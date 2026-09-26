defmodule Fil.Plugin do
  @moduledoc """
  Plugins add behaviour to a disk: transform content, rewrite paths, log, cache or handle errors.

  A plugin is a function attached to a disk. It runs on every operation on that disk, before and after the adapter, and
  decides for itself which operations it handles. There's no behaviour to implement, so a plugin can be a module or an
  anonymous function in a script:

      iex> disk =
      ...>   Fil.disk(adapter: Fil.Adapter.Memory)
      ...>   |> Fil.Plugin.attach(:shout, fn op, next, _opts ->
      ...>     op |> Fil.Op.update_content(binary: &String.upcase/1) |> next.()
      ...>   end)
      iex> Fil.write!(disk, "hello.txt", "world")
      iex> Fil.read(disk, "hello.txt")
      {:ok, "WORLD"}

  ## The callback

  A plugin callback takes three arguments:

    * `op`: the `Fil.Op` for this call, with the operation name, the path, the content of a write and the call's options
    * `next`: a function that runs the rest of the chain (the plugins attached after this one, then the adapter) and
      returns the op with its `:result` set
    * `opts`: the options given to `attach/4`

  Whatever the callback does before `next.(op)` happens on the way in, and whatever it does after happens on the way
  back, with the result in `op.result`. The callback returns the op.

  Every operation passes through every plugin, so a callback matches on `op.name` and passes the rest on unchanged:

      defp call(%Fil.Op{name: :write} = op, next, _opts) do
        op |> Fil.Op.update_content(binary: &stamp/1) |> next.()
      end

      defp call(op, next, _opts), do: next.(op)

  ## Plugin modules

  A plugin you share is a module with an `attach/2` function that attaches its callback, the same convention as
  [Req's plugins](https://req.hexdocs.pm/Req.Request.html#module-writing-plugins). Its options come from `attach/2` and
  reach the callback on every call:

      defmodule MyApp.Log do
        require Logger

        def attach(disk, opts \\\\ []) do
          Fil.Plugin.attach(disk, :log, &call/3, opts)
        end

        defp call(op, next, opts) do
          op = next.(op)
          Logger.log(Keyword.get(opts, :level, :debug), "\#{op.name} \#{op.path}: \#{elem(op.result, 0)}")
          op
        end
      end

      disk = Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage") |> MyApp.Log.attach(level: :info)

  Options given to a single call are validated by `Fil` and are the same with or without plugins, so a plugin can't add
  options of its own to `Fil.write/4` and friends.

  `Fil` ships one plugin, `Fil.Plugin.ContentType`, which also serves as a complete example.

  ## Order

  The first plugin attached is the outermost one. It sees an operation first on the way in and last on the way back:

      disk
      |> MyApp.Compression.attach()
      |> MyApp.Encryption.attach()

      # write: compress, then encrypt, then the adapter
      # read:  the adapter, then decrypt, then decompress

  Attaching a name that's already attached replaces its callback in the same position. `detach/2` removes it.

  ## Answering without the adapter

  A callback that doesn't call `next` ends the chain. It sets the result itself with `Fil.Op.put_result/2`, and neither
  the adapter nor the plugins after it run. A cache does this on a hit:

      defp call(%Fil.Op{name: :read} = op, next, opts) do
        case MyApp.Cache.get(opts[:cache], op.path) do
          {:ok, content} -> Fil.Op.put_result(op, {:ok, content})
          :miss -> next.(op)
        end
      end

  ## Errors

  Errors come back through the chain like any other result, so a callback matches on `op.result` after `next` and can
  change it. This one turns a missing file into an empty one:

      defp call(%Fil.Op{name: :read} = op, next, _opts) do
        case next.(op) do
          %Fil.Op{result: {:error, :enoent}} = op -> Fil.Op.put_result(op, {:ok, ""})
          op -> op
        end
      end

  A callback that returns something other than a `Fil.Op`, or leaves the result empty, raises `Fil.Error`.

  ## Content

  Change the content of a write with `Fil.Op.update_content/2` and the content of a read with `Fil.Op.update_result/2`,
  instead of setting `op.content` or `op.result` directly. Both take a `binary:` function for the whole content and a
  `chunk:` function for a piece of it. Content is always whole for now, but streaming is planned, and plugins that use
  these functions will keep working when it lands.

  ## Paths

  A plugin may rewrite `op.path` (to put everything under a tenant prefix, for example). The path is normalized again
  before the adapter sees it, so a rewritten path can't escape the disk root either: it fails with
  `{:error, :ebadpath}`.

  ## Copies and renames

  A `Fil.cp/3` or `Fil.rename/3` within one disk is a single `:cp` or `:rename` operation, with the destination in
  `op.dest`. Across two disks, `Fil` reads from the source disk and writes to the destination disk (and deletes the
  source after a rename), so each disk's plugins see ordinary reads, writes and deletes.
  """

  alias Fil.Disk
  alias Fil.Op

  @typedoc "A plugin callback. See the module docs."
  @type callback :: (Op.t(), (Op.t() -> Op.t()), keyword() -> Op.t())

  @doc """
  Attaches a plugin callback to a disk under a name.

  `opts` are passed to the callback on every call. Attaching a name that's already attached replaces the callback and
  its options in the same position.
  """
  @spec attach(Disk.t(), atom(), callback(), keyword()) :: Disk.t()
  def attach(%Disk{plugins: plugins} = disk, name, fun, opts \\ [])
      when is_atom(name) and is_function(fun, 3) and is_list(opts) do
    %{disk | plugins: List.keystore(plugins, name, 0, {name, fun, opts})}
  end

  @doc """
  Removes a plugin from a disk. Removing a name that isn't attached returns the disk unchanged.
  """
  @spec detach(Disk.t(), atom()) :: Disk.t()
  def detach(%Disk{plugins: plugins} = disk, name) when is_atom(name) do
    %{disk | plugins: List.keydelete(plugins, name, 0)}
  end
end
