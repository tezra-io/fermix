# Milestone 4.5: Prompt Bootstrap Architecture - Functional Design

**Status:** Draft
**Date:** 2026-04-19
**Author:** Sujeeth / Aira
**Depends on:** M4 (prompt memory files), M2 (multi-agent foundations already present), current `MainAgent`
**References:** `docs/ROADMAP.md` (M4.5 section), `docs/MILESTONE_4_ADVANCED_MEMORY.md`, Autogenesis (`arXiv:2604.15034`)

---

## 1. Problem / Goal

Fermix currently builds the main agent's system prompt from a hardcoded heredoc in `MainAgent.system_prompt/1`. This works, but it has several limitations:

- the main prompt is not file-backed or user-editable
- prompt identity, style, memory, and runtime guidance are all collapsed into one string
- there is no clean place to introduce `AGENTS.md` or `SOUL.md`
- the prompt architecture is harder to inspect and evolve than the memory architecture

**Goal of M4.5:** replace the hardcoded base prompt with a composable file-backed bootstrap layer that can load `AGENTS.md`, `SOUL.md`, `USER.md`, and `MEMORY.md` as ordered prompt parts, while keeping dynamic runtime sections generated at runtime.

This milestone also adopts one useful idea from the Autogenesis paper: prompt parts should be treated as explicit typed resources with clear exported representations, rather than one opaque heredoc. Fermix does **not** adopt the paper's full self-evolving protocol here. It only adopts the part that makes prompt composition more modular, inspectable, and safer to evolve later.

---

## 2. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| `PromptComposer` | P0 | New | Build ordered system messages from prompt/bootstrap parts |
| `AGENTS.md` support | P0 | New | File-backed agent operating instructions / runtime identity |
| `SOUL.md` support | P1 | New | File-backed tone/style/persona layer |
| Bootstrap file loader | P0 | New | Load prompt files from disk with missing-file handling |
| Prompt ordering policy | P0 | New | Stable ordering across file-backed and generated prompt parts |
| Runtime contract generation | P1 | New | Generate compact contract-style runtime sections from live registry state |
| Prompt budget accounting | P1 | New | Measure approximate contribution of each prompt/bootstrap part |
| MainAgent integration | P0 | Hybrid | Replace hardcoded `system_prompt/1` path with composed prompt messages |

### Non-Goals

| Feature | Reason | When |
|---------|--------|------|
| Memory extraction | Already belongs to M4 | M4 |
| `USER.md` / `MEMORY.md` generation | Already belongs to M4 | M4 |
| Hard file-size caps for bootstrap files | Not needed right now; accounting is enough | Later |
| Autonomous agent editing of `AGENTS.md` / `SOUL.md` | Too much prompt self-modification risk for this stage | Later |
| Sub-agent prompt inheritance policy | Future-proof API only; full behavior can wait | Later |
| Prompt marketplace / personas | Outside core bootstrap architecture | Later |

---

## 3. Current State / Constraints

### What exists today

In the current runtime:

- `MainAgent.process_message/2` fetches history, builds one `"system"` message from `system_prompt/1`, appends history, then appends the current user message
- `system_prompt/1` is a hardcoded heredoc containing:
  - the base "helpful AI assistant" identity
  - tool capabilities
  - `invoke_skill` guidance
  - the dynamic skill catalog snapshot
- the OpenAI provider already supports multiple leading system messages:
  - Responses API mode joins them into one `instructions` string
  - Chat Completions mode passes them through as system messages
- `AgentLoop` already preserves all leading system messages during naive truncation, and M4 compaction should preserve the same invariant

### Current base prompt content

The current hardcoded prompt includes the following stable ideas:

- the assistant is helpful
- it has access to tools
- it can execute shell commands, read/write files, and store/recall memories
- skills come from a cached registry snapshot
- `invoke_skill` should be used when specialization helps
- think step by step and use tools when needed

### Constraints

