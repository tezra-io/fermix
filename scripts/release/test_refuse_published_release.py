#!/usr/bin/env python3
"""Hermetic tests for the published-release immutability guard."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("refuse_published_release.sh")


class RefusePublishedReleaseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-release-guard-")
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self._write_fake_curl()

    def tearDown(self):
        self.tmp.cleanup()

    def test_allows_a_tag_without_a_release(self):
        result = self._run(404)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_allows_an_existing_draft_for_the_same_tag(self):
        result = self._run(200, {"draft": True})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("existing draft", result.stdout)

    def test_refuses_an_already_published_release(self):
        result = self._run(200, {"draft": False})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release is already published", result.stderr)
        self.assertNotIn("test-token", result.stdout + result.stderr)

    def test_fails_closed_on_an_unexpected_api_status(self):
        result = self._run(500, {"message": "server failure"})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 500", result.stderr)

    def test_fails_closed_when_the_api_request_cannot_complete(self):
        result = self._run(0, curl_exit=7)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot query GitHub release state", result.stderr)
        self.assertNotIn("test-token", result.stdout + result.stderr)

    def test_rejects_missing_arguments(self):
        result = subprocess.run(
            [str(SCRIPT), "tezra-io/fermix"],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage:", result.stderr)

    def _run(self, status, body=None, curl_exit=0):
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.bin}:{environment['PATH']}",
                "GH_TOKEN": "test-token",
                "FAKE_STATUS": str(status),
                "FAKE_BODY": json.dumps(body or {}),
                "FAKE_CURL_EXIT": str(curl_exit),
            }
        )
        return subprocess.run(
            [str(SCRIPT), "tezra-io/fermix", "v0.9.0"],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def _write_fake_curl(self):
        path = self.bin / "curl"
        path.write_text(
            """#!/bin/sh
set -eu
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "${FAKE_CURL_EXIT:-0}" -eq 0 ] || exit "$FAKE_CURL_EXIT"
printf '%s\n' "$FAKE_BODY" > "$output"
printf '%s' "$FAKE_STATUS"
""",
            encoding="utf-8",
        )
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
