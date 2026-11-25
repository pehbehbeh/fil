# Signed uploads return a request

`Fil.signed_upload/3` returns a map with the method, the URL, the headers and form fields, because Azure's Put Blob
needs an `x-ms-blob-type` header, which a URL alone can't include, and a POST policy is a form.

## Considered options

- `Fil.signed_url/3` with `method: :put`, as released in 0.1.0 and 0.2.0. It can't include headers or form fields, so it
  was removed in favour of `Fil.signed_upload/3`.
