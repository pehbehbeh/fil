defmodule Fil.Support.Content do
  @moduledoc false

  # Content is whole (iodata) or a stream (any other enumerable of iodata). These helpers turn a stream into what
  # adapters, plugins and callers get: non-empty binaries, in order.

  @doc "Whether `content` is whole iodata rather than a stream. A list is iodata, even though it's enumerable too."
  @spec whole?(term()) :: boolean()
  def whole?(content), do: is_binary(content) or is_list(content)

  @doc "Raises unless `content` can be written: iodata or an enumerable."
  @spec validate!(term()) :: :ok
  def validate!(content) do
    if whole?(content) or Enumerable.impl_for(content) != nil do
      :ok
    else
      raise ArgumentError, "expected the content to be iodata or an enumerable of iodata, got: #{inspect(content)}"
    end
  end

  @doc "The chunks of a stream as non-empty binaries. Whole content becomes a list of at most one binary."
  @spec chunks(iodata() | Enumerable.t()) :: Enumerable.t()
  def chunks(content) do
    if whole?(content) do
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
    if whole?(content) do
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
  @spec sized(Enumerable.t(), non_neg_integer() | nil) :: Enumerable.t()
  def sized(stream, nil), do: chunks(stream)

  def sized(stream, size) do
    stream
    |> chunks()
    |> Stream.transform(
      fn -> {[], 0} end,
      fn chunk, {held, count} ->
        count = count + byte_size(chunk)

        if count > size do
          raise ArgumentError, "the content has more than #{size} bytes, but the :size option is #{size}"
        end

        {held, {[chunk], count}}
      end,
      fn
        {held, ^size} -> {held, {[], size}}
        {_held, count} -> raise ArgumentError, "the content has #{count} bytes, but the :size option is #{size}"
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Fills in the context of `Fil`'s errors raised while `stream` is enumerated, the same as for errors that are returned.
  """
  @spec put_context(Enumerable.t(), keyword()) :: Enumerable.t()
  def put_context(stream, context) do
    fn acc, fun -> reduce_with_context(&Enumerable.reduce(stream, &1, fun), acc, context) end
  end

  defp reduce_with_context(continuation, acc, context) do
    case continuation.(acc) do
      {:suspended, acc, continuation} -> {:suspended, acc, &reduce_with_context(continuation, &1, context)}
      result -> result
    end
  rescue
    error -> reraise Fil.Support.Error.put_context(error, context), __STACKTRACE__
  end
end
