# Fil agent guide

`Fil` is a pluggable file storage abstraction for Elixir with one API for many kinds of storage.
The Hex package is `fil`.

## Core rules

- **Return values:** every function that can fail returns `{:ok, result} | {:error, exception}`. Actions on files
  return `{:ok, %Fil.Ref{}}`. Bang variants raise the same exception.
- **Names and semantics:** the API, the adapter callbacks and the `Fil.Op` names use `File`'s vocabulary (`read`,
  `write`, `stat`, `ls`, `cp`, `rename`, `rm`, `rm_rf`, `exists?`, `dir?`), but the semantics follow the object store
  model on every adapter: `rm` is idempotent, `write` creates parents, paths are jailed to the disk root. Every
  difference from `File` is a row in the contract table in `Fil.Adapter`. Keep that table current, and link to it
  instead of repeating it.
- **Refs:** every public function accepts `disk, path` or a `%Fil.Ref{}`, built with `Fil.ref/2`. There's
  no tuple form and no other input union type, so there are exactly two ways to name a file.
- **Plugins:** a plugin is a callback `(op, next, opts)` attached with `Fil.attach/4`, with no behaviour. The
  callback is a function or a `{module, function}` pair. The `plugins:` option of `Fil.disk/1` takes
  `{module, function, opts}` entries and attaches each under the module's name, so disks built from config need no
  functions. Plugin modules have a public `call/3` (`@doc false`) that validates its own options, because entries from
  config skip `attach/2`.
- Options come only from `attach`; there are no registered or global options. Callbacks
  match on `op.name` and change content only through the `Fil.Op` helpers (`update_content/2`, `update_result/2`),
  so they keep working once streaming lands. Every operation goes through `Fil.Op.run/1`. Plugin docs live in
  `guides/plugins.md` only, not in the README.
- **Same behaviour on every adapter:** critical behaviour (read, write, list, copy, checksums, public and signed URLs)
  works on every disk. When the storage lacks a feature, `Fil` fills the gap with a plugin (`Fil.Plugin.URL` builds and
  signs URLs for Local and Memory, and `Fil.Plug` serves them) instead of leaving the user with a
  `Fil.UnsupportedError`. Differences that remain are edge cases, documented in the "Where the adapters differ" table
  in `Fil.Adapter` and nowhere else. New behaviour gets a conformance test in `Fil.AdapterCase`.
- **Storage features stay in adapters:** anything the storage has to do itself (checksums, conditional writes,
  URLs) is an adapter option, not a plugin. So is addressing (root, bucket, prefix).
- **Wording:** "adapter" is the module (`Fil.Adapter.S3`), "storage" is what's behind it (S3, the filesystem): "the same
  on every adapter", "the storage refused access". Don't say "backend".
- **Namespaces:** `Fil.Adapter.*` is only for adapters, `Fil.Plugin.*` only for plugins. `Fil.Plug` is the Plug
  that serves public and signed URLs (compiled only when the optional Plug dependency is there, listed under
  Integrations in the docs). Shared internal helpers go in `Fil.Support.*` (`@moduledoc false`).
- **Errors:** every `{:error, _}` contains an exception struct, one per thing the caller can do about it, such as
  `Fil.NotFoundError` or `Fil.UnavailableError`. Adapters return the structs with `:reason` set (the POSIX atom,
  the S3 error code), and `Fil.Op` fills in `:op`, `:path` and `:disk`. Messages are built in `message/1`, never
  stored. A new storage failure maps onto an existing struct; `Fil.UnknownError` is for responses nobody has mapped
  yet. A new error goes into `lib/fil/exceptions.ex` and `t:Fil.error/0`; the docs sidebar picks it up by name
  (`Fil.*Error`). Bad options raise, because they're programming errors. `{:error, _}` is only for storage conditions.
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
- **Docs:** operation functions have `@doc section: :operations` (and so on). The ExDoc groups are built from these
  tags, so never maintain function lists by hand.
