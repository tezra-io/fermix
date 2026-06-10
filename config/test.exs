import Config

config :fermix_web, FermixWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "IDEc2P19ECF1+hwm0K0GriUalzvJ87GqV3JBCplMvtFgX1lnZw5n3iimO0n2KpXd",
  server: false

config :logger, level: :warning

config :fermix_core, :log, enabled: false

config :fermix_core, :browser, cdp_port_range: 19_100..19_199

config :fermix_core, :memory,
  enabled: false,
  extraction_enabled: false,
  extraction_timeout_ms: 1_000,
  extraction_context_messages: 8,
  extraction_min_confidence: 0.75,
  review_interval_hours: 24,
  review_max_messages: 40,
  review_input_token_budget: 4_000,
  review_failure_backoff_ms: 300_000,
  database_path: Path.join(System.tmp_dir!(), "fermix-test-memory.db"),
  prompt_base_dir: Path.join(System.tmp_dir!(), "fermix-test-prompt-memory"),
  prompt_user_token_cap: 800,
  prompt_memory_token_cap: 1600,
  compaction_enabled: true,
  compaction_token_budget: 8_000,
  checkpoint_persistence_enabled: true,
  scheduler_enabled: false,
  loop_detection_window: 10,
  loop_detection_warn_threshold: 3,
  loop_detection_kill_threshold: 5,
  owner_id: "default",
  agent_id: "main"

config :fermix_core, :jobs,
  scheduler_enabled: false,
  reconciliation_interval_ms: 60_000,
  default_timeout_ms: 1_800_000,
  delivery_timeout_ms: 60_000,
  delivery_channels: %{}

config :fermix_core, :prompt_bootstrap,
  bootstrap_dir: Path.join(System.tmp_dir!(), "fermix-test-bootstrap"),
  accounting_enabled: true

config :fermix_core,
  providers: [
    openai: [
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-5.4-mini",
      api_key: "test-key"
    ]
  ]

config :fermix_channels,
  telegram: [
    enabled: false,
    bot_token: "test-token"
  ]

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true

# Hermetic default: tests must never touch a real OS keychain. Secure-on-save
# (SecretStore) routes through this stub; tests exercising the writer-less path
# override with FermixTestSupport.UnavailableSecretWriter. The module lives in
# test/support and is loaded by each app's test_helper.exs.
config :fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub

# Hermetic default: tests must never resolve host runtimes or spawn real
# `--version` processes. The mcp host-runtime probe (RuntimeProbe) denies by
# default; tests stub success per-call via :find_executable / :version_fetch.
config :fermix_core, :runtime_probe_host, FermixTestSupport.HostRuntimeStub
