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

### Proving a policy denial

A tool that refuses a call because the sandbox or net guard denied it attaches
`policy_enforcement: %{source:, decision:, phase:}` to its `:metadata` — the only
machine-checkable claim that the operation never began. Error text is **not**
proof: a command that genuinely ran and exited non-zero produces error text too,
so consumers (the eval harness's `tools_none_succeeded` gate) key off this marker
and nothing else.

Derive it, never hand-write it: `Sandbox.pre_execution_denial/1` maps a denial
reason to the map and returns `nil` for anything that is not a policy denial (a
missing working directory, an env-build failure). Only stamp
`phase: "pre_execution"` where the code path proves nothing has executed yet —
`Tools.Shell` attaches it solely in the `Sandbox.shell_plan/3` else-branch, which
is strictly before the command runs. The emitter treats only `[:tool, :agent,
:success]` as authoritative, so a tool *can* set this field decoratively; doing so
is a false safety claim.

The fields are three fixed strings with no user content, so `Mapper.tool_span/3`
exports them outside the content-capture gate — a blocked-before-execution claim
must stay provable in a content-free export.

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

### The `:tokens` map

```elixir
%{prompt: p, completion: c, cached: cache_reads, cache_write: cache_writes}
```

`:total` is **derived, not emitted.** `FermixOpik.Mapper.usage/1` computes
`total = given || prompt + completion`, and every provider adapter sends only
`:prompt`/`:completion` plus whichever cache keys the vendor reported. Do not add
`:total` to a new adapter — it changes nothing downstream and makes the fleet
inconsistent. (`Realtime.SessionServer` is the one emitter that still sends it.)

Every key except `:prompt` and `:completion` is **omitted when the vendor did not
report it**, never defaulted to `0`. A fabricated `0` is indistinguishable from a
measured one, and the benchmark rate card decides cache-aware versus ceiling
pricing on whether the count is *present* — so a defaulted zero makes a cold call
claim a discount nobody measured.

`:prompt` **keeps whatever meaning that provider already gave it** — on
Anthropic it is the blended `input + cache_creation + cache_read` figure. Do not
un-fold it: `total_tokens` is what every historical leaderboard row was measured
with, and changing the sum breaks comparability with all of them. The cache
counts ride **alongside** as new keys; a consumer subtracts to recover the
uncached remainder.

`:cached` is the cache-**read** subset of the input, `:cache_write` the
cache-**creation** count. A vendor that does not report one gets **no key at
all** — never a `0`. A reported zero ("nothing was cached") and an unreported
count ("this surface publishes no cache detail") price differently, and once the
two collapse the difference is unrecoverable from the trace. A present count
that is not a non-negative integer raises rather than rounding to zero.

Where the counts come from (verify a field name against the surface, never
guess): Responses `usage.input_tokens_details.cached_tokens`; Chat Completions
`usage.prompt_tokens_details.cached_tokens`; Anthropic Messages
`usage.cache_read_input_tokens` + `usage.cache_creation_input_tokens`; Realtime
`usage.input_token_details.cached_tokens` (singular `token`).

`:cache_write` is **Anthropic-only today, and that is a gap rather than a vendor
limit.** OpenAI bills cache writes at 1.25x uncached input on GPT-5.6 and later
(GPT-5.5 and earlier publish no write rate) and reports the count as
`usage.input_tokens_details.cache_write_tokens` — no adapter reads it. Until one
does, a GPT-5.6+ turn prices its written tokens at 1.0x, understating that leg by
20%, and the benchmark's rate card can never label such a turn `cache_aware`.
Closing it is one field read in the four OpenAI adapters plus a second key name
in the harness's span reader.

`Mapper.usage/1` exports the pair as `cached_input_tokens` /
`cache_creation_input_tokens`, dropping nils exactly as it drops the others.
**Opik's own auto-cost ignores cache entirely** — its `total_estimated_cost` is
the naive `prompt × full_input_rate + completion × output_rate` — so this split
is the only record in the trace from which a cache-aware price can be computed
at all. The allowlist in `Mapper.usage/1` is the whole contract: a token key not
named there never reaches a span.

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

## Skill curation

The skill-curation pass (MILESTONE_26_SKILL_CURATION) is a run kind with two
session shapes: a cycle mints `skill_curation:<rand>` (scheduled runs are
roots; a manual `/skills review` passes
`parent_session: "command:skills:<channel>:<chat>"` through, the soul-curation
convention), and an approved creation/update task mints
`skill_curation:create:<token>` with the approving command as parent. Bookends
via `FermixCore.SkillCuration.Telemetry` — never hand-rolled:
`[:fermix, :skill_curation, :run_start]` (`stage: :cycle | :create`,
`trigger`), `run_complete` (counts only: `messages_scanned`,
`checkpoints_included`, `messages_dropped_caps`, `candidates`, `dropped_*`,
`deferred`, `proposals_new|update|archive`, `delivery_status`, …), and
`run_error` (`reason_kind`). The miner/drafter provider calls ride
`Providers.Telemetry.emit_call/3` with the run's session id.
`Trace.TelemetryHandler` records all four events as `agent_event` rows;
`FermixOpik.Aggregation` opens/closes the root (`infer_kind` tags
`skill_curation:` prefixes `:skill_curation`) and its `run_complete` clause is
the count-field allowlist. The fourth event,
`[:fermix, :skill_curation, :proposal_actioned]` (`action:
approve|deny|unpark|expire`, `kind`, `age_ms`), fires when the owner acts —
typically days after the cycle trace shipped — so the exporter renders it as
its own self-closing `skillcur:<action>` trace (the plugin-dist shape), never
a child span.

## Outbound MCP client lifecycle

A remote MCP **client** starts, discovers tools, drifts, reconnects, refuses a
call, loses its owner, and tears down — all before or outside any tool
invocation, so none of it can ride `[:fermix, :tool, :exec]`. Every one of those
phases emits `[:fermix, :mcp_client, :lifecycle]` through
`FermixCore.Capabilities.MCP.Telemetry.emit_lifecycle/5` (phase, source-qualified
server identity, optional plugin, result/`error_class`, attempt +
`duration_ms`) — never hand-roll the event. The `mcp_client` root is deliberate:
inbound MCP (Fermix as a *server*) owns `[:fermix, :mcp, :inbound, :tools_listed]`
and `[:fermix, :mcp, :inbound, :call]`, and the outbound client must not share a
prefix with server-side events. One stable name carries all eight phases; a
`[:fermix, :mcp_client, <phase>]` tail would never be delivered.

The emitter **accepts no free-form metadata map**. Its metadata is an explicit
allowlist of constructed keys (`source_id`, `plugin`, `phase`, `result`,
`error_class`, `attempt`, plus correlation), because a remote client holds
exactly what must never reach a trace: the bearer credential and authorization
headers, the MCP session ID, the workspace ID, the endpoint URL, discovered
schemas, tool arguments, and response bodies. `error_class` is *derived* from the
`{:error, reason}` — an atom, or a tagged tuple's atom head; anything else
(a message body, where a URL or token would hide) flattens to `"unclassified"`.
`source_id` is serialized to a stable string (`"plugin:eden"`, `"operator:fs"`):
a tuple raises on the daemon wire path and only `inspect`s into JSONL.

Routing splits on **whether a turn exists**, not on a retry:
`initialize`/`discover`/`ready`/`owner_down`/`teardown` happen at boot/teardown
with no session, so `Trace.TelemetryHandler` records them as
`mcp_client_lifecycle` `agent_event` rows and the Opik exporter renders each as
its own self-closing `mcp_client:<phase>` trace (the `[:fermix, :plugin, :dist]`
shape). `security_block`/`drift`/`reconnect` can fire mid-turn, so they nest as
child spans via `Mapper.mcp_client_span/3` when the caller passed its turn
`session_id`, and self-close when it did not. Nesting a boot phase would either
drop it (nil session) or mint a phantom root that `infer_kind/1` mislabels
`:subagent` — the orphan span this split exists to prevent.

The same module owns `[:fermix, :capability, :mcp_name_collision]`
(`emit_collision/4`), fired when two `{server, tool}` pairs sanitize to one
agent-facing name. It records as an `agent_event` row; it is not exported to
Opik.

## Reminder lifecycle (temporal events)

A reminder **delivery** is deterministic — no `AgentLoop`, no provider call, no
session — so its lifecycle cannot ride any agent-run family. Every transition
emits the single stable name `[:fermix, :reminder, :lifecycle]` through
`FermixCore.Temporal.Telemetry` — never hand-rolled, and never a
`[:fermix, :reminder, <phase>]` tail of its own (exact-name binding would drop
it). A post-delivery **follow-up** is the other side of that line: it calls
`AgentLoop.run/1`, so it is a run kind with its own `session_id` and its own
per-phase names — `[:fermix, :reminder, :followup_start | :followup_complete |
:followup_error]`, emitted through `FermixCore.Temporal.FollowupTelemetry` and
bound individually in `FermixOpik.Reporter`. The split is "has a session or
not": a follow-up that never reached a model has none and stays on the
lifecycle event, as the `:followup_skipped` phase. The lifecycle emitter
enforces a fixed metadata allowlist: `phase` (`materialized | claimed |
delivered | retry_scheduled | failed | expired | superseded | cancelled |
event_completed | scheduler_error | followup_skipped`),
`component: "temporal_scheduler"` (the
`agent_field`, so JSONL rows name their emitter instead of `"unknown"`),
correlation ids (`event_id`, `reminder_id`, `occurrence_key`, `rule_id`),
`platform`, `attempt`, `result`, and a **derived** `error_class` (atom, tagged
tuple's head, else `"unclassified"` — raw reasons/bodies never pass through).
Measurements: `duration_ms` only where work occurred (the channel attempt),
`count: 1` otherwise. Reminder text is attached only behind the shared content
gate. `Trace.TelemetryHandler` records it as a `reminder_lifecycle`
`agent_event` row; `FermixOpik.Aggregation` renders each event as its own
self-closing `reminder:<phase>` trace correlated by `event_id`/`reminder_id`
(the plugin-dist shape — no session, so nesting would mint a phantom root).
`TraceFile.normalize_agent_event/2` is deliberately not extended (the
harness/plugin-dist/MCP-client precedent): `mix opik.replay` skips reminder
rows. The event tools themselves (`event_store`, `event_list`, `event_update`,
`event_remove`) are ordinary built-ins riding `[:fermix, :tool, :exec]` with
`input:` passed explicitly.

## Meeting notetaker runs

A meeting is a **run kind**: `FermixCore.Meetings.Session` mints
`session_id = "meeting_<id>_<ts>"` with `parent_session` = the requesting
turn's session (nil for CLI-origin), and every emission goes through
`FermixCore.Meetings.Telemetry` — never hand-rolled. Bookends are
`[:fermix, :meeting, :run_start | :run_complete | :run_error]`; every state
transition additionally emits `[:fermix, :meeting, :phase]`
(`count: 1`, `from`/`to`/`reason` as atoms-as-strings, never free text).
Shared metadata: `agent: "meeting:<id>"`, `meeting_id`, `platform`, `origin`
(`channel | cli | job`, derived at mint). `url`/`title` attach **only** behind
the content gate (a meeting URL can embed a passcode). `run_start` carries
`max_duration_ms` — the Opik exporter's sweep floor for the root; omit it and a
quiet meeting gets force-closed at the idle TTL. `Trace.TelemetryHandler`
registers all four; `FermixOpik` binds them (`kind: :meeting`,
`infer_kind("meeting_" <> _)`, phase spans via the mapper). STT rides the
provider emitter with the meeting `session_id`: chunked batch calls span
per-segment, native streams (deepgram/xai/local) emit **one** provider call per
stream lifetime at terminal (`Transcription.Support.emit_stream_call/5`) — a
stream session is *not* a run kind. Summarizer calls are ordinary llm spans
inside the meeting session. Ingress voice-note transcription stays sessionless
(pre-turn), unchanged.

## Sessionless channel points (pairing, push, transport posture)

Pairing decisions and push deliveries are **point events with no agent
session** (like plugin dist): a pairing resolves in `PairManager` and a push
fires after the turn already closed. Both go through `FermixChannels.Telemetry`
— `emit_pair(channel, status, duration_us)` with
`status ∈ approved | denied | expired | rate_limited`, and
`emit_push(channel, status, duration_us)` with `status ∈ sent | failed` —
emitting `[:fermix, :channel, :pair]` / `[:fermix, :channel, :push]`
(`count: 1` + `duration_us`; `channel`/`status` metadata, atoms only). Never
hand-roll the event, and never attach device names, tokens, or preview bodies —
the payloads are ciphertext by design and the trace must not be the plaintext
side channel. `Trace.TelemetryHandler` maps both to `agent_event` rows; the
Opik exporter deliberately does **not** subscribe (no session to nest under),
so a missing pair/push trace in Opik is expected, not a bug.

A channel **transport** crossing into or out of a degraded posture is the third
event of this family: `emit_transport(channel, status, consecutive_failures,
error_class)` with `status ∈ degraded | recovered`, emitting
`[:fermix, :channel, :transport]` (`count: 1` + `consecutive_failures`;
`channel`/`status`/`error_class` metadata, atoms only). It carries **no
`duration_us`** — a state transition times nothing, and a fabricated zero would
read as a real measurement. It fires on **transitions only**: a poller that
emitted per failure would rebuild in telemetry the very flood that its log
de-duplication exists to prevent (prod logged 27,394 consecutive Telegram poll
timeouts across two days with no signal anywhere). `error_class` is classified
by the caller and guarded to an atom by the emitter, so no response body, URL,
or credential can reach a trace field. `Trace.TelemetryHandler` maps it to an
`agent_event` row keyed on `channel`; Opik does **not** subscribe, for the same
reason as pair/push.

## Computer-history summarizer (a headless run with no bookends)

The summarizer is **one bounded provider call per cycle**, not an agent loop:
it mints `session_id = "computer_history_summarize:<unix_ms>"` with **no**
`parent_session` and emits **no** lifecycle bookends — its provider span (via
the standard provider emitter, `agent: "computer_history_summarizer"`) is the
whole run. The Opik exporter keys the run kind off the id prefix
(`infer_kind("computer_history_summarize:" <> _) → :computer_history_summary`)
and the root closes by TTL sweep; keep the prefix and the exporter clause in
lockstep if either changes. Event **content** rides the summarizer's own
consent gate (`Gate.allow?({:summarizer, route})`) before it ever reaches the
provider emitter, so the content-capture switch below is the second gate, not
the first.

## Content (prompts / responses / tool IO)

Attach bodies **only** behind `FermixCore.Telemetry.capture_content?/0`, and
shape them with `FermixCore.Telemetry.preview/1`. With capture **on** (the
default) `preview/1` passes content through whole; with capture **off** it
bounds everything (2k chars, default inspect limits). Capture-on also enriches
some emitters: a failed browser action attaches the profile's recent
console/JS-exception buffer to its error details.

`config/runtime.exs` is the **one place** the default is decided — on unless
`FERMIX_TRACE_CONTENT=0`. Bodies never leave the machine: the JSONL lives under
a `0700` `FERMIX_HOME` and the Opik instance is local, so the privacy argument
for a lean default does not apply, and a trace missing the request and the
response cannot answer the questions traces exist for. The cost is disk —
`FermixCore.Trace` has no retention, and a busy day's `tool_exec.jsonl` runs to
tens of MB with content on. The test env pins it off (`config/test.exs`) so
every content assertion in the suite establishes its own precondition.

A field carrying user content obeys this switch even when it is not shaped by
`preview/1` — `agent_task_start` / `skill_invoke` `task_summary` is the one that
did not, and now does.

---

## When does the `fermix_opik` exporter also need a change?

The exporter lives **in-umbrella** (`apps/fermix_opik`, dev-only opt-in via
`FERMIX_OPIK_ENABLED`), so its mapper/test changes land in the same diff and
the same `mix test` gate as the provider work. The dividing line:

| You added… | Plugin change needed? |
|---|---|
| A tool that uses `Tools.Telemetry.exec` | **No** — it reuses `[:fermix, :tool, :exec]`, already handled |
| A provider that uses `Providers.Telemetry.emit_call` | **No** (but add a new provider's `provider_string/1` mapping for cost) |
| A genuinely **new event name** you want in Opik | **Yes** — three edits: add it to `FermixOpik.Reporter`'s `@events`, handle it in `FermixOpik.Aggregation.apply_event/5`, **and** give it a span/trace builder. Reporter+Aggregation alone is not enough: there is **no global metadata allowlist** — every builder in `FermixOpik.Mapper` hard-codes its own `Map.take`/`drop_nil` key set, so a key no builder names is silently dropped |
| A new **run kind** (new lifecycle events) | **Yes** — same as above, plus decide root-vs-nested via `parent_session` |

Independently of Opik, **any** new event name that should appear in the JSONL
trace stream must be registered in `FermixCore.Trace.TelemetryHandler`
(`event_definitions/0`) — this is not exclusive to new run kinds. Follow the
per-family shape: the owning emitter exposes a private `@trace_event_definitions`
list plus `trace_event_definitions/0`, and the handler appends it. `Trace.record/4`
guards `type in [:llm_call, :tool_exec, :agent_event, :channel_msg, :error,
:sandbox_event]`, so a non-tool, non-LLM event uses `trace_type: :agent_event`
with a `trace_event` string, and its `agent_field` must name a metadata key the
emitter actually sets (`:op` for plugin dist, `:name` for timeouts, `:source_id`
for the MCP client) — otherwise every row reads `"unknown"`.

If the plugin doesn't subscribe to an event, that event is simply invisible to
Opik — the live JSONL is unaffected.

## Verify (same discipline as everywhere)

- Write the telemetry assertion **red first, then green** — prove the event
  actually carries `session_id`/the fields you expect before trusting it.
- New exporter handling: extend `aggregation_test.exs` (one trace, correct
  nesting) under `apps/fermix_opik`.
