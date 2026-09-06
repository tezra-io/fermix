#!/bin/sh
# Checker (exit mode): the planted bug fixed (FAIL_TO_PASS) AND no regression on the
# visible happy-path (PASS_TO_PASS) AND a set of HIDDEN edge cases the agent never saw
# — so a fix that merely special-cases the one visible failing input still fails. The
# seeded visible tests must be untouched, and the hidden cases run from outside the
# workspace (see _pytest_gate.sh). cwd = the trial's scoped dir.
CHECKER_DIR=$(cd "$(dirname "$0")" && pwd)
. "$CHECKER_DIR/_pytest_gate.sh"

FIXTURE_TESTS="$CHECKER_DIR/../fixtures/code/business_days/tests"
gate_visible_tests "$FIXTURE_TESTS" || exit 1

HIDDEN=$(mktemp -d) || { echo "cannot create hidden-test dir"; exit 1; }
trap 'rm -rf "$HIDDEN"' EXIT
cat > "$HIDDEN/test_hidden.py" <<'EOF'
from datetime import date
from business_days import business_days_between


def test_empty_range():
    assert business_days_between(date(2026, 1, 5), date(2026, 1, 5)) == 0


def test_reversed_range():
    assert business_days_between(date(2026, 1, 12), date(2026, 1, 5)) == 0


def test_spans_sunday():
    # Fri 2026-01-09 .. Tue 2026-01-13 (excl) = Fri + Mon = 2 (Sat & Sun excluded)
    assert business_days_between(date(2026, 1, 9), date(2026, 1, 13)) == 2


def test_full_two_weeks():
    # Mon 2026-01-05 .. Mon 2026-01-19 (excl) = two whole work weeks = 10
    assert business_days_between(date(2026, 1, 5), date(2026, 1, 19)) == 10
EOF

run_pytest "$HIDDEN" "$FIXTURE_TESTS" business_days.py
