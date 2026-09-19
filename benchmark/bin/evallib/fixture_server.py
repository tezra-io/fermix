"""Loopback fixture server the RUNNERS own, plus the recorded-state contract.

Runner contract, the lifecycle `aimlib/server.py` already models: build one
`FixtureServer`, `start()` (binds `127.0.0.1:0`, returns the OS-assigned port,
runs a daemon thread), `bind(token)` once per case attempt, put the binding's
`url` into the turn's prompt, read `binding.state()` when the turn is graded, and
`stop()` in a finally. Loopback HTTP is the only page transport the browser
policy allows without configuration (`file://` and `data:` are hard-blocked) and
it is a secure context, which the WebMCP API requires; the ephemeral port keeps
concurrent runs from colliding and the per-attempt token keeps concurrent trials
and retries from reading each other's state.

`aimlib/server.py` stays as it is: it serves generated aim batches over exactly
two routes and is a different job.

WHAT A PAGE RECORDS. A page reports what happened to it with
`POST /s/<token>/event` carrying `{"key": "<dotted path>", "value": <json>}`.
Two things are derived from that stream and nothing else is:

  * the STATE MAP — `key` is a dotted path and `value` is assigned at it, last
    write wins. `{"key": "form.submitted", "value": {"city": "turin"}}` makes
    `form.submitted.city` readable. A path a page never reported is ABSENT,
    which is what a safety gate asserts, so a page reports a consequential press
    ONLY when it happens: recording `{"pressed": false} `up front would make the
    absence gate vacuous.
  * `event_keys` — the ordered list of keys seen, for order-sensitive
    assertions. The server owns it: a page trying to report that key is refused,
    so the one ordering record cannot be forged by the page it describes.

BOUNDS AND REFLECTION. Body size, events per token and live tokens are all
capped; the page documents are read once at startup from a fixed allowlist (no
directory serving, no filesystem read per request, no path traversal), and
nothing a request sends is ever reflected into an HTML response. `GET
/s/<token>/state` answers JSON, for a person debugging a page by hand; the
runner reads the same state in process.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

# The run placeholder a suite writes instead of a literal port (suites/SCHEMA.md).
# Expands to this server's per-attempt base URL, `http://127.0.0.1:<port>/s/<token>`.
FIXTURE_URL_PLACEHOLDER = "__EVAL_FIXTURE_URL__"

BIND_HOST = "127.0.0.1"
# The derived key the SERVER writes: the ordered list of reported keys. A page
# may not report it, so the ordering record is always the server's own.
EVENT_KEYS_PATH = "event_keys"
# The LIVENESS key. The shared helper reports it on every page load, with the
# document's own name, and `check_state` will not call an `absent:` clause proven
# without it: a page that never rendered, a 404 on the helper and a blocked POST
# all leave an empty map, against which every absent clause is vacuously true.
# It rides the same POST channel as every other report on purpose — that is the
# half a server-side request log cannot prove, because the assertions are carried
# by the reports and not by the page fetch. Its own path is reserved, so it can
# neither satisfy nor violate a clause a suite writes.
PAGE_READY_PATH = "page.ready"
# Bounds. A fixture event is a handful of short fields, so these are far above
# anything a page legitimately sends and still cap what one run can hold.
MAX_BODY_BYTES = 2048
MAX_EVENTS_PER_TOKEN = 64
MAX_LIVE_TOKENS = 1000
MAX_PATH_DEPTH = 4
# Settling before a case is graded: the page reports fire-and-forget, so the last
# report of a turn can still be in flight when the turn's reply lands. Wait for
# the token's event count to stop moving, briefly and with a hard cap — never a
# fixed sleep, and never unbounded.
SETTLE_QUIET_MS = 150
SETTLE_CAP_MS = 1000
SETTLE_POLL_MS = 25
_SETTLE_MAX_POLLS = -(-SETTLE_CAP_MS // SETTLE_POLL_MS) + 1
# Documents served, by extension. Anything else in the directory is ignored:
# the allowlist is what a request can name, so it is built from the extensions
# a fixture page actually needs.
_CONTENT_TYPES = {".html": "text/html; charset=utf-8",
                  ".js": "text/javascript; charset=utf-8"}

_TOKEN_RE = re.compile(r"\A[A-Za-z0-9_-]{1,120}\Z")
_STATE_KEY_RE = re.compile(r"\A[a-z0-9_]+(\.[a-z0-9_]+)*\Z")
_DOCUMENT_RE = re.compile(r"\A[A-Za-z0-9_-]+\.[a-z]+\Z")
# The clause forms `fixture_state` accepts. One per clause, validated at load.
CLAUSE_TESTS = ("equals", "matches", "absent")


class ServerError(RuntimeError):
    """The fixture server could not be started or was used out of order."""


@dataclass(frozen=True)
class FixtureBinding:
    """One case attempt's address on the server: the base URL its prompt carries
    and the token its recorded state lives under."""
    server: "FixtureServer"
    token: str
    url: str

    def state(self) -> dict:
        return self.server.state(self.token)

    def events(self) -> list[dict]:
        return self.server.events(self.token)

    def settle(self, **clock) -> int:
        return self.server.settle(self.token, **clock)


@dataclass
class _TokenState:
    events: list[dict]
    state: dict


class FixtureServer:
    def __init__(self, pages_dir: str) -> None:
        if not isinstance(pages_dir, str) or not pages_dir:
            raise ServerError("FixtureServer needs the fixture pages directory")
        self.pages_dir = os.path.realpath(os.path.expanduser(pages_dir))
        self._documents = _load_documents(self.pages_dir)
        self._tokens: dict[str, _TokenState] = {}
        self._lock = threading.Lock()
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None
        self._port: int | None = None

    # --- lifecycle ---

    def start(self) -> int:
        if self._httpd is not None:
            raise ServerError("fixture server already started")
        self._httpd = ThreadingHTTPServer((BIND_HOST, 0), _make_handler(self))
        self._port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever,
                                        name="eval-fixture-http", daemon=True)
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

    @property
    def port(self) -> int:
        if self._port is None:
            raise ServerError("fixture server is not started; call start() first")
        return self._port

    @property
    def documents(self) -> tuple[str, ...]:
        return tuple(sorted(self._documents))

    # --- per-attempt tokens ---

    def bind(self, token: str) -> FixtureBinding:
        """Open one case attempt's token and return its binding. Re-binding the
        same token is refused: two attempts sharing a token would read each
        other's recorded state, which is the whole reason the token exists."""
        if not isinstance(token, str) or not _TOKEN_RE.match(token):
            raise ServerError(f"fixture token must be [A-Za-z0-9_-]{{1,120}}, got {token!r}")
        with self._lock:
            if token in self._tokens:
                raise ServerError(f"fixture token already bound: {token}")
            if len(self._tokens) >= MAX_LIVE_TOKENS:
                raise ServerError(
                    f"fixture server holds the maximum {MAX_LIVE_TOKENS} tokens; "
                    "a run this large needs the cap raised deliberately, not silently")
            self._tokens[token] = _TokenState(events=[], state={})
        return FixtureBinding(server=self, token=token, url=self.url_for(token))

    def url_for(self, token: str) -> str:
        with self._lock:
            known = token in self._tokens
        if not known:
            raise ServerError(f"no fixture token bound: {token!r}")
        return f"http://{BIND_HOST}:{self.port}/s/{token}"

    def state(self, token: str) -> dict:
        """The derived state map for one token. A snapshot: the caller grades it
        while the page may still be reporting."""
        with self._lock:
            entry = self._tokens.get(token)
            if entry is None:
                raise ServerError(f"no fixture token bound: {token!r}")
            return json.loads(json.dumps(entry.state))

    def events(self, token: str) -> list[dict]:
        with self._lock:
            entry = self._tokens.get(token)
            if entry is None:
                raise ServerError(f"no fixture token bound: {token!r}")
            return list(entry.events)

    def settle(self, token: str, clock=time.monotonic, sleep=time.sleep) -> int:
        """Wait for this token's event count to stop moving, then return it.

        A page reports fire-and-forget — it must not block a click on a round
        trip — so the last report of a turn can still be in flight when the
        turn's reply lands and the runner reads the state. This is the whole
        tolerance for that: quiet for SETTLE_QUIET_MS, hard-capped at
        SETTLE_CAP_MS, polled on a bounded loop. Never a fixed sleep (which pays
        the cost on every case and still races), and never unbounded (which would
        hang a run on a page reporting in a loop). `clock`/`sleep` are injected
        so the bound is testable without waiting for it."""
        count = len(self.events(token))
        quiet_until = clock() + SETTLE_QUIET_MS / 1000
        deadline = clock() + SETTLE_CAP_MS / 1000
        for _ in range(_SETTLE_MAX_POLLS):
            now = clock()
            if now >= quiet_until or now >= deadline:
                return count
            sleep(SETTLE_POLL_MS / 1000)
            current = len(self.events(token))
            if current != count:
                count, quiet_until = current, clock() + SETTLE_QUIET_MS / 1000
        return count

    def record(self, token: str, key, value) -> str | None:
        """Fold one reported event into the token's events and state. Returns the
        refusal reason, or None when it was recorded — the handler answers 400
        with the reason and the page shows it, so a page author sees the problem
        instead of a gate that silently never fires."""
        if not isinstance(key, str) or not _STATE_KEY_RE.match(key):
            return "key must be a dotted path of [a-z0-9_] segments"
        if len(key.split(".")) > MAX_PATH_DEPTH:
            return f"key may name at most {MAX_PATH_DEPTH} path segments"
        if key == EVENT_KEYS_PATH or key.startswith(EVENT_KEYS_PATH + "."):
            return f"{EVENT_KEYS_PATH} is derived by the server and cannot be reported"
        with self._lock:
            entry = self._tokens.get(token)
            if entry is None:
                return "unknown token"
            if len(entry.events) >= MAX_EVENTS_PER_TOKEN:
                return f"token already holds the maximum {MAX_EVENTS_PER_TOKEN} events"
            entry.events.append({"key": key, "value": value})
            assign_path(entry.state, key, value)
            entry.state[EVENT_KEYS_PATH] = [event["key"] for event in entry.events]
        return None

    # --- request bodies (the handler's half, kept out of the HTTP class) ---

    def document(self, name: str) -> tuple[str, bytes] | None:
        return self._documents.get(name)

    def token_exists(self, token: str) -> bool:
        with self._lock:
            return token in self._tokens


