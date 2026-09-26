# reminder_delivery: Temporal reminder claims, sends and recovery

Models the Temporal reminder rail for one reminder occurrence:
`Temporal.Scheduler` (the single claimer), a `DeliveryWorker` per claim, the
send process each worker spawns, linked to it, under its watchdog
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
worker slots with two faults, so a send orphaned by a restart (with
`SendsDieWithWorker` off) never blocks the next claim. The slot bound
(`FreeSlots`) reads send-process state the scheduler cannot see, so it is the
spec's bound, not scheduler logic. `TypeOK` carries one sanity clause,
`SlotBoundNeverBinds`, which asserts on every check that the bound never blocks
a claim. It is a check on the spec, not a Fermix rule, which is why it needs no
mechanism check.

**Environment switches** (set per check):
- `PlatformDedupes`: the platform drops a second message with the same
  `proactive_key`. Only the companion timeline does, for the mobile and
  companion channels (`output.ex:159-161` → `mobile_sql.ex:170-180`), and
  neither is a reminder platform (see the plan hypotheses).
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
  (`:1042`) repeat it inside the same Repo callback (`repo.ex:2899-2902`), where
  no other writer can interleave, so removing only them would change nothing.
- `WorkersDieWithScheduler`: `DeliverySupervisor` starts after the scheduler
  under `:rest_for_one` (`application.ex:241-242`, `:259`).
- `SendsDieWithWorker`: a worker's send process is spawned linked to it
  (`Process.spawn(fun, [:link, :monitor])`, `channel_send.ex:219-224`), so a
  worker killed mid-send takes its send with it. Off, it is the code before the
  REMIND-2 fix: the send is `spawn_monitor`ed, not linked, and outlives its
  worker.
- `ResetSkipsMonitored`: the 60 s check leaves rows with a monitored worker
  alone (`scheduler.ex:508-511`).
- `RecoverSkipsSettled`: recovery leaves a row that is no longer `delivering`
  untouched (`temporal_sql.ex:1108-1111`).
- `RefusesWhileDelivering`: edit and cancel refuse while a row is `delivering`
  (`temporal_sql.ex:1563-1571`, called at `:598` and `:642`).
- `StableKey`: `proactive_key` is the row id on every attempt
  (`delivery.ex:85-87`).
- `HasWatchdog`: the worker kills its send after `timeout_ms`
  (`channel_send.ex:239`, `kill_and_drain/3` at `:284-300`).
- `ClampsWatchdog`: `timeout_ms = min(60 s, valid_until - now)`
  (`delivery_worker.ex:111-119`).
- `BoundaryExpires`: the 60 s page expires pending rows past `valid_until`
  (`scheduler.ex:392-405` → `temporal_sql.ex:1212-1249`).

