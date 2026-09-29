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
  alias Phoenix.LiveView.UploadEntry

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

  # The smallest part size S3 allows, so the conformance suite's large streams (`Fil.AdapterCase.large/0`) are
  # uploaded in parts.
  def fil_disk(%{bucket: bucket}) do
    Fil.disk(
      [adapter: S3, bucket: bucket, endpoint: Emulator.url(:s3), path_style: true, part_size: 5_242_880] ++
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

    test "presigns an upload bound to its content type, size and if_exists", %{disk: disk} do
      opts = [method: :put, content_type: "image/png", size: 3, if_exists: :error, expires_in: 60]
      assert {:ok, url} = Fil.signed_url(disk, "avatars/a.png", opts)
      headers = [{"content-type", "image/png"}, {"if-none-match", "*"}]

      # The signature covers the headers, so another content type or length, or a missing header, is refused.
      assert {:ok, %{status: 403}} =
               put(url, "png", List.keyreplace(headers, "content-type", 0, {"content-type", "a/b"}))

      assert {:ok, %{status: 403}} = put(url, "pngs", headers)
      assert {:ok, %{status: 403}} = put(url, "png", List.keydelete(headers, "if-none-match", 0))
      refute Fil.exists?(disk, "avatars/a.png")

      assert {:ok, %{status: 200}} = put(url, "png", headers)
      assert {:ok, %Fil.Stat{size: 3, content_type: "image/png"}} = Fil.stat(disk, "avatars/a.png")

      # With `if-none-match: *`, the URL writes the file once.
      assert {:ok, %{status: 412}} = put(url, "new", headers)
      assert Fil.read(disk, "avatars/a.png") == {:ok, "png"}
    end

    test "Fil.LiveView uploads a file directly and consumes it", %{disk: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "Me.PNG", client_size: 3, upload_config: :avatar}
      socket = Phoenix.LiveView.allow_upload(%Phoenix.LiveView.Socket{}, :avatar, accept: ~w(.png))

      assert {:ok, meta, _socket} = Fil.LiveView.external(disk, path: &"avatars/#{&1.uuid}.png").(entry, socket)
      assert {:ok, %{status: 200}} = put(meta.url, "png", Map.to_list(meta.headers))

      assert {:ok, avatar} = Fil.LiveView.store_entry(disk, meta, entry, max_file_size: 3)
      assert avatar.path == "avatars/0b2e8b8e.png"
      assert Fil.read(avatar) == {:ok, "png"}

      # A file from before its URL isn't the upload's: a URL signed a minute after the object was written refuses it
      # and leaves it there.
      later = %{meta | signed_at: meta.signed_at + 60}

      assert {:error, %Fil.AlreadyExistsError{reason: :before_upload}} =
               Fil.LiveView.store_entry(disk, later, entry, max_file_size: 3)

      assert Fil.read(avatar) == {:ok, "png"}
    end
  end

  describe "uploads in parts" do
    test "complete with the content type, and an ETag that counts the parts", %{disk: disk} do
      content = :crypto.strong_rand_bytes(large())

      assert {:ok, _} = Fil.write(disk, "video.mp4", chunked(content, 65_536), content_type: "video/mp4")
      assert {:ok, %Fil.Stat{content_type: "video/mp4", etag: etag}} = Fil.stat(disk, "video.mp4")
      assert String.ends_with?(etag, "-2")
    end

    test "a failed upload leaves no upload behind", %{disk: disk, bucket: bucket} do
      broken = then_run(large_chunks(), fn -> raise "broken" end)

      assert_raise RuntimeError, "broken", fn -> Fil.write(disk, "broken.bin", broken) end
      assert Emulator.list_s3_uploads(bucket) == {:ok, []}

      assert {:ok, _} = Fil.write(disk, "exists.bin", "first")

      assert {:error, %Fil.AlreadyExistsError{}} =
               Fil.write(disk, "exists.bin", large_chunks(), if_exists: :error)

      assert Emulator.list_s3_uploads(bucket) == {:ok, []}
    end

    test "the upload of a killed writer is aborted", %{disk: disk, bucket: bucket} do
      test = self()

      blocking =
        then_run(large_chunks(), fn ->
          send(test, :blocked)
          Process.sleep(:infinity)
        end)

      writer = spawn(fn -> Fil.write(disk, "killed.bin", blocking) end)

      assert_receive :blocked, 10_000
      assert {:ok, [{"killed.bin", _upload_id}]} = Emulator.list_s3_uploads(bucket)

      Process.exit(writer, :kill)

      assert eventually(fn -> Emulator.list_s3_uploads(bucket) == {:ok, []} end)
      refute Fil.exists?(disk, "killed.bin")
    end

    test "a SHA-256 of an upload in parts covers the parts", %{disk: disk} do
      content = :crypto.strong_rand_bytes(large())

      assert {:ok, _} = Fil.write(disk, "sha.bin", chunked(content, 65_536), checksum: :sha256)

      # S3 stores a checksum of the parts' checksums, which isn't the checksum of the file.
      assert {:ok, %Fil.Stat{checksum: nil}} = Fil.stat(disk, "sha.bin", checksum: :sha256)
      assert Fil.read(disk, "sha.bin", verify_checksum: true) == {:ok, content}

      assert disk
             |> Fil.stream!("sha.bin", verify_checksum: true)
             |> Enum.join() == content
    end
  end

  defp large_chunks do
    "a"
    |> :binary.copy(large())
    |> chunked(65_536)
  end

  # `chunks`, then a chunk that runs `fun`.
  defp then_run(chunks, fun), do: Stream.concat(chunks, Stream.map([:next], fn _next -> fun.() end))

  # Polls `fun` every 50 ms for up to 2 seconds.
  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() ->
        true

      attempts > 1 ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      true ->
        false
    end
  end

  defp get(url), do: Req.request(method: :get, url: url, retry: false, raw: true)

  defp put(url, body, headers \\ []) do
    Req.request(method: :put, url: url, body: body, headers: headers, retry: false, raw: true)
  end
end
