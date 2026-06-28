# Telemetry Contract — keeping new code observable (and Opik-traceable)

Fermix's telemetry is a **standardized, correlatable contract**, not ad-hoc
logging. Every LLM/tool call is stamped with the `session_id` of the run that
issued it, runs are bracketed by lifecycle events, and the JSONL trace stream is
structured. That contract is what lets a turn — including the subagents it
delegates to and the tools they call — be reassembled into one trace (greppable
on its own, or rendered by the optional in-umbrella `fermix_opik` exporter,
`apps/fermix_opik`).

**The rule:** new code must *join* this contract, not invent a parallel one.
Concretely — never hand-roll `:telemetry.execute([:fermix, :tool|provider, ...])`;
route through the shared emitters below, which add correlation + content gating
in one place ("single owner of shape"). Get this right and **new tools/providers
appear in Opik automatically, with zero plugin changes.**

---

## Adding a built-in tool

Emit via the single tool emitter — do **not** write your own `:telemetry.execute`:

```elixir
alias FermixCore.Tools.Telemetry, as: ToolTelemetry

ToolTelemetry.exec(tool_name, context, success, duration_ms,
  metadata: %{plugin: ..., action: ...},   # optional tool-specific fields
  input: args,                              # gated content (the call's input)
  result: result                            # gated content (output/error derived from it)
)
```

It pulls `agent` + `session_id`/`parent_session` from `context` and gates
`input`/`output` behind content capture. Simpler tools can wrap their work in
`FermixCore.Tools.Support.run/3`, which routes through the same emitter.
Plugin/MCP tools already flow through `Plugins.ToolExecutor`, which uses it too —
just make sure the call `context` is threaded.

## Adding a provider / adapter

Emit the LLM call via the single provider emitter, and pass the correlation ids
(which `AgentLoop.build_adapter_opts/3` already puts into `adapter_opts`):

```elixir
alias FermixCore.Providers.Telemetry, as: ProviderTelemetry

ProviderTelemetry.emit_call(
  %{provider: :openai, model: model, status: status, tokens: %{prompt: p, completion: c}, agent: agent},
  duration_ms,
  session_id: Keyword.get(opts, :session_id),
  parent_session: Keyword.get(opts, :parent_session),
  output: response_content,                 # gated content
  tool_calls: response_tool_calls           # gated content
)
```

For **Opik auto-cost** to work the span must carry `type: llm` (the Mapper sets
this), a recognized short `provider` token, a bare `model` id, and integer
`usage`. If you add a **new provider**, add its atom → short-token mapping in the
plugin's `FermixOpik.Mapper.provider_string/1` (e.g. `:openai_codex → "openai"`),
or Opik can't price it.

## Adding a new "run kind" (something that drives the agent loop)

A subagent or scheduled job is a *run*. New run kinds (anything that calls
`AgentLoop.run/1` in its own context) must:

