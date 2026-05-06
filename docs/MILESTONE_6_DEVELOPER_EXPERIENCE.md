# Milestone 6: Developer Experience

**Status:** Design ready for implementation

**Goal:** Replace the generated Phoenix landing page with a local operator console and matching CLI query surface for observing, debugging, and lightly managing Fermix while it runs.

M6 is not a new runtime foundation. The scheduler, durable jobs, setup store, health checks, release CLI, trace writer, and SQLite memory store already exist in earlier milestones. M6 makes those systems visible, searchable, and operable from Phoenix LiveView and CLI commands.

---

## 1. Current State

Fermix already has the backend pieces that M6 should consume:

- `FermixCore.Setup.ConfigStore` owns `FERMIX_HOME`, persisted `config.toml`, workspace paths, logs, traces, skills, journals, and memory paths.
- `FermixCore.Health` and `FermixCore.Readiness` expose readiness, provider, channel, config, and memory process state.
- `FermixCore.Agents.MainAgent` handles normalized channel messages and keeps in-flight conversation state internally.
- `FermixCore.Agents.AgentSupervisor.list_agents/1` returns dynamic skill-worker status.
- `FermixCore.Jobs.Registry`, `FermixCore.Jobs.Scheduler`, and `FermixCore.Jobs.Runner` own durable scheduled jobs, job runs, job output, and job memory sources.
- `FermixCore.Memory.Repo` already supports message, memory, memory-source, scheduled-job, job-run, and resource queries.
- `FermixCore.Capabilities.Registry` can list built-in, skill, and MCP capabilities with policy filtering.
- `FermixCore.Trace` writes structured JSONL trace files under `~/.fermix/traces/YYYY-MM-DD/`.
- `Fermix.CLI` already dispatches `setup`, `run`, `service`, `start`, `stop`, `restart`, `status`, `logs`, `upgrade`, `doctor`, and `version`.
- `FermixWebWeb.Router` currently exposes only `/`, `/setup`, `/health`, `/health/live`, `/health/ready`, and channel webhooks.
- `FermixWebWeb.SetupLive` is read-only setup status, not a real setup form or dashboard.
- `apps/fermix_web` already uses Phoenix LiveView, Tailwind 4, daisyUI, Heroicons, Bandit, and LiveReload.

Reference takeaways:

- Hermes Agent's web UI is useful as an endpoint inventory: status, sessions, config, logs, cron, skills, tools, and usage endpoints. Fermix should not copy the FastAPI/SPA split because Phoenix LiveView can keep state server-side.
- Hermes cron jobs prove that job output, delivery status, and failure reasons are first-class operator data, not hidden log trivia.
- RustyClaw's React dashboard gives a good information hierarchy: health cards, active channels, scheduled work, memory search, logs, config, and doctor views. Fermix should implement those as LiveViews over core APIs instead of adding a separate frontend app.

---

## 2. Roadmap Feature Mapping

| Roadmap item | M6 treatment |
| --- | --- |
| LiveView dashboard | Primary deliverable. Replace `/` with an operator dashboard. |
| Agents LiveView | Add main-agent, skill-worker, capability, and reload visibility. |
| Memory LiveView | Add source-aware memory search, source catalog, and resource revision links. |
| Logs LiveView | Add bounded log tail/follow with filters. |
| Phoenix Channels | Use LiveView/PubSub for local operator chat first. Do not add a custom external chat channel until a non-LiveView client needs it. |
| Cron scheduler | Treat as already delivered by M4.11; M6 adds UI and CLI controls over it. |
| CLI (`fermix` command) | Extend the existing release CLI with dashboard-equivalent commands. |
| Config migration tool | Add dry-run RustyClaw config import after dashboard basics ship. |
| Memory migration tool | Add dry-run RustyClaw memory import after dashboard basics ship. |
| Hot code reload | Support developer reload of skills/prompt resources and rely on Phoenix LiveReload for UI assets. Production code upgrades stay under `fermix upgrade`. |
| Rich error messages | Add shared error normalization for LiveView and CLI. |
| GraphQL API | Explicitly defer. LiveView and CLI do not need it for M6. |

