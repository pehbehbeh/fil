defmodule Fil.Adapter.S3.UploadGuard do
  @moduledoc false

  # The guard is a process of its own that creates the multipart upload and aborts it, so an upload whose writer is
  # killed (a supervisor shutdown, a client that disconnects from a Cowboy request) is aborted too. It monitors the
  # writer, and knows the upload from the moment it exists. It isn't linked, so it outlives a killed writer. The writer
  # stops it with `:done` after completing, and with `:abort` on any failure, and waits until it's done, so no upload
  # is left when a write returns. What a guard can't clean up (the node goes down, the abort fails) is left to the
  # bucket's lifecycle rules.

  alias Fil.Adapter.S3.Client
  alias Fil.Support.ObjectStore
  alias Fil.Support.XML

  @type t :: %{pid: pid(), ref: reference()}

  @doc "Starts the guard of an upload to `key` by the calling process."
  @spec start(Fil.Adapter.S3.t(), String.t()) :: t()
  def start(state, key) do
    writer = self()
    ref = make_ref()
    # `$callers` lets the guard find what the writer was allowed, such as a `Req.Test` stub.
    callers = [writer | Process.get(:"$callers", [])]

    pid =
      spawn(fn ->
        # The label shows in `:observer` and crash reports. The key names the file, and nothing else goes in.
        Process.set_label({Fil.Adapter.S3, :upload_guard, key})
        Process.put(:"$callers", callers)
        loop(%{state: state, key: key, ref: ref, writer: writer, monitor: Process.monitor(writer), id: nil})
      end)

    %{pid: pid, ref: ref}
  end

  @doc """
  Creates the upload with `headers` and returns its id. The guard crashes only on a bug, such as bad `:req_options`,
  which the writer then raises.
  """
  @spec create(t(), [{String.t(), String.t()}]) :: {:ok, String.t()} | {:error, Exception.t()}
  def create(guard, headers) do
    case ask(guard, {:create, headers}) do
      {:down, {%{__exception__: true} = exception, stacktrace}} -> reraise(exception, stacktrace)
      {:down, reason} -> exit(reason)
      reply -> reply
    end
  end

  @doc "Stops the guard after the upload completed (`:done`) or failed (`:abort`), and waits until it's done."
  @spec stop(t(), :done | :abort) :: :ok
  def stop(guard, message) do
    # A guard that crashed has nothing left to stop, and its error was raised already.
    case ask(guard, message) do
      {:down, _reason} -> :ok
      reply -> reply
    end
  end

  defp ask(%{pid: pid, ref: ref}, message) do
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

  defp loop(%{ref: ref, writer: writer, monitor: monitor} = guard) do
    receive do
      {^ref, {:create, headers}} ->
        guard
        |> create_upload(headers)
        |> loop()

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
  defp create_upload(%{state: state, key: key, ref: ref, writer: writer} = guard, headers) do
    result =
      case Client.request(state, :post, key, params: [{"uploads", ""}], headers: headers) do
        {:ok, %{status: 200, body: body}} -> upload_id(body)
        {:ok, response} -> {:error, Client.error(response)}
        {:error, reason} -> {:error, reason}
      end

    send(writer, {ref, result})

    case result do
      {:ok, id} -> %{guard | id: id}
      {:error, _error} -> guard
    end
  end

  defp upload_id(body) do
    with {:ok, result} <- ObjectStore.parse_xml(body) do
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
    _result = Client.request(state, :delete, key, params: [{"uploadId", id}])
    :ok
  end
end
