"""Loopback HTTP server that publishes the generated fixture pages.

Runner contract: build one `AimServer`, `publish(batch_id, html)` every batch's
document, `start()` once (binds `127.0.0.1:0`, returns the OS-assigned port, runs
a daemon thread), hand `url_for(batch_id, mode)` to the batch prompt, and `stop()`
in a finally. Loopback HTTP is the only page transport the browser policy allows
without configuration (`file://` and `data:` are hard-blocked), and the ephemeral
port keeps concurrent runs from colliding.

Exactly two responses exist: `GET /aim.html?batch=<known id>` -> 200 with that
batch's document, everything else -> 404. There is no directory serving, no
filesystem read, and no route that reflects request input into the body.
"""

from __future__ import annotations

import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PAGE_PATH = "/aim.html"
_BIND_HOST = "127.0.0.1"


class ServerError(RuntimeError):
    """The fixture server could not be started or was used out of order."""


class AimServer:
    def __init__(self) -> None:
        self._pages: dict[str, str] = {}
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None
        self._port: int | None = None

    # --- lifecycle ---

    def publish(self, batch_id: str, html: str) -> None:
        if not batch_id or not html:
            raise ServerError("publish needs a batch id and a rendered document")
        self._pages[batch_id] = html

    def start(self) -> int:
        if self._httpd is not None:
            raise ServerError("server already started")
        handler = _make_handler(self._pages)
        self._httpd = ThreadingHTTPServer((_BIND_HOST, 0), handler)
        self._port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever,
                                        name="aim-http", daemon=True)
        self._thread.start()
        return self._port

    def stop(self) -> None:
        if self._httpd is None:
            return
        self._httpd.shutdown()
        self._httpd.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5)
        self._httpd, self._thread, self._port = None, None, None

    # --- addressing ---

    @property
    def port(self) -> int:
        if self._port is None:
            raise ServerError("server is not started; call start() first")
        return self._port

    def url_for(self, batch_id: str, mode: str) -> str:
        if batch_id not in self._pages:
            raise ServerError(f"no page published for batch {batch_id!r}")
        return f"http://{_BIND_HOST}:{self.port}{PAGE_PATH}?batch={batch_id}&mode={mode}"


def _make_handler(pages: dict[str, str]):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
            body = _body_for(pages, self.path)
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
            """Silence the per-request stderr line; the runner owns run output."""

    return Handler


def _body_for(pages: dict[str, str], raw_path: str) -> str | None:
    """The whole routing table. Returns None for every path that is not a known
    batch's page — no fallback body, no reflected input."""
    parsed = urlparse(raw_path)
    if parsed.path != PAGE_PATH:
        return None
    batch = parse_qs(parsed.query).get("batch", [""])[0]
    return pages.get(batch)
