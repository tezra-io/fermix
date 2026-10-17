#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for the Docker cloud sandbox check of a Fermix kit (M64).

A stand-in `sbx` logs every call and answers each in-sandbox command from the
environment, so nothing here signs in to Docker or creates a sandbox.
"""

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("verify_sbx_headless.sh")
BASH = shutil.which("bash")
IMAGE = "docker.io/example/fermix-kit:9.8.7"

# `sbx --cloud exec NAME bash -lc CMD` runs CMD for real, with a stand-in
# `fermix` first on PATH and HOME at the fake sandbox home, so the script's own
# shell and python one-liners run as they will in the sandbox.
FAKE_SBX = """#!/bin/bash
printf 'sbx %s\\n' "$*" >> "$FAKE_LOG"
[ "$1" = --cloud ] || exit 64
case "$2" in
  run) exit "${FAKE_RUN_EXIT:-0}" ;;
  rm) exit 0 ;;
  exec) HOME="$FAKE_HOME" PATH="$FAKE_TOOLS:/usr/bin:/bin" exec bash -c "$6" ;;
  *) exit 64 ;;
esac
"""

# `fermix status` says "not running" (3) until its FAKE_STATUS_UP_AT-th call
# (never when 0); `settings show` prints FAKE_SETTINGS; `ask` prints FAKE_REPLY
# on stdout and FAKE_ASK_STDERR on stderr.
FAKE_FERMIX = """#!/bin/sh
printf 'fermix %s\\n' "$*" >> "$FAKE_LOG"
case "$1" in
  status)
    calls=$(( $(cat "$FAKE_LOG.status" 2>/dev/null || echo 0) + 1 ))
    echo "$calls" > "$FAKE_LOG.status"
    if [ "${FAKE_STATUS_UP_AT:-1}" -ne 0 ] && [ "$calls" -ge "${FAKE_STATUS_UP_AT:-1}" ]; then
      echo "fermix: running (pid 7, version 9.8.7)"
      exit 0
    fi
    echo "fermix: not running"
    exit 3 ;;
  settings) printf '%s\\n' "$FAKE_SETTINGS" ;;
  ask)
    printf '%s' "${FAKE_REPLY-Hello there.}"
    printf '%s' "${FAKE_ASK_STDERR-}" >&2
    exit "${FAKE_ASK_EXIT:-0}" ;;
  *) exit 64 ;;
