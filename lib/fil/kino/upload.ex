if Code.ensure_loaded?(Kino.JS.Live) do
  defmodule Fil.Kino.Upload do
    @moduledoc false

    # The upload field of `Fil.Kino.upload/3` and of the browser with `writable: true`: Kino's file input, a frame for
    # the status line below it, and a listener that writes each upload to the disk. Livebook keeps an upload as a file
    # in the runtime, so the write streams from that file, and nothing goes through the widget's websocket.

    @chunk_size 65_536

    @doc """
    Builds the field. `dir` is a path, or a function that returns the path at the time of the upload (the browser's
    current directory). `caller` is the process that built the field, whose memory store the writes use.
    """
    @spec new(Fil.Disk.t(), String.t() | (-> String.t()), keyword(), pid()) :: Kino.Layout.t()
    def new(disk, dir, opts, caller) do
      input = Kino.Input.file(opts[:label], accept: opts[:accept])
      frame = Kino.Frame.new(placeholder: false)

      Kino.listen(input, fn event ->
        # The listener runs in a process Kino starts, so it needs the caller in `$callers` for a memory disk. That
        # process only exists inside `Kino.listen/2`, so this function is the first place that can set it.
        Process.put(:"$callers", [caller])
        handle(event, disk, dir, frame, opts)
      end)

      Kino.Layout.grid([input, frame])
    end

    # The value is `nil` when the upload is cleared.
    defp handle(%{value: %{file_ref: file_ref, client_name: name}}, disk, dir, frame, opts) do
      result =
        with {:ok, dir} <- resolve(dir) do
          write(disk, dir, name, Kino.Input.file_path(file_ref), opts[:if_exists])
        end

      case result do
        {:ok, ref, size} ->
          Kino.Frame.render(frame, Kino.Text.new("Wrote #{ref.path} (#{Fil.Support.Size.format(size)})"))
          if on_upload = opts[:on_upload], do: on_upload.(ref)

        {:error, error} ->
          Kino.Frame.render(frame, Kino.Text.new(message(error), style: [color: "#d33"]))
      end
    end

    defp handle(_event, _disk, _dir, _frame, _opts), do: :ok

    # The browser's current directory. The browser may be busy with a download or a slow listing, so the call waits for
    # it, and a browser that's gone (its cell was evaluated again) is an error in the status line.
    defp resolve(dir) when is_function(dir, 0) do
      {:ok, dir.()}
    catch
      :exit, _reason -> {:error, "the browser is gone, so there's no directory to upload to"}
    end

    defp resolve(dir), do: {:ok, dir}

    # Writes the uploaded file at `source` to `dir`, under the name the browser sent.
    defp write(disk, dir, name, source, if_exists) do
      with :ok <- check_name(name),
           {:ok, %File.Stat{size: size}} <- source_stat(source) do
        content = File.stream!(source, @chunk_size)

        case Fil.write(disk, Path.join(dir, name), content, size: size, if_exists: if_exists) do
          {:ok, ref} -> {:ok, ref, size}
          {:error, error} -> {:error, error}
        end
      end
    rescue
      # A memory disk in a process without a store raises. The field shows it instead of crashing the listener.
      exception -> {:error, exception}
    end

    # The name comes from the browser. The disk root stops paths that climb out of it, but not `..` from a
    # subdirectory or a `/` that makes one, so the name has to be a plain file name.
    defp check_name(name) do
      if name in ["", ".", ".."] or String.contains?(name, ["/", "\\"]) do
        {:error, "invalid file name: #{inspect(name)}"}
      else
        :ok
      end
    end

    defp source_stat(source) do
      case File.stat(source) do
        {:ok, stat} -> {:ok, stat}
        {:error, reason} -> {:error, "could not read the upload: #{:file.format_error(reason)}"}
      end
    end

    defp message(message) when is_binary(message), do: message
    defp message(error), do: Exception.message(error)
  end
end