---

## 3. Scope Decisions

### 3.1 What M6 Owns

M6 owns the developer/operator experience:

- Local dashboard landing page.
- Agent, capability, memory, jobs, logs, traces, setup, health, and config views.
- A narrow browser chat surface for local manual testing.
- CLI read/control commands that mirror the dashboard.
- Core introspection modules that give LiveView and CLI one shared query path.
- Rich, consistent error rendering for setup, health, jobs, memory, and logs.

### 3.2 What M6 Does Not Own

M6 does not reimplement earlier milestones:

- No second scheduler. Use `FermixCore.Jobs.Scheduler`.
- No second setup store. Use `FermixCore.Setup.ConfigStore`.
- No second memory backend. Use `FermixCore.Memory.Repo`.
- No second agent loop. Route browser chat through `MainAgent.handle_message/2`.
- No new provider abstraction. Use current provider routing.
- No GraphQL API in M6. LiveView does not need it, and a REST/GraphQL API can be added later for third-party clients.
- No production BEAM hot-code upgrade. M6 supports developer reload of skills, prompt resources, and UI assets; binary upgrades remain `fermix upgrade`.
- No broad config editor that writes arbitrary TOML. M6 may show config and selected safe fields, but setup remains the write boundary for secrets and provider/channel config.

---

## 4. Product Shape

The first screen should be the operator console, not a marketing page.

Navigation:

1. **Overview** - readiness, provider/model, daemon uptime, memory DB, jobs, channels, recent failures.
2. **Chat** - local test chat routed through the same `MainAgent` ingress as channels.
3. **Agents** - main-agent status, running skill workers, capability counts, reload actions.
4. **Jobs** - scheduled jobs, next run, last run, delivery, run history, pause/resume/remove/run-now.
5. **Memory** - source catalog, scoped search, recent memories, recent messages, resource revisions.
6. **Logs** - tail `fermix.log`, filter by level/text, follow mode.
7. **Traces** - structured trace event browser for provider calls, tool/capability executions, channel messages, agent events, and errors.
8. **Setup** - current setup report, readiness failures, restart-required state, seed prompt files action.
9. **Doctor** - run local checks and show actionable output.

Keep the UI dense and operational. Use restrained tables, badges, split panes, and filters. Avoid landing-page hero treatment.

---

## 5. Architecture

### 5.1 Shared Introspection Boundary

Add a core-owned introspection namespace so web and CLI do not duplicate query logic:

```text
FermixCore.Introspection
  Overview       -> aggregate health, daemon, provider, channels, jobs, memory
  Agents         -> main-agent status + AgentSupervisor skill workers
  Capabilities   -> capability registry summaries and filtered lists
  Jobs           -> job list, job runs, run output refs, safe control calls
  Memory         -> source catalog, scoped memory/message search
  Logs           -> bounded initial reads + filters
  Traces         -> bounded JSONL trace reads and filters
  Setup          -> BootReport/Wizard projection for UI/CLI
```

These modules are pure APIs or thin wrappers over existing GenServers. They should return `{:ok, data} | {:error, reason}` and never render HTML or print CLI text.

Live updates are a separate boundary, not part of the read-only introspection API:

```text
FermixCore.Events
  emit/1        -> core-local domain event dispatch
  subscribe/1   -> app-local subscribers such as the web bridge and tests
```

`FermixCore.Events` has no Phoenix dependency and is not durable storage. It is a live notification boundary emitted at the same point that Fermix mutates owned state or writes owned runtime output. Durable truth remains in the existing registries, SQLite tables, config files, log files, and trace JSONL files; LiveViews always take an initial bounded snapshot through `FermixCore.Introspection.*` before subscribing for deltas.

### 5.2 Web Layer

