defmodule Fil.Application do
  @moduledoc false

  # Starts the lookup table for `Fil.Adapter.Memory` stores, and the server that removes what a killed Local write
  # leaves behind. Its tables are created here, so they belong to the application and survive a crash of the server.
  # Disks themselves need no process.
  #
  # With the optional Kino dependency, it also registers the smart cell of `Fil.Kino`. Kino is then in `applications`
  # of `fil.app`, so it's started first. Livebook reads the smart cells again after every evaluation, so the cell shows
  # up right after the cell with `Mix.install/1`.

  use Application

  # Only called when `Fil.Kino.DiskCell` was compiled, and that needs Kino.
  @compile {:no_warn_undefined, Kino.SmartCell}

  @impl Application
  def start(_type, _args) do
    if Code.ensure_loaded?(Fil.Kino.DiskCell), do: Kino.SmartCell.register(Fil.Kino.DiskCell)

    Fil.Support.Tmp.create_tables()
    Supervisor.start_link([Fil.Support.MemoryStores, Fil.Support.Tmp], strategy: :one_for_one, name: Fil.Supervisor)
  end
end
