# CI eval tiers — operator runbook

Implements Milestone 22 (docs/design/MILESTONE_22_MULTI_OS_CI_AND_DISPOSABLE_E2E.md).
One reusable workflow (`.github/workflows/eval-box.yml`) owns the disposable
box anatomy; thin callers own cadence:

| Tier | What runs | Where | When |
|---|---|---|---|
| T1 regression | `run_eval.py --check --judge` → `make dry` → `bin/tier.sh regression` (host-safe-core; the candidate is Claude Opus 5.5 at medium effort, judged by OpenAI's gpt-6-luna) | `eval-nightly.yml` → eval-box | nightly 07:17 UTC |
| T3 macOS smoke | `macos_smoke.sh` — ungraded daemon boot/converse/trace/refuse on a clean Mac, on the box's candidate | `eval-nightly.yml` (macos-15 job) | nightly |
| T2a capability | `make check` / `make estimate` then `bin/tier.sh capability` and `bin/tier.sh capability-judged` (deterministic composite, 27 tasks / 140 turns at k=5 including the `cap_untrusted_content` safety pack, with a pinned Claude Code CLI on Claude Haiku 5.5, signed in through Workload Identity Federation, for the delegated coding tasks + the judged response-quality axis, which has no release verdict), each publishing its runner's exit code | `eval-weekly.yml` → eval-box | weekly Sat 06:23 UTC |
| T2b dangerous | `sandbox_verify` named scenario, destructive profile | `eval-weekly.yml` → eval-box, after T2a | weekly; red files a critical issue |

All tiers also run on demand: Actions → eval-box → Run workflow (pick the tier).
Scheduled workflows execute the file on `main` but always **check out `dev`**
(the nightly checks out the dev commit its `changes` job resolved, so a green
record names exactly what ran).

**An unchanged nightly is skipped.** A scheduled nightly runs its tiers only
when dev's commit, or the commit main's workflows ran from, differs from a green
nightly's in the same ISO week (UTC). The `changes` job looks up an actions/cache
key naming both commits and the week. `record-green` saves that key once the
regression tier and the macOS smoke are both green. The week in the key re-runs
unchanged code once a week. Cache eviction can't provide that re-run, because
each nightly lookup counts as an access. A skipped night files no issue. If the
`changes` job fails or is cancelled, the tiers it skipped file the usual
"produced no evidence" issue. A manual dispatch of `eval-nightly` always runs.

**Read the T2a exit code before blaming the model.** `run_capability.py`
separates the measurement job from the quality gate: `4` means the measurement
was INVALID (a trial's trace never arrived, a checker/evaluator failed, more than
one route served the sweep, a usage limit, invalidated auth, or an unavailable
judge) and **no leaderboard row is written**, so the tier is red about the
harness, not the candidate. The first three kinds keep `results.invalid.json` and
a banner-marked report for diagnosis; the three abort kinds stop the sweep where
it stood and print the reason to stderr, because no completed set of outcomes
exists to write. `5` means the measurement was valid and recorded and the
predeclared release gate is RED. `0` is valid plus a green gate, or a valid
soft-only run, which has no gate; `2` and `3` are a refused selection and unmet
preconditions respectively.

**Read exit 5's reason before treating it as a candidate regression.** Only a
`pass@1` / `pass^k` reason, or an observed safety violation, in the run report is
about the model. The deterministic sweep's safety evidence is the
`cap_untrusted_content` pack (4 of its 27 tasks: an injected instruction in an MCP
tool result, a hidden delete instruction in a workspace file, a request for an API
key in an email, and a clean control); a violation in any trial is a real
candidate finding and turns the gate red. A task the daemon
could not be measured on (it did not advertise a tool the task requires, such as a
vendor CLI missing from the box) is NOT EVALUATED, and a selection whose cases
declare no safety gate reports *"safety not evaluated (no selected capability case
declares a safety gate)"*: both fail the gate closed by design. The judged axis
(`capability-judged`, the soft `cap_response_quality` suite) is a directional taste
signal with no release verdict, so a valid run of it exits `0` and prints *"release
gate: not applicable — soft taste axis"*. The exit code reaches the callers because
eval-box.yml captures each tier step's runner exit and publishes it as the
`exit_code` workflow output, and
because both it and `scripts/vultr-box.sh` run the tier through
`benchmark/bin/tier.sh`, which `exec`s the runner — `make` reports every runner
outcome as `2`, so a tier invoked through it carries no classification.

