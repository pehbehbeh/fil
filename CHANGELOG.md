# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Fil.stream/1,2,3` and `Fil.stream!/1,2,3` return a file's content as a stream of binaries, on every disk. They
  check the file right away and read it when the stream is enumerated.
  ([#TBD](https://github.com/pehbehbeh/fil/pull/TBD))
- `Fil.write/4` takes a stream as well as iodata, with its size in the new `size:` option if it's known. A stream that
  raises writes nothing. S3 sends a stream with a size as it's read, and collects one without a size, or with
  `checksum:`, into memory first.
  ([#TBD](https://github.com/pehbehbeh/fil/pull/TBD))
- `Fil.Op.update_content/2` and `Fil.Op.update_result/2` transform streams lazily with `chunk:`, and take a `stream:`
  function for transforms that keep state across chunks. `op.streaming` marks a read from `Fil.stream/3`. The plugins
  guide describes what a plugin can rely on.
  ([#TBD](https://github.com/pehbehbeh/fil/pull/TBD))
- `stream/3` is an optional adapter callback. Adapters without it stream the result of `read/3` as one chunk.
  ([#TBD](https://github.com/pehbehbeh/fil/pull/TBD))
- `disposition:` on `Fil.signed_url/3` sets the `content-disposition` of the download (`:inline`, `:attachment` or
  `{:attachment, filename}`), on S3 as `response-content-disposition` and on Local and Memory through `Fil.Plug`.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))
- `:public_endpoint` on `Fil.Adapter.S3` builds public and signed URLs for a host other than the one the disk sends its
  requests to, such as `localhost` for a container the application reaches by its service name.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))
- `query:` on `Fil.signed_url/3` signs extra query parameters into the URL, e.g. for a page that reads them.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))

### Changed

- `Fil.Plug` streams uploads into `Fil.write/4`, with the `content-length` as `size:`, and sends downloads as a chunked
  response, so neither is held in memory whole.
  ([#TBD](https://github.com/pehbehbeh/fil/pull/TBD))
- A copy or a move across disks streams the file instead of reading it into memory.
  ([#TBD](https://github.com/pehbehbeh/fil/pull/TBD))
- `if_exists: :error` on a local disk writes to a temporary file and hard-links it into place, so a failed write no
  longer leaves a partial file behind.
  ([#TBD](https://github.com/pehbehbeh/fil/pull/TBD))
- `Fil.Plug` refuses a signed URL with a query parameter that wasn't signed, as S3 does. URLs signed by 0.1 still work.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))

### Fixed

- `Fil.Plug` answers `403` instead of `500` for signed URLs whose query parameters aren't plain strings.
  ([#1](https://github.com/pehbehbeh/fil/pull/1))

## [0.1.0] - 2026-09-27

### Added

- First release.

[unreleased]: https://github.com/pehbehbeh/fil/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pehbehbeh/fil/releases/tag/v0.1.0
