#!/usr/bin/env python3
"""Checker (json): a file in the eval home must hold an exact value after the turn.
Gold (`checker.expect`): `path` (relative to the eval home) and `equals` (the file's
stripped content). For actions whose only trace is the state a local script leaves,
e.g. a fixture skill that "opens the garage" by writing workspace/garage.state. The
case should declare the same path under `checker.reset`, so a previous trial's state
cannot pass this one.
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

ev = lib.evidence()
gold = lib.expected(ev)
path = os.path.join(os.environ["FERMIX_EVAL_HOME"], gold["path"])
if not os.path.isfile(path):
    lib.refuse(f"no {gold['path']} (the action never ran)")
value = lib.read_text(path, gold["path"]).strip()
if value != gold["equals"]:
    lib.refuse(f"{gold['path']} holds {value[:40]!r}, want {gold['equals']!r}")
lib.emit(1.0, f"{gold['path']} = {gold['equals']}")
