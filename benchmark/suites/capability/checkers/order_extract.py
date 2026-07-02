#!/usr/bin/env python3
"""Checker (json) for the seeded-file order-extraction task. The agent must READ
order.txt and write ONE line to answer.txt in <order_id>|<total>|<item_count>|<date>.
Traps: total_charged (94.74) not subtotal (80.50); item_count = 2+1+3 = 6 (sum of
quantities) not 3 line items; date normalized to 2026-03-03."""
import json
import os
import re
import sys

ws = os.environ["FERMIX_EVAL_WORKSPACE"]
try:
    with open(os.path.join(ws, "answer.txt")) as fh:
        text = fh.read().strip()
except OSError as exc:
    print(json.dumps({"score": 0.0, "detail": f"no answer.txt: {exc}"}))
    sys.exit(0)

ok = re.search(r"(?i)\bNW-48213\s*\|\s*\$?\s*94\.74\s*\|\s*6\s*\|\s*2026-03-03\b", text) is not None
print(json.dumps({"score": 1.0 if ok else 0.0, "detail": f"answer={text[:120]!r}"}))
