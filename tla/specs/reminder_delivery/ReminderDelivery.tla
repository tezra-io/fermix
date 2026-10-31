------------------------- MODULE ReminderDelivery -------------------------
(***************************************************************************)
(* The Temporal reminder rail for ONE reminder occurrence: the scheduler   *)
(* that claims it, the DeliveryWorker each claim starts, the send process  *)
(* each worker spawns under its watchdog, the platform, the owner's edit   *)
(* or cancel, the scheduler's recovery paths (the DOWN handler, the boot   *)
(* sweep, the 60 s monitor check and validity pages), and the faults:      *)
(* a worker exiting before it settles, a scheduler restart under           *)
(* :rest_for_one, a daemon crash, a Repo call that returns an error, and   *)
(* a claim that times out but still lands.                                 *)
(*                                                                         *)
(* Time is two booleans: `due` (ready_at has passed) and `valid`           *)
(* (valid_until has not). Retry delays and backoff are abstract: a retry   *)
(* is simply "not due yet", and whether it still fits before valid_until   *)
(* is a free choice while the window is open.                              *)
(*                                                                         *)
(* Not modelled: other rules of the same occurrence (so `superseded` is    *)
(* folded into `expired`), snooze, the annual horizon, render              *)
(* and thread-option errors (terminal before any send), a send process     *)
(* that crashes ({:delivery_crashed} is terminal), the pool-unavailable    *)
(* retry inside ChannelSend (it fires before a connection exists),         *)
(* DeliverySupervisor start failures (settle_stranded: the same recovery   *)
(* as a worker that dies at once), the DeliverySupervisor crashing on its  *)
(* own, and the exact timer arithmetic. Only SQLite rows survive a restart.*)
(*                                                                         *)
(* One step = one indivisible thing: one GenServer callback, one           *)
(* Memory.Repo call, or one side effect at the platform. Every SQLite      *)
(* access goes through the single Memory.Repo process, so one Repo call is *)
(* atomic whatever SQL it runs.                                            *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/temporal/scheduler.ex @ a611fdfb118a
\* SOURCE: apps/fermix_core/lib/fermix_core/temporal/delivery_worker.ex @ 5a4521741314
\* SOURCE: apps/fermix_core/lib/fermix_core/temporal/delivery.ex @ 6b97367661a2
\* SOURCE: apps/fermix_core/lib/fermix_core/temporal/delivery_supervisor.ex @ f4c7d9dd90a1
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/temporal_sql.ex @ b85c5212fe61
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#call,call_or_timeout_error,periodic_opts,claim_due_reminders,recover_delivering_reminder,sweep_delivering_reminders,update_temporal_event @ ebd91fdc0e6f
\* SOURCE: apps/fermix_core/lib/fermix_core/delivery/channel_send.ex @ 9b06289e25ae
\* SOURCE: apps/fermix_core/lib/fermix_core/delivery/error.ex @ a3cd3a75d3ca
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/mobile_sql.ex @ 70cde913ccf3
\* SOURCE: apps/fermix_core/lib/fermix_core/application.ex#start_supervision_tree,supervision_children,temporal_scheduler_opts @ d6f4fb21a73e
\* SOURCE: apps/fermix_core/lib/fermix_core/temporal/registry.ex @ 26a90999cd1c
\* SOURCE: apps/fermix_channels/lib/fermix_channels/channels/mobile.ex @ b39e088f2603
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/output.ex @ 143a4859705c
EXTENDS Naturals, FiniteSets

CONSTANTS
    Workers,        \* slots for DeliveryWorker processes, e.g. {w1, w2, w3}. A
                    \* slot is reused once its worker is gone, its DOWN handled
                    \* and its send process finished.
    MaxFaults,      \* how many injected faults (crashes, restarts, Repo errors
                    \* and timeouts) one behaviour may contain
    \* Environment switches: what may happen to the rail.
    PlatformDedupes,     \* the platform drops a second message with the same
                         \* proactive_key (only the companion timeline does,
                         \* for the mobile and companion channels, and neither
                         \* is a reminder platform)
    PlatformCanBeSlow,   \* the platform can answer after the watchdog fired, and
                         \* can still show a message Fermix gave up on
    WorkersCanCrash,     \* a worker exits before settling (a raise, or its
                         \* settlement Repo call returns an error)
    SchedulerCanRestart, \* the scheduler, or an earlier :rest_for_one sibling,
                         \* crashes while the BEAM stays up
    DaemonCanCrash,      \* the whole daemon dies and boots again
    RepoCanFail,         \* a scheduler Repo call returns an error: it rolled
                         \* back (a recovery, the boot sweep), or it timed out
                         \* and its request still runs later (the claim)
    OwnerCanChange,      \* the owner edits or cancels the event
    DownHandledBeforeRetryDue,
                         \* timing, not a code mechanism: the scheduler handles a
                         \* settled worker's DOWN before that row's retry is due
                         \* (TRUE in every check but one; see BecomeDue)
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by at least one check to show a property needs it.
    AttemptCap,              \* @max_attempts 5 (temporal_sql.ex:24), enforced by the
                             \* claim (:1573, :1593), apply_retry (:1117), the boot
                             \* sweep (:1187) and the schema CHECK (:255)
    ClaimRequiresPending,    \* the claim takes only pending rows: the due scan's
                             \* status = 'pending' (temporal_sql.ex:1573). The
                             \* per-row re-read (:1593) and the UPDATE's WHERE
                             \* (:1033) repeat it inside the same Repo call
                             \* (repo.ex:3124-3127), so they add nothing here.
    WorkersDieWithScheduler, \* DeliverySupervisor starts after the scheduler under
                             \* :rest_for_one (application.ex:362-363, :182)
    SendsDieWithWorker,      \* a worker's send process is spawned linked to it
                             \* (Process.spawn [:link, :monitor], channel_send.ex:219-224),
                             \* so a worker killed mid-send takes its send with it
    ResetSkipsMonitored,     \* the 60 s check leaves rows with a monitored worker
                             \* alone (scheduler.ex:528-531)
    RecoverSkipsSettled,     \* recovery leaves a row that is no longer delivering
                             \* untouched (temporal_sql.ex:1099-1102)
    RefusesWhileDelivering,  \* edit and cancel refuse while a row is delivering
                             \* (temporal_sql.ex:1554-1562, called at :589, :633)
    StableKey,               \* proactive_key is the row id on every attempt
                             \* (delivery.ex:68-70)
    HasWatchdog,             \* the worker kills its send after timeout_ms
                             \* (channel_send.ex:239, :284-300)
    ClampsWatchdog,          \* timeout_ms = min(60 s, valid_until - now)
                             \* (delivery_worker.ex:102-110)
    BoundaryExpires          \* the 60 s page expires pending rows past valid_until
                             \* (scheduler.ex:405-421, temporal_sql.ex:1203-1240)

VARIABLES
    status,     \* SQLite row: the reminder_occurrences status
    attempts,   \* SQLite row: attempt_count
    due,        \* SQLite row + clock: ready_at <= now
    eventLive,  \* SQLite row: the event is active and still on the row's revision
    valid,      \* clock: now < valid_until
    sched,      \* Scheduler process: "up", "claimed" (mid-tick: the claim returned,
                \* the worker not yet started) or "down" (restarting)
    monitors,   \* Scheduler GenServer state: slots whose worker it monitors
    worker,     \* DeliveryWorker process, per slot: "none" (no process), "start",
                \* "waiting" (on its send) or "got_*" (holds a result to settle)
    sender,     \* send process (linked, monitored), per slot: "idle" (none), "ready"
                \* (spawned, request not sent yet) or "out" (request sent)
    request,    \* platform, per slot: the request its send process waits on
    late,       \* platform: requests whose send process is gone; each may still
                \* be shown or dropped
    seen,       \* user: how many times the reminder was shown (saturates at 2)
    seenAfterChange,     \* observer: shown after the owner's change was accepted
    changed,             \* owner: an edit or cancel was accepted
    changedWhileSending, \* observer: it was accepted while a send for the
                         \* reminder was running or a request of it was still at
                         \* the platform
    changedWhileSendRunning,
                         \* observer: it was accepted while a send process for
                         \* the reminder was running
    faults      \* injected faults still allowed

vars == <<status, attempts, due, eventLive, valid, sched, monitors, worker, sender,
          request, late, seen, seenAfterChange, changed, changedWhileSending,
          changedWhileSendRunning, faults>>

\* The two change observers, which only OwnerChange writes.
changeObs == <<changedWhileSending, changedWhileSendRunning>>

Statuses == {"pending", "delivering", "delivered", "failed", "expired", "cancelled"}
Terminal == {"delivered", "failed", "expired", "cancelled"}
\* The worker holds a result and its next step is the settlement Repo call.
Got == {"got_ok", "got_retry", "got_fail", "got_expired"}
Alive == {"start", "waiting"} \cup Got

-----------------------------------------------------------------------------
(* Row rules shared by several steps *)

AtCap == AttemptCap /\ attempts >= 5

\* apply_retry/5 (temporal_sql.ex:1115-1126): the attempt cap first, then the
\* validity boundary. `fits`: the next ready_at falls strictly before
\* valid_until; the spec lets it go either way while the window is open.
AfterRetry(fits) ==
    IF AtCap THEN "failed"
    ELSE IF valid /\ fits THEN "pending"
    ELSE "expired"

\* A retry, a recovery or an expiry before the send: a new ready_at that is
\* not due yet.
RetryRow == \E fits \in BOOLEAN : status' = AfterRetry(fits) /\ due' = FALSE

\* recover_delivering/5 -> recover_row (temporal_sql.ex:1091-1106): a row that
\* is no longer delivering is reported :settled and left alone; otherwise
\* apply_retry at now + 5 s (scheduler.ex:332, :380, :547).
RecoverRow ==
    IF status /= "delivering" /\ RecoverSkipsSettled
    THEN UNCHANGED <<status, due>>
    ELSE RetryRow

\* The Repo call returns {:error, _}: its transaction rolls back, the row is
\* unchanged, and the scheduler logs it and moves on (log_recovery_error,
\* scheduler.ex:372-376; the boot sweep, :217).
\* A call that times out is not this. Every scheduler call passes
\* Repo.periodic_opts/2 (scheduler.ex:175-183), so a timeout returns
\* {:error, :repo_timeout} (call_or_timeout_error, repo.ex:4188-4196) and
\* takes the same error branch, but the request is not cancelled: the Repo
\* serves requests in order, so it still runs, ahead of anything the
\* scheduler sends next (repo.ex:4173-4177). Its write lands whole, and no
\* scheduler step can read the row in between. At every site but the claim
\* that is the site's success step taken where the write lands; the claim is
\* ClaimTimesOut.
RepoFails ==
    /\ RepoCanFail /\ faults > 0
    /\ faults' = faults - 1
    /\ UNCHANGED <<status, due>>

\* sweep_row (temporal_sql.ex:1182-1193): validity first, then the cap, else
\* pending with the same ready_at (so still due).
SweptTo ==
    IF ~valid THEN "expired"
    ELSE IF AtCap THEN "failed"
    ELSE "pending"

\* The platform puts the reminder in front of the user. The companion timeline
\* drops a second message with the same key (output.ex:279-281, which the
\* mobile and companion adapters write through -> mobile_sql.ex:507-517,
\* unique index :52-54); no other platform reads the key.
AlreadyShownUnderKey == PlatformDedupes /\ StableKey /\ seen > 0
Show ==
    IF AlreadyShownUnderKey
    THEN UNCHANGED <<seen, seenAfterChange>>
    ELSE /\ seen' = IF seen >= 2 THEN 2 ELSE seen + 1
         /\ seenAfterChange' = (seenAfterChange \/ changed)

\* The spec's slot bound: a slot a new worker may use. It reads send-process
\* state the scheduler cannot see, so it is not scheduler logic; TypeOK
\* asserts it never blocks a claim.
FreeSlots == {w \in Workers : worker[w] = "none" /\ w \notin monitors /\ sender[w] = "idle"}

\* A worker exited and the scheduler has not handled its DOWN yet.
DownPending == \E w \in monitors : worker[w] = "none"

\* A send process for the reminder is running.
SendRunning == \E w \in Workers : sender[w] /= "idle"

\* A send for the reminder is running, or a request of it is still at the
\* platform.
Sending == SendRunning \/ late > 0

\* Something a crash could interrupt. A crash with nothing in flight changes
\* nothing durable: init re-arms both timers (scheduler.ex:116-124).
InFlight ==
    \/ sched = "claimed"
    \/ status = "delivering"
    \/ \E w \in Workers : worker[w] /= "none" \/ sender[w] /= "idle"

-----------------------------------------------------------------------------
(* The scheduler (Temporal.Scheduler, one GenServer) *)

\* due_reminder_ids + fetch_claimable (temporal_sql.ex:1565-1604): pending,
\* under the cap, due, still valid, event active on the row's revision.
\* The spec stops at a sixth claim: that is the attempt the rule forbids.
Claimable ==
    /\ status = "pending" \/ (~ClaimRequiresPending /\ status = "delivering")
    /\ ~AtCap
    /\ attempts < 6
    /\ due /\ valid /\ eventLive

\* :due_tick or :reconcile_tick -> run_due -> claim_due (scheduler.ex:248-258)
\* -> Repo.claim_due_reminders, ONE Repo callback (repo.ex:3124-3127) that
\* runs the due scan and every per-row claim (temporal_sql.ex:1001-1038):
\* delivering and attempt_count + 1 before any I/O. The free-slot guard is
\* the spec's bound, not free_slots/1 (DeliverySupervisor allows 4).
Claim ==
    /\ sched = "up"
    /\ Claimable
    /\ FreeSlots /= {}
    /\ status' = "delivering"
    /\ attempts' = attempts + 1
    /\ sched' = "claimed"
    /\ UNCHANGED <<due, eventLive, valid, monitors, worker, sender, request, late,
                   seen, seenAfterChange, changed, changeObs, faults>>

\* The rest of the same callback: start_delivery -> DeliverySupervisor.
\* start_child, then Process.monitor (scheduler.ex:293-316). The worker's init
\* does no I/O (delivery_worker.ex:60). A worker that already exited before
\* the monitor still yields a DOWN (:noproc), so folding the monitor into the
\* start loses nothing. CHOOSE picks one free slot, always the same one for
\* the same state: slots are interchangeable, so which one does not matter.
StartWorker ==
    /\ sched = "claimed"
    /\ FreeSlots /= {}
    /\ LET w == CHOOSE x \in FreeSlots : TRUE IN
         /\ worker' = [worker EXCEPT ![w] = "start"]
         /\ monitors' = monitors \cup {w}
    /\ sched' = "up"
    /\ UNCHANGED <<status, attempts, due, eventLive, valid, sender, request, late,
                   seen, seenAfterChange, changed, changeObs, faults>>

\* The same Repo.claim_due_reminders call times out (see RepoFails):
\* claim_due logs "Reminder due scan failed" and returns {:error, state}
\* (scheduler.ex:260-262), so no worker starts, nothing is monitored and the
\* scheduler stays up. The claim still runs before the scheduler's next Repo
\* call: the row is delivering with its attempt consumed, and no DOWN will
\* recover it. The 60 s monitor check resets it (the expected cause named at
\* scheduler.ex:520-524), or a restart's boot sweep. This is the one site
\* where a timeout is not an existing step: the success branch starts a
\* worker, the error branch does not, and the write lands either way. A
\* claim that finds nothing claimable when it runs changes nothing.
ClaimTimesOut ==
    /\ RepoCanFail /\ faults > 0
    /\ sched = "up"
    /\ Claimable
    /\ FreeSlots /= {}
    /\ faults' = faults - 1
    /\ status' = "delivering"
    /\ attempts' = attempts + 1
    /\ UNCHANGED <<due, eventLive, valid, sched, monitors, worker, sender, request, late,
                   seen, seenAfterChange, changed, changeObs>>

\* handle_info({:DOWN, ...}) -> worker_down -> recover (scheduler.ex:158-162,
\* :322-351): drop the monitor, then one Repo.recover_delivering_reminder call.
\* A recover that times out is logged "claim recovery failed" (:348-349,
\* :372-376), but it still runs before the scheduler's next Repo call, so it
\* is the RecoverRow branch taken where it lands, not RepoFails. Only other
\* processes' calls can land in between, and none is a worker of this row
\* (the dead worker's settlement was sent before its DOWN). The 60 s check's
\* list, a new claim and a restart's boot sweep are all sent after it and
\* served after it, so none of them races it. The scheduler only skips
\* re-arming its due timer, which the 60 s tick's due scan covers.
Down(w) ==
    /\ sched = "up"
    /\ w \in monitors /\ worker[w] = "none"
    /\ monitors' = monitors \ {w}
    /\ \/ RecoverRow /\ UNCHANGED faults
       \/ status = "delivering" /\ RepoFails
    /\ UNCHANGED <<attempts, eventLive, valid, sched, worker, sender, request, late,
                   seen, seenAfterChange, changed, changeObs>>

\* The 60 s :reconcile_tick -> assert_monitor_invariant (scheduler.ex:525-565):
\* list delivering rows, then recover each one no monitored worker holds.
\* Two Repo calls folded into one step: between them only a worker's
\* settlement can land, and recover_row re-reads the row anyway.
\* A list that times out is a read, so it is the RepoFails branch (nothing
\* changes); a recover that times out still runs before the scheduler's next
\* call, so it is the RecoverRow branch taken where it lands, as in Down.
MonitorCheck ==
    /\ sched = "up"
    /\ status = "delivering"
    /\ monitors = {} \/ ~ResetSkipsMonitored
    /\ \/ RecoverRow /\ UNCHANGED faults
       \/ RepoFails
    /\ UNCHANGED <<attempts, eventLive, valid, sched, monitors, worker, sender, request,
                   late, seen, seenAfterChange, changed, changeObs>>

\* The 60 s :reconcile_tick -> reconcile_boundaries (scheduler.ex:405-421) ->
\* temporal_sql.ex:1203-1240: a pending row past valid_until is expired.
\* A page that errors leaves the row for the next page (a stutter); one that
\* times out still runs before the scheduler's next call, so it is this step.
BoundaryPage ==
    /\ BoundaryExpires
    /\ sched = "up"
    /\ status = "pending" /\ ~valid
    /\ status' = "expired"
    /\ UNCHANGED <<attempts, due, eventLive, valid, sched, monitors, worker, sender,
                   request, late, seen, seenAfterChange, changed, changeObs,
                   faults>>

\* The restarted scheduler's init/1 -> boot_sweep (scheduler.ex:116-124,
\* :212-221) -> Repo.sweep_delivering_reminders (temporal_sql.ex:1165-1193).
\* A failed sweep is logged and the scheduler boots anyway. A sweep that
\* times out is logged the same way (:214) but still runs before the
\* scheduler's next call, so it is the first branch taken where it lands; the
\* RepoFails branch is a sweep that rolled back.
Boot ==
    /\ sched = "down"
    /\ sched' = "up"
    /\ \/ /\ status = "delivering"
          /\ status' = SweptTo
          /\ UNCHANGED <<due, faults>>
       \/ /\ status = "delivering"
          /\ RepoFails
       \/ /\ status /= "delivering"
          /\ UNCHANGED <<status, due, faults>>
    /\ UNCHANGED <<attempts, eventLive, valid, monitors, worker, sender, request, late,
                   seen, seenAfterChange, changed, changeObs>>

-----------------------------------------------------------------------------
(* Crashes *)

\* The scheduler, or any earlier child of FermixCore.Supervisor (Repo,
\* MainAgent, JobScheduler, ...), crashes. :rest_for_one (application.ex:182)
\* terminates every later child, DeliverySupervisor and its workers included
\* (:347-348), before init runs again. The workers do not trap exits, so they
\* die at once. Each worker's send process is linked to it
\* (Process.spawn [:link, :monitor], channel_send.ex:219-224), so it dies
\* too, as in DaemonCrash: a request it already wrote is still processed by
\* the platform. (With SendsDieWithWorker off, the sends are not linked and
\* belong to no supervisor, so they keep running: the code before the fix.)
\* In the spec a running send implies its worker is waiting, so when the
\* workers die every send dies. A worker killed in the few instructions
\* between its watchdog's unlink and kill (channel_send.ex:281-287) would
\* leave its send running; that is below this spec's step granularity.
\* Capabilities.AccessGate.Pending (application.ex:340) and ReplyBlocks
\* (:344) are two more earlier children: a crash of either is this step. The
\* owner confirmations one parks and the place records the other holds are
\* never read by the reminder rail, so they are not modelled.
\* A scheduler Repo call that times out is no longer a cause: it returns an
\* error and the scheduler keeps running (RepoFails, ClaimTimesOut).
SendsDie == WorkersDieWithScheduler /\ SendsDieWithWorker

SchedulerRestart ==
    /\ SchedulerCanRestart /\ faults > 0
    /\ sched /= "down" /\ InFlight
    /\ faults' = faults - 1
    /\ sched' = "down"
    /\ monitors' = {}
    /\ worker' = IF WorkersDieWithScheduler THEN [w \in Workers |-> "none"] ELSE worker
    /\ sender' = IF SendsDie THEN [w \in Workers |-> "idle"] ELSE sender
    /\ request' = IF SendsDie THEN [w \in Workers |-> "none"] ELSE request
    /\ late' = IF SendsDie
               THEN late + Cardinality({w \in Workers : request[w] = "pending"})
               ELSE late
    /\ UNCHANGED <<status, attempts, due, eventLive, valid, seen, seenAfterChange,
                   changed, changeObs>>

\* The BEAM dies: every process goes. A request already at the platform is
\* still processed there.
DaemonCrash ==
    /\ DaemonCanCrash /\ faults > 0 /\ InFlight
    /\ faults' = faults - 1
    /\ sched' = "down"
    /\ monitors' = {}
    /\ worker' = [w \in Workers |-> "none"]
    /\ sender' = [w \in Workers |-> "idle"]
    /\ request' = [w \in Workers |-> "none"]
    /\ late' = late + Cardinality({w \in Workers : request[w] = "pending"})
    /\ UNCHANGED <<status, attempts, due, eventLive, valid, seen, seenAfterChange,
                   changed, changeObs>>

-----------------------------------------------------------------------------
(* A DeliveryWorker (restart: :temporary) in slot w *)

\* handle_continue(:deliver) -> run/1 (delivery_worker.ex:63-80): watchdog_ms
\* (:102-110), then Delivery.attempt -> ChannelSend.with_timeout, which spawns
\* the send process linked and monitored (delivery.ex:52-66,
\* channel_send.ex:219-224).
\* Past valid_until it sends nothing and settles through the retry path
\* (expire_unclaimable, delivery_worker.ex:164-176).
Start(w) ==
    /\ worker[w] = "start"
    /\ IF valid
       THEN /\ worker' = [worker EXCEPT ![w] = "waiting"]
            /\ sender' = [sender EXCEPT ![w] = "ready"]
       ELSE /\ worker' = [worker EXCEPT ![w] = "got_expired"]
            /\ UNCHANGED sender
    /\ UNCHANGED <<status, attempts, due, eventLive, valid, sched, monitors, request,
                   late, seen, seenAfterChange, changed, changeObs, faults>>

\* The `after timeout_ms` clause of monitored_call (channel_send.ex:239) ->
\* kill_and_drain/3 (:284-300): unlink, kill the send process, wait for its
\* :DOWN, drop any result it posted, and report :delivery_timeout, which is
\* retryable (error.ex:191). A request already at the platform is not recalled. Unless
\* the platform can be slow, it always answers inside the watchdog, so the
\* watchdog can only catch a send that has not reached it (a stuck pool
\* checkout, for example).
Watchdog(w) ==
    /\ HasWatchdog
    /\ worker[w] = "waiting"
    /\ request[w] = "none" \/ PlatformCanBeSlow
    /\ worker' = [worker EXCEPT ![w] = "got_retry"]
    /\ sender' = [sender EXCEPT ![w] = "idle"]
    /\ request' = [request EXCEPT ![w] = "none"]
    /\ late' = IF request[w] = "pending" THEN late + 1 ELSE late
    /\ UNCHANGED <<status, attempts, due, eventLive, valid, sched, monitors, seen,
                   seenAfterChange, changed, changeObs, faults>>

\* settle/5 (delivery_worker.ex:114-158, :164-176): one Repo call, then the
\* worker exits (:65-66). Every settle_* refuses a row that is not delivering
\* (ensure_delivering, temporal_sql.ex:1551-1552); the worker then exits
\* abnormally and the row is left as it is. A settlement call that times out
\* still lands (it is already in the Repo's mailbox, ahead of the DOWN
\* recovery), so it is this step, not WorkerCrash.
\*   ok        -> delivered                  (settle_delivered :1041-1048)
\*   retryable -> apply_retry                (settle_retry :1058-1065)
\*   permanent -> failed                     (settle_failed :1070-1082)
\*   too late  -> apply_retry at now         (failed at the cap, else expired)
Settle(w) ==
    /\ worker[w] \in Got
    /\ worker' = [worker EXCEPT ![w] = "none"]
    /\ IF status /= "delivering"
       THEN UNCHANGED <<status, due>>
       ELSE CASE worker[w] = "got_ok"      -> status' = "delivered" /\ UNCHANGED due
              [] worker[w] = "got_fail"    -> status' = "failed" /\ UNCHANGED due
              [] worker[w] = "got_retry"   -> RetryRow
              [] worker[w] = "got_expired" -> status' = AfterRetry(FALSE) /\ due' = FALSE
    /\ UNCHANGED <<attempts, eventLive, valid, sched, monitors, sender, request, late,
                   seen, seenAfterChange, changed, changeObs, faults>>

\* The worker exits abnormally before it settles: a raise before the send, or
\* its settlement Repo call returns an error, which rolls back (settlement_error,
\* delivery_worker.ex:197-200 -> {:stop, {:settlement_failed, _}}, :66). While
\* it waits on its send it runs no code of its own, so it only dies there
\* when something kills it (see SchedulerRestart).
WorkerCrash(w) ==
    /\ WorkersCanCrash /\ faults > 0
    /\ worker[w] \in {"start"} \cup Got
    /\ worker' = [worker EXCEPT ![w] = "none"]
    /\ faults' = faults - 1
    /\ UNCHANGED <<status, attempts, due, eventLive, valid, sched, monitors, sender,
                   request, late, seen, seenAfterChange, changed, changeObs>>

WorkerStep(w) == Start(w) \/ Watchdog(w) \/ Settle(w)

-----------------------------------------------------------------------------
(* The send process of slot w, and the platform *)

\* The send process runs adapter.send_message once (delivery_max_attempts: 1,
\* delivery.ex:62; channel_send.ex:135-149): the request reaches the platform.
SenderSend(w) ==
    /\ sender[w] = "ready"
    /\ sender' = [sender EXCEPT ![w] = "out"]
    /\ request' = [request EXCEPT ![w] = "pending"]
    /\ UNCHANGED <<status, attempts, due, eventLive, valid, sched, monitors, worker,
                   late, seen, seenAfterChange, changed, changeObs, faults>>

\* The platform processes the request and answers: it shows the reminder and
\* answers ok, or rejects it with a transient or a permanent error.
PlatformDecide(w) ==
    /\ request[w] = "pending"
    /\ \/ request' = [request EXCEPT ![w] = "ok"] /\ Show
       \/ request' = [request EXCEPT ![w] = "transient"] /\ UNCHANGED <<seen, seenAfterChange>>
       \/ request' = [request EXCEPT ![w] = "permanent"] /\ UNCHANGED <<seen, seenAfterChange>>
    /\ UNCHANGED <<status, attempts, due, eventLive, valid, sched, monitors, worker,
                   sender, late, changed, changeObs, faults>>

\* The send process takes the platform's answer, messages its worker and
\* exits :normal (channel_send.ex:224, :227-233, :248-254). Its worker then
\* drops the link and the monitor (release/2, :264-269). A worker that is
\* gone never gets the answer.
\* The worker's view goes through Error.normalize/retryable? (error.ex:189-204).
SenderAnswer(w) ==
    /\ sender[w] = "out"
    /\ request[w] \in {"ok", "transient", "permanent"}
    /\ sender' = [sender EXCEPT ![w] = "idle"]
    /\ request' = [request EXCEPT ![w] = "none"]
    /\ worker' = IF worker[w] = "waiting"
                 THEN [worker EXCEPT ![w] = CASE request[w] = "ok"        -> "got_ok"
                                              [] request[w] = "transient" -> "got_retry"
                                              [] request[w] = "permanent" -> "got_fail"]
                 ELSE worker
    /\ UNCHANGED <<status, attempts, due, eventLive, valid, sched, monitors, late,
                   seen, seenAfterChange, changed, changeObs, faults>>

\* A request whose send process is gone is still processed by the platform:
\* shown or dropped.
PlatformLate ==
    /\ late > 0
    /\ late' = late - 1
    /\ \/ Show
       \/ UNCHANGED <<seen, seenAfterChange>>
    /\ UNCHANGED <<status, attempts, due, eventLive, valid, sched, monitors, worker,
                   sender, request, changed, changeObs, faults>>

-----------------------------------------------------------------------------
(* The owner and the clock *)

\* event_update / event_remove -> Repo.update_temporal_event or
\* cancel_temporal_event (temporal_sql.ex:587-599, :631-639): refused while a
\* row of the event is delivering (ensure_no_delivery_in_flight, :1554-1562);
\* otherwise the event moves to a new revision or is cancelled, and a pending
\* row is cancelled (cancel_superseded_rows :613-625, execute_cancel_pending
\* :649-661). The refusal and the write are one Repo call. One accepted
\* change is enough for one occurrence.
OwnerChange ==
    /\ OwnerCanChange /\ ~changed
    /\ ~(RefusesWhileDelivering /\ status = "delivering")
    /\ changed' = TRUE
    /\ changedWhileSending' = Sending
    /\ changedWhileSendRunning' = SendRunning
    /\ eventLive' = FALSE
    /\ status' = IF status = "pending" THEN "cancelled" ELSE status
    /\ UNCHANGED <<attempts, due, valid, sched, monitors, worker, sender, request, late,
                   seen, seenAfterChange, faults>>

\* ready_at passes and the scheduler's due timer fires (schedule_due_timer,
\* scheduler.ex:569-628; the 60 s tick also runs a due scan).
\* DownHandledBeforeRetryDue: a worker that settled a retry has exited, and
\* its DOWN is in the scheduler's mailbox long before the retry is due (the
\* shortest retry delay is 60 s, delivery.ex:29, delivery_worker.ex:130).
\* That is a delay, not an ordering the code checks: recover_row re-reads the
\* row by id only, so a DOWN handled after a new claim resets that claim under
\* its live worker (check 20).
BecomeDue ==
    /\ status = "pending" /\ ~due
    /\ ~(DownHandledBeforeRetryDue /\ DownPending)
    /\ due' = TRUE
    /\ UNCHANGED <<status, attempts, eventLive, valid, sched, monitors, worker, sender,
                   request, late, seen, seenAfterChange, changed, changeObs,
                   faults>>

