defmodule Fil.Application do
  @moduledoc false

  # Starts the lookup table for `Fil.Adapter.Memory` stores. Disks themselves need no process.

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([Fil.Support.MemoryStores], strategy: :one_for_one, name: Fil.Supervisor)
  end
end
