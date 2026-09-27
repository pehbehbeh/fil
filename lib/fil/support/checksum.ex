defmodule Fil.Support.Checksum do
  @moduledoc false

  # Checksums in the encoding S3 uses for its `x-amz-checksum-*` headers: the raw digest, base64 encoded. A CRC32 is its
  # four bytes, big endian.

  @type algorithm :: :sha256 | :sha1 | :crc32

  @typedoc "A checksum being computed piece by piece, from `init/1`."
  @opaque state :: {:crc32, non_neg_integer()} | {:crypto, :crypto.hash_state()}

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

  @doc "Adds the next piece of content."
  @spec update(state(), iodata()) :: state()
  def update({:crc32, crc}, data), do: {:crc32, :erlang.crc32(crc, data)}
  def update({:crypto, state}, data), do: {:crypto, :crypto.hash_update(state, data)}

  @doc "The checksum of everything added."
  @spec final(state()) :: String.t()
  def final({:crc32, crc}), do: Base.encode64(<<crc::unsigned-big-32>>)

  def final({:crypto, state}) do
    state
    |> :crypto.hash_final()
    |> Base.encode64()
  end

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
