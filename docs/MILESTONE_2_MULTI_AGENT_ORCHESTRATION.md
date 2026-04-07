# Milestone 2: Multi-Agent Orchestration — Functional Design

**Status:** Draft
**Date:** 2026-04-06
**Author:** Sujeeth / Aira
**Depends on:** Phase 1 (shipped)
**References:** `docs/ROADMAP.md` (M2 section), RustyClaw `MAIN_AGENT_DESIGN.md`, `OPTION_B_ORCHESTRATION_DESIGN.md`

---

## 1. Problem / Goal

Fermix today is a single-agent system. One MainAgent GenServer handles every inbound message, runs the same agent loop with the same system prompt and the same tools, regardless of what the user asked for. There is no way to:

- Delegate specialized work (coding, research, summarization) to a purpose-built sub-agent
- Run safe parallel tasks when repo state and mutation boundaries allow it
- Scope tool access per task (a research agent shouldn't have `shell`)
- Isolate memory/state between concurrent tasks
- Track provenance of who did what across a delegation chain

**Milestone 2 introduces hub-and-spoke orchestration:** one persistent Main Agent that recognizes what needs to be done and delegates to ephemeral skill agents that execute, return results, and die. This is the foundation every later milestone builds on — channels route to Main Agent, skills use memory, security gates tool access, and the dashboard monitors it all.

---

## 2. Scope and Non-Goals

### In Scope (P0 + P1 from roadmap)

| Feature | Priority | Type |
|---------|----------|------|
| AgentServer GenServer with lifecycle, parent/child tracking, state for delegated skill workers | P0 | Port |
| AgentSupervisor DynamicSupervisor for `:temporary` skill workers; MainAgent remains under Application supervision | P0 | Port |
| AgentDefinition struct with `role: :main \| :sub`, capabilities, model, tool ACL | P0 | Port |
| AgentCoordinator capability matching + delegation ACL | P1 | Port |
| Main Agent lifecycle: enhance existing persistent MainAgent with delegation hooks; it remains channel-facing while delegating to AgentServer-backed skills | P0 | Hybrid |
| Skill templates: YAML+MD files loaded from `~/.fermix/skills/` | P0 | New |
| SkillRegistry: filesystem loader with validation | P0 | New |
| `invoke_skill` tool: Main Agent spawns ephemeral skill agents | P0 | New |
| Skill journals: Markdown per-instance in `~/.fermix/journals/` | P1 | New |
| Parallel skill execution policy + safe fanout with supervision | P1 | New |
| Repo isolation boundary contract for same-repo mutating work (`git worktree` or remote execution) | P1 | New |

### Non-Goals (explicitly deferred)

| Feature | Reason | Milestone |
|---------|--------|-----------|
| Shared-checkout same-repo parallel code writing | Explicitly forbidden until repo isolation exists | Not allowed in M2 |
| ResourceLock (priority-based ETS locking) | P2, no parallel contention yet | M2 future |
| Automatic merge/reconcile flow for isolated parallel coding branches | Useful after repo isolation exists | M2 future |
| BtwRouter (`/btw` side-channel) | P2, convenience feature | M2 future |
| MessageProvenance (trace chains) | P2, useful but not blocking | M2 future |
| TraceStore (ETS-backed distributed tracing) | P2, current file tracing sufficient | M2 future |
| Multiple providers per agent | Requires provider registry (M8+ scope) | Later |
| Memory isolation between agents | Requires advanced memory (M4) | M4 |
| Formal security policy and audit logging on tool access | Requires security milestone | M5 |
| Cron-triggered skill invocation | Requires cron scheduler | M6 |

---

## 3. Current State / Assumptions

### What exists today (Phase 1, shipped)

```
FermixCore.Application supervisor (:rest_for_one)
  ├── Task.Supervisor (FermixCore.TaskSupervisor)
  ├── Trace (JSONL writer)
  ├── [conditional] TokenManager (OAuth)
  ├── Tools.Registry (GenServer, 6 tools registered)
  ├── Memory.ConversationStore (GenServer, per-chat history in memory)
  ├── Memory.Store (GenServer, ETS-backed fact storage)
  └── Agents.MainAgent (GenServer, one instance, :permanent)
```

**Message flow today:**
```
Telegram webhook → WebhookController → Telegram.parse_webhook()
  → MainAgent.handle_message() (cast)
  → Task.Supervisor spawns task
  → ConversationStore.get_history() → build messages
  → AgentLoop.run() with single provider (OpenAI)
  → reply_fn.(response) → Telegram.send_message()
```

**Key facts:**
- MainAgent is a plain GenServer started by name in the supervision tree
- AgentLoop.run/1 accepts `messages`, `tools`, `provider`, `context`, `registry` — already parameterized
- Tools are registered at startup via `Registry.register/1`, looked up by name
- Provider is hardcoded to `FermixCore.Providers.OpenAI` in MainAgent.init
- ConversationStore keys by `{channel, chat_id}` — single-tenant
- System prompt is hardcoded string in MainAgent
- No agent-level configuration, no per-agent tool filtering

### Ownership decision for M2

**Decision:** `FermixCore.Agents.MainAgent` remains the channel-facing GenServer for M2. `AgentServer` is introduced for spawned skill-worker lifecycle, not as the process that directly receives inbound channel messages.

**Why this fits the current repo:**
- `MainAgent` already exists as a standalone GenServer started directly by `FermixCore.Application`.
- `MainAgent.handle_message/2` already owns the channel-facing contract: `reply_fn`, per-chat `ConversationStore` lookup, and non-blocking `Task.Supervisor` execution.
- Existing tests in `apps/fermix_core/test/fermix_core/agents/main_agent_test.exs` and `apps/fermix_web/test/fermix_web_web/integration_test.exs` already exercise that channel-facing contract.

**Ownership boundary in M2:**
- `MainAgent` owns channel ingress, conversation assembly, reply delivery, and top-level orchestration decisions.
- The per-message task spawned by `MainAgent` owns the blocking wait for delegated skill results inside `AgentLoop.run/1`.
- `AgentSupervisor` owns spawned `AgentServer` processes.
- `AgentServer` owns delegated skill execution lifecycle once a skill has been spawned.
- `AgentServer` does **not** become the channel ingress or reply-delivery process in M2.
- `FermixCore.Application` keeps starting `MainAgent` directly; it adds `AgentSupervisor` as a sibling child rather than replacing `MainAgent`.
- Existing MainAgent/webhook tests stay anchored on `MainAgent.handle_message/2`; new M2 coverage expands around `AgentSupervisor`, `AgentServer`, `invoke_skill`, and message-flow regressions across that boundary.

### Assumptions

1. **Single user.** Fermix serves one person. Multi-tenancy is not in scope.
2. **One Main Agent.** All channels route to the same Main Agent instance.
3. **OpenAI is the only provider.** Sub-agents will also use OpenAI until provider registry exists.
4. **SQLite not yet available.** Memory is ETS + in-memory. M4 adds persistence.
5. **No formal security policy/audit yet.** Skill-agent `allowed_tools` are enforced at runtime in M2, but broader policy evaluation and audit logging remain M5 work.
6. **Skills directory must exist.** `~/.fermix/skills/` and `~/.fermix/journals/` created at startup if missing.

---

## 4. User and System Flows

### Flow 1: Direct response (no delegation)

User sends a simple question. Main Agent answers directly without invoking any skill.

```
User: "What time is it in Tokyo?"

Telegram → WebhookController → MainAgent.handle_message()
  → AgentLoop.run()
  → LLM responds directly (no tool calls, no skill invocation)
  → reply_fn → Telegram
```

**No change from Phase 1.** Main Agent handles simple queries itself. The LLM decides whether to delegate — it's not forced.

### Flow 2: Single skill delegation

User asks for something that requires specialized work. Main Agent recognizes this and invokes a skill.

```
User: "Fix the failing test in fermix_core/config_test.exs"

Telegram → MainAgent.handle_message()
  → AgentLoop.run()
  → LLM calls invoke_skill tool:
      {name: "coding-skill", task: "Fix failing test in config_test.exs",
       context: "Test error: ..."}
  → invoke_skill tool executes:
      1. SkillRegistry.load("coding-skill") → AgentDefinition
      2. AgentSupervisor.spawn_agent(definition, parent: request_task_pid)
      3. AgentServer starts as :temporary child
      4. AgentServer.run_task(task, context)
         → Builds skill-specific system prompt from template
         → AgentLoop.run() with skill's allowed_tools + model
         → Skill executes: reads file, edits code, runs tests
         → Returns result summary
      5. Skill agent process exits normally
      6. Journal written to ~/.fermix/journals/coding-skill/<timestamp>.md
  → invoke_skill returns result to Main Agent's loop
  → Main Agent summarizes result to user
  → reply_fn → Telegram
```

**Key behaviors:**
- The Main Agent-owned request task pauses while waiting for skill result (synchronous from the LLM's perspective)
- Skill gets its own AgentLoop.run() with its own tools, system prompt, and iteration budget
- Skill has no direct access to user's channel — it returns text to Main Agent
- Main Agent decides how to present the result (may summarize, may pass through)

### Flow 3: Safe parallel skill execution

User asks for work that can be parallelized safely. Main Agent invokes multiple skills concurrently only when repo isolation and mutation rules allow it.

```
User: "Review the auth refactor in fermix and update the README in the docs repo"

MainAgent → AgentLoop.run()
  → LLM calls invoke_skill with parallel: true (or multiple invoke_skill calls):
      Skill A: review-skill, task: "Review auth refactor in fermix"
      Skill B: coding-skill, task: "Update README in docs repo"
  → Both spawned under AgentSupervisor
  → Both run concurrently via separate AgentServer processes
  → Results collected as they complete
  → Main Agent combines results for user
  → reply_fn → Telegram
```

**Concurrency model:**
- Each skill is its own OTP process with its own state
- AgentSupervisor tracks all children
- The in-flight request task / `invoke_skill` call monitors spawned skill pids and collects results
- If one fails, the other continues (independent supervision)
- Results returned to Main Agent's request task in completion order
- Same-repo mutating tasks are never spawned in parallel from the same checkout; they require a per-skill isolation boundary or must run sequentially

### Flow 4: Skill failure and recovery

A skill agent crashes or times out. Main Agent handles the failure.

```
Skill "coding-skill" crashes during execution
  → AgentServer process exits with reason
  → AgentSupervisor does NOT restart (:temporary)
  → invoke_skill monitor receives {:DOWN, ref, :process, pid, reason}
  → invoke_skill tool returns {:error, reason} to agent loop
  → LLM sees error, decides: retry? report to user? try different approach?
  → Main Agent communicates outcome to user
```

**No automatic retry.** The LLM (Main Agent) decides whether to retry, try a different skill, or report the failure. This keeps the orchestration logic in the LLM, not in Elixir code.

---

## 5. Core Components and Responsibilities

### 5.1 AgentDefinition

**Responsibility:** Immutable description of an agent's identity, capabilities, and constraints.

```
Fields:
  name          :: String.t()               # unique identifier
  role          :: :main | :sub             # NEW: distinguishes orchestrator from worker
  persistent    :: boolean()                # :permanent vs :temporary restart
  system_prompt :: String.t()               # template body (Markdown)
  model         :: String.t() | nil         # LLM model override (nil = use default)
  temperature   :: float() | nil            # LLM temperature override
  capabilities  :: [String.t()]             # what this agent can do (for matching)
  allowed_tools :: [String.t()]             # tool names this agent may use
  max_iterations :: pos_integer()           # agent loop iteration budget (default 25)
  parent        :: String.t() | nil         # parent agent name (nil for Main Agent)
  delegates_to  :: [String.t()]             # which skills it can invoke ([] = any)
```

**Sources:**
- Main Agent definition: hardcoded in application config (one instance)
- Skill definitions: loaded from `~/.fermix/skills/<name>/SKILL.md` YAML frontmatter + Markdown body

**Invariants:**
- `role: :main` implies `persistent: true`
- `role: :sub` implies `persistent: false`
- `name` must match `[a-zA-Z0-9_-]+`
- `allowed_tools` must be a subset of registered tool names (warning if not, not error — tools may not be loaded yet)

### 5.2 AgentServer

**Responsibility:** GenServer that manages the lifecycle of a spawned skill agent instance. Holds state, runs tasks, tracks children, emits telemetry.

```
State:
  definition       :: AgentDefinition.t()
  session_id       :: String.t()            # unique per invocation (UUID)
  status           :: :initializing | :idle | :running | :stopping
  parent_pid       :: pid() | nil
  child_pids       :: MapSet.t(pid())       # monitored child agent pids
  started_at       :: DateTime.t()
  last_active_at   :: DateTime.t()
  accumulated_state :: map()                # arbitrary K/V (gist injection in M4)
  pending_task     :: {reference(), Task.t()} | nil
```

**Callbacks:**
- `start_link(definition, opts)` — starts GenServer
- `run_task(server, task, context)` — runs AgentLoop in a monitored Task
- `get_status(server)` — returns current status + session_id
- `stop(server, reason)` — graceful shutdown

**Key behaviors:**
- Monitors parent_pid — if parent dies, sub-agent stops itself
- Monitors child_pids — tracks spawned sub-agents
- Status transitions: `:initializing` → `:idle` → `:running` → `:idle` (loop) or → `:stopping`
- Only one `run_task` at a time per agent (rejects if already `:running`)
- In M2, AgentServer is used for skill workers. Persistent-agent snapshot/restore is deferred.

### 5.3 AgentSupervisor

**Responsibility:** DynamicSupervisor that spawns and manages AgentServer processes.

**API:**
- `spawn_agent(definition, opts)` — starts AgentServer as child
  - `opts[:parent]` — parent pid for monitoring
  - Restart strategy from `definition.persistent`
- `stop_agent(name_or_pid, reason)` — terminates a specific agent
- `list_agents()` — returns `[{name, pid, status}]` for all children
- `find_agent(name)` — returns pid for named agent, or nil

**Supervision strategy:**
- `:one_for_one` — agents are independent
- Ephemeral skills: `:temporary` restart (never restarted)
- Persistent MainAgent remains a direct `FermixCore.Application` child in M2

### 5.4 SkillRegistry

**Responsibility:** Loads, validates, and caches skill template definitions from the filesystem.

**Source directory:** `~/.fermix/skills/`

**Template format:**
```yaml
# ~/.fermix/skills/coding-skill/SKILL.md
---
name: coding-skill
model: gpt-5.4-mini
capabilities: ["code", "shell", "file_operations"]
allowed_tools: ["shell", "file_read", "file_write", "file_edit"]
max_iterations: 30
---
You are a coding agent. You receive a precise task, execute it thoroughly
using the available tools, and return a clear summary of what you did
and what changed.

Always verify your work by running relevant tests before returning.
```

**API:**
- `load(skill_name)` — returns `{:ok, AgentDefinition.t()}` or `{:error, reason}`
- `list()` — returns sorted list of available skill names
- `list_detailed()` — returns `[AgentDefinition.t()]` with full definitions
- `reload()` — clears cache, re-reads filesystem

**Behaviors:**
- Reads YAML frontmatter, parses into AgentDefinition with `role: :sub`, `persistent: false`
- Markdown body becomes `system_prompt`
- Validates name format, required fields
- Caches parsed definitions (invalidated on `reload()`)
- Creates `~/.fermix/skills/` directory at startup if missing
- Ships with 2-3 built-in skill templates (see section 5.8)

### 5.5 invoke_skill Tool

**Responsibility:** LLM-callable tool that the Main Agent uses to delegate work to a skill agent.

**Tool schema (presented to LLM):**
```json
{
  "name": "invoke_skill",
  "description": "Delegate a task to a specialized skill agent. The skill runs independently with its own tools and returns a result summary.",
  "parameters": {
    "type": "object",
    "properties": {
      "skill": {
        "type": "string",
        "description": "Name of the skill to invoke (e.g., 'coding-skill', 'research-skill')"
      },
      "task": {
        "type": "string",
        "description": "Clear description of the task for the skill agent to perform"
      },
      "context": {
        "type": "string",
        "description": "Additional context the skill needs (file paths, error messages, etc.)"
      }
    },
    "required": ["skill", "task"]
  }
}
```

**Execution flow:**
1. Validate `skill` name exists in SkillRegistry
2. Load AgentDefinition for the skill
3. Filter tools: only `allowed_tools` from the Tool Registry
4. Spawn AgentServer via AgentSupervisor with `parent: caller_pid`
5. Call `AgentServer.run_task/3` with the task + context
6. Wait for result (with timeout, default 5 minutes)
7. Write journal entry
8. Return result to calling agent loop

**Return value (to LLM):**
```
{success: true, output: "Skill 'coding-skill' completed:\n<result summary>"}
```
or
```
{success: false, output: "Skill 'coding-skill' failed: <reason>", error: "<reason>"}
```

**The invoke_skill tool is registered like any other tool** — Main Agent sees it alongside `shell`, `file_read`, etc. The LLM decides when to use it.

**Runtime note:** In the current repo architecture, `MainAgent` runs each inbound message inside a `Task.Supervisor` child. That request task is therefore the `caller_pid` that synchronously waits on `invoke_skill`, monitors the spawned skill worker, and hands the final result back to the `MainAgent` reply path.

### 5.6 Skill Journals

**Responsibility:** Persistent Markdown record of each skill invocation. Provides auditability and context for future runs.

**Directory:** `~/.fermix/journals/<skill-name>/`

**File naming:** `<YYYY-MM-DD>_<HH-MM-SS>_<task-slug>.md`

**Format:**
```markdown
# coding-skill — Fix failing config test

**Date:** 2026-04-06T14:30:00Z
**Session:** a1b2c3d4-e5f6
**Invoked by:** main-agent
**Duration:** 45s
**Status:** completed
**Iterations:** 8

## Task
Fix the failing test in fermix_core/config_test.exs

## Context
Test error: (MatchError) no match of right hand side value: {:error, :not_configured}

## Execution Summary
1. Read config_test.exs — found test expecting :openai config
2. Read config.exs — config key is :providers, not :openai
3. Edited config_test.exs to use correct config path
4. Ran mix test — all passing

## Files Changed
- apps/fermix_core/test/fermix_core/config_test.exs (+3, -2)

## Result
Fixed 1 test failure. Root cause: test used wrong config key path.
```

**Written by:** invoke_skill tool after skill agent completes (or fails). Journal captures what happened regardless of outcome.

### 5.7 AgentCoordinator (P1)

**Responsibility:** Matches required capabilities to available skills. Enforces delegation ACL.

**API:**
- `find_matching_skills(required_capabilities)` — returns skills whose `capabilities` superset matches
- `can_delegate?(from_agent, to_skill)` — checks `delegates_to` ACL
- `resolve(required_capabilities, strategy)` — returns best match per strategy

**Strategies:**
- `:first_match` — return first skill with all required capabilities (default)
- `:all_matches` — return all matching skills (for safe parallel fanout, subject to the repo isolation policy)

**Usage:** The invoke_skill tool can optionally use AgentCoordinator to auto-select a skill based on capabilities rather than requiring the LLM to name a specific skill. This is additive — explicit skill naming always works.

### 5.8 Built-in Skill Templates

Ship with these templates to make M2 immediately useful:

**coding-skill:**
- Capabilities: `["code", "shell", "file_operations"]`
- Tools: `["shell", "file_read", "file_write"]`
- System prompt: focused on code changes, testing, returning diffs

**research-skill:**
- Capabilities: `["research", "web"]`
- Tools: `["browser", "file_write"]`
- System prompt: focused on web research, summarization, saving findings

**review-skill:**
- Capabilities: `["code", "review"]`
- Tools: `["shell", "file_read"]`
- System prompt: focused on code review, finding issues, no modifications

### 5.9 Parallel Skill Safety Policy

Parallel execution is **not** a blanket permission in M2. Before spawning multiple skills, the coordinator or caller must classify each task by:

- Whether it mutates state or is read-only
- Which repo or workspace it targets
- Whether the target repo is already isolated from sibling workers

This policy follows the same grouping principle as RustyClaw's batch processor: different repos can fan out, same-repo tasks stay sequential unless an explicit worktree strategy is active.

| Case | Allowed in parallel? | Requirement |
|------|----------------------|-------------|
| Different repos, mutating or read-only | Yes | Each skill works against its own repo root; no shared checkout writes |
| No repo / external-only work (research, summarization, API inspection) | Yes | Normal task isolation only |
| Same repo, all read-only tasks | Yes | All tasks run against the same pinned snapshot/HEAD and do not write |
| Same repo, one mutating task plus one review/read-only task | Only with isolation | The read-only task must use its own snapshot or isolated checkout; otherwise its output can be invalidated by concurrent writes |
| Same repo, multiple mutating tasks | No in a shared checkout | Allowed only when every mutating skill has its own isolated repo boundary |
| Repo overlap is unknown or file ownership is ambiguous | No | Treat as unsafe and serialize until isolation is explicit |

**Required isolation strategy for same-repo mutating fanout:**

- Preferred local strategy: create a dedicated `git worktree` per mutating skill, on its own branch, and reconcile results afterward
- Acceptable alternative: dispatch the skill to a remote execution boundary (container, VM, or remote worker) that gives it an independent checkout and returns a patch, branch, or artifact for merge/review
- Without one of those boundaries, same-repo mutating tasks must be serialized or rejected with an explicit reason

**Implications for review output:**

- Review, audit, and summarization skills are only trustworthy when they read a stable snapshot
- A review running against a moving shared checkout is unsafe, even if the reviewer itself is read-only
- If a mutating sibling is active in the same repo and no snapshot boundary exists, the review must wait or run in its own isolated checkout

---

## 6. State / Lifecycle Model

### Main Agent Lifecycle

```
Application start
  │
  ├── AgentSupervisor starts (empty, no children)
  │
  └── MainAgent starts as standalone GenServer (:permanent)
      │
      ├── Receives handle_message() cast from channels
      ├── Spawns Task.Supervisor task for AgentLoop.run()
      ├── Builds messages from system prompt + ConversationStore history + user input
      ├── AgentLoop may call invoke_skill
      │   └── invoke_skill spawns child AgentServer (:temporary)
      ├── Request task collects skill results
      └── Sends final response via reply_fn
```

**Main Agent is always running.** In M2 it remains the stable, channel-facing entrypoint. It keeps ownership of `handle_message/2`, `reply_fn`, and `ConversationStore` access, while delegated skill work runs in separate `AgentServer` processes.

### Skill Agent Lifecycle

```
invoke_skill tool called
  │
  ├── AgentSupervisor.spawn_agent(definition, parent: request_task_pid)
  │   └── AgentServer.start_link()
  │       └── status: :initializing → :idle
  │
  ├── AgentServer.run_task(task, context)
  │   └── status: :running
  │       ├── Build messages: [system_prompt from template, task description]
  │       ├── AgentLoop.run() with skill's tools/model/iterations
  │       ├── Tool calls executed within skill's allowed_tools
  │       └── Return result text
  │
  ├── status: :idle (task complete)
  │   └── Journal written by invoke_skill tool
  │
  └── Process exits normally (:normal)
      └── AgentSupervisor does NOT restart (:temporary)
```

**Skill agents are one-shot worker processes.** They exist only for the duration of one task. The caller waits for completion, then the worker exits. No state persists between invocations — the journal is the record.

### State Snapshots

Persistent `AgentServer` snapshots are **not part of M2** under this ownership model. Crash recovery for the current Main Agent relies on its direct application supervision plus the existing separate `ConversationStore` process, which already owns chat history outside the `MainAgent` process.

---

## 7. Failure Modes and Recovery Behavior

### F1: Skill agent crashes during execution

**Cause:** Unhandled exception in skill's AgentLoop or tool execution.
**Detection:** The `invoke_skill` caller process (the per-message task started by `MainAgent`) receives `{:DOWN, ref, :process, pid, reason}` for the monitored child.
**Recovery:** invoke_skill tool returns `{:error, "Skill crashed: <reason>"}` to Main Agent's LLM. LLM decides whether to retry, try different skill, or report to user.
**Impact:** Other concurrent skills unaffected. Main Agent unaffected.

### F2: Skill agent times out

**Cause:** Skill takes longer than timeout (default 5 minutes).
**Detection:** `Task.yield(task, timeout)` returns nil.
**Recovery:** invoke_skill kills the skill's AgentServer process. Returns `{:error, "Skill timed out after 300s"}` to LLM. LLM decides next step.
**Impact:** Same as F1.

### F3: Main Agent crashes

**Cause:** Bug in MainAgent or unhandled error in message processing.
**Detection:** `FermixCore.Application` restarts MainAgent as its direct `:permanent` child.
**Recovery:** Conversation history remains in ConversationStore (separate process). Any in-flight request task dies with MainAgent, and any skill workers parented to that task detect parent death and self-terminate. No MainAgent snapshot restoration is assumed in M2.
**Impact:** Current message processing is lost. User may need to resend last message.

### F4: AgentSupervisor crashes

**Cause:** Supervisor itself hits max restart intensity.
**Detection:** Parent supervisor (FermixCore.Application) restarts AgentSupervisor.
**Recovery:** All spawned skill agents are lost. Because M2 starts AgentSupervisor before MainAgent in the `:rest_for_one` application tree, MainAgent also restarts and resumes with ConversationStore-backed history once AgentSupervisor is back.
**Impact:** All in-flight work lost. System recovers to idle state.

### F5: SkillRegistry can't load a skill template

**Cause:** Malformed YAML, missing file, invalid name.
**Detection:** `SkillRegistry.load/1` returns `{:error, reason}`.
**Recovery:** invoke_skill tool returns descriptive error to LLM. LLM may try a different skill or report to user.
**Impact:** Only that skill invocation fails. System otherwise healthy.

### F6: LLM provider returns error during skill execution

**Cause:** Rate limit, network error, API outage.
**Detection:** `AgentLoop.run/1` returns `{:error, reason}` from provider.
**Recovery:** Skill agent returns error to parent. Same escalation as F1.
**Impact:** Skill fails, Main Agent handles.

### F7: Runaway skill (infinite tool loop)

**Cause:** LLM keeps calling tools without converging.
**Detection:** `max_iterations` limit in AgentLoop (from AgentDefinition).
**Recovery:** AgentLoop returns with truncated result after hitting limit. invoke_skill returns partial result.
**Impact:** Bounded by design. No system-level runaway.

---

## 8. Security / Trust Boundaries

**M2 does not include a full security policy engine or audit system** — that's M5. However, M2 does enforce skill tool allowlists at runtime and establishes the structure that M5 will extend:

### Trust boundary: Main Agent → Skill Agent

- Skill's `allowed_tools` field is enforced at runtime. AgentLoop exposes only allowlisted tool schemas to the provider, and Tool Registry rejects lookups outside that allowlist with a predictable "tool not available" failure. This is a bounded runtime ACL, not a full policy engine or audit system.
- Skill cannot access Main Agent's conversation history (it gets only the task + context strings passed via invoke_skill).
- Skill cannot send messages directly to the user's channel — it returns text to Main Agent, which decides what to send.
- Skill cannot spawn further sub-agents in M2 scope (invoke_skill is not in any skill's default `allowed_tools`). Recursive delegation is a future consideration.

### Trust boundary: User → Main Agent

- Unchanged from Phase 1. Telegram `allowed_user_ids` filter. No additional auth.

### Preparation for M5

AgentDefinition already carries `allowed_tools` and `delegates_to` fields. When M5 adds SecurityPolicy, it will read these fields and enforce them with audit logging. M2 does not block M5 — it sets up the data model.

---

## 9. Telemetry / Tracing / Observability Requirements

Every new component must emit structured telemetry. This is not optional.

### New telemetry events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:fermix, :agent, :start]` | — | `%{name, role, session_id, parent}` |
| `[:fermix, :agent, :stop]` | `%{duration_ms}` | `%{name, role, session_id, reason}` |
| `[:fermix, :agent, :task_start]` | — | `%{name, session_id, task_summary}` |
| `[:fermix, :agent, :task_complete]` | `%{duration_ms, iterations}` | `%{name, session_id, success}` |
| `[:fermix, :skill, :invoke]` | `%{duration_ms}` | `%{skill, task_summary, success, parent_session}` |
| `[:fermix, :skill, :journal_write]` | `%{bytes}` | `%{skill, session_id, path}` |
| `[:fermix, :supervisor, :spawn]` | — | `%{name, persistent, parent}` |
| `[:fermix, :supervisor, :exit]` | — | `%{name, reason, was_monitored}` |

### Trace records

All events write to `~/.fermix/traces/YYYY-MM-DD/agent_event.jsonl` via existing `Trace.record/3`.

### Correlation

`session_id` (UUID per agent invocation) is the correlation key. Parent → child linked by `parent_session` in skill invocation events. This enables reconstructing the full delegation tree from trace files.

---

## 10. Acceptance Criteria

### AC-1: Main Agent delegates to a skill and returns result to user

Given a running Fermix instance with `coding-skill` template in `~/.fermix/skills/`,
when a user sends "Use the coding skill to read the README" via Telegram,
then Main Agent's LLM calls `invoke_skill(skill: "coding-skill", task: "Read the README")`,
a temporary AgentServer is spawned and runs the task,
the skill reads the file and returns content,
Main Agent sends the result back to the user,
and the skill agent process has exited.

### AC-2: Skill agent uses only its declared tools

Given a skill with `allowed_tools: ["file_read"]`,
when the skill's LLM attempts to call `shell`,
then the tool call fails with "tool not available",
and the skill can only execute `file_read`.

### AC-3: Safe parallel skill execution

Given two invoke_skill calls in the same agent loop iteration,
when they target different repos or are both read-only against the same pinned repo snapshot,
then they may run concurrently under AgentSupervisor,
both complete independently,
and the in-flight Main Agent request task receives both results.

### AC-4: Mixed same-repo mutating + read-only work requires isolation

Given one mutating coding task and one review/read-only task targeting the same repo,
when the read-only task does not have its own pinned snapshot or isolated checkout,
then the system does not run them concurrently from a shared checkout,
and instead serializes or rejects the batch with an explicit "repo isolation required" reason.

### AC-5: Same-repo multiple mutating tasks require isolation

Given two coding tasks targeting the same repo,
when no `git worktree` or remote execution boundary is configured for them,
then the system does not run them in parallel from a shared checkout,
and instead serializes or rejects the batch with an explicit "repo isolation required" reason.

### AC-6: Skill failure doesn't crash Main Agent

Given a skill that crashes during execution,
when the crash occurs,
then the in-flight request receives an error result (not a crash),
the skill process is cleaned up,
and Main Agent continues operating normally.

### AC-7: Skill journal written on completion

Given a successful skill invocation,
when the skill completes,
then a Markdown journal file exists at `~/.fermix/journals/<skill-name>/<timestamp>.md`,
containing task, duration, status, execution summary, and result.

### AC-8: Main Agent survives restart

Given a running Main Agent,
when the Main Agent process is killed and restarted by the application supervisor,
then ConversationStore history remains intact,
and Main Agent resumes accepting messages with the same channel-facing contract.

### AC-9: SkillRegistry lists and loads templates

Given skill templates in `~/.fermix/skills/`,
when `SkillRegistry.list()` is called,
then it returns all valid skill names,
and `SkillRegistry.load(name)` returns a valid AgentDefinition.

### AC-10: Telemetry emitted for full delegation lifecycle

Given a skill invocation,
then telemetry events are emitted for: agent start, task start, task complete, agent stop, skill invoke, journal write,
all with correct session_id correlation.

---

## 11. Dependency Map

### Internal dependencies (build order matters)

```
AgentDefinition          ← no dependencies (pure struct + parsing)
    │
    ├── SkillRegistry    ← depends on AgentDefinition (parses templates into definitions)
    │
    ├── AgentServer      ← depends on AgentDefinition (holds definition in state)
    │   │                   depends on AgentLoop (runs tasks)
    │   │                   depends on Tools.Registry (filters tools per definition)
    │   │
    │   └── AgentSupervisor ← depends on AgentServer (spawns delegated skill workers)
    │
    └── AgentCoordinator ← depends on SkillRegistry (queries capabilities)

invoke_skill tool        ← depends on SkillRegistry, AgentSupervisor, AgentServer
                            depends on Journal writer

MainAgent                ← depends on AgentLoop, ConversationStore, invoke_skill tool
                            depends on Task.Supervisor for per-message request tasks

Application wiring       ← depends on AgentSupervisor + MainAgent
                            starts AgentSupervisor before MainAgent
                            preserves MainAgent as a direct Application child
```

### External dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| AgentLoop | Exists | Needs minor changes: accept filtered tool list, accept definition-sourced model/temperature |
| Tools.Registry | Exists | Add allowlist-aware lookup/filter helpers used by skill-agent runtime enforcement |
| ConversationStore | Exists | Skill agents don't use it (they get task text, not chat history) |
| Trace | Exists | Add new event types for agent lifecycle |
| OpenAI provider | Exists | Used by both Main Agent and skill agents |
| Task.Supervisor | Exists | Used by MainAgent for per-message request tasks and available to AgentServer for monitored task execution |
| YAML parser | New dep | `yaml_elixir` hex package for parsing skill template frontmatter |

### Changes to existing modules

| Module | Change | Reason |
|--------|--------|--------|
| `AgentLoop` | Accept `allowed_tools` option to filter tool calls | Skill agents must only use declared tools |
| `AgentLoop` | Accept `model`, `temperature` overrides from caller | Skill definitions specify these |
| `MainAgent` | Keep as standalone GenServer; add delegation hooks to AgentSupervisor/invoke_skill while preserving `handle_message/2`, `reply_fn`, and ConversationStore ownership | Match the current runtime contract and avoid MainAgent/AgentServer split-brain during M2 |
| `Application` | Start AgentSupervisor before MainAgent as a sibling child; keep MainAgent started directly by `FermixCore.Application` | Preserve current supervision wiring while enabling supervised skill workers |
| `TelemetryHandler` | Handle new agent lifecycle events | Observability |

---

## 12. Recommended Implementation Slices

High-level sequencing. Each slice is independently testable and shippable.

### Slice 1: AgentDefinition + SkillRegistry (foundation)

Build the data model and template loader. No runtime behavior yet.

- AgentDefinition struct with all fields, validation, `new/1`
- SkillRegistry GenServer: load from filesystem, list, cache
- YAML frontmatter parser for `SKILL.md` files
- Ship 2-3 built-in skill templates
- Tests: parsing, validation, edge cases (missing fields, bad YAML, etc.)

### Slice 2: AgentServer (lifecycle)

The core GenServer that manages one delegated skill worker's life.

- AgentServer GenServer with state machine (init → idle → running → stopping)
- `run_task/3` that delegates to AgentLoop
- Parent/child monitoring (monitor parent, track children)
- Telemetry for lifecycle events
- Tests: lifecycle transitions, crash behavior, monitoring

### Slice 3: AgentSupervisor + supervision wiring

Restructure the supervision tree around skill workers while preserving the existing MainAgent entrypoint.

- AgentSupervisor DynamicSupervisor
- Start AgentSupervisor as a sibling before MainAgent in `FermixCore.Application`
- Keep MainAgent as the standalone channel-facing GenServer
- Do not convert MainAgent into an AgentServer instance in this slice
- Preserve the existing `Task.Supervisor` + `MainAgent.handle_message/2` request flow unchanged
- Tests: supervision and restart behavior

### Slice 4: invoke_skill tool + Main Agent integration

The tool that connects Main Agent to skill agents.

- invoke_skill tool module (implements Tool behaviour)
- Wire MainAgent's request-task path to delegate through `invoke_skill` into AgentServer-backed skill workers
- Execution: load skill → spawn AgentServer → run_task → collect result
- Tool filtering: pass only `allowed_tools` to skill's AgentLoop
- Model/temperature override from skill definition
- Timeout handling
- Register invoke_skill in Main Agent's tool list
- Verify existing webhook → MainAgent flow still works unchanged while delegation is enabled
- Tests: successful delegation, skill failure, timeout, unknown skill, message flow regression

### Slice 5: Skill journals

Persistence and auditability.

- Journal writer module
- Called by invoke_skill after task completes (success or failure)
- Directory creation, file naming, Markdown formatting
- Tests: journal content, failure journals, concurrent writes

### Slice 6: Parallel execution policy + AgentCoordinator (P1)

Multi-skill concurrency and capability matching.

- Classify batches by repo target and mutation mode before spawning
- Parallel skill spawning from invoke_skill (or batch variant) only for safe cases
- Block or serialize same-repo mutating batches unless an isolation boundary is configured
- Define the isolation boundary contract for same-repo mutating work:
  `git worktree` per skill locally, or a remote execution environment with a separate checkout
- AgentCoordinator: capability matching, delegation ACL
- Result collection from multiple concurrent skills
- Tests: safe parallel execution, blocked unsafe same-repo writes, coordinator matching, ACL enforcement

---

## 13. Decisions and Open Questions

### Decision-1: MainAgent remains the channel-facing GenServer in M2

`MainAgent` remains the channel-facing GenServer in M2. `AgentServer` is introduced for delegated skill-worker lifecycle and does not replace MainAgent as the inbound channel process.

**Rationale:**
- Matches the current codebase and supervision tree (`FermixCore.Application` starts MainAgent directly today).
- Matches the current runtime shape in `main_agent.ex`, where `handle_message/2` offloads each inbound request to a `Task.Supervisor` child instead of turning the GenServer itself into a long-running worker.
- Preserves the existing tests and webhook integration that already target `MainAgent.handle_message/2`.
- Keeps `reply_fn`, conversation-history assembly, and channel ingress outside the generic AgentServer abstraction.
- Lets M2 introduce AgentServer where it provides immediate value first: supervised, ephemeral skill workers.

### OQ-2: How does the LLM know which skills are available?

**Option A:** List all skills in Main Agent's system prompt (static, updated on reload).
**Option B:** Provide a `list_skills` tool that the LLM can call to discover skills dynamically.
**Option C:** Both — system prompt has a summary, tool provides details.

**Recommendation:** Option A for now. Skill list is small (2-3 built-in + user-defined). Simpler. Add Option B if skill count grows.

### OQ-3: Skill agent timeout — how long?

Default 5 minutes proposed. Some tasks (long research, large code changes) may need more. Should this be per-skill-template configurable?

**Recommendation:** Yes. Add `timeout_seconds` to AgentDefinition (default 300). Skill templates can override.

### OQ-4: Should skills be able to delegate to other skills (recursive)?

RustyClaw supports it via `delegates_to` ACL. In M2, proposed as non-goal.

**Recommendation:** Defer. Add to skill's `allowed_tools` when needed. The architecture supports it — invoke_skill is just a tool — but unbounded recursion is risky without M5's security policy.

### OQ-5: How does the skill get context about the user's workspace?

Skill needs to know the working directory, relevant file paths, etc. Should Main Agent pass this explicitly, or should skills inherit a global workspace context?

**Recommendation:** Explicit. invoke_skill's `context` parameter carries everything the skill needs. No implicit global state. This keeps skills testable and isolated.

### OQ-6: YAML parser dependency — yaml_elixir or hand-roll frontmatter?

`yaml_elixir` is a well-maintained hex package. Alternatively, frontmatter is simple enough to parse with regex + Jason (if we use JSON frontmatter instead of YAML).

**Recommendation:** Use `yaml_elixir`. YAML frontmatter is the established convention (Jekyll, Hugo, Obsidian). Don't reinvent.

### OQ-7: Should AgentLoop changes be backwards-compatible or can we refactor?

AgentLoop currently has a fixed signature. Adding `allowed_tools`, `model`, `temperature` options requires changes.

**Recommendation:** Refactor. AgentLoop.run/1 already takes a keyword list — add new optional keys. Existing callers (MainAgent) don't break because the keys are optional with defaults.

---

## Related Documents

- `docs/ROADMAP.md` — Milestone 2 feature table and sequencing
- `docs/PROJECT_PLAN.md` — Overall architecture, Phase 2 section
- RustyClaw `docs/MAIN_AGENT_DESIGN.md` — Hub-and-spoke pattern, memory tiers, skill journals
- RustyClaw `docs/OPTION_B_ORCHESTRATION_DESIGN.md` — Skill orchestration via Elixir
- RustyClaw `elixir/rustyclaw_orchestrator/lib/rustyclaw_orchestrator/plugins/git_worktree.ex` — Local repo isolation via worktrees
- RustyClaw `elixir/rustyclaw_orchestrator/lib/rustyclaw_orchestrator/plugins/batch_processor.ex` — Repo-grouped fanout policy (same repo sequential unless isolated)
- RustyClaw `elixir/rustyclaw_orchestrator/lib/rustyclaw_orchestrator/agent_server.ex` — Port reference
- RustyClaw `elixir/rustyclaw_orchestrator/lib/rustyclaw_orchestrator/agent_supervisor.ex` — Port reference
- RustyClaw `elixir/rustyclaw_orchestrator/lib/rustyclaw_orchestrator/agent_definition.ex` — Port reference
- RustyClaw `elixir/rustyclaw_orchestrator/lib/rustyclaw_orchestrator/agent_coordinator.ex` — Port reference
- RustyClaw `elixir/rustyclaw_orchestrator/lib/rustyclaw_orchestrator/skill_registry.ex` — Port reference
