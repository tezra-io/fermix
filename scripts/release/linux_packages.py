#!/usr/bin/env python3
"""Stage and build the `fermix` deb and rpm from one Burrito release (M38 §2.2).

The Burrito wrapper is already built when this runs. What is left is the part a
package manager sees: one staging tree with every file at its installed path,
one nFPM configuration rendered from the checked-in template, and one run of
nFPM per format. Both packages therefore come from one file list, which is what
keeps the two families from drifting apart.

Two facts this script refuses to assume:

* **The loader is the loader.** `packaging/linux/out/<target>/libc-musl-<digest>.so`
  is hashed and refused when its bytes are not the digest its name carries. The
  package's configuration step materialises those exact bytes at the address
  every packaged ELF interpreter names.
* **A tool is the tool that was pinned.** nFPM and cosign are downloaded by
  exact version and verified against a pinned sha256 before either is used or
  shipped.

Every download goes through `opener` and every subprocess through `runner`, so
the whole flow is reachable from a test with no network and no nFPM.
"""

from __future__ import annotations

import argparse
import email.utils
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package_app_engine  # noqa: E402

SCHEMA_VERSION = 1
ENGINE_ID = "fermix-core"
DISTRIBUTION_IDENTITY = "linux_package"
MAINTAINER = "Tezra <hello@fermix.ai>"

# target -> (architecture nFPM is told about, the architecture the identity
# reports, the rpm spelling of the same machine)
TARGETS = {
    "linux_x86_64": ("amd64", "x86_64", "x86_64", "amd64"),
    "linux_aarch64": ("arm64", "arm64", "aarch64", "arm64"),
}

# The packager runs on the build host; the verifier ships to the target host.
# Conflating the two is how a cross-built arm64 package acquires an x86_64
# cosign, so they are pinned in separate tables and resolved separately.
NFPM_VERSION = "2.47.0"
NFPM_RELEASES = {
    "x86_64": (
        f"nfpm_{NFPM_VERSION}_Linux_x86_64.tar.gz",
        "0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783",
    ),
    "aarch64": (
        f"nfpm_{NFPM_VERSION}_Linux_arm64.tar.gz",
        "1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c",
    ),
}
NFPM_URL = "https://github.com/goreleaser/nfpm/releases/download/v{version}/{asset}"

COSIGN_VERSION = "3.1.3"
COSIGN_RELEASES = {
    "linux_x86_64": (
        "cosign-linux-amd64",
        "4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71",
    ),
    "linux_aarch64": (
        "cosign-linux-arm64",
        "c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a",
    ),
}
COSIGN_URL = "https://github.com/sigstore/cosign/releases/download/v{version}/{asset}"

LOADER_PATTERN = re.compile(r"^libc-musl-([0-9a-f]{64})\.so$")
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
PLACEHOLDER_PATTERN = re.compile(r"\{\{([A-Z_]+)\}\}")
CHANGELOG_HEADING = re.compile(r"^## \[(?P<version>[^\]]+)\](?: - (?P<date>[0-9-]+))?\s*$")

# The app-engine archive's own names (amendment §5.1).
ARCHIVE_TREE = "tree"
ARCHIVE_MAINTAINER = "maintainer"
NFPM_CONTENTS_NAME = "nfpm-contents.yaml"
NFPM_CONTENTS_HEADER = """\
# The `contents:` block of the `fermix` engine package, resolved.
#
# Every `src:` is relative to the root of this archive, so a build that runs
# nFPM from the unpacked `fermix_app_engine/` directory installs the engine's
# files at the paths and modes the headless `fermix` package installs them at.
# /usr/share/doc/fermix/changelog.Debian.gz is deliberately absent: the
# combined desktop package ships one changelog, its own.
"""

# Installed path -> mode. Every file the package installs at a fixed path is
# here, and staging refuses when one of them is missing, so a file added to the
# nfpm template and not to the tree fails the build rather than shipping a
# package that quietly lacks it. The runtime payload is the one entry whose
# name carries a digest, so it is staged and moded beside this list.
CHANGELOG_PATH = "usr/share/doc/fermix/changelog.Debian.gz"
STAGED_MODES = {
    "usr/bin/fermix": 0o755,
    "usr/lib/fermix/cosign": 0o755,
    "usr/lib/systemd/user/fermix.service": 0o644,
    "usr/share/fermix/engine.json": 0o644,
    "usr/share/bash-completion/completions/fermix": 0o644,
    "usr/share/zsh/site-functions/_fermix": 0o644,
    "usr/share/fish/vendor_completions.d/fermix.fish": 0o644,
    "usr/share/man/man1/fermix.1.gz": 0o644,
    "usr/share/doc/fermix/copyright": 0o644,
    CHANGELOG_PATH: 0o644,
}


