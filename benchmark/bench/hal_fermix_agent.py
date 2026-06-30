"""HAL (Holistic Agent Leaderboard) adapter for Fermix.

⚠️  SKELETON — VERIFY the HAL agent contract against your installed hal-harness
    version. HAL expects an agent package exposing `run(input: dict) -> dict`;
    this encodes the integration design (shell to `fermix ask`), not pinned I/O
    keys. Docs: https://github.com/princeton-pli/hal-harness

Why HAL: it re-runs an agent across benchmarks (GAIA, tau-bench, SWE-bench, ...)
with $/task tracking and a reproduced-checkmark leaderboard — the cost-aware
credibility that beats a bare self-report. For the benchmarks Fermix cleanly fits
(GAIA — final-answer only), HAL adds the cost axis.

CAVEAT (from the research): HAL logs cost/traces via Weave and warns against
un-logged spawned processes. Driving Fermix as a separate daemon means the cost
column can read empty unless Fermix's provider calls are surfaced — point HAL at
the Opik-priced trace, or have the daemon echo per-turn usage, so the $/task axis
isn't vacuous. The same tool-bridging caveat as tau2 applies to HAL's tau-bench/
AppWorld tasks; HAL over GAIA-style (answer-scored) tasks is the clean path.

Env: FERMIX_HOME (default ~/.fermix-dev), FERMIX_HAL_TIMEOUT_MS (default 600000).
"""
from __future__ import annotations

import json
import os
import subprocess
import uuid


def _answer_field(input: dict) -> str:
    """HAL benchmark inputs vary; pull the task/question text robustly."""
    for key in ("question", "prompt", "task", "input", "Question"):
        if isinstance(input.get(key), str) and input[key].strip():
            return input[key]
    # fall back to the whole record so a schema change degrades to "answer the json"
    return json.dumps(input)


def run(input: dict) -> dict:
    """HAL entrypoint: drive one task through the Fermix daemon, return the answer.

    Confirm the expected OUTPUT keys for your HAL benchmark (often {"output": ...}
    or {"answer": ...}); both are returned here so the common cases are covered."""
    env = dict(os.environ)
    env.setdefault("FERMIX_HOME", os.path.expanduser("~/.fermix-dev"))
    timeout_ms = int(os.environ.get("FERMIX_HAL_TIMEOUT_MS", "600000"))
    session = f"hal-{uuid.uuid4().hex[:12]}"

    cmd = ["fermix", "ask", "--json", "--session", session,
           "--timeout", str(timeout_ms), _answer_field(input)]
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True,
                          timeout=timeout_ms / 1000 + 30)
    answer = ""
    for line in reversed(proc.stdout.strip().splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                env_obj = json.loads(line)
                answer = env_obj.get("response") or ""
                break
            except json.JSONDecodeError:
                continue
    return {"output": answer, "answer": answer, "session_id": session}
