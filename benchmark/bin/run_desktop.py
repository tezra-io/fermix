#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7"]
# ///
"""Desktop corpus runner (M86 P0): real-user requests against the compux fixture
applications, each judged by the application's own state file and counted from
the daemon's own traces. The library is `bin/desktoplib/`; this is the wiring.

One attempt is: launch the fixture on a fresh state file, send the task to the
daemon as one `fermix ask` turn (`evallib.driver`, as the other runners do), wait
for the turn, read what the fixture recorded, stop the fixture, then read the
turn's trace rows for model calls, images and computer-use failures. Each task
runs `--repeat` times (P3 needs at least 20 per cell), task order interleaved.

Every task is risk `desktop_input`: the model drives the real pointer and
keyboard and the helper captures the screen. So a live run is REFUSED unless
`--disposable-desktop` attests that the desktop, and the daemon home it runs
against, are disposable: a container or VM session, or a throwaway account, with
nobody using it. `--dry-run` validates the corpus and prints the plan, and
launches, sends and spends nothing. README §5h.

Exit: 0 complete, every attempt measured · 2 usage, corpus or attestation ·
3 preconditions · 4 incomplete: the run stopped early, or some attempts could not
be measured (a partial report is still written).
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
import tomllib
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from desktoplib import corpus, cu_trace, fixture, oracle  # noqa: E402
from evallib import config as cfgmod  # noqa: E402
from evallib import driver  # noqa: E402

EXIT_OK, EXIT_USAGE, EXIT_PRECONDITION, EXIT_INCOMPLETE = 0, 2, 3, 4

DEFAULT_SUITE = os.path.join(SKILL_DIR, "suites", "desktop", "corpus.yaml")
DEFAULT_FIXTURE_DIR = os.path.normpath(os.path.join(SKILL_DIR, "..", "..", "compux", "fixtures"))
# Where compux's `scripts/build_fixture_app.sh` puts the macOS fixture by default.
DEFAULT_FIXTURE_APP = "/tmp/FixtureApp"
DEFAULT_REPEAT = 20
PRODUCTION_HOME = "~/.fermix"

# Bounded waits. `Trace.record/4` is a cast, so a turn's last rows can land just
# after its reply; the fixture's last event can too.
TRACE_SETTLE_S = 20.0
TRACE_POLL_S = 0.5
STATE_QUIET_S = 1.0
STATE_MAX_S = 5.0
# After a turn the CLI gave up on, wait for the daemon to go quiet before the
# next attempt, so a turn still running cannot act on the next fixture.
QUIET_WINDOW_S = 20.0
QUIET_MAX_WAIT_S = 300.0
QUIET_POLL_S = 5.0

DISPOSABLE_HELP = """a live desktop run is refused without --disposable-desktop.

Every task is risk desktop_input: the model moves the real pointer, types real
keys and the computer-use helper captures the screen. Pass --disposable-desktop
only to attest that this desktop AND the daemon home it runs against
(FERMIX_EVAL_HOME, which a live run must set) are disposable: a container or VM
session, or a throwaway account, that nobody is using. Never a session someone
works in. --dry-run
validates and plans without any of this. benchmark/README.md §5h."""


class RunAbort(RuntimeError):
    """The run cannot go on: the daemon went away or never went quiet."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


@dataclass
class Context:
    """Everything one attempt needs, passed in: the seams the tests replace."""
    drive: Callable[[str, str, int], driver.DriveResult]
    traces_root: str
    out_dir: str
    fixture_def: corpus.Fixture
    fixture_dir: str
    fixture_app: str
    retained: int
    settle_s: float = fixture.WINDOW_SETTLE_S
    trace_settle_s: float = TRACE_SETTLE_S
    state_quiet_s: float = STATE_QUIET_S


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


# --- one attempt ---------------------------------------------------------------------

