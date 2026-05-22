# Main Agent Runtime Context Cache

**Status:** Design approved 2026-05-21. Code cleanup pending (see §7).
**Date:** 2026-05-19 draft; 2026-05-21 implemented draft; 2026-05-21 revised to server-epoch policy; 2026-05-21 collapsed to single refresh boundary (`fermix restart`).
**Author:** Sujeeth / Aira
**Depends on:** `docs/MILESTONE_4_5_PROMPT_BOOTSTRAP_ARCHITECTURE.md`, `docs/MILESTONE_4_9_UNIFIED_CAPABILITIES.md`, `docs/MESSAGE_GATEWAY_ARCHITECTURE.md`

## TL;DR

Runtime context is pinned to a MainAgent server epoch. The main agent builds the markdown-backed prompt base and the capability runtime once on the first inbound message, then reuses that immutable snapshot across every message in the epoch.

Prompt, config, skill source, and tool source changes are not hot-reloaded into active runtime context. **`fermix restart` is the only supported refresh boundary.** There is no in-process reload command, no telemetry-driven invalidation, and no separate "skill reload" verb. This keeps the hot path simple, avoids stale async rebuild races, and gives operators one mental model.

Provider calls remain stateless: Fermix still sends the cached prompt and selected tools to the provider on each request. The local cache avoids repeated local work; provider prompt caching is only an opportunistic latency/cost optimization.

`/compact` is only a conversation-history operation. It never reloads prompt files, skills, MCP tools, or runtime context.

---

## 1. Problem / Goal

The main agent currently has multiple runtime inputs:

- bootstrap/system prompt files
- `USER.md` and `MEMORY.md`
- generated runtime sections
- skills and capability registry entries
- provider tool schemas derived from capabilities
- conversation history

Only conversation history is expected to change per message. The other inputs are runtime sources. Rebuilding and rescanning them on every message is unnecessary, and hot-reloading them inside active tasks creates correctness risks.

**Goal:** define one explicit lifecycle for the main agent runtime context:

1. Build the runtime context once per MainAgent server epoch.
2. Reuse it across messages.
3. Refresh it only by restarting the server (`fermix restart`).
4. Keep execution-time authorization authoritative even if prompt text is pinned.

There is intentionally **one refresh command** (`fermix restart`). A separate `fermix reload` is rejected: doctor is read-only diagnostics, no other command currently mutates runtime state, and a second refresh verb only saves a few seconds of restart latency at the cost of an extra concept for operators and an extra in-process code path to maintain. Restart preserves conversation history (`ConversationStore` is persistent), so the operator-visible cost is small.

This document is not a gateway redesign and does not change owner/guest authorization semantics.

## 2. Terms

| Term | Meaning |
| --- | --- |
| Conversation key | `{channel, chat_id, thread_scope}` used by `ConversationStore`. This is the durable chat history boundary. |
| Provider turn | One `AgentLoop.run/1` invocation for a user message. It can include multiple provider calls if the model calls tools. |
| Runtime context | File-backed prompt base, generated runtime section, selected capabilities, and prompt accounting used to start a provider turn. |
| Runtime profile | The runtime section and capability list for a trust profile such as `:operator` or `:guest`. |
| Server runtime epoch | The period during which one main-agent runtime snapshot is valid. It begins when the snapshot is built and ends on server restart. |
| Prompt memory files | `USER.md` and `MEMORY.md`, rebuilt from durable memory rows. |
| Conversation compaction | Rewriting older conversation history into a compact summary. This is separate from runtime context. |

## 3. Lifecycle Policy

Runtime context is immutable during a server runtime epoch. `fermix restart` is the only supported refresh boundary.

