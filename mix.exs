defmodule Wenche.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/jarls-side-projects/elixir-wenche"

  def project do
    [
      app: :wenche,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      {:req, "~> 0.5"},
      {:xml_builder, "~> 2.3"},
      {:decimal, "~> 2.0"},
      {:uuid, "~> 1.1"},
      {:yaml_elixir, "~> 2.11"},
      {:plug, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Elixir library for Norwegian small business filings — Maskinporten auth,
    Altinn 3 API client, BRG XML/iXBRL generation, tax calculation (RF-1028/RF-1167),
    and shareholder register (RF-1086) XML generation.

    Ported from the Python CLI tool Wenche (https://github.com/olefredrik/Wenche).
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Original (Python)" => "https://github.com/olefredrik/Wenche"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"]
    ]
  end
end
