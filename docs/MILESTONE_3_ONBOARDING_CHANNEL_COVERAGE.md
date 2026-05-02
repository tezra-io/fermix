# Milestone 3: Onboarding & Channel Coverage — Functional Design

**Status:** Draft  
**Date:** 2026-04-07  
**Author:** Sujeeth / Aira  
**Depends on:** Milestone 2 foundations in current repo  
**References:** `docs/ROADMAP.md` (M3 section), `docs/MILESTONE_2_MULTI_AGENT_ORCHESTRATION.md`, `docs/PROJECT_PLAN.md`

---

## 1. Problem / Goal

Fermix can currently accept messages from Telegram and route them to the persistent `MainAgent`, but the product still assumes a hand-configured, single-channel setup:

- There is no first-run onboarding flow for API keys, channels, or workspace initialization
- Runtime config is assembled from environment variables only and is not validated as a coherent system
- `/health` only reports a static `"ok"` payload and does not reflect provider, channel, or memory readiness
- The web surface is still the default Phoenix landing page, not a Fermix setup experience
- `FermixChannels.Channel` exists as an abstraction, but Telegram is the only implemented channel
- Webhook dispatch is still channel-specific and hardcoded around Telegram

**Milestone 3 makes Fermix installable and operable by a normal user**: boot into a guided setup experience, validate config before real traffic, expose runtime health, and add the next set of channels without changing the stable `MainAgent.handle_message/2` ingress contract.

---

## 2. Scope and Non-Goals

### In Scope

| Feature | Priority | Type |
|---------|----------|------|
| Shared onboarding core for persisted config, validation, and workspace initialization | P0 | New |
| CLI onboarding wizard (`fermix setup` / `mix fermix.setup`) | P0 | New |
| LiveView onboarding at `/setup` using the same shared setup core | P1 | New |
| Runtime config validation with degraded boot behavior | P0 | New |
| Health aggregation for provider connectivity, channel status, memory backend health, and config readiness | P1 | New |
| Generalized channel dispatch/runtime foundation on top of `FermixChannels.Channel` | P0 | Hybrid |
| WhatsApp Cloud API channel | P0 | Rewrite |
| Discord channel (Gateway + REST, scoped to DM/app-mention flow) | P0 | Rewrite |
| Slack channel (Events API + Web API, scoped to DM/app-mention flow) | P1 | Rewrite |
| Signal channel via `signal-cli` subprocess | P1 | Rewrite |
| CLI channel for local interactive testing | P1 | Rewrite |
| Channel-agnostic transcription pipeline for supported voice/audio messages | P1 | Rewrite |

### Non-Goals

| Feature | Reason | Milestone |
|---------|--------|-----------|
| Replacing `MainAgent` as the channel ingress process | M2 established that contract; M3 builds on it | Not in M3 |
| Full multi-provider routing or provider registry | OpenAI remains the only provider in the current repo | Later |
| Full Slack interactivity, slash commands, or workflow apps | Initial scope is message ingress/egress only | Later |
| Discord slash commands, threads, voice, or rich guild automation | Too broad for first Discord cut | Later |
| Signal group management or provisioning UX | Start with existing account + send/receive loop | Later |
| General auth system for the web UI | Security and governance land in M10 | Later |
| Production-ready setup secrets vault | Secrets remain local-file/env based in M3 | Later |
| Phoenix Channels chat UI or dashboard | Roadmap places richer operator UI later | M6 |
| Advanced media understanding beyond speech-to-text | Only transcription is in M3 scope | Later |

---

## 3. Current State / Assumptions

### What exists today

Current repo baseline, as implemented:

```
Umbrella apps
  fermix_core
    ├── MainAgent (persistent GenServer)
    ├── AgentLoop
    ├── SkillRegistry + AgentDefinition
    ├── LifecycleTelemetry + PersistencePolicy
    ├── Tools.Registry + 6 basic tools
    ├── ConversationStore + Store
    └── OpenAI provider

  fermix_channels
    ├── Channel behaviour
    ├── Telegram webhook/parser/outbound module
    └── Telegram poller for polling mode

  fermix_web
    ├── Phoenix endpoint + router
    ├── /health
    ├── /webhook/telegram
    └── default Phoenix home page
```

### Important repo facts

