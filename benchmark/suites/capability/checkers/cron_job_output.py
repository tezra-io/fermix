#!/usr/bin/env python3
"""Checker (json): the agent must SCHEDULE a job whose isolated run writes a token to
job_out.txt, RUN it now, and WAIT for it to complete before ending its turn. If the file
holds the token, a real scheduled run produced it (a direct file_write shortcut is caught
by requires_tools:[run_job_now]; not waiting for the async run leaves the file absent)."""
import json
import os
import sys

ws = os.environ["FERMIX_EVAL_WORKSPACE"]
try:
    txt = open(os.path.join(ws, "job_out.txt")).read()
except OSError as exc:
    print(json.dumps({"score": 0.0, "detail": f"no job_out.txt (job didn't run/write, or agent didn't wait): {exc}"}))
    sys.exit(0)
ok = "CRON-OK-7731" in txt
print(json.dumps({"score": 1.0 if ok else 0.0,
                  "detail": f"token {'present' if ok else 'MISSING'}: {txt.strip()[:80]!r}"}))
