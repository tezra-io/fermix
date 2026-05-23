# Milestone 7.3: Skill Lifecycle & Progressive Disclosure

**Status:** Draft
**Date:** 2026-05-22
**Author:** Sujeeth
**Depends on:** M7 (skill files, `SkillRegistry`), M4.9 (`CapabilityRegistry`), M9.1 (Realtime voice session)

---

## 1. Problem / Goal

Fermix can discover `SKILL.md` files, but the lifecycle and exposure model are not yet right:

1. Skills are discovered at daemon start and cached independently by `SkillRegistry`, `MainAgent.state.available_skills`, and `MainAgent.state.runtime_context`.
2. Realtime voice passes `available_skills: []`, so voice prompts do not advertise skills even when the underlying tool list contains skill capabilities.
3. Current M7 behavior treats every skill as a provider-visible function capability. That works for delegation, but it is not how OpenClaw, Codex skills, or Hermes handle skills. It also bloats provider tool schemas and ties skill discovery to provider tool-name rules.

**Goal of M7.3:** make skills visible, reloadable, and cache-aware using a progressive-disclosure design:

- The runtime prompt gets a compact catalog: skill `name`, `description`, `source_path`, and trust.
- The full `SKILL.md` body is loaded only when a model chooses the skill.
- Executable tools remain capabilities. Skills are instruction packages first, not provider tools by default.
- Sub-agent delegation remains available through one stable `skill_run` tool.
- Main Agent and Realtime use the same live skill snapshot.
- `fermix skills reload` updates registry state and invalidates prompt caches without a full daemon restart.

This follows OpenClaw/Codex where it is proven, while keeping Fermix's stronger sub-agent execution path behind `skill_run` rather than one provider function per skill.

---

## 2. References

External:

- OpenClaw skill docs: `https://github.com/openclaw/openclaw/blob/main/docs/tools/skills.md`
- OpenClaw system prompt: `https://github.com/openclaw/openclaw/blob/main/src/agents/system-prompt.ts`
- OpenAI Codex skills: `https://developers.openai.com/codex/skills/`
- Agent Skills format: `https://agentskills.io/`

Local comparisons:

- Hermes skill cache note: `/Users/sujshe/projects/hermes-agent/AGENTS.md:150`
- Hermes skill reload: `/Users/sujshe/projects/hermes-agent/agent/skill_commands.py:344`
- Hermes skill invocation message: `/Users/sujshe/projects/hermes-agent/agent/skill_commands.py:428`
- Hermes OpenAI Responses tool conversion: `/Users/sujshe/projects/hermes-agent/agent/codex_responses_adapter.py:205`
- Hermes Anthropic tool conversion: `/Users/sujshe/projects/hermes-agent/agent/anthropic_adapter.py:1422`
- Hermes xAI prompt-cache routing: `/Users/sujshe/projects/hermes-agent/agent/transports/codex.py:182`

Fermix current code:

- `apps/fermix_core/lib/fermix_core/agents/skill_registry.ex`
- `apps/fermix_core/lib/fermix_core/agents/main_agent.ex`
- `apps/fermix_core/lib/fermix_core/agents/runtime_context.ex`
- `apps/fermix_core/lib/fermix_core/prompt/runtime_sections.ex`
- `apps/fermix_core/lib/fermix_core/realtime/session_server.ex`
- `apps/fermix_core/lib/fermix_core/capabilities/skill.ex`
- `apps/fermix_core/lib/fermix_core/capabilities/mcp/capability.ex`
- `apps/fermix_core/lib/fermix/cli/daemon.ex`

---

## 3. Current State, Verified

