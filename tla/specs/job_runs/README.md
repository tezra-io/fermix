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

Since M106 the settle also decides the job's retry in that transaction, and
the due scan claims a pending retry through the same claim. A failure no
retry takes goes to a heal and sends nothing, unless the job was set up by a
guest. Since M106 §6 an ok run whose tool never once worked, as in the
job's two runs before it, goes to a heal too, its own row ok and its text
delivered. The heal's own rows are left out; its run's one move on the job
(a pause, a raised time limit or a "run now") takes the owner's own path,
which the spec models; since M106 S4 that move is one guarded write, which
checks 73 to 76 model (see "Heal moves (M106 S4)"). Checks 61 to 72 cover
retries; see "Retries (M106)"
below, "Re-read for M106 retries and heals", "Re-read for the heal's
diagnosis and moves" and "Re-read for runs that end ok without working".

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
  `application.ex:336-420`) or of the `RunnerSupervisor` itself, since
  `:rest_for_one` restarts every job process in each case (`:209`). A
  runner's send helper and its AgentLoop are linked to it, so none outlives
  the restart; `LoopDiesWithRunner` off lets the loop outlive it (JOB-8).
- `SchedulerCrashes`: how many times the Scheduler alone may die, at any point
  of any callback, including its own init. A Repo timeout no longer kills it
  (`SchedulerTimeouts`); another cause still does, such as `:rest_for_one`
  restarting it when `MeetingsSupervisor`, started between the
  `RunnerSupervisor` and the Scheduler, dies (`application.ex:421-428`).
  Runners keep running. When it dies waiting on the reaper's write, that write
  may still land (see late writes).
- `SchedulerTimeouts`: how many of the Scheduler's Repo calls may time out.
  Every call its process makes passes `Repo.periodic_opts` (`on_timeout:
  :error`, `repo.ex:1252-1254`, `scheduler.ex:171-174`), so a call the Repo
  does not answer within 5 s returns `{:error, :repo_timeout}`
  (`repo.ex:4455-4463`). The Scheduler takes that call site's error branch and
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
- `ToolsCanStart`: a run's AgentLoop may start a tool before it ends
  (`ToolStarts`). The tool runs in the loop's process, whose gate first
  stores its start on the run row, in the same step (JOB-9's fix; without
  `StampsToolStart` the runner stores it later, `StampsTool`). `FALSE`:
  every run ends before any tool, which is what checks 01 to 60 assume.
- `ProviderCanFail`: a loop error may be one waiting can clear, the
  provider's (`failure_settle_by`), which the runner's settle may retry.
  `FALSE` (checks 01 to 60): no loop error is the provider's, so only the
  reaper's settle retries.
- `StampCanFail`: the store refuses a run's first tool start (an error, or no
  answer within the Repo's bound). The gate then runs no tool and the loop
  ends in `{:tool_start_unrecorded, _}`, a failure no retry takes. `FALSE`:
  the store always records it. Checks 61, 62, 63 and 72 set it `TRUE`.

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
  `starting`: an item passing an always-allowed follow-up's watcher writes
  one in the pass's transaction, and the owner's Run or Always allow on a card
  moves one from `waiting`; either wakes the Scheduler. Each admission pass, after the
  re-arm and before the cue runs, reads them (`{:starting_triggers, 10}`)
  and claims each (`Repo.claim_follow_up_run`: in one transaction the
  trigger read while `starting`, the job taken `running` through
  `claim_in_tx`, the run inserted with `trigger: "watcher"`, the trigger
  moved to `started`). A job that cannot take the run, paused, gone or still
  running, refuses the trigger in that same transaction, so a trigger never
  waits behind a run. The claimed runs start once every trigger the scan read
  is done. A follow-up run then runs, settles and delivers as a cron run
  does. Checks before 54 set it `FALSE`.
- `GuestJob`: the job was set up at guest trust, so a failure no retry takes
  sends its failure text as before (`finish_failure`'s `:out_of_scope`
  clause). `FALSE`: the owner's job, whose failure a heal takes: the run only
  marks its delivery `skipped`. Checks 01 to 60 set it `TRUE`, so their
  failure text is sent as it was before M106; checks 61 to 72 set it `FALSE`.

**Late writes.** `Memory.Repo` serves one request at a time. A call it does
not answer within 5 s (`Timeouts.repo_call`, `timeouts.ex:225-229`) times out,
but the request stays in the Repo's mailbox and lands later, still before any
later request from the same caller (`repo.ex` `call/2`). `PRAGMA
busy_timeout=5000` (`repo.ex:4495`) equals that budget, so one SQLite lock
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
  - The claim (`Repo.claim_due_job`, `:729-731`; `ClaimTimeout`) and "run
    now"'s claim (`Repo.claim_job_now`, `:765-770`; `ManualRunTimeout`). A
    claim the Repo had started still lands when it would have (one it turned
    away unrun writes nothing and leaves what a timed-out due scan leaves,
    `ScanTimeout`, or "run now"'s first branch), but no runner starts and
    nothing monitors the run: a queued run with no runner holds the job (`running`)
    until the next 60 s reconcile pass reaps it with `reaped: no live runner
    (daemon or scheduler restart, or a memory store that answered too late)`
    (`:69-73`). That occurrence never runs. A restart would have reaped it in
    init at once. Witness 30 reaches this.
  - The run lookup in `mark_run_failed` (`Repo.get_job_run`, `:968-971`;
    `ReapLookupTimeout`). After a DOWN the monitor is already gone, so the dead
    runner's run keeps its row: a queued/running row holds the job, and a
    pending delivery stays pending, until the next reconcile pass reaps it with
    the generic text instead of `runner crashed: ...`. In a reconcile pass
    the orphan waits for the next pass. Witness 31 reaches this.
  - The reconcile scan (`Repo.unsettled_job_runs`, `:503-509`;
    `ReconcileRowsTimeout`): the pass reaps and adopts nothing. After a
    restart, a live runner then stays unmonitored until the next pass, so its
    crash sends no DOWN. The run set is unknown until a scan succeeds, so no
    cue run starts meanwhile.
  - The due scan (`:583-585`; `ScanTimeout`), and the timer lookup
    (`Repo.next_scheduled_job`, `:1156-1160`; `ArmTimeout`): nothing is written
    and the due timer is armed at the 5 s backoff. After a timed-out scan or
    claim the tick's outcome is `:error`, so its re-arm floors at the backoff
    whatever its own lookup returns; that re-arm is folded into the timeout
    step. "Run now"'s lookup (`:740-742`) replies the error and writes nothing.
- Folded into an existing step, because the outcome is the same: the reaper's
  write (`Repo.settle_job_run` or the pending-delivery upsert, `:1034-1050`,
  `:1073-1086`) lands late, before the Scheduler's next call, and its error
  branch only logs and skips the memory-source mirror (`:1047-1048`,
  `:1081-1084`), which the spec does not model. That is `ReapRun`. The
  `:run_not_active` re-read is unreachable, as before. Adopting a live runner
  and starting one make no Repo call.

The bounds are constants too: `NumRuns`, `Fires`, `SendAttempts` (3 in the
code, 2 in the checks), `OwnerMoves` (pause/resume requests), `OwnerEdits`
(`update_job` requests), `ManualRuns` and `HealMoves` (a heal run's move on
the job, 0 or 1: 0 in every check before 73).

**Mechanism switches** (`TRUE` is the real code; each is switched off by the
checks listed under it):
- `AtomicRaceStop`: the claim transaction refuses while a run is queued or
  running (`ensure_no_active_job_run`, `repo.ex:7006`, `:7059-7077`), the due,
  manual and follow-up claims alike (`claim_in_tx`, `repo.ex:7798-7805`), and
  the retry's claim (`claim_retry_job_tx`, `repo.ex:8314-8323`). Checks 02,
  55 and 69.
- `RetriesOnlyUnsent`: a send is retried only when it never reached the
  platform (`channel_send.ex:140-143`, `:194-202`). This is the mechanism for
  platforms that do not dedupe. The runner tags its send with the proactive
  key `job:<run id>` (`runner.ex:1685`). The mobile channel keeps one row per
  key (`mobile_sql.ex:44-46`), so a retry there would not show twice. Check 04.
- `ReconcilesRuns`: at init and every 60 s the Scheduler reaps unsettled runs
  with no live runner and adopts live ones (`scheduler.ex:235`, `:270-540`).
  Checks 07, 28, 33 and 60.
- `CrashFailsPendingDelivery`: the crash path marks a dead runner's pending
  delivery failed, whatever the run's status (`scheduler.ex:1056-1058`,
  `:1077-1090`). Check 09.
- `DeliveryWatchdog`: the runner stops waiting for a send after
  `delivery_timeout_ms` (`channel_send.ex:219-241`). Check 05.
- `AtomicSettle`: a run's final row and its job's release are one
  transaction, `Repo.settle_job_run` (`repo.ex:2563-2566`, `:7015-7031`, `:7091-7138`), used by
  the runner (`runner.ex:362`, `:508`) and the reaper (`scheduler.ex:1038-1054`).
  The release is a column-targeted `UPDATE` that turns `running` back into
  `scheduled` and keeps any other state. Switched off, the spec runs the code
  before the fix: the run row alone, then a read and a whole-row upsert of the
  job row, in the runner and in the reaper. Checks 12, 22, 23, 24 and 70.
- `ReconcilesPending`: the reconcile pass reads every unsettled run, the
  queued/running rows and then the rows whose delivery is still pending
  (`unsettled_job_runs`, `repo.ex:2602-2655`; `scheduler.ex:496`). Switched
  off, it reads queued/running rows only. Checks 14, 15, 35.
- `RefusalBacksOff`: a due claim refused as `:already_running` returns
  `{:busy, state}`, so the re-arm floors at the 5 s backoff
  (`scheduler.ex:721-725`, `:1211-1217`). Switched off, the refusal counts as a
  clean drain and a past-due job re-arms at 0 ms. Check 19.
- `OwnerWritesColumns`: pause, resume and `update_job` write only the columns
  they own, in place (`registry.ex:324-359`;
  `Repo.update_scheduled_job_fields`, `repo.ex:2506-2509`, `:7286-7293`, the owner
  field list `:8096-8134`). Switched off, pause and `update_job` upsert the
  whole row they read. Check 27.
