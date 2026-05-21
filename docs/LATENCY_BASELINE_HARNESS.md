# Latency Baseline & Load Harness

**Status:** Draft
**Date:** 2026-05-20
**Author:** Sujeeth / Aira
**Context:** Performance work without a baseline is folklore. This plan establishes a reproducible, low-noise latency baseline for every hot-path stage in Fermix so future perf decisions (RuntimeContext cache, streaming, provider session reuse) anchor on real numbers, not estimates. Pairs with `docs/MAIN_AGENT_RUNTIME_CONTEXT_CACHE.md` — the data this harness produces should drive the runtime-context cache's cost/benefit decision.

**References:** `docs/MESSAGE_GATEWAY_ARCHITECTURE.md`, `docs/MAIN_AGENT_RUNTIME_CONTEXT_CACHE.md`, `apps/fermix_core/lib/fermix_core/agents/main_agent.ex`, `apps/fermix_core/lib/fermix_core/agent_loop.ex`, `apps/fermix_channels/lib/fermix_channels/dispatcher.ex`, `apps/fermix_core/lib/fermix_core/trace.ex`

---

## 1. Goal

Run before any perf-relevant change; diff against last baseline; catch regressions before they ship. The harness must:

- Cover every Fermix hot-path stage with per-stage duration measurement.
- Produce stable percentile numbers (not single-shot timings) so day-to-day noise doesn't drown signal.
- Run deterministically with a mock provider so network/LLM variance doesn't pollute the measurement.
- Output JSON that diffs cleanly against a checked-in baseline.
- Gate CI on regression thresholds without becoming flaky.

The harness is not a load tester for external platforms. It measures Fermix code.

---

## 2. Two Design Decisions

### 2.1 Single run vs sample → always sample

Single runs are useless for latency. File I/O variance (OS cache hot/cold), BEAM scheduler preemption, ETS lookup jitter, and HTTP client warmup blow up single-shot numbers.

- **Warmup:** discard the first 20 samples per scenario (JIT, file cache, ETS hot, connection pools warm).
- **Sample size:** ≥200 for stable p95; ≥1000 for stable p99. Default 1000.
- **Report:** `count`, `p50`, `p95`, `p99`, `max`, `mean`, `stdev` per stage. **Primary metric is p95.** That's where user-perceptible latency lives. Don't lead with mean — outliers dominate UX.
- **Diff two runs by p95 delta** with relative thresholds (warn >20%, fail >50%).

Single-shot measurement has one legitimate use: ad-hoc "is this fast?" exploration. Never for baselines, never for CI gates.

### 2.2 Per-channel vs broad → split by axis

Most work is channel-agnostic. Going per-channel for everything triples the harness for the same code. Split it:

| Tier | What it measures | Channels |
| --- | --- | --- |
| **Shared hot path** | Ingress → MainAgent → AgentLoop → provider — channel-independent | One synthetic `bench` channel |
| **Adapter-specific** | `parse_*`, `send_message`, `send_media`, text splitting, HMAC verification | Per real channel (Telegram, Discord, Slack, WhatsApp, Signal, CLI) |
| **End-to-end smoke** | Transport → reply, integration regression detection | One scenario per enabled channel, smaller sample |

90% of perf work happens in the Shared tier with one scenario. Channel-specific benchmarks fire only when adapter code changes. E2E is a thin layer to catch "an adapter change accidentally slowed the shared pipeline."

---

## 3. Where to Capture (Grounded in Fermix Architecture)

Every numbered item is a stage in the JSON report.

### 3.1 Inbound

| # | Stage | Existing telemetry | Gap |
| --- | --- | --- | --- |
| 1 | Transport receive → adapter parse | `[:fermix, :channel, :message]` (count only) | Needs `duration_us`. |
| 2 | Adapter `authorized_user?` check | none | New. |
| 3 | `Idempotency.check_and_record/3` | none | GenServer.call; QPS chokepoint. New. |
| 4 | `Dispatcher.normalize_message/1` | none | Group with #5. New. |
| 5 | `Ingress.Authorizer.resolve/1` | none | Pure module; expect <50 µs. New. |
| 6 | Transcription (audio only) | verify `[:fermix, :transcription, :*]` | Verify. |
| 7 | `Commands.dispatch/3` (commands only) | none | Branch separately — most messages skip. New. |
| 8 | `agent_alive?` + `MainAgent.handle_message/2` cast | none | Cast is microseconds; mailbox enqueue + pickup is what matters. New. |

### 3.2 MainAgent (per turn)

