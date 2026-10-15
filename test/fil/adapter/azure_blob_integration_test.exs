defmodule Fil.Adapter.AzureBlobIntegrationTest do
  @moduledoc """
  Runs the conformance suite against Azurite. Azurite verifies Shared Key and SAS signatures, so this also tests the
  request signing and the signed URLs end to end: `fil_request/4` sends the requests of the signed URL tests to Azurite
  with Req.

      docker compose up -d azurite
      mix test.integration

  Each run creates its own container in `setup_all` and removes it at the end. Each test gets a root of its own in that
  container. `FIL_AZURE_BLOB_ENDPOINT`, `FIL_AZURE_BLOB_ACCOUNT` and `FIL_AZURE_BLOB_ACCOUNT_KEY` point the suite at
  another account, Azure included.
  """

  alias Fil.Adapter.AzureBlob
  alias Fil.AdapterCase
  alias Fil.Emulator
  alias Phoenix.LiveView.UploadEntry

  use Fil.AdapterCase, async: false, tags: [:integration]

  setup_all do
    Emulator.require!(:azure_blob)

    container = Emulator.unique_name("fil")
    :ok = Emulator.create_azure_container(container)

    on_exit(fn -> Emulator.delete_azure_container(container) end)

    {:ok, container: container}
  end

  # The smallest block size, so the conformance suite's large streams (`Fil.AdapterCase.large/0`) are uploaded in
  # blocks.
  def fil_disk(%{container: container} = context) do
    Fil.disk(
      [
        adapter: AzureBlob,
        container: container,
        root: root(context),
        endpoint: Emulator.url(:azure_blob),
        block_size: 1_048_576
      ] ++ Emulator.azure_blob_credentials()
    )
  end

  # Sends the requests of the conformance suite's signed URL tests to Azurite.
  defdelegate fil_request(disk, method, url, opts), to: Fil.AdapterCase, as: :req_request

  # The test's own root in the run's container, derived from the test name, so `fil_disk/1` returns the same disk each
  # time it's called.
  defp root(%{test: test}), do: "t#{:erlang.phash2(test, 4_294_967_296)}"

  describe "signatures" do
    test "a disk with the wrong key is refused", %{container: container} do
      disk =
        Fil.disk(
          adapter: AzureBlob,
          container: container,
          endpoint: Emulator.url(:azure_blob),
          account: Emulator.azure_blob_credentials()[:account],
          account_key: Base.encode64("wrong")
        )

      assert {:error, %Fil.AccessDeniedError{reason: "AuthorizationFailure"}} = Fil.write(disk, "a.txt", "content")
    end

    test "a disk with a SAS token reads and writes without the key", %{disk: disk, container: container} = context do
      assert {:ok, _} = Fil.write(disk, "a b/ü.txt", "content")

      token = container_sas(container, "rwdl")

      sas_disk =
        Fil.disk(
          adapter: AzureBlob,
          container: container,
          root: root(context),
          endpoint: Emulator.url(:azure_blob),
          account: Emulator.azure_blob_credentials()[:account],
          sas_token: "?" <> token
        )

      assert Fil.read(sas_disk, "a b/ü.txt") == {:ok, "content"}
      assert {:ok, _} = Fil.cp(sas_disk, "a b/ü.txt", "copy.txt")
      assert Fil.read(disk, "copy.txt") == {:ok, "content"}
      assert {:error, %Fil.UnsupportedError{reason: :missing_credentials}} = Fil.signed_url(sas_disk, "copy.txt")
    end
  end

  describe "signed uploads" do
    test "with if_exists: :error, a second upload is refused by the SAS permission alone", %{disk: disk} do
      assert {:ok, upload} = Fil.signed_upload(disk, "a.png", content_type: "image/png", if_exists: :error)
      assert {:ok, %{status: 201}} = put(upload.url, "png", Map.to_list(upload.headers))

      headers =
        upload.headers
        |> Map.delete("if-none-match")
        |> Map.to_list()

      assert {:ok, %{status: status}} = put(upload.url, "new", headers)
      assert status in 400..499
      assert Fil.read(disk, "a.png") == {:ok, "png"}
    end

    test "Azure takes another content type and size than the upload was signed for", %{disk: disk} do
      assert {:ok, upload} = Fil.signed_upload(disk, "a.png", content_type: "image/png", size: 3)

      assert {:ok, %{status: 201}} =
               put(upload.url, "<html>", [{"x-ms-blob-type", "BlockBlob"}, {"content-type", "text/html"}])

      assert {:ok, %Fil.Stat{size: 6, content_type: "text/html"}} = Fil.stat(disk, "a.png")
    end

    test "Fil.LiveView uploads a file directly, and refuses one with another content type", %{disk: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "Me.PNG", client_size: 3, upload_config: :avatar}
      socket = Phoenix.LiveView.allow_upload(%Phoenix.LiveView.Socket{}, :avatar, accept: ~w(.png))
      external = Fil.LiveView.external(disk, path: &"avatars/#{&1.uuid}.png")

      assert {:ok, meta, _socket} = external.(entry, socket)
      assert {:ok, %{status: 201}} = put(meta.url, "png", Map.to_list(meta.headers))
      assert {:ok, avatar} = Fil.LiveView.store_entry(disk, meta, entry, max_file_size: 3)
      assert Fil.read(avatar) == {:ok, "png"}

      other = %{entry | uuid: "5c1d"}
      assert {:ok, meta, _socket} = external.(other, socket)
      headers = Map.put(meta.headers, "content-type", "text/html")
      assert {:ok, %{status: 201}} = put(meta.url, "png", Map.to_list(headers))

      assert {:error, %Fil.InvalidRequestError{reason: :content_type}} =
               Fil.LiveView.store_entry(disk, meta, other, max_file_size: 3)
    end
  end

  describe "uploads in blocks" do
    test "commit with the content type and the checksum of the whole file", %{disk: disk} do
      content = :crypto.strong_rand_bytes(AdapterCase.large())

      assert {:ok, _} =
               Fil.write(disk, "video.mp4", AdapterCase.chunked(content, 65_536),
                 content_type: "video/mp4",
                 checksum: :sha256
               )

      sha256 = Fil.Support.Checksum.digest(:sha256, content)

      assert {:ok, %Fil.Stat{content_type: "video/mp4", size: size, checksum: {:sha256, ^sha256}}} =
               Fil.stat(disk, "video.mp4", checksum: :sha256)

      assert size == byte_size(content)
      assert Fil.read(disk, "video.mp4", verify_checksum: true) == {:ok, content}
    end

    test "a failed upload writes nothing", %{disk: disk} do
      broken =
        "a"
        |> :binary.copy(AdapterCase.large())
        |> AdapterCase.chunked(65_536)
        |> Stream.concat(Stream.map([:next], fn _next -> raise "broken" end))

      assert_raise RuntimeError, "broken", fn -> Fil.write(disk, "broken.bin", broken) end
      refute Fil.exists?(disk, "broken.bin")
    end
  end

  # A container SAS, as the portal or `az storage container generate-sas` would make it, signed with Azurite's key.
  defp container_sas(container, permissions) do
    credentials = Emulator.azure_blob_credentials()
    key = Base.decode64!(credentials[:account_key])

    expires =
      DateTime.utc_now()
      |> DateTime.add(3600)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    canonical = "/blob/#{credentials[:account]}/#{container}"

    string_to_sign =
      Enum.join([permissions, "", expires, canonical, "", "", "", "2025-01-05", "c", "", "", "", "", "", "", ""], "\n")

    signature =
      :hmac
      |> :crypto.mac(:sha256, key, string_to_sign)
      |> Base.encode64()

    URI.encode_query([{"sv", "2025-01-05"}, {"se", expires}, {"sr", "c"}, {"sp", permissions}, {"sig", signature}])
  end

  defp put(url, body, headers) do
    Req.request(method: :put, url: url, body: body, headers: headers, retry: false, raw: true)
  end
end
