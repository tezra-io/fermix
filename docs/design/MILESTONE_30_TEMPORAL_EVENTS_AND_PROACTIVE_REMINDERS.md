# Milestone 30 — Temporal Events & Proactive Reminders

**Status:** implemented (2026-08-02, uncommitted — see §21 for the implementation log and deviations). Rev 2 simplified claim/recovery to single-scheduler monitors + boot sweep (no leases or fenced settlement), stated the Stage-4 adapter scope honestly, and corrected framing against a code-verified review of the shipped jobs/harness/delivery implementations. Snooze (§8.4) was briefly deferred during rev 2 and reinstated the same day by owner decision — a scope call, never a technical blocker — landing as an additive migration.
**Date:** 2026-08-02
**Author:** Sujeeth
**Depends on:** shipped `Memory.Repo` durable storage, the shipped scheduled-agent implementation described by M4.11, M7 advanced tools (shipped), M3 channel coverage (shipped), `FermixCore.Delivery.ChannelSend` (shipped), `docs/TELEMETRY_CONTRACT.md`
**Related docs:** `docs/design/MILESTONE_4_ADVANCED_MEMORY.md`, `docs/design/MILESTONE_4_11_SCHEDULED_AGENTS.md`, `docs/design/SCHEDULED_JOB_SLEEP_RESILIENCE.md`, `docs/design/CODING_HARNESS_ORCHESTRATION.md`, `docs/design/SUBPROCESS_LIFECYCLE_AND_CRON_DELEGATION.md`, `docs/design/MILESTONE_24_WELLNESS_DATA_PLATFORM.md`, `docs/design/MESSAGE_GATEWAY_ARCHITECTURE.md`

---

## 1. Summary

Fermix can remember that a birthday is September 14, and it can create a
scheduled agent job that runs on September 14. It does not have a first-class
representation for the thing between those two primitives: a durable personal
event with a finite reminder plan that proactively reaches the owner as the date
approaches.

This milestone adds that missing temporal rail:

1. The main agent recognizes high-confidence personal events during the current
   turn and stores them through explicit event tools.
2. The event and its concrete reminder occurrences are persisted in
   `~/.fermix/memory.db`.
3. A supervised reminder scheduler arms a nearest-due OTP timer for the next
   occurrence, with a safe long-delay cap and bounded reconciliation scan.
4. Due reminders render deterministically and are delivered through Fermix's
   configured default channel using `FermixCore.Delivery.ChannelSend`.
5. A failed channel send is retried durably on that same target. Fermix never
   fails over to another channel.
6. Annual events such as birthdays remain one stable event row. Concrete
   reminder rows are materialized for bounded future occurrences and rolled
   forward with local-calendar arithmetic.

There is no new calendar UI, no macOS notification integration, no hourly LLM
heartbeat, and no provider call when a reminder fires. Chat remains the product
interface.

This milestone **partially supersedes M4.11**: deterministic reminders move to
the temporal-event rail. M4.11 remains authoritative for future work that must
wake an agent, call a provider, use tools, inspect changing state, or write job
memory.

---

## 2. Current State and the Gap

### 2.1 Memory is durable but temporally inert

`memory_store` persists a key/value fact. Curated memory adds categories,
confidence, scope, and prompt promotion, but it does not carry:

- an occurrence date in the owner's timezone;
- annual recurrence semantics;
- more than one planned reminder;
- a next-due index;
- delivery state or retry state;
- sent, failed, or superseded history.

The memory reviewer is also intentionally allowed to archive a passed date as
stale. That is correct for bounded prompt memory and wrong for a recurring
birthday. Temporal events therefore must not be encoded as special memory keys
or appended to `USER.md` / `MEMORY.md`.

### 2.2 Scheduled jobs are active work, not passive reminders

The current runtime prompt routes reminders to `schedule_job`. Every scheduled
job occurrence then creates a `job_run`, builds an isolated prompt, calls a model,
may invoke tools, writes run output, and delivers the final response. That is the
right lifecycle for:

- "Check flight prices next Friday and summarize them."
- "Watch this repository every hour."
- "Prepare a daily inbox digest."

It is unnecessary machinery for:

- "Sarah's birthday is September 14."
- "My dentist appointment is August 16 at 3 PM."
- "Remind me to submit this on Friday."

A plain reminder needs no `AgentLoop`, provider route, token budget, job memory
source, or run artifact.

### 2.3 Fermix already has the required infrastructure patterns

The new rail does not need a new platform:

- `Memory.Repo` is the canonical SQLite single writer; compound multi-table
  operations are public Repo functions with private `BEGIN IMMEDIATE`
  transactions (the `create_job_with_source`/`claim_due_job` pattern).
- `Jobs.Scheduler` demonstrates nearest-due OTP timers, job-change re-arming,
  atomic `BEGIN IMMEDIATE` claims, bounded concurrency, and periodic
  reconciliation. It has no lease/fencing machinery and no clock seam; the
  hermetic `now_fn` seam comes from the harness workers, and the 24-hour timer
  clamp in §10.3 is bounded-timer hygiene the jobs scheduler adopted in the
  companion fix, not a mirrored behavior (jobs previously armed an unbounded
  single timer — months long for a far-out schedule).
- `Delivery.ChannelSend` is the single platform/destination-to-channel-adapter
  primitive (`send/5`, `with_timeout/2`, `resolve_adapter/2`,
  `delivery_max_attempts: 1` exactly as the harness already uses it).
- `Harness.DeliveryWorker` demonstrates durable pending delivery,
  one-send-per-attempt, persisted backoff, and terminal dead-letter state —
  as a single permanent worker whose safety rests on being the only writer; it
  has no leases either. M30 keeps that single-writer safety model.
- The gateway channels already provide the owner-facing interface.

M30 composes these patterns without routing reminders through either memory
review or the scheduled-agent runner.

### 2.4 Primitive boundary

| Owner statement | Canonical primitive | Model call when due? |
|---|---|---:|
| "Sarah likes hiking." | Memory | No due time |
| "Sarah's birthday is September 14." | Temporal event | No |
| "Remind me about the appointment tomorrow." | Temporal event | No |
| "Check ticket prices tomorrow and tell me the cheapest option." | Scheduled job | Yes |
| "Every morning, review my inbox and summarize it." | Scheduled job | Yes |

---

## 3. Decisions Locked

| Question | Decision |
|---|---|
| Primary user interface | Existing Fermix conversations: Telegram, WhatsApp, Slack, Discord, Signal, CLI, daemon, voice, or another trusted main-agent surface. No calendar UI |
| Notification medium | The one configured default Fermix channel target. No origin delivery, macOS notification, email side rail, or channel fallback |
| Existing config source | Reuse `[fermix_core.jobs].default_delivery_target`; broaden its documented meaning from cron-specific target to default daemon background-delivery target. Do not add a second reminder target. Owner decision 2026-08-03: when the key is absent, derive the owner's inbox at acceptance from the first owner-configured channel (`FermixCore.Delivery.OwnerInbox`, telegram → signal → whatsapp, explicit `owner_user_id` only) so a fresh install or `brew upgrade` works with zero new config; refuse loudly only when neither exists |
| Target lifetime | Resolve and snapshot platform/destination/persistent thread scope when the event is accepted. Later edits to `default_delivery_target` do not retarget it; live adapter mappings and credentials are intentionally not copied into SQLite |
| Timezone source | Use the existing `[fermix_core.personalization].timezone` unless the owner explicitly supplies another IANA zone for the event. Missing or invalid timezone fails creation; never assume UTC for a personal date |
| Storage | Dedicated `temporal_events` and `reminder_occurrences` tables in `memory.db`; neither memory rows nor scheduled-job rows |
| Capture trigger | The current main-agent turn calls an event tool. No second extractor, memory scan, or heartbeat |
| Scheduling mechanism | Event-driven create/update plus one bounded nearest-due OTP timer (24-hour clamp) and a 60-second reconciliation safety net. No OS cron entry per reminder |
| Claim recovery | Single-scheduler serialization, `Process.monitor` per delivery worker, and a boot-time sweep of stranded `delivering` rows. Supervision order guarantees no worker outlives the scheduler. No lease tokens or fenced settlement in v1 (§19.10) |
| Snooze | Ships (owner decision 2026-08-02, reversing an initial deferral — there was never a technical blocker). One bounded ad-hoc reminder linked to its source; no repeat-until-ack loop. Landed as an additive migration on the v1 schema (§8.4) |
| Notification execution | Deterministic renderer plus channel send. No LLM/provider/tool loop |
| Reminder frequency | A finite plan. Multiple planned reminders may lead up to an event, but there is no repeat-until-acknowledged nag loop |
| Transport retry | Retry a failed planned reminder on the same snapshotted target with a persisted, bounded schedule. A retry is not another planned nudge |
| Delivery guarantee | Durable at-least-once best effort while the daemon is available. Exactly once cannot be promised across a send-success/SQLite-crash boundary |
| Annual recurrence | One stable event row; bounded concrete reminder rows per annual occurrence; local-calendar rollover, never `+365 days` |
| Host sleep/offline | Out of scope. No OS wake scheduling, sleep inhibition, or guarantee while Fermix is stopped/suspended |
| External calendars | No Google Calendar sync/import/export in M30. Calendar plugins remain separate agent capabilities |
| Supported recurrence in v1 | One-time and yearly only. Arbitrary RRULE, monthly, weekly, and cron-like recurrence are deferred |
| Trust | Attended, top-level, non-synthesized operator turns only, gated at tool advertisement and execution — with one read carve-out (owner decision 2026-08-03): `event_list` is also readable from an operator-created scheduled run, so a cron brief can include stored events. Guest, background, delegated, and coding-continuation runs can touch nothing; scheduled runs cannot create, update, snooze, or remove |

---

## 4. Goals and Non-Goals

### 4.1 Goals

- Capture explicit reminders and high-confidence personal dates in the same turn
  in which the owner states them.
- Proactively send a small number of useful reminders as an event approaches.
- Preserve one canonical identity for a recurring birthday or anniversary.
- Make occurrence materialization and scheduler reconciliation idempotent.
- Keep delivery durable across a temporary channel or network failure while the
  daemon remains available.
- Make every failure inspectable without changing channels or silently dropping
  the parent event.
- Let the owner list, search, edit, remove, rebind, and snooze events through
  normal conversation.
- Keep notification-time cost at zero provider calls.

### 4.2 Non-goals

- A month/week/day calendar UI or a new web product surface.
- A local macOS Notification Center adapter.
- OS wake timers, sleep prevention, or a guarantee when the host/daemon is down.
- A periodic LLM heartbeat that scans files or memory for approaching dates.
- Mining all historical memories for possible events during migration.
- A general calendar server, attendee invitations, availability search, meeting
  rooms, ICS, CalDAV, or bidirectional Google Calendar synchronization.
- Arbitrary recurrence rules or a cron parser for events.
- Running tools, searching the web, or asking an LLM to enrich a reminder at
  delivery time.
- Automatic channel failover. Personal event data is sent only to the configured
  target accepted when the event was stored.

---

## 5. Owner and Chat Contract

### 5.1 Capture classes

The current model already reads the owner's message. M30 gives it one explicit
decision boundary:

| Message class | Behavior |
|---|---|
| Explicit reminder with an exact time | Store one reminder at that time unless the owner requested a larger plan |
| High-confidence personal event with a concrete date | Store the event with the applicable default plan and acknowledge it |
| Annual personal date without a year (birthday/anniversary) | Store a yearly event |
| Relative date such as "in two weeks" | Resolve inside the event tool against the configured timezone and the tool's current clock |
| Missing detail that changes delivery (for example an appointment with no time) | Ask one focused clarification before writing |
| Tentative, hypothetical, historical, quoted, or third-party informational date | Do not create an event |
| Future request that must reason or act when due | Use `schedule_job`, not the event tools |

The model must not create an event from tool output, fetched web content, or a
date merely mentioned while answering a question. The capture basis is the
owner's current statement.

### 5.2 Visible acknowledgement

An event write is never silent. The tool result gives the model the canonical
event, next occurrence, planned reminder times, recurrence, and delivery
platform. The reply must summarize those exact stored values:

```text
Remembered: Sarah's birthday — every September 14.
I'll remind you on September 7 and September 14 through Telegram.
```

For an explicit one-shot reminder:

```text
Scheduled: submit the report — Friday, August 14 at 9:00 AM ET.
I'll send one reminder through Telegram.
```

The acknowledgement must not promise delivery when event creation failed or
when the default target was missing/invalid.

