#!/usr/bin/env python3
"""Validate and reproducibly package one assembled Fermix app-engine release."""

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

ARCHITECTURES = {
    "macos_aarch64": "arm64",
    "macos_x86_64": "x86_64",
}
ARCHIVE_ROOT = "fermix_app_engine"
ENGINE_ID = "fermix-core"
MANIFEST_NAME = "engine-manifest.json"
BUILD_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
MAX_DEPTH = 32
MAX_ENTRIES = 30_000
NATIVE_EXTENSIONS = {".bundle", ".dylib", ".so"}
MACH_O_MAGICS = {
    bytes.fromhex("feedface"),
    bytes.fromhex("cefaedfe"),
    bytes.fromhex("feedfacf"),
    bytes.fromhex("cffaedfe"),
    bytes.fromhex("cafebabe"),
    bytes.fromhex("bebafeca"),
    bytes.fromhex("cafebabf"),
    bytes.fromhex("bfbafeca"),
}
THIN_MACH_O_MAGICS = {
    bytes.fromhex("feedface"): "big",
    bytes.fromhex("cefaedfe"): "little",
    bytes.fromhex("feedfacf"): "big",
    bytes.fromhex("cffaedfe"): "little",
}
FAT_MACH_O_MAGICS = {
    bytes.fromhex("cafebabe"): ("big", 20),
    bytes.fromhex("bebafeca"): ("little", 20),
    bytes.fromhex("cafebabf"): ("big", 32),
    bytes.fromhex("bfbafeca"): ("little", 32),
}
CPU_ARCHITECTURES = {
    7: "x86",
    12: "arm",
    0x01000007: "x86_64",
    0x0100000C: "arm64",
}
MAX_MACH_O_ARCHITECTURES = 16
OIDC_ISSUER = "https://token.actions.githubusercontent.com"
WORKFLOW_IDENTITY = "https://github.com/tezra-io/fermix/.github/workflows/release.yml"


class PackageError(RuntimeError):
    """Raised when an app-engine tree is unsafe or contradicts its manifest."""


@dataclass(frozen=True)
class TreeEntry:
    path: Path
    relative: str
    kind: str
    mode: int
    target: str | None = None


def compute_tree_digest(release_root):
    """Compute the canonical digest used by the embedded engine manifest."""
    root = _release_root(release_root)
    entries = _scan_tree(root, excluded={MANIFEST_NAME})
    digest = hashlib.sha256()

    for entry in entries:
        digest.update(_digest_record(entry))

    return digest.hexdigest()


def validate_release(
    release_root,
    target,
    expected_version=None,
    expected_source_commit=None,
):
    """Validate one assembled release tree and return its trusted manifest."""
    architecture = _architecture(target)
    root = _release_root(release_root)
    manifest = _load_manifest(root)
    _validate_manifest(
        manifest,
        root,
        target,
        architecture,
        expected_version,
        expected_source_commit,
    )
    return manifest


def package_release(
    release_root,
    target,
    output_dir,
    expected_version=None,
    expected_source_commit=None,
):
    """Validate and archive one release tree without replacing existing output."""
    root = _release_root(release_root)
    output = Path(output_dir).expanduser().resolve()
    if _inside(root, output):
        raise PackageError("archive output must stay outside the release tree")

    destination = output / f"fermix_app_engine_{target}.tar.gz"
    if destination.exists() or destination.is_symlink():
        raise PackageError(f"archive already exists: {destination.name}")

    validate_release(root, target, expected_version, expected_source_commit)
    output.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=".app-engine-stage-", dir=output) as temporary:
        snapshot = Path(temporary) / ARCHIVE_ROOT
        _snapshot_release_tree(root, snapshot)
        validate_release(snapshot, target, expected_version, expected_source_commit)
        _write_archive(snapshot, destination)

    return destination


def _architecture(target):
    try:
        return ARCHITECTURES[target]
    except KeyError as error:
        allowed = ", ".join(sorted(ARCHITECTURES))
        raise PackageError(f"unsupported app-engine target {target!r}; expected {allowed}") from error


def _release_root(value):
    root = Path(value).expanduser().resolve()
    if not root.is_dir():
        raise PackageError("release root must be an existing directory")
    return root


