"""Drive an eval case over the companion chat socket (`$FERMIX_HOME/companion.sock`).

The socket is the Mac app's chat: newline-delimited JSON with a `type`
discriminator, a mandatory `client_hello`, and the chat vocabulary exported in
`apps/fermix_core/priv/companion/`. The runner speaks it the way the app does, so
a `drive: companion` case exercises the real companion path end to end — the
socket, the durable claim, the queue, the turn's ending on the wire — and not
`fermix ask`'s CLI channel.

A case is one message, optionally with one of three choreographies around it
(the `companion:` map of the case):

- `cancel: running` sends `cancel` for the message as soon as its
  `turn_started` arrives, so the turn is demonstrably running; `cancel:
  waiting` first sends a `blocker` message, then this one, and cancels this one
  once it is accepted, while it waits behind the blocker's turn.
- `reads` issues history reads once the turn ended: `history_after` pages
  forward from where the conversation stood before the message, `history_before`
  pages backward from the head, and `search` searches for the case's marker.
- `offline_wait_s`: once the turn ended the connection is closed, and
  `catch_up` waits until that long has passed with no client connected, then
  reconnects and reads what the timeline gained meanwhile (a scheduled job's
  delivery, for one). The runner grades the turn's trace inside that wait,
  before anything the turn scheduled can run.

Every attempt starts with `/new`, so a case is its own conversation as an `ask`
case is, and every message carries a unique marker so the attempt's trace, rows
and search hits are its own.

What the wire said becomes `wire.*` gates (`wire_gates`); the trace, when there
is one to grade, is graded by the ordinary gates.
"""

from __future__ import annotations

import json
import os
import re
import socket
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

from .grade import GateResult

PROTOCOL_VERSION = 1
PROFILE = "main"
SOCKET_NAME = "companion.sock"

EVENT_TYPES = ("accepted", "row", "turn_started", "text_delta", "tool_event", "text_done",
               "turn_error")
READS = ("history_after", "history_before", "search")
CANCEL_MODES = ("running", "waiting")
SPEC_KEYS = {"cancel", "blocker", "reads", "offline_wait_s"}
WIRE_KEYS = {"events_all", "events_none", "error_code", "blocker_events_all",
             "reads_find_marker", "offline_row_matches"}
MAX_OFFLINE_WAIT_S = 900

# How long to keep reading after a turn's first `text_done`: a turn's replies
# are written and announced together at its completion, so its later parts
# follow the first immediately.
_DRAIN_S = 1.0
_PAGE_LIMIT = 200
_SEARCH_LIMIT = 10


class CompanionError(Exception):
    """The socket refused, closed, or never answered: the attempt is not gradable."""


# --- suite validation ---------------------------------------------------------

def spec_problems(spec, where: str) -> list[str]:
    """What is wrong with a case's `companion:` map."""
    if not isinstance(spec, dict):
        return [f"{where}: `companion` must be a map"]
    problems = [f"{where}: unknown `companion` key `{key}`" for key in spec
                if key not in SPEC_KEYS]
    cancel = spec.get("cancel")
    if cancel is not None and cancel not in CANCEL_MODES:
        problems.append(f"{where}: `companion.cancel` must be one of {list(CANCEL_MODES)}")
    blocker = spec.get("blocker")
    if cancel == "waiting" and not (isinstance(blocker, str) and blocker.strip()):
        problems.append(f"{where}: `companion.cancel: waiting` needs a `blocker` message")
    if blocker is not None and cancel != "waiting":
        problems.append(f"{where}: `companion.blocker` only goes with `cancel: waiting`")
    reads = spec.get("reads", [])
    if not isinstance(reads, list) or any(read not in READS for read in reads):
        problems.append(f"{where}: `companion.reads` must be a list drawn from {list(READS)}")
    wait = spec.get("offline_wait_s")
    if wait is not None and (isinstance(wait, bool) or not isinstance(wait, int)
                             or not 1 <= wait <= MAX_OFFLINE_WAIT_S):
        problems.append(f"{where}: `companion.offline_wait_s` must be an integer "
                        f"1..{MAX_OFFLINE_WAIT_S}")
    if cancel is not None and (reads or wait is not None):
        problems.append(f"{where}: a cancelled message has no turn to read back; "
                        "`reads` and `offline_wait_s` go without `cancel`")
    return problems


