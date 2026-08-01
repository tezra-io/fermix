# Milestone 29 — ACP Agent Surface: Fermix under any ACP client (Buzz custom harness first)

**Status:** rev 2 — **implemented 2026-08-01, Stages 0–5 (Stage 6 live acceptance outstanding); see §16 for the implementation log and deviations.** Rev-2 history (2026-07-31: external review adjudicated against both codebases; authorization mechanics corrected — registry `trust` field replaces the broken `remote?: false` assumption; slash-command pipeline disabled on this surface; credential story rebuilt on Buzz peer-parity + telemetry-export scrubbing; turn-result seam added; `:raw` stream tier replaces the quartet; `request_cwd` reuse replaces the invented workspace override; bridge hello gains an ack; conformance scope narrowed to a Buzz-first profile)
**Research basis:** `block/buzz` @ **v0.5.2** (tag, HEAD 3e48f1b23 — Buzz paths pinned to that tag; re-verify on upstream bumps), ACP spec **wire version 1 / `schema-v1.20.0`** (schema release 2026-07-21; the v2 draft of 2026-07-20 is explicitly *not* the target), Fermix @ `release/0.7.0`.
**Related docs:** `docs/design/MILESTONE_23_BUZZ_CHIEF_OF_STAFF.md` (the network-peer rail this complements; §3 adjudicates its §13 ACP rejection), `docs/design/MILESTONE_9_1_REALTIME_VOICE.md` (daemon-owned local-socket precedent), `docs/design/CHANNEL_STREAMING.md` (stream tiers — implemented; its "draft" status line is stale), `docs/design/SANDBOX_ACCESS_APPROVAL_FLOW.md` (why approvals never cross this wire, §11), `docs/TELEMETRY_CONTRACT.md`.

**Design principle for this milestone: simplest correct integration.** Every problem the rev-1 review confirmed is fixed here by *removing* surface or *reusing* an existing seam, not by adding machinery. Three deliberate simplifications carry most of the weight: no slash commands on this surface (closes the daemon-admin hole without a third trust tier), model-owned reply posting at exact parity with every other Buzz agent (no Fermix-side Nostr/delivery machinery), and `request_cwd` reuse (no new workspace concept).

---

## 1. Summary

ACP (Agent Client Protocol, agentclientprotocol.com — JSON-RPC 2.0 over stdio between a host "client" and a spawned "agent" subprocess) is the lingua franca for embedding coding agents: Zed and JetBrains natively, a 38-agent registry, and — the trigger here — **Buzz v0.5.x "bring your own harness" (BYOH)**: any ACP-speaking binary can be added as a first-class Buzz agent from the settings UI. No upstream patch, no catalog entry.

This milestone makes Fermix a native ACP **agent**:

1. **A `fermix acp` CLI verb** — a stdio⇄UDS pipe into the running daemon: one hello line, one ack line, then raw bytes. All protocol logic lives daemon-side.
2. **An `acp` channel** in `fermix_channels` — its transport child is a UDS listener at `<FERMIX_HOME>/acp.sock` (the `realtime.sock` pattern). Each ACP session becomes an ordinary gateway conversation: Fermix's system prompt, tools, sandbox, durable memory, compaction, telemetry.

The pitch: under Buzz, claude/codex are amnesiac subprocesses; Fermix-over-ACP is a window onto a persistent daemon. The harness owns identity, queueing, and replies (accepted for this role, §3); Fermix keeps memory, tool policy, sandbox, and observability.

Two research facts dominate the design (§2.4): Buzz never posts the agent's ACP output to the channel — agents post their own replies via the `buzz` CLI using spawn-env credentials — and Buzz cancels + re-prompts mid-turn agents by default with a 5-second drain. Hence the small set of core seams this milestone adds (§6.3): a registry `trust` field, a per-conversation queue stop, an optional turn-result callback, a `:raw` stream tier, and a session env overlay consumed at one point.

## 2. Research

### 2.1 Buzz v0.5.2 BYOH mechanics

