defmodule Fil.Plugin.Validation do
  @schema NimbleOptions.new!(
            max_size: [
              type: :pos_integer,
              doc: "The largest content in bytes. Larger content fails with `reason: {:too_large, max_size}`."
            ],
            min_size: [
              type: :non_neg_integer,
              doc: """
              The smallest content in bytes, `1` to refuse empty files. Smaller content fails with
              `reason: {:too_small, min_size}`.
              """
            ],
            content_types: [
              type: {:list, {:custom, __MODULE__, :validate_content_type, []}},
              doc: """
              The content types the disk takes, such as `"image/png"`, or `"image/*"` for every image type. They're
              checked against the content itself, see [Content types](#module-content-types).
              """
            ],
            extensions: [
              type: {:list, :string},
              doc: """
              The extensions the disk takes, such as `"png"`, with or without the dot, in any case. A path with another
              extension, or none, fails with `reason: {:extension, extension}` (`""` for none).
              """
            ],
            check: [
              type: {:or, [{:fun, 1}, :mfa]},
              doc: """
              A check of your own: a function, or `{module, function, args}` called with the op first. It gets the op
              before the content is read and returns `:ok`, or `{:error, reason}` to refuse it with that reason.
              """
            ],
            presigned_uploads: [
              type: {:in, [:refuse, :check_declared]},
              default: :refuse,
              doc: """
              What to do with an upload URL the storage signs itself, such as a presigned PUT on S3, whose upload never
              reaches this plugin. See [Upload URLs](#module-upload-urls).
              """
            ]
          )

  @moduledoc """
  Refuses writes that break the disk's rules: too large or too small, of a type the disk doesn't take, with the wrong
  extension, or anything a check of your own refuses.

      avatars =
        Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage/avatars")
        |> Fil.Plugin.Validation.attach(max_size: 2_000_000, content_types: ["image/png", "image/jpeg", "image/webp"])

      Fil.write(avatars, "1.png", File.stream!("cat.gif", 65_536))
      #=> {:error, %Fil.InvalidContentError{reason: {:content_type, "image/gif"}}}

  A refused write returns `Fil.InvalidContentError` with a `:reason` that says which rule it broke, and writes nothing,
  on every adapter. What can be checked before the content is read (a `size:` the caller declared, the extension, the
  `content_type:`, your `check:`) is checked first, and the adapter never runs. The content itself is checked while
  the adapter reads it, with the size of one chunk plus 1445 bytes in memory, and a stream of known size keeps its size,
  so S3 still sends it in one request. A stream that turns out too large fails before the chunk that crosses the limit
  is passed on. `Fil.Plug` answers a refused upload with a `413` for `{:too_large, _}`, a `415` for a content type or
  an extension, and a `422` for anything else.

  Writes are checked whole or streamed, including the write half of a copy across disks. A copy or a move within the
  disk has no content to check, but its destination has to have an allowed extension (and one whose content type is
  allowed), because local disks serve files with the type of their extension. Reads aren't checked.

      iex> disk =
      ...>   Fil.disk(adapter: Fil.Adapter.Memory)
      ...>   |> Fil.Plugin.Validation.attach(max_size: 10, extensions: ["txt"])
      iex> {:error, error} = Fil.write(disk, "notes.txt", "more than ten bytes")
      iex> error.reason
      {:too_large, 10}
      iex> {:error, %Fil.InvalidContentError{reason: {:extension, "md"}}} = Fil.write(disk, "notes.md", "short")
      iex> Fil.write(disk, "notes.txt", "short")
      {:ok, Fil.ref(disk, "notes.txt")}

  ## Content types

  With `content_types:`, the type comes from the content's first bytes, its magic bytes, and has to be allowed. Images,
  PDF, ZIP and the formats built on it (Office documents, EPUB), audio, video, archives and executables have a
  signature. So do HTML, SVG and XML, so they can't pass as plain text. A type that's declared too has to match the
  content:

    * the call's `content_type:` (the request's `content-type` on an upload through `Fil.Plug`) has to be allowed, and
      the content has to be of that type. A GIF declared as `image/png` fails with
      `{:content_type_mismatch, "image/png", "image/gif"}`. `application/octet-stream` counts as no type
    * the extension's type, when [MIME](https://hex.pm/packages/mime) knows it, has to be allowed. So `x.html` fails
      even if its content is a PNG
    * content without a signature, such as CSV, JSON or plain text, is checked by its declared type, or else by its
      extension's type. That type has to be allowed and has to be one without a signature: a file declared as
      `image/png` without the PNG signature fails with `{:content_type_mismatch, "image/png", nil}`. Without a type
      it fails with `{:content_type, nil}`

  Office documents are ZIP files inside, and an `.xlsx` is checked as `application/zip` with the type it declares. So
  `content_types: ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"]` takes Excel files but no other
  ZIP. A file whose content doesn't match its extension, such as a PNG renamed to `.jpg`, fails when its declared type
  comes from the extension, as it does in browsers.

  ## Upload URLs

  An upload through `Fil.Plug` (a disk with `Fil.Plugin.URL` and a `:secret`) is an ordinary write, and is checked
  like any other. A presigned PUT on S3 goes to the storage directly, so this plugin never sees its content. It checks
  what it can when the URL is signed with `Fil.signed_url/3` and `method: :put`: `check:`, the extension, and the
  signed `size:` and `content_type:`, which S3 enforces (see [Uploads](Fil.html#signed_url/1-uploads)). What it can't
  check depends on `:presigned_uploads`:

    * `:refuse` (the default) refuses to sign the URL with a `Fil.UnsupportedError` when `content_types:` is set,
      because nobody checks the magic bytes, with `reason: {:unchecked, :content_types}`. So does a URL without `size:`
      when `max_size:` or `min_size:` is set (`{:unchecked, :max_size}`)
    * `:check_declared` takes the signed `content_type:` as the upload's type, without the magic bytes, and still
      refuses a URL without `content_type:` or `size:` when a rule needs it

  Uploads through `Fil.LiveView.external/2` sign their URLs with `Fil.signed_url/3`, so the same applies to them. On a
  disk that `Fil.Plug` serves, the URL is checked when it's signed only if this plugin is attached before
  `Fil.Plugin.URL`, which answers `Fil.signed_url/3` without the plugins after it. The upload is checked either way.

  ## Content checks of your own

  `check:` sees the op, not the content. A check of the content is a plugin of its own on `Fil.Op.scan_content/4`,
  which raises `Fil.InvalidContentError` (see [Inspecting content](plugins.md#inspecting-content)). Attach this
  plugin before plugins that change the content, such as compression, so it checks what the caller wrote.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  alias Fil.Op
  alias Fil.Support.Magic

  @doc """
  Attaches the plugin to `disk` under the name `Fil.Plugin.Validation`.

  The same as `plugins: [{Fil.Plugin.Validation, :call, opts}]` in `Fil.disk/1`, except that the options are validated
  here instead of on the first write.
  """
  @spec attach(Fil.Disk.t(), keyword()) :: Fil.Disk.t()
  def attach(%Fil.Disk{} = disk, opts \\ []) do
    Fil.attach(disk, __MODULE__, {__MODULE__, :call}, NimbleOptions.validate!(opts, @schema))
  end

  @doc false
  @spec call(Op.t(), (Op.t() -> Op.t()), keyword()) :: Op.t()
  def call(%Op{name: name} = op, next, opts) when name in [:write, :cp, :rename, :signed_url] do
    opts = NimbleOptions.validate!(opts, @schema)

    if name == :signed_url and Op.get_option(op, :method) != :put do
      next.(op)
    else
      validate(op, next, opts)
    end
  end

  def call(op, next, _opts), do: next.(op)

  @doc false
  # The content types of `content_types:`: `type/subtype` or `type/*`, normalized.
  @spec validate_content_type(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_content_type(type) when is_binary(type) do
    if type =~ ~r"^[\w.+-]+/([\w.+-]+|\*)$" do
      {:ok, Magic.normalize(type)}
    else
      {:error, "expected a content type such as \"image/png\" or \"image/*\", got: #{inspect(type)}"}
    end
  end

  def validate_content_type(other), do: {:error, "expected a content type as a string, got: #{inspect(other)}"}

  defp validate(op, next, opts) do
    case check_before(op, opts) do
      :ok ->
        op
        |> scan(opts)
        |> next.()

      {:error, %{__exception__: true} = error} ->
        Op.put_result(op, {:error, error})

      {:error, reason} ->
        Op.put_result(op, {:error, %Fil.InvalidContentError{reason: reason}})
    end
  end

  ## ------------------------------------------------------------------
  ## Before the content
  ## ------------------------------------------------------------------

  defp check_before(%Op{name: name} = op, opts) when name in [:cp, :rename] do
    with :ok <- run_check(op, opts[:check]),
         :ok <- check_extension(op.dest, opts[:extensions]) do
      check_types(nil, extension_type(op.dest), opts[:content_types])
    end
  end

  defp check_before(%Op{} = op, opts) do
    size = declared_size(op)
    declared = declared_type(op)

    with :ok <- run_check(op, opts[:check]),
         :ok <- check_extension(op.path, opts[:extensions]),
         :ok <- check_size(size, opts),
         :ok <- check_types(declared, extension_type(op.path), opts[:content_types]) do
      check_presigned(op, size, declared, opts)
    end
  end

  defp run_check(_op, nil), do: :ok
  defp run_check(op, {module, function, args}), do: check_result(apply(module, function, [op | args]))
  defp run_check(op, fun), do: check_result(fun.(op))

  defp check_result(:ok), do: :ok
  defp check_result({:error, reason}), do: {:error, reason}

  defp check_result(other) do
    raise ArgumentError,
          "the check: of Fil.Plugin.Validation must return :ok or {:error, reason}, got: #{inspect(other)}"
  end

  defp check_extension(_path, nil), do: :ok

  defp check_extension(path, extensions) do
    extension = extension(path)

    allowed = Enum.map(extensions, &normalize_extension/1)

    if extension in allowed, do: :ok, else: {:error, {:extension, extension}}
  end

  defp check_size(size, opts) do
    cond do
      is_nil(size) -> :ok
      opts[:max_size] && size > opts[:max_size] -> {:error, {:too_large, opts[:max_size]}}
      opts[:min_size] && size < opts[:min_size] -> {:error, {:too_small, opts[:min_size]}}
      true -> :ok
    end
  end

  defp check_types(_declared, _extension_type, nil), do: :ok

  defp check_types(declared, extension_type, allowed) do
    cond do
      declared && not allowed?(declared, allowed) -> {:error, {:content_type, declared}}
      extension_type && not allowed?(extension_type, allowed) -> {:error, {:content_type, extension_type}}
      true -> :ok
    end
  end

  # An upload URL that `Fil.Plug` serves is checked when the upload is written. Any other is signed by the storage,
  # and its content never comes through here: what the signature can't enforce is refused, or for `:check_declared`,
  # the content type is taken from the signature.
  defp check_presigned(%Op{name: :signed_url} = op, size, declared, opts) do
    if Fil.Plugin.URL.secret(op.disk) == nil do
      opts
      |> unchecked_rule(size, declared)
      |> unchecked()
    else
      :ok
    end
  end

  defp check_presigned(_op, _size, _declared, _opts), do: :ok

  defp unchecked_rule(opts, size, declared) do
    cond do
      opts[:content_types] && (opts[:presigned_uploads] == :refuse or is_nil(declared)) -> :content_types
      opts[:max_size] && is_nil(size) -> :max_size
      opts[:min_size] && is_nil(size) -> :min_size
      true -> nil
    end
  end

  defp unchecked(nil), do: :ok
  defp unchecked(rule), do: {:error, %Fil.UnsupportedError{reason: {:unchecked, rule}}}

  ## ------------------------------------------------------------------
  ## While the content is read
  ## ------------------------------------------------------------------

  # Counts the bytes, and keeps the first ones until there are enough to detect the type, then checks it. The state is
  # the count and the bytes kept, or `:checked` once the type is checked (or doesn't need to be).
  defp scan(%Op{name: :write} = op, opts) do
    if opts[:max_size] || opts[:min_size] || opts[:content_types] do
      types = {declared_type(op), extension_type(op.path), opts[:content_types]}
      sniff = if opts[:content_types], do: <<>>, else: :checked

      Op.scan_content(
        op,
        {0, sniff},
        &scan_chunk(&1, &2, opts[:max_size], types),
        &scan_end(&1, opts[:min_size], types)
      )
    else
      op
    end
  end

  defp scan(op, _opts), do: op

  defp scan_chunk(chunk, {count, sniff}, max_size, types) do
    count = count + byte_size(chunk)
    if max_size && count > max_size, do: reject({:too_large, max_size})
    {count, sniff(sniff, chunk, types)}
  end

  defp scan_end({count, sniff}, min_size, types) do
    if min_size && count < min_size, do: reject({:too_small, min_size})
    if sniff != :checked, do: check_content_type(sniff, types)
  end

  defp sniff(:checked, _chunk, _types), do: :checked

  defp sniff(prefix, chunk, types) do
    window = Magic.window()
    prefix = prefix <> binary_part(chunk, 0, min(byte_size(chunk), window - byte_size(prefix)))

    if byte_size(prefix) < window do
      prefix
    else
      check_content_type(prefix, types)
      :checked
    end
  end

  defp check_content_type(prefix, {declared, extension_type, allowed}) do
    case content_type_error(Magic.detect(prefix), declared, extension_type, allowed) do
      :ok -> :ok
      {:error, reason} -> reject(reason)
    end
  end

  # Content with a signature has the detected type. A declared type has to match it, and the type that's checked is
  # the more specific of the two (an Office document is a ZIP). Content without one has the declared type, or else
  # the extension's, which must be a type that has no signature.
  defp content_type_error(nil, declared, extension_type, allowed) do
    type = declared || extension_type

    cond do
      is_nil(type) -> {:error, {:content_type, nil}}
      Magic.signature?(type) -> {:error, {:content_type_mismatch, type, nil}}
      allowed?(type, allowed) -> :ok
      true -> {:error, {:content_type, type}}
    end
  end

  defp content_type_error(detected, declared, extension_type, allowed) do
    claimed = Enum.find([declared, extension_type], &(&1 && Magic.matches?(&1, detected)))

    cond do
      declared && claimed != declared -> {:error, {:content_type_mismatch, declared, detected}}
      allowed?(detected, allowed) or (claimed && allowed?(claimed, allowed)) -> :ok
      true -> {:error, {:content_type, detected}}
    end
  end

  defp reject(reason), do: raise(%Fil.InvalidContentError{reason: reason})

  ## ------------------------------------------------------------------
  ## Helpers
  ## ------------------------------------------------------------------

  defp allowed?(type, allowed) do
    Enum.any?(allowed, fn
      "*/*" ->
        true

      pattern ->
        case String.split(pattern, "/") do
          [major, "*"] -> String.starts_with?(type, major <> "/")
          _type -> type == pattern
        end
    end)
  end

  # A size the call declared, or the size of content in memory.
  defp declared_size(%Op{name: :write, content: content} = op) do
    if Fil.Support.Content.iodata?(content), do: IO.iodata_length(content), else: integer_size(op)
  end

  defp declared_size(op), do: integer_size(op)

  defp integer_size(op) do
    case Op.get_option(op, :size) do
      size when is_integer(size) -> size
      _none -> nil
    end
  end

  # `application/octet-stream` is what clients send when they don't know the type.
  defp declared_type(op) do
    with type when is_binary(type) <- Op.get_option(op, :content_type) do
      case Magic.normalize(type) do
        "application/octet-stream" -> nil
        type -> type
      end
    end
  end

  defp extension_type(path) do
    extension = extension(path)

    if MIME.has_type?(extension) do
      extension
      |> MIME.type()
      |> Magic.normalize()
    end
  end

  defp extension(path) do
    path
    |> Path.extname()
    |> normalize_extension()
  end

  defp normalize_extension(extension) do
    extension
    |> String.trim_leading(".")
    |> String.downcase()
  end
end
