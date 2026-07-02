# Fermix E2E Eval (Opik trace-based)

This skill grades the **real** assistant: it sends realistic queries through the
live agent path, then evaluates the **Opik trace** each query produced. It is the
live-LLM behavioral tier that complements the deterministic in-process ExUnit
suite (`docs/design/E2E_TEST_PLAN.md`). Nothing here stubs the model.

## How it works (one query → one verdict)

```
YAML case  ──►  fermix ask --json --session <unique>   (FERMIX_HOME=~/.fermix-dev)
                     │  real turn in the Opik-enabled dev daemon
                     ▼
              Opik (localhost:5173)  ──►  trace + spans for that thread_id
                     ▼
        grade: structural gates (tools/order/errors/cost/latency/reply)
             + optional LLM judge (rubric)  ──►  MD / HTML / JSON report
```

Correlation is exact: each case gets a unique `--session`, which becomes the Opik
`thread_id` (`<channel>:<session>`). The runner polls Opik for that thread's trace.

## Capability eval & cross-model ranking (`run_capability.py`)

A second tier, distinct from the behavioral suites above. The behavioral runner
asks *"did the agent use the right tools / stay in budget"* (pass/fail gates); the
capability runner asks *"how good is the model at getting tasks done with Fermix's
tools"* — an objective **task-success score**, ranked across models.

```sh
# Score the model the dev daemon currently serves (auto-detected from the trace):
uv run bin/run_capability.py --trials 5                   # all public capability suites
uv run bin/run_capability.py --suite cap_web_research --trials 3  # one suite
uv run bin/run_capability.py --estimate --trials 5        # turn-count/cost plan, no spend
uv run bin/run_capability.py --private --trials 5         # + the held-out split (gap check)
uv run bin/run_capability.py --rank-only                  # re-render the leaderboard
uv run bin/run_capability.py --check                      # preconditions only
```

A cadence `Makefile` wraps these (`make capability`, `make rank`, `make tests`, …);
external public benchmarks (GAIA / Terminal-Bench / HAL / lm-eval) have their own
runbook at `bench/RUNBOOK.md`. Phase 2 uplift: `bin/run_baseline.py` (raw arm) +
`bin/run_uplift.py` (paired McNemar delta vs the Fermix arm).

How it scores (see `docs/design/EVAL_CAPABILITY_SCORING.md`):
- **Ground-truth tasks** live in `suites/capability/*.yaml` (knowledge, reasoning,
  instruction-following, web, safety) — each case carries a `score:` block
  (`match: exact|numeric|contains|regex|f1`, `expected`, optional `tolerance`)
  graded by `evallib/scoring.py`. Closed-form tasks must instruct a strict final
  answer (`exact`/`numeric` compare the whole reply; regexes are single-quoted in
  YAML so backslashes survive). The private held-out split is **operator-supplied
  OUTSIDE the repo** (`FERMIX_EVAL_HOLDOUT_DIR` / `--private-data`, run with
  `--private`) — answers are never shipped in the skill (they'd be readable by any
  agent iterating the eval); see `suites/capability/private/holdout.example.yaml`.
- Rubric-only tasks use the LLM judge with `--judge`. **For a FAIR cross-model
  ranking, the judge must be independent of the model under test** — set
  `EVAL_JUDGE_BACKEND=openai` + `EVAL_JUDGE_API_KEY` (the default `fermix` backend
  judges via the daemon = circular; the runner warns).
- Each task runs **k trials**; results aggregate to **pass@1** (capability),
  **pass^k** (reliability — all k pass), **tokens/✓** and **$/✓** (efficiency),
  **p95 latency**, with **safety as a hard gate** (a `tools_none`/`reply_not_matches`
  violation zeroes the task). `evallib/aggregate.py`.
- Per run, results write to an **Opik experiment** (one per config, linked to the
  existing traces by `trace_id`) + **feedback scores** on the traces, and upsert
  into a cross-config **leaderboard** (`reports/capability/leaderboard.json`),
  ranked by composite = 0.7·success + 0.3·efficiency (axis: `tokens` default,
  provider-neutral; `cost` only where Opik priced the trace — OpenAI/Google).

**Cross-MODEL sweep (operator-driven — we never restart your daemon):** point the
dev daemon at the next provider+model in `~/.fermix-dev/config.toml`, restart it,
run `run_capability.py` again. Each run auto-detects the served model and adds a
leaderboard row; the board re-ranks. The matrix of rankable configs comes from
`mix fermix.eval.matrix` (provider×model, generated from the live catalog).

## Preconditions (check these first, fail loud if missing)

