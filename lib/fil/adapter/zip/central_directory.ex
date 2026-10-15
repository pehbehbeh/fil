defmodule Fil.Adapter.Zip.CentralDirectory do
  @moduledoc false

  # Reads the list of entries at the end of a zip archive (APPNOTE.TXT, sections 4.3.12 to 4.3.16): the end of central
  # directory record, its Zip64 version for archives with large sizes or many entries, and the central directory it
  # points to. Every number in a zip archive is little endian.
  #
  # It costs a stat of the archive and one or two ranged reads: one for the tail, which holds the end record (after up
  # to 64 KiB of comment) and in a small archive the whole central directory too, and one for a central directory that
  # starts before the tail.

  alias Fil.Adapter.Zip.Archive
  alias Fil.Adapter.Zip.Entry

  import Bitwise

  @end_signature <<0x50, 0x4B, 0x05, 0x06>>
  @end_size 22
  @max_comment 65_535
  @zip64_locator_size 20
  @zip64_end_size 56
  @tail_size @end_size + @max_comment + @zip64_locator_size + @zip64_end_size

  @zip64_extra 0x0001
  @timestamp_extra 0x5455

  @doc """
  The entries of the archive that are part of the disk, in the archive's order and the first of each name. An entry
  belongs to the disk when its name is already the normalized path, so nothing outside the root, and no name that two
  spellings could reach.
  """
  @spec read(Fil.Ref.t()) :: {:ok, [Entry.t()]} | {:error, Fil.error()}
  def read(archive) do
    with {:ok, size} <- Archive.size(archive),
         tail_start = max(size - @tail_size, 0),
         {:ok, tail} <- Archive.read(archive, tail_start, size - tail_start),
         {:ok, directory, cd_offset} <- directory(archive, tail, tail_start),
         {:ok, entries} <- entries(directory, cd_offset, []) do
      {:ok, Enum.uniq_by(entries, &{&1.path, &1.type})}
    end
  end

  # The central directory and where it starts, from the tail if it holds all of it.
  defp directory(archive, tail, tail_start) do
    with {:ok, end_at} <- find_end(tail, tail_start),
         {:ok, cd_size, cd_offset} <- end_record(archive, tail, tail_start, end_at),
         :ok <- check_bounds(cd_offset + cd_size, tail_start + end_at),
         {:ok, directory} <- slice_or_read(archive, tail, tail_start, cd_offset, cd_size) do
      {:ok, directory, cd_offset}
    end
  end

  ## ------------------------------------------------------------------
  ## End of central directory
  ## ------------------------------------------------------------------

  # A record whose comment reaches exactly to the end of the archive. A comment may hold the signature, or a whole fake
  # record, so the last record whose central directory ends right where it starts wins, and the last one that fits
  # otherwise (a Zip64 archive has no 32-bit offsets to compare).
  defp find_end(tail, tail_start) do
    candidates =
      tail
      |> :binary.matches(@end_signature)
      |> Enum.map(&elem(&1, 0))
      |> Enum.reverse()
      |> Enum.filter(&end_fits?(tail, &1))

    case Enum.find(candidates, &directory_ends_at?(tail, &1, tail_start)) || List.first(candidates) do
      nil -> {:error, Archive.bad_archive(:no_end_record)}
      at -> {:ok, at}
    end
  end

  defp directory_ends_at?(tail, at, tail_start) do
    <<_before::binary-size(^at), _fields::binary-size(12), cd_size::32-little, cd_offset::32-little, _rest::binary>> =
      tail

    cd_offset + cd_size == tail_start + at
  end

  defp end_fits?(tail, at) do
    case tail do
      <<_before::binary-size(^at), _record::binary-size(20), comment_length::16-little, comment::binary>> ->
        byte_size(comment) == comment_length

      _short ->
        false
    end
  end

  defp end_record(archive, tail, tail_start, end_at) do
    <<_before::binary-size(^end_at), _signature::32, _disk::16, _cd_disk::16, _disk_entries::16, count::16-little,
      cd_size::32-little, cd_offset::32-little, _rest::binary>> = tail

    # The central directory is read to its end, so the number of entries is only needed to spot a Zip64 archive.

    # An archive can have exactly 0xFFFF entries or such a size without being a Zip64 archive, so the 32-bit values
    # count when there's no Zip64 locator.
    zip64? = count == 0xFFFF or cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF

    case zip64? && locator(tail, end_at) do
      {:ok, record_offset} -> zip64_end_record(archive, tail, tail_start, record_offset)
      _none -> {:ok, cd_size, cd_offset}
    end
  end

  # The Zip64 locator sits right before the end record and points to the Zip64 end record.
  defp locator(tail, end_at) when end_at >= @zip64_locator_size do
    locator_at = end_at - @zip64_locator_size

    case tail do
      <<_before::binary-size(^locator_at), 0x07064B50::32-little, _disk::32, at::64-little, _rest::binary>> ->
        {:ok, at}

      _other ->
        :none
    end
  end

  defp locator(_tail, _end_at), do: :none

  defp zip64_end_record(archive, tail, tail_start, record_offset) do
    with {:ok, record} <- slice_or_read(archive, tail, tail_start, record_offset, @zip64_end_size),
         <<0x06064B50::32-little, _size::64, _made::16, _needed::16, _disk::32, _cd_disk::32, _disk_entries::64,
           _count::64, cd_size::64-little, cd_offset::64-little>> <- record do
      {:ok, cd_size, cd_offset}
    else
      {:error, %Fil.ConfigurationError{reason: {:bad_archive, _where}}} ->
        {:error, Archive.bad_archive(:zip64_end_record)}

      {:error, _error} = error ->
        error

      _other ->
        {:error, Archive.bad_archive(:zip64_end_record)}
    end
  end

  defp check_bounds(cd_end, end_offset) when cd_end <= end_offset, do: :ok
  defp check_bounds(_cd_end, _end_offset), do: {:error, Archive.bad_archive(:central_directory)}

  # Bytes the tail already holds aren't read again.
  defp slice_or_read(_archive, tail, tail_start, offset, length)
       when offset >= tail_start and offset - tail_start + length <= byte_size(tail),
       do: {:ok, binary_part(tail, offset - tail_start, length)}

  defp slice_or_read(archive, _tail, _tail_start, offset, length), do: Archive.read(archive, offset, length)

  ## ------------------------------------------------------------------
  ## Central directory headers
  ## ------------------------------------------------------------------

  defp entries(<<>>, _cd_offset, acc), do: {:ok, Enum.reverse(acc)}

  defp entries(
         <<0x02014B50::32-little, _made::16, _needed::16, flags::16-little, method::16-little, time::16-little,
           date::16-little, crc::32-little, compressed_size::32-little, size::32-little, name_length::16-little,
           extra_length::16-little, comment_length::16-little, _disk::16, _internal::16, _external::32,
           offset::32-little, name::binary-size(name_length), extra::binary-size(extra_length),
           _comment::binary-size(comment_length), rest::binary>>,
         cd_offset,
         acc
       ) do
    fields = %{
      flags: flags,
      method: method,
      crc: crc,
      compressed_size: compressed_size,
      size: size,
      offset: offset,
      local_guess: name_length + extra_length
    }

    with {:ok, header} <- header(fields, extras(extra, %{}), {time, date}, cd_offset) do
      entries(rest, cd_offset, add_entry(acc, name, header))
    end
  end

  defp entries(_damaged, _cd_offset, _acc), do: {:error, Archive.bad_archive(:central_directory)}

  # The fields with their Zip64 values and the time, once they're checked.
  defp header(fields, extras, {time, date}, cd_offset) do
    with {:ok, size, compressed_size, offset} <- zip64_sizes(extras, fields),
         :ok <- check_entry(fields.method, size, compressed_size, offset + 30 + compressed_size, cd_offset) do
      fields = %{fields | size: size, compressed_size: compressed_size, offset: offset}
      {:ok, Map.put(fields, :mtime, mtime(extras, time, date))}
    end
  end

  # No zip tool writes a stored entry whose sizes differ, or an entry that reaches into the central directory, so either
  # means the archive is damaged. This also keeps a huge declared size from reading the rest of the archive.
  defp check_entry(0, size, compressed_size, _end, _cd_offset) when size != compressed_size,
    do: {:error, Archive.bad_archive(:central_directory)}

  defp check_entry(_method, _size, _compressed_size, entry_end, cd_offset) when entry_end > cd_offset,
    do: {:error, Archive.bad_archive(:central_directory)}

  defp check_entry(_method, _size, _compressed_size, _end, _cd_offset), do: :ok

  defp add_entry(acc, name, header) do
    case disk_path(name) do
      {:ok, path, type} -> [struct!(Entry, Map.merge(header, %{path: path, type: type})) | acc]
      :error -> acc
    end
  end

  defp disk_path(name) do
    {path, type} =
      name
      |> decode_name()
      |> split_slash()

    case Fil.Support.Path.normalize(path) do
      {:ok, ^path} when path != "." -> {:ok, path, type}
      _other -> :error
    end
  end

  # Names are UTF-8 when the flag says so. Without it the format says CP437, but most tools write UTF-8 anyway, so a
  # name that's valid UTF-8 is read as UTF-8, and any other as Latin-1, with the flag or without.
  defp decode_name(name), do: if(String.valid?(name), do: name, else: :unicode.characters_to_binary(name, :latin1))

  defp split_slash(name) do
    case String.replace_suffix(name, "/", "") do
      ^name -> {name, :regular}
      directory -> {directory, :directory}
    end
  end

  defp extras(<<id::16-little, length::16-little, data::binary-size(length), rest::binary>>, acc),
    do: extras(rest, Map.put_new(acc, id, data))

  defp extras(_rest, acc), do: acc

  # The Zip64 extra field holds the 64-bit values of the fields that are 0xFFFFFFFF, in this order.
  defp zip64_sizes(extras, %{size: size, compressed_size: compressed_size, offset: offset}) do
    data = Map.get(extras, @zip64_extra, <<>>)

    with {:ok, size, data} <- zip64_value(size, data),
         {:ok, compressed_size, data} <- zip64_value(compressed_size, data),
         {:ok, offset, _data} <- zip64_value(offset, data) do
      {:ok, size, compressed_size, offset}
    end
  end

  defp zip64_value(0xFFFFFFFF, <<value::64-little, rest::binary>>), do: {:ok, value, rest}
  defp zip64_value(0xFFFFFFFF, _missing), do: {:error, Archive.bad_archive(:zip64_extra)}
  defp zip64_value(value, data), do: {:ok, value, data}

  # The extended timestamp is in UTC. Without it, the MS-DOS time is local time, the way zip tools write it.
  defp mtime(%{@timestamp_extra => <<flags, mtime::32-little-signed, _rest::binary>>}, _time, _date)
       when (flags &&& 1) != 0, do: DateTime.from_unix!(mtime)

  defp mtime(_extras, time, date) do
    with {:ok, local} <- dos_time(time, date),
         {:ok, utc} <-
           local
           |> NaiveDateTime.to_erl()
           |> to_universal() do
      DateTime.from_naive!(utc, "Etc/UTC")
    else
      _invalid -> nil
    end
  end

  defp dos_time(time, date) do
    NaiveDateTime.new(
      1980 + (date >>> 9),
      date >>> 5 &&& 0x0F,
      date &&& 0x1F,
      time >>> 11,
      time >>> 5 &&& 0x3F,
      (time &&& 0x1F) * 2
    )
  end

  defp to_universal(local) do
    local
    |> :erlang.localtime_to_universaltime()
    |> NaiveDateTime.from_erl()
  end
end
