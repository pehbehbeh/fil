defmodule Fil do
  @external_resource readme = Path.join([__DIR__, "../README.md"])

  @doc_body readme
            |> File.read!()
            |> String.split("<!-- MDOC -->")
            |> Enum.fetch!(1)

  @moduledoc """
  #{Mix.Project.config()[:description]}

  #{@doc_body}
  """

  alias Fil.Disk
  alias Fil.Op
  alias Fil.Ref
  alias Fil.Stat
  alias Fil.Support.Checksum

  @type result(value) :: {:ok, value} | {:error, term()}

  @root "."

  @checksums Checksum.algorithms()

  @write_schema NimbleOptions.new!(
                  if_none_match: [
                    type: {:in, [:any]},
                    doc: """
                    Pass `:any` to only create the file: the write fails with `{:error, :precondition_failed}` if the
                    file already exists.
                    """
                  ],
                  content_type: [
                    type: :string,
                    doc: "Stored as the object's content type where the backend keeps one."
                  ],
                  checksum: [
                    type: {:in, @checksums},
                    doc: """
                    Computes a checksum of the content with this algorithm (`:sha256`, `:sha1` or `:crc32`) and sends it
                    along, where the backend supports it. S3 rejects the write with `{:error, :checksum_mismatch}` if
                    the content it received doesn't match, and stores the checksum with the object. The local filesystem
                    stores nothing.
                    """
                  ]
                )

  @ls_schema NimbleOptions.new!(
               recursive: [
                 type: :boolean,
                 default: false,
                 doc: "Walk the whole subtree instead of one level."
               ]
             )

  @disk_schema NimbleOptions.new!(
                 adapter: [
                   type: :atom,
                   required: true,
                   doc: """
                   The adapter module. Every other option given to `disk/1` is passed to the adapter, which validates it
                   against its own schema.
                   """
                 ]
               )

  @read_schema NimbleOptions.new!(
                 verify_checksum: [
                   type: :boolean,
                   default: false,
                   doc: """
                   Checks the content against the checksum stored with it and returns `{:error, :checksum_mismatch}` if
                   they differ. Only S3 stores checksums (see the `:checksum` option of `write/4`). Content without a
                   stored checksum is returned unchecked.
                   """
                 ]
               )

  @stat_schema NimbleOptions.new!(
                 checksum: [
                   type: {:in, @checksums},
                   doc: """
                   Fills in `Fil.Stat`'s `:checksum` for this algorithm. S3 returns the checksum stored with the object,
                   or `nil` if it was written without one. The local filesystem computes it by reading the file.
                   """
                 ]
               )

  # Removals take no options yet. The empty schemas still make an unknown option raise instead of being ignored.
  @rm_schema NimbleOptions.new!([])
  @rm_rf_schema NimbleOptions.new!([])

  @signed_url_schema NimbleOptions.new!(
                       method: [
                         type: {:in, [:get, :put]},
                         default: :get,
                         doc: "`:get` for a download URL, `:put` for a direct upload."
                       ],
                       expires_in: [
                         type: :pos_integer,
                         default: 900,
                         doc: "How long the URL stays valid, in seconds. Most backends cap this at 7 days."
                       ]
                     )

  ## ------------------------------------------------------------------
  ## Building
  ## ------------------------------------------------------------------

  @doc """
  Builds a disk.

      iex> Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      #Fil.Disk<local>

  The adapter validates its options here, once. Invalid options raise `ArgumentError` when the disk is built instead of
  failing on first use.

  ## Options

  #{NimbleOptions.docs(@disk_schema)}
  """
  @doc section: :building
  @spec disk(keyword()) :: Disk.t()
  def disk(opts) when is_list(opts) do
    module =
      opts
      |> validated_adapter()
      |> adapter_module!()

    case module.init(Keyword.delete(opts, :adapter)) do
      {:ok, state} ->
        %Disk{adapter: {module, state}}

      {:error, reason} ->
        raise ArgumentError,
              "invalid options for #{inspect(module)}: " <> Fil.Error.format_reason(reason)
    end
  end

  # `Fil` only validates :adapter here. The adapter validates the rest in its init/1.
  defp validated_adapter(opts) do
    opts
    |> Keyword.take([:adapter])
    |> validate!(@disk_schema)
    |> Keyword.fetch!(:adapter)
  end

  defp adapter_module!(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :init, 1) do
      module
    else
      raise ArgumentError, "#{inspect(module)} is not a Fil adapter"
    end
  end

  @doc """
  Builds a ref. Shorthand for `Fil.Ref.new/2`.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      iex> Fil.ref(disk, "uploads/a.txt")
      #Fil.Ref<local:uploads/a.txt>

  """
  @doc section: :building
  @spec ref(Disk.t(), Path.t()) :: Ref.t()
  defdelegate ref(disk, path), to: Ref, as: :new

  ## ------------------------------------------------------------------
  ## Reading
  ## ------------------------------------------------------------------

  @doc """
  Reads a file.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "hello.txt", "World")
      iex> Fil.read(disk, "hello.txt")
      {:ok, "World"}
      iex> Fil.read(disk, "nope.txt")
      {:error, :enoent}

  ## Options

  #{NimbleOptions.docs(@read_schema)}
  """
  @doc section: :operations
  @spec read(Ref.t()) :: result(binary())
  def read(ref), do: read(ref, [])

  @doc "Reads a file. See `read/1`."
  @doc section: :operations
  @spec read(Disk.t(), Path.t()) :: result(binary())
  @spec read(Ref.t(), keyword()) :: result(binary())
  def read(%Disk{} = disk, path) when is_binary(path), do: read(Ref.new(disk, path), [])

  def read(ref, opts) when is_list(opts) do
    opts = validate!(opts, @read_schema)

    run(ref, :read, opts)
  end

  @doc "Reads a file. See `read/1`."
  @doc section: :operations
  @spec read(Disk.t(), Path.t(), keyword()) :: result(binary())
  def read(%Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
    read(Ref.new(disk, path), opts)
  end

  @doc """
  Returns metadata for a file or directory.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "hello.txt", "World")
      iex> {:ok, stat} = Fil.stat(disk, "hello.txt")
      iex> {stat.size, stat.type}
      {5, :regular}
      iex> Fil.stat(disk, "nope.txt")
      {:error, :enoent}

  ## Options

  #{NimbleOptions.docs(@stat_schema)}
  """
  @doc section: :operations
  @spec stat(Ref.t()) :: result(Stat.t())
  def stat(ref), do: stat(ref, [])

  @doc "Returns metadata for a file or directory. See `stat/1`."
  @doc section: :operations
  @spec stat(Disk.t(), Path.t()) :: result(Stat.t())
  @spec stat(Ref.t(), keyword()) :: result(Stat.t())
  def stat(%Disk{} = disk, path) when is_binary(path), do: stat(Ref.new(disk, path), [])

  def stat(ref, opts) when is_list(opts) do
    opts = validate!(opts, @stat_schema)

    run(ref, :stat, opts)
  end

  @doc "Returns metadata for a file or directory. See `stat/1`."
  @doc section: :operations
  @spec stat(Disk.t(), Path.t(), keyword()) :: result(Stat.t())
  def stat(%Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
    stat(Ref.new(disk, path), opts)
  end

  @doc """
  Whether anything exists at this path.

  Predicates return a plain boolean, so an unreachable backend or an invalid path is `false`. Use `stat/1` when you need
  to tell those cases apart.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "hello.txt", "World")
      iex> Fil.exists?(disk, "hello.txt")
      true
      iex> Fil.exists?(disk, "nope.txt")
      false

  """
  @doc section: :operations
  @spec exists?(Ref.t()) :: boolean()
  def exists?(ref), do: match?({:ok, _}, stat(ref))

  @doc "Whether anything exists at this path. See `exists?/1`."
  @doc section: :operations
  @spec exists?(Disk.t(), Path.t()) :: boolean()
  def exists?(%Disk{} = disk, path) when is_binary(path), do: exists?(Ref.new(disk, path))

  @doc """
  Whether this path is a directory. On object stores, that means a non-empty prefix.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "reports/q3.pdf", "%PDF")
      iex> Fil.dir?(disk, "reports")
      true
      iex> Fil.dir?(disk, "reports/q3.pdf")
      false

  """
  @doc section: :operations
  @spec dir?(Ref.t()) :: boolean()
  def dir?(ref), do: match?({:ok, %Stat{type: :directory}}, stat(ref))

  @doc "Whether this path is a directory. See `dir?/1`."
  @doc section: :operations
  @spec dir?(Disk.t(), Path.t()) :: boolean()
  def dir?(%Disk{} = disk, path) when is_binary(path), do: dir?(Ref.new(disk, path))

  @doc """
  Lists a directory. The whole listing is loaded into memory.

  One level deep by default; pass `recursive: true` to walk the whole subtree. Paths are relative to the disk root, and
  a missing prefix returns an empty list.

  A one-level listing includes directories. A recursive listing returns files only, because object stores only have
  directories implicitly and the result should be the same on every backend.

  ## Options

  #{NimbleOptions.docs(@ls_schema)}

  ## Examples

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "hello.txt", "World")
      iex> Fil.write!(disk, "reports/q3.pdf", "%PDF")
      iex> {:ok, [hello, reports]} = Fil.ls(disk)
      iex> hello
      #Fil.Ref<memory:hello.txt>
      iex> reports.stat.type
      :directory
      iex> {:ok, [_hello, report]} = Fil.ls(disk, ".", recursive: true)
      iex> report
      #Fil.Ref<memory:reports/q3.pdf>

  The results are ordinary refs with `:stat` filled in from the listing, so you can pass them to any other
  function:

      {:ok, reports} = Fil.ls(disk, "reports", recursive: true)

      reports
      |> Enum.filter(&(&1.stat.size == 0))
      |> Enum.each(&Fil.rm/1)

  """
  @doc section: :operations
  @spec ls(Disk.t()) :: result([Ref.t()])
  @spec ls(Ref.t()) :: result([Ref.t()])
  def ls(%Disk{} = disk), do: ls(Ref.new(disk, @root), [])
  def ls(ref), do: ls(ref, [])

  @doc "Lists a directory. See `ls/1`."
  @doc section: :operations
  @spec ls(Disk.t(), Path.t()) :: result([Ref.t()])
  @spec ls(Ref.t(), keyword()) :: result([Ref.t()])
  def ls(%Disk{} = disk, path) when is_binary(path), do: ls(Ref.new(disk, path), [])

  def ls(ref, opts) when is_list(opts) do
    opts = validate!(opts, @ls_schema)

    run(ref, :ls, opts)
  end

  @doc "Lists a directory. See `ls/1`."
  @doc section: :operations
  @spec ls(Disk.t(), Path.t(), keyword()) :: result([Ref.t()])
  def ls(%Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
    ls(Ref.new(disk, path), opts)
  end

  ## ------------------------------------------------------------------
  ## Writing
  ## ------------------------------------------------------------------

  @doc """
  Writes a file, creating missing parent directories.

  `content` is any iodata.

  ## Options

  #{NimbleOptions.docs(@write_schema)}

  ## Examples

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> {:ok, report} = Fil.write(disk, "reports/q3.pdf", ["%PDF", "-1.7"])
      iex> report
      #Fil.Ref<memory:reports/q3.pdf>
      iex> Fil.write(disk, "reports/q3.pdf", "again", if_none_match: :any)
      {:error, :precondition_failed}

  """
  @doc section: :operations
  @spec write(Ref.t(), iodata()) :: result(Ref.t())
  def write(ref, content), do: write(ref, content, [])

  @doc "Writes a file. See `write/2`."
  @doc section: :operations
  @spec write(Disk.t(), Path.t(), iodata()) :: result(Ref.t())
  @spec write(Ref.t(), iodata(), keyword()) :: result(Ref.t())
  def write(%Disk{} = disk, path, content) when is_binary(path) do
    write(Ref.new(disk, path), content, [])
  end

  def write(ref, content, opts) when is_list(opts) do
    opts = validate!(opts, @write_schema)

    run(ref, :write, opts, content: content)
  end

  @doc "Writes a file. See `write/2`."
  @doc section: :operations
  @spec write(Disk.t(), Path.t(), iodata(), keyword()) :: result(Ref.t())
  def write(%Disk{} = disk, path, content, opts) when is_binary(path) and is_list(opts) do
    write(Ref.new(disk, path), content, opts)
  end

  @doc """
  Deletes a file.

  Deleting is idempotent: a missing file still returns `{:ok, ref}`. The returned ref is meant for a restore
  function in a future release.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "hello.txt", "World")
      iex> {:ok, deleted} = Fil.rm(disk, "hello.txt")
      iex> deleted
      #Fil.Ref<memory:hello.txt>
      iex> {:ok, ^deleted} = Fil.rm(disk, "hello.txt")
      iex> Fil.exists?(disk, "hello.txt")
      false

  """
  @doc section: :operations
  @spec rm(Ref.t()) :: result(Ref.t())
  def rm(ref), do: rm(ref, [])

  @doc "Deletes a file. See `rm/1`."
  @doc section: :operations
  @spec rm(Disk.t(), Path.t()) :: result(Ref.t())
  @spec rm(Ref.t(), keyword()) :: result(Ref.t())
  def rm(%Disk{} = disk, path) when is_binary(path), do: rm(Ref.new(disk, path), [])

  def rm(ref, opts) when is_list(opts) do
    opts = validate!(opts, @rm_schema)

    run(ref, :rm, opts)
  end

  @doc "Deletes a file. See `rm/1`."
  @doc section: :operations
  @spec rm(Disk.t(), Path.t(), keyword()) :: result(Ref.t())
  def rm(%Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
    rm(Ref.new(disk, path), opts)
  end

  @doc """
  Removes everything under a prefix and returns the number of deleted files.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "reports/2026/q3.pdf", "%PDF")
      iex> Fil.write!(disk, "reports/2026/q4.pdf", "%PDF")
      iex> Fil.rm_rf(disk, "reports/2026")
      {:ok, 2}

  On object stores the prefix is matched as a directory: `"reports"` removes `"reports"` and everything under
  `"reports/"`, but not `"reports.txt"`.
  """
  @doc section: :operations
  @spec rm_rf(Ref.t()) :: result(non_neg_integer())
  def rm_rf(ref), do: rm_rf(ref, [])

  @doc "Removes everything under a prefix. See `rm_rf/1`."
  @doc section: :operations
  @spec rm_rf(Disk.t(), Path.t()) :: result(non_neg_integer())
  @spec rm_rf(Ref.t(), keyword()) :: result(non_neg_integer())
  def rm_rf(%Disk{} = disk, path) when is_binary(path) do
    rm_rf(Ref.new(disk, path), [])
  end

  def rm_rf(ref, opts) when is_list(opts) do
    opts = validate!(opts, @rm_rf_schema)

    run(ref, :rm_rf, opts)
  end

  @doc "Removes everything under a prefix. See `rm_rf/1`."
  @doc section: :operations
  @spec rm_rf(Disk.t(), Path.t(), keyword()) :: result(non_neg_integer())
  def rm_rf(%Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
    rm_rf(Ref.new(disk, path), opts)
  end

  @doc """
  Copies a file and returns the destination ref.

  Within one disk, `Fil` uses the adapter's native copy. Across disks, it reads the file and writes it to the
  destination. The destination may be a ref, or a bare path on the source's disk.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> other = Fil.disk(adapter: Fil.Adapter.Memory, root: "other")
      iex> Fil.write!(disk, "hello.txt", "World")
      iex> {:ok, backup} = Fil.cp(disk, "hello.txt", "backup/hello.txt")
      iex> backup
      #Fil.Ref<memory:backup/hello.txt>
      iex> {:ok, copy} = Fil.cp(disk, "hello.txt", Fil.ref(other, "hello.txt"))
      iex> Fil.read(copy)
      {:ok, "World"}

  """
  @doc section: :operations
  @spec cp(Ref.t(), Ref.t() | Path.t()) :: result(Ref.t())
  def cp(src, dest), do: cp(src, dest, [])

  @doc "Copies a file. See `cp/2`."
  @doc section: :operations
  @spec cp(Disk.t(), Path.t(), Ref.t() | Path.t()) :: result(Ref.t())
  @spec cp(Ref.t(), Ref.t() | Path.t(), keyword()) :: result(Ref.t())
  def cp(%Disk{} = disk, src_path, dest) when is_binary(src_path) do
    cp(Ref.new(disk, src_path), dest, [])
  end

  def cp(src, dest, opts) when is_list(opts) do
    transfer(src, dest, validate!(opts, @write_schema), :cp)
  end

  @doc "Copies a file. See `cp/2`."
  @doc section: :operations
  @spec cp(Disk.t(), Path.t(), Ref.t() | Path.t(), keyword()) :: result(Ref.t())
  def cp(%Disk{} = disk, src_path, dest, opts) when is_binary(src_path) and is_list(opts) do
    cp(Ref.new(disk, src_path), dest, opts)
  end

  @doc """
  Moves a file and returns the destination ref.

  Within one disk, `Fil` uses the adapter's native rename. Across disks, it copies the file and then deletes the source.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "draft.txt", "World")
      iex> {:ok, final} = Fil.rename(disk, "draft.txt", "final.txt")
      iex> final
      #Fil.Ref<memory:final.txt>
      iex> Fil.exists?(disk, "draft.txt")
      false

  """
  @doc section: :operations
  @spec rename(Ref.t(), Ref.t() | Path.t()) :: result(Ref.t())
  def rename(src, dest), do: rename(src, dest, [])

  @doc "Moves a file. See `rename/2`."
  @doc section: :operations
  @spec rename(Disk.t(), Path.t(), Ref.t() | Path.t()) :: result(Ref.t())
  @spec rename(Ref.t(), Ref.t() | Path.t(), keyword()) :: result(Ref.t())
  def rename(%Disk{} = disk, src_path, dest) when is_binary(src_path) do
    rename(Ref.new(disk, src_path), dest, [])
  end

  def rename(src, dest, opts) when is_list(opts) do
    transfer(src, dest, validate!(opts, @write_schema), :rename)
  end

  @doc "Moves a file. See `rename/2`."
  @doc section: :operations
  @spec rename(Disk.t(), Path.t(), Ref.t() | Path.t(), keyword()) :: result(Ref.t())
  def rename(%Disk{} = disk, src_path, dest, opts) when is_binary(src_path) and is_list(opts) do
    rename(Ref.new(disk, src_path), dest, opts)
  end

  ## ------------------------------------------------------------------
  ## URLs
  ## ------------------------------------------------------------------

  @doc """
  Builds a URL that grants temporary access to a file.

  ## Options

  #{NimbleOptions.docs(@signed_url_schema)}

  ## Examples

      Fil.signed_url(s3, "cv.pdf", expires_in: 300)
      #=> {:ok, "https://bucket.s3.eu-central-1.amazonaws.com/cv.pdf?X-Amz-Algorithm=..."}

  S3 signs its own URLs. Local and memory disks can't, so they sign with `Fil.Plugin.SignedURL`, and `Fil.Plug` serves
  the URLs from your application:

      iex> disk =
      ...>   Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      ...>   |> Fil.Plugin.SignedURL.attach(base_url: "http://localhost:4000/storage", secret: "secret")
      iex> {:ok, url} = Fil.signed_url(disk, "cv.pdf")
      iex> url =~ ~r"^http://localhost:4000/storage/cv.pdf[?]expires=[0-9]+&signature="
      true

  Without the plugin, a local or memory disk returns an error:

      iex> disk = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      iex> Fil.signed_url(disk, "cv.pdf")
      {:error, {:unsupported, :signed_url}}

  """
  @doc section: :operations
  @spec signed_url(Ref.t()) :: result(String.t())
  def signed_url(ref), do: signed_url(ref, [])

  @doc "Builds a signed URL. See `signed_url/1`."
  @doc section: :operations
  @spec signed_url(Disk.t(), Path.t()) :: result(String.t())
  @spec signed_url(Ref.t(), keyword()) :: result(String.t())
  def signed_url(%Disk{} = disk, path) when is_binary(path), do: signed_url(Ref.new(disk, path), [])

  def signed_url(ref, opts) when is_list(opts) do
    opts = validate!(opts, @signed_url_schema)

    run(ref, :signed_url, opts)
  end

  @doc "Builds a signed URL. See `signed_url/1`."
  @doc section: :operations
  @spec signed_url(Disk.t(), Path.t(), keyword()) :: result(String.t())
  def signed_url(%Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
    signed_url(Ref.new(disk, path), opts)
  end

  ## ------------------------------------------------------------------
  ## Bang variants
  ## ------------------------------------------------------------------

  @doc "Same as `read/1`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec read!(Ref.t()) :: binary()
  def read!(ref), do: unwrap!(read(ref), :read, ref)

  @doc "Same as `read/2`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec read!(Disk.t(), Path.t()) :: binary()
  @spec read!(Ref.t(), keyword()) :: binary()
  def read!(a, b), do: unwrap!(read(a, b), :read, target(a, b))

  @doc "Same as `read/3`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec read!(Disk.t(), Path.t(), keyword()) :: binary()
  def read!(a, b, c), do: unwrap!(read(a, b, c), :read, target(a, b))

  @doc "Same as `stat/1`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec stat!(Ref.t()) :: Stat.t()
  def stat!(ref), do: unwrap!(stat(ref), :stat, ref)

  @doc "Same as `stat/2`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec stat!(Disk.t(), Path.t()) :: Stat.t()
  @spec stat!(Ref.t(), keyword()) :: Stat.t()
  def stat!(a, b), do: unwrap!(stat(a, b), :stat, target(a, b))

  @doc "Same as `stat/3`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec stat!(Disk.t(), Path.t(), keyword()) :: Stat.t()
  def stat!(a, b, c), do: unwrap!(stat(a, b, c), :stat, target(a, b))

  @doc "Same as `ls/1`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec ls!(Disk.t()) :: [Ref.t()]
  @spec ls!(Ref.t()) :: [Ref.t()]
  def ls!(target), do: unwrap!(ls(target), :ls, target)

  @doc "Same as `ls/2`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec ls!(Disk.t(), Path.t()) :: [Ref.t()]
  @spec ls!(Ref.t(), keyword()) :: [Ref.t()]
  def ls!(a, b), do: unwrap!(ls(a, b), :ls, target(a, b))

  @doc "Same as `ls/3`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec ls!(Disk.t(), Path.t(), keyword()) :: [Ref.t()]
  def ls!(a, b, c), do: unwrap!(ls(a, b, c), :ls, target(a, b))

  @doc "Same as `write/2`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec write!(Ref.t(), iodata()) :: Ref.t()
  def write!(ref, content), do: unwrap!(write(ref, content), :write, ref)

  @doc "Same as `write/3`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec write!(Disk.t(), Path.t(), iodata()) :: Ref.t()
  @spec write!(Ref.t(), iodata(), keyword()) :: Ref.t()
  def write!(a, b, c), do: unwrap!(write(a, b, c), :write, target(a, b))

  @doc "Same as `write/4`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec write!(Disk.t(), Path.t(), iodata(), keyword()) :: Ref.t()
  def write!(a, b, c, d), do: unwrap!(write(a, b, c, d), :write, target(a, b))

  @doc "Same as `rm/1`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec rm!(Ref.t()) :: Ref.t()
  def rm!(ref), do: unwrap!(rm(ref), :rm, ref)

  @doc "Same as `rm/2`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec rm!(Disk.t(), Path.t()) :: Ref.t()
  @spec rm!(Ref.t(), keyword()) :: Ref.t()
  def rm!(a, b), do: unwrap!(rm(a, b), :rm, target(a, b))

  @doc "Same as `rm/3`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec rm!(Disk.t(), Path.t(), keyword()) :: Ref.t()
  def rm!(a, b, c), do: unwrap!(rm(a, b, c), :rm, target(a, b))

  @doc "Same as `rm_rf/1`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec rm_rf!(Ref.t()) :: non_neg_integer()
  def rm_rf!(ref) do
    unwrap!(rm_rf(ref), :rm_rf, ref)
  end

  @doc "Same as `rm_rf/2`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec rm_rf!(Disk.t(), Path.t()) :: non_neg_integer()
  @spec rm_rf!(Ref.t(), keyword()) :: non_neg_integer()
  def rm_rf!(a, b), do: unwrap!(rm_rf(a, b), :rm_rf, target(a, b))

  @doc "Same as `rm_rf/3`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec rm_rf!(Disk.t(), Path.t(), keyword()) :: non_neg_integer()
  def rm_rf!(a, b, c) do
    unwrap!(rm_rf(a, b, c), :rm_rf, target(a, b))
  end

  @doc "Same as `cp/2`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec cp!(Ref.t(), Ref.t() | Path.t()) :: Ref.t()
  def cp!(src, dest), do: unwrap!(cp(src, dest), :cp, src)

  @doc "Same as `cp/3`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec cp!(Disk.t(), Path.t(), Ref.t() | Path.t()) :: Ref.t()
  @spec cp!(Ref.t(), Ref.t() | Path.t(), keyword()) :: Ref.t()
  def cp!(a, b, c), do: unwrap!(cp(a, b, c), :cp, target(a, b))

  @doc "Same as `cp/4`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec cp!(Disk.t(), Path.t(), Ref.t() | Path.t(), keyword()) :: Ref.t()
  def cp!(a, b, c, d), do: unwrap!(cp(a, b, c, d), :cp, target(a, b))

  @doc "Same as `rename/2`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec rename!(Ref.t(), Ref.t() | Path.t()) :: Ref.t()
  def rename!(src, dest), do: unwrap!(rename(src, dest), :rename, src)

  @doc "Same as `rename/3`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec rename!(Disk.t(), Path.t(), Ref.t() | Path.t()) :: Ref.t()
  @spec rename!(Ref.t(), Ref.t() | Path.t(), keyword()) :: Ref.t()
  def rename!(a, b, c), do: unwrap!(rename(a, b, c), :rename, target(a, b))

  @doc "Same as `rename/4`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec rename!(Disk.t(), Path.t(), Ref.t() | Path.t(), keyword()) :: Ref.t()
  def rename!(a, b, c, d), do: unwrap!(rename(a, b, c, d), :rename, target(a, b))

  @doc "Same as `signed_url/1`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec signed_url!(Ref.t()) :: String.t()
  def signed_url!(ref), do: unwrap!(signed_url(ref), :signed_url, ref)

  @doc "Same as `signed_url/2`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec signed_url!(Disk.t(), Path.t()) :: String.t()
  @spec signed_url!(Ref.t(), keyword()) :: String.t()
  def signed_url!(a, b), do: unwrap!(signed_url(a, b), :signed_url, target(a, b))

  @doc "Same as `signed_url/3`, raising `Fil.Error` on failure."
  @doc section: :bang
  @spec signed_url!(Disk.t(), Path.t(), keyword()) :: String.t()
  def signed_url!(a, b, c), do: unwrap!(signed_url(a, b, c), :signed_url, target(a, b))

  ## ------------------------------------------------------------------
  ## Dispatch
  ##
  ## Every public function builds a `Fil.Op` and runs it through the disk's
  ## plugins to the adapter (`Fil.Op.run/1`).
  ## ------------------------------------------------------------------

  # A bad option is a programming error, so it raises here instead of coming back as `{:error, _}`.
  defp validate!(opts, schema) do
    case NimbleOptions.validate(opts, schema) do
      {:ok, validated} -> validated
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  defp run(ref, name, opts, fields \\ []) do
    with {:ok, %Ref{disk: disk, path: path}} <- resolve(ref) do
      Op.run(struct!(%Op{disk: disk, name: name, path: path, options: opts}, fields))
    end
  end

  defp transfer(src, dest, opts, name) do
    with {:ok, src_ref} <- resolve(src),
         {:ok, dest_ref} <- resolve(dest, src_ref) do
      if src_ref.disk == dest_ref.disk do
        run(src_ref, name, opts, dest: dest_ref.path)
      else
        cross_disk(name, src_ref, dest_ref, opts)
      end
    end
  end

  defp cross_disk(:cp, src, dest, opts) do
    with {:ok, content} <- read(src), do: write(dest, content, opts)
  end

  defp cross_disk(:rename, src, dest, opts) do
    with {:ok, dest_ref} <- cross_disk(:cp, src, dest, opts),
         {:ok, _} <- rm(src) do
      {:ok, dest_ref}
    end
  end

  defp resolve(%Ref{} = ref), do: Ref.normalize(ref)

  defp resolve(other) do
    raise ArgumentError,
          "expected a %Fil.Ref{}, got: #{inspect(other)}"
  end

  defp resolve(path, %Ref{disk: disk}) when is_binary(path), do: resolve(Ref.new(disk, path))
  defp resolve(ref, _src), do: resolve(ref)

  defp target(%Disk{} = disk, path) when is_binary(path), do: Ref.new(disk, path)
  defp target(first, _second), do: first

  defp unwrap!({:ok, value}, _op, _ref), do: value

  defp unwrap!({:error, reason}, op, ref) do
    {path, adapter} = describe(ref)
    raise Fil.Error, reason: reason, op: op, path: path, adapter: adapter
  end

  defp describe(%Ref{disk: disk, path: path}), do: {path, Disk.adapter(disk)}
  defp describe(%Disk{} = disk), do: {@root, Disk.adapter(disk)}
  defp describe(_other), do: {nil, nil}
end
