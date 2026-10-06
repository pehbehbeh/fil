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
  alias Fil.Support.Content
  alias Fil.Support.Sized
  alias Fil.Support.Telemetry

  @typedoc """
  An error from an adapter or from `Fil` itself. Each struct stands for what the caller can do about it, and means the
  same on every adapter; see [Errors in `Fil.Adapter`](Fil.Adapter.html#module-errors).
  """
  @type error ::
          Fil.NotFoundError.t()
          | Fil.AccessDeniedError.t()
          | Fil.InvalidRequestError.t()
          | Fil.InvalidContentError.t()
          | Fil.AlreadyExistsError.t()
          | Fil.ConflictError.t()
          | Fil.ChecksumMismatchError.t()
          | Fil.StorageFullError.t()
          | Fil.UnsupportedError.t()
          | Fil.ConfigurationError.t()
          | Fil.UnavailableError.t()
          | Fil.UnknownError.t()

  @typedoc "A result. Plugins may return their own exceptions, so an error isn't always one of `t:error/0`."
  @type result(value) :: {:ok, value} | {:error, error() | Exception.t()}

  @typedoc """
  What `write/4` takes: iodata, a stream of it (any `Enumerable` that isn't a list, such as a `Stream` or a
  `File.Stream`), or `{:file, path}` for a file on the local filesystem. A list is always iodata.
  """
  @type content :: iodata() | Enumerable.t() | {:file, String.t()}

  @typedoc "A plugin callback: a function or a `{module, function}` pair. See the [Plugins guide](plugins.md)."
  @type plugin_callback :: (Op.t(), (Op.t() -> Op.t()), keyword() -> Op.t()) | {module(), atom()}

  @root "."

  @checksums Checksum.algorithms()

  @write_options [
    if_exists: [
      type: {:in, [:overwrite, :error]},
      default: :overwrite,
      doc: """
      What to do if the file (for a copy or a move, the destination) already exists. `:overwrite` replaces it. `:error`
      writes nothing and returns a `Fil.AlreadyExistsError`, like `File.write/3` with `[:exclusive]`, and a move leaves
      the source where it is. That check is atomic on local disk, in memory and on AWS S3, so two processes can't both
      create the file. Some S3-compatible servers ignore it.
      """
    ],
    content_type: [
      type: :string,
      doc: "Stored as the object's content type where the storage keeps one."
    ],
    checksum: [
      type: {:in, @checksums},
      doc: """
      Computes a checksum of the content with this algorithm (`:sha256`, `:sha1` or `:crc32`) and sends it along, where
      the storage supports it. S3 rejects the write with `Fil.ChecksumMismatchError` if the content it received doesn't
      match, and stores the checksum with the object. The local filesystem stores nothing. S3 uploads a stream with a
      checksum in parts, and for SHA-1 and SHA-256 then stores a checksum of the parts' checksums instead of the file's,
      so use `:crc32` for large streams whose checksum you need later (see
      [Checksums in `Fil.Adapter.S3`](Fil.Adapter.S3.html#module-checksums)).
      """
    ]
  ]

  # Copies take the write options except `:size`, which only describes content the caller passes.
  @transfer_schema NimbleOptions.new!(@write_options)

  @size_option [
    size: [
      type: {:or, [:non_neg_integer, {:in, [:unknown]}]},
      doc: """
      The size of the content in bytes. S3 sends a stream of known size as it's read, in one request, and uploads one
      without a size in parts. Content of another size raises `ArgumentError` and writes nothing, whatever the plugins
      do with it. Plugins that transform the content drop the size.

      Without it, `{:file, path}` has the size of its file, and so does a `File.Stream` that reads bytes
      (`File.stream!(path, 65_536)`, not lines) without a mode that changes them (`:compressed`, `:trim_bom`, an
      encoding), minus its `:read_offset`. A stream from `stream/3` has the size its adapter found. When such content
      turns out to have another size, because the file changed while it was read, the write returns `Fil.ConflictError`
      and writes nothing.

      `size: :unknown` writes the stream as it's read, without a size (S3 uploads it in parts). Use it for a file that
      grows while it's written, such as a log that's still appended to, which is then written as far as it was read,
      and for files whose stat size may be wrong, such as those under `/sys` or on a network or FUSE file system.
      """
    ]
  ]

  @write_schema NimbleOptions.new!(@write_options ++ @size_option)

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
                   they differ. Content without a stored checksum (see the `:checksum` option of `write/4`), or on
                   storage that stores none, is returned unchecked. A stored checksum covers the whole file, so it can't
                   be combined with `:offset` or `:length`.
                   """
                 ],
                 offset: [
                   type: :non_neg_integer,
                   doc: """
                   Reads from this byte on, counted from 0. The storage reads only the part that's asked for (S3 with a
                   `Range` header). From the end of the file on, the content is empty.
                   """
                 ],
                 length: [
                   type: :pos_integer,
                   doc: """
                   Reads at most this many bytes, from `:offset` on. Without it, the read goes to the end of the file.
                   Content that ends sooner is shorter, without an error. Plugins that transform the content on the
                   way back get the whole file, and the range is cut from what they return, so offsets count bytes of
                   the content as you get it (see [Plugins](plugins.md#ranges)).
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
                         under another name, which can be any UTF-8 string. Without it, S3 sends the disposition an
                         object was uploaded with outside `Fil`, and the other disks send none.
                         """
                       ],
                       content_type: [
                         type: :string,
                         doc: """
                         The content type of the upload, for `method: :put` only. The client has to send it as the
                         `content-type` header, and the file is stored with it. See Uploads below.
                         """
                       ],
                       size: [
                         type: :non_neg_integer,
                         doc: """
                         The size of the upload in bytes, for `method: :put` only. The request's `content-length` has
                         to be the same. Browsers set it from the body.
                         """
                       ],
                       if_exists: [
                         type: {:in, [:error, :overwrite]},
                         doc: """
                         What an upload does if a file is already at the path, for `method: :put` only. With `:error`
                         the client sends `if-none-match: *`, and an upload that finds a file there fails and leaves it
                         alone, so the URL writes a file once and can't replace it later. Without it (or with
                         `:overwrite`), an upload replaces the file.
                         """
                       ],
                       query: [
                         type: {:list, {:tuple, [:string, :string]}},
                         default: [],
                         doc: """
                         Extra query parameters, e.g. `[{"trackingInfo", "42"}]`, for a page that reads them from its
                         own URL. They're signed with the URL, so they can't be changed or added afterwards. Names that
                         signed URLs use themselves on some disk raise on every disk: `expires`, `disposition`,
                         `content_type`, `size`, `if_exists`, `signature`, and anything starting with `X-Amz-` or
                         `response-`.
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
  Creates a temporary directory and returns a ref to it. Shorthand for `Fil.Tmp.new/0`, which lists what it raises.

      iex> Fil.tmp()
      #Fil.Ref<local:.>

  The directory is removed when the calling process exits, see `Fil.Tmp`.
  """
  @doc section: :building
  @spec tmp() :: Ref.t()
  defdelegate tmp(), to: Fil.Tmp, as: :new

  @doc """
  Creates a temporary directory and returns a ref to the file `name` in it. Shorthand for `Fil.Tmp.new/1`, which lists
  the names it takes.

      iex> Fil.tmp("report.pdf")
      #Fil.Ref<local:report.pdf>

  The directory is removed when the calling process exits, see `Fil.Tmp`.
  """
  @doc section: :building
  @spec tmp(Path.t()) :: Ref.t()
  defdelegate tmp(name), to: Fil.Tmp, as: :new

  @doc """
  Attaches a plugin callback to a disk under a name.

      iex> disk =
      ...>   Fil.disk(adapter: Fil.Adapter.Memory)
      ...>   |> Fil.attach(:shout, fn op, next, _opts ->
      ...>     op |> Fil.Op.update_content(iodata: &String.upcase/1) |> next.()
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
      iex> Fil.read(disk, "hello.txt", offset: 1, length: 3)
      {:ok, "orl"}
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
    opts = validate_read!(opts)

    run(ref, :read, opts)
  end

  @doc "Reads a file. See `read/1`."
  @doc section: :operations
  @spec read(Disk.t(), Path.t(), keyword()) :: result(binary())
  def read(%Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
    read(Ref.new(disk, path), opts)
  end

  @doc """
  Streams a file: checks that it can be read and returns its content as a stream of binaries.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "hello.txt", "World")
      iex> {:ok, hello} = Fil.stream(disk, "hello.txt")
      iex> Enum.join(hello)
      "World"
      iex> {:error, %Fil.NotFoundError{path: "nope.txt"}} = Fil.stream(disk, "nope.txt")

  The file is read only when the stream is enumerated, and again every time it is, so a stream can be read by another
  process, more than once, or not at all. The size of the chunks depends on the adapter and says nothing about the
  content. An error after the check, such as a file deleted in between or a lost connection, raises the same error
  struct `read/2` would return. With `verify_checksum: true`, a mismatch raises `Fil.ChecksumMismatchError` at the
  latest after the last chunk, so treat the content as unverified until then.

  A stream can go straight into a write, to the same disk or another one:

      {:ok, backup} = Fil.stream(s3, "backups/2026-09.tar")
      Fil.write(local, "restore/2026-09.tar", backup)

  With `:offset` and `:length`, the stream reads only that part of the file, as `Fil.Plug` does for a `Range` request:

      {:ok, clip} = Fil.stream(disk, "videos/intro.mp4", offset: 1_048_576, length: 65_536)

  ## Options

  #{NimbleOptions.docs(@read_schema)}
  """
  @doc section: :operations
  @spec stream(Ref.t()) :: result(Enumerable.t())
  def stream(ref), do: stream(ref, [])

  @doc "Streams a file. See `stream/1`."
  @doc section: :operations
  @spec stream(Disk.t(), Path.t()) :: result(Enumerable.t())
  @spec stream(Ref.t(), keyword()) :: result(Enumerable.t())
  def stream(%Disk{} = disk, path) when is_binary(path), do: stream(Ref.new(disk, path), [])

  def stream(ref, opts) when is_list(opts) do
    opts = validate_read!(opts)

    # The chunks are binaries, even where a plugin's transform returns iodata.
    with {:ok, content} <- run(ref, :read, opts, streaming: true), do: {:ok, Content.chunks(content)}
  end

  @doc "Streams a file. See `stream/1`."
  @doc section: :operations
  @spec stream(Disk.t(), Path.t(), keyword()) :: result(Enumerable.t())
  def stream(%Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
    stream(Ref.new(disk, path), opts)
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

  `content` is iodata, a stream of it, or `{:file, path}` for a file on the local filesystem (see `t:content/0`). A
  stream is written as it's read, without holding the content in memory at once, and a file is only there once the
  stream has ended. If reading the stream raises, nothing is written: one of `Fil`'s errors (from a stream of
  `stream/3`, say) comes back as `{:error, error}`, and any other exception propagates. S3 sends a stream whose size it
  knows in one request, and uploads any other in parts. `Fil` finds the size of a local file, of a `File.Stream` of
  bytes and of a stream from `stream/3` itself; for any other stream, pass it with `:size` if you know it.

  `{:file, path}` streams the file in chunks of 64 KiB, the same as `File.stream!(path, 65_536)`. A file that doesn't
  exist, or a directory, raises `File.Error` before anything runs, as it's the caller's input, like the content itself.
  Any other failure to read it raises `File.Error` while it's written, as a `File.Stream` does, and nothing is written.
  The local file's name plays no part: the content type comes from `:content_type` or from `Fil.Plugin.ContentType`,
  which looks at the destination path.

  ## Options

  #{NimbleOptions.docs(@write_schema)}

  ## Examples

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> {:ok, report} = Fil.write(disk, "reports/q3.pdf", ["%PDF", "-1.7"])
      iex> report
      #Fil.Ref<memory:reports/q3.pdf>
      iex> {:error, %Fil.AlreadyExistsError{reason: :eexist}} =
      ...>   Fil.write(disk, "reports/q3.pdf", "again", if_exists: :error)
      iex> {:ok, _} = Fil.write(disk, "numbers.txt", Stream.map(1..3, &Integer.to_string/1))
      iex> Fil.read(disk, "numbers.txt")
      {:ok, "123"}

  A local file, such as an upload's temporary file, is written as it's read:

      Fil.write(s3, "videos/intro.mp4", {:file, "intro.mp4"})
      Fil.write(s3, "documents/upload.pdf", {:file, upload.path})

  """
  @doc section: :operations
  @spec write(Ref.t(), content()) :: result(Ref.t())
  def write(ref, content), do: write(ref, content, [])

  @doc "Writes a file. See `write/2`."
  @doc section: :operations
  @spec write(Disk.t(), Path.t(), content()) :: result(Ref.t())
  @spec write(Ref.t(), content(), keyword()) :: result(Ref.t())
  def write(%Disk{} = disk, path, content) when is_binary(path) do
    write(Ref.new(disk, path), content, [])
  end

  def write(ref, content, opts) when is_list(opts) do
    opts = validate!(opts, @write_schema)
    :ok = Content.validate!(content)

    {content, write_opts, size} =
      content
      |> Content.from_file!()
      |> check_content!(opts)

    run(ref, :write, write_opts, [content: content], size)
  end

  @doc "Writes a file. See `write/2`."
  @doc section: :operations
  @spec write(Disk.t(), Path.t(), content(), keyword()) :: result(Ref.t())
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

  Within one disk, `Fil` uses the adapter's native copy. Across disks, it streams the file from the source to the
  destination (see `stream/3`), with the size the source's adapter found, so S3 sends the upload in one request too.
  When a plugin on the source changes the content, or the adapter doesn't know the size, S3 uploads the file in parts.
  A source that changes size while it's copied fails the copy with a `Fil.ConflictError`. The destination may be a
  ref, or a bare path on the source's disk.

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
    transfer(src, dest, validate!(opts, @transfer_schema), :cp)
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
    transfer(src, dest, validate!(opts, @transfer_schema), :rename)
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

  A disk can set defaults for `:expires_in`, `:disposition` and `:if_exists` with the `:signed_url` option of
  `Fil.disk/1`. The options of a call replace them.

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

  ## Uploads

  A URL signed with `method: :put` takes a `PUT` with the file as its body. `:content_type`, `:size` and
  `if_exists: :error` tie it to one upload, because the URL's signature covers them:

      Fil.signed_url(disk, "avatars/7f3a.png",
        method: :put,
        content_type: "image/png",
        size: 48_213,
        if_exists: :error
      )

  The client then has to send these headers, on every disk:

    * `content-type: image/png`
    * `content-length: 48213`, which browsers set from the body (a script can't set it)
    * `if-none-match: *`

  A request with another content type or length is refused with a `403`, by S3 and by `Fil.Plug`. With
  `if_exists: :error`, an upload to a path that has a file fails and leaves the file alone: S3 answers `412`,
  `Fil.Plug` answers `409`. So the URL writes once, and nobody who has it can replace the file later. Some
  S3-compatible servers ignore `if-none-match` (see `Fil.Adapter.S3`).
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
    opts =
      ref
      |> signed_url_defaults(opts[:method])
      |> Keyword.merge(opts)
      |> validate!(@signed_url_schema)

    check_disposition!(opts)
    check_upload_options!(opts)
    check_query!(opts[:query])

    # The file name for `disposition: :attachment` comes from the normalized path, so `docs/..` doesn't become `..`.
    with {:ok, ref} <- resolve(ref, :signed_url) do
      run(ref, :signed_url, put_disposition(opts, Path.basename(ref.path)))
    end
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

  @doc "Same as `stream/1`, raising the error on failure."
  @doc section: :bang
  @spec stream!(Ref.t()) :: Enumerable.t()
  def stream!(ref), do: unwrap!(stream(ref))

  @doc "Same as `stream/2`, raising the error on failure."
  @doc section: :bang
  @spec stream!(Disk.t(), Path.t()) :: Enumerable.t()
  @spec stream!(Ref.t(), keyword()) :: Enumerable.t()
  def stream!(a, b), do: unwrap!(stream(a, b))

  @doc "Same as `stream/3`, raising the error on failure."
  @doc section: :bang
  @spec stream!(Disk.t(), Path.t(), keyword()) :: Enumerable.t()
  def stream!(a, b, c), do: unwrap!(stream(a, b, c))

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
  @spec write!(Ref.t(), content()) :: Ref.t()
  def write!(ref, content), do: unwrap!(write(ref, content))

  @doc "Same as `write/3`, raising the error on failure."
  @doc section: :bang
  @spec write!(Disk.t(), Path.t(), content()) :: Ref.t()
  @spec write!(Ref.t(), content(), keyword()) :: Ref.t()
  def write!(a, b, c), do: unwrap!(write(a, b, c))

  @doc "Same as `write/4`, raising the error on failure."
  @doc section: :bang
  @spec write!(Disk.t(), Path.t(), content(), keyword()) :: Ref.t()
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

  defp validate_read!(opts) do
    opts = validate!(opts, @read_schema)

    if opts[:verify_checksum] and Fil.Support.ByteRange.from_options(opts) != nil do
      raise ArgumentError, "verify_checksum: true checks the whole file and can't be combined with :offset or :length"
    end

    opts
  end

  # The caller's content is checked before plugins see it, so a plugin that collects, transforms or replaces it doesn't
  # hide bad content or a wrong size. Iodata is measured once, here, and its size is also the `:bytes` of the write's
  # events. A stream is checked against `:size` while it's read (`Fil.Support.Content.sized/3`). Without `:size`, a
  # stream whose size is known before it's read gets it (`Fil.Support.Content.known_size/1`), so S3 can send it in one
  # request, and one that turns out to have another size is a conflict instead of a bad argument: the file changed. A
  # size found this way stays with the stream (`Fil.Support.Sized`), so `Fil.Op` can tell it from one a caller or a
  # plugin declared. Returns the content, the options and the size, if it's known. `size: :unknown` only turns off
  # finding the size, so it's dropped here, and plugins and adapters never see it.
  defp check_content!(content, opts) do
    case Keyword.pop(opts, :size) do
      {:unknown, without_size} -> check_content!(content, without_size, :unknown)
      {size, _opts} -> check_content!(content, opts, size)
    end
  end

  defp check_content!(content, opts, size) do
    cond do
      Content.iodata?(content) -> {content, opts, check_iodata_size!(content, size)}
      is_integer(size) -> {Content.sized(content, size), opts, size}
      size == :unknown -> {content, opts, nil}
      true -> check_known_size(content, opts)
    end
  end

  defp check_iodata_size!(content, size) do
    case iodata_length!(content) do
      length when size in [nil, :unknown, length] -> length
      length -> raise ArgumentError, "the content has #{length} bytes, but the :size option is #{size}"
    end
  end

  defp iodata_length!(content) do
    IO.iodata_length(content)
  rescue
    ArgumentError ->
      reraise ArgumentError,
              "expected the content to be iodata, an enumerable of iodata or {:file, path}, " <>
                "got a list that isn't iodata: " <> inspect(content),
              __STACKTRACE__
  end

  defp check_known_size(stream, opts) do
    case Content.known_size(stream) do
      {size, mismatch} ->
        sized = %Sized{stream: Content.sized(stream, size, mismatch), size: size}
        {sized, Keyword.put(opts, :size, size), size}

      nil ->
        {stream, opts, nil}
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
    name in ["expires", "disposition", "content_type", "size", "if_exists", "signature"] or
      String.starts_with?(name, ["x-amz-", "response-"])
  end

  defp check_upload_options!(opts) do
    if opts[:method] == :get do
      for name <- [:content_type, :size, :if_exists], Keyword.has_key?(opts, name) do
        raise ArgumentError, "the #{inspect(name)} option only applies to uploads (method: :put)"
      end
    end

    :ok
  end

  # The disk's `:signed_url` defaults that fit the method. A call's own options aren't filtered, so they still raise.
  defp signed_url_defaults(%Ref{disk: %Disk{signed_url: defaults}}, :put), do: Keyword.delete(defaults, :disposition)
  defp signed_url_defaults(%Ref{disk: %Disk{signed_url: defaults}}, _get), do: Keyword.delete(defaults, :if_exists)
  defp signed_url_defaults(_not_a_ref, _method), do: []

  defp check_disposition!(opts) do
    case {opts[:disposition], opts[:method]} do
      {nil, _method} -> :ok
      {_disposition, :put} -> raise ArgumentError, "the :disposition option only applies to downloads (method: :get)"
      {{:attachment, ""}, :get} -> raise ArgumentError, "the file name of the :disposition option can't be empty"
      {_disposition, :get} -> :ok
    end
  end

  # Adapters get `:disposition` as the header value, built here so it's the same on every disk.
  defp put_disposition(opts, basename) do
    case opts[:disposition] do
      nil -> opts
      disposition -> Keyword.put(opts, :disposition, Fil.Support.ContentDisposition.header(disposition, basename))
    end
  end

  defp run(ref, name, opts, fields \\ [], size \\ nil) do
    with {:ok, %Ref{disk: disk, path: path}} <- resolve(ref, name) do
      %Op{disk: disk, name: name, path: path, options: opts}
      |> struct!(fields)
      |> Op.run(size)
    end
  end

  defp transfer(%Ref{} = src, dest, opts, name) do
    dest = dest_ref(dest, src)
    rejection = {%Op{disk: src.disk, name: name, path: src.path, dest: dest.path}, %{dest_disk: dest.disk}}

    with {:ok, src_ref} <- resolve(src, name, rejection),
         {:ok, dest_ref} <- resolve(dest, name, rejection) do
      if src_ref.disk == dest_ref.disk do
        run(src_ref, name, opts, dest: dest_ref.path)
      else
        across_disks(src_ref, dest_ref, opts, name)
      end
    end
  end

  defp transfer(other, _dest, _opts, _name), do: not_a_ref!(other)

  # A copy across disks is an operation of its own for `Fil.Telemetry`, with the read, the write and the delete nested
  # in it.
  defp across_disks(src, dest, opts, name) do
    op = %Op{disk: src.disk, name: name, path: src.path, dest: dest.path}

    Telemetry.span(op, [metadata: %{dest_disk: dest.disk}], fn _op, _metadata ->
      name
      |> cross_disk(src, dest, opts)
      |> name_op(name)
    end)
  end

  # A copy across disks runs as a read, a write and a delete, but the error reports the call the caller made.
  defp name_op({:error, %{op: _} = error}, name), do: {:error, %{error | op: name}}
  defp name_op(result, _name), do: result

  # The write sends the stream with the size the source's adapter found, if it did (see `check_content!/2`). An error
  # the source raises while it's streamed, or a source that changes size meanwhile, comes back from the write with the
  # source's context.
  defp cross_disk(:cp, src, dest, opts) do
    with {:ok, content} <- stream(src), do: write(dest, content, opts)
  end

  defp cross_disk(:rename, src, dest, opts) do
    with {:ok, dest_ref} <- cross_disk(:cp, src, dest, opts),
         {:ok, _} <- rm(src) do
      {:ok, dest_ref}
    end
  end

  defp resolve(%Ref{} = ref, name), do: resolve(ref, name, {%Op{disk: ref.disk, name: name, path: ref.path}, %{}})
  defp resolve(other, _name), do: not_a_ref!(other)

  # A path that escapes the disk root never reaches `Fil.Op.run/1`, but it's still an operation that failed, so it emits
  # the events of one, described by `rejection`: the op and extra metadata.
  defp resolve(ref, name, {op, extra}) do
    case Ref.normalize(ref) do
      {:ok, ref} -> {:ok, ref}
      {:error, error} -> Telemetry.span(op, [metadata: extra], fn _op, _metadata -> {:error, %{error | op: name}} end)
    end
  end

  defp dest_ref(path, %Ref{disk: disk}) when is_binary(path), do: Ref.new(disk, path)
  defp dest_ref(%Ref{} = ref, _src), do: ref
  defp dest_ref(other, _src), do: not_a_ref!(other)

  defp not_a_ref!(other), do: raise(ArgumentError, "expected a %Fil.Ref{}, got: #{inspect(other)}")

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: raise(error)
end