If an idempotent create resolves to an identical active event, the reply says it
was already remembered and repeats the existing plan; it never implies that a
second event or second set of reminders was created.

### 5.3 Conversational management

No slash command, CLI verb, or UI is required in v1. The owner asks Fermix:

- "What do I have coming up this month?"
- "When is Sarah's birthday?"
- "Change the dentist appointment to 4 PM."
- "Only remind me on the morning of the birthday."
- "Move this reminder to my current default channel."
- "Snooze that for two hours."
- "Remove that event."

The main agent performs those actions through deterministic tools and confirms
the resulting stored state.

### 5.4 No repeated nag loop

Planned reminders are finite. A successful reminder occurrence is delivered
once and never re-sent merely because the owner did not acknowledge it.

Transport retries are different: they happen only after a failed send attempt
and stop immediately after success, expiration, a permanent failure, or the
attempt cap. The user should never receive five messages merely because a
reminder had five logical delivery attempts; once adapter success is durably
committed, the occurrence is terminally delivered. The only exception is the
documented ambiguous-send window before that commit.

---

## 6. Architecture and Ownership

### 6.1 Flow

```text
owner message
  -> MainAgent / AgentLoop
  -> event_store tool
  -> Temporal.Registry validates event + default target
  -> Memory.Repo.create_temporal_event compound transaction
       -> persist event
       -> persist Temporal.Planner's reminder occurrences
  -> Temporal.Scheduler.event_changed()
       -> arm timer for earliest ready_at

due timer / reconciliation
  -> claim due reminder occurrence atomically
  -> Temporal.Renderer builds deterministic text
  -> Temporal.Delivery calls Delivery.ChannelSend once
       -> delivered
       -> pending with next retry time
       -> failed / expired / superseded
  -> re-arm timer
```

### 6.2 Proposed modules

```text
apps/fermix_core/lib/fermix_core/temporal/
├── defaults.ex              # finite default reminder plans; pure data
├── planner.ex               # pure date/calendar materialization
├── registry.ex              # validation/orchestration over compound Repo calls
├── renderer.ex              # deterministic notification text
├── delivery.ex              # one logical channel attempt + classification
├── delivery_worker.ex       # :temporary monitored worker; one claimed occurrence
├── scheduler.ex             # nearest timer, claim, monitors, boot sweep, reconciliation
├── delivery_supervisor.ex   # DynamicSupervisor, bounded non-blocking sends
└── telemetry.ex             # one owner of temporal event shapes

apps/fermix_core/lib/fermix_core/tools/
├── event_store.ex
├── event_list.ex
├── event_update.ex
├── event_remove.ex
└── reminder_snooze.ex

apps/fermix_core/lib/fermix_core/delivery/
└── error.ex                 # shared closed channel-delivery error vocabulary
```

Names may change only if repo conventions require it at implementation; the
responsibility split is fixed.

### 6.3 Supervision

`Memory.Repo` remains the single database owner. After it starts (and after the
jobs children, before `HarnessSupervisor`), the flat `:rest_for_one` application
list gains, in this order:

1. `Temporal.Scheduler`
2. `Temporal.DeliverySupervisor`

The ordering is load-bearing: under `:rest_for_one`, a `Temporal.Scheduler`
crash makes the supervisor terminate every later child — including
`Temporal.DeliverySupervisor` and its workers — before restarting the scheduler.
**No delivery worker can outlive the scheduler.** That single invariant replaces
rev 1's lease/fencing machinery:

- The scheduler `Process.monitor`s every worker it starts. A `:DOWN` without a
  settled row returns the row to `pending` (the claimed attempt stays consumed)
  or marks it `failed` at the attempt cap; a `:DOWN` after settlement changes
  nothing (the handler re-reads the row first).
- Scheduler `init/1` runs a **boot sweep**: every row still `delivering` is
  stranded (no worker survived the restart, by the ordering above) and is reset
  to `pending`, or terminalized (`failed` at the attempt cap,
  `expired`/`superseded` past its validity). The sweep is bounded and runs
  before timers arm.
- Claims are serialized in the one scheduler process, so two workers for the
  same row cannot exist within a scheduler lifetime, and cannot exist across
  lifetimes because workers die with the scheduler.

The only cost versus leases: a scheduler-only crash kills in-flight sends, and a
send the remote had already accepted is then retried — a duplicate inside the
at-least-once window §11.5 already documents. The scheduler never performs
network I/O, so scheduler-only crashes should be rare; the dominant restart
cause (daemon death) behaves identically under both designs.

Because the scheduler starts first, its init may arm a 0ms timer that fires
before `Temporal.DeliverySupervisor` has registered (a sub-millisecond boot
window). The capacity precheck treats an unregistered delivery supervisor as
zero free slots and re-arms at the 5-second error floor — the existing
backpressure path, logged, not a second mechanism.

Every delivery worker has `restart: :temporary`. A worker may run only after a
fresh durable claim; normal completion or a crash must never cause the
supervisor to restart the same send outside that claim path. Worker `init/1`
performs no channel I/O; it defers the attempt until after
`DynamicSupervisor.start_child/2` returns successfully (the scheduler monitors
the returned pid in the same callback that claimed the row).
`Temporal.DeliverySupervisor` itself sets `max_children: 4`; the scheduler's
capacity precheck is an optimization and the supervisor cap is the final OTP
authority.

`Temporal.Scheduler` and its delivery workers accept the same hermetic clock
seam as the **harness workers** (`Jobs.Scheduler` has no clock seam): an
injected zero-arity `now_fn` (default `DateTime.utc_now/0`); the scheduler also
accepts `timer_enabled` (true by default). Test config disables automatic timers
and tests drive ticks/settlement with fake time; production has one code path
with real time.

The scheduler must never block on network I/O. It atomically claims due rows and
starts bounded delivery workers. Initial limits mirror the proven scheduled-job
shape:

- at most 20 due rows read per tick;
- at most 4 active delivery workers;
- one `ChannelSend` invocation per worker;
- one timer for the earliest `ready_at`, with a 24-hour maximum delay before a
  harmless due-time recheck;
- one 60-second reconciliation timer;
- a 5-second minimum error/backpressure re-arm so a stuck row cannot hot-loop.

Each reconciliation pass handles at most 20 validity-boundary rows (marking
`expired`/`superseded` and completing passed one-time events) and 20
annual-horizon events, ordered by `(deadline, id)` with keyset cursors retained
in scheduler state. It also asserts the monitor invariant: a `delivering` row
with no monitored worker is impossible mid-lifetime (boot sweep covers restarts,
`:DOWN` covers crashes) — if one is ever observed, it is reset like the boot
sweep and traced loudly as `scheduler_error`, because it means the invariant
broke, not because a second recovery path is wanted. All loops, scans, and
annual materialization are explicitly bounded; a later reconciliation continues
the next page. A short page wraps its cursor to the beginning, and
`event_changed/0` invalidates the annual cursor so a newly earlier deadline is
not starved behind it.

### 6.4 No new agent run kind

A reminder delivery does not call `AgentLoop.run/1`; it is not a sub-agent,
scheduled job, or background reasoning run. It creates no provider call,
`job_run`, prompt snapshot, job memory source, or token-usage record.

The event tools execute inside the originating main turn and inherit its normal
tool telemetry correlation. Detached delivery lifecycle events are correlated by
`event_id`, `reminder_id`, and `occurrence_key`, not by inventing a fake agent
session.

---

## 7. Persistence Model (`memory.db`)

The next available `Memory.Repo` migration adds two tables. The SQL below is the
logical contract; implementation may adapt constraint syntax to the repo's
SQLite migration helpers without changing the fields or states.

`Memory.Repo` also owns the public compound operations that need atomicity:
create, update/rebind, cancel, materialize, claim, settle, and the boot sweep.
`Temporal.Registry` validates and prepares pure planner output before calling
one of those Repo operations; it never opens a connection or transaction itself.
This is the shipped repo pattern (there is no exported transaction primitive;
`create_job_with_source`/`claim_due_job` are the precedents). Because `repo.ex`
is already ~5,000 lines, the temporal SQL may live in a private
`Memory.Repo.TemporalSql` helper whose functions take the `conn` and are called
only from Repo's `handle_call`s — same single-writer architecture, bounded file
growth.

### 7.1 `temporal_events`: stable semantic identity

```sql
CREATE TABLE temporal_events (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL DEFAULT 'main',
  owner_id TEXT NOT NULL DEFAULT 'default',
  dedupe_key TEXT NOT NULL,

  title TEXT NOT NULL,
  description TEXT,
  kind TEXT NOT NULL CHECK (
    kind IN ('birthday', 'anniversary', 'appointment', 'deadline',
             'event', 'follow_up', 'explicit_reminder')
  ),

  time_kind TEXT NOT NULL CHECK (time_kind IN ('date', 'datetime')),
  local_date TEXT,                       -- YYYY-MM-DD; required only for one-time events
  local_time TEXT,                       -- HH:MM:SS; NULL for all-day/date-only
  timezone TEXT NOT NULL,                -- validated IANA zone
  occurrence_at TEXT,                    -- resolved UTC instant for one-time datetime

  recurrence_kind TEXT NOT NULL CHECK (recurrence_kind IN ('once', 'yearly')),
  recurrence_month INTEGER,
  recurrence_day INTEGER,
  leap_day_policy TEXT CHECK (
    leap_day_policy IS NULL OR leap_day_policy IN ('feb_28', 'mar_1')
  ),
  reminder_plan_json TEXT NOT NULL,
  next_occurrence_on TEXT,
  materialized_through_on TEXT,

  delivery_platform TEXT NOT NULL,
  delivery_destination TEXT NOT NULL,
  delivery_thread_scope TEXT NOT NULL DEFAULT 'root',

  revision INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'active' CHECK (
    status IN ('active', 'completed', 'cancelled')
  ),

  source_channel TEXT NOT NULL,
  source_chat_id TEXT NOT NULL,
  source_thread_scope TEXT NOT NULL DEFAULT 'root',
  source_session_id TEXT,
  created_by_trust TEXT NOT NULL CHECK (created_by_trust = 'operator'),
  created_by_origin TEXT NOT NULL CHECK (
    created_by_origin IN ('interactive', 'voice')
  ),

  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_temporal_events_owner_status_next
  ON temporal_events(owner_id, status, next_occurrence_on);
CREATE UNIQUE INDEX idx_temporal_events_active_dedupe
  ON temporal_events(owner_id, dedupe_key)
  WHERE status = 'active';
CREATE INDEX idx_temporal_events_kind
  ON temporal_events(owner_id, kind);
CREATE INDEX idx_temporal_events_annual_horizon
  ON temporal_events(
    status, recurrence_kind, materialized_through_on, id
  );
```

Rules:

- A one-time date-only event requires `local_date`, `local_time = NULL`, and
  `occurrence_at = NULL`.
- A one-time datetime requires local date/time plus the uniquely resolved UTC
  `occurrence_at`, and no recurrence month/day.
- `recurrence_kind = 'yearly'` requires month/day, requires `local_date` to be
  `NULL`, `local_time = NULL`, and `occurrence_at = NULL`, and is date-only in
  v1. `next_occurrence_on` is the only cached yearly occurrence date; the
  canonical identity remains month/day.
- An annual February 29 event requires an explicit `leap_day_policy`; the agent
  asks rather than silently choosing February 28 or March 1.
- `reminder_plan_json` is a bounded array of validated rules with stable rule
  IDs. It is not arbitrary prompt text.
- `dedupe_key` is tool-derived, never model-authored: yearly events hash
  normalized kind/title identity, while one-time events also include their
  resolved occurrence. Repeating an identical active create returns the existing
  event and plan; an identity collision with different date/plan fails and
  directs the agent to `event_update`. Cancelled/completed rows do not block a
  genuinely new active event.
- UTF-8 storage caps are explicit: title `1..240` bytes, description `0..2,000`
  bytes, each plan/payload JSON document at most 16 KiB, and persisted
  `last_error` at most 500 bytes. Truncation is never used to make invalid tool
  input pass; the tool asks for a shorter value.
- The event snapshots the configured default target at acceptance. No
  per-event alternate target and no delivery fallback exist.
- Cancellation is soft. Sent reminder history remains queryable.

### 7.2 `reminder_occurrences`: concrete plan plus durable outbox

