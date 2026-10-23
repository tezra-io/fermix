# cue_inbox: the M60 cue inbox, its filter calls and its cue runs

Models a few cue deliveries from acceptance to their end: `Cues.Ingest`
routing an item to its watchers (`pending` for an `llm` watcher, `passed` for a
`none` one); `Cues.Filters`, the one filter dispatcher, claiming a watcher's
oldest due `pending` delivery and running the call as a task under
`Cues.FilterSupervisor`; the task's fenced settle; the dispatcher's own settle
when a task crashes or misses its 60 s deadline; the boot reset after a
dispatcher restart; the dispatcher's 60 s sweep reclaiming a `filtering` row no
task holds; admission of cue runs inside `Jobs.Scheduler` (the slot ceiling, the
cue share, and no cue run while the last reconcile scan failed) and the cue
claim that takes the job, the run and the delivery in one transaction; the
run's settle by its runner or by the scheduler (a monitored crash or a reap);
reconciliation (adopt or reap) at the scheduler's init and on its tick; the
lifetime expiry sweep; the `tools_started_at` marker
that ends retries once a run made an allowed mandate call or a proposal; and,
behind the `Proposals` switch, one proposal of a mandate in approve mode with the
owner's `/confirm` and `/deny`.

The code it describes is the uncommitted `release/0.17.0` work of M60
(2026-10-17), as it stands after the review-1 (R1) fixes and lane R3's fixes
of CUE-1 and CUE-2, so the spec is
**not pinned yet**: its `\* SOURCE:` lines carry no
hash, and the runner reports it STALE until the owner commits and runs
`make -C tla repin SPECS=cue_inbox`. Its line references are those of the
working tree on 2026-10-17 and can drift until then; re-read them at the
re-pin.

A `Topology` constant fixes the deliveries (their watcher, subject and order).
The delivery id is the arrival order, so a delivery is accepted only after every
lower id. Each watcher wakes its own task job, named by the watcher. Time is
booleans: a delivery's `due` (`ready_at` has passed), a watcher's `wblocked`
(`filter_retry_at` has not passed), a delivery's `valid` (`valid_until` has not
passed) and a proposal's `propLive`. Faults come from a budget (`MaxFaults`), and
every claim that does not end its delivery spends one, so the call and run id
bounds never bind (`IdBoundsNeverBind`, a sanity clause of `TypeOK` checked on
every run; it is a check on the spec, not a Fermix rule).

One step is one GenServer callback, one `Memory.Repo` call (the single writer, so
one call is atomic whatever SQL it runs) or one side effect. Calls from one
process are served in the order sent, and a call whose caller timed out still
runs, ahead of anything that caller sends next (`repo.ex` `call/2`,
`call_or_timeout_error/3`). That ordering is why a filter task killed by a
dispatcher restart cannot write after the new dispatcher's boot reset: its settle,
if it was sent, is already in the Repo's mailbox ahead of the reset.

## Left out, and why

- **Backoff lengths and the held state.** A provider failure blocks the watcher
  until its `filter_retry_at` passes, a content failure or a run retry makes the
  delivery not due until its `ready_at` passes; the lengths (30 s, 2 min, 10 min)
  and the hold from the third provider failure (a 10-minute backoff plus a
  notice) change when, not whether, and the budget of two or three faults never
  reaches a hold.
- **Daily caps and filter budgets.** Both are 0 (no cap), so the liveness rule
  reads "under their caps" trivially. A cap only withholds eligibility; it is a
  single-query rule for ExUnit.
- **The inbox cap of 250 and its eviction, receipts, self-caused items, gaps,
  notices, telemetry, sources and the door.** None moves a live delivery between
  the states the properties read, except eviction, which only expires `pending`
  and `passed` rows exactly as the lifetime sweep does.
- **Other retention steps.** They touch terminal rows only (payloads, receipts,
  30-day prunes); the lifetime sweep is the one step that touches live rows.
- **Cron and manual runs.** The cue share is stated as a bound on live cue
  runners, which is what leaves a cron run its slot. The scheduler's cron claim,
  run now, the owner's pause, resume and edit, and the order between cron and cue
  runs are `job_runs`' scope; the alternation of design §9.9 is a later feature.
