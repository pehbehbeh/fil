defmodule Fil.Adapter.NullTest do
  alias Fil.Adapter.Null
  alias Fil.Op

  use ExUnit.Case, async: true

  setup do
    [disk: Fil.disk(adapter: Null)]
  end

  describe "init/1" do
    test "takes no options" do
      assert {:ok, %Null{}} = Null.init([])
      assert {:error, %NimbleOptions.ValidationError{}} = Null.init(root: "uploads")
    end
  end

  describe "writes" do
    test "succeed and keep nothing", %{disk: disk} do
      assert {:ok, %Fil.Ref{path: "a.txt"}} = Fil.write(disk, "a.txt", "hello")
      assert {:ok, _} = Fil.write(disk, "a.txt", "again", if_exists: :error, checksum: :sha256)

      assert {:error, %Fil.NotFoundError{op: :read, path: "a.txt", reason: :enoent}} = Fil.read(disk, "a.txt")
    end

    test "read a stream to the end", %{disk: disk} do
      test = self()
      stream = Stream.map(["ab", "cd"], &send(test, {:pulled, &1}))

      assert {:ok, _} = Fil.write(disk, "a.txt", Stream.map(stream, fn {:pulled, chunk} -> chunk end))
      assert_received {:pulled, "ab"}
      assert_received {:pulled, "cd"}
    end

    test "fail when the stream raises", %{disk: disk} do
      stream = Stream.map(["ab", "cd"], fn _chunk -> raise %Fil.UnavailableError{reason: :timeout} end)

      assert {:error, %Fil.UnavailableError{op: :write, path: "a.txt"}} = Fil.write(disk, "a.txt", stream)
    end

    test "fail when the stream has another size than declared", %{disk: disk} do
      assert_raise ArgumentError, fn -> Fil.write(disk, "a.txt", Stream.map(["ab"], & &1), size: 3) end
    end

    test "run the plugins, which can refuse the content", %{disk: disk} do
      disk =
        Fil.attach(disk, :refuse_secrets, fn op, next, _opts ->
          op
          |> Op.scan_content(
            nil,
            fn chunk, acc ->
              if chunk =~ "secret", do: raise(%Fil.InvalidContentError{reason: :secret}), else: acc
            end,
            fn _acc -> :ok end
          )
          |> next.()
        end)

      assert {:ok, _} = Fil.write(disk, "a.txt", Stream.map(["fine"], & &1))

      assert {:error, %Fil.InvalidContentError{op: :write, reason: :secret}} =
               Fil.write(disk, "a.txt", Stream.map(["a secret"], & &1))
    end

    test "succeed for a copy from another disk", %{disk: disk} do
      Fil.Adapter.Memory.checkout()
      memory = Fil.disk(adapter: Fil.Adapter.Memory)
      {:ok, report} = Fil.write(memory, "report.txt", "q3")

      assert {:ok, %Fil.Ref{path: "copy.txt"}} = Fil.cp(report, Fil.ref(disk, "copy.txt"))
      assert {:ok, %Fil.Ref{path: "moved.txt"}} = Fil.rename(report, Fil.ref(disk, "moved.txt"))
      refute Fil.exists?(memory, "report.txt")
    end
  end

  describe "reads" do
    test "find no file", %{disk: disk} do
      assert {:error, %Fil.NotFoundError{op: :read, reason: :enoent}} = Fil.read(disk, "a.txt")
      assert {:error, %Fil.NotFoundError{op: :read, reason: :enoent}} = Fil.stream(disk, "a.txt")
      assert {:error, %Fil.NotFoundError{op: :stat, reason: :enoent}} = Fil.stat(disk, "a.txt")
      refute Fil.exists?(disk, "a.txt")
      refute Fil.dir?(disk, "reports")
    end

    test "see the root as an empty directory", %{disk: disk} do
      assert {:ok, %Fil.Stat{type: :directory}} = Fil.stat(disk, ".")
      assert Fil.dir?(disk, ".")
      assert {:ok, []} = Fil.ls(disk, ".")
      assert {:ok, []} = Fil.ls(disk, "reports", recursive: true)
      assert {:ok, []} = Fil.wildcard(disk, "**/*.txt")
    end
  end

  describe "removals" do
    test "succeed and remove nothing", %{disk: disk} do
      assert {:ok, _} = Fil.rm(disk, "a.txt")
      assert {:ok, 0} = Fil.rm_rf(disk, "reports")
    end
  end

  describe "copies and moves on the disk" do
    test "find no source", %{disk: disk} do
      assert {:error, %Fil.NotFoundError{op: :cp, path: "a.txt", reason: :enoent}} = Fil.cp(disk, "a.txt", "b.txt")

      assert {:error, %Fil.NotFoundError{op: :rename, path: "a.txt", reason: :enoent}} =
               Fil.rename(disk, "a.txt", "b.txt")
    end
  end

  describe "URLs" do
    test "need Fil.Plugin.URL", %{disk: disk} do
      assert {:error, %Fil.UnsupportedError{reason: :no_callback}} = Fil.url(disk, "a.txt")
      assert {:error, %Fil.UnsupportedError{reason: :no_callback}} = Fil.signed_url(disk, "a.txt")
    end

    test "with Fil.Plugin.URL, Fil.Plug answers downloads with a 404 and drops uploads", %{disk: disk} do
      disk = Fil.Plugin.URL.attach(disk, base_url: "http://localhost/storage", secret: "secret")

      url = Fil.signed_url!(disk, "a.txt")
      assert {404, _headers, _body} = Fil.AdapterCase.plug_request(disk, :get, url, [])

      upload = Fil.signed_upload!(disk, "a.txt")
      assert {200, _headers, _body} = Fil.AdapterCase.plug_request(disk, upload.method, upload.url, body: "hello")
      assert {:error, %Fil.NotFoundError{}} = Fil.read(disk, "a.txt")
    end
  end

  describe "same storage" do
    test "is true for any two null disks", %{disk: disk} do
      assert Fil.Disk.same_storage?(disk, Fil.disk(adapter: Null))
      refute Fil.Disk.same_storage?(disk, Fil.disk(adapter: Fil.Adapter.Memory))
    end
  end
end