def _load_manifest(root):
    path = root / MANIFEST_NAME
    if path.is_symlink() or not path.is_file():
        raise PackageError(f"{MANIFEST_NAME} must be a regular file")

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackageError(f"cannot read {MANIFEST_NAME}: {error}") from error

    if not isinstance(payload, dict):
        raise PackageError(f"{MANIFEST_NAME} must contain a JSON object")
    return payload


def _validate_manifest(
    manifest,
    root,
    target,
    architecture,
    expected_version,
    expected_source_commit,
):
    _exact_keys(
        manifest,
        {"schema_version", "identity", "protocols", "provenance", "tree_sha256", "inventory"},
        "manifest",
    )
    if manifest["schema_version"] != 1:
        raise PackageError("manifest schema_version must be 1")

    identity = _validate_identity(
        manifest["identity"],
        target,
        architecture,
        expected_version,
        expected_source_commit,
    )
    _validate_protocols(manifest["protocols"])
    _validate_provenance(manifest["provenance"], identity["product_version"])

    actual_digest = compute_tree_digest(root)
    if manifest["tree_sha256"] != actual_digest:
        raise PackageError("manifest tree_sha256 does not match the assembled release tree")

    entries = _scan_tree(root, excluded={MANIFEST_NAME})
    _validate_inventory(manifest["inventory"], entries, target, architecture)


def _validate_identity(
    identity,
    target,
    architecture,
    expected_version,
    expected_source_commit,
):
    keys = {
        "engine_id",
        "product_version",
        "build_id",
        "source_commit",
        "distribution_identity",
        "artifact_target",
        "architecture",
    }
    _exact_keys(identity, keys, "identity")
    if identity["engine_id"] != ENGINE_ID:
        raise PackageError(f"identity.engine_id must be {ENGINE_ID}")
    _bounded_string(identity["product_version"], "identity.product_version")

    build_id = identity["build_id"]
    if not isinstance(build_id, str) or not BUILD_ID_PATTERN.fullmatch(build_id):
        raise PackageError("identity.build_id has an invalid format")

    commit = identity["source_commit"]
    if not isinstance(commit, str) or len(commit) != 40 or any(c not in "0123456789abcdefABCDEF" for c in commit):
        raise PackageError("identity.source_commit must be a full 40-character hexadecimal commit")
    if expected_source_commit is not None and commit.lower() != expected_source_commit.lower():
        raise PackageError("identity.source_commit does not match the requested source commit")
    if identity["distribution_identity"] != "macos_app":
        raise PackageError("identity.distribution_identity must be macos_app")
    if identity["artifact_target"] != target:
        raise PackageError(f"identity.artifact_target must be {target}")
    if identity["architecture"] != architecture:
        raise PackageError(f"identity.architecture must be {architecture}")
    if expected_version is not None and identity["product_version"] != expected_version:
        raise PackageError(f"identity.product_version must be {expected_version}")
    return identity


def _validate_protocols(protocols):
    _exact_keys(protocols, {"management", "realtime"}, "protocols")
    for name in ("management", "realtime"):
        value = protocols[name]
        _exact_keys(value, {"current_version", "minimum_version", "maximum_version"}, name)
        current = _positive_integer(value["current_version"], f"{name}.current_version")
        minimum = _positive_integer(value["minimum_version"], f"{name}.minimum_version")
        maximum = _positive_integer(value["maximum_version"], f"{name}.maximum_version")
        if not minimum <= current <= maximum:
            raise PackageError(f"{name} protocol range is inconsistent")


def _validate_provenance(provenance, version):
    _exact_keys(provenance, {"oidc_issuer", "certificate_identity"}, "provenance")
    expected_identity = f"{WORKFLOW_IDENTITY}@refs/tags/v{version}"
    if provenance["oidc_issuer"] != OIDC_ISSUER:
        raise PackageError("provenance.oidc_issuer is not the Fermix release issuer")
    if provenance["certificate_identity"] != expected_identity:
        raise PackageError("provenance.certificate_identity is not bound to the release tag")


