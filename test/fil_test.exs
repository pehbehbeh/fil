defmodule FilTest do
  alias Fil.Adapter.Local

  use ExUnit.Case, async: true

  describe "disk/1" do
    test "passes every other option to the adapter" do
      disk = Fil.disk(adapter: Local, root: "/tmp/fil")

      assert Fil.Disk.adapter(disk) == Local
      assert {Local, %Local{root: "/tmp/fil"}} = disk.adapter
    end

    test "requires an adapter" do
      assert_raise ArgumentError, ~r/required :adapter option not found/, fn ->
        Fil.disk(root: "/tmp")
      end

      assert_raise ArgumentError, ~r/is not a Fil adapter/, fn ->
        Fil.disk(adapter: String)
      end

      assert_raise ArgumentError, ~r/invalid value for :adapter option/, fn ->
        Fil.disk(adapter: "Fil.Adapter.Local")
      end
    end

    test "attaches plugins in order, under the name of their module" do
      disk =
        Fil.disk(
          adapter: Local,
          root: "/tmp/fil",
          plugins: [
            {Fil.Plugin.ContentType, :call, []},
            {Fil.Plugin.URL, :call, base_url: "http://localhost/files"}
          ]
        )

      assert [
               {Fil.Plugin.ContentType, {Fil.Plugin.ContentType, :call}, []},
               {Fil.Plugin.URL, {Fil.Plugin.URL, :call}, [base_url: "http://localhost/files"]}
             ] = disk.plugins

      assert Fil.url(disk, "a.txt") == {:ok, "http://localhost/files/a.txt"}
    end

    test "rejects plugins that aren't a public function of arity 3" do
      assert_raise ArgumentError, ~r/String.call\/3 is not a function/, fn ->
        Fil.disk(adapter: Local, root: "/tmp/fil", plugins: [{String, :call, []}])
      end

      assert_raise ArgumentError, ~r/invalid list in :plugins option/, fn ->
        Fil.disk(adapter: Local, root: "/tmp/fil", plugins: [Fil.Plugin.ContentType])
      end
    end

    test "plugins from config validate their options when they run" do
      disk = Fil.disk(adapter: Local, root: "/tmp/fil", plugins: [{Fil.Plugin.URL, :call, base: "http://localhost"}])

      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:base\]/, fn -> Fil.url(disk, "a.txt") end
    end
  end

  describe "argument handling" do
    setup do
      {:ok, disk: Fil.disk(adapter: Local, root: "/tmp/fil")}
    end

    test "rejects something that is not a ref", %{disk: disk} do
      assert_raise ArgumentError, ~r/expected a %Fil.Ref{}/, fn ->
        Fil.read(:uploads)
      end

      assert_raise ArgumentError, ~r/expected a %Fil.Ref{}/, fn ->
        Fil.read({disk, :not_a_path})
      end
    end

    test "a bare disk lists its root", %{disk: disk} do
      assert Fil.ls(disk) == Fil.ls(disk, ".")
    end

    test "if_exists: takes :overwrite or :error", %{disk: disk} do
      assert_raise ArgumentError, ~r/invalid value for :if_exists option/, fn ->
        Fil.write(disk, "a.txt", "content", if_exists: :skip)
      end
    end
  end

  describe "dispatch" do
    test "raises on an unexpected adapter return value" do
      disk = Fil.disk(adapter: __MODULE__.BrokenAdapter)

      assert_raise ArgumentError, ~r/BrokenAdapter.read must return .* got: :surprise/, fn ->
        Fil.read(disk, "a.txt")
      end
    end
  end

  defmodule BrokenAdapter do
    @moduledoc false
    @behaviour Fil.Adapter

    @impl Fil.Adapter
    def init(_opts), do: {:ok, %{}}

    @impl Fil.Adapter
    def read(_state, _path, _opts), do: :surprise

    @impl Fil.Adapter
    def write(_state, _path, _content, _opts), do: :ok

    @impl Fil.Adapter
    def rm(_state, _path, _opts), do: :ok

    @impl Fil.Adapter
    def stat(_state, _path, _opts), do: {:ok, %Fil.Stat{}}

    @impl Fil.Adapter
    def ls(_state, _path, _opts), do: {:ok, []}

    @impl Fil.Adapter
    def cp(_state, _src, _dest, _opts), do: :ok

    @impl Fil.Adapter
    def rename(_state, _src, _dest, _opts), do: :ok

    @impl Fil.Adapter
    def rm_rf(_state, _prefix, _opts), do: {:ok, 0}
  end
end
