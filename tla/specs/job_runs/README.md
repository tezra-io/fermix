# job_runs: scheduled jobs, from claim to delivery

Models `FermixCore.Jobs` for one recurring job: the Scheduler's due tick and
its atomic claim, one `Jobs.Runner` per run, delivery of the run's final text
through `Delivery.ChannelSend`'s watchdog, the Scheduler's monitors and its
reconciliation pass (at init and every 60 s), and the owner's pause, resume,
edit and "run now". A run ends the way the code ends it: one
`Repo.settle_job_run` transaction writes the final run row and releases the
job, then the memory write, the send, and `mark_delivery`. The Scheduler's
reaper settles a dead runner's run the same way. A Scheduler Repo call that
times out does not stop the Scheduler: it takes that call's error branch.

With cues on (M60) the Scheduler also admits cue runs, and the one job can be
a watcher's task: a job that runs on cues, claimed by admission from its
passed deliveries instead of by the due tick. Checks 36 to 52 cover it; see
"Cue runs (M60)" below, "Re-read for M60" and "Re-read after the M60
commit". The one job can also be a watcher's follow-up, whose runs start
from its watcher's triggers through the same admission pass. Checks 54 to 60
cover it; see "Follow-ups" below and "Re-read for watcher follow-ups".

Time is a clock of fire times: `now` counts the fire times that have passed,
and the job row's `next_run_at` is one of them. The AgentLoop is one step that
ends in text, `[SILENT]` or an error. Two run ids are reused once a run is
fully finished, so a check covers any number of runs. The spec's header lists
what is left out and every step folded into another.

**Environment switches** (set per check):
- `DaemonCanCrash`: the daemon dies once and boots again. Only SQLite rows and
  what the platform took survive. This also covers a crash of any core child
  started before the `RunnerSupervisor` (`CommandHostSupervisor` through
  `MainAgent`, `Memory.Repo`, `Trace` and `Finch` among them,
  `application.ex:259-346`) or of the `RunnerSupervisor` itself, since
  `:rest_for_one` restarts every job process in each case (`:182`). A
  runner's send helper and its AgentLoop are linked to it, so none outlives
  the restart; `LoopDiesWithRunner` off lets the loop outlive it (JOB-8).
- `SchedulerCrashes`: how many times the Scheduler alone may die, at any point
  of any callback, including its own init. A Repo timeout no longer kills it
  (`SchedulerTimeouts`); another cause still does, such as `:rest_for_one`
  restarting it when `MeetingsSupervisor`, started between the
  `RunnerSupervisor` and the Scheduler, dies (`application.ex:347-354`).
  Runners keep running. When it dies waiting on the reaper's write, that write
  may still land (see late writes).
- `SchedulerTimeouts`: how many of the Scheduler's Repo calls may time out.
  Every call its process makes passes `Repo.periodic_opts` (`on_timeout:
  :error`, `repo.ex:1224-1226`, `scheduler.ex:170-173`), so a call the Repo
  does not answer within 5 s returns `{:error, :repo_timeout}`
  (`repo.ex:4371-4379`). The Scheduler takes that call site's error branch and
  keeps its monitors and timers; it does not restart, so no init
  reconciliation follows. The request is not cancelled (see late writes),
  unless it is a claim the Repo reaches past the Scheduler's deadline.
- `RunnerCanCrash`: a runner dies at one of its Repo calls (a call timeout, a
  failed `{:ok, _}` match). At its final write the write may still land.
- `LoopCanFail`: the AgentLoop ends in an error or a timeout.
- `PlatformCanFail`: a send fails, either with no connection or with an error
  after the platform took the message.
- `ResponsesCanStall`: the platform takes a message and its answer never
  arrives in time. With `DeliveryWatchdog` off, the model waits forever,
  because the adapters' own HTTP timeouts are outside the sources.

**Configuration** (set per check):
- `CuesOn`: the cue tree runs (`Cues.running?/0`, which the Scheduler reads
  before every admission request and every admission), so the Scheduler
  admits cue runs: one coalesced `:cue_admit` pass on a wake from the cue
  inbox (`cue_wake/1`), on a run's end (both DOWN handlers) and on
  `:job_changed`, and admission after the due scan of every due and reconcile
  tick (`scheduler.ex`, `handle_info(:due_tick | :reconcile_tick |
  :cue_admit)`, `maybe_request_admission`, `admit_cue_runs`). While the
  Scheduler's last reconcile scan failed, admission starts no cue run
  (`runs_known?`, `free_cue_slots`), since its monitors may then miss runners
  that survived a restart; the spec carries that as `runsKnown`. Checks 01 to 35
  set it `FALSE`: the Scheduler then does exactly what it did before M60, and
  those checks find exactly the state counts they found before (every
  `holds` and every invariant violation; a liveness counterexample's count
  moves with the order TLC explores in).
