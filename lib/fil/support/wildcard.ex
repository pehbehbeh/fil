defmodule Fil.Support.Wildcard do
  @moduledoc false

  # `Fil.wildcard/3`, with `Path.wildcard/2`'s syntax and dotfile rule. No storage matches patterns itself, so `walk/4`
  # lists one directory level per segment of the pattern, and from a `**` on the whole subtree once, the same on every
  # adapter.

  alias Fil.Ref

  @typedoc "A compiled pattern: a segment per directory level."
  @type t :: [segment()]

  @typep segment :: {:literal, String.t()} | {:match, Regex.t()} | :globstar

  @doc ~S"""
  Compiles a pattern, raising `ArgumentError` when it isn't one.

      iex> Fil.Support.Wildcard.compile!("reports/*.pdf") |> Enum.map(&elem(&1, 0))
      [:literal, :match]
      iex> Fil.Support.Wildcard.compile!("**/q?.{pdf,csv}") |> hd()
      :globstar
      iex> Fil.Support.Wildcard.compile!("reports//q3.pdf")
      ** (ArgumentError) invalid pattern "reports//q3.pdf": empty, "." and ".." segments aren't allowed

  """
  @spec compile!(String.t()) :: t()
  def compile!(pattern) do
    pattern
    |> String.split("/")
    |> Enum.map(&segment!(&1, pattern))
  end

  defp segment!(segment, pattern) when segment in ["", ".", ".."] do
    raise ArgumentError, ~s(invalid pattern #{inspect(pattern)}: empty, "." and ".." segments aren't allowed)
  end

  defp segment!("**", _pattern), do: :globstar

  defp segment!(segment, pattern) do
    case parse(segment, [], false, nil) do
      {:ok, _source, false} -> {:literal, String.replace(segment, ~r/\\(.)/su, "\\1")}
      {:ok, source, true} -> {:match, regex(source)}
      {:error, message} -> raise ArgumentError, "invalid pattern #{inspect(pattern)}: #{message}"
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
  Lists the paths of `disk` that match `pattern`, sorted. `list` lists a directory, one level deep or, when its second
  argument is `true`, the whole subtree, directories included.

  The literal segments at the start of the pattern need no listing. Each other segment lists every directory the
  segment before it matched, and a `**` lists every one of them recursively, matching the rest of the pattern against
  the subtree.

  As with `Path.wildcard/2`, a name that starts with a dot is hidden in those listings unless `match_dot` is `true`, so
  only the literal start of a pattern (and a pattern without wildcards) can name one.
  """
  @spec walk(Fil.Disk.t(), t(), boolean(), (Ref.t(), boolean() -> {:ok, [Ref.t()]} | {:error, term()})) ::
          {:ok, [Ref.t()]} | {:error, term()}
  def walk(disk, pattern, match_dot, list) do
    {head, rest} = literal_head(pattern)
    start = Ref.new(disk, Enum.join(["." | head], "/"))
    hide_dots = not match_dot and not Enum.all?(pattern, &match?({:literal, _name}, &1))

    with {:ok, matched} <- match([start], rest, {list, hide_dots}) do
      {:ok, Enum.sort_by(matched, & &1.path)}
    end
  end

  # The last segment always stays, so there's one listing to find out what exists.
  defp literal_head(pattern) do
    {head, _last} =
      pattern
      |> Enum.drop(-1)
      |> Enum.split_while(&match?({:literal, _name}, &1))

    {Enum.map(head, &elem(&1, 1)), Enum.drop(pattern, length(head))}
  end

  defp match(dirs, [:globstar | _rest] = pattern, {list, hide_dots}) do
    flat_map(dirs, fn dir ->
      with {:ok, listed} <- list.(dir, true) do
        {:ok, Enum.filter(listed, &subtree_match?(pattern, names(&1, dir), hide_dots))}
      end
    end)
  end

  defp match(dirs, [segment], walker), do: flat_map(dirs, &list_matching(&1, segment, walker))

  defp match(dirs, [segment | rest], walker) do
    with {:ok, matched} <- flat_map(dirs, &list_matching(&1, segment, walker)) do
      directories = Enum.filter(matched, &(&1.stat.type == :directory))
      match(directories, rest, walker)
    end
  end

  defp list_matching(dir, segment, {list, hide_dots}) do
    with {:ok, listed} <- list.(dir, false) do
      {:ok, Enum.filter(listed, &name_match?(segment, Path.basename(&1.path), hide_dots))}
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

  defp subtree_match?(pattern, names, true), do: not Enum.any?(names, &dot?/1) and matches?(pattern, names)
  defp subtree_match?(pattern, names, false), do: matches?(pattern, names)

  # A `**` matches any number of names, none included.
  defp matches?([], []), do: true
  defp matches?([:globstar | rest] = pattern, names), do: matches?(rest, names) or matches_deeper?(pattern, names)
  defp matches?([segment | rest], [name | names]), do: name?(segment, name) and matches?(rest, names)
  defp matches?(_pattern, _names), do: false

  defp matches_deeper?(_pattern, []), do: false
  defp matches_deeper?(pattern, [_name | names]), do: matches?(pattern, names)

  defp name_match?(segment, name, true), do: not dot?(name) and name?(segment, name)
  defp name_match?(segment, name, false), do: name?(segment, name)

  defp name?({:literal, literal}, name), do: literal == name
  defp name?({:match, regex}, name), do: Regex.match?(regex, name)

  defp dot?(name), do: String.starts_with?(name, ".")
end
