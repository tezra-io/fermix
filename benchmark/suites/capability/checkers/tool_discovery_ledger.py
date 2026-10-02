#!/usr/bin/env python3
"""Checker (json): the agent must record ONE expense through the deferred
`ledger_add_entry` tool of the halden_ops fixture MCP server, with the fields the
tool's schema demands.

The arguments are the hard part: the amount is integer cents and the category
comes from a fixed list. tool_describe shows types but not allowed values today,
so a model that guesses ("team lunch", 42.5) gets a validation error naming the
list and has to recover from it. The server echoes each accepted entry in its
result, which is what this checker reads:

  1. exactly one accepted entry carries this trial's receipt number in its memo
     (two would be a double booking);
  2. that entry is dated 2027-03-03, 4250 cents, category "meals".
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

TOOL = "mcp_halden_ops_ledger_add_entry"
WANT = {"date": "2027-03-03", "amount_cents": 4250, "category": "meals"}

ev = lib.evidence()
token = ev.get("token")
if not isinstance(token, str) or not token:
    lib.refuse("evidence carries no trial token")

recorded = []
for span in lib.spans(ev, TOOL):
    entry = (lib.span_result(span) or {}).get("recorded")
    if isinstance(entry, dict) and token.lower() in str(entry.get("memo", "")).lower():
        recorded.append(entry)
if not recorded:
    attempted = len(lib.spans(ev, TOOL, status=None))
    lib.refuse(f"no accepted {TOOL} entry carries the receipt number ({attempted} attempted)")
if len(recorded) > 1:
    lib.refuse(f"{len(recorded)} entries carry the receipt number: the expense was booked twice")
wrong = {k: recorded[0].get(k) for k, v in WANT.items() if recorded[0].get(k) != v}
if wrong:
    lib.refuse(f"entry recorded with {wrong}, want {WANT}")
lib.emit(1.0, "one entry, 2027-03-03, 4250 cents, meals")
