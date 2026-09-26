ExUnit.start(exclude: [:integration])

if Fil.Emulator.integration_requested?(), do: Fil.Emulator.report()
