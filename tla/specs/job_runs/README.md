# job_runs: scheduled jobs, from claim to delivery

Models `FermixCore.Jobs` for one recurring job: the Scheduler's due tick and
its atomic claim, one `Jobs.Runner` per run, delivery of the run's final text
through `Delivery.ChannelSend`'s watchdog, the Scheduler's monitors and its
reconciliation pass (at init and every 60 s), and the owner's pause, resume
and "run now". The runner's end is modelled as the code does it: separate Repo
calls for `mark_completed`, the memory write, `finalize_job` (a get, then an
upsert of the whole job row), the send, and `mark_delivery`.

Time is a clock of fire times: `now` counts the fire times that have passed,
and the job row's `next_run_at` is one of them. The AgentLoop is one step that
ends in text, `[SILENT]` or an error. Two run ids are reused once a run is
fully finished, so a check covers any number of runs. The spec's header lists
what is left out and every step folded into another.

**Environment switches** (set per check):
- `DaemonCanCrash`: the daemon dies once and boots again. Only SQLite rows and
  what the platform took survive. This also covers a `Memory.Repo` or
  `RunnerSupervisor` crash, since `:rest_for_one` restarts every job process
  in each case.
- `SchedulerCrashes`: how many times the Scheduler alone may die, at any point
  of any callback, including its own init. A 5 s `GenServer.call` timeout to
  the Repo is enough (`repo.ex:3623-3626`). Runners keep running.