1. **Backward compatibility matters.** Fermix should continue to work if `AGENTS.md` or `SOUL.md` do not exist yet.
2. **Prompt memory from M4 must remain usable.** `USER.md` and `MEMORY.md` should plug into the composed prompt without changing their ownership model.
3. **Generated runtime sections still matter.** The skill catalog and similar runtime-only sections should stay generated, not fully moved into files yet.
4. **No separate prompt hard-cap policy in this milestone.** M4.5 measures prompt size, but overall context pressure is still handled by M4 compaction.
5. **No autonomous prompt mutation in this milestone.** `AGENTS.md` and `SOUL.md` remain operator-authored files; M4.5 does not introduce self-editing prompt loops.

---

## 4. High-Level Design

M4.5 introduces a new prompt assembly layer between `MainAgent` and the provider:

1. **Bootstrap files** - `AGENTS.md` and `SOUL.md` loaded from disk
2. **Prompt memory files** - `USER.md` and `MEMORY.md` loaded from the M4 memory layer
3. **Generated runtime sections** - skill catalog and runtime guidance generated at request time
4. **PromptComposer** - builds an ordered list of system messages

M4.5 also formalizes these parts as typed prompt resources. Each part has:

- a resource name (`agents`, `soul`, `user`, `memory`, `runtime`)
- a source (`bootstrap file`, `prompt-memory file`, `generated section`)
- prompt content
- prompt metadata (path when applicable, approximate size, optional revision info later)
- an exported representation for the LLM: a system-message text block

### Core decisions

**Decision:** `AGENTS.md` and `SOUL.md` are prompt/bootstrap files, not memory files. They should not live inside the M4 memory subsystem.

**Decision:** `USER.md` and `MEMORY.md` remain in M4. M4.5 composes them into the final prompt but does not own their generation.

**Decision:** Prompt composition outputs **multiple system messages**, not one giant concatenated string. Providers can flatten them if needed.

**Decision:** Missing file behavior must be safe. If `AGENTS.md` is absent, Fermix should fall back to the current embedded default so the system still boots and responds.

**Decision:** No hard file-size caps yet. This milestone adds accounting and visibility, not bootstrap truncation policy.

**Decision:** `AGENTS.md` is seeded by default; `SOUL.md` is optional. This matches current needs: a stable operating prompt is required, a style/persona file is useful but not mandatory.

**Decision:** Generated runtime sections should be compact **contracts**, not prose-heavy documentation. They exist to communicate live capabilities and constraints with minimal prompt bloat.

---

## 5. Prompt Part Model

M4.5 splits prompt context into explicit parts.

### 5.1 Static file-backed prompt parts

| Part | Purpose | Source |
|------|---------|--------|
| `AGENTS.md` | Main agent operating instructions and identity | `~/.fermix/bootstrap/<agent_id>/AGENTS.md` |
| `SOUL.md` | Tone, voice, and style layer | `~/.fermix/bootstrap/<agent_id>/SOUL.md` |
| `USER.md` | Owner profile memory | `~/.fermix/memory/<agent_id>/USER.md` |
| `MEMORY.md` | Agent/environment/project memory | `~/.fermix/memory/<agent_id>/MEMORY.md` |

### 5.2 Generated prompt parts

| Part | Purpose |
|------|---------|
| Skill contract | Runtime snapshot of available skills and when to use them |
| Tool/runtime contract | Dynamic capabilities, constraints, and usage rules that should not be hardcoded into files yet |

### 5.3 Why split this way

- `AGENTS.md` changes rarely and defines how the agent should operate
- `SOUL.md` changes rarely and defines how the agent should sound
- `USER.md` and `MEMORY.md` are living prompt-memory artifacts from M4
- generated runtime sections stay dynamic because they depend on live runtime state

### 5.4 Autogenesis-inspired refinement

Autogenesis is useful here in one narrow way: it treats prompts, tools, agents, environments, and memory as first-class registered resources with explicit exported representations and version lineage. Fermix should borrow the **resource model**, but not the paper's full autonomous self-evolution loop.

This is a selective adoption on purpose. The paper is strongest as a protocol/resource-management design, not as a direct prompt-memory implementation guide for a self-hosted single-user system like Fermix.

For M4.5 that means:

- prompt parts should be loaded and composed as typed resources, not concatenated ad hoc
- generated runtime sections should look like compact **contracts** exported from live runtime state
- prompt composition should preserve metadata so later milestones can add lineage and rollback without rewriting this layer