**What holds:**
- Check 01, with every fault on (no dedupe), 7,111 states:
  - No sixth attempt (`scheduler.ex:317-320`). This rests on `AttemptCap`
    (check 02).
  - Never two workers for the row (`delivery_supervisor.ex:5-10`,
    `application.ex:228-234`). This rests on `ClaimRequiresPending` (check 03),
    `WorkersDieWithScheduler` (check 04) and `ResetSkipsMonitored` (check 05),
    and on the timing fact `DownHandledBeforeRetryDue` (check 20).
  - Never two sends for the row either (the premise of M30 §19.10's no-lease
    design). This rests on `SendsDieWithWorker` (check 18): unlinked, a
    restart orphans the send, the boot sweep re-pends the row, and the
    re-claim starts a second send beside it.
  - A scheduler restart leaves no send running (M30 §6.3 :339,
    `channel_send.ex:98-105`; the unlink-to-kill residual below is under the
    spec's step granularity). This rests on `SendsDieWithWorker` (check 24).
  - No edit or cancel is accepted while a send process runs (`registry.ex:678-681`,
    M30 §16 :1490). This rests on `RefusesWhileDelivering` (check 29) and
    `SendsDieWithWorker` (check 26: unlinked, the boot sweep sets the row back
    to `pending` while the orphan still sends, and the edit is accepted).

  Before the REMIND-2 fix the same check covered 57,661 states: most of them
  were orphaned sends.
- Check 06, **hypothetical**: no reminder platform reads `proactive_key`
  (`registry.ex:48`, enforced at `:1458` and `:1503`). With every fault on and a
  platform that deduplicates, the user sees the reminder at most once (5,173
  states). This rests on `StableKey` (check 07).
- Check 08, with no faults and a platform that answers inside the watchdog, 268
  states:
  - The user sees the reminder at most once. This rests on
    `RecoverSkipsSettled` (check 09): without it, the `:DOWN` after a normal
    exit resets a delivered row and it is sent again.
  - No reminder reaches the user after an accepted edit or cancel. This rests
    on `RefusesWhileDelivering` (check 10).
  - No edit or cancel is accepted while a send process runs. This rests on
    `RefusesWhileDelivering` (check 11). This claimed rule also holds with
    every fault on (check 01). The stronger proposed rule, which also counts a
    request still at the platform, breaks (REMIND-3, check 28).
- Check 12, with every fault on, 7,111 states: no send process is still
  running past `valid_until` (`delivery_worker.ex:11-13`). This rests on
  `ClampsWatchdog` (check 13) and `SendsDieWithWorker` (check 25: unlinked, a
  restart leaves the send with no watchdog, and it can still be running, or not
  even have reached the platform, after `valid_until`). The clamp itself is
  written as a guard on the clock (`Expire` cannot fire while a worker waits on
  its send), so what this check verifies is narrower: **no fault leaves a send
  without its worker**, a scheduler restart included since the fix. The rule
  covers the send process only. A request already at the platform can still
  land after the boundary (REMIND-3's tail), and near the boundary the clamp
  shortens the watchdog enough that an ordinary platform latency can outlast
  it.
- Check 14, with every fault on: the reminder always ends delivered, failed,
  expired or cancelled, and stays there (7,111 states). Weak fairness covers:
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
for instead. `registry.ex:678-681` tells the owner "Wait for the attempt to
finish", and M30's failure table (`:1490`) says the owner "retries after the
bounded attempt", so the claimed rule is `NoChangeWhileSendRunning`: no change
is accepted while a send process runs. M30 §7.3 (`:609-614`) scopes the refusal
to that bounded attempt and disclaims recall, so the stronger
`NoChangeWhileRequestAtPlatform`, which also counts a request the attempt
abandoned at the platform, is a proposed rule (REMIND-3).

**Witnesses and the timing check:**
- 17: a failed recovery leaves a `delivering` row that only the 60 s monitor
  check can reset (a claim, a restart before the worker starts, a failed boot
  sweep; `scheduler.ex:207`).
- 19: a row claimed while valid reaches its worker after `valid_until` (claim,
  then the boundary passes, then `handle_continue`), a path
  `delivery_worker.ex:173-176` calls impossible (see the drift note).
- 20: with `DownHandledBeforeRetryDue = FALSE`, `SingleWorker` breaks in 14
  states. A worker settles a retry, the retry comes due and is claimed before
  the old `:DOWN` is handled, then that `:DOWN`'s `recover_row` resets the new
  claim under its live worker, and a third claim starts a second live worker.
  This is a reachable check, not a finding: the real timing makes it
  impossible today.

Check 18 was a witness of two sends running at once. Since the REMIND-2 fix
that never happens, so it became `OneSendAtATime`'s mechanism check.

**One more of each, run by hand** (four slots, three faults): every holds check
still holds.

| Check | Normal bound (3 slots, 2 faults) | +1 (4 slots, 3 faults) |
|---|---|---|
| 01 | 7,111 states | 9,590 states |
| 06 | 5,173 states | 6,973 states |
| 08 | 268 states | 268 states (no faults, so one slot is ever used) |
| 12 | 7,111 states | 9,590 states |
| 14 | 7,111 states | 9,590 states |

## Plan hypotheses (TLA_PLUS_MODELS.md §4.4)

- **Duplicates without dedupe, from a retryable `:delivery_timeout` after the
  platform accepted:** confirmed, REMIND-1 (check 21).
- **Duplicates without dedupe, from a crash after the send but before
  settlement:** confirmed, REMIND-1. Check 22 covers a worker whose settlement
  write fails, and check 23 a daemon crash. Before the REMIND-2 fix a
  scheduler-only restart duplicated by a second route too: the orphaned send
  ran beside the re-claimed row's send. The link removed that route (check
  18). A request already at the platform when the restart kills its send is
  still shown, and the re-claim sends again: REMIND-1's accepted duplicate.
- **At most once holds with dedupe:** true in the spec (check 06), but no real
  reminder runs in that configuration. Reminder targets are limited to
  `telegram slack discord signal whatsapp` (`registry.ex:48`, enforced at
  `:1458` and `:1503`). The only adapters that read `proactive_key` are mobile
  and companion, both through `output.ex:159-161`. The `temporal:<id>` key that
  `delivery.ex:70` attaches to every send is ignored by every platform a
  reminder can reach.
- **Never attempt six, never two workers:** both hold (check 01), each covered
  by its mechanism checks.
- **Edit and cancel refused while a delivery is in progress:** the status check
  holds by construction (see "The claimed refusal rule"). What the refusal is
  for, no change accepted while a send process runs, holds with every fault on
  (check 01) since the REMIND-2 fix. A request still at the platform after its
  attempt settled is REMIND-3, accepted by design.
- **Every due reminder ends delivered, failed or expired:** holds (check 14),
  with `cancelled` added as the owner's own end state.

## Findings

Every finding below was confirmed by walking the counterexample through the
code on `dev`. None has been reproduced on a running daemon. To see a
counterexample, run `tla/bin/check.py reminder_delivery` and open
`tla/out/reminder_delivery/<check>.txt`.

### REMIND-1: a send the platform accepted is sent again (at-least-once)
- **Severity:** low. The design chooses it and documents it, and no reminder
  platform deduplicates.
- **Status:** accepted by design (M30 §11.5 :1173-1196, §16 :1485, §19.9
  :1751-1755). `AtMostOnce` is a proposed rule, so checks 21-23 stay
  `violated REMIND-1` as the record of the accepted window.
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
    landed (`channel_send.ex:239`, `:284-300`), and that result is retryable
    (`error.ex:180`, `delivery_worker.ex:134-151`). A result the send posted
    just before the kill is discarded too, so a send that did deliver can still
    be reported as a timeout and sent again.
  - A failed settlement exits with `{:settlement_failed, _}`
    (`delivery_worker.ex:75`, `:210-213`). `recover_row` then applies the retry
    rules to the still-delivering row (`temporal_sql.ex:1113-1135`).
  - The boot sweep keeps `ready_at` (`temporal_sql.ex:1200`, in `sweep_row`,
    `:1191-1202`), so the row is due again at once.
- **Other accepted duplicate paths the spec folds into the watchdog or leaves
  out:**
  - the HTTP client's own receive timeout (Req's 15 s default;
    `telegram.ex:577-580` sets none), which returns a retryable
    `{:transport, :timeout}` (`error.ex:154-158`, `:179`) and is the usual way
    an attempt gives up on a request the platform may already hold, as are a
    connection reset after the write and signal-cli's own timeout
    (`signal.ex:544-547`);
  - `HttpClient.request`'s one immediate retry on `:closed`/`:econnrefused`
    (`http_client.ex:75-77`), which can duplicate inside one attempt (M30 §11.5
    :1181-1186);
  - a multi-chunk message that fails on a later chunk and is re-sent whole
    (`telegram.ex:182`, `signal.ex:96-103`).
