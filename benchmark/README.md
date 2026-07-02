# Running the Fermix eval metrics

This skill scores **how well a model performs *with* Fermix's tools** and **ranks
models against each other**. This README is the step-by-step run guide; `SKILL.md`
has the design detail, `bench/RUNBOOK.md` covers the external public benchmarks,
and the `Makefile` wraps the common commands.

> **The cross-model sweep is a manual loop:** Fermix bakes the main-agent model at
> daemon boot, so to score a different provider/model you **edit the config, restart
> the dev daemon, and run again**. Each run auto-detects the served model and adds a
> row to a leaderboard that re-ranks. Steps are in §3.

---

## 1. Prerequisites (once)

- **Opik** running locally (`http://localhost:5173`).
- The **Opik-enabled dev daemon** running against `~/.fermix-dev` (started with
  `FERMIX_OPIK_ENABLED=1` — the brew daemon at `~/.fermix` does NOT export to Opik
  and can't be used).
- **uv** installed (`brew install uv`). The runners are self-contained `uv run`
  scripts — no venv to set up.

Verify everything is ready:

```sh
cd benchmark
make check          # Opik reachable + dev daemon reachable
make tests          # 88 unit/integration tests (no daemon spend)
```

---

## 2. Quick start — score the model the daemon is serving now

```sh
make estimate                       # turn-count + rough $/time, no spend
make capability                     # score all public suites, k=5 trials/task
make rank                           # re-render the leaderboard table
```

`make capability` = `uv run bin/run_capability.py --trials 5` (all public suites).
Useful flags on `bin/run_capability.py`:

| flag | effect |
|---|---|
| `--trials N` | trials per task (pass^k reliability needs N≥3; default 3) |
| `--suite NAME` | one suite — `cap_web_research` (live-fetch, provenance-gated), `cap_data_extraction`, `cap_coding` (end-state checker), `cap_memory` (cross-session durable memory), `cap_safety` (judge) |
| `--max-tasks N` | cap task count (bound spend) |
| `--judge` | enable the LLM judge (required for `cap_safety` — refusal needs a judge) |
| `--private` | run an operator-supplied held-out split (`FERMIX_EVAL_HOLDOUT_DIR` or `--private-data <dir>`, OUTSIDE the repo) under a separate `:private` row, never written to Opik |
| `--config-id NAME` | override the auto-detected row label (needed to rank `openai` vs `openai_codex` — both report as `openai`) |
| `--estimate` | print the plan and exit |
| `--rank-only` | re-render the leaderboard, drive nothing |

**Checker tasks (`cap_coding`)** are graded by a script over the sandbox END-STATE
after the turn (SWE-bench style), not the reply. The runner seeds a fresh per-trial
dir under the daemon's `workspace/eval/<task>/t<i>/`, templates its absolute path in
as `{ws}`, runs `suites/capability/checkers/<name>` afterward, and SafeRm-tears-down.
They work on the standard dev daemon (absolute `{ws}` resolves under `workspace_root`
in any sandbox mode); for stronger confinement run the eval daemon with
`[sandbox] mode = "strict"` + shell enabled. Each checker ships an oracle/negative
proof (`bin/test_checker.py`). Authoring: a case carries `checker: {script, mode,
seed?}` instead of `score:`/`rubric:` (one scorer per case).

The leaderboard lives at `reports/capability/leaderboard.json` and is rendered by
`make rank`. The served config is **auto-detected** from the trace, so each row is
labeled `provider/model/effort` (e.g. `openai/gpt-5.5/xhigh`,
`anthropic/claude-opus-4-8/high`) — the same model at a different reasoning effort
is a separate row. **Exception:** `openai_codex` (OAuth) reports as `openai` in
traces, so to rank it *alongside* `openai` (api-key) you must pass
`--config-id openai_codex/<model>` for the codex run (the runner reminds you).

---

## 3. Cross-model ranking — the manual provider-switch loop

To rank multiple providers/models, repeat this loop **once per model**. (The model
you want must already be credentialed in `~/.fermix-dev` — API key in the keychain/
config, or OAuth connected.)

**List the rankable provider × model matrix** (from the repo root):

```sh
mix fermix.eval.matrix        # JSON: every provider + its curated models
```

**For each model you want to score:**

1. **Edit `~/.fermix-dev/config.toml`** — set `primary = true` on exactly ONE
   provider block and `primary = false` on all the others, and set that provider's
   `default_model`. Example switching from OpenAI to Anthropic:

   ```toml
   [fermix_core.providers.openai_codex]
   primary = false              # was true
   default_model = "gpt-5.5"

   [fermix_core.providers.anthropic]
   primary = true               # now the active model
   default_model = "claude-opus-4-8"
   reasoning_effort = "high"
   ```

   ⚠️ Exactly one provider may have `primary = true` — the daemon refuses to boot
   with two.

2. **Restart the dev daemon** so it picks up the new model (the model is a boot
   snapshot). For a source daemon: stop the running `mix fermix.dev` (Ctrl+C) and
   re-run it; for an installed service, `fermix stop` then start it. Then wait
   until it's back:

   ```sh
   make check                  # re-run until the daemon is reachable again
   ```

3. **Run the metrics** — the model is detected automatically:

   ```sh
   make capability             # adds/updates this model's leaderboard row
   ```

**After cycling every model:**

```sh
make rank                     # the full ranking, all models, sorted by composite
```

Notes:
- Rows are keyed by `provider/model/effort` (latest run wins), so re-running a
  config refreshes its row without disturbing the others. (See the `openai_codex`
  caveat above — it shares the `openai` key unless you pass `--config-id`.)
- The efficiency axis is **tokens/✓** by default (provider-neutral). `$ /✓` only
  shows for OpenAI/Google (Opik prices only those); OAuth routes report `$0`.
- For a **fair** ranking when `--judge` is on, use an **independent** judge so the
  daemon isn't grading itself: `export EVAL_JUDGE_BACKEND=openai EVAL_JUDGE_API_KEY=sk-…`.

---

## 4. The other metrics

| Goal | Command | Notes |
|---|---|---|
| Behavioral regression (did a change break anything) | `make regression` | the original `run_eval.py` tier |
| Overfitting check (public vs held-out) | put your held-out suites in a dir OUTSIDE the repo, `export FERMIX_EVAL_HOLDOUT_DIR=…`, run `… --private`, compare the `provider/model` vs `…:private` rows | answers stay out of the repo + out of Opik; see `suites/capability/private/holdout.example.yaml` |
| **Uplift** (Fermix vs raw model) | `make baseline` then `bin/run_uplift.py --fermix <results.json> --baseline <results.json>` | needs `EVAL_BASELINE_API_KEY` + `EVAL_BASELINE_MODEL` (same model the Fermix arm served) |
| Raw-intelligence baseline (Tier 0) | `make lmeval` (dry-run prints the `lm_eval` command) | needs `pip install lm-eval` + key |
| **GAIA** (flagship public number) | `bin/run_gaia.py --data <gaia.jsonl> --limit 30` | dataset gated on Hugging Face; see `bench/RUNBOOK.md` |
| Terminal-Bench / HAL | see `bench/RUNBOOK.md` | external harnesses (adapters in `bench/`) |

Run `make help` for the full target list.

---

## 5. Where results land / housekeeping

- **Leaderboard:** `reports/capability/leaderboard.json` (+ per-run `reports/capability/<ts>/`).
- **Opik:** one experiment per model under the `fermix-capability` dataset + feedback
  scores on each turn's trace (filter Opik by thread `e2e-cap-`).
- **Cost:** every turn is a real billed LLM turn (~$0.05–0.6, ~3–45 s). Use
  `--estimate` and `--max-tasks` to bound spend; cycle providers deliberately.
- **Purge** this skill's eval traces from Opik: `make purge`.
