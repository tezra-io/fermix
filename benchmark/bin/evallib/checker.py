"""Checker scoring tier — grade a task by the sandbox END-STATE after a turn
(SWE-bench / tau-bench style), plus the per-trial scoped-workspace seed/teardown.

A checker script runs as the EVAL process (external to the agent) over the trial's
scoped dir AFTER the turn, and returns pass/fail (exit mode) or a 0..1 score (json
mode). The checker grades the end-state, NEVER the trajectory. Isolation: each trial
gets a fresh `$FERMIX_HOME/workspace/eval/<task>/t<i>/` (the agent's sandbox root),
seeded before the turn and SafeRm-torn-down after.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass

from . import safe_rm


@dataclass
class CheckerResult:
    score: float            # 0.0..1.0 task success from the end-state
    detail: str
    error: str | None = None


# --- scoped workspace (the agent's sandbox is $FERMIX_HOME/workspace) --------

def workspace_root(fermix_home: str) -> str:
    return os.path.join(os.path.expanduser(fermix_home), "workspace")


def eval_root(fermix_home: str) -> str:
    return os.path.join(workspace_root(fermix_home), "eval")


def scoped_dir(fermix_home: str, task_id: str, trial: int) -> str:
    """Per-(task, trial) sandbox subdir the agent operates in. The query must
    reference this RELATIVE path (e.g. `eval/<task>/t0/sales.csv`) — a bare
    relative path resolves to workspace_root, not a subdir."""
    return os.path.join(eval_root(fermix_home), _slug(task_id), f"t{trial}")


def rel_scoped(task_id: str, trial: int) -> str:
    """The workspace-relative path to template into the query."""
    return os.path.join("eval", _slug(task_id), f"t{trial}")


def seed_workspace(scoped: str, fixtures_dir: str | None) -> None:
    """Fresh per-trial dir; copy seed fixtures in (if the task has any)."""
    if os.path.exists(scoped):
        # Guard the pre-clean like teardown does — never an unguarded rmtree on a
        # computed path (CLAUDE.md host-wipe rule). `scoped` is eval/<task>/t<i> by
        # construction, so its grandparent IS eval_root; refuse anything shallower.
        safe_rm.rm_rf(scoped, os.path.dirname(os.path.dirname(scoped)), min_below=2)
    os.makedirs(scoped, exist_ok=True)
    if fixtures_dir and os.path.isdir(fixtures_dir):
        for name in os.listdir(fixtures_dir):
            src, dst = os.path.join(fixtures_dir, name), os.path.join(scoped, name)
            shutil.copytree(src, dst) if os.path.isdir(src) else shutil.copy2(src, dst)


def teardown_workspace(fermix_home: str, scoped: str) -> None:
    safe_rm.rm_rf(scoped, eval_root(fermix_home), min_below=2)   # eval/<task>/t<i>


def teardown_task(fermix_home: str, task_id: str) -> None:
    """Remove the task's parent dir (eval/<task>) once all its trials are done, so
    empty per-task dirs don't accumulate in the workspace."""
    d = os.path.join(eval_root(fermix_home), _slug(task_id))
    if os.path.isdir(d):
        safe_rm.rm_rf(d, eval_root(fermix_home), min_below=1)   # eval/<task>


def _slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]+", "-", s)


# --- run the checker --------------------------------------------------------

def run_checker(skill_dir: str, spec: dict, scoped_dir: str, reply: str,
                timeout_s: float | None = None) -> CheckerResult:
    """Run the task's checker over the post-turn end-state. `spec.script` is
    relative to `skill_dir`; the checker reads the scoped dir via
    FERMIX_EVAL_WORKSPACE (also its cwd) and the final reply via FERMIX_EVAL_REPLY.
    Errors are recorded as a 0-score, never swallowed (Code Rule #7)."""
    script = os.path.join(skill_dir, spec["script"])
    mode = spec.get("mode", "exit")
    timeout_s = timeout_s if timeout_s is not None else (spec.get("timeout_ms", 120000) / 1000.0)
    if not os.path.isfile(script):
        return CheckerResult(0.0, "", f"checker script not found: {script}")

    env = dict(os.environ)
    env["FERMIX_EVAL_WORKSPACE"] = scoped_dir
    env["FERMIX_EVAL_REPLY"] = (reply or "")[:8000]
    try:
        proc = subprocess.run([script], env=env, cwd=scoped_dir, capture_output=True,
                              text=True, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        return CheckerResult(0.0, "", f"checker timed out after {timeout_s}s")
    except OSError as exc:
        return CheckerResult(0.0, "", f"checker failed to run: {exc}")

    if mode == "exit":
        tail = (proc.stdout or proc.stderr or "").strip()[:200]
        return CheckerResult(1.0 if proc.returncode == 0 else 0.0, f"exit={proc.returncode} {tail}")

    # json mode: the checker prints {"score": 0..1, "detail": "..."} on its last line.
    # A bare number / null / list is valid JSON but not a score object — reject it as
    # a recorded error, never an uncaught TypeError that would crash the whole sweep.
    try:
        data = json.loads(proc.stdout.strip().splitlines()[-1])
        if not isinstance(data, dict):
            raise TypeError(f"checker output must be a JSON object, got {type(data).__name__}")
        score = float(data["score"])
    except (ValueError, KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
        return CheckerResult(0.0, "", f"checker json parse failed: {exc}; out={proc.stdout[:160]!r}")
    return CheckerResult(max(0.0, min(1.0, score)), str(data.get("detail", ""))[:200])
