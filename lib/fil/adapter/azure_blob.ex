defmodule Fil.Adapter.AzureBlob do
  @schema NimbleOptions.new!(
            account: [
              type: :string,
              required: true,
              doc: "The storage account name."
            ],
            container: [
              type: :string,
              required: true,
              doc: "The container all paths are stored in."
            ],
            root: [
              type: :string,
              default: ".",
              doc: """
              The blob name prefix every path is resolved against, e.g. `"uploads"`. Paths on the disk stay relative to
              it, and listings strip it again. Defaults to the container root.
              """
            ],
            account_key: [
              type: :string,
              doc: """
              The account key, base64 encoded as the Azure portal shows it. It signs every request (Shared Key) and the
              URLs of `Fil.signed_url/3` and `Fil.signed_upload/3`. `Fil` doesn't look up credentials itself, so where
              they come from is up to the application. Leave out `:account_key` and `:sas_token` to read a public
              container without signing.
              """
            ],
            sas_token: [
              type: :string,
              doc: """
              A SAS token, such as one for the container, sent with every request instead of a signature. It can't
              sign URLs, so `Fil.signed_url/3` and `Fil.signed_upload/3` return a `Fil.UnsupportedError`. Can't be
              combined with `:account_key`.
              """
            ],
            endpoint: [
              type: :string,
              doc: """
              The blob service URL, `"https://<account>.blob.core.windows.net"` by default. Set it for
              [Azurite](https://github.com/Azure/Azurite) (`"http://127.0.0.1:10000/devstoreaccount1"`), a sovereign
              cloud or a custom domain. The container goes into the path after it.
              """
            ],
            public_endpoint: [
              type: :string,
              doc: """
              The blob service URL clients reach the storage at, when it isn't `:endpoint`, e.g. for an Azurite
              container the application reaches by another host name. `Fil.url/2`, `Fil.signed_url/3` and
              `Fil.signed_upload/3` build their URLs with it, and the requests the disk makes itself still go to
              `:endpoint`.
              """
            ],
            block_size: [
              type: {:in, 1_048_576..4_194_304_000},
              default: 8_388_608,
              doc: """
              The size in bytes of the blocks an upload in blocks uses (a stream without a size or with `checksum:`,
              and content over 5000 MiB), 8 MiB by default. An upload keeps one block in memory at a time. Azure allows
              50,000 blocks, so a stream without a size can be at most 390 GiB at the default. Pass `size:` or raise
              `:block_size` for larger ones: with `size:`, the blocks grow to fit. See
              [Uploads in blocks](#module-uploads-in-blocks).
              """
            ],
            req_options: [
              type: :keyword_list,
              default: [],
              doc: """
              Options for every [Req](https://req.hexdocs.pm) request the disk makes, such as `:receive_timeout`,
              `:connect_options` or a shared `:finch` pool. The adapter always sets `:method`, `:url`, `:headers` and
              `:body`, plus `retry: false` (retrying is up to the caller) and `raw: true` (no decompression and no body
              decoding, so a file reads back exactly as it was written). A stream sent with its size needs HTTP/1, as
              on `Fil.Adapter.S3`.
              """
            ]
          )

  @moduledoc """
  Azure Blob Storage, and [Azurite](https://github.com/Azure/Azurite), its emulator.

      disk =
        Fil.disk(
          adapter: Fil.Adapter.AzureBlob,
          account: "invoices",
          container: "documents",
          account_key: System.fetch_env!("AZURE_STORAGE_KEY")
        )

  Requests are sent with [Req](https://req.hexdocs.pm), configured with `:req_options`, and signed with the account key
  (Shared Key). Listings are parsed with OTP's `:xmerl_sax_parser`. Microsoft Entra ID (OAuth) isn't supported: it needs
  a token from a sign-in request, and a disk is a plain value without a process that could renew one. A SAS token
  (`:sas_token`) or a public container works without the key.

  Blob Storage stores block blobs, the kind every Azure tool writes by default. Append and page blobs are listed, read
  and removed like any other file, and a write replaces them with a block blob.

  ## Options

  #{NimbleOptions.docs(@schema)}

  ## Operations

  For each `Fil` function, this section says which Blob Storage requests it sends and where it departs from the
  [contract](Fil.Adapter.html#module-contract) that every adapter follows. Anything it doesn't mention follows the
  contract. Directories exist only as name prefixes, so there are no empty directories (see
  [Hierarchical namespace](#module-hierarchical-namespace) for accounts with real ones).

  ### `Fil.read/3`

    * Uses Get Blob.
    * Reading a directory returns a `Fil.NotFoundError`.
    * `offset:` and `length:` send an `x-ms-range` header. Azure answers a range that starts at the end of the blob with
      a `416`, which is read as empty content.
    * `verify_checksum: true` compares the content with the checksum stored with the blob (see
      [Checksums](#module-checksums)). Blobs stored with another algorithm, or with none, are read without a check.

  ### `Fil.stream/3`

    * Uses Get Blob Properties first, then Get Blob each time the stream is read.
    * The download runs in a process of its own and goes only as fast as the stream is read.
    * `offset:` and `length:` are clamped to the size from Get Blob Properties. An empty range downloads nothing.
    * `verify_checksum: true` computes the checksum while streaming.

  ### `Fil.write/4`

    * Uses Put Blob for content in memory and for a stream of known size (`size:`, a `File.Stream`, a stream from
      `Fil.stream/3`), which is sent as it's read.
    * Uploads in blocks instead for a stream without a size (or with `size: :unknown`), a stream with `checksum:`, and
      anything over 5000 MiB (see [Uploads in blocks](#module-uploads-in-blocks)).
    * With `if_exists: :error`, sends `If-None-Match: *`.
    * `checksum:` stores the checksum of the content as blob metadata (see [Checksums](#module-checksums)).

  ### `Fil.rm/3`

    * Uses Delete Blob. A `404` for a missing blob is `:ok`, one for a missing container an error.
    * Removing a directory succeeds and removes nothing.

  ### `Fil.stat/3`

    * Uses Get Blob Properties. If there's no blob, it checks for blobs with the path as their prefix (List Blobs with
      `maxresults=2`), so `Fil.dir?/1` works.
    * `type: :regular` sends only Get Blob Properties, and `type: :directory` (`Fil.dir?/1`) only the prefix check.
    * `:etag` and `:content_type` are the ones Azure returns. A blob written without `content_type:` has
      `application/octet-stream`.
    * `checksum:` returns the checksum `Fil` stored if the write used the same algorithm, and `nil` otherwise.

  ### `Fil.ls/3`

    * Uses List Blobs, with `delimiter=/` unless recursive, and fetches every page.

  ### `Fil.cp/4`

    * Uses Copy Blob from the same account. Azure copies within an account right away. A copy it reports as pending is
      checked with Get Blob Properties every 100 ms until it's done.
    * With `if_exists: :error`, sends `If-None-Match: *`.
    * Copying a directory returns a `Fil.NotFoundError`.
    * The copy keeps the content type and the metadata, so a stored checksum too.

  ### `Fil.rename/4`

    * Uses Copy Blob, then Delete Blob, so it's not atomic, as on S3: a write that replaces the source between the two
      requests is lost.

  ### `Fil.rm_rf/3`

    * Uses List Blobs, then one Delete Blob per blob.

  ### `Fil.url/3`

    * Returns the blob URL, without a signature, so it works for blobs in a public container only.

  ### `Fil.signed_url/3`

    * Returns a service SAS URL with read permission (`sp=r`).
    * `disposition:` becomes `rscd`, which Azure sends as the `content-disposition` of the download.
    * Azure takes `Range` headers with a start (`bytes=0-1023`, `bytes=1024-`), not a range from the end
      (`bytes=-1024`), on which Azurite 3.37.0 sends a broken response.
    * A SAS can't sign other query parameters, so `query:` returns a `Fil.UnsupportedError` with
      `reason: :unsigned_query`.

  ### `Fil.signed_upload/3`

    * Returns a service SAS URL for Put Blob with create and write permission (`sp=cw`). With `if_exists: :error`,
      only create (`sp=c`), so an upload that finds a blob at the path is refused (Azurite answers `403`).
    * The headers are `x-ms-blob-type: BlockBlob`, which Put Blob needs, `content-type` for `content_type:`, and
      `if-none-match: *` for `if_exists: :error`.
    * A SAS can't bind headers, so Azure takes an upload with another `content-type` or size than `content_type:` and
      `size:` (`Fil.LiveView` checks both after the upload). `query:` returns a `Fil.UnsupportedError`, as for
      `Fil.signed_url/3`.

  ### `Fil.Disk.same_storage?/2`

    * Compares the endpoint, `:container` and the prefix from `:root`. Disks that differ only in credentials,
      `:public_endpoint` or `:req_options` are the same storage.

  ## Details

  ### Uploads in blocks

  A stream without a size (or with `size: :unknown`), a stream with `checksum:`, and content over 5000 MiB (the largest
  Put Blob) are read one block at a time, `:block_size` bytes each, so an upload keeps about one block and one chunk in
  memory. Content that ends within the first block goes out as one Put Blob once it has ended. Anything longer is sent
  with Put Block, one block after the other, and committed with Put Block List after the stream has ended, so nothing
  is written unless it ends. `if_exists: :error` sends `If-None-Match: *` with the commit, so a write that finds the
  file already there fails only at the end. A block that fails with `Fil.UnavailableError` is sent once more, a second
  later.

  Azure allows 50,000 blocks. A stream without a size that would need more fails with `Fil.InvalidRequestError`,
  `reason: :too_many_parts`, before its last block goes out. With `size:`, the blocks are as large as the size needs,
  rounded up to a whole MiB.

  Blocks that are never committed, because the write failed or was killed, have nothing to abort: Azure deletes them
  after 7 days. Each upload gives its blocks IDs of its own, so two uploads to the same path don't mix.

  ### Checksums

  Azure stores a blob's MD5 only, and `Fil`'s algorithms are SHA-256, SHA-1 and CRC32. So a write with `checksum:`
  computes the checksum while uploading and stores it as blob metadata (`fil_sha256`, `fil_sha1` or `fil_crc32`), and
  reads compare the content with it. Uploads in blocks store the checksum of the whole file too, because the metadata is
  set when the blocks are committed. Azure doesn't check the metadata against what it received, so the checksum guards
  against content that changed after it was written, not against a broken upload.

  ### Hierarchical namespace

  Storage accounts with a hierarchical namespace (Data Lake Storage Gen2) have directories of their own, and the Blob
  API works on them. Such a directory is listed as a directory, and a file written to `a/b.txt` creates `a` too. Unlike
  on a flat account, the directories stay after the files in them are removed, `Fil.rm/3` of a directory with files
  in it fails, and `Fil.rm_rf/3` removes the files and leaves the directories.

  ## Errors

  `:reason` is the error code from the `x-ms-error-code` header (`"BlobNotFound"`), or `{:http_status, status}` when
  there's none. Failures before a response keep Req's reason (`:timeout`, an exception).

  | Azure response | `Fil` error |
  | --- | --- |
  | `BlobNotFound`, `CannotVerifyCopySource`, or `404` | `Fil.NotFoundError` |
  | `ContainerNotFound`, `AccountIsDisabled`, `InvalidResourceName` | `Fil.ConfigurationError` |
  | `AuthenticationFailed`, `AuthorizationFailure`, or `403` | `Fil.AccessDeniedError` |
  | `AuthorizationPermissionMismatch`, `InsufficientAccountPermissions` | `Fil.AccessDeniedError` |
  | `BlobAlreadyExists`, `ConditionNotMet`, `412` | `Fil.AlreadyExistsError` |
  | `LeaseIdMissing`, `LeaseIdMismatchWithBlobOperation`, `LeaseIdMismatchWithLeaseOperation` | `Fil.ConflictError` |
  | `RequestBodyTooLarge`, `InvalidBlobOrBlock`, `OutOfRangeInput` | `Fil.InvalidRequestError` |
  | `InvalidHeaderValue`, `InvalidQueryParameterValue` | `Fil.InvalidRequestError` |
  | a stream without a size that needs more than 50,000 blocks | `Fil.InvalidRequestError`, `reason: :too_many_parts` |
  | `Md5Mismatch`, `Crc64Mismatch` | `Fil.ChecksumMismatchError` |
  | a body that doesn't match its stored checksum | `Fil.ChecksumMismatchError`, `reason: :checksum_mismatch` |
  | `AccountLimitExceeded`, `ContainerQuotaExceeded` | `Fil.StorageFullError` |
  | a signed URL or upload without `:account_key` | `Fil.UnsupportedError`, `reason: :missing_credentials` |
  | a signed URL or upload with `query:` | `Fil.UnsupportedError`, `reason: :unsigned_query` |
  | `ServerBusy`, `OperationTimedOut`, `InternalError`, `429`, `5xx` | `Fil.UnavailableError` |
  | timeouts, failed connections, an unreadable listing | `Fil.UnavailableError` |
  | a copy that Azure reports as failed or aborted | `Fil.UnknownError`, `reason: {:copy_status, status}` |
  | anything else | `Fil.UnknownError` |
  """

  @behaviour Fil.Adapter

  alias Fil.Stat
  alias Fil.Support.AzureSigning
  alias Fil.Support.ByteRange
  alias Fil.Support.Checksum
  alias Fil.Support.Content
  alias Fil.Support.Download
  alias Fil.Support.Parts
  alias Fil.Support.Relay
  alias Fil.Support.XML

  import Fil.Support.ObjectStore, except: [request: 1]
  import Fil.Support.Timestamps
  import Fil.Support.URL

  # The REST API version of every request and SAS. Azurite takes it too.
  @version "2025-01-05"

  # Azure's limits: the largest Put Blob, and the most blocks of a blob.
  @max_put 5000 * 1024 ** 2
  @max_blocks 50_000

  # How long a failed block waits before it's sent again, and how often a pending copy is checked.
  @retry_delay to_timeout(second: 1)
  @copy_poll 100

  @derive {Inspect, only: [:account, :container, :prefix, :endpoint, :public_endpoint]}
  defstruct [
    :account,
    :container,
    :prefix,
    :endpoint,
    :public_endpoint,
    :account_key,
    :sas_token,
    :block_size,
    :req_options,
    max_blocks: @max_blocks,
    retry_delay: @retry_delay,
    copy_poll: @copy_poll
  ]

  @type t :: %__MODULE__{}

  @impl Fil.Adapter
  def init(opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema),
         :ok <- check_credentials(opts),
         {:ok, key} <- parse_key(opts[:account_key]),
         {:ok, prefix} <- parse_root(opts[:root]),
         {:ok, endpoint} <- parse_endpoint(:endpoint, opts[:endpoint] || default_endpoint(opts[:account])),
         {:ok, public_endpoint} <- parse_endpoint(:public_endpoint, opts[:public_endpoint]) do
      parsed = [account_key: key, prefix: prefix, endpoint: endpoint, public_endpoint: public_endpoint]
      {:ok, build(opts, parsed)}
    end
  end

  defp build(opts, parsed) do
    %__MODULE__{
      account: opts[:account],
      container: opts[:container],
      prefix: parsed[:prefix],
      endpoint: parsed[:endpoint],
      public_endpoint: parsed[:public_endpoint],
      account_key: parsed[:account_key],
      sas_token: parse_sas_token(opts[:sas_token]),
      block_size: opts[:block_size],
      req_options: opts[:req_options]
    }
  end

  # Credentials, `:public_endpoint` and the rest only change how the storage is reached.
  @impl Fil.Adapter
  def address(state), do: {state.endpoint, state.container, state.prefix}

  @impl Fil.Adapter
  def read(state, path, opts) do
    case ByteRange.from_options(opts) do
      nil -> read_blob(state, path, opts)
      range -> read_range(state, path, range)
    end
  end

  defp read_blob(state, path, opts) do
    case request(state, :get, key(state, path)) do
      {:ok, %{status: 200, body: body} = response} -> verify(body, response.headers, opts)
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Azure answers a range that starts at or after the end, and any range of an empty blob, with `416 InvalidRange`: the
  # range is empty then.
  defp read_range(state, path, range) do
    with {:ok, response} <- request(state, :get, key(state, path), headers: [range_header(range)]) do
      case response.status do
        206 -> {:ok, response.body}
        416 -> {:ok, ""}
        _other -> {:error, error(response)}
      end
    end
  end

  # Content without a stored checksum is read without a check, like on S3.
  defp verify(body, headers, opts) do
    stored = if Keyword.get(opts, :verify_checksum, false), do: find_checksum(headers)

    case stored do
      nil -> {:ok, body}
      {algorithm, checksum} -> if Checksum.digest(algorithm, body) == checksum, do: {:ok, body}, else: mismatch()
    end
  end

  defp mismatch, do: {:error, %Fil.ChecksumMismatchError{reason: :checksum_mismatch}}

  defp range_header({offset, nil}), do: {"x-ms-range", "bytes=#{offset}-"}
  defp range_header({offset, length}), do: {"x-ms-range", "bytes=#{offset}-#{offset + length - 1}"}

  @impl Fil.Adapter
  def write(state, path, content, opts) do
    key = key(state, path)

    case route(content, opts) do
      :put -> put_blob(state, key, content, opts)
      :put_stream -> put_stream(state, key, content, opts)
      {:blocks, content, size} -> upload(state, key, content, size, opts)
    end
  end

  # Content in memory is one Put Blob, up to Azure's limit of 5000 MiB for one. So is a stream of known size without a
  # checksum, sent as it's read. Anything else is uploaded in blocks (see `upload/5`).
  defp route(content, opts) do
    if Content.iodata?(content) do
      size = IO.iodata_length(content)
      if size > @max_put, do: {:blocks, [IO.iodata_to_binary(content)], size}, else: :put
    else
      route_stream(content, opts[:size], opts[:checksum])
    end
  end

  defp route_stream(_stream, size, nil) when is_integer(size) and size <= @max_put, do: :put_stream
  defp route_stream(stream, size, _checksum), do: {:blocks, stream, size}

  defp put_blob(state, key, content, opts) do
    headers =
      [{"x-ms-blob-type", "BlockBlob"}, length_header(content)]
      |> Kernel.++(content_type_header("content-type", opts))
      |> Kernel.++(metadata_headers(opts[:checksum], content))
      |> put_if_exists(opts)

    put(state, key, headers, content)
  end

  defp put_stream(state, key, content, opts) do
    headers =
      [{"x-ms-blob-type", "BlockBlob"}, {"content-length", Integer.to_string(opts[:size])}]
      |> Kernel.++(content_type_header("content-type", opts))
      |> put_if_exists(opts)

    put(state, key, headers, content)
  end

  defp put(state, key, headers, body, params \\ []) do
    case request(state, :put, key, params: params, headers: headers, body: body) do
      {:ok, %{status: 201}} -> :ok
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Checks the blob with Get Blob Properties, and downloads it when the stream is read, in a process of its own that
  # sends the chunks one at a time (`Fil.Support.Relay`), so it goes no faster than the stream is read.
  @impl Fil.Adapter
  def stream(state, path, opts) do
    key = key(state, path)

    case request(state, :head, key) do
      {:ok, %{status: 200} = response} -> download(state, key, response, opts)
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download(state, key, response, opts) do
    check = if Keyword.get(opts, :verify_checksum, false), do: download_check(response.headers)
    size = content_length(response)
    range = ByteRange.from_options(opts)

    case Download.range(size, range) do
      :empty ->
        {:ok, [], 0}

      {range, size} ->
        get = &get_into(state, key, range, &1)
        # The label shows in `:observer` and crash reports. The key names the file, and nothing else goes in.
        {:ok, Download.stream({__MODULE__, :stream, key}, get, check, &verify_download!/2), size}
    end
  end

  defp download_check(headers) do
    with {algorithm, _stored} <- find_checksum(headers), do: %{algorithm: algorithm, checksum: Checksum.init(algorithm)}
  end

  defp get_into(state, key, range, relay) do
    headers = if range, do: [range_header(range)], else: []

    case request(state, :get, key, headers: headers, into: Relay.into(relay, range)) do
      {:ok, %{status: 206, headers: _headers}} when range == nil ->
        {:error, %Fil.UnknownError{reason: {:http_status, 206}}}

      {:ok, %{status: status, headers: headers}} when status in [200, 206] ->
        {:ok, headers}

      {:ok, response} ->
        {:error, error(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Compared with the checksum the Get Blob returned, which belongs to the content that was downloaded. A blob replaced
  # since Get Blob Properties may have none for this algorithm, and is then read without a check, like `read/3`.
  defp verify_download!(%{algorithm: algorithm, checksum: checksum}, headers) do
    case find_checksum(headers) do
      {^algorithm, stored} ->
        if Checksum.final(checksum) != stored, do: raise(%Fil.ChecksumMismatchError{reason: :checksum_mismatch})

      _other ->
        :ok
    end
  end

  @impl Fil.Adapter
  def rm(state, path, _opts) do
    case request(state, :delete, key(state, path)) do
      {:ok, %{status: 202}} -> :ok
      {:ok, %{status: 404} = response} -> missing_is_ok(error(response))
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Fil.Adapter
  def stat(_state, ".", _opts), do: {:ok, %Stat{type: :directory}}

  # `type:` skips the request for the other type: a directory needs no Get Blob Properties, and a missing file no
  # listing.
  def stat(state, path, opts) do
    case Keyword.get(opts, :type) do
      :directory -> directory_stat(state, path)
      type -> blob_stat(state, path, type, Keyword.get(opts, :checksum))
    end
  end

  # A directory of an account with a hierarchical namespace is a blob with `hdi_isfolder` metadata. `Fil` turns it into
  # an error when the call asked for `type: :regular`.
  defp blob_stat(state, path, type, algorithm) do
    case request(state, :head, key(state, path)) do
      {:ok, %{status: 200} = response} -> {:ok, blob_stat(response, algorithm)}
      {:ok, %{status: 404} = response} -> missing_blob(state, path, type, error(response))
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp missing_blob(state, path, type, %Fil.NotFoundError{}) when type != :regular, do: directory_stat(state, path)
  defp missing_blob(_state, _path, _type, error), do: {:error, error}

  defp blob_stat(%{headers: headers}, algorithm) do
    if folder?(header(headers, "x-ms-meta-hdi_isfolder")) do
      %Stat{type: :directory}
    else
      %Stat{
        size: integer(header(headers, "content-length")),
        type: :regular,
        mtime: parse_http_date(header(headers, "last-modified")),
        etag: unquote_etag(header(headers, "etag")),
        content_type: header(headers, "content-type"),
        checksum: algorithm && stored_checksum(headers, algorithm)
      }
    end
  end

  # One page of two blobs is enough: the first blob under the prefix may be the directory's own marker, which doesn't
  # count.
  defp directory_stat(state, path) do
    prefix = list_prefix(state, path)

    with {:ok, blobs, prefixes, _marker} <- list_page(state, prefix, "/", nil, 2) do
      if Enum.reject(blobs, &marker?(&1, prefix)) == [] and prefixes == [] do
        {:error, %Fil.NotFoundError{reason: {:http_status, 404}}}
      else
        {:ok, %Stat{type: :directory}}
      end
    end
  end

  @impl Fil.Adapter
  def ls(state, prefix, opts) do
    delimiter = if !Keyword.get(opts, :recursive, false), do: "/"
    list_prefix = list_prefix(state, prefix)

    with {:ok, blobs, prefixes} <- list_all(state, list_prefix, delimiter) do
      listed =
        blobs
        |> Enum.reject(&marker?(&1, list_prefix))
        |> Enum.map(&blob_listing(state, &1))
        |> Kernel.++(Enum.map(prefixes, &prefix_listing(state, &1)))
        |> subtree(prefix, delimiter)

      {:ok, Enum.sort_by(listed, &elem(&1, 0))}
    end
  end

  @impl Fil.Adapter
  def cp(state, src, dest, opts) do
    headers = put_if_exists([{"x-ms-copy-source", copy_source(state, src)}, {"content-length", "0"}], opts)

    result =
      case request(state, :put, key(state, dest), headers: headers) do
        {:ok, %{status: 202, headers: headers}} -> copied(state, dest, header(headers, "x-ms-copy-status"))
        {:ok, response} -> {:error, error(response)}
        {:error, reason} -> {:error, reason}
      end

    existing_dest(result, dest)
  end

  # A copy within the account is done when Copy Blob answers. One Azure still runs is checked until it's done.
  defp copied(_state, _dest, status) when status in [nil, "success"], do: :ok

  defp copied(state, dest, "pending") do
    Process.sleep(state.copy_poll)

    case request(state, :head, key(state, dest)) do
      {:ok, %{status: 200, headers: headers}} -> copied(state, dest, header(headers, "x-ms-copy-status"))
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp copied(_state, _dest, status), do: {:error, %Fil.UnknownError{reason: {:copy_status, status}}}

  # A move onto itself is a copy onto itself, which keeps the file (or finds it there with `if_exists: :error`), without
  # the Delete Blob that would remove it.
  @impl Fil.Adapter
  def rename(state, path, path, opts), do: cp(state, path, path, opts)

  def rename(state, src, dest, opts) do
    with :ok <- cp(state, src, dest, opts), do: rm(state, src, opts)
  end

  # One Delete Blob per blob. Blob Batch would delete 256 at a time, but needs a multipart body of its own, so that's
  # left for later. Directories of a hierarchical namespace are blobs too, and stay.
  @impl Fil.Adapter
  def rm_rf(state, prefix, opts) do
    with {:ok, blobs, _prefixes} <- list_all(state, base_prefix(state, prefix), nil) do
      blobs
      |> Enum.reject(&folder?(metadata(&1, "hdi_isfolder")))
      |> Enum.map(&relative(state, XML.text(&1, "Name")))
      |> Enum.filter(&under_prefix?(&1, prefix))
      |> delete_each(&rm(state, &1, opts))
    end
  end

  @impl Fil.Adapter
  def url(state, path, _opts), do: {:ok, blob_url(public_base_url(state), key(state, path), [])}

  # `Fil` has validated `:expires_in` (at most 7 days) and built `:disposition`.
  @impl Fil.Adapter
  def signed_url(state, path, opts) do
    with :ok <- check_signing(state, opts) do
      fields = %{permissions: "r", disposition: Keyword.get(opts, :disposition)}
      {url, _expires_at} = sas_url(state, path, fields, opts)
      {:ok, url}
    end
  end

  # A SAS can't require headers. Create permission alone (`c`) refuses to replace a blob, which covers
  # `if_exists: :error`, and the headers are what Put Blob needs.
  @impl Fil.Adapter
  def signed_upload(state, path, opts) do
    with :ok <- check_signing(state, opts) do
      if_exists = Keyword.get(opts, :if_exists, :overwrite)
      permissions = if if_exists == :error, do: "c", else: "cw"

      headers =
        [{"x-ms-blob-type", "BlockBlob"}]
        |> Kernel.++(content_type_header("content-type", opts))
        |> put_if_exists(opts)
        |> Map.new()

      {url, expires_at} = sas_url(state, path, %{permissions: permissions}, opts)
      {:ok, %Fil.SignedUpload{url: url, headers: headers, expires_at: expires_at}}
    end
  end

  defp check_signing(%__MODULE__{account_key: nil}, _opts),
    do: {:error, %Fil.UnsupportedError{reason: :missing_credentials}}

  defp check_signing(_state, opts) do
    if Keyword.get(opts, :query, []) == [], do: :ok, else: {:error, %Fil.UnsupportedError{reason: :unsigned_query}}
  end

  # The URL and when it expires. A URL for `http:` (Azurite) can't require HTTPS.
  defp sas_url(state, path, fields, opts) do
    base_url = public_base_url(state)
    key = key(state, path)
    protocol = if String.starts_with?(base_url, "https:"), do: "https"

    expires =
      :second
      |> DateTime.utc_now()
      |> DateTime.add(Keyword.get(opts, :expires_in, 900))

    fields = Map.merge(fields, %{expires: expires, version: @version, protocol: protocol})
    query = AzureSigning.service_sas(state.account, state.account_key, state.container, key, fields)

    {blob_url(base_url, key, query), expires}
  end

  ## ------------------------------------------------------------------
  ## Uploads in blocks
  ## ------------------------------------------------------------------

  # A stream without a size or with a checksum, and content over 5000 MiB, is read one block at a time
  # (`Fil.Support.Parts`), in blocks of `:block_size`, or larger ones for known sizes that would need more than 50,000.
  # Content that ends within the first block goes out as one Put Blob. Anything larger is sent block by block and
  # committed after the content has ended, so nothing is written unless it ends. Blocks that are never committed are
  # deleted by Azure after 7 days, so a failed upload has nothing to clean up.
  defp upload(state, key, content, size, opts) do
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

  # Called with every full block while the stream is read, so a failed request halts the stream instead of raising:
  # the content is read inside `Fil.Op`, where a raised `Fil` error would count as the source's. A full block always
  # has more content behind it, so the last block a stream can have is refused before it's uploaded.
  defp next_block(state, block, upload) do
    next_part(length(upload.blocks), state.max_blocks, fn -> put_block(state, block, upload) end)
  end

  defp finish_upload({:halted, {:error, error}}, _state, _opts), do: {:error, error}
  defp finish_upload({:done, last, %{blocks: [], key: key}}, state, opts), do: put_blob(state, key, last, opts)

  defp finish_upload({:done, last, upload}, state, opts) do
    with {:ok, upload} <- put_block(state, last, upload), do: commit(state, upload, opts)
  end

  defp put_block(state, block, upload) do
    id = Base.encode64(upload.prefix <> String.pad_leading(Integer.to_string(length(upload.blocks)), 6, "0"))

    with :ok <- send_block(state, upload.key, id, block) do
      checksum = upload.checksum && Checksum.update(upload.checksum, block)
      {:ok, %{upload | blocks: [id | upload.blocks], checksum: checksum}}
    end
  end

  # A block is invisible until the blocks are committed, so a block that failed with `Fil.UnavailableError` is sent once
  # more, a second later (`ServerBusy` and `503` are unavailable too).
  defp send_block(state, key, id, block) do
    params = [{"comp", "block"}, {"blockid", id}]
    retry_unavailable(fn -> put(state, key, [length_header(block)], block, params) end, state.retry_delay)
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
      [length_header(body)]
      |> Kernel.++(content_type_header("x-ms-blob-content-type", opts))
      |> Kernel.++(checksum_metadata(opts[:checksum], upload.checksum))
      |> put_if_exists(opts)

    put(state, upload.key, headers, body, [{"comp", "blocklist"}])
  end

  ## ------------------------------------------------------------------
  ## Checksums
  ## ------------------------------------------------------------------

  defp metadata_headers(nil, _content), do: []
  defp metadata_headers(algorithm, content), do: [{metadata_header(algorithm), Checksum.digest(algorithm, content)}]

  defp checksum_metadata(nil, _checksum), do: []
  defp checksum_metadata(algorithm, checksum), do: [{metadata_header(algorithm), Checksum.final(checksum)}]

  defp metadata_header(algorithm), do: "x-ms-meta-fil_#{algorithm}"

  defp stored_checksum(headers, algorithm) do
    case header(headers, metadata_header(algorithm)) do
      nil -> nil
      checksum -> {algorithm, checksum}
    end
  end

  # The checksum stored with the blob, for the first algorithm that has one.
  defp find_checksum(headers), do: Enum.find_value(Checksum.algorithms(), &stored_checksum(headers, &1))

  ## ------------------------------------------------------------------
  ## Options
  ## ------------------------------------------------------------------

  defp check_credentials(opts) do
    if opts[:account_key] && opts[:sas_token],
      do: {:error, {:invalid_option, {:sas_token, "can't be combined with :account_key"}}},
      else: :ok
  end

  defp parse_key(nil), do: {:ok, nil}

  defp parse_key(key) do
    case Base.decode64(key) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, {:invalid_option, {:account_key, "isn't base64"}}}
    end
  end

  # The token as query parameters, with or without the `?` the portal shows in front of it.
  defp parse_sas_token(nil), do: nil

  defp parse_sas_token(token) do
    token
    |> String.trim_leading("?")
    |> URI.query_decoder()
    |> Enum.to_list()
  end

  defp default_endpoint(account), do: "https://#{account}.blob.core.windows.net"

  defp length_header(content) do
    length =
      content
      |> IO.iodata_length()
      |> Integer.to_string()

    {"content-length", length}
  end

  defp content_type_header(name, opts) do
    case Keyword.get(opts, :content_type) do
      nil -> []
      content_type -> [{name, content_type}]
    end
  end

  ## ------------------------------------------------------------------
  ## Requests
  ## ------------------------------------------------------------------

  defp request(state, method, key, opts \\ []) do
    params = Keyword.get(opts, :params, []) ++ (state.sas_token || [])
    url = blob_url(container_url(state.endpoint, state), key, params)

    options =
      Keyword.merge(state.req_options,
        method: method,
        url: url,
        headers: request_headers(state, method, url, params, Keyword.get(opts, :headers, [])),
        body: Keyword.get(opts, :body),
        into: Keyword.get(opts, :into),
        retry: false,
        raw: true
      )

    Fil.Support.ObjectStore.request(options)
  end

  defp request_headers(state, method, url, params, headers) do
    date =
      DateTime.utc_now()
      |> AzureSigning.http_date()

    [{"x-ms-version", @version}, {"x-ms-date", date} | headers]
    |> authorize(state, method, url, params)
  end

  # Signed with the account key (Shared Key). A disk with a SAS token or without credentials sends no signature.
  defp authorize(headers, %__MODULE__{account_key: nil}, _method, _url, _params), do: headers

  defp authorize(headers, state, method, url, params) do
    %URI{path: path} = URI.parse(url)

    [
      {"authorization", AzureSigning.shared_key(state.account, state.account_key, method, path, params, headers)}
      | headers
    ]
  end

  # URLs handed out to clients use the public endpoint, requests the disk makes itself use `:endpoint`.
  defp public_base_url(state), do: container_url(state.public_endpoint || state.endpoint, state)

  defp container_url(endpoint, state), do: endpoint <> "/" <> encode(state.container)

  defp blob_url(container_url, "", params), do: container_url <> encode_query(params)
  defp blob_url(container_url, key, params), do: container_url <> "/" <> encode_path(key) <> encode_query(params)

  # Copy Blob takes the source as a URL. Within the account, Shared Key authorizes it. With a SAS token, the source
  # carries the token.
  defp copy_source(state, src),
    do: blob_url(container_url(state.endpoint, state), key(state, src), state.sas_token || [])

  ## ------------------------------------------------------------------
  ## Listing
  ## ------------------------------------------------------------------

  defp list_all(state, prefix, delimiter, marker \\ nil, blobs \\ [], prefixes \\ []) do
    with {:ok, page_blobs, page_prefixes, next} <- list_page(state, prefix, delimiter, marker) do
      blobs = blobs ++ page_blobs
      prefixes = prefixes ++ page_prefixes

      if next in [nil, ""],
        do: {:ok, blobs, prefixes},
        else: list_all(state, prefix, delimiter, next, blobs, prefixes)
    end
  end

  # Metadata comes with the listing so the directories of a hierarchical namespace (`hdi_isfolder`) are recognised.
  defp list_page(state, prefix, delimiter, marker, max_results \\ nil) do
    params =
      Enum.reject(
        [
          {"restype", "container"},
          {"comp", "list"},
          {"include", "metadata"},
          {"prefix", prefix},
          {"delimiter", delimiter},
          {"marker", marker},
          {"maxresults", max_results && Integer.to_string(max_results)}
        ],
        fn {_name, value} -> value in [nil, ""] end
      )

    with {:ok, result} <- list_request(state, params) do
      listed = XML.children(result, "Blobs")
      blobs = Enum.flat_map(listed, &XML.children(&1, "Blob"))
      prefixes = Enum.flat_map(listed, &XML.children(&1, "BlobPrefix"))

      {:ok, blobs, prefixes, XML.text(result, "NextMarker")}
    end
  end

  defp list_request(state, params) do
    case request(state, :get, "", params: params) do
      {:ok, %{status: 200, body: body}} -> parse_xml(body)
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  # A "directory marker" is an empty blob named exactly like the listed directory, with or without the slash. Only
  # listings pass a prefix with a trailing slash. Prefix deletions don't, and there a blob named like the prefix is a
  # file to remove.
  defp marker?(blob, prefix) do
    String.ends_with?(prefix, "/") and XML.text(blob, "Name") in [prefix, String.trim_trailing(prefix, "/")]
  end

  defp blob_listing(state, blob) do
    name = relative(state, XML.text(blob, "Name"))

    if folder?(metadata(blob, "hdi_isfolder")) or String.ends_with?(name, "/") do
      {String.trim_trailing(name, "/"), %Stat{type: :directory}}
    else
      properties = child(blob, "Properties")

      stat = %Stat{
        size: integer(XML.text(properties, "Content-Length")),
        type: :regular,
        mtime: parse_http_date(XML.text(properties, "Last-Modified")),
        etag: unquote_etag(XML.text(properties, "Etag")),
        content_type: XML.text(properties, "Content-Type")
      }

      {name, stat}
    end
  end

  defp prefix_listing(state, blob_prefix) do
    path =
      blob_prefix
      |> XML.text("Name")
      |> to_string()
      |> String.trim_trailing("/")
      |> then(&relative(state, &1))

    {path, %Stat{type: :directory}}
  end

  defp metadata(blob, name) do
    blob
    |> child("Metadata")
    |> XML.text(name)
  end

  # The first child named `name`, or an empty one.
  defp child(element, name) do
    case XML.children(element, name) do
      [child | _rest] -> child
      [] -> {name, [], []}
    end
  end

  defp folder?(value), do: is_binary(value) and String.downcase(value) == "true"

  ## ------------------------------------------------------------------
  ## Errors
  ## ------------------------------------------------------------------

  @codes %{
    "BlobNotFound" => Fil.NotFoundError,
    "CannotVerifyCopySource" => Fil.NotFoundError,
    "ContainerNotFound" => Fil.ConfigurationError,
    "AccountIsDisabled" => Fil.ConfigurationError,
    "InvalidResourceName" => Fil.ConfigurationError,
    "AuthenticationFailed" => Fil.AccessDeniedError,
    "AuthorizationFailure" => Fil.AccessDeniedError,
    "AuthorizationPermissionMismatch" => Fil.AccessDeniedError,
    "AuthorizationResourceTypeMismatch" => Fil.AccessDeniedError,
    "InsufficientAccountPermissions" => Fil.AccessDeniedError,
    "BlobAlreadyExists" => Fil.AlreadyExistsError,
    "ConditionNotMet" => Fil.AlreadyExistsError,
    "LeaseIdMissing" => Fil.ConflictError,
    "LeaseIdMismatchWithBlobOperation" => Fil.ConflictError,
    "LeaseIdMismatchWithLeaseOperation" => Fil.ConflictError,
    "RequestBodyTooLarge" => Fil.InvalidRequestError,
    "InvalidBlobOrBlock" => Fil.InvalidRequestError,
    "InvalidHeaderValue" => Fil.InvalidRequestError,
    "InvalidQueryParameterValue" => Fil.InvalidRequestError,
    "OutOfRangeInput" => Fil.InvalidRequestError,
    "Md5Mismatch" => Fil.ChecksumMismatchError,
    "Crc64Mismatch" => Fil.ChecksumMismatchError,
    "AccountLimitExceeded" => Fil.StorageFullError,
    "ContainerQuotaExceeded" => Fil.StorageFullError,
    "ServerBusy" => Fil.UnavailableError,
    "OperationTimedOut" => Fil.UnavailableError,
    "InternalError" => Fil.UnavailableError
  }

  # Azure sends the code in a header, so a response without a body (HEAD) has one too.
  defp error(%{status: status} = response) do
    code = header(response.headers, "x-ms-error-code") || error_code(response.body)

    if Map.has_key?(@codes, code),
      do: struct(Map.fetch!(@codes, code), reason: code),
      else: struct(status_error(status), reason: code || {:http_status, status})
  end

  defp status_error(404), do: Fil.NotFoundError
  defp status_error(403), do: Fil.AccessDeniedError
  defp status_error(412), do: Fil.AlreadyExistsError
  defp status_error(status) when status == 429 or status >= 500, do: Fil.UnavailableError
  defp status_error(_status), do: Fil.UnknownError
end
