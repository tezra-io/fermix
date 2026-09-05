# Fermix eval — cadence targets. See SKILL.md + bench/RUNBOOK.md.
# Tier 2 (regression) every change · Tier 1 (capability/rank) on model-catalog
# changes + monthly · Tier 0 + public benchmarks per release.
UV := uv run
# Aimed-click harness (M28 C1): real OS clicks on the LIVE display, so BOTH
# attestations are required. See README §5c.
AIM_DISPLAY_ATTEST := $(if $(filter 1 true yes,$(CONFIRM_AIM_LIVE_DISPLAY)),--confirm-live-display,)
AIM_HANDS_ATTEST := $(if $(filter 1 true yes,$(CONFIRM_AIM_HANDS_OFF)),--confirm-hands-off,)
AIM_ATTEST := $(AIM_DISPLAY_ATTEST) $(AIM_HANDS_ATTEST)

.PHONY: help tests check dry regression behavioral-isolated capability capability-auto capability-judged capability-readonly estimate rank baseline uplift gaia lmeval aim aim-calibrate

help:
	@echo "targets: tests check dry regression behavioral-isolated capability capability-auto capability-judged capability-readonly estimate rank baseline uplift gaia lmeval aim aim-calibrate"

tests:        ## developer tests for harness code; does not run behavioral/capability E2E
	@for t in scoring pricing aggregate leaderboard release_gate experiments uplift baseline lmeval gaia capability_runner checker grade suites judge eval_safety seed_home opik_client tier aim; do \
	  echo "== $$t =="; $(UV) bin/test_$$t.py || exit 1; done

check:        ## preconditions (Opik + daemon)
	$(UV) bin/run_capability.py --check

dry:          ## validate behavioral suites, no spend
	$(UV) bin/run_eval.py --tag host-safe-core --judge --dry-run

regression:   ## Tier 2 behavioral regression against the development daemon
	bin/tier.sh regression

behavioral-isolated:  ## isolated-mutation behavioral suites vs the disposable eval daemon
	bin/tier.sh behavioral-isolated

# Exit codes: 0 valid+green · 2 refused selection · 3 preconditions/no route ·
# 4 measurement invalid · 5 valid and recorded, release gate RED. `make` reports every
# recipe failure as 2, so a caller that classifies on the code cannot go through make:
# bin/tier.sh execs the runner and is what CI and scripts/vultr-box.sh invoke. These
# targets are thin aliases for it — the tier commands live there, in one place.
capability:   ## Tier 1 capability score of the current daemon model, ALL public suites (k=5)
	bin/tier.sh capability

capability-auto:  ## one command: seed+start a disposable daemon, run the full sweep, tear down
	bin/capability-daemon.sh run

# --threshold 0.5 is the bar response_quality.yaml documents for this axis: a
# fractional taste score binarized at 1.0 makes pass^k meaningless, not strict.
capability-judged:  ## isolated-judge response-quality axis against the development daemon
	bin/tier.sh capability-judged

capability-readonly:  ## capability score of the READ-ONLY suites vs the dev daemon (no disposable home)
	bin/tier.sh capability-readonly

estimate:     ## print the capability turn-count/cost plan (no spend)
	$(UV) bin/run_capability.py --trials 5 --estimate

rank:         ## re-render the cross-model leaderboard
	$(UV) bin/run_capability.py --rank-only

# The claim this arm supports: the FULL Fermix system vs a raw single-call model on the
# same closed-form tasks. It does NOT isolate the contribution of tools — the arms also
# differ in scaffold, memory and execution policy. cap_web_research is selected because
# its tasks are closed-form (`score:`) and single-session; cap_data_extraction's two
# tasks are checker-only, so the selector found nothing scorable and the target refused.
baseline:     ## raw-model arm (needs EVAL_BASELINE_API_KEY + EVAL_BASELINE_MODEL)
	$(UV) bin/run_baseline.py --suite cap_web_research --trials 5

uplift:       ## paired uplift (set FERMIX_RESULTS=... BASELINE_RESULTS=...)
	$(UV) bin/run_uplift.py --fermix "$(FERMIX_RESULTS)" --baseline "$(BASELINE_RESULTS)"

gaia:         ## GAIA (set GAIA_DATA=path to the gated JSONL; LIMIT optional)
	$(UV) bin/run_gaia.py --data "$(GAIA_DATA)" --limit "$(or $(LIMIT),30)"

lmeval:       ## Tier 0 lm-eval command (dry-run; set EVAL_BASELINE_MODEL)
	$(UV) bin/run_lmeval.py --dry-run

aim:          ## aimed-click accuracy on the LIVE display (set CONFIRM_AIM_LIVE_DISPLAY=1 CONFIRM_AIM_HANDS_OFF=1)
	$(UV) bin/run_aim.py $(AIM_ATTEST)

aim-calibrate:  ## the aim run-start assertions only (one click); same two attestations
	$(UV) bin/run_aim.py --calibrate-only $(AIM_ATTEST)
