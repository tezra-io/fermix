# reminder_delivery: Temporal reminder claims, sends and recovery

Models the Temporal reminder rail for one reminder occurrence:
`Temporal.Scheduler` (the single claimer), a `DeliveryWorker` per claim, the
send process each worker spawns under its watchdog
(`ChannelSend.with_timeout`), the platform, the owner's edit or cancel, and every
recovery path: the `:DOWN` handler, the boot sweep, the 60 s monitor check and
the 60 s validity page. One occurrence with up to five attempts covers the
interleavings that matter: the scheduler keys every claim, recovery and
refusal by row, and a second row would add nothing but the other rule's
`superseded` marking, which the spec folds into `expired`.

Time is two booleans, `due` (`ready_at` has passed) and `valid` (`valid_until`
has not). Retry delays and backoff are abstract: a retry is "not due yet", and
whether it still fits inside the validity window is a free choice while the
window is open. Faults come from a budget (`MaxFaults`). The checks use three
worker slots with two faults, so a send orphaned by a restart never blocks the
next claim. The slot bound (`FreeSlots`) reads send-process state the
scheduler cannot see, so it is the spec's bound, not scheduler logic. `TypeOK`
carries one sanity clause, `SlotBoundNeverBinds`, which asserts on every check
that the bound never blocks a claim. It is a check on the spec, not a Fermix
rule, which is why it needs no mechanism check.

**Environment switches** (set per check):
- `PlatformDedupes`: the platform drops a second message with the same
  `proactive_key`. Only the mobile timeline does (`mobile.ex:444-446` →
  `mobile_sql.ex:124-134`), and mobile is not a reminder platform (see the
  plan hypotheses).
- `PlatformCanBeSlow`: the platform can answer after the watchdog fired, and can
  still show a message Fermix gave up on.
- `WorkersCanCrash`: a worker exits before settling: a raise before the send, or
  its settlement Repo call returns an error and rolls back
  (`delivery_worker.ex:210-213`, `:75`).
- `SchedulerCanRestart`: the scheduler crashes while the BEAM stays up. Any
  earlier child of the flat `:rest_for_one` list (`Repo`, `MainAgent`,
  `JobScheduler`, …; `application.ex:189-259`) restarts it too, as does a Repo
  call that exceeds `GenServer.call`'s 5 s default inside a scheduler callback.
- `DaemonCanCrash`: the whole daemon dies and boots again.
- `RepoCanFail`: a scheduler recovery or boot-sweep Repo call returns an error
  and its transaction rolls back.
- `OwnerCanChange`: the owner edits or cancels the event.
- `DownHandledBeforeRetryDue`: a timing fact, not a code mechanism. A worker
  that settles a retry exits at once, so its `:DOWN` reaches the scheduler long
  before the retry's `ready_at` (at least 60 s later, `delivery.ex:29`,
  `delivery_worker.ex:143`). `delivery.ex:29` is a delay, not an ordering the
  code checks, so this cannot be a `needs` check. It is `TRUE` in every check
  except 20, which shows what breaks without it.

**Mechanism switches** (`TRUE` is the real code; each is switched off by at
least one check):
- `AttemptCap`: `@max_attempts 5` (`temporal_sql.ex:24`), enforced by the claim
  (`:1582`, `:1602`), `apply_retry` (`:1126`), the boot sweep (`:1196`) and the
  schema `CHECK` (`:261`). The layers are redundant; the switch turns off all
  of them.
- `ClaimRequiresPending`: the claim takes only pending rows. The load-bearing
  filter is the due scan's `status = 'pending'` (`temporal_sql.ex:1582`). The
  per-row re-read (`:1602`) and the UPDATE's `WHERE status = 'pending'`
  (`:1042`) repeat it inside the same Repo callback (`repo.ex:2762-2765`), where
  no other writer can interleave, so removing only them would change nothing.
