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

### The upload field

`Fil.LiveView.upload_field/1` renders the upload part of a form: a drop zone with the file input, a row for each picked
file with a preview, its progress and a cancel button, and a row for each file the record has, with a remove button.
Import it in the `html_helpers` of your web module, next to the core components:

```elixir
import MyAppWeb.CoreComponents
import Fil.LiveView, only: [upload_field: 1]
```

This form edits a product with up to five photos, stored in a `{:array, Fil.Ecto.Ref}` field (see
[Storing the files](#storing-the-files) for `Fil.Ecto.Ref`):

```elixir
schema "products" do
  field :name, :string
  field :photos, {:array, Fil.Ecto.Ref}, disk: &MyApp.Storage.uploads/0, default: []
end
```

The LiveView keeps the photos the product keeps in the `:photos` assign. Removing one drops it from that list, and
nothing is deleted before the product is saved:

```elixir
def mount(%{"id" => id}, _session, socket) do
  product = Catalog.get_product!(id)

  {:ok,
   socket
   |> assign(product: product, photos: product.photos, photo_errors: [])
   |> assign(:form, to_form(Catalog.change_product(product)))
   |> allow_upload(:photos, accept: ~w(.jpg .jpeg .png), max_entries: 5, max_file_size: 5_000_000)}
end
```

```heex
<.form for={@form} id="product-form" phx-change="validate" phx-submit="save">
  <.input field={@form[:name]} label="Name" />
  <.upload_field
    upload={@uploads.photos}
    existing={@photos}
    field={@form[:photos]}
    errors={@photo_errors}
    label="Photos"
    translate={&translate_error/1}
  />
  <.button phx-disable-with="Saving...">Save</.button>
</.form>
```

LiveView's `max_entries:` counts only the picked files, so the limit on the product is a `validate_length/3` in the
changeset. `validate/2` checks it with the photos the product would have after the save, the kept ones and the picked
ones LiveView accepted, and the component shows the error under the files. It also clears the error of the last save:

```elixir
def handle_event("validate", %{"product" => params}, socket), do: {:noreply, validate(socket, params)}

defp validate(socket, params) do
  changeset =
    socket.assigns.product
    |> change_photos(params, planned_photos(socket))
    |> Map.put(:action, :validate)

  assign(socket, form: to_form(changeset), photo_errors: [])
end

defp change_photos(product, params, photos) do
  product
  |> Catalog.change_product(params)
  |> Ecto.Changeset.put_change(:photos, photos)
  |> Ecto.Changeset.validate_length(:photos, max: 5)
end

# `entry_ref/3` returns the ref an entry will be written to, without writing anything.
defp planned_photos(socket) do
  picked =
    for entry <- socket.assigns.uploads.photos.entries, entry.valid? do
      Fil.LiveView.entry_ref(&MyApp.Storage.uploads/0, entry)
    end

  socket.assigns.photos ++ picked
end
```

The cancel and remove buttons send `"cancel-upload"` and `"remove-file"` to the LiveView, with the upload's name in
`"upload"`. `Fil.LiveView.cancel_upload/2` cancels the entry, and ignores one that's gone already (after a double click,
say), where LiveView's `cancel_upload/3` raises. A click doesn't send the form's `phx-change`, so both handlers call
`validate/2` with the form's last params, and a count error goes away once the user removed enough photos:

```elixir
def handle_event("cancel-upload", params, socket) do
  socket = Fil.LiveView.cancel_upload(socket, params)
  {:noreply, validate(socket, socket.assigns.form.params)}
end

def handle_event("remove-file", %{"upload" => "photos", "path" => path}, socket) do
  socket = update(socket, :photos, fn photos -> Enum.reject(photos, &(&1.path == path)) end)
  {:noreply, validate(socket, socket.assigns.form.params)}
end
```

`save` checks the same changeset again before it consumes the upload, so a product with too many photos keeps the
picked files. Then it stores the new files and puts the kept and the new ones into the changeset.
`Fil.Ecto.Ref.removed/2` returns the photos the change drops, which are deleted once the update is committed:

```elixir
def handle_event("save", %{"product" => params}, socket) do
  %{product: product, photos: kept} = socket.assigns
  planned = change_photos(product, params, planned_photos(socket))

  with true <- planned.valid?,
       {:ok, new} <- Fil.LiveView.consume_uploaded_entries(socket, :photos, &MyApp.Storage.uploads/0) do
    save_product(socket, change_photos(product, params, kept ++ new), new)
  else
    false -> {:noreply, assign(socket, :form, to_form(planned, action: :update))}
    {:error, error} -> {:noreply, assign(socket, :photo_errors, [error])}
  end
end

defp save_product(socket, changeset, new) do
  removed = Fil.Ecto.Ref.removed(changeset, :photos)

  case Repo.update(changeset) do
    {:ok, product} ->
      Enum.each(removed, &Fil.rm/1)

      {:noreply,
       socket
       |> assign(product: product, photos: product.photos, photo_errors: [])
       |> assign(:form, to_form(Catalog.change_product(product)))}

    {:error, changeset} ->
      Enum.each(new, &Fil.rm/1)
      {:noreply, assign(socket, :form, to_form(changeset))}
  end
end
```

A failed update deletes the new files again. Their entries are consumed by then, so the user picks the files again.
A failed consume keeps every entry and writes nothing, and the component shows its error from `photo_errors` until the
next change.

A single file works the same with a `Fil.Ecto.Ref` field: `existing={@avatar}` takes the ref or `nil`, and the save
puts `List.first(new) || kept` into the changeset. The component hides a single stored file while a new one is picked,
because saving replaces it. Every remove button sends the name of its upload, so a second field on the page gets a
clause of its own:

```elixir
def handle_event("remove-file", %{"upload" => "avatar"}, socket), do: {:noreply, assign(socket, :avatar, nil)}
```

With `auto_upload: true` and a `progress:` callback that consumes each entry when it's done (see
[below](#storing-each-file-when-it-s-uploaded)), a consumed entry leaves the list, so append its ref to the list you
pass as `existing`.

### Errors and translations

The component shows the errors of each picked file (too large, not accepted), of the upload (too many files), of the
field once files are picked or the form was submitted, and the ones you pass in `errors`. `Fil.LiveView.upload_error/2`
gives each a text as `{msgid, bindings}`, the shape of Ecto's errors, and `translate` turns it into text.

`translate={&translate_error/1}` looks the texts up in the `errors` domain of the app's Gettext backend, as for Ecto's
errors. The component's labels ("Cancel", "Remove", "or drop files here") go through it too. `mix gettext.extract`
doesn't find texts built in a dependency, so copy the msgids from the `Fil.LiveView.upload_field/1` docs into
`priv/gettext/errors.pot`. Without `translate`, the component fills in the bindings and translates nothing.

The same function gives a flash its text:

```elixir
{:error, error} ->
  message =
    error
    |> Fil.LiveView.upload_error()
    |> translate_error()

  {:noreply, put_flash(socket, :error, message)}
```

### Styling

The default classes are [daisyUI](https://daisyui.com) 5 classes, as in the `core_components.ex` Phoenix 1.8
generates. Tailwind builds only the classes it finds in its sources, and the generated `assets/css/app.css` doesn't
look into `deps`, so add a line for Fil next to the other `@source` lines:

```css
@source "../../deps/fil/lib/fil/live_view";
```

Without it, the file input, the drop zone and the error state have no styles.

Each part takes a class attribute that replaces its default, as `class` does on the generated components:
`class`, `label_class`, `dropzone_class`, `input_class`, `error_class`, `hint_class`, `list_class`, `entry_class`,
`progress_class`, `button_class` and `message_class`. The docs of each show its default, so to add a class, copy the
default and append to it. The `<div>` around the content of a row, the preview, the name and the size, and the `<div>`
around the error messages take no class attribute, and have only Tailwind utilities.

An app with a design of its own sets the classes once, in a wrapper in its `core_components.ex` that also sets
`translate`. A wrapper declares the slots it forwards:

```elixir
attr :upload, Phoenix.LiveView.UploadConfig, required: true
attr :existing, :any, default: []
attr :field, Phoenix.HTML.FormField, default: nil
attr :errors, :list, default: []
attr :label, :string, default: nil
slot :entry
slot :file

def upload_field(assigns) do
  ~H"""
  <Fil.LiveView.upload_field
    upload={@upload}
    existing={@existing}
    field={@field}
    errors={@errors}
    label={@label}
    translate={&translate_error/1}
    dropzone_class="flex flex-col gap-2 rounded-lg border border-zinc-300 p-3"
    button_class="rounded border border-zinc-300 px-2 py-1 text-xs"
  >
    <:entry :for={entry <- @entry} :let={upload_entry}>{render_slot(entry, upload_entry)}</:entry>
    <:file :for={file <- @file} :let={ref}>{render_slot(file, ref)}</:file>
  </Fil.LiveView.upload_field>
  """
end
```

The wrapper takes the name `upload_field`, so leave out the import of `Fil.LiveView`'s in that case.

Without daisyUI, its class names and theme colours do nothing, and the Tailwind utilities still apply. Tailwind's
preflight strips the look of the file input and the buttons, so pass `input_class` and `button_class` too.

The `:file` slot replaces the content of a stored file's row, and `:entry` that of a picked file's row. The row itself
stays, with its buttons, progress bar and errors. Stored paths are UUIDs, so a form with images shows a thumbnail. The
component calls no `Fil` function while it renders, so the URLs are built before. A helper that `mount/3` and the save
call instead of assigning `:photos` keeps them in step with the photos:

```elixir
defp assign_photos(socket, photos) do
  urls = Map.new(photos, &{&1.path, Fil.signed_url!(&1, expires_in: 3600)})
  assign(socket, photos: photos, photo_urls: urls)
end
```

```heex
<.upload_field upload={@uploads.photos} existing={@photos} label="Photos">
  <:file :let={photo}>
    <img src={@photo_urls[photo.path]} alt="" width="48" height="48" class="size-12 rounded object-cover" />
  </:file>
</.upload_field>
```

A signed URL works for `expires_in` seconds, so a form that stays open longer shows broken thumbnails until it's
loaded again. Removing a photo needs no new URLs, and appending one after an auto upload goes through the helper too.

### Your own markup

The component is optional. A template of your own uses LiveView's components (see
[Uploads](https://hexdocs.pm/phoenix_live_view/uploads.html) in its docs), and `Fil.LiveView.upload_error/2` for the
texts:

```heex
<form id="avatar-form" phx-change="validate" phx-submit="save">
  <.live_file_input upload={@uploads.avatar} />

  <div :for={entry <- @uploads.avatar.entries}>
    <.live_img_preview entry={entry} width="80" />
    <progress value={entry.progress} max="100">{entry.progress}%</progress>
    <button type="button" phx-click="cancel" phx-value-ref={entry.ref}>Cancel</button>
    <p :for={error <- upload_errors(@uploads.avatar, entry)}>
      {translate_error(Fil.LiveView.upload_error(error, @uploads.avatar))}
    </p>
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

`Fil.LiveView.consume_uploaded_entries/4` writes each file to the disk and consumes its entry. Here it is on its own,
for the avatar form above:

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
      {:noreply, put_flash(socket, :error, avatar_error(error))}
  end
end

defp avatar_error(%Fil.InvalidRequestError{reason: :extension}), do: "Only .jpg and .png files can be uploaded."
defp avatar_error(%Fil.AlreadyExistsError{}), do: "This file was uploaded already."

defp avatar_error(error) do
  Logger.error("Avatar upload failed: " <> Exception.message(error))
  "The upload failed. Please try again."
end
```

An error's message names the disk and the path in storage, so it's for logs, not for users. `avatar_error/1` picks a
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
{:error, error} -> {:noreply, assign(socket, :upload_error, avatar_error(error))}
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
    {:error, error} -> {:noreply, put_flash(socket, :error, avatar_error(error))}
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
