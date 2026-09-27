defmodule Fil.Plugin.URL do
  @schema NimbleOptions.new!(
            base_url: [
              type: :string,
              required: true,
              doc: """
              The URL the disk root is served at, e.g. `"http://localhost:4000/storage/uploads"`: `Fil.Plug` in your
              application, or a CDN in front of the disk.
              """
            ],
            secret: [
              type: :string,
              doc: """
              The key URLs are signed with. Use at least 32 random bytes (`mix phx.gen.secret` prints 64). `Fil.Plug`
              reads it from the disk, so it's only configured here. Without it, the plugin only builds public URLs, and
              `Fil.signed_url/3` goes to the adapter.
              """
            ]
          )

  @moduledoc """
  Builds URLs for any disk, served by `Fil.Plug` from your application.

      disk =
        Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage/uploads")
        |> Fil.Plugin.URL.attach(base_url: "http://localhost:4000/storage/uploads", secret: secret)

      Fil.url(disk, "avatars/1.png")
      #=> {:ok, "http://localhost:4000/storage/uploads/avatars/1.png"}

      Fil.signed_url(disk, "avatars/1.png", method: :put)
      #=> {:ok, "http://localhost:4000/storage/uploads/avatars/1.png?expires=...&signature=..."}

  The plugin answers `Fil.url/2` and, with a `:secret`, `Fil.signed_url/3` itself, so the adapter never runs. That's how
  local and memory disks get URLs, since there is no storage service that could build them. A public URL only works
  where `Fil.Plug` serves the disk with `public: true` (or something else serves the files at `:base_url`).

  On an S3 disk, `:base_url` replaces the bucket URL in `Fil.url/2`, for a CDN in front of the bucket. Without a
  `:secret`, S3 still presigns `Fil.signed_url/3` itself. With one, signed URLs go to your application, which then
  passes the file through: useful when the bucket shouldn't be reachable from outside, but every download and upload
  runs through your application, and files are read into memory whole.

  A signed URL is `:base_url`, the path, and the query parameters `expires` (Unix seconds), `disposition` (the
  `content-disposition` header value, only with `disposition:`) and `signature`, an HMAC-SHA256 over the method, the URL
  path, the expiry and the disposition. `expires_in:` is capped at 7 days, as on S3, so a URL that works on one disk
  works on every disk.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  alias Fil.Op
  alias Fil.Support.URL

  @doc """
  Attaches the plugin to `disk` under the name `Fil.Plugin.URL`.

  The same as `plugins: [{Fil.Plugin.URL, :call, opts}]` in `Fil.disk/1`, except that the options are validated here
  instead of on the first URL.
  """
  @spec attach(Fil.Disk.t(), keyword()) :: Fil.Disk.t()
  def attach(%Fil.Disk{} = disk, opts) do
    Fil.attach(disk, __MODULE__, {__MODULE__, :call}, NimbleOptions.validate!(opts, @schema))
  end

  @doc false
  # The secret `Fil.Plug` verifies requests with, or `nil` for a disk that doesn't sign URLs with this plugin.
  @spec secret(Fil.Disk.t()) :: String.t() | nil
  def secret(%Fil.Disk{plugins: plugins}) do
    case List.keyfind(plugins, __MODULE__, 0) do
      {__MODULE__, _callback, opts} -> Keyword.get(opts, :secret)
      nil -> nil
    end
  end

  @doc false
  # Builds a signed URL for `path` under `base_url`. The URL path is signed exactly as it's sent, so `Fil.Plug` can
  # verify `conn.request_path` without knowing where it's mounted or which disk root the URL was built for.
  @spec sign(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def sign(base_url, secret, path, opts) do
    method = Keyword.get(opts, :method, :get)
    expires = System.os_time(:second) + Keyword.get(opts, :expires_in, 900)
    base_url = String.trim_trailing(base_url, "/")
    url_path = (URI.parse(base_url).path || "") <> "/" <> URL.encode_path(path)
    disposition = Keyword.get(opts, :disposition)
    signature = signature(secret, method, url_path, expires, disposition)

    query =
      Enum.reject([{"expires", expires}, {"disposition", disposition}, {"signature", signature}], &is_nil(elem(&1, 1)))

    base_url <> "/" <> URL.encode_path(path) <> URL.encode_query(query)
  end

  @doc false
  # Verifies a request against a signed URL: the method, the request path as it was received and the query parameters.
  @spec verify(String.t(), :get | :put, String.t(), map()) :: :ok | {:error, :expired | :invalid_signature}
  def verify(secret, method, request_path, params) do
    with {:ok, expires} <- expires(params),
         {:ok, signature} when is_binary(signature) <- Map.fetch(params, "signature"),
         disposition when is_binary(disposition) or is_nil(disposition) <- params["disposition"],
         expected = signature(secret, method, request_path, expires, disposition),
         true <- :crypto.hash_equals(expected, signature) do
      if expires >= System.os_time(:second), do: :ok, else: {:error, :expired}
    else
      _invalid -> {:error, :invalid_signature}
    end
  rescue
    # `:crypto.hash_equals/2` raises on binaries of different sizes.
    ArgumentError -> {:error, :invalid_signature}
  end

  @doc false
  @spec call(Op.t(), (Op.t() -> Op.t()), keyword()) :: Op.t()
  def call(%Op{name: :url} = op, _next, opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    result =
      with {:ok, path} <- normalize(op.path) do
        {:ok, String.trim_trailing(opts[:base_url], "/") <> "/" <> URL.encode_path(path)}
      end

    Op.put_result(op, result)
  end

  def call(%Op{name: :signed_url} = op, next, opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    case opts[:secret] do
      nil -> next.(op)
      secret -> Op.put_result(op, signed_url(op, opts[:base_url], secret))
    end
  end

  def call(op, next, _opts), do: next.(op)

  # `Fil` has validated `:expires_in` (at most 7 days).
  defp signed_url(op, base_url, secret) do
    with {:ok, path} <- normalize(op.path), do: {:ok, sign(base_url, secret, path, op.options)}
  end

  # An earlier plugin may have rewritten the path, so it's checked again, like `Fil` does before the adapter.
  defp normalize(path) do
    with {:error, :ebadpath} <- Fil.Support.Path.normalize(path) do
      {:error, %Fil.InvalidRequestError{reason: :ebadpath}}
    end
  end

  defp expires(%{"expires" => expires}) when is_binary(expires) do
    case Integer.parse(expires) do
      {expires, ""} -> {:ok, expires}
      _other -> :error
    end
  end

  defp expires(_params), do: :error

  # URLs without a disposition sign the same payload as before it existed, so they stay valid.
  defp signature(secret, method, url_path, expires, disposition) do
    payload = Enum.join([http_method(method), url_path, expires | List.wrap(disposition)], "\n")

    :hmac
    |> :crypto.mac(:sha256, secret, payload)
    |> Base.url_encode64(padding: false)
  end

  # The method as HTTP sends it, e.g. `"GET"`.
  defp http_method(method) do
    method
    |> Atom.to_string()
    |> String.upcase()
  end
end