Add LiveViews under `apps/fermix_web/lib/fermix_web_web/live/dashboard/`:

```text
dashboard_live.ex
chat_live.ex
agents_live.ex
jobs_live.ex
memory_live.ex
logs_live.ex
traces_live.ex
setup_live.ex     # replace or move current SetupLive
doctor_live.ex
```

Add reusable components under `components/dashboard_components.ex` for status badges, metric cards, data tables, filters, empty states, and code/log panes.

Routing:

```elixir
live "/", Dashboard.OverviewLive
live "/chat", Dashboard.ChatLive
live "/agents", Dashboard.AgentsLive
live "/jobs", Dashboard.JobsLive
live "/memory", Dashboard.MemoryLive
live "/logs", Dashboard.LogsLive
live "/traces", Dashboard.TracesLive
live "/setup", Dashboard.SetupLive
live "/doctor", Dashboard.DoctorLive
```

LiveView updates are push-driven via `FermixWeb.PubSub`. LiveViews never run periodic refresh timers.

Core modules do not call `Phoenix.PubSub` or refer to `FermixWeb.PubSub`. `fermix_web` owns a small bridge process, `FermixWeb.Dashboard.EventBridge`, that subscribes to `FermixCore.Events` and selected telemetry events, translates them into bounded UI deltas, and broadcasts those deltas on Phoenix topics.

Topics:

- `runtime` - Overview, Agents, Capabilities. Bridge input: setup/config changes, daemon lifecycle events, capability registry reloads, and telemetry counter deltas from the events Fermix already emits (`[:fermix, :provider, :call]`, `[:fermix, :tool, :exec]`, `[:fermix, :channel, :message]`, `[:fermix, :agent, :message]`, `[:fermix, :agent, :message_error]`, `[:fermix, :agent, :reply_error]`, plus lifecycle events from `FermixCore.Agents.LifecycleTelemetry`).
- `jobs` and `jobs:{job_id}` - Jobs list and per-job views. `FermixCore.Jobs.Registry`, `Scheduler`, and `Runner` already own the state-machine transitions; they emit core events on every transition (created, scheduled, running, completed, failed, paused, resumed, removed) and on every run lifecycle event. The web bridge rebroadcasts those events to the Phoenix topics.
- `chat:{session_id}` - local browser chat. The LiveView wraps the `MainAgent` `reply_fn` and broadcasts the final assistant response on the session topic. Token/chunk streaming is not part of M6 unless the provider/AgentLoop streaming contract is added first.
- `logs` and `traces` - writer-sourced live output. Trace live events are emitted by `FermixCore.Trace` after a successful JSONL write. Log live events are emitted by a Fermix-owned logger handler that replaces the current `:logger_std_h` file handler, preserves the configured file path/format/rotation behavior, and emits the same appended line/chunk through `FermixCore.Events` only after a successful write. The web bridge broadcasts those events to `logs` and `traces`; LiveViews consume them with `Phoenix.LiveView.stream/4` so rendered lists stay bounded without re-rendering the whole table.

Push everywhere Fermix owns the producer. If M6 needs to observe an external resource that does not expose an event source, the view must either show snapshot-only/stale state or add an explicit event adapter for that resource. Do not hide external observation behind a LiveView polling loop.

The only acceptable LiveView timer is a per-view debounce (<=200 ms) coalescing bursts a producer emits faster than the browser can paint; debounce is implemented with `Process.send_after/3` driven by an arrived event, not by a periodic tick.

Initial render of every view is a single read through `FermixCore.Introspection.*` for the bounded snapshot; from that point on the view consumes bridge events from the relevant topic.

### 5.3 CLI Layer

Extend `Fermix.CLI` with query/control commands that call `FermixCore.Introspection`:

