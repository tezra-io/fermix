#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7"]
# ///
"""Fermix E2E eval runner.

Drives realistic queries into the Opik-enabled dev daemon, grades each turn's Opik
trace against YAML-declared expectations (structural gates + optional LLM judge),
and writes MD/HTML/JSON reports. See SKILL.md and suites/SCHEMA.md.

Exit codes: 0 = no critical failures · 1 = a critical scenario failed · 2 = usage/
selection error · 3 = preconditions not met (Opik or daemon down).
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from evallib import config as cfgmod
from evallib import driver, grade, judge, report
from evallib.opik import OpikClient, OpikError, text_of
from evallib.suites import SuiteError, load_all

_SESS_RE = re.compile(r"[^A-Za-z0-9_-]")


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def sess(*parts: str) -> str:
    return _SESS_RE.sub("-", "-".join(parts))[:90]


# --- selection --------------------------------------------------------------

def select(suites, args):
    want_suites = set(args.suite or [])
    want_scen = set(args.scenario or [])
    want_tags = set(args.tag or [])
    chosen = []
    for s in suites:
        if want_suites and s.name not in want_suites:
            continue
        scns = []
        for scn in s.scenarios:
            if want_scen and scn.id not in want_scen:
                continue
            if want_tags and not (want_tags & set(scn.tags)):
                continue
            scns.append(scn)
        if scns:
            chosen.append((s, scns))
    return chosen


def plan_counts(chosen, judge_on: bool) -> tuple[int, int, int, int]:
    scenarios = cases = turns = judge_turns = 0
    for _s, scns in chosen:
        for scn in scns:
            scenarios += 1
            for c in scn.cases:
                cases += 1
                turns += len(c.turns)
                if judge_on and c.judge and c.rubric:
                    judge_turns += 1
    return scenarios, cases, turns, judge_turns


# --- precondition checks ----------------------------------------------------

def check(cfg) -> int:
    ok = True
    client = OpikClient(cfg.opik.base_url, cfg.opik.project)
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
        print(f"  [ok] dev daemon reachable (FERMIX_HOME={cfg.daemon.fermix_home})")
    else:
        print(f"  [FAIL] dev daemon not reachable (FERMIX_HOME={cfg.daemon.fermix_home}): {detail}")
        print("         start the Opik-enabled dev daemon at ~/.fermix-dev "
              "(FERMIX_OPIK_ENABLED=1) before running evals.")
        ok = False
    import glob as _glob
    n_yaml = len(_glob.glob(os.path.join(SKILL_DIR, "suites", "*.yaml")))
    print(f"  [ok] PyYAML present, {n_yaml} suite file(s)")
    return 0 if ok else 3


def purge(cfg) -> int:
    """Delete only the skill's own eval traces (thread chat_id `e2e-*`) from Opik.

    Never touches real Telegram/CLI/job traces or test fixtures — those have other
    thread prefixes. The skill grades from the JSON/MD report, not from long-lived
    Opik traces, so purging keeps the project tidy across many runs.
    """
    client = OpikClient(cfg.opik.base_url, cfg.opik.project)
    try:
        ids = client.eval_trace_ids(prefixes=("e2e-",))
    except OpikError as exc:
        print(f"Opik unreachable: {exc}", file=sys.stderr)
        return 3
    if not ids:
        print(f"no eval traces (thread e2e-*) in project '{cfg.opik.project}'.")
        return 0
    client.delete_traces(ids)
    print(f"purged {len(ids)} eval trace(s) (thread e2e-*) from project '{cfg.opik.project}'.")
    return 0


# --- operator-assisted cases (real channel turns) ----------------------------

def dev_daemon_streaming_enabled(cfg) -> bool:
    """True iff the dev daemon's config opts Telegram into streaming (draft or block).

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


