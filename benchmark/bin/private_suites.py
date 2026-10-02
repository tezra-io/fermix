#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7"]
# ///
"""Clone or fast-forward the private holdout named in config.yaml, then print its path.

The private holdout is the scored real-use tier: tasks, fixtures and gold answers that
must stay off the public repo, so no agent can search them up and no model trains on
them. `bin/capability-daemon.sh run` (make capability-auto) calls `sync` before seeding,
so a local run always scores the latest private tasks; CI never calls it.

  bin/private_suites.py sync    clone `private_suites.remote` into `private_suites.dir`,
                                or `git pull --ff-only` an existing clone; print the dir

Exit 0 with the dir as the last stdout line; exit 3 with a reason on stderr otherwise.
"""

from __future__ import annotations

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from evallib import config as cfgmod  # noqa: E402


class SyncError(RuntimeError):
    """The holdout could not be brought up to date; the message says why."""


def sync(private) -> str:
    """Bring the configured clone up to date and return its path."""
    if private is None or not private.dir:
        raise SyncError("private_suites.dir is not set in benchmark/config.yaml")
    if os.path.isdir(os.path.join(private.dir, ".git")):
        _git("-C", private.dir, "pull", "--ff-only", "--quiet")
        return private.dir
    if os.path.exists(private.dir):
        raise SyncError(f"{private.dir} exists but is not a git clone; move it aside")
    if not private.remote:
        raise SyncError(f"{private.dir} is missing and private_suites.remote is not set")
    _git("clone", "--quiet", private.remote, private.dir)
    return private.dir


def _git(*args: str) -> None:
    proc = subprocess.run(["git", *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise SyncError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")


def main(argv: list[str]) -> int:
    if argv != ["sync"]:
        print("usage: bin/private_suites.py sync", file=sys.stderr)
        return 2
    cfg = cfgmod.load(os.path.dirname(HERE))
    try:
        print(sync(cfg.private_suites))
    except SyncError as exc:
        print(f"private suites: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
