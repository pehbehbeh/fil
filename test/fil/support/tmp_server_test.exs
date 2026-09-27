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
end
