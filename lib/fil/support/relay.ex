defmodule Fil.Support.Relay do
  @moduledoc false

  # A collectable that passes each chunk to the process reading a download and waits until it asks for the next one, so
  # a download goes no faster than it's read and holds at most a chunk or two in memory. It's what `Fil.Adapter.S3`
  # gives Req as `into:`, in a process of its own (see `Fil.Adapter.S3.stream/3`).
  #
  # The reader gets `{ref, :data, chunk}` and answers `{ref, :more}`. If the reader exits, the download stops.

  @enforce_keys [:to, :ref, :monitor]
  defstruct [:to, :ref, :monitor]

  @type t :: %__MODULE__{to: pid(), ref: reference(), monitor: reference()}

  defimpl Collectable do
    def into(relay), do: {relay, &collect/2}

    defp collect(%{to: to, ref: ref, monitor: monitor} = relay, {:cont, chunk}) do
      send(to, {ref, :data, chunk})

      receive do
        {^ref, :more} -> relay
        {:DOWN, ^monitor, :process, _pid, _reason} -> exit(:normal)
      end
    end

    defp collect(relay, :done), do: relay
    defp collect(_relay, :halt), do: :ok
  end
end
