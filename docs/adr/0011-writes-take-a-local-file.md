# Writes take `{:file, path}` for a local file

`Fil.write/4` takes `{:file, path}` for a file on the local filesystem, such as a `Plug.Upload` or a LiveView upload, so
callers don't build a `File.Stream` themselves. It streams the file with its size known.

## Considered options

- `%Plug.Upload{}` as content. `{:file, upload.path}` covers it, and the upload's content type comes from the browser,
  so the type comes from `content_type:` or `Fil.Plugin.ContentType` instead.
- A Local ref and `Fil.cp/3`, which needs a disk per file and longer call sites.
- A `Fil.Content` protocol, which plain maps can't implement.