What Fermix is **not** adopting in M4.5:

- no Reflect/Select/Improve/Evaluate/Commit operator loop
- no autonomous rewriting of `AGENTS.md` or `SOUL.md`
- no protocol-level registry for every agent resource yet

This keeps the milestone practical: better prompt architecture now, versioned resource governance later.

---

## 6. Proposed Components

### 6.1 `FermixCore.Prompt.BootstrapLoader`

**Responsibility:** Load static prompt/bootstrap files from disk.

**Files:**

- `~/.fermix/bootstrap/<agent_id>/AGENTS.md`
- `~/.fermix/bootstrap/<agent_id>/SOUL.md`

**Behavior:**

- load file contents if present
- trim empty files to "not present"
- return metadata including path and approximate size
- never crash the request path because of a missing optional file

**Fallback policy:**

- if `AGENTS.md` is missing, use the embedded default equivalent of the current `system_prompt/1` base instructions
- if `SOUL.md` is missing, inject nothing for that part

### 6.2 `FermixCore.Prompt.RuntimeSections`

**Responsibility:** Build dynamic runtime prompt sections.

**Initial sections:**

- skill catalog snapshot
- tool/runtime usage guidance carried over from the current base prompt

**Important:** These sections remain generated because they are runtime-derived and should not be hand-maintained in files yet.

**Design rule:** Runtime sections should be generated as compact **contracts**, not narrative prose.

That means they should answer questions like:

- what skills/tools are currently available
- what each one is for
- when to prefer direct tool use vs `invoke_skill`
- what constraints matter right now

They should avoid:

- repeating static operating rules already in `AGENTS.md`
- long explanatory text the model can infer from names alone
- duplicating file-backed memory content

### 6.3 `FermixCore.Prompt.PromptComposer`

**Responsibility:** Compose the full ordered list of system messages for a request.

**Input:**

- `agent_id`
- prompt/bootstrap files (`SOUL.md`, `AGENTS.md`)
- prompt memory files (`USER.md`, `MEMORY.md`)
- dynamic runtime sections

**Output:**

```elixir
[
  %{role: "system", content: "...SOUL.md..."},
  %{role: "system", content: "...AGENTS.md..."},
  %{role: "system", content: "...USER.md..."},
  %{role: "system", content: "...MEMORY.md..."},
  %{role: "system", content: "...runtime sections..."}
]
```

Each output item should be assembled from an internal prompt-part descriptor, for example:

```elixir
%PromptPart{
  name: :soul,
  source: {:file, "~/.fermix/bootstrap/main/SOUL.md"},
  kind: :bootstrap,
  content: "...",
  approx_tokens: 320,
  exported_role: "system"
}
```

The provider does not need this struct directly. `PromptComposer` uses it to keep prompt assembly typed and inspectable before exporting normal `%{role: "system", content: ...}` messages.

**Ordering policy:**

1. `SOUL.md`
2. `AGENTS.md`
3. `USER.md`
4. `MEMORY.md`
5. generated runtime sections

**Why this order:**

- identity/persona first — establishes the agent's voice and character before anything else; LLMs weight early system content more heavily for tone adherence
- operating rules second — behavioral constraints apply on top of the established identity
- persistent owner/agent memory next
- dynamic runtime instructions last

### 6.4 `FermixCore.Prompt.Accounting`

**Responsibility:** Track approximate contribution of each prompt part.

**This milestone does not enforce hard limits.** It only records approximate sizes for inspection and future policy work.

**Outputs may include:**

- raw character count
- approximate token count
- source path
- part name (`agent`, `soul`, `user`, `memory`, `runtime`)

### 6.5 Why contracts matter

The useful lesson from Autogenesis is not "let the system rewrite itself." It is that prompt-facing resources should expose compact exported representations tailored to LLM consumption.

For Fermix, contract-style runtime sections help by:

- reducing prompt bloat compared with prose-heavy runtime guidance
- making live capability exposure deterministic and inspectable
- keeping file-backed prompt identity separate from runtime state
- giving later milestones a clean place to add revision tracking

### 6.6 `FermixCore.Prompt.Seeder`

