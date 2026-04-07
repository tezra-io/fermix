# Telegram Polling Implementation Plan

> Status refresh 2026-04-07: the baseline polling implementation already exists in the repo. This plan now records what is already done and the limited remaining work, so no one repeats completed implementation steps.

**Goal:** Keep the Telegram polling docs aligned with the current codebase and avoid duplicate implementation work.

**Current architecture:** `FermixChannels.Telegram.Poller` long-polls Telegram's `getUpdates` API, reuses `FermixChannels.Telegram.parse_update/1` for inbound parsing, and is conditionally started when `telegram.mode == :polling`.

## Implemented Baseline

- `FermixChannels.Telegram.Poller` is already implemented in `apps/fermix_channels/lib/fermix_channels/telegram/poller.ex`.
- The poller already performs a zero-timeout startup probe, drops queued backlog, then enters the regular `timeout=30` long-poll loop.
- `FermixChannels.Telegram.parse_update/1` is already implemented in `apps/fermix_channels/lib/fermix_channels/telegram.ex` and is shared by webhook handling and the poller.
- `FermixChannels.Application` already conditionally starts the poller in `apps/fermix_channels/lib/fermix_channels/application.ex`.
- The Telegram mode toggle is already wired in `config/config.exs`, `config/test.exs`, and `config/runtime.exs`.
- Regression coverage already exists in `apps/fermix_channels/test/fermix_channels/telegram_test.exs` and `apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs`.

## Current File Status

| Status | File | Responsibility |
|--------|------|----------------|
| Implemented | `apps/fermix_channels/lib/fermix_channels/telegram/poller.ex` | GenServer that long-polls `getUpdates` |
| Implemented | `apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs` | Poller unit coverage |
| Implemented | `apps/fermix_channels/lib/fermix_channels/telegram.ex` | Shared `parse_update/1`, webhook delegation, and outbound helpers |
| Implemented | `apps/fermix_channels/test/fermix_channels/telegram_test.exs` | Shared parser coverage |
| Implemented | `apps/fermix_channels/lib/fermix_channels/application.ex` | Conditional poller startup |
| Implemented | `config/config.exs` | Default `mode: :webhook` |
| Implemented | `config/test.exs` | Test default `mode: :webhook` |
| Implemented | `config/runtime.exs` | `TELEGRAM_MODE` parsing |

## Duplicate Implementation Steps Removed

- Do not re-create `FermixChannels.Telegram.Poller`.
- Do not re-extract or re-implement `Telegram.parse_update/1`.
- Do not re-add the `telegram.mode` config toggle or poller supervision wiring.
- Do not treat the old failing-test steps for missing poller/parser code as current work; that baseline is already complete.

## Remaining Work

### Task 1: Preserve regression coverage when polling code changes

- Re-run targeted polling tests when changing Telegram polling behavior:
  - `mix test apps/fermix_channels/test/fermix_channels/telegram_test.exs`
  - `mix test apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs`
- Re-run broader verification as needed for code changes:
  - `mix test`
  - `mix quality`

### Task 2: Manual smoke test when validating against a real Telegram bot

```bash
TELEGRAM_MODE=polling TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN OPENAI_API_KEY=$OPENAI_API_KEY TELEGRAM_ALLOWED_USER_IDS=$TELEGRAM_ALLOWED_USER_IDS mix phx.server
```

Expected result:
- Server starts with polling mode enabled.
- Poller performs the startup probe and drops stale backlog.
- New Telegram messages are processed through the Telegram channel flow.

## Scope Guard

- This plan is no longer a build-from-scratch checklist for polling mode.
- Any future work should be additive, such as operational validation or new requirements, and must build on the implemented baseline already in the repo.