- **Impact:** the user gets the reminder twice. The same timeout can also
  settle a row the user did see as `failed` (on the fifth attempt, which
  `event_list` reports as a failed delivery, `temporal_sql.ex:1476-1481`) or
  `expired` (near `valid_until`); §11.5's ambiguity clause covers that too.
- **Why by design:** marking the row delivered before the send would lose
  reminders in the opposite crash window (M30 §11.5 :1193-1196), and no reminder
  platform offers an idempotency key.

### REMIND-2: a scheduler restart kills the worker but not its send
- **Severity:** low. The trigger is rare (a restart during a send) and the
  outcome bounded (one extra, late or obsolete reminder). It contradicted the
  premise M30 §6.3 and §19.10 rest on.
- **Status:** fixed (d514e149). The send process is linked
  to its caller.
- **Checks:** the old checks 24, 25 and 26 and witness 18 are now the
  `SendsDieWithWorker` mechanism checks 24, 25, 26 and 18: their rules
  (`RestartKillsSends`, `SendEndsBeforeBoundary`, `NoChangeWhileSendRunning`,
  `OneSendAtATime`) hold in checks 01 and 12 with every fault on, and break
  with the link switched off.
- **Counterexample (before the fix):** a worker starts its send, and the
  scheduler restarts before the send answers. `:rest_for_one` kills the worker,
  but its send process keeps running (check 24). The send has no watchdog
  left, so it can still be running, or not even have reached the platform,
  after `valid_until` (check 25). The boot sweep sets the row back to
  `pending`, so the owner's cancel is accepted while the orphaned send is still
  running (check 26), and the re-claimed row's send runs beside it (witness 18).
