defmodule Fil.Support.WildcardTest do
  use ExUnit.Case, async: true

  @files ~w(
    media/a/withText/x.mp4
    media/a/withoutText/y.mp4
    media/a/other/z.mp4
    media/a/.cache/c.mp4
    media/b/withText/q.mp4
    media/b/.hidden.txt
    media/.drafts/withText/d.mp4
    media/c.txt
    media/c,d.txt
    top.txt
  )

  setup do
    Fil.Adapter.Memory.checkout()
    disk = Fil.disk(adapter: Fil.Adapter.Memory)
    for path <- @files, do: Fil.write!(disk, path, "x")

    {:ok, disk: disk}
  end

  defp wildcard(disk, pattern, opts \\ []) do
    disk
    |> Fil.wildcard!(pattern, opts)
    |> Enum.map(& &1.path)
  end

  test "* and ? match within a name", %{disk: disk} do
    assert wildcard(disk, "*.txt") == ["top.txt"]
    assert wildcard(disk, "media/*") == ~w(media/a media/b media/c,d.txt media/c.txt)
    assert wildcard(disk, "media/?") == ~w(media/a media/b)
    assert wildcard(disk, "media/*/withText") == ~w(media/a/withText media/b/withText)
  end

  test "braces match one of the alternatives, which may hold wildcards", %{disk: disk} do
    assert wildcard(disk, "media/a/{withText,withoutText}") == ~w(media/a/withText media/a/withoutText)
    assert wildcard(disk, "media/a/{with*,oth?r}") == ~w(media/a/other media/a/withText media/a/withoutText)
  end

  test "a comma or a closing brace outside braces is a plain character", %{disk: disk} do
    assert wildcard(disk, "media/c,d.txt") == ["media/c,d.txt"]
    assert wildcard(disk, "media/c,*") == ["media/c,d.txt"]
  end

  test "a class matches one of its characters or ranges", %{disk: disk} do
    assert wildcard(disk, "media/[ab]") == ~w(media/a media/b)
    assert wildcard(disk, "media/[b-z]*") == ~w(media/b media/c,d.txt media/c.txt)
  end

  test "** matches any number of directories, none included", %{disk: disk} do
    assert wildcard(disk, "**/*.mp4") == ~w(
             media/a/other/z.mp4
             media/a/withText/x.mp4
             media/a/withoutText/y.mp4
             media/b/withText/q.mp4
           )

    assert wildcard(disk, "media/**/withText/*") == ~w(media/a/withText/x.mp4 media/b/withText/q.mp4)
    assert wildcard(disk, "**/c.txt") == ["media/c.txt"]
    assert wildcard(disk, "media/b/**") == ~w(media/b/withText media/b/withText/q.mp4)
    assert wildcard(disk, "media/**/withText/**") == ~w(media/a/withText/x.mp4 media/b/withText/q.mp4)
    assert wildcard(disk, "**/{a,b}/**") == wildcard(disk, "media/{a,b}/**")
  end

  # The same results as `Path.wildcard/2` on the same tree.
  test "names with a leading dot match only the literal start of a pattern", %{disk: disk} do
    assert wildcard(disk, "media/.*") == []
    assert wildcard(disk, "media/{.drafts,a}") == ["media/a"]
    assert wildcard(disk, "media/*/.cache") == []
    assert wildcard(disk, "**/.hidden.txt") == []
    assert wildcard(disk, "media/.drafts/*") == ["media/.drafts/withText"]
    assert wildcard(disk, "media/b/.hidden.txt") == ["media/b/.hidden.txt"]
  end

  test "match_dot: true lets wildcards match them", %{disk: disk} do
    assert wildcard(disk, "media/*", match_dot: true) == ~w(media/.drafts media/a media/b media/c,d.txt media/c.txt)
    assert wildcard(disk, "media/.*", match_dot: true) == ["media/.drafts"]
    assert wildcard(disk, "**/.hidden.txt", match_dot: true) == ["media/b/.hidden.txt"]

    assert wildcard(disk, "media/*/withText", match_dot: true) ==
             ~w(media/.drafts/withText media/a/withText media/b/withText)
  end

  test "a backslash makes the next character literal", %{disk: disk} do
    Fil.write!(disk, "odd/[draft]*.txt", "x")
    Fil.write!(disk, "odd/d.txt", "x")

    assert wildcard(disk, "odd/\\[draft\\]\\*.txt") == ["odd/[draft]*.txt"]
    assert wildcard(disk, "odd/\\[draft]*") == ["odd/[draft]*.txt"]
    assert wildcard(disk, "\\odd/\\d.txt") == ["odd/d.txt"]
  end

  test "the pattern is relative to the disk root", %{disk: disk} do
    assert wildcard(disk, "/media/c.txt") == ["media/c.txt"]
    assert wildcard(disk, "//media/?.txt") == ["media/c.txt"]
    assert wildcard(disk, "media/") == ["media"]
    assert wildcard(disk, "./media//a/./withText/") == ["media/a/withText"]
    assert wildcard(disk, "nothing/here/*") == []
  end

  test "type: picks files or directories", %{disk: disk} do
    assert wildcard(disk, "media/*", type: :regular) == ~w(media/c,d.txt media/c.txt)
    assert wildcard(disk, "media/*", type: :directory) == ~w(media/a media/b)
  end

  test "lists each directory a segment reached once, and nothing for the literal head", %{disk: disk} do
    test = self()

    disk =
      Fil.attach(disk, :spy, fn op, next, _opts ->
        send(test, {:ls, op.path, op.options})
        next.(op)
      end)

    assert ["media/a/withText", "media/b/withText"] = wildcard(disk, "media/{a,b}/withText")

    assert_received {:ls, "media", [recursive: false]}
    assert_received {:ls, "media/a", [recursive: false]}
    assert_received {:ls, "media/b", [recursive: false]}
    refute_received {:ls, _path, _options}

    assert [_x, _q] = wildcard(disk, "media/*/withText/**")

    assert_received {:ls, "media", [recursive: false]}
    assert_received {:ls, "media/a", [recursive: false]}
    assert_received {:ls, "media/b", [recursive: false]}
    assert_received {:ls, "media/a/withText", [recursive: true]}
    assert_received {:ls, "media/b/withText", [recursive: true]}
    refute_received {:ls, _path, _options}
  end

  test "a failed listing is the result", %{disk: disk} do
    disk =
      Fil.attach(disk, :fail, fn
        %{name: :ls, path: "media/b"} = op, _next, _opts -> %{op | result: {:error, %Fil.UnavailableError{}}}
        op, next, _opts -> next.(op)
      end)

    assert {:error, %Fil.UnavailableError{op: :ls, path: "media/b"}} = Fil.wildcard(disk, "media/*/withText")
  end

  test "an invalid pattern raises", %{disk: disk} do
    for pattern <- ["", "/", "./", "a/..", "../*", "{a,b", "[ab", "a[]b", "{a/b}"] do
      assert_raise ArgumentError, ~r/invalid pattern/, fn -> Fil.wildcard(disk, pattern) end
    end
  end
end