\* Wall-clock time passes valid_until. This guard IS the clamp, written as a
\* constraint on the clock: with timeout_ms = min(60 s, valid_until - now)
\* (delivery_worker.ex:102-110) the watchdog fires before valid_until, so no
\* worker is still waiting on its send when the boundary passes.
Expire ==
    /\ valid
    /\ ~(HasWatchdog /\ ClampsWatchdog /\ \E w \in Workers : worker[w] = "waiting")
    /\ valid' = FALSE
    /\ UNCHANGED <<status, attempts, due, eventLive, sched, monitors, worker, sender,
                   request, late, seen, seenAfterChange, changed, changeObs,
                   faults>>

-----------------------------------------------------------------------------
(* Type and sanity invariant *)

\* The types, plus one sanity bound on the spec itself (not a Fermix rule):
\* the slot bound never blocks a claim, so three slots lose no behaviour.
SlotBoundNeverBinds == (sched = "up" /\ Claimable) => FreeSlots /= {}

TypeOK ==
    /\ status \in Statuses
    /\ attempts \in 0..6
    /\ due \in BOOLEAN /\ eventLive \in BOOLEAN /\ valid \in BOOLEAN
    /\ sched \in {"up", "claimed", "down"}
    /\ monitors \subseteq Workers
    /\ worker \in [Workers -> {"none"} \cup Alive]
    /\ sender \in [Workers -> {"idle", "ready", "out"}]
    /\ request \in [Workers -> {"none", "pending", "ok", "transient", "permanent"}]
    /\ late \in Nat
    /\ seen \in 0..2
    /\ seenAfterChange \in BOOLEAN
    /\ changed \in BOOLEAN /\ changedWhileSending \in BOOLEAN
    /\ changedWhileSendRunning \in BOOLEAN
    /\ faults \in 0..MaxFaults
    /\ SlotBoundNeverBinds

