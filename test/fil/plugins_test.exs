defmodule Fil.PluginsTest do
  alias Fil.Adapter.Local
  alias Fil.Op

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {:ok, disk: Fil.disk(adapter: Local, root: Path.join(tmp_dir, "disk"))}
  end

  # Records what a plugin saw on the way in and on the way back.
  defp tracer(test_pid, label) do
    fn op, next, _opts ->
      send(test_pid, {:in, label, op.name})
      op = next.(op)
      send(test_pid, {:out, label, op.name})
      op
    end
  end

  def upcase(op, next, _opts) do
    op
    |> Op.update_content(binary: &String.upcase/1)
    |> next.()
  end

  describe "Fil.attach/4" do
    test "runs every operation through the plugins, first attached outermost", %{disk: disk} do
      disk =
        disk
        |> Fil.attach(:outer, tracer(self(), :outer))
        |> Fil.attach(:inner, tracer(self(), :inner))

      assert {:ok, _} = Fil.write(disk, "a.txt", "content")

      assert_received {:in, :outer, :write}
      assert_received {:in, :inner, :write}
      assert_received {:out, :inner, :write}
      assert_received {:out, :outer, :write}

      {:messages, messages} = Process.info(self(), :messages)
      assert messages == []
    end

    test "passes the attach options to the callback", %{disk: disk} do
      disk =
        Fil.attach(
          disk,
          :prefix,
          fn op, next, opts -> next.(%{op | path: opts[:prefix] <> "/" <> op.path}) end,
          prefix: "tenant"
        )

      assert {:ok, ref} = Fil.write(disk, "a.txt", "content")
      assert ref.path == "tenant/a.txt"
      assert Fil.read(Fil.detach(disk, :prefix), "tenant/a.txt") == {:ok, "content"}
    end

    test "takes a {module, function} callback", %{disk: disk} do
      disk = Fil.attach(disk, :upcase, {__MODULE__, :upcase}, [])

      assert {:ok, _} = Fil.write(disk, "a.txt", "content")
      assert Fil.read(Fil.detach(disk, :upcase), "a.txt") == {:ok, "CONTENT"}

      assert_raise ArgumentError, ~r/FilTest.nope\/3 is not a function/, fn ->
        Fil.attach(disk, :nope, {FilTest, :nope})
      end

      assert_raise ArgumentError, ~r/expected a function of arity 3/, fn ->
        Fil.attach(disk, :nope, fn op -> op end)
      end
    end

    test "replaces a plugin with the same name in place", %{disk: disk} do
      disk =
        disk
        |> Fil.attach(:first, tracer(self(), :first))
        |> Fil.attach(:second, tracer(self(), :second))
        |> Fil.attach(:first, tracer(self(), :replaced))

      assert [:first, :second] = Enum.map(disk.plugins, &elem(&1, 0))

      assert {:ok, _} = Fil.stat(Fil.write!(disk, "a.txt", "content"))
      assert_received {:in, :replaced, :write}
      refute_received {:in, :first, _name}
    end

    test "detach/2 removes a plugin", %{disk: disk} do
      disk =
        disk
        |> Fil.attach(:trace, tracer(self(), :trace))
        |> Fil.detach(:trace)

      assert {:ok, _} = Fil.write(disk, "a.txt", "content")
      refute_received {:in, :trace, _name}
      assert Fil.detach(disk, :nope) == disk
    end

    test "per-call options are validated as before", %{disk: disk} do
      disk = Fil.attach(disk, :noop, fn op, next, _opts -> next.(op) end)

      assert_raise ArgumentError, ~r/unknown options \[:tenant\]/, fn ->
        Fil.read(disk, "a.txt", tenant: "acme")
      end
    end
  end

  describe "the chain" do
    test "a plugin can answer without the adapter", %{disk: disk} do
      disk =
        Fil.attach(disk, :cache, fn
          %Op{name: :read} = op, _next, _opts -> Op.put_result(op, {:ok, "cached"})
          op, next, _opts -> next.(op)
        end)

      assert Fil.read(disk, "never-written.txt") == {:ok, "cached"}
      refute Fil.exists?(disk, "never-written.txt")
    end

    test "errors come back through the chain and can be recovered", %{disk: disk} do
      disk =
        Fil.attach(disk, :default, fn op, next, _opts ->
          case next.(op) do
            %Op{name: :read, result: {:error, :enoent}} = op -> Op.put_result(op, {:ok, ""})
            op -> op
          end
        end)

      assert Fil.read(disk, "missing.txt") == {:ok, ""}
      assert Fil.stat(disk, "missing.txt") == {:error, :enoent}
    end

    test "a rewritten path can't escape the disk root", %{disk: disk, tmp_dir: tmp_dir} do
      escape = fn op, next, _opts -> next.(%{op | path: "../" <> op.path, dest: op.dest && "../" <> op.dest}) end
      escaping = Fil.attach(disk, :escape, escape)

      assert Fil.write(escaping, "a.txt", "content") == {:error, :ebadpath}
      refute File.exists?(Path.join(tmp_dir, "a.txt"))

      assert {:ok, _} = Fil.write(disk, "a.txt", "content")
      assert Fil.cp(escaping, "a.txt", "b.txt") == {:error, :ebadpath}
    end

    test "a callback that doesn't return an op raises", %{disk: disk} do
      disk = Fil.attach(disk, :broken, fn _op, _next, _opts -> :oops end)

      assert_raise Fil.Error, ~r/bad_plugin_return/, fn -> Fil.read(disk, "a.txt") end
    end

    test "a chain that ends without a result raises", %{disk: disk} do
      disk = Fil.attach(disk, :lazy, fn op, _next, _opts -> op end)

      assert_raise Fil.Error, ~r/bad_plugin_result/, fn -> Fil.read(disk, "a.txt") end
    end

    test "copies within a disk are one operation with a destination", %{disk: disk} do
      test_pid = self()

      disk =
        Fil.attach(disk, :spy, fn op, next, _opts ->
          send(test_pid, {op.name, op.path, op.dest})
          next.(op)
        end)

      assert {:ok, _} = Fil.write(disk, "a.txt", "content")
      assert {:ok, ref} = Fil.cp(disk, "a.txt", "b.txt")

      assert ref.path == "b.txt"
      assert_received {:cp, "a.txt", "b.txt"}
    end

    test "a copy across disks runs each disk's plugins", %{disk: disk, tmp_dir: tmp_dir} do
      disk = Fil.attach(disk, :source, tracer(self(), :source))

      other =
        [adapter: Local, root: Path.join(tmp_dir, "other")]
        |> Fil.disk()
        |> Fil.attach(:dest, tracer(self(), :dest))

      assert {:ok, _} = Fil.write(disk, "a.txt", "content")
      assert {:ok, _} = Fil.rename(Fil.ref(disk, "a.txt"), Fil.ref(other, "a.txt"))

      assert_received {:in, :source, :read}
      assert_received {:in, :dest, :write}
      assert_received {:in, :source, :rm}
    end
  end

  describe "Fil.Op content" do
    test "update_content and update_result transform whole content", %{disk: disk} do
      disk =
        Fil.attach(disk, :rot, fn op, next, _opts ->
          op
          |> Op.update_content(binary: &:zlib.gzip/1)
          |> next.()
          |> Op.update_result(binary: &:zlib.gunzip/1)
        end)

      assert {:ok, _} = Fil.write(disk, "a.txt", ["Hello", [", ", "World"]])
      assert Fil.read(disk, "a.txt") == {:ok, "Hello, World"}
      assert Fil.read(Fil.detach(disk, :rot), "a.txt") == {:ok, :zlib.gzip("Hello, World")}
    end

    test "chunk: alone gets the content as a single chunk", %{disk: disk} do
      disk =
        Fil.attach(disk, :upcase, fn op, next, _opts ->
          op
          |> Op.update_content(chunk: &String.upcase/1)
          |> next.()
        end)

      assert {:ok, _} = Fil.write(disk, "a.txt", ["ab", "c"])
      assert Fil.read(disk, "a.txt") == {:ok, "ABC"}
    end

    test "other operations are left alone, but the transforms are still checked", %{disk: disk} do
      op = %Op{disk: disk, name: :stat, path: "a.txt"}

      assert Op.update_content(op, binary: &String.upcase/1) == op
      assert Op.update_result(op, binary: &String.upcase/1) == op
      assert Op.materialize(op) == op

      assert_raise ArgumentError, ~r/at least one of/, fn -> Op.update_content(op, []) end
      assert_raise ArgumentError, ~r/unknown transforms \[:stream\]/, fn -> Op.update_content(op, stream: & &1) end
      assert_raise ArgumentError, ~r/1-arity function/, fn -> Op.update_result(op, binary: :nope) end
    end
  end
end