| Event | Runtime context behavior |
| --- | --- |
| Server start | No hot reload state exists yet. The first accepted turn builds runtime context. |
| First message in epoch | Build prompt base and runtime profile inside the `MainAgent` GenServer (synchronous), then reuse the snapshot. |
| Later message in same epoch | Reuse the same snapshot. Do not read prompt markdown files or rescan capabilities. |
| `/compact` | Replace conversation history only. Do not rebuild runtime context. |
| Auto compaction | Replace conversation history only. Do not rebuild runtime context. |
| New conversation key | Reuse the current server runtime context. Do not reload source files. |
| Prompt memory rebuild (`PromptFiles.rebuild/4`) | Writes new `USER.md` / `MEMORY.md` to disk but does not mutate active runtime context. `fermix restart` is required to pick up new files. |
| Skill source change (file added/removed under skills dir) | `fermix restart` is required. There is no `MainAgent.reload_skills/1` and no `fermix reload`. |
| MCP/tool source change | `fermix restart` is required. |
| Provider route/model/config change | `fermix restart` is required. |

This policy intentionally rejects background invalidation and async rebuild inside active message processing.

### 3.1 Why no `fermix reload`

A separate in-process reload was considered and rejected. It would shave ~3–10 seconds off the iteration loop for operators dropping new skills on disk, at the cost of:

- A second operator verb (`reload` vs `restart`), with non-obvious rules about which to use when.
- A daemon-socket route for in-process refresh that must stay synchronized with `fermix restart`'s coverage.
- Tests that have to assert both refresh paths behave identically for the things both cover.
- A real but small risk that an in-flight task built against the pre-reload snapshot will reply with text describing skills the new snapshot no longer lists.

For single-owner local usage, skill iteration is occasional. The 5-second restart cost amortizes across many idle minutes. The clarity of one verb outweighs the iteration-loop benefit.

## 4. Current Provider Boundary

Fermix provider calls are stateless today. OpenAI Responses/Codex requests send instructions, input, and tools for the turn. Provider adapters may reuse converted tools across continuations inside one provider turn, but Fermix does not rely on provider-side stored sessions as the canonical runtime context.

Therefore:

- local runtime context caching reduces file I/O, injection scans, runtime-section generation, and capability selection
- provider prompt caching can help when bytes stay stable
- provider prompt caching is not a correctness mechanism
- provider-specific tool payload caching is not part of this design

The desired rule is:

```text
cache locally, send every provider turn, keep bytes stable
```

## 5. Architecture

Add or keep a small `FermixCore.Agents.RuntimeContext` module owned by `MainAgent`.

`RuntimeContext` holds:

- `agent_id`
- `built_at_ms`
- base prompt messages exported from bootstrap prompt files plus `USER.md` / `MEMORY.md`
- base prompt accounting
- available skills snapshot
- enumerated runtime profiles (`:operator`, `:guest`)

The struct does **not** carry a `registry_revision`. There is nothing to compare it against under epoch pinning — see §7.5.

Each runtime profile holds:

```elixir
%{
  trust: :operator | :guest,
  capabilities: capabilities,
  runtime_message: %{role: "system", content: runtime_section},
  runtime_accounting: accounting_entry
}
```

The message path uses:

```elixir
profile = RuntimeContext.profile_for(ctx, source_trust, capability_registry, opts)
messages = RuntimeContext.messages_for(ctx, profile, history, user_message)
```

`AgentLoop.run/1` receives `capabilities: profile.capabilities` explicitly. When explicit capabilities are passed, `AgentLoop` must not rescan the registry for the same turn.

### 5.1 Prompt Base vs Runtime Section

`PromptComposer` should keep the file-backed base separate from generated runtime sections:

1. `compose_base_with_metadata/1`
   - loads bootstrap prompt files
   - loads `USER.md` / `MEMORY.md`
   - runs injection scanning
   - returns ordered parts and accounting
   - does not append generated runtime text

2. `RuntimeSections.build/2`
   - receives the exact filtered capability list
   - derives the visible skill catalog from that same capability list
   - never advertises a skill hidden by the active trust policy

3. `compose_with_metadata/1`
   - remains as a thin wrapper used by `Realtime.SessionServer` only; it composes the base then appends a runtime section built from `runtime_capabilities:`
   - must not become a second runtime-context design

### 5.2 Profile Selection

Keep the profile space enumerated:

- `:operator` is cached with the runtime context
- `:guest` is cached with the runtime context
- voice/realtime keeps its own session-scoped runtime and may reuse the builder later

