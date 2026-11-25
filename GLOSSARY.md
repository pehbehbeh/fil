# Fil

Fil is a file storage abstraction for Elixir. It has one API with `File`'s names for many kinds of storage, and behaves
like an object store on every one of them.

## Storage

**Disk**:
A `%Fil.Disk{}`, which holds an adapter with its state, the plugins attached to it and the defaults for signed URLs and
uploads. It's a plain value from `Fil.disk/1`, with no process or registry behind it.
_Avoid_: volume

**Local disk**:
A disk with `Fil.Adapter.Local`, whose storage is the filesystem.

**Adapter**:
The module that implements `Fil.Adapter` for one kind of storage, such as `Fil.Adapter.S3`.
_Avoid_: backend, driver

**Storage**:
What's behind an adapter: S3, Azure Blob Storage, the filesystem, an ETS table.
_Avoid_: backend, local disk (for the filesystem)

**Address**:
The part of an adapter's state that decides which file a path names: the `:root`, and on S3 and Azure also the endpoint,
the bucket or container, and on S3 the region. Two disks with the same adapter and the same address are the same
storage, whatever their credentials.

**Contract**:
The behaviour every adapter has to show, written down in `Fil.Adapter` (its moduledoc and the callback docs) and tested
by `Fil.AdapterCase` on every adapter except `Fil.Adapter.Null` and the read-only `Fil.Adapter.Zip`.

## Files

**Path**:
The name of a file or directory relative to the disk root, which `Fil` normalizes and refuses when it would leave the
root.
_Avoid_: prefix, key

**Directory**:
A path that other paths are under, a real directory on the filesystem and derived from the keys on object stores.
_Avoid_: prefix

**Key**:
An object store adapter's name for a file (S3, Azure, Memory), which is the `:root` plus the path and which Azure calls
the blob name.

**Ref**:
A `%Fil.Ref{}`, a disk plus a path built with `Fil.ref/2`, which can name a file that doesn't exist yet. A ref from a
listing also carries a `:stat` snapshot.
_Avoid_: handle, file object

**Content**:
What a write stores or a read returns: iodata or a stream of it, and for a write also `{:file, path}`.
_Avoid_: body, data, payload

## Plugins

**Plugin**:
A callback `(op, next, opts)` attached to a disk with `Fil.attach/4` or the `plugins:` option of `Fil.disk/1`.
_Avoid_: middleware, hook

**Operation**:
One step that `Fil` runs through a disk's plugins and its adapter, a `%Fil.Op{}` named `:read`, `:write` and so on, of
which one `Fil` call can run several (`Fil.wildcard/3`). The docs group the `Fil` functions that run them under
Operations.
_Avoid_: request

**Scan**:
A look at content or a result without changing it (`Fil.Op.scan_content/4`, `Fil.Op.scan_result/4`). A scan refuses
content by raising `Fil.InvalidContentError`.

## Uploads

**Signed upload**:
The request a client needs to upload one file directly to a disk, from `Fil.signed_upload/3`: method, URL, headers, form
fields and expiry.

**Direct upload**:
An upload the browser sends to the URL of a signed upload.

**Binding**:
What a signed upload ties the upload to: the content type, the size and `if_exists: :error`. An upload that differs is
refused where the storage or `Fil.Plug` enforces them.

**Consume**:
The step in which `Fil.LiveView` takes the files of a LiveView upload onto a disk.
