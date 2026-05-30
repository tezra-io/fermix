defmodule FermixCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :fermix_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {FermixCore.Application, []}
    ]
  end

  defp deps do
    [
      {:burrito, "~> 1.5"},
      {:exqlite, "~> 0.36.0"},
      {:anubis_mcp, "~> 1.6"},
      {:floki, "~> 0.36"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.15", only: :test},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      {:websockex, "~> 0.4"}
    ]
  end
end
