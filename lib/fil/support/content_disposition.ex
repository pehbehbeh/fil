defmodule Fil.Support.ContentDisposition do
  @moduledoc false

  # The `content-disposition` header for `disposition:` on `Fil.signed_url/3`, built once in `Fil` so every adapter
  # sends the same value.

  @doc """
  Builds the header value for a disposition and the basename of the file.

  A filename that isn't plain ASCII gets an ASCII `filename=` for old clients and the exact name in `filename*=`
  (RFC 6266), which every current browser prefers.

      iex> Fil.Support.ContentDisposition.header(:inline, "cv.pdf")
      "inline"

      iex> Fil.Support.ContentDisposition.header(:attachment, "cv.pdf")
      ~s(attachment; filename="cv.pdf")

      iex> Fil.Support.ContentDisposition.header({:attachment, "Lebenslauf Müller.pdf"}, "cv.pdf")
      ~s(attachment; filename="Lebenslauf M_ller.pdf"; filename*=UTF-8''Lebenslauf%20M%C3%BCller.pdf)

      iex> Fil.Support.ContentDisposition.header({:attachment, ~s(say "hi".txt)}, "cv.pdf")
      ~s(attachment; filename="say _hi_.txt"; filename*=UTF-8''say%20%22hi%22.txt)

  Bytes that aren't UTF-8 (a Latin-1 name from an old database, say) become `U+FFFD`, so the name keeps its extension.
  Without a basename (the disk root), the browser picks the name:

      iex> Fil.Support.ContentDisposition.header({:attachment, <<"M", 0xE4, "rz.pdf">>}, "cv.pdf")
      ~s(attachment; filename="M_rz.pdf"; filename*=UTF-8''M%EF%BF%BDrz.pdf)

      iex> Fil.Support.ContentDisposition.header(:attachment, ".")
      "attachment"

  """
  @spec header(:inline | :attachment | {:attachment, String.t()}, String.t()) :: String.t()
  def header(:inline, _basename), do: "inline"
  def header(:attachment, basename) when basename in ["", ".", ".."], do: "attachment"
  def header(:attachment, basename), do: header({:attachment, basename}, basename)

  def header({:attachment, filename}, _basename) do
    filename = String.replace_invalid(filename)
    fallback = ascii_fallback(filename)

    if fallback == filename do
      ~s(attachment; filename="#{filename}")
    else
      ~s(attachment; filename="#{fallback}"; filename*=UTF-8''#{URI.encode(filename, &attr_char?/1)})
    end
  end

  # Quotes and backslashes would need escaping inside the quoted string, which clients handle inconsistently, and some
  # decode `%` escapes in `filename=`. They're replaced like non-ASCII characters, and `filename*=` keeps them.
  defp ascii_fallback(filename) do
    for <<char::utf8 <- filename>>, into: "" do
      if char in 0x20..0x7E and char not in [?", ?\\, ?%], do: <<char>>, else: "_"
    end
  end

  # `attr-char` from RFC 8187: everything else is percent-encoded.
  defp attr_char?(char), do: char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in ~c"!#$&+-.^_`|~"
end
