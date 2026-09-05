#!/usr/bin/env python3
"""Checker (json) for the seeded-file expense task. The agent must READ expenses.csv,
handle the traps (refund parentheses = negative, quoted thousands-separator, a duplicate
header row, case/space-insensitive "Groceries" match) and write the groceries total to
answer.txt.

The gold is COMPUTED from the seeded csv at check time rather than hardcoded, so it
tracks a changed or randomized fixture and cannot be memorized by a model iterating on
the eval. The prompt says "write ONLY the number", and that is graded as written: exactly
one non-empty line holding a number (the shared ONLY/EXACTLY contract in
_checkerlib.sole_line). A prose sentence around the right value fails — the task was to
produce a machine-readable answer, and a downstream reader cannot use "the total is ...".

One deliberate leniency inside that line: a leading currency symbol and thousands
separators are stripped before the number is read, so "$1,419.35" scores. The prompt
asks for no symbol, so this is graded slightly in the model's favour; the line shape is
what the artifact contract is really about.
"""
import csv
import os
import re
import sys

sys.dont_write_bytecode = True          # never drop __pycache__ into the repo checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

CATEGORY = "groceries"


def amount(raw):
    """One Amount cell: parentheses mean a refund (negative), and the thousands
    separator and currency symbol are noise."""
    text = raw.strip().replace(",", "").replace("$", "")
    negative = text.startswith("(") and text.endswith(")")
    if negative:
        text = text[1:-1]
    value = float(text)
    return -value if negative else value


def gold(path):
    """Total of every Groceries row in the seeded csv (repeated header rows and
    near-miss categories excluded)."""
    total = 0.0
    with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.reader(fh):
            if len(row) < 4 or row[1].strip().lower() != CATEGORY:
                continue
            total += amount(row[3])
    return round(total, 2)


ws = lib.workspace()
csv_path = os.path.join(ws, "expenses.csv")
if not os.path.isfile(csv_path):
    lib.refuse("seeded expenses.csv is missing — the answer cannot be graded")
try:
    want = gold(csv_path)
except (OSError, ValueError) as exc:
    lib.refuse(f"cannot compute the gold from the seeded expenses.csv: {exc}")

answer_path = os.path.join(ws, "answer.txt")
if not os.path.isfile(answer_path):
    lib.refuse("no answer.txt")
line = lib.sole_line(answer_path, "answer.txt").replace(",", "").replace("$", "").strip()
if not re.match(r"^-?\d+(\.\d+)?$", line):
    lib.refuse(f"answer.txt must hold ONLY the number, got {line[:60]!r}")

got = float(line)
if abs(got - want) >= 0.01:
    lib.refuse(f"got {got}, want {want}")
lib.emit(1.0, f"got {got}, want {want}")
