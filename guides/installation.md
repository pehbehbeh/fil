# Installation

This guide adds `Fil` to an application with three disks: uploads on the local disk in development, backups on S3,
and an avatars disk that shares the uploads storage. Production puts everything on S3, and tests keep it in memory.

> #### One way to do it {: .info}
>
> `Fil` has no application config and doesn't care where its disks come from. The setup below is one way to structure
> it, not something `Fil` requires. Rename the module, read the options from somewhere else or pass disks around as
> arguments if that suits your application better.

## Adding the dependency

Add `fil` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fil, "~> 0.1"}
  ]
end
```

Then fetch it:

```bash
mix deps.get
```

In a script or a Livebook, `Mix.install/1` is enough, and you can build disks right away:

```elixir
Mix.install([{:fil, "~> 0.1"}])

disk = Fil.disk(adapter: Fil.Adapter.Local, root: "storage")
```

## A module for your disks

A disk is a plain value, so your application needs a place that builds it. One module with a function per disk works
well. The rest of the code asks it for a disk, and the config decides which backend is behind it:

```elixir
defmodule MyApp.Storage do
  @moduledoc "The disks MyApp stores files on."

  require Logger

  @doc "Files users upload. Browsers load them directly, so they get a content type."
  def uploads do
    :uploads
    |> options()
    |> disk()
    |> Fil.Plugin.ContentType.attach()
  end

  @doc "Avatars, stored under `avatars/` on the uploads disk."
  def avatars do
    :uploads
    |> options()
    |> under("avatars")
    |> disk()
    |> Fil.Plugin.ContentType.attach(default: "image/png")
  end

  @doc "Database dumps. Nobody downloads them in a browser, but every change is logged."
  def backups do
    :backups
    |> options()
    |> disk()
    |> Fil.Plugin.attach(:log, &log/3)
  end

  defp options(name) do
    :my_app
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(name)
  end

  # Builds the disk, and signs its URLs in the application where the config has `signed_urls:`.
  defp disk(opts) do
    {signed_urls, opts} = Keyword.pop(opts, :signed_urls)
    disk = Fil.disk(opts)

    if signed_urls, do: Fil.Plugin.SignedURL.attach(disk, signed_urls), else: disk
  end

  # Moves the root one directory down, and the base URL of signed URLs along with it.
  defp under(opts, dir) do
    opts
    |> Keyword.update(:root, dir, &Path.join(&1, dir))
    |> Keyword.replace_lazy(:signed_urls, &Keyword.update!(&1, :base_url, fn url -> url <> "/" <> dir end))
  end

  defp log(op, next, _opts) do
    result = next.(op)
    Logger.info("backups: #{op.name} #{op.path}")
    result
  end
end
```

Each disk gets its own plugins. `avatars` reuses the options of `uploads` and only moves the root, so an avatar
written as `1.png` is `avatars/1.png` on the uploads disk. That works the same whether `uploads` is a local directory,
a key prefix in an S3 bucket or a memory store, because every adapter takes a `root:`. Where the disk signs URLs in
the application (see [Signed URLs](#signed-urls)), their base URL moves along, so avatar URLs stay inside the uploads
URLs.

`Fil.disk/1` only validates the options and builds a struct (no network, no process), so building the disk on every
call is cheap.

Code that stores files doesn't know which backend it's talking to:

```elixir
def put_avatar(user, png) do
  disk = MyApp.Storage.avatars()
  Fil.write(disk, "#{user.id}.png", png)
end
```

## Configuration

In development, uploads go to a local directory and backups to an S3-compatible server running on your machine
([SeaweedFS](https://github.com/seaweedfs/seaweedfs) or [MinIO](https://github.com/minio/minio), for example):

```elixir
# config/dev.exs
config :my_app, MyApp.Storage,
  uploads: [
    adapter: Fil.Adapter.Local,
    root: "priv/storage/uploads",
    signed_urls: [base_url: "http://localhost:4000/storage/uploads", secret: "a development secret of 32 bytes"]
  ],
  backups: [
    adapter: Fil.Adapter.S3,
    bucket: "my-app-backups",
    endpoint: "http://localhost:8333",
    access_key_id: "dev",
    secret_access_key: "dev"
  ]
```

`signed_urls:` isn't an adapter option. `MyApp.Storage` takes it out and attaches `Fil.Plugin.SignedURL` with it,
see [Signed URLs](#signed-urls). Add the local directory to `.gitignore`:

```text
/priv/storage/
```

Tests keep every disk in memory (see [Testing](#testing)):

```elixir
# config/test.exs
config :my_app, MyApp.Storage,
  uploads: [
    adapter: Fil.Adapter.Memory,
    root: "uploads",
    signed_urls: [base_url: "http://localhost:4002/storage/uploads", secret: "a test secret"]
  ],
  backups: [adapter: Fil.Adapter.Memory, root: "backups"]
