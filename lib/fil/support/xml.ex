defmodule Fil.Support.XML do
  @moduledoc false

  # The little XML reading that object store listings need. S3 responds in XML, and `Fil` only ever asks for the
  # children named X or the text of Y.
  #
  # Parsing uses OTP's `:xmerl_sax_parser`, built into plain `{name, attributes, children}` tuples of strings. The SAX
  # parser reports names as charlists, so no atoms are created from what the server sent. Documents with a DTD are
  # rejected before parsing: S3 never sends one, and without it there are no entities to expand.

  @type element :: {String.t(), [{String.t(), String.t()}], [element() | String.t()]}

  @spec parse(binary()) :: {:ok, element()} | {:error, :invalid_xml}
  def parse(binary) when is_binary(binary) do
    with false <- String.contains?(binary, "<!DOCTYPE"),
         {:ok, {:done, element}, _rest} <- :xmerl_sax_parser.stream(binary, event_fun: &event/3, event_state: []) do
      {:ok, element}
    else
      _other -> {:error, :invalid_xml}
    end
  end

  def parse(_other), do: {:error, :invalid_xml}

  # The state is a stack of open elements, each with its children in reverse. Closing the last one leaves
  # `{:done, element}`.
  defp event({:startElement, _uri, name, _qualified, attributes}, _location, stack) do
    attributes = for {_uri, _prefix, key, value} <- attributes, do: {to_string(key), List.to_string(value)}
    [{to_string(name), attributes, []} | stack]
  end

  defp event({:characters, chars}, _location, [{name, attributes, children} | stack]) do
    [{name, attributes, [List.to_string(chars) | children]} | stack]
  end

  defp event({:endElement, _uri, _name, _qualified}, _location, [{name, attributes, children} | stack]) do
    element = {name, attributes, Enum.reverse(children)}

    case stack do
      [] -> {:done, element}
      [{parent, parent_attributes, siblings} | rest] -> [{parent, parent_attributes, [element | siblings]} | rest]
    end
  end

  defp event(_other, _location, state), do: state

  @doc "All direct children of `element` named `name`."
  @spec children(element(), String.t()) :: [element()]
  def children({_name, _attributes, children}, name) do
    for {child_name, _attributes, _children} = child <- children, child_name == name, do: child
  end

  @doc "The text of the first direct child named `name`, or `nil`."
  @spec text(element(), String.t()) :: String.t() | nil
  def text(element, name) do
    case children(element, name) do
      [child | _rest] -> text(child)
      [] -> nil
    end
  end

  @doc "The text an element holds directly."
  @spec text(element()) :: String.t()
  def text({_name, _attributes, children}) do
    children
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end
end
