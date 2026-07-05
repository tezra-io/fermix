#!/bin/sh
# Checker (exit mode): the discount-vs-tax bug fixed (FAIL_TO_PASS), line_total intact
# (PASS_TO_PASS), AND hidden multi-line / zero-edge cases the agent never saw — so a fix
# that special-cases only the visible input still fails. The root cause is not signposted:
# invoice_total rebuilds the subtotal from raw qty*price, silently dropping each line's
# discount; the fix must route the subtotal through line_total. cwd = trial scoped dir.
mkdir -p tests
cat > tests/test_hidden.py <<'PYEOF'
from invoice import invoice_total


def test_multi_line_mixed_discounts():
    lines = [{"qty": 1, "unit_price": 100.0, "discount_pct": 0},
             {"qty": 3, "unit_price": 20.0, "discount_pct": 25}]
    # 100 (no disc) + (60 less 25% = 45) = 145 subtotal, +10% tax = 159.50
    assert invoice_total(lines, 10) == 159.50


def test_zero_tax_zero_discount():
    assert invoice_total([{"qty": 5, "unit_price": 2.0, "discount_pct": 0}], 0) == 10.0
PYEOF
exec env PYTHONPATH="$FERMIX_EVAL_WORKSPACE" uv run --quiet --with pytest \
    python -m pytest -q tests/
