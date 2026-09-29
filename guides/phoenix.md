# Phoenix

This guide stores files from a Phoenix app on a disk: uploads from a LiveView form with `Fil.LiveView`, direct uploads
from the browser, uploads to a controller, and links to the stored files. It uses the `MyApp.Storage.uploads/0` disk
from the [installation guide](installation.md), with `Fil.Plugin.ContentType` attached.

`Fil.LiveView` needs Phoenix LiveView 1.2 and Phoenix 1.8. Both are optional dependencies of `Fil`, so an app with
them needs nothing else.

## LiveView uploads

### Allowing the upload

Allow the upload in `mount/3` as usual, with the extensions it takes in `accept:`:

```elixir
def mount(_params, _session, socket) do
  {:ok, allow_upload(socket, :avatar, accept: ~w(.jpg .jpeg .png), max_file_size: 5_000_000)}
end
```

LiveView accepts a file when its extension or its type matches `accept:`, and the type comes from the browser. A file
named `evil.html` that the browser sends as `image/png` passes. `Fil.LiveView` checks the extension of the path it
writes against the extensions `accept:` allows, the ones it lists and those of its exact types (`image/png` allows
`.png`), and refuses that file. A wildcard such as `image/*` allows no extension of its own: with only wildcards the
extension isn't checked, and next to extensions (`~w(.pdf image/*)`) it lets no image through. So list the extensions
a wildcard stands for too, in `accept:` or in `extensions:`.

### The form

The template is LiveView's own (see [Uploads](https://hexdocs.pm/phoenix_live_view/uploads.html) in its docs):

```heex
<form id="avatar-form" phx-change="validate" phx-submit="save">
  <.live_file_input upload={@uploads.avatar} />

  <div :for={entry <- @uploads.avatar.entries}>
    <.live_img_preview entry={entry} width="80" />
    <progress value={entry.progress} max="100">{entry.progress}%</progress>
    <button type="button" phx-click="cancel" phx-value-ref={entry.ref}>Cancel</button>
    <p :for={error <- upload_errors(@uploads.avatar, entry)}>{inspect(error)}</p>
  </div>

  <button type="submit">Save</button>
</form>
```

```elixir
def handle_event("validate", _params, socket), do: {:noreply, socket}

def handle_event("cancel", %{"ref" => ref}, socket) do
  {:noreply, cancel_upload(socket, :avatar, ref)}
end
```

### Storing the files

When the form is submitted, `Fil.LiveView.consume_uploaded_entries/4` writes each file to the disk and consumes its
entry:

```elixir
def handle_event("save", _params, socket) do
  user = socket.assigns.current_user

  case Fil.LiveView.consume_uploaded_entries(socket, :avatar, &MyApp.Storage.uploads/0,
         path: &"avatars/#{user.id}/#{Fil.LiveView.filename(&1)}"
       ) do
    {:ok, [avatar]} ->
      {:ok, user} = Accounts.update_avatar(user, avatar)
      {:noreply, assign(socket, :current_user, user)}

    {:ok, []} ->
      {:noreply, socket}

    {:error, error} ->
      {:noreply, put_flash(socket, :error, upload_error(error))}
  end
end

defp upload_error(%Fil.InvalidRequestError{reason: :extension}), do: "Only .jpg and .png files can be uploaded."
defp upload_error(%Fil.AlreadyExistsError{}), do: "This file was uploaded already."

defp upload_error(error) do
  Logger.error("Avatar upload failed: " <> Exception.message(error))
  "The upload failed. Please try again."
end
```

An error's message names the disk and the path in storage, so it's for logs, not for users. `upload_error/1` picks a
text for the errors a user can do something about, from the error struct and its `:reason`, and logs the rest (with
`require Logger` in the module).

The disk is a function, so it's built when the form is submitted, from the config of the environment the app runs in.
A `Fil.Ref` for a directory works as well, and the paths are then relative to it.

`path:` decides where each file goes. `Fil.LiveView.filename/1` is the entry's UUID with the extension of the uploaded
file, such as `0b2e8b8e-4a0a-4c1e-9d1e-2f6f4e0c7a11.png`, and it's the default. Don't build paths from
`entry.client_name`: the browser sends it, so it can be `../../config.exs`, a name another user already has, or
`index.html`.

