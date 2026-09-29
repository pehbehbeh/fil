defmodule Fil.Support.Tmp do
  @moduledoc false

  # Removes what a process leaves behind when it exits, also when it's killed: the directories of `Fil.tmp/0,1`, and
  # the `.fil-` file of a `Fil.Adapter.Local` write in progress with the directories that write created.
  #
  # Two public ETS tables, created in `Fil.Application.start/2` and owned by the application, so they survive a crash of
  # this server:
  #
  #   * entries, an ordered set of `{{owner, key}, data}` rows, where `key` names what gets removed:
  #     `{{owner, {:tmp, root}}, nil}` for a directory of `Fil.tmp/0,1`, `{{owner, {:file, tmp}}, created_dirs}` for a
  #     Local write. The owner deletes its row by its key once it's done, and when it exits, the server reads only its
  #     rows, which sit next to each other.
  #   * owners, `{pid}` rows for the processes this server monitors, so a process calls the server only the first time
  #     it puts an entry. Later entries go straight into the table.
  #
  # When an owner exits, the server takes its entries out of the table and removes them in a process of its own, so a
  # slow filesystem never blocks the next registration. That process removes them twice, a second apart: a process
  # that's killed during a file operation (a dirty NIF, such as the `open` that creates a `.fil-` file) is `:DOWN`
  # before the operation returns, so the file can appear after the first pass. An operation that takes longer than that
  # can still leave its file behind.
  #
  # `init/1` monitors every owner in both tables, so a restarted server still cleans up after the processes it knew.
  # Removing calls `File` directly, not `Fil`: a `.fil-` file isn't a file of its disk yet, and a temporary directory's
  # disk has no plugins, so there are no plugins to run and no operation to report to telemetry.

  use GenServer, shutdown: 30_000

  @entries __MODULE__
  @owners Fil.Support.Tmp.Owners

  # How long a cleanup waits before it removes everything a second time.
  @grace 1_000

  @doc "Creates the tables. The calling process owns them, so it has to outlive the server."
  @spec create_tables() :: :ok
  def create_tables do
    :ets.new(@entries, [:ordered_set, :public, :named_table, write_concurrency: true])
    :ets.new(@owners, [:set, :public, :named_table, read_concurrency: true])
    :ok
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Puts an entry for the calling process, so it's removed when the process exits. Putting the same key again replaces
  the entry's data. Without the tables (the application isn't running) it does nothing, so nothing is removed.
  """
  @spec put(term(), term()) :: :ok
  def put(key, data) do
    # The owner is monitored before its entry exists, so a kill in between leaves nothing to remove. A server that's
    # down right then can't monitor it, so the call is made once more after the insert: either a new server answers it,
    # or the one that starts later finds the entry in `init/1`.
    owner = self()
    monitored = monitor(owner)
    :ets.insert(@entries, {{owner, key}, data})
    if !monitored, do: monitor(owner)
    :ok
  rescue
    # The table doesn't exist.
    ArgumentError -> :ok
  end

  @doc "Whether the tables exist, which they do while the application is running."
  @spec available?() :: boolean()
  def available?, do: :ets.whereis(@entries) != :undefined

  @doc "Whether any process has an entry for `key`."
  @spec member?(term()) :: boolean()
  def member?(key) do
    # The calling process is the usual owner, whose row is a lookup. Another owner's row takes a scan of the table.
    :ets.member(@entries, {self(), key}) or
      :ets.select(@entries, [{{{:_, key}, :_}, [], [true]}], 1) != :"$end_of_table"
  rescue
    ArgumentError -> false
  end

  @doc """
  Makes `pid` the owner of an entry of the calling process. Returns `:error` if the calling process doesn't own it.
  Giving an entry to the calling process itself does nothing.
  """
  @spec give_away(term(), pid()) :: :ok | :error
  def give_away(key, pid) do
    # As in `put/2`, `pid` is monitored before its row goes in, so a caller killed anywhere in between leaves rows
    # whose owners are monitored. The second call covers a `:DOWN` the server handled before the move (`pid` was dead
    # already) and a server that was down for the first one. It returns at once when `pid` is still monitored.
    monitor(pid)
    moved = move(key, pid)
    monitor(pid)

    if moved, do: :ok, else: :error
  rescue
    ArgumentError -> :error
  end

  # Moves the calling process's row for `key` to `pid`, if there is one. The new row goes in before the old one goes, so
  # a caller that's killed in between leaves a row for each owner, and its exit removes the directory, as it would have
  # without the move. Taking the old row out first would leave a directory that nobody removes.
  defp move(key, pid) do
    owner = self()

    case :ets.lookup(@entries, {owner, key}) do
      [{_key, _data}] when pid == owner ->
        true

      [{_key, data}] ->
        :ets.insert(@entries, {{pid, key}, data})
        :ets.delete(@entries, {owner, key})
        true

      [] ->
        false
    end
  end

  @doc """
  Removes the temporary directories of `owner` now. Its other entries stay, so a write in progress keeps its file.
  """
  @spec remove_tmp(pid()) :: :ok
  def remove_tmp(owner) do
    # Each entry goes once its directory is gone. If the caller is killed meanwhile, the rest stays until `owner` exits,
    # and the server removes it then.
    @entries
    |> :ets.match_object({{owner, {:tmp, :_}}, :_})
    |> Enum.each(fn {{_owner, {:tmp, root}}, _data} = entry ->
      _result = File.rm_rf(root)
      :ets.delete_object(@entries, entry)
    end)
  rescue
    ArgumentError -> :ok
  end

  @doc "Deletes an entry of the calling process, once it removed what the entry stands for itself."
  @spec delete(term()) :: :ok
  def delete(key) do
    :ets.delete(@entries, {self(), key})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Waits until the entries of every process that's gone are removed, also of those whose `:DOWN` hasn't arrived yet.
  Running cleanups make their second pass right away instead of after the grace period. For tests, so they neither
  sleep nor crash when another test restarts the server.
  """
  @spec sync(GenServer.server()) :: :ok
  def sync(server \\ __MODULE__) do
    GenServer.call(server, :sync, :infinity)
  catch
    :exit, {:noproc, _call} ->
      Process.sleep(1)
      sync(server)

    :exit, {:killed, _call} ->
      sync(server)
  end

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

  # The call waits the default 5 seconds. One that times out still reaches the server, which monitors `pid` when it
  # gets to it (a `pid` that's dead by then is `:DOWN` right away), so a timeout only delays the cleanup. The entry is
  # left behind only if the server crashes with the call still in its mailbox, and the second call of `put/2` is lost
  # the same way. That's accepted: the server does nothing but monitor and insert a row per call, so it only falls that
  # far behind on a node that's overloaded anyway, and a longer timeout would hold up every write then.
  #
  # Returns whether `pid` is monitored now. A server that's down can't answer, which the caller has to make up for.
  defp monitor(pid) do
    :ets.member(@owners, pid) or GenServer.call(__MODULE__, {:monitor, pid}) == :ok
  catch
    :exit, _reason -> false
  end

  @impl GenServer
  def init(nil) do
    Process.flag(:trap_exit, true)

    owners = :ets.select(@owners, [{{:"$1"}, [], [:"$1"]}])
    with_entries = :ets.select(@entries, [{{{:"$1", :_}, :_}, [], [:"$1"]}])

    owners
    |> Enum.concat(with_entries)
    |> Enum.uniq()
    |> Enum.each(&start_monitor/1)

    {:ok, %{cleanups: %{}, syncs: []}}
  end

  @impl GenServer
  def handle_call({:monitor, pid}, _from, state) do
    if !:ets.member(@owners, pid), do: start_monitor(pid)
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

    if state.cleanups == %{} do
      {:reply, :ok, state}
    else
      hurry(state)
      pending = MapSet.new(state.cleanups, fn {ref, _pid} -> ref end)
      {:noreply, %{state | syncs: [{from, pending} | state.syncs]}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    if Map.has_key?(state.cleanups, ref) do
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

  # Stopping doesn't wait out the grace period of the running cleanups.
  defp remove_all(state) do
    hurry(state)

    @entries
    |> :ets.tab2list()
    |> Enum.each(&remove/1)

    for {ref, _pid} <- state.cleanups do
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      end
    end
  end

  # A `pid` that's dead already gets its `:DOWN` right away.
  defp start_monitor(pid) do
    Process.monitor(pid)
    :ets.insert(@owners, {pid})
  end

  defp down(owner, state) do
    :ets.delete(@owners, owner)
    # A bound owner limits the match to that owner's rows. Only the rows it read are deleted: the owner is dead, but
    # `give_away/2` can put a row for it in between, and then calls the server once more, which reads that row.
    entries = :ets.match_object(@entries, {{owner, :_}, :_})

    if entries == [] do
      state
    else
      Enum.each(entries, &:ets.delete_object(@entries, &1))
      {pid, ref} = spawn_monitor(fn -> clean_up(entries) end)
      %{state | cleanups: Map.put(state.cleanups, ref, pid)}
    end
  end

  defp cleaned_up(ref, state) do
    {done, syncs} =
      state.syncs
      |> Enum.map(fn {from, pending} -> {from, MapSet.delete(pending, ref)} end)
      |> Enum.split_with(fn {_from, pending} -> MapSet.size(pending) == 0 end)

    Enum.each(done, fn {from, _pending} -> GenServer.reply(from, :ok) end)
    %{state | cleanups: Map.delete(state.cleanups, ref), syncs: syncs}
  end

  # Tells the running cleanups to make their second pass now.
  defp hurry(state), do: Enum.each(state.cleanups, fn {_ref, pid} -> send(pid, :now) end)

  # `hurry/1` skips the wait.
  defp clean_up(entries) do
    Enum.each(entries, &remove/1)

    receive do
      :now -> :ok
    after
      @grace -> :ok
    end

    Enum.each(entries, &remove/1)
  end

  # The write may have placed the file already (renamed or linked), which only makes the `File.rm/1` a no-op, since the
  # names are unique.
  defp remove({{_owner, {:file, tmp}}, created_dirs}) do
    _result = File.rm(tmp)
    remove_dirs(created_dirs)
  end

  # The second pass also covers an owner killed during its `mkdir`, and a tool it started that writes a moment longer.
  defp remove({{_owner, {:tmp, root}}, nil}) do
    _result = File.rm_rf(root)
    :ok
  end
end