def run_operator_case(cfg, client, suite, scn, case, run_id):
    """Drive one operator-assisted Telegram case.

    The runner cannot inject a Telegram inbound (real Bot API, polling), so the
    operator sends ONE marked message from their own chat; the runner correlates
    the resulting `telegram:*` trace by the marker and grades it exactly like an
    `ask` case. Streaming gates ride the normal tools_* vocabulary because
    stream phases export as tool-type spans named `stream:open|seal|discard`.
    """
    import uuid

    marker = f"e2e-mark-{uuid.uuid4().hex[:6]}"
    query = case.turns[0].query
    message = f"{query} (eval:{marker})"
    eff = {"max_cost_usd": cfg.budgets.max_cost_usd,
           "max_duration_ms": cfg.budgets.max_duration_ms}
    eff.update(case.expect)
    wait_s = (case.timeout_ms or 300_000) / 1000.0

    rec = {"index": 0, "query": message, "session": marker, "status": "error",
           "drive_error": None, "note": None, "correlation": "n/a", "gates": [],
           "tools": [], "reply": "", "cost_usd": 0.0, "duration_ms": 0.0, "tokens": 0,
           "iterations": None, "subagent_spawns": 0, "trace_id": None, "trace_url": ""}

    if not dev_daemon_streaming_enabled(cfg):
        rec["drive_error"] = ("streaming not enabled in the dev daemon: set "
                              '[fermix_channels.telegram] streaming = "draft" (or "block") in '
                              f"{cfg.daemon.fermix_home}/config.toml and RESTART the daemon")
        print(f"    FAIL precondition: {rec['drive_error']}")
        return {"id": case.id, "passed": False, "gate_passed": False,
                "turns": [rec], "rubric": None}

    print(f"\n    OPERATOR ACTION — send this exact message to the dev Telegram bot now:")
    print(f"      {message}")
    print(f"    waiting up to {int(wait_s)}s for the turn's trace…", flush=True)

    after = now_utc() - timedelta(seconds=10)
    found = client.poll_for_marker("telegram:", marker, after, set(),
                                   wait_s, cfg.opik.poll_interval_s)
    if found is None:
        rec["correlation"] = "missing"
        rec["drive_error"] = f"no telegram trace containing '{marker}' appeared within {int(wait_s)}s"
        return {"id": case.id, "passed": False, "gate_passed": False,
                "turns": [rec], "rubric": None}

    trace, spans = client.await_complete(found)
    gates = grade.grade(trace, spans, eff)
    view = grade.TurnView.build(trace, spans)
    rec.update({
        "status": "ok",
        "correlation": "ok",
        "gates": [{"key": g.key, "passed": g.passed, "detail": g.detail} for g in gates],
        "tools": view.tool_names,
        "reply": view.reply,
        "cost_usd": view.cost,
        "duration_ms": view.duration_ms,
        "tokens": view.tokens,
        "iterations": view.iterations,
        "subagent_spawns": view.subagent_spawns,
        "trace_id": trace["id"],
        "trace_url": f"{cfg.opik.ui_base}/api/v1/private/traces/{trace['id']}",
    })
    gate_ok = all(g.passed for g in gates)
    return {"id": case.id, "passed": gate_ok, "gate_passed": gate_ok,
            "turns": [rec], "rubric": None}


# --- run one case -----------------------------------------------------------

