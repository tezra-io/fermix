#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Generate the spoken fixtures `drive: voice` streams into a call.

Each clip is one thing the owner says aloud in `suites/grok_voice.yaml`. The
texts live here, and only here: this script speaks each one with macOS `say`,
converts it to what the realtime socket carries (`afconvert -f WAVE -d
LEI16@24000 -c 1`: 24 kHz mono PCM16), and writes `manifest.json` beside the
WAVs with each clip's file, text, duration and sha256. The suite names clips
by their manifest key; the loader checks every named clip's hash and format at
`--dry-run`, so a WAV edited or regenerated without its manifest fails there.

Every name, place, date and number the clips speak is invented.

  uv run bin/make_voice_fixtures.py            # (re)write the WAVs and manifest
  uv run bin/make_voice_fixtures.py --check    # regenerate into a temp dir and
                                               # compare with the manifest

The output is deterministic for one macOS speech voice: the same voice, rate
and text give the same bytes. A different macOS release may synthesise a
different waveform; `--check` says so by naming the clips whose hash moved.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(os.path.dirname(HERE), "suites", "fixtures", "voice")
MANIFEST = "manifest.json"
VOICE = "Samantha"
RATE_WPM = 180
SAMPLE_RATE = 24_000
SUBPROCESS_TIMEOUT_S = 60

# key -> what the owner says. Absolute dates only.
CLIPS: dict[str, str] = {
    "rota_intake_13": (
        "Hey, who's on intake at the pantry on Saturday the thirteenth of March, "
        "twenty twenty-seven? The rota is in the voice fixtures folder in my workspace."),
    "rota_van_20": (
        "Can you check the pantry rota in the voice fixtures folder of my workspace? "
        "I need to know who's driving the van on Saturday the twentieth of March, "
        "twenty twenty-seven."),
    "stocktake_13_chickpeas": (
        "Please run the stocktake script in the voice fixtures folder of my workspace "
        "for the thirteenth of March, twenty twenty-seven, and tell me which shelf "
        "the chickpeas are on."),
    "stocktake_20_rice": (
        "Could you run the pantry stocktake script from the voice fixtures folder in my "
        "workspace for the twentieth of March, twenty twenty-seven? I want to know "
        "which shelf the rice is on."),
    "followup_curry": "While that runs, what can I use instead of chickpeas in a curry?",
    "followup_brown_rice": (
        "Quick question while you wait. How long does uncooked brown rice keep "
        "in the cupboard?"),
    "cancel_never_mind": "Actually, never mind. Cancel that, I don't need the stocktake anymore.",
    "cancel_stop": "Stop the stocktake, please. I'll go and look at the shelves myself.",
    "correct_to_20": (
        "Sorry, I said the wrong date. I meant the stocktake for the twentieth of March, "
        "not the thirteenth."),
    "correct_to_13": (
        "Wait, wrong day. I need the stocktake for the thirteenth of March, "
        "not the twentieth."),
}


def die(message: str) -> None:
    print(f"make_voice_fixtures: {message}", file=sys.stderr)
    raise SystemExit(1)


def run(argv: list[str]) -> None:
    try:
        subprocess.run(argv, check=True, capture_output=True, timeout=SUBPROCESS_TIMEOUT_S)
    except FileNotFoundError:
        die(f"{argv[0]} is not installed: the fixtures are generated on macOS")
    except subprocess.CalledProcessError as exc:
        die(f"{argv[0]} failed ({exc.returncode}): {exc.stderr.decode(errors='replace')}")
    except subprocess.TimeoutExpired:
        die(f"{argv[0]} did not finish within {SUBPROCESS_TIMEOUT_S}s")


def speak(text: str, out_wav: str, scratch: str) -> None:
    """`say` to AIFF, then `afconvert` to 24 kHz mono little-endian PCM16 WAV."""
    aiff = os.path.join(scratch, os.path.basename(out_wav) + ".aiff")
    run(["say", "-v", VOICE, "-r", str(RATE_WPM), "-o", aiff, text])
    run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1", aiff, out_wav])
    os.remove(aiff)


def describe(path: str, text: str) -> dict:
    """The manifest entry for one WAV, refused unless it is 24 kHz mono PCM16."""
    with wave.open(path, "rb") as clip:
        rate, channels, width = clip.getframerate(), clip.getnchannels(), clip.getsampwidth()
        frames = clip.getnframes()
    if (rate, channels, width) != (SAMPLE_RATE, 1, 2):
        die(f"{path} is {rate} Hz, {channels} channel(s), {8 * width}-bit; "
            f"expected {SAMPLE_RATE} Hz mono 16-bit")
    with open(path, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    return {"file": os.path.basename(path), "text": text, "sha256": digest,
            "duration_ms": frames * 1000 // SAMPLE_RATE}


def generate(out_dir: str) -> dict:
    with tempfile.TemporaryDirectory(prefix="voicefx") as scratch:
        clips = {}
        for key, text in CLIPS.items():
            path = os.path.join(out_dir, f"{key}.wav")
            speak(text, path, scratch)
            clips[key] = describe(path, text)
    return {"generator": "bin/make_voice_fixtures.py", "voice": VOICE, "rate_wpm": RATE_WPM,
            "format": {"sample_rate": SAMPLE_RATE, "channels": 1, "sample_bits": 16,
                       "container": "wav"},
            "clips": clips}


def write_manifest(out_dir: str, manifest: dict) -> None:
    with open(os.path.join(out_dir, MANIFEST), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")


def check() -> int:
    """Regenerate into a temp dir; exit 1 naming every clip whose bytes moved."""
    with open(os.path.join(FIXTURE_DIR, MANIFEST), encoding="utf-8") as handle:
        committed = json.load(handle)["clips"]
    with tempfile.TemporaryDirectory(prefix="voicefx-check") as out_dir:
        fresh = generate(out_dir)["clips"]
    moved = sorted(key for key in set(committed) | set(fresh)
                   if committed.get(key, {}).get("sha256") != fresh.get(key, {}).get("sha256")
                   or committed.get(key, {}).get("text") != fresh.get(key, {}).get("text"))
    if moved:
        print(f"voice fixtures differ from the manifest: {', '.join(moved)}", file=sys.stderr)
        return 1
    print(f"voice fixtures reproduce the manifest ({len(fresh)} clips)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate the drive: voice fixture WAVs.")
    parser.add_argument("--check", action="store_true",
                        help="regenerate into a temp dir and compare with the manifest")
    args = parser.parse_args()
    if args.check:
        return check()
    os.makedirs(FIXTURE_DIR, exist_ok=True)
    manifest = generate(FIXTURE_DIR)
    write_manifest(FIXTURE_DIR, manifest)
    total = sum(clip["duration_ms"] for clip in manifest["clips"].values())
    print(f"wrote {len(manifest['clips'])} clips ({total / 1000:.1f}s of speech) and "
          f"{MANIFEST} to {FIXTURE_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