def wire_problems(wire, spec: dict, where: str) -> list[str]:
    """What is wrong with an `expect.wire` map, given the case's choreography."""
    if not isinstance(wire, dict):
        return [f"{where}: expect `wire` must be a map"]
    problems = [f"{where}: unknown `wire` key `{key}`" for key in wire if key not in WIRE_KEYS]
    for key in ("events_all", "events_none", "blocker_events_all"):
        value = wire.get(key)
        if value is not None and (not isinstance(value, list) or not value
                                  or any(event not in EVENT_TYPES for event in value)):
            problems.append(f"{where}: `wire.{key}` must be a non-empty list drawn from "
                            f"{list(EVENT_TYPES)}")
    if "error_code" in wire and not (isinstance(wire["error_code"], str) and wire["error_code"]):
        problems.append(f"{where}: `wire.error_code` must be a non-empty string")
    if "blocker_events_all" in wire and spec.get("cancel") != "waiting":
        problems.append(f"{where}: `wire.blocker_events_all` needs `companion.cancel: waiting`")
    if "reads_find_marker" in wire:
        if wire["reads_find_marker"] is not True:
            problems.append(f"{where}: `wire.reads_find_marker` must be true")
        if not spec.get("reads"):
            problems.append(f"{where}: `wire.reads_find_marker` needs `companion.reads`")
    if "offline_row_matches" in wire:
        pattern = wire["offline_row_matches"]
        if not isinstance(pattern, str):
            problems.append(f"{where}: `wire.offline_row_matches` must be a regex string")
        else:
            try:
                re.compile(pattern)
            except re.error as exc:
                problems.append(f"{where}: `wire.offline_row_matches` is not a valid regex: {exc}")
        if spec.get("offline_wait_s") is None:
            problems.append(f"{where}: `wire.offline_row_matches` needs `companion.offline_wait_s`")
    return problems


# --- evidence -----------------------------------------------------------------

@dataclass
class TurnWire:
    """Everything the socket said about one client message, in arrival order."""
    client_msg_id: str
    command: bool = False
    cancel_sent: bool = False
    turn_id: str | None = None
    events: list[dict] = field(default_factory=list)

    def types(self) -> set[str]:
        return {event["type"] for event in self.events}

    def ended(self) -> bool:
        return bool(self.types() & {"text_done", "turn_error"}) or self.answered()

    def answered(self) -> bool:
        """A slash command ends with its answer's `row`: it is no turn."""
        return self.command and any(e["type"] == "row" and e.get("role") == "assistant"
                                    for e in self.events)

    def error_code(self) -> str | None:
        return next((e.get("code") for e in self.events if e["type"] == "turn_error"), None)

    def reply(self) -> str:
        return "\n\n".join(e.get("text", "") for e in self.events if e["type"] == "text_done")

    def last_seq(self) -> int:
        seqs = [e["server_seq"] for e in self.events if e["type"] == "text_done"]
        return max(seqs) if seqs else 0


@dataclass
class Evidence:
    ok: bool
    error: str | None
    sent_at: datetime
    elapsed_ms: float
    target: TurnWire
    blocker: TurnWire | None = None
    reads: dict[str, bool] = field(default_factory=dict)
    closed_at: float = 0.0
    offline_rows: list[str] = field(default_factory=list)


