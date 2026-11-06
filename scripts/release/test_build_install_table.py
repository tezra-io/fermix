#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for build_install_table.sh, the release rail's copy of the
digest table fermix.ai serves to scripts/install.sh.

cosign is a stand-in that logs each call, so the tests see which identity every
file was checked against and can make any one check fail.
"""

import hashlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("build_install_table.sh")

VERSION = "9.9.9"
IDENTITY = f"https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v{VERSION}"
ISSUER = "https://token.actions.githubusercontent.com"

FILES = (
    "burrito_out/fermix_linux_x86_64",
    "burrito_out/fermix_linux_aarch64",
    "burrito_out/fermix_macos_aarch64",
    "burrito_out/fermix_macos_x86_64",
    f"linux_packages/fermix_{VERSION}_amd64.deb",
    f"linux_packages/fermix_{VERSION}_arm64.deb",
    f"linux_packages/fermix-{VERSION}-1.x86_64.rpm",
    f"linux_packages/fermix-{VERSION}-1.aarch64.rpm",
)

# Fails the check for the one file named in $FAKE_COSIGN_REJECT.
FAKE_COSIGN = """#!/bin/sh
printf 'cosign %s\\n' "$*" >> "$FAKE_LOG"
for argument in "$@"; do last="$argument"; done
[ "$last" != "${FAKE_COSIGN_REJECT:-}" ] || { echo "error: none of the expected identities matched" >&2; exit 1; }
"""


class BuildInstallTableTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-install-table-")
        self.base = Path(self.tmp.name)
        self.root = self.base / "candidate"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.log = self.base / "log"
        self.log.touch()
        for tool in ("awk", "basename", "bash", "sha256sum" if shutil.which("sha256sum") else "shasum"):
            path = shutil.which(tool)
            self.assertIsNotNone(path, f"{tool} is required to build the table")
            (self.bin / tool).symlink_to(path)
        self._write(self.bin / "cosign", FAKE_COSIGN)

        self.digests = {}
        for file in FILES:
            path = self.root / file
            path.parent.mkdir(parents=True, exist_ok=True)
            payload = f"payload of {file}\n".encode()
            path.write_bytes(payload)
            (self.root / f"{file}.sig").write_bytes(b"signature\n")
            (self.root / f"{file}.pem").write_bytes(b"certificate\n")
            self.digests[Path(file).name] = hashlib.sha256(payload).hexdigest()

    def tearDown(self):
        self.tmp.cleanup()

    def test_every_installable_file_is_verified_then_hashed_into_one_row(self):
        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[:2], ["format 1", f"latest {VERSION}"])
        self.assertEqual(
            sorted(lines[2:]), sorted(f"{VERSION} {digest} {name}" for name, digest in self.digests.items())
        )
        calls = self.log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(calls), len(FILES))
        for file, call in zip(FILES, calls):
            with self.subTest(file=file):
                path = self.root / file
                self.assertEqual(
                    call,
                    f"cosign verify-blob --certificate {path}.pem --signature {path}.sig "
                    f"--certificate-identity {IDENTITY} --certificate-oidc-issuer {ISSUER} {path}",
                )

    def test_a_file_that_does_not_verify_prints_no_table(self):
        rejected = self.root / f"linux_packages/fermix_{VERSION}_arm64.deb"

        result = self._run(extra_env={"FAKE_COSIGN_REJECT": str(rejected)})

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn(f"cosign could not verify linux_packages/fermix_{VERSION}_arm64.deb", result.stderr)

    def test_a_missing_file_or_signature_prints_no_table(self):
        for missing in ("burrito_out/fermix_macos_x86_64", f"linux_packages/fermix-{VERSION}-1.aarch64.rpm.sig"):
            with self.subTest(missing=missing):
                path = self.root / missing
                kept = path.read_bytes()
                path.unlink()

                result = self._run()

                path.write_bytes(kept)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn(f"missing {path}", result.stderr)

    def test_without_cosign_nothing_is_listed(self):
        (self.bin / "cosign").unlink()

        result = self._run()

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("cosign is required", result.stderr)

    def test_a_version_that_is_not_a_release_is_refused(self):
        for version in ("v9.9.9", "9.9", "9.9.9-rc.1", ""):
            with self.subTest(version=version):
                result = self._run(version=version)

                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("expected a release such as 0.18.0", result.stderr)

    def _run(self, version=VERSION, extra_env=None):
        return subprocess.run(
            [str(self.bin / "bash"), str(SCRIPT), str(self.root), version],
            env={"PATH": str(self.bin), "FAKE_LOG": str(self.log), **(extra_env or {})},
            text=True,
            capture_output=True,
            check=False,
        )

    def _write(self, path, body):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
