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

  @typedoc """
  An error from an adapter or from `Fil` itself. Each struct stands for what the caller can do about it, and means the
  same on every adapter; see [Errors in `Fil.Adapter`](Fil.Adapter.html#module-errors).
  """
  @type error ::
          Fil.NotFoundError.t()
          | Fil.AccessDeniedError.t()
          | Fil.InvalidRequestError.t()
          | Fil.AlreadyExistsError.t()
          | Fil.ChecksumMismatchError.t()
          | Fil.StorageFullError.t()
          | Fil.UnsupportedError.t()
          | Fil.ConfigurationError.t()
          | Fil.UnavailableError.t()
          | Fil.UnknownError.t()

  @typedoc "A result. Plugins may return their own exceptions, so an error isn't always one of `t:error/0`."
  @type result(value) :: {:ok, value} | {:error, error() | Exception.t()}

  @typedoc "A plugin callback: a function or a `{module, function}` pair. See the [Plugins guide](plugins.md)."
  @type plugin_callback :: (Op.t(), (Op.t() -> Op.t()), keyword() -> Op.t()) | {module(), atom()}

  @root "."

  @checksums Checksum.algorithms()

  @write_schema NimbleOptions.new!(
                  if_exists: [
                    type: {:in, [:overwrite, :error]},
                    default: :overwrite,
                    doc: """
                    What to do if the file already exists. `:overwrite` replaces it. `:error` writes nothing and returns
                    a `Fil.AlreadyExistsError`, like `File.write/3` with `[:exclusive]`. That check is atomic on local
                    disk, in memory and on AWS S3, so two processes can't both create the file. Some S3-compatible
                    servers ignore it.
                    """
                  ],
                  content_type: [
                    type: :string,
                    doc: "Stored as the object's content type where the storage keeps one."
                  ],
                  checksum: [
                    type: {:in, @checksums},
                    doc: """
                    Computes a checksum of the content with this algorithm (`:sha256`, `:sha1` or `:crc32`) and sends it
                    along, where the storage supports it. S3 rejects the write with `Fil.ChecksumMismatchError` if the
                    content it received doesn't match, and stores the checksum with the object. The local filesystem
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

  @read_schema NimbleOptions.new!(
                 verify_checksum: [
                   type: :boolean,
                   default: false,
                   doc: """
                   Checks the content against the checksum stored with it and returns `Fil.ChecksumMismatchError` if
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

  @url_schema NimbleOptions.new!([])

  @signed_url_schema NimbleOptions.new!(
                       method: [
                         type: {:in, [:get, :put]},
                         default: :get,
                         doc: "`:get` for a download URL, `:put` for a direct upload."
                       ],
                       expires_in: [
                         type: {:in, 1..(7 * 24 * 60 * 60)},
                         default: 900,
                         doc: "How long the URL stays valid, in seconds. At most 7 days (`604800`), the cap of S3."
                       ],
                       disposition: [
                         type: {:or, [{:in, [:inline, :attachment]}, {:tuple, [{:in, [:attachment]}, :string]}]},
                         doc: """
                         The `content-disposition` of the download, for `method: :get` only. `:inline` lets the browser
                         show the file, `:attachment` saves it under the file's name, and `{:attachment, filename}`
                         under another name. Names that aren't plain ASCII work too. Without it, the download has the
                         disposition stored with the file, if any.
                         """
                       ],
                       query: [
                         type: {:list, {:tuple, [:string, :string]}},
                         default: [],
                         doc: """
                         Extra query parameters, e.g. `[{"trackingInfo", "42"}]`, for a page that reads them from its
                         own URL. They're signed with the URL, so they can't be changed or added afterwards. Names the
                         URL uses itself (`expires`, `disposition`, `signature`, and `X-Amz-*` or `response-*` on S3)
                         raise.
                         """
                       ]
                     )

  ## ------------------------------------------------------------------
  ## Building
  ## ------------------------------------------------------------------

  @doc """
  Builds a disk. Shorthand for `Fil.Disk.new/1`, which lists the options.

      iex> Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      #Fil.Disk<local>

  """
  @doc section: :building
  @spec disk(keyword()) :: Disk.t()
  defdelegate disk(opts), to: Disk, as: :new

  @doc """
  Builds a ref. Shorthand for `Fil.Ref.new/2`.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      iex> Fil.ref(disk, "uploads/a.txt")
      #Fil.Ref<local:uploads/a.txt>

  """
  @doc section: :building
  @spec ref(Disk.t(), Path.t()) :: Ref.t()
  defdelegate ref(disk, path), to: Ref, as: :new

  @doc """
  Attaches a plugin callback to a disk under a name.

      iex> disk =
      ...>   Fil.disk(adapter: Fil.Adapter.Memory)
      ...>   |> Fil.attach(:shout, fn op, next, _opts ->
      ...>     op |> Fil.Op.update_content(binary: &String.upcase/1) |> next.()
      ...>   end)
      iex> Fil.write!(disk, "hello.txt", "world")
      iex> Fil.read(disk, "hello.txt")
      {:ok, "WORLD"}

  The callback is a function of arity 3 or a `{module, function}` pair naming a public function of arity 3. `opts` are
  passed to it on every call. Attaching a name that's already attached replaces the callback and its options in the
  same position. The [Plugins guide](plugins.md) explains how to write one.
  """
  @doc section: :building
  @spec attach(Disk.t(), atom(), plugin_callback(), keyword()) :: Disk.t()
  def attach(%Disk{plugins: plugins} = disk, name, callback, opts \\ []) when is_atom(name) and is_list(opts) do
    %{disk | plugins: List.keystore(plugins, name, 0, {name, plugin_callback!(callback), opts})}
  end

  defp plugin_callback!(fun) when is_function(fun, 3), do: fun

  defp plugin_callback!({module, function} = callback) when is_atom(module) and is_atom(function) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 3) do
      callback
    else
      raise ArgumentError, "#{inspect(module)}.#{function}/3 is not a function, so it can't be a plugin callback"
    end
  end

  defp plugin_callback!(other) do
    raise ArgumentError,
          "expected a function of arity 3 or {module, function} as a plugin callback, got: #{inspect(other)}"
  end

  @doc """
  Removes a plugin from a disk. Removing a name that isn't attached returns the disk unchanged.
  """
  @doc section: :building
  @spec detach(Disk.t(), atom()) :: Disk.t()
  def detach(%Disk{plugins: plugins} = disk, name) when is_atom(name) do
    %{disk | plugins: List.keydelete(plugins, name, 0)}
  end

  ## ------------------------------------------------------------------
  ## Reading
  ## ------------------------------------------------------------------

  @doc """
  Reads a file.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "hello.txt", "World")
      iex> Fil.read(disk, "hello.txt")
      {:ok, "World"}
      iex> {:error, %Fil.NotFoundError{path: "nope.txt", reason: :enoent}} = Fil.read(disk, "nope.txt")

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
      iex> {:error, %Fil.NotFoundError{path: "nope.txt", reason: :enoent}} = Fil.stat(disk, "nope.txt")

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

  Predicates return a plain boolean, so unreachable storage or an invalid path is `false`. Use `stat/1` when you need
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
  directories implicitly and the result should be the same on every adapter.

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
      iex> {:error, %Fil.AlreadyExistsError{reason: :eexist}} =
      ...>   Fil.write(disk, "reports/q3.pdf", "again", if_exists: :error)

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
  Builds the public URL of a file.

  The URL has no signature and doesn't expire, so it only works where the file can be downloaded by anyone: a public
  bucket, a CDN, or `Fil.Plug` with `public: true`.

  ## Examples

      Fil.url(s3, "logo.png")
      #=> {:ok, "https://bucket.s3.eu-central-1.amazonaws.com/logo.png"}

  S3 builds the URL from the bucket. Local and memory disks have no URL of their own, so they get one from
  `Fil.Plugin.URL`, and `Fil.Plug` serves it from your application:

      iex> disk =
      ...>   Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      ...>   |> Fil.Plugin.URL.attach(base_url: "http://localhost:4000/avatars")
      iex> Fil.url(disk, "1.png")
      {:ok, "http://localhost:4000/avatars/1.png"}

  Without the plugin, a local or memory disk returns an error:

      iex> disk = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      iex> {:error, %Fil.UnsupportedError{op: :url, reason: :no_callback}} = Fil.url(disk, "1.png")

  """
  @doc section: :operations
  @spec url(Ref.t()) :: result(String.t())
  def url(ref), do: url(ref, [])

  @doc "Builds a public URL. See `url/1`."
  @doc section: :operations
  @spec url(Disk.t(), Path.t()) :: result(String.t())
  @spec url(Ref.t(), keyword()) :: result(String.t())
  def url(%Disk{} = disk, path) when is_binary(path), do: url(Ref.new(disk, path), [])

  def url(ref, opts) when is_list(opts) do
    run(ref, :url, validate!(opts, @url_schema))
  end

  @doc "Builds a public URL. See `url/1`."
  @doc section: :operations
  @spec url(Disk.t(), Path.t(), keyword()) :: result(String.t())
  def url(%Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
    url(Ref.new(disk, path), opts)
  end

  @doc """
  Builds a URL that grants temporary access to a file.

  ## Options

  #{NimbleOptions.docs(@signed_url_schema)}

  ## Examples

      Fil.signed_url(s3, "cv.pdf", expires_in: 300)
      #=> {:ok, "https://bucket.s3.eu-central-1.amazonaws.com/cv.pdf?X-Amz-Algorithm=..."}

      Fil.signed_url(s3, "uploads/7f3a.pdf", disposition: {:attachment, "Invoice 2026-09.pdf"})
      #=> {:ok, "https://bucket.s3.eu-central-1.amazonaws.com/uploads/7f3a.pdf?...&response-content-disposition=..."}

  S3 signs its own URLs. Local and memory disks can't, so they need `Fil.Plugin.URL` with a `:secret`, and `Fil.Plug`
  serves the URLs from your application:

      iex> disk =
      ...>   Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      ...>   |> Fil.Plugin.URL.attach(base_url: "http://localhost:4000/storage", secret: "secret")
      iex> {:ok, url} = Fil.signed_url(disk, "cv.pdf")
      iex> url =~ ~r"^http://localhost:4000/storage/cv.pdf[?]expires=[0-9]+&signature="
      true

  Without the plugin, a local or memory disk returns an error:

      iex> disk = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      iex> {:error, %Fil.UnsupportedError{op: :signed_url, reason: :no_callback}} = Fil.signed_url(disk, "cv.pdf")

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

    check_query!(opts[:query])

    run(ref, :signed_url, put_disposition(opts, ref))
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

  @doc "Same as `read/1`, raising the error on failure."
  @doc section: :bang
  @spec read!(Ref.t()) :: binary()
  def read!(ref), do: unwrap!(read(ref))

  @doc "Same as `read/2`, raising the error on failure."
  @doc section: :bang
  @spec read!(Disk.t(), Path.t()) :: binary()
  @spec read!(Ref.t(), keyword()) :: binary()
  def read!(a, b), do: unwrap!(read(a, b))

  @doc "Same as `read/3`, raising the error on failure."
  @doc section: :bang
  @spec read!(Disk.t(), Path.t(), keyword()) :: binary()
  def read!(a, b, c), do: unwrap!(read(a, b, c))

  @doc "Same as `stat/1`, raising the error on failure."
  @doc section: :bang
  @spec stat!(Ref.t()) :: Stat.t()
  def stat!(ref), do: unwrap!(stat(ref))

  @doc "Same as `stat/2`, raising the error on failure."
  @doc section: :bang
  @spec stat!(Disk.t(), Path.t()) :: Stat.t()
  @spec stat!(Ref.t(), keyword()) :: Stat.t()
  def stat!(a, b), do: unwrap!(stat(a, b))

  @doc "Same as `stat/3`, raising the error on failure."
  @doc section: :bang
  @spec stat!(Disk.t(), Path.t(), keyword()) :: Stat.t()
  def stat!(a, b, c), do: unwrap!(stat(a, b, c))

  @doc "Same as `ls/1`, raising the error on failure."
  @doc section: :bang
  @spec ls!(Disk.t()) :: [Ref.t()]
  @spec ls!(Ref.t()) :: [Ref.t()]
  def ls!(target), do: unwrap!(ls(target))

  @doc "Same as `ls/2`, raising the error on failure."
  @doc section: :bang
  @spec ls!(Disk.t(), Path.t()) :: [Ref.t()]
  @spec ls!(Ref.t(), keyword()) :: [Ref.t()]
  def ls!(a, b), do: unwrap!(ls(a, b))

  @doc "Same as `ls/3`, raising the error on failure."
  @doc section: :bang
  @spec ls!(Disk.t(), Path.t(), keyword()) :: [Ref.t()]
  def ls!(a, b, c), do: unwrap!(ls(a, b, c))

  @doc "Same as `write/2`, raising the error on failure."
  @doc section: :bang
  @spec write!(Ref.t(), iodata()) :: Ref.t()
  def write!(ref, content), do: unwrap!(write(ref, content))

  @doc "Same as `write/3`, raising the error on failure."
  @doc section: :bang
  @spec write!(Disk.t(), Path.t(), iodata()) :: Ref.t()
  @spec write!(Ref.t(), iodata(), keyword()) :: Ref.t()
  def write!(a, b, c), do: unwrap!(write(a, b, c))

  @doc "Same as `write/4`, raising the error on failure."
  @doc section: :bang
  @spec write!(Disk.t(), Path.t(), iodata(), keyword()) :: Ref.t()
  def write!(a, b, c, d), do: unwrap!(write(a, b, c, d))

  @doc "Same as `rm/1`, raising the error on failure."
  @doc section: :bang
  @spec rm!(Ref.t()) :: Ref.t()
  def rm!(ref), do: unwrap!(rm(ref))

  @doc "Same as `rm/2`, raising the error on failure."
  @doc section: :bang
  @spec rm!(Disk.t(), Path.t()) :: Ref.t()
  @spec rm!(Ref.t(), keyword()) :: Ref.t()
  def rm!(a, b), do: unwrap!(rm(a, b))

  @doc "Same as `rm/3`, raising the error on failure."
  @doc section: :bang
  @spec rm!(Disk.t(), Path.t(), keyword()) :: Ref.t()
  def rm!(a, b, c), do: unwrap!(rm(a, b, c))

  @doc "Same as `rm_rf/1`, raising the error on failure."
  @doc section: :bang
  @spec rm_rf!(Ref.t()) :: non_neg_integer()
  def rm_rf!(ref) do
    unwrap!(rm_rf(ref))
  end

  @doc "Same as `rm_rf/2`, raising the error on failure."
  @doc section: :bang
  @spec rm_rf!(Disk.t(), Path.t()) :: non_neg_integer()
  @spec rm_rf!(Ref.t(), keyword()) :: non_neg_integer()
  def rm_rf!(a, b), do: unwrap!(rm_rf(a, b))

  @doc "Same as `rm_rf/3`, raising the error on failure."
  @doc section: :bang
  @spec rm_rf!(Disk.t(), Path.t(), keyword()) :: non_neg_integer()
  def rm_rf!(a, b, c) do
    unwrap!(rm_rf(a, b, c))
  end

  @doc "Same as `cp/2`, raising the error on failure."
  @doc section: :bang
  @spec cp!(Ref.t(), Ref.t() | Path.t()) :: Ref.t()
  def cp!(src, dest), do: unwrap!(cp(src, dest))

  @doc "Same as `cp/3`, raising the error on failure."
  @doc section: :bang
  @spec cp!(Disk.t(), Path.t(), Ref.t() | Path.t()) :: Ref.t()
  @spec cp!(Ref.t(), Ref.t() | Path.t(), keyword()) :: Ref.t()
  def cp!(a, b, c), do: unwrap!(cp(a, b, c))

  @doc "Same as `cp/4`, raising the error on failure."
  @doc section: :bang
  @spec cp!(Disk.t(), Path.t(), Ref.t() | Path.t(), keyword()) :: Ref.t()
  def cp!(a, b, c, d), do: unwrap!(cp(a, b, c, d))

  @doc "Same as `rename/2`, raising the error on failure."
  @doc section: :bang
  @spec rename!(Ref.t(), Ref.t() | Path.t()) :: Ref.t()
  def rename!(src, dest), do: unwrap!(rename(src, dest))

  @doc "Same as `rename/3`, raising the error on failure."
  @doc section: :bang
  @spec rename!(Disk.t(), Path.t(), Ref.t() | Path.t()) :: Ref.t()
  @spec rename!(Ref.t(), Ref.t() | Path.t(), keyword()) :: Ref.t()
  def rename!(a, b, c), do: unwrap!(rename(a, b, c))

  @doc "Same as `rename/4`, raising the error on failure."
  @doc section: :bang
  @spec rename!(Disk.t(), Path.t(), Ref.t() | Path.t(), keyword()) :: Ref.t()
  def rename!(a, b, c, d), do: unwrap!(rename(a, b, c, d))

  @doc "Same as `url/1`, raising the error on failure."
  @doc section: :bang
  @spec url!(Ref.t()) :: String.t()
  def url!(ref), do: unwrap!(url(ref))

  @doc "Same as `url/2`, raising the error on failure."
  @doc section: :bang
  @spec url!(Disk.t(), Path.t()) :: String.t()
  @spec url!(Ref.t(), keyword()) :: String.t()
  def url!(a, b), do: unwrap!(url(a, b))

  @doc "Same as `url/3`, raising the error on failure."
  @doc section: :bang
  @spec url!(Disk.t(), Path.t(), keyword()) :: String.t()
  def url!(a, b, c), do: unwrap!(url(a, b, c))

  @doc "Same as `signed_url/1`, raising the error on failure."
  @doc section: :bang
  @spec signed_url!(Ref.t()) :: String.t()
  def signed_url!(ref), do: unwrap!(signed_url(ref))

  @doc "Same as `signed_url/2`, raising the error on failure."
  @doc section: :bang
  @spec signed_url!(Disk.t(), Path.t()) :: String.t()
  @spec signed_url!(Ref.t(), keyword()) :: String.t()
  def signed_url!(a, b), do: unwrap!(signed_url(a, b))

  @doc "Same as `signed_url/3`, raising the error on failure."
  @doc section: :bang
  @spec signed_url!(Disk.t(), Path.t(), keyword()) :: String.t()
  def signed_url!(a, b, c), do: unwrap!(signed_url(a, b, c))

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

  # Parameters that signed URLs already use on some disk. They're rejected on every disk, so a URL that works on one
  # works on all.
  defp check_query!(query) do
    for {name, _value} <- query, reserved_query_param?(String.downcase(name)) do
      raise ArgumentError, "the :query option can't set #{inspect(name)}, signed URLs use it themselves"
    end

    :ok
  end

  defp reserved_query_param?(name) do
    name in ["expires", "disposition", "signature"] or String.starts_with?(name, ["x-amz-", "response-"])
  end

  # Adapters get `:disposition` as the header value, built here so it's the same on every disk.
  defp put_disposition(opts, ref) do
    case {opts[:disposition], opts[:method]} do
      {nil, _method} ->
        opts

      {_disposition, :put} ->
        raise ArgumentError, "the :disposition option only applies to downloads (method: :get)"

      {disposition, :get} ->
        basename = if match?(%Ref{}, ref), do: Path.basename(ref.path), else: ""

        Keyword.put(opts, :disposition, Fil.Support.ContentDisposition.header(disposition, basename))
    end
  end

  defp run(ref, name, opts, fields \\ []) do
    with {:ok, %Ref{disk: disk, path: path}} <- resolve(ref, name) do
      %Op{disk: disk, name: name, path: path, options: opts}
      |> struct!(fields)
      |> Op.run()
    end
  end

  defp transfer(src, dest, opts, name) do
    with {:ok, src_ref} <- resolve(src, name),
         {:ok, dest_ref} <- resolve_dest(dest, src_ref, name) do
      if src_ref.disk == dest_ref.disk do
        run(src_ref, name, opts, dest: dest_ref.path)
      else
        name
        |> cross_disk(src_ref, dest_ref, opts)
        |> name_op(name)
      end
    end
  end

  # A copy across disks runs as a read, a write and a delete, but the error reports the call the caller made.
  defp name_op({:error, %{op: _} = error}, name), do: {:error, %{error | op: name}}
  defp name_op(result, _name), do: result

  defp cross_disk(:cp, src, dest, opts) do
    with {:ok, content} <- read(src), do: write(dest, content, opts)
  end

  defp cross_disk(:rename, src, dest, opts) do
    with {:ok, dest_ref} <- cross_disk(:cp, src, dest, opts),
         {:ok, _} <- rm(src) do
      {:ok, dest_ref}
    end
  end

  defp resolve(%Ref{} = ref, name) do
    with {:error, error} <- Ref.normalize(ref), do: {:error, %{error | op: name}}
  end

  defp resolve(other, _name) do
    raise ArgumentError,
          "expected a %Fil.Ref{}, got: #{inspect(other)}"
  end

  defp resolve_dest(path, %Ref{disk: disk}, name) when is_binary(path), do: resolve(Ref.new(disk, path), name)
  defp resolve_dest(ref, _src, name), do: resolve(ref, name)

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: raise(error)
end
