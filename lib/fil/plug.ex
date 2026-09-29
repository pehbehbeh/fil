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

    ## Responses

      * `GET` and `HEAD` on a URL signed for `:get` return the file, with its stored content type or one guessed from
        the extension, and the `content-disposition` the URL was signed with (`disposition:`). The file is streamed
        as a chunked response, so it never has to fit in memory
      * `PUT` on a URL signed for `:put` writes the request body, with the request's `content-type`, the same as a
        presigned PUT on S3. The body is streamed into `Fil.write/4` as it's read, with the `content-length` as
        `size:`. Plugins attached to the disk run as for any other write
      * a request that doesn't match its signature, or comes after the URL expired, gets a `403`
      * an upload larger than `:max_body_size` gets a `413`, and one whose body something else already read (see
        [Mounting](#module-mounting)) a `400`. Neither writes anything
      * a missing file gets a `404`, and so does a file the storage denies access to, so a client can't tell which
        files exist
      * a failed write gets a `409` if the file already exists or changed meanwhile, `422` if the disk refuses the
        content (a `Fil.InvalidRequestError` about the content, such as from `Fil.Plugin.Thumbnails` for a file that
        isn't an image), `507` if the storage is full and `503` if it's unavailable. Any other error is a `500` with a
        generic body, and its message goes to the `Logger`. So is S3's `InvalidRequest`, on a download too, because S3
        sends it for problems with the request or the bucket's configuration as well
    """

    @behaviour Plug

    import Plug.Conn

    require Logger

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
      with :ok <- Fil.Plugin.URL.verify(secret, method, conn.request_path, conn.query_string) do
        # A verified query has at most one `disposition`, and it's a string.
        case conn.query_params["disposition"] do
          nil -> {:ok, []}
          disposition -> {:ok, [{"content-disposition", disposition}]}
        end
      end
    end

    defp method(%{method: method}) when method in ["GET", "HEAD"], do: {:ok, :get}
    defp method(%{method: "PUT"}), do: {:ok, :put}
    defp method(_conn), do: {:error, :method_not_allowed}

    # The file is streamed to the client (`Fil.stream/3`), so its size doesn't matter. The response is chunked, because
    # plugins can change the content, and then the stored size isn't the size sent. An error while streaming comes
    # after the status line, so it raises and the client gets a truncated response.
    defp serve(conn, :get, disk, path, headers, _max_body_size) do
      with {:ok, stat} <- Fil.stat(disk, path),
           :regular <- stat.type,
           {:ok, content} <- Fil.stream(disk, path) do
        conn
        |> put_resp_content_type(stat.content_type || MIME.from_path(path), nil)
        |> merge_resp_headers(headers)
        |> send_content(content)
      else
        :directory -> send_error(conn, 404, "not found")
        {:error, error} -> send_fil_error(conn, error)
      end
    end

    # The request body is streamed into `Fil.write/4` as it's read, with the `content-length` as `size:`. A body that
    # breaks a rule while it's read stops the write with a throw, before the stream ends, so nothing is written.
    defp serve(conn, :put, disk, path, _headers, max_body_size) do
      opts =
        conn
        |> get_req_header("content-type")
        |> Enum.take(1)
        |> Enum.map(&{:content_type, &1})

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

    defp send_content(%{method: "HEAD"} = conn, _content), do: send_resp(conn, 200, "")

    defp send_content(conn, content) do
      Enum.reduce_while(content, send_chunked(conn, 200), fn chunk, conn ->
        case chunk(conn, chunk) do
          {:ok, conn} -> {:cont, conn}
          {:error, _closed} -> {:halt, conn}
        end
      end)
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
