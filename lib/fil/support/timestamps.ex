defmodule Fil.Support.Timestamps do
  @moduledoc false

  # The two timestamp formats object stores use: RFC 1123 in headers, ISO 8601 in listings.

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @doc ~S'Parses `"Wed, 21 Oct 2015 07:28:00 GMT"`; anything else is `nil`.'
  @spec parse_http_date(String.t() | nil) :: DateTime.t() | nil
  def parse_http_date(nil), do: nil

  def parse_http_date(value) do
    with [_weekday, day, month, year, time, _zone] <- String.split(value, " ", trim: true),
         {:ok, month} <- Map.fetch(@months, month),
         {:ok, datetime, _offset} <- DateTime.from_iso8601("#{year}-#{pad(month)}-#{pad(day)}T#{time}Z") do
      datetime
    else
      _other -> nil
    end
  end

  @doc "Parses an ISO 8601 timestamp; anything else is `nil`."
  @spec parse_iso8601(String.t() | nil) :: DateTime.t() | nil
  def parse_iso8601(nil), do: nil

  def parse_iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      {:error, _reason} -> nil
    end
  end

  defp pad(value) do
    value
    |> to_string()
    |> String.pad_leading(2, "0")
  end
end
