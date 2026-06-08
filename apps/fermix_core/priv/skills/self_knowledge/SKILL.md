---
name: self-knowledge
description: Use when the user asks what Fermix is, what it can do, or how its agent loop, providers, channels, jobs, memory, sandbox, built-ins, skills, plugins, and config/setup surfaces fit together.
allowed_tools: []
---

# Fermix self-knowledge

Fermix is an Elixir/OTP agent daemon. `fermix run` or the OS service starts one BEAM VM; the CLI talks to it over `$FERMIX_HOME/daemon.sock`. Channel messages enter the gateway, run one agent turn, execute capabilities through the registry, and reply through the originating channel.

## Runtime shape

- Main Agent caches runtime context; channel messages go through the gateway, not directly to Main Agent.
- Gateway serializes one FIFO turn per conversation; different conversations run concurrently.
- Turn flow: read history -> build prompt -> model/tool loop -> reply -> commit messages -> background memory review -> optional auto-compaction.
- Main turns and new scheduled jobs default to 100 iterations. Regular `subagents` fan out wide (hard-max 10 tasks, ≤8 concurrent — default 4; 100 iterations each). `/ultra` is a **run-mode of the normal turn** (not a separate orchestrator): the `/ultra` command tags the turn `run_profile: :ultra`, which runs the ordinary agent loop with the wider `subagents` caps unlocked (`subagent_mode: :ultra` → up to ~50 narrow probes, ≤12 concurrent, reduced per-probe depth) and an exhaustive-mode prompt addendum. Because it is a normal turn, its workers nest under the parent trace like regular `subagents`. Workers are kept brief by instruction (their prompt tells them to gather one narrow thing and stop), not by a low ceiling. Repeated identical tool calls trip the loop detector. These breadth/depth knobs are system-side config (`:subagents`, `:ultra`, `:iteration_limits`), not a `config.toml` surface.

## Providers

Provider selection is **primary-flag driven**: each `[fermix_core.providers.<name>]` block carries `primary = true|false`, exactly one provider is primary, and every other *configured* provider is an automatic fallback (deterministic catalog order: `openai_codex`, `openai`, `anthropic`, `xai`). Setup marks a newly configured provider primary by default and clears the old flag (settings/credentials are kept); the web setup provider page renders per-provider cards (status: Primary / Fallback / Not configured) as the provider selector — picking a card loads that provider into the "Configuring …" form, and saving it makes it the primary (needs a daemon restart); a configured, non-primary card also shows a "Set primary" button that flips the primary flag without re-entering credentials. Nothing is disabled, so any provider can be selected and set up. A Realtime API key reuses the OpenAI provider key slot but does **not**, on its own, promote OpenAI to primary — only a real provider credential or an explicit primary choice does. CLI OAuth login never changes primary. The legacy `[fermix_core.agent] provider` key is read-only migration input (used only when no `primary` flag exists; setup stops writing it). Routes are snapshotted at boot for main turns (restart to apply changes); scheduled jobs without an explicit provider resolve the chain at execution time — that asymmetry is intentional. **Failover** happens only on the turn's initial model call for transient errors (timeout/transport/5xx/rate-limit/quota, or a residual OAuth auth failure after the adapter's own refresh+retry); API-key auth failures, context-length, tool errors, mid-tool-loop (`continue`) errors, and mid-stream failures after visible streamed content never fail over. Failovers emit `[:fermix, :provider, :failover]` telemetry, `fermix doctor` lists configured fallbacks, and agent status exposes `primary_provider`/`fallback_providers`. Values: `openai`, `openai_codex`, `anthropic`, `xai`. All four run turns. xAI Grok supports two auth modes via `[fermix_core.providers.xai] auth_mode = "api_key" | "oauth"`: bearer API key (`api_key`, `XAI_API_KEY`), or Grok Build subscription OAuth (loopback PKCE, profile `xai_oauth`; connect with `fermix auth login --provider xai`; a 403 means the Grok plan lacks API access — not a stale token). Both ride the OpenAI Responses wire shape with efforts `none|low|medium|high` (some Grok models reject effort and get it omitted; slash-containing enum values are stripped from tool schemas). Anthropic supports two auth modes via `[fermix_core.providers.anthropic] auth_mode = "api_key" | "oauth"`: API key (`api_key`), or Claude subscription OAuth (profile `anthropic_oauth` in auth.json; connect with `fermix auth login --provider anthropic` using `--setup-token`, `--import-claude-code`, or `CLAUDE_CODE_OAUTH_TOKEN`). OAuth requests emulate Claude Code (identity headers + system block, `mcp_`-prefixed tool names) and auto-refresh with one 401 retry. All Anthropic requests send prompt-cache breakpoints and cap non-streaming output at `max_tokens` 8192. Per-provider model/effort: `[fermix_core.providers.<name>]` (`default_model`, `reasoning_effort` — all four providers; Codex-only `fast`). Reasoning effort is one canonical vocabulary (`FermixCore.Providers.ReasoningEffort`: `none|low|medium|high|xhigh|max`) with per-provider subsets, mapped to each provider's wire field (OpenAI/Codex/xAI `reasoning.effort`; Anthropic `output_config.effort`). Anthropic has no `none` (floor `low`, API default `high`); a level above a provider's ceiling clamps. Both the CLI wizard and web setup offer effort for all four providers. `auth_mode` (`api_key`/`oauth`) round-trips through config for xAI and Anthropic. The web setup provider page has an API-key vs OAuth picker per provider (xAI = loopback "Connect Grok" like Codex; Anthropic = paste a `claude setup-token` or import a Claude Code login). A stored token is inert until `auth_mode = "oauth"`, so connecting in the web AND `fermix auth login --provider xai|anthropic` both set `auth_mode = oauth` in config (and `fermix auth logout` reverts to `api_key`); the change needs a daemon restart.

