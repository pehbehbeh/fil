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

    test "content is iodata or an enumerable", %{disk: disk} do
      assert_raise ArgumentError, ~r/expected the content to be iodata or an enumerable of iodata, got: :nope/, fn ->
        Fil.write(disk, "a.txt", :nope)
      end
    end

    test "size: of iodata is checked before anything is written", %{disk: disk} do
      assert_raise ArgumentError, "the content has 5 bytes, but the :size option is 6", fn ->
        Fil.write(disk, "a.txt", ["he", "llo"], size: 6)
      end
    end

    test "size: is only an option of writes", %{disk: disk} do
      assert_raise ArgumentError, ~r/unknown options \[:size\]/, fn -> Fil.cp(disk, "a.txt", "b.txt", size: 1) end
    end
  end

  describe "stream/2" do
    setup do
      Fil.Adapter.Memory.checkout()
      {:ok, disk: Fil.disk(adapter: Fil.Adapter.Memory)}
    end

    test "streams the whole file as one chunk on an adapter without stream/3" do
      disk = Fil.disk(adapter: __MODULE__.WholeAdapter)
      {:ok, _} = Fil.write(disk, "a.txt", "content")

      assert {:ok, stream} = Fil.stream(disk, "a.txt")
      assert Enum.to_list(stream) == ["content"]
      assert {:error, %Fil.NotFoundError{op: :read, path: "nope.txt"}} = Fil.stream(disk, "nope.txt")
    end

    test "a plugin that answers with iodata still gives a stream", %{disk: disk} do
      cached =
        Fil.attach(disk, :cache, fn
          %Fil.Op{name: :read} = op, _next, _opts -> Fil.Op.put_result(op, {:ok, ["cac", "hed"]})
          op, next, _opts -> next.(op)
        end)

      assert Fil.stream(cached, "a.txt") == {:ok, ["cached"]}
      assert Fil.read(cached, "a.txt") == {:ok, ["cac", "hed"]}
    end

    test "an error of the destination isn't reported as one of the source", %{disk: disk} do
      other = Fil.disk(adapter: Fil.Adapter.Memory, root: "other")
      {:ok, _} = Fil.write(disk, "a.txt", "content")

      rejecting =
        Fil.attach(other, :reject, fn op, next, _opts ->
          op
          |> Fil.Op.update_content(chunk: fn _chunk -> raise %Fil.InvalidRequestError{reason: :rejected} end)
          |> next.()
        end)

      source = Fil.stream!(disk, "a.txt")

      assert {:error, %Fil.InvalidRequestError{op: :write, path: "b.txt", reason: :rejected} = error} =
               Fil.write(rejecting, "b.txt", source)

      assert error.disk == rejecting

      # The same as any other error of the destination of a copy: the operation is the copy, the path the destination.
      assert {:error, %Fil.InvalidRequestError{op: :cp, path: "b.txt", reason: :rejected} = error} =
               Fil.cp(disk, "a.txt", Fil.ref(rejecting, "b.txt"))

      assert error.disk == rejecting
      refute Fil.exists?(other, "b.txt")
    end

    test "a write returns an error its source stream raises", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "content")
      source = Fil.stream!(disk, "a.txt")
      {:ok, _} = Fil.rm(disk, "a.txt")

      assert {:error, %Fil.NotFoundError{op: :read, path: "a.txt"} = error} = Fil.write(disk, "b.txt", source)
      assert error.disk == disk
      refute Fil.exists?(disk, "b.txt")
    end

    test "a source that changes size while it's copied fails the copy with a conflict", %{disk: disk} do
      other = Fil.disk(adapter: Fil.Adapter.Memory, root: "other")
      {:ok, _} = Fil.write(disk, "a.txt", "content")

      # The file grows after the check, before the copy reads it.
      growing =
        Fil.attach(disk, :grow, fn op, next, _opts ->
          op = next.(op)
          if op.streaming, do: Fil.write!(op.disk, op.path, "more content")
          op
        end)

      assert {:error, %Fil.ConflictError{op: :cp, path: "a.txt", reason: :size_changed} = error} =
               Fil.cp(growing, "a.txt", Fil.ref(other, "a.txt"))

      assert error.disk == growing
      refute Fil.exists?(other, "a.txt")
    end

    test "a copy across disks returns an error the source raises while it's streamed", %{disk: disk} do
      other = Fil.disk(adapter: Fil.Adapter.Memory, root: "other")
      {:ok, _} = Fil.write(disk, "a.txt", "content")

      # The file goes away after the check, before the copy reads it.
      vanishing =
        Fil.attach(disk, :vanish, fn op, next, _opts ->
          op = next.(op)
          if op.streaming, do: Fil.rm!(op.disk, op.path)
          op
        end)

      assert {:error, %Fil.NotFoundError{op: :cp, path: "a.txt"} = error} =
               Fil.cp(vanishing, "a.txt", Fil.ref(other, "a.txt"))

      assert error.disk == vanishing
      refute Fil.exists?(other, "a.txt")
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

  # The Memory adapter without `stream/3`.
  defmodule WholeAdapter do
    @moduledoc false
    @behaviour Fil.Adapter

    alias Fil.Adapter.Memory

    @impl Fil.Adapter
    defdelegate init(opts), to: Memory
    @impl Fil.Adapter
    defdelegate read(state, path, opts), to: Memory
    @impl Fil.Adapter
    defdelegate write(state, path, content, opts), to: Memory
    @impl Fil.Adapter
    defdelegate rm(state, path, opts), to: Memory
    @impl Fil.Adapter
    defdelegate stat(state, path, opts), to: Memory
    @impl Fil.Adapter
    defdelegate ls(state, path, opts), to: Memory
    @impl Fil.Adapter
    defdelegate cp(state, src, dest, opts), to: Memory
    @impl Fil.Adapter
    defdelegate rename(state, src, dest, opts), to: Memory
    @impl Fil.Adapter
    defdelegate rm_rf(state, prefix, opts), to: Memory
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
