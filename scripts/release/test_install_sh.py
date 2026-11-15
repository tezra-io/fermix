#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for scripts/install.sh, the script served at fermix.ai/install.

Nothing here reaches the network, a package manager or /usr: the script runs
with a PATH that holds only this test's stand-ins (and the handful of real
POSIX tools it needs), and the one absolute package path it names is pointed
at a directory this test owns.

The installer trusts one document: the digest table fermix.ai serves at
/install/releases. The fake remote serves that table beside the release files,
so every refusal below is a table that is missing, malformed or disagrees with
the download, and each one must stop before anything runs as root.
"""

import hashlib
import os
import pty
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "scripts/install.sh"
TABLE_BUILDER = ROOT / "scripts/release/build_install_table.sh"

VERSION = "9.9.9"
OLDER = "9.9.8"
ORIGIN = "https://github.com/tezra-io/fermix/releases/download"
TABLE_URL = "https://fermix.ai/install/releases"

# The real tools the installer may call. Everything else on PATH is a stand-in,
# so a host's own apt-get, rpm or cosign can never answer for the test. `install`
# is real too, behind a stand-in that writes each call to the log first, and so
# is `sh`, which runs the Always On server script.
REAL_TOOLS = ("awk", "basename", "cat", "chmod", "cp", "dirname", "mkdir", "mktemp", "rm", "sh")

STANDALONE_TARGETS = ("linux-x86_64", "linux-aarch64", "macos-aarch64", "macos-x86_64")
PACKAGE_TARGETS = ("linux-x86_64", "linux-aarch64")

# Calls that install or reach root. A refusal must leave none of them in the log.
INSTALLING = ("sudo ", "apt-get ", "dnf ", "zypper ", "dpkg ", "install ")

FAKE_UNAME = """#!/bin/sh
case "$1" in
  -s) printf '%s\\n' "$FAKE_UNAME_S" ;;
  -m) printf '%s\\n' "$FAKE_UNAME_M" ;;
  *) exit 2 ;;
esac
"""

# `curl -fsSL <url> -o <path>`: a URL is a file under $FAKE_REMOTE, and a URL
# with no file is the 404 that `curl -f` turns into exit 22.
FAKE_CURL = """#!/bin/sh
set -eu
url=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf 'curl %s\\n' "$url" >> "$FAKE_LOG"
source="$FAKE_REMOTE/${url#https://}"
[ -f "$source" ] || exit 22
cat "$source" > "$output"
"""

FAKE_ID = """#!/bin/sh
[ "$1" = "-u" ] || exit 2
printf '%s\\n' "$FAKE_UID"
"""

FAKE_SUDO = """#!/bin/sh
printf 'sudo %s\\n' "$*" >> "$FAKE_LOG"
exec "$@"
"""

# The three package managers share one stand-in: it records how it was called,
# then "installs" by putting an engine where the package would.
FAKE_PACKAGE_MANAGER = """#!/bin/sh
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$FAKE_LOG"
[ "${FAKE_PACKAGE_MANAGER_EXIT:-0}" -eq 0 ] || exit "$FAKE_PACKAGE_MANAGER_EXIT"
mkdir -p "$FAKE_ROOT/usr/bin"
cp "$FAKE_ENGINE" "$FAKE_ROOT/usr/bin/fermix"
"""

FAKE_DPKG = """#!/bin/sh
printf 'dpkg %s\\n' "$*" >> "$FAKE_LOG"
"""

FAKE_DPKG_QUERY = """#!/bin/sh
[ -n "${FAKE_INSTALLED_VERSION:-}" ] || exit 1
printf '%s %s\\n' "${FAKE_INSTALLED_STATUS:-installed}" "$FAKE_INSTALLED_VERSION"
"""

# rpm says "not installed" on standard output, which is the trap the installer
# has to step around. Every call is logged, so an `rpm -i` would show.
FAKE_RPM = """#!/bin/sh
printf 'rpm %s\\n' "$*" >> "$FAKE_LOG"
if [ -z "${FAKE_INSTALLED_VERSION:-}" ]; then
  echo "package fermix is not installed"
  exit 1
fi
case "$*" in
  *--qf*) printf '%s' "$FAKE_INSTALLED_VERSION" ;;
  *) printf 'fermix-%s-1\\n' "$FAKE_INSTALLED_VERSION" ;;
