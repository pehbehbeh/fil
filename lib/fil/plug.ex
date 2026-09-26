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
              ]
            )

    @moduledoc """
    Serves the files of a disk over HTTP: the URLs `Fil.Plugin.URL` signs, or with `public: true`, every file.

    Signed URLs make direct downloads and uploads work on every disk: local and memory disks, which can't sign URLs
    themselves, and S3 disks whose files should go through your application.

    In a Phoenix app, put it in the endpoint before `Plug.Parsers`, at the path the plugin's `:base_url` points to:

        plug Fil.Plug, at: "/storage/uploads", disk: &MyApp.Storage.uploads/0

    The `:base_url` of the disk's `Fil.Plugin.URL` is then `"http://localhost:4000/storage/uploads"`, and every
    URL `Fil.signed_url/3` builds for it is served here. `Plug.Parsers` would read the body of a JSON or form upload
    before a router sees it, so a `forward` in the router only works for uploads with other content types.

    What it answers:

      * `GET` and `HEAD` on a URL signed for `:get` return the file, with its stored content type or one guessed from
        the extension
      * `PUT` on a URL signed for `:put` writes the request body, with the request's `content-type`, the same as a
        presigned PUT on S3. Plugins attached to the disk run as for any other write
      * a request that doesn't match its signature, or comes after the URL expired, gets a `403`, and a missing file a
        `404`

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

    Needs [Plug](https://plug.hexdocs.pm), an optional dependency of `Fil`.

    ## Options

    #{NimbleOptions.docs(@schema)}
    """

    @behaviour Plug

    import Plug.Conn

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
        |> handle(disk, secret, opts[:public])
        |> Map.put(:path_info, conn.path_info)
        |> halt()
      else
        _outside_or_not_served -> conn
      end
    end

    defp handle(conn, disk, secret, public?) do
      conn = fetch_query_params(conn)

      with {:ok, method} <- method(conn),
           :ok <- authorize(conn, method, secret, public?) do
        # `path_info` keeps the percent-encoding of the request, and the disk wants the path itself.
        serve(conn, method, disk, Enum.map_join(conn.path_info, "/", &URI.decode/1))
      else
        {:error, :method_not_allowed} -> send_error(conn, 405, "method not allowed")
        {:error, :expired} -> send_error(conn, 403, "the URL has expired")
        {:error, :invalid_signature} -> send_error(conn, 403, "the URL signature is invalid")
        {:error, :signature_required} -> send_error(conn, 403, "uploads need a signed URL")
      end
    end

    defp authorize(_conn, :get, _secret, true), do: :ok
    defp authorize(_conn, _method, nil, _public?), do: {:error, :signature_required}

    defp authorize(conn, method, secret, _public?),
      do: Fil.Plugin.URL.verify(secret, method, conn.request_path, conn.query_params)

    defp disk(%Fil.Disk{} = disk), do: disk
    defp disk(fun) when is_function(fun, 0), do: fun.()
    defp disk({module, function, args}), do: apply(module, function, args)

    defp method(%{method: method}) when method in ["GET", "HEAD"], do: {:ok, :get}
    defp method(%{method: "PUT"}), do: {:ok, :put}
    defp method(_conn), do: {:error, :method_not_allowed}

    defp serve(conn, :get, disk, path) do
      with {:ok, stat} <- Fil.stat(disk, path),
           :regular <- stat.type,
           {:ok, content} <- Fil.read(disk, path) do
        conn
        |> put_resp_content_type(stat.content_type || MIME.from_path(path), nil)
        |> send_resp(200, if(conn.method == "HEAD", do: "", else: content))
      else
        _missing -> send_error(conn, 404, "not found")
      end
    end

    defp serve(conn, :put, disk, path) do
      opts =
        conn
        |> get_req_header("content-type")
        |> Enum.take(1)
        |> Enum.map(&{:content_type, &1})

      with {:ok, body, conn} <- read_whole_body(conn, []),
           {:ok, _ref} <- Fil.write(disk, path, body, opts) do
        send_resp(conn, 200, "")
      else
        {:error, :body} -> send_error(conn, 400, "the request body could not be read")
        {:error, reason} -> send_error(conn, 500, Fil.Error.format_reason(reason))
      end
    end

    defp read_whole_body(conn, acc) do
      case read_body(conn) do
        {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary([acc, chunk]), conn}
        {:more, chunk, conn} -> read_whole_body(conn, [acc, chunk])
        {:error, _reason} -> {:error, :body}
      end
    end

    defp send_error(conn, status, message) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(status, message)
    end
  end
end
