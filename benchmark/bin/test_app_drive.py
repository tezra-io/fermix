#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8.4", "pyyaml>=6,<7"]
# ///
"""Specs for `drive: app` (M106 stage S6): the case's `app:` map, and the steps the
runner takes on the companion socket against a scripted stand-in daemon that offers a
heal's `job_change` card as the engine does (live when the heal is sent, again after
every hello while it waits, resolved to every connection when it ends). Pure: a local
Unix socket in a temp dir, no daemon, no model, no spend.
Run: `uv run bin/test_app_drive.py`."""
from __future__ import annotations

import json
import os
import shutil
import socket
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

from evallib import app_drive, companion  # noqa: E402

HEAL = "jhl_0a1b2c3d4e5f6071"
JOB = "Marrowfield library holds digest"


class FakeApp:
    """The daemon side of the app's chat for one heal. `seed()` sends the heal: its row
    and its card to the open connection. `/confirm <heal>` and `/deny <heal>` resolve it
    approved or denied; a message saying "move" is the owner's edit, which resolves it
    expired. With `answers=False` the daemon refuses every answer; with `offer=False` it
    sends the row and no card."""

    def __init__(self, answers: bool = True, offer: bool = True):
        self.home = tempfile.mkdtemp(prefix="app")
        self.path = companion.socket_path(self.home)
        self.answers, self.offer = answers, offer
        self.waiting = False
        self.sends: list = []
        self.commands: list[dict] = []
        self.messages: list[str] = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(4)
        threading.Thread(target=self._serve, daemon=True).start()

    def close(self):
        self.server.close()
        shutil.rmtree(self.home, ignore_errors=True)

    def card(self, ttl_s=604800):
        return {"type": "approval", "approval_id": "job_change-abc", "kind": "job_change",
                "text": f'Change job "{JOB}"?', "token": HEAL, "ttl_s": ttl_s,
                "approve_command": f"/confirm {HEAL}", "deny_command": f"/deny {HEAL}"}

    def seed(self):
        origin = {"kind": "job", "name": JOB}
        self.sends[-1]({"type": "row", "profile_id": "main", "server_seq": 2,
                        "role": "assistant", "text": "Job failed.", "ts": "2026-11-24T10:00:00Z",
                        "media_refs": [], "metadata": {"origin": origin}})
        if self.offer:
            self.waiting = True
            self.sends[-1](self.card())

    def _serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        buffer = b""

        def send(event):
            try:
                conn.sendall(json.dumps(event).encode() + b"\n")
            except OSError:
                pass

        self.sends.append(send)
        while True:
            try:
                chunk = conn.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                self._on(json.loads(line), send)

    def _on(self, event, send):
        kind = event["type"]
        if kind == "client_hello":
            send({"type": "server_hello", "min_version": 7, "max_version": 8,
                  "role": "primary", "commands": []})
        elif kind == "history_pull":
            if self.waiting:
                send(self.card(ttl_s=604790))
            send({"type": "history_page", "profile_id": "main", "messages": [],
                  "history_head_seq": 1, "next_after_seq": 0})
        elif kind == "command":
            self._command(event, send)
        elif kind == "msg":
            self._message(event, send)

    def _command(self, event, send):
        self.commands.append(event)
        answer = {"type": "row", "profile_id": "main", "server_seq": 3, "role": "assistant",
                  "text": "done", "ts": "2026-11-24T10:01:00Z", "media_refs": []}
        send(answer)
        if event["name"] in ("confirm", "deny") and event.get("args") == HEAL and \
                self.answers and self.waiting:
            self._resolve("approved" if event["name"] == "confirm" else "denied")

    def _message(self, event, send):
        self.messages.append(event["text"])
        cid = event["client_msg_id"]
        send({"type": "accepted", "client_msg_id": cid})
        send({"type": "turn_started", "turn_id": f"t-{cid}", "in_reply_to": cid})
        if "move" in event["text"] and self.waiting:
            self._resolve("expired")
        send({"type": "text_done", "turn_id": f"t-{cid}", "server_seq": 4, "text": "Moved it.",
              "ts": "2026-11-24T10:02:00Z"})

    def _resolve(self, outcome):
        self.waiting = False
        for send in self.sends:
            send({"type": "approval_resolved", "approval_id": "job_change-abc",
                  "outcome": outcome})


@pytest.fixture
def app():
    made = []

    def start(**kwargs):
        fake = FakeApp(**kwargs)
        made.append(fake)
        return fake

    yield start
    for fake in made:
        fake.close()


def _drive(fake, steps, cli=None):
    typed = []

    def type_cli(command):
        typed.append(command)
        return cli(command) if cli else "That card is not answered from here."

    evidence, broken = app_drive.drive(fake.home, {"steps": steps}, _markers(), fake.seed,
                                       type_cli, timeout_s=5)
    return evidence, broken, typed


def _markers():
    """Opaque markers, one per call, as the runner's `session_ids.eval_marker` makes."""
    made = iter(f"e2e-mark-RUN-{n:06x}" for n in range(1, 100))
    return lambda: next(made)


def _of(events, kind):
    return [e for e in events if e.get("type") == kind]


