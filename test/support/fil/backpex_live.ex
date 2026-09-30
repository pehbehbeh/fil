defmodule Fil.BackpexTest.Storage do
  @moduledoc false

  # The disks of `Fil.BackpexTest.Product`. Both are the test's memory store. `uploads/0` fails every write while the
  # store has a file at `"unavailable"`, which a test writes to make the storage fail. `signing/0` signs upload URLs
  # for `Fil.Plug`, for direct uploads.

  @spec uploads() :: Fil.Disk.t()
  def uploads do
    [adapter: Fil.Adapter.Memory]
    |> Fil.disk()
    |> Fil.attach(:unavailable, &unavailable/3)
  end

  @spec signing() :: Fil.Disk.t()
  def signing do
    Fil.Plugin.URL.attach(uploads(), base_url: "http://localhost/storage", secret: "fil-backpex-test")
  end

  @doc "Makes every write to `uploads/0` fail with a `Fil.UnavailableError`."
  @spec fail_writes() :: Fil.Ref.t()
  def fail_writes do
    [adapter: Fil.Adapter.Memory]
    |> Fil.disk()
    |> Fil.write!("unavailable", "")
  end

  defp unavailable(%Fil.Op{name: :write} = op, next, _opts) do
    memory = Fil.disk(adapter: Fil.Adapter.Memory)

    if Fil.exists?(memory, "unavailable"),
      do: Fil.Op.put_result(op, {:error, %Fil.UnavailableError{reason: :test}}),
      else: next.(op)
  end

  defp unavailable(op, next, _opts), do: next.(op)
end

defmodule Fil.BackpexTest.Product do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  schema "products" do
    field :name, :string
    field :avatar, Fil.Ecto.Ref, disk: &Fil.BackpexTest.Storage.uploads/0
    field :photos, {:array, Fil.Ecto.Ref}, disk: &Fil.BackpexTest.Storage.uploads/0, default: []
    field :docs, {:array, Fil.Ecto.Ref}, disk: &Fil.BackpexTest.Storage.signing/0, default: []
    field :logo, Fil.Ecto.Ref, disk: &Fil.BackpexTest.Storage.uploads/0
  end

  # The upload fields aren't cast: `Fil.Backpex.Upload` puts them.
  @spec changeset(Ecto.Schema.t(), map(), keyword()) :: Ecto.Changeset.t()
  def changeset(product, attrs, _metadata) do
    product
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:photos, max: 3)
  end
end

defmodule Fil.BackpexTest.Adapter do
  @moduledoc false

  # `Backpex.Adapters.Ecto` with a `get/4` SQLite can run: Backpex's query has `distinct: field(item, ^primary_key)`,
  # which SQLite refuses ("DISTINCT with multiple columns is not supported").

  for {name, arity} <- Backpex.Adapters.Ecto.__info__(:functions), name != :get do
    args = Macro.generate_arguments(arity, __MODULE__)
    @doc false
    def unquote(name)(unquote_splicing(args)), do: Backpex.Adapters.Ecto.unquote(name)(unquote_splicing(args))
  end

  @doc false
  def get(primary_value, _fields, _assigns, live_resource) do
    repo = live_resource.adapter_config(:repo)
    schema = live_resource.adapter_config(:schema)
    {:ok, repo.get(schema, primary_value)}
  end
end

defmodule Fil.BackpexTest.DirectUpload do
  @moduledoc false

  # `Fil.Backpex.Upload` with a Backpex version that allows `direct: true`, so the tests can run direct uploads before
  # a Backpex release renders their errors. It sends the test the result of each signed upload, so the test can PUT
  # the file as the browser would. The LiveView process has the test in `$callers`.

  use Backpex.Field, config_schema: Fil.Backpex.Upload.config_schema()

  defoverridable validate_config!: 2

  @doc false
  def validate_config!(field, live_resource) do
    field
    |> Fil.Backpex.Upload.__validate_config__(live_resource, &super(&1, live_resource), "99.0.0")
    |> Keyword.update!(:external, &report/1)
  end

  defp report(external) do
    fn entry, socket ->
      result = external.(entry, socket)
      for test <- Process.get(:"$callers", []), do: send(test, {:external, entry.client_name, result})
      result
    end
  end

  @impl Backpex.Field
  defdelegate render_value(assigns), to: Fil.Backpex.Upload

  @impl Backpex.Field
  defdelegate render_form(assigns), to: Fil.Backpex.Upload

  @impl Backpex.Field
  defdelegate assign_uploads(field, socket), to: Fil.Backpex.Upload

  @impl Backpex.Field
  defdelegate before_changeset(changeset, attrs, metadata, repo, field, assigns), to: Fil.Backpex.Upload
