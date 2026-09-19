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

    # ── the tree-less plugins auth clear stage ────────────────────────────

    # The class this stage exists for: a keychain helper run under a command
    # host that a tree-less verb never has.
    def test_rejects_a_plugins_verb_that_asks_for_a_command_host(self):
        self._write_artifact(create_disclaim=True, plugins_clear="needs_command_host")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("under a command host this tree-less verb does not have", result.stderr)

    def test_rejects_a_plugins_verb_that_fails_in_the_throwaway_world(self):
        self._write_artifact(create_disclaim=True, plugins_clear="refused")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must exit 0 in the throwaway world, got 1", result.stderr)

    def test_rejects_a_plugins_verb_that_never_reaches_the_keychain_helper(self):
        self._write_artifact(create_disclaim=True, plugins_clear="no_helper")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("this stage proved nothing", result.stderr)

    # The stage runs before migrate-to-app, which ends the script on Linux.
    def test_linux_artifact_runs_the_plugins_stage_too(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(
            create_disclaim=False,
            migrate="refused:not_macos",
            plugins_clear="needs_command_host",
        )

        result = self._run("linux_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("under a command host this tree-less verb does not have", result.stderr)

    # The stand-in keychain answers the one delete the verb makes and refuses
    # every other argv, so a keychain call added later cannot pass unanswered.
    # This artifact asserts the refusal, and exits 7 when the stand-in answered.
    def test_the_stand_in_keychain_answers_the_delete_and_refuses_the_rest(self):
        self._write_artifact(create_disclaim=True, plugins_clear="strict_keychain")

        result = self._run("macos_aarch64")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("deleted the stored api key for discord", result.stdout)

    # ── the browser-bridge pump stage ─────────────────────────────────────

    # The class this stage exists for: a verb whose stdout IS a wire, started by
    # a browser with no shell environment, in a release that installs its own
    # stdout log handler after the config provider has already logged.
    def test_rejects_a_pump_that_writes_to_stdout(self):
        self._write_artifact(create_disclaim=True, browser_bridge="noisy_stdout")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wrote to stdout, which is the native-messaging wire", result.stderr)

    # The other half of the same file: the manifest decides which extension may
    # connect, and the pump has to read the same list Chrome does.
    def test_rejects_a_pump_that_admits_an_unlisted_origin(self):
        self._write_artifact(create_disclaim=True, browser_bridge="admits_any_origin")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("admitted an unlisted origin", result.stderr)

    def test_rejects_an_install_that_writes_no_manifest(self):
        self._write_artifact(create_disclaim=True, browser_bridge="no_manifest")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wrote no manifest", result.stderr)

    # The stage runs before migrate-to-app, which ends the script on Linux, so a
    # Linux artifact walks it too.
    def test_linux_artifact_runs_the_browser_bridge_stage_too(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(
            create_disclaim=False,
            migrate="refused:not_macos",
            browser_bridge="noisy_stdout",
        )

        result = self._run("linux_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wrote to stdout, which is the native-messaging wire", result.stderr)

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
        plugins_clear="forgets",
        browser_bridge="works",
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
            'if [ "${1:-}" = "plugins" ]; then\n'
            f"{self._plugins_clear_behaviour(plugins_clear)}"
            "fi\n"
            'if [ "${1:-}" = "browser" ]; then\n'
            f"{self._browser_behaviour(browser_bridge)}"
            "fi\n"
            'if [ "${1:-}" = "browser-bridge" ]; then\n'
            f"{self._pump_behaviour(browser_bridge)}"
            "fi\n"
            f"printf 'fermix {version}\\n'\n",
            encoding="utf-8",
        )
        self.artifact.chmod(0o755)

    # The real verb's shape: the one keychain delete, named by the throwaway
    # home's own profile, answered "not found" by the stand-in on PATH.
    # ── the browser-bridge stub ───────────────────────────────────────────
    # The install writes a manifest in BOTH the macOS and the Linux location,
    # because the stage picks the one its TARGET names while these tests run on
    # whatever host they run on. The wrapper names this artifact as its
    # launcher, which is the one path a real install has to get right.
    def _browser_behaviour(self, browser_bridge):
        if browser_bridge == "no_manifest":
            return (
                "  printf 'Installed the Fermix browser bridge for chrome.\\n'\n"
                "  exit 0\n"
            )
        return (
            '  if [ "$2" = "bridge" ] && [ "$3" = "install" ]; then\n'
            '    mac="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"\n'
            '    lin="$HOME/.config/google-chrome/NativeMessagingHosts"\n'
            '    mkdir -p "$mac" "$lin" "$FERMIX_HOME/bin"\n'
            '    for dir in "$mac" "$lin"; do\n'
            '      printf \'{"name":"ai.fermix.bridge","type":"stdio","path":"%s",'
            '"allowed_origins":["chrome-extension://%s/"]}\\n\''
            ' "$FERMIX_HOME/bin/fermix-browser-bridge-chrome" "$7" > "$dir/ai.fermix.bridge.json"\n'
            "    done\n"
            '    printf \'#!/bin/sh\\nexec \'"\'"\'%s\'"\'"\' browser-bridge --manifest'
            ' \'"\'"\'%s\'"\'"\' "$@"\\n\' "$0" "$mac/ai.fermix.bridge.json"'
            ' > "$FERMIX_HOME/bin/fermix-browser-bridge-chrome"\n'
            '    chmod +x "$FERMIX_HOME/bin/fermix-browser-bridge-chrome"\n'
            "    printf 'Installed the Fermix browser bridge for chrome.\\n'\n"
            "    exit 0\n"
            "  fi\n"
            '  if [ "$2" = "bridge" ] && [ "$3" = "status" ]; then\n'
            "    printf 'chrome: installed\\n'\n"
            '    printf \'  Launcher: %s (present)\\n\' "$FERMIX_HOME/bin/fermix-browser-bridge-chrome"\n'
            "    printf 'Daemon: not reachable. Start it with `fermix run`.\\n'\n"
            "    exit 0\n"
            "  fi\n"
            "  exit 64\n"
        )

    def _pump_behaviour(self, browser_bridge):
        noise = (
            "  printf 'boot warning nobody asked for\\n'\n"
            if browser_bridge == "noisy_stdout"
            else ""
        )
        admitted = (
            "  "
            if browser_bridge == "admits_any_origin"
            else '  if grep -Fq "$4" "$3"; then\n  '
        )
        tail = "" if browser_bridge == "admits_any_origin" else (
            "  else\n"
            '    printf \'fermix browser-bridge: %s is not listed in %s.\\n\' "$4" "$3" >&2\n'
            "    exit 1\n"
            "  fi\n"
        )
        return (
            f"{noise}"
            f"{admitted}"
            "  printf 'fermix browser-bridge: the Fermix daemon is not running"
            " — start it with `fermix run`\\n' >&2\n"
            "    exit 1\n"
            f"{tail}"
        )

    def _plugins_clear_behaviour(self, plugins_clear):
        forget = (
            '  [ "$*" = "plugins auth clear discord" ] || exit 64\n'
            "  profile=\"$(sed -n 's/^profile = \"\\(.*\\)\"$/\\1/p'"
            ' "$FERMIX_HOME/config.toml")"\n'
            "  delete_status=0\n"
            '  security delete-generic-password -a fermix -s "fermix:$profile:FERMIX_PLUGIN_DISCORD"'
            " >/dev/null || delete_status=$?\n"
            '  [ "$delete_status" -eq 44 ] || exit 3\n'
        )
        forgotten = (
            "  printf 'deleted the stored api key for discord"
            " — revoke it with the provider too\\n'\n"
            "  exit 0\n"
        )
        if plugins_clear == "forgets":
            return forget + forgotten
        if plugins_clear == "strict_keychain":
            return self._unknown_keychain_argv_is_refused() + forget + forgotten
        if plugins_clear == "no_helper":
            return forgotten
        if plugins_clear == "needs_command_host":
            return (
                "  printf 'fermix: unexpected error — CommandRunner: command host supervisor"
                " FermixCore.CommandHost.Supervisor is not running.\\n' >&2\n"
                "  exit 1\n"
            )
        if plugins_clear == "refused":
            return (
                "  printf 'fermix plugins: {:keychain_delete_failed, FERMIX_PLUGIN_DISCORD}\\n' >&2\n"
                "  exit 1\n"
            )
        raise ValueError(f"unknown plugins clear behaviour: {plugins_clear}")

    def _unknown_keychain_argv_is_refused(self):
        return (
            "  keychain_status=0\n"
            "  security find-generic-password -a fermix -s unexpected -w >/dev/null 2>&1"
            " || keychain_status=$?\n"
            '  [ "$keychain_status" -ne 0 ] || exit 7\n'
        )

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
