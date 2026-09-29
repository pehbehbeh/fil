# Phoenix

This guide stores files from a Phoenix app on a disk: uploads from a LiveView form with `Fil.LiveView`, uploads to a
controller, and links to the stored files. It uses the `MyApp.Storage.uploads/0` disk from the
[installation guide](installation.md), with `Fil.Plugin.ContentType` attached.

`Fil.LiveView` needs Phoenix LiveView 1.2. It's an optional dependency of `Fil`, so an app with LiveView 1.2 needs
nothing else.

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
writes against the extensions in `accept:` and refuses that file, so list extensions there, not only types such as
`image/*`. With types only, the extension isn't checked, unless you pass `extensions:`.

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
      {:ok, user} = Accounts.update_avatar(user, avatar.path)
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

The result is a list of refs in the order of the file input. Store `ref.path` in your database and rebuild the ref
with `Fil.ref/2` when you need the file again, because the disk can't be stored (see `Fil.Ref`).

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
blocks the LiveView until it's stored.

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

## Showing stored files

A signed URL lets the browser download a private file for a while, from S3 or through `Fil.Plug` (see
[Signed URLs](installation.md#signed-urls) in the installation guide):

```elixir
{:ok, avatar_url} = Fil.signed_url(MyApp.Storage.uploads(), user.avatar, expires_in: 3600)
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
