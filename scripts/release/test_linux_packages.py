#!/usr/bin/env python3
"""Hermetic tests for Linux package staging and orchestration."""

import contextlib
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import linux_packages as packages  # noqa: E402



def _silent_main(argv, **kwargs):
    """Run the builder without its own stdout landing in the test report.

    `main` prints each produced package path, which is how the shell script
    reads them back; a test that let that through makes a green run look like
    it printed errors.
    """
    with contextlib.redirect_stdout(io.StringIO()):
        return packages.main(argv, **kwargs)


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(__file__).with_name("build_linux_packages.sh")
TARGET = "linux_aarch64"
VERSION = "9.9.9"
SOURCE_COMMIT = "a" * 40


def digest_of(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class FakeResponse:
    def __init__(self, payload: bytes):
        self.payload = payload

    def read(self) -> bytes:
        return self.payload

    def __enter__(self):
        return self

    def __exit__(self, *_exception):
        return False


class PureHelpersTest(unittest.TestCase):
    def test_render_template_substitutes_every_placeholder(self):
        rendered = packages.render_template("a={{ONE}} b={{TWO}}", {"ONE": 1, "TWO": "two"})

        self.assertEqual(rendered, "a=1 b=two")

    def test_render_template_refuses_a_placeholder_this_build_does_not_set(self):
        with self.assertRaises(packages.BuildError) as refusal:
            packages.render_template("{{VERSION}} {{MYSTERY}}", {"VERSION": "1.0.0"})

        self.assertIn("MYSTERY", str(refusal.exception))

    def test_version_refuses_a_revision_or_an_epoch(self):
        for version in ("1.2.3-1", "1:1.2.3", "1.2.3-rc.1"):
            with self.subTest(version=version):
                with self.assertRaises(packages.BuildError) as refusal:
                    packages.check_version(version)
                self.assertIn("revision or an epoch", str(refusal.exception))

    def test_version_refuses_anything_that_is_not_three_numbers(self):
        with self.assertRaises(packages.BuildError):
            packages.check_version("v1.2.3")

    def test_engine_manifest_publishes_the_installed_identity(self):
        manifest = packages.engine_manifest(
            target=TARGET,
            version=VERSION,
            build_id="release-1",
            source_commit=SOURCE_COMMIT,
            loader_sha256="b" * 64,
            binary_sha256="c" * 64,
        )

        self.assertEqual(
            manifest,
            {
                "schema_version": 1,
                "engine_id": "fermix-core",
                "product_version": VERSION,
                "build_id": "release-1",
                "source_commit": SOURCE_COMMIT,
                "distribution_identity": "linux_package",
                "artifact_target": TARGET,
                "architecture": "arm64",
                "loader_sha256": "b" * 64,
                "binary_sha256": "c" * 64,
            },
        )

    def test_engine_manifest_names_the_x86_architecture_for_that_target(self):
        manifest = packages.engine_manifest(
            target="linux_x86_64",
            version=VERSION,
            build_id="release-1",
            source_commit=SOURCE_COMMIT,
            loader_sha256="b" * 64,
            binary_sha256="c" * 64,
        )

        self.assertEqual(manifest["architecture"], "x86_64")

    def test_debian_changelog_renders_the_newest_released_section_first(self):
        markdown = (
            "# Changelog\n\n"
            "## [Unreleased]\n\n- **Not released yet.**\n\n"
            "## [9.9.9] - 2026-09-12\n\n### Fixed\n\n- **A thing.** Explained,\n  over two lines.\n\n"
            "## [9.9.8] - 2026-08-01\n\n- **Another thing.**\n"
        )

        rendered = packages.debian_changelog(markdown, "9.9.9")

        self.assertTrue(rendered.startswith("fermix (9.9.9) stable; urgency=medium"))
        self.assertIn("  * A thing. Explained, over two lines.", rendered)
        self.assertIn("fermix (9.9.8) stable; urgency=medium", rendered)
        self.assertIn(" -- Tezra <hello@fermix.ai>  Sat, 12 Sep 2026", rendered)
        self.assertNotIn("Not released yet", rendered)

    def test_debian_changelog_refuses_a_version_the_changelog_has_not_released(self):
        markdown = "## [Unreleased]\n\n- new\n\n## [9.9.8] - 2026-08-01\n\n- old\n"

        with self.assertRaises(packages.BuildError) as refusal:
            packages.debian_changelog(markdown, "9.9.9")

        self.assertIn("9.9.9", str(refusal.exception))

    def test_the_repository_changelog_renders_for_its_own_newest_version(self):
        markdown = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        newest = re.search(r"^## \[(\d+\.\d+\.\d+)\]", markdown, re.MULTILINE).group(1)

        rendered = packages.debian_changelog(markdown, newest)

        self.assertTrue(rendered.startswith(f"fermix ({newest}) stable; urgency=medium"))

    def test_gzip_bytes_is_deterministic(self):
        first = packages.gzip_bytes(b"the man page")
        second = packages.gzip_bytes(b"the man page")

        self.assertEqual(first, second)
        self.assertEqual(gzip.decompress(first), b"the man page")


class LoaderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-loader-")
        self.directory = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_returns_the_one_loader_and_its_verified_digest(self):
        payload = b"loader bytes"
        digest = digest_of(payload)
        (self.directory / f"libc-musl-{digest}.so").write_bytes(payload)

        loader, reported = packages.loader_in(self.directory)

        self.assertEqual(reported, digest)
        self.assertEqual(loader.read_bytes(), payload)

    def test_refuses_a_loader_whose_bytes_are_not_its_name(self):
        (self.directory / f"libc-musl-{'d' * 64}.so").write_bytes(b"loader bytes")

        with self.assertRaises(packages.BuildError) as refusal:
            packages.loader_in(self.directory)

        self.assertIn("has digest", str(refusal.exception))

    def test_refuses_when_the_release_published_no_loader(self):
        with self.assertRaises(packages.BuildError) as refusal:
            packages.loader_in(self.directory)

        self.assertIn("exactly one loader", str(refusal.exception))

    def test_refuses_when_two_loaders_are_present(self):
        for name in ("a", "b"):
            payload = f"loader {name}".encode()
            (self.directory / f"libc-musl-{digest_of(payload)}.so").write_bytes(payload)

        with self.assertRaises(packages.BuildError):
            packages.loader_in(self.directory)


class DownloadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-download-")
        self.cache = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_verifies_the_pinned_digest(self):
        payload = b"the pinned tool"
        destination = packages.download_verified(
            "https://example.invalid/tool",
            digest_of(payload),
            self.cache / "tool",
            lambda _url: FakeResponse(payload),
        )

        self.assertEqual(destination.read_bytes(), payload)

    def test_refuses_bytes_that_are_not_the_pinned_digest(self):
        with self.assertRaises(packages.BuildError) as refusal:
            packages.download_verified(
                "https://example.invalid/tool",
                "e" * 64,
                self.cache / "tool",
                lambda _url: FakeResponse(b"something else"),
            )

        self.assertIn("this build pins", str(refusal.exception))
        self.assertFalse((self.cache / "tool").exists())

    def test_reuses_a_cached_copy_with_the_pinned_digest(self):
        payload = b"the pinned tool"
        (self.cache / "tool").write_bytes(payload)

        def refusing(_url):
            raise AssertionError("a verified cached copy must not be downloaded again")

        destination = packages.download_verified(
            "https://example.invalid/tool", digest_of(payload), self.cache / "tool", refusing
        )

        self.assertEqual(destination.read_bytes(), payload)


class BuildTest(unittest.TestCase):
    """The whole helper, with the network and nfpm replaced by fixtures."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-linux-packages-")
        self.base = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

        self.source = self.base / "source"
        self.out = self.base / "out"
        self.staged = None
        self.configs = []

        self._write_source_tree()

        self.loader_payload = b"the musl loader"
        self.loader_digest = digest_of(self.loader_payload)
        loader_dir = self.source / "packaging/linux/out" / TARGET
        loader_dir.mkdir(parents=True)
        (loader_dir / f"libc-musl-{self.loader_digest}.so").write_bytes(self.loader_payload)

        self.wrapper = self.source / "burrito_out" / f"fermix_linux_package_{TARGET}"
        self.wrapper.parent.mkdir(parents=True)
        self.wrapper.write_bytes(b"the burrito wrapper")

        self.nfpm_archive = self._nfpm_archive()
        self.cosign_payload = b"the pinned cosign"

        # The pins are data, and the verifier that reads them is what is under
        # test: the fixtures get their own digests so `download_verified` still
        # refuses anything else.
        self._pin(
            packages.NFPM_RELEASES,
            {
                machine: (asset, digest_of(self.nfpm_archive))
                for machine, (asset, _sha) in packages.NFPM_RELEASES.items()
            },
        )
        self._pin(
            packages.COSIGN_RELEASES,
            {
                target: (asset, digest_of(self.cosign_payload))
                for target, (asset, _sha) in packages.COSIGN_RELEASES.items()
            },
        )

    def _pin(self, table, values):
        patch = mock.patch.dict(table, values, clear=True)
        patch.start()
        self.addCleanup(patch.stop)

    # ── the fixtures ────────────────────────────────────────────────────────

    def _write_source_tree(self):
        packaging = self.source / "packaging/linux"
        for relative, contents in {
            "nfpm-fermix.yaml.tmpl": (ROOT / "packaging/linux/nfpm-fermix.yaml.tmpl").read_text(),
            "systemd/fermix.service": "[Unit]\n",
            "completions/fermix.bash": "# bash\n",
            "completions/_fermix": "# zsh\n",
            "completions/fermix.fish": "# fish\n",
            "man/fermix.1": ".TH FERMIX 1\n",
            "copyright": "Format: https://www.debian.org/\n",
            "scripts/postinstall.sh": "#!/bin/sh\nexit 0\n",
            "scripts/postremove.sh": "#!/bin/sh\nexit 0\n",
        }.items():
            path = packaging / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8")

        (self.source / "CHANGELOG.md").write_text(
            f"# Changelog\n\n## [Unreleased]\n\n- pending\n\n"
            f"## [{VERSION}] - 2026-09-12\n\n- **Shipped.** It works.\n",
            encoding="utf-8",
        )

    def _nfpm_archive(self) -> bytes:
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            payload = b"#!/bin/sh\nexit 0\n"
            entry = tarfile.TarInfo("nfpm")
            entry.size = len(payload)
            entry.mode = 0o755
            archive.addfile(entry, io.BytesIO(payload))
        return buffer.getvalue()

    def _opener(self, url):
        if "nfpm" in url:
            return FakeResponse(self.nfpm_archive)
        if "cosign" in url:
            return FakeResponse(self.cosign_payload)
        raise AssertionError(f"unexpected download: {url}")

    def _runner(self, argv, **_options):
        if argv[1:] == ["--version"]:
            return subprocess.CompletedProcess(argv, 0)

        config = Path(argv[argv.index("--config") + 1])
        self.configs.append(config.read_text(encoding="utf-8"))

        # The staging tree lives in a working directory the helper removes on
        # its way out, so it is copied here, with its modes, while nfpm would
        # have been reading it.
        if self.staged is None:
            self.staged = self.base / "staged"
            shutil.copytree(self._stage_root(self.configs[-1]), self.staged, symlinks=True)

        packager = argv[argv.index("--packager") + 1]
        target = Path(argv[argv.index("--target") + 1])
        target.mkdir(parents=True, exist_ok=True)
        name = (
            f"fermix_{VERSION}_arm64.deb"
            if packager == "deb"
            else f"fermix-{VERSION}-1.aarch64.rpm"
        )
        (target / name).write_bytes(b"package")
        return subprocess.CompletedProcess(argv, 0)

    @staticmethod
    def _stage_root(config: str) -> Path:
        return Path(re.search(r"src: (\S+)/usr/bin/fermix", config).group(1))

    def _build(self, **overrides):
        argv = [
            "--target",
            overrides.get("target", TARGET),
            "--version",
            overrides.get("version", VERSION),
            "--output-dir",
            str(self.out),
            "--source-root",
            str(self.source),
            "--build-id",
            "release-1",
            "--source-commit",
            SOURCE_COMMIT,
            "--host-machine",
            overrides.get("host_machine", "aarch64"),
        ]
        return _silent_main(argv, opener=self._opener, runner=self._runner)

    # ── the cases ───────────────────────────────────────────────────────────

    def test_builds_both_formats_from_one_rendered_configuration(self):
        self.assertEqual(self._build(), 0)

        self.assertTrue((self.out / f"fermix_{VERSION}_arm64.deb").is_file())
        self.assertTrue((self.out / f"fermix-{VERSION}-1.aarch64.rpm").is_file())
        self.assertEqual(len(self.configs), 2)
        self.assertEqual(self.configs[0], self.configs[1])

    def test_the_debian_package_name_carries_no_revision(self):
        self.assertEqual(self._build(), 0)

        produced = sorted(path.name for path in self.out.iterdir())
        self.assertEqual(produced, [f"fermix-{VERSION}-1.aarch64.rpm", f"fermix_{VERSION}_arm64.deb"])
        self.assertNotIn("-1_", produced[1])

    def test_the_rendered_configuration_carries_the_package_facts(self):
        self._build()
        config = self.configs[0]

        self.assertIn(f'version: "{VERSION}"', config)
        self.assertIn("arch: arm64", config)
        self.assertIn('release: ""', config)
        self.assertIn("maintainer: Tezra <hello@fermix.ai>", config)
        self.assertIn(f"runtime-payload/libc-musl-{self.loader_digest}.so", config)
        self.assertIn("postinstall: ", config)
        self.assertNotIn("{{", config)

    def test_the_staged_tree_carries_every_installed_file_at_its_mode(self):
        self._build()

        for installed, mode in packages.STAGED_MODES.items():
            with self.subTest(installed=installed):
                path = self.staged / installed
                self.assertTrue(path.is_file(), installed)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), mode)

        payload = self.staged / "usr/lib/fermix/runtime-payload" / f"libc-musl-{self.loader_digest}.so"
        self.assertEqual(payload.read_bytes(), self.loader_payload)
        self.assertEqual((self.staged / "usr/bin/fermix").read_bytes(), b"the burrito wrapper")
        self.assertEqual((self.staged / "usr/lib/fermix/cosign").read_bytes(), self.cosign_payload)

    def test_the_staged_manifest_reports_the_installed_identity(self):
        self._build()

        manifest = json.loads((self.staged / "usr/share/fermix/engine.json").read_text())
        self.assertEqual(manifest["distribution_identity"], "linux_package")
        self.assertEqual(manifest["artifact_target"], TARGET)
        self.assertEqual(manifest["loader_sha256"], self.loader_digest)
        self.assertEqual(manifest["binary_sha256"], digest_of(b"the burrito wrapper"))

    def test_the_staged_documentation_is_gzipped(self):
        self._build()

        page = gzip.decompress((self.staged / "usr/share/man/man1/fermix.1.gz").read_bytes())
        changelog = gzip.decompress(
            (self.staged / "usr/share/doc/fermix/changelog.Debian.gz").read_bytes()
        )

        self.assertEqual(page, b".TH FERMIX 1\n")
        self.assertIn(f"fermix ({VERSION}) stable".encode(), changelog)

    def test_a_cross_built_package_carries_the_target_architecture_cosign(self):
        seen = []

        def opener(url):
            seen.append(url)
            return self._opener(url)

        argv = [
            "--target",
            TARGET,
            "--version",
            VERSION,
            "--output-dir",
            str(self.out),
            "--source-root",
            str(self.source),
            "--build-id",
            "release-1",
            "--source-commit",
            SOURCE_COMMIT,
            "--host-machine",
            "x86_64",
        ]
        self.assertEqual(_silent_main(argv, opener=opener, runner=self._runner), 0)

        self.assertIn(
            f"https://github.com/goreleaser/nfpm/releases/download/v{packages.NFPM_VERSION}/"
            f"nfpm_{packages.NFPM_VERSION}_Linux_x86_64.tar.gz",
            seen,
        )
        self.assertIn(
            f"https://github.com/sigstore/cosign/releases/download/v{packages.COSIGN_VERSION}/"
            "cosign-linux-arm64",
            seen,
        )

    def test_refuses_a_build_whose_wrapper_is_missing(self):
        self.wrapper.unlink()

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(self._build(), 1)

        self.assertIn("release wrapper", stderr.getvalue())

    def test_refuses_a_version_with_a_revision_before_anything_is_staged(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(self._build(version="9.9.9-2"), 1)

        self.assertIn("revision or an epoch", stderr.getvalue())
        self.assertFalse(self.out.exists())

    def test_refuses_a_host_no_pinned_packager_exists_for(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(self._build(host_machine="riscv64"), 1)

        self.assertIn("--container", stderr.getvalue())

    def test_refuses_when_nfpm_produced_nothing(self):
        def silent(argv, **_options):
            return subprocess.CompletedProcess(argv, 0)

        argv = [
            "--target",
            TARGET,
            "--version",
            VERSION,
            "--output-dir",
            str(self.out),
            "--source-root",
            str(self.source),
            "--build-id",
            "release-1",
            "--source-commit",
            SOURCE_COMMIT,
            "--host-machine",
            "aarch64",
        ]

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(_silent_main(argv, opener=self._opener, runner=silent), 1)

        self.assertIn("nfpm did not produce", stderr.getvalue())


class BuildScriptTest(unittest.TestCase):
    """The orchestration script, with mix, python3 and the host faked."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-linux-build-")
        self.base = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

        self.bin = self.base / "bin"
        self.out = self.base / "out"
        self.runner_temp = self.base / "runner"
        self.log = self.base / "commands.log"
        self.bin.mkdir()
        self.runner_temp.mkdir()

        self._write_executable("uname", '#!/bin/sh\n[ "$1" = "-s" ] && printf "Linux\\n" || printf "aarch64\\n"\n')
        self._write_fake_mix()
        self._write_fake_python()

    def test_dev_mode_stamps_a_build_identity_that_says_so(self):
        result = self._run(TARGET, VERSION, "--dev")

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = self.log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            [line.split("|", 1)[0] for line in lines],
            ["deps.get", "compile", "assets.setup", "assets.deploy", "release", "package"],
        )

        release = lines[4].split("|")
        self.assertEqual(release[1], "fermix_linux_package")
        self.assertEqual(release[2], "--overwrite")
        self.assertEqual(release[3], "linux_package")
        self.assertEqual(release[4], TARGET)
        self.assertEqual(release[5], TARGET)
        self.assertRegex(release[6], r"^dev-[0-9a-f]{12}-dirty$")
        self.assertRegex(release[7], r"^[0-9a-f]{40}$")

        package = lines[5].split("|")
        self.assertEqual(package[1], TARGET)
        self.assertEqual(package[2], VERSION)
        self.assertEqual(package[3], str(self.out.resolve()))
        self.assertRegex(package[4], r"^dev-[0-9a-f]{12}-dirty$")

    def test_dev_mode_builds_a_snapshot_rather_than_the_checkout(self):
        result = self._run(TARGET, VERSION, "--dev")

        self.assertEqual(result.returncode, 0, result.stderr)
        source_root = Path(self.log.read_text(encoding="utf-8").splitlines()[0].split("|")[1])

        self.assertEqual(source_root.name, "source")
        self.assertTrue(source_root.parent.name.startswith(f"fermix-linux-package-{TARGET}."))
        self.assertTrue(str(source_root).startswith(str(self.runner_temp.resolve())))
        self.assertNotEqual(source_root, ROOT)
        self.assertFalse(source_root.exists(), "the snapshot must be cleaned up")

    def test_refuses_a_version_with_a_revision_before_running_anything(self):
        result = self._run(TARGET, "0.9.0-1", "--dev")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("revision or an epoch", result.stderr)
        self.assertFalse(self.log.exists())

    def test_refuses_a_prerelease_version(self):
        result = self._run(TARGET, "0.9.0-rc.1", "--dev")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_refuses_an_unsupported_target(self):
        result = self._run("linux_riscv64", VERSION, "--dev")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported target", result.stderr)
        self.assertFalse(self.log.exists())

    def test_a_release_build_requires_the_build_identity(self):
        result = self._run(TARGET, VERSION, FERMIX_BUILD_ID="")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FERMIX_BUILD_ID", result.stderr)
        self.assertFalse(self.log.exists())

    def test_a_release_build_refuses_a_commit_that_is_not_the_checkout(self):
        result = self._run(
            TARGET,
            VERSION,
            FERMIX_BUILD_ID="release-1",
            FERMIX_BUILD_SOURCE_COMMIT="b" * 40,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the checkout", result.stderr)
        self.assertFalse(self.log.exists())

    def test_refuses_a_non_linux_host_and_names_the_container(self):
        self._write_executable(
            "uname", '#!/bin/sh\n[ "$1" = "-s" ] && printf "Darwin\\n" || printf "arm64\\n"\n'
        )

        result = self._run(TARGET, VERSION, "--dev")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--container", result.stderr)
        self.assertFalse(self.log.exists())

    def test_container_mode_refuses_an_output_directory_outside_the_checkout(self):
        self._write_executable("docker", "#!/bin/sh\nexit 0\n")

        result = self._run(TARGET, VERSION, "--container", "--dev")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output directory under", result.stderr)

    def _run(self, target, version, *flags, **overrides):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin}:{env['PATH']}",
                "RUNNER_TEMP": str(self.runner_temp),
                "COMMAND_LOG": str(self.log),
                "FERMIX_BUILD_DISTRIBUTION": "untrusted-inherited-value",
                "FERMIX_BUILD_TARGET": "untrusted-inherited-value",
            }
        )
        env.pop("FERMIX_BUILD_ID", None)
        env.pop("FERMIX_BUILD_SOURCE_COMMIT", None)
        env.update(overrides)

        return subprocess.run(
            [str(SCRIPT), target, version, str(self.out), *flags],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def _write_fake_mix(self):
        self._write_executable(
            "mix",
            """#!/bin/sh
set -eu
command="$1"
shift
if [ "$command" = "release" ]; then
  mkdir -p "$PWD/burrito_out"
  printf 'wrapper' > "$PWD/burrito_out/fermix_linux_package_$FERMIX_BUILD_TARGET"
  printf 'release|%s|%s|%s|%s|%s|%s|%s\\n' \\
    "$1" "$2" "$FERMIX_BUILD_DISTRIBUTION" "$FERMIX_BUILD_TARGET" "$BURRITO_TARGET" \\
    "$FERMIX_BUILD_ID" "$FERMIX_BUILD_SOURCE_COMMIT" >> "$COMMAND_LOG"
else
  printf '%s|%s|%s\\n' "$command" "$PWD" "$*" >> "$COMMAND_LOG"
fi
""",
        )

    def _write_fake_python(self):
        self._write_executable(
            "python3",
            """#!/bin/sh
set -eu
helper="$1"
shift
case "$helper" in
  *linux_packages.py) ;;
  *) exec /usr/bin/python3 "$helper" "$@" ;;
esac
[ "$1" = "--target" ]; target="$2"; shift 2
[ "$1" = "--version" ]; version="$2"; shift 2
[ "$1" = "--output-dir" ]; output="$2"; shift 2
[ "$1" = "--source-root" ]; source_root="$2"; shift 2
[ "$1" = "--build-id" ]; build_id="$2"; shift 2
[ "$1" = "--source-commit" ]; source_commit="$2"
[ -f "$source_root/burrito_out/fermix_linux_package_$target" ]
printf 'package|%s|%s|%s|%s|%s\\n' \\
  "$target" "$version" "$output" "$build_id" "$source_commit" >> "$COMMAND_LOG"
""",
        )

    def _write_executable(self, name, contents):
        path = self.bin / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
