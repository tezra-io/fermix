# computer_history: the capture buffer versus pause, disable and purge

Models Computer History's write path against the owner's three privacy
controls. The compux sidecar stamps each observed event with the wall clock.
The `Capturer` GenServer keeps it in an in-memory buffer, and a flush (the 2 s
timer, the 25-event size trigger, or `terminate/2`) hands the buffer to
`Ingest`. `Ingest` makes two `Memory.Repo` calls: it reads the pause horizon
and drops each event stamped before it (or arriving while it is in force), then
inserts the rest into the spool, which refuses a row stamped inside a recorded
purge interval. Against that it models:

- `/history pause <d>`: one Repo call that stores `pause_until`, then the reply.
- `/history purge <w>`: one Repo transaction that deletes spool rows in
  `[now - w, now]` and records that interval.
- `/history off`: flip the app env, call the `Controller`, save `config.toml`
  whatever the call returned, and reply with what the stop confirmed.

It also models the processes around the Capturer and their real supervision:
the `DynamicSupervisor` that restarts it (every start re-reads the enable bit),
the `Controller` that stops it (a `Process.whereis` lookup, then a
`terminate_child` call, as two steps), and the `:rest_for_one` supervisor that
restarts the Controller.

Two events and a clock of 0..3 cover the interleavings that matter: an event
stamped inside a window, and a flush before or after the window ends. Out of
scope as single calls (TLA_PLUS_MODELS.md §5.1), and covered by ExUnit: the
summarizer and the roll-up with their purge guard (a note or thread is refused
when a purge issued after its batch was read reaches it), the migration of a
stored watermark into one interval, pruning at the 48 h sweep, `purge all`
(`[0, now]`, a window like any other) and the Setup UI disable path. The spec
header lists everything else left out.

**Environment switches** (set per check):
- `OwnerCanPause`, `OwnerCanPurge`, `OwnerCanDisable`: the owner sends that
  command. Pause and purge are sent at most once. `/history off` is sent once,
  or again if a daemon restart killed it before its reply.
- `DaemonCanRestart`: the daemon stops and boots again. Only SQLite rows
  (the spool, `pause_until`, the purge intervals) and `config.toml` survive.
- `ControllerCanCrash`: the Controller dies alone, at any point (for example
  `do_reconcile` raises), and `ComputerHistory.Supervisor` restarts it.
- `CapturerCanCrash`: a Capturer callback raises, and its DynamicSupervisor
  restarts it.
- `ReconcileCanTimeOut`: `/history off`'s reconcile call gives up after its
  15 s timeout (`controller.ex:45`, `:53-54`). The timer starts at
  `history.ex:487`.
- `ReconcileCanStall`: that timeout can fire before the DynamicSupervisor has
  sent the Capturer `:shutdown`. Setting it `FALSE` is a timing assumption:
  the work before the `:shutdown` is app-env reads, `File.regular?` stats in
  `SidecarInstaller.installed?` (`controller.ex:94`,
  `sidecar_installer.ex:62-67`) and a `Process.whereis` (`controller.ex:128`),
  so the assumption fails only if the filesystem or the scheduler stalls for
  seconds. No safety rule needs it any more (see What holds).
- `MaxFaults` bounds restarts and crashes together (1 in every check).

**Mechanism switches** (`TRUE` is the real code; each is switched off by the
`needs` checks that show a rule depends on it):
- `IngestChecksPause`: Ingest has a pause gate at all. It reads the horizon
  once per batch and drops each event while the pause is in force,
  `now < pause_until` (`ingest.ex:175`, `:178`, `:231-240`). Off, nothing is
  dropped.
- `PauseByStamp`: the gate also drops each event stamped before the horizon,
  however late its batch is flushed: the `ts` half of
  `min(ts, now) < pause_until` (`ingest.ex:234-235`), the CH-1 fix. Off, the
  gate is the flush-time rule of 693970b7.
- `StopBeforeReply`: `/history off` replies only after its reconcile call
  returns, and that call returns only after the Capturer has exited
  (`history.ex:487`, `computer_history.ex:70`, `controller.ex:53-54`, `:133`).
- `SaveBeforeReply`: `/history off` writes `config.toml` before it replies
  (`history.ex:482`, `:490-493` before `:426-427`).
- `BootReconciles`: a started or restarted Controller reconciles in
  `handle_continue` (`controller.ex:57-74`).
