# Fermix eval — cadence targets. See SKILL.md + bench/RUNBOOK.md.
# Tier 2 (regression) every change · Tier 1 (capability/rank) on model-catalog
# changes + monthly · Tier 0 + public benchmarks per release.
UV := uv run
# External openai judge key: use EVAL_JUDGE_API_KEY if exported, else reuse the
# daemon's configured OpenAI key from the macOS keychain (same entry `@keyring`
# resolves to). Judged targets prepend it so no separate setup is needed.
JUDGE_KEY = $${EVAL_JUDGE_API_KEY:-$$(security find-generic-password -s fermix:OPENAI_API_KEY -a fermix -w 2>/dev/null)}
DAEMON_ATTEST := $(if $(filter 1 true yes,$(CONFIRM_DAEMON_ISOLATED)),--confirm-daemon-isolated,)
ISOLATION_ATTEST := $(if $(filter 1 true yes,$(CONFIRM_ISOLATED_ENV)),--confirm-isolated-env,)
COST_CONFIRM := $(if $(filter 1 true yes,$(CONFIRM_COST)),--confirm-cost,)

.PHONY: help tests check dry regression capability capability-auto capability-judged capability-readonly estimate rank baseline uplift gaia lmeval

help:
	@echo "targets: tests check dry regression capability capability-auto capability-judged capability-readonly estimate rank baseline uplift gaia lmeval"

tests:        ## developer tests for harness code; does not run behavioral/capability E2E
	@for t in scoring aggregate leaderboard experiments uplift baseline lmeval gaia capability_runner checker grade eval_safety; do \
	  echo "== $$t =="; $(UV) bin/test_$$t.py || exit 1; done

check:        ## preconditions (Opik + daemon)
	$(UV) bin/run_capability.py --check

dry:          ## validate behavioral suites, no spend
	$(UV) bin/run_eval.py --tag host-safe-core --judge --dry-run

regression:   ## Tier 2 behavioral regression against the development daemon
	EVAL_JUDGE_API_KEY="$(JUDGE_KEY)" $(UV) bin/run_eval.py --tag host-safe-core --judge

capability:   ## Tier 1 capability score of the current daemon model, ALL public suites (k=5)
	$(UV) bin/run_capability.py --trials 5 $(DAEMON_ATTEST) $(ISOLATION_ATTEST) $(COST_CONFIRM)

capability-auto:  ## one command: seed+start a disposable daemon, run the full sweep, tear down
	bin/capability-daemon.sh run

capability-judged:  ## isolated-judge response-quality axis against the development daemon
	EVAL_JUDGE_API_KEY="$(JUDGE_KEY)" $(UV) bin/run_capability.py --suite cap_response_quality --trials 5 --judge

capability-readonly:  ## capability score of the READ-ONLY suites vs the dev daemon (no disposable home)
	$(UV) bin/run_capability.py --trials 5 --suite cap_web_research --suite cap_web_app

estimate:     ## print the capability turn-count/cost plan (no spend)
	$(UV) bin/run_capability.py --trials 5 --estimate

rank:         ## re-render the cross-model leaderboard
	$(UV) bin/run_capability.py --rank-only

baseline:     ## raw-model arm (needs EVAL_BASELINE_API_KEY + EVAL_BASELINE_MODEL)
	$(UV) bin/run_baseline.py --suite cap_data_extraction --trials 5

uplift:       ## paired uplift (set FERMIX_RESULTS=... BASELINE_RESULTS=...)
	$(UV) bin/run_uplift.py --fermix "$(FERMIX_RESULTS)" --baseline "$(BASELINE_RESULTS)"

gaia:         ## GAIA (set GAIA_DATA=path to the gated JSONL; LIMIT optional)
	$(UV) bin/run_gaia.py --data "$(GAIA_DATA)" --limit "$(or $(LIMIT),30)"

lmeval:       ## Tier 0 lm-eval command (dry-run; set EVAL_BASELINE_MODEL)
	$(UV) bin/run_lmeval.py --dry-run
