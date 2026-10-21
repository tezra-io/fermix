#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8.4", "pyyaml>=6,<7", "certifi", "anthropic>=1.13,<2"]
# ///
"""Specs for `drive: voice`: the suite keys and fixture checks, the simulated
speaker's acknowledgement cadence, the wire gates on recorded frame lists (each
one failing on the broken list it exists for), the call client against a
scripted stand-in daemon, selection behind --voice, and the runner's grading.
Pure: a local Unix socket in a temp dir, generated WAVs, no daemon, no Opik,
no spend. Run: `uv run bin/test_voice.py`."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import random
import shutil
import socket
import sys
import tempfile
import threading
import time
import wave
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402
import yaml  # noqa: E402

import make_voice_fixtures  # noqa: E402
import run_eval  # noqa: E402
from evallib import suites, voice  # noqa: E402

BENCH = os.path.dirname(HERE)
SUITES_DIR = os.path.join(BENCH, "suites")
REPO = os.path.dirname(BENCH)
CLIENT_FIXTURES = os.path.join(REPO, "apps", "fermix_core", "priv", "realtime", "fixtures",
                               "client_events.jsonl")


# --- fixtures in a temp suites dir ---------------------------------------------

def _wav(path, seconds=0.2, rate=voice.SAMPLE_RATE, channels=1):
    frames = int(rate * seconds)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(channels)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(b"\x01\x00" * frames * channels)


def _fixtures(tmp_path, clips=None):
    """`<tmp>/fixtures/voice/` with a manifest over generated WAVs."""
    clips = clips or {"ask": "Who is on intake?", "more": "And the van?"}
    root = tmp_path / "fixtures" / "voice"
    root.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for key, text in clips.items():
        _wav(root / f"{key}.wav")
        digest = hashlib.sha256((root / f"{key}.wav").read_bytes()).hexdigest()
        manifest[key] = {"file": f"{key}.wav", "text": text, "sha256": digest,
                         "duration_ms": 200}
    (root / "manifest.json").write_text(json.dumps({"clips": manifest}))
    return root


_WIRE = {"engine": "xai_realtime", "task_statuses_all": ["completed"]}


def _case(cid, **extra):
    case = {"id": cid, "drive": "voice", "voice": {"clips": [{"say": "ask"}]},
            "expect": {"wire": dict(_WIRE)}}
    case.update(extra)
    return case


def _load(tmp_path, cases, risk="host_readonly"):
    doc = {"suite": "spec_voice", "title": "Spec", "risk": risk,
           "scenarios": [{"id": "scn", "title": "Scenario", "cases": cases}]}
    (tmp_path / "spec.yaml").write_text(yaml.safe_dump(doc))
    return suites.load_all(str(tmp_path))


def _problems(tmp_path, cases):
    with pytest.raises(suites.SuiteError) as exc:
        _load(tmp_path, cases)
    return exc.value.problems


# --- the suite keys -------------------------------------------------------------

def test_a_voice_case_loads_with_its_clips_as_its_one_turn(tmp_path):
    _fixtures(tmp_path)
    cases = [_case("a", voice={"clips": [{"say": "ask"},
                                         {"say": "more", "after": "task_running",
                                          "gap_ms": 2500}], "quiet_ms": 3000}),
             _case("b")]

    case = _load(tmp_path, cases)[0].scenarios[0].cases[0]

    assert case.drive == "voice" and case.needs_voice and not case.needs_operator
    assert [turn.query for turn in case.turns] == ["Who is on intake?\nAnd the van?"]
    assert case.voice["quiet_ms"] == 3000
    assert case.expect["wire"] == _WIRE


@pytest.mark.parametrize("override, fragment", [
    ({"query": "hello"}, "drop `query` and `turns`"),
    ({"turns": [{"query": "hello"}]}, "drop `query` and `turns`"),
    ({"voice": None}, "`voice` must be a map"),
    ({"voice": {"clips": []}}, "`voice.clips` must be a list of 1..4"),
    ({"voice": {"clips": [{"say": "ask"}] * 5}}, "`voice.clips` must be a list of 1..4"),
    ({"voice": {"clips": [{"say": "ask"}], "loud": True}}, "unknown `voice` key `loud`"),
    ({"voice": {"clips": [{"say": "ask"}], "quiet_ms": 50}}, "`voice.quiet_ms` must be"),
    ({"voice": {"clips": [{"say": "nobody"}]}}, "`say` must name a clip"),
    ({"voice": {"clips": ["ask"]}}, "must be a map with `say`"),
    ({"voice": {"clips": [{"say": "ask", "after": "task_running"}]}},
     "the first clip opens the call"),
    ({"voice": {"clips": [{"say": "ask"}, {"say": "more", "after": "later"}]}},
     "`after` must be one of"),
    ({"voice": {"clips": [{"say": "ask", "gap_ms": -1}]}}, "`gap_ms` must be an integer"),
    ({"voice": {"clips": [{"say": "ask", "volume": 3}]}}, "unknown clip key `volume`"),
    ({"expect": {"status": "ok"}}, "needs an expect `wire` map"),
    ({"image": "x.png"}, "attachments do not travel on the voice socket"),
])
def test_a_malformed_voice_case_is_named(tmp_path, override, fragment):
    _fixtures(tmp_path)
    problems = _problems(tmp_path, [_case("a", **override), _case("b")])
    assert any(fragment in p for p in problems), problems


def test_a_voice_case_without_its_voice_map_is_named(tmp_path):
    _fixtures(tmp_path)
    broken = _case("a")
    del broken["voice"]
    problems = _problems(tmp_path, [broken, _case("b")])
    assert any("needs a `voice` map" in p for p in problems), problems


@pytest.mark.parametrize("wire, fragment", [
    ({"loudness": 1}, "unknown `wire` key `loudness`"),
    ({"engine": ""}, "`wire.engine` must be a non-empty string"),
    ({"events_all": ["transcript"]}, "`wire.events_all` must be a non-empty list"),
    ({"events_none": []}, "`wire.events_none` must be a non-empty list"),
    ({"task_statuses_all": ["done"]}, "`wire.task_statuses_all` must be a non-empty list"),
    ({"task_statuses_none": "failed"}, "`wire.task_statuses_none` must be a non-empty list"),
    ({"caption_not_matches": "("}, "`wire.caption_not_matches` is not a valid regex"),
    ({"caption_not_matches": ""}, "`wire.caption_not_matches` must be a non-empty regex"),
    ({"max_tasks": 0}, "`wire.max_tasks` must be a positive integer"),
    ({"max_tasks": True}, "`wire.max_tasks` must be a positive integer"),
    ({"task_terminal_once": False}, "`wire.task_terminal_once` must be true"),
    ({"spoke_while_task_running": "yes"}, "`wire.spoke_while_task_running` must be true"),
])
def test_a_malformed_voice_wire_map_is_named(tmp_path, wire, fragment):
    _fixtures(tmp_path)
    problems = _problems(tmp_path, [_case("a", expect={"wire": wire}), _case("b")])
    assert any(fragment in p for p in problems), problems


def test_voice_keys_are_refused_off_the_voice_drive(tmp_path):
    _fixtures(tmp_path)
    cases = [{"id": "a", "query": "hello", "voice": {"clips": [{"say": "ask"}]},
              "expect": {"wire": {"engine": "xai_realtime"}}},
             {"id": "b", "query": "hello"}]

    problems = _problems(tmp_path, cases)

    assert any("`voice` needs `drive: voice`" in p for p in problems)
    assert any("expect `wire` needs `drive: companion` or `drive: voice`" in p
               for p in problems)


def test_a_wav_edited_after_its_manifest_fails_validation(tmp_path):
    root = _fixtures(tmp_path)
    _wav(root / "ask.wav", seconds=0.3)

    problems = _problems(tmp_path, [_case("a"), _case("b")])

    assert any("does not match its manifest sha256" in p for p in problems), problems


def test_a_wav_the_socket_cannot_carry_fails_validation(tmp_path):
    root = _fixtures(tmp_path)
    _wav(root / "ask.wav", rate=16_000)
    manifest = json.loads((root / "manifest.json").read_text())
    manifest["clips"]["ask"]["sha256"] = hashlib.sha256(
        (root / "ask.wav").read_bytes()).hexdigest()
    (root / "manifest.json").write_text(json.dumps(manifest))

    problems = _problems(tmp_path, [_case("a"), _case("b")])

    assert any("the socket carries 24000 Hz mono 16-bit" in p for p in problems), problems


def test_a_missing_manifest_fails_validation(tmp_path):
    problems = _problems(tmp_path, [_case("a"), _case("b")])
    assert any("cannot read the voice fixture manifest" in p for p in problems), problems


def test_a_manifest_file_outside_its_folder_is_refused(tmp_path):
    root = _fixtures(tmp_path)
    manifest = json.loads((root / "manifest.json").read_text())
    manifest["clips"]["ask"]["file"] = "../ask.wav"
    (root / "manifest.json").write_text(json.dumps(manifest))

    problems = _problems(tmp_path, [_case("a"), _case("b")])

    assert any("must name a .wav beside the manifest" in p for p in problems), problems


# --- the shipped suite and fixtures --------------------------------------------

def _shipped():
    return next(s for s in suites.load_all(SUITES_DIR) if s.name == "grok_voice")


def test_the_shipped_voice_suite_loads_with_explicit_risks_and_one_sanity_route():
    suite = _shipped()
    with open(suite.path, encoding="utf-8") as handle:
        raw = yaml.safe_load(handle)
    # Every scenario states its risk, and only the two the design allows.
    assert all(scenario.get("risk") in ("host_readonly", "isolated_mutation")
               for scenario in raw["scenarios"])
    cases = [case for scenario in suite.scenarios for case in scenario.cases]
    assert cases and all(case.drive == "voice" for case in cases)
    assert all(case.expect["wire"]["engine"] == "xai_realtime" for case in cases)
    assert all(case.rubric for case in cases)
    # Route assertions: exactly one labelled sanity case asserts the bridge call.
    routed = [case.id for case in cases if case.expect.get("tools_any")]
    assert routed == ["intake_on_the_thirteenth"]
    assert _shipped().scenarios[0].cases[0].expect["tools_any"] == ["fermix_task"]
    assert all(not scenario.sticky_gates for scenario in suite.scenarios)


def test_the_shipped_manifest_says_what_the_generator_says():
    manifest, error = voice.load_manifest(os.path.join(SUITES_DIR, "fixtures"))
    assert error is None
    assert {key: entry["text"] for key, entry in manifest.items()} == make_voice_fixtures.CLIPS
    for key, entry in manifest.items():
        assert voice.clip_problem(os.path.join(SUITES_DIR, "fixtures"), key, entry) is None


def test_the_correction_and_cancel_cases_forbid_only_the_other_dates_shelves():
    # The material a leak check names must be what the superseded or cancelled
    # run would have printed, never what the completed run legitimately says.
    rows = {}
    with open(os.path.join(SUITES_DIR, "fixtures", "voice", "stocktake.tsv"),
              encoding="utf-8") as handle:
        for line in handle.read().splitlines()[1:]:
            day, _item, _count, shelf = line.split("\t")
            rows.setdefault(day, set()).add(shelf.lower())
    by_case = {case.id: case for scenario in _shipped().scenarios for case in scenario.cases}
    forbidden = {"thirteenth_corrected_to_twentieth": "2027-03-13",
                 "twentieth_corrected_to_thirteenth": "2027-03-20",
                 "never_mind_cancel": "2027-03-13", "stop_the_stocktake": "2027-03-20"}
    for case_id, day in forbidden.items():
        pattern = by_case[case_id].expect["wire"]["caption_not_matches"]
        assert set(pattern.removeprefix("(?i)").split("|")) == rows[day], case_id


# --- the simulated speaker -------------------------------------------------------

def _play(sink, until_ms, step_ms=10, start_ms=0):
    reports = []
    t = start_ms
    while t <= until_ms:
        reports += [(t, r) for r in sink.tick(t)]
        t += step_ms
    return reports


def test_the_speaker_reports_at_most_every_100ms_and_at_once_on_drain():
    sink = voice.PlaybackSink(0)
    sink.receive("p1", 1_000 * voice.BYTES_PER_MS, 0)

    reports = _play(sink, 1_200)

    progress = [t for t, r in reports if not r["drained"]]
    assert progress and all(b - a >= voice.REPORT_EVERY_MS for a, b in zip(progress, progress[1:]))
    drained = [(t, r) for t, r in reports if r["drained"]]
    assert drained == [(1_000, {"type": "playback_progress", "playback_id": "p1",
                                "played_ms": 1_000, "drained": True})]
    played = [r["played_ms"] for _t, r in reports]
    assert played == sorted(played) and max(played) == 1_000
    assert sink.idle()


def test_the_speaker_plays_ids_in_arrival_order():
    sink = voice.PlaybackSink(0)
    sink.receive("p1", 300 * voice.BYTES_PER_MS, 0)
    sink.receive("p2", 200 * voice.BYTES_PER_MS, 0)

    reports = _play(sink, 600)

    first_p2 = min(t for t, r in reports if r["playback_id"] == "p2")
    p1_drained = next(t for t, r in reports if r["playback_id"] == "p1" and r["drained"])
    assert p1_drained == 300 and first_p2 >= p1_drained
    assert [r for _t, r in reports if r["drained"]][-1] == {
        "type": "playback_progress", "playback_id": "p2", "played_ms": 200, "drained": True}


def test_a_playback_stop_cuts_the_audio_and_reports_at_once():
    sink = voice.PlaybackSink(0)
    sink.receive("p1", 1_000 * voice.BYTES_PER_MS, 0)
    _play(sink, 400)

    reports = sink.stop(400)

    assert reports == [{"type": "playback_progress", "playback_id": "p1", "played_ms": 400,
                        "drained": False}]
    assert sink.idle() and _play(sink, 1_000, start_ms=410) == []


def test_audio_resumed_under_a_drained_id_drains_again():
    sink = voice.PlaybackSink(0)
    sink.receive("p1", 100 * voice.BYTES_PER_MS, 0)
    _play(sink, 150)
    sink.receive("p1", 100 * voice.BYTES_PER_MS, 200)

    reports = _play(sink, 400, start_ms=200)

    assert [r["played_ms"] for _t, r in reports if r["drained"]] == [200]


def test_the_speaker_never_reports_more_than_it_was_sent():
    rng = random.Random(7)
    sink = voice.PlaybackSink(0)
    sent = {"p1": 0, "p2": 0}
    last = {"p1": 0, "p2": 0}
    for t in range(0, 3_000, 7):
        if rng.random() < 0.2:
            pid = rng.choice(["p1", "p2"])
            size = rng.randrange(1, 200) * 2
            sent[pid] += size
            reports = sink.receive(pid, size, t)
        else:
            reports = sink.tick(t)
        for report in reports:
            pid = report["playback_id"]
            assert last[pid] <= report["played_ms"] <= sent[pid] // voice.BYTES_PER_MS
            last[pid] = report["played_ms"]


# --- the wire gates, on recorded frame lists -------------------------------------

def _evidence(frames, clips=({"say": "ask", "start_ms": 100.0, "end_ms": 2_000.0},)):
    timed = [dict(frame, t_ms=frame.get("t_ms", 1_000.0 + 10 * i))
             for i, frame in enumerate(frames)]
    return voice.Evidence(True, None, run_eval.now_utc(), 5_000.0, timed, list(clips))


def _good():
    return [{"type": "state", "state": "listening", "t_ms": 5},
            {"type": "call_ready", "engine": "xai_realtime", "call_id": "voice_live:3",
             "t_ms": 50},
            {"type": "task", "delegation_id": "d1", "revision": 1, "status": "running",
             "t_ms": 2_500},
            {"type": "caption", "speaker": "assistant", "delta": "Lentils work well.",
             "t_ms": 3_000},
            {"type": "audio_delta", "playback_id": "p1", "bytes": 4_800, "t_ms": 3_100},
            {"type": "task", "delegation_id": "d1", "revision": 1, "status": "completed",
             "summary": "Shelf Kestrel.", "t_ms": 9_000},
            {"type": "caption", "speaker": "assistant", "delta": " Chickpeas: shelf Kestrel.",
             "t_ms": 9_500}]


_EVERY_KEY = {"engine": "xai_realtime", "events_all": ["call_ready", "task", "caption"],
              "events_none": ["error"], "task_statuses_all": ["completed"],
              "task_statuses_none": ["failed", "cancelled", "superseded"],
              "caption_not_matches": "(?i)osprey", "max_tasks": 1,
              "task_terminal_once": True, "spoke_while_task_running": True}


def test_every_wire_gate_passes_on_the_evidence_it_describes():
    gates = voice.wire_gates(_evidence(_good()), _EVERY_KEY)

    assert [g.key for g in gates] == [
        "wire.engine", "wire.events_all", "wire.events_none", "wire.task_statuses_all",
        "wire.task_statuses_none", "wire.caption_not_matches", "wire.max_tasks",
        "wire.task_terminal_once", "wire.spoke_while_task_running"]
    assert all(g.passed for g in gates), [g.detail for g in gates if not g.passed]


def _broken(key):
    frames = _good()
    if key == "engine":
        frames[1]["engine"] = "openai_live"
    elif key == "events_all":
        frames = [f for f in frames if f["type"] != "caption"]
    elif key == "events_none":
        frames.append({"type": "error", "reason": "playback_stalled"})
    elif key == "task_statuses_all":
        frames[5]["status"] = "cancelled"
    elif key == "task_statuses_none":
        frames.append({"type": "task", "delegation_id": "d2", "revision": 1, "status": "failed"})
    elif key == "caption_not_matches":
        frames.append({"type": "caption", "speaker": "assistant", "delta": " Osprey too."})
    elif key == "max_tasks":
        frames.append({"type": "task", "delegation_id": "d2", "revision": 1,
                       "status": "completed"})
    elif key == "task_terminal_once":
        frames.append(dict(frames[5], t_ms=9_900))
    elif key == "spoke_while_task_running":
        frames = [f for f in frames if not (f["type"] == "caption" and f["t_ms"] < 9_000)]
    return frames


@pytest.mark.parametrize("key", sorted(_EVERY_KEY))
def test_each_wire_gate_fails_on_the_broken_list_it_exists_for(key):
    gates = {g.key: g for g in voice.wire_gates(_evidence(_broken(key)), _EVERY_KEY)}

    assert not gates[f"wire.{key}"].passed, gates[f"wire.{key}"].detail
    # Each broken list breaks its own gate; the engine one breaks nothing else.
    if key == "engine":
        assert [k for k, g in gates.items() if not g.passed] == ["wire.engine"]


def test_a_cancelled_revision_a_newer_one_replaced_reads_superseded():
    frames = [{"type": "task", "delegation_id": "d1", "revision": 1, "status": "running"},
              {"type": "task", "delegation_id": "d1", "revision": 1, "status": "cancelled"},
              {"type": "task", "delegation_id": "d1", "revision": 2, "status": "running"},
              {"type": "task", "delegation_id": "d1", "revision": 2, "status": "completed"}]
    wire = {"task_statuses_all": ["superseded", "completed"], "max_tasks": 1,
            "task_terminal_once": True}

    assert _evidence(frames).task_outcomes() == {("d1", 1): "superseded",
                                                 ("d1", 2): "completed"}
    assert all(g.passed for g in voice.wire_gates(_evidence(frames), wire))
    # A lone cancel is a cancel, never a supersede.
    lone = frames[:2]
    gates = {g.key: g for g in voice.wire_gates(_evidence(lone), {"task_statuses_all":
                                                                   ["superseded"]})}
    assert not gates["wire.task_statuses_all"].passed


def test_a_task_completed_in_two_revisions_completed_twice():
    frames = [{"type": "task", "delegation_id": "d1", "revision": 1, "status": "completed"},
              {"type": "task", "delegation_id": "d1", "revision": 2, "status": "completed"}]

    (gate,) = voice.wire_gates(_evidence(frames), {"task_terminal_once": True})

    assert not gate.passed and "tasks completed twice=['d1']" in gate.detail


def test_caption_leak_checks_read_only_what_the_voice_said():
    frames = _good() + [{"type": "caption", "speaker": "user", "delta": "Osprey?"}]

    (gate,) = voice.wire_gates(_evidence(frames), {"caption_not_matches": "(?i)osprey"})

    assert gate.passed


def test_speaking_before_the_last_clip_ended_is_not_speaking_while_the_task_ran():
    frames = _good()
    clips = ({"say": "ask", "start_ms": 100.0, "end_ms": 2_000.0},
             {"say": "more", "start_ms": 3_500.0, "end_ms": 5_000.0})
    frames = [f for f in frames if not (f["type"] == "caption" and f["t_ms"] >= 9_000)]

    (gate,) = voice.wire_gates(_evidence(frames, clips), {"spoke_while_task_running": True})

    assert not gate.passed


def test_the_recorded_audio_is_its_size_alone():
    kept = voice.record({"type": "audio_delta", "playback_id": "p1",
                         "audio": base64.b64encode(b"\x01\x00" * 480).decode()}, 12.34)
    assert kept == {"t_ms": 12.3, "type": "audio_delta", "bytes": 960, "playback_id": "p1"}
    silent = voice.record({"type": "audio_delta",
                           "audio": base64.b64encode(bytes(960)).decode()}, 1.0)
    assert silent == {"t_ms": 1.0, "type": "audio_delta", "bytes": 960, "silent": True}
    assert voice.record({"type": "surprise", "x": 1}, 1.0) == {"t_ms": 1.0, "type": "surprise"}


# --- the call client, against a scripted stand-in daemon ---------------------------

class FakeVoiceDaemon:
    """Speaks the voice wire from a script, one connection.

    It hears the microphone the way a provider's turn detection would: a run of
    non-silent chunks is an utterance, and the first silent chunk after one ends
    it. What it says when each utterance ends depends on `mode`; a running task
    completes `complete_after` chunks (100 ms each) after the last utterance."""

    def __init__(self, mode="answer", complete_after=8):
        self.home = tempfile.mkdtemp(prefix="vx")
        self.path = voice.socket_path(self.home)
        self.mode = mode
        self.complete_after = complete_after
        self.received: list[dict] = []
        self.utterances: list[int] = []         # chunk index each utterance began at
        self.running_sent_at: int | None = None
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(1)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def close(self):
        self.server.close()
        shutil.rmtree(self.home, ignore_errors=True)

    def sent(self, kind):
        return [frame for frame in self.received if frame["type"] == kind]

    def _serve(self):
        try:
            conn, _ = self.server.accept()
        except OSError:
            return
        self.conn, self.buffer, self.chunks, self.speaking = conn, b"", 0, False
        self.countdown = None
        try:
            self._loop()
        except (OSError, ValueError):
            pass
        finally:
            conn.close()

    def _loop(self):
        while True:
            chunk = self.conn.recv(65536)
            if not chunk:
                return
            self.buffer += chunk
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                frame = json.loads(line)
                self.received.append(frame)
                if self._on(frame) == "close":
                    return

    def send(self, frame):
        self.conn.sendall(json.dumps(frame).encode() + b"\n")

    def audio(self, pid, ms):
        pcm = b"\x01\x00" * (voice.BYTES_PER_MS * ms // 2)
        self.send({"type": "audio_delta", "playback_id": pid,
                   "audio": base64.b64encode(pcm).decode()})

    def task(self, status, revision=1):
        self.send({"type": "task", "delegation_id": "d1", "revision": revision,
                   "status": status})
        if status == "running" and self.running_sent_at is None:
            self.running_sent_at = self.chunks

    def _on(self, frame):
        kind = frame["type"]
        if kind == "client_hello":
            self.send({"type": "server_hello", "min_version": 1, "max_version": 3})
        elif kind == "call_start" and self.mode == "refuse":
            self.send({"type": "error", "reason": "call_in_progress"})
            return "close"
        elif kind == "call_start":
            self.send({"type": "state", "state": "listening"})
            self.send({"type": "call_ready", "engine": "xai_realtime", "call_id": "voice_live:7",
                       "call_uuid": "u-7", "conversation": "chat", "tasks_outlive_call": True,
                       "provider_session_id": "sess_7", "captions": True})
        elif kind == "audio_chunk":
            return self._heard(base64.b64decode(frame["audio"]))
        elif kind == "call_stop":
            self.send({"type": "state", "state": "idle"})
            self.send({"type": "usage", "status": "live", "accounting": "incomplete"})
        return None

    def _heard(self, pcm):
        self.chunks += 1
        if self.mode == "hangup" and self.chunks == 3:
            return "close"
        if self.mode == "live_silence":
            # GPT-Live's output never stops: digital silence between replies.
            self.send({"type": "audio_delta", "audio": base64.b64encode(bytes(4_800)).decode()})
        if any(pcm) and not self.speaking:
            self.speaking = True
            self.utterances.append(self.chunks)
        elif not any(pcm) and self.speaking:
            self.speaking = False
            self._utterance_ended(len(self.utterances))
        if self.countdown is not None:
            self.countdown -= 1
            if self.countdown == 0:
                self._complete()
        return None

    def _utterance_ended(self, n):
        if n == 1:
            self.task("running")
            self.audio("p1", 300)
            self.send({"type": "caption", "speaker": "assistant", "delta": "On it."})
            if self.mode in ("answer", "live_silence"):
                self.countdown = self.complete_after
        elif n == 2 and self.mode == "pending":
            self.audio("p2", 200)
            self.send({"type": "caption", "speaker": "assistant", "delta": " Try lentils."})
            self.countdown = self.complete_after
        elif n == 2 and self.mode == "correct":
            self.task("cancelled", revision=1)
            self.task("running", revision=2)
            self.countdown = self.complete_after

    def _complete(self):
        revision = 2 if self.mode == "correct" else 1
        self.task("completed", revision=revision)
        self.audio("p3", 200)
        self.send({"type": "caption", "speaker": "assistant", "delta": " Shelf Kestrel."})


@pytest.fixture
def daemon():
    made = []

    def start(**kwargs):
        fake = FakeVoiceDaemon(**kwargs)
        made.append(fake)
        return fake

    yield start
    for fake in made:
        fake.close()


_TONE = b"\x01\x00" * (voice.SAMPLE_RATE * 3 // 10)        # 300 ms of non-silent PCM


def _plan(*afters):
    clips = [voice.Clip("ask", _TONE, gap_ms=100)]
    clips += [voice.Clip(f"more{n}", _TONE, gap_ms=300, after=after)
              for n, after in enumerate(afters)]
    return voice.Plan(tuple(clips), quiet_ms=1_000)


def test_a_call_is_driven_until_it_settles_and_then_hung_up(daemon):
    fake = daemon(mode="answer")

    evidence = voice.drive(fake.home, _plan(), timeout_s=30)

    assert evidence.ok, evidence.error
    assert evidence.call_id() == "voice_live:7" and evidence.provider_session_id() == "sess_7"
    assert evidence.task_outcomes() == {("d1", 1): "completed"}
    assert evidence.spoken() == "On it. Shelf Kestrel."
    assert [c["say"] for c in evidence.clips] == ["ask"]
    kinds = [frame["type"] for frame in fake.received]
    assert kinds[:2] == ["client_hello", "call_start"] and kinds[-1] == "call_stop"
    assert fake.sent("client_hello")[0]["protocol_version"] == 3
    # Every chunk is 100 ms of 24 kHz mono PCM16.
    assert {len(base64.b64decode(f["audio"])) for f in fake.sent("audio_chunk")} == {4_800}
    # Every playback id was acknowledged to its end, never past what was sent.
    reports = fake.sent("playback_progress")
    sent_ms = {"p1": 300, "p3": 200}
    for pid, total in sent_ms.items():
        mine = [r["played_ms"] for r in reports if r["playback_id"] == pid]
        assert mine == sorted(mine) and max(mine) <= total
        assert any(r["playback_id"] == pid and r["drained"] and r["played_ms"] == total
                   for r in reports)
    assert evidence.summary()["playback_reports"] == len(reports)


def test_digital_silence_between_replies_does_not_hold_the_call_open(daemon):
    fake = daemon(mode="live_silence")

    evidence = voice.drive(fake.home, _plan(), timeout_s=30)

    assert evidence.ok, evidence.error
    assert sum(1 for f in evidence.frames if f.get("silent")) > 10


class _Chatty:
    """A connection with a frame always ready: what a daemon that never stops
    talking looks like to the client's loops."""

    def __init__(self, frame):
        self.frame, self.sent = frame, []

    def send(self, event):
        self.sent.append(event)

    def recv(self, _deadline):
        return dict(self.frame)


