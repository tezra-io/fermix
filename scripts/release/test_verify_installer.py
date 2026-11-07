#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for the post-publication installer check."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("verify_installer.sh")

VERSION = "9.9.9"
TABLE_URL = "https://fermix.ai/install/releases"
PACKAGE_URL = f"https://github.com/tezra-io/fermix/releases/download/v{VERSION}/fermix_{VERSION}_amd64.deb"
SCRIPT_URL = f"https://github.com/tezra-io/fermix/releases/download/v{VERSION}/fermix_always_on.sh"
TABLE = (
    f"format 1\nlatest {VERSION}\n{VERSION} {'a' * 64} fermix_{VERSION}_amd64.deb\n"
    f"{VERSION} {'b' * 64} fermix_always_on.sh\n"
)

# The real curl, as far as the check is concerned: it logs every call, so a
# request for the table that reached it would show.
FAKE_CURL = """#!/bin/sh
printf 'curl %s\\n' "$*" >> "$FAKE_LOG"
"""

# Asks curl for the table and for a release file, the two things the real
# installer fetches, then says what the test tells it to: with --always-on the
# file is the Always On server script, and the words and the exit are the
# server script's run as far as the test says.
FAKE_INSTALLER = f"""#!/bin/sh
printf 'installer %s\\n' "$*" >> "$FAKE_LOG"
curl -fsSL {TABLE_URL} -o "$FAKE_TABLE_COPY" || exit 90
if [ "$1" = --always-on ]; then
  curl -fsSL {SCRIPT_URL} -o /dev/null || exit 91
  printf '%s\\n' "$FAKE_ALWAYS_ON_TRANSCRIPT"
  exit "${{FAKE_ALWAYS_ON_EXIT:-1}}"
fi
curl -fsSL {PACKAGE_URL} -o /dev/null || exit 91
printf '%s\\n' "$FAKE_TRANSCRIPT"
exit "${{FAKE_INSTALLER_EXIT:-0}}"
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


def always_on_transcript(verified=True, refused=True, release_named=True):
    """The installer's --always-on on an account that is not root."""
    lines = [f"==> Fetching release digests from {TABLE_URL}..."]
    if verified:
        lines.append(f"==> Verified sha256 {'b' * 64} against {TABLE_URL} (fermix_always_on.sh, release {VERSION})")
    if refused:
        lines.append(
            "fermix always-on: Run this as root: curl -fsSL https://fermix.ai/install | sudo sh -s -- "
            "--always-on" + (f" --version {VERSION}" if release_named else "")
        )
    return "\n".join(lines)