1. give the loop `context` a **unique `session_id`** (e.g. `"main-<n>"`,
   `"cron_<job>_<ts>"`), and a **`parent_session`** if it was spawned by another
   run (that's what nests it under its parent in the trace);
2. emit **lifecycle bookend events** — start / complete / error — carrying that
   `session_id`. Model them on `FermixCore.Jobs.Telemetry` (jobs) or
   `FermixCore.Agents.LifecycleTelemetry` (subagents/skills). Without an opener
   the trace can't be stamped with the run's metadata; without a closer it only
   ships via the exporter's TTL sweep.
3. route those events into the JSONL trace stream via
   `FermixCore.Trace.TelemetryHandler` (`event_definitions/0`).

## Plugin distribution ops

Plugin `install`/`uninstall`/`gc` emit `[:fermix, :plugin, :dist]`
through `FermixCore.Plugins.Dist.Telemetry.emit/5` (op, plugin, version,
result/reason + `duration_ms`) — never hand-roll the event. These ops run in
the installer or a CLI VM with no agent session, so they carry no `session_id`:
`Trace.TelemetryHandler` maps each to a `plugin_dist` row in `agent_event`,
and the Opik exporter renders each op as its own self-closing `dist:<op>`
trace.

## Background memory writes

The background memory **reviewer** persists facts outside the turn that
triggered them (a detached, gated, LLM-judged run). Each durable write emits
`[:fermix, :memory, :write]` (measurements `%{count: 1}`; metadata `tool:
"memory_write"`, `action`, `category`, `key`, `scope_type`, `memory_id`, plus
attribution `session_id` + the conversation `channel`/`chat_id` and optional
`parent_session`). This makes a reviewer-driven persist an **observable span**
so "no `memory_store` tool span" is no longer indistinguishable from a no-op.
`Trace.TelemetryHandler` records it as a `tool_exec` row (`tool: memory_write`);
`FermixOpik` renders it via `Mapper.memory_write_span` as a `tool` span nested
under the reviewer's run. The reviewer fires **after** the turn's trace closes,
so it cannot nest into that trace — it correlates to the conversation by
`thread_id` (`channel:chat_id`), which `Aggregation.place_under` backfills onto
the reviewer's root trace from this event. The synchronous `memory_store` tool
keeps its own `[:fermix, :tool, :exec]` span — this event is only the reviewer's
otherwise-invisible write path.

The review run also emits a **lifecycle closer**, `[:fermix, :memory, :review]`
(measurements `%{duration_us, ops_added, ops_replaced, ops_archived,
ops_skipped, input_messages, input_tokens}`; metadata `agent`, `owner`,
`session_id` — the same per-run id its provider.call/memory.write spans carry —
plus `parent_session`, `conversation_key`, `channel`/`chat_id`, `status`,
`fired`). It is the reviewer's **closer** (§"Adding a new run kind"): the root
trace opens lazily on the run's first span and would otherwise ship only via the
exporter's TTL sweep with no status/output. `Trace.TelemetryHandler` records it
as a `memory_review` `agent_event` row; `FermixOpik` consumes it
(`Aggregation.close_root`) to close the run with an op-count output, and
`infer_kind` tags the run `:memory_review` (not `:subagent`). When a review skips
before any provider call (`session_id: nil`), `close_root` no-ops — nothing was
opened.

## Content (prompts / responses / tool IO)

Attach bodies **only** behind `FermixCore.Telemetry.capture_content?/0`, and
shape them with `FermixCore.Telemetry.preview/1`. With capture **off** (the
default), `preview/1` bounds everything (2k chars, default inspect limits);
with capture **on** it passes content through whole — the operator opted into
full-fidelity traces for debugging, and clipping would defeat the point.
Capture-on also enriches some emitters: a failed browser action attaches the
profile's recent console/JS-exception buffer to its error details. Enabling
the Opik exporter (`FERMIX_OPIK_ENABLED=1`) defaults content capture **on**
(resolved in `config/runtime.exs`); `FERMIX_TRACE_CONTENT` is the explicit
override. Off otherwise — bloat + privacy; bodies are only needed for
eval/observing.

---

## When does the `fermix_opik` exporter also need a change?

The exporter lives **in-umbrella** (`apps/fermix_opik`, dev-only opt-in via
`FERMIX_OPIK_ENABLED`), so its mapper/test changes land in the same diff and
the same `mix test` gate as the provider work. The dividing line:

| You added… | Plugin change needed? |
|---|---|
| A tool that uses `Tools.Telemetry.exec` | **No** — it reuses `[:fermix, :tool, :exec]`, already handled |
| A provider that uses `Providers.Telemetry.emit_call` | **No** (but add a new provider's `provider_string/1` mapping for cost) |
| A genuinely **new event name** you want in Opik | **Yes** — add it to `FermixOpik.Reporter`'s `@events` **and** handle it in `FermixOpik.Aggregation.apply_event/5` |
| A new **run kind** (new lifecycle events) | **Yes** — same as above, plus decide root-vs-nested via `parent_session` |

If the plugin doesn't subscribe to an event, that event is simply invisible to
Opik — the live JSONL is unaffected.

## Verify (same discipline as everywhere)

- Write the telemetry assertion **red first, then green** — prove the event
  actually carries `session_id`/the fields you expect before trusting it.
- New exporter handling: extend `aggregation_test.exs` (one trace, correct
  nesting) under `apps/fermix_opik`.