When a tier runs more than one step — the capability tier's two axes —
`benchmark/bin/tier_exit_code.sh` chooses which of their codes that output
carries: the code of the **first step that failed**, and `0` only when every
step that ran exited `0`. A `||` expression used to make this choice, and `||`
yields the first *truthy* operand — `"0"` is truthy, so a capability run's green
deterministic axis hid the judged axis's `5` and the weekly alert filed *"the
capability tier is failing"* instead of *"release gate is red"*, losing the
paragraph above.

Two outcomes publish **no** code at all, and neither is reported as `0`: no tier
step ran, and the deciding step failed before its runner published (it died in
`make check`, or the box was killed). The publishing step then fails and the
output stays empty, which the callers read as a tier that failed without a code
— the honest answer, because the later axis's `5` would otherwise report *"valid
and recorded"* about a sweep that never happened.

## Box anatomy (what eval-box does)

1. Comet-hosted Opik over its API (operator decision 2026-07-18; the earlier
   in-box docker stack is gone). The daemon exporter writes to
   `https://www.comet.com/opik/api`, the harness reads
   `…/opik/api/v1/private`, both authenticated with the `FERMIX_OPIK_API_KEY`
   + `FERMIX_OPIK_WORKSPACE` secrets. Each tier gets its own project in the
   workspace (`fermix-eval-ci-<tier>`). The local dev flow is untouched — it
   still defaults to the unauthenticated `http://localhost:5173` Opik.
2. Disposable `FERMIX_HOME` under the runner temp (leaf contains `eval`),
   seeded by `benchmark/bin/seed_capability_home.py` in **explicit mode**
   (`--provider anthropic --model <candidate> --reasoning-effort medium`): the
   provider block carries `reasoning_effort = "medium"`, which the Anthropic
   adapter sends as `output_config.effort`; no keychain, no auth.json in the
   eval home — the daemon reads `ANTHROPIC_API_KEY` from its environment at
   boot, and the boot step fails with a sentence when that secret is empty. The
   daemon never holds the judge's `OPENAI_API_KEY`.
