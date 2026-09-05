#!/usr/bin/env python3
"""Checker (json mode) for the multi-constraint email task.

Scores 8 constraints, each SENTENCE-LEVEL rather than token-level: an instruction like
"note it hasn't worked since November 3" is met by a sentence that says so, not by the
string "Nov 3" appearing somewhere.

Constraints (score = met / 8):
  1. the greeting is its own line addressed to Mr. Adeyemi;
  2. the sign-off is its own line;
  3. the greeting precedes the sign-off (email shape, not a shuffled list);
  4. a request sentence naming the heating issue AND a politeness marker;
  5. a sentence stating the November 3 date;
  6. a sentence giving the 14-day deadline;
  7. a sentence cites lease clause 14.2 (the bare string is a token, not a citation);
  8. the length reads as a letter: at least MIN_BODY_WORDS words and under 150.

Three structural rules, none of them a vocabulary allowlist, are what separate a letter
from a keyword blob. A word count alone did not: a three-line, sixteen-word blob whose
middle line was "heating please Nov 3 14.2 14 days filler filler filler filler filler"
scored 8/8, because it cleared MIN_SENTENCE_WORDS on token count.

  * Only the lines BETWEEN the greeting and the sign-off can satisfy 4-6. Content
    outside the letter body is not in the letter.
  * A unit padded to length is not prose (`is_prose`): repeating one word, or reusing
    so few distinct words that the unit is mostly repetition, disqualifies it. This
    tests the shape of the padding rather than guessing which words a real letter uses
    — a verb allowlist is the `reply_matches` trap the repo has already been bitten by
    twice, and "filler filler filler" defeats an alphabetic-token ratio outright.
  * A formal email that satisfies seven substantive requirements in fewer than
    MIN_BODY_WORDS words is not one.
"""
import os
import re
import sys

sys.dont_write_bytecode = True          # never drop __pycache__ into the repo checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

MIN_SENTENCE_WORDS = 8
MIN_BODY_WORDS = 25         # below this, seven requirements cannot have been written out
MAX_BODY_WORDS = 150        # the task's own cap
MAX_WORD_REPEATS = 2        # one word three times in a sentence is padding, not prose
MIN_DISTINCT_RATIO = 0.6    # distinct / total content words in a prose unit
GREETING = r"^dear\s+mr\.?\s+adeyemi\s*[,.:!]?$"
# A closing STARTS the line; a name may follow it ("Sincerely, Sam"). Requiring the
# closing to be the whole line rejected standard formal forms the task never forbade.
SIGNOFF = (r"^(sincerely|regards|kind regards|best|best regards|yours sincerely|"
           r"yours faithfully|many thanks|thank you|thanks)\b")
# An explicit, courteous ask — "please"/"kindly", or an actual request verb. A model that
# writes "I am writing to request that the heating be repaired" has made the request
# explicit; demanding a fixed phrase would fail correct prose (the reply_matches trap).
POLITE = r"(?i)(please|kindly|would you|request|asking you|i ask|appreciate|grateful)"
ISSUE = r"(?i)heat(ing|er)\b"
DATE = r"(?i)nov(ember)?\.?\s*3(rd)?\b"
DEADLINE = r"(?i)((14|fourteen)[\s-]+day|two[\s-]+weeks)"


def sentences(body):
    """Sentence-ish units, splitting on sentence enders and newlines while keeping
    decimals (clause 14.2) intact."""
    parts = re.split(r"(?<!\d)[.!?]+(?!\d)|\n", body)
    return [p.strip() for p in parts if p.strip()]


def line_index(lines, pattern):
    """Index of the first line that IS the given thing (not merely contains it), or
    -1. Matching whole lines is what a stuffed one-liner cannot fake."""
    for i, line in enumerate(lines):
        if re.match(pattern, line.strip().lower()):
            return i
    return -1


def is_prose(unit):
    """A unit long enough AND varied enough to be a sentence rather than padding.

    Token COUNT alone was the whole gate, so "… filler filler filler filler filler"
    cleared it. Two shape tests replace it, neither of which names a word a letter is
    supposed to contain: no content word may repeat more than MAX_WORD_REPEATS times,
    and the unit's distinct-to-total content-word ratio must clear MIN_DISTINCT_RATIO."""
    if len(unit.split()) < MIN_SENTENCE_WORDS:
        return False
    content = [w for w in re.findall(r"[a-z']{3,}", unit.lower())]
    if not content:
        return False
    counts = {}
    for token in content:
        counts[token] = counts.get(token, 0) + 1
    if max(counts.values()) > MAX_WORD_REPEATS:
        return False
    return len(counts) / float(len(content)) >= MIN_DISTINCT_RATIO


def sentence_with(units, *patterns):
    """True when one sentence satisfies every pattern and reads as prose."""
    return any(all(re.search(p, unit) for p in patterns)
               for unit in units if is_prose(unit))


def body_lines(lines, greeting_at, signoff_at):
    """The lines BETWEEN the greeting and the sign-off — the letter itself. Content
    outside them is not in the letter.

    A missing greeting starts the body at line 0 and a missing sign-off runs it to the
    end, so a letter closing with a form this checker's allowlist does not know still
    has its body graded. Making an unrecognized closing collapse the body to nothing
    would put an eight-point cliff behind a phrase list — the allowlist trap the
    greeting and sign-off constraints themselves are careful to avoid."""
    start = greeting_at + 1                                 # 0 when there is none
    end = signoff_at if signoff_at >= 0 else len(lines)
    return lines[start:end] if start < end else []


ws = lib.workspace()
email_path = os.path.join(ws, "email.txt")
if not os.path.isfile(email_path):
    lib.refuse("no email.txt")
body = lib.read_text(email_path, "email.txt")
lines = body.splitlines()
greeting_at = line_index(lines, GREETING)
signoff_at = line_index(lines, SIGNOFF)
units = sentences("\n".join(body_lines(lines, greeting_at, signoff_at)))
words = len(body.split())

constraints = {
    "greeting_line": greeting_at >= 0,
    "signoff_line": signoff_at >= 0,
    "greeting_before_signoff": 0 <= greeting_at < signoff_at,
    "requests_repair_politely": sentence_with(units, ISSUE, POLITE),
    "states_since_nov_3": sentence_with(units, DATE),
    "gives_14_day_deadline": sentence_with(units, DEADLINE),
    "cites_clause_14_2": sentence_with(units, r"\b14\.2\b"),
    "letter_length": MIN_BODY_WORDS <= words < MAX_BODY_WORDS,
}

met = sum(1 for value in constraints.values() if value)
missing = sorted(k for k, value in constraints.items() if not value)
lib.emit(met / float(len(constraints)),
         f"{met}/{len(constraints)} constraints; missing={missing}")
