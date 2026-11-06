#!/usr/bin/env python3
"""Trusted, budgeted Anthropic Messages relay for synthetic audit runs."""
import argparse
import hmac
import http.client
import json
import math
import os
import socket
import sqlite3
import sys
import threading
import time
import uuid
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

MODEL = 'claude-opus-5-5'
ALLOWED_FIELDS = {'model', 'messages', 'max_tokens', 'system', 'tools', 'tool_choice',
                  'temperature', 'top_p', 'top_k', 'stop_sequences', 'stream', 'metadata',
                  'thinking', 'cache_control', 'output_config'}
COUNT_FIELDS = {'model', 'messages', 'system', 'tools', 'tool_choice', 'thinking',
                'output_config', 'cache_control'}


def validate_config(config):
    required = {'profile', 'run_id', 'world_id', 'token_file', 'ledger', 'revocation_file',
                'expires_at', 'max_requests', 'max_input_tokens', 'max_output_tokens',
                'max_body_bytes', 'max_response_bytes', 'run_budget_usd', 'campaign_budget_usd', 'model',
                'listen_host', 'listen_port', 'evidence_dir', 'campaign_identity'}
    optional = {'secret_file', 'secret_env', 'mock_upstream'}
    if not required <= config.keys() or set(config) - required - optional or config['model'] != MODEL:
        raise ValueError('missing configuration or unsupported model')
    if config['profile'] not in ('live', 'mock'):
        raise ValueError('invalid profile')
    if ('secret_file' in config) == ('secret_env' in config):
        raise ValueError('select exactly one secret source')
    for key in ('max_requests', 'max_input_tokens', 'max_output_tokens', 'max_body_bytes', 'max_response_bytes'):
        if type(config[key]) is not int or config[key] <= 0:
            raise ValueError('invalid limit: ' + key)
    if config['max_requests'] > 10000 or config['max_body_bytes'] > 16_000_000 or config['max_response_bytes'] > 32_000_000:
        raise ValueError('limit exceeds proxy maximum')
    if config['max_input_tokens'] + config['max_output_tokens'] > 200_000:
        raise ValueError('combined token limits exceed standard-price context')
    for key in ('run_budget_usd', 'campaign_budget_usd', 'expires_at'):
        if type(config[key]) not in (int, float) or not math.isfinite(config[key]) or config[key] <= 0:
            raise ValueError('invalid limit: ' + key)
    if config['run_budget_usd'] > config['campaign_budget_usd'] or config['campaign_budget_usd'] > 100:
        raise ValueError('invalid budget relationship')
    for key in ('run_id', 'world_id', 'token_file', 'ledger', 'revocation_file', 'listen_host', 'evidence_dir', 'campaign_identity'):
        if not isinstance(config[key], str) or not config[key].strip():
            raise ValueError('invalid configuration: ' + key)
    for key in ('token_file', 'ledger', 'revocation_file', 'evidence_dir'):
        if not Path(config[key]).is_absolute():
            raise ValueError('path must be absolute: ' + key)
    source = config.get('secret_file', config.get('secret_env'))
    if not isinstance(source, str) or not source.strip():
        raise ValueError('invalid credential source')
    if 'secret_file' in config and not Path(source).is_absolute():
        raise ValueError('credential path must be absolute')
    if type(config['listen_port']) is not int or not 0 <= config['listen_port'] <= 65535:
        raise ValueError('invalid listen port')
    if config['profile'] == 'mock':
        url = urlparse(config.get('mock_upstream', ''))
        if url.scheme != 'http' or url.hostname not in ('127.0.0.1', 'localhost') or not url.port or url.path:
            raise ValueError('mock upstream must be localhost HTTP')
    elif 'mock_upstream' in config:
        raise ValueError('live profile cannot set upstream')


def connect(config):
    if config['profile'] == 'live':
        return http.client.HTTPSConnection('api.anthropic.com', timeout=30)
    url = urlparse(config['mock_upstream'])
    return http.client.HTTPConnection(url.hostname, url.port, timeout=30)


def open_ledger(config):
    uri = Path(config['ledger']).as_uri() + '?mode=rw'
    return sqlite3.connect(uri, uri=True, timeout=30, isolation_level=None)


def verify_identity(db, config):
    rows = db.execute('SELECT id FROM audit_identity').fetchall()
    if rows != [(config['campaign_identity'],)]:
        raise ValueError('campaign ledger identity mismatch')


