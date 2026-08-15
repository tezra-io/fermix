import Config

# Named-timezone resolution for scheduled-job cron evaluation. `:tz` embeds the
# IANA database at compile time (no runtime updater), so the default
# UTC-only database is replaced without a network dependency.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :fermix_web,
  generators: [timestamp_type: :utc_datetime]

config :fermix_web, FermixWebWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FermixWebWeb.ErrorHTML, json: FermixWebWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FermixWeb.PubSub,
  live_view: [signing_salt: "W1N1pyZP"]

config :esbuild,
  version: "0.25.4",
  fermix_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/fermix_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.12",
  fermix_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/fermix_web", __DIR__)
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix,
  filter_parameters:
    ~w(password secret token t _csrf_token access_token refresh_token bot_token verify_token api_key mobile_push_key mobile_apns_key)

config :fermix_core,
  providers: [
    openai: [
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-5.4-mini",
      default_temperature: 0.7
    ]
  ],
  max_conversation_history: :infinity,
  context_window_limit: 120_000

config :fermix_core, :memory,
  enabled: true,
  extraction_enabled: true,
  extraction_context_messages: 12,
  extraction_min_confidence: 0.75,
  review_interval_hours: 24,
  review_max_messages: 40,
  review_input_token_budget: 4_000,
  review_failure_backoff_ms: 300_000,
  database_path: Path.expand("~/.fermix/memory.db"),
  prompt_base_dir: Path.expand("~/.fermix/memory"),
  prompt_user_token_cap: 800,
  prompt_memory_token_cap: 1600,
  compaction_enabled: true,
  compaction_token_budget: 8_000,
  checkpoint_persistence_enabled: true,
  scheduler_enabled: true,
  loop_detection_window: 10,
  loop_detection_warn_threshold: 3,
  loop_detection_kill_threshold: 5,
  owner_id: "default",
  agent_id: "main"

# Regular `subagents` tool caps (LLM-facing, advertised in its schema). Biased
# toward "delegate wide" — more, narrower workers beats a few fat ones (worker
# brevity lowers actual depth/time, not these ceilings). Kept below the :ultra
# block so the ultra > regular ordering holds. /ultra raises them via the :ultra
# block by tagging its context `subagent_mode: :ultra`. System-side knobs.
config :fermix_core, :subagents,
  max_tasks: 10,
  hard_max_concurrency: 8,
  default_max_concurrency: 4,
  max_result_bytes: 60_000

# /ultra exhaustive mode. Breadth ≫ regular (many narrow probes), depth <
# regular (probes are narrow, so fewer iterations each). The fanout_* keys are
# what the /ultra run-mode raises the subagents caps to via `subagent_mode:
# :ultra`. System-side knobs, not a config.toml surface.
config :fermix_core, :ultra,
  max_subtasks: 50,
  fanout_max_concurrency: 12,
  fanout_max_result_bytes: 300_000,
  fanout_worker_iterations: 40

# Per-agent loop depth caps (previously implicit IterationLimits @defaults; made
# explicit + tunable). This is DEPTH (how long one agent loops); the knobs above
# are BREADTH (how many run). /ultra workers override subagent depth via :ultra.
config :fermix_core, :iteration_limits,
  interactive: 100,
  subagent: 100,
  scheduled_job_default: 100

config :fermix_core, :jobs,
  scheduler_enabled: true,
  reconciliation_interval_ms: 60_000,
  run_freshness_window_seconds: 3600,
  default_timeout_ms: 1_800_000,
  delivery_timeout_ms: 60_000,
  delivery_channels: %{
    "telegram" => FermixChannels.Channels.Telegram,
    "slack" => FermixChannels.Channels.Slack,
    "discord" => FermixChannels.Channels.Discord,
    "signal" => FermixChannels.Channels.Signal,
    "whatsapp" => FermixChannels.Channels.WhatsApp,
    "mobile" => FermixChannels.Channels.Mobile,
    "cli" => FermixChannels.CLI
  }

# Coding-harness completion continuation (CODING_HARNESS_ORCHESTRATION §23.2): the
# channels-side module that re-ingests a finished chat-origin run's notice into its
# conversation. Injected by module because fermix_core must not compile-depend on
# fermix_channels — the same pattern as `:jobs` `delivery_channels` above.
config :fermix_core,
       :harness_continuation_dispatcher,
       FermixChannels.Harness.ContinuationDispatcher

config :fermix_core, :prompt_bootstrap,
  bootstrap_dir: Path.expand("~/.fermix/bootstrap"),
  accounting_enabled: true

config :fermix_core, :transcription,
  backend: "openai",
  model: "gpt-4o-mini-transcribe",
  max_file_mb: 20

config :fermix_channels,
  telegram: [
    enabled: true
  ],
  whatsapp: [
    enabled: false,
    mode: :webhook,
    webhook_path: "/webhook/whatsapp"
  ],
  discord: [
    enabled: false,
    mode: :gateway
  ],
  slack: [
    enabled: false,
    mode: :webhook
  ],
  signal: [
    enabled: false,
    mode: :subprocess
  ],
  mobile: [
    enabled: false,
    mode: :listener,
    port: 4_031,
    bind: "0.0.0.0",
    advertise_mdns: true,
    streaming: "draft",
    max_media_bytes: 20_971_520,
    media_store_max_bytes: 2_147_483_648,
    push: [enabled: false]
  ],
  # The ACP agent surface (M29). `enabled` is the whole operator knob — the
  # socket path is fixed and the caps are internal constants. `mode` is not a
  # knob either: ACP has exactly one transport, so it is declared here rather
  # than asked for or persisted.
  #
  # On by default. A user who never learns the surface exists adds Fermix to
  # Zed or a Buzz harness, gets refused, and concludes Fermix has no ACP. It
  # adds no privilege class: the socket is 0600 same-user, and `daemon.sock`
  # is already always-on, unauthenticated, and strictly more capable (its
  # `agent_message` path runs the slash-command pipeline; the acp entry carries
  # `commands?: false`). An explicit `enabled = false` in config.toml still
  # wins — the TOML is merged over this default at boot.
  acp: [
    enabled: true,
    mode: :gateway
  ]

config :fermix_core, :trace, base_dir: Path.expand("~/.fermix/traces")

config :fermix_core, :log,
  file: Path.expand("~/.fermix/logs/fermix.log"),
  max_no_bytes: 10_485_760,
  max_no_files: 5

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