def test_an_approve_sends_the_cards_own_route_and_reads_its_resolution(app):
    fake = app()
    ev, broken, _typed = _drive(fake, ["await_card", {"answer": "approve"}])
    assert broken is None
    assert ev["card"]["token"] == HEAL
    # `/new`, then the route as the app sends it: no slash, the rest the args.
    assert [(c["name"], c.get("args")) for c in fake.commands] == [("new", None),
                                                                     ("confirm", HEAL)]
    [conn] = ev["connections"]
    assert [e["type"] for e in conn["events"] if e["type"] != "row"] == ["approval",
                                                                          "approval_resolved"]
    assert ev["steps"][-1] == {"step": "answer", "answer": "approve", "resolved": "approved"}
    assert ev["replies"] == [{"command": f"/confirm {HEAL}", "session": "app", "reply": "done"}]


def test_a_reconnect_keeps_what_its_hello_offered_apart_from_what_came_live(app):
    fake = app()
    ev, broken, _typed = _drive(fake, ["await_card", "reconnect", {"answer": "deny"},
                                       "reconnect"])
    assert broken is None
    first, second, third = ev["connections"]
    assert _of(first["events"], "approval") and not first["hello"]
    assert _of(second["hello"], "approval") and not _of(second["events"], "approval")
    assert _of(second["events"], "approval_resolved")[0]["outcome"] == "denied"
    assert third["hello"] == [] and third["events"] == []


def test_a_terminal_answer_names_the_offered_card(app):
    fake = app(answers=False)
    ev, broken, typed = _drive(fake, ["await_card", {"type_cli": "/confirm {card}"},
                                      "reconnect"])
    assert broken is None and typed == [f"/confirm {HEAL}"]
    assert ev["replies"][0]["session"] == "cli"
    assert _of(ev["connections"][1]["hello"], "approval")


def test_a_say_step_is_a_message_whose_turn_end_and_resolution_are_read(app):
    fake = app()
    ev, broken, _typed = _drive(fake, ["await_card", {"say": "please move it to 6:45"}])
    assert broken is None
    step = ev["steps"][-1]
    assert {key: step[key] for key in ("step", "timed_out", "resolved")} == {
        "step": "say", "timed_out": False, "resolved": "expired"}
    assert ev["replies"][-1]["reply"] == "Moved it."


def test_a_say_step_carries_the_marker_its_trace_is_found_by(app):
    # The say is the trial's one model turn; the runner finds its trace on the app's
    # thread by this marker, as the companion lane finds its own, so the run knows which
    # model served it.
    fake = app()
    ev, broken, _typed = _drive(fake, ["await_card", {"say": "please move it to 6:45"}])
    assert broken is None
    [say] = [s for s in ev["steps"] if s["step"] == "say"]
    # Opaque, as the companion lane's: a fresh marker that names the run and nothing of
    # the suite or the case, which the model reads.
    assert say["marker"] == "e2e-mark-RUN-000002"
    assert fake.messages == [f"please move it to 6:45 (eval:{say['marker']})"]
    assert say["sent_at"].endswith("Z") and say["elapsed_ms"] >= 0
    assert ev["replies"][-1]["say"] == "please move it to 6:45"


def test_a_wait_that_runs_out_is_recorded_and_stops_the_steps(app):
    fake = app(offer=False)
    ev, broken, _typed = _drive(fake, ["await_card", {"answer": "approve"}])
    assert broken is None
    assert ev["steps"][-1] == {"step": "await_card", "timed_out": True}
    assert [c["name"] for c in fake.commands] == ["new"]
    ev, broken, _typed = _drive(app(offer=False), ["await_row"])
    assert ev["steps"][-1] == {"step": "await_row", "timed_out": False}


def test_a_missing_socket_makes_the_attempt_ungradable():
    home = tempfile.mkdtemp(prefix="app")
    try:
        ev, broken = app_drive.drive(home, {"steps": ["await_row"]}, _markers(), lambda: None,
                                     lambda c: "", timeout_s=1)
    finally:
        shutil.rmtree(home, ignore_errors=True)
    assert broken and "cannot connect" in broken and ev["connections"] == []


@pytest.mark.parametrize("spec, fragment", [
    ({"steps": []}, "1..8 steps"),
    ({"steps": ["await_card"], "extra": 1}, "one key, `steps`"),
    ({"steps": ["wait"]}, "a bare step is one of"),
    ({"steps": [{"answer": "maybe"}]}, "is one of ['approve', 'deny']"),
    ({"steps": [{"answer": "approve"}]}, "need an `await_card` step before"),
    ({"steps": ["await_card", {"type_cli": "confirm it"}]}, "starting with '/'"),
    ({"steps": [{"say": ""}]}, "takes a non-empty string"),
    ({"steps": [{"poke": 1}]}, "unknown step"),
])
def test_a_malformed_app_spec_is_named(spec, fragment):
    problems = app_drive.spec_problems(spec, "s/c")
    assert any(fragment in p for p in problems), problems


def test_only_say_steps_are_model_turns():
    spec = {"steps": ["await_card", {"say": "move it"}, "reconnect", {"say": "thanks"}]}
    assert app_drive.spec_problems(spec, "s/c") == []
    assert app_drive.says(spec) == ["move it", "thanks"]


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
