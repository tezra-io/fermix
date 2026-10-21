#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
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

GREEN_RUN = """\
==> fermix_core
Running ExUnit with seed: 11, max_cases: 8
3 tests, 0 failures
"""

FAILED_RUN = """\
==> fermix_core
Running ExUnit with seed: 12, max_cases: 8

  1) test flushes after the debounce (FermixCore.FooTest)
     apps/fermix_core/test/fermix_core/foo_test.exs:42

3 tests, 1 failure
"""

NO_TESTS_RUN = "==> fermix_core\nThere are no tests to run\n"

# The linux-x64 runner's seconds per run under load for the change that first
# outran the step timeout (1935ffae): fermix_core's 35 files at 5 repeats
# needed about 12 minutes on their own.
CI_RUN_SECONDS = {"fermix_channels": 56, "fermix_core": 145, "fermix_opik": 2, "fermix_web": 100}

# The 0.16.0 release pull request (run 39539072311): every test file dev had
# changed since main, and the linux-x64 runner's seconds per run of at most 30
# of them under load. One run of all 152 fermix_core files outlasted the step.
RELEASE_FILES = {"fermix_channels": 39, "fermix_core": 152, "fermix_nif": 1, "fermix_opik": 3, "fermix_web": 1}
RELEASE_RUN_SECONDS = {"fermix_channels": 125, "fermix_core": 150, "fermix_nif": 5, "fermix_opik": 5, "fermix_web": 219}


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


class Clock:
    """A clock only the fake runs move; no test reads the real one."""

    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


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

    def test_an_app_with_many_files_runs_them_in_chunks(self):
        files = [f"apps/fermix_core/test/f{n}_test.exs" for n in range(2 * stress.MANY_FILES + 1)]

        chunks = stress.AppStress("fermix_core", files).chunks

        self.assertEqual([len(chunk) for chunk in chunks], [stress.MANY_FILES, stress.MANY_FILES, 1])
        self.assertEqual([path for chunk in chunks for path in chunk], files)

    def test_counts_tests_across_every_repeat(self):
        self.assertEqual(stress.tests_ran(REPEATED_GREEN), 6)
        self.assertEqual(stress.tests_ran("==> fermix_core\nThere are no tests to run\n"), 0)


class FitsTest(unittest.TestCase):
    def test_a_first_run_starts_while_any_budget_is_left(self):
        self.assertTrue(stress.fits(None, 719.9, 720))
        self.assertFalse(stress.fits(None, 720, 720))

    def test_a_later_run_starts_only_when_its_previous_run_would_end_inside_the_budget(self):
        self.assertTrue(stress.fits(145, 575, 720))
        self.assertFalse(stress.fits(145, 575.1, 720))


def simulate(seconds, repeats, budget_s, outcomes=None, files=None):
    """Round-robin over fake runs that take `seconds[app]` each; returns states, run order, seconds used.

    `files[app]` is how many changed test files the app has, one by default.
    """
    clock = Clock()
    order = []

    def run_once(state):
        order.append(state.app)
        clock.now += seconds[state.app]
        return (outcomes or {}).get((state.app, state.runs + 1), stress.PASSED)

    counts = files or {}
    apps = {app: [f"apps/{app}/test/x{n}_test.exs" for n in range(counts.get(app, 1))] for app in seconds}
    states = stress.round_robin(apps, repeats, budget_s, run_once, clock)
    return {s.app: s for s in states}, order, clock.now - 1000.0


