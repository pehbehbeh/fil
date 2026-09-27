defmodule Fil.Support.Parts do
  @moduledoc false

  # Splits a stream into parts of one size, for storage that takes large content in parts (S3's multipart uploads).
  # Every part but the last has exactly the part size, because some S3-compatible services (Cloudflare R2) require
  # that. A part is iodata: the chunks as they came, and only the chunk that crosses a part boundary is split, with
  # `binary_part/3`, so nothing is copied. Memory is about one part plus one chunk.

  @mib 1_048_576

  # Many small chunks cost more memory as list cells than as bytes, so every run of this many chunks that holds less
  # than `@small_run_bytes` is joined into one binary.
  @small_run 1024
  @small_run_bytes @mib

  @doc """
  The part size for content of `size` bytes (`nil` if it isn't known), so it fits in `max_parts` parts. That's
  `part_size`, unless the content needs larger parts, which are then rounded up to a whole MiB.

      iex> Fil.Support.Parts.size(nil, 8_388_608, 10_000)
      8388608
      iex> Fil.Support.Parts.size(6 * 1024 ** 3, 8_388_608, 10_000)
      8388608
      iex> Fil.Support.Parts.size(100 * 1024 ** 3, 8_388_608, 10_000)
      11534336
      iex> Fil.Support.Parts.size(5 * 1024 ** 4, 8_388_608, 10_000)
      550502400

  """
  @spec size(non_neg_integer() | nil, pos_integer(), pos_integer()) :: pos_integer()
  def size(nil, part_size, _max_parts), do: part_size

  def size(size, part_size, max_parts) do
    needed = div(size + max_parts - 1, max_parts)

    if needed <= part_size, do: part_size, else: div(needed + @mib - 1, @mib) * @mib
  end

  @doc """
  Reduces `chunks`, non-empty binaries, into parts of `part_size` bytes, and calls `fun` with each full part and the
  accumulator. A part is passed on only once more content has arrived after it, so the last part is never empty, and
  content of at most `part_size` bytes never reaches `fun`.

  Returns `{:done, last, acc}` with the rest of the content, 0 to `part_size` bytes, or `{:halted, acc}` once `fun`
  returned `{:halt, acc}`. Halting stops reading `chunks`, which runs the stream's after functions.
  """
  @spec reduce(Enumerable.t(), pos_integer(), acc, (iodata(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:done, iodata(), acc} | {:halted, acc}
        when acc: term()
  def reduce(chunks, part_size, acc, fun) do
    result = Enum.reduce_while(chunks, {[], 0, 0, 0, acc}, &add(&2, &1, part_size, fun))

    case result do
      {:halted, acc} -> {:halted, acc}
      {buffer, _size, _run, _run_bytes, acc} -> {:done, Enum.reverse(buffer), acc}
    end
  end

  # The state is the buffered chunks in reverse, their size, and how many chunks (and bytes) came since the last join.
  defp add({buffer, size, run, run_bytes, acc}, chunk, part_size, _fun) when size + byte_size(chunk) <= part_size do
    bytes = byte_size(chunk)
    state = {[chunk | buffer], size + bytes, run + 1, run_bytes + bytes, acc}

    {:cont, join_small_run(state)}
  end

  defp add({buffer, size, _run, _run_bytes, acc}, chunk, part_size, fun) do
    fill = part_size - size
    rest = binary_part(chunk, fill, byte_size(chunk) - fill)

    part = close(buffer, chunk, fill)

    case fun.(part, acc) do
      {:cont, acc} -> add({[], 0, 0, 0, acc}, rest, part_size, fun)
      {:halt, acc} -> {:halt, {:halted, acc}}
    end
  end

  # The buffered chunks plus the first `fill` bytes of `chunk`, in order.
  defp close(buffer, _chunk, 0), do: Enum.reverse(buffer)

  defp close(buffer, chunk, fill) do
    head = binary_part(chunk, 0, fill)
    Enum.reverse(buffer, [head])
  end

  defp join_small_run({buffer, size, @small_run, run_bytes, acc}) when run_bytes <= @small_run_bytes do
    {run, older} = Enum.split(buffer, @small_run)

    joined =
      run
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    {[joined | older], size, 0, 0, acc}
  end

  defp join_small_run({buffer, size, @small_run, _run_bytes, acc}), do: {buffer, size, 0, 0, acc}
  defp join_small_run(state), do: state
end
