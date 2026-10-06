#!/usr/bin/env python3
"""Checker (json): the final reply's terms against the task's gold (`checker.expect`):

  include_all  every term must appear
  include_any  at least one term must appear
  exclude      no term may appear

Matching is case-insensitive; a term that starts or ends with a letter or digit is
matched on word boundaries (`_checkerlib.term_present`), so "9" does not match "19".
The gold comes from the
evidence file (never from the workspace), so a private task's answer stays out of the
agent's reach. For tasks where the right answer is a FACT the reply must carry or a
claim it must not make; wording and tone belong to a judge rubric instead.
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402


ev = lib.evidence()
gold = lib.expected(ev)
reply = ev.get("reply") or ""
missing = [t for t in gold.get("include_all", []) if not lib.term_present(reply, t)]
if missing:
    lib.refuse(f"reply lacks {missing}")
anyof = gold.get("include_any", [])
if anyof and not any(lib.term_present(reply, t) for t in anyof):
    lib.refuse(f"reply has none of {anyof}")
banned = [t for t in gold.get("exclude", []) if lib.term_present(reply, t)]
if banned:
    lib.refuse(f"reply contains {banned}")
lib.emit(1.0, "reply carries the required terms and none of the excluded ones")
