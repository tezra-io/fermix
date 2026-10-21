#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for the flaky-test report."""

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))

import flaky_report as report  # noqa: E402
import mix_test_retry as retry  # noqa: E402


def flag(test="flushes", leg="macos-x64", date="2026-10-14", module="A.BTest"):
    failure = retry.Failure("fermix_core", "test", test, module, "apps/fermix_core/test/b_test.exs", 7)
    message = retry.annotation(failure).split("::", 2)[2]
    return {"leg": leg, "date": date, "message": message, "path": failure.path}


class TallyTest(unittest.TestCase):
    def test_reads_the_message_the_retry_script_writes(self):
        [row] = report.tally([flag()])

        self.assertEqual(row.test, "A.BTest flushes")
        self.assertEqual(row.where, "apps/fermix_core/test/b_test.exs:7")

    def test_counts_one_test_across_runs_and_legs_most_flagged_first(self):
        rows = report.tally(
            [
                flag("rare"),
                flag("often", leg="macos-x64", date="2026-10-01"),
                flag("often", leg="linux-x64", date="2026-10-09"),
            ]
        )

        self.assertEqual([(r.test, r.count) for r in rows], [("A.BTest often", 2), ("A.BTest rare", 1)])
        self.assertEqual(rows[0].legs, {"macos-x64", "linux-x64"})
        self.assertEqual(rows[0].last_seen, "2026-10-09")

    def test_marks_a_test_flagged_twice_as_the_next_fix(self):
        text = report.render(report.tally([flag("often"), flag("often"), flag("rare")]), 60)

        self.assertIn("A.BTest often", text.splitlines()[2])
        self.assertTrue(text.splitlines()[2].endswith("FIX NEXT"))
        self.assertFalse(text.splitlines()[3].endswith("FIX NEXT"))


class FlagsInRunTest(unittest.TestCase):
    def test_reads_only_flaky_annotations_on_test_legs(self):
        responses = {
            "repos/o/r/actions/runs/9/jobs?per_page=50": {
                "jobs": [
                    {"id": 1, "name": "compile · format · credo · test (linux-x64)"},
                    {"id": 2, "name": "catalog + compux checksum integrity"},
                ]
            },
            "repos/o/r/check-runs/1/annotations": [
                {"title": "Flaky test", "message": flag()["message"], "path": "apps/fermix_core/test/b_test.exs"},
                {"title": "Other", "message": "unrelated", "path": "x"},
            ],
        }
        with mock.patch.object(report, "gh_json", side_effect=lambda path: responses[path]):
            flags = report.flags_in_run("o/r", {"id": 9, "created_at": "2026-10-14T01:00:00Z"})

        self.assertEqual([(f["leg"], f["date"]) for f in flags], [("linux-x64", "2026-10-14")])


if __name__ == "__main__":
    unittest.main()