def run_attempt(ctx: Context, rendered: corpus.RenderedTask, repeat_index: int,
                run_id: str) -> dict:
    """Launch, drive, read, stop, count. An attempt that cannot be measured is
    `invalid` with a reason, never a scored failure."""
    label = f"{rendered.task.id}-r{repeat_index}"
    base = {"task": rendered.task.id, "verb": rendered.task.verb, "repeat": repeat_index,
            "fixture": rendered.fixture, "expect_refusal": rendered.task.expect_refusal}
    for sub in ("state", "logs"):
        os.makedirs(os.path.join(ctx.out_dir, sub), exist_ok=True)
    state_file = os.path.join(ctx.out_dir, "state", f"{label}.json")
    argv = corpus.launch_argv(ctx.fixture_def, fixture_dir=ctx.fixture_dir,
                              fixture_app=ctx.fixture_app, state_file=state_file)
    process = fixture.FixtureProcess(argv, ctx.fixture_def.env, state_file,
                                     os.path.join(ctx.out_dir, "logs", f"{label}.log"),
                                     settle_s=ctx.settle_s)
    try:
        with process:
            result = ctx.drive(f"e2e-{run_id}-{label}", rendered.query, rendered.task.timeout_ms)
            events, settled = fixture.wait_for_settled_state(state_file, ctx.state_quiet_s,
                                                             STATE_MAX_S)
    except fixture.FixtureError as exc:
        return {**base, "status": "invalid", "invalid_reason": exc.kind, "detail": str(exc)}
    except oracle.OracleError as exc:
        return {**base, "status": "invalid", "invalid_reason": "state_unreadable",
                "detail": str(exc)}
    if result.status == "not_running":
        raise RunAbort("daemon_down", f"the daemon stopped answering at {label}: {result.error}")
    if not result.ok:
        return {**base, "status": "invalid", "invalid_reason": f"turn_{result.status}",
                "detail": result.error}
    return score_attempt(ctx, base, rendered, result, events, settled)


def score_attempt(ctx: Context, base: dict, rendered: corpus.RenderedTask,
                  result: driver.DriveResult, events: list[dict], settled: bool) -> dict:
    try:
        session, rows = settled_turn_rows(ctx, result.sent_at.timestamp() * 1000.0)
    except cu_trace.TurnSelectionError as exc:
        return {**base, "status": "invalid", "invalid_reason": exc.kind, "detail": str(exc)}
    counts = cu_trace.turn_counts(rows, ctx.retained)
    unmeasurable = unmeasurable_turn(counts)
    if unmeasurable:
        return {**base, "status": "invalid", "turn": session, "counts": counts, **unmeasurable}
    results = oracle.evaluate(events, list(rendered.clauses))
    expected = rendered.task.expect_refusal
    seen = expected is not None and any(cu_trace.carries_code(row, expected) for row in rows
                                        if cu_trace.is_computer_use(row))
    return {**base, "status": "scored", "turn": session,
            "success": oracle.passed(results) and (expected is None or seen),
            "expected_refusal_seen": seen, "route": route_of(rows),
            "elapsed_ms": result.elapsed_ms,
            "events": len(events), "state_settled": settled,
            "clauses": [{"clause": r.clause.describe(), "passed": r.passed, "detail": r.detail}
                        for r in results],
            "counts": counts}


def unmeasurable_turn(counts: dict) -> dict | None:
    """Why the oracle cannot judge this turn, or None. A turn that made no
    computer-use call touched no fixture, which an `absent` clause would read as
    a pass (the helper missing, its `hello` failing). A computer-use row with no
    `output` means the daemon runs with content capture off
    (`FERMIX_TRACE_CONTENT=0`, which only the daemon's environment shows): its
    images would count as zero and its refusals could not be seen."""
    if counts["cu_calls"] == 0:
        return {"invalid_reason": "no_computer_use",
                "detail": "the turn made no computer_use call, so the fixture's silence "
                          "says nothing about the task"}
    if counts["cu_rows_without_output"]:
        return {"invalid_reason": "content_capture_off",
                "detail": f"{counts['cu_rows_without_output']} computer_use row(s) carry no "
                          "output: the daemon runs with FERMIX_TRACE_CONTENT=0, so images and "
                          "refusals cannot be counted"}
    return None