**Responsibility:** Seed default bootstrap files on first run or first access.

**Seed behavior:**

- seed `AGENTS.md` with the current default operating prompt equivalent
- do not require `SOUL.md`; it can remain absent until the user adds one

**Why seed at all:** It gives the user a visible editable file instead of forcing them to patch code to change the base prompt.

---

## 7. Prompt File Semantics

### `AGENTS.md`

`AGENTS.md` is the main operating prompt file.

It should contain:

- who the agent is
- what it is allowed and expected to do
- how it should use tools
- core runtime behavior rules

It should **not** contain:

- fast-changing user memory
- long-running project notes better suited to `MEMORY.md`
- style/persona details that belong in `SOUL.md`

### `SOUL.md`

`SOUL.md` is the style/persona layer.

It should contain:

- response style
- tone
- voice/personality constraints

It should **not** contain:

- hard operational rules
- user memory
- agent environment details

### `USER.md` and `MEMORY.md`

These remain governed by M4.

M4.5 only loads them and composes them into prompt context. It does not change:

- how they are generated
- how they are rebuilt
- what is promoted into them

### Which prompt role these files use

All four files are loaded as **system/instructions-side context**, not as user messages.

That means:

- `AGENTS.md` is a system/bootstrap prompt part
- `SOUL.md` is a system/bootstrap prompt part
- `USER.md` is a system-side user-profile memory part
- `MEMORY.md` is a system-side durable memory part

Even though `USER.md` is about the user, it is still not injected as a `role: "user"` message. It is injected as part of the agent's system context, similar to Hermes and OpenClaw.

---

## 8. MainAgent Integration

### Current flow

Today:

```text
system_message = %{role: "system", content: system_prompt(available_skills)}
messages = [system_message] ++ history ++ [user_message]
```

### New flow

After M4.5:

```text
system_messages = PromptComposer.compose(
  agent_id: "main",
  available_skills: state.available_skills
)

messages = system_messages ++ history ++ [user_message]
```

### Why this is low-risk

- `MainAgent` already constructs the message list in one place
- providers already support multiple system messages
- `AgentLoop` already preserves leading system messages
- M4 compaction can treat all system messages as protected prompt context

### How this integrates into the current codebase

The current code path already has the right seam for this milestone:

- `MainAgent.process_message/2` in `apps/fermix_core/lib/fermix_core/agents/main_agent.ex` currently builds a single `system_message` from `system_prompt/1`, then assembles `[system_message] ++ history ++ [user_message]`
- the OpenAI Responses path in `apps/fermix_core/lib/fermix_core/providers/openai.ex` already merges all leading system messages into `instructions`
- the Chat Completions path already passes multiple system messages through unchanged
- `AgentLoop.truncate_messages/1` in `apps/fermix_core/lib/fermix_core/agent_loop.ex` already preserves all leading system messages when trimming history

So integration is mostly a composition refactor:

1. load file-backed prompt resources from disk
2. load prompt-memory files from M4
3. generate runtime contracts from live skill/tool state
4. compose these into ordered system messages
5. reuse the existing provider and loop pipeline unchanged

That is why M4.5 is a good fit for the current system: it changes prompt assembly, not the provider protocol or agent loop model.

### Embedded default migration

The current hardcoded prompt should be moved into the default seeded `AGENTS.md` content, with runtime-only pieces split out into generated sections where appropriate.

The current prompt breaks down roughly into:

- stable operating instructions -> `AGENTS.md`
- dynamic skill snapshot -> generated runtime section

There is no current `SOUL.md` equivalent, so that file starts optional/empty.

---

## 9. Provider Compatibility

The current OpenAI provider path already supports this design.

### Chat Completions mode

- system messages are passed through as ordinary system messages

### Responses API mode

- all leading system messages are joined into the `instructions` field

**Result:** no provider rewrite is required to support file-backed prompt parts.

This also means the Autogenesis-inspired contract export is a natural fit. Fermix can keep a richer internal prompt-part model and still export plain system-message text to the provider boundary.

---

## 10. Compaction Interaction

Prompt/bootstrap files are part of the assembled system prompt context.

That means:

