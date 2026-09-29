defmodule Fil.LiveViewTest.UploadLive do
  @moduledoc false

  # A form with one upload, for `live_isolated/3`. The session has the pid of an agent with the test's pid, the upload's
  # name, the options for `allow_upload/3`, and a function the "save" event calls with the socket (the session is
  # signed, and refuses functions). The function's result goes to the test as `{:consumed, result}`, and so do
  # exceptions and exits, so a test can assert on them without the LiveView crashing.

  use Phoenix.LiveView, log: false

  @impl Phoenix.LiveView
  def mount(_params, %{"config" => config}, socket) do
    %{test: test, name: name, allow: allow, consume: consume} = Agent.get(config, & &1)

    socket =
      socket
      |> assign(test: test, name: name, consume: consume)
      |> allow_upload(name, allow)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <form id="form" phx-change="validate" phx-submit="save">
      <.live_file_input upload={@uploads[@name]} />
    </form>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", _params, socket) do
    send(socket.assigns.test, {:consumed, run(socket.assigns.consume, socket)})
    {:noreply, socket}
  end

  defp run(consume, socket) do
    consume.(socket)
  rescue
    exception -> {:raised, exception}
  catch
    :exit, reason -> {:exited, reason}
  end
end
