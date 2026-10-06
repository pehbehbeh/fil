if Code.ensure_loaded?(Plug) do
  defmodule Fil.Plug do
    @schema NimbleOptions.new!(
              disk: [
                type: Fil.Support.DiskOption.type([:disk, :remote_fun, :mfa]),
                required: true,
                doc: """
                The disk to serve. #{Fil.Support.DiskOption.doc([:disk, :remote_fun, :mfa])}
                """
              ],
              at: [
                type: :string,
                doc: """
                The path to serve under, e.g. `"/storage/uploads"`. Requests outside it pass through untouched, which is
                how the plug sits in an endpoint. Without it, the plug serves every request it gets, as with `forward`.
                """
              ],
              public: [
                type: :boolean,
                default: false,
                doc: """
                Serves `GET` and `HEAD` without a signature, like `Plug.Static` for a disk, so every file on the disk
                can be downloaded by anyone who knows its path:

                    plug Fil.Plug, at: "/avatars", disk: &MyApp.Storage.avatars/0, public: true

                `GET /avatars/1.png` then returns `1.png` from the disk, on every adapter. There are no directory
                listings, and a path can't leave the disk root. With `Fil.Plugin.URL` and
                `base_url: "http://localhost:4000/avatars"` on the disk, `Fil.url/2` builds these URLs.

                Uploads still need a signed URL, and without a `:secret` for `Fil.Plugin.URL` on the disk, a `PUT` gets
                a `403`. A signed download URL that has expired or was changed still works on a public disk, but
                without the `content-disposition` it was signed with.
                """
              ],
              max_body_size: [
                type: :pos_integer,
                default: 100 * 1024 * 1024,
                doc: """
                The largest upload in bytes, 100 MiB by default. A larger `PUT` gets a `413`, and nothing is written.
                Uploads are streamed into the disk, so the limit is about storage, not memory. S3 keeps one part of an
                upload without a `content-length` in memory (see `Fil.Adapter.S3`).
                """
              ]
            )

    @moduledoc """
    Serves the files of a disk over HTTP: the URLs `Fil.Plugin.URL` signs, or with `public: true`, every file.

        plug Fil.Plug, at: "/storage/uploads", disk: &MyApp.Storage.uploads/0

    Signed URLs make direct downloads and uploads work on every disk: local and memory disks, which can't sign URLs
    themselves, and S3 disks whose files should go through your application.

    Needs [Plug](https://plug.hexdocs.pm), an optional dependency of `Fil`.

    ## Options

    #{NimbleOptions.docs(@schema)}

    ## Mounting

    In a Phoenix app, the plug goes into the endpoint or behind a route. The endpoint takes uploads in any format, and
    the router lets plugs of your own run first, such as authentication.

    <!-- tabs-open -->

    ### Via Endpoint

    Put it in the endpoint before `Plug.Parsers`, at the path the plugin's `:base_url` points to:

        plug Fil.Plug, at: "/storage/uploads", disk: &MyApp.Storage.uploads/0

    The `:base_url` of the disk's `Fil.Plugin.URL` is then `"http://localhost:4000/storage/uploads"`, and every URL
    `Fil.signed_url/3` builds for it is served here.

    Requests pass through untouched when the disk doesn't sign URLs with `Fil.Plugin.URL` (and the plug isn't public).
    An S3 disk without it signs URLs that go to S3 directly, so the plug can stay in the endpoint when production uses
    S3.

    ### Via Router

    `forward` runs the plug behind a router pipeline, for example to let only signed-in users download from a public
    disk:

        pipeline :storage do
          plug :require_authenticated_user
        end

        scope "/storage" do
          pipe_through :storage
          forward "/avatars", Fil.Plug, disk: &MyApp.Storage.avatars/0, public: true
        end

    `forward` removes `/storage/avatars` from the path, so the plug needs no `:at`. The `:base_url` of
    `Fil.Plugin.URL` is still the full URL, `"http://localhost:4000/storage/avatars"`, because signatures cover the
    whole request path.

    Two things in a Phoenix app get in the way of uploads there:

      * `Plug.Parsers` in the endpoint reads the bodies it has a parser for before the router runs (in a new Phoenix
        app JSON, form and multipart bodies). A `PUT` with one of those content types reaches the plug without its
        body and gets a `400` (the plug compares what it can read with the `content-length`). Other content types,
        such as `image/png` or `application/pdf`, pass through unread. Use the endpoint for uploads in any format.
      * the `:browser` pipeline's `protect_from_forgery` rejects a `PUT` without a CSRF token. Use a pipeline of your
        own, as above.

    <!-- tabs-close -->

    ## Sending a file from a controller

    `send_file/3` sends one file as the response of a controller action, with the same headers, conditional requests and
    ranges as the mounted plug. The controller decides who gets the file, so no signed URL is involved:

        def download(conn, %{"id" => id}) do
          with {:ok, report} <- Reports.file(conn.assigns.current_scope, id),
               {:ok, conn} <- Fil.Plug.send_file(conn, report, disposition: {:attachment, "report-\#{id}.csv"}) do
            conn
          end
        end

    A missing file returns the error, so the controller's `action_fallback` can answer it.

    ## Responses

      * `GET` and `HEAD` on a URL signed for `:get` return the file, with its stored content type or one guessed from
        the extension, and the `content-disposition` the URL was signed with (`disposition:`). The file is streamed
        as a chunked response, so it never has to fit in memory
      * downloads send `etag` and `last-modified` from `Fil.stat/3` and `accept-ranges: bytes`. A request whose
        `if-none-match` lists the etag (or is `*`) gets a `304` without a body, and so does one without `if-none-match`
        whose `if-modified-since` isn't older than the file. The etag is sent as a strong validator on every adapter,
        including the `"size-mtime"` tag of `Fil.Adapter.Local`, as nginx and `Plug.Static` do
      * a `GET` with one byte range (`range: bytes=0-1023`, `bytes=1024-` or `bytes=-1024`) gets a `206` with that part
        and its `content-range`, read from the storage with `Fil.stream/3`'s `offset:` and `length:`. A range that
        starts at or after the end of the file is a `416`. Several ranges, a range the plug can't parse, and an
        `if-range` that's neither the etag nor the exact `last-modified` get a `200` with the whole file. Ranges work
        with signed URLs too, because the signature covers the method, the path and the query, not the headers.
        Offsets count bytes of the content as plugins return it, and the total in `content-range` is the size
        `Fil.stat/3` returns, so a plugin that changes the size of the content should change it in the stat too
      * `PUT` on a URL signed for `:put` writes the request body, with the request's `content-type`, the same as a
        presigned PUT on S3. The body is streamed into `Fil.write/4` as it's read, with the `content-length` as
        `size:`. Plugins attached to the disk run as for any other write. A URL signed with `content_type:` or `size:`
        takes only an upload with that `content-type` and `content-length`, and one signed with `if_exists: :error`
        writes with it, so a second upload to the same path gets a `409` (see [Uploads](Fil.html#signed_url/1-uploads))
      * a request that doesn't match its signature, or comes after the URL expired, gets a `403`, and so does an upload
        whose `content-type` or `content-length` isn't the one its URL was signed with
      * an upload larger than `:max_body_size` gets a `413`, and one whose body something else already read (see
        [Mounting](#module-mounting)) a `400`. Neither writes anything
      * a missing file gets a `404`, and so does a file the storage denies access to, so a client can't tell which
        files exist
      * a failed write gets a `409` if the file already exists or changed meanwhile, `422` if the disk refuses the
        content (a `Fil.InvalidRequestError` about the content, such as from `Fil.Plugin.Thumbnails` for a file that
        isn't an image), `507` if the storage is full and `503` if it's unavailable. Any other error is a `500` with a
        generic body, and its message goes to the `Logger`. So is S3's `InvalidRequest`, on a download too, because S3
        sends it for problems with the request or the bucket's configuration as well
      * an upload a plugin refuses with a `Fil.InvalidContentError`, before or while the body is read, gets a `413` for
        content that's too large, a `415` for a content type or an extension the disk doesn't take, and a `422` for
        anything else. Nothing is written, and the body doesn't say which rule the upload broke
    """

    @behaviour Plug

    alias Fil.Support.Conditional

    # `send_file/3,4` here send a file from a disk.
    import Plug.Conn, except: [send_file: 3, send_file: 4, send_file: 5]

    require Logger

    @send_file_schema NimbleOptions.new!(
                        content_type: [
                          type: :string,
                          doc: """
                          The `content-type` of the response. Without it, the file's stored content type, or one guessed
                          from its extension.
                          """
                        ],
                        disposition: [
                          type: {:or, [{:in, [:inline, :attachment]}, {:tuple, [{:in, [:attachment]}, :string]}]},
                          doc: """
                          The `content-disposition` of the response. `:inline` lets the browser show the file,
                          `:attachment` saves it under the file's name, and `{:attachment, filename}` under another
                          name, which can be any UTF-8 string. Without it, no `content-disposition` is sent.
                          """
                        ]
                      )

    # The most an upload is read at a time.
    @read_length 1_048_576

    # The reasons of a `Fil.InvalidRequestError` that are about the path, not the content (see the adapters' tables).
    @path_reasons [:ebadpath, :eisdir, :enotdir, :enametoolong, :eloop, "KeyTooLongError"]

    # The reasons of a `Fil.InvalidRequestError` that are about the request or the storage's configuration, which the
    # client can't fix. S3 sends `InvalidRequest` for a PutObject without `Content-MD5` in a bucket with object lock, or
    # with a checksum header it doesn't support, for example. They're a `500` that's logged, like an unknown error.
    @request_reasons ["InvalidRequest"]

    @impl Plug
    def init(opts) do
      opts = NimbleOptions.validate!(opts, @schema)

      Keyword.update(opts, :at, [], &String.split(&1, "/", trim: true))
    end

    @impl Plug
    def call(conn, opts) do
      at = opts[:at]

      # Only disks that sign with `Fil.Plugin.URL` have a secret. Requests for any other disk (an S3 disk in production,
      # for example) pass through unless the plug is public, so the plug can stay in the endpoint in every environment.
      with true <- Enum.take(conn.path_info, length(at)) == at,
           disk = Fil.Disk.resolve(opts[:disk]),
           secret = Fil.Plugin.URL.secret(disk),
           true <- opts[:public] or secret != nil do
        conn
        |> Map.update!(:path_info, &Enum.drop(&1, length(at)))
        |> handle(disk, secret, opts)
        |> Map.put(:path_info, conn.path_info)
        |> halt()
      else
        _outside_or_not_served -> conn
      end
    end

    @doc """
    Sends a file as the response, from a controller or a plug of your own.

        {:ok, conn} = Fil.Plug.send_file(conn, report, disposition: {:attachment, "Q3 report.pdf"})

    The file goes out as the mounted plug sends a download (see [Responses](#module-responses)), on every adapter:
    streamed in a chunked response, with `etag`, `last-modified` and `accept-ranges`, a `304` for a matching
    `if-none-match` or `if-modified-since`, a `206` for one byte range and a `416` for a range outside the file. A
    `HEAD` gets the headers only. When the client closes the connection, the rest of the file isn't read. Headers set
    on `conn` before the call are kept, so you can add a `cache-control`, for example.

    Conditional requests and ranges apply to `GET` and `HEAD`. Any other method, such as a `POST` to an export action,
    gets the whole file.

    Returns `{:ok, conn}` with the response sent, whatever its status. A missing file, a directory
    (`Fil.NotFoundError` with `reason: :eisdir`) and any other error of `Fil.stat/2` or `Fil.stream/3` return
    `{:error, exception}` before anything is sent, so the caller can answer it, for example in an `action_fallback`. An
    error while the file is streamed comes after the status line, so it raises and the client gets a truncated
    response.

    ## Options

    #{NimbleOptions.docs(@send_file_schema)}
    """
    @spec send_file(Plug.Conn.t(), Fil.Ref.t()) :: Fil.result(Plug.Conn.t())
    def send_file(conn, ref), do: send_file(conn, ref, [])

    @doc "Sends a file as the response. See `send_file/2`."
    @spec send_file(Plug.Conn.t(), Fil.Disk.t(), Path.t()) :: Fil.result(Plug.Conn.t())
    @spec send_file(Plug.Conn.t(), Fil.Ref.t(), keyword()) :: Fil.result(Plug.Conn.t())
    def send_file(conn, %Fil.Disk{} = disk, path) when is_binary(path), do: send_file(conn, Fil.ref(disk, path), [])

    def send_file(%Plug.Conn{} = conn, %Fil.Ref{} = ref, opts) when is_list(opts) do
      opts = NimbleOptions.validate!(opts, @send_file_schema)

      headers =
        for disposition <- List.wrap(opts[:disposition]) do
          {"content-disposition", disposition_header(disposition, ref)}
        end

      send_download(conn, ref, opts[:content_type], headers)
    end

    @doc "Sends a file as the response. See `send_file/2`."
    @spec send_file(Plug.Conn.t(), Fil.Disk.t(), Path.t(), keyword()) :: Fil.result(Plug.Conn.t())
    def send_file(conn, %Fil.Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
      send_file(conn, Fil.ref(disk, path), opts)
    end

    @doc "Same as `send_file/2`, raising the error on failure."
    @spec send_file!(Plug.Conn.t(), Fil.Ref.t()) :: Plug.Conn.t()
    def send_file!(conn, ref), do: unwrap!(send_file(conn, ref))

    @doc "Same as `send_file/3`, raising the error on failure."
    @spec send_file!(Plug.Conn.t(), Fil.Disk.t(), Path.t()) :: Plug.Conn.t()
    @spec send_file!(Plug.Conn.t(), Fil.Ref.t(), keyword()) :: Plug.Conn.t()
    def send_file!(conn, a, b), do: unwrap!(send_file(conn, a, b))

    @doc "Same as `send_file/4`, raising the error on failure."
    @spec send_file!(Plug.Conn.t(), Fil.Disk.t(), Path.t(), keyword()) :: Plug.Conn.t()
    def send_file!(conn, disk, path, opts), do: unwrap!(send_file(conn, disk, path, opts))

    defp unwrap!({:ok, conn}), do: conn
    defp unwrap!({:error, error}), do: raise(error)

    # The file name for `:attachment` comes from the path, as on `Fil.signed_url/3`.
    defp disposition_header({:attachment, ""}, _ref),
      do: raise(ArgumentError, "the file name of the :disposition option can't be empty")

    defp disposition_header(disposition, ref) do
      Fil.Support.ContentDisposition.header(disposition, Path.basename(ref.path))
    end

    defp handle(conn, disk, secret, opts) do
      conn = fetch_query_params(conn)

      with {:ok, method} <- method(conn),
           {:ok, signed} <- authorize(conn, method, secret, opts[:public]),
           :ok <- check_upload(conn, method, signed) do
        # `path_info` keeps the percent-encoding of the request, and the disk wants the path itself.
        path = Enum.map_join(conn.path_info, "/", &URI.decode/1)

        serve(conn, method, disk, path, signed, opts[:max_body_size])
      else
        {:error, reason} -> send_refusal(conn, reason)
      end
    end

    defp send_refusal(conn, :method_not_allowed), do: send_error(conn, 405, "method not allowed")
    defp send_refusal(conn, :expired), do: send_error(conn, 403, "the URL has expired")
    defp send_refusal(conn, :invalid_signature), do: send_error(conn, 403, "the URL signature is invalid")
    defp send_refusal(conn, :signature_required), do: send_error(conn, 403, "uploads need a signed URL")
    defp send_refusal(conn, :upload_mismatch), do: send_error(conn, 403, "the upload doesn't match its signed URL")

    # Returns the parameters the URL was signed with. A public download needs no signature, but only a valid one can set
    # the disposition, so nobody can make a link that serves the disk's files under another name. A verified query has
    # each parameter at most once, and only strings.
    defp authorize(conn, :get, secret, true) do
      with {:error, _reason} <- authorize(conn, :get, secret, false), do: {:ok, %{}}
    end

    defp authorize(_conn, _method, nil, _public?), do: {:error, :signature_required}

    defp authorize(conn, method, secret, _public?) do
      with :ok <- Fil.Plugin.URL.verify(secret, method, conn.request_path, conn.query_string) do
        {:ok, conn.query_params}
      end
    end

    # An upload URL signed with a content type or a size takes only a request with the same `content-type` or
    # `content-length`, as S3 does for signed headers. A missing header doesn't match either.
    defp check_upload(conn, :put, signed) do
      content_type = signed["content_type"]
      size = signed["size"]

      cond do
        content_type && get_req_header(conn, "content-type") != [content_type] -> {:error, :upload_mismatch}
        size && get_req_header(conn, "content-length") != [size] -> {:error, :upload_mismatch}
        true -> :ok
      end
    end

    defp check_upload(_conn, :get, _signed), do: :ok

    defp method(%{method: method}) when method in ["GET", "HEAD"], do: {:ok, :get}
    defp method(%{method: "PUT"}), do: {:ok, :put}
    defp method(_conn), do: {:error, :method_not_allowed}

    # A signed URL's disposition is already the header value. A failed stat or stream is answered here, because nothing
    # has been sent yet.
    defp serve(conn, :get, disk, path, signed, _max_body_size) do
      headers = for disposition <- List.wrap(signed["disposition"]), do: {"content-disposition", disposition}

      case send_download(conn, Fil.ref(disk, path), nil, headers) do
        {:ok, conn} -> conn
        {:error, error} -> send_fil_error(conn, error)
      end
    end

    # The request body is streamed into `Fil.write/4` as it's read, with the `content-length` as `size:`. A body that
    # breaks a rule while it's read stops the write with a throw, before the stream ends, so nothing is written. A URL
    # signed with `if_exists: :error` writes with it, whether the client sent `if-none-match: *` or not.
    defp serve(conn, :put, disk, path, signed, max_body_size) do
      content_type =
        conn
        |> get_req_header("content-type")
        |> Enum.take(1)
        |> Enum.map(&{:content_type, &1})

      opts = if signed["if_exists"] == "error", do: [{:if_exists, :error} | content_type], else: content_type

      length = content_length(conn)

      # A declared size over the limit is refused before anything is read, and a body `Plug.Parsers` already read is
      # noticed on the first read, before the write starts.
      with :ok <- check_declared_size(length, max_body_size),
           {:ok, first, conn} <- read_chunk(conn, 0, length, max_body_size) do
        opts = if length, do: [{:size, length} | opts], else: opts

        upload(conn, disk, path, first, opts, {length, max_body_size})
      else
        {:error, reason} -> body_error(conn, reason, max_body_size)
        {:error, reason, conn} -> body_error(conn, reason, max_body_size)
      end
    end

    # The file is streamed to the client (`Fil.stream/3`), so its size doesn't matter. The response is chunked, because
    # plugins can change the content, and then the stored size isn't the size sent. The stat gives the validators, so a
    # `304` or a `416` reads nothing. Errors before the status line are returned. An error while streaming comes after
    # it, so it raises and the client gets a truncated response.
    defp send_download(conn, ref, content_type, headers) do
      with {:ok, stat} <- Fil.stat(ref),
           :ok <- check_regular(stat, ref) do
        conn = put_validators(conn, stat)

        if not_modified?(conn, stat) do
          {:ok, send_resp(conn, 304, "")}
        else
          file = %{ref: ref, stat: stat, content_type: content_type, headers: headers}

          send_range(conn, file, range(conn, stat))
        end
      end
    end

    # A directory is no file to send, as for `Fil.LiveView`.
    defp check_regular(%Fil.Stat{type: :regular}, _ref), do: :ok

    defp check_regular(%Fil.Stat{type: :directory}, ref),
      do: {:error, %Fil.NotFoundError{reason: :eisdir, op: :stat, path: ref.path, disk: ref.disk}}

    defp put_validators(conn, stat) do
      headers = [
        {"accept-ranges", "bytes"},
        {"etag", Conditional.etag(stat)},
        {"last-modified", Conditional.last_modified(stat)}
      ]

      merge_resp_headers(conn, for({name, value} <- headers, value != nil, do: {name, value}))
    end

    # Conditional requests are for `GET` and `HEAD` only. Another method (a `POST` to a controller) gets the file.
    defp not_modified?(%{method: method} = conn, stat) when method in ["GET", "HEAD"] do
      Conditional.not_modified?(stat, get_req_header(conn, "if-none-match"), get_req_header(conn, "if-modified-since"))
    end

    defp not_modified?(_conn, _stat), do: false

    # Only a `GET` has a range. A `HEAD` gets the headers of the whole file.
    defp range(%{method: "GET"} = conn, stat) do
      Conditional.range(stat, get_req_header(conn, "range"), get_req_header(conn, "if-range"))
    end

    defp range(_conn, _stat), do: :whole

    # A `416` is a plain text error, without the file's content type and disposition.
    defp send_range(conn, %{stat: stat}, :unsatisfiable) do
      conn =
        conn
        |> put_resp_header("content-range", "bytes */#{stat.size}")
        |> send_error(416, "the range is outside the file")

      {:ok, conn}
    end

    defp send_range(conn, file, :whole) do
      with {:ok, content} <- Fil.stream(file.ref) do
        conn
        |> put_file_headers(file)
        |> send_content(200, content)
      end
    end

    defp send_range(conn, %{stat: stat} = file, {:range, offset, length}) do
      with {:ok, content} <- Fil.stream(file.ref, offset: offset, length: length) do
        conn
        |> put_file_headers(file)
        |> put_resp_header("content-range", "bytes #{offset}-#{offset + length - 1}/#{stat.size}")
        |> send_content(206, content)
      end
    end

    defp put_file_headers(conn, file) do
      content_type = file.content_type || file.stat.content_type || MIME.from_path(file.ref.path)

      conn
      |> put_resp_content_type(content_type, nil)
      |> merge_resp_headers(file.headers)
    end

    defp send_content(%{method: "HEAD"} = conn, status, _content), do: {:ok, send_resp(conn, status, "")}

    # A client that closes the connection stops the stream, so the rest of the file is never read.
    defp send_content(conn, status, content) do
      conn =
        Enum.reduce_while(content, send_chunked(conn, status), fn chunk, conn ->
          case chunk(conn, chunk) do
            {:ok, conn} -> {:cont, conn}
            {:error, _closed} -> {:halt, conn}
          end
        end)

      {:ok, conn}
    end

    # The stream reads the body with the latest conn, which it keeps in the process dictionary, because `read_body/2`
    # returns a new one each time and the response has to go out on the last.
    defp upload(conn, disk, path, first, opts, limits) do
      key = {__MODULE__, make_ref()}
      Process.put(key, conn)

      result =
        try do
          Fil.write(disk, path, body_stream(key, first, limits), opts)
        catch
          :throw, {^key, reason} -> {:body_error, reason}
        end

      conn = Process.delete(key)

      case result do
        {:ok, _ref} -> send_resp(conn, 200, "")
        {:error, error} -> send_write_error(conn, error)
        {:body_error, reason} -> body_error(conn, reason, elem(limits, 1))
      end
    end

    defp body_stream(key, first, limits) do
      Stream.resource(fn -> first end, &next_body_chunk(&1, key, limits), fn _state -> :ok end)
    end

    defp next_body_chunk({:emit, chunk, :more, size}, _key, _limits), do: {[chunk], {:read, size}}
    defp next_body_chunk({:emit, chunk, :ok, _size}, _key, _limits), do: {[chunk], :done}
    defp next_body_chunk(:done, _key, _limits), do: {:halt, :done}

    defp next_body_chunk({:read, size}, key, limits) do
      case read_stored(key, size, limits) do
        {:ok, next} -> next_body_chunk(next, key, limits)
        {:error, reason} -> throw({key, reason})
      end
    end

    # Reads with the conn kept under `key`, and keeps the new one there.
    defp read_stored(key, size, {length, max_body_size}) do
      key
      |> Process.get()
      |> read_chunk(size, length, max_body_size)
      |> store_conn(key)
    end

    defp store_conn({tag, value, conn}, key) do
      Process.put(key, conn)
      {tag, value}
    end

    # Reads the next piece of the body and checks it against the limit and the declared size.
    defp read_chunk(conn, size, length, max_body_size) do
      case read_body(conn, length: @read_length) do
        {status, chunk, conn} ->
          size = size + byte_size(chunk)

          case check_body(status, size, length, max_body_size) do
            :ok -> {:ok, {:emit, chunk, status, size}, conn}
            {:error, reason} -> {:error, reason, conn}
          end

        {:error, _reason} ->
          {:error, :body, conn}
      end
    end

    # A body shorter than its `content-length` was read by something else before the plug: `Plug.Parsers` reads the
    # body of the content types it parses but leaves the headers alone.
    defp check_body(_status, size, _length, max_body_size) when size > max_body_size, do: {:error, :too_large}

    defp check_body(_status, size, length, _max_body_size) when is_integer(length) and size > length,
      do: {:error, :body}

    defp check_body(:ok, size, length, _max_body_size) when is_integer(length) and size < length,
      do: {:error, :already_read}

    defp check_body(_status, _size, _length, _max_body_size), do: :ok

    defp body_error(conn, :too_large, max_body_size) do
      send_error(conn, 413, "the request body is larger than #{max_body_size} bytes")
    end

    defp body_error(conn, :body, _max_body_size), do: send_error(conn, 400, "the request body could not be read")

    defp body_error(conn, :already_read, _max_body_size) do
      send_error(conn, 400, "the request body was already read, probably by Plug.Parsers")
    end

    # An upload a plugin refuses (`Fil.InvalidContentError`) gets a status for what was wrong with it. The body never
    # has the reason, which a plugin may have filled with anything.
    defp send_write_error(conn, %Fil.InvalidContentError{reason: {:too_large, _max}}),
      do: send_error(conn, 413, "the content is too large")

    defp send_write_error(conn, %Fil.InvalidContentError{reason: reason})
         when is_tuple(reason) and tuple_size(reason) > 0 and
                elem(reason, 0) in [:content_type, :content_type_mismatch, :extension],
         do: send_error(conn, 415, "the content type is not allowed")

    defp send_write_error(conn, %Fil.InvalidContentError{}), do: send_error(conn, 422, "the content was rejected")

    # An upload the disk refuses for its content is a 422. One refused for its path is a 404, as on a download.
    defp send_write_error(conn, %Fil.InvalidRequestError{reason: reason})
         when reason not in @path_reasons and reason not in @request_reasons,
         do: send_error(conn, 422, "the content can't be stored here")

    defp send_write_error(conn, error), do: send_fil_error(conn, error)

    defp send_fil_error(conn, %Fil.InvalidRequestError{reason: reason} = error) when reason in @request_reasons,
      do: send_server_error(conn, error)

    # A denied file is a 404 too, so a client can't tell which files exist.
    defp send_fil_error(conn, %error{})
         when error in [Fil.NotFoundError, Fil.AccessDeniedError, Fil.InvalidRequestError],
         do: send_error(conn, 404, "not found")

    defp send_fil_error(conn, %Fil.AlreadyExistsError{}), do: send_error(conn, 409, "the file already exists")
    defp send_fil_error(conn, %Fil.ConflictError{}), do: send_error(conn, 409, "the file changed, try again")
    defp send_fil_error(conn, %Fil.StorageFullError{}), do: send_error(conn, 507, "no space left")
    defp send_fil_error(conn, %Fil.UnavailableError{}), do: send_error(conn, 503, "the storage is unavailable")
    defp send_fil_error(conn, error), do: send_server_error(conn, error)

    # The message contains the path, the disk and what the storage reported, so it goes to the log and the client
    # gets a generic body.
    defp send_server_error(conn, error) do
      Logger.error("Fil.Plug: " <> Exception.message(error))
      send_error(conn, 500, "internal server error")
    end

    defp check_declared_size(length, max_body_size) when is_integer(length) and length > max_body_size,
      do: {:error, :too_large}

    defp check_declared_size(_length, _max_body_size), do: :ok

    defp content_length(conn) do
      with [value | _rest] <- get_req_header(conn, "content-length"),
           {length, ""} <- Integer.parse(value) do
        length
      else
        _missing_or_invalid -> nil
      end
    end

    defp send_error(conn, status, message) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(status, message)
    end
  end
end