def _validate_inventory(inventory, entries, target, architecture):
    _exact_keys(inventory, {"artifact_target", "architecture", "entries"}, "inventory")
    if inventory["artifact_target"] != target:
        raise PackageError(f"inventory.artifact_target must be {target}")
    if inventory["architecture"] != architecture:
        raise PackageError(f"inventory.architecture must be {architecture}")
    if not isinstance(inventory["entries"], list):
        raise PackageError("inventory.entries must be a list")

    actual = {entry.relative: entry for entry in entries}
    listed = _inventory_by_path(inventory["entries"])
    required = {path for path, entry in actual.items() if _inventory_required(entry)}
    missing = sorted(required - set(listed))
    extra = sorted(set(listed) - required)
    if missing:
        raise PackageError(f"inventory is missing executable or symlink: {missing[0]}")
    if extra:
        raise PackageError(f"inventory lists non-executable content: {extra[0]}")

    for path in sorted(listed):
        _validate_inventory_entry(listed[path], actual[path], architecture)


def _inventory_by_path(entries):
    result = {}
    previous = None
    for value in entries:
        if not isinstance(value, dict):
            raise PackageError("inventory entries must be JSON objects")
        path = value.get("path")
        _safe_relative(path, "inventory path")
        if path in result:
            raise PackageError(f"duplicate inventory path: {path}")
        if previous is not None and path < previous:
            raise PackageError("inventory entries must be sorted by path")
        result[path] = value
        previous = path
    return result


def _validate_inventory_entry(value, entry, architecture):
    if entry.kind == "symlink":
        _exact_keys(value, {"path", "kind", "mode", "target"}, f"inventory entry {entry.relative}")
        if value["kind"] != "symlink" or value["mode"] != "0777" or value["target"] != entry.target:
            raise PackageError(f"symlink inventory mismatch: {entry.relative}")
        return

    if value.get("kind") == "script":
        _validate_script_inventory(value, entry)
        return
    if value.get("kind") == "mach_o":
        _validate_mach_o_inventory(value, entry, architecture)
        return
    raise PackageError(f"unknown inventory kind for {entry.relative}")


def _validate_script_inventory(value, entry):
    keys = {"path", "kind", "mode", "interpreter", "sha256"}
    _exact_keys(value, keys, f"inventory entry {entry.relative}")
    interpreter = _script_interpreter(_read_prefix(entry.path))
    if interpreter is None or value["interpreter"] != interpreter:
        raise PackageError(f"script interpreter mismatch: {entry.relative}")
    _validate_file_metadata(value, entry)


def _validate_mach_o_inventory(value, entry, architecture):
    keys = {"path", "kind", "mode", "architectures", "sha256"}
    _exact_keys(value, keys, f"inventory entry {entry.relative}")
    if not _is_mach_o(entry.path):
        raise PackageError(f"Mach-O inventory mismatch: {entry.relative}")

    observed = _mach_o_architectures(entry.path)
    if observed != [architecture] or value["architectures"] != observed:
        raise PackageError(f"Mach-O architecture mismatch: {entry.relative}")
    _validate_file_metadata(value, entry)


def _validate_file_metadata(value, entry):
    if value["mode"] != _mode(entry.mode):
        raise PackageError(f"file mode mismatch: {entry.relative}")
    if value["sha256"] != _file_sha256(entry.path):
        raise PackageError(f"file sha256 mismatch: {entry.relative}")


def _inventory_required(entry):
    if entry.kind == "symlink":
        return True
    if entry.kind != "file":
        return False
    return bool(entry.mode & 0o111) or entry.path.suffix in NATIVE_EXTENSIONS or _is_mach_o(entry.path)


def _scan_tree(root, excluded):
    entries = []
    seen = [0]
    _walk(root, root, 0, seen, entries, excluded)
    return sorted(entries, key=lambda entry: entry.relative)


def _walk(root, directory, depth, seen, entries, excluded):
    if depth > MAX_DEPTH:
        raise PackageError("release tree exceeds maximum depth")

    try:
        children = sorted(directory.iterdir(), key=lambda path: path.name)
    except OSError as error:
        raise PackageError(f"cannot read release directory: {error}") from error

    for path in children:
        seen[0] += 1
        if seen[0] > MAX_ENTRIES:
            raise PackageError("release tree exceeds maximum entry count")
        entry = _tree_entry(root, path)
        if entry.relative not in excluded:
            entries.append(entry)
        if entry.kind == "directory":
            _walk(root, path, depth + 1, seen, entries, excluded)


