defmodule Fil.Plugin.Thumbnails do
  @schema NimbleOptions.new!(
            variants: [
              type: :non_empty_keyword_list,
              required: true,
              keys: [
                *: [
                  type: :keyword_list,
                  keys: [
                    width: [type: :pos_integer, required: true, doc: "The largest width in pixels."],
                    height: [
                      type: :pos_integer,
                      doc: """
                      The largest height in pixels. Without it, only the width limits the size, and with `:crop` the
                      variant is square.
                      """
                    ],
                    crop: [
                      type: {:in, [:center, :attention]},
                      doc: """
                      Fills the width and the height exactly and cuts off the rest: `:center` keeps the middle,
                      `:attention` the part libvips finds most likely to draw attention. Without it, the whole image
                      fits into the box.
                      """
                    ],
                    format: [
                      type: {:in, [:jpg, :png, :webp]},
                      doc: """
                      Converts the variant, and appends the format's extension to its path. Without it, the variant
                      has the image's format.
                      """
                    ],
                    quality: [
                      type: {:in, 1..100},
                      doc: "The encoder quality of a JPEG or WebP variant. Without it, libvips' default (75)."
                    ]
                  ]
                ]
              ],
              doc: """
              The variants by name, such as `[small: [width: 200], square: [width: 96, crop: :attention]]`. A name
              goes into the variant's path, so it's lowercase letters, digits and underscores. Each variant takes:
              """
            ],
            variant_path: [
              type: {:or, [{:fun, 3}, :mfa]},
              default: {__MODULE__, :prefixed, ["thumbnails"]},
              doc: """
              Where the variants of an image go: a function `(path, variant, format)` that returns the path of the
              variant, or `nil` for a path that gets no variants, such as a variant's own path. `format` is the
              variant's `:format` or `nil`. A `{module, function, args}` is called with `args` after those three, for
              disks from config. The default puts them under `thumbnails/` (see `prefixed/4` and
              [Where variants go](#module-where-variants-go)).
              """
            ],
            extensions: [
              type: {:list, :string},
              default: ~w(.jpg .jpeg .png .webp),
              doc: """
              The extensions of images, lowercase with the dot. A path's extension is compared in lowercase, so
              `photo.JPG` is an image too.
              """
            ],
            mode: [
              type: {:in, [:on_write, :manual]},
              default: :on_write,
              doc: """
              `:on_write` makes the variants when an image is written. `:manual` doesn't, and your code calls
              `generate/1` instead, such as from a background job. Deletes, copies and renames follow in both modes.
              """
            ],
            max_pixels: [
              type: :pos_integer,
              default: 100_000_000,
              doc: """
              The most pixels an image may have. It's read from the image's header, before the image is decoded, so a
              small file that decodes into a huge image is refused before it takes up memory.
              """
            ]
          )

  @moduledoc """
  Writes smaller copies of images next to them, resized with [libvips](https://www.libvips.org).

      disk =
        Fil.disk(adapter: Fil.Adapter.S3, bucket: "photos")
        |> Fil.Plugin.Thumbnails.attach(variants: [small: [width: 200], square: [width: 96, crop: :attention]])

      Fil.write(disk, "cats/tom.jpg", jpeg)
      # also writes thumbnails/small/cats/tom.jpg and thumbnails/square/cats/tom.jpg

      disk |> Fil.Plugin.Thumbnails.variant("cats/tom.jpg", :small) |> Fil.url()

  It needs the optional dependency [Vix](https://hex.pm/packages/vix), which downloads a precompiled libvips when it's
  compiled:

      {:vix, "~> 0.33"}

  Unlike `Fil.Plug`, which isn't compiled without Plug, the plugin is always there and looks Vix up when it's attached
  or used. So a disk from config that lists the plugin raises with a message about Vix instead of a missing function,
  and adding Vix later needs no recompile of `fil`.

  It's also the example of a plugin that needs all of the content at once and writes files of its own (see the
  [Plugins guide](plugins.md)).

  ## Variants

  Every variant fits into its `:width` and `:height`, keeping the image's aspect ratio (or crops to exactly that size
  with `:crop`). Images are never enlarged. A variant is rotated by the image's EXIF orientation and keeps only the
  colour profile of the metadata, so no GPS position ends up in a public thumbnail. That needs libvips 8.15 or later
  (Vix 0.42 comes with 8.18). On an older libvips, which would keep all of the metadata, the plugin raises instead of
  running.

  A write of an image (by its extension, see `:extensions`) makes every variant in memory, then writes the image, then
  the variants, each as a `Fil.write/3` with its content type. The variant writes go through the disk's plugins too,
  and this one passes them on because `:variant_path` gives them no variants. So `Fil.Telemetry` counts an image
  write as one `:write` plus one per variant, nested in it (see
  [Nested operations](Fil.Telemetry.html#module-nested-operations)). With `mode: :manual`, a write makes no variants,
  and `generate/1` makes them later.

  ## Where variants go

  `:variant_path` maps the path of an image to the path of each variant. The default, `prefixed/4` with `"thumbnails"`,
  puts the variants of `cats/tom.jpg` at `thumbnails/small/cats/tom.jpg`, and a variant with `format: :webp` at
  `thumbnails/square/cats/tom.jpg.webp`. So `tom.jpg` and `tom.png` never share a variant, and the content type still
  follows from the extension. `{Fil.Plugin.Thumbnails, :prefixed, ["media/thumbs"]}` uses another directory.
  `variant/2` returns the ref of a variant. The variants are ordinary files: read them, build their URLs, and expect
  them in a recursive `Fil.ls/3`.

  A function of your own can put the variants next to the image instead. This one stores an image as
  `images/5a95_original_158.jpg` and its variants as `images/5a95_small_158.jpg`:

      defmodule MyApp.Images do
        def variant_path(path, variant, format) do
          case String.split(path, "_original_", parts: 2) do
            [id, rest] -> "\#{id}_\#{variant}_\#{rest}" <> if(format, do: ".\#{format}", else: "")
            [_not_an_original] -> nil
          end
        end
      end

      Fil.Plugin.Thumbnails.attach(disk,
        variants: [small: [width: 200]],
        variant_path: {MyApp.Images, :variant_path, []}
      )

  The function returns `nil` for a path that gets no variants, and that has to include the variants' own paths, or the
  plugin makes variants of variants. `Fil.rm_rf/1` calls it with the directory and a `nil` format: a path it returns,
  such as `thumbnails/small/cats` in the default layout, is deleted with everything under it, and `nil` deletes nothing
  more (variants next to their images go with the directory). A path outside the disk root, the root itself or the
  image's own path raises `ArgumentError`.

  ## Deletes, copies and renames

  Once an image is deleted, copied or renamed on its disk, the plugin does the same with its variants. `Fil.rm_rf/1`
  deletes the variants under the path too. Its count is what the operation itself deleted, so variants only count
  when they're in the deleted directory.

  A copy or a rename to another extension doesn't fit the variants any more: a rename deletes them, and a copy leaves
  the source's alone. Either deletes the variants the destination had, since they belong to the file it replaced. The
  same goes for a variant the source doesn't have (an image written before the plugin was attached has none).

  Across disks, `Fil` copies with a read and a write, so a disk with the plugin makes the variants of the copy itself,
  and a rename deletes the source's variants with the source.

  ## Memory and order

  libvips needs the whole image, so an image write collects its content into memory with `Fil.Op.materialize/1`: up
  to the whole file per image written at the same time, plus libvips' working memory. `Fil.Plug` limits uploads with
  `:max_body_size`. Every other write stays a stream.

  Attach the plugin first, before plugins that rewrite paths or change content (compression, encryption), so it sees
  the image as the caller wrote it. Its variant writes still go through those plugins. `Fil.Plugin.ContentType`
  before it does no harm.

  Two writes to the same path at the same time can leave the variants of one next to the image of the other.

  ## Errors

    * content libvips can't decode, or encode as a variant, is refused before anything is written, with a
      `Fil.InvalidRequestError` whose `:reason` is `{:not_an_image, message}`. The same goes for an image over
      `:max_pixels`, with `{:too_many_pixels, pixels}`
    * when the image can't be written, no variant is written either
    * when a variant can't be written, the image stays written and the write returns the variant's error, with the
      variant's path. The same goes for a variant that can't be deleted, copied or renamed

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  alias Fil.Op
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  # Vix is optional, so its modules may be missing when `fil` compiles.
  @compile {:no_warn_undefined, [Vix.Vips, Image, Operation]}

  # libvips' largest image dimension, the height of a box that only the width limits.
  @max_coordinate 10_000_000

  @crop %{center: :VIPS_INTERESTING_CENTRE, attention: :VIPS_INTERESTING_ATTENTION}

  @doc """
  Attaches the plugin to `disk` under the name `Fil.Plugin.Thumbnails`.

  The same as `plugins: [{Fil.Plugin.Thumbnails, :call, opts}]` in `Fil.disk/1`, except that the options are validated
  here instead of on the first operation.
  """
  @spec attach(Fil.Disk.t(), keyword()) :: Fil.Disk.t()
  def attach(%Fil.Disk{} = disk, opts) do
    vix!()
    Fil.attach(disk, __MODULE__, {__MODULE__, :call}, validate!(opts))
  end

  @doc """
  Returns the ref of a variant of an image. It's only a path: the variant may not exist.

      iex> disk =
      ...>   Fil.disk(adapter: Fil.Adapter.Memory)
      ...>   |> Fil.Plugin.Thumbnails.attach(variants: [small: [width: 200], square: [width: 96, format: :webp]])
      iex> Fil.Plugin.Thumbnails.variant(disk, "cats/tom.jpg", :small)
      #Fil.Ref<memory:thumbnails/small/cats/tom.jpg>
      iex> tom = Fil.ref(disk, "cats/tom.jpg")
      iex> Fil.Plugin.Thumbnails.variant(tom, :square)
      #Fil.Ref<memory:thumbnails/square/cats/tom.jpg.webp>

  Raises `ArgumentError` when the plugin isn't attached to the disk, `name` isn't one of its variants, the path escapes
  the disk root, or `:variant_path` gives the path no variant.
  """
  @spec variant(Fil.Ref.t(), atom()) :: Fil.Ref.t()
  def variant(%Fil.Ref{disk: disk, path: path}, name), do: variant(disk, path, name)

  @doc "Returns the ref of a variant of an image. See `variant/2`."
  @spec variant(Fil.Disk.t(), Path.t(), atom()) :: Fil.Ref.t()
  def variant(%Fil.Disk{} = disk, path, name) when is_binary(path) do
    opts = opts!(disk)
    names = Keyword.keys(opts[:variants])

    if name not in names do
      raise ArgumentError, "unknown variant #{inspect(name)}, expected one of #{inspect(names)}"
    end

    normalized =
      case Fil.Support.Path.normalize(path) do
        {:ok, normalized} -> normalized
        {:error, :ebadpath} -> raise ArgumentError, "the path #{inspect(path)} escapes the disk root"
      end

    case variant_path(normalized, name, opts[:variants][name][:format], opts) do
      nil -> raise ArgumentError, ":variant_path gives #{inspect(normalized)} no variant #{inspect(name)}"
      mapped -> Fil.ref(disk, mapped)
    end
  end

  @doc """
  Makes the variants of an image that's already stored, and returns their refs by variant name.

      {:ok, [small: small, square: square]} = Fil.Plugin.Thumbnails.generate(disk, "cats/tom.jpg")

  It reads the image with `Fil.read/1`, through the disk's plugins, and writes every variant, replacing what's there.
  Call it with `mode: :manual`, for images written before the plugin was attached or before a variant was added, and
  to repair the variants after a write returned a variant's error. An image uploaded to S3 with a presigned URL
  bypasses the plugins, so it gets its variants this way too.

  Returns the errors of `Fil.read/1` and those of a write of the image (see [Errors](#module-errors)). Raises
  `ArgumentError` when the plugin isn't attached to the disk, or the path gets no variants: its extension isn't in
  `:extensions`, or `:variant_path` returns `nil` for it.
  """
  @spec generate(Fil.Ref.t()) :: {:ok, keyword(Fil.Ref.t())} | {:error, Fil.error()}
  def generate(%Fil.Ref{disk: disk, path: path}), do: generate(disk, path)

  @doc "Makes the variants of an image that's already stored. See `generate/1`."
  @spec generate(Fil.Disk.t(), Path.t()) :: {:ok, keyword(Fil.Ref.t())} | {:error, Fil.error()}
  def generate(%Fil.Disk{} = disk, path) when is_binary(path) do
    opts = opts!(disk)
    ref = Fil.ref(disk, path)

    with {:ok, original} <- Fil.Ref.normalize(ref),
         variants = variants!(original, opts),
         {:ok, content} <- Fil.read(original),
         {:ok, thumbnails} <- thumbnails(content, original, variants, opts),
         :ok <- write_all(thumbnails) do
      {:ok, variants}
    end
  end

  @doc """
  Puts the variants under `prefix`, as `<prefix>/<variant>/<path>`, with the format's extension appended when the
  variant has a `:format`. It's the default `:variant_path`, with `"thumbnails"`. Paths under `prefix` get no
  variants, which keeps the plugin from making variants of variants.

      iex> Fil.Plugin.Thumbnails.prefixed("cats/tom.jpg", :small, nil, "thumbnails")
      "thumbnails/small/cats/tom.jpg"
      iex> Fil.Plugin.Thumbnails.prefixed("cats/tom.jpg", :square, :webp, "thumbnails")
      "thumbnails/square/cats/tom.jpg.webp"
      iex> Fil.Plugin.Thumbnails.prefixed("thumbnails/small/cats/tom.jpg", :small, nil, "thumbnails")
      nil

  Another directory is `variant_path: {Fil.Plugin.Thumbnails, :prefixed, ["media/thumbs"]}`.
  """
  @spec prefixed(String.t(), atom(), atom() | nil, String.t()) :: String.t() | nil
  def prefixed(path, variant, format, prefix) do
    prefix =
      case Fil.Support.Path.normalize(prefix) do
        {:ok, prefix} when prefix != "." -> prefix
        _root_or_escape -> raise ArgumentError, "expected a directory inside the disk root, got: #{inspect(prefix)}"
      end

    if outside?(path, prefix) do
      Path.join([prefix, Atom.to_string(variant), path]) <> format_extension(format)
    end
  end

  defp outside?(path, directory), do: path != directory and not String.starts_with?(path, directory <> "/")

  @doc false
  @spec call(Op.t(), (Op.t() -> Op.t()), keyword()) :: Op.t()
  def call(%Op{name: :write} = op, next, opts) do
    opts = validate!(opts)
    original = Fil.ref(op.disk, op.path)
    variants = variants(original, opts)

    if opts[:mode] == :on_write and variants != [] do
      vix!()
      op = Op.materialize(op)

      case thumbnails(op.content, original, variants, opts) do
        {:ok, thumbnails} ->
          op
          |> next.()
          |> each_variant(thumbnails, &write_variant/1)

        {:error, error} ->
          Op.put_result(op, {:error, error})
      end
    else
      next.(op)
    end
  end

  # The paths are taken before `next`, because a plugin after this one may rewrite them.
  def call(%Op{name: :rm, path: path} = op, next, opts) do
    opts = validate!(opts)
    op = next.(op)
    image = Fil.ref(op.disk, path)

    each_variant(op, variants(image, opts), &rm_variant/1)
  end

  def call(%Op{name: :rm_rf, path: path} = op, next, opts) do
    opts = validate!(opts)
    op = next.(op)
    tree = Fil.ref(op.disk, path)

    each_variant(op, variant_trees(tree, opts), &Fil.rm_rf/1)
  end

  def call(%Op{name: :cp, path: path, dest: dest} = op, next, opts) do
    opts = validate!(opts)
    op = next.(op)
    {src, dest} = {Fil.ref(op.disk, path), Fil.ref(op.disk, dest)}

    case pairs(src, dest, opts) do
      [] -> each_variant(op, variants(dest, opts), &rm_variant/1)
      pairs -> each_variant(op, pairs, &transfer(&1, :cp))
    end
  end

  def call(%Op{name: :rename, path: path, dest: dest} = op, next, opts) do
    opts = validate!(opts)
    op = next.(op)
    {src, dest} = {Fil.ref(op.disk, path), Fil.ref(op.disk, dest)}

    case pairs(src, dest, opts) do
      [] -> each_variant(op, variants(src, opts) ++ variants(dest, opts), &rm_variant/1)
      pairs -> each_variant(op, pairs, &transfer(&1, :rename))
    end
  end

  def call(op, next, _opts), do: next.(op)

  # Runs `fun` on each item once the operation succeeded, and stops at the first error, which becomes the result.
  defp each_variant(%Op{result: {:ok, _value}} = op, items, fun) do
    Enum.reduce_while(items, op, fn item, op ->
      case fun.(item) do
        {:ok, _value} -> {:cont, op}
        {:error, error} -> {:halt, Op.put_result(op, {:error, error})}
      end
    end)
  end

  defp each_variant(op, _items, _fun), do: op

  defp rm_variant({_name, variant}), do: Fil.rm(variant)

  # A variant the source doesn't have is deleted at the destination, where it would belong to the file copied over.
  defp transfer(%{from: from, to: to}, name) do
    with {:error, %Fil.NotFoundError{}} <- apply(Fil, name, [from, to]), do: Fil.rm(to)
  end

  defp write_variant({_name, variant, data}) do
    content_type = MIME.from_path(variant.path)
    Fil.write(variant, data, content_type: content_type)
  end

  defp write_all(thumbnails) do
    Enum.reduce_while(thumbnails, :ok, fn thumbnail, :ok ->
      case write_variant(thumbnail) do
        {:ok, _variant} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp extension(path) do
    path
    |> Path.extname()
    |> String.downcase()
  end

  defp format_extension(nil), do: ""
  defp format_extension(format), do: ".#{format}"

  # The variants of an image as `{name, ref}`. A path whose extension isn't in `:extensions` has none, and neither does
  # one `:variant_path` returns `nil` for, such as a variant's own path.
  defp variants(%Fil.Ref{disk: disk, path: path}, opts) do
    for {name, variant} <- opts[:variants],
        extension(path) in opts[:extensions],
        mapped when mapped != nil <- [variant_path(path, name, variant[:format], opts)],
        do: {name, Fil.ref(disk, mapped)}
  end

  defp variants!(original, opts) do
    case variants(original, opts) do
      [] ->
        raise ArgumentError,
              "#{inspect(original.path)} gets no variants: its extension isn't in :extensions, " <>
                "or :variant_path returns nil for it"

      variants ->
        variants
    end
  end

  # The variants a copy or a rename takes along, which only fit a destination with the same extension.
  defp pairs(src, dest, opts) do
    if extension(src.path) == extension(dest.path) do
      for {name, to} <- variants(dest, opts), {^name, from} <- variants(src, opts), do: %{from: from, to: to}
    else
      []
    end
  end

  # What `rm_rf` deletes: what `:variant_path` gives the path as a directory (without a format), and the variants of
  # the path when it's an image.
  defp variant_trees(%Fil.Ref{disk: disk, path: path} = ref, opts) do
    directories =
      for {name, _variant} <- opts[:variants],
          mapped when mapped != nil <- [variant_path(path, name, nil, opts)],
          do: Fil.ref(disk, mapped)

    files = for {_name, variant} <- variants(ref, opts), do: variant

    Enum.uniq(directories ++ files)
  end

  # Calls `:variant_path` and checks what it returns, so a mistake can't delete or overwrite the wrong files.
  defp variant_path(path, name, format, opts) do
    result =
      case opts[:variant_path] do
        {module, function, args} -> apply(module, function, [path, name, format | args])
        fun -> fun.(path, name, format)
      end

    normalized = if is_binary(result), do: Fil.Support.Path.normalize(result), else: result

    case normalized do
      nil ->
        nil

      {:ok, normalized} when normalized not in [path, "."] ->
        normalized

      _invalid ->
        raise ArgumentError,
              ":variant_path returned #{inspect(result)} for #{inspect(path)} and #{inspect(name)}, expected nil or " <>
                "a path inside the disk root, other than the root and the image's own path"
    end
  end

  # Makes every variant in memory before anything is written, as `{name, ref, binary}`.
  defp thumbnails(content, %Fil.Ref{} = original, variants, opts) do
    result =
      with :ok <- check_pixels(content, opts[:max_pixels]) do
        Enum.reduce_while(variants, {:ok, []}, &resize(&1, &2, content, opts))
      end

    case result do
      {:ok, thumbnails} -> {:ok, Enum.reverse(thumbnails)}
      {:error, reason} -> {:error, %Fil.InvalidRequestError{reason: reason, path: original.path, disk: original.disk}}
    end
  end

  defp resize({name, ref}, {:ok, thumbnails}, content, opts) do
    case thumbnail(content, ref.path, opts[:variants][name]) do
      {:ok, data} -> {:cont, {:ok, [{name, ref, data} | thumbnails]}}
      {:error, message} -> {:halt, not_an_image(message)}
    end
  end

  # Only reads the header, so a huge image is refused before it's decoded.
  defp check_pixels(content, max_pixels) do
    case Image.new_from_buffer(content) do
      {:ok, image} ->
        pixels = Image.width(image) * Image.height(image)
        if pixels > max_pixels, do: {:error, {:too_many_pixels, pixels}}, else: :ok

      {:error, message} ->
        not_an_image(message)
    end
  end

  # The only libvips code. `thumbnail_buffer` shrinks while it decodes and rotates by the EXIF orientation. The height
  # is always passed, because libvips' default is the width, a square box.
  defp thumbnail(content, variant_path, variant) do
    width = variant[:width]
    height = variant[:height] || if(variant[:crop], do: width, else: @max_coordinate)
    crop = if variant[:crop], do: [crop: @crop[variant[:crop]]], else: []

    extension = extension(variant_path)
    quality = if variant[:quality] && extension in ~w(.jpg .jpeg .webp), do: [Q: variant[:quality]], else: []

    with {:ok, image} <- Operation.thumbnail_buffer(content, width, [height: height, size: :VIPS_SIZE_DOWN] ++ crop) do
      Image.write_to_buffer(image, extension, [keep: [:VIPS_FOREIGN_KEEP_ICC]] ++ quality)
    end
  end

  # libvips repeats its message for every loader that tried, so only the first line is kept.
  defp not_an_image(message) do
    line =
      message
      |> String.split("\n", parts: 2)
      |> List.first()

    {:error, {:not_an_image, line}}
  end

  # The options of the plugin on `disk`, validated again, because entries from config weren't.
  defp opts!(%Fil.Disk{plugins: plugins} = disk) do
    case List.keyfind(plugins, __MODULE__, 0) do
      {__MODULE__, _callback, opts} ->
        vix!()
        validate!(opts)

      nil ->
        raise ArgumentError, "Fil.Plugin.Thumbnails isn't attached to #{inspect(disk)}"
    end
  end

  defp validate!(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    for {name, _variant} <- opts[:variants], not Regex.match?(~r/^[a-z0-9_]+$/, Atom.to_string(name)) do
      raise ArgumentError, "invalid variant name #{inspect(name)}, expected lowercase letters, digits and underscores"
    end

    opts
  end

  # libvips before 8.15 ignores `keep:`, so the variants would keep the image's EXIF data, GPS position included.
  defp vix! do
    if not Code.ensure_loaded?(Operation) do
      raise "Fil.Plugin.Thumbnails needs the optional dependency Vix: add {:vix, \"~> 0.33\"} to your deps"
    end

    version = Vix.Vips.version()

    if Version.compare(version, "8.15.0") == :lt do
      raise "Fil.Plugin.Thumbnails needs libvips 8.15 or later to strip the metadata from variants, Vix has #{version}"
    end
  end
end