def _bounded(target):
    worker = threading.Thread(target=target, daemon=True)
    worker.start()
    worker.join(timeout=10)
    return not worker.is_alive()


def test_a_daemon_that_never_stops_talking_cannot_hold_the_hang_up_open(monkeypatch):
    monkeypatch.setattr(voice, "CLOSE_WAIT_S", 0.2)
    conn = _Chatty({"type": "audio_delta", "audio": base64.b64encode(bytes(960)).decode()})
    call = voice._Call()

    assert _bounded(lambda: voice._hang_up(conn, call, voice.PlaybackSink(0.0),
                                           time.monotonic(), voice.Evidence(True, None, None)))
    assert conn.sent[0] == {"type": "call_stop"}


def test_a_daemon_that_never_says_listening_cannot_hold_the_start_open(monkeypatch):
    monkeypatch.setattr(voice, "READY_WAIT_S", 0.2)
    conn = _Chatty({"type": "state", "state": "thinking"})
    raised = []

    def start():
        try:
            voice._await_listening(conn, voice._Call(), time.monotonic(),
                                   time.monotonic() + 60)
        except voice.VoiceError as exc:
            raised.append(str(exc))

    assert _bounded(start)
    assert raised == ["the call was not accepted within 0s"]


def test_the_clients_frames_are_the_vendored_protocol_shapes(daemon):
    fake = daemon(mode="answer")
    voice.drive(fake.home, _plan(), timeout_s=30)
    with open(CLIENT_FIXTURES, encoding="utf-8") as handle:
        vendored = {}
        for line in handle:
            frame = json.loads(line)
            vendored.setdefault(frame["type"], set()).add(frozenset(frame))

    for frame in fake.received:
        assert frozenset(frame) in vendored[frame["type"]], frame


