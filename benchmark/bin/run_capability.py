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

Three questions are kept apart, because collapsing them is how a benchmark starts
lying (PERSONAL_ASSISTANT_AND_CHIEF_OF_STAFF_BENCHMARK_REVIEW.md §7): was the
measurement VALID (did we observe every episode, on one route), what was the TASK
OUTCOME, and does that outcome clear the RELEASE bar (evallib/release_gate.py). A
completed run is not a passing gate, and a missing trace is not a scored zero.

Exit codes:
  0  measurement valid, leaderboard written, release gate green
  2  usage / selection / argument refusal (nothing was driven)
  3  preconditions (Opik or daemon down, or no route served the sweep)
  4  measurement INVALID — missing trace evidence, a checker/evaluator failure,
     more than one main route, a usage limit, invalidated auth, an unavailable
     judge, or a provider usage map the rate card refuses. NO leaderboard row,
     ever. The first three are found at report time and keep
     `results.invalid.json` plus a banner-marked report for diagnosis; the four
     abort kinds stop the sweep where it stood and print the reason to stderr,
     because there is no completed set of outcomes to write.
  5  measurement valid and recorded (leaderboard written), release gate RED

A cost the rate card could not produce never moves any of those codes. The score is
task performance and cost is reported beside it, so a route with no rate is named
loudly on stderr and in the report and the row is written with an unknown cost — exit 4
would throw away a valid measurement over a missing price and make the dollar column a
correctness signal. The one cost failure that IS fatal is the last kind listed above: a
usage map the pricing contract says cannot exist means the exporter is broken, and
every figure built on it is silently understated.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
import tomllib
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from evallib import (aggregate, checker, config as cfgmod, driver, grade, judge, leaderboard,
                     pricing, release_gate, safe_rm, scoring, uplift)
from evallib.experiments import ExperimentWriter, OpikWriteError, stable_id
from evallib.opik import OpikClient, OpikError
from evallib.session_ids import sess
from evallib.suites import UNCLASSIFIED_RISK, SuiteError, load_all

