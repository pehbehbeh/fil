defmodule Fil.PlugTest do
  alias Fil.Plugin.URL

  use ExUnit.Case, async: true, parameterize: Fil.DiskHelper.adapters()

  import Fil.PlugHelper
  import Plug.Conn
  import Plug.Test

  @moduletag :tmp_dir

  @base_url "http://localhost/storage"

  setup context do
    disk =
      context
      |> Fil.DiskHelper.disk()
      |> URL.attach(base_url: @base_url, secret: "secret")

    {:ok, disk: disk}
  end

  describe "signed URLs" do
    test "HEAD sends the headers of a GET, without a body", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "7f3a.txt", "content")
      {:ok, url} = Fil.signed_url(disk, "7f3a.txt", disposition: {:attachment, "Rechnung März.txt"})

      conn = request(:head, url, disk)

      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == ["text/plain"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="Rechnung M_rz.txt"; filename*=UTF-8''Rechnung%20M%C3%A4rz.txt)
             ]
    end

    test "a URL signed with if_exists: :error is a 409 the second time, with or without if-none-match", %{disk: disk} do
      opts = [method: :put, content_type: "image/png", size: 3, if_exists: :error]
      {:ok, url} = Fil.signed_url(disk, "avatars/a.png", opts)
      headers = [{"content-type", "image/png"}, {"content-length", "3"}, {"if-none-match", "*"}]

      conn =
        url
        |> put("png", headers)
        |> call(disk)

      assert conn.status == 200
      assert Fil.read(disk, "avatars/a.png") == {:ok, "png"}

      # The plug writes with `if_exists: :error` because the URL says so, with or without the header.
      for headers <- [headers, List.keydelete(headers, "if-none-match", 0)] do
        conn =
          url
          |> put("new", headers)
          |> call(disk)

        assert conn.status == 409
      end

      assert Fil.read(disk, "avatars/a.png") == {:ok, "png"}
    end

    test "an upload that doesn't match its URL is a 403 and writes nothing", %{disk: disk} do
      {:ok, url} = Fil.signed_url(disk, "a.png", method: :put, content_type: "image/png", size: 3)
      headers = [{"content-type", "image/png"}, {"content-length", "3"}]

      for {headers, body} <- [
            {List.keyreplace(headers, "content-type", 0, {"content-type", "text/html"}), "png"},
            {List.keyreplace(headers, "content-length", 0, {"content-length", "4"}), "pngs"},
            {List.keydelete(headers, "content-type", 0), "png"},
            {List.keydelete(headers, "content-length", 0), "png"}
          ] do
        conn =
          url
          |> put(body, headers)
          |> call(disk)

        assert conn.status == 403
        assert conn.resp_body == "the upload doesn't match its signed URL"
      end

      refute Fil.exists?(disk, "a.png")
    end

    test "a changed path, method or expiry, or a missing signature, is a 403", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "a")
      {:ok, _} = Fil.write(disk, "b.txt", "b")
      {:ok, url} = Fil.signed_url(disk, "a.txt")
      {:ok, new_url} = Fil.signed_url(disk, "new.txt")

      assert request(:get, String.replace(url, "a.txt", "b.txt"), disk).status == 403
      assert request(:put, new_url, disk, "nope").status == 403
      refute Fil.exists?(disk, "new.txt")
      assert request(:get, String.replace(url, ~r/expires=\d+/, "expires=9999999999"), disk).status == 403
      assert request(:get, String.replace(url, ~r/&signature=.*/, ""), disk).status == 403
    end

    test "query parameters that aren't strings are rejected", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "a")
      {:ok, url} = Fil.signed_url(disk, "a.txt")

      assert request(:get, String.replace(url, "expires=", "expires[]="), disk).status == 403
      assert request(:get, String.replace(url, "signature=", "signature[]="), disk).status == 403
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

    test "a changed disposition is rejected", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "a")
      {:ok, plain} = Fil.signed_url(disk, "a.txt")
      {:ok, url} = Fil.signed_url(disk, "a.txt", disposition: :inline)

      assert request(:get, String.replace(url, "disposition=inline", "disposition=attachment"), disk).status == 403
      assert request(:get, String.replace(plain, "&signature", "&disposition=inline&signature"), disk).status == 403
      assert request(:get, String.replace(url, "disposition=inline&", ""), disk).status == 403
      assert request(:get, String.replace(url, "disposition=inline", "disposition[]=inline"), disk).status == 403
    end

    test "changed, unsigned or repeated query parameters are a 403", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "index.html", "<html>")
      {:ok, plain} = Fil.signed_url(disk, "index.html")
      {:ok, url} = Fil.signed_url(disk, "index.html", query: [{"trackingInfo", "7-42"}])

      assert request(:get, String.replace(url, "trackingInfo=7-42", "trackingInfo=8-42"), disk).status == 403
      assert request(:get, String.replace(url, "&signature", "&trackingInfo=7-42&signature"), disk).status == 403
      assert request(:get, String.replace(plain, "&signature", "&v=2&signature"), disk).status == 403
      assert request(:get, String.replace(plain, "expires=", "expires=1&expires="), disk).status == 403
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

  describe "errors" do
    test "a failed write gets the status of its error", %{disk: disk} do
      for {error, status} <- [
            {%Fil.AlreadyExistsError{reason: :eexist}, 409},
            {%Fil.ConflictError{reason: :size_changed}, 409},
            {%Fil.InvalidRequestError{reason: {:not_an_image, "not a PNG"}}, 422},
            {%Fil.InvalidRequestError{reason: "EntityTooLarge"}, 422},
            {%Fil.InvalidRequestError{reason: :enotdir}, 404},
            {%Fil.InvalidContentError{reason: {:too_large, 5}}, 413},
            {%Fil.InvalidContentError{reason: {:content_type, "image/gif"}}, 415},
            {%Fil.InvalidContentError{reason: {:content_type_mismatch, "image/png", "image/gif"}}, 415},
            {%Fil.InvalidContentError{reason: {:extension, "html"}}, 415},
            {%Fil.InvalidContentError{reason: {:too_small, 1}}, 422},
            {%Fil.InvalidContentError{reason: :custom}, 422},
            {%Fil.StorageFullError{reason: :enospc}, 507},
            {%Fil.UnavailableError{reason: :timeout}, 503}
          ] do
        failing = failing_writes(disk, error)
        {:ok, url} = Fil.signed_url(failing, "a.txt", method: :put)

        assert request(:put, url, failing, "content").status == status
      end
    end

    test "an upload a plugin rejects while it's read gets the status of its reason", %{disk: disk} do
      for {reason, status, body} <- [
            {{:too_large, 4}, 413, "the content is too large"},
            {{:content_type, nil}, 415, "the content type is not allowed"},
            {{:secret, "4111 1111 1111 1111"}, 422, "the content was rejected"}
          ] do
        rejecting =
          Fil.attach(disk, :reject, fn op, next, _opts ->
            op
            |> Fil.Op.scan_content(nil, fn _chunk, _acc -> raise %Fil.InvalidContentError{reason: reason} end)
            |> next.()
          end)

        {:ok, url} = Fil.signed_url(rejecting, "a.txt", method: :put)

        for headers <- [[{"content-length", "7"}], []] do
          conn =
            url
            |> put("content", headers)
            |> call(rejecting)

          assert {conn.status, conn.resp_body} == {status, body}
        end
      end

      refute Fil.exists?(disk, "a.txt")
    end

    test "a denied file is a 404, like a missing one", %{disk: disk} do
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
    test "any other error is a 500 that keeps the details in the log", %{disk: disk} do
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

    @tag :capture_log
    test "S3's InvalidRequest is a 500 that's logged, on an upload and a download", %{disk: disk} do
      error = %Fil.InvalidRequestError{reason: "InvalidRequest"}
      {:ok, _} = Fil.write(disk, "a.txt", "content")

      failing =
        Fil.attach(disk, :failing, fn
          %Fil.Op{name: name} = op, _next, _opts when name in [:write, :stat, :read] ->
            Fil.Op.put_result(op, {:error, error})

          op, next, _opts ->
            next.(op)
        end)

      {:ok, put_url} = Fil.signed_url(failing, "a.txt", method: :put)
      {:ok, get_url} = Fil.signed_url(failing, "a.txt")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for {method, url, body} <- [{:put, put_url, "content"}, {:get, get_url, nil}] do
            conn = request(method, url, failing, body)

            assert conn.status == 500
            assert conn.resp_body == "internal server error"
          end
        end)

      assert log =~ ~s|could not write "a.txt"|
      assert log =~ "InvalidRequest"
    end
  end

  describe "upload size" do
    test "a declared size over :max_body_size is a 413 before anything is read", %{disk: disk} do
      {:ok, url} = Fil.signed_url(disk, "big.bin", method: :put)

      conn =
        url
        |> put("0123456789", [{"content-length", "10"}])
        |> call(disk, max_body_size: 5)

      assert conn.status == 413
      assert conn.resp_body == "the request body is larger than 5 bytes"
      refute Fil.exists?(disk, "big.bin")
    end

    test "a body over :max_body_size without a declared size is a 413 too", %{disk: disk} do
      {:ok, url} = Fil.signed_url(disk, "big.bin", method: :put)

      assert (url
              |> put("0123456789")
              |> call(disk, max_body_size: 5)).status == 413

      refute Fil.exists?(disk, "big.bin")
    end

    test "a body up to :max_body_size is written", %{disk: disk} do
      {:ok, url} = Fil.signed_url(disk, "small.bin", method: :put)

      assert (url
              |> put("01234", [{"content-length", "5"}])
              |> call(disk, max_body_size: 5)).status == 200

      assert Fil.read(disk, "small.bin") == {:ok, "01234"}
    end

    test "a body Plug.Parsers already read is a 400, not an empty file", %{disk: disk} do
      {:ok, url} = Fil.signed_url(disk, "data.json", method: :put)
      parsers = Plug.Parsers.init(parsers: [:json], json_decoder: JSON, pass: ["*/*"])

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

  describe "streaming" do
    test "PUT streams the body into the write, with the content-length as its size", %{disk: disk} do
      test = self()

      recording =
        Fil.attach(disk, :record, fn op, next, _opts ->
          send(test, {:size, Fil.Op.get_option(op, :size)})

          op
          |> Fil.Op.update_content(
            stream:
              &Stream.map(&1, fn chunk ->
                send(test, {:chunk, byte_size(chunk)})
                chunk
              end)
          )
          |> next.()
        end)

      content = :crypto.strong_rand_bytes(2_500_000)
      {:ok, url} = Fil.signed_url(recording, "big.bin", method: :put)

      conn =
        url
        |> put(content, [{"content-length", "2500000"}])
        |> call(recording)

      assert conn.status == 200
      assert Fil.read(disk, "big.bin") == {:ok, content}
      assert_received {:size, 2_500_000}
      assert_received {:chunk, 1_048_576}
      assert_received {:chunk, 1_048_576}
      assert_received {:chunk, 402_848}
    end

    test "a body longer than its content-length is a 400", %{disk: disk} do
      {:ok, url} = Fil.signed_url(disk, "a.txt", method: :put)

      conn =
        url
        |> put("0123456789", [{"content-length", "5"}])
        |> call(disk)

      assert conn.status == 400
      assert conn.resp_body == "the request body could not be read"
      refute Fil.exists?(disk, "a.txt")
    end

    test "GET streams the file as a chunked response", %{disk: disk} do
      content = :crypto.strong_rand_bytes(300_000)
      {:ok, _} = Fil.write(disk, "big.bin", content)
      {:ok, url} = Fil.signed_url(disk, "big.bin")

      conn = request(:get, url, disk)

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.resp_body == content
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    end
  end

  describe "validators" do
    test "GET and HEAD send the etag, the modification time and accept-ranges", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "0123456789")
      {:ok, stat} = Fil.stat(disk, "a.txt")

      for method <- [:get, :head] do
        conn = download(disk, "a.txt", [], method)

        assert conn.status == 200
        assert get_resp_header(conn, "etag") == [~s("#{stat.etag}")]
        assert get_resp_header(conn, "last-modified") == [http_date(stat.mtime)]
        assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      end
    end

    test "If-None-Match with the etag is a 304, on GET and HEAD", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "0123456789")
      {:ok, stat} = Fil.stat(disk, "a.txt")
      etag = ~s("#{stat.etag}")

      for value <- [etag, "W/" <> etag, ~s("other", #{etag}), "*"], method <- [:get, :head] do
        conn = download(disk, "a.txt", [{"if-none-match", value}], method)

        assert conn.status == 304, "#{method} with If-None-Match: #{value}"
        assert conn.resp_body == ""
        assert get_resp_header(conn, "etag") == [etag]
        assert get_resp_header(conn, "last-modified") == [http_date(stat.mtime)]
      end

      conn = download(disk, "a.txt", [{"if-none-match", ~s("other")}])
      assert {conn.status, conn.resp_body} == {200, "0123456789"}
    end

    test "If-Modified-Since is a 304 for a file that hasn't changed since", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "0123456789")
      {:ok, stat} = Fil.stat(disk, "a.txt")
      modified = http_date(stat.mtime)

      later =
        stat.mtime
        |> DateTime.add(60)
        |> http_date()

      earlier =
        stat.mtime
        |> DateTime.add(-60)
        |> http_date()

      assert download(disk, "a.txt", [{"if-modified-since", modified}]).status == 304
      assert download(disk, "a.txt", [{"if-modified-since", later}]).status == 304
      assert download(disk, "a.txt", [{"if-modified-since", earlier}]).status == 200
      assert download(disk, "a.txt", [{"if-modified-since", "yesterday"}]).status == 200

      # If-None-Match decides when both are there.
      headers = [{"if-none-match", ~s("other")}, {"if-modified-since", modified}]
      assert download(disk, "a.txt", headers).status == 200
    end
  end

  describe "ranges" do
    test "one byte range is a 206 with its content range", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "0123456789")

      for {range, body, content_range} <- [
            {"bytes=2-4", "234", "bytes 2-4/10"},
            {"bytes=7-", "789", "bytes 7-9/10"},
            {"bytes=-3", "789", "bytes 7-9/10"},
            {"bytes=8-100", "89", "bytes 8-9/10"},
            {"bytes=-20", "0123456789", "bytes 0-9/10"},
            {"bytes=0-0", "0", "bytes 0-0/10"},
            {"Bytes=1-1", "1", "bytes 1-1/10"}
          ] do
        conn = download(disk, "a.txt", [{"range", range}])

        assert {conn.status, conn.resp_body} == {206, body}, range
        assert get_resp_header(conn, "content-range") == [content_range]
        assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      end
    end

    test "a range outside the file is a 416", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "0123456789")
      {:ok, _} = Fil.write(disk, "empty.txt", "")

      cases = [{"a.txt", "bytes=10-", 10}, {"a.txt", "bytes=-0", 10}, {"empty.txt", "bytes=0-", 0}]

      for {path, range, size} <- cases do
        conn = download(disk, path, [{"range", range}])

        assert conn.status == 416, range
        assert get_resp_header(conn, "content-range") == ["bytes */#{size}"]
      end
    end

    test "several ranges, invalid ones and other units get the whole file", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "0123456789")

      for range <- ["bytes=0-1,4-5", "bytes=5-2", "bytes=a-b", "bytes=1", "bytes=+1-2", "items=0-1", "bytes"] do
        conn = download(disk, "a.txt", [{"range", range}])

        assert {conn.status, conn.resp_body} == {200, "0123456789"}, range
        assert get_resp_header(conn, "content-range") == []
      end
    end

    test "a 416 has no disposition, and a 304 comes before the range", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "0123456789")
      {:ok, stat} = Fil.stat(disk, "a.txt")
      {:ok, url} = Fil.signed_url(disk, "a.txt", disposition: :attachment)
      uri = URI.parse(url)

      outside =
        :get
        |> conn(uri.path <> "?" <> uri.query)
        |> put_req_header("range", "bytes=20-")
        |> call(disk)

      assert outside.status == 416
      assert get_resp_header(outside, "content-disposition") == []
      assert get_resp_header(outside, "content-type") == ["text/plain; charset=utf-8"]

      headers = [{"range", "bytes=2-4"}, {"if-none-match", ~s("#{stat.etag}")}]
      assert download(disk, "a.txt", headers).status == 304
    end

    test "HEAD ignores the range", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "0123456789")

      assert download(disk, "a.txt", [{"range", "bytes=2-4"}], :head).status == 200
    end

    test "If-Range sends the range only for the same file", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "0123456789")
      {:ok, stat} = Fil.stat(disk, "a.txt")
      etag = ~s("#{stat.etag}")

      for {if_range, status} <- [
            {etag, 206},
            {http_date(stat.mtime), 206},
            {~s("other"), 200},
            {"W/" <> etag, 200},
            {stat.mtime
             |> DateTime.add(-60)
             |> http_date(), 200},
            {"yesterday", 200}
          ] do
        conn = download(disk, "a.txt", [{"range", "bytes=2-4"}, {"if-range", if_range}])

        assert conn.status == status, "If-Range: #{if_range}"
      end
    end

    test "a large file streams only its range", %{disk: disk} do
      content = :crypto.strong_rand_bytes(300_000)
      {:ok, _} = Fil.write(disk, "big.bin", content)

      conn = download(disk, "big.bin", [{"range", "bytes=100000-199999"}])

      assert conn.status == 206
      assert conn.state == :chunked
      assert conn.resp_body == binary_part(content, 100_000, 100_000)
      assert get_resp_header(conn, "content-range") == ["bytes 100000-199999/300000"]
    end

    test "a plugin that transforms reads serves ranges of the transformed content", %{disk: disk} do
      gzip =
        Fil.attach(disk, :gzip, fn
          %Fil.Op{name: :write} = op, next, _opts ->
            op
            |> Fil.Op.update_content(iodata: &:zlib.gzip/1)
            |> next.()

          %Fil.Op{name: :read} = op, next, _opts ->
            op
            |> next.()
            |> Fil.Op.update_result(iodata: &:zlib.gunzip/1)

          op, next, _opts ->
            next.(op)
        end)

      {:ok, _} = Fil.write(gzip, "a.txt", "0123456789")

      assert download(gzip, "a.txt", [{"range", "bytes=2-4"}]).resp_body == "234"
    end
  end

  describe "public: true" do
    test "serves the URLs Fil.url/2 builds", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "avatars/a 1.png", "png")
      {:ok, url} = Fil.url(disk, "avatars/a 1.png")

      assert public_request(:get, URI.parse(url).path, disk).resp_body == "png"
    end

    test "answers 404 for missing files and directories", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "avatars/1.png", "png")

      assert public_request(:get, "/storage/avatars/2.png", disk).status == 404
      assert public_request(:get, "/storage/avatars", disk).status == 404
      assert public_request(:get, "/storage", disk).status == 404
    end

    test "serves ranges and 304s", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "avatars/1.png", "0123456789")
      {:ok, stat} = Fil.stat(disk, "avatars/1.png")
      opts = Fil.Plug.init(at: "/storage", disk: disk, public: true)

      ranged =
        :get
        |> conn("/storage/avatars/1.png")
        |> put_req_header("range", "bytes=2-4")
        |> Fil.Plug.call(opts)

      assert {ranged.status, ranged.resp_body} == {206, "234"}

      cached =
        :get
        |> conn("/storage/avatars/1.png")
        |> put_req_header("if-none-match", ~s("#{stat.etag}"))
        |> Fil.Plug.call(opts)

      assert cached.status == 304
    end

    test "sets a disposition only from a valid signature", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "avatars/1.png", "png")
      {:ok, url} = Fil.signed_url(disk, "avatars/1.png", disposition: :attachment)
      %URI{path: path, query: query} = URI.parse(url)

      signed = public_request(:get, path <> "?" <> query, disk)
      assert get_resp_header(signed, "content-disposition") == [~s(attachment; filename="1.png")]

      unsigned = public_request(:get, path <> "?disposition=attachment", disk)
      assert unsigned.status == 200
      assert get_resp_header(unsigned, "content-disposition") == []

      tampered = public_request(:get, path <> "?" <> String.replace(query, "attachment", "inline"), disk)
      assert tampered.status == 200
      assert get_resp_header(tampered, "content-disposition") == []
    end
  end

  describe "at:" do
    test "serves only under its path and halts", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "a")
      {:ok, url} = Fil.signed_url(disk, "a.txt")
      opts = Fil.Plug.init(at: "/storage", disk: disk)
      uri = URI.parse(url)

      served =
        :get
        |> conn(uri.path <> "?" <> uri.query)
        |> Fil.Plug.call(opts)

      assert served.status == 200
      assert served.halted
      assert served.path_info == ["storage", "a.txt"]

      passed =
        :get
        |> conn("/other/a.txt")
        |> Fil.Plug.call(opts)

      refute passed.halted
      assert passed.state == :unset
    end
  end

  describe "send_file/3" do
    test "sends the file with its validators and keeps the headers set before", %{disk: disk} do
      {:ok, report} = Fil.write(disk, "reports/q3.csv", "a,b\n1,2\n")
      {:ok, stat} = Fil.stat(report)

      assert {:ok, conn} =
               :get
               |> conn("/download")
               |> put_resp_header("cache-control", "private")
               |> Fil.Plug.send_file(report)

      assert {conn.status, conn.state, conn.resp_body} == {200, :chunked, "a,b\n1,2\n"}
      assert get_resp_header(conn, "content-type") == ["text/csv"]
      assert get_resp_header(conn, "etag") == [~s("#{stat.etag}")]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "cache-control") == ["private"]
      assert get_resp_header(conn, "content-disposition") == []
    end

    test "takes a disk and a path, and a content type and a disposition", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "exports/7f3a", "a,b\n")

      for {disposition, header} <- [
            {:inline, "inline"},
            {:attachment, ~s(attachment; filename="7f3a")},
            {{:attachment, "Export März.csv"},
             ~s(attachment; filename="Export M_rz.csv"; filename*=UTF-8''Export%20M%C3%A4rz.csv)}
          ] do
        opts = [content_type: "text/csv", disposition: disposition]
        request = conn(:get, "/")
        {:ok, conn} = Fil.Plug.send_file(request, disk, "exports/7f3a", opts)

        assert conn.resp_body == "a,b\n"
        assert get_resp_header(conn, "content-type") == ["text/csv"]
        assert get_resp_header(conn, "content-disposition") == [header]
      end
    end

    test "answers conditional requests, ranges and HEAD", %{disk: disk} do
      {:ok, file} = Fil.write(disk, "a.txt", "0123456789")
      {:ok, stat} = Fil.stat(file)

      {:ok, not_modified} = send_with_headers(:get, file, [{"if-none-match", ~s("#{stat.etag}")}])
      assert {not_modified.status, not_modified.resp_body} == {304, ""}

      {:ok, part} = send_with_headers(:get, file, [{"range", "bytes=2-4"}], disposition: :attachment)
      assert {part.status, part.resp_body} == {206, "234"}
      assert get_resp_header(part, "content-range") == ["bytes 2-4/10"]
      assert get_resp_header(part, "content-disposition") == [~s(attachment; filename="a.txt")]

      {:ok, outside} = send_with_headers(:get, file, [{"range", "bytes=20-"}], disposition: :attachment)
      assert {outside.status, outside.resp_body} == {416, "the range is outside the file"}
      assert get_resp_header(outside, "content-disposition") == []

      {:ok, head} = send_with_headers(:head, file, [])
      assert {head.status, head.resp_body} == {200, ""}
      assert get_resp_header(head, "content-type") == ["text/plain"]
    end

    test "returns the error for a missing file or a directory, and sends nothing", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "reports/q3.csv", "a,b\n")
      conn = conn(:get, "/")

      assert {:error, %Fil.NotFoundError{path: "reports/q4.csv"}} = Fil.Plug.send_file(conn, disk, "reports/q4.csv")
      assert {:error, %Fil.NotFoundError{reason: :eisdir}} = Fil.Plug.send_file(conn, disk, "reports")
      assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.Plug.send_file(conn, disk, "../a.csv")
      assert conn.state == :unset
    end

    test "returns the error of a read that fails after the stat, and the mounted plug answers it", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "q3.csv", "a,b\n")

      failing =
        Fil.attach(disk, :failing, fn
          %Fil.Op{name: :read} = op, _next, _opts -> Fil.Op.put_result(op, {:error, %Fil.UnavailableError{}})
          op, next, _opts -> next.(op)
        end)

      conn = conn(:get, "/")

      assert {:error, %Fil.UnavailableError{}} = Fil.Plug.send_file(conn, failing, "q3.csv")
      assert conn.state == :unset
      assert download(failing, "q3.csv", []).status == 503
    end

    test "content_type: wins over the stored content type", %{disk: disk} do
      {:ok, report} = Fil.write(disk, "q3", "a,b\n", content_type: "application/octet-stream")
      request = conn(:get, "/")

      {:ok, conn} = Fil.Plug.send_file(request, report, content_type: "text/csv")
      assert get_resp_header(conn, "content-type") == ["text/csv"]
    end

    test "a POST gets the whole file, whatever its conditional and range headers", %{disk: disk} do
      {:ok, file} = Fil.write(disk, "a.txt", "0123456789")
      {:ok, stat} = Fil.stat(file)

      {:ok, conn} = send_with_headers(:post, file, [{"if-none-match", ~s("#{stat.etag}")}, {"range", "bytes=2-4"}])
      assert {conn.status, conn.resp_body} == {200, "0123456789"}
    end

    test "send_file! returns the conn or raises the error", %{disk: disk} do
      {:ok, report} = Fil.write(disk, "q3.csv", "a,b\n")
      conn = conn(:get, "/")

      assert Fil.Plug.send_file!(conn, report).resp_body == "a,b\n"
      assert Fil.Plug.send_file!(conn, disk, "q3.csv", disposition: :inline).resp_body == "a,b\n"
      assert_raise Fil.NotFoundError, fn -> Fil.Plug.send_file!(conn, disk, "q4.csv") end
    end

    test "raises for bad options", %{disk: disk} do
      report = Fil.ref(disk, "q3.csv")
      conn = conn(:get, "/")

      assert_raise NimbleOptions.ValidationError, fn ->
        Fil.Plug.send_file(conn, report, disposition: :download)
      end

      assert_raise ArgumentError, ~r/can't be empty/, fn ->
        Fil.Plug.send_file(conn, report, disposition: {:attachment, ""})
      end
    end
  end

  defp send_with_headers(method, file, headers, opts \\ []) do
    method
    |> conn("/download")
    |> then(&Enum.reduce(headers, &1, fn {name, value}, conn -> put_req_header(conn, name, value) end))
    |> Fil.Plug.send_file(file, opts)
  end

  # A GET (or another method) of a signed URL for `path`, with request headers.
  defp download(disk, path, headers, method \\ :get) do
    {:ok, url} = Fil.signed_url(disk, path)
    uri = URI.parse(url)
    conn = conn(method, uri.path <> "?" <> uri.query)

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> call(disk)
  end

  defp http_date(time), do: Calendar.strftime(time, "%a, %d %b %Y %H:%M:%S GMT")
