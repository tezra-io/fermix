#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7", "certifi"]
# ///
"""Fermix E2E eval runner.

Drives realistic queries into the Opik-enabled dev daemon, grades each turn's Opik
trace against YAML-declared structural gates and declared judge rubrics, and writes
MD/HTML/JSON reports. See SKILL.md and suites/SCHEMA.md.

Exit codes: 0 = PASS · 1 = FAIL · 2 = usage/selection error · 3 = preconditions
not met · 4 = INCOMPLETE evidence or required cases skipped.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time
import tomllib
from dataclasses import replace
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
REPO_ROOT = os.path.dirname(SKILL_DIR)
sys.path.insert(0, HERE)

from evallib import config as cfgmod
from evallib import driver, grade, judge, report
from evallib.opik import OpikClient, OpikError, valid_run_id
from evallib.suites import RISK_LEVELS, SuiteError, load_all

_SESS_RE = re.compile(r"[^A-Za-z0-9_-]")
_PROVIDER_LIMIT_RE = re.compile(
    r"usage limit\b.*?\btry again in ~|rate-limited this request|quota or credits are exhausted",
    re.IGNORECASE | re.DOTALL,
)
_DEFAULT_PROFILES = {"host_readonly"}
_ISOLATED_PROFILES = {"isolated_mutation", "external_write", "desktop_input", "destructive"}
_EVIDENCE_TOOL_LIMIT = 12
_EVIDENCE_TOOL_MAX_BYTES = 2_000
_EVIDENCE_RECORD_MAX_BYTES = 30_000


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def new_run_id() -> str:
    """UTC-sortable run id with enough entropy for concurrent harness processes."""
    return now_utc().strftime("%Y%m%dT%H%M%SZ") + secrets.token_hex(4)


def sess(*parts: str) -> str:
    return _SESS_RE.sub("-", "-".join(parts))[:90]


def _render_query(query: str, run_id: str, trial: int) -> str:
    if not isinstance(query, str) or not query.strip():
        raise ValueError("eval query must be a non-empty string")
    return (query.replace("__EVAL_RUN_ID__", run_id)
            .replace("__EVAL_TRIAL__", str(trial))
            .replace("__EVAL_REPO_ROOT__", REPO_ROOT.replace(os.sep, "/")))


def _provider_limit_reply(reply: str | None) -> bool:
    return isinstance(reply, str) and _PROVIDER_LIMIT_RE.search(reply) is not None


def _view_incomplete(view) -> bool:
    return (not view.trace_complete or not view.telemetry_complete
            or _provider_limit_reply(view.reply))


# --- selection --------------------------------------------------------------

def select(suites, args, profiles):
    if not profiles:
        raise ValueError("at least one execution profile is required")
    want_suites = set(args.suite or [])
    want_scen = set(args.scenario or [])
    want_cases = set(getattr(args, "case", None) or [])
    want_tags = set(args.tag or [])
    chosen = []
    for s in suites:
        if want_suites and s.name not in want_suites:
            continue
        scns = []
        for scn in s.scenarios:
            if scn.risk not in profiles:
                continue
            if want_scen and scn.id not in want_scen:
                continue
            if want_tags and not (want_tags & set(scn.tags)):
                continue
            cases = [case for case in scn.cases if not want_cases or case.id in want_cases]
            if cases:
                scns.append(replace(scn, cases=cases))
        if scns:
            chosen.append((s, scns))
    return chosen


def unmatched_selector_errors(suites, args, profiles: set[str]) -> list[str]:
    """Return every explicit selector that contributes no eligible case.

    Each value is checked with the other selector categories still applied. This
    catches partially matched requests such as two suites plus a scenario that
    exists in only one of them instead of silently dropping the other suite.
    """
    want_suites = list(args.suite or [])
    want_scenarios = list(args.scenario or [])
    want_cases = list(getattr(args, "case", None) or [])
    want_tags = list(args.tag or [])
    eligible = [
        (suite, scenario, case)
        for suite in suites
        for scenario in suite.scenarios
        if scenario.risk in profiles
        for case in scenario.cases
    ]

    def matches_other(suite, scenario, case, excluded: str) -> bool:
        if excluded != "suite" and want_suites and suite.name not in want_suites:
            return False
        if excluded != "scenario" and want_scenarios and scenario.id not in want_scenarios:
            return False
        if excluded != "case" and want_cases and case.id not in want_cases:
            return False
        if excluded != "tag" and want_tags and not (set(want_tags) & set(scenario.tags)):
            return False
        return True

    checks = (
        ("suite", want_suites, lambda value, s, _scn, _case: s.name == value),
        ("scenario", want_scenarios, lambda value, _s, scn, _case: scn.id == value),
        ("case", want_cases, lambda value, _s, _scn, case: case.id == value),
        ("tag", want_tags, lambda value, _s, scn, _case: value in scn.tags),
    )
    errors = []
    for kind, values, exact in checks:
        for value in dict.fromkeys(values):
            matched = any(exact(value, *item) and matches_other(*item, kind)
                          for item in eligible)
            if not matched:
                errors.append(
                    f"--{kind} {value!r} matched nothing in the selected profiles")
    return errors


def high_impact_selection_error(profiles: set[str], args, chosen) -> str | None:
    high_impact = profiles & {"desktop_input", "external_write", "destructive"}
    if not high_impact or getattr(args, "dry_run", False):
        return None
    named_cases = list(getattr(args, "case", None) or [])
    named_scenarios = list(args.scenario or [])
    if not named_cases and not named_scenarios:
        names = ", ".join(sorted(high_impact))
        return f"profile(s) {names} require one exact --scenario or --case selection"
    if named_cases:
        count = sum(len(scenario.cases) for _suite, scenarios in chosen for scenario in scenarios)
        unit = "case"
    else:
        count = sum(len(scenarios) for _suite, scenarios in chosen)
        unit = "scenario"
    if count != 1:
        return f"high-impact execution must resolve to exactly one named {unit}; matched {count}"
    return None


def selected_profiles(args) -> set[str]:
    return set(args.profile or _DEFAULT_PROFILES)


def requires_strict_sandbox(profiles: set[str]) -> bool:
    return bool(profiles & _ISOLATED_PROFILES) and profiles != {"desktop_input"}


def requires_isolated_home(profiles: set[str]) -> bool:
    return bool(profiles & _ISOLATED_PROFILES)


def profile_policy_error(profiles: set[str], args) -> str | None:
    isolated_profiles = profiles & _ISOLATED_PROFILES
    if isolated_profiles and not getattr(args, "confirm_daemon_isolated", False):
        return ("--confirm-daemon-isolated is required: attest that the reachable daemon "
                "was restarted against the disposable eval home/project, with no unrelated "
                "channels/realtime and a headless browser")
    if "destructive" in profiles and not args.dangerous:
        return "the destructive profile requires --dangerous"
    if isolated_profiles and not args.confirm_isolated_env:
        names = ", ".join(sorted(isolated_profiles))
        return f"profile(s) {names} require --confirm-isolated-env"
    private_profiles = profiles & {
        "private_account_read", "desktop_input", "external_write", "destructive"}
    if private_profiles and not args.confirm_private_data:
        names = ", ".join(sorted(private_profiles))
        return f"profile(s) {names} require --confirm-private-data"
    if "expensive" in profiles and not args.confirm_cost:
        return "expensive requires --confirm-cost"
    return None


def dangerous_disposable_error(args) -> str | None:
    if not args.dangerous:
        return None
    if os.environ.get("FERMIX_EVAL_DISPOSABLE") == "1":
        return None
    return ("--dangerous refuses to run unless FERMIX_EVAL_DISPOSABLE=1 attests a "
            "disposable, throwaway environment (a VM or CI container with no "
            "persistent state). Dangerous suites issue commands that cause real "
            "harm if the sandbox fails; muscle-memory attestation flags on a dev "
            "machine must not reach a destructive run. See "
            "docs/design/MILESTONE_22_MULTI_OS_CI_AND_DISPOSABLE_E2E.md and "
            "docs/design/MILESTONE_20_EVAL_VM_ISOLATION.md.")


def selection_policy_error(chosen, args) -> str | None:
    cost_confirmed = getattr(args, "confirm_cost", False)
    if cost_confirmed:
        return None
    costly = sorted({
        f"{suite.name}/{scenario.id}"
        for suite, scenarios in chosen
        for scenario in scenarios
        if scenario.confirm_cost
    })
    if not costly:
        return None
    return ("selected scenario(s) require --confirm-cost: "
            + ", ".join(costly))


def behavioral_schema_errors(chosen) -> list[str]:
    problems = []
    for suite, scenarios in chosen:
        for scenario in scenarios:
            for case in scenario.cases:
                unsupported = []
                if case.score_spec is not None:
                    unsupported.append("score")
                if case.checker_spec is not None:
                    unsupported.append("checker")
                if case.requires_tools:
                    unsupported.append("requires_tools")
                if case.cross_session:
                    unsupported.append("cross_session")
                if unsupported:
                    where = f"{suite.name}/{scenario.id}/{case.id}"
                    problems.append(f"{where}: run_eval does not support {unsupported}")
    return problems


def required_judge_cases(jobs, operator: bool) -> list[str]:
    required = []
    for suite, scenario, case, _trial in jobs:
        runnable = case.drive == "ask" or operator
        label = f"{suite.name}/{scenario.id}/{case.id}"
        if runnable and case.judge and case.rubric and label not in required:
            required.append(label)
    return required


def judge_requirement_error(required: list[str]) -> str | None:
    if not required:
        return None
    sample = ", ".join(required[:3])
    suffix = " …" if len(required) > 3 else ""
    return ("selected behavioral rubrics require --judge; refusing a "
            f"structural-only false-green run ({sample}{suffix})")


def judge_precondition_error(cfg, judge_on: bool) -> str | None:
    if not judge_on:
        return None
    return judge.precondition_error(cfg)


def eval_home_error(fermix_home: str, require_isolated: bool = False) -> str | None:
    resolved = os.path.realpath(os.path.expanduser(fermix_home))
    production = os.path.realpath(os.path.expanduser("~/.fermix"))
    dev = os.path.realpath(os.path.expanduser("~/.fermix-dev"))
    home = os.path.realpath(os.path.expanduser("~"))
    if resolved in {production, home}:
        return f"refusing production/non-daemon FERMIX_HOME: {resolved}"
    if resolved == dev:
        if require_isolated:
            return ("selected profiles can mutate state and cannot use ~/.fermix-dev; "
                    "set FERMIX_EVAL_HOME to a disposable eval/e2e home")
        return None
    leaf = os.path.basename(resolved).lower()
    if "eval" not in leaf and "e2e" not in leaf:
        return ("safe behavioral runs use ~/.fermix-dev; isolated profiles require a "
                "dedicated path named with 'eval' or 'e2e'")
    return None


def eval_project_error(project: str, require_isolated: bool = False) -> str | None:
    if not isinstance(project, str) or not project.strip():
        return "Opik project must be a non-empty name"
    name = project.strip().lower()
    if name == "fermix-dev":
        if require_isolated:
            return "isolated behavioral runs require an eval/e2e Opik project, not fermix-dev"
        return None
    if "eval" not in name and "e2e" not in name:
        return f"refusing production or unknown Opik project: {project!r}"
    return None


def _path_within(path: str, root: str) -> bool:
    try:
        return os.path.commonpath([path, root]) == root
    except ValueError:
        return False


def daemon_sandbox_error(
        fermix_home: str, require_isolated: bool, require_strict: bool) -> str | None:
    home = os.path.realpath(os.path.expanduser(fermix_home))
    config_path = os.path.join(home, "config.toml")
    try:
        with open(config_path, "rb") as handle:
            raw = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        return f"cannot read benchmark daemon config at {config_path}: {exc}"
    sandbox = raw.get("sandbox", {})
    if not isinstance(sandbox, dict):
        return "benchmark daemon [sandbox] config must be a table"
    if not require_isolated:
        return None
    mode = sandbox.get("mode", "standard")
    if require_strict and mode != "strict":
        return "eval daemon must use [sandbox] mode = \"strict\" for this profile"
    workspace_raw = sandbox.get("workspace_root", os.path.join(home, "workspace"))
    if not isinstance(workspace_raw, str) or not workspace_raw.strip():
        return "eval daemon sandbox.workspace_root must be a non-empty path"
    expanded = os.path.expandvars(os.path.expanduser(workspace_raw))
    if not os.path.isabs(expanded):
        return "eval daemon sandbox.workspace_root must be absolute"
    workspace = os.path.realpath(expanded)
    if workspace == home or not _path_within(workspace, home):
        return f"eval workspace must stay below the dedicated FERMIX_HOME: {workspace}"
    git_metadata = os.path.realpath(os.path.join(workspace, ".git"))
    if (not os.path.isdir(workspace) or not os.path.isdir(git_metadata)
            or not _path_within(git_metadata, workspace)):
        return ("eval workspace must contain a disposable repository snapshot "
                f"with its own .git metadata: {workspace}")
    allowed = sandbox.get("allowed_roots", [])
    if not isinstance(allowed, list) or not all(isinstance(item, str) for item in allowed):
        return "eval daemon sandbox.allowed_roots must be a list of paths"
    escaped = []
    for item in allowed:
        resolved = os.path.realpath(os.path.expandvars(os.path.expanduser(item)))
        if not _path_within(resolved, home):
            escaped.append(resolved)
    if escaped:
        return f"eval daemon allowed_roots escape its disposable home: {escaped}"
    return None


def _configured_workspace(fermix_home: str) -> str:
    home = os.path.realpath(os.path.expanduser(fermix_home))
    with open(os.path.join(home, "config.toml"), "rb") as handle:
        raw = tomllib.load(handle)
    workspace_raw = raw.get("sandbox", {}).get(
        "workspace_root", os.path.join(home, "workspace"))
    return os.path.realpath(os.path.expandvars(os.path.expanduser(workspace_raw)))


def workspace_revision_error(workspace: str, harness_repo: str) -> str | None:
    harness_sha = _git_value(harness_repo, "rev-parse", "HEAD")
    workspace_sha = _git_value(workspace, "rev-parse", "HEAD")
    if harness_sha == "unknown" or workspace_sha == "unknown":
        return "cannot verify harness and disposable-workspace git revisions"
    if workspace_sha != harness_sha:
        return ("disposable workspace HEAD does not match the harness checkout: "
                f"workspace={workspace_sha}, harness={harness_sha}")
    return None


def case_jobs(chosen, repeat: int, max_cases: int = 0,
              operator: bool = True) -> list[tuple]:
    jobs = []
    driven = 0
    for suite, scenarios in chosen:
        for scenario in scenarios:
            for case in scenario.cases:
                for trial in range(1, repeat + 1):
                    if max_cases and driven >= max_cases:
                        return jobs
                    jobs.append((suite, scenario, case, trial))
                    if case.drive == "ask" or operator:
                        driven += 1
    return jobs


def plan_counts(chosen, judge_on: bool, repeat: int = 1,
                max_cases: int = 0, operator: bool = True) -> tuple[int, int, int, int]:
    jobs = case_jobs(chosen, repeat, max_cases, operator)
    scenarios = len({(suite.name, scenario.id)
                     for suite, scenario, _case, _trial in jobs})
    turns = sum(len(case.turns) for _suite, _scenario, case, _trial in jobs
                if case.drive == "ask" or operator)
    judge_turns = sum(
        1 for _suite, _scenario, case, _trial in jobs
        if (case.drive == "ask" or operator) and judge_on and case.judge and case.rubric
    )
    return scenarios, len(jobs), turns, judge_turns


# --- precondition checks ----------------------------------------------------

def check(cfg, require_isolated: bool = False, require_strict: bool = False) -> int:
    sandbox_error = daemon_sandbox_error(
        cfg.daemon.fermix_home, require_isolated, require_strict)
    revision_error = None
    if require_isolated and sandbox_error is None:
        workspace = _configured_workspace(cfg.daemon.fermix_home)
        revision_error = workspace_revision_error(workspace, cfg.skill_dir)
    local_problems = [
        eval_home_error(cfg.daemon.fermix_home, require_isolated),
        eval_project_error(cfg.opik.project, require_isolated),
        sandbox_error,
        revision_error,
    ]
    local_problems = [problem for problem in local_problems if problem]
    if local_problems:
        for problem in local_problems:
            print(f"  [FAIL] {problem}")
        return 3
    environment = "isolated eval" if require_isolated else "development"
    print(f"  [static] configured {environment} home: {cfg.daemon.fermix_home}")
    print(f"  [static] configured Opik project: {cfg.opik.project}")
    if require_isolated:
        suffix = " in strict mode" if require_strict else ""
        print(f"  [static] config declares eval-scoped sandbox roots{suffix}; "
              "running daemon state is unverified")
    ok = True
    client = OpikClient(cfg.opik.base_url, cfg.opik.project,
                        api_key=cfg.opik.api_key, workspace=cfg.opik.workspace)
    try:
        client.ping()
        print(f"  [ok] Opik reachable at {cfg.opik.base_url}")
    except OpikError as exc:
        print(f"  [FAIL] Opik unreachable: {exc}")
        ok = False
    try:
        if client.project_exists():
            print(f"  [ok] Opik project '{cfg.opik.project}' exists")
        else:
            print(f"  [warn] Opik project '{cfg.opik.project}' not found yet "
                  "(it appears after the first exported trace)")
    except OpikError as exc:
        print(f"  [FAIL] Opik project query failed: {exc}")
        ok = False
    reachable, detail = driver.daemon_reachable(cfg)
    if reachable:
        print(f"  [ok] benchmark daemon reachable (FERMIX_HOME={cfg.daemon.fermix_home})")
    else:
        print(f"  [FAIL] benchmark daemon not reachable "
              f"(FERMIX_HOME={cfg.daemon.fermix_home}): {detail}")
        print("         start the dev daemon with FERMIX_OPIK_ENABLED=1 before running; "
              "isolated profiles also override FERMIX_EVAL_HOME and OPIK_PROJECT.")
        ok = False
    import glob as _glob
    n_yaml = len(_glob.glob(os.path.join(SKILL_DIR, "suites", "*.yaml")))
    print(f"  [ok] PyYAML present, {n_yaml} suite file(s)")
    return 0 if ok else 3


def purge(cfg, run_id: str, confirmed: bool) -> int:
    """Preview or delete traces carrying one exact eval run id."""
    target_problem = eval_home_error(
        cfg.daemon.fermix_home, False) or eval_project_error(cfg.opik.project, False)
    if target_problem:
        print(f"purge refused: {target_problem}", file=sys.stderr)
        return 2
    if not valid_run_id(run_id):
        print("--purge-run must be an eval run id like 20260715T151102Z01234567",
              file=sys.stderr)
        return 2
    client = OpikClient(cfg.opik.base_url, cfg.opik.project,
                        api_key=cfg.opik.api_key, workspace=cfg.opik.workspace)
    try:
        ids = client.eval_trace_ids_for_run(run_id)
    except OpikError as exc:
        print(f"Opik unreachable: {exc}", file=sys.stderr)
        return 3
    if not ids:
        print(f"no eval traces for run {run_id!r} in project '{cfg.opik.project}'.")
        return 0
    if not confirmed:
        print(f"preview: {len(ids)} trace(s) belong to run {run_id} in project "
              f"'{cfg.opik.project}'. Rerun with --confirm-purge to delete them.")
        return 0
    try:
        client.delete_traces(ids)
    except OpikError as exc:
        print(f"purge failed and may be partial; re-preview run {run_id} before retrying: {exc}",
              file=sys.stderr)
        return 3
    print(f"purged {len(ids)} trace(s) for run {run_id} from project '{cfg.opik.project}'.")
    return 0


# --- operator-assisted cases (real channel turns) ----------------------------

def eval_daemon_streaming_enabled(cfg) -> bool:
    """True iff the eval daemon config opts Telegram into streaming (draft or block).

    Section-aware scan of `$FERMIX_HOME/config.toml` for
    `[fermix_channels.telegram] streaming = "draft" | "block"`. Config is
    snapshotted at daemon boot, so enabling it also requires a daemon restart —
    the runner can only verify the file, and says so in the failure note.
    """
    path = os.path.join(os.path.expanduser(cfg.daemon.fermix_home), "config.toml")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            section = None
            for line in fh:
                line = line.strip()
                if line.startswith("[") and line.endswith("]"):
                    section = line[1:-1].strip()
                elif section == "fermix_channels.telegram" and line.startswith("streaming"):
                    return '"draft"' in line or '"block"' in line
    except OSError:
        return False
    return False


def operator_requires_streaming(case) -> bool:
    """Only cases that assert stream lifecycle spans need Telegram streaming."""
    for key in ("tools_any", "tools_all", "tools_none", "tools_none_succeeded"):
        if any(name.startswith("stream:") for name in case.expect.get(key, [])):
            return True
    return False


def operator_outcome(gate_ok: bool, evidence_incomplete: bool, rubric: dict | None,
                     rubric_policy: str = "fail") -> str:
    if evidence_incomplete or (rubric is not None and not rubric.get("evaluated")):
        return "incomplete"
    rubric_failed = (rubric_policy == "fail" and rubric is not None
                     and rubric.get("passed") is False)
    if not gate_ok or rubric_failed:
        return "fail"
    return "pass"


def _record_opik_error(rec: dict, exc: OpikError) -> None:
    rec.update({
        "status": "error",
        "drive_error": f"Opik evidence unavailable after preflight: {exc}",
        "note": "turn cannot be graded without trace evidence",
        "correlation": "error",
    })


def run_operator_case(cfg, client, suite, scn, case, run_id, trial, judge_on):
    """Drive one operator-assisted Telegram case.

    The runner cannot inject a Telegram inbound (real Bot API, polling), so the
    operator sends ONE marked message from their own chat; the runner correlates
    the resulting `telegram:*` trace by the marker and grades it exactly like an
    `ask` case. Streaming gates ride the normal tools_* vocabulary because
    stream phases export as tool-type spans named `stream:open|seal|discard`.
    """
    import uuid

    marker = f"e2e-mark-{run_id}-{uuid.uuid4().hex[:6]}"
    query = _render_query(case.turns[0].query, run_id, trial)
    message = f"{query} (eval:{marker})"
    # Human response time makes a CLI-equivalent wall clock unavailable. Keep
    # cost/trace gates, but do not invent latency from Opik or the operator wait.
    eff = {"max_cost_usd": cfg.budgets.max_cost_usd}
    eff.update(case.expect)
    wait_s = (case.timeout_ms or 300_000) / 1000.0

    rec = {"index": 0, "query": message, "session": marker, "status": "error",
           "drive_error": None, "note": None, "correlation": "n/a", "gates": [],
           "tools": [], "reply": "", "cost_usd": 0.0, "duration_ms": 0.0, "tokens": 0,
           "iterations": None, "subagent_spawns": 0, "trace_id": None, "trace_url": "",
           "main_models": [], "main_providers": [], "main_efforts": []}

    if operator_requires_streaming(case) and not eval_daemon_streaming_enabled(cfg):
        rec["drive_error"] = ("streaming not enabled in the eval daemon: set "
                              '[fermix_channels.telegram] streaming = "draft" (or "block") in '
                              f"{cfg.daemon.fermix_home}/config.toml and RESTART the daemon")
        print(f"    FAIL precondition: {rec['drive_error']}")
        return {"id": case.id, "trial": trial, "outcome": "incomplete", "passed": False,
                "incomplete": True, "gate_passed": False,
                "turns": [rec], "rubric": None}

    print(f"\n    OPERATOR ACTION — send this exact message to the eval Telegram bot now:")
    print(f"      {message}")
    for path in case.images:
        print(f"      attach this exact fixture: {path}")
    if case.images:
        print("      put the exact marked message above in the attachment caption")
    print(f"    waiting up to {int(wait_s)}s for the turn's trace…", flush=True)

    after = now_utc() - timedelta(seconds=10)
    try:
        found = client.poll_for_marker("telegram:", marker, after, set(),
                                       wait_s, cfg.opik.poll_interval_s)
    except OpikError as exc:
        _record_opik_error(rec, exc)
        return {"id": case.id, "trial": trial, "outcome": "incomplete", "passed": False,
                "incomplete": True, "gate_passed": False,
                "turns": [rec], "rubric": None}
    if found is None:
        rec["correlation"] = "missing"
        rec["drive_error"] = f"no telegram trace containing '{marker}' appeared within {int(wait_s)}s"
        return {"id": case.id, "trial": trial, "outcome": "incomplete", "passed": False,
                "incomplete": True, "gate_passed": False,
                "turns": [rec], "rubric": None}

    try:
        trace, spans = client.await_complete(found)
    except OpikError as exc:
        _record_opik_error(rec, exc)
        return {"id": case.id, "trial": trial, "outcome": "incomplete", "passed": False,
                "incomplete": True, "gate_passed": False,
                "turns": [rec], "rubric": None}
    gates = grade.grade(
        trace, spans, eff, elapsed_ms=None, require_duration=False)
    view = grade.TurnView.build(
        trace, spans, elapsed_ms=None, require_duration=False)
    rec.update({
        "status": "ok",
        "note": "latency gate omitted for this operator-assisted turn",
        "correlation": "ok",
        "gates": [{"key": g.key, "passed": g.passed, "detail": g.detail} for g in gates],
        "tools": view.tool_names,
        "tool_failures": _tool_failures(view),
        "reply": view.reply,
        "cost_usd": view.cost,
        "duration_ms": view.duration_ms,
        "tokens": view.tokens,
        "iterations": view.iterations,
        "subagent_spawns": view.subagent_spawns,
        "trace_id": trace["id"],
        "trace_url": f"{cfg.opik.ui_base}/api/v1/private/traces/{trace['id']}",
        "main_models": view.main_models,
        "main_providers": view.main_providers,
        "main_efforts": view.main_efforts,
    })
    gate_ok = all(g.passed for g in gates)
    incomplete = _view_incomplete(view)
    if _provider_limit_reply(view.reply):
        rec["status"] = "provider_limited"
        rec["drive_error"] = "provider usage/rate/quota limit; turn is not gradable"
    transcript = [
        {"role": "user", "content": message},
        {"role": "assistant", "content": view.reply},
    ]
    evidence = [_tool_evidence(view, 0)]
    candidate_routes = _candidate_routes_from_turns([rec])
    rubric = None if incomplete else _rubric_record(
        cfg, case, scn, run_id, trial, judge_on, transcript, evidence,
        candidate_routes, candidate_session=marker)
    outcome = operator_outcome(gate_ok, incomplete, rubric, cfg.rubric_failures)
    return {"id": case.id, "trial": trial, "outcome": outcome, "passed": outcome == "pass",
            "incomplete": outcome == "incomplete", "gate_passed": gate_ok,
            "turns": [rec], "rubric": rubric}


# --- run one case -----------------------------------------------------------

def _turn_record(index, query, session, result) -> dict:
    return {
        "index": index, "query": query, "session": session, "status": result.status,
        "drive_error": result.error, "note": None, "correlation": "n/a", "gates": [],
        "tools": [], "reply": "", "cost_usd": 0.0, "duration_ms": result.elapsed_ms,
        "tokens": 0, "iterations": None, "subagent_spawns": 0, "trace_id": None,
        "trace_url": "", "main_models": [], "main_providers": [], "main_efforts": [],
    }


def _bounded_text(value, max_bytes: int) -> str:
    text = value if isinstance(value, str) else json.dumps(
        value, ensure_ascii=False, sort_keys=True, default=str)
    raw = text.encode("utf-8")
    marker = b" [truncated]"
    if len(raw) <= max_bytes:
        return text
    kept = raw[:max_bytes - len(marker)].decode("utf-8", errors="ignore")
    return kept + marker.decode()


def _tool_failures(view) -> list[dict]:
    """Vendor text for each errored tool span, bounded.

    The `no_tool_errors` gate reports only tool NAMES, which is enough to fail a
    case and not enough to explain it: a run where every metered tool refused for
    one external reason looks identical to a run with a real product defect. The
    text is what tells those apart, so it is carried on the record.
    """
    failures = []
    for span in view.tool_spans:
        info = span.get("error_info")
        if not info:
            continue
        text = info if isinstance(info, str) else json.dumps(info, ensure_ascii=False)
        failures.append({"name": _bounded_text(span.get("name"), 128),
                         "error_text": _bounded_text(text, 512)})
    return failures


def _tool_evidence(view, turn_index: int) -> dict:
    tools = []
    for span in view.tool_spans[:_EVIDENCE_TOOL_LIMIT]:
        metadata = span.get("metadata") or {}
        detail = {
            "errored": bool(span.get("error_info")),
            "decision": metadata.get("sandbox_decision") or metadata.get("decision"),
            "input": span.get("input"),
            "output": span.get("output"),
            "error_info": span.get("error_info"),
            "start_time": span.get("start_time"),
            "end_time": span.get("end_time"),
        }
        candidate = {
            "name": _bounded_text(span.get("name"), 128),
            "evidence": _bounded_text(detail, _EVIDENCE_TOOL_MAX_BYTES),
        }
        proposed = tools + [candidate]
        record = {"turn_index": turn_index, "tools": proposed,
                  "omitted_tool_spans": len(view.tool_spans) - len(proposed)}
        encoded = json.dumps(record, ensure_ascii=False).encode("utf-8")
        if len(encoded) > _EVIDENCE_RECORD_MAX_BYTES:
            break
        tools = proposed
    return {"turn_index": turn_index, "tools": tools,
            "omitted_tool_spans": len(view.tool_spans) - len(tools)}


def _record_graded_turn(rec, cfg, trace, gates, view, note) -> None:
    rec.update({
        "status": "ok", "note": note, "correlation": "ok",
        "gates": [{"key": gate.key, "passed": gate.passed, "detail": gate.detail}
                  for gate in gates],
        "tools": view.tool_names, "tool_failures": _tool_failures(view),
        "reply": view.reply, "cost_usd": view.cost,
        "duration_ms": view.duration_ms, "tokens": view.tokens,
        "iterations": view.iterations, "subagent_spawns": view.subagent_spawns,
        "trace_id": trace["id"],
        "trace_url": f"{cfg.opik.ui_base}/api/v1/private/traces/{trace['id']}",
        "main_models": view.main_models, "main_providers": view.main_providers,
        "main_efforts": view.main_efforts,
    })


def _candidate_routes_from_turns(records: list[dict]) -> list[dict]:
    routes = []
    seen = set()
    for record in records:
        models = record.get("main_models") or []
        providers = record.get("main_providers") or []
        efforts = record.get("main_efforts") or []
        for index, model in enumerate(models):
            provider = providers[index] if index < len(providers) else "?"
            effort = efforts[index] if index < len(efforts) else "default"
            key = (str(provider), str(model), str(effort))
            if key in seen:
                continue
            routes.append({"provider": key[0], "model": key[1],
                           "reasoning_effort": key[2]})
            seen.add(key)
    return routes


def _rubric_record(cfg, case, scn, run_id, trial, judge_on, transcript, evidence,
                   candidate_routes, candidate_session=None):
    if not case.rubric:
        return None
    if not judge_on or not case.judge:
        return {"text": case.rubric, "evaluated": False, "passed": None,
                "score": None, "rationale": "", "error": "judge disabled", "backend": ""}
    last_query = next(
        (item["content"] for item in reversed(transcript) if item["role"] == "user"), "")
    reply = next(
        (item["content"] for item in reversed(transcript) if item["role"] == "assistant"), "")
    result = judge.judge_case(
        cfg, last_query, reply, case.rubric,
        tag=candidate_session or sess(run_id, "judge", scn.id, case.id, str(trial)),
        transcript=transcript, tool_evidence=evidence,
        candidate_routes=candidate_routes,
    )
    if not result.evaluated:
        # Without this the only record of a judge outage is `rubric.error`, which
        # `redact_content` blanks — the run goes INCOMPLETE with no stated reason.
        print(f"    judge unavailable: {result.error}", file=sys.stderr, flush=True)
    return {"text": case.rubric, "evaluated": result.evaluated, "passed": result.passed,
            "score": result.score, "rationale": result.rationale, "error": result.error,
            "backend": result.backend, "called": result.called,
            "judge_provider": result.provider, "judge_model": result.model,
            "judge_reasoning_effort": result.reasoning_effort,
            "finish_reason": result.finish_reason,
            "input_tokens": result.input_tokens,
            "output_tokens": result.output_tokens, "total_tokens": result.total_tokens}


def run_case(cfg, client, suite, scn, case, run_id, trial, judge_on):
    budget = {"max_cost_usd": cfg.budgets.max_cost_usd,
              "max_duration_ms": cfg.budgets.max_duration_ms}
    session = sess("e2e", run_id, suite.name, scn.id, case.id, str(trial))
    timeout_ms = case.timeout_ms or cfg.daemon.default_timeout_ms
    poll_s = max(cfg.opik.poll_timeout_s, timeout_ms / 1000.0 + 60)
    seen: set[str] = set()
    records, transcript, evidence = [], [], []
    gate_ok, incomplete = True, False

    for index, turn in enumerate(case.turns):
        query = _render_query(turn.query, run_id, trial)
        expect = dict(budget)
        expect.update(turn.expect)
        if index == len(case.turns) - 1:
            expect.update(case.expect)
        transcript.append({"role": "user", "content": query})
        result = driver.drive_query(cfg, session, query, timeout_ms=timeout_ms,
                                    attachments=(case.images if index == 0 else None))
        rec = _turn_record(index, query, session, result)
        if _provider_limit_reply(result.response):
            rec["status"] = "provider_limited"
            rec["drive_error"] = "provider usage/rate/quota limit; turn is not gradable"
            records.append(rec)
            incomplete = True
            break
        if result.status in ("not_running", "crashed"):
            records.append(rec)
            incomplete = True
            break
        after = result.sent_at - timedelta(seconds=10)
        settle_started = time.monotonic()
        try:
            found = client.poll_for_turn(session, query, after, seen,
                                         poll_s, cfg.opik.poll_interval_s)
        except OpikError as exc:
            _record_opik_error(rec, exc)
            records.append(rec)
            incomplete = True
            break
        if found is None:
            rec["correlation"] = "missing"
            records.append(rec)
            incomplete = True
            break
        seen.add(found["id"])
        try:
            trace, spans = client.await_complete(found)
        except OpikError as exc:
            _record_opik_error(rec, exc)
            records.append(rec)
            incomplete = True
            break
        elapsed_ms = driver.settled_elapsed_ms(result, settle_started)
        gates = grade.grade(trace, spans, expect, elapsed_ms=elapsed_ms)
        view = grade.TurnView.build(trace, spans, elapsed_ms=elapsed_ms)
        reply = view.reply or result.response or ""
        transcript.append({"role": "assistant", "content": reply})
        evidence.append(_tool_evidence(view, index))
        note = None
        if result.status == "timeout":
            note = ("CLI timed out; server trace later settled after "
                    f"{int(view.duration_ms)}ms end-to-end")
        _record_graded_turn(rec, cfg, trace, gates, view, note)
        if _provider_limit_reply(reply):
            rec["status"] = "provider_limited"
            rec["drive_error"] = "provider usage/rate/quota limit; turn is not gradable"
        records.append(rec)
        if _view_incomplete(view):
            incomplete = True
            break
        if any(not gate.passed for gate in gates):
            gate_ok = False

    candidate_routes = _candidate_routes_from_turns(records)
    rubric = None if incomplete else _rubric_record(
        cfg, case, scn, run_id, trial, judge_on, transcript, evidence,
        candidate_routes, candidate_session=session)
    outcome = operator_outcome(gate_ok, incomplete, rubric, cfg.rubric_failures)
    incomplete = outcome == "incomplete"
    return {"id": case.id, "trial": trial, "outcome": outcome, "passed": outcome == "pass",
            "incomplete": incomplete, "gate_passed": gate_ok,
            "turns": records, "rubric": rubric}


# --- aggregation ------------------------------------------------------------

def _git_value(repo_dir: str, *args: str) -> str:
    try:
        proc = subprocess.run(["git", "-C", repo_dir, *args], capture_output=True,
                              text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    return proc.stdout.strip() if proc.returncode == 0 else "unknown"


def _suite_hash(chosen) -> str:
    digest = hashlib.sha256()
    for suite, _scenarios in sorted(chosen, key=lambda item: item[0].path):
        digest.update(os.path.basename(suite.path).encode())
        with open(suite.path, "rb") as handle:
            digest.update(handle.read())
    return digest.hexdigest()


def reproducibility_metadata(cfg, chosen, profiles: set[str]) -> dict:
    repo_dir = cfg.skill_dir
    status = _git_value(repo_dir, "status", "--porcelain")
    harness_sha = _git_value(repo_dir, "rev-parse", "HEAD")
    isolated = requires_isolated_home(profiles)
    if isolated:
        workspace = _configured_workspace(cfg.daemon.fermix_home)
        workspace_status = _git_value(workspace, "status", "--porcelain")
        workspace_sha = _git_value(workspace, "rev-parse", "HEAD")
        workspace_dirty = workspace_status not in ("", "unknown")
        workspace_matches = workspace_sha == harness_sha
        workspace_content = (
            "operator-attested overlay; HEAD verified, dirty content not byte-compared")
    else:
        workspace_sha = None
        workspace_dirty = None
        workspace_matches = None
        workspace_content = "development daemon workspace; not snapshot-pinned"
    return {
        "git_sha": harness_sha,
        "harness_git_sha": harness_sha,
        "git_dirty": status not in ("", "unknown"),
        "workspace_git_sha": workspace_sha,
        "workspace_git_dirty": workspace_dirty,
        "workspace_head_matches_harness": workspace_matches,
        "workspace_content": workspace_content,
        "suite_sha256": _suite_hash(chosen),
        "profiles": sorted(profiles),
        "judge_backend": cfg.judge.backend,
        "judge_model": cfg.judge.model or "daemon-configured",
        "case_order": "suite declaration order",
    }


def redact_content(results: dict) -> dict:
    redacted = copy.deepcopy(results)
    for suite in redacted.get("suites", []):
        for scenario in suite.get("scenarios", []):
            for case in scenario.get("cases", []):
                for turn in case.get("turns", []):
                    turn["query"] = "[redacted by default]"
                    turn["reply"] = "[redacted by default]"
                rubric = case.get("rubric")
                if rubric and rubric.get("rationale"):
                    rubric["rationale"] = "[redacted by default]"
    _redact_error_strings(redacted)
    redacted["config"]["content_retained"] = False
    return redacted


def _redact_error_strings(value, error_context: bool = False) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_context = error_context or "error" in str(key).lower()
            if child_context and isinstance(child, str) and child:
                value[key] = "[redacted by default]"
            else:
                _redact_error_strings(child, child_context)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            if error_context and isinstance(child, str) and child:
                value[index] = "[redacted by default]"
            else:
                _redact_error_strings(child, error_context)


def reliability_summary(suite_results) -> list[dict]:
    groups: dict[tuple[str, str, str], list[str]] = {}
    for suite in suite_results:
        for scenario in suite["scenarios"]:
            for case in scenario["cases"]:
                key = (suite["name"], scenario["id"], case["id"])
                outcomes = case.get("attempt_outcomes") or [case["outcome"]]
                groups.setdefault(key, []).extend(outcomes)
    summary = []
    for (suite, scenario, case), outcomes in sorted(groups.items()):
        if "incomplete" in outcomes:
            status = "incomplete"
        elif len(set(outcomes)) > 1:
            status = "flaky"
        elif outcomes[0] == "pass":
            status = "stable_pass"
        else:
            status = "stable_fail"
        summary.append({"suite": suite, "scenario": scenario, "case": case,
                        "trials": len(outcomes), "outcomes": outcomes, "status": status})
    return summary


def overall_outcome(totals: dict, planned_cases: int, skipped_required: int) -> str:
    if totals.get("cases", 0) == 0:
        return "incomplete"
    if totals.get("cases_failed", 0) > 0:
        return "fail"
    incomplete = totals.get("cases_incomplete", 0) > 0
    selection_incomplete = skipped_required > 0 or totals.get("cases", 0) != planned_cases
    return "incomplete" if incomplete or selection_incomplete else "pass"


def aggregate(cfg, run_id, started, finished, suite_results,
              planned_cases: int, skipped_required: int) -> dict:
    tot = {"scenarios": 0, "cases": 0, "turns": 0, "cases_passed": 0, "cases_failed": 0,
           "cases_incomplete": 0, "critical_failed": 0, "gates": 0, "gates_passed": 0, "rubrics": 0,
           "rubrics_passed": 0, "cost_usd": 0.0, "duration_ms_total": 0.0,
           "judge_calls": 0, "judge_usage_reported_calls": 0, "judge_tokens_reported": 0}
    for s in suite_results:
        st = s["totals"]
        for k in tot:
            tot[k] += st.get(k, 0)
    outcome = overall_outcome(tot, planned_cases, skipped_required)
    return {
        "run_id": run_id,
        "outcome": outcome,
        "started_at": iso(started),
        "finished_at": iso(finished),
        "selection": {"planned_cases": planned_cases, "skipped_required": skipped_required},
        "config": {"daemon_home": cfg.daemon.fermix_home, "opik_project": cfg.opik.project,
                   "judge_backend": cfg.judge.backend, "judge_enabled": tot.get("_judge_on", False)},
        "accounting": {"cost_scope": "candidate traces only; judge cost is not available",
                       "judge_usage_scope": "API-reported token usage only"},
        "totals": tot,
        "suites": suite_results,
    }


def suite_totals(scenario_results) -> dict:
    st = {"scenarios": 0, "cases": 0, "turns": 0, "cases_passed": 0, "cases_failed": 0,
          "cases_incomplete": 0, "critical_failed": 0, "gates": 0, "gates_passed": 0, "rubrics": 0,
          "rubrics_passed": 0, "cost_usd": 0.0, "duration_ms_total": 0.0,
          "judge_calls": 0, "judge_usage_reported_calls": 0, "judge_tokens_reported": 0}
    for scn in scenario_results:
        st["scenarios"] += 1
        for c in scn["cases"]:
            st["cases"] += 1
            st["cases_passed"] += 1 if c["outcome"] == "pass" else 0
            st["cases_failed"] += 1 if c["outcome"] == "fail" else 0
            st["cases_incomplete"] += 1 if c["outcome"] == "incomplete" else 0
            if scn["severity"] == "critical" and c["outcome"] == "fail":
                st["critical_failed"] += 1
            for turn in c["turns"]:
                st["turns"] += 1
                st["cost_usd"] += turn["cost_usd"]
                st["duration_ms_total"] += turn["duration_ms"]
                for g in turn["gates"]:
                    st["gates"] += 1
                    st["gates_passed"] += 1 if g["passed"] else 0
            rb = c.get("rubric")
            if rb and rb.get("called") is True:
                st["judge_calls"] += 1
                if rb.get("total_tokens") is not None:
                    st["judge_usage_reported_calls"] += 1
                    st["judge_tokens_reported"] += rb["total_tokens"]
            if rb and rb["evaluated"]:
                st["rubrics"] += 1
                st["rubrics_passed"] += 1 if rb["passed"] else 0
    return st


# --- main -------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="Fermix E2E eval (Opik trace-based)")
    ap.add_argument("--suite", action="append", help="suite name (repeatable)")
    ap.add_argument("--scenario", action="append", help="scenario id (repeatable)")
    ap.add_argument("--case", action="append", help="case id (repeatable)")
    ap.add_argument("--tag", action="append", help="scenario tag (repeatable)")
    ap.add_argument("--all", action="store_true",
                    help="run all scenarios allowed by the selected profile (host_readonly by default)")
    ap.add_argument("--profile", action="append", choices=RISK_LEVELS,
                    help="execution profile (repeatable; default: host_readonly)")
    ap.add_argument("--judge", action="store_true", help="enable LLM-judge rubric grading")
    ap.add_argument("--dry-run", action="store_true", help="validate + plan only; no daemon calls")
    ap.add_argument("--check", action="store_true", help="check preconditions only")
    ap.add_argument("--purge-run", metavar="RUN_ID",
                    help="preview traces for one exact eval run id, then exit")
    ap.add_argument("--confirm-purge", action="store_true",
                    help="with --purge-run, delete the previewed run's traces")
    ap.add_argument("--max-cases", type=int, default=0, help="cap number of cases driven (0 = no cap)")
    ap.add_argument("--repeat", type=int, default=1,
                    help="run each selected case 1–3 times to expose behavioral flakiness")
    ap.add_argument("--fail-retries", type=int, default=0,
                    help="re-drive a failed case up to N times (0–2); the case fails "
                         "only if the failure reproduces, otherwise it passes and is "
                         "reported as flaky")
    ap.add_argument("--operator", action="store_true",
                    help="include operator-assisted cases (you send a Telegram message when prompted); "
                         "without this flag such cases are skipped with a notice")
    ap.add_argument("--dangerous", action="store_true",
                    help="include suites from suites/dangerous/ — these exercise the sandbox by "
                         "issuing commands that cause real harm if the sandbox fails; only run in "
                         "an isolated, disposable test environment, never on your dev machine "
                         "(requires FERMIX_EVAL_DISPOSABLE=1 to attest that environment)")
    ap.add_argument("--confirm-isolated-env", action="store_true",
                    help="attest that mutable/desktop/destructive profiles target a disposable environment")
    ap.add_argument(
        "--confirm-daemon-isolated",
        action="store_true",
        help=("for isolated profiles, attest the daemon was restarted against the disposable "
              "eval home/project with no unrelated channels/realtime and a headless browser"),
    )
    ap.add_argument("--confirm-private-data", action="store_true",
                    help="consent to sending private data to candidate/judge providers and the trace store")
    ap.add_argument("--confirm-cost", action="store_true",
                    help="acknowledge the expensive profile's potentially large model spend")
    ap.add_argument("--include-content", action="store_true",
                    help="retain full prompts/replies in reports (redacted by default)")
    ap.add_argument("--out", default=None, help="report output dir (default: reports/<ts>)")
    ap.add_argument("--config", default=None, help="behavioral config path")
    return ap


def _argument_error(args) -> str | None:
    if args.max_cases < 0:
        return "--max-cases must be zero or a positive integer"
    if args.repeat < 1 or args.repeat > 3:
        return "--repeat must be between 1 and 3"
    if args.fail_retries < 0 or args.fail_retries > 2:
        return "--fail-retries must be between 0 and 2"
    if args.confirm_purge and not args.purge_run:
        return "--confirm-purge requires --purge-run RUN_ID"
    control_modes = sum(bool(mode) for mode in (args.dry_run, args.check, args.purge_run))
    if control_modes > 1:
        return "--dry-run, --check, and --purge-run are mutually exclusive"
    return None


def _load_selection(args, profiles):
    suites = load_all(
        os.path.join(SKILL_DIR, "suites"), include_dangerous=args.dangerous)
    chosen = select(suites, args, profiles)
    return suites, chosen, behavioral_schema_errors(chosen)


def _selection_error(args, suites, chosen, profiles) -> str | None:
    has_filter = bool(args.suite or args.scenario or args.case or args.tag)
    if not (args.all or has_filter):
        available = ", ".join(suite.name for suite in suites)
        return ("nothing selected. Pass --all, --suite NAME, --scenario ID, --case ID, "
                "or --tag TAG "
                f"(refusing implicit spend). Available suites: {available}")
    selector_errors = unmatched_selector_errors(suites, args, profiles)
    if selector_errors:
        return "; ".join(selector_errors)
    if not chosen:
        return f"selection matched no scenarios allowed by profiles {sorted(profiles)}"
    return None


def _print_dry_run(chosen, profiles, judge_on: bool, args) -> int:
    jobs = case_jobs(chosen, args.repeat, args.max_cases, args.operator)
    nsc, nc, nt, _judge_turns = plan_counts(
        chosen, judge_on, args.repeat, args.max_cases, args.operator)
    suites_planned = len({suite.name for suite, _scenario, _case, _trial in jobs})
    driven = sum(1 for _suite, _scenario, case, _trial in jobs
                 if case.drive == "ask" or args.operator)
    skipped = nc - driven
    print(f"dry-run OK — profiles={sorted(profiles)} · {suites_planned} suite(s), "
          f"{nsc} scenario(s), {driven} case trial(s) would run, "
          f"{skipped} operator trial(s) would skip, {nt} real turn(s).")
    for suite, scenario, case, trial in jobs:
        action = "run" if case.drive == "ask" or args.operator else "skip: needs --operator"
        print(f"  - {suite.name}/{scenario.id}/{case.id}#{trial} "
              f"[{scenario.risk}; {action}]")
    return 0 if driven > 0 else 4


def _record_case(tree: dict, suite, scenario, case_result: dict) -> None:
    suite_entry = tree.setdefault(suite.name, {"suite": suite, "scenarios": {}})
    scenario_entry = suite_entry["scenarios"].setdefault(
        scenario.id, {"scenario": scenario, "cases": []})
    scenario_entry["cases"].append(case_result)


def _scenario_result(entry: dict) -> dict:
    scenario = entry["scenario"]
    cases = entry["cases"]
    return {"id": scenario.id, "title": scenario.title, "severity": scenario.severity,
            "risk": scenario.risk, "tags": scenario.tags, "cases": cases,
            "passed": all(case["outcome"] == "pass" for case in cases)}


def _suite_result(entry: dict) -> dict:
    suite = entry["suite"]
    scenarios = [_scenario_result(item) for item in entry["scenarios"].values()]
    return {"name": suite.name, "title": suite.title, "scenarios": scenarios,
            "totals": suite_totals(scenarios)}


def _opik_incomplete_result(suite, scenario, case, run_id: str, trial: int,
                            exc: OpikError) -> dict:
    query = _render_query(case.turns[0].query, run_id, trial)
    session = sess("e2e", run_id, suite.name, scenario.id, case.id, str(trial))
    rec = {
        "index": 0, "query": query, "session": session, "status": "error",
        "drive_error": f"Opik evidence unavailable after preflight: {exc}",
        "note": "turn cannot be graded without trace evidence", "correlation": "error",
        "gates": [], "tools": [], "reply": "", "cost_usd": 0.0,
        "duration_ms": 0.0, "tokens": 0, "iterations": None,
        "subagent_spawns": 0, "trace_id": None, "trace_url": "",
        "main_models": [], "main_providers": [], "main_efforts": [],
    }
    return {"id": case.id, "trial": trial, "outcome": "incomplete", "passed": False,
            "incomplete": True, "gate_passed": False, "turns": [rec], "rubric": None}


def _drive_case(cfg, client, suite, scenario, case, run_id: str, trial: int,
                judge_on: bool) -> dict:
    try:
        if case.drive == "telegram_operator":
            return run_operator_case(
                cfg, client, suite, scenario, case, run_id, trial, judge_on)
        return run_case(cfg, client, suite, scenario, case, run_id, trial, judge_on)
    except OpikError as exc:
        return _opik_incomplete_result(suite, scenario, case, run_id, trial, exc)


def _case_verdict(attempts: list[dict]) -> dict:
    if len(attempts) == 1:
        return attempts[0]
    outcomes = [attempt["outcome"] for attempt in attempts]
    if outcomes.count("fail") >= 2:
        final = next(a for a in reversed(attempts) if a["outcome"] == "fail")
    elif "pass" in outcomes:
        final = next(a for a in reversed(attempts) if a["outcome"] == "pass")
    else:
        final = attempts[-1]
    final = dict(final)
    final["attempt_outcomes"] = outcomes
    final["flaky"] = len(set(outcomes)) > 1
    return final


def _abort_signal(suite, result: dict) -> dict | None:
    """The first tool failure matching a fragment the suite declared terminal.

    An exhausted external account is not a product signal. Every case driven
    after the balance hits zero fails `no_tool_errors` for a reason the daemon
    did not cause, so those results are void, not red — an observed eden run
    spent its EdenAI credits mid-suite and banked nine meaningless failures that
    cost more to diagnose than the run was worth.
    """
    for turn in result.get("turns", []):
        for failure in turn.get("tool_failures", []):
            message = failure.get("error_text") or ""
            fragment = next((f for f in suite.abort_on_tool_error if f in message), None)
            if fragment:
                return {"suite": suite.name, "case": result["id"],
                        "tool": failure.get("name"), "fragment": fragment,
                        "message": message}
    return None


def _voided(result: dict) -> dict:
    """Demote a case whose result the abort condition invalidates."""
    voided = dict(result)
    voided.update({"outcome": "incomplete", "passed": False, "incomplete": True})
    return voided


def _drive_with_retries(cfg, client, suite, scenario, case, run_id, trial,
                        judge_on, fail_retries: int, repeat: int):
    """Drive one case, re-driving an unconfirmed fail. Stops early on abort.

    A retry after the abort condition would spend more of the exhausted resource
    to reproduce a failure already explained, so the signal short-circuits it.
    """
    attempts = [_drive_case(cfg, client, suite, scenario, case, run_id, trial, judge_on)]
    abort = _abort_signal(suite, attempts[-1]) if suite.abort_on_tool_error else None
    for retry in range(1, fail_retries + 1):
        outcomes = [attempt["outcome"] for attempt in attempts]
        if abort or outcomes.count("fail") != 1 or outcomes[-1] == "incomplete":
            break
        retry_trial = trial + repeat * retry
        print(f"    fail unconfirmed — retrying as #{retry_trial} …", flush=True)
        attempts.append(_drive_case(cfg, client, suite, scenario, case,
                                    run_id, retry_trial, judge_on))
        abort = _abort_signal(suite, attempts[-1]) if suite.abort_on_tool_error else None
    return attempts, abort


def _execute_jobs(cfg, client, jobs, run_id: str, judge_on: bool, operator: bool,
                  fail_retries: int = 0, repeat: int = 1):
    tree: dict = {}
    skipped_required = 0
    aborted = None
    for index, (suite, scenario, case, trial) in enumerate(jobs):
        label = f"{suite.name}/{scenario.id}/{case.id}#{trial}"
        if case.drive != "ask" and not operator:
            print(f"  · {label} — SKIPPED "
                  "(operator-assisted; rerun with --operator)", flush=True)
            skipped_required += 1
            continue
        print(f"  · {label} …", flush=True)
        attempts, abort = _drive_with_retries(
            cfg, client, suite, scenario, case, run_id, trial, judge_on,
            fail_retries, repeat)
        result = _case_verdict(attempts)
        result = _voided(result) if abort else result
        _record_case(tree, suite, scenario, result)
        note = f" · attempts {'/'.join(result['attempt_outcomes'])}" \
            if len(attempts) > 1 else ""
        print(f"    {result['outcome'].upper()} "
              f"(gates {'ok' if result['gate_passed'] else 'FAILED'}){note}")
        if abort:
            aborted = dict(abort, unrun=len(jobs) - index - 1)
            _print_abort(aborted)
            break
    return [_suite_result(entry) for entry in tree.values()], skipped_required, aborted


def _persistable_abort(aborted: dict) -> dict:
    """The abort record minus the vendor's raw text.

    `fragment` is the operator's own literal from the suite YAML, so it is safe
    to persist unredacted; the full vendor message can quote user content and
    stays on the console, under the same policy `_redact_error_strings` applies
    to every other error string.
    """
    return {key: value for key, value in aborted.items() if key != "message"}


def _print_abort(aborted: dict) -> None:
    print(f"\n  RUN ABORTED — {aborted['suite']}/{aborted['case']} hit a terminal "
          f"condition on `{aborted['tool']}`:")
    print(f"    {aborted['message']}")
    print(f"  {aborted['unrun']} remaining case(s) were NOT run. This is an external "
          "account condition,\n  not a product failure: results already banked in this "
          "run stand, and the case that\n  hit it is reported INCOMPLETE rather than "
          "failed.", flush=True)


def _write_run_reports(cfg, args, chosen, profiles, run_id: str, started,
                       suite_results, planned_cases: int, skipped_required: int,
                       aborted: dict | None = None) -> int:
    results = aggregate(cfg, run_id, started, now_utc(), suite_results,
                        planned_cases, skipped_required)
    if aborted:
        results["aborted"] = _persistable_abort(aborted)
    results["config"]["judge_enabled"] = args.judge or cfg.judge.enabled
    results["config"]["content_retained"] = args.include_content
    results["reproducibility"] = reproducibility_metadata(cfg, chosen, profiles)
    results["reproducibility"].update({"repeat": args.repeat,
                                        "fail_retries": getattr(args, "fail_retries", 0),
                                        "max_cases": args.max_cases or None})
    results["reliability"] = reliability_summary(suite_results)
    out_dir = args.out or os.path.join(cfg.report_dir, run_id)
    report_results = results if args.include_content else redact_content(results)
    paths = report.write(report_results, out_dir)
    totals = results["totals"]
    print(f"\n{'='*60}")
    flaky = sum(1 for entry in results["reliability"] if entry["status"] == "flaky")
    print(f"outcome {results['outcome'].upper()} · "
          f"cases {totals['cases_passed']}/{totals['cases']} passed · "
          f"failed {totals['cases_failed']} · flaky {flaky} · "
          f"incomplete {totals['cases_incomplete']} · "
          f"critical fails {totals['critical_failed']} · "
          f"gates {totals['gates_passed']}/{totals['gates']} · "
          f"candidate trace cost ${totals['cost_usd']:.4f} · "
          f"judge calls {totals['judge_calls']} "
          f"({totals['judge_tokens_reported']} reported tok across "
          f"{totals['judge_usage_reported_calls']} call(s))")
    if aborted:
        print(f"ABORTED at {aborted['suite']}/{aborted['case']} on `{aborted['fragment']}` · "
              f"{aborted['unrun']} case(s) not run — remaining results are unknown, not failed")
    print(f"report: {paths['md']}")
    print(f"        {paths['html']}")
    return {"pass": 0, "fail": 1, "incomplete": 4}[results["outcome"]]


def _run_selected(cfg, args, chosen, profiles, judge_on: bool) -> int:
    print("preconditions:")
    require_isolated = requires_isolated_home(profiles)
    require_strict = requires_strict_sandbox(profiles)
    if check(cfg, require_isolated=require_isolated, require_strict=require_strict) != 0:
        return 3
    if require_isolated:
        print("  [operator-attested] disposable daemon isolation and launch flags")
    else:
        print(f"  [dev] using local development daemon at {cfg.daemon.fermix_home}")
    _all_scenarios, all_cases, _all_turns, _all_judges = plan_counts(
        chosen, judge_on, args.repeat, operator=args.operator)
    nsc, nc, nt, njudge = plan_counts(
        chosen, judge_on, args.repeat, args.max_cases, args.operator)
    jobs = case_jobs(chosen, args.repeat, args.max_cases, args.operator)
    driven = sum(1 for _suite, _scenario, case, _trial in jobs
                 if case.drive == "ask" or args.operator)
    skipped = nc - driven
    if args.max_cases:
        print(f"note: --max-cases {args.max_cases} "
              f"(will drive {driven}; {all_cases} uncapped selection entries)")
    print(f"\nplan: {nsc} scenario(s), {driven} driven case(s), "
          f"{skipped} operator skip(s), ~{nt + njudge} real turns "
          f"({nt} eval + {njudge} judge). These are real model calls and may be billed. "
          "Driving now...\n")
    client = OpikClient(cfg.opik.base_url, cfg.opik.project,
                        api_key=cfg.opik.api_key, workspace=cfg.opik.workspace)
    run_id = new_run_id()
    started = now_utc()
    suite_results, skipped_required, aborted = _execute_jobs(
        cfg, client, jobs, run_id, judge_on, args.operator,
        fail_retries=args.fail_retries, repeat=args.repeat)
    return _write_run_reports(
        cfg, args, chosen, profiles, run_id, started, suite_results, nc,
        skipped_required, aborted)


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)

    try:
        config_path = args.config or os.path.join(SKILL_DIR, "behavioral_config.yaml")
        cfg = cfgmod.load(SKILL_DIR, config_path)
    except (OSError, ValueError) as exc:
        print(f"configuration invalid: {exc}", file=sys.stderr)
        return 2
    judge_on = args.judge or cfg.judge.enabled

    argument_error = _argument_error(args)
    if argument_error:
        print(argument_error, file=sys.stderr)
        return 2

    profiles = selected_profiles(args)
    if args.purge_run:
        return purge(cfg, args.purge_run, args.confirm_purge)
    if args.check:
        print("preconditions:")
        check_result = check(
            cfg,
            require_isolated=requires_isolated_home(profiles),
            require_strict=requires_strict_sandbox(profiles),
        )
        if check_result != 0:
            return check_result
        judge_error = judge_precondition_error(cfg, judge_on)
        if judge_error:
            print(f"  [FAIL] judge: {judge_error}")
            return 3
        if judge_on:
            print("  [ok] restricted judge route configured")
        return 0

    policy_error = None if args.dry_run else profile_policy_error(profiles, args)
    if policy_error:
        print(f"profile policy refused selection: {policy_error}", file=sys.stderr)
        return 2
    disposable_error = dangerous_disposable_error(args)
    if disposable_error:
        print(disposable_error, file=sys.stderr)
        return 2
    if args.dangerous and not (args.suite or args.scenario or args.case):
        print("--dangerous requires --suite <name>, --scenario <id>, or --case <id>: "
              "refusing to run all "
              "dangerous suites at once.", file=sys.stderr)
        return 2

    try:
        suites, chosen, schema_errors = _load_selection(args, profiles)
    except SuiteError as exc:
        print(f"suite validation failed ({len(exc.problems)} problem(s)):", file=sys.stderr)
        for p in exc.problems:
            print(f"  - {p}", file=sys.stderr)
        return 2
    if schema_errors:
        print("behavioral runner rejected unsupported case fields:", file=sys.stderr)
        for problem in schema_errors:
            print(f"  - {problem}", file=sys.stderr)
        return 2

    selection_error = _selection_error(args, suites, chosen, profiles)
    if selection_error:
        print(selection_error, file=sys.stderr)
        return 2

    additive_policy_error = None if args.dry_run else selection_policy_error(chosen, args)
    if additive_policy_error:
        print(f"profile policy refused selection: {additive_policy_error}", file=sys.stderr)
        return 2

    high_impact_error = high_impact_selection_error(profiles, args, chosen)
    if high_impact_error:
        print(f"profile policy refused selection: {high_impact_error}", file=sys.stderr)
        return 2

    jobs = case_jobs(chosen, args.repeat, args.max_cases, args.operator)
    required_judging = required_judge_cases(jobs, args.operator)
    requirement_error = judge_requirement_error(required_judging) if not judge_on else None
    if requirement_error:
        print(requirement_error, file=sys.stderr)
        return 3
    if args.dry_run:
        return _print_dry_run(chosen, profiles, judge_on, args)

    judge_error = judge_precondition_error(cfg, judge_on)
    if judge_error:
        print(f"judge precondition failed: {judge_error}", file=sys.stderr)
        return 3
    return _run_selected(cfg, args, chosen, profiles, judge_on)


if __name__ == "__main__":
    sys.exit(main())