Provider/channel HTTP uses shared `FermixCore.Finch`. Idle keep-alive connections older than 15s are discarded at checkout. Codex retries `:closed` once only when it happens before response data; mid-response `:closed` and `:timeout` are not retried.

## Built-in capabilities

Built-ins seed into the single capability registry at boot; outbound MCP tools register as `mcp_<server>_<tool>`. The runtime prompt's `## Built-in Capability Catalog` is authoritative; use `tool_help` for one tool's schema/failure modes.

- **Files & search**: `file_read`, `file_write`, `file_edit`, `glob_search`, `content_search`
- **Shell & git**: `shell`, `git_read`, `git_write` (no push)
- **Web**: `web_search` (static facts/no URL), `web_fetch` (one known server-rendered URL), `browser` (JS/dynamic/interactive; `fill` replaces, `type` appends, `submit` submits; receipts are immediate; verify async changes with `wait`/`get`; see `browser-guidance`). Never shell-scrape JS sites.
- **Memory**: `memory_store`, `memory_recall`, `memory_sources_list`
- **Jobs**: `schedule_job`, `update_job`, `list_jobs`, `pause_job`, `resume_job`, `remove_job`
- **Skills & delegation**: `skill_view`, `skill_run`, `skill_list`, `skill_create`, `subagents` (bounded temp sub-agents)
- **Meta**: `tool_help`, `send_attachment` (local sandbox file; URLs rejected), `model_routing_config` (writes `[fermix_core.routing]`; not yet consumed at runtime)

Built-ins need no API keys except alternate backends/integrations; default `web_search` is DuckDuckGo. If a configured non-DuckDuckGo backend (Brave/Exa/Tavily/etc.) hard-errors (auth, credits/HTTP 402, transport), `web_search` degrades once to keyless DuckDuckGo — loudly (a warning log + `degraded`/`primary_backend`/`fallback_reason` in the trace), not silently — so the broken backend stays visible. Empty results do not trigger the degrade.

## Skills

Skills are `SKILL.md` instruction packages, not provider-visible tools. `skill_view` loads a body; `skill_run` delegates as a sub-agent (recursion cap 4); `skill_list` enumerates. Bundled `priv/skills` and local `~/.fermix/skills` load at operator trust; plugin skills load at guest trust. `allowed_tools` narrows the trust default (`[]` = none, absent = trust default). `skill_create` writes to `~/.fermix/skills`; CLI: `fermix skills list|view NAME|reload`.

## Memory

Durable memory is SQLite at `~/.fermix/memory.db`; ETS is cache. `memory_recall` does key lookup or FTS5 search over memories/history with `scope` (`current|owner|all`) and `source` (`memories|history|all`). Background review curates facts; CLI: `fermix memory review --now`, `fermix memory restore ID`.

## Jobs

`schedule_job` creates durable work without running it now. Schedule forms: interval (`every N minutes|hours|days`), one ISO8601 datetime (`once`), or 5-field cron; free-form English is rejected. Runs are isolated bounded agent loops and cannot see the creating chat, so include needed facts in task text. `expires_at` makes a temporary job; `delivery_mode` is `none|origin|channel|local`.

## Channels & access control

Channels: Telegram, WhatsApp, Slack, Discord, Signal (text + media), plus local `cli` and `daemon`. Remote channels refuse to start without `owner_user_id` or `allowed_*_ids`.

Live streaming (off by default): `[fermix_channels.<name>] streaming = "draft" | "block"`. `"draft"` shows the reply as one draft message edited in place (~1/s, ≥30 chars before the draft opens) and sealed to the final authoritative text; `/stop` deletes the draft; needs a draft-capable channel (Telegram today; `fermix doctor` warns otherwise). `"block"` sends each completed model "thought" as its own ordinary message (semantic boundary = completed output item; 800–1200-char paragraph chunking only as the long-text fallback, 1 s idle flush), including the model's 💭 reasoning-summary headings as separate one-line messages — works on every channel, and pre-tool commentary lands as its own message. Both need a streaming provider (Codex today — others simply deliver normally). Only real channel turns stream — background/CLI/cron runs never do. Stream telemetry: `[:fermix, :channel, :stream]` with `phase` open/edit/block/seal/discard and the turn's `session_id`.

