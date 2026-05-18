# Milestone 4.12: Inbound MCP — Expose Fermix as an MCP Server

**Status:** Draft
**Date:** 2026-05-16
**Author:** Sujeeth / Aira
**Depends on:** M4.9 (`Capability` struct, `CapabilityRegistry`, `Capabilities.MCP.*` outbound, `policy_class`/`hidden_from_agent?` metadata), M4.8 (`fermix` CLI dispatch, daemon control socket), M3 (Phoenix endpoint, `FermixWebWeb.Router`)
**Blocks:** anything that needs Claude Desktop / Cursor / external-agent access to Fermix capabilities; future M10 security milestone (provides the per-capability authorization surface this milestone exposes).
**Defers to other milestones:** wizard integration (handled by a follow-up to `Setup.Wizard`), full auth model and per-user ACLs (M10 — Security & Governance), inbound resources/prompts (M4.12 ships tools-only).
**References:** `apps/fermix_core/lib/fermix_core/capabilities/mcp/supervisor.ex`, `apps/fermix_core/lib/fermix_core/capabilities/mcp/config.ex`, `apps/fermix_core/lib/fermix_core/capabilities/registry.ex`, `apps/fermix_core/lib/fermix_core/setup/config_store.ex`, `apps/fermix_web/lib/fermix_web_web/router.ex`, `apps/fermix_web/lib/fermix_web_web/endpoint.ex`, `apps/fermix_core/lib/fermix_core/application.ex`, `deps/hermes_mcp/lib/hermes/server.ex`, `deps/hermes_mcp/lib/hermes/server/supervisor.ex`, `deps/hermes_mcp/lib/hermes/server/transport/streamable_http.ex`, `deps/hermes_mcp/lib/hermes/server/transport/stdio.ex`, [`/Users/sujshe/projects/hermes-agent/mcp_serve.py`](file:///Users/sujshe/projects/hermes-agent/mcp_serve.py) (closest analogue — Python `hermes mcp serve` exposing a curated MCP tool surface over stdio), [Peekaboo MCP server](https://github.com/steipete/peekaboo), [MCP Streamable HTTP spec](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http)

---

## 1. Problem / Goal

M4.9 delivered **outbound MCP**: Fermix consumes external MCP servers (filesystem, github, etc.) and surfaces their tools as `%Capability{kind: :mcp}` entries in the unified `CapabilityRegistry`. Outbound is one half of the integration story. The other half is **inbound MCP** — letting external MCP clients (Claude Desktop, Cursor, ChatGPT desktop, in-house agents) consume Fermix's capabilities the same way they consume peekaboo, filesystem-mcp, or any other ecosystem server.

Concretely:

- A user running Claude Desktop adds Fermix to `claude_desktop_config.json`. Out of the box they get `file_read`, `file_write`, `memory_recall`, `memory_store`, and the rest of the read-only/read-write built-in catalog as Claude-callable tools. Adding `shell`, scheduled-job control, or a specific installed skill is one per-tool TOML block each — opt-in by name.
- A team running Cursor points the editor at Fermix's HTTP MCP endpoint and the in-editor agent can ask Fermix to recall prior conversations or invoke an explicitly-opted-in skill.
- A separate Fermix instance, or any third-party agent that speaks MCP, can call into Fermix without inventing a Fermix-specific protocol.

M4.9 (§Non-Goals) explicitly deferred this: *"Inbound MCP — fermix as an MCP server | Outbound … is the immediate value. Inbound … is a smaller follow-on once outbound is stable and the capability shape is settled."* That follow-on is now in scope: outbound has been shipping for two minor versions, the `Capability` shape is settled, `policy_class` / `hidden_from_agent?` metadata exist, and the operator pain ("I have skills and memory in Fermix but my coding agent can't see them") is concrete.

**Goal of M4.12:** ship a single Hermes-backed MCP **server** that exposes a filtered, policy-gated view of `CapabilityRegistry` as MCP tools over either stdio (peekaboo-style, for Claude Desktop / Cursor / local clients) or streamable HTTP (network clients), reuses the existing `Capability` policy metadata for access control, persists its config alongside the existing `[mcp.servers.*]` outbound config in `~/.fermix/config.toml`, and emits a `[:fermix, :mcp, :inbound, :call]` telemetry event for every served call.

After this milestone:

1. An operator can add to `~/.fermix/config.toml`:
   ```toml
   [mcp.inbound]
   enabled = true
   transport = "stdio"
   ```
   …and `fermix mcp serve` becomes a Claude-Desktop-compatible MCP server entry point exposing the conservative built-in default set (read-only + read-write file/git/memory ops). Adding individual skills is one TOML block each: `[mcp.inbound.tools.<skill>] exposed = true`.
2. The same operator can flip `transport = "streamable_http"` and the daemon's Phoenix endpoint mounts `/mcp` with bearer-token auth, allowing remote agents to connect.
3. The exposed tool set is a deterministic function of `(CapabilityRegistry contents, kind filter, policy_class filter, allow/deny lists, hidden_from_agent?)`. No capability is exposed by default that the operator did not explicitly invite — fail closed.
4. The outbound→inbound loop is prevented by construction: `kind: :mcp` capabilities are not re-exposed unless the operator explicitly opts in, and there is a documented warning when they do.
5. Every served call writes a telemetry event and a trace entry tagged with the calling MCP client name / version (sent during the MCP `initialize` handshake), the tool name, latency, and result tag — providing the audit trail M10 will later gate on.

**Non-goal in this milestone:**

- Wizard integration. Operators edit TOML by hand. A separate follow-up adds an `Setup.Wizard` step.
- Full user-facing approval UX, per-user ACLs, OAuth, role-based access. M10 owns those; this milestone surfaces *static-config* gates so M10 has somewhere to bind.
- MCP resources (`fermix://memory/...`) and MCP prompts (skill bodies). v1 ships **tools-only**. Resources and prompts are a small follow-on once the tool surface is stable.
- Streaming tool results. Hermes supports streaming responses; we ship sync-only.
- Bidirectional sampling (server-initiated `sampling/createMessage`). Out of scope.
- Multi-tenant inbound (multiple bearer tokens with different capability sets). One token, one cap set, in v1.

---

## 2. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| `FermixCore.MCP.Inbound.Server` (Hermes server module) | P0 | New | A module that `use Hermes.Server, name: "fermix", version: <vsn>, capabilities: [:tools]` and overrides `handle_request/2` to handle **both** `tools/list` and `tools/call` directly — `handle_tool_call/3` is intentionally not implemented. Hermes's default `tools/call` path (`Handlers.Tools.handle_call/3`) looks up the tool name in the registered (compile-time + Frame-registered) tool list and returns "Tool not found" when the name is absent (`deps/hermes_mcp/lib/hermes/server/handlers/tools.ex:30`). Our tool set is runtime data from `CapabilityRegistry`, so we bypass that lookup by handling `tools/call` ourselves and returning the protocol map `%{"content" => [...], "isError" => bool}` directly. Hermes's compile-time `component` macros and `Frame.register_tool/3` are not used. |
| `FermixCore.MCP.Inbound.Exposure` | P0 | New | Pure module that takes the registry contents + inbound config and returns the filtered MCP tool list. Lives outside the Hermes server module so it is unit-testable without spinning a Hermes supervisor. Implements the gate documented in §4.2. |
| `FermixCore.MCP.Inbound.Config` | P0 | New | TOML parser for `[mcp.inbound]` and `[mcp.inbound.tools.<name>]` blocks. Mirrors the shape of `FermixCore.Capabilities.MCP.Config` but for the inbound side. `$env:KEY` resolution reused for `auth_token` references. |
| `FermixCore.MCP.Inbound.Supervisor` | P0 | New | Top-level supervisor that, when `[mcp.inbound] enabled = true`, starts `Hermes.Server.Supervisor` with the configured transport. Added to `FermixCore.Application` between `BuiltinSeeder` / `SkillRegistry` and `McpSupervisor` so the inbound server only starts after the registry is seeded. |
| Stdio transport via `fermix mcp serve` | P0 | New | New CLI dispatch path in `FermixCore.Application` that starts a minimal supervision tree and runs the inbound Hermes server with `transport: :stdio`. Designed for Claude Desktop launching Fermix as a subprocess. Does not bind any network port, does not start channels or the daemon socket. |
| Streamable HTTP transport via Phoenix mount | P0 | New | `FermixWebWeb.Router` **always** mounts `/mcp` forwarded to `Hermes.Server.Transport.StreamableHTTP.Plug` (Phoenix router scopes are compile-time; the runtime TOML cannot decide whether the route exists). The route is fronted by `FermixWebWeb.Plugs.McpInboundAuth`, which checks at request time: (a) `enabled = true` and `transport = "streamable_http"`, else `503 mcp inbound disabled`; (b) valid bearer token, else `401`. The Hermes plug never runs when the gate denies. The supervisor only starts the Hermes server child when the same runtime config is satisfied. |
| Capability exposure filter | P0 | New | `Exposure.expose_for_inbound(capabilities, config) :: [Capability.t()]` applies, in order: (1) `enabled` gate, (2) per-tool override `exposed = true` force-expose (skips remaining filters), (3) per-tool override `exposed = false` force-hide (drops immediately), (4) `expose_kinds` filter (default `[:builtin]` — see §4.2), (5) `expose_policy_classes` filter (default `[:read_only, :read_write]`), (6) `hidden_from_agent?` filter (capabilities requiring approval are dropped — only the per-tool override can let them through), (7) `allowed_tools` exact allowlist if non-empty, (8) `denied_tools` exact denylist. Failing any gate excludes the capability. No partial exposure (a capability either appears in both `tools/list` and `tools/call` or in neither). |
| Per-tool override blocks | P0 | New | `[mcp.inbound.tools.<name>]` with `exposed = true \| false` and `description_override = "..."`. `exposed = true` is the **only** per-tool opt-in — it overrides every kind/policy/approval gate and is the single mechanism for force-exposing a capability that fails the default filters (including skills, `hidden_from_agent?` capabilities, and capabilities the operator wants regardless of kind). `exposed = false` is the only force-hide. No separate `approved` field; one opt-in keyword keeps the gate logic readable. `description_override` lets the operator publish a different description to MCP clients than the LLM-facing one. |
| Bearer-token auth (HTTP) | P0 | New | `auth_token` config key (resolved via `$env:` reference). Plug compares `Authorization: Bearer <token>` against the config value in constant time (`Plug.Crypto.secure_compare/2`). Missing / mismatched token returns `401 Unauthorized` with a single body line; no token enumeration via timing or body content. |
| Outbound→inbound loop prevention | P0 | New | `:mcp` is excluded from `expose_kinds` default. Operators who include it see a `Logger.warning` at startup naming each `mcp_*` capability that would be re-exposed, plus the recommendation to use the upstream MCP server directly instead. No silent loop, no automatic deduplication. |
| Capability listing + execution dispatch | P0 | New | A new `FermixCore.MCP.Inbound.CapabilityPort` behaviour with two callbacks: `list_capabilities() :: {:ok, [Capability.t()]}` and `execute_capability(name, args, context) :: {:ok, payload} \| {:error, term()}`. Two implementations: `Local` (queries `CapabilityRegistry` and calls `Capability.execute/3` in-process) and `DaemonProxy` (sends both list and execute requests over the existing daemon control socket). `Inbound.Server` only ever talks to the port — never directly to `CapabilityRegistry` or `Capability.execute/3` — so daemon-up stdio mode resolves *both* the exposed tool list and the call result against the daemon's registry. Anything less would let the stdio subprocess advertise tools the daemon can't execute, or hide tools the daemon could. |
| `Frame` context propagation | P0 | New | The MCP client's `client_info` (name + version, sent during `initialize`) and session ID are stored in the Hermes `Frame` private state and forwarded into the capability execution context as `mcp_inbound_client: %{name, version, session_id}`. Capabilities that care (audit, rate limiting) can read it. |
| Telemetry | P0 | New | `[:fermix, :mcp, :inbound, :tools_listed]` (per `tools/list`, measurements `%{count: n}`, metadata `%{client_name, client_version, session_id}`). `[:fermix, :mcp, :inbound, :call]` (per `tools/call`, measurements `%{duration_ms}`, metadata `%{tool_name, client_name, client_version, session_id, result :: :ok | {:error, tag}}`). Plumbed through `Trace.record/3` so JSONL traces include the inbound calls. |
| Health surface | P1 | New | `FermixCore.Health.report/0` gains an `:mcp_inbound` block with `enabled?`, `transport`, `exposed_count`, `last_call_ts`. Surfaces via `fermix status` and `fermix doctor`. |
| `fermix mcp list-exposed` CLI | P1 | New | Daemon-socket-backed command that prints the current inbound tool list (with kind, policy_class, description_override-or-original). Mirrors `fermix capabilities` but scoped to the inbound-filtered set. Useful for "why isn't Claude Desktop seeing this tool" diagnosis. |
| Tests | P0 | New | See §9. Hermes server start/stop, stdio E2E with a `Hermes.Client.Base` test client, HTTP E2E via `Plug.Test`, exposure filter matrix, auth plug positive/negative, loop-prevention warning, telemetry event emission, registry change between `tools/list` and `tools/call`. |
| Documentation | P0 | Docs | README snippet showing the Claude Desktop `claude_desktop_config.json` block (`"fermix": { "command": "fermix", "args": ["mcp", "serve"] }`), the Cursor / HTTP equivalent, and the `[mcp.inbound]` config block with sane defaults. |

### Non-Goals

| Feature | Reason | When |
|---------|--------|------|
| Wizard `Setup.Wizard` step | The user explicitly deferred wizard integration ("Will work on the setup module later"). Operator edits TOML directly in v1. | Follow-on to M4.12 (small) |
| Per-user / per-token ACLs | M10's job. A single inbound config = one capability set in v1. M4.12 surfaces the static gates that M10's per-user logic will compose on top of. | M10 |
| OAuth / mTLS | Same reason as above. Bearer-token + bind-127.0.0.1 is the v1 security posture. | M10 |
| Inbound resources (`resources/list`, `resources/read`) | Useful for exposing memory entries, journals, traces as MCP resources. Out of scope to keep this milestone surgical; tools-only is enough to integrate Claude Desktop / Cursor. | Follow-on milestone after tools land |
| Inbound prompts (`prompts/list`, `prompts/get`) | Useful for exposing skill bodies as Claude-Desktop slash commands. Same reason — defer until tool surface is stable. | Follow-on |
| Streaming tool responses | Hermes supports it; LLM tools today don't depend on it. Adding sync-only is one code path; adding streaming + sync is two. | Follow-on if a real client asks |
| Server-initiated sampling (`sampling/createMessage`) | Niche: allowing the inbound MCP client to handle text generation on the server's behalf. No current Fermix workflow needs it. | Never, unless a real workflow surfaces |
| Multiple inbound tokens with different cap sets | Multi-tenant inbound. v1 is one token, one cap set. The shape doesn't preclude multi-tenancy later (a token → policy-class set map is a small extension). | M10 or after |
| `tools/list` change notifications | When operator edits TOML and `Inbound.Supervisor` reloads, broadcasting `notifications/tools/list_changed` would let connected clients refresh. Useful but not required for v1; clients can also resync at next call. | Follow-on |
| Hot-reload of the inbound supervisor on `[mcp.inbound]` config edits | Operator runs `fermix restart` for now. A `fermix mcp inbound reload` daemon-socket method is a small extension. | Follow-on |
| Re-exposing outbound MCP tools by default | See §4.4. Loops are technically loud (warning at startup), but auto-allowing them creates "why am I calling github through fermix-through-github" debug nightmares. Operators opt in explicitly. | Never as default |
| Shipping any default outbound MCP server (peekaboo, filesystem, github, etc.) | M4.12 introduces zero new outbound capabilities. References to peekaboo in this doc are *design-pattern* citations (how Claude Desktop launches a stdio MCP server, §3) — Fermix does not pre-configure peekaboo or anything else. Outbound MCP servers continue to be added by the operator editing `[mcp.servers.<name>]` blocks (the existing M4.9 flow). A `fermix mcp add <spec>` CLI for seamless registration is an obvious follow-on but is out of scope here. | Future outbound CLI follow-on |

---

## 3. Reference Comparison

Three reference points shape the design.

### Outbound MCP (M4.9) — symmetric shape

The existing outbound implementation under `FermixCore.Capabilities.MCP.*` is the closest analogue. Inbound deliberately mirrors:

- **Top-level `[mcp.*]` TOML namespace** (`[mcp.inbound]`, `[mcp.inbound.tools.<name>]`), not nested under `[fermix_core.*]`. Matches the outbound `[mcp.servers.<name>]` convention.
- **`Config` module pattern** — a small purpose-built TOML reader scoped to the inbound block (`FermixCore.MCP.Inbound.Config`), echoing `FermixCore.Capabilities.MCP.Config`. Same `$env:` resolution semantics.
- **`Supervisor + Server + per-thing-isolated-subtree`** — `Inbound.Supervisor` boots Hermes and isolates a crash to the inbound subtree the same way outbound's per-server supervisors isolate one bad MCP child.
- **Reuse of `policy_class` and `hidden_from_agent?`** — the same metadata outbound consumes from the registry, inbound writes through the exposure filter. No new policy primitives.
- **No deprecation churn / no parallel registries** — `CapabilityRegistry` is already the single source of truth; inbound only reads it.

What inbound deliberately does *not* mirror from outbound:

- **No per-server isolation tree.** Outbound runs one supervisor per upstream MCP server. Inbound is one Hermes server module total (Fermix is the single MCP "server" identity), so there's no per-thing fan-out.
- **One port, not a `Discoverer` / `Caller` split.** Outbound separates discovery (`tools/list`) and dispatch (`tools/call`) into two behaviours so per-server tests can stub each independently. Inbound uses a single `CapabilityPort` behaviour (`list_capabilities/0` + `execute_capability/3`) with two impls (`Local` and `DaemonProxy`, §4.1) because the discovery target and the execution target are always the same — either both local in-process or both proxied to the daemon. Splitting them would invite a "list says yes, call says no" drift; keeping them in one behaviour rules that out by construction. Test stubs implement the same single behaviour.

### hermes-agent `mcp_serve.py` — curated stdio surface (Python sibling)

[`/Users/sujshe/projects/hermes-agent/mcp_serve.py`](file:///Users/sujshe/projects/hermes-agent/mcp_serve.py) is the closest analogue to what M4.12 ships. It's the Python sibling project's `hermes mcp serve` entry point — also a stdio MCP server, also launched from `claude_desktop_config.json` via `"command": "hermes", "args": ["mcp", "serve"]` (`mcp_serve.py:19-27`).

What we adopt:

- **The `<binary> mcp serve` CLI shape.** One verb, no required flags, optional `--verbose`. The Claude Desktop config block (`mcp_serve.py:19-27`) is the one we put in our README. Trivially copyable for users coming from hermes-agent.
- **Stdio-as-primary for local clients.** Hermes-agent doesn't ship HTTP transport. We do, but stdio is the default and the only one needed for the Claude Desktop / Cursor onboarding story.
- **Lazy / optional dep handling.** Hermes-agent imports `mcp.server.fastmcp` lazily (`mcp_serve.py:49-55`) so the broader CLI works without the MCP SDK. Fermix has `hermes_mcp` as a hard dep already, so this doesn't apply directly — but we mirror the "stay loud if MCP shape unexpectedly fails" posture by raising at config load (§4.7) and at supervisor boot rather than degrading silently.
- **Read-mostly, writes are explicit and gated.** Hermes-agent exposes nine tools; only `messages_send` and `permissions_respond` are writes, and both are explicitly named (`mcp_serve.py:8-13`). Our default exposure filter mirrors this: `:read_only` + `:read_write` only, no `:exec` / `:network` / `:external_api` without explicit opt-in.

What we deliberately diverge on:

- **Curated tool surface vs. 1:1 capability exposure.** Hermes-agent's nine tools are MCP-tool-level wrappers that don't map 1:1 to internal Python primitives. `conversations_list`, `messages_read`, `events_poll` etc. (`mcp_serve.py:469-857`) are purpose-built MCP-shaped surfaces. They read sessions.json + state.db directly, normalize per-message dicts, and emit MCP-friendly JSON.

  Fermix takes the opposite cut: each `%Capability{}` that passes the filter becomes one MCP tool, 1:1. We do this because:
  1. **Fermix already has a unified `Capability` shape** (M4.9). Hermes-agent's Python doesn't — they had to invent the MCP surface from scratch.
  2. **The Capability shape is already MCP-compatible.** `name`, `description`, `parameters` (JSON Schema) map directly to MCP `Tool { name, description, inputSchema }`. The translation in `Exposure.to_mcp_tool_descriptor/2` is small.
  3. **Skills can become first-class MCP tools.** A skill installed in `~/.fermix/skills/` is *eligible* for exposure with one `[mcp.inbound.tools.<skill>] exposed = true` block; the operator doesn't write a wrapper. (Skills aren't default-exposed because `Capabilities.Skill.from_definition/1` produces `policy_class: :exec`, and `:exec` is not in the default policy gate — see §4.2.) Hermes-agent has no analogue (their skills are markdown-only documentation).

  Curated wrappers (the hermes-agent shape) are a useful **follow-on** — e.g., `fermix_conversations_list`, `fermix_channels_list`, `fermix_journals_list` that read in-process state and expose it as MCP tools the same way hermes-agent does. They're explicitly out of scope for v1 because the 1:1 path already gives Claude Desktop access to memory_recall + memory_store + the skill set, which is the immediate value. See §10.

- **Event polling vs. notifications.** Hermes-agent's `EventBridge` (`mcp_serve.py:204-444`) polls SQLite every 200ms and queues events for `events_poll` / `events_wait` tools, so an MCP client can subscribe to live conversation activity. They built this because the MCP spec's `notifications/*` mechanism isn't well-supported by their target clients yet.

  Fermix doesn't ship this in v1 — the inbound surface is request/response only. Channel events stream into the daemon already; an MCP-side `events_*` tool would just re-shape them. Worth doing as a follow-on once the curated-wrappers question is settled (the two designs converge).

- **State coordination.** Hermes-agent reads `sessions.json` and `state.db` directly from disk, mtime-checks for changes (`mcp_serve.py:352-376`), and re-reads on change. No daemon coordination. Fermix's tools (`memory_recall`, `list_jobs`, every skill) operate on in-process state (`ConversationStore` ETS, `Memory.Repo` GenServer-mediated SQLite, `Jobs.Registry` ETS). Direct-disk reads cannot see that state. That's why §4.3 introduces the daemon-proxy `CapabilityPort` — to share the daemon's in-process state (both the capability list and tool execution). The hermes-agent "just read the files" trick doesn't translate to Fermix's architecture.

- **Approval-request surface.** Hermes-agent's `permissions_list_open` / `permissions_respond` (`mcp_serve.py:823-857`) lets the MCP client observe and respond to internal exec-approval requests. This is M10 territory in Fermix (the user-facing approval UX). Surfacing it as MCP tools is the kind of M10 extension `hidden_from_agent?` was designed to enable, but the policy surface itself doesn't exist yet, so the tools have nothing to wrap. Out of scope.

### Peekaboo — stdio-native, one-process-per-launch (design pattern only)

[Peekaboo](https://github.com/steipete/peekaboo) is a macOS-native MCP server launched by Claude Desktop as a stdio subprocess. Each launch is a fresh process; there's no daemon coordination. It is cited here **only as a design-pattern reference** for how a stdio MCP server gets wired into Claude Desktop's `mcpServers` config — Fermix does not ship peekaboo, does not bundle it, does not pre-configure it, and does not depend on it. The shape we borrow is the launch model (one stdio subprocess per MCP client launch) and the `claude_desktop_config.json` block shape, nothing else.

Adopted from peekaboo:

- **Stdio-as-default for local clients.** Claude Desktop's `claude_desktop_config.json` shape (`"fermix": { "command": "fermix", "args": ["mcp", "serve"] }`) is the primary onboarding path.
- **`fermix mcp serve` is a self-contained CLI invocation.** It does not require the user to have already started the daemon. The user types one line in `claude_desktop_config.json` and Claude Desktop wires up the rest.
- **No required network setup.** Stdio mode binds nothing.

Where Fermix necessarily diverges from peekaboo:

- **Fermix has persistent state** (memory.db, traces, conversation store). A peekaboo-style "spawn a fresh process per Claude Desktop launch" works for stateless tool servers but would clash with Fermix's SQLite write lock if both `fermix run` (the daemon) and `fermix mcp serve` tried to open the same DB in writable mode.
- **Two valid configurations, one path each** (per CLAUDE.md code rule #12):
  - **Stdio mode (`fermix mcp serve`) when the daemon is NOT running**: starts a self-contained supervision tree (CapabilityRegistry, BuiltinSeeder, SkillRegistry, Memory.Repo, Trace) and serves the stdio session. Capabilities that need cross-process state (e.g., `list_jobs`) operate on this process's own state — for a fresh `fermix mcp serve` launch, that's an empty jobs list, which is the honest answer when no daemon is around to own jobs.
  - **Stdio mode when the daemon IS running**: `fermix mcp serve` connects to the daemon control socket and proxies tool execution there. Capabilities resolve against the daemon's CapabilityRegistry; results come back over the socket. State is shared. Detection: `fermix mcp serve` attempts a `status` request on the daemon socket; if it succeeds, proxy mode is used.

  Concretely: `Inbound.Server` routes both `tools/list` and `tools/call` through `Inbound.CapabilityPort`, which has two implementations:
  - `CapabilityPort.Local` — `list_capabilities/0` reads `CapabilityRegistry.list/1`; `execute_capability/3` calls `Capability.execute/3` directly. Used by the daemon's own inbound server (HTTP transport) and by standalone `fermix mcp serve` when no daemon is detected.
  - `CapabilityPort.DaemonProxy` — `list_capabilities/0` sends a `:mcp_inbound_list` request over the existing control socket; `execute_capability/3` sends `:mcp_inbound_execute`. Used by `fermix mcp serve` when a daemon is detected. Both halves go through the daemon so the stdio subprocess never advertises a tool the daemon cannot run, and never refuses one the daemon would happily run.

  The two paths exist because there are two valid runtime configurations (daemon-up vs daemon-down). They are not a fallback chain for one configuration; the `fermix mcp serve` startup deterministically picks one mode and sticks with it. This is the "two valid configurations are fine; two paths to handle one configuration is not" interpretation of CLAUDE.md rule #12. Document and test both.

### MCP spec — Streamable HTTP is the new transport

The [MCP 2025-03-26 spec](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#streamable-http) deprecates pure SSE in favour of "Streamable HTTP", which is what Hermes ships as `Hermes.Server.Transport.StreamableHTTP`. The Hermes module exposes a `Plug` for direct Phoenix integration, which removes the need to spawn a second HTTP listener — the existing `FermixWebWeb.Endpoint` mounts `/mcp` and the same TLS/proxy infrastructure that already serves webhooks serves MCP.

Adopted:

- **Streamable HTTP, not deprecated SSE.** Hermes warns on `:sse`; we route around it by going straight to `:streamable_http`.
- **Phoenix-mounted, not a separate HTTP listener.** `forward "/mcp", Hermes.Server.Transport.StreamableHTTP.Plug, server: ...` in `FermixWebWeb.Router`.
- **Plug-based auth.** The auth middleware is a normal Phoenix plug; reuses the same plug pipeline the rest of the app uses.

---

## 4. Architecture

### 4.1 Module layout

```
FermixCore.MCP.Inbound (new umbrella namespace; NOT under Capabilities.MCP)
│
├── Supervisor              (Supervisor; in fermix_core supervision tree)
│   ├── only starts when [mcp.inbound] enabled = true
│   └── child:
│       └── Hermes.Server.Supervisor with module: Inbound.Server,
│                                          transport: <:stdio | {:streamable_http, opts}>
│
├── Server                  (use Hermes.Server, name: "fermix", version: <vsn>)
│   ├── handle_request/2    — overridden to serve BOTH tools/list and tools/call
│   │                        via CapabilityPort. handle_tool_call/3 is NOT
│   │                        implemented (would not be called — Hermes routes
│   │                        tools/call through its own component lookup, which
│   │                        does not know about our runtime-built tool list).
│   └── init/2              — stores client_info into Frame.private for telemetry
│
├── Exposure                (pure module)
│   ├── expose_for_inbound(capabilities, config) :: [Capability.t()]
│   ├── to_mcp_tool_descriptor(capability, override) :: map()
│   └── refuses to expose :mcp kind unless explicitly opted in (with warning)
│
├── Config                  (TOML parser, mirrors Capabilities.MCP.Config shape)
│   ├── from_toml(contents) :: %InboundConfig{}
│   └── $env: resolution for auth_token references
│
├── CapabilityPort          (behaviour + two impls)
│   ├── @callback list_capabilities() :: {:ok, [Capability.t()]}
│   ├── @callback execute_capability(name, args, context) :: {:ok, payload} | {:error, term}
│   │
│   ├── Local               — list_capabilities ← CapabilityRegistry.list/1
│   │                         execute_capability ← Capability.execute/3
│   │
│   └── DaemonProxy         — list_capabilities ← daemon socket :mcp_inbound_list
│                             execute_capability ← daemon socket :mcp_inbound_execute
│                              (used only by standalone fermix mcp serve when a daemon
│                              is detected — both list and execute go through the daemon
│                              so the stdio process never advertises tools the daemon
│                              cannot execute)
│
└── (no per-server isolation tree — inbound is one server, not N)

FermixCore.Application
│
├── existing children …
│
└── {Inbound.Supervisor, []}    — between MCP outbound supervisor and Repo
                                  starts conditionally on Application.get_env(:fermix_core,
                                  :mcp_inbound, [])[:enabled?]

FermixCore.CLI dispatch
│
├── existing cli_dispatch(["run" | _])    — daemon mode
├── existing cli_dispatch(["setup" | _])  — wizard
└── new      cli_dispatch(["mcp", "serve" | _])
              ├── do not enable endpoint server
              ├── do not enable daemon socket
              ├── do not start channels
              ├── start a minimal supervision tree
              │   (CapabilityRegistry, BuiltinSeeder, SkillRegistry,
              │    Memory.Repo if not daemon-proxied, Trace,
              │    Inbound.Supervisor with stdio transport)
              ├── if daemon detected → CapabilityPort = DaemonProxy
              │   else                  CapabilityPort = Local
              └── block on stdio session lifetime

FermixWebWeb.Router
│
└── ALWAYS mounted (compile-time). Runtime config decides whether the gate opens.
       pipeline :mcp_inbound do
         plug FermixWebWeb.Plugs.McpInboundAuth   # runtime: 503 if disabled, 401 if no auth
       end

       scope "/mcp" do
         pipe_through :mcp_inbound
         forward "/", Hermes.Server.Transport.StreamableHTTP.Plug,
           server: FermixCore.MCP.Inbound.Server
       end
```

### 4.2 Capability exposure filter (the gate)

The exposure filter is a pure function. It runs on every `tools/list` and is re-checked on every `tools/call` (because the registry can change between the two — a new outbound MCP server registering tools, a skill hot-reload, etc.). Re-checking is cheap (one ETS lookup + an in-memory predicate) and fails closed: a tool that was visible on `tools/list` but no longer passes the gate at call time returns the same MCP error the spec uses for "tool not found".

```elixir
defmodule FermixCore.MCP.Inbound.Exposure do
  @moduledoc """
  Pure gate that decides which `%Capability{}` entries are exposed to inbound
  MCP clients. Lives outside the Hermes server module so the rules are unit-
  testable without a supervisor.

  Order of operations (per capability):

    1. Inbound disabled?                                   -> []
    2. Per-tool [mcp.inbound.tools.<name>] exposed = true? -> EXPOSE (skip rest)
    3. Per-tool exposed = false?                           -> DROP
    4. Kind NOT in expose_kinds?                           -> DROP
    5. policy_class NOT in expose_policy_classes?          -> DROP
    6. hidden_from_agent? = true?                          -> DROP
    7. allowed_tools non-empty AND name NOT in it?         -> DROP
    8. denied_tools contains name?                         -> DROP
    9. else                                                -> EXPOSE

  The `exposed = true` per-tool override is the single opt-in keyword.
  It overrides every gate including hidden_from_agent? and policy_class.
  No separate `approved` field — one mechanism, one mental model.
  """

  alias FermixCore.Capabilities.Capability

  # Skills are policy_class :exec (per Capabilities.Skill, line 31). They are
  # intentionally not in the default kind list — exposing every installed
  # skill to inbound clients by default would mean a third-party plugin
  # skill becomes externally-callable on first launch with no operator step.
  # Operators opt skills in one at a time via per-tool exposed = true.
  @default_expose_kinds [:builtin]
  @default_expose_policy_classes [:read_only, :read_write]

  @type config :: %{
          enabled?: boolean(),
          expose_kinds: [Capability.kind()],
          expose_policy_classes: [Capability.policy_class()],
          allowed_tools: [String.t()],
          denied_tools: [String.t()],
          tool_overrides: %{String.t() => tool_override()}
        }

  @type tool_override :: %{
          optional(:exposed) => boolean(),
          optional(:description_override) => String.t()
        }

  @spec expose_for_inbound([Capability.t()], config()) :: [Capability.t()]
  def expose_for_inbound(_capabilities, %{enabled?: false}), do: []
  def expose_for_inbound(capabilities, config) do
    Enum.filter(capabilities, &exposed?(&1, config))
  end

  defp exposed?(%Capability{name: name} = capability, config) do
    case Map.get(config.tool_overrides, name) do
      %{exposed: true}  -> true                          # force-expose, skip every other gate
      %{exposed: false} -> false                         # force-hide
      _                 -> passes_default_gate?(capability, config)
    end
  end

  defp passes_default_gate?(%Capability{} = cap, config) do
    cap.kind in config.expose_kinds and
      cap.policy_class in config.expose_policy_classes and
      not cap.hidden_from_agent? and
      allowlisted?(cap.name, config.allowed_tools) and
      not denied?(cap.name, config.denied_tools)
  end
end
```

Per-tool `exposed = true` is applied **first** and short-circuits every other gate. This is the only way to expose:
- A capability whose `kind` is not in `expose_kinds` (e.g., a skill, which is `kind: :skill`).
- A capability whose `policy_class` is not in `expose_policy_classes` (e.g., `shell` is `:exec`).
- A capability where `hidden_from_agent?: true`.

The "single opt-in keyword" shape (one `exposed = true`, no separate `approved`) keeps the gate logic in §4.2 short and the operator mental model in §4.7 short. An operator who wants to expose `shell` doesn't have to think about `approved`, `policy_class`, and `exposed` as three separate dimensions — they write one line.

#### Per-tool override blocks

```toml
[mcp.inbound.tools.shell]
exposed = true                 # force-expose despite :exec policy_class
description_override = "Execute a shell command on the Fermix host."

[mcp.inbound.tools.research-skill]
exposed = true                 # opt this skill into the inbound surface

[mcp.inbound.tools.file_read]
exposed = false                # force-hide despite passing default gate
```

`description_override` lets the operator publish a cleaner MCP-facing description than the LLM-facing one. Inbound never publishes the `policy_class`, `kind`, or `hidden_from_agent?` fields — those are internal classifiers. The MCP `tool.description` and `tool.inputSchema` are derived from the `Capability`'s `description` (overridable) and `parameters` (not overridable — schema rewriting is M10 territory).

#### Defaults rationale

- `expose_kinds: [:builtin]` — only built-ins by default. **Skills are not default-exposed** because `Capabilities.Skill.from_definition/1` produces `policy_class: :exec` (`apps/fermix_core/lib/fermix_core/capabilities/skill.ex:31`), so they would fail the policy-class gate anyway — and even if they didn't, treating every installed skill as default-public for inbound MCP would mean a plugin skill becomes externally callable as soon as the operator drops a folder under `~/.fermix/skills/_plugins/`. Skills are opted in per-name (one `[mcp.inbound.tools.<skill>] exposed = true` block each). `:mcp` is also excluded by default because re-exposing outbound MCP tools as inbound MCP tools is the loop case (§4.5).
- `expose_policy_classes: [:read_only, :read_write]` — the conservative posture. `:exec` (shell, skills), `:network` (browser, web_fetch), and `:external_api` (anything with a credential) require explicit per-tool opt-in via `exposed = true`.
- `hidden_from_agent?: true` capabilities are hidden by default and only surface through `exposed = true`. The per-tool override is the single approval mechanism.

These defaults mean a brand-new `[mcp.inbound] enabled = true` config exposes exactly:

```
file_read, file_write, file_edit, glob_search, content_search,
git_read, memory_recall, memory_store, list_jobs, tool_help,
memory_sources_list
```

It does NOT expose: shell, browser, web_fetch, web_search, git_write, schedule_job, pause_job, resume_job, remove_job, delegate, skill_create, any installed skill, or any outbound MCP capability. The exposed set is "Claude Desktop / Cursor would reasonably need these without being able to break the host"; everything else opts in one TOML block at a time.

### 4.3 Transport: stdio process (`fermix mcp serve`)

```
Claude Desktop / Cursor / etc.
     │  spawns subprocess with stdin/stdout pipes
     ▼
fermix mcp serve            # new CLI dispatch path
     │
     ├─ Application.start branches on argv (existing pattern)
     ├─ start minimal supervision tree (no channels, no daemon socket, no realtime)
     │     children:
     │       CapabilityRegistry
     │       BuiltinSeeder
     │       SkillRegistry
     │       (Memory.Repo only if no daemon detected — else proxied)
     │       Trace
     │       Inbound.Supervisor with transport: :stdio
     │
     ├─ if daemon detected via control socket probe:
     │     CapabilityPort = DaemonProxy
     │     (both tools/list and tools/call resolve against the daemon's registry;
     │      this process holds no Memory.Repo)
     │
     ├─ else (no daemon):
     │     CapabilityPort = Local
     │     (this process owns its own Memory.Repo on the shared SQLite file —
     │      WAL mode + advisory locks are sufficient for "no concurrent writer"
     │      since the daemon isn't writing; this process's CapabilityRegistry
     │      is seeded by BuiltinSeeder + SkillRegistry on boot)
     │
     ├─ Hermes.Server.Transport.STDIO reads JSON-RPC from stdin, writes to stdout
     ├─ block until stdin closes (Claude Desktop exits)
     └─ on stdin close, supervisor terminates cleanly and the process exits 0
```

#### Stdio I/O safety — stdout is owned by the protocol

The `fermix mcp serve` process speaks JSON-RPC over stdout. **Any** stray byte written to stdout from anywhere in the BEAM corrupts the protocol stream and breaks every MCP session for the lifetime of that process. This is the single most common way a stdio MCP server breaks in production, and it's invisible until a real client connects.

The dispatch path `cli_dispatch(["mcp", "serve" | _])` must take two explicit steps **before** starting the supervision tree, and the codebase must enforce one ongoing convention.

**Step 1 — Replace the `:default` Logger handler with a stderr-only one.** Elixir's `Logger` ships with a `:default` handler whose target depends on the runtime config. Configurations vary across release builds and dev shells, and `iex -S mix` notoriously points it at `:stdio`. Do `:logger.remove_handler(:default)` unconditionally, then add an explicit stderr handler:

```elixir
:logger.remove_handler(:default)

:logger.add_handler(:mcp_stderr, :logger_std_h, %{
  config: %{type: :standard_error},
  formatter: {:logger_formatter, %{single_line: true}}
})
```

The existing file logger (`setup_file_logger/0`) is unaffected — it writes to `~/.fermix/logs/fermix.log` and never touches stdout/stderr.

**Step 2 — Pin the requirement with a regression test.** A startup test runs `fermix mcp serve` against `Hermes.Transport.STDIO`, sends an `initialize` then a no-op `ping`, and asserts:

1. The stdout byte stream parses as a sequence of well-formed JSON-RPC frames (one per response). No "leading garbage," no log lines, no `IO.puts` output.
2. A second variant intentionally triggers `Logger.info("hello from inside capability")` from inside a capability call and re-asserts the same well-formed stdout — the log line must not appear in stdout.

Without this regression test, the next contributor who adds an `IO.puts` for debugging breaks every Claude Desktop session and no one notices until production.

**Codebase convention (not a runtime guard) — `IO.puts/1` and `IO.write/1` are banned in code paths reachable from `mcp serve`.** Bare `IO.puts(text)` and `IO.write(text)` write to the **current process's group leader**, which for the stdio child process is `:stdio` (stdout). There is no clean BEAM mechanism to "redirect the group leader to stderr" — the group leader is itself an IO process, and substituting one writing to stderr would require either an IEx-style `:user_drv` rewrite or a custom IO server, both of which add a non-trivial process to the supervision tree just to compensate for stray prints.

The much cheaper guarantee is:

- All Fermix code uses `IO.puts(:stderr, text)` / `IO.write(:stderr, text)` / `Logger.*` — explicit device argument or the logger.
- A `mix credo` custom check (or a simple `grep` in CI) flags any `IO.puts(_)` / `IO.write(_)` whose first arg isn't `:stderr` or `:stdio` (in modules reachable from `mcp serve`).
- The Step-2 regression test is the runtime safety net if the convention slips.

The same constraint does **not** apply to the daemon's HTTP path — there, stdout is the daemon's normal stdout (used by `fermix run`'s log tail) and no client is parsing it. The constraint is specific to the `mcp serve` dispatch.

#### Daemon detection rule

`fermix mcp serve` calls `Fermix.CLI.Daemon.Client.request("status")` with a short timeout (200ms). Three outcomes:

| Result | Mode chosen | Why |
|--------|-------------|-----|
| `{:ok, %{"status" => "ok"}}` | `DaemonProxy` | A daemon is running on the local user's socket; share its state. Both list and execute go through it. |
| `{:error, :not_running}` | `Local` | No daemon; this process is the only Fermix in the user's session. Open Memory.Repo locally; seed CapabilityRegistry from disk. |
| `{:error, _other}` (e.g., permission denied on socket file) | `Local` with a `Logger.warning` line on stderr | Fall closed to standalone; warn loud. |

Mode is locked in for the lifetime of the stdio session. If the daemon stops mid-session, both `DaemonProxy.list_capabilities/0` and `DaemonProxy.execute_capability/3` return `{:error, :daemon_unavailable}` — both surface as MCP errors to the client. No re-detection, no silent transition to Local.

#### Why not always proxy?

The "always proxy if daemon, else fall closed" approach was considered and rejected because Claude Desktop / Cursor users routinely set up Fermix MCP without bothering to start a daemon. They want it to "just work" for the simple case (file ops, memory, skills) and they pay the cost (no scheduled jobs visible) only for the daemon-coupled tools. The `Local` fallback is the standalone path; it is documented and tested.

#### Why not always standalone?

The `Local`-when-daemon-running case would double-open `~/.fermix/memory.db` for writes. SQLite WAL mode allows multiple processes to read, but only one writer at a time, and the lock contention shows up as unpredictable `SQLITE_BUSY` errors at write time. Proxying through the daemon is the clean answer when the daemon is up.

### 4.4 Transport: streamable HTTP (inside the daemon)

```
Phoenix Endpoint (existing FermixWebWeb.Endpoint, bound to its existing port)
     │
     └── Router (existing FermixWebWeb.Router)
            ├── existing pipelines / scopes …
            │
            ├── new pipeline :mcp_inbound:
            │     plug FermixWebWeb.Plugs.McpInboundAuth
            │     plug :accepts, ["json"]
            │
            └── new scope "/mcp" (ALWAYS mounted at compile time):
                  pipe_through :mcp_inbound
                  forward "/", Hermes.Server.Transport.StreamableHTTP.Plug,
                    server: FermixCore.MCP.Inbound.Server
```

The route is **always present** in the compiled router. Whether it's reachable is a runtime decision made by the auth plug. This matters because Phoenix scopes are macro-expanded at compile time, and a runtime TOML edit cannot grow or shrink the route table. The clean shape is:

1. Mount the route unconditionally.
2. Put a runtime gate in front of it.
3. Let the Hermes plug behind the gate assume "I will only be called when serving is correct."

The Hermes plug owns the wire protocol (session creation, SSE streaming, message dispatch to the server module). Our only contribution at the HTTP layer is the auth plug, which runs *before* the Hermes plug and may halt before Hermes sees the request.

The Phoenix endpoint's existing bind address is reused; the inbound config does not introduce a separate bind. The operator who wants the MCP endpoint reachable from the network sets the endpoint's bind via the existing `FERMIX_BIND` / `PHX_HOST` mechanisms (same as the rest of the web app). The inbound config carries only the auth token, the kind/policy filters, and the path prefix (default `/mcp`).

When the supervisor sees `transport != "streamable_http"` or `enabled = false`, the Hermes server child does not start, so even a request that somehow bypassed the auth plug would land on a dead transport. That's the second line of defense; the auth plug is the first.

#### Auth plug — runtime gate

```elixir
defmodule FermixWebWeb.Plugs.McpInboundAuth do
  @moduledoc """
  Two-stage runtime gate for the inbound MCP HTTP route.

  The route is mounted at compile time. This plug decides per-request:

    1. Is inbound enabled AND configured for streamable_http?
       If no -> 503 with a "mcp inbound disabled" line. Operator can flip
       the TOML and restart without recompiling the router.

    2. Does the request carry a valid bearer token?
       If no -> 401 with a single body line. Constant-time compare via
       Plug.Crypto.secure_compare/2; no enumeration via timing or shape.

  Misconfiguration (HTTP enabled, no token) fails closed at boot via
  Inbound.Config.from_toml/1 raising ArgumentError. The runtime arm of this
  plug carries a defense-in-depth check for live config edits between boots.
  """

  import Plug.Conn

  alias FermixCore.MCP.Inbound.Config, as: InboundConfig

  def init(opts), do: opts

  def call(conn, _opts) do
    config = InboundConfig.current()

    cond do
      not config.enabled? ->
        disabled(conn, "mcp inbound disabled\n")

      config.transport != "streamable_http" ->
        disabled(conn, "mcp inbound transport is not streamable_http\n")

      true ->
        check_auth(conn, config.http.auth_token)
    end
  end

  defp check_auth(conn, nil), do: deny(conn)
  defp check_auth(conn, expected) when is_binary(expected) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> given] ->
        if Plug.Crypto.secure_compare(given, expected),
          do: conn,
          else: deny(conn)

      _ ->
        deny(conn)
    end
  end

  defp disabled(conn, body), do: conn |> send_resp(503, body) |> halt()
  defp deny(conn), do: conn |> send_resp(401, "unauthorized\n") |> halt()
end
```

The 503-vs-401 split is intentional. 503 tells an operator's monitoring "this is off by config"; 401 tells the client "wrong credential." Conflating them would hide misconfig under a generic auth failure.

The `auth_token` value is resolved via the existing `$env:` mechanism:

```toml
[mcp.inbound.http]
auth_token = "$env:FERMIX_MCP_INBOUND_TOKEN"
```

Operators rotate the token by changing the env var and restarting the daemon. Token rotation without restart is a follow-on (it requires a small config-reload daemon socket method).

#### Bind address

The default is **don't expose the endpoint to the network**. The existing Phoenix endpoint config already binds to whatever `PHX_HOST` / `FERMIX_BIND` is configured for — most installations bind to 127.0.0.1. M4.12 explicitly does not change that; the operator who wants `0.0.0.0` exposure flips the existing endpoint config, and inherits the auth gate by virtue of pipelining through `:mcp_inbound`. There is no inbound-MCP-specific bind override, because two bind controls for one process is a code smell.

The startup logs include a single line:

```
[info] MCP inbound (streamable_http) listening on <bind>:<port>/mcp (auth: bearer)
```

…so the operator can verify what's reachable.

### 4.5 Loop prevention

```
operator                                            external MCP server
  │                                                       │
  │  configures   [mcp.servers.github]                    │
  │  outbound     command = "npx ..."                     │
  │ ───────────────────────────────────────────────────► │
  │              (M4.9 path: Fermix consumes GitHub)      │
  │                                                       │
  │  configures   [mcp.inbound] expose_kinds = ["mcp"]    │
  │  inbound      ← DANGER                                │
  │                                                       │
Claude Desktop / Cursor                                    │
  │                                                       │
  │  tools/list  ─►  Fermix (Inbound.Server)              │
  │              ◄─  mcp_github_create_issue, ...         │
  │                                                       │
  │  tools/call mcp_github_create_issue                   │
  │              ─►  Fermix → Hermes outbound client      │
  │                                                       │
  │                  Hermes outbound client ─────────────►│
  │                                            create_issue
```

Concretely, exposing outbound MCP tools as inbound MCP tools means external clients call through Fermix as a passthrough. That's:

1. **A loop hazard** if the external client *is itself a Fermix instance configured to consume our endpoint*. A pings B pings A on every tool call.
2. **An observability hazard.** A `github_create_issue` call logged by Fermix shows up as an inbound MCP call (Claude Desktop client) and an outbound MCP call (Fermix → github npx subprocess). Two trace entries for one logical action, and the connecting thread (session ID) lives only in the inbound side. Debugging "who actually called this" is harder.
3. **A capability-attribution problem.** The Claude Desktop user thinks they're talking to "fermix". They are. But the actual side effect happens in `github_create_issue`'s subprocess, with the `GITHUB_TOKEN` Fermix injects into the outbound `[mcp.servers.github]` process via `pass_env`. The credential boundary is fuzzier than the operator may expect.

**M4.12's posture**: don't ship this as a default. Operators who want it write:

```toml
[mcp.inbound]
expose_kinds = ["builtin", "skill", "mcp"]
```

…and on boot, `Inbound.Supervisor` logs:

```
[warning] MCP inbound: re-exposing outbound MCP capabilities. The following
[warning] mcp_* tools are now visible to inbound clients:
[warning]   mcp_github_create_issue, mcp_filesystem_read_file, ...
[warning] If your inbound client is itself an MCP-consuming agent that talks
[warning] to the upstream server directly, this creates a Fermix-as-proxy
[warning] indirection that obscures call attribution. Consider whether the
[warning] inbound client should talk to the upstream server directly.
```

The warning is loud, structured, and emits on every supervisor start (not just first run) so the operator sees it in logs and `fermix doctor`.

### 4.6 Server module — handling tools/list and tools/call directly

`Hermes.Server.Base` calls `module.handle_request/2` for every MCP request. The compiled default (from `Hermes.Server.__before_compile__`) routes `tools/list` and `tools/call` to `Hermes.Server.Handlers.Tools`, which looks up the tool name in the compile-time component list + the per-frame registered tools (`deps/hermes_mcp/lib/hermes/server/handlers/tools.ex:14, 28`). Our tools come from `CapabilityRegistry` at request time — they're never registered via `Frame.register_tool/3` or the `component` macro — so the default routing returns "Tool not found" for every call.

The fix is to override `handle_request/2` for **both** `tools/list` and `tools/call` and never fall through to Hermes's tool-lookup path. Everything else (`initialize`, `ping`, etc.) still goes through `super`:

```elixir
defmodule FermixCore.MCP.Inbound.Server do
  use Hermes.Server,
    name: "fermix",
    version: Mix.Project.config()[:version] || "0.1.0",
    capabilities: [:tools]

  alias FermixCore.Capabilities.Capability
  alias FermixCore.MCP.Inbound.CapabilityPort
  alias FermixCore.MCP.Inbound.Config, as: InboundConfig
  alias FermixCore.MCP.Inbound.Exposure

  require Logger

  @impl true
  def init(client_info, frame) do
    {:ok,
     put_in(frame.private[:mcp_inbound_client], %{
       name: Map.get(client_info, "name"),
       version: Map.get(client_info, "version"),
       session_id: frame.session_id
     })}
  end

  # ---- tools/list and tools/call: served directly. Do NOT fall through. ----

  @impl true
  def handle_request(%{"method" => "tools/list"} = _request, frame) do
    config = InboundConfig.current()
    port = CapabilityPort.impl()                              # Local | DaemonProxy

    case port.list_capabilities() do
      {:ok, capabilities} ->
        exposed = Exposure.expose_for_inbound(capabilities, config)

        emit_list_telemetry(exposed, frame)

        response = %{
          "tools" =>
            Enum.map(exposed, &Exposure.to_mcp_tool_descriptor(&1, config.tool_overrides))
        }

        {:reply, response, frame}

      {:error, reason} ->
        {:error, mcp_error_internal({:capability_port_unavailable, reason}), frame}
    end
  end

  def handle_request(%{"method" => "tools/call", "params" => params} = _request, frame) do
    name = Map.get(params, "name")
    args = Map.get(params, "arguments", %{})
    handle_tool_call(name, args, frame)
  end

  # All other MCP requests (initialize, ping, etc.) fall through to the
  # Handlers-generated default — note the call to super/2.
  def handle_request(request, frame), do: super(request, frame)

  # ---- tools/call body — private function, not a Hermes callback ----

  defp handle_tool_call(name, args, frame) when is_binary(name) and is_map(args) do
    config = InboundConfig.current()
    port = CapabilityPort.impl()

    with {:ok, capabilities} <- port.list_capabilities(),
         {:ok, capability} <- find_exposed(capabilities, name, config),
         {:ok, validated_args} <- validate_args(capability, args) do
      execute_and_telemetry(port, capability, validated_args, frame)
    else
      :not_found ->
        emit_rejection_telemetry(name, :unknown_tool, frame)
        {:error, mcp_error_unknown_tool(name), frame}

      {:error, {:invalid_args, errors}} ->
        emit_rejection_telemetry(name, :invalid_params, frame)
        {:error, mcp_error_invalid_params(format_arg_errors(errors)), frame}

      {:error, reason} ->
        emit_rejection_telemetry(name, {:port_error, reason}, frame)
        {:error, mcp_error_internal(reason), frame}
    end
  end

  # Rejected calls still emit the inbound :call event so the audit trail is
  # complete. duration_ms is 0 because the capability never executed; the
  # result tag carries the rejection reason. tool_kind / tool_policy_class
  # are nil for unknown_tool (we don't have a capability to report on);
  # for invalid_params they carry the matched capability's values so
  # operators can see "Claude Desktop sent malformed args to file_read 12
  # times today."
  defp emit_rejection_telemetry(name, reason, frame) do
    :telemetry.execute(
      [:fermix, :mcp, :inbound, :call],
      %{duration_ms: 0},
      Map.merge(
        frame.private[:mcp_inbound_client] || %{},
        %{tool_name: name, result: {:error, reason}}
      )
    )
  end

  # ---- Argument validation against the capability's inputSchema ----
  #
  # MCP clients can (and do) send malformed arguments — missing required
  # fields, wrong types, extra unknown keys. The spec expects servers to
  # validate against the published inputSchema and reject with
  # `invalid_params`. We do that at the inbound boundary, before any
  # capability runs, using Peri (already a hermes_mcp transitive dep).
  #
  # Validation errors return a Hermes.MCP.Error.protocol(:invalid_params, ...)
  # with a flat message list; the MCP client surfaces the message to its user
  # (e.g., "Claude, the tool reports: file_read: path is required").
  #
  # We do NOT trust capabilities to validate their own args. Some do
  # (M7 built-ins use a defensive pattern-match-then-error), some don't
  # (skills accept arbitrary maps because their interface is the SKILL.md
  # body, not a typed parameter schema). The single validation point
  # makes the contract uniform regardless of capability source.
  defp validate_args(%Capability{parameters: schema}, args) when is_map(schema) do
    cleaned = Hermes.Server.Component.__clean_schema_for_peri__(schema)

    case Peri.validate(cleaned, args) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, {:invalid_args, errors}}
    end
  end

  defp format_arg_errors(errors) when is_list(errors) do
    errors
    |> Enum.map(&Hermes.Server.Component.Schema.format_errors([&1]))
    |> Enum.join("; ")
  end

  defp handle_tool_call(_name, _args, frame) do
    {:error, mcp_error_invalid_params("name must be a string, arguments must be a map"),
     frame}
  end

  defp find_exposed(capabilities, name, config) do
    capabilities
    |> Exposure.expose_for_inbound(config)
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> :not_found
      capability -> {:ok, capability}
    end
  end

  defp execute_and_telemetry(port, %Capability{name: name} = capability, args, frame) do
    started = System.monotonic_time(:millisecond)
    context = build_context(frame)

    result = port.execute_capability(capability, args, context)
    duration_ms = System.monotonic_time(:millisecond) - started

    emit_call_telemetry(name, capability, duration_ms, result, frame)

    case result do
      {:ok, payload} when is_binary(payload) ->
        {:reply, mcp_tool_text_response(payload, is_error: false), frame}

      {:ok, %{"isError" => is_error?} = payload} ->
        # capability returned the existing Builtin.Tool.success/error shape;
        # normalize to the MCP protocol map.
        {:reply, mcp_tool_response_from_payload(payload, is_error?), frame}

      {:error, reason} ->
        {:error, mcp_error_internal(reason), frame}
    end
  end

  defp build_context(frame) do
    %{
      source: :mcp_inbound,
      mcp_inbound_client: frame.private[:mcp_inbound_client] || %{}
    }
  end

  # ---- MCP wire helpers (build Hermes.MCP.Error / protocol maps) ----

  defp mcp_tool_text_response(text, is_error: is_error?) do
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "isError" => is_error?
    }
  end

  defp mcp_tool_response_from_payload(%{"content" => content} = _payload, is_error?)
       when is_list(content),
       do: %{"content" => content, "isError" => is_error?}

  defp mcp_tool_response_from_payload(payload, is_error?) do
    mcp_tool_text_response(Jason.encode!(payload), is_error: is_error?)
  end

  defp mcp_error_unknown_tool(name) do
    Hermes.MCP.Error.protocol(:invalid_params, %{message: "Tool not found: #{name}"})
  end

  defp mcp_error_invalid_params(msg) do
    Hermes.MCP.Error.protocol(:invalid_params, %{message: msg})
  end

  defp mcp_error_internal(reason) do
    Hermes.MCP.Error.execution("inbound capability error", %{reason: inspect(reason)})
  end
end
```

Key invariants:

- **One source for both list and call.** Both call into `CapabilityPort.impl()` — the active port (`Local` in the daemon and in standalone stdio mode; `DaemonProxy` in daemon-proxy stdio mode). Listing and execution always resolve against the same registry. If the daemon goes away mid-session in proxy mode, both `list_capabilities/0` and `execute_capability/3` return `{:error, :daemon_unavailable}` and the MCP client sees a clean error from each call. No "list said it's there but call says no" mismatch from cross-registry queries.
- **Re-check on call.** Calls re-run the exposure filter against the live capability set, so a tool that vanished (skill hot-reload, outbound server crash, operator edit of TOML) between `tools/list` and `tools/call` returns the standard MCP "Tool not found" error. No "registered but now invisible" half-state.
- **Args validated at the inbound boundary, not inside the capability.** Every `tools/call` runs `Peri.validate/2` against `capability.parameters` before reaching `execute_and_telemetry/4`. Malformed args (wrong type, missing required field, extra unknown key beyond `additionalProperties`) return `invalid_params` with a flat error message — the capability never sees a malformed payload. This means a future capability author doesn't have to write defensive `case args do %{...} -> ...; _ -> {:error, ...} end` boilerplate just for inbound; the contract is that args reaching the executor already match the published schema. The same `Peri` library and `__clean_schema_for_peri__/1` helper used by Hermes's own component path is reused so the validation semantics are identical regardless of which path a tool call took.
- **`source: :mcp_inbound` in execution context.** Capabilities can branch on this if they want (e.g., a future audit-only mode), but v1 capabilities ignore it. The tag flows into telemetry so traces distinguish "shell called by main agent" from "shell called by Claude Desktop over inbound MCP".
- **Wire shape is MCP-protocol-map, not `Hermes.Server.Response`.** Because we serve from `handle_request/2` (not `handle_tool_call/3`), Hermes never calls `Response.to_protocol/1` on our reply — the map we return *is* the response body. The map shape (`%{"content" => [...], "isError" => bool}`) matches the spec directly. The capability's own success/error payload (existing `Builtin.Tool.success/1` / `error/1` shape) is normalized in `mcp_tool_response_from_payload/2`.
- **Telemetry is the audit trail.** Every call writes one `[:fermix, :mcp, :inbound, :call]` event with the client name + version + session ID + tool name + result tag. `Trace.TelemetryHandler` already attaches to capability events; we add an attachment for the inbound events so JSONL traces include them under `~/.fermix/traces/`.

#### Request timeout — concrete contract

Hermes's `Server.Supervisor` defaults `request_timeout` to 30 seconds (`deps/hermes_mcp/lib/hermes/server/supervisor.ex:88`). For the Streamable HTTP transport, that timeout is enforced on the *caller* side via a `GenServer.call(..., timeout)` against the server process (`deps/hermes_mcp/lib/hermes/server/transport/streamable_http.ex:344`). When the timeout fires:

- The transport caller gets `{:exit, {:timeout, ...}}` and replies to the HTTP client with a JSON-RPC error.
- **The server callback (`handle_request/2`) continues running uninterrupted.** When it eventually returns `{:reply, response, frame}`, Hermes pushes the response through the session machinery; if the SSE stream has been torn down by the timeout, the response is silently dropped. There is no signal back to our callback that the client gave up.

This means the inbound server **cannot reliably tag a capability execution as "client-side timed out" from inside `handle_request/2`** — by the time the capability returns, we don't know whether the wire reply went anywhere. Wrapping each call in our own `Task` + `Task.yield_after/2` to observe the timeout would work but adds a process per call and a cancellation story the capability execution path doesn't support today.

The v1 contract is therefore weaker, and stated explicitly:

- **Default timeout: 30s** (the Hermes default, no override unless config sets one).
- **Operator-configurable** via `[mcp.inbound] request_timeout_ms = 60000`. Plumbed through `Inbound.Supervisor` into `Hermes.Server.Supervisor`'s `request_timeout` option at start time. Edits require a daemon restart (no hot-reload in v1).
- **Tools known to run long** (`delegate`, skill capabilities) are not in the default-exposed set — they require `[mcp.inbound.tools.<name>] exposed = true`. An operator opting one of those in is also expected to raise `request_timeout_ms`.
- **What the client sees:** on timeout, a JSON-RPC error response from the HTTP transport; nothing further from the server for that request id.
- **What telemetry sees:** the `[:fermix, :mcp, :inbound, :call]` event fires when the capability completes (or errors), with the **actual** result. It does *not* carry a "client timed out" tag, because the server callback can't observe that. To audit "which inbound calls did the client give up on," correlate the inbound `:call` event's `duration_ms` against the configured `request_timeout_ms` — `duration_ms > request_timeout_ms` is your timeout signal.
- **Capability cancellation is not in scope.** When the wire reply is dropped, the capability still runs to completion and any side effects it has (file writes, memory store) still happen. Operators exposing tools with externally-visible side effects should ensure their `request_timeout_ms` exceeds the realistic tail latency.

Adding proper per-call cancellation (Task-wrapped execution + cancellation signal into the capability) is a separate piece of work; the existing capability execution path is synchronous and `Capability.execute/3` does not yet have a cancellation contract. Tagging timeouts in inbound telemetry depends on that work landing first.

### 4.7 Config shape (full)

Append to `~/.fermix/config.toml`. **Top-level** `[mcp.*]` namespace — same as outbound.

```toml
# ---- Inbound MCP: expose Fermix capabilities to external clients ----

[mcp.inbound]
enabled = false                                       # default off — fail closed
transport = "stdio"                                   # "stdio" | "streamable_http"

# Filters: which capabilities are exposed.
expose_kinds = ["builtin"]                            # default; add "skill" or "mcp" to broaden (loop warning fires on "mcp")
expose_policy_classes = ["read_only", "read_write"]   # default
allowed_tools = []                                    # empty = allow all that pass filters
denied_tools = []                                     # exact-name denylist

# Optional: published server identity (visible to MCP clients in the
# initialize handshake). Defaults to ("fermix", <release version>).
server_name = "fermix"
server_version = "0.1.0"

# Optional: how long Hermes waits for handle_request/2 to return before
# the client sees a JSON-RPC timeout error. Default 30000 (30s, the
# hermes_mcp default). Raise when exposing long-running tools like
# delegate or skill capabilities — the underlying execution does not
# stop on timeout, only the wire reply.
request_timeout_ms = 30000

# ---- Per-tool overrides ----
# `exposed = true` is the single opt-in keyword. It bypasses every gate
# (kind, policy_class, hidden_from_agent?) for one named capability.

# Opt in a skill (skills are :exec policy_class, so they need the override).
[mcp.inbound.tools.research-skill]
exposed = true

# Force-expose shell despite its :exec policy_class. Operator accepts the risk.
[mcp.inbound.tools.shell]
exposed = true
description_override = "Execute a shell command on the Fermix host. Use with care."

# Force-hide a specific tool even if it passes the default filters.
[mcp.inbound.tools.file_write]
exposed = false

# ---- HTTP transport options ----
# Only consulted when transport = "streamable_http".
[mcp.inbound.http]
path = "/mcp"                                         # mount point on the existing Phoenix endpoint
auth_token = "$env:FERMIX_MCP_INBOUND_TOKEN"          # required when HTTP transport is on
```

#### Required-vs-optional table

| Key | Required when | Default | Notes |
|-----|---------------|---------|-------|
| `enabled` | always | `false` | Top-level switch. |
| `transport` | `enabled = true` | `"stdio"` | Two valid values; anything else raises at config load. |
| `expose_kinds` | never | `["builtin"]` | Adding `"skill"` lets *all* skills through the policy gate (still subject to `:exec` policy gate unless `expose_policy_classes` widens). Adding `"mcp"` triggers the loop warning. |
| `expose_policy_classes` | never | `["read_only", "read_write"]` | Adding `"exec"`, `"network"`, or `"external_api"` widens the surface. |
| `allowed_tools` / `denied_tools` | never | `[]` / `[]` | Mutually compatible; `allowed_tools` is an allowlist, `denied_tools` a denylist. Both `[]` means "use kind+policy filters". |
| `server_name` / `server_version` | never | `"fermix"` / release version | Cosmetic, surfaces in MCP client UI. |
| `request_timeout_ms` | never | `30000` (Hermes default) | Wire timeout for `handle_request/2`. Capability execution continues after timeout; only the client reply is dropped. Raise when exposing long-running tools. |
| `[mcp.inbound.tools.<name>] exposed` | never | absent (default gate applies) | `true` force-includes (bypasses every gate including `hidden_from_agent?`); `false` force-excludes. The **only** per-tool opt-in keyword. |
| `[mcp.inbound.tools.<name>] description_override` | never | uses `Capability.description` | Cosmetic. Does not change the underlying capability. |
| `[mcp.inbound.http] path` | `transport = "streamable_http"` | `"/mcp"` | Mount point on the existing Phoenix endpoint. |
| `[mcp.inbound.http] auth_token` | `transport = "streamable_http"` | _required_ | Boot fails if HTTP transport is enabled and this key is unset. |

#### Validation

`Inbound.Config.from_toml/1` raises `ArgumentError` (loud, never silent) on:

- `enabled = true` with `transport` not in `["stdio", "streamable_http"]`.
- `transport = "streamable_http"` with no `auth_token` set (after `$env:` resolution).
- Any `policy_class` not in `Capability.valid_policy_classes()`.
- Any `kind` not in `[:builtin, :skill, :mcp]`.
- Per-tool override block containing an unknown key (anything other than `exposed` or `description_override`).
- Duplicate tool names in `allowed_tools` ∪ `denied_tools`.

A per-tool block with only `description_override` (no `exposed`) is **valid**: the tool falls through to the default exposure gate, and *if it ends up exposed*, the override description is published instead of the underlying `Capability.description`. The same shape with only `exposed = false` is also valid (force-hide a tool that would otherwise be exposed). The only invalid shape is "no recognized keys" or "unknown keys present" — both raise.

Same pattern as `Capabilities.MCP.Config` — raise at config load, not on first call.

### 4.8 Frame and session lifecycle

Hermes maintains a `Frame` per MCP session. For stdio, there's one session per process (Claude Desktop owns it). For HTTP, there's one session per SSE-stream + message-POST pair (Hermes generates a session ID, the client carries it in headers).

`Inbound.Server.init/2` stores the client_info into `frame.private[:mcp_inbound_client]`:

```elixir
%{
  name: "Claude Desktop",
  version: "0.7.4",
  session_id: "01HW...xyz"
}
```

This propagates into the capability execution context and into every telemetry event for the session. A future M10 per-client ACL gate consumes the same `name` / `version` strings; we surface them now so the policy hook has stable inputs.

Session expiry is owned by Hermes — `Session.Supervisor` already cleans up idle sessions after the configurable `session_idle_timeout` (default 30 minutes). We don't add custom expiry on top.

### 4.9 Telemetry and traces

Two new telemetry events, attached to `Trace.TelemetryHandler` so they land in JSONL traces under `~/.fermix/traces/`:

```elixir
:telemetry.execute(
  [:fermix, :mcp, :inbound, :tools_listed],
  %{count: length(exposed_capabilities)},
  %{
    client_name: client.name,
    client_version: client.version,
    session_id: client.session_id
  }
)

:telemetry.execute(
  [:fermix, :mcp, :inbound, :call],
  %{duration_ms: dur},
  %{
    tool_name: name,
    tool_kind: capability.kind,             # nil for :unknown_tool rejections
    tool_policy_class: capability.policy_class,
    client_name: client.name,
    client_version: client.version,
    session_id: client.session_id,
    result: result_tag(result)
    # result tag values:
    #   :ok
    #   {:error, :invalid_params}    — rejected at the validation boundary
    #   {:error, :unknown_tool}      — not in the exposed set at call time
    #   {:error, {:port_error, _}}   — CapabilityPort failure (e.g., daemon unavailable)
    #   {:error, capability_reason}  — capability returned {:error, reason}
  }
)
```

**Rejected calls emit the `:call` event too.** A `tools/call` that fails arg validation, names an unknown/unexposed tool, or hits a port error all fire the inbound `:call` event with the appropriate `result` tag and `duration_ms: 0`. The capability never runs, so no `[:fermix, :capability, :exec]` event fires for those — only the inbound rejection telemetry. This keeps the inbound audit trail complete: every `tools/call` the MCP client sent is observable, including the malformed ones that never reached a capability.

Successful and capability-error calls emit the inbound `:call` event *in addition to* the existing `[:fermix, :capability, :exec]` event that fires inside `Capability.execute/3`. The inbound event tells you "Claude Desktop called shell"; the capability event tells you "shell ran for 12ms and returned :ok". Both attribution paths are preserved.

`fermix status` reads aggregated counts (last call time, calls in last 5min, total calls) from `Health.report/0` which keeps an in-memory tally fed by the telemetry events.

---

## 5. Removal / Deprecation List

None. M4.12 is additive. No existing module is renamed or deleted. The outbound `Capabilities.MCP.*` namespace stays untouched; inbound lives at the sibling `FermixCore.MCP.Inbound.*` namespace. The naming asymmetry (outbound under `Capabilities.MCP`, inbound under `MCP.Inbound`) is acknowledged here and not fixed in this milestone — renaming outbound is a tree-wide refactor that has nothing to do with shipping inbound functionality, and the existing namespace is descriptive (capabilities Fermix *consumes* via MCP). If a future milestone wants symmetry, it can rename outbound to `Capabilities.MCP.Outbound`; that decision is out of scope here.

---

## 6. Implementation Stages

Same staged-and-reversible approach as M4.9. Compile + tests + credo green between every stage.

### Stage 1 — Config + Exposure (pure, no transport)

- Add `FermixCore.MCP.Inbound.Config` (TOML parser + validation + `$env:` resolution).
- Add `FermixCore.MCP.Inbound.Exposure` with the full filter from §4.2.
- Wire `Setup.ConfigStore.apply_mcp_config/0` to also load `[mcp.inbound]` into `Application.put_env(:fermix_core, :mcp_inbound, ...)`.
- Tests: every Exposure gate in isolation (enabled/disabled, each kind filter, each policy_class filter, hidden_from_agent?, allowed/denied lists, per-tool override force-expose / force-hide / description_override, kind+policy+hidden_from_agent? composition, malformed TOML raises loud).

**Ship gate:** All exposure rules pinned by tests. No transport, no Hermes, no runtime change. Verifiable by reading `Application.get_env(:fermix_core, :mcp_inbound, [])` after a boot with an example TOML.

### Stage 2 — Inbound Server module + Local CapabilityPort

- Add `FermixCore.MCP.Inbound.CapabilityPort` behaviour (`list_capabilities/0`, `execute_capability/3`) + `CapabilityPort.Local` impl that reads `CapabilityRegistry` and calls `Capability.execute/3`.
- Add `FermixCore.MCP.Inbound.Server` (`use Hermes.Server, capabilities: [:tools]`) overriding `handle_request/2` for **both** `tools/list` and `tools/call`. The `handle_tool_call/3` Hermes callback is intentionally not implemented — see §4.6 for the routing rationale. Replies use the MCP protocol map directly (`%{"content" => [...], "isError" => bool}`); errors use `Hermes.MCP.Error.protocol/2` and `Hermes.MCP.Error.execution/2`.
- Add `FermixCore.MCP.Inbound.Supervisor` (conditionally starts a `Hermes.Server.Supervisor`; transport selection happens inside).
- For Stage 2, start with `transport: StubTransport` (Hermes ships this for test environments) so the Hermes server can be exercised without binding stdio or HTTP.
- Wire into `FermixCore.Application` between outbound MCP and Repo, conditional on `enabled`.
- Tests: full server lifecycle with StubTransport. `tools/list` returns the filtered set (via a `Hermes.Client.Base` round-trip, asserting our `handle_request/2` is hit and the protocol response matches the spec). `tools/call` dispatches via `CapabilityPort.Local` to the right capability with `source: :mcp_inbound` in the execution context. A capability that passed list but no longer passes call returns `Tool not found: <name>`. Unknown tool returns the same. Capability that returns `{:error, ...}` surfaces as `Hermes.MCP.Error.execution/2`. Telemetry events fire with correct measurements/metadata. Loop-prevention warning fires on `:mcp` opt-in. Anchor at least one test directly on the wire shape (raw JSON-RPC in, raw JSON-RPC out) so a future Hermes refactor that changes `handle_request/2` semantics fails loud here, not in production.

**Ship gate:** Inbound server callable in-process via a Hermes client against `StubTransport`. Both `tools/list` and `tools/call` proven not to depend on Hermes's component/Frame tool registration. No real transport yet.

### Stage 3 — Streamable HTTP transport via Phoenix

- Add `FermixWebWeb.Plugs.McpInboundAuth` with the two-stage runtime gate: stage 1 returns 503 when `[mcp.inbound]` is disabled or the configured transport is not `streamable_http`; stage 2 returns 401 on missing/wrong bearer token. Uses `Plug.Crypto.secure_compare/2`.
- Add the `:mcp_inbound` pipeline + `/mcp` scope in `FermixWebWeb.Router`. The route is mounted **unconditionally** at compile time (Phoenix scopes are macro-expanded; runtime TOML cannot decide their existence). The gate lives in the plug.
- `Inbound.Supervisor` chooses `transport: {:streamable_http, ...}` when configured, otherwise does not start the Hermes server child. The supervisor branch is the second line of defense — even if the auth plug were bypassed, the Hermes transport behind it would not be running.
- Boot log line for HTTP mode (`/mcp` path + `"auth: bearer"`); existing Phoenix endpoint bind config governs reachability.
- Tests: `Plug.Test` for the auth plug — disabled config → 503, transport mismatch → 503, missing token → 401, wrong token → 401, right token + enabled + HTTP transport → pass; constant-time compare exercised (assert `Plug.Crypto.secure_compare/2` is the comparison primitive). End-to-end: a `Hermes.Client.Base` configured with `Hermes.Transport.StreamableHTTP` round-trips `initialize`, `tools/list`, and `tools/call` against a test Phoenix endpoint. Misconfig branch: enable HTTP transport without a token in TOML → `Inbound.Config.from_toml/1` raises at config load, daemon boot fails loud.

**Ship gate:** Curl + a `Hermes.Client.Base` with `Hermes.Transport.StreamableHTTP` both round-trip an inbound MCP session against a running test daemon. Disabling the config takes effect on the **next** request (no restart needed for the gate; the supervisor restart is required only to free the Hermes server child). Boot fails loud with a useful message when HTTP is on without a token.

### Stage 4 — Stdio transport + `fermix mcp serve` CLI

- Add the new CLI dispatch in `FermixCore.Application`: `cli_dispatch(["mcp", "serve" | _])`.
- The minimal supervision tree: `CapabilityRegistry`, `BuiltinSeeder`, `SkillRegistry`, `Trace`, `Inbound.Supervisor` with `transport: :stdio`. Memory.Repo is conditional on no daemon detected.
- Add `Fermix.CLI.Daemon.Client.probe/0` (200ms timeout, returns `:running | :not_running`).
- Implement `CapabilityPort.DaemonProxy` with both halves: `list_capabilities/0` sends a `:mcp_inbound_list` request over the existing control socket; `execute_capability/3` sends `:mcp_inbound_execute`. Both halves handle `:daemon_unavailable` uniformly (one in-flight request to a now-dead socket → `{:error, :daemon_unavailable}`).
- Add the two daemon socket handlers (mirrors the existing `:status`, `:capabilities`, etc. pattern in `Fermix.CLI.Daemon`):
  - `:mcp_inbound_list` — runs `Exposure.expose_for_inbound(CapabilityRegistry.list(), InboundConfig.current())` and returns the capability list (JSON-serializable subset: name, description, parameters, kind, policy_class, hidden_from_agent?, metadata). No raw `%Capability{}` over the socket — keep the wire decoupled from the struct shape.
  - `:mcp_inbound_execute` — looks up the capability by name, re-applies `Exposure.expose_for_inbound/2`, calls `Capability.execute/3`. Returns the result tuple.
- Tests: `fermix mcp serve` end-to-end with daemon-up (both `tools/list` and `tools/call` proxy through the daemon) and daemon-down (Local mode reads from this process's own registry). MCP client (a `Hermes.Client.Base` with `Hermes.Transport.STDIO` pointed at our binary) round-trips a session. `CapabilityPort.DaemonProxy` handles `:daemon_unavailable` for both calls cleanly when the daemon disappears mid-session. The list returned in daemon-proxy mode exactly matches what an HTTP-transport client would see from the same daemon (no drift between transports).

**Ship gate:** `claude_desktop_config.json` with `"command": "fermix", "args": ["mcp", "serve"]` works end-to-end. Both modes (daemon-up, daemon-down) tested. Daemon-proxy list and daemon-proxy call agree about what is exposed. README documents the Claude Desktop config block.

### Stage 5 — Diagnostics and hygiene

- Add `fermix mcp list-exposed` CLI (`Fermix.CLI.McpCommand`). Daemon-socket method returning the exposed tool list; CLI prints names + kinds + policy_class + description (override-or-original).
- Extend `Health.report/0` with the `:mcp_inbound` block (enabled?, transport, exposed_count, last_call_ts).
- Extend `Setup.Doctor` with an inbound-MCP probe (config valid? transport reachable? auth token configured for HTTP?).
- Documentation: README section on inbound MCP, including the loop-warning rationale and the per-tool override examples. `docs/ROADMAP.md` entry updated.

**Ship gate:** `mix test`, `mix credo --strict`, `mix format --check-formatted` green. README + doctor + status all visibly support inbound MCP. Smoke test from a clean install: `fermix setup` → edit TOML → `fermix run` → curl `/mcp` → tools/list returns the expected default-exposed set.

---

## 7. Migration Safety

Inbound is additive — no existing path is removed or rerouted. The migration is "the operator changes their config to opt in." The hardest part of M4.9 (parallel-registries-during-overlap) does not apply here.

Three explicit safety measures:

1. **Default off.** `enabled = false` is the only sane default. A user who upgrades Fermix to a build with M4.12 sees zero behaviour change unless they edit TOML.
2. **Loop-warning is loud, not silent.** Operators who include `"mcp"` in `expose_kinds` get a multi-line warning on every supervisor start. Not a one-time hint that scrolls off — every restart, in the logs and in `fermix doctor`.
3. **Misconfig fails closed, fast.** HTTP transport with no auth token raises at config load; same for unknown `transport` values, unknown policy classes, unknown kinds, and malformed per-tool override blocks. The operator sees the failure at the source (during `fermix run` boot), not when Claude Desktop tries to call a tool three days later.

End-to-end smoke test before each ship gate, in addition to the test suite:

```
1. Fresh install, no [mcp.inbound] block.            → no inbound surface, no warning.
2. [mcp.inbound] enabled = true, stdio default.       → fermix mcp serve replies to tools/list with the default-exposed set.
3. claude_desktop_config.json with the stdio command. → Claude Desktop sees Fermix's tools; can call file_read, memory_recall.
4. Flip transport = "streamable_http", set auth_token. → /mcp on the daemon serves the same set via HTTP; auth required.
5. Wrong bearer token over HTTP.                       → 401, no tool exposure.
6. Add expose_kinds = ["builtin", "skill", "mcp"].     → loop warning fires; outbound mcp_* tools also exposed.
7. Per-tool override exposed = false on file_read.     → tools/list no longer includes it; tools/call returns unknown_tool.
```

---

## 8. Open Questions

1. **stdio mode "daemon detected" timeout.** Proposed 200ms. If the daemon socket is on a slow filesystem (NFS mount?), this might be too tight. Worth measuring against the existing `Daemon.Client` patterns; current daemon socket calls have a 5s default. If 200ms turns out to flake on real hardware, raise to 500ms — the user-visible cost is `fermix mcp serve` taking another 300ms to spin up, which is invisible inside Claude Desktop's own subprocess-launch overhead.

2. **Whether to expose `:mcp` kind to inbound at all.** v1 says "yes, with opt-in and a loud warning." An alternative posture: refuse outright. The argument for "yes": there are real workflows where an operator wants Claude Desktop to drive a Fermix-managed github MCP server precisely so it benefits from Fermix's outbound credential storage. The argument for "no": loops are a debugging quagmire and the operator should just point Claude Desktop at github MCP directly. Going with "yes, with warning" for v1 to avoid the operator workaround of just lying about the kind. Revisit if the warning gets ignored in practice.

3. **Per-tool description overrides — schema overrides too?** v1 only allows `description_override`. The `parameters` JSON Schema is not overridable, because rewriting a JSON Schema safely (preserving required fields, validating against the underlying capability's expectations, etc.) is M10 territory. Worth flagging because operators may want to hide an internal parameter from the MCP client's view. v1 answer: "don't expose tools whose parameter surface is unsuitable for external clients; that's what the deny list is for."

4. **Hermes_mcp server-side API stability.** Fermix is already pinned to `~> 0.13`. Hermes 0.x is pre-1.0 and the server-side `handle_request/2` signature has shifted before. We pin a specific minor and document the bump path in CHANGELOG. M4.12 will fail loud (config-load error) rather than silently degrade if a future Hermes minor changes the Frame shape.

5. **Sessions vs single inbound process.** A daemon serving HTTP MCP can have many concurrent inbound sessions (one per MCP client). The `Frame.private[:mcp_inbound_client]` and telemetry session_id make session attribution clean. But every session sees the same capability set (one config = one cap set). Per-session capability sets is multi-tenant inbound, which is M10. Just noting that the v1 shape doesn't preclude it — `Inbound.Server.init/2` already has the client_info; a future per-client policy filter is one filter added to `Exposure.expose_for_inbound/2`.

6. **Should `tools/list_changed` notifications be sent on capability registry updates?** When a new outbound MCP server registers tools, or a skill hot-reloads, the inbound set changes too. The MCP spec supports `notifications/tools/list_changed`; Hermes ships the send helper. v1 doesn't wire it up — connected clients refresh on next call. Worth a follow-on; not blocking.

7. **Skill exposure is transitive — should we re-filter the skill's internal `allowed_tools` through the inbound policy gate?** Opting a skill in via `[mcp.inbound.tools.<skill>] exposed = true` exposes the skill *and everything the skill itself can call*. A skill whose SKILL.md frontmatter sets `allowed_tools: ["shell", "web_fetch"]` will, when invoked from inbound, run a sub-agent that can call `shell` and `web_fetch` — even if those capabilities have `[mcp.inbound.tools.shell] exposed = false`. The inbound caller never directly invokes `shell`, but the skill's sub-agent does on its behalf.

   This is a real semantic gap that v1 punts on. Three plausible answers:

   - **(a) Accept transitive exposure as the cost of opt-in.** The operator opted in `research-skill` knowing what it can do (the skill body is on disk; they can read it). Same posture today for the main agent: skills inherit their trust-level policy.
   - **(b) Re-apply the inbound policy gate to sub-agents spawned from inbound calls.** The sub-agent's resolved capability set is the *intersection* of (skill's trust-level policy) ∩ (inbound `expose_kinds` × `expose_policy_classes` × allow/deny lists). Conservative; potentially breaks skills that legitimately need broader capabilities.
   - **(c) Per-skill `inbound_allowed_tools` override** in SKILL.md frontmatter, applied only when the skill is invoked via inbound. Maximum flexibility, maximum config surface area.

   v1 ships (a) by default because the alternative requires plumbing the invocation source (`source: :mcp_inbound`) through `Capabilities.Skill.invoke/3` into `Capabilities.Registry.list/2`'s filter — a non-trivial change to the M4.9 capability-resolution path. Document the transitivity in the README's "Inbound MCP" section so operators understand what `exposed = true` on a skill actually means. M10's governance work should pick (b) or (c) explicitly; it should not be a v2 design accident.

---

## 9. Success Criteria

### 9.1 Behavioural

- [ ] Stdio: `fermix mcp serve` invoked from a `claude_desktop_config.json` entry round-trips `initialize`, `tools/list`, and at least three `tools/call` invocations (one builtin read like `file_read`, one builtin write like `memory_store`, one skill exposed via `[mcp.inbound.tools.<skill>] exposed = true`) against a daemon-up and a daemon-down configuration. Default-exposed set matches §4.2: `file_read, file_write, file_edit, glob_search, content_search, git_read, memory_recall, memory_store, list_jobs, tool_help, memory_sources_list` (no skills by default).
- [ ] HTTP: a `Hermes.Client.Base` configured with `Hermes.Transport.StreamableHTTP` against the running daemon's `/mcp` round-trips `initialize`, `tools/list`, and `tools/call` over the network. Wrong token → 401. Inbound disabled or transport mismatch → 503. No token, HTTP enabled → boot fails loud at config load.
- [ ] Hermes routing: a test that crafts a raw `tools/call` JSON-RPC against `Inbound.Server` returns the actual capability output, not Hermes's default `Tool not found` for unregistered tools. Equivalent test for `tools/list`. This pins our `handle_request/2` override against Hermes's compile-time component machinery.
- [ ] Arg validation: a `tools/call` whose `arguments` violates the capability's `inputSchema` returns `Hermes.MCP.Error.protocol(:invalid_params, ...)` *without* invoking `Capability.execute/3`. Verified with a fixture: built-in `file_read` called with `arguments: %{"path" => 42}` (wrong type) and `arguments: %{}` (missing required `path`) both fail at the boundary, not inside the capability. Capability telemetry shows zero executions for these calls.
- [ ] Stdio I/O isolation: launching `fermix mcp serve`, sending a `ping`, then forcing a `Logger.info` from inside a capability call, then sending a `tools/call` — the captured stdout contains only well-formed JSON-RPC frames. No log line, no `IO.puts` output, no stray bytes. Regression coverage for the stdout-protocol invariant in §4.3.
- [ ] Request timeout: with `request_timeout_ms = 50` and a test capability that sleeps 200ms, the inbound HTTP client receives a JSON-RPC timeout error at ~50ms. The same capability, called with `request_timeout_ms = 500`, returns successfully. The inbound `:call` telemetry event fires when the capability completes in **both** cases, carrying the actual result (no client-timeout tag — per §4.6's documented contract that the server callback can't observe client-side timeouts without a Task wrapper). Operators correlate `duration_ms > request_timeout_ms` from the event metadata to identify dropped responses.
- [ ] Daemon-proxy parity: in stdio daemon-proxy mode, the tool list returned by `tools/list` is byte-identical (modulo session metadata) to the tool list returned by an HTTP-transport client hitting the same daemon. No drift.
- [ ] Loop prevention: with `expose_kinds = ["builtin", "mcp"]`, the boot logs include the warning naming every `mcp_*` tool that would be re-exposed.
- [ ] Per-tool overrides: `[mcp.inbound.tools.shell] exposed = true` adds `shell` to the exposed list despite `:exec` policy_class. `[mcp.inbound.tools.file_read] exposed = false` removes `file_read` despite passing the default gate. `[mcp.inbound.tools.<skill>] exposed = true` adds a skill (which has `policy_class: :exec`) despite the default gate.
- [ ] Telemetry: every served `tools/call` writes a `[:fermix, :mcp, :inbound, :call]` event with the client name + version + session ID; the same event lands in the JSONL trace under `~/.fermix/traces/`.

### 9.2 Exposure filter matrix

Recorded fixtures (table-driven tests in `apps/fermix_core/test/fermix_core/mcp/inbound/exposure_test.exs`) for the full matrix:

- [ ] Inbound disabled returns `[]` regardless of registry contents.
- [ ] Each `kind` filter (every combination of `[:builtin, :skill, :mcp]`). Skill-by-default is excluded; pin this explicitly.
- [ ] Each `policy_class` filter (every combination of `[:read_only, :read_write, :exec, :network, :external_api]`).
- [ ] `hidden_from_agent?: true` hidden by default and stays hidden under any kind/policy-class change. Only `exposed = true` lets it through.
- [ ] `allowed_tools = []` is no-op; non-empty is exact allowlist (other tools dropped even if they pass kind+policy).
- [ ] `denied_tools` removes a tool that would otherwise pass.
- [ ] Per-tool override `exposed: true` force-exposes despite failing kind+policy+`hidden_from_agent?` — the single opt-in mechanism.
- [ ] Per-tool override `exposed: false` force-hides despite passing kind+policy.
- [ ] Order pinned: `exposed: true` short-circuits **before** any other gate; `exposed: false` short-circuits immediately.
- [ ] `description_override` rewrites the MCP descriptor description; the underlying `Capability.description` is unchanged.
- [ ] `:mcp` in `expose_kinds` triggers the warning log; tested via `:logger`'s test backend.

### 9.3 Auth plug

- [ ] Inbound disabled → 503, body `"mcp inbound disabled\n"`, halts before Hermes plug.
- [ ] Transport configured as `"stdio"` while HTTP request comes in → 503 with the transport-mismatch body line.
- [ ] Missing `Authorization` header → 401, body `"unauthorized\n"`, halts before Hermes plug.
- [ ] Wrong `Bearer` token → 401.
- [ ] Correct `Bearer` token + enabled + streamable_http → request reaches Hermes plug (asserted via `Plug.Test` mock).
- [ ] HTTP transport in config without `auth_token` → boot fails at config load (`Inbound.Config.from_toml/1` raises). Defense-in-depth: even if config bypass happened, the runtime plug returns 401.
- [ ] Constant-time compare: `Plug.Crypto.secure_compare/2` is the comparison function (asserted via `:meck` or the equivalent test affordance).

### 9.4 Hygiene

- [ ] `mix test`, `mix credo --strict`, `mix format --check-formatted` green.
- [ ] CHANGELOG entry: "feat(mcp): expose Fermix as an MCP server (M4.12) — stdio + streamable HTTP, bearer auth, policy gates, loop-prevention warning."
- [ ] `docs/ROADMAP.md` updated to reflect M4.12 status (status → shipped).
- [ ] README section: "Inbound MCP" with the Claude Desktop block, the HTTP equivalent, and the `[mcp.inbound]` config example.

---

## 10. Out-of-Scope Follow-ons

Concrete next-step milestones this design unlocks but does not deliver:

- **Wizard step.** Add an `:inbound_mcp` step to `Setup.Wizard` after the existing M4.10 model step. Collects: enable? / transport / auth token (if HTTP) / which built-ins to expose / which skills to expose. Persists via `ConfigStore`. Operator-friendly alternative to TOML editing. **~2 days, blocking nothing.**
- **Curated MCP tool wrappers (hermes-agent shape).** Add `fermix_conversations_list`, `fermix_channels_list`, `fermix_journals_list`, `fermix_traces_list` as MCP tools that don't map 1:1 to capabilities — they wrap in-process state queries (Health, Introspection, channel directory) into MCP-shaped surfaces. Mirrors the nine-tool surface hermes-agent ships in `mcp_serve.py:469-857`. Useful because a Claude Desktop user asking "what conversations is fermix running" can't be answered by the 1:1 capability exposure — none of the capabilities are *about Fermix itself*. Lives in a new `FermixCore.MCP.Inbound.WrapperTools` module that the inbound server registers alongside the registry-derived tools. **~3-4 days.**
- **Inbound events surface (`events_poll` / `events_wait`).** Port the hermes-agent `EventBridge` pattern (`mcp_serve.py:204-444`) to Fermix. A background process tails channel telemetry / agent lifecycle events and queues them; the MCP client subscribes via `events_poll` (sync) or `events_wait` (long-poll). Lets an external agent observe Fermix activity without polling each tool. Depends on curated wrappers landing first. **~1 week.**
- **Inbound resources (`resources/list`, `resources/read`).** Expose memory entries as `fermix://memory/<id>`, journals as `fermix://journals/<skill>/<run_id>`, traces as `fermix://traces/<date>/<event_id>`. Tools-only is enough for the immediate use cases; resources unlock "let Claude Desktop recall a Fermix memory by URI." **~1 week.**
- **Inbound prompts (`prompts/list`, `prompts/get`).** Expose skill bodies as Claude-Desktop slash commands. Each skill becomes `fermix:skill:<name>`. The MCP client renders the skill prompt with parameter inputs. **~3-4 days, depends on resources.**
- **`tools/list_changed` notifications.** When `CapabilityRegistry` changes (skill hot-reload, new outbound MCP server's tools registering), broadcast to connected inbound sessions so they refresh their tool list. **~1-2 days.**
- **Hot-reload of inbound config.** `fermix mcp inbound reload` daemon socket method that re-reads `[mcp.inbound]` from disk and refreshes the Hermes server's exposure filter without restart. **~2 days, depends on the existing reseed pattern from M7+.**
- **Approval-surface exposure (M10 territory).** Once M10 ships the approval queue (the user-facing surface for `hidden_from_agent?: true` capabilities), expose `permissions_list_open` / `permissions_respond` as MCP tools so an external agent can drive Fermix's approval gate. The shape hermes-agent landed on (`mcp_serve.py:823-857`) is a reasonable port target. **Blocked on M10 — the approval store doesn't exist yet.**
- **Per-user inbound auth + ACLs (M10).** Multi-token: each token maps to a policy filter. Token rotation, audit per token, per-token rate limits, per-token capability subset. **M10 territory; this milestone surfaces the static gates that M10 composes on top of.**
- **mTLS / OAuth for HTTP transport.** Bearer is the v1 posture. mTLS and OAuth are M10.