- `WorkersDieWithScheduler`: `DeliverySupervisor` starts after the scheduler
  under `:rest_for_one` (`application.ex:241-242`, `:259`).
- `ResetSkipsMonitored`: the 60 s check leaves rows with a monitored worker
  alone (`scheduler.ex:508-511`).
- `RecoverSkipsSettled`: recovery leaves a row that is no longer `delivering`
  untouched (`temporal_sql.ex:1108-1111`).
- `RefusesWhileDelivering`: edit and cancel refuse while a row is `delivering`
  (`temporal_sql.ex:1563-1571`, called at `:598` and `:642`).
- `StableKey`: `proactive_key` is the row id on every attempt
  (`delivery.ex:85-87`).
- `HasWatchdog`: the worker kills its send after `timeout_ms`
  (`channel_send.ex:214-218`).
- `ClampsWatchdog`: `timeout_ms = min(60 s, valid_until - now)`
  (`delivery_worker.ex:111-119`).
- `BoundaryExpires`: the 60 s page expires pending rows past `valid_until`
  (`scheduler.ex:392-405` → `temporal_sql.ex:1212-1249`).

**What holds:**
- Check 01, with every fault on (no dedupe), 57,661 states:
  - No sixth attempt (`scheduler.ex:317-320`). This rests on `AttemptCap`
    (check 02).
  - Never two workers for the row (`delivery_supervisor.ex:5-10`,
    `application.ex:228-234`). This rests on `ClaimRequiresPending` (check 03),
    `WorkersDieWithScheduler` (check 04) and `ResetSkipsMonitored` (check 05),
    and on the timing fact `DownHandledBeforeRetryDue` (check 20). The worker
    processes are unique; their sends are not (REMIND-2).
- Check 06, **hypothetical**: no reminder platform reads `proactive_key`
  (`registry.ex:48`, enforced at `:1458` and `:1503`). With every fault on and a
  platform that deduplicates, the user sees the reminder at most once (41,853
  states). This rests on `StableKey` (check 07).
- Check 08, with no faults and a platform that answers inside the watchdog, 268
  states:
  - The user sees the reminder at most once. This rests on
    `RecoverSkipsSettled` (check 09): without it, the `:DOWN` after a normal
    exit resets a delivered row and it is sent again.
  - No reminder reaches the user after an accepted edit or cancel. This rests
    on `RefusesWhileDelivering` (check 10).
  - No edit or cancel is accepted while a send is running or its request is
    still at the platform. This rests on `RefusesWhileDelivering` (check 11).
    With faults on it breaks (REMIND-2, REMIND-3).
- Check 12, with every fault except a scheduler-only restart, 7,111 states: no
  send process is still running past `valid_until` (`delivery_worker.ex:11-13`).
  This rests on `ClampsWatchdog` (check 13). The clamp itself is written as a
  guard on the clock (`Expire` cannot fire while a worker waits on its send), so
  what this check actually verifies is narrower: **no fault other than a
  scheduler restart leaves a send without its worker**. The rule covers the
  send process only. A request already at the platform can still land after the
  boundary, and near the boundary the clamp shortens the watchdog enough that
  an ordinary platform latency can outlast it.
- Check 14, with every fault on: the reminder always ends delivered, failed,
  expired or cancelled, and stays there (57,661 states). Weak fairness covers:
  - the scheduler's steps and timers, and the due timer;
  - each worker's next step, its watchdog included;
  - a live send process sending its request, and taking an answer the platform
    has already given.

  None applies to the platform deciding or processing a late request (its
  slowness lives there), the owner, the clock passing `valid_until`, or faults.
  This rests on `HasWatchdog` (check 15: a platform that never answers wedges
  the worker) and `BoundaryExpires` (check 16: a pending row past `valid_until`
  is never claimed again).

