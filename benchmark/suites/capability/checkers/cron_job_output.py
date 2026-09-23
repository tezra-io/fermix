#!/usr/bin/env python3
"""Checker (json): the agent must SCHEDULE a job whose isolated run writes this trial's
token to job_out.txt, get it run, and WAIT for the run to finish before ending its turn.

The artifact alone proves nothing — a hand-written job_out.txt holding the token used to
score 1.0. Passing therefore requires the file AND the trace that produced it, correlated
through the per-trial evidence record (FERMIX_EVAL_EVIDENCE):

  1. job_out.txt holds exactly this trial's token (the runner substitutes it per trial,
     so a token memorized from an earlier sweep is worthless);
  2. a successful schedule_job span exists, with a usable start_time and the job's id;
  3. get_job_run or list_job_runs reports a COMPLETED run of that job, started at or
     after the scheduling. Which trigger started it does not matter: a one-off job due
     now is claimed by its own schedule, and run_job_now is then refused as a duplicate;
  4. the file is not older than that run (a stale artifact is not this trial's work);
  5. no direct file write produced it — no file_write/file_edit naming the artifact, and
     no shell COMMAND that both names it and carries a write construct.

Missing evidence is refused, never assumed: an unmeasured provenance half is not a pass.
"""
import os
import sys

sys.dont_write_bytecode = True          # never drop __pycache__ into the repo checkout
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

MTIME_SLACK_S = 2.0        # clock skew between the daemon's span and the file's mtime


def reported_runs(ev):
    """Every run object a successful get_job_run or list_job_runs span reported."""
    runs = [lib.span_result(s) for s in lib.spans(ev, "get_job_run")]
    for span in lib.spans(ev, "list_job_runs"):
        listed = (lib.span_result(span) or {}).get("runs")
        runs += listed if isinstance(listed, list) else []
    return [run for run in runs if isinstance(run, dict)]


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
job_ids = {(lib.span_result(s) or {}).get("id") for s in created} - {None}
if not job_ids:
    lib.refuse("schedule_job reported no job id — which job ran is unverifiable (a span "
               "with no output at all means the daemon ran with trace content capture "
               "off: set FERMIX_TRACE_CONTENT=1 and restart it)")

completed = [run for run in reported_runs(ev)
             if run.get("job_id") in job_ids and run.get("status") == "ok"]
if not completed:
    lib.refuse("no get_job_run or list_job_runs reports a completed run of the scheduled "
               "job (it failed, or the agent did not wait for it)")
starts = [t for t in (lib.epoch_seconds(run.get("started_at")) for run in completed)
          if t is not None and t >= scheduled_at - MTIME_SLACK_S]
if not starts:
    lib.refuse("no completed run started at or after the scheduling — a run that predates "
               "it cannot be of the job this task asked for")
run_start = min(starts)
mtime = os.path.getmtime(artifact)
if mtime < run_start - MTIME_SLACK_S:
    lib.refuse(f"job_out.txt predates the run by {run_start - mtime:.0f}s (stale artifact)")

direct = lib.direct_write_spans(ev, artifact)
if direct:
    lib.refuse("job_out.txt was written directly by "
               f"{', '.join(sorted(set(direct)))}, not by the scheduled run")

triggers = sorted({str(run.get("trigger")) for run in completed})
lib.emit(1.0, f"token {token} written by a completed run of {sorted(job_ids)[0]} "
         f"(trigger: {', '.join(triggers)})")
