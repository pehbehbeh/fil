# Direct uploads from the browser are untrusted

A browser that uploads directly to the storage can lie about what it uploaded, and a modified client can report an
upload it never made. So `Fil.LiveView` checks the stored file when the upload is consumed (the checks are listed under
"Direct uploads" in its moduledoc), and a failed consume never deletes the file, because it may be someone else's, and
the form can be submitted again.

When the storage signs an upload itself (S3, Azure), the content goes to the storage directly and never passes through
the disk's plugins. They only see the `:signed_upload` operation. `Fil.Plugin.Validation` therefore refuses to sign an
upload whose rules the signature can't enforce. On storage that binds the content type (S3),
`presigned_uploads: :check_declared` trusts the signed one instead.

## Consequences

- Each entry needs a path of its own. The default, `Fil.LiveView.filename/1`, builds it from the entry's UUID. A path
  built from the browser's file name would let a user claim a file someone else uploaded.
- Plugins that change the content (encryption, compression) don't work with uploads the storage signs. A disk with
  `Fil.Plugin.URL` and a `:secret` sends its uploads through `Fil.Plug` instead, where the plugins run.
