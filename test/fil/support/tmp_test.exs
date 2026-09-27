defmodule Fil.Support.TmpTest do
  alias Fil.Support.Tmp

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    tmp_dir
    |> Path.join("kept")
    |> File.mkdir_p!()

    %{disk: Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)}
  end

  # Starts a write that sends its first chunk and then waits forever, and returns once the temporary file exists.
  defp start_write(disk, path) do
    test = self()

    stream =
      Stream.map([:first, :second], fn
        :first ->
          "first"

        :second ->
          send(test, :writing)
          Process.sleep(:infinity)
      end)

    writer = spawn(fn -> Fil.write(disk, path, stream) end)
    assert_receive :writing
    writer
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp entries(pid), do: :ets.match_object(Tmp, {:_, pid, :_})

  # Every file and directory under `dir`, `.fil-` files included.
  defp tree(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&Path.relative_to(&1, dir))
  end

  test "a finished write leaves no entry", %{disk: disk} do
    assert {:ok, _} = Fil.write(disk, "kept/a.txt", "content")
    assert {:error, _} = Fil.write(disk, "kept/a.txt/b.txt", "content")

    assert entries(self()) == []
  end

  test "a killed write leaves no temporary file and no directory it created", %{disk: disk, tmp_dir: tmp_dir} do
    writer = start_write(disk, "kept/new/deeper/a.txt")

    assert [{{:file, tmp}, ^writer, created}] = entries(writer)
    assert Path.basename(tmp) =~ ~r/^\.fil-/
    assert created == [Path.join(tmp_dir, "kept/new/deeper"), Path.join(tmp_dir, "kept/new")]
    assert File.exists?(tmp)

    kill(writer)
    Tmp.sync()

    assert tree(tmp_dir) == ["kept"]
    assert entries(writer) == []
  end

  test "a killed write keeps a directory another write put a file into", %{disk: disk, tmp_dir: tmp_dir} do
    writer = start_write(disk, "new/a.txt")
    assert {:ok, _} = Fil.write(disk, "new/b.txt", "content")

    kill(writer)
    Tmp.sync()

    assert tree(tmp_dir) == ["kept", "new", "new/b.txt"]
  end

  test "an owner killed while it creates its directories leaves none of them", %{tmp_dir: tmp_dir} do
    [deepest, middle, top] = Enum.map(["new/a/b", "new/a", "new"], &Path.join(tmp_dir, &1))
    File.mkdir!(top)
    test = self()

    owner =
      spawn(fn ->
        Tmp.put({:file, Path.join(deepest, ".fil-planned")}, [deepest, middle, top])
        send(test, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    kill(owner)
    Tmp.sync()

    assert tree(tmp_dir) == ["kept"]
  end
end
