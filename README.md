# Fil

[![License](https://img.shields.io/hexpm/l/fil.svg)](https://github.com/pehbehbeh/fil/blob/main/LICENSE)
[![Version](https://img.shields.io/hexpm/v/fil.svg)](https://hex.pm/packages/fil)
[![Hex Docs](https://img.shields.io/badge/documentation-gray.svg)](https://fil.hexdocs.pm)

`Fil` is a pluggable file storage abstraction for Elixir.

## Table of Contents

- [Features and goals](#features-and-goals)
- [Concepts](#concepts)
- [Usage](#usage)
- [Development](#development)
- [Acknowledgments](#acknowledgments)

> [!NOTE]
>
> `Fil` is in early development, and the API may still change a lot.

<!-- MDOC -->

## Features and goals

- **Many storage backends behind one API.** `Fil` aims to be a solid file abstraction that behaves the same on every
  backend. Local disk, S3 (including S3-compatible stores) and an in-memory disk for tests are there today. The
  in-memory disk keeps a store per test process, so tests can run with `async: true`. Azure Blob Storage, Google Cloud
  Storage, SFTP and many more are possible. `cp` and `rename` copy and move files between disks with the same calls.
- **Lightweight, [Req](https://github.com/wojtekmach/req)-like API.** A disk is a plain value: no application config,
  no registry, nothing to add to your supervision tree. That keeps `Fil` usable in a script or a Livebook with a single
  `Mix.install/1`, and the code stays functional: build a disk, pass it around, attach things to it.
- **Pluggable.** Anything that isn't about where files are stored belongs in a
  [plugin](https://fil.hexdocs.pm/Fil.Plugin.html) attached to a disk. Plugins see every operation on it, for example
  to set content types or to log. A trash can, encryption, compression or caching could follow.
- **Few dependencies.** At runtime, `Fil` needs only [Req](https://github.com/wojtekmach/req),
  [NimbleOptions](https://github.com/dashbitco/nimble_options) and [MIME](https://github.com/elixir-plug/mime) (and
  Plug for `Fil.Plug`, as an optional dependency). Cloud adapters use Req for HTTP and request signing, and upcoming
  ones (Google Cloud Storage, Azure) should too, instead of each bringing its own client or SDK. Timeouts, proxies and
  connection pools for S3 are set per disk, as Req options.
- **Signed and public URLs.** Every disk returns signed GET and PUT URLs. S3 serves its own, and for any other disk,
  [`Fil.Plugin.SignedURL`](https://fil.hexdocs.pm/Fil.Plugin.SignedURL.html) signs them and
  [`Fil.Plug`](https://fil.hexdocs.pm/Fil.Plug.html) serves them from your application. With `public: true`,
  `Fil.Plug` serves any disk over HTTP, like `Plug.Static`.
- **Safe writes and paths.** Create-if-absent writes with `if_none_match: :any` are atomic on local disk and on AWS
  S3. With checksums, S3 rejects an upload that doesn't match, and reads can verify it. Paths are checked against the
  disk root, so a `../` in user input can't climb out of it.

## Concepts

`Fil` uses the names of Elixir's `File` module (`read`, `write`, `stat`, `ls`, `cp`, `rename`, `rm`, `rm_rf`). Every
function that can fail returns `{:ok, result}` or `{:error, reason}`.

### Disks

A disk says where files are stored: an adapter and its options. It's a plain value, so there's no application config
and nothing to add to your supervision tree (`Fil` starts one process of its own, for the Memory adapter). Every
function takes a disk as its first argument and a path relative to the disk's root:

```elixir
disk = Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage")

{:ok, _} = Fil.write(disk, "hello.txt", "World")

Fil.read(disk, "hello.txt")
#=> {:ok, "World"}
```

### Refs

A `Fil.Ref` is a single value for a file on a disk, built with `Fil.ref/2`. Every function that takes a disk and a
path as two arguments also takes a ref as one argument in their place:

```elixir
hello = Fil.ref(disk, "hello.txt")
#=> #Fil.Ref<local:hello.txt>

{:ok, _} = Fil.write(hello, "World")

Fil.read(hello)
#=> {:ok, "World"}
```

Actions on files return the ref they acted on, which keeps cross-disk code short:

```elixir
with {:ok, report} <- Fil.write(s3, "reports/q3.pdf", pdf),
     {:ok, _backup} <- Fil.cp(report, Fil.ref(local, "backups/q3.pdf")) do
  {:ok, report}
end
```

The bang variants return the ref itself instead of `{:ok, ref}`, so you can pipe one call into the next:

```elixir
disk
|> Fil.write!("hello.txt", "World")
|> Fil.cp!("backup/hello.txt")
|> Fil.read!()
#=> "World"
```

### Plugins

Plugins attach to a disk and see every operation on it. `Fil` ships one that sets the content type from the file
extension, so S3 serves `reports/q3.pdf` as `application/pdf`:

```elixir
s3 =
  Fil.disk(adapter: Fil.Adapter.S3, bucket: "my-bucket", region: "eu-central-1")
  |> Fil.Plugin.ContentType.attach()

{:ok, report} = Fil.write(s3, "reports/q3.pdf", pdf)
```

Your own plugin is a function. It gets the operation, calls `next` to run the rest, and returns the result:

```elixir
local =
  Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage")
  |> Fil.Plugin.attach(:log, fn op, next, _opts ->
    IO.puts("#{op.name} #{op.path}")
    next.(op)
  end)
```

[`Fil.Plugin`](https://fil.hexdocs.pm/Fil.Plugin.html) explains how to write plugins: matching on operations,
changing content, handling errors and answering without the adapter.

### Semantics

The names come from `File`, but the semantics follow the object store model, on every backend:

- `write` creates missing parent directories
- `rm` on a missing file succeeds
- `ls` on a missing directory returns an empty list
- paths are always relative to the disk root, and `.` is the root
- a path that climbs above the root fails with `{:error, :ebadpath}`

The [contract in `Fil.Adapter`](https://fil.hexdocs.pm/Fil.Adapter.html#module-contract) lists every difference from
`File`.

### Errors

Backend failures are mapped onto POSIX atoms where one fits (`:enoent`, `:eacces`, `:eisdir`). Apart from those:

  * `{:unsupported, op}`: the adapter can't do this at all
  * `:precondition_failed`: an `if_none_match: :any` write found the file already there
  * `:checksum_mismatch`: the content doesn't match its checksum
  * `:ebadpath`: the path escapes the disk root
  * `%Fil.TransportError{}`: the backend couldn't be reached

Every function that can fail has a bang variant that returns the bare result and raises `Fil.Error` instead.

## Usage

Add `fil` to your dependencies:

```elixir
def deps do
  [
    {:fil, "~> 0.1"}
  ]
end
```

The [installation guide](guides/installation.md) sets `Fil` up in an application, with local disks in development and
tests and S3 in production.

Build one disk per storage backend:

```elixir
local = Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage")

s3 =
  Fil.disk(
    adapter: Fil.Adapter.S3,
    bucket: "my-bucket",
    region: "eu-central-1",
    access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")
  )
```

Every operation works the same on every disk:

```elixir
{:ok, report} = Fil.write(s3, "reports/q3.pdf", pdf)
{:ok, pdf} = Fil.read(report)
{:ok, stat} = Fil.stat(report)
{:ok, reports} = Fil.ls(s3, "reports/", recursive: true)
{:ok, backup} = Fil.cp(report, Fil.ref(local, "backups/q3.pdf"))
{:ok, _} = Fil.rm(report)
```

`signed_url` returns an expiring URL, so clients can download or upload a file directly instead of going through
your application code. S3 serves its URLs itself. For local and in-memory disks, `Fil.Plugin.SignedURL` signs them and
`Fil.Plug` serves them from your application:

```elixir
{:ok, url} = Fil.signed_url(report, expires_in: 900)
{:ok, upload_url} = Fil.signed_url(s3, "inbox/new.bin", method: :put)
```

With `checksum:`, a write sends a checksum of the content. S3 rejects the upload if what it received doesn't match,
and stores the checksum with the object, so later reads can check it:

```elixir
{:ok, report} = Fil.write(s3, "reports/q3.pdf", pdf, checksum: :sha256)
{:ok, pdf} = Fil.read(report, verify_checksum: true)
{:ok, %Fil.Stat{checksum: {:sha256, checksum}}} = Fil.stat(report, checksum: :sha256)
```

With `if_none_match: :any`, a write only succeeds if nothing exists at the path yet. That's enough for a simple lock:

```elixir
case Fil.write(s3, "jobs/today.lock", "started", if_none_match: :any) do
  {:ok, _lock} -> :run_the_job
  {:error, :precondition_failed} -> :someone_else_won
end
```

## Development

`mix test` runs the unit tests, which need no network. The integration tests run the conformance suite against
SeaweedFS, started with Docker Compose:

```bash
docker compose up -d
mix test.integration
```

`FIL_S3_ENDPOINT`, `FIL_S3_ACCESS_KEY_ID`, `FIL_S3_SECRET_ACCESS_KEY` and `FIL_S3_REGION` point the integration tests
at another S3 endpoint.

## Acknowledgments

`Fil` builds on ideas from these projects:

- [Flysystem](https://flysystem.thephpleague.com) (PHP): the scope, one API across many storage backends
- [Req](https://github.com/wojtekmach/req): the API design, with disks as plain values and plugins that attach to them
- [Plug](https://github.com/elixir-plug/plug): plugins as small units you add to a disk, each doing one thing to every
  operation that passes through

Thanks to their authors and contributors.
