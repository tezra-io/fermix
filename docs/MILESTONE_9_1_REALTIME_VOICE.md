# Milestone 9.1: Realtime Local Voice Companion - Functional Design

**Status:** V1 shipped; M9.2 tracks the full-duplex cleanup pass
**Milestone:** M9 Differentiators
**Depends on:** M4.8 Distribution & Daemon, M4.9 Unified Capabilities, M4.10 Provider Selection, M7 Built-in Capability Catalog
**Informs:** M10 approval/governance, future Signal call support
**Primary model target:** OpenAI `gpt-realtime-2` (verified against official OpenAI docs on 2026-05-10)

## 1. Purpose

Fermix currently handles text-first channel messages and audio attachments that
are transcribed before entering the agent loop. That is not the same product as
a local, spoken assistant. This milestone adds a native macOS companion that can
float on the desktop like a small character, start a voice session when clicked,
stream microphone audio to Fermix, and play back low-latency assistant speech.

The first version is deliberately **not always listening**. The companion can be
always visible, but the microphone stream and OpenAI Realtime session start only
after an explicit user action. Once active, the session is a full-duplex voice
call: the microphone remains live while assistant audio plays, macOS voice
processing handles echo cancellation, and OpenAI server VAD owns turn
boundaries. Command-word activation and true always-listening cloud mode are
later phases because they carry cost, privacy, and false-positive risks.

## 2. References

- `ARCHITECTURE.md` - process-local umbrella architecture and runtime boundaries.
- `docs/ROADMAP.md` - M9 differentiators and Future ecosystem placement.
- `docs/MILESTONE_3_ONBOARDING_CHANNEL_COVERAGE.md` - existing audio attachment
  transcription path.
- `docs/MILESTONE_4_8_DISTRIBUTION.md` - local daemon and single-user install
  posture.
- `docs/MILESTONE_4_9_UNIFIED_CAPABILITIES.md` - capability registry, policy
  classes, and provider-adapter boundaries.
- `docs/MILESTONE_4_10_CODEX_PARITY.md` - provider/model setup and OpenAI API-key
  routing.
- OpenAI Realtime model docs:
  `https://platform.openai.com/docs/models/gpt-realtime-2` (`gpt-realtime-2`
  is the current default Realtime voice model as of 2026-05-10)
- OpenAI Realtime guide:
  `https://platform.openai.com/docs/guides/realtime`
- OpenAI Realtime WebSocket guide:
  `https://platform.openai.com/docs/guides/realtime-websocket`
- OpenAI Realtime conversation/VAD/cost docs:
  `https://developers.openai.com/api/docs/guides/realtime-conversations`,
  `https://developers.openai.com/api/docs/guides/realtime-vad`,
  `https://platform.openai.com/docs/guides/realtime-costs`

## 3. Current Codebase Assessment

### 3.1 Existing text and attachment path

The normal path is:

```text
channel adapter
  -> FermixChannels.Message
  -> FermixChannels.Dispatcher
  -> FermixCore.Agents.MainAgent
  -> FermixCore.AgentLoop
  -> provider adapter
  -> reply_fn
```

`FermixChannels.Dispatcher` is the right boundary for discrete messages. It
normalizes input, optionally runs `FermixCore.Transcription`, builds `reply_fn`,
and hands a single message to `MainAgent`.

This path should stay turn-based. It is not the right place for continuous audio
chunks, live playback, or an OpenAI Realtime event loop.

### 3.2 Existing transcription path

`FermixCore.Transcription` downloads one audio attachment, sends the file to the
configured transcription backend, and replaces empty message content with the
transcribed text. That supports Telegram/WhatsApp-style voice notes. It does not
handle live mic capture, assistant audio output, VAD, interruption, or function
call events.

Realtime voice must be a separate subsystem. It can reuse conversation memory and
prompt composition, but it should not overload the attachment transcription API.

### 3.3 Existing provider path

`FermixCore.Providers.Adapter` is a turn-based behavior:

- `chat(messages, capabilities, opts)`
- `continue(provider_state, tool_results, opts)`

OpenAI Realtime is session/event-based. A session receives audio deltas,
conversation items, tool-call events, audio output deltas, transcripts, and usage
events over time. Forcing Realtime into `Adapter.chat/3` would hide its actual
runtime shape and make interruption, streaming output, and session cost tracking
awkward.

The design adds `FermixCore.Realtime` instead of another normal provider
adapter.

### 3.4 Existing local daemon socket

`Fermix.CLI.Daemon` owns a 0600 Unix-domain control socket at
`~/.fermix/daemon.sock`. It is a JSON-line request/response protocol for
commands such as `status`, `health`, `capabilities`, `agent_message`, and
`shutdown`.

Live audio should not use that control socket. It needs a long-lived stream with
many events in both directions. Reusing the control socket would make the daemon
method surface harder to reason about and would mix status RPCs with high-rate
audio traffic.

### 3.5 Existing setup and config path

Runtime configuration is layered as:

1. compile-time defaults from `config/config.exs`
2. persisted setup snapshot from `FermixCore.Setup.ConfigStore`
3. environment overlays in `config/runtime.exs`

Every new setup value must be wired through `ConfigStore.current_snapshot/0`,
`persistable_snapshot/1`, TOML parsing/dumping, `apply_snapshot/1`,
`FermixCore.Setup.Wizard`, CLI setup switches, readiness, health, and runtime
env overlays where applicable. Adding only an Application env key is not enough.

### 3.6 Existing WebSocket dependency shape

`apps/fermix_channels` already depends on `websockex` for Discord gateway work.
`apps/fermix_core` does not. The Realtime client belongs in core because it needs
provider auth, capability execution, memory, traces, and setup state. Therefore
the implementation should add `{:websockex, "~> 0.4"}` to `fermix_core` rather
than making core call into `fermix_channels` or introducing a second WebSocket
library such as Mint or Gun.

