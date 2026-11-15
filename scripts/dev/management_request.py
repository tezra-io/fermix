#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Send one management request to a running Fermix daemon and print the reply.

Dev tool for exercising the app-facing management plane without the macOS app.
Speaks the packet-4 framing (4-byte big-endian length prefix + JSON) documented
in apps/fermix_core/priv/management/PROTOCOL.md.

It negotiates the protocol version as the apps do (PROTOCOL.md, "Versioning"
and "Direction of an unsupported version"), each request on its own
connection: first `hello` at version 1, the version every daemon has served,
which answers the daemon's window in `result.protocol` (or, from a daemon
whose floor is above 1, in the `client_too_old` refusal's `details`); then the
request itself at the window's `maximum_version`, so a method whose minimum
version is above 1 is served rather than refused with `method_not_found`. Only
the reply to that request is printed (callers parse it), and a hello that
answers neither is a failure on stderr, exit 1.

Usage:
    uv run scripts/dev/management_request.py <method> [params-json]

The socket is resolved from $FERMIX_HOME/daemon.sock (FERMIX_HOME required).

Examples:
    FERMIX_HOME=~/.fermix-apptest uv run scripts/dev/management_request.py hello
    FERMIX_HOME=~/.fermix-apptest uv run scripts/dev/management_request.py overview.get
    FERMIX_HOME=~/.fermix-apptest uv run scripts/dev/management_request.py setup.session.create
    FERMIX_HOME=~/.fermix-apptest uv run scripts/dev/management_request.py doctor.start '{"scope":"local"}'
    FERMIX_HOME=~/.fermix-apptest uv run scripts/dev/management_request.py logs.query '{"limit":20}'
    FERMIX_HOME=~/.fermix-apptest uv run scripts/dev/management_request.py settings.sections
"""

import json
import os
import socket
import struct
import sys
import uuid

MAX_FRAME = 4 * 1024 * 1024
# The version every daemon has served: the hello that learns the window.
HELLO_VERSION = 1
TIMEOUT_S = 35.0


def fail(message: str) -> None:
    print(f"management_request.py: {message}", file=sys.stderr)
    sys.exit(1)


def call(path: str, version: int, method: str, params: dict) -> dict:
    """One request on a connection of its own; the reply, or a failure."""
    request_id = f"dev-{uuid.uuid4().hex[:12]}"
    frame = json.dumps(
        {
            "request_id": request_id,
            "protocol_version": version,
            "method": method,
            "params": params,
        }
    ).encode("utf-8")

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(TIMEOUT_S)
        sock.connect(path)
        sock.sendall(struct.pack(">I", len(frame)) + frame)
        header = sock.recv(4, socket.MSG_WAITALL)
        if len(header) != 4:
            fail(f"{method}: connection closed before a response header arrived")
        (length,) = struct.unpack(">I", header)
        if length > MAX_FRAME:
            fail(f"{method}: response frame of {length} bytes exceeds the {MAX_FRAME} ceiling")
        body = b""
        while len(body) < length:
            chunk = sock.recv(length - len(body))
            if not chunk:
                fail(f"{method}: connection closed mid-response")
            body += chunk

    try:
        reply = json.loads(body)
    except json.JSONDecodeError as error:
        fail(f"{method}: the reply is not JSON: {error}")
    if not isinstance(reply, dict) or reply.get("request_id") != request_id:
        fail(f"{method}: the reply does not answer request {request_id}: {json.dumps(reply)}")
    return reply


def negotiate(path: str) -> int:
    """The daemon's maximum_version, from a hello at version 1."""
    reply = call(path, HELLO_VERSION, "hello", {})
    error = reply.get("error")
    if "result" in reply:
        window = reply["result"].get("protocol") if isinstance(reply["result"], dict) else None
    elif isinstance(error, dict) and error.get("code") == "client_too_old":
        window = error.get("details")
    else:
        fail(f"hello at protocol version {HELLO_VERSION} answered no window: {json.dumps(reply)}")

    maximum = window.get("maximum_version") if isinstance(window, dict) else None
    if not isinstance(maximum, int) or isinstance(maximum, bool) or maximum < 1:
        fail(f"hello answered no usable maximum_version: {json.dumps(reply)}")
    return maximum


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

    version = negotiate(path)
    reply = call(path, version, method, params)
    print(json.dumps(reply, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
