#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for app-engine archive and runtime verification."""

import hashlib
import io
import json
import os
import re
import shutil
import signal
import socket
import stat
import struct
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import package_app_engine as package  # noqa: E402
import verify_app_engine as verify  # noqa: E402

TARGET = "macos_aarch64"
ARCHITECTURE = "arm64"
VERSION = "0.9.0"
SOURCE_COMMIT = "a" * 40
MAPS_HELPER = "lib/fermix_nif-0.9.0/priv/fermix-maps"
IROH_HELPER = "lib/fermix_core-0.9.0/priv/iroh_helper/bin/fermix-iroh"
IROH_VERSION_LINE = "fermix-iroh 0.1.0 (iroh 1.3.0)"
IROH_TEAM_ID = "ABCDE12345"


class VerifyAppEngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-app-engine-verify-")
        self.base = Path(self.tmp.name)
        self.release = self.base / "release"
        self.out = self.base / "out"
        self.pin = self.base / "PIN.json"
        self.codesign_bin = self.base / "codesign-bin"
        self.codesign_log = self.base / "codesign.log"
        self.release.mkdir()
        self._write_fake_release()
        self._write_manifest()
        self._write_pin()
        # The macOS signature checks must not depend on the host's signing
        # tools, and the Linux host these tests run on in CI has none.
        self._write_codesign("team")
        path = mock.patch.dict(os.environ, {"PATH": f"{self.codesign_bin}:{os.environ['PATH']}"})
        path.start()
        self.addCleanup(path.stop)
        self.archive = package.package_release(self.release, TARGET, self.out, VERSION)
        self.timeouts = verify.Timeouts(
            startup_attempts=150,
            shutdown_attempts=150,
            poll_interval_seconds=0.02,
            health_timeout_seconds=0.2,
            management_timeout_seconds=1.0,
            stop_timeout_seconds=2.0,
            cleanup_timeout_seconds=1.0,
        )

    def tearDown(self):
        self.tmp.cleanup()

    def test_runs_native_engine_and_verifies_identity_and_socket_cleanup(self):
        with self._darwin_host("arm64"), mock.patch.dict(
            os.environ,
            {
                "FERMIX_OPIK_ENABLED": "1",
                "OPENAI_API_KEY": "operator-secret-must-not-reach-smoke",
            },
        ):
            result = verify.verify_app_engine(
                self.archive,
                TARGET,
                VERSION,
                "native",
                iroh_pin=self.pin,
                temp_parent=self.base,
                timeouts=self.timeouts,
            )

        self.assertEqual(result["target"], TARGET)
        self.assertEqual(result["architecture"], ARCHITECTURE)
        self.assertEqual(result["version"], VERSION)
        self.assertEqual(result["mode"], "native")
        self.assertGreater(int(result["pid"]), 0)
        self.assertFalse(Path(result["fermix_home"]).exists())

    def test_reports_the_apple_maps_helper_it_checked(self):
        with self._darwin_host("arm64"):
            result = verify.verify_app_engine(
                self.archive,
                TARGET,
                VERSION,
                "native",
                iroh_pin=self.pin,
                temp_parent=self.base,
                timeouts=self.timeouts,
            )

        self.assertEqual(result["maps_helper"], MAPS_HELPER)

    def test_rejects_an_engine_without_the_apple_maps_helper_before_launching(self):
        (self.release / MAPS_HELPER).unlink()
        self._write_manifest(with_helper=False)
        archive = package.package_release(self.release, TARGET, self.base / "out-no-helper", VERSION)

        with self._darwin_host("arm64"), mock.patch.object(verify, "_start_engine") as start:
            with self.assertRaisesRegex(verify.VerificationError, "exactly one Apple Maps helper"):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=self.timeouts,
                )

        start.assert_not_called()

    def test_rejects_a_helper_whose_self_check_fails(self):
        self._write_helper("#!/bin/sh\necho 'dyld: missing MapKit' >&2\nexit 70\n")
        self._write_manifest()
        archive = package.package_release(self.release, TARGET, self.base / "out-broken", VERSION)

        with self._darwin_host("arm64"), mock.patch.object(verify, "_start_engine") as start:
            with self.assertRaisesRegex(
                verify.VerificationError, r"self-check failed \(exit 70\): dyld: missing MapKit"
            ):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=self.timeouts,
                )

        start.assert_not_called()

    # ── the bundled fermix-iroh helper ────────────────────────────────────

    def test_reports_the_pinned_signed_iroh_helper_it_checked(self):
        with self._darwin_host("arm64"):
            result = verify.verify_app_engine(
                self.archive,
                TARGET,
                VERSION,
                "native",
                iroh_pin=self.pin,
                temp_parent=self.base,
                timeouts=self.timeouts,
            )

        self.assertEqual(result["iroh_helper"], IROH_HELPER)
        calls = self.codesign_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual([call.split(" /", 1)[0] for call in calls], ["--verify --strict", "-dv"])

    def test_rejects_an_engine_without_the_iroh_helper_before_launching(self):
        (self.release / IROH_HELPER).unlink()
        archive = self._repackage("no-iroh")

        self._verify_before_launch(archive, r"exactly one fermix-iroh helper .* found 0")

    def test_rejects_an_engine_with_two_iroh_helpers_before_launching(self):
        self._write_iroh_helper(
            IROH_VERSION_LINE, relative="lib/fermix_core-0.8.0/priv/iroh_helper/bin/fermix-iroh"
        )
        archive = self._repackage("two-iroh")

        self._verify_before_launch(archive, r"exactly one fermix-iroh helper .* found 2")

    # A helper that lost its executable bit is not inventoried by the release
    # manifest, so the packager's own checks pass it; this check does not.
    def test_rejects_an_iroh_helper_the_manifest_does_not_inventory(self):
        self._write_iroh_helper(IROH_VERSION_LINE, mode=0o644)
        archive = self._repackage("unlisted-iroh")

        self._verify_before_launch(archive, f"the engine manifest does not inventory {IROH_HELPER}")

    # The real build is a Mach-O, which the release manifest inventories
    # whatever its mode, so a helper that lost its executable bit can arrive
    # listed and pinned; it is refused by name before anything tries to run it.
    def test_rejects_a_listed_pinned_iroh_helper_that_is_not_executable(self):
        self._write_mach_o_iroh_helper(mode=0o644)
        self._write_pin()
        archive = self._repackage("not-executable-iroh")

        self._verify_before_launch(archive, f"the fermix-iroh helper {IROH_HELPER} is not executable")
        self.assertFalse(self.codesign_log.exists())

    def test_rejects_an_iroh_helper_whose_digest_is_not_the_pinned_one(self):
        self._write_pin(sha256="f" * 64)
        actual = self._sha256(self.release / IROH_HELPER)

        self._verify_before_launch(
            self.archive,
            f"{IROH_HELPER} is not the pinned fermix-iroh build for {TARGET}: "
            f"expected sha256 {'f' * 64}, found {actual}",
        )
        self.assertFalse(self.codesign_log.exists())

    def test_rejects_an_iroh_helper_whose_version_is_not_the_pinned_one(self):
        self._write_iroh_helper("fermix-iroh 0.1.0 (iroh 1.2.0)")
        self._write_pin()
        archive = self._repackage("old-iroh")

        self._verify_before_launch(
            archive,
            rf"--version must print exactly '{re.escape(IROH_VERSION_LINE)}', "
            r"got \(exit 0\): fermix-iroh 0\.1\.0 \(iroh 1\.2\.0\)",
        )

    def test_rejects_an_iroh_helper_that_fails_strict_signature_verification(self):
        self._write_codesign("unsigned")

        self._verify_before_launch(
            self.archive, r"does not pass codesign --verify --strict \(exit 1\): .*not signed at all"
        )

    def test_rejects_an_iroh_helper_signed_by_another_team(self):
        self._write_codesign("other_team")

        self._verify_before_launch(
            self.archive, f"must be signed by team {IROH_TEAM_ID}, found ZYXWV98765"
        )

    def test_rejects_a_pin_without_this_target_before_extracting(self):
        self._write_pin(targets={"macos_x86_64": {"asset": "fermix-iroh-macos-x86_64", "sha256": "e" * 64}})

        with self._darwin_host("arm64"), mock.patch.object(verify, "extract_archive") as extract:
            with self.assertRaisesRegex(verify.VerificationError, f"has no sha256 for {TARGET}"):
                verify.verify_app_engine(
                    self.archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=self.timeouts,
                )

        extract.assert_not_called()

    def test_rejects_a_missing_pin(self):
        with self._darwin_host("arm64"):
            with self.assertRaisesRegex(verify.VerificationError, "cannot read the fermix-iroh pin"):
                verify.verify_app_engine(
                    self.archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.base / "absent.json",
                    temp_parent=self.base,
                    timeouts=self.timeouts,
                )

    # Rosetta verification runs the x86_64 helper through `arch -x86_64`, so the
    # helper's --version goes through the same command prefix as the engine.
    def test_runs_the_iroh_helper_version_through_the_command_prefix(self):
        release_root = verify.extract_archive(self.archive, self.base / "prefix-extract")
        manifest = verify._validated_manifest(release_root, TARGET, VERSION, None)
        pinned = verify._iroh_pin(self.pin, TARGET)
        prefix = [shutil.which("env")]

        with mock.patch.object(verify.subprocess, "run", wraps=verify.subprocess.run) as run:
            verify._verify_iroh_helper(release_root, manifest, prefix, pinned, self.timeouts)

        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn([*prefix, str(release_root / IROH_HELPER), "--version"], commands)

    def test_cli_defaults_the_iroh_pin_to_this_checkout(self):
        arguments = verify._arguments(["a.tar.gz", TARGET, VERSION, SOURCE_COMMIT, "native"])

        self.assertEqual(
            Path(arguments.iroh_pin),
            Path(__file__).resolve().parents[2] / "apps/fermix_core/priv/iroh_helper/PIN.json",
        )

    def test_archive_validation_does_not_eagerly_load_every_member(self):
        with mock.patch.object(
            tarfile.TarFile,
            "getmembers",
            side_effect=AssertionError("eager archive load"),
        ):
            extracted = verify.extract_archive(self.archive, self.base / "bounded-extract")

        self.assertTrue((extracted / "engine-manifest.json").is_file())

    def test_runtime_environment_drops_unrelated_operator_values(self):
        runtime = self.base / "runtime-environment"
        scratch = self.base / "runtime-scratch"
        runtime.mkdir()
        scratch.mkdir()

        with mock.patch.dict(
            os.environ,
            {
                "ANTHROPIC_API_KEY": "operator-anthropic-secret",
                "TELEGRAM_BOT_TOKEN": "operator-telegram-secret",
                "FERMIX_OPIK_ENABLED": "1",
                "OPENAI_API_KEY": "operator-openai-secret",
            },
        ):
            _home, environment = verify._runtime_environment(runtime, scratch)

        self.assertNotIn("ANTHROPIC_API_KEY", environment)
        self.assertNotIn("TELEGRAM_BOT_TOKEN", environment)
        self.assertNotIn("FERMIX_OPIK_ENABLED", environment)
        self.assertEqual(environment["OPENAI_API_KEY"], verify.SMOKE_OPENAI_API_KEY)
        self.assertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertTrue(environment["USER"])

    def test_rejects_archive_path_traversal_before_writing_outside_staging(self):
        archive = self._write_raw_archive(
            [
                self._directory("fermix_app_engine"),
                self._file("../escaped", b"not safe"),
            ]
        )
        escaped = self.base / "escaped"

        with self.assertRaisesRegex(verify.VerificationError, "relative path"):
            verify.extract_archive(archive, self.base / "extract")

        self.assertFalse(escaped.exists())

    def test_rejects_absolute_symlink_target_before_extraction(self):
        archive = self._write_raw_archive(
            [
                self._directory("fermix_app_engine"),
                self._symlink("fermix_app_engine/escape", "/tmp/outside"),
            ]
        )

        with self.assertRaisesRegex(verify.VerificationError, "absolute symlink"):
            verify.extract_archive(archive, self.base / "extract")

    def test_rejects_archive_entry_nested_below_a_symlink(self):
        archive = self._write_raw_archive(
            [
                self._directory("fermix_app_engine"),
                self._symlink("fermix_app_engine/link", "real"),
                self._file("fermix_app_engine/link/payload", b"unsafe"),
            ]
        )

        with self.assertRaisesRegex(verify.VerificationError, "below symlink"):
            verify.extract_archive(archive, self.base / "extract")

    def test_rejects_hard_links(self):
        hard_link = tarfile.TarInfo("fermix_app_engine/hard-link")
        hard_link.type = tarfile.LNKTYPE
        hard_link.linkname = "fermix_app_engine/engine-manifest.json"
        archive = self._write_raw_archive(
            [self._directory("fermix_app_engine"), (hard_link, None)]
        )

        with self.assertRaisesRegex(verify.VerificationError, "unsupported archive entry"):
            verify.extract_archive(archive, self.base / "extract")

    def test_rejects_version_mismatch_before_launching_the_engine(self):
        with self._darwin_host("arm64"), mock.patch.object(
            verify.subprocess, "Popen"
        ) as popen:
            with self.assertRaisesRegex(verify.VerificationError, "product_version"):
                verify.verify_app_engine(
                    self.archive,
                    TARGET,
                    "0.9.1",
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=self.timeouts,
                )

        popen.assert_not_called()

    def test_rejects_source_commit_mismatch_before_launching_the_engine(self):
        with self._darwin_host("arm64"), mock.patch.object(
            verify.subprocess, "Popen"
        ) as popen:
            with self.assertRaisesRegex(verify.VerificationError, "source_commit"):
                verify.verify_app_engine(
                    self.archive,
                    TARGET,
                    VERSION,
                    "native",
                    expected_source_commit="b" * 40,
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=self.timeouts,
                )

        popen.assert_not_called()

    def test_port_collision_fails_without_selecting_an_alternate_port(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            port = occupied.getsockname()[1]

            with self._darwin_host("arm64"), mock.patch.object(
                verify, "_available_port", return_value=port
            ) as select_port:
                with self.assertRaisesRegex(
                    verify.VerificationError, "exited during startup"
                ):
                    verify.verify_app_engine(
                        self.archive,
                        TARGET,
                        VERSION,
                        "native",
                        iroh_pin=self.pin,
                        temp_parent=self.base,
                        timeouts=self.timeouts,
                    )

        select_port.assert_called_once_with()

    def test_treats_a_non_object_health_payload_as_not_live(self):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b"[]"

        with mock.patch.object(verify.urllib.request, "urlopen", return_value=response):
            self.assertFalse(
                verify._health_live(
                    {"PORT": "4030"},
                    {"identity": {"product_version": VERSION}},
                    self.timeouts,
                )
            )

    def test_rejects_rosetta_for_a_non_x86_engine(self):
        with self._darwin_host("arm64"):
            with self.assertRaisesRegex(verify.VerificationError, "Rosetta"):
                verify.verify_app_engine(
                    self.archive,
                    TARGET,
                    VERSION,
                    "rosetta",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=self.timeouts,
                )

    def test_fails_when_shutdown_leaves_a_socket_path(self):
        archive = self._archive_with_control("stale-socket")

        with self._darwin_host("arm64"):
            with self.assertRaisesRegex(verify.VerificationError, "daemon.sock remained"):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=self.timeouts,
                )

    # The app engine serves the native host socket (M76), and its listener
    # removes the file when the engine stops, as every other socket's does.
    def test_fails_when_shutdown_leaves_the_native_host_socket(self):
        archive = self._archive_with_control("stale-native_host")

        with self._darwin_host("arm64"):
            with self.assertRaisesRegex(verify.VerificationError, "native_host.sock remained"):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=self.timeouts,
                )

    def test_startup_timeout_reports_health_when_only_realtime_socket_is_missing(self):
        short = verify.Timeouts(
            startup_attempts=50,
            shutdown_attempts=3,
            poll_interval_seconds=0.02,
            health_timeout_seconds=0.02,
            management_timeout_seconds=0.1,
            stop_timeout_seconds=0.1,
            cleanup_timeout_seconds=1.0,
        )

        archive = self._archive_with_control("no-realtime")

        with self._darwin_host("arm64"), self._start_after_fixture_ready():
            with self.assertRaisesRegex(
                verify.VerificationError,
                r"daemon_socket=true.*realtime_socket=false.*companion_socket=true.*health=true",
            ):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=short,
                )

    def test_startup_timeout_reports_when_only_the_companion_socket_is_missing(self):
        short = verify.Timeouts(
            startup_attempts=50,
            shutdown_attempts=3,
            poll_interval_seconds=0.02,
            health_timeout_seconds=0.02,
            management_timeout_seconds=0.1,
            stop_timeout_seconds=0.1,
            cleanup_timeout_seconds=1.0,
        )

        archive = self._archive_with_control("no-companion")

        with self._darwin_host("arm64"), self._start_after_fixture_ready():
            with self.assertRaisesRegex(
                verify.VerificationError,
                r"daemon_socket=true.*realtime_socket=true.*companion_socket=false.*health=true",
            ):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=short,
                )

    def test_startup_timeout_reports_when_only_the_browser_host_socket_is_missing(self):
        short = verify.Timeouts(
            startup_attempts=50,
            shutdown_attempts=3,
            poll_interval_seconds=0.02,
            health_timeout_seconds=0.02,
            management_timeout_seconds=0.1,
            stop_timeout_seconds=0.1,
            cleanup_timeout_seconds=1.0,
        )

        archive = self._archive_with_control("no-browser_host")

        with self._darwin_host("arm64"), self._start_after_fixture_ready():
            with self.assertRaisesRegex(
                verify.VerificationError,
                r"daemon_socket=true.*realtime_socket=true.*companion_socket=true.*"
                r"browser_host_socket=false.*health=true",
            ):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=short,
                )

    # A packaged app engine whose native host socket cannot bind boots on
    # without it (the listener logs and ignores), so nothing would ring on the
    # Mac: the smoke run is where that is caught.
    def test_startup_timeout_reports_when_only_the_native_host_socket_is_missing(self):
        short = verify.Timeouts(
            startup_attempts=50,
            shutdown_attempts=3,
            poll_interval_seconds=0.02,
            health_timeout_seconds=0.02,
            management_timeout_seconds=0.1,
            stop_timeout_seconds=0.1,
            cleanup_timeout_seconds=1.0,
        )

        archive = self._archive_with_control("no-native_host")

        with self._darwin_host("arm64"), self._start_after_fixture_ready():
            with self.assertRaisesRegex(
                verify.VerificationError,
                r"daemon_socket=true.*realtime_socket=true.*companion_socket=true.*"
                r"browser_host_socket=true.*native_host_socket=false.*health=true",
            ):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=short,
                )

    def test_startup_timeout_reports_each_missing_runtime_surface(self):
        short = verify.Timeouts(
            startup_attempts=50,
            shutdown_attempts=3,
            poll_interval_seconds=0.02,
            health_timeout_seconds=0.02,
            management_timeout_seconds=0.1,
            stop_timeout_seconds=0.1,
            cleanup_timeout_seconds=1.0,
        )

        archive = self._archive_with_control("no-ready")

        with self._darwin_host("arm64"):
            with self.assertRaisesRegex(
                verify.VerificationError,
                r"daemon_socket=false.*realtime_socket=false.*companion_socket=false.*"
                r"browser_host_socket=false.*native_host_socket=false.*health=false",
            ):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=short,
                )

    def test_unexpected_verifier_failure_still_terminates_the_engine(self):
        processes = []
        popen = verify.subprocess.Popen
        force_cleanup = verify._force_cleanup

        # The engine's process only: the helper's self-check runs before it.
        def capture_process(*args, **kwargs):
            process = popen(*args, **kwargs)
            if any(str(part).endswith("bin/fermix_app_engine") for part in args[0]):
                processes.append(process)
            return process

        with self._darwin_host("arm64"), mock.patch.object(
            verify.subprocess, "Popen", side_effect=capture_process
        ), mock.patch.object(
            verify, "_await_ready", side_effect=RuntimeError("unexpected verifier failure")
        ), mock.patch.object(
            verify, "_force_cleanup", wraps=force_cleanup
        ) as cleanup:
            try:
                with self.assertRaisesRegex(RuntimeError, "unexpected verifier failure"):
                    verify.verify_app_engine(
                        self.archive,
                        TARGET,
                        VERSION,
                        "native",
                        iroh_pin=self.pin,
                        temp_parent=self.base,
                        timeouts=self.timeouts,
                    )
                automatic_cleanup_count = cleanup.call_count
            finally:
                for process in processes:
                    if process.poll() is None:
                        force_cleanup(process, self.timeouts)

        self.assertEqual(automatic_cleanup_count, 1)
        self.assertEqual(len(processes), 1)
        self.assertIsNotNone(processes[0].poll())

    def _start_after_fixture_ready(self):
        start_engine = verify._start_engine

        def start(command, release_root, environment, log_path):
            process = start_engine(command, release_root, environment, log_path)
            pid_path = Path(environment["FERMIX_HOME"]) / "fake-engine.pid"

            for _attempt in range(500):
                if pid_path.is_file():
                    return process
                if process.poll() is not None:
                    break
                verify.time.sleep(0.02)

            cleanup_error = verify._force_cleanup(process, self.timeouts)
            self.fail(f"fake engine did not reach partial readiness: {cleanup_error}")

        return mock.patch.object(verify, "_start_engine", side_effect=start)

    def _archive_with_control(self, name):
        controls = self.release / "test-controls"
        controls.mkdir(exist_ok=True)
        (controls / name).write_text("enabled\n", encoding="utf-8")
        self._write_manifest()
        return package.package_release(
            self.release,
            TARGET,
            self.base / f"out-{name}",
            VERSION,
        )

    def _write_fake_release(self):
        fixture = Path(__file__).with_name("fixtures") / "fake_app_engine.py"
        script = self.release / "bin/fermix_app_engine"
        script.parent.mkdir(parents=True)
        shutil.copyfile(fixture, script)
        script.chmod(0o755)
        self._write_helper("#!/bin/sh\necho 'fermix-maps: ok'\n")
        self._write_iroh_helper(IROH_VERSION_LINE)

    # A script standing in for the Mach-O helper the native build makes.
    def _write_helper(self, contents):
        helper = self.release / MAPS_HELPER
        helper.parent.mkdir(parents=True, exist_ok=True)
        helper.write_text(contents, encoding="utf-8")
        helper.chmod(0o755)

    # A script standing in for the pinned, team-signed fermix-iroh build.
    def _write_iroh_helper(self, version_line, mode=0o755, relative=IROH_HELPER):
        helper = self.release / relative
        helper.parent.mkdir(parents=True, exist_ok=True)
        helper.write_text(
            f"#!/bin/sh\n[ \"$*\" = \"--version\" ] || exit 64\necho '{version_line}'\n",
            encoding="utf-8",
        )
        helper.chmod(mode)

    # The real build's shape: a thin arm64 Mach-O header, which the manifest
    # inventories as `mach_o` whatever the file's mode.
    def _write_mach_o_iroh_helper(self, mode):
        helper = self.release / IROH_HELPER
        header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)
        helper.write_bytes(header + b"thin fermix-iroh stand-in")
        helper.chmod(mode)

    # The pin as `pin_iroh_helper.py` writes it, with this tree's helper as the
    # target's build unless a test names another digest.
    def _write_pin(self, sha256=None, targets=None):
        digest = sha256 or self._sha256(self.release / IROH_HELPER)
        pin = {
            "schema_version": 1,
            "repository": "tezra-io/fermix-iroh",
            "tag": "v0.1.0",
            "version": "0.1.0",
            "protocol_version": 1,
            "iroh_version": "1.3.0",
            "certificate_identity": (
                "https://github.com/tezra-io/fermix-iroh/.github/workflows/release.yml@refs/tags/v0.1.0"
            ),
            "certificate_oidc_issuer": "https://token.actions.githubusercontent.com",
            "macos_team_id": IROH_TEAM_ID,
            "targets": targets
            or {
                "macos_aarch64": {"asset": "fermix-iroh-macos-aarch64", "sha256": digest},
                "macos_x86_64": {"asset": "fermix-iroh-macos-x86_64", "sha256": "e" * 64},
                "linux_aarch64": {"asset": "fermix-iroh-linux-aarch64", "sha256": "c" * 64},
                "linux_x86_64": {"asset": "fermix-iroh-linux-x86_64", "sha256": "d" * 64},
            },
        }
        self.pin.write_text(json.dumps(pin, indent=2) + "\n", encoding="utf-8")

    # A stand-in for the two codesign calls the check makes, on the helper and
    # nothing else: any other argv exits 64. Every call is recorded.
    def _write_codesign(self, behaviour):
        verify = {
            "team": "  exit 0\n",
            "other_team": "  exit 0\n",
            "unsigned": "  printf '%s: code object is not signed at all\\n' \"$3\" >&2\n  exit 1\n",
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

    def _repackage(self, name):
        self._write_manifest()
        return package.package_release(self.release, TARGET, self.base / f"out-{name}", VERSION)

    def _verify_before_launch(self, archive, pattern):
        with self._darwin_host("arm64"), mock.patch.object(verify, "_start_engine") as start:
            with self.assertRaisesRegex(verify.VerificationError, pattern):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
                    iroh_pin=self.pin,
                    temp_parent=self.base,
                    timeouts=self.timeouts,
                )
        start.assert_not_called()

    def _script_entry(self, relative):
        path = self.release / relative
        return {
            "path": relative,
            "kind": "script",
            "mode": f"{path.stat().st_mode & 0o777:04o}",
            "interpreter": "/bin/sh",
            "sha256": self._sha256(path),
        }

    def _mach_o_entry(self, relative):
        path = self.release / relative
        return {
            "path": relative,
            "kind": "mach_o",
            "mode": f"{path.stat().st_mode & 0o777:04o}",
            "architectures": [ARCHITECTURE],
            "sha256": self._sha256(path),
        }

    def _write_manifest(self, with_helper=True):
        script = self.release / "bin/fermix_app_engine"
        helper_entries = []
        if with_helper:
            helper_entries.append(self._script_entry(MAPS_HELPER))
        # Every executable helper under fermix_core's priv, and a Mach-O one
        # whatever its mode, as the release manifest inventories them; a
        # non-executable script is not inventoried.
        for iroh in sorted(self.release.glob(verify.IROH_HELPER_GLOB)):
            relative = iroh.relative_to(self.release).as_posix()
            if package._is_mach_o(iroh):
                helper_entries.append(self._mach_o_entry(relative))
            elif iroh.stat().st_mode & 0o111:
                helper_entries.append(self._script_entry(relative))
        helper_entries.sort(key=lambda entry: entry["path"])
        manifest = {
            "schema_version": 1,
            "identity": {
                "engine_id": "fermix-core",
                "product_version": VERSION,
                "build_id": "release-test",
                "source_commit": SOURCE_COMMIT,
                "distribution_identity": "macos_app",
                "artifact_target": TARGET,
                "architecture": ARCHITECTURE,
            },
            "protocols": {
                "management": {
                    "current_version": 1,
                    "minimum_version": 1,
                    "maximum_version": 1,
                },
                "realtime": {
                    "current_version": 1,
                    "minimum_version": 1,
                    "maximum_version": 1,
                },
                "companion": {
                    "current_version": 1,
                    "minimum_version": 1,
                    "maximum_version": 1,
                },
                "browser_host": {
                    "current_version": 1,
                    "minimum_version": 1,
                    "maximum_version": 1,
                },
                "native_host": {
                    "current_version": 1,
                    "minimum_version": 1,
                    "maximum_version": 1,
                },
            },
            "provenance": {
                "oidc_issuer": "https://token.actions.githubusercontent.com",
                "certificate_identity": (
                    "https://github.com/tezra-io/fermix/.github/workflows/"
                    f"release.yml@refs/tags/v{VERSION}"
                ),
            },
            "tree_sha256": package.compute_tree_digest(self.release),
            "inventory": {
                "artifact_target": TARGET,
                "architecture": ARCHITECTURE,
                "entries": [
                    {
                        "path": "bin/fermix_app_engine",
                        "kind": "script",
                        "mode": "0755",
                        "interpreter": "/usr/bin/env",
                        "sha256": self._sha256(script),
                    },
                    *helper_entries,
                ],
            },
        }
        path = self.release / "engine-manifest.json"
        path.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
        path.chmod(0o644)

    def _write_raw_archive(self, members):
        archive = self.base / "fermix_app_engine_macos_aarch64.tar.gz"
        if archive.exists():
            archive.unlink()
        with tarfile.open(archive, "w:gz") as stream:
            for member, contents in members:
                stream.addfile(member, io.BytesIO(contents) if contents is not None else None)
        return archive

    @staticmethod
    def _directory(name):
        member = tarfile.TarInfo(name)
        member.type = tarfile.DIRTYPE
        member.mode = 0o755
        return member, None

    @staticmethod
    def _file(name, contents):
        member = tarfile.TarInfo(name)
        member.type = tarfile.REGTYPE
        member.mode = 0o644
        member.size = len(contents)
        return member, contents

    @staticmethod
    def _symlink(name, target):
        member = tarfile.TarInfo(name)
        member.type = tarfile.SYMTYPE
        member.mode = 0o777
        member.linkname = target
        return member, None

    @staticmethod
    def _sha256(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def _darwin_host(machine):
        return mock.patch.multiple(
            verify.platform,
            system=mock.Mock(return_value="Darwin"),
            machine=mock.Mock(return_value=machine),
        )


class RuntimeIdentityTest(unittest.TestCase):
    """The hello the verifier accepts is the one protocol v2 publishes.

    The check had no test, which is how it went on demanding a v1 hello
    (capabilities carrying only the method catalog) after v2 added the
    per-method minimum versions beside it, and refused the first release
    built after that change.
    """

    MANIFEST = {
        "protocols": {"management": {"minimum": 1, "maximum": 2}},
        "identity": {"engine_id": "fermix-core", "build_id": "b1"},
    }
    ENVIRONMENT = {"PORT": "4030"}

    def _hello(self, capabilities):
        return {
            "protocol": {"minimum": 1, "maximum": 2},
            "capabilities": capabilities,
            "engine": {"engine_id": "fermix-core", "build_id": "b1", "pid": "42"},
            "setup": {"origin": "http://127.0.0.1:4030", "path": "/setup"},
        }

    def _validate(self, capabilities):
        return verify._validate_runtime_identity(self._hello(capabilities), self.MANIFEST, 42, self.ENVIRONMENT)

    def test_accepts_the_v2_hello_with_minimum_versions(self):
        engine = self._validate({"methods": ["hello", "setup.detect"], "minimum_versions": {"hello": 1, "setup.detect": 2}})
        self.assertEqual(engine["pid"], "42")

    def test_refuses_a_hello_without_minimum_versions(self):
        with self.assertRaisesRegex(verify.VerificationError, "invalid capabilities"):
            self._validate({"methods": ["hello"]})

    def test_refuses_a_minimum_for_a_method_the_catalog_does_not_carry(self):
        with self.assertRaisesRegex(verify.VerificationError, "unknown method"):
            self._validate({"methods": ["hello"], "minimum_versions": {"hello": 1, "settings.get": 2}})

    def test_refuses_a_minimum_below_the_window(self):
        with self.assertRaisesRegex(verify.VerificationError, "invalid minimum version"):
            self._validate({"methods": ["hello"], "minimum_versions": {"hello": 0}})


if __name__ == "__main__":
    unittest.main()
