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
| `protocol_version` (pet declares) | `1` |
| daemon `min_version` | `1` |
| daemon `max_version` | `1` |

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

## Server events (daemon → pet)

| `type` | Fields | Notes |
|---|---|---|
| `server_hello` | `min_version`, `max_version` | Handshake reply; advertises the accepted range. |
| `state` | `state` (`idle` \| `listening` \| `speaking` \| `muted`) | Turn/session state. |
| `audio_delta` | `audio` (base64 PCM16) | A chunk of assistant voice output. |
| `transcript_delta` | `text` | Incremental transcript of the assistant's speech. |
| `assistant_text_delta` | `text` | Incremental assistant text. |
| `tool_event` | `status`, `reason?` | A tool call's lifecycle. |
| `usage` | token/cost fields | Per-turn usage. |
| `error` | `reason`, plus context fields | A failure; the daemon closes the connection after most errors. |
| `playback_stop` | — | The assistant's audio playback has stopped. |