def run_case(cfg, client, suite, scn, case, run_id, judge_on):
    budget = {"max_cost_usd": cfg.budgets.max_cost_usd, "max_duration_ms": cfg.budgets.max_duration_ms}
    session = sess("e2e", suite.name, scn.id, case.id, run_id)
    seen: set[str] = set()
    turn_records = []
    final_reply = ""
    last_query = case.turns[-1].query if case.turns else ""
    gate_ok = True

    # Pass the full timeout to the daemon — the daemon's await_reply uses this value
    # to bound how long it waits for the agent to reply. Suites size timeout_ms for the
    # expected task duration (e.g. 1500 s for /ultra). The old 300-s cap caused the
    # daemon to time out mid-turn, killing the server-side work and leaving no trace.
    # The poll_budget covers the time between when the CLI returns (ok or timeout) and
    # when the trace fully appears in Opik (flush + spans).
    effective_timeout = case.timeout_ms or cfg.daemon.default_timeout_ms
    cli_timeout = effective_timeout
    poll_budget = max(cfg.opik.poll_timeout_s, effective_timeout / 1000.0 + 60)

    for i, turn in enumerate(case.turns):
        is_final = i == len(case.turns) - 1
        eff = dict(budget)
        eff.update(turn.expect)
        if is_final:
            eff.update(case.expect)  # case-level gates (+ suite defaults) on the final turn

        res = driver.drive_query(cfg, session, turn.query, timeout_ms=cli_timeout,
                                 attachments=(case.images if i == 0 else None))
        rec = {"index": i, "query": turn.query, "session": session, "status": res.status,
               "drive_error": res.error, "note": None, "correlation": "n/a", "gates": [],
               "tools": [], "reply": "", "cost_usd": 0.0, "duration_ms": 0.0, "tokens": 0,
               "iterations": None, "subagent_spawns": 0, "trace_id": None, "trace_url": ""}
        # Hard stop: daemon unreachable or binary missing — no trace to grade.
        if res.status in ("not_running", "crashed"):
            gate_ok = False
            turn_records.append(rec)
            break
        # ok, timeout, or error (daemon-side JSON envelope): always poll Opik.
        # "error" responses include daemon-side timeouts where the agent kept running
        # server-side and may have written a complete trace; and CLI-side decode failures
        # (truncated socket reads) where the daemon already flushed the trace. Polling
        # is cheap — missing trace → gate_ok=False anyway.
        after = res.sent_at - timedelta(seconds=10)
        found = client.poll_for_turn(session, turn.query, after, seen,
                                     poll_budget, cfg.opik.poll_interval_s)
        if found is None:
            rec["correlation"] = "missing"
            gate_ok = False
            final_reply = res.response or final_reply
            turn_records.append(rec)
            continue
        seen.add(found["id"])
        # Wait for the trace+spans to fully flush before grading (they arrive in
        # separate Opik batches; grading early sees 0 tools/$0 — a false failure).
        trace, spans = client.await_complete(found)
        gates = grade.grade(trace, spans, eff)
        view = grade.TurnView.build(trace, spans)
        final_reply = view.reply or res.response or final_reply
        note = None
        if res.status == "timeout":
            note = (f"CLI wait elapsed at {cli_timeout // 1000}s; turn completed server-side "
                    f"({int(view.duration_ms)}ms) and was graded from its Opik trace.")
        rec.update({
            "status": "ok",
            "note": note,
            "correlation": "ok",
            "gates": [{"key": g.key, "passed": g.passed, "detail": g.detail} for g in gates],
            "tools": view.tool_names,
            "reply": view.reply,
            "cost_usd": view.cost,
            "duration_ms": view.duration_ms,
            "tokens": view.tokens,
            "iterations": view.iterations,
            "subagent_spawns": view.subagent_spawns,
            "trace_id": trace["id"],
            "trace_url": f"{cfg.opik.ui_base}/api/v1/private/traces/{trace['id']}",
        })
        if any(not g.passed for g in gates):
            gate_ok = False
        turn_records.append(rec)

    rubric_rec = None
    if case.rubric:
        if judge_on and case.judge:
            jr = judge.judge_case(cfg, last_query, final_reply, case.rubric,
                                  tag=sess(scn.id, case.id, run_id))
            rubric_rec = {"text": case.rubric, "evaluated": jr.evaluated, "passed": jr.passed,
                          "score": jr.score, "rationale": jr.rationale, "error": jr.error,
                          "backend": jr.backend}
        else:
            rubric_rec = {"text": case.rubric, "evaluated": False, "passed": None,
                          "score": None, "rationale": "", "error": "judge disabled", "backend": ""}

    passed = gate_ok
    if rubric_rec and rubric_rec["evaluated"] and rubric_rec["passed"] is False \
            and cfg.rubric_failures == "fail":
        passed = False

    return {"id": case.id, "passed": passed, "gate_passed": gate_ok,
            "turns": turn_records, "rubric": rubric_rec}


# --- aggregation ------------------------------------------------------------

