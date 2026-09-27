defmodule Fil.Adapter.S3Test do
  alias Fil.Adapter.S3

  use ExUnit.Case, async: true

  setup do
    Fil.ReqStub.stub(&adapter/1)
  end

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
      assert params(request!()) == %{"extra" => "1"}
    end

    test "rejects req_options that aren't a keyword list" do
      assert {:error, %NimbleOptions.ValidationError{key: :req_options}} = S3.init(bucket: "b", req_options: "nope")
    end
  end

  describe "addressing" do
    test "virtual-hosted by default" do
      stub([response(200, "content")])

      assert {:ok, "content"} = Fil.read(disk(), "a.txt")

      assert request!().url == "https://bucket.s3.eu-central-1.amazonaws.com/a.txt"
    end

    test "path style on request" do
      stub([response(200, "content")])

      disk = disk(path_style: true)

      assert {:ok, "content"} = Fil.read(disk, "a.txt")

      assert request!().url == "https://s3.eu-central-1.amazonaws.com/bucket/a.txt"
    end

    test "a custom endpoint" do
      stub([response(200, "content")])

      disk = disk(endpoint: "http://localhost:9000")

      assert {:ok, "content"} = Fil.read(disk, "a.txt")

      assert request!().url == "http://localhost:9000/bucket/a.txt"
    end

    test "an endpoint with a base path" do
      stub([response(200, "content")])

      disk = disk(endpoint: "https://s3.example.com/storage/")

      assert {:ok, "content"} = Fil.read(disk, "a.txt")

      assert request!().url == "https://s3.example.com/storage/bucket/a.txt"
    end

    test "encodes each path segment" do
      stub([response(200, "content")])

      assert {:ok, "content"} = Fil.read(disk(), "a b/ünï/#hash.txt")

      assert request!().url ==
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

      assert Enum.map(requests(), &path/1) == ["/uploads/avatars/a.png", "/uploads/b.png"]
    end

    test "lists under the root and strips it from the paths" do
      stub([response(200, list_under_root())])

      disk = disk(root: "uploads")

      assert {:ok, refs} = Fil.ls(disk, "photos")

      assert Enum.map(refs, & &1.path) == ["photos/2026", "photos/a.jpg"]
      assert params(request!()) == %{"list-type" => "2", "prefix" => "uploads/photos/", "delimiter" => "/"}
    end

    test "the disk root lists the root prefix" do
      stub([response(200, empty_list())])

      disk = disk(root: "uploads")

      assert {:ok, []} = Fil.ls(disk)
      assert params(request!()) == %{"list-type" => "2", "prefix" => "uploads/", "delimiter" => "/"}
    end

    test "rm_rf deletes by full key" do
      stub([response(200, list_under_root_recursive()), response(204)])

      disk = disk(root: "uploads")

      assert {:ok, 1} = Fil.rm_rf(disk, "photos")

      [list, delete] = requests()

      assert params(list) == %{"list-type" => "2", "prefix" => "uploads/photos"}
      assert path(delete) == "/uploads/photos/a.jpg"
    end

    test "copies from a key under the root" do
      stub([response(200, "<CopyObjectResult/>")])

      disk = disk(root: "uploads")

      assert {:ok, _} = Fil.cp(disk, "a.jpg", "b.jpg")

      assert path(request!()) == "/uploads/b.jpg"
      assert header(request!(), "x-amz-copy-source") == "/bucket/uploads/a.jpg"
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
      assert request.method == :put
      assert request.body == "Hello, World"
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

  describe "rm/1" do
    test "is idempotent" do
      stub([response(204), response(404)])

      assert {:ok, _} = Fil.rm(disk(), "a.txt")
      assert {:ok, _} = Fil.rm(disk(), "a.txt")

      assert Enum.map(requests(), & &1.method) == [:delete, :delete]
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
      assert request.method == :put
      assert request.url == "https://bucket.s3.eu-central-1.amazonaws.com/copies/a.txt"
      assert header(request, "x-amz-copy-source") == "/bucket/a%20b.txt"
    end

    test "copy notices a failure reported inside a 200" do
      stub([response(200, error_xml("InternalError"))])

      assert {:error, %Fil.UnavailableError{reason: "InternalError"}} = Fil.cp(disk(), "a.txt", "b.txt")
    end

    test "a missing source is not found" do
      stub([response(404, error_xml("NoSuchKey")), response(400, error_xml("NoSuchKey"))])

      assert {:error, %Fil.NotFoundError{path: "a.txt"}} = Fil.cp(disk(), "a.txt", "b.txt")
      assert {:error, %Fil.NotFoundError{path: "a.txt"}} = Fil.cp(disk(), "a.txt", "b.txt")
    end

    test "a plain 400 checks whether the source exists" do
      stub([response(400, error_xml("InvalidArgument")), response(404)])

      assert {:error, %Fil.NotFoundError{reason: {:http_status, 404}}} = Fil.cp(disk(), "a.txt", "b.txt")
      assert [%{method: :put}, %{method: :head, url: url}] = requests()
      assert url == "https://bucket.s3.eu-central-1.amazonaws.com/a.txt"

      stub([response(400, error_xml("InvalidArgument")), response(200)])

      assert {:error, %Fil.UnknownError{reason: "InvalidArgument"}} = Fil.cp(disk(), "a.txt", "b.txt")
    end

    test "rename copies and then deletes" do
      stub([response(200, "<CopyObjectResult/>"), response(204)])

      assert {:ok, ref} = Fil.rename(disk(), "a.txt", "b.txt")

      assert ref.path == "b.txt"
      assert Enum.map(requests(), & &1.method) == [:put, :delete]
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

      assert params(first) == %{"list-type" => "2", "prefix" => "photos/", "delimiter" => "/"}

      assert params(second) == %{
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

      assert params(request!()) == %{"list-type" => "2", "prefix" => "photos/"}
    end

    test "the disk root lists without a prefix" do
      stub([response(200, list_page_two())])

      assert {:ok, _} = Fil.ls(disk())

      assert params(request!()) == %{"list-type" => "2", "prefix" => "", "delimiter" => "/"}
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
      assert request!().method == :head
    end

    test "falls back to a prefix probe" do
      stub([response(404), response(200, list_page_two())])

      assert {:ok, %Fil.Stat{type: :directory}} = Fil.stat(disk(), "photos")
      assert Enum.map(requests(), & &1.method) == [:head, :get]
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

      assert params(list) == %{"list-type" => "2", "prefix" => "photos"}
      assert Enum.map([first, second], & &1.method) == [:delete, :delete]

      assert Enum.map([first, second], &path/1) == [
               "/photos/a.jpg",
               "/photos/2026/b.jpg"
             ]
    end

    test "ignores keys that only share a name prefix" do
      stub([response(200, list_sibling_prefix()), response(204)])

      assert {:ok, 1} = Fil.rm_rf(disk(), "photos")

      [_list, delete] = requests()

      assert path(delete) == "/photos/a.jpg"
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
      disk = disk(endpoint: "http://localhost:8333")

      assert Fil.url(disk, "cv.pdf") == {:ok, "http://localhost:8333/bucket/cv.pdf"}
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
      assert String.starts_with?(request!().url, "http://s3mock:9090/bucket/cv.pdf")
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

      refute Enum.any?(request!().headers, fn {name, _value} -> name =~ "x-amz-checksum" end)
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
  ## Every disk in this module uses `Fil.ReqStub`, which calls `adapter/1`, so no request reaches the network. Req runs
  ## the adapter in the test process, after all its own request steps. `stub/1` queues one response per request, and
  ## each request is recorded, so the tests can check what the adapter sent.
  ## ------------------------------------------------------------------

  defp req_options, do: [adapter: Fil.ReqStub]

  defp stub(responses) do
    Process.put(:responses, responses)
    Process.put(:requests, [])
    :ok
  end

  defp adapter(request) do
    case Process.get(:responses, []) do
      [response | rest] ->
        Process.put(:responses, rest)
        Process.put(:requests, [recorded(request) | Process.get(:requests, [])])
        {request, respond(response)}

      [] ->
        flunk("no stubbed response left for #{request.method} #{request.url}")
    end
  end

  defp response(status, body \\ "", headers \\ []), do: %{status: status, body: body, headers: headers}

  defp respond({:error, reason}), do: %Req.TransportError{reason: reason}

  defp respond(%{status: status, body: body, headers: headers}),
    do: Req.Response.new(status: status, body: body, headers: headers)

  defp recorded(request) do
    headers = for {name, values} <- request.headers, value <- values, do: {name, value}

    %{
      method: request.method,
      url: URI.to_string(request.url),
      headers: headers,
      body: IO.iodata_to_binary(request.body || "")
    }
  end

  defp requests do
    :requests
    |> Process.get([])
    |> Enum.reverse()
  end

  defp request! do
    case requests() do
      [request] -> request
      other -> flunk("expected exactly one request, got #{length(other)}")
    end
  end

  defp header(%{headers: headers}, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end

  defp params(%{url: url}) do
    case URI.parse(url).query do
      nil -> %{}
      query -> URI.decode_query(query)
    end
  end

  defp path(%{url: url}), do: URI.parse(url).path
end