-----------------------------------------------------------------------------
Init ==
    /\ status = "pending"
    /\ attempts = 0
    /\ due = FALSE
    /\ eventLive = TRUE
    /\ valid = TRUE
    /\ sched = "up"
    /\ monitors = {}
    /\ worker = [w \in Workers |-> "none"]
    /\ sender = [w \in Workers |-> "idle"]
    /\ request = [w \in Workers |-> "none"]
    /\ late = 0
    /\ seen = 0
    /\ seenAfterChange = FALSE
    /\ changed = FALSE
    /\ changedWhileSending = FALSE
    /\ changedWhileSendRunning = FALSE
    /\ faults = MaxFaults

\* The legitimate end: the row settled, the scheduler up with nothing to
\* handle, no worker or send process left, nothing held at the platform.
\* Deadlock checking is on, so any other state where nothing can happen is
\* reported as a wedge.
Done ==
    /\ status \in Terminal
    /\ sched = "up"
    /\ monitors = {}
    /\ \A w \in Workers : worker[w] = "none" /\ sender[w] = "idle"
    /\ late = 0

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ Claim \/ StartWorker \/ ClaimTimesOut \/ MonitorCheck \/ BoundaryPage \/ Boot
    \/ \E w \in Workers :
          \/ Down(w) \/ WorkerStep(w) \/ WorkerCrash(w)
          \/ SenderSend(w) \/ SenderAnswer(w) \/ PlatformDecide(w)
    \/ PlatformLate \/ OwnerChange \/ BecomeDue \/ Expire
    \/ SchedulerRestart \/ DaemonCrash
    \/ Terminated

