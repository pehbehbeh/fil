# `Fil.wildcard/3` matches patterns itself

Pattern listings are `Fil.wildcard/2,3`, which mirrors `Path.wildcard/2` with the disk root as the working directory
(the same syntax and the same dotfile rule). No storage matches patterns itself, so `Fil` walks the directories with
`Fil.ls/3`, one level at a time below the literal start of the pattern, and lists the whole subtree in one recursive
listing from a `**` on. Each listing is an operation of its own, so plugins and `[:fil, :op]` telemetry events see every
one. Adapters never see a pattern, and `Fil` filters by `type:` itself, so adapters may ignore it.

## Considered options

- A `glob:` option on `Fil.ls/3`, replaced within the same pull request
  ([#40](https://github.com/pehbehbeh/fil/pull/40)) before it was released, so that `ls` stays a single listing.
