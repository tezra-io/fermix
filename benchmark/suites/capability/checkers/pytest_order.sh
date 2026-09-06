#!/bin/sh
# Checker (exit mode): the boundary bug fixed (FAIL_TO_PASS: test_bulk_boundary_50) AND
# HIDDEN boundary/tax cases the agent never saw. The bug is a `>` vs `>=` off-by-one in
# catalog.bulk_tier that manifests two modules away in report.order_total_dollars, so the
# fix must be TRACED (report -> pricing -> catalog), not patched at the symptom. The hidden
# cases use the OTHER tier boundaries (10, 100) + tax, so a fix that special-cases qty==50
# in pricing/report still fails. The seeded visible tests must be untouched, and the hidden
# cases run from outside the workspace (see _pytest_gate.sh). cwd = trial scoped dir.
CHECKER_DIR=$(cd "$(dirname "$0")" && pwd)
. "$CHECKER_DIR/_pytest_gate.sh"

FIXTURE_TESTS="$CHECKER_DIR/../fixtures/code/order_pipeline/tests"
gate_visible_tests "$FIXTURE_TESTS" || exit 1

HIDDEN=$(mktemp -d) || { echo "cannot create hidden-test dir"; exit 1; }
trap 'rm -rf "$HIDDEN"' EXIT
cat > "$HIDDEN/test_hidden.py" <<'EOF'
from report import order_total_dollars


def test_bulk_boundary_100():
    # 100 units of B ($25) at the 100+ tier (15% off): 100*2500c*0.85 = 212500c = $2125.00
    assert order_total_dollars([("B", 100)], 0) == 2125.00


def test_bulk_boundary_10():
    # 10 units of C ($4) at the 10+ tier (5% off): 10*400c*0.95 = 3800c = $38.00
    assert order_total_dollars([("C", 10)], 0) == 38.00


def test_multi_line_with_tax():
    # A x50 (45000c) + C x10 (3800c) = 48800c, +10% tax = 53680c -> $536.80
    assert order_total_dollars([("A", 50), ("C", 10)], 10) == 536.80


def test_below_boundaries_unchanged():
    # 9 units of C: no discount tier -> 9*400c = 3600c = $36.00 (guards over-correction)
    assert order_total_dollars([("C", 9)], 0) == 36.00
EOF

run_pytest "$HIDDEN" "$FIXTURE_TESTS" catalog.py pricing.py report.py
