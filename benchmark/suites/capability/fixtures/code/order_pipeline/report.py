from pricing import line_total_cents


def order_total_dollars(lines, tax_percent):
    """Grand total in DOLLARS for `lines` (a list of (sku, qty)), with `tax_percent` tax."""
    subtotal_cents = sum(line_total_cents(sku, qty) for sku, qty in lines)
    taxed_cents = subtotal_cents * (100 + tax_percent) // 100
    return round(taxed_cents / 100, 2)