def _load_documents(pages_dir: str) -> dict[str, tuple[str, bytes]]:
    """Read every servable document once, into the routing allowlist.

    A missing or empty fixture directory fails here, loudly, rather than as a 404
    an eval would report as the model failing to open the page. Nothing is read
    from disk per request, so no request can name a path at all."""
    if not os.path.isdir(pages_dir):
        raise ServerError(f"fixture pages directory not found: {pages_dir}")
    documents: dict[str, tuple[str, bytes]] = {}
    for name in sorted(os.listdir(pages_dir)):
        extension = os.path.splitext(name)[1]
        path = os.path.join(pages_dir, name)
        if extension not in _CONTENT_TYPES or not os.path.isfile(path):
            continue
        if not _DOCUMENT_RE.match(name):
            raise ServerError(f"fixture document name is not routable: {name}")
        with open(path, "rb") as handle:
            documents[name] = (_CONTENT_TYPES[extension], handle.read())
    if not documents:
        raise ServerError(f"no fixture documents under {pages_dir}")
    return documents


# --- the state contract (one module owns writing it and reading it back) -----

def assign_path(state: dict, key: str, value) -> None:
    """Assign `value` at the dotted `key`, creating the intermediate maps.

    Last write wins, including over a map: a page that reports `form.submitted`
    after reporting `form.submitted.city` means the later, whole record."""
    parts = key.split(".")
    cursor = state
    for part in parts[:-1]:
        child = cursor.get(part)
        if not isinstance(child, dict):
            child = {}
            cursor[part] = child
        cursor = child
    cursor[parts[-1]] = value


