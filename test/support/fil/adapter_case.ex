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
            ],
            unsupported: [
              type: {:list, {:in, [:conditional_write, :checksum]}},
              default: [],
              doc: """
              Parts of the contract the backend under test doesn't implement. The matching test is then skipped instead
              of failing. This is meant for emulators with known gaps, not for adapters that cut corners.
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

  @doc "Builds the disk under test."
  @callback fil_disk(map()) :: Fil.Disk.t()

  @doc "Builds the second disk, used by the cross-disk tests."
  @callback fil_other_disk(map()) :: Fil.Disk.t()

  # Generated at compile time instead of branching at runtime, so each suite only contains the variant for its backend.
  defp conditional_write_test(false) do
    quote do
      test "if_none_match: :any creates exclusively", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "once.txt", "first", if_none_match: :any)

        assert {:error, :precondition_failed} =
                 Fil.write(disk, "once.txt", "second", if_none_match: :any)

        assert Fil.read(disk, "once.txt") == {:ok, "first"}
      end
    end
  end

  defp conditional_write_test(true) do
    quote do
      @tag :skip
      test "if_none_match: :any creates exclusively", %{disk: disk} do
        # This backend declares conditional writes unsupported. The test stays in as skipped, so the gap shows up in the
        # test output.
        assert {:error, :precondition_failed} =
                 Fil.write(disk, "once.txt", "second", if_none_match: :any)
      end
    end
  end

  defp checksum_test(false) do
    quote do
      test "stores and reports checksums", %{disk: disk} do
        content = "0123456789"

        expected = [
          sha256: Base.encode64(:crypto.hash(:sha256, content)),
          sha1: Base.encode64(:crypto.hash(:sha, content)),
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
    end
  end

  defp checksum_test(true) do
    quote do
      @tag :skip
      test "stores and reports checksums", %{disk: disk} do
        # This backend declares checksums unsupported. The test stays in as skipped, so the gap shows up in the test
        # output.
        assert {:ok, _} = Fil.write(disk, "checksum.txt", "content", checksum: :sha256)
      end
    end
  end

  defmacro __using__(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    # Module tags have to be set before the tests below are registered, so extra ones are passed as an option:
    # `use Fil.AdapterCase, tags: [:integration]`.
    moduletags = for tag <- [:tmp_dir | opts[:tags]], do: quote(do: @moduletag(unquote(tag)))
    case_opts = [async: opts[:async]]
    conditional_write = conditional_write_test(:conditional_write in opts[:unsupported])
    checksum = checksum_test(:checksum in opts[:unsupported])

    # This quote block contains every test of the suite, which is why it's long.
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      @behaviour Fil.AdapterCase

      use ExUnit.Case, unquote(case_opts)

      alias Fil.Adapter.Local

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

      test "reading a missing file is :enoent", %{disk: disk} do
        assert Fil.read(disk, "nope.txt") == {:error, :enoent}
        assert Fil.read(disk, "missing/nope.txt") == {:error, :enoent}
      end

      test "stat of a missing file is :enoent", %{disk: disk} do
        assert Fil.stat(disk, "nope.txt") == {:error, :enoent}
      end

      ## ----------------------------------------------------------------
      ## Deleting
      ## ----------------------------------------------------------------

      test "deletes a file and is idempotent", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "bye.txt", "later")
        assert {:ok, ref} = Fil.rm(disk, "bye.txt")
        assert ref.path == "bye.txt"
        assert Fil.read(disk, "bye.txt") == {:error, :enoent}
        assert {:ok, ^ref} = Fil.rm(disk, "bye.txt")
        assert {:ok, _} = Fil.rm(disk, "never/existed.txt")
      end

      test "deletes everything under a prefix", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "keep.txt", "keep")
        assert {:ok, _} = Fil.write(disk, "trash/a.txt", "a")
        assert {:ok, _} = Fil.write(disk, "trash/nested/b.txt", "b")

        assert {:ok, 2} = Fil.rm_rf(disk, "trash")
        assert Fil.read(disk, "trash/a.txt") == {:error, :enoent}
        assert Fil.read(disk, "trash/nested/b.txt") == {:error, :enoent}
        assert Fil.read(disk, "keep.txt") == {:ok, "keep"}
      end

      test "deleting a missing prefix removes nothing", %{disk: disk} do
        assert {:ok, 0} = Fil.rm_rf(disk, "never/existed")
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

      test "copying a missing file fails", %{disk: disk} do
        # `:enoent` on AWS and on the local filesystem; some S3-compatible servers report a plain 400 instead, which is
        # still a refusal.
        assert {:error, _reason} = Fil.cp(disk, "nope.txt", "target.txt")
        refute Fil.exists?(disk, "target.txt")
      end

      test "renames within a disk", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "draft.txt", "content")
        assert {:ok, ref} = Fil.rename(disk, "draft.txt", "final/report.txt")

        assert ref.path == "final/report.txt"
        assert Fil.read(disk, "final/report.txt") == {:ok, "content"}
        assert Fil.read(disk, "draft.txt") == {:error, :enoent}
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
        assert Fil.read(disk, "moving.txt") == {:error, :enoent}
      end

      ## ----------------------------------------------------------------
      ## Conditional writes
      ## ----------------------------------------------------------------

      unquote(conditional_write)

      ## ----------------------------------------------------------------
      ## Checksums
      ## ----------------------------------------------------------------

      unquote(checksum)

      ## ----------------------------------------------------------------
      ## Signed URLs
      ## ----------------------------------------------------------------

      test "signs download and upload URLs", %{disk: disk} do
        assert {:ok, _} = Fil.write(disk, "signed/file.txt", "content")
        assert {:ok, get_url} = Fil.signed_url(disk, "signed/file.txt", expires_in: 300)
        assert {:ok, put_url} = Fil.signed_url(disk, "signed/file.txt", method: :put)

        assert %URI{scheme: scheme, path: path} = URI.parse(get_url)
        assert scheme in ["http", "https"]
        assert String.ends_with?(path, "/signed/file.txt")
        assert get_url != put_url
      end

      test "signed URLs expire after 7 days at most", %{disk: disk} do
        assert {:ok, _} = Fil.signed_url(disk, "a.txt", expires_in: 7 * 24 * 60 * 60)

        assert Fil.signed_url(disk, "a.txt", expires_in: 7 * 24 * 60 * 60 + 1) ==
                 {:error, {:invalid_option, :expires_in}}
      end

      ## ----------------------------------------------------------------
      ## The path jail
      ## ----------------------------------------------------------------

      test "rejects paths escaping the disk root", %{disk: disk} do
        assert Fil.read(disk, "../escape.txt") == {:error, :ebadpath}
        assert Fil.read(disk, "a/../../escape.txt") == {:error, :ebadpath}
        assert Fil.write(disk, "../escape.txt", "nope") == {:error, :ebadpath}
        assert Fil.rm(disk, "../escape.txt") == {:error, :ebadpath}
        assert Fil.ls(disk, "..") == {:error, :ebadpath}
        assert Fil.stat(disk, "../escape.txt") == {:error, :ebadpath}
        assert Fil.cp(disk, "../escape.txt", "here.txt") == {:error, :ebadpath}
        assert Fil.rm_rf(disk, "..") == {:error, :ebadpath}
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
        assert Fil.read(Fil.ref(disk, "forms.txt")) == {:ok, "one"}
        assert Fil.read(ref) == {:ok, "one"}

        assert {:ok, _} = Fil.write(Fil.ref(disk, "forms.txt"), "two")
        assert Fil.read(disk, "forms.txt") == {:ok, "two"}

        assert {:ok, _} = Fil.write(ref, "three", [])
        assert Fil.read(disk, "forms.txt", []) == {:ok, "three"}

        assert {:ok, _} = Fil.cp(ref, Fil.ref(disk, "forms-copy.txt"))
        assert Fil.read(disk, "forms-copy.txt") == {:ok, "three"}

        assert {:ok, _} = Fil.rename(ref, "forms-renamed.txt")
        assert Fil.read(disk, "forms-renamed.txt") == {:ok, "three"}

        assert Fil.exists?(Fil.ref(disk, "forms-renamed.txt"))
        assert {:ok, %Fil.Stat{}} = Fil.stat(Fil.ref(disk, "forms-copy.txt"))
        assert {:ok, _} = Fil.ls(Fil.ref(disk, "."))
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

      test "bang variants raise Fil.Error", %{disk: disk} do
        error = assert_raise(Fil.Error, fn -> Fil.read!(disk, "nope.txt") end)

        assert error.reason == :enoent
        assert error.op == :read
        assert error.path == "nope.txt"
        assert error.adapter == Fil.Disk.adapter(disk)
        assert error.message =~ "could not read"
        assert error.message =~ "nope.txt"
        assert error.message =~ inspect(Fil.Disk.adapter(disk))

        assert_raise Fil.Error, fn -> Fil.read!(Fil.ref(disk, "../escape.txt")) end
        assert_raise Fil.Error, fn -> Fil.stat!(disk, "nope.txt") end
        assert_raise Fil.Error, fn -> Fil.cp!(disk, "nope.txt", "target.txt") end
      end
    end
  end
end
