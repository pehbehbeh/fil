# Writes store all of the content or nothing

A write either stores the whole content or leaves the destination as it was, on every adapter, so plugins can refuse
content by raising from a scan while it's written. Each adapter's page says how it does that.

## Considered options

- A temporary file for Local writes named after the destination plus a suffix, in 0.1.0. It showed up in listings,
  `rm_rf` counted it, and it failed with `:enametoolong` for names near the filesystem's limit.
- Sweeping old `.fil-` files of killed Local writes by age. Rejected because two nodes on one host can share a
  directory.