```sql
CREATE TABLE reminder_occurrences (
  id TEXT PRIMARY KEY,
  event_id TEXT NOT NULL REFERENCES temporal_events(id) ON DELETE RESTRICT,
  event_revision INTEGER NOT NULL,
  occurrence_key TEXT NOT NULL,           -- local date, e.g. 2027-09-14
  reminder_rule_id TEXT NOT NULL,         -- e.g. week_before, day_of, snooze:<src>:<t>
  source_reminder_id TEXT REFERENCES reminder_occurrences(id) ON DELETE RESTRICT,

  event_occurrence_at TEXT NOT NULL,      -- resolved UTC boundary
  scheduled_for TEXT NOT NULL,            -- original UTC notification time
  ready_at TEXT NOT NULL,                 -- scheduled_for or next retry time
  valid_until TEXT NOT NULL,

  payload_json TEXT NOT NULL,             -- bounded title/date/rule snapshot
  delivery_platform TEXT NOT NULL,
  delivery_destination TEXT NOT NULL,
  delivery_thread_scope TEXT NOT NULL DEFAULT 'root',

  status TEXT NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'delivering', 'delivered', 'failed',
               'expired', 'superseded', 'cancelled')
  ),
  attempt_count INTEGER NOT NULL DEFAULT 0,
  sent_at TEXT,
  failed_at TEXT,
  last_error TEXT,

  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,

  UNIQUE(event_id, event_revision, occurrence_key, reminder_rule_id)
);

CREATE INDEX idx_reminder_occurrences_due
  ON reminder_occurrences(status, ready_at, id);
CREATE INDEX idx_reminder_occurrences_event
  ON reminder_occurrences(event_id, occurrence_key);
CREATE UNIQUE INDEX idx_reminder_occurrences_snooze_dedupe
  ON reminder_occurrences(source_reminder_id, scheduled_for)
  WHERE source_reminder_id IS NOT NULL;
CREATE INDEX idx_reminder_occurrences_snooze_source
  ON reminder_occurrences(source_reminder_id, status, scheduled_for);
CREATE INDEX idx_reminder_occurrences_target_sent
  ON reminder_occurrences(
    delivery_platform, delivery_destination, delivery_thread_scope,
    status, sent_at DESC, id DESC
  );
```

The snooze columns/indexes (`source_reminder_id`, its dedupe pair, the
source index, and the target-scoped latest-delivered index) landed as an
additive migration on top of the v1 tables — the v1 schema was shaped so this
required no rewrite. The boot sweep scans `status = 'delivering'`, which the
`idx_reminder_occurrences_due` status prefix already serves for a set that is
at most `max_children` rows.

The revision-qualified unique tuple is the idempotency guard for the planner.
Re-running creation, reconciliation, or annual rollover for the same event
revision cannot duplicate a planned reminder, while a real event edit can
materialize a replacement row without rewriting prior history.

No third attempts table is required in v1. `attempt_count`, bounded
`last_error`, timestamps, and telemetry provide sufficient operational history.

Every UTC timestamp used in a SQLite comparison is serialized in one fixed-width
form: `YYYY-MM-DDTHH:MM:SS.ffffffZ`. Inputs with another offset are normalized to
UTC before persistence. Variable-width ISO strings and mixed offsets are
rejected, so lexical ordering is chronological ordering.

Repo normalization also enforces `attempt_count in 0..5`, and `delivered`
requires `sent_at`. `delivering` is transient claim state owned by the single
scheduler process; the boot sweep resets any `delivering` row found at scheduler
init, so the state cannot leak across restarts. Public callers cannot persist a
half-claimed or falsely delivered row.

### 7.3 Event edits

An event update is one compound `Memory.Repo` operation and transaction:

1. fail with `:delivery_in_progress` if this event has a `delivering` row;
2. validate the merged event;
3. increment `revision`;
4. cancel pending reminder rows from older revisions;
5. leave delivered/failed history immutable;
6. materialize the new bounded future plan;
7. commit;
8. notify the scheduler to re-arm.

Remove and delivery-rebind use the same in-flight guard. A channel send cannot
be recalled once it starts, so Fermix asks the owner to retry the mutation after
the bounded send attempt finishes instead of pretending it revoked an external
side effect. The Repo-owned `BEGIN IMMEDIATE` serializes this guard with the scheduler's claim:
the mutation either cancels a still-pending row first, or observes an already
claimed row and fails visibly.

---

## 8. Reminder Plans

### 8.1 Defaults

Defaults are finite constants, not a new configuration matrix. Explicit owner
instructions replace the default plan for that event; they do not append to it
silently.

| Event shape | Default reminder rules |
|---|---|
| Birthday / anniversary | 7 days before at 9:00 AM local; day-of at 9:00 AM local |
| Timed appointment / timed event | 24 hours before; 1 hour before |
| Date-only deadline / generic event | 7 days before at 9:00 AM local; 1 day before at 9:00 AM local; day-of at 9:00 AM local |
| Follow-up | At the stored follow-up time only |
| Explicit "remind me at ..." | Exactly the requested time unless the owner explicitly asks for more |

Examples:

- "Sarah's birthday is September 14" produces two planned notifications per
  annual occurrence, not a daily countdown.
- "Remind me every day for the week before Sarah's birthday" is accepted as an
  explicit bounded custom plan.
- "Keep reminding me until I acknowledge it" is rejected in v1 with a clear
  explanation; repeat-until-ack is a separate state machine and anti-spam policy.

### 8.2 Validation and caps

- At most 10 reminder rules per event.
- Every rule needs a stable, unique `rule_id` within the event.
- A rule must resolve to a time no later than the event's validity boundary.
- Past lead-time rules are skipped at creation; Fermix does not immediately
  replay a "one week before" reminder for an event tomorrow.
- If all default rules have passed but the event is still upcoming, event
  creation succeeds and its visible acknowledgement states that no future
  reminder remains unless the owner adds one.
- An empty plan is valid only when the owner explicitly asks Fermix to store an
  event without notifications.
- Even an explicitly notification-free event snapshots a valid default target,
  so adding reminders later does not introduce an implicit routing decision.

### 8.3 Validity and supersession

Each planned reminder has `valid_until`:

- an early reminder is valid until the next planned reminder becomes due;
- the last pre-event reminder is valid until the event begins;
- an exact-time explicit reminder or follow-up scheduled at the event boundary
  is valid for two hours after `scheduled_for`, which admits the complete retry
  plan without turning it into a next-day surprise;
- a date-only day-of reminder is valid until the end of that local calendar day.

When an earlier failed/pending reminder reaches the next rule's due time, it is
marked `superseded`. Fermix sends the latest still-valid reminder only. A channel
recovery must never produce a burst of "one week before," "one day before," and
"today" messages together.

Every rendered message includes the absolute event date/time. A delayed retry
therefore remains truthful even if "in seven days" is no longer accurate.

### 8.4 Snooze

Snoozing creates one bounded ad-hoc reminder row linked to the same event. It
does not mutate the event's durable default plan or create a recurring snooze
loop. A snooze time beyond the event's validity boundary requires explicit owner
confirmation (`confirm_past_boundary: true` after the agent asks). An
in-boundary snooze is valid until the earlier of two hours after its new time or
the event boundary; a confirmed post-boundary snooze is valid for two hours
after its new time. The new time itself is a bounded tagged form — a duration
(minutes/hours/days) from now, or a DST-safe datetime under the same gap/fold
rules as `event_store` — must be strictly in the future, and sits under one
90-day horizon **regardless of form**: confirmation gates boundary-crossing,
never the horizon. Beyond that, moving the date is an event edit, not a snooze.

The compound Repo snooze operation records `source_reminder_id`. In one
`BEGIN IMMEDIATE` transaction it re-reads the source and parent, rejects a
cancelled parent, inserts the snooze, and — when the boundary has already caused
a one-time parent to complete — changes that parent from `completed` back to
`active` **and restores `next_occurrence_on` to the occurrence's date**: the
completion scan pre-filters on `next_occurrence_on`, so a reactivated parent
with a NULL cache would never be revisited and would linger active forever.
With the (past) date restored, reconciliation re-completes the parent after the
snooze becomes terminal, and the past date keeps it out of any upcoming view.
Reconciliation cannot race this into an unclaimable row: both writers serialize
through the single Repo transaction — completion-first is undone by the
reactivation, snooze-first blocks completion via the new pending row.
Reactivation is subject to the active dedupe constraint; a conflict fails the
whole transaction visibly and creates no snooze.

A delivered source remains immutable `delivered`; a still-pending source
explicitly selected by ID becomes `superseded` (implicit resolution only ever
selects delivered sources, so it never supersedes a pending row). Failed,
expired, cancelled, or currently delivering sources are rejected. The new rule
ID is deterministic from source ID and the normalized snooze time, and the
unique index on `(source_reminder_id, scheduled_for)` pins **one row per
source and instant, whatever its state**. Idempotency is status-aware: a live
twin (pending or mid-delivery) at the requested instant returns as the
existing snooze; a dead twin (cancelled by an event edit, superseded by a
re-snooze, failed, or expired) at a still-future instant is **revived in
place** — back to pending under the parent's current revision with a fresh
validity and a zeroed attempt count — and acknowledged as a new commitment,
never as "already snoozed" over a corpse. (A delivered twin is unreachable —
delivered implies the instant has passed, so the in-past guard fires first —
but the transaction still meets it with a typed refusal rather than an open
clause, so an unexpected state can never crash the single writer.)
Choosing a different time supersedes any existing pending snooze from the same
source before inserting the replacement, so there is at most one active snooze
per source; a sibling snooze that is **currently mid-delivery** cannot be
recalled, so the whole call fails with `snooze_delivery_in_progress` — the
same ask-again contract event mutations use — rather than letting one source
send twice. The snooze row copies the source's occurrence identity, payload,
and delivery target, and carries the parent's current revision — a later event
edit cancels pending snoozes exactly like any other pending row.

`reminder_snooze` accepts an explicit reminder ID, but "snooze that" may omit
it. In that case the tool normalizes the caller's conversation key to the
canonical platform/destination/thread triple, matches it against the
snapshotted target plus the authorized parent-event owner, and selects the most
recent **delivered** reminder from the preceding 24 hours using the stable
order `sent_at DESC, id DESC` (served by the target-scoped index). One
platform-defined widening exists: a Slack channel mention always mints its own
`ts` (a root-level mention has no `thread_ts`), so on Slack the caller's scope
matches `{exact thread, root}` with the exact thread preferred — root messages
are visible from every thread in the channel, and the widening is
one-directional toward root, never across threads. No match fails visibly and
makes the agent ask which event; the tool never guesses across conversations or
owners. This resolution reads the reminder outbox directly and does not depend
on conversation-history metadata. The resolver is shared: `event_remove` with
an omitted ID resolves the same way and cancels the referent's **parent
event** — "cancel that" after a delivered reminder ends the whole event, and
the result names the event and its recurrence so a yearly cancellation is
visibly yearly (§5.2).

---

## 9. Annual Recurrence and Rollover

### 9.1 Stable event, bounded concrete occurrences

A yearly birthday is never copied into a new `temporal_events` row. The event
stores:

- `recurrence_kind = 'yearly'`;
- canonical month/day;
- timezone;
- reminder plan;
- one stable event ID.

`Temporal.Planner` keeps reminder rows materialized for the next **two** annual
event occurrences. Two is a deliberate bound: it avoids depending on the final
delivery of the current year to create next year's reminders, while keeping work
and storage tiny.

Example for a September 14 birthday created on August 2, 2026:

```text
temporal_events
  evt_sarah_birthday     yearly, month=9, day=14

reminder_occurrences
  2026-09-14 / week_before
  2026-09-14 / day_of
  2027-09-14 / week_before
  2027-09-14 / day_of
```

After September 14, 2026 passes, reconciliation advances
`next_occurrence_on` to `2027-09-14` and materializes the 2028 rows. The 2026
delivery history remains. There is still exactly one event row.

### 9.2 Idempotent planner

On create, update, and bounded scheduler reconciliation:

1. compute the next two annual local dates;
2. resolve each reminder rule to UTC using the event timezone;
3. call the compound Repo materializer with the planner's expected event
   revision;
4. inside one transaction, re-read `status = 'active' AND revision =
   expected_revision`, insert each `(event_id, event_revision, occurrence_key,
   rule_id)` with conflict-ignore semantics, and update `next_occurrence_on` plus
   `materialized_through_on`;
5. return `:stale_event_revision` without writes if an edit won the race;
6. stop after two future event occurrences.

The planner never waits for a notification send result to roll the series
forward. A failed reminder this year does not disable the birthday or next year's
rows.

### 9.3 Calendar correctness

- Use local calendar construction for each target year. Never add 365 days.
- Convert local notification times to UTC only after the target local date is
  constructed.
