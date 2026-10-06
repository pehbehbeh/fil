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
  The `into:` function for Req that relays the body of a response with `status`, `200` for an object and `206` for a
  range. A function, because Req hands a collectable only the body of a `200`. The body of any other response, an
  error, is collected as the response body, as without `into:`.
  """
  @spec into(t(), pos_integer()) :: ({:data, binary()}, {Req.Request.t(), Req.Response.t()} -> {:cont, term()})
  def into(%__MODULE__{} = relay, status) do
    fn
      {:data, chunk}, {request, %{status: ^status} = response} ->
        relay(relay, chunk)
        {:cont, {request, response}}

      {:data, chunk}, {request, response} ->
        {:cont, {request, %{response | body: response.body <> chunk}}}
    end
  end

  defp relay(%__MODULE__{to: to, ref: ref, monitor: monitor}, chunk) do
    send(to, {ref, :data, chunk})

    receive do
      {^ref, :more} -> :ok
      {:DOWN, ^monitor, :process, _pid, _reason} -> exit(:normal)
    end
  end
end
