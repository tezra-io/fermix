#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""A fake Fermix app, standing in for the macOS browser host, for the
`browser_host` eval suite and for hand-authoring against a dev daemon.

The real host is `tezra-io/fermix-macos`'s `BrowserHostReducer`, over
`$FERMIX_HOME/browser_host.sock`. This script speaks the same wire
(`FermixCore.BrowserHost.Protocol`, exported at `priv/browser_host/`) as its
one client: it dials the socket, completes the handshake and the attach, then
answers every request with a canned page (Example Domain, so a case's reply
can assert on real content) until the daemon closes the connection or this
process is told to stop.

Nothing about `benchmark/suites/browser_host.yaml` starts this by hand for
you: unlike the page fixture (`browser_fixture.py`), the runner owns no
lifecycle for a socket client, so a live run of that suite is a documented
external precondition, the same way `browser.yaml` requires a working Chrome
runtime already running under the dev daemon. `make dry` validates the suite
without starting anything.

    benchmark/bin/browser_host_fixture.py
    benchmark/bin/browser_host_fixture.py --fail-after 2 --fail-message "the Mac is locked"
    benchmark/bin/browser_host_fixture.py --no-attach   # a launch that connects but never attaches

Ctrl-C stops it; the daemon reads the closed socket as `host_stopping` never
having arrived at all, i.e. a plain disconnect (BROWSER-4: fails every task
bound to this connection with a sentence, never re-run on Chrome).
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys

PROTOCOL_VERSION = 1
DEFAULT_HOST_VERSION = "0.0.0-eval"
DEFAULT_PROFILE_ID = "fermix-eval"


def log(message: str) -> None:
    print(f"browser_host_fixture: {message}", file=sys.stderr, flush=True)


def send(sock: socket.socket, frame: dict) -> None:
    sock.sendall((json.dumps(frame) + "\n").encode("utf-8"))


def read_frames(sock: socket.socket):
    """Yields decoded frames from `sock`, forever, until it closes."""
    buffer = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            if line.strip():
                yield json.loads(line)


def example_page(url: str) -> dict:
    """One canned page every request answers with: real enough content
    (a heading and a link, the same shape `page.snapshot`'s fixtures use) for
    a live model to describe and click through, never the same object twice
    so callers may hold on to one board without mutating another's."""
    return {
        "url": url,
        "title": "Example Domain",
        "ready_state": "complete",
        "nodes": [
            {
                "nodeId": "1",
                "role": {"value": "RootWebArea"},
                "name": {"value": "Example Domain"},
                "childIds": ["2", "3"],
            },
            {
                "nodeId": "2",
                "role": {"value": "heading"},
                "name": {"value": "Example Domain"},
            },
            {
                "nodeId": "3",
                "backendDOMNodeId": 1,
                "role": {"value": "link"},
                "name": {"value": "More information..."},
            },
        ],
    }