1. **Opik up**: `curl -s -m5 http://localhost:5173/api/v1/private/projects` returns JSON.
2. **Opik-enabled dev daemon up**: the daemon at `~/.fermix-dev` must be running
   **with `FERMIX_OPIK_ENABLED=1`** (the brew daemon at `~/.fermix` does NOT export).
   Verify: `FERMIX_HOME=~/.fermix-dev fermix status --json` is reachable (not `not_running`).
   If it is down, tell the user to start it; do not silently fall back to `~/.fermix`.
3. **uv installed** (`brew install uv`, or the Astral installer). The runner is a
   self-contained `uv run` script — its only dependency (PyYAML) is declared inline
   (PEP 723) and fetched/cached on first run. No venv to set up.

The runner's `--check` does 1+2+3 for you and prints exactly what's missing.

## Running

Run from the skill dir via `uv run` (or `./bin/run_eval.py` directly — its shebang
invokes uv). The first run auto-fetches PyYAML:

```sh
cd benchmark
uv run bin/run_eval.py --check              # verify preconditions only

# Validate suites without spending tokens (no daemon calls):
uv run bin/run_eval.py --dry-run

# Run one suite (structural gates only — no LLM-judge cost):
uv run bin/run_eval.py --suite memory

# Run specific scenarios, with the LLM judge on:
uv run bin/run_eval.py --suite memory --scenario store_recall_roundtrip --judge

# Run everything (expensive — every case is a real gpt-5.x turn):
uv run bin/run_eval.py --all
```

Key flags: `--suite NAME` (repeatable), `--scenario ID` (repeatable),
`--tag TAG`, `--all`, `--judge` (enable rubric grading), `--dry-run`
(validate + plan only), `--check` (preconditions only), `--max-cases N`
(cap spend), `--out DIR`, `--purge` (delete this skill's own eval traces),
`--operator` (include operator-assisted cases — see below).

## Streaming suite (partly operator-assisted)

`--suite streaming` verifies channel draft streaming (docs/design/CHANNEL_STREAMING.md):

- **`cli_never_streams`** runs fully automated like any suite: `fermix ask`
  turns must produce **no** `stream:*` spans (the CLI sync path never streams,
  by design).
- **`telegram_draft_stream`** needs a human: real Telegram inbound cannot be
  synthesized (real Bot API, polling transport), so with `--operator` the
  runner prints ONE message for you to send to the dev bot from your phone
  (it embeds a unique `(eval:e2e-mark-…)` marker), then finds the resulting
  `telegram:*` trace by that marker and grades it automatically:
  `stream:open` + `stream:seal` spans present, no `stream:discard`.
  Without `--operator` these cases are skipped with a notice.

Preconditions for the operator cases (the runner prechecks the config half):
the dev daemon binary includes the streaming feature,
`[fermix_channels.telegram] streaming = "draft"` is set in
`~/.fermix-dev/config.toml`, and the daemon was **restarted** after enabling.

```sh
uv run bin/run_eval.py --suite streaming                       # automated tier only
uv run bin/run_eval.py --suite streaming --operator            # + the Telegram cases
uv run bin/run_eval.py --suite streaming --tag safety          # just the CLI-negative gate
```

Note: operator-case traces live on your real `telegram:*` thread — `--purge`
never touches them (it only deletes `e2e-*` threads).

## Provider parity suite (one daemon, one provider, cycle to compare)

`suites/provider_parity.yaml` is a single behavioural battery — it runs the same
seven scenarios (plain reasoning, web_search tool use, a local shell call, a
parallel-subagent fan-out, a memory store→recall round-trip, strict
instruction-following, harmful-request refusal) against **whatever provider the dev
daemon currently serves as primary**, so behaviour can be compared task-for-task.
(It replaces the seven byte-identical `provider_*` suites that differed only by a
model-slug pin and failed six-at-a-time under `--all`.)

There is **no per-call provider override**: `fermix ask` has no `--provider` /
`--model` flag, and the daemon serves the single provider in its config. So the
matrix is run by **cycling the daemon**, one provider at a time — exactly like the
capability sweep:

1. Set the primary provider + model in `~/.fermix-dev/config.toml`.
2. Restart the dev daemon (`FERMIX_HOME=~/.fermix-dev`).
3. Run the parity suite: `uv run bin/run_eval.py --suite provider_parity`.
4. Repeat for the next provider.

**No model-slug pin.** The suite deliberately drops the old
`defaults.expect.main_model_matches` pin: only one provider is active per daemon,
the harness already auto-detects the served model, and pinning here only produced
seven copies that failed six-at-a-time. To assert a specific daemon's model (e.g.
to catch an OpenRouter failover leaking a direct slug), add a case- or
scenario-level `main_model_matches` override for that run.

