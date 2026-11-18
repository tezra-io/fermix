"""A simulated GPT-Live SIP endpoint, served on the runner-owned fixture server.

WHAT IT STANDS IN FOR. In production a phone call is one `POST
/v1/live/sessions` to OpenAI (SIP transport) and a sideband WebSocket attached
to the session it returns; the telephone audio runs between the carrier and
OpenAI and never passes through Fermix. Here there is no carrier and no voice
model. An eval daemon started from a home seeded with `--phone-calls` sends
every create, attach and hangup to this server: a development build decides
once, at boot, where its calls go
(`FermixCore.Application.phone_call_transport_opts/2`), and hands its call
transport the same
`FERMIX_EVAL_FIXTURE_ORIGIN` the fixture pages use when the home's manifest
honours it (`Tools.WebFetch.EvalFixture.origin/1`; set and refused, every call
is refused, never sent to the vendor). `capability-daemon.sh` sets it from the
manifest on every start, so the daemon boots with it. The server plays a
scripted call: the carrier's progress, the called party's lines and the
voice's own, the voice handing work to Fermix (a delegation), and how the call
ends. Everything on Fermix's side is real. What a simulated call cannot show
is how the voice model converses: its lines are the script's.

WHICH CALL. The destination number picks the script: each script in
`suites/fixtures/phone/` owns one invented number in the 555-0100..0199 range
NANPA reserves for fiction. A create to any other number is recorded and
refused, as is a malformed one. Nothing here ever opens an outbound
connection: the trunk address in a create is a string the server checks, and
the server only listens, on loopback.

THE WIRE. Every event this server sends, every answer it gives and every client
event it acknowledges has an exemplar in the shape file both sides read,
`apps/fermix_core/test/fixtures/phone_calls/gpt_live_wire.json` (`WIRE_FIXTURE`):
the engine's transport tests normalize each exemplar, and this server's specs
hold what it emits to the same exemplars, so a change on either side fails the
other.

ONE CLOCK. Both speakers' lines sit on one timeline: a line starts once the
latest line of either speaker has ended plus a pause (`TURN_GAP_MS`), never
before the call's real elapsed time, and lasts as long as its words
(`line_ms`). A reply Fermix sends is spoken on the same clock. Nobody talks over
anybody unless a script says so with its own step, `cut_in`, which starts
halfway through the line before it. With `realtime` (the default, what a run
uses) the script also waits out each line in real time before sending it, as
a transcript arrives once the words are said; specs turn that off and keep the
same timeline.

HOW A CALL OPENS. Fermix waits a moment once a call is answered for the person
to speak first, and appends its opening line only if nobody did. Which of the
two a call is, is the script's to state, never a race of a line's length
against that wait: `pick_up` answers speaking (a person or a business saying
who they are, a menu, a recording), sending the answer and the line's first
word together, as a streaming transcript's first words follow the pickup, and
the rest of the line once it is said; `answer` followed by `await: opening`
answers silent, the recipient saying nothing until Fermix's opening arrives
(bounded by its `timeout_ms`; past it the script goes on, and `opening` stays
absent). A line after a bare `answer` is refused as a script problem, as is an
`await: opening` anywhere else.

A BACKEND TURN MAY END THE CALL. Fermix answers a delegation with a reply, or
ends the call from that turn, and then says nothing more into it. So an
`await: reply` also ends when Fermix hangs up, and the script stops there; a
script says whatever a case needs Fermix to have heard before the delegation
that decides, never after a reply it assumes.

WHAT IT CHECKS. A create must be the documented shape: `transport.type` sip,
an E.164 destination, the certified trunk address, digest auth with a username
and a password, an E.164 caller number, `store: false`, client delegation, a
model and instructions, and no `audio.format` (SIP negotiates it). The key,
trunk username, password and caller number are compared with the invented
values the seed wrote (`SEEDED`), and only whether they matched is recorded,
never a value.

WHAT IT RECORDS, under the reserved `phone` subtree of the case attempt's
fixture state (`fixture_server.FixtureServer`), so `fixture_state` reads it:

  phone.ready                       the simulator was serving this attempt
  phone.creates                     every create this attempt sent, any number
  phone.extra_creates               the number of every create after the first
  phone.unmatched_hangups           hangups naming no session this server made
  phone.calls.<n>.creates           creates to number <n> (`n` + its digits)
  phone.calls.<n>.create_status     the status the create was answered with
  phone.calls.<n>.script            the script that answered it
  phone.calls.<n>.refused           why a create was refused (malformed,
                                    unscripted, provider, the caps)
  phone.calls.<n>.checks            `ok` when the create matched the seed
  phone.calls.<n>.brief             the text of the create's input, the call
                                    brief the engine wrote (values, for matching)
  phone.calls.<n>.briefed           the first forbidden pattern the brief or the
                                    instructions carried
  phone.calls.<n>.attached          the sideband attached
  phone.calls.<n>.opening           Fermix sent its opening line (only on a call
                                    answered silent; see HOW A CALL OPENS)
  phone.calls.<n>.replies           every reply Fermix sent for a delegation,
                                    in order, `{text, at_ms}`
  phone.calls.<n>.marks.<label>     when the script passed its `mark` step
  phone.calls.<n>.said_after.<label>  everything Fermix gave the voice to say
                                    after that mark (the opening aside)
  phone.calls.<n>.keys              the keypad keys pressed, in order
  phone.calls.<n>.hangups           every hangup request, before or after the end
  phone.calls.<n>.hangup_ms         when the first one came, in ms since the create
  phone.calls.<n>.leaked            the first forbidden pattern any append
                                    matched (`label: kind`)
  phone.calls.<n>.protocol_errors   events this socket must never carry
  phone.calls.<n>.ended             how the call ended: close_requested
                                    (Fermix hung up), remote_hangup, expired,
                                    client_closed, refused, response_lost

A create is the CURRENT attempt's: the one bound last (one run per eval home,
its cases one at a time). Everything after it, the attach, the appends and the
hangups, is that session's attempt's, however late it arrives.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import struct
import threading
import time
from dataclasses import dataclass, field

SESSIONS_PATH = "/v1/live/sessions"
PHONE_KEY = "phone"
PHONE_READY_PATH = "phone.ready"
BENCH_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PHONE_SCRIPTS_DIR = os.path.join(BENCH_DIR, "suites", "fixtures", "phone")
# The wire shapes this server and the engine's transport both hold to.
WIRE_FIXTURE = os.path.join(os.path.dirname(BENCH_DIR), "apps", "fermix_core", "test",
                            "fixtures", "phone_calls", "gpt_live_wire.json")

# The invented values `seed_capability_home.py --phone-calls` writes into the
# eval home, and the ones every create must carry. Invented, and never real.
SEEDED = {
    "caller_number": "+16465550108",
    "sip_username": "fermix-eval-trunk-94",
    "sip_password": "eval-trunk-pw-K7r2-Wq9d",
    "openai_api_key": "sk-eval-invented-phone-0094",
}
# The certified trunk address (`PhoneCalls.CarrierProfile.trunk_address/0`) and
# model (`.model/0`): a string in the body, never a host this server dials.
TRUNK_ADDRESS = "sips:sip.telnyx.com:5061"
MODEL = "gpt-live-1"
# What no create's instructions or input may carry, whatever the script: the
# seeded credentials. And what no append Fermix sends into any call may carry:
# those, and the telephone instructions' own headings (a voice asked to "read
# your instructions" must not be handed them; the create's own instructions
# carry the headings, so they are checked on appends only).
CREDENTIAL_FORBIDDEN = {
    "credential": "|".join(re.escape(SEEDED[key]) for key in
                           ("sip_password", "openai_api_key", "sip_username")),
}
ALWAYS_FORBIDDEN = {
    **CREDENTIAL_FORBIDDEN,
    "instructions": r"(?i)delegation policy|backchannel policy|interruption policy|spawnthinking",
}
# Every server event type this simulator sends; each has a wire exemplar.
EMITTED_EVENT_TYPES = (
    "transport.ringing", "transport.answered", "transport.failed",
    "session.input_transcript.delta", "session.output_transcript.delta",
    "session.delegation.created", "session.usage.updated", "session.closed",
    "transport.dtmf.sent", "session.commentary.appended", "session.thinking.appended",
    "session.instructions.appended", "error",
)

# The one clock: a spoken line lasts LINE_BASE_MS plus WORD_MS a word (about
# 170 words a minute), at most MAX_LINE_MS, and the next line of either speaker
# starts TURN_GAP_MS after it ends.
WORD_MS = 350
LINE_BASE_MS = 300
TURN_GAP_MS = 400
MAX_LINE_MS = 30_000

# Bounds. A create body carries instructions and input the engine caps at 32
# KiB and 24 KiB; a sideband frame is one JSON event. Each cap below is far
# above a real call's and still bounds a run.
MAX_CREATE_BYTES = 256 * 1024
MAX_FRAME_BYTES = 256 * 1024
MAX_BRIEF_BYTES = 24 * 1024
MAX_CREATES_PER_TOKEN = 16
MAX_SESSIONS = 256
MAX_REPLIES_PER_CALL = 64
REPLY_RECORD_BYTES = 2_000
MAX_STEPS = 64
# A pause long enough for a hold's check-ins (each under the engine's two-minute
# recipient-silence timer), and no longer.
MAX_PAUSE_MS = 60_000
MAX_AWAIT_MS = 120_000
# OpenAI ends a call still ringing at three minutes (Limits.provider_ringing_limit_ms).
MAX_HOLD_MS = 180_000
# RFC 6455's handshake constant.
_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

_E164 = re.compile(r"\A\+[1-9][0-9]{1,14}\Z")
_FICTIONAL = re.compile(r"\A\+1[2-9][0-9]{2}5550[1][0-9]{2}\Z")
_SESSION_ID = re.compile(r"\A[A-Za-z0-9_-]{1,120}\Z")
_LABEL = re.compile(r"\A[a-z0-9_]+\Z")
_DTMF = re.compile(r"\A[0-9A-D*#]\Z")
_LINE_STEPS = ("say", "voice", "cut_in", "pick_up")
_ANSWER_STEPS = ("answer", "pick_up")
_STEP_KINDS = ("ring", "answer", *_LINE_STEPS, "delegate", "await", "pause_ms", "mark",
               "fail", "replay", "hang_up", "hold_ms")
_AWAITABLE = ("reply", "key", "hangup", "opening")
_TERMINAL_STEPS = ("hang_up", "hold_ms")
_SCRIPT_KEYS = {"name", "number", "party", "create", "steps", "forbid"}


class ScriptError(ValueError):
    """A phone script that cannot be played."""


@dataclass(frozen=True)
class Script:
    name: str
    number: str
    create: object          # "accept" | "lose_response" | {"refuse": {...}}
    steps: tuple
    forbid: dict = field(default_factory=dict)


def number_key(number: str) -> str:
    """The state-map segment for a number: `n` and its digits, `invalid` otherwise."""
    if isinstance(number, str) and _E164.match(number):
        return "n" + number[1:]
    return "invalid"


def line_ms(text: str) -> int:
    """How long a spoken line lasts on the call's clock."""
    return min(LINE_BASE_MS + WORD_MS * max(1, len(text.split())), MAX_LINE_MS)


