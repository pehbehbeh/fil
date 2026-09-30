defmodule Fil.PlugHelper do
  @moduledoc false

  # Requests to `Fil.Plug` for its tests. The plug is mounted like `forward "/storage", Fil.Plug, disk: disk`: the
  # prefix is stripped from `path_info`, and `request_path` keeps it.

  import Plug.Conn
  import Plug.Test

  @doc "Sends a request to the URL `Fil.signed_url/3` built, served by the plug mounted at `/storage`."
  @spec request(atom(), String.t(), term(), binary() | nil) :: Plug.Conn.t()
  def request(method, url, disk, body \\ nil) do
    uri = URI.parse(url)

    method
    |> conn(uri.path <> "?" <> (uri.query || ""), body)
    |> call(disk)
  end

  @doc "Sends a request to the plug with `public: true`, at `/storage`."
  @spec public_request(atom(), String.t(), term(), binary() | nil) :: Plug.Conn.t()
  def public_request(method, path, disk, body \\ nil) do
    opts = Fil.Plug.init(at: "/storage", disk: disk, public: true)

    method
    |> conn(path, body)
    |> Fil.Plug.call(opts)
  end

  @doc "Runs `conn` through the plug mounted at `/storage`, with more plug options."
  @spec call(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def call(conn, disk, opts \\ []) do
    conn = %{conn | path_info: Enum.drop(conn.path_info, 1), script_name: ["storage"]}
    opts = Fil.Plug.init([disk: disk] ++ opts)

    Fil.Plug.call(conn, opts)
  end

  @doc "A `PUT` to `url` with `body` and request headers."
  @spec put(String.t(), binary(), [{String.t(), String.t()}]) :: Plug.Conn.t()
  def put(url, body, headers \\ []) do
    uri = URI.parse(url)
    conn = conn(:put, uri.path <> "?" <> uri.query, body)

    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
  end

  @doc "`disk`, with every write failing with `error`."
  @spec failing_writes(Fil.Disk.t(), Exception.t()) :: Fil.Disk.t()
  def failing_writes(disk, error) do
    Fil.attach(disk, :failing, fn
      %Fil.Op{name: :write} = op, _next, _opts -> Fil.Op.put_result(op, {:error, error})
      op, next, _opts -> next.(op)
    end)
  end
end
