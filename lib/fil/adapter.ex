defmodule Fil.Adapter do
  @moduledoc """
  The contract every adapter implements.

  An adapter is a stateless module. `c:init/1` turns the options into a state term once, when `Fil.disk/1` builds the
  disk, and every other callback gets that state. There's no process to start, supervise or shut down.

  [Plugins](plugins.md) run in `Fil` before an adapter is called, so an adapter never needs to know about them.

  Two rules keep adapters small:

    * Mutations return a bare `:ok`. `Fil` wraps results into `{:ok, %Fil.Ref{}}` and handles cross-disk copies, so
      adapters don't have to. Errors are `Fil`'s error structs (see [Errors](#module-errors)), and `Fil` fills in the
      operation and the path.
    * Paths arrive normalized and jailed. `Fil` has already resolved `.` and `..`, collapsed repeated `/` and rejected
      escapes, and `"."` means the disk root. Adapters may check again (`Fil.Adapter.Local` does), but they don't need
      to parse paths defensively.

  ## Contract

  `Fil` uses the vocabulary of Elixir's `File` module, but every adapter behaves like an object store, so the semantics
  differ where the two disagree. Beyond the callback signatures, this is the contract:

  | Situation | `File` | Every `Fil` adapter |
  | --- | --- | --- |
  | `c:write/4` into a missing directory | `{:error, :enoent}` | creates the missing parents |
  | exclusive `c:write/4` on an existing file | `{:error, :eexist}` | `{:error, %Fil.AlreadyExistsError{}}` |
  | `c:cp/4` or `c:rename/4` into a missing directory | `{:error, :enoent}` | creates the missing parents |
  | `c:rm/3` on a missing file | `{:error, :enoent}` | `:ok` |
  | `c:ls/3` on a missing directory | `{:error, :enoent}` | `{:ok, []}` |
  | `c:ls/3` results | names, one level deep | `{path, stat}` pairs, one level deep; only files with `recursive: true` |
  | `c:rm_rf/3` results | `{:ok, removed_paths}`, directories included | `{:ok, count}` of removed files |
  | `c:rm_rf/3` on `"reports"` | the directory `reports` | `reports` and all of `reports/`, not `reports.txt` |
  | paths | relative to the working directory, or absolute | relative to the disk root, never above it |

  An exclusive write is `File.write/3` with `[:exclusive]`, and `c:write/4` with `if_exists: :error`.

  Where an adapter returns `:ok`, the `Fil` function returns `{:ok, %Fil.Ref{}}`, and `Fil.ls/2` turns the pairs
  into refs.

  Options that `File` has no equivalent for:

    * `checksum:` on `c:write/4` sends a checksum of the content where the storage keeps one, and storage that finds
      the content doesn't match fails with `Fil.ChecksumMismatchError`. Storage without checksums ignores the option
    * `checksum:` on `c:stat/3` fills in `Fil.Stat`'s `:checksum`, from the storage or computed from the content
    * `verify_checksum: true` on `c:read/3` fails with `Fil.ChecksumMismatchError` when the content doesn't match a
      stored checksum

  `Fil.AdapterCase` (internal for now) tests this contract against a live disk.

  ## Where the adapters differ

  Every adapter `Fil` ships reads, writes, lists, copies and checks checksums, and every disk builds public and signed
  URLs (S3 itself, the others with `Fil.Plugin.URL`), so code written against one disk runs on the others. What's left
  are edge cases:

  | Situation | `Fil.Adapter.Local` | `Fil.Adapter.S3` | `Fil.Adapter.Memory` |
  | --- | --- | --- | --- |
  | directories | exist on their own, can be empty | prefixes only | prefixes only |
  | `c:rm/3` on a directory | `Fil.InvalidRequestError` | `:ok`, removes nothing | `:ok`, removes nothing |
  | `c:read/3` or `c:cp/4` of a directory | `Fil.InvalidRequestError` | `Fil.NotFoundError` | `Fil.NotFoundError` |
  | `c:write/4` to `report.txt/x` when `report.txt` is a file | `Fil.InvalidRequestError` | writes both | writes both |
  | `c:stat/3` with `checksum:` | computed from the content | the checksum the write stored, or `nil` | same as S3 |
  | `verify_checksum: true` | ignored | compared with the stored checksum | compared with the stored checksum |
  | `:content_type` in a stat | `nil` (`Fil.Plug` guesses from the extension) | from the write | from the write |
  | `:etag` in a stat | weak, `"size-mtime"` | from S3 | MD5 of the content |
  | URLs | with `Fil.Plugin.URL`, served by `Fil.Plug` | by S3 | with the plugin, served by `Fil.Plug` |

  ## Errors

  Every error is an exception struct, listed under Errors in the sidebar. Which struct you get tells you what to do
  next, and it's the same on every adapter: a missing file is a `Fil.NotFoundError` on the local disk and on S3.
  `Fil.UnavailableError` is the only one where retrying can help.

  Every error has the same fields:

    * `:op`: the operation, such as `:read` (see `t:Fil.Op.name/0`)
    * `:path`: the path as the caller passed it (before plugins rewrote it), relative to the disk root. For a copy
      or a move, the side that failed
    * `:disk`: the `Fil.Disk`. `Fil.ref(error.disk, error.path)` is a ref to the file, and
      `Fil.Disk.adapter(error.disk)` returns the adapter
    * `:reason`: the exact cause, as the storage reported it, in the form its adapter documents (`:enoent` from
      `Fil.Adapter.Local`, `"NoSuchKey"` from `Fil.Adapter.S3`). `nil` only when a plugin built the error

  `Fil` returns two of them itself: `Fil.InvalidRequestError` with `reason: :ebadpath` for a path that escapes the disk
  root, and `Fil.UnsupportedError` with `reason: :no_callback` for a URL on an adapter without that callback.

  An adapter returns the struct with `:reason` set and leaves `:op`, `:path` and `:disk` `nil`: `Fil` fills in
  those that are still `nil`. An adapter that fails on the destination of a `c:cp/4` or `c:rename/4` sets `:path` to
  the destination, because `Fil` fills in the source. Anything in `{:error, _}` that isn't an exception raises
  `ArgumentError`.

  A failure that fits a struct is returned as that struct, whatever the storage reported: `Fil.Adapter.Local` turns
  the `:eperm` that deleting a directory gives into `:eisdir`, and `Fil.Adapter.S3` checks a copy that the server
  refused with a plain `400` for a missing source. Directories only exist as prefixes on S3 and in memory, so directory
  errors only come from storage with directories of its own (see
  [Where the adapters differ](#module-where-the-adapters-differ)).
  """

  alias Fil.Stat

  @type state :: term()
  @type path :: String.t()
  @type opts :: keyword()
  @type error :: {:error, Fil.error()}

  @doc """
  Validates options and builds the state passed to every other callback.

  Not an operation, so an error is anything that explains the bad option, such as a `NimbleOptions.ValidationError`.
  `Fil.Disk.new/1` raises it as an `ArgumentError`.
  """
  @callback init(opts()) :: {:ok, state()} | {:error, term()}

  @doc "Reads the whole file."
  @callback read(state(), path(), opts()) :: {:ok, binary()} | error()

  @doc "Writes `content`, creating parent directories as needed."
  @callback write(state(), path(), iodata(), opts()) :: :ok | error()

  @doc "Deletes a file. Idempotent: a missing file is still `:ok`."
  @callback rm(state(), path(), opts()) :: :ok | error()

  @doc "Returns metadata for a file or directory."
  @callback stat(state(), path(), opts()) :: {:ok, Stat.t()} | error()

  @doc """
  Lists `prefix`, one level deep unless `recursive: true`.

  Returns `{path, stat}` pairs. Paths are relative to the disk root, and each stat holds what the listing returned.
  `Fil` turns the pairs into `Fil.Ref`s; adapters don't build those themselves.
  """
  @callback ls(state(), path(), opts()) :: {:ok, [{path(), Stat.t()}]} | error()

  @doc """
  Copies a file within the same disk.

  A copy across two disks doesn't call this: `Fil` reads the file with `c:read/3` on the source adapter and writes it
  with `c:write/4` on the destination adapter.
  """
  @callback cp(state(), path(), path(), opts()) :: :ok | error()

  @doc """
  Moves a file within the same disk.

  A move across two disks doesn't call this: `Fil` copies the file as described in `c:cp/4`, then removes the source
  with `c:rm/3`.
  """
  @callback rename(state(), path(), path(), opts()) :: :ok | error()

  @doc "Removes everything under `prefix` and returns the number of deleted files."
  @callback rm_rf(state(), path(), opts()) :: {:ok, non_neg_integer()} | error()

  @doc """
  Builds the public URL of a file, without a signature.

  Optional. Adapters whose storage has no URLs leave it out, and `Fil.url/2` then returns a `Fil.UnsupportedError`.
  `Fil.Plugin.URL` builds URLs for those disks, and `Fil.Plug` serves them.
  """
  @callback url(state(), path(), opts()) :: {:ok, String.t()} | error()

  @doc """
  Builds a URL that grants temporary access to a file.

  Optional. Adapters whose storage can't sign URLs leave it out, and `Fil.signed_url/2` then returns a
  `Fil.UnsupportedError`. `Fil.Plugin.URL` signs URLs for those disks, and `Fil.Plug` serves them.

  `opts` has `:method` and `:expires_in` as `Fil.signed_url/3` validated them, and for a download with `disposition:`,
  `:disposition` as the finished `content-disposition` header value. The storage has to send that header with the
  download, and the URL's signature has to cover it.
  """
  @callback signed_url(state(), path(), opts()) :: {:ok, String.t()} | error()

  @optional_callbacks url: 3, signed_url: 3
end
