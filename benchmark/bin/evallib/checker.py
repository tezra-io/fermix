"""Checker scoring tier — grade a task by the sandbox END-STATE after a turn
(SWE-bench / tau-bench style), plus the per-trial scoped-workspace seed/teardown.

A checker script runs as the EVAL process (external to the agent) over the trial's
scoped dir AFTER the turn, and returns pass/fail (exit mode) or a 0..1 score (json
mode). The checker grades the end-state, NEVER the trajectory. Each trial gets a
fresh `$FERMIX_HOME/workspace/eval/<task>/t<i>/` scoring directory, seeded before
the turn and SafeRm-torn-down after. This is not a containment boundary; the
capability daemon must use a disposable workspace.
"""

from __future__ import annotations

import json
import math
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


class CheckerBoundaryError(ValueError):
    pass


_ENV_ALLOWLIST = (
    "HOME", "LANG", "LC_ALL", "PATH", "SYSTEMROOT", "TEMP", "TMP", "TMPDIR",
    "UV_CACHE_DIR", "XDG_CACHE_HOME",
)


# --- scoped scoring directory under the conventional capability workspace -----

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


def seed_workspace(scoped: str, fixtures_root: str, fixture_path: str | None,
                   cleanup_root: str) -> None:
    """Create a fresh trial dir under explicit `cleanup_root`, then copy a seed
    selected by a path relative to `fixtures_root` (if the task has one)."""
    safe_scoped = safe_rm.check(scoped, cleanup_root, min_below=2)
    fixtures_dir = None if fixture_path is None else resolve_fixture(fixtures_root, fixture_path)
    if fixtures_dir:
        _reject_fixture_symlinks(fixtures_dir)
    if os.path.exists(safe_scoped):
        safe_rm.rm_rf(safe_scoped, cleanup_root, min_below=2)
    os.makedirs(safe_scoped, exist_ok=True)
    if fixtures_dir:
        for name in os.listdir(fixtures_dir):
            src, dst = os.path.join(fixtures_dir, name), os.path.join(safe_scoped, name)
            shutil.copytree(src, dst) if os.path.isdir(src) else shutil.copy2(src, dst)


def teardown_workspace(cleanup_root: str, scoped: str) -> None:
    safe_rm.rm_rf(scoped, cleanup_root, min_below=2)   # eval/<task>/t<i>


def teardown_task(cleanup_root: str, task_id: str) -> None:
    """Remove the task's parent dir (eval/<task>) once all its trials are done, so
    empty per-task dirs don't accumulate in the workspace."""
    d = os.path.join(cleanup_root, _slug(task_id))
    if os.path.isdir(d):
        safe_rm.rm_rf(d, cleanup_root, min_below=1)   # eval/<task>


def _slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]+", "-", s)


def _resolve_relative(root: str, path: str, kind: str) -> str:
    if not isinstance(root, str) or not root:
        raise CheckerBoundaryError(f"{kind} root must be a non-empty path")
    if not isinstance(path, str) or not path or "\x00" in path:
        raise CheckerBoundaryError(f"{kind} path must be a non-empty relative path")
    portable_parts = path.replace("\\", "/").split("/")
    drive, _tail = os.path.splitdrive(path)
    portable_absolute = bool(re.match(r"^[A-Za-z]:[\\/]", path)) or path.startswith("\\\\")
    if os.path.isabs(path) or drive or portable_absolute or ".." in portable_parts:
        raise CheckerBoundaryError(f"{kind} path must be relative without traversal: {path!r}")
    resolved_root = os.path.realpath(os.path.expanduser(root))
    resolved = os.path.realpath(os.path.join(resolved_root, path))
    try:
        inside = os.path.commonpath([resolved_root, resolved]) == resolved_root
    except ValueError:
        inside = False
    if not inside or resolved == resolved_root:
        raise CheckerBoundaryError(f"{kind} path resolves outside root: {path!r}")
    return resolved


def resolve_script(root: str, path: str) -> str:
    script = _resolve_relative(root, path, "checker script")
    if not os.path.isfile(script):
        raise CheckerBoundaryError(f"checker script not found: {script}")
    return script


def resolve_fixture(root: str, path: str) -> str:
    fixture = _resolve_relative(root, path, "fixture")
    if not os.path.isdir(fixture):
        raise CheckerBoundaryError(f"fixture directory not found: {fixture}")
    return fixture


def _reject_fixture_symlinks(fixtures_dir: str) -> None:
    for current, dirs, files in os.walk(fixtures_dir, followlinks=False):
        for name in dirs + files:
            candidate = os.path.join(current, name)
            if os.path.islink(candidate):
                raise CheckerBoundaryError(f"fixture tree contains symlink: {candidate}")


def _timeout_seconds(spec: dict, override: float | None) -> float:
    value = override
    divisor = 1.0
    if value is None:
        value = spec.get("timeout_ms", 120000)
        divisor = 1000.0
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CheckerBoundaryError("checker timeout must be a positive finite number")
    try:
        seconds = float(value) / divisor
    except (OverflowError, ValueError) as exc:
        raise CheckerBoundaryError("checker timeout must be a positive finite number") from exc
    if not math.isfinite(seconds) or seconds <= 0:
        raise CheckerBoundaryError("checker timeout must be a positive finite number")
    return seconds


def _checker_env(scoped: str, reply: str) -> dict[str, str]:
    env = {key: os.environ[key] for key in _ENV_ALLOWLIST if key in os.environ}
    env["FERMIX_EVAL_WORKSPACE"] = scoped
    env["FERMIX_EVAL_REPLY"] = (reply or "")[:8000]
    return env


# --- run the checker --------------------------------------------------------

def run_checker(skill_dir: str, spec: dict, scoped_dir: str, reply: str,
                timeout_s: float | None = None) -> CheckerResult:
    """Run the task's checker over the post-turn end-state. `spec.script` is
    relative to `skill_dir`; the checker reads the scoped dir via
    FERMIX_EVAL_WORKSPACE (also its cwd) and the final reply via FERMIX_EVAL_REPLY.
    Errors are recorded as a 0-score, never swallowed (Code Rule #7)."""
    if not isinstance(spec, dict):
        return CheckerResult(0.0, "", "checker spec must be a map")
    mode = spec.get("mode")
    if mode not in ("exit", "json"):
        return CheckerResult(0.0, "", f"checker mode must be exit or json, got {mode!r}")
    try:
        script = resolve_script(skill_dir, spec.get("script"))
        timeout_s = _timeout_seconds(spec, timeout_s)
    except CheckerBoundaryError as exc:
        return CheckerResult(0.0, "", str(exc))
    scoped = os.path.realpath(os.path.expanduser(scoped_dir))
    if not os.path.isdir(scoped):
        return CheckerResult(0.0, "", f"checker workspace not found: {scoped}")
    env = _checker_env(scoped, reply)
    try:
        proc = subprocess.run([script], env=env, cwd=scoped, capture_output=True,
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
        raw_score = data["score"]
        if isinstance(raw_score, bool) or not isinstance(raw_score, (int, float)):
            raise TypeError("checker score must be a JSON number")
        score = float(raw_score)
        if not math.isfinite(score) or not 0.0 <= score <= 1.0:
            raise ValueError("checker score must be finite and within [0, 1]")
    except (ValueError, KeyError, IndexError, TypeError, OverflowError,
            json.JSONDecodeError) as exc:
        error = f"checker json parse failed: {exc}; out={proc.stdout[:160]!r}"
        return CheckerResult(0.0, "", error)
    return CheckerResult(score, str(data.get("detail", ""))[:200])
