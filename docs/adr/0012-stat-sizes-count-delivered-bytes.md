# Stat sizes count bytes of the content as the caller gets it

`Fil.stat/3` and `Fil.ls/3` describe the content as `Fil.read/3` and `Fil.stream/3` return it, the same as range offsets
do (see [Ranges](../../guides/plugins.md#ranges) in the plugins guide). A plugin that changes the size of reads sets
`size` in the `:stat` result and in the stats of the `:ls` result to the size it delivers, or to `nil` when it can't
know that size without reading the file. `Fil.Plug` resolves ranges against that size and puts it into `content-range`
as the total, so offsets and total come from the same content. A file whose stat has no size gets a `200` with the
whole file for every range, and no `accept-ranges`. The etag stays the storage's own (the `"size-mtime"` tag of
`Fil.Adapter.Local` is built from the stored size before plugins run), so validators don't depend on what a plugin
reports.

## Considered options

- Answering a range request with a `200` whenever a plugin transforms reads. `Fil.Plug` can't see that without new API
  on `Fil.Op`, and it would turn off ranges for plugins that report the right size too.
- Working out the delivered size before answering, which reads the whole file on every range request.

## Consequences

- Other code that reads `stat.size`, such as the size checks of `Fil.LiveView` and the preview and download limits of
  `Fil.Kino`, gets the delivered size. With `size: nil`, `Fil.LiveView` skips `max_file_size:` on a direct upload (it
  checked the size the browser reported before the upload), but still refuses one on storage that doesn't bind
  uploads, because it can't compare the stored file with the signed size there. `Fil.Kino` refuses to preview or
  download a file without a size.
- Code that compares `stat.size` with a number has to handle `nil` first, because `nil` sorts above every integer in
  Erlang's term order.
- A plugin that changes the size of reads and doesn't change the stat still gets wrong ranges. `Fil` doesn't detect it.
