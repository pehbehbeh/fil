# Disks are values, with no registry

A disk is a plain value, so there's no application config and nothing to supervise, and a disk works in a script or a
Livebook with `Mix.install/1`. Integrations that need one later resolve it from a function or an MFA. The test adapter
follows the same rule: a `Fil.Adapter.Memory` store belongs to the test process that checked it out, and other processes
find it through their `$callers` or `allow/2`, so a Memory disk is a plain value too.

## Considered options

- A global supervised registry, with atoms accepted wherever the API takes a disk and `put/2` at runtime for scripts and
  tenants. It was planned for after 0.1 and dropped when the integrations got `Fil.Disk.resolve/1` instead.