| Component | Behavior today | Design impact |
|---|---|---|
| Disk discovery | `SkillRegistry` scans bundled `priv/skills`, `~/.fermix/skills`, and `~/.fermix/skills/_plugins`. | Keep this source of truth. |
| Trust | Path classification returns `:operator` for bundled/local skills and `:guest` for plugin/outside roots. | The design must use `:operator` / `:guest`, not `:core` / `:local` / `:third_party`. |
| Description | `SKILL.md` frontmatter has `description`, but `AgentDefinition` currently does not store it. | Store `description`; the catalog must not derive descriptions from `system_prompt`. |
| Capability registration | `SkillRegistry` registers each skill as `%Capability{kind: :skill}`. | Stop per-skill capability registration. Replace it with `skill_view` and `skill_run`. |
| Main Agent cache | `available_skills` is loaded at init, then `runtime_context` caches generated prompt profiles after the first message. | Reload must update skills and invalidate `runtime_context`. |
| Realtime prompt | `prompt_opts/1` hardcodes `available_skills: []`. | Realtime must load a session skill snapshot. |
| Realtime tools | Capabilities are converted to OpenAI Realtime tools. | Realtime should receive `skill_view` and `skill_run`, not one tool per skill. |
| CLI daemon RPC | Control socket has no skills method. | Add explicit `skills_list`, `skills_reload`, and `skills_view` RPCs. |
| Skill create | `skill_create` is a built-in agent tool, not a CLI command. | Do not claim CLI create exists. If added later, share the scaffold writer. |
| MCP | MCP tools register as `%Capability{kind: :mcp}` through MCP code, not `SkillRegistry`. | MCP remains a capability source, not a skill source. |

---

## 4. Design Principles

1. **Copy the proven progressive-disclosure model.** OpenClaw puts a compact skill catalog in the system prompt and makes the model read the matching `SKILL.md` only when needed. Fermix should do the same.
2. **Do not depend on provider-native skill fields.** OpenClaw does not pass skill descriptions through a special provider parameter. Cross-provider behavior should be prompt text plus normal function tools.
3. **Separate instructions from executable tools.** A skill is an instruction package. A capability is an executable tool exposed to the provider.
4. **Keep provider tool schemas stable.** Adding a local skill should not add a new provider function name. Provider tool lists should change only when executable capabilities change.
5. **Preserve delegation.** Removing per-skill provider tools must not remove Fermix's existing sub-agent execution path; `skill_run` is part of M7.3.
6. **Reload must be complete.** Registry reload, Main Agent skill cache, and runtime prompt cache must update in one operation.
7. **Realtime gets session snapshots.** A new voice session sees the latest catalog. An active voice call keeps the snapshot it started with unless a future live session update is implemented.

---

## 5. Proposed Architecture

### 5.1 Skill Registry Snapshot

`SkillRegistry` remains the only disk scanner.

Skill names use one rule everywhere:

```text
^[A-Za-z0-9_-]{1,64}$
```

The current regex already allows only letters, digits, `_`, and `-`; M7.3 adds the 64-character cap so names remain safe in prompts, logs, and any optional provider tool wrapper.

Extend the loaded skill definition with a required frontmatter `description`:

```elixir
%AgentDefinition{
  name: "repo_triage",
  description: "Investigate failing repo tests and propose a fix.",
  system_prompt: "...full SKILL.md body...",
  source_path: "/Users/.../.fermix/skills/repo_triage/SKILL.md",
  trust: :operator,
  allowed_tools: nil,
  policy: nil
}
```

Do not introduce a separate `SkillDefinition` struct in M7.3. `AgentDefinition` already carries the execution fields used by sub-agents. A separate struct can be split later if Fermix supports non-agent skill packages.

Missing or blank `description` is a discovery error. Bundled skills must be migrated to include it; do not synthesize catalog descriptions from the first paragraph of `system_prompt`.

Skill names must not collide with executable capability names. A skill whose name matches a built-in or MCP tool fails discovery and appears in the structured `reload/1` errors list. Do not log-and-accept and do not auto-rename.

Add a versioned snapshot API:

```elixir
SkillRegistry.snapshot(server)
#=> {:ok, %{version: 4, skills: [%AgentDefinition{}], errors: []}}
```

`SkillRegistry.reload/1` should return a structured reply:

```elixir
{:ok,
 %{
   version: 5,
   skills: [%AgentDefinition{}],
   added: ["repo_triage"],
   removed: ["old_skill"],
   changed: ["research"],
   errors: []
 }}
```

The registry still logs detailed parse/read errors. The CLI prints a count and can show full details in `--json`.

### 5.2 Prompt Catalog

Replace the current catalog line:

```text
- name: capabilities=...; tools=...
```

with a compact, provider-neutral catalog:

```xml
<skills>
  <skill name="repo_triage" trust="operator" path="/Users/sujshe/.fermix/skills/repo_triage/SKILL.md">
    Investigate failing repo tests and propose a fix.
  </skill>
</skills>
```

