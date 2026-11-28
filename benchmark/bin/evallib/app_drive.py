"""Drive a capability trial through the Fermix app's chat (`drive: app`, M106 stage S6).

The owner's inbox in an eval home seeded with `--owner-inbox-app` is the app's chat:
the companion socket's conversation `main` (evallib/owner_inbox.py). What reaches the
owner there arrives on the socket with no turn: a message is a `row`, and a heal's
proposal is an `approval` card of kind `job_change` whose routes the app sends back as
a `command` (companion PROTOCOL.md, Approvals). A trial is driven the way the Mac app
lives with it:

1. connect, `client_hello`, and read to a barrier (a `history_pull` sent after the
   hello is answered after every card the daemon offers again on that hello), then
   `/new`, so the trial's conversation is its own;
2. the runner seeds the trial's state (`checker.state`), whose heal the daemon claims
   on its next pass and sends, with no model;
3. the case's `app.steps`, in order:

   - `await_card`: wait for an `approval` of kind `job_change`, the card the trial
     answers; `await_row`: wait for an assistant `row` whose `metadata.origin` is a job;
   - `answer: approve | deny`: send that card's route as the app does (`/confirm X` is
     `command{name: "confirm", args: "X"}`), wait for the command's answer and then,
     up to `SETTLE_S`, for the card's `approval_resolved`;
   - `reconnect`: close, connect again and read to the barrier: what the hello
     offered again;
   - `type_cli: "<command>"`: type a command in the owner's terminal chat (`fermix
     ask`), `{card}` standing for the card's token, as an answer from somewhere else;
   - `say: "<text>"`: one message of the owner's in the app (a model turn), sent with
     the marker its trace is found by appended, `(eval:<marker>)`, as the companion
     lane sends its own, waited to its end and then, up to `SETTLE_S`, for the card's
     `approval_resolved`. The step records the marker, when the message was sent and
     how long its turn took, so the runner can read that turn's trace (the model that
     served it, its usage) on the app's thread (`TRACE_THREAD_PREFIX`).

Every event every connection receives is kept, in order, split at its barrier, and
goes to the checker as evidence (`app`). A wait that runs out is recorded, not raised:
the steps after it are not run, and the checker decides from the store whether the
daemon never sent the heal (invalid) or sent it somewhere else (a 0). Only a socket
that refuses or closes makes the attempt ungradable (`companion.CompanionError`).
"""

from __future__ import annotations

import time
import uuid
from datetime import datetime, timezone

from . import companion

STEPS = ("await_card", "await_row", "answer", "reconnect", "type_cli", "say")
ANSWERS = ("approve", "deny")
CARD_KIND = "job_change"
MAX_STEPS = 8
# How long after an answer's own reply, or a turn's end, the card's resolution is
# waited for: the daemon announces it in the same pass that wrote the answer.
SETTLE_S = 10.0
# The app's chat exports its turns to Opik under the companion channel's thread
# (`companion:main`), where a `say` turn's trace is found by its marker.
TRACE_THREAD_PREFIX = "companion:"


def spec_problems(spec, where: str) -> list[str]:
    """What is wrong with a case's `app:` map."""
    if not isinstance(spec, dict) or set(spec) != {"steps"}:
        return [f"{where}: `app` must be a map with one key, `steps`"]
    steps = spec["steps"]
    if not isinstance(steps, list) or not 1 <= len(steps) <= MAX_STEPS:
        return [f"{where}: `app.steps` must be a list of 1..{MAX_STEPS} steps"]
    problems = []
    for n, step in enumerate(steps):
        problems += _step_problems(step, f"{where}: `app.steps[{n}]`")
    names = [_name(step) for step in steps]
    needs_card = [name for name in names if name in ("answer", "type_cli")]
    if needs_card and "await_card" not in names[:names.index(needs_card[0])]:
        problems.append(f"{where}: `answer` and `type_cli` need an `await_card` step before "
                        "them (the card they answer)")
    return problems


