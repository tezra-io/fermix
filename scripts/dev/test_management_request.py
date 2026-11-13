#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for scripts/dev/management_request.py, the dev management client.

Nothing here reaches a real daemon: each case serves a fake `daemon.sock` from a
temporary FERMIX_HOME this test owns, answering the packet-4 frames the way the
daemon's version gate does (`apps/fermix_core/priv/management/PROTOCOL.md`,
"Versioning" and "Direction of an unsupported version"), and records every
request with the connection it came on. The fake offers a window whose ceiling
is above today's, so a script that stamps a fixed version instead of the one
the daemon offers is caught.
"""

import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().with_name("management_request.py")
# A UNIX socket path is capped near 104 bytes on macOS, and a macOS TMPDIR
# alone is about 50, so the fake home lives under /tmp.
SHORT_TMP = "/tmp"
RUN_TIMEOUT_S = 30
ACCEPT_TIMEOUT_S = 30


def read_frame(conn):
    header = conn.recv(4, socket.MSG_WAITALL)
    if len(header) != 4:
        raise ConnectionError("no frame header")
    (length,) = struct.unpack(">I", header)
    body = conn.recv(length, socket.MSG_WAITALL)
    if len(body) != length:
        raise ConnectionError("frame cut short")
    return json.loads(body)


def write_frame(conn, message):
    body = json.dumps(message).encode("utf-8")
    conn.sendall(struct.pack(">I", len(body)) + body)


class FakeDaemon:
    """One request per connection, answered as the daemon's version gate answers it."""

    def __init__(self, path, minimum, maximum, method_minimums, hello_error=None):
        self.path = path
        self.minimum = minimum
        self.maximum = maximum
        self.method_minimums = method_minimums
        self.hello_error = hello_error
        self.requests = []
        self.stopping = threading.Event()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(8)
        # The bound on a wait for a client that never comes; close() wakes the
        # accept with a connection of its own rather than waiting this out.
        self.server.settimeout(ACCEPT_TIMEOUT_S)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def close(self):
        self.stopping.set()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as waker:
            waker.connect(self.path)
        self.thread.join(ACCEPT_TIMEOUT_S)
        self.server.close()

    def _serve(self):
        while True:
            try:
                conn, _address = self.server.accept()
            except OSError:
                return
            with conn:
                if self.stopping.is_set():
                    return
                request = read_frame(conn)
                self.requests.append(request)
                write_frame(conn, self._answer(request))

    def _answer(self, request):
        version = request["protocol_version"]
        reply = {"request_id": request["request_id"]}
        window = {"minimum_version": self.minimum, "maximum_version": self.maximum}
        method = request["method"]
        if version < self.minimum:
            reply["error"] = {"code": "client_too_old", "message": "old", "details": window}
        elif version > self.maximum:
            reply["error"] = {"code": "daemon_too_old", "message": "new", "details": window}
        elif method == "hello" and self.hello_error is not None:
            reply["error"] = {"code": self.hello_error, "message": "no hello here"}
        elif version < self.method_minimums.get(method, 1):
            requires = self.method_minimums[method]
            reply["error"] = {"code": "method_not_found", "message": "gated", "details": {"requires": requires}}
        elif method == "hello":
            protocol = {"current_version": self.maximum, **window}
            reply["result"] = {"protocol": protocol, "engine": {"version": "9.9.9"}}
        else:
            reply["result"] = {"method": method, "params": request.get("params", {}), "served_at": version}
        return reply


class ManagementRequestTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="fxmr-", dir=SHORT_TMP)
        self.addCleanup(shutil.rmtree, self.home)
        self.socket_path = os.path.join(self.home, "daemon.sock")

    def _daemon(self, minimum=1, maximum=3, method_minimums=None, hello_error=None):
        daemon = FakeDaemon(self.socket_path, minimum, maximum, method_minimums or {}, hello_error)
        self.addCleanup(daemon.close)
        return daemon

    def _run(self, *args, stdin_script=False):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "FERMIX_HOME": self.home}
        if stdin_script:
            # How benchmark/bin/audit_runtime.py runs it: `python3 - hello`.
            argv = [sys.executable, "-", *args]
            text = SCRIPT.read_text(encoding="utf-8")
        else:
            argv = [sys.executable, str(SCRIPT), *args]
            text = None
        return subprocess.run(argv, input=text, capture_output=True, text=True, env=env, timeout=RUN_TIMEOUT_S, check=False)

    @staticmethod
    def _sent(daemon):
        return [(request["method"], request["protocol_version"]) for request in daemon.requests]

    def test_says_hello_at_1_then_sends_the_method_at_the_offered_maximum(self):
        daemon = self._daemon(method_minimums={"settings.sections": 3})

        result = self._run("settings.sections")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._sent(daemon), [("hello", 1), ("settings.sections", 3)])
        reply = json.loads(result.stdout)
        self.assertEqual(reply["result"], {"method": "settings.sections", "params": {}, "served_at": 3})
        self.assertEqual(reply["request_id"], daemon.requests[1]["request_id"])

    def test_each_request_has_its_own_connection_and_its_own_id(self):
        daemon = self._daemon()

        result = self._run("logs.query", '{"limit": 20}')

        self.assertEqual(result.returncode, 0, result.stderr)
        # The fake answers one request per connection: two answered requests
        # are two connections.
        self.assertEqual(len(daemon.requests), 2)
        self.assertNotEqual(daemon.requests[0]["request_id"], daemon.requests[1]["request_id"])
        self.assertEqual(daemon.requests[1]["params"], {"limit": 20})
        self.assertEqual(daemon.requests[0]["params"], {})

    def test_prints_only_the_final_reply(self):
        daemon = self._daemon()

        result = self._run("hello")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._sent(daemon), [("hello", 1), ("hello", 3)])
        # One JSON document and nothing else: the reply to the second hello.
        reply = json.loads(result.stdout)
        self.assertEqual(reply["request_id"], daemon.requests[1]["request_id"])
        self.assertEqual(reply["result"]["protocol"]["maximum_version"], 3)

    def test_reads_the_window_from_a_client_too_old_refusal(self):
        daemon = self._daemon(minimum=2, maximum=3)

        result = self._run("overview.get")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._sent(daemon), [("hello", 1), ("overview.get", 3)])
        self.assertEqual(json.loads(result.stdout)["result"]["served_at"], 3)

    def test_runs_from_stdin_as_the_audit_harness_runs_it(self):
        daemon = self._daemon()

        result = self._run("hello", stdin_script=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._sent(daemon), [("hello", 1), ("hello", 3)])
        self.assertIn("engine", json.loads(result.stdout)["result"])

    def test_a_hello_that_fails_otherwise_stops_before_the_request(self):
        daemon = self._daemon(hello_error="internal_error")

        result = self._run("overview.get")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self._sent(daemon), [("hello", 1)])
        self.assertEqual(result.stdout, "")
        self.assertIn("internal_error", result.stderr)

    def test_refuses_without_a_daemon_socket(self):
        result = self._run("hello")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("no daemon socket", result.stderr)


if __name__ == "__main__":
    unittest.main()
