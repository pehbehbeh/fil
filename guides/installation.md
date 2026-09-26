# Installation

This guide sets up `Fil` in an application with two disks, `uploads` and `backups`. They're local directories in
development, in memory in tests and S3 buckets in production.

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

In a script or a Livebook, `Mix.install/1` is enough:

```elixir
Mix.install([{:fil, "~> 0.1"}])

disk = Fil.disk(adapter: Fil.Adapter.Local, root: "storage")
```

## A module for your disks

A disk is a plain value, so your application needs a place that builds it. One function per disk works well:

```elixir
defmodule MyApp.Storage do
  @moduledoc "The disks MyApp stores files on."

  @doc "Returns the uploads disk."
  def uploads do
    disk_from_config(:uploads)
    |> Fil.Plugin.ContentType.attach()
  end

  @doc "Returns the backups disk."
  def backups do
    disk_from_config(:backups)
  end

  defp disk_from_config(name) do
    Application.fetch_env!(:my_app, __MODULE__)
    |> Keyword.fetch!(name)
    |> Fil.disk()
  end
end
```

Plugins that every environment needs are attached here. `Fil.Plugin.ContentType` sets the content type from the file
extension, so browsers can display uploads. Plugins that only some environments need go into the config instead (see
[Signed URLs](#signed-urls)).

Building a disk only validates the options (no network, no process), so it's fine to build it on every call.

The rest of the application doesn't know which storage is behind a disk:

```elixir
disk = MyApp.Storage.uploads()
Fil.write(disk, "avatars/#{user.id}.png", png)
```

`Fil` doesn't need this module. It has no application config of its own, so read the options from anywhere you like.

## Configuration

Development stores files in local directories:

```elixir
# config/dev.exs
config :my_app, MyApp.Storage,
  uploads: [adapter: Fil.Adapter.Local, root: "priv/storage/uploads"],
  backups: [adapter: Fil.Adapter.Local, root: "priv/storage/backups"]
```

Add the directory to `.gitignore`:

```text
/priv/storage/
```

Tests keep files in memory (see [Testing](#testing)):

```elixir
# config/test.exs
config :my_app, MyApp.Storage,
  uploads: [adapter: Fil.Adapter.Memory, root: "uploads"],
  backups: [adapter: Fil.Adapter.Memory, root: "backups"]
```

Production uses S3. Put it in `config/runtime.exs`, so the credentials are read from the environment when the release
starts:

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
    uploads: s3 ++ [bucket: "my-app-uploads"],
    backups: s3 ++ [bucket: "my-app-backups"]
end
```

`Fil.Adapter.S3` lists every option. Keep the disks out of `config/config.exs`: `Config` merges keyword lists, so a
`root:` set there would end up in the S3 options too, and `Fil.disk/1` raises on options the adapter doesn't know.

## Signed URLs

A signed URL lets a browser download or upload a file directly:

```elixir
disk = MyApp.Storage.uploads()
Fil.signed_url(disk, "avatars/1.png", method: :put, expires_in: 300)
```

S3 signs its own URLs. Local and memory disks can't, so `Fil.Plugin.URL` signs them and `Fil.Plug` serves them from
your application. Production doesn't need the plugin, so it goes into the development and test config. Each entry
under `plugins:` names the plugin's callback and its options, and `Fil.disk/1` attaches them before the storage module
attaches its own:

```elixir
# config/dev.exs
uploads: [
  adapter: Fil.Adapter.Local,
  root: "priv/storage/uploads",
  plugins: [
    {Fil.Plugin.URL, :call, base_url: "http://localhost:4000/uploads", secret: "a development secret of 32 bytes"}
  ]
]
```

Then serve the URLs in your endpoint, above `Plug.Parsers`, at the path of `base_url:`:

```elixir
# lib/my_app_web/endpoint.ex
plug Fil.Plug, at: "/uploads", disk: &MyApp.Storage.uploads/0
```

In production, `uploads` has no `Fil.Plugin.URL`, so its URLs go to S3 and the plug lets every request pass.
`Fil.Plug` also serves public files without a signature, see its documentation.

## Testing

`Fil.Adapter.Memory` keeps files in a store that belongs to the test process. Check one out in every test that touches
files, for example in your `DataCase` or `ConnCase`:

```elixir
setup do
  Fil.Adapter.Memory.checkout()
end
```

Every test starts with an empty store, so tests can run with `async: true` and there's nothing to clean up. `Task`s
and LiveViews started by the test use its store too, and so does `Fil.Plug` in a `Phoenix.ConnTest` request. Any other
process has to be allowed in:

```elixir
Fil.Adapter.Memory.allow(self(), MyApp.Thumbnailer)
```

The adapters differ only in edge cases, listed in
[Where the adapters differ](Fil.Adapter.html#module-where-the-adapters-differ).