3. Judged tiers only (regression, capability), before anything else is spent:
   the judge preflight. The judge is OpenAI's `gpt-6-luna` (`judge:` in
   `config.yaml` and `behavioral_config.yaml`), on `EVAL_JUDGE_API_KEY`, which
   this step and the judged tier steps feed from the `OPENAI_API_KEY` secret.
   `bin/judge_preflight.py` (a fraction of a cent) refuses a judge on the
   candidate's model before any call, then sends one real verdict through the
   judge's own code with the judge settings the tier's runner loads and
   requires the configured model to answer. An empty secret or a failed
   preflight fails the tier: an unusable judge would leave every judged case
   INCOMPLETE.

   Capability tier only: the Anthropic sign-in for Claude Code, which signs in
   through Workload Identity Federation and no API key. An `oidc_federation`
   profile in `~/.config/anthropic`, active through its `active_config` file,
   carries the IDs from the repository variables below and names a file under
   the runner temp that holds this job's GitHub OIDC token. A harness run
   spawns claude under `env -i` (HOME, PATH, TERM, USER), which is why all of
   it lives under HOME. GitHub's tokens live about five minutes and each can be
   exchanged once, so a background loop replaces the file every 60 s, and a
   step after the daemon stops ends the loop and fails the job if any refresh
   failed. The token file and the profile sit outside the eval home and the
   uploaded artifact, and go with the VM.

   Capability tier only, after the sign-in: a pinned Claude Code binary
   (version and sha256 in the step's `env`, checked before anything runs; the
   sha256 comes from that release's GPG-signed `manifest.json`) is put on the
   daemon's PATH, with `claude-haiku-5-5` as its default model and updates off
   in `~/.claude/settings.json`, so the delegated coding tasks (`cap_harness`)
   are measured instead of held out as NOT EVALUATED. Before anything is put on
   PATH, a preflight in the wiped harness environment requires `claude auth
   status` to name the federation profile and one tiny real call (well under a
   cent) to succeed on `claude-haiku-5-5` with no API key in play; the step then
   waits for the refresher's next rotation so the first delegated run finds an
   unspent token. An empty variable, a failed checksum, a failed token fetch, a
   failed call, another credential or another model each fail the tier: an
   advertised but unusable `claude_code_run` would score its tasks 0.00 as the
   candidate's failure. A run the candidate starts with `bare: true` reads only
   `ANTHROPIC_API_KEY`, which the claude adapter passes through from the
   daemon's environment: it authenticates with, and bills, the candidate's key
   instead of the federation profile.
4. Daemon lifecycle via `benchmark/bin/capability-daemon.sh up/down`
   (`mix fermix.dev --no-web --no-realtime`; channels stay ON — CLI turns
   route through the channels Gateway queue; none are configured, so none poll).
5. Tier-specific harness invocation, then reports + daemon log uploaded as the
   run artifact (30-day retention). Trace links inside reports point at the
   hosted Comet workspace, so they stay live after the box dies.

Tier-specific seeding: the regression tier adds `--allow-root $GITHUB_WORKSPACE`
(behavioral repo-read cases expand `__EVAL_REPO_ROOT__` to the checkout;
host-readonly profiles skip the strict-sandbox check). The dangerous tier
rsyncs the checkout (with `.git`) into the eval workspace first — `run_eval`'s
strict preflight requires the workspace HEAD to match the harness checkout.

## Secrets (repo Actions secrets — no .env files anywhere)

- `ANTHROPIC_API_KEY` — the candidate's key: fills the Anthropic provider
  block at daemon boot and pays for candidate turns (eval-box's boot step and
  the macOS smoke only). Give it a provider-side spend cap.
- `OPENAI_API_KEY` — the judge's key: the judged steps (the judge preflight,
  the regression tier, the capability tier's judged axis) pass it to the judge
  as `EVAL_JUDGE_API_KEY`; the daemon never receives it.
- `FERMIX_OPIK_API_KEY` + `FERMIX_OPIK_WORKSPACE` — Comet-hosted Opik auth
  for both the daemon exporter and the harness read side. Project names are
  workflow config, not secrets (`fermix-eval-ci-<tier>`); a
  `FERMIX_OPIK_PROJECT_NAME` secret is unused. Mind the hosted free-tier
  span quota (~25k/month): nightly regression + weekly capability sit close
  to it — check the workspace usage after the first weeks.

The Anthropic sign-in on the capability tier (box anatomy, step 3) uses
repository **variables**, not secrets, because they are identifiers:
`ANTHROPIC_EVAL_ORGANIZATION_ID`, `ANTHROPIC_EVAL_SERVICE_ACCOUNT_ID` and
`ANTHROPIC_EVAL_FEDERATION_RULE_ID` (an empty one fails the tier), plus
`ANTHROPIC_EVAL_WORKSPACE_ID`, needed only when the federation rule spans more
than one workspace. The rule must match this job's OIDC token: a scheduled run
presents `sub` `repo:tezra-io/fermix:ref:refs/heads/main`, a manual run the ref
it was dispatched from. Delegated runs bill the service account's workspace,
and none of that spend shows in Opik turn cost. Only the capability tier's
caller (eval-weekly's capability job) grants `id-token: write`: eval-box
declares no permissions and inherits its caller's token, so the regression and
dangerous tiers never hold the right to mint a GitHub OIDC token. A direct
eval-box dispatch gets the repository's default token, so that default must
stay read-only (Settings → Actions → General → Workflow permissions), and the
sign-in step refuses it: run the capability tier on demand through eval-weekly.
Only the sign-in step mints a token, and the daemon's environment drops the
request credential.

**Model rule:** the candidate model (eval-box input `model`, default
`claude-opus-5-5` on Anthropic at medium effort) must differ from `judge.model`
in `benchmark/config.yaml` and `benchmark/behavioral_config.yaml`
(`gpt-6-luna`) — the judge preflight refuses a judge on the candidate's model
before any call, and the harness refuses any verdict whose judge matches a
model the candidate actually ran on, vendor prefixes and release dates aside.

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
