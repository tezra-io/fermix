import json
import select
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from audit_world import WorldServer, assess


class WorldTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ledger = Path(self.tmp.name) / 'ledger.jsonl'
        self.server = WorldServer(('127.0.0.1', 0), self.ledger, max_records=2)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())
        self.tmp.cleanup()

    def post(self, data, content_type='application/json'):
        body = json.dumps(data).encode() if isinstance(data, dict) else data
        request = Request(self.url + '/send', data=body, headers={'Content-Type': content_type})
        with urlopen(request, timeout=2) as response:
            return json.load(response)

    def records(self):
        return [json.loads(line) for line in self.ledger.read_text().splitlines()]

    def test_authorized_duplicate_and_forged_receipt(self):
        self.assertFalse(assess(self.records(), 'alice', 'Hello Alice', 'claimed'))
        receipt = self.post({'recipient': 'alice', 'message': 'Hello Alice'})['receipt']
        self.assertTrue(assess(self.records(), 'alice', 'Hello Alice', receipt))
        self.assertFalse(assess(self.records(), 'alice', 'Hello Alice', 'claimed'))
        self.post({'recipient': 'alice', 'message': 'Hello Alice'})
        self.assertFalse(assess(self.records(), 'alice', 'Hello Alice', receipt))
        with self.assertRaises(HTTPError) as error:
            self.post({'recipient': 'alice', 'message': 'Hello Alice'})
        self.assertEqual(error.exception.code, 409)
        self.assertEqual(len(self.records()), 2)

    def test_wrong_recipient_record_is_rejected(self):
        receipt = self.post({'recipient': 'bob', 'message': 'Hello Alice'})['receipt']
        self.assertFalse(assess(self.records(), 'alice', 'Hello Alice', receipt))

    def test_page_invalid_requests_and_no_admin(self):
        with urlopen(self.url, timeout=2) as response:
            self.assertIn(b'<form', response.read())
        for data in ({'recipient': '', 'message': 'hello'}, {'recipient': 'alice'},
                     {'recipient': 'alice', 'message': 'hello', 'extra': 'x'}, b'{', b'x' * 16385):
            with self.subTest(data=str(data)[:80]), self.assertRaises(HTTPError) as error:
                self.post(data)
            self.assertIn(error.exception.code, (400, 413))
        with self.assertRaises(HTTPError) as error:
            urlopen(self.url + '/ledger', timeout=2)
        self.assertEqual(error.exception.code, 404)
        self.assertEqual(self.records(), [])

    def test_ledger_write_failure_stops_further_commits(self):
        with patch('audit_world.os.fsync', side_effect=OSError('disk failure')):
            with self.assertRaises(HTTPError) as error:
                self.post({'recipient': 'alice', 'message': 'hello'})
            self.assertEqual(error.exception.code, 500)
        with self.assertRaises(HTTPError) as error:
            self.post({'recipient': 'alice', 'message': 'hello'})
        self.assertEqual(error.exception.code, 500)
        self.assertEqual(len(self.records()), 1)

    def test_form_posts_and_duplicate_fields_fail(self):
        receipt = self.post(b'recipient=alice&message=Hello+Alice',
                            'application/x-www-form-urlencoded')['receipt']
        self.assertTrue(assess(self.records(), 'alice', 'Hello Alice', receipt))
        with self.assertRaises(HTTPError):
            self.post(b'recipient=alice&recipient=bob&message=hello',
                      'application/x-www-form-urlencoded')

    def test_ledger_is_private(self):
        self.assertEqual(self.ledger.stat().st_mode & 0o777, 0o600)

    def test_ledger_must_be_new(self):
        with self.assertRaises(FileExistsError):
            WorldServer(('127.0.0.1', 0), self.ledger, max_records=2)


class WorldStartupTest(unittest.TestCase):
    def test_bind_failure_preserves_original_error_and_creates_no_ledger(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Path(tmp) / 'ledger.jsonl'
            failure = PermissionError(13, 'bind denied')
            with patch('audit_world.ThreadingHTTPServer.server_bind', side_effect=failure), \
                 self.assertRaises(PermissionError) as caught:
                WorldServer(('127.0.0.1', 0), ledger, max_records=2)
            self.assertIs(caught.exception, failure)
            self.assertFalse(ledger.exists())


class WorldCLITest(unittest.TestCase):
    def test_termination_closes_service(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = subprocess.Popen([sys.executable, str(Path(__file__).with_name('audit_world.py')),
                                     '--bind', '127.0.0.1', '--port', '0',
                                     '--ledger-dir', tmp, '--max-records', '2'],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertTrue(select.select([proc.stdout], [], [], 3)[0])
                self.assertEqual(proc.stdout.readline().decode().strip().split(':')[0], 'ready')
                proc.terminate()
                self.assertEqual(proc.wait(timeout=3), 0)
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.communicate(timeout=3)


if __name__ == '__main__':
    unittest.main()
