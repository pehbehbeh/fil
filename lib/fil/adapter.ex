defmodule Fil.Adapter do
  @moduledoc """
  The contract every storage backend implements.

  An adapter is a stateless module. `c:init/1` turns the options into a state term once, when `Fil.disk/1` builds the
  disk, and every other callback gets that state. There's no process to start, supervise or shut down.

  Plugins (`Fil.Plugin`) run in `Fil` before an adapter is called, so an adapter never needs to know about them.

  Two rules keep adapters small:

    * Mutations return a bare `:ok`. `Fil` wraps results into `{:ok, %Fil.Ref{}}`, handles cross-disk copies and
      keeps errors uniform, so adapters don't have to.
    * Paths arrive normalized and jailed. `Fil` has already resolved `.` and `..`, collapsed repeated `/` and rejected
      escapes, and `"."` means the disk root. Adapters may check again (`Fil.Adapter.Local` does), but they don't need
      to parse paths defensively.

  ## Contract

  `Fil` uses the vocabulary of Elixir's `File` module, but every adapter behaves like an object store, so the semantics
  differ where the two disagree. Beyond the callback signatures, this is the contract:

  | Situation | `File` | Every `Fil` adapter |
  | --- | --- | --- |
  | `c:write/4` into a missing directory | `{:error, :enoent}` | creates the missing parents |
  | exclusive `c:write/4` on an existing file | `{:error, :eexist}` | `{:error, :precondition_failed}` |
  | `c:cp/4` or `c:rename/4` into a missing directory | `{:error, :enoent}` | creates the missing parents |
  | `c:rm/3` on a missing file | `{:error, :enoent}` | `:ok` |
  | `c:ls/3` on a missing directory | `{:error, :enoent}` | `{:ok, []}` |
  | `c:ls/3` results | names, one level deep | `{path, stat}` pairs, one level deep; only files with `recursive: true` |
  | `c:rm_rf/3` results | `{:ok, removed_paths}`, directories included | `{:ok, count}` of removed files |
  | `c:rm_rf/3` on `"reports"` | the directory `reports` | `reports` and all of `reports/`, not `reports.txt` |
  | paths | relative to the working directory, or absolute | relative to the disk root, never above it |

  An exclusive write is `File.write/3` with `[:exclusive]`, and `c:write/4` with `if_none_match: :any`.

  Where an adapter returns `:ok`, the `Fil` function returns `{:ok, %Fil.Ref{}}`, and `Fil.ls/2` turns the pairs
  into refs.

  Options that `File` has no equivalent for:

    * `checksum:` on `c:write/4` sends a checksum of the content where the backend stores one, and a backend that finds
      the content doesn't match fails with `{:error, :checksum_mismatch}`. Backends without checksums ignore the option
    * `checksum:` on `c:stat/3` fills in `Fil.Stat`'s `:checksum`, from the backend or computed from the content
    * `verify_checksum: true` on `c:read/3` fails with `{:error, :checksum_mismatch}` when the content doesn't match a
      stored checksum

  `Fil.AdapterCase` (internal for now) tests this contract against a live disk.

  ## Where the adapters differ

  Every adapter `Fil` ships reads, writes, lists, copies and checks checksums, and every disk signs URLs (S3 itself, the
  others with `Fil.Plugin.SignedURL`), so code written against one disk runs on the others. What's left are edge
  cases:

  | Situation | `Fil.Adapter.Local` | `Fil.Adapter.S3` | `Fil.Adapter.Memory` |
  | --- | --- | --- | --- |
  | directories | exist on their own, can be empty | prefixes only | prefixes only |
  | `c:rm/3` on a directory | fails | `:ok`, removes nothing | `:ok`, removes nothing |
  | `c:stat/3` with `checksum:` | computed from the content | the checksum the write stored, or `nil` | same as S3 |
  | `verify_checksum: true` | ignored | compared with the stored checksum | compared with the stored checksum |
  | `:content_type` in a stat | `nil` (`Fil.Plug` guesses from the extension) | from the write | from the write |
  | `:etag` in a stat | weak, `"size-mtime"` | from S3 | MD5 of the content |
  | signed URLs | with `Fil.Plugin.SignedURL`, served by `Fil.Plug` | by S3 | with the plugin, served by `Fil.Plug` |

  ## Errors

  Adapters map backend failures onto POSIX atoms where one fits (`:enoent`, `:eacces`, `:eisdir`, `:enotdir`), and onto
  `Fil.TransportError` when the backend couldn't be reached.
  """

  alias Fil.Stat

  @type state :: term()
  @type path :: String.t()
  @type opts :: keyword()
  @type error :: {:error, term()}

  @doc "Validates options and builds the state passed to every other callback."
  @callback init(opts()) :: {:ok, state()} | error()

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
  Builds a URL that grants temporary access to a file.

  Optional. Adapters whose backend can't sign URLs leave it out, and `Fil.signed_url/2` then returns
  `{:error, {:unsupported, :signed_url}}`. `Fil.Plugin.SignedURL` signs URLs for those disks, and `Fil.Plug` serves
  them.
  """
  @callback signed_url(state(), path(), opts()) :: {:ok, String.t()} | error()

  @optional_callbacks signed_url: 3
end
