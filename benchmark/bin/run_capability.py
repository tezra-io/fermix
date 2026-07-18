#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7", "certifi"]
# ///
"""Fermix capability eval — score the model the dev daemon currently serves.

Runs a ground-truth task suite (suites/capability/*.yaml) k trials per task,
scores each trial objectively (closed-form scorer, else LLM judge) with safety as
a hard gate, aggregates to pass@1 / pass^k / tokens·$-per-success, writes an Opik
experiment + feedback scores next to the traces the daemon already exported, and
upserts the result into a cross-config leaderboard.

A cross-MODEL sweep is operator-driven (the safe path — we never restart your
daemon): point the dev daemon at the next provider/model, restart it, run again.
Each run auto-detects the served model from the trace and adds a row; the
leaderboard re-ranks. See SKILL.md.

Exit: 0 ok · 2 usage/selection · 3 preconditions (Opik or daemon down) ·
4 incomplete sweep (usage limit or judge failure; no leaderboard row written).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import time
import tomllib
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from evallib import (aggregate, checker, config as cfgmod, driver, grade, judge, leaderboard,
                     scoring, uplift)
from evallib.experiments import ExperimentWriter, OpikWriteError, stable_id
from evallib.opik import OpikClient, OpikError
from evallib.suites import UNCLASSIFIED_RISK, SuiteError, load_all

# Negative "must-not" gates: a failure here is a safety violation that zeroes the
# task regardless of answer correctness (§4 hard gate).
SAFETY_GATES = ("tools_none", "reply_not_matches")
CAP_DIR = os.path.join(SKILL_DIR, "suites", "capability")
DATASET = "fermix-capability"


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def sess(*parts: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]+", "-", "-".join(parts))[:90]


def _checker_fingerprint(case) -> str:
    """Grading identity of a checker task: its spec PLUS a content hash of the checker
    script, so editing a checker's grading LOGIC (not just its path) changes the task
    hash — a re-graded run can't then silently compare as the same task set."""
    if not case.checker_spec:
        return ""
    script = case.checker_spec.get("script") or ""
    digest = "no-script"
    if script:
        try:
            with open(checker.resolve_script(SKILL_DIR, script), "rb") as fh:
                digest = hashlib.sha256(fh.read()).hexdigest()[:12]
        except (checker.CheckerBoundaryError, OSError):
            pass
    return f"{script}:{case.checker_spec.get('mode')}:{case.checker_spec.get('seed')}:{digest}"


def tasks_hash(cases) -> str:
    """Content hash of the SELECTED tasks — the reproducibility pin. Covers the query,
    the scorer (score spec / checker spec + script CONTENT / rubric), the provenance
    requirement and the cross-session flag, so any change that alters what's asked or how
    it's graded yields a DISTINCT hash (a `--max-tasks`/`--suite` subset, or a re-graded
    run, can't masquerade as a prior full run), while a prose-only edit leaves it
    unchanged. Hashes the selected cases, not the suite files."""
    h = hashlib.sha256()
    rows = sorted(
        f"{s.name}/{c.id}|{c.turns[-1].query}|{c.score_spec}|{_checker_fingerprint(c)}|"
        f"{c.rubric}|{sorted(c.requires_tools)}|{c.cross_session}"
        for s, _scn, c in cases)
    for row in rows:
        h.update(row.encode("utf-8"))
    return h.hexdigest()[:16]


def _selection_label(args) -> str:
    """Human-readable record of the active selection filter (complements tasks_hash)."""
    parts = []
    if args.suite:
        parts.append("suite=" + ",".join(args.suite))
    if args.tag:
        parts.append("tag=" + ",".join(args.tag))
    if args.max_tasks:
        parts.append(f"max={args.max_tasks}")
    return ";".join(parts) or "all"


@dataclass
class TaskOutcome:
    stats: aggregate.TaskStats
    repr_trace_id: str | None        # first trial's trace, linked into the experiment
    item_data: dict                  # dataset-item payload (query/expected/tag)
    trial_traces: list[tuple[str, float]]  # (trace_id, effective_success) per trial
    models: list[str]                # main-agent models seen (config detection)


class JudgeUnavailable(RuntimeError):
    """A required judge result was not gradeable; the sweep must stay incomplete."""

    def __init__(self, case_id: str, error: str):
        super().__init__(error)
        self.case_id = case_id
        self.error = error
        self.suite = None
        self.trial = None

    def locate(self, suite: str, case_id: str, trial: int) -> None:
        self.suite = suite
        self.case_id = case_id
        self.trial = trial


# --- selection --------------------------------------------------------------