Gateway trust: **operator** (`owner_user_id` or any local caller) gets full surface; **guest** gets read-only chat: no skills, MCP, exec, or network. `allowed_*_ids` authorizes chat only, not operator promotion.

Slash commands are pre-agent: `/help`, `/whoami` for any authorized sender. Operator-only: `/compact`, `/new` (`/clear`), `/sandbox` (`/grant`, `/revoke`, `/confirm`), `/stop`, `/background` (`/bg`), `/tasks`, `/ultra`. Guests can be opted into owner-only commands via `command_allowlist`. Auto-compaction runs after reply at threshold (default 0.85); `/compact` forces it.

`/stop` kills active turns and clears pending work; the stopped turn neither delivers nor commits a reply. Its user message was already persisted at turn start, so the gateway appends a short assistant marker after it ("stopped before I finished … context only") — the discarded request stays in history/memory but the next turn does not replay and answer it. The marker is only added when the conversation's last stored message is that orphaned user turn (no double-marking, role alternation preserved).

## Sandbox

Filesystem/exec built-ins (`shell`, `file_*`, search, `git_*`, `send_attachment`) go through the sandbox. Modes: `strict` (workspace), `standard` (default: workspace + launch cwd + common project dirs), `open` (home). Protected paths (`~/.ssh`, `~/.aws`, Fermix internals, OS roots) and catastrophic commands are denied in every mode. Child env is minimal; secrets come from host env, keyring, or `source = "command"` helpers. Roots: `fermix grant|revoke path PATH`, `fermix sandbox ...`, or `/sandbox`. Command profiles expose extra local commands as tools.

## Plugins

Bundled OAuth plugins: Gmail, Google Calendar, Google Drive. A connected plugin registers all its tools; if a tool's scope wasn't granted, calling it returns a graceful "reauthorize" error rather than the tool vanishing. Other Google 403s are classified distinctly (file-permission, organizer-only, rate-limit) so the message says what actually failed. Manage with `fermix plugins enable|disable NAME` and `fermix plugins auth login|reauthorize|refresh|logout NAME`; tokens/scopes live in `~/.fermix/auth.json`. Plugin skills load at guest trust.

## Voice (macOS, off by default)

OpenAI Realtime voice companion is local and off by default (`[fermix_core.realtime] enabled=true` + OpenAI key). FermixPet connects over `$FERMIX_HOME/realtime.sock`. Channel audio attachments are transcribed before the agent sees them. CLI: `fermix voice status`.

## Config & control surfaces

- `FERMIX_HOME` default `~/.fermix`: `config.toml`, `auth.json`, `memory.db`, `daemon.sock`, `bootstrap/`, `skills/`, `plugins/`, `traces/`, `logs/`, `grants/`, `browser/`.
- Prompt files from setup: `bootstrap/main/{IDENTITY,FERMIX,SOUL,REALTIME}.md`, `memory/main/{USER,MEMORY}.md`; default agent id `main`.
- Personalization (name, timezone, communication style) is set at setup; timezone defaults to `America/New_York` (CLI wizard and web setup). The current date (UTC, with the configured timezone as a label) is stamped into the system prompt every turn and into scheduled job runs, so the agent knows "today" without running `date`. Date-only by design — a clock time would bust provider prompt caches every turn; the precise time still comes from `date`.
- Config sections: `[fermix_core.agent]`, `[fermix_core.providers.<name>]`, `[fermix_core.tools.web_search]`, `[fermix_core.jobs|memory|realtime|plugins|routing]`, `[fermix_core.oauth.google]`, `[sandbox]`, `[mcp.servers.<name>]`, `[fermix_channels.<name>]`.
- Secrets: plaintext config, `@keyring`, or env vars. Saving config auto-stores plaintext secrets to the OS keyring as `@keyring` when a writer is available (macOS `security`; account `fermix`, service `fermix:<ENV>`); without a writer, unchanged plaintext is kept (with a warning) and only new secrets fail. `fermix setup --migrate-secrets` migrates in place. OAuth logins: `fermix auth login` (Codex), `fermix auth login --provider anthropic` (Claude subscription), `fermix auth login --provider xai` (Grok Build); `fermix auth status|logout` accept `--provider`.
- Service: launchd/systemd, user default or `--system`; control with `fermix start|stop|restart`. Inspect with `fermix status|health|doctor|logs -f|capabilities`; restart for config changes.

## Observability

Traces are JSONL under `~/.fermix/traces/YYYY-MM-DD/<type>.jsonl`: `llm_call`, `tool_exec`, `agent_event`, `channel_msg`, `error`, `sandbox_event`; logs are `~/.fermix/logs/fermix.log`. No `fermix traces` verb.

`llm_call` and `tool_exec` carry `session_id`: main turns (`main-<n>`), subagents (random hex linked by parent session events), or scheduled jobs (`cron_<job>_<ts>`). Content capture is off by default; `FERMIX_OPIK_ENABLED=1` enables it unless `FERMIX_TRACE_CONTENT=0`; `FERMIX_TRACE_CONTENT=1` captures locally without Opik. Optional `fermix_opik` plugin exports nested traces and provides `mix opik.replay`.
