#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Repeat the test files a change adds or edits, with every core busy, until one fails.

A flaky test is usually written with its feature and passes that change's CI,
because it fails only a few percent of the time; a month later it fails an
unrelated PR. This runs the change's own test files up to `REPEATS` times under
CPU load (one `yes` per core), so the change that wrote a flaky test is the one
that sees it. Each run is one `mix test` per app, since from the umbrella root
a file path runs only in its own app, and each run draws a fresh seed and
writes its own log, so a step killed mid-run still leaves every finished run on
disk. The load starts when a run's tests start and stops when the run ends:
Mix's start and the app's boot, which every run repeats, take about a minute
under load and a few seconds without it.

Runs go round-robin, every app once per round, so a slow app cannot starve the
rest of their first run under load. `--budget-s` bounds the wall clock from the
first run: an app's next run starts only when its previous run's duration still
fits what is left, and a first run, with nothing measured, starts while any
budget is left. A run already going is never cut short, so the step timeout
must leave room for one. An app the budget stopped short of its count passes
with a notice naming how many runs it had. An app whose first run never started
fails the step: its files were not stressed at all, and that is not a pass.

The base is the commit to diff against: the PR's base SHA, or the push's
`before`. A missing, all-zero or unreachable base skips with a notice, since
there is then no change to name.
"""

from __future__ import annotations

import argparse
import contextlib
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterator

from mix_test_retry import Failure, clean, escape, is_seed_line, is_summary, parse_run, parse_summary, run_teed

REPEATS = 20
MANY_FILES = 30
REPEATS_WHEN_MANY = 5
PASSED = "passed"
FAILED = "failed"
NO_TESTS = "ran no tests"
BUDGET = "budget"
_TEST_FILE = re.compile(r"^apps/(\w+)/test/.+_test\.exs$")


@dataclass
class AppStress:
    app: str
    files: list[str] = field(default_factory=list)
    runs: int = 0
    last_s: float | None = None
    # Empty while the app still repeats; FAILED, NO_TESTS or BUDGET once it stops early.
    stopped: str = ""


def changed_test_files(base: str) -> tuple[list[str], str]:
    """Test files added, modified or renamed since `base`, or why there is nothing to compare."""
    if not base or set(base) == {"0"}:
        return [], "no base commit (a new branch or a manual run)"
    probe = subprocess.run(["git", "cat-file", "-e", f"{base}^{{commit}}"], capture_output=True)
    if probe.returncode != 0:
        return [], f"base {base} is not in this checkout's history (a force push?)"
    diff = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=AMR", base, "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [path for path in diff.stdout.splitlines() if _TEST_FILE.match(path)], ""


def by_app(paths: list[str]) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {}
    for path in sorted(paths):
        match = _TEST_FILE.match(path)
        assert match, f"not an app test file: {path}"
        grouped.setdefault(match.group(1), []).append(path)
    return grouped


def repeats_for(file_count: int) -> int:
    return REPEATS_WHEN_MANY if file_count > MANY_FILES else REPEATS


def tests_ran(text: str) -> int:
    return sum(parse_summary(line)[0] for line in map(clean, text.splitlines()) if is_summary(line))


def fits(last_s: float | None, elapsed_s: float, budget_s: float) -> bool:
    """Whether an app's next run may start: one as long as its previous run must end inside the budget."""
    assert budget_s > 0 and elapsed_s >= 0, (budget_s, elapsed_s)
    if last_s is None:
        return elapsed_s < budget_s
    assert last_s >= 0, last_s
    return elapsed_s + last_s <= budget_s


RunOnce = Callable[[AppStress], str]


def round_robin(
    apps: dict[str, list[str]], repeats: int, budget_s: float, run_once: RunOnce, clock: Callable[[], float]
) -> list[AppStress]:
    """Up to `repeats` rounds, each running every still-repeating app once while its next run fits."""
    assert repeats >= 1 and budget_s > 0, (repeats, budget_s)
    states = [AppStress(app, files) for app, files in apps.items()]
    start = clock()
    for _ in range(repeats):
        for state in [s for s in states if not s.stopped]:
            _take_turn(state, clock() - start, budget_s, run_once, clock)
    return states


def _take_turn(state: AppStress, elapsed_s: float, budget_s: float, run_once: RunOnce, clock: Callable[[], float]):
    if not fits(state.last_s, elapsed_s, budget_s):
        state.stopped = BUDGET
        return
    began = clock()
    outcome = run_once(state)
    state.runs += 1
    state.last_s = clock() - began
    if outcome != PASSED:
        state.stopped = outcome


def failure_annotation(failure: Failure, number: int, seed: str) -> str:
    where = f"{failure.path}:{failure.line}" if failure.path else failure.app
    message = (
        f'{failure.module} {failure.kind} "{failure.name}" ({where}) failed when its file was '
        f"repeated under CPU load (run {number}, seed {seed}). See AGENTS.md, Tests under load."
    )
    props = [f"title={escape('Flaky under load', prop=True)}"]
    if failure.path:
        props = [f"file={escape(failure.path, prop=True)}", f"line={failure.line}", *props]
    return f"::error {','.join(props)}::{escape(message)}"


