#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for the release an Always On server installs.

A server always runs exactly the Fermix of the computers it serves as their
primary, so the home can always move back to one of them (Always On's move
back, design §6): its first boot installs the release it is given
(`packaging/cloud/first-boot.sh --version`), and the nightly update it writes
(`fermix-update`) installs `fermix home status --json`'s `update_ceiling`,
never past it and never back down.

The nightly update is the script first boot writes, taken from first-boot.sh
as it writes it, with its fixed paths moved under this test's own directory
(each replaced line asserted present exactly once, as test_install_sh.py does
for the installer). Nothing reaches the network, a package manager, systemd,
another account or /run: every command it runs is a stand-in on a PATH of this
test's own, beside a handful of real POSIX tools. The container scenarios in
packaging/cloud/test/ run the same script on a real Debian.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIRST_BOOT = ROOT / "packaging/cloud/first-boot.sh"
INSTALL_URL = "https://fermix.ai/install"

REAL_TOOLS = (
    "sh", "cat", "tr", "sed", "rm", "mv", "mktemp", "install", "dirname", "env",
    "mkdir", "chmod", "cut", "grep",
)

# `dpkg --compare-versions A OP B` for the plain MAJOR.MINOR.PATCH releases
# Fermix ships, as dpkg orders them (numerically, field by field).
FAKE_DPKG = f"""#!{sys.executable}
import sys
_, flag, a, op, b = sys.argv
assert flag == "--compare-versions", sys.argv
key = lambda v: tuple(int(part) for part in v.split("."))
ops = {{"lt": key(a) < key(b), "le": key(a) <= key(b), "eq": key(a) == key(b),
        "ge": key(a) >= key(b), "gt": key(a) > key(b)}}
sys.exit(0 if ops[op] else 1)
"""


class NightlyUpdateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-update-")
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.state = self.base / "state"
        self.home = self.base / "home"
        self.fermix_home = self.home / ".fermix"
        self.log = self.base / "calls.log"
        for directory in (self.bin, self.state, self.fermix_home, self.base / "run"):
            directory.mkdir(parents=True)
        self.log.touch()
        for tool in REAL_TOOLS:
            path = shutil.which(tool)
            self.assertIsNotNone(path, f"{tool} is required to run the update")
            (self.bin / tool).symlink_to(path)
        self._stand_ins()
        self.script = self._update_script()

    def tearDown(self):
        self.tmp.cleanup()

    # -- the release it installs ---------------------------------------------

    def test_a_server_behind_its_computers_installs_exactly_their_release(self):
        self._installed("0.17.0")
        self._ceiling("0.17.2")

        result = self._night()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("==> Fermix went from 0.17.0 to 0.17.2", result.stdout)
        calls = self._calls()
        self.assertEqual(calls[:3], [
            "fermix home status --json",
            f"curl {INSTALL_URL}",
            "installer --no-setup --version 0.17.2",
        ])
        # The engine runs the older release, so it is restarted.
        self.assertIn("fermix restart", calls)

    def test_releases_are_ordered_as_dpkg_orders_them_not_as_text(self):
        self._installed("0.9.0")
        self._ceiling("0.10.0")

        result = self._night()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("installer --no-setup --version 0.10.0", self._calls())

    def test_a_server_on_its_computers_release_downloads_nothing(self):
        self._installed("0.17.0")
        self._ceiling("0.17.0")

        result = self._night()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("==> Fermix 0.17.0 is the release your computers run", result.stdout)
        self.assertNotIn(f"curl {INSTALL_URL}", self._calls())

    def test_a_server_newer_than_its_computers_is_never_installed_back_down(self):
        self._installed("0.18.0")
        self._ceiling("0.17.2")

        result = self._night()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "==> Fermix 0.18.0 is newer than 0.17.2, the oldest release your computers run, "
            "and is never installed back down: moving Fermix back to that computer waits "
            "until it updates",
            result.stdout,
        )
        self.assertNotIn(f"curl {INSTALL_URL}", self._calls())

    def test_with_no_computer_seen_fermix_stays_as_it_is(self):
        self._installed("0.17.0")
        self._ceiling(None)

        result = self._night()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "==> No computer has reached this server in the last 30 days, so Fermix stays at "
            "0.17.0",
            result.stdout,
        )
        self.assertNotIn(f"curl {INSTALL_URL}", self._calls())

    def test_a_server_with_no_home_yet_installs_nothing_and_asks_no_engine(self):
        self._installed("0.17.0")
        shutil.rmtree(self.fermix_home)

        result = self._night()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("This server has no Fermix home yet", result.stdout)
        self.assertEqual(
            [call for call in self._calls() if call.startswith(("curl", "fermix home"))], []
        )

    def test_a_ceiling_that_cannot_be_read_installs_nothing_and_ends_the_night_non_zero(self):
        self._installed("0.17.0")
        (self.state / "home-status-fails").touch()

        result = self._night()

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "fermix update: fermix home status stopped, so Fermix is not updated tonight; its "
            "message above says why.",
            result.stderr,
        )
        self.assertNotIn(f"curl {INSTALL_URL}", self._calls())

    def test_an_installer_that_fails_stops_the_night_before_the_restart(self):
        self._installed("0.17.0")
        self._ceiling("0.17.2")
        (self.state / "installer-fails").touch()

        result = self._night()

        self.assertEqual(result.returncode, 1)
        self.assertIn("The Fermix installer stopped", result.stderr)
        self.assertNotIn("fermix restart", self._calls())

    # -- first boot ---------------------------------------------------------------

    def test_first_boot_refuses_a_release_that_is_not_one_before_it_touches_the_host(self):
        for argv, sentence in (
            (["--version", "0.17"], "--version is not a Fermix release, such as 0.17.0."),
            (["--version", "latest"], "--version is not a Fermix release, such as 0.17.0."),
            (["--version"], "--version needs a value."),
        ):
            with self.subTest(argv=argv):
                result = subprocess.run(
                    ["/bin/sh", str(FIRST_BOOT), *argv],
                    env={"PATH": "/usr/bin:/bin"},
                    stdin=subprocess.DEVNULL,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, f"fermix always-on: {sentence}\n")

    def test_first_boot_installs_the_release_it_is_given(self):
        for release, expected in (("0.17.2", "installer --no-setup --version 0.17.2"),
                                  ("", "installer --no-setup")):
            with self.subTest(release=release):
                self.log.write_text("", encoding="utf-8")
                result = self._install_step(release)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self._calls(), [f"curl {INSTALL_URL}", expected])

    # The first boot's install step alone: its function as first-boot.sh holds
    # it, with what it calls before the installer stood in for.
    def _install_step(self, release):
        source = FIRST_BOOT.read_text(encoding="utf-8")
        step = source[source.index("install_fermix() {") :]
        step = step[: step.index("\n}\n") + 3]
        work = self.base / "work"
        work.mkdir(exist_ok=True)
        (self.state / "installed-version").write_text("0.17.0", encoding="utf-8")
        script = self.base / "install-step.sh"
        script.write_text(
            "set -eu\n"
            f"INSTALL_URL={INSTALL_URL}\nWORK={work}\nFERMIX_BIN={self.fermix}\n"
            f"RELEASE='{release}'\n"
            'say() { printf "==> %s\\n" "$1"; }\n'
            'fail() { printf "%s\\n" "$1" >&2; exit 1; }\n'
            "apt_install() { :; }\n"
            f"{step}install_fermix\n",
            encoding="utf-8",
        )
        return subprocess.run(
            ["/bin/sh", str(script)],
            env={"PATH": str(self.bin)},
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            check=False,
        )

    # -- fixtures -----------------------------------------------------------------

    def _night(self):
        return subprocess.run(
            ["/bin/sh", str(self.script)],
            env={"PATH": str(self.bin)},
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            check=False,
        )

    def _installed(self, version):
        (self.state / "installed-version").write_text(version, encoding="utf-8")
        (self.state / "running-version").write_text(version, encoding="utf-8")

    def _ceiling(self, version):
        value = "null" if version is None else f'"{version}"'
        (self.state / "home-status.json").write_text(
            '{\n  "ok": true,\n  "result": {\n    "move": null,\n    "role": "primary",\n'
            f'    "update_ceiling": {value},\n    "version": "0.17.0"\n  }},\n'
            '  "schema_version": 1\n}\n',
            encoding="utf-8",
        )

    def _calls(self):
        return self.log.read_text(encoding="utf-8").splitlines()

    def _stand_ins(self):
        state, log = self.state, self.log
        installer = self.base / "fake-install.sh"
        self._write(installer, f"""#!/bin/sh
set -eu
printf 'installer %s\\n' "$*" >>'{log}'
[ ! -f '{state}/installer-fails' ] || exit 1
if [ "${{2-}}" = "--version" ]; then printf '%s' "$3" >'{state}/installed-version'; fi
""")
        self._fake("curl", f"""#!/bin/sh
url="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --proto) shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
printf 'curl %s\\n' "$url" >>'{log}'
[ "$url" = '{INSTALL_URL}' ] || exit 6
cat '{installer}' >"$out"
""")
        self._fake("dpkg-query", f"""#!/bin/sh
cat '{state}/installed-version'
""")
        self._fake("dpkg", FAKE_DPKG)
        self._fake("id", "#!/bin/sh\necho 0\n")
        self._fake("systemctl", f"#!/bin/sh\nprintf 'systemctl %s\\n' \"$*\" >>'{log}'\n")
        # runuser -u ACCOUNT -- COMMAND...: the command, as that account.
        self._fake("runuser", '#!/bin/sh\nshift 3\nexec "$@"\n')
        self.fermix = self.base / "fermix"
        self._write(self.fermix, f"""#!/bin/sh
printf 'fermix %s\\n' "$*" >>'{log}'
case "$1 $2" in
  "home status")
    [ ! -f '{state}/home-status-fails' ] || exit 1
    cat '{state}/home-status.json'
    ;;
  "service status")
    alignment=aligned
    cmp -s '{state}/installed-version' '{state}/running-version' || alignment=pending_restart
    printf '{{"ok": true, "result": {{"alignment": "%s"}}}}\\n' "$alignment"
    ;;
  "restart "*)
    cp '{state}/installed-version' '{state}/running-version'
    ;;
esac
""")
        for tool in ("cmp", "cp"):
            (self.bin / tool).symlink_to(shutil.which(tool))

    def _update_script(self):
        """The script first boot writes, its fixed paths moved under self.base."""
        source = FIRST_BOOT.read_text(encoding="utf-8")
        writer = source[source.index("write_update_script() {") :]
        writer = writer[: writer.index('} | write_file "$UPDATE_SCRIPT" 0755')]
        header = self._between(writer, "    cat <<EOF\n", "\nEOF\n")
        body = self._between(writer, "    cat <<'FERMIX_UPDATE'\n", "\nFERMIX_UPDATE\n")

        for name, value in (
            ("ENGINE_USER", "fermix"),
            ("ACCOUNT_HOME", str(self.home)),
            ("FERMIX_HOME_DIR", str(self.fermix_home)),
            ("FERMIX_BIN", str(self.fermix)),
            ("INSTALL_URL", INSTALL_URL),
        ):
            header = self._once(header, f"{name}=${name}", f"{name}={value}")

        for fixed, moved in (
            ("REBOOT_FLAG=/run/reboot-required", f"REBOOT_FLAG={self.base}/run/reboot-required"),
            (
                "DEFERRALS_FILE=/var/lib/fermix-update/reboot-deferrals",
                f"DEFERRALS_FILE={self.base}/deferrals/reboot-deferrals",
            ),
            (
                "  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n",
                f"  PATH={self.bin}\n",
            ),
            (
                "WORK=$(mktemp -d /run/fermix-update.XXXXXX)",
                f"WORK=$(mktemp -d {self.base}/run/fermix-update.XXXXXX)",
            ),
        ):
            body = self._once(body, fixed, moved)

        script = self.base / "fermix-update"
        script.write_text(header + "\n" + body + "\n", encoding="utf-8")
        return script

    def _between(self, text, start, end):
        self.assertEqual(text.count(start), 1, f"{start!r} is not in write_update_script once")
        after = text[text.index(start) + len(start) :]
        return after[: after.index(end)]

    def _once(self, text, old, new):
        self.assertEqual(text.count(old), 1, f"{old!r} is not in the update script exactly once")
        return text.replace(old, new)

    def _fake(self, name, body):
        self._write(self.bin / name, body)

    def _write(self, path, body):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
