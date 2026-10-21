#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=13"]
# ///
"""Qualify Grok Voice 3.0 against what Fermix's Grok engine assumes (M70 step 0).

Speaks to xAI's realtime voice endpoint directly, the way
`FermixCore.Realtime.GrokSessionServer` does (same session configuration, the
one `fermix_task` function, 24 kHz PCM16, server VAD), with synthetic speech
from macOS `say`, and records every server event with the audio replaced by
its size. Then it checks the four behaviours the engine is built on:

  pending      Grok keeps conversing while a `fermix_task` call has no output:
               a second question gets a spoken answer before the output is sent.
  quiet        A `system` context item creates no response on its own.
  continue     After the output, one `response.create` speaks the result, once.
  truncate     `conversation.item.truncate` on an item being played answers
               `conversation.item.truncated` with the transcript up to the cut.
  acked        A `function_call_output` is acknowledged with
               `conversation.item.added` naming its client id, which is what
               would let a response Grok starts prove it heard a result.

Each checker is proven to fail on a deliberately broken event list first
(`--self-test`, which spends nothing). A live run costs money: about $0.08 per
connected minute plus $0.004 per text item; the script prints its local
estimate and the session window so the bill can be reconciled in the xAI
console for that window alone.

Usage:
    uv run scripts/dev/grok_voice_probe.py --self-test
    XAI_API_KEY=... uv run scripts/dev/grok_voice_probe.py --out /tmp/grok-probe
"""

import argparse
import asyncio
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

URL = "wss://api.x.ai/v1/realtime?model=grok-voice-3.0"
RATE = 24_000
CHUNK_MS = 100
BYTES_PER_MS = 48
DURATION_MILLICENTS_PER_MINUTE = 8_000
TEXT_ITEM_MILLICENTS = 400

TOOL = {
    "type": "function",
    "name": "fermix_task",
    "description": "Hand a task to Fermix, the owner's agent. The output arrives when the task ends.",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["submit", "cancel"]},
            "request": {"type": "string"},
            "task_id": {"type": "string"},
        },
        "required": ["action"],
        "additionalProperties": False,
    },
}

INSTRUCTIONS = """## Role & Persona
You are the owner's voice companion.

## Objective
Hand anything that needs a tool or an action to `fermix_task`; answer small talk yourself.

## Conversation Flow
- Keep talking with the owner while a task runs.
- State only results that a `fermix_task` output gave you.
"""

SAYINGS = {
    "task": "Please book the meeting room for tomorrow at ten.",
    "aside": "While that runs, what is the capital of France?",
    "story": "Tell me a long story about a lighthouse keeper.",
    "stop": "Stop, thanks.",
}


def fail(message):
    print(f"grok_voice_probe.py: {message}", file=sys.stderr)
    sys.exit(1)


# --- checkers: each answers (ok, why) over the recorded server events ---------


def check_pending(events):
    call = first(events, "response.function_call_arguments.done")
    output_at = first_sent(events, "function_call_output")
    if call is None:
        return False, "no fermix_task call was made"
    if output_at is None:
        return False, "the output was never sent"
    spoken = [
        e
        for e in events
        if e["seq"] > call["seq"]
        and e["seq"] < output_at
        and e.get("type") == "response.output_audio.delta"
    ]
    if not spoken:
        return False, "no audio was spoken between the call and its output"
    return True, f"{len(spoken)} audio deltas while the call was pending"


def check_quiet(events):
    sent = first_sent(events, "system")
    speech = first(events, "input_audio_buffer.speech_started")
    if sent is None:
        return False, "no context item was sent"
    created = [
        e
        for e in events
        if e.get("type") == "response.created"
        and e["seq"] > sent
        and (speech is None or e["seq"] < speech["seq"])
    ]
    if created:
        return False, "a response started on the context item alone"
    return True, "no response before the owner spoke"


def check_continue(events):
    requested = [e for e in events if e.get("dir") == "sent" and e.get("type") == "response.create"]
    if len(requested) != 1:
        return False, f"{len(requested)} continuations were requested"
    created = [
        e
        for e in events
        if e.get("type") == "response.created"
        and ((e.get("response") or {}).get("metadata") or {}).get("fermix_continuation") == "c1"
    ]
    if len(created) != 1:
        return False, f"{len(created)} responses answered the continuation"
    return True, "one continuation, one answer"


def check_truncate(events):
    truncated = first(events, "conversation.item.truncated")
    if truncated is None:
        return False, "no conversation.item.truncated arrived"
    if not isinstance(truncated.get("transcript"), str):
        return False, "the truncation carried no transcript"
    return True, f"cut at {truncated.get('audio_end_ms')} ms: {truncated['transcript']!r}"


