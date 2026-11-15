"""Request normal daemon shutdown over its existing local protocol."""
import json
import socket
import struct

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
    conn.settimeout(5)
    conn.connect('/home/audit/fermix/daemon.sock')
    payload = b'{"method":"shutdown"}'
    conn.sendall(struct.pack('>I', len(payload)) + payload)
    header = conn.recv(4, socket.MSG_WAITALL)
    if len(header) != 4:
        raise RuntimeError('shutdown response header missing')
    size = struct.unpack('>I', header)[0]
    if size > 4096:
        raise ValueError('shutdown response exceeds limit')
    data = conn.recv(size, socket.MSG_WAITALL)
    if len(data) != size:
        raise RuntimeError('shutdown response truncated')
    reply = json.loads(data)
    if reply.get('status') != 'shutting_down':
        raise RuntimeError('daemon refused shutdown')