def settled_turn_rows(ctx: Context, start_ms: float) -> tuple[str, list[dict]]:
    """The turn's rows once their count stops moving, or at the settle cap."""
    deadline = time.monotonic() + ctx.trace_settle_s
    end_ms = time.time() * 1000.0
    rows = cu_trace.rows_between(ctx.traces_root, start_ms, end_ms)
    while time.monotonic() < deadline:
        time.sleep(TRACE_POLL_S)
        end_ms = time.time() * 1000.0
        latest = cu_trace.rows_between(ctx.traces_root, start_ms, end_ms)
        settled, rows = len(latest) == len(rows), latest
        if settled:
            break
    return cu_trace.select_turn(rows, start_ms, end_ms)


def route_of(rows: list[dict]) -> str | None:
    """The turn's most common `provider/model/effort`, from its own model calls."""
    routes = Counter(
        f"{r.get('provider')}/{r.get('model')}/{r.get('reasoning_effort') or 'default'}"
        for r in rows if r.get("type") == "llm_call" and r.get("model"))
    return max(sorted(routes), key=lambda key: routes[key]) if routes else None


# --- summaries -----------------------------------------------------------------------

def _median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def summarize(attempts: list[dict]) -> dict:
    scored = [a for a in attempts if a["status"] == "scored"]
    cu_calls = sum(a["counts"]["cu_calls"] for a in scored)
    cu_failures = sum(a["counts"]["cu_failures"] for a in scored)
    successes = sum(1 for a in scored if a["success"])
    return {
        "attempts": len(attempts), "scored": len(scored), "invalid": len(attempts) - len(scored),
        "successes": successes,
        "success_rate": successes / len(scored) if scored else None,
        "cu_failure_rate": cu_failures / cu_calls if cu_calls else None,
        "median_model_calls": _median([a["counts"]["model_calls"] for a in scored]),
        "median_image_tokens": _median([a["counts"]["image_tokens"] for a in scored]),
        "median_image_tokens_sent": _median([a["counts"]["image_tokens_sent"] for a in scored]),
        "median_elapsed_ms": _median([a["elapsed_ms"] for a in scored]),
    }


def failure_classes(attempts: list[dict]) -> dict:
    totals = Counter()
    for attempt in attempts:
        if attempt["status"] == "scored":
            totals.update(attempt["counts"]["failure_classes"])
            totals["missed_aim"] += attempt["counts"]["missed_aims"]
    return dict(sorted(totals.items()))


def render_report(doc: dict) -> str:
    overall = doc["summary"]
    lines = [f"# Desktop corpus — {doc['run_id']}", "",
             f"- fixture: `{doc['fixture']}` ({doc['platform']}) · repeat {doc['repeat']}",
             f"- routes: {', '.join(f'`{r}`' for r in doc['routes']) or 'none recorded'}",
             f"- window: {doc['started_at']} → {doc['finished_at']} · harness "
             f"`{doc['harness_git_rev']}`",
             f"- run: {_incomplete_line(doc.get('incomplete'))}",
             f"- attempts {overall['attempts']} · scored {overall['scored']} · invalid "
             f"{overall['invalid']} · success rate {_pct(overall['success_rate'])} · computer-use "
             f"failure rate {_pct(overall['cu_failure_rate'])}",
             f"- failure classes: `{doc['failure_classes']}`", "",
             "Success is what the fixture recorded about itself. Image tokens are width × "
             "height / 750 per image a tool returned; *sent* counts each image again for every "
             f"later model call that carried it (the last {doc['retained_screenshots']} are kept).",
             "", "| task | verb | scored | invalid | success | model calls (median) | "
             "image tokens | image tokens sent | cu failure rate |",
             "|---|---|---|---|---|---|---|---|---|"]
    for task_id, summary in doc["tasks"].items():
        lines.append(f"| {task_id} | {summary['verb']} | {summary['scored']} | "
                     f"{summary['invalid']} | {_pct(summary['success_rate'])} | "
                     f"{_num(summary['median_model_calls'])} | "
                     f"{_num(summary['median_image_tokens'])} | "
                     f"{_num(summary['median_image_tokens_sent'])} | "
                     f"{_pct(summary['cu_failure_rate'])} |")
    return "\n".join(lines) + "\n"