- **Code (before the fix):**
  - `ChannelSend.with_timeout` ran the adapter call in a `spawn_monitor`ed
    process. It was not linked to the worker, and no supervisor owns it.
  - The worker does not trap exits, so the `DeliverySupervisor` shutdown under
    `:rest_for_one` (`application.ex:241-242`, `:259`) kills it at once, inside
    the watchdog's `receive`.
  - The watchdog is the worker's own `receive … after`, so the orphan was
    bounded only by the HTTP client's own timeouts (for example the 15 s pool
    checkout, `http_client.ex:68`).
  - The refusal sees only the status column (`temporal_sql.ex:1563-1571`),
    which the boot sweep has already set back to `pending`
    (`temporal_sql.ex:1191-1202`).
- **Fix** (`monitored_call/2`, `channel_send.ex:219-300`), shared by every
  `with_timeout` caller:
  - The send process is spawned linked and monitored in one atomic call
    (`Process.spawn(fun, [:link, :monitor])`, `:224`), so a worker killed
    mid-send (a restart, a clean daemon stop, a `DeliverySupervisor` crash)
    takes its send with it.
  - The link carries only that direction. `report/1` catches every raise,
    throw and exit in the send and returns it as a value, logged with a bounded
    message (`:248-258`), so the send always exits `:normal` and a crashing
    adapter still gives the terminal `{:error, {:delivery_crashed, _}}`.
  - Every exit of the wait releases the send the same way: unlink, flush a
    `{:EXIT, pid, _}` a trapping caller may hold, demonitor with `:flush`
    (`release/2`, `:264-269`).
  - The watchdog unlinks before it kills, waits for the killed send's `:DOWN`
    (`:kill` cannot be trapped, so it always arrives), then drops any result
    the send posted before it died (`kill_and_drain/3`, `:284-300`). This also
    closes a stray `:DOWN` the old zero-timeout flush left in the caller's
    mailbox.
- **Tests:** `channel_send_test.exs`: "the send process dies with its caller";
  "regression: nothing of a finished send is left in a trapping caller's
  mailbox". `temporal/delivery_worker_test.exs`: "a worker torn down mid-send
  takes its send with it" (the row stays `delivering` for the boot sweep).