### 3.7 Existing capability policy shape

M4.9 capabilities already carry:

- `policy_class`: `:read_only`, `:read_write`, `:exec`, `:network`, or
  `:external_api`
- `hidden_from_agent?`

Realtime tool exposure should reuse `FermixCore.Capabilities.Registry.list/2`
with `trust: :third_party`, `kind: :builtin | :skill | :mcp` as needed, and
`include_hidden?: false`. The third-party trust preset is already the
read-only baseline; the design must not duplicate that policy literal.

## 4. Product Contract

### 4.1 User experience

V1 ships a native macOS companion:

- small always-on-top floating character window
- draggable position
- click-to-start / click-to-end voice call
- visible states: offline, idle, listening, thinking, tool-use, speaking, muted,
  error
- macOS microphone permission through native APIs
- audio playback through native APIs
- reconnect/offline state when Fermix daemon is not running

The character may stay visible all day. The microphone and Realtime session do
not stay active all day.

### 4.2 Activation phases

| Phase | Mode | Cost posture | Scope |
|-------|------|--------------|-------|
| V1 | Click-to-talk / click-toggle | No OpenAI audio stream while idle | This milestone |
| V2 | Local command word | Wake detection runs on-device, then opens Realtime | Later |
| V3 | Always-listening cloud session | Explicit opt-in with hard budget limits | Later, never default |

### 4.3 Non-goals

- Browser-based voice UI.
- Telegram voice calls.
- Signal call integration.
- Always-listening by default.
- A wake-word engine in V1.
- Raw audio persistence.
- Replacing the existing text agent loop.
- Exposing mutating tools by default over voice before M10 approval UX.
- Multi-provider Realtime abstraction beyond a config shape that can grow later.

## 5. Architecture

### 5.1 Decision

Add a new core-owned Realtime runtime:

```text
FermixPet.app
  -> ~/.fermix/realtime.sock
  -> FermixCore.Realtime.LocalVoiceSocket
  -> FermixCore.Realtime.SessionServer
  -> FermixCore.Realtime.OpenAIClient
  -> OpenAI Realtime WebSocket

SessionServer
  -> FermixCore.Prompt.PromptComposer
  -> FermixCore.Capabilities.Registry
  -> FermixCore.Realtime.ToolBridge
  -> FermixCore.Memory.ConversationStore
  -> FermixCore.Memory.ExtractionDebouncer
  -> FermixCore.Trace / telemetry
```

The macOS companion is a client. Fermix daemon owns provider auth, prompt
composition, tool policy, memory writes, traces, and cost accounting.

### 5.2 Why not `FermixChannels`

`FermixChannels` is for platform message ingress and replies. Realtime local
voice is not a message platform. It is a local operator interface with continuous
audio. Reusing channels would force `Dispatcher` and `MainAgent` to pretend that
streaming audio is a normal message, then reimplement the Realtime session beside
the text provider loop anyway.

### 5.3 Why not `FermixCore.Providers.Adapter`

The provider adapter contract is intentionally normalized around a bounded
text/tool turn. Realtime requires a long-lived session with async events. A
dedicated Realtime client keeps the event loop explicit and lets the normal
provider adapters remain simple.

### 5.4 Why not WebRTC in V1

OpenAI recommends WebRTC for browser/mobile clients when low latency matters. In
this design the client is a native macOS app and the API key must stay in the
daemon. A daemon-managed WebSocket keeps secrets and tools out of the app, avoids
WebRTC native plumbing in V1, and fits Fermix's existing local-daemon posture.

If latency proves unacceptable, a later phase can add WebRTC with a sideband
daemon session. That should be a measured migration, not the first cut.

## 6. Components

### 6.1 `FermixCore.Realtime.Config`

Reads and validates `Application.get_env(:fermix_core, :realtime, [])`.

Initial persisted config:

```toml
[fermix_core.realtime]
enabled = false
provider = "openai"
model = "gpt-realtime-2"
voice = "marin"
max_session_minutes = 15
max_estimated_cost_cents_per_session = 100
persist_transcripts = false
```

> **Note (2026-05):** `tool_policy` and `allow_network_tools` were both
> removed. Voice now uses the same capability surface as the main agent;
> sandbox mode + command profile cover voice scope uniformly. Existing
> configs fail loud via `reject_removed_key!`.

Validation rules:

- `enabled` defaults to `false`.
- `provider` must be `"openai"` in V1.
- `model` must be `"gpt-realtime-2"` in this milestone.
- V1 exposes no `activation`, `turn_detection`, or chunk-count mode knobs.
  Realtime is one explicit full-duplex call mode with OpenAI `server_vad`.
- Internal audio defaults are PCM16 at 24 kHz mono. `max_chunk_bytes` remains an
  internal socket guard at 16,384 bytes.
- cost/session limits must be positive integers.
- `persist_transcripts` defaults to `false` because spoken input is more
  sensitive than text chat. Setup and the companion can explicitly enable local
  transcript persistence when memory continuity is desired.
- `persist_audio = true` is rejected in V1.

The TOML parser currently handles strings, booleans, integers, and arrays. This
config intentionally avoids floats.

### 6.2 `FermixCore.Realtime.Supervisor`

Starts only when realtime is enabled, setup is ready, and the runtime has
explicitly enabled the Realtime socket for `fermix run`. This mirrors the
existing `daemon_socket_enabled` gate: setup, version, doctor, and other
short-lived CLI commands must not bind the Realtime socket or start Realtime
session workers.

Implementation shape in `FermixCore.Application`:

