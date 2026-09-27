defmodule Fil.NotFoundError do
  @moduledoc """
  The file doesn't exist. Treat it as missing.

  Adapters return it for a missing file, a missing directory and a path that goes through a file (`report.txt/x`),
  which doesn't exist on an object store either.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> {:error, error} = Fil.read(disk, "nope.txt")
      iex> {error.op, error.path, error.reason}
      {:read, "nope.txt", :enoent}
      iex> error.disk == disk
      true
      iex> Exception.message(error)
      ~s|could not read "nope.txt" on #Fil.Disk<memory>: no such file (:enoent)|
  """

  defexception [:op, :path, :disk, :reason]

  @type t :: %__MODULE__{op: Fil.Op.name() | nil, path: String.t() | nil, disk: Fil.Disk.t() | nil, reason: term()}

  @impl Exception
  def message(error), do: Fil.Support.Error.message(error, "no such file")
end

defmodule Fil.AccessDeniedError do
  @moduledoc """
  The storage refused access. Fix the permissions or the credentials.

  Adapters return it for missing file permissions, a read-only filesystem, and credentials or a bucket policy that
  don't allow the operation.
  """

  defexception [:op, :path, :disk, :reason]

  @type t :: %__MODULE__{op: Fil.Op.name() | nil, path: String.t() | nil, disk: Fil.Disk.t() | nil, reason: term()}

  @impl Exception
  def message(error), do: Fil.Support.Error.message(error, "access denied")
end

defmodule Fil.InvalidRequestError do
  @moduledoc """
  The path or the content can't be used here. Use another path or smaller content.

  `Fil` returns it with `reason: :ebadpath` for a path that escapes the disk root, before any adapter or plugin sees
  it. Adapters return it for a file operation on a directory (`:eisdir`), a path under a file (`:enotdir`), a name
  that's too long, and content over the storage's size limit. Plugins return it for content they refuse, such as
  `Fil.Plugin.Thumbnails` for a file that isn't an image (`{:not_an_image, message}`). `Fil.Plug` answers an upload
  that fails with it with a `422`, or a `404` when the path is the problem.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> {:error, %Fil.InvalidRequestError{} = error} = Fil.read(disk, "../escape.txt")
      iex> error.reason
      :ebadpath
  """

  defexception [:op, :path, :disk, :reason]

  @type t :: %__MODULE__{op: Fil.Op.name() | nil, path: String.t() | nil, disk: Fil.Disk.t() | nil, reason: term()}

  @impl Exception
  def message(error), do: Fil.Support.Error.message(error, "invalid request")
end

defmodule Fil.AlreadyExistsError do
  @moduledoc """
  A write with `if_exists: :error` found a file already there. Read that file and decide again.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "once.txt", "first")
      iex> {:error, %Fil.AlreadyExistsError{}} = Fil.write(disk, "once.txt", "second", if_exists: :error)
  """

  defexception [:op, :path, :disk, :reason]

  @type t :: %__MODULE__{op: Fil.Op.name() | nil, path: String.t() | nil, disk: Fil.Disk.t() | nil, reason: term()}

  @impl Exception
  def message(error), do: Fil.Support.Error.message(error, "the file already exists")
end

defmodule Fil.ConflictError do
  @moduledoc """
  The file changed while the operation used it. Read it again and retry.

  `Fil` returns it with `reason: :size_changed` for a write of a stream whose size `Fil` found (a `File.Stream` or a
  stream from `Fil.stream/3`, see the `:size` option of `Fil.write/4`), and for a copy across disks, when the file
  changed size while it was read. For a `File.Stream`, the error has the write's context. For a stream from
  `Fil.stream/3`, it has the context of the file that changed: `op: :read` with the source's path and disk (`op: :cp`
  or `:rename` in a copy across disks).

  `Fil.Adapter.Local` returns it with `reason: :source_changed` for a move with `if_exists: :error` whose source a write
  replaced while it was moved. S3 returns it with `reason: "NoSuchUpload"` for an upload in parts that something else
  aborted while it ran, such as a lifecycle rule. Retrying can help, as with `Fil.UnavailableError`, because the next
  attempt reads the file as it is then, or starts a new upload.
  """

  defexception [:op, :path, :disk, :reason]

  @type t :: %__MODULE__{op: Fil.Op.name() | nil, path: String.t() | nil, disk: Fil.Disk.t() | nil, reason: term()}

  @impl Exception
  def message(error), do: Fil.Support.Error.message(error, "the file changed meanwhile")
