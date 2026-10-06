defmodule Fil.Support.Glob do
  @moduledoc false

  # The `glob:` option of `Fil.ls/3`. The syntax is `Path.wildcard/2`'s, but `*` and `?` also match names starting with
  # a dot, because object stores have no hidden files. There's no globbing on any storage, so `walk/3` lists one
  # directory level per segment of the pattern, and from a `**` on the whole subtree once, the same on every adapter.

  alias Fil.Ref

  @typedoc "A compiled pattern: a segment per directory level."
  @type t :: [segment()]

  @typep segment :: {:literal, String.t()} | {:match, Regex.t()} | :globstar

  @doc ~S"""
  Compiles a pattern, raising `ArgumentError` when it isn't one.

      iex> Fil.Support.Glob.compile!("reports/*.pdf") |> Enum.map(&elem(&1, 0))
      [:literal, :match]
      iex> Fil.Support.Glob.compile!("**/q?.{pdf,csv}") |> hd()
      :globstar
      iex> Fil.Support.Glob.compile!("reports//q3.pdf")
      ** (ArgumentError) invalid glob "reports//q3.pdf": empty, "." and ".." segments aren't allowed

  """
  @spec compile!(String.t()) :: t()
  def compile!(pattern) do
    pattern
    |> String.split("/")
    |> Enum.map(&segment!(&1, pattern))
  end

  defp segment!(segment, pattern) when segment in ["", ".", ".."] do
    raise ArgumentError, ~s(invalid glob #{inspect(pattern)}: empty, "." and ".." segments aren't allowed)
  end

  defp segment!("**", _pattern), do: :globstar

  defp segment!(segment, pattern) do
    case parse(segment, [], false, nil) do
      {:ok, _source, false} -> {:literal, String.replace(segment, ~r/\\(.)/su, "\\1")}
      {:ok, source, true} -> {:match, regex(source)}
      {:error, message} -> raise ArgumentError, "invalid glob #{inspect(pattern)}: #{message}"
    end
  end

  defp regex(source) do
    ["\\A", source, "\\z"]
    |> IO.iodata_to_binary()
    |> Regex.compile!("u")
  end

  # Builds the regex source of a segment, and whether it has a wildcard. `closing` is `?}` inside braces, where `,`
  # separates the alternatives; outside them, `,` and `}` are plain characters.
  defp parse(<<>>, acc, wildcard?, nil), do: {:ok, acc, wildcard?}
  defp parse(<<>>, _acc, _wildcard?, ?}), do: {:error, "unclosed {"}
  defp parse("*" <> rest, acc, _wildcard?, closing), do: parse(rest, [acc | "[^/]*"], true, closing)
  defp parse("?" <> rest, acc, _wildcard?, closing), do: parse(rest, [acc | "[^/]"], true, closing)
  defp parse("," <> rest, acc, wildcard?, ?}), do: parse(rest, [acc | "|"], wildcard?, ?})
  defp parse("}" <> rest, acc, _wildcard?, ?}), do: {:closed, acc, rest}

  defp parse("{" <> rest, acc, _wildcard?, closing) do
    case parse(rest, [], true, ?}) do
      {:closed, alternatives, rest} -> parse(rest, [acc, "(?:", alternatives, ")"], true, closing)
      {:error, message} -> {:error, message}
    end
  end

  defp parse("[" <> rest, acc, _wildcard?, closing) do
    case String.split(rest, "]", parts: 2) do
      [class, rest] when class != "" -> parse(rest, [acc, "[", class(class), "]"], true, closing)
      _unclosed -> {:error, "unclosed or empty ["}
    end
  end

  defp parse(<<?\\, char::utf8, rest::binary>>, acc, wildcard?, closing) do
    parse(rest, [acc | Regex.escape(<<char::utf8>>)], wildcard?, closing)
  end

  defp parse(<<char::utf8, rest::binary>>, acc, wildcard?, closing) do
    parse(rest, [acc | Regex.escape(<<char::utf8>>)], wildcard?, closing)
  end

  # A class keeps its ranges (`a-z`); everything else in it is literal.
  defp class(class) do
    class
    |> String.split("-")
    |> Enum.map_join("-", &Regex.escape/1)
  end

  @doc """
  Lists the paths below `dir` that match `glob`, sorted. `list` lists a directory, one level deep or, when its second
  argument is `true`, the whole subtree, directories included.

  The literal segments at the start of the pattern need no listing. Each other segment lists every directory the
  segment before it matched, and a `**` lists every one of them recursively, matching the rest of the pattern against
  the subtree.
  """
  @spec walk(Ref.t(), t(), (Ref.t(), boolean() -> {:ok, [Ref.t()]} | {:error, term()})) ::
          {:ok, [Ref.t()]} | {:error, term()}
  def walk(%Ref{} = dir, glob, list) do
    {head, rest} = literal_head(glob)
    start = Ref.new(dir.disk, Enum.join([dir.path | head], "/"))

    with {:ok, matched} <- match([start], rest, list) do
      {:ok, Enum.sort_by(matched, & &1.path)}
    end
  end

  # The last segment always stays, so there's one listing to find out what exists.
  defp literal_head(glob) do
    {head, _last} =
      glob
      |> Enum.drop(-1)
      |> Enum.split_while(&match?({:literal, _name}, &1))

    {Enum.map(head, &elem(&1, 1)), Enum.drop(glob, length(head))}
  end

  defp match(dirs, [:globstar | _rest] = glob, list) do
    flat_map(dirs, fn dir ->
      with {:ok, listed} <- list.(dir, true) do
        {:ok, Enum.filter(listed, &matches?(glob, names(&1, dir)))}
      end
    end)
  end

  defp match(dirs, [segment], list), do: flat_map(dirs, &list_matching(&1, segment, list))

  defp match(dirs, [segment | rest], list) do
    with {:ok, matched} <- flat_map(dirs, &list_matching(&1, segment, list)) do
      directories = Enum.filter(matched, &(&1.stat.type == :directory))
      match(directories, rest, list)
    end
  end

  defp list_matching(dir, segment, list) do
    with {:ok, listed} <- list.(dir, false) do
      {:ok, Enum.filter(listed, &name?(segment, Path.basename(&1.path)))}
    end
  end

  defp flat_map(dirs, fun) do
    Enum.reduce_while(dirs, {:ok, []}, fn dir, {:ok, acc} ->
      case fun.(dir) do
        {:ok, refs} -> {:cont, {:ok, refs ++ acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp names(%Ref{path: path}, %Ref{path: "."}), do: String.split(path, "/")

  defp names(%Ref{path: path}, %Ref{path: dir}) do
    path
    |> String.replace_prefix(dir <> "/", "")
    |> String.split("/")
  end

  # A `**` matches any number of names, none included.
  defp matches?([], []), do: true
  defp matches?([:globstar | rest] = glob, names), do: matches?(rest, names) or matches_deeper?(glob, names)
  defp matches?([segment | rest], [name | names]), do: name?(segment, name) and matches?(rest, names)
  defp matches?(_glob, _names), do: false

  defp matches_deeper?(_glob, []), do: false
  defp matches_deeper?(glob, [_name | names]), do: matches?(glob, names)

  defp name?({:literal, literal}, name), do: literal == name
  defp name?({:match, regex}, name), do: Regex.match?(regex, name)
end
