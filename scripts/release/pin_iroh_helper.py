#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Pin the `fermix-iroh` helper release the engine's release trees carry (M62 stage 5 §2).

`apps/fermix_core/priv/iroh_helper/PIN.json` is DERIVED state: this script is
the only thing that writes it, never a hand edit. Every value in it is proven
before it is written:

1. `SHA256SUMS`, and for each bare binary the binary, `.sha256`, `.sig` and
   `.pem`, are downloaded from the release, and the binary's own digest, its
   sidecar and its `SHA256SUMS` line must agree;
2. `cosign verify-blob` checks each binary against the tag's release workflow
   identity and the GitHub OIDC issuer (no cosign on PATH is a refusal);
3. each binary's header must be the shape the trees depend on: Linux is a
   64-bit ELF for the target's machine with no `PT_INTERP` (static), macOS is a
   thin 64-bit Mach-O for exactly the target's CPU;
4. the host's own target binary runs with stdin closed and an empty
   environment, and its `hello` line gives `helper_version` (must equal the
   tag), `protocol_version` and `iroh_version`; run again with `--version`, it
   must print exactly `fermix-iroh <version> (iroh <iroh_version>)` and a
   newline, the line every release verifier holds a tree's helper to;
5. the pin is written and the digests printed.

`--check` repeats steps 1 to 3 against the checked-in pin, changes nothing, and
exits non-zero naming every difference. The release preflight runs it, so no
tag ships a pin whose bytes its signatures do not cover.

Usage:
  pin_iroh_helper.py --tag vX.Y.Z [--pin PATH]
  pin_iroh_helper.py --check [--pin PATH]

Every download goes through `fetch` and every subprocess through `runner`, so
the whole flow is reachable from a test with no network and no cosign.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

