defmodule Fil.Plugin.ValidationTest do
  alias Fil.Adapter.Memory
  alias Fil.Op
  alias Fil.Plugin.Validation

  use ExUnit.Case, async: true

  import Fil.AdapterCase, only: [chunked: 2]

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR">> <> :binary.copy(<<0>>, 100)
  @gif "GIF89a" <> :binary.copy(<<0>>, 100)
  @zip <<"PK", 3, 4>> <> :binary.copy(<<0>>, 100)
  @csv "id,email\n1,a@example.com\n"

  setup do
    Memory.checkout()
    {:ok, disk: Fil.disk(adapter: Memory)}
  end

  # Validation, and inside it a spy that tells the test what reaches the adapter: each op, its size and each chunk.
  defp validating(disk, opts) do
    test = self()

    disk
    |> Validation.attach(opts)
    |> Fil.attach(:spy, fn op, next, _opts ->
      send(test, {:reached, op.name, Op.get_option(op, :size)})

      op
      |> Op.scan_content(nil, fn chunk, nil ->
        send(test, {:chunk, chunk})
        nil
      end)
      |> next.()
    end)
  end

  defp reason({:error, %Fil.InvalidContentError{reason: reason}}), do: reason
  defp reason(other), do: other

  describe "sizes" do
    test "content in memory over max_size never reaches the adapter", %{disk: disk} do
      disk = validating(disk, max_size: 5)

      assert {:error, %Fil.InvalidContentError{op: :write, path: "a.txt", reason: {:too_large, 5}}} =
               Fil.write(disk, "a.txt", "123456")

      refute_received {:reached, _name, _size}
      assert Fil.write(disk, "a.txt", "12345") |> elem(0) == :ok
    end

    test "a stream over a declared size never reaches the adapter", %{disk: disk} do
      disk = validating(disk, max_size: 5)

      assert reason(Fil.write(disk, "a.txt", chunked("123456", 2), size: 6)) == {:too_large, 5}
      refute_received {:reached, _name, _size}
    end

    test "a stream without a size fails before the chunk that crosses max_size", %{disk: disk} do
      disk = validating(disk, max_size: 5)

      assert reason(Fil.write(disk, "a.txt", chunked("1234567", 2))) == {:too_large, 5}
      assert_received {:chunk, "12"}
      assert_received {:chunk, "34"}
      refute_received {:chunk, "56"}
      refute Fil.exists?(disk, "a.txt")
    end

    test "min_size refuses smaller content, declared or found while it's read", %{disk: disk} do
      disk = validating(disk, min_size: 3)

      assert reason(Fil.write(disk, "a.txt", "")) == {:too_small, 3}
      assert reason(Fil.write(disk, "a.txt", chunked("ab", 1), size: 2)) == {:too_small, 3}
      refute_received {:reached, _name, _size}

      assert reason(Fil.write(disk, "a.txt", chunked("ab", 1))) == {:too_small, 3}
      assert reason(Fil.write(disk, "a.txt", Stream.map([], & &1))) == {:too_small, 3}
      assert {:ok, _} = Fil.write(disk, "a.txt", chunked("abc", 1))
    end

    test "a stream keeps its size", %{disk: disk} do
      disk = validating(disk, max_size: 100, content_types: ["text/plain"])

      assert {:ok, _} = Fil.write(disk, "a.txt", chunked("hello", 2), size: 5)
      assert_received {:reached, :write, 5}
    end
  end

  describe "extensions" do
    test "only the listed extensions, in any case, with or without the dot", %{disk: disk} do
      disk = validating(disk, extensions: ["png", ".JPG"])

      assert {:ok, _} = Fil.write(disk, "a.PNG", @png)
      assert {:ok, _} = Fil.write(disk, "b.jpg", "x")
      assert reason(Fil.write(disk, "c.gif", @gif)) == {:extension, "gif"}
      assert reason(Fil.write(disk, "Makefile", "x")) == {:extension, ""}
    end

    test "apply to the destination of a copy or a move within the disk", %{disk: disk} do
      disk = validating(disk, extensions: ["png"])
      {:ok, _} = Fil.write(disk, "a.png", @png)

      assert {:error, %Fil.InvalidContentError{op: :cp, reason: {:extension, "html"}}} =
               Fil.cp(disk, "a.png", "a.html")

      assert reason(Fil.rename(disk, "a.png", "a.html")) == {:extension, "html"}
      assert {:ok, _} = Fil.cp(disk, "a.png", "b.png")
      refute Fil.exists?(disk, "a.html")
    end
  end

  describe "content types" do
    test "the content's type has to be allowed", %{disk: disk} do
      disk = validating(disk, content_types: ["image/png", "image/jpeg"])

      assert {:ok, _} = Fil.write(disk, "a.png", @png)
      assert reason(Fil.write(disk, "b.png", @gif)) == {:content_type, "image/gif"}
      assert reason(Fil.write(disk, "b.png", chunked(@gif, 1))) == {:content_type, "image/gif"}
      refute Fil.exists?(disk, "b.png")
    end

    test "wildcards take every subtype", %{disk: disk} do
      disk = validating(disk, content_types: ["image/*"])

      assert {:ok, _} = Fil.write(disk, "a.gif", @gif)
      assert reason(Fil.write(disk, "a.pdf", "%PDF-1.7")) == {:content_type, "application/pdf"}
    end

    test "a declared type has to be allowed and match the content", %{disk: disk} do
      disk = validating(disk, content_types: ["image/png", "image/gif", "text/csv"])

      assert reason(Fil.write(disk, "a", @gif, content_type: "image/png")) ==
               {:content_type_mismatch, "image/png", "image/gif"}

      assert reason(Fil.write(disk, "a", @csv, content_type: "image/png")) == {:content_type_mismatch, "image/png", nil}
      assert reason(Fil.write(disk, "a", @png, content_type: "image/webp")) == {:content_type, "image/webp"}
      refute_received {:reached, _name, _size}

      assert {:ok, _} = Fil.write(disk, "a", @png, content_type: "IMAGE/PNG; charset=binary")
      assert {:ok, _} = Fil.write(disk, "b", @csv, content_type: "text/csv")
      assert {:ok, _} = Fil.write(disk, "c", @png, content_type: "application/octet-stream")
    end

    test "the extension's type has to be allowed, whatever the content", %{disk: disk} do
      disk = validating(disk, content_types: ["image/png"])

      assert reason(Fil.write(disk, "a.html", @png)) == {:content_type, "text/html"}
      refute_received {:reached, _name, _size}
    end

    test "content without a signature is checked by its declared or its extension's type", %{disk: disk} do
      disk = validating(disk, content_types: ["text/csv", "text/plain"])

      assert {:ok, _} = Fil.write(disk, "a.csv", @csv)
      assert {:ok, _} = Fil.write(disk, "a.txt", chunked("hello", 1))
      assert reason(Fil.write(disk, "data", @csv)) == {:content_type, nil}
      assert {:ok, _} = Fil.write(disk, "data", @csv, content_type: "text/csv")
    end

    test "HTML and SVG can't pass as text", %{disk: disk} do
      disk = validating(disk, content_types: ["text/plain"])

      assert reason(Fil.write(disk, "a.txt", "\n<script>alert(1)</script>")) == {:content_type, "text/html"}

      svg = ~s{<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>}
      assert reason(Fil.write(disk, "a.txt", chunked(svg, 1))) == {:content_type, "image/svg+xml"}
    end

    test "a type with a signature over content without one is a mismatch", %{disk: disk} do
      disk = validating(disk, content_types: ["image/png"])

      assert reason(Fil.write(disk, "a.png", "not a png")) == {:content_type_mismatch, "image/png", nil}
      assert reason(Fil.write(disk, "a.png", "")) == {:content_type_mismatch, "image/png", nil}
    end

    test "office documents are ZIPs of their declared or named type", %{disk: disk} do
      xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      disk = validating(disk, content_types: [xlsx])

      assert {:ok, _} = Fil.write(disk, "report.xlsx", @zip)
      assert {:ok, _} = Fil.write(disk, "report", chunked(@zip, 7), content_type: xlsx)
      assert reason(Fil.write(disk, "report.zip", @zip)) == {:content_type, "application/zip"}
      assert reason(Fil.write(disk, "report", @zip)) == {:content_type, "application/zip"}
    end

    test "wildcards don't take the types a browser runs scripts in", %{disk: disk} do
      svg = ~s{<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>}
      xhtml = ~s(<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><script/></html>)

      wildcard = validating(disk, content_types: ["image/*", "text/*"])
      assert reason(Fil.write(wildcard, "a.svg", svg)) == {:content_type, "image/svg+xml"}
      assert reason(Fil.write(wildcard, "a.txt", "<html>")) == {:content_type, "text/html"}

      named = validating(disk, content_types: ["image/svg+xml", "application/xml"])
      assert {:ok, _} = Fil.write(named, "a.svg", svg)
      assert {:ok, _} = Fil.write(named, "a.xml", ~s(<?xml version="1.0"?><feed/>), content_type: "text/xml")
      assert reason(Fil.write(named, "b.xml", xhtml)) == {:content_type, "text/html"}
    end

    test "common types that browsers and MIME name differently are the same", %{disk: disk} do
      m4a = <<0, 0, 0, 0x1C, "ftypM4A ">> <> :binary.copy(<<0>>, 50)
      utf16_csv = <<0xFF, 0xFE, "i", 0, "d", 0, "\n", 0>>

      zips = validating(disk, content_types: ["application/zip"])
      audio = validating(disk, content_types: ["audio/mp4"])
      tables = validating(disk, content_types: ["text/csv"])

      assert {:ok, _} = Fil.write(zips, "a.zip", @zip, content_type: "application/x-zip-compressed")
      assert {:ok, _} = Fil.write(audio, "a.m4a", m4a)
      assert {:ok, _} = Fil.write(tables, "a.csv", utf16_csv)
      assert {:ok, _} = Fil.write(tables, "b.csv", @csv, content_type: "")
    end

    test "a copy across disks is checked as a write to the destination", %{disk: disk} do
      source = Fil.disk(adapter: Memory, root: "source")
      {:ok, gif} = Fil.write(source, "a.png", @gif)
      {:ok, png} = Fil.write(source, "b.png", @png)
      disk = validating(disk, content_types: ["image/png"])
      a = Fil.ref(disk, "a.png")
      b = Fil.ref(disk, "b.png")

      assert {:error, %Fil.InvalidContentError{op: :cp, reason: {:content_type, "image/gif"}}} = Fil.cp(gif, a)
      assert {:ok, _} = Fil.cp(png, b)
      refute Fil.exists?(a)
    end

    test "the type is checked across chunks, as soon as there are enough bytes", %{disk: disk} do
      disk = validating(disk, content_types: ["text/plain"])
      long = :binary.copy("a", 5_000)

      assert {:ok, _} = Fil.write(disk, "a.txt", chunked(long, 1_000))

      # 1445 bytes are there with the second chunk, which isn't passed on.
      flush()
      late_html = "<html>" <> long
      assert reason(Fil.write(disk, "b.txt", chunked(late_html, 1_000))) == {:content_type, "text/html"}
      assert_received {:chunk, <<"<html>", _rest::binary>>}
      refute_received {:chunk, _chunk}
    end
  end

  describe "check:" do
    def deny_tmp(%Op{path: "tmp/" <> _rest}, reason), do: {:error, reason}
    def deny_tmp(%Op{}, _reason), do: :ok

    test "refuses with the reason the function returns, before the content is read", %{disk: disk} do
      test = self()

      checking =
        validating(disk,
          check: fn op ->
            send(test, {:checked, op.name, op.path})
            if "no.txt" in [op.path, op.dest], do: {:error, :nope}, else: :ok
          end
        )

      assert reason(Fil.write(checking, "no.txt", "x")) == :nope
      assert_received {:checked, :write, "no.txt"}
      refute_received {:reached, _name, _size}

      assert {:ok, _} = Fil.write(checking, "yes.txt", "x")
      assert reason(Fil.cp(checking, "yes.txt", "no.txt")) == :nope
    end

    test "takes an MFA, which works from config", %{disk: disk} do
      configured =
        Fil.disk(adapter: Memory, plugins: [{Validation, :call, check: {__MODULE__, :deny_tmp, [:temporary]}}])

      assert reason(Fil.write(configured, "tmp/a.txt", "x")) == :temporary
      assert {:ok, _} = Fil.write(configured, "a.txt", "x")
      assert {:ok, _} = Fil.write(disk, "tmp/a.txt", "x")
    end

    test "raises for anything other than :ok or {:error, reason}", %{disk: disk} do
      disk = Validation.attach(disk, check: fn _op -> true end)

      assert_raise ArgumentError, ~r/must return :ok or \{:error, reason\}, got: true/, fn ->
        Fil.write(disk, "a.txt", "x")
      end
    end
  end

  describe "upload URLs" do
    defp s3(opts) do
      [
        adapter: Fil.Adapter.S3,
        bucket: "bucket",
        region: "eu-central-1",
        access_key_id: "AKID",
        secret_access_key: "secret"
      ]
      |> Fil.disk()
      |> Validation.attach(opts)
    end

    test "the signed size, content type and extension are checked when the URL is signed", %{disk: disk} do
      # Attached before Fil.Plugin.URL, which answers without the plugins after it.
      signing =
        disk
        |> Validation.attach(max_size: 10, content_types: ["image/png"], extensions: ["png"])
        |> Fil.Plugin.URL.attach(base_url: "http://localhost/storage", secret: "secret")

      assert {:ok, _url} = Fil.signed_url(signing, "a.png", method: :put, size: 10, content_type: "image/png")

      assert {:error, %Fil.InvalidContentError{op: :signed_url, reason: {:too_large, 10}}} =
               Fil.signed_url(signing, "a.png", method: :put, size: 11)

      assert reason(Fil.signed_url(signing, "a.png", method: :put, content_type: "image/gif")) ==
               {:content_type, "image/gif"}

      assert reason(Fil.signed_url(signing, "a.gif", method: :put)) == {:extension, "gif"}
      assert {:ok, _url} = Fil.signed_url(signing, "a.gif")
    end

    test "check: runs on upload URLs", %{disk: disk} do
      signing =
        disk
        |> Validation.attach(check: fn op -> if op.name == :signed_url, do: {:error, :no_uploads}, else: :ok end)
        |> Fil.Plugin.URL.attach(base_url: "http://localhost/storage", secret: "secret")

      assert reason(Fil.signed_url(signing, "a.png", method: :put)) == :no_uploads
      assert {:ok, _url} = Fil.signed_url(signing, "a.png")
    end

    test "a disk that can't sign upload URLs says so", %{disk: disk} do
      disk = Validation.attach(disk, content_types: ["image/png"])

      assert {:error, %Fil.UnsupportedError{reason: :no_callback}} = Fil.signed_url(disk, "a.png", method: :put)
    end

    test "a URL Fil.Plug serves needs nothing more, because its upload is checked", %{disk: disk} do
      signing =
        disk
        |> Validation.attach(max_size: 10, content_types: ["image/png"])
        |> Fil.Plugin.URL.attach(base_url: "http://localhost/storage", secret: "secret")

      assert {:ok, _url} = Fil.signed_url(signing, "a.png", method: :put)
    end

    test "a presigned upload is refused for what the storage can't check" do
      typed = s3(content_types: ["image/png"])
      limited = s3(max_size: 10)
      at_least = s3(min_size: 1)
      named = s3(max_size: 10, extensions: ["png"])

      assert {:error, %Fil.UnsupportedError{op: :signed_url, reason: {:unchecked, :content_types}}} =
               Fil.signed_url(typed, "a.png", method: :put, content_type: "image/png", size: 10)

      assert {:error, %Fil.UnsupportedError{reason: {:unchecked, :max_size}}} =
               Fil.signed_url(limited, "a.png", method: :put)

      assert {:error, %Fil.UnsupportedError{reason: {:unchecked, :min_size}}} =
               Fil.signed_url(at_least, "a.png", method: :put)

      assert {:ok, _url} = Fil.signed_url(named, "a.png", method: :put, size: 10)
      assert {:ok, _url} = Fil.signed_url(typed, "a.png")
    end

    test "presigned_uploads: :check_declared takes the signed content type" do
      disk = s3(content_types: ["image/png"], presigned_uploads: :check_declared)

      assert {:ok, _url} = Fil.signed_url(disk, "a.png", method: :put, content_type: "image/png")

      assert reason(Fil.signed_url(disk, "a.png", method: :put, content_type: "text/html")) ==
               {:content_type, "text/html"}

      assert {:error, %Fil.UnsupportedError{reason: {:unchecked, :content_types}}} =
               Fil.signed_url(disk, "a.png", method: :put)

      limited = s3(max_size: 10, presigned_uploads: :check_declared)

      assert {:error, %Fil.UnsupportedError{reason: {:unchecked, :max_size}}} =
               Fil.signed_url(limited, "a.png", method: :put)
    end
  end

  describe "options" do
    test "are validated when attached, and from config on the first call", %{disk: disk} do
      assert_raise NimbleOptions.ValidationError, ~r/expected a content type such as/, fn ->
        Validation.attach(disk, content_types: ["png"])
      end

      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:max\]/, fn ->
        Validation.attach(disk, max: 1)
      end

      configured = Fil.disk(adapter: Memory, plugins: [{Validation, :call, max_size: 0}])

      assert_raise NimbleOptions.ValidationError, fn -> Fil.write(configured, "a.txt", "x") end
    end

    test "other operations pass through", %{disk: disk} do
      {:ok, _} = Fil.write(disk, "a.html", "<html>")
      disk = Validation.attach(disk, content_types: ["image/png"], extensions: ["png"], max_size: 1)

      assert Fil.read(disk, "a.html") == {:ok, "<html>"}
      assert {:ok, _} = Fil.stat(disk, "a.html")
      assert {:ok, _} = Fil.rm(disk, "a.html")
    end
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end
end
