defmodule Fil.Support.Tmp do
  @moduledoc false

  # Removes what a process leaves behind when it exits, also when it's killed: the `.fil-` file of a `Fil.Adapter.Local`
  # write in progress, and the directories that write created.
  #
  # Two public ETS tables, created in `Fil.Application.start/2` and owned by the application, so they survive a crash of
  # this server:
  #
  #   * entries, `{key, owner, data}` rows keyed by what gets removed, so the owner deletes its row in O(1) once it's
  #     done: `{{:file, tmp}, owner, created_dirs}` for a Local write.
  #   * owners, `{pid}` rows for the processes this server monitors, so a process calls the server only the first time
  #     it puts an entry. Later entries go straight into the table.
  #
  # When an owner exits, the server takes its entries out of the table and removes them in a process of its own, so a
  # slow filesystem never blocks the next registration. Finding them scans the table, which only holds what's in use
  # right now. `init/1` monitors every owner in both tables, so a restarted server still cleans up after the processes
  # it knew. Removing calls `File` directly, not `Fil`: a `.fil-` file isn't a file of its disk yet, so there are no
  # plugins to run and no operation to report to telemetry.

  use GenServer, shutdown: 30_000

  @entries __MODULE__
  @owners Fil.Support.Tmp.Owners

  @doc "Creates the tables. The calling process owns them, so it has to outlive the server."
  @spec create_tables() :: :ok
  def create_tables do
    :ets.new(@entries, [:set, :public, :named_table, write_concurrency: true])
    :ets.new(@owners, [:set, :public, :named_table, read_concurrency: true])
    :ok
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Puts an entry for the calling process, so it's removed when the process exits. Putting the same key again replaces
  the entry's data.
  """
  @spec put(term(), term()) :: :ok
  def put(key, data) do
    # The owner is monitored before its entry exists, so a kill in between leaves nothing to remove. A server that's
    # down right then can't monitor it, so the call is made once more after the insert: either a new server answers it,
    # or the one that starts later finds the entry in `init/1`.
    monitored = monitor_self()
    :ets.insert(@entries, {key, self(), data})
    if !monitored, do: monitor_self()
    :ok
  end

  @doc "Deletes an entry of the calling process, once it removed what the entry stands for itself."
  @spec delete(term()) :: :ok
  def delete(key) do
    :ets.delete(@entries, key)
    :ok
  end

  @doc """
  Waits until the entries of every process that's gone are removed, also of those whose `:DOWN` hasn't arrived yet.
  For tests.
  """
  @spec sync() :: :ok
  def sync, do: GenServer.call(__MODULE__, :sync, :infinity)

  @doc """
  Removes empty directories, deepest first, and stops at the first one that isn't empty, because another write put
  something into it meanwhile. Missing ones are skipped: a write that's killed while it creates its directories has
  made only the top ones.
  """
  @spec remove_dirs([Path.t()]) :: :ok
  def remove_dirs(dirs) do
    Enum.reduce_while(dirs, :ok, fn dir, :ok ->
      case :file.del_dir(dir) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, _reason} -> {:halt, :ok}
      end
    end)
  end

  defp monitor_self do
    :ets.member(@owners, self()) or GenServer.call(__MODULE__, :monitor) == :ok
  catch
    :exit, _reason -> false
  end

  @impl GenServer
  def init(nil) do
    Process.flag(:trap_exit, true)

    owners = :ets.select(@owners, [{{:"$1"}, [], [:"$1"]}])
    with_entries = :ets.select(@entries, [{{:_, :"$1", :_}, [], [:"$1"]}])

    owners
    |> Enum.concat(with_entries)
    |> Enum.uniq()
    |> Enum.each(&monitor/1)

    {:ok, %{cleanups: MapSet.new(), syncs: []}}
  end

  @impl GenServer
  def handle_call(:monitor, {pid, _tag}, state) do
    if !:ets.member(@owners, pid), do: monitor(pid)
    {:reply, :ok, state}
  end

  # A process that was killed is dead before its `:DOWN` is sent, so the entries of dead owners are taken right away,
  # and the reply waits for every cleanup that's running.
  def handle_call(:sync, from, state) do
    state =
      @owners
      |> :ets.select([{{:"$1"}, [], [:"$1"]}])
      |> Enum.reject(&Process.alive?/1)
      |> Enum.reduce(state, &down/2)

    if MapSet.size(state.cleanups) == 0 do
      {:reply, :ok, state}
    else
      {:noreply, %{state | syncs: [{from, state.cleanups} | state.syncs]}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    if MapSet.member?(state.cleanups, ref) do
      {:noreply, cleaned_up(ref, state)}
    else
      {:noreply, down(pid, state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # On shutdown (the application stops), everything is removed before the tables go. A crash keeps the entries for the
  # next server.
  @impl GenServer
  def terminate(reason, state) do
    if shutdown?(reason), do: remove_all(state)
    :ok
  end

  defp shutdown?(reason), do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  defp remove_all(state) do
    @entries
    |> :ets.tab2list()
    |> Enum.each(&remove/1)

    for ref <- state.cleanups do
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      end
    end
  end

  defp monitor(pid) do
    Process.monitor(pid)
    :ets.insert(@owners, {pid})
  end

  defp down(owner, state) do
    :ets.delete(@owners, owner)
    entries = :ets.match_object(@entries, {:_, owner, :_})

    if entries == [] do
      state
    else
      Enum.each(entries, &:ets.delete_object(@entries, &1))
      {_pid, ref} = spawn_monitor(fn -> Enum.each(entries, &remove/1) end)
      %{state | cleanups: MapSet.put(state.cleanups, ref)}
    end
  end

  defp cleaned_up(ref, state) do
    {done, syncs} =
      state.syncs
      |> Enum.map(fn {from, pending} -> {from, MapSet.delete(pending, ref)} end)
      |> Enum.split_with(fn {_from, pending} -> MapSet.size(pending) == 0 end)

    Enum.each(done, fn {from, _pending} -> GenServer.reply(from, :ok) end)
    %{state | cleanups: MapSet.delete(state.cleanups, ref), syncs: syncs}
  end

  # The write may have placed the file already (renamed or linked), which only makes the `File.rm/1` a no-op, since the
  # names are unique.
  defp remove({{:file, tmp}, _owner, created_dirs}) do
    _result = File.rm(tmp)
    remove_dirs(created_dirs)
  end
end
