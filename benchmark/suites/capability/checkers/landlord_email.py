#!/usr/bin/env python3
"""Checker (json mode) for the multi-constraint email task. Scores the fraction of 8
content constraints met (IFEval-style), GATED by structural well-formedness so a
keyword-stuffed blob that merely name-drops every constraint token can't score high —
it must actually read like an email (salutation before closing, real prose length)."""
import json
import os
import re
import sys

ws = os.environ["FERMIX_EVAL_WORKSPACE"]
try:
    with open(os.path.join(ws, "email.txt")) as fh:
        body = fh.read()
except OSError as exc:
    print(json.dumps({"score": 0.0, "detail": f"no email.txt: {exc}"}))
    sys.exit(0)

words = len(body.split())
content = {
    "requests_heating_repair": re.search(r"(?i)heat(ing|er)", body) is not None,
    # accept "November 3", "Nov. 3", and the idiomatic "November 3rd" (the \b after 3
    # previously rejected "3rd" — a natural correct phrasing scored a false miss)
    "states_since_nov_3": re.search(r"(?i)nov(ember)?\.?\s*3(rd)?\b", body) is not None,
    "cites_clause_14_2": "14.2" in body,
    "addresses_mr_adeyemi": re.search(r"(?i)dear\s+mr\.?\s+adeyemi", body) is not None,
    # accept "14 days", "fourteen days", and the hyphenated "14-day deadline"
    "gives_14_day_deadline": re.search(r"(?i)(14|fourteen)[\s-]+day|two[\s-]+weeks", body) is not None,
    "polite_closing": re.search(r"(?i)(sincerely|regards|thank you|best,)", body) is not None,
    "clear_request": re.search(r"(?i)(please|kindly|would you|i request|i am requesting)", body) is not None,
    "under_150_words": words < 150,
}

# Structural gate: a real email, not a keyword list. A stuffed blob fails these even
# when it hits every content token, so it can never clear the bar.
salut = re.search(r"(?i)dear\s+mr\.?\s+adeyemi", body)
close = re.search(r"(?i)(sincerely|regards|best,|thank you)", body)
structure_ok = (
    words >= 25                                  # prose, not a short token list
    and len(re.findall(r"[.!?]", body)) >= 2     # multiple sentences
    and salut is not None and close is not None
    and salut.start() < close.start()            # salutation before closing (email shape)
)

met = sum(1 for v in content.values() if v)
missing = [k for k, v in content.items() if not v]
raw = met / len(content)
score = raw if structure_ok else raw * 0.3       # gate malformed junk far below a real email
print(json.dumps({"score": round(score, 3),
                  "detail": f"{met}/{len(content)} constraints "
                            f"(structure={'ok' if structure_ok else 'MALFORMED'}); missing={missing}"}))
