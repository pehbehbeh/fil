# A disk's identity is its adapter and address

`Fil.Disk.same_storage?/2` treats two disks as the same storage when they have the same adapter and the same address,
which the adapter returns from the optional `address/1` callback of `Fil.Adapter`. That's the root on a local disk, and
the endpoint, region, bucket and prefix on S3. Plugins, credentials and options that only change how the storage is
reached don't count. Without the callback, the whole adapter state is compared.

Before it was released, `Fil.Ecto.Ref` compared the whole state, which on S3 contains the credentials
([#25](https://github.com/pehbehbeh/fil/pull/25)). After STS credentials were rotated, its refs counted as "on another
disk", and storing one of them again raised in `dump`.

## Consequences

- A ref from a disk with other plugins, or from one built before the credentials were rotated, still fits a
  `Fil.Ecto.Ref` field.