def test_a_clip_after_task_running_waits_for_the_running_frame(daemon):
    fake = daemon(mode="pending")

    evidence = voice.drive(fake.home, _plan("task_running"), timeout_s=30)

    assert evidence.ok, evidence.error
    assert len(fake.utterances) == 2 and fake.utterances[1] > fake.running_sent_at
    gates = voice.wire_gates(evidence, {"spoke_while_task_running": True,
                                        "task_statuses_all": ["completed"]})
    assert all(g.passed for g in gates), [g.detail for g in gates]


def test_a_microphone_running_late_still_ends_each_clip_when_its_audio_ends(daemon, monkeypatch):
    # The loop wakes 150 ms late before the last clip's final chunk, as on a
    # busy runner, then catches up; the silence that ends the clip still goes
    # out on schedule, and the reply to it must not read as said mid-clip.
    real_chunk = voice._Mic.chunk
    stalled = []

    def chunk(mic, at_ms, call):
        pcm = real_chunk(mic, at_ms, call)
        last = len(mic._clips) - 1
        if (not stalled and mic._index == last and mic._offset is not None
                and len(mic._clips[last].pcm) - mic._offset <= voice.CHUNK_BYTES):
            stalled.append(at_ms)
            time.sleep(0.15)
        return pcm

    monkeypatch.setattr(voice._Mic, "chunk", chunk)
    fake = daemon(mode="pending")

    evidence = voice.drive(fake.home, _plan("task_running"), timeout_s=30)

    assert evidence.ok, evidence.error
    assert stalled, "the stall never ran"
    gates = voice.wire_gates(evidence, {"spoke_while_task_running": True})
    assert all(g.passed for g in gates), [g.detail for g in gates]


