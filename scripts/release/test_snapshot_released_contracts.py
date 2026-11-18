#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for snapshot_released_contracts.

Each test builds a throwaway repository with its own git configuration, so
nothing reads the developer's or the runner's. Run with:
  uv run scripts/release/test_snapshot_released_contracts.py
"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import snapshot_released_contracts as snap  # noqa: E402

TAG = "v1.2.3"


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-released-contracts-")
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        self.environment = self._git_environment()
        self._git("init", "--quiet", "-b", "main")

    def test_writes_the_tag_s_bytes_and_records_them(self):
        tagged = self._commit_contracts("tagged")
        self._git("tag", TAG)
        # A later edit and commit are not the release's.
        self._commit_contracts("after the tag")

        dest = snap.snapshot(TAG, self.repo, runner=self._runner)

        self.assertEqual(dest, self.repo / snap.SNAPSHOTS / TAG)
        source = json.loads((dest / "SOURCE.json").read_text())
        self.assertEqual(source["tag"], TAG)
        self.assertEqual(source["commit"], tagged)
        self.assertEqual([f["path"] for f in source["files"]], sorted(snap.FILES))

        for record in source["files"]:
            data = (dest / record["path"]).read_bytes()
            self.assertEqual(data, self._contents(record["path"], "tagged"))
            self.assertEqual(record["sha256"], hashlib.sha256(data).hexdigest())

    def test_refuses_a_name_that_is_not_a_release_tag(self):
        self._commit_contracts("tagged")
        self._git("tag", "nightly")

        with self.assertRaisesRegex(snap.Refused, "not a release tag"):
            snap.snapshot("nightly", self.repo, runner=self._runner)

    def test_refuses_a_branch_named_like_a_tag(self):
        self._commit_contracts("tagged")
        self._git("branch", TAG)

        with self.assertRaisesRegex(snap.Refused, f"no tag {TAG}"):
            snap.snapshot(TAG, self.repo, runner=self._runner)

        self.assertFalse((self.repo / snap.SNAPSHOTS).exists())

    def test_refuses_a_snapshot_that_exists_and_leaves_it(self):
        self._commit_contracts("tagged")
        self._git("tag", TAG)
        existing = self.repo / snap.SNAPSHOTS / TAG / "SOURCE.json"
        existing.parent.mkdir(parents=True)
        existing.write_text("kept\n")

        with self.assertRaisesRegex(snap.Refused, "written once"):
            snap.snapshot(TAG, self.repo, runner=self._runner)

        self.assertEqual(existing.read_text(), "kept\n")

    def test_refuses_a_tag_missing_a_file_and_writes_nothing(self):
        self._commit_contracts("tagged", leave_out=snap.FILES[-1])
        self._git("tag", TAG)

        with self.assertRaisesRegex(snap.Refused, f"{TAG} has no .*{snap.FILES[-1]}"):
            snap.snapshot(TAG, self.repo, runner=self._runner)

        self.assertFalse((self.repo / snap.SNAPSHOTS / TAG).exists())

    def test_main_reports_a_refusal_and_exits_non_zero(self):
        self.assertEqual(snap.main(["--tag", "1.2.3", "--repo", str(self.repo)]), 1)

    # One commit writing every contract file with contents that name `label`.
    def _commit_contracts(self, label, leave_out=None):
        for path in snap.FILES:
            if path == leave_out:
                continue
            target = self.repo / snap.PRIV / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(self._contents(path, label))

        self._git("add", "--all")
        self._git("commit", "--quiet", "-m", label)
        return self._git("rev-parse", "HEAD").stdout.strip()

    @staticmethod
    def _contents(path, label):
        return f'{{"file": "{path}", "label": "{label}"}}\n'.encode()

    def _runner(self, command, **options):
        return subprocess.run(command, cwd=self.repo, env=self.environment, check=False, **options)

    # Every call names the throwaway repository and runs inside it, and git may
    # not look above the temporary directory, so no test reaches a real one.
    def _git(self, *arguments):
        return subprocess.run(
            ["git", "-C", str(self.repo), *arguments],
            cwd=self.repo,
            env=self.environment,
            text=True,
            capture_output=True,
            check=True,
        )

    def _git_environment(self):
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": self.tmp.name,
                "GIT_CEILING_DIRECTORIES": self.tmp.name,
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_AUTHOR_NAME": "Release Test",
                "GIT_AUTHOR_EMAIL": "release-test@example.invalid",
                "GIT_COMMITTER_NAME": "Release Test",
                "GIT_COMMITTER_EMAIL": "release-test@example.invalid",
            }
        )
        return environment


if __name__ == "__main__":
    unittest.main()
