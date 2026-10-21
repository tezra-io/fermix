# Fermix Realtime voice socket protocol

The wire contract between the Fermix daemon and the FermixPet macOS companion.

**Source of truth:** `FermixCore.Realtime.Protocol` (`lib/fermix_core/realtime/protocol.ex`).
This file, `protocol.schema.json`, and `fixtures/*.jsonl` are the machine-readable
export of that module. `protocol_contract_test.exs` asserts they never drift from
it. A downstream consumer (e.g. `fermix-macos`) **vendors the schema and fixtures
pinned by checksum** rather than hand-copying the shapes — that is the single
coordination point across the two independently-released repos.

## Transport

- **Socket:** a Unix-domain stream socket at `$FERMIX_HOME/realtime.sock`
  (default `~/.fermix/realtime.sock`), mode `0600`, owned by the daemon.
- **Framing:** newline-delimited JSON. Each frame is one JSON object followed by
  a single `\n`. There is no length prefix; a line exceeding the daemon's wire
  cap is rejected with `error: line_too_large` and the connection is closed.
- **Direction:** *client events* flow pet → daemon; *server events* flow
  daemon → pet.

## Versioning

The protocol is versioned by a single integer, `protocol_version`. The daemon
advertises the inclusive range `{min_version, max_version}` it accepts:
`max_version` is the current version, and `min_version` is the oldest version a
released pet may still speak, so a daemon that has moved to `N+1` keeps serving
older pets. The floor is held at `1` on purpose: a v1 pet still runs
`openai_realtime`. Raising it is a release decision of its own, never a side
effect of a version bump.

