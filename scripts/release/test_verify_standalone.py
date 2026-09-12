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
        self.assertIn("would perform this transaction:", result.stdout)
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

    def test_linux_artifact_refuses_not_macos_and_needs_no_disclaim(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(create_disclaim=False, migrate="refused:not_macos")

        result = self._run("linux_x86_64")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"fermix {VERSION}", result.stdout)
        self.assertIn("refused (not_macos)", result.stdout)

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

    # ── the migrate-to-app preflight stage ────────────────────────────────

    # The class this stage exists for: the packaged binary reading the release
    # it boots out of as somebody else's `fermix` on PATH.
    def test_rejects_a_binary_that_refuses_its_own_launcher_on_path(self):
        self._write_artifact(create_disclaim=True, migrate="refused:foreign_cli_target")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("foreign_cli_target", result.stderr)
        self.assertIn("own launcher", result.stderr)

    def test_rejects_a_refusal_from_a_stage_before_the_path_probe(self):
        self._write_artifact(create_disclaim=True, migrate="refused:no_formula_install")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refused the throwaway world (no_formula_install)", result.stderr)

    def test_rejects_a_probe_failure(self):
        self._write_artifact(create_disclaim=True, migrate="probe_failed")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not read the throwaway world", result.stderr)

    def test_rejects_a_plan_that_does_not_name_the_packaged_launcher(self):
        self._write_artifact(create_disclaim=True, migrate="plan_without_packaged_launcher")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not name the unpacked release's own launcher", result.stderr)

    def test_rejects_a_migrate_verb_that_exits_zero_without_a_plan(self):
        self._write_artifact(create_disclaim=True, migrate="silent_success")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("plan must exit 2, got 0", result.stderr)

    def test_rejects_a_linux_binary_that_does_not_refuse_not_macos(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(create_disclaim=False)

        result = self._run("linux_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must refuse not_macos", result.stderr)

    # The stub brew answers the three invocations the preflight makes and
    # refuses every other argv, so a brew call added later cannot pass this
    # gate unanswered. The plan behaviour runs all three; this artifact also
    # asserts the refusal, and exits 7 when the stub answered anyway.
    def test_the_stub_brew_answers_the_preflight_argv_and_refuses_the_rest(self):
        self._write_artifact(create_disclaim=True, migrate="strict_brew")

        result = self._run("macos_aarch64")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("would perform this transaction:", result.stdout)

    def _run(self, target, artifact=None):
        return subprocess.run(
            [str(SCRIPT), artifact or str(self.artifact), target, VERSION],
            text=True,
            capture_output=True,
            check=False,
        )

    # The staged-asset stage passes the bare downloaded file name from the
    # working directory; a name with no slash must not be looked up on PATH.
    def test_accepts_a_bare_artifact_name_in_the_working_directory(self):
        self._write_artifact(create_disclaim=True)

        result = subprocess.run(
            [str(SCRIPT), self.artifact.name, "macos_aarch64", VERSION],
            cwd=self.artifact.parent,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"fermix {VERSION}", result.stdout)

    def _write_artifact(
        self,
        *,
        create_disclaim,
        disclaim_executable=True,
        disclaim_exit=0,
        version=VERSION,
        marker=None,
        migrate="plan",
    ):
        setup = self._disclaim_setup(create_disclaim, disclaim_executable, disclaim_exit, version)
        marker_line = "" if marker is None else f"touch '{marker}'\n"
        self.artifact.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            f"{marker_line}"
            f"{setup}\n"
            'if [ "${1:-}" = "migrate-to-app" ]; then\n'
            f"{self._migrate_behaviour(migrate, version)}"
            "fi\n"
            f"printf 'fermix {version}\\n'\n",
            encoding="utf-8",
        )
        self.artifact.chmod(0o755)

    def _migrate_behaviour(self, migrate, version):
        if migrate.startswith("refused:"):
            return self._refusal(migrate.split(":", 1)[1])
        if migrate == "probe_failed":
            return (
                "  printf 'fermix migrate-to-app: could not inspect this account"
                " — brew --prefix: exit 1\\n' >&2\n"
                "  exit 1\n"
            )
        if migrate == "silent_success":
            return "  exit 0\n"
        if migrate == "plan_without_packaged_launcher":
            return self._plan(version, packaged_launcher=False)
        if migrate == "strict_brew":
            return self._unknown_brew_argv_is_refused() + self._plan(version)
        if migrate == "plan":
            return self._plan(version)
        raise ValueError(f"unknown migrate behaviour: {migrate}")

    def _refusal(self, code):
        return (
            f"  printf 'fermix migrate-to-app: refused ({code})\\n' >&2\n"
            "  printf '  inspected fact\\n' >&2\n"
            "  printf 'Remediation sentence.\\n' >&2\n"
            "  exit 1\n"
        )

    def _unknown_brew_argv_is_refused(self):
        return (
            "  brew_status=0\n"
            "  brew unexpected-subcommand >/dev/null 2>&1 || brew_status=$?\n"
            '  [ "$brew_status" -ne 0 ] || exit 7\n'
        )

    # The real plan's shape, including the `fermix` binaries the preflight
    # found on PATH: the unpacked release's own launcher first, because
    # `erlexec` prepends `$ROOTDIR/bin`, then the Homebrew one.
    def _plan(self, version, packaged_launcher=True):
        launcher = (
            f'"$HOME/Library/Application Support/.burrito/fermix_erts-15.2.7_{version}/bin/fermix, "'
            if packaged_launcher
            else '""'
        )
        return (
            "  brew --prefix >/dev/null\n"
            "  brew list --formula --versions fermix >/dev/null\n"
            "  brew services list >/dev/null\n"
            "  command -v fermix >/dev/null\n"
            "  printf 'fermix migrate-to-app would perform this transaction:\\n'\n"
            '  printf \'  Fermix home: %s\\n\' "$FERMIX_HOME"\n'
            "  printf '  launch agent: %s (none installed)\\n'"
            ' "$HOME/Library/LaunchAgents/io.tezra.fermix.plist"\n'
            "  printf '  daemon: not running\\n'\n"
            "  printf '  `fermix` on PATH: %s%s\\n'"
            f' {launcher} "$(command -v fermix)"\n'
            f"  printf '  Homebrew formula: fermix {version}\\n'\n"
            "  printf '  application: /Applications/Fermix.app (the cask installs it)\\n'\n"
            "  printf '\\nNothing has changed."
            " Re-run as `fermix migrate-to-app --yes` to perform it.\\n'\n"
            "  exit 2\n"
        )

    def _disclaim_setup(self, create_disclaim, executable, exit_code, version):
        if not create_disclaim:
            return ""

        # The unpacked release's layout, with the application directory
        # versioned as a release names it; the source tree's unversioned
        # apps/fermix_nif/priv is not what a release carries.
        mode = "chmod +x \"$cache/disclaim\"" if executable else "chmod -x \"$cache/disclaim\""
        return f'''cache="$HOME/Library/Application Support/.burrito/release/lib/fermix_nif-{version}/priv"
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
