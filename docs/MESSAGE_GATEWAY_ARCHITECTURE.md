# Message Gateway Architecture

**Status:** Shipped (stages 1–4 + post-rename collapse; stage 5 deferred).
Outbound gateway plan added 2026-05-19; first enforcement slice implemented
2026-05-19.
**Date:** 2026-05-18 (initial draft); updated 2026-05-18 after implementation +
trust vocabulary collapse; updated 2026-05-19 with outbound gateway bounds.
**Author:** Sujeeth / Aira
**Context:** Follow-up to the Telegram owner trust debugging around remote skill/MCP visibility. Implementation collapsed the original five-level trust enum into two atoms (`:operator`, `:guest`) for the single-owner usage model.
**References:** `ARCHITECTURE.md`, `docs/MILESTONE_9_1_REALTIME_VOICE.md`, `docs/MILESTONE_11_OUTBOUND_CHANNEL_MEDIA.md`, `apps/fermix_channels/lib/fermix_channels/ingress/`, `apps/fermix_channels/lib/fermix_channels/dispatcher.ex`, `apps/fermix_channels/lib/fermix_channels/commands/authorization.ex`, `apps/fermix_core/lib/fermix_core/agents/main_agent.ex`, `apps/fermix_core/lib/fermix_core/capabilities/registry.ex`

---

## 0. Implementation Snapshot And Cleanup Index

This section records repo state as of 2026-05-19 so cleanup work can be
done without rereading the whole history.

Already implemented:

- Ingress gateway modules live in `FermixChannels.Ingress.*`.
- `FermixChannels.Dispatcher` resolves authorization before transcription,
  drops unauthorized messages, writes `:source_trust` onto agent messages,
  and writes `authorization` into command context.
- `MainAgent` consumes the dispatcher-provided `:source_trust`; the old
  per-message owner lookup in `MainAgent` is gone.
- Slash-command authorization consumes `context.authorization`.
- Trust vocabulary is collapsed to `:operator`, `:guest`, and explicit
  `nil`.
- `MainAgent` already has single-flight behavior per conversation: one
  active task plus one pending replacement. Newer messages replace pending
  work and cancel active work.
- Transport runtimes already exist in `fermix_channels`:
  `Telegram.Poller`, `Discord.Gateway`, and `Signal.Listener`.
  `FermixChannels.Application` starts them only when channel config,
  readiness, and ingress authorization allow it.
- Outbound media is implemented by
  [M11](MILESTONE_11_OUTBOUND_CHANNEL_MEDIA.md): `send_attachment`,
  `send_media/3`, `build_media_reply/1`, outbound media idempotency, and
  adapter-owned media byte caps. Core does not know the cap matrix.
- Outbound adapter oversize-media errors are normalized to
  `{:byte_cap_exceeded, actual, allowed}` at the adapter boundary.
- Telegram text splitting now uses rendered Telegram-HTML visible length
  rather than raw Markdown source length and prefers nearby whitespace
  boundaries before the cap. Discord, Slack, and WhatsApp reject text that
  exceeds their platform hard bounds before making the API call.
- Outbound send paths parse platform retry hints into
  `{:rate_limited, retry_after_ms}`. A retrying reply executor is still
  pending; today's behavior surfaces the structured error.
- `AgentLoop` rejects multiple executable `:channel` category tool calls in
  one provider iteration before running any of them.
- Scheduled-job delivery already has a delivery deadline
  (`delivery_timeout_ms`, default 60 seconds).

Not implemented yet:

- A gateway-owned outbound reply router. Today the dispatcher still builds
  `reply_fn` closures that call channel adapter callbacks directly; the
  agent and `send_attachment` tool call those closures.
- Provider output caps are not wired through the provider adapters for
  channel turns (`max_output_tokens`, `max_completion_tokens`, or
  provider equivalent).
- Text splitting and length accounting are not routed through a gateway reply
  context yet. The adapter-level bounds exist, but the dispatcher still calls
  adapter-built reply closures directly.
- Gateway-owned retry sleeps are not implemented yet. Adapters parse retry
  hints, but no reply executor consumes them to sleep and retry under a
  deadline.
- Stage 5 remains deferred: adapter allow/guest checks still duplicate
  ingress lookups instead of delegating to one shared authorizer helper.
- Naming cleanup remains open if the target config vocabulary is `guests`.
  Current code and parts of this doc still use the pre-cleanup keys
  `allowed_user_ids` / `allowed_sender_ids` for remote non-owner senders.

---

## 1. Executive Summary

Fermix introduced a message gateway boundary as a small Elixir ingress
pipeline, not a separate Hermes-style runtime service. The trust enum
this gateway resolves into was originally defined by
[Milestone 4.9 (Unified Capabilities)](MILESTONE_4_9_UNIFIED_CAPABILITIES.md);
this work added the **ingress gateway** that decides which trust value
to feed into M4.9's `Registry.resolve_policy/2`, and the post-implementation
review **collapsed M4.9's five trust atoms to two** (`:operator`, `:guest`)
plus a nil sentinel for the single-owner usage model.