- `cli_dispatch(["run" | _])` calls `enable_realtime_socket/0` next to
  `enable_daemon_socket/0`.
- the supervision tree adds `maybe_realtime_supervisor/0`.
- `maybe_realtime_supervisor/0` starts Realtime only when both
  `:fermix_core, :realtime_socket_enabled` and
  `:fermix_core, :realtime, enabled: true` are set.

Children:

- `FermixCore.Realtime.SessionSupervisor`
- `FermixCore.Realtime.LocalVoiceSocket`

If realtime is disabled, no socket is created and no Realtime processes run.

If realtime is enabled but OpenAI API-key auth is missing, readiness reports
`setup_required` and the Realtime supervisor does not start.

### 6.3 `FermixCore.Realtime.LocalVoiceSocket`

Listens at `~/.fermix/realtime.sock`, chmod `0600`.

This is separate from `~/.fermix/daemon.sock`. The control socket remains
request/response; the voice socket is long-lived event traffic.

V1 protocol uses newline-delimited JSON events with base64 PCM audio chunks:

Client -> daemon:

- `client_hello`
- `call_start`
- `audio_chunk`
- `interrupt`
- `mute`
- `call_stop`

Daemon -> client:

- `state`
- `audio_delta`
- `transcript_delta`
- `assistant_text_delta`
- `tool_event`
- `usage`
- `error`
- `playback_stop`

`client_hello` is for protocol-version negotiation and companion metadata only;
it is not an auth layer. The 0600 socket file remains the local trust boundary.

`call_start` opens one daemon-owned OpenAI Realtime WebSocket and starts mic
streaming. `call_stop` closes that WebSocket and stops local capture/playback.
There is no separate per-turn `listen_stop`; OpenAI server VAD commits user
turns and creates responses.

`mute` means "stop accepting microphone chunks while keeping the Realtime
session and assistant audio alive." It does not silence assistant output and does
not close the session.

`interrupt` is explicit click barge-in. The daemon cancels current assistant
response playback and emits `playback_stop`; the companion stops local output
and keeps the microphone live. Passive voice barge-in is handled by OpenAI
server VAD plus macOS voice processing rather than by closing the mic path.

Base64 audio has overhead, but the first target is a local explicit voice call,
not an always-on cloud pipe. The format is easy to test with fixtures. If
profiling shows meaningful overhead, switch this socket to length-prefixed
binary frames in a follow-up.

The socket must enforce:

- `max_chunk_bytes = 16_384`
- one session per connected client
- explicit close on protocol errors
- no silent dropping of audio or output events

#### 6.3.1 Wire framing contract

The socket reads raw bytes and splits on `\n` in an explicit accumulating buffer.
It does not use Erlang `{:packet, :line}`. The reason is concrete: a default
`{:packet, :line}` listener truncates lines longer than the receive buffer
(roughly 8 KB on common configurations), which means a normal pet audio frame
(`audio_chunk` event ≈ 16 KB on the wire) is silently chopped, the daemon
decodes the half-line as `invalid_json`, sends an error, and closes the socket.
The pet then keeps capturing mic audio and observes `Socket is not connected`.
The contract for V1:

- raw `:gen_tcp` reads with `{:active, false}` and a per-connection accumulator.
- a single `\n` byte terminates each event.
- the daemon must hold a hard `@max_wire_line_bytes` cap as protection against
  unbounded buffer growth. The cap is derived from `max_chunk_bytes`: a worst-case
  wire frame is `ceil(max_chunk_bytes * 4 / 3) + 256` bytes (base64 + JSON
  overhead). Any line exceeding the cap closes the connection with a
  `line_too_large` error rather than allocating without bound.
- empty lines are skipped, not treated as events.
- multi-line bursts in a single `recv` are fully drained before the next
  `recv` call. Partial trailing lines persist in the buffer.

