# Milestone 9.2: Full-Duplex Voice Mode — Functional Design

**Status:** Draft reviewed against current OpenAI Realtime docs on 2026-05-16
**Milestone:** M9 Differentiators
**Depends on:** M9.1 Realtime Local Voice Companion (shipped in `bc39905`)
**Informs:** M10 approval/governance, future always-listening modes

## 1. Purpose

M9.1 shipped a native macOS Realtime voice companion. On the wire and in the
daemon, that pipeline is already full-duplex — the microphone keeps streaming
through assistant playback, OpenAI server VAD owns turn boundaries, and
`conversation.item.truncate` is sent on barge-in.

But end-user perception is half-duplex. The assistant cuts itself off mid-word,
the user feels they have to wait for silence, and the session ends after a few
seconds of quiet. The cause is not the protocol — it is three concrete things
in the current code:

1. The macOS audio engine never enables voice processing, so assistant speaker
   output bleeds back into the microphone and OpenAI's server VAD reads that as
   user speech, firing `interrupt_response` against the assistant's own audio.
2. The daemon enforces a 30-second idle timeout that closes the session if the
   user pauses, which is a half-duplex turn-taking assumption.
3. A separate `max_input_audio_seconds_per_session` cap counts every microphone
   chunk against a 10-minute budget, again a half-duplex assumption that
   transmission-time equals talk-time.

This milestone keeps the click-to-open-call activation model from M9.1 but
makes the in-call experience true full-duplex by fixing those three items,
plus a tight set of related cleanups in config, setup wizard, and pet UI.

## 2. References

- `docs/MILESTONE_9_1_REALTIME_VOICE.md` — the M9.1 design that landed.
- `apps/fermix_core/lib/fermix_core/realtime/session_server.ex` — the daemon
  session state machine and timer logic that this milestone trims.
- `apps/fermix_core/lib/fermix_core/realtime/config.ex` — the realtime config
  struct, normalization, and rejected-keys contract.
- `apps/fermix_core/lib/fermix_core/realtime/openai_client.ex` — the
  nested `session.update` payload that pins `server_vad` semantics.
- `apps/fermix_core/lib/fermix_core/setup/wizard.ex` — the install wizard's
  `realtime_prompts/1` block.
- `clients/macos/FermixPet/Sources/FermixPet/AudioController.swift` — the
  `AVAudioEngine` setup that currently lacks AEC.
- OpenAI Realtime conversation guide:
  `https://developers.openai.com/api/docs/guides/realtime-conversations`
  (`gpt-realtime-2`, `session.update`, nested `audio.input` /
  `audio.output`, and the 60-minute provider session cap).
- OpenAI Realtime VAD guide:
  `https://developers.openai.com/api/docs/guides/realtime-vad`
  (`server_vad`, `semantic_vad`, `create_response`, and
  `interrupt_response`).
- OpenAI Realtime API reference:
  `https://developers.openai.com/api/reference/resources/realtime`
  (`audio.input.noise_reduction`, `audio.input.turn_detection`,
  `output_modalities`, and Realtime event schemas).
- OpenAI `gpt-realtime-2` model page:
  `https://developers.openai.com/api/docs/models/gpt-realtime-2`
  (Realtime 2 modalities, function calling support, pricing shape, and
  configurable reasoning effort caveat).
- Apple `AVAudioInputNode.setVoiceProcessingEnabled(_:)` docs for the AEC API
  used in §6.1.

## 3. Current State Audit

Verified by reading the bc39905 source.

### 3.1 Already full-duplex shaped

- `OpenAIClient.session_update_event/3` already uses the current nested
  Realtime session shape: `session.type = "realtime"`, `model =
  "gpt-realtime-2"`, `output_modalities = ["audio"]`,
  `audio.input.format = {type: "audio/pcm", rate: 24000}`,
  `audio.output.format = {type: "audio/pcm", rate: 24000}`, and
  `audio.input.turn_detection.type = "server_vad"`.
- The VAD block pins `create_response = true`, `interrupt_response = true`,
  `threshold = 0.5`, `prefix_padding_ms = 300`, and
  `silence_duration_ms = 800`.
