if Code.ensure_loaded?(Backpex.Field) do
  defmodule Fil.Backpex.Upload do
    # The field's options: Backpex's options of `Backpex.Fields.Upload` with this field's defaults and texts, and its
    # own.
    @schema [
      accept: [
        type: {:list, :string},
        doc: """
        The files the file input takes, as extensions and types, such as `~w(.jpg .png)`, passed to
        `Phoenix.LiveView.allow_upload/3`. Required unless `:extensions` is given, which it defaults to then. A list
        that allows no extension, such as `~w(image/*)`, raises unless `:extensions` is given, because a wildcard lets
        through any path, `.svg` and `.html` included.
        """
      ],
      max_entries: [
        type: :pos_integer,
        doc: """
        How many files can be picked at once, passed to `Phoenix.LiveView.allow_upload/3`. Required for an
        `{:array, Fil.Ecto.Ref}` field. A `Fil.Ecto.Ref` field holds one file, so it takes only `1`, its default there.
        The number of files a record keeps is `Ecto.Changeset.validate_length/3` (see [Errors](#module-errors)).
        """
      ],
      max_file_size: [
        type: :pos_integer,
        default: 8_000_000,
        doc: """
        The largest file in bytes, passed to `Phoenix.LiveView.allow_upload/3`. A direct upload's file is checked
        against it again when it's stored.
        """
      ],
      upload_key: [
        type: :atom,
        doc: "The name of the upload in LiveView. Defaults to the name of the field."
      ],
      file_label: [
        type: {:fun, 1},
        default: &Path.basename/1,
        doc: "Returns the label of a stored file from its path, in the form and on the index and show pages."
      ],
      path: [
        type: {:or, [{:fun, 1}, {:fun, 2}]},
        default: &Fil.LiveView.filename/1,
        doc: """
        The path of each file, relative to the disk root: a function of the `Phoenix.LiveView.UploadEntry`, or of the
        entry and the form's assigns. It has to return the same path each time for the same entry (see
        [Paths](#module-paths)).
        """
      ],
      direct: [
        type: :boolean,
        default: false,
        doc: """
        Lets the browser upload the files straight to the disk, through `Fil.LiveView.external/2` (see
        [Direct uploads](#module-direct-uploads)).
        """
      ],
      extensions: [
        type: {:list, :string},
        doc: """
        The extensions the path of a file may end with, such as `[".jpg", ".png"]`, compared in lowercase before the
        record is saved. By default the extensions `:accept` allows: the ones it lists, and those of its exact types
        (`image/png` allows `.png`). An empty list raises.
        """
      ],
      if_exists: [
        type: {:in, [:error, :overwrite]},
        default: :error,
        doc: """
        What to do if a file is already at the path. `:error` refuses the upload with a `Fil.AlreadyExistsError`, and
        `:overwrite` replaces the file. Paths from `Fil.LiveView.filename/1` never collide, so a path of your own that
        stays the same between uploads needs `:overwrite`. With `direct: true`, `:overwrite` raises (see
        [Paths](#module-paths)).
        """
      ]
    ]

    @moduledoc """
    A [Backpex](https://backpex.live) upload field for `Fil.Ecto.Ref` fields, which stores the files on the field's
    disk.

    The schema decides the disk and how many files the field holds: a `Fil.Ecto.Ref` field holds one file, an
    `{:array, Fil.Ecto.Ref}` field several, in order.

        schema "products" do
          field :name, :string
          field :avatar, Fil.Ecto.Ref, disk: &MyApp.Storage.uploads/0
          field :photos, {:array, Fil.Ecto.Ref}, disk: &MyApp.Storage.uploads/0, default: []
        end

        def changeset(product, attrs, _metadata) do
          product
          |> cast(attrs, [:name])
          |> validate_length(:photos, max: 5)
        end

    The LiveResource gives the field no callbacks:

        @impl Backpex.LiveResource
        def fields do
          [
            name: %{module: Backpex.Fields.Text, label: "Name"},
            avatar: %{module: Fil.Backpex.Upload, label: "Avatar", accept: ~w(.jpg .png), max_file_size: 2_000_000},
            photos: %{module: Fil.Backpex.Upload, label: "Photos", accept: ~w(.jpg .png), max_entries: 5}
          ]
        end

    The field builds Backpex's upload callbacks from the schema. Each new file goes into the record as the ref of
    `Fil.LiveView.entry_ref/3`, and is written with `Fil.LiveView.store_entry/4` once the record is saved (with
    `direct: true` the browser has written it already, see [Direct uploads](#module-direct-uploads)). The files the
    save drops are deleted then. It renders as `Backpex.Fields.Upload` does, with Backpex's drop zone, buttons and
    texts, and Backpex's general field options (`label`, `help_text`, `only` and the others in `Backpex.Field`) work as
    on any field.

    Leave the field out of `cast/4`. The field puts its value into the changeset before the changeset function runs,
    and only ever a ref, a list of refs or `nil`, never a param from the browser.

    A single file is replaced by uploading a new one: the stored file stays in the list until the record is saved, and
    the save deletes it. Its remove button clears the field.

    Needs Backpex 0.20 or later, an optional dependency of `Fil`, and an adapter with a `:schema` such as
    `Backpex.Adapters.Ecto`.

    ## Paths

    `:path` builds the path of each file, by default with `Fil.LiveView.filename/1`: the entry's UUID and its
    extension. The field calls it for each form change, for the ref in the record and for the write after the save, so
    it has to return the same path each time. Build it from `entry.uuid` and values that don't change while the form is
    open. With 2 arities, it gets the form's assigns too:

        path: &"products/\#{&2.current_user.id}/\#{Fil.LiveView.filename(&1)}"

    Read only `assigns.item` and what the `on_mount` hooks of the live session assign, such as `current_user`, never
    `changeset` or `form`. `assigns.item` is the record as it was loaded, without the form's changes, and on the new
    page an empty struct whose id is `nil`. When the path a file was written to isn't in the saved record, the field
    logs an error.

    Paths by the record's id need the id, which a new record gets only from the insert. Move its files in the
    LiveResource's `c:Backpex.LiveResource.on_item_created/2`, which runs after they're written:

        @impl Backpex.LiveResource
        def on_item_created(socket, %{avatar: %Fil.Ref{} = avatar} = product) do
          path = "products/\#{product.id}/\#{Path.basename(avatar.path)}"

          with {:ok, moved} <- Fil.rename(avatar, path),
               {:ok, _product} <- product |> Ecto.Changeset.change(avatar: moved) |> MyApp.Repo.update() do
            :ok
          else
            {:error, error} -> Logger.error("Could not move the avatar of product \#{product.id}: \#{inspect(error)}")
          end

          socket
        end

        def on_item_created(socket, _product), do: socket

    The rename comes first. If it fails, the record keeps the old path, where the file still is. If the update fails
    after it, the record points at the old path, where the file no longer is, so the error is logged either way.

    A path that stays the same between uploads, such as `"logos/\#{item.id}.png"`, needs `if_exists: :overwrite`, or
    the second upload fails with a `Fil.AlreadyExistsError` (see [Errors](#module-errors)). `direct: true` refuses
    `:overwrite`: the browser uploads before the record is saved, so it would replace the stored file even when the save
    fails, and with UUID paths `:overwrite` changes nothing. In an array field, the save is refused when two new files,
    or a new and a kept file, get the same path.

    The extension of each path is checked against `:extensions` before the record is saved, so `evil.html` sent as
    `image/png` with `accept: ~w(.png)` is refused, and every file is written with the content type of its path, as in
    `Fil.LiveView`.

    ## Direct uploads

    With `direct: true`, the browser uploads each file straight to the disk, with an upload URL that
    `Fil.LiveView.external/2` signs, and the file never passes through the LiveView. The disk has to sign upload URLs:
    S3, or a disk with `Fil.Plugin.URL` and `Fil.Plug` in the endpoint (see
    [Direct uploads](Fil.LiveView.html#module-direct-uploads)). The browser side is Fil's uploader, passed to the
    `LiveSocket` in `assets/js/app.js` next to Backpex's hooks:

    ```javascript
    import {Hooks as BackpexHooks, backpexParams} from "backpex"
    import {uploaders} from "phoenix-colocated/fil"

    const liveSocket = new LiveSocket("/live", Socket, {
      params: backpexParams({_csrf_token: csrfToken}),
      hooks: {...colocatedHooks, ...BackpexHooks},
      uploaders
    })
    ```

    The browser uploads the files when the form is submitted, before the record is saved. If the save is refused, for an
    error in the form or at the field, the uploaded files stay on the disk without a record, and a new submit uploads
    them again under new paths. The [Phoenix guide](phoenix.md#files-nobody-consumes) shows how to clean those up.

    `direct: true` needs the `upload_error:` option of `Backpex.Fields.Upload`, which the field sets to
    `Fil.LiveView.upload_error/2`. Backpex releases without it, 0.21.0 and earlier, crash the form when a direct upload
    fails or is refused, because they have no text for those errors, so `direct: true` raises there.

    ## Deleting files

    After a save, the field deletes the files the saved record no longer has, which `Fil.Ecto.Ref.removed/2` returns:
    those removed with the remove button, and a single file replaced by a new one. When a new file of the saved record
    isn't on the disk, because its write failed, the field keeps the old files and logs an error. A failed delete is
    logged as a warning, and the file stays on the disk.

    The field compares the saved record with the record as the form loaded it. When two people edit the same record at
    once, one save can delete a file the other one keeps, unless the changeset function uses
    `Ecto.Changeset.optimistic_lock/3`. Backpex doesn't handle the `Ecto.StaleEntryError` of the second save, so its
    form crashes, which is still better than a record that points at a deleted file.

    A `nil` in an array field disappears with the next save.

    Backpex doesn't call the field when an item is deleted, so delete its files in the LiveResource's
    `c:Backpex.LiveResource.on_item_deleted/2`:

        @impl Backpex.LiveResource
        def on_item_deleted(socket, product) do
          for file <- [product.avatar | product.photos], file != nil do
            case Fil.rm(file) do
              {:ok, _file} -> :ok
              {:error, error} -> Logger.error("Could not delete a file: " <> Exception.message(error))
            end
          end

          socket
        end

    ## Errors

    An upload error keeps the record from being saved, and shows at the field with Fil's texts from
    `Fil.LiveView.upload_error/2`, as `{msgid, bindings}` for the `error_translator_function` in Backpex's config:

      * a file LiveView refused, as too large, not accepted or one too many, until it's cancelled. Backpex shows a text
        of its own next to the file too
      * a file whose path has an extension `:extensions` doesn't allow
      * in an array field, a new file whose path another new or kept file has
      * a file that isn't uploaded yet when the form is saved, which only a modified client sends

    The number of files a record keeps is the changeset's job: `Ecto.Changeset.validate_length/3` on an array field
    counts the kept and the new files, as soon as a file is picked, and blocks the save before the field writes
    anything (with `direct: true`, the browser has uploaded them already). `:max_entries` is LiveView's limit for one
    upload.

    Backpex saves the record first and writes the files after, outside the transaction, and ignores what the write
    returns. So a failed write, because the storage is down, a stable path without `if_exists: :overwrite` or a direct
    upload the browser never finished, leaves the record with a ref to a missing file. The field logs the error, keeps
    the files the save replaced, and Backpex shows its success message anyway.

    ## Not supported

    The field works in the `fields/0` of a LiveResource. It raises `ArgumentError` in `Backpex.Fields.InlineCRUD`, in a
    resource action's form, with an adapter without a `:schema`, with `index_editable`, and with `searchable: true` on
    an array field. Item actions don't set up uploads, so it doesn't work in their forms either.

    Invalid values of the options below raise `ArgumentError`. Unknown options, and invalid values of Backpex's general
    field options, raise the error Backpex raises for any field.

    ## Options

    #{NimbleOptions.docs(@schema)}
    """

    use Backpex.Field

    require Logger

    # Backpex's upload options the field sets itself: its callbacks, and the texts of upload errors.
    @built [:list_existing_files, :put_upload_change, :consume_upload, :remove_uploads, :external, :upload_error]

    # Whether `Backpex.Fields.Upload` takes `upload_error:`, a function that gives the text of an upload error. Without
    # it, Backpex crashes the form on the errors of external uploads, so `direct: true` needs it.
    @upload_error? Code.ensure_loaded?(Backpex.Fields.Upload) and
                     function_exported?(Backpex.Fields.Upload, :config_schema, 0) and
                     Keyword.has_key?(Backpex.Fields.Upload.config_schema(), :upload_error)

    # `use Backpex.Field` defines both functions in Backpex 0.20 and 0.21. The guards keep `fil` compiling if a Backpex
    # release stops doing so.
    if Module.defines?(__MODULE__, {:config_schema, 0}), do: defoverridable(config_schema: 0)
    if Module.defines?(__MODULE__, {:validate_config!, 2}), do: defoverridable(validate_config!: 2)

    # The options of the field: Backpex's upload options, without those it sets itself, and its own.
    @doc false
    def config_schema do
      Backpex.Fields.Upload.config_schema()
      |> Keyword.drop(@built)
      |> Keyword.merge(@schema)
    end

    @doc false
    def validate_config!(field, live_resource), do: __validate_config__(field, live_resource, @upload_error?)

    # Builds the field's config. `upload_error?` says whether Backpex takes `upload_error:`; the tests pass `true` to
    # test direct uploads before a Backpex release has it.
    @doc false
    def __validate_config__({name, options}, live_resource, upload_error?) do
      options =
        options
        |> Keyword.new()
        |> Keyword.put_new(:upload_key, name)

      own = validate_own!(name, options, live_resource)
      conf = conf!(name, own, live_resource)
      validated = validate_backpex!(name, options, live_resource)
      check_options!(conf, validated, live_resource, upload_error?)

      validated
      |> Keyword.put(:accept, own[:accept] || conf.extensions)
      |> Keyword.put(:max_entries, own[:max_entries] || 1)
      |> Keyword.merge(callbacks(conf, upload_error?))
      |> Keyword.put(:fil, conf)
    end

    # What the callbacks need: the schema's disk and cardinality, and the field's own options.
    defp conf!(name, own, live_resource) do
      {multiple?, disk} = field_type!(name, live_resource)

      %{
        name: name,
        disk: disk,
        multiple?: multiple?,
        upload_key: own[:upload_key],
        path: own[:path],
        extensions: own[:extensions] || accepted_extensions!(name, own, live_resource),
        if_exists: own[:if_exists],
        direct?: own[:direct]
      }
    end

    @impl Backpex.Field
    defdelegate render_value(assigns), to: Backpex.Fields.Upload

    @impl Backpex.Field
    defdelegate render_form(assigns), to: Backpex.Fields.Upload

    @impl Backpex.Field
    def assign_uploads({_name, %{fil: _conf}} = field, socket), do: Backpex.Fields.Upload.assign_uploads(field, socket)

    # Resource actions build their forms from fields Backpex never passes to `validate_config!/2`.
    def assign_uploads({name, _options}, _socket) do
      raise ArgumentError,
            "Fil.Backpex.Upload works only in the fields/0 of a LiveResource, not in the form of a resource " <>
              "action (field #{inspect(name)})"
    end

    # Puts the value `put_upload_change` built into the changeset, and the errors of the upload. Runs before the
    # changeset function on every change and save.
    @impl Backpex.Field
    def before_changeset(changeset, attrs, _metadata, _repo, {_name, %{fil: conf}}, assigns) do
      changeset
      |> put_value(attrs, conf)
      |> add_upload_errors(conf, attrs, assigns)
    end

    def before_changeset(changeset, _attrs, _metadata, _repo, _field, _assigns), do: changeset

    defp field_type!(name, live_resource) do
      schema = schema!(name, live_resource)

      case schema.__schema__(:type, name) do
        {:parameterized, {Fil.Ecto.Ref, %{disk: disk}}} ->
          {false, disk}

        {:array, {:parameterized, {Fil.Ecto.Ref, %{disk: disk}}}} ->
          {true, disk}

        type ->
          raise ArgumentError,
                "Fil.Backpex.Upload needs a Fil.Ecto.Ref or {:array, Fil.Ecto.Ref} field, but #{inspect(name)} in " <>
                  "#{inspect(schema)} has the type #{inspect(type)}"
      end
    end

    # InlineCRUD passes the name of its own field instead of the LiveResource.
    defp schema!(name, live_resource) do
      if not (is_atom(live_resource) and Code.ensure_loaded?(live_resource) and
                function_exported?(live_resource, :adapter_config, 1)) do
        raise ArgumentError,
              "Fil.Backpex.Upload works only in the fields/0 of a LiveResource, not in Backpex.Fields.InlineCRUD " <>
                "(field #{inspect(name)} in #{inspect(live_resource)})"
      end

      live_resource.adapter_config(:schema) ||
        raise ArgumentError,
              "Fil.Backpex.Upload needs an adapter with a :schema, such as Backpex.Adapters.Ecto " <>
                "(field #{inspect(name)} in #{inspect(live_resource)})"
    end

    defp accepted_extensions!(name, validated, live_resource) do
      accept = validated[:accept] || raise_config!(name, live_resource, "needs :accept or :extensions")

      Fil.Support.Accept.extensions(accept) ||
        raise_config!(
          name,
          live_resource,
          "needs :extensions, because :accept allows no extension (#{inspect(accept)}), so any path would be stored"
        )
    end

    # The options of the field's own schema, so their errors are the field's.
    defp validate_own!(name, options, live_resource) do
      own = Keyword.take(options, Keyword.keys(@schema))

      case NimbleOptions.validate(own, @schema) do
        {:ok, own} -> own
        {:error, error} -> raise_config!(name, live_resource, "has an invalid option: " <> error.message)
      end
    end

    # All options, with Backpex's general field options, as Backpex validates the options of any field.
    defp validate_backpex!(name, options, live_resource) do
      case NimbleOptions.validate(options, Backpex.Field.default_config_schema() ++ config_schema()) do
        {:ok, validated} ->
          validated

        {:error, error} ->
          raise """
          Configuration error for field "#{name}" in "#{live_resource}".

          #{error.message}
          """
      end
    end

    defp check_options!(conf, validated, live_resource, upload_error?) do
      error =
        max_entries_error(conf.multiple?, validated[:max_entries]) || option_error(conf, validated) ||
          direct_error(conf, upload_error?)

      if error, do: raise_config!(conf.name, live_resource, error)
    end

    defp max_entries_error(true, nil), do: "needs :max_entries, because it's an {:array, Fil.Ecto.Ref} field"

    defp max_entries_error(false, max_entries) when max_entries not in [nil, 1],
      do: "holds one file (a Fil.Ecto.Ref field), so :max_entries can only be 1"

    defp max_entries_error(_multiple?, _max_entries), do: nil

    defp option_error(conf, validated) do
      cond do
        conf.extensions == [] -> "needs at least one extension"
        conf.multiple? and validated[:searchable] -> "can't be searchable, because it's an {:array, Fil.Ecto.Ref} field"
        validated[:index_editable] -> "can't be index_editable"
        true -> nil
      end
    end

    defp direct_error(%{direct?: false}, _upload_error?), do: nil

    defp direct_error(%{if_exists: :overwrite}, _upload_error?) do
      "can't use direct: true with if_exists: :overwrite, because the browser would replace the stored file before " <>
        "the record is saved"
    end

    defp direct_error(_conf, false) do
      "can't use direct: true, because this Backpex version has no upload_error: option in Backpex.Fields.Upload, " <>
        "and crashes the form on errors of direct uploads"
    end

    defp direct_error(_conf, true), do: nil

    defp raise_config!(name, live_resource, message) do
      raise ArgumentError, "Fil.Backpex.Upload field #{inspect(name)} in #{inspect(live_resource)} #{message}"
    end

    defp callbacks(conf, upload_error?) do
      # Backpex passes `external:` to `allow_upload/3` only when the key is there.
      external = if conf.direct?, do: [external: &external(conf, &1, &2)], else: []
      texts = if upload_error?, do: [upload_error: &Fil.LiveView.upload_error/2], else: []

      upload_callbacks(conf) ++ external ++ texts
    end

    defp upload_callbacks(conf) do
      [
        list_existing_files: &existing_paths(&1, conf),
        put_upload_change: &put_upload_change(conf, &1, &2, &3, &4, &5, &6),
        consume_upload: &consume_upload(conf, &1, &2, &3, &4),
        remove_uploads: &remove_uploads(conf, &1, &2, &3)
      ]
    end

    defp existing_paths(item, conf) do
      item
      |> refs(conf.name)
      |> Enum.map(& &1.path)
    end

    # The value for the changeset: the kept refs and those of the new entries. LiveView's `uploaded_entries/2`, which
    # Backpex passes as the 5th argument, returns each list reversed, so the entries come from the upload instead, in
    # the order of the file input: valid ones, and only done ones on save. A new file replaces a single one.
    # On save, an entry that isn't done can only come from a modified client, because LiveView's client uploads every
    # file before it submits. Its file can't be consumed, so the marker makes `before_changeset/6` refuse the save.
    defp put_upload_change(conf, socket, params, item, _uploaded, removed_paths, action) do
      entries =
        socket.assigns
        |> upload_entries(conf)
        |> Enum.filter(& &1.valid?)

      {done, in_progress} = Enum.split_with(entries, &(action == :validate or &1.done?))
      new = Enum.map(done, &entry_ref(conf, &1, socket.assigns))

      kept =
        item
        |> refs(conf.name)
        |> Enum.reject(&(&1.path in removed_paths))

      value = if conf.multiple?, do: kept ++ new, else: List.last(new) || List.first(kept)
      params = Map.put(params, Atom.to_string(conf.name), value)

      if in_progress == [], do: params, else: Map.put(params, in_progress_key(conf), "true")
    end

    defp in_progress_key(conf), do: "_fil_in_progress_#{conf.name}"

    defp consume_upload(conf, socket, item, meta, entry) do
      upload = socket.assigns.uploads[conf.upload_key]

      opts = [
        path: path_fun(conf.path, socket.assigns),
        if_exists: conf.if_exists,
        extensions: conf.extensions,
        max_file_size: upload.max_file_size
      ]

      case Fil.LiveView.store_entry(conf.disk, meta, entry, opts) do
        {:ok, stored} ->
          check_saved(conf, stored, item)
          {:ok, stored}

        {:error, error} ->
          Logger.error(log_prefix(conf) <> "could not store an upload: " <> Exception.message(error))
          {:postpone, error}
      end
    end

    defp check_saved(conf, stored, item) do
      if stored.path not in existing_paths(item, conf) do
        Logger.error(
          log_prefix(conf) <>
            "stored #{inspect(stored.path)}, which the saved record doesn't have. The :path function has to " <>
            "return the same path each time"
        )
      end
    end

    # `removed_paths` are the paths of the remove buttons, but a new file also replaces a single one, so the field
    # compares the record the form loaded with the saved one. If a new file isn't on the disk, its write failed, and
    # the files it replaced are kept.
    defp remove_uploads(conf, socket, item, _removed_paths) do
      loaded = socket.assigns.item
      saved = Map.get(item, conf.name)

      removed =
        loaded
        |> Ecto.Changeset.change(%{conf.name => saved})
        |> Fil.Ecto.Ref.removed(conf.name)

      if removed != [] do
        case missing_files(conf, loaded, item) do
          [] ->
            Enum.each(removed, &rm(conf, &1))

          missing ->
            removed_paths = Enum.map(removed, & &1.path)
            missing_paths = Enum.map(missing, & &1.path)

            Logger.error(
              log_prefix(conf) <>
                "kept #{inspect(removed_paths)}, because the saved record has files that aren't on the disk: " <>
                inspect(missing_paths)
            )
        end
      end

      :ok
    end

    # The new files of the saved record that aren't on the disk.
    defp missing_files(conf, loaded, saved) do
      loaded_paths = existing_paths(loaded, conf)

      saved
      |> refs(conf.name)
      |> Enum.reject(&(&1.path in loaded_paths or Fil.exists?(&1)))
    end

    defp rm(conf, file) do
      case Fil.rm(file) do
        {:ok, _file} -> :ok
        {:error, error} -> Logger.warning(log_prefix(conf) <> "could not delete a file: " <> Exception.message(error))
      end
    end

    defp external(conf, entry, socket) do
      opts = [path: path_fun(conf.path, socket.assigns), if_exists: conf.if_exists, extensions: conf.extensions]
      external = Fil.LiveView.external(conf.disk, opts)
      external.(entry, socket)
    end

    defp put_value(changeset, attrs, conf) do
      with {:ok, value} <- Map.fetch(attrs, Atom.to_string(conf.name)),
           true <- value?(value, conf.multiple?) do
        Ecto.Changeset.put_change(changeset, conf.name, value)
      else
        _other -> changeset
      end
    end

    defp value?(nil, false), do: true
    defp value?(%Fil.Ref{}, false), do: true
    defp value?(value, true) when is_list(value), do: Enum.all?(value, &match?(%Fil.Ref{}, &1))
    defp value?(_value, _multiple?), do: false

    # The errors LiveView gave the upload and its entries, an entry that isn't done on save, the extension check of
    # each valid entry's path, and paths that repeat. They keep the record from being saved until the entry is
    # cancelled.
    defp add_upload_errors(changeset, conf, attrs, assigns) do
      case assigns[:uploads][conf.upload_key] do
        nil ->
          changeset

        upload ->
          errors =
            refused_errors(upload) ++
              in_progress_errors(upload, conf, attrs) ++
              extension_errors(upload, conf, assigns) ++ path_errors(upload, conf, assigns)

          errors
          |> Enum.uniq()
          |> Enum.reduce(changeset, fn {message, keys}, changeset ->
            Ecto.Changeset.add_error(changeset, conf.name, message, keys)
          end)
      end
    end

    defp refused_errors(upload) do
      refused =
        for {_ref, error} <- upload.errors do
          upload_error(error, upload, :upload)
        end

      # An invalid entry without an error of its own, which LiveView doesn't leave, but it must not be saved either.
      if refused == [] and Enum.any?(upload.entries, &(not &1.valid?)),
        do: [upload_error(:invalid, upload, :upload)],
        else: refused
    end

    defp in_progress_errors(upload, conf, attrs) do
      if Map.has_key?(attrs, in_progress_key(conf)), do: [upload_error(:in_progress, upload, :upload)], else: []
    end

    # A path of the field's own can give two new files, or a new and a kept file, the same path in an array field.
    defp path_errors(upload, %{multiple?: true} = conf, assigns) do
      removed = Keyword.get(assigns[:removed_uploads] || [], conf.upload_key, [])

      kept =
        assigns.item
        |> existing_paths(conf)
        |> Enum.reject(&(&1 in removed))

      new =
        for entry <- upload.entries, entry.valid? do
          entry_ref(conf, entry, assigns).path
        end

      if Enum.uniq(new) != new or Enum.any?(new, &(&1 in kept)),
        do: [upload_error(%Fil.AlreadyExistsError{}, upload, :unique_path)],
        else: []
    end

    defp path_errors(_upload, _conf, _assigns), do: []

    defp upload_error(error, upload, validation) do
      {message, bindings} = Fil.LiveView.upload_error(error, upload)
      {message, Keyword.put(bindings, :validation, validation)}
    end

    defp extension_errors(upload, conf, assigns) do
      for entry <- upload.entries,
          entry.valid?,
          {:error, error} <- [check_extension(conf, entry, assigns)] do
        upload_error(error, upload, :extension)
      end
    end

    defp check_extension(conf, entry, assigns) do
      conf
      |> entry_ref(entry, assigns)
      |> Fil.Support.Accept.check(conf.extensions, :write)
    end

    defp upload_entries(assigns, conf) do
      case assigns[:uploads][conf.upload_key] do
        nil -> []
        upload -> upload.entries
      end
    end

    defp entry_ref(conf, entry, assigns) do
      Fil.LiveView.entry_ref(conf.disk, entry, path: path_fun(conf.path, assigns))
    end

    defp path_fun(path, _assigns) when is_function(path, 1), do: path
    defp path_fun(path, assigns) when is_function(path, 2), do: &path.(&1, assigns)

    defp refs(item, name) do
      item
      |> Map.get(name)
      |> List.wrap()
      |> Enum.filter(&match?(%Fil.Ref{}, &1))
    end

    defp log_prefix(conf), do: "Fil.Backpex.Upload, field #{inspect(conf.name)}: "
  end
end
