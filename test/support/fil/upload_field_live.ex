defmodule Fil.LiveViewTest.UploadFieldLive do
  @moduledoc false

  # A form with `Fil.LiveView.upload_field/1` and the handlers its docs show, for `live_isolated/3`. The session has the
  # pid of an agent with the test's pid, the options for `allow_upload/3`, and functions (the session is signed, and
  # refuses functions): `:init` runs in `mount/3` and returns the socket, `:save` gets the socket when the form is
  # submitted and returns `{:ok, existing}`, `{:error, %Ecto.Changeset{}}` or `{:error, error}`. Its result goes to the
  # test as `{:saved, result}`. With `component: true`, the form is in `Fil.LiveViewTest.UploadFieldComponent` instead.

  alias Fil.LiveViewTest.UploadFieldComponent

  use Phoenix.LiveView, log: false

  @impl Phoenix.LiveView
  def mount(_params, %{"config" => config}, socket) do
    config = Agent.get(config, & &1)
    init = config[:init] || (& &1)

    socket =
      socket
      |> assign(config: config, test: config.test, save: config[:save], existing: config[:existing] || [], errors: [])
      |> assign(:form, to_form(%{}, as: :product))
      |> allow_photos(config)

    {:ok, init.(socket)}
  end

  # The component allows its own upload.
  defp allow_photos(socket, %{component: true}), do: socket
  defp allow_photos(socket, config), do: allow_upload(socket, :photos, config.allow)

  @impl Phoenix.LiveView
  def render(%{config: %{component: true}} = assigns) do
    ~H"""
    <.live_component module={UploadFieldComponent} id="photos" allow={@config.allow} />
    """
  end

  def render(assigns) do
    ~H"""
    <.form for={@form} id="form" phx-change="validate" phx-submit="save">
      <Fil.LiveView.upload_field
        upload={@uploads.photos}
        existing={@existing}
        field={@form[:photos]}
        label="Photos"
        errors={@errors}
      />
    </.form>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", params, socket), do: {:noreply, Fil.LiveView.cancel_upload(socket, params)}

  def handle_event("remove-file", %{"path" => path}, socket) do
    {:noreply, update(socket, :existing, fn existing -> Enum.reject(existing, &(&1.path == path)) end)}
  end

  def handle_event("save", _params, socket) do
    result = socket.assigns.save.(socket)
    send(socket.assigns.test, {:saved, result})

    case result do
      {:ok, existing} -> {:noreply, assign(socket, existing: existing, errors: [])}
      {:error, %Ecto.Changeset{} = changeset} -> {:noreply, assign(socket, :form, changeset_form(changeset))}
      {:error, error} -> {:noreply, assign(socket, :errors, [error])}
    end
  end

  # What phoenix_ecto's `to_form/1` builds from a changeset, without the dependency.
  defp changeset_form(changeset), do: to_form(%{}, as: :product, errors: changeset.errors, action: changeset.action)
end

defmodule Fil.LiveViewTest.UploadFieldComponent do
  @moduledoc false

  # The upload field in a LiveComponent, which handles the cancel button itself through `target={@myself}`.

  use Phoenix.LiveComponent

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      if socket.assigns[:uploads],
        do: socket,
        else: allow_upload(socket, :photos, assigns.allow)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <form id="form" phx-change="validate" phx-submit="save" phx-target={@myself}>
        <Fil.LiveView.upload_field upload={@uploads.photos} target={@myself} />
      </form>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", _params, socket), do: {:noreply, socket}
  def handle_event("cancel-upload", params, socket), do: {:noreply, Fil.LiveView.cancel_upload(socket, params)}
end
