# Fil agent guide

`Fil` is a pluggable file storage abstraction for Elixir with one API for many kinds of storage.
The Hex package is `fil`.

## Core rules

- **Return values:** every function that can fail returns `{:ok, result} | {:error, exception}`. Actions on files
  return `{:ok, %Fil.Ref{}}`. Bang variants raise the same exception.
- **Before 1.0:** the best API takes priority over compatibility. Renaming or removing public API is fine, with a
  `### Changed` or `### Removed` entry in the changelog.
- **Names and semantics:** the API, the adapter callbacks and the `Fil.Op` names use `File`'s vocabulary (`read`,
  `write`, `stream`, `stat`, `ls`, `cp`, `rename`, `rm`, `rm_rf`, `exists?`, `dir?`), but the semantics follow the
  object store model on every adapter: `rm` is idempotent, `write` creates parents, paths are jailed to the disk root.
  Every difference from `File` is a row in the contract table in `Fil.Adapter`. Keep that table current, and link to
  it instead of repeating it.
- **Refs:** every public function accepts `disk, path` or a `%Fil.Ref{}`, built with `Fil.ref/2`. There's
  no tuple form and no other input union type, so there are exactly two ways to name a file.
- **Plugins:** a plugin is a callback `(op, next, opts)` attached with `Fil.attach/4`, with no behaviour. The
  callback is a function or a `{module, function}` pair. The `plugins:` option of `Fil.disk/1` takes
  `{module, function, opts}` entries and attaches each under the module's name, so disks built from config need no
  functions. Plugin modules have a public `call/3` (`@doc false`) that validates its own options, because entries from
  config skip `attach/2`.
- Options come only from `attach`; there are no registered or global options. Callbacks
  match on `op.name` and change content only through the `Fil.Op` helpers (`update_content/2`, `update_result/2`),
  so they work on iodata and streams alike. `Fil.stream/3` runs as a `:read` with `op.streaming: true`, so a
  plugin that transforms reads covers it without knowing. Every operation goes through `Fil.Op.run/1`. Plugin docs
  live in `guides/plugins.md` only, not in the README. A new plugin goes into the list of shipped plugins at the top of
  that guide, by hand.
- **Same behaviour on every adapter:** critical behaviour (read, write, stream, list, copy, checksums, public and signed
  URLs) works on every disk. When the storage lacks a feature, `Fil` fills the gap with a plugin (`Fil.Plugin.URL`
  builds and signs URLs for Local and Memory, and `Fil.Plug` serves them) instead of leaving the user with a
  `Fil.UnsupportedError`. Differences that remain are edge cases, documented on the adapter's own page and nowhere
  else. A table with a column per adapter stops fitting on a page once there are many adapters, and readers usually
  care about one or two. New behaviour gets a conformance test in
  `Fil.AdapterCase`.
- **Adapter docs:** every adapter's `@moduledoc` has the same sections: an intro with an example, Options (generated),
  Operations and Errors. Operations lists each `Fil` function the adapter implements (`Fil.read/3`, not `read/3`):
  the storage call and where the adapter departs from the contract in `Fil.Adapter`. The callbacks stay without
  `@doc` (`@impl` hides them), because users call `Fil`, never the adapter; calling it directly would skip path
  checks, plugins and the error fields `Fil.Op` fills in.
- **Storage features stay in adapters:** anything the storage has to do itself (checksums, conditional writes,
  URLs) is an adapter option, not a plugin. So is addressing (root, bucket, prefix).
- **Wording:** "adapter" is the module (`Fil.Adapter.S3`), "storage" is what's behind it (S3, the filesystem): "the same
  on every adapter", "the storage refused access". Don't say "backend".
