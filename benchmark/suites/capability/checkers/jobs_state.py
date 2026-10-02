#!/usr/bin/env python3
"""Checker (json): the scheduled jobs in the eval home after the turn.

Reads memory.db read-only and compares it with what `checker.state` seeded (the job
snapshots in the evidence, keyed as in the state spec). Gold (`checker.expect`):

  job_count: 1                     # jobs in the home after the turn
  jobs:
    <key>:                         # a seeded job; it must still exist under its id
      min: {timeout_seconds: 301}  # column >= value
      unchanged: [schedule_expr, expires_at]   # equal to the seeded snapshot
      prompt_include_all: [...]    # task_prompt carries every term
      prompt_exclude: [...]        # and none of these
  no_job_contains: ["@oldcorp"]    # in no job's name, description or task_prompt
  reply_include_any: [...]         # the reply names one of these
  reply_question: true             # the reply asks something

A seeded job that was deleted and recreated fails on its id: the owner asked for an
edit, and a new job loses the old one's history.
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

COLUMNS = ("id", "name", "description", "schedule_expr", "timezone", "task_prompt",
           "skill_name", "timeout_seconds", "expires_at")


def job_problem(key, want, snapshot, row):
    if row is None:
        return f"job {key} ({snapshot['id']}) no longer exists (deleted or recreated)"
    for column, floor in (want.get("min") or {}).items():
        if row[column] is None or row[column] < floor:
            return f"{key}.{column} is {row[column]}, want at least {floor}"
    for column in want.get("unchanged") or ():
        if row[column] != snapshot[column]:
            return f"{key}.{column} changed: {row[column]!r} (seeded {snapshot[column]!r})"
    prompt = row["task_prompt"] or ""
    missing = [t for t in want.get("prompt_include_all") or () if not lib.term_present(prompt, t)]
    if missing:
        return f"{key} prompt lacks {missing}"
    kept = [t for t in want.get("prompt_exclude") or () if lib.term_present(prompt, t)]
    if kept:
        return f"{key} prompt still has {kept}"
    return None


ev = lib.evidence()
gold = lib.expected(ev)
state = lib.seeded(ev)
rows = lib.memory_rows(f"SELECT {', '.join(COLUMNS)} FROM scheduled_jobs")
by_id = {row["id"]: row for row in rows}

if "job_count" in gold and len(rows) != gold["job_count"]:
    lib.refuse(f"{len(rows)} jobs in the home, want {gold['job_count']}")
for key, want in (gold.get("jobs") or {}).items():
    snapshot = state["jobs"][key]
    problem = job_problem(key, want or {}, snapshot, by_id.get(snapshot["id"]))
    if problem:
        lib.refuse(problem)
for term in gold.get("no_job_contains") or ():
    hits = [row["id"] for row in rows
            if any(lib.term_present(row[c] or "", term) for c in ("name", "description", "task_prompt"))]
    if hits:
        lib.refuse(f"{term!r} still in job(s) {hits}")
problem = lib.reply_problem(ev, gold)
if problem:
    lib.refuse(problem)
lib.emit(1.0, f"{len(rows)} job(s) as expected")
