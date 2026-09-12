#!/usr/bin/env python3
"""Hermetic tests for native app-engine release orchestration."""

import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("build_app_engine.sh")
SOURCE_COMMIT = "a" * 40


class BuildAppEngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-app-engine-build-")
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.out = self.base / "out"
        self.runner_temp = self.base / "runner"
        self.log = self.base / "commands.log"
        self.source_archive = self.base / "source.tar"
        self.bin.mkdir()
        self.runner_temp.mkdir()
        self._write_source_archive()
        self._write_fake_uname("arm64")
        self._write_fake_git(SOURCE_COMMIT)
        self._write_fake_mix()
        self._write_fake_python()

    def tearDown(self):
        self.tmp.cleanup()

    def test_builds_in_a_fresh_target_scoped_path_and_packages_the_release(self):
        result = self._run("macos_aarch64")

        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.out / "fermix_app_engine_macos_aarch64.tar.gz"
        self.assertEqual(result.stdout.strip(), str(archive.resolve()))
        self.assertEqual(archive.read_bytes(), b"archive")

        lines = self.log.read_text(encoding="utf-8").splitlines()
        self.assertEqual([line.split("|", 1)[0] for line in lines], [
            "deps.get",
            "deps.compile",
            "compile",
            "assets.setup",
            "assets.deploy",
            "release",
            "package",
        ])

        source_root = Path(lines[0].split("|")[1])
        self.assertEqual(source_root.name, "source")
        self.assertTrue(source_root.parent.name.startswith("fermix-app-engine-macos_aarch64."))
        self.assertEqual(lines[1].split("|")[1], str(source_root))
        self.assertEqual(lines[2].split("|")[1], str(source_root))
        self.assertEqual(lines[2].split("|")[2], "--warnings-as-errors")
        self.assertEqual(lines[3].split("|")[1], str(source_root / "apps/fermix_web"))
        self.assertEqual(lines[4].split("|")[1], str(source_root / "apps/fermix_web"))

        release = lines[5].split("|")
        self.assertEqual(release[1], "fermix_app_engine")
        self.assertEqual(release[2], "--path")
        self.assertTrue(release[3].startswith(str(self.runner_temp.resolve())))
        self.assertEqual(release[4], "macos_app")
        self.assertEqual(release[5], "macos_aarch64")
        self.assertEqual(release[6], "release-test")
        self.assertEqual(release[7], SOURCE_COMMIT)
        self.assertEqual(release[8], "")
        self.assertEqual(release[9], str(source_root))
        self.assertFalse(source_root.exists())

        package = lines[6].split("|")
        self.assertEqual(package[4], SOURCE_COMMIT)

    def test_canonicalizes_the_scratch_parent_before_mix_creates_dependency_links(self):
        alias = self.base / "runner-alias"
        os.symlink(self.runner_temp, alias)

        result = self._run("macos_aarch64", RUNNER_TEMP=str(alias))

        self.assertEqual(result.returncode, 0, result.stderr)
        release = self.log.read_text(encoding="utf-8").splitlines()[5].split("|")
        source_root = release[9]
        self.assertTrue(source_root.startswith(str(self.runner_temp.resolve())))
        self.assertFalse(source_root.startswith(str(alias)))

    def test_rejects_native_host_mismatch_before_running_mix(self):
        self._write_fake_uname("x86_64")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires host architecture arm64", result.stderr)
        self.assertFalse(self.log.exists())

    def test_rejects_unknown_host_architecture_with_a_clear_error(self):
        self._write_fake_uname("riscv64")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported host architecture: riscv64", result.stderr)
        self.assertNotIn("unbound variable", result.stderr)
        self.assertFalse(self.log.exists())

    def test_rejects_invalid_build_identity_before_running_mix(self):
        result = self._run("macos_aarch64", FERMIX_BUILD_ID="invalid build id")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FERMIX_BUILD_ID", result.stderr)
        self.assertFalse(self.log.exists())

    def test_rejects_source_commit_that_does_not_match_the_checkout(self):
        self._write_fake_git("b" * 40)

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the checkout", result.stderr)
        self.assertFalse(self.log.exists())

    def test_rejects_a_checkout_with_uncommitted_source_changes(self):
        self._write_fake_git(SOURCE_COMMIT, " M apps/fermix_core/lib/example.ex")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("uncommitted source changes", result.stderr)
        self.assertFalse(self.log.exists())

    def test_refuses_to_replace_an_existing_archive_before_running_mix(self):
        self.out.mkdir()
        archive = self.out / "fermix_app_engine_macos_aarch64.tar.gz"
        archive.write_bytes(b"existing")

        result = self._run("macos_aarch64")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertEqual(archive.read_bytes(), b"existing")
        self.assertFalse(self.log.exists())

    def _run(self, target, **overrides):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin}:{env['PATH']}",
                "RUNNER_TEMP": str(self.runner_temp),
                "COMMAND_LOG": str(self.log),
                "SOURCE_ARCHIVE": str(self.source_archive),
                "FERMIX_BUILD_ID": "release-test",
                "FERMIX_BUILD_SOURCE_COMMIT": SOURCE_COMMIT,
                "FERMIX_BUILD_DISTRIBUTION": "untrusted-inherited-value",
                "FERMIX_BUILD_TARGET": "untrusted-inherited-value",
            }
        )
        env.update(overrides)
        return subprocess.run(
            [str(SCRIPT), target, str(self.out), "0.9.0"],
            cwd=SCRIPT.parents[2],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def _write_source_archive(self):
        with tarfile.open(self.source_archive, "w") as archive:
            for name in ("apps", "apps/fermix_web", "scripts", "scripts/release"):
                entry = tarfile.TarInfo(name)
                entry.type = tarfile.DIRTYPE
                entry.mode = 0o755
                archive.addfile(entry)

    def _write_fake_uname(self, architecture):
        self._write_executable(
            "uname",
            f'#!/bin/sh\n[ "$1" = "-s" ] && printf "Darwin\\n" || printf "{architecture}\\n"\n',
        )

    def _write_fake_git(self, commit, status=""):
        self._write_executable(
            "git",
            f'''#!/bin/sh
case "$1" in
  rev-parse) [ "$2" = "HEAD" ] && printf "%s\\n" "{commit}" ;;
  status) printf "%s" "{status}" ;;
  archive) /bin/cat "$SOURCE_ARCHIVE" ;;
  *) exit 2 ;;
esac
''',
        )

    def _write_fake_mix(self):
        self._write_executable(
            "mix",
            """#!/bin/sh
set -eu
command="$1"
shift
if [ "$command" = "release" ]; then
  release="$1"
  shift
  [ "$1" = "--path" ]
  release_path="$2"
  mkdir -p "$release_path"
  printf '{}\n' > "$release_path/engine-manifest.json"
  printf 'release|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$release" "$1" "$2" "$FERMIX_BUILD_DISTRIBUTION" "$FERMIX_BUILD_TARGET" \
    "$FERMIX_BUILD_ID" "$FERMIX_BUILD_SOURCE_COMMIT" "${MIX_BUILD_PATH:-}" "$PWD" >> "$COMMAND_LOG"
else
  printf '%s|%s|%s\n' "$command" "$PWD" "$*" >> "$COMMAND_LOG"
fi
""",
        )

    def _write_fake_python(self):
        self._write_executable(
            "python3",
            """#!/bin/sh
set -eu
shift
[ "$1" = "--release-root" ]; release_root="$2"; shift 2
[ "$1" = "--target" ]; target="$2"; shift 2
[ "$1" = "--output-dir" ]; output="$2"; shift 2
[ "$1" = "--version" ]; version="$2"; shift 2
[ "$1" = "--source-commit" ]; source_commit="$2"
[ -f "$release_root/engine-manifest.json" ]
printf 'package|%s|%s|%s|%s\n' "$release_root" "$target" "$version" "$source_commit" >> "$COMMAND_LOG"
archive="$output/fermix_app_engine_${target}.tar.gz"
printf archive > "$archive"
printf '%s\n' "$archive"
""",
        )

    def _write_executable(self, name, contents):
        path = self.bin / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
