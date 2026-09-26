# Jobs — scheduled agent runs

`schedule_job` creates durable work that runs later and must reason or act; a date that only notifies the owner is an event instead (`events_reminders`).

## Creating

| field | required | default | notes |
| --- | --- | --- | --- |
| `name` | yes | — | non-empty; slugged into the id |
| `schedule` | yes | — | see Schedule grammar |
| `task` | yes | — | non-empty |
| `timezone` | no | `UTC` | IANA zone; unknown is rejected |
| `description` | no | none | for the source catalog |
| `expires_at` | no | none | ISO8601 + offset, future |
| `delivery_mode` | no | config default, else `none` | `none`/`origin`/`channel`/`local` |
| `delivery_target` | no | none | `platform` plus one of `chat_id`, `channel_id`, `recipient`, `target`, `reply_target` |
| `allowed_tools` | no | no narrowing | subset of the caller's visible tools |
| `skill_name` | no | none | must name a loaded skill |
| `provider` + `model` | no | cron route | both or neither; provider known |
| `timeout_seconds` | no | 30 minutes | positive integer |
| `inactivity_timeout_seconds` | no | unarmed | positive integer |

No other parameters exist: the iteration cap (100), isolation, the `job:<id>` memory scope, the `[SILENT]` marker and `capability_policy` are fixed.

`task` is the run's entire brief. It cannot see the conversation that created it, so bake in every value it needs (location, account, recipient) and keep timing in `schedule`/`expires_at`. Ask for a missing detail rather than inventing one; revise with `update_job` rather than recreating.

## Schedule grammar

Exactly one of three forms. Free-form English ("daily at 8am") is rejected.

- Interval: `every N minutes|hours|days`, `N` positive. First run is N from creation.
- Cron: `minute hour day-of-month month day-of-week`. Fields take `*`, a value, a list (`1,15`), a range (`9-17`), or a step (`*/15`, `8-18/4`). Weekday `0` and `7` are Sunday. Day-of-month and day-of-week must both match. Malformed or out-of-range fields are rejected.
- One-off: one ISO8601 instant with an offset, `2035-09-10T16:00:00Z` or `2035-09-10T12:00:00-04:00`. No offset is rejected. A past instant fires on the next tick.

`timezone` affects cron only: `0 9 * * 1` with `timezone: "America/New_York"` fires 09:00 local and tracks DST, and without `timezone` fires 09:00 UTC. Interval and one-off are absolute instants. The owner's zone is in the current-date system note; pass it whenever the owner spoke in local time.

## Delivery

`none` sends nothing, `local` records without a channel send, `origin` replies into the creating conversation, `channel` sends to an explicit `delivery_target`. Delivery resolves once at creation and is snapshotted, so later config edits never retarget a job: an explicit mode wins; a `delivery_target` alone implies `channel`; neither falls to `[fermix_core.jobs] default_delivery_mode`/`default_delivery_target`, else `none`. A job the owner expects to hear from needs an explicit mode.

`channel` with no target and no configured default is rejected, as is a target missing `platform` or a destination key. `origin` derives platform, chat id and thread from the creating chat and is rejected without one; an ACP session refuses it outright, so schedule to an explicit channel there. From the Mac app's chat it delivers into the companion timeline, written even while the app is closed and caught up when it reconnects (`companion` reference).

A final response of exactly `[SILENT]` delivers nothing and stores no run summary; the run prompt tells it to answer that way when there is nothing new. Under `origin`/`channel` the run can also send files with `send_attachment` and `generate_image` (16 media sends max, always to the job's own destination — `images` reference); under `local`/`none` they refuse first.

## Runs

Each run is a fresh bounded loop with the job prompt, the current date and the task; no chat history.

Trust is stamped from the creating turn and never widens; a context carrying no trust cannot create a job. `skill_name` runs the job inside that skill's prompt, its tools and policy intersected with the job's, never wider; a skill granting nothing under the job's trust fails the run loudly. Unpinned runs resolve `[fermix_core.routing] cron_*`, else the primary/fallback chain, at run time.

`timeout_seconds` bounds the run's wall clock and `inactivity_timeout_seconds` fails a loop that stops progressing. Both are creation-only — `update_job` cannot change them — and `get_job_run` echoes what a run executed under.

## Lifecycle

A recurring job due older than the freshness window (`[fermix_core.jobs] run_freshness_window_seconds`, default 3600) is skipped rather than fired at the wrong wall-clock and its schedule advances; a one-off never goes stale and runs late instead. `expires_at` marks the job expired.

A schedule or timezone that no longer parses is terminal: the job moves to `disabled` with the reason in `last_error` and is never retried. Fix it with `update_job`, then `resume_job`.

At most four scheduled runs execute at once; a due job over the cap stays `scheduled` until a later tick claims a slot, and `run_job_now` is uncapped. A transient infrastructure failure re-runs the whole loop with bounded backoff only while no tool has executed; afterwards the run fails loudly rather than replaying side effects.

## Managing

- `update_job` edits `task`, `schedule`, `description`, `skill_name`, the route pin and delivery in place; omitted fields are unchanged, so delivery is never silently retargeted and a pin is kept. Switching to `none`/`local` clears the target. `clear_route_pin: true` un-pins to default routing and cannot be combined with `provider`/`model`. An empty patch is rejected.
- `list_jobs` lists jobs with their `task_prompt`, schedule, `timezone`, `next_run_at`, state, pin, delivery and last outcome; optional `state` filter.
- `pause_job` stops future ticks. `resume_job` recomputes the next run and refuses an expired job or a one-off whose instant has passed.
- `remove_job` deletes the job and tombstones its memory source; it refuses while a run is active.
- `run_job_now` fires one run immediately through the same runner, tagged `manual`: a recurring job keeps its cadence, and a one-off run by hand is done (it does not fire again at its instant); it refuses a paused, disabled, expired or already-running job.
- `list_job_runs` reads history newest first, optional `status` (`queued`/`running`/`ok`/`error`) and `limit` (default 20, max 100). `get_job_run` reads one run in full: the `task_prompt` it executed, prompt snapshot, token usage, final response, error. A just-triggered run can still be `queued`, so re-read before reporting an outcome. A run's `status: ok` means the loop finished, not that the task succeeded: each run row carries `tool_failures`, the number of tool calls that came back as errors, visible in `list_job_runs`, the run's `output.md` and its `job_run_complete` trace event.
