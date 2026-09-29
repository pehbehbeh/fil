defmodule Fil.DiskTest do
  use ExUnit.Case, async: true

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
