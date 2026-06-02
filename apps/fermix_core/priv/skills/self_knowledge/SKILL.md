---
name: self_knowledge
description: Use when the user asks what Fermix is, what it can do, or how its agent loop, providers, channels, jobs, memory, sandbox, built-ins, skills, plugins, and config/setup surfaces fit together.
allowed_tools: []
---

# Fermix self-knowledge

Fermix is an Elixir-native agent platform that runs as ONE OS daemon (one BEAM VM, OTP-supervised). It is started by `fermix run` or the installed OS service; the `fermix` CLI talks to the running daemon over `$FERMIX_HOME/daemon.sock`. It receives messages from channels, runs a turn against the configured provider, executes capabilities, and replies through the originating channel.

## Runtime shape

- A persistent **Main Agent** GenServer owns the cached runtime context (system prompt + per-trust capability profiles); it does not receive channel messages directly.
- The channels **gateway** serializes one turn per conversation (FIFO): newer same-conversation messages wait, different conversations run concurrently.
- A turn reads history, builds the prompt from cached context, runs the **agent loop** (model response → execute any tool calls via the one capability registry → feed results back → repeat), then replies and commits (persist messages, background memory review, post-reply auto-compaction).
- The main interactive loop is bounded at 100 iterations. Temporary `subagents` and newly-created scheduled jobs also default to 100 iterations. A loop-detector aborts the turn on repeated identical tool calls; hitting the cap returns an error.

## Providers

The active provider is `config.toml [fermix_core.agent] provider`, snapshotted at boot (restart to apply config changes). Values: `openai` | `openai_codex` | `anthropic` — but only **OpenAI** (Responses/ChatCompletions, incl. OpenAI-compatible proxies) and **Codex** (`openai_codex`, ChatGPT OAuth) run turns; the Anthropic adapter is a non-functional scaffold (`{:error, :not_implemented}`). Per-provider model/effort live under `[fermix_core.providers.<name>]` (`default_model`, `reasoning_effort`, Codex-only `fast` toggle).

## Built-in capabilities

Built-ins ship in the binary and seed at boot into the single capability registry; skills and outbound MCP tools (`mcp_<server>_<tool>`) register into the same registry. The authoritative list is the registry-generated `## Built-in Capability Catalog` in the runtime prompt; call `tool_help {"name": "<cap>"}` for one tool's params/examples/failure modes. By category:

- **Files & search**: `file_read`, `file_write`, `file_edit`, `glob_search`, `content_search`
- **Shell & git**: `shell`, `git_read`, `git_write` (no push)
- **Web**: `web_fetch`, `web_search`, `browser` (JS-capable local Chrome — see the `browser_guidance` skill)
- **Memory**: `memory_store`, `memory_recall`, `memory_sources_list`
- **Jobs**: `schedule_job`, `update_job`, `list_jobs`, `pause_job`, `resume_job`, `remove_job`
- **Skills & delegation**: `skill_view`, `skill_run`, `skill_list`, `skill_create`, `subagents` (bounded temp sub-agents)
- **Meta**: `tool_help`, `send_attachment` (local sandbox file; URLs rejected), `model_routing_config` (writes `[fermix_core.routing]`; not yet consumed at runtime)

Built-ins need no API keys (the default `web_search` backend is duckduckgo; alternate backends take a key).

## Skills

Skills are `SKILL.md` instruction packages, not provider-visible tools. The runtime prompt shows a compact Skill Catalog; `skill_view` loads a body, `skill_run` delegates it as a sub-agent (recursion cap 4), `skill_list` enumerates installed skills. Roots: bundled `priv/skills` and local `~/.fermix/skills` load at **operator** trust; enabled plugin skills load at **guest** trust (see Channels). Frontmatter `allowed_tools` only narrows the trust default (`[]` = none, absent = trust default). `skill_create` writes to `~/.fermix/skills`; inspect with `fermix skills list|view NAME|reload`.

## Memory

Durable memory is SQLite at `~/.fermix/memory.db` (ETS is a hot cache). `memory_recall` does key lookup or FTS5 lexical search over durable memories and message history, scoped by `scope` (current|owner|all) and `source` (memories|history|all). A background reviewer curates durable facts after turns; operators run `fermix memory review --now` / `fermix memory restore ID`.

## Jobs

`schedule_job` creates a durable job without running it now. Schedule accepts exactly three forms: interval (`every N minutes|hours|days`), one ISO8601 datetime (`once`), or a 5-field cron string — free-form English is rejected. Runs are isolated bounded agent loops that cannot see the creating chat, so bake needed values into the task text. `expires_at` makes a temporary job; `delivery_mode` (none|origin|channel|local) controls whether a result is sent back.

