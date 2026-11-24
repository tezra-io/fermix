#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for the pre-push gate: a throwaway repository, a fake command
runner and a temporary cache. No step of the real gate runs here."""

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))

import gate  # noqa: E402

REPO = Path(__file__).resolve().parents[2]


def git(root, *args):
    env = {**os.environ, "GIT_CEILING_DIRECTORIES": str(root.parent)}
    env.pop("GIT_INDEX_FILE", None)
    return subprocess.run(
        ["git", "-C", str(root), *args], cwd=root, env=env, check=True, capture_output=True, text=True
    ).stdout


class GateCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-gate-test-")
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.root = base / "repo"
        self.root.mkdir()
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "gate@example.invalid")
        git(self.root, "config", "user.name", "gate")
        (self.root / ".gitignore").write_text("/ignored/\n")
        (self.root / "lib.ex").write_text("one\n")
        (self.root / "tla").mkdir()
        (self.root / "tla" / "M.tla").write_text("\\* SOURCE: lib.ex @ 000000000000\n")
        for directory in gate.SCRIPT_TEST_DIRS:
            (self.root / directory).mkdir(parents=True)
            (self.root / directory / "test_sample.py").write_text("\n")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "base")
        self.commands = []
        patches = [
            mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(base / "cache")}),
            mock.patch.object(gate, "toolchain", lambda: "Elixir 1.19 OTP 28"),
            mock.patch.object(tempfile, "tempdir", str(base)),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def run_gate(self, force=False, fail=None, during=None, tla_output="", flaky=None):
        def execute(command, _root, log, _env):
            text = " ".join(command)
            self.commands.append(text)
            if during is not None and "mix_test_retry" in text:
                during()
            if flaky is not None and "mix_test_retry" in text:
                path = Path(command[command.index("--flaky-json") + 1])
                path.write_text(json.dumps({"seed": "1", "flaky": flaky}))
            log.write_text(tla_output if "tla check" in text else f"output of {text}\n")
            return 1 if fail and fail in text else 0

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gate.run_gate(self.root, force, execute)
        return code, out.getvalue()

    def ran(self, fragment):
        return [c for c in self.commands if fragment in c]


class StepsTest(GateCase):
    def test_runs_every_step_with_the_suite_last_and_the_specs_after_it(self):
        code, out = self.run_gate()

        self.assertEqual(code, 0, out)
        order = [
            "mix format",
            "mix compile",
            "mix credo",
            "scripts/release/test_sample.py",
            "make -C tla tests",
            "make -C benchmark tests",
            "make -C benchmark dry",
            "mix_test_retry",
            "make -C tla check",
        ]
        positions = [next(i for i, c in enumerate(self.commands) if step in c) for step in order]
        self.assertEqual(positions, sorted(positions))

    def test_the_first_failure_stops_the_gate_and_shows_its_log(self):
        code, out = self.run_gate(fail="mix credo")

        self.assertEqual(code, 1)
        self.assertEqual(self.ran("mix_test_retry"), [])
        self.assertIn("FAIL", out)
        self.assertIn("output of mix credo", out)

    def test_a_failure_keeps_its_logs(self):
        _code, out = self.run_gate(fail="mix credo")

        kept = Path(re.search(r"Logs: (\S+)", out).group(1))
        self.assertTrue((kept / "credo.log").exists())

    def test_a_pass_removes_its_logs(self):
        made = []
        real = tempfile.mkdtemp

        def mkdtemp(*args, **kwargs):
            made.append(real(*args, **kwargs))
            return made[-1]

        with mock.patch.object(gate.tempfile, "mkdtemp", mkdtemp):
            code, _out = self.run_gate()

        self.assertEqual(code, 0)
        self.assertFalse(Path(made[-1]).exists())

    def test_names_each_test_that_passed_only_on_its_rerun(self):
        flaky = [{"module": "A.BTest", "name": "x", "path": "apps/a/test/b_test.exs", "line": 7}]

        code, out = self.run_gate(flaky=flaky)

        self.assertEqual(code, 0)
        self.assertIn("A.BTest x (apps/a/test/b_test.exs:7)", out)


class ReceiptTest(GateCase):
    def test_a_tree_that_passed_runs_only_the_specs_again(self):
        self.run_gate()
        self.commands.clear()

        code, out = self.run_gate()

        self.assertEqual(code, 0)
        self.assertEqual(self.commands, ["make -C tla check"])
        self.assertIn("already passed", out)

    def test_a_commit_of_the_same_tree_keeps_the_pass(self):
        (self.root / "lib.ex").write_text("two\n")
        self.run_gate()
        git(self.root, "add", "lib.ex")
        git(self.root, "commit", "-qm", "change")
        self.commands.clear()

        self.run_gate()

        self.assertEqual(self.commands, ["make -C tla check"])

    def test_an_edit_runs_everything_again(self):
        self.run_gate()
        (self.root / "lib.ex").write_text("two\n")
        self.commands.clear()

        self.run_gate()

        self.assertEqual(len(self.ran("mix_test_retry")), 1)

    def test_an_untracked_file_is_part_of_the_tree(self):
        self.run_gate()
        (self.root / "new_test.exs").write_text("new\n")
        self.commands.clear()

        self.run_gate()

        self.assertEqual(len(self.ran("mix_test_retry")), 1)

    def test_an_ignored_file_is_not(self):
        self.run_gate()
        (self.root / "ignored").mkdir()
        (self.root / "ignored" / "build.log").write_text("noise\n")
        self.commands.clear()

        self.run_gate()

        self.assertEqual(self.ran("mix_test_retry"), [])

    def test_a_repin_keeps_the_pass_and_reruns_only_the_specs(self):
        self.run_gate()
        (self.root / "tla" / "M.tla").write_text("\\* SOURCE: lib.ex @ abcdefabcdef\n")
        self.commands.clear()

        self.run_gate()

        self.assertEqual(self.commands, ["make -C tla check"])

    def test_force_runs_everything_again(self):
        self.run_gate()
        self.commands.clear()

        self.run_gate(force=True)

        self.assertEqual(len(self.ran("mix_test_retry")), 1)

    def test_a_new_toolchain_runs_everything_again(self):
        self.run_gate()
        self.commands.clear()

        with mock.patch.object(gate, "toolchain", lambda: "Elixir 1.20 OTP 29"):
            self.run_gate()

        self.assertEqual(len(self.ran("mix_test_retry")), 1)

    def test_a_failed_step_records_nothing(self):
        self.run_gate(fail="mix_test_retry")
        self.commands.clear()

        self.run_gate()

        self.assertEqual(len(self.ran("mix_test_retry")), 1)

    def test_a_tree_that_moves_during_the_gate_is_refused_and_not_recorded(self):
        def move():
            (self.root / "lib.ex").write_text("another session's edit\n")

        code, out = self.run_gate(during=move)

        self.assertEqual(code, 3)
        self.assertIn("changed during the gate", out)
        self.assertEqual(self.ran("make -C tla check"), [])
        self.commands.clear()
        self.run_gate()
        self.assertEqual(len(self.ran("mix_test_retry")), 1)

    def test_computing_the_key_leaves_the_real_index_alone(self):
        (self.root / "lib.ex").write_text("unstaged\n")
        (self.root / "other.ex").write_text("untracked\n")

        gate.tree_key(self.root)

        self.assertEqual(git(self.root, "diff", "--cached", "--name-only"), "")
        self.assertIn("?? other.ex", git(self.root, "status", "--short"))


class SpecsStepTest(GateCase):
    STALE = "s\n  STALE: changed since this spec was verified: lib.ex\n"

    def test_a_stale_spec_fails_the_gate_but_keeps_the_rest_of_its_result(self):
        code, out = self.run_gate(fail="tla check", tla_output=self.STALE)

        self.assertEqual(code, 1)
        self.assertIn("make -C tla repin", out)
        self.commands.clear()

        code, _ = self.run_gate()

        self.assertEqual(code, 0)
        self.assertEqual(self.commands, ["make -C tla check"])

    def test_a_spec_failure_that_is_not_staleness_gets_no_repin_advice(self):
        _code, out = self.run_gate(fail="tla check", tla_output="  FAIL 01_x\n")

        self.assertNotIn("make -C tla repin", out)


class EnvironmentTest(unittest.TestCase):
    def test_mix_steps_run_in_the_test_env_and_no_step_inherits_a_home(self):
        with mock.patch.dict(os.environ, {"FERMIX_HOME": "/somewhere", "MIX_ENV": "dev"}):
            mix = gate.step_env(mix=True)
            other = gate.step_env(mix=False)

        self.assertEqual(mix["MIX_ENV"], "test")
        self.assertNotIn("FERMIX_HOME", mix)
        self.assertNotIn("FERMIX_HOME", other)
        self.assertEqual(other["MIX_ENV"], "dev")

    def test_a_command_reads_no_stdin_and_writes_its_output_to_the_log(self):
        with tempfile.TemporaryDirectory(prefix="fermix-gate-test-") as tmp:
            log = Path(tmp) / "step.log"
            child = "import sys; print('stdin:', repr(sys.stdin.read())); print('err', file=sys.stderr)"

            code = gate.run_command((sys.executable, "-c", child), Path(tmp), log, dict(os.environ))

            self.assertEqual(code, 0)
            self.assertIn("stdin: ''", log.read_text())
            self.assertIn("err", log.read_text())


class CiParityTest(unittest.TestCase):
    """The gate is the local copy of CI's tree checks: a new one in ci.yml must land here too."""

    def test_every_tree_check_ci_runs_is_in_the_gate(self):
        lines = (REPO / ".github/workflows/ci.yml").read_text().splitlines()
        source = "\n".join(line for line in lines if not line.lstrip().startswith("#"))
        pattern = r"run: (mix (?:format|compile|credo)\b[^\n]*)|\b(make -C \S+ \S+|scripts/\w+/test_\*\.py|scripts/ci/mix_test_retry\.py)"
        in_ci = {mix or other for mix, other in re.findall(pattern, source)}
        self.assertGreaterEqual(len(in_ci), 9, in_ci)

        with tempfile.TemporaryDirectory(prefix="fermix-gate-test-") as tmp:
            planned = [" ".join(c) for step in gate.tree_steps(REPO, Path(tmp)) for c in step.commands]
        globs = [f"{directory}/test_*.py" for directory in gate.SCRIPT_TEST_DIRS]
        for command in in_ci:
            self.assertTrue(command in globs or any(command in c for c in planned), f"not in the gate: {command}")


if __name__ == "__main__":
    unittest.main()
