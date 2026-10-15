defmodule Fil.Adapter.S3.MultipartUpload do
  @moduledoc false

  # A multipart upload of `Fil.Adapter.S3`: its state (the upload id, the parts and their ETags, the checksum) and its
  # steps (create, upload each part, complete). See the moduledoc's Uploads in parts.

  alias Fil.Adapter.S3.Checksums
  alias Fil.Adapter.S3.Client
  alias Fil.Adapter.S3.UploadGuard
  alias Fil.Support.Checksum
  alias Fil.Support.ObjectStore
  alias Fil.Support.Parts
  alias Fil.Support.XML

  @doc """
  Writes `content` to `key` in parts of `:part_size`, or larger ones for a known `size` that would need more than
  10,000. Content that ends within the first part comes back as `{:single, content}`, for the adapter to send as one
  PutObject. Anything larger starts a multipart upload once the second part begins, uploads each part when it's full,
  and completes the upload after the content has ended, so nothing is written unless it ends.

  A guard process (`Fil.Adapter.S3.UploadGuard`) creates the upload and is the only one that aborts it: when the write
  fails, raises or is killed. The content is read and the parts are uploaded in the calling process.
  """
  @spec upload(Fil.Adapter.S3.t(), String.t(), Enumerable.t(), non_neg_integer() | nil, keyword()) ::
          :ok | {:single, iodata()} | {:error, Exception.t()}
  def upload(state, key, content, size, opts) do
    guard = UploadGuard.start(state, key)
    algorithm = opts[:checksum]

    upload = %{
      key: key,
      guard: guard,
      id: nil,
      number: 0,
      parts: [],
      algorithm: algorithm,
      whole: if(algorithm == :crc32, do: Checksum.init(:crc32))
    }

    part_size = Parts.size(size, state.part_size, state.max_parts)

    try do
      content
      |> Parts.reduce(part_size, upload, &next_part(state, &1, &2, opts))
      |> finish_upload(state, opts)
    else
      :ok ->
        UploadGuard.stop(guard, :done)

      {:single, content} ->
        UploadGuard.stop(guard, :done)
        {:single, content}

      {:error, error} ->
        UploadGuard.stop(guard, :abort)
        {:error, error}
    catch
      kind, reason ->
        UploadGuard.stop(guard, :abort)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp next_part(state, part, upload, opts) do
    ObjectStore.next_part(upload.number, state.max_parts, fn -> upload_part(state, part, upload, opts) end)
  end

  defp finish_upload({:halted, {:error, error}}, _state, _opts), do: {:error, error}
  defp finish_upload({:done, last, %{id: nil}}, _state, _opts), do: {:single, last}

  defp finish_upload({:done, last, upload}, state, opts) do
    with {:ok, upload} <- upload_part(state, last, upload, opts), do: complete_upload(state, upload, opts)
  end

  # With `checksum:`, every part is sent with its checksum, which S3 checks. A CRC32 is also computed over all of the
  # content, which S3 checks when the upload completes and stores as the object's checksum.
  defp upload_part(state, part, upload, opts) do
    checksum = upload.algorithm && Checksum.digest(upload.algorithm, part)
    headers = part_checksum_header(upload.algorithm, checksum)

    with {:ok, upload} <- create_upload(upload, opts),
         number = upload.number + 1,
         {:ok, etag} <- send_part(state, upload, number, part, headers) do
      {:ok,
       %{
         upload
         | number: number,
           parts: [{number, etag, checksum} | upload.parts],
           whole: upload.whole && Checksum.update(upload.whole, part)
       }}
    end
  end

  defp part_checksum_header(nil, _checksum), do: []
  defp part_checksum_header(algorithm, checksum), do: [{Checksums.header_name(algorithm), checksum}]

  # S3 only stores and checks the checksums of an upload in parts when the upload declares the algorithm up front.
  # CRC32 can cover the whole object (`FULL_OBJECT`). SHA-1 and SHA-256 can't, so S3 stores a checksum of the parts'
  # checksums (`COMPOSITE`, the default), which ends in `-` and the number of parts.
  defp create_upload(%{id: nil, guard: guard} = upload, opts) do
    headers = [{"content-length", "0"} | Client.content_type_header(opts)] ++ algorithm_headers(upload.algorithm)

    with {:ok, id} <- UploadGuard.create(guard, headers), do: {:ok, %{upload | id: id}}
  end

  defp create_upload(upload, _opts), do: {:ok, upload}

  # A part is in memory and invisible until the upload completes, so a part that failed with `Fil.UnavailableError` is
  # sent once more, a second later (`SlowDown` and `503` are unavailable too). The ETag goes into the completion as S3
  # sent it, quotes included.
  defp send_part(state, upload, number, part, headers) do
    params = [{"partNumber", number}, {"uploadId", upload.id}]

    ObjectStore.retry_unavailable(
      fn ->
        case Client.request(state, :put, upload.key, params: params, headers: headers, body: part) do
          {:ok, %{status: 200} = response} -> etag(response.headers)
          {:ok, response} -> {:error, Client.error(response)}
          {:error, reason} -> {:error, reason}
        end
      end,
      state.retry_delay
    )
  end

  defp etag(headers) do
    case ObjectStore.header(headers, "etag") do
      nil -> {:error, %Fil.UnknownError{reason: :missing_etag}}
      etag -> {:ok, etag}
    end
  end

  # `if_exists: :error` can only be checked here: S3 takes `If-None-Match` on the completion, and not before.
  defp complete_upload(state, upload, opts) do
    headers =
      upload
      |> whole_checksum_headers()
      |> ObjectStore.put_if_exists(opts)

    params = [{"uploadId", upload.id}]

    case Client.request(state, :post, upload.key, params: params, headers: headers, body: completion(upload)) do
      {:ok, %{status: 200} = response} -> Client.xml_result(response)
      {:ok, response} -> {:error, Client.error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp completion(%{parts: parts, algorithm: algorithm}) do
    parts =
      parts
      |> Enum.reverse()
      |> Enum.map(&completed_part(&1, algorithm))

    [~s(<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">), parts, "</CompleteMultipartUpload>"]
  end

  defp completed_part({number, etag, checksum}, algorithm) do
    [
      "<Part><PartNumber>",
      Integer.to_string(number),
      "</PartNumber><ETag>",
      XML.escape(etag),
      "</ETag>",
      completed_checksum(algorithm, checksum),
      "</Part>"
    ]
  end

  defp completed_checksum(nil, _checksum), do: []

  defp completed_checksum(algorithm, checksum) do
    element = checksum_element(algorithm)
    ["<", element, ">", checksum, "</", element, ">"]
  end

  defp algorithm_headers(nil), do: []
  defp algorithm_headers(:crc32), do: [{"x-amz-checksum-algorithm", "CRC32"}, {"x-amz-checksum-type", "FULL_OBJECT"}]
  defp algorithm_headers(:sha1), do: [{"x-amz-checksum-algorithm", "SHA1"}]
  defp algorithm_headers(:sha256), do: [{"x-amz-checksum-algorithm", "SHA256"}]

  defp checksum_element(:crc32), do: "ChecksumCRC32"
  defp checksum_element(:sha1), do: "ChecksumSHA1"
  defp checksum_element(:sha256), do: "ChecksumSHA256"

  defp whole_checksum_headers(%{whole: nil}), do: []

  defp whole_checksum_headers(%{whole: whole}) do
    [{"x-amz-checksum-crc32", Checksum.final(whole)}, {"x-amz-checksum-type", "FULL_OBJECT"}]
  end
end