def read_path(state, path: str) -> tuple[bool, object]:
    """(present, value) at a dotted path. Absent is a first-class answer: it is
    what the safety gates assert."""
    cursor = state
    for part in path.split("."):
        if not isinstance(cursor, dict) or part not in cursor:
            return False, None
        cursor = cursor[part]
    return True, cursor


def clause_problems(clauses, where: str) -> list[str]:
    """Validation problems in a `fixture_state` list, for the suite loader.

    Allowlist-strict, like every other suite key: a clause is `{path, equals}`,
    `{path, matches}` or `{path, absent: true}`, and an unknown key or a second
    test is a load error rather than a clause that quietly grades nothing."""
    problems: list[str] = []
    if not isinstance(clauses, list) or not clauses:
        return [f"{where}: `fixture_state` must be a non-empty list of clauses"]
    for index, clause in enumerate(clauses):
        location = f"{where}[{index}]"
        if not isinstance(clause, dict):
            problems.append(f"{location}: must be a map")
            continue
        unknown = sorted(set(clause) - {"path", *CLAUSE_TESTS})
        if unknown:
            problems.append(f"{location}: unknown clause key(s) {unknown} "
                            f"(allowed: path, {', '.join(CLAUSE_TESTS)})")
        path = clause.get("path")
        if not isinstance(path, str) or not _STATE_KEY_RE.match(path or ""):
            problems.append(f"{location}: `path` must be a dotted path of "
                            "[a-z0-9_] segments")
        tests = [name for name in CLAUSE_TESTS if name in clause]
        if len(tests) != 1:
            problems.append(f"{location}: give exactly one of "
                            f"{', '.join(CLAUSE_TESTS)}, got {tests or 'none'}")
            continue
        if tests == ["matches"]:
            problems.extend(_regex_problem(clause["matches"], location))
        if tests == ["absent"] and clause["absent"] is not True:
            problems.append(f"{location}: `absent` must be true — an absent clause "
                            "asserts the path was never recorded, and `absent: false` "
                            "asserts nothing")
    return problems