- `FermixCore.Agents.MainAgent` is still the only runtime agent process that accepts inbound channel work.
- `MainAgent.handle_message/2` already provides a stable integration seam for all future channels.
- `FermixChannels.Channel` already defines a normalized inbound message shape and outbound behavior.
- Telegram already supports both webhook and polling mode.
- `FermixCore.Config` is only a typed accessor over `Application.get_env/2`.
- `config/runtime.exs` merges env vars into the application config at boot.
- `config/runtime.exs` currently hard-fails in production for missing provider/channel secrets via `System.fetch_env!/1`.
- `SkillRegistry` currently fail-stops startup on the first invalid `~/.fermix/skills/*/SKILL.md`.
- `FermixChannels.Channel` is currently webhook-oriented and does not yet model gateway, subprocess, or CLI ingress loops.
- `MainAgent` currently accepts `%{content, sender, channel, chat_id, reply_fn}` and does not yet carry optional channel metadata.
- `MainAgent` currently ignores the return value of `reply_fn`, so outbound delivery failures are silent at the agent layer.
- `FermixWebWeb.HealthController` returns a static payload and does not perform subsystem checks.
- The web root is still a Phoenix starter page, so no onboarding UX exists yet.

### Assumptions for M3

1. **Single user remains the target.** Onboarding is for one operator, not multi-tenant administration.
2. **`MainAgent` remains the channel ingress.** All new channels must continue routing normalized messages to `MainAgent.handle_message/2`.
3. **OpenAI remains the only LLM provider.** Onboarding and health checks only need to support the current provider surface.
4. **The web app must still boot when config is incomplete.** Otherwise `/setup` cannot fix missing configuration.
5. **Setup must persist config to disk, not just env vars.** Both CLI and LiveView need a shared write target.
6. **Webhook and long-running channels will coexist.** M3 must support HTTP webhook channels and supervised long-running channel clients under the same runtime model.

---

## 4. High-Level Design

Milestone 3 introduces three new platform layers:

1. **Setup Core**
   A shared configuration and workspace initialization layer used by CLI setup, LiveView setup, startup validation, and health reporting.

2. **Boot Readiness / Health**
   A runtime health model that distinguishes "the node is alive" from "Fermix is ready to process real channel traffic."

3. **Channel Runtime**
   A generalized dispatch layer that lets webhook channels, pollers, WebSocket clients, and subprocess-backed channels all emit the same normalized work into `MainAgent`.

### Core decision

**Decision:** M3 will keep `Application env` as the runtime contract for all existing callers, but it will introduce a persisted config file as the canonical setup artifact. Boot code loads that file, merges env overrides, validates the merged config, and then starts channels accordingly.

This preserves the existing `FermixCore.Config` API while giving onboarding somewhere durable to write.

**Decision:** M3 must explicitly remove non-Phoenix fail-fast startup checks from the provider/channel path. Missing OpenAI or channel credentials should produce `:setup_required` readiness, not prevent the node from booting. Only truly mandatory platform settings such as Phoenix endpoint essentials remain fatal.

**Decision:** M3 baseline assumes persisted setup changes are not hot-applied automatically. After writing config, Fermix validates the new snapshot and reports whether a restart is required. In-process config reload and channel restarts are an optional follow-up, not a hidden assumption in the first implementation.

**Decision:** M3 will split channel concerns into:

- a shared normalized message/outbound contract
- transport-specific ingress contracts for webhook, gateway, subprocess, and CLI runtimes

The current webhook-shaped `FermixChannels.Channel` behaviour is not sufficient by itself for all M3 transports.

**Decision:** `MainAgent.handle_message/2` remains the ingress seam, but its message map grows an optional `metadata :: map()` field so transcription and richer channel context have a place to live without breaking existing callers.

**Decision:** M3 will split health into:

- `/health/live` for process liveness
- `/health/ready` for config and subsystem readiness
- `/health` as a backward-compatible alias of `/health/ready`

This avoids setup-mode restart loops under container orchestration while still exposing useful readiness.

---

## 5. Proposed Components

### 5.1 `FermixCore.Setup.ConfigStore`

**Responsibility:** Read and write persisted user configuration.

**Proposed behavior:**

- Canonical on-disk config lives at `~/.fermix/config.toml`
- Environment variables still override file values at runtime
- CLI and LiveView both use the same writer and validator
- Initial stored shape only needs to cover the current provider/channel set, not the full future RustyClaw schema
- The loader must be usable early enough in boot to populate `Application` env before normal child startup