def _pct(value) -> str:
    return "—" if value is None else f"{value * 100:.1f}%"


def _num(value) -> str:
    return "—" if value is None else f"{value:.0f}"


def _incomplete_line(incomplete: dict | None) -> str:
    if not incomplete:
        return "complete"
    return f"**INCOMPLETE** — {incomplete['reason']}: {incomplete['detail']}"


# --- preconditions -------------------------------------------------------------------

def host_platform() -> str:
    return "macos" if sys.platform == "darwin" else ("linux" if sys.platform.startswith("linux")
                                                     else sys.platform)


def launch_files(fixture_def: corpus.Fixture, fixture_dir: str, fixture_app: str) -> list[str]:
    """The files a fixture's launch command names: the script or the binary."""
    argv = corpus.launch_argv(fixture_def, fixture_dir=fixture_dir, fixture_app=fixture_app,
                              state_file="")
    return [part for template, part in zip(fixture_def.launch, argv)
            if "{fixture_dir}" in template or "{fixture_app}" in template]


def eval_home_error(environ) -> str | None:
    """A live run names its daemon home. Left unset, the harness config falls back
    to `~/.fermix-dev`, which on the owner's Mac is the live development daemon
    the phone pairs with."""
    if environ.get("FERMIX_EVAL_HOME"):
        return None
    return ("FERMIX_EVAL_HOME is not set: a live desktop run names the disposable desktop's "
            "eval home explicitly and never falls back to the harness default (~/.fermix-dev)")


def production_home_error(cfg) -> str | None:
    home = os.path.realpath(os.path.expanduser(cfg.daemon.fermix_home))
    if home == os.path.realpath(os.path.expanduser(PRODUCTION_HOME)):
        return (f"FERMIX_EVAL_HOME is the production home {PRODUCTION_HOME}, which no eval may "
                "use; point it at the disposable desktop's eval home")
    return None


def config_problems(fermix_home: str) -> list[str]:
    """File truth about the daemon that will act: computer use is OFF by default
    and a strict sandbox derives look-only access, which refuses every action."""
    path = os.path.join(os.path.realpath(os.path.expanduser(fermix_home)), "config.toml")
    try:
        with open(path, "rb") as handle:
            raw = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        return [f"cannot read the daemon config at {path}: {exc}"]
    problems = []
    if not raw.get("fermix_core", {}).get("computer_use", {}).get("enabled"):
        problems.append(f"{path}: set [fermix_core.computer_use] enabled = true")
    if raw.get("sandbox", {}).get("mode", "standard") == "strict":
        problems.append(f'{path}: [sandbox] mode = "strict" derives look-only computer use, '
                        "which refuses every action")
    return problems


def retained_screenshots(fermix_home: str) -> int:
    """The home's `max_retained_screenshots`, or the engine's default when unset."""
    path = os.path.join(os.path.realpath(os.path.expanduser(fermix_home)), "config.toml")
    with open(path, "rb") as handle:
        raw = tomllib.load(handle)
    section = raw.get("fermix_core", {}).get("computer_use", {})
    return int(section.get("max_retained_screenshots", cu_trace.DEFAULT_RETAINED))


def preconditions(cfg, args, fixture_def: corpus.Fixture) -> list[str]:
    """In order, each with its own fix. The production home is refused before
    anything is asked of a daemon."""
    production = production_home_error(cfg)
    if production:
        return [production]
    if fixture_def.platform != host_platform():
        return [f"the {fixture_def.name} fixture runs on {fixture_def.platform}; this host is "
                f"{host_platform()}"]
    problems = [f"{path} does not exist (--fixture-dir / --fixture-app)"
                for path in launch_files(fixture_def, args.fixture_dir, args.fixture_app)
                if not os.path.isfile(path)]
    reachable, detail = driver.daemon_reachable(cfg)
    if not reachable:
        problems.append(f"daemon not reachable (FERMIX_HOME={cfg.daemon.fermix_home}): {detail}")
    return problems + config_problems(cfg.daemon.fermix_home)


