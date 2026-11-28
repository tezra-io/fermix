#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for the suite time budget."""

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import suite_time_budget as budget  # noqa: E402

REPO = Path(__file__).resolve().parents[2]

UMBRELLA_LOG = """\
==> fermix_nif
Running ExUnit with seed: 1, max_cases: 8
Finished in 0.3 seconds (0.00s async, 0.3s sync)
9 tests, 0 failures
==> fermix_core
Running ExUnit with seed: 1, max_cases: 8
2026-11-24T01:02:03.4567890Z Finished in 412.6 seconds (180.1s async, 232.5s sync)
1 doctest, 18000 tests, 0 failures
==> fermix_channels
Running ExUnit with seed: 1, max_cases: 8
Finished in 120.0 seconds (60.0s async, 60.0s sync)
3600 tests, 0 failures
"""


class FinishedSecondsTest(unittest.TestCase):
    def test_reads_each_apps_wall_time_from_an_actions_log(self):
        self.assertEqual(
            budget.finished_seconds(UMBRELLA_LOG),
            {"fermix_nif": 0.3, "fermix_core": 412.6, "fermix_channels": 120.0},
        )


class VerdictsTest(unittest.TestCase):
    def verdicts(self, seconds, allowed):
        return budget.verdicts(seconds, allowed, "test/suite_time_budget.toml")

    def test_inside_the_budget_passes(self):
        self.assertEqual(self.verdicts({"fermix_core": 400.0}, {"fermix_core": 600}), ([], []))

    def test_over_the_budget_fails_and_names_the_app(self):
        errors, _ = self.verdicts({"fermix_core": 700.0}, {"fermix_core": 600})

        self.assertEqual(len(errors), 1)
        self.assertIn("fermix_core took 700 s, over its 600 s budget", errors[0])

    def test_an_app_that_never_finished_fails(self):
        errors, _ = self.verdicts({}, {"fermix_core": 600})

        self.assertIn("printed no ExUnit finish line", errors[0])

    def test_an_app_with_no_budget_fails(self):
        errors, _ = self.verdicts({"fermix_core": 1.0, "fermix_new": 1.0}, {"fermix_core": 600})

        self.assertEqual(errors, ["fermix_new has no budget in test/suite_time_budget.toml; add one"])

    def test_far_under_the_budget_asks_for_a_lower_one(self):
        errors, notices = self.verdicts({"fermix_core": 200.0}, {"fermix_core": 600})

        self.assertEqual(errors, [])
        self.assertIn("lower it", notices[0])


class BudgetFileTest(unittest.TestCase):
    def test_the_checked_in_budget_names_every_app_with_a_suite(self):
        allowed = budget.read_budget(REPO / "test/suite_time_budget.toml")
        apps = {path.parent.parent.name for path in (REPO / "apps").glob("*/test/test_helper.exs")}

        self.assertEqual(set(allowed), apps)

    def test_a_budget_must_be_a_positive_number(self):
        with tempfile.TemporaryDirectory(prefix="fermix-budget-test-") as tmp:
            path = Path(tmp) / "budget.toml"
            path.write_text('[seconds]\nfermix_core = 0\nfermix_web = "fast"\n')

            with self.assertRaisesRegex(ValueError, "fermix_core, fermix_web"):
                budget.read_budget(path)


class MainTest(unittest.TestCase):
    def run_main(self, log_text, budget_text):
        with tempfile.TemporaryDirectory(prefix="fermix-budget-test-") as tmp:
            log, allowed = Path(tmp) / "mix-test.log", Path(tmp) / "budget.toml"
            log.write_text(log_text)
            allowed.write_text(budget_text)
            with contextlib.redirect_stdout(io.StringIO()) as out:
                code = budget.main(["--log", str(log), "--budget", str(allowed)])
        return code, out.getvalue()

    ALL = "[seconds]\nfermix_nif = 30\nfermix_core = {core}\nfermix_channels = 200\n"

    def test_a_suite_inside_every_budget_passes(self):
        code, out = self.run_main(UMBRELLA_LOG, self.ALL.format(core=600))

        self.assertEqual(code, 0, out)
        self.assertIn("fermix_core: 412.6 s", out)

    def test_one_app_over_its_budget_fails_the_step_with_an_annotation(self):
        code, out = self.run_main(UMBRELLA_LOG, self.ALL.format(core=400))

        self.assertEqual(code, 1)
        self.assertIn("::error title=Suite over its time budget::fermix_core took 413 s", out)


if __name__ == "__main__":
    unittest.main()
