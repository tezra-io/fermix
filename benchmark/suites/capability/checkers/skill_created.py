#!/usr/bin/env python3
"""Checker (json): the agent must author the `eval-echo` skill, reload so it is live,
and write its CURRENT skill list to skills.txt.

Every half is verified against something the model cannot write for itself:

  * skills.txt contains a line that IS `eval-echo` (exact after stripping a list marker,
    strip/lower) — a substring match passed notes like "(eval-echo could not be created)";
  * <home>/skills/eval-echo/SKILL.md exists and its body instructs ECHO (case-sensitive
    word) — a stale SKILL.md from an earlier sweep with a different body is not this
    task's deliverable;
  * the evidence record shows a successful skill_create whose OUTPUT names eval-echo, and
    a successful skill_reload that STARTS AFTER it — a reload before the create cannot
    have registered anything, and a hand-written SKILL.md has no skill_create at all.

The create span is matched on its OUTPUT (`{"path":"/…/skills/eval-echo","created":true}`)
because skill_create runs through `FermixCore.Tools.Support.run/3`, which records no input
at all: matching the input refused every real trial, the reference solution included.

Baseline absence is the RUNNER's job: the case declares `checker.reset: [skills/eval-echo]`
so each trial starts without the skill. This checker never deletes daemon state.
"""
import os
import re
import sys

sys.dont_write_bytecode = True          # never drop __pycache__ into the repo checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

NAMES = ("eval-echo", "eval_echo")
# "one per line" is the instruction; a bulleted or numbered rendering of that list is
# the same listing, so the marker is stripped before the exact-name comparison. Prose
# ("(eval-echo could not be created)") still fails, which is the point of the equality.
_LIST_MARKER = re.compile(r"^(?:[-*\u2022]\s+|\d+[.)]\s+)")


def _listed(line):
    return _LIST_MARKER.sub("", line.strip()).strip().lower()


ws = lib.workspace()
home = os.environ["FERMIX_EVAL_HOME"]
ev = lib.evidence()

listing_path = os.path.join(ws, "skills.txt")
if not os.path.isfile(listing_path):
    lib.refuse("no skills.txt (the live skill listing was never written)")
lines = [_listed(ln) for ln in lib.read_text(listing_path, "skills.txt").splitlines()]
if not any(ln in NAMES for ln in lines):
    lib.refuse(f"eval-echo is not a line in the listing ({len(lines)} lines)")

md = [os.path.join(home, "skills", name, "SKILL.md") for name in NAMES]
present = [p for p in md if os.path.isfile(p)]
if not present:
    lib.refuse("eval-echo listed but its SKILL.md is not on disk (claim without creation)")
body = lib.read_text(present[0], "SKILL.md")
if not re.search(r"\bECHO\b", body):
    lib.refuse("SKILL.md does not instruct ECHO (wrong or stale skill body)")

creates = [s for s in lib.spans(ev, "skill_create")
           if any(name in lib.span_output(s).lower() for name in NAMES)]
if not creates:
    lib.refuse("no successful skill_create span naming eval-echo (the skill was not "
               "created through the skill tools)")
create_starts = [t for t in (lib.span_start(s) for s in creates) if t is not None]
if not create_starts:
    lib.refuse("skill_create span has no usable start_time — ordering unverifiable")
create_start = min(create_starts)

reloads = [s for s in lib.spans(ev, "skill_reload")
           if lib.span_start(s) is not None and lib.span_start(s) >= create_start]
if not reloads:
    lib.refuse("no successful skill_reload span after the skill_create (the skill was "
               "never made live)")

lib.emit(1.0, f"eval-echo created, reloaded and listed live ({len(creates)} create, "
         f"{len(reloads)} reload spans)")