\* Fairness only on what Fermix drives: the scheduler's callbacks and timers,
\* each live worker's next step (its watchdog included), and a live send
\* process sending its request and taking an answer the platform has given.
\* None on the platform (PlatformDecide and PlatformLate, where its slowness
\* lives), the owner, the clock passing valid_until, or faults.
Fairness ==
    /\ WF_vars(Claim) /\ WF_vars(StartWorker) /\ WF_vars(MonitorCheck)
    /\ WF_vars(BoundaryPage) /\ WF_vars(Boot) /\ WF_vars(BecomeDue)
    /\ \A w \in Workers :
          /\ WF_vars(Down(w)) /\ WF_vars(WorkerStep(w))
          /\ WF_vars(SenderSend(w)) /\ WF_vars(SenderAnswer(w))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* scheduler.ex:326-329: a still-delivering row "returns to pending at the
\* error floor with its attempt consumed, or becomes failed at the cap —
\* never attempt six."
NeverAttemptSix == attempts <= 5

\* delivery_supervisor.ex:5-10 and application.ex:355-363: "no delivery
\* worker can outlive the scheduler", which is "what lets claims be
\* serialized in one process"; M30 design §6.3 (:335-337): "two workers for
\* the same row cannot exist".
SingleWorker == Cardinality({w \in Workers : worker[w] \in Alive}) <= 1

