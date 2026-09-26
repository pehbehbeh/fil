defmodule Fil.PlugTest do
  alias Fil.Plugin.URL

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  @moduletag :tmp_dir

  @base_url "http://localhost/storage"

  setup %{tmp_dir: tmp_dir} do
    Fil.Adapter.Memory.checkout()

    local =
      [adapter: Fil.Adapter.Local, root: tmp_dir]
      |> Fil.disk()
      |> URL.attach(base_url: @base_url, secret: "local-secret")

    memory =
      [adapter: Fil.Adapter.Memory, root: "uploads"]
      |> Fil.disk()
      |> URL.attach(base_url: @base_url, secret: "memory-secret")

    {:ok, local: local, memory: memory}
  end

  # The disk comes from a describe tag, because Elixir 1.16 doesn't allow `unquote` in a test's context pattern.
  for adapter <- [:local, :memory] do
    describe "#{adapter} disk" do
      @describetag adapter: adapter

      setup context do
        {:ok, disk: Map.fetch!(context, context.adapter)}
      end

      test "GET downloads the file", %{disk: disk} do
        {:ok, _} = Fil.write(disk, "docs/a file.txt", "content")
        {:ok, url} = Fil.signed_url(disk, "docs/a file.txt")

        conn = request(:get, url, disk)

        assert conn.status == 200
        assert conn.resp_body == "content"
        assert get_resp_header(conn, "content-type") == ["text/plain"]
      end

      test "HEAD answers without a body", %{disk: disk} do
        {:ok, _} = Fil.write(disk, "a.txt", "content")
        {:ok, url} = Fil.signed_url(disk, "a.txt")

        conn = request(:head, url, disk)

        assert conn.status == 200
        assert conn.resp_body == ""
      end

      test "PUT uploads the body", %{disk: disk} do
        {:ok, url} = Fil.signed_url(disk, "inbox/new.bin", method: :put)

        conn = request(:put, url, disk, "uploaded")

        assert conn.status == 200
        assert Fil.read(disk, "inbox/new.bin") == {:ok, "uploaded"}
      end

      test "a URL signed for GET can't upload", %{disk: disk} do
        {:ok, url} = Fil.signed_url(disk, "a.txt")

        conn = request(:put, url, disk, "nope")

        assert conn.status == 403
        refute Fil.exists?(disk, "a.txt")
      end

      test "a changed path or expiry is rejected", %{disk: disk} do
        {:ok, _} = Fil.write(disk, "a.txt", "a")
        {:ok, _} = Fil.write(disk, "b.txt", "b")
        {:ok, url} = Fil.signed_url(disk, "a.txt")

        assert request(:get, String.replace(url, "a.txt", "b.txt"), disk).status == 403
        assert request(:get, String.replace(url, ~r/expires=\d+/, "expires=9999999999"), disk).status == 403
        assert request(:get, String.replace(url, ~r/&signature=.*/, ""), disk).status == 403
      end

      test "an expired URL is rejected", %{disk: disk} do
        {:ok, _} = Fil.write(disk, "a.txt", "a")
        {:ok, url} = Fil.signed_url(disk, "a.txt", expires_in: 1)

        # Signed with an expiry in the past: the same signature a URL gets once its time is up.
        expired = URL.sign(@base_url, URL.secret(disk), "a.txt", expires_in: -1)

        assert request(:get, url, disk).status == 200

        conn = request(:get, expired, disk)
        assert conn.status == 403
        assert conn.resp_body == "the URL has expired"
      end

      test "a missing file is a 404", %{disk: disk} do
        {:ok, url} = Fil.signed_url(disk, "nope.txt")

        assert request(:get, url, disk).status == 404
      end

      test "other methods are not allowed", %{disk: disk} do
        {:ok, url} = Fil.signed_url(disk, "a.txt")

        assert request(:delete, url, disk).status == 405
      end
    end
  end

  test "keeps the content type of the upload and of the disk", %{memory: disk} do
    {:ok, put_url} = Fil.signed_url(disk, "data", method: :put)

    conn =
      :put
      |> conn(URI.parse(put_url).path <> "?" <> URI.parse(put_url).query, "{}")
      |> put_req_header("content-type", "application/json")
      |> call(disk)

    assert conn.status == 200
    assert {:ok, %Fil.Stat{content_type: "application/json"}} = Fil.stat(disk, "data")

    {:ok, get_url} = Fil.signed_url(disk, "data")
    assert get_resp_header(request(:get, get_url, disk), "content-type") == ["application/json"]
  end

  describe "errors" do
    test "a failed write gets the status of its error", %{memory: disk} do
      for {error, status} <- [
            {%Fil.AlreadyExistsError{reason: :eexist}, 409},
            {%Fil.StorageFullError{reason: :enospc}, 507},
            {%Fil.UnavailableError{reason: :timeout}, 503}
          ] do
        failing = failing_writes(disk, error)
        {:ok, url} = Fil.signed_url(failing, "a.txt", method: :put)

        assert request(:put, url, failing, "content").status == status
      end
    end

    test "a denied file is a 404, like a missing one", %{memory: disk} do
      {:ok, _} = Fil.write(disk, "secret.txt", "secret")

      denied =
        Fil.attach(disk, :deny, fn
          %Fil.Op{name: name} = op, _next, _opts when name in [:stat, :read] ->
            Fil.Op.put_result(op, {:error, %Fil.AccessDeniedError{reason: :eacces}})

          op, next, _opts ->
            next.(op)
        end)

      {:ok, url} = Fil.signed_url(denied, "secret.txt")

      assert request(:get, url, denied).status == 404
    end

    @tag :capture_log
    test "any other error is a 500 that keeps the details in the log", %{memory: disk} do
      failing = failing_writes(disk, %Fil.UnknownError{reason: "InvalidArgument"})
      {:ok, url} = Fil.signed_url(failing, "a.txt", method: :put)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = request(:put, url, failing, "content")

          assert conn.status == 500
          assert conn.resp_body == "internal server error"
        end)

      assert log =~ ~s|could not write "a.txt"|
      assert log =~ "InvalidArgument"
    end
  end

  describe "upload size" do
    test "a declared size over :max_body_size is a 413 before anything is read", %{memory: disk} do
      {:ok, url} = Fil.signed_url(disk, "big.bin", method: :put)

      conn =
        url
        |> put("0123456789", [{"content-length", "10"}])
        |> call(disk, max_body_size: 5)

      assert conn.status == 413
      assert conn.resp_body == "the request body is larger than 5 bytes"
      refute Fil.exists?(disk, "big.bin")
    end

    test "a body over :max_body_size without a declared size is a 413 too", %{memory: disk} do
      {:ok, url} = Fil.signed_url(disk, "big.bin", method: :put)

      assert (url
              |> put("0123456789")
              |> call(disk, max_body_size: 5)).status == 413

      refute Fil.exists?(disk, "big.bin")
    end

    test "a body up to :max_body_size is written", %{memory: disk} do
      {:ok, url} = Fil.signed_url(disk, "small.bin", method: :put)

      assert (url
              |> put("01234", [{"content-length", "5"}])
              |> call(disk, max_body_size: 5)).status == 200

      assert Fil.read(disk, "small.bin") == {:ok, "01234"}
    end

    test "a body Plug.Parsers already read is a 400, not an empty file", %{memory: disk} do
      {:ok, url} = Fil.signed_url(disk, "data.json", method: :put)
      parsers = Plug.Parsers.init(parsers: [:json], json_decoder: Jason, pass: ["*/*"])

      conn =
        url
        |> put(~s({"a":1}), [{"content-type", "application/json"}, {"content-length", "7"}])
        |> Plug.Parsers.call(parsers)
        |> call(disk)

      assert conn.status == 400
      assert conn.resp_body =~ "already read"
      refute Fil.exists?(disk, "data.json")
    end
  end

  test "resolves the disk from a function or an MFA", %{memory: disk} do
    {:ok, _} = Fil.write(disk, "a.txt", "a")
    {:ok, url} = Fil.signed_url(disk, "a.txt")

    assert request(:get, url, fn -> disk end).status == 200
    assert request(:get, url, {Function, :identity, [disk]}).status == 200
  end

  test "proxies an S3 disk" do
    # A stubbed S3: HeadObject and GetObject answer from the test, PutObject records the body.
    adapter = fn request ->
      case request.method do
        :head ->
          {request, Req.Response.new(status: 200, headers: [{"content-type", "application/pdf"}])}

        :get ->
          {request, Req.Response.new(status: 200, body: "%PDF")}

        :put ->
          send(self(), {:put, URI.to_string(request.url), request.body})
          {request, Req.Response.new(status: 200)}
      end
    end

    disk =
      [adapter: Fil.Adapter.S3, bucket: "bucket", req_options: [adapter: adapter]]
      |> Fil.disk()
      |> URL.attach(base_url: @base_url, secret: "s3-secret")

    {:ok, url} = Fil.signed_url(disk, "q3.pdf")
    assert String.starts_with?(url, @base_url)

    conn = request(:get, url, disk)
    assert conn.status == 200
    assert conn.resp_body == "%PDF"
    assert get_resp_header(conn, "content-type") == ["application/pdf"]

    {:ok, put_url} = Fil.signed_url(disk, "inbox/new.bin", method: :put)
    assert request(:put, put_url, disk, "uploaded").status == 200
    assert_received {:put, "https://bucket.s3.us-east-1.amazonaws.com/inbox/new.bin", "uploaded"}
  end

  test "passes requests for a disk that doesn't sign URLs through", %{tmp_dir: tmp_dir} do
    local = Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)
    s3 = Fil.disk(adapter: Fil.Adapter.S3, bucket: "bucket")

    for disk <- [local, s3] do
      conn = request(:get, "http://localhost/storage/a.txt?expires=1&signature=x", disk)

      assert conn.state == :unset
      refute conn.halted
    end
  end

  describe "public: true" do
    test "serves downloads without a signature, on a disk with or without the plugin", %{tmp_dir: tmp_dir} do
      plain = Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)
      signing = URL.attach(plain, base_url: @base_url, secret: "secret")
      {:ok, _} = Fil.write(plain, "avatars/1.png", "png")

      for disk <- [plain, signing] do
        conn = public_request(:get, "/storage/avatars/1.png", disk)

        assert conn.status == 200
        assert conn.resp_body == "png"
        assert get_resp_header(conn, "content-type") == ["image/png"]
        assert public_request(:head, "/storage/avatars/1.png", disk).resp_body == ""
      end
    end

    test "serves the URLs Fil.url/2 builds", %{memory: disk} do
      {:ok, _} = Fil.write(disk, "avatars/a 1.png", "png")
      {:ok, url} = Fil.url(disk, "avatars/a 1.png")

      assert public_request(:get, URI.parse(url).path, disk).resp_body == "png"
    end

    test "answers 404 for missing files and directories", %{memory: disk} do
      {:ok, _} = Fil.write(disk, "avatars/1.png", "png")

      assert public_request(:get, "/storage/avatars/2.png", disk).status == 404
      assert public_request(:get, "/storage/avatars", disk).status == 404
      assert public_request(:get, "/storage", disk).status == 404
    end

    test "keeps paths inside the disk root", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "secret")
      disk = Fil.disk(adapter: Fil.Adapter.Local, root: Path.join(tmp_dir, "public"))

      assert public_request(:get, "/storage/../secret.txt", disk).status == 404
      assert public_request(:get, "/storage/%2E%2E/secret.txt", disk).status == 404
    end

    test "uploads still need a signed URL", %{tmp_dir: tmp_dir, memory: signing} do
      plain = Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)

      conn = public_request(:put, "/storage/new.txt", plain, "nope")
      assert conn.status == 403
      assert conn.resp_body == "uploads need a signed URL"
      refute Fil.exists?(plain, "new.txt")

      assert public_request(:put, "/storage/new.txt", signing, "nope").status == 403

      {:ok, put_url} = Fil.signed_url(signing, "new.txt", method: :put)
      uri = URI.parse(put_url)
      assert public_request(:put, uri.path <> "?" <> uri.query, signing, "yes").status == 200
      assert Fil.read(signing, "new.txt") == {:ok, "yes"}
    end
  end

  describe "at:" do
    test "serves only under its path and halts", %{memory: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "a")
      {:ok, url} = Fil.signed_url(disk, "a.txt")
      opts = Fil.Plug.init(at: "/storage", disk: disk)
      uri = URI.parse(url)

      served = Fil.Plug.call(conn(:get, uri.path <> "?" <> uri.query), opts)

      assert served.status == 200
      assert served.halted
      assert served.path_info == ["storage", "a.txt"]

      passed = Fil.Plug.call(conn(:get, "/other/a.txt"), opts)

      refute passed.halted
      assert passed.state == :unset
    end
  end

  # Mounted like `forward "/storage", Fil.Plug, disk: disk`: the prefix is stripped from `path_info`, and
  # `request_path` keeps it.
  defp failing_writes(disk, error) do
    Fil.attach(disk, :failing, fn
      %Fil.Op{name: :write} = op, _next, _opts -> Fil.Op.put_result(op, {:error, error})
      op, next, _opts -> next.(op)
    end)
  end

  defp request(method, url, disk, body \\ nil) do
    uri = URI.parse(url)

    method
    |> conn(uri.path <> "?" <> (uri.query || ""), body)
    |> call(disk)
  end

  defp public_request(method, path, disk, body \\ nil) do
    method
    |> conn(path, body)
    |> Fil.Plug.call(Fil.Plug.init(at: "/storage", disk: disk, public: true))
  end

  defp call(conn, disk, opts \\ []) do
    conn = %{conn | path_info: Enum.drop(conn.path_info, 1), script_name: ["storage"]}

    Fil.Plug.call(conn, Fil.Plug.init([disk: disk] ++ opts))
  end

  defp put(url, body, headers \\ []) do
    uri = URI.parse(url)

    Enum.reduce(headers, conn(:put, uri.path <> "?" <> uri.query, body), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
  end
end