```text
fermix status [--full] [--json]
fermix health [--json]
fermix agents [--json]
fermix jobs list [--json]
fermix jobs runs JOB_ID [--json]
fermix jobs pause JOB_ID
fermix jobs resume JOB_ID
fermix jobs remove JOB_ID
fermix jobs run-now JOB_ID
fermix memory sources [--json]
fermix memory search QUERY [--scope current|owner|all] [--source memories|history|all] [--json]
fermix capabilities [--kind builtin|skill|mcp|all] [--json]
fermix traces [--type TYPE] [--since DURATION] [--json]
fermix reload skills
fermix reload prompt
```

Keep existing `fermix status`, `fermix logs`, and `fermix doctor`; improve their output by sharing formatters and error hints with the new commands.

`fermix status` stays compact by default because it already means daemon liveness to scripts and service managers. When the daemon is running, it may include a one-line operational summary: readiness, main-agent state, worker count, job count, and next scheduled job. `fermix status --full` renders the same broad snapshot as the Overview LiveView. `fermix status --json` returns the structured overview snapshot for automation. The existing "not running" exit behavior remains compatible.

CLI commands that need live process state should ask the running daemon to evaluate the matching `FermixCore.Introspection.*` module instead of starting an independent local runtime and guessing at state. File-only/history reads may still use bounded direct reads when the daemon is not running.

---

## 6. Data Contracts

### 6.1 Overview Snapshot

`FermixCore.Introspection.Overview.snapshot/1` returns:

```elixir
%{
  generated_at: DateTime.t(),
  readiness: %{status: atom(), failures: [map()]},
  daemon: %{status: :running | :not_running | :unknown, pid: String.t() | nil, uptime_ms: integer() | nil},
  provider: %{active: atom() | nil, model: String.t() | nil, auth_mode: atom() | nil},
  channels: [%{name: String.t(), status: atom(), enabled: boolean(), mode: atom() | nil}],
  memory: %{database_path: String.t(), repo: atom(), conversation_store: atom(), store: atom()},
  jobs: %{
    scheduled: integer(),
    running: integer(),
    paused: integer(),
    failed_recent: integer(),
    next: %{id: String.t(), name: String.t() | nil, next_run_at: DateTime.t(), state: String.t()} | nil,
    status: :ready | :unavailable,
    error: String.t() | nil
  },
  agents: %{
    main: %{
      health: :online | :unknown,
      activity: :idle | :running | :unknown,
      status: :idle | :running | :unknown,
      active_conversations: non_neg_integer(),
      pending_conversations: non_neg_integer()
    },
    skill_workers: integer(),
    running_skill_workers: integer()
  },
  capabilities: %{builtin: integer(), skill: integer(), mcp: integer()},
  paths: %{home: String.t(), config: String.t(), logs: String.t(), traces: String.t()}
}
```

### 6.2 Agent Status

Add `MainAgent.status/1` returning:

```elixir
%{
  name: "main",
  health: :online,
  activity: :idle | :running,
  status: :idle | :running,
  pid: pid() | nil,
  active_conversations: non_neg_integer(),
  pending_conversations: non_neg_integer(),
  active_requests: non_neg_integer(),
  pending_requests: non_neg_integer(),
  available_skills: [String.t()],
  provider: atom() | nil,
  model: String.t() | nil,
  memory: %{extraction_enabled: boolean(), agent_id: String.t(), owner_id: String.t()}
}
```

`health` means the MainAgent process answered the status call. `activity` means whether it currently has in-flight work. `status` stays as the activity value for Stage 1 CLI compatibility; dashboards must present health and activity separately so an idle but healthy main agent is not shown as inactive or broken.

This is an operational status API, not a conversation inspector. It must not expose message contents, user text, tool arguments, or full conversation keys. Skill workers continue to come from `AgentSupervisor.list_agents/1`.

### 6.3 Job Views

Use the existing `scheduled_jobs`, `job_runs`, and `memory_sources` tables. Add small read wrappers only where needed:

- `Jobs.list_jobs/1`
- `Jobs.get_job/2`
- `Jobs.list_runs/2`
- `Jobs.read_run_output/2`
- `Jobs.pause/2`
- `Jobs.resume/2`
- `Jobs.remove/2`
- `Jobs.run_now/2`