esac
"""

FAKE_SLEEP = """#!/bin/sh
printf 'sleep %s\\n' "$*" >> "$FAKE_LOG"
"""


def secrets_section(store: str) -> str:
    # The shape `fermix settings show secrets --json` printed in a sandbox.
    row = {"key": "secret_store", "kind": "choice", "label": "Keep secrets in", "value": store}
    other = {"key": "unrelated", "kind": "toggle", "label": "Another row", "value": "keyring"}
    return json.dumps({"id": "secrets", "title": "Secrets", "rows": [other, row]})


class VerifySbxHeadlessTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="vsbx"))
        self.addCleanup(shutil.rmtree, self.root)
        self.bin = self.root / "bin"
        self.tools = self.root / "tools"
        self.home = self.root / "home"
        for directory in (self.bin, self.tools, self.home):
            directory.mkdir()
        self.log = self.root / "log"
        self.log.touch()
        for directory, name, body in (
            (self.bin, "sbx", FAKE_SBX),
            (self.bin, "sleep", FAKE_SLEEP),
            (self.tools, "fermix", FAKE_FERMIX),
        ):
            path = directory / name
            path.write_text(body)
            path.chmod(0o755)
        (self.home / ".fermix-sandbox-setup-done").touch()
        (self.home / ".fermix-sandbox-boot.log").write_text("fermix-sandbox-boot: fermix setup failed\n")

    def run_check(self, *args: str, **extra: str) -> subprocess.CompletedProcess:
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "FAKE_LOG": str(self.log),
            "FAKE_HOME": str(self.home),
            "FAKE_TOOLS": str(self.tools),
            "FAKE_SETTINGS": secrets_section("file"),
        }
        env.update(extra)
        return subprocess.run(
            [BASH, str(SCRIPT), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def calls(self) -> list:
        return self.log.read_text().splitlines()

    def sandbox_name(self) -> str:
        run = next(line for line in self.calls() if line.startswith("sbx --cloud run "))
        return run.split("--name ")[1].split(" ")[0]

    def assert_removed(self) -> None:
        self.assertEqual(self.calls()[-1], f"sbx --cloud rm --force {self.sandbox_name()}")

    def test_passes_a_kit_that_boots_and_answers(self) -> None:
        result = self.run_check(IMAGE, FAKE_STATUS_UP_AT="3")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"PASS: {IMAGE} runs Fermix headless", result.stdout)
        self.assertIn("Hello there.", result.stdout)
        name = self.sandbox_name()
        self.assertRegex(name, r"^fermix-verify-\d+$")
        self.assertIn(
            f"sbx --cloud run -d --name {name} --cpus 1 --memory 2g --ttl 1h "
            f"--on-timeout delete {IMAGE}",
            self.calls(),
        )
        self.assertEqual([c for c in self.calls() if c.startswith("sleep")], ["sleep 5"] * 2)
        self.assertIn("fermix settings show secrets --json", self.calls())
        self.assert_removed()

    def test_fails_with_the_boot_log_when_the_daemon_never_comes_up(self) -> None:
        result = self.run_check(IMAGE, FAKE_STATUS_UP_AT="0")

        self.assertEqual(result.returncode, 1)
        self.assertIn("Fermix did not answer within 180 seconds", result.stderr)
        self.assertIn("fermix setup failed", result.stderr)
        self.assertEqual(len([c for c in self.calls() if c.startswith("sleep")]), 35)
        self.assert_removed()

    def test_fails_when_the_sandbox_cannot_be_created_and_still_cleans_up(self) -> None:
        result = self.run_check(IMAGE, FAKE_RUN_EXIT="1")

        self.assertEqual(result.returncode, 1)
        self.assertIn("could not create a sandbox from", result.stderr)
        self.assert_removed()

    def test_fails_when_the_boot_hook_never_marked_setup_done(self) -> None:
        (self.home / ".fermix-sandbox-setup-done").unlink()

        result = self.run_check(IMAGE)

        self.assertEqual(result.returncode, 1)
        self.assertIn("never marked setup done", result.stderr)
        self.assert_removed()

    def test_fails_on_any_secret_store_but_the_file(self) -> None:
        result = self.run_check(IMAGE, FAKE_SETTINGS=secrets_section("keyring"))

        self.assertEqual(result.returncode, 1)
        self.assertIn("must use the file secret store, not: keyring", result.stderr)

    def test_fails_when_the_secrets_section_has_no_store_row(self) -> None:
        result = self.run_check(IMAGE, FAKE_SETTINGS='{"id": "secrets", "rows": []}')

        self.assertEqual(result.returncode, 1)
        self.assertIn("could not read the secret_store row", result.stderr)
        self.assert_removed()

    def test_fails_on_a_failed_turn_and_shows_what_fermix_said(self) -> None:
        result = self.run_check(IMAGE, FAKE_ASK_EXIT="1", FAKE_REPLY="", FAKE_ASK_STDERR="401 Unauthorized")

        self.assertEqual(result.returncode, 1)
        self.assertIn("401 Unauthorized", result.stderr)
        self.assertIn("fermix ask failed", result.stderr)

    def test_a_warning_on_stderr_is_not_a_reply(self) -> None:
        result = self.run_check(IMAGE, FAKE_REPLY="", FAKE_ASK_STDERR="warning: slow provider")

        self.assertEqual(result.returncode, 1)
        self.assertIn("empty reply", result.stderr)

    def test_fails_on_an_empty_reply(self) -> None:
        result = self.run_check(IMAGE, FAKE_REPLY=" \n ")

        self.assertEqual(result.returncode, 1)
        self.assertIn("empty reply", result.stderr)
        self.assert_removed()

    def test_refuses_to_run_without_exactly_one_image(self) -> None:
        for args in ((), (IMAGE, "extra"), ("--help",)):
            with self.subTest(args=args):
                result = self.run_check(*args)

                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