esac
"""

FAKE_COSIGN = """#!/bin/sh
printf 'cosign %s\\n' "$*" >> "$FAKE_LOG"
exit "${FAKE_COSIGN_EXIT:-0}"
"""

FAKE_ENGINE = """#!/bin/sh
if [ -t 0 ]; then terminal=yes; else terminal=no; fi
printf 'fermix %s stdin_is_terminal=%s\\n' "$*" "$terminal" >> "$FAKE_LOG"
exit "${FAKE_SETUP_EXIT:-0}"
"""

# What the fake release serves as its Always On server script: it logs each
# argument in brackets, the two secrets it inherited and its first line of
# input, signals the installer when told to, then exits as the test says. It
# writes nothing to its own output, so whatever the run prints is the
# installer's.
FAKE_SERVER_SCRIPT = """#!/bin/sh
printf 'server' >> "$FAKE_LOG"
for argument in "$@"; do printf ' [%s]' "$argument" >> "$FAKE_LOG"; done
printf '\\n' >> "$FAKE_LOG"
printf 'server code=%s key=%s\\n' "${FERMIX_ENROLL_CODE-unset}" "${TS_AUTHKEY-unset}" >> "$FAKE_LOG"
if IFS= read -r line; then input="$line"; else input=none; fi
printf 'server input=%s\\n' "$input" >> "$FAKE_LOG"
[ -z "${FAKE_SERVER_SIGNAL:-}" ] || kill -s "$FAKE_SERVER_SIGNAL" "$PPID"
exit "${FAKE_SERVER_EXIT:-0}"
"""

ALWAYS_ON = "always_on"
ALWAYS_ON_FILE = "fermix_always_on.sh"

# An invented enrollment code in the real shape; nothing in it is a secret.
INVENTED_CODE = "fxenroll1.eyJ2IjoxLCJuYW1lIjoiSW52ZW50ZWQgTWFjIiwic2VjcmV0IjoiaW52ZW50ZWQifQ"


def sha256_of(data):
    return hashlib.sha256(data).hexdigest()


def standalone_name(target):
    return "fermix_" + target.replace("-", "_", 1)


def package_name(version, target, kind):
    """The release workflow's file name for one package."""
    arch = target.split("-", 1)[1]
    if kind == "deb":
        return f"fermix_{version}_{'amd64' if arch == 'x86_64' else 'arm64'}.deb"
    return f"fermix-{version}-1.{arch}.rpm"