def test_a_spoken_correction_reads_superseded_then_completed(daemon):
    fake = daemon(mode="correct")

    evidence = voice.drive(fake.home, _plan("task_running"), timeout_s=30)

    assert evidence.ok, evidence.error
    assert evidence.task_outcomes() == {("d1", 1): "superseded", ("d1", 2): "completed"}


def test_a_refused_call_start_is_evidence_naming_the_reason(daemon):
    evidence = voice.drive(daemon(mode="refuse").home, _plan(), timeout_s=10)

    assert not evidence.ok
    assert "call_in_progress" in evidence.error


def test_a_daemon_that_closes_mid_call_is_evidence_not_an_exception(daemon):
    evidence = voice.drive(daemon(mode="hangup").home, _plan(), timeout_s=10)

    assert not evidence.ok
    assert "closed the connection" in evidence.error


def test_a_call_that_never_settles_is_ended_at_its_bound(daemon):
    fake = daemon(mode="never")

    evidence = voice.drive(fake.home, _plan(), timeout_s=3)

    assert not evidence.ok and "did not settle within 3s" in evidence.error
    assert "tasks in flight ['d1']" in evidence.error
    assert fake.sent("call_stop"), "a call that was started is always ended"


def test_a_missing_socket_is_evidence_not_an_exception(tmp_path):
    evidence = voice.drive(str(tmp_path), _plan(), timeout_s=1)
    assert not evidence.ok and "cannot connect" in evidence.error


