"""Docker-only isolation qualification; never invokes a model provider."""
import ipaddress
import json
import secrets
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

from audit_runtime import run


def check_target(target, image, run_id, owner, network, home):
    labels = target['Config']['Labels']
    if target['Image'] != image or labels.get('fermix.audit.run') != run_id or labels.get('fermix.audit.owner') != owner:
        raise ValueError('target image or ownership mismatch')
    user = target['Config'].get('User', '').split(':', 1)[0]
    if not user or user in ('0', 'root'):
        raise ValueError('target must run as non-root')
    host = target['HostConfig']
    if host['Privileged'] or host['NetworkMode'] != network or any(host.get(key) == 'host' for key in ('PidMode', 'IpcMode', 'UTSMode', 'UsernsMode', 'CgroupnsMode')):
        raise ValueError('unsafe target namespaces')
    if host.get('CapAdd') or 'ALL' not in (host['CapDrop'] or []) or 'no-new-privileges' not in (host['SecurityOpt'] or []):
        raise ValueError('unsafe target security options')
    networks = target['NetworkSettings']['Networks']
    if set(networks) != {network} or networks[network].get('GlobalIPv6Address'):
        raise ValueError('target network attachment mismatch')
    if any('unconfined' in option for option in host['SecurityOpt']):
        raise ValueError('unconfined security profile')
    mounts = target['Mounts']
    if len(mounts) != 1 or mounts[0].get('Type') != 'volume' or mounts[0].get('Name') != home:
        raise ValueError('unexpected target mount')
    if mounts[0].get('Destination') != '/home/audit/fermix':
        raise ValueError('unexpected target home destination')


def probe_result(output, expected):
    try:
        result = json.loads(output)
    except (ValueError, TypeError) as error:
        raise ValueError('invalid probe result') from error
    if result != {'ok': expected}:
        raise ValueError('isolation probe failed')
    return True


def inspect(kind, name):
    data = json.loads(run(['docker', kind, 'inspect', name], timeout=10))
    if not isinstance(data, list) or len(data) != 1:
        raise ValueError('invalid Docker inspection')
    return data[0]


def owned(item, runtime):
    labels = item.get('Config', {}).get('Labels') or item.get('Labels') or {}
    if labels.get('fermix.audit.run') != runtime.run_id or labels.get('fermix.audit.owner') != runtime.owner:
        raise ValueError('refusing foreign Docker resource')


def probe(container, ip, port, nonce, expected):
    program = """import json,socket,sys,time
s=socket.socket()
s.settimeout(3)
ok=s.connect_ex((sys.argv[1],int(sys.argv[2])))==0
if ok and sys.argv[3]:
    s.sendall(b'GET / HTTP/1.0\\r\\n\\r\\n')
    data=b''
    deadline=time.monotonic()+3
    while len(data)<4096 and time.monotonic()<deadline:
        s.settimeout(max(0.001,deadline-time.monotonic()))
        chunk=s.recv(4096-len(data))
        if not chunk: break
        data+=chunk
    ok=sys.argv[3].encode() in data
s.close()
print(json.dumps({'ok':ok}))"""
    output = run(['docker', 'exec', container, 'python3', '-I', '-c', program, ip, str(port), nonce], timeout=8)
    return probe_result(output, expected)


def resolve_host(proxy):
    program = "import socket; print(socket.gethostbyname('host.docker.internal'))"
    ip = run(['docker', 'exec', proxy, 'python3', '-c', program], timeout=8).strip()
    return str(ipaddress.IPv4Address(ip))


def start_canary(runtime, services, name, nonce):
    code = """from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
def expire(sock):
    try: sock.shutdown(2)
    except OSError: pass
class Server(HTTPServer):
    def process_request(self, sock, address):
        timer=threading.Timer(3,expire,args=(sock,))
        timer.start()
        try: super().process_request(sock,address)
        finally: timer.cancel()
    def get_request(self):
        sock,addr=super().get_request()
        sock.settimeout(3)
        return sock,addr
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(NONCE.encode())
server=Server(('0.0.0.0',8080),Handler)
timer=threading.Timer(120,server.shutdown)
timer.start()
try: server.serve_forever()
finally:
    timer.cancel()
    server.server_close()
""".replace('NONCE', repr(nonce))
    try:
        run(['docker', 'create', '--name', name, '--label', runtime.label, '--label', runtime.owner_label,
             '--network', services.egress, '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
             runtime.image, 'python3', '-c', code], timeout=20)
        run(['docker', 'start', name], timeout=20)
        item = inspect('container', name)
        owned(item, runtime)
        return str(ipaddress.IPv4Address(item['NetworkSettings']['Networks'][services.egress]['IPAddress']))
    except BaseException as error:
        try:
            runtime._remove_owned('container', name)
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as cleanup_error:
            raise BaseExceptionGroup('canary startup and cleanup failed', [error, cleanup_error]) from error
        raise