**Why TOML**

- It matches the roadmap direction toward richer config later
- It is easier to inspect/edit manually than generated Elixir config
- It is a better fit than `.env` for nested channel settings

**Output of the store layer**

The loader should return merged config in the same structure current code already expects:

```
%{
  fermix_core: [...],
  fermix_channels: [...],
  fermix_web: [...]
}
```

That merged structure is then written into `Application` env during boot.

Because the current runtime only reads `Application` env, M3 must keep that as the live config source even after introducing a persisted file.

### 5.2 `FermixCore.Setup.Validator`

**Responsibility:** Validate the merged runtime config and produce a structured readiness report.

**Validation categories**

- Provider config
  - OpenAI auth mode is valid
  - required secrets exist for the chosen auth mode
- Channel config
  - enabled channels have all required credentials
  - channel-specific IDs, secrets, and modes are well-formed
- Filesystem/workspace config
  - `~/.fermix/skills`, `~/.fermix/journals`, `~/.fermix/traces`, `~/.fermix/logs` are writable
  - optional CLI workspace path exists and is readable
- Web config
  - endpoint host/port are present enough for local onboarding

**Current-code constraint**

Validator owns checks that currently exist implicitly in startup code. That includes missing provider/channel secrets that now come from `runtime.exs` and local-skill validity that now comes from `SkillRegistry` startup.

**Validation result**

```
%{
  status: :ready | :setup_required | :degraded,
  errors: [%{scope: :provider | :channel | :filesystem | :web, key: "...", message: "..."}],
  warnings: [...],
  channels: %{telegram: :ready, whatsapp: :disabled, ...},
  providers: %{openai: :ready | :error}
}
```

### 5.3 `FermixCore.Setup.BootReport`

**Responsibility:** Expose the current startup/readiness report to the rest of the system.

This should be a small runtime-owned store, not a separate source of truth. Its job is to make validation results available to:

- `HealthController`
- setup LiveView
- root-page redirect logic
- channel startup decisions

**Decision:** use a lightweight GenServer or `:persistent_term`-backed module with explicit refresh on setup completion. A GenServer is preferred because it keeps future live updates simpler.

`BootReport` should also hold restart-needed state so setup UX can distinguish:

- config is still invalid
- config is valid but the running node has not yet reloaded it
- config is valid and active

### 5.4 `FermixCore.Health`

**Responsibility:** Aggregate runtime health across config, provider connectivity, channel supervision state, and memory backends.

**Checks**

- Config readiness from `BootReport`
- Provider reachability
  - OpenAI API key or OAuth availability
  - lightweight connectivity check
- Channel status
  - enabled/disabled
  - configured/not configured
  - process alive for long-running channels
  - last successful webhook/gateway/poll activity when applicable
- Memory backend health
  - `ConversationStore` process alive
  - `Store` process alive

**HTTP contract**

`GET /health/live` should return:

- `200` whenever the Phoenix node is up enough to serve requests

`GET /health/ready` should return:

- `200` when Fermix is fully ready
- `503` when booted but not ready for normal operation

`GET /health` remains as a backward-compatible alias for `GET /health/ready`.

**Body shape**

```
%{
  status: "ready" | "setup_required" | "degraded",
  app: "fermix",
  version: "0.1.0",
  timestamp: "...",
  config: %{...},
  providers: [%{name: "openai", status: "ready"}],
  channels: [%{name: "telegram", status: "ready", mode: "webhook"}],
  memory: %{conversation_store: "ready", store: "ready"}
}
```

### 5.5 `FermixCore.Setup.Wizard`

**Responsibility:** Shared question/answer engine for CLI and LiveView onboarding.

**Flow**

1. Choose provider auth mode
2. Capture provider credentials
3. Choose which channels to enable
4. Gather per-channel secrets/config
5. Initialize local directories under `~/.fermix/`
6. Write config file
7. Re-run validation

**Important constraint**

The wizard is the shared core. The CLI and LiveView are thin interfaces around it. There must not be two separate onboarding implementations.

### 5.6 `Mix.Tasks.Fermix.Setup` and release-facing setup command

**Responsibility:** Terminal onboarding entrypoint.

**Decision**

- Dev/test entrypoint: `mix fermix.setup`
- Release/user-facing alias: `fermix setup`

The task and release command both call the same wizard core.

