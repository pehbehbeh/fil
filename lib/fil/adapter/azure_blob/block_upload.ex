defmodule Fil.Adapter.AzureBlob.BlockUpload do
  @moduledoc false

  # A block upload of `Fil.Adapter.AzureBlob`: its state (the block IDs and the checksum) and its steps (send each
  # block, commit the block list). See the moduledoc's Uploads in blocks.

  alias Fil.Adapter.AzureBlob.Client
  alias Fil.Support.Checksum
  alias Fil.Support.ObjectStore
  alias Fil.Support.Parts

  @doc """
  Writes `content` to `key` in blocks of `:block_size`, or larger ones for a known `size` that would need more than
  50,000. Content that ends within the first block comes back as `{:single, content}`, for the adapter to send as one
  Put Blob. Anything larger is sent block by block and committed after the content has ended, so nothing is written
  unless it ends. Blocks that are never
  committed are deleted by Azure after 7 days, so a failed upload has nothing to clean up.
  """
  @spec upload(Fil.Adapter.AzureBlob.t(), String.t(), Enumerable.t(), non_neg_integer() | nil, keyword()) ::
          :ok | {:single, iodata()} | {:error, Exception.t()}
  def upload(state, key, content, size, opts) do
    algorithm = opts[:checksum]

    upload = %{
      key: key,
      # Block IDs are unique to the upload and all the same length, which Azure requires of a blob's blocks.
      prefix:
        8
        |> :crypto.strong_rand_bytes()
        |> Base.encode16(case: :lower),
      blocks: [],
      checksum: algorithm && Checksum.init(algorithm)
    }

    block_size = Parts.size(size, state.block_size, state.max_blocks)

    content
    |> Parts.reduce(block_size, upload, &next_block(state, &1, &2))
    |> finish_upload(state, opts)
  end

  defp next_block(state, block, upload) do
    count = length(upload.blocks)
    ObjectStore.next_part(count, state.max_blocks, fn -> put_block(state, block, upload) end)
  end

  defp finish_upload({:halted, {:error, error}}, _state, _opts), do: {:error, error}
  defp finish_upload({:done, last, %{blocks: []}}, _state, _opts), do: {:single, last}

  defp finish_upload({:done, last, upload}, state, opts) do
    with {:ok, upload} <- put_block(state, last, upload), do: commit(state, upload, opts)
  end

  defp put_block(state, block, upload) do
    number =
      upload.blocks
      |> length()
      |> Integer.to_string()
      |> String.pad_leading(6, "0")

    id = Base.encode64(upload.prefix <> number)

    with :ok <- send_block(state, upload.key, id, block) do
      checksum = upload.checksum && Checksum.update(upload.checksum, block)
      {:ok, %{upload | blocks: [id | upload.blocks], checksum: checksum}}
    end
  end

  # A block is invisible until the blocks are committed, so a block that failed with `Fil.UnavailableError` is sent once
  # more, a second later (`ServerBusy` and `503` are unavailable too).
  defp send_block(state, key, id, block) do
    params = [{"comp", "block"}, {"blockid", id}]

    ObjectStore.retry_unavailable(
      fn -> Client.put(state, key, [Client.length_header(block)], block, params) end,
      state.retry_delay
    )
  end

  # The content type, the checksum and `if_exists: :error` go with the commit, which is what creates the blob.
  defp commit(state, upload, opts) do
    body = [
      ~s(<?xml version="1.0" encoding="utf-8"?><BlockList>),
      upload.blocks
      |> Enum.reverse()
      |> Enum.map(&["<Latest>", &1, "</Latest>"]),
      "</BlockList>"
    ]

    headers =
      [Client.length_header(body)]
      |> Kernel.++(Client.content_type_header("x-ms-blob-content-type", opts))
      |> Kernel.++(checksum_metadata(opts[:checksum], upload.checksum))
      |> ObjectStore.put_if_exists(opts)

    Client.put(state, upload.key, headers, body, [{"comp", "blocklist"}])
  end

  defp checksum_metadata(nil, _checksum), do: []
  defp checksum_metadata(algorithm, checksum), do: [{Client.metadata_header(algorithm), Checksum.final(checksum)}]
end
