import Config

config :fermix_web, FermixWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "IDEc2P19ECF1+hwm0K0GriUalzvJ87GqV3JBCplMvtFgX1lnZw5n3iimO0n2KpXd",
  server: false

config :logger, level: :warning

config :fermix_core, :log, enabled: false

config :fermix_core, :memory,
  enabled: false,
  extraction_enabled: false,
  extraction_timeout_ms: 1_000,
  extraction_context_messages: 8,
  extraction_min_confidence: 0.75,
  database_path: Path.join(System.tmp_dir!(), "fermix-test-memory.db"),
  prompt_base_dir: Path.join(System.tmp_dir!(), "fermix-test-prompt-memory"),
  prompt_user_token_cap: 800,
  prompt_memory_token_cap: 1600,
  prompt_files_rebuild_hours: 12,
  scheduler_enabled: false,
  owner_id: "default",
  agent_id: "main"

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
    bot_token: "test-token",
    allowed_user_ids: []
  ]

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true