def reserve(config, output_tokens):
    # USD millionths: worst-case one-hour cache write for all input tokens.
    amount = config['max_input_tokens'] * 8 + output_tokens * 20
    with closing(open_ledger(config)) as db:
        db.execute('BEGIN IMMEDIATE')
        verify_identity(db, config)
        count, run_total = db.execute('SELECT count(*), coalesce(sum(amount), 0) FROM reservations WHERE run_id = ?', (config['run_id'],)).fetchone()
        campaign_total = db.execute('SELECT coalesce(sum(amount), 0) FROM reservations').fetchone()[0]
        if (count >= config['max_requests'] or run_total + amount > int(config['run_budget_usd'] * 1_000_000)
                or campaign_total + amount > int(config['campaign_budget_usd'] * 1_000_000)):
            db.rollback()
            return False
        cursor = db.execute('INSERT INTO reservations (run_id, amount, created_at) VALUES (?, ?, ?)', (config['run_id'], amount, time.time()))
        reservation_id = cursor.lastrowid
        db.commit()
        return reservation_id


def validate_request(data, config):
    if not isinstance(data, dict) or set(data) - ALLOWED_FIELDS or data.get('model') != config['model']:
        return False
    output = data.get('max_tokens')
    if type(output) is not int or not 0 < output <= config['max_output_tokens']:
        return False
    if not isinstance(data.get('messages'), list) or type(data.get('stream', False)) is not bool:
        return False
    output_config = data.get('output_config', {})
    if not isinstance(output_config, dict) or set(output_config) - {'effort'}:
        return False
    tools = data.get('tools', [])
    if not isinstance(tools, list):
        return False
    return all(isinstance(tool, dict) and tool.get('type', 'custom') == 'custom' for tool in tools)