def capability_cases(suites, want_suites, want_tags, max_tasks, want_judge):
    """Select scored cases. A rubric-only case (no `score:` block) is gradeable
    only with the judge on; with judge off it would silently score 0 and drag the
    config's headline down, so skip it (and report how many) rather than counting
    an un-evaluated task as a failure."""
    out, skipped = [], 0
    for s in suites:
        explicit = bool(want_suites) and s.name in want_suites
        if want_suites and not explicit:
            continue
        if s.soft and not explicit:
            # A soft/taste suite (judge-scored 0..1, no ground truth) must never fold into
            # the correctness composite or share its tasks_hash — its scores are noisy and
            # directional. Run it on its OWN axis with `--suite <name>` (see the suite doc).
            continue
        for scn in s.scenarios:
            if want_tags and not (set(want_tags) & set(scn.tags)):
                continue
            for case in scn.cases:
                if case.score_spec or case.checker_spec:
                    out.append((s, scn, case))
                elif case.rubric and want_judge:
                    out.append((s, scn, case))
                elif case.rubric:
                    skipped += 1
    return (out[:max_tasks] if max_tasks else out), skipped


def _capability_risk_error(cases, args) -> str | None:
    risks = {scenario.risk for _suite, scenario, _case in cases}
    if UNCLASSIFIED_RISK in risks:
        return "every capability scenario must declare an execution risk"
    unsupported = risks & {
        "private_account_read", "external_write", "desktop_input", "destructive"}
    if unsupported:
        names = ", ".join(sorted(unsupported))
        return (f"capability runner refuses high-impact risk(s) {names}; use the "
                "behavioral runner's named, confirmation-gated workflow")
    if _capability_requires_isolated_home(cases) and not args.confirm_isolated_env:
        return ("isolated_mutation and checker-backed capability tasks require "
                "--confirm-isolated-env")
    if _capability_requires_cost_confirmation(cases) and not args.confirm_cost:
        return "expensive capability tasks require --confirm-cost"
    return None


def _independent_judge_error(cfg, want_judge: bool) -> str | None:
    if not want_judge:
        return None
    return judge.precondition_error(cfg)


# --- one trial / one task ---------------------------------------------------

def _safety_ok(trace, spans, expect, elapsed_ms: float) -> bool:
    relevant = {k: expect[k] for k in SAFETY_GATES if k in expect}
    if not relevant:
        return True
    gates = grade.grade(trace, spans, relevant, elapsed_ms=elapsed_ms)
    return all(gate.passed for gate in gates if gate.key in relevant)


def _provenance_ok(requires_tools, tool_names) -> bool:
    """A task that DECLARES required tools passes provenance only if ≥1 of them
    fired on the trace. A task that declares none always passes. Keeps a correct
    answer reached from parametric recall (no tool span) from earning credit."""
    return not requires_tools or bool(set(requires_tools) & set(tool_names))


def _gradeable(view) -> bool:
    return view.trace_complete and view.telemetry_complete


def _task_success(cfg, case, reply, want_judge, tag,
                  candidate_routes) -> tuple[float, str]:
    if case.score_spec:
        s = scoring.score_answer(reply, case.score_spec)
        return s.score, s.detail
    if case.rubric and want_judge:
        jr = judge.judge_case(
            cfg, case.turns[-1].query, reply, case.rubric, tag,
            candidate_routes=candidate_routes)
        if jr.evaluated and jr.score is not None:
            return jr.score, f"judge {jr.score:.2f}: {jr.rationale[:60]}"
        raise JudgeUnavailable(case.id, jr.error or "judge result was not gradeable")
    return 0.0, "no score_spec and judge off (skip-scored 0)"


@dataclass
class _Captured:
    """One driven turn's graded projection (or the reason it couldn't be graded)."""
    status: str                          # graded | no_trace | opik_error | not_running | crashed
    view: "grade.TurnView | None"
    trace: dict | None
    spans: list | None
    elapsed_ms: float


def _capture_turn(cfg, opik, session, query, timeout_ms, label) -> _Captured:
    """Drive ONE turn and return its graded view. Daemon down / binary missing →
    no server-side trace, hard fail. A CLI timeout or daemon-side error still polls
    the completed server-side trace (latency != capability). An Opik read failure is
    recorded, never raised, so one flake can't abort a multi-minute sweep."""
    # On a usage/rate/quota limit this waits out the configured backoff and retries
    # (in a fresh session), only raising UsageLimitHit once the schedule is exhausted —
    # so a mid-sweep limit is ridden out, not scored as a failure. `used_session` is
    # the session the (possibly retried) turn actually ran in — poll THAT trace.
    res, used_session = driver.drive_with_usage_retry(cfg, session, query, timeout_ms, label)
    if res.status in ("not_running", "crashed"):
        return _Captured(res.status, None, None, None, res.elapsed_ms)
    try:
        # 10s clock-skew slack (daemon vs harness clock), mirroring run_eval; the
        # unique per-trial session already prevents grabbing a stale trace.
        after = res.sent_at - timedelta(seconds=10)
        settle_started = time.monotonic()
        hit = opik.poll_for_turn(used_session, query, after, set(),
                                 cfg.opik.poll_timeout_s, cfg.opik.poll_interval_s)
        if hit is None:
            elapsed_ms = driver.settled_elapsed_ms(res, settle_started)
            return _Captured(
                "no_trace" if res.ok else res.status, None, None, None, elapsed_ms)
        if res.status == "timeout":
            print(f"    · {label}: CLI wait elapsed; graded from the completed server-side "
                  f"trace (latency, not a failure)", file=sys.stderr)
        trace, spans = opik.await_complete(hit)
        elapsed_ms = driver.settled_elapsed_ms(res, settle_started)
        view = grade.TurnView.build(trace, spans, elapsed_ms=elapsed_ms)
        incomplete = not _gradeable(view) or driver.is_usage_limit_reply(view.reply)
        if incomplete:
            return _Captured("incomplete", view, trace, spans, elapsed_ms)
        return _Captured("graded", view, trace, spans, elapsed_ms)
    except OpikError as exc:
        print(f"    ! opik read failed for {label}: {exc}", file=sys.stderr)
        elapsed_ms = driver.settled_elapsed_ms(res, settle_started)
        return _Captured("opik_error", None, None, None, elapsed_ms)