**The claimed refusal rule.** The review asked for the literal claim, "an edit or
cancel is refused while the row reads `delivering`", to be dropped as a
property. The refusal and the write are one Repo call
(`temporal_sql.ex:596-608`, `:640-648`), so the property held by construction.
That single-call fact belongs in ExUnit. The spec checks what the refusal is
for instead (`NoChangeWhileSending`): per `registry.ex:678-681` and M30's
failure table (`:1490`), "a send cannot be recalled", so no change should be
accepted while one is in flight.

**Witnesses and the timing check:**
- 17: a failed recovery leaves a `delivering` row that only the 60 s monitor
  check can reset (a claim, a restart before the worker starts, a failed boot
  sweep; `scheduler.ex:207`).
- 18: after a restart, the orphaned send and the re-claimed row's send run at
  the same time (10 states).
- 19: a row claimed while valid reaches its worker after `valid_until` (claim,
  then the boundary passes, then `handle_continue`), a path
  `delivery_worker.ex:173-176` calls impossible (see the drift note).
- 20: with `DownHandledBeforeRetryDue = FALSE`, `SingleWorker` breaks in 14
  states. A worker settles a retry, the retry comes due and is claimed before
  the old `:DOWN` is handled, then that `:DOWN`'s `recover_row` resets the new
  claim under its live worker, and a third claim starts a second live worker.
  This is a reachable check, not a finding: the real timing makes it
  impossible today.

**One more of each, run by hand** (four slots, three faults): every holds check
still holds.

| Check | Normal bound (3 slots, 2 faults) | +1 (4 slots, 3 faults) |
|---|---|---|
| 01 | 57,661 states | 213,159 states |
| 06 | 41,853 states | 154,974 states |
| 08 | 268 states | 268 states (no faults, so one slot is ever used) |
| 12 | 7,111 states | 9,590 states |
| 14 | 57,661 states | 213,159 states, 7 s |

## Plan hypotheses (TLA_PLUS_MODELS.md §4.4)

- **Duplicates without dedupe, from a retryable `:delivery_timeout` after the
  platform accepted:** confirmed, REMIND-1 (check 21).
- **Duplicates without dedupe, from a crash after the send but before
  settlement:** confirmed, REMIND-1. Check 22 covers a worker whose settlement
  write fails, and check 23 a daemon crash. A scheduler-only restart duplicates
  too, and by a different route than M30 describes (REMIND-2, witness 18).
- **At most once holds with dedupe:** true in the spec (check 06), but no real
  reminder runs in that configuration. Reminder targets are limited to
  `telegram slack discord signal whatsapp` (`registry.ex:48`, enforced at
  `:1458` and `:1503`). The only adapter that reads `proactive_key` is mobile
  (`mobile.ex:444-446`). The `temporal:<id>` key that `delivery.ex:70` attaches
  to every send is ignored by every platform a reminder can reach.
- **Never attempt six, never two workers:** both hold (check 01), each covered
  by its mechanism checks.
- **Edit and cancel refused while a delivery is in progress:** the status check
  holds by construction (see "The claimed refusal rule"). What the refusal is
  for (no change accepted while a send is in flight) holds in a quiet world
  (check 08) and breaks under a restart (REMIND-2) or a slow platform
  (REMIND-3).
- **Every due reminder ends delivered, failed or expired:** holds (check 14),
  with `cancelled` added as the owner's own end state.

## Findings

Every finding below was confirmed by walking the counterexample through the
code on `dev`. None has been reproduced on a running daemon. To see a
counterexample, run `tla/bin/check.py reminder_delivery` and open
`tla/out/reminder_delivery/<check>.txt`.

### REMIND-1: a send the platform accepted is sent again (at-least-once)
- **Severity:** low. The design chooses it and documents it (M30 §11.5,
  §19.9), and no reminder platform deduplicates.