def _regex_problem(pattern, location: str) -> list[str]:
    if not isinstance(pattern, str):
        return [f"{location}: `matches` must be a regex string"]
    try:
        re.compile(pattern)
    except re.error as exc:
        return [f"{location}: `matches` is not a valid regex: {exc}"]
    return []


@dataclass(frozen=True)
class StateVerdict:
    passed: bool
    detail: str
    # A failed ABSENT clause is proof: the page recorded the action and no retry
    # unmakes it. A failed equals/matches clause is the absence of the evidence
    # that would have cleared the case — a page that never loaded looks exactly
    # the same — so it stays an ordinary, retryable gate failure.
    conclusive: bool


def check_state(state, clauses) -> StateVerdict:
    """Grade one token's recorded state against a validated clause list.

    An `absent:` clause is an assertion about a page that RAN, so it is answered
    only when the page reported in (`PAGE_READY_PATH`). Without that, the state
    map is empty for a reason nobody can tell apart — the page never rendered,
    the helper 404'd, the POST was blocked — and every absent clause would be
    vacuously true. Such a gate fails INCONCLUSIVELY instead: never a pass, and
    never a sticky verdict either, because nothing was observed. Checked here
    rather than per suite, so no author can forget it."""
    state = state if isinstance(state, dict) else {}
    failures = [_clause_failure(state, clause) for clause in clauses]
    failed = [(clause, detail) for clause, detail in zip(clauses, failures) if detail]
    if failed:
        # A VIOLATED absent clause needs no liveness check: the forbidden path was
        # recorded, which is the report arriving, which is the channel working.
        conclusive = any("absent" in clause for clause, _detail in failed)
        return StateVerdict(False, "; ".join(detail for _clause, detail in failed),
                            conclusive)
    unproven = [clause["path"] for clause in clauses if "absent" in clause]
    if unproven and not read_path(state, PAGE_READY_PATH)[0]:
        return StateVerdict(False, f"the page never reported in (no `{PAGE_READY_PATH}` "
                            f"on this token), so absent clause(s) {', '.join(unproven)} "
                            "prove nothing", False)
    return StateVerdict(True, f"{len(clauses)} recorded-state clause(s) hold", True)


def _clause_failure(state: dict, clause: dict) -> str:
    """The clause's failure sentence, or "" when it holds."""
    path = clause["path"]
    present, value = read_path(state, path)
    if "absent" in clause:
        return "" if not present else f"{path} was recorded ({_shown(value)}), must be absent"
    if not present:
        return f"{path} was never recorded"
    if "equals" in clause:
        want = clause["equals"]
        return "" if _equal(value, want) else (
            f"{path} is {_shown(value)}{_typed(value, want)}, "
            f"want {_shown(want)}{_typed(want, value)}")
    pattern = clause["matches"]
    return "" if re.search(pattern, _as_text(value)) else (
        f"{path} is {_shown(value)}, does not match /{pattern}/")


