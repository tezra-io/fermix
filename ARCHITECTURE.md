# Architecture

This document describes the high-level architecture of Fermix. It is a code map,
not an exhaustive design spec. It should help a contributor answer two questions:
"where does this behavior live?" and "which boundary am I crossing?"

For milestone-level design history, see the files under `docs/`. Those documents
explain why individual systems were added. This file describes the current shape
of the repository.

## Bird's Eye View

Fermix is an Elixir umbrella application for a self-hosted AI assistant. External
messaging channels and the Phoenix web app run in the same BEAM VM as the agent
runtime. There are no HTTP bridges between Fermix applications.

At the highest level:

1. A channel adapter receives platform-specific input.
2. The adapter normalizes it into a `FermixChannels.Message`.
3. `FermixChannels.Gateway.ingest/2` authorizes the sender, optionally
   transcribes audio, dispatches slash commands, builds a `reply_fn`, and hands
   the turn to `Gateway.Queue`, which runs one FIFO turn per conversation
   against `FermixCore.Agents.MainAgent`.
4. `MainAgent` builds prompt context from bootstrap files, prompt memory,
   conversation history, and runtime capability sections.
5. `FermixCore.AgentLoop` calls the configured provider, executes tool calls
   through `FermixCore.Tools.Registry`, and loops until a final response or a
   bounded stop condition.
6. The original channel `reply_fn` sends the response back to the originating
   platform.
7. Conversation history, extracted memory, prompt resources, traces, and setup
   state are written through core-owned stores.

The main runtime path is intentionally process-local. Channel apps depend on
`fermix_core`; Phoenix depends on both `fermix_core` and `fermix_channels`; core
does not depend on Phoenix.

## Code Map

### Root Umbrella

The root `mix.exs` defines the umbrella, release composition, and the canonical
`mix quality` alias. Configuration lives in `config/`. Runtime configuration is
layered in this order:

1. compile-time defaults from `config/config.exs`
2. persisted setup snapshot from `FermixCore.Setup.ConfigStore`
3. environment variable overlays from `config/runtime.exs`

Architecture Invariant: persisted setup is loaded into application env before
runtime environment variables are applied. Environment variables remain the final
override layer.

### `apps/fermix_core`

This is the runtime core and the main API boundary for the rest of the umbrella.
It owns agents, provider calls, tool execution, memory, setup, readiness, prompt
composition, traces, and resource history.

`FermixCore.Application` starts the core supervision tree:

- `Task.Supervisor` for non-blocking agent and worker tasks
- `FermixCore.Trace` and telemetry handling
- optional OpenAI OAuth token management
- skill and tool registries
- SQLite-backed memory repo plus in-memory memory stores
- setup boot reporting
- dynamic skill-agent supervision
- the persistent `MainAgent`

Architecture Invariant: core code is the only place where agent runtime state,
memory state, prompt composition, tool registry state, and provider calls meet.
Controllers and channels should normalize input and delegate.

### `FermixCore.Agents.MainAgent`

`MainAgent` is the persistent top-level agent process. It owns runtime-context
cache state and checks out turn-state snapshots for `Gateway.Queue`, which owns
FIFO scheduling and one active request per conversation key.

Conversation identity is `{channel, chat_id, thread_scope}`. `thread_ts` is used
as the canonical thread identifier when present.

When a turn-state snapshot is checked out, `MainAgent`:

- loads prompt context through `FermixCore.Prompt.PromptComposer`
- reads recent conversation history from `FermixCore.Memory.ConversationStore`
- fetches tools from `FermixCore.Tools.Registry`
- calls `FermixCore.AgentLoop`
- emits telemetry

Architecture Invariant: `MainAgent` does not know how Telegram, Slack, WhatsApp,
Discord, Signal, or CLI replies are delivered. The channel `reply_fn` stays with
`Gateway.Queue` and `TurnRunner`; `MainAgent` hands out core runtime state.

### `FermixCore.AgentLoop`

`AgentLoop` is the bounded LLM/tool loop. It receives messages, provider module,
tool schemas, allowed tool names, and runtime context. It calls the provider,
detects tool calls, executes them through the tool registry, appends tool results,
and continues until the provider returns final content.

Important bounds live here:

- max iterations defaults to 25
- message compaction runs before provider calls when enabled
- repeated tool-call loop detection can warn or abort
- tool lookup honors an optional allowed-tool list

Architecture Invariant: provider responses and tool results are data flowing
through the loop; tool modules are looked up by name in `Tools.Registry`, not
hard-coded in the loop.

