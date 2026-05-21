# Latency Baseline & Load Harness

**Status:** Shared, adapter, E2E, and soak harness code implemented; advisory CI workflow present but auto-triggers disabled (manual `workflow_dispatch` only) until the harness is hardened (multi-conv supersede-tail handling) and a pinned-hardware baseline lands
**Date:** 2026-05-20
**Author:** Sujeeth / Aira
**Context:** Performance work without a baseline is folklore. This plan establishes a reproducible, low-noise latency baseline for every hot-path stage in Fermix so future perf decisions (RuntimeContext cache, streaming, provider session reuse) anchor on real numbers, not estimates. Pairs with `docs/MAIN_AGENT_RUNTIME_CONTEXT_CACHE.md` — the data this harness produces should drive the runtime-context cache's cost/benefit decision.

**References:** `docs/MESSAGE_GATEWAY_ARCHITECTURE.md`, `docs/MAIN_AGENT_RUNTIME_CONTEXT_CACHE.md`, `apps/fermix_core/lib/fermix_core/agents/main_agent.ex`, `apps/fermix_core/lib/fermix_core/agent_loop.ex`, `apps/fermix_channels/lib/fermix_channels/dispatcher.ex`, `apps/fermix_core/lib/fermix_core/trace.ex`

**Implementation note (2026-05-20):** the implementation now includes bounded, content-free `duration_us` telemetry for shared dispatcher/command/MainAgent/provider/idempotency/transcription stages, adapter parse/auth/render/send stages, and `MainAgent` mailbox pickup. It also includes `mix fermix.bench`, `mix fermix.bench.diff`, `mix fermix.bench.soak`, core benchmark recorder/stats/reporter/mock-provider modules, shared-tier scenarios, direct adapter scenarios, dispatcher-to-adapter E2E smoke scenarios, a webhook idempotency timing scenario, and an advisory GitHub Actions workflow. The first checked-in `bench/baseline.json` still must be captured by a maintainer on pinned hardware; blocking CI thresholds remain deferred until variance is known. The current GitHub-hosted advisory workflow is directional, not gate-ready.

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
| **Shared hot path** | Ingress → MainAgent → AgentLoop → provider — channel-independent | Existing local `cli` channel with synthetic messages |
| **Adapter-specific** | `parse_*`, `send_message`, `send_media`, text splitting, HMAC verification | Per real channel (Telegram, Discord, Slack, WhatsApp, Signal, CLI) |
| **End-to-end smoke** | Transport → reply, integration regression detection | One scenario per enabled channel, smaller sample |

90% of perf work happens in the Shared tier with one scenario. Channel-specific benchmarks fire only when adapter code changes. E2E is a thin layer to catch "an adapter change accidentally slowed the shared pipeline."

The default `mix fermix.bench` run captures the shared Fermix-internal hot path. Adapter and E2E scenarios are available through `--scenarios=...` and use mocked channel HTTP/subprocess boundaries, so they measure Fermix adapter code without external network variance.

---

## 3. Where to Capture (Grounded in Fermix Architecture)

Every numbered item is a stage in the JSON report.

### 3.0 Current Telemetry Map

Three categories. The harness recorder should attach to existing events where possible (no duplicate instrumentation) and only fill true gaps in Stage 1.

**Already emits `duration_us` / `duration_ms` (use as-is):**

- `[:fermix, :agent, :prompt_context]`
- `[:fermix, :agent, :history]`
- `[:fermix, :agent, :reply]`
- `[:fermix, :agent, :message]` (whole turn)
- `[:fermix, :agent, :iteration]` (per provider call)
- `[:fermix, :capabilities, :select]`
- `[:fermix, :provider, :call]`
- `[:fermix, :tool, :exec]`
- `[:fermix, :memory, :message]` (`add_message`, at `conversation_store.ex:130`)
- `[:fermix, :memory, :extraction]` (async extractor work, `extractor.ex:418`)
- `[:fermix, :transcription, :message]`
- `[:fermix, :idempotency, :check]`
- `[:fermix, :idempotency, :outbound_media_claim]`
- `[:fermix, :channel, :parse]`
- `[:fermix, :channel, :authorize]`
- `[:fermix, :channel, :render]`
- `[:fermix, :channel, :message]`
- `[:fermix, :dispatcher, :normalize]`
- `[:fermix, :ingress, :authorize]`
- `[:fermix, :command, :dispatch]`
- `[:fermix, :dispatcher, :agent_delivery]`
- `[:fermix, :agent, :mailbox]`
- `[:fermix, :agent, :loop_runtime]`
- `[:fermix, :memory, :extraction_dispatch]`
- `[:fermix, :provider, :tool_schema]`
- `[:fermix, :channel, :reply]`
- `[:fermix, :compaction, :auto]`
- `[:fermix, :compaction, :forced]`