- Validate all IANA timezones at write time.
- Annual events are date-only in v1, which avoids ambiguous/nonexistent annual
  wall-clock times across DST.
- A February 29 annual event requires `feb_28` or `mar_1` behavior for non-leap
  years. Fermix asks once and persists the answer.
- Relative `days` and `weeks` are computed by the tool from the owner's local
  date at execution time. They are never resolved from the cached prompt date
  alone.

### 9.4 One-time completion

A one-time event does not remain falsely upcoming forever. Reconciliation marks
it `completed` and clears `next_occurrence_on` after its occurrence boundary has
passed and every reminder row, including any post-boundary snooze, is terminal.
For a timed event the boundary is the stored event time; for a date-only event
it is the end of that local calendar day. A snooze created after completion
atomically reactivates the parent as defined in §8.4 (restoring the past
occurrence date so reconciliation can complete it again), but the passed event
is not shown as upcoming merely because a snooze is pending — the default
`event_list` floor (§12.1) keeps past-dated rows out of the upcoming view.
Completed events
remain available to explicit history queries but are excluded from the default
upcoming list. A yearly event never auto-completes.

---

## 10. Scheduler and State Machine

### 10.1 Reminder state machine

```text
pending
  -> delivering            atomic claim; worker started + monitored
  -> delivered             adapter returned :ok
  -> pending               retryable failure; ready_at moves forward
  -> failed                permanent failure or attempt exhaustion
  -> expired               validity boundary passed
  -> superseded            a later plan rule is now due
  -> cancelled             parent event removed/updated
```

Only `pending` rows with `ready_at <= now < valid_until` are claimable.

### 10.2 Atomic claim, monitors, and boot sweep

The due scan and claim reuse the `BEGIN IMMEDIATE` re-read shape of
`Memory.Repo.claim_due_job` (the jobs precedent has no lease machinery, and
neither does this design — see §6.3 and §19.10). The scheduler first reads
`DynamicSupervisor.count_children/1` and computes the available worker slots;
capacity is OTP state and is never checked inside a SQLite transaction. It then
asks Repo to claim no more rows than those slots:

1. fetch a bounded ordered list of due IDs;
2. in `BEGIN IMMEDIATE`, re-read one row;
3. verify `pending`, `attempt_count < 5`, due, unexpired, and matching active
   event revision;
4. set `delivering` and increment `attempt_count`;
5. commit before starting external I/O.

In the same scheduler callback, the worker is started via
`DynamicSupervisor.start_child/2` and immediately monitored. Exactly one process
can hold a claim: claims are serialized in the single scheduler process, and no
worker survives the scheduler (§6.3), so there is no reclaim race for a token to
fence against.

Settlement is a plain Repo write by the worker (delivered / pending-with-next
`ready_at` / failed), guarded by `status = 'delivering'` as a loud sanity
assert, after which the worker exits `:normal`. The scheduler's `:DOWN` handler
re-reads the row: settled rows are left alone; a still-`delivering` row from an
abnormal exit returns to `pending` at the 5-second error floor (the claimed
attempt stays consumed) or becomes `failed` on a fifth-attempt crash — never
attempt six. If `DynamicSupervisor.start_child/2` itself fails after claim, the
scheduler settles the row the same way. Either path traces the consumed logical
attempt.

Scheduler `init/1` runs the boot sweep (§6.3): stranded `delivering` rows —
possible only across a restart — return to `pending` while valid and under the
attempt cap, become `failed` at the cap, or `expired`/`superseded` past their
validity. Expired/superseded rows are terminal. There is no unbounded retry
recursion.

V1 caps the channel-send watchdog at 60 seconds. For each claim, the actual
watchdog is `min(60 seconds, valid_until - now)`; a non-positive remainder is
terminalized instead of claimed. Because a claimed send always finishes (or is
killed) before its validity boundary, an obsolete early reminder cannot complete
after its superseding rule is due — the same guarantee rev 1 bought with lease
expiry, enforced here by the validity-clamped watchdog. Settlement also rechecks
`now < valid_until`.

### 10.3 Exact timer plus reconciliation

After create/update/remove/delivery completion, `event_changed/0` causes
the scheduler to cancel its current due timer, query the earliest pending
`ready_at`, and arm one `Process.send_after/3` timer. The delay is clamped to 24
hours; a capped timer only re-queries the database and never delivers a row
before `ready_at`. This keeps long-horizon birthdays inside a portable, bounded
timer contract: no months-long armed timer whose accuracy rides through host
suspends and clock changes, and no dependence on any OTP timer range. (On
modern OTP, `Process.send_after/3` accepts delays up to ~4.6×10^18 ms — the old
~49.7-day ceiling is pre-OTP-18 — so this is hygiene, not a crash fix. The
companion jobs fix applies the same 24-hour clamp to `Jobs.Scheduler`.)

`event_changed/0` is a best-effort post-commit cast, not part of event-write
success. If the scheduler is unavailable, the caller logs/emits the signal fault
and still returns the already-committed event; the 60-second reconciliation scan
discovers it. Tests inject `scheduler: nil` rather than catching a real missing
process.

The separate 60-second reconciliation timer exists for:

- lost process messages;
- validity boundaries (expired/superseded marking, one-time completion);
- the monitor-invariant assert on `delivering` rows (§6.3);
- annual horizon maintenance;
- database rows edited while the scheduler was restarting.

It does not call a model, scan memory, or inspect arbitrary files. It is a cheap
indexed database safety pass, not a heartbeat UX.

### 10.4 Daemon-availability boundary

M30 adds no host-power behavior. If Fermix is unavailable at the scheduled time,
this milestone makes no on-time delivery guarantee.

On ordinary scheduler start/reconciliation:

- a pending reminder that is still inside `valid_until` may be delivered;
- an older reminder superseded by a later due rule is marked `superseded`;
- a row beyond `valid_until` is marked `expired` without delivery;
- recurring events maintain their next two future occurrence windows.

This is database consistency, not sleep/wake recovery. M30 does not change the
decisions in `SCHEDULED_JOB_SLEEP_RESILIENCE.md` and does not add catch-up bursts,
OS wake registration, or idle-sleep inhibition.

---

## 11. Default-Channel Delivery and Durable Retry

### 11.1 One target, resolved once

Fermix currently has no global default destination. The only configured durable
background destination is:

```toml
[fermix_core.jobs]
default_delivery_mode = "channel"

[fermix_core.jobs.default_delivery_target]
platform = "telegram"
chat_id = "8217352118"
```

M30 reuses this target rather than adding `[fermix_core.reminders]` or a second
precedence chain. Implementation documentation changes its label from
"cron-specific default delivery" to "default background delivery target"; the
config path stays stable.

Accepted configurations are the existing deterministic channel forms:

- `default_delivery_mode = "channel"` plus a valid target; or
- a valid `default_delivery_target`, which already implies channel mode.

`none`, `origin`, and `local` are invalid for event creation and refuse before
any derivation — an explicit "background delivery is off" is never overruled.
When the target key itself is absent (the fresh-install and `brew upgrade`
reality: neither path writes config), acceptance derives the owner's inbox via
the shared `FermixCore.Delivery.OwnerInbox` ladder — the first channel with an
explicit `owner_user_id`, in the fixed order telegram → signal → whatsapp
(platforms where the owner id is itself a sendable destination; a candidate
failing §11.1 validation is skipped deterministically for the next). The
acknowledgment carries `delivery.source: configured | derived`, so a derived
choice is always visible and rebindable. Only when neither an explicit target
nor a derivable owner channel exists does the event tool fail, naming both
remedies. Fermix never falls back to the originating conversation, CLI stdout,
macOS, or a different channel, and never re-resolves at send time.

At event acceptance, normalized platform, destination, and persistent thread
scope are snapshotted into the event; the planner copies those three identity
fields into each concrete reminder row. Current adapter availability is checked
with `ChannelSend.resolve_adapter/2` at acceptance, but the adapter module and
credentials are resolved live again at delivery and are not snapshotted. A
temporary health probe is not required at create time—the channel may be briefly
offline, which is what durable retry handles.

Reminder targets apply one platform-specific thread normalization contract:

| Platform | Accepted configured thread field | Canonical snapshot and send option |
|---|---|---|
| Telegram | `message_thread_id`, a positive integer or decimal string | Store its decimal string; convert it to an integer for the `message_thread_id` send option |
| Slack | `thread_ts`, a non-empty string | Store it unchanged; use the `thread_ts` send option |
| Discord | none; a Discord thread is itself the destination channel ID | Store `root`; send no thread option |
| Signal | none | Store `root`; send no thread option |
| WhatsApp | none | Store `root`; send no thread option |

Telegram, Slack, Discord, Signal, and WhatsApp are the complete v1 proactive
delivery-platform allowlist. CLI and ACP are interaction surfaces, not durable
reminder destinations — note the deliberate divergence from jobs: `cli` is a
valid jobs delivery platform through this same config key, so a
`platform = "cli"` default target is jobs-valid but event-invalid, and the
`event_store` error message says exactly that. An absent accepted thread field
normalizes to `root`.
Supplying both thread fields, supplying a non-empty field that is irrelevant to
the selected platform, or supplying an invalid value rejects event creation or
rebind; Fermix never guesses. Ingress conversation keys use the same canonical
platform/destination/thread triple—Telegram's generic inbound thread component
is normalized to the decimal `message_thread_id` string—so target matching for
"snooze that" (§8.4) cannot drift from outbound routing.

Those three identity fields use indexed columns. V1 rejects ephemeral
`reply_to`, arbitrary `req_options`, and other per-message target extras instead
of persisting stale references or secrets; delivery derives only the canonical
platform-specific thread option from `delivery_thread_scope`.

Changing `default_delivery_target` later does not silently alter existing event
rows. The owner may explicitly run
`event_update(rebind_delivery_to_default: true)` through conversation, which
snapshots the current default and regenerates unsent rows.

This guarantee is deliberately about destination identity, not the whole live
channel account. `ChannelSend` still resolves the current adapter module and the
adapter reads current credentials/account configuration at send time; Fermix
does not persist bot tokens or other secrets per event. Changing those settings
can change the effective sending account or make delivery fail, and requires the
operator to understand that channel-level effect.

### 11.2 One durable retry owner

`Temporal.Delivery` performs one bounded send:

1. render deterministic text from the reminder payload;
2. compute the validity-clamped watchdog from §10.2 and call
   `ChannelSend.with_timeout/2`;
3. call `ChannelSend.send/5` with `delivery_max_attempts: 1`;
4. persist the result.

The temporal scheduler/outbox owns every persisted retry and its timing.
`ChannelSend` does not run its own delivery loop for these sends, so two durable
backoff loops can never stack. `HttpClient.request/2` retains its existing one
immediate stale-connection refresh for `:closed`/`:econnrefused`; that is part of
one logical delivery attempt and creates no reminder row or retry schedule.

### 11.3 Shared delivery-error vocabulary

M30 adds `FermixCore.Delivery.Error.t/0` as the closed result contract at the
temporal-delivery boundary. The general
`FermixChannels.Gateway.Channel.send_message/3` behavior and
`ChannelSend.send/5` retain their existing `{:error, term()}` contracts because
other consumers—most notably ACP—have valid channel-specific errors such as
`:peer_gone`, `:detached_turn`, and `:missing_turn_sequence`. M30 does not alter
those ACP semantics.

The five reminder-capable text adapters translate their send outcomes into the
following reason vocabulary. `Temporal.Delivery` passes the result of the
*entire* `ChannelSend.with_timeout/2` call through
`FermixCore.Delivery.Error.normalize/1`, producing either `:ok` or
`{:error, reason}` where `reason` is one of:

```text
:delivery_timeout
{:rate_limited, retry_after_ms}
{:http_status, status_integer}
{:transport, :pool_unavailable | :closed | :connection_refused |
             :connection_reset | :network_unreachable | :timeout}
{:permanent, :authentication | :authorization | :invalid_destination |
             :malformed_request | :remote_rejected | :adapter_unavailable}
{:unsupported_delivery_platform, platform}
{:invalid_delivery_adapter, adapter}
{:delivery_crashed, :worker_crash}
{:unexpected_delivery_result, :invalid_contract}
```

