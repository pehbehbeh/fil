defmodule Fil.Adapter.S3IntegrationTest do
  @moduledoc """
  Runs the conformance suite against RustFS. RustFS verifies SigV4 signatures, so this also tests the request signing
  end to end.

      docker compose up -d rustfs
      mix test.integration

  Each run creates its own bucket in `setup_all`, recreates it before every test and removes it at the end, so the
  container can stay up between runs. `FIL_S3_ENDPOINT`, `FIL_S3_ACCESS_KEY_ID`, `FIL_S3_SECRET_ACCESS_KEY` and
  `FIL_S3_REGION` point the suite at another S3 endpoint, AWS included.
  """

  alias Fil.Adapter.S3
  alias Fil.Emulator

  use Fil.AdapterCase, async: false, tags: [:integration]

  setup_all do
    Emulator.require!(:s3)

    bucket = Emulator.unique_name("fil")
    :ok = Emulator.create_s3_bucket(bucket)

    on_exit(fn -> Emulator.delete_s3_bucket(bucket) end)

    {:ok, bucket: bucket}
  end

  # Recreating the bucket is cheap and gives every test an empty one, whatever the test before it left behind.
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

      assert {:error, %Fil.AccessDeniedError{reason: "SignatureDoesNotMatch"}} = Fil.read(disk, "nope.txt")
    end
  end

  describe "signed_url/2" do
    test "returns a URL that works", %{disk: disk} do
      Fil.write!(disk, "signed.txt", "World")

      assert {:ok, url} = Fil.signed_url(disk, "signed.txt", expires_in: 60)
      assert {:ok, %{status: 200, body: "World"}} = get(url)
    end

    test "returns a URL that downloads with the signed disposition", %{disk: disk} do
      Fil.write!(disk, "7f3a.pdf", "PDF")

      assert {:ok, url} = Fil.signed_url(disk, "7f3a.pdf", disposition: {:attachment, "Rechnung März.pdf"})
      assert {:ok, %{status: 200, body: "PDF"} = response} = get(url)

      assert Req.Response.get_header(response, "content-disposition") == [
               ~s(attachment; filename="Rechnung M_rz.pdf"; filename*=UTF-8''Rechnung%20M%C3%A4rz.pdf)
             ]
    end

    test "returns a URL with signed query parameters that works", %{disk: disk} do
      Fil.write!(disk, "index.html", "<html>")

      assert {:ok, url} = Fil.signed_url(disk, "index.html", query: [{"trackingInfo", "7-42-a b"}])
      assert {:ok, %{status: 200, body: "<html>"}} = get(url)
      assert {:ok, %{status: 403}} = get(String.replace(url, "trackingInfo=7", "trackingInfo=8"))
    end

    test "signs URLs for the public endpoint", %{disk: disk, bucket: bucket} do
      Fil.write!(disk, "a b/ü.txt", "public")

      # The emulator answers on 127.0.0.1 and on localhost, so one serves as the endpoint and the other as the public
      # endpoint. The signature covers the host, so the URL fails on the other one.
      endpoint =
        :s3
        |> Emulator.url()
        |> URI.parse()

      public_host = if endpoint.host == "localhost", do: "127.0.0.1", else: "localhost"
      public_endpoint = URI.to_string(%{endpoint | host: public_host})

      public =
        Fil.disk(
          [adapter: S3, bucket: bucket, endpoint: Emulator.url(:s3), public_endpoint: public_endpoint] ++
            Emulator.s3_credentials()
        )

      assert {:ok, url} = Fil.signed_url(public, "a b/ü.txt", disposition: :attachment)
      assert URI.parse(url).host == public_host
      assert {:ok, %{status: 200, body: "public"}} = get(url)
      assert {:ok, %{status: 403}} = get(String.replace(url, public_host, endpoint.host))

      assert {:ok, put_url} = Fil.signed_url(public, "a b/ü.txt", method: :put)
      assert {:ok, %{status: 200}} = put(put_url, "changed")
      assert Fil.read(disk, "a b/ü.txt") == {:ok, "changed"}
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
