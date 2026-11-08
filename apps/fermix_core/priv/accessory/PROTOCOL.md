# The Fermix accessory link

The wire between the Fermix daemon and a paired Fermix accessory: a physical
device paired with one Fermix home that carries the owner's voice and, by
capability, a screen, a pet, touch, motion and a battery. The first kind is
`stackchan` (the M5Stack K151 running the `fermix-stackchan` firmware). Phase A
carries the link over the accessory's USB-Serial-JTAG CDC port; later phases
carry the same frames inside a mutual-TLS WebSocket (Wi-Fi) or an L2CAP stream
(Bluetooth LE), one frame per message or in the byte stream, unchanged.

**Source of truth:** the `FermixCore.Accessories` modules in `fermix_core`
(`Frame`, `Parser`, `Reassembler`, `Control`, `Capabilities`, `P256`,
`Transcript`, `Attach`, `Enrollment`, `Store`). This file,
`control.schema.json` and `fixtures/` are the contract's export;
`accessories/protocol_contract_test.exs` holds them to the modules. The
firmware vendors this directory byte for byte as `contracts/accessory/`, and
the macOS app as `Resources/Contracts/accessory`; neither hand-copies a shape.
`scripts/dev/accessory_fixtures.py` writes the fixtures from an implementation
of this document that shares no code with the daemon's; with `--check` it
writes nothing and fails when the committed fixtures differ from what it would
write.

The words *host* (the Fermix daemon) and *accessory* (the device) name the two
ends throughout. Every message, field and code is named for accessories, never
for one kind.

## Byte order and encodings

- Integers in frame headers and transcripts are **little-endian**, at the
  widths given. The one exception is the compare code (*Enrollment*), which
  reads the first four bytes of a SHA-256 digest as a **big-endian** integer.
- Binary values inside JSON are **lowercase hex**, two digits per byte, with no
  prefix. There is no base64 anywhere on this wire.
- A public key is a P-256 point in SEC1 **uncompressed** form, 65 bytes
  (`04 ‖ X ‖ Y`, each coordinate 32 bytes big-endian), 130 hex digits.
- An **accessory ID** is SHA-256 of the accessory's 65-byte public key, 64 hex
  digits; a **host ID** is SHA-256 of the host's public key, the same way. An
  ID shown to a person is its first 16 hex digits in four groups of four,
  separated by spaces.
- A signature is ECDSA over P-256 with SHA-256 (the signer hashes the message;
  nothing is pre-hashed), encoded **raw**: `r ‖ s`, each 32 bytes big-endian,
  zero-padded on the left, 64 bytes, 128 hex digits, written with
  `mbedtls_mpi_write_binary(r, 32)` and `(s, 32)` and no ASN.1. A verifier
  accepts any valid signature, including both `s` and `n − s`, and refuses `r`
  or `s` outside `[1, n − 1]`.
- **Every accessory signature is deterministic ECDSA (RFC 6979, SHA-256)**:
  `mbedtls_ecdsa_sign_det_ext` with `MBEDTLS_MD_SHA256`, never the randomized
  `mbedtls_ecdsa_sign`. ECDSA's per-signature secret `k` gives the private key
  away when two signatures share it or when its values are related, and the
  ESP32-S3's random source is true-random only while a radio or the SAR-ADC
  entropy source runs; Phase A keeps both radios off. A host may ask for one
  signature per HELLO for as long as the cable is attached, so `k` must not
  depend on that source: RFC 6979 derives it from the key and the message. The
  same key becomes the accessory's TLS identity in Phase B. The fixtures'
  signatures are RFC 6979, so a firmware signer reproduces them byte for byte.
  The host signs through OpenSSL with its own random source; a verifier cannot
  tell the two apart.
- A nonce is 32 bytes from the sender's cryptographic random source. On the
  accessory that means with an entropy source enabled while it draws them.

## Framing

Every byte on the link belongs to a frame. Serial reads are fragments of a byte
stream, never frame boundaries.

| Offset | Size | Field | Rule |
|---|---|---|---|
| 0 | 2 | magic | `46 58` (`"FX"`). |
| 2 | 1 | version | Framing version, `1`. |
| 3 | 1 | type | `1` control (JSON), `2` microphone PCM, `3` speaker PCM, `4` diagnostics. |
| 4 | 1 | flags | Bit 0 `START`, bit 1 `END`, bit 2 `URGENT`; bits 3–7 are `0`. |
| 5 | 1 | reserved | `0`. |
| 6 | 2 | stream | u16. `0` is the link; `1`–`65535` is a call's stream. |
| 8 | 4 | seq | u32, per sender and per type (*Sequence numbers*). |
| 12 | 4 | length | u32, payload bytes, at most **4,096**. |
| 16 | n | payload | As the type requires. |
| 16 + n | 4 | crc32 | u32, CRC-32 over bytes `0 … 15 + n` (header and payload). |

A frame is at most 4,116 bytes. The CRC is CRC-32/ISO-HDLC, the one zlib,
Ethernet and `:erlang.crc32/1` compute: polynomial `0x04C11DB7` reflected
(`0xEDB88320`), initial value `0xFFFFFFFF`, reflected in and out, final XOR
`0xFFFFFFFF`. `fixtures/crc32.json` has vectors with the value and its four
bytes as they appear on the wire.

### Frame types

