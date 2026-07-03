#!/usr/bin/env python3
"""Checker (json): the agent must delegate reading/summarizing the 4 seeded subsystem
files to parallel subagents, then synthesize a combined summary to summary.txt covering
ALL FOUR. Grades that every subsystem's distinctive codename survived into the summary —
tests both delegation COVERAGE (all branches) and detail retention through synthesis.
The requires_tools:[subagents] provenance gate (runner) checks the fan-out actually fired."""
import json
import os
import sys

ws = os.environ["FERMIX_EVAL_WORKSPACE"]
try:
    with open(os.path.join(ws, "summary.txt")) as fh:
        text = fh.read().upper()
except OSError as exc:
    print(json.dumps({"score": 0.0, "detail": f"no summary.txt: {exc}"}))
    sys.exit(0)

codenames = ["FALCON-G7", "OTTER-M3", "HERON-S9", "BADGER-X2"]
present = [c for c in codenames if c in text]
print(json.dumps({"score": round(len(present) / len(codenames), 3),
                  "detail": f"{len(present)}/{len(codenames)} subsystems present: {present}"}))
