#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["cryptography>=43"]
# ///
"""Write the Fermix accessory link's contract fixtures.

The fixtures under `apps/fermix_core/priv/accessory/fixtures/` are the vectors
both ends of the link test against: the daemon's `FermixCore.Accessories`
modules and the firmware that vendors the contract byte for byte. This script
is a second implementation of the wire (framing, CRC, the receive algorithm,
the reassembler, both transcripts, the compare code), written from
`PROTOCOL.md` and sharing no code with the Elixir one, so a fixture the Elixir
contract test reproduces was computed twice.

Keys come from invented seeds (`derive_key`), so every run writes the same
files. Signatures are deterministic ECDSA (RFC 6979, SHA-256), checked against
the RFC's own P-256 vector before anything is written, so a firmware signer
built with deterministic ECDSA reproduces them byte for byte. A verifier must
accept any valid signature, not only these.

Usage: scripts/dev/accessory_fixtures.py [--out DIR] [--check]

`--check` writes nothing: it regenerates into a temporary directory and exits
1, naming each file, when the committed fixtures differ from what this script
writes.
"""

from __future__ import annotations

import argparse
import filecmp
import hashlib
import json
import struct
import sys
import tempfile
import zlib
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import (
    decode_dss_signature,
    encode_dss_signature,
)
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

REPO = Path(__file__).resolve().parents[2]
DEFAULT_OUT = REPO / "apps/fermix_core/priv/accessory/fixtures"

MAGIC = b"FX"
FRAMING_VERSION = 1
HEADER_LEN = 16
CRC_LEN = 4
MAX_PAYLOAD = 4096
MIC_BYTES = 960
MAX_SPEAKER_BYTES = 3840
RESYNC_LIMIT = 8192
STALL_MS = 1000
MAX_MESSAGE = 8192
TYPES = {"control": 1, "mic": 2, "speaker": 3, "diagnostics": 4}
TYPE_NAMES = {v: k for k, v in TYPES.items()}
START, END, URGENT = 1, 2, 4
RECEIVES = {"accessory": {1, 2, 4}, "host": {1, 3}}

ATTACH_DOMAIN = b"FERMIX-ACCESSORY-USB-ATTACH-v1"
ENROLL_DOMAIN = b"FERMIX-ACCESSORY-USB-ENROLL-v1"
KEY_SEED_PREFIX = b"fermix-accessory-fixture-key:"
P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551


# -- framing -----------------------------------------------------------------


def frame(type_, payload=b"", *, flags=0, stream=0, seq=0, version=FRAMING_VERSION,
          reserved=0, length=None, crc_xor=0):
    type_code = TYPES[type_] if isinstance(type_, str) else type_
    claimed = len(payload) if length is None else length
    header = MAGIC + struct.pack("<BBBBHII", version, type_code, flags, reserved, stream, seq, claimed)
    body = header + payload
    return body + struct.pack("<I", zlib.crc32(body) ^ crc_xor)


def plausible(version, type_code, flags, reserved, length):
    if version != FRAMING_VERSION:
        return "frame_version"
    if type_code not in TYPE_NAMES:
        return "unknown_frame_type"
    if flags & 0xF8:
        return "bad_flags"
    if reserved != 0:
        return "bad_reserved"
    if length > MAX_PAYLOAD:
        return "over_cap"
    return None


def semantic(sender, type_code, flags, stream, payload):
    if type_code not in RECEIVES[sender]:
        return "wrong_direction"
    name = TYPE_NAMES[type_code]
    if name == "control":
        return "bad_length" if not payload else None
    if flags:
        return "bad_flags"
    if name == "diagnostics":
        if stream != 0:
            return "bad_stream"
        return "bad_length" if not payload else None
    if stream == 0:
        return "bad_stream"
    if name == "mic":
        return None if len(payload) == MIC_BYTES else "bad_length"
    ok = 0 < len(payload) <= MAX_SPEAKER_BYTES and len(payload) % 2 == 0
    return None if ok else "bad_length"


class Parser:
    """The receive algorithm of PROTOCOL.md, *Receiving*."""

    def __init__(self, sender):
        self.sender = sender
        self.buf = b""
        self.synced = False
        self.scanned = 0
        self.resync_bytes = 0
        self.waiting_since = None
        self.events = []

    def discard(self, n, reason):
        if self.synced:
            self.events.append({"fault": reason})
            self.synced = False
        crossed = (self.scanned + n) // RESYNC_LIMIT - self.scanned // RESYNC_LIMIT
        self.scanned += n
        self.resync_bytes += n
        self.events.extend({"fault": "resync_limit"} for _ in range(crossed))
        self.buf = self.buf[n:]

    def feed(self, chunk, now_ms):
        self.buf += chunk
        progressed = self.run()
        # Pending bytes that make no progress for STALL_MS are a stalled frame:
        # one byte goes, as for any other fault, and the rest are read again.
        for _ in range(len(self.buf) + 1):
            if not self.buf:
                self.waiting_since = None
                return
            if progressed or self.waiting_since is None:
                self.waiting_since = now_ms
            if now_ms - self.waiting_since < STALL_MS:
                return
            self.discard(1, "frame_timeout")
            self.run()
            progressed = True
        raise AssertionError("the stall bound made no progress")

    def run(self):
        progressed = False
        while self.step():
            progressed = True
        return progressed

    def step(self):
        buf = self.buf
        if not buf.startswith(MAGIC):
            at = buf.find(MAGIC)
            n = at if at >= 0 else len(buf) - (1 if buf.endswith(b"F") else 0)
            if n == 0:
                return False
            self.discard(n, "bad_magic")
            return True
        if len(buf) < HEADER_LEN:
            return False
        version, type_code, flags, reserved, stream, seq, length = struct.unpack_from("<BBBBHII", buf, 2)
        reason = plausible(version, type_code, flags, reserved, length)
        if reason:
            self.discard(1, reason)
            return True
        if len(buf) < HEADER_LEN + length + CRC_LEN:
            return False
        body = buf[: HEADER_LEN + length]
        (crc,) = struct.unpack_from("<I", buf, HEADER_LEN + length)
        if zlib.crc32(body) != crc:
            self.discard(1, "crc_mismatch")
            return True
        self.buf = buf[HEADER_LEN + length + CRC_LEN:]
        self.synced = True
        self.scanned = 0
        payload = body[HEADER_LEN:]
        fault = semantic(self.sender, type_code, flags, stream, payload)
        if fault:
            self.events.append({"fault": fault})
        else:
            self.events.append({"frame": frame_record(TYPE_NAMES[type_code], flags, stream, seq, payload)})
        return True


