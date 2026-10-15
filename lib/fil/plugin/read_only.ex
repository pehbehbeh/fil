defmodule Fil.Plugin.ReadOnly do
  @schema NimbleOptions.new!([])

  @moduledoc """
  Refuses every call that would change the disk, so its files can be read but not written, copied onto, moved or
  deleted.

      archive =
        Fil.disk(adapter: Fil.Adapter.S3, bucket: "archive")
        |> Fil.Plugin.ReadOnly.attach()

      Fil.write(archive, "2025/report.pdf", pdf)
      #=> {:error, %Fil.AccessDeniedError{reason: :read_only}}

  Reads, streams, `Fil.stat/2`, listings, `Fil.url/2` and `Fil.signed_url/3` pass. Every other operation returns
  `Fil.AccessDeniedError` with `reason: :read_only`, and the adapter never runs: `Fil.write/4`, `Fil.rm/2`,
  `Fil.rm_rf/2`, a copy or a move within the disk, `Fil.signed_upload/3`, and any operation `Fil` adds later.
  `Fil.rm/2` is refused even for a missing file, so the answer doesn't depend on what's stored.

  A copy to another disk reads this one and writes the other, so it works. A copy from another disk fails on the
  write. A move off this disk fails on the delete, after the copy (see `Fil.rename/2`).

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "notes.txt", "keep")
      iex> disk = Fil.Plugin.ReadOnly.attach(disk)
      iex> {:error, %Fil.AccessDeniedError{reason: :read_only}} = Fil.rm(disk, "notes.txt")
      iex> Fil.read(disk, "notes.txt")
      {:ok, "keep"}

  The plugin takes no options.

  ## Order

  Attach this plugin before the others (first in `plugins:`), so it sees every call. `Fil.Plugin.URL` answers
  `Fil.signed_upload/3` without the plugins after it, so with `Fil.Plugin.URL` first, the disk signs an upload URL, and
  the upload fails when `Fil.Plug` writes it. Nothing is stored either way.
  """

  alias Fil.Op

  @allowed [:read, :stat, :ls, :url, :signed_url]

  @doc """
  Attaches the plugin to `disk` under the name `Fil.Plugin.ReadOnly`.

  The same as `plugins: [{Fil.Plugin.ReadOnly, :call, []}]` in `Fil.disk/1`.
  """
  @spec attach(Fil.Disk.t(), keyword()) :: Fil.Disk.t()
  def attach(%Fil.Disk{} = disk, opts \\ []) do
    Fil.attach(disk, __MODULE__, {__MODULE__, :call}, NimbleOptions.validate!(opts, @schema))
  end

  @doc false
  @spec call(Op.t(), (Op.t() -> Op.t()), keyword()) :: Op.t()
  def call(%Op{name: name} = op, next, opts) do
    NimbleOptions.validate!(opts, @schema)

    if name in @allowed do
      next.(op)
    else
      Op.put_result(op, {:error, %Fil.AccessDeniedError{reason: :read_only}})
    end
  end
end
