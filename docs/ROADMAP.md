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
| **`[mcp.servers.<name>]` config** | TOML block with `command`, `args`, `env`; `$env:VAR` prefix for shell-env references | P0 | New | N/A | S |
| **Anthropic adapter scaffold** | Real `to_provider_tools` (input_schema rename); `chat/3` returns `{:error, :not_implemented}` until tokens land | P1 | New | N/A | S |
| **Per-skill `provider:` override** | Optional frontmatter field; lets skills pin a specific provider | P1 | New | N/A | S |
| **Telemetry uniformity** | `[:fermix, :capability, :exec]` across all kinds; replaces per-tool/per-skill events with overlap during migration | P1 | Refactor | N/A | S |
| **Removal of `Tools.Registry`, `Tools.Tool`, `Tools.InvokeSkill`** | After Stage 4 cutover; no deprecation shim — fermix has 3 baked skills, no external consumers | P0 | Removal | N/A | S |

**Migration safety:** Stages 1–4 run old + new registries side-by-side; old path deletion happens only at Stage 4 ship gate. Behaviour fixtures pin OpenAI request bodies for each baked skill across the migration. End-to-end Telegram smoke test required at every stage gate.

**Multi-provider note:** The `Additional Providers (Ongoing)` section's "OpenAI Responses API unification" item is absorbed by this milestone. The `Reliable wrapper`, `Router provider`, and concrete `Anthropic`, `Gemini`, `OpenRouter`, `Ollama` adapters remain separate work items — M4.9 only delivers the abstraction layer they will plug into.

**Milestone 4.9 Total Effort:** ~3-4 weeks

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

## Milestone 5: _Reserved_

_Security & Governance was originally numbered M5; it has been moved to **M10** so feature exploration can run unconstrained first and security can be tightened against observed real-world usage rather than guessed-at threats. See M10 below._

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

## Milestone 7: Advanced Tools

**Goal:** Port all 47 RustyClaw tools for feature parity.

### File & Code Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **file_edit** | Precise text replacement in files | P0 | Rewrite | `src/tools/file_edit.rs` | M |
| **git_operations** | Git commands (commit, push, branch, etc.) | P1 | Rewrite | `src/tools/git_operations.rs` | M |
| **glob_search** | Fast file pattern matching | P1 | Rewrite | `src/tools/glob_search.rs` | S |
| **content_search** | Grep-like content search | P1 | Rewrite | `src/tools/content_search.rs` | M |

### Web & Network Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **web_fetch** | HTTP fetch + content extraction | P0 | Rewrite | `src/tools/web_fetch.rs` | M |
| **web_search_tool** | DuckDuckGo/web search | P1 | Rewrite | `src/tools/web_search_tool.rs` | M |
| **http_request** | Generic HTTP client tool | P1 | Rewrite | `src/tools/http_request.rs` | M |
| **browser** | Builtin computer-use tool via [agent-browser](https://github.com/vercel-labs/agent-browser) CLI — native Rust, accessibility tree snapshots with refs, no Playwright dependency. Needs auto-update mechanism for external engine | P0 | New | N/A | M |

### Delegation & Orchestration Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **delegate** | Single-turn delegation to another model | P1 | Rewrite | `src/tools/delegate.rs` | M |
| **schedule** | Schedule future tasks | P1 | Rewrite | `src/tools/schedule.rs` | M |

### Cron Management Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **cron_add** | Add cron job | P1 | Rewrite | `src/tools/cron_add.rs` | S |
| **cron_list** | List cron jobs | P1 | Rewrite | `src/tools/cron_list.rs` | S |
| **cron_remove** | Remove cron job | P1 | Rewrite | `src/tools/cron_remove.rs` | S |
| **cron_update** | Update cron job | P1 | Rewrite | `src/tools/cron_update.rs` | S |

### Skill Management Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **skill_create** | Create new skill template | P1 | Rewrite | `src/tools/skill_create.rs` | M |

### Configuration Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **model_routing_config** | Configure model routing | P1 | Rewrite | `src/tools/model_routing_config.rs` | M |

**Milestone 7 Total Effort:** ~8-12 weeks (can parallelize by category)

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

**Milestone 9 Total Effort:** ~8-12 weeks

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
| **Voice storytelling** | TTS integration for narratives | New | OpenClaw AGENTS.md | M |
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
- Core tools (file_edit, web_fetch, browser, git, delegate, web search, model routing, cron, skill_create)
- Production ops (telemetry, health checks, logging, clustering, rate limiting)
- Core providers (OpenRouter, Ollama, Gemini, Compatible, Reliable, Router)
- Differentiators (heartbeat, reactions, smart presence, multi-workspace, visual context, self-knowledge agent)

### Future Ecosystem — ~60+ weeks (demand-driven)
- 15 additional channels (IRC, Matrix, email, enterprise messengers, niche protocols)
- Extended security (sandboxing variants, OTP, pairing, domain matcher)
- Extended tools (SOP suite, hardware, composio, PDF, screenshots)
- Extended differentiators (Axon, plugins, mobile apps, voice, personality)
- Niche providers (Bedrock, Copilot, GLM, Telnyx, Codex)

---

## Recommended Sequence

**After Phase 1 MVP:**
1. **Milestone 2** (Multi-Agent Orchestration) — unlocks delegation
2. **Milestone 4** (Advanced Memory) — unlocks long-term context
3. **Milestone 3** (WhatsApp, Discord, Signal, Slack, CLI) — core channels
4. **Milestone 6** (Dashboard + CLI) — operational visibility
5. **Milestone 8** (Production ops) — deployment readiness
6. **Milestone 7** (Core tools) — essential feature parity
7. **Milestone 9** (Differentiators) — unique value
8. **Milestone 10** (Security core: policy, approval, content scanner) — tighten _after_ feature exploration; bind to the policy hooks already left by M4.9 / M4.11
9. **Future** (Extended ecosystem) — demand-driven expansion

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