If a future revision re-introduces `{:packet, :line}` or any other framing
abstraction, it must come with an explicit benchmark proving it handles a
pet-sized audio frame plus a regression test (see
`local_voice_socket_test.exs` "accepts a pet-sized audio chunk over the
socket").

### 6.4 `FermixCore.Realtime.SessionServer`

Owns one voice session.

Responsibilities:

- build the session prompt from `PromptComposer`
- load recent Realtime conversation history
- select and snapshot allowed capabilities from `CapabilityRegistry`
- open and monitor the OpenAI Realtime WebSocket
- forward audio chunks to OpenAI
- forward assistant audio deltas to the companion
- handle VAD/session/response events
- execute tool calls through `ToolBridge`
- write final transcript turns to conversation history
- emit telemetry and traces
- enforce idle, duration, and cost limits

The session starts on `call_start`, not on companion launch. It closes on
`call_stop`, idle timeout, cost limit, max duration, client disconnect, or
provider error.

The V1 state machine is intentionally full-duplex:

`idle -> listening <-> thinking/speaking/tool_use -> listening`

While the call is active, microphone chunks are accepted in every non-muted
state, including during assistant playback. `response.done` returns to
`listening`, not `idle`; only `call_stop` ends the call. Echo/noise control is
handled by the native companion's macOS voice-processing audio engine and by
OpenAI `server_vad` with response creation enabled.

The capability catalog is locked at session start. Realtime sends tool
definitions during session configuration; if a skill reload or MCP disconnect
changes the registry mid-session, the active voice session keeps using its
snapshot until it ends. Runtime catalog updates require a new session in V1.
Pushing `session.update` after registry mutations is a later optimization.

### 6.5 `FermixCore.Realtime.OpenAIClient`

WebSocket client for OpenAI Realtime.

V1 uses OpenAI API-key auth from `providers.openai.api_key`. It must not use the
Codex OAuth token path because Codex OAuth scopes are checked per API surface
and should not be assumed to authorize Realtime. The current Realtime target is
`gpt-realtime-2`, verified in the official model docs on 2026-05-10.

Implementation must verify exact event names and payloads against current
OpenAI docs immediately before coding. The design expects these event classes:

- session configuration update
- input audio buffer append/commit/clear
- response start/delta/done
- output audio delta/done
- transcript delta/done
- function-call argument completion
- function-call output submission
- usage in terminal response events
- provider error/rate-limit events
- required connection headers, including whether any `OpenAI-Beta` or successor
  header is required for the current Realtime API revision

#### 6.5.1 `session.update` contract

The first frame after connect is `session.update`. It must include:

- `instructions` — composed via `PromptComposer`.
- `voice` — from `Config.voice`.
- `output_modalities` (or successor field name on the active GA schema) — V1
  uses `["audio"]` only. The pet does not need text output and an extra text
  response would double-bill. If a non-pet caller of this module ever needs
  text-only output, it must override modalities at session start, not at
  request time.
- `audio.input.format` and `audio.output.format` — derived from
  `Config.input_audio_format` / `output_audio_format`. PCM16 at 24 kHz mono.
- `audio.input.turn_detection` — fixed to `server_vad` in V1, with
  `create_response = true`, `interrupt_response = true`, `threshold = 0.7`,
  `prefix_padding_ms = 300`, and `silence_duration_ms = 800`. There is no
  manual commit mode in the final V1 architecture.
- `audio.input.transcription` — required, not optional. OpenAI only emits
  `conversation.item.input_audio_transcription.completed` events when this
  field is set. Without it, the user-transcript handler in `SessionServer`
  is dead code, no `transcript_delta` (role=user) events reach the
  companion, and `ConversationRecorder` writes assistant turns alongside
  empty user turns. V1 defaults the model to `whisper-1`. The model is
  configurable for ops cost or accuracy tuning.
- `tools` and `tool_choice` — from `ToolBridge.to_openai_tools/1`,
  `tool_choice = "auto"` in V1.

The output token cap is **not** a session field on the GA `gpt-realtime`
schema (the server rejects `session.max_response_output_tokens` as
`unknown_parameter`). The daemon still includes `response.max_output_tokens`
on every explicit `response.create` it emits after a tool result, sourced from
`Config.max_response_output_tokens` (default `4096`). Server-VAD-created
responses rely on the session's normal cost and max-duration caps.

#### 6.5.2 Cost source of truth

OpenAI's Realtime `response.done` event reports usage as token counts, not
dollars. `usage` looks roughly like
`{"input_tokens": ..., "output_tokens": ..., "input_token_details": {"audio_tokens": ..., "text_tokens": ..., "cached_tokens": ...}, "output_token_details": {"audio_tokens": ..., "text_tokens": ...}}`.

The CostTracker is the only authority on per-session cost:

- estimated cost is computed from input audio duration as before, plus a
  conservative output estimate during streaming (one token per 50 ms of
  delivered audio).
- when `response.done` arrives, reported cost replaces the streaming output
  estimate using the actual token counts and the per-token rates from
  `Config.realtime_pricing` (or a literal price table on the tracker; the
  rates change with model versions and must be sourced from a single
  named location).
- the daemon enforces hard caps against `max(estimated_cost, reported_cost)`.

There is no `usage.cost_cents` field on the wire; any code that reads one is
dead code. V1 must not synthesize a cents value into the payload either —
the wire stays token-shaped.

#### 6.5.3 Connect timeout

`WebSockex.start` must use an explicit handshake timeout (`5_000` ms in V1).
If OpenAI does not accept the WebSocket inside that window, the SessionServer
returns `{:error, :openai_connect_timeout}` to the caller and notifies the
companion with an error event. Without this cap, `call_start` blocks
indefinitely and the pet's first click freezes the UI thread.

#### 6.5.4 Reconnect policy

V1 attempts a bounded reconnect on `openai_realtime_disconnect` events:

- 3 attempts maximum, with delays `1_000`, `2_000`, `4_000` ms.
- the SessionServer notifies the companion with `state: "reconnecting"`
  before each attempt so the pet can render that distinctly from `error`.
- on a successful reconnect, the daemon re-sends `session.update` with the
  same instructions, tools, and configuration snapshot taken at session
  start. It does not replay audio chunks; the user must re-utter anything
  that was mid-flight.
- after the third failed attempt, the session enters `error` state and
  closes loudly. Any in-progress assistant audio is discarded.
- companion-driven `interrupt` or `call_stop` during
  reconnect cancels the reconnect attempts.

Earlier drafts of this design said V1 had no reconnect at all. That was too
strict: a brief network blip during a 15-minute session would otherwise force
the user to start over, and the cost of replaying `session.update` is
negligible compared to the failure mode. Reconnect after a failed reconnect
loop, and reconnect across `call_stop`, are still V2.

#### 6.5.5 Barge-in protocol

When the user interrupts during assistant playback, two things must happen:

1. cancel the in-flight response (`response.cancel`).
2. truncate the assistant item to the audio duration the user actually
   heard (`conversation.item.truncate` with `audio_end_ms` = played-ms).

Without step 2, the model believes the entire generated response was heard.
The next turn references content the user never received, and multi-turn
coherence drifts. This applies to the V1 full-duplex call because the user can
interrupt mid-playback.

The companion is the only party that knows played-ms. The wire contract:

- the pet tracks decoded PCM16 ms played per assistant item id, accumulated
  across `audio_delta` events.
- on user-driven `interrupt`, the pet sends
  `{type: "interrupt", item_id: <last-assistant-item-id>, audio_end_ms: <played-ms>}`.
- the daemon `Protocol.decode_client_event/2` accepts the new fields,
  validates them as non-negative integer / non-empty string, and forwards
  to `SessionServer`.
- `SessionServer` sends `conversation.item.truncate` followed by
  `response.cancel`, in that order.
- `interrupt` with no `item_id` (e.g., user interrupts before any assistant
  audio has played) sends `response.cancel` only.

### 6.6 `FermixCore.Realtime.ToolBridge`

Converts the session-start capability snapshot into Realtime function tools and
executes function calls.

Default V1 selection:

```elixir
CapabilityRegistry.list(
  registry,
  trust: :third_party,
  include_hidden?: false
)
```

`trust: :third_party` is the existing read-only registry preset. Do not copy the
literal `allow`/`deny` list into Realtime code; the preset is the source of
truth.

Note (2026-05): network/mutating tool exposure is no longer scoped per-voice.
Realtime mirrors the main-agent capability surface; restrict at the capability
layer if you need a narrower surface across all callers.

Execution path:

1. Realtime emits a function call.
2. `ToolBridge` validates the tool exists in the session snapshot. This is a
   stale-catalog sanity check, not the primary security boundary.
3. Arguments are decoded as JSON.
4. `Capability.execute/3` runs with an explicit Realtime context.
5. Result is encoded as a string output event back to Realtime.
6. Tool start/finish/error events are traced.

Tool execution should not call `AgentLoop`. Realtime is already the model loop.

### 6.7 `FermixCore.Realtime.ConversationRecorder`

Persists transcripts, not raw audio.

Device identity is a stable, opaque per-install UUID stored under
`~/.fermix/realtime/device_id`. It is created on first `fermix run` with
Realtime enabled, not derived from hostname, username, serial number, or other
machine-identifying data. The same value is used to build a privacy-preserving
OpenAI safety identifier, after hashing with Fermix owner/install context.
Use a versioned derivation so the raw owner or device IDs are never sent:

```elixir
payload = ["fermix-realtime-safety-v1", 0, owner_id, 0, device_id]

:crypto.hash(:sha256, payload)
|> Base.url_encode64(padding: false)
|> binary_part(0, 32)
```

`owner_id` comes from `FermixCore.Memory.Config.owner_id/0`; `device_id` is the
opaque UUID above. The delimiter and version label are part of the contract.

Conversation key:

```elixir
{"realtime", "local:" <> device_id, session_scope}
```

Stored messages:

- final user transcript after VAD/manual commit
- final assistant transcript/text after response completion
- optional tool summaries in metadata
- usage/cost estimates in metadata
- `kind = "voice_turn"` so voice transcript rows are not confused with normal
  `"chat_message"` rows
- `source_type = "realtime"` and `source_id = "local:<device_id>"`, matching
  M4.11's source-aware memory shape

Raw audio is not persisted in V1. Partial transcript deltas are not persisted as
messages. They may be traced only as bounded diagnostic metadata if tracing is
explicitly configured to include them.

When `persist_transcripts = false`, transcript turns are session-local only and
memory extraction is skipped. When it is true, the recorder writes durable
`voice_turn` rows and requests extraction with the same `source_type` and
`source_id`.

Voice history retrieval should not use `ConversationStore.get_history/2`'s
hardcoded durable selector for `kind = "chat_message"`. Either extend
`ConversationStore` with a `kind:` option or let `ConversationRecorder` load
`voice_turn` rows directly through `Memory.Repo`. A text-channel `/new` clears
that text conversation key only; it does not wipe the separate
`{"realtime", "local:<device_id>", ...}` voice key. A future privacy/global wipe
command can explicitly include voice.

After each completed user/assistant exchange, the recorder can request normal
memory extraction through `ExtractionDebouncer`, using the same owner/agent IDs
as `MainAgent`.

### 6.8 `FermixCore.Realtime.CostTracker`

Tracks estimated and provider-reported usage for each session.

OpenAI's cost guide estimates audio input at about one token per 100ms and audio
output at about one token per 50ms. With current `gpt-realtime-2` pricing, that
means roughly:

- input audio: about 600 tokens/minute
- assistant audio: about 1200 tokens/minute

The tracker should:

- estimate input cost from committed audio duration before usage arrives
- update with provider usage when terminal response events include usage
- enforce hard caps against `max(estimated_cost, reported_cost)`, so an
  over-counting estimate may stop early but an under-reporting or delayed usage
  event cannot exceed the configured session budget
- emit `usage` events to the companion
- stop the session when configured cost or duration caps are crossed
- trace estimated and actual token buckets separately

The companion should show a simple session cost indicator only after V1 is
stable. The daemon must enforce the hard limits regardless of UI.

### 6.9 macOS Companion

Recommended location:

```text
clients/macos/FermixPet/
```

V1 implementation shape:

- SwiftUI/AppKit floating borderless window
- mascot-first surface: the Fermix mascot is the pet, with status and controls
  as secondary hover affordances rather than a plain status box
- explicit close/quit affordance, plus a secondary context-menu quit path, so
  the borderless accessory app is never trapped on screen
- always-on-top toggle
- draggable position stored in app preferences
- one click-to-start / click-to-end voice call mode
- AVAudioEngine for full-duplex capture/playback with macOS voice processing
- native microphone permission prompt
- local socket client to `~/.fermix/realtime.sock`
- state renderer for idle/listening/thinking/tool-use/speaking/error
- no OpenAI API key, no provider config, no tool execution

The companion is not packaged by Burrito. It is a separate native client that
expects the Fermix daemon to be installed and running.

V1 signing/posture:

- source build under `clients/macos/FermixPet` with Xcode is the supported path
  for the first implementation
- local development builds use ad-hoc signing
- zipped/shared early-access builds must document the Gatekeeper quarantine
  removal step (`xattr -dr com.apple.quarantine FermixPet.app`) until a Developer
  ID certificate and notarization flow exist
- Developer ID signing and notarization are release-packaging work, not required
  for the first local validation

CLI integration can come in later stages:

- `fermix voice status`
- `fermix voice install-companion`
- `fermix voice start-companion`
- `fermix voice stop-companion`

### 6.10 Audio chunk cadence

The companion captures at the input device's native rate and converts to
24 kHz mono PCM16 before sending. Each `audio_chunk` event carries one chunk.

V1 target: ~100 ms per chunk. With a 48 kHz input device, that's a
4_800-frame `installTap` buffer; after converting to 24 kHz mono PCM16 it
becomes 2_400 frames × 2 bytes = 4_800 raw bytes, ~6.4 KB on the wire after
base64 + JSON envelope. Earlier drafts used 12_000-frame buffers (~250 ms,
~16 KB on the wire), which adds noticeable one-way latency on top of network
and model time and showed up as "the pet heard me late." `AudioController`
logs the first converted chunk size on each
session — verify it matches the target the next time the pet is launched.

Bigger chunks are not free: latency scales linearly, and any single chunk
larger than the pet's input buffer drops samples. Smaller chunks are not
free either: a 20 ms chunk multiplies socket and base64 overhead by 5×.
Pick the cadence the OpenAI/Azure docs explicitly recommend (~100 ms),
and don't drift from it without measurement.

### 6.11 Voice activity detection (VAD)

VAD is `turn_detection` on the OpenAI Realtime session. V1 pins one mode:
`server_vad` with provider-side response creation and interruption enabled.
Fermix does not expose a manual VAD or semantic VAD selector in setup.

The reason is architectural rather than cosmetic: the pet is a full-duplex
voice call. If the daemon waits for manual commits, the UI falls back into
half-duplex turn handling and the assistant cannot be interrupted naturally.

Future work can tune threshold/silence values, add local wake-word activation,
or evaluate `semantic_vad`, but those are product-mode changes and should not
be exposed as low-level setup knobs.

## 7. Setup, Readiness, and Health

### 7.1 Setup

Add Realtime config through the existing setup chain:

- `FermixCore.Setup.ConfigStore.current_snapshot/0`
- `persistable_snapshot/1`
- TOML parse/dump
- `apply_snapshot/1`
- `empty_runtime_config/0`
- `workspace_paths/0` adds `realtime: "realtime"` for the device-id file and
  future companion-local metadata
- `FermixCore.Setup.Wizard`
- `Fermix.CLI.Setup` switches
- `config/runtime.exs` env overlays
- setup tests

Realtime is an optional companion to the chat interface; it has no Fermix
channel of its own and runs locally on the operator's machine. The setup wizard
must not add a long list of questions to every install. Setup asks one top-level
question first:

```text
Enable local voice companion? [y/N]
```

Only when the answer is yes does the wizard prompt for the rest of the realtime
block, in this order:

1. OpenAI API key for Realtime — skipped when the main agent provider is
   already `openai` (the agent's `[fermix_core.providers.openai].api_key` is
   reused). When the main agent provider is `anthropic` or `openai_codex`,
   Realtime needs its own OpenAI API key, persisted to the same canonical
   location.
2. Voice.
3. Max session minutes and max estimated cost cents.
4. Tool policy (`read_only` or `broad`) and network-tool allowance.
5. Transcript persistence.

Reconfigure flows expose the same fields directly.

Suggested CLI flags:

- `--realtime-enabled`
- `--realtime-api-key`
- `--realtime-voice`
- `--realtime-max-session-minutes`
- `--realtime-max-cost-cents`
- `--realtime-tool-policy`
- `--realtime-allow-network-tools`
- `--realtime-persist-transcripts`

Suggested env overlays:

- `FERMIX_REALTIME_ENABLED`
- `FERMIX_REALTIME_PROVIDER`
- `FERMIX_REALTIME_MODEL`
- `FERMIX_REALTIME_VOICE`
- `FERMIX_REALTIME_MAX_SESSION_MINUTES`
- `FERMIX_REALTIME_MAX_COST_CENTS`
- `FERMIX_REALTIME_TOOL_POLICY`
- `FERMIX_REALTIME_ALLOW_NETWORK_TOOLS`
- `FERMIX_REALTIME_PERSIST_TRANSCRIPTS`

The Realtime API key reuses `OPENAI_API_KEY` rather than introducing a separate
`FERMIX_REALTIME_API_KEY`, because Realtime stores its key in the canonical
`[fermix_core.providers.openai].api_key` slot. Adding a duplicate env var would
create two sources of truth for the same secret.

### 7.2 Readiness

Realtime is optional.

- Disabled: no readiness failure.
- Enabled with OpenAI API key: ready.
- Enabled without OpenAI API key: `setup_required` for `realtime:openai`.
- Enabled with provider other than OpenAI in V1: `setup_required` with a clear
  action to set `provider = "openai"` or disable realtime.

This must be independent of the chat provider. A user may run the normal agent
with `openai_codex`, but Realtime V1 still requires the regular OpenAI API key.

### 7.3 Health

`FermixCore.Health.report/1` gains a `realtime` block:

```elixir
%{
  enabled: boolean(),
  status: :disabled | :ready | :setup_required | :degraded,
  provider: "openai" | nil,
  model: String.t() | nil,
  socket_path: String.t() | nil,
  socket_alive: boolean() | nil,
  active_sessions: non_neg_integer(),
  active_clients: non_neg_integer(),
  companion_connected?: boolean()
}
```

Do not mark all Fermix degraded merely because the companion app is not open.
Only mark realtime degraded if realtime is enabled and the Realtime socket or
session supervisor is expected to be running but is not.

`LocalVoiceSocket` or `SessionSupervisor` owns the active client/session counts
that back `active_clients`, `active_sessions`, and `companion_connected?`.

## 8. Prompt, Memory, and Tools

### 8.1 Prompt composition

Realtime sessions should reuse `PromptComposer.compose_with_metadata/1` for
bootstrap and memory prompt parts, but the generated runtime section must match
the Realtime session's filtered capability snapshot.

Realtime also adds one bootstrap-only file, `REALTIME.md`, loaded only when
`PromptComposer.compose_with_metadata(realtime?: true, ...)` is used. It sits
after USER/MEMORY prompt context and before the generated runtime section, and
narrows behavior for spoken output: short answers, no rambling, interruption
handling, tool-call pacing, and echo/noise caution. Normal text turns must not
load `REALTIME.md`.

Current repo detail: `PromptComposer` passes `available_skills` to
`RuntimeSections.build/1`, and `RuntimeSections.capability_summary/1` reads
built-ins from the global registry. Calling the current API unchanged would
advertise capabilities that Realtime did not expose, causing the model to call
tools that `ToolBridge` denies.

Implementation must add a filtered runtime-section path, for example:

- `RuntimeSections.build(skills, capabilities: filtered_capabilities)`
- or `PromptComposer.compose_with_metadata(runtime_capabilities: filtered_capabilities, available_skills: filtered_skills)`

This is a small public API extension across `PromptComposer` and
`RuntimeSections`, not just Realtime call-site wiring. Keep existing call sites
backward compatible while adding tests for the filtered path.

The generated section and the Realtime `session.tools` payload must derive from
the same capability snapshot.

Because Realtime session instructions are not the same as a list of chat
messages, the implementation should render prompt context into one instruction
payload and insert recent conversation history as conversation items or a
bounded context block, whichever matches the current OpenAI event API best at
implementation time.

### 8.2 Memory

Do not fork a new memory store.

Use `ConversationStore` for transcript turns and `ExtractionDebouncer` for
post-turn fact extraction. Realtime metadata should distinguish:

- mode (`full_duplex_voice_call`)
- device ID
- transcript source
- `source_type = "realtime"`
- `source_id = "local:<device_id>"`
- `kind = "voice_turn"`
- model
- usage
- cost estimate
- tool call summaries

### 8.3 Tools

Realtime tools use the same `Capability` structs as normal turns. The model sees
only the selected tool schema. Internal fields such as `policy_class`,
`hidden_from_agent?`, and executor remain daemon-side.

V1 default tool set should be conservative:

- use `CapabilityRegistry.list/2` with `trust: :third_party`
- exclude approval-required capabilities
- snapshot the resulting list at session start

Future config can expand the set, but mutating voice tools should wait for M10
approval UX so spoken requests do not silently edit files, schedule jobs, run
shell commands, or send network traffic.

## 9. Cost and Privacy Controls

V1 guardrails:

- no session while idle
- no microphone stream while no call is active
- visible active-call/listening indicator
- explicit click-to-start/click-to-end call lifecycle
- max session duration
- idle timeout
- max committed input audio seconds per session
- max estimated cost per session
- transcript persistence off by default
- no raw audio persistence
- no always-listening cloud mode

If transcript persistence is enabled, setup and the companion must say plainly
that spoken transcript text is saved locally under Fermix memory. This is local
storage, but it is still durable storage of speech content.

V2 command-word mode must use local wake detection. It should only open the
OpenAI Realtime session after the command word fires.

V3 always-listening cloud mode, if added, must be explicit opt-in with a clear
cost warning, low default budget, and a visible recording state.

## 10. Telemetry and Traces

New telemetry events:

- `[:fermix, :realtime, :session, :start]`
- `[:fermix, :realtime, :session, :stop]`
- `[:fermix, :realtime, :audio, :input]`
- `[:fermix, :realtime, :audio, :output]`
- `[:fermix, :realtime, :response]`
- `[:fermix, :realtime, :tool, :exec]`
- `[:fermix, :realtime, :usage]`
- `[:fermix, :realtime, :error]`

Trace policy:

- trace state transitions, tool calls, provider errors, and usage
- trace transcript finals if transcript persistence is enabled
- do not trace raw audio
- redact provider headers and socket auth material

## 11. Failure Modes

| Failure | Behavior |
|---------|----------|
| Realtime disabled | No socket, health shows disabled |
| Missing OpenAI API key | Readiness setup_required, no Realtime supervisor |
| Companion cannot connect | Companion shows offline, daemon unaffected |
| OpenAI WebSocket closes | Session enters error state, trace event, close local session |
| Provider rate limit | Send error to companion, close session or pause based on provider event |
| Cost/session cap reached | Send limit event, stop listening, close provider session |
| Transient WebSocket/network error | V1 closes the session loudly; reconnect is V2 |
| User speaks over assistant audio | macOS voice processing suppresses playback echo; OpenAI server VAD interrupts response; explicit pet interrupt also sends `interrupt` and daemon emits `playback_stop` |
| Local socket protocol error | Close that client connection, trace error |
| Oversized audio chunk | Fail loud and close session; do not silently drop audio |
| Tool call unknown/denied | Return tool error output to Realtime and trace denial |
| Transcript persistence fails | Return error state after user-visible response only if recorder failure violates configured persistence requirement; otherwise trace and continue with persistence warning |

## 12. Stage Plan

### Stage 0 - Final API verification

- Re-check OpenAI Realtime docs for current model ID, event names, VAD options,
  audio formats, usage payloads, tool-call flow, connection URL, required
  headers, safety identifier handling, and whether any beta/revision header is
  required.
- Lock exact event structs in tests before writing the client.

### Stage 1 - Config, setup, readiness, health

- Add `[fermix_core.realtime]` to `ConfigStore`.
- Add setup and env overlays.
- Add readiness failure only when realtime is enabled and not configured.
- Add health `realtime` block.
- Add `realtime_socket_enabled` and `enable_realtime_socket/0` beside the
  existing daemon socket gate.
- Tests: config round-trip, disabled readiness, enabled-without-key failure,
  enabled-with-key ready, `fermix doctor`/setup paths do not start Realtime.

### Stage 2 - Core supervision and local voice socket

- Add `FermixCore.Realtime.Supervisor`.
- Add `LocalVoiceSocket` with 0600 UDS.
- Add JSON event protocol parser/encoder.
- Add chunk-size validation with `max_chunk_bytes = 16_384`. Do not add a
  per-turn chunk-count kill switch for the immediate-forwarding V1 path; it
  breaks full-duplex speech because chunks are forwarded continuously.
- Add explicit `interrupt` and pinned `mute` semantics.
- Tests: socket permissions, malformed event failure, call lifecycle,
  backpressure failure, interrupt while speaking, mute keeps session alive.

### Stage 3 - OpenAI Realtime WebSocket client

- Add `{:websockex, "~> 0.4"}` to `fermix_core`.
- Implement `OpenAIClient` with fake-server tests.
- Support session config, audio append, response events, error events, and close.
- Tests: connect auth headers, safety identifier, event decode, provider close,
  error propagation.

### Stage 4 - SessionServer, prompt, tools, recorder

- Start one session per client.
- Select and snapshot capabilities with `trust: :third_party`.
- Compose prompt context with `REALTIME.md` enabled and with a runtime section
  derived from the same snapshot.
- Implement the versioned safety identifier derivation from §6.7 and test that
  it never exposes raw owner or device IDs.
- Execute function calls through `ToolBridge`.
- Persist final transcript turns only when `persist_transcripts = true`, using
  `kind = "voice_turn"`, `source_type = "realtime"`, and
  `source_id = "local:<device_id>"`.
- Request post-turn extraction only when transcript persistence is enabled.
- Tests: prompt lists only exposed tools, tool allow/deny, snapshot survives
  registry mutation, tool result event, conversation writes.

### Stage 5 - Cost and privacy guardrails

- Add `CostTracker`.
- Enforce idle timeout, max duration, input seconds, and cost cap using
  `max(estimated_cost, reported_cost)`.
- Ensure raw audio is never written to trace/memory.
- Tests: cap crossings, usage event emission, no audio persistence, transcript
  persistence disabled by default.

### Stage 6 - macOS companion MVP

- Add `clients/macos/FermixPet`.
- Implement floating UI, states, socket connection, mic capture, playback.
- Replace the temporary status-box UI with the mascot-first pet surface and a
  visible close/quit affordance.
- Use source-build/Xcode plus ad-hoc signing for V1; document Gatekeeper
  quarantine workaround for shared early-access builds.
- Manual validation on macOS: permission prompt, start/end voice call,
  full-duplex mic capture during playback, interrupt/stop, daemon offline state,
  mascot hover controls, and quit behavior.

### Stage 7 - CLI and docs

- Add `fermix voice status`.
- Optional: add companion install/start commands if packaging is stable.
- Update README and roadmap status.
- Add troubleshooting notes for mic permission, missing API key, Gatekeeper,
  transcript persistence, and cost caps.

### Stage 8 - Later activation modes

- Local command word.
- Optional always-listening cloud mode behind explicit opt-in.
- Signal call transport exploration.
- WebRTC/sideband migration only if measured latency requires it.

## 13. Validation Matrix

| Area | Validation |
|------|------------|
| Config | TOML round-trip tests and env overlay tests |
| Readiness | disabled/enabled/missing-key cases |
| Health | realtime block with disabled, ready, setup_required, degraded |
| Socket | UDS permission, protocol parse, malformed event close |
| Session | fake OpenAI server event flow |
| Tools | trust preset selection, filtered prompt summary, snapshot survives registry mutation |
| Memory | transcript persistence opt-in, `voice_turn`, source metadata, no raw audio writes |
| Cost | input estimate, reported usage reconciliation, `max(estimate, reported)` cap enforcement |
| Companion | manual macOS mic/playback/offline/interrupt/Gatekeeper tests |
| Docs | README setup, troubleshooting, roadmap |

## 14. Open Issues and Gaps

1. Native macOS release packaging is outside Burrito. V1 uses source-build/Xcode
   plus ad-hoc signing; Developer ID signing and notarization remain release
   packaging work.
2. Core pins `websockex ~> 0.4` to match the existing channel gateway client
   dependency rather than adding a second WebSocket library.
3. Exact OpenAI Realtime event names must be verified immediately before
   implementation.
4. Base64 audio over JSON is simple and testable, but may need a binary framing
   upgrade if profiling shows overhead.
5. The default tool policy is intentionally conservative. Mutating voice actions
   wait for M10 approval UX.
6. Always-listening and command-word modes are not V1. The cost risk is real if
   background audio is streamed or committed to OpenAI.
7. V1 reconnect is bounded (3 attempts, 1/2/4s backoff per §6.5.4) but
   reconnect-after-failure-loop and reconnect-across-`call_stop` are still
   V2.
8. Realtime per-token pricing changes with model versions. The pricing source
   used by `CostTracker` (see §6.5.2) must point to a single named location and
   be reviewed when bumping `Config.model`.

## 15. Recommendation

Build M9.1 as a core Realtime subsystem plus a native macOS companion. Keep V1
full-duplex, daemon-owned, API-key-safe, transcript-persistence opt-in, and
read-only by default. This gives Fermix the local "desktop assistant" feel
without turning the existing channel dispatcher, transcription module, or
provider adapter into a streaming audio framework.
