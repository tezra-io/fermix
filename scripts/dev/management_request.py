#!/usr/bin/env python3
"""Send one management v1 request to a running Fermix daemon and print the reply.

Dev tool for exercising the app-facing management plane without the macOS app.
Speaks the packet-4 framing (4-byte big-endian length prefix + JSON) documented
in apps/fermix_core/priv/management/PROTOCOL.md.

Usage:
    python3 scripts/dev/management_request.py <method> [params-json]

The socket is resolved from $FERMIX_HOME/daemon.sock (FERMIX_HOME required).

Examples:
    FERMIX_HOME=~/.fermix-apptest python3 scripts/dev/management_request.py hello
    FERMIX_HOME=~/.fermix-apptest python3 scripts/dev/management_request.py overview.get
    FERMIX_HOME=~/.fermix-apptest python3 scripts/dev/management_request.py setup.session.create
    FERMIX_HOME=~/.fermix-apptest python3 scripts/dev/management_request.py doctor.start '{"scope":"local"}'
    FERMIX_HOME=~/.fermix-apptest python3 scripts/dev/management_request.py logs.query '{"limit":20}'
"""

import json
import os
import socket
import struct
import sys
import uuid

MAX_FRAME = 4 * 1024 * 1024


def fail(message: str) -> None:
    print(f"management_request.py: {message}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        fail(f"usage: {sys.argv[0]} <method> [params-json]")

    method = sys.argv[1]
    try:
        params = json.loads(sys.argv[2]) if len(sys.argv) == 3 else {}
    except json.JSONDecodeError as error:
        fail(f"params is not valid JSON: {error}")

    home = os.environ.get("FERMIX_HOME")
    if not home:
        fail("FERMIX_HOME is required (it names the daemon.sock to talk to)")
    path = os.path.join(os.path.expanduser(home), "daemon.sock")
    if not os.path.exists(path):
        fail(f"no daemon socket at {path} — is the daemon running?")

    frame = json.dumps(
        {
            "request_id": f"dev-{uuid.uuid4().hex[:12]}",
            "protocol_version": 1,
            "method": method,
            "params": params,
        }
    ).encode("utf-8")

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(35.0)
        sock.connect(path)
        sock.sendall(struct.pack(">I", len(frame)) + frame)
        header = sock.recv(4, socket.MSG_WAITALL)
        if len(header) != 4:
            fail("connection closed before a response header arrived")
        (length,) = struct.unpack(">I", header)
        if length > MAX_FRAME:
            fail(f"response frame of {length} bytes exceeds the {MAX_FRAME} ceiling")
        body = b""
        while len(body) < length:
            chunk = sock.recv(length - len(body))
            if not chunk:
                fail("connection closed mid-response")
            body += chunk

    print(json.dumps(json.loads(body), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