# --- selection behind --voice ------------------------------------------------------

def _chosen(tmp_path):
    _fixtures(tmp_path)
    loaded = _load(tmp_path, [_case("a"), _case("b")])
    return loaded, [(loaded[0], loaded[0].scenarios)]


def test_voice_cases_are_planned_but_not_driven_without_the_flag(tmp_path):
    _loaded, chosen = _chosen(tmp_path)

    jobs = run_eval.case_jobs(chosen, 1, operator=True, voice_on=False)
    _scn, planned, turns, judge_turns = run_eval.plan_counts(chosen, True, voice_on=False)

    assert len(jobs) == planned == 2 and turns == 0 and judge_turns == 0
    assert run_eval.plan_counts(chosen, True, voice_on=True)[2] == 2


def test_a_selected_voice_case_is_skipped_with_a_notice_and_counted(tmp_path, monkeypatch,
                                                                   capsys):
    _loaded, chosen = _chosen(tmp_path)
    jobs = run_eval.case_jobs(chosen, 1)

    def must_not_drive(*_a, **_k):
        raise AssertionError("a voice case without --voice must not be driven")

    monkeypatch.setattr(run_eval, "_drive_with_retries", must_not_drive)
    results, skipped, _aborted = run_eval._execute_jobs(
        None, None, jobs, "run1", False, operator=False, voice_on=False)

    assert results == [] and skipped == 2
    assert "rerun with --voice" in capsys.readouterr().out