def _models_of(view) -> list[str]:
    """provider/model/effort labels off the main-agent llm spans (config detection)."""
    return [f"{p}/{m}/{e}"
            for p, m, e in zip(view.main_providers, view.main_models, view.main_efforts)]


def _candidate_routes(view) -> list[dict]:
    return [
        {"provider": provider, "model": model, "reasoning_effort": effort}
        for provider, model, effort in zip(
            view.main_providers, view.main_models, view.main_efforts)
    ]


def _fail_trial(case, cap) -> tuple[aggregate.TrialResult, None, list]:
    safety_ok = True
    if cap.trace is not None and cap.spans is not None:
        safety_ok = _safety_ok(cap.trace, cap.spans, case.expect, cap.elapsed_ms)
    view = cap.view
    return (aggregate.score_trial(
        case.id, task_success=0.0, safety_ok=safety_ok,
        cost=view.cost if view else 0.0, duration_ms=cap.elapsed_ms,
        tokens=view.tokens if view else 0,
        tool_calls=len(view.tool_spans) if view else 0, status=cap.status), None, [])


def _score_trial(case, cap, succ) -> tuple[aggregate.TrialResult, str | None, list]:
    view = cap.view
    ok = _safety_ok(cap.trace, cap.spans, case.expect, cap.elapsed_ms)
    tr = aggregate.score_trial(case.id, task_success=succ, safety_ok=ok, cost=view.cost,
        duration_ms=cap.elapsed_ms, tokens=view.tokens, tool_calls=len(view.tool_spans),
        status=view.status, trace_id=cap.trace.get("id"))
    return (tr, cap.trace.get("id"), _models_of(view))


def _xsession_token(s_name, case_id, run_id, i) -> str:
    """A distinctive, deterministic, per-RUN-unique fact to plant and recall. Unique
    per run so a token left in durable memory by an earlier run can't false-green a
    broken store; deterministic so a resumed run reproduces it."""
    h = hashlib.sha256(f"{s_name}/{case_id}/{run_id}/t{i}".encode()).hexdigest()[:6]
    return f"kestrel-{h}"


def _xsession_subject(s_name, case_id, run_id, i) -> str:
    """A per-trial-unique ENTITY KEY the recall turn references, so a fresh recall
    targets THIS trial's fact instead of colliding with a near-identical fact left in the
    shared durable store by an EARLIER run — the reused-subject collision that made the
    memory tasks score a deterministic 0 even though durable memory works. Distinct
    derivation from `_xsession_token` so the entity and the value never coincide."""
    h = hashlib.sha256(f"subj/{s_name}/{case_id}/{run_id}/t{i}".encode()).hexdigest()[:6]
    return f"ref-{h}"


def _standard_trial(cfg, opik, s, case, run_id, i, is_checker, task_key, fixture_path,
                    cleanup_root, want_judge):
    session = sess("e2e-cap", run_id, s.name, case.id, f"t{i}")
    query = case.turns[-1].query
    scoped = checker.scoped_dir(cfg.daemon.fermix_home, task_key, i) if is_checker else None
    try:
        if is_checker:
            # Fresh scoring dir under the conventional capability workspace. This
            # is not containment; the disposable daemon owns the broader sandbox.
            checker.seed_workspace(scoped, SKILL_DIR, fixture_path, cleanup_root)
            query = query.replace("{ws}", scoped)
        cap = _capture_turn(cfg, opik, session, query, case.timeout_ms, f"{case.id} t{i}")
        if cap.status != "graded" or cap.view is None:
            return _fail_trial(case, cap)
        if is_checker:
            cr = checker.run_checker(SKILL_DIR, case.checker_spec, scoped, cap.view.reply)
            if cr.error:
                print(f"    ! checker error {case.id} t{i}: {cr.error}", file=sys.stderr)
            succ = cr.score
        else:
            succ, _detail = _task_success(
                cfg, case, cap.view.reply, want_judge, session,
                _candidate_routes(cap.view))
        # Tool-provenance gate: a task that DECLARES required tools scores 0 unless ≥1
        # fired — a right answer reached WITHOUT the tool is parametric recall, not tool
        # use, and earns no credit. This is what makes uplift vs a tool-less arm real.
        if not _provenance_ok(case.requires_tools, cap.view.tool_names):
            print(f"    · {case.id} t{i}: no required tool {case.requires_tools} fired "
                  f"(ran={sorted(set(cap.view.tool_names))}) — provenance fail", file=sys.stderr)
            succ = 0.0
        return _score_trial(case, cap, succ)
    finally:
        if scoped and os.path.isdir(scoped):  # always clean full or partial seeds
            checker.teardown_workspace(cleanup_root, scoped)


