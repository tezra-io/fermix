# Production-Grade Eval: Capability Scoring, Cross-Model Ranking, and Uplift

**Status:** draft (research complete, 2026-06-27) · **Owner:** sujeeth
**Predecessor:** `.claude/skills/fermix-e2e-eval` (behavioral regression tier — kept, not replaced)

---

## 0. The problem, stated correctly

The `fermix-e2e-eval` skill answers **"did this change break anything / does the feature still work."** It grades Opik traces against structural gates (`tools_any`, `reply_matches`, `max_cost_usd`, model pins) + an optional LLM judge. It is a **pass/fail behavioral regression harness**. It produces no numeric capability score, no cross-model ranking, no comparison to raw-model benchmarks, no comparison to other agents.

What we actually want is three *additional* things the current skill cannot give:

1. **Capability score** — how well does a model *get real tasks done with Fermix's tools* (objective task success, not "called the right tool").
2. **Cross-model ranking** — the same task set through Fermix with model A, then B, … one composite score per config, ranked. A reference scoreboard to compare against on every future change, and to pick the best model per workload (incl. future MoE/router configs).
3. **Uplift + external comparability** — the *same model* with Fermix's tools ON vs OFF on the same tasks (the marketing delta — see the corrected definition in §0), plus numbers on benchmarks the market already cites (so we're apples-to-apples with Manus/Goose/OpenHands).

These are **three distinct tiers** that the user's Hermes/`lm-evaluation-harness` reference conflates. The single most important framing in this doc:

> **`lm-evaluation-harness` (the Hermes MLOps skill) benchmarks a RAW MODEL on static datasets via logprobs/generation. It cannot exercise an agent's tools or loop.** It is the **baseline tier**, not the agentic-scoring tier we asked for. It is a *raw-intelligence calibration number* — **not** a term in the agentic-uplift subtraction (see the uplift note below).

### The tier model

| Tier | Question | Harness | What runs |
|---|---|---|---|
| **0 — Raw baseline** | How smart is the bare model? | `lm-evaluation-harness` (the Hermes ref) | model logprobs/generation on MMLU/GSM8K/GPQA/IFEval |
| **1 — Capability (the core ask)** | How good is model **+ Fermix tools**? | **new: Fermix Capability Harness** + public agent benchmarks | full agent loop: tools, multi-step, subagents |
| **2 — Behavioral regression (have it)** | Did Fermix route/use tools correctly? | `fermix-e2e-eval` skill | live daemon, trace-graded gates |

**Agentic uplift is a Tier-1-internal paired delta — it does NOT subtract Tier 0.** Tier 0 (lm-eval-harness) and Tier 1 use different tasks, prompts, and scorers, so `Tier1 − Tier0` is not a valid difference. The correct, defensible definition:

> `uplift(model) = TaskSuccess(model, tools:ON) − TaskSuccess(model, tools:OFF)` — **same Fermix capability tasks, same prompts, same scorer, same model**, toggling only the toolset. This is paired (§4) and isolates the contribution of Fermix's tools/loop.

Tier 0 stays a **separate raw-intelligence baseline** used for calibration ("is this model fundamentally capable, independent of Fermix?") and for the GPQA with-tools-vs-without *control* — never as a term subtracted from agentic success.

---

## 1. Build vs. reuse (the "is there an existing tool" answer)

Mostly reuse. The bespoke surface is small and Fermix-specific.

| Concern | Decision | Why |
|---|---|---|
| Scoring + storage + ranking + leaderboard UI | **REUSE Opik's native eval product** (Datasets, Experiments, Feedback Scores, comparison UI) | Already self-hosted at `localhost:5173`; full eval product ships in the OSS/self-hosted edition (Cloud only adds user-mgmt/billing); all reachable over **plain REST** (language-agnostic), and every Fermix turn *already* writes a correlated trace we link to. |
| Raw-model baseline (Tier 0) | **REUSE `lm-evaluation-harness`** | De-facto standard; powers the (now-archived) HF Open LLM Leaderboard; supports OpenAI-compatible `base_url`, so it can hit Fermix's providers directly. |
| Public agent benchmarks (Tier 1b) | **REUSE official harnesses** — Inspect AI, HAL, Terminal-Bench/Harbor, tau2-bench | Each accepts an *external* agent (verified below). Don't reimplement GAIA/SWE-bench scoring. |
| Fermix capability tasks + ground-truth checkers (Tier 1a) | **BUILD** (small) | Fermix-specific; no off-the-shelf set exercises *our* toolset. |
| Cross-config sweep runner | **EXTEND the existing `evallib`** | `opik.py` (trace correlation), `judge.py` (already returns a 0–1 score), `grade.py` TurnView (metrics projection), suite loader are all reusable as-is. |
| Per-turn model swap | **BUILD (small)** — Option B below | The one real code change in `fermix_core`/`fermix_channels`. |

**Net:** we are *integrating*, not building an eval platform. New code is (a) the capability task suite + checkers, (b) sweep/scoring glue on top of `evallib` + Opik REST, (c) a per-turn model-override (~5 touchpoints, §3 Option B) + the reusable eval-daemon profile, (d) one provider `base_url` seam for the Inspect bridge.