- `OffConfirmsStop`: an exit of the reconcile call (no Controller, a crash
  mid-call, a timeout) comes back as `{:error, {:reconcile_failed, _}}`
  (`computer_history.ex:68-75`), and `/history off` then says the stop could
  not be confirmed instead of "nothing new is captured" (`history.ex:447-452`).
  Off, the exit reads as a confirmed stop (the code at 693970b7).
- `InitChecksEnabled`: every Capturer start, a DynamicSupervisor restart
  included, re-reads `ComputerHistory.operative?/0` and returns `:ignore`
  while the feature is off (`capturer.ex:124-130`); the DynamicSupervisor then
  deletes the child.
- `InsertChecksIntervals`: the spool insert refuses, inside its own
  transaction, each row whose `ts` lies inside a recorded purge interval,
  bounds inclusive like the purge's `DELETE` (`computer_history_sql.ex:358-402`,
  `:664-675`), the CH-2 fix. Off, it is the plain `INSERT OR IGNORE` of
  693970b7.

## What holds

Check 01 runs with daemon restarts, a Controller or a Capturer crash at any
point, reconcile timeouts that may fire before the `:shutdown`
(`ReconcileCanStall = TRUE`, so it needs no timing assumption), and a pause:
- Nothing captured after the `/history off` reply lands in the spool (the
  disable half of M32 invariant 12). This rests on `StopBeforeReply` (check
  02), on `SaveBeforeReply` across a restart (check 03), on `OffConfirmsStop`
  when the Controller dies or the call times out (check 18, today's CH-3
  paths), and on `InitChecksEnabled` when a Capturer restart races the
  disable (check 19, today's CH-4 path).
- Nothing captured after the pause reply is stored, and nothing captured
  while the stored pause is in force is ever stored, whenever its batch is
  flushed (M32 invariant 12's pause half, and the claim at
  `ingest.ex:217-230`). Both rest on the gate existing at all:
  `IngestChecksPause` off (checks 17 and 04) stores an event while the pause
  is still in force, in 6 and 5 states. The first also rests on the CH-1 fix:
  `PauseByStamp` off (check 27) brings back CH-1's 7-state path, a flush
  after the horizon.

Check 05 runs with a Controller or a Capturer crash at any point, daemon
restarts and reconcile timeouts, including ones that fire before the
`:shutdown`:
- After the `/history off` reply, confirmed or not, capture eventually stops
  for good. This rests on `BootReconciles` (check 06) and on
  `InitChecksEnabled` (check 20, today's CH-4 lasso).
- Fairness is weak fairness on the Capturer, the DynamicSupervisor, the
  Controller and its supervisor, and the steps of a command already running.
  The owner, the clock, the sidecar's events, crashes and timeouts get none.
- The pause is off in 05, because a pause only decides whether a batch is
  dropped or stored.

Check 11 runs with a purge, `/history off`, Capturer crashes and daemon
restarts:
- No event stamped inside the purged window lands in the spool after the
  purge, whether it was still buffered, in a batch already past its pause
  check, or flushed by `terminate/2` (the claim at `purge.ex:3-9`, and M32
  §12). This rests on `InsertChecksIntervals`: off (check 28), CH-2's 5-state
  path is back. With the fence switched off for `terminate/2`'s insert only
  (a hand edit, reverted), 11 fails in 6 states through a Capturer crash, so
  11 covers that path too.
- The pause is off in 11: the pause gate runs before the insert and never
  moves an event into the spool.

The checks that found CH-1, CH-3 and CH-4 now hold in their original,
smaller settings, each with a `needs` check that switches the fix off and
gets the old counterexample back: 09 and 10 (CH-1; checks 21, 22 with
`PauseByStamp` off), 12 and 15 (CH-3; checks 23, 26 with `OffConfirmsStop`
off), 13 and 14 (CH-4; checks 24, 25 with `InitChecksEnabled` off).

Witnesses:
- Check 07: the terminate-time flush of `/history off` writes buffered events
  before the reply. This covers the plan's hypothesis that this flush writes
  only events from before the acknowledgement.
- Check 08: a batch whose pause check ran before the pause was stored is
  inserted after the owner has read "paused until …". The rows land after the
  ack, but every one was stamped before it, so invariant 12 is not broken.
- Check 16: CH-4's second path, now harmless. The Controller's `whereis`
  returns a Capturer that then exits; its restart declines because the
  feature is off, so the Controller's `terminate_child` is answered
  `{:error, :not_found}`, logged "already gone" (`controller.ex:142-143`),
  with no Capturer running.
- Check 29: CH-2's path, now closed. A row stamped inside the purged window
  reaches the spool insert after the purge committed, and the fence refuses
  it (`computer_history_sql.ex:385-395`), so the fence is not vacuous.

**One more of each entity, run by hand** (TLC 2.19, `-workers auto`): each row
changes the check's constants as shown, and every other constant stays as in
the check.

On this revision (per-event pause gate, `OffConfirmsStop`,
`InitChecksEnabled`, and 01/05 with every fault switch on). These runs predate
the `PauseByStamp` switch; with it `TRUE`, as in 01 and 05, the model is the
same:

| Check | Change | Result | Distinct states |
|---|---|---|---|
| 01 | `MaxFaults = 2` | holds | 14,393,154 |
| 05 | `MaxFaults = 2` | holds | 535,592 |

On the previous revision (before the CH-1, CH-3 and CH-4 fixes, with 01 at
`ControllerCanCrash = CapturerCanCrash = ReconcileCanStall = FALSE` and 05 at
`CapturerCanCrash = FALSE`):

| Check | Change | Result | Distinct states |
|---|---|---|---|
| 01 | 3 events | holds | 10,977,935 |
| 01 | clock 0..4 | holds | 1,307,319 |
| 01 | `MaxFaults = 2` | holds | 1,775,112 |
| 05 | 3 events | holds | 1,022,558 |
| 05 | clock 0..4 | holds | 170,755 |
| 05 | `MaxFaults = 2` | holds | 419,266 |
| 05 | `OwnerCanPause = TRUE` | holds | 2,874,210 |

All three bumps at once did not finish on that revision: the machine had
under 3 GB of free disk, TLC's state files filled it, and the run was
stopped. On the revision before it (before `ReconcileCanStall`, the
Controller's split lookup and crashes at any point) both held: 01 with
63,913,510 distinct states and 05 with 2,868,075.

## Plan hypotheses

- **Ingest checks the pause at write time: confirmed** (at 693970b7).
  `Ingest.ingest` called `capture_paused?`, which read `pause_until` through
  `computer_history_ensure_state` and compared it with `DateTime.utc_now()`,
  never the event's own `ts`. Since the CH-1 fix it reads the horizon once
  (`ingest.ex:175`, `:243`) and judges each event by `min(ts, now)`
  (`:178`, `:231-240`).
- **Purge is one transaction that sets the watermark, and spool inserts do
  not check it: confirmed** (at 693970b7). `purge_window`
  (`computer_history_sql.ex:509-561`) deleted, then raised
  `purge_watermark_ts` (`:548`), inside one `BEGIN IMMEDIATE` (`:1231`), all
  in one Repo call. `insert_events` (`:310-335`) was a plain `INSERT OR
  IGNORE`. Only the summarizer's `write_cycle_result` read the watermark
  (`:1015-1043`). Since the CH-2 and CH-5 fix the purge records an interval
  in the same transaction (`:606-647`), and the insert checks every recorded
  interval (`:358-402`).
- **`/history off`: env flip, then terminate the Capturer, then save
  config: confirmed.** The order is:
  1. flip (`history.ex:479-480`);
  2. a synchronous reconcile (`:482`, `:487`), which returns after
     `DynamicSupervisor.terminate_child` returns, which waits for
     `terminate/2`; since the CH-3 fix an exit of the call comes back as an
     error, not `:ok`;
  3. save (`:490-493`), whatever the reconcile returned;
  4. reply (`:426-459`), chosen by both outcomes.
- **Events captured during a pause but flushed after it ends are stored:
  confirmed → CH-1 (fixed).**
- **Buffered events land inside a purged window, known and tolerated:
  confirmed → CH-2 (fixed).** At 693970b7 the summarizer test
  (`summarizer_test.exs:1297-1312`, "a note the repo refuses is never logged
  as ok") purged `[0, 5000]`, inserted an event stamped 1000 afterwards, and
  asserted `memory_written: false`. It covered the memory only; no test
  covered the raw spool row, which stayed. The test now purges from inside the
  stub adapter's call, after the batch was read, and `purge_test.exs` "the
  spool fence" covers the row.
- **The terminate-time flush of `/history off` writes only events captured
  before the acknowledgement: confirmed (check 01, witness 07).** The EXIT
  queues behind the Capturer's earlier messages, and `terminate/2` flushes
  only what is already buffered (`capturer.ex:589-598`). The reply waits for
  that. The plan did not anticipate the other paths to the same reply that
  broke the disable half, CH-3 and CH-4; with both fixed, 01 no longer needs
  the timing assumption it once did.

## Findings

Every finding below was confirmed by walking the counterexample through the
code on `dev`. None has been reproduced on a running daemon. To see a
counterexample, run `make -C tla check SPECS=computer_history` and open
`tla/out/computer_history/<check>.txt`. The counterexample and **Code** lines
of a fixed finding cite 693970b7, where it was found; its **Fix** lines cite
the fixed code.

### CH-1: a pause does not cover events flushed after it ends
- **Severity:** medium (it happens at the end of every pause while the owner
  is active; the leak is bounded to what is buffered at the horizon, at most
  one 2 s flush interval or 25 events).
- **Status:** fixed (d514e149).
- **Checks:** 09 (M32 invariant 12) and 10 (the rule the fix now claims) hold;
  21 and 22 get the old 7- and 6-state counterexamples back with
  `PauseByStamp` off (the flush-time gate). 01 holds both rules with every
  fault on; 27 gets the same 7-state path back there with `PauseByStamp` off.
  04 and 17 switch the whole gate off (`IngestChecksPause`), so their 5- and
  6-state traces store an event while the pause is still in force, not
  CH-1's flush after the horizon.
- **Counterexample:**
  1. The owner pauses for one tick, and the reply comes back.
  2. The sidecar observes an event inside the pause, and the Capturer buffers
     it.
  3. The horizon passes.
  4. The next flush's pause check reads the horizon, finds it past, and
     inserts the batch, including the event stamped inside the pause.
- **Code:**
  - `ingest_event` buffers the event (`capturer.ex:419-430`), and the 2 s
    timer flushes the buffer (`:325-335`).
  - `capture_paused?` compares `utc_now()` with `pause_until`
    (`ingest.ex:213-222`) and never the event's `ts`, then inserts
    (`:188`).
  - Nothing flushes or fences the buffer at the pause ack. The design
    describes that step (MILESTONE_32 §7.1, and invariant 12: "the capturer
    stamps a stop-fence and drops later-stamped events"), and the code has
    none.
  - `history_test.exs:332-354` shows the same event being written once the
    horizon is in the past.
- **Clock:** the event's `ts` is the sidecar's clock (`wire.ex:95`); the pause
  check reads the daemon's `utc_now()` (`ingest.ex:221`). The spec uses one
  clock for both, since both read the same machine's wall clock.
- **Impact:** the last seconds of every pause are recorded, although the owner
  was told "paused until X". This breaks M32 invariant 12 for the pause.
  Frames held while the recorder is handshaking (`capturer.ex:447-452`) can
  widen the window.
- **Fix:** Ingest reads the horizon once and splits the batch event by event
  (`ingest.ex:173-179`): an event is dropped when `min(ts, now) < pause_until`
  (`:231-235`), an unparseable horizon drops every event (`:232`), and an
  event with no integer `ts` is dropped while a horizon is set (`:237-240`).
  The paused count is added to `dropped`, and a batch with no survivors makes
  no insert call (`:183-192`). Every flush path (timer, size trigger, ack,
  `exit_status`, degrade, `terminate/2`) reaches Ingest through `do_flush`
  (`capturer.ex:483-487`), so each is covered. Side effect, allowed by
  MILESTONE_32 §7.1 ("discarded"): events still buffered from before the pause
  began are dropped too, as the old flush-time check already did. Tests:
  `ingest_test.exs` "pause horizon (inv. 12)"; `history_test.exs` "pause is
  ENFORCED at ingest" now asserts the pre-horizon event stays out after the
  horizon.

### CH-2: buffered events land inside a purged window
- **Severity:** low (bounded to what is buffered or in flight at the purge:
  at most one 2 s flush or 25 events).
- **Status:** fixed (d514e149).
- **Checks:** 11 holds with `/history off`, Capturer crashes and daemon
  restarts; 28 gets the old 5-state counterexample back with
  `InsertChecksIntervals` off; witness 29 shows the fence refusing the late
  row.
- **Counterexample:**
  1. An event is captured, and a flush passes its pause check, so the batch
     is in flight.
  2. The owner's purge of that window commits.
  3. The flush's insert lands the event inside the purged window.

  An event still in the buffer at the purge lands the same way.
- **Code:**
  - The purge window is `[now - ms, now]` (`purge.ex:77`), and it deletes only
    rows already in the spool (`computer_history_sql.ex:517`).
  - The insert (`:322-335`) never reads the watermark (`:548`).
  - `ingest.ex:174` and `:188` are two Repo calls, so a purge can commit
    between them.
- **Clock:** the purge window comes from the daemon's clock (`purge.ex:57`),
  and the event's `ts` from the sidecar's (`wire.ex:95`); the spec uses one
  clock for both.
- **Impact:**
  - Raw activity from the purged window reappears in the spool after "Purged
    N event(s)". It stays until the 48 h sweep and is counted in `/history
    status`.
  - The late row gets a fresh id above the summarizer's cursor, so the next
    cycle reads it (`summarizer.ex:429-430`, no purge check) and sends it to
    the summarizer's route, after the owner was told it was purged.
  - The summarizer then refuses the note, because its `provenance_from_ts`
    (the sitting's earliest `ts`, `summarizer.ex:952`) is at or before the
    watermark (`computer_history_sql.ex:1040-1043`), and the cursor still
    advances (`:1005-1012`), so the sitting's post-purge activity is never
    summarized.
- **Fix:** the one high-water watermark is replaced by recorded purge
  intervals (owner decision). `purge_window` records `[from, to]` with its
  `issued_at` in the transaction that deletes the rows
  (`computer_history_sql.ex:606-647`). The spool insert checks each row's
  integer `ts` against every recorded interval, inclusive, inside its own
  transaction (`:358-402`, `:664-675`): that is the one placement that also
  stops a batch already past Ingest's pause check, because the purge and the
  insert are each one transaction on the single writer. The fenced count is
  logged (`:405-411`); a row with no integer `ts` is left to the `NOT NULL`
  refusal. Every flush path reaches this insert (`ingest.ex:201` is its only
  caller). Tests: `purge_test.exs` "the spool fence" (a late row at and
  inside the bounds, and an older window still fencing after a newer one),
  `purge_fence_log_test.exs`.
- **Also fixed with it** (the over-refusal the validator found in the
  summarizer, outside this model): a note or thread is now refused only when
  a purge issued after its batch was read reaches it. The reader takes the
  purge mark, the id of the latest recorded purge, before it reads
  (`Summarizer.run_session/4`, `Rollup.maybe_run/3`), and the write refuses
  when an interval with a higher id intersects the note's provenance
  (`computer_history_sql.ex:1141-1151`) or the window of everything the
  roll-up read (`:1220-1228`, `Rollup.read_scope/3`). A windowed purge no
  longer voids every later note of a sitting that began before it, and a
  purge before the roll-up no longer refuses the threads built from the
  notes around it. Ids, not clocks: a clock step cannot reorder a purge and a
  read. Tests: `summarizer_test.exs` "purge intervals and the note write"
  (including a purge landing right after the batch read, which pins the mark
  before the read), `summarizer_rollup_test.exs` (a purge before the roll-up;
  a purge right after its notes read; a purge during it that reaches a note
  no thread cites), `persistence_test.exs` "roll-up write".
- **Not fixed by it:** the purge acknowledgement used to say the removed
  threads "are rebuilt at the next roll-up from what remains". The roll-up
  reads only the surviving threads and the notes written since the last
  roll-up (M32 §24: "the next roll-up rebuilds from the surviving notes since
  the last roll-up"), so an older note that only a removed thread cited backs
  no thread again, and with no new note there is no roll-up at all. The
  acknowledgement now says what the roll-up does (`history.ex`, `run_purge/2`;
  owner copy sign-off pending). Re-reading those orphaned notes would be a
  design change and is an open owner question.

### CH-3: `/history off` replies without confirming the Capturer stopped
- **Severity:** low (both triggers are unlikely, and capture stops once the
  Controller reconciles).
- **Status:** fixed (d514e149).
- **Checks:** 12 (dead Controller) and 15 (stalled reconcile) hold; 23 and 26
  get the old 9-state counterexamples back with `OffConfirmsStop` off. 01
  holds the disable half with both triggers on (18).
- **Counterexample, check 12:**
  1. The Controller dies.
  2. `/history off` flips the env. Its reconcile call exits (`:noproc`), and
     `reconcile_runtime` returns `:ok`.
  3. The config is saved, and the owner is told "nothing new is captured".
  4. The still-running Capturer buffers and flushes an event captured after
     the reply.

  The restarted Controller's boot reconcile (`controller.ex:55-63`) stops the
  Capturer later, so capture does stop (check 05).
- **Counterexample, check 15:** the reconcile call times out before the
  Controller has had the DynamicSupervisor send `:shutdown`. The same
  `catch :exit` returns `:ok`, the reply goes out, and the running Capturer
  stores an event captured after it. The Controller then stops the Capturer.
- **Code:**
  - `computer_history.ex:67-74` catches every `:exit` (`:noproc`, a timeout,
    a crash mid-call) and returns `:ok`, and `history.ex:448` ignores the
    result.
  - Neither the Capturer nor Ingest reads the enable bit
    (`capturer.ex:106-156`, `ingest.ex:171-202`).
- **Impact:** events captured between the reply and the Capturer's actual stop
  are stored.
- **Confidence, check 12:** it needs the Controller to die **alone**, for
  example `do_reconcile` raising (`controller.ex:82-85`), right at
  `/history off`. A DynamicSupervisor crash also restarts the Controller
  (`:rest_for_one`, `supervisor.ex:49-60`), but it shuts the Capturer down
  first, so it cannot cause this. The window is then the supervisor's
  restart latency.
- **Confidence, check 15:** it needs the reconcile to take longer than the
  5 s call timeout before the `:shutdown` is sent. The work before it is
  app-env reads, file stats and a `whereis` (see `ReconcileCanStall`), so only
  a stalled filesystem or scheduler does this.
- **Fix:** `reconcile_runtime(server \\ Controller)` returns any exit of the
  call as `{:error, {:reconcile_failed, reason}}` and logs it at error
  (`computer_history.ex:68-75`). `/history off` reconciles only on macOS, the
  one host with a rail (`history.ex:482`, `:487-488`), through a
  `:computer_history_controller` context seam (`:64`), always saves
  (`:490-493`), and picks one of four replies from `{stop, save}`
  (`:426-459`): "nothing new is captured" only for a confirmed stop and a
  saved setting; an unconfirmed stop says the recorder could not be confirmed
  stopped and points to `/history status`. There a Capturer that does not
  answer the status call in time reads "not answering (it may still be
  running)", not "not running" (`capturer.ex:107-116`, `history.ex:123`), so
  "not running" means the process is gone. `Controller.reconcile/2` waits
  15 s (`controller.ex:45`, `:53-54`), above the two children's 5 s
  shutdowns, so a slow `terminate/2` flush no longer turns into a false
  failure. Side effect: a timeout after the `:shutdown` (a Repo stalled for
  over 15 s) now reports an unconfirmed stop, which is true. Tests:
  `history_test.exs` (absent controller, crashing controller, non-macOS host,
  confirmed stop, a status that does not answer), `controller_test.exs`
  (`reconcile_runtime` with no controller, `reconcile/2`'s timeout),
  `capturer_test.exs` "status/2". The two save-failure replies have no
  ExUnit test: `ConfigStore` offers no failure seam.

### CH-4: a Capturer restart racing `/history off` keeps capturing until the next boot
- **Severity:** medium (the trigger is rare, but the owner is told capture is
  off while it goes on indefinitely).
- **Status:** fixed (d514e149).
- **Checks:** 13 and 14 (liveness) hold; 24 gets the old 13-state
  counterexample back with `InitChecksEnabled` off, and 25 the old lasso. 01
  and 05 hold with Capturer crashes on (19, 20). Witness 16 now shows the
  second path ending in "already gone" with no Capturer running.
- **Counterexample, check 13:**
  1. A Capturer callback raises. `terminate/2` runs, and the process exits.
  2. Before the DynamicSupervisor restarts it, `/history off` flips the env.
  3. The Controller's `Process.whereis(Capturer)` finds no process, so
     `ensure_stopped` does nothing and the reconcile returns.
  4. The DynamicSupervisor restarts the Capturer.
  5. `/history off` saves and replies.
  6. The new Capturer captures and stores events.

  Nothing reconciles again while the daemon runs (check 14).
- **Second path (witness 16):**
  1. `whereis` returns the Capturer while it is still in `terminate/2`.
  2. It exits, and the DynamicSupervisor restarts it.
  3. The Controller's `terminate_child` then names the old pid.
  4. OTP answers `{:error, :not_found}` for a pid whose EXIT it has already
     handled. That was checked against a plain DynamicSupervisor. The error
     is ignored (`_ =`, `controller.ex:118`), and the log still says
     "stopped".
- **Code:**
  - `ensure_stopped` returns `:ok` on a nil pid and ignores a `terminate_child`
    error (`controller.ex:112-121`).
  - The Capturer is a `:permanent` child (the `use GenServer` default,
    `capturer.ex:43`) of the DynamicSupervisor (`supervisor.ex:55`).
  - Its `init` (`capturer.ex:106-156`) and Ingest never check the enable bit.
  - `reconcile_runtime` is called only from `history.ex:448`.
- **Impact:** capture continues after "Computer history disabled — nothing new
  is captured" until the daemon restarts. `config.toml` says disabled, so the
  next boot does not start it. Meanwhile `/history status` shows "Computer
  history: off" beside "Capture: running".
- **Confidence:** it needs a Capturer crash, for example a Repo call past its
  5 s default (`repo.ex:3777-3780`), and the windows are tiny:
  - The first path needs the Controller's `whereis` to run between the old
    Capturer's exit and its restart. The DynamicSupervisor restarts the child
    in the same message that handles its EXIT, and `Capturer.init` does no
    I/O (`capturer.ex:106-156`; the lock and the Port wait for
    `handle_continue`). So the window is the time the EXIT spends in the
    DynamicSupervisor's mailbox: microseconds when it is idle.
  - The second path needs the Capturer to exit and be restarted between the
    Controller's `whereis` and its call. That window is a few instructions of
    Controller code, and a slow crash `terminate/2` flush (a Repo call) can
    widen it.
- **Fix:** `Capturer.init/1` re-reads the one resolver,
  `ComputerHistory.operative?/0` (injectable as `:operative_fun`), and
  returns `:ignore` while the feature is off, before it traps exits or builds
  any state (`capturer.ex:124-130`). On a restart the DynamicSupervisor then
  deletes the child. The name is registered before `init` runs and History
  flips the env before it calls, so either the Controller's `whereis` sees
  the new pid and stops it, or `init` reads the flip and declines: both paths
  close. The Controller takes `:ignore` from `start_child` (a start racing
  the flip, `controller.ex:117-118`) and logs `terminate_child`'s answer:
  `:ok` as "stopped", `{:error, :not_found}` as "already gone"
  (`:133`, `:137-143`). Tests: `capturer_test.exs` "a restart racing
  /history off (CH-4)" (the DynamicSupervisor is suspended to hold the EXIT),
  `controller_test.exs` (a child that declines), `controller_stop_log_test.exs`
  (a not-found stop).

### CH-5: `/history purge all` stops every later session note and thread
- **Severity:** high (after one `purge all`, the rail never writes another
  session note or thread, silently, until the state row is repaired).
- **Status:** fixed (d514e149).
- **Check:** none. It is a single-call fact about stored state, outside the
  model (`purge all` is out of scope, see the spec header); ExUnit covers it.
- **Code:**
  - `purge all` bounds its window with a far-future ceiling:
    `@max_ts 9_999_999_999_999` (`purge.ex:26`), `bounds(:all, _now)` →
    `{0, @max_ts}` (`:76`).
  - `purge_window` raises the watermark to the window's end and never lowers
    it: `SET purge_watermark_ts = MAX(COALESCE(purge_watermark_ts, 0), ?)`
    (`computer_history_sql.ex:545-549`). After `purge all` it is
    9_999_999_999_999 for good.
  - The summarizer's note write refuses any note whose
    `provenance_from_ts <= watermark` (`computer_history_sql.ex:1040-1043`),
    and the roll-up rejects threads the same way (`:1098-1100`). Every future
    timestamp is below the watermark, so every note and every thread is
    refused.
- **Impact:** once the owner runs `/history purge all`, capture goes on and
  raw events keep reaching the summarizer's route, but no session note or
  thread is ever written again; recall and "what am I working on" go stale
  with nothing in `/history status` to say why.
- **Fix:** `purge all` is `[0, now]` (`purge.ex:75-79`; `@max_ts` is gone).
  A row stamped in the future by a backwards clock step is therefore not
  covered; the 48 h sweep deletes it 48 h after its stamp (owner decision).
  Migration 32 (`repo.ex:3887-3906`, `computer_history_sql.ex:275-298`)
  carries a stored watermark W over as one interval `[0, min(W, now)]` issued
  at the migration, the sentinel included; nothing reads or writes a
  watermark any more. The old column stays, unread, because `fermix upgrade`
  can roll back to the previous engine, which reads it on every state read
  (a later release drops it). Because the note and thread guard
  now counts only purges issued after a batch was read, that interval
  refuses nothing, and the fence refuses only rows stamped before the
  upgrade, which a restarted daemon no longer holds. The retention sweep
  prunes an interval once it was both issued and ended before the 48 h cutoff
  (`computer_history_sql.ex:420-444`). Tests: `persistence_test.exs`
  "migration 32" (a windowed watermark, the sentinel, a store that never
  purged) and "purge intervals" (issue order, pruning), `purge_test.exs`
  "purge all records [0, now] and later capture is still stored",
  `summarizer_test.exs` "a note is written for activity after purge all".

## Assumptions

- **Timing:** no `holds` check of a safety rule needs `ReconcileCanStall =
  FALSE` any more: 01-04 and 17-19 set it `TRUE`, and so do 05, 06 and 20.
  The smaller checks that set it `FALSE` do so only to keep their scenario
  small; 15 and 26 set it `TRUE` for CH-3's stalled-reconcile path.
- A daemon restart is a hard stop, and buffered events are lost. A clean
  shutdown's `terminate/2` flush is the same as a flush just before the stop,
  which the model allows.
- A `:flush` timer message queued ahead of the EXIT writes the same buffer
  `terminate/2` writes, so flushes are modelled only before the EXIT.
- `terminate/2` finishes within the DynamicSupervisor's 5 s shutdown. For the
  spool, a kill would only lose buffered events; it would also skip
  `stop_driver` and the lock release (`capturer.ex:595-596`), which no
  property here reads.
- The sidecar's `ts` and the daemon's `utc_now()` read the same machine clock
  (CH-1, CH-2).
- The purge fence works at tick granularity: an event captured after the
  purge in the same tick (`ts = clock = hi`) is refused too. That
  over-approximates the code's 1 ms edge, and no property depends on it.
- A backwards clock step after a purge: until the clock passes the
  interval's end again, the insert refuses an event the sidecar stamps inside
  it (logged at info, counts only). The window stays purged, so this is the
  fence working, not a defect; the model has one clock that never steps back.
  A row stamped after `now` by the same step survives `purge all` (see CH-5).
- The owner purges once, so the model holds at most one interval; that the
  insert checks every recorded interval, not only the latest, is covered by
  ExUnit (`purge_test.exs`).
- `/history off`'s env flip is a `get_env` and a `put_env`
  (`history.ex:479-480`), folded into one step: no other writer of that key
  is in scope.
- The Controller's start of a Capturer (`ensure_started`) is folded with the
  DynamicSupervisor's `start_child` and the Capturer's `init` read of the
  enable bit. It runs only on a boot with the feature enabled, which no
  property depends on; the `:ignore` answer of a start that races a disable
  is covered by ExUnit (`controller_test.exs`).
- A DynamicSupervisor restart folds the new Capturer's name registration and
  its `init` read of the enable bit into one step. That is sound: a
  Controller `whereis` after the flip either sees the new pid and stops it,
  or the `init` read sees the flip.
- The model's host is macOS. Off macOS `/history off` makes no reconcile call
  (`history.ex:488`), and there is no rail to stop.
- Two `/history` commands from different channels can run at once (each runs
  in its ingress process, `gateway.ex:377`), so each command is its own actor.

## Seen while reading, not modelled

These are single-call facts rather than interleavings, so each belongs in
ExUnit or a doc fix.
- Ingest's pause check fails **open** on a state-read error
  (`ingest.ex:247-250`: "a state-read error: not paused"). An unparseable
  horizon fails **closed** (`:254-266`, `:232`), and its comment calls the
  pause "a privacy control".
- There is no resume verb. The design says "resume is explicit or after the
  duration, announced either way" (MILESTONE_32 §12). The code has only the
  horizon: `history.ex:71-75`, and `set_pause_until(nil)` has no caller. It
  sends no announcement when the horizon passes. Because the horizon is never
  cleared, an event with no integer `ts` is dropped for good once any pause
  was set (`ingest.ex:237-240`); every real event carries one.
- Resolved: the design's stop-fence (MILESTONE_32 §12, invariant 12) does not
  exist as such. For `/history off` the synchronous terminate makes it
  unnecessary on the normal path; for the pause, Ingest's per-event stamp
  check now does its job (CH-1).
- Resolved: `controller.ex` called the Controller "the LAST child of the
  Supervisor", but `Retention` comes after it (`supervisor.ex:54-58`). The
  moduledoc now says it follows the DynamicSupervisor (`controller.ex:12-15`).
- Resolved: `controller.ex` said reconcile re-runs "on every enable/disable
  act (the wizard's enable, `/history off`)". The moduledoc now says it runs
  only from `/history off`, and an enable takes effect at the next boot
  (`controller.ex:15-17`).
