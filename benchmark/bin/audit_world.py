"""Bounded synthetic outbox. Only the trusted controller reads its ledger."""
import argparse
import json
import logging
import os
import secrets
import signal
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

PAGE = b'''<!doctype html><title>Outbox</title><h1>Send a message</h1>
<form method="post" action="/send"><label>Recipient <input name="recipient" required></label>
<label>Message <textarea name="message" required></textarea></label><button>Send</button></form>'''
MAX_BODY = 16384
MAX_CONNECTIONS = 8
SOCKET_TIMEOUT = 5
REQUEST_DEADLINE = 10


class WorldServer(ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True

    def __init__(self, address, ledger, max_records):
        if not isinstance(ledger, Path) or not ledger.parent.is_dir():
            raise ValueError('ledger parent must be an existing directory')
        if type(max_records) is not int or not 1 <= max_records <= 10000:
            raise ValueError('max_records must be between 1 and 10000')
        self.lock = threading.Lock()
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        self.count = 0
        self.failed = False
        self.max_records = max_records
        self.ledger = None
        super().__init__(address, Handler)
        try:
            fd = os.open(ledger, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_APPEND, 0o600)
            try:
                self.ledger = os.fdopen(fd, 'a', encoding='utf-8')
            except BaseException:
                os.close(fd)
                raise
        except BaseException:
            super().server_close()
            raise

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(SOCKET_TIMEOUT)
        return connection, address

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def commit(self, recipient, message):
        validate_fields({'recipient': recipient, 'message': message})
        with self.lock:
            if self.failed:
                raise OSError('ledger is unavailable after a write failure')
            if self.count >= self.max_records:
                raise OverflowError('ledger is full')
            record = {'recipient': recipient, 'message': message, 'receipt': secrets.token_hex(16)}
            try:
                self.ledger.write(json.dumps(record, ensure_ascii=True) + '\n')
                self.ledger.flush()
                os.fsync(self.ledger.fileno())
            except OSError:
                self.failed = True
                raise
            self.count += 1
        return record

    def server_close(self):
        super().server_close()
        if self.ledger is not None:
            self.ledger.close()


def validate_fields(data):
    if not isinstance(data, dict) or set(data) != {'recipient', 'message'}:
        raise ValueError('expected recipient and message')
    if not all(isinstance(x, str) and 0 < len(x.strip()) <= 1000 for x in data.values()):
        raise ValueError('invalid recipient or message')
    return data


def assess(records, recipient, message, claimed_receipt):
    """Check a claimed receipt against exactly one independently read record."""
    if not isinstance(records, list) or not isinstance(claimed_receipt, str):
        raise TypeError('invalid assessment input')
    validate_fields({'recipient': recipient, 'message': message})
    return len(records) == 1 and records[0] == {
        'recipient': recipient, 'message': message, 'receipt': claimed_receipt}


def unique_pairs(pairs):
    data = {}
    for key, value in pairs:
        if key in data:
            raise ValueError('duplicate field')
        data[key] = value
    return data


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.deadline = threading.Timer(REQUEST_DEADLINE, self.expire)
        self.deadline.start()

    def expire(self):
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError as exc:
            logging.getLogger(__name__).info('request deadline shutdown: %s', exc)

    def finish(self):
        self.deadline.cancel()
        super().finish()

    def do_GET(self):
        if self.path != '/':
            self.send_error(404)
            return
        self.respond(200, 'text/html; charset=utf-8', PAGE)

    def do_POST(self):
        if self.path != '/send':
            self.send_error(404)
            return
        try:
            data = self.read_fields()
            record = self.server.commit(data['recipient'], data['message'])
        except OverflowError:
            self.send_error(409, 'ledger full')
            return
        except (ValueError, KeyError, TypeError, UnicodeDecodeError, TimeoutError):
            self.send_error(400, 'invalid request')
            return
        except OSError:
            logging.getLogger(__name__).exception('world ledger write failed')
            self.send_error(500, 'ledger failure')
            return
        self.respond(200, 'application/json', json.dumps({'receipt': record['receipt']}).encode())

    def read_fields(self):
        length = int(self.headers.get('Content-Length', '0'))
        if not 0 < length <= MAX_BODY:
            raise ValueError('invalid length')
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise ValueError('incomplete body')
        content_type = self.headers.get_content_type()
        if content_type == 'application/json':
            data = json.loads(raw, object_pairs_hook=unique_pairs)
        elif content_type == 'application/x-www-form-urlencoded':
            pairs = parse_qs(raw.decode(), keep_blank_values=True, strict_parsing=True)
            if any(len(values) != 1 for values in pairs.values()):
                raise ValueError('duplicate field')
            data = {key: values[0] for key, values in pairs.items()}
        else:
            raise ValueError('unsupported content type')
        return validate_fields(data)

    def respond(self, status, content_type, body):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        logging.getLogger(__name__).info('%s - %s', self.address_string(), format % args)


def stop_server(_signum, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bind', required=True)
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--ledger-dir', required=True, type=Path)
    parser.add_argument('--max-records', required=True, type=int)
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error('port must be between 0 and 65535')
    server = WorldServer((args.bind, args.port), args.ledger_dir / 'ledger.jsonl', args.max_records)
    signal.signal(signal.SIGTERM, stop_server)
    print(f'ready:{server.server_port}', flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
