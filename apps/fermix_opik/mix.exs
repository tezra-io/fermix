defmodule FermixOpik.MixProject do
  use Mix.Project

  def project do
    [
      app: :fermix_opik,
      version: "0.1.0",
      build_path: "../../_build",
      # Own config (not the umbrella's) so standalone/recursive `mix test` for this
      # app never loads Fermix's `runtime.exs`, which references fermix_core. In a
      # release the umbrella config applies instead; the exporter falls back to its
      # code defaults there (see FermixOpik moduledoc).
      config_path: "config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {FermixOpik.Application, []}
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