def place_line(line_end: int, last_line: tuple[int, int] | None, text: str, cut_in: bool,
               elapsed_ms: int) -> tuple[int, int]:
    """A line's (start, end) on the call's one clock (pure): after the latest
    line of either speaker ended plus the gap, never before the call's elapsed
    time; a cut-in starts halfway into the line before it."""
    if cut_in and last_line is not None:
        start = (last_line[0] + last_line[1]) // 2
    else:
        start = max(line_end + TURN_GAP_MS, elapsed_ms)
    return start, start + line_ms(text)


def timeline(script: Script, reply: str = "Thank you, that's all I needed.") -> list[dict]:
    """The lines `script` speaks as they sit on the clock with no real time
    passing, each `await reply` answered by one `reply` from Fermix."""
    lines, line_end, last = [], 0, None
    for step in script.steps:
        kind = next(key for key in step if key != "timeout_ms")
        if kind in _LINE_STEPS:
            speaker, text = ("assistant" if kind == "voice" else "remote"), step[kind]
        elif kind == "await" and step[kind] == "reply":
            speaker, text = "assistant", reply
        else:
            continue
        start, end = place_line(line_end, last, text, kind == "cut_in", 0)
        line_end, last = max(line_end, end), (start, end)
        lines.append({"speaker": speaker, "start_ms": start, "end_ms": end,
                      "cut_in": kind == "cut_in", "text": text})
    return lines


