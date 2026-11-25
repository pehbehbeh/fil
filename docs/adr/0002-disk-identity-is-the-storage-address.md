# A disk's identity is its adapter and address

`Fil.Disk.same_storage?/2` compares the adapter and the address, without plugins or credentials, so a ref still fits a
`Fil.Ecto.Ref` field after the credentials were rotated.

## Considered options

- Comparing the whole adapter state, the first version in [#25](https://github.com/pehbehbeh/fil/pull/25). On S3 the
  state contains the credentials, so after STS credentials were rotated, refs counted as "on another disk", and storing
  one of them again raised in `dump`.
