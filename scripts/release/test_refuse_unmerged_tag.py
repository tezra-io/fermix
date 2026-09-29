#!/usr/bin/env python3
"""Hermetic tests for the guard that refuses a release tag off main."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("refuse_unmerged_tag.sh")


class RefuseUnmergedTagTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-tag-guard-")
        self.base = Path(self.tmp.name)
        self.environment = self._git_environment()
        self.origin = self.base / "origin.git"
        self._seed_origin()

    def tearDown(self):
        self.tmp.cleanup()

    def test_allows_the_merge_commit_at_the_tip_of_main(self):
        result = self._run(self._clone(), self.main_tip)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is on main", result.stdout)

    def test_allows_an_earlier_commit_of_main(self):
        # A tag pushed after later merges still names a commit main contains.
        result = self._run(self._clone(), self.main_first)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_refuses_a_commit_that_only_a_side_branch_contains(self):
        result = self._run(self._clone(), self.side_tip)

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{self.side_tip} is not on main", result.stderr)
        self.assertIn("tag its merge commit", result.stderr)

    def test_refuses_a_shallow_checkout_instead_of_guessing(self):
        result = self._run(self._clone("--depth", "1"), self.main_tip)

        self.assertEqual(result.returncode, 1)
        self.assertIn("fetch-depth: 0", result.stderr)

    def test_refuses_a_checkout_without_main(self):
        checkout = self._clone("--single-branch", "--branch", "side")

        result = self._run(checkout, self.side_tip)

        self.assertEqual(result.returncode, 1)
        self.assertIn("no refs/remotes/origin/main", result.stderr)

    def test_refuses_a_commit_the_checkout_does_not_have(self):
        result = self._run(self._clone(), "0" * 40)

        self.assertEqual(result.returncode, 1)
        self.assertIn("is not in the checkout", result.stderr)

    def test_rejects_an_argument_that_is_not_a_commit_sha(self):
        result = self._run(self._clone(), "v0.11.0")

        self.assertEqual(result.returncode, 1)
        self.assertIn("full commit SHA", result.stderr)

    def test_rejects_missing_arguments(self):
        result = subprocess.run(
            [str(SCRIPT)],
            cwd=self._clone(),
            env=self.environment,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)

    def _seed_origin(self):
        seed = self.base / "seed"
        self._git(self.base, "init", "--quiet", "--bare", "-b", "main", str(self.origin))
        self._git(self.base, "init", "--quiet", "-b", "main", str(seed))
        self.main_first = self._commit(seed, "first")
        self._git(seed, "checkout", "--quiet", "-b", "side")
        self.side_tip = self._commit(seed, "side only")
        self._git(seed, "checkout", "--quiet", "main")
        self.main_tip = self._commit(seed, "release merge")
        self._git(seed, "push", "--quiet", str(self.origin), "main", "side")

    def _clone(self, *options):
        checkout = Path(tempfile.mkdtemp(prefix="checkout-", dir=self.base))
        self._git(self.base, "clone", "--quiet", *options, f"file://{self.origin}", str(checkout))
        return checkout

    def _commit(self, repository, message):
        self._git(repository, "commit", "--quiet", "--allow-empty", "-m", message)
        return self._git(repository, "rev-parse", "HEAD").stdout.strip()

    def _git(self, cwd, *arguments):
        return subprocess.run(
            ["git", *arguments],
            cwd=cwd,
            env=self.environment,
            text=True,
            capture_output=True,
            check=True,
        )

    def _run(self, checkout, commit):
        return subprocess.run(
            [str(SCRIPT), commit],
            cwd=checkout,
            env=self.environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def _git_environment(self):
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(self.base),
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
