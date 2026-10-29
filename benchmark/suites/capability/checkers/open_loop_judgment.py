#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Checker (json): did the trial's turn keep the moment the way the owner labelled it?

One task per labelled moment (suites/capability/candidates/open_loop_judgment.yaml,
built by bin/build_judgment_suite.py). `checker.state` restores an empty baseline
before every trial (bin/seed_state.exs closes every live open loop), so every loop
created since the seed is this trial's. The checker reads memory.db read-only and
names what Fermix did with the moment, from the loops the trial left LIVE (M83 §06):

  let_go        no new live loop (a loop noted and then dropped or closed in the same
                trial, as when the owner's second message says "I don't want to talk
                about it", leaves nothing to raise later; the detail still shows it)
  when_around   exactly one new live loop, reach 'conversation'
  check_in      exactly one new live loop, reach 'message'
  other         more than one new live loop, or a reach this checker does not know: a
                disagreement with every label

Gold (`checker.expect`): `label` (the owner's answer) and `moment` (its id).

KEEP-OR-LET-GO ONLY. On a database whose open_loops table has no `reach` column (the
schema before migration 51) the checker cannot tell the two kept labels apart, so it
names `keep` for one new live row and grades only keep against let go; the detail says
`stage=0`. That is how the stage 0 baseline runs on today's code.

The detail is the record bin/judgment_agreement.py reads, as `key=value` tokens and
then the row's intention after ` | `:

  pred=check_in want=check_in new=1 live=1 reach=message kind=ask_after class=after stage=1 refused=none noted=1 | ...

A field the schema lacks reads `n/a`; a field with no single row to describe reads `-`.

THE MODEL LET IT GO, OR CODE REFUSED THE NOTE. Both leave no row, so the row alone
reads both as let_go. The trial's open_loop_note spans tell them apart: `noted` counts
every open_loop_note call the model made, and `refused` names the tool's own sentence
for the last call the code turned down (its first words, as one token, e.g.
`that_date_is_too_close_for_fermix_to`), or `none`. A call is read from the result
its span recorded: accepted when that result is the tool's own view of the loop it
stored (it carries `open_loop_id`), refused otherwise. The engine now traces a refusal
with `error_code` and `error_summary`, so its span is status `error`, but the result
is still what decides: it is the same evidence either way, and it also reads runs
recorded before that change, when a refusal carried no error and read status `ok`.
When the result was not recorded (tool content capture off), the refusal is read
from the error text the span recorded instead (`error_summary`, the same sentence);
a call with neither reads `refused=unread`: it is not guessed either way.

No safety observation: the costliest error (check in where the owner said let it go) is
a graded outcome, reported on its own line by the agreement script, and SCHEMA.md keeps
a scored outcome out of the safety column.
"""
import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

LABELS = ("let_go", "when_around", "check_in")
LIVE_STATES = ("open", "due", "asked")
REACH_LABELS = {"conversation": "when_around", "message": "check_in"}
BASE_COLUMNS = ("id", "state", "horizon_class", "intention", "created_at")
OPTIONAL_COLUMNS = ("reach", "anchor_kind")
NOTE_TOOL = "open_loop_note"
# The refusal token: the tool sentence's first words, bounded so the detail's head
# stays well inside the 200 characters `lib.emit` keeps.
REASON_WORDS = 8
REASON_MAX = 48


def invalid(detail):
    """Not a score: the evidence this trial needs is not there for a reason outside the
    model. A nonzero exit makes the runner record an invalid trial."""
    print(detail, file=sys.stderr)
    raise SystemExit(2)


def gold_label(gold):
    label = gold.get("label")
    if label not in LABELS:
        invalid(f"checker.expect.label must be one of {LABELS}, got {label!r}")
    return label


def table_columns():
    names = {row["name"] for row in lib.memory_rows("PRAGMA table_info(open_loops)")}
    if not set(BASE_COLUMNS) <= names:
        invalid(f"memory.db's open_loops table lacks {sorted(set(BASE_COLUMNS) - names)}")
    return names


def new_rows(columns, since_iso):
    """Every open_loops row created at or after the seed: the trial's own."""
    since = lib.epoch_seconds(since_iso)
    if since is None:
        invalid(f"the seeded state carries no readable `now`: {since_iso!r}")
    wanted = [*BASE_COLUMNS, *(c for c in OPTIONAL_COLUMNS if c in columns)]
    rows = lib.memory_rows(f"SELECT {', '.join(wanted)} FROM open_loops")
    created = []
    for row in rows:
        at = lib.epoch_seconds(row["created_at"])
        if at is None:
            invalid(f"open loop {row['id']} has an unreadable created_at {row['created_at']!r}")
        if at >= since:
            created.append(row)
    return created


def live(rows):
    return [row for row in rows if row["state"] in LIVE_STATES]


def predicted(rows, has_reach):
    """What Fermix did with the moment, named in the owner's vocabulary."""
    kept = live(rows)
    if not kept:
        return "let_go"
    if len(kept) != 1:
        return "other"
    if not has_reach:
        return "keep"
    return REACH_LABELS.get(kept[0]["reach"], "other")


def field(row, name, present):
    if not present:
        return "n/a"
    if row is None:
        return "-"
    return str(row.get(name) or "-")


def result_text(span):
    """The words a call's span recorded as its result. Opik wraps them as
    {"text": ...}, which the runner hands over as text; a bare string is the same
    words unwrapped."""
    raw = lib.span_output(span)
    try:
        outer = json.loads(raw)
    except ValueError:
        return raw
    if isinstance(outer, dict) and isinstance(outer.get("text"), str):
        return outer["text"]
    return raw


def accepted(span):
    """The tool answered with its view of the loop it stored or found."""
    result = lib.span_result(span)
    return isinstance(result, dict) and bool(result.get("open_loop_id"))


def error_text(span):
    """The sentence a refused call's span recorded as its error: Opik's `error_info`
    ({"exception_type": tag, "message": sentence}), which the runner hands over as
    text. Empty when the span recorded none."""
    raw = span.get("error") or ""
    try:
        info = json.loads(raw)
    except ValueError:
        return raw
    if isinstance(info, dict) and isinstance(info.get("message"), str):
        return info["message"]
    return raw


def reason_token(text):
    words = re.findall(r"\w+", text.lower())[:REASON_WORDS]
    return "_".join(words)[:REASON_MAX].rstrip("_") or "unread"


def refusal_token(span):
    """The refusal's token from the result the span recorded, else from its error."""
    return reason_token(result_text(span) or error_text(span))


def note_calls(ev):
    """(calls the model made, the last refusal's token or `none`)."""
    calls = lib.spans(ev, NOTE_TOOL, status=None)
    refusals = [refusal_token(span) for span in calls if not accepted(span)]
    return len(calls), (refusals[-1] if refusals else "none")


def detail(pred, want, rows, columns, notes):
    """The tokens describe the one live loop when there is one, else the one new row."""
    kept = live(rows)
    row = kept[0] if len(kept) == 1 else (rows[0] if len(rows) == 1 and not kept else None)
    intention = " ".join(str(row["intention"]).split()) if row else ""
    noted, refused = notes
    tokens = [f"pred={pred}", f"want={want}", f"new={len(rows)}", f"live={len(kept)}",
              f"reach={field(row, 'reach', 'reach' in columns)}",
              f"kind={field(row, 'anchor_kind', 'anchor_kind' in columns)}",
              f"class={field(row, 'horizon_class', True)}",
              f"stage={1 if 'reach' in columns else 0}",
              f"refused={refused}", f"noted={noted}"]
    return " ".join(tokens) + " | " + intention


def main():
    ev = lib.evidence()
    gold = lib.expected(ev)
    state = lib.seeded(ev)
    want = gold_label(gold)
    columns = table_columns()
    rows = new_rows(columns, state.get("now"))
    has_reach = "reach" in columns
    pred = predicted(rows, has_reach)
    target = want if has_reach else ("let_go" if want == "let_go" else "keep")
    lib.emit(1.0 if pred == target else 0.0,
             detail(pred, want, rows, columns, note_calls(ev)))


main()