| Type | Name | Sent by | Flags | Stream | Payload |
|---|---|---|---|---|---|
| 1 | control | both | any of `START`, `END`, `URGENT` | `0`, or a call's stream | 1–4,096 bytes of one control message or a fragment of one |
| 2 | microphone PCM | accessory | none | a call's stream | exactly **960** bytes: 20 ms of 24 kHz mono PCM16, little-endian samples |
| 3 | speaker PCM | host | none | a call's stream | even, **2–3,840** bytes (at most 80 ms) |
| 4 | diagnostics | accessory | none | `0` | 1–4,096 bytes of a debug build's own output |

A release accessory never sends type 4, and a host counts and discards it. The
host never sends it. A control message that fits in one frame has `START` and
`END` both set (flags `3`). `URGENT` asks the sender's own queue to send the
frame ahead of every unsent audio frame; it changes nothing on the receiver.
The host sends `spk.flush`, `mute.set`, `call.end` and `check.stop` with
`URGENT`.

### Sequence numbers

Each sender keeps one counter per frame type. It starts at `0` when the sender
opens the link (the host when it opens the port, the accessory at boot or when
USB appears), goes up by one per frame of that type, and wraps from
`4,294,967,295` to `0`. A receiver takes the first frame of each type after a
reset (a HELLO sent or received, or any receive fault) as its base, and
expects `previous + 1` after that:

- a gap in microphone or speaker PCM is counted and reported in
  `diag.counters` (`pcm_seq_gaps`), and the audio is used;
- a gap in control frames is the fault `control_seq_gap` (*Reassembly*);
- **a control frame with seq `0` starts a new sequence**: the receiver drops
  any partial message and rebases on it, and no fault is counted. A sender
  that opened the link again (a restarted daemon or a new link process on a
  port the accessory kept, a rebooted accessory) numbers its control frames
  from `0` while its peer still holds the old base, so its first HELLO is
  never lost to `control_seq_gap`.

## Receiving

The receive side is an incremental parser over a bounded buffer. It trusts a
frame's length only as far as waiting for its bytes: until the CRC checks, the
frame proves nothing, and a CRC failure discards one byte, not the claimed
length, so frames inside a corrupted length are found again. The normative
algorithm, which `Parser` and the fixture generator both implement:

```
state: buffer B; synced S (false at the start and after every fault);
       scanned K (bytes discarded since the last good frame);
       waiting W (when B last changed at its head, or unset)

on bytes read at time t (an empty read is the receiver's tick):
  append them to B
  scan
  if B is empty: W = unset; done
  if scan dropped or consumed any byte, or W is unset: W = t
  if t − W ≥ 1,000 ms: discard(1, frame_timeout); scan; W = t

scan, repeating while it makes progress:
  if B does not start with "FX":
      n = offset of the next "FX" in B, or else |B| (less one if B ends in "F")
      if n = 0: wait for more bytes
      discard(n, bad_magic)
  else if |B| < 16: wait
  else if the header is implausible (checks below, in order): discard(1, that reason)
  else if |B| < 20 + length: wait
  else if the CRC does not match: discard(1, crc_mismatch)
  else:
      consume the frame; S = true; K = 0
      if the frame breaks a rule of its type (below): report that fault (S stays true)
      else: deliver the frame

discard(n, reason):
  if S: report reason; S = false
  report resync_limit once for each multiple of 8,192 that K crosses as it grows by n
  drop n bytes
```

So everything before the first good frame (a ROM banner, line noise) is
discarded silently and counted; after a good frame, any byte that is not one
is a fault. Faults found before the CRC are reported only while synced; a
fault found after it is always reported, since the CRC proved the frame came
from the peer. The buffer never holds more than one frame (4,116 bytes) between
reads.

**Stalls.** A plausible header with a false length would hold the parser,
waiting for bytes the peer never sends, while an idle link exchanges nothing
else. So held bytes that do not change at their head for **one second** are a
stalled frame: one byte is discarded (`frame_timeout` while synced, silently
while hunting, counted in the discarded bytes either way) and the rest are
read again. A real frame of at most 4,116 bytes takes a few milliseconds on the
cable, and its bytes may take the whole second. Each end reads with a tick of
its own (an empty read at least every 250 ms) so a stall is found with nothing
arriving. Starting the link again (a new HELLO, sent or received) drops the
held bytes, counted as discarded, and the parser hunts afresh; its counters
carry on. A sender that starts the link again after opening it anew sends that
HELLO with control seq `0`, which starts a new sequence at the receiver
(*Reassembly*): the HELLO is read at once, with no fault.

Plausibility, before the CRC, in this order: `frame_version` (version is not
1), `unknown_frame_type` (type is not 1–4), `bad_flags` (a bit 3–7 is set),
`bad_reserved` (reserved is not 0), `over_cap` (length over 4,096).

Type rules, after the CRC, in this order: `wrong_direction` (a type the
receiver's peer never sends: the host receives 1, 2 and 4; the accessory 1 and
3), `bad_flags` (any flag on a type 2, 3 or 4 frame), `bad_stream` (PCM on
stream 0, diagnostics on a call stream), `bad_length` (an empty control or
diagnostics payload, microphone PCM that is not 960 bytes, speaker PCM that is
odd, empty or over 3,840 bytes).