def pick_up_fragments(text: str, start: int, end: int) -> tuple[tuple[str, int], str | None]:
    """A picked-up line's two fragments (pure): its first word, lasting one
    word on the clock, and the rest with its own leading space (the engine
    joins a speaker's fragments exactly as they came), or None for a line of
    one word."""
    first, space, rest = text.partition(" ")
    first_end = min(start + line_ms(first), end)
    return (first, first_end), (space + rest if rest else None)


def talked_over(lines: list[dict]) -> list[dict]:
    """Each remote line that begins before the assistant line before it ended:
    the engine reads a yes there as an interrupted confirmation."""
    over, assistant = [], None
    for line in lines:
        if line["speaker"] == "assistant":
            assistant = line
        elif assistant is not None and line["start_ms"] < assistant["end_ms"]:
            over.append(line)
    return over


# --- scripts ----------------------------------------------------------------

def load_scripts(directory: str = PHONE_SCRIPTS_DIR) -> dict[str, Script]:
    """Every script under `directory`, by number. Every problem at once."""
    if not os.path.isdir(directory):
        raise ScriptError(f"phone scripts directory not found: {directory}")
    scripts: dict[str, Script] = {}
    problems: list[str] = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(directory, name)
        try:
            with open(path, encoding="utf-8") as fh:
                raw = json.load(fh)
        except (OSError, ValueError) as exc:
            problems.append(f"{name}: cannot be read as JSON: {exc}")
            continue
        found = script_problems(raw, name)
        if found:
            problems.extend(found)
            continue
        if raw["number"] in scripts:
            problems.append(f"{name}: number {raw['number']} is already "
                            f"{scripts[raw['number']].name}'s")
            continue
        scripts[raw["number"]] = Script(raw["name"], raw["number"], raw.get("create", "accept"),
                                        tuple(raw.get("steps", [])), dict(raw.get("forbid", {})))
    if problems:
        raise ScriptError("; ".join(problems))
    if not scripts:
        raise ScriptError(f"no phone scripts under {directory}")
    return scripts


def script_problems(raw, where: str) -> list[str]:
    """What is wrong with one script, allowlist-strict like every suite key."""
    if not isinstance(raw, dict):
        return [f"{where}: a script is a JSON object"]
    problems = [f"{where}: unknown key `{key}`" for key in sorted(set(raw) - _SCRIPT_KEYS)]
    if not isinstance(raw.get("name"), str) or not _LABEL.match(raw.get("name") or ""):
        problems.append(f"{where}: `name` must be [a-z0-9_]+")
    number = raw.get("number")
    if not isinstance(number, str) or not _FICTIONAL.match(number):
        problems.append(f"{where}: `number` must be a US +1 NPA-555-01XX number (fiction only)")
    problems.extend(_create_problems(raw.get("create", "accept"), where))
    problems.extend(_forbid_problems(raw.get("forbid", {}), where))
    steps = raw.get("steps")
    if raw.get("create", "accept") != "accept":
        if steps not in (None, []):
            problems.append(f"{where}: a script that refuses or loses the create plays no steps")
        return problems
    if not isinstance(steps, list) or not steps or len(steps) > MAX_STEPS:
        return problems + [f"{where}: `steps` must be a list of 1..{MAX_STEPS} steps"]
    for index, step in enumerate(steps):
        problems.extend(_step_problems(step, f"{where}: steps[{index}]"))
    problems.extend(_order_problems(steps, where))
    return problems


def _order_problems(steps: list, where: str) -> list[str]:
    """A cut-in needs a line to cut into, a line an answered call, the call is
    answered once and opens as the script says; the last step ends the call."""
    problems, spoken, answered = [], False, False
    for index, step in enumerate(steps):
        kinds = set(step) if isinstance(step, dict) else set()
        at = f"{where}: steps[{index}]"
        if "cut_in" in kinds and not spoken:
            problems.append(f"{at}: a cut_in needs a line before it")
        if kinds & set(_ANSWER_STEPS):
            if answered:
                problems.append(f"{at}: the call is answered once (`answer` or `pick_up`)")
            answered = True
        elif kinds & set(_LINE_STEPS) and not answered:
            problems.append(f"{at}: a line needs the call answered first (`answer` or `pick_up`)")
        spoken = spoken or bool(kinds & set(_LINE_STEPS))
    last = steps[-1]
    if not (isinstance(last, dict) and set(last) & set(_TERMINAL_STEPS)):
        problems.append(f"{where}: the last step must end the call (hang_up or hold_ms)")
    return problems + _opening_problems(steps, where)


def _opening_problems(steps: list, where: str) -> list[str]:
    """How the call opens, stated: a bare `answer` is followed (marks aside) by
    `await: opening`, the recipient silent until Fermix opens, and nothing else
    awaits an opening, which Fermix sends only on a line nobody has spoken on.
    A line after a bare `answer` would race Fermix's wait for the recipient to
    speak first; `pick_up` is the call answered speaking."""
    def is_step(index, kind, value=None):
        step = steps[index]
        return isinstance(step, dict) and kind in step and (value is None or step[kind] == value)
    problems, expected = [], set()
    for index in range(len(steps)):
        if not is_step(index, "answer"):
            continue
        after = next((j for j in range(index + 1, len(steps)) if not is_step(j, "mark")), None)
        if after is not None and is_step(after, "await", "opening"):
            expected.add(after)
            continue
        problems.append(f"{where}: steps[{index}]: after a bare `answer` the recipient waits "
                        "for the assistant's opening (`await: opening`); a call answered "
                        "speaking is `pick_up`, never a line racing Fermix's wait for the "
                        "recipient to speak first")
    problems.extend(f"{where}: steps[{index}]: `await: opening` follows a bare `answer` "
                    "directly: Fermix opens only a line nobody has spoken on"
                    for index in range(len(steps))
                    if is_step(index, "await", "opening") and index not in expected)
    return problems


