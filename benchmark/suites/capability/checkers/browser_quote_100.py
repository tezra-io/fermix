#!/usr/bin/env python3
"""Checker (json) for the browser quote task (qty=100). The agent must drive the JS
web-app (open the file, enter the quantity, click Get Quote — the total is COMPUTED by JS,
not a static value) and write the shown total to answer.txt. Grades that number."""
import json, os, re, sys
ws = os.environ["FERMIX_EVAL_WORKSPACE"]
try:
    with open(os.path.join(ws, "answer.txt")) as fh:
        text = fh.read()
except OSError as exc:
    print(json.dumps({"score": 0.0, "detail": f"no answer.txt: {exc}"})); sys.exit(0)
nums = [float(t) for t in re.findall(r"-?\d*\.?\d+", text.replace(",", "").replace("$", "")) if t not in (".", "-")]
ok = any(abs(n - 1000.00) < 0.01 for n in nums)
print(json.dumps({"score": 1.0 if ok else 0.0, "detail": f"want 1000.00, got {nums}"}))
