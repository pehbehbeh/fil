defmodule Fil.Adapter.MemoryTest do
  alias Fil.Adapter.Memory

  use Fil.AdapterCase, async: true

  setup do
    Memory.checkout()
  end

  def fil_disk(_context) do
    [adapter: Memory, root: "primary"]
    |> Fil.disk()
    |> Fil.Plugin.SignedURL.attach(base_url: "http://localhost/storage", secret: "secret")
  end

  describe "init/1" do
    test "normalizes the root" do
      assert {:ok, %Memory{prefix: ""}} = Memory.init([])
      assert {:ok, %Memory{prefix: "a/b/"}} = Memory.init(root: "/a//b/")
    end

    test "rejects a root that climbs out of the store" do
      assert {:error, {:invalid_option, {:root, "../x"}}} = Memory.init(root: "../x")
    end
  end

  describe "roots" do
    test "overlap like directories", %{disk: disk} do
      nested = Fil.disk(adapter: Memory, root: "primary/avatars")

      assert {:ok, _} = Fil.write(nested, "1.png", "png")
      assert Fil.read(disk, "avatars/1.png") == {:ok, "png"}
      assert {:ok, [avatars]} = Fil.ls(disk)
      assert avatars.path == "avatars"
    end

    test "separate disks with different roots", %{disk: disk} do
      other = Fil.disk(adapter: Memory, root: "secondary")

      assert {:ok, _} = Fil.write(other, "a.txt", "a")
      assert Fil.read(disk, "a.txt") == {:error, :enoent}
      assert Fil.ls(disk) == {:ok, []}
    end
  end

  describe "stores" do
    test "belong to the test process", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "a.txt", "a")

      test = self()

      task =
        Task.async(fn ->
          send(test, :written)
          Fil.read(disk, "a.txt")
        end)

      assert_receive :written
      assert Task.await(task) == {:ok, "a"}
    end

    test "every test starts empty", %{disk: disk} do
      assert Fil.ls(disk, ".", recursive: true) == {:ok, []}
    end

    @tag :capture_log
    test "a process without a store raises", %{disk: disk} do
      {pid, ref} = spawn_monitor(fn -> Fil.read(disk, "a.txt") end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {%RuntimeError{message: message}, _stacktrace}}
      assert message =~ "has no Fil.Adapter.Memory store"
    end

    test "allow/2 shares the store with another process", %{disk: disk} do
      test = self()

      pid =
        spawn(fn ->
          receive do
            :go -> send(test, {:result, Fil.write(disk, "from-other.txt", "hi")})
          end
        end)

      :ok = Memory.allow(test, pid)
      send(pid, :go)

      assert_receive {:result, {:ok, _}}
      assert Fil.read(disk, "from-other.txt") == {:ok, "hi"}
    end

    test "allow/2 accepts registered names and needs an owner with a store" do
      {:ok, agent} = Agent.start_link(fn -> nil end, name: :fil_memory_test_agent)

      assert :ok = Memory.allow(self(), :fil_memory_test_agent)
      assert_raise ArgumentError, ~r/has no memory store/, fn -> Memory.allow(spawn(fn -> nil end), agent) end
      assert_raise ArgumentError, ~r/no process is registered/, fn -> Memory.allow(self(), :nobody) end
    end

    test "checkout/0 twice keeps the store", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "a.txt", "a")
      assert :ok = Memory.checkout()
      assert Fil.read(disk, "a.txt") == {:ok, "a"}
    end

    test "the store goes away with its owner" do
      test = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Memory.checkout()
          send(test, {:store, Fil.Support.MemoryStores.lookup(self())})
        end)

      assert_receive {:store, {:ok, store, ^pid}}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert :ets.info(store) == :undefined

      # The lookup row is removed once the registry has seen the owner exit.
      :sys.get_state(Fil.Support.MemoryStores)
      assert Fil.Support.MemoryStores.lookup(pid) == :error
    end
  end

  describe "stat/1" do
    test "stores the content type and an MD5 etag", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "a.txt", "hello", content_type: "text/plain")
      assert {:ok, stat} = Fil.stat(disk, "a.txt")

      assert stat.content_type == "text/plain"
      assert stat.etag == "5d41402abc4b2a76b9719d911017c592"
    end

    test "returns the stored checksum, like S3", %{disk: disk} do
      checksum = Base.encode64(:crypto.hash(:sha256, "hello"))

      assert {:ok, _} = Fil.write(disk, "a.txt", "hello", checksum: :sha256)
      assert {:ok, %Fil.Stat{checksum: {:sha256, ^checksum}}} = Fil.stat(disk, "a.txt", checksum: :sha256)
      assert {:ok, %Fil.Stat{checksum: nil}} = Fil.stat(disk, "a.txt", checksum: :crc32)
      assert Fil.read(disk, "a.txt", verify_checksum: true) == {:ok, "hello"}

      assert {:ok, _} = Fil.cp(disk, "a.txt", "b.txt")
      assert {:ok, %Fil.Stat{checksum: {:sha256, ^checksum}}} = Fil.stat(disk, "b.txt", checksum: :sha256)
    end

    test "a file written without a checksum has none", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "a.txt", "hello")
      assert {:ok, %Fil.Stat{checksum: nil}} = Fil.stat(disk, "a.txt", checksum: :sha256)
    end
  end

  describe "rename/2" do
    test "onto itself keeps the file", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "a.txt", "a")
      assert {:ok, _} = Fil.rename(disk, "a.txt", "a.txt")
      assert Fil.read(disk, "a.txt") == {:ok, "a"}
    end
  end

  describe "signed_url/2" do
    test "needs Fil.Plugin.SignedURL" do
      disk = Fil.disk(adapter: Memory)

      assert Fil.signed_url(disk, "a.txt") == {:error, {:unsupported, :signed_url}}
    end
  end
end
