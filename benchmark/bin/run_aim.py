#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7", "certifi", "websockets>=12,<14"]
# ///
"""Fermix aimed-click accuracy harness — M28 Phase C1.

Measures the MODEL, not the click pipeline: how well it computes a pixel target
inside a known rect (hit rate + miss vectors, in CSS px and in cell units) and
whether it can tell that its own click fired. The library contracts live in
`bin/aimlib/`; this script is the wiring.

One batch is ONE `fermix ask` turn against the live development daemon. The
managed Chrome is reaped the moment a one-shot turn ends (`gateway/queue.ex:405-424`
tears the browser down instead of pinning a window for the idle TTL), so this
process holds its own CDP client open WHILE the turn runs: that client owns the
window geometry, renders the `READY` token the model is told to wait for, and
reads the page's ground truth as it happens. The turn therefore runs on a worker
thread and the browser is driven from this one.

This drives REAL OS clicks on the live display — the documented deviation from
the VM-only `desktop_input` guidance — so both attestations are mandatory for
every clicking mode, `--calibrate-only` included. Hazards, the hands-off
contract, and the browser-profile accumulation are in `benchmark/README.md` §5c.

Exit: 0 run complete + report written · 2 usage/attestation · 3 preconditions or
calibration failed · 4 run started but incomplete (partial report written).
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import threading
import time
import tomllib
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from aimlib import cdp, page, prompts, score, server, traces  # noqa: E402
from evallib import config as cfgmod  # noqa: E402
from evallib import driver  # noqa: E402

EXIT_OK, EXIT_USAGE, EXIT_PRECONDITION, EXIT_INCOMPLETE = 0, 2, 3, 4

# Constants, not knobs (minimal-knobs rule): the sample size and the geometry are
# what make one run comparable to the next.
DEFAULT_SEED = 12345
TURN_TIMEOUT_MS = 900_000
BROWSER_PROFILE = "fermix_visible"
SUITES = ("s1", "s2", "s3")
# Readback runs for the turn's own budget plus a grace, then fails loud.
POLL_GRACE_S = 30.0
TURN_JOIN_S = TURN_TIMEOUT_MS / 1000.0 + 60.0
# `Trace.record/4` is a cast, so a row can land just after the turn's reply.
TRACE_SETTLE_S = 20.0
TRACE_POLL_S = 1.0
MAX_RUN_DAYS = 2

# Two halt causes, two messages (F9). An extra click that DID land on the page is
# neither of these — it is a counted `extra_click` and the run continues.
HALT_DETAIL = {
    "off_page": "a delivered click produced no page event at all: it landed outside the "
                "fixture page. The run stops rather than inject more clicks into a surface "
                "the harness cannot account for",
    "browser_lost": "a click was delivered after the CDP socket closed — the managed browser "
                    "died mid-batch, so nothing after that point can be attributed",
}

ATTESTATION_HELP = """this run injects REAL OS clicks on the live display, so both attestations
are required (also for --calibrate-only):

  CONFIRM_AIM_LIVE_DISPLAY=1 CONFIRM_AIM_HANDS_OFF=1 make aim

