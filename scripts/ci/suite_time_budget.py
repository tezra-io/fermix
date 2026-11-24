#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fail when an app's suite outgrows its time budget.

The suite grew from about four minutes to over twenty in one month without any
check noticing. Each app's budget is the wall time of its ExUnit run ("Finished
in N seconds") on CI's linux-x64 leg, the one leg that runs the whole suite in
one VM, so it is measured on the same runner every time. Hosted runners vary,
so each budget leaves room above what the app takes today; a run over it is a
real regression, not noise.

An app missing from the log, or from the budget, fails too: the first means its
suite never finished, the second that it has no budget yet.

    scripts/ci/suite_time_budget.py --log mix-test.log --budget test/suite_time_budget.toml
"""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path

from mix_test_retry import clean, escape

_SECTION = re.compile(r"^==> (\w+)\s*$")
_FINISHED = re.compile(r"^Finished in ([\d.]+) seconds\b")
LOWER_BELOW = 0.5


def finished_seconds(text: str) -> dict[str, float]:
    """Each app's ExUnit wall time, from an umbrella `mix test` log."""
    seconds: dict[str, float] = {}
    app = ""
    for line in map(clean, text.splitlines()):
        section = _SECTION.match(line)
        if section:
            app = section.group(1)
        finished = _FINISHED.match(line.strip())
        if finished:
            seconds[app] = float(finished.group(1))
    return seconds


def read_budget(path: Path) -> dict[str, float]:
    budget = tomllib.loads(path.read_text(encoding="utf-8")).get("seconds")
    if not isinstance(budget, dict) or not budget:
        raise ValueError(f"{path} has no [seconds] table")
    bad = [app for app, value in budget.items() if not isinstance(value, (int, float)) or value <= 0]
    if bad:
        raise ValueError(f"{path}: every budget is a positive number of seconds; not {', '.join(bad)}")
    return {app: float(value) for app, value in budget.items()}


def verdicts(seconds: dict[str, float], budget: dict[str, float], budget_path: str) -> tuple[list[str], list[str]]:
    """Errors that fail the step, and notices that ask for a lower budget."""
    errors, notices = [], []
    for app in sorted(budget.keys() - seconds.keys()):
        errors.append(f"{app} printed no ExUnit finish line, so its time was not measured")
    for app in sorted(seconds.keys() - budget.keys()):
        errors.append(f"{app} has no budget in {budget_path}; add one")
    for app in sorted(seconds.keys() & budget.keys()):
        took, allowed = seconds[app], budget[app]
        if took > allowed:
            errors.append(
                f"{app} took {took:.0f} s, over its {allowed:.0f} s budget. Find what grew and make it cheaper; "
                f"raise the budget in {budget_path} only with the reason, in the same change"
            )
        elif took < allowed * LOWER_BELOW:
            notices.append(f"{app} took {took:.0f} s of its {allowed:.0f} s budget; lower it in {budget_path}")
    return errors, notices


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--log", type=Path, required=True, help="the first run's `mix test` log")
    parser.add_argument("--budget", type=Path, required=True)
    args = parser.parse_args(argv)
    seconds = finished_seconds(args.log.read_text(errors="replace"))
    errors, notices = verdicts(seconds, read_budget(args.budget), str(args.budget))
    for app, took in sorted(seconds.items()):
        print(f"{app}: {took:.1f} s", flush=True)
    for notice in notices:
        print(f"::notice title=Suite under its time budget::{escape(notice)}", flush=True)
    for error in errors:
        print(f"::error title=Suite over its time budget::{escape(error)}", flush=True)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