def fixture_mismatch(loaded: corpus.Corpus, fixture_def: corpus.Fixture, args,
                     scratch: str) -> list[str]:
    """Run the fixture's own self-test and check it records every control the
    corpus may assert on: a corpus naming a control the fixture never records
    would score every attempt at it as the model's failure."""
    state = os.path.join(scratch, "self-test.json")
    argv = corpus.launch_argv(fixture_def, fixture_dir=args.fixture_dir,
                              fixture_app=args.fixture_app, state_file=state)
    try:
        recorded = fixture.self_test_controls(argv, fixture_def.env, state)
    except (fixture.FixtureError, oracle.OracleError) as exc:
        return [f"{fixture_def.name} fixture self-test: {exc}"]
    missing = fixture_def.controls(loaded.families, loaded.shared) - recorded
    return [f"the {fixture_def.name} fixture never recorded {sorted(missing)}"] if missing else []


# --- the run -------------------------------------------------------------------------

def live_drive(cfg) -> Callable[[str, str, int], driver.DriveResult]:
    def drive(session: str, query: str, timeout_ms: int) -> driver.DriveResult:
        result, _used = driver.drive_with_usage_retry(cfg, session, query, timeout_ms, session)
        return result
    return drive


def wait_for_quiet(ctx: Context, since_ms: float) -> None:
    """After a turn the CLI abandoned: hold until no main-agent row has landed
    for QUIET_WINDOW_S, or abort at QUIET_MAX_WAIT_S."""
    deadline = time.monotonic() + QUIET_MAX_WAIT_S
    while time.monotonic() < deadline:
        rows = cu_trace.rows_between(ctx.traces_root, since_ms, time.time() * 1000.0)
        last = max((cu_trace.end_ms(r) for r in rows if r.get("agent") == "main"), default=since_ms)
        if time.time() * 1000.0 - last >= QUIET_WINDOW_S * 1000.0:
            return
        time.sleep(QUIET_POLL_S)
    raise RunAbort("daemon_busy", f"the daemon was still working {QUIET_MAX_WAIT_S:.0f} s after "
                   "a turn the CLI gave up on; nothing more is driven")


def drive_all(ctx: Context, plan: list[corpus.RenderedTask], repeat: int, run_id: str,
              attempts: list[dict]) -> None:
    """Every task once, then again, `repeat` times: the order interleaves tasks, so
    drift over a long run spreads across all of them. Appends as it goes, so an
    abort keeps what was measured."""
    for repeat_index in range(1, repeat + 1):
        for rendered in plan:
            drive_one(ctx, rendered, repeat_index, run_id, attempts)


def drive_one(ctx: Context, rendered: corpus.RenderedTask, repeat_index: int, run_id: str,
              attempts: list[dict]) -> None:
    started_ms = time.time() * 1000.0
    attempt = run_attempt(ctx, rendered, repeat_index, run_id)
    attempts.append(attempt)
    print(f"[desktop] {rendered.task.id} r{repeat_index}: {_attempt_word(attempt)}")
    if attempt.get("invalid_reason") == "turn_timeout":
        wait_for_quiet(ctx, started_ms)


def _attempt_word(attempt: dict) -> str:
    if attempt["status"] != "scored":
        return f"INVALID ({attempt['invalid_reason']})"
    return "pass" if attempt["success"] else "fail"


def run(cfg, args, loaded: corpus.Corpus, plan: list[corpus.RenderedTask]) -> int:
    started = now_utc()
    run_id = f"desktop-{args.fixture}-{started.strftime('%Y%m%d-%H%M%S')}"
    out_dir = os.path.join(cfg.report_dir, "desktop", run_id)
    os.makedirs(out_dir, exist_ok=True)
    fixture_def = loaded.fixtures[args.fixture]
    mismatch = fixture_mismatch(loaded, fixture_def, args, out_dir)
    if mismatch:
        print("preconditions:\n  - " + "\n  - ".join(mismatch), file=sys.stderr)
        return EXIT_PRECONDITION
    ctx = Context(drive=live_drive(cfg), traces_root=os.path.join(cfg.daemon.fermix_home, "traces"),
                  out_dir=out_dir, fixture_def=fixture_def, fixture_dir=args.fixture_dir,
                  fixture_app=args.fixture_app,
                  retained=retained_screenshots(cfg.daemon.fermix_home))
    attempts: list[dict] = []
    incomplete = None
    try:
        drive_all(ctx, plan, args.repeat, run_id, attempts)
    except (RunAbort, driver.UsageLimitHit, driver.AuthInvalidated) as exc:
        incomplete = {"reason": getattr(exc, "kind", type(exc).__name__), "detail": str(exc)}
    doc = build_document(args, run_id, started, ctx, attempts, incomplete)
    write_reports(out_dir, doc)
    if incomplete or doc["summary"]["invalid"]:
        print(f"[desktop] incomplete: {incomplete or 'some attempts could not be measured'}",
              file=sys.stderr)
        return EXIT_INCOMPLETE
    return EXIT_OK