- `LoopDiesWithRunner`: a runner's AgentLoop is spawned linked to it and
  reports its own crash as a value (`runner.ex:1322-1326`, `:1338-1355`), so a
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
- `RearmsOnDown`: every runner's DOWN, a normal exit or a crash, re-arms the
  due timer for the earliest wakeup, a retry's included (`handle_info({:DOWN,
  ...})`, `scheduler.ex:335-362`). Switched off, the code before M106: a
  normal DOWN only drops the monitor and a crash's callback ends after its
  reap. Check 67.
- `StampsToolStart`: a run's first tool start is on its row before the tool
  runs. AgentLoop calls the runner's gate in the loop's own process ahead of
  each call (`gate_tool`, `agent_loop.ex:1396-1457`), and the gate stores the
  start in one Repo call (`put_tool_start_store`, `runner.ex:1728-1767`); a
  start it cannot store runs no tool. Switched off, the order before JOB-9's
  fix: the tool runs, and the runner stores its start when it handles the
  loop's message. Check 62.
- `RetryNeedsNoTool`: `Retry.decide` retries only a run in which no tool had
  started (`retried?`, `retry.ex:88-89`), from what the runner knows in its
  own settle and from the row in the reaper's. Check 72.
- `OwnerClearsRetry`: pause, resume and `update_job`
  (`update_scheduled_job_fields_row`, `repo.ex:8820-8834`) and run now
  (`claim_job_now_tx`, `:8303-8312`) delete the job's retry in their own
  transaction. Check 65.
- `HealMoveGuarded`: a heal run's move (a pause, a raised limit) is one
  transaction that writes the job only while it is still the version the
  move was drawn for (`heal_job_write_tx`, `repo.ex:9030-9064`). Switched
  off, the S3 shape: the move is written whatever the job became during the
  diagnosis. Check 74.
- `MarksOwnerWrites`: every owner write marks the job's diagnosing heal,
  whatever value it leaves, the heal's claim clears the mark, and a heal
  run's move under a marked heal is not made (JOB-12's fix). Switched off,
  the version compare alone: the first S4 code. Check 76.

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

Checks 08, 43 and 53 then sat at 60 to 80 s and timed out when TLA runs
overlapped. Two narrowings that leave each verdict and what it covers as it
was brought them to 35 s, 35 s and 17 s (from 78 s, 73 s and 61 s):
- Checks 43 and 53, and their `needs` checks 44 and 38, run with no fire
  time. `Due` is false for a watcher's task, so the clock drives none of its
  steps, and a tick only doubled the states (43: 2,926,878 to 1,463,439; 53:
  91,342 to 45,671).
- A configuration with no owner request leaves out `JobChanged`'s strong
  fairness, and one with no cue tree `CueAdmit`'s (`FairnessScope`). TLC
  splits a liveness check in two for each strongly fair action: check 08's
  liveness pass went from 54 s to 13 s, and check 53's from 39 s to 18 s
  before its clock went too.

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

**Retries (M106).** A failed run of an interval or cron job is retried
quietly when it failed before its first tool, on the provider or with no
runner left (§5.3). The settle decides it (`Retry.decide`) in its own
transaction, from the run row as written and the job as released, and keeps
it in `job_retries`: a pending retry is `retryAt`. The model takes a pending
retry as due at once (its time is always before the job's next fire time,
which the clock counts), and the attempt count, the ladder of delays and a
retry at or after the next run (no time) are a free choice of the settle.
The scan claims it by the retry when the job is not due by its next run
(`sBy`), through the claim every run takes, with `next_run_at` unmoved; the
due claim clears it too. Every property below is broken by its `needs`
check.
- **No retry is set for a run in which a tool had started**
  (`RetryOnlyBeforeTool`), with tools, a start the store refuses, provider and
  other loop errors, runner crashes (late writes included) and a Scheduler
  restart (check 61), and with a daemon crash added (check 63, JOB-9's
  setting). The runner's own settle knows whether a tool started; the
  reaper's settle reads the row, which holds the start before the tool can
  run. The first rests on the decision reading the start
  (`RetryNeedsNoTool`, check 72: a provider failure after a tool is
  retried); the second, across a daemon crash, on the start being stored
  before the tool runs (`StampsToolStart`, check 62: JOB-9's counterexample,
  the daemon dying between a tool's start and its stamp).
- **No pending retry outlives the owner's pause, resume, edit or run now**
  (check 64, `RetryClearedByOwner`), with provider and other loop errors,
  runner crashes, a pause or resume, an edit and a run by hand. This rests
  on `OwnerClearsRetry` (check 65: a run that fails and is retried, then a
  pause that leaves the retry pending).
- **A pending retry has its timer armed** (check 66, `RetryTimerArmed`):
  once no runner is left and the idle Scheduler has handled every DOWN, a
  pending retry of a claimable job has its due timer at 0 ms or the backoff.
  With provider and other loop errors, runner crashes (late writes
  included), a daemon crash, a Scheduler restart and a mid-run resume, and
  without Scheduler timeouts: after a reconcile scan that timed out, a
  runner the restarted Scheduler never adopted dies with no DOWN, and its
  retry waits for the 60 s tick. This rests on `RearmsOnDown` (check 67: a
  runner dies at its start, the reap sets a retry, and the Scheduler goes
  idle with the timer it armed while the job ran, none).
- **One active run, and a running job always has its run** (check 68,
  `OneActiveRun` and `RunningHasRun`), with retries from provider errors and
  crashes, tools, a mid-run resume, a run by hand, a daemon crash and a
  timed-out Scheduler Repo call. These rest on `AtomicRaceStop` (check 69)
  and `AtomicSettle` (check 70: the split finish leaves the job `running`
  once its run row is final).
- Witness 71 shows a retry claim is reached: the scan finds the job due by
  its retry alone, and the claim will take it.

**Heal moves (M106 S4).** With `HealMoves = 1` a heal run reads the job
before its diagnosis (`HealRead`, its plan's kind and the job's version as
read) and later makes its one move (`HealWrite`), beside a run, its loop's
errors, the owner's pause or resume and an edit.
- **A heal's raised limit never lands over an owner edit that still
  stands** (check 73, `HealNeverOverwritesEdit`, 69,561 states). This rests
  on `HealMoveGuarded` (check 74, the S3 shape). The owner reads the job for
  an edit, the heal run reads it, the owner's edit lands, and then the
  raise drawn from the earlier read lands over it: the stale read a review
  found.
- **A heal's pause never lands after an owner resume made since its read**
  (check 75, `HealPauseNeverUndoesResume`, 69,561 states). This rests on
  `MarksOwnerWrites` (check 76: JOB-12's 4-state counterexample, a resume
  that leaves the job as read, which the version compare alone cannot
  see).

In every other check `HealMoves = 0`. There a heal run's move is still
covered by the owner's steps, since a move that lands writes what an atomic
`Pause` or an edit writes (retry cleared, no other modelled column), and a
move that does not land writes nothing.

"A retry never moves `next_run_at`" is not a check. In this clock a job
that is not due always has `next_run_at` at the next fire time (`now + 1`),
which is also what a claim's patch writes, so a retry claim that moved it
could not be told from one that did not. `Claim` keeps it as it is, as
`claim_and_start_retry`'s patch, which carries no `next_run_at`, does.

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
  `application.ex:399`, after `JobRunnerSupervisor`, `MeetingsSupervisor` and
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

## Re-read for Always allow (2026-10-31)

- **The owner's edit clears a stale Always allow.** Re-read against
  `2dd0e88c`. A follow-up's automatic mode is gone
  (M60_WATCHER_CODING_RUNS.md §14): it asks first until the
  owner's Always allow on one of its cards, bound to the same digest the
  automatic approval was. `update_scheduled_job_fields_row` still runs the
  edit and the clearing of an approval it made stale in one `BEGIN
  IMMEDIATE`, now through `CuesFollowUpAllowSql.clear_stale_approval/2`: the
  same Repo call writing the same columns. A trigger an always-allowed
  follow-up's pass writes is `starting`, as an approved automatic one's was,
  and the owner's Always allow on a card moves one `waiting → starting` as
  Run does, so `starting` and the claim (`claimable`, `mark_started`,
  `refuse_starting`, unchanged) are as before. No step moved.
- **Line numbers** were moved through the diff, so each moved reference
  points at the same line it did.

## Re-read for a message's origin (2026-11-02)

A run's message now names where it came from, the send option `origin` the
Mac's and the phone's timeline store as `metadata.origin`. It staled
`runner.ex`, `delivery.ex` and `report_final_failure` in `cue_run.ex`.
`Delivery.put_origin/3` is a pure function on the send options; the runner
builds them once more for the final text and the media route
(`send_opts/1`, from the job, or the watcher its cue or trigger names, read
at the run's start as before), and the reaper's report adds its watcher's
name from the context it already loaded. No Repo call, step, row, helper,
delivery or report changes, and nothing moved below a line the spec cites,
so nothing the spec models changed.

## Re-read for earlier messages' origin (2026-11-02)

The core tree gained `Companion.OriginBackfill`, a `:temporary` task between
the skill-curation scheduler and the snapshot scheduler that fills in
`metadata.origin` on timeline rows a job's or a cue's run wrote before it
existed. It staled the `application.ex` pin. The task reads a run's trigger,
the job's name it recorded, the job's name now and the watcher its delivery
or follow-up trigger names, and writes only a timeline row's metadata: no
claim, settle, release, reconcile or delivery. `JobRunnerSupervisor` and
`JobScheduler` keep their order, and the task's own exit restarts nothing,
so nothing the spec models changed.

- **Line numbers** were moved through the diff, so each moved reference
  points at the same line it did.

## Re-read for the computers' registry (2026-11-10)

The core tree gained `Computers.Registry` (M97), a primary-only process
between `Companion.OriginBackfill` and the snapshot scheduler that keeps what
the home's computers offer, in files under `device/computers/`. It staled
the `application.ex` pin. It starts after `JobScheduler` and the temporal
rail, so a crash of it restarts only the snapshot scheduler and the cue tree,
and it reads and writes no job, run or delivery row. `JobRunnerSupervisor`
and `JobScheduler` keep their order, so nothing the spec models changed.

- **Line numbers**: the comments' `application.ex` numbers had drifted
  before this change (`:183` named a sidecar call, not the strategy at
  `:185`); they now point at the committed file.

## Re-read for the server's calls and the release table (2026-11-10)

The core tree gained two primary-only processes (M97) between
`Computers.Registry` and the snapshot scheduler: `Computers.Calls`, the
invocations the server waits on from the home's computers, and
`Home.ReleaseTable`, the release table an Always On server's update chooses
from. It staled the `application.ex` pin. Both start after `JobScheduler`
and the temporal rail, so a crash of either restarts only what follows it
(the snapshot scheduler and the cue tree), and neither reads or writes a
job, run or delivery row. `JobRunnerSupervisor`, `MeetingsSupervisor` and
`JobScheduler` keep their order, so nothing the spec models changed.

- **Line numbers**: the commit's new alias moved every cited
  `application.ex` line down by one, and the cue tree's by nine; the comments
  point at the committed file.

## Re-read for a computer's screen and Messages (2026-11-11)

The server's use of a computer's screen (M97 §6.4, `26196634`) staled the
`application.ex` pin. The computer-use supervisor now also starts on an
engine that drives a computer's screen or has its own driven by its server,
and `ComputerUse.Seat`, this computer's screen while its server drives it,
joins the tree beside it on a linked computer, never under `mix test`. Both
start after `JobScheduler` and the temporal rail, so a crash of either
restarts only what follows it (the computer-history supervisor through the
cue tree), and neither reads or writes a job, run or delivery row.
`JobRunnerSupervisor`, `MeetingsSupervisor` and `JobScheduler` keep their
order, so nothing the spec models changed.

- **Line numbers**: the commit's new alias moved every cited
  `application.ex` line down by one, and the cue tree's by two; the comments
  point at the committed file.

## Re-read for computer history on every computer (2026-11-11)

Computer history from every computer (M97 §8.1, `826ba83a`) staled the
`application.ex` pin. The computer-history supervisor is now started with the
engine's role: on every primary, whatever its platform (a Linux server
included), and on a device only where this system has a recorder. It keeps
its place after `JobScheduler` and the temporal rail, so a crash of it
restarts only what follows it (the origin backfill through the cue tree), and
it reads and writes no job, run or delivery row. `JobRunnerSupervisor`,
`MeetingsSupervisor` and `JobScheduler` keep their order, so nothing the spec
models changed.

- **Line numbers**: the change touched only that one child's line and the
  function below the tree, so every cited `application.ex` line is where it
  was.

## Re-read for the review's fixes (2026-11-11)

`c6fe1c48` staled the `application.ex` pin with two comments inside
`supervision_children`, one above the computers' record and one above the
computer-history supervisor. No child moved, so nothing the spec models
changed; the one cited `application.ex` line after them moved by one
(`:437`).

## Re-read for the Always On pane's engine half (2026-11-12)

`8e3f586f` staled the `application.ex` pin: `Home.MoveProgress` joins the
core tree after `JobScheduler`, the temporal rail and the computer-history
supervisor, so its crash reaches none of the job tree. Nothing the spec
models changed; the cited `application.ex` lines point at the committed
code.

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
open `tla/out/job_runs/<check>.txt`. JOB-10 and JOB-11 are the exception:
they were found by reading the code, lie outside the model and have no
counterexample. Their fixes rest on the tests named under them.

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
  - The claim sets the job to `running` (`repo.ex:6079-6086`,
    `scheduler.ex:723-727`). Only `finalize_job` (`runner.ex:389-413`), the
    crash path (`scheduler.ex:788-803`) and `resume_job`
    (`registry.ex:62-74`) ever set it back.
  - Each writer first made the run row final, then wrote the job row in a
    separate Repo call: the runner at `runner.ex:265` then `:402` (and `:346`
    then `:455`), the reaper at `scheduler.ex:791`/`:846` then `:896`/`:906`.
  - Reconciliation read only queued/running rows (`repo.ex:6420-6435`), so a
    run already marked `ok` or `error` was invisible to it, and the due scan
    and the timer lookup need `state = 'scheduled'`.
- **Fix:** `Repo.settle_job_run/2` (`repo.ex:2482`, `:6525-6594`) writes the
  final run row and releases the job in one `BEGIN IMMEDIATE` transaction, the
  mirror of the claim. It refuses with `{:error, :run_not_active}` unless the
  row is still queued/running, so only the run holding the job can release
  it. The runner's `mark_completed` and `mark_failed` call it
  (`runner.ex:275`, `:359`); `finalize_job`, `finalize_failed_job` and
  `final_job_state` are gone. The reaper settles a queued/running row as
  `error` through it (`scheduler.ex:837-853`); on `:run_not_active` it re-reads
  the row and settles only a still-pending delivery (`:861-874`). The old
  reaper job writers are gone. A one-time migration (version 31,
  `repo.ex:331-343`) releases every job an older release left `running` with
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
  (`repo.ex:6420-6435`, `scheduler.ex:259-264`).
- **Fix:** `Repo.unsettled_job_runs` replaces `active_job_runs`
  (`repo.ex:2491-2524`, `:6861-6865`): two index reads combined with
  `UNION ALL`, the queued/running rows first and then the rows whose delivery
  is pending, oldest first within each, under the same limit. A partial index
  (version 30, `idx_job_runs_pending_delivery`, `repo.ex:319-322`) keeps the
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
  (`release_settled_job`, `repo.ex:6577-6602`): `running` becomes `scheduled`
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
- **Fix:** `Repo.update_scheduled_job_fields/3` (`repo.ex:2425`,
  `:6816-6823`) writes only the given columns in place and returns the row.
  It accepts only the owner-editable fields (`repo.ex:7662-7703`), never
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
  (`application.ex:180-331`, `:382`): not only `Memory.Repo` and the children
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

### JOB-9: a crash between a tool's start and its stamp lets the reaper retry the run
- **Severity:** low. It needs the daemon, or the job subtree under
  `:rest_for_one`, to die in the moment between a tool's start and the
  runner storing it (one message and one Repo write), but then it breaks
  the rule the retry rests on: the retried run repeats what the tool did (a
  post, a message, a file written).
- **Status:** fixed (393cae162). Found by the M106 re-read below against the
  stage-2 code before it was pushed, and fixed in the same stage.
- **Checks:** 63 holds (it was `violated JOB-9 len=12`); 62 (`needs
  StampsToolStart`) breaks with the fix switched off, and its 12-state
  counterexample is the one below.
- **Counterexample (check 62, 12 states):** the due tick claims a run and
  starts its runner, which marks it running and enters its AgentLoop. A tool
  starts (`ToolStarts`): the loop's process has sent the runner its
  tool-start message and runs the tool. The daemon dies before the runner
  handles that message (`DaemonCrash`), so the row's `tools_started_at` is
  still empty. At boot the Scheduler's init reconciles: the run is
  `running` with no runner, so the reaper settles it `:scheduler`
  (`ReapRun`). `Retry.decide` reads `tools_started_at` from the row, finds
  none, and the job runs again, so the settle sets a retry: a pending retry
  for a run whose tool had started (`RetryOnlyBeforeTool` broken). The due
  scan then claims it with `trigger: "retry"`, and its loop runs the same
  task again.
- **Code (before the fix):** the loop's activity callback is a plain `send`
  from the loop's process, which then runs the tool (`run_agent_loop`,
  `runner.ex:1635-1642`); the runner stored the start only when it handled
  that message (`watch_loop`, `:1714-1724` → `stamp_tools_started`,
  `:1863-1882`, a Repo call). A daemon
  crash in between, a `:rest_for_one` restart of the job subtree, or the
  runner dying through a link its loop made (JOB-8's residual) leaves the run
  row with `tools_started_at` NULL. The reaper's settle (`mark_run_error`,
  `scheduler.ex:1153-1174` → `settle_job_run(_, :scheduler)` →
  `JobRetriesSql.settle/4`, `job_retries_sql.ex:43-57`) passes
  `tools_started?: not is_nil(run.tools_started_at)`, false, to
  `Retry.decide` (`retry.ex:72-92`), which retries a `:scheduler` settle of a
  job that runs again.
- **Fix:** the first tool start is stored before the tool runs, in the loop's
  own process. AgentLoop gained one opt-in option, `before_tool`: a gate it
  calls ahead of each tool call, before the call's `:tool_start` activity;
  `{:error, reason}` runs nothing, traces the call as the model's one
  unexecuted call, and ends the run with `{:error, reason}` (`gate_tool`,
  `run/1`'s catch, `agent_loop.ex:182-192`, `:1388-1423`). The runner's gate
  stores the run's first start with the existing compare-and-set
  (`Repo.mark_job_run_tools_started/3`, the Repo's ordinary bound) and
  returns `:ok`, or `{:tool_start_unrecorded, reason}` when the store did not
  record it: the tool never runs, and the run fails with a kind of its own,
  `tool_start_unrecorded`, which is no provider's failure, so it is never
  retried and goes to a heal (`put_tool_start_store`, `runner.ex:1683-1722`).
  The watchdog no longer stores anything; it keeps the timeline and the
  in-flight calls. A cue run has no gate: its marker is its mandate gate's,
  written in the mandate call's own transaction before the call acts
  (`tools_started_stamp`, `:1675-1681`). In the model `ToolStarts` is the
  start and its stamp as one step, or the store's refusal, which ends the
  loop with no tool (`StampCanFail`).
- **Tests:** `runner_tool_start_test.exs`: the stamp is on the row when the
  tool's executor is entered, with the runner's mailbox held (the runner
  process suspended); a run killed in its first tool, its runner's mailbox
  never drained, is settled by the Scheduler with the start and not retried;
  a start the store refuses ends the run before the tool, which is never
  entered, is not retried and opens a heal. `agent_loop_test.exs` ("run/1
  before_tool gate"): the gate runs ahead of the call's start and the tool;
  a refusal runs no tool and leaves one unexecuted tool event. Each of the
  runner's three failed on the code before the fix.

### JOB-10: a heal run that outlives a Scheduler restart loses its rerun
- **Severity:** low.
  - It needs the Scheduler alone to crash during the few minutes a heal
    run lives.
  - The owner has then been told that Fermix is running the job again, and
    no run comes. The heal watches for a next run that may be days away.
- **Status:** fixed (26f7e7414). Found by reading the stage-3 code in "Re-read for
  the heal's diagnosis and moves" below, and fixed in the same stage.
- **Checks:** none. The model has no heal run and no Scheduler name: a
  rerun that never starts is a "run now" never asked for, which every check
  already allows. The finding is outside the model, not a counterexample.
- **What happened:**
  1. A heal decided `rerun`, and its heal run sends the message.
  2. The Scheduler alone crashes and restarts. Under `:rest_for_one` the
     `RunnerSupervisor` before it keeps its children, so the heal run lives
     on and the new Scheduler adopts it.
  3. Its concluding write makes the heal `watching`, and then it asks the
     Scheduler that started it for the rerun. That process is dead: the
     call exits `:noproc`, which is caught and logged, and no run starts.
  4. A pause's or an edit's `:job_changed` cast to the same pid was
     dropped without a word.
- **Code (before the fix):**
  - `start_claimed_heal` gave the heal run `scheduler: self()`, and
    `start_rerun` called `Scheduler.run_now(pid, ...)`. It turned the exit
    into `{:error, {:scheduler_unavailable, reason}}` and logged "its rerun
    did not start".
  - The message sent before that said "Fermix is running it again now".
  - The owner's `run_job_now` reaches the Scheduler by its registered name,
    so it never had the gap.
- **Fix:**
  - The Scheduler keeps the name it is registered under (`start_link/1`
    hands it to `init/1` as `state.name`, `scheduler.ex:142-145`, `:195`)
    and gives heal runs `scheduler: state.name` (`:1355`). A heal run's
    "run now" and casts therefore reach whichever Scheduler holds the name.
  - `Scheduler.run_now/3` takes a `:timeout` (`:183-186`); the heal waits
    5 s, as `run_job_now` does.
  - The heal records once what came of the call (`heal_run.ex:425-601`;
    `rerun_outcome`, `job_heals_sql.ex:547-567`). One pure function,
    `HealRun.rerun_outcome/2` (`classify_rerun/2`, `heal_run.ex:489-539`),
    reads what came back. `start_rerun` keeps the check apart from the ask
    (`:446-464`): `check_rerun` runs `Registry.check_run_now/2` with any exit
    caught, and anything but `:ok` there is `{:not_asked, reason}`, so the
    Scheduler is never called. `ask_rerun` calls `Scheduler.run_now/3` and
    keeps an exit as it is. The outcomes:
    - `started`, for `{:ok, run}`;
    - `running`, for `:already_running` (a run already held the job, and
      its settle concludes the heal);
    - `refused`, only for what proves no run will come of this ask. It
      moves a heal still `watching` on its first conclusion to `waiting`
      on the owner:
      - `{:not_asked, _}`: the Scheduler was never called;
      - the replies `:expired`, `:not_runnable`, `:not_found` and
        `:disabled`;
      - the exit `:noproc`, a call that reached nobody;
    - `unanswered`, for everything else, and the heal keeps watching:
      - the replies `:repo_timeout`, `:busy` and any other error;
      - a timeout, or any other exit.

    Each `refused` reply, read against `manual_run`, `manual_run_job` and
    `claim_manual_run` (`scheduler.ex:853-889`) and the Repo's claim, is a
    proof:
    - `:expired` and `:not_runnable` come from `manual_run_job`'s read,
      before any claim.
    - `:not_runnable` from inside the claim comes from
      `fetch_claimable_job`, the claim's first statement, a `SELECT`. The
      claim then rolls back before the reply (`transact_claim` →
      `finish_job_claim`'s error clause → `rollback_job_claim`), and
      nothing had been written even if that `ROLLBACK` failed (its result
      is ignored).
    - `:not_found` comes from `manual_run`'s lookup, a read.
    - `:disabled` comes from `with_connection` on a store that is off,
      before any statement.
    - A `{:not_asked, _}` cannot follow a request that was made: `ask_rerun`
      runs only after `check_rerun` returned `:ok`, and the check is a read
      of the job. A check that timed out lands later as a read, which
      starts nothing.
  - The message now says "Fermix has asked for it to run again now"
    (`heal_message.ex:110`).
- **Residual:**
  - A call made in the instant the restarting Scheduler's name is not yet
    registered still exits `:noproc`. It is recorded `refused`, and the
    heal waits on the owner and says so. A cast lost in that instant loses
    nothing: the write it announces came first, so the new Scheduler's
    init reads that write when it arms its timer, since the name is
    registered before `init/1` runs.
  - Some calls are still recorded `unanswered` though they started none.
    The code cannot tell them from the ones that may have, so it keeps
    the possibility:
    - `manual_run`'s lookup timed out, or the store failed it with a read
      error;
    - `:busy` at the claim's `BEGIN IMMEDIATE`, which opened nothing;
    - a Scheduler stopped before it read the request.

    This does not matter: a watching heal concludes on the job's next run
    as it would on a rerun, and it expires after the same seven days as a
    waiting one. The only difference is that the next failure is told as
    a verdict.
  - A Scheduler started with no name (`name: nil`, which only tests do)
    gives its heal runs `scheduler: nil`. Their rerun exits `:noproc` and
    is recorded `refused`, and their pause or edit casts nothing.
  - **Recorded, not modelled: a claim left open by `:busy`.**
    `transact_claim/2` (`repo.ex:8469-8478`, older than M106) returns
    `{:error, :busy}` with no `ROLLBACK` when the busy comes from a
    statement inside the claim or from its `COMMIT`, not from the `BEGIN`.
    The transaction then stays open on the Repo's one connection:
    - the Repo's own later reads see the claim;
    - a later `COMMIT` on that connection commits it;
    - a later `BEGIN` fails and its caller's `ROLLBACK` undoes it.

    The spec already allows a claim whose outcome the caller cannot know:
    `ManualRunTimeout` and `ClaimTimeout` "may land", with the caller told
    an error. It does not have one that lands, is read as landed, and is
    then undone by another caller's rollback.

    No way is known to reach that busy with the store in WAL mode and
    `BEGIN IMMEDIATE` held:
    - the Repo opens the store in WAL mode (`PRAGMA journal_mode=WAL`, with
      `busy_timeout=5000`, `configure_connection`);
    - holding `BEGIN IMMEDIATE` excludes every other writer;
    - in WAL, readers never block a writer;
    - a WAL `COMMIT` appends to the log and takes no lock beyond the one
      already held.

    The only path found is a store where the WAL pragma did not take,
    for example a file system without shared memory.
    `configure_connection` does not check the mode it got. In rollback-
    journal mode a `COMMIT` needs an exclusive lock, and another process's
    read lock held past the 5 s busy timeout returns busy. So it is not
    modelled.
- **Tests:**
  - `scheduler_heal_verdict_test.exs`: "a heal run that outlives a
    Scheduler restart starts its rerun through the new one".
  - `heal_run_diagnosis_test.exs`: "a rerun that cannot start leaves the
    heal waiting, and the record, trace and list say so"; "a run now that
    does not answer in time is recorded as unanswered, and the heal
    watches".
  - `repo_job_heals_moves_test.exs`, "what came of a rerun": it is
    recorded once; `refused` takes a watching heal to waiting; a heal the
    job's run already moved stays where the run put it.

### JOB-11: a heal run's diagnosis loop outlives the heal run
- **Severity:** low.
  - It needs the heal run to be killed during its diagnosis, for example
    by a `:rest_for_one` restart of an earlier core child, which restarts
    the `RunnerSupervisor`.
  - The stray loop writes nothing modelled.
- **Status:** fixed (26f7e7414). Found by reading, in the same re-read as JOB-10,
  and fixed in the same stage.
- **Checks:** none. The loop's tools only read job and run rows, and its
  decision is a message, so no modelled step sees it.
- **What happened:** the heal run is shut down while it waits for its loop.
  The loop runs on until its six steps are used up: it makes model calls
  and reads job and run rows, and its decision goes to a dead process. The
  heal's closing bookend is never sent, since `HealDiagnosis.run/1`'s
  `finish` runs in the heal run.
- **Code (before the fix):** `supervise_loop` started the loop with
  `spawn_monitor`, unlinked, unlike a runner's loop since JOB-8.
- **Fix:** the loop is spawned linked and monitored in one call
  (`Process.spawn(..., [:link, :monitor])`, `heal_diagnosis.ex:248-268`),
  with the runner's JOB-8 pattern mirrored:
  - `report_loop/2` turns a raise, throw or exit of the loop body into
    `{:error, {:agent_loop_exit, reason}}` and logs it bounded (`:298-308`).
    The loop therefore exits `:normal`, and the link carries only heal run
    to loop.
  - `release_loop/1` unlinks and drops the monitor when the answer arrives
    (`:312-315`).
  - `kill_loop/1` unlinks before the watchdog's `:kill` (`:320-331`).

  Read against every way out of `await_loop`:
  - while the heal run waits, the loop is linked, and neither it nor its
    four tools trap exits, so a heal run that is killed or crashes takes
    the loop with it;
  - the heal run cannot end normally with the loop alive, since
    `handle_continue` goes on only after `await_loop` returns: the loop has
    answered (and is exiting), died, or been killed;
  - the watchdog's kill cannot reach the heal run, since the link is gone
    first and the monitor's DOWN is a message.
- **Residual:** the runner's, mirrored.
  - A heal run killed in the few instructions between `kill_loop`'s unlink
    and its kill leaves the loop unlinked and alive.
  - A process the loop links to itself can kill the loop with an exit
    signal, and the link then takes the heal run down too. Its lease runs
    out, and the heal is claimed and diagnosed again.
- **Tests:** `heal_run_diagnosis_test.exs`, "the diagnosis loop's life":
  "the loop dies with its heal run, before any further model call"; "the
  watchdog kills the loop, and the heal run goes on to send the facts".

### JOB-12: a heal's pause lands after an owner's resume that left the job as read
- **Severity:** low.
  - It needs the owner to resume the job while its heal run is diagnosing,
    the two minutes or so between the run's read of the job and its move:
    either a resume of a job that was running anyway, or a pause and then a
    resume.
  - The job then ends paused although the owner's last word was to resume
    it. The heal's message says Fermix paused it, so the owner could resume
    it again.
- **Status:** fixed (S4). Found by reading the first S4 code in "Re-read
  for the owner's answer and a heal's one write" below, and fixed before
  the stage shipped.
- **Checks:**
  - 75 holds (`HealPauseNeverUndoesResume`).
  - 76 (`needs MarksOwnerWrites`) breaks it with the fix switched off. Its
    4-state counterexample is the one below.
  - 73 and 74, the stale read the first S4 fence was written for, hold and
    break as before.
- **Counterexample (check 76, 4 states):**
  1. The job is enabled and scheduled.
  2. A heal run reads it before its diagnosis and resolves a pause
     (`HealRead`).
  3. The owner resumes the job (`Resume`). Nothing checks that it is
     paused, and a resume always reaches its write (`enabled?` TRUE,
     `state` "scheduled", a fresh `next_run_at`), so the owner is told
     "resumed".
  4. The heal run's move (`HealWrite`) compares the job's version with the
     one it read. They are equal, because `enabled` and the definition are
     as read, so it writes the pause.

  A pause and then a resume during the diagnosis ends the same way, two
  steps longer.
- **Code (before the fix):**
  - The heal's fence compared only `HealDecision.job_version/1` (a SHA-256
    of the definition fields and `enabled?`, `heal_decision.ex:49-62`,
    `:130-136`) of the job as it was then with the one in the plan
    (`heal_job_write_fenced`). A value digest cannot tell a job the owner
    never touched from one the owner put back as it was.
  - The owner's writes left no mark the fence read. `updated_at` is
    written by runs as well (`@run_written_fields`, `heal_decision.ex:63`),
    so no version reads it.
- **Fix:**
  - Every owner write (`update_scheduled_job_fields_row`,
    `repo.ex:8989-9002`) marks the job's `diagnosing` heal in its own
    transaction (`JobHealsSql.mark_written_under/3`, `job_heals.owner_wrote_at`),
    whatever value it leaves. Every pause, resume and edit reaches that
    write.
  - The heal's claim clears the mark (`take_lease`,
    `job_heals_sql.ex:946-960`): the run reads the job after its claim.
  - Under a heal run's claim, `heal_job_write_fenced` (`repo.ex:9047-9056`)
    treats a set mark as moved on, as it treats a moved digest, and writes
    nothing.
  - The digest compare is kept. It sees a change made outside the owner's
    write (the Scheduler's own write of `enabled?`) and is the answer
    claim's only guard there.
- **Whether the mark can be lost or wrongly kept**, read against the code:
  - *A claim between the owner's write and the heal's move.* A heal run
    holds its heal's lease, and the Scheduler claims no heal while a heal
    run lives: it runs one at a time and adopts a live one after a restart.
    A new claim therefore means the old run is dead, or its lease ran out
    and it is fenced out: a new claim writes a new `lease_token`, and the
    old run's `heal_job_write` then fails `claimant` with `:lease_lost` and
    writes nothing.
    - The new run reads the job after its claim, so clearing the mark at
      the claim is right: any owner write before it is in what that run
      reads.
  - *An owner write between the claim and the heal run's read* is marked
    though the read sees it. The move is then refused and recorded as
    `tell`: conservative, never unsafe. The model starts the mark at the
    read (`HealRead` folds the claim in), so it refuses fewer moves than
    the code, never more.
  - *A crash.* The mark is a column, so it survives. The heal's lease runs
    out, the next claim clears the mark, and that run reads the job afresh.
    `DaemonCrash` sends a reading heal back to `idle`, whose next
    `HealRead` clears the mark the same way.
  - *A write that is no owner write* (a run's claim or settle, a heal's own
    move) leaves no mark. Those writes write no version field, or are the
    move itself.
- **Tests** (names read in the export, not run here):
  - `heal_run_diagnosis_test.exs`: "paused then resumed: the heal's pause
    is not made, and no pause is claimed"; "a limit edited and edited back:
    the heal's raise is not made, nor claimed";
  - `repo_job_heals_answer_test.exs`: "an owner's write during the
    diagnosis that leaves the value as read still blocks"; "an owner's
    write before the claim does not block the move"; "the mark does not
    survive into the next claim".

## Re-read for M106 retries and heals (2026-11-24)

M106's quiet retry (§5.3) and its heal (§5.4) staled `scheduler.ex`,
`runner.ex` and the claim and settle functions of `repo.ex`. The spec was
re-read against that code, the five changes one by one:

1. **A new claim source, the retry: modelled.** The settle, the runner's
   (`Settle`, `RunnerCrashLate`) and the reaper's (`ReapWrite`), decides the
   job's retry in its own transaction from the run row as written and the
   job as released (`RunnerRetries`, `ReapRetries`, `SettledRetry`), and
   keeps it as `retryAt`. The due scan (`Scan`) finds a job due by its next
   run or by its retry and records which (`sBy`); `Claim` and `ClaimTimeout`
   take it through the claim every run takes, the retry's with
   `next_run_at` unmoved, and both clear the retry. `Arm` counts a pending
   retry as due. Pause, resume, edit and run now delete it
   (`OwnerLeavesRetry`, `OwnerClearsRetry`). Whether a tool had started is
   now state (`tool`): the tool's start inside the loop and its stamp
   (`ToolStarts`, one step since JOB-9's fix, or the store's refusal), with
   `ToolsCanStart`, `ProviderCanFail` and `StampCanFail` as switches. The attempt count, the
   delays and a retry with no time are a free choice, and the drop of a
   stale retry is left out with the stale-skip.
2. **The due timer is re-armed on every runner's DOWN: modelled.** A normal
   exit's DOWN now waits in the mailbox (`exits`, `HandleExit`) instead of
   being folded into `MarkDelivery`, since its handler makes a Repo call (the
   timer lookup); a crash's callback ends in the re-arm (`reapReturn` "arm").
   `RearmsOnDown` switches both off. One strongly fair action per run serves
   both handlers, since a run's DOWN is one or the other; with two, the
   liveness checks took about four times as long.
3. **A failed run may deliver nothing: modelled.** A retried failure, and a
   failure a heal takes, only mark the run's delivery `skipped`; only a
   guest's job sends its failure text (`GuestJob`). Checks 01 to 60 set
   `GuestJob`, so their failure text is sent as before.
4. **The Scheduler's crash settle decides a retry: modelled** (`ReapRetries`,
   from the row, so an unstamped tool start counts as none: JOB-9). Its new
   `run_error` bookend and the heal's sentence for a crash are telemetry and
   heal rows, which no step reads.
5. **Heals: not modelled.** The settle opens, joins or closes a heal in its
   own transaction, but writes only `job_heals` and `job_heal_runs`, which no
   step reads; a heal write that fails rolls the settle back like any SQLite
   error, which the spec leaves out. `Jobs.HealRun` reads the job's name and
   writes no job or run row; it runs under the `RunnerSupervisor`, where
   `live_runner_pids` skips it (`Runner.run_id/1` reads nil for it), and the
   Scheduler monitors it in a map of its own (`heal_runs`), whose DOWN clause
   comes first and starts the next heal run. Its claim, its start after each
   due scan and DOWN, its adoption after a restart, and the expiry of waiting
   heals in init and the reconcile tick are Repo calls on those tables inside
   callbacks modelled here: a timeout there changes nothing modelled, and a
   crash there is `SchedulerCrash`. A heal run is no run for the admission
   ceiling or the cue share: both count runs by the run id each runner
   publishes (`active_run_count/1`, `scheduler.ex:713-717`), so a live heal
   run takes no run slot. (Before that fix, in the same stage, it was counted
   among the supervisor's active children; the ceiling is never reached by
   one job either way.)

New `SOURCE` pins: `retry.ex`, `job_retries_sql.ex`, the heal settle
(`job_heals_sql.ex#settle`), `heal_run.ex`, and the retry claim's functions
in `repo.ex` (`claim_retry_job`, `claim_retry_job_tx`,
`fetch_claimable_retry_job`, `then_in_claim`, `scheduled_job_with_retry`,
`@earliest_wakeup_sql`), and, for JOB-9's fix, AgentLoop's gate
(`agent_loop.ex#run,run_tool_call,gate_tool,trace_unexecuted`) and
`failure.ex#provider_failure?`. New checks 61 to 72 (see "Retries (M106)"),
and finding JOB-9, found and fixed in the same stage.

