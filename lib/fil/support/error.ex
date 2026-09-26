defmodule Fil.Support.Error do
  @moduledoc false
  # What the error structs share: their messages, and filling in the context adapters don't know.

  @doc """
  Fills in the context an adapter or a plugin didn't set. Fields that are already set are kept, so an adapter can
  report the destination of a copy as the path. Exceptions without these fields are returned unchanged.
  """
  @spec put_context(Exception.t(), keyword()) :: Exception.t()
  def put_context(%{op: _, path: _, disk: _} = error, context) do
    Enum.reduce(context, error, fn {key, value}, error ->
      if Map.fetch!(error, key) == nil, do: Map.put(error, key, value), else: error
    end)
  end

  def put_context(error, _context), do: error

  @doc "Builds the message from the fields, so context filled in after the error was built still shows."
  @spec message(Exception.t(), String.t()) :: String.t()
  def message(%{op: op, path: path, disk: disk, reason: reason}, description) do
    IO.iodata_to_binary([
      "could not ",
      verb(op),
      if(path, do: [preposition(op), inspect(path)], else: []),
      if(disk, do: [" on ", inspect(disk)], else: []),
      ": ",
      description,
      detail(reason)
    ])
  end

  defp verb(:read), do: "read"
  defp verb(:write), do: "write"
  defp verb(:rm), do: "delete"
  defp verb(:cp), do: "copy"
  defp verb(:rename), do: "rename"
  defp verb(:ls), do: "list"
  defp verb(:stat), do: "stat"
  defp verb(:rm_rf), do: "delete everything under"
  defp verb(:url), do: "build a URL"
  defp verb(:signed_url), do: "sign a URL"
  defp verb(nil), do: "complete the operation"
  defp verb(other), do: "#{other}"

  # Only needed before a path, so a message without one doesn't end in "for:".
  defp preposition(op) when op in [:url, :signed_url], do: " for "
  defp preposition(nil), do: " on "
  defp preposition(_op), do: " "

  defp detail(nil), do: []
  defp detail({:http_status, status}), do: [" (HTTP ", Integer.to_string(status), ")"]
  defp detail(%{__exception__: true} = exception), do: [" (", Exception.message(exception), ")"]
  defp detail(code) when is_binary(code), do: [" (", code, ")"]
  defp detail(reason), do: [" (", inspect(reason), ")"]
end