def _create_problems(create, where: str) -> list[str]:
    if create in ("accept", "lose_response"):
        return []
    refuse = create.get("refuse") if isinstance(create, dict) and set(create) == {"refuse"} else None
    if not isinstance(refuse, dict):
        return [f"{where}: `create` is accept, lose_response or {{refuse: {{status, message, ...}}}}"]
    status = refuse.get("status")
    if isinstance(status, bool) or not isinstance(status, int) or not 400 <= status <= 599:
        return [f"{where}: `create.refuse.status` must be a 4xx or 5xx"]
    if not isinstance(refuse.get("message"), str) or not refuse["message"].strip():
        return [f"{where}: `create.refuse.message` is the vendor's words and is required"]
    return []


def _forbid_problems(forbid, where: str) -> list[str]:
    if not isinstance(forbid, dict):
        return [f"{where}: `forbid` maps a label to a regex"]
    problems = []
    for label, pattern in forbid.items():
        if not _LABEL.match(str(label)) or not isinstance(pattern, str):
            problems.append(f"{where}: forbid `{label}` must be a [a-z0-9_]+ label and a regex")
            continue
        try:
            re.compile(pattern)
        except re.error as exc:
            problems.append(f"{where}: forbid `{label}` is not a valid regex: {exc}")
    return problems


def _step_problems(step, where: str) -> list[str]:
    if not isinstance(step, dict):
        return [f"{where}: a step is an object"]
    kinds = [key for key in step if key in _STEP_KINDS]
    extra = [key for key in step if key not in _STEP_KINDS and key != "timeout_ms"]
    if len(kinds) != 1 or extra:
        return [f"{where}: exactly one of {list(_STEP_KINDS)}, got {sorted(step)}"]
    kind = kinds[0]
    if "timeout_ms" in step and kind != "await":
        return [f"{where}: only `await` takes timeout_ms"]
    return _value_problems(kind, step[kind], step, where)


def _value_problems(kind: str, value, step: dict, where: str) -> list[str]:
    if kind in _LINE_STEPS:
        return [] if isinstance(value, str) and value.strip() else [f"{where}: `{kind}` is a line"]
    if kind == "await":
        ok = value in _AWAITABLE and _bounded(step.get("timeout_ms"), MAX_AWAIT_MS)
        return [] if ok else [f"{where}: await one of {list(_AWAITABLE)} with "
                              f"timeout_ms 1..{MAX_AWAIT_MS}"]
    if kind == "pause_ms":
        return [] if _bounded(value, MAX_PAUSE_MS) else [f"{where}: pause_ms 1..{MAX_PAUSE_MS}"]
    if kind == "hold_ms":
        return [] if _bounded(value, MAX_HOLD_MS) else [f"{where}: hold_ms 1..{MAX_HOLD_MS}"]
    if kind == "mark":
        return [] if isinstance(value, str) and _LABEL.match(value) else [
            f"{where}: `mark` is a [a-z0-9_]+ label"]
    if kind == "fail":
        ok = (isinstance(value, dict) and set(value) == {"code", "message"}
              and all(isinstance(value[k], str) and value[k] for k in value))
        return [] if ok else [f"{where}: `fail` is {{code, message}}, the carrier's words"]
    return [] if value is True else [f"{where}: `{kind}` takes true"]


def _bounded(value, cap: int) -> bool:
    return not isinstance(value, bool) and isinstance(value, int) and 1 <= value <= cap


# --- the create's shape -----------------------------------------------------

def create_problems(body) -> list[str]:
    """Where a create body departs from the documented SIP create (pure)."""
    if not isinstance(body, dict):
        return ["the body is not a JSON object"]
    session = body.get("session") if isinstance(body.get("session"), dict) else {}
    transport = body.get("transport") if isinstance(body.get("transport"), dict) else {}
    trunk = transport.get("trunk") if isinstance(transport.get("trunk"), dict) else {}
    auth = trunk.get("auth") if isinstance(trunk.get("auth"), dict) else {}
    audio = session.get("audio") if isinstance(session.get("audio"), dict) else {}
    checks = [
        (transport.get("type") == "sip", "transport.type is not sip"),
        (_e164(transport.get("destination")), "transport.destination is not E.164"),
        (trunk.get("provider_url") == TRUNK_ADDRESS,
         "transport.trunk.provider_url is not the certified trunk"),
        (auth.get("type") == "digest", "transport.trunk.auth.type is not digest"),
        (_text(auth.get("username")), "transport.trunk.auth.username is missing"),
        (_text(auth.get("password")), "transport.trunk.auth.password is missing"),
        (_e164(trunk.get("caller_number")), "transport.trunk.caller_number is not E.164"),
        (session.get("store") is False, "session.store is not false"),
        ("format" not in audio, "session.audio.format is set; SIP negotiates it"),
        ((session.get("delegation") or {}).get("type") == "client",
         "session.delegation.type is not client"),
        (session.get("model") == MODEL, f"session.model is not {MODEL}"),
        (_text(session.get("instructions")), "session.instructions is missing"),
    ]
    return [problem for ok, problem in checks if not ok]


def seeded_checks(body: dict, authorization: str | None) -> list[str]:
    """Which of the seeded values a well-formed create did NOT carry (names only)."""
    trunk = body["transport"]["trunk"]
    found = {"openai_api_key": authorization == "Bearer " + SEEDED["openai_api_key"],
             "sip_username": trunk["auth"]["username"] == SEEDED["sip_username"],
             "sip_password": trunk["auth"]["password"] == SEEDED["sip_password"],
             "caller_number": trunk["caller_number"] == SEEDED["caller_number"]}
    return [name for name, ok in found.items() if not ok]


