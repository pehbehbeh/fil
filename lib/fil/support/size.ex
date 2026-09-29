defmodule Fil.Support.Size do
  @moduledoc false

  # A size in bytes as text for people, in decimal units with one decimal place: "999 B", "1.5 KB", "5 MB". Used by the
  # status line of `Fil.Kino.upload/3` and by `Fil.LiveView`'s upload field.

  @units ~w(KB MB GB TB)

  @spec format(non_neg_integer()) :: String.t()
  def format(bytes) when bytes < 1000, do: "#{bytes} B"
  def format(bytes), do: format(bytes / 1000, @units)

  # A size that rounds to 1000.0 moves on to the next unit, so 999_999 bytes are "1 MB", not "1000 KB".
  defp format(size, [unit]), do: join(size, unit)
  defp format(size, [unit | _rest]) when size < 999.95, do: join(size, unit)
  defp format(size, [_unit | rest]), do: format(size / 1000, rest)

  defp join(size, unit) do
    rounded = Float.round(size, 1)
    number = if rounded == trunc(rounded), do: trunc(rounded), else: rounded
    "#{number} #{unit}"
  end
end