class RoundRobinTest(unittest.TestCase):
    def test_every_app_runs_once_before_any_app_runs_twice(self):
        states, order, _ = simulate({"a": 1, "b": 1, "c": 1}, 3, 100)

        self.assertEqual(order, ["a", "b", "c"] * 3)
        self.assertEqual([(s.runs, s.stopped) for s in states.values()], [(3, "")] * 3)

    def test_a_slow_first_app_does_not_starve_the_rest(self):
        # App by app, fermix_channels would take three runs and the whole budget
        # before fermix_web's first run.
        states, _, _ = simulate({"fermix_channels": 200, "fermix_web": 10}, 5, 600)

        self.assertEqual((states["fermix_channels"].runs, states["fermix_channels"].stopped), (2, stress.BUDGET))
        self.assertEqual((states["fermix_web"].runs, states["fermix_web"].stopped), (5, ""))

    def test_the_change_that_outran_the_step_timeout_now_stops_inside_the_budget(self):
        states, _, used = simulate(CI_RUN_SECONDS, stress.REPEATS_WHEN_MANY, 720)

        self.assertEqual(
            {app: (s.runs, s.stopped) for app, s in states.items()},
            {
                "fermix_channels": (4, stress.BUDGET),
                "fermix_core": (2, stress.BUDGET),
                "fermix_opik": (3, stress.BUDGET),
                "fermix_web": (2, stress.BUDGET),
            },
        )
        self.assertLessEqual(used, 720)

    def test_an_app_whose_turn_comes_after_the_budget_is_spent_never_runs(self):
        states, order, _ = simulate({"a": 800, "b": 10}, 5, 720)

        self.assertEqual(order, ["a"])
        self.assertEqual((states["b"].runs, states["b"].stopped), (0, stress.BUDGET))

    def test_a_failed_run_stops_only_its_own_app(self):
        states, order, _ = simulate({"a": 1, "b": 1}, 3, 100, {("a", 2): stress.FAILED})

        self.assertEqual(order, ["a", "b", "a", "b", "b"])
        self.assertEqual((states["a"].runs, states["a"].stopped), (2, stress.FAILED))
        self.assertEqual((states["b"].runs, states["b"].stopped), (3, ""))

    def test_an_app_that_ran_no_tests_is_not_repeated(self):
        states, order, _ = simulate({"a": 1}, 5, 100, {("a", 1): stress.NO_TESTS})

        self.assertEqual(order, ["a"])
        self.assertEqual(states["a"].stopped, stress.NO_TESTS)

    def test_each_chunk_of_an_app_runs_the_repeats_of_a_whole_app(self):
        states, order, _ = simulate({"a": 1, "b": 1}, 2, 100, files={"a": stress.MANY_FILES + 1})

        self.assertEqual(order, ["a", "b", "a", "b", "a", "a"])
        self.assertEqual((states["a"].runs, states["a"].stopped), (4, ""))
        self.assertEqual((states["b"].runs, states["b"].stopped), (2, ""))

    def test_the_release_that_outran_the_step_timeout_runs_in_chunks_inside_it(self):
        states, _, used = simulate(
            RELEASE_RUN_SECONDS, stress.REPEATS_WHEN_MANY, 720, files=RELEASE_FILES
        )

        # Every app ran; a run that starts inside the budget is never cut short,
        # so the step ends by the budget plus one run, inside its 15 minutes.
        self.assertTrue(all(s.runs > 0 for s in states.values()))
        self.assertLessEqual(used, 720 + max(RELEASE_RUN_SECONDS.values()))
        self.assertLessEqual(used, 15 * 60 - 60)
        self.assertEqual(stress.exit_status(list(states.values())), 0)
        self.assertEqual(states["fermix_core"].stopped, stress.BUDGET)
        self.assertTrue(stress.unstressed_files(states["fermix_core"]))


def app_state(runs, stopped, last_s=145.0, file_count=1):
    files = [f"apps/fermix_core/test/x{n}_test.exs" for n in range(file_count)]
    return stress.AppStress("fermix_core", files, runs, last_s, stopped)


class ReportTest(unittest.TestCase):
    def test_a_budget_stop_after_a_run_is_a_notice_naming_the_count(self):
        annotation = stress.budget_annotation(app_state(2, stress.BUDGET), 5, 720)

        self.assertTrue(annotation.startswith("::notice title=Stress budget reached::fermix_core: 2 of 5 runs"))
        self.assertIn("last run took 145 s", annotation)

    def test_a_budget_stop_before_every_chunk_ran_names_the_files_left_unstressed(self):
        state = app_state(1, stress.BUDGET, file_count=2 * stress.MANY_FILES + 1)

        annotation = stress.budget_annotation(state, 5, 720)

        self.assertTrue(annotation.startswith("::notice title=Stress budget reached::fermix_core: 1 of 15 runs"))
        self.assertIn("31 of its 61 changed test files never ran under load", annotation)
        self.assertEqual(stress.unstressed_files(state), state.files[stress.MANY_FILES :])
        self.assertEqual(stress.unstressed_files(app_state(3, stress.BUDGET, file_count=61)), [])

    def test_an_app_that_never_ran_is_an_error(self):
        annotation = stress.budget_annotation(app_state(0, stress.BUDGET, None), 5, 720)

        self.assertTrue(annotation.startswith("::error title=Stress budget spent::fermix_core never ran under load"))

    def test_an_app_the_budget_did_not_stop_has_no_budget_annotation(self):
        for state in (app_state(5, ""), app_state(2, stress.FAILED), app_state(1, stress.NO_TESTS)):
            self.assertEqual(stress.budget_annotation(state, 5, 720), "")

    def test_a_budget_stop_passes_but_a_failure_or_an_app_that_never_ran_fails(self):
        self.assertEqual(stress.exit_status([app_state(5, ""), app_state(2, stress.BUDGET)]), 0)
        self.assertEqual(stress.exit_status([app_state(1, stress.NO_TESTS)]), 0)
        self.assertEqual(stress.exit_status([app_state(5, ""), app_state(2, stress.FAILED)]), 1)
        self.assertEqual(stress.exit_status([app_state(5, ""), app_state(0, stress.BUDGET, None)]), 1)

    def test_the_summary_says_how_many_runs_each_app_had_and_why_it_stopped(self):
        self.assertEqual(stress.describe(app_state(5, ""), 5), "fermix_core: 5 of 5 runs passed")
        self.assertEqual(
            stress.describe(app_state(2, stress.BUDGET), 5),
            "fermix_core: 2 of 5 runs passed, then the budget stopped it",
        )
        self.assertEqual(stress.describe(app_state(3, stress.FAILED), 5), "fermix_core: failed on run 3 of 5")
        self.assertEqual(stress.describe(app_state(1, stress.NO_TESTS), 5), "fermix_core: ran no tests")
        self.assertEqual(
            stress.describe(app_state(0, stress.BUDGET, None), 5),
            "fermix_core: never ran; the budget was spent before its first run",
        )
        self.assertEqual(
            stress.describe(app_state(2, stress.BUDGET, file_count=61), 5),
            "fermix_core: 2 of 15 runs passed, then the budget stopped it",
        )


class RunOnceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-stress-app-")
        self.log_dir = Path(self.tmp.name)
        self.commands = []
        self.logs = []
        # Each line the run prints, and when the load goes on and off between them.
        self.events = []
        self.burner = mock.Mock()
        self.burner.kill.side_effect = lambda: self.events.append("load off")

    def tearDown(self):
        self.tmp.cleanup()

    def start_burners(self):
        self.events.append("load on")
        return [self.burner]

    def run_app(self, code, text, runs_before=0):
        def fake(command, log, on_line):
            self.commands.append(command)
            self.logs.append(log)
            log.write_text(text)
            for line in text.splitlines(keepends=True):
                self.events.append(line.strip())
                on_line(line)
            return code

        return self.run_once(fake, runs_before)

    def run_once(self, fake, runs_before=0, files=None):
        state = stress.AppStress("fermix_core", files or ["apps/fermix_core/test/x_test.exs"], runs_before)
        with mock.patch.object(stress, "run_teed", fake), mock.patch.object(
            stress, "start_burners", self.start_burners
        ), contextlib.redirect_stdout(io.StringIO()) as out:
            outcome = stress.run_once(state, 20, self.log_dir)
        return outcome, out.getvalue()

    def test_the_load_runs_from_the_first_test_to_the_end_of_the_run(self):
        self.run_app(0, GREEN_RUN)

        self.assertEqual(
            self.events,
            [
                "==> fermix_core",
                "Running ExUnit with seed: 11, max_cases: 8",
                "load on",
                "3 tests, 0 failures",
                "load off",
            ],
        )

    def test_a_run_that_never_reaches_its_tests_never_loads_the_cpu(self):
        self.run_app(1, "==> fermix_core\n** (Mix) could not compile\n")

        self.assertNotIn("load on", self.events)

    def test_the_load_stops_when_a_run_raises(self):
        def fake(_command, _log, on_line):
            on_line("Running ExUnit with seed: 11, max_cases: 8\n")
            raise RuntimeError("boom")

        with self.assertRaises(RuntimeError):
            self.run_once(fake)

        self.assertEqual(self.events, ["load on", "load off"])

    def test_runs_the_files_once_into_a_log_of_their_own(self):
        outcome, _ = self.run_app(0, GREEN_RUN, runs_before=2)

        self.assertEqual(outcome, stress.PASSED)
        self.assertEqual(
            self.commands[0],
            ["mix", "test", "--warnings-as-errors", "--max-failures", "1", "apps/fermix_core/test/x_test.exs"],
        )
        self.assertEqual(self.logs[0], self.log_dir / "stress-fermix_core-3.log")

    def test_each_run_takes_the_next_chunk_and_the_runs_cycle_through_them(self):
        files = [f"apps/fermix_core/test/f{n}_test.exs" for n in range(stress.MANY_FILES + 1)]

        def fake(command, log, _on_line):
            self.commands.append(command)
            log.write_text(GREEN_RUN)
            return 0

        for runs_before in (0, 1, 2):
            self.run_once(fake, runs_before, files)

        ran = [command[5:] for command in self.commands]
        self.assertEqual(ran, [files[: stress.MANY_FILES], files[stress.MANY_FILES :], files[: stress.MANY_FILES]])

    def test_a_failure_points_at_the_test_and_the_seed_of_the_run_that_failed(self):
        outcome, out = self.run_app(2, FAILED_RUN, runs_before=1)

        self.assertEqual(outcome, stress.FAILED)
        self.assertIn(
            "::error file=apps/fermix_core/test/fermix_core/foo_test.exs,line=42,title=Flaky under load::", out
        )
        self.assertIn("(run 2, seed 12)", out)

    def test_a_failure_with_no_named_test_still_fails_and_says_so(self):
        outcome, out = self.run_app(1, "==> fermix_core\n** (Mix) could not compile\n")

        self.assertEqual(outcome, stress.FAILED)
        self.assertIn("title=Stress run failed", out)

    def test_a_green_run_that_ran_nothing_warns(self):
        outcome, out = self.run_app(0, NO_TESTS_RUN)

        self.assertEqual(outcome, stress.NO_TESTS)
        self.assertIn("title=Stress ran no tests", out)


class MainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-stress-main-")
        self.log_dir = Path(self.tmp.name)
        self.clock = Clock()
        self.burner = mock.Mock()

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, files, seconds, results=None, budget="720"):
        """main() over fake runs: `seconds[app]` per run, `results[app]` the (exit code, log) of each."""

        def fake(command, log, on_line):
            app = command[-1].split("/")[1]
            self.clock.now += seconds[app]
            code, text = (results or {}).get(app, (0, GREEN_RUN))
            log.write_text(text)
            for line in text.splitlines(keepends=True):
                on_line(line)
            return code

        argv = ["--base", "abc", "--budget-s", budget, "--log-dir", str(self.log_dir)]
        with mock.patch.object(stress, "changed_test_files", return_value=(files, "")), mock.patch.object(
            stress, "start_burners", return_value=[self.burner]
        ), mock.patch.object(stress, "run_teed", fake), contextlib.redirect_stdout(io.StringIO()) as out:
            code = stress.main(argv, clock=self.clock)
        return code, out.getvalue()

    def test_no_changed_test_files_passes_without_running_mix(self):
        with mock.patch.object(stress, "changed_test_files", return_value=([], "")), mock.patch.object(
            stress, "run_teed"
        ) as run_teed, contextlib.redirect_stdout(io.StringIO()):
            code = stress.main(["--base", "abc", "--budget-s", "720", "--log-dir", str(self.log_dir)])

        self.assertEqual(code, 0)
        run_teed.assert_not_called()

    def test_a_budget_stop_passes_with_a_notice_and_leaves_one_log_per_run(self):
        files = ["apps/fermix_core/test/a_test.exs", "apps/fermix_web/test/b_test.exs"]

        code, out = self.run_main(files, {"fermix_core": 300, "fermix_web": 100})

        self.assertEqual(code, 0)
        self.assertIn("::notice title=Stress budget reached::fermix_core: 2 of 20 runs", out)
        self.assertIn("::notice title=Stress budget reached::fermix_web: 1 of 20 runs", out)
        self.assertIn("fermix_core: 2 of 20 runs passed, then the budget stopped it", out)
        self.assertEqual(
            sorted(p.name for p in self.log_dir.iterdir()),
            ["stress-fermix_core-1.log", "stress-fermix_core-2.log", "stress-fermix_web-1.log"],
        )
        self.assertEqual(self.burner.kill.call_count, 3, "each run has its own load")

    def test_an_app_the_budget_never_reached_fails_the_step(self):
        files = ["apps/fermix_core/test/a_test.exs", "apps/fermix_web/test/b_test.exs"]

        code, out = self.run_main(files, {"fermix_core": 800, "fermix_web": 10})

        self.assertEqual(code, 1)
        self.assertIn("::error title=Stress budget spent::fermix_web never ran under load", out)

    def test_one_failing_app_fails_the_step(self):
        files = ["apps/fermix_core/test/a_test.exs", "apps/fermix_web/test/b_test.exs"]

        code, _ = self.run_main(files, {"fermix_core": 1, "fermix_web": 1}, {"fermix_web": (2, FAILED_RUN)})

        self.assertEqual(code, 1)

    def test_the_budget_is_required_and_positive(self):
        for argv in (["--log-dir", "x"], ["--log-dir", "x", "--budget-s", "0"]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                stress.parse_args(argv)


if __name__ == "__main__":
    unittest.main()
