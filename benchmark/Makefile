# Fermix eval — cadence targets. See SKILL.md + bench/RUNBOOK.md.
# Tier 2 (regression) every change · Tier 1 (capability/rank) on model-catalog
# changes + monthly · Tier 0 + public benchmarks per release.
UV := uv run

.PHONY: help tests check dry regression capability estimate rank baseline uplift gaia lmeval purge

help:
	@echo "targets: tests check dry regression capability estimate rank baseline uplift gaia lmeval purge"

tests:        ## all capability-eval unit/integration tests
	@for t in scoring aggregate leaderboard experiments uplift baseline lmeval gaia; do \
	  echo "== $$t =="; $(UV) bin/test_$$t.py || exit 1; done

check:        ## preconditions (Opik + daemon)
	$(UV) bin/run_capability.py --check

dry:          ## validate behavioral suites, no spend
	$(UV) bin/run_eval.py --dry-run

regression:   ## Tier 2 behavioral regression
	$(UV) bin/run_eval.py --all

capability:   ## Tier 1 capability score of the current daemon model, ALL public suites (k=5)
	$(UV) bin/run_capability.py --trials 5

capability-judged:  ## capability incl. the judge-scored safety suite (needs EVAL_JUDGE_BACKEND=openai)
	$(UV) bin/run_capability.py --trials 5 --judge

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

purge:        ## delete this skill's eval traces from Opik
	$(UV) bin/run_eval.py --purge
