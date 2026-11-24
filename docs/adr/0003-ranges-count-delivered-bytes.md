# Ranges count bytes of the content as the caller gets it

A read with a range gives a plugin that transforms the result the whole file, and `Fil.Op` cuts the range from what the
plugin returns. A slice of compressed or encrypted bytes can't be decompressed or decrypted on its own.

## Consequences

- With a plugin that transforms reads, `Fil` calls the adapter a second time, for the whole file. Content in memory is
  read twice. A stream isn't, but it's read from the start of the file up to the end of the range, and the adapter's
  check before a stream (a HeadObject on S3) runs twice.
