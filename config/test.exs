import Config

# Hermetic boot. The umbrella starts before a single test runs: the config
# provider hydrates `config.toml`, `SkillRegistry` loads the installed plugin
# store, `ensure_workspace/0` creates directories. With `FERMIX_HOME` unset all
# of that reads the OPERATOR's `~/.fermix`, which the suite neither controls nor
# restores — and two of the stubs pinned below are reached at boot, before any
# test has set them up: an installed `remote_mcp` plugin sends boot into the
# provenance gate (DistVerifierStub), a `@keyring` sentinel sends it into the
# secret writer (SecretWriterStub). Either one kills `mix test` outright, and on
# a machine where boot survives the suite is reading a live home instead.
#
# So the suite supplies a home of its own when the caller left it out. An
# explicit `FERMIX_HOME` still wins — `FERMIX_HOME=$(mktemp -d) mix test` is the
# documented invocation — which also keeps a re-read of this chain
# (`Config.Reader.read!(env: :test)`) a no-op rather than moving the suite's
# home mid-run. Blank is unset, the same rule `ConfigStore.fermix_home/0` uses.
case System.get_env("FERMIX_HOME") do
  home when is_binary(home) and home != "" ->
    :ok

  _unset_or_blank ->
    System.put_env(
      "FERMIX_HOME",
      Path.join(System.tmp_dir!(), "fermix-test-home-#{System.system_time(:nanosecond)}")
    )
end

# SetupLive model-listing seam: never reach Ollama/OpenRouter from tests
# (hermetic rule); live-UI tests swap in their own stub per test.
config :fermix_web, :model_listing_impl, FermixWebWeb.TestSupport.StaticModelListing

config :fermix_web, FermixWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "IDEc2P19ECF1+hwm0K0GriUalzvJ87GqV3JBCplMvtFgX1lnZw5n3iimO0n2KpXd",
  server: false

config :logger, level: :warning

config :fermix_core, :log, enabled: false

config :fermix_core, :memory,
  enabled: false,
  extraction_enabled: false,
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

# Coding-harness workers (Manager + DeliveryWorker) are always in the tree, but
# their timers, boot reconciliation, and artifact GC must stay dark in tests so
# the app-tree instances never touch the real Memory.Repo or FERMIX_HOME. Tests
# that exercise these workers start their own instances with `timer_enabled: true`
# and injected repo/runs_root seams.
config :fermix_core, :harness_workers_enabled, false

# Temporal reminder scheduler: the app-tree instance stays dark in tests (the
# jobs `scheduler_enabled` precedent), so `mix test` never runs the boot sweep,
# a due claim, or reconciliation against the real Memory.Repo. Scheduler tests
# start their own instances with injected repo/supervisor/clock seams.
config :fermix_core, :temporal, scheduler_enabled: false

# Skill-curation scheduler: belt and braces alongside the @compiled_env child
# gate in Application — disabled in config, never by omission. Curation tests
# start their own Scheduler instances with injected seams.
config :fermix_core, :skill_curation, enabled: false

# Completion continuation is OFF in tests (config.exs wires the channels-side
# dispatcher for dev/prod): `mix test` must never re-ingest a synthesized message
# into the live gateway/agent queue. A terminal run then takes the plain durable
# delivery path. Continuation tests inject their own dispatcher stub through the
# Manager's `:continuation_dispatcher` seam.
config :fermix_core, :harness_continuation_dispatcher, nil

# Hermetic default: `mix test` must never spawn a vendor `--version` probe or read
# the operator's `~/.codex`/`~/.claude`. The setup harness card (`:fermix_web`) and
# the doctor harness check (`:fermix_core`) both resolve their detector from config,
# so override both with an inert "no CLI installed" stub (the shape `Harness.Vendors`
# returns on a bare host). Tests exercising real detection inject their own seam.
harness_absent_detector = fn ->
  Map.new(["codex", "claude"], fn vendor ->
    {vendor, %{vendor: vendor, binary: nil, available?: false, version: nil, auth: :absent}}
  end)
end

config :fermix_core, :harness_vendor_detector, harness_absent_detector
config :fermix_web, :harness_detector, harness_absent_detector

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
  ],
  # Never bind a mobile listener or advertise mDNS from the suite. Tests that
  # exercise mobile start isolated instances on ephemeral ports.
  mobile: [
    enabled: false,
    mode: :listener,
    port: 4_031,
    bind: "127.0.0.1",
    advertise_mdns: false,
    streaming: "draft",
    max_media_bytes: 20_971_520,
    media_store_max_bytes: 2_147_483_648,
    push: [enabled: false]
  ],
  # Hermetic default, same reason telegram is off above: the acp surface ships
  # enabled, and a ready test tree would bind a real `<FERMIX_HOME>/acp.sock` —
  # colliding with the operator's own daemon whenever FERMIX_HOME is unset.
  # Tests that exercise the surface put their own value in app env.
  acp: [
    enabled: false
  ]

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true

# Hermetic default: tests must never touch a real OS keychain. Secure-on-save
# (SecretStore) routes through this stub; tests exercising the writer-less path
# override with FermixTestSupport.UnavailableSecretWriter. The module lives in
# the umbrella's test/support, which `fermix_core`'s `elixirc_paths(:test)`
# compiles into its ebin — every app depends on `fermix_core`, so the default
# resolves in all three suites and, unlike the old test_helper `require_file`,
# it also resolves during boot.
config :fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub

# The remote_mcp provenance gate under test. DENY-BY-DEFAULT: a test that wants a
# remote plugin to load must allow-list it explicitly (DistVerifierStub.allow/2),
# so a gate that stopped verifying fails here instead of passing quietly. Never
# replace this with a permissive stub.
config :fermix_core, :plugin_provenance_verifier, FermixTestSupport.DistVerifierStub

# Hermetic default: tests must never resolve host runtimes or spawn real
# `--version` processes. The mcp host-runtime probe (RuntimeProbe) denies by
# default; tests stub success per-call via :find_executable / :version_fetch.
config :fermix_core, :runtime_probe_host, FermixTestSupport.HostRuntimeStub

# A real daemon captures prompt/response/tool bodies in traces (resolved in
# config/runtime.exs, which honours this value). The suite pins the LEAN posture
# instead of inheriting the product default, so a test asserting on captured
# content opts in explicitly in its own setup and a test asserting content is
# absent is not reading whatever an earlier module left in the app env.
config :fermix_core, :telemetry, capture_content: false
