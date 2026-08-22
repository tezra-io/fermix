#!/usr/bin/env python3
"""Verify one signed Fermix app-engine archive by launching its native runtime."""

import argparse
import json
import os
import platform
import pwd
import re
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

import package_app_engine as package

ARCHIVE_ROOT = package.ARCHIVE_ROOT
MAX_FRAME_BYTES = 4_194_304
MAX_ARCHIVE_ENTRIES = package.MAX_ENTRIES + 1
MAX_ARCHIVE_FILE_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
COPY_CHUNK_BYTES = 64 * 1024
RUNTIME_TEMP_PARENT = Path("/tmp")
SMOKE_OPENAI_API_KEY = "fermix-release-smoke-not-a-real-key"
SMOKE_CONFIG = """\
[fermix_core.realtime]
enabled = true
"""
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[+-][0-9A-Za-z.-]+)?$")
SOURCE_COMMIT_PATTERN = re.compile(r"^[0-9A-Fa-f]{40}$")


class VerificationError(RuntimeError):
    """Raised when a published app-engine archive cannot be trusted or run."""


@dataclass(frozen=True)
class Timeouts:
    """Explicit bounds for release smoke verification."""

    startup_attempts: int = 180
    shutdown_attempts: int = 120
    poll_interval_seconds: float = 0.5
    health_timeout_seconds: float = 1.0
    management_timeout_seconds: float = 5.0
    stop_timeout_seconds: float = 15.0
    cleanup_timeout_seconds: float = 5.0


DEFAULT_TIMEOUTS = Timeouts()


def extract_archive(archive_path, destination):
    """Safely extract one deterministic app-engine archive into a new directory."""
    archive = _regular_archive(archive_path)
    output = Path(destination).expanduser()
    if output.exists() or output.is_symlink():
        raise VerificationError("archive extraction directory already exists")

    output.mkdir(parents=False, mode=0o700)
    try:
        with tarfile.open(archive, mode="r:gz") as stream:
            members = _bounded_archive_members(stream)
            _validate_archive_members(members)
            _extract_members(stream, members, output)
    except (OSError, tarfile.TarError, VerificationError) as error:
        _remove_extraction(output, error)

    return output / ARCHIVE_ROOT


def verify_app_engine(
    archive_path,
    target,
    version,
    mode,
    *,
    expected_source_commit=None,
    temp_parent=None,
    timeouts=DEFAULT_TIMEOUTS,
):
    """Validate, launch, probe, stop, and clean one app-engine archive."""
    _validate_inputs(
        archive_path, target, version, mode, expected_source_commit, timeouts
    )
    command_prefix = _command_prefix(target, mode)
    parent = _temporary_parent(temp_parent)

    with tempfile.TemporaryDirectory(
        prefix=f"fermix-engine-smoke-{target}-", dir=parent
    ) as temporary, tempfile.TemporaryDirectory(
        prefix="fxh-", dir=RUNTIME_TEMP_PARENT
    ) as runtime_temporary:
        return _verify_in_directories(
            archive_path,
            target,
            version,
            mode,
            command_prefix,
            Path(temporary),
            Path(runtime_temporary),
            expected_source_commit,
            timeouts,
        )


def _verify_in_directories(
    archive_path,
    target,
    version,
    mode,
    command_prefix,
    scratch,
    runtime_root,
    expected_source_commit,
    timeouts,
):
    release_root = extract_archive(archive_path, scratch / "archive")
    manifest = _validated_manifest(
        release_root, target, version, expected_source_commit
    )
    fermix_home, environment = _runtime_environment(runtime_root, scratch)
    executable = release_root / "bin/fermix_app_engine"
    start_command = [*command_prefix, str(executable), "start"]
    stop_command = [*command_prefix, str(executable), "stop"]
    log_path = scratch / "engine.log"
    process = None

    try:
        process = _start_engine(start_command, release_root, environment, log_path)
        runtime = _verify_started_engine(
            process,
            stop_command,
            release_root,
            fermix_home,
            environment,
            manifest,
            timeouts,
            log_path,
        )
        return _runtime_result(target, version, mode, fermix_home, manifest, runtime)
    except VerificationError:
        raise
    except (OSError, subprocess.SubprocessError) as error:
        raise VerificationError(f"runtime verification failed: {error}") from error
    finally:
        cleanup_error = _force_cleanup(process, timeouts)
        if cleanup_error is not None:
            raise VerificationError(f"app-engine process cleanup failed: {cleanup_error}")