def wire_gates(evidence: Evidence, wire: dict) -> list[GateResult]:
    """One gate per `expect.wire` key, over what the socket said."""
    out: list[GateResult] = []
    seen = sorted(evidence.target.types())

    def add(key, passed, detail):
        out.append(GateResult(key=f"wire.{key}", passed=passed, detail=detail))

    if "events_all" in wire:
        missing = [e for e in wire["events_all"] if e not in seen]
        add("events_all", not missing, f"all{wire['events_all']}: missing={missing or 'none'} "
                                       f"(seen={seen})")
    if "events_none" in wire:
        bad = [e for e in wire["events_none"] if e in seen]
        add("events_none", not bad, f"none{wire['events_none']}: present={bad or 'none'}")
    if "error_code" in wire:
        code = evidence.target.error_code()
        add("error_code", code == wire["error_code"],
            f"turn_error code {code!r}, expected {wire['error_code']!r}")
    if "blocker_events_all" in wire:
        blocker = sorted(evidence.blocker.types()) if evidence.blocker else []
        missing = [e for e in wire["blocker_events_all"] if e not in blocker]
        add("blocker_events_all", not missing,
            f"blocker all{wire['blocker_events_all']}: missing={missing or 'none'} "
            f"(seen={blocker})")
    if "reads_find_marker" in wire:
        missed = [read for read, found in evidence.reads.items() if not found]
        add("reads_find_marker", bool(evidence.reads) and not missed,
            f"reads={evidence.reads}: missed={missed or 'none'}")
    if "offline_row_matches" in wire:
        pattern = re.compile(wire["offline_row_matches"])
        hit = any(pattern.search(row) for row in evidence.offline_rows)
        add("offline_row_matches", hit,
            f"{len(evidence.offline_rows)} row(s) written while offline; "
            f"match={'yes' if hit else 'none'}")
    return out


# --- the socket ---------------------------------------------------------------

class Connection:
    """One client connection: bounded reads, one JSON object per line."""

    def __init__(self, path: str, timeout_s: float):
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.settimeout(timeout_s)
        self._buffer = b""
        try:
            self._sock.connect(path)
        except OSError as exc:
            self._sock.close()
            raise CompanionError(f"cannot connect to {path}: {exc}") from exc

    def send(self, event: dict) -> None:
        try:
            self._sock.sendall(json.dumps(event).encode("utf-8") + b"\n")
        except OSError as exc:
            raise CompanionError(f"send failed: {exc}") from exc

    def recv(self, deadline: float) -> dict | None:
        """The next event, or None once `deadline` (monotonic) passes."""
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            self._sock.settimeout(remaining)
            try:
                chunk = self._sock.recv(65536)
            except TimeoutError:
                return None
            except OSError as exc:
                raise CompanionError(f"read failed: {exc}") from exc
            if not chunk:
                raise CompanionError("the daemon closed the connection")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        try:
            return json.loads(line)
        except ValueError as exc:
            raise CompanionError(f"the daemon sent a line that is not JSON: {exc}") from exc

    def hello(self, deadline: float) -> None:
        self.send({"type": "client_hello", "protocol_version": PROTOCOL_VERSION})
        reply = self.recv(deadline)
        if reply is None or reply.get("type") != "server_hello":
            raise CompanionError(f"handshake refused: {reply!r}")

    def close(self) -> None:
        self._sock.close()


def socket_path(fermix_home: str) -> str:
    return os.path.join(os.path.expanduser(fermix_home), SOCKET_NAME)


# --- one attempt --------------------------------------------------------------

