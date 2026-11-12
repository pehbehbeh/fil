defmodule Fil.ZipHelper do
  @moduledoc false

  # Builds zip archives byte by byte, for the cases `:zip.create/3` doesn't make: names that escape the root, other
  # compression methods, wrong CRC-32s, local headers that differ from the central directory, and Zip64 records.
  #
  # An entry is a map with `:name` and `:content`, and optionally:
  #
  #   * `:method` (0 stores, 8 deflates) and `:data`, the bytes as stored, for methods the helper can't compress
  #   * `:flags` (the UTF-8 flag is set without it), `:crc`, `:local_extra` and `:offset` as written
  #   * `:size`, the size the headers declare instead of the content's
  #   * `descriptor: true`, a data descriptor after the content, with zeros in the local header
  #   * `zip64_marker: true`, 0xFFFFFFFF as the size in the central directory without a Zip64 extra field

  @doc """
  The archive, as a binary. `zip64: true` writes every size and offset in Zip64 records. `:comment` is the archive's
  comment, and `:count` and `:cd_size` replace the values the end record would have.
  """
  @spec build([map()], keyword()) :: binary()
  def build(entries, opts \\ []) do
    zip64? = Keyword.get(opts, :zip64, false)

    {data, directory} = entries(entries, zip64?)
    count = Keyword.get(opts, :count, length(entries))
    cd_size = Keyword.get(opts, :cd_size, byte_size(directory))
    comment = Keyword.get(opts, :comment, "")

    data <>
      directory <> ending(count, cd_size, byte_size(data), zip64?) <> <<byte_size(comment)::16-little, comment::binary>>
  end

  # The local headers with their content, and the central directory.
  defp entries(entries, zip64?) do
    {locals, centrals, _offset} =
      Enum.reduce(entries, {[], [], 0}, fn entry, {locals, centrals, offset} ->
        {local, central} = entry(entry, offset, zip64?)
        {[local | locals], [central | centrals], offset + byte_size(local)}
      end)

    {in_order(locals), in_order(centrals)}
  end

  defp in_order(reversed) do
    reversed
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @doc "Deflates `content` without a zlib header, as zip archives store it."
  @spec deflate(binary()) :: binary()
  def deflate(content) do
    zlib = :zlib.open()
    :ok = :zlib.deflateInit(zlib, :default, :deflated, -15, 8, :default)
    deflated = :zlib.deflate(zlib, content, :finish)
    :zlib.close(zlib)
    IO.iodata_to_binary(deflated)
  end

  defp entry(entry, offset, zip64?) do
    content = Map.get(entry, :content, "")
    method = Map.get(entry, :method, 0)
    data = Map.get_lazy(entry, :data, fn -> stored(method, content) end)
    crc = Map.get(entry, :crc, :erlang.crc32(content))
    descriptor? = Map.get(entry, :descriptor, false)
    flags = Map.get(entry, :flags, 0x0800) + if(descriptor?, do: 0x0008, else: 0)
    name = entry.name

    {sizes, local_zip64, central_zip64} =
      entry
      |> Map.get(:size, byte_size(content))
      |> sizes(byte_size(data), offset, zip64?)

    {size32, compressed32, actual_offset32} = sizes
    offset32 = Map.get(entry, :offset, actual_offset32)
    central_size32 = if Map.get(entry, :zip64_marker, false), do: 0xFFFFFFFF, else: size32
    local_extra = local_zip64 <> Map.get(entry, :local_extra, "")

    {local_fields, descriptor} =
      if descriptor? do
        {<<0::96>>, <<0x08074B50::32-little, crc::32-little, compressed32::32-little, size32::32-little>>}
      else
        {<<crc::32-little, compressed32::32-little, size32::32-little>>, ""}
      end

    local =
      <<0x04034B50::32-little, 45::16-little, flags::16-little, method::16-little, 0::16, 0x21::16-little,
        local_fields::binary, byte_size(name)::16-little, byte_size(local_extra)::16-little, name::binary,
        local_extra::binary, data::binary, descriptor::binary>>

    central =
      <<0x02014B50::32-little, 45::16-little, 45::16-little, flags::16-little, method::16-little, 0::16,
        0x21::16-little, crc::32-little, compressed32::32-little, central_size32::32-little, byte_size(name)::16-little,
        byte_size(central_zip64)::16-little, 0::16, 0::16, 0::16, 0::32, offset32::32-little, name::binary,
        central_zip64::binary>>

    {local, central}
  end

  defp stored(0, content), do: content
  defp stored(8, content), do: deflate(content)

  defp sizes(size, compressed, offset, false), do: {{size, compressed, offset}, "", ""}

  defp sizes(size, compressed, offset, true) do
    local = <<0x0001::16-little, 16::16-little, size::64-little, compressed::64-little>>
    central = <<0x0001::16-little, 24::16-little, size::64-little, compressed::64-little, offset::64-little>>
    {{0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF}, local, central}
  end

  # The end record without its comment.
  defp ending(count, cd_size, cd_offset, false) do
    <<0x06054B50::32-little, 0::16, 0::16, count::16-little, count::16-little, cd_size::32-little,
      cd_offset::32-little>>
  end

  defp ending(count, cd_size, cd_offset, true) do
    record_offset = cd_offset + cd_size

    record =
      <<0x06064B50::32-little, 44::64-little, 45::16-little, 45::16-little, 0::32, 0::32, count::64-little,
        count::64-little, cd_size::64-little, cd_offset::64-little>>

    locator = <<0x07064B50::32-little, 0::32, record_offset::64-little, 1::32-little>>

    record <>
      locator <>
      <<0x06054B50::32-little, 0::16, 0::16, 0xFFFF::16-little, 0xFFFF::16-little, 0xFFFFFFFF::32-little,
        0xFFFFFFFF::32-little>>
  end
end
