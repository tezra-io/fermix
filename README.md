# Fermix

Elixir-native multi-agent AI platform. Phoenix gateway, OTP-supervised agents, shared setup/readiness surfaces, and direct-message channel adapters that all terminate in the same agent runtime.

## Architecture

```
fermix/ (umbrella)
├── apps/fermix_core/       # Agents, providers, setup, readiness, tracing
├── apps/fermix_channels/   # Telegram, WhatsApp, Discord, Slack, Signal, CLI
├── apps/fermix_web/        # Phoenix: setup UI, health, webhook ingress
└── apps/fermix_nif/        # Rustler: HMAC-SHA256, tiktoken (future)
```

One BEAM VM. Everything is OTP-supervised. No HTTP bridges between components.

## Requirements

- Elixir >= 1.17
- Erlang/OTP >= 28
- Git

## Setup

```bash
git clone git@github.com:tezra-io/fermix.git
cd fermix
mix setup           # deps.get + git hooks
mix quality         # format + compile + credo + dialyzer + test
```

## Setup and Configuration

Fermix ships a shared setup flow for the CLI and web UI:

```bash
mix fermix.setup
```

That flow persists the runtime snapshot to:

- `FERMIX_HOME/config.toml`
- default `FERMIX_HOME` is `~/.fermix`

It also creates the local workspace roots used by the runtime:

- `~/.fermix/skills`
- `~/.fermix/journals`
- `~/.fermix/traces`
- `~/.fermix/logs`

Runtime precedence is:

1. compile-time defaults in `config/config.exs`
2. persisted setup state from `config.toml`
3. environment variable overrides from `config/runtime.exs`

### Environment variables

Common channel/provider overrides:

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENAI_API_KEY` | Yes unless OAuth is configured | OpenAI API key |
| `TELEGRAM_BOT_TOKEN` | If Telegram is enabled | Telegram Bot API token |
| `TELEGRAM_WEBHOOK_SECRET` | No | Telegram webhook verification secret |
| `WHATSAPP_ACCESS_TOKEN` | If WhatsApp is enabled | WhatsApp Cloud API access token |
| `WHATSAPP_PHONE_NUMBER_ID` | If WhatsApp is enabled | WhatsApp phone number ID |
| `WHATSAPP_VERIFY_TOKEN` | If WhatsApp is enabled | WhatsApp webhook verification token |
| `WHATSAPP_APP_SECRET` | If WhatsApp is enabled | WhatsApp webhook HMAC secret |
| `DISCORD_BOT_TOKEN` | If Discord is enabled | Discord bot token |
| `DISCORD_BOT_USER_ID` | If Discord is enabled | Discord bot user ID |
| `SLACK_BOT_TOKEN` | If Slack is enabled | Slack bot token |
| `SLACK_SIGNING_SECRET` | If Slack is enabled | Slack request signing secret |
| `SIGNAL_ACCOUNT` | If Signal is enabled | Signal phone/account identifier |
| `FERMIX_HOME` | No | Override the persisted config and workspace root |
| `FERMIX_TRACE_DIR` | No | Override the trace output directory |
| `FERMIX_LOG_FILE` | No | Override the log file path |

In dev/test, these default to empty strings.

## Running

```bash
mix phx.server       # Start Phoenix (port 4000)
```

### Endpoints

- `GET /health/live` — process liveness only
- `GET /health/ready` — structured readiness and runtime health
- `GET /health` — backward-compatible alias of `/health/ready`
- `GET /setup` — shared setup/readiness UI
- `POST /webhook/telegram` — Telegram webhook ingress
- `GET /webhook/whatsapp` — WhatsApp verification challenge
- `POST /webhook/whatsapp` — WhatsApp webhook ingress
- `POST /webhook/slack` — Slack Events API ingress

## Core Components

### Agent Loop
Recursive LLM conversation loop: call provider → check for tool calls → execute tools → loop until final response. Max 25 iterations.

### Tools
| Tool | Description |
|------|-------------|
| `shell` | Execute system commands with timeout |
| `file_read` | Read files with offset/limit |
| `file_write` | Write files with auto mkdir |
| `memory_store` | Store key-value facts |
| `memory_recall` | Recall stored facts |

### Providers
- **OpenAI** — Chat completions with function calling via Req

### Channels
- **Telegram** — Webhook or polling ingress, Bot API replies
- **WhatsApp** — Cloud API webhook ingress, text replies, voice-note transcription path
- **Discord** — Gateway DM and app-mention ingress, REST replies
- **Slack** — Events API DM and `app_mention` ingress, Web API replies
- **Signal** — `signal-cli` receive loop, subprocess send path
- **CLI** — Local stdin/stdout smoke path through the same dispatcher and `MainAgent`

### Voice and transcription

M3 keeps transcription outside the channel adapters. The shared runtime flow is:

1. channel normalizes inbound media metadata into `attachments`
2. channel-specific media fetch downloads audio to a temp file when supported
3. `FermixCore.Transcription` converts audio into text
4. the transcribed text becomes the message `content`
5. original attachment metadata is preserved on the message envelope

Current M3 voice coverage is the WhatsApp audio/voice path. Discord voice and richer media understanding are still out of scope.

### Observability
- Structured JSONL traces: `FERMIX_HOME/traces/YYYY-MM-DD/<type>.jsonl`
- Rotating log file: `FERMIX_HOME/logs/fermix.log`
- Telemetry events for all operations
- `/health/ready` reports config paths, provider status, per-channel status, and memory backend status

## Quality Gates

```bash
mix quality    # The canonical "does everything pass" command
```

Runs: format check → compile (warnings=errors) → credo strict → dialyzer → tests

Git pre-commit hook enforces format, compile, credo, and tests.

## Tests

```bash
mix test                    # All tests
mix test --only integration # E2E integration tests only
```

### Smoke checks

Recommended M3 smoke path after setup:

```bash
mix fermix.setup
mix phx.server
curl http://localhost:4000/health/live
curl http://localhost:4000/health/ready
```

Then exercise at least one enabled channel:

- CLI: `iex -S mix` then `FermixChannels.CLI.dispatch_input("hello")`
- Telegram/WhatsApp/Slack: send a direct message to the configured webhook-backed channel
- Discord/Signal: send a direct message and confirm the long-running client is connected in `/health/ready`

## License

Private — Tezra.io