- **The slot numbers and attempt caps are scaled.** The code has
  `@max_active_runs 4` and `@max_cue_runs 3`; the checks use `MaxActive = 2,
  MaxCue = 1` (two tasks) or `3, 2` (where one task needs two slots for the
  needs check), the same `MaxCue = MaxActive − 1`. The filter and task attempt
  caps are 3 in code and 2 here, so a cue's exhaustion is reachable within two
  faults.
- **A FilterSupervisor crash alone** (its tasks die with an abnormal reason and
  each counts as a content failure) and the `{:aborted, …}` result of a task shut
  down with its supervisor: the boot reset puts a row back the same way, and
  neither changes a property.
- **R1 details that change no property.** The dispatcher claims nothing
  before its first sweep timer (`ready?`, `filters.ex:111`, `:129`, `:135`):
  under weak fairness that timer fires, so the delay is not modelled. A stale
  settle wakes the scheduler (`filters.ex:375-376`): admission is fair here
  anyway. Admission is gated on `cues_running?` (the cue tree alive,
  `scheduler.ex:202`), always true here, and no longer reads
  `cue_watchers.enabled` (a paused watcher's passed items still run); watchers
  are always enabled. The daily budget read and spent inside the accept
  transaction, the gap marking at a settle, the cap notices and the
  `sweep_error` traces of a failed scan, claim or settle touch no delivery
  state. `with_immediate_transaction/2` re-raising a raise, throw or exit
  crashes the Repo process, which restarts everything after it in the core
  tree: a daemon-level restart, outside this spec.
- **The reclaim's age cutoff and its failures (R3).** The sweep reclaims a
  `filtering` row only once its call started more than the 60 s call deadline
  plus a 30 s margin ago (`filters.ex:70`, `:196`); that changes when, not
  whether: a younger orphan is reclaimed by a later sweep. A call the
  dispatcher still holds is never reclaimed, whatever its age, and that is
  modelled (`Orphan`). A reclaim that fails changes no row and is traced
  (`sweep_error`, `filter_reclaim`) and tried by the next sweep; one that times
  out still lands, as the step does.
- **The first sweep's scheduler wake (R3).** The filtering group's first sweep
  wakes the scheduler once (`first_sweep/1`, `filters.ex:179-184`), because the
  scheduler's own admission request at init comes before the cue tree runs.
  Admission is fair here, so the wake changes no property.
- **Proposals are modelled abstractly.** One proposal, created by the run's
  first action with `Proposals` on; a failed send, the owner's taps (twice, and
  from the wrong chat with `OwnerCanMistap`), the expiry clock and sweep, the
  winning `/confirm` command re-checking and then running the recorded call or
  refusing it, and that command crashing (the outcome is reported once as
  unknown and never run again). Lane F was still writing `cues/proposals.ex` and
  `memory/repo/cues_mandate_sql.ex` when this spec was written; the model follows
  `decide_waiting/5` (one `UPDATE … WHERE token_digest = ? AND state = 'waiting'
  AND sent_platform/chat/user = ? AND expires_at > ?`) and `run_confirmed/3` as
  they stood. The validator, pins, the loop breaker and idempotency are
  single-call rules for ExUnit.