Do not add a normalized profile dictionary keyed by arbitrary allowlists, policy structs, or exclusion sets unless a real caller needs it.

### 5.3 Ownership

`MainAgent` owns runtime context mutation.

The first inbound message of an epoch triggers a synchronous build inside `handle_cast({:handle_message, msg}, state)`, before the message task is spawned. The GenServer is briefly busy during the build (a few small file reads, an injection scan, and a runtime-section render — typically a few milliseconds); any other messages enqueued during that window proceed normally after the build completes.

Spawned message tasks receive the populated `runtime_context` through `task_runtime_state/1`. Tasks never write runtime context back to the GenServer. Task-side write-back (`GenServer.cast(server, {:cache_runtime_context, ctx})`) is explicitly forbidden:

```elixir
# Do NOT do this. Tasks must not publish snapshots into MainAgent state.
GenServer.cast(server, {:cache_runtime_context, ctx})
```

This prevents the failure mode where a long-running task overwrites a newer snapshot with one it built against older state.

If the synchronous build fails (corrupt prompt file, registry unreachable, etc.), `MainAgent` sends a per-message error reply via `msg.reply_fn`, logs the cause, and leaves `state.runtime_context` as `nil`. The next inbound message retries the build. The GenServer does not crash. Boot-time hard failure is **not** required (see §8).

## 6. Authorization Rule

Prompt text **and the capability set** are server-epoch-pinned.

Operator/guest trust filtering is applied once when the runtime context is built (via `CapabilityRegistry.list_for/2`) and baked into the cached profile. Per-message execution-time checks that remain authoritative:

- `state.allowed_tools` allowlist filtering inside `AgentLoop.invoke_capability/3` (per-task scoping, not epoch state).
- Per-capability sandbox/policy enforcement inside each executor (e.g. file path checks, command profile gating).
- Per-capability argument validation inside each executor.

What is **not** re-checked at execution time:

- Whether a capability still exists in `CapabilityRegistry`. The agent dispatches from the cached `state.capabilities_by_name` map (`apps/fermix_core/lib/fermix_core/agent_loop.ex:334`), not the live registry.
- Whether trust/policy filtering for the active profile has changed mid-epoch.

Operational consequence: **to remove a tool safely, restart the server.** A capability removed from the registry mid-epoch remains callable from cached snapshots until `fermix restart`. This is consistent with epoch pinning — the design rejects hot reload — but it is a deliberate trade. If a tool must become uncallable immediately (security incident, deprecation with safety implications, etc.), `fermix restart` is the supported response.

Execution-time live registry checks were considered and rejected: they would re-introduce a per-call lookup cost on the hot path, and would not actually catch the underlying class of bug (a stale executor closure pointing at a dead MCP server pid still "exists" by name in a freshly-registered registry entry). The honest framing is "restart before removal," not "live re-validation."

## 7. Cleanup Required From Current Draft Implementation

The existing code (shipped 2026-05-21 in the first implementation pass) was written against a hot-reload invalidation model. To match this revised design, clean up the parts that add races, unnecessary machinery, or operator-facing surface that is no longer supported.

Each step lists what to change and **why**. Success for the cleanup is simple: an active message task cannot publish a runtime-context snapshot back into `MainAgent`, and the only refresh boundary visible to operators is `fermix restart`.

### 7.1 Remove task-side cache write-back

**Change:** delete the `GenServer.cast(server, {:cache_runtime_context, ctx})` path from `run_message_loop/2` and `cache_runtime_context_async/2` in `apps/fermix_core/lib/fermix_core/agents/main_agent.ex`. Delete the matching `handle_cast({:cache_runtime_context, ctx}, state)` handler. Move the cache build into the GenServer in `handle_cast({:handle_message, msg}, state)` (or an explicit pre-spawn step), so the spawned task always receives an already-populated `runtime_context` in `task_runtime_state/1`.

**Reason:** The current task-side write-back is **not safe** under the existing invalidation model — it can restore a stale snapshot. Concrete race against the code as shipped:

