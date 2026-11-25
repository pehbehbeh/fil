# Temporary files get a directory per call

`Fil.tmp/0,1` creates a directory of its own on each call, owned by the calling process and removed when it exits, and
returns a ref on a Local disk rooted there. The disk is Local and not Memory, because tools need a path and big files
shouldn't sit on the heap.

## Considered options

-  A temporary directory per process. With one per call, the disk root is the jail, and handing the directory to another
  process moves it whole.
