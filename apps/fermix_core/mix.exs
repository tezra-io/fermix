defmodule FermixCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :fermix_core,
      version: "0.2.2",
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
    ] ++ opik_dep()
  end

  # Dev-only, opt-in observability exporter. It lives in the SIBLING `fermix-plugins`
  # repo, so its `path:` resolves only on a dev machine that has that repo checked
  # out — an unconditional dep would break every standalone/CI/public build.
  #
  # ONE switch: `FERMIX_OPIK_ENABLED`. Export it (e.g. in your dev shell) and rebuild
  # → the plugin is bundled here, and at boot the plugin attaches itself (it reads
  # the SAME env in `FermixOpik.enabled?`). Unset (the default) → not bundled, so
  # default builds stay clean. The truthy set mirrors the plugin's so build (bundle)
  # and runtime (attach) never disagree.
  #
  # Future: pull plugins from the plugins repo at setup time instead of a local path.
  # See docs/TELEMETRY_CONTRACT.md and projects/fermix-plugins.
  defp opik_dep do
    if System.get_env("FERMIX_OPIK_ENABLED") in ["1", "true", "TRUE", "yes", "y"] do
      # `only: [:dev, :prod]` — never bundle the exporter into the TEST build, so
      # `mix test` cannot ship test-fixture traces (bench/channel/job tests) to a
      # live Opik project even when FERMIX_OPIK_ENABLED is exported globally
      # (e.g. from ~/.zshrc). The daemon still exports in :dev / :prod.
      [{:fermix_opik, path: "../../../fermix-plugins/apps/fermix_opik", only: [:dev, :prod]}]
    else
      []
    end
  end
end
