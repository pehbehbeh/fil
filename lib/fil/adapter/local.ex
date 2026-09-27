defmodule Fil.Adapter.Local do
  @schema NimbleOptions.new!(
            root: [
              type: :string,
              doc: """
              The directory every path is resolved against. Defaults to `File.cwd!()` when the disk is built, so
              changing the working directory later doesn't move the disk. A relative root is expanded once, when the
              disk is built.
              """
            ]
          )

  @moduledoc """
  The local filesystem, jailed under a root directory.

      disk = Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage")

  Unlike on an object store, directories exist on their own and can be empty. Every path is checked against the root
  again after expansion. `Fil` has already rejected `../` escapes, so this is defense in depth. The check only looks at
  the path string: a symlink inside the root can still point outside it.

  ## Options

  #{NimbleOptions.docs(@schema)}

  ## Operations

  Where this list says nothing else, an operation follows the [contract](Fil.Adapter.html#module-contract).

    * `Fil.read/3`: `File.read/1`. Reading a directory is a `Fil.InvalidRequestError`. The filesystem stores no
      checksums, so `verify_checksum: true` is ignored.
    * `Fil.stream/3`: opens the file to check it, then reads it in chunks of 64 KiB each time the stream is read.
    * `Fil.write/4`: the content, in memory or a stream, goes to a temporary file named `.fil-` and a unique suffix in
      the destination directory, which `File.rename/2` then moves into place, so readers never see a partial file. A
      failed write leaves nothing behind, and removes the directories it created. A writer that's killed before it's
      done (a request process that the server stops when the client disconnects, for example) leaves its `.fil-` file
      and those directories behind. `if_exists: :error` hard-links the temporary file to the destination instead,
      which fails if it exists (on a filesystem without hard links, it creates the destination with `O_EXCL` first).
      `checksum:` is ignored. Writing over a directory, or to `report.txt/x` when `report.txt` is a file, is a
      `Fil.InvalidRequestError`.
    * `Fil.rm/3`: `File.rm/1`, with a missing file mapped to success. Removing a directory is a
      `Fil.InvalidRequestError`.
    * `Fil.stat/3`: `File.stat/2`. `:etag` is a weak `"size-mtime"` tag: good enough to notice a change, but it can't
      prove there was none. `:content_type` is `nil`, because the filesystem doesn't store one (`Fil.Plug` guesses it
      from the extension). `checksum:` reads the whole file to compute the checksum.
    * `Fil.ls/3`: `File.ls/1`, walked depth-first when recursive. Empty directories are listed too, temporary `.fil-`
      files of writes aren't. The disk reserves that prefix, so a file of your own whose name starts with `.fil-` is
      skipped as well. A path that isn't a directory lists nothing, the same as a missing one.
    * `Fil.cp/4`: `File.cp/2`. `if_exists: :error` copies to a `.fil-` temporary file instead and hard-links it to the
      destination, like a write. Copying a directory is a `Fil.InvalidRequestError`.
    * `Fil.rename/4`: `File.rename/2`, which moves directories too. `if_exists: :error` hard-links the file to the
      destination and then removes the source (on a filesystem without hard links, it creates the destination with
      `O_EXCL` first, like a write). A directory is still moved with `File.rename/2`, which can replace an empty
      directory, but never a file.
    * `Fil.rm_rf/3`: `File.rm_rf/1`, counting the files it removed. Files whose name starts with `.fil-` are removed
      too, but not counted.
    * `Fil.url/3` and `Fil.signed_url/3`: the filesystem has no URLs. Attach `Fil.Plugin.URL` to build them, and
      `Fil.Plug` serves them.

  ## Errors

  `:reason` is the POSIX atom from `File`, adjusted so it's the same on macOS and Linux (deleting a directory is
  `:eisdir` on both, a parent that's a file `:enotdir`).

  | Situation | `Fil` error | `:reason` |
  | --- | --- | --- |
  | a missing file or directory, or a path through a file (`report.txt/x`) | `Fil.NotFoundError` | `:enoent` |
  | missing permissions, a read-only filesystem | `Fil.AccessDeniedError` | `:eacces`, `:eperm`, `:erofs` |
  | reading, copying or deleting a directory, or writing over one | `Fil.InvalidRequestError` | `:eisdir` |
  | writing, copying or renaming to a path under a file | `Fil.InvalidRequestError` | `:enotdir` |
  | a name that's too long, a symlink loop | `Fil.InvalidRequestError` | `:enametoolong`, `:eloop` |
  | a path that resolves outside the root | `Fil.InvalidRequestError` | `:ebadpath` |
  | an exclusive create finding the file already there | `Fil.AlreadyExistsError` | `:eexist` |
  | a full disk, a used-up quota | `Fil.StorageFullError` | `:enospc`, `:edquot` |
  | too many open files | `Fil.UnavailableError` | `:emfile`, `:enfile` |
  | any other POSIX error | `Fil.UnknownError` | the atom |
  """

  @behaviour Fil.Adapter

  alias Fil.Stat
  alias Fil.Support.Checksum

  # The size of the chunks `Fil.stream/3` reads.
  @chunk_size 65_536

  # Writes go to a file with this prefix and a unique suffix, next to the destination. It's short, so a destination
  # name that fits the filesystem's limit still leaves room, and listings skip it.
  @tmp_prefix ".fil-"

  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  @impl Fil.Adapter
  def init(opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema) do
      root = Keyword.get(opts, :root, File.cwd!())

      {:ok, %__MODULE__{root: Path.expand(root)}}
    end
  end

  # Each callback works with the POSIX atoms from `File` and turns an error into a struct at the end (`to_error/1`).

  @impl Fil.Adapter
  def read(state, path, _opts), do: to_error(read_file(state, path))

  @impl Fil.Adapter
  def stream(state, path, _opts), do: to_error(stream_file(state, path))

  @impl Fil.Adapter
  def write(state, path, content, opts), do: to_error(write_file(state, path, content, opts))

  @impl Fil.Adapter
  def rm(state, path, _opts), do: to_error(rm_file(state, path))

  @impl Fil.Adapter
  def stat(state, path, opts), do: to_error(stat_file(state, path, opts))

  @impl Fil.Adapter
  def ls(state, prefix, opts), do: to_error(list(state, prefix, opts))

  @impl Fil.Adapter
  def cp(state, src, dest, opts), do: to_error(copy(state, src, dest, opts))

  @impl Fil.Adapter
  def rename(state, src, dest, opts), do: to_error(move(state, src, dest, opts))

  @impl Fil.Adapter
  def rm_rf(state, prefix, _opts), do: to_error(rm_tree(state, prefix))

  defp list(state, prefix, opts) do
    with {:ok, full} <- full_path(state, prefix) do
      if Keyword.get(opts, :recursive, false) do
        {:ok, walk(full, prefix)}
      else
        {:ok, one_level(full, prefix)}
      end
    end
  end

  defp read_file(state, path) do
    with {:ok, full} <- full_path(state, path), do: missing(File.read(full))
  end

  # The file is opened once to check it, and again each time the stream is read, by the process that reads it (a raw
  # file belongs to the process that opened it).
  defp stream_file(state, path) do
    with {:ok, full} <- full_path(state, path),
         {:ok, io} <- open_read(full) do
      {:ok, size} = :file.position(io, :eof)
      :ok = :file.close(io)

      {:ok, Stream.resource(fn -> open_read!(full) end, &read_chunk/1, &:file.close/1), size}
    end
  end

  defp open_read(full), do: missing(:file.open(full, [:read, :raw, :binary]))

  defp open_read!(full) do
    case open_read(full) do
      {:ok, io} -> io
      {:error, reason} -> raise to_struct(reason)
    end
  end

  defp read_chunk(io) do
    case :file.read(io, @chunk_size) do
      {:ok, chunk} -> {[chunk], io}
      :eof -> {:halt, io}
      {:error, reason} -> raise to_struct(reason)
    end
  end

  # The content goes to a temporary file next to the destination, which then takes its place in one step. Whatever
  # happens in between (an error, or a stream that raises), the temporary file is removed, and so are the directories
  # this write created, so the disk is left as it was.
  defp write_file(state, path, content, opts) do
    chunks = if is_binary(content) or is_list(content), do: [content], else: content

    put_file(state, path, &write_chunks(&1, chunks), opts)
  end

  # `fill` writes the content into the open temporary file.
  defp put_file(state, path, fill, opts) do
    with {:ok, full} <- full_path(state, path),
         {:ok, created} <- make_parents(full),
         {:ok, tmp, io, created} <- open_tmp(full, created) do
      write_into(full, {tmp, io}, created, fill, opts)
    else
      {:error, reason, created} ->
        remove_dirs(created)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Another write that created a directory this one found, and then failed, removes it again. If that happens before
  # the temporary file is opened, the directories are created once more, and then belong to this write. The open fails
  # with `:enoent` then, or with `:einval` on macOS when the directory is removed during the open.
  defp open_tmp(full, created) do
    tmp = tmp_path(full)

    case open_exclusive(tmp) do
      {:ok, io} -> {:ok, tmp, io, created}
      {:error, reason} when reason in [:enoent, :einval] -> reopen_tmp(full, tmp, created)
      {:error, reason} -> {:error, reason, created}
    end
  end

  defp reopen_tmp(full, tmp, created) do
    with {:ok, recreated} <- make_parents(full),
         {:ok, io} <- open_exclusive(tmp) do
      {:ok, tmp, io, created ++ recreated}
    else
      {:error, reason, recreated} -> {:error, reason, created ++ recreated}
      {:error, reason} -> {:error, reason, created}
    end
  end

  defp open_exclusive(tmp), do: :file.open(tmp, [:write, :exclusive, :raw, :binary])

  defp write_into(full, {tmp, io}, created, fill, opts) do
    result =
      try do
        place(tmp, io, full, fill, opts)
      catch
        kind, reason ->
          discard(tmp, created)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    if result == :ok, do: File.rm(tmp), else: discard(tmp, created)
    result
  end

  defp place(tmp, io, full, fill, opts) do
    with :ok <- write_tmp(io, fill) do
      case Keyword.get(opts, :if_exists, :overwrite) do
        :overwrite -> File.rename(tmp, full)
        :error -> create(tmp, full)
      end
    end
  end

  defp discard(tmp, created) do
    _ = File.rm(tmp)
    remove_dirs(created)
  end

  defp rm_file(state, path) do
    with {:ok, full} <- full_path(state, path) do
      case File.rm(full) do
        :ok -> :ok
        {:error, reason} when reason in [:enoent, :enotdir] -> :ok
        {:error, :eperm} -> {:error, directory_or(full, :eperm)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp stat_file(state, path, opts) do
    with {:ok, full} <- full_path(state, path),
         {:ok, stat} <- missing(File.stat(full, time: :posix)) do
      put_checksum(to_stat(stat), full, Keyword.get(opts, :checksum))
    end
  end

  # A copy that mustn't replace a file is a write with the source's content: it goes to a temporary file, which is then
  # hard-linked into place.
  defp copy(state, src, dest, opts) do
    case Keyword.get(opts, :if_exists, :overwrite) do
      :overwrite -> transfer(&File.cp/2, state, src, dest)
      :error -> copy_new(state, src, dest, opts)
    end
  end

  defp copy_new(state, src, dest, opts) do
    with {:ok, from} <- full_path(state, src),
         {:ok, io} <- open_read(from) do
      try do
        state
        |> put_file(dest, &copy_chunks(&1, io), opts)
        |> at_dest(dest)
      after
        :file.close(io)
      end
    end
  end

  defp copy_chunks(tmp_io, io) do
    case :file.copy(io, tmp_io) do
      {:ok, _bytes} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp move(state, src, dest, opts) do
    case Keyword.get(opts, :if_exists, :overwrite) do
      :overwrite ->
        transfer(&File.rename/2, state, src, dest)

      :error ->
        result = transfer(&move_new/2, state, src, dest)
        at_dest(result, dest)
    end
  end

  # A hard link claims the destination only if it doesn't exist, and removing the source then completes the move (see
  # `create/2`, which falls back to `O_EXCL` without hard links). When the source can't be removed, the link is removed
  # again, so both files stay as they were. Directories can't be hard-linked, so they're moved with `File.rename/2`,
  # which never puts a directory over a file.
  defp move_new(from, to) do
    if File.dir?(from) do
      File.rename(from, to)
    else
      with :ok <- create(from, to), do: remove_source(from, to)
    end
  end

  defp remove_source(from, to) do
    case File.rm(from) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        _ = File.rm(to)
        {:error, reason}
    end
  end

  # An exclusive copy or move that fails because the destination exists, is a directory or is under a file has the
  # destination's path.
  defp at_dest({:error, reason}, dest) when reason in [:eexist, :eisdir, :enotdir],
    do: {:error, %{to_struct(reason) | path: dest}}

  defp at_dest(result, _dest), do: result

  # A destination under a file fails on the destination side, so the error has that path.
  defp transfer(fun, state, src, dest) do
    with {:ok, from} <- full_path(state, src),
         {:ok, to} <- full_path(state, dest) do
      case ensure_parent(to) do
        :ok -> missing(fun.(from, to))
        {:error, reason} -> {:error, %{to_struct(reason) | path: dest}}
      end
    end
  end

  defp rm_tree(state, prefix) do
    with {:ok, full} <- full_path(state, prefix) do
      count = count_files(full)

      case File.rm_rf(full) do
        {:ok, _removed} -> {:ok, count}
        {:error, reason, _path} -> {:error, reason}
      end
    end
  end

  ## ------------------------------------------------------------------
  ## Errors
  ## ------------------------------------------------------------------

  defp to_error({:error, reason}) when is_atom(reason), do: {:error, to_struct(reason)}
  defp to_error(result), do: result

  defp to_struct(:enoent), do: %Fil.NotFoundError{reason: :enoent}

  defp to_struct(reason) when reason in [:eacces, :eperm, :erofs], do: %Fil.AccessDeniedError{reason: reason}

  defp to_struct(reason) when reason in [:eisdir, :enotdir, :enametoolong, :eloop, :ebadpath],
    do: %Fil.InvalidRequestError{reason: reason}

  defp to_struct(:eexist), do: %Fil.AlreadyExistsError{reason: :eexist}
  defp to_struct(reason) when reason in [:enospc, :edquot], do: %Fil.StorageFullError{reason: reason}
  defp to_struct(reason) when reason in [:emfile, :enfile], do: %Fil.UnavailableError{reason: reason}
  defp to_struct(reason), do: %Fil.UnknownError{reason: reason}

  ## ------------------------------------------------------------------
  ## Paths
  ## ------------------------------------------------------------------

  defp full_path(%__MODULE__{root: root}, ".") do
    {:ok, root}
  end

  defp full_path(%__MODULE__{root: root}, path) do
    full =
      root
      |> Path.join(path)
      |> Path.expand()

    if full == root or String.starts_with?(full, root <> "/") do
      {:ok, full}
    else
      {:error, :ebadpath}
    end
  end

  # Creates the missing parents of a file one by one, top down, and returns the ones it created, deepest first, so a
  # failed write can remove them again. A directory another process created meanwhile isn't counted.
  defp make_parents(full) do
    full
    |> Path.dirname()
    |> missing_dirs([])
    |> Enum.reduce_while({:ok, []}, &make_dir/2)
  end

  defp make_dir(dir, {:ok, created}) do
    case File.mkdir(dir) do
      :ok -> {:cont, {:ok, [dir | created]}}
      {:error, :eexist} -> existing_dir(dir, created, :retry)
      {:error, reason} -> {:halt, {:error, reason, created}}
    end
  end

  # A parent that's a file is `:enotdir`. A directory that another write removed between the `mkdir` and this check is
  # created again, once.
  defp existing_dir(dir, created, retry) do
    cond do
      File.dir?(dir) -> {:cont, {:ok, created}}
      File.exists?(dir) or retry == :no_retry -> {:halt, {:error, :enotdir, created}}
      File.mkdir(dir) == :ok -> {:cont, {:ok, [dir | created]}}
      true -> existing_dir(dir, created, :no_retry)
    end
  end

  defp missing_dirs(dir, missing) do
    parent = Path.dirname(dir)

    if File.dir?(dir) or parent == dir, do: missing, else: missing_dirs(parent, [dir | missing])
  end

  # Removes empty directories, deepest first, and stops at the first one that isn't empty, because another write put
  # something into it meanwhile.
  defp remove_dirs(dirs) do
    Enum.reduce_while(dirs, :ok, fn dir, :ok ->
      if :file.del_dir(dir) == :ok, do: {:cont, :ok}, else: {:halt, :ok}
    end)
  end

  # Creates the parents of a copy's or a move's destination. A parent that's a file is `:enotdir` on macOS and
  # `:eexist` on Linux, so both become `:enotdir`.
  defp ensure_parent(full) do
    parent = Path.dirname(full)

    case File.mkdir_p(parent) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :enotdir}
      {:error, reason} -> {:error, reason}
    end
  end

  # A path through a file (`report.txt/x`) is `:enotdir` to the filesystem, but that file doesn't exist, which
  # is what an object store says too. `cp/4` and `rename/4` call it after `ensure_parent/1`, so there it can only be the
  # source, and a destination under a file stays `:enotdir`.
  defp missing({:error, :enotdir}), do: {:error, :enoent}
  defp missing(result), do: result

  # Deleting a directory is `:eperm` on macOS and Linux, and an exclusive create on one is `:eexist`. This runs before
  # `to_struct/1`, so a directory is an invalid request, not denied access.
  defp directory_or(full, reason), do: if(File.dir?(full), do: :eisdir, else: reason)

  ## ------------------------------------------------------------------
  ## Writing
  ## ------------------------------------------------------------------

  defp write_tmp(io, fill) do
    result =
      try do
        fill.(io)
      catch
        kind, reason ->
          _ = :file.close(io)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    closed = :file.close(io)
    if result == :ok, do: closed, else: result
  end

  defp write_chunks(io, chunks) do
    Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
      case :file.write(io, chunk) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A hard link to the finished temporary file creates the destination only if it doesn't exist yet, in one step, so an
  # exclusive write never shows a partial file either. Filesystems without hard links (some network shares) claim the
  # name with `O_EXCL` instead and then move the content in, so the file is empty until the move.
  defp create(tmp, full) do
    case :file.make_link(tmp, full) do
      :ok -> :ok
      {:error, :eexist} -> {:error, directory_or(full, :eexist)}
      {:error, reason} when reason in [:enotsup, :eperm] -> claim(tmp, full)
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim(tmp, full) do
    case :file.open(full, [:write, :exclusive, :raw]) do
      {:ok, io} ->
        :ok = :file.close(io)
        File.rename(tmp, full)

      {:error, :eexist} ->
        {:error, directory_or(full, :eexist)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tmp_path(full) do
    full
    |> Path.dirname()
    |> Path.join(@tmp_prefix <> unique())
  end

  defp unique do
    counter =
      [:positive]
      |> System.unique_integer()
      |> Integer.to_string(36)

    time =
      :microsecond
      |> System.system_time()
      |> Integer.to_string(36)

    counter <> "-" <> time
  end

  ## ------------------------------------------------------------------
  ## Listing
  ## ------------------------------------------------------------------

  defp one_level(full, prefix) do
    full
    |> names()
    |> Enum.flat_map(&shallow(full, prefix, &1))
  end

  defp walk(full, prefix) do
    full
    |> names()
    |> Enum.flat_map(&deep(full, prefix, &1))
  end

  # A missing or unreadable directory lists nothing, the same as a prefix nobody wrote to on an object store.
  # Temporary files of writes aren't files of the disk yet, so they're left out of listings and counts.
  defp names(full) do
    case File.ls(full) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, @tmp_prefix))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp shallow(full, prefix, name) do
    case listing(Path.join(full, name), Fil.Support.Path.join(prefix, name)) do
      {:ok, listed} -> [listed]
      :error -> []
    end
  end

  defp deep(full, prefix, name) do
    child_full = Path.join(full, name)
    child_path = Fil.Support.Path.join(prefix, name)

    case listing(child_full, child_path) do
      {:ok, {_path, %Stat{type: :directory}}} -> walk(child_full, child_path)
      {:ok, listed} -> [listed]
      :error -> []
    end
  end

  defp listing(full, path) do
    case File.stat(full, time: :posix) do
      {:ok, %File.Stat{type: type} = stat} when type in [:regular, :directory] ->
        {:ok, {path, to_stat(stat)}}

      _other ->
        :error
    end
  end

  defp count_files(full) do
    case File.stat(full, time: :posix) do
      {:ok, %File.Stat{type: :regular}} ->
        1

      {:ok, %File.Stat{type: :directory}} ->
        full
        |> walk(".")
        |> length()

      _other ->
        0
    end
  end

  ## ------------------------------------------------------------------
  ## Stat
  ## ------------------------------------------------------------------

  defp put_checksum(stat, _full, nil), do: {:ok, stat}
  defp put_checksum(%Stat{type: :directory} = stat, _full, _algorithm), do: {:ok, stat}

  defp put_checksum(stat, full, algorithm) do
    with {:ok, checksum} <- Checksum.digest_file(algorithm, full) do
      {:ok, %{stat | checksum: {algorithm, checksum}}}
    end
  end

  defp to_stat(%File.Stat{type: type, size: size, mtime: mtime}) do
    %Stat{
      size: size,
      type: type,
      mtime: DateTime.from_unix!(mtime),
      etag: "#{size}-#{mtime}",
      content_type: nil
    }
  end
end
