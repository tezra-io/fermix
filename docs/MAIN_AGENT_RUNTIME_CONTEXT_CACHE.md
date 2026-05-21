# Main Agent Runtime Context Cache

**Status:** Draft
**Date:** 2026-05-19
**Author:** Sujeeth / Aira
**Depends on:** `docs/MILESTONE_4_5_PROMPT_BOOTSTRAP_ARCHITECTURE.md`, `docs/MILESTONE_4_9_UNIFIED_CAPABILITIES.md`, `docs/MESSAGE_GATEWAY_ARCHITECTURE.md`
**Context:** Follow-up improvement after the message gateway work and the first performance telemetry slice. This document intentionally does not change the gateway architecture doc.

---

## 1. Problem / Goal

The message gateway work centralized channel authorization and made remote owner traffic resolve to `:operator`. That fixed the trust path, but it also exposed a separate runtime concern: the main agent still rebuilds prompt context and selects capabilities on every message, then provider adapters rebuild/send tool schemas on every LLM request.

The current cost profile is mostly provider latency, but the runtime should still avoid repeated local work on the hot path. More importantly, the code should have one explicit model for when prompt files, skills, MCP tools, and provider tool payloads are refreshed.

**Goal:** add a warmed, versioned runtime context snapshot owned by `MainAgent`, so stable prompt parts and capability views are built at startup and refreshed only on explicit invalidation boundaries.

This is an improvement to the M4.5 prompt composition and M4.9 capability runtime. It is not a gateway redesign.

### 1.1 Assumptions

- `/compact` should keep its current job: compact active conversation history.
- Prompt markdown files should be reloaded only when their source changes or a refresh is explicitly requested.
- Capability snapshots should be rebuilt only when the capability registry, skill snapshot, or profile inputs change.
- Provider tool schemas can be cached locally, but provider-side payload cost remains until Fermix adopts a server-side provider session or equivalent.
- Auto compaction can be used as a low-priority refresh checkpoint when runtime context is already dirty, but compaction alone does not make prompt files or capabilities stale.

---

## 2. Terminology

| Term | Meaning |
| --- | --- |
| Conversation key | `{channel, chat_id, thread_scope}` used by `ConversationStore`. This is the durable chat history boundary. |
| Provider turn | One `AgentLoop.run/1` invocation for a user message. It can include multiple provider calls if the model calls tools. |
| Runtime context | Prompt base, generated runtime prompt section, selected capabilities, and optional provider tool payloads used to start a provider turn. |
| Runtime profile | The subset of runtime context determined by trust, policy, allowlist, and excluded capability categories. |
| Prompt memory files | `USER.md` and `MEMORY.md`, rebuilt by `PromptFiles.rebuild/4` from durable memory rows. |
| Conversation compaction | Rewriting older conversation history into a compact summary via `Compactor.compact/2`. This is separate from prompt memory file rebuilds. |

When this doc says "new session", it means a new conversation key or a restarted `MainAgent` process. Current provider calls are stateless HTTP requests; `MainAgent` creates a fresh request session id per message today.

---

## 3. Current Behavior

### 3.1 Startup

Application supervision starts the runtime in this order:

1. `CapabilityRegistry`
2. built-in capability seeding
3. command capability seeding
4. `SkillRegistry`
5. `MCP.Supervisor`
6. memory and conversation stores
7. `MainAgent`

At `MainAgent.init/1`, the agent loads `available_skills` from `SkillRegistry.list_detailed/1` and stores that list in GenServer state.

What is warmed today:

- built-in capabilities are registered before `MainAgent`
- skill definitions are loaded by `SkillRegistry`
- skill capabilities are synced into `CapabilityRegistry`
- MCP servers are supervised and register tools after `tools/list`
- `MainAgent.available_skills` is loaded once at init and refreshed by `MainAgent.reload_skills/1`

What is not warmed today:

- composed prompt context
- prompt file contents from `USER.md` / `MEMORY.md`
- generated runtime prompt section
- per-trust filtered capability snapshots
- provider-specific tool payloads

### 3.2 Per Message

For every inbound message that reaches `MainAgent`, `run_message_loop/2` does this:

1. Resolve `conversation_key`.
2. Call `load_prompt_context!/2`.
3. `PromptComposer.compose_with_metadata/1` loads bootstrap prompt files and `PromptFiles.load/1`.
4. `RuntimeSections.build/2` generates the runtime section.
5. Fetch conversation history from `ConversationStore`.
6. Build `messages = prompt_context.messages ++ history ++ [user_message]`.
7. Build the tool execution context, including `:source_trust`.
8. Call `build_loop_runtime/3`.
9. Call `AgentLoop.run/1`.
10. Add the user and assistant messages to `ConversationStore`.
11. Deliver the reply.
12. Start memory extraction if enabled.
13. Maybe run auto compaction.

