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
- Main turns and new scheduled jobs default to 100 iterations. Regular `subagents` fan out a few workers (hard-max 4 tasks, ≤4 concurrent — default 2; 100 iterations each); `/ultra` fans out far wider — up to ~50 narrow probes at a reduced per-probe iteration cap (breadth ≫ regular, depth < regular). Repeated identical tool calls trip the loop detector. These breadth/depth knobs are system-side config (`:subagents`, `:ultra`, `:iteration_limits`), not a `config.toml` surface.

## Providers

`[fermix_core.agent] provider` is snapshotted at boot; restart to apply config changes. Values: `openai`, `openai_codex`, `anthropic`. Only OpenAI and Codex run turns; Anthropic is a scaffold returning `{:error, :not_implemented}`. Per-provider model/effort: `[fermix_core.providers.<name>]` (`default_model`, `reasoning_effort`, Codex-only `fast`).

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

Built-ins need no API keys except alternate backends/integrations; default `web_search` is DuckDuckGo.

## Skills

Skills are `SKILL.md` instruction packages, not provider-visible tools. `skill_view` loads a body; `skill_run` delegates as a sub-agent (recursion cap 4); `skill_list` enumerates. Bundled `priv/skills` and local `~/.fermix/skills` load at operator trust; plugin skills load at guest trust. `allowed_tools` narrows the trust default (`[]` = none, absent = trust default). `skill_create` writes to `~/.fermix/skills`; CLI: `fermix skills list|view NAME|reload`.

## Memory

Durable memory is SQLite at `~/.fermix/memory.db`; ETS is cache. `memory_recall` does key lookup or FTS5 search over memories/history with `scope` (`current|owner|all`) and `source` (`memories|history|all`). Background review curates facts; CLI: `fermix memory review --now`, `fermix memory restore ID`.

## Jobs

`schedule_job` creates durable work without running it now. Schedule forms: interval (`every N minutes|hours|days`), one ISO8601 datetime (`once`), or 5-field cron; free-form English is rejected. Runs are isolated bounded agent loops and cannot see the creating chat, so include needed facts in task text. `expires_at` makes a temporary job; `delivery_mode` is `none|origin|channel|local`.

## Channels & access control

Channels: Telegram, WhatsApp, Slack, Discord, Signal (text + media), plus local `cli` and `daemon`. Remote channels refuse to start without `owner_user_id` or `allowed_*_ids`.

Gateway trust: **operator** (`owner_user_id` or any local caller) gets full surface; **guest** gets read-only chat: no skills, MCP, exec, or network. `allowed_*_ids` authorizes chat only, not operator promotion.

Slash commands are pre-agent: `/help`, `/whoami` for any authorized sender. Operator-only: `/compact`, `/new` (`/clear`), `/sandbox` (`/grant`, `/revoke`, `/confirm`), `/stop`, `/background` (`/bg`), `/tasks`, `/ultra`. Guests can be opted into owner-only commands via `command_allowlist`. Auto-compaction runs after reply at threshold (default 0.85); `/compact` forces it.

## Sandbox

Filesystem/exec built-ins (`shell`, `file_*`, search, `git_*`, `send_attachment`) go through the sandbox. Modes: `strict` (workspace), `standard` (default: workspace + launch cwd + common project dirs), `open` (home). Protected paths (`~/.ssh`, `~/.aws`, Fermix internals, OS roots) and catastrophic commands are denied in every mode. Child env is minimal; secrets come from host env, keyring, or `source = "command"` helpers. Roots: `fermix grant|revoke path PATH`, `fermix sandbox ...`, or `/sandbox`. Command profiles expose extra local commands as tools.

## Plugins

Bundled OAuth plugins: Gmail, Google Calendar, Google Drive. Tools register only when granted scopes cover their required scopes. Manage with `fermix plugins enable|disable NAME` and `fermix plugins auth login|reauthorize|refresh|logout NAME`; tokens/scopes live in `~/.fermix/auth.json`. Plugin skills load at guest trust.

## Voice (macOS, off by default)

OpenAI Realtime voice companion is local and off by default (`[fermix_core.realtime] enabled=true` + OpenAI key). FermixPet connects over `$FERMIX_HOME/realtime.sock`. Channel audio attachments are transcribed before the agent sees them. CLI: `fermix voice status`.

## Config & control surfaces

- `FERMIX_HOME` default `~/.fermix`: `config.toml`, `auth.json`, `memory.db`, `daemon.sock`, `bootstrap/`, `skills/`, `plugins/`, `traces/`, `logs/`, `grants/`, `browser/`.
- Prompt files from setup: `bootstrap/main/{IDENTITY,FERMIX,SOUL,REALTIME}.md`, `memory/main/{USER,MEMORY}.md`; default agent id `main`.
- Config sections: `[fermix_core.agent]`, `[fermix_core.providers.<name>]`, `[fermix_core.tools.web_search]`, `[fermix_core.jobs|memory|realtime|plugins|routing]`, `[fermix_core.oauth.google]`, `[sandbox]`, `[mcp.servers.<name>]`, `[channels.<name>]`.
- Secrets: plaintext config, `@keyring`, or env vars. Saving config auto-stores plaintext secrets to the OS keyring as `@keyring` when a writer is available (macOS `security`; account `fermix`, service `fermix:<ENV>`); without a writer, unchanged plaintext is kept (with a warning) and only new secrets fail. `fermix setup --migrate-secrets` migrates in place. Codex login: `fermix auth login`.
- Service: launchd/systemd, user default or `--system`; control with `fermix start|stop|restart`. Inspect with `fermix status|health|doctor|logs -f|capabilities`; restart for config changes.

## Observability

Traces are JSONL under `~/.fermix/traces/YYYY-MM-DD/<type>.jsonl`: `llm_call`, `tool_exec`, `agent_event`, `channel_msg`, `error`, `sandbox_event`; logs are `~/.fermix/logs/fermix.log`. No `fermix traces` verb.

`llm_call` and `tool_exec` carry `session_id`: main turns (`main-<n>`), subagents (random hex linked by parent session events), or scheduled jobs (`cron_<job>_<ts>`). Content capture is off by default; `FERMIX_OPIK_ENABLED=1` enables it unless `FERMIX_TRACE_CONTENT=0`; `FERMIX_TRACE_CONTENT=1` captures locally without Opik. Optional `fermix_opik` plugin exports nested traces and provides `mix opik.replay`.