- **Status:** open (accepted by design).
- **Checks:** 21 (16 states), 22 (16 states), 23 (14 states).
- **Counterexample:**
  - Check 21: the platform shows the reminder, but its answer outlasts the
    watchdog. The worker settles `:delivery_timeout` as a retry, the row is
    claimed again after the delay, and the second send is shown too.
  - Check 22: the platform shows it and answers `:ok`, but the
    `temporal_reminder_delivered` write returns an error. The worker exits
    abnormally, the `:DOWN` recovery returns the row to pending, and it is sent
    again.
  - Check 23: the daemon dies after the platform showed the reminder. The boot
    sweep returns the row to pending with its old `ready_at`, and it is claimed
    and sent again at once.
- **Code:**
  - The watchdog reports `:delivery_timeout` without knowing whether the request
    landed (`channel_send.ex:214-218`), and that result is retryable
    (`error.ex:180`, `delivery_worker.ex:134-151`).
  - A failed settlement exits with `{:settlement_failed, _}`
    (`delivery_worker.ex:75`, `:210-213`). `recover_row` then applies the retry
    rules to the still-delivering row (`temporal_sql.ex:1113-1135`).
  - The boot sweep keeps `ready_at` (`temporal_sql.ex:1204`), so the row is due
    again at once.
- **Impact:** the user gets the reminder twice. The same timeout can also
  settle a row the user did see as `failed` (on the fifth attempt, which
  `event_list` reports as a failed delivery, `temporal_sql.ex:1476-1481`) or
  `expired` (near `valid_until`).

### REMIND-2: a scheduler restart kills the worker but not its send
- **Severity:** low. The trigger is rare (a restart during a send) and the
  outcome bounded (one extra, late or obsolete reminder). It does contradict
  the premise M30 §6.3 and §19.10 rest on.
- **Status:** open.
- **Checks:** 24 (6 states), 25 (7 states), 26 (8 states). Witness 18 shows two
  sends at once.
- **Counterexample:** a worker starts its send, and the scheduler restarts before
  the send answers. `:rest_for_one` kills the worker, but its send process keeps
  running (check 24). The send has no watchdog left, so it can still be running,
  or not even have reached the platform, after `valid_until` (check 25). The
  boot sweep sets the row back to `pending`, so the owner's cancel is accepted
  while the orphaned send is still running (check 26).
- **Code:**
  - `ChannelSend.with_timeout` runs the adapter call in a `spawn_monitor`ed
    process (`channel_send.ex:200-205`). It is not linked to the worker, and no
    supervisor owns it.
  - The worker does not trap exits, so the `DeliverySupervisor` shutdown under
    `:rest_for_one` (`application.ex:241-242`, `:259`) kills it at once.
  - The watchdog is the worker's own `receive … after`
    (`channel_send.ex:207-219`), so the orphan is bounded only by the HTTP
    client's own timeouts (for example the 15 s pool checkout,
    `http_client.ex:68`).
  - The refusal sees only the status column (`temporal_sql.ex:1563-1571`),
    which the boot sweep has already set back to `pending`
    (`temporal_sql.ex:1191-1206`).
  - M30 §6.3 (`MILESTONE_30_…md:339`) says "a scheduler-only crash kills
    in-flight sends". `delivery_worker.ex:11-13` says a claimed send "always
    finishes or is killed before its validity boundary".
- **Impact:**
  - The boot sweep keeps the old `ready_at`, and the new scheduler claims the
    row again at once, so two sends for one row run side by side (witness 18).
    The "two workers … cannot exist across lifetimes" argument holds for
    workers, not sends.
  - An edit or cancel is accepted while the orphan is still sending, and the old
    reminder can arrive after it.
  - M30 §19.10 rejects lease tokens "unless delivery ever moves outside the
    daemon's process tree". The send already runs outside the supervision tree.
  - A `DeliverySupervisor` crash on its own (not modelled) orphans sends the
    same way while the scheduler stays up.

### REMIND-3: the refusal ends when the attempt settles, not when the platform is done
- **Severity:** low. The platform has to process a request after the watchdog
  gave up on it, and the owner has to change the event inside that tail.
