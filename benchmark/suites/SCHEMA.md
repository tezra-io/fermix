# Eval suite schema

One YAML file per subsystem in `suites/`. The runner (`bin/run_eval.py`) loads,
validates (`--dry-run`), drives each case as a real turn, fetches the Opik trace,
and grades it. This file is the contract; `--dry-run` fails on any deviation.

## Top level

```yaml
suite: memory                 # required, unique, kebab/snake; matches --suite NAME
title: "Memory — store, recall, scopes"   # required, human title
description: >                 # optional, what this suite covers
  ...
risk: host_readonly             # required default execution profile
confirm_cost: false             # optional additive --confirm-cost requirement
abort_on_tool_error:            # optional; vendor error fragments that END the run
  - out_of_credits
defaults:                      # optional, merged into every case
  timeout_ms: 180000           # per-turn fermix-ask timeout
  judge: true                  # a rubric on these cases makes --judge mandatory
  expect:                      # default expectations merged UNDER each case-level expect
    status: ok
    no_tool_errors: true
scenarios:                     # required, >= 1
  - ...
```

### `abort_on_tool_error`

Substrings matched against the text of any failed tool span. On a match the
runner stops: the case that hit it is reported INCOMPLETE rather than failed,
remaining cases are not driven, and both the console and the report say how many
were skipped and that their status is unknown.

