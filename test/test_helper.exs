ExUnit.start(exclude: [:integration])

# The endpoint for `Fil.LiveView`'s tests, with the PubSub its upload channels join through.
Application.put_env(:fil, Fil.LiveViewTest.Endpoint,
  secret_key_base: String.duplicate("fil-test", 8),
  live_view: [signing_salt: "fil-live-view"],
  pubsub_server: Fil.LiveViewTest.PubSub,
  server: false
)

# The endpoint and config for `Fil.Backpex.Upload`'s tests, which run a LiveResource. Backpex warns without its
# translator functions.
Application.put_env(:fil, Fil.BackpexTest.Endpoint,
  secret_key_base: String.duplicate("fil-test", 8),
  live_view: [signing_salt: "fil-backpex"],
  pubsub_server: Fil.LiveViewTest.PubSub,
  server: false
)

Application.put_env(:backpex, :pubsub_server, Fil.LiveViewTest.PubSub)
Application.put_env(:backpex, :translator_function, {Fil.BackpexTest.Translator, :translate})
Application.put_env(:backpex, :error_translator_function, {Fil.BackpexTest.Translator, :translate})

# Phoenix and LiveView log every socket connection, channel join, mount and event, which would fill the test output.
# The LiveViews of Backpex's LiveResources have no `log: false`.
for %{id: {module, _event} = id} <- :telemetry.list_handlers([:phoenix]),
    module in [Phoenix.Logger, Phoenix.LiveView.Logger],
    do: :telemetry.detach(id)

{:ok, _pid} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: Fil.LiveViewTest.PubSub}, Fil.LiveViewTest.Endpoint, Fil.BackpexTest.Endpoint],
    strategy: :one_for_one
  )

if Fil.Emulator.integration_requested?(), do: Fil.Emulator.report()