def _cross_session_trial(cfg, opik, s, case, run_id, i):
    """Store a tokened fact in session A, then recall it in a FRESH session B (same
    owner). Because B shares NO conversation context, a correct recall can only come
    from owner-scoped DURABLE memory carried across sessions — the one thing the
    single-thread memory suite can't test, and where a raw/tool-less model scores 0
    (the uplift signal)."""
    token = _xsession_token(s.name, case.id, run_id, i)
    subject = _xsession_subject(s.name, case.id, run_id, i)
    store_q = case.turns[0].query.replace("{subject}", subject).replace("{token}", token)
    recall_q = case.turns[1].query.replace("{subject}", subject).replace("{token}", token)
    sess_a = sess("e2e-cap", run_id, s.name, case.id, f"t{i}", "store")
    sess_b = sess("e2e-cap", run_id, s.name, case.id, f"t{i}", "recall")

    store = _capture_turn(cfg, opik, sess_a, store_q, case.timeout_ms, f"{case.id} t{i} store")
    if store.status != "graded" or store.view is None:
        return _fail_trial(case, store)   # infra failure on store → recall is meaningless
    cap = _capture_turn(cfg, opik, sess_b, recall_q, case.timeout_ms, f"{case.id} t{i} recall")
    if cap.status != "graded" or cap.view is None:
        return _fail_trial(case, cap)
    spec = {**case.score_spec, "expected": str(case.score_spec["expected"]).replace("{token}", token)}
    succ = scoring.score_answer(cap.view.reply, spec).score
    if not _provenance_ok(case.requires_tools, cap.view.tool_names):
        print(f"    · {case.id} t{i} recall: no required tool {case.requires_tools} fired "
              f"(ran={sorted(set(cap.view.tool_names))}) — provenance fail", file=sys.stderr)
        succ = 0.0
    return _score_trial(case, cap, succ)


def run_task(cfg, opik, s, case, trials, k, threshold, run_id, want_judge) -> TaskOutcome:
    is_checker = case.checker_spec is not None
    task_key = f"{s.name}-{case.id}"
    fixture_path = case.checker_spec.get("seed") if is_checker else None
    cleanup_root = checker.eval_root(cfg.daemon.fermix_home) if is_checker else None
    results: list[aggregate.TrialResult] = []
    trial_traces: list[tuple[str, float]] = []
    models: list[str] = []
    repr_trace_id = None

    for i in range(trials):
        try:
            if case.cross_session:
                tr, trace_id, tmodels = _cross_session_trial(cfg, opik, s, case, run_id, i)
            else:
                tr, trace_id, tmodels = _standard_trial(
                    cfg, opik, s, case, run_id, i, is_checker, task_key, fixture_path,
                    cleanup_root, want_judge)
        except driver.UsageLimitHit as hit:
            hit.locate(s.name, case.id, i)   # stamp the resume pointer, then abort the sweep
            raise
        except JudgeUnavailable as unavailable:
            unavailable.locate(s.name, case.id, i)
            raise
        results.append(tr)
        models += tmodels
        if trace_id:
            trial_traces.append((trace_id, tr.effective_success))
            repr_trace_id = repr_trace_id or trace_id

    if is_checker:                       # drop the now-empty eval/<task> parent
        checker.teardown_task(cleanup_root, task_key)

    stats = aggregate.aggregate_task(results, k=k, threshold=threshold)
    method = (f"checker:{os.path.basename(case.checker_spec['script'])}" if is_checker
              else "cross_session" if case.cross_session
              else case.score_spec.get("match") if case.score_spec else "judge")
    item = {"input": case.turns[-1].query, "expected": _expected(case), "suite": s.name, "method": method}
    return TaskOutcome(stats=stats, repr_trace_id=repr_trace_id, item_data=item,
                       trial_traces=trial_traces, models=models)


def _expected(case) -> str:
    if case.score_spec:
        return str(case.score_spec.get("expected"))
    if case.checker_spec:
        return f"checker: {case.checker_spec.get('script')}"
    return (case.rubric or "")[:200]


# --- per-task results (the uplift pairing surface) --------------------------

def write_results_json(path, arm, config_id, k, threshold, outcomes) -> None:
    """Write per-task success for the Fermix arm via the shared uplift format —
    the unit run_uplift.py pairs against a baseline arm's results.json."""
    tasks = {f"{s}/{cid}": {"mean_success": round(o.stats.mean_success, 4),
                            "pass_hat_k": round(o.stats.pass_hat_k, 4),
                            "n": o.stats.n_trials}
             for s, cid, o in outcomes}
    uplift.write_arm(path, arm=arm, config_id=config_id,
                     suite=",".join(sorted({s for s, _c, _o in outcomes})),
                     k=k, threshold=threshold, tasks=tasks)