`[:fermix, :channel, :authorize]` is the transport-layer adapter allowlist check (`:allowed | :denied`). `[:fermix, :ingress, :authorize]` is gateway trust resolution (`:ok | :unauthorized | :unknown_channel`, plus trust metadata). Keep both stages in reports; they answer different questions.

**Emits event but no duration (add `duration_us` where a timed operation exists):**

- `[:fermix, :compaction, :auto_skipped]` — count only; skipped decision timing is still pending

**No event yet (new `:telemetry.execute/3` needed):**

- `maybe_auto_compact` decision overhead

### 3.1 Inbound (shared path through Dispatcher)

| # | Stage | Existing telemetry | Action |
| --- | --- | --- | --- |
| 1 | Transport receive → adapter `parse_*` | `[:fermix, :channel, :parse]` + `[:fermix, :channel, :message]` | Use as-is. |
| 2 | Adapter `authorized_user?` / `authorized_sender?` | `[:fermix, :channel, :authorize]` | Use as-is. |
| 3 | `Dispatcher.normalize_message/1` | `[:fermix, :dispatcher, :normalize]` | Use as-is. |
| 4 | `Ingress.Authorizer.resolve/1` | `[:fermix, :ingress, :authorize]` | Use as-is; expect <50 µs. |
| 5 | Transcription (audio only) | `[:fermix, :transcription, :message]` | Use as-is. |
| 6 | `Commands.dispatch/3` (when command) | `[:fermix, :command, :dispatch]` | Use as-is. Branch separately — most messages skip. |
| 7 | `agent_alive?` + `MainAgent.handle_message/2` cast | `[:fermix, :dispatcher, :agent_delivery]` | Use as-is. Mailbox enqueue + pickup is `[:fermix, :agent, :mailbox]`. |

### 3.1.1 Webhook-only ingress (not shared path)

`Idempotency.check_and_record/3` lives in the **HTTP webhook controller** (`apps/fermix_web/lib/fermix_web_web/controllers/webhook_controller.ex:146`), not in the dispatcher. Polling channels (Telegram, Signal) and the Discord gateway socket bypass it entirely. The shared local `cli` scenarios won't exercise it.

Measured separately as the `webhook_ingress_idempotency` scenario in §5.3. The current `fermix_channels` runner measures the shared idempotency GenServer directly because `fermix_channels` must not depend on `fermix_web`; a future `fermix_web`-owned runner can add controller overhead if that boundary becomes suspect.

### 3.2 MainAgent (per turn)

| # | Stage | Existing telemetry | Action |
| --- | --- | --- | --- |
| 8 | `PromptComposer.compose_with_metadata/1` | `[:fermix, :agent, :prompt_context]` | Use as-is. |
| 8a | `MainAgent` mailbox enqueue → pickup | `[:fermix, :agent, :mailbox]` | Use as-is. |
| 9 | `ConversationStore.get_history` | `[:fermix, :agent, :history]` | Use as-is. |
| 10 | Build context + `build_loop_runtime/4` | `[:fermix, :agent, :loop_runtime]` | Use as-is. Report as `main_agent_overhead`. |
| 11 | `AgentLoop.run/1` total | `[:fermix, :agent, :message]`, `[:fermix, :agent, :iteration]` | Use as-is. |
| 12 | `Compactor.compact` (auto + forced) | `[:fermix, :compaction, :auto]` / `:forced` | Use as-is for actual compaction work. `:auto_skipped` remains count-only. |
| 13 | `CapabilityRegistry.list_for/2` | `[:fermix, :capabilities, :select]` | Use as-is. |
| 14 | `to_provider_tools/1` | `[:fermix, :provider, :tool_schema]` | Use as-is. |
| 15 | Provider HTTP call | `[:fermix, :provider, :call]` | Use as-is. |
| 16 | Per-tool `execute/2` | `[:fermix, :tool, :exec]` | Use as-is. |
| 17 | `ConversationStore.add_message` ×2 | `[:fermix, :memory, :message]` with `duration_us` | Use as-is. |
| 18 | `deliver_reply` → outbound (§3.3) | `[:fermix, :agent, :reply]` | Use as-is at the boundary; outbound work follows. |
| 19 | `maybe_start_extraction` (dispatch) | `[:fermix, :memory, :extraction_dispatch]` | Use as-is. Async extractor work is its own metric (`[:fermix, :memory, :extraction]`, `duration_ms`) and stays a background measurement, not hot-path. |
| 20 | `maybe_auto_compact` decision | none | Pending only if decision overhead proves measurable. The compaction work itself is #12. |