def brief_text(session: dict) -> str:
    """Every text the create's `session.input` carries, in order: the brief the
    engine wrote and how the call opens, bounded."""
    texts: list[str] = []
    pending = [session.get("input", [])]
    for _node in range(10_000):
        if not pending:
            break
        node = pending.pop(0)
        if isinstance(node, dict):
            texts.extend([node["text"]] if isinstance(node.get("text"), str) else [])
            pending.extend(value for key, value in node.items() if key != "text")
        elif isinstance(node, list):
            pending.extend(node)
    return "\n".join(texts)[:MAX_BRIEF_BYTES]


def _e164(value) -> bool:
    return isinstance(value, str) and _E164.match(value) is not None


def _text(value) -> bool:
    return isinstance(value, str) and value.strip() != ""


def first_forbidden(text: str, patterns: dict) -> str | None:
    """The label of the first pattern `text` matches, or None."""
    for label, pattern in patterns.items():
        if re.search(pattern, text):
            return label
    return None


# --- the simulator ----------------------------------------------------------

class PhoneSimulator:
    """The phone half of a `FixtureServer`. `recorder` is the server: it owns
    the per-attempt state and which attempt is current. `realtime` waits out
    each line in real time (see ONE CLOCK)."""

    def __init__(self, recorder, scripts: dict[str, Script], realtime: bool = True):
        self._recorder = recorder
        self._scripts = scripts
        self._realtime = realtime
        self._sessions: dict[str, _Session] = {}
        self._lock = threading.Lock()

    @property
    def numbers(self) -> tuple[str, ...]:
        return tuple(sorted(self._scripts))

    def handles(self, path: str) -> bool:
        return path == SESSIONS_PATH or path.startswith(SESSIONS_PATH + "/")

    def close_all(self) -> None:
        """End every live call; the server is stopping."""
        with self._lock:
            sessions = list(self._sessions.values())
        for session in sessions:
            session.signal(hangup="server_stopping")

    # The three routes. Each answers or refuses; none dials anything.

    def post(self, handler, path: str) -> None:
        if path == SESSIONS_PATH:
            self._create(handler)
            return
        session_id, tail = _session_route(path)
        if tail != "hangup":
            _vendor_error(handler, 404, "Not found.", "not_found")
            return
        self._hangup(handler, session_id)

    def get(self, handler, path: str) -> None:
        session_id, tail = _session_route(path)
        if tail != "attach":
            _vendor_error(handler, 404, "Not found.", "not_found")
            return
        self._attach(handler, session_id)

    def _create(self, handler) -> None:
        body, problem = _read_json(handler, MAX_CREATE_BYTES)
        token = self._recorder.phone_token()
        if token is None:
            _vendor_error(handler, 409, "No case attempt is bound on the simulator.", "unbound")
            return
        transport = body.get("transport") if isinstance(body, dict) else None
        destination = transport.get("destination") if isinstance(transport, dict) else None
        key = number_key(destination)
        total = self._count_create(token, key)
        refusal = problem or self._refusal(body, handler, token, key, total)
        if refusal is not None:
            self._refuse(handler, token, key, refusal)
            return
        script = self._scripts[destination]
        rec = self._recorder
        rec.phone_set(token, f"calls.{key}.script", script.name)
        self._briefed(token, key, body, script)
        if script.create == "lose_response":
            rec.phone_set(token, f"calls.{key}.ended", "response_lost")
            # The request was read in full and is never answered: the socket
            # closes with no status line, the create's answer lost on the way.
            handler.close_connection = True
            return
        if isinstance(script.create, dict):
            refuse = script.create["refuse"]
            self._refuse(handler, token, key, ("provider", refuse["status"], refuse["message"],
                                               refuse.get("code"), refuse.get("type")))
            return
        self._accept(handler, token, key, script)

    def _count_create(self, token: str, key: str) -> int | None:
        """Count the create; every one after the attempt's first is also named."""
        rec = self._recorder
        total = rec.phone_add(token, "creates", 1)
        rec.phone_add(token, f"calls.{key}.creates", 1)
        if total is not None and total > 1:
            rec.phone_append(token, "extra_creates", key, MAX_CREATES_PER_TOKEN)
        return total

    def _refuse(self, handler, token: str, key: str, refusal: tuple) -> None:
        why, status, message, *rest = refusal
        self._recorder.phone_set(token, f"calls.{key}.refused", why)
        self._recorder.phone_set(token, f"calls.{key}.ended", "refused")
        self._recorder.phone_set(token, f"calls.{key}.create_status", status)
        _vendor_error(handler, status, message, *rest)

    def _refusal(self, body, handler, token, key, total):
        """(recorded why, status, vendor message, code) for a create this
        simulator refuses before any script, or None."""
        # None: the attempt's record is full, which is past any cap as well.
        if total is None or total > MAX_CREATES_PER_TOKEN:
            return ("create_cap", 429, "Too many calls from this attempt.", "rate_limit_exceeded")
        shape = create_problems(body)
        if shape:
            return ("malformed: " + shape[0], 400, shape[0], "invalid_request_error")
        missing = seeded_checks(body, handler.headers.get("Authorization"))
        self._recorder.phone_set(token, f"calls.{key}.checks",
                                 "ok" if not missing else "mismatch: " + ", ".join(missing))
        if body["transport"]["destination"] not in self._scripts:
            return ("unscripted", 403, "No one answers at this number in the simulator.",
                    "unscripted_destination")
        return None

    def _briefed(self, token, key, body, script) -> None:
        session = body["session"]
        brief = brief_text(session)
        self._recorder.phone_set(token, f"calls.{key}.brief", brief)
        label = first_forbidden(session["instructions"] + "\n" + brief,
                                {**CREDENTIAL_FORBIDDEN, **script.forbid})
        if label is not None:
            self._recorder.phone_set(token, f"calls.{key}.briefed", label)

    def _accept(self, handler, token, key, script) -> None:
        session_id = "live_sim_" + secrets.token_hex(8)
        with self._lock:
            full = len(self._sessions) >= MAX_SESSIONS
            if not full:
                self._sessions[session_id] = _Session(session_id, token, key, script,
                                                      self._recorder, self._realtime)
        if full:
            self._refuse(handler, token, key, ("session_cap", 429,
                                               "Too many sessions on the simulator.",
                                               "rate_limit_exceeded"))
            return
        self._recorder.phone_set(token, f"calls.{key}.create_status", 201)
        body = {"session": {"id": session_id, "object": "live.session", "model": MODEL},
                "transport": {"type": "sip"}}
        _send(handler, 201, json.dumps(body).encode("utf-8"))

    def _hangup(self, handler, session_id) -> None:
        """Every hangup is counted, the ones after the end too: a repeated
        hangup is exactly the one that arrives once the session has ended."""
        session = self._session(session_id)
        rec = self._recorder
        if session is None:
            token = rec.phone_token()
            if token is not None:
                rec.phone_add(token, "unmatched_hangups", 1)
            _vendor_error(handler, 404, "No live session with that id.", "session_not_found")
            return
        rec.phone_add(session.token, f"calls.{session.key}.hangups", 1)
        rec.phone_set_once(session.token, f"calls.{session.key}.hangup_ms", session.elapsed_ms())
        if session.ended:
            _vendor_error(handler, 404, "No live session with that id.", "session_not_found")
            return
        session.signal(hangup="close_requested")
        if not session.attached:
            # No sideband plays this call, so the hangup is its end.
            session.ended = True
            rec.phone_set(session.token, f"calls.{session.key}.ended", "close_requested")
        _send(handler, 200, b"")

    def _attach(self, handler, session_id) -> None:
        session = self._session(session_id)
        if session is None or session.attached or session.ended:
            _vendor_error(handler, 404, "No session to attach to.", "session_not_found")
            return
        if not _upgrade(handler):
            return
        session.run(handler)

    def _session(self, session_id):
        if session_id is None:
            return None
        with self._lock:
            return self._sessions.get(session_id)


