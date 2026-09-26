#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7", "certifi"]
# ///
"""Specs for `drive: companion`: the suite keys, the socket client's choreography
against a scripted stand-in daemon, the attribution of turn endings, the wire
gates, and the runner's wire-only grading of a cancelled message. Pure: a local
Unix socket in a temp dir, no daemon, no Opik, no spend.
Run: `uv run bin/test_companion.py`."""
from __future__ import annotations

import json
import os
import shutil
import socket
import sys
import tempfile
import threading
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402
import yaml  # noqa: E402

import run_eval  # noqa: E402
from evallib import companion, suites  # noqa: E402


# --- a scripted stand-in daemon ----------------------------------------------

class FakeDaemon:
    """Speaks the companion wire from a script, one connection at a time.

    Every row written is announced: a user's as a `row` with its client id, a
    command's answer and a delivery as a `row`, a turn's reply as `text_done`.
    A message whose text contains LONG runs until it is cancelled; one containing
    BLOCK runs until the message queued behind it is cancelled, then completes;
    any other completes at once, or waits in the queue while a turn runs. With
    `stray`, a job's delivery row goes out while a message waits. With
    `offline_row`, that row is written once the first connection closes."""

    def __init__(self, stray: bool = False, offline_row: str | None = None):
        self.home = tempfile.mkdtemp(prefix="cmp")
        self.path = companion.socket_path(self.home)
        self.rows: list[dict] = []
        self.running: str | None = None
        self.waiting: list[str] = []
        self.stray = stray
        self.offline_row = offline_row
        self.connections = 0
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(4)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def close(self):
        self.server.close()
        shutil.rmtree(self.home, ignore_errors=True)

    def _serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            self.connections += 1
            self._handle(conn)
            conn.close()
            if self.connections == 1 and self.offline_row:
                self._append("assistant", self.offline_row)

    def _handle(self, conn):
        buffer = b""

        def send(event):
            conn.sendall(json.dumps(event).encode() + b"\n")

        while True:
            chunk = conn.recv(65536)
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                self._on(json.loads(line), send)

    def _append(self, role, content):
        row = {"server_seq": len(self.rows) + 1, "role": role, "content": content,
               "ts": "2026-09-26T09:00:00Z", "media_refs": []}
        self.rows.append(row)
        return row

    @staticmethod
    def _row(row, client_msg_id=None):
        event = {"type": "row", "profile_id": "main", "server_seq": row["server_seq"],
                 "role": row["role"], "text": row["content"], "ts": row["ts"]}
        if client_msg_id is not None:
            event["client_msg_id"] = client_msg_id
        return event

    def _on(self, event, send):
        kind = event["type"]
        if kind == "client_hello":
            send({"type": "server_hello", "min_version": 1, "max_version": 1})
        elif kind == "command":
            send({"type": "accepted", "client_msg_id": event["client_msg_id"],
                  "duplicate": False})
            send(self._row(self._append("user", "/" + event["name"]), event["client_msg_id"]))
            send(self._row(self._append("assistant", "Started a fresh session.")))
        elif kind == "history_pull":
            send(self._page(event))
        elif kind == "history_search":
            hits = [{"server_seq": r["server_seq"], "role": r["role"], "ts": r["ts"],
                     "excerpt": r["content"], "ranges": []}
                    for r in reversed(self.rows) if event["query"] in r["content"]]
            send({"type": "search_results", "profile_id": "main", "query": event["query"],
                  "hits": hits[:event["limit"]]})
        elif kind == "msg":
            send({"type": "accepted", "client_msg_id": event["client_msg_id"],
                  "duplicate": False})
            send(self._row(self._append("user", event["text"]), event["client_msg_id"]))
            self._msg(event, send)
        elif kind == "cancel":
            self._cancel(event["client_msg_id"], send)

    def _page(self, event):
        head = len(self.rows)
        if "after_seq" in event:
            rows = [r for r in self.rows if r["server_seq"] > event["after_seq"]]
            rows = rows[:event["limit"]]
            return {"type": "history_page", "profile_id": "main", "messages": rows,
                    "history_head_seq": head,
                    "next_after_seq": rows[-1]["server_seq"] if rows else event["after_seq"]}
        rows = [r for r in self.rows if r["server_seq"] < event["before_seq"]]
        return {"type": "history_page", "profile_id": "main",
                "messages": rows[-event["limit"]:], "history_head_seq": head}

    def _msg(self, event, send):
        cid = event["client_msg_id"]
        if self.running is not None:
            self.waiting.append(cid)
            if self.stray:
                send(self._row(self._append("assistant", "your 9am summary")))
            return
        send({"type": "turn_started", "profile_id": "main", "turn_id": f"turn-{cid}",
              "in_reply_to": cid})
        send({"type": "text_delta", "turn_id": f"turn-{cid}", "text": "Working"})
        if "LONG" in event["text"] or "BLOCK" in event["text"]:
            self.running = cid
            return
        send({"type": "tool_event", "turn_id": f"turn-{cid}", "tool": "shell",
              "phase": "start"})
        self._complete(cid, send)

    def _complete(self, cid, send):
        row = self._append("assistant", f"answer to {cid}")
        send({"type": "text_done", "turn_id": f"turn-{cid}", "server_seq": row["server_seq"],
              "text": row["content"]})

    def _cancel(self, cid, send):
        if cid in self.waiting:
            self.waiting.remove(cid)
            send({"type": "turn_error", "turn_id": f"turn-{cid}", "code": "cancelled",
                  "message": "cancelled"})
            blocker, self.running = self.running, None
            self._complete(blocker, send)
        elif cid == self.running:
            self.running = None
            send({"type": "turn_error", "turn_id": f"turn-{cid}", "code": "cancelled",
                  "message": "cancelled"})


