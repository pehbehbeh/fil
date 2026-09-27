defmodule Fil.TelemetryTest do
  alias Fil.Adapter.Memory
  alias Fil.Op

  use ExUnit.Case, async: true

  import Fil.TelemetryHelper

  @events [
    [:fil, :op, :start],
    [:fil, :op, :stop],
    [:fil, :op, :exception],
    [:fil, :stream, :start],
    [:fil, :stream, :stop],
    [:fil, :stream, :exception]
  ]

  @start_keys [:adapter, :dest, :dest_disk, :disk, :op, :path, :streaming, :telemetry_span_context]

  setup do
    :ok = Memory.checkout()
    :ok = attach(@events)
    {:ok, disk: Fil.disk(adapter: Memory)}
  end

  describe "operation events" do
    test "start and stop pair up, with the same metadata", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "reports/q3.txt", "content")

      assert [
               {[:fil, :op, :start], start_measurements, start},
               {[:fil, :op, :stop], stop_measurements, stop}
             ] = events()

      assert start_measurements
             |> Map.keys()
             |> Enum.sort() == [:monotonic_time, :system_time]

      assert stop_measurements
             |> Map.keys()
             |> Enum.sort() == [:bytes, :duration, :monotonic_time]

      assert start
             |> Map.keys()
             |> Enum.sort() == @start_keys

      assert stop == Map.put(start, :error, nil)

      assert %{
               op: :write,
               disk: ^disk,
               adapter: Memory,
               path: "reports/q3.txt",
               dest: nil,
               dest_disk: nil,
               streaming: false
             } = start
    end

    test "copies and renames have a destination", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "a.txt", "content")
      _ = events()

      assert {:ok, _} = Fil.cp(disk, "a.txt", "./copies//b.txt")
      assert [_start, {[:fil, :op, :stop], _, stop}] = events()
      assert %{op: :cp, path: "a.txt", dest: "copies/b.txt", dest_disk: ^disk} = stop
    end

    test "bytes are the caller's content on a successful read or write", %{disk: disk} do
      assert {:ok, _} = Fil.write(disk, "a.txt", ["ab", ["c", ?d]])
      assert {:ok, _} = Fil.write(disk, "b.txt", Stream.map(["ab", "cde"], & &1))
      assert {:ok, _} = Fil.write(disk, "c.txt", Stream.map(["ab", "cde"], & &1), size: 5)
      assert {:ok, "abcd"} = Fil.read(disk, "a.txt")
      assert {:ok, _} = Fil.stat(disk, "a.txt")

      assert [{:write, 4}, {:write, 5}, {:write, 5}, {:read, 4}, {:stat, nil}] =
               Enum.map(stops(), fn {measurements, metadata} -> {metadata.op, measurements[:bytes]} end)
    end

    test "bytes count what a plugin read of the caller's stream", %{disk: disk} do
      compressed =
        Fil.attach(disk, :gzip, fn op, next, _opts ->
          op
          |> Op.update_content(iodata: &:zlib.gzip/1)
          |> next.()
        end)

      answered =
        Fil.attach(disk, :answer, fn op, _next, _opts -> Op.put_result(op, {:ok, Fil.ref(op.disk, op.path)}) end)

      content = Stream.map(["ab", "cde"], & &1)

      assert {:ok, _} = Fil.write(compressed, "a.txt", content)
      assert {:ok, _} = Fil.write(answered, "b.txt", content)

      assert [{%{bytes: 5}, %{op: :write}}, {%{bytes: 0}, %{op: :write}}] = stops()
    end

    test "an error is in the stop's metadata, with its context", %{disk: disk} do
      assert {:error, %Fil.NotFoundError{} = error} = Fil.read(disk, "nope.txt")

      assert [{measurements, %{error: ^error}}] = stops()
      assert %Fil.NotFoundError{op: :read, path: "nope.txt", disk: ^disk} = error
      refute Map.has_key?(measurements, :bytes)
    end

    test "bang variants emit a stop, not an exception", %{disk: disk} do
      assert_raise Fil.NotFoundError, fn -> Fil.read!(disk, "nope.txt") end

      assert [{[:fil, :op, :start], _, _}, {[:fil, :op, :stop], _, %{error: %Fil.NotFoundError{}}}] = events()
    end

    test "exists? and dir? are a stat", %{disk: disk} do
      refute Fil.exists?(disk, "nope.txt")
      refute Fil.dir?(disk, "nope")

      assert [
               {_, %{op: :stat, path: "nope.txt", error: %Fil.NotFoundError{}}},
               {_, %{op: :stat, path: "nope", error: %Fil.NotFoundError{}}}
             ] = stops()
    end

    test "a plugin that raises ends the span with an exception", %{disk: disk} do
      raising = Fil.attach(disk, :broken, fn _op, _next, _opts -> raise "broken" end)
      returning = Fil.attach(disk, :broken, fn _op, _next, _opts -> :nope end)

      assert_raise RuntimeError, "broken", fn -> Fil.read(raising, "a.txt") end

      assert [
               {[:fil, :op, :start], _, %{telemetry_span_context: context}},
               {[:fil, :op, :exception], measurements, exception}
             ] = events()

      assert %{kind: :error, reason: %RuntimeError{message: "broken"}, stacktrace: [_ | _]} = exception
      assert %{op: :read, path: "a.txt", telemetry_span_context: ^context} = exception
      assert %{duration: _, monotonic_time: _} = measurements

      assert_raise ArgumentError, ~r/must return a %Fil.Op{}/, fn -> Fil.read(returning, "a.txt") end
      assert [_start, {[:fil, :op, :exception], _, %{reason: %ArgumentError{}}}] = events()
    end

    test "a plugin that answers itself emits the same events", %{disk: disk} do
      cached =
        Fil.attach(disk, :cache, fn
          %Op{name: :read} = op, _next, _opts -> Op.put_result(op, {:ok, ["cac", "hed"]})
          op, next, _opts -> next.(op)
        end)

      assert {:ok, _} = Fil.read(cached, "a.txt")

      assert [{%{bytes: 6}, %{op: :read, disk: ^cached, adapter: Memory, error: nil}}] = stops()
    end

    test "the path is the caller's, even when a plugin rewrote it", %{disk: disk} do
      prefixed = Fil.attach(disk, :prefix, fn op, next, _opts -> next.(%{op | path: "tenant/" <> op.path}) end)

      assert {:ok, _} = Fil.write(prefixed, "a.txt", "content")
      assert {:error, _} = Fil.read(prefixed, "nope.txt")

      assert [{_, %{path: "a.txt"}}, {_, %{path: "nope.txt", error: %{path: "nope.txt"}}}] = stops()
    end

    test "a stream that raises while it's written ends the write with an exception", %{disk: disk} do
      content = Stream.map([:boom], fn _ -> raise "the upload broke off" end)

      assert_raise RuntimeError, fn -> Fil.write(disk, "a.txt", content) end
      assert [_start, {[:fil, :op, :exception], _, %{op: :write, reason: %RuntimeError{}}}] = events()
    end
  end

  describe "stream events" do
    setup %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.txt", "content")
      _ = events()
      :ok
    end

    test "the op ends when the stream is handed out, the stream span when it's read", %{disk: disk} do
      assert {:ok, stream} = Fil.stream(disk, "a.txt")

      assert [{[:fil, :op, :start], _, op_start}, {[:fil, :op, :stop], op_measurements, op_stop}] = events()
      assert %{op: :read, streaming: true, path: "a.txt"} = op_start
      assert op_stop.error == nil
      refute Map.has_key?(op_measurements, :bytes)

      assert Enum.join(stream) == "content"

      assert [
               {[:fil, :stream, :start], start_measurements, start},
               {[:fil, :stream, :stop], stop_measurements, stop}
             ] = events()

      assert %{monotonic_time: _, system_time: _} = start_measurements
      assert %{duration: _, monotonic_time: _, bytes: 7} = stop_measurements
      assert start.telemetry_span_context != op_start.telemetry_span_context
      assert stop == Map.put(start, :halted, false)
      assert Map.delete(start, :telemetry_span_context) == Map.delete(op_start, :telemetry_span_context)
    end

    test "a stream the consumer stops early is halted, with the bytes it read", %{disk: disk} do
      chunked = answering(disk, fn -> Stream.map(["ab", "cd", "ef"], & &1) end)

      assert {:ok, stream} = Fil.stream(chunked, "a.txt")
      assert Enum.take(stream, 2) == ["ab", "cd"]

      assert [{%{bytes: 4}, %{halted: true}}] = stream_stops()
    end

    test "an error of the source is an exception", %{disk: disk} do
      failing =
        answering(disk, fn ->
          Stream.map([:ok, :error], fn
            :ok -> "ab"
            :error -> raise %Fil.UnavailableError{reason: :closed}
          end)
        end)

      assert {:ok, stream} = Fil.stream(failing, "a.txt")
      _ = events()

      assert_raise Fil.UnavailableError, fn -> Enum.to_list(stream) end

      assert [
               {[:fil, :stream, :start], _, _},
               {[:fil, :stream, :exception], %{duration: _}, %{kind: :error, reason: reason}}
             ] = events()

      assert %Fil.UnavailableError{op: :read, path: "a.txt", disk: ^failing} = reason
    end

    test "an error of the consumer halts the stream", %{disk: disk} do
      assert {:ok, stream} = Fil.stream(disk, "a.txt")

      assert_raise RuntimeError, "consumer", fn -> Enum.each(stream, fn _chunk -> raise "consumer" end) end
      assert [{%{bytes: 0}, %{halted: true}}] = stream_stops()
    end

    test "every enumeration is a span of its own", %{disk: disk} do
      assert {:ok, stream} = Fil.stream(disk, "a.txt")
      assert Enum.join(stream) == "content"
      assert Enum.join(stream) == "content"

      assert [{%{bytes: 7}, %{telemetry_span_context: first}}, {%{bytes: 7}, %{telemetry_span_context: second}}] =
               stream_stops()

      assert first != second
    end

    test "a stream read in another process emits there", %{disk: disk} do
      assert {:ok, stream} = Fil.stream(disk, "a.txt")

      assert "content" ==
               fn -> Enum.join(stream) end
               |> Task.async()
               |> Task.await()

      assert [{%{bytes: 7}, %{halted: false}}] = stream_stops()
    end

    test "a plugin's answer in memory is streamed with events", %{disk: disk} do
      cached = answering(disk, fn -> ["cac", "hed"] end)

      assert {:ok, stream} = Fil.stream(cached, "a.txt")
      assert Enum.to_list(stream) == ["cached"]
      assert [{%{bytes: 6}, %{halted: false}}] = stream_stops()
    end

    test "a stream written to a file counts on the write", %{disk: disk} do
      assert {:ok, stream} = Fil.stream(disk, "a.txt")
      assert {:ok, _} = Fil.write(disk, "b.txt", stream)

      assert [
               {[:fil, :op, :start], _, %{op: :read}},
               {[:fil, :op, :stop], _, %{op: :read}},
               {[:fil, :op, :start], _, %{op: :write}},
               {[:fil, :stream, :start], _, %{op: :read}},
               {[:fil, :stream, :stop], %{bytes: 7}, %{op: :read}},
               {[:fil, :op, :stop], %{bytes: 7}, %{op: :write}}
             ] = events()
    end
  end

  describe "privacy" do
    test "neither content nor signed URLs are in the events", %{disk: disk} do
      disk = Fil.Plugin.URL.attach(disk, base_url: "http://localhost/storage", secret: "secret")
      marker = "content-#{System.unique_integer([:positive])}"

      assert {:ok, _} = Fil.write(disk, "a.txt", marker)
      assert {:ok, ^marker} = Fil.read(disk, "a.txt")
      assert {:ok, stream} = Fil.stream(disk, "a.txt")
      assert Enum.join(stream) == marker
      assert {:ok, url} = Fil.signed_url(disk, "a.txt")

      for {_event, measurements, metadata} <- events() do
        refute inspect({measurements, metadata}) =~ marker
        refute inspect({measurements, metadata}) =~ url
      end
    end
  end

  # A disk whose plugin answers every streamed read with `content.()`.
  defp answering(disk, content) do
    Fil.attach(disk, :answer, fn
      %Op{name: :read, streaming: true} = op, _next, _opts -> Op.put_result(op, {:ok, content.()})
      op, next, _opts -> next.(op)
    end)
  end

  defp stops, do: for({[:fil, :op, :stop], measurements, metadata} <- events(), do: {measurements, metadata})

  defp stream_stops do
    for {[:fil, :stream, :stop], measurements, metadata} <- events(), do: {measurements, metadata}
  end
end