So prompt files are loaded once per user message today.

### 3.3 Per Provider Turn

`AgentLoop.build_state/1` resolves the provider adapter and selects capabilities.

If `AgentLoop.run/1` is not passed an explicit `:capabilities` list, it calls:

```elixir
CapabilityRegistry.list_for(registry,
  allowed_tools: allowed_tools,
  policy: policy,
  trust: trust,
  excluded_categories: excluded_categories
)
```

That means the selected tool surface is rebuilt once per provider turn today.

### 3.4 Per LLM Invocation

OpenAI Responses and Codex adapters both convert selected capabilities to provider tool schemas:

```elixir
ResponsesShared.to_provider_tools(capabilities)
```

On the first provider call, the adapter sends:

- model
- input/history
- instructions
- tools
- reasoning settings
- text settings

On continuation calls after tool execution, the adapter carries `tools` in `provider_state` and sends the same tool list again with the continued input.

So provider tool maps are built once per provider turn, then resent on each provider continuation in that turn. Fermix does not currently use provider-side stored responses or server-side sessions to avoid resending tool schemas.

### 3.5 `/compact`

`/compact` is implemented by `FermixChannels.Commands.Compact`.

It:

1. Authorizes through command context.
2. Reads a snapshot from `ConversationStore`.
3. Estimates current history tokens.
4. Resolves the provider route.
5. Calls `Compactor.compact/2` with a forced budget.
6. Replaces the conversation history through `ConversationStore.replace_history/3` with `expected_version`.
7. Emits `[:fermix, :compaction, :forced]`.
8. Replies with the before/after token count.

It does not:

- reload `USER.md`
- reload `MEMORY.md`
- rebuild prompt bootstrap files
- reload skills
- refresh MCP tools
- invalidate capability registry state
- rebuild provider tool schemas

This is correct for the current design: `/compact` changes conversation history, not prompt resources.

### 3.6 Auto Compaction

After a successful agent reply, `MainAgent.maybe_auto_compact/3` can compact the same conversation history if the estimated history size crosses the configured threshold.

It:

1. Reads conversation history.
2. Estimates tokens.
3. Compares against model context window and configured threshold.
4. Calls `Compactor.compact/2`.
5. Replaces history through `ConversationStore.replace_history/3`.
6. Emits `[:fermix, :compaction, :auto]`.

It does not refresh prompt files or capabilities.

### 3.7 Prompt Memory Rebuilds

Prompt memory files are rebuilt by `PromptFiles.rebuild/4`, usually through `Memory.Scheduler`.

Triggers include:

- extraction admission requesting an event rebuild
- periodic scheduler ticks
- direct calls in tests or maintenance flows

Prompt memory rebuilds write `USER.md` and `MEMORY.md`. Those files become visible to the agent only the next time `PromptComposer.compose_with_metadata/1` reads them. Because prompt composition happens on every message today, this is eventually visible without explicit notification.

After runtime context caching, prompt memory rebuild must become an explicit invalidation source.

### 3.8 MCP Tool Registration

MCP tools enter the context through the capability registry, not through prompt files.

Flow:

```text
MCP.Supervisor
  -> MCP.Server
  -> tools/list
  -> FermixCore.Capabilities.MCP.Capability.from_tool_descriptor/3
  -> CapabilityRegistry.register/2
  -> AgentLoop capability selection
  -> provider tool schema conversion
```

MCP capabilities default to:

- `kind: :mcp`
- `policy_class: :external_api`
- `hidden_from_agent?: false`

Operator turns can see them under the default `:operator` policy. Guest turns cannot see them unless policy is explicitly widened.

---

## 4. Constraints

1. Trust filtering remains authoritative. A cache must never widen a guest surface because an operator snapshot exists.
2. Runtime context must be versioned. Callers need to know which prompt and capability revision was used.
3. Conversation compaction and prompt memory rebuild are separate. Do not merge them into one concept.
4. Startup should warm the main agent's default runtime context.
5. New conversation keys should not reload static prompt files or capabilities unless a source changed.
6. Provider requests are still stateless today. Local caching can reduce CPU and file I/O, but it cannot remove provider-side token/tool payload cost unless provider session reuse is added later.
7. Voice sessions are separate. Realtime already builds prompt context with `runtime_capabilities: state.capabilities` and excludes channel tools. It can reuse the same cache builder later, but it should not depend on the text-channel gateway.

