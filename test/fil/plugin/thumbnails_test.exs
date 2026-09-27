defmodule Fil.Plugin.ThumbnailsTest do
  alias Fil.Adapter.Memory
  alias Fil.Op
  alias Fil.Plugin.Thumbnails
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  use ExUnit.Case, async: true

  import Fil.TelemetryHelper

  setup do
    Memory.checkout()
  end

  defp disk(opts \\ []) do
    {disk_opts, plugin_opts} = Keyword.split(opts, [:root])

    [adapter: Memory]
    |> Keyword.merge(disk_opts)
    |> Fil.disk()
    |> Thumbnails.attach(Keyword.put_new(plugin_opts, :variants, small: [width: 100]))
  end

  # A black image of the given size, encoded by its extension. libvips adds EXIF data to it.
  defp image(width, height, extension \\ ".png") do
    {:ok, image} = Operation.black(width, height)
    {:ok, data} = Image.write_to_buffer(image, extension)
    data
  end

  defp size(data) do
    {:ok, image} = Image.new_from_buffer(data)
    {Image.width(image), Image.height(image)}
  end

  defp header_names(data) do
    {:ok, image} = Image.new_from_buffer(data)
    {:ok, names} = Image.header_field_names(image)
    names
  end

  defp variant_size(disk, path, name) do
    disk
    |> Thumbnails.variant(path, name)
    |> Fil.read!()
    |> size()
  end

  # Fails every write under `thumbnails/` as unavailable, after the plugin.
  defp failing_variants(disk) do
    Fil.attach(disk, :failing, fn
      %Op{name: :write, path: "thumbnails/" <> _rest} = op, _next, _opts ->
        Op.put_result(op, {:error, %Fil.UnavailableError{reason: :test}})

      op, next, _opts ->
        next.(op)
    end)
  end

  describe "writes" do
    test "write each variant in its size" do
      disk = disk(variants: [small: [width: 100], square: [width: 40, crop: :center]])

      assert {:ok, _photo} = Fil.write(disk, "cats/tom.png", image(400, 200))

      assert variant_size(disk, "cats/tom.png", :small) == {100, 50}
      assert variant_size(disk, "cats/tom.png", :square) == {40, 40}
      assert Fil.exists?(disk, "thumbnails/small/cats/tom.png")
    end

    test "only the width limits a portrait image without a height" do
      disk = disk()
      Fil.write!(disk, "tall.png", image(200, 400))

      assert variant_size(disk, "tall.png", :small) == {100, 200}
    end

    test "fit into the height too, or crop to exactly the width and the height" do
      disk = disk(variants: [box: [width: 100, height: 20], cut: [width: 100, height: 20, crop: :attention]])
      Fil.write!(disk, "wide.png", image(400, 200))

      assert variant_size(disk, "wide.png", :box) == {40, 20}
      assert variant_size(disk, "wide.png", :cut) == {100, 20}
    end

    test "never enlarge an image" do
      disk = disk(variants: [small: [width: 100], square: [width: 100, crop: :center]])
      Fil.write!(disk, "tiny.png", image(50, 40))

      assert variant_size(disk, "tiny.png", :small) == {50, 40}
      assert variant_size(disk, "tiny.png", :square) == {50, 40}
    end

    test "convert with format:, appending the format's extension" do
      disk = disk(variants: [small: [width: 100, format: :webp, quality: 50]])
      Fil.write!(disk, "cats/tom.png", image(400, 200))

      variant = Thumbnails.variant(disk, "cats/tom.png", :small)
      assert variant.path == "thumbnails/small/cats/tom.png.webp"
      assert {:ok, %Fil.Stat{content_type: "image/webp"}} = Fil.stat(variant)

      {:ok, image} =
        variant
        |> Fil.read!()
        |> Image.new_from_buffer()

      assert Image.header_value(image, "vips-loader") == {:ok, "webpload_buffer"}
    end

    test "work for every default extension, in any case" do
      disk = disk()

      for extension <- ~w(.jpg .jpeg .png .webp .JPG) do
        path = "photo" <> extension
        Fil.write!(disk, path, image(400, 200, String.downcase(extension)))

        assert variant_size(disk, path, :small) == {100, 50}
      end
    end

    test "keep no metadata besides the colour profile" do
      disk = disk()
      photo = image(400, 200, ".jpg")
      Fil.write!(disk, "photo.jpg", photo)

      assert "exif-data" in header_names(photo)

      refute disk
             |> Thumbnails.variant("photo.jpg", :small)
             |> Fil.read!()
             |> header_names()
             |> Enum.any?(&String.starts_with?(&1, "exif"))
    end

    test "work on a stream" do
      disk = disk()
      photo = image(400, 200)
      chunks = for <<chunk::binary-size(10) <- photo>>, do: chunk
      rest = binary_part(photo, length(chunks) * 10, rem(byte_size(photo), 10))

      assert {:ok, _photo} = Fil.write(disk, "stream.png", Stream.concat(chunks, [rest]))

      assert Fil.read!(disk, "stream.png") == photo
      assert variant_size(disk, "stream.png", :small) == {100, 50}
    end

    test "leave other files alone, and streams as streams" do
      test = self()

      disk =
        Fil.attach(disk(), :inspect, fn op, next, _opts ->
          send(test, {:content, op.content})
          next.(op)
        end)

      assert {:ok, _notes} = Fil.write(disk, "notes.txt", Stream.map(["a", "b"], & &1))

      assert_received {:content, content}
      refute is_binary(content) or is_list(content)
      assert Fil.ls!(disk) |> Enum.map(& &1.path) == ["notes.txt"]
    end

    test "make no variants of variants, but of files next to the prefix" do
      disk = disk()

      Fil.write!(disk, "thumbnails/small/own.png", image(400, 200))
      Fil.write!(disk, "thumbnailsX/other.png", image(400, 200))

      refute Fil.exists?(disk, "thumbnails/small/thumbnails/small/own.png")
      assert Fil.exists?(disk, "thumbnails/small/thumbnailsX/other.png")
    end

    test "refuse content that isn't an image, and write nothing" do
      disk = disk()

      assert {:error, %Fil.InvalidRequestError{reason: {:not_an_image, message}} = error} =
               Fil.write(disk, "fake.jpg", "not a jpeg")

      assert {error.op, error.path} == {:write, "fake.jpg"}
      refute String.contains?(message, "\n")
      assert Fil.ls!(disk) == []
    end

    test "refuse an image with more than :max_pixels" do
      disk = disk(max_pixels: 1000)

      assert {:error, %Fil.InvalidRequestError{reason: {:too_many_pixels, 80_000}}} =
               Fil.write(disk, "big.png", image(400, 200))

      refute Fil.exists?(disk, "big.png")
    end

    test "write no variants when the image isn't written" do
      disk = disk()
      Fil.write!(disk, "photo.png", image(400, 200))

      assert {:error, %Fil.AlreadyExistsError{}} =
               Fil.write(disk, "photo.png", image(200, 200), if_exists: :error)

      assert variant_size(disk, "photo.png", :small) == {100, 50}
    end

    test "return the error of a variant that can't be written, and keep the image" do
      disk = failing_variants(disk())

      assert {:error, %Fil.UnavailableError{} = error} = Fil.write(disk, "photo.png", image(400, 200))
      assert {error.op, error.path} == {:write, "thumbnails/small/photo.png"}
      assert Fil.exists?(disk, "photo.png")
    end

    test "emit a :write event for the image and one for each variant" do
      disk = disk(variants: [small: [width: 100], large: [width: 200]])
      attach([[:fil, :op, :stop]])

      Fil.write!(disk, "photo.png", image(400, 200))

      assert [
               {_, _, %{op: :write, path: "thumbnails/small/photo.png"}},
               {_, _, %{op: :write, path: "thumbnails/large/photo.png"}},
               {_, _, %{op: :write, path: "photo.png"}}
             ] = events()
    end
  end

  describe "deletes, copies and renames" do
    setup do
      disk = disk()
      Fil.write!(disk, "cats/tom.png", image(400, 200))
      %{disk: disk}
    end

    test "rm deletes the variants", %{disk: disk} do
      assert {:ok, _tom} = Fil.rm(disk, "cats/tom.png")

      refute Fil.exists?(disk, "thumbnails/small/cats/tom.png")
    end

    test "rm_rf deletes the variants under the path, or of the file" do
      disk = disk(variants: [small: [width: 100], webp: [width: 100, format: :webp]])
      Fil.write!(disk, "cats/tom.png", image(400, 200))
      Fil.write!(disk, "cats/felix.png", image(400, 200))
      Fil.write!(disk, "dogs/rex.png", image(400, 200))

      assert Fil.rm_rf(disk, "cats") == {:ok, 2}
      assert Fil.rm_rf(disk, "dogs/rex.png") == {:ok, 1}
      assert Fil.ls!(disk, ".", recursive: true) == []
    end

    test "rm and cp of other files leave the variants alone", %{disk: disk} do
      Fil.write!(disk, "notes.txt", "notes")
      Fil.write!(disk, "thumbnails/small/notes.txt", "not a variant")

      Fil.cp!(disk, "notes.txt", "copy.txt")
      Fil.rm!(disk, "notes.txt")

      assert Fil.exists?(disk, "thumbnails/small/notes.txt")
      refute Fil.exists?(disk, "thumbnails/small/copy.txt")
    end

    test "cp and rename take the variants along", %{disk: disk} do
      Fil.cp!(disk, "cats/tom.png", "cats/copy.PNG")
      Fil.rename!(disk, "cats/tom.png", "cats/moved.png")

      assert variant_size(disk, "cats/copy.PNG", :small) == {100, 50}
      assert variant_size(disk, "cats/moved.png", :small) == {100, 50}
      refute Fil.exists?(disk, "thumbnails/small/cats/tom.png")
    end

    test "to another extension, rename deletes the variants and cp leaves them", %{disk: disk} do
      Fil.cp!(disk, "cats/tom.png", "cats/copy.jpg")
      assert Fil.exists?(disk, "thumbnails/small/cats/tom.png")
      refute Fil.exists?(disk, "thumbnails/small/cats/copy.jpg")

      Fil.rename!(disk, "cats/tom.png", "cats/tom.bin")
      refute Fil.exists?(disk, "thumbnails/small/cats/tom.png")
      refute Fil.exists?(disk, "thumbnails/small/cats/tom.bin")
    end

    test "cp and rename delete the variants the destination had", %{disk: disk} do
      Fil.write!(disk, "cats/felix.jpg", image(400, 200, ".jpg"))
      Fil.write!(disk, "cats/rex.jpg", image(400, 200, ".jpg"))

      Fil.cp!(disk, "cats/tom.png", "cats/felix.jpg")
      Fil.rename!(disk, "cats/tom.png", "cats/rex.jpg")

      refute Fil.exists?(disk, "thumbnails/small/cats/felix.jpg")
      refute Fil.exists?(disk, "thumbnails/small/cats/rex.jpg")
    end

    test "an image without variants takes the destination's along", %{disk: disk} do
      Fil.write!(disk, "cats/felix.png", image(400, 200))
      Fil.write!(disk, "cats/rex.png", image(400, 200))
      Fil.rm!(disk, "thumbnails/small/cats/tom.png")

      assert {:ok, _felix} = Fil.cp(disk, "cats/tom.png", "cats/felix.png")
      assert {:ok, _rex} = Fil.rename(disk, "cats/tom.png", "cats/rex.png")

      refute Fil.exists?(disk, "thumbnails/small/cats/felix.png")
      refute Fil.exists?(disk, "thumbnails/small/cats/rex.png")
    end

    test "across disks, the destination makes its own variants", %{disk: disk} do
      other = disk(root: "other", variants: [large: [width: 200]])

      Fil.cp!(disk, "cats/tom.png", Fil.ref(other, "tom.png"))
      assert variant_size(other, "tom.png", :large) == {200, 100}

      Fil.rename!(disk, "cats/tom.png", Fil.ref(other, "moved.png"))
      refute Fil.exists?(disk, "thumbnails/small/cats/tom.png")
      assert variant_size(other, "moved.png", :large) == {200, 100}
    end

    test "return the error of a variant", %{disk: disk} do
      disk =
        Fil.attach(disk, :failing, fn
          %Op{name: :rm, path: "thumbnails/" <> _rest} = op, _next, _opts ->
            Op.put_result(op, {:error, %Fil.UnavailableError{reason: :test}})

          op, next, _opts ->
            next.(op)
        end)

      assert {:error, %Fil.UnavailableError{path: "thumbnails/small/cats/tom.png"}} = Fil.rm(disk, "cats/tom.png")
      refute Fil.exists?(disk, "cats/tom.png")
    end
  end

  describe "generate/2" do
    test "makes the variants of a stored image, as mode: :manual leaves them to it" do
      disk = disk(mode: :manual, variants: [small: [width: 100], large: [width: 200]])
      Fil.write!(disk, "cats/tom.png", image(400, 200))
      refute Fil.exists?(disk, "thumbnails/small/cats/tom.png")

      assert {:ok, [small: small, large: large]} = Thumbnails.generate(disk, "cats/tom.png")

      assert small == Thumbnails.variant(disk, "cats/tom.png", :small)

      assert large
             |> Fil.read!()
             |> size() == {200, 100}
    end

    test "returns the errors of the read and of the image" do
      disk = disk()
      # The same store, without the plugin.
      [adapter: Memory]
      |> Fil.disk()
      |> Fil.write!("fake.png", "not a png")

      assert {:error, %Fil.NotFoundError{path: "missing.png"}} = Thumbnails.generate(disk, "missing.png")

      assert {:error, %Fil.InvalidRequestError{reason: {:not_an_image, _}, path: "fake.png"}} =
               disk
               |> Fil.ref("fake.png")
               |> Thumbnails.generate()
    end

    test "raises for a path that isn't an image" do
      assert_raise ArgumentError, ~r/isn't an image/, fn -> Thumbnails.generate(disk(), "notes.txt") end
      assert_raise ArgumentError, ~r/under :prefix/, fn -> Thumbnails.generate(disk(), "thumbnails/small/a.png") end
    end
  end

  describe "variant/3" do
    test "normalizes the path" do
      assert Thumbnails.variant(disk(), "/cats//tom.jpg", :small).path == "thumbnails/small/cats/tom.jpg"
    end

    test "raises for a disk without the plugin, an unknown variant or a path outside the root" do
      assert_raise ArgumentError, ~r/isn't attached/, fn ->
        [adapter: Memory]
        |> Fil.disk()
        |> Thumbnails.variant("a.jpg", :small)
      end

      assert_raise ArgumentError, ~r/unknown variant :large/, fn -> Thumbnails.variant(disk(), "a.jpg", :large) end
      assert_raise ArgumentError, ~r/unknown variant "small"/, fn -> Thumbnails.variant(disk(), "a.jpg", "small") end
      assert_raise ArgumentError, ~r/escapes/, fn -> Thumbnails.variant(disk(), "../a.jpg", :small) end
    end
  end

  describe "options" do
    test "are validated by attach/2" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:widht\]/, fn ->
        disk(variants: [small: [widht: 100]])
      end

      assert_raise ArgumentError, ~r/invalid variant name :Small/, fn -> disk(variants: [Small: [width: 100]]) end
      assert_raise ArgumentError, ~r/invalid variant name :"a\/b"/, fn -> disk(variants: ["a/b": [width: 100]]) end
      assert_raise NimbleOptions.ValidationError, ~r/disk root/, fn -> disk(prefix: "/") end
      assert_raise NimbleOptions.ValidationError, ~r/inside the disk root/, fn -> disk(prefix: "../up") end
    end

    test "are validated on the first write of a disk from config" do
      disk = Fil.disk(adapter: Memory, plugins: [{Thumbnails, :call, variants: [small: [width: 0]]}])

      assert_raise NimbleOptions.ValidationError, ~r/expected positive integer/, fn ->
        Fil.write(disk, "a.png", "png")
      end
    end

    test "normalize the prefix" do
      disk = disk(prefix: "/media//thumbs/")

      assert Thumbnails.variant(disk, "a.jpg", :small).path == "media/thumbs/small/a.jpg"
    end
  end
end
