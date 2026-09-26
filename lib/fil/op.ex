defmodule Fil.Op do
  @moduledoc """
  One call to a `Fil` function, as plugins see it.

  Every operation builds a `%Fil.Op{}` and passes it through the disk's plugins to the adapter. See `Fil.Plugin` for how
  to write a plugin.

    * `:disk`: the `Fil.Disk` the operation runs on
    * `:name`: the operation, `:read`, `:write`, `:stat`, `:ls`, `:rm`, `:rm_rf`, `:cp`, `:rename`, `:url` or
      `:signed_url`
    * `:path`: the normalized path, relative to the disk root
    * `:dest`: the destination path of a `:cp` or `:rename` on the same disk, `nil` otherwise
    * `:content`: the content of a `:write`, `nil` otherwise. Change it with `update_content/2`
    * `:options`: the validated options of the call
    * `:result`: `nil` on the way in, then `{:ok, value}` or `{:error, reason}` with the same value the `Fil` function
      returns. Change a read result with `update_result/2`
    * `:private`: a map for plugins to pass data along
  """

  alias Fil.Disk
  alias Fil.Ref

  @enforce_keys [:disk, :name, :path]
  defstruct [:disk, :name, :path, :dest, :content, :result, options: [], private: %{}]

  @type name :: :read | :write | :stat | :ls | :rm | :rm_rf | :cp | :rename | :url | :signed_url

  @type t :: %__MODULE__{
          disk: Disk.t(),
          name: name(),
          path: Path.t(),
          dest: Path.t() | nil,
          content: iodata() | nil,
          options: keyword(),
          result: {:ok, term()} | {:error, term()} | nil,
          private: map()
        }

  @type transform :: [binary: (binary() -> iodata()), chunk: (binary() -> iodata())]

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

  A plugin that sets the result instead of calling `next` answers the call itself, and the adapter never runs.
  """
  @spec put_result(t(), {:ok, term()} | {:error, term()}) :: t()
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

  Pass `binary:` to transform the whole content at once and `chunk:` to transform it piece by piece:

      Fil.Op.update_content(op, binary: &:zlib.gzip/1)

  Content is always whole for now, so `binary:` runs and gets a binary (iodata is flattened first). Without `binary:`,
  the content is passed to `chunk:` as a single chunk. Once streaming lands, `chunk:` runs on each chunk of a stream,
  and a stream is collected first if there's only `binary:`.
  """
  @spec update_content(t(), transform()) :: t()
  def update_content(%__MODULE__{name: :write, content: content} = op, funs) do
    %{op | content: transform!(content, funs)}
  end

  def update_content(%__MODULE__{} = op, funs) do
    _ = validate_transform!(funs)
    op
  end

  @doc """
  Transforms the content returned by a successful `:read`. Other operations and errors are returned unchanged.

  Takes the same `binary:` and `chunk:` functions as `update_content/2`.
  """
  @spec update_result(t(), transform()) :: t()
  def update_result(%__MODULE__{name: :read, result: {:ok, content}} = op, funs) do
    %{op | result: {:ok, IO.iodata_to_binary(transform!(content, funs))}}
  end

  def update_result(%__MODULE__{} = op, funs) do
    _ = validate_transform!(funs)
    op
  end

  @doc """
  Makes the content of a `:write` whole, for plugins that need all of it at once.

  Content is always whole for now, so this only flattens iodata into a binary. Once streaming lands, it collects a
  stream into memory, so use it only when a plugin can't work chunk by chunk.

      iex> op = %Fil.Op{disk: nil, name: :write, path: "a.txt", content: ["a", ["b"]]}
      iex> Fil.Op.materialize(op).content
      "ab"

  """
  @spec materialize(t()) :: t()
  def materialize(%__MODULE__{name: :write, content: content} = op) do
    %{op | content: IO.iodata_to_binary(content)}
  end

  def materialize(%__MODULE__{} = op), do: op

  defp transform!(content, funs) do
    case validate_transform!(funs) do
      %{binary: fun} -> fun.(IO.iodata_to_binary(content))
      %{chunk: fun} -> fun.(IO.iodata_to_binary(content))
    end
  end

  defp validate_transform!(funs) when is_list(funs) do
    case Keyword.split(funs, [:binary, :chunk]) do
      {[_ | _] = valid, []} ->
        Enum.each(valid, fn
          {_key, fun} when is_function(fun, 1) ->
            :ok

          {key, other} ->
            raise ArgumentError, "expected #{inspect(key)} to be a 1-arity function, got: #{inspect(other)}"
        end)

        Map.new(valid)

      {[], []} ->
        raise ArgumentError, "expected at least one of :binary or :chunk"

      {_valid, unknown} ->
        raise ArgumentError, "unknown transforms #{inspect(Keyword.keys(unknown))}, expected :binary or :chunk"
    end
  end

  ## ------------------------------------------------------------------
  ## Running
  ## ------------------------------------------------------------------

  @doc false
  # Runs the disk's plugins around the adapter call. The first plugin attached is the outermost layer.
  @spec run(t()) :: {:ok, term()} | {:error, term()}
  def run(%__MODULE__{disk: %Disk{plugins: plugins}} = op) do
    chain =
      plugins
      |> Enum.reverse()
      |> Enum.reduce(&adapter/1, fn {name, fun, opts}, next ->
        fn op ->
          op
          |> fun.(next, opts)
          |> plugin_return!(name, op)
        end
      end)

    case chain.(op) do
      %__MODULE__{result: {tag, _value} = result} when tag in [:ok, :error] -> result
      %__MODULE__{result: other} -> raise_error(op, {:bad_plugin_result, other})
    end
  end

  defp plugin_return!(%__MODULE__{} = returned, _name, _op), do: returned
  defp plugin_return!(other, name, op), do: raise_error(op, {:bad_plugin_return, name, other})

  # The end of the chain. The paths are normalized again, so a plugin that rewrites one can't escape the disk root.
  defp adapter(%__MODULE__{} = op) do
    with {:ok, path} <- Fil.Support.Path.normalize(op.path),
         {:ok, dest} <- normalize_dest(op.dest) do
      op = %{op | path: path, dest: dest}

      %{
        op
        | result:
            op
            |> call_adapter()
            |> to_result(op)
      }
    else
      {:error, reason} -> %{op | result: {:error, reason}}
    end
  end

  defp normalize_dest(nil), do: {:ok, nil}
  defp normalize_dest(dest), do: Fil.Support.Path.normalize(dest)

  defp call_adapter(%__MODULE__{disk: %Disk{adapter: {module, state}}} = op), do: call_adapter(op, module, state)

  defp call_adapter(%__MODULE__{name: :write} = op, module, state) do
    module.write(state, op.path, op.content, op.options)
  end

  defp call_adapter(%__MODULE__{name: name} = op, module, state) when name in [:cp, :rename] do
    apply(module, name, [state, op.path, op.dest, op.options])
  end

  # URLs are optional callbacks. An adapter without one leaves it to a plugin.
  defp call_adapter(%__MODULE__{name: name} = op, module, state) when name in [:url, :signed_url] do
    if Code.ensure_loaded?(module) and function_exported?(module, name, 3) do
      apply(module, name, [state, op.path, op.options])
    else
      {:error, {:unsupported, name}}
    end
  end

  # read, stat, ls, rm and rm_rf all take (state, path, opts).
  defp call_adapter(%__MODULE__{name: name} = op, module, state), do: apply(module, name, [state, op.path, op.options])

  # Adapters return a bare `:ok` for mutations. The result is the ref the operation acted on.
  defp to_result(:ok, %__MODULE__{name: name, dest: dest} = op) when name in [:cp, :rename] do
    {:ok, %Ref{disk: op.disk, path: dest}}
  end

  defp to_result(:ok, op), do: {:ok, %Ref{disk: op.disk, path: op.path}}

  defp to_result({:ok, listed}, %__MODULE__{name: :ls, disk: disk}) when is_list(listed) do
    {:ok, Enum.map(listed, fn {path, stat} -> %Ref{disk: disk, path: path, stat: stat} end)}
  end

  defp to_result({:ok, value}, _op), do: {:ok, value}
  defp to_result({:error, reason}, _op), do: {:error, reason}
  defp to_result(other, op), do: raise_error(op, {:bad_adapter_return, other})

  defp raise_error(%__MODULE__{disk: disk, name: name, path: path}, reason) do
    raise Fil.Error, op: name, path: path, adapter: Disk.adapter(disk), reason: reason
  end
end
