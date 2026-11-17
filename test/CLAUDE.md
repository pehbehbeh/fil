# Testing conventions

- `Fil.AdapterCase` (test/support) is the shared conformance suite, and every adapter runs it (except
  `Fil.Adapter.Null`, whose writes never read back, and the read-only `Fil.Adapter.Zip`). New behaviour gets a test
  there, not a copy per adapter. A new test in it needs its sentence in `Fil.Adapter` (the moduledoc or the callback's
  doc), because third-party adapters will be held to the suite once it's public. A result that differs between adapters
  on purpose (S3 refuses what Local allows) is asserted as the set of allowed results, and the exact result stays in the
  adapter's own test. Signed URL tests send their requests with `fil_request/4` (see `Fil.AdapterCase`) and assert
  refusals as a 4xx status; the exact statuses stay in `plug_test.exs` and the adapters' integration tests.
- Feature tests whose subject is the storage path (`Fil.Plug`, `Fil.LiveView`) run on Local and Memory with
  `use ExUnit.Case, async: true, parameterize: Fil.DiskHelper.adapters()`, `@moduletag :tmp_dir` and
  `Fil.DiskHelper.disk/1` in `setup` (never `setup_all`: a memory store belongs to the test process). Tests that need
  one kind of disk (stored content types, S3 stubs, filesystem checks, option errors) go into a second module in the
  same file, such as `Fil.PlugTest.OneDisk`, with shared helpers in `test/support` (`Fil.PlugHelper`). Code above the
  adapter (plugins, telemetry, Kino, thumbnails, Ecto, the upload field, doctests) stays on one adapter: a second run
  covers nothing new. Parameters aren't tags, so `--only` can't select one and a tag applies to every parameter.
  `file:line` runs a test on both adapters, a failure prints `Parameters: %{adapter: ...}` under the test, and
  `--slowest` lists the test twice without saying which run is which.
- Cloud unit tests stub the storage with `Req.Test` (`Req.Test.stub(__MODULE__, &s3(&1, test))` or `Req.Test.expect/3`,
  and `req_options: [plug: {Req.Test, __MODULE__}]`), so `mix test` makes no network requests. The adapter tests share
  `Fil.ReqStub` (test/support), which expects one request per response and sends each request to the test. The stubs are
  plugs, so the tests need Plug, which stays optional for users. Req runs the stub after its own request steps (signing
  included), so it can send the test the `Plug.Conn` it got, to assert on its method, path, query, headers and body
  (`Plug.Conn.read_body/1`). Bind `test = self()` outside the stub and send to `test`, not `self()`: Req.Test finds the
  stub through `$callers`, so it may run in another process. Stubs are owned per test process, so the tests stay async.
  Tests `import Plug.Conn`, like `Fil.Plug` does.
- Integration tests create a bucket or container per run and give each test its own root in it, derived from the test
  name (`:erlang.phash2(test, 4_294_967_296)`), so `fil_disk/1` returns the same disk each time it's called. Anything
  that lists the whole bucket, such as the multipart uploads, filters by that root.
- Telemetry tests attach with `Fil.TelemetryHelper.attach/1`, which forwards only the events of the test process and
  the processes it started (`$callers`), so they stay async. `:telemetry_test.attach_event_handlers/2` would forward
  every async test's events. Tests that attach a handler for every process (the default logger) are `async: false`.
- Kino tests `import Kino.Test` and run `setup :configure_livebook_bridge`, then `setup {Fil.KinoHelper,
  :configure_uploads}`, in that order: the helper's group leader sits in front of Kino's and answers the file path
  requests Kino's can't. `Fil.KinoHelper.upload/3` fakes a Livebook upload into a file input, and `status/1` returns the
  next status line of an upload field. Both group leaders belong to the test process, so the tests stay async.
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