- **HTTP:** cloud adapters call Req directly, with a `req_options:` adapter option that's merged into every request.
  The adapter always sets `retry: false` and `raw: true`, so user options can't change the storage semantics. Req signs
  requests (its `aws_sigv4:` option), presigned URLs use the private `Req.Utils.aws_sigv4_url/1` (Req is deliberately
  not pinned for it; if a release drops it, presigning crashes), and XML is parsed with OTP's `:xmerl_sax_parser`.
  There's no HTTP client behaviour.

## Commands

```sh
mix deps.get
mix test                    # unit tests only (no network)
docker compose up -d        # SeaweedFS (S3, verifies SigV4)
mix test.integration        # runs the @tag :integration suites against the compose.yml services
mix format                  # 120 columns, Quokka plugin
mix credo                   # strict, every check enabled (see .credo.exs)
```

## CI

`.github/workflows/ci.yml` checks formatting, `mix credo` and `mix docs --warnings-as-errors` on the latest Elixir, and
runs `mix test` on every supported Elixir minor version, each with the newest OTP it supports (plus OTP 26 on Elixir
1.16). The integration suite runs once, on the latest Elixir, against SeaweedFS started from `compose.yml`. When
`elixir:` in `mix.exs` changes, update the matrix. The `release` job (below) runs after them on `main` and on
maintenance branches.

## Releasing

Nobody publishes by hand. CI's `release` job publishes whenever `main` (or a `v0.N` maintenance branch) carries a
version that isn't on Hex yet: it checks the changelog, runs `mix hex.publish` (package and docs), pushes the `vX.Y.Z`
tag and creates the GitHub release from the changelog section. Pushes whose version is already on Hex do nothing, and a
rerun after a partial failure picks up where it stopped. It needs the `HEX_API_KEY` repository secret, created once
with `mix hex.user key generate --key-name github-actions --permission api:write`.

- **Changelog:** `CHANGELOG.md`, newest first, one line per user-visible change, added in the same commit as the change
  under `## Unreleased`. Released sections are headed `## v0.2.0 (2026-10-01)`. The file is in the Hex package and a
  Guides tab on HexDocs, so each published version carries its changelog.
- **Release:** branch `release/0.2.0` from `develop`. Bump `@version` in `mix.exs` and rename `## Unreleased` to
  `## v0.2.0 (date)`; the next change on `develop` adds a fresh `## Unreleased`. Merge into `main`, then `main` back
  into `develop`. The release job refuses a version without a changelog section or with entries left under Unreleased.
- **Hotfix:** branch `hotfix/0.2.1` from `main`, fix, add a `## v0.2.1 (date)` section, bump the version, merge into
  `main` and back into `develop`.
- **Backport** to an older line: `git checkout -b v0.1 v0.1.0`, cherry-pick the fix, bump to `0.1.1`, add the changelog
  section, push. The branch is never merged anywhere; `main` may note the backport in the current section.
- **Bad release:** `mix hex.retire fil 0.2.0 security --message "..."` warns users on `mix deps.get`. A version can't be
  replaced, so the fix is the next patch version.

## Testing conventions

- `Fil.AdapterCase` (test/support) is the shared conformance suite, and every adapter runs it. New behaviour gets a
  test there, not a copy per adapter.
- Cloud unit tests stub the storage with `Fil.ReqStub` (`Fil.ReqStub.stub(&adapter/1)` and
  `req_options: [adapter: Fil.ReqStub]`), so `mix test` makes no network requests and needs no Plug. Req calls the
  adapter in the test process after its own request steps, so a test can record the request or message itself from it.
- Integration tests create their own buckets and use a unique prefix per test.
- One-line input/output checks are doctests on the function they test, not separate tests. `Fil.DoctestTest` runs
  the doctests of every module in the app, so don't add `doctest` lines to other test files.
- Doctests that write files use `Fil.disk(adapter: Fil.Adapter.Memory)` (a second disk gets another `root:`).
  `Fil.DoctestTest` checks out a store in its setup, so examples need no setup lines. Examples that only build a disk
  use `Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")`.

## Etiquette

- README and `guides/installation.md` examples have to keep working against the actual API. The guide is listed under
  the Guides tab on HexDocs (`extras` in `mix.exs`).
- Examples name refs after the file they hold (`report`, `backup`, `reports`), not `ref` or `refs`.
