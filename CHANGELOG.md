# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
  filesystem's limit works. A failed write also removes the directories it created.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
- `Fil.Plug` refuses a signed URL with a query parameter that wasn't signed, as S3 does. URLs signed by 0.1 still work.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))

### Removed

- Elixir 1.16 and 1.17 are no longer supported; Fil needs Elixir 1.18 or later.
  ([#15](https://github.com/pehbehbeh/fil/pull/15))
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