```

Production uses S3 for both, set in `config/runtime.exs`, so the credentials are read from the environment when the
release starts instead of being compiled into it:

```elixir
# config/runtime.exs
if config_env() == :prod do
  s3 = [
    adapter: Fil.Adapter.S3,
    region: "eu-central-1",
    access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")
  ]

  config :my_app, MyApp.Storage,
    uploads: Keyword.put(s3, :bucket, "my-app-uploads"),
    backups: Keyword.put(s3, :bucket, "my-app-backups")
end
```

`Fil.Adapter.S3` lists every option, including `root:` for a key prefix inside the bucket.

Keep the disks out of `config/config.exs`. `Config` deep-merges keyword lists, so a local default there would leave
its `root:` in the S3 options of another environment, and `Fil.disk/1` raises on options the adapter doesn't know.

## Signed URLs

A signed URL lets a browser download or upload a file directly, without going through a controller:

```elixir
def avatar_upload_url(user) do
  disk = MyApp.Storage.avatars()
  Fil.signed_url(disk, "#{user.id}.png", method: :put, expires_in: 300)
end
```

On S3, the URL goes to S3. Local and memory disks can't sign URLs, so `Fil.Plugin.SignedURL` signs them (that's the
`signed_urls:` in the development and test config), and `Fil.Plug` serves them from your application. Add it to your
endpoint, above `Plug.Parsers`, at the path of the `base_url:`:

```elixir
# lib/my_app_web/endpoint.ex
plug Fil.Plug, at: "/storage/uploads", disk: &MyApp.Storage.uploads/0

plug Plug.Parsers,
  # ...
```

It answers `GET` and `HEAD` with the file and writes the body of a `PUT`, with a `403` for a URL that expired or was
changed. One plug serves `avatars` too, because its URLs are inside the uploads URLs. In production, `uploads` has no
`signed_urls:`, so its URLs go to S3 and the plug lets every request pass. The line can stay.

Give every disk whose URLs your code signs a `signed_urls:` in development and test, or `Fil.signed_url/3` returns
`{:error, {:unsupported, :signed_url}}` there. `backups` doesn't need one here, because it's on S3 in development too.

To keep a bucket private and serve its files through your application instead, add `signed_urls:` to the production
config as well. Every download and upload then runs through your application, and files are read into memory whole,
so it's only a good fit for small files.

`Fil.Plug` needs [Plug](https://plug.hexdocs.pm), which every Phoenix app already has.

## Public files

`Fil.Plug` can also serve a disk without signed URLs, for files anyone may download, such as avatars:

```elixir
# lib/my_app_web/endpoint.ex
plug Fil.Plug, at: "/avatars", disk: &MyApp.Storage.avatars/0, public: true
```

`GET /avatars/1.png` then returns the avatar from whatever disk `avatars` is in the current environment. Uploads still
need a signed URL. On S3, every download runs through your application and is read into memory whole, so for large or
busy files, a public bucket or a CDN in front of S3 is the better choice in production.

## Testing

`Fil.Adapter.Memory` keeps files in a store that belongs to the test process. Check one out in the setup of every test
that touches files, for example in your `DataCase` or `ConnCase`:

```elixir
setup do
  Fil.Adapter.Memory.checkout()
end
```

Every test starts with an empty store, and the store is gone when the test ends, so there's nothing to clean up and
tests can run with `async: true`. All disks built in the test share its store, so a file written through `avatars` is
visible on `uploads` under `avatars/`, as in production.

`Task`s started by the test find its store on their own, and so do LiveViews started by `Phoenix.LiveViewTest`. Other
processes, such as a GenServer that writes thumbnails, need to be allowed in:

```elixir
setup do
  Fil.Adapter.Memory.checkout()
  Fil.Adapter.Memory.allow(self(), MyApp.Thumbnailer)
end
```

A process without a store raises instead of writing somewhere nobody looks.

Signed URLs work in tests as well. `Phoenix.ConnTest` runs the request in the test process, so `Fil.Plug` finds the
test's store:

```elixir
test "serves the avatar through a signed URL", %{conn: conn} do
  disk = MyApp.Storage.avatars()
  {:ok, avatar} = Fil.write(disk, "1.png", "png")
  {:ok, url} = Fil.signed_url(avatar)

  assert conn |> get(url) |> response(200) == "png"
end
```

The adapters differ only in edge cases, listed in
[Where the adapters differ](Fil.Adapter.html#module-where-the-adapters-differ). A local disk
has real directories and computes checksums instead of storing them, for example, while the memory disk behaves like
S3.