Checks 01 to 60 keep every verdict, and every recorded counterexample its
length. Their state counts grew with the new steps (the DOWN handlers, the
reaper's retry, the retry's claim), most for the checks with crashes; the
`needs` checks' counts move with the order TLC explores in:

| Check | Before | After | Check | Before | After | Check | Before | After |
|---|---|---|---|---|---|---|---|---|
| 01 | 445,432 | 984,295 | 21 | 734 | 821 | 41 | 29,420 | 39,252 |
| 02 | 3,537 | 3,579 | 22 | 18,193 | 18,876 | 42 | 258 | 255 |
| 03 | 24,410 | 43,387 | 23 | 1,039 | 1,039 | 43 | 1,463,439 | 1,680,556 |
| 04 | 255 | 259 | 24 | 2,384 | 2,384 | 44 | 31,396 | 31,652 |
| 05 | 9,268 | 9,489 | 25 | 1,527 | 1,539 | 45 | 306 | 302 |
| 06 | 85,945 | 119,905 | 26 | 16,411 | 22,009 | 46 | 478,785 | 930,619 |
| 07 | 16,199 | 15,564 | 27 | 18,173 | 18,479 | 47 | 5,672 | 5,687 |
| 08 | 55,317 | 97,805 | 28 | 18,725 | 16,899 | 48 | 8,496 | 8,560 |
| 09 | 10,372 | 9,613 | 29 | 28,834 | 25,330 | 49 | 3,530 | 4,089 |
| 10 | 384 | 399 | 30 | 22 | 22 | 50 | 14,074 | 13,774 |
| 11 | 66,266 | 125,546 | 31 | 259 | 424 | 51 | 5,248 | 5,234 |
| 12 | 16,235 | 16,752 | 32 | 76,984 | 142,133 | 52 | 11,734 | 13,136 |
| 13 | 45,430 | 84,128 | 33 | 17,856 | 17,131 | 53 | 45,671 | 77,252 |
| 14 | 6,563 | 9,969 | 34 | 40,009 | 76,380 | 54 | 1,648,338 | 2,102,964 |
| 15 | 5,644 | 10,679 | 35 | 12,708 | 10,441 | 55 | 3,989 | 3,965 |
| 16 | 12,039 | 15,921 | 36 | 91,342 | 154,504 | 56 | 2,229 | 2,226 |
| 17 | 22,979 | 30,339 | 37 | 13,358 | 16,498 | 57 | 47,502 | 77,490 |
| 18 | 121,906 | 211,650 | 38 | 13,084 | 13,133 | 58 | 17,061 | 17,945 |
| 19 | 2,409 | 2,453 | 39 | 21,228 | 28,308 | 59 | 47,502 | 77,490 |
| 20 | 279 | 280 | 40 | 11,613 | 9,630 | 60 | 13,442 | 16,518 |