Before this work, the physical pieces were already in place but the decisions
were scattered:

- channel adapters normalised platform payloads into `FermixChannels.Message`
- `FermixChannels.Dispatcher` bridged channel messages into `MainAgent`
- commands had their own authorization helper
- `MainAgent` derived remote trust from channel metadata before listing
  capabilities — the bug that motivated this work

The weak point was that **authorization and trust classification were split
across adapters, commands, and `MainAgent`**. The Telegram owner fix had to
reach into `MainAgent` because the dispatcher did not hand the agent a
resolved source identity or trust decision.

The shipped architecture:

```text
transport / webhook / poller
  -> channel adapter verifies platform authenticity
  -> channel adapter normalises platform payload + early allowlist filter
  -> dispatcher's ingress gateway resolves source identity + trust
     (drops unauthorised messages before transcription)
  -> command dispatch or MainAgent receives `:source_trust` on the message
  -> CapabilityRegistry filters tools from that resolved trust
```

One place answers: "Who sent this?", "Are they allowed in?", and "What trust
level should the agent use?".

### 1.1 Single-owner trust model (post-rename)

The original draft proposed five trust atoms (`:owner_remote`, `:third_party`,
`:local`, `:core`, `nil`). Implementation review found these were
overengineered for Fermix's actual single-owner usage:

- The `:owner_remote` / `:local` split produced a confusing asymmetry where
  an owner messaging from Telegram had a wider surface than the same owner
  at the CLI.
- `:core` (internal agents) and `:owner_remote` had functionally identical
  policies.
- `:third_party` (allowed-non-owner) was dormant — no production caller
  produced it under the current single-owner setup.

The shipped vocabulary is two atoms plus a `nil` sentinel:

| Trust | Surface | Produced by |
| --- | --- | --- |
| `:operator` | Full (`:read_only`, `:read_write`, `:exec`, `:network`, `:external_api`) | Explicit `owner_user_id` senders on remote channels, local CLI/daemon paths, voice, scheduled jobs created by the operator, bundled and user-installed skills, internal sub-agents. |
| `:guest` | Read-only only (`:read_only`) | Non-owner senders in `allowed_user_ids` / `allowed_sender_ids`, plugin-loaded skills, and future group-chat callers. |
| `nil` | Treated as `:guest` when trust is *explicitly* present in opts; storage-primitive (no filter) when no trust opt is given. | The forgiving safe default for call paths that have a trust slot but didn't populate it. |

Group-chat support will extend the existing `:guest` path with reply/thread
scoping and UX controls; the trust plumbing already supports read-only human
guests.

---

## 2. Current Fermix Shape

### 2.1 Message Flow (shipped)

```text
Telegram / Slack / WhatsApp / Discord / Signal / CLI
  -> platform adapter (allowlist refusal at the earliest point)
  -> FermixChannels.Message
  -> FermixChannels.Dispatcher
      -> normalize_message/1            (canonical %Message{})
      -> FermixChannels.Ingress.Authorizer.resolve/1
         |- denied → log + return :ok (message dropped before transcription)
         |- ok    → write :source_trust onto agent_message
      -> optional transcription
      -> reply_fn / typing_fn
      -> command parsing
      -> command dispatch or MainAgent.handle_message/2
  -> FermixCore.Agents.MainAgent
      -> reads msg.source_trust (set by gateway; tests pre-set it)
      -> prompt / memory / capability listing
      -> AgentLoop
      -> provider adapter
```

### 2.2 Pre-gateway Authorization Split (historical)

For reference — this is the state the gateway refactor consolidated:

| Concern | Pre-gateway owner |
| --- | --- |
| Per-channel ingress allowlist | individual adapter `authorized_user?` / `authorized_sender?` |
| Channel startup refusal when no allowlist exists | `FermixChannels.Application` |
| Slash-command owner checks | `FermixChannels.Commands.Authorization` |
| Agent tool/skill trust | `FermixCore.Agents.MainAgent` (per-message owner lookup) |
| Capability policy application | `FermixCore.Capabilities.Registry` |

Two practical problems this caused:

1. `MainAgent` had to know about remote channel identity rules to decide
   trust level per message.
2. Command authorization and agent capability authorization could drift
   because they were resolved in different places.

Stage 3 of the migration deleted the per-message owner lookup from
`MainAgent`. Stage 5 (adapter delegation) is deferred but tracked.

### 2.3 The Runtime Bug This Started From (fixed)

Telegram parsing already included `metadata.user_id`. Ingress authorization
allowed the configured owner ID through. But the agent previously classified
all Telegram messages by channel alone, so Telegram always looked like
`:third_party`. The capability registry therefore hid skills and outbound
MCP tools because third-party trust defaulted to a restricted surface.

