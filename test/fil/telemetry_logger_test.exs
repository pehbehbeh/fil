defmodule Fil.TelemetryLoggerTest do
  alias Fil.Adapter.Memory

  # The default logger is attached for every process, so these tests run on their own, after the async ones.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    :ok = Memory.checkout()
    on_exit(fn -> Fil.Telemetry.detach_default_logger() end)
    {:ok, disk: Fil.disk(adapter: Memory)}
  end

  test "logs operations with their duration, bytes and errors", %{disk: disk} do
    :ok = Fil.Telemetry.attach_default_logger()
    other = Fil.disk(adapter: Memory, root: "other")

    log =
      capture_log(fn ->
        {:ok, _} = Fil.write(disk, "a.txt", "content")
        {:error, _} = Fil.read(disk, "nope.txt")
        {:ok, _} = Fil.cp(disk, "a.txt", Fil.ref(other, "b.txt"))
      end)

    assert log =~ ~r/\[debug\] Fil write #Fil.Ref<memory:a.txt> in \d+(µs|ms) \(7 bytes\)/
    assert log =~ ~s|Fil read #Fil.Ref<memory:nope.txt> failed in |
    assert log =~ ~s|: could not read "nope.txt" on #Fil.Disk<memory>: no such file (:enoent)|
    assert log =~ ~r/Fil stream #Fil.Ref<memory:a.txt> in \d+(µs|ms)\n/
    assert log =~ ~r/Fil streamed #Fil.Ref<memory:a.txt> in \d+(µs|ms) \(7 bytes\)/
    assert log =~ ~r/Fil cp #Fil.Ref<memory:a.txt> to #Fil.Ref<memory:b.txt> in \d+(µs|ms)\n/
  end

  test "logs streams that stop early or fail, and operations that raise", %{disk: disk} do
    {:ok, _} = Fil.write(disk, "a.txt", "content")
    :ok = Fil.Telemetry.attach_default_logger(level: :warning)
    raising = Fil.attach(disk, :broken, fn _op, _next, _opts -> raise "broken" end)

    failing =
      Fil.attach(disk, :failing, fn op, _next, _opts ->
        Fil.Op.put_result(op, {:ok, Stream.map([:error], fn _ -> raise %Fil.UnavailableError{reason: :closed} end)})
      end)

    log =
      capture_log(fn ->
        {:ok, stream} = Fil.stream(disk, "a.txt")
        assert Enum.take(stream, 1) == ["content"]
        assert_raise RuntimeError, fn -> Fil.read(raising, "a.txt") end
        {:ok, stream} = Fil.stream(failing, "a.txt")
        assert_raise Fil.UnavailableError, fn -> Enum.to_list(stream) end
      end)

    assert log =~ ~r/\[warning\] Fil stopped streaming #Fil.Ref<memory:a.txt> after \d+(µs|ms) \(7 bytes\)/
    assert log =~ ~r/Fil read #Fil.Ref<memory:a.txt> raised after \d+(µs|ms): \*\* \(RuntimeError\) broken/
    assert log =~ ~r/Fil streaming #Fil.Ref<memory:a.txt> failed after \d+(µs|ms): \*\* \(Fil.UnavailableError\)/
  end

  test "attaches once, and detaches" do
    assert Fil.Telemetry.attach_default_logger() == :ok
    assert Fil.Telemetry.attach_default_logger() == {:error, :already_exists}
    assert Fil.Telemetry.detach_default_logger() == :ok
    assert Fil.Telemetry.detach_default_logger() == {:error, :not_found}
  end

  test "rejects an unknown level" do
    assert_raise ArgumentError, ~r/:level/, fn -> Fil.Telemetry.attach_default_logger(level: :loud) end
  end
end
