#!/usr/bin/env python3
"""Checker (json mode) for the CSV->JSON task. Reads the agent-written
sales_by_region.json from the scoped workspace and compares region totals AND
descending order to the golden. Partial credit: per-region value match, with an
order penalty — so the three slip points (a dropped 0-revenue region, wrong order,
a miscomputed total) each cost something."""
import json
import os
import sys

GOLD = [("South", 89.96), ("North", 67.47), ("West", 47.50), ("East", 0.00)]
ws = os.environ["FERMIX_EVAL_WORKSPACE"]
path = os.path.join(ws, "sales_by_region.json")

try:
    with open(path) as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print(json.dumps({"score": 0.0, "detail": f"no/invalid sales_by_region.json: {exc}"}))
    sys.exit(0)

if not isinstance(data, dict):
    print(json.dumps({"score": 0.0, "detail": "sales_by_region.json is not an object"}))
    sys.exit(0)

matched = sum(1 for r, v in GOLD
              if isinstance(data.get(r), (int, float)) and abs(float(data[r]) - v) < 0.01)
order_ok = list(data.keys())[:4] == [r for r, _ in GOLD]
score = matched / 4.0
if matched == 4 and not order_ok:
    score = 0.75            # all values right but wrong descending order
print(json.dumps({"score": round(score, 3),
                  "detail": f"matched {matched}/4 regions, order={'ok' if order_ok else 'wrong'}"}))
