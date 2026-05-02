# Fermix

Elixir-native multi-agent AI platform that runs as a local daemon and reaches you through the chat channels you already use.

![License](https://img.shields.io/badge/license-proprietary-red)
![Elixir](https://img.shields.io/badge/elixir-%E2%89%A5%201.17-purple)
![Erlang/OTP](https://img.shields.io/badge/otp-%E2%89%A5%2028-red)
![Status](https://img.shields.io/badge/status-alpha%20(pre--1.0)-yellow)

## What is Fermix

Fermix is a persistent multi-agent runtime that survives reboots and talks to you through Telegram, WhatsApp, Slack, Discord, Signal, and a local CLI — all terminating in the same agent loop. Everything is one BEAM VM under OTP supervision: there are no HTTP bridges between components, no separate worker pool, no broker. Today the runtime drives OpenAI (chat completions, function calling, optional native OAuth); additional providers are on the roadmap. Fermix ships as a single self-extracting binary per platform, installs an OS service unit on first run, and writes its config, traces, and logs under `~/.fermix`.

## Quick start

```bash
brew install tezra-io/homebrew-tap/fermix
fermix setup
fermix start
```

Confirm the daemon is up:

```bash
$ fermix status
fermix: running (pid 12345, version 0.1.0, up 4s)
```

## Install

### Homebrew (macOS, Linux)

```bash
brew install tezra-io/homebrew-tap/fermix
```

### curl | sh

```bash
curl -fsSL https://fermix.sh/install | sh
```

The installer detects your `(os, arch)`, downloads the matching signed release artifact, and drops `fermix` on `PATH`. Supported targets: `macos_aarch64`, `macos_x86_64`, `linux_aarch64`, `linux_x86_64`.

### Build from source

For contributors and anyone who wants to run against unreleased code. See [Develop](#develop).

## Configure

`fermix setup` is the single entry point for first-run configuration. It is interactive by default and accepts non-interactive flags (`--openai-api-key`, `--telegram-bot-token`, …) for scripted installs. It writes a typed snapshot to:

- `FERMIX_HOME/config.toml` (default `FERMIX_HOME` is `~/.fermix`)

It also creates the workspace roots the runtime expects:

- `~/.fermix/skills`
- `~/.fermix/journals`
- `~/.fermix/traces`
- `~/.fermix/logs`
- `~/.fermix/auth.json` (when `openai_codex` is selected; `0600`)

Regular OpenAI uses `OPENAI_API_KEY`. Codex uses the separate `openai_codex` provider and imports OAuth tokens from the Codex CLI into the provider-scoped token store at `~/.fermix/auth.json`, refreshed by the supervised `TokenManager`.

Runtime precedence is:

1. compile-time defaults in `config/config.exs`
2. persisted setup state from `config.toml`
3. environment variable overrides applied in `config/runtime.exs`

### Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENAI_API_KEY` | Yes when provider is `openai` | OpenAI API key |
| `TELEGRAM_BOT_TOKEN` | If Telegram is enabled | Telegram Bot API token |
| `WHATSAPP_ACCESS_TOKEN` | If WhatsApp is enabled | WhatsApp Cloud API access token |
| `WHATSAPP_PHONE_NUMBER_ID` | If WhatsApp is enabled | WhatsApp phone number ID |
| `WHATSAPP_VERIFY_TOKEN` | If WhatsApp is enabled | WhatsApp webhook verification token |
| `WHATSAPP_APP_SECRET` | If WhatsApp is enabled | WhatsApp webhook HMAC secret |
| `DISCORD_BOT_TOKEN` | If Discord is enabled | Discord bot token |
| `DISCORD_BOT_USER_ID` | If Discord is enabled | Discord bot user ID |
| `SLACK_BOT_TOKEN` | If Slack is enabled | Slack bot token |
| `SLACK_SIGNING_SECRET` | If Slack is enabled | Slack request signing secret |
| `SIGNAL_ACCOUNT` | If Signal is enabled | Signal phone/account identifier |
| `SIGNAL_CLI_PATH` | No | Override the `signal-cli` executable path |
| `FERMIX_HOME` | No | Override the persisted config and workspace root |
| `FERMIX_TRACE_DIR` | No | Override the trace output directory |
| `FERMIX_LOG_FILE` | No | Override the log file path |

In dev/test these default to empty strings.

## Use

### Daemon control

`fermix service install` writes the OS service unit (launchd `.plist` on macOS, systemd `.service` on Linux) and enables it. Subsequent control is uniform across platforms:

```bash
fermix service install [--user|--system]   # write and enable the unit
fermix start                               # start the installed service
fermix status                              # ask the daemon over its control socket
fermix logs -f                             # tail ~/.fermix/logs/fermix.log
fermix stop
fermix restart
fermix service uninstall
```

The unit calls `fermix run`, which boots the OTP supervision tree, binds the Phoenix endpoint, and blocks. Logs rotate at `~/.fermix/logs/fermix.log` (10 MB × 10 files by default).

`--user` scope is per-user and requires no sudo; on Linux it enables `loginctl enable-linger` so the service survives logout. `--system` scope binds at boot and requires sudo.

### Channels

All channels normalize inbound messages and dispatch them through the same `FermixCore.Agents.MainAgent`.

- **Telegram** — long-poll ingress, Bot API replies.
- **WhatsApp** — Cloud API webhook ingress, text replies. Voice notes are transcribed before reaching the agent.
- **Slack** — Events API DM and `app_mention` ingress, Web API replies.
- **Discord** — Gateway DM and app-mention ingress, REST replies.
- **Signal** — `signal-cli` receive loop, subprocess send path.
- **CLI** — local stdin/stdout smoke path through the same dispatcher and `MainAgent`.

### HTTP endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health/live` | Process liveness only |
| `GET` | `/health/ready` | Structured readiness and runtime health |
| `GET` | `/health` | Backward-compatible alias of `/health/ready` |
| `GET` | `/setup` | Shared setup/readiness LiveView |
| `GET` | `/webhook/whatsapp` | WhatsApp verification challenge |
| `POST` | `/webhook/whatsapp` | WhatsApp webhook ingress |
| `POST` | `/webhook/slack` | Slack Events API ingress |

Telegram, Discord, and Signal use long-poll or persistent client transports and do not mount HTTP routes.

## CLI reference

| Command | Description |
|---------|-------------|
| `fermix setup` | Run the interactive (or flag-driven) configuration wizard |
| `fermix run` | Start the daemon in the foreground (used by service units) |
| `fermix service install [--user\|--system]` | Write and enable the OS service unit |
| `fermix service uninstall [--user\|--system]` | Remove the OS service unit |
| `fermix start [--user\|--system]` | Start the installed OS service |
| `fermix stop [--user\|--system]` | Stop the installed OS service |
| `fermix restart [--user\|--system]` | Restart the installed OS service |
| `fermix status` | Print running daemon status via the control socket (exit `3` if not running) |
| `fermix logs [-f] [-n LINES]` | Show or follow the daemon log file |
| `fermix upgrade [--check]` | Self-update from signed releases (cosign-verified, atomic swap) |
| `fermix doctor [--full]` | Post-install diagnostics; `--full` adds network checks |
| `fermix version` | Print the release version |
| `fermix help` | Show usage |

`fermix upgrade` detects package-manager installs (Homebrew, dpkg) and refuses to mutate them — it prints the right `brew upgrade` / `apt upgrade` command and exits non-zero. Unmanaged installs follow `fetch → cosign verify → snapshot → rename → restart → health-check`, with rollback from `~/.fermix/.previous` if the post-swap health check fails.

## Architecture

![Fermix architecture](docs/architecture.png)

```
fermix/ (umbrella)
├── apps/fermix_core/       # Agents, providers, tools, memory, setup, CLI, auth, tracing
├── apps/fermix_channels/   # Telegram, WhatsApp, Slack, Discord, Signal, CLI
├── apps/fermix_web/        # Phoenix: setup LiveView, health, webhook ingress
└── apps/fermix_nif/        # Stub for future Rustler NIFs (no NIFs implemented yet)
```

One BEAM VM, all `:permanent` under OTP. The data flow is straight-line:

```
channel adapter → FermixChannels.Dispatcher → FermixCore.Agents.MainAgent
  → tool / skill execution → provider (OpenAI) → LLM → reply
```

The agent loop calls the provider, parses tool calls, executes them through the registered `FermixCore.Tools.Registry`, and recurses up to a hard cap of 25 iterations. The current tool set is:

| Tool | Description |
|------|-------------|
| `shell` | Execute system commands with timeout |
| `file_read` | Read files with offset/limit |
| `file_write` | Write files with auto mkdir |
| `memory_store` | Store key-value facts |
| `memory_recall` | Recall stored facts |
| `browser` | Drive a browser via the `agent-browser` CLI (snapshot, navigate, click, fill, screenshot) |
| `invoke_skill` | Delegate a focused task to a supervised skill agent |

Observability:

- Structured JSONL traces under `FERMIX_HOME/traces/YYYY-MM-DD/<type>.jsonl`
- Rotating log file at `FERMIX_HOME/logs/fermix.log`
- Telemetry events for provider calls, tool execution, channel ingress, and agent lifecycle
- `/health/ready` reports config paths, provider status, per-channel status, and memory backend status

## Develop

Requirements: Elixir ≥ 1.17, Erlang/OTP ≥ 28, Git, and `signal-cli` on `PATH` (or `SIGNAL_CLI_PATH` configured) if Signal is enabled.

```bash
git clone git@github.com:tezra-io/fermix.git
cd fermix
mix setup           # deps.get + install git hooks
mix quality         # format check → compile --warnings-as-errors → credo --strict → dialyzer → test
mix test            # tests only
mix test --only integration
```

`mix quality` is the canonical "does everything pass" command. The git pre-commit hook enforces format, compile, credo, and tests.

For dev iteration against the channels and Phoenix endpoint, `mix phx.server` boots the umbrella without going through the CLI dispatcher.

## Resource history CLI

Versioned prompt and memory resources can be inspected from Mix:

```bash
mix fermix.resource.list
mix fermix.resource.history user_md --limit 10
mix fermix.resource.show user_md 3
mix fermix.resource.diff user_md 2 3
mix fermix.resource.rollback user_md 2
```

Use `--scope <conversation-key>` for checkpoint resources. Checkpoint rollback is not supported; checkpoint revisions are audit/history records only. Rolling back `USER.md` or `MEMORY.md` restores the file-backed prompt resource, but future memory rebuilds can overwrite the file if the underlying promoted memories are unchanged.

## Documentation

- [`CHANGELOG.md`](CHANGELOG.md) — release history (Keep a Changelog format, semver)
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — post-MVP feature roadmap

## License

Proprietary — Tezra.io. All rights reserved.