Telegram, Slack, Discord, and WhatsApp must translate HTTP responses into the
status/rate-limit forms before returning. Signal maps a non-zero CLI exit to
`{:permanent, :remote_rejected}`, a command watchdog expiry to
`{:transport, :timeout}`, and a missing executable/client to
`{:permanent, :adapter_unavailable}`; it may log a bounded diagnostic locally
but must not expose or classify free-form CLI output. `ChannelSend` normalizes
its adapter-resolution and unexpected-result cases for its general callers.
The temporal boundary additionally maps the watchdog result
`{:error, :delivery_timeout}` to `:delivery_timeout`, maps every raw
`{:error, {:delivery_crashed, _reason}}` to the fixed
`{:delivery_crashed, :worker_crash}` reason, and validates every other result.
Raw crash reasons, response bodies, CLI output, and exception messages may be
written only to bounded local diagnostics; they never become classifier input
or persisted reminder errors.

Division of labor: adapters own platform knowledge — HTTP status and
rate-limit forms, Slack's `ok: false` API-rejection codes (a bounded known set
maps to `:invalid_destination`/`:authentication`/`:authorization`; unknown codes
map to `:remote_rejected`), and Signal's CLI exit mapping. Raw transport errors
keep passing through adapters untouched; `FermixCore.Delivery.Error.normalize/1`
maps `%Req.TransportError{reason: ...}` to the `{:transport, ...}` sub-reasons
centrally, in one place. `:nxdomain` maps to `:network_unreachable` — failed DNS
resolution is the commonest offline/captive-portal symptom, exactly the
transient window this rail's durable retry exists for; rarer unlisted reasons
remain contract violations rather than guessed sub-reasons. `:pool_unavailable` reuses
`HttpClient.connection_unavailable?/1` — an inherited substring predicate on the
Finch pool-checkout exception, and the one deliberate exception to the
no-string-matching rule below.

Scope honesty: this is net-new translation work in all five adapter files, not a
wrapper. Today Telegram/Slack/Discord/WhatsApp return interpolated status
strings (`"Slack API error: 429"`), Slack additionally returns bare
`body["error"]` strings, and Signal returns strings embedding CLI stdout; only
`{:rate_limited, ms}` is already structured (shared `RetryHint`). Changing those
returns is visible to every existing consumer: `Reply.format_delivery_error/1`
gains clauses for the new tuples, and the `inspect(reason)` strings stored by
jobs (`delivery_error`) and harness (`last_delivery_error`) change shape. None
of this narrows the `{:error, term()}` behaviour contract, and ACP semantics are
untouched, but Stage 4 verifies those consumers explicitly.

Anything outside this closed vocabulary is an implementation contract violation,
logged and treated as terminal `:invalid_contract`. The reminder scheduler never
string-matches human messages (see the single carve-out above).

### 11.4 Retry policy

One planned reminder receives at most five durable claim cycles (logical
delivery attempts):

```text
attempt 1: due time
attempt 2: +1 minute
attempt 3: +5 minutes
attempt 4: +15 minutes
attempt 5: +60 minutes
```

Each delay is measured from the previous failed attempt. Every retry is clamped
by `valid_until`. A structured `{:rate_limited, retry_after_ms}` uses the larger
of the plan delay and server-provided delay, but never bypasses the attempt or
validity caps. If the resulting `ready_at` is not strictly before `valid_until`,
settlement marks the row expired/superseded immediately instead of
persisting an unclaimable pending row.

Retry only a positive allowlist of structured transient failures:

- connection unavailable / pool checkout before a connection;
- network transport close/reset/unreachable;
- bounded send timeout;
- HTTP 408, 425, 429, or 5xx.

Authentication failures, invalid destinations, unsupported adapters, malformed
requests, other 4xx responses, and unclassified errors are terminal on the first
attempt.

`attempt_count` increments in the atomic claim before external I/O. A worker
crash before reaching the adapter therefore consumes one logical attempt; this
keeps crash recovery bounded and makes the database counter honest about work
claims rather than pretending it can observe a remote side effect exactly. The
five-attempt claim is not a promise of exactly five raw HTTP requests because
the shared HTTP client may perform its one immediate stale-connection refresh.

On terminal failure or exhaustion:

- that reminder row becomes `failed` with a bounded reason;
- the parent event remains active;
- later planned reminders remain eligible;
- next year's annual occurrence remains eligible;
- `event_list` exposes the failure and lifecycle telemetry records it.

### 11.5 At-least-once truth

External channel sends and SQLite commits are not one transaction. The worker
marks a row delivered only after the adapter returns `:ok`. If the channel
accepts the message and the BEAM dies before SQLite records success, the boot
sweep returns the still-`delivering` row to pending and the message may be sent
twice.

The existing shared HTTP client also retries one stale-socket
`:closed`/`:econnrefused` result immediately. If a mutating request was accepted
but its response was lost, that refresh can duplicate inside one logical
attempt. M30 keeps this cross-daemon transport contract and includes it in the
same at-least-once guarantee; persisted `attempt_count` deliberately does not
claim to count raw HTTP requests.

The same ambiguity exists when a transport close/reset or watchdog timeout is
reported after the remote service may have accepted the request. Retrying those
allowlisted failures intentionally favors eventual reminder delivery over a
false exactly-once claim.

Marking delivered before the send would silently lose reminders in the opposite
crash window. Current channel adapters expose no universal idempotency key or
remote message ID, so exactly-once delivery is impossible. M30 explicitly chooses
durable at-least-once best effort and documents the rare duplicate window.

---

## 12. Tool Surface and Runtime Routing

### 12.1 Built-ins

All tools are attended-owner-only and emit through
`FermixCore.Tools.Telemetry.exec/5`.

| Tool | Responsibility |
|---|---|
| `event_store` | Validate and create a one-time/yearly event, snapshot default delivery, materialize reminders |
| `event_list` | Search/list events by text, kind, status, or bounded date range; include delivery failures and next reminders |
| `event_update` | Patch title/time/recurrence/plan; optionally rebind to current default target |
| `event_remove` | Soft-cancel an event and its unsent reminders. An omitted ID resolves like "snooze that" (§8.4): the parent event of the latest reminder delivered into the caller's conversation within 24h — "cancel that" after a reminder cancels the whole event, and the result names the event and its recurrence so the scope is visible |
| `reminder_snooze` | Create one bounded ad-hoc reminder from a delivered/pending source; resolve an omitted ID from the latest delivered reminder in the caller's target conversation (§8.4) |

Capability metadata is explicit (`policy_class` in the capability registry):
`event_list` is `:read_only`; the other four tools are `:read_write`; all five
set `owner_only?: true`. Those registry fields do not replace the
attended-origin advertisement/execution gate below.

Advertisement and execution both require `source_trust == :operator`,
`subagent_depth == 0`, and the existing authoritative
`computer_use_origin in [:interactive, :voice]`, plus
`harness_continuation_depth == 0`. The four conditions are implemented as **one
shared predicate** (e.g. `Temporal.Access.attended_operator_turn?/1`) called
from both the `advertise?/1` callback and `execute/2`, so the two gates cannot
drift. `TurnRunner` assigns `:interactive` as the catch-all for every
non-`"background"` channel (chat, CLI, and ACP land there today — it is not an
enumerated list, so any future unattended surface must mark itself), realtime
marks a live call `:voice`, background marks `:unattended`, and scheduled runs
omit the marker and therefore fail closed. Because `:interactive` is a
catch-all, the invariant test iterates **every** event tool across **every**
non-attended context (guest, scheduled, background, delegated, continuation) —
the whole-feature-surface style the Known Pitfalls section mandates. The
continuation-depth check excludes synthesized coding-run output that re-enters
an otherwise interactive owner channel. Trust alone is insufficient because
operator-created cron and continuation runs can also carry operator trust.

One deliberate read carve-out (owner decision 2026-08-03): `event_list` gates on
`operator_read_turn?/1` — the attended predicate OR an operator-created
scheduled run (operator trust, no origin marker at all, top-level, no
continuation depth) — so a cron morning brief can list stored events alongside
a connected calendar. The four mutating tools keep the strict attended gate;
`:unattended` background runs, guests, delegated workers, and continuations
remain fully excluded; and the whole-family invariant test pins the asymmetry
explicitly (the scheduled context advertises exactly `["event_list"]`). The
operator accepts the §14 corollary: a scheduled run's output delivers wherever
that job is configured, which may differ from the owner's default channel.

Every public function validates maps, types, timezones, recurrence constraints,
rule caps, ownership, attended origin, and state transitions. Errors are
returned as explicit `{:error, reason}` / tool errors and never swallowed.
`event_list` defaults to 25 rows, caps at 100, accepts at most a two-year date
window per call, and uses an opaque `(next_occurrence_on, id)` keyset cursor for
additional pages. The default listing is **upcoming from today**: with no
explicit window and the default active-status filter, rows whose
`next_occurrence_on` has passed are floored out (NULL caches stay visible —
fail visible, never hide), which is what keeps a snooze-reactivated passed
event out of the upcoming view (§8.4/§9.4); an explicit `from`, window, or
status filter bypasses the floor for history queries. The floor is the UTC
calendar date of the injected clock — the same basis the completion scan
compares `next_occurrence_on` against, and a read path must not hard-fail on a
missing personalization timezone (cost: west of UTC, an event earlier today
can leave the default list a few hours early).

### 12.2 Structured time input

`event_store` does not parse unrestricted English. The model converts the owner
statement into one tagged structured form:

```json
{"type":"date","date":"2026-08-16"}
{"type":"datetime","date":"2026-11-01","time":"01:30:00","utc_offset":"-04:00"}
{"type":"relative","amount":2,"unit":"weeks","time":null}
{"type":"annual","month":9,"day":14}
```

The tool owns current-time/timezone resolution and rejects invalid combinations.
The initial relative vocabulary is bounded to days and weeks; the model may pass
an already-resolved ISO date for other expressions after obtaining the precise
time when necessary. If the owner did not explicitly name a zone, the tool reads
the existing personalization timezone itself; the model does not copy a cached
prompt label into storage. A missing/invalid configured zone returns actionable
setup guidance rather than silently substituting UTC.

For a one-time local datetime, the tool resolves through the configured IANA
database and persists the resulting UTC `occurrence_at`. A nonexistent DST-gap
time is rejected and the agent asks for a real local time. An overlap time is
rejected unless `utc_offset` selects exactly one of the two valid instants; the
agent asks whether the owner means the first or second occurrence and then sends
the matching offset. Fermix never silently shifts a gap or chooses a fold.

Timed lead rules such as "24 hours before" subtract an absolute duration from
`occurrence_at`. Date-only lead rules construct local calendar dates first and
then resolve their notification wall time. Any custom reminder wall time that is
itself ambiguous/nonexistent fails event creation/update with the same focused
clarification contract.

### 12.3 Runtime prompt change

Replace the current blanket instruction "for reminders ... use
`schedule_job`" with the explicit boundary below. The same implementation edit
must also narrow `ScheduleJob.description/0`, `ScheduleJob.when_to_use/0`, and
its reminder-oriented examples; changing only the system prompt would leave the
tool catalog contradicting it.

```text
- Use event_store for deterministic personal reminders, appointments,
  deadlines, birthdays, anniversaries, and other stored dates whose future
  action is only to notify the owner.
- Use schedule_job when the future run must reason, call a provider, use tools,
  inspect changing state, produce a digest, or perform work.
- Store high-confidence owner-stated personal events even without the words
  "remember" or "remind me"; acknowledge the exact event and reminder plan.
- Ask before storing ambiguous, tentative, hypothetical, quoted, or
  third-party informational dates.
```

Update `apps/fermix_core/priv/skills/self_knowledge/SKILL.md` in the same
implementation change. This milestone materially adds a feature and tool family;
the runtime self-reference may not ship stale.

---

## 13. Deterministic Rendering

The reminder payload is rendered without a model. Messages are short and include
the absolute date/time:

```text
Reminder: Sarah's birthday is September 14 (in 7 days).
```

```text
Today: Sarah's birthday — September 14.
```

```text
Reminder: Dentist appointment — August 16 at 3:00 PM ET (in 1 hour).
```

Rules:

- Always include the absolute event date; include time/timezone when present.
- Relative text is computed at render time and omitted if a retry makes it
  misleading.
- Do not include internal IDs, retry counts, model language, or configuration
  details in ordinary reminders.
- Render one message of at most 1,800 UTF-8 bytes, truncating only at a grapheme
  boundary and including the absolute date/time plus any ellipsis. This stays
  below the smallest supported text limit (Discord) and prevents adapter
  chunking from turning one reminder into several messages.
- Store the bounded semantic payload on the reminder row so later event edits do
  not rewrite sent history.

Reminder delivery does not insert a synthetic conversation-history row in v1.
The current `ConversationStore` replays only chat messages, drops message
metadata from model history, and owns an in-memory cache that a direct Repo
insert would bypass. "Snooze that" is instead resolved server-side from the
latest delivered reminder for the caller's exact target conversation as defined
in §8.4. The reminder outbox remains the sole authority.