def check_acked(events):
    sent = [e for e in events if e.get("dir") == "sent" and (e.get("item") or {}).get("type") == "function_call_output"]
    if not sent:
        return False, "no function output was sent"
    ids = {e["item"].get("id") for e in sent}
    added = {(e.get("item") or {}).get("id") for e in events if e.get("type") == "conversation.item.added"}
    missing = ids - added
    if missing:
        return False, f"no conversation.item.added for {sorted(missing)}"
    return True, f"{len(ids)} output(s) acknowledged"


CHECKERS = {
    "pending": check_pending,
    "quiet": check_quiet,
    "continue": check_continue,
    "truncate": check_truncate,
    "acked": check_acked,
}


def first(events, kind):
    return next((e for e in events if e.get("type") == kind and e.get("dir") != "sent"), None)


def first_sent(events, marker):
    for e in events:
        if e.get("dir") == "sent" and marker in json.dumps(e.get("item") or {}):
            return e["seq"]
    return None


def self_test():
    """Each checker fails on a broken order and passes on a good one."""
    good = [
        {"seq": 1, "dir": "sent", "type": "conversation.item.create", "item": {"role": "system"}},
        {"seq": 2, "type": "input_audio_buffer.speech_started"},
        {"seq": 3, "type": "response.function_call_arguments.done"},
        {"seq": 4, "type": "response.output_audio.delta"},
        {"seq": 5, "dir": "sent", "type": "conversation.item.create", "item": {"type": "function_call_output", "id": "fx_out_1"}},
        {"seq": 5.5, "type": "conversation.item.added", "item": {"id": "fx_out_1"}},
        {"seq": 6, "dir": "sent", "type": "response.create"},
        {"seq": 7, "type": "response.created", "response": {"metadata": {"fermix_continuation": "c1"}}},
        {"seq": 8, "type": "conversation.item.truncated", "audio_end_ms": 900, "transcript": "Once"},
    ]
    broken = {
        "pending": [e for e in good if e["seq"] != 4],
        "quiet": good[:1] + [{"seq": 1.5, "type": "response.created"}] + good[1:],
        "continue": good + [{"seq": 9, "dir": "sent", "type": "response.create"}],
        "truncate": [e for e in good if e["seq"] != 8],
        "acked": [e for e in good if e["seq"] != 5.5],
    }
    for name, checker in CHECKERS.items():
        ok, why = checker(good)
        if not ok:
            fail(f"self-test: {name} refused a good order: {why}")
        ok, _why = checker(broken[name])
        if ok:
            fail(f"self-test: {name} passed a broken order")
        print(f"self-test {name}: fails on the broken order, passes on the good one")


# --- speech ---------------------------------------------------------------------


def synthesize(text, workdir):
    """24 kHz mono PCM16 of `text`, from macOS `say`."""
    aiff = Path(workdir) / "say.aiff"
    wav = Path(workdir) / "say.wav"
    subprocess.run(["say", "-o", str(aiff), text], check=True)
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(aiff), str(wav)],
        check=True,
    )
    data = wav.read_bytes()
    marker = data.find(b"data")
    if marker < 0:
        fail("afconvert produced no data chunk")
    return data[marker + 8 :]


def silence(ms):
    return bytes(ms * BYTES_PER_MS)


# --- the live run -----------------------------------------------------------------


class Probe:
    def __init__(self, ws):
        self.ws = ws
        self.events = []
        self.seq = 0
        self.text_items = 0
        self.calls = []

    def record(self, event, sent=False):
        self.seq += 1
        row = dict(event)
        for key in ("delta", "audio"):
            if isinstance(row.get(key), str) and len(row[key]) > 64:
                row[key] = f"<{len(row[key])} base64 bytes>"
        row["seq"] = self.seq
        row["t"] = round(time.monotonic(), 3)
        if sent:
            row["dir"] = "sent"
        self.events.append(row)
        return row

    async def send(self, event):
        if event.get("type") == "conversation.item.create" and event["item"].get("type") == "message":
            self.text_items += 1
        self.record(event, sent=True)
        await self.ws.send(json.dumps(event))

    async def speak(self, pcm):
        step = CHUNK_MS * BYTES_PER_MS
        for offset in range(0, len(pcm), step):
            chunk = pcm[offset : offset + step]
            await self.ws.send(json.dumps({"type": "input_audio_buffer.append", "audio": base64.b64encode(chunk).decode()}))
            await asyncio.sleep(CHUNK_MS / 1000)

    async def listen(self):
        async for raw in self.ws:
            if isinstance(raw, bytes):
                self.record({"type": "<binary frame>", "bytes": len(raw)})
                continue
            event = self.record(json.loads(raw))
            if event.get("type") == "response.function_call_arguments.done":
                self.calls.append(event)