### 5.7 `FermixWebWeb.SetupLive`

**Responsibility:** Browser onboarding UI at `/setup`.

**Behavior**

- Render the same setup steps as CLI
- Pre-fill any existing config from `ConfigStore`
- Save via the shared wizard/store path
- Re-run validation after save
- Show a clear "ready", "still incomplete", or "restart required" result

**Security decision**

Because M10 auth is not here yet, setup UI must be restricted:

- available by default only on localhost when config is incomplete
- remote setup requires an explicit opt-in flag
- once config is ready, `/setup` becomes hidden or read-only unless an explicit override is set

### 5.8 `FermixChannels.Registry`

**Responsibility:** Static inventory of supported channels and their runtime metadata.

Each channel definition should expose:

- `name`
- implementation module
- transport type: `:webhook | :polling | :gateway | :subprocess | :cli`
- whether it needs web routes
- whether it runs supervised background processes
- setup fields required for onboarding
- health-check callback

This lets onboarding, validation, health, and startup use one shared channel catalog instead of hardcoded lists in multiple places.

### 5.9 Channel Contracts

**Responsibility:** Separate shared channel concerns from transport-specific ingress mechanics.

**M3 contract split**

- `FermixChannels.Channel`
  - normalized message type
  - outbound `send_message/3`
  - `build_reply/1`
  - optional typing support
- `FermixChannels.WebhookChannel`
  - `verify_webhook/1`
  - `parse_webhook/1`
- gateway/subprocess/CLI runtimes
  - supervised processes that emit normalized `Channel.message()` values directly

This reflects the current repo more honestly. Webhook parsing is one ingress pattern, not the universal channel contract.

**Normalized inbound message shape**

M3 extends the current `Channel.message()` shape with optional fields needed for threading and media:

```
%{
  id: String.t(),
  content: String.t(),
  sender: String.t(),
  channel: String.t(),
  chat_id: String.t(),
  reply_target: String.t(),
  thread_ts: String.t() | nil,
  metadata: map(),
  attachments: [attachment()]
}
```

`attachment()` should minimally carry:

```
%{
  kind: :audio | :image | :file,
  url: String.t() | nil,
  mime_type: String.t() | nil,
  file_id: String.t() | nil,
  size_bytes: non_neg_integer() | nil
}
```

`metadata` holds channel-specific fields that should not be forced into the shared top-level schema.

### 5.10 `FermixChannels.Dispatcher`

**Responsibility:** Convert normalized channel messages into `MainAgent` requests.

This becomes the shared bridge used by:

- `WebhookController`
- Telegram poller
- Discord gateway event loop
- Slack event ingress
- Signal receive loop
- CLI input loop

**Input**

`FermixChannels.Channel.message()` values plus the channel module that can send replies.

**Output**

`MainAgent.handle_message(%{content, sender, channel, chat_id, reply_fn, metadata: %{...}})`

**Why**

Telegram currently owns `build_agent_messages/1`. That pattern does not scale. Reply-function construction belongs in a shared dispatch layer so every channel gets the same MainAgent contract.

**Reply construction contract**

Dispatcher does not synthesize outbound behavior from `reply_target` alone. Each channel module implements:

`build_reply(message) :: {:ok, (String.t() -> :ok | {:error, term()})} | {:error, term()}`

Why this is required:

- Telegram can reply with `chat_id`
- WhatsApp may need normalized phone/message target state
- Discord may need channel ID and reply context
- Slack may need channel ID plus thread reply options

Dispatcher owns normalization into `MainAgent`, but the channel owns reply closure construction.

**Reply delivery contract**

`MainAgent` must stop treating `reply_fn` as fire-and-forget. Baseline M3 behavior:

- call `reply_fn`
- if it returns `{:error, reason}`, log and emit telemetry
- do not silently discard outbound delivery failures
- retries are optional and channel-specific, not a hidden universal mechanism

**Immediate migration requirement**

M3 must replace both current Telegram dispatch call sites:

- `WebhookController`
- `Telegram.Poller`

There should be no remaining direct use of `Telegram.build_agent_messages/1` once Dispatcher lands.

### 5.11 Channel Implementations

#### WhatsApp

**Scope**

- Cloud API webhook receive
- GET verification handshake
- HMAC signature verification
- send text replies
- support inbound voice/audio attachment metadata for transcription path

**Out of scope**