### 3.3 Outbound

| # | Stage | Existing telemetry | Gap |
| --- | --- | --- | --- |
| 22 | `build_text_reply` / `build_media_reply` closure invocation | `[:fermix, :channel, :reply]` | Use as-is. |
| 23 | Adapter `send_message` text rendering (Telegram: markdown→HTML + split) | `[:fermix, :channel, :render]` | Use as-is. |
| 24 | Adapter HTTP send | `[:fermix, :channel, :message]` (`direction: :outbound`) | Use as-is. |
| 25 | Adapter `send_media` outbound cap + upload | `[:fermix, :channel, :message]` + `[:fermix, :idempotency, :outbound_media_claim]` | Use as-is. |
| 26 | Idempotency outbound media claim | `[:fermix, :idempotency, :outbound_media_claim]` | Use as-is. |

### 3.4 Cross-cutting

Verified ETS surfaces in Fermix today: capability registry (`:protected, :set` table), idempotency (`:public, :set` table), MCP server registries (one per server). `ConversationStore` is GenServer state + durable repo, **not** ETS. `Trace` writes JSONL files via async cast — no in-memory ETS buffer.

Measure:

- **BEAM memory** snapshots before/after each scenario (`:erlang.memory/0`).
- **ETS sizes** before/after for: `CapabilityRegistry` table, `Idempotency` table, per-server MCP tables.
- **Process count** before/after.
- **Supervisor restart counters** — must be 0 across the run.
- **`Trace` process mailbox depth** sampled mid-scenario if the trace writer is enabled. (Default is disabled in bench mode; see §9.)

Current shared-tier memory snapshots are taken before the scenario starts and after the recorder has detached and deleted its ETS table, so recorder buffer growth is not counted as Fermix ETS growth.

### 3.5 Gaps to fix before the harness ships (Stage 1 of §7)

Per §3.0, the only remaining optional gap is:

1. Decide whether `maybe_auto_compact` skipped-decision timing is useful; the actual compaction duration is already covered. This is intentionally not in the default recorder yet because skipped compaction is a tiny branch-only decision and has not shown up as a bottleneck.

Constraints on Stage 1 (non-interference principle):

- Telemetry payloads must be **bounded and content-free**. No message bodies, no full capability lists, no full prompt parts.
- Telemetry handlers must not add synchronous disk or network work on the user path. The bench recorder buffers in ETS and flushes at scenario end; the trace writer is disabled in bench mode.
- Each new event has a single `duration_us` measurement and a small metadata map (channel, agent, status, and existing conversation identifiers where neighboring telemetry already uses them).
- Existing behavior must stay unchanged; add focused telemetry regression tests for new events.

---

## 4. Aggregation Mechanics

Per scenario, per stage:

```elixir
%{
  count: 1000,
  p50_us: 2_134,
  p95_us: 8_421,
  p99_us: 19_882,
  max_us: 142_113,
  mean_us: 3_201.0,
  stdev_us: 4_872.0
}
```

Rules:

- **Current implementation:** sort-based list for all sample sizes. Histogram-backed aggregation is only needed if future runs move beyond the current ≤10k target.
- **One bucket per scenario per stage.** Don't aggregate across scenarios (Telegram numbers must not mix with WhatsApp).
- **Mean + stdev are sanity checks**; p95 is the gate.
- **Planned tail tracker:** keep the worst 10 samples per stage with bounded context (timestamp, conversation key, tool count, message length). Debug aid for p99 spikes.

---

## 5. Scenarios

Each is a separate JSON entry; each runs N samples with warmup.

### 5.1 Shared (channel-agnostic, drives the local `cli` channel path with synthetic messages)

