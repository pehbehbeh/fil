defmodule Fil.Op do
  @moduledoc """
  One call to a `Fil` function, as plugins see it.

  Every operation builds a `%Fil.Op{}` and passes it through the disk's plugins to the adapter. See the
  [Plugins guide](plugins.md) for how to write a plugin.

    * `:disk`: the `Fil.Disk` the operation runs on
    * `:name`: the operation, `:read`, `:write`, `:stat`, `:ls`, `:rm`, `:rm_rf`, `:cp`, `:rename`, `:url` or
      `:signed_url`
    * `:path`: the normalized path, relative to the disk root
    * `:dest`: the destination path of a `:cp` or `:rename` on the same disk, `nil` otherwise
    * `:content`: the content of a `:write`, `nil` otherwise: iodata, or a stream of it. Change it with
      `update_content/2`
    * `:streaming`: `true` for a `:read` from `Fil.stream/3`, whose result is a stream instead of a binary
    * `:options`: the validated options of the call
    * `:result`: `nil` on the way in, then `{:ok, value}` or `{:error, exception}` with the same value the `Fil`
      function returns. Change a read result with `update_result/2`
    * `:private`: a map for plugins to pass data along
  """

  alias Fil.Disk
  alias Fil.Ref
  alias Fil.Support.Content
  alias Fil.Support.Sized

  @enforce_keys [:disk, :name, :path]
  defstruct [:disk, :name, :path, :dest, :content, :result, streaming: false, options: [], private: %{}]

  @type name :: :read | :write | :stat | :ls | :rm | :rm_rf | :cp | :rename | :url | :signed_url

  @type t :: %__MODULE__{
          disk: Disk.t(),
          name: name(),
          path: Path.t(),
          dest: Path.t() | nil,
          content: iodata() | Enumerable.t() | nil,
          streaming: boolean(),
          options: keyword(),
          result: {:ok, term()} | {:error, Exception.t()} | nil,
          private: map()
        }

  @type transform :: [iodata: (binary() -> iodata()), stream: (Enumerable.t() -> Enumerable.t())]

  ## ------------------------------------------------------------------
  ## Options, results and private data
  ## ------------------------------------------------------------------

  @doc """
  Returns an option of the call.

      iex> op = %Fil.Op{disk: nil, name: :write, path: "a.txt", options: [content_type: "text/plain"]}
      iex> Fil.Op.get_option(op, :content_type)
      "text/plain"
      iex> Fil.Op.get_option(op, :missing, :default)
      :default

  """
  @spec get_option(t(), atom(), term()) :: term()
  def get_option(%__MODULE__{options: options}, key, default \\ nil) when is_atom(key) do
    Keyword.get(options, key, default)
  end

  @doc """
  Sets an option before the adapter sees it.

      iex> op = %Fil.Op{disk: nil, name: :write, path: "a.txt", options: [content_type: "text/plain"]}
      iex> op |> Fil.Op.put_option(:content_type, "text/csv") |> Fil.Op.get_option(:content_type)
      "text/csv"

  """
  @spec put_option(t(), atom(), term()) :: t()
  def put_option(%__MODULE__{options: options} = op, key, value) when is_atom(key) do
    %{op | options: Keyword.put(options, key, value)}
  end

  @doc """
  Sets an option unless the call already has it.

      iex> op = %Fil.Op{disk: nil, name: :write, path: "a.txt", options: [content_type: "text/plain"]}
      iex> op |> Fil.Op.put_new_option(:content_type, "text/csv") |> Fil.Op.get_option(:content_type)
      "text/plain"

  """
  @spec put_new_option(t(), atom(), term()) :: t()
  def put_new_option(%__MODULE__{options: options} = op, key, value) when is_atom(key) do
    %{op | options: Keyword.put_new(options, key, value)}
  end

  @doc """
  Sets the result.

  A plugin that sets the result instead of calling `next` answers the call itself, and the adapter never runs. An error
  is an exception: one of `Fil`'s (see [Errors](Fil.Adapter.html#module-errors)) or the plugin's own. `Fil` fills in
  the `:op`, `:path` and `:disk` of its own errors where the plugin left them `nil`.
  """
  @spec put_result(t(), {:ok, term()} | {:error, Exception.t()}) :: t()
  def put_result(%__MODULE__{} = op, {tag, _value} = result) when tag in [:ok, :error] do
    %{op | result: result}
  end

  @doc """
  Returns a private value.

      iex> op = %Fil.Op{disk: nil, name: :read, path: "a.txt"}
      iex> Fil.Op.get_private(op, :seen, false)
      false

  """
  @spec get_private(t(), term(), term()) :: term()
  def get_private(%__MODULE__{private: private}, key, default \\ nil), do: Map.get(private, key, default)

  @doc """
  Stores a private value, for a later plugin or for the way back.

      iex> op = %Fil.Op{disk: nil, name: :read, path: "a.txt"}
      iex> op |> Fil.Op.put_private(:seen, true) |> Fil.Op.get_private(:seen)
      true

  """
  @spec put_private(t(), term(), term()) :: t()
  def put_private(%__MODULE__{private: private} = op, key, value) do
    %{op | private: Map.put(private, key, value)}
  end

  ## ------------------------------------------------------------------
  ## Content
  ## ------------------------------------------------------------------

  @doc """
  Transforms the content of a `:write`. Other operations are returned unchanged.

  The content is iodata or a stream, and each has its transform:

      Fil.Op.update_content(op, iodata: &:zlib.gzip/1, stream: &MyApp.Gzip.stream/1)

    * `iodata:` gets all of the content as one binary and returns iodata. Without `stream:`, it gets a stream too:
      `Fil` collects the stream into memory first
    * `stream:` gets the stream, an enumerable of binaries, and returns an enumerable of iodata. A transform of each
      chunk on its own is `&Stream.map(&1, fun)`. Without `iodata:`, it gets content in memory too, as a stream of one
      chunk (none if it's empty), and the result is collected again

  The [Plugins guide](plugins.md#streams) describes what a chunk is. A transform drops the `:size` option of the
  write, because the size can change. A plugin that knows the new size declares it again with
  `put_option(op, :size, size)`.
  """
  @spec update_content(t(), transform()) :: t()
  def update_content(%__MODULE__{name: :write, content: content} = op, funs) do
    funs = validate_transform!(funs)

    content = if Content.iodata?(content), do: transform_iodata(content, funs), else: transform_stream(content, funs)

    drop_size(%{op | content: content})
  end

  def update_content(%__MODULE__{} = op, funs) do
    _ = validate_transform!(funs)
    op
  end

  @doc """
  Transforms the content returned by a successful `:read`. Other operations and errors are returned unchanged.

  Takes the same `iodata:` and `stream:` functions as `update_content/2`. The result of `Fil.stream/3` is a stream, and
  the transforms run when the caller reads it. With only `iodata:`, the stream is collected then too.

  A transform that raises one of `Fil`'s errors, such as `Fil.ChecksumMismatchError` for content that fails a check,
  turns a read that returns a binary into that error. On a stream, the error is raised when the caller reads it, with
  the operation, the path and the disk filled in.
  """
  @spec update_result(t(), transform()) :: t()
  def update_result(%__MODULE__{name: :read, result: {:ok, content}} = op, funs) do
    funs = validate_transform!(funs)

    if Content.iodata?(content) do
      %{op | result: transform_iodata_result(content, funs)}
    else
      %{op | result: {:ok, transform_result_stream(content, funs)}}
    end
  end

  def update_result(%__MODULE__{} = op, funs) do
    _ = validate_transform!(funs)
    op
  end

  # A transform that fails with one of `Fil`'s errors (a decryption that finds the content tampered with, say) turns
  # the read into that error. A stream raises it instead, when it's read.
  defp transform_iodata_result(content, funs) do
    binary =
      content
      |> transform_iodata(funs)
      |> IO.iodata_to_binary()

    {:ok, binary}
  rescue
    error -> transform_error(error, __STACKTRACE__)
  end

  @doc """
  Collects the content of a `:write` into one binary, for plugins that need all of it at once.

  Iodata is flattened into a binary. A stream is collected into memory, so use this only when a plugin can't work
  chunk by chunk.

      iex> op = %Fil.Op{disk: nil, name: :write, path: "a.txt", content: ["a", ["b"]]}
      iex> Fil.Op.materialize(op).content
      "ab"

  """
  @spec materialize(t()) :: t()
  def materialize(%__MODULE__{name: :write, content: content} = op) do
    %{op | content: Content.to_binary(content)}
  end

  def materialize(%__MODULE__{} = op), do: op

  defp transform_iodata(content, funs) do
    binary = IO.iodata_to_binary(content)

    case funs do
      %{iodata: fun} ->
        fun.(binary)

      %{stream: fun} ->
        binary
        |> Content.chunks()
        |> fun.()
        |> Enum.to_list()
    end
  end

  defp transform_stream(stream, funs) do
    chunks = Content.chunks(stream)

    case funs do
      %{stream: fun} ->
        fun.(chunks)

      %{iodata: fun} ->
        chunks
        |> Enum.into(<<>>)
        |> fun.()
    end
  end

  # A read stream stays lazy, so a transform that needs all of the content collects it when the caller reads.
  defp transform_result_stream(stream, funs) do
    case funs do
      %{stream: _fun} -> transform_stream(stream, funs)
      %{iodata: fun} -> Stream.flat_map([stream], &[collect(&1, fun)])
    end
  end

  defp collect(stream, fun) do
    stream
    |> Content.to_binary()
    |> fun.()
    |> IO.iodata_to_binary()
  end

  # `Fil`'s errors are the exceptions with an operation, a path and a disk. Anything else is a bug in the transform.
  defp transform_error(%{op: _, path: _, disk: _} = error, _stacktrace), do: {:error, error}
  defp transform_error(error, stacktrace), do: reraise(error, stacktrace)

  defp drop_size(%__MODULE__{options: options} = op), do: %{op | options: Keyword.delete(options, :size)}

  defp validate_transform!(funs) when is_list(funs) do
    case Keyword.split(funs, [:iodata, :stream]) do
      {[_ | _] = valid, []} ->
        Enum.each(valid, fn
          {_key, fun} when is_function(fun, 1) ->
            :ok

          {key, other} ->
            raise ArgumentError, "expected #{inspect(key)} to be a 1-arity function, got: #{inspect(other)}"
        end)

        Map.new(valid)

      {[], []} ->
        raise ArgumentError, "expected at least one of :iodata or :stream"

      {_valid, unknown} ->
        raise ArgumentError,
              "unknown transforms #{inspect(Keyword.keys(unknown))}, expected :iodata or :stream"
    end
  end

  ## ------------------------------------------------------------------
  ## Running
  ## ------------------------------------------------------------------

  @doc false
  # Runs the disk's plugins around the adapter call. The first plugin attached is the outermost layer.
  #
  # Errors get their context from `caller`, the op as the caller made it, not from the op a plugin may have rewritten:
  # `error.path` is the path the caller passed, so `Fil.ref(error.disk, error.path)` is a ref to the same file.
  @spec run(t()) :: {:ok, term()} | {:error, Exception.t()}
  def run(%__MODULE__{disk: %Disk{plugins: plugins}} = caller) do
    chain =
      plugins
      |> Enum.reverse()
      |> Enum.reduce(&adapter(&1, caller), fn {name, callback, opts}, next ->
        fn op ->
          callback
          |> call_plugin(op, next, opts)
          |> plugin_return!(name, caller)
        end
      end)

    caller
    |> run_chain(chain)
    |> put_stream_context(caller)
  end

  # A write reads its content during the chain, and a `Fil` error raised meanwhile (by a stream from `Fil.stream/3`, or
  # by a plugin's transform) is the write's result. An error from a source stream keeps the source's context, one
  # without context gets the write's. Anything else propagates.
  defp run_chain(%__MODULE__{name: :write} = caller, chain) do
    chain.(caller).result
  rescue
    error ->
      with {:error, error} <- transform_error(error, __STACKTRACE__), do: {:error, put_context(error, caller)}
  end

  defp run_chain(caller, chain), do: chain.(caller).result

  # Errors a plugin's transform raises while the caller reads a stream get the caller's context too, the same as the
  # adapter's (see `to_result/3`).
  defp put_stream_context({:ok, content}, %__MODULE__{name: :read, streaming: true} = caller) do
    if Content.iodata?(content), do: {:ok, content}, else: {:ok, Content.put_context(content, context(caller))}
  end

  defp put_stream_context(result, _caller), do: result

  defp context(%__MODULE__{name: name, path: path, disk: disk}), do: [op: name, path: path, disk: disk]

  defp call_plugin({module, function}, op, next, opts), do: apply(module, function, [op, next, opts])
  defp call_plugin(fun, op, next, opts), do: fun.(op, next, opts)

  # A plugin's result goes up the chain with its context filled in, so the plugins above see what the caller will see.
  defp plugin_return!(%__MODULE__{result: {:ok, _value}} = returned, _name, _caller), do: returned

  defp plugin_return!(%__MODULE__{result: {:error, %{__exception__: true} = error}} = returned, _name, caller) do
    %{returned | result: {:error, put_context(error, caller)}}
  end

  defp plugin_return!(%__MODULE__{result: {:error, reason}}, name, _caller) do
    raise ArgumentError,
          "the plugin #{inspect(name)} returned {:error, #{inspect(reason)}}, but an error must be an exception, " <>
            "such as %Fil.NotFoundError{}"
  end

  defp plugin_return!(%__MODULE__{result: other}, name, _caller) do
    raise ArgumentError, "the plugin #{inspect(name)} returned an op without a result, got: #{inspect(other)}"
  end

  defp plugin_return!(other, name, _caller) do
    raise ArgumentError, "the plugin #{inspect(name)} must return a %Fil.Op{}, got: #{inspect(other)}"
  end

  # The end of the chain. The paths are normalized again, so a plugin that rewrites one can't escape the disk root.
  defp adapter(%__MODULE__{} = op, caller) do
    with {:ok, path} <- Fil.Support.Path.normalize(op.path),
         {:ok, dest} <- normalize_dest(op.dest) do
      op = %{op | path: path, dest: dest}

      %{
        op
        | result:
            op
            |> call_adapter()
            |> to_result(op, caller)
      }
    else
      {:error, :ebadpath} -> %{op | result: {:error, put_context(%Fil.InvalidRequestError{reason: :ebadpath}, caller)}}
    end
  end

  defp normalize_dest(nil), do: {:ok, nil}
  defp normalize_dest(dest), do: Fil.Support.Path.normalize(dest)

  defp call_adapter(%__MODULE__{disk: %Disk{adapter: {module, state}}} = op), do: call_adapter(op, module, state)

  # A stream reaches the adapter as non-empty binaries, checked against the `:size` the caller declared.
  defp call_adapter(%__MODULE__{name: :write, content: content} = op, module, state) do
    content = if Content.iodata?(content), do: content, else: Content.sized(content, op.options[:size])

    module.write(state, op.path, content, op.options)
  end

  # `stream/3` is optional. Without it, the adapter reads the whole file and the stream is that one chunk.
  defp call_adapter(%__MODULE__{name: :read, streaming: true} = op, module, state) do
    if Code.ensure_loaded?(module) and function_exported?(module, :stream, 3) do
      module.stream(state, op.path, op.options)
    else
      with {:ok, content} <- module.read(state, op.path, op.options), do: {:ok, [content], byte_size(content)}
    end
  end

  defp call_adapter(%__MODULE__{name: name} = op, module, state) when name in [:cp, :rename] do
    apply(module, name, [state, op.path, op.dest, op.options])
  end

  # URLs are optional callbacks. An adapter without one leaves it to a plugin.
  defp call_adapter(%__MODULE__{name: name} = op, module, state) when name in [:url, :signed_url] do
    if Code.ensure_loaded?(module) and function_exported?(module, name, 3) do
      apply(module, name, [state, op.path, op.options])
    else
      {:error, %Fil.UnsupportedError{reason: :no_callback}}
    end
  end

  # read, stat, ls, rm and rm_rf all take (state, path, opts).
  defp call_adapter(%__MODULE__{name: name} = op, module, state), do: apply(module, name, [state, op.path, op.options])

  # Adapters return a bare `:ok` for mutations. The result is the ref the operation acted on.
  defp to_result(:ok, %__MODULE__{name: name, dest: dest} = op, _caller) when name in [:cp, :rename] do
    {:ok, %Ref{disk: op.disk, path: dest}}
  end

  defp to_result(:ok, op, _caller), do: {:ok, %Ref{disk: op.disk, path: op.path}}

  defp to_result({:ok, listed}, %__MODULE__{name: :ls, disk: disk}, _caller) when is_list(listed) do
    {:ok, Enum.map(listed, fn {path, stat} -> %Ref{disk: disk, path: path, stat: stat} end)}
  end

  # Errors raised while the caller reads the stream get the same context as returned ones. A size the adapter found
  # stays with its stream (`Fil.Support.Sized`).
  defp to_result({:ok, stream, size}, %__MODULE__{name: :read, streaming: true} = op, caller) when is_integer(size) do
    to_result({:ok, %Sized{stream: stream, size: size}}, op, caller)
  end

  defp to_result({:ok, stream, nil}, %__MODULE__{name: :read, streaming: true} = op, caller) do
    to_result({:ok, stream}, op, caller)
  end

  defp to_result({:ok, stream}, %__MODULE__{name: :read, streaming: true}, caller) do
    {:ok, Content.put_context(stream, context(caller))}
  end

  defp to_result({:ok, value}, _op, _caller), do: {:ok, value}

  # An adapter that failed on the destination of a copy says so with `path: dest`, in its own (possibly rewritten)
  # terms, so that's translated back to the caller's destination.
  defp to_result({:error, %{__exception__: true} = error}, %__MODULE__{dest: dest}, caller) when dest != nil do
    error = if Map.get(error, :path) == dest, do: %{error | path: caller.dest}, else: error
    {:error, put_context(error, caller)}
  end

  defp to_result({:error, %{__exception__: true} = error}, _op, caller), do: {:error, put_context(error, caller)}

  defp to_result(other, op, _caller) do
    raise ArgumentError,
          "#{inspect(Disk.adapter(op.disk))}.#{op.name} must return :ok, {:ok, value} or {:error, exception}, " <>
            "got: #{inspect(other)}"
  end

  defp put_context(error, %__MODULE__{disk: disk, name: name, path: path}) do
    Fil.Support.Error.put_context(error, op: name, path: path, disk: disk)
  end
end
