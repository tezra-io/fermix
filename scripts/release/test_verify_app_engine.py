#!/usr/bin/env python3
"""Hermetic tests for app-engine archive and runtime verification."""

import hashlib
import io
import json
import os
import shutil
import signal
import socket
import stat
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


class VerifyAppEngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-app-engine-verify-")
        self.base = Path(self.tmp.name)
        self.release = self.base / "release"
        self.out = self.base / "out"
        self.release.mkdir()
        self._write_fake_release()
        self._write_manifest()
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
                temp_parent=self.base,
                timeouts=self.timeouts,
            )

        self.assertEqual(result["target"], TARGET)
        self.assertEqual(result["architecture"], ARCHITECTURE)
        self.assertEqual(result["version"], VERSION)
        self.assertEqual(result["mode"], "native")
        self.assertGreater(int(result["pid"]), 0)
        self.assertFalse(Path(result["fermix_home"]).exists())

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
                r"daemon_socket=true.*realtime_socket=false.*health=true",
            ):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
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
                r"daemon_socket=false.*realtime_socket=false.*health=false",
            ):
                verify.verify_app_engine(
                    archive,
                    TARGET,
                    VERSION,
                    "native",
                    temp_parent=self.base,
                    timeouts=short,
                )

    def test_unexpected_verifier_failure_still_terminates_the_engine(self):
        processes = []
        popen = verify.subprocess.Popen
        force_cleanup = verify._force_cleanup

        def capture_process(*args, **kwargs):
            process = popen(*args, **kwargs)
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

    def _write_manifest(self):
        script = self.release / "bin/fermix_app_engine"
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
                    }
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


if __name__ == "__main__":
    unittest.main()