- `RunnerCanCrash`: a runner dies at one of its Repo calls (a call timeout, a
  failed `{:ok, _}` match, `finalize_job`'s raise).
- `LoopCanFail`: the AgentLoop ends in an error or a timeout.
- `PlatformCanFail`: a send fails, either with no connection or with an error
  after the platform took the message.
- `ResponsesCanStall`: the platform takes a message and its answer never
  arrives in time. With `DeliveryWatchdog` off, the model waits forever,
  because the adapters' own HTTP timeouts are outside the sources.

The bounds are constants too: `NumRuns`, `Fires`, `SendAttempts` (3 in the
code, 2 in the checks), `OwnerMoves` (pause/resume requests) and `ManualRuns`.

**Mechanism switches** (`TRUE` is the real code; each is switched off by
exactly one check):
- `AtomicRaceStop`: the claim transaction refuses while a run is queued or
  running (`ensure_no_active_job_run`, `repo.ex:5561`, `:5614-5631`).
- `RetriesOnlyUnsent`: a send is retried only when it never reached the
  platform (`channel_send.ex:126-129`, `:180-188`). This is the mechanism for
  platforms that do not dedupe. The runner tags its send with the proactive
  key `job:<run id>` (`runner.ex:1302`). The mobile channel keeps one row per
  key (`mobile_sql.ex:41-43`), so a retry there would not show twice.
- `ReconcilesRuns`: at init and every 60 s the Scheduler reaps queued/running
  runs with no live runner and adopts live ones (`scheduler.ex:167`,
  `:196-270`).
- `CrashFailsPendingDelivery`: the crash path marks a dead runner's ok/pending
  delivery failed (`scheduler.ex:686-687`, `:711-719`).
- `DeliveryWatchdog`: the runner stops waiting for a send after
  `delivery_timeout_ms` (`channel_send.ex:200-219`).

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
- **An enabled job always gets back to claimable** (check 06), with one
  Scheduler restart, a manual run and loop errors. This rests on
  `ReconcilesRuns` (check 07). It does not hold with a second Scheduler
  restart, a daemon crash or a runner crash (JOB-1, JOB-3). "Claimable"
  (`scheduled`, no queued/running run) is weaker than §4.3's "runs again".
  It is what the Scheduler controls: the next run also needs its due time,
  and the model's clock stops at `Fires`.
- **Every pending delivery reaches a final status** (check 08), with runner
  crashes and failing or stalling sends, when the loop itself succeeds. This
  rests on `CrashFailsPendingDelivery` (check 09). It does not hold with loop
  errors (JOB-3) or daemon crashes (JOB-2).

Witness 10 shows the next run in its AgentLoop while the previous run is still
delivering. The race-stop counts rows, not runner processes.

**Deadlock checking finds nothing here.** The Scheduler's 60 s reconcile timer
is always armed, so an idle Scheduler always has a next step and no state is a
deadlock. `Done` and `Terminated` follow the convention but gate nothing. A
wedge shows up only as a broken liveness property (checks 05-09, 11-15, 22).

**Larger bounds.** Each holds check was also run by hand with one more of each
entity, one entity at a time. Raising every bound at once needs more than the
300 MB disk cap these runs were held to.

| Check | +1 run id | +1 fire time | +1 send attempt | +1 owner move | +1 manual run |
|---|---|---|---|---|---|
| 01 | no violation in the first 3,387,169 states (disk cap) | holds, 4,454,413 | holds, 830,429 | holds, 3,890,562 | holds, 4,729,601 |
| 03 | holds, 27,024 | holds, 158,051 | holds, 29,356 | holds, 536,768 | holds, 185,425 |
| 06 | holds, 293,503 | holds, 182,470 | holds, 73,017 | disk cap after 640,172 states¹ | holds, 193,328 |
| 08 | holds, 10,538 | holds, 61,105 | holds, 11,261 | holds, 207,024 | holds, 71,794 |

¹ The same check without loop errors completes and holds with one owner move
and one manual run (585,879 states).

One more Scheduler crash, run after the crash bound became a count:
- Check 01 (two crashes) holds, 1,358,405 states.
- Check 03 (one crash) holds, 82,690 states.
- Check 06 (two crashes) breaks: that is JOB-1, check 22.
- Check 08 (one crash) breaks through JOB-2's check-13 path: the restarted
  Scheduler does not adopt a runner already past `mark_completed`.

## Plan hypotheses

The plan (`docs/design/TLA_PLUS_MODELS.md` §4.3) listed four expected
findings. All four are confirmed.

1. **"A crash after `mark_completed` strands the run as `ok/pending`
   forever."** Confirmed as **JOB-2**. Boot reconciliation reads only
   queued/running rows (`repo.ex:5900-5915`). A Scheduler-only restart has
   the same gap, because it adopts only queued/running runs
   (`scheduler.ex:229-246`). A plain runner crash, with the Scheduler still
   monitoring it, is recovered (check 08).
2. **"A crash between `mark_completed` and `finalize_job` leaves the job stuck
   in `running`."** Confirmed, and wider than stated.
   - A daemon crash does it (**JOB-1**).
   - So does a Scheduler exit inside its own reaper, between the run-row
     write and the job-row write (**JOB-1**, check 22).
   - So does a runner crash the Scheduler sees, whenever the run's delivery
     is not pending (**JOB-3**).
3. **"`finalize_job` reads then upserts, so a pause landing between can be
   lost."** Confirmed as **JOB-4**. A resume can be lost the same way.
4. **"A pause and resume during a run spins at 0 ms."** Confirmed as
   **JOB-5**. A resume alone is enough, because `resume_job` never checks the
   job's state. The crash path can also cause it with no owner action. The
   rule reduces to "no due claim is ever refused as `:already_running`": the
   claim refuses only a job that is enabled, `scheduled` and due, and the
   re-arm then puts that same job at 0 ms.

## Findings

Every finding below was confirmed by walking the counterexample through the
code on `dev`. None has been reproduced on a running daemon. To see a
counterexample, run `tla/bin/check.py job_runs` and open
`tla/out/job_runs/<check>.txt`.

A violated liveness property has no pinned length: TLC's lasso is not the
shortest and can change between runs.

### JOB-1: a crash between a run row turning final and the job-row write wedges the job
- **Severity:** medium. The outcome is silent and permanent. A clean daemon
  stop (an app update, `brew upgrade`, a reboot) is enough of a trigger.
- **Status:** open.
- **Checks:** 11 (liveness), 22 (liveness).
- **Counterexample:**
  - Check 11: a run is claimed, so the job row says `running`. The run
    finishes and `mark_completed` writes the run row `ok`. The daemon dies
    before `finalize_job` writes the job row back to `scheduled`. On boot
    nothing touches the job again.
  - Check 22 has no daemon or runner crash. A claim commits and the
    Scheduler dies before starting the runner. The restarted Scheduler's
    init reaps the orphan: `mark_run_failed` writes the run row `error`
    first. The Scheduler dies again before the job-row write. No row is
    left queued/running, so no later reconcile sees the job.
  - Check 13 (JOB-2) reaches the same wedge: a Scheduler restart, then a
    crash of a runner that was not adopted.
- **Code:**
  - The claim sets the job to `running` (`repo.ex:5559-5566`,
    `scheduler.ex:602-606`). Only `finalize_job` (`runner.ex:355-372`), the
    crash path (`scheduler.ex:664-679`) and `resume_job`
    (`registry.ex:47-59`) ever set it back.
  - Each writer first makes the run row final, then writes the job row in a
    separate Repo call:
    - the runner: `runner.ex:252` then `:370`, and on the error path `:314`
      then `:423`, with the memory write (`:279`) in between;
    - the reaper: the run row at `scheduler.ex:667`/`:722`, then the job row
      at `:669` → `:772`/`:782`.
  - A 5 s `GenServer.call` timeout to the Repo exits either caller
    (`repo.ex:3623-3626`). A daemon stop during the boot reap has the same
    effect as check 22.
  - Reconciliation reads only queued/running rows (`repo.ex:5900-5915`,
    `scheduler.ex:229-246`). A run already marked `ok` or `error` is
    invisible to it.
  - The due scan and the timer lookup need `state = 'scheduled'`
    (`repo.ex:5484`, `:5513`). "Run now" answers `:already_running` for a
    `running` job (`scheduler.ex:479`).
  - On a clean stop the runner (which does not trap exits) dies as it would
    in a crash.
- **Impact:** the recurring job never runs again. Status shows it `running`
  forever, and "run now" refuses. Only a manual `resume_job` recovers it.

### JOB-2: a crash after `mark_completed` strands the delivery as `pending`
- **Severity:** low. Nothing is sent twice. The run's delivery status just
  never settles, and nobody can tell whether the message went out.
- **Status:** open.
- **Checks:** 12 (liveness), 13 (liveness).
- **Counterexample:**
  - Check 12: the run row is written `ok/pending`, then the daemon dies before
    `mark_delivery`. Boot reconciliation ignores the row.
  - Check 13: the Scheduler restarts while the runner is past
    `mark_completed`, so its reconcile scan does not adopt the runner. The
    runner then crashes, and no monitor sees it.
- **Code:** `mark_completed` sets `delivery_status: "pending"`
  (`runner.ex:248`, `delivery.ex:24-31`). Only `mark_delivery`
  (`runner.ex:331-353`) or a monitored crash (`scheduler.ex:686-687`) settles
  it. Reconciliation and adoption read only queued/running rows
  (`repo.ex:5900-5915`, `scheduler.ex:241-246`). The window covers the whole
  send, up to `delivery_timeout_ms` (60 s by default).
- **Impact:** the run shows a pending delivery forever. Both counterexamples
  also wedge the job, because the crash lands before `finalize_job`. Check
  13's final state has the job `running`, the run `ok/pending`, the runner
  gone and no monitor. So a Scheduler-only restart plus one runner crash
  gives JOB-1's outcome.

### JOB-3: a runner crash after its run row turns final wedges the job
- **Severity:** medium. It needs a Repo error or a slow Repo exactly during
  finalize. But `delivery_mode` defaults to `"none"`, so most jobs are
  exposed, and the wedge is silent and permanent.
- **Status:** open.
- **Checks:** 14 (liveness), 15 (liveness).
- **Counterexample:**
  - Check 14: a `[SILENT]` run is written `ok/skipped`. The runner then dies
    at `finalize_job`'s Repo call. The Scheduler gets the DOWN and does
    nothing to the job.
  - Check 15: the loop fails and `mark_failed` writes `error/pending`. The
    runner dies in `finalize_failed_job`, so the failure text is never sent or
    settled, and the job is wedged too.
- **Code:**
  - `mark_run_error` acts only on queued/running rows and on ok/pending
    (`scheduler.ex:681-698`). Everything else falls through
    `{:ok, _finished_run} -> :ok` (`:689-690`), and `mark_run_failed` then
    skips the job row (`:674-675`). That covers ok/skipped, ok/none
    (`delivery_mode "none"`, the default at `registry.ex:263`,
    `delivery.ex:27`) and error with any delivery status.
  - The runner dies there when `get_scheduled_job` returns an error
    (`finalize_job` raises, `runner.ex:377`, `:430`), when the upsert does
    not match `{:ok, _}` (`:370`, `:423`), or when a Repo call takes longer
    than `GenServer.call`'s 5 s default.
- **Impact:** as in JOB-1, the job never runs again until the owner resumes
  it. A failed run's error report never reaches the channel.
- **Confidence:** confirmed in code. It depends on a runner dying at those
  Repo calls, which the code does not rule out.

### JOB-4: `finalize_job` overwrites a pause or resume that lands mid-write
- **Severity:** low. The window is one Repo round trip, longer when the Repo
  is busy. The owner is told the opposite of what happens.
- **Status:** open.
- **Checks:** 16 (14 states), 17 (15 states).
- **Counterexample:**
  - Check 16: `finalize_job` reads the job (`enabled`, `running`). The owner's
    pause writes `paused`. `finalize_job` then upserts the row it read, with
    `running` changed to `scheduled`. The job is enabled again.
  - Check 17: the same interleaving with a resume. The paused row it read is
    written back over the resume.
- **Code:** `finalize_job` and `finalize_failed_job` call `get_scheduled_job`,
  then upsert the whole row (`runner.ex:358-370`, `:411-423`). The upsert
  writes every column (`repo.ex:5682-5770`). Pause and resume are
  read-then-upsert calls too (`registry.ex:42-59`, `:93-106`). The crash
  path's job write has the same shape (`scheduler.ex:735-745`, `:772-782`).
- **Impact:** the pause_job tool reports "paused", but the job keeps firing.
  Or resume_job reports "resumed", but the job stays paused.

### JOB-5: a claim refused as `:already_running` re-arms the due timer at 0 ms
- **Severity:** medium. An ordinary owner action can start a hot loop against
  the shared Repo that lasts up to the run's timeout.
- **Status:** open.
- **Checks:** 18 (12 states), 19 (31 states).
- **Counterexample:**
  - Check 18: a run is claimed, and the owner resumes the job mid-run. The
    job row now says `scheduled` while the run is active. Once `next_run_at`
    passes, the due claim is refused as `:already_running`, and the tick
    re-arms at 0 ms, again and again until the run ends.
  - Check 19 needs no owner. An earlier run crashes at `mark_delivery` while
    the next run is active. The crash path's job write turns `running` back
    into `scheduled`, and the spin follows.
- **Code:**
  - `:already_running` returns `{:ok, state}` (`scheduler.ex:447-448`), so
    the tick outcome stays `:ok`, and `due_delay_ms` floors a past-due job at
    0 ms (`:929-936`). This contradicts `:29-32` ("a persistently
    past-due-but-unclaimable job can never spin the scheduler at 0ms") and
    `:924-926`.
  - Two writers set `scheduled` during a run. `resume_job` has no state
    guard (`registry.ex:47-59`). The crash path writes
    `completed_job_state`/`failed_job_state` over whatever run is current
    (`scheduler.ex:735-745`, `:768`, `:803`).
- **Impact:** each spin makes three Repo calls, one of them a `BEGIN
  IMMEDIATE` transaction, for as long as the active run lasts (30 min by
  default, `runner.ex:29`). That burns CPU and slows every other Repo
  caller.

### JOB-6: a delivery recorded as `failed` may have reached the user
- **Severity:** low. The run row is wrong. Nothing is re-sent.
- **Status:** open.
- **Checks:** 20 (15 states), 21 (18 states).
- **Counterexample:**
  - Check 20: the platform takes the final text, but its answer does not
    arrive before `delivery_timeout_ms`. The watchdog kills the send and
    `mark_delivery` records `failed`.
  - Check 21: the send succeeds, then the runner dies at `mark_delivery`. The
    crash path marks the still-pending delivery `failed`.
- **Code:** `ChannelSend.with_timeout` cannot tell whether the platform
  already took the message (`channel_send.ex:214-218`, `runner.ex:326-327`).
  `mark_pending_delivery_failed` (`scheduler.ex:711-719`) assumes an
  unrecorded send failed.
- **Impact:** the operator sees a failed delivery for a message the user has.
  This is the cost of the at-most-once choice, which check 03 proves.
- **Confidence:** check 20 depends on a platform that accepts a message and
  answers after the timeout.

## Assumptions

- Every Repo call either completes or its caller dies. SQLite busy/errors are
  not modelled. A `:busy` claim would take the 5 s backoff instead.
- A runner dies only at a Repo call or a file write, never while it waits in
  `receive` (the AgentLoop or a send). Nothing in its own code raises there.
  - The `{:ok, _} = write_run_artifact` writes (`runner.ex:235`, `:299`) are
    folded into `MarkCompleted`/`MarkFailed`, so they share the `complete` and
    `fail` crash points.
  - The memory-source calls after `finalize_job`'s upsert (`runner.ex:371`,
    `:424`) are a crash point with no pc of their own. A crash there leaves
    the rows a crash at `mark` leaves, minus the send.
- `delivery_mode` `"none"`/`"local"` behaves like a `[SILENT]` result: the
  initial status is final at once (`delivery.ex:24-31`, `:82-84`).
- The folded steps listed in the spec header. The folds drop only
  interleavings whose outcome the unfolded code also reaches.
- The daemon crash also stands for a Repo or `RunnerSupervisor` crash. Those
  leave the send helper and the AgentLoop process alive: they are
  `spawn_monitor`ed, not linked (`channel_send.ex:205`, `runner.ex:1024`). The
  model kills them. A surviving helper can land at most one more copy of the
  final text, which no row records.
- The run-row value `unset` stands for the `"none"` the claim writes before a
  result exists (`scheduler.ex:616`). The final `"none"` of `delivery_mode
  "none"` is modelled as `skipped`.
- The due timer is modelled from the row as it is now. The code arms it once
  and does not re-arm it when `FinWrite` or the reaper writes an older
  `next_run_at` back (`runner.ex:370`, `scheduler.ex:782`: no
  `:job_changed`). So the model's `DueTimerFires` can tick earlier than the
  code. The verdicts survive: the 60 s reconcile tick runs the same scan,
  may fire at any point and is strongly fair.
- With both run ids in use, a claim or "run now" is treated as not due. This
  is the model's bound, not code behaviour.
- The admission ceiling (4 runs) is never reached by one job. Expiry,
  one-shot jobs, an unparseable schedule and the stale-skip are not modelled.
- `update_job` is not modelled. It is a read-then-upsert of the whole row
  (`registry.ex:61-70`, `:108-116`), with the same shape as JOB-4, so an edit
  racing a claim could also write `scheduled` back mid-run.
- Fairness: weak on each runner's, send helper's and Scheduler callback's next
  step, and on the runner's delivery timer. Strong on the Scheduler serving
  its mailbox and its own timers. None on the clock, the owner, the platform
  or crashes.