The new checks' counts: 61: 16,822; 62: 429; 63: 34,603; 64: 968,160; 65:
756; 66: 160,853; 67: 732; 68: 1,487,631; 69: 962; 70: 667; 71: 117; 72: 123.
JOB-9's fix took 68 from 1,529,003 (the start and its stamp were two steps);
61 had 16,484 before it explored the store's refusal, and 63 was the
violated JOB-9 (429 states, the 12-state path now check 62's).

The new `holds` checks were run by hand with one more of an entity, one at a
time, each bounded at 15 minutes (61 and 63 again after JOB-9's fix; before
it, 61 also held with a second Scheduler crash, 25,768):

| Check | +1 run id | +1 fire time | other |
|---|---|---|---|
| 61 | holds, 214,907 | holds, 89,580 | +1 owner move: holds, 93,429 |
| 63 | holds, 443,016 | holds, 182,793 | +1 owner move: holds, 191,883 |
| 64 | holds, 15,510,220 (702 s) | holds, 3,207,865 | |
| 66 | holds, 2,054,863 | holds, 857,984 | +1 owner move: holds, 298,755 |
| 68 | not finished: 21,603,248 states in 15 min, none broken | holds, 4,504,835 | |

## Re-read for the heal's diagnosis and moves (M106, 2026-11-24)

M106's diagnosis (§5.5) and verdict (§5.9) staled `scheduler.ex`,
`runner.ex`, `registry.ex` and `heal_run.ex`. The spec was re-read against
that code, point by point. Reading it found two defects outside the model,
JOB-10 and JOB-11 (see Findings), both fixed in the same stage. The fixes
staled `scheduler.ex`, `heal_run.ex` and `heal_diagnosis.ex` again, and the
Scheduler's `init` for `cue_inbox`. The notes below are on the fixed code.
No modelled step changed:

1. **A heal run's moves are the owner's.** For a job's heal, `Jobs.HealRun`
   runs one diagnosis (`Jobs.HealDiagnosis`), turns its decision into a plan
   (`Jobs.HealDecision`, which only reads) and carries it out itself. It
   writes each move right after a write on `job_heals` that proves its lease
   still holds (`fenced`, `heal_run.ex:284-291`):
   - `pause`: `Registry.pause_job` (`heal_run.ex:279-280`), the owner's
     pause: `Pause`.
   - `raise_limit`: `Registry.update_job` with `timeout_seconds` alone
     (`heal_run.ex:271-277`). `prepare_update` reads the job and
     `apply_job_update` writes that one column through
     `Repo.update_scheduled_job_fields` (`registry.ex:143-173`, `:279-287`;
     `timeout_patch`, `:342-354`). No step reads that column: `UpdateRead`,
     then `UpdateWrite`.
   - `rerun`: once the concluding write has made the heal `watching`,
     `Registry.check_run_now` and then `Scheduler.run_now`
     (`heal_run.ex:426-464`), as the owner's `run_job_now` does
     (`run_job_now.ex:71-77`): `ManualRun`. Its claim refuses a paused,
     running or claimed job in its own transaction.
   - `propose`, `tell` and no decision write only `job_heals`.

   The spec takes these moves at any time, since the owner's steps leave
   the Scheduler alone. So every heal move it lists is already explored:
   between a claim and its start (`sPc` "start"), beside a due or retry
   claim, or against a runner's settle. A heal makes at most one move, so
   the bounds of one or two owner moves cover a heal's move beside the
   owner's. A heal's pause is never undone by a run's release, as the
   owner's is not (`PauseNeverOverwritten`, with `intent` as the last pause
   or resume any caller made).

   Only the caller differs: a process under the `RunnerSupervisor`, which
   the Scheduler monitors. Read against the code:
   - **No deadlock.** The rerun's `Scheduler.run_now` is a `GenServer.call`
     into a Scheduler that never waits on a heal run. The Scheduler starts
     the run through `RunnerSupervisor.start_run`, whose `init/1` does no
     work (`heal_run.ex:132-156`), reads its heal id from its process
     dictionary (`HealRun.heal_id/1`) and monitors it. So the call waits
     behind whatever callback is running and is served at `sPc` "idle",
     where `ManualRun` is.
   - **A call that times out** (5 s, behind a callback slowed by its own
     Repo timeouts) is still served later, as the owner's is: the request
     stays in the Scheduler's mailbox. `Scheduler.run_now/3` now takes the
     wait as `:timeout` (`scheduler.ex:183-186`), and the heal passes the
     same 5 s. Since JOB-10's fix the heal records such a call as
     `unanswered` and keeps watching (`heal_run.ex:426-602`), so the run
     that may still start is the one it watches.
   - **A Scheduler that restarted: JOB-10, fixed in this stage.** The heal
     run used to reach the Scheduler that started it by pid. A heal run
     survives a Scheduler-only crash under the `RunnerSupervisor` and is
     adopted, so after such a crash its rerun exited `:noproc` and started
     nothing. It now reaches the Scheduler by the name it is registered
     under (`scheduler.ex:195`, `:1355`).

     Neither the old nor the new address changes a modelled step:
     - A lost `:job_changed` cast after a pause or an edit loses only its
       re-arm and admission request, and neither move makes the job due
       or admissible.
     - A lost "run now" is a request never made.
   - **Its diagnosis loop: JOB-11, fixed in this stage.** The loop was
     started with `spawn_monitor`, unlinked. It is now linked and
     monitored in one call, as a runner's loop has been since JOB-8
     (`heal_diagnosis.ex:251-271`). Its four tools (`skill_view`,
     `list_job_runs`, `get_job_run`, `job_heal_respond`) read job and run
     rows or send a message, so even a stray loop wrote nothing modelled.
