defmodule Fil.Adapter.S3.Checksums do
  @moduledoc false

  # The checksums S3 stores with an object (`x-amz-checksum-*`): of the whole object, or composite for an upload in
  # parts (the checksum of the parts' checksums, then `-` and the number of parts), and how `Fil.Adapter.S3` checks
  # content against them.

  alias Fil.Adapter.S3.Client
  alias Fil.Support.Checksum
  alias Fil.Support.ObjectStore

  @doc "The header that asks S3 for the stored checksum."
  @spec mode_header() :: {String.t(), String.t()}
  def mode_header, do: {"x-amz-checksum-mode", "ENABLED"}

  @doc "The header that carries a checksum of `algorithm`."
  @spec header_name(Checksum.algorithm()) :: String.t()
  def header_name(algorithm), do: "x-amz-checksum-#{algorithm}"

  @doc "The checksum header of `body` for `checksum:`, or none."
  @spec headers(keyword(), iodata()) :: [{String.t(), String.t()}]
  def headers(opts, body) do
    case Keyword.get(opts, :checksum) do
      nil -> []
      algorithm -> [{header_name(algorithm), Checksum.digest(algorithm, body)}]
    end
  end

  @doc """
  `{algorithm, checksum}` if S3 returned a checksum of the whole object for this algorithm. Composite checksums end in
  `-` and the number of parts, and cover the parts, so they're skipped (base64 has no `-`).
  """
  @spec stored(map(), Checksum.algorithm()) :: {Checksum.algorithm(), String.t()} | nil
  def stored(headers, algorithm) do
    case ObjectStore.header(headers, header_name(algorithm)) do
      nil -> nil
      checksum -> if !String.contains?(checksum, "-"), do: {algorithm, checksum}
    end
  end

  # `{algorithm, checksum, parts}` if S3 returned a composite checksum for this algorithm.
  defp composite(headers, algorithm) do
    with checksum when is_binary(checksum) <- ObjectStore.header(headers, header_name(algorithm)),
         [_digest, parts] <- String.split(checksum, "-"),
         {parts, ""} when parts > 0 <- Integer.parse(parts) do
      {algorithm, checksum, parts}
    else
      _none -> nil
    end
  end

  # The checksum stored with the object, of the whole object or composite, for the first algorithm that has one.
  defp find(headers) do
    Enum.find_value(Checksum.algorithms(), fn algorithm ->
      stored(headers, algorithm) || composite(headers, algorithm)
    end)
  end

  @doc "Checks the body of a GetObject against the checksum that came with it."
  @spec verify(Fil.Adapter.S3.t(), String.t(), Req.Response.t()) :: {:ok, binary()} | {:error, Exception.t()}
  def verify(state, key, %{body: body} = response) do
    case checksums(state, key, response) do
      {:ok, {same, same}} -> {:ok, body}
      {:ok, {_computed, _stored}} -> {:error, %Fil.ChecksumMismatchError{reason: :checksum_mismatch}}
      {:ok, nil} -> {:ok, body}
      {:error, error} -> {:error, error}
    end
  end

  # `{computed, stored}`, or `nil` if there's nothing to check.
  defp checksums(state, key, %{body: body} = response) do
    case find(response.headers) do
      nil -> {:ok, nil}
      {algorithm, checksum} -> {:ok, {Checksum.digest(algorithm, body), checksum}}
      {algorithm, composite, parts} -> composite_digest(state, key, response, algorithm, composite, parts)
    end
  end

  # `{:ok, nil}` when the parts can't be found (see `part_size/5`).
  defp composite_digest(state, key, %{body: body} = response, algorithm, composite, parts) do
    size = byte_size(body)

    with {:ok, part_size} when is_integer(part_size) <- part_size(state, key, response, size, parts) do
      computed =
        algorithm
        |> Checksum.init_parts(part_size)
        |> Checksum.update(body)
        |> Checksum.final()

      {:ok, {computed, composite}}
    end
  end

  @doc """
  What a download computes as it goes, from the checksum the HeadObject found: the checksum of the whole object, or a
  composite one, whose parts it then needs the size of. `nil` for none, or one that can't be checked.
  """
  @spec download_check(Fil.Adapter.S3.t(), String.t(), Req.Response.t()) :: {:ok, map() | nil} | {:error, Exception.t()}
  def download_check(state, key, response) do
    case find(response.headers) do
      nil ->
        {:ok, nil}

      {algorithm, _checksum} ->
        {:ok, %{algorithm: algorithm, checksum: Checksum.init(algorithm), composite: nil}}

      {algorithm, composite, parts} ->
        size = ObjectStore.content_length(response)

        with {:ok, part_size} <- part_size(state, key, response, size, parts) do
          {:ok, composite_check(algorithm, composite, part_size)}
        end
    end
  end

  defp composite_check(_algorithm, _composite, nil), do: nil

  defp composite_check(algorithm, composite, part_size) do
    %{algorithm: algorithm, checksum: Checksum.init_parts(algorithm, part_size), composite: composite}
  end

  @doc """
  Compares a download with the checksum the GetObject returned, which belongs to the content that was downloaded. An
  object replaced since the HeadObject may have none for this algorithm, or parts of another size, and is then read
  without a check, like a read.
  """
  @spec verify_download!(map(), map()) :: :ok | nil
  def verify_download!(check, headers) do
    case downloaded_checksum(check, headers) do
      nil ->
        :ok

      stored ->
        if Checksum.final(check.checksum) != stored, do: raise(%Fil.ChecksumMismatchError{reason: :checksum_mismatch})
    end
  end

  defp downloaded_checksum(%{algorithm: algorithm, composite: nil}, headers) do
    with {^algorithm, stored} <- stored(headers, algorithm), do: stored
  end

  defp downloaded_checksum(%{algorithm: algorithm, composite: composite}, headers) do
    if ObjectStore.header(headers, header_name(algorithm)) == composite, do: composite
  end

  # A composite checksum can only be checked with the size of the parts, which S3 doesn't store with it, but a
  # HeadObject for part 1 returns. Every part but the last has that size in uploads from `Fil` and from AWS's tools,
  # which is all the check assumes. Parts that don't add up to the object, and a server that ignores `partNumber`
  # (RustFS answers with the whole object), give `nil`, and the content is read without a check. So does a server that
  # refuses `partNumber` (`400`, `501`). `If-Match` makes sure part 1 belongs to the object that was read, and an object
  # replaced or removed since then is read without a check. A failed connection or a `5xx` fails the read.
  defp part_size(state, key, response, size, parts) do
    headers = Enum.map(response.headers["etag"] || [], &{"if-match", &1})

    case Client.request(state, :head, key, params: [{"partNumber", 1}], headers: headers) do
      {:ok, %{status: status} = part} when status in [200, 206] ->
        {:ok, uniform_part_size(ObjectStore.content_length(part), size, parts)}

      {:ok, %{status: status}} when status in [400, 404, 412, 501] ->
        {:ok, nil}

      {:ok, response} ->
        {:error, Client.error(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp uniform_part_size(part_size, size, parts) when is_integer(part_size) and part_size > 0 and is_integer(size) do
    last = size - (parts - 1) * part_size
    if last > 0 and last <= part_size, do: part_size
  end

  defp uniform_part_size(_part_size, _size, _parts), do: nil
end