def aggregate(cfg, run_id, started, finished, suite_results) -> dict:
    tot = {"scenarios": 0, "cases": 0, "turns": 0, "cases_passed": 0, "cases_failed": 0,
           "critical_failed": 0, "gates": 0, "gates_passed": 0, "rubrics": 0,
           "rubrics_passed": 0, "cost_usd": 0.0, "duration_ms_total": 0.0}
    for s in suite_results:
        st = s["totals"]
        for k in tot:
            tot[k] += st.get(k, 0)
    return {
        "run_id": run_id,
        "started_at": iso(started),
        "finished_at": iso(finished),
        "config": {"daemon_home": cfg.daemon.fermix_home, "opik_project": cfg.opik.project,
                   "judge_backend": cfg.judge.backend, "judge_enabled": tot.get("_judge_on", False)},
        "totals": tot,
        "suites": suite_results,
    }


def suite_totals(scenario_results) -> dict:
    st = {"scenarios": 0, "cases": 0, "turns": 0, "cases_passed": 0, "cases_failed": 0,
          "critical_failed": 0, "gates": 0, "gates_passed": 0, "rubrics": 0,
          "rubrics_passed": 0, "cost_usd": 0.0, "duration_ms_total": 0.0}
    for scn in scenario_results:
        st["scenarios"] += 1
        for c in scn["cases"]:
            st["cases"] += 1
            st["cases_passed"] += 1 if c["passed"] else 0
            st["cases_failed"] += 0 if c["passed"] else 1
            if scn["severity"] == "critical" and not c["passed"]:
                st["critical_failed"] += 1
            for turn in c["turns"]:
                st["turns"] += 1
                st["cost_usd"] += turn["cost_usd"]
                st["duration_ms_total"] += turn["duration_ms"]
                for g in turn["gates"]:
                    st["gates"] += 1
                    st["gates_passed"] += 1 if g["passed"] else 0
            rb = c.get("rubric")
            if rb and rb["evaluated"]:
                st["rubrics"] += 1
                st["rubrics_passed"] += 1 if rb["passed"] else 0
    return st


