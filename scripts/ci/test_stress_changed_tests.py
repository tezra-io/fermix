#!/usr/bin/env python3
"""Hermetic tests for stressing the test files a change touches."""

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))

import stress_changed_tests as stress  # noqa: E402

REPEATED_GREEN = """\
==> fermix_core
Running ExUnit with seed: 11, max_cases: 8
3 tests, 0 failures
Running ExUnit with seed: 12, max_cases: 8
3 tests, 0 failures
"""

FAILED_ON_REPEAT = """\
==> fermix_core
Running ExUnit with seed: 11, max_cases: 8
3 tests, 0 failures
Running ExUnit with seed: 12, max_cases: 8

  1) test flushes after the debounce (FermixCore.FooTest)
     apps/fermix_core/test/fermix_core/foo_test.exs:42

3 tests, 1 failure
"""


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


class ChangedTestFilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-stress-")
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "ci@example.invalid")
        git(self.repo, "config", "user.name", "ci")
        self.write("apps/fermix_core/test/fermix_core/kept_test.exs")
        self.write("apps/fermix_core/test/fermix_core/gone_test.exs")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "base")
        self.base = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=self.repo, capture_output=True, text=True, check=True
        ).stdout.strip()
        self.cwd = os.getcwd()
        os.chdir(self.repo)

    def tearDown(self):
        os.chdir(self.cwd)
        self.tmp.cleanup()

    def write(self, rel, text=None):
        # Distinct content per file: identical files let git report a delete
        # plus an add as one rename, and the delete would never be seen.
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text if text is not None else f"{rel}\n")

    def test_names_added_and_edited_test_files_but_not_deleted_ones_or_other_files(self):
        self.write("apps/fermix_core/test/fermix_core/kept_test.exs", "changed\n")
        self.write("apps/fermix_channels/test/fermix_channels/new_test.exs")
        self.write("apps/fermix_core/lib/fermix_core/thing.ex")
        self.write("apps/fermix_core/test/support/helper.ex")
        (self.repo / "apps/fermix_core/test/fermix_core/gone_test.exs").unlink()
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "change")

        files, skipped = stress.changed_test_files(self.base)

        self.assertEqual(skipped, "")
        self.assertEqual(
            sorted(files),
            [
                "apps/fermix_channels/test/fermix_channels/new_test.exs",
                "apps/fermix_core/test/fermix_core/kept_test.exs",
            ],
        )

    def test_an_all_zero_base_is_skipped_with_a_reason(self):
        files, skipped = stress.changed_test_files("0" * 40)

        self.assertEqual(files, [])
        self.assertIn("no base commit", skipped)

    def test_a_base_outside_the_history_is_skipped_with_a_reason(self):
        files, skipped = stress.changed_test_files("1" * 40)

        self.assertEqual(files, [])
        self.assertIn("not in this checkout's history", skipped)


class PlanTest(unittest.TestCase):
    def test_groups_files_by_app(self):
        grouped = stress.by_app(
            [
                "apps/fermix_web/test/a_test.exs",
                "apps/fermix_core/test/b_test.exs",
                "apps/fermix_core/test/a_test.exs",
            ]
        )

        self.assertEqual(
            grouped,
            {
                "fermix_core": ["apps/fermix_core/test/a_test.exs", "apps/fermix_core/test/b_test.exs"],
                "fermix_web": ["apps/fermix_web/test/a_test.exs"],
            },
        )

    def test_a_large_change_gets_fewer_repeats(self):
        self.assertEqual(stress.repeats_for(stress.MANY_FILES), stress.REPEATS)
        self.assertEqual(stress.repeats_for(stress.MANY_FILES + 1), stress.REPEATS_WHEN_MANY)

    def test_counts_tests_across_every_repeat(self):
        self.assertEqual(stress.tests_ran(REPEATED_GREEN), 6)
        self.assertEqual(stress.tests_ran("==> fermix_core\nThere are no tests to run\n"), 0)


class StressAppTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-stress-app-")
        self.log = Path(self.tmp.name) / "stress.log"
        self.commands = []

    def tearDown(self):
        self.tmp.cleanup()

    def run_app(self, code, text):
        def fake(command, log):
            self.commands.append(command)
            log.write_text(text)
            return code

        with mock.patch.object(stress, "run_teed", fake), contextlib.redirect_stdout(io.StringIO()) as out:
            ok = stress.stress_app("fermix_core", ["apps/fermix_core/test/x_test.exs"], 20, self.log)
        return ok, out.getvalue()

    def test_repeats_the_files_until_the_first_failure(self):
        self.run_app(0, REPEATED_GREEN)

        self.assertEqual(
            self.commands[0],
            [
                "mix", "test", "--warnings-as-errors", "--max-failures", "1",
                "--repeat-until-failure", "20", "apps/fermix_core/test/x_test.exs",
            ],
        )

    def test_a_failure_on_any_repeat_fails_and_points_at_the_test(self):
        ok, out = self.run_app(2, FAILED_ON_REPEAT)

        self.assertFalse(ok)
        self.assertIn(
            "::error file=apps/fermix_core/test/fermix_core/foo_test.exs,line=42,title=Flaky under load::", out
        )
        self.assertIn("(seed 11)", out)

    def test_a_failure_with_no_named_test_still_fails_and_says_so(self):
        ok, out = self.run_app(1, "==> fermix_core\n** (Mix) could not compile\n")

        self.assertFalse(ok)
        self.assertIn("title=Stress run failed", out)

    def test_a_green_run_that_ran_nothing_warns(self):
        ok, out = self.run_app(0, "==> fermix_core\nThere are no tests to run\n")

        self.assertTrue(ok)
        self.assertIn("title=Stress ran no tests", out)


class MainTest(unittest.TestCase):
    def test_no_changed_test_files_passes_without_running_mix(self):
        with mock.patch.object(stress, "changed_test_files", return_value=([], "")), mock.patch.object(
            stress, "stress_app"
        ) as stress_app, contextlib.redirect_stdout(io.StringIO()):
            code = stress.main(["--base", "abc", "--log-dir", tempfile.gettempdir()])

        self.assertEqual(code, 0)
        stress_app.assert_not_called()

    def test_one_failing_app_fails_the_step_and_the_burners_are_stopped(self):
        burner = mock.Mock()
        files = ["apps/fermix_core/test/a_test.exs", "apps/fermix_web/test/b_test.exs"]
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            stress, "changed_test_files", return_value=(files, "")
        ), mock.patch.object(stress, "start_burners", return_value=[burner]), mock.patch.object(
            stress, "stress_app", side_effect=[True, False]
        ):
            code = stress.main(["--base", "abc", "--log-dir", tmp])

        self.assertEqual(code, 1)
        burner.kill.assert_called_once()

    def test_the_burners_are_stopped_when_a_run_raises(self):
        burner = mock.Mock()
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            stress, "changed_test_files", return_value=(["apps/fermix_core/test/a_test.exs"], "")
        ), mock.patch.object(stress, "start_burners", return_value=[burner]), mock.patch.object(
            stress, "stress_app", side_effect=RuntimeError("boom")
        ), self.assertRaises(RuntimeError):
            stress.main(["--base", "abc", "--log-dir", tmp])

        burner.kill.assert_called_once()


if __name__ == "__main__":
    unittest.main()
