defmodule Fil.Adapter.LocalTest do
  alias Fil.Adapter.Local

  use Fil.AdapterCase, async: true

  def fil_disk(%{tmp_dir: tmp_dir}) do
    [adapter: Local, root: Path.join(tmp_dir, "primary")]
    |> Fil.disk()
    |> Fil.Plugin.URL.attach(base_url: "http://localhost/storage", secret: "secret")
  end

  describe "same storage" do
    test "compares the expanded root" do
      relative = Fil.disk(adapter: Local, root: "priv/storage")

      assert Fil.Disk.same_storage?(relative, Fil.disk(adapter: Local, root: Path.expand("priv/storage")))
      refute Fil.Disk.same_storage?(relative, Fil.disk(adapter: Local, root: "priv/other"))
    end
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

    test "copies and moves that fail remove the directories they created", %{disk: disk, tmp_dir: tmp_dir} do
      assert {:ok, _} = Fil.write(disk, "kept/x.txt", "x")

      assert {:error, %Fil.NotFoundError{}} = Fil.cp(disk, "nope.txt", "kept/new/a.txt")
      assert {:error, %Fil.NotFoundError{}} = Fil.rename(disk, "nope.txt", "fresh/deeper/a.txt")
      assert {:error, %Fil.NotFoundError{}} = Fil.cp(disk, "nope.txt", "fresh/a.txt", if_exists: :error)
      assert {:error, %Fil.NotFoundError{}} = Fil.rename(disk, "nope.txt", "fresh/a.txt", if_exists: :error)

      root = Path.join(tmp_dir, "primary")

      assert root
             |> File.ls!()
             |> Enum.sort() == ["kept"]

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

    test "are atomic: readers see the old file until the new one is complete", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "atomic.txt", "old")
      test = self()

      stream =
        Stream.map([:first, :second], fn
          :first ->
            "new "

          :second ->
            send(test, {:writing, self()})

            receive do
              :go -> "content"
            end
        end)

      task = Task.async(fn -> Fil.write(disk, "atomic.txt", stream) end)
      assert_receive {:writing, writer}, 1_000

      assert Fil.read(disk, "atomic.txt") == {:ok, "old"}
      assert {:ok, %Fil.Stat{size: 3}} = Fil.stat(disk, "atomic.txt")

      send(writer, :go)
      assert {:ok, _} = Task.await(task)
      assert Fil.read(disk, "atomic.txt") == {:ok, "new content"}
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

    test "move a directory onto neither a file nor a directory with files", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "dir/file.txt", "content")
      assert {:ok, _} = Fil.write(disk, "taken.txt", "taken")
      assert {:ok, _} = Fil.write(disk, "full/other.txt", "other")

      assert {:error, %Fil.AlreadyExistsError{op: :rename, path: "taken.txt"}} =
               Fil.rename(disk, "dir", "taken.txt", if_exists: :error)

      assert {:error, %Fil.AlreadyExistsError{op: :rename, path: "full"}} =
               Fil.rename(disk, "dir", "full", if_exists: :error)

      assert Fil.read(disk, "dir/file.txt") == {:ok, "content"}
      assert Fil.read(disk, "taken.txt") == {:ok, "taken"}
      assert Fil.read(disk, "full/other.txt") == {:ok, "other"}
    end

    test "that can't remove the source remove the destination again", %{disk: disk, tmp_dir: tmp_dir} do
      assert {:ok, _} = Fil.write(disk, "locked/a.txt", "a")

      locked = Path.join(tmp_dir, "primary/locked")
      File.chmod!(locked, 0o555)
      on_exit(fn -> File.chmod(locked, 0o755) end)

      assert {:error, %Fil.AccessDeniedError{op: :rename, path: "locked/a.txt"}} =
               Fil.rename(disk, "locked/a.txt", "b.txt", if_exists: :error)

      assert Fil.read(disk, "locked/a.txt") == {:ok, "a"}
      refute Fil.exists?(disk, "b.txt")
    end

    test "that run at the same time leave no temporary files behind", %{disk: disk, tmp_dir: tmp_dir} do
      for i <- 1..8, do: assert({:ok, _} = Fil.write(disk, "sources/#{i}.txt", "#{i}"))

      1..8
      |> Task.async_stream(fn i -> Fil.cp(disk, "sources/#{i}.txt", "target/a.txt", if_exists: :error) end)
      |> Stream.run()

      assert tmp_dir
             |> Path.join("primary/target")
             |> File.ls!() == ["a.txt"]
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

    test "move a symlink, not its target", %{disk: disk, tmp_dir: tmp_dir} do
      assert {:ok, _} = Fil.write(disk, "target.txt", "target")

      root = Path.join(tmp_dir, "primary")
      link = Path.join(root, "link")
      moved = Path.join(root, "moved")
      File.ln_s!("target.txt", link)

      assert {:ok, _} = Fil.rename(disk, "link", "moved", if_exists: :error)
      assert File.read_link(moved) == {:ok, "target.txt"}
      assert File.lstat(link) == {:error, :enoent}
      assert Fil.read(disk, "moved") == {:ok, "target"}
      assert Fil.read(disk, "target.txt") == {:ok, "target"}
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
    test "stores no content type", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "a.txt", "hello", content_type: "text/plain")
      assert {:ok, %Fil.Stat{content_type: nil}} = Fil.stat(disk, "a.txt")
    end

    test "computes any checksum from the file, not only the one it was written with", %{disk: disk} do
      content = :crypto.strong_rand_bytes(200_000)
      checksum = Base.encode64(<<:erlang.crc32(content)::32>>)

      assert {:ok, _} = Fil.write(disk, "big.bin", content, checksum: :sha256)
      assert {:ok, %Fil.Stat{checksum: {:crc32, ^checksum}}} = Fil.stat(disk, "big.bin", checksum: :crc32)
    end
  end

  describe "errors" do
    test "an existing file is :eexist on an exclusive write", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "once.txt", "original")

      assert {:error, %Fil.AlreadyExistsError{reason: :eexist}} =
               Fil.write(disk, "once.txt", "clobber", if_exists: :error)
    end

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
end