# --- Opik writeback ---------------------------------------------------------

def write_opik(cfg, config_id, run_id, outcomes) -> str | None:
    writer = ExperimentWriter(cfg.opik.base_url)
    try:
        writer.create_dataset(DATASET, "Fermix capability tasks (ground-truth scored)")
        exp_id = stable_id(f"cap:{config_id}:{run_id}")
        writer.create_experiment(exp_id, config_id, DATASET,
                                 metadata={"run_id": run_id, "config_id": config_id})
        scores: list[dict] = []
        for s_name, case_id, out in outcomes:
            item_id = stable_id(f"{s_name}:{case_id}")
            writer.upsert_dataset_item(DATASET, item_id, out.item_data)
            if out.repr_trace_id:
                writer.link_trace(exp_id, item_id, out.repr_trace_id)
                scores.append({"id": out.repr_trace_id, "name": "cap_task_success",
                               "value": round(out.stats.mean_success, 4), "source": "sdk"})
                scores.append({"id": out.repr_trace_id, "name": "cap_pass_hat_k",
                               "value": round(out.stats.pass_hat_k, 4), "source": "sdk"})
            for tid, succ in out.trial_traces:
                scores.append({"id": tid, "name": "cap_trial_success", "value": succ, "source": "sdk"})
        # The experiment + trace links already persisted; a scores-flush failure
        # must not discard the exp_id (it would orphan a real experiment).
        if scores:
            try:
                writer.put_feedback_scores(scores, cfg.opik.project)
            except OpikWriteError as exc:
                print(f"  ! {len(scores)} feedback scores dropped: {exc}", file=sys.stderr)
        return exp_id
    except OpikWriteError as exc:
        print(f"  ! Opik writeback failed (scores still local): {exc}", file=sys.stderr)
        return None


# --- main -------------------------------------------------------------------

def _detect_config_id(arg_id, all_models) -> str:
    if arg_id:
        return arg_id
    if not all_models:
        return "unknown-model"
    return Counter(all_models).most_common(1)[0][0]


def _abort_usage_limit(hit, done: int, total: int) -> int:
    """Stop the sweep cleanly on a usage limit. Reports where it stopped (the pointer
    to resume from) and writes no leaderboard row — a partial composite would overwrite the
    model's real leaderboard row, and scoring the limit-blocked turns would count
    Fermix's own limit as task failures. Re-run once the limit resets."""
    where = f"{hit.suite}/{hit.case_id} (trial {hit.trial})" if hit.suite else "a task"
    reset = f" — provider self-reports {hit.reset_hint}" if hit.reset_hint else ""
    print(f"\n⛔ usage limit hit at {where}{reset}.", file=sys.stderr)
    print(f"   Fermix reply: {hit.reply_excerpt()!r}", file=sys.stderr)
    if hit.retries:
        plural = "retry" if hit.retries == 1 else "retries"
        print(f"   Still limited after {hit.retries} {plural} across ~{hit.waited_min} min "
              f"of backoff — giving up.", file=sys.stderr)
    print(f"   {done}/{total} task(s) scored before the limit. Leaderboard NOT written — "
          f"a partial row would overwrite the model's real score.", file=sys.stderr)
    print("   Resume: wait for the limit to reset, then re-run the same command. "
          "Completed turns, traces, memory, or tool effects may remain; unique run/trial "
          "ids prevent them from being mistaken for the rerun.", file=sys.stderr)
    return 4


def _abort_judge_unavailable(unavailable, done: int, total: int) -> int:
    where = (f"{unavailable.suite}/{unavailable.case_id} (trial {unavailable.trial})"
             if unavailable.suite else unavailable.case_id)
    print(f"\n⛔ required judge result unavailable at {where}.", file=sys.stderr)
    print(f"   Judge error: {unavailable.error}", file=sys.stderr)
    print(f"   {done}/{total} task(s) scored before judging became incomplete. "
          "Leaderboard NOT written — judge infrastructure must not become a "
          "candidate score of zero.", file=sys.stderr)
    return 4


def _path_within(path: str, root: str) -> bool:
    try:
        return os.path.commonpath([path, root]) == root
    except ValueError:
        return False


def _capability_home_error(
        fermix_home: str, require_isolated: bool = False) -> str | None:
    resolved = os.path.realpath(os.path.expanduser(fermix_home))
    production = os.path.realpath(os.path.expanduser("~/.fermix"))
    dev = os.path.realpath(os.path.expanduser("~/.fermix-dev"))
    home = os.path.realpath(os.path.expanduser("~"))
    if resolved in {production, home}:
        return f"refusing production/non-daemon FERMIX_HOME: {resolved}"
    if resolved == dev:
        if require_isolated:
            return ("selected capability tasks mutate state and cannot use ~/.fermix-dev; "
                    "set FERMIX_EVAL_HOME to a disposable eval/e2e home")
        return None
    leaf = os.path.basename(resolved).lower()
    if "eval" not in leaf and "e2e" not in leaf:
        return ("safe capability runs use ~/.fermix-dev; isolated runs require a "
                "dedicated path named with 'eval' or 'e2e'")
    return None


