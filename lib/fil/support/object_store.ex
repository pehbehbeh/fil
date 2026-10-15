defmodule Fil.Support.ObjectStore do
  @moduledoc false

  # What the cloud adapters (`Fil.Adapter.S3`, `Fil.Adapter.AzureBlob`) have in common, because their storages work the
  # same way: files are objects with names in one flat namespace, directories are name prefixes, and requests are HTTP
  # through Req. Signing, error codes, uploads in parts and checksums differ, and stay in the adapters.
  #
  # The name functions take the adapter state, whose `:prefix` is the root as a name prefix: `""` for the bucket or
  # container root, otherwise the root with a trailing slash. Paths are relative to the disk root, names to the bucket.

  alias Fil.Stat
  alias Fil.Support.XML

  ## ------------------------------------------------------------------
  ## Options
  ## ------------------------------------------------------------------

  @doc """
  The `:root` option as a name prefix.

      iex> Fil.Support.ObjectStore.parse_root("/uploads/2026/")
      {:ok, "uploads/2026/"}
      iex> Fil.Support.ObjectStore.parse_root(".")
      {:ok, ""}

  """
  @spec parse_root(String.t()) :: {:ok, String.t()} | {:error, {:invalid_option, {:root, String.t()}}}
  def parse_root(root) do
    case Fil.Support.Path.normalize(root) do
      {:ok, "."} -> {:ok, ""}
      {:ok, path} -> {:ok, path <> "/"}
      {:error, :ebadpath} -> {:error, {:invalid_option, {:root, root}}}
    end
  end

  @doc "An endpoint option, an http(s) URL with a host, without its trailing slash. `nil` stays `nil`."
  @spec parse_endpoint(atom(), String.t() | nil) :: {:ok, String.t() | nil} | {:error, {:invalid_option, term()}}
  def parse_endpoint(_name, nil), do: {:ok, nil}

  def parse_endpoint(name, endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, String.trim_trailing(endpoint, "/")}

      _other ->
        {:error, {:invalid_option, {name, endpoint}}}
    end
  end

  ## ------------------------------------------------------------------
  ## Names and prefixes
  ## ------------------------------------------------------------------

  @doc "The name of `path`."
  @spec key(%{prefix: String.t()}, String.t()) :: String.t()
  def key(%{prefix: prefix}, "."), do: prefix
  def key(%{prefix: prefix}, path), do: prefix <> path

  @doc "The prefix that lists the directory `path`: its name and a slash."
  @spec list_prefix(%{prefix: String.t()}, String.t()) :: String.t()
  def list_prefix(%{prefix: prefix}, "."), do: prefix
  def list_prefix(%{prefix: prefix}, path), do: prefix <> path <> "/"

  @doc "The prefix of everything `Fil.rm_rf/2` of `path` removes, `under_prefix?/2` included."
  @spec base_prefix(%{prefix: String.t()}, String.t()) :: String.t()
  def base_prefix(%{prefix: prefix}, "."), do: prefix
  def base_prefix(%{prefix: prefix}, path), do: prefix <> path

  @doc "The path of a name."
  @spec relative(%{prefix: String.t()}, String.t()) :: String.t()
  def relative(%{prefix: prefix}, name), do: String.replace_prefix(name, prefix, "")

  @doc """
  Whether a path is `prefix` or under it, so `reports` takes `reports/q3.txt` but not `reports.txt`.

      iex> Fil.Support.ObjectStore.under_prefix?("reports/q3.txt", "reports")
      true
      iex> Fil.Support.ObjectStore.under_prefix?("reports.txt", "reports")
      false

  """
  @spec under_prefix?(String.t(), String.t()) :: boolean()
  def under_prefix?(_path, "."), do: true
  def under_prefix?(path, prefix), do: path == prefix or String.starts_with?(path, prefix <> "/")

  ## ------------------------------------------------------------------
  ## Listings
  ## ------------------------------------------------------------------

  @doc """
  The entries of a listing of `prefix` with the directories it implies. With the delimiter `"/"`, the storage lists the
  directories itself, and an entry listed both as an object and as a prefix (a directory of a hierarchical namespace)
  is kept once. Without one, it lists only objects, so a subtree's directories are the parents of the paths. Entries
  the adapter listed as directories are directory markers, such as an empty object whose name ends in `/`.
  """
  @spec subtree([{String.t(), Stat.t()}], String.t(), String.t() | nil) :: [{String.t(), Stat.t()}]
  def subtree(listed, _prefix, "/"), do: Enum.uniq_by(listed, &elem(&1, 0))

  def subtree(listed, prefix, nil) do
    {markers, files} = Enum.split_with(listed, fn {_path, stat} -> stat.type == :directory end)
    marker_paths = Enum.map(markers, &elem(&1, 0))
    file_paths = Enum.map(files, &elem(&1, 0))

    directories =
      (file_paths ++ marker_paths)
      |> Fil.Support.Path.parents(prefix)
      |> Kernel.++(marker_paths)
      |> Enum.uniq()
      |> Enum.map(&{&1, %Stat{type: :directory}})

    files ++ directories
  end

  @doc "Removes each path with `rm`, and returns how many it removed, or the first error."
  @spec delete_each([String.t()], (String.t() -> :ok | {:error, term()})) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_each(paths, rm) do
    Enum.reduce_while(paths, {:ok, 0}, fn path, {:ok, count} ->
      case rm.(path) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  ## ------------------------------------------------------------------
  ## Requests and responses
  ## ------------------------------------------------------------------

  @doc """
  Sends a request with Req. Every status, 5xx included, comes back as a response, which the adapter maps. Only a failed
  connection is an error here.
  """
  @spec request(keyword()) :: {:ok, Req.Response.t()} | {:error, Fil.UnavailableError.t()}
  def request(options) do
    case Req.request(options) do
      {:ok, response} -> {:ok, response}
      {:error, %Req.TransportError{reason: reason}} -> {:error, %Fil.UnavailableError{reason: reason}}
      {:error, exception} -> {:error, %Fil.UnavailableError{reason: exception}}
    end
  end

  @doc """
  Runs `fun` again after `delay` milliseconds if it fails with a `Fil.UnavailableError` (throttling included), once. For
  the parts of an upload, which nobody sees before the upload completes.
  """
  @spec retry_unavailable((-> result), non_neg_integer()) :: result when result: term()
  def retry_unavailable(fun, delay) do
    case fun.() do
      {:error, %Fil.UnavailableError{}} ->
        Process.sleep(delay)
        fun.()

      result ->
        result
    end
  end

  @doc """
  The step of an upload in parts for each full part (see `Fil.Support.Parts.reduce/4`): runs `upload` unless the part
  would be the last of `max` parts, which only the content's last part may be. A failure halts the stream instead of
  raising, because a raised `Fil` error would count as the source's.
  """
  @spec next_part(non_neg_integer(), pos_integer(), (-> {:ok, acc} | {:error, term()})) ::
          {:cont, acc} | {:halt, {:error, term()}}
        when acc: term()
  def next_part(count, max, upload) do
    result =
      if count + 1 >= max,
        do: {:error, %Fil.InvalidRequestError{reason: :too_many_parts}},
        else: upload.()

    case result do
      {:ok, acc} -> {:cont, acc}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  @doc "Adds `if-none-match: *`, which both storages take as \"create only\", for `if_exists: :error`."
  @spec put_if_exists([{String.t(), String.t()}], keyword()) :: [{String.t(), String.t()}]
  def put_if_exists(headers, opts) do
    case Keyword.get(opts, :if_exists, :overwrite) do
      :overwrite -> headers
      :error -> [{"if-none-match", "*"} | headers]
    end
  end

  @doc "A missing file is fine for an idempotent delete, a missing bucket or container isn't."
  @spec missing_is_ok(Exception.t()) :: :ok | {:error, Exception.t()}
  def missing_is_ok(%Fil.NotFoundError{}), do: :ok
  def missing_is_ok(error), do: {:error, error}

  @doc "`If-None-Match` is about the destination of a copy, so a copy that found it already there fails with its path."
  @spec existing_dest(term(), String.t()) :: term()
  def existing_dest({:error, %Fil.AlreadyExistsError{} = error}, dest), do: {:error, %{error | path: dest}}
  def existing_dest(result, _dest), do: result

  @doc "Parses an XML response body, or fails with a `Fil.UnavailableError`."
  @spec parse_xml(term()) :: {:ok, XML.element()} | {:error, Fil.UnavailableError.t()}
  def parse_xml(body) do
    case XML.parse(body) do
      {:ok, element} -> {:ok, element}
      {:error, :invalid_xml} -> {:error, %Fil.UnavailableError{reason: :invalid_xml}}
    end
  end

  @doc "The `<Code>` of an XML error body, or `nil`."
  @spec error_code(term()) :: String.t() | nil
  def error_code(body) do
    case XML.parse(body) do
      {:ok, element} -> XML.text(element, "Code")
      {:error, :invalid_xml} -> nil
    end
  end

  @doc "The first value of a header. Req returns headers as a map of lowercase names to lists of values."
  @spec header(%{optional(String.t()) => [String.t()]}, String.t()) :: String.t() | nil
  def header(headers, name) do
    headers
    |> Map.get(name, [])
    |> List.first()
  end

  @doc "The `content-length` of a response, or `nil`."
  @spec content_length(Req.Response.t()) :: non_neg_integer() | nil
  def content_length(%{headers: headers}) do
    headers
    |> header("content-length")
    |> integer()
  end

  @doc """
  The integer a header or an XML element holds, or `nil`.

      iex> Fil.Support.ObjectStore.integer("42")
      42
      iex> Fil.Support.ObjectStore.integer(nil)
      nil

  """
  @spec integer(String.t() | nil) :: integer() | nil
  def integer(nil), do: nil

  def integer(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  @doc ~S'An ETag without its quotes: `"\"abc\""` becomes `"abc"`.'
  @spec unquote_etag(String.t() | nil) :: String.t() | nil
  def unquote_etag(nil), do: nil
  def unquote_etag(etag), do: String.trim(etag, "\"")
end
