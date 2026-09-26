defmodule Fil.Support.MemoryStores do
  @moduledoc false

  # Which process uses which `Fil.Adapter.Memory` store. The stores themselves are ETS tables owned by the process that
  # checked them out, so they're gone when it exits. This server only keeps the lookup table, `{pid, store, owner}`
  # rows, and removes an owner's rows when the owner exits.
  #
  # Reads go straight to the table. Only registrations go through the server, because it has to monitor the owner.

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Registers `pid` as a user of `owner`'s `store`."
  @spec put(pid(), :ets.tid(), pid()) :: :ok
  def put(pid, store, owner), do: GenServer.call(__MODULE__, {:put, pid, store, owner})

  @doc "The store `pid` uses, with its owner."
  @spec lookup(pid()) :: {:ok, :ets.tid(), pid()} | :error
  def lookup(pid) do
    case :ets.lookup(@table, pid) do
      [{^pid, store, owner}] -> {:ok, store, owner}
      [] -> :error
    end
  end

  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, MapSet.new()}
  end

  @impl GenServer
  def handle_call({:put, pid, store, owner}, _from, owners) do
    :ets.insert(@table, {pid, store, owner})

    if MapSet.member?(owners, owner) do
      {:reply, :ok, owners}
    else
      Process.monitor(owner)
      {:reply, :ok, MapSet.put(owners, owner)}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, owner, _reason}, owners) do
    :ets.match_delete(@table, {:_, :_, owner})
    {:noreply, MapSet.delete(owners, owner)}
  end
end