\* M30 design §6.3 (docs/design/MILESTONE_30_TEMPORAL_EVENTS_AND_PROACTIVE_
\* REMINDERS.md:339): "a scheduler-only crash kills in-flight sends";
\* channel_send.ex:98-105: "The send never outlives its caller, except in
\* the few instructions between the watchdog's unlink and its kill" (that
\* exception is below this spec's step granularity). Read as: while the
\* scheduler is restarting, no send for the reminder is running.
RestartKillsSends == sched = "down" => \A w \in Workers : sender[w] = "idle"

\* The premise of M30 §19.10's no-lease design (docs/design/MILESTONE_30_...
\* :1757-1769: leases return only "if delivery ever moves outside the
\* daemon's process tree"): one claim, one worker, one send. Read as: at most
\* one send process for the reminder runs at a time.
OneSendAtATime == Cardinality({w \in Workers : sender[w] /= "idle"}) <= 1

\* delivery_worker.ex:11-13: "a claimed send always finishes or is killed
\* before its validity boundary, which is what stops an obsolete early
\* reminder from landing after its superseding rule is due".
SendEndsBeforeBoundary == ~valid => \A w \in Workers : sender[w] = "idle"

\* registry.ex:676-679, the refusal the owner gets: "A reminder for this
\* event is being sent right now and a send cannot be recalled. Wait for the
\* attempt to finish and try again." M30 design (:1490): "Event mutation
\* while a send is in flight | Fail with delivery_in_progress". Read as: an
\* edit or cancel is accepted only when no send process for the reminder is
\* running, that is, once the bounded attempt has finished. (That the
\* refusal matches the status column is a single-call fact,
\* temporal_sql.ex:587-599, :631-639, and belongs in ExUnit.)
NoChangeWhileSendRunning == ~changedWhileSendRunning