def _step_problems(step, where: str) -> list[str]:
    if isinstance(step, str):
        return [] if step in ("await_card", "await_row", "reconnect") else [
            f"{where}: a bare step is one of await_card, await_row, reconnect, got {step!r}"]
    if not isinstance(step, dict) or len(step) != 1:
        return [f"{where}: a step is a name or a one-key map, got {step!r}"]
    (name, value), = step.items()
    if name == "answer":
        return [] if value in ANSWERS else [f"{where}: `answer` is one of {list(ANSWERS)}"]
    if name in ("type_cli", "say"):
        ok = isinstance(value, str) and value.strip()
        if ok and name == "type_cli" and not value.startswith("/"):
            return [f"{where}: `type_cli` is one command, starting with '/'"]
        return [] if ok else [f"{where}: `{name}` takes a non-empty string"]
    return [f"{where}: unknown step {name!r}; one of {list(STEPS)}"]


def _name(step) -> str:
    return step if isinstance(step, str) else next(iter(step))


def says(spec: dict) -> list[str]:
    """The owner's messages a trial sends (model turns), for the cost estimate."""
    return [step["say"] for step in spec.get("steps", [])
            if isinstance(step, dict) and "say" in step]


class _Recorder(companion._Session):
    """A session that keeps every event it reads, in order, before routing it."""

    def __init__(self, conn: companion.Connection, events: list):
        super().__init__(conn)
        self.events = events

    def _route(self, event: dict) -> None:
        self.events.append(event)
        super()._route(event)


class _Trial:
    """One attempt: its connections, in order, each with what its hello offered again
    (`hello`) and every event after that (`events`). `new_marker()` gives a fresh opaque
    marker (`session_ids.eval_marker`): one for the attempt's command ids, one per `say`."""

    def __init__(self, home: str, new_marker, deadline: float):
        self.home, self.new_marker, self.deadline = home, new_marker, deadline
        self.marker = new_marker()
        self.connections: list[dict] = []
        self.session: _Recorder | None = None
        self.card: dict | None = None
        self.replies: list[dict] = []
        self.steps: list[dict] = []

    def connect(self) -> None:
        conn = companion.Connection(companion.socket_path(self.home),
                                    max(self.deadline - time.monotonic(), 1.0))
        hello: list = []
        self.session = _Recorder(conn, hello)
        conn.hello(self.deadline)
        self.session.request({"type": "history_pull", "profile_id": companion.PROFILE,
                              "after_seq": 0, "limit": 1}, "history_page", self.deadline)
        record = {"hello": hello, "events": []}
        self.session.events = record["events"]
        self.connections.append(record)

    def close(self) -> None:
        if self.session is not None:
            self.session.conn.close()
            self.session = None

    def command(self, name: str, args: str | None = None) -> companion.TurnWire:
        turn = self.session.command(f"{self.marker}-{uuid.uuid4().hex[:8]}", name, args)
        if not self.session.pump(turn.ended, self.deadline):
            raise companion.CompanionError(f"/{name} was not answered")
        return turn

    def wait(self, found) -> dict | None:
        """The first event of this connection `found` accepts, read up to the deadline."""
        events = self.session.events

        def hit():
            return next((e for e in events if found(e)), None)

        self.session.pump(lambda: hit() is not None, self.deadline)
        return hit()

    def settle(self) -> dict | None:
        """The card's resolution on this connection, read up to `SETTLE_S`."""
        if self.card is None:
            return None
        card_id = self.card.get("approval_id")
        deadline = min(self.deadline, time.monotonic() + SETTLE_S)
        events = self.session.events
        def resolved():
            return next((e for e in events if e.get("type") == "approval_resolved"
                         and e.get("approval_id") == card_id), None)

        self.session.pump(lambda: resolved() is not None, deadline)
        return resolved()

    def evidence(self) -> dict:
        return {"marker": self.marker, "connections": self.connections, "card": self.card,
                "steps": self.steps, "replies": self.replies}