1. Task A spawns with `state.runtime_context = nil` and begins building.
2. While A is still building, an invalidation telemetry event fires; the GenServer processes `handle_cast({:invalidate_runtime_context, _}, state)` (`apps/fermix_core/lib/fermix_core/agents/main_agent.ex:272`) and sets `state.runtime_context = nil`.
3. Task A finishes its build (against the pre-invalidation source state) and casts `{:cache_runtime_context, stale_ctx}`.
4. The `handle_cast({:cache_runtime_context, ctx}, state)` handler (`apps/fermix_core/lib/fermix_core/agents/main_agent.ex:264`) unconditionally writes — there is no generation check — so `state.runtime_context = stale_ctx`. Subsequent tasks now read the stale snapshot indefinitely.

This is precisely why task-side write-back must go. Under the revised design the path is removed outright; under any future design that needs cross-process snapshot publishing, every write must carry a generation token and be rejected when the GenServer generation has advanced.

### 7.2 Delete invalidation telemetry handlers

**Change:** delete `attach_invalidation_handlers/1`, `detach_invalidation_handlers/1`, `capabilities_handler_id/1`, `prompt_files_handler_id/1`, and `__handle_invalidation_telemetry__/4` from `main_agent.ex`. Remove the call to `attach_invalidation_handlers/1` from `init/1`. Delete the `handle_cast({:invalidate_runtime_context, reason}, state)` handler and the `emit_runtime_context_invalidate/2` helper. Drop the `[:fermix, :runtime_context, :invalidate]` telemetry event.

**Reason:** Server-epoch pinning means invalidation does not happen during an epoch. Listening for `[:fermix, :capabilities, :changed]` and `[:fermix, :memory, :prompt_files_rebuilt]` is dead code under this design. Worse, leaving the handlers in place would imply hot-reload semantics the design rejects.

### 7.3 Delete prompt-files rebuild telemetry

**Change:** remove the `:telemetry.execute([:fermix, :memory, :prompt_files_rebuilt], ...)` call and its `emit_rebuilt_telemetry/5` helper from `apps/fermix_core/lib/fermix_core/memory/prompt_files.ex`. Remove the matching test in `apps/fermix_core/test/fermix_core/memory/prompt_files_test.exs`.

**Reason:** This event was added solely so `MainAgent` could invalidate its cache when memory was rebuilt. With invalidation gone (see §7.2), no one consumes it. Existing memory pipeline traces already cover the diagnostic case.

### 7.4 Delete `CapabilityRegistry.revision/1` and `[:fermix, :capabilities, :changed]`

**Change:** remove the revision counter from `apps/fermix_core/lib/fermix_core/capabilities/registry.ex`: the `@revision_key` ETS entry, `revision/1`, `bump_revision/2`, the revision field in GenServer state, and the `[:fermix, :capabilities, :changed]` telemetry execute. Remove the `Enum.reject` for the reserved key from `list/2` (no longer needed). Remove revision-related tests from `apps/fermix_core/test/fermix_core/capabilities/registry_test.exs`.

**Reason:** The revision counter was added to support cache invalidation. The only caller is `RuntimeContext.build/1` for the diagnostic `registry_revision` field. With invalidation gone, no one needs to compare revisions. Keeping the counter just to populate a never-read diagnostic field is dead code.

### 7.5 Drop `registry_revision` from `RuntimeContext`

**Change:** remove the `:registry_revision` field from the `%FermixCore.Agents.RuntimeContext{}` struct, its assignment in `build/1`, and the `runtime_context_revision/1` helper in `main_agent.ex`. Remove the corresponding metadata from `[:fermix, :runtime_context, :build]` telemetry.

**Reason:** Consequence of §7.4 — without a revision counter to compare against, recording a frozen revision number on the snapshot has no purpose.

### 7.6 Delete `MainAgent.reload_skills/1`

**Change:** remove the `reload_skills/1` public function, the `handle_call(:reload_skills, ...)` handler, and the `reload_available_skills/1` and `safe_skill_registry_call/1` helpers (if not used elsewhere) from `main_agent.ex`. Remove the existing test usages in `apps/fermix_core/test/fermix_core/agents/main_agent_test.exs`:

