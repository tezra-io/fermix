# External benchmark runbook (Phase 3 — public credibility)

Operator guide for running Fermix against the public agent benchmarks. These are
the marketing-credible tier (`../docs/EVAL_CAPABILITY_SCORING.md` §6). Unlike
the in-skill `run_capability.py` (which is fully self-contained), each external
benchmark needs its own harness/dataset/credentials — hence this runbook.

**Three states, kept apart** — because presenting a skeleton as an integration is
how a benchmark claim becomes untrue:

- **implemented + validated** — the code runs here and a real run has been graded.
- **implemented** — the code runs here; no external run has been validated yet.
- **skeleton / unavailable** — the file encodes the *integration design*. It does
  not run as written, and the section below says what it still needs.

**Honest fit map** — which benchmarks Fermix actually drops into, and how:

| Benchmark | State | Why |
|---|---|---|
| **GAIA** | ✅ implemented + validated (`bin/run_gaia.py`) | final-answer-only scoring; Fermix uses its OWN web/file tools. Scorer vendored verbatim from GAIA; live-vetted through the daemon |
| **lm-eval-harness** (Tier 0) | ✅ implemented (`bin/run_lmeval.py`) | raw-model calibration, not an agent benchmark; the `lm_eval` run itself is operator-gated |
| **Terminal-Bench** | ⚠️ **skeleton — not runnable as written** (`bench/terminal_bench/fermix_agent.py`) | the design fits cleanly (CLI installed-agent: Fermix runs *inside* the sandbox with its own tools), but the `FermixAgent` class is **commented out** because Harbor's agent API has moved between releases. Only the two pure helpers (`install_script`, `exec_command`) are live |
| **HAL** (meta-harness) | ⚠️ **skeleton** (`bench/hal_fermix_agent.py`) | a `run(input) -> dict` shim that shells to `fermix ask`. Its I/O keys are unpinned, and HAL's cost column reads empty unless Fermix's provider calls are surfaced to Weave |
| **tau2-bench / AppWorld** | ⛔ needs a Fermix change | the agent must call the *benchmark's* tools via the benchmark's protocol; `fermix ask` only drives Fermix's OWN tools. Real integration needs Fermix to accept external tool defs + emit calls in their schema (a future MCP-inbound / tool-bridge feature) — do NOT ship a shell-out adapter, it would measure nothing. |

The flagship marketing number is **GAIA** (what Manus/OpenHands/smolagents cite).
Add **Terminal-Bench** only if marketing a shell/computer-use capability, and only
after finishing its adapter. Pursue a **HAL-verified** entry for the cost-aware,
reproduced-checkmark credibility that beats a bare self-report.

Native Fermix workflow results and official benchmark results stay **separately
labeled**. For a stateful public benchmark, driving `fermix ask` with the task
text alone is not an integration: an adapter is not accepted until it demonstrates
that the official verifier sees Fermix's actions, that resets work, and that
hidden answers remain unreachable.

---

## 1. GAIA (shipped, live-vetted)

```sh
# Download the gated dataset (accept terms): huggingface.co/datasets/gaia-benchmark/GAIA
#   validation split = public answers (internal number); test split = HF leaderboard only.
uv run bin/run_gaia.py --data path/to/gaia_validation.jsonl --limit 30
```
Drives each question through the dev daemon, extracts `FINAL ANSWER:`, scores
GAIA quasi-exact-match, prints per-level accuracy, writes `submission.jsonl`
(for the HF test-split leaderboard) + `report.txt`. Cost note: GAIA accuracy is
the metric; per-turn cost lives in Opik (correlate by the `e2e-gaia-*` thread if
you want $/task).

## 2. Terminal-Bench (Harbor installed-agent) — SKELETON, not runnable

Fermix is a CLI agent, so it slots into Harbor's installed-agent model — Fermix is
installed *inside* the task container and solves with its own shell/file/git tools.
That is the design; the adapter does not yet implement it.

**What exists:** `bench/terminal_bench/fermix_agent.py` defines two pure helpers,
`install_script()` (drops the Fermix binary into the container and writes a minimal
`config.toml`) and `exec_command()` (`fermix ask --timeout <ms> "<instruction>"`).
Both are import-safe without terminal-bench installed.

**What is missing:** the `FermixAgent` class is **commented out** — Harbor's agent
API has moved between releases, so the base class and override names are not
pinned. The command below therefore cannot resolve `…:FermixAgent` today:

```sh
pip install terminal-bench            # or from github.com/laude-institute/terminal-bench
# once the class is uncommented and its overrides confirmed for YOUR Harbor version:
tb run --agent-import-path bench.terminal_bench.fermix_agent:FermixAgent \
       --model <model-id> --task-id <task>
```

**To finish it:** confirm `AbstractInstalledAgent`'s method/property names against
the installed version, uncomment the class binding, and prove one task end-to-end
before quoting any number. Scope is terminal/coding tasks — pair with GAIA for
general-assistant breadth.

## 3. HAL (Holistic Agent Leaderboard — cost-aware) — SKELETON

HAL re-runs an agent across benchmarks with $/task tracking and a reproduced
checkmark. `bench/hal_fermix_agent.py` is a `run(input) -> dict` shim that shells
to `fermix ask`; it pulls the task text from whichever of several common keys is
present and returns both `output` and `answer` so the usual cases are covered.

**What is missing:** HAL's expected input/output keys are unpinned (the shim
guesses), and the invocation below points `--agent_dir` at a **file**, not a
directory — confirm the packaging your hal-harness version expects. Budget for
HAL's Weave cost-logging constraint: driving Fermix as a separate daemon leaves the
$/task column empty unless the provider calls are surfaced (point HAL at the
Opik-priced trace, or have the daemon echo per-turn usage) — a vacuous cost axis is
worse than none.

```sh
pip install hal-harness                # github.com/princeton-pli/hal-harness
hal-eval --agent_dir <agent package dir> --benchmark gaia ...   # confirm flags + packaging per your version
```

## 4. lm-eval-harness (Tier 0 raw baseline — shipped)

Separate raw-intelligence calibration (NOT subtracted from agentic uplift, §0).

```sh
export EVAL_BASELINE_MODEL=gpt-5.5 EVAL_BASELINE_API_KEY=sk-...
uv run bin/run_lmeval.py --dry-run --limit 50        # prints the lm_eval command
# pip install lm-eval, run it (or let the wrapper run it), then:
uv run bin/run_lmeval.py --results path/to/lm_eval_results.json
```

---

## Reproducibility (applies to every external run)
Pin and record alongside any published number: model snapshot id, temperature,
tool versions, dataset commit/split, harness commit, and date. Prefer a
HAL-verified / reproducible-config result over a bare self-report. Keep a private
held-out set you never publish; report the public-vs-private gap as a credibility
asset (§4).
