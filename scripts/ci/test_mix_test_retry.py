#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for the flaky-test rerun around the umbrella `mix test`."""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))

import mix_test_retry as retry  # noqa: E402

ONE_CORE_FAILURE = """\
==> fermix_nif
Running ExUnit with seed: 100913, max_cases: 8
6 tests, 0 failures
==> fermix_core
Running ExUnit with seed: 100913, max_cases: 8

  1) test meetings_report/1 enabled with no usable lane names the one thing to do (FermixCore.Setup.DoctorTest)
     apps/fermix_core/test/fermix_core/setup/doctor_test.exs:1332
     Assertion with == failed
     stacktrace:
       test/fermix_core/setup/doctor_test.exs:1340: (test)

1 doctest, 3 properties, 6372 tests, 1 failure, 29 skipped
==> fermix_channels
Running ExUnit with seed: 100913, max_cases: 8
1 doctest, 1283 tests, 0 failures
"""

CORE_RERUN_PASSES = """\
==> fermix_nif
==> fermix_core
Running ExUnit with seed: 1, max_cases: 8
1 test, 0 failures
"""


def channels_failures(count):
    blocks = [
        f"  {n}) test case {n} (FermixChannels.SomeTest)\n"
        f"     apps/fermix_channels/test/fermix_channels/some_test.exs:{10 * n}\n"
        for n in range(1, count + 1)
    ]
    return (
        "==> fermix_channels\nRunning ExUnit with seed: 7, max_cases: 8\n"
        + "".join(blocks)
        + f"1283 tests, {count} failures\n"
    )


class ParseRunTest(unittest.TestCase):
    def test_reads_each_apps_summary_and_names_the_failure_with_its_location(self):
        run = retry.parse_run(ONE_CORE_FAILURE)

        self.assertEqual(run.seed, "100913")
        self.assertEqual(run.apps["fermix_core"].ran, 1 + 3 + 6372)
        self.assertEqual(run.apps["fermix_core"].failed, 1)
        self.assertEqual(run.apps["fermix_channels"].failed, 0)
        [failure] = run.failures
        self.assertEqual(failure.app, "fermix_core")
        self.assertEqual(failure.module, "FermixCore.Setup.DoctorTest")
        self.assertEqual(failure.path, "apps/fermix_core/test/fermix_core/setup/doctor_test.exs")
        self.assertEqual(failure.line, 1332)

    def test_tolerates_the_timestamps_and_markers_of_a_downloaded_actions_log(self):
        stamped = "\n".join(
            "2026-10-14T01:02:03.4567890Z " + ("##[error]" if "doctor_test.exs:1332" in line else "") + line
            for line in ONE_CORE_FAILURE.splitlines()
        )

        run = retry.parse_run(stamped)

        self.assertEqual(run.failures[0].line, 1332)
        self.assertEqual(run.apps["fermix_core"].failed, 1)

    def test_counts_invalid_tests_as_failed(self):
        self.assertEqual(retry.parse_summary("4 tests, 0 failures, 4 invalid"), (4, 4))

    def test_reads_a_doctest_only_summary(self):
        run = retry.parse_run("==> fermix_core\nRunning ExUnit with seed: 1\n1 doctest, 0 failures\n")

        self.assertEqual(run.apps["fermix_core"].ran, 1)

    def test_an_app_relative_location_is_made_umbrella_relative(self):
        log = "Running ExUnit with seed: 3\n  1) test x (A.BTest)\n     test/a/b_test.exs:9\n1 test, 1 failure\n"

        run = retry.parse_run(log, app="fermix_web")

        self.assertEqual(run.failures[0].path, "apps/fermix_web/test/a/b_test.exs")