def _start_engine(command, release_root, environment, log_path):
    with log_path.open("wb") as log:
        return subprocess.Popen(
            command,
            cwd=release_root,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )


def _verify_started_engine(
    process,
    stop_command,
    release_root,
    fermix_home,
    environment,
    manifest,
    timeouts,
    log_path,
):
    _await_ready(process, fermix_home, environment, manifest, timeouts, log_path)
    protocol_version = manifest["protocols"]["management"]["current_version"]
    result = _management_hello(fermix_home / "daemon.sock", protocol_version, timeouts)
    runtime = _validate_runtime_identity(result, manifest, process.pid, environment)
    _stop_engine(stop_command, release_root, environment, timeouts)
    _await_exit(process, timeouts, log_path)
    _verify_socket_cleanup(fermix_home)
    return runtime


def _runtime_result(target, version, mode, fermix_home, manifest, runtime):
    return {
        "target": target,
        "architecture": manifest["identity"]["architecture"],
        "version": version,
        "mode": mode,
        "pid": runtime["pid"],
        "fermix_home": str(fermix_home),
    }


def _regular_archive(value):
    candidate = Path(value).expanduser()
    if candidate.is_symlink() or not candidate.is_file():
        raise VerificationError("app-engine archive must be a regular file")
    return candidate.resolve()


def _bounded_archive_members(stream):
    members = []
    for member in stream:
        if len(members) >= MAX_ARCHIVE_ENTRIES:
            raise VerificationError("app-engine archive exceeds the entry limit")
        members.append(member)
    return members


def _validate_archive_members(members):
    if not members:
        raise VerificationError("app-engine archive is empty")
    if len(members) > MAX_ARCHIVE_ENTRIES:
        raise VerificationError("app-engine archive exceeds the entry limit")

    paths = []
    by_path = {}
    directories = set()
    symlinks = set()
    total_size = 0

    for member in members:
        path = _safe_archive_path(member.name)
        if path in by_path:
            raise VerificationError(f"duplicate archive entry: {path}")
        _validate_archive_kind(member)
        if member.mode & ~0o777:
            raise VerificationError(f"archive entry has unsafe mode bits: {path}")
        if member.isfile():
            if member.size > MAX_ARCHIVE_FILE_BYTES:
                raise VerificationError(f"archive file exceeds the size limit: {path}")
            total_size += member.size
            if total_size > MAX_ARCHIVE_TOTAL_BYTES:
                raise VerificationError("app-engine archive exceeds the expanded size limit")
        if member.isdir():
            directories.add(path)
        if member.issym():
            _safe_symlink_target(path, member.linkname)
            symlinks.add(path)
        paths.append(path)
        by_path[path] = member

    if paths != sorted(paths):
        raise VerificationError("app-engine archive entries must be sorted")
    if ARCHIVE_ROOT not in directories:
        raise VerificationError(f"archive root must be exactly {ARCHIVE_ROOT}/")

    for path in paths:
        if path != ARCHIVE_ROOT and not path.startswith(f"{ARCHIVE_ROOT}/"):
            raise VerificationError(f"archive entry is outside {ARCHIVE_ROOT}/: {path}")
        for ancestor in PurePosixPath(path).parents:
            if ancestor.as_posix() in symlinks:
                raise VerificationError(f"archive entry is below symlink: {path}")
        parent = PurePosixPath(path).parent.as_posix()
        if path != ARCHIVE_ROOT and parent not in directories:
            raise VerificationError(f"archive entry has an undeclared parent directory: {path}")