**Daemon preconditions for full coverage** (else those scenarios fail *uniformly*
across providers — a daemon gap, not a provider difference): shell enabled with a
sandbox workspace, and a working `web_search` backend. The memory round-trip gates
on the **reply** (the CLI eval path emits no `memory_store` span — see
`memory.yaml`), not on a tool span.

**Severity / safety note.** The `harmful_request_refusal` scenario is
`severity: normal` here on purpose: it is a parity *comparison* of refusal
behaviour, not the safety gate of record (`safety.yaml` stays `critical`). Its
real safety signal is the per-case `reply_not_matches` harm-artifact gate (did the
model actually emit the bomb recipe / phishing email / keylogger?); the
refusal-phrasing `reply_matches` is broad but softer, so it does not flip a parity
run's exit code on phrasing alone.

**Cost.** Seven providers × six scenarios is a large matrix — run providers
selectively and use `--max-cases` to bound spend. Note OAuth-billed routes
(`openai_codex`, and any OAuth-mode provider) report `$0.00` to the trace, so
`max_cost_usd` gates pass *vacuously* there — they bound the API-key paths only.

## Keeping Opik tidy

The skill drives the **shared** dev daemon, whose Opik project also collects your
real Telegram/CLI usage, scheduled jobs, and any `mix test` runs that had Opik
enabled. The skill itself only adds: the suite case turns (thread `cli:e2e-…`) and,
with `--judge`, one judge turn per case (`cli:e2e-judge-…`). To manage the clutter:

- **See only eval traces:** in the Opik UI, filter by thread_id `contains e2e-`.
- **Quieter judge:** the default `fermix` judge runs through the daemon (so judge
  turns show in Opik). Set `judge.backend: openai` (with `EVAL_JUDGE_API_KEY`) or
  `none` in `config.yaml` to keep judging off the daemon entirely.
- **Purge the skill's traces:** `uv run bin/run_eval.py --purge` deletes only the
  `e2e-*` threads it created — never your Telegram/job/test traces.
- **Test pollution is hard-gated off:** `FermixOpik.enabled?/0` returns `false`
  under `:test` regardless of `FERMIX_OPIK_ENABLED`, so `mix test` no longer
  exports fixture telemetry even with the flag exported in your shell — you don't
  need to unset it. (Pre-`8bc080f` you did; the flag alone used to switch the
  sibling `fermix_opik` app on during the umbrella test run.)

## generate_image suite (config-gated, spends image credits)

`--suite generate_image` exercises the `generate_image` builtin (create + edit)
against the OpenAI image backend. Two preconditions, both fail loud rather than
silently mis-grade:

1. The dev daemon must have the backend enabled —
   `[fermix_core.tools.generate_image]` with `backend = "openai"` — or the tool
   is not registered and the two labeled route-sanity scenarios fail their
   `tools_any: [generate_image]` gate (the "wrong daemon" signal).
2. The CLI channel has **no media reply port**: every successful generation is
   rendered and written under the sandbox `media/` floor, then delivery fails
   with `media_unsupported` — so the `generate_image` tool span carries
   `error_info`. That tool error is **expected** (same as the `media` /
   send_attachment suite), so these cases do not assert `no_tool_errors`; they
   gate on the turn completing and an honest reply (no fabricated delivery).

Image generation is modeled as a provider call with `tokens: %{}` (zero trace
cost), but each case still spends real OpenAI image credits for the picture it
renders before delivery fails. Run it explicitly, not in a blind `--all`:
`uv run bin/run_eval.py --suite generate_image`.

## Cost & latency (warn the user before `--all`)

The dev daemon runs `gpt-5.x` at high effort: **~$0.2–0.6 and ~15–45 s per turn**.
A full run is dozens of turns → tens of dollars and many minutes. Default to a
single `--suite` or `--scenario`. Use `--max-cases` to bound spend. The runner
prints an estimated turn count before driving anything and honors per-case
`max_cost_usd` / `max_duration_ms` budgets as gates.

## After a run

- Reports land in `reports/<UTC-timestamp>/` → `report.md`, `report.html`, `results.json`.
- Surface the MD summary to the user; offer the HTML for the full view.
- Each case row links to its Opik trace (`http://localhost:5173/.../traces/<id>`).
- Exit code is non-zero if any **critical** scenario failed a structural gate.

## Authoring / editing suites

Suites live in `suites/*.yaml`, one per subsystem. Schema + the full expectation
vocabulary are in `suites/SCHEMA.md`. Rules: every scenario has **≥2 cases**
(critical/safety scenarios have more); structural gates must tolerate real-LLM
variation (prefer `tools_any` / `reply_matches` over exact sequences); always pin
a safety gate where one applies (`tools_none`, hardline-not-executed, etc.).
`--dry-run` validates every suite against the schema.
