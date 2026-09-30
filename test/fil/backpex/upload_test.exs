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
  alias Fil.BackpexTest.DirectUpload
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
    Fil.Backpex.Upload.validate_config!(
      {name, Map.merge(%{module: Fil.Backpex.Upload, label: "Files"}, options)},
      ProductLive
    )
  end

  describe "validate_config!/2" do
    test "builds a single file field from a Fil.Ecto.Ref field" do
      config = field(:avatar, %{accept: ~w(.png image/jpeg)})

      assert config[:upload_key] == :avatar
      assert config[:max_entries] == 1
      refute config[:fil].multiple?
      assert config[:fil].extensions == ~w(.png .jpg .jpeg)
      refute Keyword.has_key?(config, :external)

      for callback <- [:list_existing_files, :put_upload_change, :consume_upload, :remove_uploads] do
        assert is_function(config[callback])
      end
    end

    test "takes 1 as max_entries for a single file and nothing else" do
      assert field(:avatar, %{accept: ~w(.png), max_entries: 1})[:max_entries] == 1

      assert_raise ArgumentError, ~r/:avatar in Fil.BackpexTest.ProductLive holds one file/, fn ->
        field(:avatar, %{accept: ~w(.png), max_entries: 2})
      end
    end

    test "needs max_entries for an array field" do
      assert field(:photos, %{accept: ~w(.png), max_entries: 4})[:max_entries] == 4

      assert_raise ArgumentError, ~r/needs :max_entries, because it's an \{:array, Fil.Ecto.Ref\} field/, fn ->
        field(:photos, %{accept: ~w(.png)})
      end
    end

    test "takes an upload_key" do
      assert field(:avatar, %{accept: ~w(.png), upload_key: :picture})[:upload_key] == :picture
    end

    test "defaults accept to the extensions, and needs one of them" do
      config = field(:avatar, %{extensions: ~w(.png)})
      assert config[:accept] == ~w(.png)

      assert_raise ArgumentError, ~r/needs :accept or :extensions/, fn -> field(:avatar, %{}) end
    end

    test "needs extensions when accept allows none" do
      assert_raise ArgumentError, ~r/needs :extensions, because :accept allows no extension/, fn ->
        field(:avatar, %{accept: ~w(image/*)})
      end

      assert field(:avatar, %{accept: ~w(image/*), extensions: ~w(.png)})[:fil].extensions == ~w(.png)
    end

    test "raises for a field of another type" do
      assert_raise ArgumentError, ~r/:name in Fil.BackpexTest.Product has the type :string/, fn ->
        field(:name, %{accept: ~w(.png)})
      end
    end

    test "refuses the callbacks it builds, and unknown options" do
      for option <- [consume_upload: &Function.identity/1, external: &Function.identity/1, disk: :uploads] do
        assert_raise RuntimeError, ~r/unknown options/, fn ->
          field(:avatar, Map.new([{:accept, ~w(.png)}, option]))
        end
      end
    end

    test "refuses searchable array fields and index_editable" do
      assert_raise ArgumentError, ~r/can't be searchable/, fn ->
        field(:photos, %{accept: ~w(.png), max_entries: 2, searchable: true})
      end

      assert field(:avatar, %{accept: ~w(.png), searchable: true})[:searchable]

      assert_raise ArgumentError, ~r/can't be index_editable/, fn ->
        field(:avatar, %{accept: ~w(.png), index_editable: true})
      end
    end

    test "refuses direct: true on a Backpex release that crashes on errors of direct uploads" do
      version = Application.spec(:backpex, :vsn)

      assert_raise ArgumentError, ~r/can't use direct: true on Backpex #{version}/, fn ->
        field(:docs, %{accept: ~w(.pdf), max_entries: 2, direct: true})
      end
    end

    test "raises outside a LiveResource" do
      options = %{module: Fil.Backpex.Upload, label: "Avatar", accept: ~w(.png)}

      # InlineCRUD passes the name of its own field.
      assert_raise ArgumentError, ~r/not in Backpex.Fields.InlineCRUD/, fn ->
        Fil.Backpex.Upload.validate_config!({:avatar, options}, :addresses)
      end

      assert_raise ArgumentError, ~r/needs an adapter with a :schema/, fn ->
        Fil.Backpex.Upload.validate_config!({:avatar, options}, Fil.Backpex.UploadTest.NoSchema)
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

    test "ignores a remove button for a file the record doesn't have", %{conn: conn} = context do
      other = Fil.write!(context.disk, "other/x.png", "someone else's")
      {:ok, view, _html} = live(conn, "/admin/products/#{context.product.id}/edit")

      view
      |> element(~s{button[phx-click="cancel-existing-entry"][phx-value-ref="old/a.png"]})
      |> render_click(%{"ref" => "other/x.png"})

      assert {:error, {:live_redirect, _to}} = save(view, %{name: "Chair"})

      assert Fil.exists?(other)
      assert Fil.exists?(context.a)
      assert [%Fil.Ref{path: "old/a.png"}, %Fil.Ref{path: "old/b.png"}] = Repo.get!(Product, context.product.id).photos
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
      config = direct_field()
      socket = direct_socket()
      evil = %Phoenix.LiveView.UploadEntry{upload_config: :docs, uuid: "u", client_name: "evil.html", client_size: 3}
      report = %{evil | client_name: "report.PDF"}

      assert {:error, %{reason: :extension}, _socket} = config[:external].(evil, socket)
      assert {:ok, %{uploader: "Fil", path: "u.pdf"}, _socket} = config[:external].(report, socket)
    end
  end

  defp direct_field do
    DirectUpload.validate_config!(
      {:docs, %{module: DirectUpload, label: "Docs", accept: ~w(.pdf), max_entries: 2, direct: true}},
      ProductLive
    )
  end

  defp direct_socket do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.LiveView.allow_upload(:docs, accept: ~w(.pdf), max_entries: 2)
    |> Phoenix.Component.assign(:item, %Product{})
  end

  defp png(name, content), do: %{name: name, content: content, type: "image/png"}

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