def test_a_bare_all_sweep_leaves_voice_cases_out_unless_asked(tmp_path):
    loaded, _chosen_ = _chosen(tmp_path)
    profiles = {"host_readonly"}
    sweep = SimpleNamespace(all=True, suite=None, scenario=None, case=None, tag=None,
                            voice=False)

    assert run_eval.select(loaded, sweep, profiles) == []
    assert run_eval.voice_cases_left_out(loaded, sweep, profiles) == 2
    named = SimpleNamespace(**dict(vars(sweep), suite=["spec_voice"]))
    assert len(run_eval.select(loaded, named, profiles)[0][1][0].cases) == 2
    assert run_eval.voice_cases_left_out(loaded, named, profiles) == 0
    asked = SimpleNamespace(**dict(vars(sweep), voice=True))
    assert len(run_eval.select(loaded, asked, profiles)[0][1][0].cases) == 2


def test_judging_is_required_only_for_voice_cases_that_will_run(tmp_path):
    _fixtures(tmp_path)
    loaded = _load(tmp_path, [_case("a", rubric="Judge it."), _case("b")])
    jobs = run_eval.case_jobs([(loaded[0], loaded[0].scenarios)], 1)

    assert run_eval.required_judge_cases(jobs, operator=False, voice_on=False) == []
    assert run_eval.required_judge_cases(jobs, operator=False, voice_on=True) == [
        "spec_voice/scn/a"]


