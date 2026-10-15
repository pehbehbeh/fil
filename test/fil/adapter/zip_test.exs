defmodule Fil.Adapter.ZipTest do
  alias Fil.Adapter.Memory
  alias Fil.Adapter.Zip
  alias Fil.ZipHelper

  use ExUnit.Case, async: true

  @guide String.duplicate("Install it with mix. ", 200)

  setup do
    Memory.checkout()
    [archives: Fil.disk(adapter: Memory, root: "archives")]
  end

  # A disk on `bytes`, stored on the memory disk as `name`.
  defp zip_disk(archives, bytes, name \\ "docs.zip") do
    Fil.write!(archives, name, bytes)
    Fil.disk(adapter: Zip, archive: Fil.ref(archives, name))
  end

  defp created(files) do
    {:ok, {_name, bytes}} = :zip.create(~c"docs.zip", files, [:memory])
    bytes
  end

  # Sends the test every call on the archive's disk, with the range of reads.
  defp counting(archives) do
    test = self()

    Fil.attach(archives, :count, fn op, next, _opts ->
      send(test, {:archive, op.name, op.options[:offset], op.options[:length]})
      next.(op)
    end)
  end

  defp archive_calls do
    receive do
      {:archive, name, offset, length} -> [{name, offset, length} | archive_calls()]
    after
      0 -> []
    end
  end

  describe "init/1" do
    test "takes the archive as a ref", %{archives: archives} do
      archive = Fil.ref(archives, "docs.zip")

      assert {:ok, %Zip{archive: ^archive}} = Zip.init(archive: archive)
      assert {:error, %NimbleOptions.ValidationError{}} = Zip.init([])
      assert {:error, %NimbleOptions.ValidationError{}} = Zip.init(archive: "docs.zip")
    end
  end

  describe "an archive from :zip.create/3" do
    setup %{archives: archives} do
      bytes = created([{~c"README.md", "# Docs"}, {~c"docs/guide.md", @guide}, {~c"docs/api/index.html", "<h1>"}])
      [disk: zip_disk(archives, bytes)]
    end

    test "reads and streams its files", %{disk: disk} do
      assert Fil.read(disk, "README.md") == {:ok, "# Docs"}
      assert Fil.read(disk, "docs/guide.md") == {:ok, @guide}

      assert disk
             |> Fil.stream!("docs/guide.md")
             |> Enum.join() == @guide
    end

    test "reads parts of a compressed file", %{disk: disk} do
      assert Fil.read(disk, "docs/guide.md", offset: 8, length: 10) == {:ok, binary_part(@guide, 8, 10)}
      assert Fil.read(disk, "docs/guide.md", offset: byte_size(@guide) + 5) == {:ok, ""}

      part =
        disk
        |> Fil.stream!("docs/guide.md", offset: 4000)
        |> Enum.join()

      assert part == binary_part(@guide, 4000, byte_size(@guide) - 4000)
    end

    test "lists one level and recursively", %{disk: disk} do
      assert {:ok, top} = Fil.ls(disk, ".")
      assert Enum.map(top, &{&1.path, &1.stat.type}) == [{"README.md", :regular}, {"docs", :directory}]

      assert {:ok, docs} = Fil.ls(disk, "docs")
      assert Enum.map(docs, & &1.path) == ["docs/api", "docs/guide.md"]

      assert {:ok, files} = Fil.ls(disk, ".", recursive: true)
      assert Enum.map(files, & &1.path) == ["README.md", "docs/api/index.html", "docs/guide.md"]

      assert {:ok, directories} = Fil.ls(disk, ".", recursive: true, type: :directory)
      assert Enum.map(directories, & &1.path) == ["docs", "docs/api"]

      assert {:ok, []} = Fil.ls(disk, "missing")
    end

    test "stats files and directories", %{disk: disk} do
      crc = :erlang.crc32(@guide)
      etag = Base.encode16(<<crc::32>>, case: :lower) <> "-#{byte_size(@guide)}"

      assert {:ok, %Fil.Stat{type: :regular, size: size, etag: ^etag, mtime: %DateTime{}, content_type: nil}} =
               Fil.stat(disk, "docs/guide.md")

      assert size == byte_size(@guide)
      assert {:ok, %Fil.Stat{type: :directory}} = Fil.stat(disk, "docs/api")
      assert {:ok, %Fil.Stat{type: :directory}} = Fil.stat(disk, ".")
      assert {:error, %Fil.NotFoundError{op: :stat, reason: :enoent}} = Fil.stat(disk, "docs/missing.md")
      assert {:error, %Fil.NotFoundError{op: :read, reason: :enoent}} = Fil.read(disk, "docs")
    end

    test "returns checksums", %{disk: disk} do
      for algorithm <- [:crc32, :sha256] do
        checksum = Fil.Support.Checksum.digest(algorithm, @guide)

        assert {:ok, %Fil.Stat{checksum: {^algorithm, ^checksum}}} =
                 Fil.stat(disk, "docs/guide.md", checksum: algorithm)
      end
    end

    test "copies files to another disk", %{disk: disk, archives: archives} do
      guide = Fil.ref(disk, "docs/guide.md")

      assert {:ok, _copy} = Fil.cp(guide, Fil.ref(archives, "guide.md"))
      assert Fil.read(archives, "guide.md") == {:ok, @guide}
    end

    test "is the same storage as another disk on the same archive", %{disk: disk, archives: archives} do
      assert Fil.Disk.same_storage?(disk, Fil.disk(adapter: Zip, archive: Fil.ref(archives, "docs.zip")))
      refute Fil.Disk.same_storage?(disk, Fil.disk(adapter: Zip, archive: Fil.ref(archives, "other.zip")))

      other_store = Fil.disk(adapter: Memory, root: "elsewhere")
      refute Fil.Disk.same_storage?(disk, Fil.disk(adapter: Zip, archive: Fil.ref(other_store, "docs.zip")))
    end
  end

  @tag :tmp_dir
  test "reads an archive on a local disk", %{tmp_dir: tmp_dir} do
    local = Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)
    disk = zip_disk(local, created([{~c"a.txt", "local"}]))

    assert Fil.read(disk, "a.txt") == {:ok, "local"}
  end

  describe "stored and deflated entries" do
    setup %{archives: archives} do
      bytes =
        ZipHelper.build([
          %{name: "stored.txt", content: "stored content"},
          %{name: "deflated.txt", content: @guide, method: 8},
          %{name: "empty/", content: ""},
          %{name: "nothing.txt", content: ""}
        ])

      [disk: zip_disk(archives, bytes)]
    end

    test "are read whole and in parts", %{disk: disk} do
      assert Fil.read(disk, "stored.txt") == {:ok, "stored content"}
      assert Fil.read(disk, "stored.txt", offset: 7, length: 3) == {:ok, "con"}
      assert Fil.read(disk, "deflated.txt", offset: 1, length: 4) == {:ok, binary_part(@guide, 1, 4)}
      assert Fil.read(disk, "nothing.txt") == {:ok, ""}
    end

    test "are streamed whole and in parts, each time the stream is read", %{disk: disk} do
      stream = Fil.stream!(disk, "deflated.txt")
      assert Enum.join(stream) == @guide
      assert Enum.join(stream) == @guide

      assert disk
             |> Fil.stream!("stored.txt", offset: 7)
             |> Enum.join() == "content"

      assert disk
             |> Fil.stream!("deflated.txt", offset: 3, length: 5)
             |> Enum.join() == binary_part(@guide, 3, 5)

      assert disk
             |> Fil.stream!("nothing.txt")
             |> Enum.to_list() == []
    end

    test "have the size of their content when streamed" do
      bytes = ZipHelper.build([%{name: "deflated.txt", content: @guide, method: 8}])
      archives = Fil.disk(adapter: Memory, root: "sizes")
      disk = zip_disk(archives, bytes)
      %Fil.Disk{adapter: {Zip, state}} = disk

      assert {:ok, _stream, size} = Zip.stream(state, "deflated.txt", [])
      assert size == byte_size(@guide)
      assert {:ok, _stream, 10} = Zip.stream(state, "deflated.txt", offset: 5, length: 10)
    end

    test "list a directory entry even when it's empty", %{disk: disk} do
      assert {:ok, %Fil.Stat{type: :directory}} = Fil.stat(disk, "empty")
      assert {:ok, listed} = Fil.ls(disk, ".")

      assert Enum.map(listed, &{&1.path, &1.stat.type}) == [
               {"deflated.txt", :regular},
               {"empty", :directory},
               {"nothing.txt", :regular},
               {"stored.txt", :regular}
             ]
    end
  end

  describe "reads of the archive" do
    test "are a stat and one ranged read for a listing, and one more for a file", %{archives: archives} do
      disk =
        archives
        |> counting()
        |> zip_disk(ZipHelper.build([%{name: "a.txt", content: "abc"}]))

      archive_calls()

      assert {:ok, _} = Fil.ls(disk, ".")
      assert [{:stat, nil, nil}, {:read, 0, _tail}] = archive_calls()

      assert {:ok, "abc"} = Fil.read(disk, "a.txt")
      assert [{:stat, nil, nil}, {:read, 0, _tail}, {:read, 0, _entry}] = archive_calls()
    end

    test "for a part of a stored entry are the header and only that part", %{archives: archives} do
      content = String.duplicate("0123456789", 1000)

      disk =
        archives
        |> counting()
        |> zip_disk(ZipHelper.build([%{name: "a.txt", content: content}]))

      archive_calls()

      assert Fil.read(disk, "a.txt", offset: 5000, length: 4) == {:ok, "0123"}
      assert [{:stat, _, _}, {:read, 0, _tail}, {:read, 0, header}, {:read, content_start, 4}] = archive_calls()
      assert header < 100
      assert content_start == header + 5000
    end

    test "for a part of a deflated entry or a checksum stream the entry", %{archives: archives} do
      disk =
        archives
        |> counting()
        |> zip_disk(ZipHelper.build([%{name: "a.txt", content: @guide, method: 8}]))

      archive_calls()

      assert Fil.read(disk, "a.txt", offset: 5, length: 3) == {:ok, binary_part(@guide, 5, 3)}
      assert [{:stat, _, _}, {:read, 0, _tail}, {:read, 0, _header}, {:read, _start, _compressed}] = archive_calls()

      checksum = Fil.Support.Checksum.digest(:sha1, @guide)
      assert {:ok, %Fil.Stat{checksum: {:sha1, ^checksum}}} = Fil.stat(disk, "a.txt", checksum: :sha1)
      assert [{:stat, _, _}, {:read, 0, _tail}, {:read, 0, _header}, {:read, _start, _compressed}] = archive_calls()
    end

    test "read a central directory that starts before the tail on its own", %{archives: archives} do
      names = for i <- 1..800, do: "#{String.duplicate("long-name-", 10)}#{i}.txt"

      bytes =
        names
        |> Enum.map(&%{name: &1, content: "x"})
        |> ZipHelper.build()

      disk =
        archives
        |> counting()
        |> zip_disk(bytes)

      archive_calls()

      assert {:ok, listed} = Fil.ls(disk, ".")
      assert length(listed) == 800
      assert [{:stat, nil, nil}, {:read, tail_start, _}, {:read, cd_offset, _}] = archive_calls()
      assert cd_offset < tail_start
    end

    test "read the content again when the local header is longer than the central directory says",
         %{archives: archives} do
      extra = <<0xCAFE::16-little, 300::16-little, :binary.copy(<<0>>, 300)::binary>>
      bytes = ZipHelper.build([%{name: "a.txt", content: "abc", local_extra: extra}, %{name: "b.txt", content: "d"}])

      disk =
        archives
        |> counting()
        |> zip_disk(bytes)

      archive_calls()

      assert Fil.read(disk, "a.txt") == {:ok, "abc"}
      assert [{:stat, _, _}, {:read, _, _}, {:read, 0, _guess}, {:read, _content, 3}] = archive_calls()

      assert disk
             |> Fil.stream!("a.txt")
             |> Enum.join() == "abc"
    end
  end

  describe "Zip64 archives" do
    test "are read and listed", %{archives: archives} do
      bytes =
        ZipHelper.build([%{name: "a.txt", content: "zip64"}, %{name: "b/c.txt", content: @guide, method: 8}],
          zip64: true
        )

      disk = zip_disk(archives, bytes)

      assert Fil.read(disk, "a.txt") == {:ok, "zip64"}
      assert Fil.read(disk, "b/c.txt") == {:ok, @guide}
      assert {:ok, %Fil.Stat{size: 5}} = Fil.stat(disk, "a.txt")
      assert {:ok, listed} = Fil.ls(disk, ".", recursive: true)
      assert Enum.map(listed, & &1.path) == ["a.txt", "b/c.txt"]
    end
  end

  describe "end records" do
    test "with 0xFFFF entries and no Zip64 locator count as they are", %{archives: archives} do
      disk = zip_disk(archives, ZipHelper.build([%{name: "a.txt", content: "abc"}], count: 0xFFFF))

      assert Fil.read(disk, "a.txt") == {:ok, "abc"}
    end

    test "in the comment don't count when they don't point to the central directory", %{archives: archives} do
      fake = <<0x06054B50::32-little, 0::64, 0::32-little, 0::32-little, 0::16>>
      bytes = ZipHelper.build([%{name: "a.txt", content: "abc"}], comment: "see " <> fake)
      disk = zip_disk(archives, bytes)

      assert Fil.read(disk, "a.txt") == {:ok, "abc"}
    end

    test "in the comment whose length doesn't fit are skipped", %{archives: archives} do
      fake = <<0x06054B50::32-little, 0::64, 0::32-little, 0::32-little, 99::16-little>>
      bytes = ZipHelper.build([%{name: "a.txt", content: "abc"}], comment: fake <> "tail")
      disk = zip_disk(archives, bytes)

      assert Fil.read(disk, "a.txt") == {:ok, "abc"}
    end

    test "followed by more bytes or after a prefix make the archive damaged", %{archives: archives} do
      bytes = ZipHelper.build([%{name: "a.txt", content: "abc"}])

      assert {:error, %Fil.ConfigurationError{reason: {:bad_archive, :no_end_record}}} =
               archives
               |> zip_disk(bytes <> "trailing", "trailing.zip")
               |> Fil.ls(".")

      assert {:error, %Fil.ConfigurationError{reason: {:bad_archive, :central_directory}}} =
               archives
               |> zip_disk("#!/bin/sh\n" <> bytes, "prefixed.zip")
               |> Fil.ls(".")
    end
  end

  describe "data descriptors" do
    test "after the content leave the local header's sizes empty, which isn't read", %{archives: archives} do
      bytes =
        ZipHelper.build([
          %{name: "a.txt", content: "abc", descriptor: true},
          %{name: "b.txt", content: @guide, method: 8, descriptor: true}
        ])

      disk = zip_disk(archives, bytes)

      assert Fil.read(disk, "a.txt") == {:ok, "abc"}
      assert Fil.read(disk, "b.txt") == {:ok, @guide}

      assert disk
             |> Fil.stream!("b.txt")
             |> Enum.join() == @guide
    end
  end

  describe "a stream of a deflated entry" do
    test "yields pieces of zlib's buffer size, also from one large chunk of input", %{archives: archives} do
      zeros = :binary.copy(<<0>>, 4_000_000)
      deflated = ZipHelper.deflate(zeros)
      disk = zip_disk(archives, ZipHelper.build([%{name: "zeros.bin", content: zeros, method: 8}]))
      %Fil.Disk{adapter: {Zip, state}} = disk

      # The memory disk hands over the compressed content as one chunk.
      assert [^deflated] =
               state.archive
               |> Fil.stream!(offset: 30 + byte_size("zeros.bin"), length: byte_size(deflated))
               |> Enum.to_list()

      sizes =
        disk
        |> Fil.stream!("zeros.bin")
        |> Enum.map(&byte_size/1)

      assert Enum.sum(sizes) == 4_000_000
      assert Enum.max(sizes) <= 16_384
    end
  end

  describe "an entry that inflates to more than its size" do
    setup %{archives: archives} do
      zeros = :binary.copy(<<0>>, 4_000_000)
      bytes = ZipHelper.build([%{name: "bomb.bin", content: zeros, method: 8, size: 1000}])
      [disk: zip_disk(archives, bytes)]
    end

    test "fails as soon as it passes that size", %{disk: disk} do
      too_large = {:bad_entry, :size}

      assert {:error, %Fil.ChecksumMismatchError{reason: ^too_large}} = Fil.read(disk, "bomb.bin")
      assert {:error, %Fil.ChecksumMismatchError{reason: ^too_large}} = Fil.read(disk, "bomb.bin", offset: 500)
      assert {:error, %Fil.ChecksumMismatchError{reason: ^too_large}} = Fil.stat(disk, "bomb.bin", checksum: :sha256)
    end

    test "never yields more than that size from a stream", %{disk: disk} do
      for opts <- [[], [offset: 500]] do
        test = self()

        assert_raise Fil.ChecksumMismatchError, fn ->
          disk
          |> Fil.stream!("bomb.bin", opts)
          |> Enum.each(&send(test, {:chunk, byte_size(&1)}))
        end

        yielded = Enum.sum(chunk_sizes())
        assert yielded <= 1000
      end
    end

    test "that ends early fails a stream of a part", %{archives: archives} do
      deflated = ZipHelper.deflate(@guide)
      cut = binary_part(deflated, 0, div(byte_size(deflated), 2))
      bytes = ZipHelper.build([%{name: "cut.txt", content: @guide, method: 8, data: cut}])
      disk = zip_disk(archives, bytes, "cut.zip")

      assert_raise Fil.ChecksumMismatchError, fn ->
        disk
        |> Fil.stream!("cut.txt", offset: 10)
        |> Enum.join()
      end
    end
  end

  defp chunk_sizes do
    receive do
      {:chunk, size} -> [size | chunk_sizes()]
    after
      0 -> []
    end
  end

  describe "entry names" do
    test "that escape the root or aren't normalized are left out", %{archives: archives} do
      bytes =
        ZipHelper.build([
          %{name: "../evil.txt", content: "evil"},
          %{name: "/etc/passwd", content: "root"},
          %{name: "a/./b.txt", content: "dot"},
          %{name: "a//c.txt", content: "slashes"},
          %{name: "ok.txt", content: "fine"},
          %{name: "ok.txt", content: "second"}
        ])

      disk = zip_disk(archives, bytes)

      assert {:ok, listed} = Fil.ls(disk, ".", recursive: true)
      assert Enum.map(listed, & &1.path) == ["ok.txt"]
      assert {:ok, []} = Fil.ls(disk, ".", recursive: true, type: :directory)
      assert Fil.read(disk, "ok.txt") == {:ok, "fine"}
      assert {:error, %Fil.NotFoundError{}} = Fil.read(disk, "etc/passwd")
      assert {:error, %Fil.NotFoundError{}} = Fil.read(disk, "a/b.txt")
    end

    test "that aren't UTF-8 are read as Latin-1, with the UTF-8 flag or without", %{archives: archives} do
      bytes =
        ZipHelper.build([
          %{name: <<"caf", 0xE9, ".txt">>, content: "latte", flags: 0},
          %{name: <<"th", 0xE9, ".txt">>, content: "earl grey"}
        ])

      disk = zip_disk(archives, bytes)

      assert Fil.read(disk, "café.txt") == {:ok, "latte"}
      assert Fil.read(disk, "thé.txt") == {:ok, "earl grey"}
    end

    test "can name a file and a directory at once, like keys on an object store", %{archives: archives} do
      bytes = ZipHelper.build([%{name: "a", content: "file"}, %{name: "a/b.txt", content: "below"}])
      disk = zip_disk(archives, bytes)

      assert {:ok, listed} = Fil.ls(disk, ".")
      assert Enum.map(listed, &{&1.path, &1.stat.type}) == [{"a", :regular}, {"a", :directory}]
      assert {:ok, %Fil.Stat{type: :regular}} = Fil.stat(disk, "a")
      assert Fil.read(disk, "a") == {:ok, "file"}
      assert Fil.read(disk, "a/b.txt") == {:ok, "below"}
    end
  end

  describe "entries that can't be read" do
    setup %{archives: archives} do
      bytes =
        ZipHelper.build([
          %{name: "bzip2.txt", content: "abc", method: 12, data: "BZh"},
          %{name: "secret.txt", content: "abc", flags: 0x0801},
          %{name: "damaged.txt", content: "abc", crc: 1},
          %{name: "damaged-deflated.txt", content: @guide, method: 8, crc: 1}
        ])

      [disk: zip_disk(archives, bytes)]
    end

    test "with another compression method or encrypted are unsupported", %{disk: disk} do
      assert {:error, %Fil.UnsupportedError{op: :read, path: "bzip2.txt", reason: {:compression, 12}}} =
               Fil.read(disk, "bzip2.txt")

      assert {:error, %Fil.UnsupportedError{reason: :encrypted}} = Fil.read(disk, "secret.txt")
      assert {:error, %Fil.UnsupportedError{reason: :encrypted}} = Fil.stream(disk, "secret.txt")
      assert {:ok, %Fil.Stat{size: 3}} = Fil.stat(disk, "bzip2.txt")
    end

    test "with a wrong CRC-32 fail whole, also as a stream", %{disk: disk} do
      assert {:error, %Fil.ChecksumMismatchError{op: :read, path: "damaged.txt", reason: :checksum_mismatch}} =
               Fil.read(disk, "damaged.txt")

      assert {:error, %Fil.ChecksumMismatchError{}} = Fil.read(disk, "damaged-deflated.txt")

      for path <- ["damaged.txt", "damaged-deflated.txt"] do
        error =
          assert_raise Fil.ChecksumMismatchError, fn ->
            disk
            |> Fil.stream!(path)
            |> Enum.join()
          end

        assert error.path == path
        assert error.disk == disk
      end

      assert Fil.read(disk, "damaged.txt", offset: 1) == {:ok, "bc"}
    end
  end

  describe "archives that can't be read" do
    test "missing is a configuration error with the archive's error as the reason", %{archives: archives} do
      disk = Fil.disk(adapter: Zip, archive: Fil.ref(archives, "missing.zip"))

      assert {:error, %Fil.ConfigurationError{op: :read, path: "a.txt", disk: ^disk} = error} =
               Fil.read(disk, "a.txt")

      assert %Fil.NotFoundError{op: :stat, path: "missing.zip", disk: ^archives} = error.reason
      assert Exception.message(error) =~ ~s|"missing.zip"|
      assert {:error, %Fil.ConfigurationError{op: :ls}} = Fil.ls(disk, ".")
    end

    test "that aren't zip archives or are damaged are configuration errors", %{archives: archives} do
      bytes = ZipHelper.build([%{name: "a.txt", content: "abc"}])

      for {name, content, where} <- [
            {"text.zip", "not a zip archive", :no_end_record},
            {"empty.zip", "", :no_end_record},
            {"truncated.zip", binary_part(bytes, 10, byte_size(bytes) - 10), :central_directory}
          ] do
        disk = zip_disk(archives, content, name)

        assert {:error, %Fil.ConfigurationError{reason: {:bad_archive, ^where}}} = Fil.ls(disk, "."), name
      end
    end

    test "with a damaged local header fail for that entry only", %{archives: archives} do
      bytes = ZipHelper.build([%{name: "a.txt", content: "abc"}])
      <<_signature::32, rest::binary>> = bytes
      disk = zip_disk(archives, <<0::32, rest::binary>>)

      assert {:error, %Fil.ChecksumMismatchError{reason: {:bad_entry, :local_header}}} = Fil.read(disk, "a.txt")
      assert {:ok, %Fil.Stat{size: 3}} = Fil.stat(disk, "a.txt")
    end

    test "whose central directory ends past the end record are damaged", %{archives: archives} do
      bytes = ZipHelper.build([%{name: "a.txt", content: "abc"}], cd_size: 500)
      disk = zip_disk(archives, bytes)

      assert {:error, %Fil.ConfigurationError{reason: {:bad_archive, :central_directory}}} = Fil.ls(disk, ".")
    end

    test "with an entry past the central directory or a stored entry of two sizes are damaged", %{archives: archives} do
      for {name, entry} <- [
            {"offset.zip", %{name: "a.txt", content: "abc", offset: 10_000}},
            {"sizes.zip", %{name: "a.txt", content: "abc", size: 5}}
          ] do
        disk = zip_disk(archives, ZipHelper.build([entry]), name)

        assert {:error, %Fil.ConfigurationError{reason: {:bad_archive, :central_directory}}} = Fil.ls(disk, "."), name
      end
    end

    test "with 0xFFFFFFFF as a size and no Zip64 extra field are damaged", %{archives: archives} do
      disk = zip_disk(archives, ZipHelper.build([%{name: "a.txt", content: "abc", zip64_marker: true}]))

      assert {:error, %Fil.ConfigurationError{reason: {:bad_archive, :zip64_extra}}} = Fil.ls(disk, ".")
    end

    test "with a Zip64 locator that points to no Zip64 end record are damaged", %{archives: archives} do
      bytes = ZipHelper.build([%{name: "a.txt", content: "abc"}], zip64: true)
      [before, record] = :binary.split(bytes, <<0x06064B50::32-little>>)
      disk = zip_disk(archives, before <> <<0::32>> <> record)

      assert {:error, %Fil.ConfigurationError{reason: {:bad_archive, :zip64_end_record}}} = Fil.ls(disk, ".")
    end

    test "return the archive disk's errors as errors of the zip disk", %{archives: archives} do
      Fil.write!(archives, "docs.zip", ZipHelper.build([%{name: "a.txt", content: "abc"}]))

      failing =
        Fil.attach(archives, :fail_reads, fn
          %Fil.Op{name: :read} = op, _next, _opts -> Fil.Op.put_result(op, {:error, %Fil.UnavailableError{}})
          op, next, _opts -> next.(op)
        end)

      disk = Fil.disk(adapter: Zip, archive: Fil.ref(failing, "docs.zip"))

      assert {:error, %Fil.UnavailableError{op: :read, path: "a.txt", disk: ^disk} = error} = Fil.read(disk, "a.txt")
      assert %Fil.UnavailableError{op: :read, path: "docs.zip"} = error.reason
    end

    test "raise the archive's errors from a stream as errors of the zip disk", %{archives: archives} do
      bytes = ZipHelper.build([%{name: "a.txt", content: "abc"}])

      closed = Stream.map([1], fn _chunk -> raise %Fil.UnavailableError{reason: :closed} end)

      failing =
        Fil.attach(archives, :fail_streams, fn
          %Fil.Op{name: :read, streaming: true} = op, _next, _opts -> Fil.Op.put_result(op, {:ok, closed})
          op, next, _opts -> next.(op)
        end)

      Fil.write!(archives, "docs.zip", bytes)
      disk = Fil.disk(adapter: Zip, archive: Fil.ref(failing, "docs.zip"))

      error =
        assert_raise Fil.UnavailableError, fn ->
          disk
          |> Fil.stream!("a.txt")
          |> Enum.join()
        end

      assert error.path == "a.txt"
      assert %Fil.UnavailableError{path: "docs.zip", reason: :closed} = error.reason
    end
  end

  describe "changes" do
    setup %{archives: archives} do
      disk =
        archives
        |> counting()
        |> zip_disk(ZipHelper.build([%{name: "a.txt", content: "abc"}]))

      archive_calls()
      [disk: disk]
    end

    test "are refused without reading the archive", %{disk: disk, archives: archives} do
      assert {:error, %Fil.AccessDeniedError{op: :write, reason: :read_only}} = Fil.write(disk, "b.txt", "new")
      assert {:error, %Fil.AccessDeniedError{op: :rm, reason: :read_only}} = Fil.rm(disk, "a.txt")
      assert {:error, %Fil.AccessDeniedError{op: :rm, reason: :read_only}} = Fil.rm(disk, "missing.txt")
      assert {:error, %Fil.AccessDeniedError{op: :rm_rf, reason: :read_only}} = Fil.rm_rf(disk, ".")
      assert {:error, %Fil.AccessDeniedError{op: :cp, reason: :read_only}} = Fil.cp(disk, "a.txt", "b.txt")
      assert {:error, %Fil.AccessDeniedError{op: :rename, reason: :read_only}} = Fil.rename(disk, "a.txt", "b.txt")
      assert archive_calls() == []

      archive = Fil.ref(archives, "docs.zip")

      assert {:error, %Fil.AccessDeniedError{op: :cp}} = Fil.cp(archive, Fil.ref(disk, "c.zip"))
      assert Fil.read(disk, "a.txt") == {:ok, "abc"}
    end
  end

  describe "URLs" do
    test "need Fil.Plugin.URL, and Fil.Plug serves the files", %{archives: archives} do
      disk = zip_disk(archives, ZipHelper.build([%{name: "a.txt", content: "abc"}]))

      assert {:error, %Fil.UnsupportedError{reason: :no_callback}} = Fil.url(disk, "a.txt")

      served = Fil.Plugin.URL.attach(disk, base_url: "http://localhost/storage", secret: "secret")
      url = Fil.signed_url!(served, "a.txt")

      assert {200, _headers, "abc"} = Fil.AdapterCase.plug_request(served, :get, url, [])
    end
  end
end
