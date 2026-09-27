defmodule Fil.Support.Checksum do
  @moduledoc false

  # Checksums in the encoding S3 uses for its `x-amz-checksum-*` headers: the raw digest, base64 encoded. A CRC32 is its
  # four bytes, big endian.

  @type algorithm :: :sha256 | :sha1 | :crc32

  @algorithms [:sha256, :sha1, :crc32]

  @doc "The supported algorithms."
  @spec algorithms() :: [algorithm()]
  def algorithms, do: @algorithms

  @doc "The checksum of `content`."
  @spec digest(algorithm(), iodata()) :: String.t()
  def digest(:crc32, content) do
    content
    |> :erlang.crc32()
    |> encode_crc32()
  end

  def digest(algorithm, content) do
    algorithm
    |> crypto()
    |> :crypto.hash(content)
    |> Base.encode64()
  end

  @doc "The checksum of a file, read in chunks so large files don't have to fit in memory."
  @spec digest_file(algorithm(), Path.t()) :: {:ok, String.t()} | {:error, File.posix()}
  def digest_file(algorithm, path) do
    with {:ok, {:ok, digest}} <- File.open(path, [:read, :binary, :raw], &hash_device(algorithm, &1)) do
      {:ok, digest}
    end
  end

  defp hash_device(:crc32, device) do
    with {:ok, crc} <- fold(device, 0, &:erlang.crc32/2), do: {:ok, encode_crc32(crc)}
  end

  defp hash_device(algorithm, device) do
    initial =
      algorithm
      |> crypto()
      |> :crypto.hash_init()

    with {:ok, state} <- fold(device, initial, &:crypto.hash_update/2) do
      {:ok,
       state
       |> :crypto.hash_final()
       |> Base.encode64()}
    end
  end

  defp fold(device, acc, fun) do
    case IO.binread(device, 65_536) do
      :eof -> {:ok, acc}
      {:error, reason} -> {:error, reason}
      chunk -> fold(device, fun.(acc, chunk), fun)
    end
  end

  # `:crypto` calls SHA-1 `:sha`.
  defp crypto(:sha1), do: :sha
  defp crypto(algorithm), do: algorithm

  defp encode_crc32(crc), do: Base.encode64(<<crc::unsigned-big-32>>)
end
