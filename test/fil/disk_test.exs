defmodule Fil.DiskTest do
  use ExUnit.Case, async: true

  # An adapter without `address/1`, which only needs `init/1` to build a disk.
  defmodule Unaddressed do
    def init(opts), do: {:ok, Map.new(opts)}
  end

  describe "same_storage?/2" do
    test "compares the whole state of an adapter without address/1" do
      disk = Fil.disk(adapter: Unaddressed, bucket: "b", token: "old")

      assert Fil.Disk.same_storage?(disk, Fil.disk(adapter: Unaddressed, bucket: "b", token: "old"))
      refute Fil.Disk.same_storage?(disk, Fil.disk(adapter: Unaddressed, bucket: "b", token: "new"))
    end

    test "is false for disks of different adapters" do
      local = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")

      refute Fil.Disk.same_storage?(local, Fil.disk(adapter: Fil.Adapter.Memory, root: "/tmp/fil"))
    end
  end

  describe "resolve/1" do
    test "raises when the function returns something else" do
      assert_raise ArgumentError, ~r/to return a Fil.Disk, got: :nope/, fn -> Fil.Disk.resolve(fn -> :nope end) end
    end

    test "raises when the MFA returns something else" do
      assert_raise ArgumentError, ~r/expected {Function, :identity, \[:nope\]} to return a Fil.Disk/, fn ->
        Fil.Disk.resolve({Function, :identity, [:nope]})
      end
    end

    test "raises for anything that isn't a disk, a function or an MFA" do
      assert_raise ArgumentError, ~r/got: :uploads/, fn -> Fil.Disk.resolve(:uploads) end
    end
  end
end