def frame_record(type_name, flags, stream, seq, payload):
    return {"type": type_name, "flags": flags, "stream": stream, "seq": seq, "payload": payload.hex()}


def parse(chunks, sender, times_ms=None):
    parser = Parser(sender)
    for chunk, now_ms in zip(chunks, times_ms or [0] * len(chunks), strict=True):
        parser.feed(chunk, now_ms)
    return parser.events, parser.resync_bytes, len(parser.buf)


class Reassembler:
    """The control reassembly of PROTOCOL.md, *Control messages across frames*."""

    def __init__(self):
        self.open = None
        self.last_seq = None
        self.events = []

    def fault(self, reason):
        self.events.append({"fault": reason})
        self.open = None
        self.last_seq = None

    def feed(self, flags, stream, seq, payload):
        if seq == 0:
            # A new sequence: the sender opened the link again. Drop any
            # partial message and the base, count no fault.
            self.open = None
            self.last_seq = None
        if self.last_seq is not None and seq != (self.last_seq + 1) % 2**32:
            return self.fault("control_seq_gap")
        self.last_seq = seq
        if flags & START:
            if self.open is not None:
                return self.fault("fragment_sequence")
            if flags & END:
                return self.events.append({"message": {"stream": stream, "payload": payload.hex()}})
            self.open = (stream, [payload], len(payload))
            return None
        if self.open is None:
            return self.fault("fragment_sequence")
        open_stream, parts, size = self.open
        if stream != open_stream:
            return self.fault("fragment_stream")
        if size + len(payload) > MAX_MESSAGE:
            return self.fault("control_too_large")
        parts.append(payload)
        self.open = (open_stream, parts, size + len(payload))
        if flags & END:
            self.events.append({"message": {"stream": open_stream, "payload": b"".join(parts).hex()}})
            self.open = None
        return None


# -- keys, transcripts, signatures --------------------------------------------


def derive_key(seed):
    digest = hashlib.sha256(KEY_SEED_PREFIX + seed.encode()).digest()
    scalar = int.from_bytes(digest, "big") % (P256_N - 1) + 1
    return ec.derive_private_key(scalar, ec.SECP256R1())


def public_bytes(key):
    return key.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)


def private_bytes(key):
    return key.private_numbers().private_value.to_bytes(32, "big")


def key_id(public):
    return hashlib.sha256(public).hexdigest()


def sign(key, message):
    der = key.sign(message, ec.ECDSA(hashes.SHA256(), deterministic_signing=True))
    r, s = decode_dss_signature(der)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def verify(public, message, raw):
    r, s = int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big")
    if not (0 < r < P256_N and 0 < s < P256_N):
        return False
    point = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), public)
    try:
        point.verify(encode_dss_signature(r, s), message, ec.ECDSA(hashes.SHA256()))
        return True
    except Exception:  # noqa: BLE001 - the library's InvalidSignature is the expected refusal
        return False


def check_rfc6979():
    """RFC 6979 A.2.5, P-256, SHA-256, message "sample"."""
    scalar = int("C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721", 16)
    key = ec.derive_private_key(scalar, ec.SECP256R1())
    expected = (
        "EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716"
        "F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8"
    )
    got = sign(key, b"sample").hex().upper()
    if got != expected:
        sys.exit(f"deterministic ECDSA is not RFC 6979 here: {got}")


def attach_transcript(f):
    kind = f["kind"].encode()
    return (
        ATTACH_DOMAIN
        + bytes.fromhex(f["host_id"])
        + bytes.fromhex(f["accessory_id"])
        + bytes.fromhex(f["host_nonce"])
        + bytes.fromhex(f["accessory_nonce"])
        + struct.pack("<HIII", f["wire"], f["host_caps"], f["accessory_caps"], f["gen"])
        + bytes([len(kind)])
        + kind
    )


def enroll_transcript(f):
    return (
        ENROLL_DOMAIN
        + bytes.fromhex(f["host_pk"])
        + bytes.fromhex(f["accessory_pk"])
        + bytes.fromhex(f["host_nonce"])
        + bytes.fromhex(f["accessory_nonce"])
    )


def compare_code(transcript):
    first = int.from_bytes(hashlib.sha256(transcript).digest()[:4], "big")
    return f"{first % 1_000_000:06d}"


def nonce(label):
    return hashlib.sha256(b"fermix-accessory-fixture-nonce:" + label.encode()).hexdigest()


def attempt_id(label):
    return hashlib.sha256(b"fermix-accessory-fixture-attempt:" + label.encode()).hexdigest()[:32]


# -- the fixture files ---------------------------------------------------------

KEYS = {
    "host": "larkspur-host-1",
    "other_host": "heron-host-2",
    "accessory": "kestrel-accessory-1",
    "other_accessory": "wren-accessory-2",
}


def keys_fixture():
    rows = {}
    for role, seed in KEYS.items():
        key = derive_key(seed)
        public = public_bytes(key)
        rows[role] = {
            "seed": seed,
            "private": private_bytes(key).hex(),
            "public": public.hex(),
            "id": key_id(public),
        }
    return {
        "derivation": "scalar = (SHA-256(\"fermix-accessory-fixture-key:\" || seed) as a big-endian integer) mod (n - 1) + 1",
        "keys": rows,
    }


