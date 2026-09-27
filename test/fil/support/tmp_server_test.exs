defmodule Fil.Support.TmpServerTest do
  # These tests stop the application or suspend the server, which the async tests in `Fil.Support.TmpTest` and
  # elsewhere rely on.
  alias Fil.Support.Tmp

  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  # Stopping the application logs a notice.
  @moduletag :capture_log

  setup %{tmp_dir: tmp_dir} do
    %{disk: Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)}
  end

  # Starts a write that sends its first chunk and then waits for `:go`, and returns once the temporary file exists.
  # The writer sends its result back.
  defp start_write(disk, path) do
    test = self()

    stream =
      Stream.map([:first, :second], fn
        :first ->
          "first"

        :second ->
          send(test, :writing)

          receive do
            :go -> "second"
          end
      end)

    writer = spawn(fn -> send(test, {:written, Fil.write(disk, path, stream)}) end)
    assert_receive :writing
    writer
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  # Every file and directory under `dir`, `.fil-` files included.
  defp tree(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&Path.relative_to(&1, dir))
  end

  test "stopping the application removes the files of writes in progress", %{disk: disk, tmp_dir: tmp_dir} do
    on_exit(fn -> {:ok, _apps} = Application.ensure_all_started(:fil) end)
    writer = start_write(disk, "new/a.txt")
    assert ["new", "new/.fil-" <> _suffix] = tree(tmp_dir)

    :ok = Application.stop(:fil)
    assert tree(tmp_dir) == []

    # The write goes on, and fails when it moves the file into place.
    send(writer, :go)
    assert_receive {:written, {:error, %Fil.NotFoundError{reason: :enoent}}}
  end

  test "Local writes work without the application", %{disk: disk, tmp_dir: tmp_dir} do
    on_exit(fn -> {:ok, _apps} = Application.ensure_all_started(:fil) end)
    :ok = Application.stop(:fil)

    assert {:ok, _} = Fil.write(disk, "new/a.txt", "content")
    assert_raise RuntimeError, fn -> Fil.write(disk, "other/a.txt", Stream.map([1], fn _ -> raise "failed" end)) end

    assert tree(tmp_dir) == ["new", "new/a.txt"]
  end

  # A second server stands in for the one the supervisor starts after a crash. The first one is suspended, so only the
  # second one handles the `:DOWN`s.
  test "a restarted server removes what the owners the tables name leave behind", %{disk: disk, tmp_dir: tmp_dir} do
    writer = start_write(disk, "new/a.txt")

    # An entry put while the server was down: the owner isn't in the owners table.
    orphan_dir = Path.join(tmp_dir, "orphan")
    orphan_file = Path.join(orphan_dir, ".fil-orphan")
    File.mkdir!(orphan_dir)
    File.write!(orphan_file, "")
    test = self()

    orphan =
      spawn(fn ->
        :ets.insert(Tmp, {{:file, orphan_file}, self(), [orphan_dir]})
        send(test, :inserted)
        Process.sleep(:infinity)
      end)

    assert_receive :inserted

    :ok = :sys.suspend(Tmp)
    on_exit(fn -> :sys.resume(Tmp) end)
    {:ok, restarted} = GenServer.start(Tmp, nil)
    on_exit(fn -> Process.exit(restarted, :kill) end)

    for owner <- [writer, orphan] do
      assert {:monitored_by, monitors} = Process.info(owner, :monitored_by)
      assert restarted in monitors
    end

    kill(writer)
    kill(orphan)
    Tmp.sync(restarted)

    assert tree(tmp_dir) == []
  end
end
