"""Drive an eval case over the local voice socket (`$FERMIX_HOME/realtime.sock`).

The socket is the Mac app's voice call: newline-delimited JSON, a mandatory
`client_hello`, and the wire `apps/fermix_core/priv/realtime/PROTOCOL.md`
documents (protocol v3). The runner speaks it the way the app does, so a
`drive: voice` case exercises the whole spoken path: the provider's voice model
hears fixture audio, decides to hand the request to Fermix, and Fermix's task
runs through the real VoiceBridge and agent loop. `fermix ask` and the
companion chat socket never reach the voice model, which is the gap this drive
closes.

A case is one call (the `voice:` map of the case):

- `clips` — what the owner says, in order: fixture WAVs (24 kHz mono PCM16)
  named by their key in `suites/fixtures/voice/manifest.json`. Each clip waits
  `gap_ms` of silence first; a later clip with `after: task_running` waits for a
  task frame saying `running` before its gap starts, so "while that runs" and
  "cancel that" are said while the task is in flight. A clip whose `after`
  never holds is abandoned, with the clips after it, and the call goes on.
- `quiet_ms` — the call has settled once every clip was said, every task's
  newest revision ended, everything the voice sent has played, and nothing new
  arrived for this long. Then the runner ends the call.

The microphone streams continuously from the daemon's `listening` until the
call ends: 100 ms chunks of 24 kHz mono PCM16 at real-time pace, silence
between and after the clips. Assistant audio goes to a simulated speaker
(`PlaybackSink`) that plays it in real time and reports `playback_progress`
for every playback id at most every 100 ms, and at once when an id drains or
playback stops. A simulated sink proves the protocol logic, not physical
latency: that belongs to the native app.

What the daemon said is recorded frame by frame (`state`, `call_ready`,
`caption`, `task`, `usage`, `error`, `playback_stop`, and `audio_delta` by size
only) and becomes the `wire.*` gates (`wire_gates`). The call's Opik trace,
whose root is the call (`voice_live:<n>`) and into which every backend task
turn (`voice_delegation_<n>`, `parent_session` = the call) nests, is found by
`poll_call_trace` and graded by the ordinary gates.

Everything is bounded: the handshake, the start, each clip's wait, the whole
call (`timeout_ms`), and the close. A socket that cannot be reached, refuses,
closes, or does not settle within the bound is evidence that is not gradable,
never a failed gate; the call is ended on every path once it was started.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import re
import socket
import time
import wave
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from .grade import GateResult
from .opik import parse_ts

PROTOCOL_VERSION = 3
SOCKET_NAME = "realtime.sock"
SAMPLE_RATE = 24_000
BYTES_PER_MS = 48                       # PCM16, 24 kHz, mono
CHUNK_MS = 100
CHUNK_BYTES = CHUNK_MS * BYTES_PER_MS
REPORT_EVERY_MS = 100
FIXTURE_SUBDIR = "voice"
MANIFEST = "manifest.json"

FRAME_TYPES = ("state", "call_ready", "caption", "audio_delta", "playback_stop", "task",
               "usage", "error")
TASK_STATUSES = ("pending", "running", "completed", "failed", "cancelled")
TERMINAL_STATUSES = ("completed", "failed", "cancelled")
# What a task revision ENDED as: its last status, except that a cancelled
# revision a newer revision of the same task replaced reads `superseded`.
ENDED_STATUSES = (*TASK_STATUSES, "superseded")
AFTER_CONDITIONS = ("task_running",)
SPEC_KEYS = {"clips", "quiet_ms"}
CLIP_KEYS = {"say", "gap_ms", "after"}
WIRE_KEYS = {"engine", "events_all", "events_none", "task_statuses_all", "task_statuses_none",
             "caption_not_matches", "max_tasks", "task_terminal_once",
             "spoke_while_task_running"}

MAX_CLIPS = 4
DEFAULT_GAP_MS = 1_500
MAX_GAP_MS = 30_000
DEFAULT_QUIET_MS = 5_000
MIN_QUIET_MS = 1_000
MAX_QUIET_MS = 20_000
AFTER_WAIT_MS = 30_000                  # how long a clip waits for its `after`
HELLO_WAIT_S = 5.0
READY_WAIT_S = 20.0                     # call_start -> call_ready (the daemon's own is 12 s)
CLOSE_WAIT_S = 10.0                     # call_stop -> the final usage
_TICK_S = 0.02                          # the speaker's clock granularity
_MAX_CATCH_UP = 10                      # mic chunks sent in one pass after a stall
_LINE_MAX = 1 << 20


class VoiceError(Exception):
    """The socket refused, closed, or never answered: the attempt is not gradable."""


# --- fixtures and suite validation -------------------------------------------

def manifest_path(fixtures_dir: str) -> str:
    return os.path.join(fixtures_dir, FIXTURE_SUBDIR, MANIFEST)


def load_manifest(fixtures_dir: str) -> tuple[dict, str | None]:
    """The manifest's clips by key, or why there are none."""
    path = manifest_path(fixtures_dir)
    try:
        with open(path, encoding="utf-8") as handle:
            clips = json.load(handle).get("clips")
    except (OSError, ValueError) as exc:
        return {}, f"cannot read the voice fixture manifest {path}: {exc}"
    if not isinstance(clips, dict) or not clips:
        return {}, f"{path} has no `clips` map"
    return clips, None


