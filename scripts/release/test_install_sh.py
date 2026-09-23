#!/usr/bin/env python3
"""Hermetic tests for scripts/install.sh, the script served at fermix.ai/install.

Nothing here reaches the network, a package manager or /usr: the script runs
with a PATH that holds only this test's stand-ins (and the handful of real
POSIX tools it needs), and the two absolute package paths it names are pointed
at a directory this test owns.
"""

import hashlib
import json
import os
import pty
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "scripts/install.sh"
FEED_BUILDER = ROOT / "scripts/release/build_releases_json.sh"

VERSION = "9.9.9"
ORIGIN = "https://github.com/tezra-io/fermix/releases/download"
MANIFEST_URL = "https://github.com/tezra-io/fermix/releases/latest/download/releases.json"

# The real tools the installer may call. Everything else on PATH is a stand-in,
# so a host's own apt-get, rpm or cosign can never answer for the test.
REAL_TOOLS = ("awk", "basename", "cat", "chmod", "cp", "dirname", "install", "mkdir", "mktemp", "rm")

PACKAGE_NAMES = {
    ("linux-x86_64", "deb"): f"fermix_{VERSION}_amd64.deb",
    ("linux-aarch64", "deb"): f"fermix_{VERSION}_arm64.deb",
    ("linux-x86_64", "rpm"): f"fermix-{VERSION}-1.x86_64.rpm",
    ("linux-aarch64", "rpm"): f"fermix-{VERSION}-1.aarch64.rpm",
}
STANDALONE_TARGETS = ("linux-x86_64", "linux-aarch64", "macos-aarch64", "macos-x86_64")

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

FAKE_DPKG_QUERY = """#!/bin/sh
[ -n "${FAKE_INSTALLED_VERSION:-}" ] || exit 1
printf '%s %s\\n' "${FAKE_INSTALLED_STATUS:-installed}" "$FAKE_INSTALLED_VERSION"
"""

