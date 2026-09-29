defmodule Fil.Support.DiskOption do
  @moduledoc false

  # The `disk:` option of the integrations, so every schema takes and documents a disk the same way, and
  # `Fil.Disk.resolve/1` turns it into a disk. `allow` is a subset of:
  #
  #   * `:disk`: a `%Fil.Disk{}`
  #   * `:fun`: any 0-arity function
  #   * `:remote_fun`: only a capture of a named 0-arity function with its module (`&MyApp.Storage.uploads/0`), for
  #     options that end up in compiled code, such as plug options: `Macro.escape/1` can escape that capture, but not an
  #     anonymous function or a local capture (`&uploads/0`), which is an anonymous function too
  #   * `:mfa`: `{module, function, args}`
  #
  # The validator is public, because NimbleOptions calls it through the `{:custom, module, function, args}` type.

  @kinds [:disk, :fun, :remote_fun, :mfa]

  @doc """
  Returns the NimbleOptions type for a disk in one of the forms in `allow`.

      iex> Fil.Support.DiskOption.type([:disk, :mfa])
      {:custom, Fil.Support.DiskOption, :validate, [[:disk, :mfa]]}

  """
  @spec type([atom()]) :: {:custom, module(), :validate, [[atom()]]}
  def type(allow) do
    check_allow!(allow)
    {:custom, __MODULE__, :validate, [allow]}
  end

  @doc """
  Returns the `:doc` text for an option of `type(allow)`.

      iex> Fil.Support.DiskOption.doc([:disk])
      "A `Fil.Disk`."

      iex> Fil.Support.DiskOption.doc([:remote_fun, :mfa]) =~ "A capture of a named 0-arity function"
      true

  """
  @spec doc([atom()]) :: String.t()
  def doc(allow) do
    check_allow!(allow)

    {first, rest} =
      allow
      |> forms()
      |> String.split_at(1)

    sentence = String.upcase(first) <> rest <> "."

    if allow == [:disk] do
      sentence
    else
      sentence <> " A function is called each time the disk is used, so it can build the disk from runtime config."
    end
  end

  @doc """
  Validates a disk option against `allow`. Returns `{:ok, value}` or `{:error, message}`, as NimbleOptions expects.

      iex> Fil.Support.DiskOption.validate({Fil, :disk, [[adapter: Fil.Adapter.Memory]]}, [:mfa])
      {:ok, {Fil, :disk, [[adapter: Fil.Adapter.Memory]]}}

      iex> Fil.Support.DiskOption.validate(:uploads, [:disk])
      {:error, "expected a `Fil.Disk`, got: :uploads"}

  """
  @spec validate(term(), [atom()]) :: {:ok, term()} | {:error, String.t()}
  def validate(%Fil.Disk{} = disk, allow) do
    if :disk in allow, do: {:ok, disk}, else: error(allow, disk)
  end

  def validate(fun, allow) when is_function(fun, 0) do
    cond do
      :fun in allow ->
        {:ok, fun}

      :remote_fun in allow and Function.info(fun, :type) == {:type, :external} ->
        {:ok, fun}

      :remote_fun in allow ->
        {:error,
         "expected #{forms(allow)}, got an anonymous function or a local capture. This option ends up in compiled " <>
           "code, which can't hold either, so pass a capture with the module name, such as `&MyApp.Storage.uploads/0`"}

      true ->
        error(allow, fun)
    end
  end

  def validate({module, function, args} = mfa, allow) when is_atom(module) and is_atom(function) and is_list(args) do
    if :mfa in allow, do: {:ok, mfa}, else: error(allow, mfa)
  end

  def validate(value, allow), do: error(allow, value)

  defp error(allow, value), do: {:error, "expected #{forms(allow)}, got: #{inspect(value)}"}

  # The forms in `allow` as a phrase, such as "a `Fil.Disk`, or a 0-arity function that returns one".
  defp forms([:disk]), do: "a `Fil.Disk`"

  defp forms(allow) do
    functions =
      Enum.flat_map(@kinds, fn kind ->
        cond do
          kind not in allow -> []
          kind == :fun -> ["a 0-arity function"]
          kind == :remote_fun and :fun not in allow -> ["a capture of a named 0-arity function"]
          kind == :mfa -> ["`{module, function, args}`"]
          true -> []
        end
      end)

    returning = Enum.join(functions, " or ")

    if :disk in allow do
      "a `Fil.Disk`, or #{returning} that returns one"
    else
      "#{returning} that returns a `Fil.Disk`"
    end
  end

  defp check_allow!(allow) do
    if allow == [] or not Enum.all?(allow, &(&1 in @kinds)) do
      raise ArgumentError, "expected a non-empty subset of #{inspect(@kinds)}, got: #{inspect(allow)}"
    end
  end
end