| # | Stage | Existing telemetry | Gap |
| --- | --- | --- | --- |
| 9 | `PromptComposer.compose_with_metadata/1` | `[:fermix, :agent, :prompt_context]` | OK. |
| 10 | `ConversationStore.get_history` | `[:fermix, :agent, :history]` | OK. |
| 11 | Build context + `build_loop_runtime/4` | none | Report as `main_agent_overhead`. New. |
| 12 | `AgentLoop.run/1` total | `[:fermix, :agent, :message]`, `[:fermix, :agent, :iteration]` | OK. |
| 13 | `Compactor.compact` (when active) | `[:fermix, :compaction, :*]` | OK. |
| 14 | `CapabilityRegistry.list_for/2` | `[:fermix, :capabilities, :select]` | OK. |
| 15 | `to_provider_tools/1` | none | New. |
| 16 | Provider HTTP call | verify `[:fermix, :provider, :call]` | Verify. |
| 17 | Per-tool `execute/2` | `[:fermix, :tool, :exec]` | OK. |
| 18 | `ConversationStore.add_message` x2 | none | New. |
| 19 | `deliver_reply` → outbound (see 3.3) | `[:fermix, :agent, :reply]` | OK at boundary; outbound work follows. |
| 20 | `maybe_start_extraction` (dispatch only) | `[:fermix, :memory, :extraction_*]` | Measure the dispatch on hot path, not the async work. |
| 21 | `maybe_auto_compact` (dispatch only) | `[:fermix, :compaction, :auto*]` | Same. |

### 3.3 Outbound

| # | Stage | Existing telemetry | Gap |
| --- | --- | --- | --- |
| 22 | `build_text_reply` / `build_media_reply` closure invocation | none | New. |
| 23 | Adapter `send_message` text rendering (Telegram: markdown→HTML + split) | none | Per-channel. New. |
| 24 | Adapter HTTP send | `[:fermix, :channel, :message]` (count, `direction: :outbound`) | Needs `duration_us`. |
| 25 | Adapter `send_media` outbound cap + upload | same | New. Separate cap-check from upload. |
| 26 | Idempotency outbound media claim | none | GenServer.call per media. New. |

### 3.4 Cross-cutting

- **BEAM memory** snapshots before/after each scenario (`:erlang.memory/0`).
- **ETS table sizes** before/after (capability registry, conversation store, idempotency, trace buffer).
- **Process count** before/after.
- **Supervisor restart counters** (must be 0 across the run).
- **Trace buffer flush time** — Fermix writes JSONL traces; hidden cost worth measuring.

### 3.5 Gaps to fix before the harness ships

~10 stages don't emit duration telemetry today. Add `:telemetry.execute/3` at those points with `duration_us` measurement. Keep metadata thin (no full message dumps) to avoid perturbing the measurement. Stage 1 of the implementation plan below.

---

## 4. Aggregation Mechanics

Per scenario, per stage:

```elixir
%{
  stage: "prompt_context",
  unit: :microsecond,
  count: 1000,
  p50: 2_134,
  p95: 8_421,
  p99: 19_882,
  max: 142_113,
  mean: 3_201,
  stdev: 4_872
}
```

Rules:

- **Histogram-backed** for runs >10k samples; sort-based list for ≤10k (simpler, fine for default 1000).
- **One bucket per scenario per stage.** Don't aggregate across scenarios (Telegram numbers must not mix with WhatsApp).
- **Mean + stdev are sanity checks**; p95 is the gate.
- **Tail tracker**: keep the worst 10 samples per stage with full context (timestamp, conversation key, tool count, message length). Debug aid for p99 spikes.

---

## 5. Scenarios

Each is a separate JSON entry; each runs N samples with warmup.

### 5.1 Shared (channel-agnostic, drives synthetic `bench` channel)

| Scenario | What's varied | Sample size |
| --- | --- | --- |
| `shared_text_minimal` | 1 turn, 5 caps, empty history, no tool calls, mock provider returns plain text | 1000 |
| `shared_text_with_tools` | 1 turn, 30 caps, empty history, mock provider returns 1 tool call → 1 read-only tool → final response (2 provider calls) | 1000 |
| `shared_text_long_history` | 1 turn, 30 caps, 100-message history, no tools | 500 |
| `shared_text_max_iter` | 1 turn forced to hit `max_iterations = 25` (tool loop pattern) | 200 |
| `shared_cold_start` | First N messages immediately after `MainAgent` restart, no warmup | 50 |
| `shared_single_flight_contention` | 100 messages to **same** conversation key, arrival rate > processing rate; measures supersede latency + active/pending ratios | 500 |
| `shared_multi_conv_throughput` | 100 distinct conversation keys, 10 messages each, fan-out | 1000 messages total |

### 5.2 Adapter-specific (drive the adapter function directly, no daemon)