end

defmodule Fil.BackpexTest.ProductLive do
  @moduledoc false

  use Backpex.LiveResource,
    adapter: Fil.BackpexTest.Adapter,
    adapter_config: [
      schema: Fil.BackpexTest.Product,
      repo: Fil.Backpex.UploadTest.Repo,
      update_changeset: &Fil.BackpexTest.Product.changeset/3,
      create_changeset: &Fil.BackpexTest.Product.changeset/3
    ]

  @impl Backpex.LiveResource
  def layout(_assigns), do: {Fil.BackpexTest.Layouts, :admin}

  @impl Backpex.LiveResource
  def singular_name, do: "Product"

  @impl Backpex.LiveResource
  def plural_name, do: "Products"

  @impl Backpex.LiveResource
  def fields do
    [
      name: %{module: Backpex.Fields.Text, label: "Name"},
      avatar: %{module: Fil.Backpex.Upload, label: "Avatar", accept: ~w(.png .jpg)},
      photos: %{module: Fil.Backpex.Upload, label: "Photos", accept: ~w(.png), max_entries: 3, path: &photo_path/2},
      docs: %{module: Fil.BackpexTest.DirectUpload, label: "Docs", accept: ~w(.pdf), max_entries: 2, direct: true},
      logo: %{
        module: Fil.Backpex.Upload,
        label: "Logo",
        accept: ~w(.png),
        path: fn _entry, assigns -> "logos/#{assigns.item.id}.png" end,
        if_exists: :overwrite,
        only: [:edit]
      }
    ]
  end

  # The id is `nil` on the new page, so new products get their photos under `products/new`.
  defp photo_path(entry, assigns), do: "products/#{assigns.item.id || "new"}/#{Fil.LiveView.filename(entry)}"
end

defmodule Fil.BackpexTest.Layouts do
  @moduledoc false

  use Phoenix.Component

  # Backpex renders the layout as a component with the page in its inner block.
  def admin(assigns), do: ~H"<main>{render_slot(@inner_block)}</main>"
end

defmodule Fil.BackpexTest.Hooks do
  @moduledoc false

  # Points the LiveView at the test's in-memory repo, whose pid the test puts into the session. The repo is defined in
  # the test, so `Fil.DoctestTest` doesn't run the doctests Ecto gives it.
  def on_mount(:repo, _params, %{"repo" => pid}, socket) do
    repo = Fil.BackpexTest.ProductLive.adapter_config(:repo)
    repo.put_dynamic_repo(pid)
    {:cont, socket}
  end
end

defmodule Fil.BackpexTest.Translator do
  @moduledoc false

  # Backpex's `translator_function` and `error_translator_function`: fills in the bindings, as the fallback of
  # `Fil.LiveView.upload_field/1` does.
  @spec translate({String.t(), map() | keyword()}) :: String.t()
  def translate({message, bindings}) do
    Enum.reduce(bindings, message, fn {key, value}, message ->
      String.replace(message, "%{#{key}}", to_string(value))
    end)
  end
end

defmodule Fil.BackpexTest.Router do
  @moduledoc false

  use Phoenix.Router

  import Backpex.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
  end

  scope "/admin" do
    pipe_through(:browser)

    backpex_routes()

    live_session :default, on_mount: [{Fil.BackpexTest.Hooks, :repo}, Backpex.InitAssigns] do
      live_resources("/products", Fil.BackpexTest.ProductLive)
    end
  end
end

defmodule Fil.BackpexTest.Endpoint do
  @moduledoc false

  # The endpoint of the Backpex tests, configured and started in `test_helper.exs`.

  use Phoenix.Endpoint, otp_app: :fil

  @session_options [store: :cookie, key: "_fil_backpex", signing_salt: "fil-backpex"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(Fil.BackpexTest.Router)
end