def transcript(kind="deb", manager="apt", verified=True):
    name = f"fermix_{VERSION}_amd64.deb" if kind == "deb" else f"fermix-{VERSION}-1.x86_64.rpm"
    lines = [f"==> Detected target: linux-x86_64 ({kind} package, installed with {manager})"]
    if verified:
        lines.append(f"==> Verified sha256 {'a' * 64} against {TABLE_URL} ({name}, release {VERSION})")
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
        self.table = self.base / "releases"
        self.table.write_text(TABLE, encoding="utf-8")
        self.table_copy = self.base / "table-the-installer-saw"

        # PATH holds nothing but this directory, so a curl or a docker the host
        # happens to have can never answer for the test.
        for tool in ("cat", "chmod", "cp", "dirname", "mkdir", "mktemp", "rm", "sh"):
            path = shutil.which(tool)
            self.assertIsNotNone(path, f"{tool} is required to run the check")
            (self.bin / tool).symlink_to(path)

        # The script finds the installer beside itself, so it runs from a tree
        # whose installer is this test's.
        self.script = self.base / "tree/scripts/release/verify_installer.sh"
        self.script.parent.mkdir(parents=True)
        shutil.copy(SCRIPT, self.script)
        self._write(self.base / "tree/scripts/install.sh", FAKE_INSTALLER)

        self._fake("curl", FAKE_CURL)
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
            ["installer --no-setup", "installer --no-setup", "installer --always-on"],
        )

    def test_the_installer_reads_the_rails_table_and_the_release_from_the_real_curl(self):
        result = self._run(
            "deb", transcript=transcript() + f"\nfermix {VERSION} is already installed"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.table_copy.read_text(encoding="utf-8"), TABLE)
        curls = [call for call in self._calls() if call.startswith("curl")]
        self.assertEqual(
            curls, [f"curl -fsSL {PACKAGE_URL} -o /dev/null"] * 2 + [f"curl -fsSL {SCRIPT_URL} -o /dev/null"]
        )

    # The release's Always On server script, run through --always-on as far
    # as its first refusal: the runner's account is not root.
    def test_a_deb_row_runs_always_on_as_far_as_the_server_scripts_first_refusal(self):
        result = self._run(
            "deb", transcript=transcript() + f"\nfermix {VERSION} is already installed"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fermix always-on: Run this as root", result.stdout)

    def test_an_always_on_run_that_did_not_check_the_script_is_a_failure(self):
        result = self._run(
            "deb",
            transcript=transcript() + f"\nfermix {VERSION} is already installed",
            extra_env={"FAKE_ALWAYS_ON_TRANSCRIPT": always_on_transcript(verified=False)},
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            f"did not check the Always On server script against the digest {TABLE_URL} lists for {VERSION}",
            result.stderr,
        )

    def test_an_always_on_run_that_did_not_stop_at_the_root_refusal_is_a_failure(self):
        for case, extra_env in (
            ("another refusal", {"FAKE_ALWAYS_ON_TRANSCRIPT": always_on_transcript(refused=False)}),
            # The installer hands the script its release, which the refusal's
            # command then names.
            ("a refusal without the release", {"FAKE_ALWAYS_ON_TRANSCRIPT": always_on_transcript(release_named=False)}),
            ("no refusal", {"FAKE_ALWAYS_ON_EXIT": "0"}),
        ):
            with self.subTest(case=case):
                result = self._run(
                    "deb", transcript=transcript() + f"\nfermix {VERSION} is already installed", extra_env=extra_env
                )

                self.assertEqual(result.returncode, 1)
                self.assertIn("first refusal", result.stderr)

    def test_a_second_run_that_reinstalls_is_a_failure(self):
        result = self._run("deb", transcript=transcript())

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"a second run did not recognise the installed {VERSION}", result.stderr)

    def test_an_install_that_did_not_check_the_digest_is_a_failure(self):
        result = self._run("deb", transcript=transcript(verified=False))

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"did not check the deb package against the digest {TABLE_URL} lists", result.stderr)

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

    def test_an_rpm_row_runs_in_fedora_with_the_rails_table_in_front_of_its_curl(self):
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
        self.assertIn(f"-v {self.table}:/fermix-install-releases:ro", docker[0])
        self.assertRegex(docker[0], r"-v /\S+/container-curl:/usr/local/bin/curl:ro")
        self.assertIn("fedora:41", docker[0])

    def test_the_containers_stand_in_answers_the_table_and_passes_the_rest_to_its_curl(self):
        stand_in = self._stand_in_for_the_container()

        # The same generator as the deb row's, which the tests above run for
        # real; here only its two addresses differ.
        self.assertIn('exec cp "/fermix-install-releases" "$output"', stand_in)
        self.assertIn('exec "/usr/bin/curl" "$@"', stand_in)
        self.assertIn(f'[ "$argument" != "{TABLE_URL}" ] || asks_for_table=1', stand_in)

    def test_an_rpm_row_whose_database_names_another_version_is_a_failure(self):
        result = self._run(
            "rpm",
            transcript="\n".join(
                [transcript("rpm", "dnf"), "installed-version=9.9.8", f"engine-version=fermix {VERSION}"]
            ),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"rpm does not report fermix {VERSION} installed", result.stderr)

    def test_a_table_for_another_release_is_refused_before_installing(self):
        for text in (f"format 1\nlatest 9.9.8\n", "latest 9.9.9\nformat 1\n", "format 1\n", ""):
            with self.subTest(table=text):
                self.log.write_text("", encoding="utf-8")
                self.table.write_text(text, encoding="utf-8")

                result = self._run("deb", transcript=transcript())

                self.assertEqual(result.returncode, 1)
                self.assertIn(f"the digest table at {self.table}", result.stderr)
                self.assertEqual(self._calls(), [])

    def test_a_missing_table_is_refused(self):
        self.table.unlink()

        result = self._run("deb", transcript=transcript())

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"digest table not found: {self.table}", result.stderr)
        self.assertEqual(self._calls(), [])

    def test_usage_and_unknown_kinds_are_refused(self):
        self.assertEqual(self._run_raw([]).returncode, 2)
        self.assertEqual(self._run_raw(["deb", VERSION]).returncode, 2)
        result = self._run_raw(["pkg", VERSION, str(self.table)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsupported package kind: pkg", result.stderr)

    def _stand_in_for_the_container(self):
        """The stand-in the rpm row mounts, kept by a docker that copies it out."""
        kept = self.base / "kept-container-curl"
        self._fake(
            "docker",
            "#!/bin/sh\n"
            'for argument in "$@"; do\n'
            '  case "$argument" in *:/usr/local/bin/curl:ro) cp "${argument%%:*}" "$FAKE_KEPT" ;; esac\n'
            "done\n"
            "exit 1\n",
        )
        self._run("rpm", transcript="", extra_env={"FAKE_KEPT": str(kept)})
        return kept.read_text(encoding="utf-8")

    def _run(self, kind, transcript, installed=VERSION, engine=VERSION, extra_env=None):
        return self._run_raw(
            [kind, VERSION, str(self.table)],
            {
                "FAKE_TRANSCRIPT": transcript,
                "FAKE_ALWAYS_ON_TRANSCRIPT": always_on_transcript(),
                "FAKE_INSTALLED_VERSION": installed,
                "FAKE_ENGINE_VERSION": engine,
                "FAKE_TABLE_COPY": str(self.table_copy),
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
