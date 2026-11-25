defmodule Fil.PluginHelper do
  @moduledoc false

  # Plugins that change the size of what a disk delivers, for the tests of code that reads `stat.size`.

  @doc """
  `disk`, with reads that return every byte twice, and stats whose size `stat_size` maps (see `sized_stats/2`). Pass
  `&(&1 * 2)` for a plugin that reports the size it delivers.
  """
  @spec double_reads(Fil.Disk.t(), (non_neg_integer() -> non_neg_integer() | nil)) :: Fil.Disk.t()
  def double_reads(disk, stat_size) do
    disk
    |> Fil.attach(:double, fn op, next, _opts ->
      case next.(op) do
        %Fil.Op{name: :read} = op -> Fil.Op.update_result(op, iodata: &double/1)
        op -> op
      end
    end)
    |> sized_stats(stat_size)
  end

  @doc """
  `disk`, with the size of every file in `:stat` and `:ls` results mapped by `stat_size`. Pass `fn _size -> nil end` for
  a plugin that can't know the size it delivers. Stats without a size, such as directories, keep `nil`.
  """
  @spec sized_stats(Fil.Disk.t(), (non_neg_integer() -> non_neg_integer() | nil)) :: Fil.Disk.t()
  def sized_stats(disk, stat_size) do
    Fil.attach(disk, :sized, fn op, next, _opts ->
      case next.(op) do
        %Fil.Op{name: :stat, result: {:ok, stat}} = op ->
          Fil.Op.put_result(op, {:ok, resize(stat, stat_size)})

        %Fil.Op{name: :ls, result: {:ok, refs}} = op ->
          refs = Enum.map(refs, &resize_ref(&1, stat_size))
          Fil.Op.put_result(op, {:ok, refs})

        op ->
          op
      end
    end)
  end

  defp double(content) do
    binary = IO.iodata_to_binary(content)
    for <<byte <- binary>>, into: "", do: <<byte, byte>>
  end

  defp resize_ref(ref, stat_size), do: %{ref | stat: resize(ref.stat, stat_size)}

  defp resize(%Fil.Stat{size: size} = stat, stat_size) when is_integer(size), do: %{stat | size: stat_size.(size)}
  defp resize(stat, _stat_size), do: stat
end
