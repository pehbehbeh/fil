# Create-only writes are `if_exists: :error`

`Fil.write/4`, `Fil.cp/4` and `Fil.rename/4` take `if_exists: :overwrite | :error`. The option says what it decides, and
it can grow (`:skip` for idempotent uploads), but never to `:append`, which object stores can't do.

## Considered options

- `if_none_match: :any`, which only made sense to people who know conditional request headers.
- `exclusive: true`, `File`'s word, which was still hard to read. `File`'s vocabulary is for function names, not
  options.
