defmodule Fil.DiskTest do
  use ExUnit.Case, async: true

  # An adapter without `address/1`, which only needs `init/1` to build a disk.
  defmodule Unaddressed do
    def init(opts), do: {:ok, Map.new(opts)}
  end

  describe "the :signed_url option" do
    setup do
      disk =
        [adapter: Fil.Adapter.Memory, signed_url: [expires_in: 86_400, disposition: :attachment, if_exists: :error]]
        |> Fil.disk()
        |> Fil.Plugin.URL.attach(base_url: "http://localhost/storage", secret: "secret")

      {:ok, disk: disk}
    end

    test "sets the default options of signed_url/3", %{disk: disk} do
      query = signed_query(disk, "reports/q3.pdf")

      assert String.to_integer(query["expires"]) in expiry_range(86_400)
      assert query["disposition"] == ~s(attachment; filename="q3.pdf")
      refute Map.has_key?(query, "if_exists")
    end

    test "is replaced by the options of a call", %{disk: disk} do
      query = signed_query(disk, "q3.pdf", expires_in: 60, disposition: :inline)

      assert String.to_integer(query["expires"]) in expiry_range(60)
      assert query["disposition"] == "inline"
    end

    test "applies to refs of the disk", %{disk: disk} do
      query =
        disk
        |> Fil.ref("q3.pdf")
        |> signed_query()

      assert query["disposition"] == ~s(attachment; filename="q3.pdf")
    end

    test "leaves the disposition out of uploads", %{disk: disk} do
      query = signed_query(disk, "q3.pdf", method: :put)

      assert String.to_integer(query["expires"]) in expiry_range(86_400)
      assert query["if_exists"] == "error"
      refute Map.has_key?(query, "disposition")
    end

    test "doesn't stop a call's disposition on an upload from raising", %{disk: disk} do
      assert_raise ArgumentError, ~r/only applies to downloads/, fn ->
        Fil.signed_url(disk, "q3.pdf", method: :put, disposition: :inline)
      end
    end

    test "doesn't stop a call's if_exists on a download from raising", %{disk: disk} do
      assert_raise ArgumentError, ~r/only applies to uploads/, fn ->
        Fil.signed_url(disk, "q3.pdf", if_exists: :error)
      end
    end

    test "raises on options a disk can't set" do
      for signed_url <- [[method: :put], [disposition: {:attachment, "a.pdf"}], [query: []], [expires_in: 0]] do
        assert_raise ArgumentError, ~r/signed_url/, fn ->
          Fil.disk(adapter: Fil.Adapter.Memory, signed_url: signed_url)
        end
      end
    end
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

  defp signed_query(disk, path, opts),
    do:
      disk
      |> Fil.ref(path)
      |> signed_query(opts)

  defp signed_query(ref, opts \\ []) do
    ref
    |> Fil.signed_url!(opts)
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
  end

  defp expiry_range(expires_in) do
    expires = System.os_time(:second) + expires_in
    (expires - 10)..expires
  end
end