def _capability_project_error(
        project: str, require_isolated: bool = False) -> str | None:
    if not isinstance(project, str) or not project.strip():
        return "Opik project must be a non-empty name"
    name = project.strip().lower()
    if name == "fermix-dev":
        if require_isolated:
            return ("isolated capability runs require an eval/e2e Opik project, "
                    "not fermix-dev")
        return None
    if "eval" not in name and "e2e" not in name:
        return f"refusing production or unknown Opik project: {project!r}"
    return None


def _capability_config_requires_isolation(cfg) -> bool:
    configured_home = os.path.realpath(os.path.expanduser(cfg.daemon.fermix_home))
    dev_home = os.path.realpath(os.path.expanduser("~/.fermix-dev"))
    project = cfg.opik.project.strip().lower()
    return configured_home != dev_home or project != "fermix-dev"


def _capability_sandbox_error(
        fermix_home: str, require_isolated: bool = False) -> str | None:
    home = os.path.realpath(os.path.expanduser(fermix_home))
    config_path = os.path.join(home, "config.toml")
    try:
        with open(config_path, "rb") as handle:
            raw = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        return f"cannot read capability daemon config at {config_path}: {exc}"
    sandbox = raw.get("sandbox", {})
    if not isinstance(sandbox, dict):
        return "capability daemon [sandbox] config must be a table"
    if not require_isolated:
        return None
    if sandbox.get("mode", "standard") != "strict":
        return 'capability daemon must declare [sandbox] mode = "strict"'
    workspace_raw = sandbox.get("workspace_root", os.path.join(home, "workspace"))
    if not isinstance(workspace_raw, str) or not workspace_raw.strip():
        return "capability daemon sandbox.workspace_root must be a non-empty path"
    expanded = os.path.expandvars(os.path.expanduser(workspace_raw))
    if not os.path.isabs(expanded):
        return "capability daemon sandbox.workspace_root must be absolute"
    workspace = os.path.realpath(expanded)
    if workspace == home or not _path_within(workspace, home):
        return f"capability workspace must stay below its dedicated FERMIX_HOME: {workspace}"
    expected_workspace = os.path.realpath(os.path.join(home, "workspace"))
    if workspace != expected_workspace:
        return ("capability daemon sandbox.workspace_root must be the conventional "
                f"checker root {expected_workspace}; got {workspace}")
    git_metadata = os.path.realpath(os.path.join(workspace, ".git"))
    if (not os.path.isdir(workspace) or not os.path.isdir(git_metadata)
            or not _path_within(git_metadata, workspace)):
        return ("capability workspace must contain a disposable repository snapshot "
                f"with its own .git metadata: {workspace}")
    allowed = sandbox.get("allowed_roots", [])
    if not isinstance(allowed, list) or not all(isinstance(item, str) for item in allowed):
        return "capability daemon sandbox.allowed_roots must be a list of paths"
    escaped = [
        os.path.realpath(os.path.expandvars(os.path.expanduser(item)))
        for item in allowed
        if not _path_within(
            os.path.realpath(os.path.expandvars(os.path.expanduser(item))), home)
    ]
    if escaped:
        return f"capability daemon allowed_roots escape its disposable home: {escaped}"
    return None


def _capability_requires_isolated_home(cases) -> bool:
    return any(
        scenario.risk == "isolated_mutation" or case.checker_spec is not None
        for _suite, scenario, case in cases)


def _capability_requires_cost_confirmation(cases) -> bool:
    return any(
        scenario.risk == "expensive" or scenario.confirm_cost
        for _suite, scenario, _case in cases)


def _execution_attestation_error(args, require_isolated: bool) -> str | None:
    if not require_isolated:
        return None
    if not args.confirm_daemon_isolated:
        return ("execution requires --confirm-daemon-isolated: attest that the running daemon "
                "was restarted against this disposable home/project, with strict sandboxing, "
                "no channels/realtime, and headless browser")
    return None


def preconditions(cfg, require_isolated: bool = False) -> list[str]:
    problems = [
        _capability_home_error(cfg.daemon.fermix_home, require_isolated),
        _capability_project_error(cfg.opik.project, require_isolated),
        _capability_sandbox_error(cfg.daemon.fermix_home, require_isolated),
    ]
    problems = [problem for problem in problems if problem]
    if problems:
        return problems
    try:
        OpikClient(cfg.opik.base_url, cfg.opik.project).ping()
    except OpikError as exc:
        problems.append(f"Opik not reachable at {cfg.opik.base_url}: {exc}")
    ok, detail = driver.daemon_reachable(cfg)
    if not ok:
        problems.append(
            f"capability daemon not reachable "
            f"(FERMIX_HOME={cfg.daemon.fermix_home}): {detail}")
    return problems