@pytest.fixture
def daemon():
    made = []

    def start(**kwargs):
        fake = FakeDaemon(**kwargs)
        made.append(fake)
        return fake

    yield start
    for fake in made:
        fake.close()


def _drive(fake, spec, text="hello"):
    return companion.drive(fake.home, spec, text, "e2e-mark-run1-abc123", timeout_s=5)


# --- the choreography ----------------------------------------------------------

def test_a_completed_turn_is_recorded_event_by_event_with_its_reads(daemon):
    fake = daemon()
    evidence = _drive(fake, {"reads": ["history_after", "history_before", "search"]})

    assert evidence.ok, evidence.error
    assert evidence.target.types() == {"accepted", "row", "turn_started", "text_delta",
                                       "tool_event", "text_done"}
    assert evidence.target.reply() == "answer to e2e-mark-run1-abc123-msg"
    assert evidence.reads == {"history_after": True, "history_before": True, "search": True}
    # `/new` went first, so the attempt is its own conversation.
    assert [row["content"] for row in fake.rows[:3]] == [
        "/new", "Started a fresh session.", "hello (eval:e2e-mark-run1-abc123)"]


def test_a_running_turn_is_cancelled_by_its_client_message_id(daemon):
    evidence = _drive(daemon(), {"cancel": "running"}, text="LONG essay")

    assert evidence.ok, evidence.error
    assert evidence.target.types() == {"accepted", "row", "turn_started", "text_delta",
                                       "turn_error"}
    assert evidence.target.error_code() == "cancelled"


def test_a_waiting_cancel_names_the_turn_it_never_saw_start(daemon):
    spec = {"cancel": "waiting", "blocker": "BLOCK story"}
    evidence = _drive(daemon(), spec, text="quick question")

    assert evidence.ok, evidence.error
    # The cancelled message's own row was announced although it never ran.
    assert evidence.target.types() == {"accepted", "row", "turn_error"}
    assert evidence.target.error_code() == "cancelled"
    assert {"turn_started", "text_done"} <= evidence.blocker.types()


def test_a_stray_announcement_never_ends_a_watched_request(daemon):
    spec = {"cancel": "waiting", "blocker": "BLOCK story"}
    evidence = _drive(daemon(stray=True), spec, text="quick question")

    assert evidence.ok, evidence.error
    assert "text_done" not in evidence.target.types()
    assert evidence.target.error_code() == "cancelled"


def test_catch_up_reads_what_the_timeline_gained_with_no_client(daemon):
    fake = daemon(offline_row="fern-run1-1 there are 96 days left")
    evidence = _drive(fake, {"offline_wait_s": 1})

    evidence = companion.catch_up(fake.home, 1, evidence, timeout_s=5)

    assert evidence.ok, evidence.error
    assert evidence.offline_rows == ["fern-run1-1 there are 96 days left"]
    assert fake.connections == 2


def test_a_missing_socket_is_evidence_not_an_exception():
    home = tempfile.mkdtemp(prefix="cmp")
    try:
        evidence = companion.drive(home, {}, "hello", "e2e-mark-x", timeout_s=1)
    finally:
        shutil.rmtree(home, ignore_errors=True)
    assert not evidence.ok
    assert "cannot connect" in evidence.error


