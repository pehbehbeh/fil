defmodule Fil.LiveViewTest do
  alias Fil.LiveViewTest.UploadLive
  alias Phoenix.LiveView.UploadEntry

  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Fil.LiveViewTest.Endpoint

  # The memory disk needs no `allow/2`: the LiveView process finds the test's store through `$callers`.
  setup do
    Fil.Adapter.Memory.checkout()
    {:ok, disk: Fil.disk(adapter: Fil.Adapter.Memory)}
  end

  # Mounts `UploadLive` with the upload options, and a function the "save" event calls with the socket.
  defp mount_upload(allow, consume) do
    config = %{test: self(), name: :avatar, allow: allow, consume: consume}
    agent = start_supervised!({Agent, fn -> config end}, id: make_ref())
    {:ok, view, _html} = live_isolated(build_conn(), UploadLive, session: %{"config" => agent})
    view
  end

  # Uploads the files through the channel, submits the form and returns what the consume function returned.
  defp upload(files, allow, consume) do
    view = mount_upload(allow, consume)
    select_and_upload(view, files)
    submit(view)
  end

  defp select_and_upload(view, files) do
    input = file_input(view, "#form", :avatar, Enum.map(files, &file/1))

    for file <- files do
      render_upload(input, file.name)
    end

    input
  end

  defp submit(view) do
    view
    |> element("#form")
    |> render_submit()

    assert_receive {:consumed, result}
    result
  end

  defp file(file), do: Map.put_new(file, :type, MIME.from_path(file.name))

  defp client_name(entry), do: entry.client_name

  defp files(names), do: Enum.map(names, &%{name: &1, content: "content of #{&1}"})

  describe "consume_uploaded_entries/4" do
    test "writes a file at filename/1 with the content type of its path", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk)

      assert {:ok, [avatar]} = upload([%{name: "Me.PNG", content: "png"}], [accept: ~w(.png)], consume)

      assert avatar.path =~ ~r/\A[0-9a-f-]{36}\.png\z/
      assert Fil.read(avatar) == {:ok, "png"}
      assert {:ok, %Fil.Stat{content_type: "image/png"}} = Fil.stat(avatar)
    end

    test "returns the refs in the order of the file input", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk, path: fn entry -> client_name(entry) end)
      names = ~w(c.txt a.txt b.txt)

      assert {:ok, refs} = upload(files(names), [accept: ~w(.txt), max_entries: 3], consume)

      assert Enum.map(refs, & &1.path) == names

      for name <- names do
        assert Fil.read(disk, name) == {:ok, "content of #{name}"}
      end
    end

    test "returns an empty list when nothing was uploaded", %{disk: disk} do
      view = mount_upload([accept: :any], &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk))

      assert submit(view) == {:ok, []}
    end

    test "writes relative to a directory ref", %{disk: disk} do
      target = Fil.ref(disk, "users/1")
      path = &"avatars/#{&1.client_name}"
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, target, path: path)

      assert {:ok, [avatar]} = upload(files(["a.txt"]), [accept: :any], consume)

      assert avatar.path == "users/1/avatars/a.txt"
      assert Fil.read(disk, "users/1/avatars/a.txt") == {:ok, "content of a.txt"}
    end

    test "resolves a disk from an MFA or a function", %{disk: disk} do
      mfa = {Fil, :disk, [[adapter: Fil.Adapter.Memory]]}
      from_mfa = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, mfa, path: fn _entry -> "mfa.txt" end)
      from_fun = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, fn -> disk end, path: fn _entry -> "fun.txt" end)

      assert {:ok, [_ref]} = upload(files(["a.txt"]), [accept: :any], from_mfa)
      assert {:ok, [_ref]} = upload(files(["a.txt"]), [accept: :any], from_fun)

      assert Fil.exists?(disk, "mfa.txt")
      assert Fil.exists?(disk, "fun.txt")
    end

    test "writes where entry_ref/3 said", %{disk: disk} do
      consume = fn socket ->
        [entry] = socket.assigns.uploads.avatar.entries
        expected = Fil.LiveView.entry_ref(disk, entry, path: &"avatars/#{&1.uuid}.txt")

        {expected, Fil.LiveView.consume_uploaded_entries(socket, :avatar, disk, path: &"avatars/#{&1.uuid}.txt")}
      end

      assert {expected, {:ok, [avatar]}} = upload(files(["a.txt"]), [accept: :any], consume)
      assert avatar == expected
    end

    test "refuses an extension that isn't in accept:, even with an accepted type", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk)

      # LiveView accepts the file for its type, which the browser sends.
      assert {:error, %Fil.InvalidRequestError{reason: :extension, op: :write} = error} =
               upload([%{name: "evil.html", content: "<script>", type: "image/png"}], [accept: ~w(.png)], consume)

      assert error.path =~ ~r/\.html\z/
      assert Fil.ls(disk, ".") == {:ok, []}
    end

    test "checks :extensions instead of accept:", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk, extensions: [".txt"])

      assert {:error, %Fil.InvalidRequestError{reason: :extension}} =
               upload([%{name: "a.png", content: "png"}], [accept: ~w(image/*)], consume)

      assert {:ok, [_ref]} =
               upload([%{name: "a.TXT", content: "text", type: "image/png"}], [accept: ~w(image/*)], consume)
    end

    test "allows the extensions of the exact types in accept:, and refuses others", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk)
      accept = [accept: ~w(image/png image/jpeg)]

      assert {:ok, [png]} = upload([%{name: "a.png", content: "png"}], accept, consume)
      assert {:ok, [jpeg]} = upload([%{name: "a.JPEG", content: "jpeg"}], accept, consume)
      assert png.path =~ ~r/\.png\z/
      assert jpeg.path =~ ~r/\.jpeg\z/

      # LiveView accepts the file for the type the browser sends.
      assert {:error, %Fil.InvalidRequestError{reason: :extension}} =
               upload([%{name: "evil.html", content: "<script>", type: "image/png"}], accept, consume)

      assert {:ok, [_png, _jpeg]} = Fil.ls(disk, ".")
    end

    test "refuses files a wildcard accepts in a list with extensions", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk)

      assert {:error, %Fil.InvalidRequestError{reason: :extension}} =
               upload([%{name: "a.png", content: "png"}], [accept: ~w(.pdf image/*)], consume)

      assert {:ok, [_pdf]} = upload([%{name: "a.pdf", content: "pdf"}], [accept: ~w(.pdf image/*)], consume)
    end

    test "checks no extension when accept: has only wildcards", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk)

      assert {:ok, [ref]} =
               upload([%{name: "noext", content: "png", type: "image/png"}], [accept: ~w(image/*)], consume)

      refute ref.path =~ "."
    end

    test "keeps an existing file, deletes the others and keeps the entries", %{disk: disk} do
      Fil.write!(disk, "b.txt", "old")
      view = mount_upload([accept: ~w(.txt), max_entries: 3], &consume_by_name(&1, disk))
      select_and_upload(view, files(~w(a.txt b.txt c.txt)))

      assert {:error, %Fil.AlreadyExistsError{path: "b.txt"}} = submit(view)

      assert Fil.read(disk, "b.txt") == {:ok, "old"}
      refute Fil.exists?(disk, "a.txt")
      refute Fil.exists?(disk, "c.txt")

      # The entries are still in the upload, so the form can be submitted again.
      Fil.rm!(disk, "b.txt")

      assert {:ok, refs} = submit(view)
      assert Enum.map(refs, & &1.path) == ~w(a.txt b.txt c.txt)
      assert Fil.read(disk, "b.txt") == {:ok, "content of b.txt"}
    end

    test "replaces a file with if_exists: :overwrite", %{disk: disk} do
      Fil.write!(disk, "a.txt", "old")
      consume = &consume_by_name(&1, disk, if_exists: :overwrite)

      assert {:ok, [_ref]} = upload(files(["a.txt"]), [accept: :any], consume)
      assert Fil.read(disk, "a.txt") == {:ok, "content of a.txt"}
    end

    test "refuses a path that leaves the disk root", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk, path: fn _entry -> "../escape.txt" end)

      assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = upload(files(["a.txt"]), [accept: :any], consume)
    end

    test "refuses a path that leaves a directory target", %{disk: disk} do
      users = Fil.ref(disk, "users/1")
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, users, path: fn _entry -> "../x.png" end)

      assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = upload(files(["a.png"]), [accept: :any], consume)
      assert Fil.ls(disk, ".", recursive: true) == {:ok, []}
    end

    test "raises for a path that isn't a string, after deleting the files it wrote", %{disk: disk} do
      path = fn entry -> if entry.client_name == "b.txt", do: :nope, else: entry.client_name end

      view =
        mount_upload(
          [accept: :any, max_entries: 2],
          &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk, path: path)
        )

      select_and_upload(view, files(~w(a.txt b.txt)))

      assert {:raised, %ArgumentError{message: message}} = submit(view)
      assert message =~ "expected the :path function to return a string, got: :nope"
      refute Fil.exists?(disk, "a.txt")
    end

    test "raises for bad options before writing anything", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk, if_exists: :append)

      assert {:raised, %NimbleOptions.ValidationError{}} = upload(files(["a.txt"]), [accept: :any], consume)
      assert Fil.ls(disk, ".") == {:ok, []}
    end

    test "raises for an upload that isn't allowed", %{disk: disk} do
      view = mount_upload([accept: :any], &Fil.LiveView.consume_uploaded_entries(&1, :photos, disk))

      assert {:raised, %ArgumentError{message: "no upload allowed for :photos"}} = submit(view)
    end

    test "returns a storage error as it is", %{disk: disk} do
      error = %Fil.UnavailableError{reason: :timeout}

      failing =
        Fil.attach(disk, :unavailable, fn
          %Fil.Op{name: :write} = op, _next, _opts -> Fil.Op.put_result(op, {:error, error})
          op, next, _opts -> next.(op)
        end)

      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, failing)

      assert {:error, %Fil.UnavailableError{reason: :timeout}} = upload(files(["a.txt"]), [accept: :any], consume)
    end

    test "deletes the files it wrote when an upload channel dies", %{disk: disk} do
      # Stops every upload channel once the last file is written, as if the client went away, so consuming the
      # entries afterwards exits.
      consume = fn socket ->
        pids =
          socket.assigns.uploads.avatar.entry_refs_to_pids
          |> Map.values()
          |> Enum.filter(&is_pid/1)

        stopping =
          Fil.attach(disk, :stop_channels, fn
            %Fil.Op{name: :write, path: "b.txt"} = op, next, _opts ->
              op = next.(op)
              Enum.each(pids, &GenServer.stop(&1, {:shutdown, :closed}))
              op

            op, next, _opts ->
              next.(op)
          end)

        consume_by_name(socket, stopping)
      end

      # Both files are written, and consuming the first entry finds its channel gone.
      assert {:exited, {:noproc, {GenServer, :call, [_pid, :consume_start, _timeout]}}} =
               upload(files(~w(a.txt b.txt)), [accept: :any, max_entries: 2], consume)

      refute Fil.exists?(disk, "a.txt")
      refute Fil.exists?(disk, "b.txt")
    end
  end

  describe "consume_uploaded_entry/4" do
    test "stores an entry from a progress callback", %{disk: disk} do
      test = self()

      progress = fn :avatar, entry, socket ->
        if entry.done? do
          send(test, {:stored, Fil.LiveView.consume_uploaded_entry(socket, entry, disk, path: &client_name/1)})
        end

        {:noreply, socket}
      end

      view = mount_upload([accept: :any, auto_upload: true, progress: progress], fn _socket -> :ok end)
      select_and_upload(view, files(["a.txt"]))

      assert_receive {:stored, {:ok, %Fil.Ref{path: "a.txt"}}}
      assert Fil.read(disk, "a.txt") == {:ok, "content of a.txt"}
    end

    test "keeps the entry when the write fails", %{disk: disk} do
      Fil.write!(disk, "a.txt", "old")

      consume = fn socket ->
        [entry] = socket.assigns.uploads.avatar.entries
        result = Fil.LiveView.consume_uploaded_entry(socket, entry, disk, path: &client_name/1)
        Fil.rm!(disk, "a.txt")
        {result, Fil.LiveView.consume_uploaded_entry(socket, entry, disk, path: &client_name/1)}
      end

      assert {{:error, %Fil.AlreadyExistsError{}}, {:ok, %Fil.Ref{path: "a.txt"}}} =
               upload(files(["a.txt"]), [accept: :any], consume)
    end
  end

  describe "store_entry/4" do
    test "stores entries in LiveView's own consume_uploaded_entries/3", %{disk: disk} do
      consume = fn socket ->
        Phoenix.LiveView.consume_uploaded_entries(socket, :avatar, fn meta, entry ->
          case Fil.LiveView.store_entry(disk, meta, entry, path: &client_name/1, extensions: [".txt"]) do
            {:ok, ref} -> {:ok, ref.path}
            {:error, error} -> {:postpone, error}
          end
        end)
      end

      assert upload(files(["a.txt"]), [accept: :any], consume) == ["a.txt"]

      assert [%Fil.InvalidRequestError{reason: :extension}] =
               upload([%{name: "a.png", content: "png"}], [accept: :any], consume)
    end

    test "raises for a meta without a path", %{disk: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.txt"}

      assert_raise ArgumentError, ~r/expected the meta of LiveView's default upload writer/, fn ->
        Fil.LiveView.store_entry(disk, %{key: "a"}, entry)
      end
    end
  end

  describe "entry_ref/3" do
    test "builds the ref without writing", %{disk: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.PNG"}

      assert Fil.LiveView.entry_ref(disk, entry) == Fil.ref(disk, "0b2e8b8e.png")
      avatars = Fil.ref(disk, "avatars")

      assert Fil.LiveView.entry_ref(avatars, entry).path == "avatars/0b2e8b8e.png"
      refute Fil.exists?(disk, "0b2e8b8e.png")
    end

    test "keeps the path inside a directory target", %{disk: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.png"}
      users = Fil.ref(disk, "users/1")

      assert Fil.LiveView.entry_ref(users, entry, path: fn _entry -> "a/../b.png" end).path == "users/1/b.png"

      # A path that leaves the directory would leave the disk root on its own, so using the ref fails.
      escape = Fil.LiveView.entry_ref(users, entry, path: fn _entry -> "../../x2.png" end)

      assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.write(escape, "png")
      refute Fil.exists?(disk, "x2.png")
    end

    test "raises for bad options", %{disk: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.png"}

      assert_raise NimbleOptions.ValidationError, fn -> Fil.LiveView.entry_ref(disk, entry, extensions: ".png") end
    end
  end

  defp consume_by_name(socket, disk, opts \\ []) do
    Fil.LiveView.consume_uploaded_entries(socket, :avatar, disk, [path: &client_name/1] ++ opts)
  end
end