end

defmodule Fil.ChecksumMismatchError do
  @moduledoc """
  The content doesn't match its checksum. Upload or download it again.

  Adapters return it for a write with `checksum:` that the storage received damaged, and for a read with
  `verify_checksum: true` whose content doesn't match the stored checksum.
  """

  defexception [:op, :path, :disk, :reason]

  @type t :: %__MODULE__{op: Fil.Op.name() | nil, path: String.t() | nil, disk: Fil.Disk.t() | nil, reason: term()}

  @impl Exception
  def message(error), do: Fil.Support.Error.message(error, "the content doesn't match its checksum")
end

defmodule Fil.StorageFullError do
  @moduledoc """
  There's no space left, or a quota is used up. Free up space or raise the quota.

  Content over a size limit is a `Fil.InvalidRequestError` instead, because freeing space doesn't help with it.
  """

  defexception [:op, :path, :disk, :reason]

  @type t :: %__MODULE__{op: Fil.Op.name() | nil, path: String.t() | nil, disk: Fil.Disk.t() | nil, reason: term()}

  @impl Exception
  def message(error), do: Fil.Support.Error.message(error, "no space left")
end

defmodule Fil.UnsupportedError do
  @moduledoc """
  The disk can't do this operation. Attach a plugin or use another disk.

  `:op` is the operation. `Fil` returns it with `reason: :no_callback` for a URL on an adapter without that callback
  (attach `Fil.Plugin.URL`), and S3 with `reason: :missing_credentials` for a signed URL on a disk without credentials.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> {:error, error} = Fil.url(disk, "a.txt")
      iex> Exception.message(error)
      ~s|could not build a URL for "a.txt" on #Fil.Disk<memory>: not supported by this disk (:no_callback)|
  """

  defexception [:op, :path, :disk, :reason]

  @type t :: %__MODULE__{op: Fil.Op.name() | nil, path: String.t() | nil, disk: Fil.Disk.t() | nil, reason: term()}

  @impl Exception
  def message(error), do: Fil.Support.Error.message(error, "not supported by this disk")
end

defmodule Fil.ConfigurationError do
  @moduledoc """
  The disk's options don't match the storage. Fix the disk's options.

  Every call on the disk fails until they change. S3 returns it with `reason: {:wrong_region, region}` when the bucket
  is in another region than the disk's `:region`, and with `reason: "NoSuchBucket"` when the bucket doesn't exist.
  """

  defexception [:op, :path, :disk, :reason]

  @type t :: %__MODULE__{op: Fil.Op.name() | nil, path: String.t() | nil, disk: Fil.Disk.t() | nil, reason: term()}

  @impl Exception
  def message(error), do: Fil.Support.Error.message(error, "the disk is misconfigured")
end

defmodule Fil.UnavailableError do
  @moduledoc """
  The storage didn't answer, or asked to wait. Try again later.

  Adapters return it for a timeout, a closed connection, a server error, throttling and too many open files. It's one of
  the two errors where retrying may help, with `Fil.ConflictError`. `Fil` doesn't retry (for now), because only the
  caller knows whether a failed mutation is safe to repeat. The one exception is a part of an S3 upload in parts, which
  is sent once more, a second later: nobody sees it before the upload completes.
  """

  defexception [:op, :path, :disk, :reason]

  @type t :: %__MODULE__{op: Fil.Op.name() | nil, path: String.t() | nil, disk: Fil.Disk.t() | nil, reason: term()}

  @impl Exception
  def message(error), do: Fil.Support.Error.message(error, "the storage is unavailable")
end

defmodule Fil.UnknownError do
  @moduledoc """
  The storage reported something no other error describes. Log it and fail.

  Adapters return it for storage responses nobody has mapped yet, with the storage's own term in `:reason`. Please
  report it, so it can be mapped to one of the other errors.
  """

  defexception [:op, :path, :disk, :reason]

  @type t :: %__MODULE__{op: Fil.Op.name() | nil, path: String.t() | nil, disk: Fil.Disk.t() | nil, reason: term()}

  @impl Exception
  def message(error), do: Fil.Support.Error.message(error, "unexpected error")
end