def _session_route(path: str) -> tuple[str | None, str]:
    rest = path[len(SESSIONS_PATH) + 1:] if path.startswith(SESSIONS_PATH + "/") else ""
    parts = rest.split("/")
    if len(parts) != 2 or not _SESSION_ID.match(parts[0]):
        return None, ""
    return parts[0], parts[1]


# --- one simulated call -----------------------------------------------------

class _Session:
    """One call's sideband: the script played on the attach thread, Fermix's
    events read on a second thread, the condition both wait on, and the call's
    one clock (`_place`)."""

    def __init__(self, session_id, token, key, script, recorder, realtime):
        self.session_id, self.token, self.key, self.script = session_id, token, key, script
        self._rec = recorder
        self._realtime = realtime
        self._cond = threading.Condition()
        self._write_lock = threading.Lock()
        self._clock_lock = threading.Lock()
        self._writer = None
        self._started = time.monotonic()
        self._event_ids = 0
        self._line_end = 0          # the end of the latest line on the call's clock
        self._last_line = None      # (start, end) of the latest line
        self._last_played = None    # the last event the script sent, for `replay`
        self._marks: list[str] = []
        self._openings = 0
        self.attached = False
        self.ended = False
        self.replies = 0
        self.keys = 0
        self.openings = 0
        self.hangup: str | None = None
        self.client_closed = False

    # -- shared state --

    def signal(self, hangup: str | None = None, reply: bool = False, key: bool = False,
               client_closed: bool = False, opening: bool = False) -> None:
        with self._cond:
            if hangup and self.hangup is None:
                self.hangup = hangup
            self.replies += 1 if reply else 0
            self.keys += 1 if key else 0
            self.openings += 1 if opening else 0
            self.client_closed = self.client_closed or client_closed
            self._cond.notify_all()

    def _terminal(self) -> bool:
        return self.hangup is not None or self.client_closed

    def _wait(self, predicate, timeout_ms: int) -> None:
        with self._cond:
            self._cond.wait_for(lambda: predicate() or self._terminal(), timeout_ms / 1000)

    def elapsed_ms(self) -> int:
        """Milliseconds since the create was accepted."""
        return int((time.monotonic() - self._started) * 1000)

    def _place(self, text: str, cut_in: bool = False) -> tuple[int, int]:
        """A line's (start, end) on the call's one clock: after the latest line
        of either speaker plus the gap, or, for a cut-in, halfway into it."""
        with self._clock_lock:
            start, end = place_line(self._line_end, self._last_line, text, cut_in,
                                    self.elapsed_ms())
            self._line_end = max(self._line_end, end)
            self._last_line = (start, end)
            return start, end

    def _now_on_clock(self) -> int:
        with self._clock_lock:
            return max(self._line_end, self.elapsed_ms())

    # -- the call --

    def run(self, handler) -> None:
        self._writer = handler.wfile
        self.attached = True
        self._rec.phone_set(self.token, f"calls.{self.key}.attached", True)
        reader = threading.Thread(target=self._read, args=(handler.rfile,),
                                  name=f"phone-sim-{self.session_id}", daemon=True)
        reader.start()
        try:
            self._play()
        finally:
            self.ended = True
            reader.join(timeout=5)

    def _play(self) -> None:
        heard = {"reply": 0, "key": 0, "opening": 0}
        for step in self.script.steps:
            if self._terminal():
                break
            if self._step(step, heard):
                return
        self._finish()

    def _step(self, step: dict, heard: dict) -> bool:
        """Play one step; True once the call is over."""
        kind = next(key for key in step if key != "timeout_ms")
        value = step[kind]
        if kind in _LINE_STEPS:
            self._line(kind, value)
        elif kind in ("ring", "answer"):
            self._play_event("transport.ringing" if kind == "ring" else "transport.answered",
                             session_id=self.session_id)
        elif kind == "fail":
            self._play_event("transport.failed", session_id=self.session_id,
                             error={"type": "call_error", **value})
        elif kind == "delegate":
            self._play_event("session.delegation.created", offset_ms=self._now_on_clock(),
                             delegation={"id": f"dlg_sim_{self._next_id()}",
                                         "type": "delegation", "target": "client"})
        elif kind == "replay" and self._last_played is not None:
            self._write_event(self._last_played)
        elif kind == "mark":
            self._marks.append(value)
            self._rec.phone_set(self.token, f"calls.{self.key}.marks.{value}", self.elapsed_ms())
        elif kind == "pause_ms":
            self._wait(lambda: False, value)
        elif kind == "await":
            self._await(value, step["timeout_ms"], heard)
        elif kind in _TERMINAL_STEPS:
            return self._terminal_step(kind, value)
        return False

    def _terminal_step(self, kind: str, value) -> bool:
        if kind == "hang_up":
            self._finish("remote_hangup")
            return True
        self._wait(lambda: False, value)
        if self._terminal():
            return False
        self._finish("expired")
        return True

    def _line(self, kind: str, text: str) -> None:
        """A scripted line: placed on the clock, said (in real time when the
        session runs realtime), then sent with its offsets."""
        start, end = self._place(text, cut_in=(kind == "cut_in"))
        if kind == "pick_up":
            self._pick_up(text, start, end)
            return
        self._say_by(end)
        speaker = "session.output_transcript.delta" if kind == "voice" else \
            "session.input_transcript.delta"
        self._play_event(speaker, delta=text, start_ms=start, end_ms=end)

    def _pick_up(self, text: str, start: int, end: int) -> None:
        """The call answered speaking: the answer and the line's first word go
        out back to back, so Fermix hears the recipient the moment it hears the
        answer, as a streaming transcript's first words follow the pickup; the
        rest of the line follows once it is said. One line on the clock, in two
        fragments that join back into it."""
        (first, first_end), rest = pick_up_fragments(text, start, end)
        self._play_event("transport.answered", session_id=self.session_id)
        self._play_event("session.input_transcript.delta", delta=first, start_ms=start,
                         end_ms=first_end)
        if rest is None:
            return
        self._say_by(end)
        self._play_event("session.input_transcript.delta", delta=rest, start_ms=first_end,
                         end_ms=end)

    def _say_by(self, end: int) -> None:
        """In real time, wait until the line ending at `end` has been said."""
        if self._realtime and end > self.elapsed_ms():
            self._wait(lambda: False, end - self.elapsed_ms())

    def _await(self, what: str, timeout_ms: int, heard: dict) -> None:
        if what == "hangup":
            self._wait(lambda: False, timeout_ms)
            return
        target = heard[what] + 1
        count = {"reply": lambda: self.replies, "key": lambda: self.keys,
                 "opening": lambda: self.openings}[what]
        self._wait(lambda: count() >= target, timeout_ms)
        heard[what] = max(heard[what], min(count(), target))

    def _finish(self, reason: str | None = None) -> None:
        """End the call as `reason`, or as Fermix asked: final usage, then
        `session.closed` (the only event that confirms finalization), then a
        normal close."""
        why = reason or self.hangup or "expired"
        if self.client_closed and reason is None and self.hangup is None:
            self._rec.phone_set(self.token, f"calls.{self.key}.ended", "client_closed")
            return
        seconds = round(self._now_on_clock() / 1000)
        self._event("session.usage.updated", usage={"seconds": seconds},
                    context_window={"usage_ratio": 0.05})
        self._event("session.closed", reason=why, usage={"seconds": seconds},
                    session={"id": self.session_id, "status": "closed"})
        self._close_frame(1000)
        self._rec.phone_set(self.token, f"calls.{self.key}.ended", why)

    # -- what Fermix sends --

    def _read(self, rfile) -> None:
        while True:
            try:
                frame = _read_message(rfile)
            except (OSError, ValueError):
                frame = None
            if frame is None:
                self.signal(client_closed=True)
                return
            opcode, payload = frame
            if opcode == 0x8:
                self._close_frame(1000)
                self.signal(client_closed=True)
                return
            if opcode == 0x9:
                self._write(_frame(0xA, payload))
            elif opcode == 0x1:
                self._client_event(payload)

    def _client_event(self, payload: bytes) -> None:
        try:
            event = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            self._protocol_error("not_json", None)
            return
        kind = event.get("type") if isinstance(event, dict) else None
        client_id = event.get("event_id") if isinstance(event, dict) else None
        if kind == "transport.dtmf.send":
            self._dtmf(event.get("event"), client_id)
        elif kind in ("session.commentary.append", "session.thinking.append",
                      "session.instructions.append"):
            self._append(kind, event, client_id)
        elif kind == "session.close":
            self.signal(hangup="close_requested")
        else:
            self._protocol_error(str(kind), client_id)

    def _dtmf(self, key, client_id) -> None:
        if not (isinstance(key, str) and _DTMF.match(key) and isinstance(client_id, str)):
            self._protocol_error("transport.dtmf.send", client_id)
            return
        self._rec.phone_concat(self.token, f"calls.{self.key}.keys", key)
        self._event("transport.dtmf.sent", event=key, client_event_id=client_id)
        self.signal(key=True)

    def _append(self, kind: str, event: dict, client_id) -> None:
        content = event.get("content")
        if not isinstance(content, str) or "delegation_id" not in event:
            self._protocol_error(kind, client_id)
            return
        label = first_forbidden(content, {**ALWAYS_FORBIDDEN, **self.script.forbid})
        if label is not None:
            self._rec.phone_set_once(self.token, f"calls.{self.key}.leaked",
                                     f"{label}: {kind.split('.')[1]}")
        self._event(kind.replace(".append", ".appended"), client_event_id=client_id)
        if kind == "session.commentary.append":
            self._spoken(event["delegation_id"], content)

    def _spoken(self, delegation_id, content: str) -> None:
        """A commentary: what the voice is given to say. The call's first one
        with no delegation is its opening line; every other one is
        recorded against the marks the script has passed, and a delegation's
        reply is spoken on the call's clock."""
        opening = delegation_id is None and self._openings == 0
        self._openings += 1 if delegation_id is None else 0
        if opening:
            self._rec.phone_set(self.token, f"calls.{self.key}.opening", True)
            self.signal(opening=True)
            return
        for mark in list(self._marks):
            self._rec.phone_append(self.token, f"calls.{self.key}.said_after.{mark}",
                                   content[:REPLY_RECORD_BYTES], MAX_REPLIES_PER_CALL)
        if delegation_id is None:
            return
        self._rec.phone_append(self.token, f"calls.{self.key}.replies",
                               {"text": content[:REPLY_RECORD_BYTES], "at_ms": self.elapsed_ms()},
                               MAX_REPLIES_PER_CALL)
        start, end = self._place(content)
        self._event("session.output_transcript.delta", delta=content, start_ms=start, end_ms=end)
        self.signal(reply=True)

    def _protocol_error(self, kind: str, client_id) -> None:
        self._rec.phone_append(self.token, f"calls.{self.key}.protocol_errors", kind,
                               MAX_REPLIES_PER_CALL)
        self._event("error", error={"type": "invalid_request_error", "code": "unsupported_event",
                                    "message": f"{kind} is not accepted on this sideband.",
                                    "param": None, "client_event_id": client_id})

    # -- what the vendor sends --

    def _play_event(self, kind: str, **fields) -> None:
        """An event of the script's, remembered for `replay`."""
        self._last_played = self._event(kind, **fields)

    def _event(self, kind: str, **fields) -> dict:
        event = {"type": kind, "event_id": f"evt_sim_{self._next_id()}", **fields}
        self._write_event(event)
        return event

    def _write_event(self, event: dict) -> None:
        self._write(_frame(0x1, json.dumps(event, ensure_ascii=False).encode("utf-8")))

    def _next_id(self) -> int:
        with self._write_lock:
            self._event_ids += 1
            return self._event_ids

    def _close_frame(self, code: int) -> None:
        self._write(_frame(0x8, struct.pack(">H", code)))

    def _write(self, data: bytes) -> None:
        with self._write_lock:
            try:
                self._writer.write(data)
                self._writer.flush()
            except OSError:
                self.signal(client_closed=True)


