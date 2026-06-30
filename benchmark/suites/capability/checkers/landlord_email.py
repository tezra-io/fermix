#!/usr/bin/env python3
"""Checker (json mode) for the multi-constraint email task. Reads the agent-written
email.txt from the scoped workspace and scores the fraction of 8 verifiable
constraints met (IFEval-style) — each easy alone, but holding all 8 at once is
where frontier models diverge."""
import json
import os
import re
import sys

ws = os.environ["FERMIX_EVAL_WORKSPACE"]
path = os.path.join(ws, "email.txt")
try:
    with open(path) as fh:
        body = fh.read()
except OSError as exc:
    print(json.dumps({"score": 0.0, "detail": f"no email.txt: {exc}"}))
    sys.exit(0)

words = len(body.split())
checks = {
    "under_150_words": words < 150,
    "requests_heating_repair": re.search(r"(?i)heat(ing|er)", body) is not None,
    "states_since_nov_3": re.search(r"(?i)nov(ember)?\.?\s*3\b", body) is not None,
    "cites_clause_14_2": "14.2" in body,
    "addresses_mr_adeyemi": re.search(r"(?i)dear\s+mr\.?\s+adeyemi", body) is not None,
    "gives_14_day_deadline": re.search(r"(?i)(14|fourteen)\s+days|two\s+weeks", body) is not None,
    "polite_closing": re.search(r"(?i)(sincerely|regards|thank you)", body) is not None,
    "clear_request": re.search(r"(?i)(please|kindly|would you|i request|i am requesting)", body) is not None,
}
met = sum(1 for v in checks.values() if v)
missing = [k for k, v in checks.items() if not v]
print(json.dumps({"score": round(met / len(checks), 3),
                  "detail": f"{met}/{len(checks)} constraints; missing={missing}"}))
