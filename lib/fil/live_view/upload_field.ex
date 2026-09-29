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

    # The types a browser can show as an image preview.
    @image_types ~w(image/png image/jpeg image/gif image/webp image/avif image/svg+xml image/bmp)

    @doc false
    @spec default_class(atom()) :: String.t()
    def default_class(name), do: Map.fetch!(@default_classes, name)

    @doc false
    def render(assigns) do
      assigns =
        assigns
        |> assign_rows()
        |> assign_descriptions()

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
            required={@required?}
            aria-describedby={@describedby}
            aria-invalid={@invalid? && "true"}
            class={[@classes.input_class, @invalid? && @classes.error_class]}
          />
          <span :if={@hint_text} id={@hint_id} aria-hidden="true" class={@classes.hint_class}>{@hint_text}</span>
        </label>
        <ul :if={@files != [] or @entries != []} class={@classes.list_class}>
          <li :for={row <- @files} class={@classes.entry_class}>
            <div class="flex min-w-0 flex-1 items-center gap-3">
              <%= if @file != [] do %>
                {render_slot(@file, row.ref)}
              <% else %>
                <span class="truncate">{row.name}</span>
              <% end %>
            </div>
            <button
              type="button"
              phx-click={@remove}
              phx-value-upload={@upload.name}
              phx-value-path={row.ref.path}
              phx-target={@target}
              aria-label={row.remove_label}
              class={@classes.button_class}
            >
              {text(@translate, "Remove")}
            </button>
          </li>
          <li :for={row <- @entries} class={@classes.entry_class}>
            <div class="flex min-w-0 flex-1 items-center gap-3">
              <%= if @entry != [] do %>
                {render_slot(@entry, row.entry)}
              <% else %>
                <.live_img_preview
                  :if={row.preview?}
                  entry={row.entry}
                  width="48"
                  height="48"
                  alt=""
                  class="size-12 rounded object-cover"
                />
                <span class="truncate">{row.entry.client_name}</span>
                <span :if={row.size} class="shrink-0 opacity-70">{row.size}</span>
              <% end %>
            </div>
            <progress
              :if={row.entry.valid? and row.errors == []}
              value={row.entry.progress}
              max="100"
              aria-label={row.progress_label}
              class={@classes.progress_class}
            >
              {row.entry.progress}%
            </progress>
            <button
              type="button"
              phx-click={@cancel}
              phx-value-upload={@upload.name}
              phx-value-ref={row.entry.ref}
              phx-target={@target}
              aria-label={row.cancel_label}
              class={@classes.button_class}
            >
              {text(@translate, "Cancel")}
            </button>
            <p :for={{id, message} <- row.errors} id={id} role="alert" class={@classes.message_class}>{message}</p>
          </li>
        </ul>
        <div id={@errors_id} aria-live="polite">
          <p :for={message <- @messages} class={@classes.message_class}>{message}</p>
        </div>
      </div>
      """
    end

    defp assign_rows(assigns) do
      %{upload: upload, existing: existing} = assigns
      translate = assigns.translate || (&interpolate/1)
      files = files(upload, existing)

      assign(assigns,
        translate: translate,
        files: Enum.map(files, &file_row(&1, translate)),
        entries: Enum.map(upload.entries, &entry_row(&1, upload, translate)),
        required?: assigns.required and files == [],
        classes: Map.new(@default_classes, fn {name, default} -> {name, assigns[name] || default} end)
      )
    end

    # The hint and every error get ids, so the file input can point at them with `aria-describedby`. The hint is
    # hidden from the label's name, which would include it otherwise.
    defp assign_descriptions(assigns) do
      %{upload: upload, translate: translate, entries: entries} = assigns
      messages = messages(assigns, translate)
      hint_text = hint(assigns.hint, translate)
      hint_id = hint_text && "#{upload.ref}-hint"
      errors_id = "#{upload.ref}-errors"
      entry_error_ids = for entry <- entries, {id, _message} <- entry.errors, do: id

      assign(assigns,
        messages: messages,
        invalid?: upload.errors != [] or messages != [],
        errors_id: errors_id,
        hint_text: hint_text,
        hint_id: hint_id,
        describedby: describedby([hint_id, errors_id | entry_error_ids])
      )
    end

    defp describedby(ids) do
      ids
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
    end

    defp file_row(ref, translate) do
      name = Path.basename(ref.path)
      %{ref: ref, name: name, remove_label: text(translate, "Remove %{name}", name: name)}
    end

    defp entry_row(entry, upload, translate) do
      errors =
        upload
        |> upload_errors(entry)
        |> Enum.with_index(fn error, index ->
          {"#{upload.ref}-#{entry.ref}-error-#{index}", message(error, translate, upload)}
        end)

      %{
        entry: entry,
        errors: errors,
        preview?: preview?(entry),
        size: entry.client_size && Fil.Support.Size.format(entry.client_size),
        progress_label: text(translate, "Upload progress of %{name}", name: entry.client_name),
        cancel_label: text(translate, "Cancel upload of %{name}", name: entry.client_name)
      }
    end

    # A single ref is the file of a single-file field, which saving replaces, so it's hidden while a file is picked.
    defp files(%UploadConfig{entries: [_entry | _rest]}, %Fil.Ref{}), do: []
    defp files(_upload, %Fil.Ref{} = ref), do: [ref]
    defp files(_upload, nil), do: []
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

    # The browser sends the type, which is good enough to decide on a preview. An entry LiveView refused (too large,
    # not accepted) and an empty file get none.
    defp preview?(%UploadEntry{valid?: true, client_type: type, client_size: size}) when is_integer(size) and size > 0,
      do: type in @image_types

    defp preview?(_entry), do: false

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
    # A direct upload whose file is older than its URL: the file isn't this upload's.
    def error(%Fil.AlreadyExistsError{reason: :before_upload}, _upload), do: failed()
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
