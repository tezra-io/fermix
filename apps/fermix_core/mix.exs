defmodule FermixCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :fermix_core,
      version: "0.2.0",
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
      # Explicit because FermixCore.Application supervises the shared
      # FermixCore.Finch pool directly (req would only pull it transitively).
      {:finch, "~> 0.21"},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      {:websockex, "~> 0.4"}
    ]
  end
end