def clip_problem(fixtures_dir: str, key: str, entry) -> str | None:
    """Why a manifest clip cannot be streamed: a missing or moved file, a hash
    that no longer matches, or audio that is not 24 kHz mono PCM16."""
    if not isinstance(entry, dict) or not isinstance(entry.get("text"), str):
        return f"voice clip `{key}` has no text in the manifest"
    name = entry.get("file")
    if not isinstance(name, str) or os.path.basename(name) != name or not name.endswith(".wav"):
        return f"voice clip `{key}` must name a .wav beside the manifest"
    path = os.path.join(fixtures_dir, FIXTURE_SUBDIR, name)
    try:
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        with wave.open(path, "rb") as clip:
            shape = (clip.getframerate(), clip.getnchannels(), clip.getsampwidth())
    except (OSError, wave.Error, EOFError) as exc:
        return f"voice clip `{key}` cannot be read: {exc}"
    if digest != entry.get("sha256"):
        return (f"voice clip `{key}` does not match its manifest sha256; regenerate with "
                "`uv run bin/make_voice_fixtures.py`")
    if shape != (SAMPLE_RATE, 1, 2):
        return f"voice clip `{key}` is {shape[0]} Hz, {shape[1]} channel(s), " \
               f"{8 * shape[2]}-bit; the socket carries {SAMPLE_RATE} Hz mono 16-bit"
    return None


def spec_problems(spec, where: str, fixtures_dir: str) -> list[str]:
    """What is wrong with a case's `voice:` map, its clips checked against the
    fixture manifest and the WAVs themselves."""
    if not isinstance(spec, dict):
        return [f"{where}: `voice` must be a map"]
    problems = [f"{where}: unknown `voice` key `{key}`" for key in spec if key not in SPEC_KEYS]
    quiet = spec.get("quiet_ms", DEFAULT_QUIET_MS)
    if isinstance(quiet, bool) or not isinstance(quiet, int) \
            or not MIN_QUIET_MS <= quiet <= MAX_QUIET_MS:
        problems.append(f"{where}: `voice.quiet_ms` must be an integer "
                        f"{MIN_QUIET_MS}..{MAX_QUIET_MS}")
    clips = spec.get("clips")
    if not isinstance(clips, list) or not 1 <= len(clips) <= MAX_CLIPS:
        return problems + [f"{where}: `voice.clips` must be a list of 1..{MAX_CLIPS} clips"]
    manifest, error = load_manifest(fixtures_dir)
    if error:
        return problems + [f"{where}: {error}"]
    for index, clip in enumerate(clips):
        problems.extend(_clip_entry_problems(clip, index, f"{where}: voice.clips[{index}]",
                                             manifest, fixtures_dir))
    return problems


def _clip_entry_problems(clip, index: int, where: str, manifest: dict,
                         fixtures_dir: str) -> list[str]:
    if not isinstance(clip, dict):
        return [f"{where}: must be a map with `say`"]
    problems = [f"{where}: unknown clip key `{key}`" for key in clip if key not in CLIP_KEYS]
    gap = clip.get("gap_ms", DEFAULT_GAP_MS)
    if isinstance(gap, bool) or not isinstance(gap, int) or not 0 <= gap <= MAX_GAP_MS:
        problems.append(f"{where}: `gap_ms` must be an integer 0..{MAX_GAP_MS}")
    after = clip.get("after")
    if after is not None and after not in AFTER_CONDITIONS:
        problems.append(f"{where}: `after` must be one of {list(AFTER_CONDITIONS)}")
    if after is not None and index == 0:
        problems.append(f"{where}: the first clip opens the call and cannot wait on `after`")
    key = clip.get("say")
    if key not in manifest:
        problems.append(f"{where}: `say` must name a clip in {FIXTURE_SUBDIR}/{MANIFEST}, "
                        f"got {key!r}")
        return problems
    problem = clip_problem(fixtures_dir, key, manifest[key])
    return problems + ([f"{where}: {problem}"] if problem else [])


def spoken_text(spec: dict, fixtures_dir: str) -> str:
    """What the owner says in the case, one clip per line: the case's `query`."""
    manifest, _error = load_manifest(fixtures_dir)
    return "\n".join(manifest[clip["say"]]["text"] for clip in spec["clips"])