Fixed in two parts:

- **Immediate fix** (pre-gateway): owner-aware trust derivation inside
  `MainAgent.source_trust_for_message/1`. Shipped, then deleted in stage 3.
- **Architectural fix**: trust is now computed by the gateway before
  `MainAgent` runs. `MainAgent.source_trust_for_message/1` is gone;
  `Map.get(msg, :source_trust)` replaces it at two call sites.

After the rename collapse, the operator-on-remote-channel case and the
operator-on-CLI case both resolve to the same `:operator` trust. Skills
and MCP tools are visible from both, symmetrically.

---

## 3. What "Gateway" Means In Fermix

In Fermix, gateway means **a shared ingress decision boundary**, not:

- a separate application
- a separate BEAM node
- one GenServer that owns every message
- a Python/Hermes-style central runner
- a new network hop between channels and core

The Elixir shape is a small set of pure modules used by
`FermixChannels.Dispatcher`:

```text
FermixChannels.Dispatcher
  -> FermixChannels.Ingress.Source              (normalised identity)
  -> FermixChannels.Ingress.Authorizer          (allow/deny + trust)
  -> [optional transcription]
  -> FermixChannels.Commands
  -> FermixCore.Agents.MainAgent
```

The dispatcher stays the bridge; the trust/authorization logic is explicit
and testable.

---

## 4. Gateway Responsibilities (shipped)

| Responsibility | Owner |
| --- | --- |
| Source normalization | `Ingress.Source.from_message/1` |
| Sender authorization | `Ingress.Authorizer.resolve/1` |
| Trust classification | `Ingress.Authorizer.resolve/1` (`:operator` or `:guest`) |
| Drop unauthorised before expensive work | Dispatcher (auth → transcribe) |
| Trust handoff to agent | `:source_trust` field written onto agent message map |
| Telemetry / log of denial | Dispatcher warning when authorizer returns `{:error, …}` |

What is *not* on the gateway today:

- Conversation key derivation — still on the dispatcher (channel × chat_id ×
  thread_scope), not on the authorizer.
- Reply/typing function construction — still on the dispatcher,
  channel-specific.
- Direct `MainAgent.handle_message/2` callers must set `:source_trust`.
  The dispatcher is the production writer today; future direct callers must
  preserve that invariant or fail closed before reaching `MainAgent`.

Slash-command authorization **does** consume the gateway result as of stage
4: `Commands.Authorization.owner_only/3` reads `context.authorization.role`
rather than re-doing its own owner lookup. `:operator` passes
unconditionally; `:guest` passes only when the sender is explicitly listed
in `command_allowlist` (the per-command opt-in for trusted non-owners).

### 4.1 Why the design doc's full `Envelope` struct wasn't built

The original draft proposed a fat `Ingress.Envelope` struct combining message,
source, authorization, conversation key, reply_fn, and typing_fn. In
implementation that conflated identity with plumbing and risked god-struct
drift. Instead, the dispatcher writes only `:source_trust` onto the existing
agent message map (production callers always have a known trust value;
tests can pre-set it). The full envelope can be built when a second
consumer asks for it.

---

## 5. What Stays Out Of Gateway

| Concern | Owner | Reason |
| --- | --- | --- |
| Telegram Bot API polling | `FermixChannels.Telegram.Poller` | Transport lifecycle, not auth/trust policy. |
| Discord WebSocket gateway | `FermixChannels.Discord.Gateway` | Platform transport and reconnect handling. |
| Slack / WhatsApp webhook signature verification | channel adapters + Phoenix controller | Raw request authenticity belongs at the HTTP boundary. |
| Signal subprocess receive loop | `FermixChannels.Signal.Listener` | Platform transport. |
| Prompt composition | `FermixCore.Prompt.*` | Agent behavior, not ingress. |
| Memory extraction / compaction | `FermixCore.Memory.*` | Agent/runtime concern. |
| Capability policy definitions | `FermixCore.Capabilities.Registry` | Gateway resolves trust; registry maps trust → policy. |
| Provider calls | `FermixCore.Providers.*` | Agent loop concern. |
| Owner ID persistence / immutability | `FermixCore.Setup.*` | Configuration lifecycle, not per-message runtime. |

---

## 6. Hermes Comparison, Without Copying Hermes

Hermes has a gateway runner that centralises source identity, user
authorization, session context, slash command gating, and per-platform
toolset selection before creating/running an agent. Its key advantages:
one place to check user identity, one place to drop unauthorised messages,
one place to set session context for tools, command gating and agent
execution sharing the same source identity.

Fermix adopted the **decision centralisation** without the **runtime
shape**:

| Design point | Hermes | Fermix |
| --- | --- | --- |
| Central runner | Python `GatewayRunner` handles platforms + agent run | `FermixChannels.Dispatcher` + `Ingress.*` modules |
| Source object | `SessionSource` | `FermixChannels.Ingress.Source` |
| User auth | `_is_user_authorized(source)` | `Ingress.Authorizer.resolve(source)` |
| Slash-command gates | gateway checks command access | `Commands.dispatch/3` receives the resolved `Authorization`; owner-only handlers consume `context.authorization` |
| Tool visibility | per-platform toolsets | `Registry.list_for(trust: :operator | :guest, ...)` |
| Session context for tools | contextvars / env bridge | explicit `:source_trust` on the agent message map |
| Runtime process shape | one gateway runner | OTP supervisors per channel/transport |

Fermix keeps OTP supervision boundaries that Hermes does not have. The
gateway is a boundary in the call path, not a new monolithic process.

---

## 7. Owner Identity And Allowed Users

### 7.1 Two-tier model (today)

The configured `owner_user_id` resolves to `:operator` (full surface).
Any other sender on `allowed_user_ids` resolves to `:guest` (read-only).
Strangers are denied at the gateway.

| Config | Meaning | Trust |
| --- | --- | --- |
| `owner_user_id` | The single human operator on this channel. | `:operator` |
| `allowed_user_ids` / `allowed_sender_ids` (entries that are *not* the owner) | Users allowed to chat with the bot. | `:guest` (read-only). Adding someone to this list lets them talk to the bot but does **not** silently grant them skills, MCP tools, exec, network, or external API capabilities. |
| `command_allowlist` | Non-owner users allowed to run owner-only channel slash commands. | Consulted only when the gateway resolved the sender as `:guest`; it does not grant operator tool trust. |

Owner detection uses `Config.channel_explicit_owner_user_id/1` — strict,
no single-allow-list promotion. Adding a sole user to
`allowed_user_ids` without setting `owner_user_id` does **not** make
them the owner; they get `:guest` trust. This is the P1 finding's fix:
explicit owner configuration is required to grant the operator surface.

### 7.2 Why `:guest` exists today

The earlier collapse pass merged the trust enum's five atoms to two —
but it briefly over-collapsed by giving every authorized sender
`:operator`. Review caught this: a friend you add to your Telegram
allow-list "just to chat" should not silently get your full tool
surface. The two-tier model restores the safe boundary:

- Sole human owner today → `:operator`.
- Anyone else you authorise → `:guest` (read-only).
- Future multi-user/group-chat support reuses `:guest` directly — no
  re-plumbing needed.

Group-chat UX (only respond when @-mentioned / in a reply-thread) is a
separate feature, not part of the trust model.

### 7.3 Owner ID immutability

Owner ID immutability belongs in setup/config persistence, not the
gateway:

- First setup writes `owner_user_id`.
- Reconfigure should not display owner prompts once persisted.
- Attempted owner replacement must fail loudly or require an explicit
  channel reset/recreate operation.

The gateway consumes the immutable owner ID via
`Config.channel_ingress_user_ids/1`. It does not decide whether the
owner ID may be changed.

---

## 8. Voice / Realtime

Realtime voice is **not** routed through the message gateway. The voice
design already states why:

- `FermixChannels.Dispatcher` is for discrete messages.
- Realtime voice is a local continuous audio session.
- OpenAI Realtime is session/event-based, not a bounded text/tool turn.

Voice shape (unchanged):

```text
FermixPet.app
  -> local Unix socket
  -> FermixCore.Realtime.LocalVoiceSocket
  -> FermixCore.Realtime.SessionServer
  -> FermixCore.Realtime.OpenAIClient
  -> OpenAI Realtime WebSocket
```

### 8.1 Voice trust (post-rename)

Voice is the operator at the keyboard — same trust level as the human
owner messaging from CLI or a remote channel. `SessionServer` passes
`trust: :operator` explicitly to `Registry.list_for/2`:

```elixir
CapabilityRegistry.list_for(CapabilityRegistry,
  trust: :operator,
  excluded_categories: [:channel]
)
```

The earlier draft proposed a shared `Capabilities.SourcePolicy` helper to
map source/trust to policy for both gateway and voice. After review that
was **dropped** — `Registry.resolve_policy/2` already is that helper.
Voice never imports `FermixChannels`; it uses the same registry as the
gateway, with explicit `:operator` trust.

---

## 9. Module Shape (shipped)

### 9.1 `FermixChannels.Ingress.Source`

Pure struct for normalised source identity. Fields:

- `channel` (string)
- `channel_key` (atom or nil — atom for remote channels Fermix knows about)
- `chat_id`
- `thread_id`
- `sender_id`
- `sender_name`

`from_message/1` extracts `sender_id` from `metadata.user_id`
(falling back to `metadata.sender_id`), trims whitespace, collapses
empty strings to nil, and coerces non-binary values to strings.

### 9.2 `FermixChannels.Ingress.Authorizer`

Pure module. API:

```elixir
@spec resolve(Source.t()) ::
        {:ok, Authorization.t()} | {:error, :unauthorized | :unknown_channel}
```

