defmodule Fil.Support.ByteRange do
  @moduledoc false

  # The part of a file that a read with `offset:` and `length:` returns. Adapters that know the size of the file clamp
  # the range to it with `clamp/2`, and `Fil.Op` slices content that a plugin answered with or transformed (`slice/2`).
  # A range past the end is empty, never an error.

  @type t :: {non_neg_integer(), pos_integer() | nil}

  @doc "The range of a read's options, or `nil` for the whole file."
  @spec from_options(keyword()) :: t() | nil
  def from_options(opts) do
    case {Keyword.get(opts, :offset, 0), Keyword.get(opts, :length)} do
      {0, nil} -> nil
      range -> range
    end
  end

  @doc "Removes the range from a read's options."
  @spec drop(keyword()) :: keyword()
  def drop(opts), do: Keyword.drop(opts, [:offset, :length])

  @doc "The start and the number of bytes of the range in a file of `size` bytes."
  @spec clamp(t(), non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def clamp({offset, _length}, size) when offset >= size, do: {size, 0}
  def clamp({offset, nil}, size), do: {offset, size - offset}
  def clamp({offset, length}, size), do: {offset, min(length, size - offset)}

  @doc "The range of `content`: a binary for iodata, a stream for a stream."
  @spec slice(iodata() | Enumerable.t(), t()) :: binary() | Enumerable.t()
  def slice(content, range) when is_binary(content) or is_list(content) do
    binary = IO.iodata_to_binary(content)
    {start, count} = clamp(range, byte_size(binary))
    binary_part(binary, start, count)
  end

  def slice(stream, {offset, length}) do
    Stream.transform(stream, fn -> {offset, length} end, &slice_chunk/2, fn _state -> :ok end)
  end

  # The state is the number of bytes still to skip and to take (`nil` for all). The stream halts once it has the range,
  # so the rest of the file isn't read.
  defp slice_chunk(_chunk, {_skip, 0} = state), do: {:halt, state}

  defp slice_chunk(chunk, {skip, take}) when skip >= byte_size(chunk), do: {[], {skip - byte_size(chunk), take}}

  defp slice_chunk(chunk, {skip, take}) do
    rest = binary_part(chunk, skip, byte_size(chunk) - skip)

    case take do
      nil -> {[rest], {0, nil}}
      take when take >= byte_size(rest) -> {[rest], {0, take - byte_size(rest)}}
      take -> {[binary_part(rest, 0, take)], {0, 0}}
    end
  end
end