- **Namespaces:** `Fil.Adapter.*` is only for adapters, `Fil.Plugin.*` only for plugins. `Fil.Plug` is the Plug
  that serves public and signed URLs (compiled only when the optional Plug dependency is there, listed under
  Integrations in the docs). `Fil.Kino` is the Livebook integration, compiled only when the optional Kino dependency is
  there, with its `@moduledoc false` modules under `Fil.Kino.*`. Their JS and CSS share `lib/fil/kino/assets/`, with
  an entrypoint per module (`use Kino.JS, entrypoint: "browser.js"`) and Livebook's palette and fonts in `theme.css`,
  which every widget imports first. `Fil.LiveView` is the LiveView integration, compiled only when the optional
  `phoenix_live_view` dependency is there. Its JS for apps (the uploader of direct uploads) is colocated JS in a
  `@moduledoc false` component that's never rendered (`Fil.LiveView.Uploader`), exported under a `key:`, so apps import
  it from `"phoenix-colocated/fil"`. The 120 columns apply to it too. LiveView's compiler writes only the manifest of
  the project it runs in, so `compilers:` in `mix.exs` adds it when LiveView is loaded, which is the case when an app
  compiles Fil (not in Fil's own checkout). The upload component `upload_field/1` declares its attributes in
  `Fil.LiveView`, so remote calls get their compile-time checks, and renders in `Fil.LiveView.UploadField`
  (`@moduledoc false`): daisyUI classes by default, a class attribute per part that replaces its default, and every text
  of its own through `translate`. `Fil.Ecto.Ref` is the Ecto type, compiled only when the optional Ecto dependency is
  there. Integrations take a disk as a `%Fil.Disk{}`, a 0-arity function or an MFA and turn it into a disk with
  `Fil.Disk.resolve/1` each time they use it: as a `disk:` option typed and documented by `Fil.Support.DiskOption`
  (`Fil.Plug`, `Fil.Ecto.Ref`), or as an argument that may also be a `%Fil.Ref{}` for a directory (`Fil.LiveView`).
  Options that end up in compiled code, such as a plug's or an Ecto field's, take a function only as a capture with its
  module (`:remote_fun`), because they can't hold an anonymous function. `Fil.Ecto.Ref` takes no `%Fil.Disk{}` either,
  so no credentials end up in the beam. Shared internal helpers go in `Fil.Support.*` (`@moduledoc false`).
- **Errors:** every `{:error, _}` contains an exception struct, one per thing the caller can do about it, such as
  `Fil.NotFoundError` or `Fil.UnavailableError`. Adapters return the structs with `:reason` set (the POSIX atom,
  the S3 error code), and `Fil.Op` fills in `:op`, `:path` and `:disk`. Messages are built in `message/1`, never
  stored. A new storage failure maps onto an existing struct; `Fil.UnknownError` is for responses nobody has mapped
  yet. A new error goes into `lib/fil/exceptions.ex` and `t:Fil.error/0`; the docs sidebar picks it up by name
  (`Fil.*Error`). Bad options raise, because they're programming errors. `{:error, _}` is only for storage conditions.
  Building functions (`Fil.disk/1`, `Fil.ref/2`, `Fil.tmp/0,1`) return the value itself and raise: `Fil.tmp/0,1`
  raises the mapped error struct when it can't create its directory, as `System.tmp_dir!/0` raises without one.
- **Telemetry:** `Fil.Op.run/1` wraps every operation in an `[:fil, :op]` span (`Fil.Support.Telemetry`), so a new
  operation emits events without code of its own. Each enumeration of a stream from `Fil.stream/3` is a
  `[:fil, :stream]` span, emitted where `Fil.Support.Content.put_context/3` already wraps the stream. The event
  reference is the `Fil.Telemetry` moduledoc and nowhere else. Metadata never holds content, results or options.
  Adding a metadata key is fine, removing one breaks handlers. Events must never change what a call returns.
- **Options:** every options list is validated with NimbleOptions. Schemas have `:doc` strings, and the docs are
  generated from them (`NimbleOptions.docs/1`). No ad-hoc validation with `Keyword.get`.
- **Line length:** 120 columns everywhere, prose included: `@moduledoc`, `@doc`, option `doc:` strings and `#`
  comments in every file (config files like `.credo.exs` and `compose.yml` too). Fill paragraphs up to 120 instead of
  wrapping early, and keep inline code and links on one line. `mix format` doesn't rewrap prose, so this is done by
  hand.
- **Credo:** `.credo.exs` enables every check Credo ships and overrides only the ones in `overwrite_checks`, each with
  a reason. Quokka reads the same file, so enabling a check can switch on a rewrite in `mix format`. `AliasUsage` stays
  off because lifted aliases break `@moduledoc` interpolations and option schemas above the alias. After changing
  `.credo.exs`, pass the files explicitly (`mix format "lib/**/*.{ex,exs}" "test/**/*.{ex,exs}"`); a plain
  `mix format` left unchanged files alone here.
- **`do:` one-liners:** only for bodies that fit on one line without a pipe chain. Quokka puts each pipe on its own
  line, which turns a piped `do:` body into a multi-line `do:` block; write those as `do ... end` instead.
- **Nested calls:** `f(g(x))` is a credo error (`NestedFunctionCalls`), in tests too. Pipe it, bind a variable, or give
  the step a function of its own. Credo doesn't see calls nested inside a list literal, so watch for those by hand. Bind
  a variable before a `case` rather than writing `case x |> g() do`: Quokka turns that into `|> case do`, which credo
  rejects as well.
- **Docs:** operation functions have `@doc section: :operations` (and so on). The ExDoc groups are built from these
  tags, so never maintain function lists by hand.
- **HTTP:** cloud adapters call Req directly, with a `req_options:` adapter option that's merged into every request.
  The adapter always sets `retry: false` and `raw: true`, so user options can't change the storage semantics. Req signs
  requests (its `aws_sigv4:` option), presigned URLs use the private `Req.Utils.aws_sigv4_url/1` (Req is deliberately
  not pinned for it; if a release drops it, presigning crashes), and XML is parsed with OTP's `:xmerl_sax_parser`.
  There's no HTTP client behaviour. Bodiless requests send `body: nil`, never `""`: Req 0.8.0-rc.0 turns a GET with a
  body into a POST.

## Commands

```sh
mix deps.get
mix test                    # unit tests only (no network)
docker compose up -d        # RustFS (S3, verifies SigV4)
mix test.integration        # runs the @tag :integration suites against the compose.yml services
mix format                  # 120 columns, Quokka plugin
mix credo                   # strict, every check enabled (see .credo.exs)
bin/check-changelog         # every entry under Unreleased links to its pull request (see Releasing)
bin/release 0.2.0           # releases main to Hex (see Releasing)
```

## CI

`.github/workflows/ci.yml` checks formatting, `mix credo`, `mix docs --warnings-as-errors` and `bin/check-changelog` on
the latest Elixir, and runs `mix test` on every supported Elixir minor version (1.18 and later), each with the newest
OTP it supports. Fil supports the last three OTP releases, the ones OTP still maintains (27, 28 and 29 now), and the
matrix covers each of them. The integration suite runs once, on the latest Elixir, against RustFS started from
`compose.yml`. When `elixir:` in `mix.exs` changes or a new OTP release comes out, update the matrix.

The checks job also compiles `fil` without its optional dependencies (`mix compile --no-optional-deps` in its own build
path), so a module that uses Plug, Vix, Kino or Phoenix LiveView without a compile guard (`if Code.ensure_loaded?(...)`)
fails the build.

The last job, `CI passed`, fails if any other job failed, was cancelled or was skipped. It's the only check the ruleset
on `main` requires, so the ruleset stays the same when the matrix changes. A new job goes into its `needs:`.

Pull requests are merged with a merge commit (squash and rebase merging are off), so the commits of a branch stay as
they are and `git log --first-parent main` shows one line per pull request.

## Releasing

Development is trunk-based: `main` is the only long-lived branch, a release is a commit plus a tag on it, and `v0.N`
maintenance branches exist only once an older line needs a backport. `bin/release` does a release from your machine:

```sh
bin/release 0.2.0
```

It checks that `main` is clean, in sync with `origin` and has a green CI run, refuses a version that is tagged or on
Hex, and a changelog without entries under Unreleased or with an entry that doesn't link to its pull request, and asks
before releasing while the milestone `v0.2.0` has open issues or pull requests. Then it bumps `@version` in `mix.exs`,
renames `## [Unreleased]` in `CHANGELOG.md` to `## [0.2.0] - date` and adds its compare link, commits "Release v0.2.0",
tags `v0.2.0`, runs `mix hex.publish` (package and docs, with your own Hex login and 2FA), commits a fresh
`## [Unreleased]` heading, pushes branch and tag, creates the GitHub release from the changelog section and closes the
milestone. Nothing is pushed before Hex accepted the package, and on failure the script prints how to undo the local
commits. The release commits go to `main` directly, which the ruleset allows only for repository admins (its bypass
list).

- **Changelog:** `CHANGELOG.md` follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/): newest first,
  one entry per user-visible change under `### Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or `Security`, added
  under `## [Unreleased]` in the same pull request as the change. Entries describe the difference from the last release:
  a change to something that's new in the same release updates that feature's entry, adding its pull request's link,
  instead of getting an entry of its own. User-visible changes always go through a pull request; direct pushes to `main`
  are only for changes without an entry. Each entry ends with an inline link to its pull request, such as
  `([#1](https://github.com/pehbehbeh/fil/pull/1))`, or `([#1](...), [#4](...))` for several. Add it in a commit once
  `gh pr create` has returned the number: issues and pull requests share their numbers, so don't guess it. Inline,
  because the GitHub release gets only the section, without the link definitions at the end. `bin/check-changelog`
  enforces it for the entries under Unreleased, in CI and in `bin/release`. Released sections are headed
  `## [0.2.0] - 2026-10-01`. `bin/release` keeps the link definitions at the end, which compare each version with the
  one before. The file is in the Hex package and a Guides tab on HexDocs, so each published version includes its
  changelog.