- `audio.input.noise_reduction.type` is currently `"near_field"`. Current
  OpenAI docs say `near_field` is for close-talking microphones such as
  headphones, while `far_field` is for laptop and conference-room
  microphones. Because M9.2 targets macOS laptop use first, this milestone
  should switch the default to `"far_field"` unless route detection proves
  the active input is a headset.
- `SessionServer.handle_call({:audio_chunk, _}, ...)` accepts audio in every
  non-muted state once `openai_pid` is set, including during assistant
  playback.
- After `response.done`, the daemon emits `state: "listening"` and clears
  `current_item_id`, not `state: "idle"`.
- `SessionServer.maybe_send_truncate/3` sends `conversation.item.truncate`
  before `response.cancel` on user-driven `interrupt`, with the played-ms
  the pet tracks via `AudioController.currentUtterancePlayedMs()`.
- `AudioController.startCapture` installs a continuous tap on the input node;
  it does not pause during playback.
- `AVAudioPlayerNode` schedules buffers through `mainMixerNode` and does not
  block the input path.

### 3.2 Click-to-talk artifacts to remove

- **No macOS AEC.** `AudioController.init` builds `AVAudioEngine()` but never
  calls `engine.inputNode.setVoiceProcessingEnabled(true)`. On laptop
  speakers, the assistant interrupts itself within one or two sentences.
- **Idle timeout.** `SessionServer` arms a 30s idle timer
  (`Config.idle_timeout_ms`) on every chunk and closes the session with
  `error: "idle_timeout"` if the user pauses. That is half-duplex turn-taking;
  in a full-duplex call, only an explicit `call_stop` or the cost/duration
  cap should end the call.
- **Per-session input audio cap.** `CostTracker.add_input_audio_ms/2` plus
  `Config.max_input_audio_seconds_per_session` (default 600s) caps total
  transmitted mic time. With continuous streaming this trips after 10 minutes
  of real time even if the user spoke for two minutes. The
  `max_session_minutes` and `max_estimated_cost_cents_per_session` caps
  already cover the legitimate cost-control intent.
- **Pet `.success` state.** `CompanionState.handle(event:)` flips to
  `.success` on `tool_event.status = "completed"` and never moves off it
  except on the next state push. It is a half-duplex hangover and produces
  a stutter on tool calls.
- **Wizard surfaces realtime asymmetrically across fresh install vs.
  reconfigure.** `Wizard.realtime_prompts/1` returns all eight realtime
  prompts, but only `realtime_api_key` carries `required?: true` (and only
  when `openai_api_key_unset?`). `Wizard.prompts/1` filters by `required?`,
  so fresh installs see at most a single realtime line — `realtime_enabled`
  itself is invisible and new users have no first-run path to opt into
  voice. `Wizard.reconfigure_prompts/1` then forces `required?: true` on
  every realtime key, so anyone who runs reconfigure walks through all
  eight whether or not they answer yes to enable. Two problems wearing
  different shirts: voice is invisible on first run, and voice setup is
  verbose on reconfigure.

### 3.3 Things that look click-to-talk but stay

- `call_start` / `call_stop` socket events — explicit call lifecycle is the
  decided UX (see clarification on activation model). The microphone
  permission prompt and the OpenAI WebSocket cost only fire when the user
  opens a call. That is the boundary.
- `mute` event — full-duplex calls still benefit from a "stay live but pause
  my mic" affordance. The pet UI should expose this; the daemon already
  supports it.
- `interrupt` event with `audio_end_ms` — required for truncate; not a
  click-to-talk artifact.

## 4. Product Contract

### 4.1 What "full duplex" means here

- The pet opens a call with a click. From that point on:
  - The microphone streams continuously to OpenAI Realtime.
  - macOS voice processing removes the assistant's speaker output from the
    captured mic signal so the assistant does not hear itself.
  - OpenAI server VAD owns when the user has finished a turn and when to
    create the next response.
  - The user may speak at any time, including during assistant playback;
    OpenAI's `interrupt_response: true` truncates the assistant naturally.
  - The user may pause without tripping a local idle close; only the user's
    click, the local max-session-minutes cap, OpenAI's 60-minute Realtime
    session cap, the cost cap, or a hard provider failure ends the call.