def attach_fixture(keys):
    host, acc, other = keys["host"], keys["accessory"], keys["other_accessory"]
    vectors = []
    for name, gen, acc_caps in [("enrolled", 7, 0x7F), ("voice_only", 1, 0x03), ("wake_word_bit", 4294967295, 0x1FF)]:
        fields = {
            "host_id": host["id"],
            "accessory_id": acc["id"],
            "host_nonce": nonce(f"attach-host-{name}"),
            "accessory_nonce": nonce(f"attach-accessory-{name}"),
            "wire": 1,
            "host_caps": 0x7F,
            "accessory_caps": acc_caps,
            "gen": gen,
            "kind": "stackchan",
        }
        transcript = attach_transcript(fields)
        acc_sig = sign(derive_key(KEYS["accessory"]), transcript)
        host_sig = sign(derive_key(KEYS["host"]), transcript)
        assert verify(bytes.fromhex(acc["public"]), transcript, acc_sig)
        assert verify(bytes.fromhex(host["public"]), transcript, host_sig)
        vectors.append({
            "name": name,
            "fields": fields,
            "transcript": transcript.hex(),
            "transcript_sha256": hashlib.sha256(transcript).hexdigest(),
            "accessory_sig": acc_sig.hex(),
            "host_sig": host_sig.hex(),
        })
    base = vectors[0]
    transcript = bytes.fromhex(base["transcript"])
    acc_sig = bytes.fromhex(base["accessory_sig"])
    r, s = acc_sig[:32], int.from_bytes(acc_sig[32:], "big")
    high_s = r + (P256_N - s).to_bytes(32, "big")
    wrong_key_sig = sign(derive_key(KEYS["other_accessory"]), transcript)
    later = dict(base["fields"], gen=base["fields"]["gen"] + 1)
    checks = [
        ("accessory_sig_verifies", "accessory", base["transcript"], acc_sig.hex(), True),
        ("host_sig_verifies", "host", base["transcript"], base["host_sig"], True),
        ("high_s_verifies", "accessory", base["transcript"], high_s.hex(), True),
        ("wrong_key", "accessory", base["transcript"], wrong_key_sig.hex(), False),
        ("host_sig_is_not_accessory_sig", "accessory", base["transcript"], base["host_sig"], False),
        ("other_generation", "accessory", attach_transcript(later).hex(), acc_sig.hex(), False),
        ("r_zero", "accessory", base["transcript"], (bytes(32) + acc_sig[32:]).hex(), False),
        ("s_equals_n", "accessory", base["transcript"], (r + P256_N.to_bytes(32, "big")).hex(), False),
    ]
    rows = []
    for name, signer, transcript_hex, sig_hex, expected in checks:
        public = bytes.fromhex(keys[signer]["public"])
        assert verify(public, bytes.fromhex(transcript_hex), bytes.fromhex(sig_hex)) is expected, name
        rows.append({"name": name, "public": signer, "transcript": transcript_hex, "sig": sig_hex,
                     "verifies": expected})
    assert other["id"] != acc["id"]
    return {"vectors": vectors, "verify": rows}


def enroll_fixture(keys):
    host, acc = keys["host"], keys["accessory"]
    vectors = []
    labels = ["first", "second-round"]
    # A vector whose code starts with zeros, found deterministically, so a
    # display that drops leading zeros fails it.
    for counter in range(10_000):
        fields = {"host_pk": host["public"], "accessory_pk": acc["public"],
                  "host_nonce": nonce(f"enroll-host-zero-{counter}"),
                  "accessory_nonce": nonce(f"enroll-accessory-zero-{counter}")}
        if compare_code(enroll_transcript(fields)).startswith("00"):
            break
    else:
        sys.exit("no leading-zero compare code in 10,000 candidates")
    candidates = [(label, {"host_pk": host["public"], "accessory_pk": acc["public"],
                           "host_nonce": nonce(f"enroll-host-{label}"),
                           "accessory_nonce": nonce(f"enroll-accessory-{label}")}) for label in labels]
    candidates.append(("leading_zeros", fields))
    for name, fields in candidates:
        transcript = enroll_transcript(fields)
        digest = hashlib.sha256(transcript).digest()
        vectors.append({
            "name": name,
            "fields": fields,
            "transcript": transcript.hex(),
            "host_commit": hashlib.sha256(bytes.fromhex(fields["host_nonce"])).hexdigest(),
            "transcript_sha256": digest.hex(),
            "first_32_bits": int.from_bytes(digest[:4], "big"),
            "compare_code": compare_code(transcript),
            "accessory_sig": sign(derive_key(KEYS["accessory"]), transcript).hex(),
            "host_sig": sign(derive_key(KEYS["host"]), transcript).hex(),
        })
    return {"vectors": vectors}


def crc_fixture():
    texts = ["", "a", "abc", "123456789", "message digest", "abcdefghijklmnopqrstuvwxyz",
             "The quick brown fox jumps over the lazy dog"]
    rows = [{"name": f"ascii {t!r}", "input": t.encode().hex()} for t in texts]
    rows.append({"name": "32 zero bytes", "input": bytes(32).hex()})
    rows.append({"name": "32 0xff bytes", "input": (b"\xff" * 32).hex()})
    rows.append({"name": "a hello header", "input": frame("control", b"{}", flags=3)[:-4].hex()})
    for row in rows:
        value = zlib.crc32(bytes.fromhex(row["input"]))
        row["value"] = f"{value:08x}"
        row["wire"] = struct.pack("<I", value).hex()
    return {"algorithm": "CRC-32/ISO-HDLC (IEEE 802.3, zlib): poly 0x04C11DB7 reflected (0xEDB88320), "
                         "init 0xFFFFFFFF, refin and refout, xorout 0xFFFFFFFF",
            "vectors": rows}