- **The owner's devices answer too (M60 app surface §3.7, D28; 2026-10-22).**
  With `AppAnswers`, the owner may also answer from the Mac app's socket or
  the management socket: `Cues.Proposals.decide/4`, one `UPDATE … WHERE id = ?
  AND state = 'waiting' AND expires_at > ?` (`decide_by_id/5`, with
  `end_denied/4` ending a denial's call row in the same transaction), with no
  chat to match because the transport placed the device. A device's confirm
  runs its call in a task of its own (`start_run/3`, then the same
  `run_confirmed/3`), which is the confirmer the model already has, and it is
  acknowledged at once. The device's answers share the owner's two taps, so a
  chat confirm then a device's answer, and two device answers, are both
  explored. The reach rule (with an app surface a failed chat send leaves the
  proposal waiting instead of refusing it) removes a step; the model keeps the
  refusal in every check, a superset of the code's steps, so the safety
  verdicts cover the app's world too. The phone's answer (`surface: mobile`)
  is the same `UPDATE` and adds no step. The announcements to the app
  (`{:offered, card}`, `{:resolved, …}`) and the owner-only placement of the
  socket's peer change no proposal state and are ExUnit's.

## Switches

**Environment** (what may happen): `ProviderCanFail` (a filter call's provider or
content failure, or a task still running at its deadline), `TasksCanCrash` (a
filter task, or a `/confirm` command, exits abnormally), `FiltersCanRestart`,
`SchedulerCanRestart` (runners survive it: `RunnerSupervisor` starts before the
scheduler), `RunnersCanCrash`, `RunsCanFail`, `RunsCanAct` (an allowed mandate
call or a proposal sets `tools_started_at`), `FilterRepoCanFail` (a filter claim
times out and still lands; a filter settle rolls back), `SchedulerRepoCanFail`
(a cue claim times out and still lands; a crash settle rolls back; the
reconcile scan errors), `LifetimesCanEnd`, `Proposals`, `OwnerCanMistap`,
`AppAnswers` (the owner also answers from one of their devices, by id).

**Mechanisms** (`TRUE` is the code; each is `FALSE` in at least one check):

| Switch | Code |
|---|---|
| `SubjectRule` | the subject clause of `@open_sql` (`cues_runs_sql.ex:91-94`), shared by the candidates and the claim's re-read |
| `SubjectRuleCoversUndecided` | that clause reads `pending` and `filtering` too (PLAN §1; draft 7 read `passed` and `claimed` only) |
| `ExcludesBusyWatchers` | `Cues.Filters` passes the watchers whose call it still holds (`filters.ex:235`) |
| `SettleFenced` | a filter settle needs its call open (`open_call/2`, `cues_filter_sql.ex:430`) and the row's `filter_call_id` (`move/5`, `:541`); a refused settle closes the open call `aborted` (R1, `abort_stale_call/3`, `:419`) |
| `TasksDieWithDispatcher` | the filtering group (`FermixCore.Cues.FilteringSupervisor`, defined inline in `cues/supervisor.ex:44-51`, `:58-63`) is `rest_for_one`, `Cues.Filters` before `FilterSupervisor`; the cue supervisor above the groups is `one_for_one` (`:55`) |
| `BootReset` | `Filters.init` resets `filtering` rows (`filters.ex:102`, `:159`; `cues_filter_sql.ex:633`) |
| `NonePassesAtAccept` | a `none` watcher's delivery is inserted `passed` (`cues_sql.ex:620`) |
| `ClaimNeedsIdleJob` | the cue claim needs the job `scheduled` with no active run (`@open_sql :87-90`; `repo.ex` `fetch_claimable_job`, `ensure_no_active_job_run`) |
| `CueSlotCap` | `free = min(max_active − active, 3 − active_cue)` (`cue_admission.ex:57`) |
| `AtomicCueSettle` | the run row, the job's release and the delivery's move are one transaction (`repo.ex` `settle_cue_run_in_tx`) |
| `RunSettleFenced` | a run settle needs the run active (`ensure_job_run_active`) and the delivery claimed by it (`settle_held/5`, `cues_runs_sql.ex:309`) |
| `ReapsOnlyDeadRuns` | reconciliation reaps a run only when the runner supervisor no longer holds its runner (`scheduler.ex:386`, `:398`) |
| `ReconcilesRuns` | init and the 60 s tick reconcile unsettled runs (`scheduler.ex:210`, `:250`, `:370`) |
| `ExhaustsAfterAction` | a failure once `tools_started_at` is set ends the delivery `exhausted` (`cues_runs_sql.ex:331`) |
| `ToolsMarkWriteOnce` | the run upsert never clears `tools_started_at` (`repo.ex` `upsert_job_run_row`, `coalesce`) |
| `ConfirmFenced` | the confirm is one `UPDATE` fenced on state, token, chat and expiry (`cues_mandate_sql.ex` `decide_waiting`) |
| `AppDecideFenced` | a device's answer is one `UPDATE` fenced on id, state and expiry (`cues_mandate_sql.ex` `decide_by_id`) |
| `ReclaimsOrphans` | every sweep puts back a `filtering` row whose call the dispatcher does not hold, fence cleared, attempts unchanged, its call finished `aborted` (R3, CUE-1: `reclaim_orphans/1`, `filters.ex:192-215`; `{:reclaim_orphans, …}`, `cues_filter_sql.ex:129`, `reclaim_in_tx/4` `:668`) |
| `AdmitsAfterScan` | no cue run is admitted while the last reconcile scan failed, since the monitors may then miss runners that survived a restart (R3, CUE-2: `free_cue_slots/1`, `scheduler.ex:312`; `runs_known?` set by `reconcile_active_runs/1`, `:374`, `:382`) |

## Checks

| Check | Expect | What it says |
|---|---|---|
| 01_filter_and_subject | holds | Subject order, one filter call per watcher, acked only by a settled run, under every filter, run and restart fault. |
| 02_needs_subject_rule | needs `SubjectRule` | |
| 03_needs_subject_rule_undecided | needs `SubjectRuleCoversUndecided` | A content failure leaves the older delivery `pending` while the newer passes; draft 7's rule would claim the newer. |
| 04_needs_excludes_busy_watchers | needs `ExcludesBusyWatchers` | A call that wrote its result but has not reported back keeps its watcher. |
| 05_needs_atomic_cue_settle | needs `AtomicCueSettle` | |
| 06_runs | holds | One active run per task; no retry after an action; with scheduler Repo failures. |
| 07_needs_claim_needs_idle_job | needs `ClaimNeedsIdleJob` | |
| 08_needs_exhausts_after_action | needs `ExhaustsAfterAction` | |
| 09_needs_tools_mark_write_once | needs `ToolsMarkWriteOnce` | The runner's own settle carries the run as it read it at start, marker unset. |
| 10_cue_share | holds | Live cue runners never exceed the share when the adoption scan succeeds. |
| 11_needs_cue_slot_cap | needs `CueSlotCap` | |
| 12_cue_share_after_failed_adoption | holds | Live cue runners never exceed the share with scheduler restarts whose adoption scan fails, and failed reconcile scans: no cue run is admitted until a scan succeeds (CUE-2, fixed). |
| 13_late_filter_write_after_reset | holds | Isolates the fence: a task that outlived a restart writes after the reset and a new claim, and is refused. |
| 14_needs_settle_fenced_reset | needs `SettleFenced` | |
| 15_late_filter_write_after_settle | holds | Isolates the fence: a deadline write lands after another claim of the delivery, and is refused. |
| 16_needs_settle_fenced_settle | needs `SettleFenced` | |
| 17_late_run_write_after_reap | holds | Isolates the run fence: a runner whose run was reaped while alive settles after a new claim, and is refused. |
| 18_needs_run_settle_fenced | needs `RunSettleFenced` | |
| 19_nothing_stranded | holds | Every accepted delivery of an `llm` and a `none` watcher ends terminal (weak fairness on Fermix's processes and timers), and a `none` delivery is `passed` at acceptance; every fault but a failed filter Repo call (check 23 has those). |
| 20_needs_boot_reset | needs `BootReset` | Covers 30: a restart's `filtering` row is decided again, the reclaim aside, only by the boot reset. |
| 21_needs_reconciles_runs | needs `ReconcilesRuns` | |
| 22_needs_none_passes_at_accept | needs `NonePassesAtAccept` | |
| 23_filter_repo_failure_reclaimed | holds | An `llm` delivery ends terminal with claims that time out but land, settles that roll back, provider and content failures, deadlines, task crashes and dispatcher restarts (CUE-1, fixed). |
| 24_proposals | holds | Confirmed only while waiting, unexpired and from its chat or one of the owner's devices; the call runs at most once, whichever surface answered first. |
| 25_needs_confirm_fenced_waiting | needs `ConfirmFenced` | |
| 26_needs_confirm_fenced_once | needs `ConfirmFenced` | |
| 27_witness_waits_behind_undecided | reachable | A passed delivery can wait only because an older one of its subject is still `pending` or `filtering`. |
| 28_needs_admits_after_scan | needs `AdmitsAfterScan` | Covers 12: CUE-2's path, a fourth cue run after a restart whose scan failed. |
| 29_needs_reclaims_orphans | needs `ReclaimsOrphans` | Covers 23: CUE-1's path, a claim that timed out and landed, then nothing. |
| 30_boot_reset_alone | holds | Isolates the boot reset: check 19 with the reclaim off. |
| 31_needs_app_decide_fenced_waiting | needs `AppDecideFenced` | Covers 24: a device's answer after the chat's confirm, or after expiry, counts without the device's fence. |
| 32_needs_app_decide_fenced_once | needs `AppDecideFenced` | Covers 24: a second answer from a device runs the call again without the fence. |

Checks 13, 15, 17 and 30 switch a mechanism off in a `holds` check on purpose
(the `token_refresh` 16 precedent): with every mechanism on, no stale writer
exists, because the dispatcher's tasks die with it (13), the dispatcher excludes
a watcher whose call it still holds (15) and reconciliation reaps only dead runs
(17). Each fence is defence in depth behind that, and the isolation shows it
holds by itself. Since R3 the sweep's reclaim also puts back a row a
dispatcher restart left `filtering`, so with every mechanism on the boot reset
is no longer what check 19 rests on (it only makes the row due at once instead
of after the cutoff); check 30 switches the reclaim off so check 20 still shows
the boot reset does the work by itself.

**What the checks do not show.** The fences are never exercised with every
mechanism on: a late filter or run write needs a writer the process structure
already rules out. Of design §17's list, "cron and cue runs alternate, a late
cron run goes first, and a yield never makes a cron run stale" (§9.9) is a later
feature and not modelled.

### Hand runs with one more of each entity

Each `holds` check, run once by hand with one more delivery (and a third watcher
for 10) and one more fault, on 2026-10-17:

| Check | Bigger bounds | Result |
|---|---|---|
| 01 | `subject3` (three deliveries, one subject), 3 faults | holds, 168,839 states, 9 s |
| 06 | `two_subjects3`, 3 faults | holds, 192,237 states, 8 s (R3 model) |
| 10 | `three_tasks`, `MaxActive 3`, `MaxCue 2`, 3 faults | holds, 359,566 states, 13 s (R3 model) |
| 12 | `three_tasks`, `MaxActive 3`, `MaxCue 2`, 3 faults | holds, 463,160 states, 17 s (R3 model) |
| 13 | `two_llm`, 3 faults | holds, 38,828 states, 2 s |
| 15 | `two_llm`, 3 faults | holds, 39,083 states, 3 s |
| 17 | `two_none`, 2 faults | holds, 302 states, 0 s |
| 19, 30 | see below | |
| 23 | `two_llm`, 3 faults | holds, 7,477 states, 3 s (R3 model) |
| 24 | `two_none`, 2 faults | holds, 13,751 states, 2 s; again with `AppAnswers` on 2026-10-22: holds, 13,751 states, 1 s (with its fence on, a device's answer reaches no state a tap from the right chat does not; checks 31 and 32 show what it adds without the fence) |

Check 19 (liveness) grows fast, so one entity at a time. On the R3 model:
`mixed3` (a second `llm` delivery of the same subject) with 2 faults holds,
527,000 states, 5 min 57 s; `mixed` with 3 faults holds, 127,801 states, 46 s.
Check 30 with 3 faults holds, 127,801 states, 46 s (without a failed filter
Repo call the reclaim is never enabled, so 30 explores 19's states). Before R3,
both together (`mixed3`, 3 faults) was stopped after 21 minutes at 1,309,150
distinct states and 269,461 still queued, with no violation found up to then.

Checks 01, 13, 15, 17 and 24 explore the same states at their check bounds on
the R3 model as before (the new steps need a failed filter or scheduler Repo
call, which none of them injects), so their hand runs above stand.

## Findings

### CUE-1: a filter claim that times out, or a filter settle that rolls back, strands the delivery and its watcher

**Fixed in lane R3 (2026-10-17, uncommitted; the commit is the owner's).** The
dispatcher's 60 s sweep now reclaims a `filtering` row no task holds (see
"Fix" below). Check 23 holds and check 29 (`needs ReclaimsOrphans`) keeps the
counterexample below.

Proposed rule (design §17): no undecided delivery is stranded while its watcher
is enabled; a held watcher retries until a call succeeds or the lifetime ends.

`Cues.Filters.claim/2` (`filters.ex:233-247`) calls the Repo with periodic
options (`repo_opts/1`, `:488`: `on_timeout: :error`). When the claim times out
it traces `sweep_error` (`filter_claim`) and starts no task (`:243-245`), but the
request still runs: `claim_one/3` (`cues_filter_sql.ex:209`) moves the delivery
`pending → filtering` with a new `filter_call_id` and an open call row. No task
holds that call and the dispatcher's `in_flight` does not know it. A task's
settle (or the dispatcher's own, after a crash or a deadline) that returns an
error other than a timeout or `:stale` (its transaction rolled back) leaves the
same thing: `filtering`, call open, the task reported, the slot freed
(`finish/5`, `filters.ex:380`). A timeout is harmless there: the settle still
runs, ahead of the dispatcher's next claim.

Nothing then moves the row. The claim query skips a watcher that has a
`filtering` delivery (`cues_filter_sql.ex:177`), so the watcher takes no more
calls at all; the lifetime sweep never touches `filtering` (`cues_sql.ex:1091`,
`sweeper.ex` moduledoc); the dispatcher's 60 s sweep only dispatches; the only
reset is the boot reset in `Filters.init`. The delivery and every later delivery
of that watcher wait until the daemon (or the filtering group) restarts. The
reminder rail has the recovery this lacks: its 60 s monitor check resets a
`delivering` row no worker holds (`reminder_delivery`'s `ClaimTimesOut`).

Counterexample (check 23 before R3, now check 29: `one_llm`, only
`FilterRepoCanFail`): `Accept(1)`, `FClaimTimesOut(a)`, then nothing can move
delivery 1.

R1 re-walk (2026-10-17): still open, unchanged. None of the R1 changes gives
the row a way out:
- a stale settle now closes its open call `aborted` (`abort_stale_call/3`,
  `cues_filter_sql.ex:419`), but only a call that receives a result; the
  stranded call has no task, so no result ever comes;
- the first-timer rule (`filters.ex:111`, `:129`, `:135`) only delays the
  dispatcher's first claim after a start;
- `prune_filter_calls` now deletes unfinished calls too (`cues_sql.ex:1177`),
  but only after 30 days, and it leaves the delivery `filtering`: the claim
  query still skips the watcher, and only the boot reset (which fences on the
  delivery's own `filter_call_id`, not the call row) moves it;
- the filtering group's own supervisor (R1) restarts the dispatcher only when
  it crashes, and a claim error does not crash it.

The `jobs` side recovers the same fault: a cue claim that times out leaves a run
with no runner, and reconciliation reaps it on its next tick (check 19 holds with
`SchedulerRepoCanFail` on).

Fix (R3): every sweep (`handle_info(:sweep)`, `filters.ex:133`) first runs
`reclaim_orphans/1` (`:192-215`), skipped while the boot reset is pending: one
`{:reclaim_orphans, held, cutoff, now}` Repo call (`cues_filter_sql.ex:129`,
`reclaim_in_tx/4` `:668`) with the call ids the dispatcher holds and a cutoff of
the 60 s call deadline plus a 30 s margin (`@orphan_margin_ms`, `filters.ex:70`).
In one transaction, every `filtering` row whose `filter_call_id` is not held and
whose call started before the cutoff (or whose call row is gone) goes back to
`pending` through the boot reset's fenced move (`reset_each/2`, `:653`), attempts
unchanged, and its open call is finished `aborted` with "no task held this call
past its deadline" (`abort_orphan_calls/3`, `:703`). A failure is traced as
`sweep_error` (`filter_reclaim`) and tried by the next sweep. ExUnit:
`cues/filters_test.exs` "orphaned filter calls" (a claim that commits while the
dispatcher sees `:repo_timeout` is left alone before the cutoff and freed after
it; a held call is never reclaimed, however old). Model: `FReclaim` behind
`ReclaimsOrphans`. Because the reclaim also puts back a row a dispatcher restart
left, check 20 (`needs BootReset`) now covers the isolation check 30 (19 with
the reclaim off).

### CUE-2: after a scheduler restart whose adoption scan fails, cue runs can take every slot

**Fixed in lane R3 (2026-10-17, uncommitted; the commit is the owner's).** No
cue run is admitted while the last reconcile scan failed (see "Fix" below).
Check 12 holds and check 28 (`needs AdmitsAfterScan`) keeps the counterexample
below.

Rule (`cue_admission.ex:9-11`): "Cue runs hold at most three of the scheduler's
run slots, counted from the `trigger` each `run_monitors` entry carries, so a cron
run always keeps one"; design §17: "cue runs never take the last slot".

`Jobs.Scheduler` restarts alone and its runners survive (`RunnerSupervisor`
starts before it). `init/1` reconciles first (`scheduler.ex:210`): the scan
`Repo.unsettled_job_runs` runs with periodic options, and when it errors or times
out it is logged and init goes on with no monitors (`:370-384`). Init then asks
for an admission pass (`:213`). `admit_cue_runs/2` (`:293`) computes
`free_slots(active, run_monitors, max)`: `active` is the runner supervisor's
count, which includes the surviving cue runners, but `active_cue` counts monitors,
which are empty, so the cue room is the whole share again (`cue_admission.ex:57`).
With three cue runners alive and four slots, one more cue run starts and the four
slots are all cue runs; the next reconcile tick adopts all four. A due cron run
then finds the scheduler at capacity until a cue run ends (at most 30 minutes
each).

Counterexample (check 12 before R3, now check 28; scaled to `MaxActive 2`,
`MaxCue 1`, 7 states):
accept both, `Admit(a)`, `SchedRestart`, `SchedBoot` with a failed scan,
`Admit(b)`: two live cue runners.

R1 re-walk (2026-10-17): still open, unchanged. The admission gate is now
`cues_running?` (`scheduler.ex:202`, `:283`, `:294`), true while the cue tree
lives, so it does not hold the pass back; `admit_cue_runs/2` (`:293-305`) still
passes `state.run_monitors` to `free_slots/3` (`cue_admission.ex:57-63`);
`reconcile_active_runs/1` (`:370-384`) still leaves the monitors empty on a
failed scan; `claim/4` (`cue_admission.ex:82`) traces a failed scan as
`sweep_error` but changes no count.

Fix (R3, the lead's choice of the two): the scheduler keeps `runs_known?`
(`scheduler.ex:200`), set by every reconcile scan, at init and on each tick:
true when the scan succeeded (`:374`), false when it failed (`:382`, logged
"no cue run starts until a scan succeeds"). `admit_cue_runs/2` (`:293`) takes
its free slots from `free_cue_slots/1` (`:312`): none while the run set is
unknown, else `CueAdmission.free_slots/3` as before. Cron runs keep their own
rule (the ceiling on `active`). ExUnit: `jobs/scheduler_cues_test.exs` "after a
restart whose adoption scan fails, no cue run starts until a reconcile
succeeds" (a failed `unsettled_job_runs` at init with three surviving cue
runners: no fourth cue run, a due cron run still starts, a succeeding reconcile
adopts the three, and the waiting cue starts once a cue run ends). Model:
`runsKnown`, `SchedRescan` (a tick's scan succeeding, fair) and
`SchedRescanFails`, behind `AdmitsAfterScan`. A scan that succeeds but reads at
most 50 unsettled runs (`@reconcile_run_limit`) could still miss a live runner
past the 50th; the spec's bounds never reach it.

## Related specs

`job_runs` and `reminder_delivery` pin the scheduler, runner, registry, settle
and application tree this milestone changed; their re-read is separate work.
Lane R3 changed three things `job_runs` describes: the cue claim waits for a
reconcile scan that succeeded (CUE-2's fix); the filtering group's first sweep
wakes the scheduler, so a boot's admission no longer waits for a tick (its
README calls the init request dead code, and check 37 pins the tick); and the
reaper's final failure report marks the run row's delivery `pending` before
its send (its witness 45 is no longer reachable in the code and is owed a
`holds` check with a `needs` check).