Every fault ends the link: the host tears down the authenticated session and
any call, reports the reason with its count, and sends a new HELLO, which
restores an idle link; the parser keeps hunting for the next good frame
meanwhile. `resync_limit` is the fault for 8 KiB scanned without a good frame.
Nothing is skipped silently once the link is up. `fixtures/stream_corpus.json`
holds streams, split as a serial read might split them, with the frames,
faults, discarded byte count and leftover bytes each must produce.

## Reassembly

A control message larger than one frame travels as a `START` frame, any number
of frames with neither flag, and an `END` frame, contiguous among the sender's
control frames (PCM frames may come between them). Messages of wire version 1
all fit in one frame; the reassembly exists so an additive field never needs a
new framing. The receiver:

1. starts a new sequence on a control frame with `seq` `0`: it drops any
   partial message and the expected `seq`, counts no fault, and reads the
   frame as the first of the new sequence. So a wrap from `4,294,967,295` to
   `0` inside a fragmented message drops that message (its rest, read as the
   start of the new sequence, is `fragment_sequence`); every message of wire
   version 1 is one frame;
2. faults `control_seq_gap` when any other control frame's `seq` is not the
   previous control frame's plus one (modulo 2³²);
3. faults `fragment_sequence` on a `START` while a message is open, or on a
   frame without `START` while none is;
4. faults `fragment_stream` when a fragment's stream differs from its
   message's;
5. faults `control_too_large` when a message would pass **8,192** bytes;
6. delivers the message, with its stream, on its `END`.

A fault drops the open message and the expected `seq`, so the next control
frame starts a new base. `fixtures/reassembly.json` holds frame sequences and
what each delivers.

## Control messages

A control message is one JSON object, UTF-8, at most **8,192** bytes in
either direction, nested at most **8** containers deep (the message object is
the first, so a field's array is the second), with no key repeated in any
object. Every message of wire version 1 fits in one frame (the largest, a full
`diag.chunk`, is about 3.2 KB); the cap leaves the accessory's 16 KiB JSON
parse arena room for the largest message a later version may add. Its `type` names the message; `gen` is the connection generation,
an integer `1 … 4,294,967,295`, and every message carries it. A message that
has a `stream` field travels in frames on that stream; every other message
travels on stream 0.

The set is closed per sender (*Message reference*, `control.schema.json`). A
receiver answers a message outside its peer's set with `error {code:
"unknown_message", message_type}`, and one whose fields break the reference
with `error {code: "invalid_message", message_type}`; it counts both and acts
on neither. Payloads that are not such an object (`invalid_json`) and messages
on the wrong stream (`wrong_stream`) are answered the same way, as
`invalid_message`. A field the receiver does not know is ignored, so an
additive optional field needs no new wire version.

Every message from the host carries the generation of the HELLO that opened
the link; a message from the accessory echoes it. Each end drops a message of
another generation. A call-scoped message carries the call's stream, and each
end drops one for a stream that is not the call's. Task events also carry the
task and its revision. The accessory drops an event whose revision is older
than the newest it saw for that task and, within one revision, an event that
does not move the status forward: `running` comes first, and a settled status
(`completed`, `failed` or `cancelled`) ends that revision.

`fixtures/host_messages.jsonl` and `fixtures/accessory_messages.jsonl` hold
valid messages of each sender, one per line; `fixtures/invalid_messages.jsonl`
holds payloads each receiver must refuse, with the frame stream they arrived
on and the error (`unknown_message`, `invalid_message:<field>` naming the
first field that fails, `invalid_json`, `wrong_stream`).

## Capabilities

Both ends send a capability bit set (`caps`, u32) in the HELLO exchange. The
accessory sets what its hardware and firmware have; the host sets what it can
drive. A capability is in use only when both ends set it. A receiver ignores
bits it does not know, so a new capability needs no new wire version.

| Bit | Name | The accessory has | The host can drive |
|---|---|---|---|
| 0 | `mic` | 24 kHz mono PCM16 microphone frames, with a mic-live indicator it controls | the microphone |
| 1 | `speaker` | 24 kHz mono PCM16 playback with speaker credit and playback progress | the speaker |
| 2 | `screen` | a display | presentation |
| 3 | `touch` | touch input (`call.request` sources) | touch |
| 4 | `pet` | the embedded Fermix pet | the pet |
| 5 | `motion` | head motion (calibration, `check.motion`, gestures) | motion |
| 6 | `battery` | a battery it reports in `accessory.state` | battery reports |
| 7 | `wake_word` | defined, never set in M91 | never set |
| 8 | `link_update` | reserved for updates over the link (M91 D25); never set | never set |

The host of wire version 1 sends bits 0–6 (`0x7F`). A voice accessory must
report `mic` and `speaker`, or the host refuses it with
`capability_missing`. The host sends no message whose capability the
accessory did not report (`check.tone`, `spk.*`: `speaker`; `check.mic`,
`mute.set`: `mic`; `check.face`: `screen`; `check.motion`,
`accessory.calibrate` and `accessory.set`'s `motion` field: `motion`), and the
app offers a kind's controls only for reported capabilities. The bits are
inside the attach transcript, so nothing between the two ends can change them.

## Versioning

- **Framing version** (the header's byte 2) is `1` for the life of this
  transport. It is not negotiated: a peer that cannot read version 1 frames
  cannot attach, and its port reads as one that gives no Fermix answer.
- **Wire version** is the message set, negotiated in HELLO. The host sends the
  inclusive range it speaks (`wire_min`, `wire_max`); the accessory picks the
  highest version it speaks inside it and names it in `hello_ack.wire`, or
  answers `refuse {code: "wire_version", wire_min, wire_max}` with its own
  range. The host compares the ranges to say which side to update: an
  accessory whose range is wholly below the host's needs its firmware updated;
  one wholly above, Fermix. The current wire version is **1**, and the host's
  window is `[1, 1]` (`x-wire-version`, `x-supported-wire-range` in the
  schema).
- A new message type, a new required field, a new value of a closed set
  (`enum`) or a change of meaning is a new wire version. An additive optional
  field or a new capability bit is not.
- **Rollout order:** the daemon ships first, adding version `N + 1` while it
  keeps every version a released accessory speaks; the firmware follows. A
  firmware never requires a version the released daemon lacks. Rolling back
  runs the other way: the firmware returns to `N` before the daemon drops it.

## Opening the port (host only)

The host opens the accessory's USB-Serial-JTAG port exclusively (another
program gets "port busy" instead of sharing the bytes), in raw mode, and
without resetting the chip. The controller can reset the chip from the host's
control lines, so the order in which the host sets DTR and RTS at open is part
of this contract:

- **Never clear DTR while RTS is asserted.**
- Two sequences were measured safe on a K151 (A0, 100 open and close cycles
  each, 0 resets): *rts-first*, which leaves DTR as the OS sets it at open,
  clears RTS, then clears DTR; and *pyserial's default*, which sets DTR, then
  sets RTS. Presetting both lines low, so that DTR is cleared first while RTS
  is still asserted, reset the chip on every one of 100 opens (reset reason
  USB).
- After opening, the host leaves the lines alone. The accessory never reads
  them: it knows the host is there from USB start-of-frame and from HELLO and
  heartbeats.
- The host opens only the port the owner selected while pairing, or one whose
  USB serial string matches an enrolled accessory's `port_hint` (the K151
  reports its MAC there, the same across replugs). The vendor and product IDs
  (`303A:1001`) are shared by every board on this controller and identify
  nothing. A port that does not answer as a Fermix accessory within the
  attach bound ends the step. Identity comes only from the attach proofs.
- Before any firmware install the host releases the port, since an open port
  blocks the installer.

## Attach

On every attach (the accessory plugged in, or the daemon starting with it
attached), the two ends exchange HELLO and two signatures over one transcript
before any audio, call or accessory control. The host verifies the accessory
against its enrollment record (M91 D11); the accessory verifies the host
against the host public key it stored at enrollment (D14). There is no TLS on a
cable; Phase B's mutual TLS uses the same two keys as the two identities.

```
host       -> accessory:  hello { gen, wire_min, wire_max, host_id, host_nonce, caps }
                          an enrolled accessory checks host_id against the host ID it stored
                          and, if they differ, answers refuse { unknown_host } without signing
