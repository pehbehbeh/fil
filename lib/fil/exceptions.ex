defmodule Fil.TransportError do
  @moduledoc """
  The storage backend couldn't be reached, or its answer says nothing about the file (a timeout, a closed connection, a
  5xx).

  Returned as `{:error, %Fil.TransportError{}}`. `Fil` doesn't retry transport failures (for now), because only the
  caller knows whether a failed mutation is safe to repeat.

  `:reason` is the underlying cause: an atom such as `:timeout`, an exception struct from the HTTP client, or
  `{:http_status, status}` for server errors.
  """

  defexception [:reason]

  @type t :: %__MODULE__{reason: term()}

  @impl Exception
  def message(%__MODULE__{reason: reason}), do: "transport error: " <> format(reason)

  @doc false
  def format(%{__exception__: true} = exception), do: Exception.message(exception)
  def format({:http_status, status}), do: "unexpected server response (HTTP #{status})"
  def format(reason) when is_atom(reason), do: to_string(reason)
  def format(reason), do: inspect(reason)
end

defmodule Fil.Error do
  @moduledoc """
  Raised by the bang variants of the `Fil` functions.

  The message contains the operation, the path and the adapter:

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.read!(disk, "nope.txt")
      ** (Fil.Error) could not read "nope.txt" on Fil.Adapter.Memory: no such file or directory

  The struct keeps the original `:reason`, so code that rescues the error can still match on `:enoent` and the like.
  """

  defexception [:reason, :op, :path, :adapter, :message]

  @type t :: %__MODULE__{
          reason: term(),
          op: atom(),
          path: String.t() | nil,
          adapter: module() | nil,
          message: String.t()
        }

  @impl Exception
  def exception(opts) do
    reason = Keyword.get(opts, :reason)
    op = Keyword.get(opts, :op)
    path = Keyword.get(opts, :path)
    adapter = Keyword.get(opts, :adapter)

    %__MODULE__{
      reason: reason,
      op: op,
      path: path,
      adapter: adapter,
      message: build_message(op, path, adapter, reason)
    }
  end

  defp build_message(op, path, adapter, reason) do
    [
      "could not ",
      verb(op),
      if(path, do: [preposition(op), inspect(path)], else: []),
      if(adapter, do: [" on ", inspect(adapter)], else: []),
      ": ",
      format_reason(reason)
    ]
    |> IO.iodata_to_binary()
  end

  defp verb(:read), do: "read"
  defp verb(:write), do: "write"
  defp verb(:rm), do: "delete"
  defp verb(:cp), do: "copy"
  defp verb(:rename), do: "rename"
  defp verb(:ls), do: "list"
  defp verb(:stat), do: "stat"
  defp verb(:rm_rf), do: "delete everything under"
  defp verb(:signed_url), do: "sign a URL"
  defp verb(nil), do: "complete the operation"
  defp verb(other), do: "#{other}"

  # Only needed before a path, so a message without one doesn't end in "for:".
  defp preposition(:signed_url), do: " for "
  defp preposition(nil), do: " on "
  defp preposition(_op), do: " "

  @doc false
  def format_reason(:ebadpath), do: "the path escapes the disk root"

  def format_reason(:precondition_failed), do: "the write precondition failed"

  def format_reason(:checksum_mismatch), do: "the content doesn't match its checksum"

  def format_reason({:unsupported, op}), do: "#{op} is not supported by this adapter"

  def format_reason({:wrong_region, nil}), do: "the bucket is in a different region"

  def format_reason({:wrong_region, region}), do: "the bucket is in a different region (#{region})"

  def format_reason({:unexpected_status, status, nil}), do: "unexpected response (HTTP #{status})"

  def format_reason({:unexpected_status, status, code}), do: "unexpected response (HTTP #{status}, #{code})"

  def format_reason(%{__exception__: true} = exception), do: Exception.message(exception)

  def format_reason(reason) when is_atom(reason) do
    # Newer OTP releases append the atom (`unknown POSIX error: foo`).
    case :file.format_error(reason) do
      ~c"unknown POSIX error" ++ _rest -> inspect(reason)
      message -> List.to_string(message)
    end
  end

  def format_reason(reason), do: inspect(reason)
end
