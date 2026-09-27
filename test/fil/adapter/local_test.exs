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

    test "hide the temporary file of a streamed write from listings", %{disk: disk, tmp_dir: tmp_dir} do
      test = self()

      stream =
        Stream.map([:first, :second], fn
          :first ->
            "first"

          :second ->
            send(test, {:writing, self()})

            receive do
              :go -> "second"
            end
        end)

      task = Task.async(fn -> Fil.write(disk, "inbox/a.txt", stream) end)
      assert_receive {:writing, writer}

      inbox = Path.join(tmp_dir, "primary/inbox")
      assert [".fil-" <> _suffix] = File.ls!(inbox)
      assert Fil.ls(disk, "inbox") == {:ok, []}
      assert Fil.ls(disk, ".", recursive: true) == {:ok, []}

      send(writer, :go)
      assert {:ok, _} = Task.await(task)
      assert {:ok, [written]} = Fil.ls(disk, "inbox")
      assert written.path == "inbox/a.txt"
      assert File.ls!(inbox) == ["a.txt"]
    end

    test "that fail remove the directories they created, and only those", %{disk: disk, tmp_dir: tmp_dir} do
      assert {:ok, _} = Fil.write(disk, "kept/x.txt", "x")
      failing = Stream.map([1, 2], fn _chunk -> raise "the upload broke off" end)

      assert_raise RuntimeError, fn -> Fil.write(disk, "kept/new/deeper/a.txt", failing) end
      assert_raise RuntimeError, fn -> Fil.write(disk, "fresh/a.txt", failing, if_exists: :error) end

      root = Path.join(tmp_dir, "primary")
      assert File.ls!(root) == ["kept"]

      assert root
             |> Path.join("kept")
             |> File.ls!() == ["x.txt"]
    end

    test "under a file create no directories", %{disk: disk, tmp_dir: tmp_dir} do
      assert {:ok, _} = Fil.write(disk, "file.txt", "content")

      assert {:error, %Fil.InvalidRequestError{reason: :enotdir}} = Fil.write(disk, "file.txt/deeper/child.txt", "x")

      assert tmp_dir
             |> Path.join("primary")
             |> File.ls!() == ["file.txt"]
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

  describe "copies and moves with if_exists: :error" do
    test "that fail leave no temporary files behind", %{disk: disk, tmp_dir: tmp_dir} do
      assert {:ok, _} = Fil.write(disk, "source.txt", "source")
      assert {:ok, _} = Fil.write(disk, "kept/taken.txt", "taken")

      assert {:error, %Fil.AlreadyExistsError{reason: :eexist}} =
               Fil.cp(disk, "source.txt", "kept/taken.txt", if_exists: :error)

      assert {:error, %Fil.InvalidRequestError{reason: :enotdir, path: "source.txt/deeper/copy.txt"}} =
               Fil.cp(disk, "source.txt", "source.txt/deeper/copy.txt", if_exists: :error)

      root = Path.join(tmp_dir, "primary")

      assert root
             |> File.ls!()
             |> Enum.sort() == ["kept", "source.txt"]

      assert root
             |> Path.join("kept")
             |> File.ls!() == ["taken.txt"]
    end

    test "onto a directory or from a directory are :eisdir", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "source.txt", "source")
      assert {:ok, _} = Fil.write(disk, "dir/file.txt", "content")

      assert {:error, %Fil.InvalidRequestError{reason: :eisdir, path: "dir"}} =
               Fil.cp(disk, "source.txt", "dir", if_exists: :error)

      assert {:error, %Fil.InvalidRequestError{reason: :eisdir, path: "dir"}} =
               Fil.rename(disk, "source.txt", "dir", if_exists: :error)

      assert {:error, %Fil.InvalidRequestError{reason: :eisdir, path: "dir"}} =
               Fil.cp(disk, "dir", "copy", if_exists: :error)

      assert Fil.read(disk, "source.txt") == {:ok, "source"}
    end

    test "keep the source's permissions, like File.cp/2", %{disk: disk, tmp_dir: tmp_dir} do
      assert {:ok, _} = Fil.write(disk, "run.sh", "echo")

      root = Path.join(tmp_dir, "primary")
      source = Path.join(root, "run.sh")
      copy = Path.join(root, "copies/run.sh")
      File.chmod!(source, 0o750)

      assert {:ok, _} = Fil.cp(disk, "run.sh", "copies/run.sh", if_exists: :error)
      assert %File.Stat{mode: mode} = File.stat!(copy)
      assert Bitwise.band(mode, 0o7777) == 0o750
    end

    test "move a directory as before", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "dir/file.txt", "content")
      assert {:ok, _} = Fil.rename(disk, "dir", "moved/dir", if_exists: :error)
      assert Fil.read(disk, "moved/dir/file.txt") == {:ok, "content"}
      refute Fil.exists?(disk, "dir")
    end

    test "onto the same file find it there", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "a.txt", "a")

      assert {:error, %Fil.AlreadyExistsError{op: :cp, path: "a.txt"}} =
               Fil.cp(disk, "a.txt", "a.txt", if_exists: :error)

      assert {:error, %Fil.AlreadyExistsError{op: :rename, path: "a.txt"}} =
               Fil.rename(disk, "a.txt", "a.txt", if_exists: :error)

      assert Fil.read(disk, "a.txt") == {:ok, "a"}
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
