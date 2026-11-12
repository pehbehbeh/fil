defmodule Fil.Adapter.Zip do
  @schema NimbleOptions.new!(
            archive: [
              type: {:struct, Fil.Ref},
              required: true,
              doc: """
              The zip archive, as a ref on any disk: `Fil.ref(archives, "docs.zip")`. It's read through `Fil`, with the
              plugins of its disk, and it doesn't have to exist when the disk is built.
              """
            ]
          )

  @moduledoc """
  The files in a zip archive, read-only. The archive can be on any disk.

      archives = Fil.disk(adapter: Fil.Adapter.S3, bucket: "exports")
      export = Fil.disk(adapter: Fil.Adapter.Zip, archive: Fil.ref(archives, "2026/q3.zip"))

      {:ok, report} = Fil.read(export, "reports/q3.pdf")
      {:ok, reports} = Fil.ls(export, "reports")

  A local archive is a ref on a `Fil.Adapter.Local` disk. Reads, streams, listings and URLs work as on every other disk,
  and every call that would change the archive returns a `Fil.AccessDeniedError` with `reason: :read_only`. Copy a file
  to another disk to change it there.

  The adapter reads only the parts of the archive it needs, with ranged reads (`offset:` and `length:`), so a file in a
  large archive on S3 costs a few requests and not a download of the archive. It reads entries that are stored or
  compressed with deflate, the two methods zip tools use, and archives with Zip64 sizes.

  ## Options

  #{NimbleOptions.docs(@schema)}

  ## Operations

  For each `Fil` function, this section says which calls it makes on the archive and where it departs from the
  [contract](Fil.Adapter.html#module-contract) that every adapter follows. Anything it doesn't mention follows the
  contract. Reads, streams, stats and listings first read the archive's directory (see [Reads](#module-reads)).
  Directories exist where the archive has an entry for them or files under them, like on an object store.

  ### `Fil.read/3`

    * Reads the entry with one more ranged read after the directory, two when its local header has a longer name or
      extra field than the directory says.
    * With `offset:` and `length:`, reads the local header, then only that part of a stored entry. A compressed entry
      is streamed and inflated from its start up to the end of the part, because deflate can't start in the middle.
    * Checks a whole entry against the CRC-32 the archive stores, with or without `verify_checksum: true`. An entry that
      doesn't match returns a `Fil.ChecksumMismatchError`.
    * Never inflates more than the size the archive declares for the entry (see [Damage](#module-damage)).
    * Reading a directory returns a `Fil.NotFoundError`.

  ### `Fil.stream/3`

    * Reads the entry's local header with a ranged read, then streams the content with `Fil.stream/3` on the archive
      each time the stream is read, and inflates it chunk by chunk.
    * With `offset:` and `length:`, streams only that part of a stored entry. A compressed entry is inflated from its
      start up to the end of the part.
    * Checks a whole entry against its CRC-32 after the last chunk, and raises a `Fil.ChecksumMismatchError` there if
      it doesn't match. An entry that inflates to more than its declared size raises on the chunk that passes it, so the
      stream never yields more than that size.

  ### `Fil.write/4`

    * Calls no storage and returns a `Fil.AccessDeniedError` with `reason: :read_only`.

  ### `Fil.rm/3`

    * Calls no storage and returns a `Fil.AccessDeniedError` with `reason: :read_only`, also for a missing file.

  ### `Fil.rm_rf/3`

    * Calls no storage and returns a `Fil.AccessDeniedError` with `reason: :read_only`.

  ### `Fil.stat/3`

    * Reads only the directory.
    * `:mtime` is the entry's extended timestamp, or else its MS-DOS time, which zip tools write in local time, read in
      the local time of the node.
    * `:etag` is the entry's CRC-32 and size (`"crc-size"`), the same in listings.
    * `:content_type` is `nil`, because zip archives don't store one (`Fil.Plug` guesses it from the extension).
    * `checksum: :crc32` returns the CRC-32 from the directory. Other algorithms stream the whole entry through the
      checksum.
    * A stat on a directory returns `%Fil.Stat{type: :directory}` with every other field `nil`.
    * A missing archive returns a `Fil.ConfigurationError`, and `Fil.exists?/2` returns `false` for every path on it,
      as for any error.

  ### `Fil.ls/3`

    * Reads only the directory.
    * Lists a directory the archive has an entry for even when it's empty.

  ### `Fil.cp/4`

    * Calls no storage and returns a `Fil.AccessDeniedError` with `reason: :read_only`.
    * A copy to another disk reads the entry and writes it there, so it works.

  ### `Fil.rename/4`

    * Calls no storage and returns a `Fil.AccessDeniedError` with `reason: :read_only`.
    * A move to another disk copies the entry, then fails to remove it here. The copy stays (see `Fil.rename/2`).

  ### `Fil.url/3`, `Fil.signed_url/3` and `Fil.signed_upload/3`

    * A zip archive has no URLs. Attach `Fil.Plugin.URL` to build them, and `Fil.Plug` serves the files. An upload
      fails when `Fil.Plug` writes it.

  ### `Fil.Disk.same_storage?/2`

    * Compares the archive's disk the way `Fil.Disk.same_storage?/2` does, and the archive's path.

  ## Details

  ### Reads

  The disk keeps nothing between calls, so every call reads the archive's directory again: a stat of the archive, then
  a ranged read of its last 64 KiB or so, which holds the end of the directory and in a small archive all of it. A
  larger directory takes one more ranged read. On S3 or Azure, that's two or three requests for a stat or a listing,
  and one or two more for the content of an entry. An archive with many thousands of entries has a directory of
  several megabytes, which every call reads and parses again.

  ### Entry names

  Only entries whose names are already normalized paths are part of the disk. An entry whose name climbs above the
  archive's root (`../evil.txt`), starts with `/`, or has `.` segments or repeated slashes is left out of listings and
  can't be read. Two entries with the same name are one file, the first in the archive. A name can be a file and a
  directory at once (`a` and `a/b.txt`), like keys on an object store: a listing shows both, and a stat finds the
  file. Backslashes are part of a name, because the zip format separates directories with `/` only. Names are read
  as UTF-8, and names that aren't valid UTF-8 as Latin-1, with the UTF-8 flag or without (zip's own default, CP437,
  differs in its upper half).

  ### Damage

  The archive has to end with its end record. Bytes after it, or a prefix before the archive such as the program of a
  self-extracting archive, make the whole archive damaged. So does a central directory that doesn't fit the archive,
  or an entry that reaches into the central directory, as no zip tool writes one.

  Damage to one entry fails only that entry: a local header that isn't one, deflate data that can't be inflated, and
  content of another size than the archive declares. A deflated entry can expand a thousandfold, so the adapter stops
  as soon as an entry inflates past its declared size, and never holds or yields more than that.

  ### Conformance

  Nothing can be written, which breaks the [contract](Fil.Adapter.html#module-contract), so this adapter doesn't run
  the conformance suite that the writable adapters pass.

  ## Errors

  An error of the archive's disk comes back as an error of the same kind, with the archive's error as its `:reason`.
  Its `:path` and `:disk` are the zip disk's, like those of every other error, and the archive's are in the `:reason`.

  | Situation | `Fil` error | `:reason` |
  | --- | --- | --- |
  | a missing file or directory in the archive | `Fil.NotFoundError` | `:enoent` |
  | a write, a removal, a copy or a move within the disk | `Fil.AccessDeniedError` | `:read_only` |
  | an entry whose content doesn't match its CRC-32 | `Fil.ChecksumMismatchError` | `:checksum_mismatch` |
  | a damaged entry | `Fil.ChecksumMismatchError` | `{:bad_entry, where}` |
  | an encrypted entry | `Fil.UnsupportedError` | `:encrypted` |
  | an entry compressed with another method than deflate | `Fil.UnsupportedError` | `{:compression, method}` |
  | no archive at the ref, or a directory | `Fil.ConfigurationError` | the archive's `Fil.NotFoundError` |
  | a file that isn't a zip archive, or is damaged | `Fil.ConfigurationError` | `{:bad_archive, where}` |
  | any other error reading the archive | the same kind of error | the archive's error |

  `where` says what's damaged (see [Damage](#module-damage)). For an entry, it's `:local_header`, `:deflate` or `:size`.
  For the archive, it's `:no_end_record`, `:zip64_end_record`, `:central_directory`, `:zip64_extra`, `:truncated` or
  `:no_size` (its disk has no size for it). `{:compression, method}` has the number of the method in the zip format,
  such as 12 for bzip2.
  """

  @behaviour Fil.Adapter

  alias Fil.Adapter.Zip.CentralDirectory
  alias Fil.Adapter.Zip.Entry
  alias Fil.Stat
  alias Fil.Support.ByteRange

  defstruct [:archive]

  @type t :: %__MODULE__{archive: Fil.Ref.t()}

  ## ------------------------------------------------------------------
  ## Callbacks
  ## ------------------------------------------------------------------

  @impl Fil.Adapter
  def init(opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema), do: {:ok, %__MODULE__{archive: opts[:archive]}}
  end

  @impl Fil.Adapter
  def address(%__MODULE__{archive: %Fil.Ref{disk: disk, path: path}}), do: {Fil.Disk.address(disk), path}

  @impl Fil.Adapter
  def read(state, path, opts) do
    with {:ok, entries} <- CentralDirectory.read(state.archive),
         {:ok, entry} <- fetch_file(entries, path) do
      Entry.read(state.archive, entry, ByteRange.from_options(opts))
    end
  end

  @impl Fil.Adapter
  def stream(state, path, opts) do
    with {:ok, entries} <- CentralDirectory.read(state.archive),
         {:ok, entry} <- fetch_file(entries, path) do
      Entry.stream(state.archive, entry, ByteRange.from_options(opts))
    end
  end

  @impl Fil.Adapter
  def write(_state, _path, _content, _opts), do: read_only()

  @impl Fil.Adapter
  def rm(_state, _path, _opts), do: read_only()

  @impl Fil.Adapter
  def rm_rf(_state, _prefix, _opts), do: read_only()

  @impl Fil.Adapter
  def cp(_state, _src, _dest, _opts), do: read_only()

  @impl Fil.Adapter
  def rename(_state, _src, _dest, _opts), do: read_only()

  @impl Fil.Adapter
  def stat(state, path, opts) do
    with {:ok, entries} <- CentralDirectory.read(state.archive) do
      case fetch_file(entries, path) do
        {:ok, entry} -> put_checksum(state, entry, Keyword.get(opts, :checksum))
        {:error, _not_found} = error -> directory_stat(entries, path, error)
      end
    end
  end

  @impl Fil.Adapter
  def ls(state, prefix, opts) do
    with {:ok, entries} <- CentralDirectory.read(state.archive) do
      under = under(entries, prefix)

      if Keyword.get(opts, :recursive, false) do
        {:ok, subtree(under, prefix)}
      else
        {:ok, one_level(under, prefix)}
      end
    end
  end

  defp read_only, do: {:error, %Fil.AccessDeniedError{reason: :read_only}}

  ## ------------------------------------------------------------------
  ## Stats and listings
  ## ------------------------------------------------------------------

  defp fetch_file(entries, path) do
    case Enum.find(entries, &(&1.type == :regular and &1.path == path)) do
      nil -> {:error, %Fil.NotFoundError{reason: :enoent}}
      entry -> {:ok, entry}
    end
  end

  defp put_checksum(_state, entry, nil), do: {:ok, file_stat(entry)}

  defp put_checksum(_state, entry, :crc32),
    do: {:ok, %{file_stat(entry) | checksum: {:crc32, Base.encode64(<<entry.crc::32>>)}}}

  defp put_checksum(state, entry, algorithm) do
    with {:ok, checksum} <- Entry.checksum(state.archive, entry, algorithm) do
      {:ok, %{file_stat(entry) | checksum: {algorithm, checksum}}}
    end
  end

  defp directory_stat(_entries, ".", _error), do: {:ok, %Stat{type: :directory}}

  defp directory_stat(entries, path, error) do
    if Enum.any?(entries, &(&1.path == path and &1.type == :directory)) or under(entries, path) != [] do
      {:ok, %Stat{type: :directory}}
    else
      error
    end
  end

  defp under(entries, "."), do: entries
  defp under(entries, prefix), do: Enum.filter(entries, &String.starts_with?(&1.path, prefix <> "/"))

  defp one_level(entries, prefix) do
    entries
    |> Enum.map(&child(&1, prefix))
    |> Enum.uniq()
    |> Enum.sort_by(&elem(&1, 0))
  end

  # The entry itself when it's right under `prefix`, or the directory under `prefix` that holds it.
  defp child(entry, prefix) do
    relative = relative(entry.path, prefix)

    case String.split(relative, "/", parts: 2) do
      [_name] -> {entry.path, stat(entry)}
      [name, _rest] -> {Fil.Support.Path.join(prefix, name), %Stat{type: :directory}}
    end
  end

  # The directories of a subtree are its directory entries and the parents of every entry in it.
  defp subtree(entries, prefix) do
    listed = Enum.map(entries, &{&1.path, stat(&1)})

    parents =
      entries
      |> Enum.map(& &1.path)
      |> Fil.Support.Path.parents(prefix)
      |> Enum.map(&{&1, %Stat{type: :directory}})

    (listed ++ parents)
    |> Enum.uniq()
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp relative(path, "."), do: path
  defp relative(path, prefix), do: String.replace_prefix(path, prefix <> "/", "")

  defp stat(%Entry{type: :directory}), do: %Stat{type: :directory}
  defp stat(entry), do: file_stat(entry)

  defp file_stat(entry) do
    %Stat{
      size: entry.size,
      type: :regular,
      mtime: entry.mtime,
      etag: etag(entry),
      content_type: nil
    }
  end

  defp etag(entry) do
    crc =
      <<entry.crc::32>>
      |> Base.encode16(case: :lower)

    "#{crc}-#{entry.size}"
  end
end
