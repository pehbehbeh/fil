defmodule Fil.Support.Accept do
  @moduledoc false

  # The extensions an upload's `accept:` allows, and the check of a path against a list of extensions, for
  # `Fil.LiveView` and `Fil.Backpex.Upload`.

  # The `accept:` filters that stand for a kind of file, not one type.
  @wildcards ~w(audio/* image/* video/*)

  @doc """
  The extensions `accept` allows: the ones it lists, and those of its exact types. Takes `:any`, a list, or the
  comma-separated string LiveView keeps in the upload config. Wildcards allow none, and `nil` means no check: for
  `:any`, or a list of wildcards only.

      iex> Fil.Support.Accept.extensions(~w(.png image/jpeg image/*))
      [".png", ".jpg", ".jpeg"]
      iex> Fil.Support.Accept.extensions(".pdf,image/*")
      [".pdf"]
      iex> Fil.Support.Accept.extensions(~w(image/*))
      nil
      iex> Fil.Support.Accept.extensions(:any)
      nil

  """
  @spec extensions(:any | String.t() | [String.t()]) :: [String.t()] | nil
  def extensions(:any), do: nil

  def extensions(accept) when is_binary(accept) do
    accept
    |> String.split(",")
    |> extensions()
  end

  def extensions(accept) when is_list(accept) do
    extensions =
      accept
      |> Enum.flat_map(&filter_extensions/1)
      |> Enum.uniq()

    if extensions != [], do: extensions
  end

  @doc """
  Checks that the path of `ref` ends with one of `extensions`, in lowercase. `nil` checks nothing, and an empty list
  refuses every path. The error is a `Fil.InvalidRequestError` with `reason: :extension` and `op`.
  """
  @spec check(Fil.Ref.t(), [String.t()] | nil, atom()) :: :ok | {:error, Fil.InvalidRequestError.t()}
  def check(_ref, nil, _op), do: :ok

  def check(ref, extensions, op) do
    extension =
      ref.path
      |> Path.extname()
      |> String.downcase()

    if extension != "" and extension in Enum.map(extensions, &String.downcase/1) do
      :ok
    else
      {:error, %Fil.InvalidRequestError{reason: :extension, op: op, path: ref.path, disk: ref.disk}}
    end
  end

  defp filter_extensions("." <> _name = extension), do: [extension]
  defp filter_extensions(wildcard) when wildcard in @wildcards, do: []

  defp filter_extensions(type) do
    type
    |> MIME.extensions()
    |> Enum.map(&("." <> &1))
  end
end
