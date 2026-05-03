# Milestone 4.11: Scheduled Agents — Cron Jobs, Persistent Memory Sources, and Isolated Runs

**Status:** Draft
**Date:** 2026-04-29
**Author:** Sujeeth / Aira
**Depends on:** M4.8 (`fermix` daemon), M4.9 (`CapabilityRegistry`, provider adapters, capability policy metadata), M4.10 (Codex parity — scheduled jobs need full tool calls on the user's chosen provider), M4 memory/resource store
**References:** `/Users/sujshe/projects/hermes-agent/cron/scheduler.py`, `/Users/sujshe/projects/hermes-agent/cron/jobs.py`, `apps/fermix_core/lib/fermix_core/agents/agent_server.ex`, `apps/fermix_core/lib/fermix_core/memory/*`

---

## 1. Problem / Goal

Fermix needs a first-class way to run isolated background tasks on a schedule: daily digests, repository watchers, deployment checks, "remind me later" tasks, and long-running monitors that wake up periodically. These are related to sub-agents, but they are not the same thing.

A sub-agent is spawned by the main agent for one delegated task. A scheduled agent is owned by the daemon and triggered by time or manual run. It may exist forever as a configured job, but each LLM execution should still be a bounded, isolated run.

**Goal of M4.11:** add scheduled agent jobs that can be created by the main agent, stored durably, executed by the daemon, written into source-aware memory, and made discoverable to the main agent without sharing the live main chat context.

After this milestone:

1. The main agent can create, list, pause, resume, update, remove, and manually trigger scheduled jobs through capabilities.
2. Each job run gets its own isolated LLM session (`cron_<job_id>_<timestamp>`), not the main agent's active conversation.
3. Job memory is written under a distinct memory source (`job:<job_id>`) with human-readable metadata so the main agent can tell where recalled memory came from.
4. The main agent can inspect a bounded catalog of scheduled jobs and memory sources before recalling job memory.
5. Job execution is asynchronous from user chat and daemon channels; scheduling a job is fast, running a job is supervised in the background.
6. Latency is bounded and explicit: due jobs should start within the scheduler tick/nearest-timer window, and user-facing job CRUD should not wait for LLM execution.

**Non-goal:** a forever-running unbounded LLM loop. The daemon and scheduler are long-lived; each LLM run is bounded by `max_iterations`, capability policy, timeout/inactivity policy, and a run record.

---

## 2. Reference: Hermes Cron

Hermes' cron implementation is the closest reference.

Adopt:

- Jobs are durable records, not transient prompts (`~/.hermes/cron/jobs.json` in Hermes).
- Outputs are saved per job/run (`~/.hermes/cron/output/<job_id>/...`).
- The gateway/daemon ticks the scheduler in the background.
- A lock prevents overlapping scheduler ticks.
- Each job run creates a fresh agent session id (`cron_<job_id>_<timestamp>`).
- Recurring jobs advance `next_run_at` before execution so a crash mid-run does not refire the same occurrence in a loop.
- Job prompts include scheduler-specific guidance: final response is delivered by the scheduler; the agent should not self-deliver.
- `[SILENT]` suppresses delivery when there is nothing new to report.
- Timeouts are inactivity-based where possible, not pure wall-clock.

Do not copy directly:

- Hermes stores jobs in JSON. Fermix should use the existing SQLite/resource store pattern so job metadata, runs, and memory provenance are queryable.
- Hermes loads skills into cron prompt context. Fermix should use M4.9 capabilities/skills: selected skill as fixed system prompt, capability registry for tools, source-aware memory for continuity.
- Hermes disables memory for cron to avoid corrupting user representation. Fermix should allow job memory, but under a separate source id and explicit visibility rules.

---

## 3. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| Job registry | P0 | New | Durable `scheduled_jobs` records with schedule, task, capability policy, delivery, memory source, and status metadata. |
| Job scheduler | P0 | New | OTP GenServer that tracks next due job, ticks/reconciles periodically, and starts due jobs asynchronously. |
| Job runner | P0 | New | Supervised worker that creates an isolated session and runs one bounded `AgentLoop` execution for one job occurrence. |
| Main-agent job capabilities | P0 | New | `schedule_job`, `list_jobs`, `pause_job`, `resume_job`, `update_job`, `remove_job`, `run_job_now`, `job_runs`. |
| Memory source catalog | P0 | New | Durable metadata for `main`, `job:<id>`, and future source types so memory recall has semantic provenance. |
| Source-aware memory recall | P0 | New | Memory writes/read results include `source_id`, `source_name`, `source_type`, `source_description`, `session_id`, and `run_id`. |
| Scheduler-owned delivery | P0 | New | Job final output is saved first, then delivered by scheduler/channel layer if configured. Job agents should not call messaging tools directly by default. |
| Sync/async contract | P0 | New | CRUD is synchronous and fast; execution, memory extraction, and delivery are asynchronous/supervised. |
| Latency targets | P0 | New | Explicit targets for CRUD, due-job start jitter, scheduler recovery, run status updates, memory visibility, and delivery. |
| Observability | P1 | New | Telemetry for job created/due/started/completed/failed/delivered/skipped, with run ids and source ids. |

### Non-Goals

| Feature | Reason | When |
|---------|--------|------|
| Shared main-agent context | Scheduled jobs must be reproducible and isolated. They can read shared memory by config, but they do not inherit the live main chat. | Avoid |
| Unbounded continuous LLM loop | Expensive and unsafe. Watchers may run 24/7, but each LLM turn is a bounded job run. | Avoid |
| Distributed scheduler cluster | Single-user daemon first. SQLite row locks / per-job locks are enough. | Later |
| Complex calendar UI | CLI/capability control first. LiveView dashboard can follow. | M10/M6 |
| Human approval UX | M10 governance owns interactive approval. M4.11 uses static capability policy and explicit job config. | M10 |

---

## 4. Core Design

### 4.1 Runtime Shape

```
Main Agent
  │
  ├── schedule_job(...) capability
  │     ├── validate schedule/policy/delivery
  │     ├── insert scheduled_jobs
  │     ├── insert memory_sources source_id="job:<job_id>"
  │     └── return immediately with job id + next_run_at
  │
JobScheduler (daemon process)
  │
  ├── wakes by nearest due timer + periodic reconciliation tick
  ├── loads due jobs
  ├── claims each job with a per-job lock / status transition
  ├── advances next_run_at before recurring execution
  └── starts JobRunner asynchronously
        │
        ├── insert job_runs(status="running")
        ├── build isolated prompt/session
        ├── run bounded AgentLoop
        ├── save output/artifact
        ├── write memory entries with source_id="job:<job_id>"
        ├── update job_runs + scheduled_jobs + memory_sources
        └── deliver final result asynchronously if configured
```

### 4.2 Isolation Contract

Every scheduled job run has its own LLM session by default:

```text
session_id = cron_<job_id>_<yyyymmdd_hhmmss>
agent_id   = job:<job_id>
source_id  = job:<job_id>
platform   = cron
```

It does not receive:

- main chat message history
- main agent provider continuation state
- current Telegram/Discord conversation context
- main agent ephemeral scratch state

It may receive, by explicit job config:

- selected skill prompt or job system prompt
- previous summary/checkpoint from `job:<job_id>`
- shared/global memory scopes
- selected memory sources
- capability registry filtered by job policy
- delivery target metadata

### 4.3 Session Modes

| Mode | Default | Meaning |
|------|---------|---------|
| `isolated` | yes | New LLM session every run. Reads only configured memory scopes. |
| `threaded_job` | no | New run sees a bounded summary/checkpoint of prior runs for the same job. |
| `origin_reply` | no | Execution is still isolated, but delivery goes back to the chat/channel where the job was created. |

Do not add `main_context` mode in v1. If "run in this chat thread" is needed later, make it an explicit high-friction feature with clear context budget and privacy warnings.

---

## 5. Data Model

Use SQLite/Ecto tables or the existing resource registry equivalent. The exact persistence layer can follow the current memory store conventions, but the logical records should be stable.

### 5.1 `scheduled_jobs`

One row per configured job.

```elixir
%ScheduledJob{
  id: "daily_digest_01",
  name: "Daily Research Digest",
  description: "Summarizes overnight AI infrastructure news every morning.",

  schedule_kind: :cron | :interval | :once,
  schedule_expr: "0 8 * * *",
  timezone: "America/New_York",
  next_run_at: ~U[2026-04-30 12:00:00Z],
  expires_at: nil | DateTime.t(),

  task_prompt: "Summarize overnight AI infrastructure news and highlight what matters.",
  skill_name: "research-digest",
  session_mode: :isolated,

  provider: :openai,
  model: "gpt-5.4-mini",
  max_iterations: 40,
  timeout_seconds: 900,
  inactivity_timeout_seconds: 600,

  capability_policy: [:read_only, :network],
  allowed_tools: ["browser", "memory_recall", "memory_store"],

  memory_source_id: "job:daily_digest_01",
  memory_read_scopes: ["job:self"],
  memory_write_scope: "job:self",
  main_visible?: true,

  delivery_mode: :origin | :channel | :local | :none,
  delivery_target: %{platform: "telegram", chat_id: "..."},
  silent_marker: "[SILENT]",

  enabled?: true,
  state: :scheduled | :paused | :running | :completed | :disabled,
  last_run_at: nil,
  last_status: nil,
  last_error: nil,

  created_by_agent_id: "main",
  created_by_session_id: "telegram_...",
  created_at: DateTime.t(),
  updated_at: DateTime.t()
}
```

### 5.2 `job_runs`

One row per occurrence.

```elixir
%JobRun{
  id: "run_...",
  job_id: "daily_digest_01",
  session_id: "cron_daily_digest_01_20260430_080000",

  trigger: :schedule | :manual | :retry | :catchup,
  status: :queued | :running | :ok | :error | :cancelled | :timeout,
  claimed_at: DateTime.t(),
  started_at: DateTime.t(),
  completed_at: DateTime.t(),

  prompt_snapshot: "...",
  job_config_snapshot: %{},
  capability_policy_snapshot: %{},

  output_ref: "job_runs/run_.../output.md",
  final_response: "...",
  error: nil,
  delivery_status: :pending | :sent | :skipped | :failed | :none,
  delivery_error: nil,

  iterations: 12,
  token_usage: %{prompt: 1000, completion: 500, total: 1500},
  latency_ms: %{queued: 120, run: 45_000, memory: 300, delivery: 900}
}
```

### 5.3 `memory_sources`

Catalog entry visible to the main agent.

```elixir
%MemorySource{
  id: "job:daily_digest_01",
  source_type: :scheduled_job,
  name: "Daily Research Digest",
  description: "Runs every morning and summarizes overnight AI infrastructure news.",
  owner_agent_id: "main",
  visibility: :main_visible,

  schedule_summary: "daily at 08:00 America/New_York",
  status: :enabled,
  last_run_at: DateTime.t(),
  last_status: :ok,

  memory_scope: "job:daily_digest_01",
  output_scope: "cron:daily_digest_01",
  metadata: %{job_id: "daily_digest_01"}
}
```

### 5.4 `memory_entries`

Existing memory entries need source provenance fields if they do not already exist.

```elixir
%MemoryEntry{
  id: "...",
  owner_id: "default",
  agent_id: "job:daily_digest_01",
  source_id: "job:daily_digest_01",
  source_type: :scheduled_job,
  source_name: "Daily Research Digest",
  source_description: "Runs every morning and summarizes overnight AI infrastructure news.",
  session_id: "cron_daily_digest_01_20260430_080000",
  run_id: "run_...",
  content: "...",
  tags: ["cron", "daily_digest"],
  created_at: DateTime.t()
}
```

Memory recall results must include the source metadata. The model should never see only `job:abc123` without a name and description.

---

## 6. Write Timing and Lifecycle

### 6.1 When the Main Agent Schedules a Job

Synchronous path. The capability call should return quickly.

1. Validate schedule syntax, timezone, task prompt, delivery target, policy, and allowed tools.
2. Normalize schedule to `schedule_kind`, `schedule_expr`, `timezone`, `next_run_at`.
3. Insert `scheduled_jobs`.
4. Insert/update `memory_sources` with `source_id = "job:<job_id>"`.
5. Emit `[:fermix, :job, :created]`.
6. Return `{job_id, name, next_run_at, memory_source_id}` to the main agent.

Do not run the LLM during job creation unless the user explicitly asked for `run_now: true`.

### 6.2 When the Scheduler Sees a Due Job

Synchronous inside scheduler only until it hands off to a runner.

1. Acquire scheduler tick lock or per-job claim.
2. Load due jobs.
3. If `expires_at` has passed, mark the job and memory source as expired without starting a run.
4. For recurring jobs, advance `next_run_at` before starting the run.
5. Insert `job_runs(status: :queued)` or update a pre-created run.
6. Start `JobRunner` under `JobRunnerSupervisor`.
7. Return scheduler GenServer to idle immediately.

The scheduler process must not block on LLM execution.

### 6.3 When JobRunner Starts

Asynchronous supervised execution.

1. Transition `job_runs.status` from `:queued` to `:running`.
2. Snapshot job config and prompt into `job_runs`.
3. Build system prompt:
   - Fermix cron runner guidance
   - selected skill system prompt, if configured
   - explicit job instructions
   - bounded memory source catalog, if useful
4. Build user/task prompt from `task_prompt` and optional job context.
5. Run `AgentLoop` with isolated `session_id`.

### 6.4 During the Run

Asynchronous.

- AgentLoop executes capabilities synchronously within its own run.
- Tool calls may be async internally if the tool already supports that, but from the AgentLoop perspective each tool result is awaited.
- Trace/tool events write as they happen.
- Memory writes from tools are tagged with `source_id`, `run_id`, and `session_id`.
- Inactivity tracking updates on every provider response, stream delta, tool start, tool finish, and memory write.

### 6.5 On Success

Mostly synchronous finalization. Delivery is attempted after output and status
are durable, is bounded by `delivery_timeout_ms`, and is tracked separately from
LLM run status.

1. Save full output artifact.
2. Update `job_runs(status: :ok, final_response, output_ref, token_usage, iterations)`.
3. Write/update durable job summary memory under `source_id = "job:<job_id>"`.
4. Update `scheduled_jobs.last_run_at`, `last_status`, `last_error`.
5. Update `memory_sources.last_run_at`, `last_status`.
6. If trimmed final response equals `[SILENT]`, mark delivery `:skipped`.
7. Otherwise attempt configured delivery and record delivery status.

The run should be considered complete once output and status are durable. Delivery failure is tracked separately and should not turn a successful LLM run into a failed run.

### 6.6 On Failure or Timeout

Synchronous finalization.

1. Save failure artifact with prompt snapshot and error.
2. Update `job_runs(status: :error | :timeout, error)`.
3. Update `scheduled_jobs.last_status`, `last_error`.
4. Update `memory_sources.last_status`.
5. Attempt failure notification if configured.

For recurring jobs, do not immediately retry by default. The next occurrence should be controlled by schedule unless an explicit retry policy exists.

---

## 7. Sync vs Async Contract

### Synchronous

These operations should complete before replying to the caller:

| Operation | Why |
|-----------|-----|
| `schedule_job` validation + insert | User needs a durable job id and next run time. |
| `update_job` validation + update | Prevent half-applied schedule/policy changes. |
| `pause_job` / `resume_job` | Must be immediately reflected in scheduler decisions. |
| `remove_job` | Must prevent future runs before returning. |
| `list_jobs` / `job_runs` reads | User-facing metadata reads should be fast and deterministic. |
| `memory_sources_list` | Main agent needs reliable source catalog before recall. |
| Run status final write | Avoid losing outcome if daemon stops after execution. |

### Asynchronous

These operations must not block main chat, channel polling, daemon accept loops, or scheduler GenServer calls:

| Operation | Why |
|-----------|-----|
| Scheduled job execution | LLM/tool work can take minutes. |
| Manual `run_job_now` execution | Should enqueue a run and return run id by default. |
| Delivery to Telegram/Discord/etc. | Channel APIs can be slow or unavailable. |
| Memory extraction/summarization from long output | Can require LLM or embeddings. |
| Embedding writes | External calls or CPU-bound work should not block run finalization if output is already durable. |
| Catch-up/reconciliation scan | Should be bounded and yield to the scheduler loop. |

### Optional Blocking Mode

For CLI/debugging only:

```text
fermix jobs run <job_id> --wait
```

This may wait for the run to finish, but it should be implemented as polling/subscribing to `job_runs`, not by running the job inline in the CLI process.

---

## 8. Latency Targets

Latency needs to be designed, not accidental.

| Path | Target | Notes |
|------|--------|-------|
| `schedule_job` capability reply | p95 < 300ms local DB write | No LLM call. |
| `list_jobs` / `memory_sources_list` | p95 < 200ms | Bounded results, indexed by owner/status. |
| Due job start jitter | p95 < 5s when daemon is healthy | Use nearest-job timer, not only a 60s poll, for low-latency one-shots. |
| Reconciliation tick | every 60s | Safety net for missed timers, clock changes, DB edits, daemon resume. |
| Manual `run_job_now` enqueue | p95 < 300ms | Returns `run_id`; execution is async. |
| Run status visible after start | < 1s | `job_runs.status = running` before AgentLoop call. |
| Output durable after AgentLoop returns | < 1s | Write artifact + run status synchronously. |
| Memory source status update | < 1s after run finalization | Main agent can see latest job health quickly. |
| Memory recall visibility | < 5s for summary memory | Full extraction/embedding can lag, but a run summary should be immediately queryable. |
| Delivery after success | best effort p95 < 5s | Failure tracked separately from run success; channel calls have a hard delivery timeout so runners cannot wedge after a completed AgentLoop run. |

Scheduler design:

- Keep a nearest-job timer with `Process.send_after/3` for the next `next_run_at`.
- Also run a reconciliation tick every 60 seconds.
- On any job create/update/pause/resume/remove, notify scheduler to recompute the nearest timer.
- If the daemon was down, recurring jobs outside their grace window fast-forward to next future run rather than bursting missed runs.

---

## 9. Prompt Contract

Every scheduled run gets explicit cron guidance:

```text
You are running as a scheduled Fermix job.

Your final response will be saved and delivered by Fermix if delivery is configured.
Do not call messaging tools to deliver your own result unless the job explicitly allows it.

If there is genuinely nothing new to report, respond exactly with [SILENT].
Do not combine [SILENT] with other text.
```

If a skill is configured:

```text
[skill system prompt]

---

You are running as the "<skill_name>" skill for scheduled job "<job_name>".
```

The job prompt should include a bounded source catalog only when the job can read memory. The main agent gets its own bounded source catalog for job memories so it can distinguish:

- its own prior memory
- scheduled job memory
- future sub-agent/source memory

---

## 10. Main Agent Access to Job Memory

The main agent should have two tools/surfaces:

1. `memory_sources_list`
2. source-aware `memory_recall`

Example source catalog returned to the main agent:

```elixir
[
  %{
    source_id: "main",
    source_type: :main_agent,
    name: "Main Agent",
    description: "Your own prior conversations and durable memory."
  },
  %{
    source_id: "job:daily_digest_01",
    source_type: :scheduled_job,
    name: "Daily Research Digest",
    description: "Runs every morning and summarizes overnight AI infrastructure news.",
    schedule_summary: "daily at 08:00 America/New_York",
    last_run_at: "2026-04-30T12:00:00Z",
    last_status: "ok"
  }
]
```

Example memory recall result:

```elixir
%{
  text: "The Daily Research Digest found three notable AI infrastructure updates...",
  source_id: "job:daily_digest_01",
  source_name: "Daily Research Digest",
  source_type: :scheduled_job,
  source_description: "Runs every morning and summarizes overnight AI infrastructure news.",
  session_id: "cron_daily_digest_01_20260430_080000",
  run_id: "run_...",
  created_at: "2026-04-30T12:04:10Z"
}
```

Rule: no memory recall result should expose only an opaque `source_id`. The model gets source name/type/description every time.

---

## 11. Capability Policy

Scheduled jobs are headless automation. Their default capability set should be narrower than the root main agent.

Defaults:

| Job source | Default policy |
|------------|----------------|
| Created by main agent with user confirmation | `[:read_only, :network]` unless task requires more |
| Manually configured local job | local default, can include `:read_write` / `:exec` if explicit |
| Third-party/plugin-created job | read-only only, no external API writes by default |

Messaging tools are disabled by default in job runs. Scheduler-owned delivery handles the final response. If a job truly needs messaging as part of its task, it must explicitly opt in.

Cron management capabilities are disabled inside cron runs by default. A job should not be able to create an unbounded tree of future jobs without explicit policy.

---

## 12. Concurrency, Locking, and Failure Semantics

Rules:

- One scheduler tick active at a time.
- One active run per job by default.
- Job-level `concurrency` controls overlap:
  - `skip`: if previous run active, skip this occurrence
  - `queue`: run after current finishes
  - `parallel`: allowed only for explicitly safe jobs
- Recurring jobs advance `next_run_at` before execution.
- One-shot jobs can retry on restart until they either run or pass a configurable grace window.
- Delivery failure does not mark LLM execution failed.
- Memory extraction failure does not erase run output; mark memory status separately.

Default:

```toml
concurrency = "skip"
catch_up = "grace"
catch_up_grace_seconds = 7200
```

---

## 13. Public Surfaces

### CLI

```sh
fermix jobs list
fermix jobs add --schedule "0 8 * * *" --name "Daily Digest" --task "..."
fermix jobs pause <job_id>
fermix jobs resume <job_id>
fermix jobs remove <job_id>
fermix jobs run <job_id>
fermix jobs runs <job_id>
fermix jobs show <job_id>
```

### Capabilities

```text
schedule_job(schedule, task, name?, description?, skill?, delivery?, policy?, expires_at?, timeout_seconds?, inactivity_timeout_seconds?)
list_jobs(status?)
update_job(job_id, patch)
pause_job(job_id, reason?)
resume_job(job_id)
remove_job(job_id)
run_job_now(job_id)
job_runs(job_id, limit?)
memory_sources_list()
```

### Config Example

```toml
[fermix_core.jobs]
# Cron-specific default delivery. New jobs created without delivery arguments
# resolve this into their own job row at creation time.
default_delivery_mode = "channel"

[fermix_core.jobs.default_delivery_target]
platform = "telegram"
chat_id = "8217352118"

[jobs.daily_research_digest]
name = "Daily Research Digest"
description = "Summarizes overnight AI infrastructure news."
schedule = "0 8 * * *"
timezone = "America/New_York"
# Optional ISO8601 datetime. When reached, Fermix marks the job expired
# without asking the job agent to remove itself.
expires_at = "2026-05-02T16:00:00Z"
task = "Summarize overnight AI infrastructure news and highlight what matters."
skill = "research-digest"

session_mode = "isolated"
history = "job"
concurrency = "skip"

provider = "openai"
model = "gpt-5.4-mini"
max_iterations = 40
timeout_seconds = 900
inactivity_timeout_seconds = 600
# If omitted, Fermix still applies a daemon-level wall-clock watchdog.

allowed_tools = ["browser", "memory_recall", "memory_store"]
policy = ["read_only", "network"]

memory_read_scopes = ["job:self"]
memory_write_scope = "job:self"
main_visible = true

# Optional per-job override. If omitted, the cron default above is used.
delivery = "channel"
silent_marker = "[SILENT]"
```

Delivery precedence is explicit job settings first, then the cron default in
`[fermix_core.jobs]`, then no delivery. Defaults are resolved at job creation so
editing the default later does not silently retarget existing jobs.

---

## 14. Implementation Stages

### Stage 1 — Job Registry and Source Catalog

- Add `ScheduledJob`, `JobRun`, and `MemorySource` schemas/tables.
- Add CRUD APIs.
- Add source-aware memory metadata fields if missing.
- Add tests for schedule parsing, source creation, and provenance.

Ship gate: main agent can create/list/pause/resume/remove jobs; no execution yet.

### Stage 2 — Scheduler and Runner Skeleton

- Add `FermixCore.Jobs.Scheduler` GenServer.
- Add `FermixCore.Jobs.RunnerSupervisor`.
- Add nearest-job timer + 60s reconciliation tick.
- Add per-job claim/lock.
- Add run records with queued/running/final status.

Ship gate: a fake runner can execute due jobs without blocking scheduler.

### Stage 3 — AgentLoop Integration

- Runner builds isolated session and cron prompt.
- Runner invokes `AgentLoop` with job capability policy.
- Outputs saved per run.
- Inactivity timeout and max iterations enforced.

Ship gate: one scheduled job can run a real LLM/tool loop in isolation.

### Stage 4 — Memory Provenance

- Job writes run summary under `source_id = job:<job_id>`.
- Main agent can list memory sources.
- Memory recall returns source metadata.
- Job can read its own prior job memory when configured.

Ship gate: main agent can answer "what did my daily digest find?" with provenance.

### Stage 5 — Delivery

- Scheduler-owned delivery to origin/channel/local.
- Cron default delivery target resolved at job creation.
- `[SILENT]` suppression.
- Delivery status tracked separately from run status.

Ship gate: scheduled job can send result to configured channel without calling messaging tools itself.

### Stage 6 — CLI and Operational Polish

- `fermix jobs ...` CLI.
- Telemetry and logs.
- Manual run with async default and `--wait` debug option.
- Crash/restart recovery tests.

Ship gate: daemon restart does not duplicate recurring runs; job status and outputs remain inspectable.

---

## 15. Test Matrix

- Schedule parsing: cron, interval, once, timezone, invalid syntax.
- Job CRUD: create, update, pause, resume, remove, list.
- Source catalog: source created with job, source updated after run, source visible to main.
- Scheduler latency: due job starts within timer target in tests with controlled clock.
- Reconciliation: missed timer recovered by periodic tick.
- Crash semantics: recurring job advanced before run; no duplicate after simulated crash.
- One-shot semantics: retry on restart within grace, complete once.
- Concurrency: skip/queue/parallel policies.
- Agent isolation: job run does not include main chat history.
- Capability policy: cron management and messaging disabled by default.
- Memory provenance: entries include source metadata; recall returns name/type/description.
- Delivery: success, `[SILENT]`, delivery failure, local-only, default target precedence.
- Timeout: inactivity timeout fires; active tool stream does not falsely timeout.

---

## 16. Success Criteria

- [ ] Main agent can schedule a job and immediately receive a durable `job_id` and `next_run_at`.
- [ ] Scheduler starts due jobs asynchronously without blocking channel polling or daemon socket work.
- [ ] Every job run has a unique isolated session id and run record.
- [ ] Job output is durable before delivery is attempted.
- [ ] Main agent can list job memory sources with useful descriptions.
- [ ] Memory recall results identify whether they came from main memory or a scheduled job.
- [ ] Recurring jobs do not burst missed runs after daemon downtime.
- [ ] One-shot jobs run once and do not duplicate after success.
- [ ] Latency targets in §8 are covered by tests or telemetry assertions.
- [ ] `mix test`, `mix format --check-formatted`, and relevant integration tests are green.