def run_once(state: AppStress, repeats: int, log_dir: Path) -> str:
    """One `mix test` of the app's files into its own log. A run that executes no test is a visible warning."""
    number = state.runs + 1
    log = log_dir / f"stress-{state.app}-{number}.log"
    command = ["mix", "test", "--warnings-as-errors", "--max-failures", "1", *state.files]
    print(f"\n== {state.app}: {len(state.files)} file(s), run {number} of up to {repeats} under load ==", flush=True)
    with load_from_first_test() as on_line:
        code = run_teed(command, log, on_line)
    text = log.read_text(errors="replace")
    run = parse_run(text, state.app)
    for failure in run.failures:
        print(failure_annotation(failure, number, run.seed), flush=True)
    if code != 0 and not run.failures:
        print(f"::error title=Stress run failed::{escape(state.app)}: exit {code} with no failed test named; see the log", flush=True)
    if code != 0:
        return FAILED
    if tests_ran(text) == 0:
        print(f"::warning title=Stress ran no tests::{escape(state.app)}: {escape(' '.join(state.files))}", flush=True)
        return NO_TESTS
    return PASSED


def describe(state: AppStress, repeats: int) -> str:
    """One summary line: how many runs the app had under load, and why it stopped."""
    if state.stopped == FAILED:
        return f"{state.app}: failed on run {state.runs} of {repeats}"
    if state.stopped == NO_TESTS:
        return f"{state.app}: ran no tests"
    if state.stopped == BUDGET and state.runs == 0:
        return f"{state.app}: never ran; the budget was spent before its first run"
    stopped = ", then the budget stopped it" if state.stopped == BUDGET else ""
    return f"{state.app}: {state.runs} of {repeats} runs passed{stopped}"


def budget_annotation(state: AppStress, repeats: int, budget_s: float) -> str:
    """The annotation for an app the budget stopped short of `repeats`, else empty."""
    if state.stopped != BUDGET:
        return ""
    if state.runs == 0:
        message = (
            f"{state.app} never ran under load: the first runs of the apps before it spent the {budget_s:g} s "
            f"budget, so its {len(state.files)} changed test file(s) were not stressed."
        )
        return f"::error title={escape('Stress budget spent', prop=True)}::{escape(message)}"
    message = (
        f"{state.app}: {state.runs} of {repeats} runs under load passed; another would not fit the "
        f"{budget_s:g} s budget (its last run took {state.last_s:.0f} s)."
    )
    return f"::notice title={escape('Stress budget reached', prop=True)}::{escape(message)}"


def exit_status(states: list[AppStress]) -> int:
    return 1 if any(s.stopped == FAILED or s.runs == 0 for s in states) else 0


def report(states: list[AppStress], repeats: int, budget_s: float, elapsed_s: float) -> int:
    print(f"\n== Stress under load: {elapsed_s:.0f} s of the {budget_s:g} s budget ==", flush=True)
    for state in states:
        print(describe(state, repeats), flush=True)
    for state in states:
        annotation = budget_annotation(state, repeats, budget_s)
        if annotation:
            print(annotation, flush=True)
    return exit_status(states)


def start_burners() -> list[subprocess.Popen]:
    return [subprocess.Popen(["yes"], stdout=subprocess.DEVNULL) for _ in range(os.cpu_count() or 1)]


def stop(burners: list[subprocess.Popen]) -> None:
    for burner in burners:
        burner.kill()
    for burner in burners:
        burner.wait()


@contextlib.contextmanager
def load_from_first_test() -> Iterator[Callable[[str], None]]:
    """A line hook for one run that starts the burners at ExUnit's seed line; they stop when the block exits."""
    burners: list[subprocess.Popen] = []

    def on_line(line: str) -> None:
        if not burners and is_seed_line(line):
            burners.extend(start_burners())

    try:
        yield on_line
    finally:
        stop(burners)


def main(argv: list[str], clock: Callable[[], float] = time.monotonic) -> int:
    args = parse_args(argv)
    files, skipped = changed_test_files(args.base)
    if skipped:
        print(f"::notice title=Stress skipped::{escape(skipped)}", flush=True)
        return 0
    if not files:
        print("No test files changed; nothing to stress.", flush=True)
        return 0
    repeats = repeats_for(len(files))
    args.log_dir.mkdir(parents=True, exist_ok=True)
    start = clock()
    states = round_robin(
        by_app(files), repeats, args.budget_s, lambda state: run_once(state, repeats, args.log_dir), clock
    )
    return report(states, repeats, args.budget_s, clock() - start)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--base", default="", help="commit to diff against (PR base SHA or push `before`)")
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument(
        "--budget-s",
        type=float,
        required=True,
        help="seconds after which no run starts; keep it under the step timeout by the longest run",
    )
    args = parser.parse_args(argv)
    if args.budget_s <= 0:
        parser.error("--budget-s must be positive")
    return args


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