def build_document(args, run_id: str, started: datetime, ctx: Context, attempts: list[dict],
                   incomplete: dict | None) -> dict:
    by_task: dict[str, dict] = {}
    for attempt in attempts:
        by_task.setdefault(attempt["task"], []).append(attempt)
    routes = sorted({a["route"] for a in attempts if a.get("route")})
    return {
        "run_id": run_id, "fixture": args.fixture, "platform": host_platform(),
        "repeat": args.repeat, "started_at": started.isoformat(),
        "finished_at": now_utc().isoformat(), "harness_git_rev": git_rev(),
        "routes": [args.config_id] if args.config_id else routes,
        "retained_screenshots": ctx.retained, "incomplete": incomplete,
        "summary": summarize(attempts), "failure_classes": failure_classes(attempts),
        "tasks": {task_id: {"verb": group[0]["verb"], **summarize(group)}
                  for task_id, group in by_task.items()},
        "attempts": attempts,
    }


def write_reports(out_dir: str, doc: dict) -> None:
    results = os.path.join(out_dir, "results.json")
    with open(results, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2)
        handle.write("\n")
    report = os.path.join(out_dir, "report.md")
    with open(report, "w", encoding="utf-8") as handle:
        handle.write(render_report(doc))
    print(f"[desktop] wrote {results}\n[desktop] wrote {report}")