### `FermixCore.Providers`

`FermixCore.Providers.Provider` is the provider behavior. `FermixCore.Providers.OpenAI`
is the current implementation. It supports OpenAI API-key chat completions and an
OAuth-backed Responses path used by Codex-style auth.

Architecture Invariant: the provider boundary returns a normalized response map
with `content`, `tool_calls`, `usage`, and `model`. Agent code should not depend
directly on provider-specific response bodies.

### `FermixCore.Tools`

Tool modules implement `FermixCore.Tools.Tool`. Each tool exposes a name,
description, JSON-schema parameters, and an `execute/2` callback. The registry is
a GenServer that stores tool modules and formats their schemas for the provider.

Built-in tools currently include shell execution, file read/write, memory
store/recall, browser use, and skill invocation.

Architecture Invariant: tools receive explicit context from the agent runtime.
They should not infer conversation identity, registry state, or provider state
from globals when those values are available in the context map.

### `FermixCore.Agents` Skill Workers

`FermixCore.Agents.SkillRegistry` discovers filesystem-backed skills from
`~/.fermix/skills`, seeding bundled defaults on a fresh install. It keeps an
in-memory snapshot until explicitly reloaded.

`FermixCore.Agents.AgentSupervisor` dynamically starts `AgentServer` workers.
`AgentServer` runs one delegated task at a time with its own agent definition,
session ID, provider, registry, and parent metadata.

Architecture Invariant: skill discovery is tolerant of bad skill files. A
malformed skill is skipped and logged; it should not prevent Fermix from booting.

### `FermixCore.Memory`

Memory has two layers:

- hot-path GenServers and ETS caches for active reads/writes
- durable SQLite storage owned by `FermixCore.Memory.Repo`

`Repo` owns the Exqlite connection and schema for messages, memories, FTS search,
and versioned resources. `ConversationStore` handles conversation history.
`Store` handles scoped facts and writes through to `Repo` when durable memory is
enabled. `Extractor`, `Admission`, `Scheduler`, `PromptFiles`, `Compactor`, and
`Search` implement post-turn extraction, promotion, prompt-memory file rebuilds,
context compaction, and lexical retrieval.

Architecture Invariant: SQLite is canonical for durable memory. Prompt memory
files are derived prompt artifacts, not the source of truth.

Architecture Invariant: extraction runs after the reply path. A failed extraction
should not turn a successful user-visible reply into a failed turn.

### `FermixCore.Prompt`

Prompt composition is explicit and ordered:

1. bootstrap files from `~/.fermix/bootstrap/<agent_id>/`
2. prompt memory files from the memory subsystem
3. generated runtime sections, including available skills

`PromptComposer` produces system messages and metadata. `BootstrapLoader` reads
operator-owned bootstrap files and falls back in memory for required missing
content. `SetupSeeder` is the setup-time write path for initial prompt files.
`InjectionScan` can exclude suspicious file-backed prompt parts before export.

Architecture Invariant: setup is the write boundary for seeded prompt bootstrap
files. Loading prompt files during a request may read and capture revisions, but
it should not silently create missing files.

Architecture Invariant: recalled memory is fenced and labeled as background data,
not live user instruction.

### `FermixCore.Resource`

`FermixCore.Resource.Registry` is a module API over `Memory.Repo`, not a process.
It tracks versioned prompt and memory resources, commits revisions with hashes and
provenance, supports diffs and rollback for file-backed resources, and backs the
Mix resource history tasks.

Architecture Invariant: resource history shares the memory database. There is no
second resource-store process to coordinate.

### `FermixCore.Setup`, `Readiness`, and `Health`

`Setup.ConfigStore` owns `FERMIX_HOME`, the persisted `config.toml`, and standard
workspace paths for bootstrap files, skills, journals, traces, and logs.

`Setup.Wizard` is the shared setup engine for the CLI task and Phoenix LiveView.
`Readiness` answers whether required setup is present. `Health` turns readiness,
channel status, provider status, config paths, and memory process status into the
runtime-facing health report.

Architecture Invariant: setup logic belongs in core. Web and CLI surfaces should
render or collect answers, then call the same `Setup.Wizard` API.

### `FermixCore.Trace`

`Trace` writes structured JSONL files under `FERMIX_HOME/traces/YYYY-MM-DD/`.
`Trace.TelemetryHandler` bridges telemetry events into durable traces.

Architecture Invariant: trace writes are best-effort. Failure to write a trace is
logged and should not take down the runtime.