Current values (see the schema's `x-protocol-version` / `x-supported-version-range`):

| Field | Value |
|---|---|
| `protocol_version` (pet declares) | `3` |
| daemon `min_version` | `1` |
| daemon `max_version` | `3` |

Unknown fields are ignored by older peers, so an additive optional field does
not need a version bump.

### The version each engine requires

The handshake admits every version in the window, but a call needs the version
its engine's frames were added in. A pet older than that is refused at
`call_start`, before any session starts, so an old pet never opens a paid
provider session it cannot render:

| Engine | Minimum `protocol_version` | An older pet at `call_start` |
|---|---|---|
| `openai_realtime` | `1` | — |
| `openai_live` | `2` | refused, `required_for: "openai_live"` |
| `xai_realtime` | `3` | refused, `required_for: "xai_realtime"` |

The refusal is

```json
{"type":"error","reason":"unsupported_protocol_version","kind":"update_required",
 "direction":"client_too_old","client_version":1,"min_version":2,"max_version":3,
 "required_for":"openai_live"}
```

and the connection closes — no session is started. `min_version` in **this**
refusal is the version the configured engine requires, not the handshake floor
the daemon advertises in `server_hello` (1); `required_for` names the engine that
raised it. The handshake itself still succeeds for an older pet, so the refusal
arrives at `call_start`, where the engine is known.

### Version 2 — the Live engine

Version 2 adds the frames the `openai_live` engine needs: `task_cancel` from the
pet, and `call_ready`, `caption` and `task` from the daemon, plus extra fields on
`usage` and `error`. A **v1 pet may still run the Realtime engine** against a
newer daemon, and nothing in the Realtime path changed.

### Version 3 — the Grok engine

Version 3 adds the `xai_realtime` engine: SpaceXAI's Grok Voice, which hands
every task to the Fermix agent as `openai_live` does (both are the *task
engines*), and the playback feedback it needs. Grok's turn detection runs on the
provider, and an interrupted reply has to be cut at what the operator actually
heard, so the daemon must know how much of each reply has played: every
`audio_delta` of a Grok call carries a `playback_id`, and the pet answers with
`playback_progress` (see *Playback feedback*). A Grok call otherwise uses the v2
frames (`call_ready`, `caption`, `task`, `task_cancel`), and `usage` adds
`voice_text_items`.

A v1 or v2 pet keeps running the OpenAI engines unchanged: no frame of an
OpenAI call carries `playback_id`, and `playback_progress` is refused there with
`error: unsupported_by_engine`. A v2 pet on a daemon configured for
`xai_realtime` is refused at `call_start`:

```json
{"type":"error","reason":"unsupported_protocol_version","kind":"update_required",
 "direction":"client_too_old","client_version":2,"min_version":3,"max_version":3,
 "required_for":"xai_realtime"}
```

## Handshake state machine

The connection opens with a **mandatory, one-shot handshake**. No other event is
serviced until it completes.

```
pet: connect socket
pet  -> daemon:  client_hello { protocol_version: P }
                 daemon negotiates P against {min, max}:
                   P in [min, max]   -> daemon -> pet: server_hello { min_version, max_version }
                   P < min           -> daemon -> pet: error(unsupported_protocol_version, client_too_old); close
                   P > max           -> daemon -> pet: error(unsupported_protocol_version, client_too_new); close
pet: on server_hello, validate its own version V in [min_version, max_version]:
       in range -> connected
       out of range -> refuse; report which side must update
```

Rules the daemon enforces:

1. Any client event other than `client_hello` received **before** a successful
   handshake is rejected with `error: handshake_required` and the connection is
   closed.
2. A second `client_hello` after the handshake has completed is rejected with
   `error: unexpected_client_hello` and the connection is closed. The handshake
   is a single transition, not a re-negotiable state.

Rules the pet enforces:

3. The pet does **not** consider itself connected until it has received *and
   validated* the daemon's `server_hello`. A version outside the advertised range
   surfaces a directional message (update the pet, or update Fermix) rather than a
   generic "offline" flicker.
4. Unrecognized server events are logged, never silently dropped.

## Direction of an unsupported version

`error(unsupported_protocol_version)` carries `direction`, `client_version`,
`min_version`, and `max_version` so the pet can tell the user which component to
update without re-deriving it:

- `client_too_old` — the pet speaks a version below the daemon's floor → **update
  the pet**.
- `client_too_new` — the pet speaks a version above the daemon's ceiling → **update
  Fermix**.

## Rollout / rollback order

Because the daemon and the pet ship from separate repos on independent cadences,
a version bump must land in a fixed order so the two are never mutually
unintelligible:

1. **Daemon first.** Ship a daemon that *adds* support for `N+1` while keeping
   every version a released pet still speaks. Never remove support for a version
   a released pet still requires.
2. **Pet second.** Only after that daemon is released, ship a pet that speaks
   `N+1`. A pet must never require a version the released daemon lacks.
3. **Rollback** is the reverse: roll the pet back to `N` before dropping `N` from
   the daemon.

The `protocol_version` constant plus the cross-version compatibility tests are the
enforced coordination point; a paired wire change touches `protocol.ex` (daemon)
and `CompanionState.swift` (pet) together.

## Client events (pet → daemon)

| `type` | Fields | Notes |
|---|---|---|
| `client_hello` | `protocol_version` (int > 0, required) | First frame. Opens the handshake. |
| `call_start` | — | Begins a voice call; starts the realtime session. Requires a completed handshake. |
| `audio_chunk` | `audio` (base64 PCM16, required) | Mic audio. Decoded size is capped by `[fermix_core.realtime] max_chunk_bytes`. |
| `interrupt` | `audio_end_ms` (int ≥ 0, optional) | Barge-in; `audio_end_ms` is how much of the assistant's audio actually played. |
| `mute` | `enabled` (bool, default `true`) | Mutes/unmutes capture. |
| `call_stop` | — | Ends the active call and closes the session. |
| `task_cancel` | `delegation_id` (non-empty string, required) | **v2.** Cancels one backend delegation of a task-engine call (`openai_live`, `xai_realtime`). Under `openai_realtime` it is refused with `error: unsupported_by_engine` and the connection closes. |
| `playback_progress` | `playback_id` (non-empty string ≤ 64 bytes, required), `played_ms` (int ≥ 0, required), `drained` (bool, required) | **v3**, `xai_realtime` only. How much of one playback id's audio the pet has rendered (see *Playback feedback*). Under the OpenAI engines it is refused with `error: unsupported_by_engine` and the connection closes. |

## Client audio

`audio_chunk` carries the microphone as the provider will hear it: the daemon
relays it untouched. A client streams 24 kHz mono PCM16 in 100 ms chunks from
`listening` to the end of the call, silence included, and before sending it:

- **cancels echo and suppresses noise.** GPT-Live's session takes no noise,
  echo or voice-detection settings, and Realtime's server-side noise reduction
  runs after the pet's own voice is already in the microphone. The macOS app
  uses Apple's voice processing (`AVAudioInputNode.setVoiceProcessingEnabled`);
  a Linux client needs the same from its audio stack, such as PipeWire's
  echo-cancel module, with the pet's playback routed through it as the echo
  reference.
- **reads the processed channel.** With voice processing on, macOS delivers
  several channels (six from a two-channel USB microphone) and the processed
  voice is channel 0; a converter left to mix them to mono produces digital
  silence.

Echo cancellation can still fail on a route: display speakers over HDMI play
about 90 ms later than they report. So under `openai_live` the daemon takes no
words heard during a reply, or for 2 s after it, as the operator's turn.

## Server events (daemon → pet)

| `type` | Fields | Notes |
|---|---|---|
| `server_hello` | `min_version`, `max_version` | Handshake reply; advertises the accepted range. |
| `state` | `state` (`idle` \| `listening` \| `speaking` \| `muted` \| `thinking` \| `reconnecting`) | Turn/session state. The vocabulary is OPEN and additive: a client that does not recognise a value falls back to its idle presentation, so the daemon may add one without a version bump — but it must never invent a value it has not documented here, or older clients silently render the call as idle. |
| `audio_delta` | `audio` (base64 PCM16), `playback_id?` | A chunk of assistant voice output. `playback_id` (**v3**, `xai_realtime` only) is the call-local id the pet reports `playback_progress` against; absent on every OpenAI call. |
| `transcript_delta` | `text`, `role` (`user`) | Realtime only. The user's whole utterance, once the provider has transcribed it. |
| `assistant_text_delta` | `text` | Realtime only. Incremental assistant text: the reply's words as they stream. |
| `assistant_text_done` | `text` | Realtime only. The reply's whole text, once its words are done. It follows the reply's deltas and is never itself a delta. |
| `tool_event` | `status`, `reason?` | A tool call's lifecycle. |
| `usage` | token/cost fields | Per-turn usage. The task engines add `call_uuid`, `status: "live"`, `voice_seconds`, `voice_cost_cents` (3 decimals), `backend_turns`, `backend_cost: "unknown"` and `accounting` (`complete` \| `incomplete` \| `running`). Grok adds `voice_text_items`, the text items the call sent the voice provider, each billed as a text event; SpaceXAI reports no settled usage, so a Grok call's final `accounting` is always `incomplete`. Unknown is not zero: a backend on a subscription allowance reports `unknown`, never `0`. |
| `error` | `reason`, plus context fields | A failure; the daemon closes the connection after most errors. `reason: "call_in_progress"` refuses a `call_start` while another task-engine call is up (see *One call at a time*). On a Grok call, `unknown_playback`, `playback_regressed` and `playback_beyond_sent` refuse a `playback_progress`, and `playback_stalled`, `playback_overflow` and `call_ids_exhausted` end one (see *Playback feedback*). Optional `kind` (`update_required` \| `provider_refused` \| `cost_limit` \| `session_expired` \| `close_timeout` \| `bridge_unavailable` \| `max_session_duration` \| `provider_disconnected`) is the typed failure, and optional `detail` carries the vendor's own bounded sentence. |
| `playback_stop` | — | The assistant's audio playback has stopped. |
| `call_ready` | `engine`, `call_id`, `call_uuid?`, `conversation?`, `tasks_outlive_call?`, `provider_session_id?`, `expires_at?`, `captions` | **v2.** The provider session is established. Under `openai_live` the call carries audio from the `listening` before it (see *Live call sequence*). `call_uuid` is the call's durable identity and the key of its record, the same on every `task` and `usage` of the call; `call_id` stays the trace session id and restarts with the daemon. `conversation` (`chat` \| `private`, task engines only) says where the call's tasks run: `chat`, the chat's own conversation, where a task reads what was typed and the chat later reads what was asked aloud; `private`, a conversation of the call's own, kept apart from the chat. `tasks_outlive_call` (task engines only) is `true` for a call in the chat: a task still running when the call ends is not cancelled but finishes into the chat (see *A task that outlives its call*); `false` for a private call, whose tasks end with it. `expires_at` is unix seconds and is absent when the provider did not say; `captions` is true when `caption` frames will follow. |
| `caption` | `speaker` (`user` \| `assistant`), `delta`, `start_ms`, `end_ms` | **v2.** One verbatim transcript fragment. Concatenate `delta` bytes as received — never trim them or insert spaces — and allow user and assistant captions to overlap in time. A missing fragment is not proof of silence. |
| `task` | `call_uuid?`, `delegation_id`, `revision`, `status`, `summary?`, `server_seq?`, `detached?` | **v2.** Lifecycle of one backend delegation: `pending` \| `running` \| `completed` \| `failed` \| `cancelled`. `revision` fences a re-asked task so a late frame from an earlier revision can be dropped. `summary` is bounded to 240 characters. Backend progress belongs here, outside the spoken captions. `server_seq` (a task-engine call in the chat) is the chat timeline row the result was shown at: a result too long to say, or that cannot be said (a link, code, a table), is written to the chat whole while the voice says a short line, so a client can say the result is in the chat. Absent when nothing was shown. `detached` (a task-engine call in the chat) is `true` on the one `running` frame the daemon sends as the call ends for a task that will finish into the chat; no later `task` frame names it, since the call is over. Absent on every other frame. |

## Live call sequence

Under `openai_live` the daemon speaks to the pet in this order. Every frame
except `call_ready` is optional and may repeat; there is no spoken-response
completion event, so nothing here waits for one.

The daemon says `listening` as soon as it has accepted the call, before the
provider session is up, which takes the provider over a second: a pet streams
from that `listening` as it always does, and the daemon holds the audio, up to
ten seconds of it, until `call_ready`, then passes it on in order. So the
operator can speak as soon as the pet listens and the first words reach the
voice. A start that fails after that `listening` says so with an `error`.

Live publishes no turn boundaries either, so the daemon reads the turn from the
audio and words it relays: `thinking` once Live's recognition has stopped
sending the operator's words for a moment and no reply has started (words heard
during a reply or just after it do not count: they are its echo), and `listening` once the voice
of a reply has had time to play out. They drive only the pet's presentation. Live's output
never stops: between replies `audio_delta` carries digital silence, one chunk
every 100 ms, so a pet must read speaking from the daemon's `state` and from
the voice in the audio, never from audio merely arriving.