### 4.2 Non-goals (still)

- Always-listening when the pet is launched (out of scope; this milestone
  keeps the explicit `call_start` boundary).
- Software echo cancellation as a fallback when macOS AEC fails (the call
  still runs without AEC, but the user is warned and the assistant may
  self-interrupt on loud speakers).
- Wake-word activation.
- Raw audio persistence.
- Mutating voice tools beyond M9.1's `trust: :third_party` snapshot.

## 5. Architecture

No new components. The change set is in seven places:

```text
clients/macos/FermixPet/Sources/FermixPet/AudioController.swift
  enable AVAudioEngine voice processing (AEC) on capture start

apps/fermix_core/lib/fermix_core/realtime/session_server.ex
  drop :idle_timeout timer + handler + state field

apps/fermix_core/lib/fermix_core/realtime/cost_tracker.ex
  drop max_input_audio_seconds_per_session enforcement

apps/fermix_core/lib/fermix_core/realtime/config.ex
  remove idle_timeout_ms and max_input_audio_seconds_per_session;
  keep the persisted setup surface explicit

apps/fermix_core/lib/fermix_core/realtime/openai_client.ex
  keep current nested Realtime session.update shape; switch macOS-first
  noise reduction to far_field; decide how to expose gpt-realtime-2
  reasoning effort only after verifying the exact Realtime session field

apps/fermix_core/lib/fermix_core/setup/wizard.ex
  short-circuit realtime_prompts/1 on enabled = false; trim secondary prompts

clients/macos/FermixPet/Sources/FermixPet/{CompanionState,PetView}.swift
  drop .success state; add mute control in ControlDock
```

## 6. Components

### 6.1 macOS AEC (the load-bearing change)

`AudioController.startCapture/1` must enable voice processing on the input
node before installing the tap:

```swift
do {
    try engine.inputNode.setVoiceProcessingEnabled(true)
} catch {
    NSLog("FermixPet: voice processing unavailable, continuing without AEC: %@",
          String(describing: error))
}
```

Notes:

- `setVoiceProcessingEnabled(_:)` must be called before the engine is started
  and before any tap is installed; the current code starts the engine lazily
  in `startEngineIfNeeded`. The call order in `startCapture` must change to:
  `setVoiceProcessingEnabled(true)` → `installTap` → `startEngineIfNeeded`.
- After voice processing is enabled, the input node's format may change
  (system AEC is fixed at 16 kHz mono on most hardware). The existing
  `AVAudioConverter` chain already converts to 24 kHz mono PCM16, so the
  rate change is absorbed there; `Self.usableInputFormat(from:)` must be
  re-read after enabling voice processing, not before.
- `setVoiceProcessingEnabled` can throw on devices that do not support voice
  processing (some external interfaces, virtual mics). On throw, log a
  warning and continue without AEC. The session still works; it just risks
  self-interruption on loud speakers, which is documented in §11.
- Telemetry: `AudioController.startCapture` should report AEC status back
  to `CompanionState` so the pet can mark the session "AEC off" in tooltips
  and the daemon can include it in `[:fermix, :realtime, :session, :start]`
  metadata.

### 6.2 OpenAI Realtime 2 session contract

M9.2 should keep the current GA Realtime session shape rather than the older
beta top-level audio fields:

```elixir
%{
  type: "session.update",
  session: %{
    type: "realtime",
    model: "gpt-realtime-2",
    output_modalities: ["audio"],
    audio: %{
      input: %{
        format: %{type: "audio/pcm", rate: 24_000},
        noise_reduction: %{type: "far_field"},
        transcription: %{model: config.transcription_model},
        turn_detection: %{
          type: "server_vad",
          threshold: 0.5,
          prefix_padding_ms: 300,
          silence_duration_ms: 800,
          create_response: true,
          interrupt_response: true
        }
      },
      output: %{
        format: %{type: "audio/pcm", rate: 24_000},
        voice: config.voice
      }
    }
  }
}
```

Notes:

- `gpt-realtime-2` is the only valid Realtime model for this milestone.
- `server_vad` remains the chosen turn detector because the current daemon
  relies on deterministic `speech_started` / `speech_stopped` events and
  explicit truncation. `semantic_vad` is valid in the API, but is a future
  tuning pass, not part of the AEC/half-duplex cleanup.
- Do not set provider `audio.input.turn_detection.idle_timeout_ms`.
  OpenAI's field is an optional "prompt the user after a long pause" behavior,
  not the local session-closing timeout this milestone removes.
- `gpt-realtime-2` supports configurable reasoning effort. Higher effort can
  increase latency and output token usage, which matters in voice. M9.2 should
  not add a wizard prompt for this. If Stage 0 verifies the exact Realtime
  `session.update` field, add an advanced TOML/env-only key with a
  latency-oriented default; otherwise leave the model default untouched and
  document that the field is intentionally absent.
- Voice cannot be changed after the first audio output in a session, so any
  voice update must happen before the first assistant audio response.

### 6.3 SessionServer state machine cleanup

Remove from `SessionServer`:

- `:idle_timer` field in state.
- `reset_idle_timer/1` helper and all call sites
  (`open_openai_session`, `handle_call({:audio_chunk, _}, ...)`,
  `handle_call({:interrupt, _}, ...)`, `handle_info(:reconnect_attempt, ...)`).
- `handle_info(:idle_timeout, state)` clause.
- The branch in `start_timers/1` that schedules the idle timer.
- The `Process.cancel_timer(state.idle_timer)` branch in `cancel_timers/1`.

Keep:

- `:max_session_timer` and `handle_info(:max_session_duration, state)`.
- Cost-cap enforcement via `CostTracker.enforce_limits/1` on every
  `audio_chunk` and on `response.done` usage reconciliation.

After cleanup, `start_timers/1` collapses to a single `Process.send_after`
for the duration cap, and `cancel_timers/1` to one `Process.cancel_timer`
plus the reconnect timer.

### 6.4 CostTracker cleanup

Remove from `CostTracker`:

- `enforce_limits/1` branch that checks input-audio seconds.
- The estimated-input-seconds field used only for that cap (if it exists
  solely for the cap; if it is also used for telemetry, keep the value and
  drop only the cap check).

Keep:

- Cents-based cost cap using `max(estimated, reported)` (§6.5.2 of M9.1).
- Audio-output token estimate during streaming and the `response.done`
  reconciliation.

### 6.5 Config cleanup

Remove from `FermixCore.Realtime.Config`:

- `idle_timeout_ms` field, default (30_000), normalize branch, struct entry.
- `max_input_audio_seconds_per_session` field, default (600), normalize
  branch, struct entry.

Reject removed keys explicitly in `Config.normalize/1`, the same way
`:activation` and `:turn_detection` are already rejected:

```elixir
reject_removed_key!(config, :activation)
reject_removed_key!(config, :turn_detection)
reject_removed_key!(config, :max_buffer_chunks)
reject_removed_key!(config, :idle_timeout_ms)
reject_removed_key!(config, :max_input_audio_seconds_per_session)
```

Reason: the daemon must fail loud if an old persisted TOML still carries
these keys. A silent drop would hide a stale install for weeks.

Also remove `ConfigStore.drop_legacy_realtime_keys/1`. The config store should
not silently strip stale Realtime TOML before handing it to
`RealtimeConfig.normalize/1`.

Migration: there is no boot-time migration. M9.1 is a few days old, no
third-party installs exist, and Fermix policy is "no fallbacks" (CLAUDE.md
§12). A hand-edited stale `config.toml` should fail with a clear removed-key
message. Re-running setup against a valid snapshot rewrites the persisted
Realtime block in the clean shape below.

### 6.6 Setup wizard cleanup

`Wizard.realtime_prompts/1` becomes a two-stage list:

1. Always: `realtime_enabled` (yes/no, default no).
2. Only if the answer is yes:
   - `realtime_api_key` (skipped when the main agent provider is `openai`
     and the canonical key is already set, per M9.1 §7.1).
   - `realtime_voice` (default `marin`).
   - `realtime_max_session_minutes` (default 15).
   - `realtime_max_cost_cents` (default 100).