## Channels & access control

Shipped remote channels: Telegram, WhatsApp, Slack, Discord, Signal (all send text + media), plus local loopback `cli` and `daemon`. An enabled remote channel refuses to start without ingress authorization (`owner_user_id` or an `allowed_*_ids` list).

Two trust tiers, set per sender by the gateway: **operator** (the channel `owner_user_id`, or any local caller) gets the full surface; **guest** (any other authorized sender) gets read-only chat — no skills, MCP, exec, or network. Adding someone to `allowed_*_ids` does not promote them to operator.

Slash commands are parsed before the agent: `/help`, `/whoami` (any authorized sender); `/compact`, `/new` (alias `/clear`), `/sandbox` (aliases `/grant` `/revoke` `/confirm`) are operator-only (a guest can be opted in via `command_allowlist`). Auto-compaction is threshold-driven (default 0.85 of the context window) after the reply; `/compact` forces it.

## Sandbox

Every filesystem/exec built-in (`shell`, `file_*`, search, `git_*`, `send_attachment`) is gated by the sandbox. Mode sets the allowed roots: `strict` (workspace only), `standard` (default — workspace + launch cwd + common project dirs), `open` (whole home); run `fermix sandbox status` for the resolved roots. Protected paths (`~/.ssh`, `~/.aws`, `~/.fermix` internals, OS roots) and a hardline catastrophic-command blocklist (`rm -rf` of a protected root, `mkfs`, fork bomb, …) are denied in every mode. Child processes get a minimal explicit env — Fermix owns no keystore; secrets come from the host env or operator helpers via `source = "command"`. Widen/narrow roots with `fermix grant path PATH` / `fermix revoke path PATH` (same as `fermix sandbox grant/revoke`, or `/sandbox` in-channel). Command profiles (`bare`/`assistant`/`extended`, presets) expose extra local commands as tools.

## Plugins

Bundled first-party OAuth integrations (Gmail, Google Calendar, Google Drive) that register scope-gated tools: a plugin tool registers only if its required scopes are a subset of those granted at sign-in (a read-only grant hides write tools). Manage with `fermix plugins enable|disable NAME` and `fermix plugins auth login|reauthorize|refresh|logout NAME`; tokens + granted scopes live in `~/.fermix/auth.json`. Plugin skills load at guest trust (see Channels).

## Voice (macOS, off by default)

Fermix can run a local OpenAI Realtime voice companion (`[fermix_core.realtime] enabled=true` + OpenAI key); the native macOS FermixPet app connects over `$FERMIX_HOME/realtime.sock`. Inbound channel audio attachments are transcribed to text before the agent sees them. Status: `fermix voice status`.

## Config & control surfaces

- **Root**: `FERMIX_HOME` (default `~/.fermix`) holds `config.toml` (the file users edit), `auth.json`, `memory.db`, `daemon.sock`, and dirs `bootstrap/`, `skills/`, `plugins/`, `traces/`, `logs/`, `grants/`, `browser/`.
- **Prompt files** (written by `fermix setup`, editable on disk, never rewritten at runtime): identity/rules at `~/.fermix/bootstrap/main/{IDENTITY,FERMIX,SOUL,REALTIME}.md`; user profile + working memory at `~/.fermix/memory/main/{USER,MEMORY}.md`. Default agent id is `main`.
- **config.toml sections**: `[fermix_core.agent]` (provider), `[fermix_core.providers.<name>]`, `[fermix_core.tools.web_search]`, `[fermix_core.jobs|memory|realtime|plugins|routing]`, `[fermix_core.oauth.google]`, `[sandbox]`, `[mcp.servers.<name>]` (outbound MCP), `[channels.<name>]`.
- **Secrets**: provider/channel keys can be plaintext in `config.toml`, the `@keyring` sentinel (OS keychain), or env vars (`OPENAI_API_KEY`, `TELEGRAM_BOT_TOKEN`, …); `fermix setup --migrate-secrets` moves plaintext into the keychain. Codex login is separate: `fermix auth login` writes `auth.json`.
- **Service**: launchd (macOS) / systemd (Linux) unit, user (default) or `--system` scope; control with `fermix start|stop|restart`.
- **Inspect/fix the running daemon**: `fermix status`, `fermix health`, `fermix doctor`, `fermix logs -f`, `fermix capabilities`. Full verb list: `fermix --help`. Apply config changes by restarting.

## Observability

Traces are JSONL under `~/.fermix/traces/YYYY-MM-DD/<type>.jsonl` (`llm_call`, `tool_exec`, `agent_event`, `channel_msg`, `error`, `sandbox_event`); logs at `~/.fermix/logs/fermix.log`. There is no `fermix traces` verb — read the files.
