# Milestone 4.9: Unified Capabilities — Skills, Tools, MCP, and Provider Adapters

**Status:** Draft
**Date:** 2026-04-28
**Author:** Sujeeth / Aira
**Depends on:** M2 (`AgentSupervisor`, `AgentServer`, `SkillRegistry`), M4.8 (`fermix` CLI surface, daemon)
**References:** `docs/ROADMAP.md` (§Additional Providers, §Skill Management Tools), `apps/fermix_core/lib/fermix_core/tools/registry.ex`, `apps/fermix_core/lib/fermix_core/tools/invoke_skill.ex`, `apps/fermix_core/lib/fermix_core/agents/skill_registry.ex`, [hermes-agent](file:///Users/sujshe/projects/hermes-agent/run_agent.py), [hermes_mcp](https://hexdocs.pm/hermes_mcp), [Anthropic — Equipping agents with skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills), [OpenAI Responses API](https://platform.openai.com/docs/guides/responses)

---

## 1. Problem / Goal

Fermix today has early placeholder skills (`coding-skill`, `research-skill`, `review-skill`) that the main agent invokes through a single bridge tool, `invoke_skill(skill, task, context?)` (`apps/fermix_core/lib/fermix_core/tools/invoke_skill.ex:18`). Those placeholder skills are not the product surface we preserve; the design problem is the bridge shape. A single stringly-typed skill bridge begins to fail as we add real skills, MCP servers, and additional providers.

**Five concrete problems:**

| Problem | Today | Symptom |
|---------|-------|---------|
| Two parallel registries for one concept | `Tools.Registry` (Elixir tool modules) and `SkillRegistry` (markdown sub-agents) | Bridging logic lives in the `InvokeSkill` tool. Adding a third concept (MCP server tools) means a third registry plus more bridges. |
| Skill choice is invisible to the LLM | `invoke_skill`'s `skill` parameter is `type: "string"` with prose example `"such as coding-skill or review-skill"` (`invoke_skill.ex:33`) | The model guesses skill names from prose. Adding a skill requires editing the prose. GPT picks the wrong skill or invents names. |
| Single hard-coded provider, single hard-coded API shape | `Provider` behaviour exists, but only `Providers.OpenAI` implements it, and tools are emitted in the older Chat Completions wrapper shape | New providers have to re-implement tool plumbing from scratch. Adding the OpenAI Responses API means a parallel code path. No translator layer. |
| GPT under-performs at tool use on Chat Completions | `gpt-*` models always go through `/chat/completions` regardless of model family | Fermix gets the worst of OpenAI's tool surfaces for its primary provider. Research-validated: hermes-agent forces every `gpt-*` model onto the Responses API for exactly this reason (`run_agent.py:679`). |
| No MCP integration of any kind | Zero | Fermix is locked to its own tool universe. Cannot consume the rapidly-growing MCP ecosystem (filesystem, github, sentry, search, Notion, etc.). Cannot expose its skills to other agents. |

**Goal of M4.9:** collapse tools, skills, and MCP-server-tools into one **`Capability`** abstraction; expose each capability natively to the LLM through a per-provider **`Adapter`**; route GPT models to the OpenAI Responses API; integrate the MCP ecosystem outbound.

After this milestone:

1. The main agent sees installed skills, MCP tools, and built-ins as **one flat capability list**: `some-skill(task)`, `mcp_github_create_issue(...)`, `shell(cmd)`, etc. Each capability has a first-class name and typed parameter schema.
2. The model picks a skill the same way it picks any tool. The bridge code (load definition, spawn sub-agent, await, journal, return) lives inside the skill capability's `execute/2` and is invisible to the model.
3. The main/root agent owns tool execution. Providers and adapters never run capabilities directly; they only translate provider wire formats into normalized tool calls and format tool results back for provider continuation.
4. Sub-agents receive their own fixed SKILL.md system prompt plus parent-provided task/context. The parent/main agent sees only skill names, descriptions, and parameter schemas; the full selected SKILL.md is loaded only into the spawned sub-agent's system context. Other skills' full prompts are not loaded. The sub-agent's capability set is resolved by Fermix from skill trust + frontmatter, so the main agent does not need to decide which tools a spawned sub-agent may use.
5. `gpt-*` models on `api.openai.com` route to the OpenAI Responses API with `strict: false` function tools. Tool-call continuation uses the API's documented `function_call` / `function_call_output` / `reasoning` item shape (see §4.10). Other model families route to Chat Completions through the same `Adapter` interface.
6. MCP servers configured under `[mcp.servers.<name>]` in `config.toml` start as supervised stdio children at boot. Their tools register as capabilities, namespaced `mcp_<server>_<tool>`. Outbound only — fermix consumes external MCP servers; exposing fermix as an MCP server is deferred.
7. Future provider adapters are additive. Fermix only implements OpenAI in production today, but the route key and adapter boundary are designed now so Anthropic/OpenRouter/Together/Groq can plug in without changing skills, tools, or registries.

**Non-goal:** moving sub-agents off `AgentSupervisor`, adding streaming, or preserving the current placeholder skills as stable product behaviour. Channel ingress, the agent loop shape, and built-in tool execution semantics stay stable. Placeholder skill *names* (`coding-skill`, `research-skill`, `review-skill`) are not preserved as a contract — a Telegram message that previously named a placeholder skill will get an "unknown skill" response after M4.9 unless an installed skill carries the same name.

---

## 2. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| `Capability` struct | P0 | New | Plain data: `%Capability{name, description, parameters, kind, executor, requires_approval?, policy_class, metadata}`. `executor` is `{module, function, extra_args}` — the runtime calls `apply(module, function, [args, context | extra_args])`. Replaces the current `Tools.Tool` behaviour as the lowest-level callable shape. A struct (not a behaviour) because skill and MCP capabilities are constructed from runtime data (SKILL.md frontmatter, MCP `tools/list` responses), not declared at compile time — there's no static module to back them. Built-in tools also become structs at registration time; their `executor` points at the existing tool module's `execute/2`. |
| `CapabilityRegistry` GenServer | P0 | New | Single source of truth for everything the LLM can call. Subsumes `Tools.Registry`. Holds `%Capability{}` structs in an ETS-backed table keyed by `name`. Built-in capabilities registered at app boot; skill capabilities pulled from `SkillRegistry` on register/refresh; MCP capabilities pulled from each MCP client on server-up/down. Returns the capability list the agent loop hands to the provider. |
| `Adapter` behaviour | P0 | New | Per-provider conversion + continuation. `to_provider_tools(capabilities)`, `chat(messages, capabilities, opts)`, `continue(provider_state, tool_results, opts)`, `parse_tool_calls(response)`, `parse_response(response)`. The only place that knows OpenAI-vs-Anthropic-vs-Responses wire shapes. The adapter never executes capabilities. |
| OpenAI Responses adapter | P0 | New | Routes `gpt-*` and `o*` models on `api.openai.com` to `/v1/responses` with `{type: "function", name, description, parameters, strict: false}` tool shape. Implements Responses continuation formatting with `function_call` / `function_call_output` / `reasoning` items keyed by the API-returned `call_id` (deterministic SHA256 hash used only as a fallback when the API doesn't return one). Replaces the current Chat Completions path for OpenAI-direct GPT models. |
| OpenAI Chat Completions adapter | P0 | Refactor | Extract from existing `Providers.OpenAI` into a dedicated adapter module. Used as fallback for OpenAI-compatible providers (OpenRouter, Together, Groq) that don't yet implement Responses. |
| Adapter routing | P0 | New | `Adapter.for_route(%{provider, model, auth_mode, base_url})` returns the adapter module. `:openai_codex` (explicit Codex provider, M4.10) -> `OpenAI.Codex`; OpenAI Direct + `gpt-*`/`o*` -> `OpenAI.Responses`; Anthropic -> `Anthropic.Messages`; OpenRouter / Together / Groq / OpenAI-compatible -> `OpenAI.ChatCompletions`. Unknown combinations raise loud; no silent fallthrough. See §4.8. (M4.10 split Codex into a dedicated SSE adapter so ChatGPT-Plus tool calls work without an API key.) |
| Each-skill-as-tool exposure | P0 | New | Each installed skill registers as its own capability. Parent agent picks by name from the typed capability list. `Capabilities.Skill.invoke/3` spawns the supervised sub-agent — same `AgentSupervisor` + `AgentServer` path used today. |
| Force-skill instruction | P0 | New | When a sub-agent is spawned for skill X, its system prompt is `[skill body] + "\n\nYou are running as the X skill. Use your tools and complete the task: {task}"`. Forces the right behaviour even with global tool inheritance. |
| Sub-agent capability resolution | P0 | New | Sub-agents receive a capability set resolved by Fermix from skill trust level and SKILL.md frontmatter. The main agent chooses the skill/task, not the skill's internal tools. `allowed_tools` remains an explicit override: absent = trust default, `[]` = no capabilities, list = exact allowlist. Recursion depth cap `max_skill_depth: 4` enforced by the skill executor (`Capabilities.Skill.invoke/3`) before spawning the sub-agent — failing fast at the boundary, not after the AgentServer is already up. |
| MCP outbound integration | P0 | New | Add `hermes_mcp` dep. `MCP.Supervisor` boots configured servers as stdio children. `MCP.Capability` wraps each discovered tool. Tool name namespacing: `mcp_<server>_<tool>`. Failures isolated per server (one bad server doesn't break the others). |
| MCP config | P0 | New | `[mcp.servers.<name>]` block in `~/.fermix/config.toml` with `command`, `args`, literal `env`, and `pass_env` names resolved through `[sandbox.env]`. Wizard adds an "MCP servers" review step (informational, no required answers — operator edits TOML). |
| Anthropic adapter scaffold | P1 | New | Implement `Anthropic.Messages` adapter as a real module with `to_provider_tools/1` (input_schema rename) and `chat/3` returning `{:error, :not_implemented}` until tokens land. Tests pin the schema-translation behaviour so the future implementation has guard rails. |
| Per-skill provider override | P1 | New | Add optional `provider` field to skill frontmatter (e.g., `provider: anthropic`). Defaults to global default. Lets `coding-skill` pin Claude even when the main agent is on GPT. Today's `model:` field stays. |
| Telemetry uniformity | P1 | New | `[:fermix, :capability, :exec]` event for every capability execution (builtin, skill, mcp), with `kind` metadata. Replaces the per-tool/per-skill split. |
| Capability policy metadata | P0 | New | Every `Capability` carries `requires_approval?: boolean()` and `policy_class :: :read_only \| :read_write \| :exec \| :network \| :external_api`. Built-ins set sane defaults (`shell` → `:exec`, `file_write` → `:read_write`, `file_read` → `:read_only`, `browser` → `:network`). MCP capabilities default to `:external_api` + `requires_approval?: true` until per-server overrides land. Skill capabilities are `:exec` because they spawn an agent, but the spawned agent's internal capability set is resolved separately. Surfaced now so M10's gate has somewhere to bind. |
| Sub-agent trust policy | P0 | New | `Capabilities.Registry.list/2` accepts `:policy` and `:allowed_tools` filters. For sub-agents, Fermix resolves a default policy from skill trust: core/local skills may inherit broad capabilities; third-party/plugin skills default to a safe read-only set until explicitly trusted or allowlisted. Without this, the moment MCP servers register, every sub-agent transitively gets destructive external tools. Default policy is documented and enforced in tests. |
| Placeholder skill cleanup | P0 | Refactor | The existing placeholder skills are removed or replaced with real skills. M4.9 does not preserve their current frontmatter as a compatibility contract. Tests should cover generic installed skills and at least one fixture skill, not the placeholder names as product behaviour. |

### Non-Goals

| Feature | Reason | When |
|---------|--------|------|
| Inbound MCP — fermix as an MCP server | Outbound (consume external MCP) is the immediate value. Inbound (expose fermix skills to other agents) is a smaller follow-on once outbound is stable and the capability shape is settled. | M10 / M6 |
| Real Anthropic implementation | Token storage, OAuth flow, billing decisions — all out of scope for this milestone. The adapter scaffold makes the path obvious; the implementation lands in the multi-provider milestone. | Multi-provider milestone (post-M10) |
| Streaming sub-agent output | Today's path is sync (parent blocks while sub-agent runs). Streaming changes the AgentLoop contract and the tool result shape. Defer until there's a real UX consumer. | M6 (LiveView dashboard) |
| Skill plugin install CLI | This milestone establishes the registry shape. CLI affordances (`fermix skill add <git-url>`, `fermix skill remove <name>`) are next-step polish. Operators can drop a SKILL.md folder under `~/.fermix/skills/` today. | Follow-on (skill plugins milestone) |
| MCP tool call streaming | Hermes_mcp supports streaming responses; we'll start sync-only. | Follow-on |
| Per-user tool ACLs / approval prompts | M10 governance milestone owns the user-facing approval UI and per-user authorization. M4.9 surfaces the **metadata** (`requires_approval?`, `policy_class`) and enforces static config gates so MCP doesn't ship without a guardrail; the interactive gating UX is M10. | M10 |
| Smart capability pruning | When the registry passes ~30 entries, GPT/Claude tool selection degrades. We'll address with explicit per-agent allowlists for now (already supported via `allowed_tools`). Auto-pruning is a separate optimization. | After M4.9 in production |
| Replacing `SkillRegistry` entirely | `SkillRegistry` keeps its job as the SKILL.md parser, hot-reloader, and definition cache. What changes is that its consumers move from "ask SkillRegistry directly" to "ask CapabilityRegistry, which queries SkillRegistry under the hood". | — |
| Agent-loop redesign | `AgentLoop`, `AgentServer`, `AgentSupervisor`, `MainAgent` keep their current shapes. Only the parameter that crosses into providers changes (from `tools: [map()]` to `capabilities: [Capability.t()]`). | — |

---

## 3. Reference Comparison

Three reference systems shape the design.

### hermes-agent — N-tools, native per-provider, Responses for GPT

[`/Users/sujshe/projects/hermes-agent`](file:///Users/sujshe/projects/hermes-agent) is the closest analogue. Key decisions we adopt:

- **Three API modes, one adapter per mode.** `chat_completions`, `codex_responses`, `anthropic_messages` (`run_agent.py:679–712`). Mode is selected by model+provider at agent construction, not at request time.
- **GPT trick = Responses API routing.** Any `gpt-*` model is forced onto `codex_responses` mode, which calls `/v1/responses` with `{type: "function", name, description, strict: false, parameters}` tool shape (`run_agent.py:3435–3454`). Bypasses the weak Chat Completions tool-calling on GPT.
- **Carry the API's `call_id` and reasoning items across turns.** Hermes preserves the API-returned `call_id` on every `function_call` and re-sends it on the matching `function_call_output` (`run_agent.py:3567–3612`). It also carries `reasoning` items with their `encrypted_content` between turns so the model can resume its chain of thought (`run_agent.py:3674–3685`). Both are mandatory for Responses API correctness, not optimisations. The `_deterministic_call_id` SHA256 helper (`run_agent.py:3457–3467`) is a fallback used only when the API response doesn't include a `call_id` — not the primary mechanism we adopt.
- **Native shapes per provider, no wrapper language.** Tools go to OpenAI as OpenAI shape, to Anthropic as Anthropic shape (`anthropic_adapter.py:779–791` renames `parameters → input_schema`, drops the `function` wrapper). The XML serialisation in `_format_tools_for_system_message` is for trajectory logs, not for the LLM.
- **MCP tools normalize cleanly.** `mcp_<server>_<tool>` prefix, dropped into the same registry, flow through the same per-provider conversion (`mcp_tool.py:1513–1531`). One discovery path, one execution path.

What we **don't** adopt from hermes:

- Their skills are documentation-only (`skills_list` and `skill_view` are content-loading tools). We keep our supervised sub-agent model — when the LLM picks `coding-skill`, a real sub-agent runs in a separate process with its own tool whitelist and timeout. Hermes loads the SKILL.md body into the parent's context and keeps going in the same loop. Both are valid; ours preserves stronger isolation.
- They have no per-skill execution config (`max_iterations`, `timeout_seconds`, `allowed_tools`). We keep ours — they're load-bearing for sandboxing.

### Anthropic Agent Skills — progressive disclosure, prompt-cache placement

The [Anthropic Agent Skills design](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) frames the canonical skill-as-folder pattern (SKILL.md + bundled scripts) and "progressive disclosure": only metadata in the prefix, full body loads when invoked.

Adopted:

- SKILL.md with YAML frontmatter is the on-disk format. (Already shipping.)
- Capability descriptions are short, actionable, and live in the LLM-facing schema — not buried in prose.
- Anthropic-specific cache placement (`cache_control: {type: "ephemeral"}` on the last tool) is implemented by the Anthropic adapter when that lands.

### OpenCode — single skill tool with enum

[opencode.ai/docs/skills](https://opencode.ai/docs/skills/) takes the opposite cut: one `skill` tool, all skill names in the enum, all descriptions in the tool description. Trades off type clarity for tool-count economy.

We chose **each-skill-as-its-own-tool** instead because:

1. Fermix has 3 skills today; even with plugins growing the count to ~20, we stay under the documented degradation cliff (~30 tools).
2. Per-skill parameter schemas may diverge over time (a `code-review-skill` might want a `language: enum` param; a `research-skill` might want `depth: int`). One enum-based meta-tool forces a uniform parameter shape.
3. Per-capability telemetry and audit are simpler when the LLM is naming the capability directly.
4. If we hit the degradation cliff, switching back to a meta-tool is one capability swap — the registry shape doesn't change.

---

## 4. Architecture

### 4.1 Capability shape

`Capability` is a **struct**, not a behaviour. Skills are loaded at runtime from SKILL.md frontmatter; MCP tools are discovered at runtime from `tools/list` responses. Neither has a compile-time module to implement a behaviour. A struct with a runtime `executor` reference fits both natively and works for built-in tools too (their executor is `{ToolModule, :execute, []}`).

```elixir
defmodule FermixCore.Capabilities.Capability do
  @type kind :: :builtin | :skill | :mcp
  @type policy_class :: :read_only | :read_write | :exec | :network | :external_api

  @type executor :: {module(), atom(), extra_args :: list()}

  @type t :: %__MODULE__{
          name: String.t(),                  # LLM-facing, unique across registry
          description: String.t(),           # LLM-facing
          parameters: map(),                 # JSON Schema, LLM-facing
          kind: kind(),                      # internal — telemetry / diagnostics, NOT sent to LLM
          executor: executor(),              # runtime: apply(mod, fun, [args, context | extra_args])
          requires_approval?: boolean(),     # M10 hook — gate before execution
          policy_class: policy_class(),      # M10 hook — coarse-grained classification
          metadata: map()                    # adapter hints, source pointers (mcp server name, skill path)
        }

  @enforce_keys [:name, :description, :parameters, :kind, :executor]
  defstruct [
    :name,
    :description,
    :parameters,
    :kind,
    :executor,
    requires_approval?: false,
    policy_class: :read_only,
    metadata: %{}
  ]

  @spec execute(t(), args :: map(), context :: map()) :: {:ok, term()} | {:error, term()}
  def execute(%__MODULE__{executor: {mod, fun, extra}}, args, context) do
    apply(mod, fun, [args, context | extra])
  end
end
```

**Policy class definitions** (used by §4.6.3's gate; defaults referenced from this table):

| Class | Meaning | Example capabilities |
|-------|---------|----------------------|
| `:read_only` | Reads local state with no observable side effects. | `file_read`, `memory_recall`, `mcp_filesystem_read_file` |
| `:read_write` | Mutates local state inside the operator's machine. | `file_write`, `memory_store` |
| `:exec` | Runs arbitrary local code or commands. | `shell`, `script_runner`, skill capabilities (sub-agent runs arbitrary tools) |
| `:network` | Fetches arbitrary URLs or opens unauthenticated outbound connections — the operator does not need a credential to use it. | `browser`, generic `http_get` |
| `:external_api` | Calls an authenticated third-party service the user holds credentials for. The blast radius is in someone else's account, not the local machine. | `mcp_github_create_issue`, `mcp_slack_send_message`, future calendar/email tools |

The `:network` vs `:external_api` distinction matters because the sub-agent default policies treat them differently: `:local` skills can fetch arbitrary URLs (`:network`) but cannot use the operator's GitHub credential (`:external_api`). If a built-in or MCP tool sits ambiguously between these (e.g., a curl wrapper that *could* hit an authenticated endpoint), classify it `:external_api` — fail closed.

**Constructors per kind** (all return `%Capability{}`):

| Kind | Constructor | Source | `executor` points at |
|------|-------------|--------|----------------------|
| `:builtin` | `Builtin.from_tool_module(Tools.Shell)` | compile-time module | `{Tools.Shell, :execute, []}` |
| `:skill` | `Skill.from_definition(%AgentDefinition{})` | SKILL.md (runtime) | `{Capabilities.Skill, :invoke, [definition]}` |
| `:mcp` | `MCP.from_tool_descriptor(server, descriptor)` | `tools/list` (runtime) | `{Capabilities.MCP, :call_tool, [server_name, original_tool_name]}` |

The LLM sees `name`, `description`, `parameters`. `kind`, `executor`, `requires_approval?`, `policy_class`, `metadata` are internal — used by the registry, telemetry, and the M10 policy gate, never serialised to the model.

### 4.2 Registry shape

```
CapabilityRegistry (GenServer, single instance)
│
├── built-in capabilities  — registered at app boot (Application.start callback)
│                            same wire-up as today's Tools.Registry, but Capability shape
│
├── skill capabilities     — pulled from SkillRegistry on register/refresh
│                            SkillRegistry stays the parser; CapabilityRegistry the consumer
│
└── mcp capabilities       — pulled from MCP.Supervisor on register/server-up
                             refreshed when a new MCP server starts or an existing one's
                             tool list changes
```

Public API:

```elixir
@spec list(GenServer.server()) :: [Capability.t()]
@spec list(GenServer.server(), filter :: capability_filter()) :: [Capability.t()]
@spec find(GenServer.server(), name :: String.t()) :: {:ok, Capability.t()} | :error
@spec refresh(GenServer.server(), kind :: kind() | :all) :: :ok
```

`capability_filter()` supports `:all`, `[allowed_names]`, `{:exclude, [names]}`, `{:kind, :skill}`. Replaces the current `all_tools_for_llm/2` two-arity overloads.

### 4.3 Adapter layer

```
Provider.Adapter (behaviour)
├── chat(messages, capabilities, opts) :: {:ok, provider_turn()} | {:error, reason}
├── continue(provider_state, tool_results, opts) :: {:ok, provider_turn()} | {:error, reason}
├── to_provider_tools(capabilities) :: term()    # provider-native shape
├── parse_tool_calls(response) :: [normalized_tool_call()]
├── parse_response(response) :: provider_turn()
└── supports_streaming? :: boolean()             # for future use

Concrete implementations (this milestone):
├── OpenAI.Responses          — POST /v1/responses, strict: false; formats function_call_output/reasoning continuations by call_id (§4.10)
├── OpenAI.ChatCompletions    — POST /v1/chat/completions, nested function wrapper, OpenAI-compatible providers
└── Anthropic.Messages        — scaffold only, returns {:error, :not_implemented}

Routing:
└── Adapter.for_route(%{provider, model, auth_mode, base_url}) :: module()
    See §4.8 for the full clause table. Unknown combinations raise; no fallthrough.
```

The existing `Providers.OpenAI` module becomes a thin shim over the adapter dispatch and is eventually deleted (see §5).

`provider_turn()` is the normalized shape the `AgentLoop` consumes:

```elixir
%{
  content: String.t(),
  tool_calls: [normalized_tool_call()],
  provider_state: term(),   # adapter-owned continuation state
  usage: usage()
}
```

For Chat Completions, `provider_state` contains the assistant message/tool-call IDs needed to append tool messages. For Responses, it contains the current explicit item list: prior input, `function_call` items, `reasoning` items, and the call IDs needed to build `function_call_output` items. The adapter owns provider-specific continuation state; the `AgentLoop` owns capability execution.

### 4.4 Skill execution flow

```
Main agent loop
│
├── CapabilityRegistry.list(reg, filter)        # returns [Capability.t()]
│
├── Adapter.chat(messages, capabilities, opts)  # provider-native tool shape
│
├── ↩ tool_calls [%{name: "coding-skill", args: %{task: "..."}}]
│
├── For each tool_call:
│   ├── CapabilityRegistry.find(reg, "coding-skill") → %Capability{kind: :skill, ...}
│   │
│   └── Capability.execute(skill_capability, args, context)
│       │
│       ├── executor calls Capabilities.Skill.invoke(args, context, definition)
│       │
│       ├── AgentSupervisor.spawn_agent(definition, parent: self(), …)
│       │     # context.skill_depth incremented; halt if > max_skill_depth
│       │
│       ├── force_skill_prompt = "You are the {name} skill. Complete: {task}"
│       │
│       ├── AgentServer.run_task(pid, task, context_with_force_prompt)
│       │     # sub-agent sees capabilities resolved by:
│       │     #   1. definition.allowed_tools (absent = trust default, [] = none, list = exact allowlist)
│       │     #   2. definition.policy / trust level (see §4.6)
│       │
│       ├── Await with definition.timeout_seconds
│       │
│       ├── Write skill journal entry (PersistencePolicy.write_skill_journal)
│       │
│       ├── LifecycleTelemetry.skill_invoke(...)
│       │
│       └── Return {:ok, %{content: <response>, ...}}
│
└── Append tool result to messages, loop
```

The execution boundary remains the same: the main loop receives a tool call, executes it, appends the result, and continues. The structural difference is that dispatch from `tool_call.name` to "spawn a skill agent" is no longer hard-coded inside `InvokeSkill.execute/2`; it is polymorphic on the capability's `execute/2`. Adding a fourth capability kind (e.g., `Plugin.Capability` for sandboxed Lua/WASM later) is a 1-file addition with no central edits.

#### 4.4.1 Skill prompt and LLM role boundaries

Skill invocation uses progressive disclosure. The main agent never receives the full prompt body for every installed skill.

**Parent/main agent request:**

```elixir
messages = [
  %{role: "system", content: main_system_prompt},
  %{role: "user", content: user_message}
]

tools = [
  %{
    name: "research-digest",
    description: "Research and summarize a topic using web sources.",
    parameters: %{...}
  }
]
```

The parent sees skill `name`, `description`, and `parameters` only. The full `SKILL.md` body is not appended to the parent system prompt and is not sent as hidden context to help the parent choose.

When the parent calls a skill capability, Fermix invokes the skill executor:

```elixir
Capabilities.Skill.invoke(args, context, definition)
```

That executor starts a supervised sub-agent. The selected skill's full `SKILL.md` is loaded into the **sub-agent** system prompt:

```elixir
messages = [
  %{
    role: "system",
    content: """
    <full selected SKILL.md body>

    ---

    You are running as the "research-digest" skill.
    Follow this skill's instructions and complete the assigned task.
    """
  },
  %{
    role: "user",
    content: """
    Task:
    <task argument from parent tool call>

    Parent context:
    <optional context argument>
    """
  }
]
```

Only the selected skill's prompt body is loaded. Other installed skills are visible to the sub-agent only as capability schemas if policy allows them. Denied capabilities are filtered before provider tool-list construction, so an untrusted sub-agent neither sees nor invokes capabilities outside its resolved policy.

The skill prompt itself is instructions and metadata. It does not execute commands automatically. Any side effect described by a skill, such as running a script or calling an API, must happen through an allowed capability (`shell`, `script_runner`, MCP tool, browser, etc.) and remains subject to capability policy, timeout, telemetry, and audit.

### 4.5 MCP integration

```
MCP.Supervisor (Supervisor)
│
└── For each [mcp.servers.<name>] in config.toml:
    ├── MCP.ServerSupervisor (Supervisor, restart: :permanent)
    │   ├── Hermes.Client.Stdio (one client per server, transport: :stdio)
    │   │   ├── command: "npx"
    │   │   ├── args:    ["-y", "@modelcontextprotocol/server-github"]
    │   │   └── env:     %{"GITHUB_TOKEN" => "..."}
    │   │
    │   └── On client up:
    │       ├── tools/list                        # discover server's tools
    │       ├── For each tool:
    │       │   └── CapabilityRegistry.register(MCP.Capability.new(server, tool))
    │       └── On client down:
    │           └── CapabilityRegistry.unregister_kind(:mcp, server)
    │
    └── Failures isolated: one bad server crashes its own subtree only,
        triggers exponential backoff restart, the rest of fermix keeps running.
```

`MCP.Capability.execute/2` calls `Hermes.Client.call_tool/3` against the server's client process and returns the result.

#### MCP capability name sanitization

The OpenAI Responses API rejects tool names that don't match `^[a-zA-Z0-9_-]+$` and caps name length at 64 characters. MCP tool names in the wild include dots (`fs.read_file`), slashes (`gh/create_issue`), camelCase, unicode, and >64-char names. We sanitize at registration time and keep a reverse map for dispatch.

**Algorithm** (`Capabilities.MCP.Naming`):

1. **Compute candidate name.** `prefix = "mcp_#{server_name_sanitized}_"`. `tool_part = sanitize(original_tool_name)`. `candidate = prefix <> tool_part`.
2. **`sanitize/1`:** lowercase; replace any character outside `[a-zA-Z0-9_-]` with `_`; collapse runs of `_` to a single `_`; trim leading/trailing `_` and `-`. Empty result after sanitization → `raise ArgumentError, {:invalid_mcp_name, server, original}` and refuse to register the tool (loud, not a silent skip).
3. **Length cap.** If `byte_size(candidate) > 64`, truncate `tool_part` so the total fits, then append `_<sha256(prefix <> original)[:8]>` for uniqueness. The full original name is preserved in `metadata.original_name` for telemetry and reverse lookup.
4. **Collision detection.** Before registering, look up `candidate` in the existing capability table. If present, the new tool gets a `_<short_hash>` suffix and a `[:fermix, :capability, :mcp_name_collision]` warning telemetry event fires with `{server, original, sanitized, collided_with}`. Two distinct servers exposing the same tool name is the common case (both `filesystem` and `github` may have `read_file`); the `mcp_<server>_` prefix prevents this in practice, but the safety net catches the case where `server_name_sanitized` itself collides (e.g., `fs.local` and `fs-local` both → `fs_local`).
5. **Reverse map.** `Capabilities.MCP.Naming.lookup(sanitized_name) :: {:ok, {server, original_tool_name}} | :error`. Stored in an ETS table keyed by sanitized name. The capability `executor` carries `{server, original_tool_name}` directly in its `extra_args`, so dispatch doesn't pay a lookup cost; the reverse map is for telemetry, error messages, and `fermix mcp list`.

**Examples:**

| Server | Tool name (server-emitted) | Sanitized | Notes |
|--------|---------------------------|-----------|-------|
| `github` | `create_issue` | `mcp_github_create_issue` | unchanged |
| `fs.local` | `read_file` | `mcp_fs_local_read_file` | server name dot → underscore |
| `gh-actions` | `workflow.dispatch` | `mcp_gh_actions_workflow_dispatch` | both segments sanitized |
| `notion` | `search-pages-by-title-or-content-with-pagination-support` | `mcp_notion_search_pages_by_title_or_content_with_pa_a3f1c9d2` | truncated to 64 with hash suffix |
| (collision) | second tool sanitizing to existing name | `<base>_<8char>` | telemetry event fired |

Tests pin every case (collision, truncation, unicode, leading/trailing punctuation, empty-after-sanitize raise, reverse lookup round-trip).



Config shape (`~/.fermix/config.toml`):

```toml
[mcp.servers.github]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
pass_env = ["GITHUB_TOKEN"]                    # resolved through [sandbox.env]
approved = false                               # registered, not exposed to LLM until approved

[mcp.servers.filesystem]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-filesystem", "/Users/sujshe/projects"]
approved = true

[mcp.servers.filesystem.tools.read_file]
policy_class = "read_only"
requires_approval = false
```

The `$env:` prefix lets users reference shell env vars without baking secrets into the TOML.

MCP capability exposure is static-config gated in M4.9. A capability with `requires_approval?: true` is registered for diagnostics and `fermix mcp list`, but it is not exposed to the LLM until config marks the server/tool approved or overrides the tool to `requires_approval = false`. Interactive approval prompts are M10; M4.9 uses explicit TOML configuration only.

### 4.6 Sub-agent capability scope and recursion safety

Sub-agents (`AgentServer` instances spawned by skills) are not free-form prompts generated by the main agent. They are deterministic skill runtimes:

1. Fermix loads the skill's fixed SKILL.md system prompt.
2. Fermix appends the parent-provided task/context as the assignment.
3. Fermix resolves the sub-agent's capability set from skill trust level plus SKILL.md frontmatter.
4. Fermix builds the LLM-facing tool list **after** policy + allowlist filtering. The sub-agent sees only capabilities it may actually invoke — never their schemas as "denied", never the names of other skills' prompt bodies. See §4.4.1 for the full prompt/role boundary.

The main agent's job is to choose the skill and provide the task. It should not carry the burden of deciding which internal tools the sub-agent may use. That decision belongs to Fermix policy and the skill definition.

#### 4.6.1 `allowed_tools` and trust defaults

`allowed_tools` is an explicit override for sub-agent capability scope. It is not the skill discovery mechanism. Skill discovery comes from installed SKILL.md folders; `allowed_tools` answers "once this skill is running, which capabilities can it call?"

M4.9 introduces three states:

| Frontmatter shape | Parsed as | Sub-agent capability filter |
|-------------------|-----------|------------------------------|
| field absent | `nil` | use the default capability policy for this skill's trust level |
| `allowed_tools: []` | `[]` | **no capabilities** — the sub-agent runs with an empty tool list |
| `allowed_tools: ["shell", "file_read"]` | `["shell", "file_read"]` | exact allowlist by capability name, after policy filtering |

Empty list means empty. It must not mean inherit-all; that makes reviews and third-party skill installation too hard to reason about.

**Parser change** (Stage 3, `agents/agent_definition.ex`):

```elixir
# Before
allowed_tools: normalize_string_list(get(attrs, "allowed_tools", []))

# After
allowed_tools:
  case get(attrs, "allowed_tools", :__absent__) do
    :__absent__ -> nil                              # trust-default sentinel
    list when is_list(list) -> normalize_string_list(list)
  end
```

Tests cover all three states explicitly.

**Trust levels** are coarse in M4.9:

| Skill source | Default capability policy when `allowed_tools` is absent |
|--------------|-----------------------------------------------------------|
| `:core` skill shipped by Fermix | broad default set, including built-ins and installed skills |
| `:local` user skill from the user's skills directory | broad default set, because the user installed it locally |
| `:third_party` / plugin skill | safe read-only default until explicitly trusted or allowlisted |

**Trust source detection.** `SkillRegistry` learns trust at scan time and stores it on `AgentDefinition` as `source :: :core | :local | :third_party`. The classification rule:

```elixir
defp classify_source(skill_dir, dirs) do
  cond do
    starts_with?(skill_dir, dirs.core_dir)        -> :core
    starts_with?(skill_dir, dirs.plugin_dir)      -> :third_party
    starts_with?(skill_dir, dirs.local_dir)       -> :local
    true                                           -> :third_party  # fail closed
  end
end
```

The three directories are configured at boot:

| Dir | Default path | Source |
|-----|--------------|--------|
| `core_dir` | `priv/skills` inside the Fermix release (read-only, ships in the binary) | `:core` |
| `local_dir` | `~/.fermix/skills/` (writable, operator-managed) | `:local` |
| `plugin_dir` | `~/.fermix/skills/_plugins/` (writable, plugin CLI manages) | `:third_party` |

Anything outside the three known roots classifies as `:third_party` — fail closed.

**M4.9 reality check.** The plugin install CLI is a §10 follow-on, so on a freshly installed M4.9 system there are zero `:third_party` skills. Day-one practical posture: `:core` skills (whatever ships in the release `priv/skills/`) get the broad-default policy, anything dropped under `~/.fermix/skills/` by the operator gets `:local`, and the `:third_party` tier sits dormant until the plugin CLI lands. The classifier and the trust metadata land now so the policy gate has a stable enforcement point on the day MCP starts exposing destructive tools — not retrofitted later.

**Registry filter** (`Capabilities.Registry.list/2`):

```elixir
def list(reg, opts) do
  reg
  |> list_all()
  |> apply_policy(resolve_policy(opts[:trust], opts[:policy]))
  |> apply_allowlist(opts[:allowed_tools])
end
```

A sub-agent's capability set is a function of `(skill_trust, skill_policy, skill_allowed_tools)` against the **full registry**, not against whatever subset the parent could see. This is intentional: a `:core` skill with `policy: :exec` should reach the same tools regardless of which channel or parent invoked it, otherwise transitive failures (skill works from main agent, fails when chained from another skill) become impossible to reason about. If you later need a parent-bounded mode, add a separate `opts[:parent_visible]` filter; do not let parent scope silently shrink a sub-agent's tools today.

`apply_allowlist/2` is exact:

```elixir
defp apply_allowlist(capabilities, nil), do: capabilities
defp apply_allowlist(_capabilities, []), do: []
defp apply_allowlist(capabilities, names) when is_list(names) do
  name_set = MapSet.new(names)
  Enum.filter(capabilities, &MapSet.member?(name_set, &1.name))
end
```

Loud on shape mismatch, never normalises silently.

#### 4.6.2 Recursion depth cap

`max_skill_depth: 4` (configurable per-skill, default 4). The invocation context carries `skill_depth: integer()`; the skill executor increments it before spawning. If the new depth exceeds the cap, return `{:error, :max_skill_depth_exceeded}` loud — a ToolResult error to the model, a `[:fermix, :capability, :recursion_capped]` telemetry event, no silent degradation.

#### 4.6.3 Sub-agent policy gate

Broad sub-agent access + MCP without a policy gate means: configure one MCP server with destructive tools (e.g., `github_create_issue`, `slack_send_message`) and every sub-agent can transitively reach them. That's not a posture to ship.

Every `Capability` carries `policy_class :: :read_only | :read_write | :exec | :network | :external_api` (defaults set per-kind in §4.1). Sub-agents spawned by a skill apply a policy before the `allowed_tools` filter:

```elixir
@third_party_default_policy [
  allow: [:read_only],
  deny: [:read_write, :exec, :network, :external_api]
]

@local_default_policy [
  allow: [:read_only, :read_write, :exec, :network],
  deny: [:external_api]
]

def list(reg, opts) do
  reg
  |> list_all()
  |> apply_policy(resolve_policy(opts[:trust], opts[:policy]))
  |> apply_allowlist(opts[:allowed_tools])
end
```

A skill that needs more can declare a policy class list in SKILL.md frontmatter. **YAML can't express Elixir atoms**, so the wire format is a string list and the parser does strict string→atom conversion:

```yaml
policy: [read_only, read_write, exec, network]   # bare strings (YAML scalars)
allowed_tools: ["shell", "file_read", "file_write"]
```

Equivalent quoted forms are accepted (`policy: ["read_only", "read_write"]`). Single-class shorthand is also accepted (`policy: exec`).

Parser rule (Stage 3, `agents/agent_definition.ex`):

```elixir
@valid_policy_classes ~w(read_only read_write exec network external_api)a

defp parse_policy(nil), do: nil
defp parse_policy(class) when is_binary(class), do: parse_policy([class])
defp parse_policy(classes) when is_list(classes) do
  Enum.map(classes, fn
    s when is_binary(s) and s in ~w(read_only read_write exec network external_api) ->
      String.to_existing_atom(s)
    other ->
      raise ArgumentError, "invalid policy class #{inspect(other)}; expected one of #{inspect(@valid_policy_classes)}"
  end)
end
```

Anything outside `@valid_policy_classes` raises at parse time — no silent atom creation, no typo tolerance.

`policy:` is a class-level ceiling. `allowed_tools:` is a name-level narrowing filter. If both are present, the sub-agent receives only capabilities allowed by both.

The **main agent** (root, not a sub-agent) skips the sub-agent policy gate by default. It has full registry access modulo any explicit root config. The gate is a sub-agent boundary control: when the root delegates to a skill, Fermix resolves the skill's internal capability set without making the root model micromanage tools.

Tests cover: third-party/default sub-agent cannot call `:exec`/`:external_api`, local trusted sub-agent can call broad built-ins, MCP capabilities denied by default to sub-agents, main agent unaffected, policy + allowlist compose correctly.

Together: skills are installed globally, sub-agent prompts are fixed by their SKILL.md, sub-agent capabilities are resolved by policy, and recursion is bounded loud.

### 4.7 Force-skill instruction

When `Capabilities.Skill.invoke/3` spawns its sub-agent, the AgentServer's effective system prompt is constructed as:

```
[skill_definition.system_prompt]

---

You are running as the "<skill_name>" skill, invoked by your parent agent.
Your assigned task:

<task argument>

<optional: context argument>

Use the tools available to you and complete the task. When finished, return
a concise summary of what was done and any output the parent needs.
```

This is built inside `Capabilities.Skill.invoke/3` and flows through the existing `AgentServer.execute_task/6`. No agent-loop changes. The wording matters: "you are running as" frames the sub-agent's identity around the skill, which empirically improves GPT's adherence to the skill's intent even when the model has access to other skills.

### 4.8 Provider routing — concrete

Routing on model string alone is unsafe. `gpt-4o` on `api.openai.com` should use the Responses API; the same `gpt-4o` model name proxied through a future OpenRouter-style `/v1/chat/completions` endpoint must use Chat Completions even though the model name matches the same prefix. OpenRouter and Together can expose `gpt-*` model names without the Responses API; routing on `"gpt-" <> _` would break those consumers.

The routing key is `{provider, model, auth_mode, base_url}`. Fermix only has an OpenAI provider implementation today, so Stage 2 adds a small `AuthContext`/route-key struct rather than assuming global provider state. Future providers fill the same route key.

```elixir
defmodule FermixCore.Providers.Adapter do
  @callback chat(
    messages :: [message()],
    capabilities :: [Capability.t()],
    opts :: keyword()
  ) :: {:ok, provider_turn()} | {:error, term()}

  @callback continue(
    provider_state :: term(),
    tool_results :: [tool_result()],
    opts :: keyword()
  ) :: {:ok, provider_turn()} | {:error, term()}

  @callback to_provider_tools(capabilities :: [Capability.t()]) :: term()
  @callback parse_tool_calls(response :: term()) :: [normalized_tool_call()]
  @callback parse_response(response :: term()) :: provider_turn()

  @type route_key :: %{
          provider: :openai | :anthropic | :openrouter | :together | :groq | atom(),
          model: String.t(),
          auth_mode: :api_key | :oauth,
          base_url: String.t()
        }

  @spec for_route(route_key()) :: module()
  # M4.10 update: explicit `:openai_codex` provider routes to the SSE
  # Codex adapter. The original M4.9 sketch tied OAuth to `:openai`;
  # that clause is gone. Regular `:openai` is API-key only, and Codex
  # requires the explicit provider.
  def for_route(%{provider: :openai_codex}),
    do: FermixCore.Providers.OpenAI.Codex

  def for_route(%{provider: :openai, model: "gpt-" <> _, base_url: "https://api.openai.com" <> _}),
    do: FermixCore.Providers.OpenAI.Responses

  def for_route(%{provider: :openai, model: "o" <> _, base_url: "https://api.openai.com" <> _}),
    do: FermixCore.Providers.OpenAI.Responses

  def for_route(%{provider: :anthropic}),
    do: FermixCore.Providers.Anthropic.Messages

  # OpenAI-compatible providers that don't expose Responses — explicit, not fallthrough.
  def for_route(%{provider: provider}) when provider in [:openrouter, :together, :groq, :openai],
    do: FermixCore.Providers.OpenAI.ChatCompletions

  def for_route(%{provider: provider, model: model, base_url: base_url}),
    do: raise(ArgumentError,
      "no adapter for #{inspect(provider)} #{model} at #{base_url} — register one or set provider explicitly"
    )
end
```

`AgentLoop.run/1` builds the route key from the active auth/provider config plus the agent's `model` field, then dispatches:

```elixir
adapter = Adapter.for_route(%{
  provider:  auth_context.provider,
  model:     definition.model || global_default_model,
  auth_mode: auth_context.auth_mode,
  base_url:  auth_context.base_url
})
adapter.chat(messages, capabilities, opts)
```

No global "current provider" state — each agent loop's adapter is a deterministic function of `(provider, model, auth_mode, base_url)`. Unknown combinations raise loud rather than fall through to a wrong adapter.

### 4.9 Public surfaces removed

See §5.

### 4.10 OpenAI Responses API — continuation model

The Responses API is item-list, not message-list. A response is `output: [item, item, ...]` and the next request is `input: [previous items + new items]`. Three item types matter for our tool loop:

| Item type | Direction | Required fields | Purpose |
|-----------|-----------|-----------------|---------|
| `function_call` | model → us | `call_id`, `name`, `arguments` (JSON string), `id` (response item id, `fc_…`) | The model is asking us to run a tool |
| `function_call_output` | us → model | `call_id`, `output` (string) | We send the result back, **keyed by the same `call_id` the model emitted** |
| `reasoning` | model → us | `id`, `encrypted_content` | The model's internal CoT for `o*` and reasoning-enabled `gpt-*` models. Must be **carried across turns** unmodified for the chain to resume |

**The loop, concretely:**

1. **Initial request.** `Adapter.chat/3` posts to `/v1/responses` with `input: [{type: "message", role: "user", content: "..."}]` and `tools: [<our schemas>]`.
2. **Parse response.** The adapter iterates `response.output[]` and returns normalized tool calls to `AgentLoop`. It does **not** execute them. It stores provider continuation state containing the previous input, every `reasoning` item, and every `function_call` item carrying `id` and `call_id`.
3. **Execute capabilities.** `AgentLoop` dispatches each normalized tool call through `CapabilityRegistry.find/2` and `Capability.execute/3`. Built-ins, skills, and MCP tools all execute through the same path.
4. **Continuation request.** `AgentLoop` passes the tool results back to `Adapter.continue/3`. The Responses adapter posts to `/v1/responses` with `input` = previous request input + preserved output items + a `function_call_output` item per dispatched call:
   ```elixir
   %{type: "function_call_output", call_id: original_call_id, output: tool_result_string}
   ```
   `call_id` is the model-emitted value from the corresponding `function_call`. We do not invent it. If the API response somehow lacks one (out-of-spec but observed in hermes), fall back to `call_<sha256(name:args:idx)[:12]>`.
5. **Loop until terminal.** The response is terminal when the adapter returns no normalized tool calls. The visible reply lives in the last `message` item's `content[].text`.

**Pseudocode for `AgentLoop` ownership:**

```elixir
defp provider_turn(adapter, messages, capabilities, opts, depth \\ 0) do
  with {:ok, turn} <- adapter.chat(messages, capabilities, opts) do
    continue_until_terminal(adapter, turn, opts, depth)
  end
end

defp continue_until_terminal(_adapter, _turn, _opts, depth)
     when depth >= @max_tool_loop_depth do
  {:error, {:tool_loop_cap_exceeded, depth}}
end

defp continue_until_terminal(adapter, %{tool_calls: []} = turn, _opts, _depth) do
  {:ok, turn}
end

defp continue_until_terminal(adapter, turn, opts, depth) do
  tool_results = execute_tool_calls(turn.tool_calls)

  with {:ok, next_turn} <- adapter.continue(turn.provider_state, tool_results, opts) do
    continue_until_terminal(adapter, next_turn, opts, depth + 1)
  end
end
```

**Pseudocode for the Responses adapter continuation:**

```elixir
def chat(messages, capabilities, opts) do
  input = build_input(messages)
  tools = to_provider_tools(capabilities)

  with {:ok, response} <- post_responses(input, tools, opts),
       {:ok, output_items} <- extract_output(response) do
    parse_turn(response, %{input: input, output_items: output_items, tools: tools})
  end
end

def continue(provider_state, tool_results, opts) do
  outputs = Enum.map(tool_results, &to_function_call_output/1)
  input = provider_state.input ++ provider_state.output_items ++ outputs

  with {:ok, response} <- post_responses(input, provider_state.tools, opts),
       {:ok, output_items} <- extract_output(response) do
    parse_turn(response, %{provider_state | input: input, output_items: output_items})
  end
end
```

Notes:

- `@max_tool_loop_depth` lives in `AgentLoop` (default 30, configurable). Hitting the cap returns `{:error, {:tool_loop_cap_exceeded, n}}` and surfaces as a terminal error to the user. No silent stop.
- `reasoning` items pass through `output_items` unchanged. We never decode `encrypted_content`; we only carry it forward.
- We do **not** use `previous_response_id`. Carrying the explicit item list is what makes the same input cache-stable across turns and lets us reconstruct the conversation server-side (e.g., for trace journals).
- Test fixtures pin every step. See §9 for the OpenAI Responses fixture matrix.

---

## 5. Removal / Deprecation List

Surgical removals once the new path lands. **No deprecation shim** — current skills are placeholders, there are no external skill plugins yet, and no third-party consumers depend on the `invoke_skill` bridge. The transition window is the migration commit.

| File / API | Action | Replacement |
|------------|--------|-------------|
| `apps/fermix_core/lib/fermix_core/tools/invoke_skill.ex` | **Delete entire file** | `Capabilities.Skill.invoke/3` carries the same logic per-skill |
| `apps/fermix_core/lib/fermix_core/tools/registry.ex` | **Delete after migration** | `apps/fermix_core/lib/fermix_core/capabilities/registry.ex` |
| `FermixCore.Tools.Tool` behaviour | **Delete after migration** | `FermixCore.Capabilities.Capability` struct (no behaviour — see §4.1) |
| `Tool.format_for_llm/1` | **Delete** | `Adapter.to_provider_tools/1` (per-provider) |
| `Provider.chat_opts` `tools: [map()]` field | **Replace** with `capabilities: [Capability.t()]` | Adapter does the conversion at the edge |
| `Application.register_tools/0` (`application.ex:117`) | **Refactor** | New `register_builtins/0` registers `Builtin.Capability.wrap(Module)` for each tool module |
| `MainAgent` direct `Registry.all_tools_for_llm/1` calls | **Update call sites** | `CapabilityRegistry.list/2` returning Capability structs; adapter converts at the edge |
| `AgentServer` `Registry.all_tools_for_llm(registry, allowed_tools)` (`agent_server.ex:248`) | **Update call site** | `CapabilityRegistry.list(reg, filter: allowed_tools)` |
| `InvokeSkill` registration in `application.ex:125` | **Delete the line** | Skill capabilities register automatically via SkillRegistry → CapabilityRegistry on boot |
| The string `"such as coding-skill or review-skill"` in `invoke_skill.ex:33` | **Delete with the file** | LLM sees skills as named tools, no prose enumeration needed |

**Files moved/renamed (not deleted):**

| Old path | New path | Reason |
|----------|----------|--------|
| `apps/fermix_core/lib/fermix_core/tools/` | `apps/fermix_core/lib/fermix_core/capabilities/builtin/` | `Tools.Shell` → `Capabilities.Builtin.Shell`; same code, different namespace |
| `apps/fermix_core/lib/fermix_core/agents/skill_registry.ex` | unchanged | Stays as the SKILL.md parser and definition cache |

**Behaviour preserved (no change needed):**

- `AgentSupervisor`, `AgentServer`, `MainAgent`, `AgentLoop` — same shape, only their parameter types change at the edges.
- `SkillRegistry` — keeps its job. Internal consumer of CapabilityRegistry, no longer directly consumed by InvokeSkill.
- `PersistencePolicy.write_skill_journal/2` — unchanged. Called from `Capabilities.Skill.invoke/3` instead of `InvokeSkill`.
- `LifecycleTelemetry.skill_invoke/7` — unchanged signature; called from `Capabilities.Skill.invoke/3` instead of `InvokeSkill`.
- All channel adapters (Telegram, etc.) — unaffected. They go through `MainAgent`, which is unchanged at the surface.
- All authentication (TokenManager, Auth.Store) — unaffected.

**Tests that need updates (count, not rewrites):**

- `apps/fermix_core/test/fermix_core/tools/invoke_skill_test.exs` — replace with `apps/fermix_core/test/fermix_core/capabilities/skill/capability_test.exs`. Same coverage (timeout, success, crash, unknown skill), new entry point.
- `apps/fermix_core/test/fermix_core/tools/registry_test.exs` — replace with `…/capabilities/registry_test.exs`. Same coverage (register, lookup, list, allowed_tools filter), new module.
- `apps/fermix_core/test/fermix_core/providers/openai_test.exs` — split into `…/openai/responses_test.exs` and `…/openai/chat_completions_test.exs`. Same coverage per shape.
- `apps/fermix_core/test/fermix_core/agents/agent_server_test.exs` — update `Registry.all_tools_for_llm` mocks to `CapabilityRegistry.list`.
- New: `apps/fermix_core/test/fermix_core/providers/adapter_test.exs` — covers the full `for_route/1` matrix (§4.8).
- New: `apps/fermix_core/test/fermix_core/capabilities/mcp/supervisor_test.exs` — covers MCP server start, tool registration, server crash isolation. Uses an in-process stub MCP server (no external `npx`).

---

## 6. Implementation Stages

Phased so each stage is independently shippable and reversible. Compile + tests + credo green between every stage.

### Stage 1 — Capability struct and registry (no behaviour change)

- Add `FermixCore.Capabilities.Capability` struct (see §4.1) — `name`, `description`, `parameters`, `kind`, `executor`, `requires_approval?`, `policy_class`, `metadata`.
- Add `FermixCore.Capabilities.Registry` GenServer (ETS-backed table keyed by name).
- Add `FermixCore.Capabilities.Builtin.from_tool_module/1` that wraps existing `Tools.Tool` modules into `%Capability{kind: :builtin, executor: {Module, :execute, []}}`. **Old `Tools.Registry` keeps running unchanged.**
- Both registries co-exist. `CapabilityRegistry` populated from `Tools.Registry` on boot via the wrapper.
- Tests: `CapabilityRegistry` lifecycle, listing, filtering by `:allowed_tools` (all 3 states: `nil`, `[]`, `[names]`), filtering by `:policy`.

**Ship gate:** existing test suite green. No production behaviour change.

### Stage 2 — Adapter behaviour, OpenAI adapters extracted, Responses loop

- Add `FermixCore.Providers.Adapter` behaviour.
- Extract `OpenAI.ChatCompletions` adapter from `Providers.OpenAI`. Identical wire behaviour.
- Add `OpenAI.Responses` adapter. Implements the §4.10 provider continuation formatting (function_call / function_call_output / reasoning items, model-emitted `call_id`, SHA256 fallback), `strict: false` tools, Responses request/response shape. It does not execute capabilities.
- Add `Adapter.for_route/1` routing on `(provider, model, auth_mode, base_url)` — see §4.8. Unknown combinations raise.
- `AgentLoop.run/1` switched to call `Adapter.for_route(route_key).chat/3` instead of `Provider.chat/2`, and to call `adapter.continue/3` after it executes normalized tool calls. Route key built from the new route-key/auth-context struct + agent's `model`. **Tools still converted from old `Tools.Registry` shape — adapter accepts both formats during this stage.**
- Tests: full §9.2 OpenAI Responses fixture matrix (no tool, one tool, multi-tool, reasoning carry-forward, multi-turn, malformed args, missing call_id, loop cap, terminal parsing); per-adapter tool conversion fixtures; full route-key matrix table including the unknown-raise path.

**Ship gate:** OpenAI Direct GPT/o models now run on Responses API; the same model name proxied via OpenRouter still runs on Chat Completions; route-key matrix and Responses fixture matrix green.

### Stage 3 — Skill capability, force-skill prompt, sub-agent capability policy

- Add `FermixCore.Capabilities.Skill` constructor (`from_definition/1`) producing `%Capability{kind: :skill, executor: {Capabilities.Skill, :invoke, [definition]}}`.
- `Capabilities.Skill.invoke/3` carries the existing `InvokeSkill` logic: spawn sub-agent, await, journal, telemetry.
- Force-skill instruction injected into sub-agent system prompt (§4.7).
- **Update `agents/agent_definition.ex` parser** (§4.6.1): `allowed_tools` becomes 3-state — `nil` (trust default), `[]` (none), `[names]` (exact allowlist). Tests cover all three.
- **Add `trust:` and `policy:` fields to `AgentDefinition`** (§4.6.3). `policy:` is an optional class-level ceiling parsed via the strict string→atom mapping (§4.6.3 parser rule); unknown classes raise. `trust:` is derived from source, not from frontmatter — operators can't self-declare `:core`.
- **Implement `SkillRegistry` source classifier** (§4.6.1). Configure `core_dir`/`local_dir`/`plugin_dir` at boot (defaults: release `priv/skills`, `~/.fermix/skills/`, `~/.fermix/skills/_plugins/`). Tag every loaded `AgentDefinition` with `source :: :core | :local | :third_party`; anything outside the three known roots fails closed to `:third_party`. Tests cover each root and the fallthrough case.
- Remove or replace the current placeholder SKILL.md files. New fixture skills used in tests should encode the intended semantics directly instead of preserving placeholder frontmatter.
- `max_skill_depth` cap enforced by `Capabilities.Skill.invoke/3` before spawning the sub-agent (§4.6.2).
- `SkillRegistry` registers all loaded skills as `Skill.Capability` instances in `CapabilityRegistry` on boot.
- **`InvokeSkill` tool kept registered** — both paths exist for one stage.
- Tests: skill via direct capability call, force-skill prompt content, depth cap enforcement, all three `allowed_tools` states, third-party default denies `:exec`/`:network`/`:external_api`, local/core trust gets broad built-in access, policy + allowlist composition.

**Ship gate:** Fixture skills callable both ways with identical journal output. Sub-agent trust/policy gate verified end-to-end. Existing `invoke_skill` tests still pass until Stage 4.

### Stage 4 — Switch over, delete `InvokeSkill`

- Remove `InvokeSkill` from `application.ex:125` registration.
- Delete `apps/fermix_core/lib/fermix_core/tools/invoke_skill.ex`.
- Move `apps/fermix_core/test/fermix_core/tools/invoke_skill_test.exs` to `…/capabilities/skill/capability_test.exs` and update the entry points.
- Update any docs that reference `invoke_skill`.

**Ship gate:** All skills now invoke through Capability path. `invoke_skill` is gone. Telegram → main agent → fixture skill flow exercised end-to-end with logs verified.

### Stage 5 — MCP outbound integration

- Add `hermes_mcp` dependency.
- Add `FermixCore.Capabilities.MCP.Supervisor`, `MCP.ServerSupervisor`, `MCP.Capability`, `MCP.Naming` (sanitizer + reverse map, §4.5).
- `[mcp.servers.<name>]` parsing in `Setup.ConfigStore`.
- Boot supervises configured servers; tools register into CapabilityRegistry as `%Capability{kind: :mcp, policy_class: :external_api, requires_approval?: true}` by default. Registry listing hides approval-required MCP capabilities from LLM exposure until `[mcp.servers.<name>] approved = true` or a per-tool override explicitly clears `requires_approval`. Per-tool overrides live under `[mcp.servers.<name>.tools.<tool>]` blocks.
- `$env:` prefix handling for env var references.
- Tests: stub MCP server (no external `npx`), tool registration, server crash isolation, `$env:` resolution. Naming: collision (two tools sanitizing to the same name → `_<8char>` suffix + telemetry), truncation (>64 char → truncate + hash suffix), unicode/special-char sanitization, empty-after-sanitize raises, reverse lookup round-trip. Default sub-agent cannot reach MCP tools without explicit trust/policy/allowlist configuration.

**Ship gate:** Test stub MCP server's tools visible in CapabilityRegistry with sanitized names; approved/read-only MCP tool callable by the root LLM; unapproved external MCP tool hidden from LLM exposure; crashes don't cascade; default sub-agent policy gate denies MCP by default. Documentation snippet added for `~/.fermix/config.toml` MCP block.

### Stage 6 — Anthropic adapter scaffold + per-skill provider override

- Add `FermixCore.Providers.Anthropic.Messages` module. `chat/3` returns `{:error, :not_implemented}`. `to_provider_tools/1` translates to Anthropic shape (input_schema rename, drop function wrapper). `parse_tool_calls/1`, `parse_response/1` implemented for the documented Anthropic Messages format.
- Tests: schema translation fixtures (capability list → Anthropic tools array); routing test (`for_route(%{provider: :anthropic, ...})` → `Anthropic.Messages`); a single integration test confirming `chat/3` returns `:not_implemented` cleanly.
- Add optional `provider:` field to `AgentDefinition` (default nil = global default).
- `AgentServer.execute_task/6` resolves adapter via `Adapter.for_route(%{provider: definition.provider || auth.provider, model: definition.model || global_default_model, auth_mode: auth.auth_mode, base_url: auth.base_url})`.

**Ship gate:** Schema translator under test. `coding-skill` can declare `provider: anthropic` in frontmatter and routing works (even though chat/3 errors). Path is unblocked for the eventual real implementation.

### Stage 7 — Cleanup

- Delete `apps/fermix_core/lib/fermix_core/tools/registry.ex` (now unused).
- Delete `FermixCore.Tools.Tool` behaviour.
- Move `Tools.Shell`, `Tools.FileRead`, etc. into `Capabilities.Builtin.*` namespace (or keep paths and just rename the behaviour they implement). Decide based on diff cost.
- Delete `Tool.format_for_llm/1`.
- Update `Provider.chat_opts` typespec: `tools: [map()]` → removed; capabilities flow via adapter, not opts.
- Final pass on `application.ex:117` → `register_builtins/0`.

**Ship gate:** No references to `Tools.Registry` or `Tools.Tool` outside test fixtures. `mix credo --strict` clean. Full test suite green. CHANGELOG updated.

---

## 7. Migration Safety

The single hardest constraint from the user: **don't break anything**. Three principles:

1. **Two-registry overlap during Stages 1–4.** `Tools.Registry` and `CapabilityRegistry` co-exist; `InvokeSkill` and the skill capability path co-exist. The cutover at Stage 4 is the only point where the old registration is removed, and at that point the new path has been exercised by tests for two stages.

2. **Behaviour fixtures pinned.** Before Stage 1, capture the exact request body OpenAI receives for normal chat, one built-in tool call, and one fixture skill call under both Chat Completions and Responses paths. Pin them as integration fixtures. Any unintended divergence in request shape across the migration fails CI loud.

3. **Telemetry continuity.** `[:fermix, :tool, :exec]` is replaced by `[:fermix, :capability, :exec]`, but Stage 1 emits **both** events. Stage 4 drops the old event. Anyone consuming telemetry has one stage of overlap to migrate.

End-to-end smoke test before each ship gate:

```sh
# From a Telegram client to the user
1. Send "use the fixture skill to summarize this task"
   → expect fixture skill invocation in logs
   → expect skill journal entry written
   → expect telemetry event with kind: :skill
2. Send "list the files in /tmp"
   → expect shell capability invocation
   → expect telemetry event with kind: :builtin, name: "shell"
3. (Stage 5+) Send "create a github issue titled 'test'"
   → expect mcp_github_create_issue invocation
   → expect telemetry event with kind: :mcp, name: "mcp_github_create_issue"
```

Same script run after every stage. Failure = stage rejected.

---

## 8. Open Questions

1. **`max_skill_depth` default.** Proposed: 4. That allows main → skill A → skill B → skill C, refuses D. Need a real workflow to validate; might raise to 6 if research workflows need deeper chains.

2. **Per-capability rate limiting.** With MCP servers callable by the root agent and explicitly trusted sub-agents, a runaway loop could DOS an external service. Out of scope for M4.9, but worth flagging — likely lives in M10 (Security & Governance) as a token-bucket per capability per minute.

3. **MCP server hot reload.** First version is "edit `config.toml`, restart fermix". A `fermix mcp reload` CLI command is a small follow-on once the supervisor shape is stable.

4. **OpenAI Responses built-in tools** (`web_search`, `file_search`, `code_interpreter`). The Responses API exposes these natively. Whether to surface them as fermix capabilities (so they're discoverable in the same registry) or keep them adapter-internal is a small follow-on. Defaulting to "not exposed" for v1 so we don't lock core capability semantics to OpenAI-only built-ins.

5. **Hermes_mcp version pin.** Project is at `0.3.5` as of writing. Pin a version in mix.exs and document upgrade path.

6. **Default policy class for unknown MCP tools.** Currently every MCP tool defaults to `:external_api` + `requires_approval?: true`. That is correct for `github_create_issue`; it's pessimistic for `filesystem_read_file`. Hermes-mcp doesn't expose tool side-effect annotations. Per-tool overrides live in `[mcp.servers.<name>.tools.<tool>]` config blocks; the question is whether we ship a curated default classification map for the popular MCP servers (filesystem, github, sentry, slack) or stay strict-and-explicit. Defaulting to strict-and-explicit for v1.

---

## 9. Success Criteria

This milestone is done when:

### 9.1 Behavioural

- [ ] Main agent invokes installed skills as direct named tools — no `invoke_skill` meta-tool in any LLM request.
- [ ] Placeholder skills are removed or replaced; fixture/real skills run through the capability path with journal and telemetry intact.
- [ ] `gpt-*` and `o*` models on `api.openai.com` route to the Responses API; `gpt-*` proxied via OpenRouter/Together still routes to Chat Completions (verified per-route-key fixture).
- [ ] At least one approved MCP server (filesystem, with read-only access to a test directory) configurable via `~/.fermix/config.toml`, callable by the root LLM, crash-isolated; unapproved MCP tools are registered but not exposed.
- [ ] Anthropic adapter scaffold present with full schema-translation test coverage; `for_route(%{provider: :anthropic, ...})` routes to it; `chat/3` returns a clean `:not_implemented` error.
- [ ] Per-skill `provider:` and `policy:` frontmatter fields accepted and honoured.
- [ ] Sub-agent trust policy verified: third-party/default skills cannot reach `:exec` / `:network` / `:external_api` capabilities; local/core trusted skills can receive broad built-in access; `allowed_tools` still narrows by name.
- [ ] MCP capability name sanitization round-trips (collision, truncation, unicode, empty-after-sanitize raise) all green in tests.

### 9.2 OpenAI Responses fixture matrix

Recorded fixtures (replayed via `Req.Test`/`Bypass`) for every step of the Responses loop. Each fixture is a `(request_body, response_body)` pair captured against the live API once and pinned in `apps/fermix_core/test/fixtures/openai/responses/`.

- [ ] **No tool call** — assistant returns a single `message` item; loop terminates on the first response.
- [ ] **One function call** — response output contains one `function_call`; adapter returns a normalized tool call; AgentLoop executes it; continuation request includes the original input + the `function_call` item + a matching `function_call_output` (same `call_id`); second response is a terminal `message`.
- [ ] **Multiple parallel function calls** — single response output contains 3 `function_call` items; adapter returns 3 normalized tool calls; AgentLoop executes them (sequentially, M4.9; parallel is a follow-on); continuation request appends 3 `function_call_output` items in correlation order; assertion that every dispatched `call_id` has exactly one matching output.
- [ ] **Reasoning item carry-forward** — response includes a `reasoning` item with `encrypted_content`; the continuation request input contains the **byte-identical** reasoning item alongside the `function_call_output`; no decoding, no re-encoding.
- [ ] **Multi-turn reasoning chain** — three turns of `function_call → output`, with reasoning items accumulated; assertion that every prior `function_call`, `function_call_output`, and `reasoning` item appears in turn N's input list in original order.
- [ ] **Tool output type coercion** — capability returns a non-string result; adapter coerces to a JSON string for `function_call_output.output` (no nested objects in `output`); fixture pins the wire shape.
- [ ] **Malformed `arguments`** — model emits `arguments` that don't decode as JSON; adapter returns `{:error, {:tool_arguments_invalid_json, call_id, raw}}` to AgentLoop loud; no swallowing.
- [ ] **Missing `call_id`** — synthesised response without a `call_id` triggers the SHA256 fallback (`call_<hash[:12]>`); fixture confirms the fallback path is hit only when the API omits the field.
- [ ] **Tool loop cap** — synthesised "always tool-call" response loops to `@max_tool_loop_depth`; AgentLoop returns `{:error, {:tool_loop_cap_exceeded, depth}}`; depth cap is enforced; no silent stop.
- [ ] **Final response parsing** — terminal response with `message` items containing both `content[].text` and a `finish_reason`; adapter extracts the joined text and the usage tally correctly.

A separate **route-key matrix** test pins every `Adapter.for_route/1` clause (`openai_codex`, OpenAI `:api_key` + `gpt-*` on `api.openai.com`, OpenAI `:api_key` + `o*` on `api.openai.com`, OpenAI-compatible Chat Completions fallback, scaffolded future Anthropic/OpenRouter/Together/Groq routes, unknown-raise).

### 9.3 Hygiene

- [ ] `Tools.Registry`, `Tools.Tool` behaviour, `Tools.InvokeSkill` deleted from the tree.
- [ ] `mix test`, `mix credo --strict`, `mix format --check-formatted` green.
- [ ] `docs/ROADMAP.md` updated to reflect M4.9 status; CHANGELOG entry added.

---

## 10. Out-of-Scope Follow-ons

Concrete next-step milestones this design unlocks but does not deliver:

- **Skill plugin install CLI.** `fermix skill add <git-url>`, `fermix skill remove <name>`, `fermix skill list`. Now feasible because skills are first-class capabilities. ~1 week.
- **Inbound MCP — fermix as MCP server.** Expose every fermix capability over MCP so external agents can use fermix's skills + memory + tools. Requires deciding auth model (token? mTLS?). ~2 weeks.
- **Real Anthropic implementation.** Token storage, OAuth flow, Anthropic Messages `chat/3` body, prompt caching. Adapter scaffold makes the change a 1-file fill-in. ~1.5 weeks.
- **Capability ACL / approval policy.** M10 work. M4.9 surfaces `requires_approval?` so the gating logic has a hook to bind to.
- **Capability rate limiting.** Token-bucket per capability per minute, configurable. M10.
