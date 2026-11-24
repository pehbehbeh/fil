# Writes store all of the content or nothing

A write either stores the whole content or leaves the destination as it was, on every adapter, and readers never see a
partial file. Plugins depend on this, because they refuse content by raising from a scan while it's written, which is
only safe if nothing of it is stored then. Each adapter's page says how it does that. `Fil.Adapter.Local` writes to a
`.fil-` file and moves it into place, and `Fil.Adapter.S3` completes a multipart upload only after the stream has ended.

`Fil` holds back the last chunk of a stream until the stream has ended at its size (declared, or found by `Fil`),
because S3 stores a PutObject as soon as it has `content-length` bytes. A stream that turns out longer raises before
that.

A Local writer killed mid-write can't remove its `.fil-` file, so a server that `Fil`'s application starts watches the
writers and removes it.

## Considered options

- A temporary file named after the destination plus a suffix, in 0.1.0. It showed up in listings, `rm_rf` counted it,
  and it failed with `:enametoolong` for names near the filesystem's limit.
- Sweeping old `.fil-` files by age. Rejected because two nodes on one host can share a directory.

## Consequences

- A Local disk reserves the `.fil-` prefix, so `ls` skips a user's own file with such a name, and `rm_rf` removes it
  without counting it.
- The cleanup is best effort. The `Fil.Adapter.Local` page lists what it leaves behind.
