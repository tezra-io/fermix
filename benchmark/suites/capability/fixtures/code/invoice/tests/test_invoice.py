from invoice import line_total, invoice_total


def test_line_total_applies_discount():
    # PASS_TO_PASS: line_total is correct on its own (2 x $10, less 10% = $18).
    assert line_total(2, 10.0, 10) == 18.0


def test_invoice_total_honors_line_discounts():
    # FAIL_TO_PASS: a discounted line must reduce the taxed grand total.
    # one line: 2 x $10 = $20, less 10% = $18, then +5% tax = $18.90.
    assert invoice_total([{"qty": 2, "unit_price": 10.0, "discount_pct": 10}], 5) == 18.90
