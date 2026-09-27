defmodule Fil.Support.Checksum do
  @moduledoc false

  # Checksums in the encoding S3 uses for its `x-amz-checksum-*` headers: the raw digest, base64 encoded. A CRC32 is its
  # four bytes, big endian.
  #
  # S3 stores the SHA checksum of an upload in parts as a composite checksum: the checksum of the parts' raw checksums,
  # base64 encoded, then `-` and the number of parts. `init_parts/2` computes one.

  @type algorithm :: :sha256 | :sha1 | :crc32

  @typedoc "A checksum being computed piece by piece, from `init/1` or `init_parts/2`."
  @opaque state ::
            {:crc32, non_neg_integer()}
            | {:crypto, :crypto.hash_state()}
            | {:parts, algorithm(), pos_integer(), state(), non_neg_integer(), [binary()]}

  @algorithms [:sha256, :sha1, :crc32]

  @doc "The supported algorithms."
  @spec algorithms() :: [algorithm()]
  def algorithms, do: @algorithms

  @doc "The checksum of `content`."
  @spec digest(algorithm(), iodata()) :: String.t()
  def digest(algorithm, content) do
    algorithm
    |> init()
    |> update(content)
    |> final()
  end

  @doc "Starts a checksum that `update/2` feeds and `final/1` finishes, for content that arrives in pieces."
  @spec init(algorithm()) :: state()
  def init(:crc32), do: {:crc32, :erlang.crc32(<<>>)}

  def init(algorithm) do
    {:crypto,
     algorithm
     |> crypto()
     |> :crypto.hash_init()}
  end

  @doc """
  Starts the composite checksum of content uploaded in parts of `part_size` bytes, the last one smaller.

      iex> alias Fil.Support.Checksum
      iex> :crc32 |> Checksum.init_parts(3) |> Checksum.update("ab") |> Checksum.update("cde") |> Checksum.final()
      "nkb4fw==-2"
      iex> parts = [Checksum.digest(:crc32, "abc"), Checksum.digest(:crc32, "de")]
      iex> Checksum.digest(:crc32, Enum.map(parts, &Base.decode64!/1))
      "nkb4fw=="

  """
  @spec init_parts(algorithm(), pos_integer()) :: state()
  def init_parts(algorithm, part_size), do: {:parts, algorithm, part_size, init(algorithm), 0, []}

  @doc "Adds the next piece of content."
  @spec update(state(), iodata()) :: state()
  def update({:crc32, crc}, data), do: {:crc32, :erlang.crc32(crc, data)}
  def update({:crypto, state}, data), do: {:crypto, :crypto.hash_update(state, data)}

  def update({:parts, algorithm, part_size, part, filled, digests}, data) do
    data = IO.iodata_to_binary(data)
    fill = part_size - filled

    if byte_size(data) < fill do
      {:parts, algorithm, part_size, update(part, data), filled + byte_size(data), digests}
    else
      head = binary_part(data, 0, fill)
      rest = binary_part(data, fill, byte_size(data) - fill)

      digest =
        part
        |> update(head)
        |> raw()

      update({:parts, algorithm, part_size, init(algorithm), 0, [digest | digests]}, rest)
    end
  end

  @doc "The checksum of everything added."
  @spec final(state()) :: String.t()
  def final({:parts, algorithm, _part_size, part, filled, digests}) do
    digests = if filled > 0 or digests == [], do: [raw(part) | digests], else: digests

    digest =
      digests
      |> Enum.reverse()
      |> then(&digest(algorithm, &1))

    count = length(digests)
    digest <> "-" <> Integer.to_string(count)
  end

  def final(state) do
    state
    |> raw()
    |> Base.encode64()
  end

  defp raw({:crc32, crc}), do: <<crc::unsigned-big-32>>
  defp raw({:crypto, state}), do: :crypto.hash_final(state)

  @doc "The checksum of a file, read in chunks so large files don't have to fit in memory."
  @spec digest_file(algorithm(), Path.t()) :: {:ok, String.t()} | {:error, File.posix()}
  def digest_file(algorithm, path) do
    with {:ok, {:ok, state}} <- File.open(path, [:read, :binary, :raw], &fold(&1, init(algorithm))) do
      {:ok, final(state)}
    end
  end

  defp fold(device, state) do
    case IO.binread(device, 65_536) do
      :eof -> {:ok, state}
      {:error, reason} -> {:error, reason}
      chunk -> fold(device, update(state, chunk))
    end
  end

  # `:crypto` calls SHA-1 `:sha`.
  defp crypto(:sha1), do: :sha
  defp crypto(algorithm), do: algorithm
end