Behaviour:

| Input | Output |
| --- | --- |
| Local channel (`cli`, `daemon`) | `{:ok, %Authorization{role: :operator, trust: :operator}}` |
| Sender matches explicit `owner_user_id` on a remote channel | `{:ok, %Authorization{role: :operator, trust: :operator}}` |
| Sender is in `allowed_user_ids` but **not** the owner | `{:ok, %Authorization{role: :guest, trust: :guest}}` |
| Missing `sender_id` on a remote channel | `{:error, :unauthorized}` |
| Unknown sender on a remote channel | `{:error, :unauthorized}` |
| Unknown channel string | `{:error, :unknown_channel}` |

Owner detection uses `Config.channel_explicit_owner_user_id/1` (strict —
does not promote a sole allow-list entry to owner).

### 9.3 `FermixChannels.Ingress.Authorization`

```elixir
@enforce_keys [:role, :trust]
defstruct [:role, :trust]

@type role :: :operator | :guest
@type trust :: nil | :operator | :guest
```

The full envelope struct in the original draft (combining message,
source, authorization, conversation key, reply_fn, typing_fn) was **not
built** — see §4.1.

### 9.4 ~~`FermixCore.Capabilities.SourcePolicy`~~ — **DROPPED**

`Registry.resolve_policy/2` already maps trust → policy. The proposed
`SourcePolicy` would have duplicated that function. Both the gateway
and voice call `Registry.list_for(trust: ...)` directly.

---

## 10. Migration Plan (status)

| Stage | Description | Status |
| --- | --- | --- |
| 1 | `Ingress.Source` + `Ingress.Authorization` structs + `Ingress.Authorizer`; move owner lookup + sender id extraction out of `MainAgent`. | **Shipped.** |
| 2 | `Dispatcher.dispatch_message/8` calls `Authorizer.resolve/1`, drops unauthorised messages **before** transcription, writes `:source_trust` onto agent message. | **Shipped.** |
| 3 | `MainAgent.source_trust_for_message/1` → `Map.get(msg, :source_trust)`; delete owner-lookup helpers from `MainAgent`. | **Shipped.** |
| 4 | Route slash-command authorization through the resolved `Authorization`. | **Shipped.** Dispatcher writes `authorization` into the command context; `Commands.Authorization.owner_only/3` consumes `context.authorization` — `:operator` passes unconditionally, `:guest` passes only if the sender is in `command_allowlist`, missing authorization fails closed. The pre-Stage-4 single-allowlist-promotion fallback is gone. |
| 5 | Collapse adapter allowlist duplication: each adapter's `authorized_user?` delegates to a shared `Ingress.Authorizer.allowed?/2`. | **Deferred.** Adapters still hold their own per-channel `authorized_user?`/`authorized_sender?` functions, so hot remote channels can read ingress config once in the adapter and once again in the dispatcher authorizer. |
| 6 | Shared `Capabilities.SourcePolicy` helper. | **Dropped** — see §9.4. |

### 10.1 Post-implementation cleanups

Findings from review passes after stages 1–3 landed:

- **P1 — single-allowlist promotion bug.** `Config.channel_command_owner_user_id/1`'s
  fallback treated `allowed_user_ids: ["alice"]` (no explicit `owner_user_id`) as
  owner. The original fix added a strict `channel_explicit_owner_user_id/1`
  accessor and pointed the Authorizer at it. The accessor remains the gateway's
  owner-trust source: explicit owners resolve to `:operator`; non-owner
  allow-list entries resolve to `:guest`.
- **P2 — `:owner_remote` (now `:operator`) scheduled jobs were silently
  re-narrowed.** Two bugs: (a) `effective_trust` had no clause for the
  string `"owner_remote"`, (b) the runner always passed a static
  `policy: [:read_only, :network]` which overrode trust via
  `Registry.resolve_policy/2`'s "explicit policy wins" rule. Fixed by adding
  the missing clause and a `scheduled_policy(_explicit, :operator) → nil`
  helper that lets trust drive policy for operator-created jobs.
- **P3 — auth-after-transcribe.** Initial implementation ran transcription
  before authorization. Reordered to `normalize → authorize → transcribe`
  so denied messages don't burn LLM/STT tokens. A regression test
  (`"transcription is skipped when the sender is denied"`) locks the order.