- **Milestones:** one per planned release, named after its tag (`v0.2.0`), with the issues and pull requests meant to
  ship in it. Issues without a milestone are the backlog, and a patch release needs no milestone. Before a release,
  close what's left in the milestone or move it to the next one. `.github/workflows/renovate-milestone.yml` puts every
  new Renovate pull request into the open milestone with the lowest version.
- **Hotfix:** a normal pull request to `main`, then `bin/release 0.2.1`.
- **Backport** to an older line: `git checkout -b v0.1 v0.1.0`, cherry-pick the fix with its changelog entry under a new
  `## [Unreleased]`, push the branch, then `bin/release 0.1.1` on it. The entry keeps the link to the pull request that
  made the fix on `main`. A `v0.N` branch keeps its own changelog and is never merged anywhere; `main` may note the
  backport in the current section. `v0.1.0` still has the old changelog format, so a `v0.1` branch first cherry-picks
  the commit "Follow Keep a Changelog 1.1.0".
- **Bad release:** `mix hex.retire fil 0.2.0 security --message "..."` warns users on `mix deps.get`, and the changelog
  heading becomes `## [0.2.0] - 2026-10-01 [YANKED]`. A version can't be replaced, so the fix is the next patch
  version.

## Testing conventions

- `Fil.AdapterCase` (test/support) is the shared conformance suite, and every adapter runs it. New behaviour gets a
  test there, not a copy per adapter. Each test in it needs its sentence in the `Fil.Adapter` moduledoc (the contract,
  or the options `File` has no equivalent for), because third-party adapters will be held to the suite once it's
  public. A result that differs between adapters on purpose (S3 refuses what Local allows) is asserted as the set of
  allowed results, and the exact result stays in the adapter's own test. Tests of signed URLs send their requests with
  the case's `fil_request/4`: through `Fil.Plug` by default (disks with `Fil.Plugin.URL`), with Req to RustFS in
  `Fil.Adapter.S3IntegrationTest`. They assert a refusal as a status in the 4xx range, because S3 and `Fil.Plug` answer
  with different ones; `plug_test.exs` and `s3_integration_test.exs` keep exact statuses where they matter (409 and
  412 for a second PUT, 403 for a changed expiry or signature).