2. **The S2 properties hold with a heal run as a caller.**
   - Single flight (`OneActiveRun`, `RunningHasRun`): the rerun is a manual
     claim, `claim_job_now_tx` with `ensure_no_active_job_run`.
   - `RetryClearedByOwner`: the heal's pause and its raised limit go through
     `update_scheduled_job_fields_row`, which deletes the job's retry inside
     the write's own `BEGIN IMMEDIATE`. Its rerun goes through
     `claim_job_now_tx`, which deletes the retry in the claim
     (`OwnerClearsRetry`, `OwnerLeavesRetry`).
   - The timer: the heal run's DOWN clause (`scheduler.ex:321-333`) still
     arms nothing, and it does not need to. Each move re-arms on its own:
     the `:job_changed` cast (`scheduler.ex:282-284`), `run_now`'s
     `handle_call` (`:276-279`), and the rerun's runner's own DOWN.
3. **The settle's new branch and the wider expiry: not modelled.**
   - A failure that finds its job's heal `watching` now reopens the heal
     for a verdict (`verdict`, `job_heals_sql.ex:535-563`) instead of
     joining it. Both write only `job_heals` and `job_heal_runs`.
   - An ok run closes a watching heal `healed`, as it closes any other.
   - The new outcome `{:verdict, id}` takes the runner's branch for a
     failure a heal took (`finish_failure/4`, `runner.ex:617-620`: the
     delivery is `skipped`). The reaper's crash settle does not branch on
     it, so the run is the failed run the spec already has (`GuestJob`
     FALSE).
   - The expiry now also closes a heal that has been `watching` for seven
     days (`expire_waiting`, `job_heals_sql.ex:827`). It is the same Repo
     call in init and in the reconcile tick.
   - The diagnosis columns (migration 72) are on `job_heals`.
