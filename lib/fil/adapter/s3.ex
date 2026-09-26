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
              A base URL for S3-compatible services, e.g. `"http://localhost:8333"`. Setting it turns `:path_style` on.
              """
            ],
            path_style: [
              type: :boolean,
              doc: """
              Put the bucket in the path (`https://host/bucket/key`) instead of the hostname
              (`https://bucket.host/key`). Defaults to `true` when `:endpoint` is set, `false` otherwise.
              """
            ],
            req_options: [
              type: :keyword_list,
              default: [],
              doc: """
              Options for every [Req](https://req.hexdocs.pm) request the disk makes, such as `:receive_timeout`,
              `:connect_options` or a shared `:finch` pool. The adapter always sets `:method`, `:url`, `:headers` and
              `:body`, plus `retry: false` (retrying is up to the caller) and `raw: true` (no decompression and no body
              decoding, so a file reads back exactly as it was written).
              """
            ]
          )

  @moduledoc """
  Amazon S3 and services that implement its API, such as [MinIO](https://github.com/minio/minio),
  [Adobe S3Mock](https://github.com/adobe/S3Mock), [Cloudflare R2](https://developers.cloudflare.com/r2/),
  [Backblaze B2](https://www.backblaze.com/cloud-storage), [Tigris](https://www.tigrisdata.com) and
  [Ceph](https://ceph.io).

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

  ## Checksums

  S3 stores a checksum with an object when the write sends one. With `checksum: :sha256` (or `:sha1`, `:crc32`),
  `Fil.write/4` sends the checksum of the content, S3 rejects the upload if what it received doesn't match, and
  `Fil.stat/3` with the same `:checksum` option returns the stored value. `Fil.read/3` with `verify_checksum: true` asks
  S3 for the stored checksum and compares it with the downloaded content. Objects stored with another algorithm, or with
  none, are read without a check.

  ## Options

  #{NimbleOptions.docs(@schema)}

  ## Operations

  | `Fil` | S3 |
  | --- | --- |
  | `read/3` | GetObject (`x-amz-checksum-mode: ENABLED` for `verify_checksum: true`) |
  | `write/4` | PutObject (`If-None-Match: *` for `if_none_match: :any`, `x-amz-checksum-*` for `checksum:`) |
  | `rm/3` | DeleteObject, which S3 already treats as idempotent |
  | `stat/3` | HeadObject (`x-amz-checksum-mode: ENABLED` for `checksum:`), then a prefix probe so `dir?/1` works |
  | `ls/3` | ListObjectsV2, `delimiter=/` unless recursive, paginated internally |
  | `cp/4` | CopyObject |
  | `rename/4` | CopyObject, then DeleteObject |
  | `rm_rf/3` | ListObjectsV2, then one DeleteObject per key |
  | `signed_url/3` | a presigned GET or PUT URL |

  ## Errors

  | Backend response | `Fil` error |
  | --- | --- |
  | `404` | `:enoent` |
  | `403` | `:eacces` |
  | `409`, `412` | `:precondition_failed` |
  | a `400` with `BadDigest`, or a body that doesn't match its stored checksum | `:checksum_mismatch` |
  | `301`, or a `400` that names another region | `{:wrong_region, region}` |
  | timeouts, connection failures, `5xx` | `%Fil.TransportError{}` |
  | anything else | `{:unexpected_status, status, code}` |
  """

  @behaviour Fil.Adapter

  alias Fil.Stat
  alias Fil.Support.Checksum
  alias Fil.Support.XML
  alias Fil.TransportError

  import Fil.Support.Timestamps
  import Fil.Support.URL

  @max_expires_in 7 * 24 * 60 * 60
  @checksum_mode {"x-amz-checksum-mode", "ENABLED"}

  @derive {Inspect, only: [:bucket, :region, :prefix, :endpoint, :path_style]}
  defstruct [
    :bucket,
    :region,
    :prefix,
    :endpoint,
    :path_style,
    :access_key_id,
    :secret_access_key,
    :session_token,
    :req_options
  ]

  @type t :: %__MODULE__{}

  @impl Fil.Adapter
  def init(opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema),
         {:ok, prefix} <- parse_root(opts[:root]),
         {:ok, endpoint} <- parse_endpoint(opts[:endpoint]) do
      {:ok,
       %__MODULE__{
         bucket: opts[:bucket],
         region: opts[:region],
         prefix: prefix,
         endpoint: endpoint,
         path_style: Keyword.get(opts, :path_style, endpoint != nil),
         access_key_id: opts[:access_key_id],
         secret_access_key: opts[:secret_access_key],
         session_token: opts[:session_token],
         req_options: opts[:req_options]
       }}
    end
  end

  @impl Fil.Adapter
  def read(state, path, opts) do
    verify? = Keyword.get(opts, :verify_checksum, false)
    headers = if verify?, do: [@checksum_mode], else: []

    case request(state, :get, key(state, path), headers: headers) do
      {:ok, %{status: 200, body: body} = response} when verify? -> verify_checksum(body, response.headers)
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Fil.Adapter
  def write(state, path, content, opts) do
    body = IO.iodata_to_binary(content)

    headers =
      opts
      |> content_type_header()
      |> put_if_none_match(opts)
      |> put_checksum(opts, body)

    case request(state, :put, key(state, path), headers: headers, body: body) do
      {:ok, %{status: status}} when status in [200, 201] -> :ok
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Fil.Adapter
  def rm(state, path, _opts) do
    case request(state, :delete, key(state, path)) do
      {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

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
      {:ok, %{status: 200, body: body}} -> copy_result(body)
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

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
  def signed_url(state, path, opts) do
    method = Keyword.get(opts, :method, :get)
    expires_in = Keyword.get(opts, :expires_in, 900)

    cond do
      is_nil(state.access_key_id) or is_nil(state.secret_access_key) ->
        {:error, :missing_credentials}

      method not in [:get, :put] ->
        {:error, {:invalid_option, :method}}

      expires_in > @max_expires_in ->
        {:error, {:invalid_option, :expires_in}}

      true ->
        {:ok, presign(state, key(state, path), method, expires_in)}
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

  defp parse_endpoint(nil), do: {:ok, nil}

  defp parse_endpoint(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, String.trim_trailing(endpoint, "/")}

      _other ->
        {:error, {:invalid_option, {:endpoint, endpoint}}}
    end
  end

  defp content_type_header(opts) do
    case Keyword.get(opts, :content_type) do
      nil -> []
      content_type -> [{"content-type", content_type}]
    end
  end

  defp put_if_none_match(headers, opts) do
    case Keyword.get(opts, :if_none_match) do
      :any -> [{"if-none-match", "*"} | headers]
      nil -> headers
    end
  end

  defp put_checksum(headers, opts, body) do
    case Keyword.get(opts, :checksum) do
      nil -> headers
      algorithm -> [{checksum_header(algorithm), Checksum.digest(algorithm, body)} | headers]
    end
  end

  ## ------------------------------------------------------------------
  ## Checksums
  ## ------------------------------------------------------------------

  defp checksum_header(algorithm), do: "x-amz-checksum-#{algorithm}"

  # `{algorithm, checksum}` if S3 returned a checksum for this algorithm. Checksums of multipart uploads end in
  # "-<parts>" and cover the parts, not the content, so they're skipped (base64 has no "-").
  defp stored_checksum(headers, algorithm) do
    case header(headers, checksum_header(algorithm)) do
      nil -> nil
      checksum -> if !String.contains?(checksum, "-"), do: {algorithm, checksum}
    end
  end

  defp verify_checksum(body, headers) do
    case Enum.find_value(Checksum.algorithms(), &stored_checksum(headers, &1)) do
      nil ->
        {:ok, body}

      {algorithm, checksum} ->
        if Checksum.digest(algorithm, body) == checksum, do: {:ok, body}, else: {:error, :checksum_mismatch}
    end
  end

  ## ------------------------------------------------------------------
  ## Requests
  ## ------------------------------------------------------------------

  defp request(state, method, key, opts \\ []) do
    params = Keyword.get(opts, :params, [])

    options =
      Keyword.merge(state.req_options,
        method: method,
        url: url(state, key, params),
        headers: Keyword.get(opts, :headers, []),
        body: Keyword.get(opts, :body) || "",
        aws_sigv4: aws_sigv4(state),
        retry: false,
        raw: true
      )

    # Every status, 5xx included, comes back as a response and is mapped by the caller. Only a failed connection is an
    # error here.
    case Req.request(options) do
      {:ok, response} -> {:ok, response}
      {:error, %Req.TransportError{reason: reason}} -> {:error, %TransportError{reason: reason}}
      {:error, exception} -> {:error, %TransportError{reason: exception}}
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
  # It has no option for a session token, but it signs any extra query parameters, so the token goes in that way.
  defp presign(state, key, method, expires_in) do
    query = if state.session_token, do: [{"X-Amz-Security-Token", state.session_token}], else: []

    [
      access_key_id: state.access_key_id,
      secret_access_key: state.secret_access_key,
      region: state.region,
      service: :s3,
      datetime: DateTime.utc_now(),
      method: method,
      url: url(state, key, []),
      expires: expires_in,
      query: query
    ]
    |> Req.Utils.aws_sigv4_url()
    |> URI.to_string()
  end

  defp url(state, key, params) do
    base_url(state) <> encode_key(key) <> encode_query(params)
  end

  defp base_url(%__MODULE__{endpoint: nil} = state) do
    if state.path_style do
      "https://s3.#{state.region}.amazonaws.com/#{state.bucket}"
    else
      "https://#{state.bucket}.s3.#{state.region}.amazonaws.com"
    end
  end

  defp base_url(%__MODULE__{endpoint: endpoint} = state) do
    if state.path_style, do: endpoint <> "/" <> state.bucket, else: endpoint
  end

  defp encode_key(""), do: "/"
  defp encode_key(key), do: "/" <> encode_path(key)

  defp copy_source(state, src), do: "/" <> state.bucket <> "/" <> encode_path(key(state, src))

  # CopyObject can report failure inside a 200 response body.
  defp copy_result(body) when is_binary(body) do
    if String.contains?(body, "<Error"), do: {:error, error_code(body)}, else: :ok
  end

  defp copy_result(_body), do: :ok

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
      contents = contents ++ Enum.reject(XML.children(result, "Contents"), &marker?(&1, prefix))
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
      {:error, :invalid_xml} -> {:error, %TransportError{reason: :invalid_xml}}
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
        {:error, :enoent}
      else
        {:ok, %Stat{type: :directory}}
      end
    end
  end

  ## ------------------------------------------------------------------
  ## Errors
  ## ------------------------------------------------------------------

  defp error(%{status: 404}), do: :enoent
  defp error(%{status: 403}), do: :eacces
  defp error(%{status: status}) when status in [409, 412], do: :precondition_failed
  defp error(%{status: 301} = response), do: {:wrong_region, bucket_region(response)}

  defp error(%{status: 400} = response) do
    case {bucket_region(response), error_code(response.body)} do
      {nil, "BadDigest"} -> :checksum_mismatch
      {nil, code} -> {:unexpected_status, 400, code}
      {region, _code} -> {:wrong_region, region}
    end
  end

  defp error(%{status: status}) when status >= 500 do
    %TransportError{reason: {:http_status, status}}
  end

  defp error(%{status: status, body: body}), do: {:unexpected_status, status, error_code(body)}

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