- Feature tests whose subject is the storage path (`Fil.Plug`, `Fil.LiveView`) run on Local and Memory with
  `use ExUnit.Case, async: true, parameterize: Fil.DiskHelper.adapters()`, `@moduletag :tmp_dir` and
  `Fil.DiskHelper.disk/2` in `setup` (never `setup_all`: a memory store belongs to the test process). Tests that need
  one kind of disk (stored content types, S3 stubs, filesystem checks, option errors) go into a second module in the
  same file, such as `Fil.PlugTest.Setup`, with shared helpers in `test/support` (`Fil.PlugHelper`). Code above the
  adapter (plugins, telemetry, Kino, thumbnails, Ecto, doctests) stays on one adapter: a second run covers nothing new.
  Parameters aren't tags, so `--only` can't select one and a tag applies to every parameter. `file:line` runs a test on
  both adapters, a failure prints `Parameters: %{adapter: ...}` under the test, and `--slowest` lists the test twice
  without saying which run is which.
- Cloud unit tests stub the storage with `Req.Test` (`Req.Test.stub(__MODULE__, &s3(&1, test))` or `Req.Test.expect/3`,
  and `req_options: [plug: {Req.Test, __MODULE__}]`), so `mix test` makes no network requests. The stubs are plugs, so
  the tests need Plug, which stays optional for users. Req runs the stub after its own request steps (signing included),
  so it can send the test the `Plug.Conn` it got, to assert on its method, path, query, headers and body
  (`Plug.Conn.read_body/1`). Bind `test = self()` outside the stub and send to `test`, not `self()`: Req.Test finds the
  stub through `$callers`, so it may run in another process. Stubs are owned per test process, so the tests stay async.
  Tests `import Plug.Conn`, like `Fil.Plug` does.
