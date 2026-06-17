# Changelog

All notable changes to Fermix are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.1] - 2026-06-16

### Fixed — Plugin install under the OS-service daemon
- Plugin installation from the web setup page failed for **every** plugin
  with a misleading `signature invalid — refusing.` The OS-service unit
  (launchd `.plist` / systemd unit) carried no `PATH`, so the supervised
  daemon inherited a bare `PATH` that omits the Homebrew prefix where
  `cosign` lives. Signature verification shells out to `cosign`;
  `System.find_executable("cosign")` returned `nil`, the install pipeline
  reported `{:verification_failed, :cosign_not_installed}`, and the page
  rendered it as a bad signature. The signature was never actually checked.
  The same daemon ran fine in a dev shell (where `cosign` is on `PATH`),
  which masked the problem. `fermix service install` now pins a `PATH` in
  the unit file — leading with the directory `fermix` itself was installed
  into (its sibling `cosign` on a Homebrew install) followed by the standard
  system and Homebrew bin directories — so the daemon resolves `cosign` (and
  brew-installed MCP runtimes like `node`/`python`) the same way an
  interactive shell does.
- `fermix setup` now **self-heals a drifted service unit**: when an already
  installed unit no longer matches what the current binary would write (e.g.
  after an upgrade changed the template or the computed `PATH`), setup rewrites
  and reloads it instead of merely restarting the stale one. So upgrading and
  re-running `fermix setup` is enough to pick up the new `PATH` — the manual
  `fermix service install` becomes an escape hatch, not a required step, and
  any future unit-file change reaches existing installs automatically. An
  unchanged unit is still just restarted (no needless reinstall).
- The web setup page no longer reports a missing `cosign` binary as
  `signature invalid`; it now says `cosign not found — install it to verify
  plugin signatures (e.g. \`brew install cosign\`).`, distinguishing an
  environment problem from a genuinely bad signature.

## [0.3.0] - 2026-06-16

### Added — Provider Expansion (M12)
- OpenRouter (`openrouter`) and Ollama (`ollama`) as first-class LLM
  providers: primary/fallback selection, sub-agent and cron routing, CLI
  wizard + web setup panes, doctor probes, and telemetry/Opik attribution.
  OpenRouter rides Chat Completions with vendor-prefixed model ids and
  static app-attribution headers; Ollama is keyless against the local
  OpenAI-compat endpoint (`base_url` presence marks it configured) with a
  300s receive timeout and a doctor probe that checks the *served*
  `num_ctx` against the catalog window via the native `/api/show`.
- `FermixCore.Providers.Descriptor`: a static provider registry (labels,
  auth modes, setup fields, config-key allowlists, default base URLs) that
  routing, selection, config, the setup wizard, web setup, doctor,
  readiness, and health now all derive from instead of hand-maintained
  provider lists.
- Setup-page live model discovery (`FermixCore.Providers.ModelListing`):
  the Ollama pane probes the configured server URL and lists only the
  locally installed models; the OpenRouter pane lists the live upstream
  tool-capable catalog. Fetch failures show loud guidance plus a free-form
  model input. The "Model behavior" panel is hidden for providers without
  effort/fast knobs.

### Added — Mistral Provider
- Mistral (`mistral`) as the seventh first-class provider, riding the
  OpenAI ChatCompletions adapter (api-key only, no reasoning-effort) and
  exposing three rolling `-latest` tiers (large/medium/small) on a
  128k-context catalog through `FermixCore.Providers.Descriptor`. Adds
  `mistral_api_key` / `MISTRAL_API_KEY` across secret paths, wizard, CLI
  setup, the mix task, and `runtime.exs`; a `probe_mistral` doctor auth
  check; and Opik attribution. Canonical provider order is now
  `openai_codex, openai, anthropic, xai, openrouter, mistral, ollama`.

