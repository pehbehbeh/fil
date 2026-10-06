# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Fil.Plugin.Validation` refuses writes by size (`max_size:`, `min_size:`), by content type (`content_types:`,
  checked against the content's magic bytes, so a GIF named `.png` or HTML in a `.txt` fails) and by extension, plus a
  `check:` of your own. A refused write returns `Fil.InvalidContentError` and writes nothing, and a stream fails as
  soon as it breaks a rule. Upload URLs are checked when they're signed, and a presigned S3 upload that would skip a
  content check is refused unless `presigned_uploads: :check_declared` trusts its signed content type.
- `Fil.Op.scan_content/4` and `Fil.Op.scan_result/4` let a plugin read the content of a write or a read as it passes,
  without changing it. A stream keeps its chunks and its `:size`, so S3 still sends it in one request. A plugin refuses
  content by raising the new `Fil.InvalidContentError` from a scan: the write returns the error and writes nothing, on
  every adapter, also when the scan raises after the last chunk. `Fil.Plug` answers an upload refused this way with a
  `413` (too large), a `415` (content type or extension) or a `422`. ([#33](https://github.com/pehbehbeh/fil/pull/33))
- `Fil.read/3` and `Fil.stream/3` take `offset:` and `length:` to read part of a file, on every adapter: S3 sends a
  `Range` header, the local disk reads from the offset, and the memory disk returns a sub-binary. Plugins that
  transform reads get the whole file and `Fil` cuts the part from their result, so offsets count bytes of the content
  as you get it. ([#35](https://github.com/pehbehbeh/fil/pull/35))
- `Fil.Plug` sends `etag`, `last-modified` and `accept-ranges: bytes`, answers `if-none-match` and `if-modified-since`
  with a `304`, and a `GET` with one byte range with a `206` (`416` for a range outside the file, `if-range`
  honoured). Several ranges get the whole file. Signed URLs work with ranges too, so browsers can seek in videos
  served from a local disk. ([#35](https://github.com/pehbehbeh/fil/pull/35))
- A tour of the API as a [Livebook](https://livebook.dev) notebook, under Guides in the docs and linked from the README
  with a "Run in Livebook" badge. ([#34](https://github.com/pehbehbeh/fil/pull/34))
- `Fil.LiveView.external/2` lets the browser upload files straight to a disk, on every adapter: S3 with a presigned PUT,
  local and memory disks through `Fil.Plug`. The consume functions then check each file instead of writing it, and
  refuse one that's older than its upload URL or larger than `max_file_size`. The browser side is one import in
  `app.js`, `import {uploaders} from "phoenix-colocated/fil"`. ([#26](https://github.com/pehbehbeh/fil/pull/26))
- `Fil.signed_url/3` takes `content_type:`, `size:` and `if_exists: :error` for `method: :put`, and the upload has to
  match them, on S3 and through `Fil.Plug`: another `content-type` or `content-length` is a `403`, and with
  `if_exists: :error` the URL writes the file once and can't replace it.
  ([#26](https://github.com/pehbehbeh/fil/pull/26))
- `Fil.LiveView.upload_field/1` is an upload field for LiveView forms, with drag and drop, previews, progress, cancel
  buttons, and remove buttons for the files the record already has. It's styled with daisyUI like the components
  Phoenix 1.8 generates, and a class attribute per part replaces the defaults. `Fil.LiveView.cancel_upload/2` handles
  its cancel buttons, and `Fil.LiveView.upload_error/2` turns LiveView's and Fil's upload errors into
  `{msgid, bindings}` for the app's `translate_error/1`. The [Phoenix guide](https://fil.hexdocs.pm/phoenix.html)
  shows a complete form. ([#27](https://github.com/pehbehbeh/fil/pull/27))
- `Fil.Ecto.Ref` stores refs in Ecto schemas: the column holds the path, and loading returns a `Fil.Ref` on the disk
  the field names. `{:array, Fil.Ecto.Ref}` holds several files in order, and `Fil.Ecto.Ref.removed/2` returns the refs
  a changeset drops, to delete after the commit. A ref fits a field when `Fil.Disk.same_storage?/2` finds its disk on
  the same storage: the same adapter and the same address, which adapters return from the new optional callback
  `c:Fil.Adapter.address/1` (the root on a local disk, the endpoint, region, bucket and prefix on S3), so plugins and
  rotated credentials don't count. Ecto is a new optional dependency. ([#25](https://github.com/pehbehbeh/fil/pull/25))
- `Fil.LiveView` stores LiveView uploads on a disk: `consume_uploaded_entries/4` streams each file into `Fil.write/4` at
  a path you choose, and never replaces a file unless you pass `if_exists: :overwrite`. If a write fails, it deletes the
  files it wrote and keeps the entries, so the form can be submitted again. It needs Phoenix LiveView 1.2, an optional
  dependency. The [Phoenix guide](https://fil.hexdocs.pm/phoenix.html) walks through a form.
  ([#23](https://github.com/pehbehbeh/fil/pull/23))
- `Fil.Disk.resolve/1` returns the disk for a disk, a 0-arity function or an MFA. `Fil.Plug`'s `disk:` goes through it
  and raises an `ArgumentError` when its function returns something other than a disk. It takes a function only as a
  capture such as `&MyApp.Storage.uploads/0`, because plug options can't hold an anonymous function.
  ([#22](https://github.com/pehbehbeh/fil/pull/22))
- `Fil.tmp/0,1` creates a temporary directory and returns a ref to it, or to a file in it, on a local disk, so the
  whole API works on it. The directory belongs to the calling process and is removed when that process exits, also
  when it's killed. `Fil.Tmp.path/1` returns the path for tools that need one, `Fil.Tmp.give_away/2` hands the
  directory to another process, and `Fil.Tmp.cleanup/1` removes it earlier.
  ([#18](https://github.com/pehbehbeh/fil/pull/18))
- A Fil disk smart cell for Livebook, which generates the `Fil.disk/1` call for a Local, S3 or Memory disk, with the S3
  credentials from Livebook secrets. It's there when Kino is installed.
  ([#21](https://github.com/pehbehbeh/fil/pull/21))
- `Fil.Kino.upload/3` is a file field for Livebook that writes each upload to a directory of a disk, streamed from the
  file Livebook keeps. `writable: true` on `Fil.Kino.browser/3` adds it below the browser, together with a delete
  button for each file. ([#20](https://github.com/pehbehbeh/fil/pull/20))
- `Fil.Kino.browser/3` browses a disk in Livebook: one directory at a time, with a preview of images and text and a
  download button. Kino is a new optional dependency. ([#19](https://github.com/pehbehbeh/fil/pull/19))
- `Fil.Plugin.Thumbnails` writes smaller copies of images when they're written, sized per variant, and deletes, copies
  and renames them with the image. They go under `thumbnails/`, or wherever a `:variant_path` function puts them, such
  as next to the image. `generate/1` makes them later, with `mode: :manual` or for images stored before. It needs the
  optional Vix dependency.
  ([#14](https://github.com/pehbehbeh/fil/pull/14))
- Telemetry events for every operation on every disk, `[:fil, :op, :start]`, `[:fil, :op, :stop]` and
  `[:fil, :op, :exception]`, with the operation, the disk, the path, the error and the bytes read or written. Each read
  of a stream from `Fil.stream/3` is a `[:fil, :stream, ...]` span of its own, with the bytes read. See
  `Fil.Telemetry`.
  ([#12](https://github.com/pehbehbeh/fil/pull/12))
- `Fil.Telemetry.attach_default_logger/1` logs every operation and every read of a stream, with its duration.
  ([#12](https://github.com/pehbehbeh/fil/pull/12))
- S3 uploads a stream without a size, a stream with `checksum:`, and content over 5 GiB in parts (a multipart upload),
  with one part in memory at a time: 8 MiB by default, set with the new `:part_size` option. A stream that fits in one
  part is still one PutObject. A part that fails because the storage is unavailable is sent once more, a second later.
  A failed upload is aborted, and so is the upload of a process that's killed. A `:crc32` checksum covers the whole
  file, however it's uploaded. A `:sha256` or `:sha1` checksum of an upload in parts covers each part, and S3 stores a
  checksum of those: `Fil.stat/3` returns `nil` for it, and `verify_checksum: true` checks the content against it.
  ([#11](https://github.com/pehbehbeh/fil/pull/11))
- `Fil.stream/1,2,3` and `Fil.stream!/1,2,3` return a file's content as a stream of binaries, on every disk. They
  check the file right away and read it when the stream is enumerated.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
- `Fil.write/4` takes a stream as well as iodata. A stream that raises writes nothing. S3 sends a stream of known size
  as it's read, in one request, and uploads any other in parts. `Fil` finds the size of a `File.Stream` of bytes and of
  a stream from `Fil.stream/3` itself, and the new `size:` option gives it for other streams. `size: :unknown` turns
  finding it off, for a file that grows while it's written (a log) or whose stat size may be wrong (`/sys`, network
  and FUSE file systems).
  ([#10](https://github.com/pehbehbeh/fil/pull/10), [#15](https://github.com/pehbehbeh/fil/pull/15))
- `Fil.Op.update_content/2` and `Fil.Op.update_result/2` take a `stream:` function, which transforms a stream lazily,
  chunk by chunk or with state across chunks. `op.streaming` marks a read from `Fil.stream/3`. A read transform that
  raises one of `Fil`'s errors turns the read into that error. The plugins guide describes what a plugin can rely on.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
- `Fil.ConflictError`: the file changed while the operation used it, so reading it again and retrying can help. A write
  of a stream whose size `Fil` found, and a copy across disks, return it when the file changes size meanwhile, and
  write nothing. S3 returns it when something else aborted an upload in parts. `Fil.Plug` answers it with a `409`.
  ([#10](https://github.com/pehbehbeh/fil/pull/10), [#11](https://github.com/pehbehbeh/fil/pull/11),
  [#15](https://github.com/pehbehbeh/fil/pull/15))
- `stream/3` is an optional adapter callback. Adapters without it stream the result of `read/3` as one chunk.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
- `disposition:` on `Fil.signed_url/3` sets the `content-disposition` of the download (`:inline`, `:attachment` or
  `{:attachment, filename}`), on S3 as `response-content-disposition` and on Local and Memory through `Fil.Plug`.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))
- `:public_endpoint` on `Fil.Adapter.S3` builds public and signed URLs for a host other than the one the disk sends its
  requests to, such as `localhost` for a container the application reaches by its service name.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))
- `query:` on `Fil.signed_url/3` signs extra query parameters into the URL, e.g. for a page that reads them.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))

### Changed

- `Fil.LiveView` needs Phoenix 1.8: the optional dependency is `{:phoenix, "~> 1.8", optional: true}` now, so an app
  with an older Phoenix can't resolve `fil` at all. The uploader for direct uploads is LiveView colocated JS, and
  LiveView 1.2 raises at compile time when a component with colocated JS compiles below Phoenix 1.8.
  ([#26](https://github.com/pehbehbeh/fil/pull/26))
- `content_type`, `size` and `if_exists` are reserved names in the `query:` option of `Fil.signed_url/3`, which raises
  for them like for `expires` or `disposition`.
  ([#26](https://github.com/pehbehbeh/fil/pull/26))
- S3's `InvalidRequest` error code is a `Fil.InvalidRequestError` instead of a `Fil.UnknownError`. S3 sends it for a
  copy or a move of an object onto itself, for example. `Fil.Plug` still answers it with a `500` and logs it, because S3
  sends it for problems with the request or the bucket's configuration as well.
  ([#16](https://github.com/pehbehbeh/fil/pull/16))
- `Fil.Plug` answers an upload that the disk refuses for its content, a `Fil.InvalidRequestError` that isn't about the
  path, with a `422` instead of a `404`.
  ([#14](https://github.com/pehbehbeh/fil/pull/14))
- `Fil.write/4` raises `ArgumentError` for a list that isn't iodata, such as `[70_000]`, before any plugin sees it.
  Before, a plugin that replaced the content or answered the call itself hid it.
  ([#12](https://github.com/pehbehbeh/fil/pull/12))
- `Fil.Op.update_content/2` and `update_result/2` take `iodata:` instead of `binary:`, which now raises
  `ArgumentError` like any unknown transform. The function gets the same argument as before.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
- `Fil.Plug` streams uploads into `Fil.write/4`, with the `content-length` as `size:`, and sends downloads as a chunked
  response, so neither has to fit in memory.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
- A copy or a move across disks streams the file instead of reading it into memory, with the source's size, so S3
  sends it in one request as it's read (in parts when a plugin on the source changes the content).
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
- `if_exists: :error` on a local disk writes to a temporary file and hard-links it into place, so a failed write no
  longer leaves a partial file behind.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
- Local writes name their temporary file `.fil-` and a short suffix, which listings skip, so a name near the
  filesystem's limit works. A failed write also removes the directories it created. When the writing process is killed,
  its `.fil-` file and those directories are removed as well, as far as possible.
  ([#10](https://github.com/pehbehbeh/fil/pull/10), [#17](https://github.com/pehbehbeh/fil/pull/17))
- `Fil.Plug` refuses a signed URL with a query parameter that wasn't signed, as S3 does. URLs signed by 0.1 still work.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))

### Removed

- Elixir 1.16 and 1.17 are no longer supported; Fil needs Elixir 1.18 or later.
  ([#15](https://github.com/pehbehbeh/fil/pull/15))
- OTP 26 and older are no longer supported; Fil needs OTP 27 or later, and supports the last three OTP releases.
  ([#24](https://github.com/pehbehbeh/fil/pull/24))
- `chunk:` in `Fil.Op.update_content/2` and `update_result/2`: use `stream:` with `Stream.map/2`.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))

### Fixed

- `Fil.Plug` answers `403` instead of `500` for signed URLs whose query parameters aren't plain strings.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))
- `Fil.cp/3` and `Fil.rename/3` with `if_exists: :error` replaced an existing file within one disk, and refused only
  across disks. They now return `Fil.AlreadyExistsError` on every adapter and leave both files as they were. The check
  is atomic: a hard link on local disk, `:ets.insert_new/2` in memory, and `If-None-Match: *` on the CopyObject on S3.
  On local disk and in memory, a write that replaces the source during such a move stays, and the move fails with a
  `Fil.ConflictError`. A move without `if_exists: :error` in memory keeps that write too, like one on local disk.
  ([#16](https://github.com/pehbehbeh/fil/pull/16))
- A copy or a move on local disk that failed left behind the directories it created for the destination. It removes
  them now, like a write.
  ([#16](https://github.com/pehbehbeh/fil/pull/16))

## [0.1.0] - 2026-09-27

### Added

- First release.

[unreleased]: https://github.com/pehbehbeh/fil/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pehbehbeh/fil/releases/tag/v0.1.0