`run_now` should create a `job_run` with `trigger: "manual"` and start the existing runner path. It must not bypass scheduler/runner finalization rules.

### 6.4 Memory Views

Memory browsing must be source-aware:

- default view is `memory_sources`
- search defaults to `source: "memories"` and `scope: "owner"`
- message history search requires explicit `source: "history"` or `source: "all"`
- job memory shows source name, run ID, and session ID
- prompt resources link to resource revision history instead of pretending derived `MEMORY.md` is canonical

Do not add destructive memory editing in the first stage. Deletion and manual edits need an explicit M10 policy story.

### 6.5 Logs and Traces

Logs:

- read from configured `:fermix_core, :log, :file`
- initial render returns a bounded tail (text filter, level filter, byte and line caps)
- follow is push-driven from the writer path: replace the current `:logger_std_h` handler installed by `FermixCore.Application.setup_file_logger/0` with a Fermix-owned logger handler that writes the configured file and emits `FermixCore.Events.log_appended` for the appended line/chunk only after the write succeeds
- the replacement handler preserves today's `:fermix_core, :log` config contract: `enabled`, `file`, `max_no_bytes`, `max_no_files`, and the current line formatter
- the log file remains durable history for initial render and recovery; it is not the live event source
- rotation/truncation handling belongs in the logger handler and bounded reader: when the handler reopens after rotation or detects truncation, emit one warning/status event and continue writing; when the reader sees truncation or a missing rotated file, return the newest bounded content plus a warning
- if an operator configures an external logger/file writer that Fermix does not own, the dashboard shows bounded history only unless that writer has an explicit event adapter
- handle missing log file with a clear setup/run hint

Traces:

- read from configured trace base dir
- list dates and trace types
- initial render parses bounded JSONL by date and type
- follow is push-driven from `FermixCore.Trace.record/4`: after a successful JSONL append, Trace emits `FermixCore.Events.trace_recorded` with the structured entry and file/date/type metadata
- malformed historical JSONL lines are skipped with a visible warning count during initial/recovery reads; live trace events are already structured and should not require re-parsing
- filter by type, agent, tool/capability, channel, and text
- cap initial result counts; live additions are bounded by the LiveView stream window

---

## 7. Security and Local Access

M6 runs before M10, so it must be conservative:

- Bind the dashboard to localhost by default.
- Do not expose secret values. Show configured/missing, auth mode, path, and provider.
- Do not allow arbitrary config TOML edits from the dashboard.
- Do not expose raw environment variables.
- Keep dangerous actions out of M6. No shell execution, file writes, prompt editing, memory deletion, or tool approval management from the dashboard.
- Mutating M6 actions are limited to reload skills, reload prompt files, pause/resume/remove jobs, run job now, and seed missing prompt files.
- Every mutating action emits telemetry/trace and shows a confirmation when it can delete or run work.
- If the endpoint is configured to bind remotely before M10 auth exists, disable mutating dashboard actions unless an explicit opt-in config flag is set.

---

## 8. Error Handling

Add `FermixCore.Introspection.Error` to normalize common failures:

```elixir
%{
  code: atom(),
  title: String.t(),
  detail: String.t(),
  hint: String.t() | nil,
  severity: :info | :warning | :error
}
```

Examples:

- missing config -> "Run `fermix setup` or open `/setup` locally."
- daemon not running -> "Run `fermix run` or `fermix start`."
- missing log file -> "The daemon has not written a log file yet."
- repo disabled -> "Durable memory is disabled in config."
- malformed trace line -> "Skipped N malformed trace lines."
- job not found -> "No scheduled job with that ID."
- run output missing -> "Run finished without an output artifact."

Web renders these as banners or inline table states. CLI renders a one-line error plus a hint.

---

## 9. Implementation Stages

### Stage 1 - Core Introspection Read Model

