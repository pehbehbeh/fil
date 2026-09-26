defmodule Fil.Stat do
  @moduledoc """
  Metadata about a file or directory.

  A field is `nil` when the storage doesn't know it. Object stores have no directories to stat, and the local filesystem
  stores no content type.

    * `:size`: size in bytes (`nil` for directories on object stores)
    * `:type`: `:regular` or `:directory`
    * `:mtime`: last modification time as a `DateTime` in UTC
    * `:etag`: an opaque version tag. `Fil.Adapter.Local` derives a weak one (`"size-mtime"`); S3 returns the object's
      ETag
    * `:content_type`: the stored MIME type, when the storage keeps one
    * `:checksum`: `{algorithm, checksum}`, with the checksum base64 encoded the way S3 encodes it. Only filled in when
      `Fil.stat/3` is called with the `:checksum` option
  """

  defstruct [:size, :type, :mtime, :etag, :content_type, :checksum]

  @type type :: :regular | :directory

  @type t :: %__MODULE__{
          size: non_neg_integer() | nil,
          type: type() | nil,
          mtime: DateTime.t() | nil,
          etag: String.t() | nil,
          content_type: String.t() | nil,
          checksum: {:sha256 | :sha1 | :crc32, String.t()} | nil
        }
end