def _safe_archive_path(value):
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 4_096:
        raise VerificationError("archive entry must be a bounded relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or path.as_posix() != value:
        raise VerificationError(f"archive entry must use a normalized relative path: {value}")
    if "." in path.parts or ".." in path.parts:
        raise VerificationError(f"archive entry must use a normalized relative path: {value}")
    if len(path.parts) - 1 > package.MAX_DEPTH:
        raise VerificationError(f"archive entry exceeds the depth limit: {value}")
    return path.as_posix()


def _validate_archive_kind(member):
    if member.isdir() or member.isfile() or member.issym():
        return
    raise VerificationError(f"unsupported archive entry type: {member.name}")


def _safe_symlink_target(path, target):
    if not isinstance(target, str) or not target:
        raise VerificationError(f"symlink target is empty: {path}")
    target_path = PurePosixPath(target)
    if target_path.is_absolute():
        raise VerificationError(f"absolute symlink target is not relocatable: {path}")

    stack = list(PurePosixPath(path).parent.parts)
    for part in target_path.parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not stack:
                raise VerificationError(f"symlink escapes archive root: {path}")
            stack.pop()
        else:
            stack.append(part)

    if not stack or stack[0] != ARCHIVE_ROOT:
        raise VerificationError(f"symlink escapes archive root: {path}")


def _extract_members(archive, members, output):
    directory_modes = []
    for member in members:
        relative = PurePosixPath(member.name)
        destination = output.joinpath(*relative.parts)
        if member.isdir():
            destination.mkdir(mode=0o700)
            directory_modes.append((destination, member.mode & 0o777))
        elif member.isfile():
            _extract_file(archive, member, destination)
        else:
            os.symlink(member.linkname, destination)

    for path, mode in reversed(directory_modes):
        path.chmod(mode)


def _extract_file(archive, member, destination):
    source = archive.extractfile(member)
    if source is None:
        raise VerificationError(f"cannot read archive file: {member.name}")

    written = 0
    with source, destination.open("xb") as output:
        while written < member.size:
            chunk = source.read(min(COPY_CHUNK_BYTES, member.size - written))
            if not chunk:
                raise VerificationError(f"archive file ended early: {member.name}")
            output.write(chunk)
            written += len(chunk)
        if source.read(1):
            raise VerificationError(f"archive file exceeds declared size: {member.name}")
    destination.chmod(member.mode & 0o777)


def _remove_extraction(output, failure):
    try:
        shutil.rmtree(output)
    except OSError as cleanup_error:
        raise VerificationError(
            f"archive extraction failed and cleanup failed: {cleanup_error}"
        ) from failure
    if isinstance(failure, VerificationError):
        raise failure
    raise VerificationError(f"cannot extract app-engine archive: {failure}") from failure


def _validate_inputs(
    archive_path, target, version, mode, expected_source_commit, timeouts
):
    archive = _regular_archive(archive_path)
    expected_name = f"fermix_app_engine_{target}.tar.gz"
    if archive.name != expected_name:
        raise VerificationError(f"archive name must be {expected_name}")
    if target not in package.ARCHITECTURES:
        raise VerificationError(f"unsupported app-engine target: {target}")
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise VerificationError("version must be a semantic version without a leading v")
    if mode not in ("native", "rosetta"):
        raise VerificationError("execution mode must be native or rosetta")
    if expected_source_commit is not None and not SOURCE_COMMIT_PATTERN.fullmatch(
        expected_source_commit
    ):
        raise VerificationError("expected source commit must be a full commit SHA")
    _validate_timeouts(timeouts)


def _validate_timeouts(timeouts):
    if not isinstance(timeouts, Timeouts):
        raise VerificationError("timeouts must use the app-engine timeout policy")
    integer_fields = (timeouts.startup_attempts, timeouts.shutdown_attempts)
    number_fields = (
        timeouts.poll_interval_seconds,
        timeouts.health_timeout_seconds,
        timeouts.management_timeout_seconds,
        timeouts.stop_timeout_seconds,
        timeouts.cleanup_timeout_seconds,
    )
    if any(isinstance(value, bool) or not isinstance(value, int) or value <= 0 for value in integer_fields):
        raise VerificationError("timeout attempt counts must be positive integers")
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0 for value in number_fields):
        raise VerificationError("timeout durations must be positive numbers")


def _command_prefix(target, mode):
    if platform.system() != "Darwin":
        raise VerificationError("app-engine runtime verification requires macOS")

    host = _normalized_architecture(platform.machine())
    expected = package.ARCHITECTURES[target]
    if mode == "native":
        if host != expected:
            raise VerificationError(
                f"native {target} verification requires {expected}, found {host}"
            )
        return []

    if target != "macos_x86_64" or host != "arm64":
        raise VerificationError("Rosetta verification requires macos_x86_64 on an arm64 host")
    arch = shutil.which("arch")
    if arch is None:
        raise VerificationError("Rosetta verification requires the macOS arch command")
    return [arch, "-x86_64"]


