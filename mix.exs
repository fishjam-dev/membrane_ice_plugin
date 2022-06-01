defmodule Membrane.ICE.Mixfile do
  use Mix.Project

  @version "0.12.0"
  @github_url "https://github.com/membraneframework/membrane_ice_plugin"

  def project do
    [
      app: :membrane_ice_plugin,
      version: @version,
      elixir: "~> 1.10",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # hex
      description: "Template Plugin for Membrane Multimedia Framework",
      package: package(),

      # docs
      name: "Membrane Template plugin",
      source_url: @github_url,
      homepage_url: "https://membraneframework.org",
      docs: docs()
    ]
  end

  def application do
    [
      mod: {Membrane.ICE.Application, []},
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 0.10.0"},
      {:membrane_rtp_format, "~> 0.5.0"},
      {:membrane_funnel_plugin, "~> 0.6.0"},
      {:membrane_telemetry_metrics, "~> 0.1.0"},
      {:bunch, "~> 1.3.0"},
      {:fake_turn, "~> 0.2.0"},
      {:ex_dtls, "~> 0.11.0"},
      {:ex_doc, "~> 0.26", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},
      {:credo, "~> 1.6.1", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Membrane.ICE]
    ]
  end
end