def pcm(n, salt):
    # A deterministic sample pattern with no "FX" in it, so a corpus case's
    # resync count depends only on the bytes the case puts there on purpose.
    out = bytearray()
    i = 0
    while len(out) < n:
        out += struct.pack("<h", ((i * 37 + salt * 101) % 2000) - 1000)
        i += 1
    data = bytes(out[:n])
    assert MAGIC not in data
    return data


def control(obj):
    return json.dumps(obj, separators=(",", ":")).encode()


HELLO_ACK_PAYLOAD = control({"type": "pong", "gen": 3, "uptime_ms": 81234})
MIC_STATE_PAYLOAD = control({"type": "mic.state", "gen": 3, "stream": 1, "state": "live"})


def frames_fixture():
    # No message of wire version 1 needs a second frame; an additive field a
    # later version adds may, so the reassembly already carries one.
    long_json = control({"type": "pong", "gen": 3, "uptime_ms": 1, "note": "n" * 5000})
    parts = [long_json[:4096], long_json[4096:]]
    assert len(parts[1]) > 0
    specs = [
        ("control_single", "control", HELLO_ACK_PAYLOAD, 3, 0, 0),
        ("control_urgent", "control", control({"type": "spk.flush", "gen": 3, "stream": 2}), 7, 2, 41),
        ("control_first_fragment", "control", parts[0], 1, 0, 9),
        ("control_last_fragment", "control", parts[1], 2, 0, 10),
        ("mic_20ms", "mic", pcm(MIC_BYTES, 1), 0, 1, 0),
        ("speaker_one_sample", "speaker", b"\x01\x80", 0, 1, 0),
        ("speaker_80ms", "speaker", pcm(MAX_SPEAKER_BYTES, 2), 0, 65535, 4294967295),
        ("diagnostics_text", "diagnostics", b"I (812) fx_link: attached\n", 0, 0, 77),
        ("control_max_payload", "control", b"[" + b"0," * 2046 + b"00]", 3, 0, 5),
    ]
    rows = []
    for name, type_, payload, flags, stream, seq in specs:
        assert len(payload) <= MAX_PAYLOAD, name
        rows.append(dict(frame_record(type_, flags, stream, seq, payload), name=name,
                         frame=frame(type_, payload, flags=flags, stream=stream, seq=seq).hex()))
    return {"frames": rows}


