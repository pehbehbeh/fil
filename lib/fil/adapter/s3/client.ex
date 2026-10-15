defmodule Fil.Adapter.S3.Client do
  @moduledoc false

  # How `Fil.Adapter.S3` talks to S3: URLs, requests signed with SigV4, presigned URLs, and the mapping of S3's
  # responses to `Fil` errors. Req does the signing itself, so this module only decides what goes into a signature.

  alias Fil.Adapter.S3
  alias Fil.Support.ObjectStore
  alias Fil.Support.URL
  alias Fil.Support.XML

  @doc "Sends a request for `key`, `\"\"` for the bucket. `opts` has `:params`, `:headers`, `:body` and `:into`."
  @spec request(S3.t(), atom(), String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, Fil.UnavailableError.t()}
  def request(state, method, key, opts \\ []) do
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

    ObjectStore.request(options)
  end

  # Req signs every request with SigV4 when the disk has credentials. Without them, requests go out unsigned, which is
  # how a public bucket is read.
  defp aws_sigv4(%S3{access_key_id: nil}), do: nil
  defp aws_sigv4(%S3{secret_access_key: nil}), do: nil

  defp aws_sigv4(state) do
    [
      access_key_id: state.access_key_id,
      secret_access_key: state.secret_access_key,
      token: state.session_token,
      region: state.region,
      service: :s3
    ]
  end

  @doc "`:ok` if the disk can presign URLs."
  @spec check_credentials(S3.t()) :: :ok | {:error, Fil.UnsupportedError.t()}
  def check_credentials(%S3{access_key_id: id, secret_access_key: secret}) when is_nil(id) or is_nil(secret),
    do: {:error, %Fil.UnsupportedError{reason: :missing_credentials}}

  def check_credentials(_state), do: :ok

  @doc """
  Presigns `url` for `method`, signed at `now`.

  `Req.Utils.aws_sigv4_url/1` is private Req API, and this is its only caller. Req isn't pinned for it: if a release
  drops it, presigning crashes. It has no option for a
  session token, but it signs any extra query parameters, so the token goes in that way, and so do the
  `response-content-disposition` S3 answers the download with and the caller's `:query`. An upload's `:content_type`,
  `:size` and `if_exists: :error` become signed headers (`upload_headers/1`), which the client has to send as they
  are.
  """
  @spec presign(S3.t(), String.t(), :get | :put, keyword(), DateTime.t()) :: String.t()
  def presign(state, url, method, opts, now \\ DateTime.utc_now()) do
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
      datetime: now,
      method: method,
      url: url,
      expires: Keyword.get(opts, :expires_in, 900),
      headers: upload_headers(opts),
      query: query
    ]
    |> Req.Utils.aws_sigv4_url()
    |> URI.to_string()
  end

  @doc "The headers a presigned upload signs: `content-type`, `content-length` and `if-none-match`."
  @spec upload_headers(keyword()) :: [{String.t(), String.t()}]
  def upload_headers(opts) do
    headers =
      for {name, key} <- [{"content-type", :content_type}, {"content-length", :size}],
          value = opts[key],
          value != nil,
          do: {name, to_string(value)}

    ObjectStore.put_if_exists(headers, opts)
  end

  @doc "The URL of `key` that clients get, at the public endpoint."
  @spec public_object_url(S3.t(), String.t()) :: String.t()
  def public_object_url(state, key), do: object_url(state, key, [], public_base_url(state))

  @doc "The `content-type` header for `content_type:`."
  @spec content_type_header(keyword()) :: [{String.t(), String.t()}]
  def content_type_header(opts) do
    case Keyword.get(opts, :content_type) do
      nil -> []
      content_type -> [{"content-type", content_type}]
    end
  end

  @doc "The URL of `key`, at `base_url` or the endpoint the disk sends its own requests to."
  @spec object_url(S3.t(), String.t(), [{term(), term()}], String.t() | nil) :: String.t()
  def object_url(state, key, params, base_url \\ nil) do
    (base_url || base_url(state, state.endpoint)) <> encode_key(key) <> URL.encode_query(params)
  end

  @doc "The bucket URL clients get: at the public endpoint, while requests the disk makes itself use `:endpoint`."
  @spec public_base_url(S3.t()) :: String.t()
  def public_base_url(state), do: base_url(state, state.public_endpoint || state.endpoint)

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
  defp encode_key(key), do: "/" <> URL.encode_path(key)

  @doc "The `x-amz-copy-source` of a copy from `src`."
  @spec copy_source(S3.t(), String.t()) :: String.t()
  def copy_source(state, src) do
    path =
      state
      |> ObjectStore.key(src)
      |> URL.encode_path()

    "/" <> state.bucket <> "/" <> path
  end

  @doc """
  The result of a `200` that may hold an error. CopyObject and CompleteMultipartUpload can report failure inside a
  `200`, after the status has gone out. Only an `<Error>` document is a failure: once the object may have been written,
  a body that can't be read doesn't turn it into an error.
  """
  @spec xml_result(Req.Response.t()) :: :ok | {:error, Exception.t()}
  def xml_result(response) do
    case XML.parse(response.body) do
      {:ok, {"Error", _attributes, _children}} -> {:error, error(response)}
      _result_or_unreadable -> :ok
    end
  end

  ## ------------------------------------------------------------------
  ## Errors
  ## ------------------------------------------------------------------

  @codes %{
    "NoSuchKey" => Fil.NotFoundError,
    "NoSuchBucket" => Fil.ConfigurationError,
    "AccessDenied" => Fil.AccessDeniedError,
    "InvalidRequest" => Fil.InvalidRequestError,
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

  @doc """
  The `Fil` error of an S3 response. The error code decides before the status, because S3-compatible servers don't all
  send the status AWS does.
  """
  @spec error(Req.Response.t()) :: Exception.t()
  def error(%{status: status} = response) do
    region = bucket_region(response)
    code = ObjectStore.error_code(response.body)

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

  defp bucket_region(%{headers: headers}), do: ObjectStore.header(headers, "x-amz-bucket-region")
end