| Scenario | Channel | What's measured |
| --- | --- | --- |
| `telegram_parse_inbound` | Telegram | `parse_update/1` on representative payloads |
| `telegram_send_short_text` | Telegram | `send_message/3` with mocked HTTP, 100-char text |
| `telegram_send_long_text_split` | Telegram | `send_message/3` with 20k chars markdown → render + split + multi-POST |
| `telegram_send_media` | Telegram | `send_media/3` with 5 MB image, mocked upload |
| `discord_*`, `slack_*`, `whatsapp_*`, `signal_*` | each | Same shape: parse, send_short, send_media |

Adapter scenarios use `Req.Test` stubs to return mock responses deterministically. Network-latency measurement is explicitly out of scope; the harness measures Fermix code.

### 5.3 End-to-end smoke (1 scenario per enabled real channel)

200 samples each, end-to-end through the dispatcher with stubbed HTTP. Catches integration regressions where a shared-tier change accidentally slows a specific channel.

### 5.4 Soak (separate command, optional)

`shared_soak_10min` — 10-minute sustained run at fixed QPS across 50 conversation keys. Reports BEAM memory growth slope, ETS size deltas, supervisor restarts. Not a CI gate; run pre-release.

---

## 6. Output

`bench/baseline.json` checked into the repo. Compare with `mix fermix.bench.diff old.json new.json`.

```json
{
  "version": 1,
  "git_sha": "aa85f91",
  "timestamp": "2026-05-20T14:32:11Z",
  "elixir": "1.18.0",
  "otp": "27.0",
  "config": {
    "samples": 1000,
    "warmup": 20,
    "provider_mode": "mock",
    "trace_writes_enabled": false
  },
  "scenarios": {
    "shared_text_minimal": {
      "messages_processed": 1000,
      "stages": {
        "ingress_authorize":   { "p50_us": 18,   "p95_us": 42,   "p99_us": 110,   "max_us": 240 },
        "prompt_context":      { "p50_us": 2134, "p95_us": 8421, "p99_us": 19882, "max_us": 142113 },
        "history_fetch":       { "p50_us": 380,  "p95_us": 1100, "p99_us": 2400,  "max_us": 5800 },
        "capabilities_select": { "p50_us": 320,  "p95_us": 580,  "p99_us": 980,   "max_us": 2400 },
        "agent_loop_total":    { "p50_us": 8500, "p95_us": 14200,"p99_us": 22000, "max_us": 48000 },
        "deliver_reply":       { "p50_us": 1200, "p95_us": 2100, "p99_us": 3400,  "max_us": 6800 }
      },
      "memory": {
        "beam_total_before_bytes": 142336000,
        "beam_total_after_bytes": 148812000,
        "ets_growth_bytes": 6476000
      }
    }
  }
}
```

Diff output:

```
$ mix fermix.bench.diff bench/baseline.json bench/current.json

shared_text_minimal:
  prompt_context        p95  8.4ms → 2.1ms  -75%  improved
  capabilities_select   p95  0.4ms → 0.4ms   +0%
  agent_loop_total      p95 12.8ms → 6.7ms  -48%  improved

telegram_send_long_text_split:
  render_split          p95  4.2ms → 6.8ms  +62%  regression (threshold +50%)

Status: 1 regression
```

Regression thresholds (configurable per stage):

- `+20%` → warn
- `+50%` → fail (non-zero exit)

---

## 7. Implementation Stages

### Stage 1 — Telemetry gap fill (1 day)

Add `:telemetry.execute/3` with `duration_us` measurement at the ~10 stages currently uninstrumented. Surgical edits only; no behavior change. Tests pass unchanged.

Verify:

- Every numbered stage in §3 emits a duration event.
- Existing tests pass.
- Telemetry payload metadata is bounded (no message content, no full capability lists).

### Stage 2 — Bench infrastructure (1 day)

- `apps/fermix_core/lib/fermix_core/bench/` module tree
- `Bench.Recorder` — telemetry handler that buffers `{stage, duration_us}` tuples in ETS during a scenario
- `Bench.Stats` — percentile computation (sort-based for n ≤10k; histogram for larger)
- `Bench.MockProvider` — reuses the existing test mock adapter
- `Bench.Reporter` — JSON writer + delta diff
- `mix fermix.bench` task with `--scenarios=…`, `--samples=N`, `--warmup=N`, `--output=path`, `--compare=path`

Verify:

- Recorder attaches and detaches cleanly per scenario.
- Stats produce stable percentiles on repeated runs against a no-op scenario.
- Mix task accepts the listed flags.

### Stage 3 — Shared-tier scenarios (1 day)