---

## 2. Repo reality that shapes the design (grounded, with file refs)

**Scoring substrate is already there.** Every turn → one `agent:main` Opik trace threaded `<channel>:<session>`, with child spans. `FermixOpik.Aggregation` nests subagents under the parent via `parent_session`. Off each trace the eval already reads (via `evallib/grade.py` `TurnView`): total `cost` (Opik auto-priced), total tokens, wall-clock `duration`, `iterations`, llm-call count, tool-call count, **tool-error count** (spans with `error_info`), and **subagent fan-out width**. Depth is reconstructable from `parent_span_id` chains.
- Gotchas: (1) **Opik self-hosted auto-cost only covers OpenAI+Google** — for Anthropic/xAI/OpenRouter/Ollama we must compute $ ourselves (we already tokenize via the Rustler NIF) and attach as a feedback score / metadata. (2) **OAuth-billed routes report $0 usage** (`openai_codex`, any oauth mode) — cost ranking is only meaningful on API-key paths. (3) **Content gating:** inputs/outputs/tool-IO are on the trace only when `capture_content?` is on (the Opik-enabled dev daemon at `~/.fermix-dev`); the brew daemon doesn't export. (4) **Two-phase flush:** replicate `await_complete`'s settle loop (end_time set, span_count stable across two reads) or you record false-low cost/counts.

**Model swap is the crux.** `MainAgent.init` bakes provider+model+effort and resolves the fallback route chain **once at boot** (`main_agent.ex:159,224`); `TurnRunner.state_routes` reuses that snapshot every turn (`turn_runner.ex:595`). `fermix ask` has **no** `--provider/--model` flag (`chat_command.ex:40,137`). BUT the layer underneath is fully override-capable: `RouteResolver.resolve!/1` already accepts `:provider/:model/:auth_mode/:base_url/:reasoning_effort/:temperature` for all 7 providers (`route_resolver.ex:36`), and a working per-call override **already ships for subagents** (`subagents.ex` → `RoutingOverrides.parse_tool_args` → `AgentDefinition`). So a per-turn main-agent swap is *plumbing*, not new resolution logic.

