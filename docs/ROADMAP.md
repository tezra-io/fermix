# Fermix Roadmap — Post-MVP Features

**Last Updated:** 2026-04-07
**Status:** Planning

This roadmap organizes features by milestone AFTER the Phase 1 MVP (single-agent Telegram bot with basic tools).

**Priority Legend:**
- **P0**: Critical for production use
- **P1**: High value, should be done soon
- **P2**: Nice to have, can be deferred

**Effort Scale:**
- **S**: Small (1-3 days)
- **M**: Medium (1-2 weeks)
- **L**: Large (2-4 weeks)
- **XL**: Extra Large (1-2 months)

**Type:**
- **Port**: Direct port from RustyClaw Elixir layer
- **Rewrite**: Rewrite from RustyClaw Rust reference
- **New**: Original feature for Fermix
- **Hybrid**: Port with significant changes

---

## Milestone 2: Multi-Agent Orchestration

**Goal:** Main Agent can delegate to ephemeral skill agents with supervision, journals, and safe parallel execution.

**Ownership model for M2:** `MainAgent` remains the channel-facing GenServer started directly by `FermixCore.Application`; `AgentServer` is introduced for supervised skill workers.

**Implementation order for M2:** `AgentDefinition` + `SkillRegistry` foundation → `AgentServer` lifecycle → `AgentSupervisor` + application wiring → `invoke_skill` + MainAgent integration → journals / safe parallel execution policy / AgentCoordinator. Same-repo parallel code-writing stays disabled until an isolation boundary (`git worktree` or remote execution) exists.

**Test boundary for M2:** keep existing MainAgent/webhook coverage anchored on `MainAgent.handle_message/2`; add new tests for `AgentSupervisor` restart semantics, `AgentServer` lifecycle, and `invoke_skill` delegation/message-flow regressions.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **AgentServer port** | Port AgentServer GenServer for delegated skill worker lifecycle, parent/child tracking | P0 | Port | `elixir/agent_server.ex` | M |
| **AgentSupervisor port** | Port DynamicSupervisor for `:temporary` skill workers; keep MainAgent under application supervision | P0 | Port | `elixir/agent_supervisor.ex` | S |
| **AgentDefinition port** | Port with `role: :main \| :sub` field added | P0 | Port | `elixir/agent_definition.ex` | S |
| **AgentCoordinator port** | Port capability matching + ACL | P1 | Port | `elixir/agent_coordinator.ex` | S |
| **Main Agent lifecycle** | Enhance the existing persistent MainAgent with delegation hooks while keeping it as the channel-facing GenServer for AgentServer-backed skills | P0 | Hybrid | `docs/MAIN_AGENT_DESIGN.md` | M |
| **Skill templates** | YAML+MD skill definition files loaded from filesystem | P0 | New | `docs/OPTION_B_ORCHESTRATION_DESIGN.md` | M |
| **SkillRegistry** | Load skill templates from `~/.fermix/skills/` | P0 | New | `docs/OPTION_B_ORCHESTRATION_DESIGN.md` | S |
| **invoke_skill tool** | Tool for Main Agent to spawn ephemeral skill agents | P0 | New | `docs/OPTION_B_ORCHESTRATION_DESIGN.md` | M |
| **Skill journals** | Markdown journals per skill instance in `~/.fermix/journals/` | P1 | New | `docs/MAIN_AGENT_DESIGN.md` | M |
| **Safe parallel skill execution** | Spawn multiple skills concurrently only for safe cases: different repos, external-only work, or same-repo read-only tasks on a pinned snapshot. Same-repo mixed mutating + read-only work requires isolation. | P1 | New | `docs/MAIN_AGENT_DESIGN.md` | L |
| **Repo isolation boundary** | Required before enabling same-repo parallel code-writing; default local strategy is `git worktree`, remote execution is an acceptable alternative | P1 | New | `docs/MAIN_AGENT_DESIGN.md` | M |
| **ResourceLock port** | Port resource locking for coordinated access | P2 | Port | `elixir/resource_lock.ex` | S |
| **BtwRouter port** | Port side-channel routing (`/btw` commands) | P2 | Port | `elixir/btw_router.ex` | S |
| **MessageProvenance port** | Port message tracking/tracing | P2 | Port | `elixir/message_provenance.ex` | S |
| **TraceStore port** | Port distributed tracing for debugging | P2 | Port | `elixir/trace_store.ex` | S |

**Milestone 2 Total Effort:** ~8-12 weeks

---

## Milestone 3: Onboarding & Channel Coverage

**Goal:** First-run onboarding experience + support for all major messaging platforms.

### Onboarding

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **CLI onboarding wizard** | Interactive `fermix setup` — walks through API keys, provider selection, channel config, workspace init | P0 | New | N/A | M |
| **LiveView onboarding** | Browser-based first-run setup at localhost:4000/setup — same flow as CLI but visual | P1 | New | N/A | M |
| **Config validation** | Validate all config on startup, surface clear errors for missing/invalid keys | P0 | New | N/A | S |
| **Health check endpoint** | /health with provider connectivity, channel status, memory backend health | P1 | New | N/A | S |

### Channels

**Goal:** Support the most popular messaging platforms first. Additional channels deferred to Future milestone.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **WhatsApp channel** | Cloud API, webhook + signature verification | P0 | Rewrite | `src/channels/whatsapp.rs` | M |
| **Discord channel** | Gateway WebSocket + REST API | P0 | Rewrite | `src/channels/discord.rs` | L |
| **Signal channel** | signal-cli integration via subprocess | P1 | Rewrite | `src/channels/signal.rs` | M |
| **Slack channel** | RTM/Events API + Bot user | P1 | Rewrite | `src/channels/slack.rs` | M |
| **CLI channel** | Interactive CLI for testing | P1 | Rewrite | `src/channels/cli.rs` | S |
| **Transcription support** | Audio transcription for voice messages | P1 | Rewrite | `src/channels/transcription.rs` | M |

**Milestone 3 Total Effort:** ~6-10 weeks

---

## Milestone 4: Advanced Memory

**Goal:** Three-tier memory architecture with intelligent extraction, gist generation, and compaction.

