defmodule Fil.Adapter.LocalTest do
  alias Fil.Adapter.Local

  use Fil.AdapterCase, async: true

  def fil_disk(%{tmp_dir: tmp_dir}) do
    [adapter: Local, root: Path.join(tmp_dir, "primary")]
    |> Fil.disk()
    |> Fil.Plugin.URL.attach(base_url: "http://localhost/storage", secret: "secret")
  end

  describe "init/1" do
    test "defaults the root to the current directory at build time" do
      {:ok, state} = Local.init([])

      assert state.root == File.cwd!()
    end

    test "expands a relative root once" do
      {:ok, state} = Local.init(root: "priv/storage")

      assert state.root == Path.expand("priv/storage")
    end

    test "rejects a root that is not a path" do
      assert {:error, %NimbleOptions.ValidationError{key: :root}} = Local.init(root: :nope)

      assert_raise ArgumentError, ~r/invalid value for :root option: expected string/, fn ->
        Fil.disk(adapter: Local, root: :nope)
      end
    end

    test "rejects an option nobody knows" do
      assert_raise ArgumentError, ~r/unknown options \[:rooot\]/, fn ->
        Fil.disk(adapter: Local, rooot: "/tmp")
      end
    end
  end

  describe "the jail" do
    test "applies when the adapter is called directly", %{tmp_dir: tmp_dir} do
      {:ok, state} = Local.init(root: tmp_dir)

      assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Local.read(state, "../../etc/passwd", [])
      assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Local.write(state, "../escape.txt", "x", [])

      refute tmp_dir
             |> Path.join("../escape.txt")
             |> File.exists?()
    end

    test "does not confuse a sibling directory with the root", %{tmp_dir: tmp_dir} do
      {:ok, state} = Local.init(root: Path.join(tmp_dir, "root"))

      tmp_dir
      |> Path.join("root-sibling")
      |> File.mkdir_p!()

      tmp_dir
      |> Path.join("root-sibling/secret.txt")
      |> File.write!("secret")

      assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Local.read(state, "../root-sibling/secret.txt", [])
    end
  end

  describe "writes" do
    test "leave no temporary files behind", %{disk: disk, tmp_dir: tmp_dir} do
      assert {:ok, _} = Fil.write(disk, "nested/a.txt", "content")

      leftovers =
        Path.join(tmp_dir, "primary/nested")
        |> File.ls!()
        |> Enum.filter(&String.contains?(&1, ".fil-"))

      assert leftovers == []
    end

    test "are atomic: readers never see a partial file", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "atomic.txt", "first content")
      assert {:ok, _} = Fil.write(disk, "atomic.txt", "second")
      assert Fil.read(disk, "atomic.txt") == {:ok, "second"}
    end

    test "if_exists: :error does not truncate the existing file", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "once.txt", "original")

      assert {:error, %Fil.AlreadyExistsError{reason: :eexist}} =
               Fil.write(disk, "once.txt", "clobber", if_exists: :error)

      assert Fil.read(disk, "once.txt") == {:ok, "original"}
    end
  end

  describe "stat/1" do
    test "derives a weak etag that changes with the content", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "etag.txt", "small")
      assert {:ok, first} = Fil.stat(disk, "etag.txt")

      assert {:ok, _} = Fil.write(disk, "etag.txt", "considerably larger content")
      assert {:ok, second} = Fil.stat(disk, "etag.txt")

      assert first.etag != second.etag
      assert first.content_type == nil
    end

    test "computes a checksum from the file and ignores the option on writes and reads", %{disk: disk} do
      content = :crypto.strong_rand_bytes(200_000)

      checksum =
        :sha256
        |> :crypto.hash(content)
        |> Base.encode64()

      assert {:ok, _} = Fil.write(disk, "big.bin", content, checksum: :sha256)
      assert {:ok, %Fil.Stat{checksum: {:sha256, ^checksum}}} = Fil.stat(disk, "big.bin", checksum: :sha256)
      assert Fil.read(disk, "big.bin", verify_checksum: true) == {:ok, content}
    end

    test "a directory has no checksum", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "dir/file.txt", "content")
      assert {:ok, %Fil.Stat{type: :directory, checksum: nil}} = Fil.stat(disk, "dir", checksum: :crc32)
    end
  end

  describe "errors" do
    test "a directory is :eisdir", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "dir/file.txt", "content")

      assert {:error, %Fil.InvalidRequestError{reason: :eisdir}} = Fil.read(disk, "dir")
      assert {:error, %Fil.InvalidRequestError{reason: :eisdir}} = Fil.cp(disk, "dir", "copy.txt")
      assert {:error, %Fil.InvalidRequestError{reason: :eisdir}} = Fil.write(disk, "dir", "content")

      assert {:error, %Fil.InvalidRequestError{reason: :eisdir}} =
               Fil.write(disk, "dir", "content", if_exists: :error)
    end

    test "a path under a file is :enotdir", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "file.txt", "content")

      assert {:error, %Fil.InvalidRequestError{reason: :enotdir}} = Fil.write(disk, "file.txt/child.txt", "child")

      assert {:error, %Fil.InvalidRequestError{reason: :enotdir}} =
               Fil.write(disk, "file.txt/deeper/child.txt", "child")

      assert {:error, %Fil.InvalidRequestError{reason: :enotdir, path: "file.txt/copy.txt"}} =
               Fil.cp(disk, "file.txt", "file.txt/copy.txt")
    end
  end

  describe "rm/1" do
    test "refuses to delete a directory", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "dir/file.txt", "content")
      assert {:error, %Fil.InvalidRequestError{reason: :eisdir}} = Fil.rm(disk, "dir")
      assert Fil.read(disk, "dir/file.txt") == {:ok, "content"}
    end
  end

  describe "url/2 and signed_url/2" do
    test "needs Fil.Plugin.URL", %{tmp_dir: tmp_dir} do
      disk = Fil.disk(adapter: Local, root: tmp_dir)

      assert {:error, %Fil.UnsupportedError{op: :url, reason: :no_callback}} = Fil.url(disk, "a.txt")
      assert {:error, %Fil.UnsupportedError{op: :signed_url, reason: :no_callback}} = Fil.signed_url(disk, "a.txt")
    end
  end
end