def corpus_fixture():
    a1 = frame("control", HELLO_ACK_PAYLOAD, flags=3, seq=0)
    a2 = frame("mic", pcm(MIC_BYTES, 3), stream=1, seq=0)
    a3 = frame("control", MIC_STATE_PAYLOAD, flags=3, stream=1, seq=1)
    m2 = frame("mic", pcm(MIC_BYTES, 4), stream=1, seq=1)
    m3 = frame("mic", pcm(MIC_BYTES, 5), stream=1, seq=2)
    h1 = frame("control", control({"type": "ping", "gen": 3}), flags=3, seq=0)
    h2 = frame("speaker", pcm(480, 6), stream=1, seq=0)
    h3 = frame("control", control({"type": "spk.flush", "gen": 3, "stream": 1}), flags=7, stream=1, seq=1)
    banner = b"ESP-ROM:esp32s3-20210327\r\nbuild:Mar 27 2021\r\nrst:0x15 (USB_UART_CHIP_RESET)\r\n"
    false_magic = b"boot: FX mode 1\r\n"
    no_f = bytes(b for b in range(256) if b != 0x46)

    def stretched(f, length):
        # The same frame with a larger length field: its CRC no longer matches.
        return f[:12] + struct.pack("<I", length) + f[16:]

    cases = [
        ("clean", "accessory", [a1 + a2 + a3], ["f", "f", "f"]),
        ("clean_byte_at_a_time", "accessory", [bytes([b]) for b in a1 + a2], ["f", "f"]),
        ("rom_banner_then_frames", "accessory", [banner + a1 + a2], ["f", "f"]),
        ("false_magic_in_banner", "accessory", [false_magic + a1], ["f"]),
        ("trailing_partial_frame", "accessory", [a1 + a2[:10]], ["f"]),
        ("trailing_magic_byte", "accessory", [a1 + b"F"], ["f"]),
        ("bad_crc_after_sync", "accessory", [a1 + frame("mic", pcm(MIC_BYTES, 3), stream=1, crc_xor=1) + a3],
         ["f", "crc_mismatch", "f"]),
        ("stretched_length_recovers_what_follows", "accessory", [a1 + stretched(a2, 2000) + a3 + m2 + m3],
         ["f", "crc_mismatch", "f", "f", "f"]),
        ("over_cap_after_sync", "accessory", [a1 + stretched(a2, 4097) + a3], ["f", "over_cap", "f"]),
        ("over_cap_while_hunting", "accessory", [stretched(a2, 70000) + a1], ["f"]),
        ("bad_magic_after_sync", "accessory", [a1 + b"\x00garbage\x00" + a3], ["f", "bad_magic", "f"]),
        ("resync_limit", "accessory", [a1 + (no_f * 36)[:9000] + a3], ["f", "bad_magic", "resync_limit", "f"]),
        ("resync_limit_twice", "accessory", [a1 + (no_f * 80)[:17000] + a3],
         ["f", "bad_magic", "resync_limit", "resync_limit", "f"]),
        ("frame_version_after_sync", "accessory", [a1 + frame("control", b"{}", flags=3, seq=1, version=2) + a3],
         ["f", "frame_version", "f"]),
        ("unknown_type_after_sync", "accessory", [a1 + frame(9, b"{}", seq=1) + a3],
         ["f", "unknown_frame_type", "f"]),
        ("unknown_flag_after_sync", "accessory", [a1 + frame("control", b"{}", flags=8, seq=1) + a3],
         ["f", "bad_flags", "f"]),
        ("reserved_set_after_sync", "accessory", [a1 + frame("control", b"{}", flags=3, seq=1, reserved=1) + a3],
         ["f", "bad_reserved", "f"]),
        ("speaker_from_accessory", "accessory", [a1 + frame("speaker", b"\x00\x00", stream=1) + a3],
         ["f", "wrong_direction", "f"]),
        ("short_mic_frame", "accessory", [a1 + frame("mic", pcm(958, 3), stream=1) + a3], ["f", "bad_length", "f"]),
        ("mic_on_link_stream", "accessory", [a1 + frame("mic", pcm(MIC_BYTES, 3), stream=0) + a3],
         ["f", "bad_stream", "f"]),
        ("mic_with_flags", "accessory", [a1 + frame("mic", pcm(MIC_BYTES, 3), flags=4, stream=1) + a3],
         ["f", "bad_flags", "f"]),
        ("empty_control", "accessory", [a1 + frame("control", b"", flags=3, seq=1) + a3], ["f", "bad_length", "f"]),
        ("diagnostics_on_call_stream", "accessory", [a1 + frame("diagnostics", b"x", stream=1) + a3],
         ["f", "bad_stream", "f"]),
        ("host_stream", "host", [h1 + h2 + h3], ["f", "f", "f"]),
        ("mic_from_host", "host", [h1 + frame("mic", pcm(MIC_BYTES, 3), stream=1) + h3],
         ["f", "wrong_direction", "f"]),
        ("odd_speaker_frame", "host", [h1 + frame("speaker", b"\x00\x00\x00", stream=1) + h3],
         ["f", "bad_length", "f"]),
        ("oversized_speaker_frame", "host", [h1 + frame("speaker", pcm(3842, 7), stream=1) + h3],
         ["f", "bad_length", "f"]),
    ]
    # Timed cases: each chunk arrives at its time; an empty chunk is the
    # receiver's tick with nothing new to read.
    false_length = stretched(a3, 2000)
    timed = [
        ("false_length_times_out_while_synced", "accessory", [a1 + false_length, b"", b"", a2], [0, 999, 1000, 1001],
         ["f", "frame_timeout", "f"]),
        ("false_length_times_out_silently_while_hunting", "accessory", [false_length, b"", a1], [0, 1000, 1001],
         ["f"]),
        ("frame_completed_at_the_bound", "accessory", [a2[:500], a2[500:]], [0, 1000], ["f"]),
        ("stall_clock_restarts_after_progress", "accessory", [a1 + a2[:500], a2[500:] + a3[:10], b"", a3[10:]],
         [0, 900, 1800, 1899], ["f", "f", "f"]),
    ]
    rows = []
    for name, sender, chunks, expected in cases:
        rows.append(corpus_row(name, sender, chunks, [0] * len(chunks), expected))
        if name == "stretched_length_recovers_what_follows":
            # The same stream split at irregular points, so a reader proves its
            # parser does not depend on where reads end.
            whole = b"".join(chunks)
            cuts = [0, 1, 17, 18, 999, 1000, 2019, 2020, 2021, len(whole)]
            split = [whole[cuts[i]:cuts[i + 1]] for i in range(len(cuts) - 1)]
            assert parse(split, sender) == parse(chunks, sender)
            rows.append(corpus_row(name + "_split", sender, split, [0] * len(split), expected))
    for name, sender, chunks, times_ms, expected in timed:
        rows.append(corpus_row(name, sender, chunks, times_ms, expected))
    return {"stall_ms": STALL_MS, "cases": rows}


def corpus_row(name, sender, chunks, times_ms, expected):
    events, resync, pending = parse(chunks, sender, times_ms)
    shape = ["f" if "frame" in e else e["fault"] for e in events]
    assert shape == expected, (name, shape)
    return {"name": name, "from": sender, "chunks": [c.hex() for c in chunks], "times_ms": times_ms,
            "events": events, "resync_bytes": resync, "pending_bytes": pending}


def reassembly_fixture():
    big = control({"type": "diag.chunk", "gen": 3, "source": "log", "chunk": 1, "last": False,
                   "data": "61" * 3000})
    p = [big[:2000], big[2000:4000], big[4000:]]
    cases = [
        ("single", [(3, 0, 10, b"{}")], ["m"]),
        ("three_fragments", [(1, 0, 10, p[0]), (0, 0, 11, p[1]), (2, 0, 12, p[2])], ["m"]),
        ("urgent_single", [(7, 2, 4294967295, b"{}"), (3, 0, 0, b"[]")], ["m", "m"]),
        ("gap_between_messages", [(3, 0, 10, b"{}"), (3, 0, 12, b"{}")], ["m", "control_seq_gap"]),
        ("gap_inside_message", [(1, 0, 10, p[0]), (2, 0, 12, p[2])], ["control_seq_gap"]),
        ("start_while_open", [(1, 0, 10, p[0]), (1, 0, 11, p[0])], ["fragment_sequence"]),
        ("middle_without_start", [(0, 0, 10, p[1])], ["fragment_sequence"]),
        ("end_without_start", [(2, 0, 10, p[2])], ["fragment_sequence"]),
        ("stream_changes_inside_message", [(1, 0, 10, p[0]), (2, 1, 11, p[2])], ["fragment_stream"]),
        ("over_8_kib", [(1, 0, 0, b"x" * 4096), (0, 0, 1, b"x" * 4096), (2, 0, 2, b"x")], ["control_too_large"]),
        ("exactly_8_kib", [(1, 0, 0, b"x" * 4096), (2, 0, 1, b"x" * 4096)], ["m"]),
        ("rebases_after_a_fault", [(0, 0, 10, p[1]), (3, 0, 99, b"{}")], ["fragment_sequence", "m"]),
        # A control frame with seq 0 starts a new sequence (a sender that
        # opened the link again): no gap, any partial message dropped, no fault.
        ("seq_zero_after_a_gap_rebases", [(3, 0, 41, b"{}"), (3, 0, 0, b"[]")], ["m", "m"]),
        ("seq_zero_drops_an_open_message", [(1, 0, 7, p[0]), (3, 0, 0, b"[]")], ["m"]),
        ("seq_zero_then_counts_on", [(3, 0, 41, b"{}"), (3, 0, 0, b"{}"), (3, 0, 2, b"{}")],
         ["m", "m", "control_seq_gap"]),
        ("a_wrap_inside_a_message_drops_it", [(1, 0, 4294967295, p[0]), (2, 0, 0, p[2])],
         ["fragment_sequence"]),
    ]
    rows = []
    for name, frames, expected in cases:
        r = Reassembler()
        for flags, stream, seq, payload in frames:
            r.feed(flags, stream, seq, payload)
        shape = ["m" if "message" in e else e["fault"] for e in r.events]
        assert shape == expected, (name, shape)
        rows.append({"name": name,
                     "frames": [dict(payload_field(pl), flags=f, stream=s, seq=q) for f, s, q, pl in frames],
                     "events": [compact_event(e) for e in r.events]})
    return {"cases": rows}