end

defmodule Fil.PlugTest.OneDisk do
  alias Fil.Plugin.URL

  use ExUnit.Case, async: true

  import Fil.PlugHelper
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

    {:ok, local: local, memory: memory()}
  end

  # Named, so tests can pass them as `disk:` captures, the only functions a plug's options can hold.
  def memory do
    [adapter: Fil.Adapter.Memory, root: "uploads"]
    |> Fil.disk()
    |> URL.attach(base_url: @base_url, secret: "memory-secret")
  end

  def nope, do: :nope

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

  test "a body over :max_body_size leaves nothing behind on a local disk", %{local: disk, tmp_dir: tmp_dir} do
    {:ok, url} = Fil.signed_url(disk, "inbox/big.bin", method: :put)
    body = :crypto.strong_rand_bytes(3_000_000)

    conn =
      url
      |> put(body)
      |> call(disk, max_body_size: 2_000_000)

    # No file, no temporary file, and not the directory the write created either.
    assert conn.status == 413
    assert File.ls!(tmp_dir) == []
  end

  test "an upload a plugin rejects at its end leaves nothing on a local disk", %{local: disk, tmp_dir: tmp_dir} do
    rejecting =
      Fil.attach(disk, :reject, fn op, next, _opts ->
        op
        |> Fil.Op.scan_content(0, fn chunk, size -> size + byte_size(chunk) end, fn _size ->
          raise %Fil.InvalidContentError{reason: :at_end}
        end)
        |> next.()
      end)

    {:ok, url} = Fil.signed_url(rejecting, "inbox/big.bin", method: :put)

    conn =
      url
      |> put(:crypto.strong_rand_bytes(3_000_000), [{"content-length", "3000000"}])
      |> call(rejecting)

    assert conn.status == 422
    assert File.ls!(tmp_dir) == []
  end

  describe "with Fil.Plugin.Validation" do
    setup %{local: disk} do
      {:ok, validating: Fil.Plugin.Validation.attach(disk, max_size: 1_000, content_types: ["image/png"])}
    end

    test "an upload over max_size is a 413, by its content-length or while it's read", %{validating: disk} do
      {:ok, url} = Fil.signed_url(disk, "a.png", method: :put)
      png = <<0x89, "PNG\r\n", 0x1A, "\n">> <> :binary.copy(<<0>>, 2_000)

      for headers <- [[{"content-length", "2008"}], []] do
        conn =
          url
          |> put(png, headers)
          |> call(disk)

        assert {conn.status, conn.resp_body} == {413, "the content is too large"}
      end

      refute Fil.exists?(disk, "a.png")
    end

    test "a GIF sent as a PNG is a 415 and leaves nothing behind", %{validating: disk, tmp_dir: tmp_dir} do
      {:ok, url} = Fil.signed_url(disk, "inbox/a.png", method: :put)

      conn =
        url
        |> put("GIF89a" <> :binary.copy(<<0>>, 500), [{"content-type", "image/png"}])
        |> call(disk)

      assert {conn.status, conn.resp_body} == {415, "the content type is not allowed"}
      assert File.ls!(tmp_dir) == []
    end
  end

  test "resolves the disk from a capture or an MFA", %{memory: disk} do
    {:ok, _} = Fil.write(disk, "a.txt", "a")
    {:ok, url} = Fil.signed_url(disk, "a.txt")

    assert request(:get, url, &__MODULE__.memory/0).status == 200
    assert request(:get, url, {Function, :identity, [disk]}).status == 200
  end

  test "raises when the disk function returns something else" do
    assert_raise ArgumentError, ~r/to return a Fil.Disk, got: :nope/, fn ->
      request(:get, "/storage/a.txt", &__MODULE__.nope/0)
    end
  end

  # `plug` and `forward` escape the options into compiled code, which can't hold an anonymous function.
  test "refuses an anonymous disk function", %{memory: disk} do
    assert_raise NimbleOptions.ValidationError, ~r/got an anonymous function or a local capture/, fn ->
      Fil.Plug.init(disk: fn -> disk end)
    end
  end

  test "refuses a disk option that is no disk, function or MFA" do
    assert_raise NimbleOptions.ValidationError, ~r/invalid value for :disk option: expected a `Fil.Disk`/, fn ->
      Fil.Plug.init(disk: :uploads)
    end
  end

  test "proxies an S3 disk" do
    # A stubbed S3: HeadObject and GetObject answer from the test, PutObject records the body.
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "HEAD" ->
          conn
          |> put_resp_header("content-type", "application/pdf")
          |> send_resp(200, "")

        "GET" ->
          send_resp(conn, 200, "%PDF")

        "PUT" ->
          {:ok, body, conn} = read_body(conn)
          send(test, {:put, request_url(conn), body, get_req_header(conn, "x-amz-content-sha256")})
          send_resp(conn, 200, "")
      end
    end)

    disk =
      [
        adapter: Fil.Adapter.S3,
        bucket: "bucket",
        access_key_id: "AKIDEXAMPLE",
        secret_access_key: "secret",
        req_options: [plug: {Req.Test, __MODULE__}]
      ]
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
    # Without a content-length, the upload is collected and signed with its hash. With one, it goes to S3 as it's read.
    assert_received {:put, "https://bucket.s3.us-east-1.amazonaws.com/inbox/new.bin", "uploaded", [hash]}
    assert hash =~ ~r/^[0-9a-f]{64}$/

    assert (put_url
            |> put("streamed", [{"content-length", "8"}])
            |> call(disk)).status == 200

    assert_received {:put, "https://bucket.s3.us-east-1.amazonaws.com/inbox/new.bin", "streamed", ["UNSIGNED-PAYLOAD"]}
  end

  test "send_file/3 streams a range from an S3 disk" do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "HEAD" ->
          conn
          |> put_resp_header("content-length", "10")
          |> put_resp_header("etag", ~s("abc"))
          |> send_resp(200, "")

        "GET" ->
          send(test, {:range, get_req_header(conn, "range")})
          send_resp(conn, 206, "234")
      end
    end)

    disk =
      Fil.disk(
        adapter: Fil.Adapter.S3,
        bucket: "bucket",
        access_key_id: "AKIDEXAMPLE",
        secret_access_key: "secret",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    {:ok, conn} =
      :get
      |> conn("/download")
      |> put_req_header("range", "bytes=2-4")
      |> Fil.Plug.send_file(disk, "exports/7f3a.csv", disposition: :attachment)

    assert {conn.status, conn.resp_body} == {206, "234"}
    assert get_resp_header(conn, "content-range") == ["bytes 2-4/10"]
    assert get_resp_header(conn, "etag") == [~s("abc")]
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="7f3a.csv")]
    assert_received {:range, ["bytes=2-4"]}
  end

  test "send_file/3 stops reading when the client closes the connection", %{memory: disk} do
    test = self()

    {:ok, _} = Fil.write(disk, "big.bin", "abc")

    # The stream sends each chunk it reads to the test, and the connection is closed on the first chunk.
    reading =
      Fil.attach(disk, :chunks, fn
        %Fil.Op{name: :read} = op, _next, _opts ->
          chunks =
            Stream.map(["a", "b", "c"], fn chunk ->
              send(test, {:read, chunk})
              chunk
            end)

          Fil.Op.put_result(op, {:ok, chunks})

        op, next, _opts ->
          next.(op)
      end)

    conn = %{conn(:get, "/download") | adapter: {Fil.PlugTest.ClosingAdapter, test}}

    assert {:ok, %Plug.Conn{state: :chunked}} = Fil.Plug.send_file(conn, reading, "big.bin")
    assert_received {:read, "a"}
    assert_received :closed
    refute_received {:read, "b"}
  end

  test "an upload over :max_body_size into an S3 disk aborts the upload in parts" do
    # A stubbed S3 that starts an upload, takes part 1 and records the abort.
    test = self()

    Req.Test.expect(__MODULE__, fn conn ->
      body = "<InitiateMultipartUploadResult><UploadId>UP</UploadId></InitiateMultipartUploadResult>"
      send_resp(conn, 200, body)
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 10_000_000)
      send(test, {:part, conn.query_params["partNumber"], byte_size(body)})

      conn
      |> put_resp_header("etag", ~s("e1"))
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      send(test, {:abort, conn.method, conn.query_string})
      send_resp(conn, 204, "")
    end)

    disk =
      [
        adapter: Fil.Adapter.S3,
        bucket: "bucket",
        access_key_id: "AKIDEXAMPLE",
        secret_access_key: "secret",
        part_size: 5_242_880,
        req_options: [plug: {Req.Test, __MODULE__}]
      ]
      |> Fil.disk()
      |> URL.attach(base_url: @base_url, secret: "s3-secret")

    {:ok, url} = Fil.signed_url(disk, "big.bin", method: :put)

    # Without a content-length, the size is only known once the body has been read.
    conn =
      url
      |> put(:binary.copy("a", 7_000_000))
      |> call(disk, max_body_size: 6_500_000)

    assert conn.status == 413
    assert_received {:part, "1", 5_242_880}
    assert_received {:abort, "DELETE", "uploadId=UP"}
    Req.Test.verify!(__MODULE__)
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

    test "keeps paths inside the disk root", %{tmp_dir: tmp_dir} do
      tmp_dir
      |> Path.join("secret.txt")
      |> File.write!("secret")

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
end

defmodule Fil.PlugTest.ClosingAdapter do
  @moduledoc false

  # A connection the client closes as soon as the first chunk is sent. The state is the test process.

  def send_chunked(test, _status, _headers), do: {:ok, nil, test}

  def chunk(test, _chunk) do
    send(test, :closed)
    {:error, :closed}
  end
end