| Scenario | What's varied | Sample size |
| --- | --- | --- |
| `shared_text_minimal` | 1 turn, 5 caps, empty history, no tool calls, mock provider returns plain text | 1000 |
| `shared_text_with_tools` | 1 turn, 30 caps, empty history, mock provider returns 1 tool call → 1 read-only tool → final response (2 provider calls) | 1000 |
| `shared_text_long_history` | 1 turn, 30 caps, 100-message history, no tools | 500 |
| `shared_text_max_iter` | 1 turn forced to hit `max_iterations = 25` (tool loop pattern) | 200 |
| `shared_cold_start` | First N messages immediately after `MainAgent` restart, no warmup | 50 |
| `shared_single_flight_contention` | 100 messages to **same** conversation key, arrival rate > processing rate; measures supersede latency + active/pending ratios | 500 |
| `shared_multi_conv_throughput` | 100 distinct conversation keys, dispatched in waves with at most one in-flight message per key; each wave waits for replies and agent idle before the next wave, so throughput is measured without single-flight supersession | 1000 messages total |

### 5.2 Adapter-specific (drive the adapter function directly, no daemon)

| Scenario | Channel | What's measured |
| --- | --- | --- |
| `telegram_parse_inbound` | Telegram | `parse_update/1` on representative payloads |
| `telegram_send_short_text` | Telegram | `send_message/3` with mocked HTTP, 100-char text |
| `telegram_send_long_text_split` | Telegram | `send_message/3` with 20k chars markdown → render + split + multi-POST |
| `telegram_send_media` | Telegram | `send_media/3` with 5 MB image, mocked upload |
| `discord_*`, `slack_*`, `whatsapp_*`, `signal_*` | each | Same shape: parse, send_short, send_media |

Adapter scenarios use `Req.Test` stubs to return mock responses deterministically. Network-latency measurement is explicitly out of scope; the harness measures Fermix code.

### 5.3 End-to-end smoke (1 scenario per enabled real channel + webhook idempotency)

200 samples each, end-to-end through the dispatcher with stubbed HTTP. Catches integration regressions where a shared-tier change accidentally slows a specific channel.

Includes a dedicated **`webhook_ingress_idempotency`** scenario so `Idempotency.check_and_record/3` is exercised. The shared-tier scenarios do not reach this code (see §3.1.1). The Phoenix controller wrapper is intentionally not called from `fermix_channels` to avoid reversing the app dependency direction.

### 5.4 Soak (separate command, optional)

`shared_soak_10min` — 10-minute sustained run across the shared multi-conversation scenario. Reports batch count, processed messages, throughput, and BEAM memory growth slope. Not a CI gate; run pre-release.

---

## 6. Output

