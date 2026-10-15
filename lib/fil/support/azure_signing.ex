defmodule Fil.Support.AzureSigning do
  @moduledoc false

  # Azure Storage's two signatures, as `Fil.Adapter.AzureBlob` needs them: Shared Key for the requests the disk sends
  # (https://learn.microsoft.com/rest/api/storageservices/authorize-with-shared-key) and the service SAS for the URLs
  # it hands out (https://learn.microsoft.com/rest/api/storageservices/create-service-sas). Both are an HMAC-SHA256 of
  # a string built from the request with the account key, so they're pure functions of their arguments.

  # The standard headers in the order the string to sign lists them, before the `x-ms-` headers.
  @standard_headers ~w(content-encoding content-language content-length content-md5 content-type date if-modified-since
                       if-match if-none-match if-unmodified-since range)

  @doc """
  The `authorization` header of a request: `method`, the encoded URL path as sent (with the account in it for a
  path-style endpoint such as Azurite's), the decoded query parameters and the request headers with lowercase names.
  A `content-length` of `"0"` is signed as empty, as Azure expects.

      iex> headers = [{"x-ms-date", "Thu, 15 Oct 2026 12:00:00 GMT"}, {"x-ms-version", "2025-01-05"}]
      iex> key = Base.decode64!("a2V5")
      iex> Fil.Support.AzureSigning.shared_key("acct", key, :get, "/c/a.txt", [], headers)
      "SharedKey acct:6e+X/GJfDkP0dPAMJLEwAaUdpDH9oukVJCiKtRH30nQ="

  """
  @spec shared_key(String.t(), binary(), atom(), String.t(), [{String.t(), String.t()}], [{String.t(), String.t()}]) ::
          String.t()
  def shared_key(account, key, method, path, params, headers) do
    headers = Map.new(headers)

    standard =
      Enum.map(@standard_headers, fn
        "content-length" -> if headers["content-length"] in [nil, "0"], do: "", else: headers["content-length"]
        name -> Map.get(headers, name, "")
      end)

    canonical_headers =
      headers
      |> Enum.filter(fn {name, _value} -> String.starts_with?(name, "x-ms-") end)
      |> Enum.sort()
      |> Enum.map(fn {name, value} -> name <> ":" <> String.trim(value) <> "\n" end)

    string_to_sign =
      IO.iodata_to_binary([
        Enum.join([verb(method) | standard], "\n"),
        "\n",
        canonical_headers,
        canonical_resource(account, path, params)
      ])

    "SharedKey " <> account <> ":" <> sign(key, string_to_sign)
  end

  # `/account/path`, then each query parameter on a line of its own, sorted by its lowercase name. Repeated names are
  # joined with commas, their values sorted.
  defp canonical_resource(account, path, params) do
    query =
      params
      |> Enum.group_by(fn {name, _value} -> String.downcase(name) end, fn {_name, value} -> to_string(value) end)
      |> Enum.sort()
      |> Enum.map(fn {name, values} ->
        [
          "\n",
          name,
          ":",
          values
          |> Enum.sort()
          |> Enum.join(",")
        ]
      end)

    ["/", account, path, query]
  end

  @doc """
  The query parameters of a service SAS for one blob, in the format of `version` 2020-12-06 and later. `fields` has
  `:permissions` (such as `"r"` or `"cw"`), `:expires` (a `DateTime`), `:version` and, if they're set, `:protocol`
  (`"https"`) and `:disposition` (the `content-disposition` Azure sends with the download). `blob` is the blob's name
  in the container, not encoded.
  """
  @spec service_sas(String.t(), binary(), String.t(), String.t(), map()) :: [{String.t(), String.t()}]
  def service_sas(account, key, container, blob, fields) do
    expires = iso8601(fields.expires)
    protocol = Map.get(fields, :protocol)
    disposition = Map.get(fields, :disposition)

    string_to_sign =
      Enum.join(
        [
          fields.permissions,
          "",
          expires,
          "/blob/" <> account <> "/" <> container <> "/" <> blob,
          "",
          "",
          protocol || "",
          fields.version,
          "b",
          "",
          "",
          "",
          disposition || "",
          "",
          "",
          ""
        ],
        "\n"
      )

    Enum.reject(
      [
        {"sv", fields.version},
        {"spr", protocol},
        {"se", expires},
        {"sr", "b"},
        {"sp", fields.permissions},
        {"rscd", disposition},
        {"sig", sign(key, string_to_sign)}
      ],
      fn {_name, value} -> is_nil(value) end
    )
  end

  @doc ~S'Formats a `DateTime` the way the `x-ms-date` header has it, e.g. `"Thu, 15 Oct 2026 12:00:00 GMT"`.'
  @spec http_date(DateTime.t()) :: String.t()
  def http_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")

  defp iso8601(datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp sign(key, string) do
    :hmac
    |> :crypto.mac(:sha256, key, string)
    |> Base.encode64()
  end

  defp verb(method) do
    method
    |> Atom.to_string()
    |> String.upcase()
  end
end