def wire_problems(wire, where: str) -> list[str]:
    """What is wrong with a `drive: voice` case's `expect.wire` map."""
    if not isinstance(wire, dict):
        return [f"{where}: expect `wire` must be a map"]
    problems = [f"{where}: unknown `wire` key `{key}`" for key in wire if key not in WIRE_KEYS]
    if "engine" in wire and not (isinstance(wire["engine"], str) and wire["engine"]):
        problems.append(f"{where}: `wire.engine` must be a non-empty string")
    for key, vocabulary in (("events_all", FRAME_TYPES), ("events_none", FRAME_TYPES),
                            ("task_statuses_all", ENDED_STATUSES),
                            ("task_statuses_none", ENDED_STATUSES)):
        value = wire.get(key)
        if value is not None and (not isinstance(value, list) or not value
                                  or any(item not in vocabulary for item in value)):
            problems.append(f"{where}: `wire.{key}` must be a non-empty list drawn from "
                            f"{list(vocabulary)}")
    if "caption_not_matches" in wire:
        problems.extend(_regex_problems(wire["caption_not_matches"],
                                        f"{where}: `wire.caption_not_matches`"))
    if "max_tasks" in wire:
        value = wire["max_tasks"]
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            problems.append(f"{where}: `wire.max_tasks` must be a positive integer")
    for key in ("task_terminal_once", "spoke_while_task_running"):
        if key in wire and wire[key] is not True:
            problems.append(f"{where}: `wire.{key}` must be true")
    return problems


def _regex_problems(pattern, where: str) -> list[str]:
    if not isinstance(pattern, str) or not pattern:
        return [f"{where} must be a non-empty regex string"]
    try:
        re.compile(pattern)
    except re.error as exc:
        return [f"{where} is not a valid regex: {exc}"]
    return []


# --- the plan -----------------------------------------------------------------

@dataclass(frozen=True)
class Clip:
    say: str
    pcm: bytes
    gap_ms: int = DEFAULT_GAP_MS
    after: str | None = None


@dataclass(frozen=True)
class Plan:
    clips: tuple[Clip, ...]
    quiet_ms: int = DEFAULT_QUIET_MS


def plan_for(spec: dict, fixtures_dir: str) -> Plan:
    """The validated `voice:` map with each clip's PCM read off its WAV."""
    manifest, error = load_manifest(fixtures_dir)
    if error:
        raise VoiceError(error)
    clips = []
    for clip in spec["clips"]:
        path = os.path.join(fixtures_dir, FIXTURE_SUBDIR, manifest[clip["say"]]["file"])
        with wave.open(path, "rb") as handle:
            pcm = handle.readframes(handle.getnframes())
        clips.append(Clip(clip["say"], pcm, clip.get("gap_ms", DEFAULT_GAP_MS),
                          clip.get("after")))
    return Plan(tuple(clips), spec.get("quiet_ms", DEFAULT_QUIET_MS))


# --- the simulated speaker ----------------------------------------------------