- Add `FermixCore.Introspection.Overview`.
- Add `FermixCore.Introspection.Agents`.
- Add `FermixCore.Introspection.Capabilities`.
- Add `MainAgent.status/1`.
- Extend `fermix status` with `--full` and `--json` over the Overview snapshot while preserving the existing compact default and not-running exit behavior.
- Add tests with injected process resolvers, fake registries, and no Phoenix dependency.

Ship gate: `fermix status --json`, `fermix health --json`, `fermix agents --json`, and `fermix capabilities --json` can be implemented with no web code.

### Stage 2 - Dashboard Shell and Overview

- Replace the generated Phoenix home page with the dashboard shell.
- Add sidebar/top navigation.
- Add overview cards and readiness/failure tables.
- Keep `/setup` working and move its current content into the dashboard layout.
- Add LiveView tests for routes and setup-required rendering.

Ship gate: opening `/` shows Fermix status, not Phoenix marketing content.

### Stage 3 - Agents, Capabilities, Jobs

- Add Agents LiveView.
- Add Capabilities LiveView.
- Add Jobs LiveView with list, run history, pause, resume, remove, and run-now.
- Add `FermixCore.Events` as the core-local live event boundary with no Phoenix dependency.
- Add `FermixWeb.Dashboard.EventBridge` to translate core events and selected telemetry into `FermixWeb.PubSub` topics.
- Add `FermixCore.Introspection.Jobs`.
- Add CLI `fermix jobs ...`.
- Wire job state transitions in `FermixCore.Jobs.Registry`, `Scheduler`, and `Runner` to emit core events. The web bridge broadcasts them on `jobs` and `jobs:{job_id}`.
- Wire the Agents/Capabilities producers to emit core events for reloads and lifecycle changes.
- Add the telemetry side of the web bridge for `[:fermix, :provider, :call]`, `[:fermix, :tool, :exec]`, `[:fermix, :channel, :message]`, `[:fermix, :agent, :message]`, `[:fermix, :agent, :message_error]`, `[:fermix, :agent, :reply_error]`, and `FermixCore.Agents.LifecycleTelemetry.trace_event_definitions/0`. The bridge emits bounded counter deltas on `runtime`.

Ship gate: a scheduled job can be inspected and paused/resumed from both CLI and dashboard, and the dashboard reflects state changes within one PubSub round-trip with no polling timer in the LiveView.

### Stage 4 - Memory, Logs, Traces

- Add Memory LiveView over source-aware search and resource revisions.
- Add Logs LiveView with bounded initial render plus push-driven follow.
- Add Traces LiveView with JSONL filters and push-driven follow.
- Replace the current `:logger_std_h` file handler with a Fermix-owned logger handler that preserves existing file path, formatter, rotation, and failure behavior, then emits core log events after successful writes.
- Update `FermixCore.Trace.record/4` to emit a core trace event after successful JSONL writes.
- Extend the web bridge to broadcast log and trace events on `logs` and `traces` PubSub topics.
- Add CLI `fermix memory ...` and `fermix traces ...`.

Ship gate: an operator can answer "what happened, what did it call, what memory exists, and where did it come from" without opening SQLite or raw JSONL files, and Logs/Traces views surface new lines as they are written without a refresh.

### Stage 5 - Local Browser Chat and Reload Controls

- Add Chat LiveView routed through `MainAgent.handle_message/2`.
- Add browser-only `reply_fn` that appends assistant responses to the LiveView conversation.
- Add `fermix reload skills` and dashboard skill reload action.
- Add prompt reload action if it can be implemented as a visible, single code path; otherwise keep prompt reload out and require restart.

Ship gate: local chat uses the same MainAgent path as real channels and reload controls are visible in trace/log output.

### Stage 6 - Migration Helpers

- Add `fermix import rustyclaw-config --dry-run --path PATH`.
- Add `fermix import rustyclaw-memory --dry-run --path PATH`.
- Keep imports dry-run first, with a summary of target Fermix config/memory records.
- Only add write mode after dry-run tests cover malformed, partial, and duplicate input.

