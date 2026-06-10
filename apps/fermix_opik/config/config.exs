import Config

# FermixOpik exports Fermix's telemetry to an Opik instance. Disabled by default;
# set `enabled: true` (or FERMIX_OPIK_ENABLED=1) to attach. These values mirror
# the code defaults in `FermixOpik`, so inside the Fermix release — where this
# per-app config is NOT loaded, only Fermix's umbrella config is — the exporter
# resolves the same settings from env + those defaults (see FermixOpik moduledoc).
config :fermix_opik,
  enabled: false,
  base_url: "http://localhost:5173/api",
  project_name: "fermix",
  api_key: nil,
  workspace: nil,
  trace_ttl_ms: 120_000,
  max_queue: 500
