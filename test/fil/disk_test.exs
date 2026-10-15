defmodule Fil.DiskTest do
  use ExUnit.Case, async: true

  # An adapter without `address/1`, which only needs `init/1` to build a disk.
  defmodule Unaddressed do
    def init(opts), do: {:ok, Map.new(opts)}
  end

  describe "the :signed_url and :signed_upload options" do
    setup do
      disk =
        [
          adapter: Fil.Adapter.Memory,
          signed_url: [expires_in: 86_400, disposition: :attachment],
          signed_upload: [expires_in: 600, if_exists: :error]
        ]
        |> Fil.disk()
        |> Fil.Plugin.URL.attach(base_url: "http://localhost/storage", secret: "secret")

      {:ok, disk: disk}
    end

    test "set the default options of signed_url/3", %{disk: disk} do
      query = signed_query(disk, "reports/q3.pdf")

      assert String.to_integer(query["expires"]) in expiry_range(86_400)
      assert query["disposition"] == ~s(attachment; filename="q3.pdf")
      refute Map.has_key?(query, "if_exists")
    end

    test "are replaced by the options of a call", %{disk: disk} do
      query = signed_query(disk, "q3.pdf", expires_in: 60, disposition: :inline)

      assert String.to_integer(query["expires"]) in expiry_range(60)
      assert query["disposition"] == "inline"

      refute disk
             |> upload_query("q3.pdf", if_exists: :overwrite)
             |> Map.has_key?("if_exists")
    end

    test "apply to refs of the disk", %{disk: disk} do
      query =
        disk
        |> Fil.ref("q3.pdf")
        |> signed_query()

      assert query["disposition"] == ~s(attachment; filename="q3.pdf")
    end

    test "set the default options of signed_upload/3", %{disk: disk} do
      query = upload_query(disk, "q3.pdf")

      assert String.to_integer(query["expires"]) in expiry_range(600)
      assert query["if_exists"] == "error"
      refute Map.has_key?(query, "disposition")
    end

    test "raise on options a disk can't set" do
      for signed_url <- [[if_exists: :error], [disposition: {:attachment, "a.pdf"}], [query: []], [expires_in: 0]] do
        assert_raise ArgumentError, ~r/signed_url/, fn ->
          Fil.disk(adapter: Fil.Adapter.Memory, signed_url: signed_url)
        end
      end

      for signed_upload <- [[disposition: :inline], [content_type: "image/png"], [size: 1], [expires_in: 0]] do
        assert_raise ArgumentError, ~r/signed_upload/, fn ->
          Fil.disk(adapter: Fil.Adapter.Memory, signed_upload: signed_upload)
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

  defp upload_query(disk, path, opts \\ []) do
    %Fil.SignedUpload{url: url} = Fil.signed_upload!(disk, path, opts)

    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
  end

  defp expiry_range(expires_in) do
    expires = System.os_time(:second) + expires_in
    (expires - 10)..expires
  end
end
