#!/usr/bin/env python3
"""Checker (json): the agent must reach the deferred `shipment_status` tool of the
halden_ops fixture MCP server and report what it returned for THIS trial's
tracking number.

The server derives carrier and delivery date from the tracking number
(`halden_ops.shipment_facts`, imported here so server and grader cannot drift),
and the runner substitutes a fresh tracking number per trial, so the facts cannot
be guessed or remembered. Passing needs both halves:

  1. a successful `mcp_halden_ops_shipment_status` span whose result is for this
     tracking number (the tool was discovered and called; the route does not
     matter: direct, tool_describe first, or tool_search first);
  2. the reply names the carrier and the delivery date (ISO or a written date).
"""
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

sys.path.insert(0, lib.repo_path("fixtures", "mcp"))
import halden_ops  # noqa: E402

TOOL = "mcp_halden_ops_shipment_status"
MONTHS = ("january", "february", "march", "april", "may", "june", "july", "august",
          "september", "october", "november", "december")


def date_pattern(iso):
    """Every common spelling of one date: 2027-04-07, April 7, Apr. 07, April 7th,
    7 April, the 7th of April, 4/7, 04/07. Word boundaries keep 4/1 from matching 4/12."""
    _year, month, day = (int(part) for part in iso.split("-"))
    name = MONTHS[month - 1]
    word = rf"(?:{name}|{name[:3]}\.?)"
    num = rf"0?{day}(?:st|nd|rd|th)?"
    forms = [re.escape(iso), rf"{word}\s+{num}\b", rf"\b{num}\s+(?:of\s+)?{word}\b",
             rf"\b0?{month}/0?{day}\b"]
    return re.compile("|".join(forms), re.IGNORECASE)


ev = lib.evidence()
token = ev.get("token")
if not isinstance(token, str) or not token:
    lib.refuse("evidence carries no trial token")
facts = halden_ops.shipment_facts(token)

results = [lib.span_result(s) or {} for s in lib.spans(ev, TOOL)]
if not any(str(r.get("tracking_id", "")).upper() == token.upper() for r in results):
    attempted = len(lib.spans(ev, TOOL, status=None))
    lib.refuse(f"no successful {TOOL} result for this tracking number "
               f"({attempted} attempted; a span without output means trace content "
               "capture is off)")

reply = (ev.get("reply") or "").lower()
if facts["carrier"].lower() not in reply:
    lib.refuse(f"reply does not name the carrier {facts['carrier']!r}")
if not date_pattern(facts["eta"]).search(reply):
    lib.refuse(f"reply does not give the delivery date {facts['eta']}")
lib.emit(1.0, f"{facts['carrier']}, {facts['eta']} reported from the deferred tool")
