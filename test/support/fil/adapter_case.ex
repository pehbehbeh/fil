defmodule Fil.AdapterCase do
  @schema NimbleOptions.new!(
            async: [
              type: :boolean,
              default: false,
              doc: "Passed straight to `ExUnit.Case`."
            ],
            tags: [
              type: {:list, :atom},
              default: [],
              doc: """
              Extra module tags. They're passed as an option because ExUnit needs module tags before the tests are
              registered, and this macro registers the suite.
              """
            ]
          )

  @moduledoc """
  The adapter conformance suite: an ExUnit case template that tests the whole `Fil.Adapter` contract against a live
  disk.

  A case using it provides the disks:

      defmodule Fil.Adapter.LocalTest do
        use Fil.AdapterCase, async: true

        def fil_disk(%{tmp_dir: tmp_dir}) do
          Fil.disk(adapter: Fil.Adapter.Local, root: Path.join(tmp_dir, "primary"))
        end
      end

  `fil_other_disk/1` builds the second disk for the cross-disk tests. It defaults to a local disk in the test's
  temporary directory and can be overridden. Every case gets `@moduletag :tmp_dir`, so ExUnit gives each test its own
  directory.

  The suite is internal to `Fil` for now. Once it's public, third-party adapters can run it to show that they follow the
  contract.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @doc "Splits `content` into a stream of `size`-byte chunks, the way a file or an upload arrives."
  @spec chunked(binary(), pos_integer()) :: Enumerable.t()
  def chunked(content, size) do
    Stream.unfold(content, fn
      "" -> nil
      rest when byte_size(rest) <= size -> {rest, ""}
      rest -> {binary_part(rest, 0, size), binary_part(rest, size, byte_size(rest) - size)}
    end)
  end

  @doc "Compresses a stream with gzip, a transform that keeps state from one chunk to the next and adds a trailer."
  @spec gzip(Enumerable.t()) :: Enumerable.t()
  def gzip(chunks) do
    Stream.transform(
      chunks,
      fn ->
        z = :zlib.open()
        :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
        z
      end,
      fn chunk, z -> {[:zlib.deflate(z, chunk)], z} end,
      fn z -> {[:zlib.deflate(z, [], :finish)], z} end,
      &:zlib.close/1
    )
  end

  @doc "Decompresses what `gzip/1` compressed."
  @spec gunzip(Enumerable.t()) :: Enumerable.t()
  def gunzip(chunks) do
    Stream.transform(
      chunks,
      fn ->
        z = :zlib.open()
        :ok = :zlib.inflateInit(z, 31)
        z
      end,
      fn chunk, z -> {[:zlib.inflate(z, chunk)], z} end,
      fn z -> {[], z} end,
      &:zlib.close/1
    )
  end

  @doc "Builds the disk under test."
  @callback fil_disk(map()) :: Fil.Disk.t()

  @doc "Builds the second disk, used by the cross-disk tests."
  @callback fil_other_disk(map()) :: Fil.Disk.t()

  defmacro __using__(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    # Module tags have to be set before the tests below are registered, so extra ones are passed as an option:
    # `use Fil.AdapterCase, tags: [:integration]`.
    moduletags = for tag <- [:tmp_dir | opts[:tags]], do: quote(do: @moduletag(unquote(tag)))
    case_opts = [async: opts[:async]]

    # This quote block contains every test of the suite, which is why it's long.
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      @behaviour Fil.AdapterCase

      use ExUnit.Case, unquote(case_opts)

      alias Fil.Adapter.Local

      import Fil.AdapterCase, only: [chunked: 2, gzip: 1, gunzip: 1]

      unquote_splicing(moduletags)

      def fil_other_disk(%{tmp_dir: tmp_dir}) do
        Fil.disk(adapter: Local, root: Path.join(tmp_dir, "other"))
      end

      defoverridable fil_other_disk: 1

      setup context do
        {:ok, disk: fil_disk(context), other_disk: fil_other_disk(context)}
      end

      ## ----------------------------------------------------------------
      ## Reading and writing
      ## ----------------------------------------------------------------

      test "writes and reads a file", %{disk: disk} do
        assert {:ok, ref} = Fil.write(disk, "hello.txt", "World")
        assert ref.path == "hello.txt"
        assert ref.disk == disk
        assert Fil.read(disk, "hello.txt") == {:ok, "World"}
      end

      test "writes iodata", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "iodata.txt", ["Hello", [", ", ?W], "orld"])
        assert Fil.read(disk, "iodata.txt") == {:ok, "Hello, World"}
      end

      test "writes arbitrary binary content", %{disk: disk} do
        content = :crypto.strong_rand_bytes(1024)
        assert {:ok, _} = Fil.write(disk, "random.bin", content)
        assert Fil.read(disk, "random.bin") == {:ok, content}
      end

      test "overwrites an existing file", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "hello.txt", "first")
        assert {:ok, _} = Fil.write(disk, "hello.txt", "second")
        assert Fil.read(disk, "hello.txt") == {:ok, "second"}
      end

      test "creates parent directories", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "deeply/nested/tree/file.txt", "here")
        assert Fil.read(disk, "deeply/nested/tree/file.txt") == {:ok, "here"}
      end

      test "handles unicode, spaces and dots in paths", %{disk: disk} do
        paths = ["ünïcödé/ümlaut.txt", "with spaces/a file.txt", "dotted/v1.2.3/notes.txt"]

        for path <- paths do
          assert {:ok, ref} = Fil.write(disk, path, path)
          assert ref.path == path
          assert Fil.read(disk, path) == {:ok, path}
        end
      end

      test "writes a file whose name is near the filesystem's limit", %{disk: disk} do
        # 244 bytes: a local temporary file named after it would be too long for most filesystems (255 bytes).
        overwritten = String.duplicate("o", 240) <> ".txt"
        exclusive = String.duplicate("e", 240) <> ".txt"
        streamed = Stream.map(["long", " name"], & &1)

        assert {:ok, _} = Fil.write(disk, overwritten, "long name")
        assert {:ok, _} = Fil.write(disk, overwritten, streamed)
        assert {:ok, _} = Fil.write(disk, exclusive, streamed, if_exists: :error)

        assert Fil.read(disk, overwritten) == {:ok, "long name"}
        assert Fil.read(disk, exclusive) == {:ok, "long name"}
      end

      test "reading a missing file is not found", %{disk: disk} do
        assert {:error, %Fil.NotFoundError{}} = Fil.read(disk, "nope.txt")
        assert {:error, %Fil.NotFoundError{}} = Fil.read(disk, "missing/nope.txt")
      end

      test "errors carry the operation, the path, the disk and a reason", %{disk: disk} do
        assert {:error, %Fil.NotFoundError{} = error} = Fil.read(disk, "missing/nope.txt")

        assert error.op == :read
        assert error.path == "missing/nope.txt"
        assert error.disk == disk
        refute error.reason == nil, "adapters must set :reason"

        assert {:error, %Fil.NotFoundError{op: :cp, path: "nope.txt"} = error} = Fil.cp(disk, "nope.txt", "target.txt")
        refute error.reason == nil, "adapters must set :reason"
      end

      test "stat of a missing file is not found", %{disk: disk} do
        assert {:error, %Fil.NotFoundError{}} = Fil.stat(disk, "nope.txt")
      end

      test "a path through a file is a missing file", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "report.txt", "report")

        assert {:error, %Fil.NotFoundError{}} = Fil.read(disk, "report.txt/nope.txt")
        assert {:error, %Fil.NotFoundError{}} = Fil.stat(disk, "report.txt/nope.txt")
        assert {:error, %Fil.NotFoundError{}} = Fil.cp(disk, "report.txt/nope.txt", "target.txt")
        assert {:ok, _} = Fil.rm(disk, "report.txt/nope.txt")
        refute Fil.exists?(disk, "report.txt/nope.txt")
      end

      test "reading a directory fails", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "tree/leaf.txt", "leaf")

        # A real directory (Local) or a prefix with no object of its own (S3, Memory).
        assert {:error, error} = Fil.read(disk, "tree")
        assert match?(%Fil.InvalidRequestError{}, error) or match?(%Fil.NotFoundError{}, error)
      end

      ## ----------------------------------------------------------------
      ## Streaming
      ## ----------------------------------------------------------------

      test "writes a stream, with or without its size", %{disk: disk} do
        content = :crypto.strong_rand_bytes(300_000)
        stream = chunked(content, 10_000)

        assert {:ok, ref} = Fil.write(disk, "streamed.bin", stream)
        assert ref.path == "streamed.bin"
        assert Fil.read(disk, "streamed.bin") == {:ok, content}

        assert {:ok, _} = Fil.write(disk, "sized.bin", stream, size: byte_size(content))
        assert Fil.read(disk, "sized.bin") == {:ok, content}
        assert {:ok, %Fil.Stat{size: 300_000}} = Fil.stat(disk, "sized.bin")
      end

      test "streams a file in chunks, as often as it's read", %{disk: disk} do
        content = :crypto.strong_rand_bytes(1_000_000)
        assert {:ok, _} = Fil.write(disk, "big.bin", content)

        assert {:ok, stream} = Fil.stream(disk, "big.bin")
        chunks = Enum.to_list(stream)

        assert length(chunks) > 1
        assert Enum.all?(chunks, &(is_binary(&1) and &1 != ""))
        assert IO.iodata_to_binary(chunks) == content

        assert [first] = Enum.take(stream, 1)
        assert String.starts_with?(content, first)
        assert Enum.join(stream) == content

        assert disk
               |> Fil.stream!("big.bin")
               |> Enum.join() == content
      end

      test "a stream goes straight into a write", %{disk: disk, other_disk: other_disk} do
        content = :crypto.strong_rand_bytes(200_000)
        assert {:ok, _} = Fil.write(disk, "source.bin", content)

        assert {:ok, stream} = Fil.stream(disk, "source.bin")
        assert {:ok, _} = Fil.write(disk, "copy.bin", stream)
        assert {:ok, _} = Fil.write(other_disk, "copy.bin", stream)

        assert Fil.read(disk, "copy.bin") == {:ok, content}
        assert Fil.read(other_disk, "copy.bin") == {:ok, content}
      end

      test "writes and streams empty content", %{disk: disk} do
        empty = Stream.map([], & &1)

        assert {:ok, _} = Fil.write(disk, "empty.txt", empty)
        assert {:ok, _} = Fil.write(disk, "empty-sized.txt", empty, size: 0)
        assert {:ok, _} = Fil.write(disk, "empty-chunks.txt", Stream.map(["", [], ""], & &1))

        for path <- ["empty.txt", "empty-sized.txt", "empty-chunks.txt"] do
          assert Fil.read(disk, path) == {:ok, ""}
          assert {:ok, stream} = Fil.stream(disk, path)
          assert Enum.to_list(stream) == []
        end
      end

      test "streaming a missing file or a directory fails right away", %{disk: disk} do
        assert {:error, %Fil.NotFoundError{op: :read, path: "nope.txt"} = error} = Fil.stream(disk, "nope.txt")
        assert error.disk == disk
        assert_raise Fil.NotFoundError, fn -> Fil.stream!(disk, "nope.txt") end

        assert {:ok, _} = Fil.write(disk, "tree/leaf.txt", "leaf")
        assert {:error, error} = Fil.stream(disk, "tree")
        assert match?(%Fil.InvalidRequestError{}, error) or match?(%Fil.NotFoundError{}, error)
      end

      test "a file removed before its stream is read raises with the context", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "gone.txt", "soon")
        assert {:ok, stream} = Fil.stream(disk, "gone.txt")
        assert {:ok, _} = Fil.rm(disk, "gone.txt")

        error = assert_raise Fil.NotFoundError, fn -> Enum.to_list(stream) end
        assert {error.op, error.path, error.disk} == {:read, "gone.txt", disk}
      end

      test "a stream that raises writes nothing", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "kept.txt", "original")

        failing =
          Stream.map(1..5, fn
            4 -> raise "the upload broke off"
            _other -> String.duplicate("x", 10_000)
          end)

        for opts <- [[], [size: 50_000], [if_exists: :error], [if_exists: :error, size: 50_000]] do
          assert_raise RuntimeError, "the upload broke off", fn -> Fil.write(disk, "kept.txt", failing, opts) end
          assert_raise RuntimeError, "the upload broke off", fn -> Fil.write(disk, "new.txt", failing, opts) end
        end

        assert Fil.read(disk, "kept.txt") == {:ok, "original"}
        refute Fil.exists?(disk, "new.txt")
        assert {:ok, [kept]} = Fil.ls(disk)
        assert kept.path == "kept.txt"
      end

      test "a stream of another size than :size raises and writes nothing", %{disk: disk} do
        stream = chunked("hello", 2)

        assert_raise ArgumentError, "the content has 5 bytes, but the :size option is 6", fn ->
          Fil.write(disk, "sized.txt", stream, size: 6)
        end

        assert_raise ArgumentError, "the content has more than 4 bytes, but the :size option is 4", fn ->
          Fil.write(disk, "sized.txt", stream, size: 4)
        end

        refute Fil.exists?(disk, "sized.txt")
      end

      test "if_exists: :error applies to streams", %{disk: disk} do
        first = chunked("first", 2)
        second = chunked("second", 2)

        assert {:ok, _} = Fil.write(disk, "once.txt", first, if_exists: :error)
        assert {:error, %Fil.AlreadyExistsError{}} = Fil.write(disk, "once.txt", second, if_exists: :error)
        assert {:error, %Fil.AlreadyExistsError{}} = Fil.write(disk, "once.txt", second, if_exists: :error, size: 6)
        assert Fil.read(disk, "once.txt") == {:ok, "first"}
      end

      test "plugins transform a stream chunk by chunk", %{disk: disk} do
        test = self()

        shouting =
          Fil.attach(disk, :shout, fn op, next, _opts ->
            op
            |> Fil.Op.update_content(
              chunk: fn chunk ->
                send(test, {:chunk, chunk})
                String.upcase(chunk)
              end
            )
            |> next.()
            |> Fil.Op.update_result(chunk: &String.downcase/1)
          end)

        # The transform drops `:size`, and a size that no longer holds wouldn't matter.
        assert {:ok, _} = Fil.write(shouting, "shout.txt", chunked("hello world", 4), size: 11)
        assert_received {:chunk, "hell"}
        assert_received {:chunk, "o wo"}
        assert_received {:chunk, "rld"}

        assert Fil.read(disk, "shout.txt") == {:ok, "HELLO WORLD"}
        assert Fil.read(shouting, "shout.txt") == {:ok, "hello world"}

        assert shouting
               |> Fil.stream!("shout.txt")
               |> Enum.join() == "hello world"
      end

      test "plugins keep state across the chunks of a stream", %{disk: disk} do
        compressing =
          Fil.attach(disk, :gzip, fn op, next, _opts ->
            op
            |> Fil.Op.update_content(iodata: &:zlib.gzip/1, stream: &gzip/1)
            |> next.()
            |> Fil.Op.update_result(iodata: &:zlib.gunzip/1, stream: &gunzip/1)
          end)

        content = String.duplicate("all work and no play makes Jack a dull boy\n", 5_000)
        stream = chunked(content, 1_000)

        assert {:ok, _} = Fil.write(compressing, "jack.txt.gz", stream)
        assert {:ok, compressed} = Fil.read(disk, "jack.txt.gz")
        assert byte_size(compressed) < byte_size(content)
        assert :zlib.gunzip(compressed) == content

        assert Fil.read(compressing, "jack.txt.gz") == {:ok, content}

        assert compressing
               |> Fil.stream!("jack.txt.gz")
               |> Enum.join() == content

        assert {:ok, _} = Fil.write(compressing, "iodata.txt.gz", content)

        assert compressing
               |> Fil.stream!("iodata.txt.gz")
               |> Enum.join() == content
      end

      test "stores and verifies checksums of streams", %{disk: disk} do
        content = :crypto.strong_rand_bytes(100_000)
        stream = chunked(content, 10_000)

        checksum =
          :sha256
          |> :crypto.hash(content)
          |> Base.encode64()

        assert {:ok, _} = Fil.write(disk, "checked.bin", stream, checksum: :sha256)
        assert {:ok, %Fil.Stat{checksum: {:sha256, ^checksum}}} = Fil.stat(disk, "checked.bin", checksum: :sha256)
        assert Fil.read(disk, "checked.bin", verify_checksum: true) == {:ok, content}

        assert disk
               |> Fil.stream!("checked.bin", verify_checksum: true)
               |> Enum.join() == content
      end

      ## ----------------------------------------------------------------
      ## Deleting
      ## ----------------------------------------------------------------

      test "deletes a file and is idempotent", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "bye.txt", "later")
        assert {:ok, ref} = Fil.rm(disk, "bye.txt")
        assert ref.path == "bye.txt"
        assert {:error, %Fil.NotFoundError{}} = Fil.read(disk, "bye.txt")
        assert {:ok, ^ref} = Fil.rm(disk, "bye.txt")
        assert {:ok, _} = Fil.rm(disk, "never/existed.txt")
      end

      test "deletes everything under a prefix", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "keep.txt", "keep")
        assert {:ok, _} = Fil.write(disk, "trash/a.txt", "a")
        assert {:ok, _} = Fil.write(disk, "trash/nested/b.txt", "b")

        assert {:ok, 2} = Fil.rm_rf(disk, "trash")
        assert {:error, %Fil.NotFoundError{}} = Fil.read(disk, "trash/a.txt")
        assert {:error, %Fil.NotFoundError{}} = Fil.read(disk, "trash/nested/b.txt")
        assert Fil.read(disk, "keep.txt") == {:ok, "keep"}
      end

      test "deleting a missing prefix removes nothing", %{disk: disk} do
        assert {:ok, 0} = Fil.rm_rf(disk, "never/existed")
      end

      test "deleting a directory removes nothing", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "tree/leaf.txt", "leaf")

        # Local refuses, object stores have nothing to delete under that exact key.
        result = Fil.rm(disk, "tree")
        assert match?({:ok, _}, result) or match?({:error, %Fil.InvalidRequestError{reason: :eisdir}}, result)
        assert Fil.read(disk, "tree/leaf.txt") == {:ok, "leaf"}
      end

      ## ----------------------------------------------------------------
      ## Predicates and metadata
      ## ----------------------------------------------------------------

      test "exists? and dir?", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "tree/leaf.txt", "leaf")

        assert Fil.exists?(disk, "tree/leaf.txt")
        assert Fil.exists?(disk, "tree")
        refute Fil.exists?(disk, "tree/other.txt")
        refute Fil.exists?(disk, "nope")

        refute Fil.dir?(disk, "tree/leaf.txt")
        assert Fil.dir?(disk, "tree")
        refute Fil.dir?(disk, "nope")
      end

      test "stat describes a file", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "stat.txt", "0123456789")
        assert {:ok, stat} = Fil.stat(disk, "stat.txt")

        assert stat.size == 10
        assert stat.type == :regular
        assert %DateTime{} = stat.mtime
        assert is_binary(stat.etag)
      end

      test "stat describes a directory", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "statdir/file.txt", "x")
        assert {:ok, stat} = Fil.stat(disk, "statdir")
        assert stat.type == :directory
      end

      ## ----------------------------------------------------------------
      ## Listing
      ## ----------------------------------------------------------------

      test "lists one level by default", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "root.txt", "root")
        assert {:ok, _} = Fil.write(disk, "sub/child.txt", "child")
        assert {:ok, _} = Fil.write(disk, "sub/deeper/grandchild.txt", "grandchild")

        assert {:ok, refs} = Fil.ls(disk)
        assert Enum.map(refs, & &1.path) == ["root.txt", "sub"]
        assert Enum.map(refs, & &1.stat.type) == [:regular, :directory]
        assert Enum.all?(refs, &(&1.disk == disk))

        assert {:ok, refs} = Fil.ls(disk, "sub")
        assert Enum.map(refs, & &1.path) == ["sub/child.txt", "sub/deeper"]
      end

      test "lists recursively", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "root.txt", "root")
        assert {:ok, _} = Fil.write(disk, "sub/child.txt", "child")
        assert {:ok, _} = Fil.write(disk, "sub/deeper/grandchild.txt", "grandchild")

        assert {:ok, refs} = Fil.ls(disk, ".", recursive: true)

        assert Enum.map(refs, & &1.path) == [
                 "root.txt",
                 "sub/child.txt",
                 "sub/deeper/grandchild.txt"
               ]

        assert Enum.all?(refs, &(&1.stat.type == :regular))

        assert {:ok, refs} = Fil.ls(disk, "sub", recursive: true)
        assert Enum.map(refs, & &1.path) == ["sub/child.txt", "sub/deeper/grandchild.txt"]
      end

      test "listing fills in a stat snapshot", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "sized.txt", "12345")
        assert {:ok, [ref]} = Fil.ls(disk)
        assert ref.stat.size == 5
        assert ref.stat.type == :regular
      end

      test "listing a missing prefix is empty", %{disk: disk} do
        assert Fil.ls(disk, "never/existed") == {:ok, []}
      end

      test "listed refs feed straight back into other operations", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "listed.txt", "content")
        assert {:ok, [ref]} = Fil.ls(disk)

        assert Fil.read(ref) == {:ok, "content"}
        assert {:ok, copied} = Fil.cp(ref, "listed-copy.txt")
        assert copied.stat == nil
        assert {:ok, deleted} = Fil.rm(ref)
        assert deleted.stat == nil
        refute Fil.exists?(disk, "listed.txt")
      end

      ## ----------------------------------------------------------------
      ## Copying and renaming
      ## ----------------------------------------------------------------

      test "copies within a disk", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "source.txt", "content")
        assert {:ok, ref} = Fil.cp(disk, "source.txt", "copies/target.txt")

        assert ref.path == "copies/target.txt"
        assert Fil.read(disk, "copies/target.txt") == {:ok, "content"}
        assert Fil.read(disk, "source.txt") == {:ok, "content"}
      end

      test "copying or renaming a missing file is not found", %{disk: disk} do
        assert {:error, %Fil.NotFoundError{}} = Fil.cp(disk, "nope.txt", "target.txt")
        assert {:error, %Fil.NotFoundError{}} = Fil.rename(disk, "nope.txt", "target.txt")
        refute Fil.exists?(disk, "target.txt")
      end

      test "renames within a disk", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "draft.txt", "content")
        assert {:ok, ref} = Fil.rename(disk, "draft.txt", "final/report.txt")

        assert ref.path == "final/report.txt"
        assert Fil.read(disk, "final/report.txt") == {:ok, "content"}
        assert {:error, %Fil.NotFoundError{}} = Fil.read(disk, "draft.txt")
      end

      test "an error across disks names the call", %{disk: disk, other_disk: other_disk} do
        assert {:error, %Fil.NotFoundError{op: :cp, path: "nope.txt"}} =
                 Fil.cp(disk, "nope.txt", Fil.ref(other_disk, "target.txt"))

        assert {:error, %Fil.NotFoundError{op: :rename, path: "nope.txt"}} =
                 Fil.rename(disk, "nope.txt", Fil.ref(other_disk, "target.txt"))
      end

      test "copies across disks", %{disk: disk, other_disk: other_disk} do
        assert {:ok, source} = Fil.write(disk, "shared/report.txt", "content")
        assert {:ok, ref} = Fil.cp(source, Fil.ref(other_disk, "backups/report.txt"))

        assert ref.disk == other_disk
        assert Fil.read(other_disk, "backups/report.txt") == {:ok, "content"}
        assert Fil.read(disk, "shared/report.txt") == {:ok, "content"}
      end

      test "renames across disks", %{disk: disk, other_disk: other_disk} do
        assert {:ok, source} = Fil.write(disk, "moving.txt", "content")
        assert {:ok, ref} = Fil.rename(source, Fil.ref(other_disk, "moved.txt"))

        assert ref.disk == other_disk
        assert Fil.read(other_disk, "moved.txt") == {:ok, "content"}
        assert {:error, %Fil.NotFoundError{}} = Fil.read(disk, "moving.txt")
      end

      ## ----------------------------------------------------------------
      ## Exclusive writes
      ## ----------------------------------------------------------------

      test "if_exists: :error never replaces a file", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "once.txt", "first", if_exists: :error)

        assert {:error, %Fil.AlreadyExistsError{}} =
                 Fil.write(disk, "once.txt", "second", if_exists: :error)

        assert Fil.read(disk, "once.txt") == {:ok, "first"}
      end

      ## ----------------------------------------------------------------
      ## Checksums
      ## ----------------------------------------------------------------

      test "stores and reports checksums", %{disk: disk} do
        content = "0123456789"

        expected = [
          sha256:
            :sha256
            |> :crypto.hash(content)
            |> Base.encode64(),
          sha1:
            :sha
            |> :crypto.hash(content)
            |> Base.encode64(),
          crc32: Base.encode64(<<:erlang.crc32(content)::32>>)
        ]

        for {algorithm, checksum} <- expected do
          path = "checksum-#{algorithm}.txt"

          assert {:ok, _} = Fil.write(disk, path, content, checksum: algorithm)
          assert Fil.read(disk, path, verify_checksum: true) == {:ok, content}
          assert {:ok, %Fil.Stat{checksum: {^algorithm, ^checksum}}} = Fil.stat(disk, path, checksum: algorithm)
        end

        assert {:ok, %Fil.Stat{checksum: nil}} = Fil.stat(disk, "checksum-sha256.txt")
      end

      ## ----------------------------------------------------------------
      ## URLs
      ## ----------------------------------------------------------------

      test "builds public URLs", %{disk: disk} do
        assert {:ok, url} = Fil.url(disk, "public/a file.txt")

        assert %URI{scheme: scheme, path: path, query: nil} = URI.parse(url)
        assert scheme in ["http", "https"]
        assert String.ends_with?(path, "/public/a%20file.txt")
      end

      test "signs download and upload URLs", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "signed/file.txt", "content")
        assert {:ok, get_url} = Fil.signed_url(disk, "signed/file.txt", expires_in: 300)
        assert {:ok, put_url} = Fil.signed_url(disk, "signed/file.txt", method: :put)

        assert %URI{scheme: scheme, path: path} = URI.parse(get_url)
        assert scheme in ["http", "https"]
        assert String.ends_with?(path, "/signed/file.txt")
        assert get_url != put_url
      end

      test "signs a content disposition into download URLs", %{disk: disk} do
        assert {:ok, plain} = Fil.signed_url(disk, "cv.pdf")
        assert {:ok, inline} = Fil.signed_url(disk, "cv.pdf", disposition: :inline)
        assert {:ok, attachment} = Fil.signed_url(disk, "cv.pdf", disposition: :attachment)
        assert {:ok, renamed} = Fil.signed_url(disk, "cv.pdf", disposition: {:attachment, "Lebenslauf.pdf"})

        # S3 names the parameter `response-content-disposition`, `Fil.Plugin.URL` just `disposition`.
        query_values = fn url ->
          url
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()
          |> Map.values()
        end

        assert "inline" in query_values.(inline)
        assert ~s(attachment; filename="cv.pdf") in query_values.(attachment)
        assert ~s(attachment; filename="Lebenslauf.pdf") in query_values.(renamed)

        refute plain
               |> query_values.()
               |> Enum.any?(&String.contains?(&1, "attachment"))

        assert_raise ArgumentError, ~r/disposition/, fn ->
          Fil.signed_url(disk, "cv.pdf", method: :put, disposition: :attachment)
        end
      end

      test "signs extra query parameters into URLs", %{disk: disk} do
        assert {:ok, url} = Fil.signed_url(disk, "index.html", query: [{"trackingInfo", "7-42-a b"}])
        assert {:ok, put_url} = Fil.signed_url(disk, "index.html", method: :put, query: [{"trackingInfo", "7"}])

        assert url
               |> URI.parse()
               |> Map.fetch!(:query)
               |> URI.decode_query()
               |> Map.get("trackingInfo") == "7-42-a b"

        assert put_url =~ "trackingInfo=7"

        for name <- ["expires", "Signature", "disposition", "X-Amz-Date", "response-content-type"] do
          assert_raise ArgumentError, ~r/can't set/, fn -> Fil.signed_url(disk, "index.html", query: [{name, "x"}]) end
        end
      end

      test "signed URLs expire after 7 days at most", %{disk: disk} do
        assert {:ok, _} = Fil.signed_url(disk, "a.txt", expires_in: 7 * 24 * 60 * 60)

        assert_raise ArgumentError, ~r/expires_in/, fn ->
          Fil.signed_url(disk, "a.txt", expires_in: 7 * 24 * 60 * 60 + 1)
        end
      end

      ## ----------------------------------------------------------------
      ## The path jail
      ## ----------------------------------------------------------------

      test "rejects paths escaping the disk root", %{disk: disk} do
        assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.read(disk, "../escape.txt")
        assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.read(disk, "a/../../escape.txt")
        assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.write(disk, "../escape.txt", "nope")
        assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.rm(disk, "../escape.txt")
        assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.ls(disk, "..")
        assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.stat(disk, "../escape.txt")
        assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.cp(disk, "../escape.txt", "here.txt")
        assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.rm_rf(disk, "..")
        refute Fil.exists?(disk, "../escape.txt")
      end

      test "normalizes paths before the adapter sees them", %{disk: disk} do
        assert {:ok, ref} = Fil.write(disk, "./a//b/../c.txt", "content")
        assert ref.path == "a/c.txt"
        assert Fil.read(disk, "a/c.txt") == {:ok, "content"}
        assert Fil.read(disk, "/a/c.txt") == {:ok, "content"}
      end

      ## ----------------------------------------------------------------
      ## Argument forms
      ## ----------------------------------------------------------------

      test "accepts disk and path, or a ref", %{disk: disk} do
        ref = Fil.ref(disk, "forms.txt")

        assert {:ok, _} = Fil.write(disk, "forms.txt", "one")

        assert disk
               |> Fil.ref("forms.txt")
               |> Fil.read() == {:ok, "one"}

        assert Fil.read(ref) == {:ok, "one"}

        assert {:ok, _} =
                 disk
                 |> Fil.ref("forms.txt")
                 |> Fil.write("two")

        assert Fil.read(disk, "forms.txt") == {:ok, "two"}

        assert {:ok, _} = Fil.write(ref, "three", [])
        assert Fil.read(disk, "forms.txt", []) == {:ok, "three"}

        assert {:ok, _} = Fil.cp(ref, Fil.ref(disk, "forms-copy.txt"))
        assert Fil.read(disk, "forms-copy.txt") == {:ok, "three"}

        assert {:ok, _} = Fil.rename(ref, "forms-renamed.txt")
        assert Fil.read(disk, "forms-renamed.txt") == {:ok, "three"}

        assert disk
               |> Fil.ref("forms-renamed.txt")
               |> Fil.exists?()

        assert {:ok, %Fil.Stat{}} =
                 disk
                 |> Fil.ref("forms-copy.txt")
                 |> Fil.stat()

        assert {:ok, _} =
                 disk
                 |> Fil.ref(".")
                 |> Fil.ls()
      end

      ## ----------------------------------------------------------------
      ## Bang variants
      ## ----------------------------------------------------------------

      test "bang variants return bare results", %{disk: disk} do
        assert %Fil.Ref{path: "bang.txt"} = Fil.write!(disk, "bang.txt", "content")
        assert Fil.read!(disk, "bang.txt") == "content"
        assert %Fil.Stat{} = Fil.stat!(disk, "bang.txt")
        assert [%Fil.Ref{}] = Fil.ls!(disk)
        assert %Fil.Ref{} = Fil.cp!(disk, "bang.txt", "bang-copy.txt")
        assert %Fil.Ref{} = Fil.rename!(disk, "bang-copy.txt", "bang-moved.txt")
        assert %Fil.Ref{} = Fil.rm!(disk, "bang-moved.txt")
        assert Fil.rm_rf!(disk, ".") >= 1
      end

      test "bang variants raise the error", %{disk: disk} do
        error = assert_raise(Fil.NotFoundError, fn -> Fil.read!(disk, "nope.txt") end)

        assert error.op == :read
        assert error.path == "nope.txt"
        assert error.disk == disk
        assert Exception.message(error) =~ ~s|could not read "nope.txt" on #{inspect(disk)}|

        assert_raise Fil.InvalidRequestError, fn ->
          disk
          |> Fil.ref("../escape.txt")
          |> Fil.read!()
        end

        assert_raise Fil.NotFoundError, fn -> Fil.stat!(disk, "nope.txt") end
        assert_raise Fil.NotFoundError, fn -> Fil.cp!(disk, "nope.txt", "target.txt") end
      end
    end
  end
end