# --- HTTP and WebSocket plumbing (stdlib only) ------------------------------

def _read_json(handler, limit: int):
    """(body, None) or (None, (recorded why, status, message, code))."""
    length = handler.headers.get("Content-Length")
    if length is None or not length.isdigit() or int(length) > limit:
        handler.close_connection = True
        return None, ("malformed: body length", 400, "A bounded JSON body is required.",
                      "invalid_request_error")
    raw = handler.rfile.read(int(length))
    try:
        body = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None, ("malformed: not JSON", 400, "The body is not JSON.", "invalid_request_error")
    return body, None


def _vendor_error(handler, status: int, message: str, code: str | None = None,
                  kind: str | None = None) -> None:
    error = {"message": message, "type": kind or "invalid_request_error", "code": code}
    _send(handler, status, json.dumps({"error": error}).encode("utf-8"))


def _send(handler, status: int, body: bytes) -> None:
    """One answer, and the end of its connection: each phone request is its own,
    so no kept-alive socket outlives the request that opened it."""
    handler.close_connection = True
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Connection", "close")
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    if body:
        handler.wfile.write(body)


def _upgrade(handler) -> bool:
    """Answer a WebSocket upgrade (RFC 6455): 101 with the accept digest."""
    key = handler.headers.get("Sec-WebSocket-Key")
    if (handler.headers.get("Upgrade", "").lower() != "websocket" or not key
            or not (handler.headers.get("Authorization") or "").startswith("Bearer ")):
        _vendor_error(handler, 400, "A WebSocket upgrade with a bearer key is required.",
                      "invalid_request_error")
        return False
    accept = base64.b64encode(hashlib.sha1((key + _WS_GUID).encode("ascii")).digest())
    handler.send_response(101, "Switching Protocols")
    handler.send_header("Upgrade", "websocket")
    handler.send_header("Connection", "Upgrade")
    handler.send_header("Sec-WebSocket-Accept", accept.decode("ascii"))
    handler.end_headers()
    handler.wfile.flush()
    handler.close_connection = True
    return True