- **Status:** open.
- **Checks:** 28 (9 states), 27 (10 states).
- **Counterexample:** the send reaches the platform, and the watchdog fires
  before the platform answers. The worker settles the row as a retry (here it
  no longer fits, so `expired`). The owner edits the event, which is accepted
  because nothing is `delivering`, although the request is still at the
  platform (check 28). The platform then shows the old reminder (check 27).
- **Code:**
  - The watchdog kills the send process but cannot recall a request already at
    the platform (`channel_send.ex:214-218`).
  - The refusal checks only for `delivering` rows
    (`temporal_sql.ex:1563-1571`), yet it tells the owner "a send cannot be
    recalled. Wait for the attempt to finish" (`registry.ex:678-681`).
  - A daemon crash with a request in flight opens the same window.
- **Impact:** after the owner moved or cancelled the event, they still receive
  the reminder for the old one.
- **Confidence:** depends on a platform delivering a message after Fermix's
  watchdog abandoned the HTTP call. Near `valid_until` the clamped watchdog can
  be milliseconds long, so an ordinary latency is enough there.
- **Why a separate ID from REMIND-2:** REMIND-2 is an orphaned send process with
  no watchdog; the fix is to kill or link it. REMIND-3 happens with every
  process behaving as designed: the request has left Fermix, and no process
  change can recall it.

## Code and doc drift

- `delivery_worker.ex:173-176` says a claim past the validity boundary "cannot
  happen through the scheduler's due scan", and `expire_unclaimable` logs it as
  an error (`:178-180`). Witness 19 reaches it in 6 states: the claim is valid,
  then `valid_until` passes before the worker's `handle_continue` computes its
  watchdog. The window is the claim-to-start latency, so it is rare, but the log
  line would report a broken invariant that is not broken.
- `delivery_worker.ex:7-9` says the scheduler has monitored the worker "before
  the channel is touched". The worker's `handle_continue` runs as soon as
  `init/1` returns, in parallel with the scheduler's `Process.monitor`. This is
  harmless: monitoring a pid that has already exited yields an immediate
  `:DOWN` (`:noproc`), and `worker_down` recovers it the same way. The spec
  folds the monitor into the start.
- M30 §6.3:339 and §19.10: see REMIND-2.

## Assumptions

- **Timing (`DownHandledBeforeRetryDue`).** See the environment switch and
  check 20. `recover_row` re-reads the row by id only
  (`temporal_sql.ex:1100-1115`) and does not check that the `delivering` status
  belongs to the dead worker's claim. A future change that makes a retry due
  within the `:DOWN` latency (a zero delay, or a settlement path that does not
  exit) would turn check 20 into a real bug.
- **Platform behaviour.** Whether Telegram, Slack, Discord, Signal or WhatsApp
  can show a message after the HTTP call was abandoned is the platform's
  business. With `PlatformCanBeSlow = FALSE` the platform always answers inside
  the watchdog, so the watchdog can only catch a send that never reached it.
- **Repo call timeouts.** `Memory.Repo` calls use `GenServer.call`'s 5 s default
  and nobody catches the exit (`repo.ex:3623-3626`).
  - A timed-out claim crashes the scheduler (a `SchedulerRestart`). The claim
    still lands before the boot sweep, since both queue in the Repo's mailbox in
    order.
  - A timed-out settlement crashes the worker, but the settlement still lands
    before the `:DOWN` recovery, which then sees a settled row. In the spec that
    is `Settle` followed by `Down`, not `WorkerCrash`.
  - Only a settlement that returns an error leaves the row `delivering`, which
    is what `WorkerCrash` models.
- **Folded steps.** The 60 s monitor check's list and recovery calls are one
  step, because `recover_row` re-reads the row. Settlement and the worker's exit
  are one step, because nothing between them changes shared state.
- **Bounds.** One occurrence, three worker slots, two faults, a sixth claim at
  most (the one `NeverAttemptSix` forbids), and `seen` saturating at 2.