\* Proposed rule: an edit or cancel is accepted only when no send for the
\* reminder is running AND no request of it is still at the platform. M30
\* §7.3 (:609-614) scopes the refusal to the bounded attempt and disclaims
\* recall ("instead of pretending it revoked an external side effect"), so
\* the code does not claim this (REMIND-3).
NoChangeWhileRequestAtPlatform == ~changedWhileSending

\* Proposed rule: once the owner's edit or cancel is accepted, the old
\* reminder never reaches the user.
NoReminderAfterChange == ~seenAfterChange

\* Proposed rule: the user sees each reminder at most once. (M30 §11.5
\* promises only at-least-once.)
AtMostOnce == seen <= 1

\* Proposed rule: every reminder ends delivered, failed, expired or
\* cancelled, and stays there (scheduler.ex:520-524: a stranded row is "never
\* left `delivering` forever").
Settles == <>[](status \in Terminal)

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* The 60 s monitor check has work: a delivering row that no worker holds and
\* no DOWN will recover, with the scheduler up.
Witness_StrandedClaim ==
    ~(sched = "up" /\ status = "delivering" /\ monitors = {}
      /\ \A w \in Workers : worker[w] = "none")

\* A worker starts after valid_until although its claim was valid: the path
\* delivery_worker.ex:160-163 calls impossible ("cannot happen through the
\* scheduler's due scan").
Witness_StartPastBoundary == \A w \in Workers : worker[w] /= "got_expired"

=============================================================================