class BuildError(RuntimeError):
    """A refusal that names what was wrong, printed without a traceback."""


# ── pure helpers ────────────────────────────────────────────────────────────


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def render_template(template: str, values: dict) -> str:
    """Substitute every {{KEY}}, and refuse a template with one left over."""

    rendered = PLACEHOLDER_PATTERN.sub(
        lambda match: _substitute(match.group(1), values), template
    )
    leftover = PLACEHOLDER_PATTERN.findall(rendered)
    if leftover:
        raise BuildError(f"the nfpm template still carries placeholders: {sorted(leftover)}")
    return rendered


def _substitute(key: str, values: dict) -> str:
    if key not in values:
        raise BuildError(f"the nfpm template asks for {{{{{key}}}}}, which this build does not set")
    return str(values[key])


def engine_manifest(
    *,
    target: str,
    version: str,
    build_id: str,
    source_commit: str,
    loader_sha256: str,
    binary_sha256: str,
) -> dict:
    """The immutable installed identity, published at /usr/share/fermix/engine.json."""

    _, architecture, _, _ = resolve_target(target)
    return {
        "schema_version": SCHEMA_VERSION,
        "engine_id": ENGINE_ID,
        "product_version": version,
        "build_id": build_id,
        "source_commit": source_commit,
        "distribution_identity": DISTRIBUTION_IDENTITY,
        "artifact_target": target,
        "architecture": architecture,
        "loader_sha256": loader_sha256,
        "binary_sha256": binary_sha256,
    }


KEY_LEDGER_NAME = ".engine-payload-keys.json"


def check_payload_key(output_dir: Path, build_id: str, binary_sha256: str) -> None:
    """Refuse when one payload key would name two different payloads.

    The extracted runtime directory is named after the release version, which
    carries the build id, so the build id IS the cache key. Two builds sharing
    it must therefore be the same bytes, or the second one silently inherits
    the first one's extraction -- the defect this keying exists to end.

    For a dev build the id already folds in a digest of the working tree, so
    editing anything moves it. For a release build the id comes from CI, and a
    rebuild of the same tag can produce different bytes, because our builds are
    not yet bit-reproducible. This is the guard that catches that case instead
    of trusting it: a ledger beside the produced packages records what each key
    was last built from, and a key that comes back with different bytes stops
    the build rather than shipping a package that will not unpack.
    """

    ledger_path = output_dir / KEY_LEDGER_NAME
    try:
        ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        ledger = {}
    except (OSError, json.JSONDecodeError) as broken:
        raise BuildError(f"the payload key ledger {ledger_path} is unreadable: {broken}")

    recorded = ledger.get(build_id)
    if recorded is not None and recorded != binary_sha256:
        raise BuildError(
            f"the build id {build_id} already named a different payload "
            f"({recorded[:12]}…, now {binary_sha256[:12]}…): two payloads sharing one key "
            "would share one extracted runtime directory, so the second would never unpack. "
            "Give this build its own id."
        )

    ledger[build_id] = binary_sha256
    output_dir.mkdir(parents=True, exist_ok=True)
    ledger_path.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def resolve_target(target: str):
    if target not in TARGETS:
        raise BuildError(f"unsupported target: {target}")
    return TARGETS[target]


def check_version(version: str) -> str:
    """Neither package may carry a Debian revision or an rpm epoch (M38 §2.2)."""

    if "-" in version or ":" in version:
        raise BuildError(
            f"the version {version} carries a revision or an epoch, and neither package may"
        )
    if not VERSION_PATTERN.match(version):
        raise BuildError(f"the version {version} is not a plain MAJOR.MINOR.PATCH version")
    return version


def debian_changelog(markdown: str, version: str, *, limit: int = 10) -> str:
    """The Debian changelog entries this project's own CHANGELOG.md already has."""

    entries = []
    for released, date, body in _changelog_sections(markdown):
        if released == "Unreleased":
            continue
        entries.append(_changelog_entry(released, date, body))
        if len(entries) >= limit:
            break

    if not entries:
        raise BuildError("CHANGELOG.md carries no released section to render")

    if not entries[0].startswith(f"fermix ({version})"):
        raise BuildError(
            f"CHANGELOG.md's newest released section is not {version}; "
            "release the version you are packaging"
        )

    return "\n".join(entries)