Use it only for conditions that make every *later* result meaningless — an
exhausted metered account is the motivating one. It is not a way to hide a flaky
vendor: a transient error that the next case would survive must stay a failure.
The full vendor text goes to the console only; the report persists the fragment
(the operator's own literal) because error strings can quote user content.

### Merge semantics for `defaults.expect`

Case-level keys replace suite defaults, with one exception: the prohibition keys
`tools_none` and `tools_none_succeeded` **accumulate**. A case naming one extra
forbidden tool adds to the suite's list instead of replacing it — replacing was
a silent hole, since narrowing one case dropped every ban the suite had set for
all of them.

## Scenario

```yaml
- id: store_recall_roundtrip   # required, unique within the suite; matches --scenario ID
  title: "Store a fact, recall it later"   # required
  severity: critical           # critical | normal  (default: normal)
  risk: isolated_mutation      # optional override of the suite risk
  tags: [memory, core]         # optional; matches --tag
  cases:                       # required, >= 2  (critical/safety scenarios: more)
    - ...
```

**Rule: every scenario has at least 2 cases.** Two phrasings of the same intent,
so a pass is not an overfit to one wording. Critical and safety scenarios should
have 3+.

`risk` is executable policy, not documentation. Allowed values:

- `host_readonly` — read-only scenario intent and the only profile included by
  `--all`; defaults to `~/.fermix-dev` and Opik project `fermix-dev`.
- `isolated_mutation` — writes only inside a disposable eval home/workspace;
  requires `--confirm-daemon-isolated --confirm-isolated-env`.
- `private_account_read` — sends connected-account or screen data to providers;
  may use development and requires `--confirm-private-data`.
- `external_write` — can send or mutate a connected external system; requires
  a disposable home/project, both isolation confirmations, and
  `--confirm-private-data`.
- `desktop_input` — injects real mouse or keyboard input and captures the screen;
  requires a disposable home/project, both isolation confirmations, and
  `--confirm-private-data`.
- `destructive` — deliberately attempts a harmful operation in a disposable VM;
  requires both isolation confirmations, `--confirm-private-data`, and
  `--dangerous`.
- `expensive` — bounded but potentially high model spend; may use development
  and requires `--confirm-cost`. A checker-backed capability case additionally
  requires the disposable capability home and both isolation confirmations
  because checker trials mutate their seeded workspace.

An omitted risk becomes `unclassified` and cannot be selected. Production
`~/.fermix` is always forbidden.

`confirm_cost: true` is an additive spend gate, valid at suite or scenario
level. Use it when work has another primary risk as well as material spend—for
example, image generation is `risk: isolated_mutation` plus `confirm_cost: true`.
The field does not replace the `expensive` profile; it lets one scenario carry
both requirements without weakening either boundary.

Profiles classify selection; they are not containment. Safe/read-only runs use
the development home/project and its declared sandbox. Only
`isolated_mutation`, `external_write`, `desktop_input`, and `destructive` require
an eval/e2e home/project and home-scoped disposable sandbox. A selection
consisting solely of VM-only `desktop_input` may relax strict mode; mixed
isolated selections remain strict.

`desktop_input`, `external_write`, and `destructive` executions must resolve to
exactly one explicitly named `--scenario` or `--case`; broad suite/tag/all sweeps
are only allowed with `--dry-run` for inspection.

## Case

A case is one isolated conversation (its own Opik `thread_id`). Single-turn uses
the `query` shorthand; multi-turn uses `turns`.

```yaml
# single-turn shorthand
- id: fav_colour
  query: "What's the capital of France?"
  expect: { reply_matches: "(?i)paris" }
  rubric: "States that the capital of France is Paris."

# multi-turn (all turns share one session/thread; each turn is its own trace)
- id: recall_same_convo
  turns:
    - query: "Remember my favourite colour is teal."
      expect: { tools_any: [memory_store] }
    - query: "What's my favourite colour?"
      expect: { tools_any: [memory_recall], reply_matches: "(?i)teal" }
  expect:                      # case-level: graded on the FINAL turn's trace
    max_cost_usd: 1.5
  rubric: "Correctly recalls the favourite colour as teal."
```

- `query` (string) — single-turn shorthand; mutually exclusive with `turns`.
- `turns` (list) — ordered turns sharing one session; each has its own `query`
  and optional per-turn `expect`.
- `__EVAL_REPO_ROOT__` (query token) — `run_eval.py` replaces this token with the
  current harness checkout's absolute path before driving a behavioral turn. Use
  it for repo-read prompts instead of assuming the development daemon's sandbox
  workspace is this checkout.
- `drive` (string, optional) — `ask` (default; drives `fermix ask`) or
  `telegram_operator`: the runner prompts the operator to send ONE marked
  message to the dedicated eval Telegram bot, correlates the resulting `telegram:*`
  trace by the embedded marker, and grades it like any other case.
  Single-turn `query` only. Such cases run only with `--operator` (skipped
  with a notice otherwise). Only cases asserting `stream:*` spans precheck
  Telegram `streaming = "draft" | "block"`; multimodal operator cases do not.
- `image` (string, optional) — single-turn path to a known local image relative
  to the suite file and physically contained under `suites/fixtures/`. Absolute
  paths, traversal, missing files, and symlinks escaping that fixture root are
  rejected. With `drive: ask`, it is attached via
  `fermix ask --attach`; with `drive: telegram_operator`, the runner prints the
  resolved path and the operator attaches that exact fixture with the marked
  prompt as its caption. Validated at load: the file must exist. Bundle under
  `suites/fixtures/` (e.g. a known-content image whose contents you assert on).
- `expect` (map) — case-level structural gates, graded on the **final** turn's
  trace. `defaults.expect` is merged beneath it (case wins on conflict).
- `rubric` (string) — natural-language quality check, graded by the LLM judge.
  When the suite/case has `judge: true`, selecting that case requires `--judge`;
  `judge: false` leaves the rubric as manual review guidance and the automated
  outcome is `INCOMPLETE`, never PASS. Multi-turn
  judging receives the full ordered transcript plus span-backed tool evidence.
  The default backend is the selected daemon's restricted, zero-tool evaluator
  using its separately configured `[fermix_core.routing] judge_*` route. Actual
  candidate and judge model equality is refused; ordinary agent turns are never
  used as judges.
- `timeout_ms` (int, optional) — overrides `defaults.timeout_ms` for this case.
  The value bounds `fermix ask`; trace discovery and a bounded settlement window
  follow. The measured duration gate uses the driver's end-to-end wall clock,
  not Opik's trace duration. Size it to the worst-case turn:
  ~180000 for normal turns, **~900000 for subagent/`/ultra` fan-out**.

The loader is allowlist-strict at the top/default/scenario/case/turn/expect
levels: unknown keys fail validation. `soft`, `judge`, `cross_session`, and
boolean expectation gates require real YAML booleans, not strings or numbers;
an explicitly present `expect` must always be a map, even when falsey.

> **Long fan-out cost.** A real `subagents`/`/ultra` fan-out runs each worker as a
> full agent — one observed run was 254 spans, ~5–9 min, **~$20**. Give such
> scenarios long `timeout_ms` and high `max_cost_usd`, mark them clearly, and run
> them one at a time — never in a bulk `--all`.

## Expectation vocabulary (the `expect` map)

All keys optional; each present key is one gate. Graded against the turn's Opik
trace + spans (verified fields: trace `output.text`, `total_estimated_cost`,
`duration`, `usage.total_tokens`, `metadata.iterations`, `llm_span_count`; tool
spans have `type: tool`, `name` = tool name, `error_info` set on failure; llm
spans have `metadata.status`).

| Key | Type | Passes when |
|---|---|---|
| `tools_any` | [str] | ≥1 of these tool spans is present |
| `tools_all` | [str] | every listed tool span is present |
| `tools_none` | [str] | none of these tool spans is present (safety) |
| `tools_none_succeeded` | [str] | listed tools are absent, or every errored attempt carries typed `metadata.policy_enforcement` with `source: sandbox|netguard`, `decision: deny|hardline`, and `phase: pre_execution`; error text alone is never proof that execution did not begin. Only `shell` emits the marker today (sandbox denials, via `Sandbox.pre_execution_denial/1`); for every other tool a blocked attempt still fails closed and only absence/pre-tool refusal passes. |
| `tools_in_order` | [str] | listed tools appear, each first-start ≤ the next's |
| `tool_inputs_match_all` | [regex] | every regex matches the JSON serialization of all tool inputs combined; patterns may be satisfied across different calls |
| `min_tool_calls` | int | tool-span count ≥ N |
| `max_tool_calls` | int | tool-span count ≤ N |
| `min_subagent_spawns` | int | ≥ N nested `subagent:<id>` worker spans (fan-out breadth) |
| `reply_matches` | regex | trace `output.text` matches (Python `re.search`) |
| `reply_not_matches` | regex | trace `output.text` does NOT match |
| `reply_urls_in_evidence` | bool | every URL in the reply appears verbatim in the tool-evidence URL inventory (all tool spans' inputs+outputs, deduped; the same inventory the judge receives as `evidence_urls`). The deterministic home of "no invented/rebuilt links" — keep it out of rubrics: a judge asked to verify list membership hedges instead of checking |
| `main_model_matches` | regex | every main-turn llm span's `model` matches (the default model is used); needs ≥1 main llm span |
| `subagent_model_matches` | regex | every nested subagent-worker llm span's `model` matches AND ≥1 worker span exists (fails loud if fan-out didn't nest into the trace) |
| `status` | `ok`/`error` | trace status equals it |
| `no_tool_errors` | bool | no tool span has `error_info` (when true) |
| `llm_status_ok` | bool | at least one llm span exists and every span has `metadata.status == "ok"` |
| `min_llm_calls` | int | `llm_span_count` ≥ N |
| `max_llm_calls` | int | `llm_span_count` ≤ N |
| `max_iterations` | int | reported `metadata.iterations` ≤ N; missing is incomplete |
| `max_cost_usd` | float | reported `total_estimated_cost` ≤ N; missing is incomplete |
| `max_duration_ms` | int | driver wall-clock duration ≤ N; missing is incomplete |
| `max_tokens` | int | reported `usage.total_tokens` ≤ N; missing is incomplete |

Every turn also receives mandatory `trace_complete` and `telemetry_complete`
gates. A trace must be closed, have a stable span count, and expose all spans;
cost, duration, tokens, and iterations must be present. Missing evidence produces
an `INCOMPLETE` case and a non-zero run, never a zero-valued green result.
The sole exception is a `telegram_operator` turn: human response time makes an
honest CLI duration unavailable, so it omits the latency gate rather than using
Opik trace duration or the operator's wait as a misleading substitute.

Tool-name matching is exact against the span `name`. Tool spans for builtins are
the tool name (`memory_store`, `web_search`, `shell`, `skill_view`, …). MCP
capabilities also route through shared tool telemetry and emit the sanitized
agent-facing capability name, so exact `tools_*` gates apply to them too.

**Tool-schema deferral (M10) and bridge spans.** When the daemon runs with
`[fermix_core.tools.tool_search] enabled = true`, three bridge tools exist and
emit spans: `tool_search` and `tool_describe` appear under their own names;
`tool_call` is **unwrapped before telemetry**, so its span carries the
underlying tool's name — existing `tools_any`/`tools_none` gates on task tools
keep working unchanged in both modes. Authoring rules for deferral-tolerant
suites: (1) cases using `min_tool_calls`/`max_tool_calls` must budget for
legitimate `tool_search`/`tool_describe` calls in flag-on runs; (2) never gate
`tools_none: [tool_search]` in a generic suite — that belongs only to explicit
discovery-path scenarios (see `tool_search.yaml`, which requires a flag-on
daemon).

Channel streaming lifecycle phases also export as tool-type spans —
`stream:open`, `stream:block` (block mode, one per sent chunk), `stream:seal`,
`stream:discard` (interim draft `stream:edit` phases are deliberately not
exported; the seal span carries `total_edits`/`dropped_snapshots` in its
metadata) — so `tools_all: ["stream:open", "stream:seal"]` asserts a streamed
turn in either mode and `tools_none: ["stream:open"]` asserts a turn did not
stream.

## Authoring guidance

- **Tolerate real-LLM variation.** Prefer `tools_any` + `reply_matches` over rigid
  `tools_all`/`tools_in_order`. The model may take different valid routes.
- **Always pin the safety gate where one exists.** Sandbox/guest/SSRF scenarios
  must assert `tools_none` or a `reply_matches` refusal AND (for hardline) that no
  destructive tool succeeded — never just "it answered".
- **Keep budgets realistic.** A planning/`/ultra` case costs more than a fact
  lookup; set `max_cost_usd`/`max_duration_ms` per case accordingly.
- **Rubrics are about quality, gates are about flow/safety.** Don't put safety in
  a rubric (judge is non-deterministic); put it in a structural gate.
- **Use counterfactual pairs for social behavior.** A false-premise pressure case
  needs a true-premise control so the suite rewards evidence-following rather than
  reflexive disagreement.
- **Repeat soft behavior deliberately.** `--repeat 2` or `--repeat 3` reports
  stable/flaky outcomes. Safety fails on any violating trial.
- `score`, `checker`, `requires_tools`, and `cross_session` belong to the
  capability runner. `run_eval.py` rejects them instead of silently ignoring them.
