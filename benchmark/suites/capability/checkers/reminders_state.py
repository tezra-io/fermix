#!/usr/bin/env python3
"""Checker (json): the reminders the turn created in the eval home.

Reads memory.db read-only. `checker.state` cancels every reminder and seeds the task's
own before the trial, so the active reminders it did not seed are the ones this trial
created. Gold (`checker.expect`), all optional:

  count: 1                          # reminders created
  each:                             # every created reminder matches
    next_on_offset_days: 1          # next occurrence = the home's seed-time date + N
    next_on: "2027-04-17"           # or an absolute local date
    local_time: "20:00:00"          # or local_time_between: ["06:00:00", "11:59:59"]
    kind: birthday
    recurrence: yearly
    title_include_any: [...]        # title or description names one of these
    lead_time: true                 # a reminder before the occurrence, not only at it
    reply_states_time: true         # the reply names this reminder's stored time
  reply_include_any: [...]
  reply_question: true
  any_of: [{...}, {...}]            # alternative outcomes, each a gold map like this
                                    # one; any_of stands alone (a sibling key is refused)

Reply floors carry facts a correct reply must contain (a date, a number, the stored
time), never a phrasing: a wording list rots on every model change (AGENTS.md).

"Tomorrow" is counted from the home's local date when the trial was seeded, not from
this checker's clock.
"""
import datetime
import json
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402


def states_time(reply, local_time):
    """The reply names the stored time: its hour on a 12- or 24-hour clock ("9am",
    "9:00", "21:00") or the full "09:00". A fact, not a phrasing."""
    if not local_time:
        return False
    hour, minute = int(local_time[:2]), local_time[3:5]
    forms = {str(hour), str(hour % 12 or 12), f"{hour:02d}:{minute}"}
    return any(lib.term_present(reply, form) for form in forms)


def reminder_problem(ev, row, want, today):
    if "next_on_offset_days" in want:
        due = (today + datetime.timedelta(days=want["next_on_offset_days"])).isoformat()
        if row["next_occurrence_on"] != due:
            return f"{row['title']!r} is on {row['next_occurrence_on']}, want {due}"
    if "next_on" in want and row["next_occurrence_on"] != want["next_on"]:
        return f"{row['title']!r} is on {row['next_occurrence_on']}, want {want['next_on']}"
    if "local_time" in want and row["local_time"] != want["local_time"]:
        return f"{row['title']!r} is at {row['local_time']}, want {want['local_time']}"
    if "local_time_between" in want:
        low, high = want["local_time_between"]
        if not row["local_time"] or not low <= row["local_time"] <= high:
            return f"{row['title']!r} is at {row['local_time']}, want {low}-{high}"
    for column, key in (("kind", "kind"), ("recurrence_kind", "recurrence")):
        if key in want and row[column] != want[key]:
            return f"{row['title']!r} {key} is {row[column]}, want {want[key]}"
    text = f"{row['title']} {row['description'] or ''}"
    terms = want.get("title_include_any")
    if terms and not any(lib.term_present(text, t) for t in terms):
        return f"{row['title']!r} names none of {terms}"
    if want.get("reply_states_time") and not states_time(ev.get("reply") or "", row["local_time"]):
        return f"reply does not state the reminder's time ({row['local_time']})"
    if want.get("lead_time"):
        kinds = {rule.get("kind") for rule in json.loads(row["reminder_plan_json"])}
        if not kinds & {"days_before", "duration_before"}:
            return f"{row['title']!r} reminds only at the time itself"
    return None


def outcome_problem(ev, gold, created, today):
    if "count" in gold and len(created) != gold["count"]:
        return f"{len(created)} reminder(s) created, want {gold['count']}"
    for row in created:
        problem = reminder_problem(ev, row, gold.get("each") or {}, today)
        if problem:
            return problem
    return lib.reply_problem(ev, gold)


ev = lib.evidence()
gold = lib.expected(ev)
state = lib.seeded(ev)
today = datetime.date.fromisoformat(state["today"])
seeded_ids = {r["id"] for r in state.get("reminders") or ()}
created = [row for row in lib.memory_rows("SELECT * FROM temporal_events WHERE status = 'active'")
           if row["id"] not in seeded_ids]

if "any_of" in gold and len(gold) > 1:
    # A gold mistake, not a model failure: exit non-zero so the trial is invalid.
    print("checker.expect: any_of cannot sit beside other keys", file=sys.stderr)
    raise SystemExit(2)
alternatives = gold.get("any_of") or [gold]
problems = [outcome_problem(ev, alt, created, today) for alt in alternatives]
if all(problems):
    lib.refuse("; ".join(problems))
lib.emit(1.0, f"{len(created)} reminder(s) created as expected")
