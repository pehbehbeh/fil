defmodule Fil.Adapter.Memory do
  @schema NimbleOptions.new!(
            root: [
              type: :string,
              default: ".",
              doc: """
              The prefix every path is resolved against, inside the store. Two disks on the same store see each other's
              files where their roots overlap, the same as two local disks on one filesystem.
              """
            ]
          )

  @moduledoc """
  Files in memory, in a store that belongs to a process. It's meant for tests.

      setup do
        Fil.Adapter.Memory.checkout()
      end

      test "stores the avatar" do
        disk = Fil.disk(adapter: Fil.Adapter.Memory, root: "uploads")

        assert {:ok, _} = Fil.write(disk, "avatars/1.png", "png")
      end

  ## Stores

  `checkout/0` creates a store owned by the calling process, usually the test. The store is an ETS table, so it's gone
  when the owner exits. Every test starts with an empty store and nothing needs cleaning up, with `async: true` too.

  Every operation uses the store of the process that runs it:

    * the store the process checked out itself
    * a store it was allowed into with `allow/2`
    * the store of a process in its `$callers`. `Task` sets `$callers`, and so does `Phoenix.LiveViewTest` for the
      LiveView processes it starts, so both find the test's store without `allow/2`

  An operation in a process without a store raises, because that's a missing `checkout/0` or `allow/2` in the test and
  not a storage condition.

  The disk itself only holds the root, so it can be built anywhere (in `config/test.exs`, for example), and every disk
  built in the test sees the same store.

  ## Options

  #{NimbleOptions.docs(@schema)}

  ## Operations

  Where this list says nothing else, an operation follows the [contract](Fil.Adapter.html#module-contract). Directories
  exist only as prefixes, like on an object store, so there are no empty directories.

    * `Fil.read/3`: the content from the store. Reading a directory is a `Fil.NotFoundError`. `verify_checksum: true`
      compares the content with the checksum the write stored.
    * `Fil.stream/3`: the content from the store, looked up when the stream is read, in chunks of 64 KiB.
      `verify_checksum: true` compares it before the first chunk.
    * `Fil.write/4`: one `:ets.insert/2`, so writes are atomic. A stream is collected first. `if_exists: :error` uses
      `:ets.insert_new/2`, so its check is atomic too. `checksum:` stores the checksum of the content. Writing to
      `report.txt/x` when `report.txt` is a file writes a second file and leaves the first alone.
    * `Fil.rm/3`: removing a directory succeeds and removes nothing.
    * `Fil.stat/3`: `:etag` is the MD5 of the content in hex (the ETag S3 returns for a single-part upload), and
      `:content_type` is the `content_type:` the write stored. `checksum:` returns the stored checksum if the write
      used the same algorithm, and `nil` otherwise. A stat on a directory returns `%Fil.Stat{type: :directory}` with
      every other field `nil`.
    * `Fil.cp/4`: the copy keeps the content type and the checksum. Copying a directory is a `Fil.NotFoundError`.
    * `Fil.url/3` and `Fil.signed_url/3`: a memory store has no URLs. Attach `Fil.Plugin.URL` to build them, and
      `Fil.Plug` serves them, in a test through `Phoenix.ConnTest` too.

  ## Errors

  `:reason` is the POSIX atom `Fil.Adapter.Local` would return in the same situation.

  | Situation | `Fil` error | `:reason` |
  | --- | --- | --- |
  | a missing file | `Fil.NotFoundError` | `:enoent` |
  | an exclusive create finding the file already there | `Fil.AlreadyExistsError` | `:eexist` |
  | `verify_checksum: true` and content that doesn't match | `Fil.ChecksumMismatchError` | `:checksum_mismatch` |
  """

  @behaviour Fil.Adapter

  alias Fil.Stat
  alias Fil.Support.Checksum
  alias Fil.Support.Content
  alias Fil.Support.MemoryStores

  # A stream yields the stored binary in pieces of this size. They're sub-binaries, so nothing is copied.
  @chunk_size 65_536

  defstruct [:prefix]

  @type t :: %__MODULE__{prefix: String.t()}

  @doc """
  Creates a store owned by the calling process.

  Returns `:ok`, so it can be the whole `setup` block. Calling it again in the same process keeps the existing store.
  """
  @spec checkout() :: :ok
  def checkout do
    owner = self()

    case MemoryStores.lookup(owner) do
      {:ok, _store, ^owner} ->
        :ok

      _other ->
        store = :ets.new(__MODULE__, [:ordered_set, :public, read_concurrency: true])
        MemoryStores.put(owner, store, owner)
    end
  end

  @doc """
  Lets `allowed` use the store of `owner`.

  Both can be a pid or a registered name. `owner` must have a store, from `checkout/0` or from an earlier `allow/2`.
  Processes that `owner` starts as `Task`s don't need this.

      setup do
        Fil.Adapter.Memory.checkout()
        Fil.Adapter.Memory.allow(self(), MyApp.Thumbnailer)
      end

  """
  @spec allow(pid() | atom(), pid() | atom()) :: :ok
  def allow(owner, allowed) do
    owner_pid = whereis!(owner)

    case MemoryStores.lookup(owner_pid) do
      {:ok, store, real_owner} ->
        allowed
        |> whereis!()
        |> MemoryStores.put(store, real_owner)

      :error ->
        raise ArgumentError, "#{inspect(owner)} has no memory store, call Fil.Adapter.Memory.checkout/0 first"
    end
  end

  defp whereis!(pid) when is_pid(pid), do: pid

  defp whereis!(name) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> pid
      _other -> raise ArgumentError, "no process is registered as #{inspect(name)}"
    end
  end

  ## ------------------------------------------------------------------
  ## Callbacks
  ## ------------------------------------------------------------------

  @impl Fil.Adapter
  def init(opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema),
         {:ok, prefix} <- parse_root(opts[:root]) do
      {:ok, %__MODULE__{prefix: prefix}}
    end
  end

  defp parse_root(root) do
    case Fil.Support.Path.normalize(root) do
      {:ok, "."} -> {:ok, ""}
      {:ok, path} -> {:ok, path <> "/"}
      {:error, :ebadpath} -> {:error, {:invalid_option, {:root, root}}}
    end
  end

  @impl Fil.Adapter
  def read(state, path, opts) do
    case :ets.lookup(store!(), key(state, path)) do
      [{_key, content, _content_type, _mtime, checksum}] -> verify(content, checksum, opts)
      [] -> {:error, %Fil.NotFoundError{reason: :enoent}}
    end
  end

  # The store holds the whole content anyway, so a stream is collected before it's stored.
  @impl Fil.Adapter
  def write(state, path, content, opts) do
    content = Content.to_binary(content)
    entry = {key(state, path), content, Keyword.get(opts, :content_type), now(), checksum(content, opts)}

    case Keyword.get(opts, :if_exists, :overwrite) do
      :overwrite -> insert(store!(), entry)
      :error -> if :ets.insert_new(store!(), entry), do: :ok, else: {:error, %Fil.AlreadyExistsError{reason: :eexist}}
    end
  end

  # The file is looked up again when the stream is read, like on the other adapters.
  @impl Fil.Adapter
  def stream(state, path, opts) do
    case :ets.lookup(store!(), key(state, path)) do
      [{_key, content, _content_type, _mtime, _checksum}] ->
        {:ok, Stream.flat_map([path], &read_chunks!(state, &1, opts)), byte_size(content)}

      [] ->
        {:error, %Fil.NotFoundError{reason: :enoent}}
    end
  end

  defp read_chunks!(state, path, opts) do
    case read(state, path, opts) do
      {:ok, content} -> chunks(content)
      {:error, error} -> raise error
    end
  end

  defp chunks(<<chunk::binary-size(@chunk_size), rest::binary>>), do: [chunk | chunks(rest)]
  defp chunks(<<>>), do: []
  defp chunks(rest), do: [rest]

  @impl Fil.Adapter
  def rm(state, path, _opts) do
    true = :ets.delete(store!(), key(state, path))
    :ok
  end

  @impl Fil.Adapter
  def stat(_state, ".", _opts), do: {:ok, %Stat{type: :directory}}

  def stat(state, path, opts) do
    store = store!()

    case :ets.lookup(store, key(state, path)) do
      [entry] -> {:ok, file_stat(entry, Keyword.get(opts, :checksum))}
      [] -> directory_stat(store, state, path)
    end
  end

  @impl Fil.Adapter
  def ls(state, prefix, opts) do
    entries = entries_under(store!(), state, prefix)

    if Keyword.get(opts, :recursive, false) do
      {:ok, Enum.map(entries, &{relative(state, elem(&1, 0)), file_stat(&1, nil)})}
    else
      {:ok, one_level(entries, state, prefix)}
    end
  end

  @impl Fil.Adapter
  def cp(state, src, dest, _opts) do
    store = store!()

    case :ets.lookup(store, key(state, src)) do
      [{_key, content, content_type, _mtime, checksum}] ->
        insert(store, {key(state, dest), content, content_type, now(), checksum})

      [] ->
        {:error, %Fil.NotFoundError{reason: :enoent}}
    end
  end

  @impl Fil.Adapter
  def rename(_state, path, path, _opts), do: :ok

  def rename(state, src, dest, opts) do
    with :ok <- cp(state, src, dest, opts), do: rm(state, src, opts)
  end

  @impl Fil.Adapter
  def rm_rf(state, prefix, _opts) do
    store = store!()
    exact = :ets.take(store, key(state, prefix))
    under = entries_under(store, state, prefix)

    Enum.each(under, &:ets.delete(store, elem(&1, 0)))

    {:ok, length(exact) + length(under)}
  end

  ## ------------------------------------------------------------------
  ## Stores
  ## ------------------------------------------------------------------

  defp store! do
    Enum.find_value([self() | Process.get(:"$callers", [])], &lookup_store/1) ||
      raise """
      #{inspect(self())} has no Fil.Adapter.Memory store. Call Fil.Adapter.Memory.checkout/0 in the test setup, or \
      Fil.Adapter.Memory.allow/2 for a process the test didn't start as a Task.
      """
  end

  defp lookup_store(pid) do
    case MemoryStores.lookup(pid) do
      {:ok, store, _owner} -> store
      :error -> nil
    end
  end

  defp insert(store, entry) do
    true = :ets.insert(store, entry)
    :ok
  end

  ## ------------------------------------------------------------------
  ## Keys
  ## ------------------------------------------------------------------

  # Keys are full paths in the store. `state.prefix` is `""` or the root with a trailing slash.
  defp key(state, "."), do: state.prefix
  defp key(state, path), do: state.prefix <> path

  defp relative(state, key), do: String.replace_prefix(key, state.prefix, "")

  defp dir_prefix(state, "."), do: state.prefix
  defp dir_prefix(state, path), do: state.prefix <> path <> "/"

  # Every entry below `path`, sorted by key. The table is an ordered set, so this could walk from the prefix with
  # `:ets.next/2`. A store in a test is small, so a scan keeps it simple.
  defp entries_under(store, state, path) do
    prefix = dir_prefix(state, path)

    store
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _content, _content_type, _mtime, _checksum} -> String.starts_with?(key, prefix) end)
  end

  ## ------------------------------------------------------------------
  ## Listing and stat
  ## ------------------------------------------------------------------

  defp one_level(entries, state, prefix) do
    dir = dir_prefix(state, prefix)

    entries
    |> Enum.map(fn entry ->
      key = elem(entry, 0)

      relative_key = String.replace_prefix(key, dir, "")

      case String.split(relative_key, "/", parts: 2) do
        [_name] -> {relative(state, key), file_stat(entry, nil)}
        [name, _rest] -> {Fil.Support.Path.join(prefix, name), %Stat{type: :directory}}
      end
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp directory_stat(store, state, path) do
    if entries_under(store, state, path) == [] do
      {:error, %Fil.NotFoundError{reason: :enoent}}
    else
      {:ok, %Stat{type: :directory}}
    end
  end

  defp file_stat({_key, content, content_type, mtime, checksum}, algorithm) do
    %Stat{
      size: byte_size(content),
      type: :regular,
      mtime: mtime,
      etag:
        :md5
        |> :crypto.hash(content)
        |> Base.encode16(case: :lower),
      content_type: content_type,
      checksum: stored_checksum(checksum, algorithm)
    }
  end

  ## ------------------------------------------------------------------
  ## Checksums
  ## ------------------------------------------------------------------

  defp checksum(content, opts) do
    case Keyword.get(opts, :checksum) do
      nil -> nil
      algorithm -> {algorithm, Checksum.digest(algorithm, content)}
    end
  end

  # Like S3: only the algorithm the file was written with has a checksum.
  defp stored_checksum({algorithm, _checksum} = stored, algorithm), do: stored
  defp stored_checksum(_stored, _algorithm), do: nil

  defp verify(content, {algorithm, checksum}, opts) do
    if Keyword.get(opts, :verify_checksum, false) and Checksum.digest(algorithm, content) != checksum do
      {:error, %Fil.ChecksumMismatchError{reason: :checksum_mismatch}}
    else
      {:ok, content}
    end
  end

  defp verify(content, nil, _opts), do: {:ok, content}

  defp now do
    :second
    |> System.os_time()
    |> DateTime.from_unix!()
  end
end
