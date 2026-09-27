defmodule Fil.Support.Content do
  @moduledoc false

  alias Fil.Support.Sized
  alias Fil.Support.Telemetry

  # Content is iodata or a stream (any other enumerable of iodata). These helpers turn a stream into what
  # adapters, plugins and callers get: non-empty binaries, in order.

  @doc "Whether `content` is iodata rather than a stream. A list is iodata, even though it's enumerable too."
  @spec iodata?(term()) :: boolean()
  def iodata?(content), do: is_binary(content) or is_list(content)

  @doc "Raises unless `content` can be written: iodata or an enumerable."
  @spec validate!(term()) :: :ok
  def validate!(content) do
    if iodata?(content) or Enumerable.impl_for(content) != nil do
      :ok
    else
      raise ArgumentError, "expected the content to be iodata or an enumerable of iodata, got: #{inspect(content)}"
    end
  end

  @doc "The chunks of a stream as non-empty binaries. Iodata becomes a list of at most one binary."
  @spec chunks(iodata() | Enumerable.t()) :: Enumerable.t()
  def chunks(content) do
    if iodata?(content) do
      content
      |> IO.iodata_to_binary()
      |> List.wrap()
      |> Enum.reject(&(&1 == ""))
    else
      content
      |> Stream.map(&IO.iodata_to_binary/1)
      |> Stream.reject(&(&1 == ""))
    end
  end

  @doc "Collects content into one binary."
  @spec to_binary(iodata() | Enumerable.t()) :: binary()
  def to_binary(content) do
    if iodata?(content) do
      IO.iodata_to_binary(content)
    else
      content
      |> chunks()
      |> Enum.into(<<>>)
    end
  end

  @doc """
  The chunks of a stream, checked against the size the caller declared, so an adapter never finishes a write of the
  wrong size. Each chunk is passed on only once the next one has arrived, and the last one once the stream has ended
  at exactly `size` bytes. Storage that knows the size (a PutObject with its `content-length`) would store the content
  as soon as it has all of it, so a stream that turns out longer raises before the last chunk goes out, and one that
  ends short raises instead of ending.
  """
  @spec sized(Enumerable.t(), non_neg_integer() | nil, (String.t() -> Exception.t())) :: Enumerable.t()
  def sized(stream, size, mismatch \\ &ArgumentError.exception/1)

  def sized(stream, nil, _mismatch), do: chunks(stream)

  def sized(stream, size, mismatch) do
    stream
    |> chunks()
    |> Stream.transform(
      fn -> {[], 0} end,
      fn chunk, {held, count} ->
        count = count + byte_size(chunk)

        if count > size do
          raise mismatch.("the content has more than #{size} bytes, but the :size option is #{size}")
        end

        {held, {[chunk], count}}
      end,
      fn
        {held, ^size} -> {held, {[], size}}
        {_held, count} -> raise mismatch.("the content has #{count} bytes, but the :size option is #{size}")
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Fills in the context of `Fil`'s errors that `stream` raises while it's enumerated, the same as for errors that are
  returned. What the consumer's reducer raises (a write that reads the stream, and its plugins) passes through
  unchanged, so an error of the destination isn't reported as one of the source.

  With `telemetry`, the metadata of the op, each enumeration of the stream is a `[:fil, :stream]` span
  (`Fil.Telemetry`). The stream's own errors end it with `:exception`, the consumer's with a `:stop` that's `halted`.
  """
  @spec put_context(Enumerable.t(), keyword(), map() | nil) :: Enumerable.t()
  def put_context(stream, context, telemetry \\ nil)

  def put_context(%Sized{stream: stream} = sized, context, telemetry) do
    %{sized | stream: put_context(stream, context, telemetry)}
  end

  def put_context(stream, context, telemetry) do
    fn acc, fun ->
      ref = make_ref()
      span = Telemetry.stream_start(telemetry)
      reduce_with_context(&Enumerable.reduce(stream, &1, consumer(fun, ref)), with_bytes(acc, 0), context, ref, span)
    end
  end

  # The accumulator counts the bytes the consumer took, and notes whether it asked to halt: a source may end with
  # `:halted` on its own (`Stream.flat_map/2` does). The consumer's exceptions travel through the stream as a throw
  # tagged with `ref`, with the count, and are raised again as they were once they're out of it.
  defp consumer(fun, ref) do
    fn element, {acc, bytes, _halted} ->
      try do
        fun.(element, acc)
      catch
        kind, reason -> throw({ref, kind, reason, __STACKTRACE__, bytes})
      else
        {command, acc} -> {command, {acc, bytes + IO.iodata_length(element), command == :halt}}
      end
    end
  end

  defp with_bytes({command, acc}, bytes), do: {command, {acc, bytes, command == :halt}}

  defp reduce_with_context(continuation, acc, context, ref, span) do
    case continuation.(acc) do
      {:suspended, {acc, bytes, _halted}, continuation} ->
        {:suspended, acc, &reduce_with_context(continuation, with_bytes(&1, bytes), context, ref, span)}

      {result, {acc, bytes, halted}} when result in [:done, :halted] ->
        Telemetry.stream_stop(span, bytes, halted)
        {result, acc}
    end
  rescue
    error ->
      error = Fil.Support.Error.put_context(error, context)
      Telemetry.stream_exception(span, :error, error, __STACKTRACE__)
      reraise error, __STACKTRACE__
  catch
    :throw, {^ref, kind, reason, stacktrace, bytes} ->
      Telemetry.stream_stop(span, bytes, true)
      :erlang.raise(kind, reason, stacktrace)

    kind, reason ->
      Telemetry.stream_exception(span, kind, reason, __STACKTRACE__)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end
end
