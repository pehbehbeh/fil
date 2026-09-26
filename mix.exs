defmodule Fil.MixProject do
  alias Fil.Adapter.Local
  alias Fil.Adapter.Memory
  alias Fil.Adapter.S3

  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/pehbehbeh/fil"

  def project do
    [
      app: :fil,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description: "Fil is a pluggable file storage abstraction for Elixir.",
      package: package(),
      docs: docs(),
      name: "Fil",
      source_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: ["test.integration": :test]]
  end

  def application do
    [mod: {Fil.Application, []}, extra_applications: [:logger, :crypto, :xmerl]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.7"},
      {:mime, "~> 2.0"},

      # Optional: Fil.Plug serves signed URLs of Local and Memory disks
      {:plug, "~> 1.14", optional: true},

      # Development
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:quokka, "~> 2.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    ["test.integration": ["test --only integration"]]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Fil",
      api_reference: false,
      source_ref: "v#{@version}",
      extra_section: "Guides",
      extras: ["guides/installation.md", "guides/plugins.md"],
      groups_for_docs: [
        Building: &(&1[:section] == :building),
        Operations: &(&1[:section] == :operations),
        "Bang variants": &(&1[:section] == :bang)
      ],
      groups_for_modules: [
        Adapters: [Fil.Adapter, Local, S3, Memory],
        Plugins: ~r/^Fil\.Plugin\./,
        Integrations: [Fil.Plug],
        Errors: [Fil.Error, Fil.TransportError]
      ]
    ]
  end
end
