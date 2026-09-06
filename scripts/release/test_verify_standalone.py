#!/usr/bin/env python3
"""Hermetic tests for standalone release smoke verification."""

import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("verify_standalone.sh")
VERSION = "0.9.0"


class VerifyStandaloneTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-standalone-verify-")
        self.base = Path(self.tmp.name)
        self.artifact = self.base / "fermix_macos_aarch64"

    def tearDown(self):
        self.tmp.cleanup()

    def test_runs_version_and_packaged_disclaim_check_for_macos(self):
        self._write_artifact(create_disclaim=True)

        result = self._run("macos_aarch64")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"fermix {VERSION}", result.stdout)
        self.assertIn("disclaim: ok", result.stdout)

    def test_rejects_macos_artifact_without_packaged_disclaim(self):
        self._write_artifact(create_disclaim=False)

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disclaim shim not found", result.stderr)

    def test_rejects_non_executable_packaged_disclaim(self):
        self._write_artifact(create_disclaim=True, disclaim_executable=False)

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disclaim shim is not executable", result.stderr)

    def test_rejects_packaged_disclaim_that_fails_its_self_check(self):
        self._write_artifact(create_disclaim=True, disclaim_exit=1)

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disclaim shim self-check failed", result.stderr)

    def test_linux_artifact_does_not_require_macos_disclaim(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(create_disclaim=False)

        result = self._run("linux_x86_64")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"fermix {VERSION}", result.stdout)

    def test_rejects_version_output_that_does_not_match(self):
        self._write_artifact(create_disclaim=True, version="0.8.0")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--version output does not contain 0.9.0", result.stderr)

    def test_rejects_unknown_target_before_running_artifact(self):
        marker = self.base / "ran"
        self._write_artifact(create_disclaim=False, marker=marker)

        result = self._run("windows_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported standalone target", result.stderr)
        self.assertFalse(marker.exists())

    def test_rejects_missing_non_regular_and_symlink_artifacts(self):
        missing = self._run("macos_aarch64")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("regular file", missing.stderr)

        self.artifact.mkdir()
        directory = self._run("macos_aarch64")
        self.assertNotEqual(directory.returncode, 0)
        self.assertIn("regular file", directory.stderr)

        self.artifact.rmdir()
        target = self.base / "target"
        target.write_text("artifact\n", encoding="utf-8")
        self.artifact.symlink_to(target)
        symlink = self._run("macos_aarch64")
        self.assertNotEqual(symlink.returncode, 0)
        self.assertIn("regular file", symlink.stderr)

    def test_rejects_wrong_argument_count(self):
        result = subprocess.run(
            [str(SCRIPT), str(self.artifact), "macos_aarch64"],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage:", result.stderr)

    def _run(self, target):
        return subprocess.run(
            [str(SCRIPT), str(self.artifact), target, VERSION],
            text=True,
            capture_output=True,
            check=False,
        )

    def _write_artifact(
        self,
        *,
        create_disclaim,
        disclaim_executable=True,
        disclaim_exit=0,
        version=VERSION,
        marker=None,
    ):
        setup = self._disclaim_setup(create_disclaim, disclaim_executable, disclaim_exit)
        marker_line = "" if marker is None else f"touch '{marker}'\n"
        self.artifact.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            f"{marker_line}"
            f"{setup}\n"
            f"printf 'fermix {version}\\n'\n",
            encoding="utf-8",
        )
        self.artifact.chmod(0o755)

    def _disclaim_setup(self, create_disclaim, executable, exit_code):
        if not create_disclaim:
            return ""

        mode = "chmod +x \"$cache/disclaim\"" if executable else "chmod -x \"$cache/disclaim\""
        return f'''cache="$HOME/Library/Application Support/.burrito/release/lib/fermix_nif/priv"
mkdir -p "$cache"
cat > "$cache/disclaim" <<'SHIM'
#!/bin/sh
[ "$1" = "--check" ] || exit 2
printf 'disclaim: ok\\n'
exit {exit_code}
SHIM
{mode}'''


if __name__ == "__main__":
    unittest.main()