def _tree_entry(root, path):
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PackageError(f"cannot stat release entry: {error}") from error

    relative = path.relative_to(root).as_posix()
    if stat.S_ISLNK(metadata.st_mode):
        return _symlink_entry(root, path, relative)
    if stat.S_ISDIR(metadata.st_mode):
        return TreeEntry(path, relative, "directory", stat.S_IMODE(metadata.st_mode))
    if stat.S_ISREG(metadata.st_mode):
        return TreeEntry(path, relative, "file", stat.S_IMODE(metadata.st_mode))
    raise PackageError(f"unsupported release tree entry: {relative}")


def _symlink_entry(root, path, relative):
    try:
        target = os.readlink(path)
    except OSError as error:
        raise PackageError(f"cannot read release symlink: {relative}: {error}") from error

    if os.path.isabs(target):
        raise PackageError(f"absolute symlink target is not relocatable: {relative}")

    lexical = Path(os.path.abspath(path.parent / target))
    if not _inside(root, lexical):
        raise PackageError(f"symlink escapes release root: {relative}")
    if not lexical.exists():
        raise PackageError(f"symlink target is missing: {relative}")
    resolved = Path(os.path.realpath(lexical))
    if not _inside(root, resolved):
        raise PackageError(f"symlink escapes release root: {relative}")
    return TreeEntry(path, relative, "symlink", 0o777, target)


def _inside(root, path):
    try:
        return os.path.commonpath((str(root), str(path))) == str(root)
    except ValueError:
        return False


def _digest_record(entry):
    mode = _mode(entry.mode)
    if entry.kind == "directory":
        return f"directory\0{entry.relative}\0{mode}\n".encode()
    if entry.kind == "file":
        digest = _file_sha256(entry.path)
        return f"file\0{entry.relative}\0{mode}\0{digest}\n".encode()
    return f"symlink\0{entry.relative}\0{mode}\0{entry.target}\n".encode()


def _snapshot_release_tree(root, snapshot):
    try:
        root_mode = stat.S_IMODE(root.stat().st_mode)
        snapshot.mkdir(mode=root_mode)
        snapshot.chmod(root_mode)

        for entry in _scan_tree(root, excluded=set()):
            destination = snapshot / entry.relative
            if entry.kind == "directory":
                destination.mkdir(mode=entry.mode)
                destination.chmod(entry.mode)
            elif entry.kind == "symlink":
                os.symlink(entry.target, destination)
            else:
                _copy_regular_file(entry.path, destination, entry.mode)
    except OSError as error:
        raise PackageError(f"cannot snapshot app-engine release: {error}") from error


def _copy_regular_file(source, destination, mode):
    source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(source_fd).st_mode):
            raise PackageError(f"release file changed during snapshot: {source.name}")

        destination_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        try:
            with os.fdopen(source_fd, "rb", closefd=False) as input_stream:
                with os.fdopen(destination_fd, "wb", closefd=False) as output_stream:
                    shutil.copyfileobj(input_stream, output_stream, 64 * 1024)
        finally:
            os.close(destination_fd)
    finally:
        os.close(source_fd)
    destination.chmod(mode)


def _write_archive(root, destination):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".app-engine-", suffix=".tmp", dir=destination.parent, delete=False) as raw:
            temporary = Path(raw.name)
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.GNU_FORMAT) as archive:
                    _add_archive_tree(archive, root)
        os.chmod(temporary, 0o644)
        _activate_archive(temporary, destination)
    except (OSError, tarfile.TarError, PackageError) as error:
        _cleanup_archive(temporary, error)


def _add_archive_tree(archive, root):
    root_info = _normalized_tarinfo(archive.gettarinfo(str(root), arcname=ARCHIVE_ROOT), None)
    archive.addfile(root_info)
    for entry in _scan_tree(root, excluded=set()):
        arcname = f"{ARCHIVE_ROOT}/{entry.relative}"
        info = _normalized_tarinfo(archive.gettarinfo(str(entry.path), arcname=arcname), entry)
        if entry.kind == "file":
            with entry.path.open("rb") as stream:
                archive.addfile(info, stream)
        else:
            archive.addfile(info)


def _normalized_tarinfo(info, entry):
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    info.pax_headers = {}
    info.mode = 0o755 if entry is None else entry.mode
    return info


