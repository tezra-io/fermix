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
advertises the inclusive range `{min_version, max_version}` it accepts. The range
is an **N/N-1 window**: `max_version` is the current version and `min_version` is
the previous one (or the same value when only one version has ever existed), so a
daemon that has moved to `N+1` still serves a pet speaking `N` for one release.

Current values (see the schema's `x-protocol-version` / `x-supported-version-range`):

| Field | Value |
|---|---|
| `protocol_version` (pet declares) | `2` |
| daemon `min_version` | `1` |
| daemon `max_version` | `2` |

### Version 2 — the Live engine

Version 2 adds the frames the `openai_live` engine needs: `task_cancel` from the
pet, and `call_ready`, `caption` and `task` from the daemon, plus extra fields on
`usage` and `error`. A **v1 pet may still run the Realtime engine** against a v2
daemon — that is the whole point of the N/N-1 window, and nothing in the Realtime
path changed.

Live is the exception: a v1 pet that sends `call_start` while the daemon is
configured for `openai_live` is refused with

```json
{"type":"error","reason":"unsupported_protocol_version","kind":"update_required",
 "direction":"client_too_old","client_version":1,"min_version":2,"max_version":2,
 "required_for":"openai_live"}
```

and the connection closes — no session is started. `min_version` in **this**
refusal is the version the configured engine requires (2), not the handshake
floor the daemon advertises in `server_hello` (1); `required_for` names the
engine that raised it. The handshake itself still succeeds for a v1 pet, so the
refusal arrives at `call_start`, where the engine is known.

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
   `N` (the N/N-1 window). Never remove support for a version a released pet still
   requires.
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
| `task_cancel` | `delegation_id` (non-empty string, required) | **v2.** Cancels one backend delegation of a Live call. Under the Realtime engine it is refused with `error: unsupported_by_engine` and the connection closes. |

## Server events (daemon → pet)

| `type` | Fields | Notes |
|---|---|---|
| `server_hello` | `min_version`, `max_version` | Handshake reply; advertises the accepted range. |
| `state` | `state` (`idle` \| `listening` \| `speaking` \| `muted` \| `thinking` \| `reconnecting`) | Turn/session state. The vocabulary is OPEN and additive: a client that does not recognise a value falls back to its idle presentation, so the daemon may add one without a version bump — but it must never invent a value it has not documented here, or older clients silently render the call as idle. |
| `audio_delta` | `audio` (base64 PCM16) | A chunk of assistant voice output. |
| `transcript_delta` | `text` | Incremental transcript of the assistant's speech. |
| `assistant_text_delta` | `text` | Incremental assistant text. |
| `tool_event` | `status`, `reason?` | A tool call's lifecycle. |
| `usage` | token/cost fields | Per-turn usage. Live adds `status: "live"`, `voice_seconds`, `voice_cost_cents` (3 decimals), `backend_turns`, `backend_cost: "unknown"` and `accounting` (`complete` \| `incomplete` \| `running`). Unknown is not zero: a backend on a subscription allowance reports `unknown`, never `0`. |
| `error` | `reason`, plus context fields | A failure; the daemon closes the connection after most errors. Optional `kind` (`update_required` \| `provider_refused` \| `cost_limit` \| `session_expired` \| `close_timeout` \| `bridge_unavailable` \| `max_session_duration` \| `provider_disconnected`) is the typed failure, and optional `detail` carries the vendor's own bounded sentence. |
| `playback_stop` | — | The assistant's audio playback has stopped. |
| `call_ready` | `engine`, `call_id`, `provider_session_id?`, `expires_at?`, `captions` | **v2.** The provider session is established and the call can carry audio. `expires_at` is unix seconds and is absent when the provider did not say; `captions` is true when `caption` frames will follow. |
| `caption` | `speaker` (`user` \| `assistant`), `delta`, `start_ms`, `end_ms` | **v2.** One verbatim transcript fragment. Concatenate `delta` bytes as received — never trim them or insert spaces — and allow user and assistant captions to overlap in time. A missing fragment is not proof of silence. |
| `task` | `delegation_id`, `revision`, `status`, `summary?` | **v2.** Lifecycle of one backend delegation: `pending` \| `running` \| `completed` \| `failed` \| `cancelled`. `revision` fences a re-asked task so a late frame from an earlier revision can be dropped. `summary` is bounded to 240 characters. Backend progress belongs here, outside the spoken captions. |

## Live call sequence

Under `openai_live` the daemon speaks to the pet in this order. Every frame
except `call_ready` is optional and may repeat; there is no spoken-response
completion event, so nothing here waits for one.

```
pet  -> daemon:  call_start
                 daemon opens the provider session and the backend bridge
daemon -> pet:   call_ready { engine: "openai_live", call_id, provider_session_id?, expires_at?, captions }
daemon -> pet:   state { state: "listening" }
pet  -> daemon:  audio_chunk …                     (continuous PCM, including silence)
daemon -> pet:   caption …                         (user and assistant fragments, overlapping)
daemon -> pet:   audio_delta … / state { speaking }
daemon -> pet:   task { delegation_id, revision, status: "running" }      (backend work started)
pet  -> daemon:  task_cancel { delegation_id }                            (optional)
daemon -> pet:   task { …, status: "completed" | "failed" | "cancelled", summary? }
daemon -> pet:   usage { status: "live", voice_seconds, voice_cost_cents, backend_turns,
                         backend_cost: "unknown", accounting: "running" }
pet  -> daemon:  call_stop
daemon -> pet:   state { state: "idle" }
daemon -> pet:   usage { …, accounting: "complete" | "incomplete" }       (final)
```

The final `usage` is the settled bill for the call: `accounting: "incomplete"`
says the provider never reported a terminal duration, and an incomplete total is
never overwritten with zero. A call the daemon ends itself (cost ceiling, session
expiry, max duration, provider disconnect) sends the same `state: "idle"` and
final `usage`, followed by `error` carrying the matching `kind`.
