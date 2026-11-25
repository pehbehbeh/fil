# `Fil` signs its own URLs in a plugin

Local and Memory have no storage service that could sign URLs, so `Fil` signs them in `Fil.Plugin.URL`, which works on
any disk, S3 included.

## Considered options

- `base_url:` and `secret:` as options of the Local and Memory adapters, replaced before 0.1.0 was released.
