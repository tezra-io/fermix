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
              Opik project fermix-dev  ──►  trace + spans for that thread_id
                     ▼
        grade: structural gates (tools/order/errors/cost/latency/reply)
             + required judge for judged rubrics  ──►  MD / HTML / JSON report
```

Correlation is exact: each case gets a unique `--session`, which becomes the Opik
`thread_id` (`<channel>:<session>`). The runner polls Opik for that thread's trace.

## Capability eval & cross-model ranking (`run_capability.py`)

A second tier, distinct from the behavioral suites above. The behavioral runner
asks *"did the agent use the right tools / stay in budget"* (pass/fail gates); the
capability runner asks *"how good is the model at getting tasks done with Fermix's
tools"* — an objective **task-success score**, ranked across models.

```sh
# Judge response quality on the development daemon (auto-detected from the trace):
uv run bin/run_capability.py --suite cap_response_quality --trials 5 --judge

# Full public sweep includes isolated-mutation and expensive tasks:
FERMIX_EVAL_HOME=~/.fermix-capability-eval \
  OPIK_PROJECT=fermix-capability-eval \
  uv run bin/run_capability.py --trials 5 --confirm-daemon-isolated \
  --confirm-isolated-env --confirm-cost
uv run bin/run_capability.py --estimate --trials 5        # turn-count/cost plan, no spend
uv run bin/run_capability.py --private --trials 5
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
  `--private` skips Opik dataset/experiment/feedback writeback, but candidate
  prompts and replies still enter the configured trace store because trace evidence
  is the scoring source. Choose a separate local eval/e2e project when the
  held-out material should not appear in `fermix-dev`.
- Rubric-only tasks use an **independent external LLM judge** with `--judge` —
  the OpenAI API, called directly by the harness (no daemon or core involvement).
  Set `judge.backend: openai` and `judge.model` in **this benchmark's config**
  (`config.yaml` / `behavioral_config.yaml`); the model must differ from the
  candidate (the harness refuses a match). The call authenticates with
  `EVAL_JUDGE_API_KEY`, which the `make` judged targets resolve from the same
  OpenAI key the daemon uses (macOS keychain `fermix:OPENAI_API_KEY`) — export it
  to override, or `EVAL_JUDGE_BASE_URL` / `EVAL_JUDGE_MODEL` to point elsewhere.
  Because it's a different provider from the daemon's candidate model, it is a
  genuinely independent oracle. The judge scores only prose; structural gates
  remain the hard safety/flow signal.
- Each task runs **k trials**; results aggregate to **pass@1** (capability),
  **pass^k** (reliability — all k pass), **tokens/✓** and **$/✓** (efficiency),
  **p95 latency**, with **safety as a hard gate** (a `tools_none`/`reply_not_matches`
  violation zeroes the task). `evallib/aggregate.py`.
- Per run, results write to an **Opik experiment** (one per config, linked to the
  existing traces by `trace_id`) + **feedback scores** on the traces, and upsert
  into a cross-config **leaderboard** (`reports/capability/leaderboard.json`),
  ranked by composite = 0.7·success + 0.3·efficiency (axis: `tokens` default,
  provider-neutral; `cost` only where Opik priced the trace — OpenAI/Google).

**Cross-MODEL sweep (operator-driven — the runner never restarts the daemon):**
point the isolated capability daemon at the next provider+model in
`~/.fermix-capability-eval/config.toml`, restart it with the safe launch flags,
run `run_capability.py` again. Each run auto-detects the served model and adds a
leaderboard row; the board re-ranks. The matrix of rankable configs comes from
`mix fermix.eval.matrix` (provider×model, generated from the live catalog).

## Preconditions (check these first, fail loud if missing)

1. **Opik up**: `curl -s -m5 http://localhost:5173/api/v1/private/projects` returns JSON.
2. **Opik-enabled development daemon up**: safe/read-only behavioral runs and the
   response-quality capability suite default to `~/.fermix-dev` and Opik project
   `fermix-dev`. The production home `~/.fermix` is always rejected.
3. **Judge key for judged runs**: set `judge.backend: openai` + `judge.model` in
   the benchmark config; the external judge authenticates with `EVAL_JUDGE_API_KEY`,
   which the `make` judged targets resolve from the daemon's configured OpenAI key
   (keychain `fermix:OPENAI_API_KEY`). The judge model must differ from the candidate.
4. **uv installed** (`brew install uv`, or the Astral installer). The runner is a
   self-contained `uv run` script — its only dependency (PyYAML) is declared inline
   (PEP 723) and fetched/cached on first run. No venv to set up.

The runner's `--check` verifies connectivity and the configured home, project,
and sandbox declaration; add `--judge` to preflight the restricted judge route
without making a model call. Safe/read-only runs need no isolation attestation.

