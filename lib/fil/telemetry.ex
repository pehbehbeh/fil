defmodule Fil.Telemetry do
  @moduledoc """
  The [Telemetry](https://hexdocs.pm/telemetry) events `Fil` emits: one span for every operation on every disk, and one
  for every read of a stream from `Fil.stream/3`.

  Attach a handler to collect metrics, log or trace:

      :telemetry.attach("my-app-fil", [:fil, :op, :stop], &MyApp.Storage.handle_event/4, nil)

  The events are always emitted. Handlers run synchronously in the process that runs the operation, so keep them
  short.

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
  that. `Fil.exists?/1` on a missing file is a `:stat` that ends with a `Fil.NotFoundError`, so a counter of errors
  counts it too. An `:exception` means the call raised: a plugin or an adapter with a bug, or content passed to
  `Fil.write/4` that raised while it was read (`Fil.Plug` stops an upload that's too large or ends short this way).
  Options that fail validation raise before any event.

  `:bytes` counts the caller's content, before plugins change it:

    * a read: the size of the content it returns
    * a write: the `:size` option, the size of iodata, or what was read from a stream without `:size` (0 if a plugin
      answered without reading it)

  A read from `Fil.stream/3` has no `:bytes`, its stream events count them. Nor do copies, renames and the other
  operations.

  The metadata never has content, the result of the call (a signed URL is a credential), or the options of the call,
  which can hold file names and query parameters. The `%Fil.Op{}` isn't in it either, because it holds the content.

  ## Stream events

  The op span of `Fil.stream/3` ends when it returns the stream. It covers the check that the file can be read (a
  HeadObject on S3). Every time the stream is read, that's a span of its own, in the process that reads it, from the
  first chunk it asks for to the last:

    * `[:fil, :stream, :start]` when the stream is enumerated
      * Measurements: `:monotonic_time`, `:system_time`
      * Metadata: the start metadata of the op, with a `:telemetry_span_context` of its own
    * `[:fil, :stream, :stop]` when the stream ended, or its consumer stopped reading
      * Measurements: `:duration`, `:monotonic_time`, and `:bytes`, the bytes the consumer took
      * Metadata: the start's, plus `:halted`
    * `[:fil, :stream, :exception]` when reading the stream failed
      * Measurements: `:duration`, `:monotonic_time`
      * Metadata: the start's, plus `:kind`, `:reason` and `:stacktrace`. `:reason` is the exception the stream raises,
        with its context filled in

  So the duration of a stream span includes the time to the first byte. `:halted` is `true` when the consumer stopped
  before the end: `Enum.take/2`, a client of `Fil.Plug` that disconnected, or a write that failed, such as an S3 upload
  in parts whose part was refused. An exception of the consumer ends the span with `halted: true` as well, because the
  stream itself is fine. A span has no end if the process that reads the stream is killed, or if an enumeration that
  was suspended (by `Stream.zip/2`, say) is dropped.

  When a stream goes into `Fil.write/4` and the source fails, the write's `:stop` has the source's error, whose `:op`
  and `:path` name the source.
  """
end
