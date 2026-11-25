# Errors are sorted by what the caller can do

Every `{:error, _}` holds an exception struct, one per thing the caller can do about it, so a caller matches on what to
do next, and the struct means the same on every disk.

## Considered options

- One `Fil.Error` with a reason, plus `Fil.TransportError`, replaced before 0.1.0 was released.
- An `:adapter` field. `:disk` lets `Fil.ref(error.disk, error.path)` name the file.