---

## 5. Proposed Architecture

Add a small `FermixCore.Agents.RuntimeContext` module owned by `MainAgent`.

`RuntimeContext` should build and hold:

- base prompt parts loaded from bootstrap files and prompt memory files
- prompt accounting
- available skills snapshot
- filtered capability snapshots by runtime profile
- generated runtime prompt sections by runtime profile
- optional provider tool payload snapshots by provider adapter and runtime profile
- source revisions used to build the snapshot

The main agent should use the snapshot on the hot path. Rebuilds happen only through explicit invalidation.

### 5.1 Shape

Suggested struct:

```elixir
defmodule FermixCore.Agents.RuntimeContext do
  defstruct [
    :agent_id,
    :owner_id,
    :revision,
    :built_at_ms,
    :source_versions,
    :base_messages,
    :base_accounting,
    :available_skills,
    :profiles
  ]
end
```

Each profile entry:

```elixir
%{
  key: profile_key,
  trust: :operator | :guest | nil,
  policy: policy,
  allowed_tools: allowed_tools,
  excluded_categories: excluded_categories,
  capabilities: capabilities,
  runtime_message: %{role: "system", content: runtime_section},
  accounting: accounting
}
```

The full prompt for a message becomes:

```elixir
profile = RuntimeContext.fetch_profile!(ctx, profile_key)
prompt_messages = ctx.base_messages ++ [profile.runtime_message]
messages = prompt_messages ++ history ++ [user_message]
```

This avoids duplicating static prompt text across trust profiles while still making the runtime section match the actual capability surface for that turn.

### 5.2 Runtime Profile Key

The cache key should include only inputs that change tool visibility:

```elixir
{
  trust,
  normalized_policy,
  normalized_allowed_tools,
  normalized_excluded_categories
}
```

For current text turns, the important profiles are:

- operator text profile: `trust: :operator`
- guest text profile: `trust: :guest`
- voice profile: `trust: :operator, excluded_categories: [:channel]`
- skill sub-agent profile: derived from skill trust and allowed tools

Channel name should not be part of the key unless channel-specific tool visibility is introduced later.

### 5.3 Prompt Base vs Runtime Section

`PromptComposer` currently builds both file-backed prompt parts and generated runtime parts in one call. For caching, split the responsibility:

1. `PromptComposer.compose_base_with_metadata/1`
   - loads bootstrap files
   - loads `USER.md` / `MEMORY.md`
   - returns base system messages and accounting

2. `RuntimeSections.build/2`
   - receives the exact filtered capabilities for the profile
   - receives the available skills snapshot
   - returns the generated runtime section

3. `PromptComposer.compose_with_metadata/1`
   - remains as a compatibility wrapper for tests and realtime until callers are migrated

This makes the cache boundary explicit and keeps generated runtime state out of the file-backed prompt cache.

### 5.4 Capability Selection

`RuntimeContext` should call `CapabilityRegistry.list_for/2` while building each profile.

`AgentLoop.run/1` should receive the selected `capabilities:` list explicitly from `MainAgent`. It already supports this path. When a capabilities list is passed, `AgentLoop` skips registry selection and only indexes the list by name.

That makes per-message capability selection a cache hit instead of an ETS scan/filter.

### 5.5 Provider Tool Payloads

Provider tool payloads are adapter-specific. The first implementation can cache capability structs only.

Optional second step:

```elixir
%{
  provider_tool_payloads: %{
    {adapter_module, profile_key, capability_revision} => tools
  }
}
```

This avoids repeated `ResponsesShared.to_provider_tools/1` work, but it does not avoid sending tools to the provider on each stateless request. Treat this as a local CPU/cache optimization only.

---

## 6. Invalidation Model

Runtime context should rebuild on source changes, not on every message.

| Source | Current behavior | New behavior |
| --- | --- | --- |
| Process start | MainAgent loads available skills only | Build initial runtime context before accepting turns |
| `/compact` | Replaces conversation history | No runtime context rebuild unless a prompt/capability source is already dirty |
| Auto compaction | Replaces conversation history after reply | No runtime context rebuild unless a prompt/capability source is already dirty |
| `PromptFiles.rebuild/4` | Next message sees new files because prompt is reloaded every message | Emit/call runtime invalidation for `:prompt_memory` |
| `MainAgent.reload_skills/1` | Reloads skills and updates `available_skills` | Reload skills, then rebuild runtime context profiles |
| MCP server tools discovered | Registers capabilities | Increment capability registry revision and invalidate capability profiles |
| MCP server disconnected | Unregisters server tools | Increment capability registry revision and invalidate capability profiles |
| Built-in/command capability changes | Boot-time only today | Revision changes if dynamic refresh is added |
| Provider route/model changes | Requires daemon restart today | Startup rebuild is enough until live config reload exists |

