defmodule Fil.Adapter.AzureBlob.Client do
  @moduledoc false

  # How `Fil.Adapter.AzureBlob` talks to Blob Storage: URLs, requests signed with Shared Key or carrying a SAS token,
  # SAS URLs, the checksum `Fil` stores as metadata, and the mapping of Azure's responses to `Fil` errors.

  alias Fil.Adapter.AzureBlob
  alias Fil.Adapter.AzureBlob.Signing
  alias Fil.Support.Checksum
  alias Fil.Support.ObjectStore
  alias Fil.Support.Timestamps
  alias Fil.Support.URL

  # The REST API version of every request and SAS. Azurite takes it too.
  @version "2025-01-05"

  @doc "Sends a request for `key`, `\"\"` for the container. `opts` has `:params`, `:headers`, `:body` and `:into`."
  @spec request(AzureBlob.t(), atom(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Fil.UnavailableError.t()}
  def request(state, method, key, opts \\ []) do
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

    ObjectStore.request(options)
  end

  @doc "Sends a PUT that answers `201 Created`, such as Put Blob, Put Block or Put Block List."
  @spec put(AzureBlob.t(), String.t(), [header], iodata() | Enumerable.t(), [{String.t(), String.t()}]) ::
          :ok | {:error, Exception.t()}
        when header: {String.t(), String.t()}
  def put(state, key, headers, body, params \\ []) do
    case request(state, :put, key, params: params, headers: headers, body: body) do
      {:ok, %{status: 201}} -> :ok
      {:ok, response} -> {:error, error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_headers(state, method, url, params, headers) do
    date =
      DateTime.utc_now()
      |> Timestamps.format_http_date()

    [{"x-ms-version", @version}, {"x-ms-date", date} | headers]
    |> authorize(state, method, url, params)
  end

  # Signed with the account key (Shared Key). A disk with a SAS token or without credentials sends no signature.
  defp authorize(headers, %AzureBlob{account_key: nil}, _method, _url, _params), do: headers

  defp authorize(headers, state, method, url, params) do
    %URI{path: path} = URI.parse(url)

    [
      {"authorization", Signing.shared_key(state.account, state.account_key, method, path, params, headers)}
      | headers
    ]
  end

  @doc "`:ok` if the disk can sign a URL with these options: it needs the account key, and a SAS can't sign `query:`."
  @spec check_signing(AzureBlob.t(), keyword()) :: :ok | {:error, Fil.UnsupportedError.t()}
  def check_signing(%AzureBlob{account_key: nil}, _opts),
    do: {:error, %Fil.UnsupportedError{reason: :missing_credentials}}

  def check_signing(_state, opts) do
    if Keyword.get(opts, :query, []) == [], do: :ok, else: {:error, %Fil.UnsupportedError{reason: :unsigned_query}}
  end

  @doc """
  A SAS URL for `path` with the permissions and the disposition in `fields`, and when it expires. A URL for `http:`
  (Azurite) can't require HTTPS.
  """
  @spec sas_url(AzureBlob.t(), String.t(), map(), keyword()) :: {String.t(), DateTime.t()}
  def sas_url(state, path, fields, opts) do
    base_url = public_base_url(state)
    key = ObjectStore.key(state, path)
    protocol = if String.starts_with?(base_url, "https:"), do: "https"

    expires =
      :second
      |> DateTime.utc_now()
      |> DateTime.add(Keyword.get(opts, :expires_in, 900))

    fields = Map.merge(fields, %{expires: expires, version: @version, protocol: protocol})
    query = Signing.service_sas(state.account, state.account_key, state.container, key, fields)

    {blob_url(base_url, key, query), expires}
  end

  @doc "The container URL clients get: at the public endpoint, while requests the disk makes itself use `:endpoint`."
  @spec public_base_url(AzureBlob.t()) :: String.t()
  def public_base_url(state), do: container_url(state.public_endpoint || state.endpoint, state)

  defp container_url(endpoint, state), do: endpoint <> "/" <> URL.encode(state.container)

  @doc "The URL of `key` in the container at `container_url`, `\"\"` for the container itself."
  @spec blob_url(String.t(), String.t(), [{term(), term()}]) :: String.t()
  def blob_url(container_url, "", params), do: container_url <> URL.encode_query(params)
  def blob_url(container_url, key, params), do: container_url <> "/" <> URL.encode_path(key) <> URL.encode_query(params)

  @doc """
  The `x-ms-copy-source` of a copy from `src`. Copy Blob takes the source as a URL. Within the account, Shared Key
  authorizes it. With a SAS token, the source carries the token.
  """
  @spec copy_source(AzureBlob.t(), String.t()) :: String.t()
  def copy_source(state, src) do
    state.endpoint
    |> container_url(state)
    |> blob_url(ObjectStore.key(state, src), state.sas_token || [])
  end

  @doc "The `content-length` header of `content`."
  @spec length_header(iodata()) :: {String.t(), String.t()}
  def length_header(content) do
    length =
      content
      |> IO.iodata_length()
      |> Integer.to_string()

    {"content-length", length}
  end

  @doc "The header `name` for `content_type:`."
  @spec content_type_header(String.t(), keyword()) :: [{String.t(), String.t()}]
  def content_type_header(name, opts) do
    case Keyword.get(opts, :content_type) do
      nil -> []
      content_type -> [{name, content_type}]
    end
  end

  ## ------------------------------------------------------------------
  ## Checksums
  ## ------------------------------------------------------------------

  @doc "The metadata header `Fil` stores a checksum of `algorithm` in."
  @spec metadata_header(Checksum.algorithm()) :: String.t()
  def metadata_header(algorithm), do: "x-ms-meta-fil_#{algorithm}"

  @doc "`{algorithm, checksum}` if the blob has a checksum of this algorithm."
  @spec stored_checksum(map(), Checksum.algorithm()) :: {Checksum.algorithm(), String.t()} | nil
  def stored_checksum(headers, algorithm) do
    case ObjectStore.header(headers, metadata_header(algorithm)) do
      nil -> nil
      checksum -> {algorithm, checksum}
    end
  end

  @doc "The checksum stored with the blob, for the first algorithm that has one."
  @spec find_checksum(map()) :: {Checksum.algorithm(), String.t()} | nil
  def find_checksum(headers), do: Enum.find_value(Checksum.algorithms(), &stored_checksum(headers, &1))

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

  @doc "The `Fil` error of an Azure response. Azure sends the code in a header, so a response to a HEAD has one too."
  @spec error(Req.Response.t()) :: Exception.t()
  def error(%{status: status} = response) do
    code = ObjectStore.header(response.headers, "x-ms-error-code") || ObjectStore.error_code(response.body)

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