def upstream(config, path, data):
    secret = Path(config['secret_file']).read_text().strip() if 'secret_file' in config else os.environ[config['secret_env']]
    if not secret or '\n' in secret or '\r' in secret:
        raise ValueError('invalid provider credential')
    body = json.dumps(data, separators=(',', ':')).encode()
    conn = connect(config)
    try:
        if path == '/v1/messages' and (time.time() >= config['expires_at'] or Path(config['revocation_file']).exists()):
            raise ValueError('run unauthorized')
        conn.request('POST', path, body, {'x-api-key': secret, 'anthropic-version': '2023-06-01', 'content-type': 'application/json'})
        return conn, conn.getresponse()
    except Exception:
        conn.close()
        raise


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def reject(self, status, message):
        body = json.dumps({'error': {'type': 'audit_proxy_error', 'message': message}}).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def credentials(self):
        config = self.server.config
        secret = Path(config['secret_file']).read_text().strip() if 'secret_file' in config else os.environ[config['secret_env']]
        return [Path(config['token_file']).read_text().strip(), secret]

    def authorized(self):
        config = self.server.config
        token = Path(config['token_file']).read_text().strip()
        return (bool(token) and hmac.compare_digest(self.headers.get('x-api-key', ''), token)
                and time.time() < config['expires_at'] and not Path(config['revocation_file']).exists())

    def do_GET(self):
        if self.path != '/health':
            return self.reject(404, 'not found')
        if self.server.degraded.is_set():
            return self.reject(503, 'evidence unavailable')
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_POST(self):
        try:
            self.handle_request()
        except (OSError, ValueError, KeyError, sqlite3.Error, http.client.HTTPException):
            self.reject(502, 'proxy or upstream failure')

    def handle_request(self):
        config = self.server.config
        self.request_id = None
        if self.server.degraded.is_set():
            return self.reject(503, 'evidence unavailable')
        if self.path != '/v1/messages':
            return self.reject(404, 'not found')
        if not self.authorized():
            return self.reject(403, 'run unauthorized')
        length = self.headers.get('Content-Length', '')
        if not length.isascii() or not length.isdigit() or not 0 < int(length) <= config['max_body_bytes']:
            return self.reject(400, 'invalid body length')
        data = json.loads(self.rfile.read(int(length)))
        if not validate_request(data, config):
            return self.reject(400, 'invalid request')
        self.secrets = self.credentials()
        if any(not secret or '\n' in secret or '\r' in secret for secret in self.secrets):
            return self.reject(502, 'invalid credential')
        with self.server.admission_lock:
            if self.server.degraded.is_set():
                return self.reject(503, 'evidence unavailable')
            reservation_id = reserve(config, data['max_tokens'])
        if not reservation_id:
            self.record_failure(data, None, 429, 'budget_exhausted')
            return self.reject(429, 'budget exhausted')
        self.write_evidence(data, None, b'', 'in_flight', self.secrets, reservation_id)
        self.reserved_request(data, reservation_id)

    def reserved_request(self, data, reservation_id):
        try:
            self.count_and_forward(data, reservation_id)
        except (OSError, ValueError, KeyError, sqlite3.Error, http.client.HTTPException):
            self.record_failure(data, reservation_id, 502, 'transport_error')
            self.reject(502, 'proxy or upstream failure')

    def record_failure(self, data, reservation_id, status, terminal):
        self.write_evidence(data, status, b'', terminal, self.secrets, reservation_id)

    def count_and_forward(self, data, reservation_id):
        config = self.server.config
        count = {key: value for key, value in data.items() if key in COUNT_FIELDS}
        conn, response = upstream(config, '/v1/messages/count_tokens', count)
        try:
            raw = response.read(config['max_body_bytes'] + 1)
            if response.status != 200:
                return self.count_failure(data, reservation_id, response.status, raw)
            result = json.loads(raw)
            if type(result.get('input_tokens')) is not int or not 0 <= result['input_tokens'] <= config['max_input_tokens']:
                self.record_failure(data, reservation_id, 400, 'input_limit')
                return self.reject(400, 'input token limit or count failure')
        finally:
            conn.close()
        if not self.authorized():
            self.record_failure(data, reservation_id, 403, 'run_unauthorized')
            return self.reject(403, 'run unauthorized')
        self.forward(data, reservation_id)

    def count_failure(self, data, reservation_id, status, raw):
        secrets = self.secrets
        safe = redact(raw, [secret.encode() for secret in secrets if secret])
        self.write_evidence(data, status, safe, 'count_error', secrets, reservation_id)
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(safe)))
        self.end_headers()
        self.wfile.write(safe)

    def forward(self, data, reservation_id):
        config = self.server.config
        secrets = self.secrets
        conn, response = upstream(config, '/v1/messages', data)
        captured = bytearray()
        self.request_id = safe_request_id(response.getheader('request-id'), secrets)
        stop = threading.Event()
        state = {}
        sock = response.fp.raw._sock
        watcher = threading.Thread(target=watch_stream, args=(sock, config, stop, state), daemon=True)
        watcher.start()
        terminal = 'complete'
        try:
            self.send_response(response.status)
            self.send_header('Content-Type', response.getheader('Content-Type', 'application/json'))
            if self.request_id:
                self.send_header('request-id', self.request_id)
            self.send_header('Connection', 'close')
            self.end_headers()
            self.close_connection = True
            terminal = self.copy_response(response, secrets, captured)
        except (OSError, http.client.HTTPException):
            terminal = 'stream_error'
        finally:
            stop.set()
            watcher.join(timeout=2)
            terminal = state.get('terminal', terminal)
            response.close()
            conn.close()
            try:
                self.write_evidence(data, response.status, bytes(captured), terminal, secrets, reservation_id)
            except (OSError, ValueError):
                print('audit proxy evidence write failed', file=sys.stderr)

    def write_evidence(self, data, status, body, terminal, secrets, reservation_id):
        try:
            save_evidence(self.server.config, data, status, body, terminal, secrets, reservation_id, self.request_id)
        except (OSError, ValueError):
            with self.server.admission_lock:
                self.server.degraded.set()
            raise

    def copy_response(self, response, secrets, captured):
        config = self.server.config
        remaining = config['max_response_bytes']
        deadline = time.monotonic() + 300
        pending = b''
        encoded = [secret.encode() for secret in secrets if secret]
        overlap = max((len(secret) for secret in encoded), default=1) - 1
        while remaining > 0 and time.monotonic() < deadline:
            chunk = response.read1(min(65536, remaining))
            if not chunk:
                self.emit(redact(pending, encoded), captured)
                return 'complete'
            pending += chunk
            for secret in encoded:
                pending = pending.replace(secret, b'[REDACTED]')
            if len(pending) > overlap:
                boundary = len(pending) - overlap
                self.emit(pending[:boundary], captured)
                pending = pending[boundary:]
            remaining -= len(chunk)
        self.emit(redact(pending, encoded), captured)
        return 'response_limit_or_deadline'

    def emit(self, chunk, captured):
        captured.extend(chunk)
        self.wfile.write(chunk)
        self.wfile.flush()


def redact(data, secrets):
    for secret in secrets:
        data = data.replace(secret, b'[REDACTED]')
    return data


def parse_event(line):
    if not line.startswith(b'data: '):
        return None
    try:
        return json.loads(line[6:])
    except (ValueError, UnicodeDecodeError):
        return None


