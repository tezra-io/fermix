def discounted(amount: float, pct: float) -> float:
    """Return `amount` after a `pct` percent discount (pct in 0..100)."""
    return round(amount * (1 - pct / 100), 2)
