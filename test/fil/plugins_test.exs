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

      assert disk
             |> Fil.detach(:prefix)
             |> Fil.read("tenant/a.txt") == {:ok, "content"}
    end

    test "takes a {module, function} callback", %{disk: disk} do
      disk = Fil.attach(disk, :upcase, {__MODULE__, :upcase}, [])

      assert {:ok, _} = Fil.write(disk, "a.txt", "content")

      assert disk
             |> Fil.detach(:upcase)
             |> Fil.read("a.txt") == {:ok, "CONTENT"}

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

      assert {:ok, _} =
               disk
               |> Fil.write!("a.txt", "content")
               |> Fil.stat()

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
            %Op{name: :read, result: {:error, %Fil.NotFoundError{}}} = op -> Op.put_result(op, {:ok, ""})
            op -> op
          end
        end)

      assert Fil.read(disk, "missing.txt") == {:ok, ""}

      assert {:error, %Fil.NotFoundError{op: :stat, path: "missing.txt", reason: :enoent}} =
               Fil.stat(disk, "missing.txt")
    end

    test "plugins see errors with their context filled in", %{disk: disk} do
      test_pid = self()

      disk =
        Fil.attach(disk, :spy, fn op, next, _opts ->
          op = next.(op)
          send(test_pid, {:result, op.result})
          op
        end)

      assert {:error, error} = Fil.read(disk, "missing.txt")
      assert_received {:result, {:error, ^error}}
      assert %Fil.NotFoundError{op: :read, path: "missing.txt", disk: ^disk} = error
    end

    test "an error a plugin builds gets the context it left out", %{disk: disk} do
      disk =
        Fil.attach(disk, :read_only, fn
          %Op{name: :write} = op, _next, _opts -> Op.put_result(op, {:error, %Fil.UnsupportedError{reason: :read_only}})
          op, next, _opts -> next.(op)
        end)

      assert {:error, error} = Fil.write(disk, "a.txt", "content")
      assert error == %Fil.UnsupportedError{op: :write, path: "a.txt", disk: disk, reason: :read_only}
    end

    test "a plugin may return its own exception", %{disk: disk} do
      disk =
        Fil.attach(disk, :own, fn op, _next, _opts -> Op.put_result(op, {:error, %RuntimeError{message: "no"}}) end)

      assert Fil.read(disk, "a.txt") == {:error, %RuntimeError{message: "no"}}
    end

    test "an error that isn't an exception raises", %{disk: disk} do
      disk = Fil.attach(disk, :bare, fn op, _next, _opts -> Op.put_result(op, {:error, :enoent}) end)

      assert_raise ArgumentError, ~r/the plugin :bare returned \{:error, :enoent\}/, fn -> Fil.read(disk, "a.txt") end
    end

    test "errors name the caller's path, not a rewritten one", %{disk: disk} do
      tenant = fn op, next, _opts ->
        next.(%{op | path: "tenant/" <> op.path, dest: op.dest && "tenant/" <> op.dest})
      end

      disk = Fil.attach(disk, :tenant, tenant)

      assert {:error, %Fil.NotFoundError{path: "a.txt"} = error} = Fil.read(disk, "a.txt")

      assert {:ok, _} = Fil.write(error.disk, error.path, "content")

      assert error.disk
             |> Fil.ref(error.path)
             |> Fil.read() == {:ok, "content"}

      # Local reports a destination under a file with the destination's path, which is translated back too.
      assert {:error, %Fil.InvalidRequestError{path: "a.txt/copy.txt", reason: :enotdir}} =
               Fil.cp(disk, "a.txt", "a.txt/copy.txt")
    end

    test "a rewritten path can't escape the disk root", %{disk: disk, tmp_dir: tmp_dir} do
      escape = fn op, next, _opts -> next.(%{op | path: "../" <> op.path, dest: op.dest && "../" <> op.dest}) end
      escaping = Fil.attach(disk, :escape, escape)

      assert {:error, %Fil.InvalidRequestError{path: "a.txt", reason: :ebadpath}} =
               Fil.write(escaping, "a.txt", "content")

      refute tmp_dir
             |> Path.join("a.txt")
             |> File.exists?()

      assert {:ok, _} = Fil.write(disk, "a.txt", "content")
      assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.cp(escaping, "a.txt", "b.txt")
    end

    test "a callback that doesn't return an op raises", %{disk: disk} do
      disk = Fil.attach(disk, :broken, fn _op, _next, _opts -> :oops end)

      assert_raise ArgumentError, ~r/the plugin :broken must return a %Fil.Op\{\}, got: :oops/, fn ->
        Fil.read(disk, "a.txt")
      end
    end

    test "a chain that ends without a result raises", %{disk: disk} do
      disk = Fil.attach(disk, :lazy, fn op, _next, _opts -> op end)

      assert_raise ArgumentError, ~r/the plugin :lazy returned an op without a result/, fn ->
        Fil.read(disk, "a.txt")
      end
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

      assert {:ok, _} =
               disk
               |> Fil.ref("a.txt")
               |> Fil.rename(Fil.ref(other, "a.txt"))

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

      assert disk
             |> Fil.detach(:rot)
             |> Fil.read("a.txt") == {:ok, :zlib.gzip("Hello, World")}
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

    test "update_content transforms a stream lazily and drops its size", %{disk: disk} do
      test = self()

      stream =
        Stream.map(["ab", "", "cd"], fn chunk ->
          send(test, {:pulled, chunk})
          chunk
        end)

      op = %Op{disk: disk, name: :write, path: "a.txt", content: stream, options: [size: 4, content_type: "x"]}

      chunked = Op.update_content(op, chunk: &String.upcase/1)
      refute_received {:pulled, _chunk}
      assert chunked.options == [content_type: "x"]
      assert Enum.to_list(chunked.content) == ["AB", "CD"]

      streamed = Op.update_content(op, binary: &String.reverse/1, stream: &Stream.map(&1, fn c -> [c, "."] end))

      assert streamed.content
             |> Enum.to_list()
             |> IO.iodata_to_binary() == "ab.cd."

      collected = Op.update_content(op, binary: &String.reverse/1)
      assert collected.content == "dcba"
      assert collected.options == [content_type: "x"]

      # The content stays the same, and so does its size.
      materialized = Op.materialize(op)
      assert materialized.content == "abcd"
      assert materialized.options == [size: 4, content_type: "x"]
    end

    test "a stream of another size than :size raises, whatever the plugins do with it", %{disk: disk} do
      stream = Stream.map(["he", "llo"], & &1)

      updates = [materialized: &Op.materialize/1, chunked: &Op.update_content(&1, chunk: fn chunk -> chunk end)]

      for {name, update} <- updates do
        plugged =
          Fil.attach(disk, name, fn op, next, _opts ->
            op
            |> update.()
            |> next.()
          end)

        path = "#{name}.txt"

        assert_raise ArgumentError, "the content has 5 bytes, but the :size option is 6", fn ->
          Fil.write(plugged, path, stream, size: 6)
        end

        refute Fil.exists?(plugged, path)
        assert {:ok, _} = Fil.write(plugged, path, stream, size: 5)
      end
    end

    test "a Fil error a read transform raises is the read's error", %{disk: disk, tmp_dir: tmp_dir} do
      tampered = fn _content -> raise %Fil.ChecksumMismatchError{reason: :tampered} end

      checking =
        Fil.attach(disk, :check, fn op, next, _opts ->
          op
          |> next.()
          |> Op.update_result(binary: tampered, stream: &Stream.map(&1, tampered))
        end)

      {:ok, _} = Fil.write(checking, "a.txt", "content")

      # Whole content: returned as an error, with the context filled in.
      assert {:error, %Fil.ChecksumMismatchError{op: :read, path: "a.txt", reason: :tampered} = error} =
               Fil.read(checking, "a.txt")

      assert error.disk == checking

      # A stream: raised when it's read, with the context filled in.
      assert {:ok, stream} = Fil.stream(checking, "a.txt")
      error = assert_raise Fil.ChecksumMismatchError, fn -> Enum.to_list(stream) end
      assert {error.op, error.path, error.disk} == {:read, "a.txt", checking}

      # A copy across disks streams, and returns the source's error.
      other = Fil.disk(adapter: Local, root: Path.join(tmp_dir, "other"))

      assert {:error, %Fil.ChecksumMismatchError{op: :cp, path: "a.txt", reason: :tampered}} =
               Fil.cp(checking, "a.txt", Fil.ref(other, "a.txt"))

      refute Fil.exists?(other, "a.txt")
    end

    test "other exceptions in a read transform propagate", %{disk: disk} do
      failing =
        Fil.attach(disk, :fail, fn op, next, _opts ->
          op
          |> next.()
          |> Op.update_result(binary: fn _content -> raise "a bug" end)
        end)

      {:ok, _} = Fil.write(failing, "a.txt", "content")

      assert_raise RuntimeError, "a bug", fn -> Fil.read(failing, "a.txt") end
    end

    test "update_content passes whole content to a stream transform as one chunk", %{disk: disk} do
      op = %Op{disk: disk, name: :write, path: "a.txt", content: ["ab", "cd"], options: [size: 4]}

      streamed = Op.update_content(op, stream: &Stream.map(&1, fn chunk -> [chunk, "!"] end))
      assert IO.iodata_to_binary(streamed.content) == "abcd!"
      assert streamed.options == []
    end

    test "update_result transforms a streamed read when it's read", %{disk: disk} do
      test = self()

      stream =
        Stream.map(["ab", "cd"], fn chunk ->
          send(test, {:pulled, chunk})
          chunk
        end)

      op = %Op{disk: disk, name: :read, path: "a.txt", streaming: true, result: {:ok, stream}}

      assert {:ok, chunked} = Op.update_result(op, chunk: &String.upcase/1).result
      assert {:ok, collected} = Op.update_result(op, binary: &String.reverse/1).result
      refute_received {:pulled, _chunk}

      assert Enum.to_list(chunked) == ["AB", "CD"]
      assert Enum.to_list(collected) == ["dcba"]
      assert_received {:pulled, "ab"}
    end

    test "chunk: gets no call for empty content, whole or streamed", %{disk: disk} do
      marking = &[&1, "!"]

      for content <- ["", [], Stream.map([""], & &1)] do
        op = %Op{disk: disk, name: :write, path: "a.txt", content: content}
        written = Op.update_content(op, chunk: marking)
        assert Fil.Support.Content.to_binary(written.content) == ""

        read = %Op{disk: disk, name: :read, path: "a.txt", streaming: true, result: {:ok, content}}
        assert {:ok, result} = Op.update_result(read, chunk: marking).result
        assert Fil.Support.Content.to_binary(result) == ""
      end
    end

    test "other operations are left alone, but the transforms are still checked", %{disk: disk} do
      op = %Op{disk: disk, name: :stat, path: "a.txt"}

      assert Op.update_content(op, binary: &String.upcase/1) == op
      assert Op.update_result(op, binary: &String.upcase/1) == op
      assert Op.materialize(op) == op

      assert_raise ArgumentError, ~r/at least one of :binary, :chunk or :stream/, fn -> Op.update_content(op, []) end
      assert_raise ArgumentError, ~r/unknown transforms \[:lines\]/, fn -> Op.update_content(op, lines: & &1) end
      assert_raise ArgumentError, ~r/1-arity function/, fn -> Op.update_result(op, binary: :nope) end
    end

    test "the transforms are checked before the content", %{disk: disk} do
      op = %Op{disk: disk, name: :read, path: "a.txt", result: {:ok, :not_iodata}}

      assert_raise ArgumentError, ~r/at least one of/, fn -> Op.update_result(op, []) end
    end
  end
end