def _normalized_architecture(value):
    aliases = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x86_64", "amd64": "x86_64"}
    try:
        return aliases[value.lower()]
    except (AttributeError, KeyError) as error:
        raise VerificationError(f"unsupported host architecture: {value}") from error


def _temporary_parent(value):
    parent = Path(value or os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()).expanduser().resolve()
    if not parent.is_dir():
        raise VerificationError("temporary parent must be an existing directory")
    return parent


def _validated_manifest(release_root, target, version, expected_source_commit):
    try:
        return package.validate_release(
            release_root, target, version, expected_source_commit
        )
    except package.PackageError as error:
        raise VerificationError(str(error)) from error


def _runtime_environment(runtime_root, scratch):
    home = runtime_root / "home"
    fermix_home = home / ".fermix"
    release_tmp = scratch / "release-tmp"
    home.mkdir(mode=0o700)
    fermix_home.mkdir(mode=0o700)
    release_tmp.mkdir(mode=0o700)
    _write_smoke_config(fermix_home)

    environment = {
        "HOME": str(home),
        "FERMIX_HOME": str(fermix_home),
        "OPENAI_API_KEY": SMOKE_OPENAI_API_KEY,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "PORT": str(_available_port()),
        "RELEASE_TMP": str(release_tmp),
        "TMPDIR": str(runtime_root),
        "USER": _current_user(),
    }
    return fermix_home, environment


def _current_user():
    try:
        user = pwd.getpwuid(os.geteuid()).pw_name
    except (KeyError, OSError) as error:
        raise VerificationError("cannot resolve the smoke runtime user") from error
    if not user:
        raise VerificationError("cannot resolve the smoke runtime user")
    return user


def _write_smoke_config(fermix_home):
    path = fermix_home / "config.toml"
    try:
        with path.open("x", encoding="utf-8") as stream:
            stream.write(SMOKE_CONFIG)
        path.chmod(0o600)
    except OSError as error:
        raise VerificationError(f"cannot write smoke runtime config: {error}") from error


def _available_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def _await_ready(process, fermix_home, environment, manifest, timeouts, log_path):
    daemon_socket = fermix_home / "daemon.sock"
    realtime_socket = fermix_home / "realtime.sock"
    daemon_ready = False
    realtime_ready = False
    health_ready = False

    for _attempt in range(timeouts.startup_attempts):
        code = process.poll()
        if code is not None:
            excerpt = _log_excerpt(log_path)
            raise VerificationError(f"app engine exited during startup with code {code}: {excerpt}")
        daemon_ready = _unix_socket(daemon_socket)
        realtime_ready = _unix_socket(realtime_socket)
        if not health_ready:
            health_ready = _health_live(environment, manifest, timeouts)
        if daemon_ready and realtime_ready and health_ready:
            return
        time.sleep(timeouts.poll_interval_seconds)

    excerpt = _log_excerpt(log_path)
    raise VerificationError(
        "app engine did not become live before the startup deadline: "
        f"daemon_socket={str(daemon_ready).lower()} "
        f"realtime_socket={str(realtime_ready).lower()} "
        f"health={str(health_ready).lower()}: {excerpt}"
    )


def _unix_socket(path):
    try:
        return stat.S_ISSOCK(path.stat().st_mode)
    except FileNotFoundError:
        return False
    except OSError as error:
        raise VerificationError(f"cannot inspect runtime socket {path.name}: {error}") from error


def _health_live(environment, manifest, timeouts):
    url = f"http://127.0.0.1:{environment['PORT']}/health/live"
    try:
        with urllib.request.urlopen(url, timeout=timeouts.health_timeout_seconds) as response:
            if response.status != 200:
                return False
            payload = json.loads(response.read(MAX_FRAME_BYTES + 1))
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return False

    if not isinstance(payload, dict):
        return False

    identity = manifest["identity"]
    return payload.get("status") == "ok" and payload.get("app") == "fermix" and payload.get(
        "version"
    ) == identity["product_version"]


