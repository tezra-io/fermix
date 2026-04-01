# Fermix

Elixir-native multi-agent AI platform. Phoenix gateway, OTP-supervised agents, Rustler NIFs for crypto/tokenization.

## Architecture

```
fermix/ (umbrella)
├── apps/fermix_core/       # Agents, providers, tools, memory, tracing
├── apps/fermix_channels/   # Telegram, WhatsApp, Discord, Signal
├── apps/fermix_web/        # Phoenix: webhooks, REST, WebSocket
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

## Configuration

Environment variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENAI_API_KEY` | Yes (prod) | OpenAI API key |
| `TELEGRAM_BOT_TOKEN` | Yes (prod) | Telegram Bot API token |
| `TELEGRAM_WEBHOOK_SECRET` | No | Webhook verification secret |

In dev/test, these default to empty strings.

## Running

```bash
mix phx.server       # Start Phoenix (port 4000)
```

### Endpoints

- `GET /health` — Health check
- `POST /webhook/telegram` — Telegram webhook receiver

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
- **Telegram** — Webhook parsing, Bot API messaging, typing indicators

### Observability
- Structured JSONL traces: `~/.fermix/traces/YYYY-MM-DD/<type>.jsonl`
- Log file with rotation: `~/.fermix/logs/fermix.log`
- Telemetry events for all operations

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

## License

Private — Tezra.io
