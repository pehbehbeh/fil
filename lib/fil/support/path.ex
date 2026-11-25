defmodule Fil.Support.Path do
  @moduledoc false

  # Path normalization and the `../` jail. Every path passed to `Fil` goes through `normalize/1` before an adapter sees
  # it, and `Fil.Op.run/1` normalizes again after the plugins, so a rewritten path can't escape either.
  #
  # Normalization only looks at the string, so it's the same for every adapter:
  #
  #   * repeated separators collapse: `"a//b"` becomes `"a/b"`
  #   * `"."` segments disappear, and `".."` segments are resolved against the preceding segment
  #   * a leading `"/"` is dropped: paths are always relative to the disk root
  #   * the disk root itself normalizes to `"."`
  #   * anything that would escape the root, or that contains a null byte, is rejected with `{:error, :ebadpath}`

  @root "."

  @doc ~S"""
  Normalizes `path`, rejecting escapes.

  Repeated separators and `.` segments disappear, and `..` is resolved against the segment before it:

      iex> Fil.Support.Path.normalize("a//b/./c/../d.txt")
      {:ok, "a/b/d.txt"}

  A leading separator is dropped, because paths are always relative to the disk root:

      iex> Fil.Support.Path.normalize("///a/b.txt")
      {:ok, "a/b.txt"}

  The root itself is `"."`:

      iex> Fil.Support.Path.normalize("")
      {:ok, "."}
      iex> Fil.Support.Path.normalize(".")
      {:ok, "."}
      iex> Fil.Support.Path.normalize("/")
      {:ok, "."}
      iex> Fil.Support.Path.normalize("a/..")
      {:ok, "."}

  Dots inside a name, unicode and spaces are kept:

      iex> Fil.Support.Path.normalize("v1.2.3/.hidden")
      {:ok, "v1.2.3/.hidden"}
      iex> Fil.Support.Path.normalize("...")
      {:ok, "..."}
      iex> Fil.Support.Path.normalize("ünï cödé/a b.txt")
      {:ok, "ünï cödé/a b.txt"}

  Anything that climbs above the root, or contains a null byte, is rejected:

      iex> Fil.Support.Path.normalize("..")
      {:error, :ebadpath}
      iex> Fil.Support.Path.normalize("/../a")
      {:error, :ebadpath}
      iex> Fil.Support.Path.normalize("a/b/../../../c")
      {:error, :ebadpath}
      iex> Fil.Support.Path.normalize("a.txt\0.png")
      {:error, :ebadpath}

  """
  @spec normalize(Path.t()) :: {:ok, String.t()} | {:error, :ebadpath}
  def normalize(path) when is_binary(path) do
    if String.contains?(path, <<0>>) do
      {:error, :ebadpath}
    else
      path
      |> String.split("/")
      |> resolve([])
    end
  end

  @doc """
  Joins a normalized prefix and a name, keeping the root implicit.

      iex> Fil.Support.Path.join(".", "a.txt")
      "a.txt"
      iex> Fil.Support.Path.join("a", "b.txt")
      "a/b.txt"

  """
  @spec join(String.t(), String.t()) :: String.t()
  def join(@root, name), do: name
  def join(prefix, name), do: prefix <> "/" <> name

  @doc """
  The directories between `prefix` and each of `paths`, sorted. Object stores have them only implicitly, as the parents
  of their files.

      iex> Fil.Support.Path.parents(["a/b/c.txt", "a/d.txt", "e.txt"], ".")
      ["a", "a/b"]
      iex> Fil.Support.Path.parents(["a/b/c.txt", "a/d.txt"], "a")
      ["a/b"]

  """
  @spec parents([String.t()], String.t()) :: [String.t()]
  def parents(paths, prefix) do
    paths
    |> Enum.flat_map(&ancestors(&1, prefix))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp ancestors(path, prefix) do
    case Path.dirname(path) do
      @root -> []
      ^prefix -> []
      parent -> [parent | ancestors(parent, prefix)]
    end
  end

  defp resolve([], []), do: {:ok, @root}

  defp resolve([], acc) do
    path =
      acc
      |> Enum.reverse()
      |> Enum.join("/")

    {:ok, path}
  end

  defp resolve(["" | rest], acc), do: resolve(rest, acc)
  defp resolve([@root | rest], acc), do: resolve(rest, acc)
  defp resolve([".." | _rest], []), do: {:error, :ebadpath}
  defp resolve([".." | rest], [_parent | acc]), do: resolve(rest, acc)
  defp resolve([segment | rest], acc), do: resolve(rest, [segment | acc])
end
