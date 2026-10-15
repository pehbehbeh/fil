defmodule Fil.Support.Download do
  @moduledoc false

  # The stream of a cloud download (`Fil.Adapter.S3`, `Fil.Adapter.AzureBlob`). Each time it's read, the request runs
  # in a process of its own, whose `into:` (`into/2`) passes each chunk to the reading process and waits until it asks
  # for the next one. So the download goes no faster than the stream is read and holds at most a chunk or two in
  # memory. With a checksum to check, the chunks update it on the way, and `verify` checks it against the response
  # headers once the download is done.
  #
  # The reader gets `{ref, :data, chunk}` and answers `{ref, :more}`. If the reader exits, the download stops.

  alias Fil.Support.Checksum

  # The handle the request process relays its chunks with: the reader, the ref of the download's messages, and the
  # monitor of the reader.
  @enforce_keys [:to, :ref, :monitor]
  defstruct [:to, :ref, :monitor]

  @type t :: %__MODULE__{to: pid(), ref: reference(), monitor: reference()}

  @typedoc "The checksum a download computes: `nil`, or a map whose `:checksum` is a `Fil.Support.Checksum` state."
  @type check :: %{required(:checksum) => Checksum.state(), optional(atom()) => term()} | nil

  @doc """
  The stream. `get` gets the handle, sends the request with `into(handle, range)` as Req's `into:`, and returns
  `{:ok, headers}` or `{:error, exception}`, which the stream raises. `label` names the download process in `:observer`
  and crash reports. `verify` gets the check and the response headers, and raises on a mismatch.
  """
  @spec stream(term(), (t() -> {:ok, map()} | {:error, Exception.t()}), check(), (check(), map() -> term())) ::
          Enumerable.t()
  def stream(label, get, check, verify) do
    Stream.resource(fn -> start(label, get, check, verify) end, &next_chunk/1, &stop/1)
  end

  @doc """
  The range of a download and the size of its stream, from the size the storage reported and the requested range. A
  range is clamped to the size, so the stream knows its size, and an empty range is `:empty` and downloads nothing
  (storage answers it with `416`). Without a size, the range stays as it is and the size is unknown.

      iex> Fil.Support.Download.range(10, {2, 100})
      {{2, 8}, 8}
      iex> Fil.Support.Download.range(10, {10, nil})
      :empty

  """
  @spec range(non_neg_integer() | nil, Fil.Support.ByteRange.t() | nil) ::
          {Fil.Support.ByteRange.t() | nil, non_neg_integer() | nil} | :empty
  def range(size, nil), do: {nil, size}
  def range(nil, range), do: {range, nil}

  def range(size, range) do
    case Fil.Support.ByteRange.clamp(range, size) do
      {_start, 0} -> :empty
      {start, count} -> {{start, count}, count}
    end
  end

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

  defp start(label, get, check, verify) do
    reader = self()
    ref = make_ref()
    # `$callers` lets the download find what the reader was allowed, such as a `Req.Test` stub.
    callers = [reader | Process.get(:"$callers", [])]

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.set_label(label)
        Process.put(:"$callers", callers)
        relay = %__MODULE__{to: reader, ref: ref, monitor: Process.monitor(reader)}
        send(reader, {ref, :done, get.(relay)})
      end)

    %{pid: pid, monitor: monitor, ref: ref, check: check, verify: verify}
  end

  defp next_chunk(%{pid: pid, monitor: monitor, ref: ref} = download) do
    receive do
      {^ref, :data, chunk} ->
        send(pid, {ref, :more})
        {[chunk], put_chunk(download, chunk)}

      {^ref, :done, result} ->
        finish!(download, result)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        crashed!(reason)
    end
  end

  defp put_chunk(%{check: nil} = download, _chunk), do: download

  defp put_chunk(%{check: check} = download, chunk) do
    %{download | check: %{check | checksum: Checksum.update(check.checksum, chunk)}}
  end

  defp finish!(%{check: nil} = download, {:ok, _headers}), do: {:halt, download}

  defp finish!(%{check: check, verify: verify} = download, {:ok, headers}) do
    verify.(check, headers)
    {:halt, download}
  end

  defp finish!(_download, {:error, error}), do: raise(error)

  # The download process only ends before it's done if it crashed, for example on bad `:req_options`.
  defp crashed!({%{__exception__: true} = exception, stacktrace}), do: reraise(exception, stacktrace)
  defp crashed!(reason), do: exit(reason)

  # Runs when the stream is done, halted early or raised. Stopping the download closes its connection. A chunk it sent
  # meanwhile arrives before the `:DOWN` of a new monitor, so it's dropped once that's in.
  defp stop(%{pid: pid, monitor: monitor, ref: ref}) do
    Process.demonitor(monitor, [:flush])
    stopped = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^stopped, :process, ^pid, _reason} -> flush(ref)
    end
  end

  defp flush(ref) do
    receive do
      {^ref, _tag, _value} -> flush(ref)
    after
      0 -> :ok
    end
  end
end
