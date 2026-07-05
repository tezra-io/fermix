#!/usr/bin/env python3
"""Checker (json): the agent must skill_create a new skill, reload, and write its CURRENT
skill list to skills.txt — so the new skill appearing there proves the self-modification
both happened AND took effect live (registered without a restart)."""
import json
import os
import sys

ws = os.environ["FERMIX_EVAL_WORKSPACE"]
try:
    txt = open(os.path.join(ws, "skills.txt")).read().lower()
except OSError as exc:
    print(json.dumps({"score": 0.0, "detail": f"no skills.txt: {exc}"}))
    sys.exit(0)
ok = "eval-echo" in txt or "eval_echo" in txt
print(json.dumps({"score": 1.0 if ok else 0.0,
                  "detail": f"eval-echo {'listed (skill live)' if ok else 'NOT in listing'}"}))