- **Residual:** a caller killed in the few instructions between the watchdog's
  unlink and its kill (`channel_send.ex:281-287`) leaves its send unlinked,
  bounded only by the send's own client timeouts. It is below this spec's step
  granularity. A request already at the platform when its send is killed is
  still processed there: that is REMIND-1 and REMIND-3, which no process
  change can recall.

### REMIND-3: the refusal ends when the attempt settles, not when the platform is done
- **Severity:** low. The platform has to process a request after Fermix gave up
  on it, and the owner has to change the event inside that tail.
- **Status:** accepted by design (M30 §7.3 :609-614, §16 :1490).
  `NoChangeWhileRequestAtPlatform` and `NoReminderAfterChange` are proposed
  rules, so checks 27 and 28 stay `violated REMIND-3`.
- **Checks:** 28 (9 states), 27 (10 states).
- **Counterexample:** the send reaches the platform, and the watchdog fires
  before the platform answers. The worker settles the row as a retry (here it
  no longer fits, so `expired`). The owner edits the event, which is accepted
  because nothing is `delivering`, although the request is still at the
  platform (check 28). The platform then shows the old reminder (check 27).
- **Code:**
  - The watchdog kills the send process but cannot recall a request already at
    the platform (`channel_send.ex:284-300`). In practice the usual give-up is
    not the 60 s watchdog but the HTTP client's own 15 s receive timeout,
    which ends the attempt the same way (see REMIND-1).
  - The refusal checks only for `delivering` rows
    (`temporal_sql.ex:1563-1571`), and it tells the owner to "Wait for the
    attempt to finish" (`registry.ex:678-681`), which is exactly when it stops
    refusing.
  - A daemon crash with a request in flight opens the same window.
- **Impact:** after the owner moved or cancelled the event, they can still
  receive the reminder for the old one. That looks the same as a reminder the
  platform delivered just before the edit, which no design can prevent.
- **Confidence:** needs a platform that shows a request after Fermix's attempt
  abandoned it, and the owner's change accepted inside that delay. With
  ordinary platform latency the gap is sub-second; near `valid_until` the
  clamped watchdog can be milliseconds long, which widens it. Signal cannot
  do this: CommandHost ends signal-cli when the send process dies
  (`command_host.ex:22`, `:118`, `:313`).
- **Why by design:** M30 §7.3 says "A channel send cannot be recalled once it
  starts, so Fermix asks the owner to retry the mutation after the bounded send
  attempt finishes instead of pretending it revoked an external side effect."
  A time-based cool-down after an ambiguous attempt could not bound the
  platform's delay either, and would be a second guard beside the status guard.
- **Why a separate ID from REMIND-2:** REMIND-2 was an orphaned send process
  with no watchdog; the fix linked it. REMIND-3 happens with every process
  behaving as designed: the request has left Fermix, and no process change can
  recall it.

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
- M30 §6.3:339 ("a scheduler-only crash kills in-flight sends") and §10.2
  (:892-898): closed by the REMIND-2 fix, which makes both true for the send
  process. §19.10 (:1757-1769) says "Neither the jobs scheduler nor the harness
  delivery worker uses leases"; the harness now writes a hand-off lease
  (`next_delivery_at`) at its terminal write (harness_delivery, HARNESS-1). It
  is a delay, not a claim token, and fences nothing, but the sentence reads
  otherwise.

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
  and nobody catches the exit (`repo.ex:3777-3780`).
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
- **The send's link.** A worker killed in the few instructions between its
  watchdog's unlink and kill leaves its send unlinked
  (`channel_send.ex:281-287`); the spec does not split the watchdog that finely.
  A clean daemon stop (reverse-order shutdown) kills the worker with
  `:shutdown`, and since the fix its send with it; the spec's `DaemonCrash`
  kills everything at once, which gives the same result.
- **Bounds.** One occurrence, three worker slots, two faults, a sixth claim at
  most (the one `NeverAttemptSix` forbids), and `seen` saturating at 2.
