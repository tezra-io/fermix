# job_runs: scheduled jobs, from claim to delivery

Models `FermixCore.Jobs` for one recurring job: the Scheduler's due tick and
its atomic claim, one `Jobs.Runner` per run, delivery of the run's final text
through `Delivery.ChannelSend`'s watchdog, the Scheduler's monitors and its
reconciliation pass (at init and every 60 s), and the owner's pause, resume,
edit and "run now". A run ends the way the code ends it: one
`Repo.settle_job_run` transaction writes the final run row and releases the
job, then the memory write, the send, and `mark_delivery`. The Scheduler's
reaper settles a dead runner's run the same way.

Time is a clock of fire times: `now` counts the fire times that have passed,
and the job row's `next_run_at` is one of them. The AgentLoop is one step that
ends in text, `[SILENT]` or an error. Two run ids are reused once a run is
fully finished, so a check covers any number of runs. The spec's header lists
what is left out and every step folded into another.

**Environment switches** (set per check):
- `DaemonCanCrash`: the daemon dies once and boots again. Only SQLite rows and
  what the platform took survive. This also covers a crash of `Memory.Repo`,
  of the `RunnerSupervisor`, or of any child started between them
  (`TemplateReconciler` through `MainAgent`), since `:rest_for_one` restarts
  every job process in each case. What that fold hides is JOB-8.
- `SchedulerCrashes`: how many times the Scheduler alone may die, at any point
  of any callback, including its own init. A 5 s `GenServer.call` timeout to
  the Repo is enough (`repo.ex:3777-3780`). Runners keep running. When it dies
  waiting on the reaper's write, that write may still land (see late writes).
- `RunnerCanCrash`: a runner dies at one of its Repo calls (a call timeout, a
  failed `{:ok, _}` match). At its final write the write may still land.
- `LoopCanFail`: the AgentLoop ends in an error or a timeout.
- `PlatformCanFail`: a send fails, either with no connection or with an error
  after the platform took the message.
- `ResponsesCanStall`: the platform takes a message and its answer never
  arrives in time. With `DeliveryWatchdog` off, the model waits forever,
  because the adapters' own HTTP timeouts are outside the sources.

**Late writes.** A caller that dies on a `GenServer.call` timeout does not
cancel the call: the request stays in the Repo's mailbox and lands later.
`PRAGMA busy_timeout=5000` (`repo.ex:3809`) equals the call's 5 s default, so
one SQLite lock wait is enough. The spec therefore has two kinds of crash at a
Repo write: the write lands late, or it never lands (a kill, or a failed
match). The late kind is modelled where no later crash point already stands
for it: `RunnerCrashLate` at the runner's final write and `SchedulerCrashLate`
at the reaper's write. Any later reader's call is queued after the late one,
so the late write lands in the crash step itself.

The bounds are constants too: `NumRuns`, `Fires`, `SendAttempts` (3 in the
code, 2 in the checks), `OwnerMoves` (pause/resume requests), `OwnerEdits`
(`update_job` requests) and `ManualRuns`.

**Mechanism switches** (`TRUE` is the real code; each is switched off by the
checks listed under it):
- `AtomicRaceStop`: the claim transaction refuses while a run is queued or
  running (`ensure_no_active_job_run`, `repo.ex:5771`, `:5824-5842`). Check 02.
- `RetriesOnlyUnsent`: a send is retried only when it never reached the
  platform (`channel_send.ex:140-143`, `:194-202`). This is the mechanism for
  platforms that do not dedupe. The runner tags its send with the proactive
  key `job:<run id>` (`runner.ex:1276`). The mobile channel keeps one row per
  key (`mobile_sql.ex:41-43`), so a retry there would not show twice. Check 04.
- `ReconcilesRuns`: at init and every 60 s the Scheduler reaps unsettled runs
  with no live runner and adopts live ones (`scheduler.ex:168`, `:197-273`).
  Checks 07, 28.
- `CrashFailsPendingDelivery`: the crash path marks a dead runner's pending
  delivery failed, whatever the run's status (`scheduler.ex:721-723`,
  `:742-755`). Check 09.
- `DeliveryWatchdog`: the runner stops waiting for a send after
  `delivery_timeout_ms` (`channel_send.ex:219-241`). Check 05.