def _activate_archive(temporary, destination):
    try:
        os.link(temporary, destination)
    except FileExistsError as error:
        raise PackageError(f"archive already exists: {destination.name}") from error
    temporary.unlink()


def _cleanup_archive(temporary, failure):
    if temporary is None or not temporary.exists():
        raise PackageError(f"cannot package app-engine release: {failure}") from failure
    try:
        temporary.unlink()
    except OSError as cleanup_error:
        raise PackageError(
            f"cannot package app-engine release and cannot remove temporary archive: {cleanup_error}"
        ) from failure
    raise PackageError(f"cannot package app-engine release: {failure}") from failure


def _exact_keys(value, expected, label):
    if not isinstance(value, dict) or set(value) != expected:
        raise PackageError(f"{label} has invalid fields")


def _safe_relative(value, label):
    if not isinstance(value, str) or not value:
        raise PackageError(f"{label} must be a non-empty relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise PackageError(f"{label} must stay inside the release root")


def _bounded_string(value, label):
    if not isinstance(value, str) or not 1 <= len(value.encode("utf-8")) <= 256:
        raise PackageError(f"{label} must contain 1 to 256 UTF-8 bytes")
    return value


def _positive_integer(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise PackageError(f"{label} must be a positive integer")
    return value


def _script_interpreter(prefix):
    if not prefix.startswith(b"#!"):
        return None
    first_line = prefix.split(b"\n", 1)[0][2:].strip()
    if not first_line:
        return None
    try:
        return first_line.split(None, 1)[0].decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise PackageError("script interpreter must be valid UTF-8") from error


def _mach_o_architectures(path):
    header = _read_prefix(path, 8 + MAX_MACH_O_ARCHITECTURES * 32)
    if len(header) < 8:
        raise PackageError(f"Mach-O header is truncated: {path.name}")

    magic = header[:4]
    if magic in THIN_MACH_O_MAGICS:
        cpu_type = int.from_bytes(header[4:8], THIN_MACH_O_MAGICS[magic])
        return [_cpu_architecture(cpu_type, path)]
    if magic in FAT_MACH_O_MAGICS:
        byte_order, record_size = FAT_MACH_O_MAGICS[magic]
        return _fat_mach_o_architectures(header, byte_order, record_size, path)
    raise PackageError(f"Mach-O header has an unknown magic: {path.name}")


def _fat_mach_o_architectures(header, byte_order, record_size, path):
    count = int.from_bytes(header[4:8], byte_order)
    if count < 1 or count > MAX_MACH_O_ARCHITECTURES:
        raise PackageError(f"Mach-O architecture count is invalid: {path.name}")

    required = 8 + count * record_size
    if len(header) < required:
        raise PackageError(f"Mach-O architecture table is truncated: {path.name}")

    architectures = []
    for index in range(count):
        offset = 8 + index * record_size
        cpu_type = int.from_bytes(header[offset : offset + 4], byte_order)
        architecture = _cpu_architecture(cpu_type, path)
        if architecture in architectures:
            raise PackageError(f"Mach-O architecture is duplicated: {path.name}")
        architectures.append(architecture)
    return sorted(architectures)


def _cpu_architecture(cpu_type, path):
    try:
        return CPU_ARCHITECTURES[cpu_type]
    except KeyError as error:
        raise PackageError(f"Mach-O CPU type is unsupported: {path.name}") from error


def _is_mach_o(path):
    return _read_prefix(path, 4) in MACH_O_MAGICS


def _read_prefix(path, size=512):
    try:
        with path.open("rb") as stream:
            return stream.read(size)
    except OSError as error:
        raise PackageError(f"cannot inspect release file {path.name}: {error}") from error


def _file_sha256(path):
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(64 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise PackageError(f"cannot hash release file {path.name}: {error}") from error
    return digest.hexdigest()


def _mode(value):
    return f"{value:04o}"


def _arguments(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-root", required=True)
    parser.add_argument("--target", choices=sorted(ARCHITECTURES), required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--version")
    parser.add_argument("--source-commit", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    args = _arguments(argv)
    try:
        archive = package_release(
            args.release_root,
            args.target,
            args.output_dir,
            args.version,
            args.source_commit,
        )
    except PackageError as error:
        print(f"package_app_engine.py: {error}", file=sys.stderr)
        return 1
    print(archive)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
