#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7"]
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

Exit: 0 ok · 2 usage/selection · 3 preconditions (Opik or daemon down).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from evallib import (aggregate, checker, config as cfgmod, driver, grade, judge, leaderboard,
                     safe_rm, scoring, uplift)
from evallib.experiments import ExperimentWriter, OpikWriteError, stable_id
from evallib.opik import OpikClient, OpikError
from evallib.suites import SuiteError, load_all

# Negative "must-not" gates: a failure here is a safety violation that zeroes the
# task regardless of answer correctness (§4 hard gate).
SAFETY_GATES = ("tools_none", "reply_not_matches")
CAP_DIR = os.path.join(SKILL_DIR, "suites", "capability")
DATASET = "fermix-capability"


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def sess(*parts: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]+", "-", "-".join(parts))[:90]


def tasks_hash(cases) -> str:
    """Content hash of the SELECTED tasks (id + query + score spec) — the
    reproducibility pin. Hashing the actual selected cases (not the suite files)
    means a `--max-tasks`/`--tag`/`--suite` subset gets a DISTINCT hash (so a
    partial smoke run can't masquerade as a full run for the same model), while a
    prose/description-only edit that changes no task leaves it unchanged."""
    h = hashlib.sha256()
    rows = sorted(f"{s.name}/{c.id}|{c.turns[-1].query}|{c.score_spec}|{c.rubric}"
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


# --- selection --------------------------------------------------------------

def capability_cases(suites, want_suites, want_tags, max_tasks, want_judge):
    """Select scored cases. A rubric-only case (no `score:` block) is gradeable
    only with the judge on; with judge off it would silently score 0 and drag the
    config's headline down, so skip it (and report how many) rather than counting
    an un-evaluated task as a failure."""
    out, skipped = [], 0
    for s in suites:
        if want_suites and s.name not in want_suites:
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


# --- one trial / one task ---------------------------------------------------

def _safety_ok(trace, spans, expect) -> bool:
    relevant = {k: expect[k] for k in SAFETY_GATES if k in expect}
    if not relevant:
        return True
    return all(g.passed for g in grade.grade(trace, spans, relevant))


def _task_success(cfg, case, reply, want_judge, tag) -> tuple[float, str]:
    if case.score_spec:
        s = scoring.score_answer(reply, case.score_spec)
        return s.score, s.detail
    if case.rubric and want_judge:
        jr = judge.judge_case(cfg, case.turns[-1].query, reply, case.rubric, tag)
        if jr.evaluated and jr.score is not None:
            return jr.score, f"judge {jr.score:.2f}: {jr.rationale[:60]}"
        return 0.0, f"judge unavailable: {jr.error}"
    return 0.0, "no score_spec and judge off (skip-scored 0)"


def run_task(cfg, opik, s, case, trials, k, threshold, run_id, want_judge) -> TaskOutcome:
    base_query = case.turns[-1].query
    is_checker = case.checker_spec is not None
    task_key = f"{s.name}-{case.id}"
    fixtures_dir = (os.path.join(SKILL_DIR, case.checker_spec["seed"])
                    if is_checker and case.checker_spec.get("seed") else None)
    results: list[aggregate.TrialResult] = []
    trial_traces: list[tuple[str, float]] = []
    models: list[str] = []
    repr_trace_id = None

    for i in range(trials):
        session = sess("e2e-cap", run_id, s.name, case.id, f"t{i}")
        scoped = None
        if is_checker:
            # fresh per-trial scoped dir under the agent's sandbox; `{ws}` in the
            # query is the workspace-relative path the agent must operate in.
            scoped = checker.scoped_dir(cfg.daemon.fermix_home, task_key, i)
            checker.seed_workspace(scoped, fixtures_dir)
            # Absolute scoped path: under workspace_root (always an allowed sandbox
            # root) so it resolves in ANY sandbox mode, not just strict.
            query = base_query.replace("{ws}", scoped)
        else:
            query = base_query
        try:
            res = driver.drive_query(cfg, session, query, case.timeout_ms)
            if not res.ok:
                results.append(aggregate.score_trial(case.id, task_success=0.0, safety_ok=True,
                    cost=0.0, duration_ms=res.elapsed_ms, tokens=0, tool_calls=0, status=res.status))
                continue
            # A transient Opik read failure must NOT abort a multi-minute run — record
            # the trial as an opik_error zero and move on, like the not-ok branches.
            try:
                hit = opik.poll_for_turn(session, query, res.sent_at, set(),
                                         cfg.opik.poll_timeout_s, cfg.opik.poll_interval_s)
                if hit is None:
                    results.append(aggregate.score_trial(case.id, task_success=0.0, safety_ok=True,
                        cost=0.0, duration_ms=res.elapsed_ms, tokens=0, tool_calls=0, status="no_trace"))
                    continue
                trace, spans = opik.await_complete(hit)
                view = grade.TurnView.build(trace, spans)
                if is_checker:
                    # grade the sandbox END-STATE, not the reply text
                    cr = checker.run_checker(SKILL_DIR, case.checker_spec, scoped, view.reply)
                    if cr.error:
                        print(f"    ! checker error {case.id} t{i}: {cr.error}", file=sys.stderr)
                    succ = cr.score
                else:
                    succ, _detail = _task_success(cfg, case, view.reply, want_judge, session)
                ok = _safety_ok(trace, spans, case.expect)
            except OpikError as exc:
                print(f"    ! opik read failed for {case.id} t{i}: {exc}", file=sys.stderr)
                results.append(aggregate.score_trial(case.id, task_success=0.0, safety_ok=True,
                    cost=0.0, duration_ms=res.elapsed_ms, tokens=0, tool_calls=0, status="opik_error"))
                continue
            # Latency = the driver's end-to-end wall-clock (the trace's own duration is
            # ~0; the Opik exporter stamps start==end on the agent:main trace).
            tr = aggregate.score_trial(case.id, task_success=succ, safety_ok=ok, cost=view.cost,
                duration_ms=res.elapsed_ms, tokens=view.tokens, tool_calls=len(view.tool_spans),
                status=view.status, trace_id=trace.get("id"))
            results.append(tr)
            # Label the config by provider/model/effort so configs sharing a slug
            # (openai vs openai_codex) AND the same model at a different effort each
            # get their own leaderboard row, not a silent collision.
            models += [f"{p}/{m}/{e}"
                       for p, m, e in zip(view.main_providers, view.main_models, view.main_efforts)]
            if trace.get("id"):
                trial_traces.append((trace["id"], tr.effective_success))
                repr_trace_id = repr_trace_id or trace["id"]
        finally:
            if scoped:                       # always clean the seeded dir (guarded)
                try:
                    checker.teardown_workspace(cfg.daemon.fermix_home, scoped)
                except safe_rm.SafeRmError as exc:
                    print(f"    ! teardown refused for {case.id} t{i}: {exc}", file=sys.stderr)

    if is_checker:                       # drop the now-empty eval/<task> parent
        try:
            checker.teardown_task(cfg.daemon.fermix_home, task_key)
        except safe_rm.SafeRmError as exc:
            print(f"    ! task teardown refused for {case.id}: {exc}", file=sys.stderr)

    stats = aggregate.aggregate_task(results, k=k, threshold=threshold)
    method = (f"checker:{os.path.basename(case.checker_spec['script'])}" if is_checker
              else case.score_spec.get("match") if case.score_spec else "judge")
    item = {"input": base_query, "expected": _expected(case), "suite": s.name, "method": method}
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


def preconditions(cfg) -> list[str]:
    problems = []
    try:
        OpikClient(cfg.opik.base_url, cfg.opik.project).ping()
    except OpikError as exc:
        problems.append(f"Opik not reachable at {cfg.opik.base_url}: {exc}")
    ok, detail = driver.daemon_reachable(cfg)
    if not ok:
        problems.append(f"dev daemon not reachable (FERMIX_HOME={cfg.daemon.fermix_home}): {detail}")
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
    p.add_argument("--max-tasks", type=int, default=None, help="cap task count (bound spend)")
    p.add_argument("--no-opik", action="store_true", help="skip Opik writeback (local scores only)")
    p.add_argument("--private", action="store_true",
                   help="run an operator-supplied held-out split (FERMIX_EVAL_HOLDOUT_DIR / --private-data)")
    p.add_argument("--private-data",
                   help="dir of held-out suites OUTSIDE the repo (or set FERMIX_EVAL_HOLDOUT_DIR)")
    p.add_argument("--rank-only", action="store_true", help="re-render the leaderboard, drive nothing")
    p.add_argument("--estimate", action="store_true", help="print the turn-count/cost plan and exit")
    p.add_argument("--check", action="store_true", help="preconditions only")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = build_args(argv)
    cfg = cfgmod.load(SKILL_DIR)
    lb_path = leaderboard.store_path(cfg.report_dir)

    if args.rank_only:
        store = leaderboard.load_store(lb_path)
        print(leaderboard.render_md(store, axis=args.axis))
        return 0

    problems = preconditions(cfg)
    if args.check or problems:
        print("preconditions:" + ("\n  - " + "\n  - ".join(problems) if problems else " all OK ✓"))
        return 3 if problems else 0

    if not 0 < args.threshold <= 1:
        print(f"--threshold must be in (0, 1], got {args.threshold}", file=sys.stderr)
        return 2

    trials = max(1, args.trials)
    k = args.k or trials
    want_judge = args.judge or cfg.judge.enabled
    if want_judge and cfg.judge.backend == "fermix":
        print("warning: judge backend is 'fermix' — the judge IS the model under test "
              "(circular for a fair ranking). Set EVAL_JUDGE_BACKEND=openai + "
              "EVAL_JUDGE_API_KEY for an independent judge.", file=sys.stderr)

    # --private runs ONLY an operator-supplied held-out split (never merged into the
    # public set): its tasks score under a distinct ':private' config row and its
    # answers are NEVER written to Opik. The held-out suites must live OUTSIDE the
    # repo — shipping the answers in the skill would let any agent/model iterating
    # the eval read them, defeating the contamination/overfitting check.
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
            suites = load_all(CAP_DIR)
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

    run_id = now_utc().strftime("%Y%m%dT%H%M%SZ")
    opik = OpikClient(cfg.opik.base_url, cfg.opik.project)

    print(f"capability eval · {len(cases)} task(s) × {trials} trial(s) · "
          f"judge={'on' if want_judge else 'off'} · axis={args.axis}")
    outcomes, all_models, task_stats = [], [], []
    for s, _scn, case in cases:
        out = run_task(cfg, opik, s, case, trials, k, args.threshold, run_id, want_judge)
        outcomes.append((s.name, case.id, out))
        all_models += out.models
        task_stats.append(out.stats)
        st = out.stats
        print(f"  {s.name}/{case.id:24} success={st.mean_success:.2f} "
              f"pass^{st.k}={st.pass_hat_k:.2f} tok={int(st.mean_tokens)} "
              f"{'⚠️safety' if st.safety_violations else ''}")

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

    # Never publish held-out answers to Opik (write_opik upserts expected answers
    # into the shared dataset) — private rows stay local-only.
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
