#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for pin_iroh_helper.

No network, no cosign, no helper: the release is a dict of fake assets built
here from minimal ELF and Mach-O headers, every download goes through a fake
`fetch` and every subprocess through a fake `runner`. Run with:
  uv run scripts/release/test_pin_iroh_helper.py
"""

import contextlib
import hashlib
import io
import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import pin_iroh_helper as pin  # noqa: E402

TAG = "v0.1.0"
IDENTITY = "https://github.com/tezra-io/fermix-iroh/.github/workflows/release.yml@refs/tags/v0.1.0"
ISSUER = "https://token.actions.githubusercontent.com"
HELLO = b'{"event":"hello","protocol_version":1,"helper_version":"0.1.0","iroh_version":"1.3.0"}\n'
VERSION_LINE = b"fermix-iroh 0.1.0 (iroh 1.3.0)\n"
LINUX_HOST = ("Linux", "x86_64")
CHECKED_IN_PIN = Path(__file__).resolve().parents[2] / "apps/fermix_core/priv/iroh_helper/PIN.json"

PT_LOAD = 1


def elf(machine=pin.EM_X86_64, *, interp=False, elf_class=2):
    """A minimal ELF: header, a PT_LOAD, and (when asked) a PT_INTERP after it."""

    types = [PT_LOAD, pin.PT_INTERP] if interp else [PT_LOAD]
    ident = b"\x7fELF" + bytes([elf_class, 1, 1]) + bytes(9)
    header = struct.pack("<16sHHIQQQIHHHHHH", ident, 3, machine, 1, 0, 64, 0, 0, 64, 56, len(types), 0, 0, 0)
    tables = b"".join(struct.pack("<IIQQQQQQ", kind, 5, 0, 0, 0, 0, 0, 0) for kind in types)
    return header + tables + f"static helper for machine {machine}".encode()


def macho(cpu=pin.CPU_TYPE_ARM64, magic=pin.MH_MAGIC_64):
    return struct.pack("<IiiIIIII", magic, cpu, 0, 2, 0, 0, 0, 0) + f"thin helper for {cpu:#x}".encode()


def fat_macho():
    return struct.pack(">II", 0xCAFEBABE, 2) + bytes(40)


def good_binaries():
    return {
        "fermix-iroh-macos-aarch64": macho(pin.CPU_TYPE_ARM64),
        "fermix-iroh-macos-x86_64": macho(pin.CPU_TYPE_X86_64),
        "fermix-iroh-linux-aarch64": elf(pin.EM_AARCH64),
        "fermix-iroh-linux-x86_64": elf(pin.EM_X86_64),
    }


def sha(data):
    return hashlib.sha256(data).hexdigest()


class FakeRelease:
    """The release's files by URL, with each sidecar and SHA256SUMS written honestly
    unless a test overrides one."""

    def __init__(self, binaries=None, *, sidecars=None, sums=None):
        self.binaries = binaries or good_binaries()
        self.sidecars = sidecars or {}
        self.sums = sums or {}
        self.fetched = []

    def files(self):
        files, lines = {}, []
        for asset, data in sorted(self.binaries.items()):
            digest = self.sidecars.get(asset, sha(data))
            files[asset] = data
            files[f"{asset}.sha256"] = f"{digest}  {asset}\n".encode()
            files[f"{asset}.sig"] = b"signature"
            files[f"{asset}.pem"] = b"certificate"
            lines.append(f"{self.sums.get(asset, sha(data))}  {asset}")
        files["SHA256SUMS"] = ("\n".join(lines) + "\n").encode()
        return files

    def fetch(self, url):
        self.fetched.append(url)
        prefix = f"https://github.com/tezra-io/fermix-iroh/releases/download/{TAG}/"
        name = url.removeprefix(prefix)
        files = self.files()
        if not url.startswith(prefix) or name not in files:
            raise pin.PinError(f"{url} answered HTTP 404")
        return files[name]


class FakeRunner:
    """cosign answers `cosign_exit`; the helper prints `hello` and exits `helper_exit`,
    and under `--version` prints `version` and exits `version_exit`."""

    def __init__(self, *, cosign_exit=0, hello=HELLO, helper_exit=0, version=VERSION_LINE, version_exit=0):
        self.cosign_exit = cosign_exit
        self.hello = hello
        self.helper_exit = helper_exit
        self.version = version
        self.version_exit = version_exit
        self.cosign_calls = []
        self.helper_calls = []
        self.paths_seen = []

    def __call__(self, command, **kwargs):
        if command[0] == "/fake/bin/cosign":
            self.cosign_calls.append(command)
            self.paths_seen.append(Path(command[-1]))
            stderr = "" if self.cosign_exit == 0 else "error: none of the expected identities matched"
            return subprocess.CompletedProcess(command, self.cosign_exit, "", stderr)
        self.helper_calls.append((command, kwargs))
        self.paths_seen.append(Path(command[0]))
        if command[1:] == ["--version"]:
            stderr = b"" if self.version_exit == 0 else b"error: unexpected argument"
            return subprocess.CompletedProcess(command, self.version_exit, self.version, stderr)
        return subprocess.CompletedProcess(command, self.helper_exit, self.hello, b"")


def with_cosign(name):
    return "/fake/bin/cosign" if name == "cosign" else None


def without_cosign(_name):
    return None


def expected_pin_text(binaries=None):
    digests = {asset: sha(data) for asset, data in (binaries or good_binaries()).items()}
    return f"""{{
  "schema_version": 1,
  "repository": "tezra-io/fermix-iroh",
  "tag": "v0.1.0",
  "version": "0.1.0",
  "protocol_version": 1,
  "iroh_version": "1.3.0",
  "certificate_identity": "{IDENTITY}",
  "certificate_oidc_issuer": "{ISSUER}",
  "macos_team_id": "54A57TH9BJ",
  "targets": {{
    "macos_aarch64": {{
      "asset": "fermix-iroh-macos-aarch64",
      "sha256": "{digests['fermix-iroh-macos-aarch64']}"
    }},
    "macos_x86_64": {{
      "asset": "fermix-iroh-macos-x86_64",
      "sha256": "{digests['fermix-iroh-macos-x86_64']}"
    }},
    "linux_aarch64": {{
      "asset": "fermix-iroh-linux-aarch64",
      "sha256": "{digests['fermix-iroh-linux-aarch64']}"
    }},
    "linux_x86_64": {{
      "asset": "fermix-iroh-linux-x86_64",
      "sha256": "{digests['fermix-iroh-linux-x86_64']}"
    }}
  }}
}}
"""


class PureHelpersTest(unittest.TestCase):
    def test_a_tag_is_vmajor_minor_patch_and_nothing_else(self):
        self.assertEqual(pin.version_of("v0.1.0"), "0.1.0")
        for tag in ("0.1.0", "v0.1", "v0.1.0-rc1", "", None):
            with self.subTest(tag=tag), self.assertRaisesRegex(pin.PinError, "is not a release tag"):
                pin.version_of(tag)

    def test_the_identity_is_the_tags_release_workflow(self):
        self.assertEqual(pin.certificate_identity(TAG), IDENTITY)

    def test_sha256sums_refuses_a_malformed_or_duplicate_line(self):
        digest = "a" * 64
        self.assertEqual(pin.parse_sha256sums(f"{digest}  one\n{digest}  two\n"), {"one": digest, "two": digest})
        with self.assertRaisesRegex(pin.PinError, "line 1 is not"):
            pin.parse_sha256sums("not-a-digest  one\n")
        with self.assertRaisesRegex(pin.PinError, "names one twice"):
            pin.parse_sha256sums(f"{digest}  one\n{digest}  one\n")

    def test_a_sidecar_must_name_its_own_asset(self):
        digest = "b" * 64
        self.assertEqual(pin.parse_sidecar(f"{digest}  fermix-iroh-linux-x86_64\n", "fermix-iroh-linux-x86_64"), digest)
        with self.assertRaisesRegex(pin.PinError, "is not one"):
            pin.parse_sidecar(f"{digest}  fermix-iroh-linux-aarch64\n", "fermix-iroh-linux-x86_64")

    def test_a_static_elf_for_the_target_machine_passes(self):
        pin.check_elf("helper", elf(pin.EM_AARCH64), pin.EM_AARCH64)

    def test_an_elf_with_pt_interp_is_refused(self):
        with self.assertRaisesRegex(pin.PinError, "PT_INTERP program header, so it is dynamically linked"):
            pin.check_elf("helper", elf(pin.EM_X86_64, interp=True), pin.EM_X86_64)

    def test_an_elf_for_another_machine_is_refused(self):
        with self.assertRaisesRegex(pin.PinError, "machine 183, and its target needs machine 62"):
            pin.check_elf("helper", elf(pin.EM_AARCH64), pin.EM_X86_64)

    def test_a_32_bit_or_non_elf_file_is_refused(self):
        with self.assertRaisesRegex(pin.PinError, "not a 64-bit little-endian ELF"):
            pin.check_elf("helper", elf(elf_class=1), pin.EM_X86_64)
        with self.assertRaisesRegex(pin.PinError, "is not an ELF file"):
            pin.check_elf("helper", macho(), pin.EM_X86_64)

    def test_an_elf_whose_program_headers_run_past_the_file_is_refused(self):
        with self.assertRaisesRegex(pin.PinError, "truncated"):
            pin.check_elf("helper", elf()[:70], pin.EM_X86_64)

    def test_a_thin_mach_o_for_the_target_cpu_passes(self):
        pin.check_macho("helper", macho(pin.CPU_TYPE_X86_64), pin.CPU_TYPE_X86_64)

    def test_a_fat_mach_o_is_refused(self):
        with self.assertRaisesRegex(pin.PinError, "fat \\(universal\\) Mach-O"):
            pin.check_macho("helper", fat_macho(), pin.CPU_TYPE_ARM64)

    def test_a_mach_o_for_another_cpu_or_a_32_bit_one_is_refused(self):
        with self.assertRaisesRegex(pin.PinError, "CPU 0x01000007, and its target needs 0x0100000c"):
            pin.check_macho("helper", macho(pin.CPU_TYPE_X86_64), pin.CPU_TYPE_ARM64)
        with self.assertRaisesRegex(pin.PinError, "32-bit Mach-O"):
            pin.check_macho("helper", macho(magic=pin.MH_MAGIC), pin.CPU_TYPE_ARM64)
        with self.assertRaisesRegex(pin.PinError, "not a Mach-O file"):
            pin.check_macho("helper", elf(), pin.CPU_TYPE_ARM64)

    def test_hello_gives_the_three_versions(self):
        self.assertEqual(
            pin.parse_hello("helper", HELLO + b'{"event":"log"}\n', "0.1.0"),
            {"protocol_version": 1, "helper_version": "0.1.0", "iroh_version": "1.3.0"},
        )

    def test_hello_refuses_a_helper_version_that_is_not_the_tag(self):
        with self.assertRaisesRegex(pin.PinError, "helper_version '0.0.9', and the tag is v0.1.0"):
            pin.parse_hello("helper", HELLO.replace(b"0.1.0", b"0.0.9"), "0.1.0")

    def test_hello_refuses_anything_that_is_not_a_hello(self):
        for stdout, reason in (
            (b"fermix-iroh 0.1.0\n", "not JSON"),
            (b'{"event":"ready"}\n', "not a hello event"),
            (HELLO.replace(b'"protocol_version":1', b'"protocol_version":true'), "not an integer"),
            (HELLO.replace(b'"iroh_version":"1.3.0"', b'"iroh_version":""'), "not a version"),
        ):
            with self.subTest(reason=reason), self.assertRaisesRegex(pin.PinError, reason):
                pin.parse_hello("helper", stdout, "0.1.0")

    def test_an_unreleased_host_is_refused(self):
        self.assertEqual(pin.host_target("Darwin", "arm64"), "macos_aarch64")
        with self.assertRaisesRegex(pin.PinError, "this host is FreeBSD amd64"):
            pin.host_target("FreeBSD", "amd64")

    def test_differences_name_every_changed_missing_and_extra_field(self):
        expected = {"tag": "v0.1.0", "targets": {"a": {"sha256": "1"}, "b": {"sha256": "2"}}}
        actual = {"tag": "v0.2.0", "targets": {"a": {"sha256": "1"}}, "extra": True}
        self.assertEqual(
            pin.pin_differences(expected, actual),
            [
                "tag: the pin has 'v0.2.0', the release gives 'v0.1.0'",
                "targets.b.sha256: missing from the pin",
                "extra: the pin has True, which the release does not give",
            ],
        )


class PinTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-iroh-pin-test-")
        self.addCleanup(self.tmp.cleanup)
        self.pin_path = Path(self.tmp.name) / "PIN.json"
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()

    def run_main(self, argv, release, runner, which=with_cosign, host=LINUX_HOST):
        with contextlib.redirect_stdout(self.stdout), contextlib.redirect_stderr(self.stderr):
            return pin.main(
                [*argv, "--pin", str(self.pin_path)], fetch=release.fetch, runner=runner, which=which, host=host
            )

    def make(self, release=None, runner=None, **kwargs):
        return self.run_main(["--tag", TAG], release or FakeRelease(), runner or FakeRunner(), **kwargs)

    def assert_refused(self, code, message):
        self.assertEqual(code, 1)
        self.assertIn(message, self.stderr.getvalue())
        self.assertFalse(self.pin_path.exists(), "a refused run must write no pin")


class MakePinTest(PinTestCase):
    def test_writes_the_pin_in_its_exact_shape_and_prints_the_digests(self):
        self.assertEqual(self.make(), 0, self.stderr.getvalue())
        self.assertEqual(self.pin_path.read_text(encoding="utf-8"), expected_pin_text())
        for asset, data in good_binaries().items():
            self.assertIn(f"{sha(data)}  ", self.stdout.getvalue())
            self.assertIn(asset, self.stdout.getvalue())

    def test_cosign_checks_every_binary_against_the_tags_identity_and_issuer(self):
        runner = FakeRunner()
        self.assertEqual(self.make(runner=runner), 0, self.stderr.getvalue())
        self.assertEqual(len(runner.cosign_calls), 4)
        for command in runner.cosign_calls:
            binary = command[-1]
            self.assertEqual(
                command,
                [
                    "/fake/bin/cosign", "verify-blob",
                    "--certificate", f"{binary}.pem",
                    "--signature", f"{binary}.sig",
                    "--certificate-identity", IDENTITY,
                    "--certificate-oidc-issuer", ISSUER,
                    binary,
                ],
            )
        self.assertEqual(
            sorted(Path(command[-1]).name for command in runner.cosign_calls), sorted(good_binaries())
        )

    # Twice: bare for the hello, then `--version` for the line the release
    # verifiers hold every tree's helper to.
    def test_runs_only_the_hosts_own_binary_with_stdin_closed_and_an_empty_environment(self):
        runner = FakeRunner()
        self.assertEqual(self.make(runner=runner, host=("Darwin", "arm64")), 0, self.stderr.getvalue())
        [(hello, hello_kwargs), (version, version_kwargs)] = runner.helper_calls
        self.assertEqual(Path(hello[0]).name, "fermix-iroh-macos-aarch64")
        self.assertEqual(hello[1:], [])
        self.assertEqual(version, [hello[0], "--version"])
        for kwargs in (hello_kwargs, version_kwargs):
            self.assertIs(kwargs["stdin"], subprocess.DEVNULL)
            self.assertEqual(kwargs["env"], {})
            self.assertEqual(kwargs["timeout"], pin.HELLO_TIMEOUT_SECONDS)

    def test_downloads_live_in_a_temporary_directory_removed_on_success_and_on_failure(self):
        for runner in (FakeRunner(), FakeRunner(hello=HELLO.replace(b"0.1.0", b"0.0.9"))):
            with self.subTest(helper_exit=runner.hello):
                self.make(runner=runner)
                self.assertTrue(runner.paths_seen)
                for path in runner.paths_seen:
                    self.assertFalse(path.parent.exists(), f"{path.parent} outlived the run")

    def test_refuses_a_sidecar_that_disagrees_with_the_binary(self):
        release = FakeRelease(sidecars={"fermix-iroh-linux-aarch64": "0" * 64})
        self.assert_refused(self.make(release), "fermix-iroh-linux-aarch64: the binary hashes to")

    def test_refuses_a_sha256sums_line_that_disagrees_with_the_binary(self):
        release = FakeRelease(sums={"fermix-iroh-macos-x86_64": "f" * 64})
        self.assert_refused(self.make(release), f"and SHA256SUMS says {'f' * 64}")

    def test_refuses_a_signature_cosign_refuses(self):
        self.assert_refused(
            self.make(runner=FakeRunner(cosign_exit=1)),
            f"fermix-iroh-macos-aarch64: cosign refused the signature for {IDENTITY}",
        )

    def test_refuses_without_cosign_before_downloading_anything(self):
        release = FakeRelease()
        self.assert_refused(self.make(release, which=without_cosign), "cosign is not on PATH")
        self.assertEqual(release.fetched, [])

    def test_refuses_an_unreleased_host_before_downloading_anything(self):
        release = FakeRelease()
        self.assert_refused(self.make(release, host=("Linux", "riscv64")), "this host is Linux riscv64")
        self.assertEqual(release.fetched, [])

    def test_refuses_a_dynamically_linked_linux_helper(self):
        binaries = {**good_binaries(), "fermix-iroh-linux-x86_64": elf(pin.EM_X86_64, interp=True)}
        self.assert_refused(self.make(FakeRelease(binaries)), "fermix-iroh-linux-x86_64 has a PT_INTERP")

    def test_refuses_a_fat_macos_helper(self):
        binaries = {**good_binaries(), "fermix-iroh-macos-x86_64": fat_macho()}
        self.assert_refused(self.make(FakeRelease(binaries)), "fermix-iroh-macos-x86_64 is a fat (universal)")

    def test_refuses_a_helper_built_for_another_cpu(self):
        for asset, data, message in (
            ("fermix-iroh-macos-aarch64", macho(pin.CPU_TYPE_X86_64), "is a Mach-O for CPU 0x01000007"),
            ("fermix-iroh-linux-aarch64", elf(pin.EM_X86_64), "is an ELF for machine 62"),
        ):
            with self.subTest(asset=asset):
                self.stderr = io.StringIO()
                self.assert_refused(self.make(FakeRelease({**good_binaries(), asset: data})), f"{asset} {message}")

    def test_refuses_a_helper_whose_hello_is_not_the_tag(self):
        runner = FakeRunner(hello=HELLO.replace(b"0.1.0", b"0.1.1"))
        self.assert_refused(self.make(runner=runner), "helper_version '0.1.1', and the tag is v0.1.0")

    def test_refuses_a_helper_that_does_not_exit_cleanly_at_end_of_stdin(self):
        self.assert_refused(self.make(runner=FakeRunner(helper_exit=101)), "exited 101 at end of stdin")

    # The release verifiers require this exact line from every tree's helper,
    # so a build whose `--version` drifted from its hello is refused here, not
    # on every release's verifier.
    def test_refuses_a_helper_whose_version_line_is_not_the_one_the_verifiers_require(self):
        for printed in (
            b"fermix-iroh 0.1.0 (iroh 1.2.0)\n",
            b"fermix-iroh 0.1.1 (iroh 1.3.0)\n",
            b"fermix-iroh 0.1.0\n",
            b"fermix-iroh 0.1.0 (iroh 1.3.0)",
            b"fermix-iroh 0.1.0 (iroh 1.3.0)\nbuilt from a dirty tree\n",
        ):
            with self.subTest(printed=printed):
                self.stderr = io.StringIO()
                self.assert_refused(
                    self.make(runner=FakeRunner(version=printed)),
                    f"fermix-iroh-linux-x86_64 --version printed {printed.decode()!r}, and the release "
                    f"verifiers require exactly {VERSION_LINE.decode()!r}",
                )

    def test_refuses_a_helper_whose_version_command_fails(self):
        self.assert_refused(
            self.make(runner=FakeRunner(version=b"", version_exit=2)),
            "fermix-iroh-linux-x86_64 --version exited 2: error: unexpected argument",
        )

    def test_a_pin_path_that_cannot_be_written_is_a_sentence_not_a_traceback(self):
        self.pin_path = Path(self.tmp.name) / "missing-directory" / "PIN.json"
        self.assert_refused(self.make(), "No such file or directory")

    def test_a_refused_run_leaves_an_existing_pin_untouched(self):
        self.pin_path.write_text("the previous pin\n", encoding="utf-8")
        self.assertEqual(self.make(runner=FakeRunner(cosign_exit=1)), 1)
        self.assertEqual(self.pin_path.read_text(encoding="utf-8"), "the previous pin\n")


class CheckPinTest(PinTestCase):
    def check(self, release=None, runner=None, **kwargs):
        self.stdout, self.stderr = io.StringIO(), io.StringIO()
        return self.run_main(["--check"], release or FakeRelease(), runner or FakeRunner(), **kwargs)

    def write_pin(self, text):
        self.pin_path.write_text(text, encoding="utf-8")
        return self.pin_path.stat().st_mtime_ns

    def test_passes_on_the_pin_its_release_gives_and_changes_nothing(self):
        mtime = self.write_pin(expected_pin_text())
        runner = FakeRunner()
        self.assertEqual(self.check(runner=runner), 0, self.stderr.getvalue())
        self.assertEqual(self.pin_path.read_text(encoding="utf-8"), expected_pin_text())
        self.assertEqual(self.pin_path.stat().st_mtime_ns, mtime)
        self.assertEqual(len(runner.cosign_calls), 4)
        self.assertEqual(runner.helper_calls, [], "--check does not run the helper")

    def test_fails_on_a_changed_digest_and_names_it(self):
        good = sha(good_binaries()["fermix-iroh-linux-x86_64"])
        self.write_pin(expected_pin_text().replace(good, "e" * 64))
        self.assertEqual(self.check(), 1)
        self.assertIn(
            f"targets.linux_x86_64.sha256: the pin has '{'e' * 64}', the release gives '{good}'",
            self.stderr.getvalue(),
        )
        self.assertIn("e" * 64, self.pin_path.read_text(encoding="utf-8"), "--check must change nothing")

    def test_names_every_difference_not_only_the_first(self):
        text = expected_pin_text().replace('"macos_team_id": "54A57TH9BJ"', '"macos_team_id": "AAAAAAAAAA"')
        text = text.replace('"version": "0.1.0"', '"version": "0.1.1"')
        self.write_pin(text)
        self.assertEqual(self.check(), 1)
        self.assertIn("version: the pin has '0.1.1', the release gives '0.1.0'", self.stderr.getvalue())
        self.assertIn("macos_team_id: the pin has 'AAAAAAAAAA'", self.stderr.getvalue())

    def test_fails_on_a_release_whose_bytes_its_signatures_do_not_cover(self):
        self.write_pin(expected_pin_text())
        self.assertEqual(self.check(runner=FakeRunner(cosign_exit=1)), 1)
        self.assertIn("cosign refused the signature", self.stderr.getvalue())

    def test_fails_on_a_pin_that_is_not_in_the_written_form(self):
        self.write_pin(json.dumps(json.loads(expected_pin_text()), indent=4) + "\n")
        self.assertEqual(self.check(), 1)
        self.assertIn("is not in the form this script writes", self.stderr.getvalue())

    # Every field equal, rendered the way the script renders, in another key
    # order: the written form includes the order, so it is still not that form.
    def test_fails_on_a_pin_whose_keys_are_reordered(self):
        written = json.loads(expected_pin_text())
        for name, reordered in (
            ("top level", {"tag": written["tag"], **{k: v for k, v in written.items() if k != "tag"}}),
            ("targets", {**written, "targets": dict(reversed(list(written["targets"].items())))}),
        ):
            with self.subTest(order=name):
                self.write_pin(json.dumps(reordered, indent=2) + "\n")
                self.assertEqual(pin.pin_differences(written, reordered), [])
                self.assertEqual(self.check(), 1)
                self.assertIn("is not in the form this script writes", self.stderr.getvalue())

    def test_fails_on_a_hello_value_that_is_not_a_value(self):
        self.write_pin(expected_pin_text().replace('"protocol_version": 1', '"protocol_version": "1"'))
        self.assertEqual(self.check(), 1)
        self.assertIn("protocol_version: the pin has '1', not an integer", self.stderr.getvalue())

    def test_refuses_without_cosign(self):
        self.write_pin(expected_pin_text())
        self.assertEqual(self.check(which=without_cosign), 1)
        self.assertIn("cosign is not on PATH", self.stderr.getvalue())

    def test_refuses_a_missing_pin(self):
        self.assertEqual(self.check(), 1)
        self.assertIn("does not exist; make it with --tag", self.stderr.getvalue())


class CheckedInPinTest(unittest.TestCase):
    """The one invariant about the checked-in file itself: it is what the script
    writes, for the targets the script knows. Its bytes are proven by --check."""

    def test_the_checked_in_pin_is_in_the_form_the_script_writes(self):
        text = CHECKED_IN_PIN.read_text(encoding="utf-8")
        checked_in = json.loads(text)
        self.assertEqual(text, pin.render_pin(checked_in))
        self.assertEqual(list(checked_in["targets"]), list(pin.TARGETS))
        rebuilt = pin.build_pin(
            checked_in["tag"],
            checked_in["protocol_version"],
            checked_in["iroh_version"],
            {target: entry["sha256"] for target, entry in checked_in["targets"].items()},
        )
        self.assertEqual(pin.pin_differences(rebuilt, checked_in), [])


if __name__ == "__main__":
    unittest.main()