4. **What JOB-10's fix added: not modelled.**
   - The heal records what came of the rerun once, in
     `job_heals.rerun_outcome` (`rerun_outcome`,
     `job_heals_sql.ex:770-790`): `started`, `running` (a run already held
     the job), `refused` or `unanswered`. The write comes after the
     concluding write has released the lease.
   - The outcome comes from `HealRun.rerun_outcome/2`. `refused` is only
     what proves no run will come of the ask: a check that stopped it
     before the Scheduler was called, `:expired`, `:not_runnable`,
     `:not_found`, `:disabled`, or `:noproc`. Everything else is
     `unanswered`, including the `:repo_timeout` of a claim that may land
     late (`ManualRunTimeout`'s landing branch) and a `:busy`. A run that
     comes of an `unanswered` ask is one the spec already has, and its
     settle moves the watching heal as any run's does (see JOB-10).
   - A refusal moves the heal from `watching` to `waiting`, but only while
     it is still `watching` on its first conclusion: the `UPDATE`'s `CASE`
     tests `state = 'watching' AND conclusion = 'first'`.
   - The only steps that move a watching heal are these: the rerun's own
     settle (a verdict sets `conclusion = 'verdict'` and `state = 'open'`;
     an ok run closes the heal) and the expiry (closes it). So a heal the
     settle has already moved stays where the settle put it. `rerun_outcome
     IS NULL` in the `WHERE` makes the write happen once.
   - Every column the write touches is on `job_heals`, and no step reads
     them.
   - The message now says "Fermix has asked for it to run again now"
     (`heal_message.ex:166`), which holds whatever the Scheduler answers.

Citations:
- The `registry.ex` ones moved with `check_update` and `prepare_update`
  and were updated.
- In the spec and in this README's sections on the current code (above
  "Re-read for M60", the two M106 re-reads and "Assumptions"), the
  `scheduler.ex`, `heal_run.ex` and `job_heals_sql.ex` ones moved with S3
  and its fixes (`next_wakeup_at` is now `scheduler.ex:1444-1450`) and
  were updated. The earlier dated re-reads and the findings cite the code
  as it was then, and were left as they were.
- The `repo.ex` line citations were already wrong before this stage and
  were left as they were: `repo.ex` is pinned by function, so its line
  numbers drift without anyone noticing.

New `SOURCE` pins:
- the heal functions that the run's settle, the Scheduler's expiry and the
  rerun's outcome call
  (`job_heals_sql.ex#take_failure,not_closed,verdict,join,open_or_quiet,open,link_run,close_healed,close_rows,expire_waiting,expire_rows,rerun_outcome`,
  beside `settle`). The `settle` pin alone did not go stale when this stage
  changed `take_failure`.
- the diagnosis loop's tools, its linked spawn and its watchdog
  (`heal_diagnosis.ex#@allowed_tools,supervise_loop,await_loop,report_loop,release_loop,kill_loop`).

No check was added or changed. All 72 keep their verdicts and every `holds`
check its state count from the M106 re-read above; the `needs` checks'
counts move with the order TLC explores in, as before.

