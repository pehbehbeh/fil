defmodule Fil.Kino.UploadTest do
  alias Fil.KinoHelper

  use ExUnit.Case, async: true

  import Kino.Test

  setup :configure_livebook_bridge
  setup {Fil.KinoHelper, :configure_uploads}

  setup do
    Fil.Adapter.Memory.checkout()

    {:ok, disk: Fil.disk(adapter: Fil.Adapter.Memory)}
  end

  test "writes an upload to the directory", %{disk: disk} do
    {input, frame} =
      disk
      |> Fil.Kino.upload("reports")
      |> KinoHelper.upload_field()

    KinoHelper.upload(input, "q3.pdf", "%PDF")

    assert KinoHelper.status(frame) == "Wrote reports/q3.pdf (4 B)"
    assert Fil.read(disk, "reports/q3.pdf") == {:ok, "%PDF"}
  end

  test "writes to the root", %{disk: disk} do
    {input, frame} =
      disk
      |> Fil.Kino.upload()
      |> KinoHelper.upload_field()

    KinoHelper.upload(input, "a.txt", "a")

    assert KinoHelper.status(frame) == "Wrote a.txt (1 B)"
    assert Fil.exists?(disk, "a.txt")
  end

  test "writes to the path of a ref", %{disk: disk} do
    {input, frame} =
      disk
      |> Fil.ref("inbox")
      |> Fil.Kino.upload()
      |> KinoHelper.upload_field()

    KinoHelper.upload(input, "b.txt", String.duplicate("b", 1500))

    assert KinoHelper.status(frame) == "Wrote inbox/b.txt (1.5 KB)"
    assert Fil.exists?(disk, "inbox/b.txt")
  end

  test "keeps an existing file by default, and stays usable", %{disk: disk} do
    Fil.write!(disk, "a.txt", "old")

    {input, frame} =
      disk
      |> Fil.Kino.upload()
      |> KinoHelper.upload_field()

    KinoHelper.upload(input, "a.txt", "new")
    assert KinoHelper.status(frame) =~ "the file already exists"
    assert Fil.read(disk, "a.txt") == {:ok, "old"}

    KinoHelper.upload(input, "b.txt", "b")
    assert KinoHelper.status(frame) == "Wrote b.txt (1 B)"
  end

  test "overwrites with if_exists: :overwrite", %{disk: disk} do
    Fil.write!(disk, "a.txt", "old")

    {input, frame} =
      disk
      |> Fil.Kino.upload(".", if_exists: :overwrite)
      |> KinoHelper.upload_field()

    KinoHelper.upload(input, "a.txt", "new")

    assert KinoHelper.status(frame) == "Wrote a.txt (3 B)"
    assert Fil.read(disk, "a.txt") == {:ok, "new"}
  end

  test "refuses names that aren't plain file names", %{disk: disk} do
    {input, frame} =
      disk
      |> Fil.Kino.upload("reports")
      |> KinoHelper.upload_field()

    for name <- ["..", ".", "", "a/b", "a\\b", "../a.txt"] do
      KinoHelper.upload(input, name, "x")
      assert KinoHelper.status(frame) == "invalid file name: #{inspect(name)}"
    end

    assert Fil.ls(disk, ".", recursive: true) == {:ok, []}
  end

  test "calls on_upload with the ref", %{disk: disk} do
    test = self()

    {input, frame} =
      disk
      |> Fil.Kino.upload("reports", on_upload: &send(test, {:uploaded, &1}))
      |> KinoHelper.upload_field()

    KinoHelper.upload(input, "q3.pdf", "%PDF")

    assert KinoHelper.status(frame) == "Wrote reports/q3.pdf (4 B)"
    assert_receive {:uploaded, %Fil.Ref{path: "reports/q3.pdf"}}
  end

  test "shows a storage error", %{disk: disk} do
    failing =
      Fil.attach(disk, :unavailable, fn op, _next, _opts ->
        Fil.Op.put_result(op, {:error, %Fil.UnavailableError{reason: :timeout}})
      end)

    {input, frame} =
      failing
      |> Fil.Kino.upload()
      |> KinoHelper.upload_field()

    KinoHelper.upload(input, "a.txt", "a")

    assert KinoHelper.status(frame) =~ "the storage is unavailable"
  end

  test "labels the field with the disk and the path", %{disk: disk} do
    assert label(Fil.Kino.upload(disk, "reports")) == "Upload to memory:reports"
    assert label(Fil.Kino.upload(disk)) == "Upload to memory"
    assert label(Fil.Kino.upload(disk, ".", label: "Invoices")) == "Invoices"
  end

  test "passes accept: to the input", %{disk: disk} do
    {input, _frame} =
      disk
      |> Fil.Kino.upload(".", accept: [".pdf"])
      |> KinoHelper.upload_field()

    assert input.attrs.accept == [".pdf"]
  end

  test "bad options raise ArgumentError", %{disk: disk} do
    assert_raise ArgumentError, ~r/if_exists/, fn -> Fil.Kino.upload(disk, ".", if_exists: :skip) end
    assert_raise ArgumentError, ~r/on_upload/, fn -> Fil.Kino.upload(disk, ".", on_upload: fn -> :ok end) end
  end

  defp label(field) do
    {input, _frame} = KinoHelper.upload_field(field)
    input.attrs.label
  end
end