Runtime instructions must say:

- Use the catalog only to decide whether a skill is relevant.
- Before following a skill, call `skill_view` with the skill name.
- Do not infer detailed behavior from the description alone.
- Use supporting files only if the loaded `SKILL.md` asks for them.

The compact catalog intentionally omits `capabilities` and `allowed_tools`. The model must call `skill_view` before it can see execution details or instructions.

Catalog rendering is sorted by skill name and bounded by `skills.catalog_max_bytes`, default `16_384`. If the cap is exceeded, render as many complete skill entries as fit and append an omitted count. Do not partially render XML entries.

Catalog visibility is no longer derived from `%Capability{kind: :skill}` because those capabilities go away in M7.3. `RuntimeContext.build_profile/4` passes the profile trust into `RuntimeSections.build/2`; operator profiles receive the skill catalog, and guest profiles receive `- none loaded` in M7.3 to preserve today's guest behavior.

**Render order and prompt-surface cleanup.** The runtime section assembles in this fixed order: (1) runtime contract, (2) capability catalog, (3) skill catalog. The four progressive-disclosure instructions above live inside the runtime contract — not inside the `<skills>` block — so the model sees them whether or not skills are loaded. M7.3 also rewrites three other surfaces that still teach the old skill-as-capability model:

- `RuntimeSections.runtime_contract/0` (`apps/fermix_core/lib/fermix_core/prompt/runtime_sections.ex:96-108`). Drop *"Pick a skill capability by name when a specialized skill is a better fit than handling the work directly."* (no skill capabilities exist after M7.3) and *"Runtime capability snapshots change only after process restart."* (`fermix skills reload` updates `runtime_context` without restart — §5.6). Replace with the four `skill_view`-based instructions and one line naming `skill_run` as the delegation entry point.
- `apps/fermix_core/priv/templates/agents.md.eex:7`. Drop the same *"Pick a skill capability by name"* line. This template is rendered by `skill_create`, so newly scaffolded skills would otherwise inherit obsolete advice from day one.
- `apps/fermix_core/priv/skills/self_knowledge/SKILL.md`. Rewrite the sentences that frame skills as registry-resident capabilities (notably *"installed skills"* in the capability-registry sentence on line 15, and *"Spawn skill sub-agents when a specialized skill is a better fit"* on line 37) to describe the catalog → `skill_view` → optional `skill_run` flow. The skill's existing evals (`priv/skills/self_knowledge/evals/evals.json`) gate that the rewrite still answers the prompts they pose.

### 5.3 `skill_view` Tool

Add one built-in capability:

```text
skill_view(name)
```

Behavior:

1. Validate `name` using the same provider-safe skill-name rule used by the registry.
2. Load the skill from `SkillRegistry`.
3. Return `name`, `description`, `trust`, `source_path`, and the full `SKILL.md` body.
4. Enforce `skills.view_max_bytes`, default `65_536`. If the skill body is too large, return a clear tool error and no partial body. Tell the operator to split the skill or move long references into separate files.

Why `skill_view` instead of `file_read`:

- Fermix skills live under `~/.fermix/skills`, while `file_read` goes through sandbox roots. A registry-mediated tool avoids widening filesystem access only to read skills.
- `skill_view` can enforce trust filtering, size caps, and structured output.

`skill_view` is operator-visible only in M7.3. Use `policy_class: :exec` so it stays out of guest tool lists because local skill bodies may contain operator-authored instructions or paths.

`:exec` is the existing operator-only trust gate in `CapabilityRegistry`; M7.3 uses it for `skill_view` instead of introducing a new `:operator_only` or `:skill_admin` policy class.

### 5.4 `skill_run` Tool

Fermix's current advantage over OpenClaw is sub-agent execution. Keep that capability, but expose it as one stable tool instead of one provider function per skill:

```text
skill_run(name, task, context?)
```

Behavior:

1. Validate and load the named skill from `SkillRegistry`.
2. Spawn the existing sub-agent execution path currently behind `FermixCore.Capabilities.Skill.invoke/2`.
3. Enforce the existing max skill recursion depth.
4. Return the sub-agent summary.

This preserves delegation without making provider schemas change every time a user adds or removes a local skill.