```
pet  -> daemon:  call_start
daemon -> pet:   state { state: "listening" }      (the call is accepted)
pet  -> daemon:  audio_chunk …                     (continuous PCM, including silence)
                 daemon opens the provider session and the backend bridge, holding the audio
daemon -> pet:   call_ready { engine: "openai_live", call_id, call_uuid, conversation, tasks_outlive_call, provider_session_id?, expires_at?, captions }
                 daemon passes the held audio on, in order, then each chunk as it arrives
daemon -> pet:   caption …                         (user and assistant fragments, overlapping)
daemon -> pet:   state { state: "thinking" }       (the operator has stopped speaking)
daemon -> pet:   audio_delta … / state { speaking }
daemon -> pet:   state { state: "listening" }      (the reply has had time to play out)
daemon -> pet:   task { delegation_id, revision, status: "running" }      (backend work started)
pet  -> daemon:  task_cancel { delegation_id }                            (optional)
daemon -> pet:   task { …, status: "completed" | "failed" | "cancelled", summary?, server_seq? }
daemon -> pet:   usage { status: "live", voice_seconds, voice_cost_cents, backend_turns,
                         backend_cost: "unknown", accounting: "running" }
pet  -> daemon:  call_stop
daemon -> pet:   state { state: "idle" }
daemon -> pet:   task { …, status: "running", summary?, detached: true }  (a call in the chat: a task still running)
daemon -> pet:   usage { …, accounting: "complete" | "incomplete" }       (final)
```

