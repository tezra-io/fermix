# Fermix meetbot sidecar protocol

The wire contract between the Fermix daemon and the `fermix-meetbot` sidecar — a
Node/Playwright process that joins a Google Meet as a signed-in bot account and
streams the meeting's audio and roster back.

**Source of truth:** `FermixCore.Meetings.Sidecar.Frame`
(`lib/fermix_core/meetings/sidecar/frame.ex`). This file and `fixtures/*` are the
machine-readable export of that module, and `protocol_contract_test.exs` asserts
they never drift from it. The `tezra-io/fermix-meetbot` repo **vendors this file
and the fixtures** rather than hand-copying the shapes — that is the single
coordination point across the two independently-released repos.

Fermix defines the protocol; the sidecar implements it.

## Transport

- **Channel:** the sidecar's stdin/stdout, spawned by the daemon as an Erlang
  Port. Nothing is listened on and no socket is opened — the sidecar is not
  reachable from anywhere but its parent.
- **Framing:** `{:packet, 4}` — every frame is preceded by a 4-byte big-endian
  unsigned length, in both directions. A frame is
  `<<type::8, payload::binary>>`.
- **stderr is not part of the channel.** The daemon does not merge it into
  stdout: a single diagnostic byte written to the data channel would be read as
  part of a length prefix and desync every frame after it. Diagnostics travel as
  `log` control frames.

| Type byte | Meaning | Payload | Max payload bytes | Direction |
|---|---|---|---|---|
| `0x01` | control | UTF-8 JSON object with a `"type"` string | 65536 | both |
| `0x02` | audio | raw PCM s16le, 16 kHz, mono | 32768 | sidecar → daemon |

Any other type byte, an oversized payload, an odd-length audio payload, a
non-JSON control payload, or an unknown control `"type"` is a **protocol
error**: the daemon tears the sidecar down and reports it. There is no
skip-and-continue — a dropped frame silently desyncs the clock below.

## Clock

Audio frames carry no timestamp. The cumulative sample count of the audio
stream, counted from the first audio frame, **is** the shared clock:

```
t_ms = samples / 16          # 16 kHz mono, 2 bytes per sample
```

Every `t_ms` the sidecar puts in a control frame (today only `active_speaker`)
MUST equal `samples_sent_before_this_event / 16`. The daemon's own receive-side
sample counter is authoritative; speaker attribution is computed against it, so
a sidecar that derives `t_ms` from wall-clock time will produce transcripts
attributed to the wrong people.

## Versioning

A single integer, `protocol_version`, currently **1**. The sidecar declares it
in `hello`; the daemon refuses anything but its own version and tears down. There
is no negotiation window — the sidecar binary is pinned by the fermix build that
downloads it, so both halves ship together.

## Control messages, sidecar → daemon

```json
{"type":"hello","protocol_version":1,"sidecar_version":"0.1.0","platforms":["meet"]}
{"type":"state","phase":"joining"}
{"type":"join_result","status":"admitted"}
{"type":"roster","participants":[{"id":"p_ab12","name":"Ada Lovelace"}]}
{"type":"active_speaker","id":"p_ab12","t_ms":123456}
{"type":"chat_posted"}
{"type":"meeting_ended","reason":"host_removed"}
{"type":"error","code":"page_crash","message":"<sidecar detail>"}
{"type":"log","level":"info","message":"..."}
{"type":"pong"}
```

| Message | Enumerations | Semantics |
|---|---|---|
| `hello` | — | MUST be the first frame, within 15 s of spawn. |
| `state` | `phase`: `joining`, `knocking`, `leaving` | Join-choreography progress. |
| `join_result` | `status`: `admitted`, `denied`, `login_required`, `signin_required`, `bot_blocked`, `knock_timeout` | Sent exactly once. |
| `roster` | — | A **full snapshot** on every membership change, and once right after `admitted`. Never a delta. Capped at 200 entries. |
| `active_speaker` | — | Emitted on change only, with `t_ms` on the shared clock. |
| `chat_posted` | — | The consent announcement landed in the meeting chat. |
| `meeting_ended` | `reason`: `host_removed`, `meeting_closed`, `left` | The bot is out of the meeting. |
| `error` | — | Terminal: the sidecar exits within 2 s of sending it. |
| `log` | `level`: `debug`, `info`, `warn`, `error` | Forwarded to the daemon's logger prefixed `meetbot: `, never parsed. |
| `pong` | — | Answer to `ping`. |

## Control messages, daemon → sidecar

```json
{"type":"join","platform":"meet","url":"https://meet.google.com/abc-defg-hij",
 "passcode":null,"bot_name":"Fermix Notetaker","announce":true,
 "announce_message":"👋 Fermix Notetaker here — …","profile_dir":"/…/plugins/meetbot/profile"}
{"type":"leave"}
{"type":"ping"}
```

- `join` is sent exactly once, immediately after a successful handshake (and
  once more after a pre-admission relaunch, with the identical payload).
- The daemon **never** sends account credentials, cookies, or API keys over this
  wire. The bot account's signed-in state lives entirely in the Chromium profile
  at `profile_dir`, which the sidecar owns and the daemon never reads inside.
- `ping` is sent only after 30 s with no inbound frame of any type. If no frame
  arrives within 15 s of a `ping`, the sidecar is considered wedged and is torn
  down — a hung Chromium holds the port open indefinitely, so silence is the
  only detectable symptom.

## Lifecycle

1. **Handshake.** The daemon spawns the sidecar and waits for `hello`. A
   different first frame, a version mismatch, or 15 s of silence ends in
   teardown and a typed error; the sidecar is never left running.
2. **Join.** The daemon sends `join`. The sidecar reports `state` transitions
   and exactly one `join_result`.
3. **Capture.** On `admitted` the sidecar posts the announcement (when
   `announce` is true), emits a `roster` snapshot, and streams audio frames plus
   `active_speaker` / `roster` updates.
4. **Leave.** On `leave` the sidecar leaves and reports
   `meeting_ended`/`reason:"left"`, then exits 0.
5. **stdin EOF.** The sidecar MUST leave the meeting (best-effort) and exit
   within 2 s. Daemon death therefore always removes the bot from the meeting.
6. **Teardown.** The daemon closes stdin, waits 2 s for the exit, then SIGKILLs
   the sidecar's **process group** — the port child is a group leader, so
   Playwright's Chromium descendants die with it. There is no SIGTERM step; EOF
   is the polite path and the group kill is the guarantee.

## Reserved

`{"type":"signin"}` (daemon → sidecar) is reserved for the interactive bot
sign-in flow, which launches the sidecar headed so an operator can sign the bot
account in. It is not implemented in v1 and deliberately absent from
`known_types/1` and the fixtures.

## Fixtures

- `fixtures/control_frames.jsonl` — one JSON object per line,
  `{"dir":"s2d"|"d2s","frame":{…}}`, covering every control message type with
  representative payloads. Both halves test against these bytes.
- `fixtures/audio_frame.bin` — one valid `0x02` payload: 3200 bytes, i.e.
  100 ms of a 440 Hz sine at 16 kHz s16le.