# --- main -------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Fermix E2E eval (Opik trace-based)")
    ap.add_argument("--suite", action="append", help="suite name (repeatable)")
    ap.add_argument("--scenario", action="append", help="scenario id (repeatable)")
    ap.add_argument("--tag", action="append", help="scenario tag (repeatable)")
    ap.add_argument("--all", action="store_true", help="run every suite (expensive)")
    ap.add_argument("--judge", action="store_true", help="enable LLM-judge rubric grading")
    ap.add_argument("--dry-run", action="store_true", help="validate + plan only; no daemon calls")
    ap.add_argument("--check", action="store_true", help="check preconditions only")
    ap.add_argument("--purge", action="store_true",
                    help="delete this skill's own eval traces (thread e2e-*) from Opik, then exit")
    ap.add_argument("--max-cases", type=int, default=0, help="cap number of cases driven (0 = no cap)")
    ap.add_argument("--operator", action="store_true",
                    help="include operator-assisted cases (you send a Telegram message when prompted); "
                         "without this flag such cases are skipped with a notice")
    ap.add_argument("--dangerous", action="store_true",
                    help="include suites from suites/dangerous/ — these exercise the sandbox by "
                         "issuing commands that cause real harm if the sandbox fails; only run in "
                         "an isolated, disposable test environment, never on your dev machine")
    ap.add_argument("--out", default=None, help="report output dir (default: reports/<ts>)")
    ap.add_argument("--config", default=None, help="config.yaml path")
    args = ap.parse_args(argv)

    cfg = cfgmod.load(SKILL_DIR, args.config)
    judge_on = args.judge or cfg.judge.enabled

    if args.purge:
        return purge(cfg)

    if args.check:
        print("preconditions:")
        return check(cfg)

    if args.dangerous and not (args.suite or args.scenario):
        print("--dangerous requires --suite <name> or --scenario <id>: refusing to run all "
              "dangerous suites at once.", file=sys.stderr)
        return 2

    try:
        suites = load_all(os.path.join(SKILL_DIR, "suites"),
                          include_dangerous=args.dangerous)
    except SuiteError as exc:
        print(f"suite validation failed ({len(exc.problems)} problem(s)):", file=sys.stderr)
        for p in exc.problems:
            print(f"  - {p}", file=sys.stderr)
        return 2

    has_filter = bool(args.suite or args.scenario or args.tag)

    if args.dry_run:
        chosen = select(suites, args) if has_filter else [(s, s.scenarios) for s in suites]
        nsc, nc, nt, _ = plan_counts(chosen, judge_on)
        print(f"dry-run OK — {len(chosen)} suite(s), {nsc} scenario(s), {nc} case(s), {nt} turn(s) would run.")
        for s, scns in chosen:
            print(f"  {s.name}: {len(scns)} scenario(s)")
            for scn in scns:
                print(f"    - {scn.id} [{scn.severity}] · {len(scn.cases)} cases · tags={scn.tags}")
        return 0

    if not (args.all or has_filter):
        print("nothing selected. Pass --all, --suite NAME, --scenario ID, or --tag TAG "
              "(refusing to drive every suite implicitly — that is real spend).", file=sys.stderr)
        print(f"available suites: {', '.join(s.name for s in suites)}", file=sys.stderr)
        return 2

    chosen = select(suites, args)
    if not chosen:
        print("selection matched no scenarios.", file=sys.stderr)
        return 2

    # preconditions before spending tokens
    print("preconditions:")
    if check(cfg) != 0:
        return 3

    nsc, nc, nt, njudge = plan_counts(chosen, judge_on)
    if args.max_cases:
        print(f"note: --max-cases {args.max_cases} (of {nc})")
    est = nt + njudge
    print(f"\nplan: {nsc} scenario(s), {nc} case(s), ~{est} real turns "
          f"({nt} eval + {njudge} judge). Each turn is a real gpt-5.x turn "
          f"(~$0.2–0.6, ~15–45s). Driving now...\n")

    client = OpikClient(cfg.opik.base_url, cfg.opik.project)
    run_id = now_utc().strftime("%Y%m%dT%H%M%SZ")
    started = now_utc()
    suite_results = []
    cases_done = 0
    stop = False

    for s, scns in chosen:
        scenario_results = []
        for scn in scns:
            case_results = []
            for case in scn.cases:
                if args.max_cases and cases_done >= args.max_cases:
                    stop = True
                    break
                if case.drive != "ask" and not args.operator:
                    print(f"  · {s.name}/{scn.id}/{case.id} — SKIPPED "
                          "(operator-assisted; rerun with --operator)", flush=True)
                    continue
                print(f"  · {s.name}/{scn.id}/{case.id} …", flush=True)
                if case.drive == "telegram_operator":
                    cr = run_operator_case(cfg, client, s, scn, case, run_id)
                else:
                    cr = run_case(cfg, client, s, scn, case, run_id, judge_on)
                case_results.append(cr)
                cases_done += 1
                mark = "PASS" if cr["passed"] else "FAIL"
                print(f"    {mark} (gates {'ok' if cr['gate_passed'] else 'FAILED'})")
            if case_results:
                scenario_results.append({"id": scn.id, "title": scn.title, "severity": scn.severity,
                                         "tags": scn.tags, "cases": case_results,
                                         "passed": all(c["passed"] for c in case_results)})
            if stop:
                break
        if scenario_results:
            st = suite_totals(scenario_results)
            suite_results.append({"name": s.name, "title": s.title, "scenarios": scenario_results,
                                  "totals": st})
        if stop:
            break

    finished = now_utc()
    results = aggregate(cfg, run_id, started, finished, suite_results)
    results["config"]["judge_enabled"] = judge_on

    out_dir = args.out or os.path.join(cfg.report_dir, run_id)
    paths = report.write(results, out_dir)

    t = results["totals"]
    print(f"\n{'='*60}")
    print(f"cases {t['cases_passed']}/{t['cases']} passed · critical fails {t['critical_failed']} · "
          f"gates {t['gates_passed']}/{t['gates']} · cost ${t['cost_usd']:.4f}")
    print(f"report: {paths['md']}")
    print(f"        {paths['html']}")
    return 0 if t["critical_failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