class PlaybackSink:
    """Plays assistant audio in real time, in arrival order, and says how much
    of each playback id it has played (PROTOCOL.md, *Playback feedback*).

    Pure: the caller passes the clock in milliseconds. A report is the
    `playback_progress` frame to send. While an id plays it is reported at most
    every `REPORT_EVERY_MS`; when it drains, or when playback stops, at once.
    `played_ms` never decreases and never passes the audio received for the id.
    """

    def __init__(self, now_ms: float):
        self._queue: deque[list] = deque()      # [playback_id, bytes left], arrival order
        self._ids: dict[str, dict] = {}
        self._clock = now_ms
        self._carry = 0.0

    def idle(self) -> bool:
        return not self._queue

    def receive(self, playback_id: str, size: int, now_ms: float) -> list[dict]:
        reports = self.tick(now_ms)             # time before the audio arrived plays nothing of it
        if size <= 0:
            return reports
        entry = self._ids.setdefault(playback_id, {"received": 0, "played": 0,
                                                   "reported_ms": 0, "reported_at": None,
                                                   "drained": False})
        entry["received"] += size
        entry["drained"] = False
        if self._queue and self._queue[-1][0] == playback_id:
            self._queue[-1][1] += size
        else:
            self._queue.append([playback_id, size])
        return reports

    def tick(self, now_ms: float) -> list[dict]:
        elapsed = max(0.0, now_ms - self._clock)
        self._clock = max(self._clock, now_ms)
        if not self._queue:
            self._carry = 0.0
            return []
        played = self._play(elapsed * BYTES_PER_MS + self._carry)
        return [report for pid in played if (report := self._due(pid, now_ms)) is not None]

    def stop(self, now_ms: float) -> list[dict]:
        """`playback_stop`: what has not played is dropped; each cut id is
        reported at once with what it played."""
        reports = self.tick(now_ms)
        cut = list(dict.fromkeys(pid for pid, _left in self._queue))
        self._queue.clear()
        self._carry = 0.0
        for pid in cut:
            entry = self._ids[pid]
            reports.append(self._report(pid, now_ms, drained=False))
            entry["received"] = entry["played"]
            entry["drained"] = True
        return reports

    def _play(self, budget: float) -> list[str]:
        touched: list[str] = []
        while self._queue and budget >= 1:
            head = self._queue[0]
            step = min(head[1], int(budget))
            head[1] -= step
            budget -= step
            self._ids[head[0]]["played"] += step
            if head[0] not in touched:
                touched.append(head[0])
            if head[1] == 0:
                self._queue.popleft()
        self._carry = budget if self._queue else 0.0
        return touched

    def _due(self, pid: str, now_ms: float) -> dict | None:
        entry = self._ids[pid]
        if entry["played"] == entry["received"] and not entry["drained"]:
            entry["drained"] = True
            return self._report(pid, now_ms, drained=True)
        last = entry["reported_at"]
        if entry["drained"] or (last is not None and now_ms - last < REPORT_EVERY_MS):
            return None
        return self._report(pid, now_ms, drained=False)

    def _report(self, pid: str, now_ms: float, drained: bool) -> dict:
        entry = self._ids[pid]
        played_ms = max(entry["reported_ms"], entry["played"] // BYTES_PER_MS)
        entry["reported_ms"], entry["reported_at"] = played_ms, now_ms
        return {"type": "playback_progress", "playback_id": pid, "played_ms": played_ms,
                "drained": drained}


# --- evidence -----------------------------------------------------------------

_KEPT_FIELDS = {
    "state": ("state",),
    "call_ready": ("engine", "call_id", "call_uuid", "conversation", "tasks_outlive_call",
                   "provider_session_id", "captions"),
    "caption": ("speaker", "delta", "start_ms", "end_ms"),
    "task": ("delegation_id", "revision", "status", "summary", "server_seq", "detached"),
    "usage": ("status", "accounting", "voice_seconds", "voice_cost_cents", "voice_text_items",
              "backend_turns", "backend_cost"),
    "error": ("reason", "kind", "detail", "required_for"),
    "playback_stop": (),
}


def record(frame: dict, t_ms: float) -> dict:
    """What the evidence keeps of one daemon frame: audio by size only, and an
    unrecognised frame by its type alone (logged, never dropped)."""
    kind = frame.get("type")
    kept: dict = {"t_ms": round(t_ms, 1), "type": kind if isinstance(kind, str) else "?"}
    if kind == "audio_delta":
        pcm = audio_bytes(frame.get("audio"))
        kept["bytes"] = len(pcm)
        if not any(pcm):
            kept["silent"] = True       # Live streams digital silence between replies
        if isinstance(frame.get("playback_id"), str):
            kept["playback_id"] = frame["playback_id"]
        return kept
    for name in _KEPT_FIELDS.get(kind, ()):
        if name in frame:
            kept[name] = frame[name]
    return kept


def audio_bytes(audio) -> bytes:
    try:
        return base64.b64decode(audio, validate=True) if isinstance(audio, str) else b""
    except (binascii.Error, ValueError):
        return b""


@dataclass
class Evidence:
    ok: bool
    error: str | None
    started_at: datetime
    elapsed_ms: float = 0.0             # call_start until the call settled
    frames: list[dict] = field(default_factory=list)
    clips: list[dict] = field(default_factory=list)      # {"say", "start_ms", "end_ms"}
    abandoned: list[str] = field(default_factory=list)   # clips whose `after` never held
    reports_sent: int = 0

    def of(self, kind: str) -> list[dict]:
        return [frame for frame in self.frames if frame["type"] == kind]

    def call_ready(self) -> dict:
        return next(iter(self.of("call_ready")), {})

    def call_id(self) -> str | None:
        return self.call_ready().get("call_id")

    def provider_session_id(self) -> str | None:
        return self.call_ready().get("provider_session_id")

    def spoken(self) -> str:
        """Everything the voice said aloud, its caption bytes concatenated as received."""
        return "".join(frame.get("delta", "") for frame in self.of("caption")
                       if frame.get("speaker") == "assistant")

    def task_outcomes(self) -> dict[tuple[str, int], str]:
        """How each task revision ended (`ENDED_STATUSES`)."""
        last: dict[tuple[str, int], str] = {}
        newest: dict[str, int] = {}
        for frame in self.of("task"):
            key = (frame.get("delegation_id"), frame.get("revision"))
            last[key] = frame.get("status")
            if isinstance(key[1], int):
                newest[key[0]] = max(newest.get(key[0], key[1]), key[1])
        return {key: ("superseded" if status == "cancelled" and isinstance(key[1], int)
                      and key[1] < newest.get(key[0], key[1]) else status)
                for key, status in last.items()}

    def summary(self) -> dict:
        """The persisted digest: identifiers, outcomes and counts, never what was said."""
        ready = self.call_ready()
        counts: dict[str, int] = {}
        for frame in self.frames:
            counts[frame["type"]] = counts.get(frame["type"], 0) + 1
        return {"call_id": ready.get("call_id"), "call_uuid": ready.get("call_uuid"),
                "engine": ready.get("engine"), "conversation": ready.get("conversation"),
                "tasks": [{"delegation_id": key[0], "revision": key[1], "ended": status}
                          for key, status in self.task_outcomes().items()],
                "frames": counts, "playback_reports": self.reports_sent,
                "clips": [{"say": c["say"], "start_ms": c["start_ms"], "end_ms": c["end_ms"]}
                          for c in self.clips],
                "abandoned_clips": list(self.abandoned)}


def _in_flight_while(evidence: Evidence, after_ms: float) -> bool:
    """Whether an assistant caption arrived at or after `after_ms` while some
    task's newest revision had not ended."""
    newest: dict[str, tuple[int, str]] = {}
    for frame in evidence.frames:
        if frame["type"] == "task":
            pid, rev = frame.get("delegation_id"), frame.get("revision")
            if not isinstance(rev, int):
                continue
            if pid not in newest or rev >= newest[pid][0]:
                newest[pid] = (rev, frame.get("status"))
        elif (frame["type"] == "caption" and frame.get("speaker") == "assistant"
              and frame["t_ms"] >= after_ms
              and any(status not in TERMINAL_STATUSES for _rev, status in newest.values())):
            return True
    return False


def wire_gates(evidence: Evidence, wire: dict) -> list[GateResult]:
    """One `wire.<key>` gate per key, over what the socket said."""
    out: list[GateResult] = []
    seen = sorted({frame["type"] for frame in evidence.frames})
    outcomes = evidence.task_outcomes()
    ended = sorted(set(outcomes.values()))

    def add(key, passed, detail):
        out.append(GateResult(key=f"wire.{key}", passed=passed, detail=detail))

    if "engine" in wire:
        engine = evidence.call_ready().get("engine")
        add("engine", engine == wire["engine"],
            f"call_ready.engine {engine!r}, expected {wire['engine']!r}")
    if "events_all" in wire:
        missing = [e for e in wire["events_all"] if e not in seen]
        add("events_all", not missing, f"all{wire['events_all']}: missing={missing or 'none'} "
                                       f"(seen={seen})")
    if "events_none" in wire:
        bad = [e for e in wire["events_none"] if e in seen]
        add("events_none", not bad, f"none{wire['events_none']}: present={bad or 'none'}")
    if "task_statuses_all" in wire:
        missing = [s for s in wire["task_statuses_all"] if s not in ended]
        add("task_statuses_all", not missing,
            f"all{wire['task_statuses_all']}: missing={missing or 'none'} (ended={ended})")
    if "task_statuses_none" in wire:
        bad = [s for s in wire["task_statuses_none"] if s in ended]
        add("task_statuses_none", not bad,
            f"none{wire['task_statuses_none']}: present={bad or 'none'} (ended={ended})")
    if "caption_not_matches" in wire:
        pattern = wire["caption_not_matches"]
        hit = re.search(pattern, evidence.spoken()) is not None
        add("caption_not_matches", not hit,
            f"/{pattern}/ {'PRESENT in what the voice said' if hit else 'absent'}")
    if "max_tasks" in wire:
        tasks = len({key[0] for key in outcomes})
        add("max_tasks", tasks <= wire["max_tasks"], f"<= {wire['max_tasks']} task(s) "
                                                     f"(got {tasks})")
    if "task_terminal_once" in wire:
        add("task_terminal_once", *_terminal_once(evidence))
    if "spoke_while_task_running" in wire:
        last_clip_end = max((clip["end_ms"] for clip in evidence.clips), default=None)
        spoke = last_clip_end is not None and _in_flight_while(evidence, last_clip_end)
        add("spoke_while_task_running", spoke,
            "the voice spoke after the last clip while a task was in flight"
            if spoke else "no assistant caption after the last clip while a task was in flight")
    return out


def _terminal_once(evidence: Evidence) -> tuple[bool, str]:
    """No task revision ends twice, and no task completes twice."""
    ends: dict[tuple, int] = {}
    completions: dict[str, int] = {}
    for frame in evidence.of("task"):
        if frame.get("status") not in TERMINAL_STATUSES:
            continue
        key = (frame.get("delegation_id"), frame.get("revision"))
        ends[key] = ends.get(key, 0) + 1
        if frame.get("status") == "completed":
            completions[key[0]] = completions.get(key[0], 0) + 1
    twice = sorted(f"{key[0]}#{key[1]}" for key, count in ends.items() if count > 1)
    again = sorted(pid for pid, count in completions.items() if count > 1)
    passed = not twice and not again
    return passed, (f"revisions ended twice={twice or 'none'}; "
                    f"tasks completed twice={again or 'none'}")


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
            raise VoiceError(f"cannot connect to {path}: {exc}") from exc

    def send(self, event: dict) -> None:
        try:
            self._sock.sendall(json.dumps(event).encode("utf-8") + b"\n")
        except OSError as exc:
            raise VoiceError(f"send failed: {exc}") from exc

    def recv(self, deadline: float) -> dict | None:
        """The next frame, or None once `deadline` (monotonic) passes."""
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
                raise VoiceError(f"read failed: {exc}") from exc
            if not chunk:
                raise VoiceError("the daemon closed the connection")
            self._buffer += chunk
            if len(self._buffer) > _LINE_MAX and b"\n" not in self._buffer:
                raise VoiceError("the daemon sent a line over 1 MiB")
        line, self._buffer = self._buffer.split(b"\n", 1)
        try:
            frame = json.loads(line)
        except ValueError as exc:
            raise VoiceError(f"the daemon sent a line that is not JSON: {exc}") from exc
        if not isinstance(frame, dict):
            raise VoiceError("the daemon sent a frame that is not a JSON object")
        return frame

    def close(self) -> None:
        self._sock.close()


def socket_path(fermix_home: str) -> str:
    return os.path.join(os.path.expanduser(fermix_home), SOCKET_NAME)


# --- one call -----------------------------------------------------------------

class _Mic:
    """The microphone: silence, and each clip once its turn and gap have come."""

    def __init__(self, plan: Plan):
        self._clips = list(plan.clips)
        self._index = 0
        self._offset: int | None = None
        self._since: float | None = None        # when the next clip's wait began
        self._ready_at: float | None = None
        self.played: list[dict] = []
        self.abandoned: list[str] = []

    def done(self) -> bool:
        return self._index >= len(self._clips)

    def last_end(self) -> float | None:
        return self.played[-1]["end_ms"] if self.played else None

    def chunk(self, at_ms: float, call: "_Call") -> bytes:
        """The next chunk. `at_ms` is when it is due on the microphone's own
        schedule, not when it is sent, so a clip ends when its audio does: a
        loop that wakes late and catches up cannot send the silence after a
        clip before the clip's recorded end."""
        if self._offset is None and not self.done():
            self._maybe_start(at_ms, call)
        if self._offset is None:
            return bytes(CHUNK_BYTES)
        clip = self._clips[self._index]
        piece = clip.pcm[self._offset:self._offset + CHUNK_BYTES]
        self._offset += CHUNK_BYTES
        if self._offset >= len(clip.pcm):
            self.played[-1]["end_ms"] = round(at_ms + CHUNK_MS, 1)
            self._offset, self._since, self._ready_at = None, at_ms + CHUNK_MS, None
            self._index += 1
        return piece + bytes(CHUNK_BYTES - len(piece))

    def _maybe_start(self, now_ms: float, call: "_Call") -> None:
        if call.ready_at_ms is None:
            return
        clip = self._clips[self._index]
        since = self._since if self._since is not None else call.ready_at_ms
        if self._ready_at is None:
            held_at = self._condition_held_at(clip, call)
            if held_at is None:
                if now_ms - since > AFTER_WAIT_MS:
                    self.abandoned.extend(c.say for c in self._clips[self._index:])
                    self._index = len(self._clips)
                return
            self._ready_at = max(held_at, since) + clip.gap_ms
        if now_ms >= self._ready_at:
            self._offset = 0
            self.played.append({"say": clip.say, "start_ms": round(now_ms, 1),
                                "end_ms": round(now_ms, 1)})

    def _condition_held_at(self, clip: Clip, call: "_Call") -> float | None:
        """When the clip's `after` first held: `task_running` is a task frame
        saying `running` since the previous clip began."""
        if clip.after is None:
            return 0.0
        begun = self.played[-1]["start_ms"] if self.played else call.ready_at_ms
        return next((t for t in call.running_at if t >= begun), None)


class _Call:
    """What the daemon has said so far, as the call's choreography reads it."""

    def __init__(self):
        self.frames: list[dict] = []
        self.ready_at_ms: float | None = None
        self.listening = False
        self.running_at: list[float] = []
        self.last_activity_ms = 0.0
        self.tasks: dict[str, tuple[int, str]] = {}     # id -> newest (revision, status)
        self.final_usage = False
        self.idle = False

    def take(self, frame: dict, t_ms: float) -> dict:
        kept = record(frame, t_ms)
        self.frames.append(kept)
        kind = kept["type"]
        if kind == "state":
            self.listening |= kept.get("state") == "listening"
            self.idle |= kept.get("state") == "idle"
        elif kind == "call_ready" and self.ready_at_ms is None:
            self.ready_at_ms = t_ms
        elif kind == "task":
            self._task(kept, t_ms)
        elif kind == "usage" and self.idle and kept.get("accounting") not in (None, "running"):
            self.final_usage = True
        speech = kind != "audio_delta" or not kept.get("silent")
        if kind in ("audio_delta", "caption", "task", "playback_stop") and speech:
            self.last_activity_ms = t_ms
        return kept

    def _task(self, kept: dict, t_ms: float) -> None:
        pid, rev, status = kept.get("delegation_id"), kept.get("revision"), kept.get("status")
        if not isinstance(pid, str) or not isinstance(rev, int):
            return
        if status == "running":
            self.running_at.append(t_ms)
        if pid not in self.tasks or rev >= self.tasks[pid][0]:
            self.tasks[pid] = (rev, status)

    def in_flight(self) -> list[str]:
        return sorted(pid for pid, (_rev, status) in self.tasks.items()
                      if status not in TERMINAL_STATUSES)


def drive(fermix_home: str, plan: Plan, timeout_s: float) -> Evidence:
    """Run one call: handshake, `call_start`, the clips at real-time pace with
    the speaker acknowledging, `call_stop` once settled. Never raises for the
    socket: a failure is evidence with `ok=False`. The call is ended on every
    path once it was started, and the connection is closed on return."""
    started_at = datetime.now(timezone.utc)
    origin = time.monotonic()
    deadline = origin + timeout_s
    call, mic = _Call(), _Mic(plan)
    evidence = Evidence(False, None, started_at)
    try:
        conn = Connection(socket_path(fermix_home), timeout_s)
    except VoiceError as exc:
        evidence.error = str(exc)
        return evidence
    sink = PlaybackSink(0.0)
    started = False
    try:
        _hello(conn, min(deadline, time.monotonic() + HELLO_WAIT_S))
        conn.send({"type": "call_start"})
        started = True
        origin = time.monotonic()
        settled_ms = _converse(conn, plan, call, mic, sink, origin, deadline, evidence)
        evidence.ok, evidence.elapsed_ms = True, settled_ms
    except VoiceError as exc:
        evidence.error = _with_last_error(str(exc), call)
    finally:
        if started:
            _hang_up(conn, call, sink, origin, evidence)
        conn.close()
        evidence.frames, evidence.clips = call.frames, mic.played
        evidence.abandoned = mic.abandoned
    return evidence


def _hello(conn: Connection, deadline: float) -> None:
    conn.send({"type": "client_hello", "protocol_version": PROTOCOL_VERSION})
    reply = conn.recv(deadline)
    if reply is None or reply.get("type") != "server_hello":
        raise VoiceError(f"handshake refused: {reply!r}")


def _ms(origin: float) -> float:
    return (time.monotonic() - origin) * 1000.0


def _converse(conn: Connection, plan: Plan, call: _Call, mic: _Mic, sink: PlaybackSink,
              origin: float, deadline: float, evidence: Evidence) -> float:
    """Stream until the call settles; the milliseconds it took. Raises
    VoiceError past a bound."""
    _await_listening(conn, call, origin, deadline)
    next_chunk = time.monotonic()
    while True:
        now = time.monotonic()
        if now >= deadline:
            raise VoiceError(f"the call did not settle within {deadline - origin:.0f}s "
                             f"({_pending(call, mic, sink)})")
        if call.ready_at_ms is None and now - origin > READY_WAIT_S:
            raise VoiceError(f"no call_ready within {READY_WAIT_S:.0f}s of call_start")
        for _ in range(_MAX_CATCH_UP):
            if now < next_chunk:
                break
            pcm = mic.chunk((next_chunk - origin) * 1000.0, call)
            conn.send({"type": "audio_chunk", "audio": base64.b64encode(pcm).decode("ascii")})
            next_chunk += CHUNK_MS / 1000.0
        _send_reports(conn, sink.tick(_ms(origin)), evidence)
        if _settled(call, mic, sink, plan, _ms(origin)):
            return _ms(origin)
        frame = conn.recv(min(next_chunk, time.monotonic() + _TICK_S, deadline))
        if frame is not None:
            _take(conn, call, sink, frame, _ms(origin), evidence)


def _await_listening(conn: Connection, call: _Call, origin: float, deadline: float) -> None:
    """The daemon accepted the call; until then the microphone stays closed."""
    until = min(deadline, origin + READY_WAIT_S)
    while not call.listening:
        frame = conn.recv(until)
        if frame is None or time.monotonic() >= until:
            raise VoiceError(f"the call was not accepted within {READY_WAIT_S:.0f}s")
        call.take(frame, _ms(origin))
        if frame.get("type") == "error":
            raise VoiceError("call_start refused")


def _take(conn: Connection, call: _Call, sink: PlaybackSink, frame: dict, now_ms: float,
          evidence: Evidence) -> None:
    kept = call.take(frame, now_ms)
    if kept["type"] == "audio_delta" and "playback_id" in kept:
        _send_reports(conn, sink.receive(kept["playback_id"], kept["bytes"], now_ms), evidence)
    elif kept["type"] == "playback_stop":
        _send_reports(conn, sink.stop(now_ms), evidence)


def _send_reports(conn: Connection, reports: list[dict], evidence: Evidence) -> None:
    for report in reports:
        conn.send(report)
        evidence.reports_sent += 1


def _settled(call: _Call, mic: _Mic, sink: PlaybackSink, plan: Plan, now_ms: float) -> bool:
    if call.ready_at_ms is None or not mic.done() or call.in_flight() or not sink.idle():
        return False
    quiet_since = max(call.last_activity_ms, mic.last_end() or 0.0, call.ready_at_ms)
    return now_ms - quiet_since >= plan.quiet_ms


def _pending(call: _Call, mic: _Mic, sink: PlaybackSink) -> str:
    parts = []
    if call.ready_at_ms is None:
        parts.append("no call_ready")
    if not mic.done():
        parts.append(f"clips said {len(mic.played)}")
    if call.in_flight():
        parts.append(f"tasks in flight {call.in_flight()}")
    if not sink.idle():
        parts.append("assistant audio still playing")
    return ", ".join(parts) or "never quiet"


def _hang_up(conn: Connection, call: _Call, sink: PlaybackSink, origin: float,
             evidence: Evidence) -> None:
    """`call_stop`, then what the call says as it ends — a detached task, the
    final usage — until that usage, the bound, or the connection closing."""
    try:
        conn.send({"type": "call_stop"})
        until = time.monotonic() + CLOSE_WAIT_S
        while not call.final_usage and time.monotonic() < until:
            frame = conn.recv(min(until, time.monotonic() + _TICK_S))
            if frame is not None:
                _take(conn, call, sink, frame, _ms(origin), evidence)
            _send_reports(conn, sink.tick(_ms(origin)), evidence)
    except VoiceError:
        return  # the connection closed as the call ended: what arrived is kept


def _with_last_error(message: str, call: _Call) -> str:
    errors = [frame for frame in call.frames if frame["type"] == "error"]
    if not errors:
        return message
    last = errors[-1]
    said = ", ".join(f"{key}={last[key]}" for key in ("reason", "kind", "required_for", "detail")
                     if key in last)
    return f"{message}; the daemon said error({said})"


# --- the trace ----------------------------------------------------------------

def find_call_trace(client, call_id: str, provider_session_id: str | None,
                    after: datetime | None) -> dict | None:
    """The one trace this call rooted: named for the call id, started at or
    after `after`, and carrying the call's provider session id when the trace
    says one. The `voice_live:<n>` counter restarts with the daemon, so the
    start bound and the provider session are what keep an earlier VM's call of
    the same number out."""
    if not call_id:
        raise ValueError("call_id must be non-empty")
    # The lookup lives with the driver because the call's root is found by its
    # name, not by a thread; `_filtered_traces` already bounds and pages it.
    filters = [{"field": "name", "operator": "=", "value": call_id}]
    candidates = []
    for trace in client._filtered_traces(filters, after):
        if trace.get("name") != call_id:
            continue
        started = parse_ts(trace.get("start_time"))
        if after is not None and (started is None or started < after):
            continue
        stamped = (trace.get("metadata") or {}).get("provider_session_id")
        if provider_session_id and stamped not in (None, provider_session_id):
            continue
        candidates.append(trace)
    return candidates[0] if len(candidates) == 1 else None


def poll_call_trace(client, call_id: str, provider_session_id: str | None,
                    after: datetime | None, timeout_s: float, interval_s: float) -> dict | None:
    """Block until the call's trace appears in Opik, or None at the timeout."""
    if timeout_s < 0 or interval_s <= 0:
        raise ValueError("timeout_s must be non-negative and interval_s must be positive")
    deadline = time.monotonic() + timeout_s
    while True:
        hit = find_call_trace(client, call_id, provider_session_id, after)
        if hit is not None:
            return hit
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        time.sleep(min(interval_s, remaining))


def trace_window_start(evidence: Evidence) -> datetime:
    return evidence.started_at - timedelta(seconds=10)


# --- what the judge reads -----------------------------------------------------

def transcript(evidence: Evidence, spoken: list[str]) -> list[dict]:
    """The call in order: each clip the owner said (its fixture text) and the
    voice's captions between them, consecutive captions merged."""
    events = [(clip["start_ms"], "user", spoken[index])
              for index, clip in enumerate(evidence.clips) if index < len(spoken)]
    events += [(frame["t_ms"], "assistant", frame.get("delta", ""))
               for frame in evidence.of("caption") if frame.get("speaker") == "assistant"]
    out: list[dict] = []
    for _t, role, text in sorted(events, key=lambda item: item[0]):
        if out and out[-1]["role"] == role == "assistant":
            out[-1]["content"] += text
        else:
            out.append({"role": role, "content": text})
    return out


def judge_evidence(evidence: Evidence) -> dict:
    """The call's timeline as the judge's evidence: when each clip was said,
    what the voice model heard and said, and every task frame."""
    timeline = [{"t_ms": clip["start_ms"], "owner_said_clip": clip["say"]}
                for clip in evidence.clips]
    for frame in evidence.frames:
        if frame["type"] == "caption":
            timeline.append({"t_ms": frame["t_ms"], "caption": frame.get("speaker"),
                             "text": frame.get("delta", "")})
        elif frame["type"] == "task":
            timeline.append({"t_ms": frame["t_ms"], "task": frame.get("delegation_id"),
                             "revision": frame.get("revision"), "status": frame.get("status"),
                             "summary": frame.get("summary")})
    timeline.sort(key=lambda item: item["t_ms"])
    outcomes = [{"task": key[0], "revision": key[1], "ended": status}
                for key, status in evidence.task_outcomes().items()]
    return {"voice_call": {"engine": evidence.call_ready().get("engine"),
                           "timeline": timeline, "task_revisions": outcomes}}
