"""Ground-truth answer scoring for the capability eval tier.

Pure and deterministic: given a model's final reply and a `score:` spec, return a
0.0..1.0 task-success score. These are the closed-form, programmatically-checkable
scorers (exact / numeric / contains / regex / token-F1) that the capability sweep
prefers over an LLM judge wherever a verifiable answer exists
(docs/design/EVAL_CAPABILITY_SCORING.md §4). Open-ended tasks with no ground truth
fall back to the judge (judge.py); this module never calls a model.

This is a SEPARATE concern from the behavioral gate grader (grade.py): grade.py
answers "did the agent use the right tools / stay in budget" (pass/fail gates),
while this answers "is the final answer correct" (a numeric task-success score).
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass

# Supported closed-form match methods. Imported by suites.py so the suite schema
# and the scorer can never disagree on the vocabulary.
MATCH_METHODS: tuple[str, ...] = ("exact", "numeric", "contains", "regex", "f1")

_PUNCT_RE = re.compile(r"[^\w\s]", re.UNICODE)
_WS_RE = re.compile(r"\s+")
_NUMBER_RE = re.compile(r"-?\d[\d,]*(?:\.\d+)?")


@dataclass
class AnswerScore:
    score: float            # 0.0..1.0 task success
    method: str             # one of MATCH_METHODS
    detail: str             # human-readable, for the report row


def score_answer(reply: str, spec: dict) -> AnswerScore:
    """Score `reply` against a validated `score:` spec.

    `spec` shape (validated in suites.py before it ever reaches here):
        {"match": <method>, "expected": <str|number|list>, "tolerance"?: <number>}

    Raises ValueError on an unknown method — callers validate first, so reaching
    this is a programmer error, not user input.
    """
    method = spec.get("match")
    expected = spec.get("expected")
    if method == "exact":
        return _exact(reply, expected)
    if method == "numeric":
        return _numeric(reply, expected, spec.get("tolerance", 0))
    if method == "contains":
        return _contains(reply, expected)
    if method == "regex":
        return _regex(reply, expected)
    if method == "f1":
        return _f1(reply, expected)
    raise ValueError(f"unknown match method {method!r}; expected one of {MATCH_METHODS}")


# --- methods ----------------------------------------------------------------

def _exact(reply: str, expected) -> AnswerScore:
    got, want = _normalize(reply), _normalize(_as_text(expected))
    hit = got == want
    return AnswerScore(1.0 if hit else 0.0, "exact",
                       f"exact: {'==' if hit else '!='} expected {want!r} (got {got!r})")


def _numeric(reply: str, expected, tolerance) -> AnswerScore:
    want = _parse_number(_as_text(expected))
    got = _parse_number(reply)
    if want is None:
        return AnswerScore(0.0, "numeric", f"numeric: expected {expected!r} is not a number")
    if got is None:
        return AnswerScore(0.0, "numeric", f"numeric: no number found in reply")
    tol = float(tolerance or 0)
    hit = abs(got - want) <= tol
    return AnswerScore(1.0 if hit else 0.0, "numeric",
                       f"numeric: got {got} vs {want} (tol {tol}) -> {'ok' if hit else 'off'}")


def _contains(reply: str, expected) -> AnswerScore:
    got, want = _normalize(reply), _normalize(_as_text(expected))
    hit = want in got
    return AnswerScore(1.0 if hit else 0.0, "contains",
                       f"contains {want!r}: {'present' if hit else 'absent'}")


def _regex(reply: str, expected) -> AnswerScore:
    pattern = _as_text(expected)
    hit = re.search(pattern, reply) is not None
    return AnswerScore(1.0 if hit else 0.0, "regex",
                       f"/{pattern}/ {'matched' if hit else 'no match'}")


def _f1(reply: str, expected) -> AnswerScore:
    pred = Counter(_tokens(reply))
    gold = Counter(_tokens(_as_text(expected)))
    if not gold:
        return AnswerScore(0.0, "f1", "f1: empty expected answer")
    common = sum((pred & gold).values())
    if common == 0:
        return AnswerScore(0.0, "f1", "f1: no token overlap")
    precision = common / sum(pred.values())
    recall = common / sum(gold.values())
    f1 = 2 * precision * recall / (precision + recall)
    return AnswerScore(round(f1, 4), "f1", f"f1={f1:.3f} (p={precision:.2f} r={recall:.2f})")


# --- helpers ----------------------------------------------------------------

def _as_text(value) -> str:
    """Render an `expected` value (str / number / list) as text. Lists join with
    spaces so a list answer scores naturally under token-F1 or contains."""
    if isinstance(value, (list, tuple)):
        return " ".join(_as_text(v) for v in value)
    return str(value)


def _normalize(s: str) -> str:
    return _WS_RE.sub(" ", _PUNCT_RE.sub(" ", (s or "").lower())).strip()


def _tokens(s: str) -> list[str]:
    return _normalize(s).split()


def _parse_number(s: str) -> float | None:
    """The LAST number in the text. Models present a final answer after any
    chain-of-thought, so the last number is the answer; the first is usually a
    premise ("If 5 machines... → 5 minutes"). "Reply with ONLY the number" is a
    request, not a guarantee — this scorer does not assume the reply is bare."""
    matches = _NUMBER_RE.findall(s or "")
    if not matches:
        return None
    try:
        return float(matches[-1].replace(",", ""))
    except ValueError:
        return None
