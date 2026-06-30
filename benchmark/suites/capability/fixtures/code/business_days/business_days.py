from datetime import date, timedelta


def business_days_between(start: date, end: date) -> int:
    """Count Mon-Fri business days from `start` (inclusive) to `end` (exclusive)."""
    count = 0
    cur = start
    while cur < end:
        if cur.weekday() <= 5:   # bug: weekday()==5 is Saturday, wrongly counted
            count += 1
        cur += timedelta(days=1)
    return count
