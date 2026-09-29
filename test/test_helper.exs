ExUnit.start(exclude: [:integration])

# The endpoint for `Fil.LiveView`'s tests, with the PubSub its upload channels join through.
Application.put_env(:fil, Fil.LiveViewTest.Endpoint,
  secret_key_base: String.duplicate("fil-test", 8),
  live_view: [signing_salt: "fil-live-view"],
  pubsub_server: Fil.LiveViewTest.PubSub,
  server: false
)

# Phoenix logs every socket connection and channel join, which would fill the test output.
for %{id: {Phoenix.Logger, _event} = id} <- :telemetry.list_handlers([:phoenix]), do: :telemetry.detach(id)

{:ok, _pid} =
  Supervisor.start_link([{Phoenix.PubSub, name: Fil.LiveViewTest.PubSub}, Fil.LiveViewTest.Endpoint],
    strategy: :one_for_one
  )

if Fil.Emulator.integration_requested?(), do: Fil.Emulator.report()