Implement scenarios in §5.1. Drive `FermixChannels.Dispatcher.dispatch/2` with synthetic `bench` channel + stubbed `reply_fn`. Validate that per-stage durations sum correctly to `agent_loop_total` within 1ms tolerance.

Verify:

- Each scenario completes within sane wallclock.
- Per-stage sums match aggregates.
- First baseline `bench/baseline.json` checked in.

### Stage 4 — Adapter scenarios (1-2 days)

Implement §5.2 per channel. Each adapter benchmark exercises `parse_*`, `send_message`, `send_media` directly with `Req.Test` stubs. No daemon boot needed.

Verify:

- Each channel's text rendering and media flow has its own scenario entry.
- Telegram markdown→HTML+split scenario produces a measurable delta from short-text.

### Stage 5 — E2E smoke (half day)

Implement §5.3. Same harness but full pipeline per channel.

Verify:

- Each enabled channel has an E2E entry.
- E2E numbers are within an expected envelope of `shared_text_minimal` (channel overhead is small).

### Stage 6 — CI integration (half day)

- GitHub Actions job runs `mix fermix.bench --compare=bench/baseline.json` on every PR that touches `apps/fermix_core/` or `apps/fermix_channels/`.
- Posts a comment with the delta table.
- Fails the check on >50% regression.
- Operator refreshes baseline via `git commit bench/baseline.json` after a deliberate change.

Verify:

- A no-op PR shows zero regressions.
- A deliberately slowed function fails the check.
- Baseline refresh path documented.

### Stage 7 — Soak (optional, 1 day)

Implement `shared_soak_10min`. Manual `mix fermix.bench.soak` pre-release. Reports BEAM/ETS growth slopes.

**Total: 5-7 days for Stages 1-6.**

---

## 8. Anti-goals

- **No real-provider calls in the default suite.** Network jitter + cost + nondeterminism make it useless for regression. Real-provider tests live in a separate `mix fermix.smoke` command, opt-in, with a hard call budget.
- **No dashboards / UI.** JSON files + git diff + CI comment. UI is for a year from now.
- **No distributed tracing.** Existing trace JSONL files capture per-event detail when debugging a spike.
- **No production telemetry as the harness.** The harness runs in a controlled benchmark config. Prod telemetry is a separate stream.
- **No load test for external platforms.** Driving real Telegram/Slack at scale is rate-limit suicide and irrelevant — the bottleneck isn't them.
- **No happy-path-only thinking.** Tail latency scenarios (`max_iter` loop, single-flight contention) are first-class.

---

## 9. Open Questions

1. **Baseline location.** `bench/baseline.json` in the repo root, refreshed manually by a maintainer when a deliberate change shifts numbers. Alternative: per-branch baseline in CI cache. The in-repo version is simpler and visible — start there.
2. **Trace writer during bench.** Disable by default. `~/.fermix/traces/` writes add measurable JSONL I/O. Add a `bench_mode` config flag that routes traces to a null sink.
3. **Auto-compaction during scenarios.** Disabled by default for cleaner numbers; separate scenario `shared_with_auto_compact` exercises it intentionally.
4. **Idempotency and sample reuse.** Generate unique message IDs per sample so `Idempotency.check_and_record/3` doesn't short-circuit after the first message.
5. **Per-tool execution duration breakdown.** §3.2 #17 reports an aggregate; expose per-tool too for `send_attachment`, `web_fetch`, `shell` — they vary a lot.
6. **Cold-start cadence.** `shared_cold_start` runs immediately after `MainAgent` restart. Should it run before or after warmup? Before — cold-start is its own measurement, not a warmup throwaway.

---

## 10. What the First Baseline Will Tell You

Once Stages 1-3 land and you run `mix fermix.bench` once:

- Whether `compose_with_metadata` is actually 2 ms or 20 ms → recalibrates `docs/MAIN_AGENT_RUNTIME_CONTEXT_CACHE.md`'s cost/benefit math.
- Whether `CapabilityRegistry.list_for/2` is noise or measurable at 30 caps → tells you if the cache's capability-selection win matters.
- Whether `Idempotency.check_and_record/3` is a chokepoint at sustained QPS → tells you if F-06's GenServer-serialization choice has a cost.
- Whether single-flight contention causes pending-slot churn in real patterns → informs the supersede design.
- Whether outbound text rendering (Telegram markdown→HTML+split) dominates the outbound path → tells you if streaming would help more.

That data should drive every perf decision for the next year, including whether the RuntimeContext cache is worth its invalidation-machinery cost.

---

## 11. Bottom Line

5-7 days of work, broken into stages that each ship independently. After Stage 3 you have data. After Stage 6 you have a regression gate. Defer Stage 7 until measured wins from Stages 1-6 justify it.
