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
import tempfile
from dataclasses import dataclass, field

from . import safe_rm


@dataclass
class CheckerResult:
    score: float            # 0.0..1.0 task success from the end-state
    detail: str
    error: str | None = None
    # A checker's own SAFETY verdict, tri-state like every other safety answer in the
    # harness: True = it looked and found nothing · False = it observed a violation ·
    # None = it said nothing, which leaves the gate-derived verdict untouched rather
    # than crediting an unmeasured pass.
    safety_ok: bool | None = None
    violations: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        # Naming a violation IS the observation. Deriving it here rather than at the
        # parse site means no construction can report harm and still read as "nothing
        # was evaluated".
        if self.violations and self.safety_ok is None:
            self.safety_ok = False


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


def _checker_env(scoped: str, reply: str, fermix_home: str,
                 evidence_path: str | None) -> dict[str, str]:
    env = {key: os.environ[key] for key in _ENV_ALLOWLIST if key in os.environ}
    env["FERMIX_EVAL_WORKSPACE"] = scoped
    env["FERMIX_EVAL_REPLY"] = (reply or "")[:8000]
    # Ground-truth checkers verify daemon end-state under the home (e.g. a
    # created skill's SKILL.md), not just files the model wrote in the
    # workspace — a workspace listing alone is the model's CLAIM.
    env["FERMIX_EVAL_HOME"] = fermix_home
    # Correlation evidence (this trial's token + tool spans). Absent when the
    # caller passed none, so a checker that requires it refuses loudly rather
    # than assuming an empty span list means "the model did nothing".
    if evidence_path is not None:
        env["FERMIX_EVAL_EVIDENCE"] = evidence_path
    return env


# --- per-trial evidence file ------------------------------------------------

def _write_evidence(evidence: dict) -> tuple[str, str]:
    """Materialize the runner's per-trial evidence as `evidence.json` in a fresh
    temp dir OUTSIDE the scored workspace — the agent must never be able to read
    or forge the record its work is correlated against. Returns
    (temp_dir, evidence_path); the caller removes temp_dir on every exit path."""
    tmp_dir = tempfile.mkdtemp(prefix="fermix-eval-evidence-")
    path = os.path.join(tmp_dir, "evidence.json")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(evidence, fh)
    except (OSError, TypeError, ValueError):
        _remove_evidence(tmp_dir)
        raise
    return tmp_dir, path


def _remove_evidence(tmp_dir: str) -> None:
    safe_rm.rm_rf(tmp_dir, tempfile.gettempdir(), min_below=1)


def _preflight(spec, fermix_home, evidence) -> str | None:
    """Argument guards shared by every run; returns an error string or None."""
    if not isinstance(spec, dict):
        return "checker spec must be a map"
    if not isinstance(fermix_home, str) or not fermix_home:
        return "checker fermix_home must be a non-empty path"
    if evidence is not None and not isinstance(evidence, dict):
        return f"checker evidence must be a map, got {type(evidence).__name__}"
    mode = spec.get("mode")
    if mode not in ("exit", "json"):
        return f"checker mode must be exit or json, got {mode!r}"
    return None


def _result_of(mode: str, proc: subprocess.CompletedProcess) -> CheckerResult:
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
        return CheckerResult(0.0, "", f"checker json parse failed: {exc}; out={proc.stdout[:160]!r}")
    try:
        safety_ok, violations = _checker_safety(data)
    except (TypeError, ValueError) as exc:
        return CheckerResult(0.0, "", f"checker safety verdict invalid: {exc}")
    return CheckerResult(score, str(data.get("detail", ""))[:200],
                         safety_ok=safety_ok, violations=violations)


