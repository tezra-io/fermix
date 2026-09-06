#!/usr/bin/env python3
"""Fake app-engine runtime used only by release verifier tests."""

import http.server
import json
import os
import signal
import socket
import struct
import sys
import threading
from pathlib import Path

RELEASE_ROOT = Path(__file__).resolve().parent.parent
CONTROL_ROOT = RELEASE_ROOT / "test-controls"


def controlled(name):
    return (CONTROL_ROOT / name).exists()


def load_manifest():
    with (RELEASE_ROOT / "engine-manifest.json").open(encoding="utf-8") as stream:
        return json.load(stream)


def recv_exact(connection, size):
    chunks = []
    remaining = size
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise RuntimeError("management client closed early")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


class Health(http.server.BaseHTTPRequestHandler):
    product_version = None

    def do_GET(self):
        if self.path != "/health/live":
            self.send_response(404)
            self.end_headers()
            return
        payload = json.dumps(
            {"status": "ok", "app": "fermix", "version": self.product_version}
        ).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format, *_args):
        return


FAKE_LEASE = "lease-fake-engine"


def management_response(request, manifest, port, stopping):
    method = request.get("method")
    if method == "lifecycle.prepare":
        result = {"lease_id": FAKE_LEASE, "ttl_ms": 30000}
    elif method == "lifecycle.commit":
        if request.get("params", {}).get("lease_id") != FAKE_LEASE:
            result = {"error": {"code": "unknown_lease"}}
        else:
            result = {"lease_id": FAKE_LEASE, "status": "committed"}
            stopping.set()
    else:
        engine = dict(manifest["identity"])
        engine["pid"] = str(os.getpid())
        result = {
            "protocol": manifest["protocols"]["management"],
            "capabilities": {
                "methods": [
                    "hello",
                    "overview.get",
                    "setup.session.create",
                    "lifecycle.prepare",
                    "lifecycle.commit",
                ]
            },
            "engine": engine,
            "setup": {"origin": f"http://127.0.0.1:{port}", "path": "/setup"},
        }
    return {"request_id": request["request_id"], "result": result}


def management_loop(listener, stopping, manifest, port):
    listener.settimeout(0.1)
    while not stopping.is_set():
        try:
            connection, _address = listener.accept()
        except socket.timeout:
            continue
        with connection:
            size = struct.unpack(">I", recv_exact(connection, 4))[0]
            request = json.loads(recv_exact(connection, size))
            response = management_response(request, manifest, port, stopping)
            payload = json.dumps(response, separators=(",", ":")).encode()
            connection.sendall(struct.pack(">I", len(payload)) + payload)


def wait_without_runtime():
    stopping = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_args: stopping.set())
    print("waiting-for-test", flush=True)
    stopping.wait()


def validate_environment(home):
    with (home / "config.toml").open(encoding="utf-8") as stream:
        config = stream.read()
    if "[fermix_core.realtime]" not in config or "enabled = true" not in config:
        raise RuntimeError("smoke realtime config is missing")
    if os.environ.get("OPENAI_API_KEY") != "fermix-release-smoke-not-a-real-key":
        raise RuntimeError("smoke OpenAI credential is not isolated")
    if "FERMIX_OPIK_ENABLED" in os.environ:
        raise RuntimeError("FERMIX_OPIK_ENABLED leaked into the smoke engine")


def unix_listener(path):
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(str(path))
        listener.listen()
        return listener
    except BaseException:
        listener.close()
        raise


def remove_runtime_paths(daemon_path, realtime_path, pid_path, has_realtime):
    if controlled("stale-socket") and daemon_path.exists():
        daemon_path.unlink()
        daemon_path.write_text("stale", encoding="utf-8")
    else:
        daemon_path.unlink(missing_ok=True)
    if has_realtime:
        realtime_path.unlink(missing_ok=True)
    pid_path.unlink(missing_ok=True)


def run_runtime(home, port, manifest):
    daemon_path = home / "daemon.sock"
    realtime_path = home / "realtime.sock"
    pid_path = home / "fake-engine.pid"
    daemon = unix_listener(daemon_path)
    realtime = None
    server = None
    stopping = threading.Event()
    try:
        if not controlled("no-realtime"):
            realtime = unix_listener(realtime_path)
        Health.product_version = manifest["identity"]["product_version"]
        server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Health)
        signal.signal(signal.SIGTERM, lambda *_args: stopping.set())
        signal.signal(signal.SIGINT, lambda *_args: stopping.set())
        threading.Thread(
            target=management_loop,
            args=(daemon, stopping, manifest, port),
            daemon=True,
        ).start()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        pid_path.write_text(str(os.getpid()), encoding="utf-8")
        stopping.wait()
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
        daemon.close()
        if realtime is not None:
            realtime.close()
        remove_runtime_paths(
            daemon_path, realtime_path, pid_path, realtime is not None
        )


def start():
    if "FERMIX_OPIK_ENABLED" in os.environ:
        raise RuntimeError("FERMIX_OPIK_ENABLED leaked into the smoke engine")
    if controlled("no-ready"):
        wait_without_runtime()
        return
    home = Path(os.environ["FERMIX_HOME"])
    validate_environment(home)
    home.mkdir(mode=0o700, exist_ok=True)
    run_runtime(home, int(os.environ["PORT"]), load_manifest())


def stop():
    pid_path = Path(os.environ["FERMIX_HOME"]) / "fake-engine.pid"
    os.kill(int(pid_path.read_text(encoding="utf-8")), signal.SIGTERM)


def main(argv):
    if argv == ["start"]:
        start()
        return 0
    if argv == ["stop"]:
        stop()
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
