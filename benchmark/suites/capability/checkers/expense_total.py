#!/usr/bin/env python3
"""Checker (json) for the seeded-file expense task. The agent must READ expenses.csv,
handle the traps (refund parentheses = negative, quoted thousands-separator, a
duplicate header row, case/space-insensitive "Groceries" match) and write the
groceries total to answer.txt. Grades that number (gold 1419.35, computed:
84.20+52.10+210.00-18.75+67.30+1024.50)."""
import json
import os
import re
import sys

ws = os.environ["FERMIX_EVAL_WORKSPACE"]
try:
    with open(os.path.join(ws, "answer.txt")) as fh:
        text = fh.read()
except OSError as exc:
    print(json.dumps({"score": 0.0, "detail": f"no answer.txt: {exc}"}))
    sys.exit(0)

nums = []
for tok in re.findall(r"-?\d*\.?\d+", text.replace(",", "").replace("$", "")):
    try:
        nums.append(float(tok))
    except ValueError:
        pass
if not nums:
    print(json.dumps({"score": 0.0, "detail": f"no number in answer.txt: {text[:80]!r}"}))
    sys.exit(0)

got = nums[-1]                                   # the answer is the (only/last) number
ok = abs(got - 1419.35) < 0.01
print(json.dumps({"score": 1.0 if ok else 0.0, "detail": f"got {got}, want 1419.35"}))
