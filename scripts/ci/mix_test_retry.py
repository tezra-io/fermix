#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run the umbrella suite; rerun a few failed tests once and flag them as flaky.

The first run is the ordinary `mix test --warnings-as-errors`. When it fails
with at most `--max-flaky` failed tests and nothing else wrong, each app that
had failures reruns only those tests (`mix do --app <app> test --failed`). If
every rerun passes and ran at least as many tests as failed, the failures are
flaky: each one becomes a `::warning` annotation titled "Flaky test", a row in
the job summary and an entry in the flaky JSON, and the step passes.

Everything else stays red: a suite that aborted (warnings, compile errors), an
app whose suite never printed its summary, more failures than the cap, a rerun
that fails again, and a rerun that ran fewer tests than failed. `mix test
--failed` from the umbrella root runs zero tests and exits 0 whatever its
apps' manifests hold, so the rerun is per app and its test count is checked.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

MAX_FLAKY_DEFAULT = 5
ANNOTATION_TITLE = "Flaky test"

_PREFIX = re.compile(r"^(\d{4}-\d\d-\d\dT[\d:.]+Z )?(##\[(error|warning)\])?")
_SECTION = re.compile(r"^==> (\w+)\s*$")
_SEED = re.compile(r"Running ExUnit with seed: (\d+)")
_SUMMARY = re.compile(r"\b\d+ (?:doctests?|propert(?:y|ies)|tests?), .*\b\d+ failures?\b")
_COUNT = re.compile(r"(\d+) (doctests?|properties|property|tests?|failures?|invalid)\b")
_HEADER = re.compile(r"^\s+\d+\) (test|doctest|property) (.+) \(([\w.]+)\)\s*$")
_LOCATION = re.compile(r"^\s+((?:apps/\w+/)?test/\S+\.exs):(\d+)\s*$")
_ABORTED = (
    "Test suite aborted",
    "== Compilation error",
    "(CompileError)",
    "(SyntaxError)",
)


@dataclass
class Failure:
    app: str
    kind: str
    name: str
    module: str
    path: str = ""
    line: int = 0


@dataclass
class AppRun:
    started: bool = False
    ran: int | None = None
    failed: int = 0


@dataclass
class Run:
    apps: dict[str, AppRun] = field(default_factory=dict)
    failures: list[Failure] = field(default_factory=list)
    aborted: str = ""
    seed: str = ""


def is_summary(line: str) -> bool:
    return bool(_SUMMARY.search(line))


def clean(line: str) -> str:
    return _PREFIX.sub("", line.rstrip("\n"), count=1)


def parse_summary(line: str) -> tuple[int, int]:
    """Tests that ran and tests that failed, from one ExUnit summary line."""
    ran = failed = 0
    for number, word in _COUNT.findall(line):
        if word.startswith(("failure", "invalid")):
            failed += int(number)
        else:
            ran += int(number)
    return ran, failed


def parse_run(text: str, app: str = "") -> Run:
    """Read one `mix test` log. `app` names the app when the log has no `==>` header."""
    run = Run()
    current = app
    pending: Failure | None = None
    for raw in text.splitlines():
        line = clean(raw)
        current, pending = _read_line(run, line, current, pending)
    return run


def _read_line(run: Run, line: str, current: str, pending: Failure | None):
    section = _SECTION.match(line)
    if section:
        return section.group(1), None
    if any(marker in line for marker in _ABORTED) and not run.aborted:
        run.aborted = line.strip()
    seed = _SEED.search(line)
    if seed:
        run.seed = run.seed or seed.group(1)
        run.apps.setdefault(current, AppRun()).started = True
        return current, None
    if _SUMMARY.search(line):
        ran, failed = parse_summary(line)
        app_run = run.apps.setdefault(current, AppRun())
        app_run.ran, app_run.failed = ran, failed
        return current, None
    return current, _read_failure(run, line, current, pending)


def _read_failure(run: Run, line: str, current: str, pending: Failure | None):
    header = _HEADER.match(line)
    if header:
        failure = Failure(current, header.group(1), header.group(2), header.group(3))
        run.failures.append(failure)
        return failure
    location = _LOCATION.match(line)
    if pending is not None and location:
        path = location.group(1)
        pending.path = path if path.startswith("apps/") else f"apps/{pending.app}/{path}"
        pending.line = int(location.group(2))
        return None
    return pending


def plan_retry(run: Run, max_flaky: int) -> tuple[dict[str, int], str]:
    """Apps to rerun with their failed counts, or a reason the failure stays red."""
    if run.aborted:
        return {}, f"the suite aborted: {run.aborted}"
    unfinished = sorted(app for app, a in run.apps.items() if a.started and a.ran is None)
    if unfinished:
        return {}, f"no ExUnit summary for {', '.join(unfinished)}: the suite did not finish"
    failed = {app: a.failed for app, a in run.apps.items() if a.failed > 0}
    total = sum(failed.values())
    if total == 0:
        return {}, "mix test failed with no failed tests, so there is nothing to rerun"
    if total > max_flaky:
        return {}, f"{total} tests failed; more than {max_flaky} is not treated as flaky"
    if not run.failures:
        return {}, "tests failed but no failure was named in the log"
    return failed, ""


