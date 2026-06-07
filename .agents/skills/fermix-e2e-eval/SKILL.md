---
name: fermix-e2e-eval
description: >
  Run Fermix end-to-end behavioral evals. Drives realistic user queries into the
  live Opik-enabled Fermix dev daemon (fermix ask → ~/.fermix-dev), pulls each
  resulting trace from the local Opik instance, grades the trace against the
  expected flow declared in YAML suites (structural gates + optional LLM judge),
  and writes Markdown + HTML + JSON reports. Use when asked to "run the e2e eval",
  "run the eval suites", "check the assistant end-to-end", grade behavior against
  Opik traces, or verify a feature still works through the real agent path.
allowed-tools: Bash, Read, Write, Edit
---

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
cd .claude/skills/fermix-e2e-eval
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
- **Stop test pollution:** run `mix test` with `FERMIX_OPIK_ENABLED` unset so test
  fixtures (bench/channel/job tests) don't export to your live project.

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
