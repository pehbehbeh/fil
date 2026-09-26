defmodule Fil.Disk do
  @moduledoc """
  A disk is a plain value that describes where files are stored.

  Build one with `Fil.disk/1` and pass it around. There's no global configuration, no registry and no process behind it:

      disk = Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage")

  The struct holds the adapter module together with the state its `c:Fil.Adapter.init/1` returned, and the plugins
  attached with `Fil.Plugin.attach/4`. The adapter state may contain credentials, so `%Fil.Disk{}` has a custom
  `Inspect` implementation that prints only the adapter label:

      iex> inspect(Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil"))
      "#Fil.Disk<local>"

  """

  @enforce_keys [:adapter]
  defstruct [:adapter, plugins: []]

  @type t :: %__MODULE__{
          adapter: {module(), term()},
          plugins: [{atom(), Fil.Plugin.callback(), keyword()}]
        }

  @doc """
  Returns the adapter module backing `disk`.

      iex> Fil.Disk.adapter(Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil"))
      Fil.Adapter.Local

  """
  @spec adapter(t()) :: module()
  def adapter(%__MODULE__{adapter: {module, _state}}), do: module

  @doc """
  A short, human readable label for the disk's adapter.

  Used by the `Inspect` implementations of `Fil.Disk` and `Fil.Ref`.

      iex> Fil.Disk.label(Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil"))
      "local"

  """
  @spec label(t()) :: String.t()
  def label(%__MODULE__{adapter: {module, _state}}), do: label(module)

  @spec label(module()) :: String.t()
  def label(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  rescue
    # Erlang modules and other non-Elixir atoms
    ArgumentError -> inspect(module)
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(disk, _opts) do
      concat(["#Fil.Disk<", Fil.Disk.label(disk), ">"])
    end
  end
end