def cleanup_canary(runtime, name):
    item = inspect('container', name)
    owned(item, runtime)
    run(['docker', 'rm', '-f', name], timeout=20)


def expire_client(client):
    try:
        client.shutdown(2)
    except OSError:
        return


class CanaryServer(HTTPServer):
    def process_request(self, client, address):
        timer = threading.Timer(3, expire_client, args=(client,))
        timer.start()
        try:
            super().process_request(client, address)
        finally:
            timer.cancel()

    def get_request(self):
        client, address = super().get_request()
        client.settimeout(3)
        return client, address


def host_canary(nonce):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(nonce.encode())

        def log_message(self, format, *args):
            return

    server = CanaryServer(('0.0.0.0', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    timer = threading.Timer(120, server.shutdown)
    timer.start()
    return server, thread, timer


def close_host(server, thread, timer):
    timer.cancel()
    server.shutdown()
    thread.join(timeout=5)
    server.server_close()
    if thread.is_alive():
        raise RuntimeError('host canary failed to stop')


def check_networks(internal, egress):
    if not internal.get('Internal') or egress.get('Internal'):
        raise ValueError('network isolation configuration mismatch')
    if internal.get('EnableIPv6') is not False or egress.get('EnableIPv6') is not False:
        raise ValueError('IPv6 is outside this preflight profile')
    if (internal.get('Options') or {}).get('com.docker.network.bridge.gateway_mode_ipv4') != 'isolated':
        raise ValueError('internal network must use isolated IPv4 gateway mode')


def wait_ready(proxy, ip, nonce):
    deadline = time.monotonic() + 15
    last_error = None
    while time.monotonic() < deadline:
        try:
            probe(proxy, ip, 8080, nonce, True)
            return
        except (ValueError, subprocess.SubprocessError) as error:
            last_error = error
        time.sleep(0.2)
    raise TimeoutError('egress canary did not become ready') from last_error


def qualify(runtime, services, expected_image_id):
    """Return qualified evidence only after all controlled Docker probes pass."""
    target = inspect('container', runtime.target)
    check_target(target, expected_image_id, runtime.run_id, runtime.owner, runtime.network, runtime.volume)
    proxy = inspect('container', services.proxy)
    world = inspect('container', services.world)
    owned(proxy, runtime)
    owned(world, runtime)
    if set(proxy['NetworkSettings']['Networks']) != {runtime.network, services.egress}:
        raise ValueError('proxy network attachment mismatch')
    if set(world['NetworkSettings']['Networks']) != {runtime.network}:
        raise ValueError('world network attachment mismatch')
    internal = inspect('network', runtime.network)
    egress = inspect('network', services.egress)
    owned(internal, runtime)
    owned(egress, runtime)
    check_networks(internal, egress)
    nonce = secrets.token_hex(24)
    name = f'{runtime.network}-canary'
    server, thread, timer = host_canary(nonce)
    created = False
    try:
        # Create separately so cleanup remains possible even if startup fails.
        ip = start_canary(runtime, services, name, nonce)
        created = True
        wait_ready(services.proxy, ip, nonce)
        probe(runtime.target, ip, 8080, '', False)
        host_ip = resolve_host(services.proxy)
        probe(services.proxy, host_ip, server.server_port, nonce, True)
        probe(runtime.target, host_ip, server.server_port, '', False)
        world_ip = world['NetworkSettings']['Networks'][runtime.network]['IPAddress']
        probe(runtime.target, str(ipaddress.IPv4Address(world_ip)), 8080, '', True)
    except BaseException as error:
        try:
            cleanup(runtime, name, created, server, thread, timer)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, ExceptionGroup) as cleanup_error:
            raise BaseExceptionGroup('preflight and cleanup failed', [error, cleanup_error]) from error
        raise
    cleanup(runtime, name, created, server, thread, timer)
    return {'qualified': True, 'target_image_id': expected_image_id, 'checks': [
        'egress_canary', 'host_canary', 'world_access', 'target_inspection']}


def cleanup(runtime, name, created, server, thread, timer):
    errors = []
    try:
        close_host(server, thread, timer)
    except (OSError, RuntimeError) as error:
        errors.append(error)
    if created:
        try:
            cleanup_canary(runtime, name)
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
            errors.append(error)
    if errors:
        raise ExceptionGroup('canary cleanup failed', errors)
