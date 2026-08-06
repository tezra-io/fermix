defmodule FermixChannels.MixProject do
  use Mix.Project

  def project do
    [
      app: :fermix_channels,
      version: "0.8.0",
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
      mod: {FermixChannels.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:fermix_core, in_umbrella: true},
      {:fermix_nif, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:websockex, "~> 0.4"}
    ]
  end
end