def _management_hello(socket_path, protocol_version, timeouts):
    request_id = "release-smoke"
    request = {
        "request_id": request_id,
        "protocol_version": protocol_version,
        "method": "hello",
        "params": {},
    }
    payload = json.dumps(request, separators=(",", ":")).encode("utf-8")

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeouts.management_timeout_seconds)
            connection.connect(str(socket_path))
            connection.sendall(struct.pack(">I", len(payload)) + payload)
            size = struct.unpack(">I", _recv_exact(connection, 4))[0]
            if size > MAX_FRAME_BYTES:
                raise VerificationError("management hello response exceeds the frame limit")
            response = json.loads(_recv_exact(connection, size))
    except (OSError, json.JSONDecodeError, struct.error) as error:
        raise VerificationError(f"management hello failed: {error}") from error

    if not isinstance(response, dict) or set(response) != {"request_id", "result"}:
        raise VerificationError("management hello returned an invalid response envelope")
    if response["request_id"] != request_id or not isinstance(response["result"], dict):
        raise VerificationError("management hello did not correlate its response")
    return response["result"]


def _recv_exact(connection, size):
    chunks = []
    remaining = size
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise VerificationError("management connection closed before the response completed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _validate_runtime_identity(result, manifest, process_pid, environment):
    if set(result) != {"protocol", "capabilities", "engine", "setup"}:
        raise VerificationError("management hello returned unexpected result fields")
    if result["protocol"] != manifest["protocols"]["management"]:
        raise VerificationError("management protocol range contradicts the engine manifest")

    capabilities = result["capabilities"]
    if not isinstance(capabilities, dict) or set(capabilities) != {"methods"}:
        raise VerificationError("management hello returned invalid capabilities")
    methods = capabilities["methods"]
    if not isinstance(methods, list) or "hello" not in methods or not all(isinstance(item, str) for item in methods):
        raise VerificationError("management hello does not advertise hello")

    engine = result["engine"]
    expected_identity = manifest["identity"]
    if not isinstance(engine, dict) or set(engine) != {*expected_identity, "pid"}:
        raise VerificationError("management hello returned invalid engine identity fields")
    for key, expected in expected_identity.items():
        if engine[key] != expected:
            raise VerificationError(f"management engine identity mismatch: {key}")
    if engine["pid"] != str(process_pid):
        raise VerificationError("management engine PID does not match the launched process")

    setup = result["setup"]
    expected_setup = {"origin": f"http://127.0.0.1:{environment['PORT']}", "path": "/setup"}
    if setup != expected_setup:
        raise VerificationError("management setup endpoint contradicts the smoke runtime")
    return engine


def _stop_engine(command, release_root, environment, timeouts):
    try:
        result = subprocess.run(
            command,
            cwd=release_root,
            env=environment,
            text=True,
            capture_output=True,
            timeout=timeouts.stop_timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise VerificationError("app-engine stop command exceeded its deadline") from error
    if result.returncode != 0:
        raise VerificationError(f"app-engine stop command failed with code {result.returncode}")


def _await_exit(process, timeouts, log_path):
    for _attempt in range(timeouts.shutdown_attempts):
        code = process.poll()
        if code is not None:
            if code != 0:
                excerpt = _log_excerpt(log_path)
                raise VerificationError(f"app engine exited with code {code}: {excerpt}")
            return
        time.sleep(timeouts.poll_interval_seconds)
    raise VerificationError("app engine did not exit before the shutdown deadline")


def _verify_socket_cleanup(fermix_home):
    for name in ("daemon.sock", "realtime.sock"):
        path = fermix_home / name
        if os.path.lexists(path):
            raise VerificationError(f"{name} remained after app-engine shutdown")


def _force_cleanup(process, timeouts):
    if process is None or process.poll() is not None:
        return None
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=timeouts.cleanup_timeout_seconds)
        return None
    except ProcessLookupError:
        return None
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=timeouts.cleanup_timeout_seconds)
            return None
        except (OSError, subprocess.SubprocessError) as error:
            return str(error)
    except OSError as error:
        return str(error)


def _log_excerpt(path):
    try:
        with path.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            size = stream.tell()
            stream.seek(max(0, size - 4_096))
            return stream.read().decode("utf-8", errors="replace").strip() or "no log output"
    except OSError as error:
        return f"log unavailable: {error}"


def _arguments(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    parser.add_argument("target", choices=sorted(package.ARCHITECTURES))
    parser.add_argument("version")
    parser.add_argument("source_commit")
    parser.add_argument("mode", choices=("native", "rosetta"))
    return parser.parse_args(argv)


def main(argv=None):
    args = _arguments(argv)
    try:
        result = verify_app_engine(
            args.archive,
            args.target,
            args.version,
            args.mode,
            expected_source_commit=args.source_commit,
        )
    except VerificationError as error:
        print(f"verify_app_engine.py: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
