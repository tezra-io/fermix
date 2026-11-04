#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7"]
# ///
"""The computer-use baseline (M86 §2, P0 (a)): what today's computer-use
failures are made of, and how many image tokens a computer-use turn carries.

Reads a machine's existing trace files, READ-ONLY, and drives nothing:

  uv run bin/cu_baseline.py                             # ~/.fermix-dev/traces and ~/.fermix/traces
  uv run bin/cu_baseline.py --traces DIR --since 2026-10-01

Every computer-use `tool_exec` row is counted, and every FAILED one is put in one
class (`desktoplib/cu_trace.py` says how): `refusal` (a typed refusal code),
`timeout`, `permission`, `stale_observation` (the image or control reference the
action named was no longer the helper's) or `other`. A missed aim is not a failed
row, since the click went out: it is an aimed action that went through and was
followed by the same action at other coordinates, and it is counted beside the
failures. Rows are bucketed into turns (`(agent, session_id)`, split on a long
gap), and for every turn that used computer use the report gives its model calls,
the images its tools returned and their estimated tokens (width × height / 750),
and the image tokens its model calls carried, each image counted once per later
call while it was still among the last `--retained-screenshots`.

Without content capture a row has no `output`, so its images cannot be counted
and its failure falls back to the row's closed fields; the report says how many
rows that was. It is a count, not a diagnosis: read the rows of a bad day before
trusting a class.

Exit: 0 report written (possibly empty) · 2 usage (a named directory is missing).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from datetime import date, datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from desktoplib import cu_trace  # noqa: E402

EXIT_OK, EXIT_USAGE = 0, 2
DEFAULT_ROOTS = ("~/.fermix-dev/traces", "~/.fermix/traces")
_LLM_FIELDS = ("ts", "type", "agent", "session_id", "duration_ms", "provider", "model",
               "reasoning_effort")


# --- reading -------------------------------------------------------------------------

def scan_root(root: str, since: str | None, until: str | None) -> tuple[list[dict], list[str]]:
    """The root's computer-use rows, plus the model calls of the turns that used
    computer use, and the days scanned. A turn can cross UTC midnight, so the
    model calls are read from every scanned day and the day after the last one,
    for every turn any day's computer-use rows name; `computer_use_turns` then
    keeps only the turns that hold a computer-use row. Model-call rows are cut to
    the fields the counts need as they are read: with content capture a day of
    them is large."""
    days = cu_trace.trace_days(root, since, until)
    cu_rows = [_tag(_read(root, day, "tool_exec", cu_trace.is_computer_use), root, day)
               for day in days]
    turns = {(row.get("agent"), row.get("session_id")) for day_rows in cu_rows
             for row in day_rows}
    wanted = lambda row: (row.get("agent"), row.get("session_id")) in turns  # noqa: E731
    llm_rows = [_tag([{key: row[key] for key in _LLM_FIELDS if key in row}
                      for row in _read(root, day, "llm_call", wanted)], root, day)
                for day in _and_next_day(root, days)] if turns else []
    return [row for day_rows in cu_rows + llm_rows for row in day_rows], days


def _and_next_day(root: str, days: list[str]) -> list[str]:
    if not days:
        return []
    following = (date.fromisoformat(days[-1]) + timedelta(days=1)).isoformat()
    return days + ([following] if os.path.isdir(os.path.join(root, following)) else [])


def _read(root: str, day: str, kind: str, keep) -> list[dict]:
    path = os.path.join(root, day, f"{kind}.jsonl")
    return [row for row in cu_trace.iter_rows(path) if keep(row)] if os.path.isfile(path) else []


def _tag(rows: list[dict], root: str, day: str) -> list[dict]:
    for row in rows:
        row["_root"], row["_day"] = root, day
    return rows


# --- counting ------------------------------------------------------------------------

def computer_use_counts(cu_rows: list[dict], turns: list[list[dict]]) -> dict:
    failed = [row for row in cu_rows if not row.get("success")]
    classes = Counter(cu_trace.classify_failure(row) for row in failed)
    missed = sum(len(cu_trace.missed_aims([r for r in turn if cu_trace.is_computer_use(r)]))
                 for turn in turns)
    total = len(cu_rows)
    return {
        "rows": total,
        "failed": len(failed),
        "failure_rate": len(failed) / total if total else None,
        "failure_classes": {kind: classes.get(kind, 0) for kind in cu_trace.FAILURE_CLASSES},
        "missed_aims": missed,
        "failed_or_missed_rate": (len(failed) + missed) / total if total else None,
        "aim_not_confirmed": sum(cu_trace.AIM_NOT_CONFIRMED in (r.get("output") or "")
                                 for r in cu_rows),
        "refusal_codes": dict(Counter(r["geometry_refusal"] for r in failed
                                      if r.get("geometry_refusal"))),
        "actions": dict(Counter(r.get("action") or "?" for r in cu_rows)),
        "failed_without_output": sum("output" not in r for r in failed),
        "rows_without_output": sum("output" not in r for r in cu_rows),
    }


def turn_summary(turns: list[list[dict]], retained: int) -> tuple[dict, list[dict]]:
    per_turn = []
    for turn in turns:
        counts = cu_trace.turn_counts(turn, retained)
        per_turn.append({"root": turn[0]["_root"], "day": turn[0]["_day"],
                         "session_id": turn[0].get("session_id"), **counts})
    fields = ("model_calls", "cu_calls", "images", "image_tokens", "image_tokens_sent")
    summary = {"count": len(per_turn),
               **{name: cu_trace.distribution([t[name] for t in per_turn]) for name in fields}}
    return summary, per_turn


def by_day(cu_rows: list[dict], per_turn: list[dict]) -> list[dict]:
    keyed: dict[tuple[str, str], dict] = {}

    def entry(root: str, day: str) -> dict:
        return keyed.setdefault((root, day), {"cu_rows": 0, "failed": 0, "turns": 0})

    for row in cu_rows:
        entry(row["_root"], row["_day"])["cu_rows"] += 1
        entry(row["_root"], row["_day"])["failed"] += 0 if row.get("success") else 1
    for turn in per_turn:
        entry(turn["root"], turn["day"])["turns"] += 1
    return [{"root": root, "day": day, **counts} for (root, day), counts in sorted(keyed.items())]


def computer_use_turns(rows: list[dict]) -> list[list[dict]]:
    """Turns that used computer use, bucketed per traces root: two daemons count
    their own `main-<n>`, so the same id in two roots is two turns."""
    turns = []
    for root in sorted({row["_root"] for row in rows}):
        turns += [turn for turn in cu_trace.bucket_turns([r for r in rows if r["_root"] == root])
                  if any(cu_trace.is_computer_use(r) for r in turn)]
    return turns


def build(roots: list[dict], rows: list[dict], retained: int, args) -> dict:
    turns = computer_use_turns(rows)
    cu_rows = [row for row in rows if cu_trace.is_computer_use(row)]
    summary, per_turn = turn_summary(turns, retained)
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "window": {"since": args.since, "until": args.until},
        "roots": roots,
        "retained_screenshots": retained,
        "computer_use": computer_use_counts(cu_rows, turns),
        "turns": summary,
        "by_day": by_day(cu_rows, per_turn),
        "per_turn": per_turn,
    }


# --- output --------------------------------------------------------------------------

def _pct(value) -> str:
    return "—" if value is None else f"{value * 100:.1f}%"


def _num(value) -> str:
    return "—" if value is None else f"{value:.0f}"


def summary_lines(doc: dict) -> list[str]:
    cu, turns = doc["computer_use"], doc["turns"]
    lines = [f"traces: {root['path']} — {root['status']}, {len(root['days'])} day(s)"
             for root in doc["roots"]]
    if not cu["rows"]:
        return lines + ["no computer-use rows in the scanned traces: there is no baseline to "
                        "report from this machine"]
    classes = " · ".join(f"{k} {v}" for k, v in cu["failure_classes"].items())
    lines += [f"computer-use calls {cu['rows']}, failed {cu['failed']} "
              f"({_pct(cu['failure_rate'])}), failed or missed {_pct(cu['failed_or_missed_rate'])}",
              f"  {classes} · missed_aim {cu['missed_aims']} · aim not confirmed "
              f"{cu['aim_not_confirmed']}",
              f"  rows without output (content capture off): {cu['rows_without_output']}"]
    for name in ("model_calls", "images", "image_tokens", "image_tokens_sent"):
        dist = turns[name]
        lines.append(f"per computer-use turn ({turns['count']}): {name} median "
                     f"{_num(dist['median'])}, p90 {_num(dist['p90'])}, max {_num(dist['max'])}, "
                     f"total {_num(dist['total'])}")
    return lines


def render_markdown(doc: dict) -> str:
    lines = ["# Computer-use baseline", "",
             f"Generated {doc['generated_at']}, read-only, from the trace files below. Image "
             f"tokens are width × height / 750; *sent* counts an image once per later model "
             f"call while it is among the last {doc['retained_screenshots']} images.", ""]
    lines += [f"- {line}" for line in summary_lines(doc)]
    lines += ["", "| root | day | computer-use calls | failed | turns |", "|---|---|---|---|---|"]
    lines += [f"| {d['root']} | {d['day']} | {d['cu_rows']} | {d['failed']} | {d['turns']} |"
              for d in doc["by_day"]]
    return "\n".join(lines) + "\n"


def write(out_dir: str, doc: dict) -> tuple[str, str]:
    os.makedirs(out_dir, exist_ok=True)
    json_path = os.path.join(out_dir, "baseline.json")
    md_path = os.path.join(out_dir, "baseline.md")
    with open(json_path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2)
        handle.write("\n")
    with open(md_path, "w", encoding="utf-8") as handle:
        handle.write(render_markdown(doc))
    return json_path, md_path


# --- entry ---------------------------------------------------------------------------

def _day(value: str) -> str:
    date.fromisoformat(value)
    return value


def build_args(argv):
    p = argparse.ArgumentParser(description="Computer-use trace baseline (M86 P0), read-only")
    p.add_argument("--traces", action="append", default=[],
                   help="a traces directory (repeatable); default: "
                        + " and ".join(DEFAULT_ROOTS) + ", whichever exist")
    p.add_argument("--since", type=_day, help="first UTC day to read (YYYY-MM-DD)")
    p.add_argument("--until", type=_day, help="last UTC day to read (YYYY-MM-DD)")
    p.add_argument("--retained-screenshots", type=int, default=cu_trace.DEFAULT_RETAINED,
                   help="images a model call carries ([fermix_core.computer_use] "
                        f"max_retained_screenshots; default {cu_trace.DEFAULT_RETAINED})")
    p.add_argument("--out", help="report directory (default reports/cu_baseline/<UTC time>)")
    return p.parse_args(argv)


def resolve_roots(named: list[str]) -> tuple[list[str], list[dict], str | None]:
    """The directories to read. A directory the operator NAMED must exist; a
    default that does not is reported as absent."""
    if named:
        paths = [os.path.expanduser(path) for path in named]
        missing = [path for path in paths if not os.path.isdir(path)]
        if missing:
            return [], [], f"traces directory does not exist: {', '.join(missing)}"
        return paths, [], None
    paths = [os.path.expanduser(path) for path in DEFAULT_ROOTS]
    absent = [{"path": path, "status": "absent", "days": []}
              for path in paths if not os.path.isdir(path)]
    return [path for path in paths if os.path.isdir(path)], absent, None


def main(argv=None) -> int:
    args = build_args(argv)
    if args.retained_screenshots < 0:
        print("--retained-screenshots must be 0 or more", file=sys.stderr)
        return EXIT_USAGE
    paths, roots, problem = resolve_roots(args.traces)
    if problem:
        print(problem, file=sys.stderr)
        return EXIT_USAGE
    rows: list[dict] = []
    for path in paths:
        root_rows, days = scan_root(path, args.since, args.until)
        rows.extend(root_rows)
        roots.append({"path": path, "status": "read", "days": days})
    doc = build(roots, rows, args.retained_screenshots, args)
    out_dir = args.out or os.path.join(
        SKILL_DIR, "reports", "cu_baseline", datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"))
    json_path, md_path = write(out_dir, doc)
    print("\n".join(summary_lines(doc)))
    print(f"wrote {json_path}\nwrote {md_path}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
