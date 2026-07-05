from discounts import discounted


def line_total(qty: int, unit_price: float, discount_pct: float) -> float:
    """Total for one line: quantity x unit price, after the line's discount."""
    return discounted(qty * unit_price, discount_pct)


def invoice_total(lines: list[dict], tax_pct: float) -> float:
    """Grand total: the sum of the (discounted) line totals, then tax applied.
    Each line is a dict with keys 'qty', 'unit_price', 'discount_pct'."""
    subtotal = sum(ln["qty"] * ln["unit_price"] for ln in lines)
    return round(subtotal * (1 + tax_pct / 100), 2)
