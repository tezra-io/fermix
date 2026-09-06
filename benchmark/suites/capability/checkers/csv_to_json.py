#!/usr/bin/env python3
"""Checker (json mode) for the CSV->JSON task. Computes the expected region totals
AND descending order FROM the seeded sales.csv (no hardcoded gold — so it auto-adapts
if the fixture is changed/randomized and can't be memorized by an eval-iterating
agent), then compares the agent-written sales_by_region.json. Partial credit:
per-region value match, with an order penalty.

Same artifact contract as the other seeded-file tasks (expense_total, order_extract):
the object must contain the seeded regions and NOTHING else. A key that is not a seeded
region is fabrication — an invented "Mars" total is worse than a missing one — and scores
0 outright rather than diluting into partial credit. A value must be a JSON number:
"89.96" is a string that every consumer of this file would have to re-parse, so it does
not count as a match."""
import csv
import json
import os
import sys


def _gold(csv_path):
    totals = {}
    with open(csv_path, newline="") as fh:
        for row in csv.DictReader(fh):
            totals[row["region"]] = totals.get(row["region"], 0.0) \
                + float(row["units"]) * float(row["unit_price"])
    # highest revenue first; region name breaks ties deterministically
    ordered = sorted(totals.items(), key=lambda kv: (-round(kv[1], 2), kv[0]))
    return [(r, round(v, 2)) for r, v in ordered]


ws = os.environ["FERMIX_EVAL_WORKSPACE"]
try:
    gold = _gold(os.path.join(ws, "sales.csv"))
except (OSError, KeyError, ValueError) as exc:
    print(json.dumps({"score": 0.0, "detail": f"cannot read seeded sales.csv: {exc}"}))
    sys.exit(0)

try:
    with open(os.path.join(ws, "sales_by_region.json")) as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print(json.dumps({"score": 0.0, "detail": f"no/invalid sales_by_region.json: {exc}"}))
    sys.exit(0)

if not isinstance(data, dict):
    print(json.dumps({"score": 0.0, "detail": "sales_by_region.json is not an object"}))
    sys.exit(0)

invented = [k for k in data if k not in {r for r, _v in gold}]
if invented:
    print(json.dumps({"score": 0.0,
                      "detail": f"invented regions not in the seeded csv: {invented[:5]}"}))
    sys.exit(0)

# A JSON string is not a total (see the module docstring): isinstance excludes it, and
# bool is excluded because `True` is an int in Python and is not a revenue figure.
matched = sum(1 for r, v in gold
              if isinstance(data.get(r), (int, float)) and not isinstance(data[r], bool)
              and abs(float(data[r]) - v) < 0.01)
order_ok = list(data.keys())[:len(gold)] == [r for r, _ in gold]
score = matched / len(gold)
if matched == len(gold) and not order_ok:
    score = 0.75            # every value right but not sorted highest-to-lowest
print(json.dumps({"score": round(score, 3),
                  "detail": f"matched {matched}/{len(gold)} regions, order={'ok' if order_ok else 'wrong'}"}))