- **R1 — MainAgent-restart silent drop.** `MainAgent.handle_message/2` is
  `GenServer.cast`, which the BEAM silently no-ops if the registered name
  is unbound (e.g., during a supervisor restart). The dispatcher now
  pre-checks `GenServer.whereis/1` + `Process.alive?/1`; on a dead or
  unregistered server it logs, emits a `[:fermix, :dispatcher, :agent_unavailable]`
  telemetry event, and surfaces a user-facing reply ("I'm restarting —
  please send your message again in a moment.") via the same `reply_fn`
  the agent would have used. Two regression tests in
  `dispatcher_test.exs` cover the unregistered-name and dead-pid paths.
- **R2 — auth-specific error reply.** `Agent loop failed` previously
  emitted a single generic line regardless of the failure. The
  `agent_loop_error_message/1` helper in `MainAgent` now branches on
  `auth_error?/1` — known auth signals (`:no_auth_file`,
  `:auth_invalidated`, `:refresh_failed`, HTTP 401/403 in any of the
  observed shapes, or a free-form string matching `401`/`Unauthorized`/
  `refresh_token_reused`/`invalid_grant`) produce the actionable
  "Authentication failed — run `fermix auth login`" reply. Everything
  else keeps the generic "encountered an error" line.

### 10.2 Trust vocabulary collapse

Originally implemented with five trust atoms matching the registry's
existing enum (`:owner_remote`, `:third_party`, `:local`, `:core`, nil).
Review concluded this was overengineered for the single-owner usage model
and produced confusing asymmetries (CLI ops < Telegram-owner ops). The
collapse:

- `:owner_remote` + `:local` + `:core` → `:operator`
- `:third_party` → `:guest`
- `nil` → forgiving safe default (`:guest`-equivalent when explicit;
  storage-primitive when no trust opt at all)

A migration (v7 in `FermixCore.Memory.Repo`) rewrites the
`scheduled_jobs.created_by_trust` column from the old vocabulary to the
new on first boot after upgrade.

`AgentDefinition.source` and `SkillRegistry` were collapsed the same way
to keep one trust type across the codebase:

- Bundled (`core_dir`) and user-installed (`local_dir`) skills →
  `:operator`.
- Plugin-loaded (`plugin_dir`) and unknown-path skills → `:guest`.

`Memory.Admission` (F-09 gate) still drops `instruction`/`correction`
candidates from explicit `:guest` source trust; nil-source paths
(internal extractor runs) remain permissive — Admission's job is to
restrict an explicit low-trust source, not to second-guess internal
callers that never produced one.

---

## 11. Testing

### 11.1 Authorizer matrix

| Channel | Sender | Expected |
| --- | --- | --- |
| Telegram | owner | `{:ok, :operator}` |
| Telegram | allowed non-owner | `{:ok, :guest}` |
| Telegram | unknown | `{:error, :unauthorized}` |
| Telegram | missing `user_id` | `{:error, :unauthorized}` |
| Slack | sole `allowed_user_ids` entry without explicit `owner_user_id` | `{:ok, :guest}` |
| CLI | local | `{:ok, :operator}` |
| Daemon | local | `{:ok, :operator}` |
| Unknown remote channel (e.g. `matrix`) | any | `{:error, :unknown_channel}` |

### 11.2 Dispatcher integration

- Owner remote message → agent message has `:source_trust = :operator`.
- Allowed non-owner remote message → agent message has `:source_trust = :guest`.
- Unauthorised sender → message dropped, agent not invoked, warning logged.
- CLI channel → `:operator`.
- **Transcription is skipped when the sender is denied** (locks the
  auth-before-transcribe order).

### 11.3 Registry trust → policy

- `list(reg, trust: :operator)` returns the full surface
  (`[:read_only, :read_write, :exec, :network, :external_api]`).
- `list(reg, trust: :guest)` returns read-only only.
- `list(reg, trust: nil)` (explicit) returns read-only (safe default).
- `list(reg)` (no trust opt at all) returns everything registered
  (storage primitive).
- `list(reg, trust: :guest, policy: [:read_only, :exec])` — explicit
  policy overrides trust default.

### 11.4 Scheduled jobs

- Operator-created scheduled run preserves the full capability surface
  (`stage3_read` + `stage3_external` both visible).
- Guest-trust scheduled run is narrowed to read-only capabilities.

### 11.5 Voice

- `SessionServer` calls `Registry.list_for/2` with `trust: :operator`;
  full surface visible minus `:channel`-categorised tools.
- Voice does not import `FermixChannels`.

---

## 12. Risks And Trade-offs

### 12.1 Gateway becoming too broad

Mitigation: §4 and §5 lock its scope to source / auth / trust / drop-on-
denial. Conversation key, reply_fn, and typing_fn stay on the dispatcher.
Command authorization consumes the gateway's resolved `Authorization` but
stays implemented in command handlers.

### 12.2 Single-owner collapse hides multi-user complexity

Mitigation: `:guest` is in the type system. The registry's `:guest`
policy is defined and tested. Adding back the second human-trust tier
requires:

- A `Authorizer.resolve/1` branch that emits `:guest`.
- A config knob distinguishing operator-equivalent users from guests.

Both are ~10 lines, not a re-plumbing.

### 12.3 `nil = least privilege` may surprise

`Registry.list/2` calls with **no** trust/policy/policy_classes opt
preserve the old "show me everything" behaviour (storage primitive).
Only calls that explicitly pass `trust: nil` get the read-only safe
default. This compromise keeps test ergonomics while preserving the
safety guarantee for production paths that have a trust slot.

### 12.4 Voice / scheduled-jobs policy drift

Mitigation: both call `Registry.list_for/2` directly, with explicit
trust. No second policy-mapping module to drift against.

---

## 13. Outcome

The gateway lives at `FermixChannels.Ingress.*`. The dispatcher writes
`:source_trust` onto the agent message map and `authorization` into the
command context. `MainAgent` reads the trust; owner-only commands read
the authorization; the registry maps trust to a policy. Two human trust
levels (`:operator`, `:guest`) plus `nil` as the safe default. Five atoms
collapsed to two plus a sentinel. Stages 1–4 shipped, stage 6 dropped,
and stage 5 remains deferred until it earns its keep.

Remaining work, tracked:

- **Stage 5** — adapters delegate `authorized_user?` to a shared
  `Ingress.Authorizer.allowed?/2` to remove the five copies of the same
  4-line allowlist check.

---

## 14. Next Plan: Transport And Outbound Gateway

The next gateway step is not another trust refactor. The missing boundary is
reply delivery: inbound trust is centralized, but outbound replies still leave
core through direct `reply_fn` closures built by the dispatcher. That works,
but it means serialization, rate-limit handling, stale-turn rejection, and
reply telemetry are not owned by one runtime boundary.

### 14.1 Boundary

Keep the gateway inside `fermix_channels`.

```text
enabled transport
  -> channel adapter
  -> Dispatcher + Ingress.Authorizer
  -> MainAgent
  -> gateway ReplyContext
  -> channel adapter send_message/send_media
```

Core still must not import `FermixChannels`. `MainAgent` receives a
`reply_fn`, but that function should call a `fermix_channels` reply context
instead of directly calling Telegram/Slack/Discord/WhatsApp/Signal adapter
functions.

Voice stays out of this gateway. Realtime voice has its own local socket and
OpenAI Realtime session lifecycle; it shares the capability registry trust
model, not message transport.

### 14.2 No Generic Queue Size

Do not add a generic `max_queue_length`, `max_parts`, or "100 messages"
setting. Those values are not platform standards and would be made up.

The outbound gateway should instead use these existing or protocol-owned
bounds:

| Bound | Source |
| --- | --- |
| Conversation concurrency | Existing `MainAgent` single-flight: one active task plus one pending replacement per conversation. |
| Turn execution | Existing `AgentLoop` iteration cap, default 25. |
| Live agent deadline | Existing `AgentDefinition.timeout_seconds`, default 300 seconds. |
| Scheduled delivery deadline | Existing jobs `delivery_timeout_ms`, default 60 seconds. |
| Text part size | Adapter-declared platform text limit (§14.3). |
| Media byte size | Adapter-owned M11 media caps (§14.4). |
| Retry delay | Platform/API retry hint (`retry_after`, `Retry-After`, or equivalent), not guessed sleeps. |

The reply executor should be FIFO for a single accepted reply batch. Stale
turn checks happen before accepting a batch; once a text batch starts, it
drains all chunks under the delivery deadline so Telegram/Discord users do
not receive half a sentence. New reply batches from canceled/replaced turns
are rejected before delivery. Channel tool side effects such as media sends
are not rollbackable once accepted.

Dispatcher/system replies that are intentionally outside an agent turn
must have an explicit system-delivery path. The existing restart message
(`"I'm restarting — please send your message again in a moment."`) is one
such path: it has no agent turn id and must still deliver.

### 14.3 Text Bounds

Each adapter declares its text limit and length-accounting function. The
gateway can ask the adapter to split text; it should not embed platform
rules in core.

| Channel | Text bound |
| --- | --- |
| Telegram | 4096 characters after entity parsing for `sendMessage`. Current adapter splitting counts Fermix-rendered Telegram HTML visible length, not raw Markdown source length, and prefers nearby whitespace split points before the visible cap. |
| Discord | 2000 characters in message `content`; current adapter rejects larger text before API send. |
| Slack | Hard truncation begins above 40000 characters; current adapter rejects larger text before API send. If Fermix later chooses a 4000-character UX chunk, name it as a Fermix UX policy, not a platform hard cap. |
| WhatsApp | 4096 characters in `messages.text.body`; current adapter rejects larger text before API send. |
| Signal | Use the adapter/client-supported text behavior; no gateway-owned generic value. |
| CLI | No split required for transport correctness. |

Provider output should also be bounded before delivery:

- OpenAI Responses: wire `max_output_tokens`.
- OpenAI Chat Completions: wire `max_completion_tokens`.
- Anthropic Messages, when enabled: wire required `max_tokens`.
- OpenAI Codex/private Responses route: wire the equivalent field only if the
  route supports it; otherwise document that the route relies on post-response
  channel truncation.

### 14.4 Media Bounds

Media size is already solved by
[M11](MILESTONE_11_OUTBOUND_CHANNEL_MEDIA.md). The gateway must not copy
this matrix into core and must not add a second central cap registry.

| Channel | Kind | Cap |
| --- | --- | --- |
| Telegram | `:image` | 10 MB |
| Telegram | `:voice` | 1 MB |
| Telegram | `:audio`, `:video`, `:document` | 50 MB |
| Discord | any | 10 MiB default; configurable to 50 or 100 MiB for boosted guilds. |
| Slack | any | 100 MiB v1 cap. |
| WhatsApp | `:image` | 5 MB |
| WhatsApp | `:voice`, `:audio`, `:video` | 16 MB. `:voice` maps to WhatsApp `audio` and requires `audio/ogg; codecs=opus`. |
| WhatsApp | `:document` | 100 MB |
| Signal | any | 100 MB |
| CLI | any | unsupported |

The gateway receives success or adapter errors. For oversize media, adapters
return `{:error, {:byte_cap_exceeded, actual, allowed}}`. The gateway logs and
surfaces the normalized failure. Core sees only the tool result.

WhatsApp has a separate inbound download cap from audit F-06:
`@max_media_bytes` is 25 MiB for inbound media downloads. That is not an
outbound send cap and should remain documented separately from this outbound
matrix.

### 14.5 Media Count Bound

Do not bound media count with a queue depth. Bound it from the turn runtime:

- For channel-bound agent turns, disable provider parallel tool calls where
  the provider supports that setting.
- The enforcement point is `AgentLoop`: if a provider still returns
  multiple channel-side-effect tool calls (`send_attachment` or future
  channel category tools) in one iteration, reject that iteration before
  executing any of them and return a tool/loop error.
- With one channel side-effect per iteration, the maximum number of
  `send_attachment` deliveries in one turn is the agent loop's
  `max_iterations`.

This keeps the media count bound tied to an existing Fermix runtime contract
instead of a new queue knob.

### 14.6 Rate Limits And Retries

Retry only when the platform tells us when to retry:

- Telegram: use Bot API `parameters.retry_after` on flood/rate errors.
- Discord: use `Retry-After` / `retry_after` and documented rate-limit
  headers.
- Slack: use `Retry-After` on HTTP 429.
- WhatsApp/Meta: use a documented retry hint only if present. Without one,
  fail visibly and let the operator retry.

If the retry delay exceeds the remaining live-turn or scheduled-delivery
deadline, fail instead of sleeping past the caller's deadline.

Adapters now parse `parameters.retry_after`, `Retry-After`, and body-level
`retry_after` hints into `{:error, {:rate_limited, retry_after_ms}}` on
outbound send failures. The remaining work is executor behavior: consume that
hint, sleep only if it fits the live-turn or scheduled-delivery deadline, and
retry once through the same adapter send function.

### 14.7 Implementation Steps

1. Add a `FermixChannels.Replies.Context` value owned by the dispatcher:
   channel module, reply target, platform thread option, conversation key,
   optional turn id, source, authorization, and delivery deadline.
2. Change dispatcher-built `reply_fn` to call the reply context, not direct
   adapter closures.
3. Add a per-conversation reply executor keyed by the dispatcher's existing
   `conversation_key` (`{channel, chat_id, thread_ts || thread_scope}`). Do
   not introduce a second outbound thread vocabulary.
4. **Done for the current adapters:** Move text chunking behind adapter-owned
   functions so platform limits stay
   near `send_message/3`. Telegram splitting must count the post-render text
   that Telegram validates after Fermix's Markdown-to-HTML preparation, not
   only the raw source string.
5. **Done:** Keep media byte checks inside adapters exactly as M11 designed,
   then normalize oversize media errors to
   `{:byte_cap_exceeded, actual, allowed}` at the adapter boundary.
6. **Adapter parsing done; executor retry pending:** Add retry-hint parsing in
   adapters before routing delivery through the executor.
7. Wire provider output caps into adapter options for channel turns.
8. **Done:** Add `AgentLoop` protection against multiple channel side-effect
   tool calls in one iteration.
9. Add an explicit system-delivery path for dispatcher replies that have no
   agent turn id.
10. Add tests before behavior changes:
   - stale turn reply is rejected;
   - two reply parts from one active turn are delivered FIFO;
   - accepted multi-chunk text batch drains to completion under deadline;
   - dispatcher restart reply delivers without a turn id;
   - **done:** Telegram text splits at the adapter limit;
   - **done:** Telegram split counting uses post-render outbound text length;
   - **done:** Discord text fails before API call at 2000 characters;
   - **done:** Slack and WhatsApp text fail before API call at their hard
     bounds;
   - **done:** adapter oversize media errors are normalized;
   - **done for parsing:** retry hints are surfaced from adapters;
   - retry waits use platform retry hints and respect delivery deadlines.
