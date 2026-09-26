defmodule Fil.DoctestTest do
  use ExUnit.Case, async: true

  # Examples that write files use memory disks. Each doctest runs in its own process, so each gets an empty store.
  setup do
    Fil.Adapter.Memory.checkout()
  end

  # Runs the doctests of every module in the application, so a new module's examples are tested without registering
  # it anywhere.
  {:ok, modules} = :application.get_key(:fil, :modules)

  for module <- Enum.sort(modules) do
    doctest module
  end
end
