defmodule Fil.Plugin.ReadOnly do
  @schema NimbleOptions.new!([])

  @moduledoc """
  Refuses every operation that changes the disk, so its files can be read but not written, copied onto, moved or
  deleted.

      archive =
        Fil.disk(adapter: Fil.Adapter.S3, bucket: "archive")
        |> Fil.Plugin.ReadOnly.attach()

      Fil.write(archive, "2025/report.pdf", pdf)
      #=> {:error, %Fil.AccessDeniedError{reason: :read_only}}

  A refused call returns `Fil.AccessDeniedError` with `reason: :read_only`, and the adapter never runs. That covers
  `Fil.write/4`, `Fil.rm/2`, `Fil.rm_rf/2`, a copy or a move within the disk, and `Fil.signed_upload/3`, on every
  adapter. `Fil.rm/2` is refused even for a missing file, so the answer doesn't depend on what's stored.

  Reads, streams, `Fil.stat/2`, listings and URLs pass. A copy to another disk reads this one and writes the other, so
  it works. A copy from another disk fails on the write, and a move off this disk fails on the delete after the copy,
  so the copy stays on the other disk.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.write!(disk, "notes.txt", "keep")
      iex> disk = Fil.Plugin.ReadOnly.attach(disk)
      iex> {:error, %Fil.AccessDeniedError{reason: :read_only}} = Fil.rm(disk, "notes.txt")
      iex> Fil.read(disk, "notes.txt")
      {:ok, "keep"}

  The plugin takes no options.
  """

  alias Fil.Op

  @refused [:write, :rm, :rm_rf, :cp, :rename, :signed_upload]

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

    if name in @refused do
      Op.put_result(op, {:error, %Fil.AccessDeniedError{reason: :read_only}})
    else
      next.(op)
    end
  end
end