class _Session:
    """One attempt's connection plus the turns it is watching."""

    def __init__(self, conn: Connection):
        self.conn = conn
        self.turns: dict[str, TurnWire] = {}
        self.pending: list[dict] = []

    def message(self, client_msg_id: str, text: str) -> TurnWire:
        turn = TurnWire(client_msg_id)
        self.turns[client_msg_id] = turn
        self.conn.send({"type": "msg", "client_msg_id": client_msg_id, "profile_id": PROFILE,
                        "text": text, "attach_ids": []})
        return turn

    def command(self, client_msg_id: str, name: str) -> TurnWire:
        turn = TurnWire(client_msg_id, command=True)
        self.turns[client_msg_id] = turn
        self.conn.send({"type": "command", "client_msg_id": client_msg_id,
                        "profile_id": PROFILE, "name": name})
        return turn

    def cancel(self, turn: TurnWire) -> None:
        turn.cancel_sent = True
        self.conn.send({"type": "cancel", "profile_id": PROFILE,
                        "client_msg_id": turn.client_msg_id})

    def pump(self, until, deadline: float) -> bool:
        """Route events to their turns until `until()` holds; False at the deadline."""
        while not until():
            event = self.conn.recv(deadline)
            if event is None:
                return False
            self._route(event)
        return True

    def drain(self, seconds: float) -> None:
        deadline = time.monotonic() + seconds
        while (event := self.conn.recv(deadline)) is not None:
            self._route(event)

    def request(self, event: dict, answer: str, deadline: float) -> dict:
        """Send a read and return its answer, routing turn events met on the way."""
        self.conn.send(event)
        while True:
            reply = self.conn.recv(deadline)
            if reply is None:
                raise CompanionError(f"no {answer} for {event['type']}")
            if reply.get("type") == answer:
                return reply
            if reply.get("type") == "error":
                raise CompanionError(f"{event['type']} refused: {reply!r}")
            self._route(reply)

    # A request's `accepted` and its user's `row` carry its `client_msg_id`; a
    # turn is named by `in_reply_to` only in `turn_started`, and every later
    # event carries its `turn_id`. Two endings name nothing the client saw: a
    # slash command's answer (a `row` of the assistant's), and the `turn_error`
    # of a message cancelled while it waited. Each is attributed to the one
    # watched request of that kind still open, and to nothing when that is
    # ambiguous, so a stray announcement (a job's delivery) never ends a
    # watched request.
    def _route(self, event: dict) -> None:
        kind = event.get("type")
        if kind == "accepted":
            self._append(self.turns.get(event.get("client_msg_id")), event)
        elif kind == "row":
            self._append(self._row_owner(event), event)
        elif kind == "turn_started":
            turn = self.turns.get(event.get("in_reply_to"))
            if turn is not None:
                turn.turn_id = event.get("turn_id")
            self._append(turn, event)
        elif kind in EVENT_TYPES:
            self._append(self._by_turn_id(event.get("turn_id"), kind), event)

    def _row_owner(self, event: dict) -> TurnWire | None:
        if "client_msg_id" in event:
            return self.turns.get(event["client_msg_id"])
        return self._only([t for t in self.turns.values() if t.command and not t.ended()])

    def _by_turn_id(self, turn_id, kind: str) -> TurnWire | None:
        named = next((t for t in self.turns.values() if t.turn_id == turn_id), None)
        if named is not None or kind != "turn_error":
            return named
        cancelled = self._only([t for t in self.turns.values()
                                if t.turn_id is None and t.cancel_sent and not t.ended()])
        if cancelled is not None:
            cancelled.turn_id = turn_id
        return cancelled

    @staticmethod
    def _only(candidates: list[TurnWire]) -> TurnWire | None:
        return candidates[0] if len(candidates) == 1 else None

    @staticmethod
    def _append(turn: TurnWire | None, event: dict) -> None:
        if turn is not None:
            turn.events.append(event)


def drive(fermix_home: str, spec: dict, text: str, marker: str,
          timeout_s: float) -> Evidence:
    """Run one attempt: `/new`, the message and its choreography, the reads.

    The connection is closed on return; an `offline_wait_s` case continues with
    `catch_up`."""
    sent_at = datetime.now(timezone.utc)
    started = time.monotonic()
    deadline = started + timeout_s
    target = TurnWire(f"{marker}-msg")
    try:
        conn = Connection(socket_path(fermix_home), timeout_s)
    except CompanionError as exc:
        return Evidence(False, str(exc), sent_at, 0.0, target)
    session = _Session(conn)
    try:
        conn.hello(deadline)
        _fresh_conversation(session, marker, deadline)
        head = _head(session, deadline)
        target, blocker = _send(session, spec, text, marker, deadline)
        elapsed_ms = (time.monotonic() - started) * 1000.0
        reads = _reads(session, spec, marker, head, deadline)
    except CompanionError as exc:
        conn.close()
        return Evidence(False, str(exc), sent_at, (time.monotonic() - started) * 1000.0,
                        session.turns.get(target.client_msg_id, target))
    conn.close()
    return Evidence(True, None, sent_at, elapsed_ms, target, blocker, reads,
                    closed_at=time.monotonic())