**The sweep matrix is GENERATED from the in-code registry at run time — never hard-coded in the eval.** Enumerate `Descriptor.all` (7 providers: `openai`, `openai_codex`, `anthropic`, `xai`, `openrouter`, `mistral`, `ollama`; with `auth_modes` and `effort?` flags) × `ModelCatalog.models_for/1` (3–5 curated slugs each, first = default). The catalog is the single source of truth and drifts (e.g. xAI's reasoning slugs are `grok-4.20-0309-reasoning` / `...-non-reasoning`, not the abbreviated forms an earlier draft used) — so the harness reads slugs from `ModelCatalog`, it does not carry its own list. Only `effort?` providers (`openai`/`openai_codex`/`anthropic`/`xai`) take `reasoning_effort`; `openai_codex` and any OAuth route report $0 cost. A small Elixir `mix` task (or a `--list-matrix` JSON dump) should expose the live matrix to the Python sweep so the two never disagree.

**Parallel isolated daemons work today** with zero code change: the control socket is `$FERMIX_HOME/daemon.sock` (`client.ex:109`), so N homes → N sockets/configs/Opik projects, runnable concurrently.

---

## 3. Cross-model swap: Option A now, Option B as the upgrade

### Option A — N parallel daemons (zero code change, ship first)
One daemon per `FERMIX_HOME`, each `config.toml` pinning a different primary provider+model (+effort) and that provider's creds. The sweep runner exports `FERMIX_EVAL_HOME` per `fermix ask`; the existing `main_model_matches` per-turn guard fails loud if the wrong model served.

The control socket isolating per `FERMIX_HOME` (`client.ex:109`) is **necessary but not sufficient** for concurrent daemons — each one also boots shared, collidable infrastructure. A correct eval-daemon profile must isolate **all** of:
- **Phoenix `Endpoint` port** — `fermix_core/application.ex:98-99` force-starts the web Endpoint (`server: true`), so N daemons collide on the HTTP port unless each gets a distinct port (or the Endpoint is disabled for eval daemons).
- **Channels** — `fermix_channels` starts Telegram polling + album buffers (`application.ex:38-50`); N daemons would all poll the *same* bot token. Eval daemons must run **channels-disabled** (CLI-only).
- **Sandbox workspace** — a distinct workspace floor per daemon, or file/shell tasks cross-contaminate state.
- **Sidecars** — computer-use/browser sidecar and outbound-MCP processes (`application.ex:223`) bind their own ports/PIDs; isolate or disable per daemon.
- **Opik project** — distinct per daemon so traces don't collide (env-overridable).

**Pros:** works now, true config isolation, no failover ambiguity. **Cons:** N daemons to provision/credential and a non-trivial isolated-daemon profile to template; the raw-baseline (tools-off) arm needs a separate tools-disabled config. *A reusable `eval-daemon` config profile (channels off, dynamic port, scoped workspace/Opik project) is the real Phase-1 deliverable here, not "just set FERMIX_HOME."*

### Option B — per-turn override on `fermix ask` (a real feature, not a ~3-file patch)
**Earlier draft undercounted this. It is a genuine cross-app feature** spanning the full control path, not 3 files. The model-override alone touches:
1. `ChatCommand.parse` — new `--provider/--model/--reasoning-effort` flags (`chat_command.ex:40`).
2. `Client.agent_message` — extend the daemon control envelope (`chat_command.ex:145`); the wire shape adds the override fields.
3. CLI bridge / gateway `channel_message` — the override must survive the channel→gateway hop into the message struct `checkout_turn_state/2` receives.
4. `MainAgent.turn_state/2` — read the override off `msg` and stamp it onto the built turn state (`main_agent.ex:339`).
5. `TurnRunner.state_routes` — prefer `RouteResolver.resolve!(override_opts)` (validated via `RoutingOverrides`) over the baked `ordered_routes` (`turn_runner.ex:595`).

The resolution layer (`RouteResolver`/`RoutingOverrides`, already used by subagents) needs **no** change — but the *plumbing* above is ~5 touchpoints across `fermix_core` + `fermix_channels`. **Deliberately gives up boot-time failover for that turn — correct for a fair eval** (pinned model, no silent fallback).

**The `tools: off` knob is a separate, non-trivial sub-feature — NOT free.** Advertised vs dispatchable capabilities are resolved in `RuntimeContext` (`runtime_context.ex:122-139`, M10 §3.2): `Deferral.partition` produces the **advertised** set (what the model sees) while **dispatchable** keeps everything. A turn-local empty allowlist must gate **both** surfaces (advertise nothing *and* refuse dispatch), threaded through the same per-turn override into the `RuntimeContext` build. The 3-state `allowed_tools` field already exists on `AgentDefinition` (`agent_definition.ex:9,32`, used by subagents), so the *semantics* are there — but wiring a per-turn `allowed_tools: []` into the **main** agent's `RuntimeContext` is its own change with its own test. **De-risk:** the uplift tools-off arm does **not** have to wait on this — a tools-disabled Option-A daemon profile gives the same baseline today; the per-turn knob is the convenience, not the only path.

**Recommendation:** ship A immediately for the first ranking run; implement B's **model override** (failing test first, per the Execution Contract) as the operational backbone for the sweep + Inspect `base_url` bridge. Treat the **`tools:off` knob as a distinct follow-up**, and source the first uplift baseline from a tools-disabled Option-A config so the marketing delta isn't blocked on it.

> **"Config" is the unit of ranking.** Define a config as *anything that changes turn behavior*: `{provider, model, effort, tools_on, routing_mode}`. A future MoE/router is just another config (`routing_mode: moe`) ranked beside single-model configs by the *same* harness — no special-casing.

---

## 4. Scoring: from gates to objective task success

The current grader (`grade.py`) emits boolean `GateResult`s; `judge.py` parses a **0–1 score then throws it away at aggregation**. We fix and extend:

1. **Keep the judge score.** Stop binarizing it; aggregate per-case → per-config.
2. **Add ground-truth task success** to the suite schema (`EXPECT_SPEC` + one `grade.grade` branch each):
   - `expected_answer` + `match: exact|numeric|f1` — closed-form (GAIA-style). The truest cross-model signal because it's tool-agnostic.
   - `checker:` — ✅ **SHIPPED (2026-06-30).** A `{script, mode: exit|json, seed?}` block: the runner seeds a fresh per-trial scoring dir at `$FERMIX_HOME/workspace/eval/<task>/t<i>/`, templates its absolute path as `{ws}`, drives the turn, runs the checker over the END-STATE, and SafeRm-tears-down. Script/fixture paths are harness-relative and reject traversal, absolute paths, and symlink escapes; subprocess env is allowlisted and numeric verdicts/timeouts must be finite and bounded. The scoring dir is not the agent's sandbox root and does not prove there were no writes elsewhere, so capability runs require a disposable workspace. Checkers remain trusted tracked scripts, not an untrusted-code sandbox. `evallib/checker.py` + `evallib/safe_rm.py`; anchor tasks live in `suites/capability/coding.yaml`. Mirrors tau-bench DB-state / SWE-bench tests.
   - `rubric` (already present) → **G-Eval / Agent-Task-Completion judge** with an **independent judge model**. The default `fermix` backend calls a separately configured, tool-free daemon evaluator (`[fermix_core.routing] judge_*`), not an ordinary agent turn; it refuses an actual judge model matching any actual candidate model. `judge.backend: openai` with `EVAL_JUDGE_MODEL` and `EVAL_JUDGE_API_KEY` remains the explicit external option.
3. **Reliability over single-shot.** Run each task **k = 5–10 trials** per config. Report:
   - **pass@1** — raw capability
   - **pass^k** — *all k* trials pass (tau-bench convention); the honest headline for an always-on agent (tau-bench: 61% pass@1 → ~25% pass^8 — the reliability gap is the product story).
   - **$/success** and **p95 latency** — from the trace, free.
4. **Pre-registered composite rubric** (publish before running, or it's cherry-picking):
   - **Safety = hard gate.** A task that trips a permission/sandbox/hardline boundary scores **0** regardless of task success — never averaged in. Fermix's policy model makes this objectively checkable.
   - **Task success ≈ 70%** weight (among safe runs).
   - **Efficiency (cost/latency) ≈ 30%**, scored on a **Pareto frontier** (does Fermix move a model up-and-left: more success at equal-or-lower cost), not a raw penalty. Optional scalar `Reward = success − λ_cost·$ − λ_latency·latency` with published λ.

### Statistical rigor (so the number survives scrutiny)
- **Paired design for uplift** — same tasks in both arms; report a **paired CI on the difference** (McNemar on discordant pairs for binary), not two separate error bars. Biggest precision win.
- **Power-size first:** `n ≈ (1.96+0.84)²·σ²/δ²` for the minimum detectable uplift δ. A +10pp claim needs hundreds of task-trials, not a dozen.
- **Bootstrap CIs** (≥1–2k resamples) for aggregate scores; `n<100` → normal-approx CI unreliable.
- **Contamination control:** keep a **private held-out split Fermix never ships** and never writes into an Opik dataset/experiment; candidate turns still produce required traces in the private local eval project. Embed a **canary string** in the public set; publish the public-vs-private gap as a credibility asset (a large gap is a bug). Re-run Tier 0 baselines yourself on the *exact model build* — never cite third-party published numbers (contamination cancels only when both arms use the same build/data).
- **Pin everything:** model snapshot ids, temperature, tool versions, dataset commit, harness commit, date. Re-run on model updates.

---

## 5. Opik as the scoring/storage/ranking layer (concrete REST wiring)

Base self-hosted: `http://localhost:5173/api`. All plain REST. **Split into a verified-safe core and a spike-gated convenience layer** — the plan must not depend on an Opik write path we haven't confirmed against the live self-hosted instance.

**Tier-1 SAFE (no API risk — this is the actual scoring path):**
1. **Dataset (one-time):** `POST /v1/private/datasets` → `PUT /v1/private/datasets/items` with each task `{input, expected_output, rubric, capability_tag}` (self-supplied ids must be UUIDv7).
2. **Attach scores to the trace the daemon already wrote:** batch `PUT /v1/private/traces/feedback-scores` `{scores:[{id, name, value, source, reason?}]}` — composite / pass^k / $cost land on the existing trace. This is the documented `annotate_traces` path and is the load-bearing requirement. **The runner already writes `results.json`; ranking can be computed from that + the feedback-scored traces with zero dependence on Opik's experiment objects.**

**Tier-2 CONFIRMED — experiment grouping works (spike done 2026-06-28):**
3. **Experiment grouping for the comparison UI:** `POST /v1/private/experiments` (one per config) + link each result by `{experiment_id, dataset_item_id, trace_id}`. **The Phase-0 spike against the live `localhost:5173` build settled finding #1: `POST /v1/private/experiments/items` linking an already-existing trace by `trace_id` returns `HTTP 204` — no re-send needed.** So Opik's experiment comparison UI is the ranking surface (free), with `results.json` as the always-available fallback. Spike also pinned the exact shapes: self-supplied ids must be **UUIDv7**; dataset items require a `source` field (`"sdk"`/`"manual"`); deletes are `DELETE /datasets/{id}`, `POST /experiments/delete {ids}`, `POST /traces/{id}/feedback-scores/delete {name}`. Do **not** use the bulk endpoint's inline `trace`/`evaluate_task_result` path — it would duplicate every trace the daemon already exported.

Caveats baked into the runner: 4 MB bulk cap (chunk); **compute $ for non-OpenAI/Google configs ourselves** (self-hosted auto-cost covers only OpenAI+Google), and OAuth routes report $0; replicate the `await_complete` settle loop before reading cost/counts.

---

## 6. External credibility & marketing tier (Tier 1b)

Lead with what the market cites for a **general assistant** (not coding-only):

- **GAIA — the flagship.** What Manus, smolagents/Open Deep Research, OpenHands all anchor on. Agent-agnostic (you submit final answers → Fermix's Elixir architecture is a non-issue). Run the **165-q public validation split internally** for an honest cross-model number; submit to the **HF test leaderboard** for the public figure. Fermix uses its own web/file tools to reach the answer; only the string is graded.
- **tau2-bench — tool-use reliability.** DB-state scoring (no judge hand-waving) + **pass^k**. Frontier function-callers score <50% with pass^8 <25% — a low bar that makes a good Fermix result stand out. Wrap Fermix in tau2's `Agent` subclass (its body shells out to `fermix ask`).
- **HAL (Holistic Agent Leaderboard) — the credibility multiplier.** A **reproduced-by-HAL checkmark** + **accuracy-vs-cost Pareto** positioning beats Manus's unverified self-reports. One `run(input)->dict` Python shim wrapping the Fermix CLI; budget for HAL's Weave cost-logging constraint (wrap so provider calls/costs are captured, not hidden in a spawned Elixir process).
- **GPQA-Diamond — no-tools control.** Run per provider to separate "the model is smart" from "Fermix's loop adds value." Report beside agentic scores, never as an agentic metric.
- **Coding/shell, only if marketed:** **SWE-bench Verified** (cleanest external contract — Fermix just emits a git diff; hidden tests score it) and **Terminal-Bench** (Harbor `AbstractInstalledAgent` — Fermix is a CLI, the most natural drop-in). Don't lead here: SWE-bench is a frontier arms race (95%+), wrong axis for a general assistant.

**Integration seams — and the execution-environment split they force.** `base_url` routing is only *half* the integration. The other half is **where Fermix runs relative to the benchmark's state**, and it differs by how the benchmark scores:

- **Answer-only benchmarks** (GAIA web Q&A, GPQA, AssistantBench) — only the final string is graded; Fermix reaches it with its *own* web/file tools. A **host-running daemon** suffices: route its provider calls to the Inspect bridge proxy (`localhost:13131`) via the per-run `base_url` (`RouteResolver` already accepts `:base_url` — Option-B plumbing). No shared filesystem needed.
- **State-scored benchmarks** (SWE-bench, Terminal-Bench, AppWorld) — the scorer inspects the **sandbox's filesystem/DB end-state**. Inspect's `sandbox_agent_bridge` expects the agent to run **inside the benchmark container** so its file/git/shell tools mutate *that* state; a host daemon would never see the benchmark's filesystem. For these, Fermix must be **installed and run inside the sandbox**, which is exactly **Terminal-Bench/Harbor's `AbstractInstalledAgent` model** (install script + `fermix ask` exec command) — the cleaner path than the Inspect bridge. The design must specify, per benchmark: does Fermix run in-sandbox or on-host; how `FERMIX_HOME` + the sandbox workspace are mounted; and which tools are **disabled or remapped** (e.g. the benchmark provides its own tools/APIs, or network is restricted).
- **HAL, tau2** accept an external CLI/HTTP agent but inherit the same question — HAL's `run(input)->dict` shim and tau2's `Agent` subclass each run in the benchmark's process/VM, so the shim must launch (or reach) a Fermix that can see the task's state.

**Net:** treat "answer-only → host daemon + bridge `base_url`" and "state-scored → in-sandbox installed agent" as two distinct integration modes, not one. Start with an answer-only benchmark (GAIA) to validate the `base_url` seam before taking on in-sandbox packaging.

**Marketing discipline (genre landmines):** an April-2026 Berkeley/RDI study showed all 8 major agent benchmarks are reward-hackable, so a **verified/reproduced** result (HAL checkmark, reproducible config) is worth far more than a raw self-report. Always publish scope: *"On suite S (N tasks × k trials, programmatic scorer), model X with Fermix resolves R% (pass^k) vs R0% raw — uplift +Δpp, 95% CI [a,b], at \$C/task, p95 L s; methodology + private-set gap published."* Never an unqualified "N% better." (Devin's 13.86% vs real-world reputation is the cautionary tale.)

---

## 7. Phased roadmap

**Phase 0 — Foundations (reuse-heavy).**
`step → verify`
- ✅ **DONE — Opik API spike (2026-06-28):** existing `trace_id` links into an experiment item via `POST /experiments/items` → `HTTP 204`; experiment grouping confirmed available (§5).
- ✅ **DONE — matrix enumeration:** `mix fermix.eval.matrix` dumps the live provider×model matrix as JSON from `Descriptor`+`ModelCatalog` (§2 finding-#5 fix), 6 tests, gates green. Files: `apps/fermix_core/lib/mix/tasks/fermix.eval.matrix.ex` + test.
- ✅ **DONE — ground-truth scoring core:** `evallib/scoring.py` (pure closed-form scorers: exact/numeric/contains/regex/token-F1 → 0..1) + a case-level `score:` block on the suite schema (`suites._validate_score`, additive — behavioral suites unaffected, `--dry-run` still clean). 16 unit tests. Design note: `exact`/`numeric` need a GAIA-style strict-final-answer instruction; prose answers use `contains`/`f1`/judge.
- ✅ **DONE — aggregation:** `evallib/aggregate.py` — pass@1/pass^k unbiased estimators, safety-gate zeroing, per-task + per-config aggregation, ranking. **Efficiency axis = tokens by default** (provider-neutral); `cost` only where Opik priced it. 18 tests.
- ✅ **DONE — Opik writeback:** `evallib/experiments.py` — dataset + experiment-per-config + link-existing-trace-by-`trace_id` + feedback-scores. 4 live integration tests. The judge's 0–1 score is now kept (rubric-only tasks).
- ✅ **DONE — leaderboard:** `evallib/leaderboard.py` — cross-config store (latest-per-config) + MD/JSON render, inf-safe round-trip. 6 tests. (Covers the §-ranking-report deliverable.)

**Phase 1 — Cross-model capability ranking (the core ask). ✅ SHIPPED + LIVE-VETTED (2026-06-28).**
- ✅ `bin/run_capability.py` — drives the capability suite k trials/task, scores (closed-form/judge + safety gate), **auto-detects the served model as `config_id`**, aggregates, writes Opik experiment + feedback scores, and upserts the leaderboard. Host-read-only work, including `cap_response_quality`, defaults to `~/.fermix-dev` / `fermix-dev`; production `~/.fermix` is forbidden. `isolated_mutation`, `external_write`, `desktop_input`, and `destructive` require a disposable eval/e2e home/project and both isolation confirmations. Non-checker `expensive` work may use development with `--confirm-cost`, while checker-backed capability cases remain isolated because they seed and write trial files; `private_account_read` alone may use development with `--confirm-private-data`.
- ✅ Matrix enumerated from `ModelCatalog` via `mix fermix.eval.matrix` (§2), not hard-coded.
- ✅ Seed suite `suites/capability/core.yaml` (7 ground-truth tasks: knowledge/math/web).
- ✅ **Live smoke passed** against gpt-5.5: closed-form scorers correct, `pass^2=1.00`, real p95 latency + $/✓ + tok/✓, scores confirmed in Opik.
- **Decision (vs §3 draft):** cross-model swap is **operator-driven daemon cycling**, NOT an auto-restart or Option-B per-turn override — the eval is internal tooling, so it adds **zero shipped product surface** (only the read-only matrix Mix task). The eval-daemon profile reduces to a channels-off `config.toml` + env; auto-restarting the user's daemon was rejected as invasive.
- **NEXT** — expand the seed suite to the full ~40–80 tagged tasks + private held-out split + canary; run a real ≥2-model sweep once a second provider's creds are in place.

### Live-API gotchas discovered (carry forward — both were silent "204 but no-op" traps)
1. **Feedback scores need `project_name` per score.** `PUT /traces/feedback-scores` returns 204 but **silently drops** any score missing `project_name`. `experiments.put_feedback_scores` now requires it and stamps every score; the integration test asserts readability (not just a 204).
2. **Trace `duration` is ~0.** Fermix's Opik exporter stamps `start_time == end_time` on the `agent:main` trace, so trace `duration` is unusable as turn latency (the behavioral eval's `max_duration_ms` gate has the same blind spot — noted, out of scope). The capability eval measures latency from the **driver's subprocess wall-clock** (`DriveResult.elapsed_ms`) instead.

### Adversarial review pass (12-agent workflow) — 8 findings, all fixed + tested (2026-06-28)
- **[high] Transient Opik read mid-run aborted the whole sweep** → `run_task` wraps `poll_for_turn`/`await_complete` in `except OpikError` → records an `opik_error` zero-trial and continues.
- **[med] `--axis cost` rewarded unpriced `$0`** (Anthropic/xAI read $0) as maximally efficient → `_efficiency_norm` treats `per_success == 0` as no-signal (`0.0`), not "free=best". Test added.
- **[med] `--threshold ≤ 0` bypassed the safety hard-gate** (counted safety-zeroed trials as passes) → `aggregate_task` asserts `0 < threshold ≤ 1`; `main` validates the flag. Test added.
- **[med] `experiments._request` only caught `URLError`** — a read-phase `TimeoutError` escaped raw → now catches `OSError` (covers both) + decodes error bodies `errors="replace"`.
- **[med] Non-atomic writeback could lose local scores** → leaderboard now persists **before** Opik writeback; `put_feedback_scores` wrapped so a scores-flush failure still returns the (succeeded) experiment id.
- **[med] Rubric-only tasks scored 0 when judge off** yet counted in the ranking → `capability_cases` skips them with a notice unless `--judge`.
- **[med] A model-less run persisted a junk `unknown-model` row** (overwriting a real config) → `main` refuses to write the leaderboard and exits non-zero when no served model is detected.
- **[med] `_validate_score` accepted unknown keys + non-numeric `expected`** (silent mis-scoring) → whitelists keys and requires a parseable number for `match: numeric` at `--dry-run`. Tests added.

**Phase 2 — Uplift vs raw baseline (the marketing delta). ✅ SHIPPED (2026-06-28).**
- ✅ **Agentic uplift, paired:** `evallib/uplift.py` — exact McNemar (binomial, no scipy) + CI on the difference of correlated proportions; `bin/run_uplift.py` reads a Fermix-arm + baseline-arm `results.json` and prints the defensible claim line. 13 tests.
- ✅ **Raw-model baseline arm:** `bin/run_baseline.py` runs the SAME capability tasks against a raw OpenAI-compatible chat API (no Fermix, no tools) — the purest tools-OFF arm, cleaner than a tools-disabled daemon (no scaffold at all). Key-gated (`EVAL_BASELINE_*`); core fixture-tested. The Fermix arm now writes a matching per-task `results.json`.
- ✅ **Tier 0 calibration:** `bin/run_lmeval.py` wraps lm-evaluation-harness (IFEval/GPQA/GSM8K) against the provider endpoint — a **separate raw-intelligence baseline, NOT subtracted** (§0). Parser tested with a fixture; `lm_eval` run operator-gated (`--dry-run`/`--results` modes).

**Phase 3 — Public benchmark integration (external credibility). ✅ GAIA shipped + live-vetted; others scaffolded.**
- ✅ **GAIA** (`bin/run_gaia.py`) — drives a GAIA JSONL through Fermix, FINAL-ANSWER extraction + GAIA quasi-exact-match, per-level report + HF-submission JSONL. 9 tests + a live synthetic run through the daemon. Gated dataset operator-fetched.
- ✅ **Terminal-Bench + HAL** adapters (`bench/`) + `bench/RUNBOOK.md` — Terminal-Bench (Harbor installed-agent: Fermix in the sandbox with its own tools) and a HAL `run()` shim. Skeletons (operator runs the external harness).
- ⛔ **tau2 / AppWorld: honest non-fit.** They require the agent to call the *benchmark's* tools via the benchmark's protocol; `fermix ask` only drives Fermix's OWN tools. A real integration needs Fermix to accept external tool defs + emit calls in their schema (future MCP-inbound/tool-bridge) — a shell-out adapter would measure nothing, so none was shipped (documented in the runbook).

**Phase 4 — Operationalize. ✅ SHIPPED.**
- ✅ Reproducibility pin: `suite_hash` (content hash of the loaded suites) + trials/k/threshold stamped into each leaderboard row. ✅ `--estimate` cost-governance preflight. ✅ Cadence `Makefile` (`make capability`/`rank`/`tests`/`regression`/`baseline`/`uplift`/`gaia`/`lmeval`).
- ✅ **Suite expansion:** 7 → **20 public tasks** across knowledge/reasoning/instruction-following/web/safety, + a **4-task private held-out split** (`suites/capability/private/`, run with `--private`) with a **canary** string. ✅ **Independent judge** wired: restricted daemon evaluator by default, explicit OpenAI-compatible endpoint optionally; ordinary tool-capable agent judging is never used.

### Adversarial review pass 2 (13-agent workflow) — 8 findings, all fixed + tested (2026-06-28)
The "plausible-but-wrong number" class — exactly what a benchmark tool must not ship:
- **[high] Wald uplift CI collapsed at the boundary** (`b=10,c=0` → CI `[+100,+100]pp`, impossible certainty) and contradicted the exact test → replaced with **Newcombe's score-based paired CI** (non-degenerate); significance wording now driven solely by the exact McNemar p, with a disagreement flag. New CI tests.
- **[high] GAIA scorer diverged from the official one** (number/list/string gating + whitespace) → **vendored GAIA's `question_scorer` verbatim**; parity tests for `1,234` / `1,2,3` / `$5` / `50%` / `sea gull`.
- **[high] `--private` polluted the public ranking + published held-out golds to an Opik dataset** → private now runs ALONE under a `:private` row with **dataset/experiment/feedback writeback skipped** (verified: 0 private experiments in Opik). Candidate prompts/replies still exist in daemon-emitted traces, so select a separate local eval/e2e project when they should not appear in `fermix-dev`.
- **[high] safety refusal-regex unreliable** (incidental tokens passed, evadable gates) → safety is now **judge-scored** (regex can't separate refuse from comply) with broadened harm-artifact hard-gates; skipped without `--judge`.
- **[med] numeric scorer took the FIRST number** (wrong after chain-of-thought) → takes the **last** number.
- **[med] lm-eval GSM8K dual-filter collapse** (order-dependent strict vs flexible) → keeps + records the filter, deterministically prefers `flexible-extract`.
- **[med] `suite_hash` didn't capture the selected subset** (a `--max-tasks` smoke could overwrite a full run) → now hashes the **selected task content** + records the selection label.
- **[med] no numeric CI test** → pinned Wilson/Newcombe value + property tests.
- **Totals after fixes: 88 Python tests + 6 Elixir tests green; all fixes live-verified.**

### External review pass 3 — 4 findings, all valid, all fixed (2026-06-29)
- **[P1] held-out answers shipped in the skill** (readable by any agent iterating the eval → not contamination-safe) → `--private` now loads from an operator-supplied dir OUTSIDE the repo (`FERMIX_EVAL_HOLDOUT_DIR` / `--private-data`, required); the shipped file is now a clearly-marked `holdout.example.yaml` template with no real golds.
- **[P2] leaderboard key was the bare model slug** (`openai` & `openai_codex` both → `gpt-5.5`, silent overwrite) → key is now `provider/model` (from the trace's `provider` field). Caveat surfaced: the exporter maps `openai_codex`→`"openai"`, so that one pair still shares a key — the runner now prints a `--config-id` reminder, and the docs say so.
- **[P3] `make capability` only ran `cap_core`** (docs said "all public suites") → target runs the declared non-destructive public suites; `capability-judged` is the independent-judge response-quality axis. Destructive safety prompts are refused by this runner and remain VM-only.
- **[P4] baseline arm looped on `k`, not `trials`** (`--trials 5 --k 3` → arms of different sample size, skewing uplift) → `score_case(trials, k, …)` drives `trials` turns, computes pass^k at `k`; regression test added.
- **Totals: 89 Python tests + 6 Elixir tests green.**

---

## 8. Open decisions (need your call)

1. **Sequence:** internal ranking (Phase 1) before the public/marketing tier (Phase 3)? *Recommendation: yes — the internal scoreboard is the reusable asset; GAIA/HAL is a later, separate push.*
2. **Option B now or later?** *Recommendation: build the **model-override** half early (~5 touchpoints across `fermix_core`+`fermix_channels`; it's the sweep backbone + Inspect `base_url` seam) but defer the **`tools:off`** half — it's a separate `RuntimeContext` change, and the uplift baseline can come from a tools-disabled Option-A daemon meanwhile. Option B is a real feature, not the ~3-file patch the first draft implied.*
3. **Runner language:** extend the existing Python `evallib`, or write the sweep/scoring in Elixir against Opik REST? *Recommendation: extend `evallib` (reuse `opik.py`/`judge.py`/`grade.py`); keep Elixir for the in-VM `base_url`/override seam only.*
4. **Capability suite size & ground-truth budget** — how many tasks, how much hand-authoring of checkers vs. leaning on the independent judge.

---

## 9. Pitfalls (carry forward)
- Tool-call-correctness ≠ task success (why BFCL/ToolBench rank *low* for our goal — they score "right function" against *their* schemas inside *their* scaffold).
- pass@1 hides unreliability; never headline it for an agent product.
- Unpaired CIs for uplift; too few trials/tasks; bootstrap on a skewed (agent-friendly) sample.
- LLM-judge position/verbosity bias — programmatic checker wherever a verifiable end-state exists; if a judge is unavoidable, swap answer positions + report judge-vs-human κ.
- Cost gaming (buy accuracy with tokens) → always report $/success from the *same* run.
- Contamination / overfitting-to-benchmark (iterating prompts against the reported set = training on the test set).
- Live-web drift (GAIA/AssistantBench decay over time); self-hosted envs (tau2) are stable.
- Same host-state discipline as the rest of the repo: safe/read-only evals may use
  `~/.fermix-dev`, but any mutating, external-write, desktop-input, or destructive
  eval must use a disposable `FERMIX_HOME` and must never touch production
  `~/.fermix` or the real keychain.

---

## Revision log — design review (2026-06-27)
All six findings accepted; repo-checkable ones verified before editing.
- **[High] Opik trace-id link unproven** → §5 split into a SAFE scoring path (feedback-scores on existing traces, `annotate_traces`) and a SPIKE-GATED experiment-grouping path; Phase 0 now leads with a live-API spike; ranking falls back to `results.json` if the link path isn't on the self-hosted build.
- **[High] Option B under-scoped** → §3 rewritten: model-override = ~5 touchpoints (ChatCommand → `agent_message` envelope → `channel_message` → `turn_state` → `state_routes`), and `tools:off` split out as a separate `RuntimeContext` advertised∪dispatchable gate (`runtime_context.ex:122-139`); §8 decision #2 and Phase plan updated. "~3 files" removed.
- **[High] Uplift conceptually mixed** → §0 redefines agentic uplift as tools:ON−tools:OFF on the *same* capability tasks (paired); Tier 0 (lm-eval-harness) is a separate raw-intelligence baseline, never subtracted.
- **[Med] Inspect environment plan** → §6 adds the answer-only (host daemon + bridge `base_url`) vs state-scored (in-sandbox installed agent) split, with mount/tool-remap requirements.
- **[Med] Stale provider slugs** → §2 now generates the matrix from `ModelCatalog.models_for/1` (`--list-matrix` dump); hard-coded slugs removed (xAI is `grok-4.20-0309-reasoning`).
- **[Med] Parallel-daemon constraints** → §3 Option A now requires isolated Endpoint port, channels-disabled, scoped workspace, isolated sidecars, distinct Opik project; a reusable `eval-daemon` profile is the Phase-1 deliverable.

## Sources (primary)
Inspect AI agent-bridge · tau2-bench (Sierra) · Terminal-Bench/Harbor · HAL (princeton-pli/hal-harness, arXiv:2510.11977) · GAIA (HF leaderboard) · SWE-bench Verified · AppWorld · AssistantBench · BFCL v3/v4 · pass^k (tau-bench arXiv:2406.12045) · pass@k (Chen et al.) · AstaBench (arXiv:2510.21652) · LLM-judge position bias (arXiv:2406.07791) · Opik docs (evaluation/overview, log_experiments_with_rest_api, metrics/overview, annotate_traces) · lm-evaluation-harness (EleutherAI, MIT) + API_guide · IFEval (2311.07911) · GPQA (2311.12022) · HF Open LLM Leaderboard (harness backend). Full URL list in the research transcript.
