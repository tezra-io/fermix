#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for standalone release smoke verification."""

import hashlib
import json
import os
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("verify_standalone.sh")
VERSION = "0.9.0"
IROH_VERSION_LINE = "fermix-iroh 0.1.0 (iroh 1.3.0)"
IROH_TEAM_ID = "ABCDE12345"
TARGETS = ("linux_aarch64", "linux_x86_64", "macos_aarch64", "macos_x86_64")


class VerifyStandaloneTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-standalone-verify-")
        self.base = Path(self.tmp.name)
        self.artifact = self.base / "fermix_macos_aarch64"
        self.pin = self.base / "PIN.json"
        self.helper_source = self.base / "helper-payload" / "fermix-iroh"
        self.notices_source = self.base / "helper-payload" / "THIRD-PARTY-NOTICES.txt"
        self.empty_payload = self.base / "empty-payload"
        self.pinned_digest = None
        self.pinned_notices_digest = None
        self.codesign_bin = self.base / "codesign-bin"
        self.codesign_log = self.base / "codesign.log"

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

    # ── the tree-less auth logout stage ───────────────────────────────────

    def test_rejects_a_logout_that_does_not_report_the_removed_entry(self):
        self._write_artifact(create_disclaim=True, auth_logout="silent")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("auth logout did not report the removed entry", result.stderr)

    def test_rejects_a_logout_that_leaves_the_tokens(self):
        self._write_artifact(create_disclaim=True, auth_logout="keeps_tokens")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("left the ChatGPT tokens in auth.json", result.stderr)

    def test_rejects_a_logout_that_leaves_a_lockfile(self):
        self._write_artifact(create_disclaim=True, auth_logout="leaves_lock")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("auth logout left a lockfile behind", result.stderr)

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

    # ── the settings no-daemon stage ──────────────────────────────────────

    def test_settings_with_no_daemon_refuses_with_exit_3_and_one_json_object(self):
        self._write_artifact(create_disclaim=True)

        result = self._run("macos_aarch64")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("settings change only through it", result.stdout)

    # The release that lacks the verb: the dispatcher's unknown-command exit.
    def test_rejects_an_artifact_without_the_settings_verb(self):
        self._write_artifact(create_disclaim=True, settings="unknown_verb")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must exit 3, got 2", result.stderr)

    # Exit 1 is the older management clients' not-running code; settings
    # reserves 3 for it so a script can tell "no daemon" from "refused".
    def test_rejects_a_settings_verb_that_exits_1_with_no_daemon(self):
        self._write_artifact(create_disclaim=True, settings="exit_one")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must exit 3, got 1", result.stderr)

    # The class this stage exists for: boot logging on stdout in the packaged
    # runtime, ahead of the one JSON object a script parses.
    def test_rejects_settings_json_with_a_log_line_on_stdout(self):
        self._write_artifact(create_disclaim=True, settings="noisy_stdout")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must print exactly", result.stderr)

    def test_rejects_settings_that_prints_its_sentence_on_stdout(self):
        self._write_artifact(create_disclaim=True, settings="human_stdout")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must print exactly", result.stderr)

    def test_rejects_settings_that_does_not_say_why_on_stderr(self):
        self._write_artifact(create_disclaim=True, settings="silent")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not say on stderr why it changed nothing", result.stderr)

    # The stage runs before migrate-to-app, which ends the script on Linux.
    def test_linux_artifact_runs_the_settings_stage_too(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(
            create_disclaim=False,
            migrate="refused:not_macos",
            settings="exit_one",
        )

        result = self._run("linux_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must exit 3, got 1", result.stderr)

    # ── the fermix home stage ─────────────────────────────────────────────

    def test_home_exports_imports_and_marks_moved_once(self):
        self._write_artifact(create_disclaim=True)

        result = self._run("macos_aarch64")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("primary epoch: 5", result.stdout)
        self.assertIn("at primary epoch 6.", result.stdout)

    # The release that lacks the verb: the dispatcher's unknown-command exit.
    def test_rejects_an_artifact_without_the_home_verb(self):
        self._write_artifact(create_disclaim=True, home="unknown_verb")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fermix home export must exit 0 in the throwaway world, got 2", result.stderr)

    def test_rejects_a_mark_moved_that_marks_a_moved_home_again(self):
        self._write_artifact(create_disclaim=True, home="marks_twice")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("a second fermix home mark-moved must exit 1, got 0", result.stderr)

    def test_rejects_a_mark_moved_that_writes_no_marker(self):
        self._write_artifact(create_disclaim=True, home="not_moved")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fermix home mark-moved wrote no marker", result.stderr)

    def test_rejects_a_home_status_that_does_not_read_the_epoch(self):
        self._write_artifact(create_disclaim=True, home="status_blind")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fermix home status did not read the home's primary epoch", result.stderr)

    # The class the enroll stage exists for: the packaged binary taking a code
    # file that holds no enrollment code and making the home a candidate anyway.
    def test_rejects_an_enroll_that_accepts_an_invalid_code(self):
        self._write_artifact(create_disclaim=True, home="enroll_accepts")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fermix home enroll with an invalid code must exit 1, got 0", result.stderr)

    def test_rejects_an_enroll_refusal_that_leaves_a_home_behind(self):
        self._write_artifact(create_disclaim=True, home="enroll_leaves_home")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fermix home enroll left a home behind", result.stderr)

    def test_rejects_an_enroll_refusal_that_removes_the_code_file(self):
        self._write_artifact(create_disclaim=True, home="enroll_consumes")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fermix home enroll removed the code file it refused", result.stderr)

    # The stage runs before migrate-to-app, which ends the script on Linux.
    def test_linux_artifact_runs_the_home_stage_too(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(create_disclaim=False, migrate="refused:not_macos", home="unknown_verb")

        result = self._run("linux_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fermix home export must exit 0 in the throwaway world, got 2", result.stderr)

    # Every run passes its own pin, written for the target it verifies, and puts
    # a stand-in `codesign` first on PATH: the macOS rows must not depend on the
    # host's signing tools, and a Linux host has none.
    #
    # The stub resolves its payload directory the way Burrito does, so the
    # host's own data-directory overrides are dropped: one would move the
    # stub's unpack out of the throwaway world and onto the host. A test that
    # needs one passes it in `extra_env`.
    def _run(self, target, artifact=None, cwd=None, codesign="team", pin_entry=True, pin_changes=None, extra_env=None):
        self._write_pin(target, pin_entry, pin_changes)
        self._write_codesign(codesign)
        environment = {
            name: value for name, value in os.environ.items() if name not in ("XDG_DATA_HOME", "FERMIX_INSTALL_DIR")
        }
        return subprocess.run(
            [str(SCRIPT), artifact or str(self.artifact), target, VERSION, str(self.pin)],
            cwd=cwd,
            env={**environment, "PATH": f"{self.codesign_bin}:{os.environ['PATH']}", **(extra_env or {})},
            text=True,
            capture_output=True,
            check=False,
        )

    # The staged-asset stage passes the bare downloaded file name from the
    # working directory; a name with no slash must not be looked up on PATH.
    def test_accepts_a_bare_artifact_name_in_the_working_directory(self):
        self._write_artifact(create_disclaim=True)

        result = self._run("macos_aarch64", artifact=self.artifact.name, cwd=self.artifact.parent)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"fermix {VERSION}", result.stdout)

    # ── the bundled fermix-iroh helper stage ──────────────────────────────

    def test_checks_the_pinned_signed_helper_on_macos(self):
        self._write_artifact(create_disclaim=True)

        result = self._run("macos_aarch64")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"({IROH_VERSION_LINE})", result.stdout)
        calls = self.codesign_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual([call.split(" /", 1)[0] for call in calls], ["--verify --strict", "-dv"])

    # The stage runs before migrate-to-app, which ends the script on Linux, and
    # a Linux tree carries no signature to check.
    def test_linux_artifact_checks_the_helper_without_codesign(self):
        self.artifact = self.base / "fermix_linux_aarch64"
        self._write_artifact(create_disclaim=False, migrate="refused:not_macos")

        result = self._run("linux_aarch64")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"({IROH_VERSION_LINE})", result.stdout)
        self.assertFalse(self.codesign_log.exists())

    # ── the bundled Landlock shim stage (Linux) ───────────────────────────

    def test_linux_artifact_checks_the_landlock_shim(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(create_disclaim=False, migrate="refused:not_macos")

        result = self._run("linux_x86_64")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(
            result.stdout,
            r"Landlock shim: .+/lib/fermix_nif-0\.9\.0/priv/fermix_landlock \(fermix_landlock: abi 6\)\n",
        )

    # A release runner whose kernel has no Landlock still proves the shim runs.
    def test_accepts_a_shim_that_says_landlock_is_unavailable_here(self):
        self.artifact = self.base / "fermix_linux_aarch64"
        self._write_artifact(create_disclaim=False, migrate="refused:not_macos", landlock_shim="unavailable")

        result = self._run("linux_aarch64")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("(fermix_landlock: Landlock is unavailable on this kernel", result.stdout)

    def test_rejects_a_linux_release_without_the_landlock_shim(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(create_disclaim=False, migrate="refused:not_macos", landlock_shim="missing")

        result = self._run("linux_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must carry exactly one Landlock shim", result.stderr)
        self.assertIn("found 0", result.stderr)

    def test_rejects_a_linux_release_with_two_landlock_shims(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(create_disclaim=False, migrate="refused:not_macos", landlock_shim="two")

        result = self._run("linux_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 2", result.stderr)

    def test_rejects_a_landlock_shim_that_is_not_an_executable_file(self):
        for behaviour in ("not_executable", "symlink"):
            with self.subTest(behaviour=behaviour):
                self.artifact = self.base / "fermix_linux_x86_64"
                self._write_artifact(create_disclaim=False, migrate="refused:not_macos", landlock_shim=behaviour)

                result = self._run("linux_x86_64")

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Landlock shim is not an executable regular file", result.stderr)

    def test_rejects_a_dynamically_linked_landlock_shim_before_running_it(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(create_disclaim=False, migrate="refused:not_macos", landlock_shim="dynamic")

        result = self._run("linux_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Landlock shim is dynamically linked", result.stderr)

    def test_rejects_a_landlock_shim_that_does_not_answer_its_abi(self):
        for behaviour in ("wrong_answer", "silent_success"):
            with self.subTest(behaviour=behaviour):
                self.artifact = self.base / "fermix_linux_x86_64"
                self._write_artifact(create_disclaim=False, migrate="refused:not_macos", landlock_shim=behaviour)

                result = self._run("linux_x86_64")

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Landlock shim --abi must print its ABI", result.stderr)

    def test_a_macos_release_needs_no_landlock_shim(self):
        self._write_artifact(create_disclaim=True)

        result = self._run("macos_aarch64")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Landlock shim", result.stdout)

    def test_rejects_a_release_without_the_helper(self):
        self._write_artifact(create_disclaim=True, iroh_helper="missing")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must carry exactly one fermix-iroh helper", result.stderr)
        self.assertIn("found 0: none", result.stderr)

    def test_rejects_a_linux_release_without_the_helper(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(create_disclaim=False, migrate="refused:not_macos", iroh_helper="missing")

        result = self._run("linux_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must carry exactly one fermix-iroh helper", result.stderr)

    def test_rejects_a_release_with_two_helpers(self):
        self._write_artifact(create_disclaim=True, iroh_helper="two")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must carry exactly one fermix-iroh helper", result.stderr)
        self.assertIn("found 2:", result.stderr)
        self.assertIn("fermix_core-0.8.0", result.stderr)

    def test_rejects_a_helper_that_is_not_executable(self):
        self._write_artifact(create_disclaim=True, iroh_helper="not_executable")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fermix-iroh helper is not executable", result.stderr)

    def test_rejects_a_helper_whose_digest_is_not_the_pinned_one(self):
        self._write_artifact(create_disclaim=True, iroh_helper="other_bytes")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not the pinned macos_aarch64 build", result.stderr)
        self.assertIn(f"expected sha256 {self.pinned_digest}", result.stderr)
        self.assertIn(f"found {self._sha256(self.helper_source)}", result.stderr)

    def test_rejects_a_linux_helper_whose_digest_is_not_the_pinned_one(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        self._write_artifact(create_disclaim=False, migrate="refused:not_macos", iroh_helper="other_bytes")

        result = self._run("linux_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not the pinned linux_x86_64 build", result.stderr)

    # The pin names a digest per target; the one for another target is not this
    # tree's, so a stage that read the wrong entry fails here.
    def test_rejects_a_helper_pinned_for_another_target(self):
        self._write_artifact(create_disclaim=True)

        result = self._run("macos_x86_64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not the pinned macos_x86_64 build", result.stderr)

    def test_rejects_a_helper_whose_version_is_not_the_pinned_one(self):
        self._write_artifact(create_disclaim=True, iroh_helper="other_version")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"--version must print exactly '{IROH_VERSION_LINE}'", result.stderr)
        self.assertIn("got 'fermix-iroh 0.1.0 (iroh 1.2.0)'", result.stderr)

    def test_rejects_a_helper_whose_version_command_fails(self):
        self._write_artifact(create_disclaim=True, iroh_helper="version_fails")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fermix-iroh helper --version failed", result.stderr)

    def test_rejects_a_macos_helper_that_fails_strict_signature_verification(self):
        self._write_artifact(create_disclaim=True)

        result = self._run("macos_aarch64", codesign="unsigned")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not pass codesign --verify --strict", result.stderr)
        self.assertIn("code object is not signed at all", result.stderr)

    def test_rejects_a_macos_helper_signed_by_another_team(self):
        self.artifact = self.base / "fermix_macos_x86_64"
        self._write_artifact(create_disclaim=True)

        result = self._run("macos_x86_64", codesign="other_team")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"must be signed by team {IROH_TEAM_ID}, found ZYXWV98765", result.stderr)

    # The stage asks the wrapper where it unpacked its payload; a wrapper that
    # cannot say is a refusal, not a search of whatever lies under the home.
    def test_rejects_a_wrapper_that_cannot_name_its_payload_directory(self):
        self._write_artifact(create_disclaim=True, maintenance="fails")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("maintenance directory did not name the unpacked payload", result.stderr)

    def test_rejects_a_payload_directory_that_does_not_exist(self):
        self._write_artifact(create_disclaim=True, maintenance="names_a_missing_directory")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"the unpacked payload directory does not exist: {self.base / 'no-such-payload'}", result.stderr)

    # The run above still unpacked a helper under the isolated home, so a stage
    # that searched the home would pass; only the directory the wrapper names
    # counts.
    def test_rejects_a_payload_directory_the_wrapper_names_without_the_helper(self):
        self._write_artifact(create_disclaim=True, maintenance="names_an_empty_directory")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must carry exactly one fermix-iroh helper", result.stderr)
        self.assertIn(f"under {self.empty_payload}), found 0: none", result.stderr)

    # Burrito unpacks into $XDG_DATA_HOME/.burrito on Linux when it is set,
    # outside the isolated home; the stage follows the wrapper there.
    def test_finds_the_helper_where_the_wrapper_unpacked_it_outside_the_home(self):
        self.artifact = self.base / "fermix_linux_x86_64"
        data_home = self.base / "xdg-data"
        self._write_artifact(create_disclaim=False, migrate="refused:not_macos")

        result = self._run("linux_x86_64", extra_env={"XDG_DATA_HOME": str(data_home)})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"fermix-iroh helper: {data_home}/.burrito/fermix_erts-15.2.7_{VERSION}/lib/fermix_core-{VERSION}/",
            result.stdout,
        )

    def test_rejects_a_missing_pin_before_running_the_artifact(self):
        marker = self.base / "ran"
        self._write_artifact(create_disclaim=True, marker=marker)
        self._write_codesign("team")

        result = subprocess.run(
            [str(SCRIPT), str(self.artifact), "macos_aarch64", VERSION, str(self.base / "absent.json")],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("iroh helper pin not found", result.stderr)
        self.assertFalse(marker.exists())

    def test_rejects_a_pin_without_this_target_before_running_the_artifact(self):
        marker = self.base / "ran"
        self._write_artifact(create_disclaim=True, marker=marker)

        result = self._run("macos_aarch64", pin_entry=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no sha256 for macos_aarch64", result.stderr)
        self.assertFalse(marker.exists())

    # A pin from before the notices names none, so it cannot say which bytes
    # the payload must carry beside the helper.
    def test_rejects_a_pin_without_the_notices_before_running_the_artifact(self):
        for changes, message in (
            ({"notices": None}, "has no sha256 for the notices"),
            ({"schema_version": 1}, "is not schema_version 2"),
        ):
            with self.subTest(changes=changes):
                marker = self.base / "ran"
                self._write_artifact(create_disclaim=True, marker=marker)

                result = self._run("macos_aarch64", pin_changes=changes)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(marker.exists())

    # ── the fermix-iroh third-party notices beside the helper ─────────────

    def test_checks_the_pinned_notices_beside_the_helper(self):
        for target in ("macos_aarch64", "linux_x86_64"):
            with self.subTest(target=target):
                self.artifact = self.base / f"fermix_{target}"
                linux = target.startswith("linux_")
                self._write_artifact(create_disclaim=not linux, migrate="refused:not_macos" if linux else "plan")

                result = self._run(target)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertRegex(
                    result.stdout, r"fermix-iroh notices: .+/fermix_core-0\.9\.0/priv/iroh_helper/THIRD-PARTY-NOTICES\.txt\n"
                )

    def test_rejects_a_release_without_the_notices(self):
        for target in ("macos_aarch64", "linux_x86_64"):
            with self.subTest(target=target):
                self.artifact = self.base / f"fermix_{target}"
                linux = target.startswith("linux_")
                self._write_artifact(
                    create_disclaim=not linux, migrate="refused:not_macos" if linux else "plan", iroh_notices="missing"
                )

                result = self._run(target)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must carry the fermix-iroh third-party notices as a regular file", result.stderr)

    def test_rejects_notices_that_are_a_symbolic_link(self):
        self._write_artifact(create_disclaim=True, iroh_notices="symlink")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must carry the fermix-iroh third-party notices as a regular file", result.stderr)

    def test_rejects_notices_whose_digest_is_not_the_pinned_one(self):
        self._write_artifact(create_disclaim=True, iroh_notices="other_bytes")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the fermix-iroh notices are not the pinned ones", result.stderr)
        self.assertIn(f"expected sha256 {self.pinned_notices_digest}", result.stderr)
        self.assertIn(f"found {self._sha256(self.notices_source)}", result.stderr)

    def test_rejects_notices_that_are_not_mode_0644(self):
        self._write_artifact(create_disclaim=True, iroh_notices="executable")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the fermix-iroh notices must be mode 0644, found 0755", result.stderr)

    # The pin as `pin_iroh_helper.py` writes it: one digest per target, the
    # target under test holding this tree's helper and every other target a
    # different build's.
    def _write_pin(self, target, pin_entry=True, pin_changes=None):
        digests = {name: hashlib.sha256(f"another build for {name}".encode()).hexdigest() for name in TARGETS}
        if self.pinned_digest is not None:
            digests[self._artifact_target()] = self.pinned_digest
        if not pin_entry:
            del digests[target]
        pin = {
            "schema_version": 2,
            "repository": "tezra-io/fermix-iroh",
            "tag": "v0.1.0",
            "version": "0.1.0",
            "protocol_version": 1,
            "iroh_version": "1.3.0",
            "certificate_identity": "https://github.com/tezra-io/fermix-iroh/.github/workflows/release.yml@refs/tags/v0.1.0",
            "certificate_oidc_issuer": "https://token.actions.githubusercontent.com",
            "macos_team_id": IROH_TEAM_ID,
            "notices": {"asset": "fermix-iroh-THIRD-PARTY-NOTICES.txt", "sha256": self.pinned_notices_digest},
            "targets": {name: {"asset": f"fermix-iroh-{name}", "sha256": digests[name]} for name in digests},
        }
        # A change to None drops the key, as a pin from before it would.
        for key, value in (pin_changes or {}).items():
            if value is None:
                del pin[key]
            else:
                pin[key] = value
        self.pin.write_text(json.dumps(pin, indent=2) + "\n", encoding="utf-8")

    def _artifact_target(self):
        return self.artifact.name.removeprefix("fermix_")

    # A stand-in for the two codesign calls the stage makes, on the helper it
    # found, and nothing else: any other argv exits 64, so a codesign call added
    # later cannot pass this gate unanswered. Every call is recorded.
    def _write_codesign(self, behaviour):
        verify = {
            "team": "    exit 0\n",
            "other_team": "    exit 0\n",
            "unsigned": "    printf '%s: code object is not signed at all\\n' \"$3\" >&2\n    exit 1\n",
        }[behaviour]
        team = "ZYXWV98765" if behaviour == "other_team" else IROH_TEAM_ID
        self.codesign_bin.mkdir(exist_ok=True)
        script = self.codesign_bin / "codesign"
        script.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$*\" >> '{self.codesign_log}'\n"
            'case "$*" in\n'
            "  *' '*/fermix_core-*/priv/iroh_helper/bin/fermix-iroh) ;;\n"
            "  *) printf 'stand-in codesign: unexpected path: %s\\n' \"$*\" >&2 ; exit 64 ;;\n"
            "esac\n"
            'if [ "$#" -eq 3 ] && [ "$1" = "--verify" ] && [ "$2" = "--strict" ]; then\n'
            f"{verify}"
            "fi\n"
            'if [ "$#" -eq 2 ] && [ "$1" = "-dv" ]; then\n'
            "  printf 'Executable=%s\\nIdentifier=fermix-iroh\\n' \"$2\" >&2\n"
            f"  printf 'TeamIdentifier={team}\\n' >&2\n"
            "  exit 0\n"
            "fi\n"
            "printf 'stand-in codesign: unexpected invocation: codesign %s\\n' \"$*\" >&2\n"
            "exit 64\n",
            encoding="utf-8",
        )
        script.chmod(0o755)

    @staticmethod
    def _sha256(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

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
        auth_logout="removes",
        browser_bridge="works",
        settings="refuses",
        home="carries",
        iroh_helper="pinned",
        iroh_notices="pinned",
        maintenance="answers",
        landlock_shim="answers",
    ):
        setup = self._disclaim_setup(create_disclaim, disclaim_executable, disclaim_exit, version)
        helper_setup = self._iroh_helper_setup(iroh_helper, iroh_notices, version)
        helper_setup += self._landlock_shim_setup(landlock_shim, version)
        marker_line = "" if marker is None else f"touch '{marker}'\n"
        self.empty_payload.mkdir(exist_ok=True)
        self.artifact.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            f"{marker_line}"
            f"{self._payload_line(version)}"
            'if [ "${1:-}" = "maintenance" ]; then\n'
            f"{self._maintenance_behaviour(maintenance)}"
            "fi\n"
            f"{setup}\n"
            f"{helper_setup}"
            'if [ "${1:-}" = "migrate-to-app" ]; then\n'
            f"{self._migrate_behaviour(migrate, version)}"
            "fi\n"
            'if [ "${1:-}" = "plugins" ]; then\n'
            f"{self._plugins_clear_behaviour(plugins_clear)}"
            "fi\n"
            'if [ "${1:-}" = "auth" ]; then\n'
            f"{self._auth_logout_behaviour(auth_logout)}"
            "fi\n"
            'if [ "${1:-}" = "browser" ]; then\n'
            f"{self._browser_behaviour(browser_bridge)}"
            "fi\n"
            'if [ "${1:-}" = "browser-bridge" ]; then\n'
            f"{self._pump_behaviour(browser_bridge)}"
            "fi\n"
            'if [ "${1:-}" = "settings" ]; then\n'
            f"{self._settings_behaviour(settings)}"
            "fi\n"
            'if [ "${1:-}" = "home" ]; then\n'
            f"{self._home_behaviour(home)}"
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

    # The real verb's shape with no daemon: one JSON object on stdout, the
    # sentence on stderr, exit 3. The argv is pinned so a stage that stops
    # asking for `--json` cannot pass against this stub.
    def _settings_behaviour(self, settings):
        if settings == "unknown_verb":
            return (
                "  printf 'fermix: unknown command: settings\\n' >&2\n"
                "  exit 2\n"
            )
        argv = '  [ "$*" = "settings --json" ] || exit 64\n'
        noise = "  printf 'boot notice nobody asked for\\n'\n"
        json = "  printf '{\"error\":{\"code\":\"not_running\"}}\\n'\n"
        sentence = (
            "  printf 'fermix settings: the Fermix daemon is not running,"
            " and settings change only through it.\\n'"
        )
        if settings == "refuses":
            return argv + json + sentence + " >&2\n" + "  exit 3\n"
        if settings == "exit_one":
            return argv + json + sentence + " >&2\n" + "  exit 1\n"
        if settings == "noisy_stdout":
            return argv + noise + json + sentence + " >&2\n" + "  exit 3\n"
        if settings == "human_stdout":
            return argv + sentence + "\n" + "  exit 3\n"
        if settings == "silent":
            return argv + json + "  exit 3\n"
        raise ValueError(f"unknown settings behaviour: {settings}")

    # The real verbs' shapes in the throwaway world: export seals the home the
    # environment names, import makes the next primary with the home's own path
    # moved, and mark-moved writes the marker once and refuses the second time.
    def _home_behaviour(self, home):
        if home == "unknown_verb":
            return "  printf 'fermix: unknown command: home\\n' >&2\n  exit 2\n"
        export = (
            '  if [ "$2" = "export" ]; then\n'
            '    [ "$4" = "--passphrase-file" ] || exit 64\n'
            '    epoch="$(cat "$FERMIX_HOME/mobile/primary_epoch")"\n'
            '    printf \'sealed\\n\' > "$3"\n'
            "    printf 'Exported %s to %s\\n  primary epoch: %s\\n' \"$FERMIX_HOME\" \"$3\" \"$epoch\"\n"
            "    exit 0\n"
            "  fi\n"
        )
        moved_path = "" if home == "not_moved" else (
            '    printf \'{"ok":true}\\n\' > "$FERMIX_HOME/moved.json"\n'
        )
        restored = (
            '  if [ "$2" = "import" ]; then\n'
            '    [ "$4" = "--into" ] && [ "$6" = "--passphrase-file" ] || exit 64\n'
            '    mkdir -p "$5/mobile"\n'
            "    printf '6\\n' > \"$5/mobile/primary_epoch\"\n"
            "    printf '[sandbox]\\nworkspace_root = \"%s/workspace\"\\n' \"$5\" > \"$5/config.toml\"\n"
            "    printf 'Restored 2 files into %s at primary epoch 6.\\n' \"$5\"\n"
            "    exit 0\n"
            "  fi\n"
        )
        marked = (
            '  [ "$*" = "home mark-moved --to verify-host --json" ] || exit 64\n'
            '  if [ -e "$FERMIX_HOME/moved.json" ]; then\n'
            '    printf \'{"error":{"code":"already_moved","sentence":"moved"},"ok":false}\\n\'\n'
            "    exit 1\n"
            "  fi\n"
            f"{moved_path}"
            '  printf \'{"ok":true,"result":{"epoch":5}}\\n\'\n'
            "  exit 0\n"
        )
        status = (
            '  if [ "$2" = "status" ]; then\n'
            '    [ "$3" = "--json" ] || exit 64\n'
            '    epoch="$(cat "$FERMIX_HOME/mobile/primary_epoch")"\n'
            + ("    epoch=null\n" if home == "status_blind" else "")
            + '    printf \'{"ok":true,"result":{"role":"primary","epoch":%s}}\\n\' "$epoch"\n'
            "    exit 0\n"
            "  fi\n"
        )
        if home == "marks_twice":
            marked = (
                '  : > "$FERMIX_HOME/moved.json"\n'
                '  printf \'{"ok":true,"result":{"epoch":5}}\\n\'\n'
                "  exit 0\n"
            )
        enroll = self._enroll_behaviour(home)
        if home in (
            "carries",
            "marks_twice",
            "not_moved",
            "status_blind",
            "enroll_accepts",
            "enroll_leaves_home",
            "enroll_consumes",
        ):
            return export + restored + status + enroll + marked
        raise ValueError(f"unknown home behaviour: {home}")

    # The real verb refuses a code file that holds no enrollment code: one
    # sentence on stderr, exit 1, and the home and the code file as it found
    # them. Each other shape is one way a release could get that wrong.
    @staticmethod
    def _enroll_behaviour(home):
        refusal = (
            "    printf 'fermix home enroll: That is not an enrollment code Fermix opened (json). "
            "Copy the code again.\\n' >&2\n"
            "    exit 1\n"
        )
        effect = {
            "enroll_accepts": (
                '    mkdir -p "$FERMIX_HOME/candidate"\n'
                '    rm -f "$4"\n'
                "    printf 'This home is now a candidate of studio-mac.\\n'\n"
                "    exit 0\n"
            ),
            "enroll_leaves_home": '    mkdir -p "$FERMIX_HOME/logs"\n' + refusal,
            "enroll_consumes": '    rm -f "$4"\n' + refusal,
        }.get(home, refusal)
        return (
            '  if [ "$2" = "enroll" ]; then\n'
            '    [ "$3" = "--code-file" ] && [ -f "$4" ] || exit 64\n'
            f"{effect}"
            "  fi\n"
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

    # The real verb's shape: the seeded ChatGPT sign-in's tokens leave auth.json
    # while its registration stays, signed out; the sentence says so, and no
    # lockfile stays beside auth.json.
    def _auth_logout_behaviour(self, auth_logout):
        argv = '  [ "$*" = "auth logout" ] || exit 64\n'
        cleared = (
            "  printf '{\"version\": 2, \"providers\": {\"chatgpt\": "
            "{\"auth_mode\": \"oauth_siwc\", \"status\": \"signed_out\", "
            "\"tokens\": {\"access_token\": null, \"refresh_token\": null}}}}\\n'"
            ' > "$FERMIX_HOME/auth.json"\n'
        )
        reported = (
            "  printf 'Logged out of ChatGPT. Cleared its tokens in %s.\\n'"
            ' "$FERMIX_HOME/auth.json"\n'
        )
        lock = '  : > "$FERMIX_HOME/auth.json.lock"\n'
        done = "  exit 0\n"
        if auth_logout == "removes":
            return argv + cleared + reported + done
        if auth_logout == "silent":
            return argv + cleared + done
        if auth_logout == "keeps_tokens":
            return argv + reported + done
        if auth_logout == "leaves_lock":
            return argv + cleared + lock + reported + done
        raise ValueError(f"unknown auth logout behaviour: {auth_logout}")

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

    # ── the Burrito wrapper's payload directory ───────────────────────────
    # Where the wrapper unpacks its payload, resolved as Burrito 1.5's
    # `getAppDataDir` resolves it: the macOS application-support directory, or
    # on Linux `$XDG_DATA_HOME` when it is set and `~/.local/share` when not.
    def _payload_line(self, version):
        base = (
            "${XDG_DATA_HOME:-$HOME/.local/share}/.burrito"
            if self._artifact_target().startswith("linux_")
            else "$HOME/Library/Application Support/.burrito"
        )
        return f'payload="{base}/fermix_erts-15.2.7_{version}"\n'

    # The wrapper's own verb, answered before anything is unpacked, as Burrito
    # answers it: the payload directory on stdout, exit 0. The argv is pinned so
    # a stage that asks for anything else cannot pass against this stub.
    def _maintenance_behaviour(self, maintenance):
        argv = '  [ "$*" = "maintenance directory" ] || exit 64\n'
        if maintenance == "answers":
            return argv + "  printf '%s\\n' \"$payload\"\n  exit 0\n"
        if maintenance == "fails":
            return argv + "  printf 'stand-in wrapper: cannot resolve the install directory\\n' >&2\n  exit 1\n"
        if maintenance == "names_an_empty_directory":
            return argv + f"  printf '%s\\n' '{self.empty_payload}'\n  exit 0\n"
        if maintenance == "names_a_missing_directory":
            return argv + f"  printf '%s\\n' '{self.base / 'no-such-payload'}'\n  exit 0\n"
        raise ValueError(f"unknown maintenance behaviour: {maintenance}")

    # ── the fermix-iroh helper stub ───────────────────────────────────────
    # Every run of the stub unpacks its payload where the wrapper names it, and
    # the helper and its notices into that payload from source files whose
    # bytes the pin names (or, for `other_bytes`, does not). A release without
    # the helper still unpacks its payload.
    def _iroh_helper_setup(self, behaviour, notices, version):
        version_line = "fermix-iroh 0.1.0 (iroh 1.2.0)" if behaviour == "other_version" else IROH_VERSION_LINE
        answer = "exit 70" if behaviour == "version_fails" else f"printf '%s\\n' '{version_line}'"
        self.helper_source.parent.mkdir(exist_ok=True)
        self.helper_source.write_text(
            f'#!/bin/sh\n[ "$*" = "--version" ] || exit 64\n{answer}\n', encoding="utf-8"
        )
        self.pinned_digest = (
            hashlib.sha256(b"another fermix-iroh build").hexdigest()
            if behaviour == "other_bytes"
            else self._sha256(self.helper_source)
        )
        self.notices_source.write_text("MIT License\n\nCopyright (c) 2026 Tezra.io\n", encoding="utf-8")
        self.pinned_notices_digest = (
            hashlib.sha256(b"other notices").hexdigest()
            if notices == "other_bytes"
            else self._sha256(self.notices_source)
        )
        lines = ['mkdir -p "$payload/lib"']
        if behaviour == "missing":
            return "\n".join(lines) + "\n"

        app_versions = [version, "0.8.0"] if behaviour == "two" else [version]
        mode = "-x" if behaviour == "not_executable" else "+x"
        for app_version in app_versions:
            lines += [
                f'iroh="$payload/lib/fermix_core-{app_version}/priv/iroh_helper/bin"',
                'mkdir -p "$iroh"',
                f"cp '{self.helper_source}' \"$iroh/fermix-iroh\"",
                f'chmod {mode} "$iroh/fermix-iroh"',
                *self._iroh_notices_lines(notices),
            ]
        return "\n".join(lines) + "\n"

    def _iroh_notices_lines(self, notices):
        target = '"$iroh/../THIRD-PARTY-NOTICES.txt"'
        if notices == "missing":
            return []
        if notices == "symlink":
            return [f"ln -sf '{self.notices_source}' {target}"]
        mode = "0755" if notices == "executable" else "0644"
        return [f"cp '{self.notices_source}' {target}", f"chmod {mode} {target}"]

    # ── the Landlock shim stub (Linux targets) ────────────────────────────
    # Where the NIF build puts it in the unpacked payload. The stub answers
    # `--abi` the way the shim does; `dynamic` is an ELF header naming a
    # program interpreter, which the stage must refuse before running it. A
    # macOS tree carries no shim.
    def _landlock_shim_setup(self, behaviour, version):
        if not self._artifact_target().startswith("linux_") or behaviour == "missing":
            return ""

        answers = {
            "answers": "printf 'fermix_landlock: abi 6\\n'\nexit 0",
            "unavailable": "printf 'fermix_landlock: Landlock is unavailable on this kernel (Function not implemented)\\n' >&2\nexit 69",
            "wrong_answer": "printf 'Segmentation fault\\n' >&2\nexit 139",
            "silent_success": "exit 0",
        }
        source = self.base / "landlock-payload" / "fermix_landlock"
        source.parent.mkdir(exist_ok=True)
        if behaviour == "dynamic":
            source.write_bytes(self._elf_naming_an_interpreter())
        else:
            answer = answers.get(behaviour, answers["answers"])
            source.write_text(f'#!/bin/sh\n[ "$*" = "--abi" ] || exit 64\n{answer}\n', encoding="utf-8")

        app_versions = [version, "0.8.0"] if behaviour == "two" else [version]
        lines = []
        for app_version in app_versions:
            target = f'"$payload/lib/fermix_nif-{app_version}/priv/fermix_landlock"'
            lines.append(f'mkdir -p "$payload/lib/fermix_nif-{app_version}/priv"')
            if behaviour == "symlink":
                lines.append(f"ln -sf '{source}' {target}")
            else:
                lines.append(f"cp '{source}' {target}")
                lines.append(f"chmod {'-x' if behaviour == 'not_executable' else '+x'} {target}")
        return "\n".join(lines) + "\n"

    # A 64-bit little-endian ELF header and one program header of type
    # PT_INTERP (3): what a shim linked against a C library carries.
    @staticmethod
    def _elf_naming_an_interpreter():
        ident = b"\x7fELF" + bytes([2, 1, 1]) + bytes(9)
        header = ident + struct.pack("<HHIQQQIHHHHHH", 2, 62, 1, 0, 64, 0, 0, 64, 56, 1, 64, 0, 0)
        program_header = struct.pack("<IIQQQQQQ", 3, 4, 120, 0, 0, 28, 28, 1)
        return header + program_header + b"/lib/ld-linux-x86-64.so.2\0\0\0"


if __name__ == "__main__":
    unittest.main()
