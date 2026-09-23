#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Serve the browser eval's fixture pages by hand, for AUTHORING a page.

The runners own this server during a run: `run_eval.py` and `run_capability.py`
start one `evallib.fixture_server.FixtureServer` when a selected case uses
`__EVAL_FIXTURE_URL__`, bind a token per case attempt, and stop it on every exit
path. Nothing about a run needs this CLI, and no suite names a port.

What it is for is the loop between editing a page and looking at it: it starts
the same server on an ephemeral loopback port, binds one token, and prints every
page's URL under it plus the state endpoint, so the page can be opened in a
browser and its recorded state read back:

    benchmark/bin/browser_fixture.py
    # open a printed page URL, interact with it, then:
    curl http://127.0.0.1:<port>/s/<token>/state

Loopback HTTP is the only page transport the browser policy allows without
configuration (`file://` and `data:` are hard-blocked), and it is a secure
context, which the WebMCP API requires. Every document is read once at startup —
no directory serving, no filesystem read per request, no route that reflects
request input into the body. Edit a page, restart.
"""

from __future__ import annotations

import argparse
import os
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from evallib.fixture_server import FixtureServer, ServerError  # noqa: E402

PAGES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "suites", "fixtures", "browser")


def die(msg: str) -> None:
    print(f"browser_fixture: {msg}", file=sys.stderr)
    raise SystemExit(1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Serve the browser eval's fixture pages on loopback, by hand.")
    parser.add_argument("--token", default="handauthoring",
                        help="the token the pages are served under (default: handauthoring)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        fixtures = FixtureServer(PAGES_DIR)
        port = fixtures.start()
    except ServerError as exc:
        die(str(exc))
    try:
        binding = fixtures.bind(args.token)
    except ServerError as exc:
        fixtures.stop()
        die(str(exc))
    print(f"serving {len(fixtures.documents)} document(s) on 127.0.0.1:{port}")
    for name in fixtures.documents:
        print(f"  {binding.url}/{name}")
    print(f"recorded state: {binding.url}/state")
    print("ctrl-c to stop")
    try:
        # The server runs on its own daemon thread; this one only waits to be
        # interrupted (never on stdin, which is empty when this is started
        # detached and would spin).
        threading.Event().wait()
    except KeyboardInterrupt:
        print("")
    finally:
        fixtures.stop()


if __name__ == "__main__":
    main()
