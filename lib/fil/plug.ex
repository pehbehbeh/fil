if Code.ensure_loaded?(Plug) do
  defmodule Fil.Plug do
    @schema NimbleOptions.new!(
              disk: [
                type: {:or, [{:struct, Fil.Disk}, {:fun, 0}, :mfa]},
                required: true,
                doc: """
                The disk to serve: a `Fil.Disk`, or a function or `{module, function, args}` that returns one. Use a
                function when the disk comes from runtime config, because plug options are compiled.
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
                Serves `GET` and `HEAD` without a signature, so every file on the disk can be downloaded by anyone who
                knows its path. That's where the URLs of `Fil.url/2` point. Uploads still need a URL signed by
                `Fil.Plugin.URL`.
                """
              ],
              max_body_size: [
                type: :pos_integer,
                default: 100 * 1024 * 1024,
                doc: """
                The largest upload in bytes, 100 MiB by default. A larger `PUT` gets a `413`, and nothing is written.
                Uploads are read into memory whole before they're written, so keep it at what your server can hold.
                """
              ]
            )

    @moduledoc """
    Serves the files of a disk over HTTP: the URLs `Fil.Plugin.URL` signs, or with `public: true`, every file.

    Signed URLs make direct downloads and uploads work on every disk: local and memory disks, which can't sign URLs
    themselves, and S3 disks whose files should go through your application.

    In a Phoenix app, put it in the endpoint before `Plug.Parsers`, at the path the plugin's `:base_url` points to:

        plug Fil.Plug, at: "/storage/uploads", disk: &MyApp.Storage.uploads/0

    The `:base_url` of the disk's `Fil.Plugin.URL` is then `"http://localhost:4000/storage/uploads"`, and every
    URL `Fil.signed_url/3` builds for it is served here. To run plugs of your own first, such as authentication, use
    a router instead (see [In a router](#module-in-a-router)).

    What it answers:

      * `GET` and `HEAD` on a URL signed for `:get` return the file, with its stored content type or one guessed from
        the extension, and the `content-disposition` the URL was signed with (`disposition:`)
      * `PUT` on a URL signed for `:put` writes the request body, with the request's `content-type`, the same as a
        presigned PUT on S3. Plugins attached to the disk run as for any other write
      * a request that doesn't match its signature, or comes after the URL expired, gets a `403`
      * an upload larger than `:max_body_size` gets a `413`, and one whose body something else already read (see
        [In a router](#module-in-a-router)) a `400`. Neither writes anything
      * a missing file gets a `404`, and so does a file the storage denies access to, so a client can't tell which
        files exist
      * a failed write gets a `409` if the file already exists, `507` if the storage is full and `503` if it's
        unavailable. Any other error is a `500` with a generic body, and its message goes to the `Logger`

    Requests pass through untouched when the disk doesn't sign URLs with `Fil.Plugin.URL` (and the plug isn't public).
    An S3 disk without it signs URLs that go to S3 directly, so the plug can stay in the endpoint when production uses
    S3.

    ## Public disks

    With `public: true`, the plug serves downloads without a signature, like `Plug.Static` for a disk:

        plug Fil.Plug, at: "/avatars", disk: &MyApp.Storage.avatars/0, public: true

    `GET /avatars/1.png` then returns `1.png` from the disk, on every adapter. There are no directory listings, and a
    path can't leave the disk root. With `Fil.Plugin.URL` and `base_url: "http://localhost:4000/avatars"` on the disk,
    `Fil.url/2` builds these URLs. Uploads still need a signed URL, and without a `:secret` for `Fil.Plugin.URL` on the
    disk, a `PUT` gets a `403`.

    ## In a router

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

    Needs [Plug](https://plug.hexdocs.pm), an optional dependency of `Fil`.

    ## Options

    #{NimbleOptions.docs(@schema)}
    """

    @behaviour Plug

    import Plug.Conn

    require Logger

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
           disk = disk(opts[:disk]),
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

    defp handle(conn, disk, secret, opts) do
      conn = fetch_query_params(conn)

      with {:ok, method} <- method(conn),
           {:ok, headers} <- authorize(conn, method, secret, opts[:public]) do
        # `path_info` keeps the percent-encoding of the request, and the disk wants the path itself.
        path = Enum.map_join(conn.path_info, "/", &URI.decode/1)

        serve(conn, method, disk, path, headers, opts[:max_body_size])
      else
        {:error, :method_not_allowed} -> send_error(conn, 405, "method not allowed")
        {:error, :expired} -> send_error(conn, 403, "the URL has expired")
        {:error, :invalid_signature} -> send_error(conn, 403, "the URL signature is invalid")
        {:error, :signature_required} -> send_error(conn, 403, "uploads need a signed URL")
      end
    end

    # Returns the response headers the signed URL asks for. A public download needs no signature, but only a valid one
    # can set the disposition, so nobody can make a link that serves the disk's files under another name.
    defp authorize(conn, :get, secret, true) do
      with {:error, _reason} <- authorize(conn, :get, secret, false), do: {:ok, []}
    end

    defp authorize(_conn, _method, nil, _public?), do: {:error, :signature_required}

    defp authorize(conn, method, secret, _public?) do
      with :ok <- Fil.Plugin.URL.verify(secret, method, conn.request_path, conn.query_params) do
        {:ok, Enum.map(List.wrap(conn.query_params["disposition"]), &{"content-disposition", &1})}
      end
    end

    defp disk(%Fil.Disk{} = disk), do: disk
    defp disk(fun) when is_function(fun, 0), do: fun.()
    defp disk({module, function, args}), do: apply(module, function, args)

    defp method(%{method: method}) when method in ["GET", "HEAD"], do: {:ok, :get}
    defp method(%{method: "PUT"}), do: {:ok, :put}
    defp method(_conn), do: {:error, :method_not_allowed}

    defp serve(conn, :get, disk, path, headers, _max_body_size) do
      with {:ok, stat} <- Fil.stat(disk, path),
           :regular <- stat.type,
           {:ok, content} <- Fil.read(disk, path) do
        conn
        |> put_resp_content_type(stat.content_type || MIME.from_path(path), nil)
        |> merge_resp_headers(headers)
        |> send_resp(200, if(conn.method == "HEAD", do: "", else: content))
      else
        :directory -> send_error(conn, 404, "not found")
        {:error, error} -> send_fil_error(conn, error)
      end
    end

    defp serve(conn, :put, disk, path, _headers, max_body_size) do
      opts =
        conn
        |> get_req_header("content-type")
        |> Enum.take(1)
        |> Enum.map(&{:content_type, &1})

      with :ok <- check_declared_size(conn, max_body_size),
           {:ok, body, conn} <- read_whole_body(conn, max_body_size, 0, []),
           {:ok, body, conn} <- check_complete(conn, body) do
        write(conn, disk, path, body, opts)
      else
        {:error, :too_large} ->
          too_large(conn, max_body_size)

        {:error, :too_large, conn} ->
          too_large(conn, max_body_size)

        {:error, :body, conn} ->
          send_error(conn, 400, "the request body could not be read")

        {:error, :already_read, conn} ->
          send_error(conn, 400, "the request body was already read, probably by Plug.Parsers")
      end
    end

    defp write(conn, disk, path, body, opts) do
      case Fil.write(disk, path, body, opts) do
        {:ok, _ref} -> send_resp(conn, 200, "")
        {:error, error} -> send_fil_error(conn, error)
      end
    end

    # A denied file is a 404 too, so a client can't tell which files exist.
    defp send_fil_error(conn, %error{})
         when error in [Fil.NotFoundError, Fil.AccessDeniedError, Fil.InvalidRequestError],
         do: send_error(conn, 404, "not found")

    defp send_fil_error(conn, %Fil.AlreadyExistsError{}), do: send_error(conn, 409, "the file already exists")
    defp send_fil_error(conn, %Fil.StorageFullError{}), do: send_error(conn, 507, "no space left")
    defp send_fil_error(conn, %Fil.UnavailableError{}), do: send_error(conn, 503, "the storage is unavailable")
    # The message contains the path, the disk and what the storage reported, so it goes to the log and the client
    # gets a generic body.
    defp send_fil_error(conn, error) do
      Logger.error("Fil.Plug: " <> Exception.message(error))
      send_error(conn, 500, "internal server error")
    end

    defp too_large(conn, max_body_size),
      do: send_error(conn, 413, "the request body is larger than #{max_body_size} bytes")

    # A `content-length` over the limit is refused before anything is read.
    defp check_declared_size(conn, max_body_size) do
      case content_length(conn) do
        length when is_integer(length) and length > max_body_size -> {:error, :too_large}
        _fits_or_unknown -> :ok
      end
    end

    # The limit is checked again while reading, for uploads without a `content-length` and clients that send more than
    # they declared. Uploads are still read whole into memory until `Fil.write` takes a stream.
    defp read_whole_body(conn, max_body_size, size, acc) do
      case read_body(conn) do
        {status, chunk, conn} when status in [:ok, :more] and size + byte_size(chunk) > max_body_size ->
          {:error, :too_large, conn}

        {:ok, chunk, conn} ->
          {:ok, IO.iodata_to_binary([acc, chunk]), conn}

        {:more, chunk, conn} ->
          read_whole_body(conn, max_body_size, size + byte_size(chunk), [acc, chunk])

        {:error, _reason} ->
          {:error, :body, conn}
      end
    end

    # `Plug.Parsers` reads the body of the content types it parses but leaves the headers alone, so a body shorter than
    # its `content-length` was read by something else before the plug.
    defp check_complete(conn, body) do
      case content_length(conn) do
        length when is_integer(length) and length != byte_size(body) -> {:error, :already_read, conn}
        _complete_or_unknown -> {:ok, body, conn}
      end
    end

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