Drop from the wizard entirely:

- `realtime_persist_transcripts` — privacy-sensitive, off by default,
  configurable via TOML or env.

Note: `realtime_tool_policy` was removed entirely in 2026-05.
`realtime_allow_network_tools` was also removed in 2026-05 — see §F-03 of
`docs/audit/fermix_audit_2026-05-18.md` for the rationale. Voice now
uses the same capability surface as the main agent — sandbox mode +
command profile cover voice scope. See the rationale in
`Realtime.SessionServer.default_capabilities/1`.

Implementation note: today `Wizard.realtime_prompts/1` returns all eight
prompts with `required?: false` (except `realtime_api_key`), so
`Wizard.prompts/1` filters them out on fresh install and `realtime_enabled`
never appears. The fix has two parts:

1. Make `realtime_enabled` itself required on fresh install so voice is
   surfaced at all. `Wizard.prompts/1` (or `prompt_specs/1`) must set
   `required?: true` on `realtime_enabled` when there is no persisted
   realtime block.
2. When `realtime_enabled` resolves to true, append the secondary prompts
   (`realtime_api_key` when the canonical OpenAI key is missing,
   `realtime_voice`, `realtime_max_session_minutes`,
   `realtime_max_cost_cents`) with `required?: true`. When it resolves to
   false, return only the enable prompt.

`Wizard.reconfigure_prompts/1` should apply the same two-stage shape rather
than force `required?: true` on every realtime key, so reconfigure no
longer asks about voice model, session minutes, cost cents, tool policy,
network tools, and transcript persistence after the user answers "no".

If the runner does not currently support re-evaluating prompts after an
answer arrives, the cleanest fix is to have the realtime prompt list
return `[realtime_enabled]` first, then append the rest when the answer
is in. Verify against the actual `Wizard` flow in implementation.

Env overlays in `config/runtime.exs` stay as they are. `FERMIX_REALTIME_*`
remains the escape hatch for advanced operators; the wizard simply does not
prompt for them.

The generated `FERMIX_HOME/config.toml` block must be explicit:

```toml
[fermix_core.realtime]
enabled = true
provider = "openai"
model = "gpt-realtime-2"
voice = "marin"
max_session_minutes = 15
max_estimated_cost_cents_per_session = 100
persist_transcripts = false
```

Do not persist `activation`, `turn_detection`, `idle_timeout_ms`,
`max_buffer_chunks`, `max_input_audio_seconds_per_session`, raw audio
persistence, or any provider VAD shape under `[fermix_core.realtime]`.
`OpenAIClient` owns the Realtime API payload. The setup config only owns
operator policy: enabled state, OpenAI model/voice, duration and cost caps,
tool scope, network-tool allowlist policy, and transcript persistence.

If Stage 0 verifies a supported Realtime 2 reasoning-effort field in
`session.update`, add `reasoning_effort` as an advanced TOML/env key here
and in `Config.to_keyword/1`; keep it out of the first-run wizard.

### 6.7 Pet UI cleanup

`CompanionState`:

- Drop the `.success` enum case and the branch in `handle(event:)` that flips
  to `.success` on `tool_event.status = "completed"`. The pet should stay
  in `.toolUse` until the next `state` event from the daemon, then transition
  to `.listening` naturally.
- Track `muted: Bool` and add `setMute(_ enabled: Bool)` that sends
  `{type: "mute", enabled: bool}` and updates local state immediately.
- On `state: "muted"` event from daemon, render the muted mascot variant.

`PetView` / `ControlDock`:

- Add a mute toggle button alongside the existing mic and interrupt buttons.
  Render with `mic.slash.fill` when muted, `mic.fill` when live.
- Remove `.success` from the `tint`/`iconName` switches.

`PetExpression`:

- If a `.success` expression mapping exists, drop it. Leave the rest
  unchanged.

### 6.8 REALTIME.md prompt