_SHIPPED = ["--suite", "grok_voice", "--profile", "host_readonly", "--profile",
            "isolated_mutation", "--judge", "--dry-run"]


def test_the_runner_dry_runs_the_shipped_suite_with_and_without_the_flag(capsys):
    assert run_eval.main(_SHIPPED) == 4
    out = capsys.readouterr().out
    assert "0 case trial(s) would run" in out and "8 voice trial(s) would skip" in out
    assert out.count("skip: needs --voice") == 8

    assert run_eval.main(_SHIPPED + ["--voice"]) == 0
    out = capsys.readouterr().out
    assert "8 case trial(s) would run" in out and "skip: needs --voice" not in out
    assert "8 case trial(s) would each open one paid Grok voice call" in out


def test_driving_voice_cases_needs_the_isolation_attestations(capsys):
    argv = ["--suite", "grok_voice", "--scenario", "spoken_request_answered_through_task",
            "--judge", "--voice"]

    assert run_eval.main(argv) == 2
    assert "--confirm-daemon-isolated and --confirm-isolated-env" in capsys.readouterr().err


def test_the_voice_precondition_reads_the_home_and_probes_the_socket(tmp_path):
    home = tmp_path / "voice-eval"
    home.mkdir()
    (home / "config.toml").write_text("[sandbox]\nmode = \"strict\"\n")
    assert "no [fermix_core.realtime] enabled = true" in run_eval.voice_precondition_error(
        str(home))

    (home / "config.toml").write_text("[fermix_core.realtime]\nenabled = true\n")
    assert "no voice socket answers" in run_eval.voice_precondition_error(str(home))

    short = tempfile.mkdtemp(prefix="vx")          # AF_UNIX paths are short
    try:
        shutil.copy(home / "config.toml", os.path.join(short, "config.toml"))
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(voice.socket_path(short))
        server.listen(1)
        try:
            assert run_eval.voice_precondition_error(short) is None
        finally:
            server.close()
    finally:
        shutil.rmtree(short, ignore_errors=True)


# --- the runner's grading -------------------------------------------------------------

def _cfg():
    return SimpleNamespace(
        budgets=SimpleNamespace(max_cost_usd=2.0, max_duration_ms=240_000),
        daemon=SimpleNamespace(fermix_home="/nowhere", default_timeout_ms=1_000),
        opik=SimpleNamespace(poll_timeout_s=1, poll_interval_s=0.1, ui_base="http://opik"),
        rubric_failures="fail")


def _graded_case(tmp_path, wire=None, expect=None):
    _fixtures(tmp_path)
    expect = dict(expect or {}, wire=wire or {"engine": "xai_realtime",
                                              "task_statuses_all": ["completed"]})
    loaded = _load(tmp_path, [_case("a", expect=expect), _case("b")])
    suite, scenario = loaded[0], loaded[0].scenarios[0]
    return suite, scenario, scenario.cases[0]


def _settled(frames=None):
    return _evidence(frames or _good())


@pytest.fixture
def stub_fixtures(monkeypatch):
    monkeypatch.setattr(voice, "plan_for", lambda *_a, **_k: _plan())


