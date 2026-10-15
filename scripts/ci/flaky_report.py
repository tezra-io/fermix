#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""List the tests CI flagged as flaky, most often first.

`mix_test_retry.py` lets a leg pass when a few failed tests pass on their one
rerun, and leaves a "Flaky test" annotation for each. This reads those
annotations from the last `--runs` CI runs through `gh` and counts them per
test. A test flagged twice or more is the next one to fix (AGENTS.md, Tests
under load); a flag is never a reason to raise a bound.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field

TITLE = "Flaky test"
LEG_JOB = re.compile(r"^compile · format · credo · test \((.+)\)$")
MESSAGE = re.compile(r'^(?P<module>\S+) (?P<kind>\w+) "(?P<name>.*)" \((?P<where>[^)]*)\) failed, then passed on rerun$')


@dataclass
class Row:
    test: str
    where: str
    count: int = 0
    legs: set[str] = field(default_factory=set)
    last_seen: str = ""


def gh_json(path: str) -> dict:
    out = subprocess.run(["gh", "api", path], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def flags_in_run(repo: str, run: dict) -> list[dict]:
    """Every "Flaky test" annotation on the run's test legs, with its leg and date."""
    jobs = gh_json(f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=50")["jobs"]
    flags = []
    for job in jobs:
        leg = LEG_JOB.match(job["name"])
        if not leg:
            continue
        annotations = gh_json(f"repos/{repo}/check-runs/{job['id']}/annotations")
        flags += [
            {"leg": leg.group(1), "date": run["created_at"][:10], "message": a["message"], "path": a["path"]}
            for a in annotations
            if a.get("title") == TITLE
        ]
    return flags


def tally(flags: list[dict]) -> list[Row]:
    rows: dict[str, Row] = {}
    for flag in flags:
        match = MESSAGE.match(flag["message"])
        test = f"{match['module']} {match['name']}" if match else flag["message"]
        where = match["where"] if match else flag["path"]
        row = rows.setdefault(test, Row(test, where))
        row.count += 1
        row.legs.add(flag["leg"])
        row.last_seen = max(row.last_seen, flag["date"])
    return sorted(rows.values(), key=lambda r: (-r.count, r.test))


def render(rows: list[Row], runs: int) -> str:
    if not rows:
        return f"No flaky tests flagged in the last {runs} CI runs."
    lines = [f"Flaky tests flagged in the last {runs} CI runs (fix anything flagged twice first):", ""]
    for row in rows:
        mark = "  FIX NEXT" if row.count >= 2 else ""
        lines.append(f"{row.count:>3}  {row.test}  [{row.where}]  legs: {', '.join(sorted(row.legs))}  last: {row.last_seen}{mark}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--repo", default="tezra-io/fermix")
    parser.add_argument("--runs", type=int, default=60, help="how many recent CI runs to read (max 100)")
    args = parser.parse_args(argv)
    if not 1 <= args.runs <= 100:
        parser.error("--runs must be between 1 and 100")
    runs = gh_json(f"repos/{args.repo}/actions/workflows/ci.yml/runs?per_page={args.runs}")["workflow_runs"]
    finished = [run for run in runs if run.get("conclusion") in ("success", "failure")]
    flags = [flag for run in finished for flag in flags_in_run(args.repo, run)]
    print(render(tally(flags), len(runs)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