def _changelog_sections(markdown: str):
    current = None
    body: list[str] = []

    for line in markdown.splitlines():
        heading = CHANGELOG_HEADING.match(line)
        if heading:
            if current:
                yield current[0], current[1], body
            current = (heading.group("version"), heading.group("date"))
            body = []
        elif current:
            body.append(line)

    if current:
        yield current[0], current[1], body


def _changelog_entry(version: str, date: str | None, body: list[str]) -> str:
    if not date:
        raise BuildError(f"the released section [{version}] carries no date")

    stamp = email.utils.format_datetime(
        datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    )
    bullets = _bullets(body) or ["See the release notes for this version."]
    wrapped = "\n".join(
        textwrap.fill(bullet, width=76, initial_indent="  * ", subsequent_indent="    ")
        for bullet in bullets
    )

    return (
        f"fermix ({version}) stable; urgency=medium\n\n"
        f"{wrapped}\n\n"
        f" -- {MAINTAINER}  {stamp}\n"
    )


def _bullets(body: list[str]) -> list[str]:
    """One Markdown bullet, its continuation lines folded back into it."""

    bullets: list[str] = []

    for line in body:
        text = line.strip().replace("**", "")
        if line.startswith("- "):
            bullets.append(text[2:])
        elif bullets and text and line.startswith("  "):
            bullets[-1] += " " + text

    return bullets


def loader_in(directory: Path) -> tuple[Path, str]:
    """The one verified loader this target's release published."""

    candidates = sorted(p for p in directory.glob("libc-musl-*.so") if p.is_file())
    if len(candidates) != 1:
        raise BuildError(
            f"expected exactly one loader in {directory}, found {len(candidates)}; "
            "rebuild the release so its fetch step publishes one"
        )

    loader = candidates[0]
    match = LOADER_PATTERN.match(loader.name)
    if not match:
        raise BuildError(f"{loader} does not name a sha256 digest")

    digest = sha256_file(loader)
    if digest != match.group(1):
        raise BuildError(f"{loader} has digest {digest} and is named {match.group(1)}")

    return loader, digest


def gzip_bytes(data: bytes) -> bytes:
    """Deterministic gzip: no name and no timestamp, so two builds agree."""

    buffer = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buffer, compresslevel=9, mtime=0) as out:
        out.write(data)
    return buffer.getvalue()


# ── downloads ───────────────────────────────────────────────────────────────


def download_verified(url: str, sha256: str, destination: Path, opener) -> Path:
    """Fetch one pinned artifact, or reuse a cached copy with the pinned digest."""

    if destination.exists() and sha256_file(destination) == sha256:
        return destination

    destination.parent.mkdir(parents=True, exist_ok=True)
    with opener(url) as response:
        payload = response.read()

    digest = hashlib.sha256(payload).hexdigest()
    if digest != sha256:
        raise BuildError(f"{url} has digest {digest}, and this build pins {sha256}")

    destination.write_bytes(payload)
    return destination


def resolve_nfpm(host_machine: str, cache: Path, opener, runner) -> Path:
    machine = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}.get(
        host_machine
    )
    if machine is None:
        raise BuildError(
            f"nfpm is pinned for x86_64 and aarch64 Linux hosts, and this host is {host_machine}; "
            "build with --container"
        )

    asset, sha256 = NFPM_RELEASES[machine]
    archive = download_verified(
        NFPM_URL.format(version=NFPM_VERSION, asset=asset), sha256, cache / asset, opener
    )

    executable = cache / f"nfpm-{NFPM_VERSION}-{machine}"
    if not executable.exists():
        with tarfile.open(archive) as tar:
            member = tar.extractfile("nfpm")
            if member is None:
                raise BuildError(f"{archive} carries no nfpm executable")
            executable.write_bytes(member.read())
        executable.chmod(0o755)

    runner([str(executable), "--version"], check=True)
    return executable


def resolve_cosign(target: str, cache: Path, opener) -> Path:
    asset, sha256 = COSIGN_RELEASES[target]
    cosign = download_verified(
        COSIGN_URL.format(version=COSIGN_VERSION, asset=asset),
        sha256,
        cache / f"{asset}-{COSIGN_VERSION}",
        opener,
    )
    return cosign