# Negative "must-not" gates: a failure here is a SAFETY violation that zeroes the
# task regardless of answer correctness, and a case declaring none of them reports
# "not evaluated" rather than a clean bill (§4 P0). `tools_none_succeeded` is the
# behavioral suites' typed-denial form: a tool that was blocked before execution
# passes, a tool that merely errored does not.
SAFETY_GATES = ("tools_none", "tools_none_succeeded", "reply_not_matches")
# Version of the task-set hash. v2 covers the WHOLE episode definition (every turn's
# query and expectations, provenance, scorer, checker + its reset list and fixture
# tree, rubric + judge, limits); v1 covered only the last query and a little more,
# so two materially different task sets could share a digest. Defined by the
# leaderboard — the board decides what is comparable, and one constant must drive both
# the stamping and that decision.
HASH_VERSION = leaderboard.CURRENT_HASH_VERSION
CAP_DIR = os.path.join(SKILL_DIR, "suites", "capability")
DATASET = "fermix-capability"


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _checker_fingerprint(case) -> str:
    """Grading identity of a checker task: its spec PLUS a content hash of the checker
    script, so editing a checker's grading LOGIC (not just its path) changes the task
    hash — a re-graded run can't then silently compare as the same task set."""
    if not case.checker_spec:
        return ""
    script = case.checker_spec.get("script") or ""
    digest = "no-script"
    if script:
        # RAISES on an unreadable script, like `_fixture_digest` does on an unreadable
        # seed. Folding the failure into the literal "no-script" made two different
        # checkers hash identically, so a re-graded run compared as the same task set —
        # exactly what hashing the script content exists to prevent.
        with open(checker.resolve_script(SKILL_DIR, script), "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()[:12]
    return f"{script}:{case.checker_spec.get('mode')}:{case.checker_spec.get('seed')}:{digest}"


def _fixture_digest(case) -> str:
    """Content hash of a checker task's SEED FIXTURE TREE (sorted relative paths plus
    each file's sha256). Editing a seeded csv changes the question the model is being
    asked, whatever the prompt still says — so it must change the task identity, or a
    re-seeded run compares as the same task set."""
    if not case.checker_spec:
        return ""
    seed = case.checker_spec.get("seed")
    if not seed:
        return "no-seed"
    root = checker.resolve_fixture(SKILL_DIR, seed)   # raises: an unreadable seed is loud
    h = hashlib.sha256()
    for path in sorted(_fixture_files(root)):
        h.update(os.path.relpath(path, root).encode("utf-8"))
        with open(path, "rb") as fh:
            h.update(hashlib.sha256(fh.read()).hexdigest().encode("ascii"))
    return h.hexdigest()[:16]


def _fixture_files(root: str) -> list[str]:
    return [os.path.join(current, name)
            for current, _dirs, files in os.walk(root) for name in files]


def _case_identity(suite_name: str, case, cfg) -> str:
    """The full grading identity of ONE selected task, as canonical JSON."""
    payload = {
        "task": f"{suite_name}/{case.id}",
        "turns": [{"query": turn.query, "expect": turn.expect} for turn in case.turns],
        "expect": case.expect,
        "requires_tools": sorted(case.requires_tools),
        "requires_tools_all": sorted(case.requires_tools_all),
        "cross_session": case.cross_session,
        "score": case.score_spec,
        "checker": _checker_fingerprint(case),
        "checker_reset": sorted((case.checker_spec or {}).get("reset", [])),
        "fixture": _fixture_digest(case),
        "rubric": case.rubric,
        # A rubric task's oracle IS the judge, so its identity moves with the judge's
        # backend and model. A deterministic task is unaffected by either.
        "judge": f"{cfg.judge.backend}/{cfg.judge.model}" if case.rubric else "",
        "timeout_ms": case.timeout_ms,
    }
    return json.dumps(payload, sort_keys=True, default=str)


def tasks_hash(cases, cfg) -> str:
    """Content hash of the SELECTED tasks — the reproducibility pin (v2, see
    HASH_VERSION). Any change to what is asked, what is required, or how it is graded
    yields a DISTINCT hash, so a `--max-tasks`/`--suite` subset or a re-graded run can
    never masquerade as a prior full run; a prose-only YAML edit leaves it unchanged.
    Hashes the selected cases, not the suite files."""
    h = hashlib.sha256()
    for row in sorted(_case_identity(s.name, c, cfg) for s, _scn, c in cases):
        h.update(row.encode("utf-8"))
    return h.hexdigest()[:16]


def _repo_revision() -> dict:
    """The commit under test plus a digest of any uncommitted diff. A benchmark number
    that cannot be traced to a tree is not reproducible, and "dev at some point on
    Tuesday" is not a tree."""
    sha = _git("rev-parse", "HEAD")
    diff = _git("diff", "HEAD")
    return {"sha": sha,
            "dirty_digest": "clean" if not diff else hashlib.sha256(
                diff.encode("utf-8", "replace")).hexdigest()[:16]}


def _git(*args: str) -> str:
    proc = subprocess.run(["git", "-C", SKILL_DIR, *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed ({proc.returncode}): {proc.stderr.strip()[:200]} "
            "— the run's manifest identity cannot be recorded")
    return proc.stdout.strip()


def _selection_label(args) -> str:
    """Human-readable record of the active selection filter (complements tasks_hash)."""
    parts = []
    if args.suite:
        parts.append("suite=" + ",".join(args.suite))
    if args.tag:
        parts.append("tag=" + ",".join(args.tag))
    if args.max_tasks:
        parts.append(f"max={args.max_tasks}")
    if args.candidates:
        # Unvalidated hard-tier drafts were in the pool: a different task set, and the
        # label must say so even when the digest is the only other clue.
        parts.append("candidates")
    return ";".join(parts) or "all"


@dataclass
class TaskOutcome:
    stats: aggregate.TaskStats
    repr_trace_id: str | None        # first trial's trace, linked into the experiment
    item_data: dict                  # dataset-item payload (query/expected/tag)
    trial_traces: list[tuple[str, float]]  # (trace_id, effective_success) per trial
    models: list[str]                # main-agent models seen (config detection)
    trials: list[aggregate.TrialResult] = field(default_factory=list)
    #   kept per-trial (not just folded into `stats`) so the run-validity check can
    #   name the exact trials whose evidence was missing.


class PricingContractError(RuntimeError):
    """A provider adapter emitted a usage map the rate card says cannot exist.

    Not a model failure and not a "cost problem": it means the exporter is wrong (half a
    usage map, cache counts exceeding the blended input, a cache-write against a model
    the card gives no write rate), and every dollar figure computed after it would be
    silently understated. The sweep stops on the documented invalid-measurement exit
    rather than publishing a row nobody can re-check."""

    def __init__(self, error: str):
        super().__init__(error)
        self.error = error
        self.suite = None
        self.case_id = None
        self.trial = None

    def locate(self, suite: str, case_id: str, trial: int) -> None:
        self.suite = suite
        self.case_id = case_id
        self.trial = trial


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


def _undriven_case_error(cases) -> str | None:
    """Cases this runner cannot DRIVE. `_standard_trial` sends `case.turns[-1].query`
    alone and `_cross_session_trial` drives exactly two; anything else would be scored
    off its last prompt while the estimator counted every declared turn. The loader
    already refuses this shape for score/checker cases at authoring time — it cannot
    see rubric-only ones, which only exist as a selection once `--judge` admits them."""
    undriven = sorted(f"{suite.name}/{case.id}"
                      for suite, _scn, case in cases
                      if len(case.turns) > 1 and not case.cross_session)
    if not undriven:
        return None
    return ("multi-turn capability cases are not driven (only a cross_session pair is): "
            + ", ".join(undriven)
            + " — split them into single turns or declare cross_session")


def _selection_policy_error(cases) -> str | None:
    """Risk classes this runner refuses to SELECT at all — independent of the
    operator's attestations, so `--estimate` refuses them too rather than printing a
    plan for a sweep that must never run."""
    risks = {scenario.risk for _suite, scenario, _case in cases}
    if UNCLASSIFIED_RISK in risks:
        return "every capability scenario must declare an execution risk"
    unsupported = risks & {
        "private_account_read", "external_write", "desktop_input", "destructive"}
    if unsupported:
        names = ", ".join(sorted(unsupported))
        return (f"capability runner refuses high-impact risk(s) {names}; use the "
                "behavioral runner's named, confirmation-gated workflow")
    return None


def _confirmation_error(cases, args) -> str | None:
    """Operator attestations required to EXECUTE the selection. Planning a sweep
    spends nothing and mutates nothing, so these gate the run, not the estimate."""
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

def _safety_ok(trace, spans, expect, elapsed_ms: float) -> bool | None:
    """TRI-STATE. True = every declared safety gate passed · False = one failed (a
    violation; the task is zeroed) · None = the case declared NO safety gate, so
    nothing was observed. None is the honest answer: a zero-violation column over
    zero graded gates is not evidence of safety, and must never render as a pass."""
    relevant = {k: expect[k] for k in SAFETY_GATES if k in expect}
    if not relevant:
        return None
    gates = grade.grade(trace, spans, relevant, elapsed_ms=elapsed_ms)
    return all(gate.passed for gate in gates if gate.key in relevant)


def _failed_constraints(trace, spans, expect, elapsed_ms: float) -> list[str]:
    """Every NON-safety expectation on the case, graded as a HARD constraint.

    A capability case that declares `tools_all` or `max_tool_calls` is stating what
    completing the task requires; scoring the answer while ignoring that turns a
    declared requirement into decoration. A failure here zeroes the task under its own
    status (`constraint_fail`), distinct from a safety violation."""
    relevant = {k: v for k, v in expect.items() if k not in SAFETY_GATES}
    if not relevant:
        return []
    gates = grade.grade(trace, spans, relevant, elapsed_ms=elapsed_ms)
    return [f"{gate.key} ({gate.detail})"
            for gate in gates if gate.key in relevant and not gate.passed]


def _succeeded_tools(view) -> set[str]:
    """Names of tools whose span carried NO error_info. A call that failed caused
    nothing, so it is not provenance for anything the reply claims."""
    return {span.get("name") for span in view.tool_spans if not span.get("error_info")}


def _provenance_ok(requires_tools, requires_tools_all, succeeded: set) -> bool:
    """`requires_tools` is ANY-of: ≥1 of them must have SUCCEEDED, so a correct answer
    reached from parametric recall (or from a tool that errored) earns no credit.
    `requires_tools_all` is ALL-of: a task that genuinely needs two steps (create AND
    register) states both, so half the work cannot score. A task declaring neither
    always passes."""
    if requires_tools and not set(requires_tools) & succeeded:
        return False
    return set(requires_tools_all) <= succeeded


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
    detail: str = ""                     # the CLI's own word for a normalized failure


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
            # NO TRACE is no evidence, whatever the CLI called it. Keeping the CLI's
            # word as the status put "timeout"/"error" outside INVALID_STATUSES, so an
            # evidence-less capture became a scored zero about the model. The word is
            # kept as detail, where it diagnoses without deciding.
            print(f"    ! {label}: no trace found (CLI said {res.status}) — this trial "
                  "is an INVALID measurement, not a zero", file=sys.stderr)
            return _Captured("no_trace", None, None, None, elapsed_ms, detail=res.status)
        if res.status == "timeout":
            print(f"    · {label}: CLI wait elapsed; graded from the completed server-side "
                  f"trace (latency, not a failure)", file=sys.stderr)
        trace, spans = opik.await_complete(hit)
        elapsed_ms = driver.settled_elapsed_ms(res, settle_started)
        view = grade.TurnView.build(trace, spans, elapsed_ms=elapsed_ms)
        if driver.is_auth_invalidated_reply(view.reply):
            # The CLI-side check missed it (e.g. an ask timeout graded from the
            # server trace): same permanent condition, same abort — never score it.
            raise driver.AuthInvalidated(view.reply)
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


@dataclass
class _Episode:
    """Every turn driven for ONE trial, each paired with the expect map it is graded
    against. The trial's accounting sums the WHOLE episode: a two-turn memory task
    that reported only its recall turn's tokens under-counted the work by half."""
    caps: list[_Captured]
    expects: list[dict]


def _case_expect(case, index: int) -> dict:
    """The expectations graded on turn `index`: the turn's own, plus the case-level
    ones on the FINAL turn (mirrors run_eval's per-turn contract)."""
    expect = dict(case.turns[index].expect)
    if index == len(case.turns) - 1:
        expect.update(case.expect)
    return expect


def _episode_safety(ep: _Episode) -> bool | None:
    """One verdict for the episode: a violation anywhere is a violation; otherwise a
    pass only if some turn actually had a gate graded; else NOT EVALUATED."""
    verdicts = [_safety_ok(cap.trace, cap.spans, expect, cap.elapsed_ms)
                for cap, expect in zip(ep.caps, ep.expects)
                if cap.trace is not None and cap.spans is not None]
    if False in verdicts:
        return False
    return True if True in verdicts else None


def _episode_constraints(ep: _Episode) -> list[str]:
    return [problem
            for cap, expect in zip(ep.caps, ep.expects)
            if cap.trace is not None and cap.spans is not None
            for problem in _failed_constraints(
                cap.trace, cap.spans, expect, cap.elapsed_ms)]


def _episode_tools(ep: _Episode) -> set[str]:
    """Tools that SUCCEEDED anywhere in the episode. A cross-session task stores in
    turn 1 and recalls in turn 2, so provenance is a property of the episode."""
    return {name for cap in ep.caps if cap.view is not None
            for name in _succeeded_tools(cap.view)}


def _episode_models(ep: _Episode) -> list[str]:
    return [label for cap in ep.caps if cap.view is not None
            for label in _models_of(cap.view)]


def _trial_safety(ep: _Episode, checker_safety: bool | None) -> bool | None:
    """One safety verdict for the trial: the episode's declared gates AND the checker's
    own answer. A checker-declared violation is a violation; a checker that says nothing
    leaves the gate-derived tri-state exactly as it was, so silence never becomes a
    clean bill."""
    gates = _episode_safety(ep)
    if checker_safety is False or gates is False:
        return False
    if checker_safety is True or gates is True:
        return True
    return None


def _fail_trial(case, ep: _Episode, label: str = "") -> tuple[
        aggregate.TrialResult, None, list]:
    """An episode whose final turn was not gradeable: the measurement is invalid
    (INVALID_STATUSES), not a scored zero. Turns that WERE captured still contribute
    their usage and their safety verdict — an unobserved turn contributes neither,
    and is never credited as clean."""
    trial, _trace_id, models = _finish_trial(case, ep, 0.0, label)
    return (trial, None, models)


def _finish_trial(case, ep: _Episode, succ: float, label: str = "",
                  invalid_status: str | None = None,
                  checker_safety: bool | None = None) -> tuple[
        aggregate.TrialResult, str | None, list]:
    """Fold one driven episode into a trial result. `label` names the trial in the
    per-trial diagnostics ("<case> t<i>"). `invalid_status` marks the measurement
    invalid because the EVALUATOR failed — it wins over both the graded status and any
    constraint fail, because an evaluator failure is never a model failure."""
    final = ep.caps[-1]
    graded = final.status == "graded"
    # An ungradeable episode keeps its INVALID status: "we did not observe this" must
    # never be relabelled as "the model broke a rule we watched it break".
    status = final.view.status if graded else final.status
    constraints = _episode_constraints(ep) if graded else []
    if constraints:
        # A declared requirement the episode failed: a real, observed task failure,
        # under its own status so a reader never confuses it with a safety violation.
        succ, status = 0.0, "constraint_fail"
    if invalid_status:
        succ, status = 0.0, invalid_status
    usage = _episode_usage(ep)
    trace_id = final.trace.get("id") if final.trace else None
    trial = aggregate.score_trial(
        case.id, task_success=succ, safety_ok=_trial_safety(ep, checker_safety),
        cost=usage["cost"], duration_ms=usage["duration_ms"], tokens=usage["tokens"],
        tool_calls=usage["tool_calls"], status=status, trace_id=trace_id,
        cost_known=usage["cost_known"], status_detail=final.detail,
        **_episode_pricing(ep))
    if constraints:
        print(f"    · {label or case.id}: constraint fail — {'; '.join(constraints)}",
              file=sys.stderr)
    return (trial, trace_id if graded else None, _episode_models(ep))


def _episode_usage(ep: _Episode) -> dict:
    """Tokens, cost, wall time and tool calls over EVERY turn of the trial. Cost stays
    unknown (never $0.00) unless every captured turn actually reported one."""
    views = [cap.view for cap in ep.caps if cap.view is not None]
    return {
        "cost": sum(view.cost for view in views),
        "cost_known": bool(views) and all(view.cost_reported for view in views),
        "duration_ms": sum(cap.elapsed_ms for cap in ep.caps),
        "tokens": sum(view.tokens for view in views),
        "tool_calls": sum(len(view.tool_spans) for view in views),
    }


# The pseudo-route a turn gets when its trace exported NO llm span at all. Vendor-CLI
# harness delegation is the known case: it exports as a `harness:*` trace whose tokens
# sit in `trace.metadata.usage` — a shape no llm span carries — so the spans account for
# none of that turn's spend and $0.00 would be a claim about a real vendor run.
_NO_LLM_SPANS = "(no llm spans)"

# Every pricing column, unset. An episode nobody observed was never priced, which the
# aggregate layer keeps distinct from "priced, and found to owe nothing".
_PRICING_NOT_ATTEMPTED: dict = {
    "total_input_tokens": None, "total_output_tokens": None,
    "total_cached_input_tokens": None, "total_cache_write_tokens": None,
    "priced_cost_usd": None, "pricing_basis": None, "pricing_card_version": None,
    "unpriced_routes": None, "spans_without_usage": None,
}


def _episode_pricing(ep: _Episode) -> dict:
    """The rate card's verdict on the WHOLE episode, as `score_trial`'s pricing kwargs.

    The dollar figure comes from `evallib.pricing` ALONE. Opik's `total_estimated_cost`
    stays exactly where it is (`_episode_usage` -> `cost`/`cost_known`), because that is
    what the declared `max_cost_usd` gates read; blending the two would publish a
    leaderboard number nobody could attribute to a price table.
    """
    views = [cap.view for cap in ep.caps if cap.view is not None]
    if not views:
        return dict(_PRICING_NOT_ATTEMPTED)
    spans = [usage for view in views for usage in view.llm_usage]
    priced = _priced_columns(spans, _stranded_turns(ep))
    return {**_token_split(spans), **priced}


def _priced_columns(spans: list, stranded: tuple[str, ...]) -> dict:
    """The card's five columns for one episode.

    A stranded turn OVERRIDES the card's own verdict: its spend is real and absent from
    these spans, so any total here would be a partial sum — and a partial sum published
    under a total's heading is exactly the defect this column exists to end. The episode
    reports "unpriced" and names the turn instead."""
    priced = _price(spans)
    routes = sorted(set(priced.unpriced_routes) | set(stranded))
    return {
        "priced_cost_usd": None if routes else priced.cost_usd,
        "pricing_basis": "unpriced" if routes else priced.basis,
        "pricing_card_version": priced.card_version,
        "unpriced_routes": routes,
        "spans_without_usage": priced.spans_without_usage,
    }


def _price(spans: list) -> pricing.PricedUsage:
    """`pricing.price`, with its contract violations named for the sweep's abort path.

    The card raises only on usage a provider adapter cannot legitimately emit. Every
    such case silently understates every dollar figure built on it, so the run stops
    loudly instead of riding past it."""
    try:
        return pricing.price(spans)
    except (TypeError, ValueError) as exc:
        raise PricingContractError(str(exc)) from exc


def _token_split(spans: list) -> dict:
    """The episode's four token columns, summed over the spans that REPORTED one.

    Tri-state throughout: a column is None when NO span reported it, never 0 — "the
    vendor said zero" and "the vendor said nothing" are different facts. Input keeps the
    adapter's BLENDED semantics (Anthropic folds cache_creation + cache_read into it);
    the cache columns ride alongside, so a consumer subtracts for the uncached
    remainder."""
    split = {"total_input_tokens": _sum_reported(spans, "prompt_tokens"),
             "total_output_tokens": _sum_reported(spans, "completion_tokens"),
             "total_cached_input_tokens": _sum_reported(spans, "cached_input_tokens"),
             "total_cache_write_tokens": _sum_reported(spans, "cache_write_tokens")}
    if (split["total_input_tokens"] is None) != (split["total_output_tokens"] is None):
        raise PricingContractError(
            f"a turn totalled input={split['total_input_tokens']!r} against "
            f"output={split['total_output_tokens']!r} — a span carries a whole usage map "
            "or none, and half a split silently under-prices every row built on it")
    return split


def _sum_reported(spans: list, attr: str) -> int | None:
    """Sum one count over the spans that reported it; None when none did. A span that
    reported nothing is counted in `spans_without_usage`, never summed in as a zero."""
    reported = [getattr(span, attr) for span in spans if getattr(span, attr) is not None]
    return sum(reported) if reported else None


def _stranded_turns(ep: _Episode) -> tuple[str, ...]:
    """Observed turns whose trace exported no llm span, named as pseudo-routes so the
    blank cell points at the trace that has to be correlated."""
    return tuple(sorted({f"{_NO_LLM_SPANS}/{_trace_name(cap)}"
                         for cap in ep.caps
                         if cap.view is not None and not cap.view.llm_usage}))


def _trace_name(cap: _Captured) -> str:
    return (cap.trace or {}).get("name") or "(unnamed trace)"


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


def trial_token(s_name: str, case_id: str, run_id: str, i: int) -> str:
    """This trial's plantable marker. Deterministic (a resumed run reproduces it) and
    unique per run/case/trial, so an artifact holding a token memorized from an earlier
    sweep — or copied from a sibling trial — cannot pass this one."""
    digest = hashlib.sha256(f"{s_name}/{case_id}/{run_id}/t{i}".encode()).hexdigest()
    return "TOK-" + digest[:8].upper()


def _evidence(run_id: str, trial: int, session: str, token: str, ep: _Episode) -> dict:
    """The per-trial correlation record handed to the checker (checker.run_checker
    writes it outside the workspace, so the agent can neither read nor forge it).

    The artifact alone proves nothing: a hand-written job_out.txt holding the token
    scored 1.0. A checker grades the artifact AND the trace that produced it."""
    final = ep.caps[-1]
    return {
        "schema": 1,
        "run_id": run_id,
        "trial": trial,
        "session": session,
        "trace_id": final.trace.get("id") if final.trace else None,
        "token": token,
        "reply": final.view.reply if final.view else "",
        "tool_spans": [span
                       for cap in ep.caps if cap.view is not None
                       for span in _evidence_spans(cap.view)],
    }


def _evidence_spans(view) -> list[dict]:
    return [{"name": span.get("name"),
             "status": "error" if span.get("error_info") else "ok",
             "error": _as_text(span.get("error_info")),
             "input": span.get("input"),
             "output": _as_text(span.get("output")),
             "start_time": span.get("start_time"),
             "end_time": span.get("end_time")}
            for span in view.tool_spans]


def _as_text(value) -> str | None:
    if value is None or isinstance(value, str):
        return value
    return json.dumps(value, default=str)


def _reset_declared_state(fermix_home: str, paths) -> None:
    """Restore the baseline a checker task declares (`checker.reset`) BEFORE the trial.

    Trials are independent only if each starts from the same world: a skill left by the
    previous trial makes the next `skill_create` refuse "already exists" on its own
    filesystem check, so trial 2 onward measures leftovers instead of the model. The
    seeder's eval-home leaf guard is re-asserted here — this is a recursive delete
    inside a FERMIX_HOME, and it must be impossible to point at a real one."""
    home = os.path.realpath(os.path.expanduser(fermix_home))
    leaf = os.path.basename(home).lower()
    if "eval" not in leaf and "e2e" not in leaf:
        raise safe_rm.SafeRmError(
            f"refusing to reset state outside a disposable eval home: {home}")
    for entry in paths:
        target = os.path.join(home, entry)
        resolved = safe_rm.check(target, home, min_below=2)  # never a root, never the home
        if os.path.islink(target):
            # Remove the LINK, never what it points at. safe_rm.check returns the
            # realpath, so following it deleted an undeclared target and left the
            # declared entry behind as a dangling link — the opposite of a baseline
            # restore on both counts.
            os.remove(target)
        elif os.path.isdir(resolved):
            safe_rm.rm_rf(target, home, min_below=2)
        elif os.path.isfile(resolved):
            os.remove(resolved)


def _standard_trial(cfg, opik, s, case, run_id, i, is_checker, task_key, fixture_path,
                    cleanup_root, want_judge):
    session = sess("e2e-cap", run_id, s.name, case.id, f"t{i}")
    token = trial_token(s.name, case.id, run_id, i)
    query = case.turns[-1].query.replace("{token}", token)
    scoped = checker.scoped_dir(cfg.daemon.fermix_home, task_key, i) if is_checker else None
    try:
        if is_checker:
            # Restore the declared daemon-state baseline, then a fresh scoring dir under
            # the conventional capability workspace. Neither is containment; the
            # disposable daemon owns the broader sandbox.
            _reset_declared_state(cfg.daemon.fermix_home, case.checker_spec["reset"])
            checker.seed_workspace(scoped, SKILL_DIR, fixture_path, cleanup_root)
            query = query.replace("{ws}", scoped)
        label = f"{case.id} t{i}"
        cap = _capture_turn(cfg, opik, session, query, case.timeout_ms, label)
        ep = _Episode(caps=[cap], expects=[_case_expect(case, len(case.turns) - 1)])
        if cap.status != "graded" or cap.view is None:
            return _fail_trial(case, ep, label)
        if is_checker:
            return _checker_trial(cfg, case, ep, scoped, run_id, i, session, token, label)
        succ, _detail = _task_success(
            cfg, case, cap.view.reply, want_judge, session, _candidate_routes(cap.view))
        succ = _provenance_gate(case, ep, succ, label)
        return _finish_trial(case, ep, succ, label)
    finally:
        if scoped and os.path.isdir(scoped):  # always clean full or partial seeds
            checker.teardown_workspace(cleanup_root, scoped)


def _checker_trial(cfg, case, ep: _Episode, scoped, run_id, i, session, token, label):
    """Grade one checker task's end-state and fold the checker's verdict into the trial.

    A recorded checker error (script missing, boundary error, workspace or home gone,
    evidence unwritable, timeout, spawn failure, unparseable output) is an EVALUATOR
    failure: the trial is invalid, not the model scoring zero. It used to enter the
    leaderboard as a valid 0.0 and drag pass@1."""
    cr = checker.run_checker(SKILL_DIR, case.checker_spec, scoped, ep.caps[-1].view.reply,
                             cfg.daemon.fermix_home,
                             evidence=_evidence(run_id, i, session, token, ep))
    if cr.error:
        print(f"    ! checker error {label}: {cr.error} — trial INVALID (not a model "
              "failure)", file=sys.stderr)
        return _finish_trial(case, ep, 0.0, label, invalid_status="checker_error")
    if cr.violations:
        print(f"    ⚠️ {label}: checker reported violation(s): {'; '.join(cr.violations)}",
              file=sys.stderr)
    succ = _provenance_gate(case, ep, cr.score, label)
    return _finish_trial(case, ep, succ, label, checker_safety=cr.safety_ok)


def _provenance_gate(case, ep: _Episode, succ: float, label: str) -> float:
    """Zero a task whose declared mechanism did not actually run. A right answer
    reached WITHOUT the tool is parametric recall, not tool use, and earns no credit —
    this is what makes uplift against a tool-less arm real."""
    succeeded = _episode_tools(ep)
    if _provenance_ok(case.requires_tools, case.requires_tools_all, succeeded):
        return succ
    print(f"    · {label}: required tools any={list(case.requires_tools)} "
          f"all={list(case.requires_tools_all)} not satisfied "
          f"(succeeded={sorted(succeeded)}) — provenance fail", file=sys.stderr)
    return 0.0


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
    ep = _Episode(caps=[store], expects=[_case_expect(case, 0)])
    label = f"{case.id} t{i}"
    if store.status != "graded" or store.view is None:
        return _fail_trial(case, ep, label)   # infra failure on store → recall is meaningless
    cap = _capture_turn(cfg, opik, sess_b, recall_q, case.timeout_ms, f"{case.id} t{i} recall")
    ep.caps.append(cap)
    ep.expects.append(_case_expect(case, 1))
    if cap.status != "graded" or cap.view is None:
        return _fail_trial(case, ep, label)
    spec = {**case.score_spec, "expected": str(case.score_spec["expected"]).replace("{token}", token)}
    succ = scoring.score_answer(cap.view.reply, spec).score
    succ = _provenance_gate(case, ep, succ, label)
    return _finish_trial(case, ep, succ, label)


def run_task(cfg, opik, s, scn, case, trials, k, threshold, run_id,
             want_judge) -> TaskOutcome:
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
        except driver.AuthInvalidated as hit:
            hit.locate(s.name, case.id, i)
            raise
        except JudgeUnavailable as unavailable:
            unavailable.locate(s.name, case.id, i)
            raise
        except PricingContractError as broken:
            broken.locate(s.name, case.id, i)
            raise
        results.append(tr)
        models += tmodels
        if trace_id:
            trial_traces.append((trace_id, tr.effective_success))
            repr_trace_id = repr_trace_id or trace_id

    if is_checker:                       # drop the now-empty eval/<task> parent
        checker.teardown_task(cleanup_root, task_key)

    # The scenario is the independent WORLD: its cases are variants of one situation,
    # so the config CI resamples scenarios, never paraphrases as independent evidence.
    stats = aggregate.aggregate_task(results, k=k, threshold=threshold,
                                     family=f"{s.name}/{scn.id}")
    method = (f"checker:{os.path.basename(case.checker_spec['script'])}" if is_checker
              else "cross_session" if case.cross_session
              else case.score_spec.get("match") if case.score_spec else "judge")
    # Every declared prompt, with the per-trial placeholders left TEMPLATED: the
    # dataset item is the task definition, and one trial's token is not it.
    item = {"input": "\n---\n".join(turn.query for turn in case.turns),
            "expected": _expected(case), "suite": s.name, "method": method}
    return TaskOutcome(stats=stats, repr_trace_id=repr_trace_id, item_data=item,
                       trial_traces=trial_traces, models=models, trials=results)


def _expected(case) -> str:
    if case.score_spec:
        return str(case.score_spec.get("expected"))
    if case.checker_spec:
        return f"checker: {case.checker_spec.get('script')}"
    return (case.rubric or "")[:200]


# --- measurement validity (separate from task outcome, separate from release) ---

def _planned_turns(cases) -> int:
    """Turns ONE trial actually drives across the selection. A cross-session case is
    two real turns; counting cases × trials understated the declared input by every
    memory store turn (the review's §10 "120 turns" was 130)."""
    return sum(len(case.turns) for _s, _scn, case in cases)


def _validity_problems(outcomes, routes: set) -> list[str]:
    """Why this run is not a measurement OF THIS CONFIG, if it isn't.

    Two distinct defects, both fatal to comparability and neither a model failure:
    a trial whose evidence never arrived (a 0 recorded for it is evidence about the
    harness), and a sweep served by more than one route — a mid-run model or provider
    change means the row's config_id names something that did not run the whole set."""
    problems = [
        f"{s_name}/{case_id} trial {index}: no usable evidence "
        f"(status={trial.status}, trace={trial.trace_id or 'none'})"
        for s_name, case_id, out in outcomes
        for index, trial in enumerate(out.trials) if not trial.valid
    ]
    if len(routes) > 1:
        problems.append(
            "more than one main route served this sweep (" + ", ".join(sorted(routes))
            + ") — the score is not attributable to one config")
    return problems


def _no_route_error(all_models, config_id) -> str | None:
    """No main-agent llm span anywhere means no model served the sweep — an
    "unknown-model" zero would overwrite a real row. A `--config-id` is a LABEL for
    the row; it is not evidence that anything ran, so it waives nothing."""
    if all_models:
        return None
    label = f" (--config-id {config_id!r} names a row, it does not supply a route)" \
        if config_id else ""
    return ("no served model detected on any trace (every turn failed?) — leaderboard "
            f"not written{label}.")


def render_report(run_id, config_id, meta, score, gate, problems) -> str:
    """The run's own record: validity first, then outcome, then the release decision.
    Rendered for an invalid run too — preserved for diagnosis, never for comparison."""
    head = [f"# capability run {run_id}", "",
            f"- config: `{config_id}`",
            f"- tasks_hash: `{meta['tasks_hash']}` (hash v{meta['hash_version']})",
            f"- selection: {meta['selection']} · trials: {meta['trials']} · "
            f"k: {meta['k']} · threshold: {meta['threshold']}",
            f"- repo: `{meta['repo']['sha'][:12]}` (uncommitted diff: "
            f"{meta['repo']['dirty_digest']})",
            f"- judge: {meta['judge']}",
            f"- routes: {', '.join(meta['routes']) or 'none'}", ""]
    if problems:
        return "\n".join(head + [
            "## MEASUREMENT INVALID", "",
            "This run is evidence about the harness, not about the model. No "
            "leaderboard row was written and these numbers must not be compared with "
            "a valid run.", "",
            *(f"- {problem}" for problem in problems), ""])
    return "\n".join(head + [
        "## measurement", "",
        f"Valid: {score.n_trials} trial(s) over {score.n_tasks} task(s), every one "
        "observed, one route.", "",
        "## outcome", "",
        f"- strict pass@1: {score.mean_pass_at_1:.3f}",
        f"- pass^{meta['k']}: {score.mean_pass_hat_k:.3f}",
        f"- mean task success (partial credit): {score.mean_task_success:.3f}",
        f"- safety: {_safety_line(score)}",
        f"- latency: {score.p95_latency_ms:.0f} ms ({score.latency_stat})", "",
        "## cost (reported beside the score, never inside it)", "",
        *_cost_lines(score), "",
        "## release gate", "",
        ("PASS — every predeclared target met." if gate.passed
         else "RED — " + "; ".join(gate.reasons)), ""])


def _cost_warning(score) -> list[str]:
    """Why this run's dollar column is blank, named so an operator can act on it.

    Printed even though it never changes the exit code: a blank `$/success` cell with no
    stated reason is the defect this whole column exists to end, and the fix for a
    silently unpriced row is LOUDNESS, not refusing the run."""
    if score.pricing_basis is None:
        return ["⚠️ cost was never priced for this run (a trial observed no turn) — "
                "the $/success cell stays blank."]
    if score.pricing_basis != "unpriced":
        return []
    return [f"⚠️ cost NOT priced against rate card {score.pricing_card_version} — "
            "$/success reads 'unpriced'; task scores are unaffected:"] + [
        f"   - {name}: {_unpriced_reason(name)}"
        for name in (score.unpriced_routes or [])]


def _unpriced_reason(route_name: str) -> str:
    """What an operator must actually DO about one unpriced route name."""
    if route_name.startswith(_NO_LLM_SPANS + "/"):
        return ("the turn exported no llm span; vendor-CLI harness delegation strands its "
                "tokens in trace.metadata.usage, which no span carries — correlate that "
                "trace before any figure includes it")
    pending = pricing.UNPRICED_PENDING_RATE.get(route_name)
    if pending:
        return f"a recorded rate gap — {pending}"
    return "no entry in the rate card — add one to bin/evallib/pricing.py"


def _cost_lines(score) -> list[str]:
    """The rate card's verdict, in the run's own record.

    Never Opik's `total_estimated_cost` — that number stays on the declared
    `max_cost_usd` gates. This figure is a list-price COUNTERFACTUAL (every stored row
    so far ran on a subscription/OAuth route), and while the basis is "ceiling" it is
    also an upper bound, because cached input still bills at the full input rate."""
    if score.pricing_basis is None:
        return ["- not priced: no trial carried a rate-card result"]
    lines = [f"- rate card: `{score.pricing_card_version}` · basis: **{score.pricing_basis}**",
             f"- tokens: {_tok(score.total_input_tokens)} in (blended — "
             f"{_tok(score.total_cached_input_tokens)} cached, "
             f"{_tok(score.total_cache_write_tokens)} cache-write) / "
             f"{_tok(score.total_output_tokens)} out"]
    if score.spans_without_usage:
        lines.append(f"- {score.spans_without_usage} llm span(s) reported no usage "
                     "(errored calls: real spend, unrecoverable)")
    return lines + _cost_verdict(score)


def _cost_verdict(score) -> list[str]:
    """The one line (or list) that says what the dollar figure is, or why there is none."""
    if score.pricing_basis == "not_token_billed":
        return ["- no dollar figure: every route billed no per-token rate (served locally)"]
    if score.pricing_basis == "unpriced":
        return ["- no dollar figure — routes with no rate:"] + [
            f"  - `{name}` — {_unpriced_reason(name)}"
            for name in (score.unpriced_routes or [])]
    # `ceiling` means at least one leg was priced without a reported count, and the error
    # runs BOTH ways: an unreported cache READ bills at the full input rate (overstates),
    # while an unreported cache WRITE on a vendor charging a premium bills at 1.0x instead
    # of 1.25x (understates). Do not claim a direction the basis does not establish.
    bound = (" — a list-price ESTIMATE, not a bound: legs with no reported count are "
             "priced at the input rate, which overstates cached reads and understates "
             "premium cache writes" if score.pricing_basis == "ceiling" else "")
    return [f"- list-price cost: ${score.priced_cost_usd:.4f} · "
            f"$/success: {_per_success(score)}{bound}"]


def _tok(value: int | None) -> str:
    return "?" if value is None else f"{value:,}"


def _per_success(score) -> str:
    ratio = score.priced_cost_per_success
    if ratio is None:
        return "n/a"
    return "∞ (nothing succeeded)" if ratio == float("inf") else f"${ratio:.4f}"


def _safety_line(score) -> str:
    if not score.safety_trials_evaluated:
        return "not evaluated (0 trials carried a graded safety gate)"
    return (f"{score.safety_violations} violation(s) over "
            f"{score.safety_trials_evaluated} evaluated trial(s)")


# --- per-task results (the uplift pairing surface) --------------------------

def write_results_json(path, arm, config_id, k, threshold, outcomes, valid: bool) -> None:
    """Write per-task success for the Fermix arm via the shared uplift format —
    the unit run_uplift.py pairs against a baseline arm's results.json.

    `valid` travels with the numbers so an arm cannot be paired without the pairing
    seeing what the run itself concluded."""
    tasks = {f"{s}/{cid}": {"mean_success": round(o.stats.mean_success, 4),
                            "pass_hat_k": round(o.stats.pass_hat_k, 4),
                            "n": o.stats.n_trials}
             for s, cid, o in outcomes}
    uplift.write_arm(path, arm=arm, config_id=config_id,
                     suite=",".join(sorted({s for s, _c, _o in outcomes})),
                     k=k, threshold=threshold, tasks=tasks, valid=valid)


# --- Opik writeback ---------------------------------------------------------

def write_opik(cfg, config_id, run_id, outcomes) -> str | None:
    writer = ExperimentWriter(cfg.opik.base_url,
                              api_key=cfg.opik.api_key, workspace=cfg.opik.workspace)
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


def _soft_axis_suffix(cases) -> str | None:
    """A config_id suffix for a SOFT-ONLY selection (every selected case comes from a
    `soft: true` taste suite — only reachable via explicit `--suite`, since the default
    sweep excludes soft suites). A judge/taste run and the correctness composite both
    auto-detect the SAME served-model config_id, and the leaderboard store is keyed on
    config_id alone, so without this the axis that runs second silently overwrites the
    other's row. The suffix is the sorted, `+`-joined soft suite name(s), so a soft run
    lands on its OWN row. A deterministic or mixed selection returns None (unchanged)."""
    if not cases or not all(suite.soft for suite, _scn, _case in cases):
        return None
    return "+".join(sorted({suite.name for suite, _scn, _case in cases}))


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


def _abort_auth_invalidated(hit, done: int, total: int) -> int:
    """Stop the sweep on permanently invalidated provider auth. Unlike a usage
    limit there is nothing to wait out — Fermix sends this reply only after a
    token refresh permanently failed — so every remaining trial would refuse
    before any model call and bank a meaningless 0 (the 2026-08-06 sweep scored
    70 such trials into a bogus 0.38 leaderboard row). No row is written."""
    where = f"{hit.suite}/{hit.case_id} (trial {hit.trial})" if hit.suite else "a task"
    print(f"\n⛔ provider auth invalidated at {where}.", file=sys.stderr)
    print(f"   Fermix reply: {hit.reply_excerpt()!r}", file=sys.stderr)
    print(f"   {done}/{total} task(s) scored before auth died. Leaderboard NOT written — "
          f"a partial row would overwrite the model's real score.", file=sys.stderr)
    print("   Recover: re-authenticate (`fermix auth login`), then restart the daemon. "
          "For the disposable capability home, re-run `capability-daemon.sh up` — the "
          "seed copies a fresh token from the dev store.", file=sys.stderr)
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


def _abort_pricing_contract(broken, done: int, total: int) -> int:
    """Stop the sweep on a rate-card contract violation. The task outcomes gathered so
    far may be fine, but the exporter that produced this usage map is not — a row whose
    dollar column rests on it cannot be re-checked — so nothing is published."""
    where = (f"{broken.suite}/{broken.case_id} (trial {broken.trial})"
             if broken.suite else "a task")
    print(f"\n⛔ a provider usage map violates the pricing contract at {where}.",
          file=sys.stderr)
    print(f"   Rate card: {broken.error}", file=sys.stderr)
    print(f"   {done}/{total} task(s) scored before it. Leaderboard NOT written — fix the "
          "adapter's token map before any dollar figure from it is trustworthy.",
          file=sys.stderr)
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
        OpikClient(cfg.opik.base_url, cfg.opik.project,
                          api_key=cfg.opik.api_key, workspace=cfg.opik.workspace).ping()
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


def _argument_error(args) -> str | None:
    """Argument combinations that cannot produce a publishable number. Checked before
    anything is loaded or driven — a `--k 5 --trials 3` run must not discover at
    aggregation time that its reliability column is unmeasurable."""
    if args.trials < 1:
        return f"--trials must be at least 1, got {args.trials}"
    if not 0 < args.threshold <= 1:
        return f"--threshold must be in (0, 1], got {args.threshold}"
    if args.k is not None and not 1 <= args.k <= args.trials:
        return (f"--k {args.k} needs 1 <= k <= --trials ({args.trials}): pass^k over "
                "more trials than were run is not measurable, and a clamped pass^3 "
                "must never be published in a pass^5 column")
    return None


def main(argv=None) -> int:
    args = build_args(argv)
    argument_problem = _argument_error(args)
    if argument_problem:
        print(argument_problem, file=sys.stderr)
        return 2
    cfg = cfgmod.load(SKILL_DIR)
    lb_path = leaderboard.store_path(cfg.report_dir)

    if args.rank_only:
        print(leaderboard.render_md(leaderboard.load_store(lb_path), axis=args.axis))
        return 0
    if args.check:
        return _check(cfg, args)

    want_judge = args.judge or cfg.judge.enabled
    loaded, problem = _load_selection(args)
    if problem:
        print(problem, file=sys.stderr)
        return 2
    cases, skipped = capability_cases(loaded, args.suite, args.tag, args.max_tasks, want_judge)
    if skipped:
        print(f"note: skipped {skipped} rubric-only task(s) — run with --judge to score them")
    if not cases:
        print("no capability tasks selected (need a `score:` block, or --judge for rubric tasks)",
              file=sys.stderr)
        return 2

    refusal = _planning_gate(cfg, cases, want_judge)
    if refusal is not None:
        return refusal
    if args.estimate:
        return _print_plan(cases, args.trials)
    refusal = _execution_gate(cfg, args, cases)
    if refusal is not None:
        return refusal
    return _sweep(cfg, args, lb_path, cases, want_judge)


def _check(cfg, args) -> int:
    require_isolated = _capability_config_requires_isolation(cfg)
    problems = preconditions(cfg, require_isolated=require_isolated)
    judge_problem = _independent_judge_error(cfg, args.judge or cfg.judge.enabled)
    if judge_problem:
        problems.append(f"judge: {judge_problem}")
    if problems:
        print("preconditions:\n  - " + "\n  - ".join(problems))
        return 3
    environment = "isolated" if require_isolated else "development"
    print(f"preconditions: {environment} daemon config and reachability OK")
    return 0


def _planning_gate(cfg, cases, want_judge) -> int | None:
    """Refusals that apply even to `--estimate`: a selection this runner must never
    execute, and a judge it could not use. Printing a plan for either invites a run
    that cannot happen."""
    policy_error = _selection_policy_error(cases)
    if policy_error:
        print(f"capability risk policy refused selection: {policy_error}", file=sys.stderr)
        return 2
    undriven = _undriven_case_error(cases)
    if undriven:
        print(f"capability runner refused selection: {undriven}", file=sys.stderr)
        return 2
    judge_error = _independent_judge_error(cfg, want_judge)
    if judge_error:
        print(f"judge precondition failed: {judge_error}", file=sys.stderr)
        return 2
    return None


def _execution_gate(cfg, args, cases) -> int | None:
    """Refusals about the ENVIRONMENT and the operator's attestations. Planning
    spends nothing and mutates nothing, so these gate the run, not the estimate."""
    confirmation_error = _confirmation_error(cases, args)
    if confirmation_error:
        print(f"capability risk policy refused selection: {confirmation_error}",
              file=sys.stderr)
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
    return None


def _load_selection(args) -> tuple[list, str | None]:
    """Load the suites this run scores. Returns (suites, problem)."""
    root, problem = _selection_root(args)
    if problem:
        return [], problem
    try:
        return load_all(root, include_candidates=args.candidates), None
    except SuiteError as exc:
        return [], "capability suites invalid:\n  - " + "\n  - ".join(exc.problems)


def _selection_root(args) -> tuple[str, str | None]:
    """The public capability set, or ONLY an operator-supplied held-out split.

    --private never merges into the public set and scores under a distinct ':private'
    row. Its suites must live OUTSIDE the repo — shipping gold answers in the skill
    would defeat the contamination check."""
    if not args.private:
        return CAP_DIR, None
    holdout_dir = os.environ.get("FERMIX_EVAL_HOLDOUT_DIR") or args.private_data
    if not holdout_dir:
        return "", ("--private needs a held-out dir OUTSIDE the repo so its answers aren't "
                    "readable by anyone iterating the eval: set FERMIX_EVAL_HOLDOUT_DIR or pass "
                    "--private-data <dir>. See suites/capability/private/holdout.example.yaml "
                    "for the format — copy it out of the repo and fill in your own tasks.")
    if not os.path.isdir(holdout_dir):
        return "", f"--private: held-out dir not found: {holdout_dir}"
    return holdout_dir, None


def _print_plan(cases, trials: int) -> int:
    per_trial = _planned_turns(cases)
    turns = per_trial * trials
    print(f"plan: {len(cases)} task(s) × {trials} trial(s) = {turns} real turns "
          f"({per_trial} declared turn(s) per trial, cross-session store turns included) "
          f"(≈ ${turns * 0.05:.1f}–${turns * 0.6:.0f}, "
          f"≈ {turns * 5 // 60 + 1}–{turns * 45 // 60 + 1} min at dev-daemon rates). "
          "Drop --estimate to run.")
    return 0


@dataclass
class _Run:
    """One sweep's identity and results, assembled once and passed as a unit."""
    run_id: str
    revision: dict
    tasks_hash: str
    cases: list
    trials: int
    k: int
    want_judge: bool
    outcomes: list = field(default_factory=list)
    all_models: list = field(default_factory=list)
    task_stats: list = field(default_factory=list)


def _sweep(cfg, args, lb_path, cases, want_judge) -> int:
    """Drive every selected task, then report. Driving CONTINUES after an invalid
    trial — the remaining tasks are the diagnosis — but an invalid trial anywhere
    still costs the run its leaderboard row (see _report)."""
    run = _Run(run_id=now_utc().strftime("%Y%m%dT%H%M%SZ"),
               # Both resolved BEFORE any spend: a run whose tree or task set cannot be
               # identified is not reproducible, and finding that out afterwards wastes
               # the sweep. tasks_hash reads the checker scripts and the fixture trees,
               # and raises on an unreadable one.
               revision=_repo_revision(), tasks_hash=tasks_hash(cases, cfg),
               cases=cases, trials=args.trials,
               k=args.k or args.trials, want_judge=want_judge)
    opik = OpikClient(cfg.opik.base_url, cfg.opik.project,
                      api_key=cfg.opik.api_key, workspace=cfg.opik.workspace)
    print(f"capability eval · {len(cases)} task(s) × {run.trials} trial(s) · "
          f"judge={'on' if want_judge else 'off'} · axis={args.axis}")
    try:
        for s, scn, case in cases:
            out = run_task(cfg, opik, s, scn, case, run.trials, run.k, args.threshold,
                           run.run_id, want_judge)
            run.outcomes.append((s.name, case.id, out))
            run.all_models += out.models
            run.task_stats.append(out.stats)
            print(f"  {s.name}/{case.id:24} success={out.stats.mean_success:.2f} "
                  f"pass^{out.stats.k}={out.stats.pass_hat_k:.2f} "
                  f"tok={int(out.stats.mean_tokens)}"
                  f"{' ⚠️safety' if out.stats.safety_violations else ''}"
                  f"{f' ⛔{out.stats.n_invalid} unobserved' if out.stats.n_invalid else ''}")
    except driver.UsageLimitHit as hit:
        return _abort_usage_limit(hit, len(run.outcomes), len(cases))
    except driver.AuthInvalidated as hit:
        return _abort_auth_invalidated(hit, len(run.outcomes), len(cases))
    except JudgeUnavailable as unavailable:
        return _abort_judge_unavailable(unavailable, len(run.outcomes), len(cases))
    except PricingContractError as broken:
        return _abort_pricing_contract(broken, len(run.outcomes), len(cases))
    return _report(cfg, args, lb_path, run)


def _report(cfg, args, lb_path, run: _Run) -> int:
    """Validity, then outcome, then the release decision — in that order, because a
    completed run is not a valid one and a valid one is not a passing gate."""
    route_error = _no_route_error(run.all_models, args.config_id)
    if route_error:
        print(route_error, file=sys.stderr)
        return 3
    config_id = _config_id(args, run)
    score = aggregate.aggregate_config(config_id, run.task_stats)
    for line in _cost_warning(score):
        print(line, file=sys.stderr)
    routes = sorted(set(run.all_models))
    meta = _meta(cfg, args, run, routes)
    out_dir = os.path.join(cfg.report_dir, "capability", run.run_id)
    os.makedirs(out_dir, exist_ok=True)
    problems = _validity_problems(run.outcomes, set(routes))
    if problems:
        # Per-task results are kept for DIAGNOSIS, under a name run_uplift.py cannot be
        # pointed at by habit: written as results.json they were byte-identical in shape
        # to a valid arm, so an invalid sweep paired cleanly and published an uplift
        # claim built on harness failures.
        write_results_json(os.path.join(out_dir, "results.invalid.json"), "fermix",
                           config_id, run.k, args.threshold, run.outcomes, valid=False)
        _write_report(out_dir, run.run_id, config_id, meta, None, None, problems)
        print("\n⛔ measurement INVALID — leaderboard NOT written:", file=sys.stderr)
        print("   - " + "\n   - ".join(problems), file=sys.stderr)
        print(f"   Results (results.invalid.json) and report kept for diagnosis: "
              f"{out_dir}", file=sys.stderr)
        return 4
    # Per-task results = the Fermix arm of an uplift pairing (run_uplift.py reads this
    # against a baseline arm).
    write_results_json(os.path.join(out_dir, "results.json"), "fermix", config_id,
                       run.k, args.threshold, run.outcomes, valid=True)
    gate = release_gate.evaluate(score)
    meta["release_gate"] = {"passed": gate.passed, "reasons": gate.reasons}
    md = _publish(cfg, args, lb_path, config_id, score, meta, run)
    with open(os.path.join(out_dir, "leaderboard.md"), "w", encoding="utf-8") as fh:
        fh.write(md)
    _write_report(out_dir, run.run_id, config_id, meta, score, gate, [])
    print(f"\nscored config: {config_id}  (composite over {score.n_tasks} tasks)")
    print(md)
    print(f"leaderboard: {lb_path}")
    if gate.passed:
        print("release gate: PASS")
        return 0
    print("release gate: RED — " + "; ".join(gate.reasons), file=sys.stderr)
    print("   Exit 5 means the measurement is VALID and recorded; the gate is a separate "
          "release decision. Read the reason above before treating it as a candidate "
          "regression.", file=sys.stderr)
    return 5


def _config_id(args, run: _Run) -> str:
    config_id = _detect_config_id(args.config_id, run.all_models)
    # The provider/model key separates most configs, but the Opik exporter maps
    # openai_codex -> "openai" (same API family), so those two share a key. Auth
    # mode isn't in the trace — the operator must disambiguate with --config-id.
    if not args.config_id and config_id.startswith("openai/"):
        print("note: traces report both openai (api_key) and openai_codex (oauth) as "
              "'openai' — to rank both, pass --config-id (e.g. --config-id openai_codex/<model>).",
              file=sys.stderr)
    soft_suffix = _soft_axis_suffix(run.cases)
    if soft_suffix:
        config_id = f"{config_id}:{soft_suffix}"  # soft/taste axis: own row, never the composite's
    if args.private:
        config_id = f"{config_id}:private"      # distinct row; never overwrites the public one
    return config_id


def _meta(cfg, args, run: _Run, routes: list) -> dict:
    """The row's measurement identity: what was asked, how it was graded, which tree
    and which route answered. A number without this cannot be reproduced or compared."""
    return {"run_id": run.run_id, "trials": run.trials, "k": run.k,
            "tasks": len(run.cases), "threshold": args.threshold,
            "tasks_hash": run.tasks_hash, "hash_version": HASH_VERSION,
            "private": args.private, "selection": _selection_label(args),
            "opik_ui": cfg.opik.ui_base, "repo": run.revision, "routes": routes,
            "judge": (f"on:{cfg.judge.backend}/{cfg.judge.model}"
                      if run.want_judge else "off")}


def _publish(cfg, args, lb_path, config_id, score, meta, run: _Run) -> str:
    """Persist the local leaderboard FIRST so the computed scores survive any Opik
    writeback hiccup; then fold the experiment id back in on success."""
    store = leaderboard.upsert(leaderboard.load_store(lb_path), score, meta)
    leaderboard.save_store(lb_path, store)
    # Never upsert held-out gold answers into an Opik dataset or experiment.
    # Candidate prompts/replies are already present in daemon-emitted traces.
    exp_id = None if (args.no_opik or args.private) else write_opik(
        cfg, config_id, run.run_id, run.outcomes)
    if exp_id:
        store = leaderboard.upsert(store, score, {**meta, "experiment_id": exp_id})
        leaderboard.save_store(lb_path, store)
    return leaderboard.render_md(store, axis=args.axis)


def _write_report(out_dir, run_id, config_id, meta, score, gate, problems) -> None:
    with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8") as fh:
        fh.write(render_report(run_id, config_id, meta, score, gate, problems))


if __name__ == "__main__":
    sys.exit(main())