def test_an_unsettled_call_is_incomplete_not_failed(tmp_path, monkeypatch, stub_fixtures):
    suite, scenario, case = _graded_case(tmp_path)
    lost = voice.Evidence(False, "the daemon closed the connection", run_eval.now_utc())
    monkeypatch.setattr(voice, "drive", lambda *_a, **_k: lost)

    result = run_eval.run_voice_case(_cfg(), None, suite, scenario, case, "run1", 1, False)

    assert result["outcome"] == "incomplete"
    assert result["turns"][0]["drive_error"] == "voice socket: the daemon closed the connection"


def test_a_failed_wire_gate_fails_the_case_without_a_trace(tmp_path, monkeypatch,
                                                         stub_fixtures):
    suite, scenario, case = _graded_case(tmp_path)
    frames = _broken("task_statuses_all")
    monkeypatch.setattr(voice, "drive", lambda *_a, **_k: _settled(frames))
    monkeypatch.setattr(voice, "poll_call_trace", lambda *_a, **_k: None)

    result = run_eval.run_voice_case(_cfg(), None, suite, scenario, case, "run1", 1, False)

    assert result["outcome"] == "fail"
    assert [g["key"] for g in result["turns"][0]["gates"]] == ["wire.engine",
                                                              "wire.task_statuses_all"]


def test_a_settled_call_without_its_trace_is_incomplete(tmp_path, monkeypatch, stub_fixtures):
    suite, scenario, case = _graded_case(tmp_path)
    monkeypatch.setattr(voice, "drive", lambda *_a, **_k: _settled())
    monkeypatch.setattr(voice, "poll_call_trace", lambda *_a, **_k: None)

    result = run_eval.run_voice_case(_cfg(), None, suite, scenario, case, "run1", 1, False)

    assert result["outcome"] == "incomplete"
    assert "no voice call trace named 'voice_live:3'" in result["turns"][0]["drive_error"]


class _Traces:
    """The call's root trace with a nested task turn's spans."""

    def __init__(self):
        self.trace = {"id": "t-1", "name": "voice_live:3", "start_time": "2026-10-17T09:00:00Z",
                      "end_time": "2026-10-17T09:01:00Z", "usage": {"total_tokens": 420},
                      "total_estimated_cost": 0.01, "_eval_trace_complete": True}
        self.spans = [
            {"id": "s1", "type": "tool", "name": "fermix_task", "start_time": "2026-10-17T09:00:05Z"},
            {"id": "s2", "type": "general", "name": "voice_delegation_1"},
            {"id": "s3", "type": "llm", "parent_span_id": "s2", "model": "m",
             "metadata": {"status": "ok"}},
            {"id": "s4", "type": "tool", "name": "shell", "parent_span_id": "s2",
             "start_time": "2026-10-17T09:00:06Z"}]

    def await_complete(self, found):
        assert found is self.trace
        return dict(self.trace), list(self.spans)


def test_a_settled_call_is_graded_on_its_trace_and_what_the_voice_said(
        tmp_path, monkeypatch, stub_fixtures):
    suite, scenario, case = _graded_case(
        tmp_path, expect={"tools_any": ["fermix_task"], "reply_matches": "(?i)kestrel",
                          "reply_not_matches": "(?i)osprey", "status": "ok"})
    traces = _Traces()
    monkeypatch.setattr(voice, "drive", lambda *_a, **_k: _settled())
    monkeypatch.setattr(voice, "poll_call_trace", lambda *_a, **_k: traces.trace)

    result = run_eval.run_voice_case(_cfg(), traces, suite, scenario, case, "run1", 1, False)

    turn = result["turns"][0]
    assert result["outcome"] == "pass", [g for g in turn["gates"] if not g["passed"]]
    assert turn["reply"] == "Lentils work well. Chickpeas: shelf Kestrel."
    assert turn["session"] == "voice_live:3" and turn["tools"] == ["fermix_task", "shell"]
    assert {"tools_any", "reply_matches", "reply_not_matches", "wire.engine"} <= {
        g["key"] for g in turn["gates"]}
    # The persisted digest carries outcomes and counts, never what was said.
    assert "Kestrel" not in json.dumps(turn["voice"])


def test_the_call_trace_is_the_one_named_for_the_call_after_it_started():
    after = run_eval.now_utc().replace(year=2026, month=10, day=17, hour=9, minute=0,
                                       second=0, microsecond=0)
    good = {"id": "t-good", "name": "voice_live:3", "start_time": "2026-10-17T09:00:02Z",
            "metadata": {"provider_session_id": "sess_7"}}
    rows = [good,
            {"id": "t-old", "name": "voice_live:3", "start_time": "2026-10-16T09:00:02Z"},
            {"id": "t-other", "name": "voice_live:3", "start_time": "2026-10-17T09:00:03Z",
             "metadata": {"provider_session_id": "sess_other"}},
            {"id": "t-name", "name": "voice_live:30", "start_time": "2026-10-17T09:00:04Z"}]
    seen = []

    class Client:
        def _filtered_traces(self, filters, since):
            seen.append(filters)
            return rows

    assert voice.find_call_trace(Client(), "voice_live:3", "sess_7", after) is good
    assert seen == [[{"field": "name", "operator": "=", "value": "voice_live:3"}]]
    rows.append(dict(good, id="t-twin"))
    assert voice.find_call_trace(Client(), "voice_live:3", "sess_7", after) is None


if __name__ == "__main__":
    # No third-party pytest plugins: the anthropic SDK imports anyio first, and its
    # autoloaded plugin would only warn that it could not be rewritten.
    sys.exit(pytest.main([__file__, "-q", "--disable-plugin-autoload"]))