class FakeHost:
    """One connection's worth of state: the tabs it has opened, keyed by the
    task that opened them (`task.release`'s bookkeeping), and the point past
    which it starts refusing requests (the "lock mid-task" scenario)."""

    def __init__(
        self,
        fail_after: int | None,
        fail_reason: str,
        fail_message: str,
        host_version: str,
        profile_id: str,
    ) -> None:
        self.fail_after = fail_after
        self.fail_reason = fail_reason
        self.fail_message = fail_message
        self.host_version = host_version
        self.profile_id = profile_id
        self.tabs: dict[str, str] = {}
        self.next_tab = 1
        self.answered = 0

    def next_tab_id(self) -> str:
        tab_id = f"t{self.next_tab}"
        self.next_tab += 1
        return tab_id

    def handle(self, sock: socket.socket, frame: dict) -> None:
        if "id" not in frame:
            log(f"ignoring an unsolicited daemon frame: {frame}")
            return

        request_id = frame["id"]
        request_type = frame["type"]
        self.answered += 1

        if self.fail_after is not None and self.answered >= self.fail_after:
            log(f"answering {request_type} (#{self.answered}) with {self.fail_reason}")
            send(
                sock,
                {
                    "id": request_id,
                    "ok": False,
                    "error": {"reason": self.fail_reason, "message": self.fail_message},
                },
            )
            if self.fail_reason == "host_unavailable":
                send(sock, {"type": "availability", "available": False, "reason": self.fail_message})
            return

        log(f"answering {request_type} (#{self.answered})")
        send(sock, {"id": request_id, "ok": True, "result": self.answer(request_type, frame)})

    def answer(self, request_type: str, frame: dict) -> dict:
        if request_type == "tab.open":
            return self.opened(frame)
        if request_type == "tab.navigate":
            return self.navigated(frame)
        if request_type == "tab.list":
            return self.listed(frame)
        if request_type == "tab.focus":
            return {"tab_id": frame["tab_id"], "url": "https://example.com/", "title": "Example Domain"}
        if request_type == "tab.close":
            self.tabs.pop(frame["tab_id"], None)
            return {"tab_id": frame["tab_id"]}
        if request_type == "task.release":
            return self.released(frame["task_id"])
        if request_type == "page.snapshot":
            return snapshot_result(example_page(frame_url(frame)))
        if request_type == "page.act":
            return self.acted(frame)
        if request_type in ("page.screenshot", "page.pdf"):
            return self.captured(request_type, frame)
        if request_type == "page.upload":
            return {"tab_id": frame["tab_id"]}
        if request_type == "dialog.resolve":
            return {"tab_id": frame["tab_id"]}
        if request_type == "cookies.get":
            return {"url": "https://example.com/", "cookies": []}
        if request_type == "cookies.clear":
            return {"cleared": 0}
        if request_type == "host.status":
            return {
                "host_version": self.host_version,
                "profile_id": self.profile_id,
                "available": True,
                "task_tabs": len(self.tabs),
                "person_tabs": 0,
            }
        if request_type == "host.stop_ack":
            return {}
        raise SystemExit(f"browser_host_fixture: no answer scripted for {request_type}")

    def opened(self, frame: dict) -> dict:
        tab_id = self.next_tab_id()
        self.tabs[tab_id] = frame["task_id"]
        page = example_page(frame["url"])
        result = {"tab_id": tab_id, "url": frame["url"], "title": page["title"]}
        if frame.get("observe"):
            result["page"] = page
        return result

    def navigated(self, frame: dict) -> dict:
        page = example_page(frame["url"])
        result = {"tab_id": frame["tab_id"], "url": frame["url"], "title": page["title"]}
        if frame.get("observe"):
            result["page"] = page
        return result

    def listed(self, frame: dict) -> dict:
        task_id = frame["task_id"]
        tabs = [
            {"tab_id": tab_id, "url": "https://example.com/", "title": "Example Domain", "active": True}
            for tab_id, owner in self.tabs.items()
            if owner == task_id
        ]
        return {"tabs": tabs}

    def released(self, task_id: str) -> dict:
        released = [tab_id for tab_id, owner in self.tabs.items() if owner == task_id]
        for tab_id in released:
            del self.tabs[tab_id]
        log(f"released task {task_id}: {released or '(nothing open)'}")
        return {"released": released}

    def acted(self, frame: dict) -> dict:
        page = example_page("https://example.com/")
        result = {"url": page["url"], "title": page["title"]}
        if frame.get("kind") == "get":
            result["value"] = "Example Domain"
        if frame.get("observe"):
            result["page"] = page
        return result

    def captured(self, request_type: str, frame: dict) -> dict:
        path = frame["path"]
        with open(path, "wb") as stream:
            stream.write(b"")
        result = {"path": path, "bytes": 0, "url": "https://example.com/"}
        if request_type == "page.screenshot":
            result.update({"mime_type": "image/png", "device_pixel_ratio": 1})
        else:
            result["mime_type"] = "application/pdf"
        return result


def frame_url(frame: dict) -> str:
    return frame.get("url", "https://example.com/")


def snapshot_result(page: dict) -> dict:
    return {"url": page["url"], "title": page["title"], "ready_state": page["ready_state"], "nodes": page["nodes"]}


def negotiate(sock: socket.socket) -> None:
    send(sock, {"type": "client_hello", "protocol_version": PROTOCOL_VERSION})
    for frame in read_frames(sock):
        if frame.get("type") == "server_hello":
            return
        raise SystemExit(f"browser_host_fixture: handshake refused: {frame}")
    raise SystemExit("browser_host_fixture: the daemon closed the socket before server_hello")


def run(args: argparse.Namespace) -> None:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(args.socket)
    negotiate(sock)
    log(f"handshake complete on {args.socket}")

    if args.no_attach:
        log("not attaching: simulating a launch that connected but never reported (launch-deadline scenario)")
        log("holding the connection open; ctrl-c to disconnect")
        try:
            for _frame in read_frames(sock):
                log("ignoring a frame received before ever attaching")
        except KeyboardInterrupt:
            log("stopping")
        finally:
            sock.close()
        return

    send(sock, {"type": "attached", "host_version": args.host_version, "profile_id": args.profile_id})
    send(sock, {"type": "availability", "available": True})
    log(f"attached as {args.profile_id}; waiting for requests")

    host = FakeHost(args.fail_after, args.fail_reason, args.fail_message, args.host_version, args.profile_id)
    try:
        for frame in read_frames(sock):
            host.handle(sock, frame)
    except KeyboardInterrupt:
        log("stopping")
    finally:
        sock.close()


def parse_args() -> argparse.Namespace:
    default_socket = os.path.join(
        os.environ.get("FERMIX_HOME", os.path.expanduser("~/.fermix")), "browser_host.sock"
    )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=default_socket, help="browser_host.sock path (default: $FERMIX_HOME)")
    parser.add_argument("--host-version", default=DEFAULT_HOST_VERSION)
    parser.add_argument("--profile-id", default=DEFAULT_PROFILE_ID)
    parser.add_argument(
        "--fail-after",
        type=int,
        default=None,
        help="answer the Nth request onward (and every one after) with --fail-reason instead",
    )
    parser.add_argument("--fail-reason", default="host_unavailable")
    parser.add_argument("--fail-message", default="the Mac is locked")
    parser.add_argument(
        "--no-attach",
        action="store_true",
        help="complete the handshake, then hang up without ever attaching",
    )
    return parser.parse_args()


def main() -> None:
    run(parse_args())


if __name__ == "__main__":
    main()
