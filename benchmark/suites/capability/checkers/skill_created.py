#!/usr/bin/env python3
"""Checker (json): the agent must skill_create a new skill, reload, and write its CURRENT
skill list to skills.txt. Passing needs BOTH halves: the listing proves the agent observed
the skill live after a reload, and the skill's SKILL.md under the daemon home proves the
creation actually happened — ground truth, not the model's claim (a listing alone could be
written without creating anything)."""
import json
import os
import sys

ws = os.environ["FERMIX_EVAL_WORKSPACE"]
home = os.environ["FERMIX_EVAL_HOME"]
try:
    txt = open(os.path.join(ws, "skills.txt")).read().lower()
except OSError as exc:
    print(json.dumps({"score": 0.0, "detail": f"no skills.txt: {exc}"}))
    sys.exit(0)
listed = "eval-echo" in txt or "eval_echo" in txt
on_disk = any(
    os.path.isfile(os.path.join(home, "skills", name, "SKILL.md"))
    for name in ("eval-echo", "eval_echo"))
if not listed:
    print(json.dumps({"score": 0.0, "detail": "eval-echo NOT in listing"}))
elif not on_disk:
    print(json.dumps({"score": 0.0,
                      "detail": "eval-echo listed but its SKILL.md is not on disk "
                                "(claim without creation)"}))
else:
    print(json.dumps({"score": 1.0, "detail": "eval-echo listed and SKILL.md on disk (skill live)"}))