- templates, catalogs, interactive buttons, business workflows

#### Discord

**Scope**

- supervised Gateway client
- heartbeat, session tracking, reconnect
- listen to DMs and app mentions only
- send outbound replies through REST API

**Out of scope**

- slash commands
- voice
- full guild automation

#### Slack

**Scope**

- Events API webhook receive
- request signing verification
- DMs and `app_mention` only
- send outbound replies via Web API

**Out of scope**

- interactivity payloads
- modals
- slash commands

#### Signal

**Scope**

- supervised `signal-cli` receive loop
- subprocess-based send
- direct text messages first, minimal attachment support

**Out of scope**

- provisioning UX
- advanced group features

#### CLI

**Scope**

- interactive stdin/stdout shell loop
- same `MainAgent` path as real channels
- easiest local smoke-test channel

**Why it matters**

This is a development accelerator and a fallback path for testing onboarding and message flow without any external webhook or gateway.

### 5.12 `FermixCore.Transcription`

**Responsibility:** Channel-agnostic speech-to-text service.

**Flow**

1. Channel implementation receives a media event
2. Channel-specific media fetcher downloads the attachment to a temp path
3. `FermixCore.Transcription.transcribe/2` converts audio to text
4. The transcribed text becomes the `content` passed to `MainAgent`
5. Original media metadata is attached to `message.metadata`
6. `MainAgent` threads `metadata` into `AgentLoop` context for future extensions

**Decision**

Keep transcription outside channel modules. Channels should only fetch media and hand it off.

### 5.13 Conversation Identity

**Responsibility:** Define the unit of conversation history and single-flight scheduling across channels.

**Decision**

M3 changes the effective conversation identity from:

`{channel, chat_id}`

to:

`{channel, chat_id, thread_scope}`

where:

- `thread_scope = thread_ts` for threaded channels when present
- `thread_scope = :root` when no thread exists

This identity must be used consistently by:

- `ConversationStore`
- `MainAgent` single-flight request tracking
- `AgentLoop` context
- any future memory extraction that is meant to be thread-aware

This preserves current direct-chat semantics while avoiding history collisions in Slack-style threaded channels.

---

## 6. User and System Flows

### Flow 1: First boot with incomplete config

```
System boots
  → ConfigStore loads persisted config (or none)
  → env overrides are merged
  → Validator returns :setup_required
  → BootReport stores setup-required state
  → invalid local skill files are reported as readiness errors instead of stopping the node
  → Web endpoint starts
  → Long-running channels do not start unless sufficiently configured
  → GET / redirects to /setup
  → GET /health returns 503 with structured setup errors
```

**Desired outcome:** the app stays usable enough to complete setup instead of crashing on missing config.

### Flow 2: CLI onboarding

```
User runs `mix fermix.setup` or `fermix setup`
  → Setup.Wizard loads current config snapshot
  → prompts for provider + channel choices
  → writes ~/.fermix/config.toml
  → creates ~/.fermix/{skills,journals,traces,logs}
  → re-runs Validator
  → prints success report or actionable errors
```

### Flow 3: LiveView onboarding

```
User opens /setup
  → SetupLive reads BootReport + ConfigStore
  → renders provider/channel steps
  → user saves
  → shared wizard/store persists config
  → validator reruns
  → BootReport refreshes to either :ready_pending_restart or :ready
  → UI shows next steps, including restart if required
```

### Flow 4: Webhook-based channel message

Example: WhatsApp or Slack

```
Webhook request → WebhookController.action(channel)
  → channel.verify_webhook(conn)
  → channel.parse_webhook(params)
  → Dispatcher.dispatch(channel_module, messages)
  → MainAgent.handle_message()
  → reply_fn created by channel.build_reply(message)
  → channel.send_message(reply_target, response, opts)
```

### Flow 5: Long-running channel message

Example: Discord or Signal

```
Channel runtime process receives event
  → normalize to Channel.message
  → Dispatcher.dispatch(channel_module, [message])
  → MainAgent.handle_message()
  → reply_fn sends response back through channel module
```

### Flow 6: Voice message with transcription

```
Channel receives audio attachment
  → channel downloads attachment
  → Transcription.transcribe(tempfile, metadata)
  → normalized text message created
  → attachments + channel metadata preserved on the message envelope
  → Dispatcher.dispatch(...)
  → MainAgent processes text like any other message
```