- `CueTask` (with `CuesOn`): the job is a watcher's task (`schedule_kind
  "cue"`, `Registry.create_cue_job/2`). The due scan and the timer lookup
  never return it (no `next_run_at`, no expiry), `run_job_now` refuses it
  before calling the Scheduler (`Registry.check_run_now`) and a job's kind
  never changes, so it has no manual run. Its runs are claimed by admission
  from `waiting`, the count of its passed deliveries (`Repo.claim_cue_run`: in
  one transaction the eligible delivery, the job taken `running` with
  `next_run_at` left alone, the run inserted with `trigger: "cue"`, the
  delivery moved to `claimed`). A completed run acks its delivery. A failed
  run, settled by its runner or by the reaper (`Repo.settle_cue_run`), puts it
  back (`waiting + 1`) or ends it: a free choice that stands for the attempt
  count, the provider-failure rule and `tools_started_at`. A retried attempt
  only marks its run's delivery `skipped` (`finish_cue_failure`). An exhausted
  run the reaper settled gets its failure text from a task under the shared
  `TaskSupervisor` (`report_cue_failure` → `CueRun.report_final_failure`),
  which marks the run's delivery `pending` before the send and records the
  result after it (`mark_attempted`, `record_delivery`).
- `Cues`: the passed deliveries the cue inbox hands the task, each with its
  wake (for a cron job, wakes caused by another task's deliveries; for a
  follow-up, the triggers its watcher sets `starting`, each with its wake).
- `FollowUp` (with `CuesOn`, never with `CueTask`): the job is a watcher's
  follow-up (`schedule_kind "watcher"`, `Registry.create_follow_up_job/2`,
  M60_WATCHER_CODING_RUNS.md §4). As for a cue task, the due scan and the
  timer lookup never return it and a resume arms no next run; unlike one, the
  owner may run it now by hand (`check_run_now` refuses the cue kind alone).
  Its runs start from `starting`, the count of its triggers in state
  `starting`: an item passing an automatic follow-up's watcher writes one in
  the pass's transaction, and the owner's yes on a card moves one from
  `waiting`; either wakes the Scheduler. Each admission pass, after the
  re-arm and before the cue runs, reads them (`{:starting_triggers, 10}`)
  and claims each (`Repo.claim_follow_up_run`: in one transaction the
  trigger read while `starting`, the job taken `running` through
  `claim_in_tx`, the run inserted with `trigger: "watcher"`, the trigger
  moved to `started`). A job that cannot take the run, paused, gone or still
  running, refuses the trigger in that same transaction, so a trigger never
  waits behind a run. The claimed runs start once every trigger the scan read
  is done. A follow-up run then runs, settles and delivers as a cron run
  does. Checks before 54 set it `FALSE`.

**Late writes.** `Memory.Repo` serves one request at a time. A call it does
not answer within 5 s (`Timeouts.repo_call`, `timeouts.ex:225-229`) times out,
but the request stays in the Repo's mailbox and lands later, still before any
later request from the same caller (`repo.ex` `call/2`). `PRAGMA
busy_timeout=5000` (`repo.ex:4411`) equals that budget, so one SQLite lock
wait is enough. The one exception is a claim its caller marks `skip_when_late`:
the Scheduler's `claim_due_job`, `claim_job_now`, `claim_cue_run` and
`claim_follow_up_run`. The Repo turns such a claim away unrun once the
caller's deadline has passed (`handle_call/3`'s `{:with_deadline, ...}`
clause), and it writes nothing; one the Repo had started by then still lands
late. Every write, a runner's or the reaper's, lands late as before.
- A runner dies on the timeout. The spec therefore has two kinds of crash at a
  runner's Repo write: the write lands late, or it never lands (a kill, or a
  failed match). The late kind is modelled where no later crash point already
  stands for it: `RunnerCrashLate` at the runner's final write.
- The Scheduler survives the timeout (`SchedulerTimeouts`): its write lands
  late while it has already taken the error branch. It can still die of
  another cause while it waits on the reaper's write, which then lands:
  `SchedulerCrashLate`.

Any later reader's call is queued after the late one, and the Scheduler's own
steps before its next Repo call read no row, so the late write lands in the
crash or timeout step itself.

**A Scheduler Repo call that times out**, site by site (`scheduler.ex`):
- Modelled, because the Scheduler carries on from states a crash and restart
  never left:
  - The claim (`Repo.claim_due_job`, `:722-724`; `ClaimTimeout`) and "run
    now"'s claim (`Repo.claim_job_now`, `:758-763`; `ManualRunTimeout`). A
    claim the Repo had started still lands when it would have (one it turned
    away unrun writes nothing and leaves what a timed-out due scan leaves,
    `ScanTimeout`, or "run now"'s first branch), but no runner starts and
    nothing monitors the run: a queued run with no runner holds the job (`running`)
    until the next 60 s reconcile pass reaps it with `reaped: no live runner
    (daemon or scheduler restart, or a memory store that answered too late)`
    (`:69-73`). That occurrence never runs. A restart would have reaped it in
    init at once. Witness 30 reaches this.
  - The run lookup in `mark_run_failed` (`Repo.get_job_run`, `:961-964`;
    `ReapLookupTimeout`). After a DOWN the monitor is already gone, so the dead
    runner's run keeps its row: a queued/running row holds the job, and a
    pending delivery stays pending, until the next reconcile pass reaps it with
    the generic text instead of `runner crashed: ...`. In a reconcile pass
    the orphan waits for the next pass. Witness 31 reaches this.
  - The reconcile scan (`Repo.unsettled_job_runs`, `:496-502`;
    `ReconcileRowsTimeout`): the pass reaps and adopts nothing. After a
    restart, a live runner then stays unmonitored until the next pass, so its
    crash sends no DOWN. The run set is unknown until a scan succeeds, so no
    cue run starts meanwhile.
  - The due scan (`:576-578`; `ScanTimeout`), and the timer lookup
    (`Repo.next_scheduled_job`, `:1149-1153`; `ArmTimeout`): nothing is written
    and the due timer is armed at the 5 s backoff. After a timed-out scan or
    claim the tick's outcome is `:error`, so its re-arm floors at the backoff
    whatever its own lookup returns; that re-arm is folded into the timeout
    step. "Run now"'s lookup (`:733-735`) replies the error and writes nothing.
- Folded into an existing step, because the outcome is the same: the reaper's
  write (`Repo.settle_job_run` or the pending-delivery upsert, `:1027-1043`,
  `:1066-1079`) lands late, before the Scheduler's next call, and its error
  branch only logs and skips the memory-source mirror (`:1040-1041`,
  `:1074-1077`), which the spec does not model. That is `ReapRun`. The
  `:run_not_active` re-read is unreachable, as before. Adopting a live runner
  and starting one make no Repo call.

The bounds are constants too: `NumRuns`, `Fires`, `SendAttempts` (3 in the
code, 2 in the checks), `OwnerMoves` (pause/resume requests), `OwnerEdits`
(`update_job` requests) and `ManualRuns`.

**Mechanism switches** (`TRUE` is the real code; each is switched off by the
checks listed under it):
- `AtomicRaceStop`: the claim transaction refuses while a run is queued or
  running (`ensure_no_active_job_run`, `repo.ex:6842`, `:6895-6913`), the due,
  manual and follow-up claims alike (`claim_in_tx`, `repo.ex:7634-7641`).
  Checks 02 and 55.
- `RetriesOnlyUnsent`: a send is retried only when it never reached the
  platform (`channel_send.ex:140-143`, `:194-202`). This is the mechanism for
  platforms that do not dedupe. The runner tags its send with the proactive
  key `job:<run id>` (`runner.ex:1647`). The mobile channel keeps one row per
  key (`mobile_sql.ex:44-46`), so a retry there would not show twice. Check 04.
- `ReconcilesRuns`: at init and every 60 s the Scheduler reaps unsettled runs
  with no live runner and adopts live ones (`scheduler.ex:228`, `:263-533`).
  Checks 07, 28, 33 and 60.
- `CrashFailsPendingDelivery`: the crash path marks a dead runner's pending
  delivery failed, whatever the run's status (`scheduler.ex:1049-1051`,
  `:1070-1083`). Check 09.
- `DeliveryWatchdog`: the runner stops waiting for a send after
  `delivery_timeout_ms` (`channel_send.ex:219-241`). Check 05.
- `AtomicSettle`: a run's final row and its job's release are one
  transaction, `Repo.settle_job_run` (`repo.ex:2489-2492`, `:6851-6867`, `:6927-6974`), used by
  the runner (`runner.ex:344`, `:490`) and the reaper (`scheduler.ex:1031-1047`).
  The release is a column-targeted `UPDATE` that turns `running` back into
  `scheduled` and keeps any other state. Switched off, the spec runs the code
  before the fix: the run row alone, then a read and a whole-row upsert of the
  job row, in the runner and in the reaper. Checks 12, 22, 23, 24.
- `ReconcilesPending`: the reconcile pass reads every unsettled run, the
  queued/running rows and then the rows whose delivery is still pending
  (`unsettled_job_runs`, `repo.ex:2528-2581`; `scheduler.ex:489`). Switched
  off, it reads queued/running rows only. Checks 14, 15, 35.
- `RefusalBacksOff`: a due claim refused as `:already_running` returns
  `{:busy, state}`, so the re-arm floors at the 5 s backoff
  (`scheduler.ex:714-718`, `:1204-1210`). Switched off, the refusal counts as a
  clean drain and a past-due job re-arms at 0 ms. Check 19.
- `OwnerWritesColumns`: pause, resume and `update_job` write only the columns
  they own, in place (`registry.ex:238-261`;
  `Repo.update_scheduled_job_fields`, `repo.ex:2432-2435`, `:7122-7129`, the owner
  field list `:8096-8134`). Switched off, pause and `update_job` upsert the
  whole row they read. Check 27.
- `LoopDiesWithRunner`: a runner's AgentLoop is spawned linked to it and
  reports its own crash as a value (`runner.ex:1285-1289`, `:1301-1318`), so a
  restart that kills the runner kills its loop. Switched off, the code before
  the fix: the loop was only monitored, and a daemon crash (which stands for
  a restart of the job subtree) leaves a runner's loop running as a stray
  loop until it ends by itself. Check 29.
- `TicksAdmit`: the due and reconcile ticks run cue admission after their due
  scan. Switched off, only a wake, a run's end and `:job_changed` ask for
  admission (a starting Scheduler asks for none, see "Re-read for M60"), so a
  delivery a reap put back inside a reconcile pass, or one whose admission
  pass timed out, waits for an event that may never come. Checks 37 and 58.
- `ReportMarksPending`: the reaper's final failure report for an exhausted
  cue run marks the run's delivery `pending` before it sends
  (`CueRun.report_final_failure` → `mark_attempted`, `cue_run.ex:377`,
  `:386-391`), so a daemon that dies around the send leaves a row the
  reconcile pass finishes. Switched off, the code before the fix: the task
  sent first and wrote the result after, so a crash between the two left a
  report the user saw on a run row that says nothing was sent. Check 45.

**What holds.** Every property below is also broken by its `needs` check.
- **At most one active run per job** (check 01). An active run is a
  queued/running row, a runner still before or inside its AgentLoop, or an
  AgentLoop that outlived its runner. This holds with a mid-run resume, every
  kind of crash and a timed-out Scheduler Repo call, and rests on
  `AtomicRaceStop` (check 02) and, across a restart of the job subtree, on
  `LoopDiesWithRunner` (check 29: JOB-8).
- **Final text reaches the user at most once** (check 03), with failing and
  stalling sends, loop errors and runner crashes. On a platform that does not
  dedupe on the proactive key, this rests on `RetriesOnlyUnsent` (check 04).
- **A runner never waits on a send forever** (check 03). This rests on
  `DeliveryWatchdog` (check 05).
- **An enabled job always gets back to claimable**, in four settings:
  - check 06: two Scheduler restarts (a late reaper write included), a manual
    run and loop errors. It rests on `ReconcilesRuns` (check 07) and on
    `AtomicSettle` (check 22: old check 22's wedge).
  - check 11: a daemon crash, runner crashes (late writes included), a
    Scheduler restart and loop errors. It rests on `AtomicSettle` (check 12,
    whose counterexample is JOB-1's shape: after a daemon crash the boot
    reaper's run-row write lands and the Scheduler dies before the job write)
    and on `ReconcilesRuns` (check 28).
  - check 26: an owner edit during a run. It rests on `OwnerWritesColumns`
    (check 27: JOB-7).
  - check 32: a timed-out Scheduler Repo call, runner crashes and a manual
    run. A claim that lands with no runner, or a dead runner's run left
    unmarked, holds the job until the next reconcile pass reaps it, so this
    rests on `ReconcilesRuns` (check 33: a due claim lands after its call
    timed out and nothing ever reaps it).
  "Claimable" (`scheduled`, no queued/running run) is weaker than §4.3's "runs
  again". It is what the Scheduler controls: the next run also needs its due
  time, and the model's clock stops at `Fires`. The widened property was split
  in two because one check with every crash kind holds but takes 220 s
  (476,070 states), over the runner's 120 s timeout.
- **Every pending delivery reaches a final status**, in three settings:
  - check 08: runner crashes (late writes included), a Scheduler restart, loop
    errors, and failing or stalling sends. It rests on
    `CrashFailsPendingDelivery` (check 09) and on `ReconcilesPending` (check
    15: old check 13's path).
  - check 13: a daemon crash, runner crashes, loop errors and failing sends.
    It rests on `ReconcilesPending` (check 14: old check 12's path).
  - check 34: a timed-out Scheduler Repo call, runner crashes and loop errors.
    It rests on `ReconcilesPending` (check 35: a runner dies after its settle,
    the run lookup in its DOWN's handler times out, and only a pass that reads
    pending deliveries settles the row).
  Split for the same reason: all of it in one check holds but takes 100 s.
  The Scheduler timeouts have checks of their own, 32 and 34, for the same
  reason: with one timeout added, checks 06, 08 and 11 hold but take 99 s,
  170 s and 70 s (247,271, 159,411 and 190,508 states).
- **A pause, and a resume, the owner was told about stay in force** (checks 16
  and 17), whenever the run's release lands. Each rests on `AtomicSettle`
  (checks 23 and 24: JOB-4).
- **A refused claim never re-arms at 0 ms** (check 18), with a resume during a
  run and runner crashes over three fire times. This rests on
  `RefusalBacksOff` (check 19: JOB-5). Witness 25 shows the refusal itself is
  reachable, so the pass is not vacuous.

Witness 10 shows the next run in its AgentLoop while the previous run is still
delivering. The race-stop counts rows, not runner processes. Witness 30 shows a
due claim landing after its call timed out, with no runner behind it, while the
Scheduler keeps running; witness 31 shows a crashed runner's run left holding
its job when the run lookup in the DOWN's handler times out.

**Cue runs (M60).** Every property below is broken by its `needs` check too.
- **A watcher's task is not stranded** (checks 36 and 53), with two
  deliveries, loop errors and a timed-out Scheduler Repo call (a failed
  reconcile scan included, after which no cue run starts until a scan
  succeeds):
  - a passed delivery of the enabled task is claimed in the end (check 36,
    `CueClaimedEventually`, the Scheduler's part of M60 §17's "no undecided
    or passed delivery is stranded"). This rests on `TicksAdmit` (check 37:
    the admission pass's candidate scan times out and nothing else asks
    again);
  - the job always gets back to claimable (check 53). This rests on
    `ReconcilesRuns` (check 38: a cue claim lands after its call timed out,
    with no runner).
- **Every pending delivery of a watcher's task reaches a final status**
  (check 39), with runner crashes (late writes included) and loop errors, a
  retried attempt's `pending` then `skipped` included. This rests on
  `CrashFailsPendingDelivery` (check 40: a runner's settle lands late and the
  reaper leaves the pending delivery).
- **No text reaches the user twice** (check 41), the reaper's failure report
  included, with failing and stalling sends, loop errors and runner crashes.
  This rests on `RetriesOnlyUnsent` (check 42). With a Scheduler restart, a
  timed-out Scheduler Repo call and an owner move added it ran past the
  runner's two-minute limit.
- **One active run of a watcher's task** (check 43), with two deliveries, a
  mid-run resume, a daemon crash, runner crashes and a timed-out Scheduler
  Repo call. The claim's no-active-run rule is enforced twice inside one
  transaction (the eligibility query and `claim_in_tx`'s
  `ensure_no_active_job_run`), so no single switch breaks it; across a
  restart of the job subtree the pass rests on `LoopDiesWithRunner` (check
  44: a stray loop and the next cue claim). Witness 51 shows the case the
  rule is for is reached: the candidate scan runs while a second delivery
  waits and the job is `scheduled` again (a resume mid-run) with its run
  still active.
- **A cron job in a home with cues on** keeps its rules under the extra
  admission passes: one active run and no 0 ms re-arm after a refused claim
  (check 46, with a resume during a run and runner crashes over three fire
  times), resting on `AtomicRaceStop` (check 47) and `RefusalBacksOff` (check
  48); and the job gets back to claimable with an owner edit during a run
  (check 49), resting on `OwnerWritesColumns` (check 50).
- **Text that reached the user is recorded** (check 52), the reaper's final
  failure report included, with a daemon crash and runner crashes: once
  nothing is left to write it, its run row never says no delivery was made
  (`SentTextRecorded`; the row may say `failed`, JOB-6). This rests on
  `ReportMarksPending` (check 45: the daemon dies between the report's send
  and its write).

The liveness checks were split (36, 39) because one check with every cue
fault ran past the runner's two-minute limit. Check 36's two properties were
split again (36, 53) when `runsKnown` took it to that limit on a loaded
machine (123 s, against 71 s and 92 s apart).

**Follow-ups (M60 watcher follow-ups).** Every property below is broken by
its `needs` check too.
- **One active run of a follow-up** (check 54), with two triggers, a run by
  hand, a mid-run resume, runner crashes and a timed-out Scheduler Repo call.
  The follow-up's claim is the claim every run takes (`claim_in_tx`), so the
  pass rests on `AtomicRaceStop` (check 55: a resume between two claims of
  one pass, and each trigger's claim takes a run). Witness 56 shows the case
  the race-stop is for: a trigger's claim meets the follow-up's active run
  while the job is `scheduled` again.
- **A starting trigger is never left starting** (check 57,
  `TriggerDecided`), with two triggers, loop errors and a timed-out
  Scheduler Repo call (a failed reconcile scan included): each is in the end
  started or refused. This rests on `TicksAdmit` (check 58: the pass the
  trigger's wake asked for times out at the trigger scan, and nothing else
  asks again).
- **The follow-up's job always gets back to claimable** (check 59), in the
  same setting. This rests on `ReconcilesRuns` (check 60: a follow-up claim
  lands after its call timed out, with no runner).

A follow-up run settles and delivers as a cron run does, so the delivery
properties (03, 08, 13, 34) are not repeated for it. Checks 57 and 59 keep
the owner out: with an owner move each holds but runs past the runner's
two-minute limit (see the hand runs below); check 54 has one.

**Deadlock checking finds nothing here.** The Scheduler's 60 s reconcile timer
is always armed, so an idle Scheduler always has a next step and no state is a
deadlock. `Done` and `Terminated` follow the convention but gate nothing. A
wedge shows up only as a broken liveness property.

**Larger bounds.** Each holds check was also run by hand with one more of each
entity, one entity at a time, with at most 15 minutes and 1.5 GB of TLC state
on disk per run. A send attempt was added only where sends can fail, since the
retry counter never moves otherwise. Every run completed and held; the
slowest took 520 s (check 08 with a second owner edit).

| Check | +1 run id | +1 fire time | +1 send attempt | +1 owner move | +1 manual run | +1 owner edit |
|---|---|---|---|---|---|---|
| 01 | holds, 155,098¹ | holds, 575,653 | n/a | holds, 292,387 | holds, 728,719 | holds, 793,639 |
| 03 | holds, 24,410¹ | holds, 88,278 | holds, 26,528 | holds, 124,285 | holds, 112,600 | holds, 189,961 |
| 06 | holds, 396,793 | holds, 210,266 | n/a | holds, 465,071 | holds, 223,580 | holds, 647,900 |
| 08 | holds, 55,317¹ | holds, 199,389 | holds, 60,027 | holds, 282,392 | holds, 254,518 | holds, 430,381 |
| 11 | holds, 66,266¹ | holds, 239,720 | n/a | holds, 345,524 | holds, 305,646 | holds, 508,767 |
| 13 | holds, 45,430¹ | holds, 164,337 | holds, 49,490 | holds, 232,192 | holds, 209,583 | holds, 350,653 |
| 16 | holds, 12,039¹ | holds, 41,714 | n/a | holds, 22,979 | holds, 53,326 | holds, 61,558 |
| 17 | holds, 22,979¹ | holds, 81,897 | n/a | holds, 34,103 | holds, 104,071 | holds, 110,050 |
| 18 | holds, 669,266 | holds, 269,602 | n/a | holds, 237,774 | holds, 390,964 | holds, 673,463 |
| 26 | holds, 16,411¹ | holds, 59,845 | n/a | holds, 61,558 | holds, 70,065 | holds, 40,379 |

¹ The same state count as the check itself: with that check's fire times and
manual runs, no claim ever finds every run id in use, so a third id is never
taken.

The table predates `SchedulerTimeouts`: its row for check 01 was measured
before check 01 had a Scheduler timeout (155,098 states then, 445,432 now),
and checks 32 and 34 have no row yet. They were run by hand with one more
Scheduler fault instead, and each held: check 32 with a second timeout
(132,103 states) or a Scheduler restart (186,295); check 34 with a second
timeout (68,930) or a Scheduler restart (94,439).

The cue checks were run by hand with one more of an entity: check 36 with a
third delivery held (182,672 states, 238 s); 39 with a second delivery held
(89,950); with a third run id, 39's states (202,928) were all explored with
no invariant broken, but its liveness check had not finished after 11
minutes and was stopped; 41 held with a second delivery (140,202) and with a
third run id (269,020); 46 held with a second wake (733,455) and 49 with a
second fire time (60,643). Check 43 (1,512,284
states) was not run larger. These runs predate `runsKnown` and `ReportMark`
(see "Re-read after the M60 commit") and were not repeated.

The follow-up checks were run by hand on 2026-10-30, one entity at a time,
and each held: check 54 with a third trigger (3,864,536 states, 117 s), a
third run id (8,219,486, 233 s), a second run by hand (4,185,712) or a second
owner move (3,024,592), and with a daemon crash added (3,402,126); checks 57
and 59 each with a third trigger (146,240 states, about 150 s) or an owner
move (267,568, 156 s and 207 s), and with a third run id at their own state
count (47,502).

## Re-read for M60 (2026-10-17)

M60 (cues and watchers), on `release/0.17.0` and not yet committed, staled
every pin but `runner_supervisor.ex`, `delivery.ex`, `channel_send.ex` and
`timeouts.ex`. Re-read against the working tree:
- **Unchanged for the modelled cron job.** With cues off,
  `maybe_request_admission` and `admit_cue_runs` do nothing, and every cron
  path keeps its order: the due and reconcile ticks, the claim, the manual
  run, the reaper and its `settle_job_run` (which now also refuses a cue run,
  `ensure_not_cue_run`, a read inside the same transaction), the runner's
  `mark_completed`/`mark_failed`, `upsert_job_run_row` (now write-once on
  `tools_started_at` and `cue_delivery_id`, two columns the spec does not
  model), the registry's pause, resume and edit (an extra refusal for cue
  tasks only), and the core tree (the cue subtree is its LAST child,
  `application.ex:392`, after `JobRunnerSupervisor`, `MeetingsSupervisor` and
  `JobScheduler`, which keep their order). The `:clock` option and the
  session-id suffix change nothing modelled. Checks 01 to 35 set the new
  constants off and reproduce their earlier verdicts and state counts.
- **Modelled.** The Scheduler's cue admission (`CuesOn`), the cue claim beside
  `ManualRun` (`CueTask`, `CueAdmit`, `CueCandidates`, `CueClaim`,
  `CueStart` and their timeouts), the cue settle in the runner (`Settle`,
  `RunnerCrashLate`, with the retried attempt's `skipped` delivery) and in the
  reaper (`ReapWrite`), the reaper's failure report (`ReportSend`,
  `ReportWrite`), and the requests from a run's end and `:job_changed`.
  Checks 36 to 51 and the new `SOURCE` lines (`cue_admission.ex`, the cue
  claim and settle in `repo.ex`, the eligibility rule and `settle_delivery`
  in `cues_runs_sql.ex`, and `CueRun.report_final_failure`).
- **Read after the review fixes (R1).** The Scheduler's gate is
  `Cues.running?/0` (the cue tree is alive), not `Cues.enabled?/0`; the
  claim's rule no longer reads the watcher's `enabled`; the candidate scan
  also returns the watchers only their daily cap holds, and admission sends
  each a `:cap_reached` notice from a task (not modelled: it changes no row
  the spec reads); scan, claim and settle errors are traced before they are
  logged; the runner's start options no longer carry the delivery (it reads
  it from the run row); the runner marks its watcher's gaps at the settle and
  sends `:task_provider_down` on a retried provider failure (notices, not
  modelled); and `Cues.Supervisor` is `one_for_one` over its intake and
  filtering groups and the sweeper, still the core tree's last child. Only
  the first changed the model: see the first item under "Noticed".
- **Line numbers.** The comments' numbers now point at the working tree as
  of this re-read. Several had drifted before M60 (most `repo.ex` ones), and
  other M60 lanes were still editing `scheduler.ex`, `runner.ex`, `repo.ex`
  and `cue_admission.ex` while this was written, so the re-read after the
  commit should check them again before `make -C tla repin SPECS=job_runs`.

**Noticed (code, for the owner):**
- A starting Scheduler never asks for admission. `init` ends with
  `maybe_request_admission`, which asks only while `Cues.running?/0`, and the
  cue subtree starts after `JobScheduler` under `:rest_for_one`, so it is never
  up then (a boot, or any restart of the Scheduler, which restarts the cue
  subtree after it). That call is dead code in a real tree. Nothing is lost:
  the first due or reconcile tick admits (at most 60 s later), which is what
  `TicksAdmit` and check 37 pin. The spec models the code (no request at
  init).
- The reaper's failure report for an exhausted cue run is not recorded before
  it is sent. The run was settled with the claim's `delivery_status` ("none"),
  the task sends, then writes "sent" or "failed". A daemon crash between the
  two leaves a report the user saw on a run row that says nothing was sent,
  and a crash before the send leaves the owner untold with the same row; no
  reconcile pass reads either, because neither is "pending". Witness 45
  reaches the first. A runner's own send writes "pending" first, so
  `DeliveryReachesFinal` covers it (JOB-6's accepted "failed" aside).
  **Fixed before the commit** (`mark_attempted`): see "Re-read after the M60
  commit".

**Owed** (not modelled here; each needs more than one job):
- **Cue runs never take the last slot** (M60 §17), now with the follow-up
  runs that share the cue share. `free = min(max_active −
  active, 3 − active_cue)` (`CueAdmission.free_slots`), the due path's
  `at_capacity?` and "run now" bypassing the ceiling need several jobs and
  the ceiling, which this one-job spec leaves out. `tla/specs/cue_inbox`
  already records one way the rule breaks (its CUE-2: after a Scheduler
  restart whose reconcile scan fails, `active` counts the surviving runners
  but `active_cue` counts the empty monitors); the model below would carry
  that finding into the jobs side. To model: at least two
  cron jobs and one cue task sharing a small ceiling (`max_active_runs` 2,
  cue share 1), `active` as the runner supervisor's children (a run past its
  settle still sending counts), `active_cue` from the monitors' `trigger`
  (adopted runs read it from the row after a restart), and the order "due
  scan, then admission" inside one callback. Properties: whenever a cue claim
  commits, the cue runs are within the cue share and a slot is left for a
  cron run (`CueNeverTakesLastSlot`); a due cron job and a passed delivery
  competing for one freed slot are decided for the cron job (`CronFirst`);
  and a due cron job is not starved by cue runs (liveness). Checks: one
  `holds` per property, with `needs` checks that switch off the cue-share
  term and the scan-before-admission order. A separate spec (for example
  `tla/specs/job_slots`) is likely cheaper than widening this one, whose
  checks already take up to a minute.
- **Cross-task fairness** (admission takes tasks in the order of their
  oldest eligible delivery, `@candidates_sql`): several tasks; it belongs with
  the slot model.
- **The reaper's report** above: done. The code marks the report "pending"
  before its send; check 52 holds and check 45 is its `needs` check.

## Re-read after the M60 commit (2026-10-23)

M60 was committed as `e0be70a6`, on top of `dev` `b0246d74`, after the review
rounds that followed the re-read above. Every `SOURCE` it touched was re-read
against that commit, from `ddc17fc1`, the last commit that touched this spec
on `dev`:
- **Ordinary scheduled jobs: unchanged.** The due and reconcile ticks, the
  claim and its race-stop, the `:already_running` backoff, the runner's
  settle, the reaper and its pending-delivery path, the owner's pause, resume
  and edit, and the supervision order keep what the model describes. The one
  new Scheduler field, `runs_known?`, is read only by cue admission, so a home
  without cues runs exactly as before; the spec keeps `runsKnown` at `TRUE`
  there. Checks 01 to 35 and 46 to 50 find the state counts they found before
  in every `holds`, invariant violation and witness; only the liveness
  counterexamples of their `needs` checks moved, with the order TLC explores
  in.
- **No cue run starts while the last reconcile scan failed.**
  `free_cue_slots/1` returns 0 until a scan succeeds (`runs_known?`, the fix
  for `tla/specs/cue_inbox`'s CUE-2), and `CueAdmission.claim(0, ...)` then
  makes no Repo call. The comment that said the free slots are never 0 for
  one job was wrong after a failed scan. Now modelled: `runsKnown`, cleared by
  `ReconcileRowsTimeout` and a restart, set by `ReconcileRows`, and read by
  `CueCandidates` and `CueCandidatesTimeout`. `CueClaimedEventually` still
  holds (check 36): the next reconcile tick that succeeds also admits. Check
  36 grew from 70,366 to 91,342 states and check 43 from 1,512,284 to
  2,926,878, so check 36's second property moved to check 53.
- **The reaper's failure report marks the delivery `pending` first**
  (`report_final_failure` → `mark_attempted`). Now modelled: `ReportMark`
  and the mechanism `ReportMarksPending`. Witness 45 is no longer reachable
  with the real code, so it became the `needs` check of the new check 52
  (`SentTextRecorded`), keeping its file name. A report task is no runner,
  so a reconcile pass can mark its pending row `failed` while it still
  sends; its own result write then replaces that, and `ReapRun`'s comment
  says which order its fold drops.
- **The eligibility rule also asks that a delivery's lifetime has not
  ended** (`d.valid_until > ?`). Left to `tla/specs/cue_inbox`, like the
  subject rule, the caps and the retry delays (the header says so).
- **Nothing modelled changed** in `run_context/3` (the cue run's taint and
  context), the `:task_provider_down` notice a retried provider failure sends
  before its `skipped` mark (the `Settle` comment now says so), the runner's
  gap marks, the cue artifact, and the tagged no-route error.
- **Line numbers** in the comments for `scheduler.ex`, `runner.ex`,
  `application.ex`, `cues_runs_sql.ex` and `cue_run.ex` now point at
  `e0be70a6`.

## Re-read for watcher follow-ups (2026-10-30)

Watcher follow-ups (M60_WATCHER_CODING_RUNS.md) staled `scheduler.ex`,
`runner.ex`, `registry.ex`, `cue_admission.ex`, the owner's column write in
`repo.ex` and the cap rule in `cues_runs_sql.ex`. Each was re-read against
the six commits on `dev` `c3442c3a` that build the feature (`a190c404` to
`90a1f0f1`):
- **Modelled: a follow-up's runs (design §4.2, §4.3).** A watcher's
  follow-up is a job of its own kind, `"watcher"`, whose runs start from its
  watcher's triggers, a new source of scheduled runs. The Scheduler admits
  them in the pass that admits cue runs, after the due scan and the re-arm
  and before the cue runs, counted in the cue share (`@cue_share_triggers`),
  never through the manual path that bypasses the ceiling. Each trigger's
  claim is the claim every run takes (`claim_in_tx`), so one run per job
  holds by the same race-stop; a trigger whose job is paused or still
  running is refused in that transaction rather than kept. New:
  `FollowUp`, `starting`, the trigger as a kind of `CueArrives`, the steps
  `FollowUpScan`, `FollowUpClaim` and `FollowUpStart` with their timeouts,
  `TriggerDecided`, witness 56 and checks 54 to 60, and two `SOURCE` lines
  (the follow-up claim in `repo.ex`, and `claimable`, `mark_started` and
  `refuse_starting` in `cues_follow_up_sql.ex`). A follow-up may also run by
  hand (`check_run_now` refuses the cue kind alone), which `ManualRun`
  already is.
- **Unchanged for a cron job and a cue task.** For a job with no follow-up
  the trigger scan finds nothing and its timeout changes nothing modelled,
  so `AdmitFrom` goes straight to the cue runs, and checks 01 to 53 find the
  state counts they found before in every `holds`, invariant violation and
  witness; only the liveness counterexamples of their `needs` checks moved,
  with the order TLC explores in. The offer of new cards before it is a Repo
  call over waiting triggers and a send in a task, which no step reads. The
  owner's edit (`update_scheduled_job_fields_row`) now runs in one
  `BEGIN IMMEDIATE` that also clears a follow-up's automatic approval the
  edit made stale: still one Repo call that writes the same columns. A
  follow-up's own edit may also write its tools and timeout, which no step
  reads. The cue share now counts follow-up runs, and the cap rule counts a
  watcher's follow-ups started or proposed beside its task runs; neither
  binds one job (the share) or is modelled here (the caps are
  `tla/specs/cue_inbox`'s). The runner's read of its trigger and the run's
  telemetry add a prompt line and trace fields; a read that fails fails the
  run as a loop error does. `registry.ex`'s refusals for the cue kind now
  cover both kinds a watcher runs, which no modelled owner request reaches.
- **Line numbers** were moved through the diff, so each moved reference
  points at the same line it did; the new comments cite `90a1f0f1`.

## Re-read for the owner's lists (M85, 2026-10-31)

The owner's lists (M85) staled `runner.ex` alone. `finalize_delivery` now asks
`FermixCore.ReplyBlocks` for the lists the run's list tools read or changed
(`reply_delivery_opts`, a call into the in-memory holder, no Repo call) before
the send helper spawns, and passes them as the send's `blocks`, which a channel
that draws none ignores. No modelled row, helper, delivery or report changes,
and the new function sits below every line the spec cites, so nothing the spec
models changed and no reference moved.

## Re-read for claims the Repo may skip (2026-10-31)

- **A late claim may now write nothing.** A caller marks a request
  `skip_when_late` when skipping it is safe, and the Repo turns such a request
  away unrun once the caller's deadline has passed (see late writes). The
  Scheduler marks its four claims (`claim_due_job`, `claim_job_now`,
  `claim_cue_run`, `claim_follow_up_run`) and nothing else, so every write a
  step models still lands late. A claim turned away leaves what a branch the
  spec already has leaves: `ScanTimeout` for the due claim, the first branch of
  `ManualRunTimeout` and `FollowUpClaimTimeout`, and for a cue claim a pass that
  ends with its delivery still waiting. `ClaimTimeout` and `CueClaimTimeout`
  keep modelling only the claim that lands; a turned-away claim writes nothing
  and leaves the job and its delivery as the pass found them. No step moved.
- **Line numbers** were moved through the diff, so each moved reference
  points at the same line it did.

## Plan hypotheses

The plan (`docs/design/TLA_PLUS_MODELS.md` §4.3) listed four expected
findings. All four were confirmed and all four are fixed.

1. **"A crash after `mark_completed` strands the run as `ok/pending`
   forever."** Confirmed as **JOB-2**; fixed by reconciling pending deliveries.
2. **"A crash between `mark_completed` and `finalize_job` leaves the job stuck
   in `running`."** Confirmed, and wider than stated (**JOB-1**, **JOB-3**);
   fixed by the atomic settle.
3. **"`finalize_job` reads then upserts, so a pause landing between can be
   lost."** Confirmed as **JOB-4**, a resume too; fixed by the settle's
   column-targeted release. The owner's own writes had the same shape
   (**JOB-7**), fixed the same way.
4. **"A pause and resume during a run spins at 0 ms."** Confirmed as
   **JOB-5**; fixed by treating the refusal as backpressure.

## Findings

Every finding below was confirmed by walking the counterexample through the
code on `dev` at `693970b7` (JOB-8 at `35a6acdc`); none has been reproduced
on a running daemon. The **Code** paragraphs cite that code, before the
fix. Each fix is proven by a failing-first ExUnit test and by the checks
named under it. To see a counterexample, run `tla/bin/check.py job_runs` and
open `tla/out/job_runs/<check>.txt`.

A violated liveness property has no pinned length: TLC's lasso is not the
shortest and can change between runs.

### JOB-1: a crash between a run row turning final and the job-row write wedges the job
- **Severity:** medium. The outcome is silent and permanent. A clean daemon
  stop (an app update, `brew upgrade`, a reboot) is enough of a trigger.
- **Status:** fixed (d514e149).
- **Checks:** 06 and 11 hold; 22 and 12 (`needs AtomicSettle`) break with
  the fix switched off. Before the fix these were checks 11 and 22
  (`violated JOB-1`).
- **Counterexample (before the fix):**
  - Old check 11: a run is claimed, so the job row says `running`. The run
    finishes and `mark_completed` writes the run row `ok`. The daemon dies
    before `finalize_job` writes the job row back to `scheduled`. On boot
    nothing touches the job again.
  - Old check 22 has no daemon or runner crash. A claim commits and the
    Scheduler dies before starting the runner. The restarted Scheduler's
    init reaps the orphan: `mark_run_failed` writes the run row `error`
    first. The Scheduler dies again before the job-row write. No row is
    left queued/running, so no later reconcile sees the job. Check 22 now
    reaches the same wedge through the reaper's late write.
- **Code (before the fix):**
  - The claim sets the job to `running` (`repo.ex:5915-5922`,
    `scheduler.ex:723-727`). Only `finalize_job` (`runner.ex:389-413`), the
    crash path (`scheduler.ex:788-803`) and `resume_job`
    (`registry.ex:62-74`) ever set it back.
  - Each writer first made the run row final, then wrote the job row in a
    separate Repo call: the runner at `runner.ex:265` then `:402` (and `:346`
    then `:455`), the reaper at `scheduler.ex:791`/`:846` then `:896`/`:906`.
  - Reconciliation read only queued/running rows (`repo.ex:6256-6271`), so a
    run already marked `ok` or `error` was invisible to it, and the due scan
    and the timer lookup need `state = 'scheduled'`.
- **Fix:** `Repo.settle_job_run/2` (`repo.ex:2408`, `:6361-6430`) writes the
  final run row and releases the job in one `BEGIN IMMEDIATE` transaction, the
  mirror of the claim. It refuses with `{:error, :run_not_active}` unless the
  row is still queued/running, so only the run holding the job can release
  it. The runner's `mark_completed` and `mark_failed` call it
  (`runner.ex:275`, `:359`); `finalize_job`, `finalize_failed_job` and
  `final_job_state` are gone. The reaper settles a queued/running row as
  `error` through it (`scheduler.ex:837-853`); on `:run_not_active` it re-reads
  the row and settles only a still-pending delivery (`:861-874`). The old
  reaper job writers are gone. A one-time migration (version 31,
  `repo.ex:330-342`) releases every job an older release left `running` with
  no queued/running run, by the settle's rule (JOB-4's **Fix**): a one-off
  its claim consumed (`next_run_at` NULL) `completed` and disabled, any other
  job back to `scheduled`. Before this change a manual claim kept a one-off's
  `next_run_at`, so a one-off wedged after a "run now" goes back to
  `scheduled` and fires at its instant (at once if that has passed).
- **Tests:** `repo_jobs_queries_test.exs` (`settle_job_run/2`),
  `scheduler_test.exs` ("final write and job release": a runner killed right
  after its final write; a Scheduler killed right after its reap write),
  `repo_job_settle_migration_test.exs`.

### JOB-2: a crash after `mark_completed` strands the delivery as `pending`
- **Severity:** low. Nothing is sent twice. The run's delivery status just
  never settles, and nobody can tell whether the message went out.
- **Status:** fixed (d514e149).
- **Checks:** 08 and 13 hold; 15 and 14 (`needs ReconcilesPending`) break
  with the fix switched off. Before the fix these were checks 12 and 13
  (`violated JOB-2`).
- **Counterexample (before the fix):**
  - Old check 12: the run row is written `ok/pending`, then the daemon dies
    before `mark_delivery`. Boot reconciliation ignores the row.
  - Old check 13: the Scheduler restarts while the runner is past
    `mark_completed`, so its reconcile scan does not adopt the runner. The
    runner then crashes, and no monitor sees it.
- **Code (before the fix):** `mark_completed` set `delivery_status:
  "pending"` (`runner.ex:261`, `delivery.ex:24-31`). Only `mark_delivery`
  (`runner.ex:365-387`) or a monitored crash (`scheduler.ex:810-811`) settled
  it. Reconciliation and adoption read only queued/running rows
  (`repo.ex:6256-6271`, `scheduler.ex:259-264`).
- **Fix:** `Repo.unsettled_job_runs` replaces `active_job_runs`
  (`repo.ex:2417-2450`, `:6697-6701`): two index reads combined with
  `UNION ALL`, the queued/running rows first and then the rows whose delivery
  is pending, oldest first within each, under the same limit. A partial index
  (version 30, `idx_job_runs_pending_delivery`, `repo.ex:318-321`) keeps the
  pending read off the never-pruned run history; a test asserts the query plan
  has no `SCAN job_runs`. `reconcile_active_runs` reads it
  (`scheduler.ex:261`), so a live runner past its settle is adopted after a
  Scheduler restart and a dead one's delivery is failed. The crash path's
  pending clause now matches any status (`scheduler.ex:855-857`), after the
  queued/running clause. The claim guard still counts queued/running rows
  only, so a slow send never blocks the next claim.
- **Tests:** `repo_jobs_queries_test.exs` (`unsettled_job_runs/1`, with the
  `EXPLAIN QUERY PLAN` assertion), `scheduler_test.exs` ("a pending delivery
  left by a dead runner is failed at boot", "a runner past its final write is
  adopted after a scheduler restart").
- **Note:** a pending row reaped this way is recorded `failed` even when the
  platform took the message: the same at-most-once choice as JOB-6.

### JOB-3: a runner crash after its run row turns final wedges the job
- **Severity:** medium. It needs a Repo error or a slow Repo exactly during
  finalize. But `delivery_mode` defaults to `"none"`, so most jobs are
  exposed, and the wedge is silent and permanent.
- **Status:** fixed (d514e149).
- **Checks:** 11 (job released) and 08 (the failure text's delivery settled)
  hold; 12 (`needs AtomicSettle`) and 09 (`needs CrashFailsPendingDelivery`)
  break with the fixes switched off. Before the fix these were checks 14 and
  15 (`violated JOB-3`).
- **Counterexample (before the fix):**
  - Old check 14: a `[SILENT]` run is written `ok/skipped`. The runner then
    dies at `finalize_job`'s Repo call. The Scheduler gets the DOWN and does
    nothing to the job.
  - Old check 15: the loop fails and `mark_failed` writes `error/pending`. The
    runner dies in `finalize_failed_job`, so the failure text is never sent or
    settled, and the job is wedged too.
- **Code (before the fix):** `mark_run_error` acted only on queued/running
  rows and on ok/pending (`scheduler.ex:805-822`); everything else fell
  through `{:ok, _finished_run} -> :ok` and the job row was skipped. Which
  runner deaths wedged: a timeout at the finalize upsert (`runner.ex:404`,
  `:457`) healed, because the late write released the job; a timeout or an
  `{:error, _}` at the finalize get (`:390`, `:443`), or a timeout at
  `mark_completed`'s or `mark_failed`'s own run-row upsert (`:263`, `:346`),
  wedged, because the run row was final before the reaper's get.
- **By hand:** with runner crashes alone (every other environment switch off)
  and `AtomicSettle` off, TLC wedges the job (a 17-state lasso) through the late
  write: a `[SILENT]` run's `mark_completed` times out, its `ok/skipped` row
  lands, and the reaper sees a final row. With the fix the same setup holds
  (6,105 states).
- **Fix:** JOB-1's settle, with JOB-2's widened pending clause. In the fixed
  code no runner death leaves the job `running`: a death before the settle
  leaves an active row, which the reaper settles as `error` and releases in
  one write; a settle that times out lands whole, late, before the reaper's
  get, which then sees a final row and at most fails a still-pending delivery;
  a death after the settle leaves a released job.
- **Tests:** `scheduler_test.exs` ("a runner killed right after its final run
  write leaves its job claimable" covers old check 14 with the default
  `delivery_mode "none"`; "a failed run whose runner dies after its final
  write releases the job and fails the failure-text delivery" covers old
  check 15).

### JOB-4: `finalize_job` overwrites a pause or resume that lands mid-write
- **Severity:** low. The window is one Repo round trip, longer when the Repo
  is busy. The owner is told the opposite of what happens.
- **Status:** fixed (d514e149).
- **Checks:** 16 and 17 hold; 23 and 24 (`needs AtomicSettle`) break with the
  fix switched off. Before the fix checks 16 and 17 were `violated JOB-4`.
- **Counterexample (before the fix):**
  - Old check 16: `finalize_job` reads the job (`enabled`, `running`). The
    owner's pause writes `paused`. `finalize_job` then upserts the row it
    read, with `running` changed to `scheduled`. The job is enabled again.
  - Old check 17: the same interleaving with a resume. The paused row it read
    is written back over the resume.
- **Code (before the fix):** `finalize_job` and `finalize_failed_job` called
  `get_scheduled_job`, then upserted the whole row (`runner.ex:392-404`,
  `:445-457`). The crash path's job write had the same shape
  (`scheduler.ex:859-869`, `:896-906`).
- **Fix:** the settle's release is one column-targeted `UPDATE`
  (`release_settled_job`, `repo.ex:6413-6438`): `running` becomes `scheduled`
  and any other state is kept. It never writes `next_run_at`. It completes
  and disables a one-off only when that one-off's claim consumed it: the due
  claim (`scheduler.ex:736-738`) and a manual claim (`manual_claim_patch`,
  `:749-753`) both clear `next_run_at`, and an edit that sets a new instant
  writes it again. So an edit made mid-run that turns the job into a one-off,
  or moves a one-off, survives the release. Deciding "one-off" from the row's
  current `schedule_kind` alone would complete and disable such an edited
  job, and deciding it from the claim-time kind (the code before the fix)
  lost an edit of a one-off. No stale snapshot is ever written back.
- **Tests:** `scheduler_test.exs` ("a pause landing just before the run's
  release is kept", "a resume landing just before the run's release is
  kept", "an edit that turns a running recurring job into a one-off is kept
  by its release", "a manual run of a one-off keeps the instant an edit set
  while it ran", "run_now of a one-off before its instant runs it and is
  done"), `repo_jobs_queries_test.exs` ("keeps a pause that landed mid-run",
  "keeps a one-off an edit set while the run was in flight").

### JOB-5: a claim refused as `:already_running` re-arms the due timer at 0 ms
- **Severity:** medium. An ordinary owner action could start a hot loop
  against the shared Repo that lasted up to the run's timeout.
- **Status:** fixed (d514e149).
- **Checks:** 18 holds; 19 (`needs RefusalBacksOff`) breaks with the fix
  switched off; witness 25 shows the refusal is reachable. Check 18 folds in
  the environment of old check 19 (runner crashes, three fire times). Before
  the fix checks 18 and 19 were `violated JOB-5`.
- **Counterexample (before the fix):**
  - Old check 18: a run is claimed, and the owner resumes the job mid-run. The
    job row now says `scheduled` while the run is active. Once `next_run_at`
    passes, the due claim is refused as `:already_running`, and the tick
    re-arms at 0 ms, again and again until the run ends.
  - Old check 19 needed no owner: an earlier run crashed at `mark_delivery`
    while the next run was active, and the crash path's job write turned
    `running` back into `scheduled`. The atomic settle removed that trigger
    (the pending-delivery reap no longer writes the job row).
- **Code (before the fix):** `:already_running` returned `{:ok, state}`
  (`scheduler.ex:565-566`), so the tick outcome stayed `:ok` and
  `due_delay_ms` floored a past-due job at 0 ms (`:1053-1060`), contradicting
  `:37-40` and `:1048-1050`.
- **Fix:** `{:error, :already_running} -> {:busy, state}`
  (`scheduler.ex:579-583`): a due job whose previous run is still active is
  backpressure, and the re-arm floors at the 5 s backoff. The job is claimed
  within 5 s of that run settling. The comments at `:38-42` and `:1004-1007`
  name the case. The rule is now checked as an action property: the `Arm`
  step that ends a refused claim's callback never arms the 0 ms timer.
- **Tests:** `scheduler_test.exs` ("a due claim refused because the previous
  run is still active re-arms at the backoff floor").

### JOB-6: a delivery recorded as `failed` may have reached the user
- **Severity:** low. The run row is wrong. Nothing is re-sent.
- **Status:** accepted by design (at-most-once, `channel_send.ex:140-143`).
  A `failed` delivery means "not confirmed delivered", and its
  `delivery_error` says which case it was: `:delivery_timeout`, `runner
  crashed: ...`, or `reaped: no live runner (daemon or scheduler restart, or
  a memory store that answered too late)`. Retrying on an unknown
  outcome would duplicate messages on platforms that do not dedupe; recording
  `failed` is what keeps check 03 (`DeliveredAtMostOnce`) true.
  `FailedMeansNotDelivered` is a rule Fermix deliberately does not make.
- **Checks:** 20 (13 states), 21 (16 states). Both stay `violated JOB-6`; the
  settle made each path two states shorter.
- **Counterexample:**
  - Check 20: the platform takes the final text, but its answer does not
    arrive before `delivery_timeout_ms`. The watchdog kills the send and
    `mark_delivery` records `failed`.
  - Check 21: the send succeeds, then the runner dies at `mark_delivery`
    without its write landing, and the crash path marks the still-pending
    delivery `failed`. Under the late-write model, a call timeout there would
    land `sent` late (the reaper then sees a final delivery), so this path
    needs the write never to land. In the code that is the Repo refusing
    the write (a full disk, say): `mark_delivery` exits the runner with
    `{:delivery_status_write_failed, "sent", nil, reason}`
    (`runner.ex:397-403`, 232508bc), and the Scheduler's
    DOWN path fails the pending delivery at once with that cause
    (`scheduler.ex:235-246`, `:855-857`). When a failed send's `"failed"`
    write is the one refused, the platform's error rides in the third
    element, so that cause survives too. Before that change `mark_delivery`
    logged the error and exited `:normal`, so the DOWN only cleared the
    monitor and the reconcile pass (widened by JOB-2) later reaped the row
    with the generic `reaped: no live runner` text. A Repo that still
    refuses writes when the DOWN arrives fails the crash-path write too. One
    that does not answer the DOWN's run lookup within 5 s leaves the row
    unmarked while the Scheduler carries on (`scheduler.ex:824-827`;
    `ReapLookupTimeout`, witness 31). Either way a later reconcile pass
    settles the row with the generic text, which now also names that cause:
    `reaped: no live runner (daemon or scheduler restart, or a memory store
    that answered too late)`. The runner's own cause then survives only in the
    log. The model's crash at `mark` with no late write stands for each of
    these, and for a kill of the runner alone; the rows end the same.
  - A third path came with JOB-2's fix, outside these checks: the daemon dies
    after the platform took the message, and boot reconciliation reaps the
    pending row as `failed`.
- **Code:** `ChannelSend.with_timeout` cannot tell whether the platform
  already took the message (`channel_send.ex:238-239`, `:284-300`, `runner.ex:377-378`).
  `mark_pending_delivery_failed` (`scheduler.ex:876-889`) assumes an
  unrecorded send failed.
- **Owner question:** keep `failed` (recommended), or add a separate
  `unconfirmed` delivery status? A new status is a wire change through
  `job_runs`, the management export and the macOS app.

### JOB-7: an owner's whole-row write reverts a run's release
- **Severity:** medium. An ordinary edit can wedge a job permanently, with no
  crash; the window is milliseconds.
- **Status:** fixed (d514e149).
- **Checks:** 26 holds; 27 (`needs OwnerWritesColumns`) breaks with the fix
  switched off. The model's `UpdateRead`/`UpdateWrite` is `update_job`;
  switched off, the write puts back the enabled, state and `next_run_at` it
  read.
- **Counterexample (check 27):** a run is claimed (`running`). `update_job`
  reads the row. The run settles and releases the job (`scheduled`).
  `update_job` then upserts the row it read, writing `running` back. No row is
  queued/running, so nothing ever releases the job: JOB-1's outcome from an
  ordinary edit. The same whole-row write straddling a claim put `scheduled`
  and a stale `next_run_at` over the claim's `running` (JOB-5's state), and
  pause and resume reverted the `last_*` columns a concurrent release wrote.
- **Code (before the fix):** `update_job`, `pause_job` and `resume_job` read
  the row and upserted all of it (`registry.ex:76-105`, `:128-151`), and
  `upsert_scheduled_job_row` writes every column.
- **Fix:** `Repo.update_scheduled_job_fields/3` (`repo.ex:2351`,
  `:6652-6659`) writes only the given columns in place and returns the row.
  It accepts only the owner-editable fields (`repo.ex:7498-7539`), never
  `last_*`, and raises in the caller on anything else. Pause writes `enabled`
  and `state`; resume writes `enabled`, `state` and `next_run_at`;
  `update_job` writes only the edited columns, never `state`, `enabled` or
  `last_*` (`registry.ex:129-152`).
- **Tests:** `registry_test.exs` ("owner writes racing a run's release":
  `update_job` and resume each keep a release that lands between their read
  and their write; pause, which reads nothing, writes only `enabled` and
  `state` and keeps a release that lands just before its write).

### JOB-8: an AgentLoop survives a restart of the job subtree and runs beside the next run
- **Severity:** medium. It needs a restart of the job subtree mid-run, which
  is rare, but a job's side effects (a post, an edit of a file) then happen
  twice, and the first run's answer is never recorded or delivered.
- **Status:** fixed (232508bc).
- **Checks:** 01 holds; 29 (`needs LoopDiesWithRunner`) breaks with the fix
  switched off. Before the fix there was no check: the daemon-crash fold
  killed every job process, so check 01's pass did not cover it. The holds
  checks' state counts are unchanged, since with the switch on no loop is
  ever stray.
- **Counterexample (check 29, 16 states):** a run is claimed, started and
  enters its AgentLoop. The job subtree restarts (a `DaemonCrash` step), which
  kills the runner and leaves its loop running. The restarted Scheduler's
  init reaps the run (`error`, job released). At the next fire time the due
  tick claims a second run while the first run's loop still runs: two active
  runs of one job.
- **Code (before the fix, at `35a6acdc`):** a crash of any core child started
  before `JobRunnerSupervisor` restarts the job subtree under `:rest_for_one`
  (`application.ex:179-330`, `:381`): not only `Memory.Repo` and the children
  after it, but also `CommandHostSupervisor`, `Finch`, `Trace`,
  `TokenSupervisor`, `CapabilityRegistry`, `McpSupervisor` and the rest. The
  runner dies with its supervisor, but its AgentLoop was `spawn_monitor`ed,
  not linked (`runner.ex:1024`), so it kept running tools, bounded only by
  `max_iterations` and per-call timeouts: the wall-clock and inactivity
  watchdog lives in the runner (`runner.ex:1041-1092`). Its media sends stayed
  possible, since only the runner clears the MediaBridge flag
  (`runner.ex:205-209`), up to MediaBridge's run deadline and send cap
  (`media_bridge.ex:158-199`). The restarted Scheduler reaped the run and
  could claim the job again.
- **Fix:** the runner spawns its loop linked and monitored in one call, the
  pattern of REMIND-2's `ChannelSend.monitored_call`
  (`runner.ex:1026-1030`). The loop body reports its own raise, throw or exit
  as `{:error, {:agent_loop_exit, reason}}` and logs it bounded
  (`report_loop`, `:1037-1054`), so the loop always exits `:normal` and the
  link carries only runner to loop: a loop crash still fails the run through
  the runner's own path. The runner unlinks on the loop's answer
  (`release_loop`, `:1056-1061`) and before the watchdog's kill
  (`kill_loop`, `:1119-1131`), so neither can take the runner down.
- **Residual:** a process the loop links to itself can still kill it with an
  exit signal, and the link then takes the runner down too; the Scheduler's
  DOWN path settles that run as `runner crashed`. That run delivers no
  failure text (a run still `running` has delivery `none`) and emits no
  `run_error` after its `run_start`, since the crash path emits no job
  telemetry; before the fix the same death failed cleanly as
  `{:agent_loop_exit, reason}`, with both. A runner killed in the few
  instructions between `kill_loop`'s unlink and its kill leaves the loop
  unlinked, the same residual as `ChannelSend`'s `kill_and_drain`.
- **Tests:** `runner_test.exs` ("a runner shut down mid-loop takes its
  AgentLoop with it"; "an AgentLoop crash fails the run and the runner still
  exits normally"; the watchdog tests, which kill a linked loop and still
  expect the runner to exit `:normal`).

## Assumptions

- Every Repo call completes, or its caller dies, or, for the Scheduler, it
  times out and the Scheduler takes that call site's error branch. SQLite
  busy/errors are not modelled otherwise. A `:busy` claim would take the 5 s
  backoff instead.
- A caller that dies at a Repo write may have its write land late, modelled at
  the runner's final write and the reaper's write (see late writes). Elsewhere
  a crash right after a step already stands for that step's late write. A
  Scheduler write that times out lands in the timeout step.
- A timed-out Scheduler scan or claim re-arms the backoff timer at once: the
  re-arm's own lookup is folded in, since with the tick's outcome `:error` the
  code arms no sooner than 5 s whatever it returns, and the model's backoff
  timer fires whether or not the job is due.
- A runner dies only at a Repo call or a file write, never while it waits in
  `receive` on a send; nothing in its own code raises there. While it waits
  on its AgentLoop, the loop reports its own crash as a value. The one death
  left there (a process the loop links to itself killing the loop, and through
  the link the runner) leaves the rows the `Loop` step and then a crash at
  `complete` or `fail` leave.
  - The `{:ok, _} = write_run_artifact` writes (`runner.ex:318`, `:476`) are
    folded into the final write, so they share the `complete` and `fail`
    crash points.
  - After a loop error, the memory-source calls between the settle and the
    send are folded into the settle; a crash there is `RunnerCrashLate` at
    `fail`.
- The settle's `:run_not_active` refusal is unreachable in the model: the
  reaper only settles the run of a dead runner, and a dead runner's late write
  was queued before the reaper's read.
- `delivery_mode` `"none"`/`"local"` behaves like a `[SILENT]` result: the
  initial status is final at once (`delivery.ex:24-31`, `:82-84`).
- The folded steps listed in the spec header. The folds drop only
  interleavings whose outcome the unfolded code also reaches.
- The daemon crash also stands for a crash of any core child started before
  the `RunnerSupervisor`, or of the `RunnerSupervisor` itself. The model
  kills every job process then; with `LoopDiesWithRunner` off, a runner's
  AgentLoop survives it (JOB-8).
- The access gate is outside the model. A run's access-sensitive tool call
  that its job row does not name is refused inside the one `Loop` step; a
  scheduled run never parks a call for the owner (`access_gate.ex:487-512`).
  An owner edit, resume or run now of a job naming such a tool, from a turn
  that could not run it directly, is refused by the tool before any registry
  write or Scheduler call (`job_registry_support.ex:36-41`): a request the owner
  never made. That check's job-row read feeds no modelled column. The store
  of parked confirmations (`Capabilities.AccessGate.Pending`,
  `application.ex:340`) and the holder of a conversation's place records
  (`ReplyBlocks`, `:344`, which no job process reads) are two more core
  children started before the `RunnerSupervisor`, so a crash of either is the
  daemon crash above.
- The run-row value `unset` stands for the `"none"` the claim writes before a
  result exists (`scheduler.ex:904`). The final `"none"` of `delivery_mode
  "none"` is modelled as `skipped`.
- The due timer is modelled from the row as it is now. The code arms it once
  and re-arms it on `:job_changed`, not when a settle releases the job. So the
  model's `DueTimerFires` can tick earlier than the code. The verdicts
  survive: the 60 s reconcile tick runs the same scan, may fire at any point
  and is strongly fair. A backoff timer fires whether or not the job is due,
  which is also only earlier than the code.
- With both run ids in use, a claim or "run now" is treated as not due. This
  is the model's bound, not code behaviour.
- The admission ceiling (4 runs) is never reached by one job. Expiry,
  one-shot jobs, an unparseable schedule and the stale-skip are not modelled.
  The Scheduler's own whole-row writers on those paths (`advance_stale_job`,
  `expire_scheduled_job`, `disable_job`) are therefore not modelled either.
- An owner edit is modelled as one that writes no modelled column (a task,
  description, pin or delivery edit). A schedule edit also writes a fresh
  `next_run_at`, which the column-targeted write keeps as the owner meant,
  and so does the settle's release: it never writes `next_run_at`, and it
  completes a one-off only when the one-off's claim consumed it (JOB-4's
  **Fix**), so an edit into a one-off, or to a new instant, made mid-run
  still fires.
- A watcher's task (`CueTask`): its passed deliveries are a count, claimable
  at once and never expiring; the subject rule, the daily cap, the retry
  delay (`ready_at`), the lifetime (`valid_until`) and the attempt count are
  `tla/specs/cue_inbox`'s, so a failed cue run's retry is a free choice. The
  watcher's own `enabled` is not part of the claim's rule (design §8.8). The
  cue share of the ceiling (three) and the ceiling itself (four) never bind
  one job, so the candidate scan runs whenever the Scheduler's last reconcile
  scan succeeded; after one that failed, admission counts no free slot and
  makes no call (`runsKnown`). The cap notices the candidate scan triggers (a
  task under the `TaskSupervisor`) send nothing this spec models.
- A watcher's follow-up (`FollowUp`): its starting triggers are a count,
  each written with its wake; how a trigger gets there (freshness, the daily
  cap, one waiting card, the owner's answer on a card, its expiry) is the cue
  side's. The hold check before each claim (`FollowUps.check`: the tools not
  ready, the automatic approval cleared, the switch off) refuses a trigger
  without touching the job, as the claim's own refusal does, so it is left
  out; so are the card offers before the trigger scan and the task that
  tells the owner of a refused trigger, which write nothing modelled. The
  cue share never binds one job: a claim needs a free run id, so at most one
  runner is alive and at most one cue-share run is monitored, which leaves
  at least two slots, and the one job takes at most one run per pass. A
  pass reads at most ten triggers, more than the checks ever write.
- The reaper's report task dies only with the daemon. Its other death, a Repo
  call that times out and exits it (it passes no `on_timeout`), leaves the
  rows a daemon crash at the same point leaves: nothing sent and no delivery
  recorded before its pending mark lands, a `pending` row the reconcile pass
  marks `failed` after.
- A cue tree that crashes and restarts on its own makes `Cues.running?/0`
  false for a moment, so a request or an admission in that window is
  skipped; the next tick admits, as after a Scheduler restart. `CuesOn` is a
  constant: that window is not modelled.
- Fairness: weak on each runner's, send helper's, report task's and Scheduler
  callback's next step, and on the runner's delivery timer. Strong on the
  Scheduler serving its mailbox and its own timers. None on the clock, the
  owner, the cue inbox, the platform or crashes.
