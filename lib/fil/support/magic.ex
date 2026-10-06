defmodule Fil.Support.Magic do
  @moduledoc false

  # The content type of content from its first bytes (its magic bytes), for `Fil.Plugin.Validation`. Binary formats have
  # fixed signatures. Of the text formats, only those a browser runs or renders as a document are recognised (HTML, SVG,
  # XML, PostScript), so they can't pass as plain text. CSV, JSON and plain text have no signature, and are never
  # detected.

  # How many bytes `detect/1` looks at: the resource header of the WHATWG MIME Sniffing standard.
  @window 1445

  # Types that contain other types: content detected as the key may be declared as any type in its list, or with any
  # of its prefixes.
  @containers %{
    "application/zip" => [
      "application/epub+zip",
      "application/java-archive",
      "application/vnd.android.package-archive",
      {:prefix, "application/vnd.openxmlformats-officedocument."},
      {:prefix, "application/vnd.oasis.opendocument."},
      {:prefix, "application/vnd.ms-excel.sheet."},
      {:prefix, "application/vnd.ms-word.document."},
      {:prefix, "application/vnd.ms-powerpoint.presentation."}
    ],
    "application/x-cfb" => [
      "application/msword",
      "application/vnd.ms-excel",
      "application/vnd.ms-powerpoint",
      "application/vnd.ms-outlook",
      "application/x-msi"
    ],
    "application/xml" => [{:suffix, "+xml"}],
    "video/mp4" => ["audio/mp4", "audio/x-m4a", "audio/m4a", "video/x-m4v"],
    "audio/mp4" => ["video/mp4", "audio/x-m4a", "audio/m4a"],
    "video/webm" => ["audio/webm"],
    "video/x-matroska" => ["audio/x-matroska"],
    "audio/ogg" => ["application/ogg", "video/ogg", "audio/opus"]
  }

  # Other names for the same type.
  @aliases %{
    "image/jpg" => "image/jpeg",
    "text/xml" => "application/xml",
    "application/x-zip-compressed" => "application/zip",
    "image/pjpeg" => "image/jpeg",
    "image/x-icon" => "image/vnd.microsoft.icon",
    "image/x-ms-bmp" => "image/bmp",
    "image/x-bmp" => "image/bmp",
    "image/heif" => "image/heic",
    "application/x-gzip" => "application/gzip",
    "application/x-pdf" => "application/pdf",
    "audio/mp3" => "audio/mpeg",
    "audio/x-wav" => "audio/wav",
    "audio/wave" => "audio/wav",
    "audio/vnd.wave" => "audio/wav",
    "audio/x-flac" => "audio/flac",
    "application/x-rar-compressed" => "application/vnd.rar",
    "application/x-msdownload" => "application/vnd.microsoft.portable-executable",
    "application/x-msdos-program" => "application/vnd.microsoft.portable-executable",
    "application/xhtml+xml" => "text/html"
  }

  # The types `detect/1` returns for binary formats. A type that belongs to one of them (`matches?/2`) has a signature,
  # so content of that type that isn't detected isn't of that type. Text formats can start in many ways, so they're not
  # in this list.
  @binary_types [
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/bmp",
    "image/tiff",
    "image/vnd.microsoft.icon",
    "image/avif",
    "image/heic",
    "application/pdf",
    "application/zip",
    "application/x-cfb",
    "application/gzip",
    "application/x-tar",
    "application/x-7z-compressed",
    "application/vnd.rar",
    "video/mp4",
    "audio/mp4",
    "video/quicktime",
    "video/webm",
    "video/x-matroska",
    "video/x-msvideo",
    "audio/mpeg",
    "audio/aac",
    "audio/wav",
    "audio/ogg",
    "audio/flac",
    "application/vnd.microsoft.portable-executable",
    "application/x-executable",
    "application/x-mach-binary",
    "application/wasm"
  ]

  # Mach-O, 32 and 64 bits, in both byte orders.
  @mach_o [
    <<0xFE, 0xED, 0xFA, 0xCE>>,
    <<0xFE, 0xED, 0xFA, 0xCF>>,
    <<0xCE, 0xFA, 0xED, 0xFE>>,
    <<0xCF, 0xFA, 0xED, 0xFE>>
  ]

  @doc "How many bytes `detect/1` looks at."
  @spec window() :: pos_integer()
  def window, do: @window

  @doc """
  The content type of content that starts with `prefix`, or `nil` if it has no known signature.

      iex> Fil.Support.Magic.detect(<<0x89, "PNG\\r\\n", 0x1A, "\\n", 0, 0>>)
      "image/png"
      iex> Fil.Support.Magic.detect(<<0xFF, 0xD8, 0xFF, 0xE0>>)
      "image/jpeg"
      iex> Fil.Support.Magic.detect("GIF89a...")
      "image/gif"
      iex> Fil.Support.Magic.detect("RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 ")
      "image/webp"
      iex> Fil.Support.Magic.detect("%PDF-1.7")
      "application/pdf"
      iex> Fil.Support.Magic.detect(<<"PK", 3, 4, 20, 0>>)
      "application/zip"
      iex> Fil.Support.Magic.detect(<<0, 0, 0, 0x20, "ftypisom", 0, 0>>)
      "video/mp4"
      iex> Fil.Support.Magic.detect(<<0, 0, 0, 0x1C, "ftypavif", 0, 0>>)
      "image/avif"
      iex> Fil.Support.Magic.detect(<<0x7F, "ELF", 2, 1>>)
      "application/x-executable"
      iex> Fil.Support.Magic.detect("  <!DOCTYPE html><title>x</title>")
      "text/html"
      iex> Fil.Support.Magic.detect(~s(<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>))
      "image/svg+xml"
      iex> Fil.Support.Magic.detect(~s(<?xml version="1.0"?><feed/>))
      "application/xml"
      iex> Fil.Support.Magic.detect("id,email\\n1,a@example.com\\n")
      nil
      iex> Fil.Support.Magic.detect("")
      nil

  """
  @spec detect(binary()) :: String.t() | nil
  def detect(prefix) when is_binary(prefix) do
    prefix = binary_part(prefix, 0, min(byte_size(prefix), @window))
    binary(prefix) || text(prefix)
  end

  # Images.
  defp binary(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: "image/png"
  defp binary(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"
  defp binary(<<"GIF8", v, "a", _rest::binary>>) when v in [?7, ?9], do: "image/gif"
  defp binary(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: "image/webp"
  defp binary(<<"BM", _size::32, 0::32, _rest::binary>>), do: "image/bmp"
  defp binary(<<"II*", 0, _rest::binary>>), do: "image/tiff"
  defp binary(<<"MM", 0, "*", _rest::binary>>), do: "image/tiff"

  # Documents and archives.
  defp binary(<<"%PDF-", _rest::binary>>), do: "application/pdf"
  defp binary(<<"PK", a, b, _rest::binary>>) when {a, b} in [{3, 4}, {5, 6}, {7, 8}], do: "application/zip"
  defp binary(<<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, _rest::binary>>), do: "application/x-cfb"
  defp binary(<<0x1F, 0x8B, 8, _rest::binary>>), do: "application/gzip"
  defp binary(<<"7z", 0xBC, 0xAF, 0x27, 0x1C, _rest::binary>>), do: "application/x-7z-compressed"
  defp binary(<<"Rar!", 0x1A, 0x07, _rest::binary>>), do: "application/vnd.rar"
  defp binary(<<_name::binary-size(257), "ustar", _rest::binary>>), do: "application/x-tar"

  # Audio and video.
  defp binary(<<_size::binary-size(4), "ftyp", brand::binary-size(4), _rest::binary>>), do: ftyp(brand)
  defp binary(<<0x1A, 0x45, 0xDF, 0xA3, rest::binary>>), do: matroska(rest)
  defp binary(<<0, 0, 1, 0, count::little-16, _rest::binary>>) when count > 0, do: "image/vnd.microsoft.icon"
  defp binary(<<"RIFF", _size::binary-size(4), "WAVE", _rest::binary>>), do: "audio/wav"
  defp binary(<<"RIFF", _size::binary-size(4), "AVI ", _rest::binary>>), do: "video/x-msvideo"
  defp binary(<<"OggS", 0, _rest::binary>>), do: "audio/ogg"
  defp binary(<<"fLaC", _rest::binary>>), do: "audio/flac"
  defp binary(<<"ID3", major, minor, _rest::binary>>) when major in 2..4 and minor < 0xFF, do: "audio/mpeg"
  # An MPEG audio frame: 11 sync bits, the version (`01` is reserved), the layer (`00` is AAC in an ADTS frame, `11` is
  # Layer I, which nobody uses and which the UTF-16 byte order marks `FF FE` and `FF FF` look like), and in the next
  # byte a bitrate (not `1111`) and a sample rate (not `11`).
  defp binary(<<0xFF, 0b111::3, version::2, 0b00::2, _protection::1, _rest::bitstring>>) when version != 0b01,
    do: "audio/aac"

  defp binary(<<0xFF, 0b111::3, version::2, layer::2, _protection::1, bitrate::4, rate::2, _rest::bitstring>>)
       when version != 0b01 and layer in [0b01, 0b10] and bitrate != 0b1111 and rate != 0b11, do: "audio/mpeg"

  # Executables.
  defp binary(<<"MZ", _header::binary-size(58), offset::little-32, _rest::binary>> = prefix),
    do: portable(prefix, offset)

  defp binary(<<0x7F, "ELF", _rest::binary>>), do: "application/x-executable"
  defp binary(<<magic::binary-size(4), _rest::binary>>) when magic in @mach_o, do: "application/x-mach-binary"

  defp binary(<<0, "asm", _rest::binary>>), do: "application/wasm"
  defp binary(_prefix), do: nil

  # A Windows executable has `PE\0\0` where its DOS header points, so text that starts with `MZ` isn't one.
  defp portable(prefix, offset) do
    case prefix do
      <<_dos::binary-size(^offset), "PE", 0, 0, _rest::binary>> -> "application/vnd.microsoft.portable-executable"
      _other -> nil
    end
  end

  defp ftyp(brand) when brand in ["avif", "avis"], do: "image/avif"
  defp ftyp(brand) when brand in ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"], do: "image/heic"
  defp ftyp("qt  "), do: "video/quicktime"
  defp ftyp(brand) when brand in ["M4A ", "M4B ", "M4P "], do: "audio/mp4"
  defp ftyp(_brand), do: "video/mp4"

  defp matroska(rest) do
    if :binary.match(rest, "webm") == :nomatch, do: "video/x-matroska", else: "video/webm"
  end

  # Text formats, after leading whitespace and a UTF-8 byte order mark. HTML is recognised by the tags of the WHATWG
  # MIME Sniffing standard, SVG and XHTML by an `<svg` or `<html` tag anywhere in the window after an XML declaration
  # or a comment, because browsers render them and run their scripts whatever XML type they're served as.
  defp text(prefix) do
    start =
      prefix
      |> String.replace_prefix(<<0xEF, 0xBB, 0xBF>>, "")
      |> skip_whitespace()

    lower = String.downcase(start)

    cond do
      svg?(lower) -> "image/svg+xml"
      xhtml?(lower) -> "text/html"
      html?(lower) -> "text/html"
      String.starts_with?(lower, "<?xml") -> "application/xml"
      String.starts_with?(start, "%!PS-Adobe-") -> "application/postscript"
      String.starts_with?(start, "{\\rtf") -> "application/rtf"
      true -> nil
    end
  end

  defp skip_whitespace(<<c, rest::binary>>) when c in [?\t, ?\n, ?\f, ?\r, ?\s], do: skip_whitespace(rest)
  defp skip_whitespace(rest), do: rest

  defp svg?(lower) do
    String.starts_with?(lower, ["<?xml", "<!--", "<!doctype svg", "<svg"]) and lower =~ ~r/<svg[\s>\/]/
  end

  defp xhtml?(lower) do
    String.starts_with?(lower, ["<?xml", "<!--", "<!doctype html"]) and lower =~ ~r/<html[\s>\/]/
  end

  # Each is followed by a space or `>`.
  @html_tags ["<!doctype html"] ++
               ~w(<html <head <script <iframe <h1 <div <font <table <a <style <title <b <body <br <p <!--)

  defp html?(lower), do: Enum.any?(@html_tags, &String.starts_with?(lower, [&1 <> " ", &1 <> ">"]))

  @doc """
  Normalizes a content type: lowercase, without parameters, with aliases resolved.

      iex> Fil.Support.Magic.normalize("Image/JPG; charset=binary")
      "image/jpeg"

  """
  @spec normalize(String.t()) :: String.t()
  def normalize(type) do
    type =
      type
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    Map.get(@aliases, type, type)
  end

  @doc """
  Whether content of type `declared` may have been detected as `detected`: the same type, an alias, or a type that
  `detected` contains, such as a Word document in a ZIP.

      iex> Fil.Support.Magic.matches?("image/jpg", "image/jpeg")
      true
      iex> docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      iex> Fil.Support.Magic.matches?(docx, "application/zip")
      true
      iex> Fil.Support.Magic.matches?("image/png", "image/gif")
      false

  """
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(declared, detected) do
    declared = normalize(declared)
    members = Map.get(@containers, detected, [])

    declared == detected or Enum.any?(members, &contained?(declared, &1))
  end

  defp contained?(type, {:prefix, prefix}), do: String.starts_with?(type, prefix)
  defp contained?(type, {:suffix, suffix}), do: String.ends_with?(type, suffix)
  defp contained?(type, member), do: type == member

  @doc """
  Whether content of `type` always starts with a signature `detect/1` knows, so content that isn't detected can't be of
  this type.

      iex> Fil.Support.Magic.signature?("image/png")
      true
      iex> Fil.Support.Magic.signature?("text/csv")
      false

  """
  @spec signature?(String.t()) :: boolean()
  def signature?(type), do: Enum.any?(@binary_types, fn detected -> matches?(type, detected) end)
end