- they are loaded **before** history and the current user message are appended
- compaction sees them as protected prompt context
- compaction should summarize old conversation history, not these files

### Important design rule

M4.5 does **not** add special bootstrap truncation policy. If prompt pressure grows, the system should first:

- rely on M4 compaction for history
- surface prompt accounting for visibility

If hard prompt-file clipping is ever needed later, that should be a separate policy addition.

This is another place where the split from Autogenesis matters: M4.5 treats prompt parts as typed resources for composition and accounting, but compaction still operates over normal assembled messages. There is no new protocol layer in the hot path.

---

## 11. File Locations and Workspace Layout

Current `ConfigStore.workspace_paths/0` does not include a prompt/bootstrap directory.

M4.5 should add:

```elixir
bootstrap: "~/.fermix/bootstrap"
```

And use:

- `~/.fermix/bootstrap/<agent_id>/AGENTS.md`
- `~/.fermix/bootstrap/<agent_id>/SOUL.md`

This keeps prompt/bootstrap files separate from:

- `~/.fermix/memory/<agent_id>/USER.md`
- `~/.fermix/memory/<agent_id>/MEMORY.md`

### Why separate roots

- memory files are generated/rewritten by the memory system
- bootstrap files are operator-authored prompt files
- the separation makes ownership and lifecycle clear

---

## 12. User and System Flows

### Flow 1: Normal request

```text
MainAgent.process_message()
  -> BootstrapLoader.load(agent_id)          # SOUL.md, AGENTS.md
  -> PromptFiles.load(agent_id)              # USER.md, MEMORY.md from M4
  -> RuntimeSections.build(available_skills)
  -> PromptComposer.compose(...)
  -> messages = system_messages ++ history ++ [user_message]
  -> Compactor.compact(messages, budget) if needed
  -> AgentLoop.run(...)
```

### Flow 2: First run / missing AGENTS.md

```text
PromptComposer.compose(...)
  -> BootstrapLoader.load(agent_id)
  -> AGENTS.md missing
  -> Seeder.ensure_seeded(agent_id) or fallback to embedded default
  -> continue request safely
```

### Flow 3: User edits `AGENTS.md`

```text
User edits ~/.fermix/bootstrap/main/AGENTS.md
  -> next request loads file from disk
  -> new contents appear in composed system messages
```

No explicit reload endpoint is required for prompt/bootstrap files in this milestone.

---

## 13. Config

New configuration keys under `:fermix_core`:

```elixir
config :fermix_core, :prompt_bootstrap,
  bootstrap_dir: "~/.fermix/bootstrap",
  seed_agent_file: true,
  seed_soul_file: false,
  accounting_enabled: true
```

No hard bootstrap size cap is introduced in this milestone.

---

## 14. Testing Strategy

### Unit tests

- `BootstrapLoader`: present file, missing file, empty file handling
- `RuntimeSections`: skill catalog rendering
- `PromptComposer`: correct ordering, omission of absent optional parts
- `PromptSeeder`: default `AGENTS.md` seeding
- `PromptAccounting`: approximate size metadata

### Integration tests

- `MainAgent` uses seeded/default `AGENTS.md` when no file exists
- `MainAgent` loads `SOUL.md` when present
- `MainAgent` composes `SOUL.md` + `AGENTS.md` + `USER.md` + `MEMORY.md` + runtime guidance in the correct order
- provider receives multiple system messages correctly
- compaction preserves composed system messages verbatim

### Regression anchors

- if no prompt/bootstrap files exist, the main agent still behaves like today's hardcoded prompt path
- `USER.md` / `MEMORY.md` continue to work exactly as defined in M4

---

## 15. Implementation Order

### Stage 1: Bootstrap filesystem support

1. Add bootstrap dir path to `ConfigStore`
2. Implement `Prompt.Seeder`
3. Implement `Prompt.BootstrapLoader`

**Verify:** `AGENTS.md` can be seeded and loaded from disk.

### Stage 2: Prompt composition

1. Implement `Prompt.RuntimeSections`
2. Implement `Prompt.PromptComposer`
3. Add prompt accounting metadata
4. Keep runtime sections contract-like and compact

**Verify:** Composer returns correct ordered system messages.

