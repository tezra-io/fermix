"""Call the audit-only observer checkpoint socket from the trusted client."""
import json
import socket
import sys
import time

nonce = sys.argv[1]
request = json.dumps({'op': 'checkpoint', 'nonce': nonce}).encode() + b'\n'
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
    deadline = time.monotonic() + 2
    conn.settimeout(2)
    conn.connect('/home/audit/fermix/audit-observer.sock')
    conn.sendall(request)
    data = bytearray()
    while not data.endswith(b'\n') and len(data) <= 1024:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('observer checkpoint deadline expired')
        conn.settimeout(remaining)
        chunk = conn.recv(min(1025 - len(data), 1024))
        if not chunk:
            raise RuntimeError('observer checkpoint closed without a reply')
        data.extend(chunk)
    if len(data) > 1024:
        raise ValueError('observer checkpoint reply exceeds 1024 bytes')
    print(json.dumps(json.loads(data)))