The result is a list of refs in the order of the file input. A `Fil.Ecto.Ref` field stores a ref: the column holds the
path, and loading the user gives a ref on the field's disk again.

```elixir
schema "users" do
  field :avatar, Fil.Ecto.Ref, disk: &MyApp.Storage.uploads/0
end
```

The field takes refs, never strings from params, so leave it out of `cast/4` and put the ref with `put_change/3`.
`Fil.Ecto.Ref.removed/2` returns the avatar the change replaces, which `update_avatar/2` deletes once the update is
committed:

```elixir
def update_avatar(user, avatar) do
  changeset =
    user
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_change(:avatar, avatar)

  removed = Fil.Ecto.Ref.removed(changeset, :avatar)

  with {:ok, user} <- Repo.update(changeset) do
    Enum.each(removed, &Fil.rm/1)
    {:ok, user}
  end
end
```

The `Fil.Ecto.Ref` docs show the migration for each database, and `{:array, Fil.Ecto.Ref}` for several files in one
field.

`Fil.LiveView` never replaces a file, unless you pass `if_exists: :overwrite`. With UUIDs in the path that doesn't
happen anyway, but a `path:` that returns a name that's taken gets a `Fil.AlreadyExistsError` instead of replacing
that file. That includes two files of one submit with the same name: the second one fails, and then the first one is
deleted again with the rest, as below.

A failed write returns the error and keeps every entry in the upload. Files written before the error are deleted
again, so the user can fix what's wrong and submit the form again, or cancel an entry. To show the error next to the
form instead of in a flash, assign it:

```elixir
{:error, error} -> {:noreply, assign(socket, :upload_error, upload_error(error))}
```

The files are written in the LiveView process, as with LiveView's own `consume_uploaded_entries/3`, so a large file
blocks the LiveView until it's stored. [Direct uploads](#direct-uploads) don't.

### Storing each file when it's uploaded

With `auto_upload: true` and a `progress:` callback, each file can be stored as soon as it's uploaded, with
`Fil.LiveView.consume_uploaded_entry/4`:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   allow_upload(socket, :avatar,
     accept: ~w(.jpg .jpeg .png),
     auto_upload: true,
     progress: &handle_progress/3
   )}
end

defp handle_progress(:avatar, entry, socket) when entry.done? do
  case Fil.LiveView.consume_uploaded_entry(socket, entry, &MyApp.Storage.uploads/0) do
    {:ok, avatar} -> {:noreply, assign(socket, :avatar, avatar.path)}
    {:error, error} -> {:noreply, put_flash(socket, :error, upload_error(error))}
  end
end

defp handle_progress(:avatar, _entry, socket), do: {:noreply, socket}
```

A failed write keeps the entry, but the upload is finished, so the progress callback doesn't run for it again. Show the
error and let the user cancel the entry and pick the file again.

### Testing

Tests with a memory disk need nothing more than the `Fil.Adapter.Memory.checkout/0` from the
[installation guide](installation.md#testing): the LiveView uses the store of the test that started it. Upload with
`Phoenix.LiveViewTest`, then look at the disk:

```elixir
test "stores the avatar", %{conn: conn, user: user} do
  {:ok, view, _html} = live(conn, ~p"/settings/avatar")

  avatar = file_input(view, "#avatar-form", :avatar, [%{name: "me.png", content: "png", type: "image/png"}])
  render_upload(avatar, "me.png")

  view
  |> form("#avatar-form")
  |> render_submit()

  assert {:ok, [_avatar]} = Fil.ls(MyApp.Storage.uploads(), "avatars/#{user.id}")
end
```

## Direct uploads

With a direct upload, the browser sends each file straight to the disk, and the content never passes through the
LiveView. On S3 that's a presigned PUT. Local and memory disks get the file through `Fil.Plug` in your endpoint.
`Fil.LiveView.external/2` returns the function for `external:`:

```elixir
def mount(_params, _session, socket) do
  user = socket.assigns.current_user

  {:ok,
   allow_upload(socket, :avatar,
     accept: ~w(.jpg .jpeg .png),
     max_file_size: 20_000_000,
     external:
       Fil.LiveView.external(&MyApp.Storage.uploads/0,
         path: &"avatars/#{user.id}/#{Fil.LiveView.filename(&1)}"
       )
   )}