def _checker_safety(data: dict) -> tuple[bool | None, list[str]]:
    """Read the OPTIONAL `safety_ok` / `violations` keys off a json-mode result.

    Both are optional — most checkers grade task success only and say nothing about
    safety, which must stay "not evaluated". When present they must be well-formed: a
    malformed safety verdict is a checker ERROR, not a quiet demotion to silence, or a
    typo in a checker turns a declared safety observation into no observation at all."""
    safety_ok = data.get("safety_ok")
    if safety_ok is not None and not isinstance(safety_ok, bool):
        raise TypeError(f"safety_ok must be true/false, got {type(safety_ok).__name__}")
    violations = data.get("violations", [])
    if not isinstance(violations, list) or not all(isinstance(v, str) for v in violations):
        raise TypeError("violations must be a list of strings")
    return safety_ok, [v[:200] for v in violations]


# --- run the checker --------------------------------------------------------

def run_checker(skill_dir: str, spec: dict, scoped_dir: str, reply: str,
                fermix_home: str, timeout_s: float | None = None,
                evidence: dict | None = None) -> CheckerResult:
    """Run the task's checker over the post-turn end-state. `spec.script` is
    relative to `skill_dir`; the checker reads the scoped dir via
    FERMIX_EVAL_WORKSPACE (also its cwd), the final reply via FERMIX_EVAL_REPLY,
    the daemon home via FERMIX_EVAL_HOME (for ground truth outside the
    workspace), and — when the caller supplies `evidence` — this trial's token
    and tool spans as JSON at FERMIX_EVAL_EVIDENCE. Errors are recorded on
    `CheckerResult.error`, never swallowed (Code Rule #7); the caller treats a
    recorded error as an INVALID measurement, not as the model scoring zero.

    A json-mode checker may also return `safety_ok` and `violations`; both are
    optional and read into the result's tri-state safety verdict."""
    problem = _preflight(spec, fermix_home, evidence)
    if problem is not None:
        return CheckerResult(0.0, "", problem)
    try:
        script = resolve_script(skill_dir, spec.get("script"))
        timeout_s = _timeout_seconds(spec, timeout_s)
    except CheckerBoundaryError as exc:
        return CheckerResult(0.0, "", str(exc))
    scoped = os.path.realpath(os.path.expanduser(scoped_dir))
    if not os.path.isdir(scoped):
        return CheckerResult(0.0, "", f"checker workspace not found: {scoped}")
    # Held to the same standard as the workspace: a checker reading ground truth
    # out of a FERMIX_EVAL_HOME that does not exist finds nothing and scores the
    # task 0, which is indistinguishable from the model having failed it.
    home = os.path.realpath(os.path.expanduser(fermix_home))
    if not os.path.isdir(home):
        return CheckerResult(0.0, "", f"checker fermix_home not found: {home}")
    tmp_dir, evidence_path = None, None
    if evidence is not None:
        try:
            tmp_dir, evidence_path = _write_evidence(evidence)
        except (OSError, TypeError, ValueError) as exc:
            return CheckerResult(0.0, "", f"checker evidence could not be written: {exc}")
    env = _checker_env(scoped, reply, home, evidence_path)
    try:
        proc = subprocess.run([script], env=env, cwd=scoped, capture_output=True,
                              text=True, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        return CheckerResult(0.0, "", f"checker timed out after {timeout_s}s")
    except OSError as exc:
        return CheckerResult(0.0, "", f"checker failed to run: {exc}")
    finally:
        cleanup = _cleanup_evidence(tmp_dir)
    result = _result_of(mode=spec["mode"], proc=proc)
    if cleanup:
        return CheckerResult(0.0, result.detail, cleanup)
    return result


def _cleanup_evidence(tmp_dir: str | None) -> str | None:
    """Remove the per-trial evidence dir, returning a message instead of raising.

    Raising out of the `finally` masks the CheckerResult and takes the whole sweep
    with it — including the case where the dir is simply gone already (a concurrent
    tmp cleaner, or the checker removing it). The failure is still reported: it becomes
    the result's recorded error, which invalidates that trial."""
    if tmp_dir is None:
        return None
    try:
        _remove_evidence(tmp_dir)
    except (safe_rm.SafeRmError, OSError) as exc:
        return f"checker evidence dir could not be removed ({tmp_dir}): {exc}"
    return None
