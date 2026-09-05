#!/usr/bin/env python3
"""Checker (json) for the seeded-file order-extraction task. The agent must READ
order.txt and write EXACTLY one line to answer.txt as
<order_id>|<total>|<item_count>|<date>.

The gold is PARSED from the seeded order at check time (not hardcoded), so it follows a
changed fixture and cannot be memorized: total_charged rather than the subtotal,
item_count as the sum of quantities rather than the number of lines, and the delivery
date normalized to YYYY-MM-DD.

The prompt says EXACTLY one line and nothing else, and that is graded as written (the
shared ONLY/EXACTLY contract in _checkerlib.sole_line): a preamble, a second line, or a
trailing "Done." fails, because the artifact is meant to be machine-readable. Inside the
line, a leading "$" on the total is tolerated although the prompt asks for a bare number —
graded slightly in the model's favour, like expense_total.
"""
import os
import re
import sys

sys.dont_write_bytecode = True          # never drop __pycache__ into the repo checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

MONTHS = ("january", "february", "march", "april", "may", "june", "july",
          "august", "september", "october", "november", "december")


def gold(text):
    """Order id, charged total, item count and ISO delivery date from the seeded
    order confirmation."""
    order = re.search(r"#([A-Z]{2}-\d+)", text)
    total = re.search(r"(?i)total charged:\s*\$?\s*([\d,]+\.\d{2})", text)
    delivery = re.search(r"(?i)delivery:.*?([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})", text)
    quantities = re.findall(r"(?m)^\s*(\d+)x\s", text)
    if not (order and total and delivery and quantities):
        lib.refuse("seeded order.txt is not an order confirmation (missing id/total/"
                   "delivery/quantities)")
    month = delivery.group(1).lower()
    if month not in MONTHS:
        lib.refuse(f"seeded order.txt has an unparseable delivery month: {month!r}")
    date = f"{delivery.group(3)}-{MONTHS.index(month) + 1:02d}-{int(delivery.group(2)):02d}"
    return (order.group(1), float(total.group(1).replace(",", "")),
            sum(int(q) for q in quantities), date)


ws = lib.workspace()
order_path = os.path.join(ws, "order.txt")
if not os.path.isfile(order_path):
    lib.refuse("seeded order.txt is missing — the answer cannot be graded")
want_id, want_total, want_count, want_date = gold(lib.read_text(order_path, "order.txt"))

answer_path = os.path.join(ws, "answer.txt")
if not os.path.isfile(answer_path):
    lib.refuse("no answer.txt")
fields = [f.strip() for f in lib.sole_line(answer_path, "answer.txt").split("|")]
if len(fields) != 4:
    lib.refuse(f"answer.txt must hold 4 pipe-separated fields, got {len(fields)}: {fields!r}")

want = f"{want_id}|{want_total}|{want_count}|{want_date}"
if fields[0].upper() != want_id.upper():
    lib.refuse(f"order id {fields[0]!r}, want {want_id} (line: {want})")
if not re.match(r"^\$?\d+(\.\d+)?$", fields[1]) \
        or abs(float(fields[1].lstrip("$")) - want_total) >= 0.01:
    lib.refuse(f"total {fields[1]!r}, want {want_total} (line: {want})")
if fields[2] != str(want_count):
    lib.refuse(f"item count {fields[2]!r}, want {want_count} (line: {want})")
if fields[3] != want_date:
    lib.refuse(f"delivery date {fields[3]!r}, want {want_date} (line: {want})")
lib.emit(1.0, f"answer matches the seeded order: {want}")
