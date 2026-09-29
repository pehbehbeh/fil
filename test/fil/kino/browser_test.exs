defmodule Fil.Kino.BrowserTest do
  use ExUnit.Case, async: true

  import Kino.Test

  setup :configure_livebook_bridge

  setup do
    Fil.Adapter.Memory.checkout()

    {:ok, disk: Fil.disk(adapter: Fil.Adapter.Memory)}
  end

  describe "listing" do
    test "lists the root on connect, directories first", %{disk: disk} do
      Fil.write!(disk, "b.txt", "b")
      Fil.write!(disk, "a.txt", "a")
      Fil.write!(disk, "reports/q3.pdf", "%PDF")

      browser = Fil.Kino.browser(disk)

      assert %{label: "memory", path: ".", error: nil, more: 0, entries: entries} = connect(browser)
      assert Enum.map(entries, & &1.name) == ["reports", "a.txt", "b.txt"]

      assert [
               %{type: "directory", path: "reports", content_type: nil, previewable: false},
               %{type: "file", path: "a.txt", size: 1, content_type: "text/plain", previewable: true, mtime: mtime}
               | _rest
             ] = entries

      assert {:ok, _datetime, 0} = DateTime.from_iso8601(mtime)
    end

    test "starts at a path, or at a ref", %{disk: disk} do
      Fil.write!(disk, "reports/q3.pdf", "%PDF")

      assert %{path: "reports", entries: [%{name: "q3.pdf"}]} = connect(Fil.Kino.browser(disk, "reports"))

      reports = Fil.ref(disk, "reports")
      assert %{path: "reports", entries: [%{name: "q3.pdf"}]} = connect(Fil.Kino.browser(reports))
    end

    test "opens a directory, and a missing one lists empty", %{disk: disk} do
      Fil.write!(disk, "reports/2026/q3.pdf", "%PDF")
      browser = Fil.Kino.browser(disk)
      connect(browser)

      push_event(browser, "open", %{"path" => "reports"})
      assert_broadcast_event(browser, "listing", %{path: "reports", entries: [%{name: "2026", type: "directory"}]})

      push_event(browser, "open", %{"path" => "nope"})
      assert_broadcast_event(browser, "listing", %{path: "nope", entries: []})
    end

    test "shows a path that climbs out of the root as an error, and keeps working", %{disk: disk} do
      browser = Fil.Kino.browser(disk)
      connect(browser)

      push_event(browser, "open", %{"path" => "../x"})
      assert_send_event(browser, "error", %{message: message})
      assert message =~ "../x"

      push_event(browser, "refresh", %{})
      assert_broadcast_event(browser, "listing", %{path: ".", entries: []})
    end

    test "refresh shows files written after connect", %{disk: disk} do
      browser = Fil.Kino.browser(disk)
      assert %{entries: []} = connect(browser)

      Fil.write!(disk, "new.txt", "new")

      push_event(browser, "refresh", %{})
      assert_broadcast_event(browser, "listing", %{entries: [%{name: "new.txt"}]})
    end

    test "shows at most 1,000 entries", %{disk: disk} do
      for i <- 1..1003, do: Fil.write!(disk, "f#{i}.txt", "")

      assert %{entries: entries, more: 3} = connect(Fil.Kino.browser(disk))
      assert length(entries) == 1000
    end
  end

  describe "preview" do
    test "sends text as text and images as a binary", %{disk: disk} do
      Fil.write!(disk, "notes.md", "# Notes")
      Fil.write!(disk, "data.bin", "no type, but text")
      Fil.write!(disk, "logo.png", <<137, 80, 78, 71>>)
      browser = Fil.Kino.browser(disk)
      connect(browser)

      push_event(browser, "preview", %{"path" => "notes.md"})
      assert_send_event(browser, "preview", %{path: "notes.md", kind: "text", text: "# Notes"})

      push_event(browser, "preview", %{"path" => "data.bin"})
      assert_send_event(browser, "preview", %{path: "data.bin", kind: "text", text: "no type, but text"})

      push_event(browser, "preview", %{"path" => "logo.png"})

      assert_send_event(
        browser,
        "preview_image",
        {:binary, %{path: "logo.png", type: "image/png"}, <<137, 80, 78, 71>>}
      )
    end

    test "has no preview for text that isn't valid UTF-8", %{disk: disk} do
      Fil.write!(disk, "latin1.txt", <<"caf", 0xE9>>)
      browser = Fil.Kino.browser(disk)
      connect(browser)

      push_event(browser, "preview", %{"path" => "latin1.txt"})
      assert_send_event(browser, "preview", %{path: "latin1.txt", kind: "none"})
    end

    test "doesn't read a file the listing has no size for", %{disk: disk} do
      Fil.write!(disk, "a.txt", "a")

      browser =
        disk
        |> notify_reads()
        |> drop_sizes()
        |> Fil.Kino.browser()

      assert %{entries: [%{size: nil, previewable: false, downloadable: false}]} = connect(browser)

      push_event(browser, "preview", %{"path" => "a.txt"})
      assert_send_event(browser, "error", %{message: "the size of a.txt is unknown"})

      push_event(browser, "download", %{"path" => "a.txt"})
      assert_send_event(browser, "error", %{message: "the size of a.txt is unknown"})
      refute_received {:read, _path}
    end

    test "has no preview for binary files", %{disk: disk} do
      Fil.write!(disk, "archive.zip", <<80, 75, 0, 0, 255>>)
      browser = Fil.Kino.browser(disk)
      connect(browser)

      push_event(browser, "preview", %{"path" => "archive.zip"})
      assert_send_event(browser, "preview", %{path: "archive.zip", kind: "none"})
    end

    test "doesn't read a file over max_preview_size", %{disk: disk} do
      Fil.write!(disk, "big.txt", "12345")

      browser =
        disk
        |> notify_reads()
        |> Fil.Kino.browser(".", max_preview_size: 4)

      assert %{entries: [%{previewable: false, downloadable: true}]} = connect(browser)

      push_event(browser, "preview", %{"path" => "big.txt"})
      assert_send_event(browser, "error", %{message: "big.txt is too large to preview"})
      refute_received {:read, _path}
    end

    test "refuses paths that aren't files of the current listing", %{disk: disk} do
      Fil.write!(disk, "secret/key.txt", "key")

      browser =
        disk
        |> notify_reads()
        |> Fil.Kino.browser()

      connect(browser)

      push_event(browser, "preview", %{"path" => "secret/key.txt"})
      assert_send_event(browser, "error", %{message: "secret/key.txt is not in the current listing" <> _rest})

      push_event(browser, "preview", %{"path" => "secret"})
      assert_send_event(browser, "error", %{message: "secret is a directory"})

      push_event(browser, "download", %{"path" => "secret/key.txt"})
      assert_send_event(browser, "error", %{message: "secret/key.txt is not in the current listing" <> _rest})

      refute_received {:read, _path}
    end
  end

  describe "download" do
    test "sends the content as a binary", %{disk: disk} do
      Fil.write!(disk, "reports/q3.pdf", "%PDF")
      browser = Fil.Kino.browser(disk, "reports")
      connect(browser)

      push_event(browser, "download", %{"path" => "reports/q3.pdf"})
      assert_send_event(browser, "download", {:binary, %{name: "q3.pdf"}, "%PDF"})
    end

    test "doesn't read a file over max_download_size", %{disk: disk} do
      Fil.write!(disk, "big.bin", "12345")

      browser =
        disk
        |> notify_reads()
        |> Fil.Kino.browser(".", max_download_size: 4)

      assert %{entries: [%{downloadable: false}]} = connect(browser)

      push_event(browser, "download", %{"path" => "big.bin"})
      assert_send_event(browser, "error", %{message: "big.bin is too large to download here"})
      refute_received {:read, _path}
    end
  end

  describe "errors" do
    test "shows a storage error and keeps working", %{disk: disk} do
      Fil.write!(disk, "a.txt", "a")

      failing =
        Fil.attach(disk, :unavailable, fn
          %{name: :read} = op, _next, _opts -> Fil.Op.put_result(op, {:error, %Fil.UnavailableError{reason: :timeout}})
          op, next, _opts -> next.(op)
        end)

      browser = Fil.Kino.browser(failing)
      connect(browser)

      push_event(browser, "preview", %{"path" => "a.txt"})
      assert_send_event(browser, "error", %{message: message})
      assert message =~ "unavailable"

      push_event(browser, "refresh", %{})
      assert_broadcast_event(browser, "listing", %{entries: [%{name: "a.txt"}]})
    end

    test "shows a failed listing on connect", %{disk: disk} do
      failing =
        Fil.attach(disk, :unavailable, fn op, _next, _opts ->
          Fil.Op.put_result(op, {:error, %Fil.UnavailableError{reason: :timeout}})
        end)

      assert %{entries: [], error: message} = connect(Fil.Kino.browser(failing))
      assert message =~ "unavailable"
    end

    test "shows an exception instead of crashing", %{disk: disk} do
      # Another process has no memory store, so listing in it raises.
      browser = Task.async(fn -> Fil.Kino.browser(disk) end) |> Task.await()

      assert %{error: message} = connect(browser)
      assert message =~ "has no Fil.Adapter.Memory store"
      assert Process.alive?(browser.pid)
    end

    test "ignores unknown events", %{disk: disk} do
      browser = Fil.Kino.browser(disk)
      connect(browser)

      push_event(browser, "delete", %{"path" => "a.txt"})
      push_event(browser, "open", %{"path" => 1})
      push_event(browser, "refresh", %{})

      assert_broadcast_event(browser, "listing", %{entries: []})
    end
  end

  test "bad options raise ArgumentError", %{disk: disk} do
    assert_raise ArgumentError, ~r/max_preview_size/, fn -> Fil.Kino.browser(disk, ".", max_preview_size: 0) end
    assert_raise ArgumentError, ~r/unknown options \[:writable\]/, fn -> Fil.Kino.browser(disk, ".", writable: true) end
  end

  # Lists every file without a size, as a storage might that doesn't report one.
  defp drop_sizes(disk) do
    Fil.attach(disk, :drop_sizes, fn op, next, _opts ->
      case next.(op) do
        %{name: :ls, result: {:ok, refs}} = op ->
          Fil.Op.put_result(op, {:ok, Enum.map(refs, &put_in(&1.stat.size, nil))})

        op ->
          op
      end
    end)
  end

  # Tells the test process about every read, so a test can check that nothing was read.
  defp notify_reads(disk) do
    test = self()

    Fil.attach(disk, :notify_reads, fn op, next, _opts ->
      if op.name == :read, do: send(test, {:read, op.path})
      next.(op)
    end)
  end
end
