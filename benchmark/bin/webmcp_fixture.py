#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Serve the two WebMCP counter fixture pages on loopback, for the browser evals.

The `webmcp` action's eval cases need a page that offers WebMCP tools. Loopback
HTTP is the only page transport the browser policy allows without configuration
(`file://` and `data:` are hard-blocked), and it is a secure context, which the
WebMCP API requires. Start this before the run, leave it up, stop it after:

    benchmark/bin/webmcp_fixture.py

    # behavioral (needs the dev daemon + --judge)
    cd benchmark && uv run bin/run_eval.py --suite browser \\
      --scenario page_offered_tools --judge

    # capability (needs the disposable capability daemon)
    cd benchmark && uv run bin/run_capability.py --candidates \\
      --suite cap_browser_webmcp --trials 3 \\
      --confirm-daemon-isolated --confirm-isolated-env

Unlike `aimlib.server` (which `run_aim.py` owns, starts on an ephemeral port and
hands the resulting URL to the prompt it generates), this server is NOT started
by a runner: neither `run_eval.py` nor `run_capability.py` has a fixture-server
seam, and a suite's `query` is authored text with no URL placeholder. So the port
is FIXED and the suites name it literally. `--port` exists for a clash, and moving
it means editing those two suites in the same change.

Exactly three responses exist: `GET /shimmed.html`, `GET /native-only.html`, and
404 for everything else. Both documents are read once at startup — there is no
directory serving, no filesystem read per request, and no route that reflects
request input into the body. Edit a page, restart the server.
"""

from __future__ import annotations

import argparse
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND_HOST = "127.0.0.1"
DEFAULT_PORT = 8977
PAGES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "suites", "fixtures", "webmcp")
# The whole routing table: request path -> the document that answers it.
ROUTES = {"/shimmed.html": "shimmed.html", "/native-only.html": "native_only.html"}


def die(msg: str) -> None:
    print(f"webmcp_fixture: {msg}", file=sys.stderr)
    raise SystemExit(1)


def load_pages() -> dict[str, str]:
    """Read every routed document once. A missing fixture fails here, loudly, rather
    than as a 404 an eval would report as the model failing to open the page."""
    pages = {}
    for route, name in ROUTES.items():
        path = os.path.join(PAGES_DIR, name)
        if not os.path.isfile(path):
            die(f"missing fixture page: {path}")
        with open(path, encoding="utf-8") as fh:
            pages[route] = fh.read()
    return pages


def make_handler(pages: dict[str, str]):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
            body = pages.get(self.path.split("?", 1)[0])
            if body is None:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            raw = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, fmt, *args) -> None:
            """Silence the per-request stderr line; the served URLs are the output."""

    return Handler


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Serve the WebMCP counter fixture pages on loopback.")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"loopback port (default {DEFAULT_PORT}); the suites name the "
                             "default literally, so another port needs them edited too")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not 1 <= args.port <= 65535:
        die(f"--port must be a TCP port, got {args.port}")
    pages = load_pages()
    try:
        httpd = ThreadingHTTPServer((BIND_HOST, args.port), make_handler(pages))
    except OSError as exc:
        die(f"cannot bind {BIND_HOST}:{args.port}: {exc}")
    for route in ROUTES:
        print(f"serving http://{BIND_HOST}:{args.port}{route}")
    print("ctrl-c to stop")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