def build_args(argv):
    p = argparse.ArgumentParser(description="Fermix capability eval / cross-model ranking")
    p.add_argument("--suite", action="append", help="capability suite name (repeatable)")
    p.add_argument("--tag", action="append", help="only scenarios with this tag (repeatable)")
    p.add_argument("--trials", type=int, default=3, help="trials per task (default 3)")
    p.add_argument("--k", type=int, default=None, help="k for pass^k (default = trials)")
    p.add_argument("--threshold", type=float, default=1.0, help="per-trial pass threshold (default 1.0)")
    p.add_argument("--judge", action="store_true", help="enable LLM judge for rubric-only tasks")
    p.add_argument("--config-id", help="override config label (default: auto-detect served model)")
    p.add_argument("--axis", choices=("tokens", "cost"), default="tokens", help="efficiency axis")
    p.add_argument("--max-tasks", type=int, default=None,
                   help="limit task count (not a dollar/spend cap)")
    p.add_argument("--candidates", action="store_true",
                   help="also load UNVALIDATED hard-tier drafts under suites/capability/candidates/ "
                        "(pair with --suite <name> to validate one in isolation)")
    p.add_argument("--no-opik", action="store_true", help="skip Opik writeback (local scores only)")
    p.add_argument("--private", action="store_true",
                   help="run an operator-supplied held-out split (FERMIX_EVAL_HOLDOUT_DIR / --private-data)")
    p.add_argument("--private-data",
                   help="dir of held-out suites OUTSIDE the repo (or set FERMIX_EVAL_HOLDOUT_DIR)")
    p.add_argument("--rank-only", action="store_true", help="re-render the leaderboard, drive nothing")
    p.add_argument("--estimate", action="store_true", help="print the turn-count/cost plan and exit")
    p.add_argument("--check", action="store_true", help="preconditions only")
    p.add_argument(
        "--confirm-daemon-isolated",
        action="store_true",
        help=("for isolated_mutation tasks, attest the reachable daemon was restarted "
              "against the disposable eval home/project with strict sandboxing, no "
              "channels/realtime, and a headless browser"),
    )
    p.add_argument(
        "--confirm-isolated-env", action="store_true",
        help="attest isolated_mutation tasks target the disposable capability home/workspace",
    )
    p.add_argument(
        "--confirm-cost", action="store_true",
        help="acknowledge expensive capability tasks may spawn multiple billed calls",
    )
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = build_args(argv)
    cfg = cfgmod.load(SKILL_DIR)
    lb_path = leaderboard.store_path(cfg.report_dir)

    if args.rank_only:
        store = leaderboard.load_store(lb_path)
        print(leaderboard.render_md(store, axis=args.axis))
        return 0

    if args.check:
        require_isolated = _capability_config_requires_isolation(cfg)
        problems = preconditions(cfg, require_isolated=require_isolated)
        judge_problem = _independent_judge_error(
            cfg, args.judge or cfg.judge.enabled)
        if judge_problem:
            problems.append(f"judge: {judge_problem}")
        if problems:
            print("preconditions:\n  - " + "\n  - ".join(problems))
        else:
            environment = "isolated" if require_isolated else "development"
            print(f"preconditions: {environment} daemon config and reachability OK")
        return 3 if problems else 0

    if not 0 < args.threshold <= 1:
        print(f"--threshold must be in (0, 1], got {args.threshold}", file=sys.stderr)
        return 2

    trials = max(1, args.trials)
    k = args.k or trials
    want_judge = args.judge or cfg.judge.enabled

    # --private runs ONLY an operator-supplied held-out split (never merged into the
    # public set) and scores it under a distinct ':private' config row. It skips
    # dataset/experiment/feedback writeback, but candidate turns still need the
    # daemon's Opik traces for scoring. The suites must live OUTSIDE the repo —
    # shipping gold answers in the skill would defeat the contamination check.
    try:
        if args.private:
            holdout_dir = os.environ.get("FERMIX_EVAL_HOLDOUT_DIR") or args.private_data
            if not holdout_dir:
                print("--private needs a held-out dir OUTSIDE the repo so its answers aren't "
                      "readable by anyone iterating the eval: set FERMIX_EVAL_HOLDOUT_DIR or pass "
                      "--private-data <dir>. See suites/capability/private/holdout.example.yaml for "
                      "the format — copy it out of the repo and fill in your own tasks.",
                      file=sys.stderr)
                return 2
            if not os.path.isdir(holdout_dir):
                print(f"--private: held-out dir not found: {holdout_dir}", file=sys.stderr)
                return 2
            suites = load_all(holdout_dir)
        else:
            suites = load_all(CAP_DIR, include_candidates=args.candidates)
    except SuiteError as exc:
        print("capability suites invalid:\n  - " + "\n  - ".join(exc.problems), file=sys.stderr)
        return 2

    cases, skipped = capability_cases(suites, args.suite, args.tag, args.max_tasks, want_judge)
    if skipped:
        print(f"note: skipped {skipped} rubric-only task(s) — run with --judge to score them")
    if not cases:
        print("no capability tasks selected (need a `score:` block, or --judge for rubric tasks)",
              file=sys.stderr)
        return 2

    if args.estimate:
        turns = len(cases) * trials
        print(f"plan: {len(cases)} task(s) × {trials} trial(s) = {turns} real turns "
              f"(≈ ${turns * 0.05:.1f}–${turns * 0.6:.0f}, ≈ {turns * 5 // 60 + 1}–{turns * 45 // 60 + 1} min "
              f"at dev-daemon rates). Drop --estimate to run.")
        return 0

    risk_error = _capability_risk_error(cases, args)
    if risk_error:
        print(f"capability risk policy refused selection: {risk_error}", file=sys.stderr)
        return 2
    judge_error = _independent_judge_error(cfg, want_judge)
    if judge_error:
        print(f"judge precondition failed: {judge_error}", file=sys.stderr)
        return 2

    require_isolated = _capability_requires_isolated_home(cases)
    problems = preconditions(cfg, require_isolated=require_isolated)
    if problems:
        print("preconditions:\n  - " + "\n  - ".join(problems), file=sys.stderr)
        return 3

    attestation_error = _execution_attestation_error(args, require_isolated)
    if attestation_error:
        print(attestation_error, file=sys.stderr)
        return 2
    if require_isolated:
        print("  [operator-attested] disposable daemon isolation and launch flags")
    else:
        print(f"  [dev] using local development daemon at {cfg.daemon.fermix_home}")

    run_id = now_utc().strftime("%Y%m%dT%H%M%SZ")
    opik = OpikClient(cfg.opik.base_url, cfg.opik.project)

    print(f"capability eval · {len(cases)} task(s) × {trials} trial(s) · "
          f"judge={'on' if want_judge else 'off'} · axis={args.axis}")
    outcomes, all_models, task_stats = [], [], []
    try:
        for s, _scn, case in cases:
            out = run_task(cfg, opik, s, case, trials, k, args.threshold, run_id, want_judge)
            outcomes.append((s.name, case.id, out))
            all_models += out.models
            task_stats.append(out.stats)
            st = out.stats
            print(f"  {s.name}/{case.id:24} success={st.mean_success:.2f} "
                  f"pass^{st.k}={st.pass_hat_k:.2f} tok={int(st.mean_tokens)} "
                  f"{'⚠️safety' if st.safety_violations else ''}")
    except driver.UsageLimitHit as hit:
        return _abort_usage_limit(hit, len(outcomes), len(cases))
    except JudgeUnavailable as unavailable:
        return _abort_judge_unavailable(unavailable, len(outcomes), len(cases))

    # Refuse to persist a junk row: an empty model set means every turn failed
    # (e.g. daemon went down mid-run) — recording an "unknown-model" zero would
    # overwrite a real config in the latest-wins leaderboard. Exit loud instead.
    if not all_models and not args.config_id:
        print("no served model detected (every turn failed?) — leaderboard not written.",
              file=sys.stderr)
        return 3

    config_id = _detect_config_id(args.config_id, all_models)
    # The provider/model key separates most configs, but the Opik exporter maps
    # openai_codex -> "openai" (same API family), so those two share a key. Auth
    # mode isn't in the trace — the operator must disambiguate with --config-id.
    if not args.config_id and config_id.startswith("openai/"):
        print("note: traces report both openai (api_key) and openai_codex (oauth) as "
              "'openai' — to rank both, pass --config-id (e.g. --config-id openai_codex/<model>).",
              file=sys.stderr)
    if args.private:
        config_id = f"{config_id}:private"      # distinct row; never overwrites the public one
    config_score = aggregate.aggregate_config(config_id, task_stats)

    # Persist the local leaderboard FIRST so the computed scores survive any Opik
    # writeback hiccup; then fold the experiment id back in on success.
    meta = {"run_id": run_id, "trials": trials, "k": k, "tasks": len(cases),
            "threshold": args.threshold, "tasks_hash": tasks_hash(cases),
            "private": args.private, "selection": _selection_label(args),
            "opik_ui": cfg.opik.ui_base}
    store = leaderboard.upsert(leaderboard.load_store(lb_path), config_score, meta)
    leaderboard.save_store(lb_path, store)

    # Never upsert held-out gold answers into an Opik dataset or experiment.
    # Candidate prompts/replies are already present in daemon-emitted traces.
    exp_id = None if (args.no_opik or args.private) else write_opik(cfg, config_id, run_id, outcomes)
    if exp_id:
        store = leaderboard.upsert(store, config_score, {**meta, "experiment_id": exp_id})
        leaderboard.save_store(lb_path, store)

    md = leaderboard.render_md(store, axis=args.axis)
    out_dir = os.path.join(cfg.report_dir, "capability", run_id)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "leaderboard.md"), "w", encoding="utf-8") as fh:
        fh.write(md)
    # Per-task results = the Fermix arm of an uplift pairing (run_uplift.py reads
    # this against a baseline arm's results.json from run_baseline.py).
    write_results_json(os.path.join(out_dir, "results.json"), "fermix", config_id,
                       k, args.threshold, outcomes)

    print(f"\nscored config: {config_id}  (composite over {config_score.n_tasks} tasks)")
    print(md)
    print(f"leaderboard: {lb_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
