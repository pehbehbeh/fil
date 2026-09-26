defmodule Fil.Support.URL do
  @moduledoc false

  # Percent-encoding for object stores: everything outside the unreserved set is encoded, because request signatures are
  # computed over exactly that form.

  @doc "Encodes every segment of an object name, keeping the separators."
  @spec encode_path(String.t()) :: String.t()
  def encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &encode/1)
  end

  @doc "Encodes one query name or value, including separators."
  @spec encode(term()) :: String.t()
  def encode(value) do
    value
    |> to_string()
    |> URI.encode(fn char -> URI.char_unreserved?(char) end)
  end

  @doc "Builds a query string, or an empty one for no parameters."
  @spec encode_query([{term(), term()}]) :: String.t()
  def encode_query([]), do: ""

  def encode_query(params) do
    "?" <> Enum.map_join(params, "&", fn {name, value} -> encode(name) <> "=" <> encode(value) end)
  end
end
