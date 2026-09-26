defmodule Fil.Support.SignedURL do
  @moduledoc false

  # Signed URLs for disks that don't have a backend to sign them (Local, Memory). `Fil.Plug` verifies them.
  #
  # A URL is the disk's base URL, the encoded path, and two query parameters: `expires` (Unix seconds) and `signature`,
  # an HMAC-SHA256 over the method, the URL path and the expiry. The URL path is signed exactly as it's sent, so the
  # plug can verify `conn.request_path` without knowing where it's mounted or which disk root the URL was built for.

  alias Fil.Support.URL

  # The same cap as S3's presigned URLs, so a URL that works on one disk works on every disk.
  @max_expires_in 7 * 24 * 60 * 60

  @doc "Checks the options every adapter applies to `signed_url`."
  @spec validate(keyword()) :: :ok | {:error, term()}
  def validate(opts) do
    if Keyword.get(opts, :expires_in, 900) > @max_expires_in do
      {:error, {:invalid_option, :expires_in}}
    else
      :ok
    end
  end

  @doc "Builds a signed URL for `path` under `base_url`."
  @spec sign(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def sign(base_url, secret, path, opts) do
    method = Keyword.get(opts, :method, :get)
    expires = System.os_time(:second) + Keyword.get(opts, :expires_in, 900)
    base_url = String.trim_trailing(base_url, "/")
    url_path = (URI.parse(base_url).path || "") <> "/" <> URL.encode_path(path)
    signature = signature(secret, method, url_path, expires)

    base_url <> "/" <> URL.encode_path(path) <> URL.encode_query([{"expires", expires}, {"signature", signature}])
  end

  @doc """
  Verifies a request against a signed URL: the method, the request path as it was received and the query parameters.
  """
  @spec verify(String.t(), :get | :put, String.t(), map()) :: :ok | {:error, :expired | :invalid_signature}
  def verify(secret, method, request_path, params) do
    with {:ok, expires} <- expires(params),
         {:ok, signature} <- Map.fetch(params, "signature"),
         true <- :crypto.hash_equals(signature(secret, method, request_path, expires), signature) do
      if expires >= System.os_time(:second), do: :ok, else: {:error, :expired}
    else
      _invalid -> {:error, :invalid_signature}
    end
  rescue
    # `:crypto.hash_equals/2` raises on binaries of different sizes.
    ArgumentError -> {:error, :invalid_signature}
  end

  defp expires(%{"expires" => expires}) do
    case Integer.parse(expires) do
      {expires, ""} -> {:ok, expires}
      _other -> :error
    end
  end

  defp expires(_params), do: :error

  defp signature(secret, method, url_path, expires) do
    payload = Enum.join([String.upcase(Atom.to_string(method)), url_path, expires], "\n")

    :hmac
    |> :crypto.mac(:sha256, secret, payload)
    |> Base.url_encode64(padding: false)
  end
end
