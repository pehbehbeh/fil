<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img alt="Fil" src="assets/logo-light.svg" width="240">
  </picture>
</h1>

[![CI](https://img.shields.io/github/actions/workflow/status/pehbehbeh/fil/ci.yml?branch=main&label=CI)](https://github.com/pehbehbeh/fil/actions/workflows/ci.yml?query=branch%3Amain)
[![License](https://img.shields.io/hexpm/l/fil.svg)](https://github.com/pehbehbeh/fil/blob/main/LICENSE)
[![Version](https://img.shields.io/hexpm/v/fil.svg)](https://hex.pm/packages/fil)
[![Hex Docs](https://img.shields.io/badge/documentation-gray.svg)](https://fil.hexdocs.pm)
[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Ffil.hexdocs.pm%2Ftour.livemd)

`Fil` is a pluggable file storage abstraction for Elixir.

```elixir
Mix.install([
  {:fil, "~> 0.1"}
])

disk = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")

disk
|> Fil.write!("hello.txt", "World")
|> Fil.read!()
#=> "World"
```

With `adapter: Fil.Adapter.S3`, a bucket and credentials, the same code writes to S3.

To try `Fil` without a project, run the [tour](https://fil.hexdocs.pm/tour.html) in [Livebook](https://livebook.dev).

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

- **One API for many kinds of storage.** Local disk, S3 (and S3-compatible stores) and an in-memory disk for async
  tests, with the same behaviour on every adapter. `cp` and `rename` work across disks.
- **Just values.** A disk is a plain value: no application config, no registry, nothing to supervise. It works in a
  script or a Livebook with `Mix.install/1`. In Livebook, [`Fil.Kino`](https://fil.hexdocs.pm/Fil.Kino.html) browses a
  disk, uploads files to it, and adds a smart cell that builds one.
- **Pluggable.** Anything that isn't about where files are stored is a [plugin](https://fil.hexdocs.pm/plugins.html),
  such as setting content types or logging.
- **Few dependencies.** Req, NimbleOptions, MIME and Telemetry, plus Plug if you serve files. Cloud adapters use Req
  instead of their own SDKs.
- **Streaming.** Files can be read and written as streams on every disk, so large files don't have to fit in memory.
- **URLs on every disk.** Public and signed GET and PUT URLs, from S3 itself or from `Fil.Plugin.URL` and `Fil.Plug`.
- **Phoenix uploads.** `Fil.LiveView` stores LiveView uploads on any disk, also straight from the browser (see the
  [Phoenix guide](https://fil.hexdocs.pm/phoenix.html)), and [`Fil.Ecto.Ref`](https://fil.hexdocs.pm/Fil.Ecto.Ref.html)
  stores the refs in Ecto schemas.
- **Safe by default.** Paths can't climb out of the disk root, `if_exists: :error` never replaces a file, and S3
  verifies checksums.
- **Errors you can act on.** Each error, such as `Fil.NotFoundError` or `Fil.UnavailableError`, says what to do next
  and is the same on every adapter.
- **Telemetry.** Every operation emits [Telemetry](https://hexdocs.pm/telemetry) events with its duration, bytes and
  error, for metrics, logs and traces (see `Fil.Telemetry`).

## Concepts

`Fil` uses the function names of Elixir's `File` module (`read`, `write`, `stream`, `stat`, `ls`, `cp`, `rename`, `rm`,
`rm_rf`), but on every adapter they behave like an object store:

- `write` creates missing parent directories
- `rm` on a missing file succeeds
- `ls` on a missing directory returns an empty list
- paths are always relative to the disk root, and `.` is the root
- a path that climbs above the root fails with a `Fil.InvalidRequestError`

The [contract in `Fil.Adapter`](https://fil.hexdocs.pm/Fil.Adapter.html#module-contract) lists every difference from
`File`. Every function that can fail returns `{:ok, result}` or `{:error, error}`, with an error from the Errors
section below.

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

For a disk built from config, `Fil.disk/1` takes plugins as data: `plugins: [{Fil.Plugin.ContentType, :call, []}]`.

Your own plugin is a function. It gets the operation, calls `next` to run the rest, and returns the result:

```elixir
local =
  Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage")
  |> Fil.attach(:log, fn op, next, _opts ->
    IO.puts("#{op.name} #{op.path}")
    next.(op)
  end)
```

The [plugins guide](https://fil.hexdocs.pm/plugins.html) explains how to write plugins: matching on operations,
changing content, handling errors and answering without the adapter.

### Errors

Every error is an exception struct that says what you can do about it, and means the same on every disk:

```elixir
case Fil.read(disk, "report.txt") do
  {:ok, content} -> content
  {:error, %Fil.NotFoundError{}} -> nil
  {:error, %Fil.UnavailableError{}} -> :retry_later
end
```

The structs contain the operation, the path, the disk and what the storage reported (`:reason`), so a log line says
which file failed and why. Each error has its own page under Errors in the docs, and
[Errors in `Fil.Adapter`](https://fil.hexdocs.pm/Fil.Adapter.html#module-errors) explains how adapters use them.

Every function that can fail has a bang variant that returns the bare result and raises the same struct instead.

## Usage

The [installation guide](https://fil.hexdocs.pm/installation.html) is the full setup for an application: a module
for your disks, the config for each environment (local disks in development, memory disks in tests and S3 in
production), signed URLs and tests. This section is only a quick tour of the API.

Build one disk per kind of storage:

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

Large files don't have to fit in memory. `stream` returns a file's content as a stream of chunks, and `write` takes a
stream as well as a binary, so a file can go from one disk to another, or from a local file to S3, piece by piece:

```elixir
{:ok, video} = Fil.stream(s3, "videos/intro.mp4")
{:ok, _} = Fil.write(local, "cache/intro.mp4", video)

{:ok, _} = Fil.write(s3, "backups/db.dump", File.stream!("db.dump", 65_536))
```

With a `File.stream!` of bytes, as above, or a stream from `stream`, `Fil` knows the size, and S3 sends the stream as
it's read, in one request. For other streams, pass `size:` if you know it, or S3 uploads the stream in parts of 8 MiB
(the local and memory disks don't need the size).

`offset:` and `length:` read part of a file, and the storage reads only that part (S3 with a `Range` header):

```elixir
{:ok, header} = Fil.read(s3, "videos/intro.mp4", length: 4096)
{:ok, rest} = Fil.stream(s3, "videos/intro.mp4", offset: 4096)
```

`url` returns the public URL of a file, and `signed_url` an expiring one, so clients can download or upload a file
directly instead of going through your application code. S3 serves its URLs itself. For local and in-memory disks,
`Fil.Plugin.URL` builds them and `Fil.Plug` serves them from your application, with etags, `304`s and range requests,
so browsers can cache files and seek in videos:

```elixir
{:ok, logo_url} = Fil.url(s3, "logo.png")
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

To create a file only if it doesn't exist yet, pass `if_exists: :error`. If the file is already there, nothing is
overwritten and the write returns a `Fil.AlreadyExistsError`. That makes a simple lock: whoever creates the file
first runs the job.

```elixir
case Fil.write(s3, "jobs/today.lock", "started", if_exists: :error) do
  {:ok, _lock} -> :run_the_job
  {:error, %Fil.AlreadyExistsError{}} -> :someone_else_won
end
```

`tmp` returns a ref to a file in a temporary directory, which is removed when the calling process exits. It's a local
file, so a copy from any disk gives a tool the path it needs:

```elixir
report = Fil.tmp("report.pdf")
{:ok, _} = Fil.cp(Fil.ref(s3, "reports/q3.pdf"), report)
{text, 0} = System.cmd("pdftotext", [Fil.Tmp.path(report), "-"])
```

## Development

`mix test` runs the unit tests, which need no network. The integration tests run the conformance suite against RustFS,
started with Docker Compose:

```bash
docker compose up -d
mix test.integration
```

`FIL_S3_ENDPOINT`, `FIL_S3_ACCESS_KEY_ID`, `FIL_S3_SECRET_ACCESS_KEY` and `FIL_S3_REGION` point the integration tests
at another S3 endpoint.

## Acknowledgments

`Fil` builds on ideas from these projects:

- [Flysystem](https://flysystem.thephpleague.com) (PHP): the scope, one API across many kinds of storage
- [Req](https://github.com/wojtekmach/req): the API design, with disks as plain values and plugins that attach to them
- [Plug](https://github.com/elixir-plug/plug): plugins as small units you add to a disk, each doing one thing to every
  operation that passes through

Thanks to their authors and contributors.
