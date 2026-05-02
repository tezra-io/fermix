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

It wrote through the same public `ConversationStore.add_message/4` API twice: once with no repo configured for the memory-only baseline, and once with an enabled SQLite repo using WAL mode.

Local run on 2026-04-24:

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

Why:

- the active conversation already lives in the current request context and the in-memory `ConversationStore` window
- `memory.db` is durability and historical reference, not the thing that should decide whether a generated reply reaches the user
- a transient local SQLite failure should not drop an already-generated response
- keeping the in-memory append synchronous preserves next-turn context without blocking on disk

The async durable path logs failures, emits telemetry, and retries boundedly before giving up. Pending writes are versioned against conversation clears so a stale async write is skipped after `ConversationStore.clear/2`.

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

If runtime telemetry shows retry storms, queue growth, or shutdown loss, move from per-message async tasks to a bounded write-behind process:

- keep the in-memory hot window update synchronous
- enqueue durable writes to a supervised writer process
- batch inserts in small groups or short intervals
- expose queue depth and flush latency telemetry
- flush or reject on shutdown/backpressure instead of silently dropping writes