`skill_run` is part of M7.3. It replaces the provider-visible per-skill capability path. Like the old skill capability, it uses `policy_class: :exec` and is operator-visible only.

### 5.5 Provider Tool Surface

M7.3 chooses the decisive option: `SkillRegistry` stops registering `%Capability{kind: :skill}` entirely. `skill_view` and `skill_run` look up skills by name from `SkillRegistry`.

Implementation requirements:

1. Remove the `SkillRegistry.sync_capabilities/3` registration path for current skills.
2. On `SkillRegistry.init/1` and `SkillRegistry.reload/1`, unregister stale existing `kind: :skill` capabilities from the capability registry so upgrades do not leave old tools behind.
3. Keep name-conflict validation against executable tool names so a skill cannot share a name with a built-in or MCP tool. This must work in both directions: skill reload fails discovery for skills that collide with currently registered capability names, and MCP tool registration rejects sanitized tool names that collide with the current skill snapshot.
4. Remove the `RuntimeSections.visible_skills/2` dependency on `kind: :skill` capability presence. Skill catalog visibility is trust/profile based.
5. Remove `FermixCore.Capabilities.Skill.from_definition/1` if it becomes unused. If it is temporarily retained for compatibility or tests, it must use `AgentDefinition.description`, not synthesize a description from `system_prompt`.

After this redesign, providers see:

- Built-in executable tools such as `file_read`, `file_write`, `skill_create`, `skill_view`, and `skill_run`.
- MCP tools as `%Capability{kind: :mcp}`.
- No provider-visible function per local skill.

Provider serialization remains standard:

- OpenAI Responses/Codex: flat function tools with `type`, `name`, `description`, `parameters`, `strict`.
- OpenAI Chat Completions: nested `{"type": "function", "function": ...}`.
- Anthropic: `name`, `description`, `input_schema`.
- Realtime: OpenAI Realtime `session.tools`.

Skills are not passed through a provider-specific `skills` parameter in M7.3. If a future provider exposes a stable cross-provider skill API, add that in provider adapters without changing the registry model.

Provider adapters and Realtime `ToolBridge` should not need special skill filtering after this change because `state.capabilities` no longer contains per-skill capabilities. Removing per-skill provider visibility changes operator-trust turns only; guest-trust turns already did not receive the old `:exec` skill capabilities.

### 5.6 Main Agent Reload

Add:

```elixir
MainAgent.reload_skills(server \\ __MODULE__)
```

The handler must:

1. Call `SkillRegistry.reload(state.skill_registry)`.
2. Replace `state.available_skills` from the returned snapshot.
3. Set `state.runtime_context` to `nil`.
4. Return the structured reload summary.

Invalidating `runtime_context` is mandatory. Updating `available_skills` alone is insufficient because `RuntimeContext` caches generated operator/guest prompt profiles after the first message.

In-flight message tasks keep their immutable runtime snapshot. A reload during an active turn does not mutate that task. The next inbound message rebuilds the runtime context using the new skill catalog.

### 5.7 Realtime Voice Parity

Realtime should use the same `RuntimeContext` runtime rendering path as Main Agent rather than maintaining a parallel prompt path.

`SessionServer.init/1`:

1. Loads the latest skill snapshot from `SkillRegistry`.
2. Builds a `RuntimeContext` with those skills and the capability registry.
3. Builds a realtime operator profile with `excluded_categories: [:channel]`.
4. Stores `state.available_skills`, `state.runtime_context`, `state.runtime_profile`, and `state.capabilities`.

The realtime profile's `capabilities` become the source for `ToolBridge.to_openai_tools/1`. The profile's runtime message becomes the source for the Skill Catalog instructions.

`build_session_update_event/1` should assemble instructions from:

```elixir
state.runtime_context.base_messages ++ [state.runtime_profile.runtime_message]
```

Voice sessions are session-scoped. A session started after `fermix skills reload` sees the latest catalog. A long-running active call does not change mid-call in M7.3.

`MainAgent.reload_skills/1` or the daemon-side reload handler should log any active realtime session scopes that now have a stale skill snapshot. This is observability only; M7.3 does not push live `session.update` events into active voice sessions.

### 5.8 CLI and Daemon RPC

Add `fermix skills` with:

```text
fermix skills list [--json]
fermix skills view <name> [--json]
fermix skills reload [--json]
```