class PlanRetryTest(unittest.TestCase):
    def test_one_failure_is_retried_in_its_own_app_by_its_location(self):
        targets, refusal = retry.plan_retry(retry.parse_run(ONE_CORE_FAILURE), max_flaky=5)

        self.assertEqual(
            (targets, refusal),
            ({"fermix_core": ["apps/fermix_core/test/fermix_core/setup/doctor_test.exs:1332"]}, ""),
        )

    def test_a_later_apps_failure_is_retried_in_that_app(self):
        log = "==> fermix_core\nRunning ExUnit with seed: 5\n9 tests, 0 failures\n" + channels_failures(2)

        targets, refusal = retry.plan_retry(retry.parse_run(log), max_flaky=5)

        self.assertEqual(refusal, "")
        self.assertEqual(
            targets,
            {
                "fermix_channels": [
                    "apps/fermix_channels/test/fermix_channels/some_test.exs:10",
                    "apps/fermix_channels/test/fermix_channels/some_test.exs:20",
                ]
            },
        )

    def test_a_failure_with_no_test_location_stays_red(self):
        log = "Running ExUnit with seed: 3\n  1) test x (A.BTest)\n     ** (RuntimeError) boom\n1 test, 1 failure\n"

        targets, refusal = retry.plan_retry(retry.parse_run(log, app="fermix_core"), max_flaky=5)

        self.assertEqual(targets, {})
        self.assertIn("no test location for A.BTest x", refusal)

    def test_failures_exunit_did_not_name_stay_red(self):
        log = channels_failures(1).replace("1283 tests, 1 failures", "1283 tests, 1 failure, 3 invalid")

        targets, refusal = retry.plan_retry(retry.parse_run(log), max_flaky=5)

        self.assertEqual(targets, {})
        self.assertIn("named 1 of 4 failures", refusal)

    def test_more_failures_than_the_cap_stay_red(self):
        failed, refusal = retry.plan_retry(retry.parse_run(channels_failures(6)), max_flaky=5)

        self.assertEqual(failed, {})
        self.assertIn("6 tests failed", refusal)

    def test_an_aborted_suite_stays_red(self):
        log = ONE_CORE_FAILURE + (
            "ERROR! Test suite aborted after successful execution due to warnings "
            "while using the --warnings-as-errors option\n"
        )

        failed, refusal = retry.plan_retry(retry.parse_run(log), max_flaky=5)

        self.assertEqual(failed, {})
        self.assertIn("aborted", refusal)

    def test_an_app_that_started_but_printed_no_summary_stays_red(self):
        log = ONE_CORE_FAILURE + "==> fermix_web\nRunning ExUnit with seed: 100913, max_cases: 8\n"

        _failed, refusal = retry.plan_retry(retry.parse_run(log), max_flaky=5)

        self.assertIn("fermix_web", refusal)

    def test_a_red_exit_with_no_failed_test_stays_red(self):
        _failed, refusal = retry.plan_retry(retry.parse_run("==> fermix_core\n** (Mix) boom\n"), max_flaky=5)

        self.assertIn("no failed tests", refusal)


class CheckRerunTest(unittest.TestCase):
    def test_a_passing_rerun_that_ran_the_failed_tests_proves_them_flaky(self):
        rerun = retry.parse_run(CORE_RERUN_PASSES)

        self.assertEqual(retry.check_rerun("fermix_core", 1, rerun, 0), "")

    def test_a_rerun_that_ran_nothing_is_not_proof(self):
        rerun = retry.parse_run("==> fermix_core\nThere are no tests to run\n")

        self.assertIn("no ExUnit summary", retry.check_rerun("fermix_core", 1, rerun, 0))

    def test_a_rerun_that_ran_fewer_tests_than_failed_is_not_proof(self):
        rerun = retry.parse_run(CORE_RERUN_PASSES)

        self.assertIn("ran 1 tests for 2 failures", retry.check_rerun("fermix_core", 2, rerun, 0))

    def test_a_rerun_that_fails_again_is_not_flaky(self):
        rerun = retry.parse_run(CORE_RERUN_PASSES.replace("0 failures", "1 failure"))

        self.assertIn("failed again", retry.check_rerun("fermix_core", 1, rerun, 2))


