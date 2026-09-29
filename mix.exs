defmodule Fil.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/pehbehbeh/fil"

  def project do
    [
      app: :fil,
      version: @version,
      elixir: "~> 1.18",
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
      {:telemetry, "~> 1.3"},

      # Optional: Fil.Plug serves signed URLs of Local and Memory disks, and Req.Test stubs are plugs.
      {:plug, "~> 1.14", optional: true},
      # Optional: Fil.Plugin.Thumbnails resizes images with libvips.
      {:vix, "~> 0.33", optional: true},
      # Optional: Fil.Kino browses disks in Livebook.
      {:kino, "~> 0.19", optional: true},

      # Development
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
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
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      files: ~w(lib guides mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Fil",
      api_reference: false,
      logo: "assets/icon.svg",
      favicon: "assets/icon.svg",
      source_ref: "v#{@version}",
      extra_section: "Guides",
      extras: ["guides/installation.md", "guides/plugins.md", "CHANGELOG.md"],
      groups_for_docs: [
        Building: &(&1[:section] == :building),
        Operations: &(&1[:section] == :operations),
        "Bang variants": &(&1[:section] == :bang)
      ],
      groups_for_modules: [
        Adapters: ~r/^Fil\.Adapter(\.\w+)?$/,
        Plugins: ~r/^Fil\.Plugin\./,
        Integrations: [Fil.Plug, Fil.Kino],
        Errors: ~r/^Fil\.\w+Error$/
      ]
    ]
  end
end