SCHEMA_VERSION = 1
REPOSITORY = "tezra-io/fermix-iroh"
RELEASE_WORKFLOW = ".github/workflows/release.yml"
OIDC_ISSUER = "https://token.actions.githubusercontent.com"
MACOS_TEAM_ID = "54A57TH9BJ"
PIN_PATH = Path(__file__).resolve().parents[2] / "apps/fermix_core/priv/iroh_helper/PIN.json"
TAG_RE = re.compile(r"^v(?P<version>\d+\.\d+\.\d+)$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

# The protocol gives the helper 10 s to say hello and 5 s to exit after a
# shutdown, which end of stdin is; past both it is not a helper that works.
# `--version` runs under the same bound.
HELLO_TIMEOUT_SECONDS = 15
DOWNLOAD_TIMEOUT_SECONDS = 120

ELF_MAGIC = b"\x7fELF"
ELF_CLASS_64 = 2
ELF_DATA_LSB = 1
ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
ELF_PROGRAM_HEADER = struct.Struct("<IIQQQQQQ")
PT_INTERP = 3
PN_XNUM = 0xFFFF
EM_X86_64 = 62
EM_AARCH64 = 183

MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC = 0xFEEDFACE
FAT_MAGICS = (0xCAFEBABE, 0xCAFEBABF)
CPU_TYPE_X86_64 = 0x01000007
CPU_TYPE_ARM64 = 0x0100000C

# Target keys are the Burrito target aliases the release already uses; the
# order here is the order PIN.json lists them in.
TARGETS = {
    "macos_aarch64": {"asset": "fermix-iroh-macos-aarch64", "format": "macho", "cpu": CPU_TYPE_ARM64},
    "macos_x86_64": {"asset": "fermix-iroh-macos-x86_64", "format": "macho", "cpu": CPU_TYPE_X86_64},
    "linux_aarch64": {"asset": "fermix-iroh-linux-aarch64", "format": "elf", "cpu": EM_AARCH64},
    "linux_x86_64": {"asset": "fermix-iroh-linux-x86_64", "format": "elf", "cpu": EM_X86_64},
}

HOST_TARGETS = {
    ("Darwin", "arm64"): "macos_aarch64",
    ("Darwin", "x86_64"): "macos_x86_64",
    ("Linux", "aarch64"): "linux_aarch64",
    ("Linux", "arm64"): "linux_aarch64",
    ("Linux", "x86_64"): "linux_x86_64",
}

SIDECARS = (".sha256", ".sig", ".pem")


class PinError(Exception):
    """The pin cannot be made or checked; the message names the target and the stage."""


# ── pure helpers (no network, no subprocess, no filesystem) ─────────────────


def version_of(tag: str) -> str:
    """`0.1.0` for `v0.1.0`; anything else is refused."""

    match = TAG_RE.match(tag or "")
    if match is None:
        raise PinError(f"tag {tag!r} is not a release tag of the form vMAJOR.MINOR.PATCH")
    return match["version"]


def certificate_identity(tag: str) -> str:
    return f"https://github.com/{REPOSITORY}/{RELEASE_WORKFLOW}@refs/tags/{tag}"


def release_url(tag: str, name: str) -> str:
    return f"https://github.com/{REPOSITORY}/releases/download/{tag}/{name}"


def host_target(system: str, machine: str) -> str:
    target = HOST_TARGETS.get((system, machine))
    if target is None:
        raise PinError(
            f"this host is {system} {machine}, and the helper is released for "
            f"{', '.join(TARGETS)}; make the pin on one of those"
        )
    return target


def parse_sha256sums(text: str) -> dict[str, str]:
    """{asset name: digest} from a `SHA256SUMS` body of `<digest>  <name>` lines."""

    sums: dict[str, str] = {}
    for number, line in enumerate(text.splitlines(), start=1):
        fields = line.split()
        if len(fields) != 2 or not SHA256_RE.match(fields[0]):
            raise PinError(f"SHA256SUMS line {number} is not `<sha256>  <name>`: {line!r}")
        digest, name = fields
        if name in sums:
            raise PinError(f"SHA256SUMS names {name} twice")
        sums[name] = digest
    return sums


def parse_sidecar(text: str, asset: str) -> str:
    """The digest a `<asset>.sha256` sidecar pins: one `<digest>  <asset>` line."""

    lines = text.splitlines()
    fields = lines[0].split() if len(lines) == 1 else []
    if len(fields) != 2 or not SHA256_RE.match(fields[0]) or fields[1] != asset:
        raise PinError(f"{asset}.sha256 is not one `<sha256>  {asset}` line: {text!r}")
    return fields[0]


def agree_digests(asset: str, actual: str, sidecar: str, sums: dict[str, str]) -> str:
    listed = sums.get(asset)
    if listed is None:
        raise PinError(f"SHA256SUMS does not list {asset}")
    if not actual == sidecar == listed:
        raise PinError(
            f"{asset}: the binary hashes to {actual}, its .sha256 says {sidecar} "
            f"and SHA256SUMS says {listed}; the three must agree"
        )
    return actual


def check_elf(asset: str, data: bytes, machine: int) -> None:
    """A 64-bit little-endian ELF for `machine` with no `PT_INTERP` program header."""

    if len(data) < ELF_HEADER.size or data[:4] != ELF_MAGIC:
        raise PinError(f"{asset} is not an ELF file")
    ident, _, e_machine, _, _, phoff, _, _, _, phentsize, phnum, _, _, _ = ELF_HEADER.unpack_from(data)
    if ident[4] != ELF_CLASS_64 or ident[5] != ELF_DATA_LSB:
        raise PinError(f"{asset} is not a 64-bit little-endian ELF (class {ident[4]}, data {ident[5]})")
    if e_machine != machine:
        raise PinError(f"{asset} is an ELF for machine {e_machine}, and its target needs machine {machine}")
    if phentsize != ELF_PROGRAM_HEADER.size or phnum in (0, PN_XNUM):
        raise PinError(f"{asset} has a program header table this check cannot read ({phnum} of {phentsize} bytes)")
    if phoff + phnum * phentsize > len(data):
        raise PinError(f"{asset} is truncated: its program header table ends past the file")
    for index in range(phnum):
        (p_type, *_rest) = ELF_PROGRAM_HEADER.unpack_from(data, phoff + index * phentsize)
        if p_type == PT_INTERP:
            raise PinError(
                f"{asset} has a PT_INTERP program header, so it is dynamically linked; "
                "the trees carry only a static helper"
            )


def check_macho(asset: str, data: bytes, cpu: int) -> None:
    """A thin 64-bit Mach-O for exactly `cpu`; a fat (universal) file is refused."""

    if len(data) < 8:
        raise PinError(f"{asset} is not a Mach-O file")
    (big_endian_magic,) = struct.unpack_from(">I", data)
    magic, cputype = struct.unpack_from("<Ii", data)
    if big_endian_magic in FAT_MAGICS:
        raise PinError(f"{asset} is a fat (universal) Mach-O; the trees carry one thin binary per target")
    if magic == MH_MAGIC:
        raise PinError(f"{asset} is a 32-bit Mach-O")
    if magic != MH_MAGIC_64:
        raise PinError(f"{asset} is not a Mach-O file")
    if cputype != cpu:
        raise PinError(f"{asset} is a Mach-O for CPU {cputype:#010x}, and its target needs {cpu:#010x}")


def check_shape(target: str, data: bytes) -> None:
    spec = TARGETS[target]
    if spec["format"] == "elf":
        check_elf(spec["asset"], data, spec["cpu"])
    else:
        check_macho(spec["asset"], data, spec["cpu"])


def parse_hello(asset: str, stdout: bytes, version: str) -> dict:
    """`protocol_version`, `helper_version` and `iroh_version` from the helper's first line."""

    try:
        first = stdout.decode("utf-8").split("\n", 1)[0]
        hello = json.loads(first)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise PinError(f"{asset}'s first stdout line is not JSON: {stdout[:200]!r}") from None
    if not isinstance(hello, dict) or hello.get("event") != "hello":
        raise PinError(f"{asset}'s first stdout line is not a hello event: {first!r}")
    protocol, helper, iroh = (hello.get(k) for k in ("protocol_version", "helper_version", "iroh_version"))
    if not isinstance(protocol, int) or isinstance(protocol, bool):
        raise PinError(f"{asset}'s hello carries protocol_version {protocol!r}, not an integer")
    if not isinstance(iroh, str) or not iroh:
        raise PinError(f"{asset}'s hello carries iroh_version {iroh!r}, not a version")
    if helper != version:
        raise PinError(f"{asset}'s hello reports helper_version {helper!r}, and the tag is v{version}")
    return {"protocol_version": protocol, "helper_version": helper, "iroh_version": iroh}


def build_pin(tag: str, protocol_version, iroh_version, digests: dict[str, str]) -> dict:
    """PIN.json in its one key order; `digests` is {target: sha256}."""

    return {
        "schema_version": SCHEMA_VERSION,
        "repository": REPOSITORY,
        "tag": tag,
        "version": version_of(tag),
        "protocol_version": protocol_version,
        "iroh_version": iroh_version,
        "certificate_identity": certificate_identity(tag),
        "certificate_oidc_issuer": OIDC_ISSUER,
        "macos_team_id": MACOS_TEAM_ID,
        "targets": {
            target: {"asset": spec["asset"], "sha256": digests[target]} for target, spec in TARGETS.items()
        },
    }


def render_pin(pin: dict) -> str:
    return json.dumps(pin, indent=2) + "\n"


def pin_differences(expected: dict, actual: dict) -> list[str]:
    """One sentence per field where the checked-in pin differs from the release."""

    want, have = _flatten(expected), _flatten(actual)
    differences = []
    for key in list(want) + [k for k in have if k not in want]:
        if key not in have:
            differences.append(f"{key}: missing from the pin")
        elif key not in want:
            differences.append(f"{key}: the pin has {have[key]!r}, which the release does not give")
        elif want[key] != have[key] or type(want[key]) is not type(have[key]):
            differences.append(f"{key}: the pin has {have[key]!r}, the release gives {want[key]!r}")
    return differences


def hello_field_problems(pin: dict) -> list[str]:
    """`--check` does not re-run the hello, so the two values it gave must at least be values."""

    problems = []
    protocol, iroh = pin.get("protocol_version"), pin.get("iroh_version")
    if "protocol_version" in pin and (not isinstance(protocol, int) or isinstance(protocol, bool)):
        problems.append(f"protocol_version: the pin has {protocol!r}, not an integer")
    if "iroh_version" in pin and (not isinstance(iroh, str) or not iroh):
        problems.append(f"iroh_version: the pin has {iroh!r}, not a version")
    return problems


def _flatten(value, prefix: str = "") -> dict:
    if not isinstance(value, dict):
        return {prefix: value}
    flat = {}
    for key, inner in value.items():
        flat.update(_flatten(inner, f"{prefix}.{key}" if prefix else key))
    return flat


# ── effectful (network, cosign, the helper, the filesystem) ─────────────────


def http_get(url: str) -> bytes:
    try:
        with urllib.request.urlopen(url, timeout=DOWNLOAD_TIMEOUT_SECONDS) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise PinError(f"{url} answered HTTP {error.code}") from None
    except urllib.error.URLError as error:
        raise PinError(f"{url} could not be fetched: {error.reason}") from None


def resolve_cosign(which) -> str:
    cosign = which("cosign")
    if cosign is None:
        raise PinError("cosign is not on PATH; a pin is only made from signatures cosign has verified")
    return cosign


def download(tag: str, name: str, workdir: Path, fetch) -> Path:
    path = workdir / name
    path.write_bytes(fetch(release_url(tag, name)))
    return path


def cosign_verify(cosign: str, tag: str, binary: Path, runner) -> None:
    command = [
        cosign, "verify-blob",
        "--certificate", f"{binary}.pem",
        "--signature", f"{binary}.sig",
        "--certificate-identity", certificate_identity(tag),
        "--certificate-oidc-issuer", OIDC_ISSUER,
        str(binary),
    ]
    result = runner(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise PinError(
            f"{binary.name}: cosign refused the signature for {certificate_identity(tag)} "
            f"(exit {result.returncode}): {(result.stderr or '').strip()}"
        )


def verify_target(target: str, tag: str, sums: dict, workdir: Path, *, cosign: str, fetch, runner) -> tuple[Path, str]:
    """Steps 1 to 3 for one target: (the downloaded binary, its agreed digest)."""

    asset = TARGETS[target]["asset"]
    binary = download(tag, asset, workdir, fetch)
    for suffix in SIDECARS:
        download(tag, asset + suffix, workdir, fetch)
    data = binary.read_bytes()
    sidecar = parse_sidecar((workdir / f"{asset}.sha256").read_text(encoding="utf-8"), asset)
    digest = agree_digests(asset, hashlib.sha256(data).hexdigest(), sidecar, sums)
    cosign_verify(cosign, tag, binary, runner)
    check_shape(target, data)
    return binary, digest


def verify_release(tag: str, workdir: Path, *, cosign: str, fetch, runner) -> dict[str, tuple[Path, str]]:
    """{target: (binary, digest)} for every target, each proven by steps 1 to 3."""

    sums = parse_sha256sums(download(tag, "SHA256SUMS", workdir, fetch).read_text(encoding="utf-8"))
    return {
        target: verify_target(target, tag, sums, workdir, cosign=cosign, fetch=fetch, runner=runner)
        for target in TARGETS
    }


def read_hello(binary: Path, version: str, runner) -> dict:
    """Run the helper with stdin closed (end of stdin is a shutdown) and read its hello."""

    binary.chmod(0o755)
    try:
        result = runner(
            [str(binary)],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            env={},
            timeout=HELLO_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise PinError(f"{binary.name} did not exit within {HELLO_TIMEOUT_SECONDS} s of end of stdin") from None
    if result.returncode != 0:
        stderr = (result.stderr or b"").decode("utf-8", "replace").strip()
        raise PinError(f"{binary.name} exited {result.returncode} at end of stdin: {stderr}")
    return parse_hello(binary.name, result.stdout or b"", version)


def read_version_line(binary: Path, version: str, iroh_version: str, runner) -> None:
    """Run `--version` the way the hello ran and require the exact line the release verifiers require."""

    expected = f"fermix-iroh {version} (iroh {iroh_version})\n"
    try:
        result = runner(
            [str(binary), "--version"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            env={},
            timeout=HELLO_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise PinError(f"{binary.name} --version did not exit within {HELLO_TIMEOUT_SECONDS} s") from None
    if result.returncode != 0:
        stderr = (result.stderr or b"").decode("utf-8", "replace").strip()
        raise PinError(f"{binary.name} --version exited {result.returncode}: {stderr}")
    printed = (result.stdout or b"").decode("utf-8", "replace")
    if printed != expected:
        raise PinError(
            f"{binary.name} --version printed {printed!r}, and the release verifiers require exactly {expected!r}"
        )


def write_atomic(path: Path, text: str) -> None:
    """tmp-write and rename in the destination dir, so a failed run never leaves a torn pin."""

    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def make_pin(tag: str, pin_path: Path, *, fetch, runner, which, host) -> dict:
    """`--tag`: prove the release, read the host binary's hello and `--version`, write the pin."""

    version = version_of(tag)
    cosign = resolve_cosign(which)
    own_target = host_target(*host)
    with tempfile.TemporaryDirectory(prefix="fermix-iroh-pin-") as tmp:
        verified = verify_release(tag, Path(tmp), cosign=cosign, fetch=fetch, runner=runner)
        hello = read_hello(verified[own_target][0], version, runner)
        read_version_line(verified[own_target][0], version, hello["iroh_version"], runner)
    digests = {target: digest for target, (_, digest) in verified.items()}
    pin = build_pin(tag, hello["protocol_version"], hello["iroh_version"], digests)
    write_atomic(pin_path, render_pin(pin))
    return pin


def load_pin(pin_path: Path) -> tuple[dict, str]:
    try:
        text = pin_path.read_text(encoding="utf-8")
        pin = json.loads(text)
    except FileNotFoundError:
        raise PinError(f"{pin_path} does not exist; make it with --tag") from None
    except json.JSONDecodeError as error:
        raise PinError(f"{pin_path} is not JSON: {error}") from None
    if not isinstance(pin, dict):
        raise PinError(f"{pin_path} is not a JSON object")
    return pin, text


def check_pin(pin_path: Path, *, fetch, runner, which) -> list[str]:
    """`--check`: every difference between the checked-in pin and the release it names."""

    pin, text = load_pin(pin_path)
    tag = pin.get("tag")
    version_of(tag)
    cosign = resolve_cosign(which)
    with tempfile.TemporaryDirectory(prefix="fermix-iroh-pin-check-") as tmp:
        verified = verify_release(tag, Path(tmp), cosign=cosign, fetch=fetch, runner=runner)
    digests = {target: digest for target, (_, digest) in verified.items()}
    # The hello is not re-run here, so the two values it gave are taken from
    # the pin; the engine's own test holds them to the protocol and relay
    # revision it speaks.
    expected = build_pin(tag, pin.get("protocol_version"), pin.get("iroh_version"), digests)
    differences = pin_differences(expected, pin) + hello_field_problems(pin)
    # Compared with the pin as this script would write it, not as the file's
    # own keys order it, so a hand-reordered pin is not the written form.
    if not differences and text != render_pin(expected):
        differences.append(f"{pin_path.name} is not in the form this script writes; regenerate it with --tag {tag}")
    return differences


def main(argv=None, *, fetch=http_get, runner=subprocess.run, which=shutil.which, host=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--tag", help="the fermix-iroh release tag to pin, vX.Y.Z")
    mode.add_argument("--check", action="store_true", help="verify the checked-in pin; change nothing")
    parser.add_argument("--pin", type=Path, default=PIN_PATH, help="the pin file (default: the checkout's)")
    arguments = parser.parse_args(argv)
    host = host or (platform.system(), platform.machine())
    try:
        if arguments.check:
            return report_check(arguments.pin, check_pin(arguments.pin, fetch=fetch, runner=runner, which=which))
        pin = make_pin(arguments.tag, arguments.pin, fetch=fetch, runner=runner, which=which, host=host)
    except (PinError, OSError) as error:
        print(f"pin_iroh_helper.py: {error}", file=sys.stderr)
        return 1
    for target, entry in pin["targets"].items():
        print(f"{entry['sha256']}  {target}  {entry['asset']}")
    print(f"wrote {arguments.pin} for {REPOSITORY} {pin['tag']}")
    return 0


def report_check(pin_path: Path, differences: list[str]) -> int:
    if differences:
        for difference in differences:
            print(f"pin_iroh_helper.py: {pin_path.name} differs: {difference}", file=sys.stderr)
        return 1
    print(f"{pin_path} matches its release: digests, signatures and shapes verified for {len(TARGETS)} targets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
