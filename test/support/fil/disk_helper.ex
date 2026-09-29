defmodule Fil.DiskHelper do
  @moduledoc false

  # The adapters a feature test runs on with `parameterize:`, and the disk for each. For modules whose subject is the
  # storage path (`Fil.Plug`, `Fil.LiveView`), not for code above the adapter:
  #
  #     use ExUnit.Case, async: true, parameterize: Fil.DiskHelper.adapters()
  #
  #     @moduletag :tmp_dir
  #
  #     setup context do
  #       {:ok, disk: Fil.DiskHelper.disk(context)}
  #     end
  #
  # Build disks in `setup`, never in `setup_all`: a memory store belongs to the test process.

  @doc "The parameters, one per adapter. The module is the value, so a failure prints the adapter it ran on."
  @spec adapters() :: [%{adapter: module()}]
  def adapters, do: [%{adapter: Fil.Adapter.Local}, %{adapter: Fil.Adapter.Memory}]

  @doc "Builds a disk of `context.adapter`: a local one in the test's temporary directory, a memory one in its store."
  @spec disk(map()) :: Fil.Disk.t()
  def disk(%{adapter: Fil.Adapter.Local} = context) do
    tmp_dir =
      Map.get(context, :tmp_dir) ||
        raise ArgumentError, "a local disk needs a temporary directory, add @moduletag :tmp_dir to the test module"

    Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)
  end

  def disk(%{adapter: Fil.Adapter.Memory}) do
    :ok = Fil.Adapter.Memory.checkout()
    Fil.disk(adapter: Fil.Adapter.Memory)
  end
end
