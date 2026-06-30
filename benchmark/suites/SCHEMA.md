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
defaults:                      # optional, merged into every case
  timeout_ms: 180000           # per-turn fermix-ask timeout
  judge: true                  # whether cases here are rubric-graded when --judge is on
  expect:                      # default expectations merged UNDER each case-level expect
    status: ok
    no_tool_errors: true
scenarios:                     # required, >= 1
  - ...
```

## Scenario

```yaml
- id: store_recall_roundtrip   # required, unique within the suite; matches --scenario ID
  title: "Store a fact, recall it later"   # required
  severity: critical           # critical | normal  (default: normal)
  tags: [memory, core]         # optional; matches --tag
  cases:                       # required, >= 2  (critical/safety scenarios: more)
    - ...
```

**Rule: every scenario has at least 2 cases.** Two phrasings of the same intent,
so a pass is not an overfit to one wording. Critical and safety scenarios should
have 3+.

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
- `drive` (string, optional) — `ask` (default; drives `fermix ask`) or
  `telegram_operator`: the runner prompts the operator to send ONE marked
  message to the dev Telegram bot, correlates the resulting `telegram:*`
  trace by the embedded marker, and grades it like any other case.
  Single-turn `query` only. Such cases run only with `--operator` (skipped
  with a notice otherwise) and precheck that the dev daemon config has
  `[fermix_channels.telegram] streaming = "draft"`.
- `image` (string, optional) — `drive: ask` only, single-turn: a path to a
  local image (relative to the suite file's directory) attached via
  `fermix ask --attach`. The image rides the same gateway → turn_runner →
  provider-encoder spine a channel image would, so this is the automated
  (no-operator) way to test inbound vision. Validated at load: the file must
  exist (`--dry-run` fails loud otherwise). Bundle fixtures under
  `suites/fixtures/` (e.g. a known-content image whose contents you assert on).
- `expect` (map) — case-level structural gates, graded on the **final** turn's
  trace. `defaults.expect` is merged beneath it (case wins on conflict).
- `rubric` (string) — natural-language quality check, graded by the LLM judge
  (only when `--judge` and the suite/case `judge` is not false).
- `timeout_ms` (int, optional) — overrides `defaults.timeout_ms` for this case. This
  is the **total budget to wait for the trace**, not just the CLI wait. The runner
  caps the synchronous `fermix ask` wait at 300s but keeps polling Opik for the full
  budget, because the daemon finishes a turn server-side even after the CLI socket
  gives up (a subagent fan-out can run 5–9 min). Size it to the worst-case turn:
  ~180000 for normal turns, **~900000 for subagent/`/ultra` fan-out**.

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
| `tools_in_order` | [str] | listed tools appear, each first-start ≤ the next's |
| `min_tool_calls` | int | tool-span count ≥ N |
| `max_tool_calls` | int | tool-span count ≤ N |
| `min_subagent_spawns` | int | ≥ N nested `subagent:<id>` worker spans (fan-out breadth) |
| `reply_matches` | regex | trace `output.text` matches (Python `re.search`) |
| `reply_not_matches` | regex | trace `output.text` does NOT match |
| `main_model_matches` | regex | every main-turn llm span's `model` matches (the default model is used); needs ≥1 main llm span |
| `subagent_model_matches` | regex | every nested subagent-worker llm span's `model` matches AND ≥1 worker span exists (fails loud if fan-out didn't nest into the trace) |
| `status` | `ok`/`error` | trace status equals it |
| `no_tool_errors` | bool | no tool span has `error_info` (when true) |
| `llm_status_ok` | bool | every llm span `metadata.status == "ok"` (when true) |
| `min_llm_calls` | int | `llm_span_count` ≥ N |
| `max_llm_calls` | int | `llm_span_count` ≤ N |
| `max_iterations` | int | `metadata.iterations` ≤ N |
| `max_cost_usd` | float | `total_estimated_cost` ≤ N (falls back to budgets) |
| `max_duration_ms` | int | `duration` ≤ N (falls back to budgets) |
| `max_tokens` | int | `usage.total_tokens` ≤ N |

Tool-name matching is exact against the span `name`. Tool spans for builtins are
the tool name (`memory_store`, `web_search`, `shell`, `skill_view`, …). MCP
(`kind: :mcp`) calls do **not** emit tool spans — don't assert them via `tools_*`.

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
