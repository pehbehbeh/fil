defmodule Fil.Adapter.S3Test do
  alias Fil.Adapter.S3

  use ExUnit.Case, async: true

  import Fil.AdapterCase, only: [chunked: 2]
  import Plug.Conn

  setup {Req.Test, :verify_on_exit!}

  @mib 1_048_576
  @part 5 * @mib

  @access_key_id "AKIDEXAMPLE"
  @secret_access_key "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

  describe "init/1" do
    test "requires a bucket" do
      assert_raise ArgumentError, ~r/required :bucket option not found/, fn ->
        Fil.disk(adapter: S3, req_options: req_options())
      end
    end

    test "rejects an endpoint that is not a URL" do
      assert_raise ArgumentError, ~r/invalid_option/, fn ->
        Fil.disk(adapter: S3, bucket: "b", endpoint: "localhost:9000", req_options: req_options())
      end
    end

    test "defaults the region" do
      {:ok, state} = S3.init(bucket: "b")

      assert state.region == "us-east-1"
      assert state.path_style == false
      assert state.req_options == []
    end

    test "an endpoint turns on path style" do
      {:ok, state} = S3.init(bucket: "b", endpoint: "http://localhost:9000")

      assert state.path_style == true
    end

    test "passes req_options to every request" do
      stub([response(200, "content")])

      disk = disk(req_options: [{:params, [extra: "1"]} | req_options()])

      assert {:ok, "content"} = Fil.read(disk, "a.txt")
      assert request!().query_params == %{"extra" => "1"}
    end

    test "rejects req_options that aren't a keyword list" do
      assert {:error, %NimbleOptions.ValidationError{key: :req_options}} = S3.init(bucket: "b", req_options: "nope")
    end
  end

  describe "addressing" do
    test "virtual-hosted by default" do
      stub([response(200, "content")])

      assert {:ok, "content"} = Fil.read(disk(), "a.txt")

      assert request_url(request!()) == "https://bucket.s3.eu-central-1.amazonaws.com/a.txt"
    end

    test "path style on request" do
      stub([response(200, "content")])

      disk = disk(path_style: true)

      assert {:ok, "content"} = Fil.read(disk, "a.txt")

      assert request_url(request!()) == "https://s3.eu-central-1.amazonaws.com/bucket/a.txt"
    end

    test "a custom endpoint" do
      stub([response(200, "content")])

      disk = disk(endpoint: "http://localhost:9000")

      assert {:ok, "content"} = Fil.read(disk, "a.txt")

      assert request_url(request!()) == "http://localhost:9000/bucket/a.txt"
    end

    test "an endpoint with a base path" do
      stub([response(200, "content")])

      disk = disk(endpoint: "https://s3.example.com/storage/")

      assert {:ok, "content"} = Fil.read(disk, "a.txt")

      assert request_url(request!()) == "https://s3.example.com/storage/bucket/a.txt"
    end

    test "encodes each path segment" do
      stub([response(200, "content")])

      assert {:ok, "content"} = Fil.read(disk(), "a b/ünï/#hash.txt")

      assert request_url(request!()) ==
               "https://bucket.s3.eu-central-1.amazonaws.com/a%20b/%C3%BCn%C3%AF/%23hash.txt"
    end
  end

  describe "root" do
    test "prefixes every key" do
      stub([response(200, "content"), response(200)])

      avatars = disk(root: "uploads/avatars")
      uploads = disk(root: "/uploads/")

      assert {:ok, "content"} = Fil.read(avatars, "a.png")
      assert {:ok, _} = Fil.write(uploads, "b.png", "content")

      assert Enum.map(requests(), & &1.request_path) == ["/uploads/avatars/a.png", "/uploads/b.png"]
    end

    test "lists under the root and strips it from the paths" do
      stub([response(200, list_under_root())])

      disk = disk(root: "uploads")

      assert {:ok, refs} = Fil.ls(disk, "photos")

      assert Enum.map(refs, & &1.path) == ["photos/2026", "photos/a.jpg"]
      assert request!().query_params == %{"list-type" => "2", "prefix" => "uploads/photos/", "delimiter" => "/"}
    end

    test "the disk root lists the root prefix" do
      stub([response(200, empty_list())])

      disk = disk(root: "uploads")

      assert {:ok, []} = Fil.ls(disk)
      assert request!().query_params == %{"list-type" => "2", "prefix" => "uploads/", "delimiter" => "/"}
    end

    test "rm_rf deletes by full key" do
      stub([response(200, list_under_root_recursive()), response(204)])

      disk = disk(root: "uploads")

      assert {:ok, 1} = Fil.rm_rf(disk, "photos")

      [list, delete] = requests()

      assert list.query_params == %{"list-type" => "2", "prefix" => "uploads/photos"}
      assert delete.request_path == "/uploads/photos/a.jpg"
    end

    test "copies from a key under the root" do
      stub([response(200, "<CopyObjectResult/>")])

      disk = disk(root: "uploads")

      assert {:ok, _} = Fil.cp(disk, "a.jpg", "b.jpg")

      request = request!()

      assert request.request_path == "/uploads/b.jpg"
      assert header(request, "x-amz-copy-source") == "/bucket/uploads/a.jpg"
    end

    test "presigns the full key" do
      disk = disk(root: "uploads")

      assert {:ok, url} = Fil.signed_url(disk, "cv.pdf")
      assert URI.parse(url).path == "/uploads/cv.pdf"
    end

    test "rejects a root that climbs out of the bucket" do
      assert {:error, {:invalid_option, {:root, "../x"}}} = S3.init(bucket: "b", root: "../x")
    end
  end

  describe "signing" do
    test "signs every request and sends the payload hash" do
      stub([response(200, "content")])

      assert {:ok, _} = Fil.read(disk(), "a.txt")

      request = request!()
      authorization = header(request, "authorization")

      assert authorization =~ ~r"^AWS4-HMAC-SHA256 Credential=#{@access_key_id}/\d{8}/eu-central-1/s3/aws4_request"
      assert authorization =~ ~r/SignedHeaders=host;x-amz-content-sha256;x-amz-date/
      assert authorization =~ ~r/Signature=[0-9a-f]{64}$/
      assert header(request, "x-amz-content-sha256") =~ ~r/^[0-9a-f]{64}$/
      assert header(request, "x-amz-date") =~ ~r/^\d{8}T\d{6}Z$/
      assert header(request, "host") == "bucket.s3.eu-central-1.amazonaws.com"
    end

    test "a session token is signed and sent" do
      stub([response(200, "content")])

      disk = disk(session_token: "SESSION")

      assert {:ok, _} = Fil.read(disk, "a.txt")

      request = request!()

      assert header(request, "x-amz-security-token") == "SESSION"
      assert header(request, "authorization") =~ "x-amz-security-token"
    end

    test "a bucket without credentials is read unsigned" do
      stub([response(200, "content")])

      disk = Fil.disk(adapter: S3, bucket: "public", req_options: req_options())

      assert {:ok, "content"} = Fil.read(disk, "a.txt")
      assert header(request!(), "authorization") == nil
    end
  end

  describe "errors" do
    test "map the status when there's no error code" do
      for {status, error} <- [
            {404, Fil.NotFoundError},
            {403, Fil.AccessDeniedError},
            {409, Fil.AlreadyExistsError},
            {412, Fil.AlreadyExistsError},
            {429, Fil.UnavailableError},
            {503, Fil.UnavailableError},
            {418, Fil.UnknownError}
          ] do
        stub([response(status)])

        assert {:error, %^error{reason: {:http_status, ^status}}} = Fil.read(disk(), "a.txt")
      end
    end

    test "map the error code whatever the status" do
      for {code, error} <- [
            {"NoSuchKey", Fil.NotFoundError},
            {"AccessDenied", Fil.AccessDeniedError},
            {"EntityTooLarge", Fil.InvalidRequestError},
            {"KeyTooLongError", Fil.InvalidRequestError},
            {"PreconditionFailed", Fil.AlreadyExistsError},
            {"ConditionalRequestConflict", Fil.AlreadyExistsError},
            {"BadDigest", Fil.ChecksumMismatchError},
            {"NoSuchBucket", Fil.ConfigurationError},
            {"SlowDown", Fil.UnavailableError},
            {"OperationAborted", Fil.UnavailableError},
            {"InternalError", Fil.UnavailableError},
            {"ServiceUnavailable", Fil.UnavailableError}
          ] do
        stub([response(400, error_xml(code))])

        assert {:error, %^error{reason: ^code}} = Fil.read(disk(), "a.txt")
      end
    end

    test "a 409 with another code doesn't mean the file exists" do
      stub([response(409, error_xml("BucketNotEmpty"))])

      assert {:error, %Fil.UnknownError{reason: "BucketNotEmpty"}} = Fil.read(disk(), "a.txt")
    end

    test "an unknown code is an unknown error that keeps it" do
      stub([response(400, error_xml("InvalidArgument"))])

      assert {:error, %Fil.UnknownError{reason: "InvalidArgument"}} = Fil.read(disk(), "a.txt")
    end

    test "a client failure is unavailable" do
      stub([{:error, :timeout}])

      assert {:error, %Fil.UnavailableError{reason: :timeout} = error} = Fil.read(disk(), "a.txt")
      assert Exception.message(error) =~ "the storage is unavailable (:timeout)"
    end

    test "a redirect or a 400 that names a region is a configuration error" do
      stub([response(301, "", [{"x-amz-bucket-region", "us-west-2"}])])
      assert {:error, %Fil.ConfigurationError{reason: {:wrong_region, "us-west-2"}}} = Fil.read(disk(), "a.txt")

      stub([response(400, error_xml("AuthorizationHeaderMalformed"), [{"x-amz-bucket-region", "us-west-2"}])])
      assert {:error, %Fil.ConfigurationError{reason: {:wrong_region, "us-west-2"}}} = Fil.read(disk(), "a.txt")
    end
  end

  describe "write/3" do
    test "sends a PutObject" do
      stub([response(200)])

      assert {:ok, ref} = Fil.write(disk(), "a.txt", ["Hello", ", World"])

      request = request!()

      assert ref.path == "a.txt"
      assert request.method == "PUT"
      assert request.assigns.body == "Hello, World"
      assert header(request, "x-amz-content-sha256") == sha256("Hello, World")
    end

    test "sends the content type when asked" do
      stub([response(200)])

      assert {:ok, _} = Fil.write(disk(), "a.txt", "x", content_type: "text/plain")

      assert header(request!(), "content-type") == "text/plain"
    end

    test "if_exists: :error becomes If-None-Match: *" do
      stub([response(200)])

      assert {:ok, _} = Fil.write(disk(), "a.txt", "x", if_exists: :error)

      assert header(request!(), "if-none-match") == "*"
    end

    test "a lost race means the file already exists" do
      stub([response(412, error_xml("PreconditionFailed"))])

      assert {:error, %Fil.AlreadyExistsError{reason: "PreconditionFailed"}} =
               Fil.write(disk(), "a.txt", "x", if_exists: :error)
    end
  end

  describe "streamed writes" do
    test "a stream with a size is sent as it's read" do
      stub([response(200)])

      stream = Stream.map(["Hello", ", ", "World"], & &1)

      assert {:ok, _} = Fil.write(disk(), "a.txt", stream, size: 12, content_type: "text/plain")

      request = request!()

      assert request.assigns.body == "Hello, World"
      assert header(request, "content-length") == "12"
      assert header(request, "content-type") == "text/plain"
      assert header(request, "x-amz-content-sha256") == "UNSIGNED-PAYLOAD"
      assert header(request, "authorization") =~ "x-amz-content-sha256"
    end

    test "a stream without a size is collected and sent as one binary" do
      stub([response(200)])

      assert {:ok, _} = Fil.write(disk(), "a.txt", Stream.map(["Hello", ", World"], & &1))

      request = request!()

      assert request.assigns.body == "Hello, World"
      assert header(request, "x-amz-content-sha256") == sha256("Hello, World")
    end

    test "a stream with a checksum is collected, so the checksum goes first" do
      stub([response(200)])

      assert {:ok, _} = Fil.write(disk(), "a.txt", Stream.map(["He", "llo"], & &1), size: 5, checksum: :crc32)

      request = request!()

      assert header(request, "x-amz-checksum-crc32") == "99GJgg=="
      assert header(request, "x-amz-content-sha256") == sha256("Hello")
    end

    test "if_exists: :error still sends If-None-Match: *" do
      stub([response(412, error_xml("PreconditionFailed"))])

      assert {:error, %Fil.AlreadyExistsError{}} =
               Fil.write(disk(), "a.txt", Stream.map(["x"], & &1), size: 1, if_exists: :error)

      assert header(request!(), "if-none-match") == "*"
    end
  end

  describe "uploads in parts" do
    test "a stream without a size larger than a part is uploaded in parts" do
      stub([
        response(200, initiate_xml("UP")),
        part_response("e1"),
        part_response("e2"),
        response(200, completed_xml())
      ])

      content = :crypto.strong_rand_bytes(@part + 1)

      assert {:ok, ref} = Fil.write(parts_disk(), "a.bin", chunked(content, @mib), content_type: "video/mp4")
      assert ref.path == "a.bin"

      [create, first, second, complete] = requests()

      assert {create.method, create.request_path, create.query_params} == {"POST", "/a.bin", %{"uploads" => ""}}
      assert header(create, "content-type") == "video/mp4"
      assert header(create, "content-length") == "0"

      assert {first.method, first.query_params} == {"PUT", %{"partNumber" => "1", "uploadId" => "UP"}}
      assert first.assigns.body == binary_part(content, 0, @part)
      assert header(first, "x-amz-content-sha256") == sha256(first.assigns.body)

      assert second.query_params == %{"partNumber" => "2", "uploadId" => "UP"}
      assert second.assigns.body == binary_part(content, @part, 1)

      assert {complete.method, complete.query_params} == {"POST", %{"uploadId" => "UP"}}
      assert completed_parts(complete) == [{"1", ~s("e1")}, {"2", ~s("e2")}]

      for request <- [create, first, second, complete], do: assert(header(request, "if-none-match") == nil)
    end

    test "a stream of whole parts has no empty last part" do
      stub([
        response(200, initiate_xml("UP")),
        part_response("e1"),
        part_response("e2"),
        response(200, completed_xml())
      ])

      assert {:ok, _} = Fil.write(parts_disk(), "a.bin", chunked(:binary.copy("a", 2 * @part), @mib))

      assert [_create, _first, second, complete] = requests()
      assert byte_size(second.assigns.body) == @part
      assert length(completed_parts(complete)) == 2
    end

    test "a stream that fits in one part is one PutObject" do
      stub([response(200)])
      content = :binary.copy("a", @part)

      assert {:ok, _} = Fil.write(parts_disk(), "a.bin", chunked(content, @mib), content_type: "video/mp4")

      request = request!()
      assert {request.method, request.query_params} == {"PUT", %{}}
      assert request.assigns.body == content
      assert header(request, "content-type") == "video/mp4"
    end

    test "if_exists: :error is checked when the upload completes" do
      stub([
        response(200, initiate_xml("UP")),
        part_response("e1"),
        part_response("e2"),
        response(200, completed_xml())
      ])

      assert {:ok, _} = Fil.write(parts_disk(), "a.bin", large_stream(), if_exists: :error)
      assert Enum.map(requests(), &header(&1, "if-none-match")) == [nil, nil, nil, "*"]

      stub([
        response(200, initiate_xml("UP")),
        part_response("e1"),
        part_response("e2"),
        response(412, error_xml("PreconditionFailed")),
        response(204)
      ])

      assert {:error, %Fil.AlreadyExistsError{reason: "PreconditionFailed", op: :write, path: "a.bin"}} =
               Fil.write(parts_disk(), "a.bin", large_stream(), if_exists: :error)

      assert_aborted(requests())
    end

    test "a failed part aborts the upload and closes the stream" do
      test = self()
      stub([response(200, initiate_xml("UP")), response(500), response(503, error_xml("SlowDown")), response(204)])

      stream =
        Stream.resource(
          fn -> 0 end,
          fn count -> {[:binary.copy("a", @mib)], count + 1} end,
          fn _count -> send(test, :closed) end
        )

      assert {:error, %Fil.UnavailableError{reason: "SlowDown"}} = Fil.write(parts_disk(), "a.bin", stream)
      assert_received :closed

      requests = requests()
      assert Enum.map(requests, & &1.method) == ["POST", "PUT", "PUT", "DELETE"]
      assert_aborted(requests)
    end

    test "a part that fails with an unavailable storage is sent once more" do
      stub([
        response(200, initiate_xml("UP")),
        {:error, :closed},
        part_response("e1"),
        part_response("e2"),
        response(200, completed_xml())
      ])

      assert {:ok, _} = Fil.write(parts_disk(), "a.bin", large_stream())

      assert [_create, failed, retried, _second, complete] = requests()
      assert failed.assigns.body == retried.assigns.body
      assert retried.query_params["partNumber"] == "1"
      assert completed_parts(complete) == [{"1", ~s("e1")}, {"2", ~s("e2")}]
    end

    test "a stream that raises after a part aborts the upload" do
      stub([response(200, initiate_xml("UP")), part_response("e1"), response(204)])

      assert_raise RuntimeError, "the upload broke off", fn ->
        Fil.write(parts_disk(), "a.bin", raising_after(@part + 1, fn -> raise "the upload broke off" end))
      end

      assert_aborted(requests())

      stub([response(200, initiate_xml("UP")), part_response("e1"), response(204)])

      assert {:error, %Fil.ConflictError{reason: :size_changed}} =
               Fil.write(
                 parts_disk(),
                 "a.bin",
                 raising_after(@part + 1, fn -> raise %Fil.ConflictError{reason: :size_changed} end)
               )

      assert_aborted(requests())
    end

    test "an error inside the 200 of the completion aborts the upload" do
      stub([
        response(200, initiate_xml("UP")),
        part_response("e1"),
        part_response("e2"),
        response(200, "\n   \n" <> error_xml("InternalError")),
        response(204)
      ])

      assert {:error, %Fil.UnavailableError{reason: "InternalError"}} = Fil.write(parts_disk(), "a.bin", large_stream())
      assert_aborted(requests())
    end

    test "a completion with a result after whitespace succeeds" do
      stub([
        response(200, initiate_xml("UP")),
        part_response("e1"),
        part_response("e2"),
        response(200, "\n  " <> completed_xml())
      ])

      assert {:ok, _} = Fil.write(parts_disk(), "a.bin", large_stream())
    end

    test "a failed create has nothing to abort" do
      stub([response(403, error_xml("AccessDenied"))])
      assert {:error, %Fil.AccessDeniedError{reason: "AccessDenied"}} = Fil.write(parts_disk(), "a.bin", large_stream())
      assert [%{method: "POST"}] = requests()

      stub([response(200, "<InitiateMultipartUploadResult/>")])
      assert {:error, %Fil.UnavailableError{reason: :invalid_xml}} = Fil.write(parts_disk(), "a.bin", large_stream())
    end

    test "a failed abort still returns the error of the write" do
      stub([response(200, initiate_xml("UP")), response(400, error_xml("InvalidArgument")), response(500)])

      assert {:error, %Fil.UnknownError{reason: "InvalidArgument"}} = Fil.write(parts_disk(), "a.bin", large_stream())
      assert_aborted(requests())
    end

    test "an upload aborted from outside is a conflict" do
      stub([response(200, initiate_xml("UP")), response(404, error_xml("NoSuchUpload")), response(404)])

      assert {:error, %Fil.ConflictError{reason: "NoSuchUpload"}} = Fil.write(parts_disk(), "a.bin", large_stream())
    end

    test "a part without an ETag is an unknown error" do
      stub([response(200, initiate_xml("UP")), response(200), response(204)])

      assert {:error, %Fil.UnknownError{reason: :missing_etag}} = Fil.write(parts_disk(), "a.bin", large_stream())
    end

    test "a stream that needs more parts than S3 allows stops before the last one" do
      disk = max_parts(parts_disk(), 2)

      stub([
        response(200, initiate_xml("UP")),
        part_response("e1"),
        part_response("e2"),
        response(200, completed_xml())
      ])

      assert {:ok, _} = Fil.write(disk, "a.bin", chunked(:binary.copy("a", 2 * @part), @mib))

      stub([response(200, initiate_xml("UP")), part_response("e1"), response(204)])

      assert {:error, %Fil.InvalidRequestError{reason: :too_many_parts}} =
               Fil.write(disk, "a.bin", chunked(:binary.copy("a", 2 * @part + 1), @mib))

      assert_aborted(requests())
    end

    test "the upload of a killed writer is aborted" do
      test = self()
      stub([response(200, initiate_xml("UP")), part_response("e1"), response(204)])
      disk = parts_disk()

      writer =
        spawn(fn ->
          Process.put(:"$callers", [test])
          Fil.write(disk, "a.bin", raising_after(@part + 1, fn -> Process.sleep(:infinity) end))
        end)

      assert_receive {__MODULE__, %{method: "PUT", query_params: %{"partNumber" => "1"}}}, 5_000
      Process.exit(writer, :kill)

      assert_receive {__MODULE__, %{method: "DELETE"} = abort}, 5_000
      assert abort.query_params == %{"uploadId" => "UP"}
    end

    test "the part size is at least 5 MiB" do
      assert_raise ArgumentError, ~r/invalid value for :part_size option/, fn -> disk(part_size: @part - 1) end
    end
  end

  describe "copies from another disk" do
    setup do
      Fil.Adapter.Memory.checkout()
      {:ok, memory: Fil.disk(adapter: Fil.Adapter.Memory)}
    end

    test "stream with the source's size", %{memory: memory} do
      stub([response(200)])
      {:ok, source} = Fil.write(memory, "a.txt", "Hello, World")

      assert {:ok, _} = Fil.cp(source, Fil.ref(disk(), "b.txt"))

      request = request!()

      assert request.assigns.body == "Hello, World"
      assert header(request, "content-length") == "12"
      assert header(request, "x-amz-content-sha256") == "UNSIGNED-PAYLOAD"
    end

    test "are collected when a plugin on the source changes the content", %{memory: memory} do
      stub([response(200)])
      {:ok, _} = Fil.write(memory, "a.txt", "Hello")

      shouting =
        Fil.attach(memory, :shout, fn
          %Fil.Op{name: :read} = op, next, _opts ->
            op
            |> next.()
            |> Fil.Op.update_result(stream: &Stream.map(&1, fn chunk -> String.upcase(chunk) end))

          op, next, _opts ->
            next.(op)
        end)

      assert {:ok, _} = Fil.cp(shouting, "a.txt", Fil.ref(disk(), "b.txt"))

      request = request!()

      assert request.assigns.body == "HELLO"
      assert header(request, "x-amz-content-sha256") == sha256("HELLO")
    end
  end

  describe "stream/2" do
    test "checks with HeadObject and downloads with GetObject when the stream is read" do
      stub([response(200), response(200, ["Hel", "lo"])])

      assert {:ok, stream} = Fil.stream(disk(), "a.txt")
      assert [%{method: "HEAD", request_path: "/a.txt"}] = requests()

      assert Enum.to_list(stream) == ["Hel", "lo"]
      assert [%{method: "GET", request_path: "/a.txt"} = get] = requests()
      assert header(get, "x-amz-checksum-mode") == nil
    end

    test "downloads again each time the stream is read" do
      stub([response(200), response(200, "one"), response(200, "two")])

      assert {:ok, stream} = Fil.stream(disk(), "a.txt")
      assert Enum.join(stream) == "one"
      assert Enum.join(stream) == "two"
    end

    test "stops the download when the stream is halted" do
      test = self()

      Req.Test.verify!(__MODULE__)
      Req.Test.expect(__MODULE__, &send_resp(&1, 200, ""))

      Req.Test.expect(__MODULE__, fn conn ->
        send(test, {:download, self()})
        reply(conn, response(200, ["a", "b", "c"]))
      end)

      assert {:ok, stream} = Fil.stream(disk(), "a.txt")
      assert Enum.take(stream, 1) == ["a"]

      assert_received {:download, download}
      monitor = Process.monitor(download)
      assert_receive {:DOWN, ^monitor, :process, ^download, _reason}
      refute_received _leftover
    end

    test "a missing object is asked again with GetObject, for the error code" do
      stub([response(404), response(404, error_xml("NoSuchBucket"))])

      assert {:error, %Fil.ConfigurationError{op: :read, reason: "NoSuchBucket"}} = Fil.stream(disk(), "a.txt")
      assert Enum.map(requests(), & &1.method) == ["HEAD", "GET"]

      stub([response(404), response(404, error_xml("NoSuchKey"))])
      assert {:error, %Fil.NotFoundError{reason: "NoSuchKey"}} = Fil.stream(disk(), "a.txt")
    end

    test "another HeadObject failure is returned right away" do
      stub([response(403)])

      assert {:error, %Fil.AccessDeniedError{reason: {:http_status, 403}}} = Fil.stream(disk(), "a.txt")
    end

    test "a failed download raises with the context" do
      disk = disk()
      stub([response(200), response(503, error_xml("SlowDown"))])

      assert {:ok, stream} = Fil.stream(disk, "a.txt")

      error = assert_raise Fil.UnavailableError, fn -> Enum.to_list(stream) end
      assert {error.op, error.path, error.disk, error.reason} == {:read, "a.txt", disk, "SlowDown"}
    end

    test "a lost connection raises" do
      stub([response(200), {:error, :closed}])

      assert {:ok, stream} = Fil.stream(disk(), "a.txt")
      assert_raise Fil.UnavailableError, ~r/:closed/, fn -> Enum.to_list(stream) end
    end

    test "verify_checksum: true checks the download against the stored checksum" do
      checksum = [{"x-amz-checksum-crc32", "99GJgg=="}]

      stub([response(200, "", checksum), response(200, ["Hel", "lo"], checksum)])

      assert {:ok, stream} = Fil.stream(disk(), "a.txt", verify_checksum: true)
      assert Enum.join(stream) == "Hello"
      assert Enum.map(requests(), &header(&1, "x-amz-checksum-mode")) == ["ENABLED", "ENABLED"]

      stub([response(200, "", checksum), response(200, ["Hel", "lø"], checksum)])

      assert {:ok, stream} = Fil.stream(disk(), "a.txt", verify_checksum: true)

      assert_raise Fil.ChecksumMismatchError, ~r/could not read "a.txt"/, fn -> Enum.to_list(stream) end
    end

    test "verify_checksum: true reads objects without a checksum unchecked" do
      stub([response(200), response(200, "Hellø")])

      assert {:ok, stream} = Fil.stream(disk(), "a.txt", verify_checksum: true)
      assert Enum.join(stream) == "Hellø"
    end
  end

  describe "rm/1" do
    test "is idempotent" do
      stub([response(204), response(404)])

      assert {:ok, _} = Fil.rm(disk(), "a.txt")
      assert {:ok, _} = Fil.rm(disk(), "a.txt")

      assert Enum.map(requests(), & &1.method) == ["DELETE", "DELETE"]
    end

    test "a missing bucket is still an error" do
      stub([response(404, error_xml("NoSuchBucket"))])

      assert {:error, %Fil.ConfigurationError{reason: "NoSuchBucket"}} = Fil.rm(disk(), "a.txt")
    end
  end

  describe "cp/2 and rename/2" do
    test "copy sends the source as a header" do
      stub([response(200, "<CopyObjectResult/>")])

      assert {:ok, ref} = Fil.cp(disk(), "a b.txt", "copies/a.txt")

      request = request!()

      assert ref.path == "copies/a.txt"
      assert request.method == "PUT"
      assert request_url(request) == "https://bucket.s3.eu-central-1.amazonaws.com/copies/a.txt"
      assert header(request, "x-amz-copy-source") == "/bucket/a%20b.txt"
    end

    test "copy notices a failure reported inside a 200" do
      stub([response(200, error_xml("InternalError"))])

      assert {:error, %Fil.UnavailableError{reason: "InternalError"}} = Fil.cp(disk(), "a.txt", "b.txt")
    end

    test "copy notices a failure after the whitespace that kept the connection alive" do
      stub([response(200, "\n  \n" <> error_xml("InternalError"))])

      assert {:error, %Fil.UnavailableError{reason: "InternalError"}} = Fil.cp(disk(), "a.txt", "b.txt")
    end

    test "copy succeeds when the 200 has a result, or a body that can't be read" do
      stub([response(200, "\n  <CopyObjectResult><ETag>\"a\"</ETag></CopyObjectResult>"), response(200, "<Err")])

      assert {:ok, _} = Fil.cp(disk(), "a.txt", "b.txt")
      assert {:ok, _} = Fil.cp(disk(), "a.txt", "b.txt")
    end

    test "a missing source is not found" do
      stub([response(404, error_xml("NoSuchKey")), response(400, error_xml("NoSuchKey"))])

      assert {:error, %Fil.NotFoundError{path: "a.txt"}} = Fil.cp(disk(), "a.txt", "b.txt")
      assert {:error, %Fil.NotFoundError{path: "a.txt"}} = Fil.cp(disk(), "a.txt", "b.txt")
    end

    test "a plain 400 checks whether the source exists" do
      stub([response(400, error_xml("InvalidArgument")), response(404)])

      assert {:error, %Fil.NotFoundError{reason: {:http_status, 404}}} = Fil.cp(disk(), "a.txt", "b.txt")
      assert [%{method: "PUT"}, %{method: "HEAD"} = head] = requests()
      assert request_url(head) == "https://bucket.s3.eu-central-1.amazonaws.com/a.txt"

      stub([response(400, error_xml("InvalidArgument")), response(200)])

      assert {:error, %Fil.UnknownError{reason: "InvalidArgument"}} = Fil.cp(disk(), "a.txt", "b.txt")
    end

    test "rename copies and then deletes" do
      stub([response(200, "<CopyObjectResult/>"), response(204)])

      assert {:ok, ref} = Fil.rename(disk(), "a.txt", "b.txt")

      assert ref.path == "b.txt"
      assert Enum.map(requests(), & &1.method) == ["PUT", "DELETE"]
    end
  end

  describe "ls/2" do
    test "asks for one level and pages through the results" do
      stub([response(200, list_page_one()), response(200, list_page_two())])

      assert {:ok, refs} = Fil.ls(disk(), "photos")

      assert Enum.map(refs, & &1.path) == [
               "photos/2025",
               "photos/2026",
               "photos/a.jpg",
               "photos/b.jpg"
             ]

      assert Enum.map(refs, & &1.stat.type) == [:directory, :directory, :regular, :regular]

      [first, second] = requests()

      assert first.query_params == %{"list-type" => "2", "prefix" => "photos/", "delimiter" => "/"}

      assert second.query_params == %{
               "list-type" => "2",
               "prefix" => "photos/",
               "delimiter" => "/",
               "continuation-token" => "1ueGcxLPRx1Tr"
             }
    end

    test "fills in the stat snapshot from the listing" do
      stub([response(200, list_page_two())])

      assert {:ok, [directory, ref]} = Fil.ls(disk(), "photos")

      assert directory.path == "photos/2026"
      assert directory.stat == %Fil.Stat{type: :directory}
      assert ref.path == "photos/b.jpg"
      assert ref.stat.size == 2048
      assert ref.stat.etag == "b0b0b0"
      assert ref.stat.mtime == ~U[2026-02-03 04:05:06Z]
      assert ref.disk == disk()
    end

    test "recursive listings drop the delimiter" do
      stub([response(200, list_page_two())])

      assert {:ok, _} = Fil.ls(disk(), "photos", recursive: true)

      assert request!().query_params == %{"list-type" => "2", "prefix" => "photos/"}
    end

    test "the disk root lists without a prefix" do
      stub([response(200, list_page_two())])

      assert {:ok, _} = Fil.ls(disk())

      assert request!().query_params == %{"list-type" => "2", "prefix" => "", "delimiter" => "/"}
    end

    test "skips the directory marker object" do
      stub([response(200, list_with_marker())])

      assert {:ok, refs} = Fil.ls(disk(), "photos")

      assert Enum.map(refs, & &1.path) == ["photos/a.jpg"]
    end

    test "an unparsable body is unavailable" do
      stub([response(200, "not xml at all")])

      assert {:error, %Fil.UnavailableError{reason: :invalid_xml}} = Fil.ls(disk(), "photos")
    end
  end

  describe "stat/1 and dir?/1" do
    test "reads the object headers" do
      stub([
        response(200, "", [
          {"content-length", "1024"},
          {"content-type", "image/jpeg"},
          {"etag", "\"d41d8cd98f00b204e9800998ecf8427e\""},
          {"last-modified", "Wed, 21 Oct 2015 07:28:00 GMT"}
        ])
      ])

      assert {:ok, stat} = Fil.stat(disk(), "a.jpg")

      assert stat.size == 1024
      assert stat.type == :regular
      assert stat.content_type == "image/jpeg"
      assert stat.etag == "d41d8cd98f00b204e9800998ecf8427e"
      assert stat.mtime == ~U[2015-10-21 07:28:00Z]
      assert request!().method == "HEAD"
    end

    test "falls back to a prefix probe" do
      stub([response(404), response(200, list_page_two())])

      assert {:ok, %Fil.Stat{type: :directory}} = Fil.stat(disk(), "photos")
      assert Enum.map(requests(), & &1.method) == ["HEAD", "GET"]
    end

    test "dir? is true for a prefix and false for an object" do
      stub([response(404), response(200, list_page_two())])
      assert Fil.dir?(disk(), "photos")

      stub([response(200, "", [{"content-length", "1"}])])
      refute Fil.dir?(disk(), "a.jpg")

      stub([response(404), response(200, empty_list())])
      refute Fil.dir?(disk(), "nope")
    end

    test "a missing key with nothing under it is not found" do
      stub([response(404), response(200, empty_list())])

      assert {:error, %Fil.NotFoundError{reason: {:http_status, 404}}} = Fil.stat(disk(), "photos")
    end

    test "the disk root is always a directory" do
      stub([])

      assert {:ok, %Fil.Stat{type: :directory}} = Fil.stat(disk(), ".")
      assert requests() == []
    end
  end

  describe "rm_rf/1" do
    test "lists and then deletes every key underneath" do
      stub([response(200, list_recursive()), response(204), response(204)])

      assert {:ok, 2} = Fil.rm_rf(disk(), "photos")

      [list, first, second] = requests()

      assert list.query_params == %{"list-type" => "2", "prefix" => "photos"}
      assert Enum.map([first, second], & &1.method) == ["DELETE", "DELETE"]

      assert Enum.map([first, second], & &1.request_path) == [
               "/photos/a.jpg",
               "/photos/2026/b.jpg"
             ]
    end

    test "ignores keys that only share a name prefix" do
      stub([response(200, list_sibling_prefix()), response(204)])

      assert {:ok, 1} = Fil.rm_rf(disk(), "photos")

      [_list, delete] = requests()

      assert delete.request_path == "/photos/a.jpg"
    end

    test "stops at the first key it cannot delete" do
      stub([response(200, list_recursive()), response(403, error_xml("AccessDenied"))])

      assert {:error, %Fil.AccessDeniedError{reason: "AccessDenied"}} = Fil.rm_rf(disk(), "photos")
    end

    test "deletes nothing when there is nothing" do
      stub([response(200, empty_list())])

      assert {:ok, 0} = Fil.rm_rf(disk(), "photos")
      assert length(requests()) == 1
    end
  end

  describe "url/2" do
    test "builds the object URL without a signature" do
      assert Fil.url(disk(), "reports/q3 final.pdf") ==
               {:ok, "https://bucket.s3.eu-central-1.amazonaws.com/reports/q3%20final.pdf"}

      disk = disk(root: "uploads")

      assert Fil.url(disk, "cv.pdf") ==
               {:ok, "https://bucket.s3.eu-central-1.amazonaws.com/uploads/cv.pdf"}

      assert requests() == []
    end

    test "puts the bucket in the path of a custom endpoint" do
      disk = disk(endpoint: "http://localhost:9000")

      assert Fil.url(disk, "cv.pdf") == {:ok, "http://localhost:9000/bucket/cv.pdf"}
    end

    test "needs no credentials" do
      disk = Fil.disk(adapter: S3, bucket: "public", region: "eu-central-1", req_options: req_options())

      assert Fil.url(disk, "cv.pdf") == {:ok, "https://public.s3.eu-central-1.amazonaws.com/cv.pdf"}
    end
  end

  describe "signed_url/2" do
    test "presigns a GET" do
      assert {:ok, url} = Fil.signed_url(disk(), "cv.pdf", expires_in: 300)

      query = query(url)

      assert String.starts_with?(url, "https://bucket.s3.eu-central-1.amazonaws.com/cv.pdf?")
      assert query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
      assert query["X-Amz-Credential"] =~ "#{@access_key_id}/"
      assert query["X-Amz-Expires"] == "300"
      assert query["X-Amz-SignedHeaders"] == "host"
      assert query["X-Amz-Signature"] =~ ~r/^[0-9a-f]{64}$/
      assert requests() == []
    end

    test "presigns a PUT differently" do
      assert {:ok, get} = Fil.signed_url(disk(), "upload.bin")
      assert {:ok, put} = Fil.signed_url(disk(), "upload.bin", method: :put)

      refute signature(get) == signature(put)
      assert query(get)["X-Amz-Expires"] == "900"
    end

    test "encodes the key and includes the session token" do
      disk = disk(session_token: "SESSION")

      assert {:ok, url} = Fil.signed_url(disk, "reports/q3 final.pdf")

      uri = URI.parse(url)

      assert uri.path == "/reports/q3%20final.pdf"
      assert URI.decode_query(uri.query)["X-Amz-Security-Token"] == "SESSION"
    end

    test "validates the expiry and the method" do
      assert_raise ArgumentError, ~r/invalid value for :expires_in option/, fn ->
        Fil.signed_url(disk(), "cv.pdf", expires_in: 8 * 24 * 60 * 60)
      end

      assert_raise ArgumentError, ~r/invalid value for :method option/, fn ->
        Fil.signed_url(disk(), "cv.pdf", method: :delete)
      end
    end

    test "needs credentials" do
      disk = Fil.disk(adapter: S3, bucket: "public", req_options: req_options())

      assert {:error, %Fil.UnsupportedError{op: :signed_url, reason: :missing_credentials}} =
               Fil.signed_url(disk, "cv.pdf")
    end

    test "signs the disposition as response-content-disposition" do
      assert {:ok, plain} = Fil.signed_url(disk(), "cv.pdf")
      assert {:ok, inline} = Fil.signed_url(disk(), "cv.pdf", disposition: :inline)
      assert {:ok, attachment} = Fil.signed_url(disk(), "cv.pdf", disposition: :attachment)

      refute plain
             |> query()
             |> Map.has_key?("response-content-disposition")

      assert query(inline)["response-content-disposition"] == "inline"

      # Encoded the way SigV4 canonicalizes it (`%20`, not `+`), so the URL S3 receives matches the signed query.
      assert URI.parse(attachment).query =~
               "&response-content-disposition=attachment%3B%20filename%3D%22cv.pdf%22&"

      assert [plain, inline, attachment]
             |> Enum.map(&signature/1)
             |> Enum.uniq()
             |> length() == 3

      assert requests() == []
    end

    test "takes the file name from the normalized path" do
      disposition = fn path, opts ->
        {:ok, url} = Fil.signed_url(disk(), path, opts)
        query(url)["response-content-disposition"]
      end

      assert disposition.("docs/../cv.pdf", disposition: :attachment) == ~s(attachment; filename="cv.pdf")
      assert disposition.("", disposition: :attachment) == "attachment"

      assert_raise ArgumentError, ~r/can't be empty/, fn ->
        Fil.signed_url(disk(), "cv.pdf", disposition: {:attachment, ""})
      end
    end

    test "signs extra query parameters" do
      assert {:ok, plain} = Fil.signed_url(disk(), "index.html")
      assert {:ok, tracked} = Fil.signed_url(disk(), "index.html", query: [{"trackingInfo", "7-42-a b"}])

      assert query(tracked)["trackingInfo"] == "7-42-a b"
      assert URI.parse(tracked).query =~ "&trackingInfo=7-42-a%20b&"
      refute signature(plain) == signature(tracked)
    end

    test "encodes a filename that isn't ASCII" do
      assert {:ok, url} = Fil.signed_url(disk(), "7f3a.pdf", disposition: {:attachment, ~s(Rechnung "März".pdf)})

      assert query(url)["response-content-disposition"] ==
               ~s(attachment; filename="Rechnung _M_rz_.pdf"; filename*=UTF-8''Rechnung%20%22M%C3%A4rz%22.pdf)
    end
  end

  describe "public_endpoint" do
    setup do
      {:ok, disk: disk(endpoint: "http://s3mock:9090", public_endpoint: "http://localhost:9090/")}
    end

    test "builds public and signed URLs", %{disk: disk} do
      assert Fil.url(disk, "cv.pdf") == {:ok, "http://localhost:9090/bucket/cv.pdf"}
      assert {:ok, "http://localhost:9090/bucket/cv.pdf?" <> _query} = Fil.signed_url(disk, "cv.pdf")
    end

    test "leaves the requests on the endpoint", %{disk: disk} do
      stub([response(200, "content")])

      assert Fil.read(disk, "cv.pdf") == {:ok, "content"}
      assert "http://s3mock:9090/bucket/cv.pdf" <> _ = request_url(request!())
    end

    test "follows path_style" do
      disk = disk(public_endpoint: "https://bucket.cdn.example.com", path_style: false)

      assert Fil.url(disk, "cv.pdf") == {:ok, "https://bucket.cdn.example.com/cv.pdf"}
    end

    test "must be a URL" do
      assert {:error, {:invalid_option, {:public_endpoint, "localhost:9090"}}} =
               S3.init(bucket: "b", public_endpoint: "localhost:9090")
    end
  end

  ## ------------------------------------------------------------------
  ## Fixtures
  ## ------------------------------------------------------------------

  describe "checksums" do
    @checksums [
      sha256: "GF+NsyJx/iX1Yab8k4suJkMG7DBO2lGAB9F2SCY4GWk=",
      sha1: "9/+ei3uy4Jtwk1pdeF4MxdnQq/A=",
      crc32: "99GJgg=="
    ]

    test "a write sends the checksum of the content" do
      for {algorithm, checksum} <- @checksums do
        stub([response(200)])

        assert {:ok, _} = Fil.write(disk(), "a.txt", ["He", "llo"], checksum: algorithm)

        assert header(request!(), "x-amz-checksum-#{algorithm}") == checksum
      end
    end

    test "a write without the option sends no checksum" do
      stub([response(200)])

      assert {:ok, _} = Fil.write(disk(), "a.txt", "Hello")

      refute Enum.any?(request!().req_headers, fn {name, _value} -> name =~ "x-amz-checksum" end)
    end

    test "BadDigest is a checksum mismatch" do
      stub([response(400, error_xml("BadDigest"))])

      assert {:error, %Fil.ChecksumMismatchError{reason: "BadDigest"}} =
               Fil.write(disk(), "a.txt", "Hello", checksum: :sha256)
    end

    test "stat returns the stored checksum" do
      stub([response(200, "", [{"content-length", "5"}, {"x-amz-checksum-crc32", "99GJgg=="}])])

      assert {:ok, %Fil.Stat{checksum: {:crc32, "99GJgg=="}}} = Fil.stat(disk(), "a.txt", checksum: :crc32)
      assert header(request!(), "x-amz-checksum-mode") == "ENABLED"
    end

    test "stat without a stored checksum for the algorithm" do
      stub([response(200, "", [{"x-amz-checksum-crc32", "99GJgg=="}])])
      assert {:ok, %Fil.Stat{checksum: nil}} = Fil.stat(disk(), "a.txt", checksum: :sha256)

      stub([response(200, "", [{"x-amz-checksum-crc32", "99GJgg=="}])])
      assert {:ok, %Fil.Stat{checksum: nil}} = Fil.stat(disk(), "a.txt")
      assert header(request!(), "x-amz-checksum-mode") == nil
    end

    test "a read verifies the stored checksum when asked" do
      stub([response(200, "Hello", [{"x-amz-checksum-sha256", @checksums[:sha256]}])])

      assert Fil.read(disk(), "a.txt", verify_checksum: true) == {:ok, "Hello"}
      assert header(request!(), "x-amz-checksum-mode") == "ENABLED"
    end

    test "a read with a mismatching checksum fails" do
      stub([response(200, "Hellø", [{"x-amz-checksum-sha256", @checksums[:sha256]}])])

      assert {:error, %Fil.ChecksumMismatchError{reason: :checksum_mismatch}} =
               Fil.read(disk(), "a.txt", verify_checksum: true)
    end

    test "a read skips checksums it can't verify" do
      # A multipart checksum covers the parts, and CRC64NVME isn't supported.
      stub([
        response(200, "Hello", [
          {"x-amz-checksum-sha256", "abc=-3"},
          {"x-amz-checksum-crc64nvme", "AAAAAAAAAAA="}
        ])
      ])

      assert Fil.read(disk(), "a.txt", verify_checksum: true) == {:ok, "Hello"}
    end

    test "a read without the option doesn't verify" do
      stub([response(200, "Hellø", [{"x-amz-checksum-sha256", @checksums[:sha256]}])])

      assert Fil.read(disk(), "a.txt") == {:ok, "Hellø"}
      assert header(request!(), "x-amz-checksum-mode") == nil
    end
  end

  defp disk(opts \\ []) do
    [
      adapter: S3,
      bucket: "bucket",
      region: "eu-central-1",
      access_key_id: @access_key_id,
      secret_access_key: @secret_access_key,
      req_options: req_options()
    ]
    |> Keyword.merge(opts)
    |> Fil.disk()
  end

  defp parts_disk(opts \\ []), do: disk([part_size: @part] ++ opts)

  # The adapter's limit of 10,000 parts can't be reached in a unit test, so the tests lower it in the disk's state.
  defp max_parts(%Fil.Disk{adapter: {S3, state}} = disk, max_parts) do
    %{disk | adapter: {S3, %{state | max_parts: max_parts}}}
  end

  # Two parts: a whole one and a byte.
  defp large_stream do
    @part
    |> Kernel.+(1)
    |> then(&:binary.copy("a", &1))
    |> chunked(@mib)
  end

  # `size` bytes in chunks of 1 MiB, then calls `fun` for the next chunk.
  defp raising_after(size, fun) do
    size
    |> then(&:binary.copy("a", &1))
    |> chunked(@mib)
    |> Stream.concat(Stream.map([:next], fn _next -> fun.() end))
  end

  defp assert_aborted(requests) do
    abort = List.last(requests)

    assert {abort.method, abort.request_path, abort.query_params} == {"DELETE", "/a.bin", %{"uploadId" => "UP"}}
  end

  defp part_response(etag), do: response(200, "", [{"etag", ~s("#{etag}")}])

  defp initiate_xml(id) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Bucket>bucket</Bucket><Key>a.bin</Key><UploadId>#{id}</UploadId>
    </InitiateMultipartUploadResult>
    """
  end

  defp completed_xml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Bucket>bucket</Bucket><Key>a.bin</Key><ETag>"3858f62230ac3c915f300c664312c11f-2"</ETag>
    </CompleteMultipartUploadResult>
    """
  end

  # The part numbers and ETags of a CompleteMultipartUpload request, in order.
  defp completed_parts(request) do
    {:ok, completion} = Fil.Support.XML.parse(request.assigns.body)

    for part <- Fil.Support.XML.children(completion, "Part") do
      {Fil.Support.XML.text(part, "PartNumber"), Fil.Support.XML.text(part, "ETag")}
    end
  end

  defp sha256(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end

  defp query(url) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
  end

  defp signature(url) do
    url
    |> query()
    |> Map.fetch!("X-Amz-Signature")
  end

  defp error_xml(code) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>#{code}</Code><Message>Nope</Message><RequestId>ABC</RequestId></Error>
    """
  end

  defp list_page_one do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>bucket</Name>
      <Prefix>photos/</Prefix>
      <Delimiter>/</Delimiter>
      <KeyCount>2</KeyCount>
      <MaxKeys>1000</MaxKeys>
      <IsTruncated>true</IsTruncated>
      <NextContinuationToken>1ueGcxLPRx1Tr</NextContinuationToken>
      <Contents>
        <Key>photos/a.jpg</Key>
        <LastModified>2026-01-02T03:04:05.000Z</LastModified>
        <ETag>&quot;a0a0a0&quot;</ETag>
        <Size>1024</Size>
        <StorageClass>STANDARD</StorageClass>
      </Contents>
      <CommonPrefixes><Prefix>photos/2025/</Prefix></CommonPrefixes>
    </ListBucketResult>
    """
  end

  defp list_page_two do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>bucket</Name>
      <Prefix>photos/</Prefix>
      <IsTruncated>false</IsTruncated>
      <Contents>
        <Key>photos/b.jpg</Key>
        <LastModified>2026-02-03T04:05:06.000Z</LastModified>
        <ETag>&quot;b0b0b0&quot;</ETag>
        <Size>2048</Size>
      </Contents>
      <CommonPrefixes><Prefix>photos/2026/</Prefix></CommonPrefixes>
    </ListBucketResult>
    """
  end

  defp list_with_marker do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult>
      <IsTruncated>false</IsTruncated>
      <Contents><Key>photos/</Key><Size>0</Size></Contents>
      <Contents><Key>photos/a.jpg</Key><Size>1</Size></Contents>
    </ListBucketResult>
    """
  end

  defp list_recursive do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult>
      <IsTruncated>false</IsTruncated>
      <Contents><Key>photos/a.jpg</Key><Size>1</Size></Contents>
      <Contents><Key>photos/2026/b.jpg</Key><Size>2</Size></Contents>
    </ListBucketResult>
    """
  end

  defp list_sibling_prefix do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult>
      <IsTruncated>false</IsTruncated>
      <Contents><Key>photos/a.jpg</Key><Size>1</Size></Contents>
      <Contents><Key>photos.txt</Key><Size>2</Size></Contents>
    </ListBucketResult>
    """
  end

  defp list_under_root do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult>
      <IsTruncated>false</IsTruncated>
      <Contents><Key>uploads/photos/a.jpg</Key><Size>1</Size></Contents>
      <CommonPrefixes><Prefix>uploads/photos/2026/</Prefix></CommonPrefixes>
    </ListBucketResult>
    """
  end

  defp list_under_root_recursive do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult>
      <IsTruncated>false</IsTruncated>
      <Contents><Key>uploads/photos/a.jpg</Key><Size>1</Size></Contents>
      <Contents><Key>uploads/photos.txt</Key><Size>2</Size></Contents>
    </ListBucketResult>
    """
  end

  defp empty_list do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult><KeyCount>0</KeyCount><IsTruncated>false</IsTruncated></ListBucketResult>
    """
  end

  ## ------------------------------------------------------------------
  ## Stubbed requests
  ##
  ## Every disk in this module sends its requests to the `Req.Test` stub named after the module, so no request reaches
  ## the network. `stub/1` expects one request per response, in order, and `Req.Test.verify_on_exit!/1` checks that
  ## every response was used. Req runs the stub after all its own request steps, and the stub messages the test each
  ## `Plug.Conn` it gets (the body read into `conn.assigns.body`), so the tests check what the adapter sent. It sends to
  ## the pid `stub/1` bound, not `self()`, so a request from another process still reaches the test.
  ## ------------------------------------------------------------------

  defp req_options, do: [plug: {Req.Test, __MODULE__}]

  # Starts over: the responses of the previous `stub/1` must all have been used, and its requests are dropped.
  defp stub(responses) do
    Req.Test.verify!(__MODULE__)
    _previous = requests()
    test = self()

    for response <- responses, do: Req.Test.expect(__MODULE__, &respond(&1, response, test))
  end

  defp respond(conn, response, test) do
    {:ok, body, conn} = read_body(conn)
    request = assign(conn, :body, body)
    send(test, {__MODULE__, request})
    reply(conn, response)
  end

  defp reply(conn, {:error, reason}), do: Req.Test.transport_error(conn, reason)

  # A list body is sent in chunks, so a download gets them one by one.
  defp reply(conn, %{status: status, body: chunks, headers: headers}) when is_list(chunks) do
    conn =
      conn
      |> merge_resp_headers(headers)
      |> send_chunked(status)

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = chunk(conn, chunk)
      conn
    end)
  end

  defp reply(conn, %{status: status, body: body, headers: headers}) do
    conn
    |> merge_resp_headers(headers)
    |> send_resp(status, body)
  end

  defp response(status, body \\ "", headers \\ []), do: %{status: status, body: body, headers: headers}

  # The requests since the last `stub/1`, oldest first. Reading them takes them out of the mailbox.
  defp requests(received \\ []) do
    receive do
      {__MODULE__, request} -> requests([request | received])
    after
      0 -> Enum.reverse(received)
    end
  end

  defp request! do
    case requests() do
      [request] -> request
      other -> flunk("expected exactly one request, got #{length(other)}")
    end
  end

  defp header(request, name) do
    request
    |> get_req_header(name)
    |> List.first()
  end
end
