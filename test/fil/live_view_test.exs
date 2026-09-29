defmodule Fil.LiveViewTest do
  alias Fil.Plugin.URL
  alias Phoenix.LiveView.UploadEntry

  use ExUnit.Case, async: true, parameterize: Fil.DiskHelper.adapters()

  import Fil.LiveViewHelper
  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  @endpoint Fil.LiveViewTest.Endpoint

  @base_url "http://localhost/storage"

  # The memory disk needs no `allow/2`: the LiveView process finds the test's store through `$callers`.
  setup context do
    {:ok, disk: Fil.DiskHelper.disk(context)}
  end

  describe "consume_uploaded_entries/4" do
    test "writes a file at filename/1", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk)

      assert {:ok, [avatar]} = upload([%{name: "Me.PNG", content: "png"}], [accept: ~w(.png)], consume)

      assert avatar.path =~ ~r/\A[0-9a-f-]{36}\.png\z/
      assert Fil.read(avatar) == {:ok, "png"}
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
  end

  describe "direct uploads" do
    setup %{disk: disk} do
      {:ok, disk: URL.attach(disk, base_url: @base_url, secret: "secret")}
    end

    test "consume the file the browser uploaded through Fil.Plug", %{disk: disk} do
      view = mount_direct(disk, [accept: ~w(.png)], &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk))
      meta = select_direct(view, %{name: "Me.PNG", content: "png"})

      assert put_direct(meta, "png", disk).status == 200

      assert {:ok, [avatar]} = submit(view)
      assert avatar.path == meta.path
      assert Fil.read(avatar) == {:ok, "png"}

      # The URL writes once.
      assert put_direct(meta, "new", disk).status == 409
      assert Fil.read(avatar) == {:ok, "png"}
    end

    test "a refused extension is an upload error, and nothing is signed", %{disk: disk} do
      view = mount_upload([accept: ~w(.png), external: Fil.LiveView.external(disk)], fn _socket -> :unused end)
      input = file_input(view, "#form", :avatar, [%{name: "evil.html", content: "<html>", type: "image/png"}])

      assert {:error, [[ref, %{reason: :extension}]]} = render_upload(input, "evil.html")

      assert view
             |> element("#errors-#{ref}")
             |> render() =~ inspect([{:external_metadata_failure, %{reason: :extension}}])
    end

    test "a file that wasn't uploaded is a Fil.NotFoundError, and the entry stays", %{disk: disk} do
      view = mount_direct(disk, [accept: ~w(.png)], &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk))
      meta = select_direct(view, %{name: "a.png", content: "png"})

      assert {:error, %Fil.NotFoundError{op: :stat}} = submit(view)

      assert put_direct(meta, "png", disk).status == 200
      assert {:ok, [%Fil.Ref{}]} = submit(view)
    end

    test "a failed consume doesn't delete the files the browser uploaded", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk)
      view = mount_direct(disk, [accept: ~w(.png), max_entries: 2], consume)
      [first, _second] = select_direct(view, [%{name: "a.png", content: "png"}, %{name: "b.png", content: "png"}])

      assert put_direct(first, "png", disk).status == 200

      assert {:error, %Fil.NotFoundError{}} = submit(view)
      assert Fil.read(disk, first.path) == {:ok, "png"}
    end

    test "a file larger than max_file_size is refused and kept", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk)
      view = mount_direct(disk, [accept: ~w(.png), max_file_size: 3], consume)
      meta = select_direct(view, %{name: "a.png", content: "png"})

      # Something else wrote to the path, since the URL takes only 3 bytes. It may be someone else's file, so the
      # consume leaves it alone.
      Fil.write!(disk, meta.path, "larger")

      assert {:error, %Fil.InvalidRequestError{reason: :too_large, op: :stat, path: path, disk: ^disk}} = submit(view)
      assert path == meta.path
      assert Fil.read(disk, meta.path) == {:ok, "larger"}
    end

    test "store_entry/4 checks the file with :max_file_size", %{disk: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.png"}
      meta = direct_meta("avatars/a.png")
      Fil.write!(disk, "avatars/a.png", "png")

      assert {:ok, %Fil.Ref{path: "avatars/a.png"}} = Fil.LiveView.store_entry(disk, meta, entry)
      assert {:ok, %Fil.Ref{path: "avatars/a.png"}} = Fil.LiveView.store_entry(disk, meta, entry, max_file_size: 3)

      # The meta's path is relative to the disk root, whatever the target.
      other = Fil.ref(disk, "other")

      assert {:error, %Fil.InvalidRequestError{reason: :too_large}} =
               Fil.LiveView.store_entry(other, meta, entry, max_file_size: 2)

      assert Fil.exists?(disk, "avatars/a.png")
    end

    test "store_entry/4 refuses a file older than the upload URL", %{disk: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.png"}
      Fil.write!(disk, "a.png", "png")
      now = System.os_time(:second)

      # A URL signed within the allowance for clock differences takes the file, one signed later doesn't.
      assert {:ok, %Fil.Ref{}} = Fil.LiveView.store_entry(disk, direct_meta("a.png", now + 20), entry)

      assert {:error, %Fil.AlreadyExistsError{reason: :before_upload, op: :stat, path: "a.png", disk: ^disk}} =
               Fil.LiveView.store_entry(disk, direct_meta("a.png", now + 60), entry)

      assert Fil.read(disk, "a.png") == {:ok, "png"}
    end

    test "store_entry/4 refuses a directory", %{disk: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.png"}
      Fil.write!(disk, "avatars/a.png", "png")

      for opts <- [[], [max_file_size: 3]] do
        assert {:error, %Fil.NotFoundError{reason: :eisdir, op: :stat, path: "avatars"}} =
                 Fil.LiveView.store_entry(disk, direct_meta("avatars"), entry, opts)
      end

      assert Fil.read(disk, "avatars/a.png") == {:ok, "png"}
    end
  end
end

defmodule Fil.LiveViewTest.OneDisk do
  alias Fil.Plugin.URL
  alias Phoenix.LiveView.UploadEntry

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Fil.LiveViewHelper

  @base_url "http://localhost/storage"

  @empty_list """
  <?xml version="1.0" encoding="UTF-8"?>
  <ListBucketResult><KeyCount>0</KeyCount><IsTruncated>false</IsTruncated></ListBucketResult>
  """

  setup do
    Fil.Adapter.Memory.checkout()
    {:ok, disk: Fil.disk(adapter: Fil.Adapter.Memory)}
  end

  test "stores the content type of the path, consumed or uploaded directly", %{disk: disk} do
    consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk)

    assert {:ok, [avatar]} = upload([%{name: "Me.PNG", content: "png"}], [accept: ~w(.png)], consume)
    assert {:ok, %Fil.Stat{content_type: "image/png"}} = Fil.stat(avatar)

    signing = URL.attach(disk, base_url: @base_url, secret: "secret")
    view = mount_direct(signing, [accept: ~w(.png)], &Fil.LiveView.consume_uploaded_entries(&1, :avatar, signing))
    meta = select_direct(view, %{name: "Me.PNG", content: "png"})

    assert put_direct(meta, "png", signing).status == 200
    assert {:ok, [direct]} = submit(view)
    assert {:ok, %Fil.Stat{content_type: "image/png"}} = Fil.stat(direct)
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

  describe "option errors" do
    test "raises for bad options before writing anything", %{disk: disk} do
      consume = &Fil.LiveView.consume_uploaded_entries(&1, :avatar, disk, if_exists: :append)

      assert {:raised, %NimbleOptions.ValidationError{}} = upload(files(["a.txt"]), [accept: :any], consume)
      assert Fil.ls(disk, ".") == {:ok, []}
    end

    test "raises for an upload that isn't allowed", %{disk: disk} do
      view = mount_upload([accept: :any], &Fil.LiveView.consume_uploaded_entries(&1, :photos, disk))

      assert {:raised, %ArgumentError{message: "no upload allowed for :photos"}} = submit(view)
    end

    test "raises for a meta without a path", %{disk: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.txt"}

      # The meta of another external uploader.
      assert_raise ArgumentError, ~r/Other external uploads \(external: in allow_upload\/3\)/, fn ->
        Fil.LiveView.store_entry(disk, %{uploader: "S3", url: "https://example.com"}, entry)
      end
    end
  end

  describe "external/2" do
    setup %{disk: disk} do
      {:ok, signing: URL.attach(disk, base_url: @base_url, secret: "secret")}
    end

    test "signs an upload URL bound to the file", %{signing: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "Me.PNG", client_size: 3, upload_config: :avatar}

      assert {:ok, meta, _socket} = Fil.LiveView.external(disk).(entry, socket(accept: ~w(.png)))

      assert %{uploader: "Fil", path: "0b2e8b8e.png", url: url, signed_at: signed_at} = meta
      assert_in_delta signed_at, System.os_time(:second), 5
      assert meta.headers == %{"content-type" => "image/png", "if-none-match" => "*"}

      %URI{path: path, query: query} = URI.parse(url)
      assert path == "/storage/0b2e8b8e.png"
      assert URL.verify("secret", :put, path, query) == :ok

      assert %{"content_type" => "image/png", "size" => "3", "if_exists" => "error", "expires" => expires} =
               URI.decode_query(query)

      assert_in_delta String.to_integer(expires), System.os_time(:second) + 300, 5
    end

    test "leaves if-none-match out with if_exists: :overwrite", %{signing: disk} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.png", client_size: 3, upload_config: :avatar}

      assert {:ok, meta, _socket} = Fil.LiveView.external(disk, if_exists: :overwrite).(entry, socket())

      assert meta.headers == %{"content-type" => "image/png"}
      refute meta.url =~ "if_exists"
    end

    test "presigns a PUT on S3, at the public endpoint", %{disk: _disk} do
      disk =
        Fil.disk(
          adapter: Fil.Adapter.S3,
          bucket: "bucket",
          access_key_id: "AKIDEXAMPLE",
          secret_access_key: "secret",
          endpoint: "http://s3:9000",
          public_endpoint: "http://localhost:9000",
          path_style: true
        )

      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.png", client_size: 3, upload_config: :avatar}
      external = Fil.LiveView.external(disk, path: &"avatars/#{&1.uuid}.png", expires_in: 60)

      assert {:ok, meta, _socket} = external.(entry, socket())
      assert "http://localhost:9000/bucket/avatars/0b2e8b8e.png?" <> query = meta.url

      query = URI.decode_query(query)
      assert query["X-Amz-Expires"] == "60"
      assert query["X-Amz-SignedHeaders"] == "content-length;content-type;host;if-none-match"
      assert meta.path == "avatars/0b2e8b8e.png"
    end

    test "gives the error meta for a refused extension or a disk that can't sign", %{disk: disk, signing: signing} do
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "evil.html", client_size: 3, upload_config: :avatar}

      # LiveView sends the meta to the browser, so it has a reason, and the message, which names the disk and the path,
      # goes to the log. A refused extension comes from the user's file and isn't logged.
      signed = Fil.LiveView.external(signing)
      assert {{:error, meta, _socket}, log} = with_log(fn -> signed.(entry, socket(accept: ~w(.png))) end)
      assert meta == %{reason: :extension}
      # The log of an async test has the other tests' messages too, so only this one's are checked.
      refute log =~ "Fil.LiveView.external/2"

      unsigned = Fil.LiveView.external(disk)
      png = %{entry | client_name: "a.png"}
      assert {{:error, error_meta, _socket}, log} = with_log(fn -> unsigned.(png, socket(accept: ~w(.png))) end)
      assert error_meta == %{reason: :error}
      assert log =~ "Fil.LiveView.external/2: "
      assert log =~ "0b2e8b8e.png"
    end

    test "raises for bad options", %{disk: disk} do
      assert_raise NimbleOptions.ValidationError, fn -> Fil.LiveView.external(disk, expires_in: 0) end
      assert_raise NimbleOptions.ValidationError, fn -> Fil.LiveView.external(disk, max_file_size: 1) end
    end
  end

  describe "store_entry/4 of a direct upload" do
    @tag :tmp_dir
    test "store_entry/4 refuses a file older than the upload URL on a local disk", %{tmp_dir: tmp_dir} do
      disk = Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)
      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.png"}
      Fil.write!(disk, "a.png", "png")

      assert {:ok, %Fil.Ref{}} = Fil.LiveView.store_entry(disk, direct_meta("a.png"), entry)

      # Someone else's file from an hour ago, at a path a modified client claims it uploaded to.
      tmp_dir
      |> Path.join("a.png")
      |> File.touch!(System.os_time(:second) - 3600)

      assert {:error, %Fil.AlreadyExistsError{reason: :before_upload}} =
               Fil.LiveView.store_entry(disk, direct_meta("a.png"), entry)

      assert Fil.read(disk, "a.png") == {:ok, "png"}
    end

    test "store_entry/4 stats the file on S3" do
      disk =
        Fil.disk(
          adapter: Fil.Adapter.S3,
          bucket: "bucket",
          access_key_id: "AKIDEXAMPLE",
          secret_access_key: "secret",
          req_options: [plug: {Req.Test, __MODULE__}]
        )

      entry = %UploadEntry{uuid: "0b2e8b8e", client_name: "a.png"}
      meta = direct_meta("avatars/a.png")
      test = self()

      Req.Test.expect(__MODULE__, fn conn ->
        send(test, {:request, conn.method, conn.request_path})
        s3_head(conn, DateTime.utc_now())
      end)

      assert {:ok, %Fil.Ref{path: "avatars/a.png"}} = Fil.LiveView.store_entry(disk, meta, entry, max_file_size: 3)
      assert_received {:request, "HEAD", "/avatars/a.png"}

      # An object from an hour before the URL.
      Req.Test.expect(__MODULE__, &s3_head(&1, ~U[2026-09-30 10:00:00Z]))
      old = direct_meta("avatars/a.png", DateTime.to_unix(~U[2026-09-30 11:00:00Z]))
      assert {:error, %Fil.AlreadyExistsError{reason: :before_upload}} = Fil.LiveView.store_entry(disk, old, entry)

      Req.Test.expect(__MODULE__, 2, fn
        %{method: "HEAD"} = conn -> Plug.Conn.send_resp(conn, 404, "")
        conn -> Plug.Conn.send_resp(conn, 200, @empty_list)
      end)

      assert {:error, %Fil.NotFoundError{}} = Fil.LiveView.store_entry(disk, meta, entry)
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

  # Answers a HEAD for an object of 3 bytes last modified at `datetime`.
  defp s3_head(conn, datetime) do
    conn
    |> Plug.Conn.put_resp_header("content-length", "3")
    |> Plug.Conn.put_resp_header("last-modified", Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT"))
    |> Plug.Conn.send_resp(200, "")
  end
end
