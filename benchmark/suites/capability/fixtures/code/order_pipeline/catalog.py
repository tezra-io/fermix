# Prices are stored in whole CENTS (integers).
PRICES = {"A": 1000, "B": 2500, "C": 400}


def bulk_tier(qty):
    """Volume discount PERCENT for an order line of `qty` units.
    Tiers: 10+ -> 5%, 50+ -> 10%, 100+ -> 15%."""
    if qty > 100:
        return 15
    elif qty > 50:
        return 10
    elif qty > 10:
        return 5
    return 0