### Added — Sub-agent & Cron Model Selection
- `[fermix_core.routing]` `subagent_*` / `cron_*` keys
  (provider/model/reasoning_effort) give delegated `subagents` workers and
  unpinned cron jobs a smaller/cheaper model and thinking level without
  ever changing the main agent's model; unset keys inherit the main model.
  New `FermixCore.Providers.RoutingOverrides` reads and validates them,
  overlaying effort per-route (clamped per provider) so the inherited
  failover chain is preserved. Surfaced through `config.toml`, the setup
  wizard, the web setup page (sub-agent select shown only on the primary
  provider's pane), the `model_routing_config` tool, an optional on-the-fly
  per-call `model` arg on the `subagents` tool (provider inferred from the
  slug), and `fermix doctor` validation.

### Added — Deferred Tool Catalog
- Lazy tool-discovery surface so the model fetches tool schemas on demand
  instead of carrying the full catalog in every prompt.
  `FermixCore.Capabilities.Deferral` partitions trust-filtered capabilities
  into advertised (full schemas on the wire) and deferred (plugin/MCP tools
  — names stay in the prompt prose, schemas load on demand) sets, with
  three new bridge tools: `tool_search` (BM25 over the live registry),
  `tool_describe`, and `tool_call`. Gated by a single
  `[fermix_core.tools.tool_search] enabled` boolean; disabled is
  byte-identical to the inline catalog.
- `FermixCore.Prompt.ModelOverlays` for constrained per-model-family prompt
  overlays appended at the end of the instructions (currently only the
  Codex/GPT-5 family), preserving the cached prefix.

### Added — Plugin Distribution (M8 / M8.1)
- External plugin distribution: plugins now live in the
  `tezra-io/fermix-plugins` repo and reach users as signed, versioned
  installs. The install pipeline streams the artifact
  (`Net.StreamDownload`), sha256-checks it, runs `cosign verify-blob` with
  the certificate identity pinned to
  `release-plugin.yml@refs/tags/<name>/v<version>`, guards the archive
  against traversal/symlink/zip-bomb attacks, enforces a content boundary,
  decodes the manifest, verifies the `h1` hash, and atomically activates
  into a versioned store under `$FERMIX_HOME/plugins` (cross-VM lock,
  pin/rollback/gc, `SafeRm`-disciplined deletes). Modules under
  `FermixCore.Plugins.Dist.*` (`Installer`, `Store`, `Archive`, `Index`,
  `Lock`, `Verifier.Cosign`).
- Static plugin catalog: `apps/fermix_core/priv/plugins/index.json` is
  checked into the repo and shipped inside the release binary as the only
  catalog source — no remote index, no refresh, no boot-time refresh, no
  downgrade guard. New plugins reach users with the next Fermix release.
  `scripts/release/sync_plugin_catalog.py` regenerates the catalog from
  `fermix-plugins` releases and downloads, sha256-checks, and
  cosign-verifies every artifact pin it writes.
- Two plugin execution rails. Declarative HTTP rail: a template-grammar
  interpreter (`FermixCore.Plugins.Http.*` — `Template`, `Interpreter`,
  `ParamSchema`, `Extract`) with a param schema, SSRF floor, bounded
  pagination, and response extraction; the Google manifests are now
  expressed as in-VM HTTP templates (`ToolExecutor` shrinks 1042 -> 827
  lines). MCP rail: `Dist.McpSource` materializes server specs,
  `MCP.Supervisor.reload/0` starts/stops the per-plugin child (disable
  stops the process), a host-runtime probe gates install, and a `Status`
  ladder (`:not_installed` / `:incompatible` / `:missing_host_runtime` /
  `:needs_config`) surfaces readiness in the prompt catalog.
- `fermix plugins` CLI verbs: `install`, `installed`, `uninstall`,
  `upgrade`, `pin`, `gc`, and `config`, plus a `plugins_apply` daemon
  control-socket method so a running daemon reloads after a change.
  `fermix doctor` gains plugin checks.
- Setup-page plugin catalog: cards with inline logos, install-on-connect,
  and per-stage error prose. Per-plugin manifest config entries are
  collected at Connect time (web form / `fermix plugins config set`),
  persisted to TOML, and injected into the plugin env. A
  `[fermix_core.plugins] dev_local` author loop lets plugin developers
  point at a local build.

### Added — Plugin OAuth Providers (M8 §9.1)
- OAuth provider registry on the existing PKCE-loopback engine
  (`FermixCore.Auth.OAuthProviders`): `google`, `github`, and `notion`
  provider definitions. GitHub uses `Accept: application/json`,
  comma-separated scopes, and a port-wildcarded loopback; Notion uses HTTP
  Basic-auth token exchange on fixed loopback port 1458. Refresh dispatch
  is deduplicated through the registry, client secrets are keychained via
  `SecretPaths`, and the setup page renders a per-provider OAuth-client
  form. `oauth2` manifests may declare empty scopes for page-picker
  providers.
- X (Twitter) OAuth provider so the X HTTP-rail plugin (`x/v1.0.0`)
  connects through the PKCE-loopback engine: `x.com` authorize, `api.x.com`
  token, HTTP Basic confidential-client exchange, fixed loopback port 1459,
  redirect host `127.0.0.1` (X's portal accepts the IP, not `localhost`).
  Added to `Config @registry_oauth_providers`, an `X_OAUTH_CLIENT_SECRET`
  keychain path, the setup-page provider list (display "X", port 1459) with
  OAuth help tooltip, and an agent plugin-surface steer (`x_*` owns
  X/Twitter, not the browser).

### Added — Wave-1 Plugins (M8.1)
- Wave-1 plugins published to the bundled catalog: `github`, `notion`,
  `obsidian`, and `x`. The catalog was re-synced across the release to
  track upstream releases — Obsidian gained a branded card logo (1.0.1),
  then a cleaned-up logo (1.0.2), and GitHub/Notion/Obsidian (1.0.3)/X
  picked up clearer, more token-efficient tool and skill descriptions. Each
  pin is re-downloaded and cosign-verified by the sync script.

### Added — Scheduled Agents (M4.11)
- Scheduled jobs can be bound to an existing skill at create time
  (`schedule_job` `skill_name`), so the future run executes inside that
  skill's tool/policy confinement — its `allowed_tools` and capability
  policy are intersected with the job's, never widened; `Jobs.Runner`
  enforces the intersection and unknown skill names are rejected up front.
- New scheduled-job tools: `run_job_now` fires a job immediately and out of
  band through the same isolated runner (trigger `manual`) while leaving the
  timed cadence untouched, refusing a paused, disabled, expired, or
  already-running job (atomic claim via `Repo.claim_job_now`);
  `list_job_runs` and `get_job_run` read a job's execution history and one
  run in full (status, trigger, timing, prompt snapshot, token usage,
  outcome); `skill_reload` re-scans the skill directories and refreshes the
  running agent in place — reporting added/removed/changed names and load
  errors — without restarting the daemon.
- `list_jobs` payloads now include `task_prompt` (the job's current
  instructions) and `get_job_run` includes the `task_prompt` the run
  actually executed, sourced from the run's recorded `job_config_snapshot`
  so it reflects the instructions at run time rather than the
  possibly-since-edited current text (runs recorded before this change
  return null). The agent no longer has to read `scheduled_jobs.task_prompt`
  straight out of `memory.db`.

### Added — Prompt (Stale-failure guard)
- A `FERMIX.md` operating rule so the agent treats a failure it reported
  earlier as possibly-already-fixed: it checks live state before re-running
  something that failed, and if it cannot confirm the failure was resolved
  it flags what failed last time and asks rather than blindly retrying.
  Closes the narrow cross-turn gap where a narrated failure survives in the
  verbatim recent window with no latest-state-wins principle.

### Changed — Provider Expansion (M12)
- Fail-loud config validation: unknown keys in a
  `[fermix_core.providers.*]` TOML block and an unknown legacy
  `[fermix_core.agent] provider` now stop boot with a clear message instead
  of being silently dropped; an unknown readiness provider is a visible
  setup failure instead of silently coercing to `openai`; scheduled-job
  provider *atoms* are validated like strings.
- `/health` now reports one entry per configured provider (with the primary
  flagged) instead of a hardcoded single `openai` card, and ChatCompletions
  error/telemetry attribution follows the routed provider (OpenRouter/Ollama
  calls are no longer mislabeled `openai`).

### Changed — OpenRouter Setup Picker
- The OpenRouter setup model picker is now searchable and vendor-sorted:
  the live upstream list is sorted by id so same-vendor models cluster
  (`anthropic/*`, `openai/*`, `x-ai/*`, …) instead of newest-first, and the
  `<select>` is replaced by a free-text `<input>` + `<datalist>` so you can
  type to filter by id/label or enter any custom slug. `phx-debounce="blur"`
  keeps keystrokes client-side so the form doesn't re-fetch the catalog per
  letter.

### Changed — Scheduled Agents (M4.11)
- The 5-field cron parser now accepts comma lists (`1,15`), ranges (`9-17`),
  and steps (`*/15`, `8-18/4`) per field, with weekday `7` and `0` both
  meaning Sunday; out-of-range or malformed fields are rejected at creation.
  Schedule descriptions and the canonical example move to the cron form
  (`0 8 * * *`), and free-form English like "daily at 8am" is now rejected.
- `update_job` gains in-place editing of the delivery route (`delivery_mode`
  `none` / `origin` / `channel` / `local` + `delivery_target`) and skill
  rebinding (`skill_name`). Omitted delivery is left unchanged; switching to
  `none` / `local` clears a stale target; unknown skill names are rejected.
- Recurring jobs whose fire time was missed while the daemon was down are
  now skipped instead of running at a wall-clock far from their schedule: a
  due time older than `[fermix_core.jobs] run_freshness_window_seconds`
  (default `3600`) is skipped and the schedule advanced to the next future
  occurrence (logged). A one-off `once` run has no next occurrence, so it
  runs late rather than being dropped.

### Changed — Memory Taxonomy Redesign
- Memory category vocabulary moves to a six-category general-assistant
  spine. USER.md now holds `identity`, `preference`, `interest`, and `goal`
  (facts about the owner); MEMORY.md holds `context` (durable working
  knowledge) and `directive` (behavior-shaping rules), replacing the old
  domain-skewed `project` / `environment` / `instruction` / `correction` /
  `episode` set. `Admission.promotable_category?/2` is the single source of
  truth for which categories each bucket accepts, and `:guest`-trust callers
  can no longer promote `directive` rows into durable memory. The reviewer
  system prompt is rewritten to describe the new taxonomy and steer toward
  keeping memory current (replace/archive/generalize) instead of
  append-only growth.
- Memory prompt files are bounded by per-section row caps
  (Identity/Preferences/Interests 6, Goals 5, Context 12, Working Rules 8)
  plus a 200-char value truncation, keeping the newest rows and logging a
  warning when older rows are dropped. Unknown categories are dropped rather
  than bucketed into a catch-all section, and rendered items now show the
  fact itself instead of the internal dedup key. Per-file prompt token caps
  raised to match the wider spine (`@prompt_user_token_cap` 800 to 1500,
  `@prompt_memory_token_cap` 1600 to 2000).
- Transactional DB migration v10 folds legacy memory rows forward in place:
  `project` / `environment` become `context`, `instruction` / `correction`
  become `directive`, and retired `episode` rows are tombstoned via
  `archived_at` (recoverable, not deleted). FTS triggers and the scope-key
  UNIQUE index are preserved across the migration.

### Changed — Memory Review Hygiene
- The daily memory reviewer prompt gains principle-level rules: write each
  value as a declarative fact about the user or their work (not a
  self-instruction), and on a correction replace or archive the existing row
  by id rather than appending a duplicate (latest statement wins). Review
  excerpts are now labelled as user-sent messages only (the agent's own
  replies are not shown) so a correction is not misread as a fresh fact.
- The per-turn memory prompt now logs a warning when rows are dropped to fit
  the char/token cap, replacing the previously silent eviction.

### Changed — Observability (fermix_opik in umbrella)
- `apps/fermix_opik` joined the umbrella (moved in from `fermix-plugins`
  per M8 §14.3) and is inert until `FERMIX_OPIK_ENABLED`. Background
  `memory_reviewer` writes are now observable: each durable op emits
  `[:fermix, :memory, :write]` via `ReviewTools`, threading
  `session` / `channel` / `chat_id` / `parent_session` through `Reviewer`,
  routed as a `tool_exec` span and aggregated in `fermix_opik` (point
  `memory_write` span + `thread_id` backfill so reviewer runs correlate by
  thread even after the parent turn closes).

### Changed — Secrets (Profile-scoped keychain)
- Keychain secrets are now scoped by an optional `[fermix_core] profile`
  (default `general`) so two installs on one machine (e.g. `~/.fermix` and
  `~/.fermix-dev`) no longer share one keychain entry per secret and resolve
  each other's tokens — a collision that surfaced as a Telegram 409 Conflict
  with both pollers on one bot. `general`/unset keeps the bare
  `fermix:<ENV>` coordinate (existing installs need no migration); a named
  profile uses `fermix:<profile>:<ENV>`. The profile is read from the
  snapshot being resolved/saved (correct at boot, before app env is
  populated) and threaded through `SecretStore` into `SecretWriter`, and is
  wired through the config parse/persist/dump/apply round-trip.

### Changed — Setup UI & Branding
- Setup wizard and operator console retheme: pitch-black/white/grey surface
  with a single Fermix-blue (`#2b5cff`) accent across the daisyUI light/dark
  tokens, shared verbatim by `/setup` and `/`. Dark theme darkened toward
  pitch black (base-100 14%->9%, surfaces and hairline borders lowered
  proportionally). The green-screen-removed ghost mascot and an inlined
  currentColor wordmark replace the old green logo; `fermix_wordmark` is
  promoted to shared `CoreComponents` and used in setup and homepage headers
  (drops the "Fermix" eyebrow, "Agent runtime ready", and "Guided
  onboarding" copy). New monochrome app-icon favicon (256px `favicon.png` +
  multi-res `favicon.ico`, black rounded tile / white ghost) replaces the
  blue tile.
- OAuth integrations in setup replace the always-visible
  client-id/secret/port boxes with a Connect/Edit modal. Google
  (multi-plugin) keeps a shared client row; single-plugin providers
  (GitHub/Notion/X) render as one card like Obsidian with the OAuth client
  folded in. Form panes gain an "Unsaved changes" hint.

### Changed — Release / CI
- 0.3.0 release line: umbrella + `fermix_core` / `fermix_channels` /
  `fermix_web` / `fermix_nif` bumped to 0.3.0 (started as `0.3.0-beta`,
  `-beta` dropped at finalize; `fermix_opik` keeps its own 0.1.0
  lifecycle). CI now runs compile/format/credo/test on `release/**`
  branches, not just main/dev. `release.yml` publishes pre-release tags
  (SemVer `-` segment, e.g. `v0.3.0-beta`) as GitHub pre-releases and skips
  the Homebrew tap bump so a beta never marks itself Latest or promotes into
  the brew formula; stable tags are unchanged.

### Removed — Provider Expansion (M12)
- `together` / `groq` accepted-but-unroutable provider strings (no resolver
  ever existed; OpenRouter covers those vendors' models).

### Removed — Model Catalog
- `claude-opus-4-7` (display "Claude Opus 4.7") dropped from the Anthropic
  model catalog and its max-output map; the selectable Anthropic models are
  now the 4.8 line, and test fixtures pinned to 4.7 move to
  `claude-opus-4-8`.

### Removed — Secrets (Telegram env overlay)
- Removed the `TELEGRAM_BOT_TOKEN` env overlay from `runtime.exs`. The bot
  token is a config-owned secret, and a stray exported var could shadow
  every install's per-config token (an env-beats-config fallback); it now
  resolves only from `config.toml`. Telegram readiness remediation now
  points operators at `fermix setup` / `config.toml` instead of the removed
  env var.

### Fixed — Provider Expansion (M12)
- Cron jobs now fire in the job's own timezone (DST-aware via the `tz` dep)
  instead of UTC, and unknown zones are rejected at creation. `fermix
  doctor` validates routing `subagent_model` / `cron_model` against the
  catalog, ChatCompletions threads `reasoning_effort` onto the request body
  and call telemetry, and the jobs runner records `route_used` from the
  already-resolved route (a second resolution that could re-raise and strand
  the run on the failure path is gone). `OAuthProvider` redacts
  `client_secret` on inspect and the secret temp dir is created `0700`.

### Fixed — Mistral Provider
- ChatCompletions now omits the `content` key (rather than sending an empty
  string) on assistant messages that carry `tool_calls`. Mistral's strict
  validator 422s on empty-string `content` alongside `tool_calls`; the
  omission produces one wire shape valid on Mistral, OpenAI, OpenRouter, and
  Ollama. A real non-empty preamble is preserved.

### Fixed — Sub-agent & Cron Model Selection
- Saving a provider in setup no longer promotes the edited provider to
  primary (model/effort previously wrote to the primary's block) — writes
  land on the edited provider, and only the first configured provider
  auto-promotes; others stay fallbacks until "Set primary". The api-key
  secret writers (`put_openai_secret` / `put_anthropic_secret`) no longer
  replace the whole `[fermix_core]` config with only `:providers`, which had
  wiped routing/personalization/etc. on api-key saves; both now delegate to
  the shared `put_provider_secret`.

### Fixed — Scheduled Agents (M4.11)
- Scheduled runs firing as the host wakes from sleep no longer fail
  permanently on a Finch pool-checkout queue timeout. The timeout is now
  classified as a typed `:connection_unavailable` transport error
  (deliberately excluded from `Providers.Failover` fallback kinds — it is
  terminal for a single route, so the cron runner owns recovery and re-runs
  with bounded exponential backoff). A new `FermixCore.Net.Readiness` runs a
  short, bounded TCP-connect probe to the run's primary route host before
  the first model call, gated by `[fermix_core.jobs]
  network_readiness_enabled` (default true) and skipped when the run has no
  route host.
- Wake-from-sleep pool-timeout recovery is now provider-agnostic:
  `Jobs.Runner` recognizes the bare Finch `%RuntimeError{}` returned by the
  non-Codex adapters (previously only the Codex adapter minted the typed
  `:connection_unavailable` the runner keys on, so cron runs on
  Anthropic/OpenAI/xAI failed permanently on the identical condition). Each
  newly started run also waits a capped startup delay (250ms per
  already-active run, ≤5s) before its first network call so a batch of jobs
  due in the same minute doesn't check out HTTP connections all at once, and
  channel delivery retries with bounded backoff on the same transient pool
  timeout (a checkout timeout never sent, so the retry can't duplicate).

### Fixed — Memory Review Hygiene
- The background memory reviewer no longer persists the agent's own behavior
  or one-off exchanges as durable memory. It previously minted safety
  refusals as `directive` Working Rules and one-shot Q&A answers (e.g. a
  FizzBuzz answer) as `context`. The reviewer prompt restores the
  anti-inference clause and skip-list named by provenance: the agent's own
  refusals and guardrail rules, the substance of a declined or
  instruction-overriding request, and one-shot answers the user did not ask
  to keep are no longer saved. The `directive` category is tightened to a
  standing rule the user set, never the agent's own defensive stance.

### Fixed — Plugin Distribution (M8 / M8.1)
- Connecting a not-yet-installed GitHub/Notion catalog card flashed "Save a
  <Provider> OAuth client first" with no form to do so — the OAuth client
  forms were derived only from installed plugins and catalog entries did not
  carry the auth provider. `auth_provider` now flows end to end (sync script
  -> seed -> `Index.parse` -> `Catalog.available_entry` -> card), and the
  provider client form renders for catalog-only `oauth2` providers.
- HTTP-rail plugins no longer reject stringified object/array params. LLMs
  serialize freeform object/array tool args as JSON strings, which
  `ParamSchema`'s `is_map` / `is_list` checks rejected (e.g. Notion
  create-page "invalid parameter: parent"). A JSON-string value is now
  decoded to a map/list when the param is declared `object` / `array` and
  the string decodes to that type; otherwise it is left untouched so
  `check_type` still fails loud — a single deterministic path with no
  fallback.

### Fixed — Resilience (Un-encodable tool output)
- Tool output containing invalid UTF-8 (e.g. a `0xF3` byte from a scheduled
  run, a Latin-1 file read, or raw command bytes) no longer crashes the run.
  The text agent loop scrubs every captured tool result through
  `String.replace_invalid/1` at the single provider-agnostic seam
  (`AgentLoop.execute_tool_calls/2`) so invalid bytes become U+FFFD and the
  request body stays JSON-encodable across all providers; the Realtime voice
  run-type's separate dispatcher (`Realtime.ToolBridge.execute_call/2`),
  which never passed through the text path's sanitizer, now deep-scrubs the
  binary leaves of the whole result map before `Jason.encode!/1` so an
  invalid byte can no longer crash a live `SessionServer` turn.

### Fixed — Resilience (Trace encoding never crashes)
- The `Trace` GenServer no longer crashes on un-encodable trace content. It
  previously `Jason.encode!`'d each entry raw, so invalid UTF-8 in captured
  tool output or a PID/ref/struct with no encoder raised inside
  `handle_cast` — and because `Trace` is a `rest_for_one` ancestor of
  `MainAgent` and the job supervisors, that crash cascade-restarted them and
  could take down in-flight runs. Encoding is now defensive at the boundary:
  invalid UTF-8 in binary leaves is scrubbed and retried, still-unencodable
  entries are dropped-with-log (rescuing exactly the JSON-encode exception
  classes), and `json_safe/1` is hardened so a struct in telemetry metadata
  can no longer crash `Map.new` in the emitting process and permanently
  detach the telemetry handler.

### Fixed — Resilience (Finch pool exhaustion)
- A starved Finch connection pool no longer crashes an agent turn. On a
  checkout queue-timeout Finch reraises a `RuntimeError` ("unable to provide
  a connection within the timeout due to excess queuing") rather than
  returning an error tuple, so a transiently starved pool (e.g.
  api.telegram.org via the typing indicator) aborted the whole turn,
  surfacing only as the generic "I encountered an error processing your
  message". `Net.HttpClient` now wraps the request in `run/2`, rescuing that
  pool-exhaustion `RuntimeError` and returning it as the
  `{:error, Exception.t()}` its `@spec` already promises — fixing the one
  request instead of the calling process across every caller (typing, sends,
  provider calls, plugins, all channels). Pool exhaustion is deliberately
  not retried; genuine programming errors still crash loud.

### Fixed — FermixPet (macOS voice companion)
- FermixPet `.app` is now signed with a stable self-signed identity
  (auto-created if missing, fails loud with no ad-hoc fallback) so the
  microphone TCC grant keeps matching across rebuilds — previously ad-hoc
  signatures changed cdhash on every build, silently revoking mic capture
  and dropping the call back to idle. The SwiftPM resource bundle is staged
  under `Contents/Resources` for a codesign-valid layout, and
  `FermixPet.icns` is regenerated from the app-icon PNG so the system mic
  indicator and Finder match the dock icon.

### Fixed — Telemetry / Opik export
- Opik no longer exports near-empty traces during `mix test`.
  `FERMIX_OPIK_ENABLED=1` in the developer shell switched the exporter on
  inside `:test` because the sibling `fermix_opik` umbrella app booted there;
  `FermixOpik.enabled?/0` now gates on the compile-time env
  (`@compiled_env != :test and enabled_by_flag?()`), so the flag can never
  turn export on inside a test run. Compile-time capture stays release-safe.

### Fixed — Setup UI & Branding
- Setup flash-banner text now adapts per theme (`text-error` / `text-success`
  instead of `*-content`, which was invisible on the faint tint);
  `set_primary` resets the sub-agent model to same-as-main and is confirmed
  for OpenRouter/Ollama; the confusing empty-catalog line is dropped and the
  topbar uses the brand blue. Fixed the OAuth modal's missing gap between the
  redirect-port field and the Save button.

### Security — Plugin trust-boundary containment
- Three plugin/sandbox containment fixes from the dual-repo security review.
  `Sandbox.PathPolicy` now resolves each path component to its real on-disk
  case (`real_case/2`) so a case-variant like `~/.SSH` can't slip past the
  protected-path check on case-insensitive filesystems (macOS) while still
  landing on the real `~/.ssh` inode — the path checked is now the path
  touched, with exact matches winning on case-sensitive filesystems.
  `Plugins.Registry.validate_runtime_block` now requires a bare executable
  name (no whitespace, `/`, or `..`) so a `vendored: true` MCP command can't
  `Path.join`-escape its `bin/<target>/` dir to a host executable like
  `/bin/sh`, and `validate_asset` bounds the manifest asset path inside the
  plugin dir via `Path.safe_relative`, refusing `../` escapes before the
  read.

## [0.2.3] - 2026-06-08

### Added — FermixPet (macOS voice companion)
- FermixPet build script gains an `install` mode
  (`./script/build_and_run.sh install`): builds the SwiftPM `.app` bundle in
  release configuration under `~/Library/Caches/io.tezra.FermixPet` and
  installs it to `~/Applications/FermixPet.app`, with `FERMIXPET_*` env
  overrides for cache/stage/install paths and configuration. Docs now point
  operators at installing the app rather than running it from source.

### Changed — Setup UI
- Provider and Channels setup tabs reworked into a card selector that loads a
  single "Configuring …" form. Provider cards carry the primary flag (Save
  sets primary; a "Set primary" action flips it among configured providers);
  channel cards are a plain selector with no primary concept. "Apply &
  restart" now returns to the tab you were on (mount honors `?tab=`,
  apply_restart push_patches the active tab across the restart) instead of
  bouncing to the first incomplete tab.

### Fixed — Setup UI
- Saving a Realtime API key no longer steals the primary flag from an
  explicitly chosen provider: the Realtime key shares the OpenAI provider key
  slot, but a realtime-only save no longer counts as a provider-configuring
  promotion trigger.

### Fixed — FermixPet (macOS voice companion)
- FermixPet now fully releases the microphone on call end, disconnect,
  peer-close, and error so macOS clears the mic privacy indicator as soon as
  the local call ends — teardown is unified through a single
  `shutdownAudio()` (calls `audio.shutdown()` and zeroes `audioLevel`)
  instead of leaving the engine/tap warm between calls. Right-click "Quit
  FermixPet" now routes through `quitApplication()`, shutting audio and the
  socket down before terminating.
- The Realtime voice session no longer reports "listening" before the
  provider is ready. `Realtime.SessionServer` tracks a `provider_ready?` flag
  and waits for the upstream `session_updated` event before starting timers
  and notifying the companion to listen, so the pet's listening state matches
  when the provider can actually receive audio (also reset across reconnect
  attempts).

## [0.2.2] - 2026-06-07

### Fixed — Setup (Web wizard OAuth)
- Completing a provider's OAuth in the web setup wizard now persists it as
  primary immediately. Previously the OAuth-completion handlers wrote the
  credential but never the primary flag, so a connect-then-probe flow left no
  config pointer and the end-of-setup probe fell back to its `:openai`
  default and reported "provider not configured" (re-saving the provider step
  fixed it) — worst for `openai_codex`, whose completion persisted no config
  at all, while xAI/Anthropic wrote `auth_mode` but no primary. New
  `Wizard.mark_primary/1` (mirrors `set_provider_auth_mode/2`, reading the
  current snapshot so it can't clobber the auth_mode the login flow just
  wrote) routes all three OAuth-completion handlers (codex/xai/anthropic)
  through it; idempotent with a later save.

## [0.2.1] - 2026-06-07

_Maintenance release — hermetic CI test fixes; no user-facing changes._

## [0.2.0] - 2026-06-07

### Added — Providers (xAI & Anthropic)
- xAI (Grok) and Anthropic (Claude) as first-class providers with API-key and
  OAuth auth modes: route resolver, readiness, doctor, CLI wizard, and web
  setup support; model catalog + reasoning-effort vocabularies; env overlays
  in `runtime.exs`; and `fermix auth login --provider xai|anthropic`.

### Added — Primary-Provider Selection & Failover
- Per-provider `primary` flag in config selects the main provider (replacing
  the legacy `[fermix_core.agent] provider` key, migrated forward; multiple
  primaries are a surfaced config error). `Providers.PrimaryConfig` owns the
  migration and `mark_primary_provider/2` gives the wizard radio semantics
  with auto-promotion of newly configured providers. Status, doctor, jobs,
  and agents all consume one ordered route chain [primary | configured
  fallbacks].
- Bounded provider failover: `Providers.run_chain/3` is the one executor used
  by the agent loop's initial chat, compaction (auto/preflight/`/compact`),
  and memory review, with eligibility keyed on `Providers.Error` kinds (OAuth
  residual 401/refresh-failures eligible; API-key auth and OAuth 403
  terminal). A `[:fermix, :provider, :failover]` telemetry event is emitted
  per transition, and `fermix doctor` lists fallback availability.

### Added — Work-Control Commands & /ultra
- Gateway work-control command surface: `/stop` (owner-only emergency halt of
  active and pending turns, leaving scheduled jobs and voice untouched) and
  `/background`, `/bg`, `/tasks` for detached work via `Gateway.WorkRegistry`
  + `Gateway.BackgroundSupervisor`, with `FermixCore.Agents.BackgroundRun`
  providing work-scoped history/memory isolation. `Commands.Registry.validate!/0`
  now guards against duplicate command names/aliases at boot.
- `/ultra` exhaustive run-mode: an `/ultra <prompt>` turn tags
  `run_profile: :ultra` to widen the `subagents` caps (`subagent_mode: :ultra`)
  and prepend an exhaustive-mode addendum so workers nest under the parent
  trace. Began as a fixed-topology `UltraOrchestrator` (decompose -> fan-out
  -> verify -> synthesize) and was folded into a run-mode of the normal agent
  turn before release.

### Added — Telemetry Contract
- Telemetry contract with shared emitters (`Tools.Telemetry`,
  `Providers.Telemetry`, `Jobs.Telemetry`), `session_id` correlation across
  agent/provider/tool events, and content-capture gating via
  `FERMIX_TRACE_CONTENT` / `FERMIX_OPIK_ENABLED`; documented in
  `docs/TELEMETRY_CONTRACT.md`.

### Added — Channel Streaming
- Live streamed replies into chat channels via
  `[fermix_channels.<name>] streaming = "off" | "draft" | "block"` (off
  default). Draft mode edits one message in place (~1 Hz, 30-char open
  threshold, 300-edit cap); block mode posts each completed model thought
  (and reasoning-summary heading) as its own message with fence-safe
  paragraph chunking. A new channel-agnostic `Gateway.DraftStream` engine
  drives it over an optional open/edit/seal/discard_draft + stream_capability
  channel contract (Telegram implements draft editing; block mode rides
  ordinary sends on every channel). The Codex `SSEParser` gains a
  `delta_callback` emitting `{:text_delta, ...}` / `{:text_done}` /
  `{:reasoning_done, summary}`, and `AgentLoop` / `TurnRunner.run/4` thread a
  `stream_callback`. Emits `[:fermix, :channel, :stream]` telemetry
  (session-correlated, ttfd) and `fermix doctor` warns on draft without the
  channel capability.

### Added — Prompt (Current date)
- A fresh "Current date" system note is injected ahead of conversation
  history on every main turn (`TurnRunner`) and scheduled job run
  (`Jobs.Runner`) via the new `FermixCore.Prompt.CurrentDate` module, sourced
  from the personalization timezone. Date-only by design so the provider
  prompt-cache prefix stays stable (agents call `run` for the precise time).
  Setup now defaults the timezone to `America/New_York` (CLI wizard + web
  form) so the stamp always has a zone, and the `FERMIX.md` guidance that
  told the agent to shell out for the date is softened.

### Added — Setup Secrets (Secure-on-save)
- `FermixCore.Setup.SecretStore` consolidates the three duplicated snapshot
  path-walkers (ConfigStore, SecretMigration, Wizard) and owns
  secure-on-save: any plaintext value registered in `SecretPaths` is written
  through `SecretWriter` and persisted as a `@keyring` sentinel when a writer
  is available. Rotation over a `@keyring` sentinel rewrites the keyring
  instead of silently dropping the new value; writer-less hosts keep
  already-persisted plaintext unchanged while new/changed secrets still fail
  loud. `GOOGLE_OAUTH_CLIENT_SECRET` is registered in `SecretPaths`.

### Added — Browser Runtime
- Native first-party CDP browser runtime (`FermixCore.Browser.*`) replacing
  the agent-browser CLI wrapper: OTP-supervised Chrome driven over the
  DevTools Protocol, per-conversation scoped profiles (hashed
  `conversation_key`) with a live-instance cap, LRU eviction, and idle-sweep
  reclamation, re-attach to an already-running Chrome for a profile (fixes the
  "Opening in existing browser session" failure after daemon restart),
  guaranteed teardown (terminate + SIGTERM/SIGKILL of the Chrome os_pid,
  orphan reaping, launch-failure cooldown), an SSRF URL policy (incl.
  IPv4-mapped/compatible/NAT64 IPv6), accessibility-first snapshots with
  depth budgeting and editable-field refs, plus screenshots, actions,
  downloads, dialogs, redacted cookies, and PDF. All timeouts/limits live in
  `Browser.Config`; per-action latency and Chrome stderr land in
  `tool_exec` / `agent_event` traces. Adds a `browser_guidance` skill and a
  `browser` workspace path.

### Added — Agent Iteration Limits
- `FermixCore.Agents.IterationLimits` adds bounded iteration caps for
  agent-loop entry points (`interactive` / `subagent` / `scheduled_job_default`,
  default 100), read from `[:fermix_core, :iteration_limits]`. Hitting the cap
  now yields a clear "hit the investigation step limit" channel reply instead
  of the generic error.

### Added — Google Plugins (Write tools)
- Write tools across the Gmail, Calendar, and Drive first-party plugins on a
  graceful-error foundation: a ready plugin's tools register regardless of
  granted scope, and a call-time pre-flight check returns reauthorize guidance
  before any API call instead of the tool silently disappearing. 403s are
  classified by Google's reason (scope-insufficient, file-permission,
  organizer-only, rate-limit) so the message says what actually failed. Gmail
  (+gmail.compose, +gmail.modify) adds reply_to_thread, create/send draft,
  modify labels, trash/untrash, create label, and surfaces
  Message-Id/References for threaded replies; Calendar adds update, delete,
  RSVP, and move; Drive adds create folder, upload, rename, move, and copy.
  Destructive ops are `read_only: false` with prompt-driven confirmation in
  each plugin SKILL.

### Changed — Setup Hardening
- Provider `auth_mode = "oauth"` now persists through config instead of being
  normalized to nil (which silently fell back to API-key mode). Setup also
  suppresses the Codex token import when a non-codex provider is explicitly
  selected, and wires xAI through the web setup provider form
  (parse/normalize/models + reasoning-effort field guard).

### Changed — Provider Error Handling
- Provider errors are normalized through a typed `Providers.Error` (kind +
  stage, OAuth tagging): Codex/OpenAI retry and error surfacing hardened, a
  dead/missing `TokenManager` degrades to a failover-eligible auth error
  instead of crashing the loop, and `TurnRunner` no longer string-matches on
  Codex error copy.

### Changed — Web Search
- `web_search` degrades once to the keyless DuckDuckGo backend when a
  configured non-DuckDuckGo backend (Brave/Exa/Tavily/...) hard-errors on a
  service condition (out of credits/HTTP 402, provider errors, rate limits,
  transport failures, response-schema drift), so a dead paid provider no
  longer breaks web research. The degrade is loud — a warning log plus
  `degraded` / `primary_backend` / `fallback_reason` in the result metadata
  (carried on the tool trace). Auth/missing-key and bad-query errors are not
  degraded; the fallback is bounded to one attempt and DuckDuckGo's own
  failure surfaces the original backend's error.

### Changed — Google Plugins (Drive scope)
- The Google Drive plugin now requests the full `drive` scope (search keeps
  `drive.metadata.readonly`) to enable create/edit/organize/copy operations.

### Changed — Observability (fermix_opik gating)
- The `fermix_opik` exporter path dep is gated behind a single
  `FERMIX_OPIK_ENABLED` switch (and scoped to `only: [:dev, :prod]`), so
  default/standalone/CI builds omit it (lock unchanged) and `mix test` never
  bundles the exporter or ships test fixtures to a live Opik project. The same
  flag gates the runtime content-capture default.

### Changed — CLI / provider tidy
- `cli/chat_command` stringifies atom error reasons in the JSON envelope;
  `main_agent` maps `FermixCore.Providers.XAI.Responses` to `:xai`;
  `jobs/runner` derives the provider atom from `ModelCatalog` (dropping
  per-provider clauses). Default and test CDP port ranges shifted in
  `Browser.Config`.

### Fixed — CLI auth (route activation)
- `fermix auth login --provider xai|anthropic` now also sets that
  provider's config `auth_mode = oauth` (and `fermix auth logout` reverts
  it to `api_key`). The stored OAuth token was previously inert —
  `RouteResolver` keys on `[providers.<p>].auth_mode`, so a freshly
  connected provider stayed in API-key mode until the operator flipped it
  by hand. Login and logout now keep the token and the route in sync.

### Removed — Google Plugins (Trimmed surface)
- Dropped the Calendar quick-add (`google_calendar_quick_add_event`) and the
  Drive share/trash/delete (`google_drive_share_file`,
  `google_drive_trash_file`, `google_drive_delete_file`) tools from the Google
  plugin manifests and skill docs; `response_status` is now constrained to an
  enum.

### Fixed — Long-lived HTTP connections
- Supervised shared Finch pool with a 15s idle cap so long-lived daemons drop
  load-balancer-RST'd keep-alive sockets instead of failing requests with
  `:closed`.

### Fixed — OAuth Loopback Catcher
- The loopback OAuth callback server no longer aborts the flow on the first
  non-callback connection (surfaced as "Grok sign-in failed:
  :malformed_request" on xAI's cold ephemeral port). `Auth.OAuthFlow` now
  accumulates the full request line (bounded by per-read timeout, 64 KB cap,
  and overall deadline) and skips junk/segmented connections until the real
  callback or the deadline; genuine callback errors (state mismatch, missing
  code, OAuth error param) stay terminal.

### Fixed — Channel Streaming
- Hardened streaming against mid-stream Codex retries: block mode no longer
  crashes (negative `binary_part`) when a dropped connection is retried with a
  fresh SSE parser and cumulative text restarts shorter than the consumed
  offset (`unsent/1` clamps and resumes once the stream regrows); draft-mode
  seal retries on Telegram `retry_after` are now bounded (~11 s worst case) so
  they no longer outlast the engine's 15 s seal timeout, falling through to
  the designed discard-and-redeliver recovery instead of orphaning the draft
  and duplicating the answer.

### Fixed — Setup Secrets (Secure-on-save)
- Sandbox env command sources now reuse the writer's own lookup args
  (`-a fermix -s fermix:<ENV>`) instead of the old inline `-a $USER -s <ENV>`,
  which could never find what `put()` stored.
- secure-on-save now writes only on a positively-confirmed rotation, never on
  a keychain read failure. `keep_or_rotate` previously lumped a genuine
  rotation in with a locked/timeout/unavailable read under one branch that
  escalated to a write, so a transient read failure on an already-`@keyring`
  secret could error the whole `save_snapshot` and couple unrelated config
  commits (model_routing_config, `/sandbox grant`, plugin enable) to keychain
  health. A read error now keeps the sentinel and lets the save succeed; the
  rotation is re-detected once the keychain is reachable.

### Fixed — Daemon control socket
- Daemon control-socket replies larger than the inet line buffer (e.g.
  `/ultra` output, the enlarged `self_knowledge` skill body pushing
  `skills_view` past ~9 KB) no longer truncate mid-stream into a
  `Jason.DecodeError`. First fixed in the client with a bounded `recv_line`
  loop accumulating chunks to a trailing newline (4 MB cap, fails loud as
  `:response_too_large`), then the framing was switched from `{:packet, :line}`
  to `{:packet, 4}` length-prefixing on both ends so a reply arrives whole,
  with `{:packet_size, 4MB}` bounding each frame (a skewed/corrupt header
  fails instantly with `:emsgsize` instead of buffering to timeout) and decode
  failures reporting `response_decode_failed`.

### Fixed — Gateway queue
- The gateway queue no longer mislabels ordinary turns as `:crashed` under
  load. `Process.monitor` ran after `Task.Supervisor.start_child` returned, so
  a near-instant turn could exit before being monitored, yielding
  `{:DOWN, …, :noproc}` mapped to `:crashed`. The task now parks in
  `await_run_signal` and the queue releases it only after monitoring — closing
  the race (185/200 turns mislabeled on the old code, 0 with the fix).

### Fixed — Path resolution (empty FERMIX_HOME)
- A blank `FERMIX_HOME` (`""`) is now treated as unset across path resolvers.
  It was truthy in Elixir, so `get_env() || default` did not fall back and
  `fermix_home` resolved to `""`, making every workspace path cwd-relative
  (booting from the repo root seeded bundled skills into `./skills` instead of
  `~/.fermix/skills`). Blank is now coerced to unset in the canonical
  `ConfigStore.fermix_home/0`, `runtime.exs`, and the two sandbox resolvers;
  CLI/service route through the canonical one.

### Fixed — Service unit (Homebrew)
- The launchd/systemd service unit is now pinned to the stable Homebrew
  `<prefix>/bin/<name>` symlink instead of the versioned Cellar path, so
  `brew upgrade` (which removes the old Cellar path) no longer strands the
  service unable to start. Non-Cellar paths pass through unchanged.

### Fixed — Audit hardening
- Audit-hardening sweep: `Sandbox.Env` and `SecretWriter.MacOS` run helpers
  through `CommandRunner` (a timeout now kills the OS child; a missing helper
  is an error tuple instead of a crash through the linked Task);
  `Auth.Store.read` returns `{:error, {:invalid_auth_entry, provider, reason}}`
  instead of raising through its tuple spec; provider adapters return
  `ProviderError.auth` tuples for credential-preflight and token-server
  failures, so a missing/expired credential becomes a channel reply instead of
  a silently crashed turn; `file_read` validates `offset` / `limit` as
  positive integers (`offset 0` previously dropped the last line), streams
  line ranges, and caps output at 100 KB with a continue-from-offset marker;
  the realtime voice socket probes for a live listener before unlinking its
  path (mirroring the daemon control socket); and `/health/live` +
  `/health/ready` report `Application.spec` versions instead of a hardcoded
  `0.1.0`.

### Security — Log parameter filtering
- Phoenix request-log parameter filtering now redacts `password`, `secret`,
  `token`, `access_token`, `refresh_token`, `bot_token`, `verify_token`,
  `_csrf_token`, and `t` so credentials no longer land in logs.

## [0.1.0] - 2026-05-30

### Added — Subagents Orchestration
- `subagents` built-in: the main agent can spawn one or more temporary
  generic subagents for independent delegated work, run them concurrently
  up to a bounded cap, and synthesize the structured results. Each worker
  inherits the parent turn's trust and runs with the parent's policy classes
  minus `:read_write` (read, web, MCP/plugins, skills, sandbox-bounded
  `shell`; no direct local/Fermix-state writes), with its `tool_context`
  sanitized so it cannot reply on Fermix's channel or reach the parent's
  memory. Recursive fanout is bounded by a `subagent_depth` guard.
- `skill_list` built-in so a subagent can discover installed skills on
  demand before delegating to one via `skill_run`.
- `FermixCore.Agents.WorkerRun`: shared one-shot worker lifecycle
  (spawn → run → timeout → normalize → stop) reused by `skill_run` and
  `subagents`. `FermixCore.Capabilities.Registry.default_policy_classes/1`
  exposes a trust's baseline class set.

### Removed
- The `delegate` built-in and the `routing.delegate_model` config key
  (and its `model_routing_config` surface). Delegated work now goes through
  `subagents` (general, tool-using) or `skill_run` (named skill); existing
  `delegate_model` config entries are ignored.

### Added — M7.1 (Conversation Lifecycle)
- Per-model context-window catalog and `[fermix_core.compaction]` threshold
  config for automatic post-turn conversation compaction.
- Shared channel command surface for `/compact`, `/new`, `/clear`, `/help`,
  and `/whoami`, routed through `FermixChannels.Dispatcher` before agent
  delivery.
- Per-channel owner authorization for mutating commands via
  `owner_user_id` and optional `command_allowlist`; CLI remains implicit
  owner.
- `fermix doctor` now reports the active compaction trigger point and
  channel command-owner configuration.

### Fixed
- Background memory extraction no longer times out at 5s when the agent
  provider is Codex (or any reasoning model). `[fermix_core.memory]
  extraction_timeout_ms` default raised from `5_000` to `90_000`,
  round-tripped through `ConfigStore` and exposed as an optional
  `extraction_timeout_ms` wizard prompt. The Codex `:timeout` transport
  message no longer hardcodes "60s" and now points operators at the
  `extraction_timeout_ms` knob alongside `req_options[:receive_timeout]`
  and `reasoning_effort`.
- `Providers.OpenAI.Codex` no longer hangs on long Codex turns and surfaces
  `:closed` from the daemon. The SSE response is now consumed via a `Req`
  `:into` callback that feeds `SSEParser` incrementally; `receive_timeout`
  (60s) measures gaps between chunks rather than the whole turn, and a
  5s `connect_options[:timeout]` bounds TCP/TLS handshake. Bare
  `Req.TransportError` reasons (`:closed`, `:timeout`, `:econnrefused`)
  are mapped to actionable operator-readable messages instead of the raw
  atom. `SSEParser` gains `new/0`, `feed/2`, and `finalize/1` for
  incremental parsing; the existing `parse/1` is preserved.
- New `FermixCore.Net.HttpClient.request/2` wraps `Req.request/1` with a
  single retry on stale-pool transport errors (`:closed`,
  `:econnrefused`). Fixes the "first message after macOS sleep fails,
  second works" failure mode: Finch's pooled HTTPS connections to
  long-lived API hosts (api.openai.com, chatgpt.com, api.telegram.org,
  discord.com, slack.com, graph.facebook.com) go silently dead during
  long idle periods and the first request hits an RST'd connection.
  `:timeout` deliberately does NOT retry — a slow server should not be
  hammered. All four OpenAI provider POST sites (`Providers.OpenAI`,
  `Providers.OpenAI.Responses`, `Providers.OpenAI.ChatCompletions`,
  `Providers.OpenAI.Codex`), the Whisper transcription POST
  (`Transcription.OpenAI`), and the five channel-send POSTs (Telegram
  `sendMessage` + `sendChatAction`, Discord, Slack, WhatsApp) now route
  through it.

### Added — M7 (Advanced Tools)
- Built-in catalog expanded with `file_edit`, `glob_search`, `content_search`,
  `git_read`, `git_write`, `web_fetch`, `web_search`, `skill_create`,
  `model_routing_config`, and `tool_help`.
- Capability metadata schema for built-ins: `when_to_use`, `examples`,
  `failure_modes`, `requires_setup`, and `category`. Runtime prompts now
  generate a compact built-in catalog from this metadata.
- `FermixCore.Net.Guard` for public HTTP(S)-only outbound validation and
  sensitive-header redaction, plus `FermixCore.Tools.HtmlText` for
  markdown-light HTML extraction.
- Keyless `web_search` using DuckDuckGo HTML results with loud
  `rate_limited` and `parser_changed` failure contracts.
- Core `self_knowledge` skill explaining Fermix architecture, built-ins,
  skills, jobs, memory, and channels.
- Starter eval fixtures for M7 built-in tool-selection checks and the
  self-knowledge skill.

### Changed — M7
- `ConfigStore` now round-trips `[fermix_core.routing]` for local routing
  preferences used by `model_routing_config`.
- Wizard-written `config.toml` now documents the built-in-tool vs skill
  distinction in comments.

### Added — M4.10 (Codex Parity & Provider Selection)
- `Providers.OpenAI.Codex` adapter now implements the full Responses
  tool-call lifecycle over SSE — `chat/3` posts `tools`, `parse_tool_calls/1`
  surfaces normalized calls, `continue/3` rebuilds `input = prior_input ++
  output_items ++ function_call_outputs` with the API-emitted `call_id`s.
  ChatGPT-Plus users (no API key) can now run skills, MCP tools, and
  built-ins through the agent loop end-to-end.
- Reasoning-effort plumbing across the Responses + Codex adapters and the
  resolver. `:none | :minimal | :low | :medium | :high | :xhigh` accepted
  in config and threaded through `RouteResolver.resolve!/1`.
- TOML config schema gains `agent.provider`, per-provider `default_model`
  and `reasoning_effort`. `Providers.ModelCatalog` defines the canonical
  per-provider model lists. `fermix setup` exposes `--provider`,
  `--default-model`, and `--reasoning-effort` switches; `Wizard.prompts/1`
  asks the same three questions interactively when no provider is yet
  persisted in `~/.fermix/config.toml`. A new `:model` wizard step shows
  up in `WizardState.step` once the provider check is satisfied but no
  provider is recorded. `SetupLive` displays the next step inline.
  Env-var overlays (`FERMIX_PROVIDER`, `FERMIX_DEFAULT_MODEL`,
  `FERMIX_REASONING_EFFORT`) layer on top of TOML values and survive
  round-trips through `ConfigStore.save_snapshot/1`.
- `Setup.Doctor.probe_provider/2` and `probe_active/1`: live ~$0.0001
  auth probes used by `fermix doctor --full` and the wizard finalize step
  to fail loud at config time. Probes classify into `:auth_scope_mismatch`
  (401/403), `:misconfigured`, `:server_error`, `:network`. Inject HTTP
  with `req_options: [plug: ...]`; OAuth bearer comes from `TokenManager`
  (override via `:token_server` for tests).
- `MainAgent.init/1` bakes `agent.provider` + per-provider `default_model`
  + `reasoning_effort` from config into `adapter_overrides`. Explicit
  `adapter_overrides: [provider: ...]` wins whole, so a runtime route to
  a different provider can't leak per-key config from the configured
  provider's block.

### Removed — M4.10
- The "tool calls not supported on Codex" caveat in the M4.9 design doc;
  M4.10 closes that gap. `Providers.OpenAI.Codex` is the explicit
  `:openai_codex` route's adapter.

### Fixed — M4.10
- `Setup.Doctor.probe_provider/2` no longer crashes with `(EXIT) :noproc`
  when the CLI invokes `fermix doctor --full` against an OAuth-mode
  provider. The CLI process intentionally halts before starting the OTP
  supervision tree (no `TokenManager`, no `Memory.Repo`, no port bind),
  so probes that need a Codex bearer now return
  `{:error, {:misconfigured, ...}}` with a hint to run the probe from
  the daemon instead.

### Added — M4.9 (Unified Capabilities)
- Single `%FermixCore.Capabilities.Capability{}` shape for built-ins,
  skills, and MCP server tools. ETS-backed `Capabilities.Registry`
  serves the agent loop's hot path without a GenServer round-trip.
- `Providers.Adapter` behaviour with deterministic `for_route/1`
  routing on `(provider, model, auth_mode, base_url)`. OpenAI Responses
  / Chat Completions / Codex extracted as separate adapters; Codex
  treated as its own `:openai_codex` provider.
- Skills surface as direct named tools — no `invoke_skill` meta-tool.
  Sub-agent trust gate: third-party skills cannot reach `:exec` /
  `:network` / `:external_api` capabilities; `allowed_tools` narrows by
  name on top of policy.
- MCP outbound integration via `hermes_mcp`. Per-server supervisor
  isolates faults; async discovery with exponential backoff so one bad
  server can't take down healthy peers. Tool name sanitization with
  SHA256 collision suffix and 64-byte truncation matches OpenAI
  Responses regex.
- Anthropic adapter scaffold (`Providers.Anthropic.Messages`) with full
  schema-translation coverage; `chat/3` returns `:not_implemented` until
  the OAuth + token-storage milestone lands. `provider:` accepted in
  skill frontmatter so per-skill provider overrides route end-to-end.

### Removed — M4.9 cleanup
- `FermixCore.Tools.Registry`, `FermixCore.Tools.Tool` behaviour, and
  `FermixCore.Tools.InvokeSkill` are gone. Built-in tool modules now
  implement `FermixCore.Capabilities.Builtin.Tool`. `Provider.chat_opts`
  no longer carries a `:tools` field — capabilities flow through the
  adapter, not provider opts.

### Fixed — M4.9 review
- `AgentLoop` now dispatches against the per-turn filtered capability
  map, not the full `CapabilityRegistry`. A capability filtered out by
  `policy:`, `trust:`, or `allowed_tools:` can no longer be invoked
  from the loop just because it's in the registry.
- `AgentServer` now threads `definition.policy` and `definition.trust`
  into `AgentLoop` opts. Sub-agent capability filtering finally fires:
  third-party skills are read-only by default, local skills get the
  broad-but-not-`:external_api` set, and main-agent root sessions stay
  unfiltered. Implements the §4.6.3 trust gate end-to-end.
- `Prompt.RuntimeSections.build/1` no longer crashes on a skill with
  `allowed_tools: nil` (the trust-default sentinel). Renders as
  `tools=default`.
- `RouteResolver` no longer auto-routes `auth_mode: :oauth` to Codex.
  Per design §4.8, default OpenAI OAuth users land on `OpenAI.Responses`
  (which supports tool calling); Codex is reachable only via explicit
  `provider: :openai_codex`. `OpenAI.Responses` accepts `:api_key`,
  `:access_token`, or a `:token_server` for the Bearer header.
- `MCP.Supervisor` now actually starts a `Hermes.Client.Base` +
  `Hermes.Transport.STDIO` pair per server with a `:command`. Pluggable
  via `:hermes_starter` so tests don't have to spawn real subprocesses.
  Per-server sub-supervisor is `:one_for_all` so a transport crash
  bounces the client and discovery process together.
- `SkillRegistry.sync_capabilities/3` refuses to evict an existing
  built-in (or MCP) capability with the same name. Boot order is
  reordered: a `BuiltinSeeder` runs as a supervised child between
  `CapabilityRegistry` and `SkillRegistry`, so built-ins land before
  any skill snapshot can race them.
- `priv/templates/agents.md.eex` no longer references the deleted
  `invoke_skill` tool.
- `MCP.Registry` ETS table is now derived from the GenServer name
  instead of a hardcoded module atom, so multiple registry instances
  (e.g., per-test setups) don't fight over a shared table.

### Fixed — M4.8 review
- `scripts/release/build_releases_json.sh` previously rewrote every
  underscore in the artifact filename, turning `fermix_macos_x86_64`
  into target `macos-x86-64`. The installer, upgrader, and Homebrew
  bumper all expect `macos-x86_64` / `linux-x86_64`, so x86_64
  Linux and Intel macOS users could not find their artifact in
  the published manifest. Now only the os/arch separator is
  rewritten; `x86_64` stays intact.
- `Fermix.CLI.Daemon` no longer unlinks the control socket
  unconditionally on boot. We probe first: if a daemon is already
  bound, we abort with `{:another_daemon_running, path}` instead of
  unlinking the live socket out from under the running daemon and
  leaving it unreachable via `status` / `stop`. Stale sockets
  (no listener) are still removed.
- `Fermix.CLI.Upgrade.InstallMethod` now follows symlinks and
  consults `brew --prefix`. Intel Homebrew installs link
  `/usr/local/bin/fermix` to a Cellar path, and the link itself
  contains neither `/Cellar/` nor `/homebrew/`. The previous check
  classified those as unmanaged, allowing `fermix upgrade` to
  replace the brew symlink with a raw binary and desync the
  package manager. Brew symlinks are now correctly detected.
- `Fermix.CLI.Upgrade.run/1` only rolls back from the
  `~/.fermix/.previous` recovery slot when a swap actually
  happened. Pre-swap failures (download error, sha mismatch,
  cosign failure) leave the running binary alone; previously they
  could quietly overwrite the current binary with a stale recovery
  slot from an earlier upgrade attempt.
- `scripts/install.sh` no longer aborts when only `sha256sum`
  (and not `shasum`) is on PATH — common on minimal Linux. The
  preflight now accepts either tool.

### Added — M4.8 Stage 7 (`fermix doctor`)
- `Fermix.CLI.Doctor` aggregates one-shot diagnostic checks into a
  uniform table-style report. Returns exit `0` when no checks fail
  (warnings are allowed) and exit `1` otherwise so monitoring
  scripts can branch on it. The default invocation is offline; the
  `--full` flag opts into network checks (binary integrity vs the
  signed manifest, upgrade availability).
- `Fermix.CLI.Doctor.Checks` — readiness (reuses
  `FermixCore.Readiness`), workspace layout (`FERMIX_HOME` and
  subdirs exist), service unit installed, daemon control socket
  reachable, recent log activity (warns when stale > 24h), Linux
  user-scope linger state, sha256 binary integrity vs the manifest
  for the host's target, and upgrade availability.
- `fermix doctor [--full]` wired through `Fermix.CLI.Doctor` and
  documented in the usage banner.

### Added — M4.8 Stage 6 (Distribution channels)
- `scripts/install.sh` — POSIX `sh` installer for the published
  binary. Detects (os, arch), pulls `releases.json` from the latest
  GitHub Release, sha256-verifies the binary against the manifest,
  and installs to `/usr/local/bin` (with `sudo` if needed) or
  `~/.local/bin` (no sudo). Aborts on any sha mismatch or
  unsupported (os, arch) — there is no "best effort" partial
  install. `--prefix DIR` overrides the install location;
  `--no-setup` skips the post-install `fermix setup` wizard. Meant
  to be invoked as `curl -fsSL https://fermix.sh/install | sh`.
- `scripts/homebrew/fermix.rb` — starter Homebrew formula with all
  four `on_macos`/`on_linux` × `on_arm`/`on_intel` artifact blocks
  pre-wired. Versions and sha256s are placeholders that the bumper
  rewrites.
- `scripts/homebrew/bump.sh` — release-pipeline helper that reads
  `releases.json` and rewrites the formula's `version`, `url`, and
  `sha256` lines for each target. Idempotent and stateless. Used by
  CI to open auto-bump PRs against `tezra-io/homebrew-tap`.

### Added — M4.8 Stage 5 (`fermix upgrade`)
- `Fermix.CLI.Upgrade.Manifest` fetches and parses the signed
  `releases.json` manifest, compares the running version against
  `latest`, and selects the binary artifact for the host
  (os/arch). Schema mismatches and non-200 responses surface
  verbatim instead of degrading to "no upgrade available".
- `Fermix.CLI.Upgrade.InstallMethod` detects Homebrew (Cellar paths)
  and dpkg-managed installs and refuses to mutate them. Returns
  `{:managed, name, hint}` so the CLI can print the right
  `brew upgrade` / `apt upgrade` command instead of silently
  overwriting package-manager files.
- `Fermix.CLI.Upgrade.Cosign` shells out to `cosign verify-blob`
  with the certificate identity pinned to the
  `tezra-io/fermix` release workflow file and OIDC issuer pinned to
  GitHub Actions. A forged cert minted against another repo cannot
  pass.
- `Fermix.CLI.Upgrade.Swapper` downloads the binary, signature, and
  certificate to a staging directory, sha256-verifies the binary
  against the manifest, snapshots the current binary into a one-shot
  `~/.fermix/.previous` recovery slot, and atomically renames the
  staged binary into the installed path. `rollback/2` is a single
  rename back from the recovery slot — there is no version history
  or A/B install.
- `Fermix.CLI.Upgrade.run/1` orchestrates the full
  fetch → verify → snapshot → rename → restart sequence, polls the
  control socket for up to 10s as a post-swap health check, and
  rolls back automatically when the health check fails.
- `~/.fermix/upgrades.jsonl` audit log records every attempt with
  `{from, to, timestamp, sha256, status}` for `fermix doctor`
  consumption (Stage 7).
- `fermix upgrade` and `fermix upgrade --check` are now wired
  through `Fermix.CLI.UpgradeCommand`. `--check` reports current vs
  latest and the install method without touching disk.

### Added — M4.8 Stage 4 (OS daemon integration)
- `Fermix.CLI.Service` and the `Service.Templates`, `Service.Launchd`,
  `Service.Systemd` backends — install/uninstall/start/stop the
  daemon as a launchd `.plist` (macOS) or systemd `.service` unit
  (Linux). Two scopes per OS — user (default; per-user, no sudo) and
  system (`--system`; boot survival, sudo). On Linux user-scope, the
  installer runs `loginctl enable-linger` and aborts non-zero with
  the exact retry instructions if it fails (no degraded
  "works-while-logged-in" half-state).
- `fermix service install|uninstall [--user|--system]`,
  `fermix start|stop|restart [--user|--system]`. Each command
  refuses to operate when no unit is installed in the requested
  scope and points the operator at the right next step instead of
  silently no-op'ing.
- `Fermix.CLI.Daemon` — Unix-domain control socket
  (`~/.fermix/daemon.sock`, `0600`) that serves a tiny
  newline-delimited JSON request/response protocol. Methods:
  `status` (returns version, uptime, pid) and `shutdown` (replies
  then halts the BEAM via `:init.stop()`). Started only inside
  `fermix run`; stale sockets from prior crashes are removed on
  boot.
- `fermix status` queries the control socket and prints the daemon's
  liveness, version, uptime, and pid. Returns exit `3` when nothing
  is listening so monitoring scripts can branch on the conventional
  "service not running" signal.
- `fermix logs [-f|--follow] [-n LINES]` streams
  `~/.fermix/logs/fermix.log` via `tail`. Aborts with a clear
  message when the log file does not yet exist instead of hanging.
- File-logger rotation default bumped from 5 × 10 MB to 10 × 10 MB to
  match the milestone's stated retention budget.

### Added — M4.8 Stage 3 (Fermix-owned auth, drop runtime ~/.codex)
- `FermixCore.Auth.Store` — versioned, provider-scoped JSON store at
  `~/.fermix/auth.json`. Atomic writes via tmp+rename, `0600` perms,
  silent migration of the M3-era flat shape into the new nested
  schema.
- `FermixCore.Auth.RefreshClient` — extracted OpenAI token refresh
  HTTP shape so `TokenManager` and the new Codex import use one
  implementation.
- `FermixCore.Auth.CodexImport` — one-shot `~/.codex` → `~/.fermix`
  migration. Performs a single OAuth refresh against the Codex
  refresh token, persists the result, and never reads `~/.codex`
  again. Fails loud if the refresh fails (no degraded path).
- `fermix setup --import-codex` (also offered interactively when the
  Codex CLI auth file is detected and OpenAI is otherwise missing).
  Marks the openai provider with `auth_mode: :oauth` so subsequent
  daemon boots start `TokenManager`.
- `Readiness` recognizes `auth_mode == :oauth` as the canonical
  OAuth-configured signal alongside the legacy credential keys.

### Removed
- `TokenManager` no longer reads `~/.codex` at runtime — the codex
  bootstrap path, `:fork_refresh` handler, and the M3-temporary
  TODO comment are gone. A daemon that starts without
  `~/.fermix/auth.json` (or any equivalent provider config) logs a
  warning and `:get_token` returns `{:error, :no_token}`. Operators
  re-run `fermix setup` to migrate.

### Added — M4.8 Stage 2 (cross-compile + signed releases)
- `mix.exs` Burrito targets now cover `macos_aarch64`, `macos_x86_64`,
  `linux_aarch64`, `linux_x86_64`. Cross-compile from a macOS arm64 host
  validated locally (`fermix_linux_aarch64` builds as a 19 MB statically
  linked ELF).
- `.github/workflows/release.yml` — tag-driven (`v*.*.*`) release
  pipeline on `ubuntu-24.04`. Verifies tag matches `mix.exs` version,
  builds all four targets, signs each binary with cosign keyless OIDC,
  generates `releases.json`, and creates a GitHub Release with the
  binaries, signatures, certificates, and manifest attached. Auto-
  generated release notes include the cosign verification command.
- `scripts/release/build_releases_json.sh` — emits the signed-release
  manifest consumed by `fermix upgrade` (Stage 5). Schema is documented
  inline; `schema_version` field bumps on breaking changes.

### Added — M4.8 Stage 1 (Burrito single-binary)
- `fermix` CLI dispatcher (`Fermix.CLI`) routing argv to subcommand modules
  (`setup`, `run`, `version`, `help`). `start`/`stop` are registered but
  print a Stage 4 deferral message and exit `2` rather than silently
  delegating to `run`.
- Release-safe `FermixCore.Setup.Runtime` extracted from
  `Mix.Tasks.Fermix.Setup`; the Mix task is now a thin wrapper.
- `FermixCore.Application.start/2` decides at boot whether the binary was
  invoked through Burrito (`Burrito.Util.running_standalone?/0`) and
  routes accordingly:
  - `setup` — full supervision tree (needed for `Memory.Repo`), then
    `System.halt/1` before sibling apps boot. No port bind.
  - `run` — enable Phoenix endpoint server in env, start the supervision
    tree, and spawn the foreground daemon CLI. All sibling apps remain
    `:permanent` so OTP keeps the BEAM alive.
  - `version` / `help` / `start` / `stop` / unknown — read-only;
    `System.halt/1` runs before any sibling app starts. No file logger,
    no `Memory.Repo`, no `TokenManager`, no port bind.
- Burrito wrap step in `mix.exs`; `macos-aarch64` target shipped first.
- `FERMIX_HTTP_BIND` runtime env (default `127.0.0.1`) parsed via
  `:inet.parse_address/1`. Invalid values raise during `runtime.exs`
  evaluation so the daemon fails loud at boot rather than silently
  binding the wrong interface.
- Auto-generated `SECRET_KEY_BASE` if the env var is unset, so a freshly
  installed binary can boot before the user has configured anything.

### Distribution — Stage 1 acceptance gate
- **Compressed binary size:** `fermix_macos_aarch64` is **11 MB**
  (`11,455,336 bytes`). Hard ceiling for M4.8 is 100 MB; well within
  budget.
- Stage 1 verified end-to-end on `aarch64-apple-darwin`:
  `version` / `help` / unknown commands halt before any supervision tree
  starts; `setup --print-state` boots the full tree and halts; `run`
  binds `127.0.0.1` by default and `0.0.0.0` via `FERMIX_HTTP_BIND`.

### Known
- The packaged release logs a startup warning that
  `priv/static/cache_manifest.json` is missing. This is a pre-existing
  Phoenix digest-pipeline gap (the cache manifest is not produced by the
  current build) and does not block `fermix run`. Tracked separately.