def git_rev() -> str:
    try:
        done = subprocess.run(["git", "-C", SKILL_DIR, "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    return done.stdout.strip() if done.returncode == 0 else "unknown"


# --- dry run -------------------------------------------------------------------------

def dry_run(loaded: corpus.Corpus, names: list[str], tasks: list[corpus.Task], args) -> int:
    rendered = {name: {r.task.id: r for r in corpus.render_all(_only(loaded, tasks), [name])}
                for name in names}
    print(f"desktop corpus {loaded.suite}: {len(tasks)} task(s), risk {loaded.risk} — "
          f"{os.path.relpath(loaded.path, SKILL_DIR)}")
    print(f"plan: --repeat {args.repeat} → {len(tasks) * args.repeat} turn(s) per fixture; "
          f"fixtures {', '.join(f'{n} ({loaded.fixtures[n].platform})' for n in names)}")
    for task in tasks:
        refusal = f" · expect refusal {task.expect_refusal}" if task.expect_refusal else ""
        print(f"\n  {task.id} [{task.verb}] risk={task.risk}{refusal}")
        for name in names:
            print(f"    {name}: {rendered[name][task.id].query}")
        clauses = rendered[names[0]][task.id].clauses
        print("      oracle: " + "; ".join(clause.describe() for clause in clauses))
    print("\npreconditions for a live run on this host (" + host_platform() + "):")
    for name in names:
        print(f"  {name}: {_launch_note(loaded.fixtures[name], args)}")
    print("\na live run needs --fixture NAME, --disposable-desktop and FERMIX_EVAL_HOME set "
          "(a desktop and daemon home nobody uses);\ndry run: nothing launched, nothing sent, "
          "nothing spent")
    return EXIT_OK


def _only(loaded: corpus.Corpus, tasks: list[corpus.Task]) -> corpus.Corpus:
    return corpus.Corpus(path=loaded.path, suite=loaded.suite, title=loaded.title,
                         risk=loaded.risk, fixtures=loaded.fixtures, families=loaded.families,
                         shared=loaded.shared, tasks=tuple(tasks))


def _launch_note(fixture_def: corpus.Fixture, args) -> str:
    if fixture_def.platform != host_platform():
        return f"runs on {fixture_def.platform}; not checked here"
    files = launch_files(fixture_def, args.fixture_dir, args.fixture_app)
    missing = [path for path in files if not os.path.isfile(path)]
    return f"MISSING {', '.join(missing)}" if missing else f"found {', '.join(files)}"


# --- entry ---------------------------------------------------------------------------

def build_args(argv):
    p = argparse.ArgumentParser(description="Desktop corpus runner (M86 P0)")
    p.add_argument("--suite", default=DEFAULT_SUITE, help="the corpus file")
    p.add_argument("--fixture", help="the fixture a live run measures (gtk3, gtk4, qt, macos); "
                                     "a dry run plans every fixture unless one is named")
    p.add_argument("--task", action="append", default=[], help="one task id (repeatable)")
    p.add_argument("--repeat", type=int, default=DEFAULT_REPEAT,
                   help=f"attempts per task (default {DEFAULT_REPEAT}, what P3 needs per cell)")
    p.add_argument("--dry-run", action="store_true",
                   help="validate the corpus and print the plan; launch, send and spend nothing")
    p.add_argument("--disposable-desktop", action="store_true",
                   help="attest this desktop and the daemon home are disposable (see --help text "
                        "of a refused run); required for a live run")
    p.add_argument("--fixture-dir", default=DEFAULT_FIXTURE_DIR,
                   help="compux's fixtures/ directory (default: the compux checkout beside "
                        "this one)")
    p.add_argument("--fixture-app", default=DEFAULT_FIXTURE_APP,
                   help="the built macOS fixture (scripts/build_fixture_app.sh)")
    p.add_argument("--config-id", help="label for the measured config (default: from the turns' "
                                       "own model calls)")
    return p.parse_args(argv)


def selection(loaded: corpus.Corpus, args) -> tuple[list[str], list[corpus.Task], str | None]:
    if args.repeat < 1:
        return [], [], "--repeat must be at least 1"
    if args.fixture and args.fixture not in loaded.fixtures:
        return [], [], f"--fixture {args.fixture!r} is not one of {sorted(loaded.fixtures)}"
    known = {task.id for task in loaded.tasks}
    unknown = [task_id for task_id in args.task if task_id not in known]
    if unknown:
        return [], [], f"--task {unknown} matched nothing in the corpus"
    tasks = [t for t in loaded.tasks if not args.task or t.id in args.task]
    names = [args.fixture] if args.fixture else sorted(loaded.fixtures)
    return names, tasks, None


def live_usage_error(args) -> str | None:
    if not args.disposable_desktop:
        return DISPOSABLE_HELP
    if not args.fixture:
        return "a live run measures ONE fixture: name it with --fixture"
    return None


def main(argv=None) -> int:
    args = build_args(argv)
    try:
        loaded = corpus.load(args.suite)
    except corpus.CorpusError as exc:
        print("corpus refused:\n  - " + "\n  - ".join(exc.problems), file=sys.stderr)
        return EXIT_USAGE
    names, tasks, problem = selection(loaded, args)
    if problem:
        print(problem, file=sys.stderr)
        return EXIT_USAGE
    if args.dry_run:
        return dry_run(loaded, names, tasks, args)
    usage = live_usage_error(args)
    if usage:
        print(usage, file=sys.stderr)
        return EXIT_USAGE
    unset = eval_home_error(os.environ)
    if unset:
        print(f"preconditions:\n  - {unset}", file=sys.stderr)
        return EXIT_PRECONDITION
    cfg = cfgmod.load(SKILL_DIR)
    problems = preconditions(cfg, args, loaded.fixtures[args.fixture])
    if problems:
        print("preconditions:\n  - " + "\n  - ".join(problems), file=sys.stderr)
        return EXIT_PRECONDITION
    plan = corpus.render_all(_only(loaded, tasks), [args.fixture])
    return run(cfg, args, loaded, plan)


if __name__ == "__main__":
    sys.exit(main())
