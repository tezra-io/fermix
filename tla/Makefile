# TLA+ specs of Fermix's concurrent protocols. See README.md.
# SPECS selects specs by name (directories under specs/); empty means all.
UV := uv run
SPECS ?=

.PHONY: help tests check report list repin

help:
	@echo "targets: tests check report list repin   (SPECS=\"turn_queue ...\" to select)"

tests:        ## the runner's own tests (no Java, no TLC)
	$(UV) bin/test_check.py

check:        ## run the specs; exit 1 on a FAIL or a stale spec
	$(UV) bin/check.py $(SPECS)

report:       ## check, then write out/report.md + out/report.json: each finding as code-referenced steps
	$(UV) bin/check.py --report $(SPECS)

list:         ## every check, its expectation, and stale specs (no Java)
	$(UV) bin/check.py --list $(SPECS)

repin:        ## after committing a change and re-reading the stale spec: make repin SPECS=<spec>
	@test -n "$(SPECS)" || { echo "usage: make repin SPECS=\"<spec> ...\" (re-pin only what you re-read)"; exit 2; }
	$(UV) bin/check.py --repin $(SPECS)
