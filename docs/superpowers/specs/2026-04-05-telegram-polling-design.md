# Telegram Polling Mode

## Summary

Add long-polling support to Telegram channel alongside existing webhook mode. A config toggle (`mode: :polling` or `:webhook`) determines which is active. Polling removes the need for a public HTTPS URL, making local development straightforward.

## Architecture

### New Module: `FermixChannels.Telegram.Poller`

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
  |     |     |-- parse_message/1 (reuses existing Telegram function)
  |     |     |-- authorized_user?/1 check (already in parse_message)
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

These functions in `FermixChannels.Telegram` are already extracted and reusable:
- `parse_message/1` — extracts message fields from Telegram update
- `authorized_user?/1` — checks user ID allow-list
- `build_agent_messages/1` — wraps parsed messages with reply_fn
- `send_message/3` — sends outbound messages via Bot API

The poller calls `parse_message/1` directly (it's currently private, will need to be made accessible or extracted).

### Files

| Action | File |
|--------|------|
| Create | `apps/fermix_channels/lib/fermix_channels/telegram/poller.ex` |
| Create | `apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs` |
| Modify | `apps/fermix_channels/lib/fermix_channels/telegram.ex` — expose `parse_message/1` for poller |
| Modify | `apps/fermix_channels/lib/fermix_channels/application.ex` — conditional poller startup |
| Modify | `config/config.exs` — add `mode: :webhook` default |
| Modify | `config/test.exs` — add `mode: :webhook` |
| Modify | `config/runtime.exs` — parse `TELEGRAM_MODE` env var |

### Testing

- Poller GenServer starts and stops cleanly
- Processes updates through parse_message and MainAgent
- Advances offset correctly
- Retries on error with backoff
- Ignores updates from unauthorized users (via existing filter)
- Does not start when mode is `:webhook`
