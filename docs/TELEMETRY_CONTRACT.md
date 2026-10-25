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

A second source stamps the marker: `Capabilities.AccessGate`, the one gate in
`Capability.execute/3`. It decides plugin tools whose manifest marks them
`access_sensitive`, any call made while another call of the same turn is parked,
and, through its first clause (`Cues.MandateGate`), **every** call a run woken
by a cue makes, flagged or not (see "Access-gate labels"). It derives the map
from `AccessGate.pre_execution_marker/1`
(`source: "access_gate"`, `decision: "confirm"` when it held the call for the
owner's confirmation, `"deny"` when it refused it, `phase: "pre_execution"`),
and only on the held and refused branches, where the executor was never called.
Because the executor never ran, the gate itself emits that model call's single
`[:fermix, :tool, :exec]` event through `Tools.Telemetry.exec/5`, under the
capability's name and with `success: false`.

### Access-gate labels

Every call the gate decides (every access-sensitive call, and every call of a
run a cue woke) also carries `access_gate`, a closed enum of how the gate
settled it: `direct` (the owner's clean, attended request), `scheduled` (a
job whose `allowed_tools` names it), `confirmed`, or one of `held_this_chat`,
`held_owner_inbox`, `held_voice`, `already_confirmed`, `refused_worker`,
`refused_cue_run`, `refused_unattended`, `refused_not_allowlisted`,
`refused_no_surface`, `refused_full`, `refused_confirm_mismatch`. The refused
labels are one function's output (`refused_<reason>`), so a new refusal reason
is a new label here. `refused_cue_run` is an access-sensitive call made by a job
run a cue woke (`trigger: "cue"` on the context) outside its mandate: it read
content an outsider wrote and no owner is in its loop, so the gate refuses it
right after the worker check and before the job-row allowlist, whatever the
job's `allowed_tools` say. A held call also carries
`access_intent`, the opaque id of the parked record. `refused_waiting` lands on
a call to any tool, flagged or not: the turn (or Realtime call)
that made it has a parked call still waiting on the owner, so the gate refused
it (`:access_waiting` on the context) with the same `deny` marker. The gate stamps a
dispatched call's label on the context it hands the executor, and `exec/5`
copies `access_gate`, `access_intent`, `validator` and `mandate_call_id` from
the context into the executor's own event, so no executor knows the gate exists
and the context wins over a caller's `:metadata`.

In a run a cue woke, `Cues.MandateGate` decides every call first, flagged or
not, and adds its own labels to the enum. A call to a tool the run's mandate
names (`tools`) is a **mandate call**: it is recorded as a `cue_mandate_calls`
row before any check, then decided `mandate_allowed` (the executor ran it; its
own event carries the label through the context, with no marker),
`mandate_proposed` (held for the owner's `/confirm`, marker `confirm`), or
refused with marker `deny` as `mandate_refused` (its arguments, `pin_args`, the
hourly limit of ten allowed or proposed calls per task, or the validator said
no), `mandate_disabled` (the mandate or `mandates_enabled` is switched off, it
fails its load checks, or it is not approved), `mandate_stale` (the cue is older
than `max_cue_age`, or its time is unknown) or `mandate_unpinned` (what the
mandate pins changed since the owner approved it; the mandate is disabled until
approved again). A call to a tool outside the run's tool set is refused as
`refused_cue_surface`, or, when the tool is access-sensitive, falls through to
`refused_cue_run`. In a mandated run a file tool reads only inside the job's
skill folder; when the job names no skill, or the folder cannot be read, the
call is refused as `refused_mandate_files`. Every mandate call also carries
`mandate_call_id` (its row) and `validator: "program" | "none"` (whether the
owner's validator program decided), and an event the gate emitted itself adds
`mandate_reason`, Fermix's own sentence for the decision (a validator's own
words stay in the row as "validator refused"; no argument the model sent is in
it). A proposal the owner confirms runs later, from `/confirm` or an answer
from one of the owner's devices (the Mac app, the management socket), under the
proposing run's `session_id`, and its executor's event carries
`access_gate: "confirmed"` and the call's `mandate_call_id`. `Mapper.tool_span/3`
exports `validator`, `mandate_call_id` and `mandate_reason` outside the
content-capture gate beside the label.

The run the owner confirmed is not a model call. The daemon runs it later (a
tap, `/confirm`, a spoken yes), with the parking turn's `session_id` and
`parent_session` from the recorded snapshot, and its exec event carries
`access_gate: "confirmed"` and the same `access_intent` as the held one: that id
pairs "held" with "ran". Both keys are exported outside the content-capture
gate (a closed enum and an opaque id). When the parking turn's trace has
already shipped, `Aggregation` ships the confirmed exec as its own
self-closing `access_gate:confirmed` trace instead of dropping it at the
closed-session tombstone, or, once that tombstone is pruned, opening a phantom
root for the turn. Park, confirm, decline, expiry, a changed plugin and
an unreachable owner inbox are one `Logger` line each (tool, intent id,
reason; never argument values or transcript text).

### An allowed variable the sandbox could not pass

The opposite claim, kept distinct on purpose. When an allow-listed environment
variable cannot be read where the daemon runs, the shell command still executes
without it, and the tool's `:metadata` carries `env_unresolved: [names]` (names
only, no values, no reasons). It is **not** a policy denial and never carries
`policy_enforcement`: the command ran. `Mapper.tool_span/3` exports the names
outside the content-capture gate because they are operator configuration, not
user content. The reason and the remedy sentence go to the model in the tool
result and to the daemon log once per transition (`Sandbox.EnvHealth`), and
readiness publishes the name in the sandbox pane until it resolves.

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
   `"cron_<job>_<YYYYMMDD_HHMMSS>_<6 hex>"`), and a **`parent_session`** if it
   was spawned by another run (that's what nests it under its parent in the
   trace). A job run's id ends in a random suffix so two runs of one job started
   in the same second never share a trace (see "Cue runs" below);
2. emit **lifecycle bookend events** — start / complete / error — carrying that
   `session_id`. Model them on `FermixCore.Jobs.Telemetry` (jobs) or
   `FermixCore.Agents.LifecycleTelemetry` (subagents/skills). Without an opener
   the trace can't be stamped with the run's metadata; without a closer it only
   ships via the exporter's TTL sweep.
3. route those events into the JSONL trace stream via
   `FermixCore.Trace.TelemetryHandler` (`event_definitions/0`).

## In-loop context compaction

When a turn's tool results near or exceed the model's context window, the agent
loop compresses older results into digests and retries the provider call. Each
reduction applied emits `[:fermix, :agent_loop, :context_compaction]`
(measurements `%{count: 1, results, bytes_before, bytes_after}`; metadata
`session_id`, optional `parent_session`, `agent`, `iteration`, `level`,
`trigger` in `:budget | :recovery`). Each recovery round after a provider
refused a request as too large emits `[:fermix, :agent_loop, :context_recovery]`
(measurements `%{count: 1}`; metadata `session_id`, optional `parent_session`,
`agent`, `iteration`, `round` 1..3, `outcome` in `:recovered | :refused_again |
:nothing_left | :digest_failed`). Both are point events. `FermixOpik` renders
them via `Mapper.context_compaction_span` / `Mapper.context_recovery_span` as
`general` spans named `context_compaction` / `context_recovery`, nested under
the compacting run by `session_id`; the span metadata is `agent`, `iteration`
and the event's own keys (`level`, `trigger`, `results`, `bytes_before`,
`bytes_after`, or `round`, `outcome`), with atoms as strings. A digest call is
an ordinary provider call carrying `agent: "tool_result_digest"` and needs nothing
here.

