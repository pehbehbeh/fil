defmodule Fil.TelemetryHelper do
  @moduledoc """
  Collects `Fil.Telemetry` events in the test that attached the handler.

  `:telemetry_test.attach_event_handlers/2` forwards the events of every process, and the async suites run in parallel.
  Disks can't tell tests apart either: memory disks with the same root are equal, because the store is found through
  `$callers`. So the handler only forwards events from the test process and the processes it started, such as a `Task`
  that reads a stream.

      import Fil.TelemetryHelper

      attach([[:fil, :op, :stop]])
      Fil.read(disk, "a.txt")
      assert_receive {:telemetry, [:fil, :op, :stop], %{duration: _}, %{op: :read}}

  """

  @doc "Attaches a handler for `events` that sends them to the test as `{:telemetry, event, measurements, metadata}`."
  @spec attach([[atom()]]) :: :ok
  def attach(events) do
    id = make_ref()
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, self())
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def handle_event(event, measurements, metadata, test) do
    if self() == test or test in Process.get(:"$callers", []) do
      send(test, {:telemetry, event, measurements, metadata})
    end
  end

  @doc "The events received so far, oldest first, as `{event, measurements, metadata}`. Takes them out of the mailbox."
  @spec events() :: [{[atom()], map(), map()}]
  def events, do: collect([])

  defp collect(received) do
    receive do
      {:telemetry, event, measurements, metadata} -> collect([{event, measurements, metadata} | received])
    after
      0 -> Enum.reverse(received)
    end
  end
end
