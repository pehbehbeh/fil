defmodule Fil.Support.Relay do
  @moduledoc false

  # Passes each chunk of a download to the process reading it and waits until it asks for the next one, so a download
  # goes no faster than it's read and holds at most a chunk or two in memory. `Fil.Adapter.S3` gives `into/2` to Req as
  # `into:`, in a process of its own (see `Fil.Adapter.S3.stream/3`).
  #
  # The reader gets `{ref, :data, chunk}` and answers `{ref, :more}`. If the reader exits, the download stops.

  @enforce_keys [:to, :ref, :monitor]
  defstruct [:to, :ref, :monitor]

  @type t :: %__MODULE__{to: pid(), ref: reference(), monitor: reference()}

  @doc """
  The `into:` function for Req that relays the body of a `200`, or with `range`, of a `206`. A server that ignores the
  `Range` header answers with a `200` and the whole object, and only the range of it is relayed: the download stops
  once that's through. A function, because Req hands a collectable only the body of a `200`. The body of any other
  response, an error, is collected as the response body, as without `into:`.
  """
  @spec into(t(), Fil.Support.ByteRange.t() | nil) ::
          ({:data, binary()}, {Req.Request.t(), Req.Response.t()} -> {:cont | :halt, term()})
  def into(%__MODULE__{} = relay, range) do
    fn {:data, chunk}, acc -> receive_chunk(acc, chunk, relay, range) end
  end

  defp receive_chunk({request, %{status: 206} = response}, chunk, relay, range) when range != nil do
    relay(relay, chunk)
    {:cont, {request, response}}
  end

  defp receive_chunk({request, %{status: 200} = response}, chunk, relay, range) when range != nil do
    {parts, cut} = Fil.Support.ByteRange.cut(chunk, Req.Response.get_private(response, :fil_cut, range))
    Enum.each(parts, &relay(relay, &1))
    response = Req.Response.put_private(response, :fil_cut, cut)

    case cut do
      {_skip, 0} -> {:halt, {request, response}}
      _more -> {:cont, {request, response}}
    end
  end

  defp receive_chunk({request, %{status: 200} = response}, chunk, relay, nil) do
    relay(relay, chunk)
    {:cont, {request, response}}
  end

  defp receive_chunk({request, response}, chunk, _relay, _range) do
    {:cont, {request, %{response | body: response.body <> chunk}}}
  end

  defp relay(%__MODULE__{to: to, ref: ref, monitor: monitor}, chunk) do
    send(to, {ref, :data, chunk})

    receive do
      {^ref, :more} -> :ok
      {:DOWN, ^monitor, :process, _pid, _reason} -> exit(:normal)
    end
  end
end
