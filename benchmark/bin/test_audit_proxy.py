import gc
import json
import os
import sqlite3
import tempfile
import threading
import time
import unittest
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar
from unittest.mock import patch

import audit_proxy


class Upstream(BaseHTTPRequestHandler):
    requests: ClassVar[list] = []
    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        self.requests.append((self.path, self.headers.get('x-api-key'), json.loads(data)))
        if getattr(self.server, 'failure', False) and self.path.endswith('/messages'):
            body = b'{"error":{"message":"key-canary token-canary upstream failed"}}'
            self.send_response(429)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.endswith('count_tokens'):
            body = getattr(self.server, 'count_body', b'{"input_tokens":10}')
            revoke = getattr(self.server, 'revoke', None)
            if revoke:
                Path(revoke).touch()
        elif json.loads(data).get('stream'):
            body = b'event: message_delta\ndata: {"usage":{"output_tokens":2},"text":"key-canary token-canary"}\n\nevent: message_delta\ndata: {"usage":{"output_tokens":2}}\n\n'
        else:
            body = b'{"type":"message","usage":{"input_tokens":10,"output_tokens":2}}'
        self.send_response(200)
        if not self.path.endswith('count_tokens'):
            self.send_header('request-id', getattr(self.server, 'request_id', 'req-synthetic'))
        if getattr(self.server, 'hold', False) and not self.path.endswith('count_tokens'):
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(b'data: started\n\n')
            self.wfile.flush()
            self.server.started.set()
            self.server.release.wait(10)
            return
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass


class ProxyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.up = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        self.addCleanup(self.up.server_close)
        Upstream.requests = []
        threading.Thread(target=self.up.serve_forever, daemon=True).start()
        self.addCleanup(self.up.shutdown)
        self.config = {'profile': 'mock', 'mock_upstream': f'http://127.0.0.1:{self.up.server_port}',
                       'run_id': 'run', 'world_id': 'world', 'token_file': self.file('token', 'token-canary'),
                       'secret_file': self.file('secret', 'key-canary'), 'ledger': str(Path(self.tmp.name) / 'ledger.sqlite'),
                       'revocation_file': str(Path(self.tmp.name) / 'revoked'), 'expires_at': time.time() + 600,
                       'max_requests': 3, 'max_input_tokens': 100, 'max_output_tokens': 100,
                       'max_body_bytes': 10000, 'max_response_bytes': 100000, 'run_budget_usd': 1, 'campaign_budget_usd': 1,
                       'model': 'claude-opus-5-5', 'listen_host': '127.0.0.1', 'listen_port': 0}
        self.config['evidence_dir'] = self.tmp.name
        self.config['campaign_identity'] = 'campaign-id'
        with audit_proxy.closing(sqlite3.connect(self.config['ledger'])) as db:
            db.execute('CREATE TABLE audit_identity (id TEXT NOT NULL)')
            db.execute('INSERT INTO audit_identity VALUES (?)', ('campaign-id',))
            db.execute('CREATE TABLE reservations (run_id TEXT NOT NULL, amount INTEGER NOT NULL, created_at REAL NOT NULL)')
            db.commit()
        self.start()
    def file(self, name, value):
        path = Path(self.tmp.name) / name
        path.write_text(value)
        return str(path)
    def start(self):
        self.server = audit_proxy.make_server(self.config)
        self.addCleanup(self.server.server_close)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
    def stop(self):
        self.server.shutdown()
        self.server.server_close()
    def request(self, data=None, token='token-canary'):
        conn = HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        body = json.dumps(data or {'model': 'claude-opus-5-5', 'messages': [], 'max_tokens': 10})
        conn.request('POST', '/v1/messages', body, {'x-api-key': token, 'Content-Type': 'application/json'})
        response = conn.getresponse()
        result = response.status, response.read()
        conn.close()
        return result
    def test_json_stream_and_secrets(self):
        self.assertEqual(self.request()[0], 200)
        status, data = self.request({'model': 'claude-opus-5-5', 'messages': [], 'max_tokens': 10, 'stream': True})
        self.assertEqual(status, 200)
        self.assertEqual(data.count(b'message_delta'), 2)
        self.assertTrue(all(req[1] == 'key-canary' for req in Upstream.requests))
        self.assertNotIn(b'key-canary', data)
        self.assertNotIn(b'token-canary', data)
        records = [json.loads(path.read_text()) for path in Path(self.tmp.name).glob('*.json')]
        self.assertEqual([record['observed_usage']['output_tokens'] for record in records], [2, 2])
        self.assertNotIn(b'token-canary', Path(self.config['ledger']).read_bytes())
    def test_rejections_and_restart(self):
        self.assertEqual(self.request(token='wrong')[0], 403)
        self.assertEqual(self.request(token='other-world-token')[0], 403)
        self.assertEqual(self.request({'model': 'wrong', 'messages': [], 'max_tokens': 1})[0], 400)
        self.assertEqual(self.request({'model': 'claude-opus-5-5', 'messages': [], 'max_tokens': 1, 'tools': [{'type': 'web_search_20250305', 'name': 'web'}]})[0], 400)
        for _ in range(3):
            self.assertEqual(self.request()[0], 200)
        self.stop()
        self.start()
        self.assertEqual(self.request()[0], 429)
        records = [json.loads(path.read_text()) for path in Path(self.tmp.name).glob('*.json')]
        rejection = next(record for record in records if record['terminal'] == 'budget_exhausted')
        self.assertIsNone(rejection['reservation_id'])
    def test_expiry_and_revoke(self):
        Path(self.config['revocation_file']).touch()
        self.assertEqual(self.request()[0], 403)
        os.unlink(self.config['revocation_file'])
        self.server.config['expires_at'] = time.time() - 1
        self.assertEqual(self.request()[0], 403)
    def test_real_adapter_shape_and_evidence(self):
        body = {'model': 'claude-opus-5-5', 'messages': [{'role': 'user', 'content': 'hello'}],
                'max_tokens': 16384, 'temperature': 0.5, 'output_config': {'effort': 'high'},
                'tools': [{'name': 'example', 'input_schema': {'type': 'object'}}]}
        self.server.config['max_output_tokens'] = 16384
        self.assertEqual(self.request(body)[0], 200)
        self.assertNotIn('temperature', Upstream.requests[0][2])
        self.assertEqual(Upstream.requests[1][2], body)
        records = list(Path(self.tmp.name).glob('*.json'))
        self.assertEqual(len(records), 1)
        record = json.loads(records[0].read_text())
        self.assertEqual(record['request']['tools'], body['tools'])
        self.assertEqual(record['observed_usage']['output_tokens'], 2)

    def test_upstream_error_redacts_canaries(self):
        self.up.failure = True
        status, body = self.request()
        self.assertEqual(status, 429)
        self.assertNotIn(b'key-canary', body)
        self.assertNotIn(b'token-canary', body)
        for record in Path(self.tmp.name).glob('*.json'):
            self.assertNotIn('key-canary', record.read_text())
            self.assertNotIn('token-canary', record.read_text())

    def test_redaction_across_chunk_boundaries(self):
        class Pieces:
            def __init__(self): self.parts = iter([b'hello key-', b'canary token-', b'canary end', b''])
            def read1(self, size): return next(self.parts)
        handler = object.__new__(audit_proxy.Handler)
        handler.server = self.server
        import io
        handler.wfile = io.BytesIO()
        captured = bytearray()
        self.assertEqual(handler.copy_response(Pieces(), ['key-canary', 'token-canary'], captured), 'complete')
        self.assertEqual(bytes(captured), b'hello [REDACTED] [REDACTED] end')

    def test_rejects_unpriced_speed(self):
        body = {'model': 'claude-opus-5-5', 'messages': [], 'max_tokens': 10, 'output_config': {'speed': 'fast'}}
        self.assertEqual(self.request(body)[0], 400)

    def test_ledger_connections_closed(self):
        connections = []
        original = audit_proxy.sqlite3.connect

        class TrackedConnection(sqlite3.Connection):
            closed = False
            def close(self):
                self.closed = True
                super().close()

        def connect(*args, **kwargs):
            connection = original(*args, factory=TrackedConnection, **kwargs)
            connections.append(connection)
            return connection

        with patch.object(audit_proxy.sqlite3, 'connect', side_effect=connect):
            self.assertEqual(self.request()[0], 200)
            extra = audit_proxy.make_server(self.config)
            extra.server_close()
        self.assertEqual(len(connections), 2)
        self.assertTrue(all(connection.closed for connection in connections))
        connections.clear()
        gc.collect()

    def test_reserved_failures_have_terminal_evidence(self):
        cases = [('input_limit', b'{"input_tokens":101}', False),
                 ('run_unauthorized', b'{"input_tokens":10}', True)]
        for terminal, count_body, revoke in cases:
            previous = set(Path(self.tmp.name).glob('*.json'))
            self.up.count_body = count_body
            self.up.revoke = self.config['revocation_file'] if revoke else None
            self.assertIn(self.request()[0], (400, 403))
            created = set(Path(self.tmp.name).glob('*.json')) - previous
            record = json.loads(created.pop().read_text())
            self.assertEqual(record['terminal'], terminal)
            self.assertTrue(record['reservation_id'])
        self.assertTrue(all(path.endswith('count_tokens') for path, _, _ in Upstream.requests))

    def test_transport_failure_has_terminal_evidence(self):
        with patch.object(audit_proxy, 'upstream', side_effect=OSError('secret')):
            self.assertEqual(self.request()[0], 502)
        record = json.loads(next(Path(self.tmp.name).glob('*.json')).read_text())
        self.assertEqual(record['terminal'], 'transport_error')
        self.assertTrue(record['reservation_id'])
        self.assertEqual(Upstream.requests, [])

    def test_config_rejects_unknown_and_absurd_limits(self):
        for change in ({'unknown': 1}, {'max_body_bytes': 10**12}, {'secret_file': 'relative'}):
            with self.assertRaises(ValueError):
                audit_proxy.validate_config({**self.config, **change})

    def test_request_evidence_precedes_upstream_dispatch(self):
        original = audit_proxy.upstream
        seen = []
        def checked(config, path, data):
            records = list(Path(self.tmp.name).glob('reservation-*.json'))
            self.assertEqual(len(records), 1)
            record = json.loads(records[0].read_text())
            self.assertEqual(record['terminal'], 'in_flight')
            self.assertEqual(record['request']['model'], 'claude-opus-5-5')
            seen.append(path)
            return original(config, path, data)
        with patch.object(audit_proxy, 'upstream', side_effect=checked):
            self.assertEqual(self.request()[0], 200)
        self.assertEqual(len(seen), 2)
        records = list(Path(self.tmp.name).glob('reservation-*.json'))
        self.assertEqual(len(records), 1)
        self.assertEqual(json.loads(records[0].read_text())['terminal'], 'complete')

    def test_initial_evidence_failure_prevents_dispatch(self):
        with patch.object(audit_proxy, 'save_evidence', side_effect=OSError('disk full')):
            self.assertEqual(self.request()[0], 502)
        self.assertEqual(Upstream.requests, [])
        self.assertEqual(self.request()[0], 503)

    def test_startup_rejects_corrupt_ledger_data(self):
        with audit_proxy.closing(sqlite3.connect(self.config['ledger'])) as db:
            db.execute("INSERT INTO reservations VALUES ('run', -1, 1)")
            db.commit()
        with self.assertRaises(ValueError):
            audit_proxy.make_server(self.config)

    def test_evidence_failure_blocks_subsequent_dispatch(self):
        original = audit_proxy.save_evidence
        def fail_terminal(*args):
            if args[4] != 'in_flight':
                raise OSError('disk full')
            return original(*args)
        with patch.object(audit_proxy, 'save_evidence', side_effect=fail_terminal):
            self.assertEqual(self.request()[0], 200)
        previous = len(Upstream.requests)
        self.assertEqual(self.request()[0], 503)
        self.assertEqual(len(Upstream.requests), previous)
        conn = HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        conn.request('GET', '/health')
        response = conn.getresponse()
        self.assertEqual(response.status, 503)
        response.read()
        conn.close()
        with audit_proxy.closing(sqlite3.connect(self.config['ledger'])) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM reservations').fetchone()[0], 1)

    def test_missing_and_replaced_ledger_rejected(self):
        os.unlink(self.config['ledger'])
        with self.assertRaises((ValueError, sqlite3.Error)):
            audit_proxy.make_server(self.config)
        self.assertFalse(Path(self.config['ledger']).exists())
        self.assertEqual(self.request()[0], 502)
        self.assertEqual(Upstream.requests, [])
        self.assertFalse(Path(self.config['ledger']).exists())
        with audit_proxy.closing(sqlite3.connect(self.config['ledger'])) as db:
            db.execute('CREATE TABLE audit_identity (id TEXT NOT NULL)')
            db.execute("INSERT INTO audit_identity VALUES ('wrong')")
            db.execute('CREATE TABLE reservations (run_id TEXT NOT NULL, amount INTEGER NOT NULL, created_at REAL NOT NULL)')
            db.commit()
        self.assertEqual(self.request()[0], 502)
        self.assertEqual(Upstream.requests, [])

    def test_request_id_forwarded_and_recorded(self):
        conn = HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        body = json.dumps({'model': 'claude-opus-5-5', 'messages': [], 'max_tokens': 10})
        conn.request('POST', '/v1/messages', body, {'x-api-key': 'token-canary'})
        response = conn.getresponse()
        self.assertEqual(response.getheader('request-id'), 'req-synthetic')
        response.read()
        conn.close()
        record = json.loads(next(Path(self.tmp.name).glob('reservation-*.json')).read_text())
        self.assertEqual(record['request_id'], 'req-synthetic')

    def test_revocation_interrupts_held_stream(self):
        self.up.started, self.up.release = threading.Event(), threading.Event()
        self.up.hold = True
        self.addCleanup(self.up.release.set)
        done = threading.Event()
        def call():
            try:
                self.request({'model': 'claude-opus-5-5', 'messages': [], 'max_tokens': 10, 'stream': True})
            finally:
                done.set()
        thread = threading.Thread(target=call)
        thread.start()
        self.assertTrue(self.up.started.wait(10))
        Path(self.config['revocation_file']).touch()
        self.assertTrue(done.wait(10))
        thread.join(10)
        record = json.loads(next(Path(self.tmp.name).glob('reservation-*.json')).read_text())
        self.assertEqual(record['terminal'], 'revoked')

    def test_expiry_interrupts_held_stream(self):
        self.up.started, self.up.release = threading.Event(), threading.Event()
        self.up.hold = True
        self.addCleanup(self.up.release.set)
        done = threading.Event()
        def call():
            try:
                self.request({'model': 'claude-opus-5-5', 'messages': [], 'max_tokens': 10, 'stream': True})
            finally:
                done.set()
        thread = threading.Thread(target=call)
        thread.start()
        self.assertTrue(self.up.started.wait(10))
        self.server.config['expires_at'] = time.time() - 1
        self.assertTrue(done.wait(10))
        thread.join(10)
        record = json.loads(next(Path(self.tmp.name).glob('reservation-*.json')).read_text())
        self.assertEqual(record['terminal'], 'expired')

    def test_request_id_redacts_secrets(self):
        self.up.request_id = 'key-canary-token-canary'
        with audit_proxy.closing(HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)) as conn:
            body = json.dumps({'model': 'claude-opus-5-5', 'messages': [], 'max_tokens': 10})
            conn.request('POST', '/v1/messages', body, {'x-api-key': 'token-canary'})
            response = conn.getresponse()
            request_id = response.getheader('request-id')
            self.assertNotIn('key-canary', request_id)
            self.assertNotIn('token-canary', request_id)
            response.read()
        record = json.loads(next(Path(self.tmp.name).glob('reservation-*.json')).read_text())
        self.assertEqual(record['request_id'], request_id)

    def test_concurrent_budget(self):
        self.stop()
        self.config['run_budget_usd'] = 0.0011
        self.start()
        results = []
        threads = [threading.Thread(target=lambda: results.append(self.request()[0])) for _ in range(4)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(10)
        self.assertEqual(sorted(results), [200, 429, 429, 429])

    def test_remote_content_sources_are_refused_and_recorded(self):
        image = {'type': 'image', 'source': {'type': 'url', 'url': 'https://example.test/x.png'}}
        document = {'type': 'document', 'source': {'type': 'file', 'file_id': 'file_123'}}
        nested = {'type': 'tool_result', 'tool_use_id': 't', 'content': [image]}
        for block in (image, document, nested):
            with self.subTest(block=block['type']):
                body = {'model': 'claude-opus-5-5', 'max_tokens': 10,
                        'messages': [{'role': 'user', 'content': [block]}]}
                self.assertEqual(self.request(body)[0], 400)
        system = {'model': 'claude-opus-5-5', 'max_tokens': 10, 'messages': [], 'system': [image]}
        self.assertEqual(self.request(system)[0], 400)
        self.assertEqual(Upstream.requests, [])
        records = [json.loads(path.read_text()) for path in Path(self.tmp.name).glob('*.json')]
        self.assertEqual(len(records), 4)
        self.assertTrue(all(r['terminal'] == 'rejected_request' and r['status'] == 400
                            and r['reservation_id'] is None and r['run_id'] == 'run' for r in records))
        self.assertNotIn('example.test', json.dumps(records))

    def test_inline_base64_content_is_accepted(self):
        image = {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'aGk='}}
        body = {'model': 'claude-opus-5-5', 'max_tokens': 10,
                'messages': [{'role': 'user', 'content': [image, {'type': 'text', 'text': 'look'}]}]}
        self.assertEqual(self.request(body)[0], 200)

    def test_rejection_records_are_bounded(self):
        bad = {'model': 'wrong', 'messages': [], 'max_tokens': 1}
        statuses = [self.request(bad)[0] for _ in range(audit_proxy.MAX_REJECTION_RECORDS + 3)]
        self.assertEqual(statuses[:audit_proxy.MAX_REJECTION_RECORDS], [400] * audit_proxy.MAX_REJECTION_RECORDS)
        self.assertEqual(set(statuses[audit_proxy.MAX_REJECTION_RECORDS + 1:]), {503})
        self.assertEqual(len(list(Path(self.tmp.name).glob('rejection-*.json'))), audit_proxy.MAX_REJECTION_RECORDS)


if __name__ == '__main__':
    unittest.main()