- `AtomicSettle`: a run's final row and its job's release are one
  transaction, `Repo.settle_job_run` (`repo.ex:2263`, `:5859-5928`), used by
  the runner (`runner.ex:258`, `:321`) and the reaper (`scheduler.ex:703-719`).
  The release is a column-targeted `UPDATE` that turns `running` back into
  `scheduled` and keeps any other state. Switched off, the spec runs the code
  before the fix: the run row alone, then a read and a whole-row upsert of the
  job row, in the runner and in the reaper. Checks 12, 22, 23, 24.
- `ReconcilesPending`: the reconcile pass reads every unsettled run, the
  queued/running rows and then the rows whose delivery is still pending
  (`unsettled_job_runs`, `repo.ex:2272-2305`; `scheduler.ex:233`). Switched
  off, it reads queued/running rows only. Checks 14, 15.
- `RefusalBacksOff`: a due claim refused as `:already_running` returns
  `{:busy, state}`, so the re-arm floors at the 5 s backoff
  (`scheduler.ex:451-455`, `:864-870`). Switched off, the refusal counts as a
  clean drain and a past-due job re-arms at 0 ms. Check 19.
- `OwnerWritesColumns`: pause, resume and `update_job` write only the columns
  they own, in place (`registry.ex:93-116`;
  `Repo.update_scheduled_job_fields`, `repo.ex:2206`, `:6071-6078`, the owner
  field list `:6955-6996`). Switched off, pause and `update_job` upsert the
  whole row they read. Check 27.

**What holds.** Every property below is also broken by its `needs` check.
- **At most one active run per job** (check 01). An active run is a
  queued/running row, or a runner still before or inside its AgentLoop. This
  holds with a mid-run resume and every kind of crash, and rests on
  `AtomicRaceStop` (check 02).
- **Final text reaches the user at most once** (check 03), with failing and
  stalling sends, loop errors and runner crashes. On a platform that does not
  dedupe on the proactive key, this rests on `RetriesOnlyUnsent` (check 04).
- **A runner never waits on a send forever** (check 03). This rests on
  `DeliveryWatchdog` (check 05).
- **An enabled job always gets back to claimable**, in three settings:
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
  "Claimable" (`scheduled`, no queued/running run) is weaker than §4.3's "runs
  again". It is what the Scheduler controls: the next run also needs its due
  time, and the model's clock stops at `Fires`. The widened property was split
  in two because one check with every crash kind holds but takes 220 s
  (476,070 states), over the runner's 120 s timeout.