---

## 14. Trust, Privacy, and Safety

- Event tools require the attended top-level operator gate from §12.1 at both
  advertisement and execution. Missing origin/trust context fails closed rather
  than inventing owner authority.
- Guest, detached-background, delegated-worker, and synthesized
  coding-continuation capability catalogs, tool search, dispatch, and prompts
  exclude the entire event family. Scheduled-job runs exclude the four mutating
  tools and, when operator-created, may read via `event_list` (§12.1 carve-out).
- Events are owner-scoped. A caller may narrow list queries but cannot widen
  beyond its authorization.
- The delivery target is resolved once, at acceptance, with a closed ladder
  (owner decision 2026-08-03): the explicitly configured
  `default_delivery_target` wins; absent that, the owner's inbox is derived
  from the first channel carrying an explicit `owner_user_id`
  (telegram → signal → whatsapp — platforms where the owner id IS a sendable
  destination; never Discord/Slack, never `allowed_user_ids`, never mere
  channel presence, never another owner's ID). The acknowledgment names the
  choice (`delivery.source: configured | derived`) so a derived target is
  visible and rebindable, and a hostile `default_delivery_mode`
  (`none`/`origin`/`local`) refuses before derivation — an explicit
  "background delivery is off" is never overruled. Fermix still never infers
  a DM on id-less platforms and never tries a second channel after failure.
- Target snapshots prevent a later `default_delivery_target` edit from silently
  moving a personal birthday/deadline to another conversation; live channel
  credentials remain governed by channel configuration as described in §11.1.
- Store only the event title/description and bounded provenance coordinates; do
  not duplicate full conversation transcripts in event rows.
- Reminder content in telemetry is gated by
  `FermixCore.Telemetry.capture_content?/0`.
- Event creation is driven only by the owner statement in the current turn, not
  by untrusted web/tool output or a background scan.

---

## 15. Telemetry and Operational Visibility

### 15.1 Tools

The five tools use the shared tool emitter, so success, duration, gated
input/output, and whatever correlation the originating surface supplies join
existing traces with no new run kind. Text main turns carry their normal unique
`session_id`; realtime voice currently has a surface-scoped value and must not be
described as providing the same uniqueness guarantee.

Each tool supplies `input: args` exactly once. Implementation either extends
`Tools.Support.run/3` with one args-aware arity or calls
`FermixCore.Tools.Telemetry.exec/5` directly; it must not assume the current
helper emits input, because it only forwards results today.

### 15.2 Detached lifecycle event

One owning emitter, `FermixCore.Temporal.Telemetry`, emits a single event family:

```text
[:fermix, :reminder, :lifecycle]
```

Metadata uses a fixed allowlist:

- `phase`: `materialized | claimed | delivered | retry_scheduled | failed |
  expired | superseded | cancelled | event_completed | scheduler_error`;
- `component`: the fixed string `temporal_scheduler` (the JSONL
  `agent_field` for this non-agent event family);
- `event_id`, `reminder_id`, `occurrence_key`, `rule_id`;
- `platform`;
- `attempt`;
- `result` and typed `error_class`;
- content only behind the shared content gate.

Measurements include `duration_ms` where work occurred and `count: 1` otherwise.
No arbitrary reason/body map is accepted by the emitter.

Register the event in `Trace.TelemetryHandler.event_definitions/0` as an
`agent_event` via the per-family convention (`Temporal.Telemetry` exposes
`trace_event_definitions/0` with `agent_field: :component`, like the
plugin-dist/timeout/MCP-client families), and in the same implementation diff
add the `FermixOpik.Reporter` `@events` entry, an
`FermixOpik.Aggregation.apply_event/5` clause building a **self-closing
reminder trace** (the plugin-dist precedent — built inline with `Mapper`
helpers; no dedicated Mapper builder is required for a self-closing family),
and aggregation tests including the Reporter-parity assertion the MCP-client
tests use. `FermixOpik.TraceFile.normalize_agent_event/2` (`mix opik.replay`)
is intentionally not extended, matching the harness/plugin-dist/MCP-client
precedent. Because delivery is not an agent run, each lifecycle event is a
self-closing reminder operation correlated by IDs; it does not mint a fake
subagent root.

### 15.3 Inspection

`event_list` exposes next occurrence, reminder plan, next due reminder, last
delivery state/error, and snapshotted platform without exposing channel secrets.
Trace logs expose scheduler faults.

M30 does not add a `fermix doctor` row. That command runs without the daemon's
application tree, so live scheduler state would require a new control-socket
method or overview payload; that operational surface is not required for the
reminder capability. No calendar dashboard is added either.

---

## 16. Failure Semantics

| Failure | Required result |
|---|---|
| No configured default target | Derive the owner's inbox from the first owner-configured channel (§11.1 ladder); only when no channel carries an `owner_user_id` either does `event_store` fail, naming both remedies; no event row |
| Invalid timezone/date/recurrence | Tool error; no partial write |
| DST gap/ambiguous local time without offset | Focused clarification; no partial write or silent shift |
| Event DB transaction fails | Tool error; no acknowledgement claiming success |
| Post-commit scheduler signal unavailable | Keep committed tool success, emit `scheduler_error`; reconciliation discovers row |
| Scheduler due query fails | Log + lifecycle error, re-arm at bounded error floor |
| Delivery capacity full | Leave row pending; re-arm at bounded backpressure floor |
| Worker start fails after claim | Scheduler settles the row: 5-second pending retry for claims 1–4; claim 5 fails terminally |
| Retryable channel failure | Persist next attempt on same target, within cap/validity |
| Permanent channel failure | Mark that reminder failed immediately; event stays active |
| Adapter returns outside shared error vocabulary | Log contract violation and fail that reminder terminally |
| Retry exhaustion | Mark failed and expose via event list/telemetry; no channel fallback |
| Earlier reminder still failing when later one is due | Mark earlier row superseded; send only latest valid row |
| Planner runs twice | Unique constraint makes second materialization a no-op |
| Two scheduler ticks race | Atomic claim allows one delivery worker |
| Worker crashes before send | `:DOWN` handler re-reads the row; still-`delivering` returns to pending (attempt consumed) while valid |
| Worker crashes after remote acceptance | Rare duplicate possible; at-least-once contract |
| Daemon or scheduler restart with `delivering` rows | Boot sweep resets them (pending / failed at cap / expired past validity); safe because no worker outlives the scheduler |
| Daemon unavailable at due time | No on-time guarantee; ordinary reconciliation only handles still-valid rows |
| Current-year birthday reminder fails | Later rule and future years remain active |
| Event removed/edited while pending | Old unsent rows cancelled by revision transaction |
| Event mutation while a send is in flight | Fail with `delivery_in_progress`; owner retries after the bounded attempt |

Errors are always logged/traced before returning or transitioning. There is no
`{:error, _} -> :ok`, bare rescue, infinite retry, or alternate delivery path.

---

## 17. Implementation Stages (`step -> verify`)

### Stage 0 — Lock contracts with red tests

**Step:** Add failing tests for event/job routing, attended-origin gating,
one-event annual identity, bounded reminder plans, default-target requirement,
no macOS/origin fallback, and delivery retry state.

**Verify:** Tests fail for the missing M30 behavior and do not call real channels,
provider APIs, host notification APIs, `System.cmd`, or `Port.open`.

### Stage 1 — Persistence and pure planner

**Step:** Add the two tables, Repo CRUD/claim queries, `Temporal.Defaults`, and the
pure local-calendar `Temporal.Planner`.

**Verify:** Migration is idempotent; planner tests cover one-time, yearly,
two-occurrence horizon, conflict-ignore materialization, timezone conversion,
February 29 policy, DST gap/overlap refusal, past-rule skipping, fixed-width UTC
ordering, and event revision updates.

### Stage 2 — Event tool family and prompt routing

**Step:** Add attended-owner-only event CRUD tools, capability metadata,
runtime/tool-catalog routing boundaries, and tool telemetry. Resolve/snapshot the
existing default target at event acceptance.

**Verify:** High-confidence event requests call the event rail; active future work
still calls `schedule_job`; ambiguous inputs ask; missing/invalid targets fail
loud; guest/scheduled/background/delegated/continuation profiles cannot discover
or dispatch the tools.

### Stage 3 — Scheduler and deterministic renderer

**Step:** Add temporary-worker delivery supervision (scheduler before workers
under `:rest_for_one`), nearest-due timer, bounded cursor reconciliation, atomic
claim with worker monitors and the boot sweep, supersession, bounded
concurrency, and deterministic message rendering.

**Verify:** Fake-clock tests prove exact re-arming, one claim under racing
ticks, a worker crash returns the row to pending with its attempt consumed, a
fifth-attempt crash is terminal `failed` (never attempt six), the boot sweep
after a simulated restart resets `delivering` rows exactly once
(pending/failed/expired by attempt and validity), workers never restart without
a claim, no scheduler blocking/hot-loop/LLM call, and only the latest valid
reminder after a simulated outage.

### Stage 4 — Durable channel retry

**Step:** Add the closed temporal delivery-error normalizer, update the five
reminder-capable text adapters to return its structured reasons without
narrowing the general channel behavior, send through one `ChannelSend`
invocation, normalize the whole watchdog result, and persist the five-claim
schedule, rate-limit delay, terminal failure, and crash recovery.

**Verify:** A fake channel that fails transiently then recovers receives one
successful logical occurrence; every error variant classifies exhaustively;
an arbitrary watchdog child crash is reduced to the bounded `worker_crash`
reason; free-form errors fail as invalid contracts; ACP's existing error
contract is unchanged; `Reply.format_delivery_error/1` renders every new reason
shape and the changed `inspect` strings in jobs/harness delivery errors are
acknowledged in the diff; permanent errors do not retry; cap and `valid_until`
are exact; no second channel or macOS code path is reachable; the
logical-attempt/raw-request distinction remains honest.

### Stage 5 — Recurrence rollover, observability, and docs

**Step:** Wire bounded annual horizon maintenance, temporal lifecycle
telemetry, Trace/Opik mapping, README/wiki, M4.11 partial-supersession note,
and self-knowledge updates.

**Verify:** Passing a birthday rolls forward across years with one event row;
Trace JSONL and Opik show reminder lifecycle fields; `event_list` reports target
and failed states; self-knowledge explains the event/job boundary.

### Stage 6 — Full repository gates

**Step:** Run the required project gates.

**Verify:**

```sh
mix compile
mix test
mix credo --strict
mix format --check-formatted
```

Zero warnings. No real host state, keychain item, channel message, notification,
or external service is touched by tests.

---

## 18. Test Matrix and Acceptance Criteria

### 18.1 Planner and recurrence

- A September 14 birthday created before September 14 creates reminder rows for
  this year and next year.
- The same birthday created after September 14 starts with next year and the year
  after.
- Re-running the planner produces no duplicate rows.
- A stale revision planner cannot insert rows or advance horizon caches after an
  event edit commits.
- Repeating the same active `event_store` call returns the existing event rather
  than creating duplicate birthday reminders.
- Editing an event creates replacement rows under a new revision without
  colliding with immutable history.
- After the current occurrence passes, there is still one event row and the
  two-future-occurrence horizon advances.
- Annual calculation never drifts across leap years.
- One-time DST-gap input is rejected; an overlap requires an offset selecting
  one valid instant.
- February 29 cannot be stored yearly without an explicit non-leap policy.
- A failed current-year reminder does not pause/cancel the annual event.
- A passed one-time event becomes completed only after its reminders are
  terminal and no longer appears in the default upcoming list.
- A post-boundary snooze atomically reactivates a completed one-time parent
  (restoring its past occurrence date), remains claimable, does not make the
  passed event appear upcoming, and lets reconciliation complete the parent
  again after the snooze terminates.

### 18.2 Multiple reminders

- Birthday defaults deliver week-before and day-of once each.
- Timed appointment defaults deliver 24-hours-before and one-hour-before once
  each.
- Explicit one-shot reminder creates only one rule.
- A custom plan replaces, rather than silently appends to, defaults.
- Past rules are skipped.
- A failed old rule is superseded when a newer rule becomes due.
- A successful rule is never sent again for lack of acknowledgement.
- Repeating the same snooze request is idempotent; replacing its time leaves one
  active snooze and preserves delivered source history.

### 18.3 Delivery

- The configured default target is snapshotted on event creation.
- Changing `default_delivery_target` does not rewrite an existing event's
  snapshotted destination.
- Explicit rebind updates unsent rows to the current default.
- Missing/invalid default target leaves no event row.
- Target normalization maps Telegram only to `message_thread_id`, Slack only to
  `thread_ts`, and the other allowed platforms to root; conflicting or
  irrelevant thread fields fail before persistence.
- Transient failures follow exactly four bounded delays/five total durable
  claims.
- Rate-limit retry-after is honored inside the validity boundary.
- Permanent and unknown failures are terminal.
- ACP retains its existing non-reminder errors, while an arbitrary crash from
  the whole watchdog/send call is normalized to the bounded `worker_crash`
  reason before classification or persistence.
- Delivery never switches platform/destination.
- Reminder text always names the absolute date/time.
- Rendered output is one message at most 1,800 UTF-8 bytes.
- Successful delivery becomes the target conversation's latest snoozable
  reminder in the outbox; a failed delivery does not.
- Omitted-ID snooze resolution cannot cross owner, platform, destination,
  thread, or the 24-hour lookback.
- Omitted-ID `event_remove` resolves through the same single resolver to the
  delivered reminder's parent event, names the event and recurrence scope in
  its result, and fails visibly (ask which event) when nothing matches.

### 18.4 Scheduler and safety

- One timer points at the earliest `ready_at`.
- A reminder more than 24 hours away arms a bounded recheck and cannot deliver
  early.
- Create/update/remove causes immediate re-arm.
- A failed post-commit re-arm signal cannot turn a committed event write into a
  tool error; reconciliation discovers it.
- Due scan and delivery concurrency stay within caps.
- Validity-boundary and annual-horizon scans use their covering indexes, bounded
  keyset pages, and wrap without starvation.
- Two simultaneous claims deliver once (claims serialize in the one scheduler).
- A worker crash returns the row to pending with its attempt consumed; a
  fifth-attempt crash becomes failed, never attempt six; a `:DOWN` after
  settlement changes nothing.
- Delivery workers are `:temporary` and cannot outlive the scheduler
  (supervision order); the boot sweep after a simulated restart resets
  `delivering` rows exactly once and is bounded and validity-aware.
- Event mutation and reminder claim serialize; a mutation during delivery fails
  visibly and cannot create a competing send.
- No LLM/provider call occurs on reminder delivery.
- Guest, scheduled, background, delegated, and coding-continuation contexts
  cannot advertise or execute event tools; an attended top-level operator can.
- Tests use fake clocks, fake Repo servers where appropriate, and fake adapters.
- No test sends a real message or touches a real OS notification surface.

### 18.5 End-to-end acceptance

M30 is complete when all of the following are proven:

1. From an owner channel, "Sarah's birthday is September 14" stores one yearly
   event and visibly confirms its two-reminder plan.
2. The week-before and day-of reminders are delivered through the snapshotted
   default Fermix channel with no provider call.
3. The database already holds bounded future reminder rows; after the current
   year passes, the same event ID advances and future rows remain scheduled.
4. A temporary channel failure retries the same reminder on the same channel and
   either delivers or becomes visibly failed after the bound.
5. A failed reminder does not disable later reminders or future years.
6. "What do I have coming up?", edit, remove, rebind, and snooze all work
   through normal conversation.
7. "Check flight prices next Friday" still routes to `schedule_job`.
8. No calendar UI, macOS notifier, heartbeat scan, OS wake integration, or channel
   failover ships in the diff.

---

## 19. Rejected Alternatives

### 19.1 Store dates only in memory

Rejected: memory is not due-indexed, recurrent, or delivery-aware, and its
reviewer is allowed to archive passed dates.

### 19.2 Translate every reminder into `schedule_job`

Rejected: a deterministic notification should not create an isolated agent run,
provider cost, prompt snapshot, tool policy, job memory source, and run history.

### 19.3 Hourly heartbeat over memory/files

Rejected: it repeatedly spends inference to rediscover state that should be
structured once, has coarse latency, and turns an invisible polling file into the
product interface.

### 19.4 One OS cron entry per reminder

Rejected: it bypasses OTP supervision, SQLite claims, channel delivery telemetry,
and bounded retry; edits/removals become external process/config management.

### 19.5 macOS Notification Center

Rejected by owner decision: proactive events stay inside Fermix and its configured
channels. No platform-specific local notification surface.

### 19.6 Channel failover

Rejected: sending personal event data to another channel after failure is a
privacy and UX surprise. Retry the accepted target, then fail visibly.

### 19.7 Full calendar and RRULE in v1

Rejected: the request is proactive personal recall, not a calendar server.
One-time and yearly events cover the motivating cases without importing a large
calendar semantics surface.

### 19.8 Resolve default target at every send

Rejected: a config change could silently move a personal reminder into a
different channel or group. Snapshot once; rebind only on explicit owner action.

### 19.9 Exactly-once promise

Rejected: current text channel APIs and adapters provide no universal
idempotency key. The honest guarantee is durable at-least-once best effort with a
documented rare duplicate window.

### 19.10 Lease tokens and fenced settlement (rev 1 design)

Rejected for v1: on a single-BEAM daemon with one scheduler process, claims
serialized in that process, and workers that cannot outlive it (supervision
order §6.3), monitors plus a boot sweep give identical at-least-once guarantees
with materially less mechanism — no lease columns, no expiry arithmetic, no
fenced compare-and-set SQL, no stale-token test matrix. Neither the jobs
scheduler nor the harness delivery worker uses leases; both rely on the same
single-writer safety this design keeps. The only additional duplicate window
(a scheduler-only crash killing an in-flight send the remote already accepted)
is inside the §11.5 contract, and the scheduler performs no network I/O, so the
window is dominated by daemon death either way. Leases return only if delivery
ever moves outside the daemon's process tree.

---

## 20. Deferred Follow-Ups

- Lease/fenced settlement if delivery ever moves out of the daemon's process
  tree (§19.10).
- External calendar adapters/import/export and conflict policy. Owner
  decision 2026-08-03: stays deferred — Google tokens expire often enough
  that a sync would mostly serve stale events, and a stale mirror is worse
  than a named separate source. Until then the runtime contract makes agenda
  questions consult every available calendar surface with source
  attribution, and capture asks before storing a date a connected calendar
  likely already tracks (double-reminder surprise).
- Mining existing memory for candidate events behind an explicit owner-reviewed
  migration command.
- Monthly/weekly recurrence and a carefully bounded recurrence DSL.
- A global config namespace replacing the historical
  `[fermix_core.jobs].default_delivery_target` path. If done, migrate in one
  release and delete the old read path; never keep a new-key/old-key fallback.
- Optional read-only upcoming-events card on the existing home dashboard, if
  operational evidence shows the conversational list is insufficient.
- Host wake/offline reliability under the separate scheduled-job power-management
  design.
- Remote provider idempotency/message IDs if every supported channel eventually
  exposes a usable common contract.

---

## 21. Implementation Log

**2026-08-02 — implemented in full (uncommitted working tree), all §17 stages.**
Companion jobs fixes landed first: `Jobs.Scheduler` gained the 24-hour timer
clamp (bounded-timer hygiene — on modern OTP `Process.send_after/3` accepts up
to ~4.6×10^18 ms, so the old ~49.7-day crash premise was wrong) and
liveness-based stuck-run reconciliation at init and each reconcile tick (orphans
reaped through the same path as monitored crashes; surviving runners re-adopted
after a scheduler-only restart via a run-id process-dictionary key, not a
GenServer call — a busy runner cannot answer calls).

Shipped: migration v17 (`temporal_events` + `reminder_occurrences`, §7 rev 2
schema plus CHECK constraints for `attempt_count 0..5` and
`delivered ⇒ sent_at`); temporal SQL in private conn-passing
`Memory.Repo.TemporalSql` (§7 preamble option); pure `Temporal.Planner` +
`Temporal.Defaults`; `Temporal.Registry` + five attended-owner tools with the
single shared `Temporal.Access.attended_operator_turn?/1` at both gates and a
whole-family trust-invariant test; `Temporal.Scheduler`/`DeliverySupervisor`/
`DeliveryWorker`/`Renderer` per §6.3/§10 rev 2 (monitors + boot sweep, no
leases); `Delivery.Error` closed vocabulary + five adapter send-path
translations + `Reply.format_delivery_error/1` clauses; `[:fermix, :reminder,
:lifecycle]` via `Temporal.Telemetry` + Trace/Opik self-closing traces (+ a
family section in `docs/TELEMETRY_CONTRACT.md`); prompt/tool routing per §12.3;
self-knowledge via `references/events_reminders.md`. Verification: red-first
tests per stage; adversarial 4-lens review (2 blockers — a due-timer hot-loop on
past-validity pending rows and an unvalidated `event_list` text filter reaching
the single writer — plus majors, all fixed); final gates green — full umbrella
6,062 tests + 2 doctests 0 failures, `credo --strict` clean, zero warnings,
`format --check-formatted` clean.

Deviations from this doc as written (reviewed set):

1. §8.3 — supersession relabels PENDING rows only; terminal `failed` rows keep
   their state (history immutability §7.3(5) and §11.4's "expose the failure"
   win; a failed row cannot send, so the anti-burst guarantee is unchanged).
2. §10.2 — the `now < valid_until` settlement recheck applies to retry/recover
   paths, not the delivered path: once the adapter returned `:ok` the message
   went out, and recording anything else would make the outbox lie.
3. §10.2/§6.3 — boot-sweep outcomes are pending/failed/expired, never
   `superseded` (the sweep lacks later-rule context; the reconciliation
   boundary pass owns supersession).
4. §11.4 — at settlement the attempt cap is checked before the validity clamp:
   a fifth failure settles `failed` (visible in `event_list`) even when the
   hypothetical next delay would overshoot `valid_until`. The sweep keeps
   validity-first, where real time has actually passed.
5. §11.3 — `:nxdomain` maps to `{:transport, :network_unreachable}` (offline
   DNS); Signal's command-host crash/port failure classify as
   `{:transport, :timeout}` (the CLI subprocess is Signal's transport);
   `normalize/1` passes an adapter's own
   `{:unexpected_delivery_result, :invalid_contract}` through; all five
   adapters map an unconfigured send to `{:permanent, :adapter_unavailable}`.
6. §11.3 — Telegram's shared HTTP-error translator serves send and
   react/draft/media paths alike, so those paths now also return
   `{:http_status, n}` (one translator; a send-only fork would be Rule-12
   duplication).
7. §6.3 — a test-tree `scheduler_enabled` Application-env key (default true,
   false in `config/test.exs`) mirrors the jobs scheduler; not a TOML surface.
   The Registry takes `:now`/`:jobs_config`/`:personalization` injection opts
   (the `DeliveryDefaults` seam) while scheduler/worker keep `now_fn`.
8. §15.2 — an idempotent repeat create (`{:existing, …}`) emits no
   `materialized` phase: no rows were written, and §5.2 forbids implying a
   second plan.
9. §12.1 — `event_update`/`event_remove`/single reads are not owner-narrowed
   (only `event_list` filters `owner_id`); the system is single-owner today
   (`owner_id` constant `"default"`). Must be closed before any multi-owner
   work.
10. §12.3 — the events knowledge lives in the self-knowledge skill's
    `references/events_reminders.md` (the decomposed pattern): the main body
    hit its 60,000-byte guard. Remaining headroom is ~216 bytes; the inline
    `## Jobs` section (~6.4 KB) is the next decomposition candidate — owner
    decision.
11. Open specifics the doc left to implementation, now fixed: custom-plan JSON
    rule shapes (`days_before`/`duration_before`/`at_time` with deterministic
    rule ids), the opaque list cursor (`"<deadline>|<id>"`, malformed ⇒
    `{:invalid_cursor, value}`), renderer rounding rules (calendar days for
    date-only, day/hour granularity for timed, clause omitted under an hour or
    once begun; year shown only when it differs; real zone abbreviation, not
    "ET").

Follow-ups deliberately not done here: `TraceFile` replay for the reminder
family (precedent: skipped), media-path adapter vocabulary (reminders are
text-only), owner-narrowing in item 9.

**2026-08-02 addendum — snooze reinstated and shipped (same day).** The
deferral was a scope call, never a technical blocker; the owner reversed it and
§8.4 shipped as migration v18 on the additive seam v1 left for it:
`source_reminder_id` + the dedupe/source/target-sent indexes, the compound
`Repo.snooze_temporal_reminder` transaction (idempotent re-snooze, one active
snooze per source, delivered sources immutable, completed-parent reactivation
**restoring `next_occurrence_on`** so reconciliation re-completes after the
snooze terminates — the pre-filter trap §8.4 documents), target-scoped
`latest_delivered_reminder` resolution, and the `reminder_snooze` tool joining
the shared attended gate and the whole-family trust-invariant test (its
completeness assertion now also catches `reminder_*` names). Also in this
addendum: the self-knowledge skill's `## Jobs` section was decomposed into
`references/jobs.md` (freeing ~5.3 KB of main-body headroom under the 60 KB
guard) and an in-pattern inline `## Events & reminders` stub was restored; the
runtime prompt gained one snooze routing line. Snooze deviations from §8.4 as
written: the datetime snooze form resolves in the owner's personalization zone,
not the event's zone ("snooze until 3pm" is the owner's wall clock; the
acknowledgment names the zone used); an owner mismatch on an explicit
`reminder_id` reads as `:not_found` rather than a distinct error (a distinct
atom would confirm another owner's row exists); the in-transaction dedupe check
is an explicit SELECT with the partial unique index as the schema invariant
(typed error, no SQLite string parsing); the telemetry `superseded` list covers
every row the transaction retired, including an explicitly-snoozed pending
source. Verification: red-first at repo/registry/tool layers (42 new tests,
including the full reactivate → claim → deliver → re-complete round trip and
five near-miss axes of the resolution query), then an adversarial review that
FAILED the first cut with 1 blocker + 4 majors — all reproduced, all fixed
red-first in a second pass: (1) status-blind idempotency acknowledged a snooze
over a cancelled/superseded row → fixed by status-aware **revival in place**
(§8.4; the unique index was the constraint that forced the elegant fix);
(2) a mid-delivery sibling snooze escaped supersession and one source sent
twice → `snooze_delivery_in_progress`; (3) "snooze that" was structurally
unmatchable in Slack channels (root mentions mint their own `ts`) → the
one-directional root widening in §8.4, pinned by tests that drive the REAL
ingress `ConversationKey` constructor (the detection-and-execution-share-one-
constructor pitfall); (4) the 90-day horizon bound only the duration form →
uniform `future_instant/2` gate; (5) a snooze-reactivated passed event listed
FIRST in the default upcoming view for the whole snooze horizon → the §12.1
UTC-date floor. Plus three minors (bounded supersede page with invariant
alarm, a sub-millisecond watchdog truncation, and a v18-replay migration test
whose fixture DDL is sourced from `TemporalSql.schema_sql()` so it cannot
rot). Final gates: full umbrella **6,144 tests, 0 failures** (fermix_core
5,141 / channels 764 / web 161 / opik 73 / nif 5), `mix compile
--warnings-as-errors` clean, `mix credo --strict` clean (19,833 mods/funs),
`mix format --check-formatted` clean. Known judgment calls for review: the
upcoming floor uses the UTC calendar date (a read path must not hard-fail on
missing personalization; west-of-UTC events can leave the default list hours
early), and the Slack conversation-identity oddity (each root mention keys a
fresh conversation) is flagged as a separate follow-up — it affects FIFO lanes
and history scoping beyond snooze.

**2026-08-03 addendum — implicit "cancel that", e2e suite, seeder pre-grants.**
`event_remove` with an omitted ID now resolves through the SAME single referent
resolver snooze uses (extracted `resolve_referent/3`, no second query) and
cancels the referent's parent event, returning the full canonical event plus
the anchoring `source_reminder_id`; shared error sentences generalized to name
both verbs; the explicit-ID path is byte-for-byte unchanged and the trust
invariant covers the referent path structurally (an empty-args `execute` IS the
referent path). The runtime prompt deliberately gained no cancel routing line
(a steering change silently re-routes existing eval tasks; the tool description
carries the affordance). E2E: `benchmark/suites/temporal_events.yaml`
(risk `isolated_mutation`, 5 scenarios / 11 cases / 17 turns, dry-run
validated) covers capture, the job/event boundary, clarification, and the full
list/update/remove lifecycle; reminder DELIVERY and the implicit
"snooze/cancel that" resolutions are deliberately not e2e-automatable (they
need a reminder actually delivered into the caller's conversation, which an
ask→grade loop cannot arrange) and stay pinned by the hermetic ExUnit tier.
`benchmark/bin/seed_capability_home.py` now pre-grants the two setup decisions
`event_store` hard-requires — `[fermix_core.jobs] default_delivery_target`
(credential-less platform: an eval-window delivery terminates first-try as
adapter_unavailable without touching the network) and
`[fermix_core.personalization]` — closing the fresh-eval-home
zero-score trap before it ever fired.

Same-day follow-up: the multi-source agenda posture (§20 deferred-sync bullet
carries the owner's rationale). `event_list`'s description now scopes itself to
Fermix-stored events; the google-calendar plugin skill points back the other
way; two runtime-contract lines make agenda questions consult every available
calendar surface with source attribution and make capture ask before storing a
date a connected calendar likely already tracks. Instruction-level by design
(no aggregator tool: it would wrap dynamically-registered plugin tools, mix
policy classes in one call, and blur which source answered). The read
carve-out was then taken the same day (owner decision, morning-brief cron
architecture confirmed): `event_list` gates on the new
`Access.operator_read_turn?/1` — attended OR operator-created scheduled run —
with the four mutating tools unchanged, the invariant test pinning the exact
asymmetry, and a positive scheduled-run execution test. The owner accepted the
job-delivery-target corollary (§12.1).

**2026-08-04 addendum — owner-inbox derivation (fresh-install/upgrade gap).**
A live trace (owner said "My birthday is March 16th", model routed correctly
to `event_store`, the tool refused on the absent target, the model salvaged to
memory transparently) exposed that neither a fresh install nor `brew upgrade`
ever writes `default_delivery_target` — and that M26 had already solved the
same question by deriving the owner's inbox from channel config. Owner
decision: unify. `FermixCore.Delivery.OwnerInbox` is now the one resolver
(configured target → derived owner inbox → `:no_delivery_target`); M26
proposals delegate to it; the temporal Registry keeps its §11.1 rung-one
validation verbatim and borrows `derived_candidates/1` as rung two, refusing
hostile modes before derivation and skipping candidates that fail validation.
`delivery.source` (`configured`/`derived`) rides every acceptance/rebind
payload — provenance is visible, never persisted (no schema change).
Derivation reads only an explicit `owner_user_id`, only on
telegram/signal/whatsapp. The read carve-out and this change together close
the two decisions of 2026-08-03/04; a matching Known-Pitfalls entry in
CLAUDE.md makes the install/upgrade zero-config test a standing requirement
for every future feature. Also fixed in the same pass: the in-flight-send
test's hardcoded claim instant (a date bomb armed the moment UTC rolled past
its author's calendar) now derives the claim time from the created reminder.

**2026-08-04 addendum 2 — event-identity floors (same-name/different-date).**
Owner testing surfaced the question live: "my birthday is March 16" then
"…March 17" hours later — the model handled it correctly (searched, updated in
place, revision 2, old reminders cancelled), but the same flow would wrongly
merge two people sharing a name, and nothing made the delta visible. Owner
decision: the same-or-different question is model judgment steered at TOOL
scope only (the shared runtime prompt is deliberately untouched — routing
between tools lives in the contract, conduct within a tool lives in the tool),
backstopped by three deterministic floors: `identity_conflict` now carries the
existing event from the Repo transaction outward and its rendered refusal
names the stored event, quotes its stored date (`every MM-DD` / ISO local
date, never an invented year), and instructs the model to ask the owner
same-or-different (update vs a distinguishing title) — the bare atom shape is
gone; `event_update` results carry `previous` (exactly the user-facing fields
that changed, so every rewrite acks was→now); `event_store` results carry
`similar_events` (active same-kind events, capped at 5, `[]` on the
idempotent-existing path; a post-commit read failure logs and returns `[]`
rather than un-telling a committed write). One principle-only conduct sentence
on each of `event_store`/`event_update` descriptions; no example strings
anywhere. Pinned by a three-turn eval case
(`clarify_dont_guess/same_name_different_date`: ask before writing, then two
coexisting birthdays under distinct titles) — behavior-graded, so the
tool-scoped steering is measured rather than assumed. Also: a
`behavioral-isolated` make target now runs every isolated_mutation behavioral
suite against the disposable eval daemon (auto-enrolling by existence; the
nightly `regression` tag-sweep correctly never includes mutation suites, and
the capability tier is a different rail — behavioral suites do not belong in
`make capability-auto`). Deliberately parked, needs no design change unless
revisited: a personal-touch line in delivered reminders (would amend §13's
deterministic-render contract; the stored `description` field is the natural
carrier if ever wanted).

**2026-08-05 addendum — `confirm_overwrite` (owner decision after live Sara
test).** A bare restatement 37 seconds after storing "Sara's birthday" was
silently rewritten Dec 10 → Aug 5 on the pre-floors build; the owner ruled
that a date rewrite must always pass a prompt. Implemented as the second
instance of the shipped `confirm_past_boundary` pattern: `event_update` with a
`when` key requires `confirm_overwrite: true` (presence-based, control
argument stripped before any field handling); without it the guard refuses
BEFORE validation or writes with `{:error, {:overwrite_unconfirmed,
existing}}`, whose sentence quotes the stored title and date and instructs the
ask (overwrite, or keep both as separate events). Attestation semantics: the
owner explicitly directed this date change — stating their own new date or
asking to move a named event counts — or has just answered the overwrite
question; the flag is self-attested (a conscious checkpoint, not
cryptographic proof a human spoke — the same honesty note as
`confirm_past_boundary`), and the eval rubric fails any unconfirmed-feeling
overwrite so flag-reflex decay is measured. Title/kind/timezone-only patches
and rebinds need no flag. Watch-item accepted deliberately: the
`manage_roundtrip` eval turns ("move it to 2pm") now demand first-attempt
attestation — a guarded refusal there fails the turn's `no_tool_errors` gate
by design (it would mean the steering failed on the explicit-direction case);
if live runs show reflexive first-call misses instead, relax the two turns on
evidence, not preemptively. ~A dozen lines of production code; no state,
schema, config, telemetry, or path changes; scheduler/delivery/snooze/cancel
untouched.

**2026-08-06 addendum — the relative clause floored away an hour.** First
organic 24h-before delivery (13ms of scheduler latency) rendered "(in 23
hours)"; the same floor would have OMITTED tomorrow's "(in 1 hour)" clause
entirely (3599.987s < the 3600 branch). §13's renderer now rounds half-down to
the displayed unit — latency can never shave the number, "in 24 hours" and
"in 1 hour" render as humans expect, a retry at exactly 30 minutes still drops
the clause (the pinned mislead rule), and timed events under 48 hours display
in hours rather than collapsing to "in 1 day" at the 24h boundary. Found by
the owner reading their own reminder — the demo-week observation loop doing
its job.

**2026-08-05 addendum 2 — the boolean lost to reality within hours;
`owner_direction` replaces it.** First live trial: the model passed
`confirm_overwrite: true` on its FIRST call for a bare "Saras birthday is on
August 30th" — reflexive self-attestation, contextually explainable (the
thread had corrected Sara twice) and exactly the decay mode the addendum above
predicted. Owner reviewed three escalation options (accept judgment /
turn-boundary token / approve-deny buttons riding the shipped ProposalButton
pattern — which the owner correctly spotted as the option-3 UX already built)
and chose a fourth, better one: keep the model as the only
language-understander (no regex, no lexical validation, ever — typos and
phrasing variance make content-parsing a dead end) but make the attestation
impossible to fill on autopilot. `confirm_overwrite: true` became
`owner_direction: "<near-verbatim excerpt of the owner's directing words>"` —
the guard checks presence, trim-emptiness, and a 240-byte cap (house pattern;
overlong refuses with "quote the directing clause", never silently truncates)
and NEVER inspects content. A boolean is boilerplate; a verbatim quote forces
retrieval of the owner's actual sentence at the decision point, and a bare
restatement offers no directing words to quote. The field is a control
argument: stripped before merge/target/Repo (strip-proof tested), so it lives
only in the tool-call span — trace-auditable per overwrite, and the eval judge
now checks span evidence (the quoted direction must be the owner's directing
words, not a restatement; span input demonstrably reaches the judge, with a
noted watch on the evidence byte-caps truncating many-span turns). The
`event_update` example was rewritten to a non-date edit so the tool's own
example no longer demonstrates a shape its guard refuses (and no example
direction string exists anywhere, per the owner's rule). Approve/deny buttons
remain the documented escalation if live `behavioral-isolated` runs show quote
attestation also decaying. The `manage_roundtrip` first-attempt watch-item
stands, now easier to satisfy: the directing words are literally the turn
text.
