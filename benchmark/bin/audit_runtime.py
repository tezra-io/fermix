"""Owned Docker lifecycle for a single audit target."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import selectors
import shutil
import subprocess
import time
from pathlib import Path
from tempfile import TemporaryDirectory, TemporaryFile, gettempdir
from threading import Lock


def _capture_ready(selector, sizes, chunks, limit, remaining):
    for key, _ in selector.select(remaining):
        data = os.read(key.fd, 65536)
        if not data:
            selector.unregister(key.fileobj)
            continue
        sizes[key.fileobj] += len(data)
        if sizes[key.fileobj] > limit:
            raise RuntimeError(f"command output limit exceeded: {limit} bytes")
        chunks[key.fileobj].append(data)


def _capture_loop(selector, process, deadline, timeout, limit, chunks, sizes):
    while selector.get_map():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(process.args, timeout)
        _capture_ready(selector, sizes, chunks, limit, remaining)


def _capture(process, timeout, limit):
    deadline = time.monotonic() + timeout
    chunks = {process.stdout: [], process.stderr: []}
    sizes = dict.fromkeys(chunks, 0)
    with selectors.DefaultSelector() as selector:
        for stream in chunks:
            selector.register(stream, selectors.EVENT_READ)
        _capture_loop(selector, process, deadline, timeout, limit, chunks, sizes)
    process.wait(timeout=max(0, deadline - time.monotonic()))
    return tuple(b"".join(chunks[stream]).decode(errors="replace")
                 for stream in (process.stdout, process.stderr))


def _run_process(args, stdin, timeout, max_output, include_stderr):
    with subprocess.Popen(args, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        try:
            stdout, stderr = _capture(process, timeout, max_output)
        except (RuntimeError, subprocess.TimeoutExpired):
            process.kill()
            process.wait()
            raise
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, args, stdout, stderr)
        return (stdout, stderr) if include_stderr else stdout


def run(args, *, timeout=30, input=None, max_output=4 * 1024 * 1024, include_stderr=False):
    if timeout <= 0 or max_output <= 0:
        raise ValueError("timeout and output limit must be positive")
    with TemporaryFile() as stdin:
        if input is not None:
            stdin.write(input.encode())
            stdin.seek(0)
        return _run_process(args, stdin, timeout, max_output, include_stderr)


def _copy_build_inputs(repo, tmp, entries, digest):
    for source, target in sorted(entries):
        path = repo / source
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"non-regular build input: {source}")
        destination = Path(tmp) / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        digest.update(target.encode() + b"\0" + hashlib.sha256(destination.read_bytes()).digest())


def policy_source_hashes(root):
    paths = ('apps/fermix_core/lib/fermix_core/capabilities/builtin.ex',
             'apps/fermix_core/lib/fermix_core/capabilities/capability.ex')
    return {path: hashlib.sha256((Path(root) / path).read_bytes()).hexdigest() for path in paths}


def build_image(repo, image):
    """Build from tracked source and return the exact context hash and image ID."""
    repo = Path(repo).resolve(strict=True)
    # Docker Desktop's local image store and the temporary source context share
    # the host volume in the qualified setup. Eight GiB reserves room for the
    # BEAM toolchain, Chromium, dependency compilation and intermediate layers.
    # This checks the temp filesystem; a separately located Docker store must
    # independently have enough space.
    required = 8 * 1024 ** 3
    available = shutil.disk_usage(gettempdir()).free
    if available < required:
        raise RuntimeError(f"insufficient build space: required {required} bytes, available {available} bytes")
    commit = run(["git", "-C", str(repo), "rev-parse", "HEAD"]).strip()
    paths = run(["git", "-C", str(repo), "ls-files", "-z", "apps", "config",
                 "mix.exs", "mix.lock", "rel"], timeout=30).split("\0")
    additions = {"benchmark/bin/fermix-shim": "fermix-shim",
                 "benchmark/audit/docker/Dockerfile": "Dockerfile",
                 "benchmark/audit/docker/audit_bootstrap.py": "audit_bootstrap.py",
                 "benchmark/audit/docker/audit_foreground.py": "audit_foreground.py",
                 "benchmark/audit/docker/audit_observer.exs": "benchmark/audit/docker/audit_observer.exs",
                 "benchmark/audit/docker/audit_observer_launch.exs": "benchmark/audit/docker/audit_observer_launch.exs"}
    entries = [(p, p) for p in paths if p] + list(additions.items())
    digest = hashlib.sha256()
    with TemporaryDirectory(prefix="fermix-audit-build-") as tmp:
        _copy_build_inputs(repo, tmp, entries, digest)
        policy_sources = policy_source_hashes(tmp)
        try:
            run(["docker", "build", "--tag", image, tmp], timeout=1800)
        except subprocess.CalledProcessError as error:
            raise RuntimeError(f"audit image build failed: {error.stderr}") from error
    identity = run(["docker", "image", "inspect", "--format", "{{.Id}}", image]).strip()
    return {"source_commit": commit, "context_sha256": digest.hexdigest(), "image_id": identity,
            "policy_sources": policy_sources}


def _redact_json_line(line, redact_values):
    normalized = json.dumps(json.loads(line), ensure_ascii=False)
    for secret in redact_values:
        normalized = normalized.replace(json.dumps(secret, ensure_ascii=False)[1:-1], "[REDACTED]")
    return normalized


def _memory_review_closed(logs, chat_id, run_id):
    seq = 0
    for line in logs.splitlines():
        if not line.startswith("FERMIX_AUDIT_TRACE "):
            continue
        record = json.loads(line.removeprefix("FERMIX_AUDIT_TRACE "))
        if not isinstance(record, dict) or record.get("run_id") != run_id or record.get("seq") != seq + 1:
            raise ValueError("invalid or discontinuous observer record while waiting for memory review")
        seq += 1
        data = record.get("data")
        if (record.get("kind") == "event" and record.get("type") == "agent_event" and isinstance(data, dict)
                and data.get("event") == "memory_review" and data.get("channel") == "cli"
                and data.get("chat_id") == chat_id):
            return True
    return False


class AuditRuntime:
    def __init__(self, run_id, image, owner=None):
        if not re.fullmatch(r"[a-f0-9]{32}", run_id):
            raise ValueError("run_id must be 32 lowercase hex characters")
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.:/@-]*", image):
            raise ValueError("invalid image reference")
        self.run_id = run_id
        self.image = image
        self.network = f"fermix-audit-{run_id}"
        self.target = f"{self.network}-target"
        self.volume = f"{self.network}-home"
        self.client = f"{self.network}-client"
        self.initializer = f"{self.network}-initializer"
        self.owner = owner or secrets.token_hex(16)
        if not re.fullmatch(r"[a-f0-9]{32}", self.owner):
            raise ValueError("owner must be 32 lowercase hex characters")
        self.owner_label = f"fermix.audit.owner={self.owner}"
        self.label = f"fermix.audit.run={run_id}"
        self._client_lock = Lock()

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc, traceback):
        try:
            self.cleanup()
        except (ExceptionGroup, RuntimeError) as cleanup_error:
            if exc is None:
                raise
            raise BaseExceptionGroup("episode and cleanup failed", [exc, cleanup_error]) from exc

    def start(self):
        try:
            run(["docker", "volume", "create", "--label", self.label, "--label", self.owner_label, self.volume])
            labels = json.loads(run(["docker", "volume", "inspect", "--format", "{{json .Labels}}", self.volume]))
            if not isinstance(labels, dict) or (labels.get("fermix.audit.run") != self.run_id or labels.get("fermix.audit.owner") != self.owner):
                raise RuntimeError("refusing foreign home volume")
            run(["docker", "network", "create", "--internal", "--opt",
                 "com.docker.network.bridge.gateway_mode_ipv4=isolated",
                 "--label", self.label, "--label", self.owner_label, self.network])
            run(["docker", "create", "--name", self.target, "--label", self.label,
                 "--label", self.owner_label, "--network", self.network, "--init", "--cap-drop", "ALL",
                 "--mount", f"type=volume,src={self.volume},dst=/home/audit/fermix",
                 "--security-opt", "no-new-privileges",
                 "--security-opt", f"seccomp={Path(__file__).resolve().parents[1] / 'audit/docker/seccomp_audit.json'}",
                 "--shm-size", "256m", "--memory", "2g", "--cpus", "2", "--pids-limit", "512",
                 "--env", f"FERMIX_AUDIT_RUN_ID={self.run_id}",
                 self.image, "python3", "/src/audit_foreground.py"])
        except BaseException as error:
            try:
                self.cleanup()
            except ExceptionGroup as cleanup_error:
                raise BaseExceptionGroup("startup and cleanup failed", [error, cleanup_error]) from error
            raise

    def bootstrap(self, model, proxy_url, token):
        if not model or not token or not re.fullmatch(r"http://[a-z0-9-]+:[0-9]+/v1", proxy_url):
            raise ValueError("model, run token and internal proxy URL are required")
        payload = json.dumps({"model": model, "proxy_url": proxy_url, "token": token, "run_id": self.run_id})
        args = ["docker", "run", "--rm", "-i", "--name", self.initializer,
                "--label", self.label, "--label", self.owner_label, "--network", "none",
                "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                "--mount", f"type=volume,src={self.volume},dst=/home/audit/fermix",
                self.image, "python3", "/src/audit_bootstrap.py"]
        try:
            output = run(args, input=payload, timeout=30)
        except BaseException as error:
            try:
                self._remove_owned("container", self.initializer)
            except (OSError, subprocess.SubprocessError, ValueError, TypeError, RuntimeError) as cleanup_error:
                raise BaseExceptionGroup("initializer and cleanup failed", [error, cleanup_error]) from error
            raise
        self._remove_owned("container", self.initializer)
        result = json.loads(output)
        if not re.fullmatch(r"[a-f0-9]{64}", result.get("config_sha256", "")):
            raise ValueError("bootstrap did not return a config hash")
        run(["docker", "start", self.target], timeout=30)
        return result

    def _client(self, command, *, input=None, timeout=30):
        if timeout <= 0 or not self._client_lock.acquire(timeout=timeout):
            raise TimeoutError("another trusted client is active")
        try:
            return self._run_client(command, input=input, timeout=timeout)
        finally:
            self._client_lock.release()

    def _run_client(self, command, *, input, timeout):
        args = ["docker", "run", "--rm", "-i", "--name", self.client, "--label", self.label,
                "--label", self.owner_label, "--network", "none", "--pid", f"container:{self.target}", "--cap-drop", "ALL",
                "--mount", f"type=volume,src={self.volume},dst=/home/audit/fermix",
                "--memory", "256m", "--cpus", "1", "--pids-limit", "64", self.image, *command]
        try:
            result = run(args, input=input, timeout=timeout)
        except BaseException as error:
            try:
                self._remove_owned("container", self.client)
            except (OSError, subprocess.SubprocessError, ValueError, TypeError, RuntimeError) as cleanup_error:
                raise BaseExceptionGroup("client and cleanup failed", [error, cleanup_error]) from error
            raise
        self._remove_owned("container", self.client)
        return result

    def _hello(self, timeout):
        script = Path(__file__).resolve().parents[2] / "scripts/dev/management_request.py"
        output = self._client(["python3", "-", "hello"], input=script.read_text(), timeout=timeout)
        response = json.loads(output)
        if "result" not in response or "engine" not in response["result"]:
            raise RuntimeError(f"daemon hello failed: {response}")
        return response

    def ready(self, timeout=120):
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        deadline = time.monotonic() + timeout
        last_error = "no response"
        while time.monotonic() < deadline:
            try:
                return self._hello(min(40, max(1, deadline - time.monotonic())))
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                last_error = str(error.stderr or error)
                time.sleep(min(1, max(0, deadline - time.monotonic())))
        raise TimeoutError(f"target daemon did not become ready: {last_error}")

    def ask(self, query, session, timeout):
        if not query or not session or timeout <= 0:
            raise ValueError("query, session and positive timeout are required")
        return self._client(["python3", "/src/fermix-shim", "ask",
                    "--json", "--session", session, "--timeout", str(timeout * 1000), query],
                   timeout=timeout + 15)

    def wait_for_memory_review(self, chat_id, timeout):
        """Wait for the post-turn memory review closer of this CLI conversation.

        A reply is not proof that post-turn work finished: the reviewer runs
        after the turn, so the checkpoint waits for its run closer instead of a
        fixed delay. Bounded by `timeout` seconds of real time.
        """
        if not isinstance(chat_id, str) or not chat_id or type(timeout) is not int or timeout <= 0:
            raise ValueError("chat ID and positive integer timeout are required")
        deadline = time.monotonic() + timeout
        for _ in range(timeout * 4):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            logs = run(["docker", "logs", self.target], timeout=min(10, max(1, remaining)),
                       max_output=48 * 1024 * 1024)
            if _memory_review_closed(logs, chat_id, self.run_id):
                return
            time.sleep(min(0.25, max(0, deadline - time.monotonic())))
        raise TimeoutError(f"post-turn memory review did not complete within {timeout} seconds")

    def collect_traces(self, evidence_root, *, redact_values):
        if not redact_values or any(not isinstance(value, str) or not value for value in redact_values):
            raise ValueError("nonempty trace redaction values are required")
        script = Path(__file__).resolve().parents[1] / "audit/docker/collect_traces.py"
        # -I keeps the target-writable working directory (/src) off sys.path.
        output = run(["docker", "exec", "-i", self.target, "python3", "-I", "-"],
                     input=script.read_text(), timeout=30, max_output=48 * 1024 * 1024)
        traces = json.loads(output)
        if not isinstance(traces, dict):
            raise TypeError("invalid trace collection")
        for name in traces:
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}/[a-z_]+(?:\.bodies)?\.jsonl", name):
                raise ValueError(f"unsafe trace path: {name}")
        destination = Path(evidence_root).resolve(strict=True) / self.run_id
        destination.mkdir(mode=0o700, exist_ok=False)
        for name, encoded in traces.items():
            path = destination / name
            path.parent.mkdir(mode=0o700, exist_ok=True)
            data = base64.b64decode(encoded, validate=True)
            path.write_text("".join(_redact_json_line(line, redact_values) + "\n" for line in data.splitlines()))
        return destination

    def versions(self):
        chromium = run(["docker", "exec", self.target, "chromium", "--version"]).strip()
        beam = run(["docker", "exec", self.target, "elixir", "--version"]).strip()
        if not chromium or not beam:
            raise RuntimeError("target version probe returned an empty result")
        return {"chromium": chromium, "beam": beam}

    def checkpoint(self, nonce):
        if not isinstance(nonce, str) or not re.fullmatch(r"[A-Za-z0-9]{16,128}", nonce):
            raise ValueError("checkpoint nonce must be 16–128 ASCII alphanumeric characters")
        script = Path(__file__).resolve().parents[1] / "audit/docker/audit_checkpoint.py"
        result = json.loads(self._client(["python3", "-", nonce], input=script.read_text(), timeout=10))
        if result.get("nonce") != nonce or type(result.get("seq")) is not int or result["seq"] < 2:
            raise ValueError("invalid observer checkpoint response")
        return result

    def stop(self):
        labels = json.loads(run(["docker", "container", "inspect", "--format", "{{json .Config.Labels}}", self.target]))
        if (not isinstance(labels, dict) or labels.get("fermix.audit.run") != self.run_id or
                labels.get("fermix.audit.owner") != self.owner):
            raise RuntimeError("refusing to stop foreign target")
        script = Path(__file__).resolve().parents[1] / "audit/docker/audit_shutdown.py"
        self._client(["python3", "-"], input=script.read_text(), timeout=10)
        result = run(["docker", "wait", self.target], timeout=20).strip()
        if result != "0":
            raise RuntimeError(f"daemon exited abnormally: exit_code={result}")
        self._assert_stopped()

    def _assert_stopped(self):
        state = json.loads(run(["docker", "inspect", "--format", "{{json .State}}", self.target]))
        if (state.get("Status") != "exited" or state.get("OOMKilled") is not False or
                state.get("ExitCode") != 0 or state.get("Error")):
            raise ValueError(f"target did not stop cleanly: status={state.get('Status')}, "
                             f"exit_code={state.get('ExitCode')}, oom_killed={state.get('OOMKilled')}, "
                             f"docker_error={bool(state.get('Error'))}")

    def collect_observer(self, evidence_dir, *, checkpoint, redact_values):
        if not redact_values or any(not isinstance(value, str) or not value for value in redact_values):
            raise ValueError("nonempty observer redaction values are required")
        if (not isinstance(checkpoint, dict) or not re.fullmatch(r"[A-Za-z0-9]{16,128}", checkpoint.get("nonce", ""))
                or type(checkpoint.get("seq")) is not int or checkpoint["seq"] < 2):
            raise ValueError("invalid observer checkpoint")
        self._assert_stopped()
        output, stderr = run(["docker", "logs", self.target], timeout=30,
                             max_output=48 * 1024 * 1024, include_stderr=True)
        if any("FERMIX_AUDIT_OBSERVER_FAILURE" in stream for stream in (output, stderr)):
            raise ValueError("observer failure marker found in Docker logs")
        records = []
        for line in output.splitlines():
            if not line.startswith("FERMIX_AUDIT_TRACE "):
                continue
            record = json.loads(line.removeprefix("FERMIX_AUDIT_TRACE "))
            if (not isinstance(record, dict) or type(record.get("version")) is not int or
                    record.get("version") != 1 or type(record.get("seq")) is not int or
                    record.get("run_id") != self.run_id or record.get("seq") != len(records) + 1):
                raise ValueError("invalid or discontinuous observer record")
            kind = record.get("kind")
            if kind not in ("start", "event", "checkpoint") or len(records) >= 100000:
                raise ValueError("observer reported an error or exceeded its record limit")
            if kind == "start" and records:
                raise ValueError("observer emitted a duplicate start")
            if kind == "event" and not all(key in record for key in ("type", "agent", "data")):
                raise ValueError("observer event is malformed")
            records.append(record)
        if not records or records[0].get("kind") != "start":
            raise ValueError("observer start record is missing")
        index = checkpoint["seq"] - 1
        if (index >= len(records) or records[index].get("kind") != "checkpoint" or
                records[index].get("nonce") != checkpoint["nonce"]):
            raise ValueError("observer checkpoint is missing or mismatched")
        path = Path(evidence_dir).resolve(strict=True) / "observer.jsonl"
        with path.open("x", encoding="utf-8") as stream:
            for record in records:
                stream.write(_redact_json_line(json.dumps(record), redact_values) + "\n")
        return path

    def cleanup(self):
        errors = []
        for kind, name in (("container", self.initializer), ("container", self.client), ("container", self.target),
                           ("network", self.network), ("volume", self.volume)):
            try:
                self._remove_owned(kind, name)
            except (OSError, subprocess.SubprocessError, ValueError, TypeError, RuntimeError) as error:
                errors.append(error)
        if errors:
            raise ExceptionGroup("audit cleanup failed", errors)

    def _remove_owned(self, kind, name):
        try:
            labels = run(["docker", kind, "inspect", "--format", "{{json .Config.Labels}}"
                          if kind == "container" else "{{json .Labels}}", name])
        except subprocess.CalledProcessError as error:
            if "No such" in (error.stderr or "") or (kind in ("network", "volume") and "not found" in (error.stderr or "")):
                return
            raise
        if (json.loads(labels).get("fermix.audit.run") != self.run_id or
                json.loads(labels).get("fermix.audit.owner") != self.owner):
            raise RuntimeError(f"refusing to remove foreign {kind}: {name}")
        command = ["docker", "rm", "-f", name] if kind == "container" else ["docker", kind, "rm", name]
        run(command, timeout=30)