## Re-read for runs that end ok without working (M106, 2026-11-24)

M106's §6 (S5) staled `runner.ex`, `agent_loop.ex#run_tool_call`,
the heal settle's functions in `job_heals_sql.ex`, `repo.ex`'s
`@unsettled_job_runs_sql` and `heal_run.ex` (comments only). Every pinned
function that changed was re-read against the code, point by point. No
modelled step changed:

1. **An ok run's settle reads and writes heals: not modelled.**
   - The settle runs as before, in its one `BEGIN IMMEDIATE`
     (`settle_job_run_in_tx`, `repo.ex:8629`): the active and not-cue
     checks, the run row with its facts, the job's release, the retry
     reset, then the heals.
   - The run passed to the heals is the row read back
     (`upsert_job_run_row` → `fetch_job_run`), its tally read through
     `JobHealsSql.run_tally/2` (`job_heals_sql.ex:294`). A tally this engine
     cannot read is none and is logged, so nothing raises in the Repo.
   - For an operator's job, `degraded/3` (`:396`) reads the tallies of the
     job's two newest other settled non-cue runs (`earlier_tallies`,
     `:406`). Those are `job_runs` and `job_run_facts` rows with a final
     status, read through the `(job_id, created_at)` index.
     `Jobs.Degraded.decide/1` (pure) says whether a tool never once
     succeeded in all three.
   - `settle_ok` (`:422`) then either closes the heals the run proves
     (`close_proven`, `:442`), or closes the provider's heal and takes the
     tool's failure (`take_failure`). Both write only `job_heals` and
     `job_heal_runs`.
   - The run row stays ok with no failure kind. The release and the retry
     reset are unchanged, and so is the delivery: `mark_completed`
     (`runner.ex:380`) and `complete_run` are unchanged, and read the
     settlement only for telemetry.
   - The new reads take place inside the settle's transaction on the
     Repo's one connection, so nothing they read can change under them. A
     claim, a retry's claim and the reaper's settle are separate Repo
     requests, served before or after it, as the model's one `Settle` step
     has them.
   - Under single flight (`OneActiveRun`) no other run of the job is
     active then, and the read takes only final statuses. It feeds
     nothing but heal rows.
   - A new query that fails rolls the settle back, like any SQLite error,
     which the spec leaves out.
2. **A heal an ok run leaves open: no new interleaving.** A heal an ok run
   leaves open is claimed by the same heal pass as one a failed run leaves,
   in the same callbacks (the S3 re-read above). Its heal run's moves are
   the owner's, which the spec takes at any time. A plugin's heal has no
   job: it is never diagnosed (`diagnosable?` needs a job subject,
   `heal_run.ex:215`), so it makes no move.
3. **The runner: the JOB-9 gate, the stored first start and the watchdog's
   order are unchanged.**
   - `run_agent_loop` still adds the gate (`put_tool_start_store`,
     `runner.ex:1719-1727`).
   - The watchdog handles `:tool_start` as before (`in_flight`,
     `last_activity_at`, `first_tool_at`, `:1882`) and adds a per-tool
     tally in the same step.
   - A name the run was not offered is `(no such tool)` for both its start
     and its finish (`recorded_name`, `:1936`), so `in_flight` still pairs
     them.
   - `put_run_facts` still takes `tools_started_at` from `first_tool_at`,
     and adds the tally beside the timeline.
   - The runner asks for a failed call's error words (`maybe_put(
     :activity_error_chars, ...)`, `:1660`; 500 characters, none for a cue
     run, `:1700-1701`). Those ride the call's `:tool_finish`, after the
     tool has run.
4. **`AgentLoop`: only after the tool.**
   - In `run_tool_call` (`agent_loop.ex:1396`) the gate still runs before
     `:tool_start`. Only the finish's detail changed (`finish_detail`,
     `:1422-1428`).
   - A bad `activity_error_chars` fails the run's start in `build_state`,
     inside the runner's `report_loop`.
   - `error_result/3` (`:1569`) interpolates the tool's words as the old
     frame already did, so it raises nowhere new.
   - `agent_loop.ex` is pinned only here: `turn_queue` and
     `companion_session` pin `turn_runner.ex`.
5. **The reaper reads the tally too.** `@unsettled_job_runs_sql`
   (`repo.ex:2854`) selects `tool_tally_json`. The crash settle writes the
   stored tally back unchanged (`upsert_job_run_facts`, `repo.ex:9010`,
   keeps a stored value) and is an error settle, which never reads
   tallies.

`cue_inbox` is not stale and was re-read as well. A cue run asks for no
error words, `earlier_tallies` skips trigger `cue`, and a cue run's settle
(`settle_cue_run`) still calls neither `JobRetriesSql` nor `JobHealsSql`.

New `SOURCE` pins:
- the ok settle's functions in `job_heals_sql.ex` (`degraded`,
  `earlier_tallies`, `settle_ok`, `close_proven`, `open_for`,
  `query_open_for`, `close_ids`, `run_tally`), with `close_healed` gone;
- `degraded.ex` whole, the pure trigger the settle calls.

Citations:
- the `runner.ex`, `agent_loop.ex`, `failure.ex`, `heal_run.ex`,
  `heal_diagnosis.ex`, `heal_message.ex` and `job_heals_sql.ex` ones that
  moved were updated, in the spec and in this README's sections on the
  current code;
- the `repo.ex` ones were left as before.

No check was added or changed, and no finding came of the re-read.

## Re-read for the owner's answer and a heal's one write (M106, 2026-11-25)

M106's §5.7 (S4: every job write that belongs to a heal is one
transaction, and the store can apply or leave a stored proposal) staled
`runner.ex`, `registry.ex`, `heal_run.ex` and, in `repo.ex`,
`update_scheduled_job_fields_row`, `scheduled_job_field_assignments!` and
then `heal_job_write_fenced`. This section reads the code as it shipped:
the first S4 code was reworked once more before the stage was pushed (the
mark of JOB-12's fix, and no caller for the answer yet). Point by point:

1. **The owner's steps still describe the owner's writes.**
   - `Repo.update_scheduled_job_fields_row` (`repo.ex:8989-9002`) is still
     one `BEGIN IMMEDIATE`. It now reads the job before its write and
     again after it. The write itself (`write_scheduled_job_fields`,
     `:9009-9018`) sets the given columns, clears a follow-up's stale
     approval and deletes the retry, as before.
   - When the job's version moved (`HealDecision.job_version/1`), it also
     closes the job's waiting proposals superseded (`supersede_moved`,
     `:9020-9024`; `JobHealsSql.supersede_proposals`). Whatever it leaves,
     it marks the job's `diagnosing` heal (`mark_written_under/3`,
     JOB-12's fix). Those are heal rows; the mark is read by the heal's
     move, which is modelled (`hMark`, below).
   - `scheduled_job_field_assignments!` now refuses a field not on
     `@owner_job_fields` before any clause reads it. That changes no write
     the owner's steps make.
   - So `Pause`, `Resume` and `UpdateRead` then `UpdateWrite` stand. The
     edit's read (`prepare_update`) still feeds only the edited columns,
     none of them modelled.
   - A run's claim and settle write no version field and supersede
     nothing.
2. **A heal run's move is now its own step: modelled** (`HealRead`,
   `HealWrite`, checks 73 to 76; see "Heal moves (M106 S4)").
   - The move is `Registry.heal_write/5` → `Repo.heal_job_write/5`
     (`heal_job_write_tx`, `repo.ex:9030-9064`). In one transaction it checks
     the heal is still `diagnosing` under the run's lease
     (`JobHealsSql.claimant`), reads the job, and compares its version
     with the plan's `change_job_digest`. The plan's digest comes from the
     job read before the diagnosis (`diagnose`, `heal_run.ex:228-237`).
     It also treats a heal an owner write marked since its claim as moved
     on (`written_under?`, `:9053-9056`).
   - Then it either writes nothing to the job (`moved_on`: the plan is
     recorded as `tell`, refused `job_changed`), or writes the job as an
     owner write does and records the decision under the lease, both or
     neither.
   - The old `{:hold, ...}`, a lease proof followed by an unguarded
     `Registry.pause_job` or `update_job`, is gone.
   - Check 73 shows the fence keeps a raise off an edit that still stands.
     Check 74 is the S3 shape, whose counterexample is the stale read a
     review found: an owner edit lands during the diagnosis and the raise
     overwrites it.
   - Check 75 holds: a heal's pause never lands after an owner resume
     since its read. Check 76 is the first S4 code, which compared the
     version alone: a resume that leaves `enabled` as read (of a running
     job, or after a pause) let the pause land after it. That is JOB-12,
     found in that code and fixed by the mark before the stage shipped.
   - The mark is never lost while the run that will move is alive. It is
     wrongly kept only for an owner write between the claim and the run's
     read, which refuses a move whose read saw the write: conservative.
     See JOB-12.
3. **The owner's answer: no caller yet, so not a step.**
   - The model-called tool of the first S4 code (`answer_job_proposal`,
     with its `owner_words`) is removed: the owner answers a proposal on
     its card, a later stage.
   - `Jobs.HealAnswer` holds the two answers, and nothing in production
     calls it.
     - `apply_change/4` writes through the same `heal_job_write/5` under
       the answer claim. The claim needs the heal to be the job's
       unanswered waiting proposal on its first conclusion; the version is
       the proposal's, and the mark is not read. The write is either an
       owner write with the heal moved to `watching`, or nothing with the
       heal closed `superseded`.
     - `leave/3` closes the heal `skipped` in one `job_heals` call.
   - The heal records `decided_from`, where it was answered, in place of a
     session.
   - Once something calls it, an `apply` is `UpdateRead` with
     `UpdateWrite` at once (its read folded into the guarded write), or no
     write: the owner's own steps.
   - The value comparison cannot reach an answer: the first owner write
     that moves the version (an edit, a pause, a resume) closes the
     proposal in that write's own transaction, so a later `apply` finds it
     not waiting.
4. **The runner's error text: nothing decides on it.**
   - A failed run's `error` and its job's `last_error` now hold Fermix's
     sentence for the failure's kind (`run_error`, `runner.ex:689-695`;
     `Failure.sentence/2`, which delegates to `Failure.kind_sentence/3`).
     For a kind Fermix has no sentence for, they hold the failure's own
     text (`Failure.other_text/1`).
   - Every decision still reads the reason term:
     - the runner's settle retry (`failure_settle_by`, `runner.ex:610`,
       `Failure.provider_failure?/1`);
     - the stored kind (`Failure.stored(Failure.kind(reason))`);
     - a cue run's outcome (`CueRun.outcome/3` on the `{status, reason}`
       result);
     - the reaper's crash settle, from its own kind (`Failure.sentence(kind)`,
       `Failure.stored(kind)`);
     - `Retry.decide`, from the settle and `tools_started_at`.
   - The text is only shown: `get_job_run`, `list_job_runs`, `list_jobs`,
     a cue run's final failure report (`stopped_text`,
     `cue_run.ex:424-427`) and telemetry.
   - `Failure.kind_sentence/3` is total. In the first S4 code, `told/3`
     matched `:time_limit`, `:idle_limit` and `:unknown_skill` only on
     their own reason; that shape is gone.

`cue_inbox` went stale on `runner.ex#mark_failed` alone. Its cue clause
changed only the stored `error` text; the cue settle still decides from
`CueRun.outcome/3`, a term.