def merge_usage(values, item):
    if not isinstance(item, dict):
        return
    message = item.get('message')
    message_usage = message.get('usage', {}) if isinstance(message, dict) else {}
    usage = item.get('usage') or message_usage
    if not isinstance(usage, dict):
        return
    for key, value in usage.items():
        if type(value) is int and value >= 0:
            values[key] = max(values.get(key, 0), value)


def observed_usage(body):
    try:
        candidates = [json.loads(body)]
    except (ValueError, UnicodeDecodeError):
        candidates = [parse_event(line) for line in body.splitlines()]
    values = {}
    for item in candidates:
        merge_usage(values, item)
    return values


def save_evidence(config, request, status, body, terminal, secrets, reservation_id, request_id=None):
    safe_request = redact(json.dumps(request).encode(), [secret.encode() for secret in secrets if secret])
    record = {'run_id': config['run_id'], 'world_id': config['world_id'], 'reservation_id': reservation_id,
              'request': json.loads(safe_request), 'status': status, 'terminal': terminal, 'request_id': request_id,
              'response': body.decode('utf-8', errors='replace'),
              'observed_usage': observed_usage(body), 'accounting': 'reserved upper bound; not actual spend'}
    content = redact(json.dumps(record).encode(), [secret.encode() for secret in secrets if secret])
    name = f'reservation-{reservation_id}' if reservation_id is not None else 'rejection-' + uuid.uuid4().hex
    path = Path(config['evidence_dir']) / (name + '.json')
    temporary = path.with_name(name + '-' + uuid.uuid4().hex + '.tmp')
    with temporary.open('xb') as stream:
        os.chmod(temporary, 0o600)
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    directory = os.open(config['evidence_dir'], os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def safe_request_id(value, secrets):
    if not isinstance(value, str) or not 0 < len(value) <= 256:
        return None
    if not value.isascii() or any(ord(char) < 32 or ord(char) > 126 for char in value):
        return None
    return redact(value.encode(), [secret.encode() for secret in secrets if secret]).decode()


def watch_stream(sock, config, stop, state):
    deadline = time.monotonic() + 300
    while not stop.wait(0.1):
        if Path(config['revocation_file']).exists():
            state['terminal'] = 'revoked'
        elif time.time() >= config['expires_at']:
            state['terminal'] = 'expired'
        elif time.monotonic() >= deadline:
            state['terminal'] = 'response_limit_or_deadline'
        if state:
            expire_socket(sock)
            return


def expire_socket(request):
    try:
        request.shutdown(socket.SHUT_RDWR)
    except OSError:
        print('audit proxy request deadline reached', file=sys.stderr)


class BoundedServer(ThreadingHTTPServer):
    def __init__(self, address, handler):
        self.slots = threading.BoundedSemaphore(16)
        self.degraded = threading.Event()
        self.admission_lock = threading.Lock()
        super().__init__(address, handler)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        request.settimeout(10)
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        timer = threading.Timer(300, expire_socket, args=(request,))
        timer.start()
        try:
            super().process_request_thread(request, address)
        finally:
            timer.cancel()
            self.slots.release()


def check_evidence_dir(path):
    directory = Path(path)
    if not directory.is_dir() or directory.stat().st_mode & 0o077:
        raise ValueError('evidence directory must be private')
    probe = directory / ('.probe-' + uuid.uuid4().hex)
    try:
        with probe.open('xb') as stream:
            stream.write(b'probe')
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        if probe.exists():
            probe.unlink()


def make_server(config):
    validate_config(config)
    check_evidence_dir(config['evidence_dir'])
    with closing(open_ledger(config)) as db:
        verify_identity(db, config)
        if db.execute('PRAGMA integrity_check').fetchone() != ('ok',):
            raise ValueError('ledger integrity check failed')
        columns = [row[1] for row in db.execute('PRAGMA table_info(reservations)')]
        if columns != ['run_id', 'amount', 'created_at']:
            raise ValueError('invalid ledger schema')
        invalid = db.execute("SELECT count(*) FROM reservations WHERE typeof(run_id) != 'text' OR run_id = '' OR typeof(amount) != 'integer' OR amount <= 0 OR typeof(created_at) NOT IN ('integer', 'real') OR created_at <= 0").fetchone()[0]
        if invalid:
            raise ValueError('invalid ledger data')
    server = BoundedServer((config['listen_host'], config['listen_port']), Handler)
    server.config = config
    return server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    server = make_server(config)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
