#!/usr/bin/env python3
"""Hermetic tests for the post-publication installer check."""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("verify_installer.sh")

VERSION = "9.9.9"
IDENTITY = f"https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v{VERSION}"

# The feed the stand-in curl serves, and a count of how often it was asked.
FAKE_CURL = """#!/bin/sh
printf 'curl\\n' >> "$FAKE_LOG"
[ "${FAKE_CURL_EXIT:-0}" -eq 0 ] || exit "$FAKE_CURL_EXIT"
printf '%s\\n' "$FAKE_FEED"
"""

FAKE_SLEEP = """#!/bin/sh
printf 'sleep %s\\n' "$*" >> "$FAKE_LOG"
"""

FAKE_INSTALLER = """#!/bin/sh
printf 'installer %s\\n' "$*" >> "$FAKE_LOG"
printf '%s\\n' "$FAKE_TRANSCRIPT"
exit "${FAKE_INSTALLER_EXIT:-0}"
"""

FAKE_DPKG_QUERY = """#!/bin/sh
printf '%s' "$FAKE_INSTALLED_VERSION"
"""

FAKE_ENGINE = """#!/bin/sh
printf 'fermix %s\\n' "$FAKE_ENGINE_VERSION"
"""

FAKE_DOCKER = """#!/bin/sh
printf 'docker %s\\n' "$*" >> "$FAKE_LOG"
printf '%s\\n' "$FAKE_TRANSCRIPT"
exit "${FAKE_DOCKER_EXIT:-0}"
"""


def transcript(kind="deb", manager="apt", verified=True):
    lines = [f"==> Detected target: linux-x86_64 ({kind} package, installed with {manager})"]
    if verified:
        lines.append(f"==> Signature verified against {IDENTITY}")
    lines.append("Done. fermix is installed at /usr/bin/fermix.")
    return "\n".join(lines)


class VerifyInstallerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-verify-installer-")
        # Resolved, because the script resolves its own location and macOS keeps
        # its temporary directories behind a symbolic link.
        self.base = Path(self.tmp.name).resolve()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.log = self.base / "log"
        self.log.touch()

        # PATH holds nothing but this directory, so a cosign or a docker the
        # host happens to have can never answer for the test.
        for tool in ("dirname", "seq", "sh"):
            path = shutil.which(tool)
            self.assertIsNotNone(path, f"{tool} is required to run the check")
            (self.bin / tool).symlink_to(path)
        self._fake("python3", f'#!/bin/sh\nexec "{sys.executable}" "$@"\n')

        # The script finds the installer beside itself, so it runs from a tree
        # whose installer is this test's.
        self.script = self.base / "tree/scripts/release/verify_installer.sh"
        self.script.parent.mkdir(parents=True)
        shutil.copy(SCRIPT, self.script)
        self._write(self.base / "tree/scripts/install.sh", FAKE_INSTALLER)

        self._fake("curl", FAKE_CURL)
        self._fake("sleep", FAKE_SLEEP)
        self._fake("cosign", "#!/bin/sh\nexit 0\n")
        self._fake("dpkg-query", FAKE_DPKG_QUERY)
        self._fake("fermix", FAKE_ENGINE)
        self._fake("docker", FAKE_DOCKER)

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_deb_row_installs_twice_and_the_second_run_changes_nothing(self):
        # One transcript answers both runs, so it carries both runs' words.
        result = self._run(
            "deb", transcript=transcript() + f"\nfermix {VERSION} is already installed"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [call for call in self._calls() if call.startswith("installer")],
            ["installer --no-setup", "installer --no-setup"],
        )

    def test_a_second_run_that_reinstalls_is_a_failure(self):
        result = self._run("deb", transcript=transcript())

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"a second run did not recognise the installed {VERSION}", result.stderr)

    def test_a_skipped_signature_check_is_a_failure(self):
        result = self._run("deb", transcript=transcript(verified=False))

        self.assertEqual(result.returncode, 1)
        self.assertIn("did not verify the package signature", result.stderr)

    def test_a_host_that_was_handed_the_standalone_binary_is_a_failure(self):
        result = self._run(
            "deb", transcript="==> Detected target: linux-x86_64 (standalone binary)"
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("did not choose the deb package", result.stderr)

    def test_the_package_database_must_name_the_release(self):
        result = self._run("deb", transcript=transcript(), installed="9.9.8")

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"dpkg reports fermix 9.9.8 installed, not {VERSION}", result.stderr)

    def test_the_engine_must_name_the_release(self):
        result = self._run("deb", transcript=transcript(), engine="9.9.8")

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"fermix --version does not contain {VERSION}", result.stderr)

    def test_an_installer_that_fails_shows_what_it_said(self):
        result = self._run(
            "deb", transcript="install.sh: sha256 mismatch", extra_env={"FAKE_INSTALLER_EXIT": "1"}
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("install.sh: sha256 mismatch", result.stdout)
        self.assertIn("the installer did not finish on this runner", result.stderr)

    def test_an_rpm_row_runs_in_fedora_with_the_runners_cosign(self):
        result = self._run(
            "rpm",
            transcript="\n".join(
                [
                    transcript("rpm", "dnf"),
                    f"installed-version={VERSION}",
                    f"engine-version=fermix {VERSION}",
                ]
            ),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        docker = [call for call in self._calls() if call.startswith("docker")]
        self.assertEqual(len(docker), 1)
        self.assertIn(f"-v {self.base}/tree/scripts/install.sh:/install.sh:ro", docker[0])
        self.assertIn(f"-v {self.bin}/cosign:/usr/local/bin/cosign:ro", docker[0])
        self.assertIn("fedora:41", docker[0])

    def test_an_rpm_row_whose_database_names_another_version_is_a_failure(self):
        result = self._run(
            "rpm",
            transcript="\n".join(
                [transcript("rpm", "dnf"), "installed-version=9.9.8", f"engine-version=fermix {VERSION}"]
            ),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"rpm does not report fermix {VERSION} installed", result.stderr)

    def test_the_wait_for_the_feed_is_bounded_and_names_what_the_feed_said(self):
        result = self._run("deb", transcript=transcript(), feed_latest="9.9.8")

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"still names '9.9.8' instead of {VERSION} after 12 checks", result.stderr)
        calls = self._calls()
        self.assertEqual(calls.count("curl"), 12)
        self.assertEqual(calls.count("sleep 10"), 11)
        self.assertEqual([call for call in calls if call.startswith("installer")], [])

    def test_a_feed_that_never_answers_is_named_as_that(self):
        result = self._run("deb", transcript=transcript(), extra_env={"FAKE_CURL_EXIT": "22"})

        self.assertEqual(result.returncode, 1)
        self.assertIn("could not be fetched", result.stderr)
        self.assertEqual(self._calls().count("curl"), 12)

    def test_cosign_is_required_so_the_check_cannot_be_skipped(self):
        (self.bin / "cosign").unlink()

        result = self._run("deb", transcript=transcript())

        self.assertEqual(result.returncode, 1)
        self.assertIn("cosign is required", result.stderr)

    def test_usage_and_unknown_kinds_are_refused(self):
        self.assertEqual(self._run_raw([]).returncode, 2)
        result = self._run_raw(["pkg", VERSION])
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsupported package kind: pkg", result.stderr)

    def _run(self, kind, transcript, installed=VERSION, engine=VERSION, feed_latest=VERSION, extra_env=None):
        return self._run_raw(
            [kind, VERSION],
            {
                "FAKE_TRANSCRIPT": transcript,
                "FAKE_INSTALLED_VERSION": installed,
                "FAKE_ENGINE_VERSION": engine,
                "FAKE_FEED": json.dumps({"schema_version": 1, "latest": feed_latest}),
                **(extra_env or {}),
            },
        )

    def _run_raw(self, arguments, extra_env=None):
        environment = {"PATH": str(self.bin), "FAKE_LOG": str(self.log), **(extra_env or {})}
        return subprocess.run(
            [shutil.which("bash"), str(self.script), *arguments],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def _calls(self):
        return self.log.read_text(encoding="utf-8").splitlines()

    def _fake(self, name, body):
        self._write(self.bin / name, body)

    def _write(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
