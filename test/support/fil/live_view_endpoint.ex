defmodule Fil.LiveViewTest.Endpoint do
  @moduledoc false

  # The endpoint `Phoenix.LiveViewTest` needs for `Fil.LiveView`'s tests. It's configured and started in
  # `test_helper.exs`, with the PubSub the upload channel joins through.

  use Phoenix.Endpoint, otp_app: :fil

  socket("/live", Phoenix.LiveView.Socket)
end
