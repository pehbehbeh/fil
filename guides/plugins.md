# Plugins

Plugins add behaviour to a disk: transform content, rewrite paths, log, cache or handle errors.

A plugin is a callback attached to a disk. It runs on every operation on that disk, before and after the adapter, and
decides for itself which operations it handles. There's no behaviour to implement, so a plugin can be a module or an
anonymous function in a script:

```elixir
disk =
  Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
  |> Fil.attach(:shout, fn op, next, _opts ->
    op |> Fil.Op.update_content(binary: &String.upcase/1) |> next.()
  end)

Fil.write!(disk, "hello.txt", "world")
Fil.read(disk, "hello.txt")
#=> {:ok, "WORLD"}
```

`Fil` ships these plugins:

  * `Fil.Plugin.ContentType`: sets the content type of a write from the file extension
  * `Fil.Plugin.URL`: builds URLs for any disk, served by `Fil.Plug` from your application

## The callback

A plugin callback takes three arguments:

  * `op`: the `Fil.Op` for this call, with the operation name, the path, the content of a write and the call's options
  * `next`: a function that runs the rest of the chain (the plugins attached after this one, then the adapter) and
    returns the op with its `:result` set
  * `opts`: the options the plugin was attached with

Whatever the callback does before `next.(op)` happens on the way in, and whatever it does after happens on the way
back, with the result in `op.result`. The callback returns the op.

Every operation passes through every plugin, so a callback matches on `op.name` (see `t:Fil.Op.name/0` for the
operations) and passes the rest on unchanged:

```elixir
def call(%Fil.Op{name: :write} = op, next, _opts) do
  op |> Fil.Op.update_content(binary: &stamp/1) |> next.()
end

def call(op, next, _opts), do: next.(op)
```

Options given to a single call are validated by `Fil` and are the same with or without plugins, so a plugin can't add
options of its own to `Fil.write/4` and friends.

## Plugin modules

A plugin you share is a module with a public callback:

```elixir
defmodule MyApp.Log do
  require Logger

  def call(op, next, opts) do
    op = next.(op)
    Logger.log(Keyword.get(opts, :level, :debug), "#{op.name} #{op.path}: #{elem(op.result, 0)}")
    op
  end
end
```

A disk lists it in the `:plugins` option of `Fil.disk/1` as `{module, function, opts}`. That's plain data, so the
plugins can come from config along with the adapter options:

```elixir
disk = Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage", plugins: [{MyApp.Log, :call, level: :info}])
```

`Fil.disk/1` attaches each entry under the name of its module, the same as
`Fil.attach(disk, MyApp.Log, {MyApp.Log, :call}, level: :info)`. Options from config reach the callback as they are,
so a callback with options of its own validates them itself. Anonymous functions can't go into `:plugins`, only into
`Fil.attach/4`.

An `attach/2` is a nice addition for code that builds the disk itself, as with
[Req's plugins](https://req.hexdocs.pm/Req.Request.html#module-writing-plugins). It can validate the options right
away:

```elixir
def attach(disk, opts \\ []), do: Fil.attach(disk, __MODULE__, {__MODULE__, :call}, opts)
```

```elixir
disk = Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage") |> MyApp.Log.attach(level: :info)
```

`Fil.Plugin.ContentType` is a complete example of a plugin module.

## Order

The first plugin attached is the outermost one. It sees an operation first on the way in and last on the way back:

```elixir
disk
|> MyApp.Compression.attach()
|> MyApp.Encryption.attach()

# write: compress, then encrypt, then the adapter
# read:  the adapter, then decrypt, then decompress
```

Plugins from the `:plugins` option are attached first, in the order they're listed. Attaching a name that's already
attached replaces its callback in the same position. `Fil.detach/2` removes it.

## Answering without the adapter

A callback that doesn't call `next` ends the chain. It sets the result itself with `Fil.Op.put_result/2`, and neither
the adapter nor the plugins after it run. A cache does this on a hit:

```elixir
def call(%Fil.Op{name: :read} = op, next, opts) do
  case MyApp.Cache.get(opts[:cache], op.path) do
    {:ok, content} -> Fil.Op.put_result(op, {:ok, content})
    :miss -> next.(op)
  end
end
```

## Errors

Errors come back through the chain like any other result, so a callback matches on `op.result` after `next` and can
change it. They're the same structs the caller gets, with the operation and the path already filled in. This one turns
a missing file into an empty one:

```elixir
def call(%Fil.Op{name: :read} = op, next, _opts) do
  case next.(op) do
    %Fil.Op{result: {:error, %Fil.NotFoundError{}}} = op -> Fil.Op.put_result(op, {:ok, ""})
    op -> op
  end
end
```

A callback that answers with an error puts an exception in the result: one of `Fil`'s errors, such as
`%Fil.UnsupportedError{reason: :read_only}`, or its own. `Fil` fills in the operation, the path and the disk of its
own errors. A callback that returns something other than a `Fil.Op`, leaves the result empty or puts anything else in
`{:error, _}` raises `ArgumentError`, because that's a bug in the plugin.

## Content

Change the content of a write with `Fil.Op.update_content/2` and the content of a read with `Fil.Op.update_result/2`,
instead of setting `op.content` or `op.result` directly. Both take a `binary:` function for the whole content and a
`chunk:` function for a piece of it. Content is always whole for now, but streaming is planned, and plugins that use
these functions will keep working when it lands.

## Paths

A plugin may rewrite `op.path` (to put everything under a tenant prefix, for example). The path is normalized again
before the adapter sees it, so a rewritten path can't escape the disk root either: it fails with a
`Fil.InvalidRequestError` whose `:reason` is `:ebadpath`.

## Copies and renames

A `Fil.cp/3` or `Fil.rename/3` within one disk is a single `:cp` or `:rename` operation, with the destination in
`op.dest`. Across two disks, `Fil` reads from the source disk and writes to the destination disk (and deletes the
source after a rename), so each disk's plugins see ordinary reads, writes and deletes.