Only `isolated_mutation`, `external_write`, `desktop_input`, and `destructive`
profiles require a disposable eval/e2e home and project plus both
`--confirm-daemon-isolated` and `--confirm-isolated-env`. Conventional pairs are
`~/.fermix-eval` / `fermix-eval` for behavioral runs and
`~/.fermix-capability-eval` / `fermix-capability-eval` for capability runs. The
disposable daemon must have no unrelated channels or realtime, use a headless
browser, and keep a strict sandbox below its home. The flags attest that the
already-running daemon was restarted with that setup; they are not proof or
containment.

A disposable behavioral daemon's config must include a boundary like this,
alongside a separately configured provider:

```toml
[sandbox]
mode = "strict"
workspace_root = "/absolute/path/to/.fermix-eval/workspace"
allowed_roots = []
```

Use a sanitized disposable local clone/snapshot there, with its own `.git` for git
scenarios; overlay the current change, but copy no `.env`, credentials, normal
Fermix homes, or build caches. The runner requires the disposable workspace
`HEAD` to match the harness checkout and records both; dirty overlay content is
operator-attested, not byte-compared. Then start with no channel configured — the
channels app must stay up because it owns the CLI-ask turn queue
(`FermixChannels.Gateway.Queue`, so `--no-channels` would break every turn), but
with no bot token in this fresh home no adapter actually polls:

```sh
FERMIX_HOME=~/.fermix-eval FERMIX_OPIK_ENABLED=1 \
FERMIX_OPIK_PROJECT=fermix-eval FERMIX_BROWSER_HEADLESS=1 \
mix fermix.dev --no-realtime
```

Operator-assisted Telegram cases need a live bot: configure only a dedicated eval
bot in this fresh home, keep `--no-realtime`, and stop it after the named operator
run. Never reuse a personal or production bot. Multimodal cases need the dedicated
bot but not streaming; only the streaming suite requires Telegram
`streaming = "draft"` or `"block"`.

## Running

Run from the skill dir via `uv run` (or `./bin/run_eval.py` directly — its shebang
invokes uv). The first run auto-fetches PyYAML:

```sh
cd benchmark
uv run bin/run_eval.py --check              # verify preconditions only

# Validate and plan the recommended core without spending tokens or daemon calls:
uv run bin/run_eval.py --tag host-safe-core --judge --dry-run

# Run one host-read-only behavioral suite on ~/.fermix-dev:
uv run bin/run_eval.py --suite conversation --judge

# Run specific scenarios, with the LLM judge on:
uv run bin/run_eval.py --suite chief_of_staff \
  --scenario briefing_reprioritization --judge

# Every scenario in the host-read-only profile (higher risks stay excluded):
uv run bin/run_eval.py --all --judge

# Recommended change-by-change regression and bounded qualitative repetition:
uv run bin/run_eval.py --tag host-safe-core --judge
uv run bin/run_eval.py --suite epistemic_integrity --judge --repeat 3
```

Key flags: `--suite NAME` (repeatable), `--scenario ID` (repeatable),
`--case ID` (repeatable), `--tag TAG`, `--all` (host-read-only only),
`--profile PROFILE`, `--judge`,
`--repeat 1..3`, `--dry-run`
(validate + plan only), `--check` (preconditions only), `--max-cases N`
(limit driven case trials; not a dollar/spend cap), `--out DIR`,
`--purge-run RUN_ID` (exact-run preview), `--confirm-daemon-isolated` (isolated
profiles only), and
`--operator` (include operator-assisted cases — see below).

Every explicit suite/scenario/case/tag value must match within the selected
profiles; a typo or a selector dropped by another filter is a usage error, never
a silently smaller run. Real `desktop_input`, `external_write`, and `destructive`
runs must resolve to exactly one named scenario or case. Their broader selections
are available only as `--dry-run` plans; destructive execution also requires
private-data consent.

If any planned case has both `judge: true` and a rubric, `--judge` is mandatory;
the runner refuses a structural-only false green. Rubrics on `judge: false`
cases are manual review guidance; without a recorded verdict the case is
`INCOMPLETE`, never PASS.

Behavioral query text may contain `__EVAL_REPO_ROOT__`. Before driving the turn,
`run_eval.py` expands it to the current harness checkout's absolute path. Use the
token for repo-read scenarios so they address this checkout even when the
development daemon's sandbox workspace is elsewhere.

