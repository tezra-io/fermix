# computer_history: the capture buffer versus pause, disable and purge

Models Computer History's write path against the owner's three privacy
controls. The compux sidecar stamps each observed event with the wall clock.
The `Capturer` GenServer keeps it in an in-memory buffer, and a flush (the 2 s
timer, the 25-event size trigger, or `terminate/2`) hands the buffer to
`Ingest`. `Ingest` makes two `Memory.Repo` calls: it reads the pause horizon,
then inserts the batch into the spool. Against that it models:

- `/history pause <d>`: one Repo call that stores `pause_until`, then the reply.
- `/history purge <w>`: one Repo transaction that deletes spool rows in
  `[now - w, now]` and raises the watermark.
- `/history off`: flip the app env, call the `Controller`, save `config.toml`,
  reply.

It also models the processes around the Capturer and their real supervision:
the `DynamicSupervisor` that restarts it, the `Controller` that stops it (a
`Process.whereis` lookup, then a `terminate_child` call, as two steps), and the
`:rest_for_one` supervisor that restarts the Controller.

Two events and a clock of 0..3 cover the interleavings that matter: an event
stamped inside a window, and a flush before or after the window ends. The
summarizer, the Setup UI disable path and `purge all` are out of scope (single
calls, TLA_PLUS_MODELS.md §5.1). The spec header lists everything else left
out.

**Environment switches** (set per check):
- `OwnerCanPause`, `OwnerCanPurge`, `OwnerCanDisable`: the owner sends that
  command. Pause and purge are sent at most once. `/history off` is sent once,
  or again if a daemon restart killed it before its reply.
- `DaemonCanRestart`: the daemon stops and boots again. Only SQLite rows
  (the spool, `pause_until`) and `config.toml` survive.
- `ControllerCanCrash`: the Controller dies alone, at any point (for example
  `do_reconcile` raises), and `ComputerHistory.Supervisor` restarts it.
- `CapturerCanCrash`: a Capturer callback raises, and its DynamicSupervisor
  restarts it.
- `ReconcileCanTimeOut`: `/history off`'s reconcile call gives up after
  `GenServer.call`'s 5 s default. The timer starts at `history.ex:448`.
- `ReconcileCanStall`: that timeout can fire before the DynamicSupervisor has
  sent the Capturer `:shutdown`. Setting it `FALSE` is a timing assumption:
  the work before the `:shutdown` is app-env reads, `File.regular?` stats in
  `SidecarInstaller.installed?` (`controller.ex:83`,
  `sidecar_installer.ex:62-67`) and a `Process.whereis` (`controller.ex:113`),
  so the assumption fails only if the filesystem or the scheduler stalls for
  seconds.
- `MaxFaults` bounds restarts and crashes together (1 in every check).

**Mechanism switches** (`TRUE` is the real code; each is switched off by exactly
one check):
- `IngestChecksPause`: Ingest drops the whole batch while
  `now < pause_until` (`ingest.ex:174-175`, `:213-222`).
- `StopBeforeReply`: `/history off` replies only after its reconcile call
  returns, and that call returns only after the Capturer has exited
  (`history.ex:448`, `computer_history.ex:68`, `controller.ex:43`, `:118`).
- `SaveBeforeReply`: `/history off` writes `config.toml` before it replies
  (`history.ex:450-452` before `:418-423`).
- `BootReconciles`: a started or restarted Controller reconciles in
  `handle_continue` (`controller.ex:55-63`).

## What holds

Check 01 runs with daemon restarts, reconcile timeouts and a pause:
- Nothing captured after the `/history off` reply lands in the spool (the
  disable half of M32 invariant 12). This rests on `StopBeforeReply` (check 02)
  and, across a restart, on `SaveBeforeReply` (check 03).
  - **It also rests on an assumption, `ReconcileCanStall = FALSE`**: a
    timeout may fire only once the DynamicSupervisor has sent the Capturer
    `:shutdown`. Anything the Capturer reads after that `:shutdown` is never
    read (see `Capture` in the spec).
  - The code does not enforce this. The 5 s timer starts before the Controller
    runs, and the `catch :exit` in `reconcile_runtime` would turn an early
    timeout into a "disabled" reply. Check 15 shows what breaks without it
    (CH-3).
- While a pause is in force, nothing captured during it is in the spool. This
  rests on `IngestChecksPause` (check 04).