end
```

For each file it builds the path, checks the extension as above, and signs an upload URL with `Fil.signed_url/3`. The
URL is bound to the content type of the path, the size the browser reported and `if_exists: :error` (see
[Uploads](Fil.html#signed_url/1-uploads)), so it uploads one file, once, and can't replace the file later. With
`if_exists: :overwrite`, it writes the file again on every request until it expires, also after the consume. A refused
extension shows up as `{:external_metadata_failure, %{reason: :extension}}` in `upload_errors/2`, any other error as
`%{reason: :error}`, and the error itself goes to the log. A failed upload is LiveView's `:external_client_failure`.

The form and the `save` handler from [Storing the files](#storing-the-files) stay the same, with the same disk.
`Fil.LiveView.consume_uploaded_entries/4` then checks that each file arrived at the path `external/2` signed, which
LiveView keeps on the server, instead of writing it, and `update_avatar/2` stores the ref as before. The consume's own
`path:`, `extensions:` and `if_exists:` don't apply to direct uploads, so another `path:` there doesn't move the file.
A file that never arrived gives a `Fil.NotFoundError`, and the entry stays, as with any failed consume. A failed
consume doesn't delete the files that did arrive, so the form can be submitted again.

The browser only reports that the upload is done, and a modified client can report one it never made. So `path:` has
to give each entry a path of its own, as `Fil.LiveView.filename/1` does. With `&"docs/#{&1.client_name}"`, a user could
claim a file another user uploaded. The consume refuses a file that's older than the upload URL (with 30 seconds for
clock differences) with a `Fil.AlreadyExistsError` and `reason: :before_upload`, and one that's larger than
`max_file_size` with `reason: :too_large`. It leaves both files where they are, because they may belong to someone
else.

### The uploader

The browser side is the `Fil` uploader, which `Fil` compiles as colocated JS. Pass it to the `LiveSocket` in
`assets/js/app.js`:

```javascript
import {uploaders} from "phoenix-colocated/fil"

const liveSocket = new LiveSocket("/live", Socket, {hooks: {...colocatedHooks}, uploaders, params: {_csrf_token}})
```

An app with uploaders of its own merges them: `uploaders: {...uploaders, S3: myS3Uploader}`. Apps generated by Phoenix
1.8 find `phoenix-colocated/fil` already, because their esbuild config has the build directory in `NODE_PATH`. An older
app adds `Mix.Project.build_path()` to `NODE_PATH` in its esbuild config, and an app with another bundler points it at
`_build/<env>/phoenix-colocated`.

The uploader sends each file with `XMLHttpRequest`, with the headers the URL was signed with, and reports its
progress. Cancelling an entry aborts its request. An upload the storage refuses calls `entry.error()`, which LiveView
shows as `:external_client_failure`. Without `auto_upload`, LiveView then clears the file input, and the user picks
the file again.

### Local and memory disks

`Fil.Plugin.URL` with a `secret:` signs the URLs and `Fil.Plug` takes the uploads, as in
[Signed URLs](installation.md#signed-urls) in the installation guide. The uploads go to your own endpoint, so they need
no CORS and no CSRF token. `Fil.Plug` takes uploads up to its `max_body_size:`, 100 MiB by default, so set it to at
least the upload's `max_file_size`:

```elixir
# lib/my_app_web/endpoint.ex
plug Fil.Plug, at: "/uploads", disk: &MyApp.Storage.uploads/0, max_body_size: 20_000_000
```

A disk without `Fil.Plugin.URL` can't sign URLs, so `external/2` gives every file the error `%{reason: :error}`. For
tests with direct uploads, add the plugin to the memory disk in `config/test.exs` too. `render_upload/3` doesn't send
the file of a direct upload, so a test that consumes it has to write the file itself.

### S3

S3 checks the signature, the content type and the size of each upload, and answers `412` when the file exists. The
browser sends the file to the bucket from your app's page, so the bucket needs a CORS rule that allows `PUT` from your
app's origin with the two headers the uploader sets:

```json
{
  "CORSRules": [
    {
      "AllowedOrigins": ["https://my-app.example.com"],
      "AllowedMethods": ["PUT"],
      "AllowedHeaders": ["content-type", "if-none-match"],
      "MaxAgeSeconds": 3600
    }
  ]
}
```

```bash
aws s3api put-bucket-cors --bucket my-app-uploads --cors-configuration file://cors.json
```

A disk with a `public_endpoint:` signs the URLs for it, so the browser can reach a bucket behind another name than the
one the app uses.

### Plugins and thumbnails

A presigned PUT goes to S3 directly, so none of the disk's plugins run. `Fil.Plugin.ContentType` isn't needed, because
the content type is bound into the URL. Plugins that change the content (encryption, compression) don't work with
direct uploads to S3, and `Fil.Plugin.Thumbnails` makes no thumbnails. For those, attach `Fil.Plugin.Thumbnails` with
`mode: :manual` and make them from the refs the consume returns, in the `save` handler:

```elixir
{:ok, [avatar]} ->
  Fil.Plugin.Thumbnails.generate(avatar)
  {:ok, user} = Accounts.update_avatar(user, avatar)
  {:noreply, assign(socket, :current_user, user)}
