#!/usr/bin/env python3
"""Checker (json): the agent must file three receipts the way the eval home's
`receipt-filing` skill says, which it can only know by opening that skill: the
prompt carries only a one-line description of it.

The skill's rules are unguessable on purpose: a per-month sheet at
expenses/YYYY-MM.csv, a semicolon-separated header `date;vendor;amount_cents;code`,
integer cents, and finance codes (meals M2, rides T7, software S4). The sheet must
hold exactly the three receipts, once each; vendor case does not matter.
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

HEADER = "date;vendor;amount_cents;code"
WANT = {("2027-03-02", "blue fern cafe", "1840", "M2"),
        ("2027-03-02", "ridewell", "2310", "T7"),
        ("2027-03-05", "draftboard", "1500", "S4")}

sheet = os.path.join(lib.workspace(), "expenses", "2027-03.csv")
if not os.path.isfile(sheet):
    lib.refuse("no expenses/2027-03.csv in the expense folder")
lines = [ln.strip() for ln in lib.read_text(sheet, "the March sheet").splitlines() if ln.strip()]
if not lines or lines[0] != HEADER:
    lib.refuse(f"first line is {lines[0][:60] if lines else ''!r}, want {HEADER!r}")
rows = []
for line in lines[1:]:
    fields = [f.strip() for f in line.split(";")]
    if len(fields) != 4:
        lib.refuse(f"row is not four semicolon-separated fields: {line[:60]!r}")
    rows.append((fields[0], fields[1].lower(), fields[2], fields[3]))
if len(rows) != len(set(rows)):
    lib.refuse("a receipt was filed twice")
if set(rows) != WANT:
    missing, extra = sorted(WANT - set(rows)), sorted(set(rows) - WANT)
    lib.refuse(f"rows differ from the receipts: missing {missing[:2]}, unexpected {extra[:2]}")
lib.emit(1.0, "three receipts filed as the skill specifies")
