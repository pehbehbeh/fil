if Code.ensure_loaded?(Kino.JS.Live) do
  defmodule Fil.Kino.Browser do
    @moduledoc false

    # The server of `Fil.Kino.browser/3`. The client lists, previews and downloads through events, and the server only
    # reads files that are in the current listing, so the widget isn't a generic read API for the page.

    use Kino.JS, assets_path: "lib/fil/kino/assets/browser"
    use Kino.JS.Live

    # A listing shows this many entries, and says how many more there are.
    @max_entries 1000

    @image_types ~w(image/png image/jpeg image/gif image/webp)
    @text_types ~w(application/json application/xml)

    @impl Kino.JS.Live
    def init({disk, path, opts, caller}, ctx) do
      # The widget runs in a process Kino starts, not in the cell's evaluator. With the evaluator in `$callers`, a
      # memory disk finds the evaluator's store, the same way a `Task` does.
      Process.put(:"$callers", [caller])

      {:ok,
       assign(ctx,
         disk: disk,
         path: path,
         entries: [],
         listed: %{},
         more: 0,
         max_preview_size: opts[:max_preview_size],
         max_download_size: opts[:max_download_size]
       )}
    end

    # Lists on every connect (each tab or reload), so building the widget does no I/O and an error shows up in it.
    @impl Kino.JS.Live
    def handle_connect(ctx) do
      case list(ctx, ctx.assigns.path) do
        {:ok, ctx} -> {:ok, listing(ctx, nil), ctx}
        {:error, error} -> {:ok, listing(ctx, message(error)), ctx}
      end
    end

    @impl Kino.JS.Live
    def handle_event("open", %{"path" => path}, ctx) when is_binary(path), do: {:noreply, open(ctx, path)}
    def handle_event("refresh", _payload, ctx), do: {:noreply, open(ctx, ctx.assigns.path)}

    def handle_event("preview", %{"path" => path}, ctx) when is_binary(path) do
      with {:ok, file} <- listed_file(ctx, path),
           :ok <- check_size(file, ctx.assigns.max_preview_size, "too large to preview"),
           {:ok, content} <- safely(fn -> Fil.read(file) end) do
        send_preview(ctx, file, content)
      else
        {:error, error} -> send_error(ctx, error)
      end

      {:noreply, ctx}
    end

    def handle_event("download", %{"path" => path}, ctx) when is_binary(path) do
      with {:ok, file} <- listed_file(ctx, path),
           :ok <- check_size(file, ctx.assigns.max_download_size, "too large to download here"),
           {:ok, content} <- safely(fn -> Fil.read(file) end) do
        send_event(ctx, ctx.origin, "download", {:binary, %{name: Path.basename(file.path)}, content})
      else
        {:error, error} -> send_error(ctx, error)
      end

      {:noreply, ctx}
    end

    # Anything else comes from a client that doesn't match this server, so it's ignored instead of crashing.
    def handle_event(_event, _payload, ctx), do: {:noreply, ctx}

    # Lists `path` and sends the listing to every client, so they all show the same directory. An error goes to the
    # client that asked, and the listing stays as it was.
    defp open(ctx, path) do
      case list(ctx, path) do
        {:ok, ctx} ->
          broadcast_event(ctx, "listing", listing(ctx, nil))
          ctx

        {:error, error} ->
          send_error(ctx, error)
          ctx
      end
    end

    defp list(ctx, path) do
      dir = Fil.ref(ctx.assigns.disk, path)

      with {:ok, refs} <- safely(fn -> Fil.ls(dir) end) do
        {entries, rest} =
          refs
          |> Enum.sort_by(&{&1.stat.type != :directory, Path.basename(&1.path)})
          |> Enum.split(@max_entries)

        listed = Map.new(entries, &{&1.path, &1})

        {:ok, assign(ctx, path: dir.path, entries: entries, listed: listed, more: length(rest))}
      end
    end

    defp listing(ctx, error) do
      %{
        label: Fil.Disk.label(ctx.assigns.disk),
        path: ctx.assigns.path,
        entries: Enum.map(ctx.assigns.entries, &entry(&1, ctx.assigns)),
        more: ctx.assigns.more,
        error: error
      }
    end

    defp entry(%Fil.Ref{path: path, stat: stat}, assigns) do
      file? = stat.type == :regular

      %{
        name: Path.basename(path),
        path: path,
        type: if(file?, do: "file", else: "directory"),
        size: stat.size,
        mtime: stat.mtime && DateTime.to_iso8601(stat.mtime),
        content_type: if(file?, do: stat.content_type || MIME.from_path(path)),
        previewable: file? and fits?(stat.size, assigns.max_preview_size),
        downloadable: file? and fits?(stat.size, assigns.max_download_size)
      }
    end

    defp fits?(size, max), do: is_integer(size) and size <= max

    # Only files of the current listing can be read, and only by the path the listing has.
    defp listed_file(ctx, path) do
      case ctx.assigns.listed do
        %{^path => %Fil.Ref{stat: %{type: :regular}} = file} -> {:ok, file}
        %{^path => _directory} -> {:error, "#{path} is a directory"}
        _other -> {:error, "#{path} is not in the current listing, refresh and try again"}
      end
    end

    # The size from the listing decides, so a file that's too large is never read. A file the listing has no size for
    # isn't read either.
    defp check_size(%{stat: %{size: nil}} = file, _max, _message), do: {:error, "the size of #{file.path} is unknown"}

    defp check_size(file, max, message) do
      if fits?(file.stat.size, max), do: :ok, else: {:error, "#{file.path} is #{message}"}
    end

    defp send_preview(ctx, file, content) do
      type = file.stat.content_type || MIME.from_path(file.path)

      cond do
        type in @image_types ->
          send_event(ctx, ctx.origin, "preview_image", {:binary, %{path: file.path, type: type}, content})

        text?(type, content) ->
          send_event(ctx, ctx.origin, "preview", %{path: file.path, kind: "text", text: content})

        true ->
          send_event(ctx, ctx.origin, "preview", %{path: file.path, kind: "none"})
      end
    end

    # Text goes to the client as a JSON string, so it has to be valid UTF-8 whatever its type says. SVG is shown as
    # text too, because rendering it would run what's in it.
    defp text?(type, content) do
      String.valid?(content) and (text_type?(type) or not String.contains?(content, <<0>>))
    end

    defp text_type?("text/" <> _subtype), do: true
    defp text_type?(type), do: type in @text_types

    defp send_error(ctx, error), do: send_event(ctx, ctx.origin, "error", %{message: message(error)})

    defp message(message) when is_binary(message), do: message
    defp message(error), do: Exception.message(error)

    # Storage errors come back as `{:error, exception}`. Anything that raises, such as a memory disk in a process
    # without a store, is shown in the widget too, instead of crashing it.
    defp safely(fun) do
      fun.()
    rescue
      exception -> {:error, exception}
    end
  end
end
