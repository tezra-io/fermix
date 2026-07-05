from datetime import date

from business_days import business_days_between


def test_no_weekend():
    # Mon 2026-01-05 .. Sat 2026-01-10 (exclusive) = Mon-Fri = 5. Passes WITH the bug
    # too (no Saturday inside the range) — this is the PASS_TO_PASS guard against a
    # fix that breaks the happy path.
    assert business_days_between(date(2026, 1, 5), date(2026, 1, 10)) == 5


def test_spans_saturday():
    # Mon 2026-01-05 .. Mon 2026-01-12 (exclusive) includes Sat 2026-01-10. Correct
    # answer is 5; the planted bug counts Saturday and returns 6 — FAIL_TO_PASS.
    assert business_days_between(date(2026, 1, 5), date(2026, 1, 12)) == 5
