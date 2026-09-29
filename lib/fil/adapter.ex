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
  | `c:stream/3` on a missing file | `File.stream!/3` raises when it's read | `{:error, %Fil.NotFoundError{}}` |
  | `c:write/4` into a missing directory | `{:error, :enoent}` | creates the missing parents |
  | exclusive `c:write/4` on an existing file | `{:error, :eexist}` | `{:error, %Fil.AlreadyExistsError{}}` |
  | exclusive `c:cp/4` or `c:rename/4` onto an existing file | replaces it | `{:error, %Fil.AlreadyExistsError{}}` |
  | `c:cp/4` or `c:rename/4` into a missing directory | `{:error, :enoent}` | creates the missing parents |
  | `c:rm/3` on a missing file | `{:error, :enoent}` | `:ok` |
  | `c:ls/3` on a missing directory | `{:error, :enoent}` | `{:ok, []}` |
  | `c:ls/3` results | names, one level deep | `{path, stat}` pairs, one level deep; only files with `recursive: true` |
  | `c:rm_rf/3` results | `{:ok, removed_paths}`, directories included | `{:ok, count}` of removed files |
  | `c:rm_rf/3` on `"reports"` | the directory `reports` | `reports` and all of `reports/`, not `reports.txt` |
  | paths | relative to the working directory, or absolute | relative to the disk root, never above it |

  An exclusive write is `File.write/3` with `[:exclusive]`, and `c:write/4` with `if_exists: :error`. An exclusive copy
  or move is `c:cp/4` or `c:rename/4` with `if_exists: :error`. It fails with the destination's path and leaves both
  files as they were.

  A copy or a move onto its own path never loses the file. The adapter leaves it where it is, fails with
  `Fil.AlreadyExistsError` when the call is exclusive, or refuses the call with `Fil.InvalidRequestError`. A copy keeps
  the content type, where the storage keeps one.

  The `:etag` that `c:stat/3` returns changes when a write changes the size of the file. A weak etag may miss other
  changes. Which result an adapter gives for a copy onto itself, and what its etag covers, is under Operations on the
  adapter's page.

  Where an adapter returns `:ok`, the `Fil` function returns `{:ok, %Fil.Ref{}}`, and `Fil.ls/2` turns the pairs
  into refs.

  Options that `File` has no equivalent for:

    * `size:` on `c:write/4` is the size of a stream, when the caller knows it or `Fil.write/4` found it. Storage that
      needs the size before the content uses it, and uploads a stream without one in parts
    * `checksum:` on `c:write/4` sends a checksum of the content where the storage keeps one, and storage that finds
      the content doesn't match fails with `Fil.ChecksumMismatchError`. Storage without checksums ignores the option
    * `checksum:` on `c:stat/3` fills in `Fil.Stat`'s `:checksum`, from the storage or computed from the content. A
      directory has no checksum, and a copy keeps the checksum of a file written in one part (S3 computes a new one
      when it copies a file uploaded in parts)
    * `verify_checksum: true` on `c:read/3` fails with `Fil.ChecksumMismatchError` when the content doesn't match a
      stored checksum

  `Fil.AdapterCase` (internal for now) tests this contract against a live disk.

  Every adapter `Fil` ships reads, writes and streams files, lists, copies and checks checksums, and every disk builds
  public and signed URLs (S3 itself, the others with `Fil.Plugin.URL`), so code written against one disk runs on the
  others. What's left are edge cases, such as whether directories exist on their own, and each adapter lists them
  under Operations on its own page.

  ## Errors

  Every error is an exception struct, listed under Errors in the sidebar. Which struct you get tells you what to do
  next, and it's the same on every adapter: a missing file is a `Fil.NotFoundError` on the local disk and on S3.
  `Fil.UnavailableError` and `Fil.ConflictError` are the ones where retrying can help.

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
  refused with a plain `400` for a missing source. Directory errors only come from storage with directories of its own,
  such as the filesystem. Where directories are only key prefixes, reading or copying one is a `Fil.NotFoundError`.
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

  @doc """
  Checks that a file can be read and returns a stream of its content.

  Optional. Without it, `Fil.stream/3` calls `c:read/3` and streams the file as one chunk.

  Returns `{:ok, stream, size}` when the check found the size of the file, `{:ok, stream}` otherwise. `Fil.write/4`
  passes the size on when the stream is written, to another disk or in a copy across disks, so storage that needs the
  size before the content (S3) can stream it too.

  The stream is lazy: it reads the file only when it's enumerated, and again each time it is, in whatever process
  enumerates it. It yields binaries of any size and raises an error struct when reading fails (`Fil` fills in its
  context). `opts` are those of `c:read/3`, and a `verify_checksum: true` mismatch raises `Fil.ChecksumMismatchError`
  at the latest after the last chunk.
  """
  @callback stream(state(), path(), opts()) ::
              {:ok, Enumerable.t()} | {:ok, Enumerable.t(), non_neg_integer()} | error()

  @doc """
  Writes `content`, creating parent directories as needed.

  `content` is iodata, or a stream of non-empty binaries. `Fil` checks a stream against the `:size` option while the
  adapter reads it, when the caller gave one or `Fil.write/4` found one. If the stream raises, the adapter lets the
  error propagate and writes nothing: the destination keeps what it had before.
  """
  @callback write(state(), path(), iodata() | Enumerable.t(), opts()) :: :ok | error()

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

  With `if_exists: :error`, an existing destination fails the copy with `Fil.AlreadyExistsError`, `:path` set to the
  destination, and the destination keeps its content.
  """
  @callback cp(state(), path(), path(), opts()) :: :ok | error()

  @doc """
  Moves a file within the same disk.

  A move across two disks doesn't call this: `Fil` copies the file as described in `c:cp/4`, then removes the source
  with `c:rm/3`.

  With `if_exists: :error`, an existing destination fails the move as it fails `c:cp/4`, and the source stays where it
  is.
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

  `opts` has `:method`, `:expires_in` and `:query` as `Fil.signed_url/3` validated them, and for a download with
  `disposition:`, `:disposition` as the finished `content-disposition` header value. The storage has to send that header
  with the download, and the URL's signature has to cover it and the `:query` parameters. A request with another path,
  method or parameter than the URL was signed for gets a status in the 4xx range, and an upload through it writes
  nothing.

  An upload URL may get `:content_type`, `:size` and `:if_exists`. The signature has to cover them, so the storage
  refuses an upload with another `content-type` or `content-length`, and with `if_exists: :error` one that finds a file
  at the path. The client sends the headers `Fil.signed_url/3` lists under Uploads.
  """
  @callback signed_url(state(), path(), opts()) :: {:ok, String.t()} | error()

  @doc """
  Returns the address of the files: what decides which file a path names, such as the root directory, or the bucket and
  prefix.

  Optional. `Fil.Disk.same_storage?/2` compares two disks of the adapter by it. Leave out credentials and options that
  only change how the storage is reached, so a disk with rotated credentials is still the same storage. Without this
  callback, the whole state is compared.
  """
  @callback address(state()) :: term()

  @optional_callbacks stream: 3, url: 3, signed_url: 3, address: 1
end
