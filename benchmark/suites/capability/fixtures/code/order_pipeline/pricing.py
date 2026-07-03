from catalog import PRICES, bulk_tier


def line_total_cents(sku, qty):
    """Total CENTS for one order line: unit price x qty, less the volume discount."""
    price = PRICES[sku]
    disc = bulk_tier(qty)
    return price * qty * (100 - disc) // 100