- Integration tests create a bucket per run and give each test its own root in it, derived from the test name
  (`:erlang.phash2(test, 4_294_967_296)`), so `fil_disk/1` returns the same disk each time it's called. Anything that
  lists the whole bucket, such as the multipart uploads, filters by that root.
- Telemetry tests attach with `Fil.TelemetryHelper.attach/1`, which forwards only the events of the test process and
  the processes it started (`$callers`), so they stay async. `:telemetry_test.attach_event_handlers/2` would forward
  every async test's events. Tests that attach a handler for every process (the default logger) are `async: false`.
- Kino tests `import Kino.Test` and run `setup :configure_livebook_bridge`, then `setup :configure_uploads` from
  `Fil.KinoHelper`, in that order: the helper's group leader sits in front of Kino's and answers the file path requests
  Kino's can't. `Fil.KinoHelper.upload/3` fakes a Livebook upload into a file input, and `status/1` returns the next
  status line of an upload field. Both group leaders belong to the test process, so the tests stay async.
- One-line input/output checks are doctests on the function they test, not separate tests. `Fil.DoctestTest` runs
  the doctests of every module in the app, so don't add `doctest` lines to other test files.
- Doctests that write files use `Fil.disk(adapter: Fil.Adapter.Memory)` (a second disk gets another `root:`).
  `Fil.DoctestTest` checks out a store in its setup, so examples need no setup lines. Examples that only build a disk
  use `Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")`.
- `Fil.LiveView` tests mount `Fil.LiveViewTest.UploadLive` (test/support) with `live_isolated/3` on the test endpoint
  that `test_helper.exs` configures and starts with its PubSub, then upload with `file_input/4` and `render_upload/3`.
  The LiveView's session is signed and refuses functions, so the test passes an agent with the upload options and the
  function the form's submit calls. The LiveView process finds the test's memory store through `$callers`, so the tests
  need no `allow/2` and stay async.
- `Fil.Ecto.Ref` tests that need a database start an in-memory SQLite repo of their own with `start_supervised!/1`
  (`name: nil`, `database: ":memory:"`, `pool_size: 1`), point `Repo.put_dynamic_repo/1` at it and run the SQLite
  migration from the docs with `Ecto.Migrator.up/4`, which uses the dynamic repo. So they stay async without a sandbox.
  Postgres and MySQL aren't in CI: the type does nothing per database, and they were checked by hand when it was added.

## Etiquette

- README and `guides/installation.md` examples have to keep working against the actual API. The guide is listed under
  the Guides tab on HexDocs (`extras` in `mix.exs`).
- Examples name refs after the file they hold (`report`, `backup`, `reports`), not `ref` or `refs`.