Live cannot cancel a reply, so an `interrupt` stops it at the relay: the daemon
answers `playback_stop` and `state: "listening"`, and forwards none of the rest
of that reply. Audio after its stream has been quiet for a moment is a new reply.

The final `usage` is the settled bill for the call: `accounting: "incomplete"`
says the provider never reported a terminal duration, and an incomplete total is
never overwritten with zero. A call the daemon ends itself (cost ceiling, session
expiry, max duration, provider disconnect) sends the same `state: "idle"` and
final `usage`, followed by `error` carrying the matching `kind`.

## Grok call sequence

Under `xai_realtime` the daemon speaks to the pet in this order. As under
`openai_live`, the daemon says `listening` as soon as it has accepted the call
and holds the pet's audio until `call_ready`; every frame except `call_ready` is
optional and may repeat.

```
pet  -> daemon:  call_start
daemon -> pet:   state { state: "listening" }      (the call is accepted)
pet  -> daemon:  audio_chunk …                     (continuous PCM, including silence)
                 daemon opens the provider session and the backend bridge, holding the audio
daemon -> pet:   call_ready { engine: "xai_realtime", call_id, call_uuid, conversation, tasks_outlive_call, provider_session_id?, captions }
daemon -> pet:   caption …                         (each finished utterance once)
daemon -> pet:   state { state: "thinking" | "speaking" | "listening" }      (as the turn moves)
daemon -> pet:   audio_delta { playback_id, audio } …
pet  -> daemon:  playback_progress { playback_id, played_ms, drained: false } …   (at most every 100 ms)
pet  -> daemon:  playback_progress { playback_id, played_ms, drained: true }      (at once, on drain)
daemon -> pet:   task { delegation_id, revision, status: "running" }              (backend work started)
pet  -> daemon:  task_cancel { delegation_id }                                    (optional)
daemon -> pet:   task { …, status: "completed" | "failed" | "cancelled", summary?, server_seq? }
daemon -> pet:   usage { status: "live", voice_seconds, voice_cost_cents, voice_text_items,
                         backend_turns, backend_cost: "unknown", accounting: "running" }
pet  -> daemon:  call_stop
daemon -> pet:   state { state: "idle" }
daemon -> pet:   task { …, status: "running", summary?, detached: true }  (a call in the chat: a task still running)
daemon -> pet:   usage { …, accounting: "incomplete" }                    (final)
```

