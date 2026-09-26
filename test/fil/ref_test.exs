defmodule Fil.RefTest do
  alias Fil.Adapter.Local
  alias Fil.Adapter.S3

  use ExUnit.Case, async: true

  setup do
    {:ok, disk: Fil.disk(adapter: Local, root: "/tmp/fil")}
  end

  describe "inspect" do
    test "redacts S3 credentials" do
      disk =
        Fil.disk(
          adapter: S3,
          bucket: "secrets",
          access_key_id: "AKIAIOSFODNN7EXAMPLE",
          secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
          session_token: "FwoGZXIvYXdzEBYaDNZ"
        )

      ref = Fil.ref(disk, "cv.pdf")

      assert inspect(ref) == "#Fil.Ref<s3:cv.pdf>"
      assert inspect(disk) == "#Fil.Disk<s3>"

      for output <- [inspect(ref), inspect(disk), inspect(%{ref: ref})] do
        refute output =~ "wJalrXUtnFEMI"
        refute output =~ "AKIAIOSFODNN7EXAMPLE"
        refute output =~ "FwoGZXIvYXdzEBYaDNZ"
      end
    end

    test "even the adapter state hides its secrets" do
      {:ok, state} =
        S3.init(
          bucket: "secrets",
          access_key_id: "AKIAIOSFODNN7EXAMPLE",
          secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
        )

      output = inspect(state)

      assert output =~ "secrets"
      refute output =~ "wJalrXUtnFEMI"
      refute output =~ "AKIAIOSFODNN7EXAMPLE"
    end
  end

  describe "the stat snapshot" do
    test "is dropped when a ref is used as an input", %{disk: disk} do
      snapshot = %Fil.Ref{disk: disk, path: "a.txt", stat: %Fil.Stat{size: 1}}

      assert {:ok, ref} = Fil.Ref.normalize(snapshot)
      assert ref.stat == nil
      assert ref == Fil.ref(disk, "a.txt")
    end

    test "is not part of what makes two refs the same file", %{disk: disk} do
      snapshot = %Fil.Ref{disk: disk, path: "a.txt", stat: %Fil.Stat{size: 1}}
      plain = Fil.ref(disk, "a.txt")

      refute snapshot == plain
      assert {snapshot.disk, snapshot.path} == {plain.disk, plain.path}
    end
  end
end