# --- the wire gates -----------------------------------------------------------

def _evidence(types, code=None, blocker=None, reads=None, rows=None):
    target = companion.TurnWire("m")
    target.events = [{"type": t, **({"code": code} if t == "turn_error" else {})}
                     for t in types]
    blocker_wire = None
    if blocker is not None:
        blocker_wire = companion.TurnWire("b")
        blocker_wire.events = [{"type": t} for t in blocker]
    return companion.Evidence(True, None, None, 0.0, target, blocker_wire, reads or {},
                              offline_rows=rows or [])


def test_wire_gates_pass_on_the_evidence_they_describe():
    evidence = _evidence(["accepted", "turn_error"], code="cancelled",
                         blocker=["turn_started", "text_done"],
                         reads={"search": True}, rows=["bread-run1-1 leaves"])
    wire = {"events_all": ["accepted", "turn_error"], "events_none": ["text_done"],
            "error_code": "cancelled", "blocker_events_all": ["text_done"],
            "reads_find_marker": True, "offline_row_matches": "(?i)BREAD-run1-1"}

    gates = companion.wire_gates(evidence, wire)

    assert [g.key for g in gates] == [f"wire.{key}" for key in wire]
    assert all(g.passed for g in gates), [g.detail for g in gates if not g.passed]


def test_wire_gates_fail_on_what_the_wire_did_not_say():
    evidence = _evidence(["accepted", "turn_started", "text_done"],
                         reads={"history_after": True, "search": False})
    wire = {"events_all": ["turn_error"], "events_none": ["text_done"],
            "error_code": "cancelled", "reads_find_marker": True,
            "offline_row_matches": "fern"}

    gates = {g.key: g for g in companion.wire_gates(evidence, wire)}

    assert not any(g.passed for g in gates.values())
    assert "missed=['search']" in gates["wire.reads_find_marker"].detail


# --- the suite keys -----------------------------------------------------------

def _load(tmp_path, cases):
    doc = {"suite": "spec_companion", "title": "Spec", "risk": "isolated_mutation",
           "scenarios": [{"id": "scn", "title": "Scenario", "cases": cases}]}
    with open(os.path.join(str(tmp_path), "spec.yaml"), "w", encoding="utf-8") as fh:
        yaml.safe_dump(doc, fh)
    return suites.load_all(str(tmp_path))


def _problems(tmp_path, cases):
    with pytest.raises(suites.SuiteError) as exc:
        _load(tmp_path, cases)
    return exc.value.problems


def _case(cid, **extra):
    return {"id": cid, "query": "hello", "drive": "companion",
            "expect": {"wire": {"events_all": ["text_done"]}}, **extra}


def test_a_companion_case_loads_unattended_with_its_spec(tmp_path):
    cases = [_case("a", companion={"reads": ["search"]},
                   expect={"status": "ok", "wire": {"reads_find_marker": True}}),
             _case("b")]

    case = _load(tmp_path, cases)[0].scenarios[0].cases[0]

    assert case.drive == "companion"
    assert not case.needs_operator
    assert case.companion == {"reads": ["search"]}
    assert case.expect["wire"] == {"reads_find_marker": True}


def test_companion_keys_are_refused_off_the_companion_drive(tmp_path):
    cases = [{"id": "a", "query": "hello", "companion": {"reads": ["search"]},
              "expect": {"wire": {"events_all": ["text_done"]}}}, _case("b")]

    problems = _problems(tmp_path, cases)

    assert any("`companion` needs `drive: companion`" in p for p in problems)
    assert any("expect `wire` needs `drive: companion`" in p for p in problems)


def test_a_companion_case_needs_its_wire_and_one_turn(tmp_path):
    cases = [{"id": "a", "drive": "companion", "turns": [{"query": "one"}, {"query": "two"}]},
             _case("b")]

    problems = _problems(tmp_path, cases)

    assert any("supports only single-turn" in p for p in problems)
    assert any("needs an expect `wire` map" in p for p in problems)


def test_a_cancelled_message_is_graded_on_the_wire_alone(tmp_path):
    cases = [_case("a", companion={"cancel": "running"}, rubric="Judge the reply.",
                   expect={"status": "ok", "wire": {"error_code": "cancelled"}}),
             _case("b")]

    problems = _problems(tmp_path, cases)

    assert any("graded on the wire alone; drop ['status']" in p for p in problems)
    assert any("no reply to judge" in p for p in problems)