- line 1330 — `test "keeps the skill list static until reload_skills/1 is called"`
- line 1355 — assertion inside the same test
- line 1374 — second usage in that test
- line 1423 — usage in a follow-on test
- line 1448 — usage in a further follow-on test
- line 1875 — `test "reload_skills/1 invalidates the cache"` (added in the first implementation pass; deletable in full)

Either delete each test block or rewrite its premise to demonstrate that `available_skills` is now epoch-pinned and `reload_skills/1` does not exist. The latter only makes sense for the line-1330 test (which becomes "skills stay pinned for the lifetime of MainAgent"); the others have no analog and should be deleted.

Update the following doc references to remove "call `MainAgent.reload_skills`" guidance and direct operators to `fermix restart`:

- `docs/MILESTONE_2_MULTI_AGENT_ORCHESTRATION.md:915-916`
- `docs/MILESTONE_6_DEVELOPER_EXPERIENCE.md:200` (currently lists `fermix reload skills`)
- `docs/MILESTONE_6_DEVELOPER_EXPERIENCE.md:201` (currently lists `fermix reload prompt`)
- `docs/MILESTONE_6_DEVELOPER_EXPERIENCE.md:426` (currently proposes adding `fermix reload skills` plus a dashboard action)
- `docs/wiki/skills.html`
- `docs/wiki/agents.html`

**Reason:** `reload_skills/1` was the in-process refresh path for skill changes. Under server-epoch pinning + single-refresh-boundary policy, it has no role: even if it updated `state.available_skills`, the cached snapshot would still hold the old list and the prompt would not reflect the change. Keeping it would either be dead (no cache effect) or quietly violate the epoch-pinning rule (cache effect = mini-reload back-door). Same reasoning applies to the planned `fermix reload skills` / `fermix reload prompt` surface in MILESTONE_6 — those plans predate the epoch-pinning decision and must be retracted, not just left as future work. Documented public API and roadmap removal: milestone docs, wiki, and tests must all be updated in the same change.

### 7.7 Keep: skill catalog filtering

**Change:** no change. `RuntimeSections.build/2` already derives the skill catalog from the supplied `:capabilities` opt.

**Reason:** Correctness fix. Independent of caching strategy; applies under any policy regime. Without it, a guest profile would advertise skills its trust filter hides.

### 7.8 Keep: explicit `:capabilities` into `AgentLoop.run/1`

**Change:** no change. `run_message_loop/2` already passes `capabilities: profile.capabilities` into `build_loop_runtime/4`.

**Reason:** Avoids redundant `CapabilityRegistry.list_for/2` on every message. The profile already holds the filtered list; reusing it is the point of the cache.

### 7.9 Keep: `/compact` and auto-compaction independence

**Change:** no change. Neither path mutates `state.runtime_context`.

**Reason:** Conversation history and runtime context are orthogonal concerns. Coupling them would re-introduce the multi-purpose command this design rejects.

### 7.10 Keep: provider-specific tool payload caching out of scope

**Change:** no change. `to_provider_tools/1` runs once per provider turn and is reused across continuations by `provider_state`.

**Reason:** A local cache here saves a single microsecond-scale conversion per turn. It does not reduce provider-side payload cost. Not worth the maintenance.

### 7.11 Update telemetry surface

**Change:** retain `[:fermix, :runtime_context, :build]` and `[:fermix, :runtime_context, :cache]` (the latter still reports `:hit | :miss` per turn). Drop `[:fermix, :runtime_context, :invalidate]`. Update the trace handler (`apps/fermix_core/lib/fermix_core/trace/telemetry_handler.ex`) if it referenced any of the removed events.

**Reason:** Cache visibility (build duration, hit ratio) remains useful. Invalidation events are not meaningful under epoch pinning — they would only fire on restart, which is observable through service-level telemetry.

## 8. Failure Behavior

Runtime context build failure should preserve the existing operator-facing behavior: a per-message error reply, not a daemon crash.