Chief-of-staff action judgment extends beyond the host-safe core. The named
`jobs/clarify_before_scheduling` scenario exposes real isolated job mutation and
requires clarification before scheduling. The named
`subagents/autonomous_delegation_judgment` scenario pairs a broad dossier review
with a tiny direct task without prescribing a route. Its judge evaluates whether
the chosen direct or delegated workflow was proportionate and complete. It is
intentionally non-deterministic and expensive, so use `--repeat 3`,
`--profile expensive`, and `--confirm-cost`. This non-checker behavioral
scenario may use the development daemon.

Every scenario declares `risk: host_readonly | isolated_mutation |
private_account_read | external_write | desktop_input | destructive | expensive`.
Unclassified scenarios cannot run. `isolated_mutation`, `external_write`,
`desktop_input`, and `destructive` require a disposable eval/e2e home/project and
both isolation confirmations. Private reads may use development with
`--confirm-private-data`; non-checker expensive cases may use development with
`--confirm-cost`. Checker-backed capability cases always require the disposable
capability home because their trials seed and write workspace files. Desktop
input and external writes also require
`--confirm-private-data`; destructive cases additionally require
`--confirm-private-data`, `--dangerous`, and a named selection. These flags are
attestations, not containment.

A suite or scenario may add `confirm_cost: true` to another primary risk. The
runner then requires `--confirm-cost` as well; image generation uses this to keep
both its isolation and provider-spend acknowledgements.

## Streaming suite (partly operator-assisted)

`--suite streaming` verifies channel draft streaming (docs/design/CHANNEL_STREAMING.md):

- **`cli_never_streams`** runs fully automated like any suite: `fermix ask`
  turns must produce **no** `stream:*` spans (the CLI sync path never streams,
  by design).
- **`telegram_draft_stream`** needs a human: real Telegram inbound cannot be
  synthesized (real Bot API, polling transport), so with `--operator` the
  runner prints ONE message for you to send to the dedicated eval bot from your phone
  (it embeds a unique `(eval:e2e-mark-…)` marker), then finds the resulting
  `telegram:*` trace by that marker and grades it automatically:
  `stream:open` + `stream:seal` spans present, no `stream:discard`.
  Without `--operator` these cases are skipped with a notice.

Preconditions for the operator cases (the runner prechecks the config half):
the dev daemon binary includes the streaming feature,
`[fermix_channels.telegram] streaming = "draft"` is set in
`~/.fermix-eval/config.toml`, and the daemon was **restarted** after enabling.

```sh
uv run bin/run_eval.py --suite streaming                            # automated tier only
uv run bin/run_eval.py --suite streaming --scenario telegram_draft_stream --operator \
  --profile external_write --confirm-isolated-env \
  --confirm-private-data --confirm-daemon-isolated              # dedicated eval bot only
uv run bin/run_eval.py --suite streaming --tag safety           # just the CLI-negative gate
```

Note: operator-case traces live on your real `telegram:*` thread. Exact-run
purge includes only turns bearing that run's exact `(eval:e2e-mark-<run-id>-…)`
marker; always preview the count before confirming deletion.
Operator turns have no honest CLI wall-clock because a human sends the message;
they grade trace/tool/cost evidence but explicitly omit the latency gate.

## Provider parity suite (one daemon, one provider, cycle to compare)

`suites/provider_parity.yaml` is a single behavioural battery — it runs the same
seven scenarios (plain reasoning, web_search tool use, a local shell call, a
parallel-subagent fan-out, a memory store→recall round-trip, strict
instruction-following, harmful-request refusal) against **whatever provider the
configured daemon currently serves as primary**, so behaviour can be compared
task-for-task.
(It replaces the seven byte-identical `provider_*` suites that differed only by a
model-slug pin and failed six-at-a-time under `--all`.)

There is **no per-call provider override**: `fermix ask` has no `--provider` /
`--model` flag, and the daemon serves the single provider in its config. So the
matrix is run by **cycling the daemon**, one provider at a time — exactly like the
capability sweep:

1. Set the primary provider + model in `~/.fermix-dev/config.toml`.
2. Restart the development daemon (`FERMIX_HOME=~/.fermix-dev`).
3. Run its five host-read-only scenarios:
   `uv run bin/run_eval.py --suite provider_parity --judge`.
   For all seven scenarios, restart a disposable eval/e2e daemon and explicitly
   include and confirm both higher-risk tiers:

   ```sh
   FERMIX_EVAL_HOME=~/.fermix-eval OPIK_PROJECT=fermix-eval \
     uv run bin/run_eval.py --suite provider_parity --judge \
     --profile host_readonly --profile expensive --profile isolated_mutation \
     --confirm-cost --confirm-isolated-env --confirm-daemon-isolated
   ```
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
both the explicit store turn's `memory_store` span and the recalled reply.

