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
                Without this option, the consume functions take the extensions in the upload's `accept:` list, and
                `store_entry/4` checks none.
                """
              ],
              if_exists: [
                type: {:in, [:error, :overwrite]},
                default: :error,
                doc: """
                What to do if a file is already at the path, passed to `Fil.write/4`. `:error` writes nothing and
                gives a `Fil.AlreadyExistsError`, so an upload never replaces a file by accident. `:overwrite` replaces
                it.
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

    Needs Phoenix LiveView 1.2, an optional dependency of `Fil`.

    ## Paths

    `:path` decides where each file goes. The default is `filename/1`, the entry's UUID and its extension, such as
    `"0b2e8b8e-4a0a-4c1e-9d1e-2f6f4e0c7a11.png"`. The name the browser sent (`entry.client_name`) never becomes a path
    unless you put it there, because it can be anything: `../../config.exs`, a name another user already has, or
    `index.html`.

    A path that leaves the target gives a `Fil.InvalidRequestError` with `reason: :ebadpath` when the file is stored:
    with a directory as the target, `"../other.png"` is refused, and with a disk, a path that leaves the disk root.

    LiveView's `accept:` lets a file through when its type or its extension matches, and the type comes from the
    browser. With `accept: ~w(.png)`, a file named `evil.html` sent as `image/png` is accepted, and `filename/1` would
    name it `<uuid>.html`. So the consume functions check the extension of the final path against the extensions in
    `accept:` (or `:extensions`, when given), and refuse the file before anything is written. Use extensions in
    `accept:`, such as `~w(.jpg .png)`, so the check applies; with only types (`~w(image/*)`) nothing is checked.

    Every file is written with the content type of its path (`MIME.from_path/1`), never the type the browser sent. A
    path with an unknown extension is stored as `application/octet-stream`, which takes precedence over the
    `:default` of `Fil.Plugin.ContentType`.

    ## All or nothing

    `consume_uploaded_entries/4` writes every file, then consumes the entries. If a write fails, it deletes the files
    it wrote, keeps every entry in the upload, and returns the first error, so the user can submit the form again or
    cancel an entry. With `if_exists: :overwrite`, deleting a written file also deletes the file it replaced.

    Consuming talks to each entry's upload channel. If a channel is gone because the browser went away, the call exits
    as LiveView's own does, after deleting the files it wrote.

    The files are written in the LiveView process, as with LiveView's own `consume_uploaded_entries/3`. A large file
    blocks the LiveView until it's stored.

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

    # How much of the temporary file is read at a time.
    @chunk_size 65_536

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

      consume(socket, conf.entries, target, Keyword.put_new(opts, :extensions, accepted_extensions(conf)))
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

      case consume(socket, [entry], target, Keyword.put_new(opts, :extensions, accepted_extensions(conf))) do
        {:ok, [ref]} -> {:ok, ref}
        {:error, error} -> {:error, error}
      end
    end

    @doc """
    Writes one entry to `target`, without consuming it. `meta` is what LiveView passes to the function of its
    `Phoenix.LiveView.consume_uploaded_entries/3`, with the path of the temporary file.

    Returns `{:ok, ref}` or `{:error, exception}`. Checks the extension only against an explicit `:extensions`,
    because there's no socket to find the upload's `accept:` in. See
    [Building your own integration](#module-building-your-own-integration).

    Raises `ArgumentError` for a `meta` without a `:path`, such as from a custom `writer:` in `allow_upload/3`.
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
    defp consume(socket, entries, target, opts) do
      case write_all(socket, entries, target, opts) do
        {:ok, stored} ->
          consume_all(socket, stored)

        {:error, error, stored} ->
          delete(stored)
          {:error, error}

        {:raise, kind, reason, stacktrace, stored} ->
          delete(stored)
          :erlang.raise(kind, reason, stacktrace)

        {:exit, reason, stored} ->
          delete(stored)
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

    defp consume_all(socket, stored) do
      Enum.each(stored, fn {entry, ref} -> consume_entry(socket, entry, ref, stored) end)
      {:ok, Enum.map(stored, &elem(&1, 1))}
    end

    # Consumes a written entry, which drops it from the upload and deletes its temporary file.
    defp consume_entry(socket, entry, ref, stored) do
      consume = fn _meta -> {:ok, ref} end

      case call_channel(fn -> Phoenix.LiveView.consume_uploaded_entry(socket, entry, consume) end) do
        {:ok, ^ref} ->
          :ok

        {:exit, reason} ->
          delete(stored)
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
    defp delete(stored), do: Enum.each(stored, fn {_entry, ref} -> Fil.rm(ref) end)

    defp store(target, %{path: tmp_path}, entry, opts) do
      ref = build_ref(target, entry, opts[:path])

      # `Fil.write/4` finds the size of the temporary file, so S3 sends it in one request.
      with :ok <- check_extension(ref, opts[:extensions]) do
        content = File.stream!(tmp_path, @chunk_size)
        Fil.write(ref, content, if_exists: opts[:if_exists], content_type: MIME.from_path(ref.path))
      end
    end

    defp store(_target, meta, _entry, _opts) do
      raise ArgumentError,
            "expected the meta of LiveView's default upload writer, a map with the :path of the temporary file, " <>
              "got: #{inspect(meta)}"
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

    defp check_extension(_ref, nil), do: :ok

    defp check_extension(ref, extensions) do
      extension =
        ref.path
        |> Path.extname()
        |> String.downcase()

      if extension != "" and extension in Enum.map(extensions, &String.downcase/1) do
        :ok
      else
        {:error, %Fil.InvalidRequestError{reason: :extension, op: :write, path: ref.path, disk: ref.disk}}
      end
    end

    # The extensions in `accept:`, or nil for an upload that accepts only types or anything.
    defp accepted_extensions(conf) do
      case MapSet.to_list(conf.acceptable_exts) do
        [] -> nil
        extensions -> extensions
      end
    end
  end
end
