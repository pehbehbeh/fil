defmodule Fil.Adapter.AzureBlobTest do
  alias Fil.Adapter.AzureBlob
  alias Fil.AdapterCase
  alias Fil.ReqStub
  alias Fil.Support.Checksum

  use ExUnit.Case, async: true

  setup {Req.Test, :verify_on_exit!}

  @mib 1_048_576

  # Azurite's well-known development key, so a failing signature can be checked against Azurite by hand.
  @account_key "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="

  describe "same storage" do
    test "compares endpoint, container and prefix, not how the storage is reached" do
      base = [adapter: AzureBlob, account: "acct", container: "c", root: "uploads"]
      uploads = Fil.disk(base)

      reached_otherwise = [
        account_key: @account_key,
        public_endpoint: "http://localhost:10000/acct",
        block_size: 2 * @mib,
        req_options: [receive_timeout: 1_000]
      ]

      for {key, value} <- reached_otherwise do
        assert Fil.Disk.same_storage?(uploads, Fil.disk([{key, value} | base])), "#{key} changed the storage"
      end

      addressing = [container: "d", endpoint: "http://localhost:10000/acct", root: "other"]

      for {key, value} <- addressing do
        refute Fil.Disk.same_storage?(uploads, Fil.disk(Keyword.put(base, key, value))), "#{key} kept the storage"
      end
    end
  end

  describe "init/1" do
    test "requires an account and a container" do
      assert_raise ArgumentError, ~r/required :account option not found/, fn ->
        Fil.disk(adapter: AzureBlob, container: "c")
      end

      assert_raise ArgumentError, ~r/required :container option not found/, fn ->
        Fil.disk(adapter: AzureBlob, account: "acct")
      end
    end

    test "rejects a key that isn't base64, and a key with a SAS token" do
      assert_raise ArgumentError, ~r/isn't base64/, fn ->
        Fil.disk(adapter: AzureBlob, account: "acct", container: "c", account_key: "not base64!")
      end

      assert_raise ArgumentError, ~r/can't be combined/, fn ->
        Fil.disk(adapter: AzureBlob, account: "acct", container: "c", account_key: @account_key, sas_token: "sv=1")
      end
    end

    test "defaults the endpoint to the account's blob service" do
      {:ok, state} = AzureBlob.init(account: "acct", container: "c")

      assert state.endpoint == "https://acct.blob.core.windows.net"
      assert state.prefix == ""
    end

    test "rejects an endpoint that is not a URL" do
      assert_raise ArgumentError, ~r/invalid_option/, fn ->
        Fil.disk(adapter: AzureBlob, account: "acct", container: "c", endpoint: "localhost:10000")
      end
    end

    test "keeps the key out of inspect" do
      refute inspect(Fil.disk(adapter: AzureBlob, account: "acct", container: "c", account_key: @account_key)) =~
               "Eby8"
    end
  end

  describe "requests" do
    test "are signed with Shared Key, with the version and the date" do
      stub([response(200, "content")])

      uploads = disk(root: "uploads")
      assert Fil.read(uploads, "a b/ü.txt") == {:ok, "content"}

      request = request!()
      assert request.method == "GET"
      assert request.request_path == "/c/uploads/a%20b/%C3%BC.txt"
      assert header(request, "x-ms-version") == "2025-01-05"
      assert header(request, "x-ms-date") =~ ~r/^\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/
      assert header(request, "authorization") =~ ~r"^SharedKey acct:[A-Za-z0-9+/]{43}=$"
    end

    test "with a SAS token carry it instead of a signature" do
      stub([response(200, "content")])
      disk = disk(account_key: nil, sas_token: "?sv=2025-01-05&sp=r&sig=abc%2B")

      assert Fil.read(disk, "a.txt") == {:ok, "content"}

      request = request!()
      assert header(request, "authorization") == nil
      assert URI.decode_query(request.query_string) == %{"sv" => "2025-01-05", "sp" => "r", "sig" => "abc+"}
    end

    test "go to the endpoint with the container in the path" do
      stub([response(200, "content")])

      azurite = disk(endpoint: "http://127.0.0.1:10000/devstoreaccount1/")
      assert Fil.read(azurite, "a.txt") == {:ok, "content"}
      assert request!().request_path == "/devstoreaccount1/c/a.txt"
    end
  end

  describe "errors" do
    test "map the code of the x-ms-error-code header, also without a body" do
      for {status, code, error} <- [
            {404, "BlobNotFound", Fil.NotFoundError},
            {404, "ContainerNotFound", Fil.ConfigurationError},
            {403, "AuthenticationFailed", Fil.AccessDeniedError},
            {409, "BlobAlreadyExists", Fil.AlreadyExistsError},
            {412, "LeaseIdMissing", Fil.ConflictError},
            {413, "RequestBodyTooLarge", Fil.InvalidRequestError},
            {503, "ServerBusy", Fil.UnavailableError},
            {400, "SomethingNew", Fil.UnknownError}
          ] do
        stub([response(status, "", [{"x-ms-error-code", code}])])

        assert {:error, %^error{reason: ^code}} = Fil.read(disk(), "a.txt")
      end
    end

    test "read the code from the body, and fall back to the status" do
      stub([response(403, error_xml("AuthorizationFailure"))])
      assert {:error, %Fil.AccessDeniedError{reason: "AuthorizationFailure"}} = Fil.read(disk(), "a.txt")

      stub([response(500)])
      assert {:error, %Fil.UnavailableError{reason: {:http_status, 500}}} = Fil.read(disk(), "a.txt")
    end

    test "a failed connection is unavailable" do
      stub([{:error, :econnrefused}])

      assert {:error, %Fil.UnavailableError{reason: :econnrefused}} = Fil.read(disk(), "a.txt")
    end
  end

  describe "write/3" do
    test "puts a block blob with its size, content type and if-none-match" do
      stub([response(201)])

      assert {:ok, _} = Fil.write(disk(), "a.txt", ["con", "tent"], content_type: "text/plain", if_exists: :error)

      request = request!()
      assert request.method == "PUT"
      assert request.assigns.body == "content"
      assert header(request, "x-ms-blob-type") == "BlockBlob"
      assert header(request, "content-length") == "7"
      assert header(request, "content-type") == "text/plain"
      assert header(request, "if-none-match") == "*"
    end

    test "stores the checksum as metadata" do
      stub([response(201)])

      assert {:ok, _} = Fil.write(disk(), "a.txt", "content", checksum: :sha256)
      assert header(request!(), "x-ms-meta-fil_sha256") == Checksum.digest(:sha256, "content")
    end

    test "sends a stream of known size as one Put Blob" do
      stub([response(201)])

      assert {:ok, _} = Fil.write(disk(), "a.txt", Stream.map(["con", "tent"], & &1), size: 7)

      request = request!()
      assert request.assigns.body == "content"
      assert header(request, "content-length") == "7"
      assert request.query_string == ""
    end

    test "a missing container is an error" do
      stub([response(404, "", [{"x-ms-error-code", "ContainerNotFound"}])])

      assert {:error, %Fil.ConfigurationError{reason: "ContainerNotFound"}} = Fil.write(disk(), "a.txt", "content")
    end
  end

  describe "uploads in blocks" do
    test "send each block, then commit them with the content type, the checksum and if-none-match" do
      stub([response(201), response(201), response(201)])
      content = :binary.copy("a", @mib + 1)

      assert {:ok, _} =
               Fil.write(blocks_disk(), "big.bin", AdapterCase.chunked(content, 65_536),
                 content_type: "video/mp4",
                 checksum: :crc32,
                 if_exists: :error
               )

      [first, last, commit] = requests()

      assert query(first)["comp"] == "block"
      assert byte_size(first.assigns.body) == @mib
      assert byte_size(last.assigns.body) == 1
      assert header(first, "if-none-match") == nil

      ids = Enum.map([first, last], &query(&1)["blockid"])

      assert ids
             |> Enum.map(&byte_size/1)
             |> Enum.uniq()
             |> length() == 1

      assert ids
             |> Enum.uniq()
             |> length() == 2

      assert query(commit)["comp"] == "blocklist"
      assert commit.assigns.body =~ "<Latest>#{Enum.at(ids, 0)}</Latest><Latest>#{Enum.at(ids, 1)}</Latest>"
      assert header(commit, "x-ms-blob-content-type") == "video/mp4"
      assert header(commit, "x-ms-meta-fil_crc32") == Checksum.digest(:crc32, content)
      assert header(commit, "if-none-match") == "*"
    end

    test "give every upload block IDs of its own" do
      stub([response(201), response(201), response(201), response(201), response(201), response(201)])
      assert {:ok, _} = Fil.write(blocks_disk(), "big.bin", large_chunks())
      assert {:ok, _} = Fil.write(blocks_disk(), "big.bin", large_chunks())

      [first, _last, _commit, second, _last2, _commit2] = requests()
      refute query(first)["blockid"] == query(second)["blockid"]
    end

    test "content that ends within the first block is one Put Blob" do
      stub([response(201)])

      assert {:ok, _} = Fil.write(blocks_disk(), "small.bin", AdapterCase.chunked("small", 2), checksum: :sha1)

      request = request!()
      assert request.query_string == ""
      assert header(request, "x-ms-meta-fil_sha1") == Checksum.digest(:sha1, "small")
    end

    test "a block that fails with an unavailable error is sent once more" do
      stub([response(503, "", [{"x-ms-error-code", "ServerBusy"}]), response(201), response(201), response(201)])

      assert {:ok, _} = Fil.write(blocks_disk(), "big.bin", large_chunks())
      assert length(requests()) == 4
    end

    test "a stream that raises commits nothing" do
      stub([response(201)])

      raising = Stream.concat(large_chunks(), Stream.map([:next], fn _next -> raise "broken" end))

      assert_raise RuntimeError, "broken", fn -> Fil.write(blocks_disk(), "big.bin", raising) end
      assert [%{query_string: "comp=block" <> _}] = requests()
    end

    test "a stream that needs more blocks than allowed fails before its last block" do
      stub([response(201)])
      disk = put_state(blocks_disk(), max_blocks: 2)

      assert {:error, %Fil.InvalidRequestError{reason: :too_many_parts}} =
               Fil.write(disk, "big.bin", AdapterCase.chunked(:binary.copy("a", 2 * @mib + 1), @mib))

      assert length(requests()) == 1
    end
  end

  describe "read/3" do
    test "sends a range as x-ms-range, and reads a 416 as empty" do
      stub([response(206, "234"), response(416, "", [{"x-ms-error-code", "InvalidRange"}])])

      assert Fil.read(disk(), "digits.txt", offset: 2, length: 3) == {:ok, "234"}
      assert Fil.read(disk(), "digits.txt", offset: 10) == {:ok, ""}

      [first, second] = requests()
      assert header(first, "x-ms-range") == "bytes=2-4"
      assert header(second, "x-ms-range") == "bytes=10-"
    end

    test "verify_checksum: true compares with the stored checksum" do
      checksum = Checksum.digest(:sha256, "content")

      stub([response(200, "content", [{"x-ms-meta-fil_sha256", checksum}])])
      assert Fil.read(disk(), "a.txt", verify_checksum: true) == {:ok, "content"}

      stub([response(200, "changed", [{"x-ms-meta-fil_sha256", checksum}])])

      assert {:error, %Fil.ChecksumMismatchError{reason: :checksum_mismatch}} =
               Fil.read(disk(), "a.txt", verify_checksum: true)

      stub([response(200, "changed")])
      assert Fil.read(disk(), "a.txt", verify_checksum: true) == {:ok, "changed"}
    end
  end

  describe "stream/2" do
    test "checks the blob, then downloads it in its own process when read" do
      stub([response(200, "", [{"content-length", "7"}]), response(200, ["con", "tent"])])

      assert {:ok, stream} = Fil.stream(disk(), "a.txt")
      assert [%{method: "HEAD"}] = requests()

      assert Enum.join(stream) == "content"
      assert [%{method: "GET", assigns: %{label: {AzureBlob, :stream, "a.txt"}}}] = requests()
    end

    test "an empty range downloads nothing" do
      stub([response(200, "", [{"content-length", "7"}])])

      assert {:ok, stream} = Fil.stream(disk(), "a.txt", offset: 7)
      assert Enum.to_list(stream) == []
    end

    test "a missing blob is an error before the stream is read" do
      stub([response(404, "", [{"x-ms-error-code", "BlobNotFound"}])])

      assert {:error, %Fil.NotFoundError{reason: "BlobNotFound"}} = Fil.stream(disk(), "a.txt")
    end

    test "verify_checksum: true raises after the last chunk on a mismatch" do
      headers = [{"content-length", "7"}, {"x-ms-meta-fil_crc32", Checksum.digest(:crc32, "content")}]
      stub([response(200, "", headers), response(200, ["changed"], headers)])

      assert {:ok, stream} = Fil.stream(disk(), "a.txt", verify_checksum: true)
      assert_raise Fil.ChecksumMismatchError, fn -> Enum.to_list(stream) end
    end
  end

  describe "stat/1 and dir?/1" do
    test "reads the properties and the stored checksum" do
      headers = [
        {"content-length", "7"},
        {"last-modified", "Thu, 15 Oct 2026 12:00:00 GMT"},
        {"etag", ~s("0x8DE0000000000")},
        {"content-type", "text/plain"},
        {"x-ms-meta-fil_sha256", "abc="}
      ]

      stub([response(200, "", headers)])

      assert {:ok, stat} = Fil.stat(disk(), "a.txt", checksum: :sha256)

      assert stat == %Fil.Stat{
               size: 7,
               type: :regular,
               mtime: ~U[2026-10-15 12:00:00Z],
               etag: "0x8DE0000000000",
               content_type: "text/plain",
               checksum: {:sha256, "abc="}
             }
    end

    test "a missing blob is a directory if blobs have it as their prefix" do
      stub([response(404, "", [{"x-ms-error-code", "BlobNotFound"}]), response(200, list_xml(["docs/a.txt"], []))])

      assert {:ok, %Fil.Stat{type: :directory}} = Fil.stat(disk(), "docs")

      [_head, list] = requests()
      assert query(list)["prefix"] == "docs/"
      assert query(list)["delimiter"] == "/"
      assert query(list)["maxresults"] == "2"
    end

    test "a missing container isn't looked up as a directory" do
      stub([response(404, "", [{"x-ms-error-code", "ContainerNotFound"}])])

      assert {:error, %Fil.ConfigurationError{reason: "ContainerNotFound"}} = Fil.stat(disk(), "docs")
    end

    test "a directory of a hierarchical namespace isn't read as a file" do
      folder = [{"x-ms-meta-hdi_isfolder", "true"}, {"content-length", "0"}]

      stub([response(200, "", folder)])
      assert {:error, %Fil.NotFoundError{reason: :eisdir}} = Fil.read(disk(), "docs")

      stub([response(200, "", folder)])
      assert {:error, %Fil.NotFoundError{reason: :eisdir}} = Fil.stream(disk(), "docs")
    end

    test "a directory of a hierarchical namespace is a directory" do
      stub([response(200, "", [{"x-ms-meta-hdi_isfolder", "true"}])])

      assert {:ok, %Fil.Stat{type: :directory}} = Fil.stat(disk(), "docs")
    end
  end

  describe "ls/2" do
    test "fetches every page, and lists blobs and prefixes" do
      stub([
        response(200, list_xml(["r/a.txt"], ["r/docs/"], "next")),
        response(200, list_xml(["r/b.txt"], []))
      ])

      root = disk(root: "r")
      assert {:ok, listed} = Fil.ls(root, ".")
      assert Enum.map(listed, & &1.path) == ["a.txt", "b.txt", "docs"]

      [first, second] = requests()
      assert query(first)["prefix"] == "r/"
      assert query(first)["include"] == "metadata"
      assert query(second)["marker"] == "next"
    end

    test "finds the directories of a recursive listing in the names" do
      stub([response(200, list_xml(["a/b/c.txt", "d/"], []))])

      assert {:ok, listed} = Fil.ls(disk(), ".", recursive: true, type: :directory)
      assert Enum.map(listed, & &1.path) == ["a", "a/b", "d"]

      assert query(request!())["delimiter"] == nil
    end

    test "an unreadable listing is unavailable" do
      stub([response(200, "<EnumerationResults")])

      assert {:error, %Fil.UnavailableError{reason: :invalid_xml}} = Fil.ls(disk(), ".")
    end
  end

  describe "cp/2 and rename/2" do
    test "copies with the source URL, and waits for a pending copy" do
      stub([
        response(202, "", [{"x-ms-copy-status", "pending"}]),
        response(200, "", [{"x-ms-copy-status", "pending"}]),
        response(200, "", [{"x-ms-copy-status", "success"}])
      ])

      assert {:ok, _} = Fil.cp(copy_disk(), "a b.txt", "c.txt", if_exists: :error)

      [copy, _poll, _poll2] = requests()
      assert copy.request_path == "/c/c.txt"
      assert header(copy, "x-ms-copy-source") == "https://acct.blob.core.windows.net/c/a%20b.txt"
      assert header(copy, "if-none-match") == "*"
      assert header(copy, "content-length") == "0"
    end

    test "a copy that stays pending gives up" do
      stub([response(202, "", [{"x-ms-copy-status", "pending"}])])
      disk = put_state(copy_disk(), copy_timeout: 0)

      assert {:error, %Fil.UnavailableError{reason: :copy_pending}} = Fil.cp(disk, "a.txt", "c.txt")
    end

    test "a failed copy is an error" do
      stub([response(202, "", [{"x-ms-copy-status", "pending"}]), response(200, "", [{"x-ms-copy-status", "failed"}])])

      assert {:error, %Fil.UnknownError{reason: {:copy_status, "failed"}}} = Fil.cp(copy_disk(), "a.txt", "c.txt")
    end

    test "a destination that exists fails with its path" do
      stub([response(409, "", [{"x-ms-error-code", "BlobAlreadyExists"}])])

      assert {:error, %Fil.AlreadyExistsError{path: "c.txt"}} = Fil.cp(disk(), "a.txt", "c.txt", if_exists: :error)
    end

    test "a move copies, then deletes the source, but a move onto itself only copies" do
      stub([response(202, "", [{"x-ms-copy-status", "success"}]), response(202)])
      assert {:ok, _} = Fil.rename(disk(), "a.txt", "b.txt")
      assert Enum.map(requests(), & &1.method) == ["PUT", "DELETE"]

      stub([response(202, "", [{"x-ms-copy-status", "success"}])])
      assert {:ok, _} = Fil.rename(disk(), "a.txt", "a.txt")
      assert Enum.map(requests(), & &1.method) == ["PUT"]
    end
  end

  describe "rm/1 and rm_rf/1" do
    test "a missing blob is fine, a missing container isn't" do
      stub([response(404, "", [{"x-ms-error-code", "BlobNotFound"}])])
      assert {:ok, _} = Fil.rm(disk(), "a.txt")

      stub([response(404, "", [{"x-ms-error-code", "ContainerNotFound"}])])
      assert {:error, %Fil.ConfigurationError{}} = Fil.rm(disk(), "a.txt")
    end

    test "keeps the marker of the disk root" do
      stub([response(200, list_xml(["r/", "r/a.txt"], [])), response(202)])

      root = disk(root: "r")
      assert Fil.rm_rf(root, ".") == {:ok, 1}
      assert [_list, %{request_path: "/c/r/a.txt"}] = requests()
    end

    test "removes the blobs under the prefix, not its siblings and not directories of a hierarchical namespace" do
      folder = {"r/docs/sub", [{"hdi_isfolder", "true"}]}

      stub([
        response(200, list_xml(["r/docs", "r/docs/a.txt", folder, "r/docs.txt"], [])),
        response(202),
        response(202)
      ])

      root = disk(root: "r")
      assert Fil.rm_rf(root, "docs") == {:ok, 2}

      [list | deletes] = requests()
      assert query(list)["prefix"] == "r/docs"
      assert Enum.map(deletes, & &1.request_path) == ["/c/r/docs", "/c/r/docs/a.txt"]
    end
  end

  describe "url/2" do
    test "is the blob URL, at the public endpoint if there is one" do
      assert Fil.url(disk(), "a b.txt") == {:ok, "https://acct.blob.core.windows.net/c/a%20b.txt"}

      public = disk(public_endpoint: "http://localhost:10000/acct")
      assert Fil.url(public, "a.txt") == {:ok, "http://localhost:10000/acct/c/a.txt"}
    end
  end

  describe "signed_url/2" do
    test "signs a read SAS for the blob, with the disposition" do
      root = disk(root: "r")
      assert {:ok, url} = Fil.signed_url(root, "a b.pdf", expires_in: 300, disposition: :attachment)

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert uri.path == "/c/r/a%20b.pdf"
      assert %{"sv" => "2025-01-05", "sr" => "b", "sp" => "r", "spr" => "https"} = query
      assert query["rscd"] == ~s(attachment; filename="a b.pdf")
      assert {:ok, expires, 0} = DateTime.from_iso8601(query["se"])
      assert_in_delta DateTime.diff(expires, DateTime.utc_now()), 300, 5

      expected = sas_signature("r", query["se"], "/blob/acct/c/r/a b.pdf", "https", query["rscd"])
      assert query["sig"] == expected
    end

    test "leaves the protocol open on an http endpoint" do
      azurite = disk(endpoint: "http://127.0.0.1:10000/acct")
      assert {:ok, url} = Fil.signed_url(azurite, "a.txt")

      refute url
             |> url_query()
             |> Map.has_key?("spr")
    end

    test "can't sign query parameters" do
      assert {:error, %Fil.UnsupportedError{op: :signed_url, reason: :unsigned_query}} =
               Fil.signed_url(disk(), "a.txt", query: [{"v", "1"}])
    end

    test "needs the account key" do
      anonymous = disk(account_key: nil)
      assert {:error, %Fil.UnsupportedError{reason: :missing_credentials}} = Fil.signed_url(anonymous, "a.txt")

      sas = disk(account_key: nil, sas_token: "sv=1")
      assert {:error, %Fil.UnsupportedError{reason: :missing_credentials}} = Fil.signed_upload(sas, "a.txt")
    end
  end

  describe "signed_upload/2" do
    test "signs create and write, or only create with if_exists: :error, with the headers Put Blob needs" do
      assert {:ok, upload} = Fil.signed_upload(disk(), "a.png")
      assert url_query(upload.url)["sp"] == "cw"
      assert upload.headers == %{"x-ms-blob-type" => "BlockBlob"}

      assert {:ok, upload} = Fil.signed_upload(disk(), "a.png", content_type: "image/png", size: 3, if_exists: :error)
      assert url_query(upload.url)["sp"] == "c"

      assert upload.headers == %{
               "x-ms-blob-type" => "BlockBlob",
               "content-type" => "image/png",
               "if-none-match" => "*"
             }
    end

    test "can't sign query parameters" do
      assert {:error, %Fil.UnsupportedError{op: :signed_upload, reason: :unsigned_query}} =
               Fil.signed_upload(disk(), "a.txt", query: [{"v", "1"}])
    end
  end

  defp disk(opts \\ []) do
    [adapter: AzureBlob, account: "acct", container: "c", account_key: @account_key, req_options: req_options()]
    |> Keyword.merge(opts)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Fil.disk()
  end

  # The smallest block size, and a failed block sent again without the second's wait.
  defp blocks_disk do
    [block_size: @mib]
    |> disk()
    |> put_state(retry_delay: 0)
  end

  defp copy_disk, do: put_state(disk(), copy_poll: 0)

  defp put_state(%Fil.Disk{adapter: {AzureBlob, state}} = disk, fields) do
    %{disk | adapter: {AzureBlob, struct!(state, fields)}}
  end

  # Two blocks of the blocks disk: a whole one and a byte.
  defp large_chunks do
    "a"
    |> :binary.copy(@mib + 1)
    |> AdapterCase.chunked(@mib)
  end

  defp sas_signature(permissions, expires, resource, protocol, disposition) do
    fields = [
      permissions,
      "",
      expires,
      resource,
      "",
      "",
      protocol,
      "2025-01-05",
      "b",
      "",
      "",
      "",
      disposition,
      "",
      "",
      ""
    ]

    key = Base.decode64!(@account_key)

    :hmac
    |> :crypto.mac(:sha256, key, Enum.join(fields, "\n"))
    |> Base.encode64()
  end

  defp error_xml(code) do
    ~s(<?xml version="1.0" encoding="utf-8"?><Error><Code>#{code}</Code><Message>m</Message></Error>)
  end

  # A List Blobs page. A blob is a name, or `{name, metadata}`.
  defp list_xml(blobs, prefixes, next_marker \\ "") do
    blobs =
      Enum.map(blobs, fn
        {name, metadata} -> blob_xml(name, metadata)
        name -> blob_xml(name, [])
      end)

    prefixes = Enum.map(prefixes, &"<BlobPrefix><Name>#{&1}</Name></BlobPrefix>")

    """
    <?xml version="1.0" encoding="utf-8"?>
    <EnumerationResults ServiceEndpoint="https://acct.blob.core.windows.net/" ContainerName="c">
      <Blobs>#{blobs}#{prefixes}</Blobs>
      <NextMarker>#{next_marker}</NextMarker>
    </EnumerationResults>
    """
  end

  defp blob_xml(name, metadata) do
    metadata = Enum.map(metadata, fn {key, value} -> "<#{key}>#{value}</#{key}>" end)

    """
    <Blob><Name>#{name}</Name><Properties><Last-Modified>Thu, 15 Oct 2026 12:00:00 GMT</Last-Modified>\
    <Etag>0x8DE0000000000</Etag><Content-Length>1</Content-Length><Content-Type>text/plain</Content-Type>\
    </Properties><Metadata>#{metadata}</Metadata></Blob>
    """
  end

  ## ------------------------------------------------------------------
  ## Stubbed requests (see `Fil.ReqStub`)
  ## ------------------------------------------------------------------

  defp req_options, do: ReqStub.req_options(__MODULE__)
  defp stub(responses), do: ReqStub.stub(__MODULE__, responses)
  defp response(status, body \\ "", headers \\ []), do: ReqStub.response(status, body, headers)
  defp requests, do: ReqStub.requests(__MODULE__)
  defp request!, do: ReqStub.request!(__MODULE__)
  defp header(request, name), do: ReqStub.header(request, name)
  defp query(request), do: URI.decode_query(request.query_string)

  defp url_query(url) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
  end
end
