# CI eval tiers — operator runbook

Implements Milestone 22 (docs/design/MILESTONE_22_MULTI_OS_CI_AND_DISPOSABLE_E2E.md).
One reusable workflow (`.github/workflows/eval-box.yml`) owns the disposable
box anatomy; thin callers own cadence:

| Tier | What runs | Where | When |
|---|---|---|---|
| T1 regression | `run_eval.py --check --judge` → `make dry` → `make regression` (host-safe-core, judged) | `eval-nightly.yml` → eval-box | nightly 07:17 UTC |
| T3 macOS smoke | `macos_smoke.sh` — ungraded daemon boot/converse/trace/refuse on a clean Mac | `eval-nightly.yml` (macos-15 job) | nightly |
| T2a capability | `make check/estimate/capability/capability-judged` (22-task composite + judged response-quality axis) | `eval-weekly.yml` → eval-box | weekly Sat 06:23 UTC |
| T2b dangerous | `sandbox_verify` named scenario, destructive profile | `eval-weekly.yml` → eval-box, after T2a | weekly; red files a critical issue |

All tiers also run on demand: Actions → eval-box → Run workflow (pick the tier).
Scheduled workflows execute the file on `main` but always **check out `dev`**.

## Box anatomy (what eval-box does)

1. Pinned Opik up in-box (`opik/docker-compose.yml`, see `opik/README.md`),
   probed via `wait_opik.sh` — the harness's own precondition route.
2. Disposable `FERMIX_HOME` under the runner temp (leaf contains `eval`),
   seeded by `benchmark/bin/seed_capability_home.py` in **explicit mode**
   (`--provider openai --model <candidate>`): no keychain, no auth.json — the
   daemon reads `OPENAI_API_KEY` from its environment at boot, so no secret
   ever lands on disk.
3. Daemon lifecycle via `benchmark/bin/capability-daemon.sh up/down`
   (`mix fermix.dev --no-web --no-realtime`; channels stay ON — CLI turns
   route through the channels Gateway queue; none are configured, so none poll).
4. Tier-specific harness invocation, then reports + daemon log uploaded as the
   run artifact (30-day retention). Trace links inside reports point at the
   box-local Opik and die with it — the report is the durable record.

Tier-specific seeding: the regression tier adds `--allow-root $GITHUB_WORKSPACE`
(behavioral repo-read cases expand `__EVAL_REPO_ROOT__` to the checkout;
host-readonly profiles skip the strict-sandbox check). The dangerous tier
rsyncs the checkout (with `.git`) into the eval workspace first — `run_eval`'s
strict preflight requires the workspace HEAD to match the harness checkout.

## Secrets (repo Actions secrets — no .env files anywhere)

- `OPENAI_API_KEY` — dedicated eval key with a provider-side spend cap; fills
  the provider block at daemon boot and pays for candidate turns.
- `EVAL_JUDGE_API_KEY` — the independent judge (may be the same OpenAI key
  *value*; independence comes from the judge **model**). The Makefile's
  keychain fallback for this key is macOS-only; CI must set the secret.

**Model rule:** the candidate model (eval-box input `model`, default
`gpt-5.6-luna`) must differ from `judge.model` in `benchmark/config.yaml`
(`gpt-5.4-mini`) — the harness refuses a judge that matches the candidate.

Secrets are reachable only from `schedule`/`workflow_dispatch` runs — no
PR-triggered workflow declares them.

## Reproducing a tier locally (dev Mac)

```sh
# regression against the dev daemon (the normal loop — no box needed):
cd benchmark && make dry && make regression

# capability exactly like CI (disposable daemon, auto teardown):
make -C benchmark capability-auto

# dangerous: NOT on this machine. The FERMIX_EVAL_DISPOSABLE=1 guard refuses
# it outside a disposable environment — use the eval-box dispatch, or the
# Milestone 20 Tart VM when it lands.
```

## Capability leaderboard continuity

`benchmark/reports/capability/leaderboard.json` persists across weekly runs
via `actions/cache` (restore latest → save under the run id). Cache eviction
loses only the aggregate view — per-run `results.json` artifacts are the
source of truth; re-render with `make rank`.

## Knobs (capability-daemon.sh)

| Env | Default | Meaning |
|---|---|---|
| `FERMIX_CAP_HOME` | `~/.fermix-capability-eval` | disposable home (leaf must contain `eval`/`e2e`) |
| `FERMIX_CAP_PROJECT` | `fermix-capability-eval` | Opik project the daemon exports to |
| `FERMIX_CAP_SEED_ARGS` | — | extra `seed_capability_home.py` flags (CI explicit mode) |
| `FERMIX_CAP_OPIK` | `1` | `0` starts the daemon without the Opik exporter (macOS smoke) |
| `READY_TIMEOUT` | `90` | seconds to wait for the control socket |
