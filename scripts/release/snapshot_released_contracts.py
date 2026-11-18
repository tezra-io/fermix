#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Snapshot the wire contracts a release's apps were built against.

`test/released_contracts/<tag>/` holds, byte for byte as the tag published
them under `apps/fermix_core/priv/`, each protocol's schema and the golden
fixtures the released-contract tests read (`FermixTestSupport.ReleasedContracts`):
those tests hold every later engine to them, so an app that has not updated
keeps working. `SOURCE.json` beside them records the tag, its commit and each
file's SHA-256, which the tests check the files against.

A snapshot is written once, from the tag itself, never from a working tree:
the script refuses a name that is not a release tag, a tag that does not
exist, a snapshot that already exists, and a tag missing any of the files.
Deleting a snapshot is how a release stops being served; it is never
rewritten.

Usage:
  snapshot_released_contracts.py --tag vX.Y.Z [--repo PATH]

Every git call goes through `runner`, so a test drives it against a
throwaway repository.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

PRIV = "apps/fermix_core/priv"
SNAPSHOTS = "test/released_contracts"

# What the released-contract tests read, by path under `priv/`.
FILES = (
    "management/protocol.schema.json",
    "management/fixtures/requests.jsonl",
    "management/fixtures/success.jsonl",
    "management/fixtures/errors.jsonl",
    "realtime/protocol.schema.json",
    "realtime/fixtures/client_events.jsonl",
    "realtime/fixtures/server_events.jsonl",
    "mobile/protocol.schema.json",
    "mobile/fixtures/client_events.jsonl",
    "mobile/fixtures/client_binary_frames.jsonl",
    "mobile/fixtures/server_events.jsonl",
    "mobile/fixtures/server_binary_frames.jsonl",
)

RELEASE_TAG = re.compile(r"^v\d+\.\d+\.\d+$")


class Refused(Exception):
    """A snapshot this script will not write, with the reason."""


def git(runner, repo: Path, *args: str) -> bytes:
    result = runner(["git", "-C", str(repo), *args], capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        raise Refused(f"git {' '.join(args)} failed: {detail}")
    return result.stdout


def blob(runner, repo: Path, tag: str, path: str) -> bytes:
    try:
        return git(runner, repo, "show", f"{tag}:{PRIV}/{path}")
    except Refused as refusal:
        raise Refused(f"{tag} has no {PRIV}/{path}") from refusal


def snapshot(tag: str, repo: Path, runner=subprocess.run) -> Path:
    """Writes the tag's snapshot and returns its directory."""

    if not RELEASE_TAG.match(tag):
        raise Refused(f"{tag!r} is not a release tag (vMAJOR.MINOR.PATCH)")

    try:
        commit = git(runner, repo, "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
    except Refused as refusal:
        raise Refused(f"no tag {tag} in {repo}") from refusal

    dest = repo / SNAPSHOTS / tag
    if dest.exists():
        raise Refused(f"{dest} exists: a snapshot is written once, from its tag")

    blobs = {path: blob(runner, repo, tag, path) for path in FILES}

    for path, data in blobs.items():
        target = dest / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    source = {
        "tag": tag,
        "commit": commit.decode().strip(),
        "files": [
            {"path": path, "sha256": hashlib.sha256(blobs[path]).hexdigest()}
            for path in sorted(FILES)
        ],
    }
    (dest / "SOURCE.json").write_text(json.dumps(source, indent=2) + "\n")
    return dest


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)

    try:
        dest = snapshot(args.tag, args.repo)
    except Refused as refusal:
        print(f"snapshot_released_contracts: {refusal}", file=sys.stderr)
        return 1

    print(f"wrote {dest.relative_to(args.repo)} ({len(FILES)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
