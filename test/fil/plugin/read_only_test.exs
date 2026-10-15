defmodule Fil.Plugin.ReadOnlyTest do
  alias Fil.Adapter.Memory
  alias Fil.Plugin.ReadOnly

  use ExUnit.Case, async: true

  setup do
    Memory.checkout()
    writable = Fil.disk(adapter: Memory)
    Fil.write!(writable, "notes.txt", "keep")
    {:ok, writable: writable, disk: ReadOnly.attach(writable)}
  end

  defp read_only?({:error, %Fil.AccessDeniedError{reason: :read_only}}), do: true
  defp read_only?(_result), do: false

  test "refuses writes and leaves the file as it was", %{disk: disk} do
    assert disk
           |> Fil.write("notes.txt", "changed")
           |> read_only?()

    assert disk
           |> Fil.write("new.txt", Stream.map(["a", "b"], & &1))
           |> read_only?()

    assert Fil.read(disk, "notes.txt") == {:ok, "keep"}
    assert Fil.exists?(disk, "new.txt") == false
  end

  test "refuses deletes, also of a missing file", %{disk: disk} do
    assert disk
           |> Fil.rm("notes.txt")
           |> read_only?()

    assert disk
           |> Fil.rm("missing.txt")
           |> read_only?()

    assert disk
           |> Fil.rm_rf(".")
           |> read_only?()

    assert Fil.read(disk, "notes.txt") == {:ok, "keep"}
  end

  test "refuses copies and moves within the disk", %{disk: disk} do
    assert disk
           |> Fil.cp("notes.txt", "copy.txt")
           |> read_only?()

    assert disk
           |> Fil.rename("notes.txt", "moved.txt")
           |> read_only?()

    assert {:ok, [%Fil.Ref{path: "notes.txt"}]} = Fil.ls(disk, ".")
  end

  test "refuses copies from another disk and leaves the source of a move", %{disk: disk} do
    other = Fil.disk(adapter: Memory, root: "other")
    Fil.write!(other, "incoming.txt", "new")
    notes = Fil.ref(disk, "notes.txt")

    assert other
           |> Fil.ref("incoming.txt")
           |> Fil.cp(Fil.ref(disk, "incoming.txt"))
           |> read_only?()

    assert notes
           |> Fil.rename(Fil.ref(other, "notes.txt"))
           |> read_only?()

    assert Fil.read(notes) == {:ok, "keep"}
    assert Fil.read(other, "notes.txt") == {:ok, "keep"}
  end

  test "copies to another disk", %{disk: disk} do
    other = Fil.disk(adapter: Memory, root: "other")
    copy = Fil.ref(other, "copy.txt")

    assert disk
           |> Fil.ref("notes.txt")
           |> Fil.cp(copy) == {:ok, copy}

    assert Fil.read(copy) == {:ok, "keep"}
  end

  test "refuses signed uploads", %{disk: disk} do
    disk = Fil.Plugin.URL.attach(disk, base_url: "https://files.example.com", secret: String.duplicate("s", 32))

    assert disk
           |> Fil.signed_upload("upload.txt")
           |> read_only?()

    assert {:ok, _url} = Fil.signed_url(disk, "notes.txt")
  end

  test "lets reads, streams, stats and listings through", %{disk: disk} do
    assert Fil.read(disk, "notes.txt") == {:ok, "keep"}
    assert {:ok, stream} = Fil.stream(disk, "notes.txt")
    assert Enum.join(stream) == "keep"
    assert {:ok, %Fil.Stat{size: 4}} = Fil.stat(disk, "notes.txt")
    assert Fil.exists?(disk, "notes.txt")
    assert {:ok, [_notes]} = Fil.ls(disk, ".")
  end

  test "fills in the error's context", %{disk: disk} do
    assert {:error, error} = Fil.write(disk, "./notes.txt", "changed")
    assert {error.op, error.path, error.disk, error.reason} == {:write, "notes.txt", disk, :read_only}
    assert Exception.message(error) =~ "access denied (:read_only)"
  end

  test "works from the plugins: option of Fil.disk/1", %{writable: writable} do
    disk = Fil.disk(adapter: Memory, plugins: [{ReadOnly, :call, []}])

    assert disk
           |> Fil.write("notes.txt", "changed")
           |> read_only?()

    assert Fil.read(writable, "notes.txt") == {:ok, "keep"}
  end

  test "refuses options" do
    disk = Fil.disk(adapter: Memory)
    assert_raise NimbleOptions.ValidationError, fn -> ReadOnly.attach(disk, nope: true) end
  end
end