def payload_field(payload):
    # A payload of one repeated byte is written as a fill, so the 64 KiB cases
    # stay small: {"fill": {"byte": 120, "count": 4096}} is 4,096 bytes of "x".
    if len(payload) > 64 and len(set(payload)) == 1:
        return {"fill": {"byte": payload[0], "count": len(payload)}}
    return {"payload": payload.hex()}


def compact_event(event):
    if "message" not in event:
        return event
    message = event["message"]
    return {"message": dict(payload_field(bytes.fromhex(message["payload"])), stream=message["stream"])}


OVER_CAP_PREFIX = '{"type":"pong","gen":7,"uptime_ms":1,"pad":"'


def messages(keys, attach, enroll):
    host, acc = keys["host"], keys["accessory"]
    a = attach["vectors"][0]
    af = a["fields"]
    e = enroll["vectors"][0]
    ef = e["fields"]
    attempt = attempt_id("first")
    state = {"battery": 87, "power": "usb", "brownout": False, "volume": 60, "brightness": 80,
             "motion": "ready", "calibration": "valid"}
    host_messages = [
        {"type": "hello", "gen": af["gen"], "wire_min": 1, "wire_max": 1, "host_id": host["id"],
         "host_nonce": af["host_nonce"], "caps": af["host_caps"]},
        {"type": "host_proof", "gen": af["gen"], "sig": a["host_sig"]},
        {"type": "ping", "gen": 7},
        {"type": "refuse", "gen": 7, "code": "unknown_accessory"},
        {"type": "refuse", "gen": 7, "code": "wire_version", "wire_min": 2, "wire_max": 3},
        {"type": "error", "gen": 7, "code": "unknown_message", "message_type": "head.spin"},
        {"type": "enroll.begin", "gen": 2, "attempt": attempt, "round": 1, "host_pk": host["public"],
         "host_id": host["id"], "host_commit": e["host_commit"]},
        {"type": "enroll.reveal", "gen": 2, "attempt": attempt, "round": 1, "host_nonce": ef["host_nonce"]},
        {"type": "enroll.commit", "gen": 2, "attempt": attempt, "round": 1, "host_sig": e["host_sig"]},
        {"type": "enroll.cancel", "gen": 2, "attempt": attempt, "reason": "mismatch_limit"},
        {"type": "call.start", "gen": 7, "stream": 1, "call": "4b1f3c2e-9a7d-4e15-b6c8-0d2f4a6e8b13"},
        {"type": "call.result", "gen": 7, "request": 12, "result": "accepted"},
        {"type": "call.result", "gen": 7, "request": 13, "result": "refused", "code": "call_in_progress"},
        {"type": "call.state", "gen": 7, "stream": 1, "state": "listening"},
        {"type": "call.state", "gen": 7, "stream": 1, "state": "speaking"},
        {"type": "call.end", "gen": 7, "stream": 1, "reason": "call_stop"},
        {"type": "call.end", "gen": 7, "stream": 1},
        {"type": "mute.set", "gen": 7, "stream": 1, "muted": True},
        {"type": "check.tone", "gen": 7},
        {"type": "check.mic", "gen": 7, "seconds": 3},
        {"type": "check.face", "gen": 7, "pose": "speaking"},
        {"type": "check.motion", "gen": 7, "gesture": "nod"},
        {"type": "check.stop", "gen": 7},
        {"type": "accessory.calibrate", "gen": 7, "op": "begin"},
        {"type": "accessory.calibrate", "gen": 7, "op": "nudge", "axis": "tilt", "steps": -4},
        {"type": "accessory.calibrate", "gen": 7, "op": "set_zero"},
        {"type": "spk.begin", "gen": 7, "stream": 1, "segment": 1, "playback_id": None},
        {"type": "spk.begin", "gen": 7, "stream": 1, "segment": 2, "playback_id": "p17"},
        {"type": "spk.end", "gen": 7, "stream": 1, "segment": 2},
        {"type": "spk.flush", "gen": 7, "stream": 1},
        {"type": "task.event", "gen": 7, "stream": 1, "task": "rt:1", "revision": 1, "status": "running",
         "in_chat": False},
        {"type": "task.event", "gen": 7, "stream": 1, "task": "d-5e0c", "revision": 2, "status": "completed",
         "in_chat": True},
        {"type": "voice.readiness", "gen": 7, "ready": False, "code": "missing_key"},
        {"type": "voice.readiness", "gen": 7, "ready": True},
        {"type": "accessory.set", "gen": 7, "volume": 40},
        {"type": "accessory.set", "gen": 7, "motion": False, "brightness": 55},
        {"type": "accessory.forget", "gen": 7},
        {"type": "diag.fetch", "gen": 7, "source": "log", "chunk": 0},
    ]
    accessory_messages = [
        {"type": "hello_ack", "gen": af["gen"], "wire": 1, "kind": "stackchan", "accessory_id": acc["id"],
         "firmware": "0.1.0", "pack": hashlib.sha256(b"fixture-pack").hexdigest(), "caps": af["accessory_caps"],
         "accessory_nonce": af["accessory_nonce"], "sig": a["accessory_sig"]},
        {"type": "hello_ack", "gen": 2, "wire": 1, "kind": "stackchan", "accessory_id": None,
         "firmware": "0.1.0", "pack": None, "caps": 0x7F, "accessory_nonce": nonce("unenrolled"), "sig": None},
        {"type": "attached", "gen": af["gen"], "state": state},
        {"type": "pong", "gen": 7, "uptime_ms": 81234},
        {"type": "refuse", "gen": 7, "code": "unknown_host"},
        {"type": "error", "gen": 7, "code": "not_now", "message_type": "check.mic"},
        {"type": "enroll.offer", "gen": 2, "attempt": attempt, "round": 1, "accessory_pk": acc["public"],
         "accessory_nonce": ef["accessory_nonce"]},
        {"type": "enroll.confirmed", "gen": 2, "attempt": attempt, "round": 1, "sig": e["accessory_sig"]},
        {"type": "enroll.done", "gen": 2, "attempt": attempt, "accessory_id": acc["id"]},
        {"type": "enroll.cancel", "gen": 2, "attempt": attempt, "reason": "owner"},
        {"type": "call.request", "gen": 7, "request": 12, "source": "screen_tap"},
        {"type": "call.request", "gen": 7, "request": 14, "source": "head_swipe"},
        {"type": "call.end_request", "gen": 7, "stream": 1},
        {"type": "mic.state", "gen": 7, "stream": 1, "state": "live"},
        {"type": "mic.state", "gen": 7, "stream": 1, "state": "off", "reason": "mic_backlog"},
        {"type": "check.level", "gen": 7, "rms": 1210},
        {"type": "check.result", "gen": 7, "check": "mic", "result": "ok"},
        {"type": "check.result", "gen": 7, "check": "motion", "result": "fault", "code": "servo_timeout"},
        {"type": "credit", "gen": 7, "stream": 1, "bytes": 8192},
        {"type": "playback.progress", "gen": 7, "stream": 1, "playback_id": "p17", "played_ms": 420,
         "drained": False},
        {"type": "spk.drained", "gen": 7, "stream": 1, "segment": 2},
        {"type": "spk.flushed", "gen": 7, "stream": 1, "segment": 2, "played_ms": 380},
        {"type": "spk.flushed", "gen": 7, "stream": 1, "played_ms": 0},
        {"type": "accessory.state", "gen": 7, **dict(state, battery=None, power="battery", motion="off",
                                                      calibration="calibrating")},
        {"type": "diag.counters", "gen": 7, "counters": {"uptime_s": 3600, "frames_rx": 912, "frames_tx": 180004,
                                                         "crc_errors": 0, "resync_bytes": 77, "pcm_seq_gaps": 0,
                                                         "mic_overflows": 0, "spk_underflows": 2}},
        # The latest microphone opening's levels, all six beside the counters.
        {"type": "diag.counters", "gen": 7, "counters": {"uptime_s": 52, "frames_rx": 33, "frames_tx": 1296,
                                                         "crc_errors": 0, "resync_bytes": 0, "pcm_seq_gaps": 0,
                                                         "mic_overflows": 0, "spk_underflows": 0},
         "mic_rms": 188, "mic_peak": 507, "ref_rms": 0, "ref_peak": 3, "out_rms": 731, "out_peak": 2014},
        {"type": "diag.fault", "gen": 7, "code": "event_queue_overflow"},
        {"type": "diag.chunk", "gen": 7, "source": "log", "chunk": 0, "last": True, "data": "4920283831322920"},
    ]
    invalid = [
        ("accessory", 0, '{"type":"head.spin","gen":7}', "unknown_message"),
        ("accessory", 0, '{"type":"hello","gen":7,"wire_min":1,"wire_max":1,"host_id":"' + host["id"]
         + '","host_nonce":"' + af["host_nonce"] + '","caps":127}', "unknown_message"),
        ("host", 0, '{"type":"pong","gen":7,"uptime_ms":1}', "unknown_message"),
        ("accessory", 0, '{"type":"pong","uptime_ms":1}', "invalid_message:gen"),
        ("accessory", 0, '{"type":"pong","gen":0,"uptime_ms":1}', "invalid_message:gen"),
        ("accessory", 0, '{"type":"pong","gen":4294967296,"uptime_ms":1}', "invalid_message:gen"),
        ("accessory", 0, '{"type":"pong","gen":7,"uptime_ms":-1}', "invalid_message:uptime_ms"),
        ("accessory", 0, '{"type":"pong","gen":7,"uptime_ms":1.5}', "invalid_message:uptime_ms"),
        ("accessory", 1, '{"type":"credit","gen":7,"stream":1,"bytes":8193}', "invalid_message:bytes"),
        ("accessory", 1, '{"type":"credit","gen":7,"stream":1,"bytes":"8"}', "invalid_message:bytes"),
        ("accessory", 0, '{"type":"enroll.offer","gen":2,"attempt":"' + attempt + '","round":1,"accessory_pk":"'
         + acc["public"].upper() + '","accessory_nonce":"' + ef["accessory_nonce"] + '"}',
         "invalid_message:accessory_pk"),
        ("accessory", 0, '{"type":"hello_ack","gen":7,"wire":1,"kind":"stackchan","accessory_id":"' + acc["id"]
         + '","firmware":"0.1.0","pack":null,"caps":127,"accessory_nonce":"' + af["accessory_nonce"]
         + '","sig":null}', "invalid_message:sig"),
        ("accessory", 0, '{"type":"hello_ack","gen":7,"wire":1,"kind":"StackChan","accessory_id":null,'
         '"firmware":"0.1.0","pack":null,"caps":127,"accessory_nonce":"' + af["accessory_nonce"] + '","sig":null}',
         "invalid_message:kind"),
        ("accessory", 0, '{"type":"mic.state","gen":7,"stream":1,"state":"live"}', "wrong_stream"),
        ("accessory", 2, '{"type":"mic.state","gen":7,"stream":1,"state":"live"}', "wrong_stream"),
        ("accessory", 1, '{"type":"pong","gen":7,"uptime_ms":1}', "wrong_stream"),
        ("accessory", 1, '{"type":"mic.state","gen":7,"stream":1,"state":"loud"}', "invalid_message:state"),
        ("accessory", 0, '{"type":"pong","gen":7,"gen":8,"uptime_ms":1}', "invalid_json"),
        ("accessory", 0, '{"type":"pong","gen":7,"uptime_ms":1', "invalid_json"),
        ("accessory", 0, '[{"type":"pong"}]', "invalid_json"),
        ("accessory", 0, '"pong"', "invalid_json"),
        ("accessory", 0, '{"type":7,"gen":7}', "invalid_message:type"),
        ("accessory", 0, '{"gen":7}', "invalid_message:type"),
        ("accessory", 0, '{"type":"pong","gen":7,"uptime_ms":1,"x":[[[[[[[[1]]]]]]]]}', "invalid_json"),
        ("host", 0, '{"type":"accessory.set","gen":7}', "invalid_message:volume"),
        ("host", 0, '{"type":"accessory.calibrate","gen":7,"op":"nudge","axis":"pan"}', "invalid_message:steps"),
        ("host", 0, '{"type":"accessory.calibrate","gen":7,"op":"nudge","axis":"pan","steps":0}',
         "invalid_message:steps"),
        ("host", 0, '{"type":"accessory.calibrate","gen":7,"op":"begin","axis":"pan"}', "invalid_message:axis"),
        ("host", 0, '{"type":"call.result","gen":7,"request":3,"result":"refused"}', "invalid_message:code"),
        ("host", 0, '{"type":"refuse","gen":7,"code":"wire_version"}', "invalid_message:wire_min"),
        ("host", 0, '{"type":"hello","gen":7,"wire_min":2,"wire_max":1,"host_id":"' + host["id"]
         + '","host_nonce":"' + af["host_nonce"] + '","caps":127}', "invalid_message:wire_max"),
        ("host", 1, '{"type":"spk.begin","gen":7,"stream":1,"segment":1,"playback_id":"has space"}',
         "invalid_message:playback_id"),
        ("host", 0, '{"type":"enroll.begin","gen":2,"attempt":"' + attempt + '","round":1,"host_pk":"'
         + host["public"] + '","host_id":"' + host["id"] + '","host_nonce":"' + ef["host_nonce"] + '"}',
         "invalid_message:host_commit"),
        # One byte over the 8,192-byte cap, whatever it says.
        ("accessory", 0, OVER_CAP_PREFIX + "p" * (MAX_MESSAGE + 1 - len(OVER_CAP_PREFIX) - 2) + '"}',
         "invalid_json"),
    ]
    assert len(invalid[-1][2]) == MAX_MESSAGE + 1
    # A field the receiver does not know is ignored, so an additive optional
    # field needs no wire version.
    accessory_messages.append({"type": "pong", "gen": 7, "uptime_ms": 5, "temperature_c": 41})
    # Eight levels deep, the bound: the object is the first level.
    accessory_messages.append({"type": "pong", "gen": 7, "uptime_ms": 6, "x": [[[[[[[1]]]]]]]})
    return host_messages, accessory_messages, [
        {"sender": s, "stream": st, "payload": p, "error": err} for s, st, p, err in invalid
    ]


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def write_jsonl(path, rows):
    path.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--check", action="store_true", help="compare with --out and write nothing")
    args = parser.parse_args()
    check_rfc6979()
    if args.check:
        with tempfile.TemporaryDirectory() as scratch:
            write_all(Path(scratch))
            sys.exit(compare(Path(scratch), args.out))
    args.out.mkdir(parents=True, exist_ok=True)
    write_all(args.out)
    print(f"wrote the accessory fixtures to {args.out}")


