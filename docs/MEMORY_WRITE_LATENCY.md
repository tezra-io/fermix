# Conversation Write Latency

## Context

TEZ-374 changed `FermixCore.Memory.ConversationStore.add_message/4` from an async cast to a synchronous call. At that point, the caller continued only after the in-memory update and any enabled SQLite write completed.

The main agent writes two chat messages on each successful turn before delivering the reply:

- user message
- assistant message

The original sync durability goal was simple crash semantics: after `add_message/4` returned, the chat message was durable. This document keeps that historical measurement and records the later async durability change separately.

## Measurement

The repeatable benchmark entrypoint is:

```sh
mix fermix.memory_write_latency --iterations 5000 --warmup 200 --message-bytes 512
```

It exercises the public `ConversationStore.add_message/4` API twice: once with no repo configured for the memory-only baseline, and once with an enabled SQLite repo (WAL mode) plus a dedicated Task.Supervisor for the async durable path. Only the synchronous return is timed; the asynchronous SQLite commit is observable via the `[:fermix, :memory, :message_persist]` telemetry event.

### Historical numbers (pre-2026-05-02, synchronous durable path)

Captured against the original sync-durable implementation. The current code path is async — these numbers are kept as a reference for what the old contract cost, not as a current measurement.

```text
memory only: avg=1.2us p50=1us p95=3us p99=4us max=26us
durable sqlite: avg=133.1us p50=122us p95=180us p99=501us max=1070us
durable overhead: avg=131.9us p50=121us p95=179us p99=500us max=1069us
```

At two synchronous chat writes per successful agent turn, the measured durable overhead was roughly:

- average: 264us per turn
- p95: 358us per turn
- p99: 1ms per turn
- max in this run: 2.1ms per turn

## Async Durability Update

On 2026-05-02, durable SQLite persistence moved off the message-delivery path. `ConversationStore.add_message/4` still performs the in-memory hot-window append synchronously, but it now queues the SQLite insert to an async task.

After this change, `add_message/4` returning no longer means the message is durable. The accepted loss window is VM/process shutdown or task termination between the in-memory append and the SQLite insert returning.

Why:

- the active conversation lives in the in-memory `ConversationStore` hot window during a turn
- `memory.db` is durability and historical reference, not the thing that should decide whether a generated reply reaches the user
- a transient local SQLite failure should not drop an already-generated response
- keeping the in-memory append synchronous preserves next-turn context without blocking on disk

The async durable path logs failures, emits telemetry, and retries boundedly before giving up. Pending writes carry a snapshot of the conversation's clear/history version, and the async task re-reads the current version (`{clear_version, history_version}` for `replace_history`, `clear_version` only for plain inserts) before issuing the SQL operation; a mismatch causes the task to skip. This check is **non-atomic** — a `clear/2` or `replace_history/3` that lands after the check but before the SQL commit can still leave a stale row behind. Closing this race needs serialized durable writes per conversation; see §Decision History/2026-05-02.

## Runtime Telemetry

`ConversationStore.add_message/4` emits `[:fermix, :memory, :message]` with:

- `count`
- `duration_us`
- `durable_write_us` (`0` for the async durable path)
- metadata: `channel`, `chat_id`, `durable?`

`duration_us` measures the synchronous store callback work. `durable?` means a durable write was queued.

Async durable writes emit `[:fermix, :memory, :message_persist]` with:

- `count`
- `duration_us`
- metadata: `channel`, `chat_id`, `role`, `kind`, `attempt`, `status`, `reason`

## Decision History

### TEZ-374

The initial synchronous durability guarantee was acceptable for Stage 1A production traffic because measured overhead was sub-millisecond at p95 for the two-write turn path, and provider latency dominated local persistence.

### 2026-05-02

Keep the in-memory append synchronous and durable SQLite writes asynchronous. This gives the main agent immediate local context for the next turn without making user-visible message delivery depend on SQLite health.

Three signals would trigger the move to a bounded write-behind process. Only one is currently observable:

- **Retry storms** — observable today via `status=:error` counts on `[:fermix, :memory, :message_persist]` (`attempt` field surfaces escalation depth).
- **Queue growth** — not observable. Per-message tasks have no queue; would need a sampled `Task.Supervisor.children/1` cardinality metric.
- **Shutdown loss** — not observable. A killed task does not emit a `message_persist` event, and the in-memory hot window doesn't survive the shutdown to be compared against on next boot. Would need either a persisted write-intent ledger written *before* `add_message/4` returns (so an unmatched intent on next boot proves loss) or graceful-shutdown drain accounting (a count of pending tasks that flushed vs. were killed, emitted at terminate).

Add the missing two before relying on the trigger. When the trigger fires, move from per-message async tasks to a bounded write-behind process:

- keep the in-memory hot window update synchronous
- enqueue durable writes to a supervised writer process (per-conversation, which also closes the stale-write-after-clear race called out in §Async Durability Update)
- batch inserts in small groups or short intervals
- expose queue depth and flush latency telemetry
- flush or reject on shutdown/backpressure instead of silently dropping writes