class AnnotationTest(unittest.TestCase):
    def test_names_the_test_and_points_at_its_line(self):
        failure = retry.Failure("fermix_core", "test", "a, b: c", "A.BTest", "apps/x/test/b_test.exs", 7)

        self.assertEqual(
            retry.annotation(failure),
            '::warning file=apps/x/test/b_test.exs,line=7,title=Flaky test::'
            'A.BTest test "a, b: c" (apps/x/test/b_test.exs:7) failed, then passed on rerun',
        )

    def test_escapes_workflow_command_characters_in_the_message(self):
        failure = retry.Failure("fermix_core", "test", "50%\nnext", "A.BTest")

        self.assertIn('"50%25%0Anext"', retry.annotation(failure))


class MainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-mix-test-retry-")
        self.base = Path(self.tmp.name)
        self.log = self.base / "mix-test.log"
        self.flaky = self.base / "flaky.json"
        self.calls = []

    def tearDown(self):
        self.tmp.cleanup()

    def fake_runner(self, outputs):
        def run(command, log):
            self.calls.append(command)
            code, text = outputs[len(self.calls) - 1]
            log.write_text(text)
            return code

        return run

    def main(self, outputs, *extra):
        argv = ["--log", str(self.log), "--flaky-json", str(self.flaky), *extra]
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = retry.main(argv, runner=self.fake_runner(outputs))
        return code, out.getvalue()

    def test_a_green_suite_runs_once(self):
        code, _out = self.main([(0, "6 tests, 0 failures\n")])

        self.assertEqual(code, 0)
        self.assertEqual(self.calls, [["mix", "test", "--warnings-as-errors"]])
        self.assertFalse(self.flaky.exists())

    def test_a_failure_that_passes_its_rerun_is_flagged_and_passes(self):
        code, out = self.main([(2, ONE_CORE_FAILURE), (0, CORE_RERUN_PASSES)])

        self.assertEqual(code, 0)
        self.assertEqual(
            self.calls[1],
            ["mix", "test", "--warnings-as-errors", "apps/fermix_core/test/fermix_core/setup/doctor_test.exs:1332"],
        )
        self.assertIn("::warning file=apps/fermix_core/test/fermix_core/setup/doctor_test.exs,line=1332", out)
        flaky = json.loads(self.flaky.read_text())
        self.assertEqual(flaky["seed"], "100913")
        self.assertEqual([f["module"] for f in flaky["flaky"]], ["FermixCore.Setup.DoctorTest"])

    def test_a_failure_that_fails_its_rerun_stays_red(self):
        code, out = self.main([(2, ONE_CORE_FAILURE), (2, CORE_RERUN_PASSES.replace("0 failures", "1 failure"))])

        self.assertEqual(code, 1)
        self.assertNotIn("::warning", out)
        self.assertFalse(self.flaky.exists())

    def test_a_rerun_that_runs_nothing_stays_red(self):
        code, _out = self.main([(2, ONE_CORE_FAILURE), (0, "==> fermix_core\nThere are no tests to run\n")])

        self.assertEqual(code, 1)

    def test_too_many_failures_keep_the_first_exit_code_and_are_not_rerun(self):
        code, out = self.main([(2, channels_failures(6))])

        self.assertEqual(code, 2)
        self.assertEqual(len(self.calls), 1)
        self.assertIn("Not retried", out)

    def test_extra_arguments_reach_the_first_run(self):
        self.main([(0, "1 test, 0 failures\n")], "--", "apps/fermix_core/test/x_test.exs")

        self.assertEqual(self.calls[0][-1], "apps/fermix_core/test/x_test.exs")

    def test_writes_the_job_summary_and_step_output_when_actions_provides_them(self):
        summary, output = self.base / "summary.md", self.base / "output"
        env = {"GITHUB_STEP_SUMMARY": str(summary), "GITHUB_OUTPUT": str(output)}
        with mock.patch.dict(os.environ, env):
            self.main([(2, ONE_CORE_FAILURE), (0, CORE_RERUN_PASSES)])

        self.assertIn("| `FermixCore.Setup.DoctorTest` |", summary.read_text())
        self.assertEqual(output.read_text(), "flaky=true\n")

    def test_a_green_suite_sets_no_flaky_output(self):
        output = self.base / "output"
        with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}):
            self.main([(0, "6 tests, 0 failures\n")])

        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