- A custom harness is a JSON file `<app-data>/custom_harnesses/<id>.json` — `{id, label, command, args, env, installInstructionsUrl?, installHint?}` (`desktop/src-tauri/src/managed_agents/custom_harnesses.rs:47-70`), created from the Settings Harnesses panel or inline from the agent dialogs. Constraints: `args` may not contain literal commas (they travel comma-delimited in `BUZZ_ACP_AGENT_ARGS`); `env` may not set keys on the finite, case-insensitive reserved list (`env_vars.rs:58-90` — the `BUZZ_*` wiring keys plus `NOSTR_PRIVATE_KEY`); ids collide-checked against builtins/presets.
- The desktop never speaks ACP itself. It spawns one `buzz-acp` harness per (agent, relay) pair, env-configured; `buzz-acp` spawns a pool of `parallelism` (default 10, max 32) copies of the custom binary — NDJSON JSON-RPC over stdio, 10 MiB line cap (`crates/buzz-acp/src/acp.rs:21`).
- Custom binaries are PATH-resolved with generous fallbacks (literal absolute path; `/opt/homebrew/bin`; `~/.local/bin`; login-shell `command -v`; `~/.bun/bin`; …) — a Homebrew `fermix` resolves from a GUI launch. **No probing**: no `--version`, no handshake test (version gating is codex-only).
- Spawn context: cwd `~/.buzz` (the shared "nest"; `$HOME` fallback; no per-agent workspace), env inherited from the harness including **`BUZZ_PRIVATE_KEY` (the agent's Nostr nsec), `BUZZ_RELAY_URL`, `BUZZ_AUTH_TAG` (when set), `NOSTR_PRIVATE_KEY` + `GIT_CONFIG_*` (git-over-relay credentials), and the harness's augmented PATH** (`runtime.rs:552-578,828-850`; `acp.rs:493-511`). **Every Buzz agent's own shell children see these too** — claude/codex under Buzz run arbitrary shell with these variables present. Custom harnesses get no MCP sidecar (`mcpServers` always `[]`), no model/provider env wiring, no auth probes.
- Lifecycle: subprocess crash → respawn with backoff + a 3-in-60 s circuit breaker; **if every initial slot fails (daemon down at first spawn), the harness exits — the stderr message lands in the per-agent log but is not guaranteed to surface as the displayed status summary**. Idle turn timeout default 900 s (reset by any valid frame from the agent, and explicitly by `tool_call`), hard cap 7200 s. **v0.5.2 exposes no UI field for the idle timeout** — the agent record's `idle_timeout_seconds` exists (`runtime.rs:716-724`) but no dialog sets it; the harness default governs in practice. A successful cancel drain keeps the subprocess; only drain expiry (5 s for control-signal cancels) triggers kill + respawn.

### 2.2 The wire contract buzz-acp exercises (v0.5.2)

| Wire item | Buzz behavior (cited to `crates/buzz-acp/src/`) |
|---|---|
| framing | NDJSON JSON-RPC 2.0, numeric client ids; unknown agent→client *requests* answered `-32601`, unknown notifications dropped (`acp.rs:1670-1685`) |
| `initialize` | sends `protocolVersion: 2` (deliberate squat ahead of upstream, `acp.rs:599-601`); `clientCapabilities` carry **no spec `fs` and no spec `terminal`** (only a nonstandard `auth: {terminal: true}` / `_meta["terminal-auth"]` flag for its out-of-band auth flows); reads back `protocolVersion` (≥2 ⇒ system prompt via `session/new.systemPrompt`, else legacy in-message `[Base]`/`[System]` sections), `agentInfo.name`, `_meta.steering.supported`; **ignores `agentCapabilities`**; 60 s timeout |
| `authenticate` | never called at runtime (only by `buzz-acp auth-methods/authenticate` CLI flows) |
| `session/new` | one session per Buzz channel (DMs included), lazily on first prompt, reused until rotation; params `cwd` (= harness cwd, `~/.buzz`), `mcpServers` (`[]` for custom), `_meta.sessionTitle` ("Agent · #channel"; bare agent name for DMs); mines `modes`/`configOptions`/`models` from the response for optional mode/model switching (skipped when absent) |
| `session/load` | never called; agent restart ⇒ fresh `session/new` |
| `session/prompt` | **text ContentBlocks only**; `[Context]` (scope, channel, thread ids, `buzz` CLI hints, reply-anchor instruction) → optional `[Thread/Conversation Context]` → one or more `[Buzz event]` blocks (sender label + npub + hex, raw content, tag JSON); multiple pending mentions batch into ONE turn; a triggering message that is a **single-event batch** whose content (after leading mentions) starts `/alnum…` is passed through as a separate first text block (`acp.rs:741-753`) |
| `session/update` | mirrored to the desktop session viewer (owner-encrypted kind-24200 observer frames) and consumed for harness state: `tool_call` resets the idle clock, `session_info_update._meta.goose.activeRunId` feeds steering, goose-style usage notifications feed kind-44200 metrics. **Nothing the agent streams is posted to the channel** |
| replies | the agent posts its own messages via the `buzz` CLI (`buzz messages send --reply-to <anchor>`), authenticated by the spawn env; the injected base prompt mandates this (`base_prompt.md`) |
| `session/request_permission` | auto-answered, no UI: `allow_once` option, else `reject_once`, else protocol error (`acp.rs:1856-1940`) |
| `session/cancel` | notification; sent on idle timeout, steer fallback, interrupt, owner `!cancel`/`!rotate`, model switch, desktop stop; **5 s drain** for control-signal cancels, then subprocess kill+respawn; the agent must answer the in-flight prompt with `stopReason:"cancelled"` |
| `_session/steering` | mid-turn injection; gated solely on `_meta.steering.supported: true` in the initialize response (BYOH may opt in); non-steering agents get cancel + merged re-prompt (desktop pins steer mode) |
| errors | turn errors whose message contains `"Re-authenticate"` or `"API Error: 401"` dead-letter immediately with a visible in-channel notice; anything else requeues with backoff up to 10 times, then dead-letters with a visible notice (`lib.rs:3002-3179`) |
| stopReason | case-insensitive; exactly `end_turn`, `cancelled`, `max_tokens`, `max_turn_requests`, `refusal`; missing/unknown = protocol error |

### 2.3 ACP spec state (verified live 2026-07-30)

Wire `protocolVersion` = integer **1**; artifact `schema-v1.20.0`. Framing: newline-delimited JSON-RPC 2.0 over stdio, UTF-8; **agents MUST NOT write non-ACP bytes to stdout** (stderr free for logs). Negotiation: the client sends the latest version it supports; an agent that doesn't support it **replies with the latest it does** — the client then decides whether to disconnect (so version `0` gets `1` back, not an error). All paths absolute, `session/new.cwd` included. Minimum conforming agent: `initialize`, `session/new` (accept `cwd` + `mcpServers` — **stdio MCP is an ungated MUST**), `session/prompt` (accept `text` + `resource_link`), handle `session/cancel` (→ `stopReason:"cancelled"`), stream `agent_message_chunk`, one `stopReason` per turn; `authMethods: []` when auth is not needed; `-32000` auth required; `$/cancel_request` → complete the referenced request with `-32800`. Everything else is capability-gated, omitted-means-unsupported. **ACP v2 draft** (2026-07-20) restructures prompt turns and removes fs/terminal/`session/load` — a reason to keep the wire codec and the session layer separate, and not to chase Buzz's `protocolVersion: 2` squat.

Elixir ecosystem: no maintained current-spec library (hex `acpex` 0.1.1, `agent_client_protocol` 0.1.0 pre-date the 2026 stabilizations). Hand-roll the small codec; vendor the schema; contract-test against it (the `priv/realtime` pattern).

### 2.4 Verdict: can Fermix be added to Buzz out of the box?

**Yes — via BYOH — provided Fermix speaks ACP v1 over stdio and solves two problems the protocol does not state:**

1. **Reply publication.** Buzz posts nothing on the agent's behalf. Replies happen because the injected base prompt instructs the model to run `buzz messages send` and the spawn env carries relay credentials. A daemon-bridged agent must make that env reachable from the session's shell tool (§8.3) or it can never answer in-channel. Corollary: anything Fermix "replies" outside the model's own posting — command output, system texts — would be invisible in the channel; rev 2 removes those reply classes from this surface instead of building a delivery path for them (§4).
2. **Cancel latency.** Steer-mode is pinned: every mid-turn mention triggers `session/cancel` + merged re-prompt with a 5 s drain before kill-and-respawn. Turn abort must complete in well under a second (§8.5).

Everything else fits: no spec fs/terminal advertised (Fermix has its own tools), no MCP servers passed to custom harnesses, permissions auto-handled, capabilities Fermix won't advertise are ignored, no version/vendor probe on custom binaries.

## 3. Relationship to M23 (and its §13 ACP rejection)

M23's verdict stands: **the chief-of-staff rail remains native relay membership.** M23 rejected ACP *for the CoS role*; this milestone ships ACP for a different role — a worker/dev agent an org member adds from the Buzz UI — and for the ACP client ecosystem beyond Buzz. They compose: a CoS Fermix (M23, Fermix-owned keypair) can delegate to a Buzz-managed Fermix-over-ACP agent (Buzz-owned keypair) like any org agent. Against M23 §13, objection by objection:

| M23 §13 objection | M29 disposition |
|---|---|
| harness owns identity, sessions, queueing, batching, replies | Accepted for this role — it is what "being a Buzz-managed agent" means; claude/codex accept the same terms |
| "Fermix demoted to a prompt-responder inside someone else's loop" | Half-dissolved: the loop is harness-owned, but memory, skills, sandbox policy, compaction, and telemetry stay daemon-owned — the half that made "prompt-responder" an insult |
| kills slash commands | **Conceded, and made deliberate**: rev 2 disables the command pipeline on this surface entirely (§4) — the alternative was exposing daemon-admin commands to anyone who can @mention the agent. `/compact` is redundant (auto-compaction) and session reset exists harness-side (owner `!rotate`) |
| kills streaming, reaction acks | Accepted: streaming surfaces in the Buzz session viewer, not the channel; reactions are harness-posted. Channel-visible streaming remains an M23-rail property |
| kills single-flight | Dissolved: sessions map 1:1 to gateway conversations; per-conversation single-flight applies unchanged |
| harness auto-approves permissions — "the opposite of Fermix's trust model" | Dissolved by not playing: Fermix never emits `session/request_permission`; its sandbox modes + hardline blocklist remain the enforcement layer, and the approval flow is structurally unreachable from this surface (§11) |

M23 §14's deferred `buzz-backend-fermix` deploy binary is unaffected. M23's "revisit only as a thin demo shim" sentence is superseded by this design; the CoS-rail decision is not.

## 4. Decisions locked

| Question | Decision |
|---|---|
| Process topology | **Bridge, not boot.** `fermix acp` is a stdio⇄UDS pump into the running daemon (SQLite single-writer forbids a second tree; a private home would fork memory). Daemon down ⇒ fail fast and loud (§6.2). No standalone fallback (Rule 12) |
| Where logic lives | All ACP protocol logic daemon-side in `fermix_channels` (`Channels.Acp.*`). The bridge parses exactly two control lines (its hello, the daemon's ack) and nothing else |
| Integration shape | A channel. Registry entry: `%{name: "acp", config_key: :acp, adapter: Channels.Acp, remote?: true, trust: :local_operator, commands?: false, transport: :gateway, child: Channels.Acp.Supervisor}`. See the two new registry fields below — rev 1's `remote?: false` entry was broken (Sources would have carried `channel_key: :acp` and been rejected, `source.ex:36` + `authorizer.ex:45`) and would have opted ACP into the one-shot loopback behaviors (per-turn browser reaping, `queue.ex:419`) |
| `trust` registry field (new) | `trust: :local_operator` — consulted first by `Authorizer.resolve/1` (unconditional operator, before the sender-id clauses) and by the registry's `startable?`/`missing_ingress_authorizations` gates (channels with this trust need no ingress list). `cli`/`daemon` entries gain the same field (behavior unchanged); `remote?` keeps its lifecycle meanings only — for acp, `remote?: true` correctly keeps browsers warm across turns of a persistent session and makes harness-continuation delivery refuse loudly. One field, two consumers, no third trust tier |
| `commands?` registry field (new) | `commands?: false` — the gateway's command-dispatch step skips channels that opt out; message content is always model input. **This is the two-principal answer, simplified**: operator *tool* trust under Buzz is peer-parity (claude/codex run full-tool with `bypassPermissions` there — §11), but operator *command* trust would hand `/sandbox grant|revoke|confirm`, `/soul`, `/background` and friends to anyone who can @mention the agent — a cross-surface, durable blast radius no peer has. Removing the pipeline closes that hole with one field. All other channels default `commands?: true` |
| Protocol version | **Honest v1** (`schema-v1.20.0`). Buzz sends `2`; Fermix replies `1`; buzz-acp proceeds on legacy in-message prompt framing (verified). A client sending `0` also gets `1` back — negotiation replies with the latest supported version and the *client* decides to disconnect |
| Capabilities advertised | `loadSession: false`, `promptCapabilities: {}`, `mcpCapabilities` omitted, no modes/configOptions, `authMethods: []`, `agentInfo {name: "fermix", version}`. No `_meta.steering.supported` |
| Conformance scope | **"Buzz-first ACP v1 interoperability profile"** — spec-v1-shaped everywhere except: non-empty `mcpServers` ⇒ named `-32602` error ("session-scoped MCP servers are not supported yet; configure MCP in Fermix's own config"). Stdio MCP is a spec MUST, so rev 2 does not claim general v1 conformance (rev 1 did; the claims could not coexist). Buzz always sends `[]` for custom harnesses; Zed works when the user attaches no MCP servers to Fermix. Full conformance = §14 |
| Session ⇒ conversation | `session/new` mints a UUID `sessionId`; conversation key `{"acp", session_id, :root}`. Continuity across harness restarts = **daemon-global state only** (curated memory, skills, SOUL — the Reviewer/MEMORY.md pipeline), not conversation transcripts: Buzz never calls `session/load`, so a restart is a fresh conversation by construction. Worded honestly everywhere (rev 1's "memory intact" implied more) |
| Reply publication (Buzz) | **The model posts via the `buzz` CLI through Fermix's shell tool — exactly like every other Buzz agent** (the injected base prompt instructs it; the env overlay makes it work, §8.3). No framework-owned posting (§13). Turn *failures* become JSON-RPC errors, and **Buzz itself posts the in-channel failure notice** (its dead-letter/retry machinery) — error visibility without any Fermix delivery code |
| Env overlay | Bridge hello carries its spawn env; the **daemon** filters to an internal allowlist (`BUZZ_RELAY_URL`, `BUZZ_PRIVATE_KEY`, `BUZZ_AUTH_TAG`, `BUZZ_ACP_DISPLAY_NAME`, `NOSTR_PRIVATE_KEY`, `GIT_TERMINAL_PROMPT`, `GIT_CONFIG_COUNT`+`GIT_CONFIG_KEY_n`/`VALUE_n`, `PATH`) and discards the rest before storing. Applied at **one consumption point**: sandbox shell-command env construction for that session's conversations. Custody posture in §11 — peer-parity, plus scrubbing of the two secret values at the telemetry choke point |
| Workspace | **Reuse `request_cwd`** — the seam already exists end-to-end: `Message.request_cwd` (`message.ex:26`) → operator-only threading (`turn_runner.ex:334`) → `Sandbox.Mode.effective_roots/2`, where standard mode admits an inside-home cwd as a root (never `$HOME` itself), strict never admits it, open already covers it, canonicalization + blocked-roots always apply. The session's `session/new.cwd` (validated absolute) becomes `request_cwd` on every synthesized message. `~/.buzz` therefore works grant-free in standard mode; outside-home project dirs surface the existing sandbox refusal with the existing `fermix grant` guidance. Rev 1's new "workspace override" seam is **deleted** |
| Streaming out | A third stream tier, **`:raw`**: the adapter's `stream_capability/0` returns `:raw`; the gateway's existing stream-spec assembly selects it; the Queue then threads the adapter-built callback straight through **without a DraftStream engine**. Only `text_delta`/`text_done` become `agent_message_chunk` suffix-deltas; reasoning events are dropped (v1); the final `{:text, response}` delivery reconciles (emit any unsent suffix). Rev 1's quartet plan is dead: default block mode emits reasoning side-blocks (`draft_stream.ex:191,256`) and post-final compaction notices (`queue.ex:396,544`), so chunk concatenation would not equal the final message |
| Tool events | `activity_callback` threaded Queue→TurnRunner (same nil-safe shape as `stream_callback`), with one payload extension: `{:tool_finish, name, %{status: :ok | :error}}` (both consumers — cron watchdog, acp — updated together). Session emits `tool_call` (`in_progress`, title = tool name, kind mapped from policy class) at start and `tool_call_update` (`completed`/`failed`) at finish. Resets Buzz's idle clock at tool *start*; renders in the session viewer |
| Turn results | New optional **`turn_result_fn`** on the agent message (assembled by the gateway from an optional adapter callback, mirroring `build_text_reply`): invoked **exactly once per turn by the Queue** — `{:completed}` after the normal deliver/commit path, `{:failed, reason}` from the error path (the *raw* reason, before `error_reply/1` stringification) and from abnormal task DOWN, `{:cancelled}` from the stop path. Existing channels omit it; nothing else changes. This is what lets `Acp.Peer` emit exactly one terminal JSON-RPC response and map provider-auth failures to a message starting `"Re-authenticate: …"` (Buzz's dead-letter matcher) — today the Queue collapses every error into channel text (`queue.ex:398-402`), which no adapter can classify. Bounded public error rendering; raw reasons go to Logger, never the wire |
| Cancel | `session/cancel` ⇒ new `Queue.stop_conversation/2` (per-key extraction of `stop_all` internals: terminate the active turn task, stopped-turn marker, clear pending) ⇒ `turn_result_fn.({:cancelled})` ⇒ respond `stopReason:"cancelled"`. **The wire fence lives in the Peer**: after responding, late deliveries/stream events for that turn id are dropped-and-logged — the Queue's freshness check is check-then-act, not atomic, and rev 2 does not pretend otherwise. No rollback of already-performed side effects is claimed. `$/cancel_request` naming an in-flight `session/prompt` id runs the same stop path and completes that request with `-32800` |
| Approvals | `session/request_permission` never sent. No `approval_fn` is injected for acp turns ⇒ `request_directory_access` self-hides (its advertise gate requires `approval_fn`). Sandbox escalations end as normal denials whose text says how to grant from an owner surface |
| Detached work | Harness run tools hidden on this surface (their `advertise?/1` gains a channel check — continuations cannot deliver back to a client-owned ephemeral session; with `remote?: true` and no owner configured, `ContinuationDispatcher` would refuse loudly anyway, `continuation_dispatcher.ex:101`). Origin-mode `schedule_job` refused at schedule time with a named message; explicit-target scheduling to other channels works. `/background` is gone with the command pipeline |
| Telemetry | No new event names, no new run kind. **The transport emits the shared channel events itself** — `ChannelTelemetry.emit_parse/emit_message`, exactly as `cli.ex:30,123,189` does; `Gateway.ingest` does not do it for you (rev-1 error). Tools/providers via shared emitters. Overlay secret **values** scrubbed from telemetry content previews (§8.3). Socket lifecycle = structured Logger |
| Config | `[fermix_channels.acp] enabled` — the only knob. **Default `true`** (owner decision 2026-08-01; rev 2 shipped `false` — see §16.4). Socket path fixed; caps internal constants |
| Dependencies | None. Hand-rolled NDJSON JSON-RPC codec (Anubis is MCP-method-bound; hex ACP libs are stale). Upstream `schema.json`+`meta.json` vendored at `apps/fermix_channels/priv/acp/`, pinned by a contract test |

## 5. Goals / non-goals

**Goals**

- G1: An operator adds Fermix to Buzz as a custom harness (label "Fermix", command `fermix`, args `acp`) and org members @mention it like any agent: it answers in-channel via the `buzz` CLI it is instructed and equipped to run, shows live activity in the desktop session viewer, honors cancel/steer-fallback semantics, and carries Fermix's daemon-global memory/skills/persona across harness restarts (conversation transcripts do not survive restarts — Buzz never resumes sessions).
- G2: The same surface works for any spec-v1 ACP client **that passes `mcpServers: []`** (the Buzz-first interoperability profile): honest capability advertisement and negotiation (including version 0 → reply 1), baseline prompt handling (`text` + `resource_link`), `$/cancel_request`, clean stdout.
- G3: Sessions run as first-class gateway conversations: operator tool trust under the real sandbox (session cwd via `request_cwd`), durable memory, full telemetry through existing emitters — with the command pipeline, approvals, and detached work structurally absent.
- G4: The whole surface is one gate: `enabled = false` ⇒ no listener, no socket, nothing advertised anywhere — pinned by a test that enumerates the surface, not per-tool asserts. (The default is `true`, so the gate is what an operator uses to turn the surface *off*; readiness still gates the listener, so an unconfigured install opens nothing.)
- G5: `self_knowledge` updated in the same change; site docs get the BYOH runbook.

**Non-goals (v1)**

- The M23 CoS rail or any Nostr code. Slash commands on this surface. Steering. `session/load` replay. Session-scoped MCP servers (and with them, general v1 conformance). Modes/configOptions. Plan/thought/usage updates. fs/terminal consumption. Image/audio prompts or outbound media. ACP registry listing. Windows. ACP v2.

## 6. Architecture

```
Buzz desktop (Tauri)                     operator's machine                Fermix daemon (one BEAM VM)
┌──────────────────────┐   spawns   ┌──────────────────────┐   UDS    ┌──────────────────────────────────┐
│ managed agent:        │──────────▶│ buzz-acp harness      │          │ Channels.Acp.Supervisor          │
│  harness=custom       │           │  (pool of N slots)    │          │ ├ Acp.Endpoint (acp.sock 0600,   │
│  command=fermix acp   │           │   └ per slot:         │          │ │  accept loop, stale-probe)     │
└──────────────────────┘           │   fermix acp (bridge) │◀────────▶│ └ Acp.PeerSupervisor             │
                                    │    stdio NDJSON ACP   │ hello →  │    └ one Acp.Peer per connection │
 Zed / JetBrains / nvim ──spawns──▶ │    ⇄ raw byte pump    │ ← ack    │       (framing, JSON-RPC ids,    │
 (same binary, no Buzz)             └──────────────────────┘ then raw │        session table, wire fence)│
                                                                       │        └ per prompt:             │
                                                                       │          Gateway.ingest/2 →      │
                                                                       │          Authorizer→Queue→       │
                                                                       │          MainAgent/TurnRunner    │
                                                                       └──────────────────────────────────┘
```

### 6.1 Modules

| Module | Job |
|---|---|
| `Fermix.CLI.Acp` (fermix_core) | The bridge verb (§6.2). New clause in `Fermix.CLI` dispatch; ordinary tree-less CLI path (no special `cli_dispatch` casework) |
| `Channels.Acp.Supervisor` | Registered as the channel's transport child: `Endpoint` + `PeerSupervisor` |
| `Channels.Acp.Endpoint` | UDS listener — `gen_tcp` `{:local, path}`, chmod 0600, stale-socket probe-before-unlink, bounded accept (64 connections — two max-parallelism Buzz agents), starts one temporary `Peer` per socket (copies `local_voice_socket.ex` structure) |
| `Channels.Acp.Peer` | Per-connection GenServer and the unit of ownership: socket + NDJSON framing (10 MiB line cap), hello/ack, JSON-RPC id bookkeeping, `initialize` negotiation, **the sessionId → session-state table** (sessions are plain state, not processes — a session is a map: conversation key, filtered env, cwd, in-flight turn ref), per-turn wire fence, ordered outbound writes (single process = natural serialization), `$/cancel_request`. One Peer can never touch another Peer's sessions |
| `Channels.Acp.Wire` | Pure codec: NDJSON JSON-RPC encode/decode, method table, error structs. Golden-tested against the vendored schema |
| `Channels.Acp` | The channel adapter: `parse_webhook`/`verify_webhook` → `{:error, :unsupported_transport}`; `stream_capability/0` → `:raw`; reply/stream/turn-result closures target the Peer (Registry-keyed by session id); `send_message` = final-text reconcile; media parts render as a text line (`[attachment: <name> — not transferable over this surface]`) |
| `apps/fermix_channels/priv/acp/` | Vendored `schema.json` + `meta.json` @ `schema-v1.20.0` (provenance + checksum noted); `acp_contract_test.exs` validates every emitted frame in the golden suite and pins the version string |

**Why the M4.12 fate does not repeat**: inbound MCP shipped modules with no process wiring and was never reachable. Here the wiring is the milestone — the verb and the transport child are early stage deliverables with an end-to-end fake-client test, and live Buzz acceptance is a stage.

### 6.2 The bridge verb

1. Resolve `<FERMIX_HOME>/acp.sock`, connect. Failure: one stderr line ("Fermix daemon not running (or `[fermix_channels.acp]` disabled) — start it with `fermix run`; socket: <path>"), exit 1. No retry loop — the harness owns respawn policy. Note the honest Buzz UX: if the daemon is down at first spawn, all slots fail and the harness exits; the message is in the per-agent log, not necessarily the status summary.
2. Send one hello line: `{"fermix_bridge": 1, "app_version": "<vsn>", "env": {…full process env…}}`. **Wait for one ack line** (bounded: 5 s, 4 KiB): `{"fermix_bridge_ack": {"status": "ok"}}` → become a pure byte pump; `{"status": "error", "message": …}` → print message to stderr, exit 1. `fermix_bridge` is the compatibility integer — app patch skew never refuses. The ack is what keeps daemon refusals off stdout (rev 1 had the bridge "printing the daemon's refusal" with no channel to receive it on — self-contradiction, fixed). Hello caps: 256 KiB, 5 s, enforced daemon-side too.
3. Env filtering happens **daemon-side only** (single policy point; the transport is a same-user 0600 socket — a second filter in the bridge would add code, not security).
4. **stdout purity**: Logger to stderr before any output; no banner; golden test asserts a full session's stdout is byte-exact protocol frames.
5. Lifecycle: stdin EOF → close socket, exit 0. Socket close → stderr line, exit 1. Two pump directions, one coordinator, deterministic EOF handling. SIGKILL from the harness process group needs no cooperation.

Peer treats bridge disconnect as teardown: in-flight turns are cancelled via the same path as `session/cancel` (a respawned buzz-acp slot never reuses sessionIds — verified: fresh `session/new` after any exit).

### 6.3 Core seams (the complete list)

1. `ChannelRegistry` fields `trust:` + `commands?:` with their three consumers (Authorizer first clause; `startable?`/`missing_ingress_authorizations` ingress exemption; gateway command-dispatch skip). Every `local?` call site audited: authorizer (superseded by `trust`), browser reaping `queue.ex:419` (acp is `remote?: true` ⇒ keep-warm, correct), approval `resume_intent` `gateway.ex:516` (inert — no approvals here), continuation `local_channel` (refuses acp loudly — wanted).
2. `Queue.stop_conversation/2` — extraction of the existing `stop_all` per-key internals.
3. `turn_result_fn` — optional agent-message field, three exactly-once invocation sites in the Queue (normal return, error/DOWN, stop).
4. `:raw` stream tier — one clause in the existing stream-spec selection; no DraftStream for this tier.
5. `activity_callback` threading (Queue→TurnRunner→loop opts; `AgentLoop` already accepts it) + the `{:tool_finish, name, %{status: …}}` payload extension (cron watchdog match updated in the same change).
6. Session env overlay — context-carried, consumed at sandbox shell-command env construction only; plus secret-value scrubbing in `Tools.Telemetry.maybe_put_content` (one choke point, driven by a context-carried redaction list).
7. `request_cwd` set from the session's cwd — **zero new mechanism** (existing field, existing policy).

Nothing else in core changes.

## 7. Wire contract Fermix implements (v1 profile)

| Method | Fermix behavior |
|---|---|
| `initialize` | Reply `protocolVersion: 1` whatever the client sent (2 → 1: Buzz proceeds on legacy framing, verified; 0 → 1: client's call to disconnect). `agentCapabilities: {loadSession: false, promptCapabilities: {}}`, `agentInfo`, `authMethods: []` |
| `authenticate` | `-32601` (no methods advertised) |
| `session/new` | `cwd` must be absolute (`-32602` otherwise). `mcpServers != []` ⇒ named `-32602` (§4). Else mint UUID sessionId; record cwd + the connection's filtered env; capture `_meta.sessionTitle` as a log label; reply `{sessionId}` |
| `session/load`/`list`/`resume`/`close`/`delete`, `set_mode`, `set_config_option`, `logout` | `-32601` (capabilities honestly absent; Buzz only calls config/model switching when the session advertised it — verified it skips otherwise) |
| `session/prompt` | One in flight per session; a concurrent second ⇒ `-32600` ("prompt already in flight for this session" — the spec forbids the client behavior without defining a code; this is our server response, documented as such). Fold blocks (§8.2) → synthesized Message (`request_cwd`, overlay context, callbacks) → `Gateway.ingest/2`. Terminal response from `turn_result_fn`: `{:completed}` ⇒ `{stopReason:"end_turn"}`; `{:cancelled}` ⇒ `"cancelled"`; `{:failed, reason}` ⇒ JSON-RPC error — auth-shaped provider reasons map to `-32000` with message `"Re-authenticate: <provider> credentials rejected (…)"` (Buzz dead-letters immediately with a visible notice), everything else `-32603` with a bounded public rendering (raw reason to Logger only) |
| `session/cancel` (notif) | §8.5. Also fired internally on bridge disconnect |
| `$/cancel_request` (notif) | Pending non-prompt request ⇒ complete `-32800`. Pending prompt request ⇒ same stop path as `session/cancel`, then complete that request with `-32800` |
| unknown | requests `-32601`; notifications ignored |
| → `session/update` | `agent_message_chunk` suffix-deltas + final reconcile; `tool_call`/`tool_call_update` with real `completed`/`failed` statuses. Nothing else in v1 |
| → `session/request_permission`, `fs/*`, `terminal/*` | Never sent |

Timeout fit (documented, no code): Buzz's 900 s idle clock resets on every chunk and at every tool *start* (`tool_call`). A single silent tool exceeding 900 s still trips it; v0.5.2 has **no UI field** to raise the limit (the record field exists but nothing sets it), so the honest v1 posture is: long delegated work belongs on owner channels, not Buzz mentions — consistent with detached-work tools being hidden here anyway. No keepalive hacks (masks real hangs).

## 8. Session & turn design

### 8.1 Keying, queueing, persistence

Conversation key `{"acp", session_id, :root}`. One FIFO turn per key via the existing Queue; distinct sessions parallel. History persists in ConversationStore under the key; compaction and memory review run normally. Harness restart ⇒ new sessionId ⇒ new conversation, by construction (Buzz never calls `session/load`); what carries over is daemon-global: curated memory, skills, persona. Stated as-is in docs and `self_knowledge`.

### 8.2 Prompt folding

`text` blocks verbatim; `resource_link` ⇒ `[resource: <uri> (<name>)]`; `image`/`audio`/`resource` ⇒ `-32602` (capabilities are honestly false). Blocks join `\n\n`. With `commands?: false`, Buzz's slash pass-through block (single-event batches only, §2.2) lands as ordinary model text — the model can act on "/compact please" conversationally, but no Fermix command executes. `metadata.user_id` unset; sender attribution stays inside the prompt text where Buzz put it (§11).

### 8.3 The env overlay (the Buzz-reply enabler)

- Peer stores the daemon-filtered hello env per connection; each session snapshots it with its cwd. Tool executions for that conversation build their **sandbox shell-command** env as policy env ⊕ overlay (overlay wins on its keys; PATH included — the harness's PATH is what makes `buzz` resolvable). One consumption point; git/file/MCP/other tools untouched.
- **Custody, stated honestly (peer-parity, not invisibility):** any shell command the model runs in this session can read `BUZZ_PRIVATE_KEY` — exactly as it can for claude/codex under Buzz today, whose children inherit the same variables from the same harness with `bypassPermissions` on top. Fermix is strictly tighter (sandbox modes, profiles, hardline blocklist still bind). The key is Buzz-owned and relay-revocable (remove the agent, rotate). The overlay is RAM-only session state, never persisted, dropped at session end.
- **The boundary that is Fermix's own to defend is telemetry export**: tool output previews are captured under `capture_content` (`tools/telemetry.ex` `maybe_put_content`), so the two secret *values* (`BUZZ_PRIVATE_KEY`, `NOSTR_PRIVATE_KEY`) ride the context as a redaction list and are scrubbed at that single choke point before any preview is attached. Conversation history may still contain what the model chose to print — local SQLite, same trust domain as the harness's own logs; accepted and documented, not hidden.
- Non-Buzz clients: the allowlist matches nothing but PATH — tools see the client's PATH and run in the project root the client chose. Right for editors.
- Tests (the 2026-07-26 env-sanitizer lesson, both halves): **fidelity** — seeded fake `BUZZ_*` env + a fake `buzz` on the overlay PATH is reachable from a shell exec inside the session; **isolation** — absent from sibling conversations, absent after session end, and secret values absent from telemetry previews *even with* `capture_content: true` and a command that prints them.

### 8.4 Streaming and tool events

`:raw` tier: the Queue threads the adapter-built callbacks directly (no DraftStream). Peer keeps `sent_len` per turn; `text_delta`(cumulative) ⇒ suffix chunk; final `{:text, response}` ⇒ emit unsent suffix (or the whole text for unstreamed turns). Reasoning events dropped (v1); any *additional* `{:text, …}` delivery after the final reconcile (compaction notice — it is delivered post-commit, `queue.ex:396`) is dropped-and-logged: an internal housekeeping notice, not part of the reply. Tool events per §4: `tool_call` at start (kind from policy class: shell/harness/computer-use ⇒ `execute`, web/http ⇒ `fetch`, read/search classes ⇒ `read`/`search`, else `other`; toolCallId minted sequentially per turn), `tool_call_update` with the real `:ok | :error` outcome at finish.

### 8.5 Cancel

On `session/cancel` (or bridge disconnect): `Queue.stop_conversation(key)` (kill active turn task synchronously, stopped-turn marker — precisely right for Buzz's merged re-prompt — clear pending) → `turn_result_fn.({:cancelled})` → respond `stopReason:"cancelled"` → **Peer fences the turn**: any late delivery/stream event for that turn id is dropped-and-logged. The freshness check in the Queue is check-then-act; the fence is what makes the *wire* clean — rev 2 claims exactly that and no more (no atomic finalization machinery, no rollback of side effects; in-flight sandboxed subprocesses die with the task's tree via the existing CommandHost group-kill). Cancel-to-response target well under 1 s, pinned by test, against Buzz's 5 s drain.

## 9. Config & setup surface (registration checklist)

1. `ChannelRegistry` entry + the `trust`/`commands?` fields and their three consumers, with a regression test that cli/daemon/acp and one remote channel all authorize/start exactly as before/intended.
2. `Setup.ConfigStore`: snapshot read/apply, defaults (`enabled = true`), TOML render/parse of `[fermix_channels.acp]`.
3. `Setup.Runtime` key allowlist + `Setup.Wizard` answer key (a boolean toggle in the channels step; no interactive flow beyond it).
4. `SetupLive` + components: channels-tab toggle (boolean field renderer), save/restart path.
5. `Setup.Doctor`: acp section — enabled?, socket file present?, listener alive **queried over the daemon control socket** (doctor runs in a tree-less VM and cannot see the Endpoint process; daemon down ⇒ "daemon not running" degradation). Not added to `@command_channels` (no command pipeline here at all).
6. `FermixCore.Readiness`: enabled ⇒ ready (no secrets, no external deps).
7. `FermixCore.Health` `@channels`: acp entry (enabled, listener child, active peers/sessions counts).
8. `Fermix.CLI.Setup` `@switches` + `Mix.Tasks.Fermix.Setup` `@switches` (both copies): `--acp-enabled`; CLI usage/help text.
9. `config/config.exs` + test defaults; fixtures that enumerate channels.
10. `self_knowledge` SKILL.md: the surface, how to add Fermix to Buzz/Zed, what is absent (commands, approvals, detached work) — no version numbers.

**Deliberately skipped**: `SecretPaths` (no configured secrets — session credentials arrive per-connection and are never persisted); `@channel_ingress_keys` (no ingress lists — `trust: :local_operator`); jobs `delivery_channels` (sessions are ephemeral; origin-mode scheduling refused at schedule time with a named message; explicit targets to other channels work).

**Operator runbook (site docs + self_knowledge):**

1. `fermix run` (the surface is on by default; `enabled = false` in `config.toml` turns it off).
2. Buzz → Settings → Harnesses → Add custom: label `Fermix`, command `fermix` (absolute path if unusual install), args `acp` (one comma-free arg), env `FERMIX_HOME` only if non-default (GUI spawns inherit no shell exports — the FermixPet lesson; the BYOH env field is the fix).
3. Agents → new agent → harness Fermix. Expect: in-channel replies (model-posted via `buzz`), live activity in the session viewer, `fermix doctor` reporting the listener. Long delegated work belongs on owner channels (§7 timeout note).

## 10. Telemetry

No new event names, no new run kind. The **transport** emits `ChannelTelemetry.emit_parse/emit_message` (`:acp`, inbound/outbound) exactly as the CLI transport does (`cli.ex:30,123,189`) — `Gateway.ingest` does not emit them. Tools/providers flow through the shared emitters with MainAgent session ids. Overlay secret values scrubbed from content previews at the `maybe_put_content` choke point (§8.3). Listener/peer lifecycle (accept, hello refusal, session open/close, cancel, fence drops, bridge disconnect) is structured Logger, matching every other transport. Timeout paths through `FermixCore.Timeouts`.

## 11. Security model

- **Transport trust.** The bridge is spawned by a process running as the operator on the operator's machine over a 0600 UDS under `FERMIX_HOME` — the same class as `fermix ask` and the realtime socket. `trust: :local_operator` encodes it in the registry instead of overloading `remote?`.
- **Content posture, stated plainly.** Under Buzz, channel members' words arrive inside operator-trust prompts: whoever can @mention the agent drives its tools. This is the same envelope the operator already accepted for claude/codex under Buzz (full tools, `bypassPermissions`, same credential-bearing env) — and Fermix binds it tighter: sandbox floor/modes/profiles and the hardline blocklist gate every command, `:network`-class tool output renders inside untrusted framing. What Fermix **removes** from that envelope on this surface: the entire slash-command pipeline (`commands?: false` — no `/sandbox grant|revoke|confirm`, no `/soul`, no `/background`, nothing), the approval flow (no `approval_fn` ⇒ `request_directory_access` self-hides; a client that auto-answers `allow_once` can never mint a grant), and detached work (harness tools hidden; origin-mode scheduling refused). There is no claim that "owner-only boundaries hold" beyond this list — rev 1 made that claim and it was false. Operators who want a guest-trust Buzz presence use the M23 rail; a third trust tier for "delegated" content is rejected for v1 as machinery without a second customer (§13).
- **Session credentials.** Peer-parity custody, one Fermix-specific hardening: secret values scrubbed from telemetry export previews (§8.3). RAM-only, never persisted, closed struct with a custom `Inspect`, dropped at session end. Relay-side revocation is the recovery path (remove agent, rotate key).
- **Workspace.** `request_cwd` reuse means the *existing* policy decides: standard mode admits an inside-home session cwd as a root (never `$HOME` itself, canonicalized, blocked-roots enforced — `sandbox/mode.ex`), strict admits nothing, open already covers home. A hostile cwd cannot widen scope beyond what that policy always allowed.
- **Socket surface.** 0600, stale-probe before unlink, 64-connection cap, 10 MiB line cap, 256 KiB/5 s hello caps, one in-flight prompt per session, malformed frames answered with parse errors. `enabled = false` removes everything (G4).
- **Injection.** Prompt text is ordinary channel input — Content-Is-Data applies; nothing in it can reach commands (none), approvals (none), other sessions' overlays, or another Peer's sessions (Peer-local tables).

## 12. Implementation stages (step → verify)

Gates for every stage: `mix compile --warnings-as-errors`, `mix test`, `mix credo --strict`, `mix format --check-formatted`.

- **Stage 0 — Wire codec + vendored contract.** `Wire`, schema/meta vendored @ `schema-v1.20.0`, contract test.
  *Verify:* golden frames validate; negotiation table (1→1, 2→1, **0→1**); oversize/junk lines; `$/cancel_request` → `-32800`; unknown methods/notifications.
- **Stage 1 — Registry + gateway policy.** `trust`/`commands?` fields, three consumers, command-skip.
  *Verify:* acp Sources authorize operator with no sender id; cli/daemon/remote channels byte-identical behavior (regression suite); enabled acp starts its child with no ingress config and appears in no missing-ingress log; a `/sandbox grant` message on a `commands?: false` channel reaches the model as text and executes nothing (the whole-surface test, M28 lesson: enumerate every command, loop).
- **Stage 2 — Queue seams.** `stop_conversation/2`, `turn_result_fn` (three exactly-once sites incl. task DOWN), `:raw` tier, `activity_callback` threading + `{:tool_finish, name, %{status}}` (cron watchdog updated).
  *Verify:* per-key stop kills only that conversation, marker written, sibling turns untouched; `turn_result_fn` fires exactly once for: normal completion, error path (raw reason delivered), task crash, stop — and never twice under stop-vs-completion races (deterministic interleaving tests); raw tier bypasses DraftStream and receives deltas; existing channels (no `turn_result_fn`, block/draft tiers) byte-identical.
- **Stage 3 — Endpoint + Peer + adapter (the vertical slice).** Hello/ack, initialize, session/new (cwd absolute + `request_cwd`, mcpServers refusal, overlay snapshot), prompt→chunks→end_turn, tool events, cancel + fence, error mapping, `emit_parse`/`emit_message`.
  *Verify (fake ACP client over a tmp-home socket, hermetic):* full transcript — initialize(2)→1; prompt (multi-block + leading `/word` + resource_link) → streamed chunks whose concatenation equals the final reply (reasoning + compaction notice excluded by construction, asserted); tool_call/`failed` update for a failing tool; `mcpServers:[…]` → named `-32602`; concurrent prompt → `-32600`; **cancel mid-turn → `cancelled` < 1 s, zero post-cancel frames (fence test), merged re-prompt answers once**; bridge-disconnect teardown; provider-401 stub → `-32000` message starting `Re-authenticate`; env overlay fidelity/isolation/scrub quartet (§8.3); `request_cwd` admitted in standard mode (fake home), refused in strict with the existing message; **disabled config ⇒ no socket, no child, surface-enumeration test finds nothing (G4)**; parallel sessions parallel turns; harness tools absent from the advertised set on acp turns.
- **Stage 4 — Bridge verb.** Dispatch clause, hello/ack, pump, exit codes, Logger-to-stderr.
  *Verify:* pump unit tests (EOF both ways, refusal ack → stderr + exit 1, connect failure message); **stdout purity golden test** (scripted session: stdout byte-exact protocol, all logs stderr).
- **Stage 5 — Setup surfaces.** §9 items 2-10.
  *Verify:* config round-trip; both setup entrypoints accept the flag; doctor (daemon up/down variants) and health render; origin-mode `schedule_job` from an acp conversation returns the named refusal; channel-enumerating fixtures updated.
- **Stage 6 — Live acceptance (manual, operator).** Real Buzz stack + desktop: BYOH-add; mention → in-channel reply posted by the model via `buzz`; session-viewer activity; mid-turn second mention → cancel+merge answered once; `!cancel`; provider key revoked → Buzz's re-auth dead-letter notice appears in-channel; harness restart → fresh conversation with daemon memory recall demonstrated; Zed smoke (no MCP servers configured; project cwd honored). Then a Tier-B `fermix-e2e-eval` suite entry.

## 13. Rejected alternatives

- **Standalone boot / boot-if-daemon-down hybrid**: SQLite single-writer + forked memory; Rule 12.
- **A third trust tier ("delegated") or per-channel capability profiles**: real machinery through TurnRunner/CapabilityRegistry/commands for exactly one surface, when disabling the command pipeline + hiding detached tools achieves the material risk reduction with two registry fields. Revisit only when a second delegated surface exists.
- **Framework-owned Buzz posting** (`Acp.BuzzDelivery` running the `buzz` CLI): double-posts against a model the injected base prompt *instructs* to post; requires parsing Buzz's `[Context]` prompt text for reply anchors (coupling to a prompt format Buzz can change silently); makes core delivery Buzz-specific. Its motivating hole — command replies invisible in-channel — is closed by removing commands; error visibility is provided by Buzz's own dead-letter/retry notices once failures are JSON-RPC errors (§4). If a future client needs framework posting, it is a new design, not a fallback here.
- **Per-binary credential injection** (env visible only to `buzz` invocations): matching "the command is really `buzz`" on shell-mediated strings is unsound (compound commands), and a sound matcher is a new security-relevant parser — complexity with a false-safety smell. Peer-parity + export scrubbing is honest instead.
- **Claiming `protocolVersion: 2`**: buys `systemPrompt`-via-param today, breaks the day Buzz adopts real v2 semantics. Legacy framing is verified-working.
- **The streaming quartet / DraftStream for acp**: block mode emits reasoning side-blocks and post-final notices — concatenation would lie; draft mode's throttle/edit semantics solve a chat-UX problem this wire doesn't have. A raw tier is less code end-to-end.
- **Reusing `realtime.sock`/`daemon.sock`**: different wires, different version cadences.
- **Anubis / hex ACP libs as the codec**: MCP-method-bound strict validation / stale pre-2026 surfaces.
- **`remote?: false` (rev 1)**: broken authorization via `Source.channel_key` derivation, plus per-turn browser reaping on a persistent-session surface.
- **Mapping sandbox approvals onto `session/request_permission`**: the first target client auto-answers `allow_once`; an approval UI that cannot decline is not one.
- **A keepalive to defeat Buzz's idle timer**: masks real hangs; the honest posture is "long detached work doesn't belong on this surface" (and its tools are hidden here).
- **A `trust` config knob**: a security boundary as a toggle invites the guest-but-actually-operator misconfiguration; postures are rails (this one, M23), not knob values.

## 14. Deferred

- **Session-scoped stdio MCP servers** — lifts the `-32602` refusal to full spec-v1 conformance; needs per-session Anubis client lifecycle/supervision/teardown design.
- **Steering** (`_session/steering` → inject at the next loop-iteration boundary; advertise `_meta.steering.supported`). Cancel+merge is correct meanwhile.
- **`loadSession: true`** — replay from ConversationStore (valuable for Zed; unused by Buzz).
- **Slash commands on this surface** — if ever wanted, as an explicit per-channel command allowlist (the guest `command_allowlist` shape), never the full operator pipeline.
- **configOptions/modes** (model via `Providers.RoutingOverrides`, sandbox mode), **plan/thought/usage updates**, **`available_commands_update`**, **richer tool content** (diffs, locations), **outbound media as image content blocks**.
- **ACP registry listing** (whether `authMethods: []` qualifies is unverified) and an upstream Buzz preset PR once proven.
- **ACP v2** when stabilized — Wire/session split is shaped for it.
- **Transport-lifecycle telemetry** — same named follow-up as M23 §10.
- **Windows** (named pipes) — with the broader Windows story.

## 15. Open questions

1. **Buzz idle timer vs long tools**: is "long work belongs on owner channels" sustainable in practice, or does real usage need periodic `tool_call_update` progress patches (which also reset the clock)? Decide from Stage 6 usage.
2. **Chunk cadence**: `:raw` forwards provider delta cadence; if observer-frame volume looks excessive (Buzz paces frames ~6/s), add a small coalescing constant in the Peer — measure first.
3. **`kind` fidelity on tool_call**: policy-class mapping is coarse; worth a per-capability hint only when a client visibly benefits.
4. **Multiple Buzz agents / multiple daemons**: BYOH env can point different agents at different `FERMIX_HOME`s; one daemon also serves several agents structurally (distinct connections/overlays). Document as supported, or discourage until asked for?

## 16. Implementation log (2026-08-01)

Stages 0–5 implemented; Stage 6 (live Buzz acceptance) is owner-run and outstanding. Gates on completion: `mix compile --warnings-as-errors` clean, `mix test` **4840 tests + 2 doctests, 0 failures** on two seeds, `mix credo --strict` 904 files / 0 issues, `mix format --check-formatted` clean. All work uncommitted pending review.

### 16.1 Deviations that change a design decision

1. **The harness prompt/wire mismatch was fixed by removing the category, not by gating the prose.** §4 hid harness *tools* on acp turns, but `Prompt.RuntimeSections` renders the "Coding Harness" section from `HarnessConfig` alone, so an acp turn was told to route work to `codex_run` while no harness tool was on the wire (the M28 pitfall shape). Fix: the client-owned trust profile is built with `excluded_categories: [:harness]` — an existing knob already used by realtime/voice — cached as a `harness_free_profiles` variant on `RuntimeContext` (required field, `Map.fetch!`, fail-loud). Prompt text and advertised schemas now derive from **one** list, which is the actual cure for the drift class. **Consequence beyond the design's wording:** the harness family leaves `profile.capabilities`/`dispatchable` entirely on acp turns, so a by-name `codex_run` dispatch misses the tool instead of reaching the execute-time `Harness.Authorization` refusal. Judged more correct (§4 says such a run cannot deliver its continuation, so the alternative spawns a real vendor CLI, does real work, then fails to report), and reversible in one line if the owner disagrees.
2. **The env overlay reaches the shell tool via `Sandbox.shell_plan/3`, not only `Sandbox.CommandTool`.** §8.3 named "sandbox shell-command env construction" as one consumption point; in reality `Tools.Shell` builds its env through `Env.build/3` while `CommandTool` uses `Env.build_command/3`. As first built, a shell exec on an acp turn saw neither the harness `PATH` nor `BUZZ_PRIVATE_KEY` — i.e. reply publication (§2.4 problem 1) did not work. Both callers now share one caller-side merge helper on `Sandbox.Env`; `build/build_command` semantics are unchanged, so every non-acp caller is byte-identical. Corollary worth knowing: `git_read`/`git_write` run through `CommandRunner` with an additive env and never see the overlay, so the allowlist's `GIT_*` keys only take effect when the model runs git *through the shell tool*.
3. **The telemetry scrub is broader than §8.3 described.** §8.3 specified scrubbing the `:input`/`:output` previews. Implementation found those are capture-gated while caller-supplied `:metadata` is merged **unconditionally** — and `Tools.Shell` passes `metadata.command` (verbatim command text) plus an `error_summary` that embeds child stdout on a non-zero exit. A command containing the key, or a failing command printing it, therefore exported the secret on the always-on path. The scrub now also covers metadata values (recursive, depth-capped at 8, same `«redacted»` marker and 8-byte floor, structs passed through, zero traversal when `redact_values` is empty). The guarantee is now strictly broader than the prose.
4. **The `schedule_job` origin refusal lives in `Jobs.DeliveryDefaults.resolve/3`**, not `schedule_job.ex` (§9). That function has exactly one caller and is the only place the *resolved* mode is known — a `default_delivery_mode = "origin"` config default never appears in the tool's args and would have slipped past a check on raw args.
5. **Doctor's acp section is a `Fermix.CLI.Doctor.Checks` row**, not a `Setup.Doctor` probe (§9 item 5). Every doctor row lives in `Checks`; `Setup.Doctor` is the probe library that runs in the tree-less CLI VM where the Endpoint cannot exist. Liveness goes over the daemon control socket's existing `health` method (no new socket method, no new payload field). `Setup.Doctor.enabled_probe_channel?/1` gained one clause so a `trust: :local_operator` channel is not reported as "enabled but unprobed". `Channels.Acp` deliberately exports no `health_check/1` for the same reason.
6. **`FermixCore.Readiness` is unchanged.** §9 item 6 called for a check; acp has no credential and no external dependency, so the correct implementation is the *absence* of one (a check that always returns nil is dead code). Behavior is pinned by tests only.

### 16.2 Smaller deviations, grouped

**Wire/codec (Stage 0).** The contract test pins *structure* (every `known_methods/0` entry present in the vendored `meta.json`, schema `$defs` presence, checksums in `PROVENANCE.md`) rather than running full JSON-Schema validation — §4 forbids a new dependency. `decode_line/1` additionally rejects non-object `params` (`-32602`), a non-string/number `id` and an empty/non-string `method` (`-32600`), and treats explicit `"id": null` as a notification — validating at the codec rather than silently coercing (Rule 12). `Wire.Error` is a struct defined in `wire.ex`.

**Gateway/queue (Stages 1–2).** The gateway's closures tuple became a keyed map (7 members); `run_commands/5`, `configured_stream_spec/3`, `build_agent_message/3` extracted to hold the size rule. `stream_capability/0` is typed `:draft_edit | :raw | :none` (`:none` is load-bearing in the existing docs). `AgentLoop`'s internal tool-result map gained `status: :ok | :error` (`text_result/1` → `/2`, 6 call sites) because that map is the only non-heuristic carrier of the outcome. `turn_result_fn` is stashed only in the queue's active-turn entry and claimed via `{:claim_turn_result, key, pid}` — the claim is what makes exactly-once hold under a stop-vs-completion race. Two outcome sites beyond the three specified: a failed turn-state checkout and a failed `Task.Supervisor.start_child` each fire `{:failed, reason}` (both already reply to the channel and neither produces an abnormal DOWN, so without them a turn would end with no terminal signal).

**ACP surface (Stage 3).** Session ids are `"acp-" <> 32 hex`, not a UUID. `$/cancel_request` naming a pending *non-prompt* id is dropped-and-logged: every non-prompt request is answered synchronously inside its own frame, so that state cannot occur. `:iteration_started` is *consumed* (resets the cumulative-delta baseline) rather than ignored — the loop's `text_delta` snapshots are cumulative per iteration, so without it a multi-iteration turn puts sliced garbage on the wire. `Endpoint` traps exits so `terminate/2` releases the listen socket and the socket file on every path. Tool-kind map extends §8.4's: `:read_write`/`:exec`/`:gui_control` → `execute`, `:external_api` → `fetch`. Test-injectable opts (`:socket_path`, `:max_connections`, `:hello_timeout_ms`, …) mirror `Realtime.LocalVoiceSocket`'s seam shape and add no operator-facing knob.

**Bridge verb (Stage 4).** Module is `Fermix.CLI.AcpCommand` (house naming, every sibling verb is `*Command`). **`:io.setopts(encoding: :latin1)` before pumping is required and the design missed it** — Elixir stdio defaults to unicode, so `IO.binwrite` double-encodes every non-ASCII byte and corrupts the protocol stream; a byte-exactness test on ASCII fixtures passes while production breaks. Connect errors outside the daemon-down family (`enoent`/`econnrefused`/`timeout`/…) get their own named line rather than being collapsed into "daemon not running" (M28 lesson on distinct failure kinds). The bridge does not enforce the 256 KiB hello cap client-side — the daemon is the single policy point (§6.2.3) and a second cap would be duplicate policy. `application.ex` needed no change: `acp` already falls through to the tree-less `System.halt(run_cli(argv))` clause. `Timeouts.acp_bridge_hello/0` (5 s) is now read by both ends.

**Setup (Stage 5).** No interactive wizard *question* — acp gets a flag plus a web toggle, following the `computer_use_enabled`/`harness_approved` precedent for off-by-default advanced features. `config/config.exs` declares `acp: [enabled: false, mode: :gateway]`; `mode` is a registry-shape constant, never asked for, never rendered to TOML, and `normalize_acp/1` accepts only `enabled` — so `enabled` remains the one operator knob. The health payload carries `process_alive` but no peer/session counts (§9 item 7): `fermix_core` has no compile dependency on `fermix_channels`, so counts would need reflection — the accessors (`Endpoint.connection_count/1`) exist when wanted.

### 16.2b Stdout purity needed a second, earlier redirect (found by manual dev-daemon testing)

§6.2 item 3 said "configures Logger to stderr before any output", and `AcpCommand` does — but that is **too late**. `config/runtime.exs` calls `ConfigStore.bootstrap_runtime_config/1` before any application starts, and a boot warning there (an unresolvable `@keyring` sentinel, a plaintext-secret notice) goes to the default handler = **stdout**, ahead of the verb's own redirect. Reproduced from source (485–582 stdout bytes) and confirmed for the release path from the built `start.script` boot order: the config provider runs after only `kernel`+`stdlib`, so Erlang's `:logger` owns the default handler (`logger_std_h`, `type: standard_io`) and Elixir's Logger has not started yet.

Fix: `config/runtime.exs` sniffs argv (`System.argv/0`, plus `Burrito.Util.Args.argv/0` when running standalone) and, **only for the `acp` verb**, points the default handler at `:standard_error` before hydration. **Both redirects are load-bearing** — a release starts the `logger` app *after* the config provider, and `Logger.App.start/2` re-adds a `:default` handler that falls back to `standard_io`, so the verb's own move is what re-establishes the guarantee. Regression test is necessarily a **subprocess** test (an in-process assertion cannot observe output emitted before app start), asserting stdout is byte-empty while stderr carries the refusal.

Two consequences worth carrying forward: any future stdio-protocol surface inherits this hazard and needs the same argv sniff; and an invocation that does not put the verb in argv (e.g. calling `AcpCommand.run/2` directly from `mix run -e`) misses the sniff and leaks — the dev wrapper must dispatch through `Fermix.CLI.main/1`. Related: under a locale-less GUI spawn (`env -i`), stdio opens as latin1 and the refusal's em dash renders as `\x{2014}` on **stderr** — cosmetic only; the pump was proven byte-identical for UTF-8 payloads under both `env -i` and a UTF-8 locale, because `raw_mode/1` pins both devices to latin1 and writes via `IO.binwrite/2`.

### 16.3 Known gaps and follow-ups

- **Stage 6 (live Buzz acceptance) not run** — everything below the wire is test-proven against a fake ACP client over a real UDS socket, but no real Buzz stack has driven it.
- **`update_job` is not gated**: an existing job can still be flipped to `delivery_mode: "origin"` from an acp conversation. §4/§9 only specified refusal at *schedule* time, so this matches the spec as written — flagged in case the intent was any origin binding from an acp turn.
- **Agent-turn content previews are not scrubbed**: `[:fermix, :agent, :message]` attaches reply text without consulting `redact_values`, so a model that echoes a secret into its own reply still exports it. Per §8.3 the scrub is specified at the tool choke point only; the same applies to any other `Telemetry.preview/1` caller.
- **Stale comment**: `turn_runner.ex` still calls `Tools.Telemetry.maybe_put_content` "the single choke point" — accurate before 16.1 item 3, now understated.
- **RESOLVED — the `peer_test.exs` parallel-sessions flake was a real test defect** (~50–75% failure in isolation; two agents disagreed about it because it is near-invisible in a warm full-suite run). Root cause: the test bound each turn's runner to a prompt by `:turn_started` **arrival order**, but the whole point of the test is that the two lanes run concurrently — so the order is a coin flip, and on a swap it finished one turn and then waited out the 5 s receive budget on the other. Fixed by correlating runners to sessions via `chat_id` (`Map.fetch!`, fail-loud) instead of by position; 8/8 isolated runs green, 118/118 for the directory. No timeout was loosened and no sleep added.
- **Two test-isolation bugs found and fixed during the final gates run** (both sides of the repo's own leaked-app-env rule): the new `--acp-enabled` setup-task test applied a snapshot to live app env without restoring `:fermix_channels, :acp`, and `WizardTest` asserted an enabled-channel default it never established. Polluter now restores; victim now establishes its own baseline.

### 16.4 The surface ships ON by default (owner decision, 2026-08-01)

Rev 2 specified `enabled = false`, argued from minimal-knobs and the house pattern (inbound MCP, computer use, harness approval all default off). The owner overrode it on a discoverability argument that beats it: a user who never learns the surface exists adds Fermix to Buzz or Zed, hits the refusal, and concludes Fermix has no ACP support — the feature fails silently for exactly the people it is for.

The security review that supports the flip: the socket is 0600 same-user, and **`~/.fermix/daemon.sock` is already always-on, unauthenticated** (its own comment: "the trust boundary is the 0600 socket file") and strictly *more* capable — its `agent_message` path runs through the `cli` channel with the slash-command pipeline enabled, reaching `/sandbox grant`, `/soul`, `shutdown`, `plugins_apply`. The acp entry carries `commands?: false`. Default-on therefore adds no new privilege class, and gating the §8.3 env overlay behind a second knob (floated in review) would have been theater against that baseline. Readiness still gates the listener, so an unconfigured install opens nothing.

Two implementation findings, both of which invalidate reasoning stated earlier in this doc:

1. **One line in `config/config.exs` was NOT sufficient — the release would have ignored an operator's `enabled = false`.** `ConfigStore.apply_channel_config/2` merges persisted TOML over the compile-time default, so an absent `[fermix_channels.acp]` section correctly inherits the new default (this is what makes `brew upgrade` seamless: no existing config.toml carries the section, since the feature never shipped). But `Config.Provider.boot/1` ends with `Application.put_all_env(merge(sys.config, runtime.exs declarations), persistent: true)`, so any key declared in `config/config.exs` and **not re-declared in `config/runtime.exs`** is reset to its compile-time value *after* `bootstrap_runtime_config` hydrated it. All five sibling channels re-declare themselves (`config :fermix_channels, telegram: Application.get_env(...)`); `:acp` did not, so a persisted `false` would have been silently overwritten back to `true` in a release. Fixed by adding the same re-declaration. Invisible under `mix`, where `loadconfig` applies only what runtime.exs declares — which is why it took decompiling the provider to find. **The same gap still exists for `:fermix_core` `:jobs` and `:transcription`** (found, not fixed — a separate change).
2. **A failed socket bind took down the whole daemon.** `Endpoint.init/1` returned `{:stop, reason}`, which propagates through `FermixChannels.Application` and kills boot — reproduced with a 121-character `FERMIX_HOME`, where `acp.sock` exceeds the platform `sun_path` limit (~104 bytes on macOS) and `:gen_tcp.listen` returns `:einval`. Unreachable while the surface was off; with it on, every ready install binds at boot, so one unbindable path bricks the daemon entirely — no agent, no channels, not even the CLI control socket. Fixed so an unbindable listener refuses loudly and returns `:ignore`, leaving the daemon up (a bad Telegram token does not kill boot either), with a pre-flight path-length check because `:einval` is unreadable as a diagnosis. Verified against a real `:fermix_core` + `:fermix_channels` boot: with a 121-byte `FERMIX_HOME` the tree, its sibling children and the daemon all survive, no socket is created, and the operator gets one line — *"ACP is disabled for this boot: the ACP socket path is 130 bytes, over the 103-byte limit this OS allows for a unix socket address — set a shorter FERMIX_HOME and restart. Path: …"*; with a short home the endpoint binds at 0600 and serves a real client. Failure kinds stay distinct (path-too-long / permission-denied-bind / permission-denied-mkdir / another-daemon-listening), the live-socket case is now proven non-destructive (the other daemon's socket survives *and still accepts clients*), and a fresh-machine first run is pinned alongside the fail-closed branches per the pre-flight pitfall. `Health` already reported a non-started endpoint as `:degraded` with `process_alive: false`, and doctor turns that into an actionable row — verified, unchanged.

Setup copy was also cut to one sentence — "Lets clients like Zed or a Buzz harness drive this daemon over a local socket." — matching the other channel toggles; the omitted detail (no token, no slash commands, restart required) belongs in docs, and the restart is already carried by the restart-key affordance.