def _fresh_conversation(session: _Session, marker: str, deadline: float) -> None:
    reset = session.command(f"{marker}-new", "new")
    if not session.pump(reset.ended, deadline):
        raise CompanionError("/new was not answered")


def _head(session: _Session, deadline: float) -> int:
    page = session.request({"type": "history_pull", "profile_id": PROFILE, "after_seq": 0,
                            "limit": 1}, "history_page", deadline)
    return page["history_head_seq"]


def _send(session: _Session, spec: dict, text: str, marker: str,
          deadline: float) -> tuple[TurnWire, TurnWire | None]:
    blocker = None
    if spec.get("cancel") == "waiting":
        blocker = session.message(f"{marker}-blocker", f"{spec['blocker']} (eval:{marker})")
        if not session.pump(lambda: blocker.turn_id is not None, deadline):
            raise CompanionError("the blocker's turn never started")
    target = session.message(f"{marker}-msg", f"{text} (eval:{marker})")
    if spec.get("cancel") == "waiting":
        if not session.pump(lambda: "accepted" in target.types(), deadline):
            raise CompanionError("the waiting message was never accepted")
        session.cancel(target)
    if spec.get("cancel") == "running":
        if not session.pump(lambda: target.turn_id is not None, deadline):
            raise CompanionError("the turn never started")
        session.cancel(target)
    if not session.pump(target.ended, deadline):
        raise CompanionError("the turn never ended on the wire")
    if blocker is not None and not session.pump(blocker.ended, deadline):
        raise CompanionError("the blocker's turn never ended on the wire")
    session.drain(_DRAIN_S)
    return target, blocker


def _reads(session: _Session, spec: dict, marker: str, head: int,
           deadline: float) -> dict[str, bool]:
    found: dict[str, bool] = {}
    for read in spec.get("reads", []):
        if read == "history_after":
            page = session.request({"type": "history_pull", "profile_id": PROFILE,
                                    "after_seq": head, "limit": _PAGE_LIMIT},
                                   "history_page", deadline)
            found[read] = _rows_mention(page["messages"], marker)
        elif read == "history_before":
            now = _head(session, deadline)
            page = session.request({"type": "history_pull", "profile_id": PROFILE,
                                    "before_seq": now + 1, "limit": _PAGE_LIMIT},
                                   "history_page", deadline)
            found[read] = _rows_mention(page["messages"], marker)
        else:
            results = session.request({"type": "history_search", "profile_id": PROFILE,
                                       "query": marker, "limit": _SEARCH_LIMIT},
                                      "search_results", deadline)
            found[read] = bool(results["hits"])
    return found


def _rows_mention(messages: list[dict], marker: str) -> bool:
    return any(marker in (message.get("content") or "") for message in messages)


def catch_up(fermix_home: str, wait_s: int, evidence: Evidence,
             timeout_s: float) -> Evidence:
    """No client connected for `wait_s` since `drive` closed, then read what the
    timeline gained after the turn's last row."""
    since = max(evidence.target.last_seq(), 0)
    time.sleep(max(0.0, wait_s - (time.monotonic() - evidence.closed_at)))
    deadline = time.monotonic() + timeout_s
    try:
        conn = Connection(socket_path(fermix_home), timeout_s)
    except CompanionError as exc:
        evidence.ok, evidence.error = False, str(exc)
        return evidence
    session = _Session(conn)
    try:
        conn.hello(deadline)
        page = session.request({"type": "history_pull", "profile_id": PROFILE,
                                "after_seq": since, "limit": _PAGE_LIMIT},
                               "history_page", deadline)
        evidence.offline_rows = [m.get("content") or "" for m in page["messages"]]
    except CompanionError as exc:
        evidence.ok, evidence.error = False, str(exc)
    finally:
        conn.close()
    return evidence
