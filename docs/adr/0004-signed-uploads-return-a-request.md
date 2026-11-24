# Signed uploads return a request

`Fil.signed_upload/3` signs uploads and returns a map with the method, the URL, the headers the client has to send, form
fields and the expiry. `Fil.signed_url/3` signs only downloads. Azure's Put Blob needs an `x-ms-blob-type` header, which
a URL alone can't include, and a POST policy is a form. The request differs between disks, and an adapter can
change it in a later version, so a client that assumes a `PUT` would break on one that signs a form.

## Considered options

- `Fil.signed_url/3` with `method: :put`, as released in 0.1.0 and 0.2.0. It can't include headers or form fields, so it
  was removed in favour of `Fil.signed_upload/3`.

## Consequences

- Clients build the request from the map. No adapter signs a form yet (S3 signs a presigned `PUT`), but one that does
  needs no change on the client.
- Storage differs in what a signature can bind (see Binding in the `Fil.signed_upload/1` docs). The optional
  `binds_uploads?/1` callback of `Fil.Adapter` says whether the storage refuses an upload with another content type or
  size.
