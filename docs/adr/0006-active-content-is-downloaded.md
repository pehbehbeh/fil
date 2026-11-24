# `Fil.Plug` sends files a browser would run as downloads

An uploaded HTML or SVG file served from the app's domain would run its scripts with access to the app's cookies and
pages. `Fil.Plug` sends a file whose type is in `:active_types`, or that has no valid type, as
`application/octet-stream` with `content-disposition: attachment`, so the browser saves it instead of running it, and a
page can't load it as a script either. The `Fil.Plug` moduledoc (Security) has the details.

## Considered options

- Only `content-disposition: attachment`. It doesn't stop a `<script src>` from running a JavaScript file, so the type
  changes as well.
- `content-security-policy: sandbox` on every response. It would break the PDF viewer of Chrome, so only active types
  sent `inline` get the sandbox.

## Consequences

- URLs that S3 and Azure sign themselves go to the storage, not through `Fil.Plug`, so this doesn't cover them. The
  `Fil.Plug` moduledoc says what to do there.