New `SOURCE` pins:
- the heal write's functions in `repo.ex` (`heal_job_write`,
  `heal_job_write_tx`, `heal_job_write_fenced`, `heal_job_write_in_tx`,
  `write_scheduled_job_fields`, `supersede_moved`);
- `heal_decision.ex#job_version,@version_fields,@run_written_fields,decide`;
- `job_heals_sql.ex`'s `claimant`, `claim_written`, `moved_on`,
  `mark_written_under` and `take_lease`;
- `written_under?` beside the heal write's functions in `repo.ex`.

New constants:
- `HealMoves` (0 in checks 01 to 72);
- `HealMoveGuarded` and `MarksOwnerWrites` (TRUE in checks 01 to 72).

The new variables are constant when `HealMoves = 0`, so checks 01 to 72
keep every verdict and every `holds` state count.

Citations:
- `runner.ex`, `registry.ex` and `failure.ex` ones in the spec and in this
  README's top sections and assumptions were shifted to the S4 lines;
- the earlier dated re-reads and the findings cite the code as it was then;
- the `repo.ex` ones were left as before.

## Re-read for events drawn as cards (2026-11-13)

`reply_delivery_opts` now keeps the run's events and trips blocks beside its lists (M89): it
takes the run's records from the in-memory `ReplyBlocks` holder once, as
before, and passes the kept blocks as the send's `blocks`, which a channel that
draws none ignores. No modelled row, helper, delivery or report changed, and
the change sits below every line the spec cites, so no reference moved.

## Re-read for the place-search pacer (2026-11-14)

`supervision_children` gains `PlaceSearch.Brave.Pacer` right after
`ReplyBlocks` (M89 D13, `eb5fc530`): the home's one door to Brave's place
search, holding only who waits and when the next request may send. It starts
before `AgentSupervisor`, so under `:rest_for_one` a pacer crash restarts the
job rail with every later child, which the model already takes as a
`:rest_for_one` restart of the scheduler and its runs; its callbacks raise on
nothing their guarded callers hand them. The order of `JobRunnerSupervisor`,
`JobScheduler` and the cue subtree is unchanged. No modelled row, helper,
delivery or report changed; the six lines move every citation past
`ReplyBlocks`, now `application.ex:292-376`, `:377-384` and `:399`.

## Re-read for the trip placer (2026-11-14)

`supervision_children` gains `Trips.Placer` after `Computers.Calls` and
before `Home.ReleaseTable` (M89 D13 B, `d4f5e1f3`), primary-only: it places
the trip stops that wait for their place, runs each pass in a task linked to
it, and raises on nothing it is sent, so a crash of it restarts only the
children after it, the cue tree among them, which the model already takes
as a `:rest_for_one` restart. The job rail and its order are unchanged. No modelled row,
helper, delivery or report changed; the cue tree's citation, which the
pacer's six lines had already moved, is now the call itself,
`application.ex:457`.

## Re-read for the trips' day turn (2026-11-14)

`supervision_children` gains `Trips.DayTurn` right after `Trips.Placer` and
before `Home.ReleaseTable` (M89 D14, `fad8eeea`), primary-only: it sends the
trips index again at a day's turn, serves no call, arms one timer and raises
on nothing it is sent, so a crash of it restarts only the children after it,
the cue tree among them, which the model already takes as a `:rest_for_one`
restart. The job rail and its order are unchanged. No modelled row, helper,
delivery or report changed; its seven lines move the cue tree's citation to
`application.ex:465`.

## Re-read for Always On in every build (2026-11-15)

`d195aa17` staled the `application.ex` pin. Every build now serves Always
On: the boot drops the release gate's alias, and `Home.ReleaseTable` fetches
on an Always On server's primary with no build check, its child comment
reworded in place. No child moved or changed order. The job rail and its order
are unchanged, so no modelled row, helper, delivery or report changed. The
removed alias moves every later line by one: the spec's citations point at
the committed file, the cue tree at `application.ex:464` and
JobRunnerSupervisor before JobScheduler at `:377` and `:384`, which an
earlier change had left at `:371` and `:378`.

## Re-read for outbound phone calls (2026-11-17)

`16727975` staled the `application.ex` pin. `supervision_children` gains the
phone-call subtree (`PhoneCalls.Supervisor`, M94) right after
`Harness.Supervisor`, primary-only, so after `JobRunnerSupervisor`,
`MeetingsSupervisor` and `JobScheduler`, which keep their order: a crash of it
restarts only the children after it, none of the job rail. The application
also gains `prep_stop/1`, which on an orderly stop asks a phone call in
progress to end, for at most twelve seconds, before the tree stops; the job
processes stop with the tree after it, as before, which the model's daemon
crash covers. The access gate's new kind, a phone call's start, is never
parked from a scheduled run (where it asks, it refuses one), so the
assumption below that a scheduled run never parks a call for the owner
stands. No modelled row, helper, delivery or
report changed. The citations had fallen behind the file: two changes after
`d195aa17` moved the tree fourteen lines down without touching a pinned
function, and this one adds aliases and `prep_stop/1` above it. They now point
at the committed file: the core children before the `RunnerSupervisor` at
`application.ex:338-422`, the tree's strategy at `:209`, JobRunnerSupervisor
before JobScheduler at `:423` and `:430`, the parked confirmations and the
place records at `:410` and `:414`, and the cue tree at `:518`. The
access gate's citation for a scheduled run's refusal, which had drifted
before, now names `command_decision/3` and `scheduled_decision/2`, and the
new kind's `effect_decision/2` beside them.

`f2a874b8` (M94, 2026-11-17) shortened the comment above `prep_stop/1` and
changed none of the pinned functions; the `application.ex` citations below it
moved up by two with the code.

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
  - The `{:ok, _} = write_run_artifact` writes (`runner.ex:336`, `:494`) are
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
  scheduled run never parks a call for the owner (`access_gate.ex:320-330`,
  `:898-907`), nor a phone call's start, the gate's external effect
  (`:714-724`).
  An owner edit, resume or run now of a job naming such a tool, from a turn
  that could not run it directly, is refused by the tool before any registry
  write or Scheduler call (`job_registry_support.ex:36-41`): a request the owner
  never made. That check's job-row read feeds no modelled column. The store
  of parked confirmations (`Capabilities.AccessGate.Pending`,
  `application.ex:408`) and the holder of a conversation's place records
  (`ReplyBlocks`, `:412`, which no job process reads) are two more core
  children started before the `RunnerSupervisor`, so a crash of either is the
  daemon crash above.
- The run-row value `unset` stands for the `"none"` the claim writes before a
  result exists (`scheduler.ex:911`). The final `"none"` of `delivery_mode
  "none"` is modelled as `skipped`.
- The due timer is modelled from the row as it is now. The code arms it at
  the end of a tick, on `:job_changed`, after run now and (since M106) at
  every runner's DOWN, not at the moment a settle releases the job. So the
  model's `DueTimerFires` can tick earlier than the code. The verdicts
  survive: the 60 s reconcile tick runs the same scan, may fire at any point
  and is strongly fair. A backoff timer fires whether or not the job is due,
  which is also only earlier than the code.
- With both run ids in use, a claim or "run now" is treated as not due. This
  is the model's bound, not code behaviour.
- A pending retry is due at once: its time is always before the job's next
  fire time, so the clock never separates the two, and the model can only
  claim it earlier than the code. The attempt count, the delays, the
  `:exhausted` fourth and a retry whose time falls at or after the next run
  (no time written) are a free choice of the settle. A retry older than the
  freshness window, dropped by the scan, is left out with the stale-skip.
- A heal's rows (M106 §5.4) are outside the model: see "Re-read for M106
  retries and heals" for why none of the settle's heal writes touches a job
  row, a run row or the claim, and "Re-read for runs that end ok without
  working" for an ok run's, which also reads the job's earlier runs' tool
  tallies in the same transaction.
- A heal run's move on the job:
  - in checks 73 to 76 (`HealMoves = 1`) it is its own two steps
    (`HealRead`, `HealWrite`), and `intent` is the owner's alone;
  - `HealRead` folds in the heal's claim, which in the code comes just
    before the read and clears the owner-write mark. So the model's mark
    starts at the read and refuses fewer moves than the code, never more.
  - everywhere else it is covered by the owner's pause, edit or "run now"
    (see "Re-read for the heal's diagnosis and moves" and "Heal moves (M106
    S4)"), and `OwnerMoves`, `OwnerEdits` and `ManualRuns` bound it with the
    owner's.
- The definition the heal's version reads is `defVer`, a count that every
  edit (the owner's, or a heal's raise) moves.
  - In checks 73 to 76 every owner edit is taken to set the time limit,
    the field a raise writes, so an edit the raise lands over is
    overwritten.
  - An edit that puts the definition back as it was is not modelled. The
    mark refuses the move after it all the same (see JOB-12).
- The admission ceiling (4 runs) is never reached by one job (two runners).
  A heal run is not counted against it: the ceiling and the cue share count
  runs by the run id each runner publishes (`active_run_count/1`). Expiry,
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
  ready, the switch off) refuses a trigger
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
  Scheduler serving its mailbox and its own timers; a configuration with no
  owner request or no cue tree leaves out the strong fairness of the step it
  can never take (`FairnessScope` in `TypeOK` holds that it cannot). None on
  the clock, the owner, the cue inbox, the platform or crashes.
