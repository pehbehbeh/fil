defmodule Fil.Support.Conditional do
  @moduledoc false

  # Conditional and range requests for `Fil.Plug` (RFC 9110, sections 13 and 14): the validators of a file from its
  # stat, whether a request's conditions hold, and which byte range a `Range` header asks for. Plain functions on header
  # values, so they don't need Plug.

  alias Fil.Stat

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
          |> Enum.with_index(1)
          |> Map.new(fn {name, number} ->
            {name,
             number
             |> Integer.to_string()
             |> String.pad_leading(2, "0")}
          end)

  @doc "The `ETag` header value of a file, or `nil` if the storage gave none."
  @spec etag(Stat.t()) :: String.t() | nil
  def etag(%Stat{etag: nil}), do: nil
  def etag(%Stat{etag: etag}), do: ~s("#{etag}")

  @doc "The `Last-Modified` header value of a file, or `nil` if the storage gave no time."
  @spec last_modified(Stat.t()) :: String.t() | nil
  def last_modified(%Stat{mtime: nil}), do: nil
  def last_modified(%Stat{mtime: mtime}), do: http_date(mtime)

  @doc """
  Whether a `GET` or `HEAD` gets a `304`: `If-None-Match` lists the file's etag (compared weakly) or is `*`, or, without
  `If-None-Match`, the file hasn't changed since `If-Modified-Since`. Takes the values of both headers.
  """
  @spec not_modified?(Stat.t(), [String.t()], [String.t()]) :: boolean()
  def not_modified?(stat, [_ | _] = if_none_match, _if_modified_since) do
    tags = Enum.flat_map(if_none_match, &String.split(&1, ","))
    Enum.any?(tags, &(String.trim(&1) == "*")) or (stat.etag != nil and Enum.any?(tags, &weak_match?(&1, stat)))
  end

  def not_modified?(%Stat{mtime: %DateTime{} = mtime}, [], [since]) do
    case parse_http_date(since) do
      {:ok, since} ->
        mtime
        |> DateTime.truncate(:second)
        |> DateTime.compare(since) != :gt

      :error ->
        false
    end
  end

  def not_modified?(_stat, _if_none_match, _if_modified_since), do: false

  defp weak_match?(tag, stat), do: opaque(tag) == opaque(etag(stat))

  defp opaque(tag) do
    case String.trim(tag) do
      "W/" <> tag -> tag
      tag -> tag
    end
  end

  @doc """
  The range a `GET` with these `Range` and `If-Range` header values gets, for a file of `size` bytes:

    * `:whole` for no range, one that can't be parsed, several ranges, or an `If-Range` that doesn't match the file
    * `{:range, offset, length}` for one byte range, cut to the size of the file
    * `:unsatisfiable` for a range that starts at or after the end, a suffix of 0 bytes, or any range of an empty file
  """
  @spec range(Stat.t(), [String.t()], [String.t()]) ::
          :whole | :unsatisfiable | {:range, non_neg_integer(), pos_integer()}
  def range(%Stat{size: size} = stat, [value], if_range) when is_integer(size) do
    with true <- if_range?(stat, if_range),
         {:ok, spec} <- parse_range(value) do
      resolve(spec, size)
    else
      _whole -> :whole
    end
  end

  def range(_stat, _range, _if_range), do: :whole

  # `If-Range` takes a strong etag or the exact `Last-Modified` date.
  defp if_range?(_stat, []), do: true
  defp if_range?(stat, [~s(") <> _rest = tag]), do: stat.etag != nil and String.trim(tag) == etag(stat)
  defp if_range?(%Stat{mtime: nil}, [_date]), do: false
  defp if_range?(stat, [date]), do: parse_http_date(date) == {:ok, DateTime.truncate(stat.mtime, :second)}
  defp if_range?(_stat, _several), do: false

  defp parse_range(value) do
    with [unit, spec] <- String.split(value, "=", parts: 2),
         "bytes" <-
           unit
           |> String.trim()
           |> String.downcase(),
         [first, last] <-
           spec
           |> String.trim()
           |> String.split("-", parts: 2) do
      parse_spec(first, last)
    else
      _invalid -> :error
    end
  end

  defp parse_spec("", last) do
    with {:ok, count} <- parse_integer(last), do: {:ok, {:suffix, count}}
  end

  defp parse_spec(first, last) do
    with {:ok, first} <- parse_integer(first),
         {:ok, last} <- parse_last(last),
         true <- last == nil or last >= first do
      {:ok, {first, last}}
    else
      _invalid -> :error
    end
  end

  defp parse_last(""), do: {:ok, nil}
  defp parse_last(last), do: parse_integer(last)

  # Digits only: no sign or spaces, and a comma (several ranges) makes the range invalid too.
  defp parse_integer(value) do
    if value =~ ~r/\A\d+\z/, do: {:ok, String.to_integer(value)}, else: :error
  end

  defp resolve(_spec, 0), do: :unsatisfiable
  defp resolve({:suffix, 0}, _size), do: :unsatisfiable
  defp resolve({:suffix, count}, size), do: {:range, max(size - count, 0), min(count, size)}
  defp resolve({first, _last}, size) when first >= size, do: :unsatisfiable
  defp resolve({first, nil}, size), do: {:range, first, size - first}
  defp resolve({first, last}, size), do: {:range, first, min(last, size - 1) - first + 1}

  @doc "Formats a time as an HTTP date: `Sun, 06 Nov 1994 08:49:37 GMT`."
  @spec http_date(DateTime.t()) :: String.t()
  def http_date(%DateTime{} = time) do
    time
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  @doc """
  Parses an HTTP date in the format every sender has to use (IMF-fixdate). A date in one of the obsolete formats is an
  `:error`, which means no `304` and the whole file for `If-Range`: the safe side.
  """
  @spec parse_http_date(String.t()) :: {:ok, DateTime.t()} | :error
  def parse_http_date(value) do
    pattern = ~r/\A[A-Z][a-z]{2}, (\d{2}) ([A-Z][a-z]{2}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT\z/

    with [day, month, year, time] <- Regex.run(pattern, String.trim(value), capture: :all_but_first),
         {:ok, month} <- Map.fetch(@months, month),
         {:ok, datetime, 0} <- DateTime.from_iso8601("#{year}-#{month}-#{day}T#{time}Z") do
      {:ok, datetime}
    else
      _invalid -> :error
    end
  end
end
