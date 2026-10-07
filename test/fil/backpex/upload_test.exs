defmodule Fil.Backpex.UploadTest.Repo do
  use Ecto.Repo, otp_app: :fil, adapter: Ecto.Adapters.SQLite3
end

defmodule Fil.Backpex.UploadTest.Migration do
  use Ecto.Migration

  def change do
    create table(:products) do
      add(:name, :text)
      add(:avatar, :text)
      add(:photos, {:array, :string}, null: false, default: [])
      add(:docs, {:array, :string}, null: false, default: [])
      add(:logo, :text)
    end
  end
end

defmodule Fil.Backpex.UploadTest do
  alias Fil.Backpex.UploadTest.Migration
  alias Fil.Backpex.UploadTest.Repo
  alias Fil.BackpexTest.Product
  alias Fil.BackpexTest.ProductLive
  alias Fil.BackpexTest.Storage

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Fil.BackpexTest.Endpoint

  # A repo per test, in memory. The LiveView finds it through the session and `Fil.BackpexTest.Hooks`.
  setup do
    Fil.Adapter.Memory.checkout()
    repo = start_supervised!({Repo, name: nil, database: ":memory:", pool_size: 1, log: false})
    Repo.put_dynamic_repo(repo)
    :ok = Ecto.Migrator.up(Repo, 1, Migration, log: false)

    conn = Plug.Test.init_test_session(build_conn(), %{"repo" => repo})
    {:ok, conn: conn, disk: Storage.uploads()}
  end

  defp field(name, options) do
    options = Map.merge(%{module: Fil.Backpex.Upload, label: "Files"}, options)
    config = Fil.Backpex.Upload.validate_config!({name, options}, ProductLive)
    {name, Map.new(config)}
  end

  # The socket of the form component, as Backpex passes it to the field.
  defp form_socket(assigns \\ %{}) do
    assigns = Map.merge(%{item: %Product{}, live_resource: ProductLive}, assigns)
    Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, assigns)
  end

  # The upload the field allows, which raises for invalid options.
  defp allowed(name, options, socket \\ form_socket()) do
    field = field(name, options)
    socket = Fil.Backpex.Upload.assign_uploads(field, socket)
    socket.assigns.uploads[name]
  end

  describe "assign_uploads/2" do
    test "allows one file for a Fil.Ecto.Ref field" do
      upload = allowed(:avatar, %{accept: ~w(.png image/jpeg)})

      assert upload.max_entries == 1
      assert upload.accept == ".png,image/jpeg"
      refute upload.external
    end

    test "takes 1 as max_entries for a single file and nothing else" do
      assert allowed(:avatar, %{accept: ~w(.png), max_entries: 1}).max_entries == 1

      assert_raise ArgumentError, ~r/:avatar in Fil.BackpexTest.ProductLive holds one file/, fn ->
        allowed(:avatar, %{accept: ~w(.png), max_entries: 2})
      end
    end

    test "needs max_entries for an array field" do
      assert allowed(:photos, %{accept: ~w(.png), max_entries: 4}).max_entries == 4

      assert_raise ArgumentError, ~r/needs :max_entries, because it's an \{:array, Fil.Ecto.Ref\} field/, fn ->
        allowed(:photos, %{accept: ~w(.png)})
      end
    end

    test "takes an upload_key" do
      field = field(:avatar, %{accept: ~w(.png), upload_key: :picture})
      socket = Fil.Backpex.Upload.assign_uploads(field, form_socket())
      assert socket.assigns.uploads[:picture]
    end

    test "defaults accept to the extensions, and needs one of them" do
      assert allowed(:avatar, %{extensions: ~w(.png)}).accept == ".png"

      assert_raise ArgumentError, ~r/needs :accept or :extensions/, fn -> allowed(:avatar, %{}) end
    end

    test "needs extensions when accept allows none" do
      assert_raise ArgumentError, ~r/needs :extensions, because :accept allows no extension/, fn ->
        allowed(:avatar, %{accept: ~w(image/*)})
      end

      assert allowed(:avatar, %{accept: ~w(image/*), extensions: ~w(.png)}).accept == "image/*"

      assert_raise ArgumentError, ~r/needs at least one extension/, fn ->
        allowed(:avatar, %{accept: ~w(.png), extensions: []})
      end
    end

    test "raises for a field of another type" do
      assert_raise ArgumentError, ~r/:name in Fil.BackpexTest.Product has the type :string/, fn ->
        allowed(:name, %{accept: ~w(.png)})
      end
    end

    test "refuses searchable array fields and index_editable" do
      assert_raise ArgumentError, ~r/can't be searchable/, fn ->
        allowed(:photos, %{accept: ~w(.png), max_entries: 2, searchable: true})
      end

      assert allowed(:avatar, %{accept: ~w(.png), searchable: true})

      assert_raise ArgumentError, ~r/can't be index_editable/, fn ->
        allowed(:avatar, %{accept: ~w(.png), index_editable: true})
      end
    end

    test "allows direct: true only when Backpex takes upload_error:" do
      field = field(:docs, %{accept: ~w(.pdf), max_entries: 2, direct: true})

      options = Fil.Backpex.Upload.__upload_options__(field, form_socket(), true)
      assert is_function(options.external, 2)

      assert_raise ArgumentError, ~r/can't use direct: true, because this Backpex version has no upload_error:/, fn ->
        Fil.Backpex.Upload.__upload_options__(field, form_socket(), false)
      end
    end

    test "detects upload_error: in the installed Backpex" do
      options = %{accept: ~w(.pdf), max_entries: 2, direct: true}

      assert {:docs, %{upload_error: upload_error}} = field(:docs, options)
      assert upload_error == (&Fil.LiveView.upload_error/2)

      if Keyword.has_key?(Backpex.Fields.Upload.config_schema(), :upload_error) do
        assert is_function(allowed(:docs, options).external, 2)
      else
        assert_raise ArgumentError, ~r/has no upload_error: option/, fn -> allowed(:docs, options) end
      end
    end

    test "refuses direct: true with if_exists: :overwrite" do
      field = field(:docs, %{accept: ~w(.pdf), max_entries: 2, direct: true, if_exists: :overwrite})

      assert_raise ArgumentError, ~r/can't use direct: true with if_exists: :overwrite/, fn ->
        Fil.Backpex.Upload.__upload_options__(field, form_socket(), true)
      end
    end

    test "raises outside the fields of a LiveResource" do
      assert_raise ArgumentError, ~r/not in the form of a resource action/, fn ->
        allowed(:avatar, %{accept: ~w(.png)}, form_socket(%{action_type: :resource}))
      end

      assert_raise ArgumentError, ~r/needs an adapter with a :schema/, fn ->
        allowed(:avatar, %{accept: ~w(.png)}, form_socket(%{live_resource: Fil.Backpex.UploadTest.NoSchema}))
      end
    end
  end

  describe "validate_config!/2" do
    test "refuses the callbacks the field implements, unknown and invalid options" do
      for option <- [consume_upload: &Function.identity/1, external: &Function.identity/1, disk: :uploads] do
        assert_raise RuntimeError, ~r/unknown options/, fn ->
          field(:avatar, Map.new([{:accept, ~w(.png)}, option]))
        end
      end

      assert_raise RuntimeError, ~r/Configuration error for field "avatar".*:if_exists/s, fn ->
        field(:avatar, %{accept: ~w(.png), if_exists: :replace})
      end
    end
  end

  describe "new" do
    test "stores the files in the order of the file input, with the content type of their paths", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/products/new")

      upload(view, :photos, [png("a.png", "photo a"), png("b.PNG", "photo b")])
      upload(view, :avatar, [%{name: "me.jpg", content: "avatar", type: "image/png"}])

      assert {:error, {:live_redirect, _to}} = save(view, %{name: "Chair"})

      [product] = Repo.all(Product)
      assert [%Fil.Ref{path: "products/new/" <> _a} = a, %Fil.Ref{path: "products/new/" <> _b} = b] = product.photos
      assert Fil.read!(a) == "photo a"
      assert Fil.read!(b) == "photo b"
      assert Path.extname(b.path) == ".png"

      assert Fil.read!(product.avatar) == "avatar"
      assert Fil.stat!(product.avatar).content_type == "image/jpeg"
      assert Fil.Disk.same_storage?(product.avatar.disk, Storage.uploads())
    end

    test "refuses a file whose path has another extension, before the save", %{conn: conn, disk: disk} do
      {:ok, view, _html} = live(conn, "/admin/products/new")

      upload(view, :photos, [%{name: "evil.html", content: "<script></script>", type: "image/png"}])
      html = save(view, %{name: "Chair"})

      assert html =~ "This type of file isn&#39;t accepted"
      assert Repo.all(Product) == []
      assert {:ok, []} = Fil.ls(disk, "products/new")
    end

    test "refuses the save while LiveView refused a file", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/products/new")

      upload(view, :avatar, [%{name: "cat.gif", content: "gif", type: "image/gif"}])
      assert save(view, %{name: "Chair"}) =~ "This type of file isn&#39;t accepted"
      assert Repo.all(Product) == []
    end

    test "refuses the save with more files than max_entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/products/new")

      photos = for name <- ~w(a b c d), do: png("#{name}.png", name)

      file_input(view, "#resource-form", :photos, photos)
      |> render_upload("a.png")

      html = save(view, %{name: "Chair"})
      assert html =~ "You can upload at most 3 file(s)"
      assert Repo.all(Product) == []
    end

    test "logs a failed write, and the record keeps the ref", %{conn: conn} do
      Storage.fail_writes()
      {:ok, view, _html} = live(conn, "/admin/products/new")
      upload(view, :photos, [png("a.png", "photo a")])

      log = capture_log(fn -> assert {:error, {:live_redirect, _to}} = save(view, %{name: "Chair"}) end)

      assert log =~ "Fil.Backpex.Upload, field :photos: could not store an upload"
      [product] = Repo.all(Product)
      assert [photo] = product.photos
      refute Fil.exists?(photo)
    end
  end

  describe "edit" do
    setup %{disk: disk} do
      a = Fil.write!(disk, "old/a.png", "A")
      b = Fil.write!(disk, "old/b.png", "B")
      avatar = Fil.write!(disk, "old/avatar.png", "old avatar")
      product = Repo.insert!(%Product{name: "Chair", photos: [a, b], avatar: avatar})

      {:ok, product: product, a: a, b: b, avatar: avatar}
    end

    test "deletes a removed photo and a replaced avatar after the save", %{conn: conn} = context do
      {:ok, view, html} = live(conn, "/admin/products/#{context.product.id}/edit")
      assert html =~ "a.png"

      remove(view, "old/a.png")
      upload(view, :avatar, [png("new.png", "new avatar")])
      upload(view, :photos, [png("c.png", "photo c")])

      assert {:error, {:live_redirect, _to}} = save(view, %{name: "Chair"})

      product = Repo.get!(Product, context.product.id)
      assert [%Fil.Ref{path: "old/b.png"}, %Fil.Ref{path: "products/" <> _c} = c] = product.photos
      assert c.path =~ "products/#{product.id}/"
      assert Fil.read!(c) == "photo c"
      assert Fil.read!(product.avatar) == "new avatar"

      refute Fil.exists?(context.a)
      refute Fil.exists?(context.avatar)
      assert Fil.exists?(context.b)
    end

    test "writes and deletes nothing when the changeset is invalid, and keeps the entries", %{conn: conn} = context do
      {:ok, view, _html} = live(conn, "/admin/products/#{context.product.id}/edit")

      remove(view, "old/a.png")
      upload(view, :avatar, [png("new.png", "new avatar")])
      html = save(view, %{name: ""})

      assert html =~ "can&#39;t be blank"
      assert html =~ "new.png"
      assert %Product{avatar: %Fil.Ref{path: "old/avatar.png"}} = Repo.get!(Product, context.product.id)
      assert Fil.exists?(context.a)
      assert Fil.exists?(context.avatar)
      assert {:ok, []} = Fil.ls(context.disk, "products")
    end

    test "counts kept and new files with validate_length/3, before anything is written", %{conn: conn} = context do
      {:ok, view, _html} = live(conn, "/admin/products/#{context.product.id}/edit")

      upload(view, :photos, [png("c.png", "C"), png("d.png", "D")])
      html = save(view, %{name: "Chair"})

      assert html =~ "should have at most 3 item(s)"
      assert {:ok, []} = Fil.ls(context.disk, "products")
    end

    test "keeps the replaced avatar when the new one isn't written", %{conn: conn} = context do
      {:ok, view, _html} = live(conn, "/admin/products/#{context.product.id}/edit")
      upload(view, :avatar, [png("new.png", "new avatar")])
      Storage.fail_writes()

      log = capture_log(fn -> assert {:error, {:live_redirect, _to}} = save(view, %{name: "Chair"}) end)

      assert log =~ "could not store an upload"
      assert log =~ ~s(kept ["old/avatar.png"])
      assert Fil.read!(context.avatar) == "old avatar"
    end

    test "ignores a removed path the record doesn't have", context do
      other = Fil.write!(context.disk, "other/x.png", "someone else's")
      product = context.product
      field = field(:photos, %{accept: ~w(.png), max_entries: 3})
      socket = Fil.Backpex.Upload.assign_uploads(field, form_socket(%{item: product}))

      params = Fil.Backpex.Upload.put_upload_change(field, socket, %{}, product, {[], []}, ["other/x.png"], :insert)
      assert Enum.map(params["photos"], & &1.path) == ["old/a.png", "old/b.png"]

      Fil.Backpex.Upload.remove_uploads(field, socket, product, ["other/x.png"])
      assert Fil.exists?(other)
      assert Fil.exists?(context.a)
      assert Fil.exists?(context.b)
    end

    test "refuses the save with a file that isn't uploaded yet", %{conn: conn} = context do
      {:ok, view, _html} = live(conn, "/admin/products/#{context.product.id}/edit")

      # LiveViewTest sends a file in chunks of 64 KB, so it needs a larger one to stop at 50 %.
      big = String.duplicate("D", 200_000)
      input = file_input(view, "#resource-form", :photos, [png("c.png", "C"), png("d.png", big)])
      render_upload(input, "c.png")
      render_upload(input, "d.png", 50)
      html = save(view, %{name: "Chair"})

      assert html =~ "The file couldn&#39;t be uploaded"
      assert [%Fil.Ref{path: "old/a.png"}, %Fil.Ref{path: "old/b.png"}] = Repo.get!(Product, context.product.id).photos
      assert {:ok, []} = Fil.ls(context.disk, "products")
    end

    test "refuses new files that get the same path in an array field", context do
      field = field(:photos, %{accept: ~w(.png), max_entries: 3, path: &"old/#{&1.client_name}"})
      changeset = Ecto.Changeset.change(context.product)

      assigns = fn names, removed ->
        entries = for {name, i} <- Enum.with_index(names), do: entry(name, i)
        upload = struct!(Phoenix.LiveView.UploadConfig, name: :photos, max_entries: 3, entries: entries)

        %{
          uploads: %{photos: upload},
          item: context.product,
          removed_uploads: [photos: removed],
          live_resource: ProductLive
        }
      end

      error = {"A file with this name already exists", [validation: :unique_path]}
      check = &Fil.Backpex.Upload.before_changeset(changeset, %{}, [], nil, field, &1)

      # Twice the same path, and the path of a kept file.
      for names <- [~w(c.png c.png), ~w(a.png)] do
        refused =
          names
          |> assigns.([])
          |> check.()

        assert error in Keyword.get_values(refused.errors, :photos)
      end

      different = assigns.(~w(c.png d.png), [])
      assert check.(different).valid?

      # A kept file that's removed frees its path.
      removed = assigns.(~w(a.png), ["old/a.png"])
      assert check.(removed).valid?
    end

    test "replaces a file at a stable path with if_exists: :overwrite", %{conn: conn} = context do
      id = context.product.id

      for content <- ["logo 1", "logo 2"] do
        {:ok, view, _html} = live(conn, "/admin/products/#{id}/edit")
        upload(view, :logo, [png("logo.png", content)])
        assert {:error, {:live_redirect, _to}} = save(view, %{name: "Chair"})
      end

      logo = Repo.get!(Product, id).logo
      assert logo.path == "logos/#{id}.png"
      assert Fil.read!(logo) == "logo 2"
    end

    test "shows the names of the files", %{conn: conn} = context do
      {:ok, _view, html} = live(conn, "/admin/products/#{context.product.id}/show")

      assert html =~ "a.png"
      assert html =~ "avatar.png"
      refute html =~ "old/a.png"
    end
  end

  describe "direct uploads" do
    test "stores the file the browser uploaded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/products/new")

      upload(view, :docs, [%{name: "a.pdf", content: "PDF", type: "application/pdf"}])
      assert_receive {:external, "a.pdf", {:ok, meta, _socket}}
      assert %{status: 200} = Fil.LiveViewHelper.put_direct(meta, "PDF", Storage.signing())

      assert {:error, {:live_redirect, _to}} = save(view, %{name: "Chair"})

      [product] = Repo.all(Product)
      assert [%Fil.Ref{path: path} = doc] = product.docs
      assert path == meta.path
      assert Fil.read!(doc) == "PDF"
    end

    test "logs a file the browser never uploaded, and the record keeps the ref", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/products/new")
      upload(view, :docs, [%{name: "a.pdf", content: "PDF", type: "application/pdf"}])

      log = capture_log(fn -> assert {:error, {:live_redirect, _to}} = save(view, %{name: "Chair"}) end)

      assert log =~ "Fil.Backpex.Upload, field :docs: could not store an upload"
      assert [%Product{docs: [doc]}] = Repo.all(Product)
      refute Fil.exists?(doc)
    end

    test "refuses a path with another extension when it signs the URL" do
      field = field(:docs, %{accept: ~w(.pdf), max_entries: 2, direct: true})
      %{external: external} = Fil.Backpex.Upload.__upload_options__(field, form_socket(), true)
      socket = Phoenix.LiveView.allow_upload(form_socket(), :docs, accept: ~w(.pdf), max_entries: 2)
      evil = %Phoenix.LiveView.UploadEntry{upload_config: :docs, uuid: "u", client_name: "evil.html", client_size: 3}
      report = %{evil | client_name: "report.PDF"}

      assert {:error, %{reason: :extension}, _socket} = external.(evil, socket)
      assert {:ok, %{uploader: "Fil", path: "u.pdf"}, _socket} = external.(report, socket)
    end
  end

  defp png(name, content), do: %{name: name, content: content, type: "image/png"}

  defp entry(name, index) do
    %Phoenix.LiveView.UploadEntry{
      ref: Integer.to_string(index),
      upload_config: :photos,
      uuid: "uuid-#{index}",
      client_name: name,
      client_type: "image/png",
      valid?: true,
      done?: true,
      progress: 100
    }
  end

  defp upload(view, name, files) do
    input = file_input(view, "#resource-form", name, files)
    for file <- files, do: render_upload(input, file.name)
    input
  end

  defp remove(view, path) do
    view
    |> element(~s{button[phx-click="cancel-existing-entry"][phx-value-ref="#{path}"]})
    |> render_click()
  end

  defp save(view, change) do
    view
    |> form("#resource-form", change: change)
    |> render_submit(%{"save-type" => "save"})
  end
end

defmodule Fil.Backpex.UploadTest.NoSchema do
  def adapter_config(_key), do: nil
end
