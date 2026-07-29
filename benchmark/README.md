# Fermix end-to-end regression harness

The primary job of this harness is **change-by-change behavioral regression**:
does Fermix still behave like a grounded chief of staff through its real agent,
tool, memory, and trace path? The recommended 15-case core covers realistic
multi-turn work, prioritization, tool-grounded synthesis, sycophancy
counterfactuals, evidence-sensitive recommendations, and calibrated confidence.
It is not a benchmark.

The separate `run_capability.py` workflow can optionally score and rank models.
That is a different, less-frequent workflow; it does not replace the behavioral
E2E regression. This README covers both, `docs/HARNESS.md` has design detail,
`bench/RUNBOOK.md` covers external public benchmarks, and the `Makefile` wraps
common commands.

---

## 1. Safe setup (development default)

- **Opik** running locally (`http://localhost:5173`).
- **uv** installed (`brew install uv`).
- The existing Opik-enabled development daemon at `~/.fermix-dev`, exporting to
  project `fermix-dev`. Safe/read-only behavioral runs and the response-quality
  capability suite use it by default:

  ```sh
  FERMIX_HOME=~/.fermix-dev FERMIX_OPIK_ENABLED=1 \
  FERMIX_OPIK_PROJECT=fermix-dev FERMIX_BROWSER_HEADLESS=1 PORT=4031 \
  mix fermix.dev
  ```

The production home `~/.fermix` is always forbidden. Only
`isolated_mutation`, `external_write`, `desktop_input`, and `destructive` runs
must move to a disposable eval/e2e home and project. For those runs, use a strict
home-scoped sandbox and sanitized repository snapshot, start without unrelated
channels or realtime, and provide both `--confirm-daemon-isolated` and
`--confirm-isolated-env`. Conventional pairs are `~/.fermix-eval` /
`fermix-eval` for behavioral runs and `~/.fermix-capability-eval` /
`fermix-capability-eval` for capability runs. The confirmations are operator
attestations, not containment.

Judged runs use an **independent external judge** — the OpenAI API, called
directly by the harness (no daemon or core involvement). Configure it in **this
benchmark's config** (`config.yaml` / `behavioral_config.yaml`):

```yaml
judge:
  backend: "openai"        # or "none" to skip rubric judging
  model: "gpt-5.4-mini"    # must differ from the candidate model
```

The call authenticates with `EVAL_JUDGE_API_KEY`; the `make` judged targets
resolve it from the same OpenAI key the daemon uses (macOS keychain service
`fermix:OPENAI_API_KEY`), so there's no separate setup — export
`EVAL_JUDGE_API_KEY` to override, or `EVAL_JUDGE_BASE_URL` / `EVAL_JUDGE_MODEL`
to point elsewhere. The judge scores only prose against the rubric (structural
gates remain the hard safety/flow signal), and the harness refuses a judge model
that matches the candidate so the field is never graded by one of its own.

`private_account_read` alone may use the development daemon with
`--confirm-private-data`. Non-checker `expensive` work may use it with
`--confirm-cost`; checker-backed capability tasks always require the disposable
capability home because their trials seed and write workspace files.
Suites can also declare additive `confirm_cost: true` when cost is secondary to
another risk, so neither confirmation is lost.

Verify everything is ready:

```sh
cd benchmark
uv run bin/run_eval.py --check     # development behavioral daemon + Opik
uv run bin/run_eval.py --check --judge  # also preflight the restricted judge route
uv run bin/run_capability.py --check --judge  # capability + judge preflight
```

`make tests` is a separate developer command for the harness's unit/integration
tests. Behavioral and capability E2E commands do not invoke it implicitly.

---

## 2. Change-by-change behavioral regression

```sh
make dry
make regression
```