### 6.1 `/compact` Boundary

`/compact` should remain a history operation. It should not rebuild runtime context by default.

If the product wants `/compact` to be a convenient refresh checkpoint, the rule should be:

1. Run conversation compaction.
2. Check runtime context dirty flags.
3. Rebuild only dirty sources.
4. Return compaction result plus refresh status.

Do not make `/compact` reload prompt files unconditionally. That would reintroduce slow local work on a command whose main job is conversation history compaction.

### 6.2 Auto Compaction Boundary

Auto compaction should not block replies on runtime context rebuild. It runs after reply delivery today and should stay outside the user-visible response path.

Recommended behavior:

- if runtime context is clean, auto compaction only replaces history
- if runtime context is dirty, auto compaction can schedule an async rebuild after history replacement
- if async rebuild fails, keep the last good runtime context and log/telemetry the failure

### 6.3 Prompt Memory Rebuild Boundary

`Memory.Scheduler` should notify `MainAgent` after a successful `PromptFiles.rebuild/4`.

Recommended API:

```elixir
MainAgent.invalidate_runtime_context(:prompt_memory, agent_id: agent_id)
```

The invalidation should be cheap. Rebuild can be:

- synchronous for explicit user/admin commands
- asynchronous for extraction and periodic scheduler paths

### 6.4 Capability Registry Revision

`CapabilityRegistry` currently stores capabilities in ETS and serializes writes through the GenServer. Add a revision counter to the GenServer state.

Write operations that change the table increment the revision:

- successful `register/2`
- `unregister/2`
- `unregister_kind/3`
- future real `refresh/2`

Expose:

```elixir
CapabilityRegistry.revision(server)
```

`RuntimeContext` stores the revision used to build capability profiles. A mismatch marks those profiles dirty.

---

## 7. MainAgent Hot Path After Change

Per message should become:

1. Resolve `conversation_key`.
2. Resolve runtime profile from `source_trust`, policy, allowlist, and exclusions.
3. Fetch warmed runtime profile from `state.runtime_context`.
4. Fetch conversation history.
5. Build messages from cached prompt base, cached runtime section, history, and current user message.
6. Call `AgentLoop.run/1` with explicit `capabilities: profile.capabilities`.
7. Persist user and assistant messages.
8. Deliver reply.
9. Start extraction.
10. Maybe auto compact conversation history.

No prompt files or capability registry scans should happen on the clean hot path.

---

## 8. Failure Behavior

### 8.1 Startup

Startup should fail loud if the initial runtime context cannot be built. This matches the current behavior where `load_prompt_context!/2` raises on prompt composition failure, but moves the failure to boot instead of first user message.

### 8.2 Async Refresh

If an async refresh fails:

- keep the last good runtime context
- mark the context stale
- emit telemetry with the reason
- log an error
- retry only on the next explicit invalidation or bounded scheduled refresh

Do not drop to an empty operator profile. An empty profile can hide tools and produce misleading "I do not have access" replies.

### 8.3 Missing Profile

If a message needs a profile that is not cached:

1. Build that profile synchronously from the current runtime context sources.
2. If build succeeds, store it and continue.
3. If build fails, return an agent error and do not widen to another trust profile.

Never reuse an operator profile for a guest message.

---

## 9. Telemetry

The first telemetry slice already added measurement around:

- prompt context composition
- conversation history fetch
- capability selection
- provider request payload shape
- reply delivery