### Stage 3: MainAgent integration

1. Replace `system_prompt/1` usage in `MainAgent.process_message/2`
2. Build `system_messages` via `PromptComposer`
3. Keep history/user message assembly unchanged

**Verify:** MainAgent works with file-backed prompt parts and the providers still behave correctly.

### Stage 4: Cleanup and fallback removal

1. Move the current hardcoded prompt text into the default `AGENTS.md` seed content
2. Keep embedded fallback only as a compatibility safety net
3. Add tests around missing-file fallback

**Verify:** Default file-backed prompt behavior matches the old system prompt closely enough to avoid regressions.

---

## 16. Later Milestones

### 16.1 What M4.5 intentionally leaves out

M4.5 should stop at:

- file-backed bootstrap prompt parts
- prompt-memory composition
- generated runtime contracts
- prompt accounting

It should not take on:

- version lineage
- rollback
- autonomous prompt mutation
- general resource registries beyond prompt composition needs

### 16.2 Recommended follow-up milestone

If Fermix wants the strongest useful part of Autogenesis later, the right next step is a separate milestone for **Versioned Prompt and Memory Resources**.

That milestone should add:

- revision history for `AGENTS.md`, `SOUL.md`, `USER.md`, `MEMORY.md`
- revision history for persisted compaction checkpoints
- rollback to prior accepted revisions
- change provenance: what memory/event caused a rewrite
- optional diff inspection in LiveView or CLI

This is worth doing because it improves auditability and operator control without forcing Fermix into autonomous self-modification.

### 16.3 Why no stronger adoption now

The full Autogenesis design is broader than Fermix needs right now. It is centered on protocol-level management of prompts, agents, tools, environments, and memory, plus a closed-loop self-improvement operator stack.

For Fermix today, that would add:

- more protocol surface area than the runtime currently needs
- prompt/tool self-mutation risk before governance is ready
- complexity not required to ship persistent memory and file-backed bootstrap prompts

So the right use of the paper is selective adoption:

- adopt typed prompt resources and contract-style runtime exports now
- defer lineage and rollback to a dedicated later milestone
- skip autonomous self-evolution for now

---

## 16. Risks and Mitigations

### Risk: `AGENTS.md` and generated runtime sections duplicate each other

**Mitigation:** Keep dynamic skill/runtime sections generated and keep `AGENTS.md` focused on stable operating rules.

### Risk: prompt/bootstrap files become a dumping ground

**Mitigation:** Separate responsibilities clearly:

- `AGENTS.md` = operating instructions
- `SOUL.md` = tone/style
- `USER.md` = owner memory
- `MEMORY.md` = agent/environment memory

### Risk: user edits break agent behavior

**Mitigation:** Seed safe defaults, keep embedded fallback, and test missing/empty-file behavior carefully.

### Risk: prompt size grows without visibility

**Mitigation:** Add prompt accounting metadata now, even without hard caps.

### Risk: sub-agents later need different bootstrap policy

**Mitigation:** Design `PromptComposer` to accept `agent_role` or prompt-part filters even if only the main agent uses the full stack today.

---

## 17. Open Questions

1. **Should `SOUL.md` be seeded with a default style file, or stay absent by default?**
2. **Should prompt/bootstrap files be loaded every request or cached by mtime?** Loading every request is simpler; caching is an optimization.
3. **Should sub-agents inherit `SOUL.md` or only `AGENTS.md` plus their own skill prompt?** This can wait, but the composer API should leave room for it.
4. **Should prompt accounting be exposed in a future `/context` or health/debug endpoint?**

---

## 18. Summary

Milestone 4.5 gives Fermix a clean prompt/bootstrap architecture:

- `AGENTS.md` replaces the hardcoded main operating prompt
- `SOUL.md` adds an optional persona/style layer
- `USER.md` and `MEMORY.md` plug in from M4 as prompt-memory files
- `PromptComposer` builds ordered system messages from file-backed and generated sections
- current provider paths already support multiple system messages
- no hard size cap is introduced yet; this milestone focuses on composition and visibility

This keeps the architecture clean:

- M4 owns memory
- M4.5 owns prompt/bootstrap composition