accessory  -> host:       hello_ack { gen, wire, kind, accessory_id, firmware, pack, caps,
                                      accessory_nonce, sig }      (sig: the accessory's signature)
                          host checks gen, wire, kind, caps, the record, then sig
host       -> accessory:  host_proof { gen, sig }                  (sig: the host's signature)
                          accessory checks the host ID it stored and sig
accessory  -> host:       attached { gen, state }
```

An unenrolled accessory answers `hello_ack` with `accessory_id` and `sig` both
`null`, and can then only enroll. The host numbers generations: each HELLO
carries a new `gen`, and the transcript includes it, so both signatures are
bound to this attach. The host sends at most one `hello` a second, and the
accessory honours at most one per 500 ms; each honoured `hello` costs the
accessory one deterministic signature (*Byte order and encodings*).

### The attach transcript

| Offset | Size | Field |
|---|---|---|
| 0 | 30 | `"FERMIX-ACCESSORY-USB-ATTACH-v1"` (ASCII, no terminator) |
| 30 | 32 | host ID (the raw digest) |
| 62 | 32 | accessory ID (the raw digest) |
| 94 | 32 | `host_nonce` |
| 126 | 32 | `accessory_nonce` |
| 158 | 2 | wire version, u16 (`hello_ack.wire`) |
| 160 | 4 | host capabilities, u32 (`hello.caps`) |
| 164 | 4 | accessory capabilities, u32 (`hello_ack.caps`) |
| 168 | 4 | `gen`, u32 |
| 172 | 1 | kind length *k*, 1–16 |
| 173 | *k* | kind (ASCII) |

The accessory signs it with its enrolled key (`hello_ack.sig`); the host signs
the same bytes with its host key (`host_proof.sig`). The fixed domain string
keeps either signature from serving as an enrollment signature or as a TLS 1.3
handshake signature made with the same key.

### What the host checks, in order

| Check | Refusal (`refuse.code`) |
|---|---|
| `gen` is the open challenge's | none: a stale message is dropped and the challenge stays open |
| the challenge is still open (one answer per challenge) | `stale_generation` |
| within 10 s of the HELLO | `auth_timeout` |
| `wire` inside the host's window | `wire_version` |
| `kind` is one the host knows (`stackchan`) | `unsupported_kind` |
| the accessory reports `mic` and `speaker` | `capability_missing` |
| `accessory_id` is not `null` | none: an unenrolled accessory, which may only enroll |
| an enrollment record names `accessory_id` | `unknown_accessory` |
| `sig` verifies over the transcript with the record's public key | `bad_proof` |

Any answer closes the challenge, refused or not: nonces are single-use and die
with the 10-second deadline, and an old `hello_ack` replayed on a later attach
fails its signature, since the later transcript has a new nonce and
generation. A forgotten accessory fails here, before any provider session. The
accessory refuses with `unknown_host` at the `hello` (a `host_id` other than
the one it stored, checked before it signs anything), `bad_proof` (the host's
signature fails) or `auth_timeout`, keeps its microphone closed, and stays
detached.

## Enrollment

Pairing happens over the cable the owner selects, with the owner at the
accessory. The host enrolls a key only when the accessory holding it signed
the enrollment transcript and the owner confirmed in the app that both screens
show the same compare code. The host commits to its nonce before it sees the
accessory's and reveals it only after, so neither end's nonce can be chosen
knowing the other's: something on the cable that substitutes its own keys in
both directions gets two codes that agree by chance only, one in a million
each round, and at most three rounds an attempt.

```
host       -> accessory:  enroll.begin { gen, attempt, round, host_pk, host_id, host_commit }
                          host_commit = SHA-256(host_nonce); the nonce stays on the host
                          the accessory asks "Pair with this Mac?"; the owner taps it;
                          the accessory makes its keypair if it has none
accessory  -> host:       enroll.offer { gen, attempt, round, accessory_pk, accessory_nonce }
host       -> accessory:  enroll.reveal { gen, attempt, round, host_nonce }
                          the accessory checks SHA-256(host_nonce) = host_commit, or cancels
                          with invalid_reveal and shows no code; then both ends show the
                          six-digit compare code
accessory  -> host:       enroll.confirmed { gen, attempt, round, sig }   (only after the owner taps Matches)
                          the owner confirms the same code in the app
host       -> accessory:  enroll.commit { gen, attempt, round, host_sig }
                          the accessory verifies host_sig, burns its key-protection eFuse on a
                          first enrollment, stores the host key and its own in one commit
accessory  -> host:       enroll.done { gen, attempt, accessory_id }
                          the host writes the accessory's record
```

### The enrollment transcript and the compare code

| Offset | Size | Field |
|---|---|---|
| 0 | 30 | `"FERMIX-ACCESSORY-USB-ENROLL-v1"` (ASCII) |
| 30 | 65 | host public key |
| 95 | 65 | accessory public key |
| 160 | 32 | `host_nonce` |
| 192 | 32 | `accessory_nonce` |

The **compare code** is the first four bytes of SHA-256 of the transcript read
as a big-endian u32, modulo 1,000,000, written as six decimal digits with
leading zeros. Thirty-two bits keep the code close to uniform; twenty would
make the low codes twice as likely.

`enroll.confirmed.sig` is the accessory's signature over the enrollment
transcript, proving it holds the key it offered; `enroll.commit.host_sig` is
the host's. `enroll.begin.host_id` is SHA-256 of `host_pk`, and
`enroll.done.accessory_id` SHA-256 of `accessory_pk`; each end checks.

### Bounds

- One attempt open at a time, named by `attempt` (16 random bytes, 32 hex
  digits), for at most **120 seconds** from its first `enroll.begin` until
  the host sends `enroll.commit`. From the commit on, neither end runs the
  window: the accessory may be burning its eFuse and writing its keys, and
  the link's own bounds (heartbeats, USB loss) end the attempt if it goes. The
  accessory stops its own 120-second clock when it receives the commit.
- An attempt has at most **three** comparison rounds. When the owner says the
  codes differ, the round fails; the host starts the next with a new
  `enroll.begin` (`round` + 1, a new commitment to a new `host_nonce`), the
  accessory answers with a new `accessory_nonce`, and the host reveals the new
  nonce, so each round shows a new code. A third failed round closes the
  attempt (`mismatch_limit`).
- `enroll.cancel {reason}` from either end closes the attempt: `owner` (Cancel
  on the accessory or in the app), `expired`, `mismatch_limit`,
  `invalid_offer`, `invalid_reveal` (the accessory's: a `host_nonce` whose
  SHA-256 is not the round's `host_commit`) or `link_reset`. The host closes
  with `invalid_offer` for an offered key that is not a P-256 point or is the
  host's own, an `enroll.confirmed` whose signature does not verify with the
  offered key, and an `enroll.done` whose `accessory_id` is not that key's
  SHA-256. Closing on USB loss needs no message. A closed attempt writes
  nothing.
- The host refuses an offer of its own public key.
- The host writes the record only on `enroll.done`. An accessory that committed
  but whose record the host failed to write is refused `unknown_accessory` at
  its next attach and offers to forget its side.

### Forget

`accessory.forget` on an attached accessory erases its keys and returns it to
unenrolled; the host erases the record in the same step. An accessory
forgotten while unplugged learns at its next attach (`unknown_accessory`).

## Calls

The host admits one owner-voice call per home across every engine and endpoint
(`priv/realtime/PROTOCOL.md`, *One call at a time*); an accessory's calls are
the endpoint `accessory:<accessory_id>`.

```
accessory  -> host:       call.request { gen, request, source }    (a tap or a head swipe)
host       -> accessory:  call.result { gen, request, result, code? }
host       -> accessory:  call.start { gen, stream, call }         (an admitted request, or a start from the Mac)
host       -> accessory:  call.state { gen, stream, state: "connecting" }
                          the accessory opens its codec input, mic gate closed
host       -> accessory:  call.state { gen, stream, state: "listening" }
                          the accessory draws the mic-live mark, then opens the gate
accessory  -> host:       mic.state { gen, stream, state: "live" } and microphone PCM, continuously
…
accessory  -> host:       call.end_request { gen, stream }          (or the host ends it)
host       -> accessory:  call.end { gen, stream, reason? }
```

- The microphone is off between calls. Capture starts at the host's
  `listening` and streams continuously, silence included, while an unmuted call
  is active. Attached or connected never means the microphone is ready.
- `request` is the accessory's own counter, `1 … 4,294,967,295`.
  `call.result.code`, when refused, uses the Realtime error vocabulary
  (`call_in_progress`, `voice_not_ready`, `update_required` and the like).
- A call has a stream ID from `call.start`; its PCM and call-scoped messages
  use it. The host does not reuse a stream ID on one link.
- `call.state.state` is one of `connecting`, `listening`, `thinking`,
  `speaking`, `muted`, `reconnecting`.
- Mute works on the accessory without the host: it closes the gate at once and
  reports `mic.state {state: "muted"}`. `mute.set` is the Mac's mute.
  `mic.state` is `live`, `muted` or `off`, with a `reason` when the accessory
  closed it itself (`mic_backlog` for a microphone ring that overflowed for 500
  ms, which ends the call).
- The host aggregates five microphone frames into the Realtime session's 100
  ms, 4,800-byte input chunk.

## Speaker and credit

The host never sends speaker PCM beyond the accessory's credit.

- **Credit.** `credit {stream, bytes}` grants `bytes` more. Credit is *used*
  by speaker PCM received on the wire: each type 3 frame's payload bytes, as
  they arrive, whether or not they have played. Outstanding credit (granted
  and not yet used) never passes **8,192** bytes; a grant that would pass it is
  answered `error {code: "credit_overgrant"}` and the host ends the call. The
  accessory grants while its ring's fill plus outstanding credit is under 400
  ms (19,200 bytes). A call's stream starts with no credit. A speaker byte
  past outstanding credit is a host bug: the accessory flushes the stream and
  answers `error {code: "credit_exceeded"}`, and the call ends.
- **Segments.** Audio comes in segments: `spk.begin {stream, segment,
  playback_id}`, speaker frames, `spk.end {stream, segment}`. `segment` is 1
  for a stream's first and one more for each `spk.begin` after it. A segment
  takes audio from its `spk.begin` to its `spk.end`, and only one takes audio
  at a time. It is *open* from its `spk.begin` until it drains (the accessory
  answers `spk.drained {segment}` once its last sample has played) or a flush
  closes it. At most **8** are open.
- **Segment faults end the call.** The accessory discards the audio or
  message, answers `error`, and the host ends the call (`call.end {reason}`
  with the same code), since each is a host bug: `segment_limit` for a ninth
  open segment's `spk.begin`; `segment_sequence` for speaker PCM while no
  segment takes audio, a `spk.begin` while one still does or with the wrong
  number, and a `spk.end` for a segment that is not taking audio.
- **Flush.** An interrupt is `spk.flush {stream}` (`URGENT`): the accessory
  drops all queued audio and answers `spk.flushed {stream, segment?,
  played_ms}` with the segment that was playing and what of it played; the
  host passes that on as the engine's interrupt. A flush closes every open
  segment: none counts toward the 8 afterwards, and no `spk.drained` follows
  for any of them. Outstanding credit is unchanged by a flush.
- **Progress.** `playback_id` is the Grok engine's id
  (`priv/realtime/PROTOCOL.md`, *Playback feedback*), or `null`. For a
  non-null id the accessory reports `playback.progress {stream, playback_id,
  played_ms, drained}` from consumed samples, at most every 100 ms and at once
  on drain or flush; `played_ms` never decreases. The host sends no
  progress-bearing id on an OpenAI call.
- Playback starts after a 120 ms prebuffer; the accessory's ring is one
  second. Everything else, Grok's send-ahead included, waits on the host.

## Tasks

`task.event {stream, task, revision, status, in_chat}` drives the accessory's
task reactions, the same on every engine (M91 D21):

- From a GPT-Live or Grok `task` frame: `task` is its `delegation_id`,
  `revision` its revision, `status` its status (`pending` is sent as
  `running`), `in_chat` whether it names a chat row (`server_seq`). The frame
  that detaches a task at the end of a call is not sent: the call is over.
- From OpenAI Realtime's ID-less `tool_event`s, one task per tool batch: the
  first `running` while no batch is open starts task `rt:<n>` (call-local,
  revision 1) as `running`; later calls join it; it settles when its last open
  call settles, `completed` when every call completed and `failed` when any
  errored; a provider reconnect while it is open settles it `cancelled`.
  `in_chat` is always `false`. A `completed` or `error` with no open batch is a
  contract fault the host logs and counts; it never opens a batch. Tool names
  and error reasons stay on the host.

`status` is `running`, `completed`, `failed` or `cancelled`. The accessory
shows one reaction per task and revision, and never a success for a task that
reached `cancelled` or `failed`.

## Setup checks and calibration

Only on an attached accessory with no call. `check.tone` plays a tone;
`check.mic {seconds}` (1–10) reports `check.level {rms}` while it runs, with
levels only (no audio leaves the accessory, and the mic-live mark stays off);
`check.face {pose}` shows a named pose; `check.motion {gesture}` runs a named
gesture; `check.stop` ends any check. Each ends with `check.result {check,
result, code?}`. `accessory.calibrate {op}` is the Calibrate head step:
`begin`, `nudge {axis, steps}` (`pan` or `tilt`, `−64 … 64`, not zero),
`set_zero` or `cancel`; progress and outcome arrive in `accessory.state
{calibration}`, and the accessory writes the result only to its own settings.
A check or calibration outside those conditions is answered `error {code:
"not_now"}`.

## State and settings

`accessory.state` (also `attached.state`) reports `battery` (percent, or
`null` without the `battery` capability or a reading), `power` (`usb`,
`battery`, `low`, `critical`), `brownout` (a brownout this boot), `volume` and
`brightness` (0–100), `motion` (`absent` without the capability, `off`,
`homing`, `ready`, `paused`, `fault`) and `calibration` (`absent`, `missing`,
`valid`, `calibrating`, `failed`). The accessory sends it on any change.
`accessory.set` changes `volume`, `motion` (on or off) or `brightness`, at
least one. `voice.readiness {ready, code?}` says whether a call can start
(`code` as the Realtime refusal names it: `voice_disabled`, `missing_key`,
`restart_required`, `needs_local_primary`).

## Diagnostics

`diag.counters` every 10 s and at a call's end, with the accessory's counters
since boot. `diag.fault {code}` names a fault the accessory hit.
`diag.fetch {source, chunk}` asks for one chunk of the accessory's log ring or
core dump, and `diag.chunk {source, chunk, last, data}` answers with at most
1,536 bytes. Diagnostics never carry raw audio, transcripts or credentials.

## Timing bounds

| Bound | Value | At the bound |
|---|---|---|
| Attach | 10 s from the port opening (the host: from its `hello`) to both signatures verified | `auth_timeout`; the host sends a new HELLO |
| HELLO rate | the host sends at most one `hello` a second; the accessory honours at most one per 500 ms | the accessory drops a faster one |
| Heartbeat outside a call | the host pings every 5 s | three missed (15 s with no frame from the peer) is link loss, either end |
| Heartbeat in a call | the host pings every 1 s | the accessory closes its gate, flushes its speaker and ends the call after 3 s with no host frame |
| Call start | the accessory waits 15 s from `call.start` for `listening` | it ends the call and returns to attached |
| Enrollment | 120 s per attempt until the host's `enroll.commit`, three rounds | `expired`, `mismatch_limit` |
| Microphone ring | one second; an overflow held 500 ms | the call ends, `mic.state {reason: "mic_backlog"}` |
| Speaker credit | 8,192 bytes outstanding | `credit_overgrant`, `credit_exceeded` |
| Open segments | 8 | `segment_limit`; the call ends |
| Playback progress | at most every 100 ms; at once on drain and flush | |
| Resynchronisation | 8,192 bytes scanned without a good frame | `resync_limit` |
| Stalled frame | held bytes unchanged at their head for 1 s; each end ticks its parser at least every 250 ms | `frame_timeout` |
| Control message | 8,192 bytes, 8 containers deep | `control_too_large`, `invalid_json` |
| Port busy (host) | five opens, 1, 2, 4, 8 and 15 s apart | the app shows Port busy and waits for Retry |

Re-attaching restores an idle link only: it never replays microphone audio, a
reaction, a tool action or an old `call.start`. A revoked accessory, a failed
signature and a protocol fault are not retried.

## Message reference

Every message has `type` and `gen`. Types: *int a–b* is an integer in that
range; *hex n* is exactly *n* bytes as hex; *token n* is `[a-z][a-z0-9_]*`, at
most *n* characters; *text n* is 1–*n* printable ASCII characters with no
space; `?` marks an optional field. Messages with a `stream` field travel on
that stream; the rest on stream 0.

### Host to accessory

| `type` | Fields | |
|---|---|---|
| `hello` | `wire_min`, `wire_max` (int 1–65535, `wire_min ≤ wire_max`), `host_id` (hex 32), `host_nonce` (hex 32), `caps` (int 0–2³²−1) | Opens the attach; a new `gen`. |
| `host_proof` | `sig` (hex 64) | The host's attach signature. |
| `ping` | | Heartbeat. |
| `refuse` | `code`, `wire_min?`, `wire_max?` (required when `code` is `wire_version`) | Ends the attach. |
| `error` | `code`, `message_type?` (text 32) | A message it refused. |
| `enroll.begin` | `attempt` (hex 16), `round` (int 1–3), `host_pk` (hex 65), `host_id` (hex 32), `host_commit` (hex 32: SHA-256 of the round's `host_nonce`) | |
| `enroll.reveal` | `attempt`, `round`, `host_nonce` (hex 32) | After the round's `enroll.offer`. |
| `enroll.commit` | `attempt`, `round`, `host_sig` (hex 64) | |
| `enroll.cancel` | `attempt`, `reason` | |
| `call.start` | `stream` (int 1–65535), `call` (text 64) | |
| `call.result` | `request` (int 1–2³²−1), `result` (`accepted` \| `refused`), `code?` (token 48, required when refused) | |
| `call.state` | `stream`, `state` | |
| `call.end` | `stream`, `reason?` (token 48) | |
| `mute.set` | `stream`, `muted` (bool) | |
| `check.tone` | | |
| `check.mic` | `seconds` (int 1–10) | |
| `check.face` | `pose` (token 32) | |
| `check.motion` | `gesture` (token 32) | |
| `check.stop` | | |
| `accessory.calibrate` | `op` (`begin` \| `nudge` \| `set_zero` \| `cancel`), `axis?` (`pan` \| `tilt`), `steps?` (int −64–64, not 0) | `axis` and `steps` exactly when `op` is `nudge`. |
| `spk.begin` | `stream`, `segment` (int 1–2³²−1: 1, then one more each), `playback_id` (text 64 or `null`) | |
| `spk.end` | `stream`, `segment` | |
| `spk.flush` | `stream` | |
| `task.event` | `stream`, `task` (text 64), `revision` (int 1–2³²−1), `status`, `in_chat` (bool) | |
| `voice.readiness` | `ready` (bool), `code?` (token 48) | |
| `accessory.set` | `volume?`, `brightness?` (int 0–100), `motion?` (bool) | At least one. |
| `accessory.forget` | | |
| `diag.fetch` | `source` (`log` \| `coredump`), `chunk` (int 0–65535) | |

### Accessory to host

| `type` | Fields | |
|---|---|---|
| `hello_ack` | `wire` (int 1–65535), `kind` (token 16), `accessory_id` (hex 32 or `null`), `firmware` (text 32), `pack` (hex 32 or `null`: the pet pack's SHA-256), `caps` (int 0–2³²−1), `accessory_nonce` (hex 32), `sig` (hex 64 or `null`) | `sig` is `null` exactly when `accessory_id` is. |
| `attached` | `state` (the fields of `accessory.state`) | |
| `pong` | `uptime_ms` (int 0–2⁵³−1) | |
| `refuse` | `code`, `wire_min?`, `wire_max?` | |
| `error` | `code`, `message_type?` | |
| `enroll.offer` | `attempt`, `round`, `accessory_pk` (hex 65), `accessory_nonce` (hex 32) | |
| `enroll.confirmed` | `attempt`, `round`, `sig` (hex 64) | Only after the owner taps Matches. |
| `enroll.done` | `attempt`, `accessory_id` (hex 32) | |
| `enroll.cancel` | `attempt`, `reason` | |
| `call.request` | `request`, `source` (`screen_tap` \| `head_swipe`) | |
| `call.end_request` | `stream` | |
| `mic.state` | `stream`, `state` (`live` \| `muted` \| `off`), `reason?` (token 48) | |
| `check.level` | `rms` (int 0–32767) | |
| `check.result` | `check` (`tone` \| `mic` \| `face` \| `motion`), `result` (`ok` \| `fault`), `code?` (token 48) | |
| `credit` | `stream`, `bytes` (int 1–8192) | |
| `playback.progress` | `stream`, `playback_id` (text 64), `played_ms` (int 0–2³²−1), `drained` (bool) | |
| `spk.drained` | `stream`, `segment` | |
| `spk.flushed` | `stream`, `segment?`, `played_ms` | |
| `accessory.state` | `battery`, `power`, `brownout`, `volume`, `brightness`, `motion`, `calibration` | |
| `diag.counters` | `counters`: `uptime_s`, `frames_rx`, `frames_tx`, `crc_errors`, `resync_bytes`, `pcm_seq_gaps`, `mic_overflows`, `spk_underflows` (each int 0–2³²−1) | |
| `diag.fault` | `code` (token 48) | |
| `diag.chunk` | `source`, `chunk`, `last` (bool), `data` (1–1,536 bytes as hex) | |

### Closed codes

| Field | Values |
|---|---|
| `refuse.code` | `wire_version`, `unknown_accessory`, `unknown_host`, `bad_proof`, `capability_missing`, `unsupported_kind`, `auth_timeout`, `stale_generation` |
| `error.code` | `unknown_message`, `invalid_message`, `not_now`, `capability_missing`, `credit_overgrant`, `credit_exceeded`, `segment_limit`, `segment_sequence` |
| `enroll.cancel.reason` | `owner`, `expired`, `mismatch_limit`, `invalid_offer`, `invalid_reveal`, `link_reset` |
| `call.state.state` | `connecting`, `listening`, `thinking`, `speaking`, `muted`, `reconnecting` |
| `task.event.status` | `running`, `completed`, `failed`, `cancelled` |

## Fixtures

| File | Holds |
|---|---|
| `crc32.json` | CRC-32 inputs, values and their wire bytes |
| `frames.json` | Frames with their fields, payload and full encoding |
| `stream_corpus.json` | Byte streams as read, each chunk with the time it arrives (`times_ms`; an empty chunk is a tick), with the frames, faults, discarded and leftover bytes each produces, and the stall bound (`stall_ms`) |
| `reassembly.json` | Control frame sequences with the messages and faults each produces; a payload of one repeated byte is written `{"fill": {"byte", "count"}}` |
| `keys.json` | The fixture keys: seed, private scalar, public key and ID, and how a seed becomes a key |
| `attach.json` | Attach transcripts from their fields, both signatures, and signatures that must and must not verify |
| `enroll.json` | Enrollment transcripts, the host nonce's commitment, their digests and compare codes, and both signatures |
| `host_messages.jsonl`, `accessory_messages.jsonl` | Valid messages of each sender |
| `invalid_messages.jsonl` | Payloads each receiver refuses, with their stream and error |

The fixture keys are derived from invented seeds and are public: never use
them outside tests. The signatures are deterministic (RFC 6979), so a signer
built with deterministic ECDSA reproduces them; any valid signature passes.