def _is_card(event: dict) -> bool:
    return event.get("type") == "approval" and event.get("kind") == CARD_KIND


def _is_job_row(event: dict) -> bool:
    origin = (event.get("metadata") or {}).get("origin") or {}
    return (event.get("type") == "row" and event.get("role") == "assistant"
            and origin.get("kind") == "job")


def _route_command(route: str) -> tuple[str, str]:
    """An approval's route as the app sends it: no leading '/', the first word the
    name, the rest the args."""
    name, _sep, args = route.lstrip("/").partition(" ")
    return name, args


def _run_step(trial: _Trial, step, cli) -> bool:
    """One step; False when its wait ran out (the steps after it are not run)."""
    name = _name(step)
    if name == "await_card":
        trial.card = trial.wait(_is_card)
        trial.steps.append({"step": name, "timed_out": trial.card is None})
        return trial.card is not None
    if name == "await_row":
        row = trial.wait(_is_job_row)
        trial.steps.append({"step": name, "timed_out": row is None})
        return row is not None
    if name == "reconnect":
        trial.close()
        trial.connect()
        trial.steps.append({"step": name})
        return True
    if name == "answer":
        route = trial.card.get("approve_command" if step["answer"] == "approve"
                               else "deny_command")
        if not isinstance(route, str) or not route.startswith("/"):
            trial.steps.append({"step": name, "answer": step["answer"], "no_route": True})
            return False
        turn = trial.command(*_route_command(route))
        resolved = trial.settle()
        trial.replies.append({"command": route, "session": "app", "reply": _answer(turn)})
        trial.steps.append({"step": name, "answer": step["answer"],
                            "resolved": (resolved or {}).get("outcome")})
        return True
    if name == "type_cli":
        command = step["type_cli"].replace("{card}", str(trial.card.get("token", "")))
        trial.replies.append({"command": command, "session": "cli", "reply": cli(command)})
        trial.steps.append({"step": name, "command": command})
        return True
    marker = trial.new_marker()
    sent_at = datetime.now(timezone.utc)
    started = time.monotonic()
    target = trial.session.message(marker, f"{step['say']} (eval:{marker})")
    ended = trial.session.pump(target.ended, trial.deadline)
    elapsed_ms = (time.monotonic() - started) * 1000.0
    resolved = trial.settle() if ended else None
    trial.replies.append({"say": step["say"], "session": "app", "reply": target.reply()})
    trial.steps.append({"step": "say", "timed_out": not ended,
                        "resolved": (resolved or {}).get("outcome"), "marker": marker,
                        "sent_at": sent_at.strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
                        "elapsed_ms": elapsed_ms})
    return ended


def _answer(turn: companion.TurnWire) -> str:
    """A command's answer: the assistant row the daemon wrote for it."""
    return "\n".join(e.get("text", "") for e in turn.events
                     if e.get("type") == "row" and e.get("role") == "assistant")


def drive(home: str, spec: dict, new_marker, seed, cli,
          timeout_s: float) -> tuple[dict, str | None]:
    """One attempt: connect and start a fresh conversation, `seed()` the trial's state,
    then run the steps. `new_marker()` returns a fresh opaque eval marker
    (`session_ids.eval_marker`). `cli(command)` types a command in the owner's terminal
    chat and returns its reply. Returns the evidence and, when the socket refused or closed, why
    the attempt cannot be graded (None otherwise). The connection is closed on return."""
    trial = _Trial(home, new_marker, time.monotonic() + timeout_s)
    try:
        trial.connect()
        trial.command("new")
        seed()
        trial.steps.append({"step": "seed"})
        for step in spec["steps"]:
            if not _run_step(trial, step, cli):
                break
    except companion.CompanionError as exc:
        return trial.evidence(), str(exc)
    finally:
        trial.close()
    return trial.evidence(), None