@pytest.mark.parametrize("spec, fragment", [
    ({"cancel": "later"}, "`companion.cancel` must be one of"),
    ({"cancel": "waiting"}, "needs a `blocker` message"),
    ({"blocker": "x"}, "only goes with `cancel: waiting`"),
    ({"reads": ["history_sideways"]}, "`companion.reads` must be a list"),
    ({"offline_wait_s": 0}, "`companion.offline_wait_s` must be an integer"),
    ({"cancel": "running", "reads": ["search"]}, "go without `cancel`"),
    ({"surprise": 1}, "unknown `companion` key `surprise`"),
])
def test_a_malformed_companion_spec_is_named(tmp_path, spec, fragment):
    assert any(fragment in p for p in _problems(tmp_path, [_case("a", companion=spec),
                                                            _case("b")]))


@pytest.mark.parametrize("wire, fragment", [
    ({"events_all": ["text_finished"]}, "`wire.events_all` must be a non-empty list"),
    ({"reads_find_marker": True}, "needs `companion.reads`"),
    ({"offline_row_matches": "fern"}, "needs `companion.offline_wait_s`"),
    ({"offline_row_matches": "("}, "not a valid regex"),
    ({"blocker_events_all": ["text_done"]}, "needs `companion.cancel: waiting`"),
    ({"latency": 1}, "unknown `wire` key `latency`"),
])
def test_a_malformed_wire_map_is_named(tmp_path, wire, fragment):
    cases = [_case("a", expect={"wire": wire}), _case("b")]
    assert any(fragment in p for p in _problems(tmp_path, cases))


def test_the_shipped_companion_suite_loads():
    suites_dir = os.path.join(os.path.dirname(HERE), "suites")
    loaded = [s for s in suites.load_all(suites_dir) if s.name == "companion"]
    assert loaded and all(scn.risk == "isolated_mutation" for scn in loaded[0].scenarios)
    assert all(case.drive == "companion"
               for scn in loaded[0].scenarios for case in scn.cases)


# --- the runner ---------------------------------------------------------------

def test_the_runner_plans_companion_cases_without_an_operator(tmp_path):
    loaded = _load(tmp_path, [_case("a"), _case("b")])
    chosen = [(loaded[0], loaded[0].scenarios)]

    _scenarios, jobs, turns, _judge = run_eval.plan_counts(chosen, False, operator=False)

    assert (jobs, turns) == (2, 2)


def test_a_cancelled_case_is_graded_from_the_wire_without_opik(tmp_path, monkeypatch):
    loaded = _load(tmp_path, [
        _case("a", companion={"cancel": "running"},
              expect={"wire": {"events_all": ["turn_error"], "error_code": "cancelled"}}),
        _case("b")])
    suite, scenario = loaded[0], loaded[0].scenarios[0]
    evidence = _evidence(["accepted", "turn_started", "turn_error"], code="cancelled")
    monkeypatch.setattr(companion, "drive", lambda *args, **kwargs: evidence)
    cfg = SimpleNamespace(daemon=SimpleNamespace(fermix_home="/nowhere",
                                                 default_timeout_ms=1000))

    class NoOpik:
        def __getattr__(self, name):
            raise AssertionError(f"a cancelled case must not read Opik ({name})")

    result = run_eval.run_companion_case(cfg, NoOpik(), suite, scenario, scenario.cases[0],
                                         "run1", 1, judge_on=False)

    assert result["outcome"] == "pass"
    assert [g["key"] for g in result["turns"][0]["gates"]] == ["wire.events_all",
                                                              "wire.error_code"]


def test_an_unreachable_socket_is_incomplete_not_failed(tmp_path, monkeypatch):
    loaded = _load(tmp_path, [_case("a"), _case("b")])
    suite, scenario = loaded[0], loaded[0].scenarios[0]
    lost = companion.Evidence(False, "cannot connect to /x: refused", None, 0.0,
                              companion.TurnWire("m"))
    monkeypatch.setattr(companion, "drive", lambda *args, **kwargs: lost)
    cfg = SimpleNamespace(daemon=SimpleNamespace(fermix_home="/x", default_timeout_ms=1000))

    result = run_eval.run_companion_case(cfg, None, suite, scenario, scenario.cases[0],
                                         "run1", 1, judge_on=False)

    assert result["outcome"] == "incomplete"
    assert "cannot connect" in result["turns"][0]["drive_error"]


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
