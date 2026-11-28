#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""The gate before a push: every check of the tree that CI runs and this machine can.

While working, run the tests you touched. Run this once, on the final tree:

    scripts/dev/gate.py            # format, compile, credo, script and harness
                                   # tests, the whole suite, then the TLA+ specs
    scripts/dev/gate.py --force    # run them even if this tree already passed

A pass is remembered by the content of the working tree and the toolchain, so a
later run on the same tree, such as after committing it, skips straight to the
specs. `tla/` is left out of that identity because no other step reads it: a
re-pin after the commit reruns only the specs, whose own saved verdicts make that
take seconds. Only the latest pass is kept.

The suite runs through `scripts/ci/mix_test_retry.py`, as in CI: a few failed
tests rerun once by name, and any that pass are named here as bugs to fix.

Exit status: 0 passed, 1 a step failed, 3 the tree changed while the gate ran, so
the result describes no tree anyone can commit. CI still owns what a single
machine cannot do: the other platforms, the stress run, published-artifact
checksums and the release cross-compiles.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_TEST_DIRS = ("scripts/release", "scripts/ci", "scripts/dev")
SPECS_COMMAND = ("make", "-C", "tla", "check")
LOG_TAIL_LINES = 40
EXIT_FAILED = 1
EXIT_TREE_MOVED = 3

Command = tuple[str, ...]
Execute = Callable[[Command, Path, Path, dict], int]


@dataclass(frozen=True)
class Step:
    name: str
    commands: tuple[Command, ...]
    mix: bool = False


def tree_steps(root: Path, logs: Path) -> tuple[Step, ...]:
    """CI's checks of the tree, cheapest first, so a failure arrives early."""
    return (
        Step("format", (("mix", "format", "--check-formatted"),), mix=True),
        Step("compile", (("mix", "compile", "--warnings-as-errors"),), mix=True),
        Step("credo", (("mix", "credo", "--strict"),), mix=True),
        Step("scripts", script_test_commands(root)),
        Step("benchmark", (("make", "-C", "benchmark", "tests"), ("make", "-C", "benchmark", "dry"))),
        Step("suite", (suite_command(logs),)),
    )


def script_test_commands(root: Path) -> tuple[Command, ...]:
    scripts = [path for directory in SCRIPT_TEST_DIRS for path in sorted((root / directory).glob("test_*.py"))]
    commands: list[Command] = [("uv", "run", str(path.relative_to(root))) for path in scripts]
    return (*commands, ("make", "-C", "tla", "tests"))


def suite_command(logs: Path) -> Command:
    return (
        "uv", "run", "scripts/ci/mix_test_retry.py",
        "--log", str(logs / "mix-test.log"),
        "--flaky-json", str(logs / "flaky.json"),
    )  # fmt: skip


def step_env(mix: bool) -> dict[str, str]:
    """Test config makes its own home, so an exported FERMIX_HOME must not reach a step."""
    env = {key: value for key, value in os.environ.items() if key != "FERMIX_HOME"}
    if mix:
        env["MIX_ENV"] = "test"
    return env


def run_command(command: Command, root: Path, log: Path, env: dict) -> int:
    """Attached, with stdin closed: a port's child would otherwise inherit the caller's."""
    with log.open("a", encoding="utf-8") as sink:
        done = subprocess.run(command, cwd=root, env=env, stdin=subprocess.DEVNULL, stdout=sink, stderr=subprocess.STDOUT)
    return done.returncode


def toolchain() -> str:
    return subprocess.run(["elixir", "--version"], check=True, capture_output=True, text=True).stdout


def tree_key(root: Path) -> str:
    """The working tree's content and the toolchain, through a private index."""
    with tempfile.TemporaryDirectory(prefix="fermix-gate-index-") as tmp:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(tmp) / "index")}
        for args in (("read-tree", "HEAD"), ("add", "-A"), ("rm", "-r", "--cached", "--quiet", "--ignore-unmatch", "tla")):
            subprocess.run(["git", "-C", str(root), *args], env=env, check=True, capture_output=True)
        tree = subprocess.run(
            ["git", "-C", str(root), "write-tree"], env=env, check=True, capture_output=True, text=True
        ).stdout.strip()
    return hashlib.sha256(f"{tree}\0{toolchain()}".encode()).hexdigest()


def receipt_path() -> Path:
    cache = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(cache) / "fermix" / "gate-receipt.json"


def has_receipt(key: str) -> bool:
    path = receipt_path()
    if not path.exists():
        return False
    try:
        return json.loads(path.read_text())["key"] == key
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f"{path} is unreadable ({error}); delete it and re-run") from error


def write_receipt(key: str) -> None:
    path = receipt_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".part")
    try:
        with os.fdopen(fd, "w") as out:
            json.dump({"key": key, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, out)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def log_tail(log: Path) -> str:
    return "\n".join(log.read_text(errors="replace").splitlines()[-LOG_TAIL_LINES:])


def run_step(step: Step, root: Path, logs: Path, execute: Execute) -> bool:
    log = logs / f"{step.name}.log"
    log.touch()
    started = time.monotonic()
    code = next((c for c in (execute(cmd, root, log, step_env(step.mix)) for cmd in step.commands) if c != 0), 0)
    status = "ok  " if code == 0 else "FAIL"
    print(f"  {status} {step.name:<10} {time.monotonic() - started:7.1f}s", flush=True)
    if code != 0:
        print(f"\n{log_tail(log)}\n\nLogs: {logs}", flush=True)
    return code == 0


def report_flaky(logs: Path) -> None:
    path = logs / "flaky.json"
    if not path.exists():
        return
    print("\nThese tests failed, then passed on their rerun. Each is a bug to fix (AGENTS.md, Tests under load):")
    for test in json.loads(path.read_text())["flaky"]:
        print(f"  {test['module']} {test['name']} ({test['path']}:{test['line']})")


def run_tree_steps(root: Path, logs: Path, key: str, execute: Execute) -> int:
    if not all(run_step(step, root, logs, execute) for step in tree_steps(root, logs)):
        return EXIT_FAILED
    report_flaky(logs)
    if tree_key(root) != key:
        print(f"\nThe tree changed during the gate, so this result proves nothing. Gate a stable copy.\nLogs: {logs}")
        return EXIT_TREE_MOVED
    write_receipt(key)
    return 0


def run_specs(root: Path, logs: Path, execute: Execute) -> int:
    if run_step(Step("specs", (SPECS_COMMAND,)), root, logs, execute):
        return 0
    if "STALE" in (logs / "specs.log").read_text(errors="replace"):
        print(
            "\nCommit the change, re-read each STALE spec, run `make -C tla repin SPECS=<spec>`, commit that, "
            "and run this gate again. The rest of its result is kept, so only the specs rerun."
        )
    return EXIT_FAILED


def run_gate(root: Path, force: bool, execute: Execute = run_command) -> int:
    key = tree_key(root)
    logs = Path(tempfile.mkdtemp(prefix="fermix-gate-"))
    if not force and has_receipt(key):
        print("  ok   this tree already passed every step but the specs", flush=True)
    else:
        code = run_tree_steps(root, logs, key, execute)
        if code != 0:
            return code
    code = run_specs(root, logs, execute)
    if code != 0:
        return code
    if (logs / "flaky.json").exists():
        print(f"\nThe first run's failures, to fix them from: Logs: {logs}")
    else:
        shutil.rmtree(logs)
    print("\nGate passed. CI still owns the other platforms, the stress run, checksums and cross-compiles.")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--force", action="store_true", help="run every step even if this tree already passed")
    args = parser.parse_args(argv)
    return run_gate(REPO_ROOT, args.force)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
