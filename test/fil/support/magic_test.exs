defmodule Fil.Support.MagicTest do
  alias Fil.Support.Magic

  use ExUnit.Case, async: true

  test "detects binary formats by their signatures" do
    for {prefix, type} <- [
          {<<"BM", 0x36, 0x28, 0, 0, 0, 0, 0, 0, 0x36, 0>>, "image/bmp"},
          {<<"II*", 0, 8, 0>>, "image/tiff"},
          {<<"MM", 0, "*", 0, 8>>, "image/tiff"},
          {<<0, 0, 1, 0, 1, 0, 16, 16>>, "image/vnd.microsoft.icon"},
          {<<0, 0, 0, 0x18, "ftypheic", 0, 0>>, "image/heic"},
          {<<0, 0, 0, 0x14, "ftypqt  ", 0, 0>>, "video/quicktime"},
          {<<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1>>, "application/x-cfb"},
          {<<0x1F, 0x8B, 8, 0>>, "application/gzip"},
          {<<"7z", 0xBC, 0xAF, 0x27, 0x1C>>, "application/x-7z-compressed"},
          {<<"Rar!", 0x1A, 0x07, 0>>, "application/vnd.rar"},
          {:binary.copy(<<0>>, 257) <> "ustar\0", "application/x-tar"},
          {<<0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x84, "webm">>, "video/webm"},
          {<<0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x88, "matroska">>, "video/x-matroska"},
          {"RIFF" <> <<0, 0, 0, 0>> <> "WAVEfmt ", "audio/wav"},
          {"RIFF" <> <<0, 0, 0, 0>> <> "AVI LIST", "video/x-msvideo"},
          {<<"OggS", 0, 2>>, "audio/ogg"},
          {"fLaC" <> <<0, 0, 0, 34>>, "audio/flac"},
          {"ID3" <> <<4, 0>>, "audio/mpeg"},
          {<<0xFF, 0xFB, 0x90, 0x64>>, "audio/mpeg"},
          {<<0xFF, 0xF1, 0x50, 0x80>>, "audio/aac"},
          {"MZ" <> :binary.copy(<<0>>, 58) <> <<64::little-32>> <> "PE\0\0",
           "application/vnd.microsoft.portable-executable"},
          {<<0, 0, 0, 0x1C, "ftypM4A ", 0, 0>>, "audio/mp4"},
          {<<0xCF, 0xFA, 0xED, 0xFE, 7, 0>>, "application/x-mach-binary"},
          {<<0, "asm", 1, 0, 0, 0>>, "application/wasm"}
        ] do
      assert Magic.detect(prefix) == type, "expected #{inspect(prefix)} to be #{type}"
    end
  end

  test "detects the text formats a browser renders, after whitespace and a byte order mark" do
    for {prefix, type} <- [
          {"<HTML>", "text/html"},
          {<<0xEF, 0xBB, 0xBF, "\n  <script>alert(1)</script>">>, "text/html"},
          {"<p>Hello</p>", "text/html"},
          {"<!-- comment --><div>", "text/html"},
          {"<!-- generator --><svg viewBox='0 0 1 1'></svg>", "image/svg+xml"},
          {"<svg>", "image/svg+xml"},
          {~s(<?xml version="1.0"?>\n<html xmlns="http://www.w3.org/1999/xhtml"><script/></html>), "text/html"},
          {"%!PS-Adobe-3.0", "application/postscript"},
          {"{\\rtf1\\ansi", "application/rtf"}
        ] do
      assert Magic.detect(prefix) == type, "expected #{inspect(prefix)} to be #{type}"
    end
  end

  test "detects nothing in text without a signature" do
    for prefix <- [
          "BMW,320d,2019\n",
          "MZ,1,2\n" <> :binary.copy("x", 100),
          "ID3,artist\n",
          <<0xFF, 0xFE, "i", 0, "d", 0>>,
          <<0xFF, 0xFF, 0, 0>>,
          "<pre",
          "<paragraph>",
          ~s({"a": 1}),
          "hello",
          "<svgfoo>",
          "MM,1,2"
        ] do
      assert Magic.detect(prefix) == nil, "expected #{inspect(prefix)} to have no type"
    end
  end

  test "looks only at the first 1445 bytes" do
    late = :binary.copy(" ", Magic.window()) <> "<html>"
    assert Magic.detect(late) == nil
  end

  test "matches declared types with their aliases and the types a container holds" do
    assert Magic.matches?("application/vnd.oasis.opendocument.text", "application/zip")
    assert Magic.matches?("application/msword", "application/x-cfb")
    assert Magic.matches?("application/rss+xml", "application/xml")
    assert Magic.matches?("audio/x-wav", "audio/wav")
    assert Magic.matches?("text/xml", "application/xml")
    assert Magic.matches?("application/x-zip-compressed", "application/zip")
    assert Magic.matches?("video/mp4", "audio/mp4")
    assert Magic.normalize("text/xml") == "application/xml"
    refute Magic.matches?("application/zip", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    refute Magic.matches?("text/plain", "text/html")
  end

  test "knows which types always have a signature" do
    assert Magic.signature?("image/jpg")
    assert Magic.signature?("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    refute Magic.signature?("text/html")
    refute Magic.signature?("image/svg+xml")
    refute Magic.signature?("application/json")
  end
end
