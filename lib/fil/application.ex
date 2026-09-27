defmodule Fil.Application do
  @moduledoc false

  # Starts the lookup table for `Fil.Adapter.Memory` stores, and the server that removes what a killed Local write
  # leaves behind. Its tables are created here, so they belong to the application and survive a crash of the server.
  # Disks themselves need no process.

  use Application

  @impl Application
  def start(_type, _args) do
    Fil.Support.Tmp.create_tables()
    Supervisor.start_link([Fil.Support.MemoryStores, Fil.Support.Tmp], strategy: :one_for_one, name: Fil.Supervisor)
  end
end
