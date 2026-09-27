# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Telemetry events for every operation on every disk, `[:fil, :op, :start]`, `[:fil, :op, :stop]` and
  `[:fil, :op, :exception]`, with the operation, the disk, the path, the error and the bytes read or written. Each read
  of a stream from `Fil.stream/3` is a `[:fil, :stream, ...]` span of its own, with the bytes read. See
  `Fil.Telemetry`.
  ([#N](https://github.com/pehbehbeh/fil/pull/N))
- `Fil.Telemetry.attach_default_logger/1` logs every operation and every read of a stream, with its duration.
  ([#N](https://github.com/pehbehbeh/fil/pull/N))
- S3 uploads a stream without a size, and content over 5 GiB, in parts (a multipart upload), with one part in memory
  at a time: 8 MiB by default, set with the new `:part_size` option. A stream that fits in one part is still one
  PutObject. A part that fails because the storage is unavailable is sent once more, a second later. A failed upload
  is aborted, and so is the upload of a process that's killed.
  ([#11](https://github.com/pehbehbeh/fil/pull/11))
- `Fil.stream/1,2,3` and `Fil.stream!/1,2,3` return a file's content as a stream of binaries, on every disk. They
  check the file right away and read it when the stream is enumerated.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
- `Fil.write/4` takes a stream as well as iodata, with its size in the new `size:` option if it's known. A stream that
  raises writes nothing. S3 sends a stream with a size as it's read, and uploads one without a size in parts.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
- `Fil.Op.update_content/2` and `Fil.Op.update_result/2` take a `stream:` function, which transforms a stream lazily,
  chunk by chunk or with state across chunks. `op.streaming` marks a read from `Fil.stream/3`. A read transform that
  raises one of `Fil`'s errors turns the read into that error. The plugins guide describes what a plugin can rely on.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
- `Fil.ConflictError`: the file changed while the operation used it, so reading it again and retrying can help. A copy
  across disks returns it when the source changes size while it's copied, and `Fil.Plug` answers it with a `409`.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))
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

- S3 reads a stream with `checksum:` one part at a time instead of collecting it into memory. A `:crc32` checksum
  covers the whole file, however it's uploaded. A `:sha256` or `:sha1` checksum of an upload in parts covers each
  part, and S3 stores a checksum of those: `Fil.stat/3` returns `nil` for it, and `verify_checksum: true` checks the
  content against it.
  ([#11](https://github.com/pehbehbeh/fil/pull/11))
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

- `chunk:` in `Fil.Op.update_content/2` and `update_result/2`: use `stream:` with `Stream.map/2`.
  ([#10](https://github.com/pehbehbeh/fil/pull/10))

### Fixed

- `Fil.Plug` answers `403` instead of `500` for signed URLs whose query parameters aren't plain strings.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))

## [0.1.0] - 2026-09-27

### Added

- First release.

[unreleased]: https://github.com/pehbehbeh/fil/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pehbehbeh/fil/releases/tag/v0.1.0
