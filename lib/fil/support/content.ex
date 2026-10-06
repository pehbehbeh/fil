defmodule Fil.Support.Content do
  @moduledoc false

  alias Fil.Support.Sized
  alias Fil.Support.Telemetry

  # Content is iodata, a stream (any other enumerable of iodata) or a local file (`{:file, path}`, which `from_file!/1`
  # turns into a stream). These helpers turn a stream into what adapters, plugins and callers get: non-empty binaries,
  # in order.

  # The chunk size of the stream for `{:file, path}`.
  @chunk_size 65_536

  @doc "Whether `content` is iodata rather than a stream. A list is iodata, even though it's enumerable too."
  @spec iodata?(term()) :: boolean()
  def iodata?(content), do: is_binary(content) or is_list(content)

  @doc "Raises unless `content` can be written: iodata, an enumerable or `{:file, path}`."
  @spec validate!(term()) :: :ok
  def validate!({:file, path}) when is_binary(path), do: :ok

  def validate!(content) do
    if iodata?(content) or Enumerable.impl_for(content) != nil do
      :ok
    else
      raise ArgumentError,
            "expected the content to be iodata, an enumerable of iodata or {:file, path}, got: #{inspect(content)}"
    end
  end

  @doc """
  The stream of `{:file, path}`: a `File.Stream` of bytes, whose size `known_size/1` finds. Any other content is
  returned as it is. A file that doesn't exist, or a directory, raises `File.Error` right away, as `File.stream!/2`
  would once it's read, so nothing runs before it fails. Other read errors (no permission) raise when it's read.
  """
  @spec from_file!(term()) :: iodata() | Enumerable.t()
  def from_file!({:file, path}) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> raise File.Error, reason: :eisdir, action: "stream", path: path
      {:ok, _stat} -> File.stream!(path, @chunk_size)
      {:error, reason} -> raise File.Error, reason: reason, action: "stream", path: path
    end
  end

  def from_file!(content), do: content

  @doc "The chunks of a stream as non-empty binaries. Iodata becomes a list of at most one binary."
  @spec chunks(iodata() | Enumerable.t()) :: Enumerable.t()
  def chunks(%Sized{stream: stream} = sized), do: %{sized | stream: chunks(stream)}

  def chunks(content) do
    if iodata?(content) do
      content
      |> IO.iodata_to_binary()
      |> List.wrap()
      |> Enum.reject(&(&1 == ""))
    else
      content
      |> Stream.map(&IO.iodata_to_binary/1)
      |> Stream.reject(&(&1 == ""))
    end
  end

  @doc "Collects content into one binary."
  @spec to_binary(iodata() | Enumerable.t()) :: binary()
  def to_binary(content) do
    if iodata?(content) do
      IO.iodata_to_binary(content)
    else
      content
      |> chunks()
      |> Enum.into(<<>>)
    end
  end

  @doc """
  The size of a stream that's known before it's read, and the error it raises in `sized/3` when it turns out to have
  another size: a stream from `Fil.stream/3` whose adapter found the size, or a `File.Stream` that reads a file's bytes
  as they are (see `file_size/1` below). `nil` for any other stream.
  """
  @spec known_size(Enumerable.t()) :: {non_neg_integer(), (String.t() -> Exception.t())} | nil
  def known_size(%Sized{size: size, context: context}), do: {size, size_changed(context)}

  def known_size(%File.Stream{} = stream) do
    with size when is_integer(size) <- file_size(stream), do: {size, size_changed([])}
  end

  def known_size(_stream), do: nil

  # A `File.Stream` of chunks of bytes (not lines), on this node, without an encoding, and with no mode that changes
  # what's read (`:compressed`, `:trim_bom`), reads the file from its `:read_offset` to its end. The size is what the
  # file has now; `sized/3` notices if it changes before the stream has been read. A file that can't be found, or isn't
  # a regular file (a device or a pipe, whose size says nothing), has none, and fails the write when it's read. Nor
  # does an empty one: the pseudo-files of `/proc` on Linux are regular files of size 0 that read thousands of bytes.
  defp file_size(%File.Stream{line_or_bytes: bytes, raw: true, node: node, modes: modes, path: path})
       when is_integer(bytes) and node == node() do
    with true <- Enum.all?(modes, &plain_mode?/1),
         {:ok, %File.Stat{type: :regular, size: size}} when size > 0 <- File.stat(path) do
      max(size - read_offset(modes), 0)
    else
      _other -> nil
    end
  end

  defp file_size(_stream), do: nil

  # Modes that don't change the bytes read: `File.stream!/3` adds `:raw`, `:read_ahead` and `:binary` itself, and the
  # others only apply when the stream is written to.
  defp plain_mode?(mode) when mode in [:raw, :binary, :read_ahead, :append, :delayed_write], do: true
  defp plain_mode?({:read_ahead, _size}), do: true
  defp plain_mode?({:delayed_write, _size, _delay}), do: true
  defp plain_mode?({:read_offset, _offset}), do: true
  defp plain_mode?(_mode), do: false

  defp read_offset(modes) do
    case List.keyfind(modes, :read_offset, 0) do
      {:read_offset, offset} -> offset
      nil -> 0
    end
  end

  # The file changed after its size was found. The error has the context of the read that found it, or none, so that
  # the write fills in its own.
  defp size_changed(context) do
    fn _message -> Fil.Support.Error.put_context(%Fil.ConflictError{reason: :size_changed}, context) end
  end

  @doc """
  The chunks of a stream, checked against `size`, which the caller declared or `known_size/1` found, so an adapter never
  finishes a write of the wrong size. Each chunk is passed on only once the next one has arrived, and the last one once
  the stream has ended at exactly `size` bytes. Storage that knows the size (a PutObject with its `content-length`)
  would store the content as soon as it has all of it, so a stream that turns out longer raises before the last chunk
  goes out, and one that ends short raises instead of ending.
  """
  @spec sized(Enumerable.t(), non_neg_integer() | nil, (String.t() -> Exception.t())) :: Enumerable.t()
  def sized(stream, size, mismatch \\ &ArgumentError.exception/1)

  def sized(stream, nil, _mismatch), do: chunks(stream)

  def sized(stream, size, mismatch) do
    stream
    |> chunks()
    |> Stream.transform(
      fn -> {[], 0} end,
      fn chunk, {held, count} ->
        count = count + byte_size(chunk)

        if count > size do
          raise mismatch.("the content has more than #{size} bytes, but the :size option is #{size}")
        end

        {held, {[chunk], count}}
      end,
      fn
        {held, ^size} -> {held, {[], size}}
        {_held, count} -> raise mismatch.("the content has #{count} bytes, but the :size option is #{size}")
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Fills in the context of `Fil`'s errors that `stream` raises while it's enumerated, the same as for errors that are
  returned. What the consumer's reducer raises (a write that reads the stream, and its plugins) passes through
  unchanged, so an error of the destination isn't reported as one of the source.

  With `telemetry`, the metadata of the op, each enumeration of the stream is a `[:fil, :stream]` span
  (`Fil.Telemetry`). The stream's own errors end it with `:exception`, the consumer's with a `:stop` that's `halted`.
  """
  @spec put_context(Enumerable.t(), keyword(), map() | nil) :: Enumerable.t()
  def put_context(stream, context, telemetry \\ nil)

  def put_context(%Sized{stream: stream} = sized, context, telemetry) do
    %{sized | stream: put_context(stream, context, telemetry), context: context}
  end

  def put_context(stream, context, telemetry) do
    fn acc, fun ->
      ref = make_ref()
      span = Telemetry.stream_start(telemetry)
      reduce_with_context(&Enumerable.reduce(stream, &1, consumer(fun, ref)), with_bytes(acc, 0), context, ref, span)
    end
  end

  # The accumulator counts the bytes handed to the consumer, and notes whether it asked to halt: a source may end with
  # `:halted` on its own (`Stream.flat_map/2` does). The consumer's exceptions travel through the stream as a throw
  # tagged with `ref`, with the count, and are raised again as they were once they're out of it.
  defp consumer(fun, ref) do
    fn element, {acc, bytes, _halted} ->
      bytes = bytes + IO.iodata_length(element)

      try do
        fun.(element, acc)
      catch
        kind, reason -> throw({ref, kind, reason, __STACKTRACE__, bytes})
      else
        {command, acc} -> {command, {acc, bytes, command == :halt}}
      end
    end
  end

  defp with_bytes({command, acc}, bytes), do: {command, {acc, bytes, command == :halt}}

  defp reduce_with_context(continuation, acc, context, ref, span) do
    case continuation.(acc) do
      {:suspended, {acc, bytes, _halted}, continuation} ->
        {:suspended, acc, &reduce_with_context(continuation, with_bytes(&1, bytes), context, ref, span)}

      {result, {acc, bytes, halted}} when result in [:done, :halted] ->
        Telemetry.stream_stop(span, bytes, halted)
        {result, acc}
    end
  rescue
    error ->
      error = Fil.Support.Error.put_context(error, context)
      Telemetry.stream_exception(span, :error, error, __STACKTRACE__)
      reraise error, __STACKTRACE__
  catch
    :throw, {^ref, kind, reason, stacktrace, bytes} ->
      Telemetry.stream_stop(span, bytes, true)
      :erlang.raise(kind, reason, stacktrace)

    kind, reason ->
      Telemetry.stream_exception(span, kind, reason, __STACKTRACE__)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end
end
