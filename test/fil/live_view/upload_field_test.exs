defmodule Fil.LiveView.UploadFieldTest.Product do
  use Ecto.Schema

  schema "products" do
    field :name, :string
    field :photos, {:array, Fil.Ecto.Ref}, disk: {Fil, :disk, [[adapter: Fil.Adapter.Memory]]}, default: []
  end
end

defmodule Fil.LiveView.UploadFieldTest.Repo do
  use Ecto.Repo, otp_app: :fil, adapter: Ecto.Adapters.SQLite3
end

defmodule Fil.LiveView.UploadFieldTest.Migration do
  use Ecto.Migration

  def change do
    create table(:products) do
      add(:name, :text)
      add(:photos, {:array, :string}, null: false, default: [])
    end
  end
end

defmodule Fil.LiveView.UploadFieldTest do
  alias Fil.LiveView.UploadFieldTest.Migration
  alias Fil.LiveView.UploadFieldTest.Product
  alias Fil.LiveView.UploadFieldTest.Repo
  alias Fil.LiveViewTest.UploadFieldLive
  alias Phoenix.LiveView.UploadConfig
  alias Phoenix.LiveView.UploadEntry

  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2, to_form: 2]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Fil.LiveViewTest.Endpoint

  setup do
    Fil.Adapter.Memory.checkout()
    {:ok, disk: Fil.disk(adapter: Fil.Adapter.Memory)}
  end

  defp upload(fields \\ []) do
    defaults = [name: :photos, ref: "phx-photos", max_entries: 3, max_file_size: 5_000_000, accept: ".png,.pdf"]
    struct!(UploadConfig, Keyword.merge(defaults, fields))
  end

  defp entry(fields) do
    defaults = [
      ref: "0",
      upload_ref: "phx-photos",
      upload_config: :photos,
      uuid: "0b2e8b8e",
      client_name: "cat.png",
      client_type: "image/png",
      client_size: 1500,
      valid?: true,
      progress: 49
    ]

    struct!(UploadEntry, Keyword.merge(defaults, fields))
  end

  defp stored(path) do
    [adapter: Fil.Adapter.Memory]
    |> Fil.disk()
    |> Fil.ref(path)
  end

  defp render_field(assigns) do
    assigns =
      assigns
      |> Map.new()
      |> Map.put_new(:upload, upload())

    component = &Fil.LiveView.upload_field/1

    component
    |> render_component(assigns)
    |> LazyHTML.from_fragment()
  end

  defp attribute(html, selector, name) do
    html
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  defp texts(html, selector) do
    html
    |> LazyHTML.query(selector)
    |> Enum.map(
      &(&1
        |> LazyHTML.text()
        |> String.trim())
    )
  end

  defp count(html, selector) do
    html
    |> LazyHTML.query(selector)
    |> Enum.count()
  end

  defp classes(html, selector) do
    [class] = attribute(html, selector, "class")
    class
  end

  describe "upload_field/1" do
    test "renders a label and a drop zone for the file input" do
      html = render_field(label: "Photos")

      assert attribute(html, "label", "for") == ["phx-photos"]
      assert attribute(html, "label", "phx-drop-target") == ["phx-photos"]
      assert attribute(html, "label input[type=file]", "id") == ["phx-photos"]
      assert attribute(html, "input", "accept") == [".png,.pdf"]
      assert attribute(html, "input", "multiple") == [""]
      assert texts(html, "label > span") == ["Photos", "or drop files here"]
      assert count(html, "ul") == 0
    end

    test "points the file input at the errors and marks it invalid while there are errors" do
      html = render_field(upload: upload())

      assert attribute(html, "input", "aria-describedby") == ["phx-photos-hint phx-photos-errors"]
      assert attribute(html, "#phx-photos-hint", "aria-hidden") == ["true"]
      assert attribute(html, "#phx-photos-errors", "aria-live") == ["polite"]
      assert attribute(html, "input", "aria-invalid") == []
      assert attribute(html, "input", "required") == []

      invalid = render_field(upload: upload(errors: [{"phx-photos", :too_many_files}]), required: true)

      assert attribute(invalid, "input", "aria-invalid") == ["true"]
      assert attribute(invalid, "input", "required") == [""]
      assert classes(invalid, "input") == "file-input w-full file-input-error"
    end

    test "points the file input at the errors of its entries, which are announced" do
      entries = [entry(ref: "0", valid?: false), entry(ref: "1", valid?: false, client_name: "b.png")]
      errors = [{"0", :too_large}, {"1", :not_accepted}, {"1", :too_large}]
      html = render_field(upload: upload(entries: entries, errors: errors), hint: false)

      ids = ["phx-photos-0-error-0", "phx-photos-1-error-0", "phx-photos-1-error-1"]
      assert attribute(html, "input", "aria-describedby") == [Enum.join(["phx-photos-errors" | ids], " ")]
      assert attribute(html, "input", "aria-invalid") == ["true"]
      assert attribute(html, "li p", "id") == ids
      assert attribute(html, "li p", "role") == ["alert", "alert", "alert"]
    end

    test "requires a file only while there's no stored file" do
      assert render_field(required: true) |> attribute("input", "required") == [""]
      assert render_field(required: true, existing: [stored("a.png")]) |> attribute("input", "required") == []
    end

    test "renders a row for each entry, with a preview only for valid images a browser shows" do
      entries = [
        entry(ref: "0"),
        entry(ref: "1", client_name: "cv.pdf", client_type: "application/pdf", progress: 0),
        entry(ref: "2", client_name: "raw.tiff", client_type: "image/tiff"),
        entry(ref: "3", client_name: "empty.png", client_size: 0),
        entry(ref: "4", client_name: "huge.png", valid?: false)
      ]

      html = render_field(upload: upload(entries: entries))

      assert texts(html, "li span.truncate") == ["cat.png", "cv.pdf", "raw.tiff", "empty.png", "huge.png"]
      assert texts(html, "li span.shrink-0") == ["1.5 KB", "1.5 KB", "1.5 KB", "0 B", "1.5 KB"]
      assert attribute(html, "progress", "value") == ["49", "0", "49", "49"]
      assert attribute(html, "progress", "aria-label") |> hd() == "Upload progress of cat.png"
      assert attribute(html, "li img", "data-phx-entry-ref") == ["0"]
      assert attribute(html, "li img", "alt") == [""]
    end

    test "renders a cancel button for each entry, and a remove button for each existing file" do
      existing = [stored("photos/a.png")]
      html = render_field(upload: upload(entries: [entry([])]), existing: existing)

      assert texts(html, "li:first-child span.truncate") == ["a.png"]
      assert texts(html, "button") == ["Remove", "Cancel"]
      assert attribute(html, "button", "type") == ["button", "button"]
      assert attribute(html, "button", "phx-click") == ["remove-file", "cancel-upload"]
      assert attribute(html, "button", "phx-value-upload") == ["photos", "photos"]
      assert attribute(html, "button", "phx-value-path") == ["photos/a.png"]
      assert attribute(html, "button", "phx-value-ref") == ["0"]
      assert attribute(html, "button", "aria-label") == ["Remove a.png", "Cancel upload of cat.png"]
      assert attribute(html, "button", "phx-target") == []
    end

    test "sends the events it's given to the target" do
      existing = [stored("a.png")]
      assigns = [upload: upload(entries: [entry([])]), existing: existing, cancel: "cancel", remove: "remove"]
      html = render_field([{:target, "#photos"} | assigns])

      assert attribute(html, "button", "phx-click") == ["remove", "cancel"]
      assert attribute(html, "button", "phx-target") == ["#photos", "#photos"]
    end

    test "takes a single ref or nil as existing" do
      disk = Fil.disk(adapter: Fil.Adapter.Memory)

      assert render_field(existing: Fil.ref(disk, "avatar.png"))
             |> texts("li")
             |> length() == 1

      assert render_field(existing: nil) |> count("li") == 0
    end

    test "hides a single existing ref while an entry is there, because saving replaces it" do
      avatar = stored("avatar.png")

      without_entry = render_field(upload: upload(max_entries: 1), existing: avatar)
      assert texts(without_entry, "button") == ["Remove"]
      assert attribute(without_entry, "input", "multiple") == []

      with_entry = render_field(upload: upload(max_entries: 1, entries: [entry([])]), existing: avatar)
      assert texts(with_entry, "button") == ["Cancel"]
    end

    test "keeps a list of existing refs while an entry is there, also with max_entries: 1" do
      html = render_field(upload: upload(max_entries: 1, entries: [entry([])]), existing: [stored("a.png")])
      assert texts(html, "button") == ["Remove", "Cancel"]
    end

    test "replaces the content of rows with the slots, and keeps the buttons and the progress" do
      assigns = %{
        upload: upload(entries: [entry([])]),
        existing: [stored("a.png")]
      }

      html =
        ~H"""
        <Fil.LiveView.upload_field upload={@upload} existing={@existing}>
          <:entry :let={entry}><em>new {entry.client_name}</em></:entry>
          <:file :let={photo}><em>stored {photo.path}</em></:file>
        </Fil.LiveView.upload_field>
        """
        |> rendered_to_string()
        |> LazyHTML.from_fragment()

      assert texts(html, "li em") == ["stored a.png", "new cat.png"]
      assert count(html, "li span.truncate") == 0
      assert count(html, "li img") == 0
      assert count(html, "progress") == 1
      assert texts(html, "button") == ["Remove", "Cancel"]
    end

    test "replaces the default classes of each part" do
      default = render_field(id: "field", upload: upload(entries: [entry([])]), label: "Photos")

      assert classes(default, "#field") == "fieldset mb-2"
      assert classes(default, "label") =~ "border-dashed"
      assert attribute(default, "label > span", "class") == ["label mb-1", "label"]
      assert classes(default, "input") == "file-input w-full"
      assert classes(default, "ul") == "mt-2 flex flex-col gap-2 text-sm"
      assert classes(default, "progress") == "progress w-32"
      assert classes(default, "button") == "btn btn-sm btn-ghost"

      html =
        render_field(
          id: "field",
          upload:
            upload(
              entries: [entry([]), entry(ref: "1", valid?: false)],
              errors: [{"1", :too_large}, {"phx-photos", :too_many_files}]
            ),
          label: "Photos",
          class: "root",
          label_class: "label-text",
          dropzone_class: "dropzone",
          input_class: ["input", false],
          error_class: "invalid",
          hint_class: "hint",
          list_class: "list",
          entry_class: "entry",
          progress_class: "bar",
          button_class: "button",
          message_class: "error"
        )

      assert classes(html, "#field") == "root"
      assert classes(html, "label") == "dropzone"
      assert attribute(html, "label > span", "class") == ["label-text", "hint"]
      assert classes(html, "input") == "input invalid"
      assert classes(html, "ul") == "list"
      assert attribute(html, "li", "class") == ["entry", "entry"]
      assert classes(html, "progress") == "bar"
      assert attribute(html, "button", "class") == ["button", "button"]
      assert attribute(html, "p", "class") == ["error", "error"]
    end

    test "shows the errors of the upload, its entries and errors, through upload_error/2" do
      entries = [entry(ref: "0", valid?: false, client_type: "text/html"), entry(ref: "1", valid?: false)]
      errors = [{"0", :not_accepted}, {"1", :too_large}, {"phx-photos", :too_many_files}]
      extra = [%Fil.AlreadyExistsError{}, "Plain text", {"custom %{n}", n: 1}]
      html = render_field(upload: upload(entries: entries, errors: errors), errors: extra)

      assert texts(html, "li p") == ["This type of file isn't accepted", "The file is larger than 5 MB"]
      assert count(html, "progress") == 0

      assert texts(html, "#phx-photos-errors p") == [
               "You can upload at most 3 file(s)",
               "A file with this name already exists",
               "Plain text",
               "custom 1"
             ]
    end

    test "shows the field's errors once files are picked or the form was submitted" do
      errors = [photos: {"should have at most %{count} item(s)", [count: 5, validation: :length]}]
      field = fn action -> to_form(%{}, as: :product, errors: errors, action: action)[:photos] end

      assert render_field(field: field.(nil)) |> texts("#phx-photos-errors p") == []
      assert render_field(field: field.(:validate)) |> texts("#phx-photos-errors p") == []

      assert render_field(field: field.(:validate), upload: upload(entries: [entry([])]))
             |> texts("#phx-photos-errors p") ==
               ["should have at most 5 item(s)"]

      assert render_field(field: field.(:update)) |> texts("#phx-photos-errors p") == ["should have at most 5 item(s)"]
    end

    test "passes every text through translate" do
      existing = [stored("a.png")]
      upload = upload(entries: [entry(valid?: false)], errors: [{"0", :too_large}, {"phx-photos", :too_many_files}])
      translate = fn {msg, opts} -> "<#{msg}|#{Enum.map_join(opts, ",", fn {key, value} -> "#{key}=#{value}" end)}>" end
      html = render_field(upload: upload, existing: existing, translate: translate, errors: [%Fil.NotFoundError{}])

      assert texts(html, "label > span") == ["<or drop files here|>"]
      assert texts(html, "button") == ["<Remove|>", "<Cancel|>"]

      assert attribute(html, "button", "aria-label") == [
               "<Remove %{name}|name=a.png>",
               "<Cancel upload of %{name}|name=cat.png>"
             ]

      assert texts(html, "p") == [
               "<The file is larger than %{max}|max=5 MB,max_file_size=5000000>",
               "<You can upload at most %{count} file(s)|count=3>",
               "<The upload failed|>"
             ]
    end

    test "shows a hint of its own, or none" do
      assert render_field(hint: "PNG, at most 5 MB") |> texts("label > span") == ["PNG, at most 5 MB"]
      assert render_field(hint: false) |> count("label > span") == 0
    end

    test "sets the id of the root" do
      assert render_field(id: "photos") |> attribute("#photos", "class") == ["fieldset mb-2"]
    end
  end

  # Mounts `UploadFieldLive` with the upload options and the rest of its config.
  defp mount(allow, config \\ []) do
    config = Map.merge(%{test: self(), allow: allow}, Map.new(config))
    agent = start_supervised!({Agent, fn -> config end}, id: make_ref())
    {:ok, view, _html} = live_isolated(build_conn(), UploadFieldLive, session: %{"config" => agent})
    view
  end

  defp submit(view) do
    view
    |> element("#form")
    |> render_submit()

    assert_receive {:saved, result}
    result
  end

  defp view_html(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
  end

  defp png(name, content \\ String.duplicate("p", 100)), do: %{name: name, content: content, type: "image/png"}

  describe "upload_field/1 in a LiveView" do
    test "shows the progress of an upload, and cancels an entry" do
      view = mount(accept: ~w(.png), max_entries: 2)
      input = file_input(view, "#form", :photos, [png("a.png", String.duplicate("a", 100)), png("b.png")])
      render_upload(input, "a.png", 49)

      html = view_html(view)
      assert texts(html, "li span.truncate") == ["a.png", "b.png"]
      assert attribute(html, "progress", "value") == ["49", "0"]

      view
      |> element("button[aria-label='Cancel upload of a.png']")
      |> render_click()

      assert view
             |> view_html()
             |> texts("li span.truncate") == ["b.png"]
    end

    test "shows the progress of a direct upload", %{disk: disk} do
      signing = Fil.Plugin.URL.attach(disk, base_url: "http://localhost/storage", secret: "secret")
      view = mount(accept: ~w(.png), external: Fil.LiveView.external(signing))
      input = file_input(view, "#form", :photos, [png("a.png")])

      # `render_upload/3` reports progress as the uploader does.
      render_upload(input, "a.png", 49)

      assert view
             |> view_html()
             |> attribute("progress", "value") == ["49"]
    end

    test "shows a direct upload whose extension external/2 refuses", %{disk: disk} do
      signing = Fil.Plugin.URL.attach(disk, base_url: "http://localhost/storage", secret: "secret")
      view = mount(accept: ~w(.png), external: Fil.LiveView.external(signing))
      input = file_input(view, "#form", :photos, [png("evil.html")])

      assert {:error, _errors} = render_upload(input, "evil.html")

      html = view_html(view)
      assert texts(html, "li p") == ["This type of file isn't accepted"]
      assert count(html, "progress") == 0
    end

    test "shows a direct upload that couldn't be started", %{disk: disk} do
      # A memory disk without `Fil.Plugin.URL` can't sign an upload URL.
      view = mount(accept: ~w(.png), external: Fil.LiveView.external(disk))
      input = file_input(view, "#form", :photos, [png("a.png")])

      log = ExUnit.CaptureLog.capture_log(fn -> render_upload(input, "a.png") end)

      assert log =~ "Fil.LiveView.external/2"

      assert view
             |> view_html()
             |> texts("li p") == ["The upload couldn't be started"]
    end

    test "shows a file that's too large" do
      view = mount(accept: ~w(.png), max_file_size: 10)
      input = file_input(view, "#form", :photos, [png("a.png", String.duplicate("a", 11))])

      assert {:error, [[_ref, :too_large]]} = render_upload(input, "a.png")

      assert view
             |> view_html()
             |> texts("li p") == ["The file is larger than 10 B"]
    end

    test "shows too many files" do
      view = mount(accept: ~w(.png), max_entries: 1)
      input = file_input(view, "#form", :photos, [png("a.png"), png("b.png")])

      assert {:error, [[_ref, :too_many_files]]} = render_upload(input, "a.png")

      assert view
             |> view_html()
             |> texts("[aria-live] p") == ["You can upload at most 1 file(s)"]
    end

    test "shows an extension the upload doesn't accept, after the submit", %{disk: disk} do
      save = &Fil.LiveView.consume_uploaded_entries(&1, :photos, disk)
      view = mount([accept: ~w(.png)], save: save)

      # LiveView accepts the file for the type the browser sends.
      input = file_input(view, "#form", :photos, [png("evil.html", "<script>")])
      render_upload(input, "evil.html")

      assert {:error, %Fil.InvalidRequestError{reason: :extension}} = submit(view)

      assert view
             |> view_html()
             |> texts("[aria-live] p") == ["This type of file isn't accepted"]
    end

    test "shows a file that already exists", %{disk: disk} do
      {:ok, _taken} = Fil.write(disk, "taken.png", "old")
      save = &Fil.LiveView.consume_uploaded_entries(&1, :photos, disk, path: fn _entry -> "taken.png" end)
      view = mount([accept: ~w(.png)], save: save)

      input = file_input(view, "#form", :photos, [png("a.png")])
      render_upload(input, "a.png")

      assert {:error, %Fil.AlreadyExistsError{}} = submit(view)

      assert view
             |> view_html()
             |> texts("[aria-live] p") == ["A file with this name already exists"]

      assert view
             |> view_html()
             |> texts("li span.truncate") == ["a.png"]
    end

    test "removes an existing file from the list, and saves the ones it keeps", %{disk: disk} do
      {:ok, a} = Fil.write(disk, "a.png", "a")
      {:ok, b} = Fil.write(disk, "b.png", "b")

      save = fn socket ->
        with {:ok, new} <- Fil.LiveView.consume_uploaded_entries(socket, :photos, disk) do
          {:ok, socket.assigns.existing ++ new}
        end
      end

      view = mount([accept: ~w(.png), max_entries: 2], existing: [a, b], save: save)

      view
      |> element("button[aria-label='Remove a.png']")
      |> render_click()

      assert view
             |> view_html()
             |> texts("li span.truncate") == ["b.png"]

      input = file_input(view, "#form", :photos, [png("c.png", "c")])
      render_upload(input, "c.png")

      assert {:ok, [^b, c]} = submit(view)
      assert Fil.read(c) == {:ok, "c"}
      assert Fil.exists?(a)

      assert view
             |> view_html()
             |> texts("li span.truncate") == ["b.png", Path.basename(c.path)]
    end

    test "leaves the socket alone for an unknown upload or entry" do
      view = mount(accept: ~w(.png))
      input = file_input(view, "#form", :photos, [png("a.png")])
      render_upload(input, "a.png", 10)

      render_click(view, "cancel-upload", %{"upload" => "photos", "ref" => "unknown"})
      render_click(view, "cancel-upload", %{"upload" => "unknown", "ref" => "0"})
      render_click(view, "cancel-upload", %{"upload" => "__phoenix_refs_to_names__", "ref" => "0"})
      render_click(view, "cancel-upload", %{})

      assert view
             |> view_html()
             |> texts("li span.truncate") == ["a.png"]
    end

    test "sends the cancel event to a LiveComponent" do
      view = mount([accept: ~w(.png)], component: true)
      input = file_input(view, "#form", :photos, [png("a.png")])
      render_upload(input, "a.png", 10)

      assert view
             |> view_html()
             |> texts("li span.truncate") == ["a.png"]

      view
      |> element("button", "Cancel")
      |> render_click()

      assert view
             |> view_html()
             |> count("li") == 0
    end
  end

  describe "upload_field/1 with Fil.Ecto.Ref" do
    # A repo per test, in memory, which the LiveView process uses through `put_dynamic_repo/1`.
    setup do
      pid = start_supervised!({Repo, name: nil, database: ":memory:", pool_size: 1, log: false})
      Repo.put_dynamic_repo(pid)
      :ok = Ecto.Migrator.up(Repo, 1, Migration, log: false)
      {:ok, repo: pid}
    end

    test "replaces one of two photos and deletes the removed one after the save", %{disk: disk, repo: repo} do
      {:ok, a} = Fil.write(disk, "a.png", "a")
      {:ok, b} = Fil.write(disk, "b.png", "b")

      product =
        %Product{name: "Chair"}
        |> Ecto.Changeset.change(photos: [a, b])
        |> Repo.insert!()

      init = fn socket ->
        Repo.put_dynamic_repo(repo)
        Phoenix.Component.assign(socket, product: product)
      end

      # The save of the Phoenix guide.
      save = fn socket ->
        %{product: product, existing: kept} = socket.assigns

        with {:ok, new} <- Fil.LiveView.consume_uploaded_entries(socket, :photos, disk) do
          changeset =
            product
            |> Ecto.Changeset.change()
            |> Ecto.Changeset.put_change(:photos, kept ++ new)
            |> Ecto.Changeset.validate_length(:photos, max: 2)

          removed = Fil.Ecto.Ref.removed(changeset, :photos)

          case Repo.update(changeset) do
            {:ok, product} ->
              Enum.each(removed, &Fil.rm/1)
              {:ok, product.photos}

            {:error, changeset} ->
              Enum.each(new, &Fil.rm/1)
              {:error, changeset}
          end
        end
      end

      view = mount([accept: ~w(.png), max_entries: 2], existing: product.photos, init: init, save: save)

      view
      |> element("button[aria-label='Remove a.png']")
      |> render_click()

      input = file_input(view, "#form", :photos, [png("c.png", "c")])
      render_upload(input, "c.png")

      assert {:ok, [^b, c]} = submit(view)
      assert Repo.get!(Product, product.id).photos == [b, c]
      refute Fil.exists?(a)
      assert Fil.read(b) == {:ok, "b"}
      assert Fil.read(c) == {:ok, "c"}
    end

    test "shows the field's error after a failed save", %{disk: disk, repo: repo} do
      {:ok, a} = Fil.write(disk, "a.png", "a")
      product = Repo.insert!(%Product{name: "Chair", photos: [a]})

      init = fn socket ->
        Repo.put_dynamic_repo(repo)
        Phoenix.Component.assign(socket, product: product)
      end

      save = fn socket ->
        with {:ok, new} <- Fil.LiveView.consume_uploaded_entries(socket, :photos, disk) do
          socket.assigns.product
          |> Ecto.Changeset.change(photos: socket.assigns.existing ++ new)
          |> Ecto.Changeset.validate_length(:photos, max: 1)
          |> Repo.update()
        end
      end

      view = mount([accept: ~w(.png)], existing: product.photos, init: init, save: save)
      input = file_input(view, "#form", :photos, [png("b.png")])
      render_upload(input, "b.png")

      assert {:error, %Ecto.Changeset{}} = submit(view)

      assert view
             |> view_html()
             |> texts("[aria-live] p") == ["should have at most 1 item(s)"]
    end
  end
end