# ── the staging tree ────────────────────────────────────────────────────────


def stage_engine_tree(
    *,
    stage_root: Path,
    source_root: Path,
    wrapper: Path,
    loader: Path,
    cosign: Path,
    manifest: dict,
    changelog: str | None,
) -> None:
    """Stage the engine's installed layout once, for both things that carry it.

    The deb and the rpm are built from this tree, and so is the `tree/` the
    app-engine archive hands the desktop package, which is what makes "the
    engine layout is identical in both packages" true by construction. A
    `changelog` of None is the one documented difference: the archive omits it
    because the combined desktop package ships one changelog, its own.
    """
    packaging = source_root / "packaging/linux"

    copies = {
        "usr/bin/fermix": wrapper,
        "usr/lib/fermix/cosign": cosign,
        "usr/lib/systemd/user/fermix.service": packaging / "systemd/fermix.service",
        "usr/share/bash-completion/completions/fermix": packaging / "completions/fermix.bash",
        "usr/share/zsh/site-functions/_fermix": packaging / "completions/_fermix",
        "usr/share/fish/vendor_completions.d/fermix.fish": packaging / "completions/fermix.fish",
        "usr/share/doc/fermix/copyright": packaging / "copyright",
    }

    for installed, origin in copies.items():
        if not origin.is_file():
            raise BuildError(f"{origin} is missing, so /{installed} cannot be staged")
        _write(stage_root / installed, origin.read_bytes())

    _write(
        stage_root / "usr/share/fermix/engine.json",
        (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8"),
    )
    _write(
        stage_root / "usr/share/man/man1/fermix.1.gz",
        gzip_bytes((packaging / "man/fermix.1").read_bytes()),
    )
    if changelog is not None:
        _write(
            stage_root / "usr/share/doc/fermix/changelog.Debian.gz",
            gzip_bytes(changelog.encode("utf-8")),
        )
    payload = stage_root / "usr/lib/fermix/runtime-payload" / loader.name
    _write(payload, loader.read_bytes())
    payload.chmod(0o644)

    for installed, mode in staged_modes(changelog is not None).items():
        path = stage_root / installed
        if not path.is_file():
            raise BuildError(f"/{installed} was not staged")
        path.chmod(mode)


def staged_modes(with_changelog: bool) -> dict:
    if with_changelog:
        return STAGED_MODES
    return {path: mode for path, mode in STAGED_MODES.items() if path != CHANGELOG_PATH}


def _write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


# ── the app-engine archive ──────────────────────────────────────────────────


def nfpm_contents(rendered: str, *, omit: set[str]) -> str:
    """The `contents:` block on its own, with the paths this archive omits gone.

    The desktop package concatenates this into its own nFPM configuration
    instead of restating every path and mode, so the two packages install the
    engine's files at the same places with the same modes or neither builds.
    """
    _head, marker, rest = rendered.partition("\ncontents:\n")
    body, scripts, _tail = rest.partition("\nscripts:\n")
    if not marker or not scripts:
        raise BuildError("the nfpm template no longer has a contents block before its scripts")

    blocks = [block for block in body.split("\n\n") if block.strip()]
    kept = [block for block in blocks if _destination(block) not in omit]
    if len(blocks) - len(kept) != len(omit):
        raise BuildError(f"the nfpm template's contents block does not carry all of {sorted(omit)}")

    return NFPM_CONTENTS_HEADER + "contents:\n" + "\n\n".join(kept) + "\n"


def _destination(block: str) -> str:
    match = re.search(r"^\s*dst:\s*(\S+)\s*$", block, re.MULTILINE)
    if not match:
        raise BuildError(f"an nfpm contents entry names no destination:\n{block}")
    return match.group(1)


def stage_app_engine(
    *,
    release_root: Path,
    source_root: Path,
    target: str,
    version: str,
    build_id: str,
    source_commit: str,
    wrapper: Path,
    loader: Path,
    cosign: Path,
    manifest: dict,
    contents: str,
    protocols: dict,
) -> None:
    """Assemble the archive root the desktop build consumes (amendment §5.1)."""

    stage_engine_tree(
        stage_root=release_root / ARCHIVE_TREE,
        source_root=source_root,
        wrapper=wrapper,
        loader=loader,
        cosign=cosign,
        manifest=manifest,
        changelog=None,
    )

    for name in ("postinstall.sh", "postremove.sh"):
        script = release_root / ARCHIVE_MAINTAINER / name
        _write(script, (source_root / "packaging/linux/scripts" / name).read_bytes())
        script.chmod(0o755)

    _write(release_root / NFPM_CONTENTS_NAME, contents.encode("utf-8"))
    (release_root / NFPM_CONTENTS_NAME).chmod(0o644)

    built = package_app_engine.build_manifest(
        release_root,
        target,
        product_version=version,
        build_id=build_id,
        source_commit=source_commit,
        protocols=protocols,
    )
    engine_manifest_path = release_root / package_app_engine.MANIFEST_NAME
    _write(engine_manifest_path, (json.dumps(built, indent=2, sort_keys=True) + "\n").encode())
    engine_manifest_path.chmod(0o644)


def read_protocols(path: Path) -> dict:
    """The management and Realtime windows the compiled engine reports.

    They are read out of the engine by the build script rather than restated
    here, so the archive's manifest and the macOS manifest can only ever
    disagree if the wire authorities themselves do.
    """
    try:
        protocols = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BuildError(f"cannot read the protocol windows from {path}: {error}") from error

    if not isinstance(protocols, dict) or set(protocols) != {"management", "realtime"}:
        raise BuildError(f"{path} does not carry a management and a realtime protocol window")
    return protocols


# ── packaging ───────────────────────────────────────────────────────────────


def build_packages(
    *,
    nfpm: Path,
    config: Path,
    output_dir: Path,
    version: str,
    target: str,
    runner,
) -> list[Path]:
    nfpm_arch, _, rpm_arch, deb_arch = resolve_target(target)
    output_dir.mkdir(parents=True, exist_ok=True)

    expected = {
        "deb": output_dir / f"fermix_{version}_{deb_arch}.deb",
        "rpm": output_dir / f"fermix-{version}-1.{rpm_arch}.rpm",
    }

    built = []
    for packager, package in expected.items():
        if package.exists():
            package.unlink()

        runner(
            [
                str(nfpm),
                "package",
                "--config",
                str(config),
                "--packager",
                packager,
                "--target",
                str(output_dir),
            ],
            check=True,
        )

        if not package.is_file():
            produced = sorted(p.name for p in output_dir.iterdir())
            raise BuildError(
                f"nfpm did not produce {package.name} for {nfpm_arch}; it wrote {produced}"
            )
        built.append(package)

    return built


def main(argv=None, *, opener=urllib.request.urlopen, runner=subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True, choices=sorted(TARGETS))
    parser.add_argument("--version", required=True)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--build-id", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--burrito-out", type=Path)
    parser.add_argument("--tool-cache", type=Path)
    parser.add_argument("--host-machine", default=os.uname().machine)
    parser.add_argument(
        "--app-engine-dir",
        type=Path,
        help="also build fermix_app_engine_<target>.tar.gz into this directory",
    )
    parser.add_argument(
        "--protocols",
        type=Path,
        help="JSON the build script read out of the compiled engine; required by --app-engine-dir",
    )
    arguments = parser.parse_args(argv)

    if arguments.app_engine_dir and not arguments.protocols:
        parser.error("--app-engine-dir needs --protocols")

    try:
        packages = run_build(arguments, opener=opener, runner=runner)
    except BuildError as error:
        print(f"linux_packages.py: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        # A packager that exits non-zero is a refusal with a command to name,
        # not a traceback for somebody to read backwards.
        print(
            f"linux_packages.py: {' '.join(error.cmd)} exited {error.returncode}",
            file=sys.stderr,
        )
        return 1
    except (OSError, package_app_engine.PackageError) as error:
        print(f"linux_packages.py: {error}", file=sys.stderr)
        return 1

    for package in packages:
        print(package)
    return 0


def run_build(arguments, *, opener, runner) -> list[Path]:
    version = check_version(arguments.version)
    source_root = arguments.source_root.resolve()
    target = arguments.target
    burrito_out = (arguments.burrito_out or source_root / "burrito_out").resolve()
    cache = (arguments.tool_cache or source_root / "packaging/linux/out/tools").resolve()

    wrapper = burrito_out / f"fermix_linux_package_{target}"
    if not wrapper.is_file():
        raise BuildError(f"the release wrapper {wrapper} is missing; build the release first")

    loader_dir = source_root / "packaging/linux/out" / target
    loader, loader_sha256 = loader_in(loader_dir)

    manifest = engine_manifest(
        target=target,
        version=version,
        build_id=arguments.build_id,
        source_commit=arguments.source_commit,
        loader_sha256=loader_sha256,
        binary_sha256=sha256_file(wrapper),
    )

    check_payload_key(
        arguments.output_dir.resolve(), arguments.build_id, manifest["binary_sha256"]
    )

    changelog = debian_changelog((source_root / "CHANGELOG.md").read_text(encoding="utf-8"), version)

    nfpm = resolve_nfpm(arguments.host_machine, cache, opener, runner)
    cosign = resolve_cosign(target, cache, opener)

    work = Path(tempfile.mkdtemp(prefix=f"fermix-linux-package-{target}-"))
    try:
        return produce_artifacts(
            arguments,
            work=work,
            source_root=source_root,
            version=version,
            wrapper=wrapper,
            loader=loader,
            cosign=cosign,
            manifest=manifest,
            changelog=changelog,
            nfpm=nfpm,
            runner=runner,
        )
    finally:
        shutil.rmtree(work, ignore_errors=True)


def produce_artifacts(
    arguments,
    *,
    work: Path,
    source_root: Path,
    version: str,
    wrapper: Path,
    loader: Path,
    cosign: Path,
    manifest: dict,
    changelog: str,
    nfpm: Path,
    runner,
) -> list[Path]:
    """The deb, the rpm and, when asked for, the archive — from one staged tree."""

    target = arguments.target
    stage_root = work / "stage"
    stage_engine_tree(
        stage_root=stage_root,
        source_root=source_root,
        wrapper=wrapper,
        loader=loader,
        cosign=cosign,
        manifest=manifest,
        changelog=changelog,
    )

    template = (source_root / "packaging/linux/nfpm-fermix.yaml.tmpl").read_text(encoding="utf-8")
    config = source_root / "packaging/linux/out" / target / "nfpm-fermix.yaml"
    config.write_text(
        render_config(template, source_root, target, version, stage_root, loader.name),
        encoding="utf-8",
    )

    packages = build_packages(
        nfpm=nfpm,
        config=config,
        output_dir=arguments.output_dir.resolve(),
        version=version,
        target=target,
        runner=runner,
    )

    if arguments.app_engine_dir is None:
        return packages

    archive = build_app_engine_archive(
        arguments,
        work=work,
        source_root=source_root,
        template=template,
        wrapper=wrapper,
        loader=loader,
        cosign=cosign,
        manifest=manifest,
        version=version,
    )
    return [*packages, archive]


def render_config(
    template: str,
    source_root: Path,
    target: str,
    version: str,
    stage_root: Path,
    loader_name: str,
) -> str:
    nfpm_arch, _, _, _ = resolve_target(target)
    return render_template(
        template,
        {
            "VERSION": version,
            "ARCH": nfpm_arch,
            "STAGE": stage_root,
            "LOADER": loader_name,
            "POSTINSTALL": source_root / "packaging/linux/scripts/postinstall.sh",
            "POSTREMOVE": source_root / "packaging/linux/scripts/postremove.sh",
        },
    )


def build_app_engine_archive(
    arguments,
    *,
    work: Path,
    source_root: Path,
    template: str,
    wrapper: Path,
    loader: Path,
    cosign: Path,
    manifest: dict,
    version: str,
) -> Path:
    """Stage and package `fermix_app_engine_<target>.tar.gz` from this build."""

    target = arguments.target
    release_root = work / "app-engine"
    contents = nfpm_contents(
        render_config(template, source_root, target, version, Path(ARCHIVE_TREE), loader.name),
        omit={f"/{CHANGELOG_PATH}"},
    )

    stage_app_engine(
        release_root=release_root,
        source_root=source_root,
        target=target,
        version=version,
        build_id=arguments.build_id,
        source_commit=arguments.source_commit,
        wrapper=wrapper,
        loader=loader,
        cosign=cosign,
        manifest=manifest,
        contents=contents,
        protocols=read_protocols(arguments.protocols),
    )

    output = arguments.app_engine_dir.resolve()
    destination = output / f"fermix_app_engine_{target}.tar.gz"
    # The packages beside it are replaced on every run, and this archive is
    # produced by the same build from the same tree, so it follows the same
    # rule rather than refusing a second run in the same output directory.
    if destination.exists() or destination.is_symlink():
        destination.unlink()

    return package_app_engine.package_release(
        release_root, target, output, version, arguments.source_commit
    )


if __name__ == "__main__":
    raise SystemExit(main())