```

Uploads through `Fil.Plug` are written with `Fil.write/4`, so the plugins run there. A disk with `Fil.Plugin.URL` and a
`secret:` sends its uploads through `Fil.Plug`, on S3 too.

### Files nobody consumes

A file whose form is never submitted stays on the disk, and so does a file the consume refused. Clean those up with a
job that runs every day and deletes the files that are older than a day and not in your database:

```elixir
def delete_unused_avatars do
  cutoff = DateTime.add(DateTime.utc_now(), -1, :day)

  # A `Fil.Ecto.Ref` field loads refs, so compare their paths.
  stored =
    from(u in User, where: not is_nil(u.avatar), select: u.avatar)
    |> Repo.all()
    |> MapSet.new(& &1.path)

  {:ok, avatars} = Fil.ls(MyApp.Storage.uploads(), "avatars", recursive: true)

  avatars
  |> Enum.filter(&(DateTime.before?(&1.stat.mtime, cutoff) and not MapSet.member?(stored, &1.path)))
  |> Enum.each(&Fil.rm/1)
end
```

With `{:array, Fil.Ecto.Ref}`, each row is a list of refs, so flatten them before the set:
`Repo.all(query) |> List.flatten() |> MapSet.new(& &1.path)`. The day between upload and deletion keeps files whose
form is still open. `Fil.ls/3` lists every file under the prefix, so keep the job's prefix to the files of this upload,
and don't run it against a prefix that other code writes to.

On S3, a lifecycle rule that expires objects under a prefix does the same without a job, but it deletes every file
under the prefix, consumed or not. It fits when the uploads are temporary anyway, or when the app moves each consumed
file out of the prefix with `Fil.rename/3` (on S3 a copy on the server).

## Showing stored files

A signed URL lets the browser download a private file for a while, from S3 or through `Fil.Plug` (see
[Signed URLs](installation.md#signed-urls) in the installation guide):

```elixir
{:ok, avatar_url} = Fil.signed_url(user.avatar, expires_in: 3600)
```

```heex
<img src={@avatar_url} alt="" />
```

Files everyone may see can have a public URL instead, with `Fil.url/2`: from a public S3 bucket, or on local and memory
disks from `Fil.Plugin.URL`'s `base_url:`, served by `Fil.Plug` with `public: true`.

## Controller uploads

A controller gets a `Plug.Upload` with the path of a temporary file. Streaming it into `Fil.write/4` is the whole
upload:

```elixir
def create(conn, %{"document" => %Plug.Upload{} = upload}) do
  id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  content = File.stream!(upload.path, 65_536)

  case Fil.write(MyApp.Storage.uploads(), "documents/#{id}.pdf", content, if_exists: :error) do
    {:ok, document} ->
      json(conn, %{path: document.path})

    {:error, error} ->
      Logger.error("Document upload failed: " <> Exception.message(error))
      conn |> put_status(500) |> json(%{error: "The upload failed."})
  end
end
```

`Fil.write/4` finds the size of the file stream, so S3 sends the file in one request instead of uploading it in parts.
As with LiveView, `upload.filename` and `upload.content_type` come from the browser, so the path above is one the
server picked, and the content type comes from its extension through `Fil.Plugin.ContentType`.