def compare(fresh, committed):
    names = sorted({p.name for p in fresh.iterdir()} | {p.name for p in committed.iterdir()})
    stale = [n for n in names if not ((fresh / n).is_file() and (committed / n).is_file()
                                      and filecmp.cmp(fresh / n, committed / n, shallow=False))]
    for name in stale:
        print(f"differs from what this script writes: {committed / name}", file=sys.stderr)
    if not stale:
        print(f"the fixtures in {committed} are current")
    return 1 if stale else 0


def write_all(out):
    keys = keys_fixture()
    attach = attach_fixture(keys["keys"])
    enroll = enroll_fixture(keys["keys"])
    host_messages, accessory_messages, invalid = messages(keys["keys"], attach, enroll)
    write_json(out / "crc32.json", crc_fixture())
    write_json(out / "frames.json", frames_fixture())
    write_json(out / "stream_corpus.json", corpus_fixture())
    write_json(out / "reassembly.json", reassembly_fixture())
    write_json(out / "keys.json", keys)
    write_json(out / "attach.json", attach)
    write_json(out / "enroll.json", enroll)
    write_jsonl(out / "host_messages.jsonl", host_messages)
    write_jsonl(out / "accessory_messages.jsonl", accessory_messages)
    write_jsonl(out / "invalid_messages.jsonl", invalid)


if __name__ == "__main__":
    main()
