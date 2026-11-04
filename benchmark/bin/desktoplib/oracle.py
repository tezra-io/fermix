"""The fixture's own record of what happened to it, and the clauses a task
asserts on it.

A fixture application (compux `fixtures/linux/*.py`, `fixtures/macos/FixtureApp.swift`)
writes `{"version": 1, "events": [...]}`, each event `{seq, control, action}`
plus `value`, or `length` for a secure field, whose text is never written. That
file is the oracle: a task passes on what the application recorded, never on a
picture of the screen or on the reply's wording (M42 §14.1, M42.1 §9).

A clause names a `control` and optionally an `action`, a `value` or a `length`,
and exactly one verdict:

  * `present: true` — at least one matching event;
  * `absent: true`  — no matching event;
  * `count: N`      — exactly N matching events;
  * `last: true`    — the LAST event of that control and action matches the
                      value / length (the field ends up holding it).

A state file that cannot be read, or that breaks the contract, is an
`OracleError`: an evaluator failure, never a task failure.
"""

from __future__ import annotations

import json
from dataclasses import dataclass

STATE_VERSION = 1
VERDICTS = ("present", "absent", "count", "last")
_FILTERS = ("control", "action", "value", "length")
SECURE_SUFFIX = ".secure_field"


class OracleError(RuntimeError):
    """The fixture's state could not be read, or it broke the contract."""


@dataclass(frozen=True)
class Clause:
    control: str
    action: str | None
    value: str | None
    length: int | None
    verdict: str
    count: int | None = None

    def describe(self) -> str:
        parts = [self.control, self.action or "*"]
        if self.value is not None:
            parts.append(f"value={self.value!r}")
        if self.length is not None:
            parts.append(f"length={self.length}")
        verdict = f"count={self.count}" if self.verdict == "count" else self.verdict
        return f"{' '.join(parts)} {verdict}"


@dataclass(frozen=True)
class ClauseResult:
    clause: Clause
    passed: bool
    detail: str


def parse_clause(raw: dict, where: str) -> Clause:
    """One clause from its YAML map. Raises ValueError naming `where`."""
    if not isinstance(raw, dict):
        raise ValueError(f"{where}: a clause must be a map")
    unknown = set(raw) - set(_FILTERS) - set(VERDICTS)
    if unknown:
        raise ValueError(f"{where}: unknown clause key(s) {sorted(unknown)}")
    verdicts = [v for v in VERDICTS if raw.get(v) is not None and raw.get(v) is not False]
    if len(verdicts) != 1:
        raise ValueError(f"{where}: a clause needs exactly one of {', '.join(VERDICTS)}")
    verdict = verdicts[0]
    control = raw.get("control")
    if not isinstance(control, str) or not control:
        raise ValueError(f"{where}: a clause needs a `control`")
    _check_flag(raw, verdict, where)
    if verdict == "last" and not raw.get("action"):
        raise ValueError(f"{where}: `last` reads the last event of one action; name the action")
    return Clause(control=control, action=_text(raw, "action", where),
                  value=_text(raw, "value", where), length=_length(raw, where),
                  verdict=verdict, count=raw.get("count") if verdict == "count" else None)


def _check_flag(raw: dict, verdict: str, where: str) -> None:
    value = raw[verdict]
    if verdict == "count":
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"{where}: `count` must be a whole number of events, 0 or more")
        return
    if value is not True:
        raise ValueError(f"{where}: `{verdict}` takes `true`")


def _text(raw: dict, key: str, where: str) -> str | None:
    value = raw.get(key)
    if value is not None and not isinstance(value, str):
        raise ValueError(f"{where}: `{key}` must be text (quote numbers: \"80\")")
    return value


def _length(raw: dict, where: str) -> int | None:
    value = raw.get("length")
    if value is not None and (isinstance(value, bool) or not isinstance(value, int)):
        raise ValueError(f"{where}: `length` must be a whole number")
    return value


# --- the state file --------------------------------------------------------------

def read_state(path: str) -> list[dict]:
    """The events a fixture recorded, after checking the file keeps the contract."""
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise OracleError(f"cannot read the fixture state file {path}: {exc}") from exc
    if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
        raise OracleError(f"{path} is not a version {STATE_VERSION} fixture state file")
    events = state.get("events")
    if not isinstance(events, list):
        raise OracleError(f"{path} has no `events` list")
    for index, event in enumerate(events, start=1):
        _check_event(path, index, event)
    return events


def _check_event(path: str, index: int, event) -> None:
    if not isinstance(event, dict) or event.get("seq") != index:
        raise OracleError(f"{path}: event {index} is missing or carries the wrong seq")
    for key in ("control", "action"):
        if not isinstance(event.get(key), str):
            raise OracleError(f"{path}: event {index} has no `{key}`")
    if event["control"].endswith(SECURE_SUFFIX) and "value" in event:
        raise OracleError(f"{path}: event {index} recorded a secure field's text; the "
                          "fixture must record only its length")


# --- evaluation --------------------------------------------------------------------

def evaluate(events: list[dict], clauses: list[Clause]) -> list[ClauseResult]:
    return [_evaluate_one(events, clause) for clause in clauses]


def passed(results: list[ClauseResult]) -> bool:
    return bool(results) and all(result.passed for result in results)


def _matches(event: dict, clause: Clause) -> bool:
    return (event["control"] == clause.control
            and (clause.action is None or event["action"] == clause.action)
            and (clause.value is None or event.get("value") == clause.value)
            and (clause.length is None or event.get("length") == clause.length))


def _evaluate_one(events: list[dict], clause: Clause) -> ClauseResult:
    if clause.verdict == "last":
        return _evaluate_last(events, clause)
    found = sum(1 for event in events if _matches(event, clause))
    if clause.verdict == "present":
        ok = found >= 1
    elif clause.verdict == "absent":
        ok = found == 0
    else:
        ok = found == clause.count
    return ClauseResult(clause, ok, f"{found} matching event(s)")


def _evaluate_last(events: list[dict], clause: Clause) -> ClauseResult:
    same = [e for e in events if e["control"] == clause.control and e["action"] == clause.action]
    if not same:
        return ClauseResult(clause, False, f"no {clause.control} {clause.action} event")
    last = same[-1]
    shown = {key: last[key] for key in ("value", "length") if key in last}
    return ClauseResult(clause, _matches(last, clause), f"last event {shown}")