def release_files(version):
    """Every file the installer can fetch from one release, keyed by what it is."""
    files = {target: standalone_name(target) for target in STANDALONE_TARGETS}
    for target in PACKAGE_TARGETS:
        for kind in ("deb", "rpm"):
            files[(target, kind)] = package_name(version, target, kind)
    files[ALWAYS_ON] = ALWAYS_ON_FILE
    return files


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-installer-")
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.remote = self.base / "remote"
        self.root = self.base / "root"
        self.home = self.base / "home"
        self.log = self.base / "log"
        self.scratch = self.base / "tmp"
        for directory in (self.bin, self.remote, self.root, self.home, self.scratch):
            directory.mkdir()
        self.log.touch()

        for tool in REAL_TOOLS:
            self._link_real_tool(tool)
        self._link_real_tool("sha256sum" if shutil.which("sha256sum") else "shasum")
        real_install = shutil.which("install")
        self.assertIsNotNone(real_install, "install is required to run the installer")
        self._fake("install", f'#!/bin/sh\nprintf \'install %s\\n\' "$*" >> "$FAKE_LOG"\nexec "{real_install}" "$@"\n')

        self.engine = self.base / "fake-engine"
        self._write(self.engine, FAKE_ENGINE)
        self._fake("uname", FAKE_UNAME)
        self._fake("curl", FAKE_CURL)
        self._fake("id", FAKE_ID)
        self._fake("sudo", FAKE_SUDO)

        self.payloads = {}
        self.digests = {}
        self.script = self._sandboxed_installer()
        self._release(VERSION)
        self._publish_table(self._table())

    def tearDown(self):
        self.tmp.cleanup()

    # -- which channel a machine gets ------------------------------------

    def test_a_deb_host_installs_the_package_with_apt_through_sudo(self):
        self._host("apt")

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("linux-x86_64 (deb package, installed with apt)", result.stdout)
        calls = self._calls()
        self.assertEqual(calls[0], f"curl {TABLE_URL}")
        self.assertIn(f"curl {ORIGIN}/v{VERSION}/fermix_{VERSION}_amd64.deb", calls)
        install = self._one(calls, "apt-get ")
        # --no-remove: an installed package that pins the exact old engine
        # version stops the install instead of being removed to make room.
        self.assertRegex(install, r"^apt-get install -y --no-remove /\S+/fermix\.deb$")
        self.assertIn(f"sudo {install}", calls)
        self.assertIn(f"Done. fermix is installed at {self.root}/usr/bin/fermix.", result.stdout)

    def test_an_rpm_host_installs_with_dnf_and_root_needs_no_sudo(self):
        self._host("dnf", machine="aarch64", uid=0)

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("linux-aarch64 (rpm package, installed with dnf)", result.stdout)
        calls = self._calls()
        self.assertIn(f"curl {ORIGIN}/v{VERSION}/fermix-{VERSION}-1.aarch64.rpm", calls)
        self.assertRegex(self._one(calls, "dnf "), r"^dnf install -y /\S+/fermix\.rpm$")
        self.assertEqual([call for call in calls if call.startswith("sudo ")], [])

    def test_an_opensuse_host_installs_with_zypper_and_vouches_for_the_unsigned_rpm(self):
        self._host("zypper")

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(
            self._one(self._calls(), "zypper "),
            r"^zypper --non-interactive install --allow-unsigned-rpm /\S+/fermix\.rpm$",
        )

    def test_a_host_with_no_package_manager_gets_the_standalone_binary_and_is_told_so(self):
        self._host(None)
        prefix = self.base / "prefix"
        prefix.mkdir()

        result = self._run("--prefix", str(prefix))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("linux-x86_64 (standalone binary)", result.stdout)
        self.assertIn("No apt, dnf or zypper on this machine", result.stdout)
        self.assertIn("fermix upgrade", result.stdout)
        self.assertIn(f"curl {ORIGIN}/v{VERSION}/fermix_linux_x86_64", self._calls())
        self.assertEqual((prefix / "fermix").read_bytes(), self.payloads[(VERSION, "linux-x86_64")])

    def test_standalone_flag_installs_the_binary_on_a_package_host(self):
        self._host("apt")
        prefix = self.base / "prefix"
        prefix.mkdir()

        result = self._run("--standalone", "--prefix", str(prefix))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((prefix / "fermix").read_bytes(), self.payloads[(VERSION, "linux-x86_64")])
        self.assertEqual([call for call in self._calls() if call.startswith("apt-get")], [])
        self.assertNotIn("No apt, dnf or zypper", result.stdout)

    def test_macos_gets_the_standalone_binary_whatever_else_is_installed(self):
        self._host("apt", system="Darwin", machine="arm64")
        prefix = self.base / "prefix"
        prefix.mkdir()

        result = self._run("--prefix", str(prefix))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("macos-aarch64 (standalone binary)", result.stdout)
        self.assertEqual((prefix / "fermix").read_bytes(), self.payloads[(VERSION, "macos-aarch64")])
        self.assertEqual([call for call in self._calls() if call.startswith("apt-get")], [])

    def test_a_failed_package_install_is_not_retried_as_a_standalone_one(self):
        self._host("apt")

        result = self._run(extra_env={"FAKE_PACKAGE_MANAGER_EXIT": "100"})

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Done.", result.stdout)
        fetched = [call for call in self._calls() if call.startswith("curl ")]
        self.assertEqual(
            fetched,
            [f"curl {TABLE_URL}", f"curl {ORIGIN}/v{VERSION}/fermix_{VERSION}_amd64.deb"],
        )

    # -- where the trust comes from --------------------------------------------

    def test_only_the_digest_table_and_the_release_files_are_fetched(self):
        # A cosign on the machine changes nothing: the digest fermix.ai lists is
        # the one check, so no signature, certificate or GitHub manifest is read.
        self._fake("cosign", FAKE_COSIGN)
        for manager, machine in (("apt", "x86_64"), ("dnf", "aarch64"), (None, "x86_64")):
            with self.subTest(manager=manager):
                self.log.write_text("", encoding="utf-8")
                self._host(manager, machine=machine)
                prefix = self.base / f"prefix-{manager}"
                prefix.mkdir()
                arguments = () if manager else ("--prefix", str(prefix))

                result = self._run(*arguments)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"against {TABLE_URL}", result.stdout)
                fetched = [call.removeprefix("curl ") for call in self._calls() if call.startswith("curl ")]
                self.assertEqual(fetched[0], TABLE_URL)
                self.assertEqual(len(fetched), 2, fetched)
                self.assertTrue(fetched[1].startswith(f"{ORIGIN}/v{VERSION}/"), fetched)
                self.assertFalse(fetched[1].endswith((".sig", ".pem", ".sha256", "releases.json")))
                self.assertEqual([call for call in self._calls() if call.startswith("cosign")], [])

    # -- refusals: each stops before any download, sudo or package manager ---

    def test_prefix_is_refused_where_a_package_is_installed(self):
        self._host("apt")

        result = self._run("--prefix", str(self.base))

        self.assertEqual(result.returncode, 1)
        self.assertIn("--prefix places the standalone binary", result.stderr)
        self.assertIn("--standalone", result.stderr)
        self.assertEqual(self._calls(), [])

    def test_no_table_installs_nothing(self):
        (self.remote / TABLE_URL.removeprefix("https://")).unlink()
        for manager in ("apt", "dnf", None):
            with self.subTest(manager=manager):
                self.log.write_text("", encoding="utf-8")
                self._host(manager)

                result = self._run()

                self.assertEqual(result.returncode, 1)
                self.assertIn(f"could not fetch the release digests from {TABLE_URL}", result.stderr)
                self.assertEqual(self._calls(), [f"curl {TABLE_URL}"])

    def test_a_table_in_an_unknown_format_installs_nothing(self):
        rows = self._table().split("\n", 1)[1]
        for text in ("format 2\n" + rows, rows, "", "<!doctype html>\n<p>Not found</p>\n", " format 1\n" + rows):
            with self.subTest(first_line=text.split("\n", 1)[0]):
                self.log.write_text("", encoding="utf-8")
                self._host("apt")
                self._publish_table(text)

                result = self._run()

                self.assertEqual(result.returncode, 1)
                self.assertIn(f"{TABLE_URL} is not in a format this installer reads", result.stderr)
                self._assert_refused_before_downloading()

    def test_a_table_without_a_latest_release_installs_nothing(self):
        for latest in (None, "v9.9.9", "9.9", ""):
            with self.subTest(latest=latest):
                self.log.write_text("", encoding="utf-8")
                self._host("apt")
                self._publish_table(self._table(latest=latest))

                result = self._run()

                self.assertEqual(result.returncode, 1)
                self.assertIn(f"{TABLE_URL} names no latest release", result.stderr)
                self._assert_refused_before_downloading()

    def test_a_named_release_with_no_row_installs_nothing(self):
        for manager in ("apt", None):
            with self.subTest(manager=manager):
                self.log.write_text("", encoding="utf-8")
                self._host(manager)

                result = self._run("--version", "9.9.7")

                self.assertEqual(result.returncode, 1)
                self.assertIn(f"{TABLE_URL} lists no release 9.9.7", result.stderr)
                self._assert_refused_before_downloading()

    def test_a_file_with_no_row_installs_nothing(self):
        for manager, system, machine, key in (
            ("apt", "Linux", "x86_64", ("linux-x86_64", "deb")),
            ("dnf", "Linux", "aarch64", ("linux-aarch64", "rpm")),
            ("zypper", "Linux", "x86_64", ("linux-x86_64", "rpm")),
            (None, "Linux", "aarch64", "linux-aarch64"),
            (None, "Darwin", "arm64", "macos-aarch64"),
        ):
            with self.subTest(file=release_files(VERSION)[key]):
                self.log.write_text("", encoding="utf-8")
                self._host(manager, system=system, machine=machine)
                self._publish_table(self._table(drop={(VERSION, key)}))

                result = self._run()

                self.assertEqual(result.returncode, 1)
                self.assertIn(
                    f"{TABLE_URL} lists no single sha256 for {release_files(VERSION)[key]} of release {VERSION}",
                    result.stderr,
                )
                if manager:
                    self.assertIn("--standalone", result.stderr)
                self._assert_refused_before_downloading()

    def test_a_file_listed_twice_installs_nothing(self):
        self._host("apt")
        name = release_files(VERSION)[("linux-x86_64", "deb")]
        self._publish_table(self._table() + f"{VERSION} {'0' * 64} {name}\n")

        result = self._run()

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"lists no single sha256 for {name}", result.stderr)
        self._assert_refused_before_downloading()

    def test_a_row_that_is_not_a_sha256_installs_nothing(self):
        self._host("apt")
        self._publish_table(self._table(digests={(VERSION, ("linux-x86_64", "deb")): "ABC123"}))

        result = self._run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("lists no single sha256", result.stderr)
        self._assert_refused_before_downloading()

    def test_a_digest_mismatch_installs_nothing(self):
        for manager, system, machine, key in (
            ("apt", "Linux", "x86_64", ("linux-x86_64", "deb")),
            ("zypper", "Linux", "x86_64", ("linux-x86_64", "rpm")),
            (None, "Linux", "x86_64", "linux-x86_64"),
            (None, "Darwin", "arm64", "macos-aarch64"),
        ):
            with self.subTest(file=release_files(VERSION)[key]):
                self.log.write_text("", encoding="utf-8")
                self._host(manager, system=system, machine=machine)
                self._publish_table(self._table(digests={(VERSION, key): "0" * 64}))
                prefix = self.base / "prefix"
                prefix.mkdir(exist_ok=True)
                arguments = () if manager else ("--prefix", str(prefix))

                result = self._run(*arguments)

                self.assertEqual(result.returncode, 1)
                self.assertIn(f"sha256 mismatch: expected {'0' * 64}", result.stderr)
                self.assertIn(f"is not the file {TABLE_URL} lists", result.stderr)
                self._assert_nothing_installed()
                self.assertFalse((prefix / "fermix").exists())

    def test_an_account_with_neither_root_nor_sudo_is_told_what_to_do(self):
        self._host("apt")
        (self.bin / "sudo").unlink()

        result = self._run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("needs root", result.stderr)
        self.assertIn("--standalone", result.stderr)

    # -- what happens after the package is on disk ----------------------------

    def test_the_latest_version_already_installed_downloads_nothing(self):
        self._host("apt")

        result = self._run(extra_env={"FAKE_INSTALLED_VERSION": VERSION})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"fermix {VERSION} is already installed", result.stdout)
        self.assertIn("fermix setup", result.stdout)
        self.assertEqual(self._calls(), [f"curl {TABLE_URL}"])

    def test_a_removed_package_dpkg_still_remembers_is_installed_afresh(self):
        self._host("apt")

        result = self._run(
            extra_env={"FAKE_INSTALLED_VERSION": VERSION, "FAKE_INSTALLED_STATUS": "config-files"}
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("already installed", result.stdout)
        self._one(self._calls(), "apt-get ")

    def test_rpm_saying_not_installed_is_not_read_as_a_version(self):
        self._host("dnf")

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Updated fermix", result.stdout)
        self.assertNotIn("is not installed", result.stdout)

    def test_an_update_starts_no_setup_and_names_the_restart(self):
        for manager in ("apt", "dnf"):
            with self.subTest(manager=manager):
                self.log.write_text("", encoding="utf-8")
                self._host(manager)

                result = self._run(extra_env={"FAKE_INSTALLED_VERSION": "9.9.8"}, terminal=True)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Updated fermix 9.9.8 to {VERSION}", result.stdout)
                self.assertIn("fermix restart", result.stdout)
                self.assertEqual([call for call in self._calls() if call.startswith("fermix ")], [])

    def test_an_earlier_install_ahead_on_path_is_named_and_setup_is_not_started(self):
        self._host("apt")
        self._fake("fermix", FAKE_ENGINE)

        result = self._run(terminal=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"typing fermix on this account runs {self.bin}/fermix", result.stdout)
        self.assertIn(
            "https://fermix.ai/docs/linux-packages#move-from-a-standalone-install", result.stdout
        )
        self.assertEqual([call for call in self._calls() if call.startswith("fermix ")], [])

    def test_the_package_binary_reached_by_another_spelling_is_not_an_earlier_install(self):
        self._host("apt")
        (self.bin / "fermix").symlink_to(self.root / "usr/bin/fermix")

        result = self._run(terminal=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("an earlier install", result.stdout)
        self._one(self._calls(), "fermix setup")

    def test_under_sudo_setup_is_left_to_the_account_that_will_own_the_service(self):
        self._host("apt", uid=0)

        result = self._run(extra_env={"SUDO_USER": "ada"}, terminal=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Run setup as ada, without sudo: fermix setup", result.stdout)
        self.assertEqual([call for call in self._calls() if call.startswith("fermix ")], [])

    def test_no_setup_flag_names_the_next_command(self):
        self._host("apt")

        result = self._run("--no-setup", terminal=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Skipping fermix setup (--no-setup)", result.stdout)
        self.assertEqual([call for call in self._calls() if call.startswith("fermix ")], [])

    def test_setup_is_handed_the_terminal_when_the_script_arrives_on_a_pipe(self):
        self._host("apt")

        result = self._run(terminal=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._one(self._calls(), "fermix "), "fermix setup stdin_is_terminal=yes"
        )

    def test_with_no_terminal_setup_is_named_instead_of_started(self):
        self._host("apt")

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No terminal is attached", result.stdout)
        self.assertIn("fermix setup", result.stdout)
        self.assertEqual([call for call in self._calls() if call.startswith("fermix ")], [])

    def test_a_setup_that_does_not_finish_says_the_package_is_installed(self):
        self._host("apt")

        result = self._run(extra_env={"FAKE_SETUP_EXIT": "1"}, terminal=True)

        self.assertEqual(result.returncode, 1)
        self.assertIn("fermix is installed, but 'fermix setup' did not finish", result.stderr)

    # -- a named release ---------------------------------------------------------
    #
    # Always On's servers run exactly their desktop's Fermix (move back, design
    # §6): first boot and its updates install a named release, never
    # the latest.

    def test_a_named_release_is_installed_from_its_own_row(self):
        self._host("apt")
        self._release(OLDER)
        self._publish_table(self._table(releases=(VERSION, OLDER)))

        result = self._run("--version", OLDER)

        self.assertEqual(result.returncode, 0, result.stderr)
        fetched = [call for call in self._calls() if call.startswith("curl ")]
        self.assertEqual(
            fetched, [f"curl {TABLE_URL}", f"curl {ORIGIN}/v{OLDER}/fermix_{OLDER}_amd64.deb"]
        )
        self._one(self._calls(), "apt-get ")

    def test_a_named_release_already_installed_downloads_nothing(self):
        self._host("apt")

        result = self._run("--version", VERSION, extra_env={"FAKE_INSTALLED_VERSION": VERSION})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"fermix {VERSION} is already installed.", result.stdout)
        self.assertNotIn("latest release", result.stdout)
        self.assertEqual(self._calls(), [f"curl {TABLE_URL}"])

    def test_an_older_install_is_updated_to_the_named_release(self):
        self._host("apt")

        result = self._run("--version", VERSION, extra_env={"FAKE_INSTALLED_VERSION": OLDER})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Updated fermix {OLDER} to {VERSION}", result.stdout)

    def test_a_named_release_that_is_not_a_version_is_refused_before_anything_is_fetched(self):
        for version in ("latest", "v9.9.9", "9.9", "9.9.9-rc.1", ""):
            with self.subTest(version=version):
                self.log.write_text("", encoding="utf-8")
                self._host("apt")

                result = self._run("--version", version)

                self.assertEqual(result.returncode, 2)
                self.assertIn("--version takes a release, such as 0.17.0", result.stderr)
                self.assertEqual(self._calls(), [])

    def test_an_unknown_argument_without_always_on_is_refused_as_before(self):
        self._host("apt")

        result = self._run("--tailscale")

        self.assertEqual(result.returncode, 2)
        self.assertIn("install.sh: unknown argument: --tailscale", result.stderr)
        self.assertIn("Usage: install.sh", result.stdout)
        self.assertEqual(self._calls(), [])

    def test_without_always_on_an_unknown_argument_is_refused_where_it_stands(self):
        self._host("apt")
        for arguments in (("--bogus", "--help"), ("--bogus", "--prefix"), ("--bogus", "--version", "0.17")):
            with self.subTest(arguments=arguments):
                result = self._run(*arguments)

                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stderr, "install.sh: unknown argument: --bogus\n")
                self.assertEqual(self._calls(), [])

        result = self._run("--help", "--bogus")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage: install.sh", result.stdout)

    def test_prefix_without_a_value_is_refused_in_the_installers_own_words(self):
        self._host(None)
        for arguments in (("--prefix",), ("--prefix", ""), ("--standalone", "--prefix")):
            with self.subTest(arguments=arguments):
                result = self._run(*arguments)

                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stderr, "install.sh: --prefix requires a value\n")
                self.assertEqual(self._calls(), [])

    # -- an Always On server (--always-on) ---------------------------------------
    #
    # Each release publishes its Always On server script, a byte copy of
    # packaging/cloud/first-boot.sh. The installer checks it against the table
    # exactly as it checks a package, then runs it with the release named; the
    # host checks are the script's own.

    def test_always_on_runs_the_verified_server_script_with_the_release_and_the_rest_unchanged(self):
        self._host("apt", uid=0)

        result = self._run(
            "--always-on",
            "--tailscale",
            "--version",
            VERSION,
            "--snapshot-bucket",
            "two words",
            "--snapshot-region",
            "it's",
            extra_env={"FERMIX_ENROLL_CODE": INVENTED_CODE, "TS_AUTHKEY": "tskey-auth-invented"},
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._server_calls(),
            [
                f"server [--version] [{VERSION}] [--tailscale] [--snapshot-bucket] [two words] "
                "[--snapshot-region] [it's]",
                f"server code={INVENTED_CODE} key=tskey-auth-invented",
                "server input=none",
            ],
        )
        fetched = [call for call in self._calls() if call.startswith("curl ")]
        self.assertEqual(fetched, [f"curl {TABLE_URL}", f"curl {ORIGIN}/v{VERSION}/{ALWAYS_ON_FILE}"])
        self.assertIn(
            f"==> Verified sha256 {self.digests[(VERSION, ALWAYS_ON)]} against {TABLE_URL} "
            f"({ALWAYS_ON_FILE}, release {VERSION})",
            result.stdout,
        )
        self._assert_nothing_installed()
        self._assert_no_download_left()

    def test_always_on_hands_the_script_the_latest_release_unless_one_is_named(self):
        self._release(OLDER)
        self._publish_table(self._table(releases=(VERSION, OLDER)))
        for arguments, release in ((("--always-on",), VERSION), (("--version", OLDER, "--always-on"), OLDER)):
            with self.subTest(arguments=arguments):
                self.log.write_text("", encoding="utf-8")
                self._host("apt", uid=0)

                result = self._run(*arguments)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self._server_calls()[0], f"server [--version] [{release}]")
                self.assertIn(f"curl {ORIGIN}/v{release}/{ALWAYS_ON_FILE}", self._calls())

    def test_always_on_exits_with_the_server_scripts_own_status(self):
        for status in (0, 1, 7):
            with self.subTest(status=status):
                self.log.write_text("", encoding="utf-8")
                self._host("apt", uid=0)

                result = self._run("--always-on", extra_env={"FAKE_SERVER_EXIT": str(status)})

                self.assertEqual(result.returncode, status, result.stderr)
                self._assert_no_download_left()

    def test_always_on_leaves_every_host_check_to_the_server_script(self):
        # Neither the system, the architecture, the account nor the package
        # manager is the installer's to refuse here.
        self._host(None, system="Darwin", machine="riscv64", uid=1000)

        result = self._run("--always-on")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._server_calls()[0], f"server [--version] [{VERSION}]")
        self.assertNotIn("Detected target", result.stdout)

    def test_always_on_passes_what_it_does_not_own_on_unread_and_never_echoes_it(self):
        self._host("apt", uid=0)

        result = self._run("--always-on", INVENTED_CODE, extra_env={"FAKE_SERVER_EXIT": "1"})

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self._server_calls()[0], f"server [--version] [{VERSION}] [{INVENTED_CODE}]")
        self.assertNotIn(INVENTED_CODE, result.stdout + result.stderr)

    def test_the_server_script_never_reads_the_installers_own_input(self):
        # Under `curl | sh` the installer's input is the rest of the installer.
        self._host("apt", uid=0)

        result = self._run("--always-on", input_text="the rest of the installer\n")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("server input=none", self._server_calls())

    def test_always_on_with_an_option_for_another_install_is_refused_before_anything_is_fetched(self):
        self._host("apt", uid=0)
        for option, arguments in (
            ("--standalone", ("--always-on", "--standalone", INVENTED_CODE)),
            ("--prefix", ("--prefix", str(self.base), "--always-on", INVENTED_CODE)),
            ("--no-setup", (INVENTED_CODE, "--always-on", "--no-setup")),
        ):
            with self.subTest(option=option):
                self.log.write_text("", encoding="utf-8")

                result = self._run(*arguments)

                self.assertEqual(result.returncode, 2)
                self.assertEqual(
                    result.stderr,
                    "install.sh: --always-on runs the release's Always On server script, which "
                    "installs Fermix itself, so it takes none of --standalone, --prefix and "
                    "--no-setup.\n",
                )
                self.assertNotIn(INVENTED_CODE, result.stdout)
                self.assertEqual(self._calls(), [])

    def test_always_on_refuses_a_release_that_lists_no_server_script_before_downloading(self):
        for case, table in (
            ("no row", self._table(drop={(VERSION, ALWAYS_ON)})),
            ("two rows", self._table() + f"{VERSION} {'0' * 64} {ALWAYS_ON_FILE}\n"),
            ("not a sha256", self._table(digests={(VERSION, ALWAYS_ON): "ABC123"})),
        ):
            with self.subTest(case=case):
                self.log.write_text("", encoding="utf-8")
                self._host("apt", uid=0)
                self._publish_table(table)

                result = self._run("--always-on")

                self.assertEqual(result.returncode, 1)
                self.assertIn(
                    f"install.sh: {TABLE_URL} lists no Always On server script for release {VERSION}",
                    result.stderr,
                )
                self.assertEqual(self._calls(), [f"curl {TABLE_URL}"])
                self._assert_no_download_left()

    def test_always_on_refuses_a_named_release_the_table_does_not_list(self):
        self._host("apt", uid=0)

        result = self._run("--always-on", "--version", "9.9.7")

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{TABLE_URL} lists no release 9.9.7", result.stderr)
        self.assertEqual(self._calls(), [f"curl {TABLE_URL}"])

    def test_always_on_refuses_a_script_that_does_not_match_its_row_before_running_it(self):
        self._host("apt", uid=0)
        self._publish_table(self._table(digests={(VERSION, ALWAYS_ON): "0" * 64}))

        result = self._run("--always-on")

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"sha256 mismatch: expected {'0' * 64}", result.stderr)
        self.assertIn(f"is not the file {TABLE_URL} lists for release {VERSION}", result.stderr)
        self.assertEqual(self._server_calls(), [])
        self._assert_no_download_left()

    def test_always_on_leaves_no_download_behind_when_it_is_stopped(self):
        for signal, status in (("TERM", 143), ("INT", 130)):
            with self.subTest(signal=signal):
                self._host("apt", uid=0)

                result = self._run("--always-on", extra_env={"FAKE_SERVER_SIGNAL": signal})

                self.assertEqual(result.returncode, status, result.stderr)
                self._assert_no_download_left()

    # -- the contract with the release rail -----------------------------------
    #
    # The rail builds the same table from its own cosign-verified files and runs
    # this installer against it; the site's pin script writes the served one.

    def test_the_installer_reads_the_table_the_release_rail_builds(self):
        table = self._rail_table()
        lines = table.splitlines()
        self.assertEqual(lines[:2], ["format 1", f"latest {VERSION}"])
        self.assertEqual(
            sorted(line.split(" ")[2] for line in lines[2:]), sorted(release_files(VERSION).values())
        )

        self._publish_table(table)
        self._host("dnf", machine="aarch64")

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"curl {ORIGIN}/v{VERSION}/fermix-{VERSION}-1.aarch64.rpm", self._calls())

    def test_the_server_script_runs_from_the_table_the_release_rail_builds(self):
        self._publish_table(self._rail_table())
        self._host("apt", uid=0)

        result = self._run("--always-on")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._server_calls()[0], f"server [--version] [{VERSION}]")

    # -- fixtures --------------------------------------------------------------

    def _host(self, manager, system="Linux", machine="x86_64", uid=1000):
        """Describe the machine: its kernel, its account and its package manager."""
        self.host_env = {"FAKE_UNAME_S": system, "FAKE_UNAME_M": machine, "FAKE_UID": str(uid)}
        for name in ("dpkg", "dpkg-query", "apt-get", "rpm", "dnf", "zypper"):
            (self.bin / name).unlink(missing_ok=True)
        if manager == "apt":
            self._fake("dpkg", FAKE_DPKG)
            self._fake("dpkg-query", FAKE_DPKG_QUERY)
            self._fake("apt-get", FAKE_PACKAGE_MANAGER)
        elif manager in ("dnf", "zypper"):
            self._fake("rpm", FAKE_RPM)
            self._fake(manager, FAKE_PACKAGE_MANAGER)

    def _run(self, *arguments, extra_env=None, terminal=False, input_text=None):
        environment = {
            "PATH": str(self.bin),
            "HOME": str(self.home),
            # Where the installer's mktemp makes its directory, so a test can
            # see that nothing is left behind.
            "TMPDIR": str(self.scratch),
            "FAKE_LOG": str(self.log),
            "FAKE_REMOTE": str(self.remote),
            "FAKE_ROOT": str(self.root),
            "FAKE_ENGINE": str(self.engine),
            **self.host_env,
            **(extra_env or {}),
        }
        command = ["/bin/sh", str(self.script), *arguments]
        if terminal:
            return self._run_on_a_terminal(command, environment)
        # A session of its own has no controlling terminal, whoever runs the
        # suite, so /dev/tty cannot be opened: the state a CI job is in. Input
        # given as text stands for what `curl | sh` leaves on standard input.
        stdin = {"stdin": subprocess.DEVNULL} if input_text is None else {"input": input_text}
        return subprocess.run(
            command,
            env=environment,
            **stdin,
            text=True,
            capture_output=True,
            check=False,
            start_new_session=True,
        )

    def _run_on_a_terminal(self, command, environment):
        """Run as `curl | sh` does: a controlling terminal, and stdin that is not it."""
        stdout_path = self.base / "stdout"
        stderr_path = self.base / "stderr"
        pid, master = pty.fork()
        if pid == 0:
            try:
                # One descriptor stays on the terminal: macOS takes a session's
                # controlling terminal away when its last one closes.
                os.dup2(0, 9)
                os.dup2(os.open(os.devnull, os.O_RDONLY), 0)
                os.dup2(os.open(stdout_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC), 1)
                os.dup2(os.open(stderr_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC), 2)
                os.execve(command[0], command, environment)
            finally:
                os._exit(127)
        _, status = os.waitpid(pid, 0)
        os.close(master)
        return subprocess.CompletedProcess(
            command,
            os.waitstatus_to_exitcode(status),
            stdout_path.read_text(encoding="utf-8"),
            stderr_path.read_text(encoding="utf-8"),
        )

    def _calls(self):
        return self.log.read_text(encoding="utf-8").splitlines()

    def _server_calls(self):
        """What the Always On server script was run with, if it ran."""
        return [call for call in self._calls() if call.startswith("server ")]

    def _assert_no_download_left(self):
        """The installer's own directory is gone, the downloaded script with it."""
        self.assertEqual(list(self.scratch.iterdir()), [])

    def _one(self, calls, prefix):
        matching = [call for call in calls if call.startswith(prefix)]
        self.assertEqual(len(matching), 1, f"expected one {prefix!r} call in {calls}")
        return matching[0]

    def _assert_refused_before_downloading(self):
        """Only the table was fetched, and nothing was installed."""
        self.assertEqual(self._calls(), [f"curl {TABLE_URL}"])
        self._assert_nothing_installed()

    def _assert_nothing_installed(self):
        for call in self._calls():
            with self.subTest(call=call):
                self.assertFalse(call.startswith(INSTALLING), f"a refusal still ran: {call}")
                self.assertNotRegex(call, r"^rpm (-i|-U|-F|--install|--upgrade|--freshen)")

    def _release(self, version):
        """Publish one release's files on the fake GitHub, each with its own payload."""
        for key, name in release_files(version).items():
            payload = FAKE_SERVER_SCRIPT.encode() if key == ALWAYS_ON else f"{version} {key}\n".encode()
            self.payloads[(version, key)] = payload
            self.digests[(version, key)] = sha256_of(payload)
            self._serve(f"{ORIGIN}/v{version}/{name}", payload)

    def _table(self, latest=VERSION, releases=(VERSION,), drop=(), digests=None):
        """The digest table fermix.ai serves: a format line, latest, then one row per file."""
        lines = ["format 1"]
        if latest is not None:
            lines.append(f"latest {latest}".rstrip())
        for version in releases:
            for key, name in release_files(version).items():
                if (version, key) in drop:
                    continue
                digest = (digests or {}).get((version, key), self.digests[(version, key)])
                lines.append(f"{version} {digest} {name}")
        return "\n".join(lines) + "\n"

    def _publish_table(self, text):
        self._serve(TABLE_URL, text.encode())

    def _serve(self, url, payload):
        path = self.remote / url.removeprefix("https://")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        return url

    def _rail_table(self):
        """Run the release rail's own table builder over this test's payloads."""
        self.assertIsNotNone(shutil.which("bash"), "bash is required to build the table")
        tree = self.base / "candidate"
        for key, name in release_files(VERSION).items():
            if key == ALWAYS_ON:
                directory = tree / "always_on"
            else:
                directory = tree / ("burrito_out" if isinstance(key, str) else "linux_packages")
            directory.mkdir(parents=True, exist_ok=True)
            (directory / name).write_bytes(self.payloads[(VERSION, key)])
            (directory / f"{name}.sig").write_bytes(b"signature\n")
            (directory / f"{name}.pem").write_bytes(b"certificate\n")
        tools = self.base / "rail-bin"
        tools.mkdir()
        (tools / "cosign").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (tools / "cosign").chmod(0o755)

        result = subprocess.run(
            ["bash", str(TABLE_BUILDER), str(tree), VERSION],
            env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}"},
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def _sandboxed_installer(self):
        """The installer, with the absolute package path moved under self.root."""
        source = INSTALLER.read_text(encoding="utf-8")
        line = 'PACKAGE_BINARY="/usr/bin/fermix"\n'
        self.assertEqual(source.count(line), 1, "PACKAGE_BINARY is not declared exactly once")
        source = source.replace(line, f'PACKAGE_BINARY="{self.root}/usr/bin/fermix"\n')
        script = self.base / "install.sh"
        script.write_text(source, encoding="utf-8")
        return script

    def _link_real_tool(self, name):
        path = shutil.which(name)
        self.assertIsNotNone(path, f"{name} is required to run the installer")
        (self.bin / name).symlink_to(path)

    def _fake(self, name, body):
        self._write(self.bin / name, body)

    def _write(self, path, body):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
