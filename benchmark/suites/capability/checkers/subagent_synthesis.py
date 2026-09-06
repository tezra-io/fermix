#!/usr/bin/env python3
"""Checker (json): the agent must fan out to parallel subagents over the four seeded
subsystem files and synthesize ONE summary covering all four.

Presence of the four codenames is not synthesis — `FALCON-G7 OTTER-M3 HERON-S9 BADGER-X2`
used to score 1.0 with no role or team anywhere. Grading is per subsystem, on the
sentence that carries its codename:

  * the sentence must also carry that subsystem's owner team or a distinctive term from
    its role line (detail actually survived the fan-out and the synthesis);
  * a TEAM claim must not be negated: a sentence denying the subsystem's OWN team
    ("FALCON-G7 is not owned by Platform") zeroes it exactly as a foreign attribution
    does, because both are false claims about it. The negation test is
    scoped to a short window before the team word and is never applied to role terms:
    two of the four role lines are inherently negative ("cannot see the creating chat",
    "protected paths always denied"), so a whole-sentence negation test scored a
    faithful paraphrase of them as a denial;
  * any sentence attributing a FOREIGN team to the codename scores that subsystem 0 even
    if a correct sentence exists elsewhere — a summary that says both has established
    nothing.

Only sentences naming exactly ONE codename are graded. A merged sentence naming two
cannot attribute a team or a role to either of them, so it is evidence for neither
rather than a contradiction against both; a subsystem that appears only inside such
sentences scores 0 with that reason.

Score = correct subsystems / 4.

The gold is read from the SEEDED files at check time, so it cannot be memorized from an
earlier sweep and it follows a changed fixture. Because the agent can write in its own
workspace, each seeded file is compared byte-for-byte with the repo fixture first: a
missing or edited source means the summary cannot be graded, and the checker refuses
(score 0, with the reason) rather than grading against the model's own edit.
"""
import os
import re
import sys

sys.dont_write_bytecode = True          # never drop __pycache__ into the repo checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

FIXTURE = ("fixtures", "agentic", "subsystems")
FILES = ("gateway.txt", "memory.txt", "scheduler.txt", "sandbox.txt")
NEGATIONS = (r"\bnot\b", r"\bisn't\b", r"\bis not\b", r"\bno longer\b",
             r"\bincorrect\b", r"\bwrong\b")
NEGATION_WINDOW = 40        # characters before a team word that can negate the claim
STOPWORDS = {"that", "with", "this", "from", "into", "them", "they", "their", "when",
             "each", "also", "always", "than", "then", "some", "over", "under", "which",
             "cannot", "runs", "role", "team", "owner", "subsystem", "internal",
             "codename"}


def parse(text, source):
    """Codename, owner team and role line out of one seeded subsystem file."""
    code = re.search(r"(?i)internal codename:\s*([A-Z0-9-]+)", text)
    team = re.search(r"(?i)owner team:\s*([A-Za-z]+)", text)
    role = re.search(r"(?i)^role:\s*(.+)$", text, re.M)
    if not (code and team and role):
        lib.refuse(f"seeded {source} is not a subsystem file (no codename/team/role)")
    return {"code": code.group(1).upper(), "team": team.group(1).lower(),
            "role": role.group(1).lower(), "source": source}


def load_gold(ws):
    """Read the four seeded files, refusing unless each is byte-identical to the
    repo fixture it was seeded from."""
    gold = []
    for name in FILES:
        seeded, repo = os.path.join(ws, name), lib.repo_path(*(FIXTURE + (name,)))
        if not os.path.isfile(seeded):
            lib.refuse(f"seeded {name} is missing — the summary cannot be graded")
        if lib.read_text(seeded, name) != lib.read_text(repo, "fixture " + name):
            lib.refuse(f"seeded {name} was altered in the workspace — refusing to "
                       "grade against a rewritten source")
        gold.append(parse(lib.read_text(seeded, name), name))
    return gold


def role_terms(gold):
    """Per subsystem, the role words that belong to it alone — so a match is real
    detail retention, not vocabulary shared by every subsystem."""
    words = [set(w for w in re.findall(r"[a-z]{4,}", g["role"]) if w not in STOPWORDS)
             for g in gold]
    return [w - set().union(*(words[:i] + words[i + 1:])) for i, w in enumerate(words)]


def units(text):
    """Sentence-ish units: lines split on sentence enders and semicolons.

    The terminator must be followed by whitespace or end-of-text. That keeps decimals
    ("1.5h") and hyphenated codenames intact for the same reason the old rule did, but
    without refusing to split after a DIGIT — every codename ends in one, so
    "…codename is FALCON-G7. The memory…" was one unit and each sentence then read as
    naming every other subsystem's team."""
    parts = re.split(r"[.!?;]+(?=\s|$)|\n", text)
    return [p.strip().lower() for p in parts if p.strip()]


def word(text):
    """A whole-word pattern, so "platform" doesn't match inside "platforms-team"."""
    return r"\b" + re.escape(text) + r"\b"


def has(unit, patterns):
    return any(re.search(p, unit) for p in patterns)


def team_mention(unit, team):
    """How this unit mentions `team`: None (absent), "claim" (attributed) or "denial"
    (negated). The negation test looks only at the text immediately BEFORE the team
    word — applying it to the whole unit made every faithful paraphrase of the
    scheduler's and sandbox's negative role lines read as a denial of the team."""
    found = re.search(word(team), unit)
    if found is None:
        return None
    before = unit[max(0, found.start() - NEGATION_WINDOW):found.start()]
    return "denial" if has(before, NEGATIONS) else "claim"


def sole_codename_units(summary_units, gold, index):
    """Units naming THIS codename and no other. A merged sentence attributes nothing to
    either subsystem, so it is not evidence and not a contradiction."""
    code = gold[index]["code"].lower()
    others = [g["code"].lower() for i, g in enumerate(gold) if i != index]
    return [u for u in summary_units
            if code in u and not any(other in u for other in others)]


def score_subsystem(summary_units, gold, terms, index):
    code = gold[index]["code"].lower()
    mine = sole_codename_units(summary_units, gold, index)
    if not mine:
        if any(code in u for u in summary_units):
            return 0, "only named alongside another subsystem"
        return 0, "absent"
    foreign_teams = [gold[o]["team"] for o in range(len(gold)) if o != index]
    if any(team_mention(u, team) == "claim" for u in mine for team in foreign_teams):
        return 0, "attributed to another subsystem's team"
    own_team = gold[index]["team"]
    if any(team_mention(u, own_team) == "denial" for u in mine):
        # A false claim about the subsystem, exactly as damaging as a foreign one.
        return 0, "denies its own owner team"
    own_terms = [word(t) for t in sorted(terms[index])]
    confirmed = [u for u in mine
                 if team_mention(u, own_team) == "claim" or has(u, own_terms)]
    if not confirmed:
        return 0, "codename without its role or team"
    return 1, "ok"


ws = lib.workspace()
summary_path = os.path.join(ws, "summary.txt")
if not os.path.isfile(summary_path):
    lib.refuse("no summary.txt")
gold = load_gold(ws)
terms = role_terms(gold)
summary_units = units(lib.read_text(summary_path, "summary.txt"))

results = [score_subsystem(summary_units, gold, terms, i) for i in range(len(gold))]
correct = sum(point for point, _why in results)
detail = ", ".join(f"{gold[i]['code']}={results[i][1]}" for i in range(len(gold)))
lib.emit(correct / float(len(gold)), f"{correct}/{len(gold)} subsystems: {detail}")
