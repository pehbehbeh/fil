defmodule Fil.Adapter.Null do
  @schema NimbleOptions.new!([])

  @moduledoc """
  A disk that stores nothing. Writes succeed and drop the content, and every file is missing.

      disk = Fil.disk(adapter: Fil.Adapter.Null)

      {:ok, _report} = Fil.write(disk, "reports/q3.pdf", pdf)
      {:error, %Fil.NotFoundError{}} = Fil.read(disk, "reports/q3.pdf")

  Use it where code has to write files that nobody reads back: a dry run, an environment with storage turned off, or
  tests that don't check the files. Plugins run as on every other disk, so a dry run still validates the content.
  Tests that read files back need `Fil.Adapter.Memory`.

  Writes that never read back break the [contract](Fil.Adapter.html#module-contract), so this adapter doesn't run the
  conformance suite that every other adapter passes.

  ## Options

  None. Every null disk is the same storage, so it has no root either.

  ## Operations

  For each `Fil` function, this section says what the adapter does instead of storing files. Anything it doesn't mention
  follows the [contract](Fil.Adapter.html#module-contract) that every adapter follows.

  ### `Fil.read/3` and `Fil.stream/3`

    * Return a `Fil.NotFoundError` for every path.

  ### `Fil.write/4`

    * Drops the content and succeeds, also with `if_exists: :error`, because no file exists.
    * Reads a stream to the end first, so a stream that fails, or a plugin that refuses the content while it's read
      (`Fil.Op.scan_content/4`), fails the write as it would on another disk.
    * Ignores `checksum:`, as storage without checksums does.

  ### `Fil.rm/3` and `Fil.rm_rf/3`

    * Succeed and remove nothing. `Fil.rm_rf/3` returns `{:ok, 0}`.

  ### `Fil.stat/3`, `Fil.exists?/3` and `Fil.ls/3`

    * The disk root is an empty directory, so `Fil.ls/3` returns `{:ok, []}` for every path, and `Fil.stat/3` on
      `"."` returns `%Fil.Stat{type: :directory}`.
    * Every other path returns a `Fil.NotFoundError`.

  ### `Fil.cp/4` and `Fil.rename/4`

    * Return a `Fil.NotFoundError` for the missing source. A copy from another disk onto a null disk is a write, so it
      succeeds.

  ### `Fil.url/3`, `Fil.signed_url/3` and `Fil.signed_upload/3`

    * A null disk has no URLs. Attach `Fil.Plugin.URL` to build them. `Fil.Plug` answers a download with a `404`, as
      for any missing file, and accepts an upload, whose content it drops.

  ### `Fil.Disk.same_storage?/2`

    * Returns `true` for any two null disks.

  ## Errors

  `:reason` is the POSIX atom `Fil.Adapter.Local` would return for a missing file.

  | Situation | `Fil` error | `:reason` |
  | --- | --- | --- |
  | any path but the root, on a read, a stream, a stat, a copy or a move | `Fil.NotFoundError` | `:enoent` |
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