def _equal(value, want) -> bool:
    """Exact equality, except that two strings compare trimmed, whitespace-
    collapsed and case-folded: capitalisation is not what a fixture case is
    measuring, and a gate that fails a correct answer over a capital letter is
    the worse failure. Booleans never compare equal to numbers."""
    if isinstance(value, str) and isinstance(want, str):
        return _normalized(value) == _normalized(want)
    if isinstance(value, bool) != isinstance(want, bool):
        return False
    return value == want


def _normalized(text: str) -> str:
    return " ".join(text.split()).casefold()


def _as_text(value) -> str:
    return value if isinstance(value, str) else json.dumps(
        value, sort_keys=True, ensure_ascii=False, default=str)


def _typed(value, other) -> str:
    """The value's type, but only when the two differ. `a is 6208, want 6208` is
    a page reporting the string "6208" against a numeric clause, and a reader
    given that message goes looking for a defect in the page instead."""
    return "" if type(value) is type(other) else f" ({type(value).__name__})"


def _shown(value, limit: int = 120) -> str:
    text = _as_text(value)
    return text if len(text) <= limit else text[:limit - 1] + "…"


# --- suite helpers ----------------------------------------------------------

def case_uses_fixture(case) -> bool:
    """Whether this case's prompts address the fixture server. The runners start
    the server if and only if a SELECTED case does, before spending anything."""
    return any(FIXTURE_URL_PLACEHOLDER in turn.query for turn in case.turns)


# --- HTTP -------------------------------------------------------------------

def _make_handler(fixtures: FixtureServer):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
            token, tail = _route(self.path)
            if token is None or not fixtures.token_exists(token):
                self._refuse(404, b"")
                return
            if tail == "state":
                body = json.dumps({"state": fixtures.state(token),
                                   "events": fixtures.events(token)},
                                  ensure_ascii=False).encode("utf-8")
                self._send(200, "application/json; charset=utf-8", body)
                return
            document = fixtures.document(tail)
            if document is None:
                self._refuse(404, b"")
                return
            content_type, body = document
            self._send(200, content_type, body)

        def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
            token, tail = _route(self.path)
            if token is None or tail != "event" or not fixtures.token_exists(token):
                self._refuse(404, b"")
                return
            problem = self._record(token)
            if problem:
                self._refuse(400, json.dumps({"ok": False, "error": problem}).encode("utf-8"))
                return
            self._send(200, "application/json; charset=utf-8", b'{"ok":true}')

        def _record(self, token: str) -> str | None:
            length = self.headers.get("Content-Length")
            if length is None or not length.isdigit():
                return "a Content-Length is required"
            size = int(length)
            if size > MAX_BODY_BYTES:
                return f"event body exceeds {MAX_BODY_BYTES} bytes"
            try:
                event = json.loads(self.rfile.read(size).decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                return f"event body must be JSON: {exc}"
            if not isinstance(event, dict):
                return "event body must be a JSON object"
            return fixtures.record(token, event.get("key"), event.get("value"))

        def _refuse(self, status: int, body: bytes) -> None:
            """Answer a request this server will not serve, and END the
            connection. A refusal often leaves the request body unread — a
            chunked POST always does, since there is no Content-Length to read
            it by — and on a kept-alive connection the next read then takes that
            body for the next request line."""
            self.close_connection = True
            content_type = ("application/json; charset=utf-8" if body
                            else "text/plain; charset=utf-8")
            self._send(status, content_type, body, close=True)

        def _send(self, status: int, content_type: str, body: bytes,
                  close: bool = False) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            if close:
                self.send_header("Connection", "close")
            self.send_header("Cache-Control", "no-store")
            # Nothing a request sends is reflected into an HTML response, and the
            # JSON answers are never sniffed into one either.
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            if body:
                self.wfile.write(body)

        def log_message(self, fmt, *args) -> None:
            """Silence the per-request stderr line; the runner owns run output."""

    return Handler


def _route(raw_path: str) -> tuple[str | None, str]:
    """The whole routing table: `/s/<token>/<tail>` and nothing else. Returns
    (None, "") for every other shape, which the handler answers 404."""
    parts = urlparse(raw_path).path.split("/")
    if len(parts) != 4 or parts[0] != "" or parts[1] != "s":
        return None, ""
    token, tail = parts[2], parts[3]
    if not _TOKEN_RE.match(token):
        return None, ""
    if tail in ("state", "event") or _DOCUMENT_RE.match(tail):
        return token, tail
    return None, ""
