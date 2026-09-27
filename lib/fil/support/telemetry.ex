defmodule Fil.Support.Telemetry do
  @moduledoc false

  # Emits the events `Fil.Telemetry` documents: an `[:fil, :op]` span around each operation, and a `[:fil, :stream]`
  # span each time the stream of a streamed read is enumerated (see `Fil.Support.Content.put_context/3`).

  alias Fil.Disk
  alias Fil.Op
  alias Fil.Support.Content

  @typedoc """
  The start time and the metadata of a stream span, and whether it has ended, or `nil` for a stream without events.
  """
  @type stream_span :: {integer(), map(), :atomics.atomics_ref()} | nil

  @doc """
  Runs `fun` in an `[:fil, :op]` span for `op`, the operation as the caller made it. `fun` gets the op to run, whose
  stream content counts the bytes read from it, and the metadata, for the stream events of a streamed read.

    * `:metadata`: merged into the metadata
    * `:size`: the size of a write's content, when `Fil.write/4` knows it: the `:size` option, the length of iodata,
      which it measured when it checked the content, or the size of a stream it found
  """
  @spec span(Op.t(), keyword(), (Op.t(), map() -> Fil.result(term()))) :: Fil.result(term())
  def span(%Op{} = op, opts \\ [], fun) do
    metadata = metadata(op, Keyword.get(opts, :metadata, %{}))
    {op, bytes} = count(op, opts[:size])

    :telemetry.span([:fil, :op], metadata, fn ->
      result = fun.(op, metadata)
      {result, measurements(op, result, bytes), Map.put(metadata, :error, error(result))}
    end)
  end

  defp metadata(%Op{disk: disk, dest: dest} = op, extra) do
    metadata = %{
      op: op.name,
      disk: disk,
      adapter: Disk.adapter(disk),
      path: op.path,
      dest: dest,
      dest_disk: if(dest, do: disk),
      streaming: op.streaming
    }

    Map.merge(metadata, extra)
  end

  # A write knows its size up front when the caller declared it, when it passed iodata, which `Fil.write/4` measured,
  # or a stream whose size `Fil.write/4` found (a `File.Stream`, a stream from `Fil.stream/3`). The content is checked
  # against it. A stream without a size counts what's read from it. A counter works from any process, and a
  # third-party adapter may read the content in another one.
  defp count(%Op{name: :write} = op, size) when is_integer(size), do: {op, {:size, size}}

  defp count(%Op{name: :write, content: content} = op, nil) do
    if Content.iodata?(content) do
      {op, nil}
    else
      counter = :counters.new(1, [])
      {%{op | content: Stream.map(content, &count_chunk(&1, counter))}, {:counter, counter}}
    end
  end

  defp count(op, _size), do: {op, nil}

  defp count_chunk(chunk, counter) do
    :counters.add(counter, 1, IO.iodata_length(chunk))
    chunk
  end

  defp measurements(%Op{name: :write}, {:ok, _ref}, bytes) when bytes != nil, do: %{bytes: bytes(bytes)}

  defp measurements(%Op{name: :read, streaming: false}, {:ok, content}, _bytes), do: read_bytes(content)
  defp measurements(_op, _result, _bytes), do: %{}

  # A plugin may answer a read with iodata. Anything else has no size, and events never make a call fail.
  defp read_bytes(content) when is_binary(content), do: %{bytes: byte_size(content)}

  defp read_bytes(content) when is_list(content) do
    %{bytes: IO.iodata_length(content)}
  rescue
    ArgumentError -> %{}
  end

  defp read_bytes(_content), do: %{}

  defp bytes({:size, size}), do: size
  defp bytes({:counter, counter}), do: :counters.get(counter, 1)

  defp error({:error, error}), do: error
  defp error(_result), do: nil

  ## Streams

  @doc "Emits `[:fil, :stream, :start]` with the op's `metadata`, and returns the span for the other stream events."
  @spec stream_start(map() | nil) :: stream_span()
  def stream_start(nil), do: nil

  def stream_start(metadata) do
    metadata = Map.put(metadata, :telemetry_span_context, make_ref())
    start = System.monotonic_time()

    :telemetry.execute(
      [:fil, :stream, :start],
      %{monotonic_time: start, system_time: System.system_time()},
      metadata
    )

    {start, metadata, :atomics.new(1, [])}
  end

  @doc "Emits `[:fil, :stream, :stop]` once the stream has ended, was halted, or its consumer failed."
  @spec stream_stop(stream_span(), non_neg_integer(), boolean()) :: :ok
  def stream_stop(nil, _bytes, _halted), do: :ok

  def stream_stop({start, metadata, ended}, bytes, halted) do
    if ended?(ended) do
      :ok
    else
      stop = System.monotonic_time()

      :telemetry.execute(
        [:fil, :stream, :stop],
        %{duration: stop - start, monotonic_time: stop, bytes: bytes},
        Map.put(metadata, :halted, halted)
      )
    end
  end

  @doc "Emits `[:fil, :stream, :exception]` when the stream itself raised, threw or exited."
  @spec stream_exception(stream_span(), :error | :exit | :throw, term(), Exception.stacktrace()) :: :ok
  def stream_exception(nil, _kind, _reason, _stacktrace), do: :ok

  def stream_exception({start, metadata, ended}, kind, reason, stacktrace) do
    if ended?(ended) do
      :ok
    else
      stop = System.monotonic_time()

      :telemetry.execute(
        [:fil, :stream, :exception],
        %{duration: stop - start, monotonic_time: stop},
        Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
      )
    end
  end

  # A span ends once. Before Elixir 1.18, `Stream.transform/5` halts the stream it transforms once more when its last
  # function raises, although that stream has already ended, so a stream that ended short of the `:size` of a write
  # would otherwise end twice. Marks the span as ended, and returns whether it had already.
  defp ended?(ended), do: :atomics.exchange(ended, 1, 1) == 1
end