Daemon control-socket methods:

```text
skills_list
skills_view
skills_reload
```

CLI behavior:

- `list` prints `name`, `trust`, `description`, and `source_path`.
- `view` prints the same content as `skill_view`, without going through the model.
- `reload` calls `MainAgent.reload_skills/1` so registry, Main Agent cache, and runtime prompt cache update together.
- `--json` emits the full structured reply, including error tuples.

Do not add `fermix skills create` in M7.3 unless explicitly requested. Current create support is the agent tool `skill_create`. If CLI create is added later, extract shared scaffold code and have both CLI and tool call it.

### 5.9 Prompt Cache Impact

Fermix currently has an internal runtime-context cache, not a provider prompt-cache integration for normal text turns.

M7.3 behavior:

- Reload invalidates Fermix's internal `runtime_context`.
- The next Main Agent message rebuilds the compact catalog.
- Full `SKILL.md` bodies do not enter the system prompt, so prompt size stays bounded.
- Provider tool schemas remain stable when skills are added or removed.
- The first provider request after a skill reload can miss provider-side prompt-prefix caches because the compact system-prompt catalog changed. That is acceptable and bounded; the full skill body is still loaded only on demand.

Compared systems:

- Hermes preserves provider prompt cache more aggressively by injecting skills as user messages only when slash-invoked.
- OpenClaw and Codex use automatic discoverability through a compact system-prompt catalog.
- Fermix should choose OpenClaw/Codex behavior because it needs the agent and realtime voice to discover skills without the user typing a slash command.

### 5.10 Restart Impact

After M7.3, `fermix restart` is not required for:

- adding a `SKILL.md`
- editing a skill description or body
- removing a skill
- renaming a skill directory/name

The operator runs:

```text
fermix skills reload
```

`fermix restart` is still required for:

- code changes
- provider adapter changes
- config changes loaded only at daemon boot
- credential/auth changes whose owners cache tokens at process init

---

## 6. Migration Plan

| Step | Change | Verify |
|---|---|---|
| 1 | Add required `description` and the 64-character name cap to `AgentDefinition` parsing. Update bundled skills. | A `SKILL.md` frontmatter description survives `SkillRegistry.list_detailed/1`; missing description and long names fail discovery. |
| 2 | Add `SkillRegistry.snapshot/1` and structured `reload/1` reply with version, diff, and errors. | Registry tests cover add, remove, change, invalid skill, and sorted output. |
| 3 | Add `skill_view` and `skill_run` built-in capabilities. | Tool tests cover valid skill, missing skill, invalid name, operator-only visibility, max-size failure, and sub-agent execution. |
| 4 | Stop registering per-skill `%Capability{kind: :skill}` entries; remove stale skill capabilities on init/reload. | Provider tool tests assert only `skill_view`/`skill_run` are exposed, not one function per installed skill. |
| 5 | Teach MCP capability naming/registration to consult `SkillRegistry.list/1` and reject sanitized names that collide with installed skills. | MCP naming tests cover sanitized MCP name collision with an existing skill. |
| 6 | Change `RuntimeSections.skill_catalog/1` to render compact XML-like entries and skill-use instructions, filtered by profile trust. | Prompt tests assert description/path are present, full body is absent, and guest profile has no skill catalog. |
| 7 | Update prompt contract and bundled prompt content: edit `RuntimeSections.runtime_contract/0`, `priv/templates/agents.md.eex`, and `priv/skills/self_knowledge/SKILL.md` to remove the stale skill-as-capability framing and embed the four `skill_view`-based instructions and the `skill_run` delegation line. | `RuntimeSectionsTest` asserts the contract no longer contains *"Pick a skill capability by name"* or *"snapshots change only after process restart"* and that it includes the four progressive-disclosure instructions plus the `skill_run` line; `self_knowledge` skill evals continue to pass against the rewritten body. |
| 8 | Add `MainAgent.reload_skills/1` and invalidate `runtime_context`. | Main Agent test sends one message to build cache, reloads, then asserts the next prompt uses the new catalog. |
| 9 | Rewire Realtime to build and use a `RuntimeContext` realtime operator profile. | Realtime test asserts voice instructions contain the compact Skill Catalog and tools come from the profile capabilities. |
| 10 | Add daemon RPC and `fermix skills list/view/reload`. | CLI tests cover JSON and non-JSON output, daemon-not-running errors, and reload summary. |

