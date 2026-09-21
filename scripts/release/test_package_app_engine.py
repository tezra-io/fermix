#!/usr/bin/env python3
"""Hermetic tests for app-engine release packaging."""

import hashlib
import json
import os
import stat
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


TARGET = "macos_aarch64"
ARCHITECTURE = "arm64"
VERSION = "0.9.0"
LINUX_TARGET = "linux_x86_64"
LINUX_ARCHITECTURE = "x86_64"
PROTOCOLS = {
    "management": {"current_version": 2, "minimum_version": 1, "maximum_version": 2},
    "realtime": {"current_version": 1, "minimum_version": 1, "maximum_version": 1},
}
UNIT_SOURCE = Path(__file__).resolve().parents[2] / "packaging/linux/systemd/fermix.service"


class PackageAppEngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-app-engine-package-")
        self.base = Path(self.tmp.name)
        self.release = self.base / "release"
        self.out = self.base / "out"
        self._write_release_tree()
        self._write_manifest()

    def tearDown(self):
        self.tmp.cleanup()

    def test_packages_one_deterministic_root_with_modes_and_symlinks(self):
        archive = package.package_release(self.release, TARGET, self.out)

        self.assertEqual(archive.name, "fermix_app_engine_macos_aarch64.tar.gz")
        self.assertEqual(stat.S_IMODE(archive.stat().st_mode), 0o644)

        with tarfile.open(archive, "r:gz") as tar:
            members = {member.name: member for member in tar.getmembers()}

        self.assertEqual(
            set(members),
            {
                "fermix_app_engine",
                "fermix_app_engine/bin",
                "fermix_app_engine/bin/fermix_app_engine",
                "fermix_app_engine/empty",
                "fermix_app_engine/engine-manifest.json",
                "fermix_app_engine/lib",
                "fermix_app_engine/lib/runtime.dat",
                "fermix_app_engine/runtime-link",
            },
        )
        self.assertEqual(members["fermix_app_engine/bin/fermix_app_engine"].mode, 0o755)
        self.assertEqual(members["fermix_app_engine/lib/runtime.dat"].mode, 0o644)
        self.assertTrue(members["fermix_app_engine/runtime-link"].issym())
        self.assertEqual(members["fermix_app_engine/runtime-link"].linkname, "lib/runtime.dat")

    def test_archive_bytes_are_reproducible(self):
        first = package.package_release(self.release, TARGET, self.out / "one")
        second = package.package_release(self.release, TARGET, self.out / "two")

        self.assertEqual(self._sha256(first), self._sha256(second))

    def test_archive_root_mode_does_not_change_reproducible_bytes(self):
        first = package.package_release(self.release, TARGET, self.out / "one")
        os.chmod(self.release, 0o700)
        second = package.package_release(self.release, TARGET, self.out / "two")

        self.assertEqual(self._sha256(first), self._sha256(second))

    def test_rejects_tree_mutation_after_manifest_generation(self):
        (self.release / "lib/runtime.dat").write_text("mutated\n", encoding="utf-8")

        with self.assertRaisesRegex(package.PackageError, "tree_sha256"):
            package.package_release(self.release, TARGET, self.out)

    def test_archives_validated_snapshot_when_source_changes_before_write(self):
        write_archive = package._write_archive

        def mutate_source(root, destination):
            (self.release / "lib/runtime.dat").write_text("mutated\n", encoding="utf-8")
            write_archive(root, destination)

        with mock.patch.object(package, "_write_archive", side_effect=mutate_source):
            archive = package.package_release(self.release, TARGET, self.out)

        with tarfile.open(archive, "r:gz") as stream:
            payload = stream.extractfile("fermix_app_engine/lib/runtime.dat").read()

        self.assertEqual(payload, b"runtime\n")

    def test_rejects_manifest_target_mismatch(self):
        manifest = self._manifest()
        manifest["identity"]["artifact_target"] = "macos_x86_64"
        self._store_manifest(manifest)

        with self.assertRaisesRegex(package.PackageError, "artifact_target"):
            package.package_release(self.release, TARGET, self.out)

    def test_rejects_manifest_from_a_different_source_commit(self):
        with self.assertRaisesRegex(package.PackageError, "source_commit"):
            package.package_release(
                self.release,
                TARGET,
                self.out,
                expected_source_commit="b" * 40,
            )

    def test_rechecks_source_commit_after_snapshotting(self):
        snapshot_release_tree = package._snapshot_release_tree

        def replace_manifest_before_snapshot(root, snapshot):
            manifest = self._manifest()
            manifest["identity"]["source_commit"] = "b" * 40
            self._store_manifest(manifest)
            snapshot_release_tree(root, snapshot)

        with mock.patch.object(
            package,
            "_snapshot_release_tree",
            side_effect=replace_manifest_before_snapshot,
        ):
            with self.assertRaisesRegex(package.PackageError, "source_commit"):
                package.package_release(
                    self.release,
                    TARGET,
                    self.out,
                    expected_source_commit="a" * 40,
                )

    def test_rejects_executable_omitted_from_inventory(self):
        manifest = self._manifest()
        manifest["inventory"]["entries"] = [manifest["inventory"]["entries"][1]]
        self._store_manifest(manifest)

        with self.assertRaisesRegex(package.PackageError, "missing executable"):
            package.package_release(self.release, TARGET, self.out)

    def test_rejects_mach_o_whose_observed_architecture_differs_from_manifest(self):
        native = self.release / "lib/native.bundle"
        native.write_bytes(bytes.fromhex("cffaedfe") + (0x01000007).to_bytes(4, "little"))
        native.chmod(0o755)

        manifest = self._manifest()
        manifest["tree_sha256"] = package.compute_tree_digest(self.release)
        manifest["inventory"]["entries"].insert(
            1,
            {
                "path": "lib/native.bundle",
                "kind": "mach_o",
                "mode": "0755",
                "architectures": [ARCHITECTURE],
                "sha256": self._sha256(native),
            },
        )
        self._store_manifest(manifest)

        with self.assertRaisesRegex(package.PackageError, "Mach-O architecture mismatch"):
            package.package_release(self.release, TARGET, self.out)

    def test_rejects_symlink_that_escapes_release_root(self):
        os.symlink("../outside", self.release / "escape")

        with self.assertRaisesRegex(package.PackageError, "escapes release root"):
            package.package_release(self.release, TARGET, self.out)

    def test_rejects_absolute_symlink_targets_inside_the_staging_tree(self):
        target = (self.release / "lib/runtime.dat").resolve()
        os.symlink(target, self.release / "absolute-link")

        with self.assertRaisesRegex(package.PackageError, "absolute symlink target"):
            package.compute_tree_digest(self.release)

    def test_refuses_to_replace_an_existing_archive(self):
        self.out.mkdir(parents=True)
        destination = self.out / "fermix_app_engine_macos_aarch64.tar.gz"
        destination.write_bytes(b"existing")

        with self.assertRaisesRegex(package.PackageError, "already exists"):
            package.package_release(self.release, TARGET, self.out)

        self.assertEqual(destination.read_bytes(), b"existing")

    def test_refuses_archive_output_inside_the_release_tree(self):
        with self.assertRaisesRegex(package.PackageError, "outside the release tree"):
            package.package_release(self.release, TARGET, self.release / "artifacts")

        self.assertFalse((self.release / "artifacts").exists())

    def test_rejects_invalid_build_id(self):
        manifest = self._manifest()
        manifest["identity"]["build_id"] = "invalid build id"
        self._store_manifest(manifest)

        with self.assertRaisesRegex(package.PackageError, "build_id"):
            package.package_release(self.release, TARGET, self.out)

    def test_rejects_an_unexpected_engine_identity(self):
        manifest = self._manifest()
        manifest["identity"]["engine_id"] = "different-product"
        self._store_manifest(manifest)

        with self.assertRaisesRegex(package.PackageError, "engine_id"):
            package.package_release(self.release, TARGET, self.out)

    def test_removes_temporary_output_when_archive_creation_fails(self):
        with mock.patch.object(
            package,
            "_add_archive_tree",
            side_effect=package.PackageError("injected archive failure"),
        ):
            with self.assertRaisesRegex(package.PackageError, "injected archive failure"):
                package.package_release(self.release, TARGET, self.out)

        self.assertEqual(list(self.out.iterdir()), [])

    def _write_release_tree(self):
        (self.release / "bin").mkdir(parents=True)
        (self.release / "empty").mkdir()
        (self.release / "lib").mkdir()
        (self.release / "bin/fermix_app_engine").write_text(
            "#!/bin/sh\nexit 0\n", encoding="utf-8"
        )
        (self.release / "lib/runtime.dat").write_text("runtime\n", encoding="utf-8")
        os.symlink("lib/runtime.dat", self.release / "runtime-link")

        os.chmod(self.release, 0o755)
        os.chmod(self.release / "bin", 0o755)
        os.chmod(self.release / "empty", 0o700)
        os.chmod(self.release / "lib", 0o755)
        os.chmod(self.release / "bin/fermix_app_engine", 0o755)
        os.chmod(self.release / "lib/runtime.dat", 0o644)

    def _write_manifest(self):
        script = self.release / "bin/fermix_app_engine"
        manifest = {
            "schema_version": 1,
            "identity": {
                "engine_id": "fermix-core",
                "product_version": VERSION,
                "build_id": "release-test",
                "source_commit": "a" * 40,
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
                        "interpreter": "/bin/sh",
                        "sha256": self._sha256(script),
                    },
                    {
                        "path": "runtime-link",
                        "kind": "symlink",
                        "mode": "0777",
                        "target": "lib/runtime.dat",
                    },
                ],
            },
        }
        self._store_manifest(manifest)

    def _manifest(self):
        return json.loads((self.release / "engine-manifest.json").read_text(encoding="utf-8"))

    def _store_manifest(self, manifest):
        (self.release / "engine-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.chmod(self.release / "engine-manifest.json", 0o644)

    @staticmethod
    def _sha256(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()


class LinuxAppEngineTest(unittest.TestCase):
    """The Linux archive, whose manifest this module builds as well as checks."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-linux-engine-package-")
        self.base = Path(self.tmp.name)
        self.release = self.base / "release"
        self.out = self.base / "out"
        self.loader_payload, self.loader_name = linux_engine.loader_bytes(LINUX_ARCHITECTURE)
        self.interpreter = linux_engine.trusted_interpreter(self.loader_name)
        self._write_release_tree()
        self._write_manifest()

    def tearDown(self):
        self.tmp.cleanup()

    def test_builds_a_manifest_the_validator_then_accepts(self):
        archive = package.package_release(
            self.release, LINUX_TARGET, self.out, VERSION, "a" * 40
        )

        self.assertEqual(archive.name, "fermix_app_engine_linux_x86_64.tar.gz")
        manifest = self._manifest()
        self.assertEqual(manifest["identity"]["distribution_identity"], "linux_package")
        self.assertEqual(manifest["identity"]["architecture"], LINUX_ARCHITECTURE)
        self.assertEqual(manifest["protocols"], PROTOCOLS)

    def test_the_inventory_lists_every_elf_and_nothing_else(self):
        entries = {entry["path"]: entry for entry in self._manifest()["inventory"]["entries"]}

        self.assertEqual(
            sorted(entries),
            sorted(
                [
                    "maintainer/postinstall.sh",
                    "maintainer/postremove.sh",
                    "tree/usr/bin/fermix",
                    "tree/usr/lib/fermix/cosign",
                    f"tree/usr/lib/fermix/runtime-payload/{self.loader_name}",
                ]
            ),
        )
        self.assertEqual(entries["tree/usr/bin/fermix"]["kind"], "elf")
        self.assertEqual(entries["tree/usr/bin/fermix"]["architectures"], [LINUX_ARCHITECTURE])
        self.assertEqual(entries["tree/usr/bin/fermix"]["interpreter"], self.interpreter)
        self.assertIsNone(entries["tree/usr/lib/fermix/cosign"]["interpreter"])
        self.assertEqual(entries["maintainer/postinstall.sh"]["kind"], "script")

    def test_rejects_an_elf_built_for_the_other_architecture(self):
        self._replace(
            "tree/usr/bin/fermix",
            linux_engine.elf_bytes("arm64", interpreter=self.interpreter),
        )

        with self.assertRaisesRegex(package.PackageError, "ELF architecture mismatch"):
            package.package_release(self.release, LINUX_TARGET, self.out, VERSION, "a" * 40)

    def test_rejects_an_interpreter_that_is_not_the_staged_loader(self):
        self._replace(
            "tree/usr/bin/fermix",
            linux_engine.elf_bytes(
                LINUX_ARCHITECTURE, interpreter=f"/var/lib/fermix/runtimes/{'b' * 64}/libc-musl.so"
            ),
        )

        with self.assertRaisesRegex(package.PackageError, "does not name the staged loader"):
            package.package_release(self.release, LINUX_TARGET, self.out, VERSION, "a" * 40)

    def test_rejects_a_loader_whose_bytes_are_not_its_name(self):
        payload = self.release / f"tree/usr/lib/fermix/runtime-payload/{self.loader_name}"
        payload.write_bytes(self.loader_payload + b"tampered")
        self._restamp()

        with self.assertRaisesRegex(package.PackageError, "is named"):
            package.package_release(self.release, LINUX_TARGET, self.out, VERSION, "a" * 40)

    def test_rejects_a_systemd_unit_that_is_not_the_packaged_one(self):
        self._replace("tree/usr/lib/systemd/user/fermix.service", b"[Unit]\nDescription=other\n")

        with self.assertRaisesRegex(package.PackageError, "systemd unit"):
            package.package_release(self.release, LINUX_TARGET, self.out, VERSION, "a" * 40)

    def test_rejects_a_macos_distribution_identity_on_a_linux_target(self):
        manifest = self._manifest()
        manifest["identity"]["distribution_identity"] = "macos_app"
        self._store_manifest(manifest)

        with self.assertRaisesRegex(package.PackageError, "distribution_identity"):
            package.package_release(self.release, LINUX_TARGET, self.out, VERSION, "a" * 40)

    def test_refuses_to_build_a_macos_manifest(self):
        with self.assertRaisesRegex(package.PackageError, "comes from the release step"):
            package.build_manifest(
                self.release,
                TARGET,
                product_version=VERSION,
                build_id="release-test",
                source_commit="a" * 40,
                protocols=PROTOCOLS,
            )

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
            "tree/usr/share/fermix/engine.json": (b"{}\n", 0o644),
            "maintainer/postinstall.sh": (b"#!/bin/sh\nexit 0\n", 0o755),
            "maintainer/postremove.sh": (b"#!/bin/sh\nexit 0\n", 0o755),
            "nfpm-contents.yaml": (b"contents:\n", 0o644),
        }
        for relative, (payload, mode) in files.items():
            path = self.release / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            path.chmod(mode)

    def _write_manifest(self):
        manifest = package.build_manifest(
            self.release,
            LINUX_TARGET,
            product_version=VERSION,
            build_id="release-test",
            source_commit="a" * 40,
            protocols=PROTOCOLS,
        )
        self._store_manifest(manifest)

    def _replace(self, relative, payload):
        """Swap one staged file and rebuild the manifest around it.

        A tampered tree that still carries the old manifest refuses on the
        digest, which would pass every case below for the wrong reason. The
        builder states what the tree says; the validator is what is under test.
        """
        (self.release / relative).write_bytes(payload)
        self._restamp()

    def _restamp(self):
        self._write_manifest()

    def _manifest(self):
        return json.loads((self.release / "engine-manifest.json").read_text(encoding="utf-8"))

    def _store_manifest(self, manifest):
        path = self.release / "engine-manifest.json"
        path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        path.chmod(0o644)


if __name__ == "__main__":
    unittest.main()