Check 05 runs with a Controller crash at any point, daemon restarts and
reconcile timeouts, including ones that fire before the `:shutdown`
(`ReconcileCanStall = TRUE`, so it needs no timing assumption):
- After the `/history off` reply, capture eventually stops for good. This
  rests on `BootReconciles` (check 06).
- Fairness is weak fairness on the Capturer, the DynamicSupervisor, the
  Controller and its supervisor, and the steps of a command already running.
  The owner, the clock, the sidecar's events, crashes and timeouts get none.
- The pause is off in 05, because a pause only decides whether a batch is
  dropped or stored. With the pause on, 05 also holds (run by hand, see
  below).

Witnesses:
- Check 07: the terminate-time flush of `/history off` writes buffered events
  before the reply. This covers the plan's hypothesis that this flush writes
  only events from before the acknowledgement.
- Check 08: a batch whose pause check ran before the pause was stored is
  inserted after the owner has read "paused until …". The rows land after the
  ack, but every one was stamped before it, so invariant 12 is not broken.
- Check 16: CH-4's second path. The Controller's `whereis` returns a Capturer
  that then dies and is restarted, so its `terminate_child` names a pid the
  DynamicSupervisor no longer has.

**One more of each entity, run by hand** (TLC 2.19, `-workers auto`, on this
revision of the spec): each row changes the check's constants as shown, and
every other constant stays as in the check.

| Check | Change | Result | Distinct states |
|---|---|---|---|
| 01 | 3 events | holds | 10,977,935 |
| 01 | clock 0..4 | holds | 1,307,319 |
| 01 | `MaxFaults = 2` | holds | 1,775,112 |
| 05 | 3 events | holds | 1,022,558 |
| 05 | clock 0..4 | holds | 170,755 |
| 05 | `MaxFaults = 2` | holds | 419,266 |
| 05 | `OwnerCanPause = TRUE` | holds | 2,874,210 |