---

## 7. Tests

Required tests:

- `SkillRegistryTest`
  - loads descriptions
  - returns versioned snapshots
  - reports reload diff
  - reports discovery errors in structured form
  - removes stale skills after file deletion
  - fails discovery for a skill named `file_read` because it collides with a built-in capability
  - fails discovery for a skill named after a registered MCP tool
- `McpCapabilityNamingTest`
  - rejects an MCP sanitized name that collides with an existing skill
- `RuntimeSectionsTest`
  - renders compact catalog
  - includes description and source path
  - omits full skill body
  - respects catalog byte cap
  - runtime contract no longer contains *"Pick a skill capability by name"* or *"snapshots change only after process restart"*
  - runtime contract includes the four progressive-disclosure instructions and names `skill_run` as the delegation entry point
  - section assembly order is runtime contract → capability catalog → skill catalog
- `SkillViewTest`
  - validates name
  - returns full body only on explicit view
  - enforces max response size
  - never returns a partial body when the size cap is exceeded
  - handles unknown skill loudly
- `SkillRunTest`
  - validates name
  - invokes the existing sub-agent execution path
  - enforces max skill recursion depth
  - is operator-visible only
- `MainAgentTest`
  - reload updates `available_skills`
  - reload invalidates `runtime_context`
  - next prompt contains the new catalog
  - reload during an active turn leaves the in-flight task on its old runtime snapshot and the next turn uses the new catalog
- `SessionServerTest`
  - voice prompt receives skills from registry snapshot
  - voice tool list contains `skill_view` and `skill_run`
  - voice tool list does not contain one tool per installed skill
  - an active voice session keeps its session skill snapshot after a reload
- `ProviderToolSurfaceTest`
  - OpenAI Responses, OpenAI Chat Completions, Anthropic, and Realtime serializers receive no `%Capability{kind: :skill}` entries
  - provider schemas remain stable when a skill is added or removed
- `SkillsCommandTest`
  - list/view/reload
  - `--json`
  - daemon unavailable

Relevant commands before completion:

```text
mix test apps/fermix_core/test/fermix_core/agents/skill_registry_test.exs
mix test apps/fermix_core/test/fermix_core/prompt/runtime_sections_test.exs
mix test apps/fermix_core/test/fermix_core/tools/skill_view_test.exs
mix test apps/fermix_core/test/fermix_core/tools/skill_run_test.exs
mix test apps/fermix_core/test/fermix_core/agents/main_agent_test.exs
mix test apps/fermix_core/test/fermix_core/realtime/session_server_test.exs
mix test apps/fermix_core/test/fermix_core/providers/provider_tool_surface_test.exs
mix test apps/fermix_core/test/fermix/cli/skills_command_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
```

---

## 8. Deferred

- Filesystem watcher. OpenClaw supports optional watch with debounce. Fermix should first ship explicit reload and a versioned snapshot. A watcher can call the same reload path later.
- `fermix skills create`. Useful, but not required for visibility/reload. Add only by extracting shared scaffold logic from `skill_create`.
- Provider-native skill adapters. Do not build until a target provider surface is stable and useful across Fermix's supported providers.
- Per-conversation skill scoping. M7.3 uses trust and active session capability policy. Fine-grained skill scopes can land after lifecycle is correct.
- Worktree-local skill roots. Current roots are bundled, `~/.fermix/skills`, and plugins. Worktree-local `.fermix/skills` belongs with workspace-boundary work.

---

## 9. Success Criteria

- Main Agent and Realtime both show a compact Skill Catalog when skills are installed.
- Full `SKILL.md` bodies are not included in the system prompt.
- `skill_view` loads the full skill only when explicitly called.
- `skill_run` preserves sub-agent delegation without exposing one provider function per skill.
- `fermix skills reload` updates `SkillRegistry`, `MainAgent.state.available_skills`, and invalidates `MainAgent.state.runtime_context`.
- Removing or renaming a skill on disk, then reloading, removes it from the catalog with no stale prompt entries.
- Provider tool schemas do not grow by one function per installed skill.
- MCP tools remain capabilities and are not part of `SkillRegistry`.
- `fermix restart` is no longer needed for normal skill add/edit/remove workflows.