`make dry` validates and prints the exact 15-case plan without contacting the
daemon or judge. `make regression` runs that host-read-only core through the real
assistant and independent judge. For targeted investigation, select
`chief_of_staff`, `chief_of_staff_tools`, or `epistemic_integrity` directly with
`run_eval.py`; these safe/read-only runs use the development daemon without an
isolation attestation.
The isolated `jobs/clarify_before_scheduling` scenario tests clarification before
a real durable action. The expensive `subagents/autonomous_delegation_judgment`
pair tests whether Fermix chooses a proportionate work approach without being
told which route to use; repeat that named scenario three times when assessing
stability, never as an unbounded bulk run. This non-checker scenario requires
`--confirm-cost` but does not require an isolated daemon.

---

## 3. Optional capability score and model ranking

```sh
make estimate           # rough turn/time/price range, no model calls
make capability-auto     # full 22-task sweep: seed+start a disposable daemon, run, tear down
make capability-judged   # 4 rubric tasks, dev daemon, external OpenAI judge
make capability-readonly # cap_web_research + cap_web_app, dev daemon, read-only
make rank                # render the leaderboard
```

`make estimate` prints a rough turn/time/price range without model calls; it is
not a quote or hard spend guard. `make capability-judged` (4 rubric tasks) and
`make capability-readonly` (`cap_web_research` + `cap_web_app`) run host-read-only
against `~/.fermix-dev` / `fermix-dev` and need no isolation confirmation. `make
capability-auto` is the full 22-task sweep — it includes isolated-mutation and
expensive suites that must never touch `~/.fermix-dev`, so it stands up a
throwaway daemon, supplies the isolation attestations and cost confirmation, runs,
and tears the daemon down.

### The disposable capability daemon

`make capability-auto` is the whole flow in one command. It scores the model your
`~/.fermix-dev` daemon currently runs, in a throwaway `~/.fermix-capability-eval`
home, and cleans up after itself:

```sh
make capability-auto     # seed -> start (background) -> make check -> full sweep -> stop
```

Under the hood (`bin/capability-daemon.sh` + `bin/seed_capability_home.py`) it:

1. **Seeds `~/.fermix-capability-eval`** — creates the home, a git-backed
   `workspace/` (the checker's per-trial scoring root), a minimal strict
   `config.toml`, and the auth the scored model needs. The scored model is derived
   from the `primary = true` provider in `~/.fermix-dev/config.toml`, and its
   credentials are reused from the dev home:
   - **OAuth providers** (`openai_codex`, `anthropic`, `xai`) store their token
     home-scoped in `$FERMIX_HOME/auth.json`, so a fresh home has none. The seed
     copies just that provider's entry from `~/.fermix-dev/auth.json` into the
     disposable home (`0600`). It only *reads* the dev store; the eval daemon writes
     any refresh to its own copy, and a current token (valid hours out) is used
     as-is, so a normal short run never refreshes or rotates the shared token.
   - **API-key providers** keep `profile = "fermix-dev"` plus a `@keyring` sentinel,
     so the existing `fermix:fermix-dev:<ENV>` keychain entry resolves unchanged.

   The `[sandbox]` block is always regenerated strict and home-scoped
   (`mode = "strict"`, `workspace_root = $FERMIX_HOME/workspace`, `allowed_roots =
   []`) — never copied from the dev config, whose `allowed_roots` escape the home and
   would fail the runner's precondition.
2. **Starts it in the background** — `mix fermix.dev --no-web --no-realtime` with
   `FERMIX_OPIK_PROJECT=fermix-capability-eval` and a headless browser. Channels stay
   *on* (no `--no-channels`) because the CLI-ask turn queue is
   `FermixChannels.Gateway.Queue`; the seeded home configures no channel, so no bot
   adapter actually polls. `--no-web` drops the Phoenix port entirely, so it never
   collides with your `~/.fermix-dev` daemon (which owns a different home, a
   different control socket, and its own port); the two coexist untouched.
3. **Waits for readiness** — polls the control socket until `fermix status` answers.
4. **Runs `make check` then the full sweep**, and on exit **stops the daemon**
   (SIGTERM the BEAM, SIGKILL fallback) and clears its socket.

`make capability-auto` always scores the **current `~/.fermix-dev` primary** — the
seed regenerates `config.toml` from it on every run. To rank *several* models, drive
the daemon manually per §4 (you hand-edit which provider is primary between runs);
don't use `capability-auto` for that loop.

Useful flags on `bin/run_capability.py`:

| flag | effect |
|---|---|
| `--trials N` | trials per task (pass^k reliability needs N≥3; default 3) |
| `--suite NAME` | one suite — `cap_web_research` (live-fetch, provenance-gated), `cap_data_extraction`, `cap_coding` (end-state checker), `cap_memory` (cross-session durable memory), `cap_response_quality` (independent judge) |
| `--max-tasks N` | limit the number of tasks driven; not a dollar/spend cap |
| `--judge` | enable the independent external OpenAI judge (scores rubric prose; `EVAL_JUDGE_API_KEY` auto-resolved from the keychain) |
| `--confirm-daemon-isolated` | attest that an isolated-profile run is using the declared disposable daemon |
| `--confirm-isolated-env` | attest selected `isolated_mutation` tasks use the disposable capability home/workspace |
| `--confirm-cost` | acknowledge selected `expensive` cases may spawn several billed calls |
| `--private` | run an operator-supplied held-out split (`FERMIX_EVAL_HOLDOUT_DIR` or `--private-data <dir>`, OUTSIDE the repo) under a separate local `:private` row; skips Opik dataset/experiment/feedback writeback, but candidate turns still appear in the configured Opik trace store |
| `--config-id NAME` | override the auto-detected row label (needed to rank `openai` vs `openai_codex` — both report as `openai`) |
| `--estimate` | print the plan and exit |
| `--rank-only` | re-render the leaderboard, drive nothing |

**Checker tasks (`cap_coding`)** are graded by a script over the sandbox END-STATE
after the turn (SWE-bench style), not the reply. The runner seeds a fresh per-trial
dir under the daemon's `workspace/eval/<task>/t<i>/`, templates its absolute path in
as `{ws}`, runs `suites/capability/checkers/<name>` afterward, and SafeRm-tears-down.
They require the capability daemon's conventional `workspace_root =
$FERMIX_HOME/workspace`. The scoped directory is a scoring oracle, not the
agent's sandbox root: the harness does not prove the agent wrote nowhere else.
Use a disposable capability home/workspace and strict mode. Each checker ships
an oracle/negative proof (`bin/test_checker.py`). Authoring: a case carries
`checker: {script, mode, seed?}` instead of `score:`/`rubric:` (one scorer per case).
Checker and fixture paths must remain relative to the harness root; traversal,
absolute paths, symlink escapes, non-finite scores/timeouts, and unknown modes are
rejected. Subprocesses receive an allowlisted environment. Checkers are still
trusted tracked scripts, not a general untrusted-code sandbox.

The leaderboard lives at `reports/capability/leaderboard.json` and is rendered by
`make rank`. The served config is **auto-detected** from the trace, so each row is
labeled `provider/model/effort` (e.g. `openai/gpt-5.5/xhigh`,
`anthropic/claude-opus-4-8/high`) — the same model at a different reasoning effort
is a separate row. **Exception:** `openai_codex` (OAuth) reports as `openai` in
traces, so to rank it *alongside* `openai` (api-key) you must pass
`--config-id openai_codex/<model>` for the codex run (the runner reminds you).

---

## 4. Cross-model ranking — the manual provider-switch loop

To rank multiple providers/models, repeat this loop **once per model**. Configure
each provider only in the disposable `~/.fermix-capability-eval` home; do not
reuse or point the runner at the normal/dev daemon.

**List the rankable provider × model matrix** (from the repo root):

```sh
mix fermix.eval.matrix        # JSON: every provider + its curated models
```

**For each model you want to score:**

1. **Edit `~/.fermix-capability-eval/config.toml`** — set `primary = true` on exactly ONE
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
   with two. If the new primary is an **OAuth** provider (`openai_codex`,
   `anthropic`, `xai`), also copy its entry from `~/.fermix-dev/auth.json` into
   `~/.fermix-capability-eval/auth.json` (`0600`) — OAuth tokens are home-scoped, so
   a hand-managed eval home has none. (`capability-auto` does this automatically for
   the dev primary.) API-key providers just need `profile = "fermix-dev"` +
   `@keyring`.

2. **Restart the isolated source daemon by hand** so it picks up the new model
   (the model is a boot snapshot). Do **not** use `make capability-auto` here — it
   re-seeds `config.toml` from the `~/.fermix-dev` primary and would clobber your
   hand-edited model choice. Launch it directly, then wait until it is reachable:

   ```sh
   FERMIX_HOME=~/.fermix-capability-eval FERMIX_OPIK_ENABLED=1 \
     FERMIX_OPIK_PROJECT=fermix-capability-eval FERMIX_BROWSER_HEADLESS=1 \
     mix fermix.dev --no-web --no-realtime

   FERMIX_EVAL_HOME=~/.fermix-capability-eval \
     OPIK_PROJECT=fermix-capability-eval make check
   ```

3. **Run the metrics** — the model is detected automatically:

   ```sh
   FERMIX_EVAL_HOME=~/.fermix-capability-eval \
     OPIK_PROJECT=fermix-capability-eval \
     CONFIRM_DAEMON_ISOLATED=1 CONFIRM_ISOLATED_ENV=1 CONFIRM_COST=1 \
     make capability
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
- For a **fair** ranking when `--judge` is on, keep `judge.model` fixed and
  different from every candidate model. The runner verifies the actual routes and
  refuses a match. Point `EVAL_JUDGE_BASE_URL` at a separately operated endpoint
  if one is required.
- **Usage-limit backoff, then fail-fast (exit 4).** If the daemon's model hits a
  usage/rate/quota limit mid-sweep, Fermix returns a canned "try again" reply —
  scoring it would count Fermix's own limit as a task failure. So the runner **waits
  and retries** the turn on an escalating backoff (`usage_limit.retry_backoff_min` in
  `config.yaml`, default `30 / 60 / 120 / 180` min — sized to ride out a multi-hour
  subscription session-limit, whose "~N min" self-report is unreliable; each wait logs
  a `⏳` line with the retry clock time). Only when the **whole schedule is exhausted**
  does it stop at the pointer (`suite/case (trial)`), write **no** leaderboard row (a
  partial composite would overwrite the model's real score), and exit 4 — re-run once
  the limit clears. Tune per run with `EVAL_USAGE_RETRY_BACKOFF_MIN="30,60,120,180"`,
  or set it empty (`[]` / `""`) for immediate fail-fast. (Subscription paths like
  `openai_codex` hit limits; the pay-per-token `openai` API-key path usually won't.)

---

## 5. The other metrics

| Goal | Command | Notes |
|---|---|---|
| Behavioral regression (did a change break anything) | `make regression` | 15-case `host-safe-core`, independent external OpenAI judge, development daemon |
| Overfitting check (public vs held-out) | put your held-out suites in a dir OUTSIDE the repo, `export FERMIX_EVAL_HOLDOUT_DIR=…`, run `… --private`, compare the `provider/model` vs `…:private` rows | golds stay out of the repo and no held-out dataset/experiment is written; candidate prompts/replies still enter the configured Opik trace project, so choose project separation appropriate to the data; see `suites/capability/private/holdout.example.yaml` |
| **Uplift** (Fermix vs raw model) | `make baseline` then `bin/run_uplift.py --fermix <results.json> --baseline <results.json>` | needs `EVAL_BASELINE_API_KEY` + `EVAL_BASELINE_MODEL` (same model the Fermix arm served) |
| Raw-intelligence baseline (Tier 0) | `make lmeval` (dry-run prints the `lm_eval` command) | needs `pip install lm-eval` + key |
| **GAIA** (flagship public number) | `bin/run_gaia.py --data <gaia.jsonl> --limit 30` | dataset gated on Hugging Face; see `bench/RUNBOOK.md` |
| Terminal-Bench / HAL | see `bench/RUNBOOK.md` | external harnesses (adapters in `bench/`) |

Run `make help` for the full target list.

---

## 5b. Running any of this on Linux (`scripts/vultr-box.sh`)

macOS is the dev machine, so Linux-only regressions — writer-less secrets, no
`~/.fermix`, process-group reaping, the strict sandbox — are otherwise only seen
after a push. `scripts/vultr-box.sh` provisions a real Vultr VM (full root, the
artifact you ship, no shim) and runs the same recipe there:

```sh
scripts/vultr-box.sh plans             # real plan ids/prices for your region
scripts/vultr-box.sh snapshot          # once: pinned-toolchain base image
scripts/vultr-box.sh run regression    # ephemeral: provision -> test -> ALWAYS destroy
scripts/vultr-box.sh run dangerous     # the one place FERMIX_EVAL_DISPOSABLE=1 is honest
scripts/vultr-box.sh up                # persistent box; ssh in, `fermix setup` for channels
```

**Full runbook: [`docs/VULTR_BOX.md`](../docs/VULTR_BOX.md)** — setup, every
command, harness vendor-CLI logins, secrets, cost, limits, troubleshooting.

Defaults are `atl` / `vc2-2c-4gb`; OTP 28 and Elixir 1.19.5 are pinned via
`mise` and the pins are verified before the image is accepted, so a wrong version fails the snapshot
instead of quietly testing a toolchain we do not ship.

The image also carries a warmed `deps/` and `_build/` (dev + test), so a `run`
reuses ~214 MB of compiled dependencies and the Rust NIF instead of rebuilding
them. `--delete` never touches them: they are excluded from the rsync, which
protects them on the receiver. Refresh the image when `mix.lock` moves.

**Umbrella app code is always compiled with `--force`, deliberately.** `mix
compile` skips a source whose mtime is not *newer* than its manifest, and rsync
carries your macOS mtimes — so a file you edited before the image was built
arrives "older" than the warm `_build` and is silently not recompiled, leaving
the box testing code that is not on it (verified: a reverted module kept
returning its old value). `--force` rebuilds only this project, so warm deps
still pay off; it costs an app recompile per run and buys a box you can believe.

Your **working tree is rsync'd, not cloned**, so uncommitted work is what gets
tested. Secrets are forwarded per run and never baked into the snapshot. Needs
`VULTR_API_KEY`; see the script header for the rest.

Two limits worth knowing. It reproduces `linux-x64` only — there is no macOS
guest anywhere, and Vultr ARM was not confirmed. And `mix test` parallelism is
2x cores, so a 2-core box runs `max_cases 4` against CI's 8; to chase a CI
concurrency failure (like the `CommandHostStreamTest` teardown race) use a
4-core plan. `run` covers e2e, which **no push-triggered CI job does** — `ci.yml`
is entirely hermetic and the eval tiers only run on schedules, after a push.

---

## 6. Where results land / housekeeping

- **Leaderboard:** `reports/capability/leaderboard.json` (+ per-run `reports/capability/<ts>/`).
- **Opik:** one experiment per model under the `fermix-capability` dataset + feedback
  scores on each turn's trace (filter Opik by thread `e2e-cap-`). Safe runs use
  `fermix-dev`; isolated runs use their configured eval/e2e project.
- **Cost:** every turn is a real model call and may be billed. `--estimate`,
  `--max-tasks`, and `--max-cases` limit the plan or number of driven tasks; none
  is a dollar cap. Retries, judge calls, provider pricing, and unpriced OAuth
  routes can make billed spend differ from candidate-trace estimates.
- **Behavioral accounting:** reports label Opik cost as **candidate trace cost**,
  report judge call count and API-reported judge tokens when available, and do
  not claim judge cost is included.
- **Behavioral trace cleanup:** use `bin/run_eval.py --purge-run <UTC_RUN_ID>` to
  preview one exact run, then add `--confirm-purge` only after reviewing the count.