All three bumps at once did not finish on this revision: the machine had
under 3 GB of free disk, TLC's state files filled it, and the run was
stopped. On the previous revision (before `ReconcileCanStall`, the
Controller's split lookup and crashes at any point) both held: 01 with
63,913,510 distinct states and 05 with 2,868,075.

## Plan hypotheses

- **Ingest checks the pause at write time: confirmed.** `Ingest.ingest` calls
  `capture_paused?` (`ingest.ex:174`), which reads `pause_until` through
  `computer_history_ensure_state` (`:225`) and compares it with
  `DateTime.utc_now()` (`:221`). It never looks at the event's own `ts`.
- **Purge is one transaction that sets the watermark, and spool inserts do
  not check it: confirmed.** `purge_window` (`computer_history_sql.ex:509-561`)
  deletes, then raises `purge_watermark_ts` (`:548`), inside one
  `BEGIN IMMEDIATE` (`:1231`), all in one Repo call. `insert_events`
  (`:310-335`) is a plain `INSERT OR IGNORE`. Only the summarizer's
  `write_cycle_result` reads the watermark (`:1015-1043`).
- **`/history off`: env flip, then terminate the Capturer, then save
  config: confirmed.** The order is:
  1. flip (`history.ex:446`);
  2. a synchronous reconcile (`:448`), which returns after
     `DynamicSupervisor.terminate_child` returns, which waits for
     `terminate/2`;
  3. save (`:450-452`);
  4. reply (`:418-423`).
- **Events captured during a pause but flushed after it ends are stored:
  confirmed → CH-1.**
- **Buffered events land inside a purged window, known and tolerated:
  confirmed → CH-2.** The summarizer test is `summarizer_test.exs:1297-1312`,
  "a note the repo refuses is never logged as ok". It purges `[0, 5000]`,
  inserts an event stamped 1000 afterwards, and asserts `memory_written: false`
  and zero memories. It covers the memory only. No test covers the raw spool
  row, which stays.
- **The terminate-time flush of `/history off` writes only events captured
  before the acknowledgement: confirmed (check 01, witness 07), under the
  timing assumption above.** The EXIT queues behind the Capturer's earlier
  messages, and `terminate/2` flushes only what is already buffered
  (`capturer.ex:562-571`). The reply waits for that. The plan did not
  anticipate the other paths to the same reply that break the disable half:
  CH-3 and CH-4.

## Findings

Every finding below was confirmed by walking the counterexample through the
code on `dev`. None has been reproduced on a running daemon. To see a
counterexample, run `make -C tla check SPECS=computer_history` and open
`tla/out/computer_history/<check>.txt`.

### CH-1: a pause does not cover events flushed after it ends
- **Severity:** medium (it happens at the end of every pause while the owner
  is active; the leak is bounded to what is buffered at the horizon, at most
  one 2 s flush interval or 25 events).
- **Status:** open.
- **Checks:** 09 (7 states, M32 invariant 12), 10 (6 states, the proposed
  rule).
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

### CH-2: buffered events land inside a purged window
- **Severity:** low (no memory is made from them, and they age out with the
  48 h sweep).
- **Status:** open (known and tolerated).
- **Check:** 11 (5 states).
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
  - The summarizer refuses any memory whose provenance starts at or before
    the watermark (`computer_history_sql.ex:1040-1043`).
  - Possible side effect, not verified (summarizer out of scope): the memory's
    `provenance_from_ts` is the earliest `ts` in the sitting
    (`summarizer.ex:952`). A late row could therefore also void the memory for
    post-purge activity in the same sitting.

### CH-3: `/history off` replies without confirming the Capturer stopped
- **Severity:** low (both triggers are unlikely, and capture stops once the
  Controller reconciles).
- **Status:** open.
- **Checks:** 12 (9 states, dead Controller), 15 (9 states, stalled
  reconcile).
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
  - `computer_history.ex:67-73` catches every `:exit` (`:noproc`, a timeout,
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

### CH-4: a Capturer restart racing `/history off` keeps capturing until the next boot
- **Severity:** medium (the trigger is rare, but the owner is told capture is
  off while it goes on indefinitely).
- **Status:** open.
- **Checks:** 13 (13 states), 14 (liveness; TLC's lasso is not the shortest,
  so no length is pinned). Witness 16 shows the second path.
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
  5 s default (`repo.ex:3623-3626`), and the windows are tiny:
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

## Assumptions

- **Timing:** checks 01-04 set `ReconcileCanStall = FALSE`, i.e. the Capturer
  gets its `:shutdown` within the 5 s call timeout (see the switch above).
  Check 05 does not assume it; check 15 shows what breaks without it.
- A daemon restart is a hard stop, and buffered events are lost. A clean
  shutdown's `terminate/2` flush is the same as a flush just before the stop,
  which the model allows.
- A `:flush` timer message queued ahead of the EXIT writes the same buffer
  `terminate/2` writes, so flushes are modelled only before the EXIT.
- `terminate/2` finishes within the DynamicSupervisor's 5 s shutdown. A kill
  would only lose buffered events.
- The sidecar's `ts` and the daemon's `utc_now()` read the same machine clock
  (CH-1, CH-2).
- `/history off`'s env flip is a `get_env` and a `put_env`
  (`history.ex:445-446`), folded into one step: no other writer of that key
  is in scope.
- The Controller's start of a Capturer (`ensure_started`) is folded with the
  DynamicSupervisor's `start_child`. It runs only on a boot with the feature
  enabled, which no property depends on.
- Two `/history` commands from different channels can run at once (each runs
  in its ingress process, `gateway.ex:377`), so each command is its own actor.

## Seen while reading, not modelled

These are single-call facts rather than interleavings, so each belongs in
ExUnit or a doc fix.
- Ingest's pause check fails **open** on a state-read error
  (`ingest.ex:229-232`: "a state-read error: not paused"). An unparseable
  horizon fails **closed** (`:236-248`), and its comment calls the pause "a
  privacy control".
- There is no resume verb. The design says "resume is explicit or after the
  duration, announced either way" (MILESTONE_32 §12). The code has only the
  horizon: `history.ex:67-71`, and `set_pause_until(nil)` has no caller. It
  sends no announcement when the horizon passes.
- The design's stop-fence (MILESTONE_32 §12, invariant 12) does not exist. For
  `/history off` the synchronous terminate makes it unnecessary on the normal
  path; for the pause its absence is CH-1.
- `controller.ex:9` calls the Controller "the LAST child of the Supervisor",
  but `Retention` comes after it (`supervisor.ex:54-58`).
- `controller.ex:12-13` says reconcile re-runs "on every enable/disable act
  (the wizard's enable, `/history off`)". Nothing outside `history.ex:448`
  calls it; enabling takes effect on the next boot.
