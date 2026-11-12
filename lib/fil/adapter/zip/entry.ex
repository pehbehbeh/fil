defmodule Fil.Adapter.Zip.Entry do
  @moduledoc false

  # One entry of the central directory, and reading its content: the local file header before the content (APPNOTE.TXT,
  # section 4.3.7), then the content, stored or compressed with deflate.
  #
  # The local header has its own name and extra field, whose lengths can differ from the central directory's, so the
  # content starts only after it. A read of a whole entry asks for the header, the name and extra field of the central
  # directory's length and the content in one ranged read, and reads the content again only when the local fields are
  # longer.
  #
  # Inflating never produces more than the size the central directory declares: a deflated entry can expand a
  # thousandfold, so an entry that declares a small size and inflates to more fails as soon as it passes that size.

  alias Fil.Adapter.Zip.Archive
  alias Fil.Support.ByteRange
  alias Fil.Support.Checksum

  import Bitwise

  @enforce_keys [:path, :type]
  defstruct [:path, :type, :flags, :method, :crc, :compressed_size, :size, :offset, :mtime, :local_guess]

  @type t :: %__MODULE__{
          path: String.t(),
          type: :regular | :directory,
          flags: non_neg_integer(),
          method: non_neg_integer(),
          crc: non_neg_integer(),
          compressed_size: non_neg_integer(),
          size: non_neg_integer(),
          offset: non_neg_integer(),
          mtime: DateTime.t() | nil,
          local_guess: non_neg_integer()
        }

  @local_header_size 30
  @stored 0
  @deflated 8
  @encrypted_flag 0x0001

  @doc """
  The content of the entry, or the part `range` asks for. A stored entry's part is read on its own. A compressed entry's
  part is inflated from the start up to the end of the part, because deflate can't start in the middle. A whole entry
  is checked against its CRC-32.
  """
  @spec read(Fil.Ref.t(), t(), ByteRange.t() | nil) :: {:ok, binary()} | {:error, Fil.error()}
  def read(archive, entry, range) do
    with :ok <- check_readable(entry), do: read_content(archive, entry, range)
  end

  defp read_content(archive, %__MODULE__{method: @stored} = entry, nil) do
    with {:ok, content} <- content(archive, entry, 0, entry.compressed_size),
         :ok <- check(entry, byte_size(content), :erlang.crc32(content)),
         do: {:ok, content}
  end

  defp read_content(archive, %__MODULE__{method: @stored} = entry, range) do
    case ByteRange.clamp(range, entry.size) do
      {0, count} -> content(archive, entry, 0, count)
      {start, count} -> content_at(archive, entry, start, count)
    end
  end

  defp read_content(archive, entry, nil) do
    with {:ok, compressed} <- content(archive, entry, 0, entry.compressed_size) do
      collect(fn ->
        [compressed]
        |> inflating(entry)
        |> checked(entry)
        |> Enum.join()
      end)
    end
  end

  defp read_content(archive, entry, range) do
    with {:ok, stream, _size} <- stream(archive, entry, range), do: collect(fn -> Enum.join(stream) end)
  end

  @doc "The checksum of the whole entry, computed from its stream."
  @spec checksum(Fil.Ref.t(), t(), Checksum.algorithm()) :: {:ok, String.t()} | {:error, Fil.error()}
  def checksum(archive, entry, algorithm) do
    with {:ok, stream, _size} <- stream(archive, entry, nil) do
      collect(fn ->
        stream
        |> Enum.reduce(Checksum.init(algorithm), &Checksum.update(&2, &1))
        |> Checksum.final()
      end)
    end
  end

  @doc """
  A lazy stream of the content, or of the part `range` asks for, and its size. The local header is read now, the
  content each time the stream is enumerated, from the archive's own stream and inflated chunk by chunk. A whole entry
  is checked against its CRC-32 after the last chunk.
  """
  @spec stream(Fil.Ref.t(), t(), ByteRange.t() | nil) ::
          {:ok, Enumerable.t(), non_neg_integer()} | {:error, Fil.error()}
  def stream(archive, entry, range) do
    {start, count} = ByteRange.clamp(range || {0, nil}, entry.size)

    with :ok <- check_readable(entry),
         {:ok, content_start, _none} <- locate(archive, entry, 0, 0) do
      {:ok, content_stream(archive, entry, content_start, range, start, count), count}
    end
  end

  defp content_stream(_archive, _entry, _content_start, _range, _start, 0), do: []

  defp content_stream(archive, %__MODULE__{method: @stored} = entry, content_start, nil, _start, _count) do
    archive
    |> Archive.stream(content_start, entry.compressed_size)
    |> checked(entry)
  end

  defp content_stream(archive, %__MODULE__{method: @stored}, content_start, _range, start, count),
    do: Archive.stream(archive, content_start + start, count)

  defp content_stream(archive, entry, content_start, nil, _start, _count) do
    archive
    |> Archive.stream(content_start, entry.compressed_size)
    |> inflating(entry)
    |> checked(entry)
  end

  defp content_stream(archive, entry, content_start, range, _start, _count) do
    archive
    |> Archive.stream(content_start, entry.compressed_size)
    |> inflating(entry)
    |> ByteRange.slice(range)
  end

  defp check_readable(%__MODULE__{flags: flags}) when (flags &&& @encrypted_flag) != 0,
    do: {:error, %Fil.UnsupportedError{reason: :encrypted}}

  defp check_readable(%__MODULE__{method: method}) when method in [@stored, @deflated], do: :ok
  defp check_readable(%__MODULE__{method: method}), do: {:error, %Fil.UnsupportedError{reason: {:compression, method}}}

  defp check(%__MODULE__{size: size, crc: crc}, size, crc), do: :ok
  defp check(%__MODULE__{size: size}, other_size, _crc) when other_size != size, do: {:error, bad_entry(:size)}
  defp check(_entry, _size, _crc), do: {:error, %Fil.ChecksumMismatchError{reason: :checksum_mismatch}}

  # Damage confined to one entry: the rest of the archive can still be read.
  defp bad_entry(where), do: %Fil.ChecksumMismatchError{reason: {:bad_entry, where}}

  # Runs `fun`, which reads a stream, and returns the error a step of it raised.
  defp collect(fun) do
    {:ok, fun.()}
  rescue
    error -> if fil_error?(error), do: {:error, error}, else: reraise(error, __STACKTRACE__)
  end

  defp fil_error?(error), do: match?(%{op: _, path: _, disk: _, reason: _}, error)

  ## ------------------------------------------------------------------
  ## Local header
  ## ------------------------------------------------------------------

  # `count` bytes of the stored content from `skip` on, with the header in the same read.
  defp content(archive, entry, skip, count) do
    with {:ok, _content_start, bytes} <- locate(archive, entry, skip, count), do: {:ok, bytes}
  end

  # `count` bytes from `skip` on, read after the header, so a part of a large entry doesn't read the bytes before it.
  defp content_at(archive, entry, skip, count) do
    with {:ok, content_start, _none} <- locate(archive, entry, 0, 0),
         do: Archive.read(archive, content_start + skip, count)
  end

  defp locate(archive, entry, skip, count) do
    # The central directory follows the last entry, so reading past an entry's end never reaches the end of the archive.
    guess = @local_header_size + entry.local_guess

    with {:ok, bytes} <- Archive.read(archive, entry.offset, guess + skip + count),
         {:ok, fields} <- local_fields(bytes) do
      header = @local_header_size + fields
      content_after(archive, bytes, {entry.offset, header}, skip, count)
    end
  end

  # The content from the bytes read with the header, or read again when the local fields were longer than the guess.
  defp content_after(_archive, bytes, {offset, header}, skip, count) when header + skip + count <= byte_size(bytes),
    do: {:ok, offset + header, binary_part(bytes, header + skip, count)}

  defp content_after(archive, _bytes, {offset, header}, skip, count) do
    with {:ok, content} <- Archive.read(archive, offset + header + skip, count), do: {:ok, offset + header, content}
  end

  defp local_fields(
         <<0x04034B50::32-little, _needed::16, _flags::16, _method::16, _time::16, _date::16, _crc::32, _compressed::32,
           _size::32, name_length::16-little, extra_length::16-little, _rest::binary>>
       ), do: {:ok, name_length + extra_length}

  defp local_fields(_damaged), do: {:error, bad_entry(:local_header)}

  ## ------------------------------------------------------------------
  ## Inflating and checking
  ## ------------------------------------------------------------------

  # Inflates each chunk of compressed input lazily, one piece of zlib's buffer size at a time, so a chunk that expands a
  # thousandfold is never held whole. The zlib handle keeps its state between pieces and chunks.
  defp inflating(compressed, entry) do
    compressed
    |> Stream.transform(
      fn ->
        zlib = :zlib.open()
        :ok = :zlib.inflateInit(zlib, -15)
        zlib
      end,
      fn chunk, zlib -> {pieces(zlib, chunk), zlib} end,
      &:zlib.close/1
    )
    |> limited(entry)
  end

  defp pieces(zlib, chunk) do
    {:input, chunk}
    |> Stream.unfold(&next_piece!(zlib, &1))
    |> Stream.reject(&(&1 == ""))
  end

  defp next_piece!(_zlib, :finished), do: nil
  defp next_piece!(zlib, {:input, chunk}), do: piece!(zlib, chunk)
  defp next_piece!(zlib, :continue), do: piece!(zlib, [])

  defp piece!(zlib, input) do
    case :zlib.safeInflate(zlib, input) do
      {:continue, output} -> {IO.iodata_to_binary(output), :continue}
      {:finished, output} -> {IO.iodata_to_binary(output), :finished}
      _preset_dictionary -> raise bad_entry(:deflate)
    end
  rescue
    ErlangError -> reraise bad_entry(:deflate), __STACKTRACE__
  end

  # Raises before a piece takes the content past the entry's size, so the inflating stops there. Input that ends before
  # the content reaches that size is damaged too.
  defp limited(pieces, entry) do
    Stream.transform(
      pieces,
      fn -> 0 end,
      fn piece, total ->
        total = total + byte_size(piece)
        if total > entry.size, do: raise(bad_entry(:size))
        {[piece], total}
      end,
      fn total ->
        if total < entry.size, do: raise(bad_entry(:size))
        {[], total}
      end,
      fn _total -> :ok end
    )
  end

  # Counts and checksums the content as it passes, and raises after the last chunk when it doesn't match the entry.
  defp checked(content, entry) do
    Stream.transform(
      content,
      fn -> {0, :erlang.crc32(<<>>)} end,
      fn chunk, {size, crc} -> {[chunk], {size + byte_size(chunk), :erlang.crc32(crc, chunk)}} end,
      fn {size, crc} = acc ->
        case check(entry, size, crc) do
          :ok -> {[], acc}
          {:error, error} -> raise error
        end
      end,
      fn _acc -> :ok end
    )
  end
end