The bootstrap file at `apps/fermix_core/priv/templates/realtime.md.eex`
loads only when `PromptComposer.compose_with_metadata(realtime?: true, ...)`
is called (see M9.1 §8.1). Verify the current content does not instruct the
model to wait for silence or assume turn-by-turn delivery. If it does,
trim those lines.

The prompt should reinforce:

- Keep responses short; the user can interrupt at any time.
- If interrupted, stop immediately and listen.
- Do not announce yourself before answering.
- Tool calls should be concise; long stalls feel wrong in voice.

This is a content-only change in the existing template. No new file.

## 7. Setup, Readiness, Health

### 7.1 Setup

Wizard prompt list reduced as per §6.6. CLI flags
(`--realtime-*`) and env overlays (`FERMIX_REALTIME_*`) are unchanged.
The README setup section must show the same config-file shape as §6.6 and
must not document removed `activation` or `turn_detection` controls.

Interactive setup asks for only:

- `realtime_enabled`
- `realtime_api_key` when no reusable OpenAI API key is persisted
- `realtime_voice`
- `realtime_max_session_minutes`
- `realtime_max_cost_cents`

Non-interactive setup may still accept the advanced flags that map directly
to persisted policy keys:

- `--realtime-tool-policy`
- `--realtime-allow-network-tools`
- `--realtime-persist-transcripts`

Runtime env overlays stay:

- `FERMIX_REALTIME_ENABLED`
- `FERMIX_REALTIME_PROVIDER`
- `FERMIX_REALTIME_MODEL`
- `FERMIX_REALTIME_VOICE`
- `FERMIX_REALTIME_MAX_SESSION_MINUTES`
- `FERMIX_REALTIME_MAX_COST_CENTS` /
  `FERMIX_REALTIME_MAX_ESTIMATED_COST_CENTS_PER_SESSION`
- `FERMIX_REALTIME_TOOL_POLICY`
- `FERMIX_REALTIME_ALLOW_NETWORK_TOOLS`
- `FERMIX_REALTIME_PERSIST_TRANSCRIPTS`

Removed flags/env (none were ever exposed for the dropped fields):

- No `--realtime-idle-timeout-ms` exists today; nothing to remove on the
  CLI surface.
- No `FERMIX_REALTIME_IDLE_TIMEOUT_MS` exists today; same.
- `FERMIX_REALTIME_ACTIVATION` and `FERMIX_REALTIME_TURN_DETECTION` appear in
  README today but are not supported by `config/runtime.exs`; remove them
  from docs rather than adding compatibility.

If any are discovered during implementation, remove them.

### 7.2 Readiness

No change. Realtime stays optional; readiness fails only when
`realtime.enabled = true` and the OpenAI API key is missing or the
configured provider is not `openai`.

### 7.3 Health

`FermixCore.Health.report/1`'s `realtime` block stays the same shape. Add
one optional field:

```elixir
%{
  ...
  aec_status: :enabled | :disabled | :unknown
}
```

The macOS pet reports AEC status back over the socket in `client_hello` or
on the first `call_start`; the daemon stores it on the session and reflects
the last observed value in health. `:unknown` is the default when no
companion has connected.

This is optional; if the AEC status thread feels like scope creep during
implementation, drop the health field and rely on telemetry only.

## 8. Cost and Privacy

Unchanged from M9.1 except:

- Idle timeout no longer fires. A user can pause inside a call without the
  daemon ending the session. The session ends on click, cost cap,
  `max_session_minutes`, OpenAI's 60-minute Realtime session cap, or hard
  provider failure.
- Per-session input-audio-seconds cap removed.

The local `max_session_minutes` (default 15) and
`max_estimated_cost_cents_per_session` (default 100) caps remain the only
Fermix-owned automatic close conditions. That is intentional: cost is the cap
that matters, and minutes is the cap that prevents an open mic from running
until the laptop sleeps.

## 9. Telemetry and Traces

Existing events stay. Add one measurement field:

- `[:fermix, :realtime, :session, :start]` metadata gains
  `aec_status: :enabled | :disabled | :unknown`.

Remove obsolete events (only if they exist today):

- Any `:idle_timeout` trace event in the realtime namespace.

## 10. Failure Modes (delta from M9.1)

