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

  Where this list says nothing else, an operation follows the [contract](Fil.Adapter.html#module-contract). Directories
  exist only as key prefixes, so there are no empty directories.

    * `Fil.read/3`: GetObject. Reading a directory is a `Fil.NotFoundError`. `verify_checksum: true` asks S3 for the
      stored checksum (`x-amz-checksum-mode: ENABLED`) and compares it with the downloaded content, including the
      composite checksum of an upload in parts (see [Checksums](#module-checksums)). Objects stored with another
      algorithm, or with none, are read without a check.
    * `Fil.stream/3`: HeadObject, then GetObject each time the stream is read. The download runs in a process of its
      own and goes only as fast as the stream is read. `verify_checksum: true` computes the checksum while streaming.
    * `Fil.write/4`: PutObject for content in memory, and for a stream of known size (`size:`, a `File.Stream`, a stream
      from `Fil.stream/3`), which is sent as it's read. A stream without a size or with `checksum:`, and anything over
      5 GiB, goes up in parts instead (see [Uploads in parts](#module-uploads-in-parts)). `if_exists: :error` sends
      `If-None-Match: *`. `checksum:` (`:sha256`, `:sha1` or `:crc32`) sends the checksum of the content in
      `x-amz-checksum-*`, S3 rejects the upload if what it received doesn't match, and stores the checksum with the
      object. Writing to `report.txt/x` when `report.txt` is an object writes a second object and leaves the first
      alone.
    * `Fil.rm/3`: DeleteObject, which S3 already treats as idempotent (a `404` for a missing bucket is still an error).
      Removing a directory succeeds and removes nothing.
    * `Fil.stat/3`: HeadObject, then a prefix probe if there's no object, so `Fil.dir?/1` works. `:etag` and
      `:content_type` are the ones S3 returns, and the ETag of an upload in parts ends in `-` and the number of parts.
      `checksum:` returns the checksum S3 stored if the write used the same algorithm, and `nil` otherwise, as well as
      for the composite checksum of an upload in parts.
    * `Fil.ls/3`: ListObjectsV2, with `delimiter=/` unless recursive, paginated internally.
    * `Fil.cp/4`: CopyObject. Copying a directory is a `Fil.NotFoundError`.
    * `Fil.rename/4`: CopyObject, then DeleteObject.
    * `Fil.rm_rf/3`: ListObjectsV2, then one DeleteObject per key.
    * `Fil.url/3`: the object URL, without a signature, so it works for public objects only.
    * `Fil.signed_url/3`: a presigned GET or PUT URL, with `response-content-disposition` for `disposition:`, and the
      `query:` parameters.

  ## Uploads in parts

  A stream without a size, a stream with `checksum:`, and content over 5 GiB (the largest PutObject) are read one part
  at a time, `:part_size` bytes each, so an upload keeps about one part and one chunk in memory. Content that ends
  within the first part goes out as one PutObject once it has ended. Anything longer is a multipart upload:

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

  ### Checksums

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
  | `EntityTooLarge`, `KeyTooLongError` | `Fil.InvalidRequestError` |
  | a `size:` over 5 TiB | `Fil.InvalidRequestError`, `reason: "EntityTooLarge"` |
  | a stream without a size that needs more than 10,000 parts | `Fil.InvalidRequestError`, `reason: :too_many_parts` |
  | `PreconditionFailed`, `ConditionalRequestConflict` | `Fil.AlreadyExistsError` |
  | `412`, or a `409` without a code | `Fil.AlreadyExistsError` |
  | `NoSuchUpload`: an upload in parts was aborted from outside, by a lifecycle rule, say | `Fil.ConflictError` |
  | `BadDigest` | `Fil.ChecksumMismatchError` |
  | a body that doesn't match its stored checksum | `Fil.ChecksumMismatchError`, `reason: :checksum_mismatch` |
  | a signed URL on a disk without credentials | `Fil.UnsupportedError`, `reason: :missing_credentials` |
  | `301`, or a `400` that gives another region | `Fil.ConfigurationError`, `reason: {:wrong_region, region}` |
  | `SlowDown`, `OperationAborted`, `InternalError`, `ServiceUnavailable` | `Fil.UnavailableError` |
  | `429`, `5xx` | `Fil.UnavailableError` |
  | timeouts, failed connections, an unreadable listing or upload ID | `Fil.UnavailableError` |
  | an uploaded part without an ETag | `Fil.UnknownError`, `reason: :missing_etag` |
  | anything else, such as an unmapped code inside the `200` of a CopyObject or a completion | `Fil.UnknownError` |
  """

  @behaviour Fil.Adapter

  alias Fil.Stat
  alias Fil.Support.Checksum
  alias Fil.Support.Content
  alias Fil.Support.Parts
  alias Fil.Support.Relay
  alias Fil.Support.XML

  import Fil.Support.Timestamps
  import Fil.Support.URL

  @checksum_mode {"x-amz-checksum-mode", "ENABLED"}

  # S3's limits: the largest PutObject, the largest object, and the most parts of a multipart upload.
  @max_put 5 * 1024 ** 3
  @max_object 5 * 1024 ** 4
  @max_parts 10_000

  # How long a failed part waits before it's sent again, in milliseconds, so a storage that asked to slow down gets a
  # moment.
  @retry_delay 1_000

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
         {:ok, prefix} <- parse_root(opts[:root]),
         {:ok, endpoint} <- parse_endpoint(:endpoint, opts[:endpoint]),
         {:ok, public_endpoint} <- parse_endpoint(:public_endpoint, opts[:public_endpoint]) do
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

  @impl Fil.Adapter
  def read(state, path, opts) do
    verify? = Keyword.get(opts, :verify_checksum, false)
    headers = if verify?, do: [@checksum_mode], else: []

    case request(state, :get, key(state, path), headers: headers) do
      {:ok, %{status: 200} = response} when verify? -> verify_checksum(state, key(state, path), response)
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Fil.Adapter
  def write(state, path, content, opts) do
    key = key(state, path)

    case route(content, opts) do
      :put -> put_object(state, key, content, opts)
      :put_stream -> put_stream(state, key, content, opts)
      {:parts, content, size} -> upload(state, key, content, size, opts)
      :too_large -> {:error, %Fil.InvalidRequestError{reason: "EntityTooLarge"}}
    end
  end

  # Content in memory is one PutObject, up to S3's limit of 5 GiB for one. So is a stream of known size without a
  # checksum, sent as it's read. Anything else is uploaded in parts (see `upload/5`).
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
    checksum = checksum_header(opts, content)

    headers =
      opts
      |> content_type_header()
      |> put_if_exists(opts)
      |> Kernel.++(checksum)

    put(state, key, headers, content)
  end

  # One PutObject that sends a stream of known size as it's read, with its `content-length`, signed with
  # `UNSIGNED-PAYLOAD` (Req does that for a streamed body).
  defp put_stream(state, key, content, opts) do
    headers =
      opts
      |> content_type_header()
      |> put_if_exists(opts)
      |> Kernel.++([{"content-length", Integer.to_string(opts[:size])}])

    put(state, key, headers, content)
  end

  defp put(state, key, headers, body) do
    case request(state, :put, key, headers: headers, body: body) do
      {:ok, %{status: status}} when status in [200, 201] -> :ok
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Checks the object with a HeadObject, and downloads it when the stream is read. The download runs in a process of
  # its own that sends the chunks one at a time (`Fil.Support.Relay`), so it goes no faster than the stream is read.
  # A HeadObject has no body and so no error code, and a missing bucket is a 404 like a missing key, so a 404 is asked
  # again with a GetObject to get the same error as `read/3`.
  @impl Fil.Adapter
  def stream(state, path, opts) do
    verify? = Keyword.get(opts, :verify_checksum, false)
    headers = if verify?, do: [@checksum_mode], else: []

    case request(state, :head, key(state, path), headers: headers) do
      {:ok, %{status: 200} = response} -> download(state, key(state, path), response, verify?)
      {:ok, %{status: 404}} -> with {:ok, content} <- read(state, path, opts), do: {:ok, [content], byte_size(content)}
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download(state, key, response, verify?) do
    check = if verify?, do: download_check(state, key, response), else: {:ok, nil}

    with {:ok, check} <- check do
      stream =
        Stream.resource(
          fn -> start_download(state, key, check) end,
          &next_chunk/1,
          &stop_download/1
        )

      {:ok, stream, content_length(response)}
    end
  end

  defp content_length(%{headers: headers}), do: integer(header(headers, "content-length"))

  # What the download computes as it goes, from the checksum the HeadObject found: the checksum of the whole object,
  # or a composite one, whose parts it then needs the size of. `nil` for none, or one that can't be checked.
  defp download_check(state, key, response) do
    case find_checksum(response.headers) do
      nil ->
        {:ok, nil}

      {algorithm, _checksum} ->
        {:ok, %{algorithm: algorithm, checksum: Checksum.init(algorithm), composite: nil}}

      {algorithm, composite, parts} ->
        size = content_length(response)

        with {:ok, part_size} <- part_size(state, key, response, size, parts) do
          {:ok, composite_check(algorithm, composite, part_size)}
        end
    end
  end

  defp composite_check(_algorithm, _composite, nil), do: nil

  defp composite_check(algorithm, composite, part_size) do
    %{algorithm: algorithm, checksum: Checksum.init_parts(algorithm, part_size), composite: composite}
  end

  defp start_download(state, key, check) do
    reader = self()
    ref = make_ref()
    # `$callers` lets the download find what the reader was allowed, such as a `Req.Test` stub.
    callers = [reader | Process.get(:"$callers", [])]

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        relay = %Relay{to: reader, ref: ref, monitor: Process.monitor(reader)}
        headers = if check, do: [@checksum_mode], else: []

        result =
          case request(state, :get, key, headers: headers, into: relay) do
            {:ok, %{status: 200, headers: headers}} -> {:ok, headers}
            {:ok, response} -> {:error, error(response)}
            {:error, reason} -> {:error, reason}
          end

        send(reader, {ref, :done, result})
      end)

    %{pid: pid, monitor: monitor, ref: ref, check: check}
  end

  defp next_chunk(%{pid: pid, monitor: monitor, ref: ref} = download) do
    receive do
      {^ref, :data, chunk} ->
        send(pid, {ref, :more})
        {[chunk], put_chunk(download, chunk)}

      {^ref, :done, result} ->
        finish_download!(download, result)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        crashed!(reason)
    end
  end

  defp put_chunk(%{check: nil} = download, _chunk), do: download

  defp put_chunk(%{check: check} = download, chunk) do
    %{download | check: %{check | checksum: Checksum.update(check.checksum, chunk)}}
  end

  defp finish_download!(download, {:ok, headers}) do
    verify_download!(download, headers)
    {:halt, download}
  end

  defp finish_download!(_download, {:error, error}), do: raise(error)

  # The download process only ends before it's done if it crashed, for example on bad `:req_options`.
  defp crashed!({%{__exception__: true} = exception, stacktrace}), do: reraise(exception, stacktrace)
  defp crashed!(reason), do: exit(reason)

  # Compared with the checksum the GetObject returned, which belongs to the content that was downloaded. An object
  # replaced since the HeadObject may have none for this algorithm, or parts of another size, and is then read without
  # a check, like `read/3`.
  defp verify_download!(%{check: nil}, _headers), do: :ok

  defp verify_download!(%{check: check}, headers) do
    case downloaded_checksum(check, headers) do
      nil ->
        :ok

      stored ->
        if Checksum.final(check.checksum) != stored, do: raise(%Fil.ChecksumMismatchError{reason: :checksum_mismatch})
    end
  end

  defp downloaded_checksum(%{algorithm: algorithm, composite: nil}, headers) do
    with {^algorithm, stored} <- stored_checksum(headers, algorithm), do: stored
  end

  defp downloaded_checksum(%{algorithm: algorithm, composite: composite}, headers) do
    if header(headers, checksum_header(algorithm)) == composite, do: composite
  end

  # Runs when the stream is done, halted early or raised. Stopping the download closes its connection. A chunk it sent
  # meanwhile arrives before the `:DOWN` of a new monitor, so it's dropped once that's in.
  defp stop_download(%{pid: pid, monitor: monitor, ref: ref}) do
    Process.demonitor(monitor, [:flush])
    stopped = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^stopped, :process, ^pid, _reason} -> flush_download(ref)
    end
  end

  defp flush_download(ref) do
    receive do
      {^ref, _tag, _value} -> flush_download(ref)
    after
      0 -> :ok
    end
  end

  @impl Fil.Adapter
  def rm(state, path, _opts) do
    case request(state, :delete, key(state, path)) do
      {:ok, %{status: status}} when status in [200, 204] -> :ok
      {:ok, %{status: 404} = response} -> missing_is_ok(error(response))
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  # A missing file is fine for an idempotent delete, a missing bucket isn't.
  defp missing_is_ok(%Fil.NotFoundError{}), do: :ok
  defp missing_is_ok(error), do: {:error, error}

  @impl Fil.Adapter
  def stat(_state, ".", _opts), do: {:ok, %Stat{type: :directory}}

  def stat(state, path, opts) do
    algorithm = Keyword.get(opts, :checksum)
    headers = if algorithm, do: [@checksum_mode], else: []

    case request(state, :head, key(state, path), headers: headers) do
      {:ok, %{status: 200} = response} -> {:ok, object_stat(response, algorithm)}
      {:ok, %{status: 404}} -> directory_stat(state, path)
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Fil.Adapter
  def ls(state, prefix, opts) do
    delimiter = if !Keyword.get(opts, :recursive, false), do: "/"

    with {:ok, contents, prefixes} <- list_all(state, list_prefix(state, prefix), delimiter) do
      listed = Enum.map(contents, &object_listing(state, &1)) ++ Enum.map(prefixes, &prefix_listing(state, &1))

      {:ok, Enum.sort_by(listed, &elem(&1, 0))}
    end
  end

  @impl Fil.Adapter
  def cp(state, src, dest, _opts) do
    headers = [{"x-amz-copy-source", copy_source(state, src)}]

    case request(state, :put, key(state, dest), headers: headers) do
      {:ok, %{status: 200} = response} -> xml_result(response)
      {:ok, %{status: 400} = response} -> copy_error(state, src, error(response))
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  # AWS answers a missing source with `404 NoSuchKey`, but some S3-compatible servers (SeaweedFS) send a plain 400, so
  # an unexplained 400 is checked against the source.
  defp copy_error(state, src, %Fil.UnknownError{} = error) do
    case request(state, :head, key(state, src)) do
      {:ok, %{status: 404}} -> {:error, %Fil.NotFoundError{reason: {:http_status, 404}}}
      _other -> {:error, error}
    end
  end

  defp copy_error(_state, _src, error), do: {:error, error}

  @impl Fil.Adapter
  def rename(state, src, dest, opts) do
    with :ok <- cp(state, src, dest, opts), do: rm(state, src, opts)
  end

  @impl Fil.Adapter
  def rm_rf(state, prefix, opts) do
    # One DeleteObject per key. The batched DeleteObjects call needs a hand-built XML body with an MD5 checksum, so that
    # optimization is left for later.
    with {:ok, contents, _prefixes} <- list_all(state, base_prefix(state, prefix), nil) do
      contents
      |> Enum.map(&relative(state, XML.text(&1, "Key")))
      |> Enum.filter(&under_prefix?(&1, prefix))
      |> delete_each(state, opts)
    end
  end

  defp delete_each(paths, state, opts) do
    Enum.reduce_while(paths, {:ok, 0}, fn path, {:ok, count} ->
      case rm(state, path, opts) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl Fil.Adapter
  def url(state, path, _opts), do: {:ok, object_url(state, key(state, path), [], public_base_url(state))}

  @impl Fil.Adapter
  def signed_url(state, path, opts) do
    # `Fil` has validated `:method` and `:expires_in` (at most 7 days, the limit of S3) and built `:disposition`.
    if is_nil(state.access_key_id) or is_nil(state.secret_access_key) do
      {:error, %Fil.UnsupportedError{reason: :missing_credentials}}
    else
      {:ok, presign(state, key(state, path), opts)}
    end
  end

  ## ------------------------------------------------------------------
  ## Uploads in parts
  ## ------------------------------------------------------------------

  # A stream without a size or with a checksum, and content over 5 GiB, is read one part at a time
  # (`Fil.Support.Parts`), in parts of `:part_size`, or larger ones for known sizes that would need more than 10,000.
  # Content that ends within the first part goes out as one PutObject. Anything larger starts a multipart upload once
  # the second part begins, uploads each part when it's full, and completes the upload after the content has ended, so
  # nothing is written unless it ends.
  #
  # A guard process (`start_guard/2`) creates the upload and is the only one that aborts it: when the write fails,
  # raises or is killed. The content is read and the parts are uploaded in the calling process.
  defp upload(state, key, content, size, opts) do
    guard = start_guard(state, key)
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
        stop_guard(guard, :done)

      {:error, error} ->
        stop_guard(guard, :abort)
        {:error, error}
    catch
      kind, reason ->
        stop_guard(guard, :abort)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # Called with every full part while the stream is read, so a failed request halts the stream instead of raising: the
  # content is read inside `Fil.Op`, where a raised `Fil` error would count as the source's. A full part always has
  # more content behind it, so the last part a stream can have is refused before it's uploaded.
  defp next_part(state, part, upload, opts) do
    result =
      if upload.number + 1 >= state.max_parts,
        do: {:error, %Fil.InvalidRequestError{reason: :too_many_parts}},
        else: upload_part(state, part, upload, opts)

    case result do
      {:ok, upload} -> {:cont, upload}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp finish_upload({:halted, {:error, error}}, _state, _opts), do: {:error, error}
  defp finish_upload({:done, last, %{id: nil, key: key}}, state, opts), do: put_object(state, key, last, opts)

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
  defp part_checksum_header(algorithm, checksum), do: [{checksum_header(algorithm), checksum}]

  # S3 only stores and checks the checksums of an upload in parts when the upload declares the algorithm up front.
  # CRC32 can cover the whole object (`FULL_OBJECT`). SHA-1 and SHA-256 can't, so S3 stores a checksum of the parts'
  # checksums (`COMPOSITE`, the default), which ends in `-` and the number of parts.
  defp create_upload(%{id: nil, guard: guard} = upload, opts) do
    headers = [{"content-length", "0"} | content_type_header(opts)] ++ algorithm_headers(upload.algorithm)

    with {:ok, id} <- call_guard(guard, {:create, headers}), do: {:ok, %{upload | id: id}}
  end

  defp create_upload(upload, _opts), do: {:ok, upload}

  # A part is in memory and invisible until the upload completes, so a part that failed with `Fil.UnavailableError` is
  # sent once more, a second later (`SlowDown` and `503` are unavailable too). The ETag goes into the completion as S3
  # sent it, quotes included.
  defp send_part(state, upload, number, part, headers, retries \\ 1) do
    params = [{"partNumber", number}, {"uploadId", upload.id}]

    result =
      case request(state, :put, upload.key, params: params, headers: headers, body: part) do
        {:ok, %{status: 200} = response} -> etag(response.headers)
        {:ok, response} -> {:error, error(response)}
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:error, %Fil.UnavailableError{}} when retries > 0 ->
        Process.sleep(state.retry_delay)
        send_part(state, upload, number, part, headers, retries - 1)

      result ->
        result
    end
  end

  defp etag(headers) do
    case header(headers, "etag") do
      nil -> {:error, %Fil.UnknownError{reason: :missing_etag}}
      etag -> {:ok, etag}
    end
  end

  # `if_exists: :error` can only be checked here: S3 takes `If-None-Match` on the completion, and not before.
  defp complete_upload(state, upload, opts) do
    headers = put_if_exists(whole_checksum_headers(upload), opts)
    params = [{"uploadId", upload.id}]

    case request(state, :post, upload.key, params: params, headers: headers, body: completion(upload)) do
      {:ok, %{status: 200} = response} -> xml_result(response)
      {:ok, response} -> {:error, error(response)}
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

  ## Guard

  # The guard is a process of its own that creates the multipart upload and aborts it, so an upload whose writer is
  # killed (a supervisor shutdown, a client that disconnects from a Cowboy request) is aborted too. It monitors the
  # writer, and knows the upload from the moment it exists. It isn't linked, so it outlives a killed writer. The writer
  # stops it with `:done` after completing, and with `:abort` on any failure, and waits until it's done, so no upload
  # is left when a write returns. What a guard can't clean up (the node goes down, the abort fails) is left to the
  # bucket's lifecycle rules.
  defp start_guard(state, key) do
    writer = self()
    ref = make_ref()
    # `$callers` lets the guard find what the writer was allowed, such as a `Req.Test` stub.
    callers = [writer | Process.get(:"$callers", [])]

    pid =
      spawn(fn ->
        Process.put(:"$callers", callers)
        guard(%{state: state, key: key, ref: ref, writer: writer, monitor: Process.monitor(writer), id: nil})
      end)

    %{pid: pid, ref: ref}
  end

  defp guard(%{ref: ref, writer: writer, monitor: monitor} = guard) do
    receive do
      {^ref, {:create, headers}} ->
        guard
        |> create(headers)
        |> guard()

      {^ref, :done} ->
        send(writer, {ref, :ok})

      {^ref, :abort} ->
        abort(guard)
        send(writer, {ref, :ok})

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        abort(guard)
    end
  end

  # Creates the upload and tells the writer its id, which the guard keeps.
  defp create(%{state: state, key: key, ref: ref, writer: writer} = guard, headers) do
    result =
      case request(state, :post, key, params: [{"uploads", ""}], headers: headers) do
        {:ok, %{status: 200, body: body}} -> upload_id(body)
        {:ok, response} -> {:error, error(response)}
        {:error, reason} -> {:error, reason}
      end

    send(writer, {ref, result})

    case result do
      {:ok, id} -> %{guard | id: id}
      {:error, _error} -> guard
    end
  end

  defp upload_id(body) do
    with {:ok, result} <- parse_xml(body) do
      case XML.text(result, "UploadId") do
        id when id in [nil, ""] -> {:error, %Fil.UnavailableError{reason: :invalid_xml}}
        id -> {:ok, id}
      end
    end
  end

  # Once the upload is completed or aborted, S3 answers `404 NoSuchUpload`, which is fine too. A failed abort is left
  # to the lifecycle rules: the write's own error is what the caller needs.
  defp abort(%{id: nil}), do: :ok

  defp abort(%{state: state, key: key, id: id}) do
    _result = request(state, :delete, key, params: [{"uploadId", id}])
    :ok
  end

  # The guard crashes only on a bug, such as bad `:req_options`, which the writer then raises.
  defp call_guard(guard, message) do
    case ask_guard(guard, message) do
      {:down, reason} -> crashed!(reason)
      reply -> reply
    end
  end

  # A guard that crashed has nothing left to stop, and its error was raised already.
  defp stop_guard(guard, message) do
    case ask_guard(guard, message) do
      {:down, _reason} -> :ok
      reply -> reply
    end
  end

  defp ask_guard(%{pid: pid, ref: ref}, message) do
    monitor = Process.monitor(pid)
    send(pid, {ref, message})

    receive do
      {^ref, reply} ->
        Process.demonitor(monitor, [:flush])
        reply

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:down, reason}
    end
  end

  ## ------------------------------------------------------------------
  ## Options
  ## ------------------------------------------------------------------

  # The root is stored as a key prefix: `""` for the bucket root, otherwise the normalized root with a trailing slash.
  defp parse_root(root) do
    case Fil.Support.Path.normalize(root) do
      {:ok, "."} -> {:ok, ""}
      {:ok, path} -> {:ok, path <> "/"}
      {:error, :ebadpath} -> {:error, {:invalid_option, {:root, root}}}
    end
  end

  defp parse_endpoint(_name, nil), do: {:ok, nil}

  defp parse_endpoint(name, endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, String.trim_trailing(endpoint, "/")}

      _other ->
        {:error, {:invalid_option, {name, endpoint}}}
    end
  end

  defp content_type_header(opts) do
    case Keyword.get(opts, :content_type) do
      nil -> []
      content_type -> [{"content-type", content_type}]
    end
  end

  # S3 creates an object only if none exists when the request has `If-None-Match: *`.
  defp put_if_exists(headers, opts) do
    case Keyword.get(opts, :if_exists, :overwrite) do
      :overwrite -> headers
      :error -> [{"if-none-match", "*"} | headers]
    end
  end

  defp checksum_header(opts, body) do
    case Keyword.get(opts, :checksum) do
      nil -> []
      algorithm -> [{checksum_header(algorithm), Checksum.digest(algorithm, body)}]
    end
  end

  ## ------------------------------------------------------------------
  ## Checksums
  ## ------------------------------------------------------------------

  defp checksum_header(algorithm), do: "x-amz-checksum-#{algorithm}"

  # `{algorithm, checksum}` if S3 returned a checksum for this algorithm. Composite checksums of uploads in parts end in
  # `-` and the number of parts, and cover the parts, so they're skipped (base64 has no `-`).
  defp stored_checksum(headers, algorithm) do
    case header(headers, checksum_header(algorithm)) do
      nil -> nil
      checksum -> if !String.contains?(checksum, "-"), do: {algorithm, checksum}
    end
  end

  # `{algorithm, checksum, parts}` if S3 returned a composite checksum for this algorithm.
  defp composite_checksum(headers, algorithm) do
    with checksum when is_binary(checksum) <- header(headers, checksum_header(algorithm)),
         [_digest, parts] <- String.split(checksum, "-"),
         {parts, ""} when parts > 0 <- Integer.parse(parts) do
      {algorithm, checksum, parts}
    else
      _none -> nil
    end
  end

  # The checksum stored with the object, of the whole object or composite, for the first algorithm that has one.
  defp find_checksum(headers) do
    Enum.find_value(Checksum.algorithms(), fn algorithm ->
      stored_checksum(headers, algorithm) || composite_checksum(headers, algorithm)
    end)
  end

  defp verify_checksum(state, key, %{body: body} = response) do
    case checksums(state, key, response) do
      {:ok, {same, same}} -> {:ok, body}
      {:ok, {_computed, _stored}} -> {:error, %Fil.ChecksumMismatchError{reason: :checksum_mismatch}}
      {:ok, nil} -> {:ok, body}
      {:error, error} -> {:error, error}
    end
  end

  # `{computed, stored}`, or `nil` if there's nothing to check.
  defp checksums(state, key, %{body: body} = response) do
    case find_checksum(response.headers) do
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

  # A composite checksum can only be checked with the size of the parts, which S3 doesn't store with it, but a
  # HeadObject for part 1 returns. Every part but the last has that size in uploads from `Fil` and from AWS's tools,
  # which is all the check assumes. Parts that don't add up to the object, and a server that ignores `partNumber`
  # (RustFS answers with the whole object), give `nil`, and the content is read without a check. So does a server that
  # refuses `partNumber` (`400`, `501`). `If-Match` makes sure part 1 belongs to the object that was read, and an object
  # replaced or removed since then is read without a check. A failed connection or a `5xx` fails the read.
  defp part_size(state, key, response, size, parts) do
    headers = Enum.map(response.headers["etag"] || [], &{"if-match", &1})

    case request(state, :head, key, params: [{"partNumber", 1}], headers: headers) do
      {:ok, %{status: status} = part} when status in [200, 206] ->
        {:ok, uniform_part_size(content_length(part), size, parts)}

      {:ok, %{status: status}} when status in [400, 404, 412, 501] ->
        {:ok, nil}

      {:ok, response} ->
        {:error, error(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp uniform_part_size(part_size, size, parts) when is_integer(part_size) and part_size > 0 and is_integer(size) do
    last = size - (parts - 1) * part_size
    if last > 0 and last <= part_size, do: part_size
  end

  defp uniform_part_size(_part_size, _size, _parts), do: nil

  ## ------------------------------------------------------------------
  ## Requests
  ## ------------------------------------------------------------------

  defp request(state, method, key, opts \\ []) do
    params = Keyword.get(opts, :params, [])

    options =
      Keyword.merge(state.req_options,
        method: method,
        url: object_url(state, key, params),
        headers: Keyword.get(opts, :headers, []),
        body: Keyword.get(opts, :body),
        into: Keyword.get(opts, :into),
        aws_sigv4: aws_sigv4(state),
        retry: false,
        raw: true
      )

    # Every status, 5xx included, comes back as a response and is mapped by the caller. Only a failed connection is an
    # error here.
    case Req.request(options) do
      {:ok, response} -> {:ok, response}
      {:error, %Req.TransportError{reason: reason}} -> {:error, %Fil.UnavailableError{reason: reason}}
      {:error, exception} -> {:error, %Fil.UnavailableError{reason: exception}}
    end
  end

  # Req signs every request with SigV4 when the disk has credentials. Without them, requests go out unsigned, which is
  # how a public bucket is read.
  defp aws_sigv4(%__MODULE__{access_key_id: nil}), do: nil
  defp aws_sigv4(%__MODULE__{secret_access_key: nil}), do: nil

  defp aws_sigv4(state) do
    [
      access_key_id: state.access_key_id,
      secret_access_key: state.secret_access_key,
      token: state.session_token,
      region: state.region,
      service: :s3
    ]
  end

  # `Req.Utils.aws_sigv4_url/1` is private Req API. Req isn't pinned for it: if a release drops it, presigning crashes.
  # It has no option for a session token, but it signs any extra query parameters, so the token goes in that way, and so
  # do the `response-content-disposition` S3 answers the download with and the caller's `:query`.
  defp presign(state, key, opts) do
    query =
      Enum.reject(
        [
          {"X-Amz-Security-Token", state.session_token},
          {"response-content-disposition", Keyword.get(opts, :disposition)}
          | Keyword.get(opts, :query, [])
        ],
        &is_nil(elem(&1, 1))
      )

    [
      access_key_id: state.access_key_id,
      secret_access_key: state.secret_access_key,
      region: state.region,
      service: :s3,
      datetime: DateTime.utc_now(),
      method: Keyword.get(opts, :method, :get),
      url: object_url(state, key, [], public_base_url(state)),
      expires: Keyword.get(opts, :expires_in, 900),
      query: query
    ]
    |> Req.Utils.aws_sigv4_url()
    |> URI.to_string()
  end

  defp object_url(state, key, params, base_url \\ nil) do
    (base_url || base_url(state, state.endpoint)) <> encode_key(key) <> encode_query(params)
  end

  # URLs handed out to clients use the public endpoint, requests the disk makes itself use `:endpoint`.
  defp public_base_url(state), do: base_url(state, state.public_endpoint || state.endpoint)

  defp base_url(state, nil) do
    if state.path_style do
      "https://s3.#{state.region}.amazonaws.com/#{state.bucket}"
    else
      "https://#{state.bucket}.s3.#{state.region}.amazonaws.com"
    end
  end

  defp base_url(state, endpoint) do
    if state.path_style, do: endpoint <> "/" <> state.bucket, else: endpoint
  end

  defp encode_key(""), do: "/"
  defp encode_key(key), do: "/" <> encode_path(key)

  defp copy_source(state, src), do: "/" <> state.bucket <> "/" <> encode_path(key(state, src))

  # CopyObject and CompleteMultipartUpload can report failure inside a `200`, after the status has gone out. Only an
  # `<Error>` document is a failure: once the object may have been written, a body that can't be read doesn't turn it
  # into an error.
  defp xml_result(response) do
    case XML.parse(response.body) do
      {:ok, {"Error", _attributes, _children}} -> {:error, error(response)}
      _result_or_unreadable -> :ok
    end
  end

  ## ------------------------------------------------------------------
  ## Keys and prefixes
  ## ------------------------------------------------------------------

  # Paths are relative to the disk root, keys are relative to the bucket. `state.prefix` is `""` or ends in `/`.
  defp key(state, "."), do: state.prefix
  defp key(state, path), do: state.prefix <> path

  defp list_prefix(state, "."), do: state.prefix
  defp list_prefix(state, path), do: state.prefix <> path <> "/"

  defp base_prefix(state, "."), do: state.prefix
  defp base_prefix(state, path), do: state.prefix <> path

  defp relative(state, key), do: String.replace_prefix(key, state.prefix, "")

  defp under_prefix?(_key, "."), do: true
  defp under_prefix?(key, prefix), do: key == prefix or String.starts_with?(key, prefix <> "/")

  ## ------------------------------------------------------------------
  ## Listing
  ## ------------------------------------------------------------------

  defp list_all(state, prefix, delimiter, token \\ nil, contents \\ [], prefixes \\ []) do
    with {:ok, result} <- list_page(state, prefix, delimiter, token) do
      page_contents =
        result
        |> XML.children("Contents")
        |> Enum.reject(&marker?(&1, prefix))

      contents = contents ++ page_contents

      prefixes = prefixes ++ XML.children(result, "CommonPrefixes")

      case next_token(result) do
        nil -> {:ok, contents, prefixes}
        token -> list_all(state, prefix, delimiter, token, contents, prefixes)
      end
    end
  end

  defp list_page(state, prefix, delimiter, token) do
    case request(state, :get, "", params: list_params(prefix, delimiter, token)) do
      {:ok, %{status: 200, body: body}} -> parse_xml(body)
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_params(prefix, delimiter, token) do
    Enum.reject(
      [
        {"list-type", "2"},
        {"prefix", prefix},
        {"delimiter", delimiter},
        {"continuation-token", token}
      ],
      fn {_name, value} -> is_nil(value) end
    )
  end

  defp parse_xml(body) do
    case XML.parse(body) do
      {:ok, element} -> {:ok, element}
      {:error, :invalid_xml} -> {:error, %Fil.UnavailableError{reason: :invalid_xml}}
    end
  end

  defp next_token(result) do
    if XML.text(result, "IsTruncated") == "true", do: XML.text(result, "NextContinuationToken")
  end

  # A "directory marker" is an empty object named exactly like the listed directory. Only listings pass a prefix with a
  # trailing slash. Prefix deletions don't, and there a key equal to the prefix is a file to remove.
  defp marker?(contents, prefix) do
    String.ends_with?(prefix, "/") and XML.text(contents, "Key") == prefix
  end

  defp object_listing(state, contents) do
    stat = %Stat{
      size: integer(XML.text(contents, "Size")),
      type: :regular,
      mtime: parse_iso8601(XML.text(contents, "LastModified")),
      etag: unquote_etag(XML.text(contents, "ETag"))
    }

    {relative(state, XML.text(contents, "Key")), stat}
  end

  defp prefix_listing(state, common_prefix) do
    path =
      common_prefix
      |> XML.text("Prefix")
      |> to_string()
      |> String.trim_trailing("/")
      |> then(&relative(state, &1))

    {path, %Stat{type: :directory}}
  end

  ## ------------------------------------------------------------------
  ## Stat
  ## ------------------------------------------------------------------

  defp object_stat(%{headers: headers}, algorithm) do
    %Stat{
      size: integer(header(headers, "content-length")),
      type: :regular,
      mtime: parse_http_date(header(headers, "last-modified")),
      etag: unquote_etag(header(headers, "etag")),
      content_type: header(headers, "content-type"),
      checksum: algorithm && stored_checksum(headers, algorithm)
    }
  end

  defp directory_stat(state, path) do
    with {:ok, contents, prefixes} <- list_all(state, list_prefix(state, path), "/") do
      if contents == [] and prefixes == [] do
        {:error, %Fil.NotFoundError{reason: {:http_status, 404}}}
      else
        {:ok, %Stat{type: :directory}}
      end
    end
  end

  ## ------------------------------------------------------------------
  ## Errors
  ## ------------------------------------------------------------------

  @codes %{
    "NoSuchKey" => Fil.NotFoundError,
    "NoSuchBucket" => Fil.ConfigurationError,
    "AccessDenied" => Fil.AccessDeniedError,
    "EntityTooLarge" => Fil.InvalidRequestError,
    "KeyTooLongError" => Fil.InvalidRequestError,
    "PreconditionFailed" => Fil.AlreadyExistsError,
    "ConditionalRequestConflict" => Fil.AlreadyExistsError,
    "BadDigest" => Fil.ChecksumMismatchError,
    "NoSuchUpload" => Fil.ConflictError,
    "SlowDown" => Fil.UnavailableError,
    "OperationAborted" => Fil.UnavailableError,
    "InternalError" => Fil.UnavailableError,
    "ServiceUnavailable" => Fil.UnavailableError
  }

  # The error code decides before the status, because S3-compatible servers don't all send the status AWS does.
  defp error(%{status: status} = response) do
    region = bucket_region(response)
    code = error_code(response.body)

    cond do
      status == 301 or (status == 400 and is_binary(region)) -> %Fil.ConfigurationError{reason: {:wrong_region, region}}
      Map.has_key?(@codes, code) -> struct(Map.fetch!(@codes, code), reason: code)
      true -> struct(status_error(status, code), reason: code || {:http_status, status})
    end
  end

  # A 409 means an `if_exists: :error` write found a file only without another code: S3 sends 409 for other conflicts
  # too.
  defp status_error(404, _code), do: Fil.NotFoundError
  defp status_error(403, _code), do: Fil.AccessDeniedError
  defp status_error(412, _code), do: Fil.AlreadyExistsError
  defp status_error(409, nil), do: Fil.AlreadyExistsError
  defp status_error(status, _code) when status == 429 or status >= 500, do: Fil.UnavailableError
  defp status_error(_status, _code), do: Fil.UnknownError

  defp bucket_region(%{headers: headers}), do: header(headers, "x-amz-bucket-region")

  defp error_code(body) when is_binary(body) do
    case XML.parse(body) do
      {:ok, element} -> XML.text(element, "Code")
      {:error, :invalid_xml} -> nil
    end
  end

  defp error_code(_body), do: nil

  ## ------------------------------------------------------------------
  ## Response values
  ## ------------------------------------------------------------------

  # Req returns headers as a map of lowercase names to lists of values.
  defp header(headers, name) do
    headers
    |> Map.get(name, [])
    |> List.first()
  end

  defp integer(nil), do: nil

  defp integer(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp unquote_etag(nil), do: nil
  defp unquote_etag(etag), do: String.trim(etag, "\"")
end
