#!/usr/bin/env python3
"""Stop a running Fermix app engine over its management socket.

The app-engine release runs with Erlang distribution off (no epmd), so the
generated release's rpc-based `bin/fermix_app_engine stop` cannot reach it.
The management lifecycle is the sanctioned stop path — the same one the macOS
app uses: lifecycle.prepare mints the single drain lease, lifecycle.commit
runs the daemon's shutdown path.

Usage:
    FERMIX_HOME=~/.fermix-apptest python3 scripts/dev/engine_stop.py
"""

import json
import os
import socket
import struct
import sys
import uuid

MAX_FRAME = 4 * 1024 * 1024


def fail(message):
    print(f"engine_stop.py: {message}", file=sys.stderr)
    sys.exit(1)


def request(path, method, params):
    frame = json.dumps(
        {
            "request_id": f"stop-{uuid.uuid4().hex[:12]}",
            "protocol_version": 1,
            "method": method,
            "params": params,
        }
    ).encode("utf-8")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(15.0)
        sock.connect(path)
        sock.sendall(struct.pack(">I", len(frame)) + frame)
        header = sock.recv(4, socket.MSG_WAITALL)
        if len(header) != 4:
            fail("connection closed before a response header arrived")
        (length,) = struct.unpack(">I", header)
        if length > MAX_FRAME:
            fail("response exceeds the frame ceiling")
        body = b""
        while len(body) < length:
            chunk = sock.recv(length - len(body))
            if not chunk:
                fail("connection closed mid-response")
            body += chunk
    return json.loads(body)["result"]


def main():
    home = os.environ.get("FERMIX_HOME")
    if not home:
        fail("FERMIX_HOME is required (it names the daemon.sock to stop)")
    path = os.path.join(os.path.expanduser(home), "daemon.sock")
    if not os.path.exists(path):
        fail(f"no daemon socket at {path} — nothing to stop")

    lease = request(path, "lifecycle.prepare", {}).get("lease_id")
    if not lease:
        fail("lifecycle.prepare returned no lease")
    committed = request(path, "lifecycle.commit", {"lease_id": lease})
    if committed.get("status") != "committed":
        fail(f"lifecycle.commit did not commit: {committed}")
    print("engine_stop.py: shutdown committed")


if __name__ == "__main__":
    main()