| Failure | Old behavior (M9.1) | New behavior (M9.2) |
|---------|----------------------|----------------------|
| User pauses 30s in call | Daemon closes session, pet shows `error: idle_timeout` | Daemon keeps session open; pet stays in `listening` |
| Mic time hits 10 min in call | Daemon closes session, pet shows usage limit | Removed; only cost cap + duration cap apply |
| macOS AEC unavailable | Not a failure mode (AEC was never enabled) | Pet logs warning, session still runs without AEC, daemon records `aec_status: :disabled` |
| Assistant playback bleeds into mic | Server VAD triggers `interrupt_response` against assistant's own audio; assistant cuts itself off | macOS AEC strips playback from mic input; assistant continues uninterrupted |

All other failure modes (provider error, WebSocket close, oversized chunk,
unknown tool, transcript persistence error) are unchanged.

## 11. Stage Plan

### Stage 0 — API verification

- Re-verify against current OpenAI Realtime docs that
  `audio.input.turn_detection = server_vad` with `interrupt_response = true`
  is still the recommended full-duplex configuration.
- Confirm `audio.input.noise_reduction.type = "far_field"` is accepted on
  `gpt-realtime-2` and use it as the macOS laptop default. `near_field`
  remains valid for headsets but is not the default target for this milestone.
- Verify the exact `session.update` field for Realtime 2 reasoning effort.
  If the field is documented and accepted, add advanced TOML/env-only
  support; otherwise leave it unset and document the omission.

### Stage 1 — macOS AEC

- Add `setVoiceProcessingEnabled(true)` to `AudioController.startCapture`
  with the call-order fix from §6.1.
- Surface AEC status to `CompanionState`.
- Manual validation: assistant continues speaking on Mac laptop speakers
  without self-interrupting; mic captures user voice cleanly when user
  interrupts.

### Stage 2 — Daemon cleanup

- Remove `idle_timeout_ms` and `max_input_audio_seconds_per_session` from
  `Config` (struct, default, normalize, rejected-keys, to_keyword).
- Remove `ConfigStore.drop_legacy_realtime_keys/1` so stale realtime TOML
  fails loudly instead of being silently rewritten.
- Remove `:idle_timer`, `:idle_timeout` handler, `reset_idle_timer/1`, and
  related cancel/start logic from `SessionServer`.
- Remove input-seconds enforcement from `CostTracker`.
- Update `OpenAIClient.session_update_event/3` to use `far_field` noise
  reduction for macOS-first capture.
- Update tests in `apps/fermix_core/test/fermix_core/realtime/`:
  - `config_test.exs`: drop `idle_timeout_ms` round-trip, drop input-seconds
    round-trip, add rejected-key assertions for `activation`,
    `turn_detection`, `max_buffer_chunks`, `idle_timeout_ms`, and
    `max_input_audio_seconds_per_session`.
  - `session_server_test.exs`: drop idle-timeout test, drop input-seconds
    cap test.
  - `cost_tracker_test.exs`: drop input-seconds cap test.

### Stage 3 — Wizard simplification

- Mark `realtime_enabled` as `required?: true` on fresh install (no
  persisted realtime block) so first-run users see the prompt.
- Reshape `Wizard.realtime_prompts/1` (and `reconfigure_prompts/1`) so
  that when `realtime_enabled` resolves to `true` it appends the
  secondary prompts (`realtime_api_key` only when the canonical OpenAI
  key is missing, `realtime_voice`, `realtime_max_session_minutes`,
  `realtime_max_cost_cents`) with `required?: true`, and when it resolves
  to `false` it returns only the enable prompt.
- Drop `realtime_persist_transcripts` from both prompt lists.
  (`realtime_tool_policy` and `realtime_allow_network_tools` were both
  removed entirely in 2026-05; existing configs fail loud via
  `reject_removed_key!`.)
- Update wizard tests to assert:
  - fresh install with no persisted realtime block surfaces
    `realtime_enabled`,
  - answering "no" to `realtime_enabled` returns no further realtime
    prompts,
  - answering "yes" returns api_key (only when needed), voice, session
    minutes, cost cents.
