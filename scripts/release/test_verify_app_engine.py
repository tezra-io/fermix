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
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parent / "fixtures"))
import linux_engine  # noqa: E402
import package_app_engine as package  # noqa: E402
import verify_app_engine as verify  # noqa: E402

TARGET = "macos_aarch64"
ARCHITECTURE = "arm64"
VERSION = "0.9.0"
SOURCE_COMMIT = "a" * 40
LINUX_TARGET = "linux_x86_64"
LINUX_ARCHITECTURE = "x86_64"
UNIT_SOURCE = Path(__file__).resolve().parents[2] / "packaging/linux/systemd/fermix.service"


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


class LinuxVerifyTest(unittest.TestCase):
    """The Linux archive, whose engine runs installed rather than in place."""

    SMOKE_OUTPUT = (
        f"fermix {VERSION}\n"
        '{"ok":false,"schema_version":1,"error":{"code":"user_manager_unreachable",'
        '"sentence":"This session has no user service manager."}}\n'
    )

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-linux-engine-verify-")
        self.base = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.release = self.base / "release"
        self.loader_payload, self.loader_name = linux_engine.loader_bytes(LINUX_ARCHITECTURE)
        self.interpreter = linux_engine.trusted_interpreter(self.loader_name)
        self._write_release_tree()
        self.archive = package.package_release(
            self.release, LINUX_TARGET, self.base / "out", VERSION, SOURCE_COMMIT
        )
        self.timeouts = verify.Timeouts(container_timeout_seconds=5.0)

    def test_validates_the_archive_and_runs_the_engine_it_installs(self):
        runner = self._docker(0, self.SMOKE_OUTPUT)
        result = verify.verify_app_engine(
            self.archive,
            LINUX_TARGET,
            VERSION,
            "container",
            expected_source_commit=SOURCE_COMMIT,
            temp_parent=self.base,
            timeouts=self.timeouts,
        )

        self.assertEqual(result["target"], LINUX_TARGET)
        self.assertEqual(result["architecture"], LINUX_ARCHITECTURE)
        self.assertEqual(result["mode"], "container")

        command = runner.call_args.args[0]
        self.assertIn("--platform", command)
        self.assertEqual(command[command.index("--platform") + 1], "linux/amd64")
        self.assertIn(verify.LINUX_SMOKE_IMAGE, command)
        # The archive's own extracted tree is what the container installs, and
        # nothing else is bound: the home the wrapper unpacks into stays in the
        # write layer, so the container's root leaves no file this account
        # cannot remove.
        mounts = [command[index + 1] for index, item in enumerate(command) if item == "-v"]
        self.assertEqual(len(mounts), 1)
        self.assertTrue(mounts[0].endswith(":/archive:ro"))
        self.assertIn("/archive/maintainer/postinstall.sh", command[-1])

    def test_refuses_a_mode_that_belongs_to_the_other_family(self):
        with self.assertRaisesRegex(verify.VerificationError, "must be container"):
            verify.verify_app_engine(
                self.archive, LINUX_TARGET, VERSION, "native", temp_parent=self.base
            )

    def test_refuses_a_container_mode_for_a_macos_target(self):
        with self.assertRaisesRegex(verify.VerificationError, "must be native or rosetta"):
            verify._validate_mode(TARGET, "container")

    def test_refuses_an_engine_that_reports_another_version(self):
        output = self.SMOKE_OUTPUT.replace(VERSION, "0.0.1")

        self._docker(0, output)

        with self.assertRaisesRegex(verify.VerificationError, f"report version {VERSION}"):
            self._verify()

    def test_refuses_a_service_status_that_did_not_refuse(self):
        output = f"fermix {VERSION}\n" '{"ok":true,"result":{"active":true}}\n'

        self._docker(0, output)

        with self.assertRaisesRegex(verify.VerificationError, "must refuse"):
            self._verify()

    def test_refuses_a_refusal_that_is_not_the_container_one(self):
        output = f"fermix {VERSION}\n" '{"ok":false,"error":{"code":"something_else"}}\n'

        self._docker(0, output)

        with self.assertRaisesRegex(verify.VerificationError, "user_manager_unreachable"):
            self._verify()

    def test_reports_the_container_failure_rather_than_swallowing_it(self):
        self._docker(2, "", stderr="fermix: the runtime payload directory is missing")

        with self.assertRaisesRegex(verify.VerificationError, "runtime payload directory"):
            self._verify()

    def test_refuses_a_manifest_mismatch_before_the_container_runs(self):
        runner = self._docker(0, self.SMOKE_OUTPUT)

        with self.assertRaisesRegex(verify.VerificationError, "source_commit"):
            verify.verify_app_engine(
                self.archive,
                LINUX_TARGET,
                VERSION,
                "container",
                expected_source_commit="b" * 40,
                temp_parent=self.base,
                timeouts=self.timeouts,
            )

        runner.assert_not_called()

    def _verify(self):
        return verify.verify_app_engine(
            self.archive,
            LINUX_TARGET,
            VERSION,
            "container",
            temp_parent=self.base,
            timeouts=self.timeouts,
        )

    def _docker(self, returncode, stdout, stderr=""):
        completed = subprocess.CompletedProcess(["docker"], returncode, stdout, stderr)
        patch = mock.patch.object(verify.subprocess, "run", return_value=completed)
        runner = patch.start()
        self.addCleanup(patch.stop)
        which = mock.patch.object(verify.shutil, "which", return_value="/usr/bin/docker")
        which.start()
        self.addCleanup(which.stop)
        return runner

    def _write_release_tree(self):
        files = {
            "tree/usr/bin/fermix": (
                linux_engine.elf_bytes(LINUX_ARCHITECTURE, interpreter=self.interpreter),
                0o755,
            ),
            "tree/usr/lib/fermix/cosign": (
                linux_engine.elf_bytes(LINUX_ARCHITECTURE, padding=b"cosign\n"),
                0o755,
            ),
            f"tree/usr/lib/fermix/runtime-payload/{self.loader_name}": (
                self.loader_payload,
                0o644,
            ),
            "tree/usr/lib/systemd/user/fermix.service": (UNIT_SOURCE.read_bytes(), 0o644),
            "maintainer/postinstall.sh": (b"#!/bin/sh\nexit 0\n", 0o755),
            "maintainer/postremove.sh": (b"#!/bin/sh\nexit 0\n", 0o755),
            "nfpm-contents.yaml": (b"contents:\n", 0o644),
        }
        for relative, (payload, mode) in files.items():
            path = self.release / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            path.chmod(mode)

        manifest = package.build_manifest(
            self.release,
            LINUX_TARGET,
            product_version=VERSION,
            build_id="release-test",
            source_commit=SOURCE_COMMIT,
            protocols={
                "management": {"current_version": 1, "minimum_version": 1, "maximum_version": 1},
                "realtime": {"current_version": 1, "minimum_version": 1, "maximum_version": 1},
            },
        )
        path = self.release / "engine-manifest.json"
        path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        path.chmod(0o644)


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