async def run(out_dir, key):
    import websockets

    workdir = tempfile.mkdtemp(prefix="grok-probe-")
    speech = {name: synthesize(text, workdir) for name, text in SAYINGS.items()}
    started = time.time()

    async with websockets.connect(URL, additional_headers={"Authorization": f"Bearer {key}"}) as ws:
        probe = Probe(ws)
        listener = asyncio.create_task(probe.listen())
        await asyncio.sleep(1)
        await probe.send(
            {
                "type": "session.update",
                "session": {
                    "instructions": INSTRUCTIONS,
                    "voice": "eve",
                    "turn_detection": {"type": "server_vad"},
                    "reasoning": {"effort": "high"},
                    "resumption": {"enabled": False},
                    "tools": [TOOL],
                    "audio": {
                        "input": {"format": {"type": "audio/pcm", "rate": RATE}},
                        "output": {"format": {"type": "audio/pcm", "rate": RATE}},
                    },
                },
            }
        )
        await asyncio.sleep(1)
        await probe.send(
            {
                "type": "conversation.item.create",
                "item": {
                    "id": "fx_ctx_1",
                    "type": "message",
                    "role": "system",
                    "content": [{"type": "input_text", "text": "Context only, not a request: the owner typed a lease link."}],
                },
            }
        )
        await asyncio.sleep(3)

        # The task, then a second question while its call is still open.
        await probe.speak(speech["task"] + silence(1_500))
        await asyncio.sleep(4)
        await probe.speak(speech["aside"] + silence(1_500))
        await asyncio.sleep(8)

        for n, call in enumerate(probe.calls, start=1):
            output = json.dumps({"status": "completed", "task_id": "t1", "result": "The room is booked for 10am tomorrow."})
            await probe.send(
                {
                    "type": "conversation.item.create",
                    "item": {"id": f"fx_out_{n}", "type": "function_call_output", "call_id": call["call_id"], "output": output},
                }
            )
        await probe.send({"type": "response.create", "response": {"metadata": {"fermix_continuation": "c1"}}})
        await asyncio.sleep(8)

        # A long reply, cut after about a second of it.
        await probe.speak(speech["story"] + silence(1_500))
        item = await wait_for_audio(probe, 25)
        if item:
            await asyncio.sleep(1)
            await probe.send({"type": "conversation.item.truncate", "item_id": item, "content_index": 0, "audio_end_ms": 1_000})
            await probe.speak(speech["stop"] + silence(1_500))
        await asyncio.sleep(5)

        listener.cancel()
        ended = time.time()

    report(probe, out_dir, started, ended)


async def wait_for_audio(probe, seconds):
    start = probe.seq
    for _ in range(seconds * 10):
        for e in probe.events:
            if e["seq"] > start and e.get("type") == "response.output_audio.delta":
                return e.get("item_id")
        await asyncio.sleep(0.1)
    return None


def report(probe, out_dir, started, ended):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    events_path = out / "events.jsonl"
    events_path.write_text("".join(json.dumps(e) + "\n" for e in probe.events))

    connected_ms = int((ended - started) * 1000)
    millicents = -(-connected_ms * DURATION_MILLICENTS_PER_MINUTE // 60_000) + TEXT_ITEM_MILLICENTS * probe.text_items
    print(f"events: {events_path} ({len(probe.events)} rows, audio replaced by its size)")
    print(f"window: {time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(started))}Z .. {time.strftime('%H:%M:%S', time.gmtime(ended))}Z")
    print(f"estimate: {connected_ms / 1000:.1f} s connected, {probe.text_items} text items, ${millicents / 100_000:.4f}")

    failures = 0
    for name, checker in CHECKERS.items():
        ok, why = checker(probe.events)
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} {name}: {why}")
    sys.exit(1 if failures else 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true", help="prove each checker fails on a broken order; spends nothing")
    parser.add_argument("--out", help="directory for the recorded events")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return
    if not args.out:
        fail("--out is required for a live run")
    if sys.platform != "darwin":
        fail("the synthetic speech needs macOS `say` and `afconvert`")
    key = os.environ.get("XAI_API_KEY", "")
    if key in ("", "@keyring", "@file"):
        fail("set XAI_API_KEY to a SpaceXAI API key for the live run")
    asyncio.run(run(args.out, key))


if __name__ == "__main__":
    main()