Add runtime context telemetry:

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:fermix, :runtime_context, :build]` | `duration_us`, `base_message_bytes`, `profile_count`, `capabilities_count` | `agent`, `revision`, `reason`, `status` |
| `[:fermix, :runtime_context, :invalidate]` | `count` | `agent`, `reason`, `old_revision` |
| `[:fermix, :runtime_context, :profile_build]` | `duration_us`, `capabilities_count`, `runtime_message_bytes` | `agent`, `profile_key`, `trust`, `policy` |
| `[:fermix, :runtime_context, :cache]` | `count` | `agent`, `profile_key`, `result: :hit | :miss | :stale` |

Success criteria:

- clean hot-path prompt composition duration is zero because composition does not run
- clean hot-path capability selection duration is zero because `AgentLoop` receives capabilities
- provider telemetry still reports the actual tools and input bytes sent to the provider

---

## 10. Voice / Realtime

Voice should not move into the message gateway.

Realtime already has a separate session runtime and explicitly excludes channel tools:

```elixir
CapabilityRegistry.list_for(CapabilityRegistry,
  trust: :operator,
  excluded_categories: [:channel]
)
```

The useful shared piece is the runtime context builder:

- text channels use operator/guest text profiles
- voice uses operator voice profile with channel tools excluded
- both can share prompt base loading and capability profile building

Do not make voice depend on Telegram/Discord/Slack gateway state. Voice is click-to-talk operator input, not channel ingress.

---

## 11. Implementation Plan

### Stage 1: Source Revisions

Step: add `CapabilityRegistry.revision/1` and increment it on table-changing writes.

Verify:

- registry tests prove revision increments on register/unregister/unregister_kind
- read-only `list/2` and `find/2` do not increment revision

### Stage 2: Runtime Context Builder

Step: add `FermixCore.Agents.RuntimeContext` with base prompt build and profile build.

Verify:

- base prompt loads bootstrap plus `USER.md` / `MEMORY.md`
- profile runtime section uses the exact filtered capabilities
- guest profile excludes non-read-only capability classes
- voice profile excludes `:channel`

### Stage 3: MainAgent Warmup

Step: build runtime context in `MainAgent.init/1` after `available_skills` is loaded.

Verify:

- startup fails if prompt composition fails
- `MainAgent.status/1` includes runtime context revision and stale flag
- no inbound message is processed before warmup succeeds

### Stage 4: MainAgent Hot Path

Step: change `run_message_loop/2` to read cached prompt/profile data and pass `capabilities:` into `AgentLoop.run/1`.

Verify:

- focused test proves `PromptComposer.compose_with_metadata/1` is not called per message on clean cache
- focused test proves `CapabilityRegistry.list_for/2` is not called inside `AgentLoop` when capabilities are passed
- telemetry records runtime context cache hit

### Stage 5: Invalidation Hooks

Step: wire invalidation from:

- `MainAgent.reload_skills/1`
- successful `PromptFiles.rebuild/4` through `Memory.Scheduler`
- MCP capability registration/unregistration through registry revision checks
- explicit admin command if added later

Verify:

- prompt memory rebuild invalidates prompt base
- skill reload invalidates skill catalog and skill capabilities
- MCP registration invalidates capability profiles
- `/compact` does not rebuild runtime context unless dirty

### Stage 6: Optional Provider Tool Payload Cache

Step: cache adapter-specific provider tool maps by `{adapter, profile_key, capability_revision}`.

Verify:

- provider tool map conversion is skipped on clean cache
- request telemetry still reports the actual sent tools
- cache is invalidated when capability revision changes

---

## 12. Non-Goals

- Do not move prompt composition into the message gateway.
- Do not move voice into the message gateway.
- Do not change owner/guest authorization semantics.
- Do not add server-side provider sessions in this slice.
- Do not change `/compact` into prompt memory rebuild.
- Do not reload all markdown files every message.
- Do not hide provider latency behind local cache metrics; provider telemetry remains the source of truth for LLM time.

---

## 13. Open Questions

1. Should the runtime prompt list all visible MCP tools, or should it summarize MCP servers while the full tool schema carries exact tool detail?
2. Should periodic prompt memory rebuild push invalidation directly to `MainAgent`, or should `MainAgent` poll source revisions on a bounded interval?
3. Should admin commands expose `/context_status` or `/runtime_context` so the owner can inspect revisions, stale state, profile count, and prompt/tool byte sizes?
4. Should provider-side session reuse be a later milestone for OpenAI Responses/Codex once local caching is clean?

---

## 14. Acceptance Criteria

- `MainAgent` builds a runtime context snapshot at startup.
- Clean text-channel turns do not read prompt markdown files.
- Clean text-channel turns pass explicit capabilities to `AgentLoop`.
- Operator and guest profiles are cached separately.
- Guest cache misses never fall back to operator profiles.
- `/compact` still compacts only conversation history.
- Prompt memory rebuild invalidates cached prompt base.
- Skill reload invalidates cached skill/runtime sections.
- MCP tool registration changes invalidate cached capability profiles.
- Telemetry can show whether latency is local runtime work, provider request size, or provider response time.
