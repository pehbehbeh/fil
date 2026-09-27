defmodule Fil.Emulator do
  @moduledoc false

  alias Fil.Support.URL
  alias Fil.Support.XML

  # Setup for the local emulators the integration suites run against: a reachability check with an error message that
  # says how to start them, and creating and removing the bucket for a run.
  #
  #     docker compose up -d
  #     mix test.integration

  @emulators %{
    s3: %{name: "RustFS", service: "rustfs", url: "http://127.0.0.1:9000"}
  }

  @s3_access_key_id "filaccesskey"
  @s3_secret_access_key "filsecretkey"
  @s3_region "us-east-1"

  @spec url(atom()) :: String.t()
  def url(kind) do
    System.get_env("FIL_#{String.upcase(to_string(kind))}_ENDPOINT") ||
      @emulators[kind].url
  end

  @spec s3_credentials() :: keyword()
  def s3_credentials do
    [
      access_key_id: System.get_env("FIL_S3_ACCESS_KEY_ID", @s3_access_key_id),
      secret_access_key: System.get_env("FIL_S3_SECRET_ACCESS_KEY", @s3_secret_access_key),
      region: System.get_env("FIL_S3_REGION", @s3_region)
    ]
  end

  @doc "A bucket or container name no other run is using."
  @spec unique_name(String.t()) :: String.t()
  def unique_name(prefix) do
    "#{prefix}-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"
  end

  @doc "Whether the emulator is listening. Gives up after 500 ms instead of waiting for a request timeout."
  @spec reachable?(atom()) :: boolean()
  def reachable?(kind) do
    uri =
      kind
      |> url()
      |> URI.parse()

    host = String.to_charlist(uri.host)

    case :gen_tcp.connect(host, uri.port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @doc "Raises with instructions to start the emulator when it isn't reachable."
  @spec require!(atom()) :: :ok
  def require!(kind) do
    if reachable?(kind) do
      :ok
    else
      %{name: name, service: service} = @emulators[kind]

      raise """
      #{name} is not reachable at #{url(kind)}.

      Start the emulators and run the suite again:

          docker compose up -d #{service}
          mix test.integration
      """
    end
  end

  @doc "Prints, once, which emulators an integration run is missing."
  @spec report() :: :ok
  def report do
    missing = for {kind, emulator} <- @emulators, not reachable?(kind), do: emulator

    if missing != [] do
      # A test helper talking to the developer, not library output.
      # credo:disable-for-next-line Credo.Check.Refactor.IoPuts
      IO.puts([
        "\n",
        IO.ANSI.yellow(),
        "Integration tests were requested, but these emulators are not reachable: ",
        Enum.map_join(missing, ", ", & &1.name),
        "\n",
        "Start them with: docker compose up -d\n",
        IO.ANSI.reset()
      ])
    end

    :ok
  end

  @doc "Whether this run was asked for the integration tests."
  @spec integration_requested?() :: boolean()
  def integration_requested? do
    ExUnit.configuration()
    |> Keyword.get(:include, [])
    |> Enum.any?(&(&1 == :integration or match?({:integration, _value}, &1)))
  end

  ## ------------------------------------------------------------------
  ## Buckets
  ## ------------------------------------------------------------------

  # A bucket we already own answers 409 `BucketAlreadyOwnedByYou` outside us-east-1 and counts as created. Any other
  # 409 fails the setup with its code: `OperationAborted` (the bucket was deleted a moment ago) or `BucketAlreadyExists`
  # (someone else's bucket) would otherwise show up later as a confusing `NoSuchBucket`.
  @spec create_s3_bucket(String.t()) :: :ok | {:error, term()}
  def create_s3_bucket(bucket), do: s3_request(:put, "/" <> bucket, [200, {409, "BucketAlreadyOwnedByYou"}])

  # S3 and RustFS refuse to delete a bucket that isn't empty, so the objects go first. A bucket that doesn't exist
  # counts as deleted, but a 409 (`BucketNotEmpty`) doesn't: it means `Fil.rm_rf/2` left something behind. Multipart
  # uploads a test left behind are aborted too (RustFS 1.0.0 deletes a bucket with uploads, but they cost on AWS).
  @spec delete_s3_bucket(String.t()) :: :ok | {:error, term()}
  def delete_s3_bucket(bucket) do
    disk = Fil.disk([adapter: Fil.Adapter.S3, bucket: bucket, endpoint: url(:s3), path_style: true] ++ s3_credentials())

    case Fil.rm_rf(disk, ".") do
      {:ok, _count} -> abort_s3_uploads_and_delete(bucket)
      {:error, %Fil.ConfigurationError{reason: "NoSuchBucket"}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp abort_s3_uploads_and_delete(bucket) do
    with {:ok, uploads} <- list_s3_uploads(bucket) do
      for {key, upload_id} <- uploads do
        path = "/#{bucket}/" <> URL.encode_path(key) <> URL.encode_query([{"uploadId", upload_id}])
        :ok = s3_request(:delete, path, [204, 404])
      end

      s3_request(:delete, "/" <> bucket, [200, 204, 404])
    end
  end

  @doc "The multipart uploads in `bucket` that were neither completed nor aborted, as `{key, upload_id}` pairs."
  @spec list_s3_uploads(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def list_s3_uploads(bucket) do
    case send_s3_request(:get, "/#{bucket}?uploads=") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, result} = XML.parse(body)

        {:ok,
         for(upload <- XML.children(result, "Upload"), do: {XML.text(upload, "Key"), XML.text(upload, "UploadId")})}

      {:ok, %{status: 404}} ->
        {:ok, []}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, error_code(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp s3_request(method, path, allowed) do
    method
    |> send_s3_request(path)
    |> accept(allowed)
  end

  defp send_s3_request(method, path) do
    credentials = s3_credentials()

    Req.request(
      method: method,
      url: url(:s3) <> path,
      aws_sigv4: [
        access_key_id: credentials[:access_key_id],
        secret_access_key: credentials[:secret_access_key],
        region: credentials[:region],
        service: :s3
      ],
      retry: false,
      raw: true
    )
  end

  # `allowed` holds statuses, and `{status, code}` pairs that accept a status only with that S3 error code.
  defp accept({:ok, %{status: status, body: body}}, allowed) when is_list(allowed) do
    code = error_code(body)

    if status in allowed or {status, code} in allowed do
      :ok
    else
      {:error, {:unexpected_status, status, code}}
    end
  end

  defp accept({:error, reason}, _allowed), do: {:error, reason}

  defp error_code(body) do
    case XML.parse(body) do
      {:ok, element} -> XML.text(element, "Code")
      {:error, :invalid_xml} -> nil
    end
  end
end