def _frame(opcode: int, payload: bytes) -> bytes:
    """One unmasked, unfragmented server frame."""
    size = len(payload)
    if size < 126:
        head = struct.pack(">BB", 0x80 | opcode, size)
    elif size < 65536:
        head = struct.pack(">BBH", 0x80 | opcode, 126, size)
    else:
        head = struct.pack(">BBQ", 0x80 | opcode, 127, size)
    return head + payload


def _read_exact(rfile, size: int) -> bytes | None:
    data = rfile.read(size)
    return data if data is not None and len(data) == size else None


def _read_message(rfile) -> tuple[int, bytes] | None:
    """One client message, its fragments joined, or None at end of stream. A
    client frame must be masked; anything past the bounds is a ValueError."""
    opcode, chunks, total = None, [], 0
    for _fragment in range(64):
        head = _read_exact(rfile, 2)
        if head is None:
            return None
        fin, frame_op, masked, size = head[0] & 0x80, head[0] & 0x0F, head[1] & 0x80, head[1] & 0x7F
        if size == 126:
            size = struct.unpack(">H", _read_exact(rfile, 2) or b"\0\0")[0]
        elif size == 127:
            size = struct.unpack(">Q", _read_exact(rfile, 8) or b"\0" * 8)[0]
        total += size
        if not masked or total > MAX_FRAME_BYTES:
            raise ValueError("unmasked or oversized client frame")
        mask = _read_exact(rfile, 4)
        data = _read_exact(rfile, size) if size else b""
        if mask is None or data is None:
            return None
        chunks.append(bytes(byte ^ mask[index % 4] for index, byte in enumerate(data)))
        opcode = frame_op if opcode is None else opcode
        if frame_op >= 0x8 or fin:
            return (frame_op if frame_op >= 0x8 else opcode), b"".join(chunks)
    raise ValueError("too many fragments")
