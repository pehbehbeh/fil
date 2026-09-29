if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Fil.LiveView.UploadField do
    @moduledoc false

    # The markup of `Fil.LiveView.upload_field/1`, which declares its attributes and slots, so remote calls get their
    # compile-time checks, and calls `render/1` here. Also the error texts of `Fil.LiveView.upload_error/2` and the
    # event handling of `Fil.LiveView.cancel_upload/2`.

    alias Phoenix.LiveView.UploadConfig
    alias Phoenix.LiveView.UploadEntry

    use Phoenix.Component

    # The default class of each part, as in the `core_components.ex` of Phoenix 1.8's generator. LiveView adds
    # `phx-drop-target-active` to the drop zone while a file is dragged over it.
    @default_classes %{
      class: "fieldset mb-2",
      label_class: "label mb-1",
      dropzone_class:
        "flex flex-col gap-2 rounded-box border-2 border-dashed border-base-300 p-4 " <>
          "[&.phx-drop-target-active]:border-primary",
      input_class: "file-input w-full",
      error_class: "file-input-error",
      hint_class: "label",
      list_class: "mt-2 flex flex-col gap-2 text-sm",
      entry_class: "flex flex-wrap items-center gap-x-3 gap-y-1",
      progress_class: "progress w-32",
      button_class: "btn btn-sm btn-ghost",
      message_class: "w-full text-sm text-error"
    }

    @doc false
    @spec default_class(atom()) :: String.t()
    def default_class(name), do: Map.fetch!(@default_classes, name)

    @doc false
    def render(assigns) do
      %{upload: upload, existing: existing} = assigns
      translate = assigns.translate || (&interpolate/1)
      messages = messages(assigns, translate)

      assigns =
        assign(assigns,
          translate: translate,
          files: files(upload, existing),
          messages: messages,
          invalid?: upload.errors != [] or messages != [],
          errors_id: "#{upload.ref}-errors",
          hint_text: hint(assigns.hint, translate),
          classes: Map.new(@default_classes, fn {name, default} -> {name, assigns[name] || default} end)
        )

      ~H"""
      <div id={@id} class={@classes.class}>
        <label
          for={@upload.ref}
          phx-drop-target={@upload.ref}
          class={@classes.dropzone_class}
        >
          <span :if={@label} class={@classes.label_class}>{@label}</span>
          <.live_file_input
            upload={@upload}
            required={@required}
            aria-describedby={@errors_id}
            aria-invalid={@invalid? && "true"}
            class={[@classes.input_class, @invalid? && @classes.error_class]}
          />
          <span :if={@hint_text} class={@classes.hint_class}>{@hint_text}</span>
        </label>
        <ul :if={@files != [] or @upload.entries != []} class={@classes.list_class}>
          <li :for={ref <- @files} class={@classes.entry_class}>
            <div class="flex min-w-0 flex-1 items-center gap-3">
              <%= if @file != [] do %>
                {render_slot(@file, ref)}
              <% else %>
                <span class="truncate">{Path.basename(ref.path)}</span>
              <% end %>
            </div>
            <button
              type="button"
              phx-click={@remove}
              phx-value-upload={@upload.name}
              phx-value-path={ref.path}
              phx-target={@target}
              aria-label={text(@translate, "Remove %{name}", name: Path.basename(ref.path))}
              class={@classes.button_class}
            >
              {text(@translate, "Remove")}
            </button>
          </li>
          <li :for={entry <- @upload.entries} class={@classes.entry_class}>
            <div class="flex min-w-0 flex-1 items-center gap-3">
              <%= if @entry != [] do %>
                {render_slot(@entry, entry)}
              <% else %>
                <.live_img_preview
                  :if={image?(entry)}
                  entry={entry}
                  width="48"
                  height="48"
                  alt=""
                  class="size-12 rounded object-cover"
                />
                <span class="truncate">{entry.client_name}</span>
                <span :if={entry.client_size} class="shrink-0 text-base-content/70">
                  {Fil.Support.Size.format(entry.client_size)}
                </span>
              <% end %>
            </div>
            <progress
              :if={entry.valid?}
              value={entry.progress}
              max="100"
              aria-label={text(@translate, "Upload progress of %{name}", name: entry.client_name)}
              class={@classes.progress_class}
            >
              {entry.progress}%
            </progress>
            <button
              type="button"
              phx-click={@cancel}
              phx-value-upload={@upload.name}
              phx-value-ref={entry.ref}
              phx-target={@target}
              aria-label={text(@translate, "Cancel upload of %{name}", name: entry.client_name)}
              class={@classes.button_class}
            >
              {text(@translate, "Cancel")}
            </button>
            <p
              :for={error <- upload_errors(@upload, entry)}
              class={@classes.message_class}
            >
              {message(error, @translate, @upload)}
            </p>
          </li>
        </ul>
        <div id={@errors_id} aria-live="polite">
          <p :for={message <- @messages} class={@classes.message_class}>{message}</p>
        </div>
      </div>
      """
    end

    # A single upload replaces the file the record has, so that file is hidden while an entry is there.
    defp files(%UploadConfig{max_entries: 1, entries: [_entry | _rest]}, _existing), do: []
    defp files(_upload, nil), do: []
    defp files(_upload, %Fil.Ref{} = ref), do: [ref]
    defp files(_upload, refs) when is_list(refs), do: refs

    defp hint(false, _translate), do: nil
    defp hint(nil, translate), do: translate.({"or drop files here", []})
    defp hint(hint, _translate), do: hint

    # The errors below the list: the upload's own (too many files), the field's, and the ones the app passes.
    defp messages(assigns, translate) do
      %{upload: upload, field: field, errors: errors} = assigns
      upload_errors = upload_errors(upload)
      field_errors = field_errors(field, upload)

      Enum.map(upload_errors ++ field_errors ++ errors, &message(&1, translate, upload))
    end

    # The file input sends no param under the field's name, so `used_input?/1` alone stays false. The errors show once
    # the form was submitted (an action other than `:validate`) or files were picked.
    defp field_errors(nil, _upload), do: []

    defp field_errors(%Phoenix.HTML.FormField{} = field, upload) do
      if upload.entries != [] or submitted?(field.form) or used_input?(field), do: field.errors, else: []
    end

    defp submitted?(%Phoenix.HTML.Form{action: action}), do: action not in [nil, :validate]

    defp message(text, _translate, _upload) when is_binary(text), do: text

    defp message(error, translate, upload) do
      error
      |> error(upload)
      |> translate.()
    end

    defp text(translate, msg, opts \\ []), do: translate.({msg, opts})

    # The browser sends the type, which is good enough to decide on a preview.
    defp image?(%UploadEntry{client_type: "image/" <> _subtype}), do: true
    defp image?(_entry), do: false

    # What Phoenix's generator writes into `translate_error/1` for apps without Gettext.
    defp interpolate({msg, opts}) do
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _match -> to_string(value) end)
      end)
    end

    @doc false
    def error({msg, opts} = error, _upload) when is_binary(msg) and is_list(opts), do: error
    def error(:too_large, upload), do: too_large(upload)

    def error(%Fil.InvalidRequestError{reason: reason}, upload) when reason in [:too_large, "EntityTooLarge"],
      do: too_large(upload)

    def error(:not_accepted, _upload), do: not_accepted()
    def error(%Fil.InvalidRequestError{reason: :extension}, _upload), do: not_accepted()
    def error({:external_metadata_failure, %{reason: :extension}}, _upload), do: not_accepted()

    def error(:too_many_files, %UploadConfig{max_entries: max}),
      do: {"You can upload at most %{count} file(s)", count: max}

    def error(:too_many_files, _upload), do: {"Too many files", []}
    def error(%Fil.AlreadyExistsError{}, _upload), do: {"A file with this name already exists", []}
    def error(:external_client_failure, _upload), do: failed()
    def error({:writer_failure, _reason}, _upload), do: failed()
    def error(%Fil.NotFoundError{}, _upload), do: failed()
    def error({:external_metadata_failure, _meta}, _upload), do: {"The upload couldn't be started", []}
    def error(_error, _upload), do: {"The file couldn't be uploaded", []}

    defp too_large(%UploadConfig{max_file_size: max}) do
      {"The file is larger than %{max}", max: Fil.Support.Size.format(max), max_file_size: max}
    end

    defp too_large(_upload), do: {"The file is too large", []}

    defp not_accepted, do: {"This type of file isn't accepted", []}

    defp failed, do: {"The upload failed", []}

    @doc false
    def cancel_upload(socket, %{"upload" => name, "ref" => ref}) when is_binary(name) and is_binary(ref) do
      uploads = socket.assigns[:uploads] || %{}

      case Enum.find(uploads, &upload?(&1, name)) do
        {key, %UploadConfig{entries: entries}} ->
          if Enum.any?(entries, &(&1.ref == ref)), do: Phoenix.LiveView.cancel_upload(socket, key, ref), else: socket

        nil ->
          socket
      end
    end

    def cancel_upload(socket, _params), do: socket

    # `uploads` also holds LiveView's map of refs to names, under `:__phoenix_refs_to_names__`.
    defp upload?({_key, %UploadConfig{name: name}}, param), do: to_string(name) == param
    defp upload?(_other, _param), do: false
  end
end