> **Decision Pending:** Evaluate Honcho AI (self-learning + dreaming) and wiki-style memory (lightweight LLM-wiki pattern) as alternatives to Hermes consolidation. If either proves sufficient, skip Hermes consolidation to keep the stack simpler and leaner. See Open Questions #7.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Hermes extraction (Phase 1)** | LLM-driven memory extraction with confidence scoring | P0 | Port | `elixir/hermes/` + `docs/hermes-memory-design.md` | L |
| **Hermes consolidation (Phase 2)** | Memory deduplication and merging *(may be replaced by Honcho AI or wiki-style memory)* | P0 | Port | `elixir/hermes/` | M |
| **Hermes decay (Phase 3)** | Confidence decay over time | P1 | Port | `elixir/hermes/` | S |
| **Honcho AI integration** | Self-learning memory with dreaming capability — heavier Docker image but strong autonomous learning | P1 | New | [honcho.dev](https://honcho.dev) | M |
| **Wiki-style memory** | Lightweight LLM-wiki pattern for capturing important bits — integrable from existing skill | P1 | New | `skills/llm-wiki/SKILL.md` | S |
| **Gist generator** | Tier 1 cohesive memory document (always in context) | P0 | New | `docs/MAIN_AGENT_DESIGN.md` | M |
| **Daily memory storage** | Tier 2 structured storage by date | P1 | New | `docs/MAIN_AGENT_DESIGN.md` | S |
| **Context compaction** | Tier 3 compaction with token counting | P0 | New | `docs/MAIN_AGENT_DESIGN.md` | M |
| **SQLite backend** | SQLite storage with FTS5 + embeddings | P0 | Rewrite | `src/memory/` | L |
| **Embedding search** | Vector similarity search for semantic recall | P1 | Rewrite | `src/memory/` | M |
| **Memory hygiene** | Cleanup old/stale memories | P2 | Rewrite | `src/memory/` | S |
| **Memory snapshots** | Backup/restore memory state | P2 | Rewrite | `src/memory/` | S |
| **Loop detection** | Detect runaway tool call loops | P1 | Port | `elixir/loop_detection_hook.ex` | S |
| **Memory recall tool** | Tool for agents to query memory | P0 | Rewrite | `src/tools/memory_recall.rs` | S |

**Milestone 4 Total Effort:** ~10-14 weeks

---

## Milestone 4.5: Prompt Bootstrap Architecture

**Goal:** Replace the hardcoded main-agent system prompt with a composable file-backed bootstrap layer.

This milestone is intentionally separate from M4:

- `USER.md` and `MEMORY.md` are memory artifacts and belong in M4
- `AGENTS.md` and `SOUL.md` are prompt/bootstrap artifacts and should not be coupled to memory implementation

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **PromptComposer** | Build system prompt from ordered prompt/bootstrap parts instead of one hardcoded heredoc | P0 | New | OpenClaw system prompt docs | M |
| **`AGENTS.md` support** | File-backed agent operating instructions / runtime identity block | P0 | New | OpenClaw `AGENTS.md` | S |
| **`SOUL.md` support** | File-backed persona/style/voice layer for the main agent | P1 | New | OpenClaw `SOUL.md` | S |
| **Prompt file ordering policy** | Define stable ordering for `AGENTS.md`, `SOUL.md`, `USER.md`, `MEMORY.md`, skill catalog, and runtime guidance | P0 | New | OpenClaw system prompt docs | S |
| **Bootstrap file loader** | Load prompt files from the Fermix workspace/home with missing-file handling | P0 | New | N/A | S |
| **Runtime contract generation** | Generate compact contract-style runtime sections from live skill/tool state instead of prose-heavy prompt fragments | P1 | New | Autogenesis `Fτ,i` exported representations | S |
| **Prompt budget accounting** | Track approximate contribution of each injected prompt/bootstrap file | P1 | New | OpenClaw `/context` inspiration | M |
| **Truncation visibility** | Surface when injected prompt/bootstrap files were clipped by context policy | P1 | New | OpenClaw truncation warnings | S |
| **Sub-agent bootstrap filtering** | Future-proof rule for which bootstrap files sub-agents do or do not inherit | P1 | New | OpenClaw sub-agent filtering | S |

**Milestone 4.5 Total Effort:** ~3-5 weeks

---

## Milestone 4.6: Versioned Prompt and Memory Resources

**Goal:** Add revision lineage, rollback, and auditable provenance for prompt/bootstrap and prompt-memory artifacts without introducing autonomous self-modification.

This milestone captures the useful part of Autogenesis for Fermix:

- prompt and memory artifacts are treated as first-class resources
- every accepted rewrite has lineage and can be rolled back
- the system stays operator-controlled; no closed-loop autonomous prompt mutation is introduced yet

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Prompt resource registry** | Register `AGENTS.md`, `SOUL.md`, `USER.md`, `MEMORY.md`, and compaction checkpoints as typed resources with metadata | P0 | New | Autogenesis RSPL | M |
| **Revision lineage** | Track resource versions, parent revision, timestamps, and mutation source | P0 | New | Autogenesis version lineage | M |
| **Rollback support** | Revert prompt or memory resources to a prior accepted revision safely | P0 | New | Autogenesis rollback | S |
| **Change provenance** | Store why a prompt/memory artifact changed and what source events or memories drove the rewrite | P1 | New | Autogenesis auditability | M |
| **Diff inspection UI** | Surface prompt/memory revision diffs in LiveView or CLI tooling | P1 | New | N/A | M |
| **Checkpoint resource history** | Version persisted compaction checkpoints the same way as other prompt resources | P1 | New | Autogenesis resource model | S |

**Milestone 4.6 Total Effort:** ~4-6 weeks

---

## Milestone 4.8: Distribution & Daemon

**Goal:** Turn Fermix from a runnable project into an installable product. Single binary per `(os, arch)`, OS-supervised daemon, Codex auth import for the `openai_codex` provider, explicit `fermix upgrade`.

See `docs/MILESTONE_4_8_DISTRIBUTION.md` for the full design.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Burrito single-binary build** | Wrap `mix release` into one self-extracting binary per target; bundles ERTS + NIFs | P0 | New | [burrito-elixir/burrito](https://github.com/burrito-elixir/burrito) | M |
| **Cross-compile matrix** | macOS aarch64/x86_64, Linux aarch64/x86_64; Windows deferred | P0 | New | N/A | M |
| **`fermix` CLI** | `setup`, `start`, `stop`, `restart`, `status`, `logs`, `upgrade`, `doctor`, `version`, `uninstall` | P0 | New | N/A | M |
| **OS daemon integration** | launchd plist (macOS) and systemd-user unit (Linux); user-scope by default | P0 | New | Tailscale install pattern | M |
| **Codex auth import** | Import Codex CLI tokens into `~/.fermix/auth.json` for the `openai_codex` provider | P0 | New | Codex CLI auth flow | M |
| **`fermix upgrade`** | Fetch + verify signature + atomic swap + restart | P0 | New | N/A | M |
| **Versioning + signed releases** | SemVer in `mix.exs`; cosign keyless OIDC; `releases.json` manifest | P0 | New | Sigstore | S |
| **Homebrew tap** | `tezra-io/homebrew-tap`, auto-bumped from CI | P1 | New | N/A | S |
| **Linux install script** | `curl -fsSL .../install \| sh` — detect platform, download, verify, run setup | P1 | New | Hermes install pattern | S |
| **`fermix doctor`** | Post-install diagnostics — binary integrity, daemon health, NIF load, auth validity | P1 | New | Tailscale doctor | S |
| **Debian package** | `.deb` for Ubuntu/Debian with systemd unit | P2 | New | N/A | S |
| **Docker image** | Production image for server deployments (consolidated from M8) | P2 | New | M8 | S |

**Milestone 4.8 Total Effort:** ~5-7 weeks

---

## Milestone 4.9: Unified Capabilities (Skills, Tools, MCP, Provider Adapters) — _Shipped_

**Goal:** Collapse `Tools.Registry` and `SkillRegistry` into a single `CapabilityRegistry` exposing built-in tools, skills, and MCP-server tools through one shape. Add a per-provider `Adapter` layer so each provider gets its native tool schema. Route `gpt-*` to the OpenAI Responses API. Integrate MCP outbound via `hermes_mcp`. Implementation is OpenAI-only, but the abstraction is multi-provider.

See `docs/MILESTONE_4_9_UNIFIED_CAPABILITIES.md` for the full design.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **`Capability` behaviour** | Single contract for built-in tools, skills, and MCP tools — `name`, `description`, `parameters`, `execute`, `kind` | P0 | New | hermes-agent registry pattern | M |
| **`CapabilityRegistry`** | One GenServer replacing `Tools.Registry`; sources from built-ins, `SkillRegistry`, MCP supervisor | P0 | New | N/A | M |
| **Per-provider `Adapter` layer** | Behaviour + per-provider modules; `to_provider_tools`, `chat`, `parse_tool_calls` | P0 | New | hermes-agent api_mode pattern | M |
| **OpenAI Responses adapter** | `/v1/responses` with `strict: false` function tools; deterministic call IDs for cache stability | P0 | New | hermes-agent `_responses_tools` | M |
| **OpenAI Chat Completions adapter** | Extracted from existing `Providers.OpenAI`; fallback for OpenAI-compatible providers | P0 | Refactor | N/A | S |
| **`Adapter.for_model/1` routing** | `gpt-*` → Responses, `claude-*` → Anthropic, default → ChatCompletions | P0 | New | N/A | S |
| **Each-skill-as-tool exposure** | Replaces `invoke_skill` meta-tool with per-skill capabilities; sub-agent spawn inside `Skill.Capability.execute/2` | P0 | Rewrite | OpenCode meta-tool comparison | M |
| **Force-skill instruction** | Sub-agent system-prompt prepend: "You are running as the X skill" | P0 | New | N/A | S |
| **Sub-agent global capability inheritance** | Default = sub-agent sees parent's full registry; `allowed_tools` is opt-out | P0 | Refactor | N/A | S |
| **`max_skill_depth` recursion cap** | Default 4; context-propagated; fail loud past it | P0 | New | N/A | S |
| **MCP outbound integration** | `hermes_mcp` dependency; `MCP.Supervisor` boots configured stdio servers; tools register as namespaced capabilities | P0 | New | [hermes_mcp](https://hexdocs.pm/hermes_mcp), hermes-agent `_convert_mcp_schema` | M |
| **`[mcp.servers.<name>]` config** | TOML block with `command`, `args`, literal `env`, and `pass_env` names resolved through `[sandbox.env]` | P0 | New | N/A | S |
| **Anthropic adapter scaffold** | Real `to_provider_tools` (input_schema rename); `chat/3` returns `{:error, :not_implemented}` until tokens land | P1 | New | N/A | S |
| **Per-skill `provider:` override** | Optional frontmatter field; lets skills pin a specific provider | P1 | New | N/A | S |
| **Telemetry uniformity** | `[:fermix, :capability, :exec]` across all kinds; replaces per-tool/per-skill events with overlap during migration | P1 | Refactor | N/A | S |
| **Removal of `Tools.Registry`, `Tools.Tool`, `Tools.InvokeSkill`** | After Stage 4 cutover; no deprecation shim — pre-release system, no external consumers | P0 | Removal | N/A | S |

**Migration safety:** Stages 1–4 run old + new registries side-by-side; old path deletion happens only at Stage 4 ship gate. Behaviour fixtures pin OpenAI request bodies for representative skill fixtures across the migration. End-to-end Telegram smoke test required at every stage gate.

**Multi-provider note:** The `Additional Providers (Ongoing)` section's "OpenAI Responses API unification" item is absorbed by this milestone. The `Reliable wrapper`, `Router provider`, and concrete `Anthropic`, `Gemini`, `OpenRouter`, `Ollama` adapters remain separate work items — M4.9 only delivers the abstraction layer they will plug into.

**Milestone 4.9 Total Effort:** ~3-4 weeks

---

## Default Skill Set — Initial Release

**Goal:** Define the small set of Fermix-owned skills that ship with the first install.

This is a product decision, not a capability-system milestone. M2 and M4.9 provide the skill runtime, registry, policy, and direct skill-as-capability invocation. This section owns the actual default skill catalog.

Default skills should be:

- Few enough that the main agent can choose confidently.
- Product-shaped, not generic role labels.
- Backed by checked-in `SKILL.md` files under the release `priv/skills` tree.
- Tested through `SkillRegistry`, `CapabilityRegistry`, sub-agent invocation, and journal output.
- Documented in README with only the skill name, intended use, and capability boundary.

Initial skill names and contents are TBD.

Out of scope:

- User-created skill tooling; that remains under Milestone 7's `skill_create`.
- Third-party/plugin skill installation; that remains a follow-on unlocked by M4.9.
- Large catalogs of overlapping specialist skills.

---

## Milestone 4.10: Codex Parity & Provider Selection UX

**Goal:** Close the M4.9 gap that left ChatGPT Plus users without a working agent loop. Make `:openai_codex` a first-class provider with tool-call support; persist provider/model/reasoning_effort in TOML with env overlays; expose a wizard step for provider+model+effort; surface the chosen surface in `fermix doctor` with a real auth probe so config mistakes fail at boot, not on the first message.

See `docs/MILESTONE_4_10_CODEX_PARITY.md` for the full design.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Codex tool-call adapter** | Implement `to_provider_tools/1`, `parse_tool_calls/1`, `continue/3` on `OpenAI.Codex`; SSE function_call accumulation | P0 | New | `~/projects/rustyclaw/src/providers/openai_codex.rs`, `~/projects/hermes-agent/run_agent.py:679–712` | M |
| **Codex SSE parser** | Stateful accumulator for `chatgpt.com/backend-api/codex/responses` stream; emits final `body["output"]` shape | P0 | New | rustyclaw codex SSE handler | M |
| **Reasoning effort plumbing** | `reasoning: %{effort: <level>}` in Codex/Responses request body; opts → app config → omitted; `none/minimal/low/medium/high/xhigh` | P1 | New | `~/projects/hermes-agent/hermes_constants.py` | S |
| **Provider/model/effort persistence** | `ConfigStore.normalize_openai/anthropic` round-trip `provider`, `default_model`, `reasoning_effort` through TOML | P0 | New | N/A | S |
| **Env-var overlays** | `FERMIX_PROVIDER`, `FERMIX_DEFAULT_MODEL`, `FERMIX_REASONING_EFFORT` in `runtime.exs` with fail-soft validation | P0 | New | runtime env overlay pattern | S |
| **Model catalog** | `FermixCore.Providers.ModelCatalog.models_for/1` static curated lists + Custom escape hatch | P0 | New | N/A | S |
| **Wizard provider+model+effort step** | New `:model` wizard step extending `WizardState.step`; Codex disclaimer; Anthropic api_key entry | P0 | New | N/A | M |
| **Doctor auth probe** | Per-provider real $0.0001 API call to verify scope works against the chosen surface; actionable error mapping | P0 | New | N/A | S |
| **MainAgent default sourcing** | Read provider/model/effort from app config when adapter_overrides empty; layered with existing M4.9 per-agent overrides | P0 | Modify | N/A | S |

**Why before M4.11:** scheduled jobs are agent loops with tool calls. Without M4.10, a job under `:openai_codex` either errors on `continue/3` or returns text-only. Stacking M4.11's cron infra on a broken provider substrate means re-validating M4.11 after M4.10 lands. Fix the foundation first.

**Non-goals:** new providers (Gemini, OpenRouter, Ollama — see `Additional Providers (Ongoing)`); streaming partial tokens to channels; per-model effort clamping (we send verbatim and surface API rejections).

**Milestone 4.10 Total Agent Wall-Clock:** ~5–8 hours (one end-of-day review pass). Stage 1 (Codex SSE parser) is the only realistic source of variance.

---

## Milestone 4.11: Scheduled Agents — Cron Jobs, Persistent Memory Sources, Isolated Runs

**Goal:** First-class scheduled background tasks. Daily digests, repository watchers, deployment checks, "remind me later" tasks, long-running monitors. Each LLM execution is bounded and isolated; the catalog and memory provenance are durable and discoverable to the main agent.

See `docs/MILESTONE_4_11_SCHEDULED_AGENTS.md` for the full design.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Job registry** | Durable `scheduled_jobs` records with schedule, task, capability policy, delivery, memory source, status | P0 | New | `~/projects/hermes-agent/cron/jobs.py` | M |
| **Job scheduler** | OTP GenServer that tracks next due job, ticks/reconciles, starts due jobs asynchronously | P0 | New | `~/projects/hermes-agent/cron/scheduler.py` | M |
| **Job runner** | Supervised worker; isolated session per occurrence; bounded `AgentLoop` execution | P0 | New | N/A | M |
| **Main-agent job capabilities** | `schedule_job`, `list_jobs`, `pause_job`, `resume_job`, `update_job`, `remove_job`, `run_job_now`, `job_runs` | P0 | New | N/A | M |
| **Memory source catalog** | Durable metadata for `main`, `job:<id>`, future source types | P0 | New | N/A | S |
| **Source-aware memory recall** | Memory writes/reads carry `source_id`, `source_name`, `source_type`, `session_id`, `run_id` | P0 | Modify | N/A | M |
| **Scheduler-owned delivery** | Job final output saved first, then delivered by scheduler/channel layer; agents do not self-deliver by default | P0 | New | N/A | S |
| **Sync/async contract** | CRUD synchronous + fast; execution/extraction/delivery asynchronous + supervised | P0 | New | N/A | S |
| **Latency targets** | Explicit targets for CRUD, due-job start jitter, scheduler recovery, run status, memory visibility, delivery | P0 | New | N/A | S |
| **Observability** | Telemetry for job lifecycle: created/due/started/completed/failed/delivered/skipped | P1 | New | N/A | S |

**Depends on M4.10:** scheduled jobs need full tool calls on whichever provider the user picked.

**Milestone 4.11 Total Agent Wall-Clock:** ~7–10 hours (one review day, possibly stretching into a second pass for the source-aware memory schema migration). The job scheduler's timer/reconciliation logic and the memory-source DB shape are the two scope-shaped variances.

---

## Milestone 5: Workspace Sandbox & Capability Surface

**Goal:** Ship the smallest correct *floor* under tool execution — a workspace-rooted policy boundary that keeps day-to-day bash permissive inside `~/.fermix/workspace` and operator-granted roots, hardline-blocks a tiny set of uncategorically-banned commands, and stores credentials in the OS keyring (macOS Keychain / Linux Secret Service) instead of plaintext config. Explicitly **not** M10 — no LLM content filter, no leak detector, no prompt-injection guard, no per-call approval UX. Those stay in M10. M5 is the floor M10 hardens on top of.

See `docs/MILESTONE_5_WORKSPACE_SANDBOX.md` for the full design.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Workspace root + dev/release split** | `FERMIX_HOME=~/.fermix` (release) vs `~/.fermix-dev` (dev); `workspace/` subdir is the default-allowed write surface for all built-in tools; daemon `working_dir` default changes from `File.cwd!()` to workspace root | P0 | New | hermes `environments/local.py` shape | S |
| **Hardline blocklist** | Pure-function classifier for uncategorically-banned commands (`rm -rf /`, `mkfs`, `dd of=/dev/sd*`, fork bomb, system shutdown, sudo password-guessing). Hardcoded in code, not config — no flag lifts it | P0 | New | hermes `HARDLINE_PATTERNS` (`tools/approval.py:198`) | S |
| **Workspace containment** | `:read_write` / `:exec` capabilities write only inside workspace + `[sandbox.allowed_roots]`. Resolved-symlink check; macOS `/private/etc` collapse handled. Best-effort shell-operand parser for `cp/mv/tee/>` with deny-on-unparsed default | P0 | New | hermes `path_security.validate_within_dir` | M |
| **Sandbox dispatch module** | `FermixCore.Sandbox.enforce/3` — single dispatch point keyed off existing `%Capability{policy_class}` ladder; emits `[:fermix, :sandbox, :decision]` telemetry + trace entry; no Plug-style middleware chain | P0 | New | N/A | S |
| **Allowed-roots grant CLI** | `fermix grant path <dir>`, `fermix revoke path <dir>`, append-only audit records in `~/.fermix/grants/`; control-socket `:reload_sandbox` re-reads config without daemon restart | P0 | New | hermes config.yaml shape | S |
| **External-CLI subagent grant** | `fermix grant subagent <name>` registers a built-in capability that shells out to a local CLI (Codex, Claude Code, Cline, etc.) with declared credential passthrough; one-shot per call, `:exec` policy class | P0 | New | hermes `subprocess` patterns | M |
| **Credential passthrough** | `[sandbox.credentials.<name>]` declares files (mount-path) or env vars (env-name) capabilities can see; daemon env scrubbed of credential-shaped vars at boot unless claimed | P0 | New | hermes `credential_files.py` | S |
| **OS keyring backend (Rustler NIF)** | Wrap `keyring-rs` 3.x in `apps/fermix_nif`. macOS Keychain Services, Linux Secret Service (libsecret/D-Bus), Windows Credential Manager (deferred with M4.8 Windows) | P0 | New | `keyring-rs` crate | M |
| **`age` encryption for OAuth blobs** | Multi-field OAuth credentials (Codex `auth.json` and future OAuth providers) encrypted-at-rest with `rage-rs`; symmetric master key stored in the OS keyring; `fermix keystore rotate-master` decrypts and re-encrypts with new key | P0 | New | `rage-rs` crate | S |
| **`FermixCore.Auth.Keystore` facade** | GenServer-backed facade with `put/3` `get/2` `delete/2` `list/1` `backend_info/0`; in-memory `Stub` for tests injected via Application env; file-fallback for headless servers behind explicit opt-in | P0 | New | N/A | S |
| **One-time plaintext-secret migration** | First M5 boot walks `auth.json` + `[providers.*].api_key` + channel secrets, writes to keystore, rewrites config with `"@keyring"` sentinels; pre-migration files preserved as `.pre-m5` until operator deletes them after `fermix doctor` green | P0 | New | N/A | S |
| **`"@keyring"` config sentinel** | `ConfigStore` resolves `"@keyring"` and `"@keyring:<scope>.<name>"` values to live keystore lookups at read time; never writes plaintext values back to TOML | P0 | New | N/A | S |
| **Keystore CLI** | `fermix keystore status / put / get / delete / list / rotate-master`; secret values via stdin only, never argv | P0 | New | N/A | S |
| **Website blocklist (optional)** | `[sandbox.website_blocklist]` honored at `NetGuard.validate/2` boundary; fail-open default; `fermix grant website-allow <host>` for overrides; cannot override the NetGuard private-IP block | P1 | New | hermes `website_policy.py` | S |
| **`SafeRm` test helper + Credo checks** | `FermixCore.TestSupport.SafeRm.rm_rf!/1` asserts path is under a tmp prefix with ≥4 segments and no `..`; two Credo checks forbid raw `File.rm_rf` in `test/` and ban `System.cmd` / `Port.open` in `test/fermix_core/sandbox/`. Pre-existing 14 test sites rewritten in Stage 0 | P0 | New | Stage 0 of M5 (gate) | S |
| **Doctor + audit task** | `fermix doctor` adds sandbox + keystore probes; `mix sandbox.audit` Mix task prints resolved workspace, allowed roots, subagents, credentials, keystore backend, all green/red marks | P0 | New | N/A | S |
| **Setup wizard step** | "Where do you want the agent to operate?" — defaults to `~/.fermix/workspace`, optional `~/projects/<name>` add, detect-and-grant for `codex`/`claude`/`cline` in `$PATH`; API-key prompts write through `Keystore.put/3` only | P0 | New | M4.10 wizard | S |

### Why before M10 (Security & Governance)

M10 as scoped (Sentinel LLM filter, content scanner, leak detector, prompt-injection guard, approval workflow, audit-log signing) is the **ceiling**, not the floor. Without M5, the operator-experience trade-off is "no protection at all" vs "prompts every shell call" — and the user has correctly flagged the latter as worse-than-useless. M5 ships the floor: workspace containment, a tiny hardline list, keychain-backed credentials, and `fermix grant` UX. M10 then layers its pattern-based and LLM-based defenses on top, without M10's progress blocking M5's day-1 value.

**Test-wipe pitfall (must read).** A prior M5-shaped implementation pass had Codex generate a unit test whose cleanup hook called `File.rm_rf!` on a computed path; the path collapsed to an unsafe root and the host filesystem was wiped during `mix test`. The shell sandbox could not have caught it — direct VM call. M5's **Stage 0** is therefore the non-negotiable `FermixCore.TestSupport.SafeRm` helper + Credo checks that forbid raw `File.rm_rf` in `test/` and forbid `System.cmd` / `Port.open` in sandbox tests. Nothing else in M5 begins until Stage 0 is merged. See `docs/MILESTONE_5_WORKSPACE_SANDBOX.md` §11 for the full negative-test discipline.

**Depends on M4.8** (CLI dispatch, daemon, `~/.fermix` home, Rustler NIF infra) and **M4.9** (`%Capability{}` struct, `policy_class` ladder, `CapabilityRegistry`). **Blocks M10** — every M10 enforcement point binds to a hook M5 introduces (`Sandbox.enforce/3` decision pipeline, `[:fermix, :sandbox, :decision]` telemetry, `~/.fermix/grants/` audit records, the `"@keyring"` sentinel).

**Milestone 5 Total Agent Wall-Clock:** ~9–11 hours (one to two review days). Stages 5–6 (keystore NIF introduction + migration) and Stage 0 (test-safety prerequisite) are the variance sources; the OS-keyring path needs validation on macOS Keychain + Linux Secret Service + file-fallback before any caller switches.

---

## Milestone 5.1: Finish M5 + Sandbox Env Unification

**Goal:** Land the two halves of M5 that did not ship (wizard secret writer for plaintext API keys, `auth.json` perms-widened boot refusal, doctor trace scan, rename migration error, deny-message audit) and unify MCP env routing through `Sandbox.Env` so `[sandbox.env]` is the single declared-secret registry across shell, sandbox commands, and MCP servers.

See `docs/POST_M5_PLAN.md` for the full plan.

| Slice | Description | Priority | Effort | PR |
|---|---|---|---|---|
| **A1 Wizard secret writer (macOS-first)** | `Setup.SecretWriter` writes setup secrets to macOS Keychain via `/usr/bin/security`; `"@keyring"` sentinel in `config.toml`; explicit `fermix setup --migrate-secrets` for opt-in migration of existing plaintext keys (config load stays noninteractive) | P0 | M | 2 |
| **A2 `auth.json` perms boot refusal** | Daemon refuses to start if `~/.fermix/auth.json` is not `0o600`; `fermix doctor` reports the same check | P0 | S | 1 |
| **A3 Persist sandbox decisions + doctor trace scan** | Telemetry handler writes `:deny`/`:hardline` events to `Trace.record/4`; doctor scan walks recent traces and prints `fermix grant path <target>` suggestions with the right granularity per tool family | P0 | S | 3 |
| **A4 Roadblock-message audit** | Every sandbox deny path (`shell`, `file_write`, `file_edit`, `git_write`, `sandbox/env.ex`, CLI/channel handlers) emits a message naming the exact fix command. Granularity: shell grants the cwd, file ops grant `Path.dirname`, git grants the repo root | P0 | S | 1 |
| **A5 Rename migration error** | `Config.normalize` raises `ArgumentError` with old → new mode/profile mapping and the CLI fix command when old names appear in `config.toml` | P0 | XS | 1 |
| **B1 MCP env unification** | Route MCP server env through `Sandbox.Env.build_command/2` via a new `pass_env` field on `[mcp.servers.*]`; `[sandbox.env].mode` extends to MCP; `$env:KEY` shorthand deleted (pre-release, no migration shim) | P1 | S | 4 |

**Out of scope (roadmap, demand-driven):** Linux `secret-tool` / `pass` / `op` SecretWriter backends, Windows `Wincred` backend, auto-detection of project roots beyond the five common ones, OAuth-blob Keychain migration (`auth.json` stays as `0600` plaintext).

**Depends on M5.** **Blocks M10** — the unified secret registry from B1 is the surface M10's leak detector and approval flow bind to; without it, every M10 enforcement point has to handle MCP-env separately.

**Milestone 5.1 Total Agent Wall-Clock:** ~2.5 working days across four PRs (PR 1 ~½ day, PR 2 ~1 day, PR 3 ~½ day, PR 4 ~½ day). PR 1 first because it establishes the deny-message format the rest of the work follows.

---

## Milestone 6: Developer Experience

**Goal:** LiveView dashboard, CLI tools, hot reload, and excellent debugging.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **LiveView dashboard** | Real-time agent status monitoring | P0 | New | N/A | L |
| **Agents LiveView** | View/manage running agents | P1 | New | N/A | M |
| **Memory LiveView** | Browse and search memory | P1 | New | N/A | M |
| **Logs LiveView** | Real-time log streaming | P1 | New | N/A | M |
| **Phoenix Channels** | WebSocket for real-time chat | P1 | New | N/A | M |
| **Cron scheduler** | Native GenServer-based scheduler | P0 | New | N/A | M |
| **CLI (`fermix` command)** | Mix tasks or escript for ops | P1 | New | N/A | M |
| **Config migration tool** | Import RustyClaw TOML config | P2 | New | N/A | S |
| **Memory migration tool** | Import RustyClaw SQLite memory | P2 | New | N/A | M |
| **Hot code reload** | Reload agent code without restart | P1 | New | N/A | S |
| **Rich error messages** | Elixir-style helpful errors | P1 | New | N/A | S |
| **GraphQL API** | Alternative to REST for dashboard | P2 | New | N/A | L |

**Milestone 6 Total Effort:** ~10-14 weeks

---

## Milestone 7: Advanced Tools — Built-in Capability Catalog — _Shipped_

**Goal:** ship the canonical Fermix built-in tool catalog so the agent stops reaching for `shell` for verbs Fermix should own; upgrade `Capability` metadata + dynamic prompt summary so the registry stays steerable as the catalog grows; ship a static self-knowledge skill.

**Shipped notes:** M7 keeps the catalog keyless in v1. It does not add cron-named duplicates because M4.11's job tool names are canonical. `git_push` remains deferred to M10 approval flow, and `http_request` remains deferred to the pluggable backend/config milestone.

See `docs/MILESTONE_7_ADVANCED_TOOLS.md` for the full design.

**Scope narrowed from "port all 47 RustyClaw tools."** M4.11 already shipped the canonical job/memory tools (`schedule_job`, `list_jobs`, `pause_job`, `resume_job`, `remove_job`, `memory_recall`, `memory_store`, `memory_sources_list`); the RustyClaw `cron_*` and `schedule` names are not added — they would duplicate M4.11 under different names. Extended-tool ports (SOP suite, hardware, composio, PDF/screenshot, etc.) move to "Future" — demand-driven, not part of M7.

**Every M7 built-in is keyless in v1.** No setup wizard prompts, no `[fermix_core.tools]` TOML section, no per-tool API-key persistence, no `BuiltinSeeder.reseed/1`. `web_search` ships with one backend (DuckDuckGo HTML SERP scrape — keyless, layout-fragile). The "pluggable backend per capability + paid alternatives + wizard surface for API keys" UX is its own future milestone (see "Pluggable Capability Backends" below).

### Built-ins added by M7

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Capability metadata schema** | `when_to_use`, `examples`, `failure_modes`, `requires_setup`, `category` keys on `Capability.metadata`; existing 12 tools migrated | P0 | New | M7 §4.1 | S |
| **`tool_help` capability** | On-demand expansion of full per-tool docs (description + parameters + examples + failure modes) | P0 | New | M7 §4.6 | S |
| **`file_edit`** | Unique-anchor string replacement, atomic write | P0 | Port | `src/tools/file_edit.rs` | S |
| **`glob_search`** | File pattern matching with bounded results | P1 | Port | `src/tools/glob_search.rs` | S |
| **`content_search`** | Pure-Elixir grep across the workspace | P1 | Port | `src/tools/content_search.rs` | S |
| **`git_read` / `git_write`** | Two tools, one per `policy_class` band — split because the registry filters at capability level, not per action. `git_push` deferred to M10 (needs `requires_approval?: true`, but the registry strips approval-required capabilities by default and AgentLoop has no opt-in path in M7). | P1 | Port (split) | `src/tools/git_operations.rs` | S |
| **`web_fetch`** | HTTP GET + HTML→markdown via Floki, keyless. All outbound URLs (initial + redirects) gated by `NetGuard`. | P0 | Port | `src/tools/web_fetch.rs` | S |
| **`web_search`** | DuckDuckGo HTML SERP scrape backend, keyless. One backend in M7 — pluggable backends + paid alternatives are the future "Pluggable Capability Backends" milestone. Failure contract is loud (`:rate_limited`, `:parser_changed`), not silent. | P0 | New | `src/tools/web_search_tool.rs` (shape only) | S |
| **`NetGuard` module** | Shared outbound-network safety contract. Hardcoded "public HTTP(S) only" rules: scheme allowlist, IP-literal block (RFC 1918 + loopback + link-local + IPv6), DNS resolution + recheck of every resolved address, redirect re-validation per hop, sensitive-header redaction. Used by `web_fetch` and `web_search`. | P0 | New | M7 §4.3a | S |
| **`delegate`** | Single-turn delegation to another model; `:external_api` policy class, recursion-guarded | P1 | Port | `src/tools/delegate.rs` | S |
| **`skill_create`** | Scaffold a `~/.fermix/skills/<name>/SKILL.md` | P1 | Port | `src/tools/skill_create.rs` | S |
| **`model_routing_config`** | Read/update `[fermix_core.routing]` via `ConfigStore` | P1 | Port | `src/tools/model_routing_config.rs` | S |

### Runtime plumbing M7 also lands

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **`RuntimeSections.capability_summary/0`** | Dynamic prompt summary generated from capability metadata; replaces hand-listed tool block in `agents.md.eex` | P0 | New | M7 §4.5 | S |
| **Self-knowledge skill** | Static `priv/skills/self_knowledge/SKILL.md` answering "what is Fermix" / "how do agents/jobs/memory/channels fit together" | P0 | New | M7 §4.7 | S |

### Capability Instructions and Fermix Self-Knowledge

Tool-use knowledge is owned by `CapabilityRegistry` via `Capability.metadata` (new schema in M7 §4.1). The main-agent runtime prompt summarizes broad routing rules; detailed tool behavior is generated by `RuntimeSections.capability_summary/0` (M7 §4.5) plus on-demand `tool_help` (M7 §4.6). Higher-level "how Fermix works" knowledge lives in the static self-knowledge skill (M7 §4.7), not in user memory or prompt prose.

**Stage gate before expanding the M7 tool catalog (or shipping `Default Skill Set`):**

- every new capability has `metadata.when_to_use` + at least one example
- the main agent prompt is generated from `capability_summary/0`, not hand-listed tool blocks
- full capability documentation reachable via `tool_help`, not in the base prompt
- tests cover at least one realistic main-agent tool-call path per tool family (M7 §7.3 manual steering check)

**Milestone 7 shipped:** built-in catalog, metadata schema, dynamic prompt summary, `tool_help`, self-knowledge skill, and user-facing built-in vs skill docs are implemented. Stage 3's accepted residual gap remains: DNS preflight blocks private resolutions, but full IP-pinned rebinding defense is still M10 security work.

---

## Milestone 7.1: Conversation Lifecycle — Threshold Compaction & Channel Commands

**Goal:** Operators can configure a context-window utilization threshold (e.g., `0.9` = compact when the conversation reaches 90 % of the model's context window), and end-users can drive conversation lifecycle from any channel via `/compact`, `/new`, and `/clear`. Today `Memory.Compactor` only runs when the agent loop opts into it; there is no auto-trigger tied to the model's context window, and channels have no command surface at all — every message is forwarded to `MainAgent` as raw user content.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Per-model context-window catalog** | Canonical `max_input_tokens` per model id, sourced from `Providers.ModelCatalog` (extends what M4.10 introduced for routing). Fallback policy for unknown models. | P0 | Modify | `apps/fermix_core/lib/fermix_core/providers/model_catalog.ex` | S |
| **`compaction.threshold` config key** | Float in `[0.1, 1.0]` in `[fermix_core.compaction]`, default `0.9`. Validated by `ConfigStore`. Wizard-writable. | P0 | New | `Memory.Compactor` | S |
| **Threshold-driven auto-compaction** | After each `MainAgent` turn, if `tokens_used / context_window >= threshold`, run `Compactor.compact/2` for the conversation key before the next turn. Telemetry: `[:fermix, :compaction, :auto]` with reason. | P0 | New | `Memory.Compactor` | M |
| **Channel command surface** | Shared parser+dispatcher in `fermix_channels` that recognizes leading `/<cmd>` (and `/<cmd>@bot` on Telegram) on inbound messages **before** they reach `MainAgent`. Pluggable command handlers receive normalized `Message.t()` + a `reply_fn`. | P0 | New | N/A | M |
| **`/compact` command** | Force-immediate `Compactor.compact/2` for the conversation; replies with before/after token counts. Bypasses the threshold check for one turn. | P0 | New | N/A | S |
| **`/new` & `/clear` commands** | Wipe the `ConversationStore` history for the current `conversation_key`, plus any provider-side per-conversation state (Codex `provider_state`, OpenAI Responses prior-input cache). Aliases of one another. Replies with a fresh-session marker. | P0 | New | `Memory.ConversationStore`, `MainAgent` | M |
| **Command authorization model** | Per-channel allow-list: which sender ids may run `/new`, `/clear`, `/compact`. Default: only the chat owner (operator) where the channel exposes that signal; otherwise everyone in 1:1 chats, no-one in groups. | P0 | New | N/A | S |
| **Local CLI parity** | `fermix ask /compact` and `fermix ask /new` go through the same channel-command surface (since `fermix ask` already dispatches via `FermixChannels.CLI`). | P1 | New | M7 review | XS |

### Open design questions

- **Auto-compaction policy.** Compactor today produces a single summary message. Options under threshold: (a) full single-summary replacement; (b) keep last N turns verbatim + summarize older; (c) hybrid that always preserves the system prompt + the active tool-call thread. Pick one for v1; the others are follow-ups.
- **Threshold scope.** Per-conversation only, or also per-skill/per-channel overrides? Default to global with `conversation_key` carrying the actual ratio measurement.
- **Codex provider_state lifecycle.** Codex's `prior_input` is replayed across turns and is what actually drives token growth. `/new` must reset it; auto-compaction must rewrite it. Confirm the rewrite path doesn't drop replayable reasoning items needed for tool-call continuity.
- **Command syntax cross-channel.** Telegram uses `/cmd@botname` for group disambiguation; Slack uses `/cmd` as a true slash command (separate webhook); Discord uses application commands; WhatsApp/Signal have no native slash. v1 should be plain `/cmd` at message start in the inbound text payload, with Telegram's `@botname` suffix stripped — full slash-command-API integration is per-channel follow-up work.
- **`/help` and command discovery.** Out of scope or in scope? At minimum `/help` should list available commands; otherwise users have to read the docs to know `/compact` exists.
- **Permission model edge cases.** What about scheduled jobs that originate from a channel — should the job's reply path inherit the originator's permission to run `/new` on its own conversation? Probably yes, but worth stating.

### Why a separate milestone

These are three coherent features that depend on each other:

1. Auto-compaction needs a per-model context-window number and a threshold config key.
2. `/compact` needs a channel-command surface to trigger compaction without going through the LLM.
3. `/new` and `/clear` need the same surface, plus provider-state wipe coordination.

Folding any one into M4.11 (Scheduled Agents) or M6 (DX) means designing the channel-command pipeline twice. Splitting auto-compaction from the user-driven commands ships a half-feature where operators can set a threshold but users can't manually trigger it.

**Depends on M4.11:** the `/new` wipe path needs to handle scheduled-job conversation keys correctly (they share `ConversationStore` infrastructure), so M4.11's source-aware memory shape should land first.

**Milestone 7.1 Total Agent Wall-Clock:** ~6–9 hours. Channel-command parser + per-channel `@botname` handling is the only realistic source of variance.

See `docs/MILESTONE_7_1_CONVERSATION_LIFECYCLE.md` for the full design.

---

## Milestone 7+: Pluggable Capability Backends — _Reserved (operator-scoped)_

**Goal:** Per-capability backend choice (e.g., `web_search` → Parallel REST | Tavily | DDG-default), API-key wizard surface, `[fermix_core.tools.<name>]` TOML schema with `ConfigStore` round-trip, `BuiltinSeeder.reseed/1` for live re-registration after the wizard writes a key, daemon control-socket `:reseed_builtins` request, doctor probes per backend, **and `http_request` tool** (deferred from M7 because it requires per-tool `[http_request].allowed_domains` config that this milestone provides — see RustyClaw `src/tools/http_request.rs:47`). This milestone also owns bounded DNS preflight behavior for `NetGuard`-backed tools: explicit DNS lookup timeouts and, if measurements show repeated resolver cost, a small per-daemon cache for successful public resolutions.

Separately tracked: **`git_push`** is deferred to **M10** (Security & Governance), not here. It's not a per-tool config problem — it's an approval-flow problem. M10 owns the `requires_approval?: true` exposure path (`include_approval_required?: true` opt threading through AgentLoop, `/approve` UX, etc.) which `git_push` and any future approval-gated capability need.

Not part of M7 — folding even a stripped-down version into M7 means designing the same plumbing twice when this milestone properly lands.

See `docs/MILESTONE_7_PLUS_PLUGGABLE_BACKENDS.md` for the full design.

---

## Milestone 8: Production Readiness

**Goal:** Observability, deployment, clustering, and operational excellence.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Telemetry integration** | Prometheus metrics, OpenTelemetry | P0 | New | N/A | M |
| **Structured logging** | JSON logs with correlation IDs | P0 | New | N/A | S |
| **Health checks** | Readiness/liveness endpoints | P0 | New | N/A | S |
| **Clustering support** | Multi-node deployment with libcluster | P1 | New | N/A | L |
| **Database pooling** | Connection pooling for SQLite/Postgres | P1 | New | N/A | S |
| **Rate limiting** | Per-user/per-channel rate limits | P1 | New | N/A | M |
| **Circuit breakers** | Fault tolerance for external APIs | P1 | New | N/A | M |
| **Graceful shutdown** | Drain connections on SIGTERM | P1 | New | N/A | S |
| **Docker images** | Production-ready Docker builds | P1 | New | N/A | M |
| **Fly.io deployment** | Deployment guide for Fly.io | P2 | New | N/A | S |
| **Systemd service** | Linux service integration | P2 | New | N/A | S |
| **Backup automation** | Automated memory/config backups | P1 | New | N/A | M |
| **Performance testing** | Load tests for agent throughput | P2 | New | N/A | M |
| **Benchmarking suite** | Tool execution benchmarks | P2 | New | N/A | M |

**Milestone 8 Total Effort:** ~8-12 weeks

---

## Milestone 9: Differentiators

**Goal:** Features that go beyond RustyClaw/OpenClaw to make Fermix unique.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Heartbeat system** | Proactive periodic checks (email, calendar, weather) | P1 | New | OpenClaw AGENTS.md | M |
| **Reaction support** | Emoji reactions for group chats | P1 | New | OpenClaw AGENTS.md | S |
| **Smart presence** | Know when to speak vs stay silent in groups | P1 | New | OpenClaw AGENTS.md | M |
| **Multi-workspace** | Support multiple isolated agent workspaces | P1 | New | `docs/MAIN_AGENT_DESIGN.md` | L |
| **Visual context** | Screenshot analysis, image understanding | P1 | New | N/A | M |
| **Self-knowledge agent** | Persistent subagent with full Fermix codebase knowledge — can modify Fermix itself when user requests platform changes | P1 | New | N/A | L |
| **Realtime local voice companion** | Native macOS floating pet that opens a click-to-talk OpenAI Realtime session through the local daemon; command-word and always-listening modes are later opt-in phases | P1 | New | `docs/MILESTONE_9_1_REALTIME_VOICE.md` | L |
| **Full-duplex voice cleanup** | Mac-first Realtime pass that enables graceful echo-cancellation fallback, removes local half-duplex timeout/input caps, aligns setup prompts with `gpt-realtime-2`, and rejects old voice mode knobs loudly | P1 | Follow-up | `docs/MILESTONE_9_2_FULL_DUPLEX_VOICE.md` | M |

**Milestone 9 Total Effort:** ~8-12 weeks

See `docs/MILESTONE_9_1_REALTIME_VOICE.md` and
`docs/MILESTONE_9_2_FULL_DUPLEX_VOICE.md` for the voice designs.

---

## Milestone 10: Security & Governance

**Goal:** Production-grade security with tool ACLs, approval workflows, and content filtering — added _last_ on purpose, after the feature surface has settled and we have observed real usage patterns. Earlier milestones (M4.9 capabilities, M4.11 scheduled agents) leave hooks (`requires_approval?`, `policy_class`, static-config gating) for M10 to bind to.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Security policy** | Tool ACLs and operation enforcement | P0 | Rewrite | `src/security/policy.rs` | L |
| **Approval manager** | `/approve` commands, auto_approve, always_ask | P0 | Rewrite | `src/security/mod.rs` | M |
| **Sentinel engine** | LLM-based content filtering middleware | P1 | Rewrite | `src/security/sentinel/` | L |
| **Content scanner** | Scan for secrets, PII, malicious content | P0 | Rewrite | `src/security/content_scanner.rs` | M |
| **Leak detector** | Detect credential/secret leaks in agent output | P0 | Rewrite | `src/security/leak_detector.rs` | M |
| **Secrets manager** | Secure credential storage | P1 | Rewrite | `src/security/secrets.rs` | M |
| **Prompt guard** | Prompt injection detection | P1 | Rewrite | `src/security/prompt_guard.rs` | M |
| **Audit logging** | Security event logging | P1 | Rewrite | `src/security/audit.rs` | S |
| **E-stop** | Emergency stop for runaway agents | P1 | Rewrite | `src/security/estop.rs` | M |

**Milestone 10 Total Effort:** ~8-10 weeks

---

## Additional Providers (Ongoing)

**Note:** The regular OpenAI provider should use the official OpenAI Responses API (`api.openai.com/v1/responses`) with standard API keys. Codex remains a separate `openai_codex` provider because it uses a different auth source, endpoint, and streaming shape. Low effort (S), do before adding more providers.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **OpenAI Responses API unification** | _Absorbed by M4.9 (Unified Capabilities) — see `docs/MILESTONE_4_9_UNIFIED_CAPABILITIES.md`._ Migrate api_key path from Chat Completions to official Responses API; unify with oauth path | P1 | New | N/A | S |
| **OpenRouter provider** | Meta-provider for many models | P1 | Rewrite | `src/providers/openrouter.rs` | M |
| **Ollama provider** | Local model support | P1 | Rewrite | `src/providers/ollama.rs` | M |
| **Gemini provider** | Google Gemini API | P1 | Rewrite | `src/providers/gemini.rs` | L |
| **Compatible provider** | Generic OpenAI-compatible provider | P1 | Rewrite | `src/providers/compatible.rs` | L |
| **Reliable wrapper** | Retry/fallback/timeout wrapper | P0 | Rewrite | `src/providers/reliable.rs` | L |
| **Router provider** | Multi-provider routing logic | P1 | Rewrite | `src/providers/router.rs` | M |

**Provider Total Effort:** ~6-8 weeks

---

## Future: Full Ecosystem Expansion

**Goal:** Comprehensive coverage after the core is stable and proven. Bring items forward as needed once corresponding milestones are complete.

### Additional Channels

| Feature | Description | Type | Reference | Effort |
|---------|-------------|------|-----------|--------|
| **IRC channel** | IRC protocol, multi-server support | Rewrite | `src/channels/irc.rs` | M |
| **Matrix channel** | Matrix homeserver client | Rewrite | `src/channels/matrix.rs` | L |
| **Email channel** | IMAP/SMTP for email-based interactions | Rewrite | `src/channels/email_channel.rs` | L |
| **iMessage channel** | iMessage via AppleScript on macOS | Rewrite | `src/channels/imessage.rs` | M |
| **Mattermost channel** | Mattermost API integration | Rewrite | `src/channels/mattermost.rs` | M |
| **Lark/Feishu channel** | ByteDance enterprise messenger | Rewrite | `src/channels/lark.rs` | L |
| **DingTalk channel** | Alibaba enterprise messenger | Rewrite | `src/channels/dingtalk.rs` | M |
| **QQ channel** | Tencent QQ messaging | Rewrite | `src/channels/qq.rs` | M |
| **Nostr channel** | Decentralized protocol | Rewrite | `src/channels/nostr.rs` | M |
| **LINQ channel** | Enterprise communication | Rewrite | `src/channels/linq.rs` | M |
| **MQTT channel** | IoT/lightweight messaging | Rewrite | `src/channels/mqtt.rs` | S |
| **Nextcloud Talk channel** | Self-hosted Nextcloud chat | Rewrite | `src/channels/nextcloud_talk.rs` | M |
| **ClawdTalk channel** | Custom protocol | Rewrite | `src/channels/clawdtalk.rs` | M |
| **WATI channel** | WhatsApp Team Inbox API | Rewrite | `src/channels/wati.rs` | S |
| **WhatsApp Web channel** | Browser-based WhatsApp automation | Rewrite | `src/channels/whatsapp_web.rs` | M |

### Extended Security

| Feature | Description | Type | Reference | Effort |
|---------|-------------|------|-----------|--------|
| **Domain matcher** | URL/domain allowlisting | Rewrite | `src/security/domain_matcher.rs` | S |
| **OTP support** | Two-factor authentication | Rewrite | `src/security/otp.rs` | S |
| **Pairing system** | Device pairing for authorization | Rewrite | `src/security/pairing.rs` | M |
| **Sandboxing (Landlock)** | Linux sandboxing via Landlock LSM | Rewrite | `src/security/landlock.rs` | M |
| **Sandboxing (Bubblewrap)** | Linux sandboxing via bubblewrap | Rewrite | `src/security/bubblewrap.rs` | S |
| **Sandboxing (Firejail)** | Linux sandboxing via firejail | Rewrite | `src/security/firejail.rs` | S |
| **Sandboxing (Docker)** | Docker container isolation | Rewrite | `src/security/docker.rs` | S |

### Extended Tools

| Feature | Description | Type | Reference | Effort |
|---------|-------------|------|-----------|--------|
| **pdf_read** | Read/extract text from PDFs | Rewrite | `src/tools/pdf_read.rs` | M |
| **image_info** | Extract image metadata | Rewrite | `src/tools/image_info.rs` | S |
| **browser_open** | Open URLs in user's browser | Rewrite | `src/tools/browser_open.rs` | S |
| **cron_run** | Manually trigger cron job | Rewrite | `src/tools/cron_run.rs` | S |
| **cron_runs** | List cron execution history | Rewrite | `src/tools/cron_runs.rs` | S |
| **skill_edit** | Edit skill template | Rewrite | `src/tools/skill_edit.rs` | S |
| **skill_patch** | Patch skill template | Rewrite | `src/tools/skill_patch.rs` | S |
| **skill_delete** | Delete skill template | Rewrite | `src/tools/skill_delete.rs` | S |
| **sop_execute** | Execute defined procedure | Rewrite | `src/tools/sop_execute.rs` | M |
| **sop_list** | List available SOPs | Rewrite | `src/tools/sop_list.rs` | S |
| **sop_advance** | Advance SOP to next step | Rewrite | `src/tools/sop_advance.rs` | S |
| **sop_approve** | Approve SOP step | Rewrite | `src/tools/sop_approve.rs` | S |
| **sop_status** | Check SOP execution status | Rewrite | `src/tools/sop_status.rs` | S |
| **composio** | Composio integration (hundreds of integrations) | Rewrite | `src/tools/composio.rs` | L |
| **pushover** | Pushover notification service | Rewrite | `src/tools/pushover.rs` | S |
| **screenshot** | System screenshot capture | Rewrite | `src/tools/screenshot.rs` | M |
| **hardware_board_info** | Board/system info | Rewrite | `src/tools/hardware_board_info.rs` | S |
| **hardware_memory_map** | Memory mapping info | Rewrite | `src/tools/hardware_memory_map.rs` | S |
| **hardware_memory_read** | Read hardware memory | Rewrite | `src/tools/hardware_memory_read.rs` | S |
| **proxy_config** | Configure HTTP/SOCKS proxy | Rewrite | `src/tools/proxy_config.rs` | S |
| **synth_proxy** | API synthesis proxy | Rewrite | `src/tools/synth_proxy.rs` | M |
| **cli_discovery** | Discover available CLI tools | Rewrite | `src/tools/cli_discovery.rs` | S |

### Extended Differentiators

| Feature | Description | Type | Reference | Effort |
|---------|-------------|------|-----------|--------|
| **Voice storytelling** | TTS integration for narratives; interactive live voice is tracked separately in M9.1 | New | OpenClaw AGENTS.md | M |
| **Agent personality** | Configurable tone/style per workspace | New | N/A | M |
| **Context awareness** | Time-of-day, location-based behavior | New | N/A | M |
| **Axon integration** | Agent-to-agent mesh protocol | Hybrid | `projects/agent-mesh` | XL |
| **Plugin system** | Third-party tool/channel plugins | New | N/A | L |
| **Proactive suggestions** | Agent suggests optimizations unprompted | New | N/A | L |
| **Learning from feedback** | Improve from user corrections over time | New | N/A | L |
| **Mobile app** | Native iOS/Android apps | New | N/A | XL |
| **Browser extension** | Chrome/Firefox extension for web context | New | N/A | L |
| **Collaborative agents** | Multiple agents working on same task | New | N/A | XL |

### Extended Providers

| Feature | Description | Type | Reference | Effort |
|---------|-------------|------|-----------|--------|
| **Bedrock provider** | AWS Bedrock integration | Rewrite | `src/providers/bedrock.rs` | L |
| **Copilot provider** | GitHub Copilot API | Rewrite | `src/providers/copilot.rs` | M |
| **GLM provider** | ChatGLM integration | Rewrite | `src/providers/glm.rs` | M |
| **Telnyx provider** | Telnyx AI API | Rewrite | `src/providers/telnyx.rs` | M |
| **OpenAI Codex provider** | Codex-specific optimizations | Rewrite | `src/providers/openai_codex.rs` | M |

**Future Total Effort:** ~60+ weeks (demand-driven, not scheduled)

---

## Summary by Priority

### Core Milestones (M2–M9) — ~50-60 weeks total
- Multi-agent orchestration (AgentServer, Supervisor, Main Agent, skill invocation)
- WhatsApp, Discord, Signal, Slack, CLI channels
- Advanced memory (Hermes extraction, Honcho AI/wiki-style, gist, compaction, SQLite)
- Security core (policy, approval, content scanner, leak detector, Sentinel, prompt guard, e-stop)
- LiveView dashboard, CLI, cron scheduler
- Core tools (file_edit, web_fetch, web_search, browser, git_read/git_write, delegate, model_routing_config, skill_create, NetGuard) — cron-named scheduling tools shipped under M4.11; `git_push` and `http_request` deferred (M10 and M7+ respectively)
- Production ops (telemetry, health checks, logging, clustering, rate limiting)
- Core providers (OpenRouter, Ollama, Gemini, Compatible, Reliable, Router)
- Differentiators (heartbeat, reactions, smart presence, multi-workspace, visual context, self-knowledge agent, realtime local voice companion)

### Future Ecosystem — ~60+ weeks (demand-driven)
- 15 additional channels (IRC, Matrix, email, enterprise messengers, niche protocols)
- Extended security (sandboxing variants, OTP, pairing, domain matcher)
- Extended tools (SOP suite, hardware, composio, PDF, screenshots)
- Extended differentiators (Axon, plugins, mobile apps, narrative voice, personality)
- Niche providers (Bedrock, Copilot, GLM, Telnyx, Codex)

---

## Recommended Sequence

**After Phase 1 MVP:**
1. **Milestone 2** (Multi-Agent Orchestration) — unlocks delegation
2. **Milestone 4** (Advanced Memory) — unlocks long-term context
3. **Milestone 3** (WhatsApp, Discord, Signal, Slack, CLI) — core channels
4. **Milestone 5** (Workspace Sandbox + OS-keyring credentials) — ship the floor under tool execution; M10 hardens on top later
5. **Milestone 6** (Dashboard + CLI) — operational visibility
6. **Milestone 8** (Production ops) — deployment readiness
7. **Milestone 7** (Core tools) — essential feature parity
8. **Milestone 9** (Differentiators) — unique value
9. **Milestone 10** (Security ceiling: Sentinel, leak detector, approval UX) — tighten _after_ feature exploration; bind to the policy hooks left by M4.9 / M4.11 and the sandbox/keystore hooks from M5
10. **Future** (Extended ecosystem) — demand-driven expansion

**Total estimated time for core (M2–M10):** ~6-9 months full-time with AI assistance. Future items are demand-driven.

---

## Open Questions

1. **PostgreSQL vs SQLite?** — SQLite works for single-node, Postgres needed for clustering
2. **Axon integration strategy?** — Separate project or merge into Fermix?
3. **Open source timing?** — When to release under sixteen.dev?
4. **Mobile-first strategy?** — Native apps or PWA?
5. **Enterprise features?** — RBAC, multi-tenancy, SSO?
6. **Cloud hosting?** — Fermix Cloud as a service offering?
7. **Honcho AI vs Hermes vs Wiki memory?** — Evaluate Honcho AI (self-learning + dreaming, heavy Docker), wiki-style memory (lightweight LLM-wiki), and Hermes consolidation — pick the simplest that meets needs
8. **Browser tool auto-update?** — agent-browser is an external engine; need a mechanism to keep it current

---

## Related Documents

- `docs/PROJECT_PLAN.md` — Overall architecture and Phase 1-5 plan
- `docs/PHASE1_TASKS.md` — Detailed Phase 1 task breakdown
- `docs/MAIN_AGENT_DESIGN.md` — Main Agent architecture (RustyClaw reference)
- `docs/OPTION_B_ORCHESTRATION_DESIGN.md` — Skill orchestration design (RustyClaw reference)
- `docs/hermes-memory-design.md` — Hermes memory extraction (RustyClaw reference)
- `/Users/sujshe/projects/rustyclaw/` — RustyClaw reference implementation
- `/Users/sujshe/.openclaw/workspace/AGENTS.md` — OpenClaw agent behavior patterns