An `interrupt`, or the operator speaking over a reply, stops the reply: the
daemon answers `playback_stop`, and no more audio of that reply follows. An
interruption stops speech only; a task the call handed off keeps running.

## Playback feedback

Under `xai_realtime` (v3) each stretch of assistant audio is sent under a
**playback id**: a call-local id the daemon mints, one per audio part of a
provider output item, carried on every `audio_delta` of that stretch. The pet treats the id as opaque,
at most 64 bytes, and echoes it back unchanged. Under the OpenAI engines no frame
carries one, and `playback_progress` is refused.

The pet reports what it has rendered of each id with

```json
{"type":"playback_progress","playback_id":"p17","played_ms":420,"drained":false}
```

- `played_ms` is the milliseconds of that id's audio rendered so far (PCM16,
  24 kHz, mono: 48 bytes per millisecond). It never decreases, and it never
  exceeds the audio the daemon has sent under the id.
- `drained` is `true` when everything sent under the id so far has played. An id
  that drained becomes undrained again if more audio arrives under it.
- **Cadence:** at most every 100 ms while an id is playing, and **immediately**
  when it drains or when playback stops (an `interrupt`, a `playback_stop`), so
  the daemon cuts an interrupted reply at what was actually heard.

The daemon closes the connection with an `error` whose `reason` is
`unknown_playback` (an id it never sent on this call), `playback_regressed` (a
`played_ms` below one already reported for the id) or `playback_beyond_sent` (a
`played_ms` beyond the audio sent under the id).

The daemon paces the audio by these reports: it keeps about ten seconds of
unplayed audio on the pet and holds the rest until progress frees room, so a pet
that stops reporting stops receiving audio. A Grok call whose sent audio goes
unacknowledged for 2 seconds, with nothing more reported played meanwhile, ends
with `error` `reason: "playback_stalled"`. A reply that outgrows what the
daemon holds besides (about two minutes of audio) ends the call with
`reason: "playback_overflow"`, and a call that has raised more function calls
than it can remember (1,024) ends with `reason: "call_ids_exhausted"` rather
than risk running one twice.

## A task that outlives its call

In a call in the chat (`call_ready.tasks_outlive_call: true`) a task still
running when the call ends, however it ends, is not cancelled. The daemon
sends one `task { status: "running", detached: true }` for it after
`state: "idle"` and before the final `usage`, and the task finishes into the
chat: its result is written there as a row, and the owner can cancel it from
the chat (`priv/companion/PROTOCOL.md`, *A Live call's rows*). A task that was
still waiting is started behind it when its words were heard, and otherwise
ends `failed`. Nothing more about either reaches this socket: the call is over.
A private call's tasks are cancelled when it ends, as before.

## One call at a time

The daemon holds one task-engine call (`openai_live` or `xai_realtime`). A
`call_start` on another connection while a call is up, or still settling (its provider session closing and its bill being
settled), is refused before any session starts with

```json
{"type":"error","reason":"call_in_progress"}
```

and the connection closes. The call that was up is untouched. A repeated
`call_start` on the connection that holds the call is not a second call.
