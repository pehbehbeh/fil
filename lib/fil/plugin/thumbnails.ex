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
              is a directory in the variant's path, so it's lowercase letters, digits and underscores. Each variant
              takes:
              """
            ],
            prefix: [
              type: {:custom, __MODULE__, :normalize_prefix, []},
              default: "thumbnails",
              doc: "The directory of the variants, as `<prefix>/<variant>/<path>`. Writes under it get no variants."
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

  The plugin is compiled without it, and raises when it's attached or used and Vix isn't there. So a disk from config
  that lists the plugin gets that message instead of a missing function. `Fil.Plug` is left out when Plug is missing,
  but Vix is looked up when the plugin runs, so adding it later needs no recompile of `fil`.

  It's also the example of a plugin that needs all of the content at once and writes files of its own (see the
  [Plugins guide](plugins.md)).

  ## Variants

  A variant of `cats/tom.jpg` is at `<prefix>/<variant>/cats/tom.jpg`. With `format: :webp`, it's
  `thumbnails/square/cats/tom.jpg.webp`, so `tom.jpg` and `tom.png` never share a variant and the extension gives the
  right content type. `variant/2` returns the ref. The variants are ordinary files: read them, build their URLs, and
  expect them in a recursive `Fil.ls/3` of the root.

  Every variant fits into its `:width` and `:height`, keeping the image's aspect ratio (or crops to exactly that size
  with `:crop`). Images are never enlarged. A variant is rotated by the image's EXIF orientation and keeps only its
  colour profile of the metadata, so no GPS position ends up in a public thumbnail. That needs libvips 8.15 or later,
  which Vix's precompiled build is.

  A write of an image (by its extension, see `:extensions`) makes every variant in memory, then writes the image, then
  the variants, each as a `Fil.write/3` with its content type. With `mode: :manual`, it writes only the image, and
  `generate/1` makes the variants later. The variants are written with the disk's plugins, and
  the plugin passes on its own writes because they're under `:prefix`. So `Fil.Telemetry` counts an image write as
  one `:write` plus one per variant, nested in it (see
  [Nested operations](Fil.Telemetry.html#module-nested-operations)).

  ## Deletes, copies and renames

  Once an image is deleted, copied or renamed on its disk, the plugin does the same with its variants. `Fil.rm_rf/1`
  deletes the variants under the path too. Its count is what the operation itself deleted, so variants only count
  when the prefix is in the deleted directory.

  A copy or a rename to another extension doesn't fit the variants any more: a rename deletes them, and a copy leaves
  the source's alone. A missing variant is skipped, since an image written before the plugin was attached has none.

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

    * content libvips can't decode is refused before anything is written, with a `Fil.InvalidRequestError` whose
      `:reason` is `{:not_an_image, message}`. The same goes for an image over `:max_pixels`, with
      `{:too_many_pixels, pixels}`. A libvips that can't encode the variant also returns `:not_an_image` (a libvips
      older than 8.15, say)
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
  @compile {:no_warn_undefined, [Image, Operation]}

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

  Raises `ArgumentError` when the plugin isn't attached to the disk, `name` isn't one of its variants, or the path
  escapes the disk root.
  """
  @spec variant(Fil.Ref.t(), atom()) :: Fil.Ref.t()
  def variant(%Fil.Ref{disk: disk, path: path}, name), do: variant(disk, path, name)

  @doc "Returns the ref of a variant of an image. See `variant/2`."
  @spec variant(Fil.Disk.t(), Path.t(), atom()) :: Fil.Ref.t()
  def variant(%Fil.Disk{} = disk, path, name) when is_binary(path) and is_atom(name) do
    opts = opts!(disk)
    names = Keyword.keys(opts[:variants])

    if name not in names do
      raise ArgumentError, "unknown variant #{inspect(name)}, expected one of #{inspect(names)}"
    end

    case Fil.Support.Path.normalize(path) do
      {:ok, path} -> variant_ref(disk, path, name, opts)
      {:error, :ebadpath} -> raise ArgumentError, "the path #{inspect(path)} escapes the disk root"
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
  `ArgumentError` when the plugin isn't attached to the disk or the path isn't an image by `:extensions`.
  """
  @spec generate(Fil.Ref.t()) :: {:ok, keyword(Fil.Ref.t())} | {:error, Fil.error()}
  def generate(%Fil.Ref{disk: disk, path: path}), do: generate(disk, path)

  @doc "Makes the variants of an image that's already stored. See `generate/1`."
  @spec generate(Fil.Disk.t(), Path.t()) :: {:ok, keyword(Fil.Ref.t())} | {:error, Fil.error()}
  def generate(%Fil.Disk{} = disk, path) when is_binary(path) do
    opts = opts!(disk)
    original = Fil.ref(disk, path)

    if not image?(original.path, opts) do
      raise ArgumentError, "#{inspect(path)} isn't an image, its extension isn't in :extensions"
    end

    with {:ok, content} <- Fil.read(original),
         {:ok, thumbnails} <- thumbnails(content, original, opts),
         :ok <- write_all(thumbnails) do
      {:ok, for({name, variant, _data} <- thumbnails, do: {name, variant})}
    end
  end

  @doc false
  @spec call(Op.t(), (Op.t() -> Op.t()), keyword()) :: Op.t()
  def call(%Op{name: :write} = op, next, opts) do
    opts = validate!(opts)

    if opts[:mode] == :on_write and image?(op.path, opts) do
      vix!()
      op = Op.materialize(op)
      original = Fil.ref(op.disk, op.path)

      case thumbnails(op.content, original, opts) do
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

    if image?(path, opts), do: each_variant(op, variants(op.disk, path, opts), &Fil.rm/1), else: op
  end

  def call(%Op{name: :rm_rf, path: path} = op, next, opts) do
    opts = validate!(opts)
    op = next.(op)

    if under_prefix?(path, opts[:prefix]), do: op, else: each_variant(op, variants(op.disk, path, opts), &Fil.rm_rf/1)
  end

  def call(%Op{name: :cp, path: path, dest: dest} = op, next, opts) do
    opts = validate!(opts)
    op = next.(op)

    if follows?(path, dest, opts) do
      each_variant(op, pairs(op.disk, path, dest, opts), &Fil.cp(&1.from, &1.to))
    else
      op
    end
  end

  def call(%Op{name: :rename, path: path, dest: dest} = op, next, opts) do
    opts = validate!(opts)
    op = next.(op)

    cond do
      follows?(path, dest, opts) -> each_variant(op, pairs(op.disk, path, dest, opts), &Fil.rename(&1.from, &1.to))
      image?(path, opts) -> each_variant(op, variants(op.disk, path, opts), &Fil.rm/1)
      true -> op
    end
  end

  def call(op, next, _opts), do: next.(op)

  @doc false
  # The `:prefix` type: a path inside the disk root, normalized so it compares with normalized paths.
  @spec normalize_prefix(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_prefix(prefix) when is_binary(prefix) do
    case Fil.Support.Path.normalize(prefix) do
      {:ok, "."} -> {:error, "expected a directory, got the disk root: #{inspect(prefix)}"}
      {:ok, prefix} -> {:ok, prefix}
      {:error, :ebadpath} -> {:error, "expected a directory inside the disk root, got: #{inspect(prefix)}"}
    end
  end

  def normalize_prefix(other), do: {:error, "expected a string, got: #{inspect(other)}"}

  # Runs `fun` on each item once the operation succeeded, and stops at the first error, which becomes the result. A
  # missing variant is fine: an image written before the plugin was attached has none.
  defp each_variant(%Op{result: {:ok, _value}} = op, items, fun) do
    Enum.reduce_while(items, op, fn item, op ->
      case fun.(item) do
        {:ok, _value} -> {:cont, op}
        {:error, %Fil.NotFoundError{}} -> {:cont, op}
        {:error, error} -> {:halt, Op.put_result(op, {:error, error})}
      end
    end)
  end

  defp each_variant(op, _items, _fun), do: op

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

  # An image by its extension, outside the prefix, so the plugin's own operations pass through.
  defp image?(path, opts), do: extension(path) in opts[:extensions] and not under_prefix?(path, opts[:prefix])

  # A copy or a rename keeps the variants when they still fit: the destination is an image of the same format.
  defp follows?(path, dest, opts), do: image?(path, opts) and image?(dest, opts) and extension(path) == extension(dest)

  defp extension(path) do
    path
    |> Path.extname()
    |> String.downcase()
  end

  defp under_prefix?(path, prefix), do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp variant_ref(disk, path, name, opts) do
    format = opts[:variants][name][:format]
    extension = if format, do: ".#{format}", else: ""
    variant_path = Path.join([opts[:prefix], Atom.to_string(name), path])

    Fil.ref(disk, variant_path <> extension)
  end

  defp variants(disk, path, opts) do
    for {name, _variant} <- opts[:variants], do: variant_ref(disk, path, name, opts)
  end

  defp pairs(disk, path, dest, opts) do
    for {name, _variant} <- opts[:variants] do
      %{from: variant_ref(disk, path, name, opts), to: variant_ref(disk, dest, name, opts)}
    end
  end

  # Makes every variant in memory before anything is written, as `{name, ref, binary}`.
  defp thumbnails(content, %Fil.Ref{} = original, opts) do
    result =
      with :ok <- check_pixels(content, opts[:max_pixels]) do
        Enum.reduce_while(opts[:variants], {:ok, []}, &resize(&1, &2, content, original, opts))
      end

    case result do
      {:ok, thumbnails} -> {:ok, Enum.reverse(thumbnails)}
      {:error, reason} -> {:error, %Fil.InvalidRequestError{reason: reason, path: original.path, disk: original.disk}}
    end
  end

  defp resize({name, variant}, {:ok, thumbnails}, content, original, opts) do
    ref = variant_ref(original.disk, original.path, name, opts)

    case thumbnail(content, ref.path, variant) do
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

    for {name, _variant} <- opts[:variants],
        not (name
             |> Atom.to_string()
             |> String.match?(~r/^[a-z0-9_]+$/)) do
      raise ArgumentError, "invalid variant name #{inspect(name)}, expected lowercase letters, digits and underscores"
    end

    opts
  end

  defp vix! do
    if not Code.ensure_loaded?(Operation) do
      raise "Fil.Plugin.Thumbnails needs the optional dependency Vix: add {:vix, \"~> 0.33\"} to your deps"
    end
  end
end