- **Every pending delivery reaches a final status**, in two settings:
  - check 08: runner crashes (late writes included), a Scheduler restart, loop
    errors, and failing or stalling sends. It rests on
    `CrashFailsPendingDelivery` (check 09) and on `ReconcilesPending` (check
    15: old check 13's path).
  - check 13: a daemon crash, runner crashes, loop errors and failing sends.
    It rests on `ReconcilesPending` (check 14: old check 12's path).
  Split for the same reason: all of it in one check holds but takes 100 s.
- **A pause, and a resume, the owner was told about stay in force** (checks 16
  and 17), whenever the run's release lands. Each rests on `AtomicSettle`
  (checks 23 and 24: JOB-4).
- **A refused claim never re-arms at 0 ms** (check 18), with a resume during a
  run and runner crashes over three fire times. This rests on
  `RefusalBacksOff` (check 19: JOB-5). Witness 25 shows the refusal itself is
  reachable, so the pass is not vacuous.

Witness 10 shows the next run in its AgentLoop while the previous run is still
delivering. The race-stop counts rows, not runner processes.

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
code on `dev` at `693970b7`; none has been reproduced on a running daemon.
The **Code** paragraphs cite that code, before the fix. Each fix is proven by
a failing-first ExUnit test and by the checks named under it. To see a
counterexample, run `tla/bin/check.py job_runs` and open
`tla/out/job_runs/<check>.txt`.

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
  - The claim sets the job to `running` (`repo.ex:5559-5566`,
    `scheduler.ex:602-606`). Only `finalize_job` (`runner.ex:355-379`), the
    crash path (`scheduler.ex:664-679`) and `resume_job`
    (`registry.ex:47-59`) ever set it back.
  - Each writer first made the run row final, then wrote the job row in a
    separate Repo call: the runner at `runner.ex:252` then `:370` (and `:314`
    then `:423`), the reaper at `scheduler.ex:667`/`:722` then `:772`/`:782`.
  - Reconciliation read only queued/running rows (`repo.ex:5900-5915`), so a
    run already marked `ok` or `error` was invisible to it, and the due scan
    and the timer lookup need `state = 'scheduled'`.
- **Fix:** `Repo.settle_job_run/2` (`repo.ex:2263`, `:5859-5928`) writes the
  final run row and releases the job in one `BEGIN IMMEDIATE` transaction, the
  mirror of the claim. It refuses with `{:error, :run_not_active}` unless the
  row is still queued/running, so only the run holding the job can release
  it. The runner's `mark_completed` and `mark_failed` call it
  (`runner.ex:258`, `:321`); `finalize_job`, `finalize_failed_job` and
  `final_job_state` are gone. The reaper settles a queued/running row as
  `error` through it (`scheduler.ex:703-719`); on `:run_not_active` it re-reads
  the row and settles only a still-pending delivery (`:727-740`). The old
  reaper job writers are gone. A one-time migration (version 31,
  `repo.ex:319-331`) releases every job an older release left `running` with
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
  "pending"` (`runner.ex:248`, `delivery.ex:24-31`). Only `mark_delivery`
  (`runner.ex:331-353`) or a monitored crash (`scheduler.ex:686-687`) settled
  it. Reconciliation and adoption read only queued/running rows
  (`repo.ex:5900-5915`, `scheduler.ex:241-246`).
- **Fix:** `Repo.unsettled_job_runs` replaces `active_job_runs`
  (`repo.ex:2272-2305`, `:6195-6199`): two index reads combined with
  `UNION ALL`, the queued/running rows first and then the rows whose delivery
  is pending, oldest first within each, under the same limit. A partial index
  (version 30, `idx_job_runs_pending_delivery`, `repo.ex:307-310`) keeps the
  pending read off the never-pruned run history; a test asserts the query plan
  has no `SCAN job_runs`. `reconcile_active_runs` reads it
  (`scheduler.ex:233`), so a live runner past its settle is adopted after a
  Scheduler restart and a dead one's delivery is failed. The crash path's
  pending clause now matches any status (`scheduler.ex:721-723`), after the
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
  rows and on ok/pending (`scheduler.ex:681-698`); everything else fell
  through `{:ok, _finished_run} -> :ok` and the job row was skipped. Which
  runner deaths wedged: a timeout at the finalize upsert (`runner.ex:370`,
  `:423`) healed, because the late write released the job; a timeout or an
  `{:error, _}` at the finalize get (`:358`, `:411`), or a timeout at
  `mark_completed`'s or `mark_failed`'s own run-row upsert (`:252`, `:314`),
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
  `get_scheduled_job`, then upserted the whole row (`runner.ex:358-370`,
  `:411-423`). The crash path's job write had the same shape
  (`scheduler.ex:735-745`, `:772-782`).
- **Fix:** the settle's release is one column-targeted `UPDATE`
  (`release_settled_job`, `repo.ex:5889-5914`): `running` becomes `scheduled`
  and any other state is kept. It never writes `next_run_at`. It completes
  and disables a one-off only when that one-off's claim consumed it: the due
  claim (`scheduler.ex:605-607`) and a manual claim (`manual_claim_patch`,
  `:618-622`) both clear `next_run_at`, and an edit that sets a new instant
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
  (`scheduler.ex:447-448`), so the tick outcome stayed `:ok` and
  `due_delay_ms` floored a past-due job at 0 ms (`:929-936`), contradicting
  `:29-32` and `:924-926`.
- **Fix:** `{:error, :already_running} -> {:busy, state}`
  (`scheduler.ex:451-455`): a due job whose previous run is still active is
  backpressure, and the re-arm floors at the 5 s backoff. The job is claimed
  within 5 s of that run settling. The comments at `:29-33` and `:858-861`
  name the case. The rule is now checked as an action property: the `Arm`
  step that ends a refused claim's callback never arms the 0 ms timer.
- **Tests:** `scheduler_test.exs` ("a due claim refused because the previous
  run is still active re-arms at the backoff floor").

### JOB-6: a delivery recorded as `failed` may have reached the user
- **Severity:** low. The run row is wrong. Nothing is re-sent.
- **Status:** accepted by design (at-most-once, `channel_send.ex:140-143`).
  A `failed` delivery means "not confirmed delivered", and its
  `delivery_error` says which case it was: `:delivery_timeout`, `runner
  crashed: ...`, or `reaped: no live runner ...`. Retrying on an unknown
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
    needs the write never to land. In the code that is `mark_delivery`
    swallowing an `{:error, _}` from its upsert (`runner.ex:355-365`): the
    runner then exits `:normal`, the DOWN clears only the monitor
    (`scheduler.ex:212-213`), and the reconcile pass (widened by JOB-2) reaps
    the still-pending row as `failed`. The model's crash at `mark` with no
    late write stands for that, and for a kill of the runner alone; the rows
    end the same.
  - A third path came with JOB-2's fix, outside these checks: the daemon dies
    after the platform took the message, and boot reconciliation reaps the
    pending row as `failed`.
- **Code:** `ChannelSend.with_timeout` cannot tell whether the platform
  already took the message (`channel_send.ex:238-239`, `:284-300`, `runner.ex:339-340`).
  `mark_pending_delivery_failed` (`scheduler.ex:742-755`) assumes an
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
  the row and upserted all of it (`registry.ex:61-70`, `:93-116`), and
  `upsert_scheduled_job_row` writes every column.
- **Fix:** `Repo.update_scheduled_job_fields/3` (`repo.ex:2206`,
  `:6071-6078`) writes only the given columns in place and returns the row.
  It accepts only the owner-editable fields (`repo.ex:6955-6996`), never
  `last_*`, and raises in the caller on anything else. Pause writes `enabled`
  and `state`; resume writes `enabled`, `state` and `next_run_at`;
  `update_job` writes only the edited columns, never `state`, `enabled` or
  `last_*` (`registry.ex:93-116`).
- **Tests:** `registry_test.exs` ("owner writes racing a run's release":
  `update_job` and resume each keep a release that lands between their read
  and their write; pause, which reads nothing, writes only `enabled` and
  `state` and keeps a release that lands just before its write).

### JOB-8: an AgentLoop survives a restart of the job subtree and runs beside the next run
- **Severity:** open; for the owner to decide. It needs a crash of
  `Memory.Repo` or of a child started between it and `JobRunnerSupervisor`.
- **Status:** open, outside this model. No check: the daemon-crash fold kills
  every job process, so check 01's pass does not cover it.
- **What happens:** a crash of any child started between `Memory.Repo` and
  `JobRunnerSupervisor` (`TemplateReconciler`, `ConversationStore`, `Store`,
  `SecretWriteLog`, `SecretAclState`, `BootReport`, `RestartState`,
  `EnvHealth`, `AgentSupervisor`, `MainAgent`) restarts the job subtree under
  `:rest_for_one` (`application.ex:189-227`, `:259`). The runner dies with its
  supervisor, but its AgentLoop process is `spawn_monitor`ed, not linked
  (`runner.ex:977`), so it keeps running tools. It has no wall-clock limit,
  since the loop watchdog lives in the runner (`runner.ex:994-1045`), and its
  media path stays open, since only the runner clears the MediaBridge flag
  (`runner.ex:192-196`). Meanwhile the restarted Scheduler reaps the run
  (settles it `error` and releases the job) and can claim a fresh run of the
  same job: two concurrent executions of one job.
- **Related:** REMIND-2's fix (reminder_delivery) links the send helper to
  its caller (`channel_send.ex:219-224`), so the AgentLoop is the only job
  process that survives such a restart.
- **To model it:** an environment switch for a subtree restart that kills
  runners but leaves their loops running, a `loopAlive` variable, and
  `OneActiveRun` counting a surviving loop.

## Assumptions

- Every Repo call either completes or its caller dies. SQLite busy/errors are
  not modelled, except as a crash. A `:busy` claim would take the 5 s backoff
  instead.
- A caller that dies at a Repo write may have its write land late, modelled at
  the runner's final write and the reaper's write (see late writes). Elsewhere
  a crash right after a step already stands for that step's late write.
- A runner dies only at a Repo call or a file write, never while it waits in
  `receive` (the AgentLoop or a send). Nothing in its own code raises there.
  - The `{:ok, _} = write_run_artifact` writes (`runner.ex:241`, `:307`) are
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
- The daemon crash also stands for a Repo or `RunnerSupervisor` crash, or a
  crash of a child between them. The model kills every job process then; see
  JOB-8 for the AgentLoop that survives.
- The run-row value `unset` stands for the `"none"` the claim writes before a
  result exists (`scheduler.ex:632`). The final `"none"` of `delivery_mode
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
- Fairness: weak on each runner's, send helper's and Scheduler callback's next
  step, and on the runner's delivery timer. Strong on the Scheduler serving
  its mailbox and its own timers. None on the clock, the owner, the platform
  or crashes.