`bench/baseline.json` should be checked into the repo after a deliberate pinned-machine baseline run. Local ad-hoc runs should write `bench/current.json`. Compare with `mix fermix.bench.diff old.json new.json`.

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
    "trace_writes_enabled": false,
    "output": "bench/current.json"
  },
  "scenarios": {
    "shared_text_minimal": {
      "messages_dispatched": 1000,
      "messages_processed": 1000,
      "messages_superseded": 0,
      "wall_time_us": 4200000,
      "throughput_messages_per_second": 238.1,
      "setup": {
        "environments_started": 1,
        "history_conversations_seeded": 0,
        "history_messages_seeded": 0
      },
      "stages": {
        "ingress_authorize":   { "count": 1000, "p50_us": 18,   "p95_us": 42,   "p99_us": 110,   "max_us": 240 },
        "prompt_context":      { "count": 1000, "p50_us": 2134, "p95_us": 8421, "p99_us": 19882, "max_us": 142113 },
        "history_fetch":       { "count": 1000, "p50_us": 380,  "p95_us": 1100, "p99_us": 2400,  "max_us": 5800 },
        "capabilities_select": { "count": 1000, "p50_us": 320,  "p95_us": 580,  "p99_us": 980,   "max_us": 2400 },
        "agent_message":       { "count": 1000, "p50_us": 8500, "p95_us": 14200,"p99_us": 22000, "max_us": 48000 },
        "agent_reply":         { "count": 1000, "p50_us": 1200, "p95_us": 2100, "p99_us": 3400,  "max_us": 6800 }
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

Initial shared-path pass is complete for dispatcher normalization, ingress authorization, command dispatch, agent delivery, reply closure invocation, transcription, idempotency, MainAgent loop runtime, extraction dispatch, provider tool schema conversion, and actual compaction work.

Remaining edits per the §3.0 map:

1. **Implemented:** adapter-specific parse/auth/send/render/media paths emit `duration_us`.
2. **Implemented:** `MainAgent` mailbox enqueue → pickup emits `duration_us`.
3. **Deferred by design:** `maybe_auto_compact` skipped-decision timing. Actual compaction durations already emit `duration_us`; skipped decisions remain count-only unless baseline data shows a need.

Constraints (per §3.5):

- Telemetry payloads bounded, content-free, no synchronous I/O.
- Existing behavior remains unchanged; focused telemetry regression tests cover new shared-path events.
- The bench recorder attaches to the existing event names; no rename or duplicate emission.

Verify:

- Every implemented shared stage in §3.1 and §3.2 has a duration source (existing event, extended event, or new event).
- Remaining gap matches the §3.5 list.
- A quick `grep -r ":telemetry.execute" apps/` smoke shows no inadvertent duplication.

### Stage 2 — Bench infrastructure (1 day)

Implemented:

- `apps/fermix_core/lib/fermix_core/bench/` module tree under `lib/`, not `test/` — Mix tasks cannot depend on test-tree modules.
- `FermixCore.Bench.Recorder` — telemetry handler that buffers `{stage, duration_us}` tuples in an ETS `:duplicate_bag` with read/write concurrency during a scenario and flushes at scenario end.
- `FermixCore.Bench.Stats` — sort-based percentile computation for the default sample sizes.
- `FermixCore.Bench.MockProvider` — minimal `FermixCore.Providers.Adapter` implementation with deterministic `:text`, `:tool_once`, and `:repeat_tool` scripts configured through adapter opts.
- `FermixCore.Bench.Reporter` — JSON writer + p95 delta diff.
- `FermixChannels.Bench.Runner` — shared-path runner lives in `fermix_channels` because it deliberately exercises `FermixChannels.Dispatcher`; core benchmark primitives remain in `fermix_core`.
- `FermixChannels.Bench.AdapterRunner` — adapter and dispatcher-to-adapter E2E scenarios with mocked channel boundaries.
- `mix fermix.bench` with `--scenarios=…`, `--samples=N`, `--warmup=N`, `--output=path`, `--compare=path`, and `--list`.
- `mix fermix.bench.diff OLD.json NEW.json`.
- `mix fermix.bench.soak` with `--duration-ms=N`, `--samples=N`, and `--output=path`.

Verify:

- Recorder attaches and detaches cleanly per scenario.
- Stats produce stable percentiles against deterministic samples.
- Mix task accepts the listed flags.

### Stage 3 — Shared-tier scenarios (1 day)

Implemented scenarios in §5.1. The runner drives `FermixChannels.Dispatcher.dispatch/2` with synthetic messages on the existing local `cli` channel and a stubbed `reply_fn`.

Verify:

- Each scenario completes within sane wallclock.
- Per-stage counts are emitted for the expected shared events.
- Contention scenarios report dispatched, processed, and superseded message counts explicitly.
- Multi-conversation scenarios report `wall_time_us` and `throughput_messages_per_second`.
- First baseline `bench/baseline.json` is captured and checked in from the pinned baseline machine, not from an ad-hoc developer laptop run.

### Stage 4 — Adapter scenarios (1-2 days)

Implemented §5.2 per channel. Each adapter benchmark exercises `parse_*`, `send_message`, and `send_media` directly with `Req.Test` stubs or the in-process Signal bench client. No daemon boot is needed. The default `mix fermix.bench` run still stays on the shared tier; adapter scenarios run when named explicitly with `--scenarios=...`.

Verify:

- Each channel's text rendering and media flow has its own scenario entry.
- Telegram markdown→HTML+split scenario produces a measurable delta from short-text.

### Stage 5 — E2E smoke (half day)

Implemented dispatcher-to-adapter E2E smoke scenarios for the configured channel adapters (`*_e2e_text`). These parse a representative inbound payload, dispatch through `Dispatcher` and `MainAgent`, and deliver the reply through the adapter's outbound send path with mocked HTTP/subprocess boundaries.

`webhook_ingress_idempotency` measures the idempotency GenServer used by the webhook controller path. A full Phoenix controller benchmark belongs in `fermix_web` rather than `fermix_channels`; keep that as a web-owned extension if controller overhead itself becomes a suspected bottleneck.

Verify:

- Each enabled channel has an E2E entry.
- E2E numbers are within an expected envelope of `shared_text_minimal` (channel overhead is small).

### Stage 6 — CI integration (half day, then ~1 week observation)

CI gates are tempting but premature without variance data. Phase the rollout:

**Phase 6a — advisory-only.** Implemented as `.github/workflows/bench.yml`. GitHub Actions runs `mix fermix.bench` on every PR touching `apps/fermix_core/` or `apps/fermix_channels/`; if `bench/baseline.json` exists, the workflow embeds `mix fermix.bench.diff bench/baseline.json bench/current.json` output in the PR comment. The check is advisory (`continue-on-error`) and uploads `bench/current.json` as an artifact. The current `ubuntu-24.04` GitHub-hosted runner is useful for directional PR feedback only; move to a pinned self-hosted runner before treating numbers as authoritative.

**Phase 6b — nightly baseline refresh.** The workflow has a scheduled run. Use the same pinned runner for ~7 days of nightly data before deriving thresholds.

**Phase 6c — promote to blocking.** Once nightly variance is known per stage, derive per-stage regression thresholds (e.g., "p95 stage X has σ ≈ 8%, fail at >3σ ≈ 25%"). Promote the PR check to blocking with those thresholds. Operator refreshes the baseline via `git commit bench/baseline.json` after a deliberate change.

Until 6c, the harness reports without enforcing. Better to ship a useful advisory tool than a flaky gate.

Verify:

- Phase 6a: a no-op PR shows ~zero regression (within noise).
- Phase 6b: nightly runs land 7 consecutive baselines; variance per stage is computed.
- Phase 6c: a deliberately slowed function fails the check; the baseline refresh path is documented.

### Stage 7 — Soak (optional, 1 day)

Implemented `shared_soak_10min` as `mix fermix.bench.soak`. Manual pre-release command; reports batch count, processed messages, throughput, and BEAM memory growth slope.

Historical estimate: 5-7 days for Stages 1-6. The remaining work is operational baseline capture and blocking-gate rollout.

---

## 8. Anti-goals

- **No real-provider calls in the default suite.** Network jitter + cost + nondeterminism make it useless for regression. Real-provider tests live in a separate `mix fermix.smoke` command, opt-in, with a hard call budget.
- **No dashboards / UI.** JSON files + git diff + CI comment. UI is for a year from now.
- **No distributed tracing.** The existing trace JSONL writer (`apps/fermix_core/lib/fermix_core/trace/telemetry_handler.ex`) covers a fixed event set today: `[:fermix, :provider, :call]`, `[:fermix, :tool, :exec]`, `[:fermix, :channel, :message]`, `[:fermix, :agent, :prompt_context]`, `[:fermix, :agent, :history]`, `[:fermix, :agent, :reply]`, `[:fermix, :capabilities, :select]`, plus MCP inbound events. It does **not** cover `[:fermix, :agent, :message]`/`:iteration`, compaction events, memory message/extraction events, dispatcher events, or idempotency events. The bench harness attaches its own recorder; it does not piggyback on trace JSONL.
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

Once Stages 1-3 land and you run `mix fermix.bench` once (Shared tier):

- Whether `compose_with_metadata` is actually 2 ms or 20 ms → recalibrates `docs/MAIN_AGENT_RUNTIME_CONTEXT_CACHE.md`'s cost/benefit math.
- Whether `CapabilityRegistry.list_for/2` is noise or measurable at 30 caps → tells you if the cache's capability-selection win matters.
- Whether single-flight contention causes pending-slot churn in real patterns → informs the supersede design.
- Whether outbound text rendering (Telegram markdown→HTML+split) dominates the outbound path → tells you if streaming would help more.
- Whether `Compactor.compact` durations justify the per-message auto-compact check on the hot path.

With Stages 4-5 (Adapter + E2E smoke) implemented and `webhook_ingress_idempotency` available:

- Whether `Idempotency.check_and_record/3` is a chokepoint at sustained webhook QPS → tells you if the F-06 GenServer-serialization choice has a measurable cost on Slack/WhatsApp paths. Polling-channel scenarios won't surface this (see §3.1.1).

That data should drive every perf decision for the next year, including whether the RuntimeContext cache is worth its invalidation-machinery cost.

---

## 11. Bottom Line

The harness code now covers Stages 1-7 except the intentionally manual pinned-machine baseline and the deferred promotion from advisory to blocking CI. Use the first week of advisory runs to establish variance before changing thresholds or enabling blocking behavior.
