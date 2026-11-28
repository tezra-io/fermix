#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for verify_update_signature.sh, the release workflow's run
of the check an Always On server's update makes before it installs a package:
first-boot.sh's own release_signature_holds, with the cosign the candidate
deb ships (not the runner's, which signed it) and a Sigstore cache of its own.

The deb is a stand-in: a tar, which a stand-in dpkg-deb unpacks for `-x`,
holding a stand-in cosign that logs its arguments, its TUF_ROOT and what that
folder held, and answers as cosign does. A cosign on PATH, the runner's,
fails every call and logs it, so a check run with it shows."""

import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/release/verify_update_signature.sh"
FIRST_BOOT = ROOT / "packaging/cloud/first-boot.sh"
VERSION = "0.21.0"
DEB = f"fermix_{VERSION}_amd64.deb"
IDENTITY = f"https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v{VERSION}"
ISSUER = "https://token.actions.githubusercontent.com"

# `dpkg-deb -x DEB DIR`, for a deb that is a tar.
FAKE_DPKG_DEB = """#!/bin/sh
[ "$#" -eq 3 ] && [ "$1" = -x ] || { echo "dpkg-deb stand-in: unexpected arguments: $*" >&2; exit 64; }
mkdir -p "$3" && tar -xf "$2" -C "$3"
"""

# The runner's cosign, which signed the release: never the one that checks it here.
RUNNER_COSIGN = """#!/bin/sh
printf 'runner cosign %s\\n' "$*" >>"$CALLS"
exit 70
"""

# The package's cosign: logs its arguments, its TUF_ROOT and that folder's
# entries, then answers as $COSIGN_ANSWER says.
PACKAGED_COSIGN = """#!/bin/sh
{
  printf 'args'; for arg in "$@"; do printf ' %s' "$arg"; done; printf '\\n'
  printf 'tuf_root %s\\n' "${TUF_ROOT-unset}"
  printf 'tuf_root_entries %s\\n' "$(ls -A "${TUF_ROOT-/nonexistent}" 2>&1 | tr '\\n' ' ')"
} >>"$CALLS"
if [ "$COSIGN_ANSWER" = refuse ]; then
  echo "Error: none of the expected identities matched what was in the certificate" >&2
  exit 1
fi
echo "Verified OK" >&2
"""


class VerifyUpdateSignatureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-update-signature-")
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.calls = self.base / "calls.log"
        self.calls.touch()
        # A runner's own Sigstore cache, which the check must not read.
        self.home = self.base / "home"
        (self.home / ".sigstore" / "root").mkdir(parents=True)
        self.release = self.base / "linux packages"
        self.release.mkdir()
        self._write(self.bin / "dpkg-deb", FAKE_DPKG_DEB)
        self._write(self.bin / "cosign", RUNNER_COSIGN)

    def tearDown(self):
        self.tmp.cleanup()

    def test_runs_the_server_s_check_with_the_cosign_the_deb_ships(self):
        deb = self._deb()

        result = self._run(deb)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._call("args"),
            f"verify-blob --certificate {deb}.pem --signature {deb}.sig "
            f"--certificate-identity {IDENTITY} --certificate-oidc-issuer {ISSUER} {deb}",
        )
        self.assertNotIn("runner cosign", self.calls.read_text(encoding="utf-8"))
        self.assertIn("Verified OK", result.stderr)
        self.assertEqual(
            result.stdout,
            f"ok: the cosign {DEB} ships verifies its release signature as an Always On "
            "server's update does\n",
        )

    # A server's first update starts with an empty Sigstore cache in root's
    # own folder, so the check does too: never the runner's ~/.sigstore,
    # which the runner's cosign has just filled.
    def test_the_sigstore_cache_is_a_fresh_folder_of_the_check_s_own(self):
        deb = self._deb()

        result = self._run(deb)

        self.assertEqual(result.returncode, 0, result.stderr)
        tuf_root = self._call("tuf_root")
        self.assertNotEqual(tuf_root, "unset")
        self.assertFalse(tuf_root.startswith(str(self.home)), tuf_root)
        self.assertEqual(self._call("tuf_root_entries"), "")
        # Removed with the unpacked package once the check ends.
        self.assertFalse(Path(tuf_root).exists())

    def test_a_signature_the_packaged_cosign_refuses_fails_the_release(self):
        deb = self._deb()

        result = self._run(deb, answer="refuse")

        self.assertEqual(result.returncode, 1)
        self.assertIn("Error: none of the expected identities matched", result.stderr)
        self.assertTrue(
            result.stderr.endswith(
                f"verify_update_signature: the cosign {DEB} ships refused its release signature "
                "(its message above says why), so every Always On server would refuse this "
                "release as an update.\n"
            ),
            result.stderr,
        )
        self.assertEqual(result.stdout, "")

    def test_a_deb_that_ships_no_cosign_is_refused(self):
        deb = self._deb(cosign=False)

        result = self._run(deb)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stderr,
            f"verify_update_signature: {DEB} ships no executable usr/lib/fermix/cosign, so no "
            "Always On server could check an update to it.\n",
        )
        self.assertEqual(self.calls.read_text(encoding="utf-8"), "")

    def test_a_deb_without_its_signature_or_certificate_is_refused_before_cosign_runs(self):
        for missing in (".sig", ".pem"):
            with self.subTest(missing=missing):
                deb = self._deb()
                Path(f"{deb}{missing}").unlink()

                result = self._run(deb)

                self.assertEqual(result.returncode, 1)
                self.assertEqual(
                    result.stderr,
                    f"verify_update_signature: {deb}{missing} is not there: the release signs "
                    "each deb beside it.\n",
                )
                self.assertEqual(self.calls.read_text(encoding="utf-8"), "")

    # The flags live in first-boot.sh alone: a change there is what the
    # check runs, with no copy here to drift from it.
    def test_the_command_is_first_boot_s_own(self):
        self.assertNotIn("verify-blob", SCRIPT.read_text(encoding="utf-8"))
        tree = self.base / "tree"
        (tree / "scripts/release").mkdir(parents=True)
        (tree / "packaging/cloud").mkdir(parents=True)
        shutil.copy2(SCRIPT, tree / "scripts/release/verify_update_signature.sh")
        source = FIRST_BOOT.read_text(encoding="utf-8")
        flag = '--certificate-oidc-issuer "$RELEASE_ISSUER"'
        self.assertEqual(source.count(flag), 1, "first-boot.sh names the issuer flag once")
        (tree / "packaging/cloud/first-boot.sh").write_text(
            source.replace(flag, f"--invented-flag {flag}"), encoding="utf-8"
        )
        deb = self._deb()

        result = self._run(deb, script=tree / "scripts/release/verify_update_signature.sh")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f" --invented-flag --certificate-oidc-issuer {ISSUER} ", self._call("args"))

    # -- fixtures -----------------------------------------------------------

    def _deb(self, cosign=True):
        """A candidate deb, its .sig and .pem beside it, in a folder whose name has a space."""
        staged = self.base / "staged"
        shutil.rmtree(staged, ignore_errors=True)
        (staged / "usr/bin").mkdir(parents=True)
        self._write(staged / "usr/bin/fermix", "#!/bin/sh\n")
        if cosign:
            (staged / "usr/lib/fermix").mkdir(parents=True)
            self._write(staged / "usr/lib/fermix/cosign", PACKAGED_COSIGN)
        deb = self.release / DEB
        with tarfile.open(deb, "w") as archive:
            archive.add(staged, arcname=".")
        Path(f"{deb}.sig").write_text("signature\n", encoding="utf-8")
        Path(f"{deb}.pem").write_text("certificate\n", encoding="utf-8")
        return deb

    def _run(self, deb, answer="accept", script=SCRIPT):
        return subprocess.run(
            ["sh", str(script), str(deb), VERSION],
            env={
                "PATH": f"{self.bin}:{os.environ['PATH']}",
                "HOME": str(self.home),
                "CALLS": str(self.calls),
                "COSIGN_ANSWER": answer,
            },
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            check=False,
        )

    def _call(self, key):
        """The value the packaged cosign logged under `key`, from its one call."""
        lines = [line for line in self.calls.read_text(encoding="utf-8").splitlines() if line.startswith(f"{key} ")]
        self.assertEqual(len(lines), 1, self.calls.read_text(encoding="utf-8"))
        return lines[0][len(key) + 1 :].rstrip()

    def _write(self, path, body):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
