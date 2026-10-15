defmodule Fil.Adapter.S3 do
  @schema NimbleOptions.new!(
            bucket: [
              type: :string,
              required: true,
              doc: "The bucket all paths are stored in."
            ],
            region: [
              type: :string,
              default: "us-east-1",
              doc: "The bucket's region."
            ],
            root: [
              type: :string,
              default: ".",
              doc: """
              The key prefix every path is resolved against, e.g. `"uploads"`. Paths on the disk stay relative to
              it, and listings strip it again. Defaults to the bucket root.
              """
            ],
            access_key_id: [
              type: :string,
              doc: """
              The access key. `Fil` doesn't look up credentials itself (no environment variables, no instance metadata),
              so where they come from is up to the application. Leave out all credentials to access a public bucket
              without signing.
              """
            ],
            secret_access_key: [type: :string, doc: "The secret matching `:access_key_id`."],
            session_token: [type: :string, doc: "The session token, for temporary STS credentials."],
            endpoint: [
              type: :string,
              doc: """
              A base URL for S3-compatible services, e.g. `"http://localhost:9000"`. Setting it turns `:path_style` on.
              """
            ],
            public_endpoint: [
              type: :string,
              doc: """
              The base URL clients reach the storage at, when it isn't `:endpoint`, e.g. `"http://localhost:9090"` for
              a container the application reaches as `"http://s3mock:9090"`. `Fil.url/2` and `Fil.signed_url/3` build
              their URLs with it, and the requests the disk makes itself still go to `:endpoint`. A signature covers the
              host, so a signed URL can't be rewritten to another host afterwards. `:path_style` applies to both, but
              only `:endpoint` turns it on by default.
              """
            ],
            path_style: [
              type: :boolean,
              doc: """
              Put the bucket in the path (`https://host/bucket/key`) instead of the hostname
              (`https://bucket.host/key`). Defaults to `true` when `:endpoint` is set, `false` otherwise.
              """
            ],
            part_size: [
              type: {:in, 5_242_880..5_368_709_120},
              default: 8_388_608,
              doc: """
              The size in bytes of the parts an upload in parts uses (a stream without a size or with `checksum:`,
              and content over 5 GiB), 8 MiB by default and at least 5 MiB (S3's minimum). An upload keeps one part in
              memory at a time. S3 allows 10,000 parts, so a stream without a size can be at most 78 GiB at the
              default. Pass `size:` or raise `:part_size` for larger ones: with `size:`, the parts grow to fit. See
              [Uploads in parts](#module-uploads-in-parts).
              """
            ],
            req_options: [
              type: :keyword_list,
              default: [],
              doc: """
              Options for every [Req](https://req.hexdocs.pm) request the disk makes, such as `:receive_timeout`,
              `:connect_options` or a shared `:finch` pool. The adapter always sets `:method`, `:url`, `:headers` and
              `:body`, plus `retry: false` (retrying is up to the caller) and `raw: true` (no decompression and no body
              decoding, so a file reads back exactly as it was written). A stream sent with its size needs HTTP/1,
              see above.
              """
            ]
          )

  @moduledoc """
  Amazon S3 and services that implement its API, such as [RustFS](https://github.com/rustfs/rustfs),
  [SeaweedFS](https://github.com/seaweedfs/seaweedfs), [Adobe S3Mock](https://github.com/adobe/S3Mock),
  [Cloudflare R2](https://developers.cloudflare.com/r2/), [Backblaze B2](https://www.backblaze.com/cloud-storage),
  [Tigris](https://www.tigrisdata.com) and [Ceph](https://ceph.io).

      disk =
        Fil.disk(
          adapter: Fil.Adapter.S3,
          bucket: "invoices",
          region: "eu-central-1",
          access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
          secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")
        )

  Requests are sent and signed (SigV4) by [Req](https://req.hexdocs.pm), configured with `:req_options`. Listings are
  parsed with OTP's `:xmerl_sax_parser`.

  A stream of known size (see the `:size` option of `Fil.write/4`) is sent as it's read, and that needs an HTTP/1
  connection pool, which is what Req uses unless `:req_options` asks for HTTP/2 (for example with
  `connect_options: [protocols: [:http2]]` or a `:finch` pool for HTTP/2). On HTTP/2, Finch reads a request body in the
  pool's process instead of the caller's, and a stream that only the caller's process can read fails or stalls there: a
  `Fil.Plug` upload, or a stream from another S3 disk (`Fil.stream/3`, or a copy across disks). Content in memory,
  [uploads in parts](#module-uploads-in-parts) and streams that any process can read, such as a `File.Stream`, are fine.

  ## Options

  #{NimbleOptions.docs(@schema)}

  ## Operations

  For each `Fil` function, this section says which S3 requests it sends and where it departs from the
  [contract](Fil.Adapter.html#module-contract) that every adapter follows. Anything it doesn't mention follows the
  contract. Directories exist only as key prefixes, so there are no empty directories.

  ### `Fil.read/3`

    * Uses GetObject.
    * Reading a directory returns a `Fil.NotFoundError`.
    * `offset:` and `length:` send a `Range` header. S3 answers a range that starts at the end of the object with a
      `416`, which is read as empty content.
    * `verify_checksum: true` asks S3 for the stored checksum (`x-amz-checksum-mode: ENABLED`) and compares it with the
      downloaded content, including the composite checksum of an upload in parts (see [Checksums](#module-checksums)).
      Objects stored with another algorithm, or with none, are read without a check.

  ### `Fil.stream/3`

    * Uses HeadObject first, then GetObject each time the stream is read.
    * The download runs in a process of its own and goes only as fast as the stream is read.
    * `offset:` and `length:` are clamped to the size from the HeadObject and sent as a `Range` header. An empty range
      downloads nothing.
    * `verify_checksum: true` computes the checksum while streaming.

  ### `Fil.write/4`

    * Uses PutObject for content in memory and for a stream of known size (`size:`, a `File.Stream`, a stream from
      `Fil.stream/3`), which is sent as it's read. The last chunk goes out only once the stream has ended, so a stream
      that raises after its last chunk leaves no object.
    * Uploads in parts instead for a stream without a size (or with `size: :unknown`), a stream with `checksum:`, and
      anything over 5 GiB (see [Uploads in parts](#module-uploads-in-parts)).
    * With `if_exists: :error`, sends `If-None-Match: *`.
    * `checksum:` (`:sha256`, `:sha1` or `:crc32`) sends the checksum of the content in `x-amz-checksum-*`. S3 rejects
      the upload if what it received doesn't match, and stores the checksum with the object.
    * Writing to `report.txt/x` when `report.txt` is an object writes a second object and leaves the first alone.

  ### `Fil.rm/3`

    * Uses DeleteObject, which S3 already treats as idempotent. A `404` for a missing bucket is still an error.
    * Removing a directory succeeds and removes nothing.

  ### `Fil.stat/3`

    * Uses HeadObject. If there's no object, it checks for keys with the path as their prefix (ListObjectsV2 with
      `max-keys=2`), so `Fil.dir?/1` works.
    * `type: :regular` sends only the HeadObject, and `type: :directory` (`Fil.dir?/1`) only the prefix check. So a key
      that is an object and a prefix at once is both a file and a directory.
    * A directory marker alone doesn't make a directory for the prefix check, though a listing of its parent lists it.
    * `:etag` and `:content_type` are the ones S3 returns. The ETag of an upload in parts ends in `-` and the number of
      parts.
    * `checksum:` returns the checksum S3 stored if the write used the same algorithm, and `nil` otherwise. It's `nil`
      for the composite checksum of an upload in parts too.

  ### `Fil.ls/3`

    * Uses ListObjectsV2, with `delimiter=/` unless recursive, and fetches every page.
    * A recursive listing finds the directories in the keys, so an empty directory shows up only as a directory marker
      (an empty object whose key ends in `/`, as consoles create for a new folder), which is listed as the directory.

  ### `Fil.cp/4`

    * Uses CopyObject.
    * With `if_exists: :error`, sends `If-None-Match: *`. AWS checks it on copies since October 2025, and RustFS 1.0.0
      does too.
    * Copying a directory returns a `Fil.NotFoundError`.
    * S3 refuses to copy an object onto itself, so that's a `Fil.InvalidRequestError` with `reason: "InvalidRequest"`,
      with or without `if_exists: :error`. The other adapters copy the file onto itself, or return a
      `Fil.AlreadyExistsError` with `if_exists: :error`.
    * A copy of a file uploaded in parts gets a new checksum of the whole file, and doesn't keep the one of the parts.

  ### `Fil.rename/4`

    * Uses CopyObject, then DeleteObject.
    * A copy that fails (with `if_exists: :error` too) fails before the source is deleted.
    * Renaming an object onto itself fails like the copy.
    * The DeleteObject removes whatever is at the source by then, so a write that replaces the source between the two
      requests is lost. The other adapters keep it, and with `if_exists: :error` fail the move with a
      `Fil.ConflictError`.

  ### `Fil.rm_rf/3`

    * Uses ListObjectsV2, then one DeleteObject per key.

  ### `Fil.url/3`

    * Returns the object URL, without a signature, so it works for public objects only.

  ### `Fil.signed_url/3`

    * Returns a presigned GET URL.
    * `disposition:` becomes `response-content-disposition`, and the `query:` parameters are added to the URL.

  ### `Fil.signed_upload/3`

    * Returns a presigned PUT URL, with the `query:` parameters added to it.
    * `content_type:`, `size:` and `if_exists: :error` are signed headers (`content-type`, `content-length` and
      `if-none-match: *`). S3 refuses a PUT without them, or with other values, with a `403`, and answers `412` when
      `if_exists: :error` finds an object.

  ### `Fil.Disk.same_storage?/2`

    * Compares `:endpoint`, `:region`, `:bucket` and the prefix from `:root`. Disks that differ only in credentials,
      `:public_endpoint`, `:path_style` or `:req_options` are the same storage.

  ## Details

  ### Uploads in parts

  A stream without a size (or with `size: :unknown`), a stream with `checksum:`, and content over 5 GiB (the largest
  PutObject) are read one part at a time, `:part_size` bytes each, so an upload keeps about one part and one chunk in
  memory. Content that ends within the first part goes out as one PutObject once it has ended. Anything longer is a
  multipart upload:

    * CreateMultipartUpload once the second part begins, with the content type and the checksum algorithm
    * UploadPart for each part once more content has arrived after it, signed with its SHA-256, which S3 checks.
      The parts go out one after the other from the calling process, so this works on HTTP/2 too. A part that fails
      with `Fil.UnavailableError` (throttling such as `SlowDown` included) is sent once more, a second later. It's the
      only request `Fil` repeats: nobody sees a part before the upload completes
    * CompleteMultipartUpload after the stream has ended, so nothing is written unless it ends. `if_exists: :error`
      sends `If-None-Match: *` with it (S3 takes it nowhere else), so a write that finds the file already there fails
      only at the end

  S3 allows 10,000 parts. A stream without a size that would need more fails with `Fil.InvalidRequestError`,
  `reason: :too_many_parts`, before its last part goes out: that's 78 GiB at the default part size, so pass `size:` or
  raise `:part_size` for larger ones. With `size:`, the parts are as large as the size needs, rounded up to a whole
  MiB (525 MiB for 5 TiB, the largest object S3 stores). A `size:` over 5 TiB fails with `Fil.InvalidRequestError`,
  `reason: "EntityTooLarge"`, before the stream is read.

  Completing a large upload can take a while. AWS answers with a `200` right away and sends whitespace until it's
  done, and `:receive_timeout` applies between packets, so it doesn't cut the completion off. An error that comes
  after the `200` is read like any other. Whether RustFS keeps the connection alive the same way hasn't been checked.

  Any failure aborts the upload (AbortMultipartUpload), and so does a stream that raises. When the writing process is
  killed (a supervisor shutdown, or Cowboy stopping the request of a client that disconnected), a process of its own
  that watches the writer aborts the upload. The abort can still be missed: when the node goes down, or when the
  abort request fails. S3 doesn't list the parts of an incomplete upload, but bills them, so give the bucket a
  lifecycle rule that aborts incomplete multipart uploads (`AbortIncompleteMultipartUpload`, for example after one day).
  It also aborts uploads that are still running after that time.

  For `Fil.Telemetry`, an upload in parts is one `:write`, with no events for the parts. Its requests are Finch events,
  and the creation and the abort run in a process of their own (see
  [HTTP requests in `Fil.Telemetry`](Fil.Telemetry.html#module-http-requests)).

  #### Checksums

  `checksum: :crc32` covers the whole file, however it's uploaded. Each part is sent with its CRC32, and the completion
  with the CRC32 of all of the content (`FULL_OBJECT`), which S3 checks and stores as it does for a PutObject.

  S3 can't compute a SHA-1 or SHA-256 over an upload in parts. With `:sha1` or `:sha256`, each part is sent with its
  checksum, which S3 checks, and S3 stores a composite checksum: the checksum of the parts' checksums, followed by `-`
  and the number of parts. `Fil.stat/3` returns `nil` for it, because it isn't the checksum of the file.
  `verify_checksum: true` asks for the size of the first part (a HeadObject with `partNumber=1`), checksums the content
  part by part and compares the result. That works for uploads whose parts all have one size but the last, as `Fil`'s
  and those of AWS's tools do. Other objects, and objects on a server that ignores `partNumber` (RustFS 1.0.0 does),
  are read without a check. Use `:crc32` for large streams if you need the checksum of the file later.

  ## Errors

  `:reason` is the error code from the response body (`"NoSuchKey"`), or `{:http_status, status}` when there's none.
  Failures before a response keep Req's reason (`:timeout`, an exception). The error code decides first, whatever the
  status, because S3-compatible servers don't all send the same one.

  | S3 response | `Fil` error |
  | --- | --- |
  | `NoSuchKey`, or `404` | `Fil.NotFoundError` |
  | `NoSuchBucket` | `Fil.ConfigurationError` |
  | a `400` for a copy whose source doesn't exist (checked with HeadObject) | `Fil.NotFoundError` |
  | `AccessDenied`, or `403` | `Fil.AccessDeniedError` |
  | `InvalidRequest`, `EntityTooLarge`, `KeyTooLongError` | `Fil.InvalidRequestError` |
  | a `size:` over 5 TiB | `Fil.InvalidRequestError`, `reason: "EntityTooLarge"` |
  | a stream without a size that needs more than 10,000 parts | `Fil.InvalidRequestError`, `reason: :too_many_parts` |
  | `PreconditionFailed`, `ConditionalRequestConflict` | `Fil.AlreadyExistsError` |
  | `412`, or a `409` without a code | `Fil.AlreadyExistsError` |
  | `NoSuchUpload`: an upload in parts was aborted from outside, by a lifecycle rule, say | `Fil.ConflictError` |
  | `BadDigest` | `Fil.ChecksumMismatchError` |
  | a body that doesn't match its stored checksum | `Fil.ChecksumMismatchError`, `reason: :checksum_mismatch` |
  | a signed URL or upload on a disk without credentials | `Fil.UnsupportedError`, `reason: :missing_credentials` |
  | `301`, or a `400` that gives another region | `Fil.ConfigurationError`, `reason: {:wrong_region, region}` |
  | `SlowDown`, `OperationAborted`, `InternalError`, `ServiceUnavailable` | `Fil.UnavailableError` |
  | `429`, `5xx` | `Fil.UnavailableError` |
  | timeouts, failed connections, an unreadable listing or upload ID | `Fil.UnavailableError` |
  | an uploaded part without an ETag | `Fil.UnknownError`, `reason: :missing_etag` |
  | anything else, such as an unmapped code inside the `200` of a CopyObject or a completion | `Fil.UnknownError` |
  """

  @behaviour Fil.Adapter

  alias Fil.Adapter.S3.Checksums
  alias Fil.Adapter.S3.Client
  alias Fil.Adapter.S3.MultipartUpload
  alias Fil.Stat
  alias Fil.Support.ByteRange
  alias Fil.Support.Content
  alias Fil.Support.Download
  alias Fil.Support.ObjectStore
  alias Fil.Support.Timestamps
  alias Fil.Support.XML

  # S3's limits: the largest PutObject, the largest object, and the most parts of a multipart upload.
  @max_put 5 * 1024 ** 3
  @max_object 5 * 1024 ** 4
  @max_parts 10_000

  # How long a failed part waits before it's sent again, so a storage that asked to slow down gets a moment.
  @retry_delay to_timeout(second: 1)

  @derive {Inspect, only: [:bucket, :region, :prefix, :endpoint, :public_endpoint, :path_style]}
  defstruct [
    :bucket,
    :region,
    :prefix,
    :endpoint,
    :public_endpoint,
    :path_style,
    :access_key_id,
    :secret_access_key,
    :session_token,
    :part_size,
    :req_options,
    max_parts: @max_parts,
    retry_delay: @retry_delay
  ]

  @type t :: %__MODULE__{}

  @impl Fil.Adapter
  def init(opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema),
         {:ok, prefix} <- ObjectStore.parse_root(opts[:root]),
         {:ok, endpoint} <- ObjectStore.parse_endpoint(:endpoint, opts[:endpoint]),
         {:ok, public_endpoint} <- ObjectStore.parse_endpoint(:public_endpoint, opts[:public_endpoint]) do
      {:ok,
       %__MODULE__{
         bucket: opts[:bucket],
         region: opts[:region],
         prefix: prefix,
         endpoint: endpoint,
         public_endpoint: public_endpoint,
         path_style: Keyword.get(opts, :path_style, endpoint != nil),
         access_key_id: opts[:access_key_id],
         secret_access_key: opts[:secret_access_key],
         session_token: opts[:session_token],
         part_size: opts[:part_size],
         req_options: opts[:req_options]
       }}
    end
  end

  # Credentials, `:public_endpoint`, `:path_style` and the rest only change how the storage is reached.
  @impl Fil.Adapter
  def address(state), do: {state.endpoint, state.region, state.bucket, state.prefix}

  @impl Fil.Adapter
  def read(state, path, opts) do
    case ByteRange.from_options(opts) do
      nil -> read_object(state, path, opts)
      range -> read_range(state, path, range)
    end
  end

  defp read_object(state, path, opts) do
    verify? = Keyword.get(opts, :verify_checksum, false)
    headers = if verify?, do: [Checksums.mode_header()], else: []

    case Client.request(state, :get, ObjectStore.key(state, path), headers: headers) do
      {:ok, %{status: 200} = response} when verify? -> Checksums.verify(state, ObjectStore.key(state, path), response)
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, response} -> {:error, Client.error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  # S3 answers a range that starts at or after the end, and any range of an empty object, with `416 InvalidRange`: the
  # range is empty then. A server that ignores the header sends the whole object, which is cut here.
  defp read_range(state, path, range) do
    case Client.request(state, :get, ObjectStore.key(state, path), headers: [range_header(range)]) do
      {:ok, %{status: 206, body: body}} -> {:ok, body}
      {:ok, %{status: 200, body: body}} -> {:ok, ByteRange.slice(body, range)}
      {:ok, %{status: 416}} -> {:ok, ""}
      {:ok, response} -> {:error, Client.error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp range_header({offset, nil}), do: {"range", "bytes=#{offset}-"}
  defp range_header({offset, length}), do: {"range", "bytes=#{offset}-#{offset + length - 1}"}

  @impl Fil.Adapter
  def write(state, path, content, opts) do
    key = ObjectStore.key(state, path)

    case route(content, opts) do
      :put ->
        put_object(state, key, content, opts)

      :put_stream ->
        put_stream(state, key, content, opts)

      {:parts, content, size} ->
        state
        |> MultipartUpload.upload(key, content, size, opts)
        |> single(state, key, opts)

      :too_large ->
        {:error, %Fil.InvalidRequestError{reason: "EntityTooLarge"}}
    end
  end

  # Content that fit in one part after all goes out in one request.
  defp single({:single, content}, state, key, opts), do: put_object(state, key, content, opts)
  defp single(result, _state, _key, _opts), do: result

  # Content in memory is one PutObject, up to S3's limit of 5 GiB for one. So is a stream of known size without a
  # checksum, sent as it's read. Anything else is uploaded in parts (see `Fil.Adapter.S3.MultipartUpload`).
  defp route(content, opts) do
    if Content.iodata?(content) do
      content
      |> IO.iodata_length()
      |> route_iodata(content)
    else
      route_stream(content, opts[:size], opts[:checksum])
    end
  end

  defp route_iodata(size, _content) when size > @max_object, do: :too_large
  defp route_iodata(size, content) when size > @max_put, do: {:parts, [IO.iodata_to_binary(content)], size}
  defp route_iodata(_size, _content), do: :put

  # A size over S3's limit is refused before the stream is read.
  defp route_stream(_stream, size, _checksum) when is_integer(size) and size > @max_object, do: :too_large
  defp route_stream(_stream, size, nil) when is_integer(size) and size <= @max_put, do: :put_stream
  defp route_stream(stream, size, _checksum), do: {:parts, stream, size}

  # One PutObject with content in memory, signed with its SHA-256.
  defp put_object(state, key, content, opts) do
    checksum = Checksums.headers(opts, content)

    headers =
      opts
      |> Client.content_type_header()
      |> ObjectStore.put_if_exists(opts)
      |> Kernel.++(checksum)

    put(state, key, headers, content)
  end

  # One PutObject that sends a stream of known size as it's read, with its `content-length`, signed with
  # `UNSIGNED-PAYLOAD` (Req does that for a streamed body).
  defp put_stream(state, key, content, opts) do
    headers =
      opts
      |> Client.content_type_header()
      |> ObjectStore.put_if_exists(opts)
      |> Kernel.++([{"content-length", Integer.to_string(opts[:size])}])

    put(state, key, headers, content)
  end

  defp put(state, key, headers, body) do
    case Client.request(state, :put, key, headers: headers, body: body) do
      {:ok, %{status: status}} when status in [200, 201] -> :ok
      {:ok, response} -> {:error, Client.error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Checks the object with a HeadObject, and downloads it when the stream is read (`Fil.Support.Download`). A HeadObject
  # has no body and so no error code, and a missing bucket is a 404 like a missing key, so a 404 is asked again with a
  # GetObject to get the same error as `read/3`.
  @impl Fil.Adapter
  def stream(state, path, opts) do
    verify? = Keyword.get(opts, :verify_checksum, false)
    headers = if verify?, do: [Checksums.mode_header()], else: []

    case Client.request(state, :head, ObjectStore.key(state, path), headers: headers) do
      {:ok, %{status: 200} = response} -> download(state, ObjectStore.key(state, path), response, verify?, opts)
      {:ok, %{status: 404}} -> with {:ok, content} <- read(state, path, opts), do: {:ok, [content], byte_size(content)}
      {:ok, response} -> {:error, Client.error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download(state, key, response, verify?, opts) do
    check = if verify?, do: Checksums.download_check(state, key, response), else: {:ok, nil}
    size = ObjectStore.content_length(response)
    range = ByteRange.from_options(opts)

    with {:ok, check} <- check,
         {range, size} <- Download.range(size, range) do
      get = &get_into(state, key, check, range, &1)
      # The label shows in `:observer` and crash reports. The key names the file, and nothing else goes in.
      {:ok, Download.stream({__MODULE__, :stream, key}, get, check, &Checksums.verify_download!/2), size}
    else
      :empty -> {:ok, [], 0}
      {:error, error} -> {:error, error}
    end
  end

  defp get_into(state, key, check, range, relay) do
    range_headers = if range, do: [range_header(range)], else: []
    headers = if check, do: [Checksums.mode_header() | range_headers], else: range_headers

    case Client.request(state, :get, key, headers: headers, into: Download.into(relay, range)) do
      {:ok, %{status: status, headers: headers}} when status in [200, 206] -> downloaded(status, range, headers)
      {:ok, response} -> {:error, Client.error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  # S3 answers a range with `206`, even one that covers the whole object. A `200` to a range is a server that ignored
  # the header, and `Fil.Support.Download.into/2` cuts the range from it. A `206` without a range is an error.
  defp downloaded(206, nil, _headers), do: {:error, %Fil.UnknownError{reason: {:http_status, 206}}}
  defp downloaded(_status, _range, headers), do: {:ok, headers}

  @impl Fil.Adapter
  def rm(state, path, _opts) do
    case Client.request(state, :delete, ObjectStore.key(state, path)) do
      {:ok, %{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %{status: 404} = response} ->
        response
        |> Client.error()
        |> ObjectStore.missing_is_ok()

      {:ok, response} ->
        {:error, Client.error(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Fil.Adapter
  def stat(_state, ".", _opts), do: {:ok, %Stat{type: :directory}}

  # `type:` skips the request for the other type: a directory needs no `HEAD`, and a missing file no listing.
  def stat(state, path, opts) do
    case Keyword.get(opts, :type) do
      :directory -> directory_stat(state, path)
      type -> object_stat(state, path, type, Keyword.get(opts, :checksum))
    end
  end

  defp object_stat(state, path, type, algorithm) do
    headers = if algorithm, do: [Checksums.mode_header()], else: []

    case Client.request(state, :head, ObjectStore.key(state, path), headers: headers) do
      {:ok, %{status: 200, headers: headers}} -> {:ok, object_stat(headers, algorithm)}
      {:ok, %{status: 404}} when type == :regular -> {:error, %Fil.NotFoundError{reason: {:http_status, 404}}}
      {:ok, %{status: 404}} -> directory_stat(state, path)
      {:ok, response} -> {:error, Client.error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp object_stat(headers, algorithm) do
    %Stat{
      size:
        headers
        |> ObjectStore.header("content-length")
        |> ObjectStore.integer(),
      type: :regular,
      mtime:
        headers
        |> ObjectStore.header("last-modified")
        |> Timestamps.parse_http_date(),
      etag:
        headers
        |> ObjectStore.header("etag")
        |> ObjectStore.unquote_etag(),
      content_type: ObjectStore.header(headers, "content-type"),
      checksum: algorithm && Checksums.stored(headers, algorithm)
    }
  end

  defp directory_stat(state, path), do: ObjectStore.directory_stat(state, &list_page(state, &1, &2, &3, &4), path)

  @impl Fil.Adapter
  def ls(state, path, opts), do: ObjectStore.ls(state, &list_page(state, &1, &2, &3, &4), path, opts)

  @impl Fil.Adapter
  def cp(state, src, dest, opts) do
    headers = ObjectStore.put_if_exists([{"x-amz-copy-source", Client.copy_source(state, src)}], opts)

    result =
      case Client.request(state, :put, ObjectStore.key(state, dest), headers: headers) do
        {:ok, %{status: 200} = response} -> Client.xml_result(response)
        {:ok, %{status: 400} = response} -> copy_error(state, src, Client.error(response))
        {:ok, response} -> {:error, Client.error(response)}
        {:error, reason} -> {:error, reason}
      end

    ObjectStore.existing_dest(result, dest)
  end

  # AWS answers a missing source with `404 NoSuchKey`, but some S3-compatible servers (SeaweedFS) send a plain 400, so
  # an unexplained 400 is checked against the source. So is `InvalidRequest`, which doesn't say much more.
  defp copy_error(state, src, %Fil.UnknownError{} = error), do: check_source(state, src, error)

  defp copy_error(state, src, %Fil.InvalidRequestError{reason: "InvalidRequest"} = error),
    do: check_source(state, src, error)

  defp copy_error(_state, _src, error), do: {:error, error}

  defp check_source(state, src, error) do
    case Client.request(state, :head, ObjectStore.key(state, src)) do
      {:ok, %{status: 404}} -> {:error, %Fil.NotFoundError{reason: {:http_status, 404}}}
      _other -> {:error, error}
    end
  end

  @impl Fil.Adapter
  def rename(state, src, dest, opts) do
    with :ok <- cp(state, src, dest, opts), do: rm(state, src, opts)
  end

  # One DeleteObject per key. The batched DeleteObjects call needs a hand-built XML body with an MD5 checksum, so that
  # optimization is left for later.
  @impl Fil.Adapter
  def rm_rf(state, path, opts) do
    ObjectStore.rm_rf(state, &list_page(state, &1, &2, &3, &4), path, &rm(state, &1, opts))
  end

  @impl Fil.Adapter
  def url(state, path, _opts),
    do: {:ok, Client.object_url(state, ObjectStore.key(state, path), [], Client.public_base_url(state))}

  # `Fil` has validated `:expires_in` (at most 7 days, the limit of S3) and built `:disposition`.
  @impl Fil.Adapter
  def signed_url(state, path, opts) do
    with :ok <- Client.check_credentials(state) do
      url = Client.public_object_url(state, ObjectStore.key(state, path))
      {:ok, Client.presign(state, url, :get, opts)}
    end
  end

  # The signature covers `content-type` and `content-length`, so S3 refuses an upload with others.
  @impl Fil.Adapter
  def binds_uploads?(_state), do: true

  # The headers the client sends are the signed ones but `content-length`, which a browser sets from the body.
  @impl Fil.Adapter
  def signed_upload(state, path, opts) do
    with :ok <- Client.check_credentials(state) do
      now = DateTime.utc_now(:second)
      url = Client.public_object_url(state, ObjectStore.key(state, path))

      headers =
        opts
        |> Client.upload_headers()
        |> Map.new()
        |> Map.delete("content-length")

      expires_at = DateTime.add(now, Keyword.get(opts, :expires_in, 900))

      {:ok,
       %{
         method: :put,
         url: Client.presign(state, url, :put, opts, now),
         headers: headers,
         fields: [],
         expires_at: expires_at
       }}
    end
  end

  ## ------------------------------------------------------------------
  ## Listing
  ## ------------------------------------------------------------------

  # One page of ListObjectsV2, for `Fil.Support.ObjectStore`.
  defp list_page(state, prefix, delimiter, token, max_keys) do
    with {:ok, result} <- list_request(state, list_params(prefix, delimiter, token, max_keys)) do
      objects = for contents <- XML.children(result, "Contents"), do: object_listing(contents)
      prefixes = for common_prefix <- XML.children(result, "CommonPrefixes"), do: XML.text(common_prefix, "Prefix")
      next = if XML.text(result, "IsTruncated") == "true", do: XML.text(result, "NextContinuationToken")

      {:ok, objects, prefixes, next}
    end
  end

  defp list_request(state, params) do
    case Client.request(state, :get, "", params: params) do
      {:ok, %{status: 200, body: body}} -> ObjectStore.parse_xml(body)
      {:ok, response} -> {:error, Client.error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_params(prefix, delimiter, token, max_keys) do
    Enum.reject(
      [
        {"list-type", "2"},
        {"prefix", prefix},
        {"delimiter", delimiter},
        {"continuation-token", token},
        {"max-keys", max_keys && Integer.to_string(max_keys)}
      ],
      fn {_name, value} -> is_nil(value) end
    )
  end

  # A key ending in `/` is a directory marker (an empty "folder" made in a console), listed as the directory it stands
  # for.
  defp object_listing(contents) do
    key = XML.text(contents, "Key")

    if String.ends_with?(key, "/") do
      {key, %Stat{type: :directory}}
    else
      stat = %Stat{
        size:
          contents
          |> XML.text("Size")
          |> ObjectStore.integer(),
        type: :regular,
        mtime:
          contents
          |> XML.text("LastModified")
          |> Timestamps.parse_iso8601(),
        etag:
          contents
          |> XML.text("ETag")
          |> ObjectStore.unquote_etag()
      }

      {key, stat}
    end
  end
end
