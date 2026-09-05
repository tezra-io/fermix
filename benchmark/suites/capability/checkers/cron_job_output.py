#!/usr/bin/env python3
"""Checker (json): the agent must SCHEDULE a job whose isolated run writes this trial's
token to job_out.txt, RUN it now, and WAIT for the run to finish before ending its turn.

The artifact alone proves nothing — a hand-written job_out.txt holding the token used to
score 1.0. Passing therefore requires the file AND the trace that produced it, correlated
through the per-trial evidence record (FERMIX_EVAL_EVIDENCE):

  1. job_out.txt holds exactly this trial's token (the runner substitutes it per trial,
     so a token memorized from an earlier sweep is worthless);
  2. a successful schedule_job span exists, with a usable start_time;
  3. a successful run_job_now span that STARTS AT OR AFTER it — the run executed a job
     that had already been scheduled, not the other way round;
  4. the file is not older than that run (a stale artifact is not this trial's work);
  5. no direct file write produced it — no file_write/file_edit naming the artifact, and
     no shell COMMAND that both names it and carries a write construct.

What this deliberately does NOT check is that the scheduled job's task text carries the
token and the path. schedule_job goes through `FermixCore.Tools.Support.run/3`, which
records neither input nor output on the span, so the task text is not in the trace at
all: requiring it refused every real trial, the reference solution included. Closing that
gap needs a daemon telemetry change and is recorded as a deviation in the design log.
The remaining chain is still not forgeable by hand — the token is per-trial and no
recorded tool wrote the file — it just cannot name WHICH job produced it.

Missing evidence is refused, never assumed: an unmeasured provenance half is not a pass.
"""
import os
import sys

sys.dont_write_bytecode = True          # never drop __pycache__ into the repo checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

MTIME_SLACK_S = 2.0        # clock skew between the daemon's span and the file's mtime

ws = lib.workspace()
artifact = os.path.join(ws, "job_out.txt")
ev = lib.evidence()
token = ev.get("token")
if not isinstance(token, str) or not token:
    lib.refuse("evidence carries no trial token")

if not os.path.isfile(artifact):
    lib.refuse("no job_out.txt (job didn't run/write, or the agent didn't wait)")
content = lib.read_text(artifact, "job_out.txt").strip()
if content != token:
    lib.refuse(f"job_out.txt is {content[:60]!r}, want the trial token {token!r}")

created = lib.spans(ev, "schedule_job")
if not created:
    attempted = lib.spans(ev, "schedule_job", status=None)
    lib.refuse(f"no successful schedule_job span ({len(attempted)} attempted)")
schedule_starts = [t for t in (lib.span_start(s) for s in created) if t is not None]
if not schedule_starts:
    lib.refuse("schedule_job span has no usable start_time — ordering unverifiable")
scheduled_at = min(schedule_starts)

runs = lib.spans(ev, "run_job_now")
if not runs:
    attempted = lib.spans(ev, "run_job_now", status=None)
    lib.refuse(f"no successful run_job_now span ({len(attempted)} attempted)")

starts = [t for t in (lib.span_start(s) for s in runs) if t is not None]
if not starts:
    lib.refuse("run_job_now span has no usable start_time — freshness unverifiable")
after_schedule = [t for t in starts if t >= scheduled_at - MTIME_SLACK_S]
if not after_schedule:
    lib.refuse("every run_job_now span started before the schedule_job — a run that "
               "predates the scheduling cannot be of the job this task asked for")
run_start = min(after_schedule)
mtime = os.path.getmtime(artifact)
if mtime < run_start - MTIME_SLACK_S:
    lib.refuse(f"job_out.txt predates the run by {run_start - mtime:.0f}s (stale artifact)")

direct = lib.direct_write_spans(ev, artifact)
if direct:
    lib.refuse("job_out.txt was written directly by "
               f"{', '.join(sorted(set(direct)))}, not by the scheduled run")

lib.emit(1.0, f"token {token} written by a scheduled run ({len(runs)} run_job_now, "
         f"{len(created)} schedule_job)")
