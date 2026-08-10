defmodule FermixCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :fermix_core,
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
      {:compux, github: "tezra-io/compux", ref: "9afd3f53d8c61d43c26c9d3f5ccbe367f9f559c7"},
      # Native kill(2) process-group shim used by the command-sweep (ProcessGroup).
      {:fermix_nif, in_umbrella: true},
      {:plug, "~> 1.15", only: :test},
      # Explicit because FermixCore.Application supervises the shared
      # FermixCore.Finch pool directly (req would only pull it transitively).
      {:finch, "~> 0.21"},
      # Explicit because the remote-MCP rail drives Mint directly
      # (`Capabilities.MCP.Remote.Connection`): it pins the connection to a
      # guard-validated peer and enforces response caps while streaming, neither
      # of which a pooled request/response client can express. Finch would only
      # pull it transitively.
      {:mint, "~> 1.7"},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      # Compile-time-embedded IANA tz database (no runtime network fetch, unlike
      # :tzdata) so scheduled-job cron timezones resolve in the Burrito binary.
      {:tz, "~> 0.28"},
      {:websockex, "~> 0.4"}
    ] ++ opik_dep()
  end

  # Observability exporter (Opik) — an in-repo umbrella app (`apps/fermix_opik`),
  # compiled into every dev/prod build (so a `brew`-installed binary carries it),
  # INERT until `FERMIX_OPIK_ENABLED` is set in the daemon env: `FermixOpik.enabled?`
  # gates startup (empty supervisor, no telemetry handler attached, zero overhead
  # when off). `only: [:dev, :prod]` keeps `fermix_core`'s recursive test run from
  # loading it, so `mix test` can never ship fixture traces to Opik.
  #
  # It lives in core because it is BEAM code (a telemetry handler in this VM) — it
  # must be compiled in and cannot be a pull-on-enable plugin (runtime BEAM loading
  # is unsupported; MILESTONE_8 §4/§14.3: an Elixir "plugin" belongs in core).
  defp opik_dep do
    [{:fermix_opik, in_umbrella: true, only: [:dev, :prod]}]
  end
end
