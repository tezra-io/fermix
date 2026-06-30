# External benchmark runbook (Phase 3 — public credibility)

Operator guide for running Fermix against the public agent benchmarks. These are
the marketing-credible tier (`docs/design/EVAL_CAPABILITY_SCORING.md` §6). Unlike
the in-skill `run_capability.py` (which is fully self-contained), each external
benchmark needs its own harness/dataset/credentials — hence this runbook.

**Honest fit map** — which benchmarks Fermix actually drops into, and how:

| Benchmark | Fit | Why |
|---|---|---|
| **GAIA** | ✅ clean (shipped: `bin/run_gaia.py`) | final-answer-only scoring; Fermix uses its OWN web/file tools |
| **Terminal-Bench** | ✅ clean (`bench/terminal_bench/`) | CLI installed-agent: Fermix runs *inside* the sandbox with its own shell/file/git tools |
| **HAL** (meta-harness) | ✅ via shim (`bench/hal_fermix_agent.py`) | wraps GAIA/Terminal-Bench Fermix runs and adds cost-vs-accuracy + a verified leaderboard entry |
| **lm-eval-harness** (Tier 0) | ✅ (shipped: `bin/run_lmeval.py`) | raw-model calibration, not an agent benchmark |
| **tau2-bench / AppWorld** | ⛔ needs a Fermix change | the agent must call the *benchmark's* tools via the benchmark's protocol; `fermix ask` only drives Fermix's OWN tools. Real integration needs Fermix to accept external tool defs + emit calls in their schema (a future MCP-inbound / tool-bridge feature) — do NOT ship a shell-out adapter, it would measure nothing. |

The flagship marketing number is **GAIA** (what Manus/OpenHands/smolagents cite).
Add **Terminal-Bench** only if marketing a shell/computer-use capability. Pursue a
**HAL-verified** entry for the cost-aware, reproduced-checkmark credibility that
beats a bare self-report.

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

## 2. Terminal-Bench (Harbor installed-agent)

Fermix is a CLI agent, so it slots into Harbor's installed-agent model — Fermix is
installed *inside* the task container and solves with its own shell/file/git tools.

```sh
pip install terminal-bench            # or from github.com/laude-institute/terminal-bench
# Adapter: bench/terminal_bench/fermix_agent.py (AbstractInstalledAgent)
tb run --agent-import-path bench.terminal_bench.fermix_agent:FermixAgent \
       --model <model-id> --task-id <task>      # see the adapter header for current flags
```
The adapter's install script drops the Fermix binary into the container and sets
the exec command to `fermix ask "<task instruction>"`. **Verify the
`AbstractInstalledAgent` method names against your installed Harbor version** (the
adapter header flags exactly what to confirm). Scope is terminal/coding tasks —
pair with GAIA for general-assistant breadth.

## 3. HAL (Holistic Agent Leaderboard — cost-aware)

HAL re-runs an agent across benchmarks with $/task tracking and a reproduced
checkmark. Use `bench/hal_fermix_agent.py` (a `run(input)->dict` shim that calls
`fermix ask`). Budget for HAL's Weave cost-logging constraint — wrap so Fermix's
provider calls/costs are captured, not hidden in a spawned process.

```sh
pip install hal-harness                # github.com/princeton-pli/hal-harness
hal-eval --agent_dir bench/hal_fermix_agent --benchmark gaia ...   # confirm flags per your version
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
