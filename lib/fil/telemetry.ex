defmodule Fil.Telemetry do
  @moduledoc """
  The [Telemetry](https://hexdocs.pm/telemetry) events `Fil` emits: one span for every operation on every disk, and one
  for every read of a stream from `Fil.stream/3`.

  Attach a handler to collect metrics, log or trace:

      :telemetry.attach("my-app-fil", [:fil, :op, :stop], &MyApp.Telemetry.handle_event/4, nil)

  The events are always emitted, and add well under a microsecond to an operation when no handler is attached.
  Handlers run synchronously in the process that runs the operation, so keep them short. `:telemetry` detaches a
  handler that raises, so the events suit metrics, logs and traces, but not an audit log that must be complete.

  ## Operation events

  Each call to an operation function, such as `Fil.read/3`, `Fil.write/4` or `Fil.exists?/1`, is a span, with the
  disk's plugins included in the time:

    * `[:fil, :op, :start]` when the operation starts
      * Measurements: `:monotonic_time`, `:system_time`
      * Metadata: see below
    * `[:fil, :op, :stop]` when it returns, whether it succeeded or not
      * Measurements: `:duration`, `:monotonic_time`, and `:bytes` on a successful read or write
      * Metadata: the start's, plus `:error`
    * `[:fil, :op, :exception]` when it raised, threw or exited
      * Measurements: `:duration`, `:monotonic_time`
      * Metadata: the start's, plus `:kind`, `:reason` and `:stacktrace`

  Times are in `:native` units, see `System.convert_time_unit/3`. The metadata:

    * `:op`: the operation, a `t:Fil.Op.name/0`, the same as the `:op` of an error. `Fil.stream/3` is a `:read`, and
      `Fil.exists?/1` and `Fil.dir?/1` are a `:stat`
    * `:disk`: the `Fil.Disk`
    * `:adapter`: the disk's adapter module, also when a plugin answered the call. Unlike the disk, it makes a good
      metric tag
    * `:path`: the path as the caller named it, normalized, even when a plugin rewrote it. A path that escapes the disk
      root is kept as given
    * `:dest` and `:dest_disk`: the destination of a `:cp` or `:rename`, and `nil` for other operations
    * `:streaming`: `true` for `Fil.stream/3`
    * `:error`: on `:stop` only, `nil` on success, otherwise the exception the call returns, with `:op`, `:path` and
      `:disk` filled in
    * `:telemetry_span_context`: the same on a start and its stop or exception

  A call that returns `{:error, error}` ends with a `:stop` that has the error, and its bang variant raises only after
  that. A path that escapes the disk root is such an error, with a `:start` and a `:stop` of its own. `Fil.exists?/1`
  on a missing file is a `:stat` that ends with a `Fil.NotFoundError`, so a counter of errors counts it too. An
  `:exception` means the call raised: a plugin or an adapter with a bug, or content passed to `Fil.write/4` that raised
  while it was read (`Fil.Plug` stops an upload that's too large or ends short this way). Options that fail validation
  raise before any event.

  `:bytes` counts the caller's content, before plugins change it:

    * a read: the size of the content it returns
    * a write: the `:size` option, the size of iodata or of a stream whose size `Fil.write/4` found, or what was read
      from any other stream (0 if a plugin answered without reading it)

  A read from `Fil.stream/3` has no `:bytes`, its stream events count them. Nor do copies, renames and the other
  operations.

  The metadata never has content, the result of the call (a signed URL is a credential), or the options of the call,
  which can hold file names and query parameters. The `%Fil.Op{}` isn't in it either, because it holds the content.

  ## Nested operations

  A copy or a rename across disks is a `:cp` or `:rename` span with the operations it runs nested inside: a streamed
  `:read` of the source, a `:write` to the destination that reads the stream, and for a rename an `:rm` of the source.
  A plugin that calls `Fil` nests its operations the same way. So a counter of all `[:fil, :op, :stop]` events counts
  a copy across disks three times, and an error of its read twice: on the `:read` and on the `:cp`. Filter or tag by
  `:op` where that matters.

  ## Stream events

  The op span of `Fil.stream/3` ends when it returns the stream. It covers the check that the file can be read (a
  HeadObject on S3). Every time the stream is read, that's a span of its own, in the process that reads it, from the
  first chunk it asks for to the last:

    * `[:fil, :stream, :start]` when the stream is enumerated
      * Measurements: `:monotonic_time`, `:system_time`
      * Metadata: the start metadata of the op, with a `:telemetry_span_context` of its own
    * `[:fil, :stream, :stop]` when the stream ended, or its consumer stopped reading
      * Measurements: `:duration`, `:monotonic_time`, and `:bytes`, the bytes handed to the consumer
      * Metadata: the start's, plus `:halted`
    * `[:fil, :stream, :exception]` when reading the stream failed
      * Measurements: `:duration`, `:monotonic_time`
      * Metadata: the start's, plus `:kind`, `:reason` and `:stacktrace`. `:reason` is the exception the stream raises,
        with its context filled in

  So the duration of a stream span includes the time to the first byte. `:halted` is `true` when the consumer asked to
  stop before the end: `Enum.take/2`, a client of `Fil.Plug` that disconnected, or a write that failed, such as an S3
  upload in parts whose part was refused. A consumer may ask for that after it has read every chunk (`Stream.zip/2`
  can), so `halted: true` doesn't mean content is missing. An exception of the consumer ends the span with
  `halted: true` as well, because the stream itself is fine, and its `:bytes` include the chunk it failed on. A span
  has no end if the process that reads the stream is killed, or if an enumeration that was suspended (by
  `Stream.zip/2`, say) is dropped.

  When a stream goes into `Fil.write/4` and the source fails, the write's `:stop` has the source's error, whose `:op`
  and `:path` name the source. A source that turns out to have another size than the write found for it (the file
  changed while it was read) is reported the same way, with a `Fil.ConflictError` on the write's `:stop`. The write
  checks the size, and the stream itself read fine, so its span ends with a `:stop` instead of an `:exception`, with
  `halted: true` if the source was longer, and `false` if it ended short.

  ## Metrics

  With [Telemetry.Metrics](https://hexdocs.pm/telemetry_metrics):

      [
        summary("fil.op.stop.duration", unit: {:native, :millisecond}, tags: [:op, :adapter, :streaming]),
        sum("fil.op.stop.bytes", tags: [:op, :adapter]),
        counter("fil.op.errors",
          event_name: [:fil, :op, :stop],
          keep: &(&1.error != nil),
          tags: [:op, :adapter, :error],
          tag_values: &%{&1 | error: inspect(&1.error.__struct__)}
        ),
        counter("fil.op.exception.duration", tags: [:op, :adapter]),
        summary("fil.stream.stop.duration", unit: {:native, :millisecond}, tags: [:adapter, :halted]),
        sum("fil.stream.stop.bytes", tags: [:adapter])
      ]

  Disks have no names. To tell two disks with the same adapter apart, map each disk to a name of your own in
  `:tag_values`:

      summary("fil.op.stop.duration",
        unit: {:native, :millisecond},
        tags: [:op, :disk],
        tag_values: &%{&1 | disk: disk_name(&1.disk)}
      )

  Never use `:path` as a tag: there are as many values as there are files.

  ## Logging

  `attach_default_logger/1` logs every operation and every read of a stream, with the duration, the bytes and the
  error. For logs of your own, attach a handler to the events above.

  ## HTTP requests

  `Fil.Adapter.S3` sends its requests with [Req](https://hexdocs.pm/req) and [Finch](https://hexdocs.pm/finch),
  which emits `[:finch, :request, ...]` events of its own. Most requests are sent from the process that runs the
  operation, so in a Finch handler that process is `self()`, and the requests fall inside its span. Only the download
  of a stream from `Fil.stream/3` and the requests that create and abort an upload in parts run in processes of their
  own. Those put the process that runs the operation first in `$callers`, so `hd(Process.get(:"$callers", []))` finds
  it there. In the operation's own process, `$callers` is empty (and that call crashes) or names the processes that
  started it.

  A handler that has to cover both, or tell the requests of one disk from another's, is better off with a
  `:finch_private` in each disk's `:req_options`. Finch passes it on in its events as `request.private`, from any
  process:

      Fil.disk(adapter: Fil.Adapter.S3, bucket: "uploads", req_options: [finch_private: %{disk: :uploads}])

  `Fil.Plug` has no events of its own. Its calls to `Fil` emit the events above, and `Plug.Telemetry` or the endpoint
  events of Phoenix time the requests.

  ## Privacy

  `:disk`, and the `:disk` of an error, hold the adapter's state, which may contain credentials. `inspect` leaves it
  out (see `Fil.Disk`), so logging them is safe, but a handler that exports the raw terms (to a tracing backend, say)
  exports the credentials too. Paths can be personal data. Content, results and options are never in the events (see
  above).

  ## Event names

  `[:fil, :op, ...]` and `[:fil, :stream, ...]` are the events `Fil` emits so far. Other names under `[:fil, ...]` are
  kept for `Fil` and its own plugins, so a plugin of your own emits its events under a prefix of its own.
  """

  require Logger

  @logger_schema NimbleOptions.new!(
                   level: [
                     type: {:in, [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug]},
                     default: :debug,
                     doc: "The `Logger` level of the messages."
                   ]
                 )

  @logger_id "fil-default-logger"

  @logger_events [
    [:fil, :op, :stop],
    [:fil, :op, :exception],
    [:fil, :stream, :stop],
    [:fil, :stream, :exception]
  ]

  @doc """
  Logs every operation and every read of a stream, with its duration, until `detach_default_logger/0`.

      Fil.Telemetry.attach_default_logger(level: :info)

  The messages look like this:

  ```text
  Fil write #Fil.Ref<s3:q3.pdf> in 12ms (5120 bytes)
  Fil read #Fil.Ref<s3:q4.pdf> failed in 8ms: could not read "q4.pdf" on #Fil.Disk<s3>: no such file (NoSuchKey)
  Fil stream #Fil.Ref<s3:videos/intro.mp4> in 9ms
  Fil streamed #Fil.Ref<s3:videos/intro.mp4> in 2140ms (73400320 bytes)
  ```

  Returns `{:error, :already_exists}` if the logger is attached already.

  ## Options

  #{NimbleOptions.docs(@logger_schema)}
  """
  @spec attach_default_logger(keyword()) :: :ok | {:error, :already_exists}
  def attach_default_logger(opts \\ []) do
    level =
      case NimbleOptions.validate(opts, @logger_schema) do
        {:ok, opts} -> opts[:level]
        {:error, error} -> raise ArgumentError, Exception.message(error)
      end

    :telemetry.attach_many(@logger_id, @logger_events, &__MODULE__.handle_event/4, level)
  end

  @doc "Stops logging. Returns `{:error, :not_found}` if the logger isn't attached."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: :telemetry.detach(@logger_id)

  @doc false
  @spec handle_event([atom()], map(), map(), Logger.level()) :: :ok
  def handle_event(event, measurements, metadata, level) do
    Logger.log(level, fn -> message(event, measurements, metadata) end)
  end

  defp message([:fil, :op, :stop], measurements, %{error: nil} = metadata) do
    [op(metadata), " in ", duration(measurements), bytes(measurements)]
  end

  defp message([:fil, :op, :stop], measurements, %{error: error} = metadata) do
    [op(metadata), " failed in ", duration(measurements), ": ", Exception.message(error)]
  end

  defp message([:fil, :op, :exception], measurements, metadata) do
    [op(metadata), " raised after ", duration(measurements), ": ", banner(metadata)]
  end

  defp message([:fil, :stream, :stop], measurements, %{halted: false} = metadata) do
    ["Fil streamed ", target(metadata), " in ", duration(measurements), bytes(measurements)]
  end

  defp message([:fil, :stream, :stop], measurements, %{halted: true} = metadata) do
    ["Fil stopped streaming ", target(metadata), " after ", duration(measurements), bytes(measurements)]
  end

  defp message([:fil, :stream, :exception], measurements, metadata) do
    ["Fil streaming ", target(metadata), " failed after ", duration(measurements), ": ", banner(metadata)]
  end

  # `Fil.stream/3` is a `:read`, but its op events only cover the check, so the message says "stream".
  defp op(%{streaming: true} = metadata), do: ["Fil stream ", target(metadata)]
  defp op(%{op: op} = metadata), do: ["Fil ", Atom.to_string(op), " ", target(metadata)]

  defp target(%{disk: disk, path: path, dest: nil}), do: ref(disk, path)

  defp target(%{disk: disk, path: path, dest: dest, dest_disk: dest_disk}) do
    [ref(disk, path), " to ", ref(dest_disk, dest)]
  end

  defp ref(disk, path), do: inspect(%Fil.Ref{disk: disk, path: path})

  defp duration(%{duration: duration}) do
    microseconds = System.convert_time_unit(duration, :native, :microsecond)

    if microseconds < 1000 do
      [Integer.to_string(microseconds), "µs"]
    else
      milliseconds = div(microseconds, 1000)
      [Integer.to_string(milliseconds), "ms"]
    end
  end

  defp bytes(%{bytes: bytes}), do: [" (", Integer.to_string(bytes), " bytes)"]
  defp bytes(_measurements), do: []

  defp banner(%{kind: kind, reason: reason, stacktrace: stacktrace}) do
    Exception.format_banner(kind, reason, stacktrace)
  end
end
