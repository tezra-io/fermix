#!/usr/bin/env python3
"""Checker (json): the agent must leave a set of drafts, one file per recipient, in a
folder of the trial workspace. Gold (`checker.expect`):

  dir      folder under the workspace the drafts go in
  groups   one list of terms per expected draft; each list must match exactly ONE
           file (all its terms present), and every file must match exactly one list
  exclude  terms no draft may contain (e.g. a rest day that is not a dive day)

So "one email per shop" with one shop on two days is two files, not three, and a
draft that books the wrong day fails. Terms match case-insensitively on word
boundaries (`_checkerlib.term_present`).
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

present = lib.term_present

ev = lib.evidence()
gold = lib.expected(ev)
folder = os.path.join(lib.workspace(), gold["dir"])
if not os.path.isdir(folder):
    lib.refuse(f"no {gold['dir']}/ folder of drafts")
drafts = {name: lib.read_text(os.path.join(folder, name), name)
          for name in sorted(os.listdir(folder))
          if os.path.isfile(os.path.join(folder, name)) and not name.startswith(".")}
groups = gold["groups"]
if len(drafts) != len(groups):
    lib.refuse(f"{len(drafts)} draft(s), want {len(groups)} (one per recipient)")
for name, text in drafts.items():
    matching = [g for g in groups if all(present(text, t) for t in g)]
    if len(matching) != 1:
        lib.refuse(f"{name} matches {len(matching)} recipient(s), want exactly one")
    banned = [t for t in gold.get("exclude", []) if present(text, t)]
    if banned:
        lib.refuse(f"{name} contains {banned}")
for group in groups:
    if sum(all(present(text, t) for t in group) for text in drafts.values()) != 1:
        lib.refuse(f"no single draft covers {group}")
lib.emit(1.0, f"{len(drafts)} drafts, one per recipient")