def check_rerun(app: str, expected: int, rerun: Run, code: int) -> str:
    """Empty when the rerun proves the failures flaky, else why it does not."""
    app_run = rerun.apps.get(app)
    if code != 0:
        return f"{app}: the rerun failed again (exit {code})"
    if app_run is None or app_run.ran is None:
        return f"{app}: the rerun printed no ExUnit summary"
    if app_run.failed:
        return f"{app}: {app_run.failed} tests failed on the rerun"
    if app_run.ran < expected:
        return f"{app}: the rerun ran {app_run.ran} tests for {expected} failures"
    return ""


def escape(value: str, prop: bool = False) -> str:
    value = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return value.replace(":", "%3A").replace(",", "%2C") if prop else value


def annotation(failure: Failure) -> str:
    where = f"{failure.path}:{failure.line}" if failure.path else failure.app
    message = f'{failure.module} {failure.kind} "{failure.name}" ({where}) failed, then passed on rerun'
    props = [f"title={escape(ANNOTATION_TITLE, prop=True)}"]
    if failure.path:
        props = [f"file={escape(failure.path, prop=True)}", f"line={failure.line}", *props]
    return f"::warning {','.join(props)}::{escape(message)}"


def summary_markdown(failures: list[Failure], seed: str) -> str:
    rows = [f"| `{f.module}` | {f.name} | `{f.path}:{f.line}` |" for f in failures]
    return "\n".join(
        [
            f"### {len(failures)} flaky test(s): failed, then passed on rerun (seed {seed})",
            "",
            "| Module | Test | Location |",
            "|---|---|---|",
            *rows,
            "",
        ]
    )


Runner = Callable[[list[str], Path], int]


def run_teed(command: list[str], log: Path) -> int:
    """Run `command` with MIX_ENV=test, streaming its output to stdout and `log`."""
    env = {**os.environ, "MIX_ENV": "test"}
    with log.open("w", encoding="utf-8") as sink:
        proc = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, text=True, errors="replace"
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            sys.stdout.write(line)
            sink.write(line)
        sys.stdout.flush()
        return proc.wait()


def clear_failure_manifests(root: Path) -> None:
    """A restored `_build` cache carries old manifests; `--failed` must see this run only."""
    for manifest in glob.glob(str(root / "_build/test/lib/*/.mix/.mix_test_failures")):
        os.remove(manifest)


def retry_failures(failed: dict[str, int], log: Path, runner: Runner) -> str:
    for app, expected in sorted(failed.items()):
        rerun_log = log.with_name(f"{log.stem}-rerun-{app}{log.suffix}")
        print(f"\n== Rerunning the {expected} failed test(s) in {app} once ==", flush=True)
        code = runner(["mix", "do", "--app", app, "test", "--warnings-as-errors", "--failed"], rerun_log)
        reason = check_rerun(app, expected, parse_run(rerun_log.read_text(errors="replace"), app), code)
        if reason:
            return reason
    return ""


def report_flaky(run: Run, flaky_json: Path | None) -> None:
    for failure in run.failures:
        print(annotation(failure), flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(summary_markdown(run.failures, run.seed))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as out:
            out.write("flaky=true\n")
    if flaky_json is not None:
        entries = [f.__dict__ for f in run.failures]
        flaky_json.write_text(json.dumps({"seed": run.seed, "flaky": entries}, indent=2) + "\n")


def main(argv: list[str], runner: Runner = run_teed, root: Path = Path(".")) -> int:
    args = parse_args(argv)
    clear_failure_manifests(root)
    code = runner(["mix", "test", "--warnings-as-errors", *args.mix_args], args.log)
    if code == 0:
        return 0
    first = parse_run(args.log.read_text(errors="replace"))
    failed, refusal = plan_retry(first, args.max_flaky)
    if refusal:
        print(f"\nNot retried: {refusal}.", flush=True)
        return code
    reason = retry_failures(failed, args.log, runner)
    if reason:
        print(f"\nNot flaky: {reason}.", flush=True)
        return 1
    report_flaky(first, args.flaky_json)
    print(f"\n{len(first.failures)} flaky test(s) passed on rerun; see the annotations.", flush=True)
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--log", type=Path, required=True, help="where the first run's output goes")
    parser.add_argument("--flaky-json", type=Path, help="where to write the flaky tests, if any")
    parser.add_argument("--max-flaky", type=int, default=MAX_FLAKY_DEFAULT)
    parser.add_argument("mix_args", nargs="*", help="extra `mix test` arguments, after --")
    args = parser.parse_args(argv)
    if args.max_flaky < 1:
        parser.error("--max-flaky must be at least 1")
    return args


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
