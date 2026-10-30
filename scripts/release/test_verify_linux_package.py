#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for the Landlock shim check verify_linux_package.sh runs on
an installed package. The check is the script's own `landlock_shim_check`
text, run against a fake payload that a stand-in `fermix` names."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("verify_linux_package.sh")


def landlock_shim_check():
    lines = SCRIPT.read_text(encoding="utf-8").splitlines()
    start = lines.index("landlock_shim_check='")
    end = lines.index("'", start + 1)
    return "\n".join(lines[start + 1 : end]) + "\n"


class LandlockShimCheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-linux-package-verify-")
        self.base = Path(self.tmp.name)
        self.payload = self.base / "payload"
        self.payload.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        fermix = self.bin / "fermix"
        fermix.write_text(
            '#!/bin/sh\n[ "$*" = "maintenance directory" ] || exit 64\n'
            f"printf '%s\\n' '{self.payload}'\n",
            encoding="utf-8",
        )
        fermix.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def _shim(self, answer, version="0.9.0", executable=True):
        priv = self.payload / "lib" / f"fermix_nif-{version}" / "priv"
        priv.mkdir(parents=True, exist_ok=True)
        shim = priv / "fermix_landlock"
        shim.write_text(f'#!/bin/sh\n[ "$*" = "--abi" ] || exit 64\n{answer}\n', encoding="utf-8")
        shim.chmod(0o755 if executable else 0o644)
        return shim

    def _run(self):
        return subprocess.run(
            ["sh", "-c", landlock_shim_check(), "landlock-shim-check"],
            env={**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}"},
            text=True,
            capture_output=True,
            check=False,
        )

    def test_accepts_a_shim_that_answers_its_abi(self):
        shim = self._shim("printf 'fermix_landlock: abi 6\\n'\nexit 0")

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"Landlock shim: {shim} (fermix_landlock: abi 6)\n")

    def test_accepts_a_shim_that_says_landlock_is_unavailable_here(self):
        self._shim("printf 'fermix_landlock: Landlock is unavailable on this kernel (x)\\n' >&2\nexit 69")

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("(fermix_landlock: Landlock is unavailable on this kernel (x))", result.stdout)

    def test_rejects_a_payload_without_the_shim(self):
        (self.payload / "lib" / "fermix_nif-0.9.0" / "priv").mkdir(parents=True)

        result = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must carry exactly one Landlock shim", result.stderr)
        self.assertIn("found 0", result.stderr)

    def test_rejects_a_payload_with_two_shims(self):
        self._shim("printf 'fermix_landlock: abi 6\\n'", version="0.9.0")
        self._shim("printf 'fermix_landlock: abi 6\\n'", version="0.8.0")

        result = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 2", result.stderr)

    def test_rejects_a_shim_that_is_not_an_executable_regular_file(self):
        self._shim("printf 'fermix_landlock: abi 6\\n'", executable=False)
        not_executable = self._run()

        shim = self.payload / "lib" / "fermix_nif-0.9.0" / "priv" / "fermix_landlock"
        target = self.base / "elsewhere"
        shim.rename(target)
        target.chmod(0o755)
        shim.symlink_to(target)
        symlink = self._run()

        for result in (not_executable, symlink):
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Landlock shim is not an executable regular file", result.stderr)

    def test_rejects_a_shim_that_does_not_answer_its_contract(self):
        for answer in ("printf 'Segmentation fault\\n' >&2\nexit 139", "exit 0", "printf 'abi 6\\n'\nexit 0"):
            with self.subTest(answer=answer):
                self._shim(answer)

                result = self._run()

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Landlock shim --abi must print its ABI", result.stderr)


if __name__ == "__main__":
    unittest.main()
