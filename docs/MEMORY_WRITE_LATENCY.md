# Conversation Write Latency

## Context

TEZ-374 changed `FermixCore.Memory.ConversationStore.add_message/4` from an async cast to a synchronous call. The caller now continues only after the in-memory update and any enabled SQLite write complete.

The main agent writes two chat messages on each successful turn before delivering the reply:

- user message
- assistant message

This is intentional for Stage 1A durability, but the cost needs to remain visible before later memory stages add more work to the same path.

## Measurement

The repeatable benchmark entrypoint is:

```sh
mix fermix.memory_write_latency --iterations 5000 --warmup 200 --message-bytes 512
```

It writes through the same public `ConversationStore.add_message/4` API twice: once with no repo configured for the memory-only baseline, and once with an enabled SQLite repo using WAL mode.

Local run on 2026-04-24:

```text
memory only: avg=1.2us p50=1us p95=3us p99=4us max=26us
durable sqlite: avg=133.1us p50=122us p95=180us p99=501us max=1070us
durable overhead: avg=131.9us p50=121us p95=179us p99=500us max=1069us
```

At two synchronous chat writes per successful agent turn, the measured durable overhead is roughly:

- average: 264us per turn
- p95: 358us per turn
- p99: 1ms per turn
- max in this run: 2.1ms per turn

## Runtime Telemetry

`ConversationStore.add_message/4` emits `[:fermix, :memory, :message]` with:

- `count`
- `duration_us`
- `durable_write_us`
- metadata: `channel`, `chat_id`, `durable?`

`duration_us` measures the synchronous store callback work. `durable_write_us` measures the nested SQLite insert call when a durable repo is enabled, or `0` when writes are memory-only.

## Decision

The current synchronous durability guarantee is acceptable for Stage 1A production traffic. The measured overhead is sub-millisecond at p95 for the two-write turn path, and the reply path is dominated by provider latency and tool execution rather than local SQLite persistence.

Keep synchronous writes for now because they give simple crash semantics: after `add_message/4` returns, the chat message is durable. Revisit the design if runtime telemetry shows sustained p95 durable write latency above 10ms per message or if later memory stages add more synchronous work before reply delivery.

If that threshold is crossed, prefer a bounded write-behind design:

- keep the in-memory hot window update synchronous
- enqueue durable writes to a supervised writer process
- batch inserts in small groups or short intervals
- expose queue depth and flush latency telemetry
- flush or reject on shutdown/backpressure instead of silently dropping writes
