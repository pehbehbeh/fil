defmodule Fil.Adapter.S3IntegrationTest do
  @moduledoc """
  Runs the conformance suite against RustFS. RustFS verifies SigV4 signatures, so this also tests the request signing
  and the presigned URLs end to end: `fil_request/4` sends the requests of the signed URL tests to RustFS with Req.

      docker compose up -d rustfs
      mix test.integration

  Each run creates its own bucket in `setup_all` and removes it at the end, so the container can stay up between runs.
  Each test gets a root of its own in that bucket, so it starts empty whatever the tests before it left behind.
  `FIL_S3_ENDPOINT`, `FIL_S3_ACCESS_KEY_ID`, `FIL_S3_SECRET_ACCESS_KEY` and `FIL_S3_REGION` point the suite at another
  S3 endpoint, AWS included.
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

  # The smallest part size S3 allows, so the conformance suite's large streams (`Fil.AdapterCase.large/0`) are
  # uploaded in parts.
  def fil_disk(%{bucket: bucket} = context) do
    Fil.disk(
      [
        adapter: S3,
        bucket: bucket,
        root: root(context),
        endpoint: Emulator.url(:s3),
        path_style: true,
        part_size: 5_242_880
      ] ++ Emulator.s3_credentials()
    )
  end

  # Sends the requests of the conformance suite's signed URL tests to RustFS.
  def fil_request(_disk, method, url, opts) do
    {:ok, response} =
      Req.request(
        method: method,
        url: url,
        body: Keyword.get(opts, :body),
        headers: Keyword.get(opts, :headers, []),
        retry: false,
        raw: true
      )

    headers = for {name, values} <- response.headers, value <- values, do: {name, value}
    {response.status, headers, response.body}
  end

  # The test's own root in the run's bucket. It's derived from the test name, because the conformance suite calls
  # `fil_disk/1` in its `setup` and again in a test, and both calls have to return the same disk.
  defp root(%{test: test}), do: "t#{:erlang.phash2(test, 4_294_967_296)}"

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
    test "signs URLs for the public endpoint", %{disk: disk, bucket: bucket} = context do
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
          [
            adapter: S3,
            bucket: bucket,
            root: root(context),
            endpoint: Emulator.url(:s3),
            public_endpoint: public_endpoint
          ] ++ Emulator.s3_credentials()
        )

      assert {:ok, url} = Fil.signed_url(public, "a b/ü.txt", disposition: :attachment)
      assert URI.parse(url).host == public_host
      assert {:ok, %{status: 200, body: "public"}} = get(url)
      assert {:ok, %{status: 403}} = get(String.replace(url, public_host, endpoint.host))

      assert {:ok, put_url} = Fil.signed_url(public, "a b/ü.txt", method: :put)
      assert {:ok, %{status: 200}} = put(put_url, "changed")
      assert Fil.read(disk, "a b/ü.txt") == {:ok, "changed"}
    end

    test "presigns an upload bound to if-none-match, and answers 412 the second time", %{disk: disk} do
      opts = [method: :put, content_type: "image/png", size: 3, if_exists: :error, expires_in: 60]
      assert {:ok, url} = Fil.signed_url(disk, "avatars/a.png", opts)
      headers = [{"content-type", "image/png"}, {"if-none-match", "*"}]

      # The signature covers the header, so a request without it is refused.
      assert {:ok, %{status: 403}} = put(url, "png", List.keydelete(headers, "if-none-match", 0))
      refute Fil.exists?(disk, "avatars/a.png")

      assert {:ok, %{status: 200}} = put(url, "png", headers)
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

    test "a failed upload leaves no upload behind", %{disk: disk} = context do
      broken = then_run(large_chunks(), fn -> raise "broken" end)

      assert_raise RuntimeError, "broken", fn -> Fil.write(disk, "broken.bin", broken) end
      assert uploads(context) == []

      assert {:ok, _} = Fil.write(disk, "exists.bin", "first")

      assert {:error, %Fil.AlreadyExistsError{}} =
               Fil.write(disk, "exists.bin", large_chunks(), if_exists: :error)

      assert uploads(context) == []
    end

    test "the upload of a killed writer is aborted", %{disk: disk} = context do
      test = self()

      blocking =
        then_run(large_chunks(), fn ->
          send(test, :blocked)
          Process.sleep(:infinity)
        end)

      writer = spawn(fn -> Fil.write(disk, "killed.bin", blocking) end)

      assert_receive :blocked, 10_000
      assert uploads(context) == ["killed.bin"]

      Process.exit(writer, :kill)

      assert eventually(fn -> uploads(context) == [] end)
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

  # The paths of the multipart uploads under the test's root that were neither completed nor aborted. The bucket holds
  # the uploads of every test in the run.
  defp uploads(%{bucket: bucket} = context) do
    prefix = root(context) <> "/"
    {:ok, uploads} = Emulator.list_s3_uploads(bucket)

    for {key, _upload_id} <- uploads, String.starts_with?(key, prefix), do: String.replace_prefix(key, prefix, "")
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
