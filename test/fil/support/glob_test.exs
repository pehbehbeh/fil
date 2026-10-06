defmodule Fil.Support.GlobTest do
  use ExUnit.Case, async: true

  @files ~w(
    media/a/withText/x.mp4
    media/a/withoutText/y.mp4
    media/a/other/z.mp4
    media/b/withText/q.mp4
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

  defp glob(disk, path \\ ".", pattern) do
    disk
    |> Fil.ls!(path, glob: pattern)
    |> Enum.map(& &1.path)
  end

  test "* and ? match within a name, dotted names included", %{disk: disk} do
    assert glob(disk, "*.txt") == ["top.txt"]
    assert glob(disk, "media/*") == ~w(media/.drafts media/a media/b media/c,d.txt media/c.txt)
    assert glob(disk, "media/?") == ~w(media/a media/b)
    assert glob(disk, "media/*/withText") == ~w(media/.drafts/withText media/a/withText media/b/withText)
  end

  test "braces match one of the alternatives, which may hold wildcards", %{disk: disk} do
    assert glob(disk, "media/a/{withText,withoutText}") == ~w(media/a/withText media/a/withoutText)
    assert glob(disk, "media/a/{with*,oth?r}") == ~w(media/a/other media/a/withText media/a/withoutText)
  end

  test "a comma or a closing brace outside braces is a plain character", %{disk: disk} do
    assert glob(disk, "media/c,d.txt") == ["media/c,d.txt"]
    assert glob(disk, "media/c,*") == ["media/c,d.txt"]
  end

  test "a class matches one of its characters or ranges", %{disk: disk} do
    assert glob(disk, "media/[ab]") == ~w(media/a media/b)
    assert glob(disk, "media/[b-z]*") == ~w(media/b media/c,d.txt media/c.txt)
    assert glob(disk, "media/[.]*") == ["media/.drafts"]
  end

  test "** matches any number of directories, none included", %{disk: disk} do
    assert glob(disk, "**/*.mp4") == ~w(
             media/.drafts/withText/d.mp4
             media/a/other/z.mp4
             media/a/withText/x.mp4
             media/a/withoutText/y.mp4
             media/b/withText/q.mp4
           )

    assert glob(disk, "media/**/withText/*") == ~w(
             media/.drafts/withText/d.mp4
             media/a/withText/x.mp4
             media/b/withText/q.mp4
           )

    assert glob(disk, "**/c.txt") == ["media/c.txt"]
    assert glob(disk, "media/b/**") == ~w(media/b/withText media/b/withText/q.mp4)
  end

  test "the pattern is relative to the listed directory", %{disk: disk} do
    assert glob(disk, "media/a", "*/x.mp4") == ["media/a/withText/x.mp4"]
    assert glob(disk, "/", "media/c.txt") == ["media/c.txt"]
    assert glob(disk, "nothing/here", "*") == []
  end

  test "lists each directory a segment reached once, and nothing for the literal head", %{disk: disk} do
    test = self()

    disk =
      Fil.attach(disk, :spy, fn op, next, _opts ->
        send(test, {:ls, op.path, op.options})
        next.(op)
      end)

    assert ["media/a/withText", "media/b/withText"] = glob(disk, "media/{a,b}/withText")

    assert_received {:ls, "media", [recursive: false]}
    assert_received {:ls, "media/a", [recursive: false]}
    assert_received {:ls, "media/b", [recursive: false]}
    refute_received {:ls, _path, _options}

    assert [_d, _x, _q] = glob(disk, "media/*/withText/**")

    assert_received {:ls, "media", [recursive: false]}
    assert_received {:ls, "media/.drafts/withText", [recursive: true]}
    assert_received {:ls, "media/a/withText", [recursive: true]}
    assert_received {:ls, "media/b/withText", [recursive: true]}
  end

  test "a backslash makes the next character literal", %{disk: disk} do
    Fil.write!(disk, "odd/[draft]*.txt", "x")
    Fil.write!(disk, "odd/d.txt", "x")

    assert glob(disk, "odd/\\[draft\\]\\*.txt") == ["odd/[draft]*.txt"]
    assert glob(disk, "odd/\\[draft]*") == ["odd/[draft]*.txt"]
    assert glob(disk, "\\odd/\\d.txt") == ["odd/d.txt"]
  end

  test "an invalid pattern raises", %{disk: disk} do
    for pattern <- ["", "a//b", "./a", "a/..", "{a,b", "[ab", "a[]b", "{a/b}"] do
      assert_raise ArgumentError, ~r/invalid glob/, fn -> Fil.ls(disk, ".", glob: pattern) end
    end
  end

  test "a glob can't be recursive", %{disk: disk} do
    assert_raise ArgumentError, ~r/use \*\* in the pattern instead/, fn ->
      Fil.ls(disk, ".", glob: "*", recursive: true)
    end
  end

  test "a path outside the disk fails like any listing", %{disk: disk} do
    assert {:error, %Fil.InvalidRequestError{op: :ls, path: "../x"}} = Fil.ls(disk, "../x", glob: "*")
  end
end