## Plugin distribution ops

Plugin `install`/`uninstall`/`gc` emit `[:fermix, :plugin, :dist]`
through `FermixCore.Plugins.Dist.Telemetry.emit/5` (op, plugin, version,
result/reason + `duration_ms`) — never hand-roll the event. These ops run in
the installer or a CLI VM with no agent session, so they carry no `session_id`:
`Trace.TelemetryHandler` maps each to a `plugin_dist` row in `agent_event`,
and the Opik exporter renders each op as its own self-closing `dist:<op>`
trace.

## Plugin auth ops

Plugin `login`/`refresh`/`logout`/`set`/`clear` emit `[:fermix, :plugin, :auth]`
through `FermixCore.Plugins.Auth.Telemetry.emit/4` (op, plugin, outcome +
`duration_ms`) — never hand-roll the event. In the daemon they run in a setup
flow or a management job with no agent session, so they carry no `session_id`:
`Trace.TelemetryHandler` maps each to a `plugin_auth` row in `agent_event`
keyed on `plugin`, and the Opik exporter renders each op as its own
self-closing `auth:<op>` trace (tag `auth`). A `fermix plugins auth` CLI verb
emits the same event from a tree-less VM where no handler is attached, so a
CLI-run op reaches neither the JSONL trace nor Opik; the operator reads its
sentence on stderr. A token manager's own background refresh is not one of
these ops: its refusal reaches the daemon log (the `TokenManager` line, with
the vendor's words) rather than this event.

The metadata is a fixed allowlist: `op`, `plugin`, `result` (`ready` or
`logged_out`, else `error`), a **derived** `error_class` (the reason's atom, or
a tagged tuple's atom head, else `unclassified`), and — only when the provider
refused the saved sign-in client (`Auth.ClientRejection`) — the vendor's own
`vendor_error` code and `vendor_description` (redacted and bounded by the
classifier). The raw reason never rides: a sign-in reason can carry the
authorize URL, which must reach no log and no trace, and a vendor body can carry
anything. `Plugins.Auth` logs each failed op once with the same class (plus the
vendor's words for a refused client), so a failed sign-in the daemon ran is
diagnosable from the trace, the daemon log and the operator's surface alike.

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
`duration_ms`) — never hand-roll the event. The `mcp_client` root names the side
Fermix is on: the client of a server it connects to. One stable name carries all
eight phases; a `[:fermix, :mcp_client, <phase>]` tail would never be delivered.

The emitter **accepts no free-form metadata map**. Its metadata is an explicit
allowlist of constructed keys (`source_id`, `plugin`, `phase`, `result`,
`error_class`, `attempt`, plus correlation), because a remote client holds
exactly what must never reach a trace: the bearer credential and authorization
headers, the MCP session ID, the workspace ID, the endpoint URL, discovered
schemas, tool arguments, and response bodies. `error_class` is *derived* from the
`{:error, reason}` — an atom, or a tagged tuple's atom head; anything else
(a message body, where a URL or token would hide) flattens to `"unclassified"`.
`source_id` is serialized to a stable string (`"plugin:acme"`, `"operator:fs"`):
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

## Open loop check-ins

An open loop (M78) is an intention the owner stated with the date it matters
by. The scheduler decides when one is due, and a **check-in** is the one
isolated run that may speak about it. A check-in calls `AgentLoop.run/1`, so it
is a **run kind**, and it is always a **root**:
`FermixCore.OpenLoops.Telemetry.correlation/2` mints
`session_id = "open_loop_<id>_<touch>"` (`touch` is the touch the run would
make, the row's `touches + 1`) and `agent: "open_loop:<id>"`, and the run's loop
context takes both from it, so its provider and tool spans correlate with the
bookends by construction. There is no `parent_session`: the scheduler spawned
the run, not another run, and the turn that captured the loop closed days
before (the follow-up reason). A retry after a timeout or an error keeps its
touch, and so its session id. The `followup_` prefix belongs to the reminder
follow-up and stays there.

Every emission goes through `FermixCore.OpenLoops.Telemetry` — never
hand-rolled. The bookends are `[:fermix, :open_loop, :checkin, :start |
:complete | :error]`, with shared metadata `agent`, `session_id`,
`open_loop_id`, `touch` and `component: "open_loop_checkin"`. `start`
(`count: 1`) adds `rung` (`1 | 2`), `horizon_class` (`long | medium | short |
imminent`), `active_hours` (the `HH:MM-HH:MM` hours the run was admitted under,
snapshotted) and `max_duration_ms`, the run's watchdog and the exporter's sweep
floor. `complete` (`duration_ms`) adds `outcome`: `spoke | silent | closed |
empty | delivery_failed`, each a run that finished. `error` (`duration_ms`)
adds `status` (`timeout | error`) and `error`, a string (a binary as it is, any
other term inspected). The message a `spoke` run sent rides as `output`, shaped
by `Telemetry.preview/1`, only when `capture_content?/0` is on. The delivery
destination reaches no field: no function in the emitter accepts one.

Two point events have no run behind them, so they are sessionless, as the
reminder rail's pre-run skips are. `[:fermix, :open_loop, :skipped]`
(`count: 1`) is the scheduler declining to start a check-in: `open_loop_id`
(absent when the skip concerns no single loop), `reason` (`disabled | budget |
active_hours | no_target | max_children | closed_meanwhile`) and
`component: "open_loop_scheduler"`, and never a `session_id`.
`[:fermix, :open_loop, :settled]` (`count: 1`) is a loop's state moving:
`open_loop_id`, `from` (the live state the write left: `open | due | asked`),
`to`, `answer` (`done | plan | not_yet | stop | drop | asked`, absent when no
answer caused the move), `by` (`main_agent | checkin | scheduler`; every expiry
is `scheduler`) and `component: "open_loops"`, plus the settling turn's
`session_id` only when the caller has one. That is the whole allowlist. The
emitter checks every word against its closed set and raises on anything else
rather than emit a word no consumer knows, and drops nils rather than emit
them.

`Trace.TelemetryHandler` registers all five as `agent_event` rows:
`open_loop_checkin_start`, `_complete` and `_error` keyed on `agent`,
`open_loop_skipped` and `open_loop_settled` keyed on `component`. `FermixOpik`
binds all five. The bookends open and close a root of kind `:open_loop_checkin`
(`infer_kind("open_loop_" <> _)`, so a closer arriving without its opener does
not read as a `:subagent` phantom root), named by the agent with the session id
as its fallback, unthreaded, and swept by `max_duration_ms`. `complete` closes
it with status `ok` and the outcome in its metadata; `error` closes it with its
`status` word and the error as its output. The root's metadata is the allowlist
`component`, `open_loop_id`, `touch`, `rung`, `horizon_class`, `active_hours`,
`outcome`. Because a retry reuses its session id inside the closed-session
tombstone window, the opener lifts that session's tombstone: an opener is a new
run, never a late span of the one that shipped. `skipped` and `settled` render
as self-closing `open_loop:<reason>` and `open_loop:settled` traces tagged
`open_loop`, correlated by `open_loop_id`; a settlement's `session_id` is
metadata there, never a parent, because the settling turn may already have
shipped. `TraceFile.normalize_agent_event/2` is deliberately not extended (the
reminder precedent): `mix opik.replay` skips open-loop rows. The main agent's
loop tools and the check-in's `open_loop_respond` are ordinary built-ins riding
`[:fermix, :tool, :exec]` through `Tools.Telemetry.exec/5`.

`[:fermix, :open_loop, :fault]` (`count: 1`) is the third sessionless point
event, the open-loop counterpart of the reminder rail's `scheduler_error`
phase: `OpenLoops.Scheduler` logs and traces every failed step through
`OpenLoops.Telemetry.fault/3`. Its metadata is `stage` (`scan | claim | release
| timer | start_checkin | sweep`; a read needed to weigh a due loop is `scan`,
and a dead run's claim that could not be recovered is `release`),
`open_loop_id` (absent when the fault concerns no single loop),
`component: "open_loop_scheduler"` and `error_class`, derived exactly as the
reminder emitter derives it (an atom, a tagged tuple's atom head, else
`unclassified`); the reason itself stays in the log line. A full supervisor
stays the `max_children` skip. It is the trace row `open_loop_fault`, keyed on
`component`, and in `FermixOpik` a self-closing `open_loop:fault` trace tagged
`open_loop` carrying `stage`, `open_loop_id` and `error_class`; both consumers
bind it beside the five above.

## Cues: lifecycle, sources, filter calls and cue runs

A cue is an item an outside source sent (a feed entry, a stream event, a local
push). Every watcher listening to the source gets a delivery of it; a filter
call may pass or drop the delivery, and a cue run (a job run with
`trigger: "cue"`) settles it. Items and deliveries move through two stable
event names, both emitted only through `FermixCore.Cues.Telemetry` — never
hand-rolled, and never a `[:fermix, :cue, <phase>]` tail of their own
(exact-name binding would drop it, the reminder lifecycle's rule):

- `[:fermix, :cue, :lifecycle]`, `Cues.Telemetry.lifecycle(phase,
  measurements, metadata)`: one event per item or delivery transition.
- `[:fermix, :cue, :source]`, `Cues.Telemetry.source(phase, metadata)`: one
  event per source worker transition.

**Ids and counts only.** A cue carries an outside party's text, so both
emitters build their metadata from a fixed allowlist and raise on any other key;
there is no pass-through map a caller could put text into. Lifecycle metadata
may hold the ids `source_ref`, `cue_id`, `delivery_id`, `watcher_id`, `gap_id`,
`job_id`, `run_id`, `filter_call_id`, `mandate_call_id`, `proposal_id`,
`session_id`, `parent_session`; the labels `reason`, `outcome`, `state`,
`decision`, `validator`, `mandate`, `tool`, `provider`, `model`, `kind`,
`status` (an atom, or a string of at most 128 bytes); the counts `attempt` and
`count`; `result` (`:ok | {:ok, _} | :error | {:error, _}`), which reaches the
event only as its tag plus a **derived** `error_class` (the reason's atom, a
tagged tuple's atom head, else `"unclassified"`); and one content key,
`content`, dropped unless `FermixCore.Telemetry.capture_content?/0` is on (today
only a filter decision's reason, on `passed` and `dropped`). The emitter adds
`phase` and `component: "cues"`. Measurements are non-negative integers among
`count`, `accept_ms` (receipt to commit, on `accepted`), `queue_ms` (receipt to
the task's claim, on `claimed`) and `duration_ms`; none given means
`%{count: 1}`. An event names one delivery (`delivery_id`); there is no
`cue_count`.

**A phase's class is its session**, and the emitter enforces it:

| Class | Phases | `session_id` |
|---|---|---|
| sessionless | `accepted`, `duplicate`, `conflict`, `stale`, `rejected`, `rate_limited`, `over_budget`, `routed`, `gap`, `expired`, `ingest_error`, `sweep_error` | refused (raises) |
| filter-scoped | `passed`, `dropped`, `filter_retry`, `filter_held`, `filter_failed` | the filter call's; optional |
| run-scoped | `claimed`, `settled`, `retry`, `exhausted` | the cue run's; required |
| proposal-scoped | `proposed`, `confirmed`, `denied`, `proposal_expired`, `proposal_refused` | the proposing run's; required |

Who emits what:

- **Accept and route** (`Cues.Ingest`, one event per item after the
  transaction commits): `accepted` (`cue_id`, `accept_ms`), or what happened
  instead: `duplicate` (seen before), `conflict` (same identity, different content),
  `stale` (older than the 7-day horizon), `rejected` (it failed validation),
  `rate_limited`, `over_budget`. Then `routed` per delivery created
  (`delivery_id`, `watcher_id`, `state` `pending` or `passed`), and for a
  watcher with no filter `passed` at once, with no session and
  `reason: "no filter"` (no filter call exists for it). A delivery evicted from
  a full inbox is `expired` with `reason: "inbox_full"`. A refusal at the HTTP
  door (401, 413, 429, …) emits nothing: it is counted in
  `cue_sources.reject_counts`. A watcher switched to no filter passes what
  waited for its filter in the switch's transaction, and `Cues.Watchers` then
  emits the same sessionless `passed` (`reason: "no filter"`, `cue_id`,
  `source_ref`) for each.
- **Gaps and expiry**: `gap` (`gap_id`, `reason`, measurement `count`) when
  ingest, the sweeper or a watcher's removal opens or extends a gap; `expired`
  with `reason: "lifetime"` from `Cues.Sweeper` and `"watcher_removed"` from
  `Cues.Watchers`.
- **Errors**: `ingest_error` (an ingest transaction, or a source worker's
  Repo call, failed; `result`) and `sweep_error`, whose `reason` names the step
  that failed: a retention step of `Cues.Sweeper` (`expire_lifetime`,
  `drop_payloads`, …), the filter dispatcher's `filter_reset`, `filter_claim`
  or `filter_reclaim` (its sweep's reclaim of `filtering` rows no task holds),
  or cue admission's `cue_claim` (the candidate scan, or one
  job's claim with its `job_id`) or `cue_settle` (a cue run's settle, with its
  `job_id` and `run_id`). Every
  `{:error, reason}` from ingest, a sweep, the dispatcher or admission is traced
  before it is returned or logged (the reminders' `scheduler_error` precedent).
  A stored row that cannot be read back (`{:error, {:corrupt, table, detail}}`,
  for instance a `cue_sources` row) reads `error_class: "corrupt"`.
- **Filter calls** (`Cues.Filters`, after the call's result is written and
  before its closer, each with the call's `session_id`, `filter_call_id`,
  `watcher_id`, `delivery_id`, `cue_id`, `source_ref`, `job_id`, `attempt`):
  `passed` or `dropped` (`decision`, the reason in `content`); `filter_retry`
  (a provider failure before the hold, a content failure with retries left, or
  a call stopped with its supervisor, `reason: "aborted"`); `filter_held` (the
  third provider failure in a row, and each after it); `filter_failed` (the
  third content failure: the delivery is exhausted). A failure adds `reason`
  (`provider_failure | content_failure | aborted`), `kind` (the failure's typed
  kind) and `result: {:error, kind}`.
- **Cue runs** (`Jobs.CueAdmission`, each with the run's `session_id`,
  `job_id`, `run_id`, `delivery_id`, `watcher_id`, `source_ref`, `state`,
  `attempt`): `claimed` when the scheduler's claim commits (`queue_ms`), then
  one of `settled` (the delivery is acked), `retry` (back to `passed` for
  another attempt) or `exhausted`, from the runner's settle or, for a reaped or
  crashed run, the scheduler's; these add `outcome` and `reason`
  (`ignored | acted | provider_failure | run_failure | reaped`). A settle that
  finds its delivery no longer held by the run emits nothing (it is logged).
- **Proposals** (`Cues.Proposals`, each with the proposing run's `session_id`,
  `proposal_id`, `mandate_call_id`, `job_id`, `run_id`, `delivery_id`,
  `watcher_id`, `mandate`, `tool` and `state`): `proposed` once an approve-mode
  mandate call's proposal is stored and waits for the owner (sent to the
  owner's chat when there is one, and offered to every app surface),
  `confirmed` or `denied` on the owner's answer, with `kind` naming the surface
  it came from (`telegram`, `signal`, `whatsapp` or `imessage` for `/confirm`
  and `/deny` in the owner's chat; `companion`, `mobile` or `management` for an
  answer from one of the owner's devices, `Cues.Proposals.decide/4`),
  `proposal_expired` from the sweeper, and `proposal_refused` with
  `reason: "unreachable"` (the chat's message could not be sent and no app can
  show the proposal) or `"recheck"` (at the owner's yes the mandate's switches,
  pins or validator no longer allowed the call). Every phase keeps the
  proposing run's `session_id`, whichever surface answered; no surface adds an
  event name. The confirmed call itself is its executor's own
  `[:fermix, :tool, :exec]` (see "Access-gate labels").

`[:fermix, :cue, :source]` metadata needs `source_ref` and may hold `kind`
(`feed | stream`), `status`, `reason`, `attempt`, `result` (tag plus derived
`error_class`) and `content` (a stream service's own error message, at most 512
bytes with control characters removed, kept only when content capture is on);
`count` and `duration_ms` become its measurements. Phases:
`connect` and `reconnect` (a feed's first good poll, and its first after a
failure; a stream's handshake), `disconnect` (`attempt`, `reason`, `result`;
`reason: :service_error` when a stream with no preset closed on its service's
error, with that error as `content`), `auth_failure` (a stream's refused
handshake), `backfill` (`duration_ms` is how far back a stream's rewind
reaches), `budget` (the daily budget is spent), `gap` (`reason` is the gap's,
`count`) and `stopped` (a worker that gave up: `reason: :refused` after a
stream's eighth connection in a row ended on its service's error, with the last
as `content`; or `reason: "crashed"` from `Cues.SourceManager` after a worker's
fifth crash in an hour). Emitted by the feed and stream workers (`Cues.Source.Feed`,
`Cues.Source.Stream`, through `Cues.Source.Worker.trace/3`) and by
`Cues.SourceManager`.

`Trace.TelemetryHandler` records the two events as `cue_lifecycle` and
`cue_source` `agent_event` rows (agent field `component`, so every row reads
`cues`).

**Opik.** `FermixOpik.Reporter` binds `[:fermix, :cue, :lifecycle]`, and
`Aggregation` places each phase by its session id alone:
- no session (every sessionless phase, and a filterless watcher's `passed`): its
  own self-closing `cue:<phase>` trace (tag `cue`), built like a reminder's and
  never tracked in state;
- the session of a filter call or a cue run that is still open: a `cue:<phase>`
  child span of that run, so a filter decision sits in the `cue_filter_` trace
  beside its model call, and a claim, settle or proposal in the run's trace;
- `claimed` is traced by the scheduler before the runner exists, so it opens
  the run's root itself; the job's `run_start` then adopts that root (its name,
  metadata, thread and sweep floor) as if it had created it;
- any other session, shipped or never seen (a proposal confirmed hours after
  its run's trace shipped, a crashed run reaped later): its own self-closing
  `cue:<phase>` trace that keeps the `session_id` in its metadata, so it is
  found beside the run's trace instead of being dropped at the closed-session
  tombstone or opening a phantom root.

The span and trace metadata is the emitter's allowlist, labels as strings, plus
the measurements. The exporter does not bind `[:fermix, :cue, :source]`: no
source transition has a session to nest under (the channel transport
precedent), so source traces are read from the JSONL stream.
`TraceFile.normalize_agent_event/2` is not extended for either event (the
reminder precedent): `mix opik.replay` skips cue rows.

### Filter calls (a run kind with one model call)

A filter call is one bounded model call deciding one delivery for one watcher,
in the shape of a Live call's gist. `Cues.Filters` mints its session id,
`cue_filter_<watcher_id>_<YYYYMMDD_HHMMSS>_<6 hex>` (UTC claim time; the
watcher id keeps its `cwt_` prefix), with **no** `parent_session`: no turn asked
for it, so it is always a root. Its bookends go through
`FermixCore.Cues.Filter.Telemetry` — never hand-rolled:
`[:fermix, :cue_filter, :run_start]` (`%{count: 1}`) as the call goes out, and
one closer after the result is written, `[:fermix, :cue_filter, :run_complete]`
or `[:fermix, :cue_filter, :run_error]` (`%{count: 1, duration_ms}`). Shared
metadata: `agent: "cue_filter"`, `session_id`, `filter_call_id`, `watcher_id`,
`delivery_id`, `cue_id`, `source_ref`, `attempt`, and `provider`/`model` only
when the watcher pins them. `run_complete` adds `status: "ok"` and
`decision: "pass" | "drop"`; `run_error` adds `status` (`provider_failure`,
`content_failure`, `aborted`, `stale` when the delivery had moved on before the
write, `settle_failed` when the write itself failed) and `error_kind`, the
failure's typed kind, never a message. The cue's text, the decision's reason and
the hint never reach a bookend. The model call is the adapter's own
`[:fermix, :provider, :call]` through `Providers.Telemetry.emit_call/3`, with
`agent: "cue_filter"` and the call's `session_id`; failover events carry
`agent: "cue_filter"`, `surface: :cue_filter` and the same `session_id`, so a
failover nests in the call's trace beside its model call. `Trace.TelemetryHandler`
records the bookends as `cue_filter_run_start`, `cue_filter_run_complete` and
`cue_filter_run_error` `agent_event` rows. `FermixOpik` binds them
(`kind: :cue_filter`, `infer_kind("cue_filter_" <> _)`, the trace named by the
session id); the closer's metadata adds `decision`, `status`, `error_kind` and
`duration_ms`, and a `run_error` carries `error_info` `CueFilterError` with the
kind. A watcher with no filter makes no filter call and has no filter session.

### Cue runs

A cue run is a scheduled-job run (`FermixCore.Jobs.Telemetry`, the
`[:fermix, :job, :run_start | :run_complete | :run_error]` bookends). Every job
run's session id is `cron_<job_id>_<YYYYMMDD_HHMMSS>_<6 lowercase hex>` (UTC
claim time), scheduled, manual and cue runs alike: the random suffix keeps two
runs started in one second apart, and the `cron_` prefix is kept, so
`fermix_opik`'s `infer_kind`, `Meetings.Session`'s origin and every other prefix
check read a cue run as a scheduled one. The bookends carry `trigger`
(`"schedule"`, `"manual"` or `"cue"`) on every run, and on a cue run also
`watcher_id` (which the runner puts on the run map it passes, since the run row
does not hold it) and `delivery_id` (the row's `cue_delivery_id`, the
`cue_deliveries.id` the run held); both are absent on any other run. The Opik
run trace's metadata carries `trigger`, `watcher_id` and `delivery_id`, and
`mix opik.replay` keeps all three. A cue run's tools are ordinary
`[:fermix, :tool, :exec]` events under the run's session, one per model call:
the gate labels each call it decides, a mandate call with a `mandate_*` label,
a call outside the run's tools `refused_cue_surface`, an access-sensitive one
outside its mandate `refused_cue_run` (see "Access-gate labels").

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

## Live voice runs

A call on a **task engine**, one that hands every task to Fermix through the
voice bridge, is a **run kind**, and it is always a **root**. There are two
task engines, GPT Live (`openai_live`) and Grok (`xai_realtime`, M70), and they
share this run kind, its six events and its id prefixes: `engine` and
`provider` on every event are what tell them apart. The local voice socket
mints `session_id = "voice_live:<n>"` for the call on either engine; the call's
session mints a *separate* `"voice_delegation_<n>"` for every backend turn it
delegates to, with `parent_session` = the call id. That parent link is the **only**
correlation between a call and its turns — a delegation shares no other field
with the call it came from — so it is what nests the turn's `llm`/`tool` spans
under the call's trace. A call opened from a turn may carry its own
`parent_session` as correlation metadata, but it never nests: the call outlives
the turn that asked for it (the meeting precedent).

A delegation keeps that `session_id` and `parent_session` whichever
conversation it runs in. Unless the call is private
(`[fermix_core.realtime] conversation = "private"`), its hand-offs run in the
chat's own conversation (M56 §4.1), so the events that name a conversation
key (the history read, the loop runtime, the queue's request events) name the
chat's, `{"companion","main",:root}`, while the message's `channel` stays
`voice`. The trace still nests under the call, because nesting follows
`parent_session` and never the conversation key. The request a hand-off
persists in the chat is marked spoken in the conversation store and reaches no
telemetry field, like every other piece of spoken content.

The phone's turns run in that same conversation (M56 D9): a phone message
carries the chat's key, so for a phone turn the events that name a
conversation key name the chat's too. The history read and the loop runtime
carry `conversation_key` `{"companion","main",:root}` beside the message's
`channel` `mobile`, and compaction's events carry that key; the queue's
request events, the conversation store's `[:fermix, :memory,
:message_persist]` and the memory review (its `session_id`, its
`channel`/`chat_id` and the Opik `thread_id` they fill) take their `channel`
from it and read `companion`. The turn's own events keep the message's
channel (`[:fermix, :agent, :message]` and its Opik thread `mobile:main`, the
queue's enqueue, the channel's message points), so a phone turn is still told
apart there. Nothing new is emitted.

A message typed in the chat while a call in the chat is up is an ordinary
chat turn (`main-*` session, M56 §4.4): it is told the call is up and may end
with no reply. Its `[:fermix, :agent, :message]` event carries `silent`, a
boolean, `true` only when the turn ended that way (its snapshot allowed it and
its reply was exactly `[SILENT]`); the Opik root carries it in its metadata.
`voice_call_context`, the tool such a turn reads the call with, emits through
`Tools.Telemetry.exec/5` like every tool, with `tasks` and `speech_bytes` and
no output preview: what was said reaches no field.

`send_to_channel` (M56 §4.7) sends a text to the owner's own inbox on a
channel they name, from any owner turn and from a call's task alike. Its one
exec event carries `channel` (the name asked for, at most 64 bytes),
`text_bytes` and `outcome`, one of `sent`, `invalid_args`, `text_too_long`,
`unsupported_delivery_platform`, `invalid_delivery_adapter`, `no_owner_inbox`
and `delivery_failed`, and no input preview: the text, which may have been
said aloud, reaches no field. The output preview is the result's sentence,
which names channels and never the text. The send itself is a channel delivery
and counts as the channel's own outbound message point.

A coding run a task of a call in the chat launches (M56 §4.7) is a harness run
like any other, and so a **root** of its own (`harness_<id>`, never nested:
it outlives the turn that launched it, and the call's run closed at
`call_stop` long before the run ends). Its `origin_session_id` is the task's
`voice_delegation_<n>`, whose own `parent_session` is the call: that is how a
run is tied to the call that asked for it, through the turn, as correlation.
Its completion re-enters the chat as an ordinary companion turn (`main-*`),
also a root of its own.

Every emission goes through `FermixCore.Realtime.LiveTelemetry` (the
detached task's owner included) — never hand-rolled. The six events are `[:fermix, :voice_live, :call_start |
:session_started | :delegation_start | :delegation_stop | :provider_error |
:call_stop]`. Shared metadata: `agent: "voice_live"`, `session_id` (the call
id), `call_uuid`, `engine`, `provider`, `device_id`, `model`, `voice`, and
`provider_session_id` once the vendor has named its session — that last one is
the only handle a vendor-side investigation has, and it exists nowhere else in
the trace. `engine` and `provider` are **required on every event**, passed by
the caller and never defaulted: `openai_live` with `openai` on a GPT Live call,
`xai_realtime` with `xai` and Grok's one pinned model on a Grok call. A caller
that leaves either out raises at the emitter rather than being filed under
GPT Live, and the detached task's owner passes the engine and provider
of the call the task came from. On Grok, `session_started` marks the session
configured and ready (its configuration applied and its starting context
acknowledged), not the vendor's first event.
`call_uuid` is the call's durable identity, minted with the session and the key
of its `voice_calls` record; the `voice_live:<n>` counter restarts with the VM,
so the UUID is what ties a trace to that record. The counter stays the trace's
session id. Nils are dropped rather than emitted. `call_start` carries `max_duration_ms` —
the Opik exporter's sweep floor for the root; omit it and a call that sits quiet
between delegations is force-closed at the idle TTL, and its ledger-bearing
`call_stop` then mints a second, empty root. It also sizes what the call started
with (M56 §4.3), never quoting it: `instructions_bytes` (the composed
instructions, the owner's details and memory files included) and `input_items`
and `input_bytes` (the starting `session.input`: the chat's newest messages and
earlier calls' gists; both `0` for a private call or an empty chat). The delegation events carry
`delegation_id`, `revision` and `turn_session_id`, and `delegation_stop` adds
the terminal word `status` (`completed | failed | cancelled`, and `timed_out`
on a detached stop; never a bare "ok")
with a `duration_ms` measurement. When a call in the chat showed the
delegation's result there (M56 §4.5: what the voice cannot say is written to
the chat's timeline while it says a short line), `delegation_stop` also
carries `server_seq`, the row it was written to, and `shown_bytes`, its size:
sizes only, so the shown text reaches no field, and neither does the line
said. `provider_error` carries the vendor's bounded
sentence and is **not** terminal: a Live moderation refusal cuts the audio and
the session keeps running.

A delegation can end **after** `call_stop` (M56 §4.6). A task still running
when a call in the chat ends is handed to `FermixChannels.Voice.Detached`,
which owns it until it ends into the chat, so its `delegation_stop` comes from
that owner, after the call's `call_stop`, through
`LiveTelemetry.detached_delegation_stop/5`: the same event, with the call's
`session_id` and `call_uuid` and the task's own `delegation_id`, `revision` and
`turn_session_id`, plus `detached: true` and its terminal `status`, which may
be `timed_out` (a detached task has a 30 minute wall clock), `duration_ms`
from its creation on the call to its end, and `server_seq`/`shown_bytes` of
its done row in the chat. Sizes only, as on the call. Its turn keeps its
`session_id` and `parent_session` (the call's id). The call's Opik root ships
at `call_stop`, so the aggregator attaches a detached stop only while that run
is open (it never opens a run for one, which would be an empty phantom root)
and its turn's later spans follow the tombstone rule of a run that outlived its
trace; the JSONL stream keeps every one. A task that ends from the boot pass
after a restart (`daemon_restarted`) emits nothing: it is a companion write,
logged.

`call_stop` is the run's whole cost record, and every value is a number:
`voice_seconds`, `voice_cost_millicents`, `backend_turns`, and
`accounting_complete` as `0`/`1`. A Grok call adds `voice_text_items`, the
billable text items it sent (the starting context and messages mirrored from
the chat, counted at send; a function output is not one), because Grok bills
the session clock and each text item; its `voice_seconds` is the connected
time, silence and mute included, and its `voice_cost_millicents` the local
estimate from those two. A GPT Live call sends no `voice_text_items`: the key
is absent, never `0`. A Grok call's `accounting_complete` is **always `0`**:
there is no vendor terminal usage to settle against, so it settles on the
local estimate and says so. A Grok call also says how long its owner waited
(`GrokLatency`): `user_turns` always, and, once there is a sample,
`generation_latency_ms_median`/`_max` (from the end of the owner's speech to
the first audio Grok generated for it) and `audible_latency_ms_median`/`_max`
(to the first of it the client reported playing), integer milliseconds. Only
the first reply after each turn counts, a latency with no sample is absent
rather than `0`, and a task's own time stays on its `delegation_stop`, so a
slow provider, a slow client and a slow backend remain three findings.
Metadata carries `reason` — `call_stop`, `cost_limit`, `max_session_duration`,
`provider_disconnected`, `session_expired`, and on Grok also `playback_stalled`, `playback_overflow`
and `call_ids_exhausted` — because a ceiling kill that read as a hang-up is
exactly what makes a torn-down call undiagnosable. A non-numeric measurement
raises at the emitter rather than reaching a trace as an unpriceable field.

**Voice is duration-priced and is never expressed as tokens.** A Live minute is
billed by the clock, so the ledger is seconds plus **integer millicents**
(1 cent = 1000) and there is no token count that could stand in for it;
inventing one would fabricate a unit the invoice does not have. The nested
delegation turns keep their own token usage on their own `llm` spans, so voice
cost and backend cost stay separately attributed rather than double-counted, and
an incomplete finalization stays visible as `accounting_complete: 0` rather than
reading as a measured zero-cost call. Spoken content — captions, transcript
fragments, the composed instructions, the starting input — reaches no field on
any of these events.

Backend work inside a delegation rides the shared emitters as usual
(`Providers.Telemetry.emit_call/3`, `Tools.Telemetry.exec/5`) with the
delegation's own `session_id`, so a Live turn is priced and rendered exactly like
any other turn.

A Grok call's own work rides the same shared emitters on the **call's**
`session_id`, with `agent: "voice_live"`, so it nests under the call's root
beside the phase spans. Every function call the Grok model makes (one per
call id) is one `[:fermix, :tool, :exec]` through `Tools.Telemetry.exec/5`
under the one name the session advertises, `fermix_task`, **rejected and
cancelled calls included**: metadata `action` (`submit`, `cancel`, or
`invalid` for arguments that did not parse), `status` (the terminal word of
its one output: `completed`, `failed`, `cancelled`, `superseded`, `busy`,
`rejected`) and `task_id` when it names a Fermix task; `success` is true for
`completed`, `cancelled` and `superseded`, and `duration_ms` runs from the call
to its output. It passes no input or output: the request the model sent and
the line it was answered with reach no field. Every Grok response that ends
is one `Providers.Telemetry.emit_call/3` with `provider: :xai`, the pinned
model, `status` `ok` for a completed response and `error` otherwise, a
`duration_ms` from `response.created` to `response.done`, and the vendor's own
token counts as `:tokens` (empty when the vendor sent none, never a
fabricated count). It passes no `:input`/`:output` whatever the capture
switch. That span is the vendor's account of one response, not the voice
bill, which is the `call_stop` ledger. A vendor failure reaches
`provider_error`, with the vendor's bounded sentence, before the session acts
on it. No field of any Grok event carries raw audio, a transcript, a caption,
memory text, an API key or an unsanitized provider payload.

`Trace.TelemetryHandler` registers all six events as `agent_event` rows,
flattening every metadata key and measurement, `engine`, `provider`,
`voice_text_items` and the latency summary included; `FermixOpik` binds them
(`infer_kind("voice_live:" <> _)` → `:voice_live`,
`infer_kind("voice_delegation_" <> _)` → `:voice_delegation`, root open and
close in `Aggregation`, which carries `engine`, `provider`, `model`, the
ledger (`voice_text_items` included) and the latency summary into the root's
metadata; phase spans via `Mapper.voice_live_span/3`, each naming `engine` and
`provider`; replay in `TraceFile`). `Mapper.tool_span/3` and the `tool_exec` replay keep a
`fermix_task` span's `status` and `task_id`, so a refused call stays told apart
from one that ran. Both id prefixes are minted outside `fermix_opik`; keep
them in lockstep with the exporter's clauses, or a `call_stop` arriving without
its opener reads as a `:subagent` phantom root.

A call in the chat leaves a **gist** (M56 §4.2), and the gist is a run kind of
its own: one bounded summarising call made after the call has settled and its
`call_stop` closed the call's run, so it is always a **root**, minted
`session_id = "voice_gist:<call_uuid>"` with no `parent_session` and tied to the
call by `call_uuid` alone. Every emission goes through
`FermixCore.Realtime.GistTelemetry`: `[:fermix, :voice_gist, :run_start |
:run_complete | :run_error]`, with `agent: "voice_gist"`, `session_id` and
`call_uuid`. `run_start` carries what it summarises by size (`tasks`,
`speech_bytes`, `input_bytes`) and `tainted`, whether anything drawn from
Computer History reached the call; `run_complete` has `status: "written"` and
the measurements `duration_ms` and `gist_bytes`; `run_error` has `status:
"failed"`, the bounded reason as `error`, and `count`/`duration_ms`. What was
said, the task results and the gist reach no field of these events. The
summarising call itself goes through the adapters'
`Providers.Telemetry.emit_call/3` with the same `session_id` and `agent:
"voice_gist"`, an ordinary `llm` span whose input and output follow the
content switch like every provider call's (the meeting summariser's
precedent). `Trace.TelemetryHandler` registers the three as `agent_event`
rows; `FermixOpik` binds them (`infer_kind("voice_gist:" <> _)` →
`:voice_gist`, the root opened by `run_start` and closed by either closer in
`Aggregation`); `mix opik.replay` skips them, as it skips the soul-curation
bookends. The call's row written after the gist, and the boot pass that
writes a row a dead daemon left owed (failing its pending gist), emit nothing
of their own: the row is a companion write, logged on failure.

## Sessionless channel points (pairing, push, render, transport posture)

Pairing decisions and push deliveries are **point events with no agent
session** (like plugin dist): a pairing resolves in `PairManager` and a push
fires after the turn already closed. Both go through `FermixChannels.Telemetry`
— `emit_pair(channel, status, duration_us, facts)` with
`status ∈ approved | denied | expired | cancelled | device_disconnected |
attestation | attestation_unavailable | platform_unsupported`
(`cancelled`: the window closed before a decision, by an owner's cancel, a
dropped `fermix pair` connection or a failed setup; `device_disconnected`: the
phone was gone when the owner approved; the last three: the phone's key
attestation was refused, Google's status list could not be used, or the phone
is not Android, each ending the window before the owner was asked), and
`emit_push(channel, status, duration_us, platform)` with `status ∈ sent |
failed` and `platform ∈ apns | fcm`, the service the push went through —
emitting `[:fermix, :channel, :pair]` / `[:fermix, :channel, :push]`
(`count: 1` + `duration_us`; `channel`/`status` metadata, plus the push's
`platform`, atoms only). The
pair event's `facts` add `platform` (`android | ios`), `attestation`
(`verified | refused | unavailable`) and `signer_role` (`development |
release`, set only when verified), each `nil` when no phone got that far;
never a chain, a key or a name. A refusal's internal check and detail go to
the daemon log (`mobile pairing refused: …`), not the event.
`expired` is the window's own end, which the phone and the management wire
both call `timeout`. Failed handshakes refuse only the address they came from
and never end a window, so they have no pair status. Never hand-roll the
event, and never attach device names, tokens, or preview bodies — the payloads
are ciphertext by design and the trace must not be the plaintext side channel.
`Trace.TelemetryHandler` maps both to `agent_event` rows; the Opik exporter
deliberately does **not** subscribe (no session to nest under), so a missing
pair/push trace in Opik is expected, not a bug.

A channel **render** is a point of the same family:
`emit_render(channel, result, duration_us)` emits `[:fermix, :channel,
:render]` (`duration_us`; `channel`/`status` metadata, atoms only, `:ok` or the
error's class). Telegram emits it per rendered reply (`:ok`, or
`:plain_fallback` when a chunk is resent as raw Markdown). The mobile socket
emits it only when it drops a fan-out event it cannot encode for one phone
(`FermixChannels.Mobile.Session`, `drop_event/4`): `status` is the
reason's leading atom (`event_too_large`, `null_field`, `invalid_payload`,
…, or `encode_failed`), never the event, and the session stays open, because
an outbound encode failure is the daemon's fault, not the phone's. A waiting
approval card it cannot encode when a phone says hello is dropped the same way.
The daemon log carries the event type and a bounded reason. No handler turns a
render into a trace row, and Opik does not subscribe; the benchmark runner
reads it as `channel_render`.

A channel **transport** crossing into or out of a degraded posture is another
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
iMessage is one of its emitters: `emit_transport(:imessage, :degraded |
:recovered, …)` fires on transitions of its helper (an exit loop, the Messages
database becoming unavailable, a missing grant or unconfirmed recipients at
boot, a suspected reply loop) and never per failure, and a message body the
helper could not decode is the `emit_parse(:imessage, :decode_error, …)` parse
status, not a new event name.
The phone channel's remote reach (M62) is another: `emit_transport(:mobile_iroh,
:degraded | :recovered, …)` fires when the `fermix-iroh` helper first fails
(it exited, did not answer in time, reported an `error`, spoke another
protocol or iroh version, or the bridge socket was not listening) and when it
is ready again, never per retry. `error_class` is the failure's kind
(`exited`, `timeout`, `helper_error`, `protocol_version`, `iroh_version`,
`endpoint_id`, `bridge_unavailable`, …). A build with no helper is a state,
not a transition, and emits nothing; `mobile.status` and `fermix doctor` say
it. A phone's session over the iroh carrier emits exactly the events a
WebSocket session does.

## Inbound attachments (a pre-turn point per attachment)

The gateway's attachment pipeline (`FermixChannels.Gateway.Attachments`, M67)
emits **one point event per inbound attachment**, once what reached the model is
settled, through its one emitter `FermixCore.Attachments.Telemetry.emit_ingest/3`:
`[:fermix, :attachment, :ingest]` with measurements `duration_us` (download,
classification and rendering, ffmpeg included), `bytes` (its size),
`rendered_bytes` (what rides the turn inline: the picture, the frames or the
still, the PDF or the text) and `parts` (content parts it adds: one per frame),
and metadata `channel`, `kind`
(`still | animation | video | audio | document | text | unknown`), `mime`,
`outcome` (`image | frames | poster | document | text | transcript | unusable`:
`frames` when an installed ffmpeg read a GIF's or a video's frames, `poster`
when the one still the sender made or a GIF's first frame went instead),
`reason` (the unusable reason's leading atom, such as `too_large`,
`needs_ffmpeg` (no ffmpeg here), `render_failed` (ffmpeg ran and failed) or
`download_failed`, else nil), `detail` (the whole reason, inspected and bounded
to 200 characters, so an HTTP status or ffmpeg's exit and last words reach the
trace and not only the log; a `render_failed` detail is `{:ffmpeg_exit, code,
words}`, `{:timeout, ms}`, `{:output_overflow, bytes}` or `:no_frames`; else
nil), `sound` (a video's sound, transcribed beside its pictures: `transcript`,
`no_speech`, `no_sound` (ffmpeg found no sound track, so no transcription ran)
or `failed`; nil for anything else, an animation included) and `sound_detail`
(the transcription failure, bounded the same way, else nil). A video's transcription also emits the usual
`[:fermix, :transcription, :message]`. The file name rides as `name` only under
`capture_content?`; bytes and transcripts never ride. It runs before any turn,
like ingress transcription, so it has no session: `Trace.TelemetryHandler`
records it as an `attachment_ingest` `agent_event` row keyed on `kind`, and
Opik does **not** subscribe. A message whose attachments are all unreadable is
answered at the gateway and counted as `[:fermix, :dispatcher, :ingress_failed]`
with `reason: :attachments_unusable`. Never hand-roll the event.

An operator turn that keeps its attachments in the workspace
(`FermixCore.Attachments.Workspace`, `media/inbound/<date>/`) emits **one point
event per turn** through `FermixCore.Attachments.Telemetry.emit_save/4`:
`[:fermix, :attachment, :save]` with measurements `duration_us` (the prune and
the writes), `saved` and `failed` (attachments), `files` and `bytes` (written,
the stills and frames beside each attachment included), `pruned_files` and
`pruned_bytes` (what the 14-day, 1 GiB prune deleted first), and metadata
`channel`, `session_id` (the turn's), `outcome` (`saved`, or `failed` when any
attachment was not saved) and `detail` (the first failure's sentence, bounded
to 200 characters, else nil; a sentence names folders, never a sender's file
name). A guest's turn and a Live hand-off save nothing and emit nothing.
`Trace.TelemetryHandler` records it as an `attachment_save` `agent_event` row
keyed on `channel`, and the Opik exporter places it under the turn's trace as an
`attachment_save` span (`FermixOpik.Mapper.attachment_save_span/3`: the counts,
`channel` and `outcome`, flagged errored with `detail` when the outcome is
`failed`). A failed save never fails the turn: the manifest names it as well.

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
## Management socket runs (Doctor sessions and management jobs)

The management wire has two **run kinds** and no others. A Doctor session mints
`session_id = "doctor:<rand>"`; a management job mints `"job:<rand>"`. Both go
through `FermixCore.Management.Telemetry` — never hand-rolled. Bookends are
`[:fermix, :doctor, :session_start | :session_complete | :session_error]` and
`[:fermix, :management_job, :start | :complete]`, with `agent: "doctor"` /
`agent: "management_job"` and the whole-run `budget_ms` (the exporter's sweep
floor for the root). A Doctor session also carries `scope` and the
`parent_session` that asked for it; a job carries its `kind`. Terminal metadata
is the run's own diagnosis word (`completed | cancelled | timed_out`, plus
`failed` for a job), never a bare "ok".

What rides and what does not: check **counts** per status ride the Doctor
bookend, a check `summary` and its `evidence` never do (both can carry operator
paths). A job's `failure_code` and its refusal `sentence` do ride, deliberately
— they are the daemon's own bounded copy and they are the whole diagnosis — but
no operation `result` ever does.

A provider call made inside a job carries the **job's** id as its `session_id`
through `Providers.Telemetry.emit_call/3`, so a metered probe nests under the run
that issued it rather than floating as a root. `Trace.TelemetryHandler` registers
all five events and `FermixOpik` binds them (`infer_kind("job:" <> _)`, root open
and close in `Aggregation`, replay in `TraceFile`).

Everything else on this socket is **deliberately sessionless**: `hello`,
`overview.get`, `settings.*`, `secret.*`, `plugins.*`'s request verbs, `logs.query`,
`lifecycle.*` and `diagnostics.build` are single bounded request/response calls
with no run identity, no cancellation and no budget of their own, so they mint no
`session_id` and emit nothing. Adding an event for one of them would create a
root span per settings read with nothing nested under it. If a new management
method has to *wait* on a network, a download or a person, it is a job — start
one and inherit the bookends rather than minting a sixth event.

## Computer-use sessions

A computer-use session is a **run kind**: `ComputerUse.Session` mints
`session_id = "cua_<rand>"` for the one session per conversation, and every
lifecycle emission goes through `FermixCore.ComputerUse.Telemetry` — never
hand-rolled. The five verbs are `[:fermix, :computer_use, :session_start |
:session_complete | :session_error | :session_pause | :session_resume]`. Shared
metadata: `agent` (the turn's own agent name), `session_id`, `mode`, and the
optional `parent_session` and `origin`. Pause and resume are lifecycle rather
than actions — the operator took the seat back, or gave it up again — and a trace
showing only start and complete cannot say why nothing was dispatched in between.

**Which bookend closes the run is the diagnosis.** `session_complete` (measuring
`actions` and `duration_ms`) is only for a session that ended on its own terms: a
clean stop, or a sidecar exit with status 75. Every **fault** stop — a sidecar
timeout and the poison reset it triggers, any other sidecar exit status, a failed
probe, a lost check — closes with `session_error` and a bounded `reason`
(previewed at the emitter, never a raw term). A session that died is therefore
never reported as one that finished.

The run is **always a root, and `parent_session` rides as correlation metadata,
never as a parent**. The session is keyed by conversation and reused across
turns, so it outlives the turn that opened it (the meeting/harness/voice-call
reason): nesting it would let a mid-turn `session_error` — a sidecar exit, a
poison reset — close and ship the *turn's* trace and tombstone everything the
turn did afterwards, and a session ending after its turn would mint a phantom
second root. `Trace.TelemetryHandler` registers all five as `agent_event` rows;
`FermixOpik` binds them (`infer_kind("cua_" <> _)` → `:computer_use`, the root
opening on `session_start` and closing through `close_root` on complete and
error, pause and resume as phase spans via `Mapper.computer_use_span/3`, replay
in `TraceFile`). The id prefix is minted outside `fermix_opik`; keep it in
lockstep with the exporter's clause, or a `session_complete` arriving without its
opener reads as a `:subagent` phantom root.

**In Opik one session is normally more than one root, by design.** Between its
opener and its bookend the run receives nothing — the actions ride the turn — and
a session lives as long as the conversation wants it, so almost every real
session sits idle past the exporter's idle TTL and its root ships then, with no
counts and no status. A pause or resume arriving while that shipped root's
tombstone stands is dropped from Opik (it is still in the JSONL stream). The
closing bookend then opens a **continuation root** under the same `cua_…` id,
and that continuation root is where `actions`, `duration_ms`, the status and any
`error_info` live. This is not the meeting/voice-call situation: those runs pass
a `max_duration_ms` sweep floor because they have a cap, and a computer-use
session has none, so there is no honest number to pass and none is invented.
**The JSONL stream is the complete record** — every verb, in order, under one
`session_id`; read it, not Opik, when a session's whole life is the question.

**The actions themselves stay under the turn.** One `computer_use` call is one
ordinary `[:fermix, :tool, :exec]` under the *turn's* session, which is where the
eval harness and every trace reader look for a turn's tool calls, so correlation
runs the other way: each exec carries `cu_session` (the `cua_…` id) and
`outcome` — one of `refused | performed | performed_unverified | unknown | read`
— in its always-on metadata. An opaque id and a closed enum, with no page or
screen text in either, so both ride outside the content gate. A metadata key no
exporter names is silently dropped, so the pair is listed in both allowlists a
tool key must pass: `Mapper.tool_span/3`'s `Map.take` and
`TraceFile.normalize("tool_exec", …)`. The JSONL handler needs nothing — it
writes a tool exec's metadata whole.

Their **types differ by seam**, and both are pinned by tests. `cu_session` is
always a string. `outcome` is an **atom** on the live path (the emitter's enum,
carried through `Map.take` untouched and rendered by Jason as the bare word) and
a **string** after replay, because the JSONL row it is read back from is JSON.
Everything downstream treats the two alike; a consumer that compares `outcome`
must accept both spellings rather than assume the live one.

### What a `computer_use` exec row may carry

The whole of it, derived from `Tools.ComputerUse`'s `@receipt_facts` and the two
putters beside it. Every field below is a closed word, a boolean, a bounded
count or an opaque id, and every one of them is named in **both** allowlists
(`Mapper.tool_span/3` and `TraceFile.normalize("tool_exec", …)`) — a key that is
in neither is written to the JSONL stream and then dropped by replay and by
Opik, which is a field nobody can count. A field is **absent** rather than
defaulted whenever its fact was not established.

| Field | Values | Present when | Means |
|---|---|---|---|
| `action` | the model's action name | every call | which verb was asked for |
| `cu_session` | `cua_…` string | the session was registry-registered | which session drove it |
| `outcome` | `refused \| performed \| performed_unverified \| unknown \| read` | every call | what happened to the INPUT |
| `courtesy` | `off \| na \| unavailable \| proceeded \| deferred \| yielded \| paused` | every call | what the coexistence arbiter did about a person at the machine: nothing to do, not applicable, no idle signal, went ahead, waited for them, stepped aside, or the seat was already handed back |
| `observation_age_ms` | non-negative integer | the action named an image | how stale that image was when it was sent |
| `geometry_refusal` | `observation_required \| addressing_conflict \| unknown_observation \| expired_observation \| stale_observation \| point_outside_observation \| capture_geometry_mismatch` | an addressing or geometry gate refused | which one, countable without parsing a sentence |
| `input_method` | `ax \| foreground_hid` | the helper reported a receipt | by which mechanism the input went out |
| `effect` | `verified \| not_observed \| unknown` | the helper observed the result | what it observed, never inferred |
| `check_kind` | `image \| semantic \| none` | the action came back with a check | which evidence it carried |
| `check_changed` | boolean | an image check could compare two hashes | whether that view differs from the one acted on |
| `cu_input_ms` / `cu_settle_ms` / `cu_capture_ms` / `cu_encode_ms` | non-negative integers, dropped above the outer call deadline | the helper timed that phase | what each phase of the action cost |
| `target_kind` | `window \| desktop` | a target is bound, which needs `[fermix_core.computer_use] background` on; absent on every row otherwise | what the action was pointed at |
| `cu_mode` | `background \| foreground` | the action produced a result rather than a refusal; reads `foreground` until a window is bound, so `background` is the value that needs the flag | how the input reached the screen: inside a bound window through accessibility, or in front of the person |

`control_origin` is the one addition to the **lifecycle** rows: on
`session_pause` and `session_resume` it is `:command` when a chat `/pause` or
`/resume` did it and `:indicator` when the person pressed the button on the
helper's own on-screen panel. It is beside `origin`, never instead of it —
`origin` is the session's attended origin (`:interactive`, `:voice`) on every row
of the family, and overwriting it would make the row lie about where the session
came from.

**Nothing read off the screen is ever in any of these.** No window title, no
application name, no control label, no typed text, no value a `set_value`
carried, no image data — whatever the content-capture posture. Those are content:
they ride the model's side of the wire and the capture gate, never always-on
metadata.

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