- Update setup/config-store tests to assert the generated
  `[fermix_core.realtime]` block matches §6.6 and does not contain
  `activation`, `turn_detection`, `idle_timeout_ms`, `max_buffer_chunks`, or
  `max_input_audio_seconds_per_session`.

### Stage 4 — Pet UI cleanup

- Drop `.success` enum case in `CompanionState.Mode`.
- Add mute toggle button and `setMute/_` flow.
- Update `PetView`, `ControlDock`, `PetExpression`.

### Stage 5 — Telemetry + health

- Plumb AEC status from pet → daemon → telemetry → health (optional, scope
  in if cheap; drop if it grows).

### Stage 6 — Docs

- Update `docs/ROADMAP.md` to add M9.2 row under Milestone 9.
- Update `CLAUDE.md` "Docs" list to point at `MILESTONE_9_2_FULL_DUPLEX_VOICE.md`.
- Update `MILESTONE_9_1_REALTIME_VOICE.md` status to note V1 shipped and V1.1
  (this milestone) is the cleanup pass.
- Add a short paragraph in README if it currently uses the phrase
  "click-to-talk" (it does, per `git grep`).
- Remove README references to `--realtime-activation`,
  `FERMIX_REALTIME_ACTIVATION`, and `FERMIX_REALTIME_TURN_DETECTION`; add the
  canonical `[fermix_core.realtime]` config example from §6.6.
- Update `clients/macos/FermixPet/README.md` so it describes explicit
  click-to-open-call capture with continuous in-call streaming, not the old
  click-to-talk / click-toggle framing.

## 12. Validation

| Area | Test |
|------|------|
| AEC on Mac | Manual: open call, let assistant speak full paragraph through laptop speakers, verify no self-interrupt |
| Idle | Manual: open call, stay silent 60s, verify session stays open |
| Cost cap | Unit: `CostTracker.enforce_limits/1` still closes session on cost overrun |
| Duration cap | Unit: `SessionServer` still closes session at `max_session_minutes` |
| Realtime API payload | Unit: `OpenAIClient.session_update_event/3` emits nested `audio.input.turn_detection`, `output_modalities = ["audio"]`, `model = "gpt-realtime-2"`, and macOS-first `noise_reduction.type = "far_field"` |
| Removed config keys | Unit: `Config.normalize/1` raises on `:activation`, `:turn_detection`, `:max_buffer_chunks`, `:idle_timeout_ms`, and `:max_input_audio_seconds_per_session` |
| Setup config file | Unit: `ConfigStore.save_snapshot/1` writes the canonical `[fermix_core.realtime]` block and no removed keys |
| Wizard | Unit: `realtime_enabled = no` returns only the enable prompt |
| Wizard | Unit: `realtime_enabled = yes` returns api_key (when needed), voice, session minutes, cost cents |
| Pet UI | Manual: mute button toggles mic stream; daemon shows `state: muted`; daemon shows `state: listening` on unmute; tool calls do not flash `.success` |

## 13. Open Issues

1. AEC unavailability on some external audio interfaces is documented but
   not actively detected at install time. A future `fermix doctor` check
   could probe AEC capability before the user opens a call.
2. AEC may not fully suppress loud speaker playback in some rooms. If
   user reports show meaningful self-interruption with AEC on, the next
   step is either a software AEC layer or pushing OpenAI's `threshold`
   higher and `silence_duration_ms` lower at the cost of slower
   barge-in detection.
3. The `mute` socket event was specified in M9.1 §6.3 but the pet UI never
   surfaced it. This milestone adds the UI but does not revisit the wire
   protocol; the existing payload shape `{type: "mute", enabled: bool}`
   stays.

## 14. Recommendation

Ship M9.2 as small staged commits matching the plan above. The single change
that matters most is Stage 1 (macOS AEC) — without it, every other cleanup is
cosmetic. Stages 2–4 remove the half-duplex assumptions the AEC fix exposes;
without them, a long-pause user trips the idle timeout the same afternoon.
The wizard and pet UI cleanups (Stages 3–4) are not on the critical path but
should land together with Stage 2 to keep the persisted config and CLI surface
consistent.
