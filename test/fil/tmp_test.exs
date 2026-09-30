defmodule Fil.TmpTest do
  alias Fil.Support.Tmp

  use ExUnit.Case, async: true

  import Bitwise

  # Runs `fun` in a new process that stays alive until it's killed, and returns the process and what `fun` returned.
  defp spawn_owner(fun) do
    test = self()

    owner =
      spawn(fn ->
        send(test, {:created, fun.()})
        Process.sleep(:infinity)
      end)

    assert_receive {:created, result}, 1_000
    {owner, result}
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
  end

  # The temporary directory a ref is on.
  defp dir(tmp), do: Fil.Tmp.path(tmp.disk, ".")

  # The temporary directories `pid` owns.
  defp owned(pid) do
    Tmp
    |> :ets.match({{pid, {:tmp, :"$1"}}, :_})
    |> List.flatten()
    |> Enum.sort()
  end

  # A pid on a node that isn't connected, decoded from the external term format (`NEW_PID_EXT`).
  defp remote_pid do
    node = "other@example"
    :erlang.binary_to_term(<<131, 88, 119, byte_size(node), node::binary, 1::32, 0::32, 1::32>>)
  end

  test "creates a directory that only its user can open" do
    frames = Fil.tmp()
    dir = Fil.Tmp.path(frames)

    assert frames.path == "."
    assert Path.dirname(dir) == Path.expand(System.tmp_dir!())
    assert Path.basename(dir) =~ ~r/^fil-/
    assert %File.Stat{type: :directory, mode: mode} = File.stat!(dir)
    assert (mode &&& 0o777) == 0o700
  end

  test "creates a directory per call" do
    report = Fil.tmp("report.pdf")
    other = Fil.tmp("report.pdf")

    assert report.path == "report.pdf"
    dir = dir(report)

    refute dir == dir(other)
    assert File.dir?(dir)

    refute report
           |> Fil.Tmp.path()
           |> File.exists?()
  end

  test "works with the whole API" do
    report = Fil.tmp("reports/q3.pdf")

    assert {:ok, ^report} = Fil.write(report, "pdf")
    assert {:ok, "pdf"} = Fil.read(report)
    assert {:ok, [%Fil.Ref{path: "reports/q3.pdf"}]} = Fil.ls(report.disk, ".", recursive: true)
    assert {:ok, _} = Fil.rm(report)
    refute Fil.exists?(report)
  end

  test "takes a copy from another disk" do
    Fil.Adapter.Memory.checkout()
    invoices = Fil.disk(adapter: Fil.Adapter.Memory)
    Fil.write!(invoices, "2026/09.pdf", "invoice")
    source = Fil.ref(invoices, "2026/09.pdf")
    invoice = Fil.tmp("09.pdf")

    assert {:ok, ^invoice} = Fil.cp(source, invoice)
    path = Fil.Tmp.path(invoice)
    assert File.read!(path) == "invoice"
  end

  test "path/1 returns the path of the directory and of anything on its disk" do
    report = Fil.tmp("report.pdf")
    dir = Fil.Tmp.path(%{report | path: "."})

    page = Fil.ref(report.disk, "pages/1.png")

    assert Fil.Tmp.path(report) == Path.join(dir, "report.pdf")
    assert Fil.Tmp.path(page) == Path.join(dir, "pages/1.png")
    assert Fil.Tmp.path(report.disk, "./pages//1.png") == Path.join(dir, "pages/1.png")
    assert Fil.Tmp.path(report.disk, "") == dir
  end

  test "lists what a tool wrote into the directory" do
    frames = Fil.tmp()
    dir = Fil.Tmp.path(frames)
    first = Path.join(dir, "001.png")
    second = Fil.Tmp.path(frames.disk, "002.png")
    File.write!(first, "png")
    File.write!(second, "png")

    assert {:ok, pngs} = Fil.ls(frames)
    paths = Enum.map(pngs, & &1.path)
    assert Enum.sort(paths) == ["001.png", "002.png"]
  end

  test "path/1 raises for refs on other disks and outside the directory" do
    local = Fil.disk(adapter: Fil.Adapter.Local, root: System.tmp_dir!())
    memory = Fil.disk(adapter: Fil.Adapter.Memory)
    frames = Fil.tmp()
    escape = %Fil.Ref{disk: frames.disk, path: "../a.txt"}

    assert_raise ArgumentError, ~r/from Fil.tmp/, fn -> Fil.Tmp.path(local, "a.txt") end
    assert_raise ArgumentError, ~r/from Fil.tmp/, fn -> Fil.Tmp.path(memory, "a.txt") end
    assert_raise ArgumentError, ~r/outside the temporary directory/, fn -> Fil.Tmp.path(escape) end
  end

  test "names that aren't relative paths inside the directory raise before anything is created" do
    for name <- ["/etc/passwd", "", ".", "a/..", "../a.txt", "a/../../b.txt", "a\0.txt"] do
      assert_raise ArgumentError, ~r/expected a relative path inside the temporary directory/, fn -> Fil.tmp(name) end
    end

    assert owned(self()) == []
  end

  test "the directory is removed when its owner exits" do
    test = self()

    owner =
      spawn(fn ->
        report = Fil.tmp("report.pdf")
        Fil.write!(report, "pdf")
        send(test, {:created, dir(report)})
      end)

    assert_receive {:created, dir}, 1_000
    # The owner may be gone before the monitor starts.
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 1_000
    Tmp.sync()

    refute File.exists?(dir)
  end

  test "the directory is removed when its owner is killed" do
    {owner, report} =
      spawn_owner(fn ->
        report = Fil.tmp("report.pdf")
        Fil.write!(report, "pdf")
        report
      end)

    dir = dir(report)
    kill(owner)
    Tmp.sync()

    refute File.exists?(dir)
    assert_raise ArgumentError, ~r/removed already/, fn -> Fil.Tmp.path(report) end
  end

  test "give_away/2 keeps the directory until the new owner exits" do
    {new_owner, nil} = spawn_owner(fn -> nil end)
    report = Fil.tmp("report.pdf")
    Fil.write!(report, "pdf")
    dir = dir(report)

    assert Fil.Tmp.give_away(report, new_owner) == :ok
    assert owned(self()) == []
    assert owned(new_owner) == [dir]
    assert Fil.Tmp.cleanup() == :ok
    assert Fil.read(report) == {:ok, "pdf"}

    kill(new_owner)
    Tmp.sync()

    refute File.exists?(dir)
  end

  test "give_away/2 keeps the directory when the first owner exits first" do
    {new_owner, nil} = spawn_owner(fn -> nil end)

    {first_owner, report} =
      spawn_owner(fn ->
        report = Fil.tmp("report.pdf")
        Fil.write!(report, "pdf")
        :ok = Fil.Tmp.give_away(report, new_owner)
        report
      end)

    dir = dir(report)
    kill(first_owner)
    Tmp.sync()

    assert Fil.read(report) == {:ok, "pdf"}

    kill(new_owner)
    Tmp.sync()

    refute File.exists?(dir)
  end

  test "give_away/2 to a dead process removes the directory" do
    {dead, nil} = spawn_owner(fn -> nil end)
    kill(dead)
    frames = Fil.tmp()
    dir = dir(frames)

    assert Fil.Tmp.give_away(frames, dead) == :ok
    Tmp.sync()

    refute File.exists?(dir)
  end

  test "give_away/2 to the owner itself changes nothing" do
    frames = Fil.tmp()

    assert Fil.Tmp.give_away(frames, self()) == :ok
    assert owned(self()) == [dir(frames)]
  end

  test "give_away/2 raises for a directory the caller doesn't own" do
    {owner, frames} = spawn_owner(&Fil.tmp/0)
    local = Fil.disk(adapter: Fil.Adapter.Local, root: System.tmp_dir!())
    other = Fil.ref(local, ".")

    assert_raise ArgumentError, ~r/doesn't own/, fn -> Fil.Tmp.give_away(frames, self()) end
    # Also when the directory would go to the process that owns it.
    assert_raise ArgumentError, ~r/doesn't own/, fn -> Fil.Tmp.give_away(frames, owner) end
    assert_raise ArgumentError, ~r/from Fil.tmp/, fn -> Fil.Tmp.give_away(other, owner) end
    assert owned(owner) == [dir(frames)]
  end

  test "give_away/2 raises for a process on another node" do
    frames = Fil.tmp()
    pid = remote_pid()

    assert_raise ArgumentError, ~r/only exists on/, fn -> Fil.Tmp.give_away(frames, pid) end
  end

  test "cleanup/1 removes the directories of a process now" do
    frames = Fil.tmp()
    report = Fil.tmp("report.pdf")
    Fil.write!(report, "pdf")
    dirs = [dir(frames), dir(report)]
    {owner, other} = spawn_owner(&Fil.tmp/0)

    assert Fil.Tmp.cleanup() == :ok

    refute Enum.any?(dirs, &File.exists?/1)
    assert owned(self()) == []
    assert owned(owner) == [dir(other)]
    assert Fil.Tmp.cleanup() == :ok
    assert_raise ArgumentError, ~r/removed already/, fn -> Fil.Tmp.path(frames) end
  end

  test "cleanup/1 removes the directories of another process" do
    {owner, frames} = spawn_owner(&Fil.tmp/0)
    dir = dir(frames)

    assert Fil.Tmp.cleanup(owner) == :ok
    refute File.exists?(dir)
    assert owned(owner) == []
  end

  @tag :tmp_dir
  test "cleanup/1 leaves a write in progress alone", %{tmp_dir: tmp_dir} do
    disk = Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)
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

    writer =
      spawn(fn ->
        send(test, {:created, Fil.tmp()})
        send(test, {:written, Fil.write(disk, "a.txt", stream)})
      end)

    assert_receive {:created, frames}, 1_000
    assert_receive :writing, 1_000

    dir = dir(frames)

    assert Fil.Tmp.cleanup(writer) == :ok
    refute File.exists?(dir)
    send(writer, :go)

    assert_receive {:written, {:ok, _}}, 1_000
    assert Fil.read(disk, "a.txt") == {:ok, "firstsecond"}
  end
end
