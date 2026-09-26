defmodule Fil.Adapter.S3IntegrationTest do
  @moduledoc """
  Runs the conformance suite against SeaweedFS. SeaweedFS verifies SigV4 signatures, so this also tests the request
  signing end to end.

      docker compose up -d seaweedfs
      mix test.integration

  Each run creates its own bucket in `setup_all`, recreates it before every test and removes it at the end, so the
  container can stay up between runs. `FIL_S3_ENDPOINT`, `FIL_S3_ACCESS_KEY_ID`, `FIL_S3_SECRET_ACCESS_KEY` and
  `FIL_S3_REGION` point the suite at another S3 endpoint, AWS included.
  """

  # SeaweedFS answers a second `If-None-Match: *` PUT with 200 instead of refusing it, so the `if_exists: :error` test
  # can't pass here. It also accepts `x-amz-checksum-*` on a PUT but returns no stored checksum from HeadObject, and
  # it answers a DeleteObject on a prefix with a 500, because it stores prefixes as real directories. The unit tests
  # cover the requests `Fil` sends, and AWS handles all three.
  alias Fil.Adapter.S3
  alias Fil.Emulator

  use Fil.AdapterCase, async: false, tags: [:integration], unsupported: [:if_exists, :checksum, :rm_directory]

  setup_all do
    Emulator.require!(:s3)

    bucket = Emulator.unique_name("fil")
    :ok = Emulator.create_s3_bucket(bucket)

    on_exit(fn -> Emulator.delete_s3_bucket(bucket) end)

    {:ok, bucket: bucket}
  end

  # SeaweedFS is filer-backed, so emptying a bucket leaves its directories behind and they'd show up in the listing
  # tests. Recreating the bucket is cheap and gives every test an empty one.
  setup %{bucket: bucket} do
    :ok = Emulator.delete_s3_bucket(bucket)
    :ok = Emulator.create_s3_bucket(bucket)
    :ok
  end

  def fil_disk(%{bucket: bucket}) do
    Fil.disk(
      [adapter: S3, bucket: bucket, endpoint: Emulator.url(:s3), path_style: true] ++
        Emulator.s3_credentials()
    )
  end

  describe "signatures" do
    test "a disk with the wrong secret is refused", %{bucket: bucket} do
      disk =
        Fil.disk(
          adapter: S3,
          bucket: bucket,
          endpoint: Emulator.url(:s3),
          path_style: true,
          region: Emulator.s3_credentials()[:region],
          access_key_id: Emulator.s3_credentials()[:access_key_id],
          secret_access_key: "not-the-secret"
        )

      assert {:error, error} = Fil.read(disk, "nope.txt")
      refute match?(%Fil.NotFoundError{}, error), "SeaweedFS accepted a request signed with the wrong secret"
    end
  end

  describe "signed_url/2" do
    test "returns a URL that works", %{disk: disk} do
      Fil.write!(disk, "signed.txt", "World")

      assert {:ok, url} = Fil.signed_url(disk, "signed.txt", expires_in: 60)
      assert {:ok, %{status: 200, body: "World"}} = get(url)
    end

    test "presigns an upload", %{disk: disk} do
      assert {:ok, url} = Fil.signed_url(disk, "uploaded.txt", method: :put, expires_in: 60)
      assert {:ok, %{status: status}} = put(url, "Uploaded")
      assert status in [200, 201]
      assert Fil.read(disk, "uploaded.txt") == {:ok, "Uploaded"}
    end
  end

  defp get(url), do: Req.request(method: :get, url: url, retry: false, raw: true)

  defp put(url, body) do
    Req.request(method: :put, url: url, body: body, retry: false, raw: true)
  end
end