---

## 7. Supervision and Runtime Model

### Core rule

M3 does not change the `MainAgent` ownership model. All channels still terminate in `MainAgent.handle_message/2`.

### Proposed supervision shape

```
FermixCore.Application
  ├── Task.Supervisor
  ├── Trace
  ├── SkillRegistry
  ├── Tools.Registry
  ├── ConversationStore
  ├── Store
  ├── BootReport
  └── MainAgent

FermixChannels.Application
  ├── ChannelRegistry (static or lightweight process if needed)
  ├── [conditional] Telegram.Poller
  ├── [conditional] Discord.Gateway
  ├── [conditional] Signal.Listener
  └── [conditional] CLI.SessionSupervisor

FermixWeb.Application
  ├── Phoenix endpoint
  └── SetupLive / Health / webhook routes
```

### Startup policy

- Web app always starts
- `MainAgent` can still start even in setup-required mode
- `SkillRegistry` must not take the node down for invalid local skill files during setup-required mode; those failures become readiness errors
- long-running channels only start when their config validates
- webhook routes may exist before a channel is ready, but should return clear readiness/auth errors

### Supervision note

This tree lists supervised processes only.

- `LifecycleTelemetry` and `PersistencePolicy` are module-level contracts, not OTP children
- `AgentSupervisor` should appear here once the remaining M2 worker-supervision work lands

---

## 8. Routing and HTTP Surface

### Existing routes

- `GET /`
- `GET /health`
- `GET /health/live`
- `GET /health/ready`
- `POST /webhook/telegram`

### Proposed M3 routes

```
GET  /                 -> root page or redirect to /setup when incomplete
GET  /setup            -> SetupLive
GET  /health           -> backward-compatible readiness alias
GET  /health/live      -> liveness
GET  /health/ready     -> structured readiness report

POST /webhook/telegram -> existing
POST /webhook/whatsapp -> inbound WhatsApp events
GET  /webhook/whatsapp -> verification challenge
POST /webhook/slack    -> inbound Slack Events API
```

Discord, Signal, and CLI do not require HTTP routes for inbound traffic.

### Controller decision

Keep channel-specific controller actions rather than inventing a fully dynamic webhook router in M3. Phoenix route clarity is more important than extra indirection at this stage.

---

## 9. Config and Persistence Contract

### Persisted config target

`~/.fermix/config.toml`

### Runtime precedence

1. hardcoded defaults from `config/config.exs`
2. persisted config file
3. environment variable overrides from `config/runtime.exs`

### Why this order

- preserves existing defaults
- makes setup durable across restarts
- keeps env overrides useful for deploys and CI

### Startup semantics change

M3 requires `runtime.exs` to stop treating missing provider/channel credentials as fatal boot errors. Those conditions move into validation/readiness reporting so the app can boot into setup mode.

### Workspace initialization

On first successful setup, Fermix ensures:

- `~/.fermix/skills/`
- `~/.fermix/journals/`
- `~/.fermix/traces/`
- `~/.fermix/logs/`

M3 does not introduce multi-workspace selection. It only guarantees the single-user local workspace and storage roots exist.

### Sender allowlist semantics

M3 should standardize sender filtering across channels:

- channel disabled = no ingress accepted
- enabled channel + empty allowlist = no sender restriction
- enabled channel + non-empty allowlist = only listed senders accepted

This preserves current Telegram semantics while making the rule explicit for new channels.

---

## 10. Testing Strategy

### Unit tests

- `ConfigStore` read/write/merge behavior
- validator coverage for missing and malformed provider/channel config
- health aggregation logic
- dispatcher reply-function construction
- per-channel webhook signature verification and parsing
- transcription service behavior with mocked provider

### Integration tests

- boot with missing config enters setup-required mode
- invalid local skill file does not prevent `/setup` and `/health` from coming up
- completing setup updates readiness and health
- completing setup reports restart-required when the running node has not reloaded config
- `/setup` renders and persists config
- `/health/live` returns `200` while `/health/ready` returns `503` during setup-required mode
- `/health/ready` returns `200` when ready
- webhook channel end-to-end: webhook -> dispatcher -> MainAgent -> outbound send
- long-running channel end-to-end with mocked gateway/subprocess clients
- CLI channel smoke test around stdin/stdout loop
- thread-aware channel messages do not leak history across separate threads in the same chat
- outbound delivery failures from `reply_fn` are logged and traced