CONFIRM_AIM_LIVE_DISPLAY attests you accept the documented deviation from the
VM-only desktop_input guidance. CONFIRM_AIM_HANDS_OFF attests that for the whole
run the keyboard and mouse stay untouched, macOS Focus/Do-Not-Disturb is ON, and
no channel traffic is expected on this daemon. See benchmark/README.md §5c."""


class HarnessAbort(RuntimeError):
    """A batch could not be run or read at all. Typed by `kind` so the operator
    sees which world broke — never a bare status word."""

    def __init__(self, kind: str, message: str) -> None:
        super().__init__(message)
        self.kind = kind


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


# --- usage + preconditions --------------------------------------------------

def attestation_error(args) -> str | None:
    """Checked before the environment probes: a missing attestation is a USAGE
    error (exit 2) and must read the same whether or not a daemon is running."""
    if args.confirm_live_display and args.confirm_hands_off:
        return None
    return ATTESTATION_HELP


def preconditions(cfg) -> list[str]:
    """Probed in order, each fail-loud with its own fix. Nothing here is retried
    and nothing degrades: a daemon that cannot click cannot be measured."""
    problems = []
    ok, detail = driver.daemon_reachable(cfg)
    if not ok:
        problems.append(f"daemon not reachable (FERMIX_HOME={cfg.daemon.fermix_home}): {detail}")
    return problems + config_problems(cfg.daemon.fermix_home)


def config_problems(fermix_home: str) -> list[str]:
    """File truth about the daemon that will do the clicking: computer use is OFF
    by default (`computer_use/config.ex:75`) and a strict sandbox derives strict
    (look-only) access, which refuses every click (`config.ex:64`,
    `tools/computer_use.ex:384-386`)."""
    path = os.path.join(os.path.realpath(os.path.expanduser(fermix_home)), "config.toml")
    try:
        with open(path, "rb") as handle:
            raw = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        return [f"cannot read the daemon config at {path}: {exc}"]
    computer_use = raw.get("fermix_core", {}).get("computer_use", {})
    mode = raw.get("sandbox", {}).get("mode", "standard")
    problems = []
    if not computer_use.get("enabled"):
        problems.append(f'{path}: set [fermix_core.computer_use] enabled = true — '
                        "computer use is off by default and the harness cannot click")
    if mode == "strict":
        problems.append(f'{path}: [sandbox] mode = "strict" derives look-only computer-use '
                        'access, which refuses every click — use "standard"')
    return problems


# --- one turn ---------------------------------------------------------------

class TurnThread(threading.Thread):
    """`fermix ask` on a worker thread. The driver call blocks for the whole turn
    and the browser must be held open during it, so the two cannot share a thread."""

    def __init__(self, cfg, session: str, prompt: str) -> None:
        super().__init__(name=f"aim-turn-{session}", daemon=True)
        self._cfg, self._session, self._prompt = cfg, session, prompt
        self.result: driver.DriveResult | None = None
        self.error: BaseException | None = None
        self.finished = False

    def run(self) -> None:
        try:
            self.result = driver.drive_query(self._cfg, self._session, self._prompt,
                                             TURN_TIMEOUT_MS)
        except Exception as exc:  # handed to the owning thread below, never swallowed
            self.error = exc
        finally:
            self.finished = True  # written last: a reader seeing True can read the rest


@dataclass
class Observed:
    aim: dict
    samples: list = field(default_factory=list)
    socket_closed_ms: float | None = None
    bounds: dict = field(default_factory=dict)
    multi_client: bool = False
    chrome_version: str = "unknown"


@dataclass
class BatchRun:
    session: str
    reply: str | None
    observed: Observed
    sent_at: datetime


def drive_batch(cfg, plan: page.BatchPlan, url: str, session: str) -> BatchRun:
    """Run one batch turn and come back holding its page-side ground truth."""
    turn = TurnThread(cfg, session, prompts.batch_prompt(plan, url, BROWSER_PROFILE))
    turn.start()
    aborted: HarnessAbort | None = None
    try:
        observed = observe_turn(cfg, plan, turn)
    except HarnessAbort as exc:
        aborted = exc          # re-raised below, once the turn's own reply is readable
    finally:
        # Even on an abort: a turn still clicking while the next batch starts would
        # write its clicks into the next batch's page.
        turn.join(TURN_JOIN_S)
    if aborted is not None:
        raise _diagnosed(aborted, turn) from aborted
    if turn.error is not None:
        raise HarnessAbort("turn_failed", f"driving {session} raised: {turn.error}")
    if turn.is_alive() or turn.result is None:
        raise HarnessAbort("turn_stuck", f"`fermix ask` for {session} never returned")
    if not turn.result.ok:
        raise HarnessAbort("turn_failed",
                           f"`fermix ask` for {session} failed ({turn.result.status}): "
                           f"{turn.result.error}")
    return BatchRun(session=session, reply=turn.result.response, observed=observed,
                    sent_at=turn.result.sent_at)


def _diagnosed(abort: HarnessAbort, turn: TurnThread) -> HarnessAbort:
    """A turn that ended before the page appeared has two very different causes,
    and the model already said which: an `ABORT` reply is its own report that the
    page never reached READY. Give the operator that diagnosis instead of the
    generic one."""
    reply = (turn.result.response or "") if turn.result else ""
    if abort.kind == "turn_ended_early" and reply.strip() == prompts.ABORT_TOKEN:
        return HarnessAbort("handshake_failed",
                            "the model replied ABORT: it reports the fixture page never "
                            "showed READY")
    return abort


def observe_turn(cfg, plan: page.BatchPlan, turn: TurnThread) -> Observed:
    """Own the browser for the life of the turn. A CDP failure is an environment
    condition, not a harness bug, so it becomes a typed abort carrying the
    client's own words — the run then writes its partial report instead of a
    traceback."""
    try:
        return _observe(cfg, plan, turn)
    except cdp.CdpError as exc:
        raise HarnessAbort("cdp_failed", str(exc)) from exc


def _observe(cfg, plan: page.BatchPlan, turn: TurnThread) -> Observed:
    """Find the Chrome the daemon just launched (only one written since this turn
    began counts), attach beside the daemon's own client, fix the window geometry,
    render READY, then read back every 500 ms."""
    profiles_root = os.path.join(cfg.daemon.fermix_home, "browser", "profiles")
    since_ms = time.time() * 1000.0
    sleep = _sleep_while_running(turn)
    port = cdp.discover_port(profiles_root, BROWSER_PROFILE, sleep=sleep, since_ms=since_ms)
    target = cdp.wait_for_target(port, f"batch={plan.batch_id}", sleep=sleep)
    # Read while the browser is certainly alive: it is reaped at turn end.
    chrome = cdp.browser_version(port)
    client = cdp.CdpClient(cdp.browser_websocket_url(port))
    with client:
        session_id = client.attach(target["targetId"])
        bounds = cdp.apply_window_bounds(client, target["targetId"], session_id)
        watcher = cdp.PageWatcher(client, session_id)
        watcher.poll_once()   # a completed readback IS the multi-client assertion
        watcher.set_ready()   # the token the model's `act wait` is blocked on
        readback_loop(watcher, client, turn)
    if watcher.latest is None:
        raise HarnessAbort("no_page_state", f"the fixture page for {plan.batch_id} never "
                                            "reported its state over CDP")
    return Observed(aim=watcher.latest, samples=watcher.samples,
                    socket_closed_ms=client.closed_at_ms, bounds=bounds,
                    multi_client=True, chrome_version=chrome)


def _sleep_while_running(turn: TurnThread):
    """Wait between discovery polls, but never past the turn: once the subprocess
    has returned, whatever we are waiting for is never going to appear."""
    def sleeper(seconds: float) -> None:
        if turn.finished:
            raise HarnessAbort("turn_ended_early",
                               "the turn ended before the fixture page was open — the model "
                               "never opened it, or the daemon refused the browser tool")
        time.sleep(seconds)
    return sleeper


def readback_loop(watcher: cdp.PageWatcher, client: cdp.CdpClient, turn: TurnThread) -> None:
    """500 ms full-state readback plus one focus/visibility/scroll sample per tick
    (F5). Ends on the socket closing — which at turn end is the browser being
    reaped, and earlier is a dead browser `closed_at_ms` will name — or one tick
    after the turn returns, or loudly at the cap."""
    deadline = time.monotonic() + TURN_TIMEOUT_MS / 1000.0 + POLL_GRACE_S
    while time.monotonic() < deadline:
        finished = turn.finished          # read BEFORE the poll: that poll is the last one
        if not _poll_once(watcher, client):
            return
        if finished:
            return
        time.sleep(cdp.POLL_INTERVAL_S)
    raise HarnessAbort("readback_timeout", "the turn outlived the readback budget of "
                                           f"{TURN_TIMEOUT_MS // 1000}s + {POLL_GRACE_S:.0f}s")


def _poll_once(watcher: cdp.PageWatcher, client: cdp.CdpClient) -> bool:
    """False once the socket is gone. A readback failure with the socket still
    open is a real fault and stays an abort — never a quiet skip."""
    try:
        watcher.poll_once()
        return True
    except cdp.CdpError as exc:
        if client.closed_at_ms is None:
            raise HarnessAbort("page_readback_failed", str(exc)) from exc
        return False


# --- one batch, scored ------------------------------------------------------

@dataclass
class Batch:
    run: BatchRun
    rows: list[dict]
    window: tuple[float, float]
    result: dict


def run_batch(cfg, srv: server.AimServer, plan: page.BatchPlan, session: str,
              started: datetime) -> Batch:
    srv.publish(plan.batch_id, page.render_page(plan))
    print(f"[aim] {plan.batch_id}: {plan.probes} probe(s), session {session}")
    run = drive_batch(cfg, plan, srv.url_for(plan.batch_id, plan.mode), session)
    rows, window = turn_rows(cfg, run, trace_dates(started))
    report, report_error = parse_report(run.reply)
    result = score_turn(plan, session, run, rows, report, report_error)
    print(f"       {_outcome_line(result)}")
    return Batch(run=run, rows=rows, window=window, result=result)


def score_turn(plan, session: str, run: BatchRun, rows, report, report_error) -> dict:
    """Scoring reads recorded evidence, so a contradiction in it is an environment
    fault like any other: it becomes a typed abort that still writes the partial
    report, never a traceback that loses every batch already scored."""
    try:
        return score.score_batch(score.BatchInput(
            plan=plan, session=session, rows=rows, aim=run.observed.aim,
            samples=run.observed.samples, socket_closed_ms=run.observed.socket_closed_ms,
            report=report, report_error=report_error))
    except (score.ScoreError, traces.TraceError) as exc:
        raise HarnessAbort("scoring_failed",
                           f"{plan.batch_id} could not be scored: {exc}") from exc


def parse_report(reply: str | None) -> tuple[list[dict] | None, str | None]:
    """The model's self-report, or the reason it is unusable — which score.py
    records as `report_unparseable` (hits still score, the fired column goes
    null). An ABORT reply is different in kind: the page never reached READY, so
    the batch produced no evidence at all."""
    if (reply or "").strip() == prompts.ABORT_TOKEN:
        raise HarnessAbort("handshake_failed",
                           "the model replied ABORT: the fixture page never showed READY")
    try:
        return prompts.parse_model_report(reply), None
    except prompts.ReportError as exc:
        return None, str(exc)


def read_trace_rows(cfg, kind: str, dates: list[str]) -> list[dict]:
    """An unreadable trace directory is an environment condition, so it aborts
    typed rather than ending the run in a stack trace."""
    root = os.path.join(cfg.daemon.fermix_home, "traces")
    try:
        return traces.read_jsonl(root, kind, dates)
    except traces.TraceError as exc:
        raise HarnessAbort("trace_unreadable", str(exc)) from exc


def turn_rows(cfg, run: BatchRun, dates: list[str]) -> tuple[list[dict], tuple[float, float]]:
    """The batch turn's tool rows plus the window they were selected by. The CLI
    `--session` name reaches no trace field — the daemon stamps its own per-turn
    `main-<n>` id (`turn_runner.ex:221`) — so the window from just before
    `fermix ask` launched to now IS the correlation key. `Trace.record/4` is a
    cast (`trace.ex:38`), so give the rows a bounded moment to land; an empty
    answer at the cap is the honest one and `check_trace_visibility` names it."""
    start_ms = run.sent_at.timestamp() * 1000.0
    deadline = time.monotonic() + TRACE_SETTLE_S
    while True:
        end_ms = time.time() * 1000.0
        rows = select_turn_rows(read_trace_rows(cfg, "tool_exec", dates), start_ms, end_ms)
        if rows or time.monotonic() >= deadline:
            return rows, (start_ms, end_ms)
        time.sleep(TRACE_POLL_S)


def select_turn_rows(rows: list[dict], start_ms: float, end_ms: float) -> list[dict]:
    """Two turns' rows inside one window is an unquiesced daemon, not a harness
    bug: nothing in the window can be attributed, so the batch aborts by name."""
    try:
        return traces.rows_for_turn(rows, start_ms, end_ms)
    except traces.TraceError as exc:
        raise HarnessAbort("correlation_ambiguous", str(exc)) from exc


def trace_dates(started: datetime) -> list[str]:
    """The UTC day directories the run's rows can be under (`trace.ex:113,134`).
    A run spanning more days than a measurement run ever legitimately does means
    the clock or the start stamp is wrong — say so instead of scanning a home."""
    first, last = started.date(), now_utc().date()
    if (last - first).days > MAX_RUN_DAYS:
        raise HarnessAbort("run_too_long",
                           f"this run claims to span {first}..{last}; refusing to scan "
                           "the whole trace directory")
    return [(first + timedelta(days=offset)).isoformat()
            for offset in range((last - first).days + 1)]


def _outcome_line(result: dict) -> str:
    counts: dict[str, int] = {}
    for probe in result["probes"]:
        counts[probe["outcome"]] = counts.get(probe["outcome"], 0) + 1
    flags = [name for name, on in result["flags"].items() if on]
    tail = f" flags={','.join(flags)}" if flags else ""
    if result.get("abort_reason"):
        tail += f" abort={result['abort_reason']}"
    return " ".join(f"{name}={count}" for name, count in sorted(counts.items())) + tail


# --- calibration ------------------------------------------------------------

@dataclass
class Calibration:
    checks: list
    batch: Batch

    @property
    def passed(self) -> bool:
        return all(check.passed for check in self.checks)

    def document(self) -> dict:
        return {"passed": self.passed, "session": self.batch.run.session,
                "checks": {c.name: {"passed": c.passed, "detail": c.detail}
                           for c in self.checks}}


def calibrate(cfg, args, run_id: str, srv: server.AimServer, started: datetime) -> Calibration:
    """The run-start assertion list, run as a real turn against the `cal` page.
    Calibration IS the spike: it probes the same world the run works in — a live
    click through the real driver onto the real page — instead of a stand-in."""
    suite, condition, _batches, probes = prompts.CAL_BATCH
    plan = page.plan_batch(args.seed, suite, condition, 1, probes)
    batch = run_batch(cfg, srv, plan, batch_session(run_id, plan), started)
    # F10: two questions with two causes and two fixes — are the run's rows on
    # disk where the harness reads at all, and do they carry `input`.
    trace_checks = [traces.check_trace_visibility(batch.rows, plan.batch_id),
                    traces.check_capture_content(batch.rows, plan.batch_id)]
    try:
        checks = score.calibration_checks(aim=batch.run.observed.aim, batch=batch.result,
                                          bounds=batch.run.observed.bounds,
                                          multi_client=batch.run.observed.multi_client,
                                          trace_checks=trace_checks)
    except (score.ScoreError, traces.TraceError) as exc:
        raise HarnessAbort("calibration_unreadable",
                           f"the calibration turn's own record is unreadable: {exc}") from exc
    return Calibration(checks=checks, batch=batch)


def print_calibration(cal: Calibration) -> None:
    for check in cal.checks:
        mark = "ok  " if check.passed else "FAIL"
        print(f"[cal] {mark} {check.name}: {check.detail}")


# --- run --------------------------------------------------------------------

def batch_session(run_id: str, plan: page.BatchPlan) -> str:
    """`e2e-` prefixed so the behavioral purge convention finds these threads."""
    return f"e2e-{run_id}-{plan.batch_id}"


def selected_batches(args) -> list[tuple[str, str, int, int]]:
    wanted = set(args.suite or SUITES)
    return [entry for entry in prompts.BATCH_PLAN if entry[0] in wanted]


def batch_loop(cfg, args, run_id: str, srv: server.AimServer,
               started: datetime) -> tuple[list[dict], list[tuple[float, float]], dict | None]:
    """Every selected batch, in order. A halt outcome (`off_page`, `browser_lost`)
    stops the run where it stands: both mean the clicks are landing somewhere the
    harness cannot account for, and the answer to that is fewer clicks, not more."""
    results: list[dict] = []
    windows: list[tuple[float, float]] = []
    for plan in batch_plans(args):
        session = batch_session(run_id, plan)
        try:
            batch = run_batch(cfg, srv, plan, session, started)
        except HarnessAbort as abort:
            # Recorded, not swallowed: the reason rides the partial report and the
            # run exits 4.
            return results, windows, _incomplete(abort.kind, str(abort), plan, session)
        results.append(batch.result)
        windows.append(batch.window)
        halt = batch.result["halt_reason"]
        if halt:
            return results, windows, _incomplete(halt, HALT_DETAIL[halt], plan, session)
    return results, windows, None


def batch_plans(args) -> list[page.BatchPlan]:
    return [page.plan_batch(args.seed, suite, condition, number, probes)
            for suite, condition, count, probes in selected_batches(args)
            for number in range(1, count + 1)]


def _incomplete(reason: str, detail: str, plan: page.BatchPlan, session: str) -> dict:
    return {"reason": reason, "detail": detail, "batch": plan.batch_id, "session": session}


def detect_config_id(cfg, args, windows: list[tuple[float, float]],
                     started: datetime) -> tuple[str, str]:
    """Auto-detection reads the same turn windows the tool rows were read by — an
    `llm_call` row carries the daemon's per-turn `main-<n>` id, not the CLI
    session name."""
    if args.config_id:
        return args.config_id, "flag"
    rows = read_trace_rows(cfg, "llm_call", trace_dates(started))
    try:
        detected = traces.detect_config_id(rows, windows)
    except traces.TraceError as exc:
        raise HarnessAbort("trace_unreadable", str(exc)) from exc
    if not detected:
        raise HarnessAbort("config_id_unknown",
                           "no llm_call row inside this run's turns names the model that "
                           "served it — pass --config-id rather than label a report with a guess")
    return detected, "auto"


def environment(cfg, cal: Calibration, dirs_before: int, dirs_after: int) -> dict:
    observed = cal.batch.run.observed
    meta = observed.aim.get("meta") or {}
    return {"fermix_home": cfg.daemon.fermix_home,
            "dpr": meta.get("dpr"), "visual_viewport_scale": meta.get("vv_scale"),
            "screen": [meta.get("screen_w"), meta.get("screen_h")],
            "inner": [meta.get("inner_w"), meta.get("inner_h")],
            "window_bounds": observed.bounds,
            "chrome_version": observed.chrome_version,
            "sent_dims_fullscreen": list(score.full_sent_dims(cal.batch.rows) or []),
            # F11: profile dirs pile up under the daemon's home and NOTHING here
            # deletes them — the count makes the accumulation visible instead.
            "browser_profile_dirs": {"before": dirs_before, "after": dirs_after,
                                     "created": dirs_after - dirs_before}}


def write_reports(out_dir: str, doc: dict) -> None:
    results_path = score.write_results(os.path.join(out_dir, "results.json"), doc)
    report_path = os.path.join(out_dir, "report.md")
    with open(report_path, "w", encoding="utf-8") as handle:
        handle.write(score.render_report(doc))
    print(f"[aim] wrote {results_path}")
    print(f"[aim] wrote {report_path}")


def git_rev() -> str:
    try:
        proc = subprocess.run(["git", "-C", SKILL_DIR, "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    return proc.stdout.strip() if proc.returncode == 0 else "unknown"


def run(cfg, args) -> int:
    started = now_utc()
    run_id = f"aim-{started.strftime('%Y%m%d-%H%M%S')}"
    out_dir = os.path.join(cfg.report_dir, "aim", run_id)
    profiles_root = os.path.join(cfg.daemon.fermix_home, "browser", "profiles")
    dirs_before = cdp.count_profile_dirs(profiles_root)
    srv = server.AimServer()
    port = srv.start()
    print(f"[aim] {run_id} · seed {args.seed} · fixture server on 127.0.0.1:{port}")
    try:
        return run_stages(cfg, args, run_id, out_dir, srv, started, profiles_root, dirs_before)
    finally:
        srv.stop()


def run_stages(cfg, args, run_id: str, out_dir: str, srv: server.AimServer,
               started: datetime, profiles_root: str, dirs_before: int) -> int:
    try:
        cal = calibrate(cfg, args, run_id, srv, started)
    except HarnessAbort as abort:
        print(f"[aim] calibration aborted ({abort.kind}): {abort}", file=sys.stderr)
        return EXIT_PRECONDITION
    print_calibration(cal)
    if not cal.passed:
        print("[aim] calibration failed — the run would measure an unknown world.",
              file=sys.stderr)
        return EXIT_PRECONDITION

    batches: list[dict] = []
    windows = [cal.batch.window]
    incomplete: dict | None = None
    if not args.calibrate_only:
        batches, batch_windows, incomplete = batch_loop(cfg, args, run_id, srv, started)
        windows += batch_windows
    return _finish(cfg, args, run_id, out_dir, started, cal, batches, windows,
                   incomplete, dirs_before, cdp.count_profile_dirs(profiles_root))


def _finish(cfg, args, run_id: str, out_dir: str, started: datetime, cal: Calibration,
            batches: list[dict], windows: list[tuple[float, float]], incomplete: dict | None,
            dirs_before: int, dirs_after: int) -> int:
    # One try over the whole document: a report the harness cannot label or
    # assemble is not written at all, and says which step refused.
    try:
        config_id, source = detect_config_id(cfg, args, windows, started)
        doc = score.build_results(run_id=run_id, seed=args.seed,
                                  started_at=started.isoformat(),
                                  finished_at=now_utc().isoformat(), config_id=config_id,
                                  config_id_source=source, harness_git_rev=git_rev(),
                                  environment=environment(cfg, cal, dirs_before, dirs_after),
                                  calibration=cal.document(), batches=batches,
                                  incomplete=incomplete)
    except (HarnessAbort, score.ScoreError, traces.TraceError) as exc:
        kind = exc.kind if isinstance(exc, HarnessAbort) else "report_unbuildable"
        print(f"[aim] {kind}: {exc}", file=sys.stderr)
        return EXIT_PRECONDITION
    write_reports(out_dir, doc)
    if incomplete:
        print(f"[aim] run incomplete: {incomplete['reason']} at {incomplete['batch']} — "
              "remaining batches were not driven.", file=sys.stderr)
        return EXIT_INCOMPLETE
    return EXIT_OK


# --- entry ------------------------------------------------------------------

def build_args(argv):
    p = argparse.ArgumentParser(description="Fermix aimed-click accuracy harness (M28 C1)")
    p.add_argument("--seed", type=int, default=DEFAULT_SEED,
                   help=f"target-plan seed; reruns are probe-for-probe identical (default {DEFAULT_SEED})")
    p.add_argument("--suite", action="append", choices=SUITES,
                   help="suite to run (repeatable; default all)")
    p.add_argument("--config-id", help="label for the measured config "
                                       "(default: auto-detect from the run's llm_call rows)")
    p.add_argument("--calibrate-only", action="store_true",
                   help="run the calibration turn (one click) and stop")
    p.add_argument("--check", action="store_true",
                   help="preconditions only; drives nothing and clicks nothing")
    p.add_argument("--confirm-live-display", action="store_true",
                   help="attest this run injects real OS clicks on the live display")
    p.add_argument("--confirm-hands-off", action="store_true",
                   help="attest hands off the keyboard/mouse, Do-Not-Disturb on, channels quiet")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = build_args(argv)
    cfg = cfgmod.load(SKILL_DIR)
    if args.check:
        problems = preconditions(cfg)
        if not problems:
            print(f"preconditions: {cfg.daemon.fermix_home} is reachable and may click")
            return EXIT_OK
        print("preconditions:\n  - " + "\n  - ".join(problems))
        return EXIT_PRECONDITION
    usage = attestation_error(args)
    if usage:
        print(usage, file=sys.stderr)
        return EXIT_USAGE
    problems = preconditions(cfg)
    if problems:
        print("preconditions:\n  - " + "\n  - ".join(problems), file=sys.stderr)
        return EXIT_PRECONDITION
    try:
        return run(cfg, args)
    except HarnessAbort as abort:
        print(f"[aim] aborted ({abort.kind}): {abort}", file=sys.stderr)
        return EXIT_INCOMPLETE


if __name__ == "__main__":
    sys.exit(main())