Ship gate: RustyClaw imports are previewable without mutating Fermix state.

---

## 10. Testing Strategy

Core tests:

- Introspection modules accept injected server names, file paths, clocks, and process resolvers.
- Overview snapshot handles missing daemon socket, missing logs, disabled memory, missing job tables, and setup-required state.
- Logs and traces enforce byte/line caps.
- Trace reader handles malformed JSONL without failing the whole request.
- Job controls use existing registry/runner APIs and preserve existing job state transitions.
- MainAgent status reports active/pending conversation counts without exposing message contents.
- Core event tests assert owned state transitions emit `FermixCore.Events` without depending on Phoenix or `FermixWeb.PubSub`.
- Log writer tests assert the Fermix-owned logger handler preserves the current file path, formatter, `max_no_bytes`/`max_no_files` rotation behavior, and failure handling; successful writes emit log events, while rotation/truncation produces one warning/status event.
- Trace writer tests assert successful JSONL writes emit structured trace events and failed writes do not emit false positives.

Web tests:

- Router tests for every dashboard route.
- LiveView mount tests for ready, setup-required, and degraded states.
- LiveView event tests for job pause/resume/remove/run-now with confirmation.
- Memory search form tests for scope/source defaults.
- Logs/traces tests with temp files exercise bounded initial/recovery reads for rotation, truncation, and malformed-line handling.
- PubSub bridge tests assert job transitions, telemetry deltas, log events, trace events, and chat replies fan out on the documented topics.
- LiveView tests subscribe and assert renders happen on receive, with no `Process.send_after/3`-driven periodic refresh in the view.
- Static/code-boundary test asserts `apps/fermix_core` does not reference `Phoenix.PubSub` or `FermixWeb.PubSub`.

CLI tests:

- `--json` output is valid JSON.
- Human output includes concise status and hints.
- Not-running daemon exits remain compatible with current `fermix status` behavior; `status --full` and `status --json` do not mask the service-not-running case.
- Mutating commands return non-zero on missing IDs or invalid state transitions.

Manual smoke:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test apps/fermix_core/test/fermix_core/introspection apps/fermix_web/test/fermix_web_web
PHX_SERVER=true mix phx.server
```

Then open `http://localhost:4030/`, create a temporary job through the existing tool or CLI, and verify the dashboard sees it.

---

## 11. Acceptance Checklist

- [ ] `/` is the Fermix dashboard, not the Phoenix default page.
- [ ] `/setup` still works in setup-required mode.
- [ ] Dashboard never displays raw secrets or raw env vars.
- [ ] Overview shows readiness, provider/model, channels, jobs, memory, daemon, and paths.
- [ ] Agents view shows main-agent status and dynamic skill workers.
- [ ] Jobs view shows schedule, next run, last run, delivery, run history, and output refs.
- [ ] Memory view searches durable memories with source metadata.
- [ ] Logs view tails bounded log content and handles missing files.
- [ ] Traces view parses and filters structured trace JSONL.
- [ ] CLI mirrors core dashboard reads with JSON output for automation.
- [ ] `fermix status` remains compact by default; `status --full` and `status --json` expose the Overview snapshot without changing existing not-running semantics.
- [ ] Mutating dashboard actions are limited, confirmed, traced, and localhost-only unless explicitly enabled.
- [ ] Dashboard updates from PubSub topics, not polling timers; core emits owned state changes through `FermixCore.Events`, and `fermix_web` owns the Phoenix PubSub bridge.
- [ ] Logs and traces follow writer-sourced events without periodic refresh; the Fermix logger handler replaces `:logger_std_h` while preserving existing file config, formatting, and rotation semantics; bounded file reads handle missing files, malformed trace lines, rotation, and truncation.
- [ ] No GraphQL, duplicate scheduler, duplicate memory store, or duplicate setup writer is added.