### Regression anchors

Keep these existing seams stable:

- `MainAgent.handle_message/2`
- Telegram webhook and poller behavior
- `FermixChannels.Channel.message()` as the normalized inbound shape

---

## 11. Implementation Order

### Stage 1: Setup and readiness foundation

1. remove fail-fast provider/channel secret loading from `runtime.exs`
2. make `SkillRegistry` startup compatible with degraded setup-required boot
3. `ConfigStore`
4. `Validator`
5. `BootReport`
6. `Health`
7. root redirect behavior and `/setup`

This stage must land before new channels so onboarding and degraded boot behavior are solved once.

### Stage 2: Shared channel runtime

1. split channel contracts into shared outbound + transport-specific ingress behaviours
2. `FermixChannels.Registry`
3. `FermixChannels.Dispatcher`
4. extend `Channel.message()` with `metadata` and `attachments`
5. implement thread-aware conversation identity
6. replace both Telegram dispatch paths with Dispatcher

This stage hardens the contract every new channel will reuse.

### Stage 3: Lowest-risk new channel

1. CLI channel

This gives a zero-external-dependency test path for the generalized runtime.

### Stage 4: P0 external channels

1. WhatsApp
2. Discord

### Stage 5: P1 external channels

1. Slack
2. Signal
3. transcription support across eligible channels

---

## 12. Risks and Mitigations

### Risk: setup cannot recover a broken boot state

**Mitigation:** web endpoint and `/setup` must boot even when validation fails.

### Risk: config sources diverge between CLI, LiveView, and runtime boot

**Mitigation:** one shared `ConfigStore` and one shared validator. No separate writers.

### Risk: channel implementations duplicate Telegram-specific glue

**Mitigation:** centralize `MainAgent` dispatch in `FermixChannels.Dispatcher`.

### Risk: Dispatcher becomes too generic to represent real outbound reply semantics

**Mitigation:** keep reply closure construction in the channel module via `build_reply/1`, not in Dispatcher.

### Risk: threaded channels contaminate each other's conversation history

**Mitigation:** move to `{channel, chat_id, thread_scope}` conversation identity in M3, not later.

### Risk: outbound delivery fails silently after the agent finishes work

**Mitigation:** treat `reply_fn` failures as first-class telemetry/logging events.

### Risk: long-running channel clients become opaque to `/health`

**Mitigation:** each channel definition must expose a health/status callback, including last-seen activity and process liveness.

### Risk: setup UI exposes secret-writing capability without auth

**Mitigation:** local-only setup by default while security/auth remains out of scope.

---

## 13. Open Questions

1. Should persisted config be TOML now, or should M3 stay env-only and only add a file later?
2. For Slack, should we explicitly choose Events API only and defer RTM/Socket Mode despite the roadmap wording?
3. For Discord, is DM + mention scope enough for the first production cut, or do we need slash commands immediately?
4. Which transcription backend should M3 standardize on while OpenAI is the only provider in the repo?
5. Should partial wizard progress be persisted as draft state, or should M3 only persist complete snapshots on explicit save?

## 14. Wizard State Contract

The shared wizard needs an explicit state machine so CLI and LiveView do not drift.

**State shape**

```
%WizardState{
  step: atom(),
  config_snapshot: map(),
  enabled_channels: [atom()],
  validation_errors: [map()],
  dirty?: boolean()
}
```

**Rules**

- provider selection is always required
- channel-specific steps are skipped when that channel is not enabled
- rerunning setup loads the existing config snapshot and allows editing a subset
- baseline M3 persists only complete snapshots on explicit save
- aborting setup does not write partial config to disk
- CLI and LiveView both consume the same state transitions and validation responses

---

## 15. Summary

Milestone 3 should not be treated as "add some more webhook handlers." It is the phase that makes Fermix installable, debuggable, and extensible as a real product.

The key architectural decisions are:

- keep `MainAgent.handle_message/2` as the universal ingress contract
- add a persisted config layer with shared validation
- boot into a usable setup-required mode instead of crashing on incomplete config
- centralize channel-to-agent dispatch before adding more channels
- ship onboarding, health, and channel expansion as one coherent runtime story

That foundation keeps the current repo stable while making WhatsApp, Discord, Slack, Signal, CLI, and transcription additive rather than one-off implementations.
