# Jobs — scheduled agent runs

`schedule_job` creates durable work without running it now — use it when the future run must reason or act; a deterministic personal date that only needs to notify the owner belongs in `event_store` (see the `events_reminders` reference).

## Schedule forms

Schedule forms: interval (`every N minutes|hours|days`), one ISO8601 datetime (`once`), or 5-field cron; free-form English (e.g. "daily at 8am") is rejected — use `0 8 * * *`. Each cron field supports `*`, single values, comma lists (`1,15`), ranges (`9-17`), and steps (`*/15`, `8-18/4`); weekday `7` and `0` both mean Sunday; out-of-range or malformed fields are rejected at creation. Cron fires in the job's timezone (DST-aware; an unknown zone is rejected at creation).

## Isolation

Runs are isolated bounded agent loops and cannot see the creating chat, so include needed facts in task text.

## Missed fires and terminal states

If the daemon was down across a recurring job's fire time, a due time older than the freshness window (`[fermix_core.jobs] run_freshness_window_seconds`, default 3600) is **skipped** rather than fired late at the wrong wall-clock — the schedule just advances to the next future occurrence (logged). A one-off `once` run has no next occurrence, so it runs late instead of being dropped. A schedule expression or timezone that no longer parses (e.g. a corrupted row) is **terminal**: the job moves to a `disabled` state with the parse error in `last_error` and stops being retried — it must be fixed with `update_job` and then resumed, distinct from a user pause.

## Concurrency and transient retries

Concurrent scheduled runs are capped (a small fixed ceiling); while the cap is full a due job stays `scheduled` and is claimed by a later tick as a slot frees, so a burst of simultaneously-due jobs never fans out without bound. A transient failure on the whole-loop retry is only retried before any tool has executed — once a tool has run, a mid-run connection loss fails the run loudly rather than replaying the tool's side effects (one narrow exception: a continuation call that failed transiently — a pre-response timeout, a transport cut, or a provider-declared overload — with nothing user-visible emitted is re-issued in place by the agent loop with short bounded backoff; nothing replays). A run that fires just as the host wakes can hit a not-yet-ready network: the runner classifies a pool-checkout `connection_unavailable` failure as transient infrastructure (not a provider-failover case) and re-runs the whole loop with bounded exponential backoff, and — when `[fermix_core.jobs] network_readiness_enabled` (default true) is on — first waits on a short, bounded TCP readiness probe to the primary route's host before the first model call.

## Lifetime, timeouts, and delivery

`expires_at` makes a temporary job; `delivery_mode` is `none|origin|channel|local`. `timeout_seconds` caps each run's wall clock (absent = the 30-minute daemon default) and `inactivity_timeout_seconds` arms a watchdog that fails a run whose provider/tool loop stops making progress (absent = unarmed); both are set at creation only — `update_job` cannot edit them — and `get_job_run`'s config snapshot echoes the values a run actually executed under.

## Capability confinement and trust

`allowed_tools` narrows the run to a subset of the caller's currently-visible tools (unknown names rejected); the model can never widen the run's capability policy past the creator's trust. **Operator-created** scheduled runs can delegate in parallel via `subagents` (regular caps — 10 tasks / 8 concurrent), and each worker's surface is the intersection of the delegation baseline and the run's own ceiling: a job confined by `allowed_tools`/`capability_policy`/`skill_name` spawns workers confined the same way, never wider. Guest-created runs never see `subagents` (it is policy class `external_api`, which the guest surface excludes), and `subagents` is only advertised to a run where it can actually execute. Every job is stamped at creation with its creator's own trust (operator or guest) — a context that carries no trust cannot create a job at all, so a job never inherits a trust the creator lacked. `skill_name` binds the run to an existing skill (rejected at creation if unknown): the run then executes inside that skill's confinement — the skill's `allowed_tools` and policy are intersected with the job's, never widened, and a guest job naming a skill whose policy grants nothing under guest trust fails loud rather than running unconfined.

## Route pins

Optional `provider` + `model` pin which provider/model the job's runs use; they are both-or-neither (set both or neither — a pin without its pair is rejected), `provider` must be a known/configured provider (validated at creation against the same catalog the runner enforces), and `model` is a free-form provider-specific id. Omit both to use the default cron route (`[fermix_core.routing] cron_*`, else the primary/fallback chain resolved at run time).

## Managing jobs

`update_job` edits a job in place — task, schedule, description, `skill_name` rebinding, `provider`/`model` route pin, and delivery (`delivery_mode`/`delivery_target`); omitted fields are left unchanged (delivery is never silently retargeted to a config default, and an omitted `provider`/`model` keeps the current pin), and switching delivery to `none`/`local` clears the target. A `clear_route_pin` boolean un-pins the job's `provider`/`model` back to default routing; it is mutually exclusive with `provider`/`model` (set those to re-pin instead) and combining them is rejected. `list_jobs` payloads surface `task_prompt` (the job's current instructions), `skill_name`, `provider`, `model`, `delivery_mode`, and `delivery_target` so the instructions, binding, pinned route, and destination are readable without reaching into the database. `run_job_now` fires a job immediately, out of band, through the same isolated runner (the run is tagged `trigger: "manual"`) and leaves the timed cadence untouched — use it to test a job or satisfy an on-demand request; it refuses when the job is paused/disabled/expired or already mid-run. `list_job_runs` reads a job's execution history (status/trigger/timing/outcome, newest first, optional `status` filter) and `get_job_run` reads one run in full (`task_prompt` the run actually executed — captured in its config snapshot, so it reflects the instructions at run time rather than the job's current ones; plus prompt snapshot, token usage, final response, error) — use these to confirm a job is actually firing and inspect what its runs produced.
