# Milestone 4.13: Anubis MCP Migration

**Status:** Shipped
**Date:** 2026-05-23
**Author:** Sujeeth / Aira
**Depends on:** M4.9 (`Capabilities.MCP.*` outbound client surface), M4.12 (`MCP.Inbound.Server` Hermes-backed inbound MCP server)
**Blocks:** any future MCP work that needs a maintained upstream (newer MCP protocol revisions, server bugfixes, transport features). Nothing user-facing.
**References:** `apps/fermix_core/mix.exs`, `apps/fermix_core/lib/fermix_core/capabilities/mcp/anubis_starter.ex`, `apps/fermix_core/lib/fermix_core/capabilities/mcp/caller.ex`, `apps/fermix_core/lib/fermix_core/capabilities/mcp/discoverer.ex`, `apps/fermix_core/lib/fermix_core/capabilities/mcp/server.ex`, `apps/fermix_core/lib/fermix_core/capabilities/mcp/supervisor.ex`, `apps/fermix_core/lib/fermix_core/mcp/inbound/server.ex`, `apps/fermix_core/lib/fermix_core/mcp/inbound/supervisor.ex`, [zoedsoupe/anubis-mcp](https://github.com/zoedsoupe/anubis-mcp), [anubis_mcp on Hex.pm](https://hex.pm/packages/anubis_mcp), [hexdocs.pm/anubis_mcp](https://hexdocs.pm/anubis_mcp), [Anubis announcement — Elixir Forum](https://elixirforum.com/t/anubis-formerly-hermes-mcp-model-context-protocol-implementation-for-elixir/71410)

---

## 1. Problem / Goal

`hermes_mcp` (the dep that powers both our outbound MCP client in M4.9 and our inbound MCP server in M4.12) has not had a release since v0.14.1 on 2025-08-14. Its author (zoedsoupe) left CloudWalk and forked it to `anubis_mcp` in July 2025; new MCP protocol revisions, server work, and bugfixes happen there now. Hermes is effectively frozen — it works, but any future Fermix MCP work that needs upstream change (newer protocol version, transport fixes, server features) would require patching a dead dep ourselves.

The previous framing of "drop-in rename" is **wrong for Fermix specifically**. Anubis v1.0 (2026-03-16) intentionally removed the client base module and macro and re-implemented the server. We use both halves: `Hermes.Client.Base` + `Hermes.Transport.STDIO` for the outbound client, and `use Hermes.Server` for the inbound server. The migration is therefore a small architectural change inside our outbound starter (two child processes collapse into one) plus a namespace rename across the rest.

**Goal of M4.13:** swap `hermes_mcp ~> 0.13` for `anubis_mcp ~> 1.6`, rewrite the outbound starter to use Anubis's single-child `Anubis.Client` shape, port the inbound server's frame-state accessors from `put_private/get_mcp_session_id` to `assign`, and migrate every test and module reference, in **one commit**. No new behavior, no new config, no new tests beyond renames. Done when `mix compile --warnings-as-errors`, `mix test`, `mix credo --strict`, and `mix format --check-formatted` on the touched Elixir files all pass on the migrated tree and a manual stdio E2E (`fermix mcp serve` connected to Claude Desktop) lists and calls one inbound tool.

**Non-goal in this milestone:**

- New MCP features (streaming, resources, prompts, sampling, OAuth, bearer-token rotation) — even where Anubis 1.x exposes them.
- Adoption of `use Anubis.Server` component DSL (`component MyTool`) — `MCP.Inbound.Server` keeps its runtime-data approach, overriding `handle_request/2` for `tools/list` and `tools/call` exactly as it does today.
- Behavior change in outbound discovery (retry backoff, `expected_startup_error?` heuristic) — the structs and reason atoms transfer; only namespaces change.
- Touching the unrelated `hermes-agent` Python project references in `providers/openai/responses_shared.ex` and its test — that string ("hermes-agent compatible enum") refers to the upstream Python project, not the Elixir lib. Leave it alone.

---

## 2. Scope and Non-Goals

### In Scope

| Item | Type | Notes |
|---|---|---|
| `mix.exs` dep swap | Edit | `{:hermes_mcp, "~> 0.13"}` → `{:anubis_mcp, "~> 1.6"}`. `mix deps.unlock hermes_mcp && mix deps.get`. |
| `MCP.HermesStarter` → `MCP.AnubisStarter` | Rename + rewrite | Module file renamed. `build_specs/2` collapses the `Base` + `STDIO` child pair into a **single** `Anubis.Client` child whose `:transport` opt is `{:stdio, command: ..., args: ..., env: ...}`. The starter's `client_name_for/1`/`transport_name_for/1` becomes just `client_name_for/1`. Child spec id `{:hermes_base, name}` and `{:hermes_stdio, name}` → `{:anubis_client, name}`. |
| `MCP.Caller.Hermes` → `MCP.Caller.Anubis` | Rename | `Hermes.Client.Base.call_tool/3` → `Anubis.Client.call_tool/3`. Same arity, same return shape (`{:ok, %Anubis.MCP.Response{}}` / `{:error, %Anubis.MCP.Error{}}`). |
| `MCP.Discoverer.Hermes` → `MCP.Discoverer.Anubis` | Rename | `Hermes.Client.Base.list_tools/1` → `Anubis.Client.list_tools/1`. `%Hermes.MCP.Response{}` pattern → `%Anubis.MCP.Response{}`. The `is_error: true` and `result: %{"tools" => _}` field matches survive — verified against the Anubis 1.6.0 docs. |
| `MCP.Server` defaults | Edit | `init/1` defaults change to `MCP.Discoverer.Anubis` / `MCP.Caller.Anubis`. `expected_startup_error?/1` pattern matches `%Anubis.MCP.Error{reason: :internal_error, data: %{message: msg}}` (same struct shape — `code`, `reason`, `message`, `data`). |
| `MCP.Supervisor` | Edit | `:hermes_starter` opt key → `:anubis_starter`. Default value `HermesStarter.Default` → `AnubisStarter.Default`. Variable names, log lines, comments. |
| `MCP.Registry` | Edit | Moduledoc says "Hermes.Client.Base pid" → "Anubis.Client pid". |
| `MCP.Capability` | Edit | Moduledoc/comment references to Hermes. |
| `MCP.Inbound.Server` | Edit | `use Hermes.Server` → `use Anubis.Server` (signature identical: `name`, `version`, `capabilities: [:tools]`). Aliases: `Hermes.MCP.Error` → `Anubis.MCP.Error`, `Hermes.Server.Frame` → `Anubis.Server.Frame`, `Hermes.Server.Handlers` → `Anubis.Server.Handlers`, `Hermes.Server.Component.Schema` → `Anubis.Server.Component.Schema`. **State accessor rewrite:** `Frame.put_private(frame, :mcp_inbound_client, client)` → `Frame.assign(frame, :mcp_inbound_client, client)`, and the reader switches `frame.private` → `frame.assigns`. **Session ID:** see §4 open question. |
| `MCP.Inbound.Supervisor` | Edit | `Hermes.Server.Supervisor` → `Anubis.Server.Supervisor`. Child id `:mcp_inbound_hermes_server` → `:mcp_inbound_anubis_server`. Moduledoc/comments. |
| Outbound test suite | Edit | `test/fermix_core/capabilities/mcp/discoverer_test.exs` (Hermes → Anubis module + struct), `test/fermix_core/capabilities/mcp/supervisor_test.exs` (`FakeHermes` → `FakeAnubis`, `RecordingHermesStarter` → `RecordingAnubisStarter`, `:hermes_starter` → `:anubis_starter`, every `:fake_hermes_started` / `:hermes_starter_invoked` message tag). The `FakeHermes` test double only needs to honor the single-process `Anubis.Client` shape — its job is still to send a "started" message; no behavior change. |
| Inbound test suite | Edit | `test/fermix_core/mcp/inbound/server_test.exs` (`Hermes.MCP.Error`, `Hermes.Server.Frame`, `HermesRegistry`, direct wire harness over `Hermes.Server.Base`/`HermesSessionSupervisor` → direct `Anubis.Server.Session` harness), `test/fermix_core/mcp/inbound/supervisor_test.exs` (`FakeHermesSupervisor` → `FakeAnubisSupervisor`, message tags). |
| Hermes mention in `providers/openai/responses_shared.ex` | Leave alone | Refers to the unrelated `hermes-agent` Python project. Not in scope. |
| Verify `mix.lock` has no orphan `hermes_mcp` | Edit | `mix deps.clean hermes_mcp` post-swap to drop any lingering build artifacts. |
| `docs/MILESTONE_4_12_INBOUND_MCP.md` | Edit | Update the M4.12 doc to Anubis-current names, including dependency paths, module names, and server/client references. Preserve legitimate references to the external `hermes-agent` Python project because that is the project name; the §8 docs grep gate excludes those lines. |
| `docs/MILESTONE_4_12_INBOUND_MCP.md` post-migration annotation | Edit | Add a single line under the Status header noting that M4.12 was updated to Anubis MCP names in M4.13 (2026-05-23), so future readers know why the shipped M4.12 doc now uses the post-migration names. |
| `docs/wiki/mcp.html` | Edit | Hand-edited HTML (no generator — `docs/wiki/` contains only static `.html` + `assets/style.css`). Three lines reference Hermes (`Caller.Hermes`, `HermesStarter`, "Hermes-based MCP server"). Update to the Anubis names so the user-facing wiki page doesn't go stale. Only `mcp.html` mentions Hermes; the other 21 wiki pages don't. |
| `CLAUDE.md` `## Docs` section | Edit | Add a line for this doc once the migration ships; mark M4.12 as still-valid against Anubis. |

### Non-Goals

| Item | Reason |
|---|---|
| Adopt `component`-macro DSL for inbound tools | Our tool set is runtime data from `CapabilityRegistry`; the macro path is the wrong shape (see M4.12 §2 for why we override `handle_request/2`). |
| Upgrade MCP protocol version | Stay on whatever Anubis 1.6 negotiates by default. Bumping protocol version is its own concern. |
| Replace stdio transport tests with the new `Anubis.Client` test client | If Anubis exposes a simpler test transport, evaluate later. v1 of this milestone keeps the existing test shape. |
| Touch the `hermes-agent` Python references in code or M4.12 analogue prose | Different project, name collision is incidental. The references in `providers/openai/responses_shared.ex:30`, its test, and the M4.12 comparison to `hermes-agent` stay. Grep gates explicitly exempt lines containing `hermes-agent`. |
| Rewrite shipped milestone docs outside M4.12 and the MCP wiki | M4.13 only updates the docs whose post-migration names would otherwise be stale. Other milestone docs keep their historical wording unless a later milestone explicitly reopens them. |

---

## 3. Migration Inventory (call-site delta)

Complete list of identifiers that change. One PR, mechanical except for the two starred items.

**Library symbol renames** (all instances):

```
Hermes.Client.Base                 → Anubis.Client
Hermes.Transport.STDIO             → (folded into Anubis.Client :transport opt) *
Hermes.MCP.Response                → Anubis.MCP.Response
Hermes.MCP.Error                   → Anubis.MCP.Error
Hermes.Server                      → Anubis.Server         (use macro target)
Hermes.Server.Base                 → Anubis.Server.Session (test harness; Anubis has no Server.Base)
Hermes.Server.Frame                → Anubis.Server.Frame
  Frame.put_private/3              → Frame.assign/3        *
  frame.private                    → frame.assigns         *
  Frame.get_mcp_session_id/1       → frame.context.session_id *
Hermes.Server.Handlers             → Anubis.Server.Handlers
Hermes.Server.Component.Schema     → Anubis.Server.Component.Schema
Hermes.Server.Supervisor           → Anubis.Server.Supervisor
Hermes.Server.Transport.STDIO      → Anubis.Server.Transport.STDIO
Hermes.Server.Registry             → Anubis.Server.Registry
Hermes.Server.Session.Supervisor   → Anubis.Server.Session (test harness direct session)
```

**Fermix module renames** (file + every alias/reference):

```
FermixCore.Capabilities.MCP.HermesStarter         → ...AnubisStarter
FermixCore.Capabilities.MCP.HermesStarter.Default → ...AnubisStarter.Default
FermixCore.Capabilities.MCP.Caller.Hermes         → ...Caller.Anubis
FermixCore.Capabilities.MCP.Discoverer.Hermes     → ...Discoverer.Anubis
```

**Fermix internal identifiers — exhaustive**. The grep gate in §8 (`grep -r "Hermes\|hermes" apps/`) will fail unless every one of these is renamed; list them explicitly so the implementer doesn't have to rediscover them by playing whack-a-mole with the grep gate.

*Source code:*

```
:hermes_starter             (opt key, MCP.Supervisor)             → :anubis_starter
:hermes_base, :hermes_stdio (child spec ids, HermesStarter)        → :anubis_client
:mcp_inbound_hermes_server  (child spec id, Inbound.Supervisor)    → :mcp_inbound_anubis_server
:hermes_client_not_started  (error atom, MCP.Server line 160)      → :anubis_client_not_started
hermes_children, hermes_client, hermes_starter
    (local var names, MCP.Supervisor lines 60/69/91/94)            → anubis_children, anubis_client, anubis_starter
hermes_child/1, hermes_children
    (local fn + var, Inbound.Supervisor lines 24/29)               → anubis_child/1, anubis_children
```

*Tests* (`test/fermix_core/capabilities/mcp/supervisor_test.exs` and `test/fermix_core/mcp/inbound/supervisor_test.exs`):

```
:fake_hermes_started, :hermes_starter_invoked                      → :fake_anubis_started, :anubis_starter_invoked
:fake_hermes                       (child spec id)                 → :fake_anubis
recording_hermes_client_*          (registered atom prefix)        → recording_anubis_client_*
mcp_sup_hermes_*, mcp_sup_hermes_reg_*
    (Supervisor / Registry registered name prefixes)               → mcp_sup_anubis_*, mcp_sup_anubis_reg_*
:mcp_supervisor_hermes_test        (child spec id)                 → :mcp_supervisor_anubis_test
mcp_sup_no_hermes_*, mcp_sup_no_hermes_reg_*                       → mcp_sup_no_anubis_*, mcp_sup_no_anubis_reg_*
:mcp_supervisor_no_hermes_test                                     → :mcp_supervisor_no_anubis_test
FakeHermes, FakeHermesSupervisor, RecordingHermesStarter
    (test module names)                                            → s/Hermes/Anubis/
FermixCore.Capabilities.MCP.Discoverer.HermesTest                  → FermixCore.Capabilities.MCP.Discoverer.AnubisTest
ensure_hermes_registry_started/0   (test helper, server_test.exs)  → removed; wire test starts Anubis.Session directly
```

Items marked `*` in §3 are the **only** non-mechanical edits.

---

## 4. The two non-mechanical changes

### 4.1 Outbound starter: `Base` + `STDIO` pair → single `Anubis.Client` child

**Today** (`HermesStarter.Default.build_specs/2`):

```elixir
base_spec = Supervisor.child_spec(
  {Hermes.Client.Base,
   [transport: [layer: Hermes.Transport.STDIO, name: transport_name],
    client_info: ..., capabilities: %{}, name: client_name]},
  id: {:hermes_base, server.name}, restart: :permanent)

transport_spec = Supervisor.child_spec(
  {Hermes.Transport.STDIO,
   [command: command, client: client_name, name: transport_name, ...]},
  id: {:hermes_stdio, server.name}, restart: :permanent)

%{children: [base_spec, transport_spec], client_name: client_name}
```

**After** (`AnubisStarter.Default.build_specs/2`):

```elixir
transport_opts =
  [{:command, command}]
  |> add_optional(:args, Map.get(server, :args))
  |> add_optional(:env, Map.get(server, :env))

client_spec = Supervisor.child_spec(
  {Anubis.Client,
   [name: client_name,
    transport: {:stdio, transport_opts},
    client_info: client_info(),
    capabilities: %{}}]},
  id: {:anubis_client, server.name}, restart: :permanent)

%{children: [client_spec], client_name: client_name}
```

Implementation note: Anubis 1.6.0 defaults `protocol_version` to `Anubis.Protocol.latest_version()` (`"2025-11-25"` in 1.6.0). Fermix leaves that option implicit per the §2 non-goal of not adding its own protocol-version policy in this migration.

The `MCP.Server` GenServer continues to read `client_name` from the starter result and pass it to `Discoverer.list_tools/1` / `Caller.call_tool/3` — unchanged. The fact that `Anubis.Client` is internally a supervision tree (not a single GenServer) is invisible to callers because `Anubis.Client.list_tools/2` and `Anubis.Client.call_tool/4` look up the registered name themselves.

`MCP.Server.maybe_register_client/1` continues unchanged. The Anubis 1.6 docs are explicit: `Anubis.Client.start_link/1` boots "the client supervision tree (client + transport)", and the `:name` option registers the **client GenServer itself** (not the supervisor) under that name. Therefore `Process.whereis(client_name)` resolves to the client GenServer pid as it does today with `Hermes.Client.Base`, the existing `MCP.Registry.register/3` (typed `pid()`) stays correct, and `Anubis.Client.call_tool/4` / `Anubis.Client.list_tools/2` accept the pid via `GenServer.server()` — no Registry shape change, no Caller signature change, no terminate-path change. `MCP.Registry` stays a moduledoc-only edit.

(If implementation surfaces that this is wrong — e.g. the registered name resolves only to a supervisor pid that doesn't accept client calls — stop and reopen this doc rather than working around it in the caller. Code Rule 12: no fallback path.)

### 4.2 Inbound server: `Frame.put_private` → `Frame.assign`; `get_mcp_session_id` is gone

**Today** (`MCP.Inbound.Server.init/2`):

```elixir
def init(client_info, %Frame{} = frame) when is_map(client_info) do
  client = %{
    client_name: Map.get(client_info, "name"),
    client_version: Map.get(client_info, "version"),
    session_id: Frame.get_mcp_session_id(frame)
  }
  {:ok, Frame.put_private(frame, :mcp_inbound_client, client)}
end
```

…and the reader (`client_context/1`) reaches into `frame.private`.

**After:**

```elixir
def init(client_info, %Frame{} = frame) when is_map(client_info) do
  client = %{
    client_name: Map.get(client_info, "name"),
    client_version: Map.get(client_info, "version"),
    session_id: frame_session_id(frame)
  }
  {:ok, Frame.assign(frame, :mcp_inbound_client, client)}
end
```

…with `client_context/1` reading `frame.assigns[:mcp_inbound_client]`.

Implementation resolved the session-id question as option (1): Anubis 1.6 stores read-only callback context on `frame.context`, whose `%Anubis.Server.Context{}` includes `session_id`. Fermix implements `frame_session_id(%Frame{context: %{session_id: session_id}})`, keeps the value in the same inbound client context map as before, and does not add any parallel session-tracking path.

---

## 5. Implementation Plan

Single PR, single commit on a branch. Stages exist for code review, not for shipping incrementally.

1. **Dep swap.** Edit `apps/fermix_core/mix.exs`. `mix deps.unlock hermes_mcp && mix deps.clean hermes_mcp && mix deps.get`. Run `mix compile` and confirm the compile errors are exactly the renames inventoried in §3 — nothing else. If anything unexpected shows up, stop and investigate before proceeding.
2. **Outbound rewrite.** Rename `hermes_starter.ex` → `anubis_starter.ex`, rewrite `build_specs/2` per §4.1, rename the modules. Update `MCP.Supervisor` opt key and default. Update `MCP.Server` init defaults and `expected_startup_error?/1` struct match. Rename `MCP.Caller.Hermes` and `MCP.Discoverer.Hermes`. Compile clean.
3. **Inbound rewrite.** Update `use Anubis.Server` macro target, alias list, frame state accessors per §4.2. Resolve the session-id question by reading the Anubis source under `deps/anubis_mcp/lib/anubis/server/`. Update `MCP.Inbound.Supervisor` server-supervisor reference and child id. Compile clean.
4. **Test rewrite.** Mechanically rename the four test files' Hermes references per §3. The `FakeAnubis` test double from the renamed `FakeHermes` needs to honor the new single-process client shape, but its observable behavior (send a `:fake_anubis_started` message to the reporter) is unchanged.
5. **Gates.** `mix compile --warnings-as-errors`, `mix test`, `mix credo --strict`, and `mix format --check-formatted` on the touched Elixir files all pass. Zero warnings (Code Rule 11). Full-repo format drift that predates this migration is not part of this milestone.
6. **Smoke test.** With Claude Desktop pointed at `fermix mcp serve` via `claude_desktop_config.json`, confirm `tools/list` returns the same set as before and one `tools/call` (e.g., `memory_recall`) round-trips with the same payload shape. Confirm `[:fermix, :mcp, :inbound, :call]` telemetry fires once. Confirm `[:fermix, :mcp, :inbound, :tools_listed]` fires once per list. Document the session-id resolution chosen in §4.2.
7. **Docs.** In `docs/MILESTONE_4_12_INBOUND_MCP.md`, update every stale migration-source reference to Anubis-current names while preserving legitimate references to the external `hermes-agent` Python project. Add the one-line post-migration annotation under the M4.12 Status header. Update `docs/wiki/mcp.html` lines 23, 25, 56 (`Caller.Hermes` → `Caller.Anubis`, `HermesStarter` → `AnubisStarter`, "Hermes-based MCP server" → "Anubis-based MCP server"). Add this milestone to `CLAUDE.md` `## Docs`. Move status of this doc to `Shipped` and date-stamp.

If any step beyond (1) introduces a behavior delta that isn't a documented rename — stop and reopen this doc before continuing. The whole point of this milestone is "no new behavior."

---

## 6. Tests

No new tests. Existing coverage validates the migration:

- `test/fermix_core/capabilities/mcp/discoverer_test.exs` exercises the `is_error: true` and `result: %{"tools" => _}` paths — those structs survive the namespace rename, so these tests still gate the response decoding.
- `test/fermix_core/capabilities/mcp/supervisor_test.exs` exercises that the starter is invoked exactly once per server and forwarded the correct `command`/`args`/`env` opts. Whether the starter emits one child or two is internal to the starter, but the test asserts on the **starter** call, not the child count — survives the §4.1 architectural shift.
- `test/fermix_core/mcp/inbound/server_test.exs` exercises the `tools/list` and `tools/call` wire boundary and the `client_info`-keyed context propagation. The frame state accessor change (§4.2) is observable through this test; if the assigns-vs-private rewrite is incomplete, the "Hermes wire boundary returns configured identity and dynamic tools" test fails.
- `test/fermix_core/mcp/inbound/supervisor_test.exs` exercises the disabled-config and enabled-config paths; the fake supervisor double's renamed message tags assert the supervisor wires the right transport and timeout to Anubis.

If any of those tests can be deleted as redundant after the migration — they couldn't before, so they can't now. Leave them.

The one place a new assertion *would* be justified is if §4.2's session-id resolution lands as "fall back to nil." In that case, add one test that asserts `session_id: nil` in the inbound call telemetry metadata for a client that did not supply one, to document the v1 behavior. Skip it otherwise.

---

## 7. Cutover and Rollback

**Cutover:** single PR, single commit, merged to `dev`, then to `main` via the usual local-merge flow. No staged dual-deps period — having both `hermes_mcp` and `anubis_mcp` in the tree at once would either fail at compile (overlapping `Hermes` / `Anubis` modules each registering MCP transports) or pass with two competing implementations claiming the same supervisor names. Both are bad.

**Rollback:** revert the migration commit. The previous Hermes-based tree compiles and tests pass. There is no migration-of-state involved — MCP servers are spawned from config every boot, there is no on-disk Hermes state to translate to Anubis or vice versa. A revert is clean.

**Field risk:** low. The outbound path is exercised by every `[mcp.servers.*]` config (filesystem-mcp, etc.); a regression surfaces on the first `tools/list` retry. The inbound path is exercised by every Claude Desktop / Cursor connection; a regression surfaces on the first `initialize` exchange. Both are fast-feedback.

---

## 8. Done When

1. `mix.exs` references `{:anubis_mcp, "~> 1.6"}` and no `hermes_mcp` dep remains.
2. `grep -rn "Hermes\|hermes" apps/ --include="*.ex" --include="*.exs"` returns **exactly two** lines, both referring to the unrelated `hermes-agent` Python project: `providers/openai/responses_shared.ex:30` ("Mirrors hermes-agent's ...") and `test/fermix_core/providers/openai/responses_shared_test.exs:7` ("hermes-agent compatible enum"). Any other hit means the inventory was incomplete.
3. `grep -rn "Hermes\|hermes" docs/wiki/` returns no hits, and `grep -n "Hermes\|hermes" docs/MILESTONE_4_12_INBOUND_MCP.md | grep -v "hermes-agent"` returns no hits. The user-facing wiki and M4.12 docs must read as Anubis-current, while the external Python project keeps its real name.
4. `grep -n "deps/hermes_mcp" docs/MILESTONE_4_12_INBOUND_MCP.md` returns no hits. The dep-path citations resolve in the new tree.
5. `docs/MILESTONE_4_12_INBOUND_MCP.md` Status header carries the one-line Anubis-current migration annotation referencing M4.13.
6. `mix compile --warnings-as-errors` is clean. Zero warnings.
7. `mix test` passes. No tests skipped or marked pending as part of this migration.
8. `mix credo --strict` is clean.
9. The touched Elixir files pass `mix format --check-formatted`. Full-repo formatting drift outside this migration is out of scope for the M4.13 gate.
10. Manual smoke: `fermix mcp serve` from Claude Desktop returns the same tool set as before the migration and one tool call round-trips, with `[:fermix, :mcp, :inbound, :call]` telemetry fired.
11. Manual smoke: at least one outbound server (e.g., filesystem-mcp) discovers its tools and one tool call succeeds via `Capability.execute/3`.
12. §4.2 session-id resolution is documented in code (one comment on `frame_session_id/1`) and in this doc's final state.
13. `CLAUDE.md` `## Docs` lists this doc as `(shipped)`.
