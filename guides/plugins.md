# Plugins

Plugins add behaviour to a disk: transform content, rewrite paths, log, cache or handle errors.

A plugin is a callback attached to a disk. It runs on every operation on that disk, before and after the adapter, and
decides for itself which operations it handles. There's no behaviour to implement, so a plugin can be a module or an
anonymous function in a script:

```elixir
disk =
  Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
  |> Fil.attach(:shout, fn op, next, _opts ->
    op |> Fil.Op.update_content(iodata: &String.upcase/1) |> next.()
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
  op |> Fil.Op.update_content(iodata: &stamp/1) |> next.()
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

To log or measure the operations of every disk, attach a handler to the events in `Fil.Telemetry` instead of a
plugin to each disk. `Fil.Telemetry.attach_default_logger/1` logs them. A plugin that emits events of its own uses a
prefix of its own, because names under `[:fil, ...]` are kept for `Fil`.

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

The answer can be content in memory on a read from `Fil.stream/3` too. The caller then gets it as a stream of one
chunk.

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

A content transform can fail with one of `Fil`'s errors too, such as `Fil.ChecksumMismatchError` from a check that
finds the content tampered with. On a read of content in memory, a transform passed to `Fil.Op.update_result/2` that
raises one turns the read into `{:error, error}`, with the operation, the path and the disk filled in. On a stream, the
error is raised to whoever reads it (see [Streams](#streams)). On a write, one raised while the content is read (by a
transform, or by a stream from `Fil.stream/3`) is the write's result. Any other exception propagates as it is.

## Content

Change the content of a write with `Fil.Op.update_content/2` and the content of a read with `Fil.Op.update_result/2`,
instead of setting `op.content` or `op.result` directly. Content is in memory (iodata) or a stream, and these
functions handle both:

```elixir
def call(%Fil.Op{name: :write} = op, next, _opts) do
  op
  |> Fil.Op.update_content(iodata: &String.upcase/1, stream: &Stream.map(&1, fn chunk -> String.upcase(chunk) end))
  |> next.()
end
```

`iodata:` gets content in memory as one binary, and `stream:` gets a stream. Each also covers the other kind when it's
alone:

  * a plugin with only `iodata:` still works on streams: `Fil` collects the stream into memory first (on a read, when
    the caller reads it), which costs memory for large files
  * a plugin with only `stream:` gets content in memory as a stream of one chunk, and `Fil` collects the result again

`Fil.Op.materialize/1` collects a stream too, for plugins that need all of the content for something else, such as a
signature.

A write is a stream when the caller passes one to `Fil.write/4`, and a read is one when it comes from `Fil.stream/3`
(`op.streaming` is `true` then). Both are still `:write` and `:read` operations, so a plugin that transforms content
sees every read and write.

### Streams

A stream is an enumerable of binaries. What a plugin can rely on:

  * chunks come in order, and none is empty
  * their size depends on where the stream comes from (the caller's stream, an upload, the adapter, the network) and
    says nothing about the content: a chunk isn't a line, a record or a multiple of a block size. A transform that
    needs whole lines or blocks buffers them itself
  * a transform returns iodata of any size, including none, so it may change the chunk boundaries. `Fil` drops empty
    chunks before the adapter or the caller sees them. Return output as it's ready, in pieces, rather than holding it
    back, so memory use doesn't grow with the file
  * the functions run lazily, in the process that reads the stream. On a write that's usually the one that called
    `Fil.write/4`, but an HTTP client may read the content in a process of its own (an S3 disk on HTTP/2, see
    `Fil.Adapter.S3`). On a read it's whichever process enumerates the stream from `Fil.stream/3`, which may not be
    the one that called it. A resource that belongs to a process, such as a `:zlib` port, is opened and closed while
    the stream is read, not in the callback
  * a stream from `Fil.stream/3` can be read more than once, and the functions then run again from the start. State
    for one pass goes into the start function of `Stream.transform/5`, not into the callback
  * errors are `Fil`'s error structs, such as `Fil.ChecksumMismatchError` for content that fails a check. On content
    in memory, a transform that raises one turns the read into `{:error, error}`. On a stream, it's raised to whoever
    reads the stream, with the operation, the path and the disk filled in. A write that raises leaves nothing behind

A transform of each chunk on its own is `Stream.map/2`, as in the example above. A transform that keeps state from one
chunk to the next, or adds something after the last one (compression, encryption), builds a new stream with
`Stream.transform/5`, whose start function runs each time the stream is read:

```elixir
def call(%Fil.Op{name: :write} = op, next, _opts) do
  op
  |> Fil.Op.update_content(iodata: &:zlib.gzip/1, stream: &gzip/1)
  |> next.()
end

def call(%Fil.Op{name: :read} = op, next, _opts) do
  op
  |> next.()
  |> Fil.Op.update_result(iodata: &:zlib.gunzip/1, stream: &gunzip/1)
end

def call(op, next, _opts), do: next.(op)

defp gzip(chunks) do
  Stream.transform(
    chunks,
    fn ->
      z = :zlib.open()
      :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
      z
    end,
    fn chunk, z -> {[:zlib.deflate(z, chunk)], z} end,
    fn z -> {[:zlib.deflate(z, [], :finish)], z} end,
    &:zlib.close/1
  )
end
```

`gunzip/1` is the same with `inflateInit/2` and `inflate/2`. Content in memory goes to `stream:` as a stream of one
chunk when there's no `iodata:`, so one function can cover both.

A transform can change the size of the content, so `Fil.Op.update_content/2` drops the `:size` option of the write.
On S3, a stream without a size is uploaded in parts. A plugin that knows the new size declares it again with
`Fil.Op.put_option(op, :size, size)`, so S3 can send the stream in one request.

## Paths

A plugin may rewrite `op.path` (to put everything under a tenant prefix, for example). The path is normalized again
before the adapter sees it, so a rewritten path can't escape the disk root either: it fails with a
`Fil.InvalidRequestError` whose `:reason` is `:ebadpath`.

## Copies and renames

A `Fil.cp/3` or `Fil.rename/3` within one disk is a single `:cp` or `:rename` operation, with the destination in
`op.dest`. Across two disks, `Fil` streams from the source disk and writes the stream to the destination disk (and
deletes the source after a rename), so each disk's plugins see ordinary reads, writes and deletes. In
`Fil.Telemetry`, those operations are nested in a `:cp` or `:rename` event.
