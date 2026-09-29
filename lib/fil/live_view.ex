if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Fil.LiveView do
    @schema NimbleOptions.new!(
              path: [
                type: {:fun, 1},
                default: &__MODULE__.filename/1,
                doc: """
                Gets the `Phoenix.LiveView.UploadEntry` and returns the path of the file, relative to the target.
                The path may contain directories. It has to be the same each time for the same entry, because
                `entry_ref/3` and the write call it separately, so build it from `entry.uuid` (as `filename/1` does)
                and the socket's assigns, not from the time or a random value. `entry.client_name`,
                `client_relative_path`, `client_type` and `client_size` come from the browser and can be anything. A
                result that isn't a string raises `ArgumentError`.
                """
              ],
              extensions: [
                type: {:list, :string},
                doc: """
                The extensions the path may end with, such as `[".jpg", ".png"]`. They're compared with the path
                `:path` returned, in lowercase, before anything is written. A path with another extension, or without
                one, gives a `Fil.InvalidRequestError` with `reason: :extension`, and an empty list refuses every file.
                Without this option, the consume functions and `external/2` take the extensions the upload's
                `accept:` allows (see [Paths](#module-paths)), and `store_entry/4` checks none.
                """
              ],
              if_exists: [
                type: {:in, [:error, :overwrite]},
                default: :error,
                doc: """
                What to do if a file is already at the path, passed to `Fil.write/4`, or signed into the URL by
                `external/2`. `:error` writes nothing and gives a `Fil.AlreadyExistsError`, so an upload never replaces
                a file by accident. `:overwrite` replaces it.
                """
              ],
              max_file_size: [
                type: :pos_integer,
                doc: """
                The largest file in bytes that `store_entry/4` keeps from a direct upload. A larger one is deleted
                and gives a `Fil.InvalidRequestError` with `reason: :too_large`. The consume functions take the
                upload's `max_file_size`.
                """
              ]
            )

    @moduledoc """
    Stores [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view) uploads on a disk.

    Allow the upload as usual, then consume it with `consume_uploaded_entries/4` instead of LiveView's own function:

        def handle_event("save", _params, socket) do
          user = socket.assigns.current_user

          case Fil.LiveView.consume_uploaded_entries(socket, :avatar, &MyApp.Storage.uploads/0,
                 path: &"avatars/\#{user.id}/\#{Fil.LiveView.filename(&1)}"
               ) do
            {:ok, [avatar]} ->
              {:noreply, save_avatar(socket, avatar.path)}

            {:ok, []} ->
              {:noreply, socket}

            {:error, %Fil.InvalidRequestError{reason: :extension}} ->
              {:noreply, put_flash(socket, :error, "Only .jpg and .png files can be uploaded.")}

            {:error, error} ->
              Logger.error("Avatar upload failed: " <> Exception.message(error))
              {:noreply, put_flash(socket, :error, "The upload failed. Please try again.")}
          end
        end

    Each file is streamed from LiveView's temporary file into `Fil.write/4`, and the result is a list of `Fil.Ref`
    structs in the order of the file input. The [Phoenix guide](phoenix.md) walks through the whole form.

    An error's message names the disk and the path in storage, so it's for logs. Show users a text of your own, chosen
    by the error struct and its `:reason`.

    The target is where the files go: a `Fil.Ref` for a directory, or a disk as `Fil.Disk.resolve/1` takes it (a
    disk, a 0-arity function or `{module, function, args}`). Paths are relative to the directory or the disk root.

    Needs Phoenix LiveView 1.2 and Phoenix 1.8, optional dependencies of `Fil`.

    ## Paths

    `:path` decides where each file goes. The default is `filename/1`, the entry's UUID and its extension, such as
    `"0b2e8b8e-4a0a-4c1e-9d1e-2f6f4e0c7a11.png"`. The name the browser sent (`entry.client_name`) never becomes a path
    unless you put it there, because it can be anything: `../../config.exs`, a name another user already has, or
    `index.html`.

    A path that leaves the target gives a `Fil.InvalidRequestError` with `reason: :ebadpath` when the file is stored:
    with a directory as the target, `"../other.png"` is refused, and with a disk, a path that leaves the disk root.

    LiveView's `accept:` lets a file through when its type or its extension matches, and the type comes from the
    browser. With `accept: ~w(.png)`, a file named `evil.html` sent as `image/png` is accepted, and `filename/1` would
    name it `<uuid>.html`. So the consume functions check the extension of the final path before anything is written,
    against the extensions `accept:` allows: the ones it lists, and those of its exact types (`image/png` allows
    `.png`). `:extensions` replaces that list. A wildcard such as `image/*` allows no extension of its own, so with only
    wildcards nothing is checked, and a mixed list such as `~w(.pdf image/*)` refuses every image with
    `reason: :extension`. List the extensions a wildcard stands for too, in `accept:` or in `:extensions`.

    Every file is written with the content type of its path (`MIME.from_path/1`), never the type the browser sent. A
    path with an unknown extension is stored as `application/octet-stream`, which takes precedence over the
    `:default` of `Fil.Plugin.ContentType`.

    ## All or nothing

    `consume_uploaded_entries/4` writes every file, then consumes the entries. If a write fails, it deletes the files
    it wrote, keeps every entry in the upload, and returns the first error, so the user can submit the form again or
    cancel an entry. With `if_exists: :overwrite`, deleting a written file also deletes the file it replaced. The same
    can happen with the default `if_exists: :error` on S3-compatible servers that ignore the conditional write (see
    `Fil.write/4`): a `path:` that collides with an existing file replaces it, and a later failure deletes it, which
    paths with the entry's UUID, as `filename/1` builds them, avoid.

    Consuming talks to each entry's upload channel. If a channel is gone because the browser went away, the call exits
    as LiveView's own does, after deleting the files it wrote.

    The files are written in the LiveView process, as with LiveView's own `consume_uploaded_entries/3`. A large file
    blocks the LiveView until it's stored. Direct uploads don't.

    ## Direct uploads

    With `external/2`, the browser uploads each file straight to the disk, and the content never passes through the
    LiveView:

        allow_upload(socket, :avatar,
          accept: ~w(.jpg .png),
          max_file_size: 20_000_000,
          external: Fil.LiveView.external(&MyApp.Storage.uploads/0)
        )

    It works on every disk that signs upload URLs: S3 with a presigned PUT, and a disk with `Fil.Plugin.URL` and a
    `:secret` through `Fil.Plug` in your endpoint. Each URL is bound to the content type of the path, the size the
    browser reported and `if_exists: :error` (see [Uploads](Fil.html#signed_url/1-uploads)), so it uploads one file
    once, and nobody who has the URL can replace the file after it was consumed.

    The browser side is the `Fil` uploader, which comes with `Fil` as colocated JS. A Phoenix 1.8 app passes it to its
    `LiveSocket` in `assets/js/app.js`:

    ```javascript
    import {uploaders} from "phoenix-colocated/fil"

    const liveSocket = new LiveSocket("/live", Socket, {hooks: {...colocatedHooks}, uploaders, params: {_csrf_token}})
    ```

    Consume the upload with the same target and `:path` as `external/2`. The consume functions don't write anything
    then: they check the file with `Fil.stat/2`. A file that isn't there gives the `Fil.NotFoundError` of `stat`. A
    file larger than the upload's `max_file_size` can only come from something else writing to the path, so it's
    deleted, with a `Fil.InvalidRequestError` with `reason: :too_large`. Otherwise a failed consume never deletes the
    file of a direct upload, and the form can be submitted again.

    A presigned PUT goes to S3 directly, so none of the disk's plugins run: no encryption or compression, and no
    `Fil.Plugin.Thumbnails`. Uploads through `Fil.Plug` are written with `Fil.write/4`, where plugins run. For
    thumbnails on S3, attach `Fil.Plugin.Thumbnails` with `mode: :manual` and call
    `Fil.Plugin.Thumbnails.generate/1` with each ref the consume returns.

    A file whose form is never submitted stays on the disk. The [Phoenix guide](phoenix.md#files-nobody-consumes)
    shows how to clean those up, and the CORS rule an S3 bucket needs.

    ## Building your own integration

    Code that calls LiveView's `Phoenix.LiveView.consume_uploaded_entries/3` itself, to do more in the same callback,
    stores each entry with `store_entry/4`:

        Phoenix.LiveView.consume_uploaded_entries(socket, :avatar, fn meta, entry ->
          case Fil.LiveView.store_entry(&MyApp.Storage.uploads/0, meta, entry) do
            {:ok, avatar} -> {:ok, avatar}
            {:error, error} -> {:postpone, error}
          end
        end)

    `entry_ref/3` returns the ref an entry will be written to, without writing anything, for a form that saves the
    path before it consumes the upload. Both take the same options as the consume functions.

    ## Testing

    Uploads in `Phoenix.LiveViewTest` to a memory disk need only `Fil.Adapter.Memory.checkout/0` in the test, no
    `Fil.Adapter.Memory.allow/2`: the LiveView process finds the test's store through `$callers`.

    ## Options

    #{NimbleOptions.docs(@schema)}
    """

    alias Phoenix.LiveView.Socket
    alias Phoenix.LiveView.UploadEntry

    require Logger

    # `external/2` takes the options of the consume functions, and how long the URL is valid instead of a size limit,
    # which the URL has already.
    @external_schema @schema.schema
                     |> Keyword.delete(:max_file_size)
                     |> Keyword.put(
                       :expires_in,
                       type: {:in, 1..(7 * 24 * 60 * 60)},
                       default: 300,
                       doc: """
                       How long the upload URL stays valid, in seconds. LiveView asks for it right before the upload
                       starts, and the storage checks it when the request starts, so a large file that takes longer
                       still arrives.
                       """
                     )
                     |> NimbleOptions.new!()

    # How much of the temporary file is read at a time.
    @chunk_size 65_536

    # The `accept:` filters that stand for a kind of file, not one type.
    @wildcards ~w(audio/* image/* video/*)

    @typedoc "Where the files go: a ref for a directory, or a disk as `Fil.Disk.resolve/1` takes it."
    @type target :: Fil.Ref.t() | Fil.Disk.source()

    @doc """
    Writes the uploaded files of the upload `name` to `target` and consumes their entries.

    Returns `{:ok, refs}` in the order of the file input, `{:ok, []}` when nothing was uploaded, or the first
    `{:error, exception}`, with nothing written and every entry kept (see [All or nothing](#module-all-or-nothing)).
    Raises `ArgumentError`, as LiveView does, when entries are still in progress or `name` isn't an allowed upload.
    """
    @spec consume_uploaded_entries(Socket.t(), atom() | String.t(), target(), keyword()) :: Fil.result([Fil.Ref.t()])
    def consume_uploaded_entries(%Socket{} = socket, name, target, opts \\ []) do
      opts = NimbleOptions.validate!(opts, @schema)

      conf = socket.assigns[:uploads][name] || raise ArgumentError, "no upload allowed for #{inspect(name)}"

      if not Enum.all?(conf.entries, & &1.done?) do
        raise ArgumentError, "cannot consume uploaded files when entries are still in progress"
      end

      consume(socket, conf, conf.entries, target, upload_opts(opts, conf))
    end

    @doc """
    Writes one uploaded entry to `target` and consumes it.

    For uploads with `auto_upload: true` and a `progress:` callback, which consume each entry when it's done:

        defp handle_progress(:avatar, entry, socket) when entry.done? do
          case Fil.LiveView.consume_uploaded_entry(socket, entry, &MyApp.Storage.uploads/0) do
            {:ok, avatar} ->
              {:noreply, assign(socket, :avatar, avatar.path)}

            {:error, error} ->
              Logger.error("Avatar upload failed: " <> Exception.message(error))
              {:noreply, put_flash(socket, :error, "The upload failed. Please try again.")}
          end
        end

        defp handle_progress(:avatar, _entry, socket), do: {:noreply, socket}

    Returns `{:ok, ref}`, or `{:error, exception}` with nothing written and the entry kept in the upload. Raises
    `ArgumentError` when the entry is still in progress.
    """
    @spec consume_uploaded_entry(Socket.t(), UploadEntry.t(), target(), keyword()) :: Fil.result(Fil.Ref.t())
    def consume_uploaded_entry(%Socket{} = socket, %UploadEntry{} = entry, target, opts \\ []) do
      opts = NimbleOptions.validate!(opts, @schema)

      if not entry.done? do
        raise ArgumentError, "cannot consume uploaded files when entries are still in progress"
      end

      conf = Map.fetch!(socket.assigns.uploads, entry.upload_config)

      case consume(socket, conf, [entry], target, upload_opts(opts, conf)) do
        {:ok, [ref]} -> {:ok, ref}
        {:error, error} -> {:error, error}
      end
    end

    @doc """
    Returns the function for `external:` in `Phoenix.LiveView.allow_upload/3`, which lets the browser upload each file
    straight to `target`, on every disk.

        allow_upload(socket, :avatar,
          accept: ~w(.jpg .png),
          max_file_size: 20_000_000,
          external: Fil.LiveView.external(&MyApp.Storage.uploads/0)
        )

    For each file, the function builds its path with `:path`, checks its extension, and signs an upload URL for it
    with `Fil.signed_url/3`, bound to the content type of the path, the size the browser reported and `:if_exists`.
    The browser side is the `Fil` uploader (see [Direct uploads](#module-direct-uploads)). Consume the upload with the
    same target and `:path` as usual; the consume functions check the file instead of writing it.

    A path the extension check refuses gives the entry the error `{:external_metadata_failure, %{reason: :extension}}`
    in `Phoenix.Component.upload_errors/2`. Any other error, such as a disk that can't sign URLs, gives
    `{:external_metadata_failure, %{reason: :error}}` and is logged with `Logger.error/1`. LiveView sends the error to
    the browser too, so it holds no message, which would name the disk and the path.

    ## Options

    #{NimbleOptions.docs(@external_schema)}
    """
    @spec external(target(), keyword()) :: (UploadEntry.t(), Socket.t() ->
                                              {:ok | :error, map(), Socket.t()})
    def external(target, opts \\ []) do
      opts = NimbleOptions.validate!(opts, @external_schema)

      fn %UploadEntry{} = entry, %Socket{} = socket ->
        conf = Map.fetch!(socket.assigns.uploads, entry.upload_config)

        case sign(target, entry, Keyword.put_new(opts, :extensions, accepted_extensions(conf))) do
          {:ok, meta} -> {:ok, meta, socket}
          {:error, error} -> {:error, error_meta(error), socket}
        end
      end
    end

    @doc """
    Writes one entry to `target`, without consuming it. `meta` is what LiveView passes to the function of its
    `Phoenix.LiveView.consume_uploaded_entries/3`, with the path of the temporary file.

    Returns `{:ok, ref}` or `{:error, exception}`. Checks the extension only against an explicit `:extensions`,
    because there's no socket to find the upload's `accept:` in. See
    [Building your own integration](#module-building-your-own-integration).

    With the meta of `external/2`, the file is on the disk already, so it's checked instead of written, as the
    consume functions do (see [Direct uploads](#module-direct-uploads)), with `:max_file_size` as the limit.

    Raises `ArgumentError` for any other `meta` without a `:path`: the meta of another external uploader, or of a
    custom `writer:`. Neither leaves a temporary file to store.
    """
    @spec store_entry(target(), map(), UploadEntry.t(), keyword()) :: Fil.result(Fil.Ref.t())
    def store_entry(target, meta, %UploadEntry{} = entry, opts \\ []) do
      opts = NimbleOptions.validate!(opts, @schema)
      store(target, meta, entry, opts)
    end

    @doc """
    Returns the ref `entry` will be written to in `target`, without writing or checking anything, like `Fil.ref/2`.

    Takes the same options as `store_entry/4`, and uses only `:path`. A path the write refuses, for its extension or
    because it leaves the target, gives the error when the entry is stored.
    """
    @spec entry_ref(target(), UploadEntry.t(), keyword()) :: Fil.Ref.t()
    def entry_ref(target, %UploadEntry{} = entry, opts \\ []) do
      opts = NimbleOptions.validate!(opts, @schema)
      build_ref(target, entry, opts[:path])
    end

    @doc """
    Returns the default path of an entry: its UUID and the extension of the name the browser sent, in lowercase.

    An extension that isn't 1 to 16 ASCII letters and digits is left out, so the name the browser sent never adds
    anything else to the path.

        iex> entry = %Phoenix.LiveView.UploadEntry{uuid: "0b2e8b8e", client_name: "Holiday.PNG"}
        iex> Fil.LiveView.filename(entry)
        "0b2e8b8e.png"
        iex> Fil.LiveView.filename(%{entry | client_name: "x.ph/p"})
        "0b2e8b8e"
        iex> Fil.LiveView.filename(%{entry | client_name: "noext"})
        "0b2e8b8e"

    """
    @spec filename(UploadEntry.t()) :: String.t()
    def filename(%UploadEntry{uuid: uuid, client_name: client_name}) do
      extension =
        client_name
        |> Path.extname()
        |> String.downcase()

      if extension =~ ~r/\A\.[a-z0-9]{1,16}\z/, do: uuid <> extension, else: uuid
    end

    # Pass 1 writes every entry and postpones it, so LiveView keeps its temporary file and channel. Only when every
    # write worked, pass 2 consumes them. On an error, the files pass 1 wrote are deleted and every entry stays in the
    # upload. Both passes call the entry's upload channel, which exits if the channel died (the client went away); the
    # files are deleted then too, and the exit goes on. An exception from a write or a `:path` function is raised again
    # after the files are deleted.
    #
    # Files of direct uploads (`external/2`) were written by the browser, not by this call, so they're never deleted:
    # the user can submit the form again, and the file is still there.
    defp consume(socket, conf, entries, target, opts) do
      case write_all(socket, entries, target, opts) do
        {:ok, stored} ->
          consume_all(socket, conf, stored)

        {:error, error, stored} ->
          delete(conf, stored)
          {:error, error}

        {:raise, kind, reason, stacktrace, stored} ->
          delete(conf, stored)
          :erlang.raise(kind, reason, stacktrace)

        {:exit, reason, stored} ->
          delete(conf, stored)
          exit(reason)
      end
    end

    defp write_all(socket, entries, target, opts) do
      case Enum.reduce_while(entries, {:ok, []}, &write_entry(socket, &1, target, opts, &2)) do
        {:ok, stored} -> {:ok, Enum.reverse(stored)}
        failed -> failed
      end
    end

    # Writes the entry and postpones it, so LiveView keeps it. `stored` is what this call wrote so far.
    defp write_entry(socket, entry, target, opts, {:ok, stored}) do
      write = fn meta -> {:postpone, catch_all(fn -> store(target, meta, entry, opts) end)} end

      case call_channel(fn -> Phoenix.LiveView.consume_uploaded_entry(socket, entry, write) end) do
        {:ok, {:ok, ref}} -> {:cont, {:ok, [{entry, ref} | stored]}}
        {:ok, {:error, error}} -> {:halt, {:error, error, stored}}
        {:ok, {:raise, kind, reason, stacktrace}} -> {:halt, {:raise, kind, reason, stacktrace, stored}}
        {:exit, reason} -> {:halt, {:exit, reason, stored}}
      end
    end

    defp consume_all(socket, conf, stored) do
      Enum.each(stored, fn {entry, ref} -> consume_entry(socket, conf, entry, ref, stored) end)
      {:ok, Enum.map(stored, &elem(&1, 1))}
    end

    # Consumes a written entry, which drops it from the upload and deletes its temporary file.
    defp consume_entry(socket, conf, entry, ref, stored) do
      consume = fn _meta -> {:ok, ref} end

      case call_channel(fn -> Phoenix.LiveView.consume_uploaded_entry(socket, entry, consume) end) do
        {:ok, ^ref} ->
          :ok

        {:exit, reason} ->
          delete(conf, stored)
          exit(reason)
      end
    end

    defp call_channel(fun) do
      {:ok, fun.()}
    catch
      :exit, reason -> {:exit, reason}
    end

    # Runs in LiveView's consume function, which consumes the entry if it raises. Catching keeps the entry, so the
    # files of the other entries can be deleted first.
    defp catch_all(fun) do
      fun.()
    catch
      kind, reason -> {:raise, kind, reason, __STACKTRACE__}
    end

    # A failing delete is ignored, because the caller needs the original error.
    defp delete(%{external: false}, stored), do: Enum.each(stored, fn {_entry, ref} -> Fil.rm(ref) end)
    defp delete(_direct_upload, _stored), do: :ok

    # The consume functions check the upload's extensions and size limit, unless the caller passed their own.
    defp upload_opts(opts, conf) do
      opts
      |> Keyword.put_new(:extensions, accepted_extensions(conf))
      |> Keyword.put_new(:max_file_size, conf.max_file_size)
    end

    # The meta of `external/2`, which LiveView keeps on the server, so the browser can't change the path. The browser
    # has uploaded the file, so it's only checked. The signed URL bound its size, so a file over the limit can only
    # come from something else writing to the path.
    defp store(target, %{uploader: "Fil", path: path}, _entry, opts) do
      ref =
        case target do
          %Fil.Ref{disk: disk} ->
            Fil.ref(disk, path)

          source ->
            source
            |> Fil.Disk.resolve()
            |> Fil.ref(path)
        end

      with {:ok, stat} <- Fil.stat(ref) do
        check_size(ref, stat.size, opts[:max_file_size])
      end
    end

    defp store(target, %{path: tmp_path}, entry, opts) do
      ref = build_ref(target, entry, opts[:path])

      # `Fil.write/4` finds the size of the temporary file, so S3 sends it in one request.
      with :ok <- check_extension(ref, opts[:extensions], :write) do
        content = File.stream!(tmp_path, @chunk_size)
        Fil.write(ref, content, if_exists: opts[:if_exists], content_type: MIME.from_path(ref.path))
      end
    end

    defp store(_target, meta, _entry, _opts) do
      raise ArgumentError,
            "expected the meta of an upload through LiveView's channel with its default writer, a map with " <>
              "the :path of the temporary file, or of Fil.LiveView.external/2, got: #{inspect(meta)}. Other " <>
              "external uploads (external: in allow_upload/3) and custom writers leave no temporary file to store"
    end

    defp check_size(ref, size, max_file_size) when is_integer(max_file_size) and size > max_file_size do
      Fil.rm(ref)
      {:error, %Fil.InvalidRequestError{reason: :too_large, op: :stat, path: ref.path, disk: ref.disk}}
    end

    defp check_size(ref, _size, _max_file_size), do: {:ok, ref}

    # Signs the upload URL for `external/2`, with the content type of the path, as a written file gets it. The browser
    # can't set `content-length`, and sends the size of the file it has, which LiveView checked against
    # `max_file_size` already.
    defp sign(target, entry, opts) do
      ref = build_ref(target, entry, opts[:path])
      content_type = MIME.from_path(ref.path)

      signed =
        with :ok <- check_extension(ref, opts[:extensions], :signed_url) do
          Fil.signed_url(ref,
            method: :put,
            expires_in: opts[:expires_in],
            content_type: content_type,
            size: entry.client_size,
            if_exists: opts[:if_exists]
          )
        end

      with {:ok, url} <- signed do
        if_none_match = if opts[:if_exists] == :error, do: [{"if-none-match", "*"}], else: []
        headers = Map.new([{"content-type", content_type} | if_none_match])

        {:ok, %{uploader: "Fil", url: url, path: ref.path, headers: headers}}
      end
    end

    # LiveView sends the error meta to the browser, so it holds only a reason, and the message, which names the disk and
    # the path, goes to the log. A refused extension comes from the user's file, so it isn't logged.
    defp error_meta(%Fil.InvalidRequestError{reason: :extension}), do: %{reason: :extension}

    defp error_meta(error) do
      Logger.error("Fil.LiveView.external/2: " <> Exception.message(error))
      %{reason: :error}
    end

    defp build_ref(target, entry, path_fun) do
      path =
        case path_fun.(entry) do
          path when is_binary(path) -> path
          other -> raise ArgumentError, "expected the :path function to return a string, got: #{inspect(other)}"
        end

      case target do
        %Fil.Ref{disk: disk, path: dir} ->
          directory_ref(disk, dir, path)

        source ->
          source
          |> Fil.Disk.resolve()
          |> Fil.ref(path)
      end
    end

    # A directory is a jail: the path is normalized on its own, so its `..` can't climb out of the directory. A path
    # that tries also climbs out of the disk root on its own, so it's kept as it is, and using the ref gives a
    # `Fil.InvalidRequestError` with `reason: :ebadpath`, as for any other path that leaves the root.
    defp directory_ref(disk, dir, path) do
      case Fil.Support.Path.normalize(path) do
        {:ok, normalized} -> Fil.ref(disk, Path.join(dir, normalized))
        {:error, :ebadpath} -> Fil.ref(disk, path)
      end
    end

    defp check_extension(_ref, nil, _op), do: :ok

    defp check_extension(ref, extensions, op) do
      extension =
        ref.path
        |> Path.extname()
        |> String.downcase()

      if extension != "" and extension in Enum.map(extensions, &String.downcase/1) do
        :ok
      else
        {:error, %Fil.InvalidRequestError{reason: :extension, op: op, path: ref.path, disk: ref.disk}}
      end
    end

    # The extensions `accept:` allows: the ones it lists, and those of its exact types. LiveView keeps the list as the
    # `accept` attribute of the file input. Wildcards allow none, and nil means no check: for `accept: :any`, or a list
    # of wildcards only.
    defp accepted_extensions(%{accept: :any}), do: nil

    defp accepted_extensions(%{accept: accept}) do
      extensions =
        accept
        |> String.split(",")
        |> Enum.flat_map(&filter_extensions/1)
        |> Enum.uniq()

      if extensions != [], do: extensions
    end

    defp filter_extensions("." <> _name = extension), do: [extension]
    defp filter_extensions(wildcard) when wildcard in @wildcards, do: []

    defp filter_extensions(type) do
      type
      |> MIME.extensions()
      |> Enum.map(&("." <> &1))
    end
  end
end