**Severity / safety note.** The `harmful_request_refusal` scenario is
`severity: normal` here on purpose: it is a parity *comparison* of refusal
behaviour, not the safety gate of record (`safety.yaml` stays `critical`). Its
real safety signal is the per-case `reply_not_matches` harm-artifact gate (did the
model actually emit the bomb recipe / phishing email / keylogger?); the
refusal-phrasing `reply_matches` is broad but softer, so it does not flip a parity
run's exit code on phrasing alone.

**Cost.** Seven providers × seven scenarios is a large matrix — run providers
selectively and use `--max-cases` to limit driven case trials; it is not a dollar
cap. Note OAuth-billed routes
(`openai_codex`, and any OAuth-mode provider) report `$0.00` to the trace, so
`max_cost_usd` gates pass *vacuously* there — they bound the API-key paths only.

## Keeping Opik tidy

Safe/read-only behavioral runs share the development daemon and `fermix-dev`
project. Unique `e2e-` thread ids keep them filterable from ordinary development
traffic. The four isolated profiles use a dedicated disposable daemon/project.
To manage the traces:

- **See only eval traces:** filter CLI/judge threads by `thread_id contains e2e-`;
  operator turns stay on `telegram:*` and carry the exact run marker in input.
- **Independent judge:** `--judge` calls the OpenAI API directly (no daemon or
  Fermix agent turn), so it is a genuinely independent oracle. The judge model
  must differ from the candidate (the harness refuses a match). Evidence is capped
  at 64 KiB and the returned verdict is byte-bounded; a missing, unknown, or
  truncated completion becomes `INCOMPLETE` rather than a score.
- **Purge one run:** `--purge-run 20260715T151102Z01234567` previews CLI, judge, and
  exact-marked operator turns for that run; add `--confirm-purge` only after
  reviewing the count.
- **Test pollution is hard-gated off:** `FermixOpik.enabled?/0` returns `false`
  under `:test` regardless of `FERMIX_OPIK_ENABLED`, so `mix test` no longer
  exports fixture telemetry even with the flag exported in your shell — you don't
  need to unset it. (Pre-`8bc080f` you did; the flag alone used to switch the
  sibling `fermix_opik` app on during the umbrella test run.)

## generate_image suite (config-gated, spends image credits)

`--suite generate_image` exercises the `generate_image` builtin (create + edit)
against the OpenAI image backend. Two preconditions, both fail loud rather than
silently mis-grade:

1. The disposable eval daemon must have the backend enabled —
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
renders before delivery fails. Each case also writes a media file, so run it
explicitly against the disposable eval home, not in a blind `--all`:

```sh
FERMIX_EVAL_HOME=~/.fermix-eval OPIK_PROJECT=fermix-eval \
  uv run bin/run_eval.py --suite generate_image --profile isolated_mutation \
  --confirm-daemon-isolated --confirm-isolated-env --confirm-cost --judge
```

## Cost & latency

Every driven turn is a real provider call and may be billed; price and latency
depend on the configured provider/model. A host-read-only `--all` may still be
hundreds of turns. Inspect it with `--dry-run`; normally use
`--tag host-safe-core`, a suite, or a scenario. `--max-cases` bounds driven case
trials; skipped operator-only cases do not consume it. It does not bound billed
dollars: judge calls, retries, provider pricing, and unpriced OAuth traces can
change actual spend. Reports label trace totals as candidate trace cost, count
judge calls, include API-reported judge tokens when available, and do not claim
unknown judge cost is included. Per-case cost/duration expectations remain
regression gates.

## After a run

- Reports land in `reports/<UTC-timestamp>/` → `report.md`, `report.html`, `results.json`.
- Surface the MD summary to the user; offer the HTML for the full view.
- Each case row links to its Opik trace (`http://localhost:5173/.../traces/<id>`).
- Results are `PASS`, `FAIL`, or `INCOMPLETE`. Any selected regression fails
  non-zero; missing telemetry/judge evidence, zero cases, or required skips are
  `INCOMPLETE` (exit 4). Opik failures after preflight are preserved as incomplete
  report evidence instead of escaping as a traceback. Report prompts, replies,
  judge rationale, and all error strings are redacted unless `--include-content`.

## Authoring / editing suites

Suites live in `suites/*.yaml`, one per subsystem. Schema + the full expectation
vocabulary are in `suites/SCHEMA.md`. Rules: every scenario has **≥2 cases**
(critical/safety scenarios have more); structural gates must tolerate real-LLM
variation (prefer `tools_any` / `reply_matches` over exact sequences); always pin
a safety gate where one applies (`tools_none`, hardline-not-executed, etc.). Use
`__EVAL_REPO_ROOT__` rather than assuming the daemon workspace is the checkout in
behavioral repo-read prompts.

`--dry-run` validates every suite against the schema.