### `apps/fermix_channels`

This app owns messaging-platform integrations and depends on `fermix_core`.
Every adapter implements `FermixChannels.Channel`.

The shared channel boundary is:

- parse inbound platform payloads into `FermixChannels.Message`
- verify platform authenticity where applicable
- send outbound messages
- build a one-argument `reply_fn`
- optionally download attachments for shared transcription

`FermixChannels.Gateway.ingest/2` is the bridge from channels into core. It
normalizes map inputs into `Message`, authorizes the sender, runs the shared
transcription hook, dispatches slash commands, builds the reply function, and
hands the turn to `Gateway.Queue` (one FIFO turn per conversation).
`FermixChannels.Dispatcher` remains only as a thin compatibility alias for
`Gateway.ingest/2`.

Current adapters:

- `Telegram` uses long polling through `Telegram.Poller`; webhook transport is
  intentionally unsupported in the current code path.
- `WhatsApp` uses Cloud API webhook ingress and Graph API replies, with audio
  attachment download support.
- `Slack` uses signed Events API webhook ingress and Web API replies.
- `Discord` uses a supervised Gateway connection and REST replies.
- `Signal` uses a supervised `signal-cli` receive loop and subprocess sends.
- `CLI` provides a local smoke path through the same gateway and agent.

Architecture Invariant: channel adapters own platform quirks and auth checks.
After dispatch, the agent sees only normalized message fields and a `reply_fn`.

### `apps/fermix_web`

This is the Phoenix application. It owns HTTP ingress, setup UI, health endpoints,
static assets, and web presentation.

The router exposes:

- `/` for the home page
- `/setup` for the shared setup LiveView
- `/health`, `/health/live`, and `/health/ready`
- WhatsApp webhook verification and ingress
- Slack webhook ingress

Controllers should stay thin. `WebhookController` verifies the request, parses
messages with the channel adapter, and dispatches to `MainAgent`. `HealthController`
returns reports from `FermixCore.Health`. `SetupLive` drives `FermixCore.Setup.Wizard`.

Architecture Invariant: Phoenix does not contain agent business logic. It is an
HTTP and UI boundary over core APIs.

### `apps/fermix_nif`

This app is reserved for native helpers. It currently contains only the generated
placeholder module and does not participate in the main runtime path.

Architecture Invariant: native code should stay a leaf dependency for narrow
performance or platform primitives. Agent orchestration, provider calls, channel
flow, and persistence belong in Elixir.

### `docs/`

The `docs/` directory contains milestone design documents and roadmap material.
Those documents are intentionally more detailed and more historical than this
file. When a milestone is implemented, prefer updating this architecture map only
for durable boundaries and invariants, not for every implementation detail.

## Cross-Cutting Concerns

### Supervision and Concurrency

Fermix relies on OTP supervision, not service boundaries. The core supervisor uses
`:rest_for_one` because downstream runtime processes depend on earlier setup,
registry, memory, and trace processes. Channel and web apps use their own
supervision trees.

Long-running or blocking work should run under `FermixCore.TaskSupervisor` or a
dedicated supervised process. GenServer callbacks should enqueue, delegate, or
update state, not perform slow provider or network work inline.

### Configuration

Runtime configuration is stored as ordinary application env after bootstrapping.
`ConfigStore` persists setup choices, and `runtime.exs` applies environment
overrides afterward. Channel enablement affects both readiness and which
long-running channel clients are supervised.

### Error Handling

Public APIs generally return `:ok`, `{:ok, value}`, or `{:error, reason}`.
Channel controllers translate auth and validation errors into HTTP status codes.
Agent turn failures are logged, traced via telemetry, and converted into a user
visible fallback reply.

### Testing

Tests live beside each umbrella app. Core tests cover agent loops, tools, memory,
prompt composition, setup, resources, readiness, and provider normalization.
Channel tests cover parsing, auth, dispatch behavior, and platform-specific send
logic. Web tests cover controllers, LiveView/setup surfaces, and integration
paths.

Use `mix quality` from the root for the full gate. For focused work, run the
smallest relevant `mix test` target first, then broaden before merging.

### Observability

Telemetry is the common event surface for provider calls, tool execution, channel
messages, agent turns, lifecycle events, and errors. Durable traces are JSONL.
Logs go to the configured file under `FERMIX_HOME/logs`.

Architecture Invariant: observability should be added at boundaries where work
enters, leaves, blocks, or fails. Avoid scattering trace writes through pure
transformation code.
