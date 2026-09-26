defmodule Fil.Plugin.SignedURL do
  @schema NimbleOptions.new!(
            base_url: [
              type: :string,
              required: true,
              doc: """
              The URL `Fil.Plug` serves the disk root at, e.g. `"http://localhost:4000/storage/uploads"`.
              """
            ],
            secret: [
              type: :string,
              required: true,
              doc: """
              The key URLs are signed with. Use at least 32 random bytes (`mix phx.gen.secret` prints 64). `Fil.Plug`
              reads it from the disk, so it's only configured here.
              """
            ]
          )

  @moduledoc """
  Signs URLs for any disk, served by `Fil.Plug` from your application.

      disk =
        Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage/uploads")
        |> Fil.Plugin.SignedURL.attach(base_url: "http://localhost:4000/storage/uploads", secret: secret)

      Fil.signed_url(disk, "avatars/1.png", method: :put)
      #=> {:ok, "http://localhost:4000/storage/uploads/avatars/1.png?expires=...&signature=..."}

  The plugin answers `Fil.signed_url/3` itself, so the adapter never runs. That's how local and memory disks get signed
  URLs, since they have no backend that could sign them. On an S3 disk, it replaces S3's presigned URLs with URLs to
  your application, which then passes the file through: useful when the bucket shouldn't be reachable from outside,
  but every download and upload runs through your application, and files are read into memory whole.

  A URL is `:base_url`, the path, and two query parameters: `expires` (Unix seconds) and `signature`, an HMAC-SHA256
  over the method, the URL path and the expiry. `expires_in:` is capped at 7 days, as on S3.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  alias Fil.Op
  alias Fil.Support.SignedURL

  @doc "Attaches the plugin to `disk` under the name `:signed_url`."
  @spec attach(Fil.Disk.t(), keyword()) :: Fil.Disk.t()
  def attach(%Fil.Disk{} = disk, opts) do
    Fil.Plugin.attach(disk, :signed_url, &call/3, NimbleOptions.validate!(opts, @schema))
  end

  @doc false
  # The secret `Fil.Plug` verifies requests with, or `nil` for a disk without this plugin.
  @spec secret(Fil.Disk.t()) :: String.t() | nil
  def secret(%Fil.Disk{plugins: plugins}) do
    case List.keyfind(plugins, :signed_url, 0) do
      {:signed_url, _fun, opts} -> Keyword.get(opts, :secret)
      nil -> nil
    end
  end

  defp call(%Op{name: :signed_url} = op, _next, opts) do
    result =
      with {:ok, path} <- Fil.Support.Path.normalize(op.path),
           :ok <- SignedURL.validate(op.options) do
        {:ok, SignedURL.sign(opts[:base_url], opts[:secret], path, op.options)}
      end

    Op.put_result(op, result)
  end

  defp call(op, next, _opts), do: next.(op)
end
