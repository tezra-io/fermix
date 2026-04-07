# Telegram Polling Mode

## Summary

Telegram long-polling support is already implemented alongside webhook mode. This document now records the implemented baseline so future work starts from the current repo state instead of re-implementing existing pieces.

## Implemented Baseline

- `FermixChannels.Telegram.Poller` already exists and long-polls Telegram's `getUpdates` API.
- `FermixChannels.Telegram.parse_update/1` already exists as the shared update parser used by both webhook handling and the poller.
- `FermixChannels.Application` already conditionally starts the poller when `telegram.mode == :polling` and the channel is enabled.
- The `telegram.mode` config toggle is already present in compile-time config, test config, and `TELEGRAM_MODE` runtime parsing.
- Targeted tests for `Telegram.parse_update/1` and `FermixChannels.Telegram.Poller` already exist.

## Architecture

### Implemented Module: `FermixChannels.Telegram.Poller`

A GenServer that long-polls Telegram's `getUpdates` API endpoint.

**State:**
- `offset` — integer, tracks last processed `update_id + 1`. Starts at 0.
- `bot_token` — string, from config.

### Startup Backlog Policy

- When the poller starts, its first cycle is a startup probe: `getUpdates` with `timeout=0`.
- Any updates returned by that startup probe are treated as stale backlog and are not processed.
- The poller only advances `offset` to `max(update_id) + 1` for that backlog.
- Regular long-polling begins only after the startup probe completes.
- This is the webhook-to-polling transition policy as well: if Telegram has queued stale updates
  while webhook mode was active or while the bot was switching modes, polling drops that queued
  backlog and only processes updates that arrive after the startup probe.

**Lifecycle:**
1. `init/1` — reads config, initializes `offset` to `0`, and marks startup backlog draining as pending.
2. First `handle_info(:poll, state)` cycle — runs the startup probe (`getUpdates` with `timeout=0`), drops any returned backlog, and sets the initial offset.
3. Main loop via later `handle_info(:poll, state)` cycles — calls `getUpdates` with `timeout=30` (Telegram long-poll window), processes results, schedules next `:poll`.

### Polling Flow

```
Poller GenServer
  |-- First cycle: GET getUpdates?offset=N&timeout=0&allowed_updates=["message"]
  |-- On success:
  |     |-- Do not process returned updates
  |     |-- Advance offset to max(update_id) + 1
  |     |-- Enter regular polling loop
  |-- Regular loop: GET getUpdates?offset=N&timeout=30&allowed_updates=["message"]
  |-- On success:
  |     |-- For each update:
  |     |     |-- Telegram.parse_update/1
  |     |     |-- authorized_user?/1 filtering via Telegram.parse_update/1 internals
  |     |     |-- build_agent_messages/1
  |     |     |-- MainAgent.handle_message/1
  |     |-- Advance offset to max(update_id) + 1
  |     |-- send(self(), :poll)
  |-- On error:
  |     |-- Log error
  |     |-- Process.send_after(self(), :poll, 5_000)
```

### Error Handling

- Network errors: 5-second backoff, retry.
- Non-200 responses: log, 5-second backoff, retry.
- GenServer crashes: supervisor restarts it (`:permanent` strategy).

### Config Toggle

```elixir
# config.exs
config :fermix_channels,
  telegram: [
    mode: :webhook,        # :webhook (default) or :polling
    enabled: true,
    ...
  ]

# runtime.exs — TELEGRAM_MODE env var
```

### Supervision

`FermixChannels.Application` conditionally starts the poller:

```elixir
children =
  if telegram_config[:mode] == :polling and telegram_config[:enabled] != false do
    [{FermixChannels.Telegram.Poller, []}]
  else
    []
  end
```

### Existing Code Reuse

These functions in `FermixChannels.Telegram` are part of the implemented baseline:
- `parse_update/1` — public shared parser used by webhook handling and the poller
- `parse_webhook/1` — delegates to `parse_update/1` and emits inbound telemetry
- `build_agent_messages/1` — wraps parsed messages with reply_fn
- `send_message/3` — sends outbound messages via Bot API
- `parse_message/1` and `authorized_user?/1` remain internal helpers behind `parse_update/1`

### Files

| Status | File | Notes |
|--------|------|-------|
| Implemented | `apps/fermix_channels/lib/fermix_channels/telegram/poller.ex` | Poller with startup backlog drain and regular long-poll loop |
| Implemented | `apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs` | Poller coverage for startup probe, backlog drop, offset handling, and retry behavior |
| Implemented | `apps/fermix_channels/lib/fermix_channels/telegram.ex` | Shared `parse_update/1`, webhook delegation, and agent message building |
| Implemented | `apps/fermix_channels/test/fermix_channels/telegram_test.exs` | Parser coverage for webhook and shared update parsing |
| Implemented | `apps/fermix_channels/lib/fermix_channels/application.ex` | Conditional poller startup in polling mode |
| Implemented | `config/config.exs` | Default `mode: :webhook` |
| Implemented | `config/test.exs` | Test default `mode: :webhook` |
| Implemented | `config/runtime.exs` | `TELEGRAM_MODE` runtime parsing |

### Testing

- Poller GenServer starts and stops cleanly
- Processes updates through `Telegram.parse_update/1`, `build_agent_messages/1`, and `MainAgent`
- Advances offset correctly
- Retries on error with backoff
- Ignores updates from unauthorized users (via `Telegram.parse_update/1` filtering)
- Does not start when mode is `:webhook`

## Remaining Work

- No baseline implementation work remains in this design doc.
- Any future polling changes should be additive and should build on the existing poller, shared parser, and config wiring rather than re-implementing them.
