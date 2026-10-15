defmodule Fil.ReqStub do
  @moduledoc false

  # The `Req.Test` stub of the cloud adapters' unit tests (`Fil.Adapter.S3Test`, `Fil.Adapter.AzureBlobTest`). Every
  # disk of a test module sends its requests to the stub named after the module, so no request reaches the network.
  # `stub/2` expects one request per response, in order, and `Req.Test.verify_on_exit!/1` checks that every response
  # was used. Req runs the stub after all its own request steps, and the stub messages the test each `Plug.Conn` it gets
  # (the body read into `conn.assigns.body`, and the label of the process that sent it in `conn.assigns.label`), so the
  # tests check what the adapter sent. It sends to the pid `stub/2` bound, not `self()`, so a request from another
  # process still reaches the test.

  import Plug.Conn

  @doc "The `:req_options` that send a disk's requests to the stub `name`."
  @spec req_options(module()) :: keyword()
  def req_options(name), do: [plug: {Req.Test, name}]

  @doc """
  Starts over: the responses of the previous `stub/2` must all have been used, and its requests are dropped. A response
  is `response/3`, or `{:error, reason}` for a failed connection.
  """
  @spec stub(module(), [map() | {:error, term()}]) :: :ok
  def stub(name, responses) do
    Req.Test.verify!(name)
    _previous = requests(name)
    test = self()

    for response <- responses, do: Req.Test.expect(name, &respond(&1, response, name, test))
    :ok
  end

  @doc "A response. A list body is sent in chunks, so a download gets them one by one."
  @spec response(pos_integer(), binary() | [binary()], [{String.t(), String.t()}]) :: map()
  def response(status, body \\ "", headers \\ []), do: %{status: status, body: body, headers: headers}

  @doc "The requests since the last `stub/2`, oldest first. Reading them takes them out of the mailbox."
  @spec requests(module(), [Plug.Conn.t()]) :: [Plug.Conn.t()]
  def requests(name, received \\ []) do
    receive do
      {^name, request} -> requests(name, [request | received])
    after
      0 -> Enum.reverse(received)
    end
  end

  @doc "The one request since the last `stub/2`."
  @spec request!(module()) :: Plug.Conn.t()
  def request!(name) do
    case requests(name) do
      [request] -> request
      other -> ExUnit.Assertions.flunk("expected exactly one request, got #{length(other)}")
    end
  end

  @doc "The first value of a request header, or `nil`."
  @spec header(Plug.Conn.t(), String.t()) :: String.t() | nil
  def header(request, name) do
    request
    |> get_req_header(name)
    |> List.first()
  end

  @doc "Answers `conn` with `response` and sends the request to `test`, for a stub of a test's own."
  @spec respond(Plug.Conn.t(), map() | {:error, term()}, module(), pid()) :: Plug.Conn.t()
  def respond(conn, response, name, test) do
    {:ok, body, conn} = read_body(conn)

    request =
      conn
      |> assign(:body, body)
      |> assign(:label, :proc_lib.get_label(self()))

    send(test, {name, request})
    reply(conn, response)
  end

  @doc "Answers `conn` with `response`."
  @spec reply(Plug.Conn.t(), map() | {:error, term()}) :: Plug.Conn.t()
  def reply(conn, {:error, reason}), do: Req.Test.transport_error(conn, reason)

  def reply(conn, %{status: status, body: chunks, headers: headers}) when is_list(chunks) do
    conn =
      conn
      |> merge_resp_headers(headers)
      |> send_chunked(status)

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = chunk(conn, chunk)
      conn
    end)
  end

  def reply(conn, %{status: status, body: body, headers: headers}) do
    conn
    |> merge_resp_headers(headers)
    |> send_resp(status, body)
  end
end
