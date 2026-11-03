#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Snapshot and restore a disposable eval home's seeded state.

`capability-daemon.sh up` takes the snapshot right after seeding, with the daemon
still down, and `capability-daemon.sh reset` stops the daemon, restores it and
starts the daemon again, so each attempt of an isolated companion case
(`run_eval.py --reset-home`) starts from the world the seed made rather than from
what the previous case's model left behind: a watcher it created, a memory
directive it stored.

What is kept is what `seed_capability_home.reset_state` clears (`STATE_DIRS` and
`STATE_FILES`: memory.db with its -wal and -shm, the memory/ tree, skills, job runs,
journals, grants, bootstrap, browser, harness and eval-mcp) plus config.toml. An
entry absent from the snapshot is removed on restore, as the seed left it.
auth.json is not kept: the daemon may rotate an OAuth refresh token in it, and
putting the old one back would sign the eval home out.

  eval_home_state.py snapshot HOME   take it (daemon down; replaces an older one)
  eval_home_state.py restore HOME    put it back (daemon down)
  eval_home_state.py check HOME      refuse unless HOME is a disposable eval home
                                     holding a snapshot; reads nothing else

Every mode first refuses a home that is not disposable, with the seeder's own guard
(`seed_capability_home.disposable_home`: the leaf names eval or e2e, the home is no
symlink, and it is never ~/.fermix, ~/.fermix-dev or ~), before it reads or writes
anything in it.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import seed_capability_home as seed  # noqa: E402
from evallib import safe_rm  # noqa: E402

SNAPSHOT_DIR = "eval-snapshot"
PARTIAL_DIR = "eval-snapshot.partial"
KEPT = seed.STATE_DIRS + seed.STATE_FILES + ("config.toml",)


def down_home(home: str, what: str) -> str:
    """The home as a realpath: disposable, present, and with no daemon answering it.

    memory.db is copied and replaced whole, which is consistent only while nothing
    writes it, so both directions refuse a home a daemon answers."""
    resolved = seed.disposable_home(home, what)
    if not os.path.isdir(resolved):
        seed.die(f"refusing to {what} a home that does not exist: {home}")
    if seed.daemon_answers(resolved):
        seed.die(f"a daemon is answering for {resolved}: stop it before you {what} the "
                 "seeded state, which is consistent only with the daemon down")
    return resolved


def _remove(path: str, home: str) -> None:
    """Remove one kept entry, strictly under the home, never through a symlink."""
    if os.path.islink(path):
        seed.die(f"refusing a symlink among the eval home's kept state: {path}")
    if os.path.isdir(path):
        safe_rm.rm_rf(path, home, min_below=1)
    elif os.path.exists(path):
        os.remove(safe_rm.check(path, home, min_below=1))


def _copy(source: str, dest: str) -> None:
    if os.path.islink(source):
        seed.die(f"refusing a symlink among the eval home's kept state: {source}")
    if os.path.isdir(source):
        shutil.copytree(source, dest, symlinks=True)
    else:
        shutil.copy2(source, dest)


def snapshot(home: str) -> str:
    """Copy the seeded state into `<home>/eval-snapshot`, replacing an older one."""
    resolved = down_home(home, "snapshot")
    if not os.path.isfile(os.path.join(resolved, "config.toml")):
        seed.die(f"no config.toml in {resolved}: snapshot a home the seeder has seeded")
    partial = os.path.join(resolved, PARTIAL_DIR)
    final = os.path.join(resolved, SNAPSHOT_DIR)
    _remove(partial, resolved)
    os.mkdir(partial)
    for name in KEPT:
        source = os.path.join(resolved, name)
        if os.path.lexists(source):
            _copy(source, os.path.join(partial, name))
    _remove(final, resolved)
    os.rename(partial, final)
    return final


def restore(home: str) -> None:
    """Put every kept entry back as the snapshot holds it, and remove the rest."""
    resolved = down_home(home, "restore")
    saved = snapshot_path(resolved)
    for name in KEPT:
        live = os.path.join(resolved, name)
        _remove(live, resolved)
        kept = os.path.join(saved, name)
        if os.path.lexists(kept):
            _copy(kept, live)


def snapshot_path(home: str) -> str:
    """`<home>/eval-snapshot`, refused unless the home is disposable and holds one."""
    resolved = seed.disposable_home(home, "reset")
    saved = os.path.join(resolved, SNAPSHOT_DIR)
    if not os.path.isfile(os.path.join(saved, "config.toml")):
        seed.die(f"no seeded-state snapshot in {resolved}: `capability-daemon.sh up` takes "
                 "one after seeding")
    return saved


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("mode", choices=("snapshot", "restore", "check"))
    parser.add_argument("home")
    args = parser.parse_args(argv)
    if args.mode == "snapshot":
        print(f"snapshot of the seeded state: {snapshot(args.home)}")
    elif args.mode == "restore":
        restore(args.home)
        print(f"restored the seeded state of {seed.disposable_home(args.home, 'restore')}")
    else:
        print(f"seeded-state snapshot: {snapshot_path(args.home)}")


if __name__ == "__main__":
    main()
