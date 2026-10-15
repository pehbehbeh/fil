defmodule Fil.Adapter.Null do
  @schema NimbleOptions.new!([])

  @moduledoc """
  A disk that stores nothing. Writes succeed and drop the content, and every file is missing.

      disk = Fil.disk(adapter: Fil.Adapter.Null)

      {:ok, _report} = Fil.write(disk, "reports/q3.pdf", pdf)
      {:error, %Fil.NotFoundError{}} = Fil.read(disk, "reports/q3.pdf")

  Use it where code writes files that nobody reads back: a dry run, an environment with storage turned off, or tests
  that don't check the files. Plugins run as on every other disk, so a dry run still validates the content.

  Anything that reads a file after writing it fails, because the file isn't there. Direct uploads through
  `Fil.LiveView.external/2` fail when they're consumed, because that checks the stored file with `Fil.stat/3`. Uploads
  through LiveView's channel and `PUT`s to `Fil.Plug` succeed. Tests that read files back need `Fil.Adapter.Memory`.

  ## Options

  None. Every null disk is the same storage, so it has no root either.

  ## Operations

  For each `Fil` function, this section says what the adapter does instead of storing files and where it departs from
  the [contract](Fil.Adapter.html#module-contract) that every adapter follows. Anything it doesn't mention follows the
  contract.

  ### `Fil.read/3`

    * Calls no storage and returns a `Fil.NotFoundError` for every path, the root included.

  ### `Fil.stream/3`

    * Calls no storage and returns a `Fil.NotFoundError` for every path, the root included.

  ### `Fil.write/4`

    * Calls no storage. Drops the content and succeeds, also with `if_exists: :error`, because no file exists.
    * Reads a stream to the end first (see [Streams](#module-streams)).
    * Ignores `checksum:`, as storage without checksums does.

  ### `Fil.rm/3`

    * Calls no storage and succeeds for every path.

  ### `Fil.rm_rf/3`

    * Calls no storage and returns `{:ok, 0}` for every path, the root included.

  ### `Fil.stat/3`

    * Calls no storage. The root is an empty directory, so a stat on `"."` returns `%Fil.Stat{type: :directory}`, and
      `Fil.exists?/3` is `true` for it.
    * Every other path returns a `Fil.NotFoundError`.

  ### `Fil.ls/3`

    * Calls no storage and returns `{:ok, []}` for every path.

  ### `Fil.cp/4`

    * Calls no storage and returns a `Fil.NotFoundError` for the source.
    * A copy from another disk onto a null disk is a write, so it succeeds.

  ### `Fil.rename/4`

    * Calls no storage and returns a `Fil.NotFoundError` for the source.
    * A move from another disk onto a null disk is a write followed by a removal of the source, so it succeeds and the
      file is gone.

  ### `Fil.url/3`, `Fil.signed_url/3` and `Fil.signed_upload/3`

    * A null disk has no URLs. Attach `Fil.Plugin.URL` to build them. `Fil.Plug` answers a download with a `404`, as
      for any missing file, and accepts an upload, whose content it drops.

  ### `Fil.Disk.same_storage?/2`

    * Returns `true` for any two null disks.

  ## Details

  ### Conformance

  Writes never read back, which breaks the [contract](Fil.Adapter.html#module-contract), so this adapter doesn't run
  the conformance suite that every other adapter passes.

  ### Streams

  A stream is read to the end before its content is dropped, because the size check of `size:` and the scans of
  plugins (`Fil.Op.scan_content/4`) run while it's read. A stream that fails, or content a plugin refuses, fails the
  write as on another disk. So dropped content still costs a full read: a large `{:file, path}` is read whole.

  ## Errors

  `:reason` is the POSIX atom `Fil.Adapter.Local` would return for a missing file.

  | Situation | `Fil` error | `:reason` |
  | --- | --- | --- |
  | a read, a stream, a copy or a move, on any path | `Fil.NotFoundError` | `:enoent` |
  | a stat on any path but the root | `Fil.NotFoundError` | `:enoent` |
  """

  @behaviour Fil.Adapter

  alias Fil.Stat
  alias Fil.Support.Content

  defstruct []

  @type t :: %__MODULE__{}

  ## ------------------------------------------------------------------
  ## Callbacks
  ## ------------------------------------------------------------------

  @impl Fil.Adapter
  def init(opts) do
    with {:ok, _opts} <- NimbleOptions.validate(opts, @schema), do: {:ok, %__MODULE__{}}
  end

  @impl Fil.Adapter
  def read(_state, _path, _opts), do: not_found()

  @impl Fil.Adapter
  def stream(_state, _path, _opts), do: not_found()

  # A stream is read to the end, so an error it raises fails the write, as on every other disk.
  @impl Fil.Adapter
  def write(_state, _path, content, _opts) do
    if !Content.iodata?(content), do: Stream.run(content)
    :ok
  end

  @impl Fil.Adapter
  def rm(_state, _path, _opts), do: :ok

  @impl Fil.Adapter
  def stat(_state, ".", _opts), do: {:ok, %Stat{type: :directory}}
  def stat(_state, _path, _opts), do: not_found()

  @impl Fil.Adapter
  def ls(_state, _prefix, _opts), do: {:ok, []}

  @impl Fil.Adapter
  def cp(_state, _src, _dest, _opts), do: not_found()

  @impl Fil.Adapter
  def rename(_state, _src, _dest, _opts), do: not_found()

  @impl Fil.Adapter
  def rm_rf(_state, _prefix, _opts), do: {:ok, 0}

  defp not_found, do: {:error, %Fil.NotFoundError{reason: :enoent}}
end
