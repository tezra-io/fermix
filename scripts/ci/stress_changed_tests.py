#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Repeat the test files a change adds or edits, with every core busy, until one fails.

A flaky test is usually written with its feature and passes that change's CI,
because it fails only a few percent of the time; a month later it fails an
unrelated PR. This runs the change's own test files `REPEATS` times under CPU
load (one `yes` per core), so the change that wrote a flaky test is the one
that sees it. One `mix test` per app: from the umbrella root a file path runs
only in its own app, and each invocation's repeats draw fresh seeds.

The base is the commit to diff against: the PR's base SHA, or the push's
`before`. A missing, all-zero or unreachable base skips with a notice, since
there is then no change to name.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

from mix_test_retry import Failure, clean, escape, is_summary, parse_run, parse_summary, run_teed

REPEATS = 20
MANY_FILES = 30
REPEATS_WHEN_MANY = 5
_TEST_FILE = re.compile(r"^apps/(\w+)/test/.+_test\.exs$")


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


def failure_annotation(failure: Failure, seed: str) -> str:
    where = f"{failure.path}:{failure.line}" if failure.path else failure.app
    message = (
        f'{failure.module} {failure.kind} "{failure.name}" ({where}) failed when its file was '
        f"repeated under CPU load (seed {seed}). See AGENTS.md, Tests under load."
    )
    props = [f"title={escape('Flaky under load', prop=True)}"]
    if failure.path:
        props = [f"file={escape(failure.path, prop=True)}", f"line={failure.line}", *props]
    return f"::error {','.join(props)}::{escape(message)}"


def stress_app(app: str, files: list[str], repeats: int, log: Path) -> bool:
    """True when every repeat passed. A run that executes no test is a visible warning."""
    command = ["mix", "test", "--warnings-as-errors", "--max-failures", "1", "--repeat-until-failure", str(repeats), *files]
    print(f"\n== {app}: {len(files)} file(s), up to {repeats} repeats under load ==", flush=True)
    code = run_teed(command, log)
    text = log.read_text(errors="replace")
    run = parse_run(text, app)
    for failure in run.failures:
        print(failure_annotation(failure, run.seed), flush=True)
    if code != 0 and not run.failures:
        print(f"::error title=Stress run failed::{escape(app)}: exit {code} with no failed test named; see the log", flush=True)
    if code == 0 and tests_ran(text) == 0:
        print(f"::warning title=Stress ran no tests::{escape(app)}: {escape(' '.join(files))}", flush=True)
    return code == 0


def start_burners() -> list[subprocess.Popen]:
    return [subprocess.Popen(["yes"], stdout=subprocess.DEVNULL) for _ in range(os.cpu_count() or 1)]


def stop(burners: list[subprocess.Popen]) -> None:
    for burner in burners:
        burner.kill()
    for burner in burners:
        burner.wait()


def main(argv: list[str]) -> int:
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
    burners = start_burners()
    try:
        results = [stress_app(app, paths, repeats, args.log_dir / f"stress-{app}.log") for app, paths in by_app(files).items()]
    finally:
        stop(burners)
    return 0 if all(results) else 1


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--base", default="", help="commit to diff against (PR base SHA or push `before`)")
    parser.add_argument("--log-dir", type=Path, required=True)
    return parser.parse_args(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
