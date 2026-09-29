defmodule Fil.Disk do
  @schema NimbleOptions.new!(
            adapter: [
              type: :atom,
              required: true,
              doc: """
              The adapter module. Every option other than `:adapter` and `:plugins` is passed to the adapter, which
              validates it against its own schema.
              """
            ],
            plugins: [
              type: {:list, {:tuple, [:atom, :atom, :keyword_list]}},
              default: [],
              doc: """
              Plugins to attach, in order, so the first one is the outermost. Each is a plugin callback as
              `{module, function, opts}`, attached under the name `module` (see `Fil.attach/4`). They're plain data, so
              the plugins can come from config along with the adapter options:
              `plugins: [{Fil.Plugin.ContentType, :call, default: "text/plain"}]`.
              """
            ]
          )

  @moduledoc """
  A disk is a plain value that describes where files are stored.

  Build one with `Fil.disk/1` (short for `new/1`) and pass it around. There's no global configuration, no registry and
  no process behind it:

      disk = Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage")

  The struct holds the adapter module together with the state its `c:Fil.Adapter.init/1` returned, and the plugins
  attached with `Fil.attach/4` or the `:plugins` option of `new/1`. The adapter state may contain
  credentials, so `%Fil.Disk{}` has a custom `Inspect` implementation that prints only the adapter label:

      iex> inspect(Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil"))
      "#Fil.Disk<local>"

  Refs and errors contain the disk too. Logging them is safe, because logs use `inspect`, but anything that stores the
  raw term (`:erlang.term_to_binary/1`, a crash dump) stores the credentials with it.

  """

  @enforce_keys [:adapter]
  defstruct [:adapter, plugins: []]

  @type t :: %__MODULE__{
          adapter: {module(), term()},
          plugins: [{atom(), Fil.plugin_callback(), keyword()}]
        }

  @typedoc """
  A disk, or a 0-arity function or `{module, function, args}` that returns one. See `resolve/1`.
  """
  @type source :: t() | (-> t()) | {module(), atom(), [term()]}

  @doc """
  Builds a disk. `Fil.disk/1` is the same function.

      iex> Fil.Disk.new(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      #Fil.Disk<local>

  The adapter validates its options here, once. Invalid options raise `ArgumentError` when the disk is built instead of
  failing on first use.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    # Only `:adapter` and `:plugins` are validated here. The adapter validates the rest in its init/1.
    {own_opts, adapter_opts} = Keyword.split(opts, [:adapter, :plugins])
    validated = validate!(own_opts)
    module = adapter_module!(validated[:adapter])

    Enum.reduce(validated[:plugins], %__MODULE__{adapter: {module, init!(module, adapter_opts)}}, fn
      {plugin, function, plugin_opts}, disk -> Fil.attach(disk, plugin, {plugin, function}, plugin_opts)
    end)
  end

  defp validate!(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, validated} -> validated
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  defp init!(module, opts) do
    case module.init(opts) do
      {:ok, state} -> state
      {:error, reason} -> raise ArgumentError, "invalid options for #{inspect(module)}: " <> invalid_options(reason)
    end
  end

  defp invalid_options(%{__exception__: true} = exception), do: Exception.message(exception)
  defp invalid_options(reason), do: inspect(reason)

  defp adapter_module!(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :init, 1) do
      module
    else
      raise ArgumentError, "#{inspect(module)} is not a Fil adapter"
    end
  end

  @doc """
  Returns the disk for a `t:source/0`: the disk itself, the result of a 0-arity function, or the result of
  `{module, function, args}`.

  Integrations such as `Fil.Plug` take their disk in any of these forms and call this each time they need it. A
  function or an MFA can build the disk from runtime config, where a disk in the options would be fixed at compile time
  (plug options, for example, are compiled):

      iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
      iex> Fil.Disk.resolve(disk) == disk
      true
      iex> Fil.Disk.resolve(fn -> disk end) == disk
      true
      iex> Fil.Disk.resolve({Fil, :disk, [[adapter: Fil.Adapter.Memory]]})
      #Fil.Disk<memory>

  Raises `ArgumentError` when the function returns something other than a disk, or `source` is none of the three.
  """
  @spec resolve(source()) :: t()
  def resolve(%__MODULE__{} = disk), do: disk
  def resolve(fun) when is_function(fun, 0), do: check_resolved!(fun.(), fun)

  def resolve({module, function, args} = mfa) when is_atom(module) and is_atom(function) and is_list(args) do
    module
    |> apply(function, args)
    |> check_resolved!(mfa)
  end

  def resolve(source) do
    raise ArgumentError,
          "expected a Fil.Disk, or a 0-arity function or {module, function, args} that returns one, got: " <>
            inspect(source)
  end

  defp check_resolved!(%__MODULE__{} = disk, _source), do: disk

  defp check_resolved!(other, source) do
    raise ArgumentError, "expected #{inspect(source)} to return a Fil.Disk, got: #{inspect(other)}"
  end

  @doc """
  Returns the adapter module backing `disk`.

      iex> Fil.Disk.adapter(Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil"))
      Fil.Adapter.Local

  """
  @spec adapter(t()) :: module()
  def adapter(%__MODULE__{adapter: {module, _state}}), do: module

  @doc """
  A short, human readable label for the disk's adapter.

  Used by the `Inspect` implementations of `Fil.Disk` and `Fil.Ref`.

      iex> Fil.Disk.label(Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil"))
      "local"

  """
  @spec label(t()) :: String.t()
  def label(%__MODULE__{adapter: {module, _state}}), do: label(module)

  @spec label(module()) :: String.t()
  def label(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  rescue
    # Erlang modules and other non-Elixir atoms
    ArgumentError -> inspect(module)
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(disk, _opts) do
      concat(["#Fil.Disk<", Fil.Disk.label(disk), ">"])
    end
  end
end