If malformed prompt resources are discovered when building the runtime context, `MainAgent` sends an error reply via the failing message's `reply_fn`, logs the cause, and leaves `state.runtime_context` as `nil`. The next inbound message retries the build against current source state. Do not silently continue with a partial prompt.

Boot-time hard failure is not required by this design. A server can start cleanly, then fail the first session/turn that attempts to build invalid runtime context. This matches the pre-cache behavior of `load_prompt_context!` and avoids the deploy-time regression where a malformed `USER.md` would block daemon startup.

## 9. Telemetry

Keep telemetry focused on what remains useful under epoch pinning:

| Event | Purpose |
| --- | --- |
| `[:fermix, :runtime_context, :build]` | Measures the single per-epoch build. Fired once per MainAgent epoch under normal conditions. |
| `[:fermix, :runtime_context, :cache]` | Per-turn cache result (`:hit` after the first message of the epoch). |
| `[:fermix, :agent, :prompt_context]` | Reports prompt context bytes/accounting and whether local composition ran (cache hit ⇒ `duration_us: 0`). |
| `[:fermix, :capabilities, :select]` | Per-turn capability selection. With explicit `:capabilities` passed in, `duration_us` collapses to ~0 — that zero is informative. |
| Provider telemetry | Reports actual provider request size and latency. |

Removed: `[:fermix, :runtime_context, :invalidate]`, `[:fermix, :capabilities, :changed]`, `[:fermix, :memory, :prompt_files_rebuilt]`. Reason: they only existed to drive cache invalidation, which is no longer a runtime concern.

Do not add telemetry events that imply hot reload if hot reload is not supported.

## 10. Voice / Realtime

Voice should not move into the message gateway.

Realtime already has a separate session runtime and explicitly excludes channel tools. It may reuse the same prompt-base/profile builder later, but it should not depend on text-channel gateway state.

Voice follows the same high-level rule: build a session runtime, reuse it across turns, and refresh it at a server restart boundary unless voice defines its own explicit session lifecycle later.

## 11. Non-Goals

- Do not hot-reload prompt/config/source changes into active runtime context.
- Do not reload all markdown files every message.
- Do not couple `/compact` or auto-compaction to runtime-context refresh.
- Do not add a `fermix reload` (or equivalent in-process refresh) command. `fermix restart` is the only refresh boundary.
- Do not extend `fermix doctor` to mutate runtime state. It stays read-only diagnostics.
- Do not keep `MainAgent.reload_skills/1`. Documented public API removal — see §7.6.
- Do not move prompt composition into the message gateway.
- Do not move voice into the message gateway.
- Do not change owner/guest authorization semantics.
- Do not add server-side provider sessions in this slice.
- Do not cache provider-specific tool payloads.
- Do not add a profile dictionary before there is a real multi-profile use case.
- Do not add a `/runtime_context` admin command in this slice.

## 12. Open Questions

1. Should provider-side session reuse become a later milestone after local runtime context is stable?

## 13. Acceptance Criteria

- First turn in an epoch builds runtime context once, inside the `MainAgent` GenServer.
- Later turns in the same epoch do not read prompt markdown files.
- Later turns in the same epoch pass explicit cached capabilities to `AgentLoop.run/1`.
- Spawned message tasks never write runtime context back into `MainAgent`.
- `/compact` and auto-compaction only change conversation history.
- Prompt memory rebuild does not mutate active runtime context.
- Capability registry changes do not mutate active runtime context.
- Skill/MCP/prompt/config source changes are picked up only by `fermix restart` — no in-process reload path remains.
- `MainAgent.reload_skills/1` does not exist as a public API; `fermix reload skills` / `fermix reload prompt` are removed from the MILESTONE_6 roadmap.
- Runtime skill catalog is derived from the filtered capability list for the active profile.
- Per-task execution-time checks remain authoritative for the things that genuinely run per call: `state.allowed_tools`, per-capability executor sandbox/policy enforcement, and argument validation.
- Capability existence and trust filtering are epoch-pinned. Removing a tool requires `fermix restart` to take effect for the running daemon; this is documented in §6 as the operational rule.
- Provider requests remain explicit about instructions and tools; provider prompt caching is treated as an optimization only.