# rpm says "not installed" on standard output, which is the trap the installer
# has to step around.
FAKE_RPM = """#!/bin/sh
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


def sha256_of(data):
    return hashlib.sha256(data).hexdigest()


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-installer-")
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.remote = self.base / "remote"
        self.root = self.base / "root"
        self.home = self.base / "home"
        self.log = self.base / "log"
        for directory in (self.bin, self.remote, self.root, self.home):
            directory.mkdir()
        self.log.touch()

        for tool in REAL_TOOLS:
            self._link_real_tool(tool)
        self._link_real_tool("sha256sum" if shutil.which("sha256sum") else "shasum")

        self.engine = self.base / "fake-engine"
        self._write(self.engine, FAKE_ENGINE)
        self._fake("uname", FAKE_UNAME)
        self._fake("curl", FAKE_CURL)
        self._fake("id", FAKE_ID)
        self._fake("sudo", FAKE_SUDO)

        self.payloads = {}
        self.script = self._sandboxed_installer()
        self._publish(self._manifest())

    def tearDown(self):
        self.tmp.cleanup()

    # -- which channel a machine gets ------------------------------------

    def test_a_deb_host_installs_the_package_with_apt_through_sudo(self):
        self._host("apt")
        self._fake("cosign", FAKE_COSIGN)

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("linux-x86_64 (deb package, installed with apt)", result.stdout)
        calls = self._calls()
        self.assertEqual(calls[0], f"curl {MANIFEST_URL}")
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
        self.assertEqual((prefix / "fermix").read_bytes(), self.payloads["linux-x86_64"])

    def test_standalone_flag_installs_the_binary_on_a_package_host(self):
        self._host("apt")
        prefix = self.base / "prefix"
        prefix.mkdir()

        result = self._run("--standalone", "--prefix", str(prefix))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((prefix / "fermix").read_bytes(), self.payloads["linux-x86_64"])
        self.assertEqual([call for call in self._calls() if call.startswith("apt-get")], [])
        self.assertNotIn("No apt, dnf or zypper", result.stdout)

    def test_macos_gets_the_standalone_binary_whatever_else_is_installed(self):
        self._host("apt", system="Darwin", machine="arm64")
        prefix = self.base / "prefix"
        prefix.mkdir()

        result = self._run("--prefix", str(prefix))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("macos-aarch64 (standalone binary)", result.stdout)
        self.assertEqual((prefix / "fermix").read_bytes(), self.payloads["macos-aarch64"])
        self.assertEqual([call for call in self._calls() if call.startswith("apt-get")], [])

    def test_a_failed_package_install_is_not_retried_as_a_standalone_one(self):
        self._host("apt")

        result = self._run(extra_env={"FAKE_PACKAGE_MANAGER_EXIT": "100"})

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Done.", result.stdout)
        fetched = [call for call in self._calls() if call.startswith("curl ")]
        self.assertEqual(
            fetched,
            [f"curl {MANIFEST_URL}", f"curl {ORIGIN}/v{VERSION}/fermix_{VERSION}_amd64.deb"],
        )

    # -- refusals ----------------------------------------------------------

    def test_prefix_is_refused_where_a_package_is_installed(self):
        self._host("apt")

        result = self._run("--prefix", str(self.base))

        self.assertEqual(result.returncode, 1)
        self.assertIn("--prefix places the standalone binary", result.stderr)
        self.assertIn("--standalone", result.stderr)
        self.assertEqual(self._calls(), [])

    def test_a_release_without_packages_refuses_and_names_the_standalone_binary(self):
        self._host("apt")
        manifest = self._manifest()
        del manifest["releases"][0]["packages"]
        self._publish(manifest)

        result = self._run()

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"release {VERSION} lists no deb package for linux-x86_64", result.stderr)
        self.assertIn("--standalone", result.stderr)
        self.assertEqual(self._calls(), [f"curl {MANIFEST_URL}"])

    def test_a_package_url_outside_the_release_origin_is_refused_before_it_is_fetched(self):
        for field in ("url", "sig_url", "cert_url"):
            with self.subTest(field=field):
                self.log.write_text("", encoding="utf-8")
                self._host("apt")
                manifest = self._manifest()
                manifest["releases"][0]["packages"]["linux-x86_64"]["deb"][field] = (
                    "https://example.invalid/fermix.deb"
                )
                self._publish(manifest)

                result = self._run()

                self.assertEqual(result.returncode, 1)
                self.assertIn(f"{field} for target linux-x86_64 is not under", result.stderr)
                self.assertEqual(self._calls(), [f"curl {MANIFEST_URL}"])

    def test_a_checksum_mismatch_refuses_before_the_package_manager_runs(self):
        self._host("apt")
        manifest = self._manifest()
        manifest["releases"][0]["packages"]["linux-x86_64"]["deb"]["sha256"] = "0" * 64
        self._publish(manifest)

        result = self._run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("sha256 mismatch", result.stderr)
        self.assertEqual([call for call in self._calls() if call.startswith("apt-get")], [])

    def test_an_account_with_neither_root_nor_sudo_is_told_what_to_do(self):
        self._host("apt")
        (self.bin / "sudo").unlink()

        result = self._run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("needs root", result.stderr)
        self.assertIn("--standalone", result.stderr)

    # -- the signature -------------------------------------------------------

    def test_the_package_signature_is_checked_against_the_release_tag(self):
        self._host("apt")
        self._fake("cosign", FAKE_COSIGN)

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self._calls()
        package_url = f"{ORIGIN}/v{VERSION}/fermix_{VERSION}_amd64.deb"
        self.assertIn(f"curl {package_url}.sig", calls)
        self.assertIn(f"curl {package_url}.pem", calls)
        verify = self._one(calls, "cosign ")
        self.assertIn(
            "--certificate-identity "
            f"https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v{VERSION}",
            verify,
        )
        self.assertIn(
            "--certificate-oidc-issuer https://token.actions.githubusercontent.com", verify
        )
        self.assertLess(calls.index(verify), calls.index(self._one(calls, "apt-get ")))

    def test_a_failed_signature_installs_nothing(self):
        self._host("apt")
        self._fake("cosign", FAKE_COSIGN)

        result = self._run(extra_env={"FAKE_COSIGN_EXIT": "1"})

        self.assertEqual(result.returncode, 1)
        self.assertIn("cosign verify-blob FAILED", result.stderr)
        self.assertEqual([call for call in self._calls() if call.startswith("apt-get")], [])

    def test_without_cosign_the_skip_is_loud_and_names_the_manual_check(self):
        self._host("apt")

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SKIPPING the release signature check", result.stderr)
        self.assertIn("https://fermix.ai/docs/linux-packages#download-and-verify", result.stderr)
        # The standalone wording is about verbs a package never uses.
        self.assertNotIn("fermix upgrade", result.stderr)

    def test_an_installed_package_lends_its_bundled_cosign_to_the_update(self):
        self._host("apt")
        bundled = self.root / "usr/lib/fermix/cosign"
        bundled.parent.mkdir(parents=True)
        self._write(bundled, FAKE_COSIGN)

        result = self._run(extra_env={"FAKE_INSTALLED_VERSION": "9.9.8"})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Signature verified against", result.stdout)
        self.assertNotIn("SKIPPING", result.stderr)

    # -- what happens after the package is on disk ----------------------------

    def test_the_latest_version_already_installed_downloads_nothing(self):
        self._host("apt")

        result = self._run(extra_env={"FAKE_INSTALLED_VERSION": VERSION})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"fermix {VERSION} is already installed", result.stdout)
        self.assertIn("fermix setup", result.stdout)
        self.assertEqual(self._calls(), [f"curl {MANIFEST_URL}"])

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

    # -- the contract with the release rail -----------------------------------

    def test_the_installer_reads_the_feed_the_release_rail_writes(self):
        feed = json.loads(self._real_feed())
        package = feed["releases"][0]["packages"]["linux-aarch64"]["rpm"]
        self.assertEqual(package["sig_url"], package["url"] + ".sig")
        self.assertEqual(package["cert_url"], package["url"] + ".pem")

        self._publish_text(self._real_feed())
        self._host("dnf", machine="aarch64")
        self._fake("cosign", FAKE_COSIGN)

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self._calls()
        for suffix in ("", ".sig", ".pem"):
            self.assertIn(f"curl {package['url']}{suffix}", calls)

    def test_every_package_in_the_feed_names_its_signature_and_certificate(self):
        packages = json.loads(self._real_feed())["releases"][0]["packages"]

        self.assertEqual(sorted(packages), ["linux-aarch64", "linux-x86_64"])
        for target, formats in packages.items():
            self.assertEqual(sorted(formats), ["deb", "rpm"])
            for kind, package in formats.items():
                with self.subTest(target=target, kind=kind):
                    self.assertEqual(package["name"], PACKAGE_NAMES[(target, kind)])
                    self.assertEqual(package["url"], f"{ORIGIN}/v{VERSION}/{package['name']}")
                    self.assertEqual(package["sig_url"], package["url"] + ".sig")
                    self.assertEqual(package["cert_url"], package["url"] + ".pem")
                    self.assertEqual(
                        package["sha256"], sha256_of(self.payloads[(target, kind)])
                    )

    # -- fixtures --------------------------------------------------------------

    def _host(self, manager, system="Linux", machine="x86_64", uid=1000):
        """Describe the machine: its kernel, its account and its package manager."""
        self.host_env = {"FAKE_UNAME_S": system, "FAKE_UNAME_M": machine, "FAKE_UID": str(uid)}
        for name in ("dpkg", "dpkg-query", "apt-get", "rpm", "dnf", "zypper"):
            (self.bin / name).unlink(missing_ok=True)
        if manager == "apt":
            self._fake("dpkg", "#!/bin/sh\nexit 0\n")
            self._fake("dpkg-query", FAKE_DPKG_QUERY)
            self._fake("apt-get", FAKE_PACKAGE_MANAGER)
        elif manager in ("dnf", "zypper"):
            self._fake("rpm", FAKE_RPM)
            self._fake(manager, FAKE_PACKAGE_MANAGER)

    def _run(self, *arguments, extra_env=None, terminal=False):
        environment = {
            "PATH": str(self.bin),
            "HOME": str(self.home),
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
        # suite, so /dev/tty cannot be opened: the state a CI job is in.
        return subprocess.run(
            command,
            env=environment,
            stdin=subprocess.DEVNULL,
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

    def _one(self, calls, prefix):
        matching = [call for call in calls if call.startswith(prefix)]
        self.assertEqual(len(matching), 1, f"expected one {prefix!r} call in {calls}")
        return matching[0]

    def _manifest(self):
        """The feed for one release, with a real payload behind every URL."""
        artifacts = []
        for target in STANDALONE_TARGETS:
            name = "fermix_" + target.replace("-", "_", 1)
            payload = f"standalone {target}\n".encode()
            self.payloads[target] = payload
            url = self._serve(f"{ORIGIN}/v{VERSION}/{name}", payload)
            artifacts.append(self._entry(url, payload, target=target))

        packages = {}
        for (target, kind), name in PACKAGE_NAMES.items():
            payload = f"{kind} {target}\n".encode()
            self.payloads[(target, kind)] = payload
            url = self._serve(f"{ORIGIN}/v{VERSION}/{name}", payload)
            packages.setdefault(target, {})[kind] = {"name": name, **self._entry(url, payload)}

        return {
            "schema_version": 1,
            "latest": VERSION,
            "releases": [
                {
                    "version": VERSION,
                    "published_at": "2026-01-01T00:00:00Z",
                    "artifacts": artifacts,
                    "packages": packages,
                }
            ],
        }

    def _entry(self, url, payload, **leading):
        self._serve(url + ".sig", b"signature\n")
        self._serve(url + ".pem", b"certificate\n")
        return {
            **leading,
            "url": url,
            "sha256": sha256_of(payload),
            "sig_url": url + ".sig",
            "cert_url": url + ".pem",
        }

    def _serve(self, url, payload):
        path = self.remote / url.removeprefix("https://")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        return url

    def _publish(self, manifest):
        # jq's layout, which is what the installer's line scanner reads: two
        # spaces, one key per line.
        self._publish_text(json.dumps(manifest, indent=2) + "\n")

    def _publish_text(self, text):
        self._serve(MANIFEST_URL, text.encode())

    def _real_feed(self):
        """Run the release rail's own feed builder over this test's payloads."""
        for tool in ("bash", "jq", "sha256sum"):
            self.assertIsNotNone(shutil.which(tool), f"{tool} is required to build the feed")

        tree = self.base / "feed"
        if not tree.exists():
            self._manifest()
            builder = tree / "scripts/release/build_releases_json.sh"
            builder.parent.mkdir(parents=True)
            shutil.copy(FEED_BUILDER, builder)
            (tree / "burrito_out").mkdir()
            (tree / "packages").mkdir()
            for target in STANDALONE_TARGETS:
                name = "fermix_" + target.replace("-", "_", 1)
                (tree / "burrito_out" / name).write_bytes(self.payloads[target])
            for key, name in PACKAGE_NAMES.items():
                (tree / "packages" / name).write_bytes(self.payloads[key])

        result = subprocess.run(
            ["bash", str(tree / "scripts/release/build_releases_json.sh")],
            env={
                **os.environ,
                "VERSION": f"v{VERSION}",
                "REPO": "tezra-io/fermix",
                "PACKAGES_DIR": str(tree / "packages"),
            },
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def _sandboxed_installer(self):
        """The installer, with the two absolute package paths moved under self.root."""
        source = INSTALLER.read_text(encoding="utf-8")
        for constant, path in (
            ("PACKAGE_BINARY", "/usr/bin/fermix"),
            ("PACKAGE_COSIGN", "/usr/lib/fermix/cosign"),
        ):
            line = f'{constant}="{path}"\n'
            self.assertEqual(source.count(line), 1, f"{constant} is not declared exactly once")
            source = source.replace(line, f'{constant}="{self.root}{path}"\n')
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
