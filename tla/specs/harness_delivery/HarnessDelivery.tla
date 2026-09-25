-------------------------- MODULE HarnessDelivery --------------------------
(***************************************************************************)
(* How ONE local coding-harness run's outcome reaches the owner: the Run   *)
(* reporting its end (or crashing), the Harness.Manager writing the one    *)
(* terminal ledger row (which also leases the row to the Manager's inline  *)
(* first attempt), running the memory write-back and handing the outcome   *)
(* off (a continuation turn, an inline text, or a dead letter), the        *)
(* DeliveryWorker's 30 s outbox tick, a Manager crash with its             *)
(* :rest_for_one restart and boot reconciliation, the owner's cancel of an *)
(* active row the Manager no longer tracks, and sends that fail or time    *)
(* out after they landed. The Manager can crash at every step, including  *)
(* between the terminal write and the write-back, and during the           *)
(* write-back itself (a second Repo call).                                 *)
(*                                                                         *)
(* Not modelled:                                                           *)
(* - admission and its refusals (the row starts admitted, the Run started) *)
(* - the cloud rail (submit, polling, stop_tracking)                       *)
(* - the owner's cancel of a TRACKED run, and /stop: for a framework       *)
(*   origin they only choose the "text" hand-off; for a client-owned       *)
(*   origin a tracking-stopped or depth-capped row, or one with no         *)
(*   dispatcher, is dead-lettered with no send at all (manager.ex:1123-1128,*)
(*   :1134-1139, :1186-1192). The cancel of an UNTRACKED row is modelled   *)
(*   (OwnerCancelUntracked), including its owner-halt dead letter.         *)
(* - the continuation depth cap itself (a pure per-row rule; ExUnit)       *)
(* - delivery_mode "none" and "local", which succeed without a channel     *)
(*   send (delivery.ex:108-110)                                            *)
(* - advisory notices and telemetry                                        *)
(* - the worker's backoff clock and max-age rule (a rescheduled row is     *)
(*   simply due again at a later tick)                                     *)
(* - the hand-off lease's length: the lease is a flag here, and its end    *)
(*   waits for the Manager's hand-off (see LeaseEnds). That the length     *)
(*   covers the hand-off is checked by ExUnit ("the lease outlasts the     *)
(*   longest inline hand-off", manager_test.exs), not by TLC               *)
(* - a failed delivery mark (logged; the row stays pending, the same       *)
(*   at-least-once resend a timeout gives)                                 *)
(* - the DeliveryWorker crashing on its own                                *)
(* - other runs (the Manager and the worker each handle one run at a       *)
(*   time, so one run covers the interleavings that matter)                *)
(*                                                                         *)
(* One step = one indivisible thing in the code: one GenServer callback    *)
(* up to its next call into another process, one Memory.Repo call (all     *)
(* SQLite goes through that one process), or one effect at a platform.     *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/manager.ex @ cd3fef98ab3d
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/delivery_worker.ex @ baa051c7b24d
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/continuation.ex @ 630753e79843
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/continuation_dispatcher.ex @ 92d85f69b270
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/delivery.ex @ 99276b23ba8c
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/ledger.ex @ 765a9a695ae5
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/memory_writeback.ex @ d85eb40385ad
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/supervisor.ex @ f4967c985e88
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/run_supervisor.ex @ 434b12f3182b
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/run.ex @ 788c70041804
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#call,admit_harness_run,admit_harness_run_tx,admit_harness_run_in_tx,ensure_harness_capacity,insert_harness_run_row,terminalize_harness_run,terminalize_harness_run_row,update_harness_run,update_harness_run_row,pending_harness_deliveries,fetch_pending_harness_deliveries,active_harness_runs,fetch_active_harness_runs,normalize_harness_run_attrs,upsert_memory,@harness_runs_schema_sql,@harness_active_status_sql @ 025ab35639d2
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#interpret_harness_terminalize,harness_terminalize_rejection,harness_run_set_clause,harness_run_set_entry,@harness_run_timestamp_cols @ 7799fd5a935f
\* SOURCE: apps/fermix_core/lib/fermix_core/delivery/channel_send.ex @ 380824457212
\* SOURCE: apps/fermix_channels/lib/fermix_channels/harness/continuation_dispatcher.ex @ d4e6a8909e30
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway.ex#ingest,do_deliver_to_agent @ a988106fa5ca
EXTENDS Naturals, Sequences

CONSTANTS
    Origins,        \* hand-off kinds to explore, a subset of {"chat", "text", "client"}:
                    \*   "chat"   chat origin inside the chain cap: continuation dispatch
                    \*   "text"   scheduled origin, capped chain, owner halt or no
                    \*            dispatcher on a framework channel: inline text
                    \*   "client" client-owned (ACP) origin inside the chain cap:
                    \*            continuation, else dead letter
    MaxAttempts,       \* the worker's dead-letter cap (delivery_max_attempts, default 20)
    MaxManagerCrashes, \* how many times the Manager may die in one behaviour
    \* Environment switches: what may happen.
    RunsCanCrash,            \* the Run raises before it reports (abnormal DOWN)
    ManagerCanCrash,         \* the Manager dies and its supervisor restarts it
    SendsCanFail,            \* a text send or a dispatch is refused, or the watchdog
                             \* fires before the platform or gateway accepted it
    AcceptedSendsCanTimeOut, \* the watchdog fires AFTER the platform or gateway
                             \* accepted: with_timeout cannot tell (channel_send.ex:219-240)
    TerminalWriteCanFail,    \* the terminal UPDATE returns an error (SQLite busy, I/O, full)
    ReconcileScanCanFail,    \* the boot scan (Ledger.active_runs) returns an error: it is
                             \* logged and nothing is reconciled (manager.ex:1344-1349,
                             \* :1439-1442)
    LeaseCanLapse,           \* the hand-off lease ends while the Manager is still inside
                             \* its hand-off: a laptop sleep or a wall-clock jump moves the
                             \* wall clock past next_delivery_at while BEAM timers pause
    OwnerCancels,            \* the owner cancels (cancel_coding_run) a run the Manager
                             \* no longer tracks
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* a check switches one off to show a property rests on it.
    CleanDownDropsOnly,    \* a :normal/:shutdown DOWN only drops the monitor (manager.ex:1017)
    IgnoresUntrackedRun,   \* every terminalization outcome ends in drop_run (manager.ex:1068,
                           \* :1083, :1088, :1245-1261), and a report or DOWN for a run no
                           \* longer tracked is ignored (:997-999, :1015-1016, :1023-1024)
    GuardedTerminalUpdate, \* the terminal UPDATE only matches an active row (repo.ex:6329-6334);
                           \* :already_terminal is dropped (manager.ex:1040, :1079-1084)
    RestForOne,            \* a Manager crash also restarts RunSupervisor and DeliveryWorker
                           \* (supervisor.ex:38-44), killing every live Run first
    ReconcilesAtBoot,      \* the restarted Manager finalizes active rows interrupted
                           \* (manager.ex:235-236, :1344-1354)
    CrashDownTerminalizes, \* an abnormal Run DOWN terminalizes failed/run_crashed
                           \* (manager.ex:1014-1027)
    MarksDelivered,        \* a successful hand-off marks the row delivered
                           \* (manager.ex:1143, :1148-1155, :1223, :1228-1238)
    ClientDeadLetters,     \* a failed client-owned dispatch dead-letters the row with its
                           \* named cause (manager.ex:1162-1168, :1196-1211)
    WorkerDrainsOutbox,    \* the worker selects terminal rows still pending
                           \* (delivery_worker.ex:101-123, repo.ex:6452-6464)
    DeadLetterCap,         \* the worker dead-letters at MaxAttempts (delivery_worker.ex:129-141)
    LeasesFirstAttempt,    \* the terminal write leases the row to the Manager's inline first
                           \* attempt: next_delivery_at = now + @handoff_lease_ms in the same
                           \* guarded UPDATE (terminalize_and_notify/4, manager.ex:1035-1047,
                           \* :83-95), and the worker selects only due rows (repo.ex:6461)
    SendsDieWithCaller,    \* a with_timeout sender is spawned linked to its caller
                           \* (Process.spawn [:link, :monitor], channel_send.ex:219-224), so a
                           \* caller that dies takes a sender still in flight with it
    CancelsStrandedRow     \* an owner cancel of an active local row the Manager does not
                           \* track terminalizes it cancelled (cancel_untracked/3,
                           \* manager.ex:977-992)

VARIABLES
    origin,      \* SQLite row: origin_kind / client_origin, frozen at admission
    rpc,         \* the Harness.Run process: "running" or "gone"
    runStale,    \* Run state: its :manager pid belongs to a dead Manager
    reported,    \* history: the Run sent its terminal report (run.ex:634)
    mbox,        \* Manager mailbox: the Run's report and DOWN messages, in order
    mpc,         \* Manager: which callback it is in (see MgrStates)
    mgrCrashes,  \* environment bound: Manager crashes so far
    tracked,     \* Manager state: the run is in its runs / run_monitors maps (manager.ex:353-364)
    wpc,         \* DeliveryWorker: "idle" between ticks, "sending" inside process_row
    wsnap,       \* DeliveryWorker: delivery_attempts in the row it selected
    snd,         \* snd[c]: the with_timeout sender process caller c is waiting on
    orphans,     \* orphans[k]: senders of kind k still in flight whose caller died
    status,      \* SQLite row: "active" or the terminal status written
    delivery,    \* SQLite row: delivery_status
    attempts,    \* SQLite row: delivery_attempts
    lastError,   \* SQLite row: last_delivery_error: "none", "named" (Manager) or "worker"
    leased,      \* SQLite row + clock: next_delivery_at is the hand-off lease, still ahead
    texts,       \* visible to the owner: text messages received for this run (capped at 2)
    turns,       \* visible to the owner: continuation turns ingested for this run (capped at 2)
    writes,      \* history: successful terminal writes (capped at 2)
    clientCause, \* history: the Manager named a client-owned row's cause (a failed
                 \* dispatch it saw, or an owner halt)
    confirmedTurn, \* history: the Manager saw its continuation dispatch answer :ok
    lied         \* history: an owner cancel of an active row was answered :already_terminal

\* History variables (reported, writes, clientCause, confirmedTurn, lied) are
\* read by no process: they record what already happened so the properties
\* can refer to the past.
runVars   == <<rpc, runStale, reported>>
mgrVars   == <<mbox, mpc, mgrCrashes, tracked>>
wkrVars   == <<wpc, wsnap>>
sndVars   == <<snd, orphans>>
rowVars   == <<status, delivery, attempts, lastError, leased>>
seenVars  == <<texts, turns>>
ghostVars == <<writes, clientCause, confirmedTurn, lied>>
vars == <<origin, runVars, mgrVars, wkrVars, sndVars, rowVars, seenVars, ghostVars>>

Callers   == {"mgr", "wkr"}
Kinds     == {"text", "turn"}
MgrStates == {"idle",        \* waiting for a message
              "reconcile",   \* restarted: handle_continue(:reconcile) still to run
              "reconciling", \* active_runs returned this row; terminalize it next
              "writeback",   \* terminal row written; memory write-back still to run
              "handoff"}     \* inside hand_off_outcome, waiting on its sender
Messages  == {"report", "down_normal", "down_crash"}

TypeOK ==
    /\ origin \in Origins
    /\ rpc \in {"running", "gone"}
    /\ runStale \in BOOLEAN /\ reported \in BOOLEAN
    /\ mbox \in Seq(Messages) /\ Len(mbox) <= 2
    /\ mpc \in MgrStates
    /\ mgrCrashes \in 0..MaxManagerCrashes
    /\ tracked \in BOOLEAN
    /\ wpc \in {"idle", "sending"} /\ wsnap \in 0..MaxAttempts
    /\ snd \in [Callers -> {"none", "flying", "landed"}]
    /\ orphans \in [Kinds -> 0..(1 + MaxManagerCrashes)]
    /\ status \in {"active", "result", "crashed", "interrupted", "cancelled"}
    /\ delivery \in {"pending", "delivered", "dead_letter"}
    /\ attempts \in 0..MaxAttempts
    /\ lastError \in {"none", "named", "worker"}
    /\ leased \in BOOLEAN
    /\ texts \in 0..2 /\ turns \in 0..2 /\ writes \in 0..2
    /\ clientCause \in BOOLEAN /\ confirmedTurn \in BOOLEAN /\ lied \in BOOLEAN

-----------------------------------------------------------------------------
Min(a, b) == IF a < b THEN a ELSE b
Sat(n)    == Min(n, 2)

\* What the Manager's hand-off sends (hand_off_outcome/3, manager.ex:1108-1113):
\* a chat or client-owned origin dispatches a continuation turn, the rest a
\* text. A cancelled row is an owner halt and never continues
\* (not_continuable_reason/1, :1134): a framework origin gets the inline text.
MgrKind == IF origin = "text" \/ status = "cancelled" THEN "text" ELSE "turn"
SenderKind(c) == IF c = "mgr" THEN MgrKind ELSE "text"

\* A client-owned origin's owner halt has no text path: no_continuation/3
\* dead-letters it as :owner_halt with no send (manager.ex:1186-1192).
OwnerHaltDeadLetters == origin = "client" /\ status = "cancelled"

\* The worker's text to a client-owned origin is refused inside its sender
\* before anything is dispatched: ChannelSend has no adapter for "acp"
\* (config.exs:117-125), so resolve_adapter answers
\* {:error, {:unsupported_delivery_platform, "acp"}} (channel_send.ex:312-321).
\* The Manager's continuation dispatch to that origin can land.
CanLand(c) == c = "mgr" \/ origin /= "client"

Notify(kind) ==
    IF kind = "text"
    THEN texts' = Sat(texts + 1) /\ UNCHANGED turns
    ELSE turns' = Sat(turns + 1) /\ UNCHANGED texts

-----------------------------------------------------------------------------
(* The Harness.Run process *)

\* handle_info({:command_host_exit, ...}) -> report_and_stop/3 (run.ex:125-131,
\* :631-636): send {:harness_report_terminal, ...} to the :manager pid, then
\* stop :normal, which queues a :normal DOWN behind it (Process.monitor,
\* manager.ex:354). A report to a dead Manager's pid is dropped.
RunReports ==
    /\ rpc = "running"
    /\ rpc' = "gone"
    /\ reported' = TRUE
    /\ mbox' = IF runStale THEN mbox ELSE mbox \o <<"report", "down_normal">>
    /\ UNCHANGED <<origin, runStale, mpc, mgrCrashes, tracked, wkrVars, sndVars,
                   rowVars, seenVars, ghostVars>>

\* The Run raises before its report: only an abnormal DOWN reaches the
\* Manager (manager.ex:289-291). After report_and_stop it cannot crash:
\* terminate/2 only closes an already-nil spool (run.ex:169, :707).
RunCrashes ==
    /\ RunsCanCrash
    /\ rpc = "running"
    /\ rpc' = "gone"
    /\ mbox' = IF runStale THEN mbox ELSE Append(mbox, "down_crash")
    /\ UNCHANGED <<origin, runStale, reported, mpc, mgrCrashes, tracked, wkrVars,
                   sndVars, rowVars, seenVars, ghostVars>>

-----------------------------------------------------------------------------
(* The Harness.Manager process                                             *)
(*                                                                         *)
(*   idle --report/DOWN/cancel--> [terminal write] --ok--> writeback -->   *)
(*     ^                        | error, :already_terminal       handoff   *)
(*     +------------------------+----------------------------------+       *)
(*   crash --> reconcile --> reconciling --> [terminal write] ...          *)

\* The Manager acts on a report or DOWN only for a run it still tracks,
\* unless that layer is switched off.
Knows == tracked \/ ~IgnoresUntrackedRun

\* terminalize_and_notify/4 (manager.ex:1035-1047): Ledger.terminalize ->
\* Repo terminalize_harness_run_row/4 (ledger.ex:72-79, repo.ex:6322-6337),
\* ONE Repo call running `UPDATE ... WHERE id = ? AND status IN (active)`. It
\* writes status, the outcome's ledger fields, completed_at and
\* next_delivery_at = now + @handoff_lease_ms (manager.ex:1036, :1045-1047):
\* the row is terminal and leased to this Manager's inline attempt at once,
\* so the worker cannot select it until the lease ends. delivery_status
\* stays 'pending' as admission wrote it (manager.ex:395-425,
\* repo.ex:502-505, :6770-6772).
\* The call has three outcomes, one per disjunct: the Repo returns an error;
\* the UPDATE changes the row; or the guard finds the row already terminal.
TerminalWrite(st) ==
    \/ /\ TerminalWriteCanFail
       \* after_terminalize_error/4 for a local run: log and drop_run
       \* (manager.ex:1049-1062, :1086-1089). The row stays active.
       /\ mpc' = "idle"
       /\ tracked' = FALSE
       /\ UNCHANGED <<status, writes, leased>>
    \/ /\ status = "active" \/ ~GuardedTerminalUpdate
       \* {:ok, row} -> post_terminal/5 (manager.ex:1039, :1064-1069).
       /\ status' = st
       /\ writes' = Sat(writes + 1)
       /\ leased' = LeasesFirstAttempt
       /\ mpc' = "writeback"
       /\ UNCHANGED tracked
    \/ /\ status /= "active" /\ GuardedTerminalUpdate
       \* {:error, :already_terminal} -> resolve_after_race: drop, never
       \* re-deliver or re-continue (manager.ex:1040, :1079-1084).
       /\ mpc' = "idle"
       /\ tracked' = FALSE
       /\ UNCHANGED <<status, writes, leased>>

TerminalWriteKeeps == UNCHANGED <<mpc, status, writes, tracked, leased>>

MgrKeeps == UNCHANGED <<origin, runVars, mgrCrashes, wkrVars, sndVars, delivery,
                        attempts, lastError, seenVars, clientCause, confirmedTurn, lied>>

\* handle_info({:harness_report_terminal, ...}) -> finalize_reported/4
\* (manager.ex:285-286, :996-1004); an untracked run's report is only logged
\* (log_unknown_report, :1006-1012).
MgrReport ==
    /\ mpc = "idle" /\ mbox /= <<>> /\ Head(mbox) = "report"
    /\ mbox' = Tail(mbox)
    /\ IF Knows THEN TerminalWrite("result") ELSE TerminalWriteKeeps
    /\ MgrKeeps

\* handle_info({:DOWN, ...}) -> handle_down/3 (manager.ex:289-290, :1014-1020):
\* a DOWN for an untracked run finds no monitor (:1015-1016); a :normal or
\* :shutdown DOWN only drops the monitor (:1017).
MgrCleanDown ==
    /\ mpc = "idle" /\ mbox /= <<>> /\ Head(mbox) = "down_normal"
    /\ mbox' = Tail(mbox)
    /\ IF Knows /\ ~CleanDownDropsOnly
       THEN TerminalWrite("crashed")
       ELSE TerminalWriteKeeps
    /\ MgrKeeps

\* An abnormal DOWN -> mark_run_crashed/2 -> terminalize failed/run_crashed
\* (manager.ex:1018, :1022-1027, :1290-1297).
MgrCrashDown ==
    /\ mpc = "idle" /\ mbox /= <<>> /\ Head(mbox) = "down_crash"
    /\ mbox' = Tail(mbox)
    /\ IF Knows /\ CrashDownTerminalizes
       THEN TerminalWrite("crashed")
       ELSE TerminalWriteKeeps
    /\ MgrKeeps

\* handle_continue(:reconcile) -> reconcile/1 -> Ledger.active_runs, one Repo
\* call (manager.ex:235-236, :1344-1349; repo.ex:6436-6450). A scan error is
\* only logged (log_reconcile_scan_error/2, manager.ex:1347, :1439-1442): the
\* row stays active and this Manager tracks nothing.
MgrReconcileScan ==
    /\ mpc = "reconcile"
    /\ \/ mpc' = IF ReconcilesAtBoot /\ status = "active" THEN "reconciling" ELSE "idle"
       \/ ReconcileScanCanFail /\ mpc' = "idle"
    /\ UNCHANGED <<origin, runVars, mbox, mgrCrashes, tracked, wkrVars, sndVars,
                   rowVars, seenVars, ghostVars>>

\* reconcile_row/2 for a local starting/running row: terminalize it
\* interrupted, then the same post_terminal (manager.ex:1351-1354, :1299-1301).
MgrReconcileRow ==
    /\ mpc = "reconciling"
    /\ TerminalWrite("interrupted")
    /\ UNCHANGED mbox
    /\ MgrKeeps

\* The rest of post_terminal/5 (manager.ex:1065-1067): run_complete/run_error
\* telemetry, then MemoryWriteback.write, which for a completed run is a
\* second Repo call, Repo.upsert_memory (memory_writeback.ex:46-52, :159);
\* then hand_off_outcome spawns the text send or the continuation dispatch
\* under ChannelSend.with_timeout (delivery.ex:280-293, continuation.ex:154-166)
\* and waits. The Manager can crash before this step (no sender exists yet).
\* An owner halt of a client-owned row instead dead-letters it as :owner_halt
\* with no send: dead_letter/3, one Repo call (manager.ex:1186-1192,
\* :1196-1211); the write-back skips a row that did not complete
\* (memory_writeback.ex:46-52), so that is this step's only Repo call.
MgrWriteback ==
    /\ mpc = "writeback"
    /\ IF OwnerHaltDeadLetters
       THEN /\ mpc' = "idle"
            /\ tracked' = FALSE
            /\ delivery' = "dead_letter" /\ lastError' = "named" /\ clientCause' = TRUE
            /\ UNCHANGED snd
       ELSE /\ mpc' = "handoff"
            /\ snd' = [snd EXCEPT !["mgr"] = "flying"]
            /\ UNCHANGED <<tracked, delivery, lastError, clientCause>>
    /\ UNCHANGED <<origin, runVars, mbox, mgrCrashes, wkrVars, orphans, status,
                   attempts, leased, seenVars, writes, confirmedTurn, lied>>

\* The sender answered :ok. mark_continued/2 or deliver_and_mark/2 then
\* mark_delivered/2: one Repo call, an unguarded UPDATE by id
\* (manager.ex:1143, :1148-1155, :1223, :1228-1238; repo.ex:6363-6370).
\* A dispatch that answered :ok is the one the code calls confirmed
\* (manager.ex:1091-1103).
MgrHandOffOk ==
    /\ IF MarksDelivered THEN delivery' = "delivered" ELSE UNCHANGED delivery
    /\ confirmedTurn' = (confirmedTurn \/ MgrKind = "turn")
    /\ UNCHANGED <<lastError, clientCause>>

\* The sender answered {:error, _}. A client-owned origin dead-letters with
\* the named cause (continuation_failed/3 -> dead_letter/3, manager.ex:1162-1168,
\* :1196-1211, one Repo call); every other origin leaves the row pending for
\* the worker (manager.ex:1170-1179, :1224, :1240-1243).
MgrHandOffError ==
    /\ IF origin = "client"
       THEN /\ clientCause' = TRUE
            /\ IF ClientDeadLetters
               THEN delivery' = "dead_letter" /\ lastError' = "named"
               ELSE UNCHANGED <<delivery, lastError>>
       ELSE UNCHANGED <<delivery, lastError, clientCause>>
    /\ UNCHANGED confirmedTurn

\* with_timeout returns, the Manager records the result, then drop_run
\* (manager.ex:1068, :1245-1261). The watchdog kills a sender that has not
\* answered within 60 s (text) or 15 s (dispatch); if the platform had
\* already accepted, the Manager still sees {:error, :delivery_timeout}.
MgrResolve ==
    /\ mpc = "handoff"
    /\ \/ snd["mgr"] = "landed" /\ MgrHandOffOk
       \/ /\ \/ snd["mgr"] = "landed" /\ AcceptedSendsCanTimeOut
             \/ snd["mgr"] = "flying" /\ SendsCanFail
          /\ MgrHandOffError
    /\ snd' = [snd EXCEPT !["mgr"] = "none"]
    /\ mpc' = "idle"
    /\ tracked' = FALSE
    /\ UNCHANGED <<origin, runVars, mbox, mgrCrashes, wkrVars, orphans, status,
                   attempts, leased, seenVars, writes, lied>>

\* handle_call({:cancel, run_id, :owner}) for a run absent from the runs map
\* -> cancel_untracked/3 (manager.ex:254-257, :977-992): Ledger.get, then for
\* an active local row GenServer.reply(:ok) and terminalize_and_notify/4 with
\* stranded_cancel_outcome/0 (cancelled, :1306-1308). The read and the write
\* are two Repo calls in one callback; nothing between them can change an
\* active row's status, since only this process writes status and the worker
\* never selects an active row, so they are one step here. A call is served
\* only between callbacks, and handle_continue runs before any message, so
\* the guard reads only what the Manager can see: it is idle, the run is not
\* in its maps, and the row reads active. Nothing here assumes the Run is
\* gone: CancelFinalizesDeadRuns checks it.
\* Before the fix, terminal_cancel_reply/2 answered any row it found
\* :already_terminal and changed nothing.
OwnerCancelUntracked ==
    /\ OwnerCancels
    /\ mpc = "idle" /\ ~tracked /\ status = "active"
    /\ \/ /\ CancelsStrandedRow
          /\ TerminalWrite("cancelled")
          /\ UNCHANGED lied
       \/ /\ ~CancelsStrandedRow
          /\ lied' = TRUE
          /\ TerminalWriteKeeps
    /\ UNCHANGED <<origin, runVars, mbox, mgrCrashes, wkrVars, sndVars, delivery,
                   attempts, lastError, seenVars, clientCause, confirmedTurn>>

\* Senders of kind k a Manager crash orphans: the Manager's own, plus the
\* worker's when :rest_for_one kills the worker too. A sender linked to its
\* caller dies with it; one that already landed has already been seen.
NewOrphans(k) ==
    IF SendsDieWithCaller THEN 0
    ELSE (IF snd["mgr"] = "flying" /\ MgrKind = k THEN 1 ELSE 0)
         + (IF RestForOne /\ snd["wkr"] = "flying" /\ CanLand("wkr") /\ k = "text" THEN 1 ELSE 0)

\* The Manager dies (a raise, or an exit from a Repo call past its 5 s
\* GenServer.call timeout, repo.ex:3777-3780). Harness.Supervisor is
\* :rest_for_one Manager -> RunSupervisor -> DeliveryWorker (supervisor.ex:38-44):
\* it terminates the DeliveryWorker and the RunSupervisor (whose :temporary
\* Runs die with it, run.ex:77-85, run_supervisor.ex:12, :32-34; nothing in the
\* harness traps exits), then restarts all three. The new Manager starts with
\* empty runs and run_monitors maps (manager.ex:1507-1508), and its init
\* returns {:continue, :reconcile} (manager.ex:227-230), so the supervisor
\* starts the new worker while reconciliation is still to run. The mailbox
\* is lost. A with_timeout sender is linked to its caller
\* (channel_send.ex:219-224), so a sender still in flight dies with the
\* Manager, or with the worker under :rest_for_one, before its platform call
\* or gateway cast lands; one that already landed was already seen.
MgrCrash ==
    /\ ManagerCanCrash /\ mgrCrashes < MaxManagerCrashes
    /\ mgrCrashes' = mgrCrashes + 1
    /\ mbox' = <<>>
    /\ mpc' = "reconcile"
    /\ tracked' = FALSE
    /\ orphans' = [k \in Kinds |-> orphans[k] + NewOrphans(k)]
    /\ snd' = [c \in Callers |-> IF c = "mgr" \/ RestForOne THEN "none" ELSE snd[c]]
    /\ wpc' = IF RestForOne THEN "idle" ELSE wpc
    /\ wsnap' = IF RestForOne THEN 0 ELSE wsnap
    /\ rpc' = IF RestForOne THEN "gone" ELSE rpc
    /\ runStale' = (~RestForOne /\ rpc = "running")
    /\ UNCHANGED <<origin, reported, rowVars, seenVars, ghostVars>>

-----------------------------------------------------------------------------
(* The hand-off lease and the clock *)

\* The wall clock passes next_delivery_at. @handoff_lease_ms (manager.ex:83-95)
\* outlasts the longest hand-off. Its clock starts before the terminal write
\* is served (manager.ex:1036), so the budget is the terminal write (one Repo
\* call), the write-back (at most two), the inline watchdog
\* (Delivery.deliver_timeout_ms/0, 60 s, or Continuation.dispatch_timeout_ms/0,
\* 15 s) and the mark (one), each Repo call bounded by GenServer.call's 5 s:
\* at most 80 s against the 120 s lease. So, with the clock running
\* normally, the lease does not end while the Manager is still in its
\* write-back or hand-off. This guard reads the Manager's mpc, which no
\* process in the code reads: it stands for that timing budget, which ExUnit
\* locks ("the lease outlasts the longest inline hand-off"), not TLC. After a
\* Manager crash nothing holds the lease.
LeaseEnds ==
    /\ leased
    /\ mpc \notin {"writeback", "handoff"}
    /\ leased' = FALSE
    /\ UNCHANGED <<origin, runVars, mgrVars, wkrVars, sndVars, status, delivery,
                   attempts, lastError, seenVars, ghostVars>>

\* The lease ends while the Manager is still inside its hand-off: a laptop
\* sleep or a wall-clock jump mid-send (the BEAM's timers pause, the wall
\* clock does not). A tick can then race the resumed send: the designed
\* at-least-once duplicate.
LeaseLapses ==
    /\ LeaseCanLapse
    /\ leased
    /\ mpc \in {"writeback", "handoff"}
    /\ leased' = FALSE
    /\ UNCHANGED <<origin, runVars, mgrVars, wkrVars, sndVars, status, delivery,
                   attempts, lastError, seenVars, ghostVars>>

-----------------------------------------------------------------------------
(* The Harness.DeliveryWorker process *)

WorkerCanSelect == WorkerDrainsOutbox /\ status /= "active" /\ delivery = "pending"

\* handle_info(:tick) -> run_tick/1 -> Ledger.pending_deliveries, one Repo
\* call: `delivery_status = 'pending' AND status NOT IN (active) AND
\* (next_delivery_at IS NULL OR next_delivery_at <= now)` (delivery_worker.ex:62-65,
\* :101-108; repo.ex:6452-6464). A leased row is not due yet. Then
\* process_row/3 spawns Delivery.deliver under with_timeout
\* (delivery_worker.ex:118-119, delivery.ex:280-293) and waits. Nothing claims
\* the row between the select and the send.
WkrTick ==
    /\ wpc = "idle"
    /\ WorkerCanSelect
    /\ ~leased
    /\ wpc' = "sending"
    /\ wsnap' = attempts
    /\ snd' = [snd EXCEPT !["wkr"] = "flying"]
    /\ UNCHANGED <<origin, runVars, mgrVars, orphans, rowVars, seenVars, ghostVars>>

\* handle_failure/4 (delivery_worker.ex:129-141) from the selected row's
\* attempts: dead_letter/3 (:153-158) at the cap, else reschedule/5 (:160-168),
\* which writes attempts, next_delivery_at and last_delivery_error but not
\* delivery_status. Either is one unguarded UPDATE (repo.ex:6363-6370).
WkrFailure ==
    LET tried == wsnap + 1 IN
    IF DeadLetterCap /\ tried >= MaxAttempts
    THEN /\ delivery' = "dead_letter" /\ lastError' = "worker"
         /\ UNCHANGED attempts
    ELSE /\ attempts' = Min(tried, MaxAttempts) /\ lastError' = "worker"
         /\ UNCHANGED delivery

\* process_row/3 once with_timeout returns: mark_delivered/3 on :ok
\* (delivery_worker.ex:120, :125-127), handle_failure/4 on {:error, _}.
WkrKeeps == UNCHANGED <<origin, runVars, mgrVars, orphans, status, leased, seenVars,
                        ghostVars>>

WkrResolve ==
    /\ wpc = "sending"
    /\ \/ /\ snd["wkr"] = "landed"
          /\ delivery' = "delivered"
          /\ UNCHANGED <<attempts, lastError>>
       \/ /\ \/ snd["wkr"] = "landed" /\ AcceptedSendsCanTimeOut
             \/ snd["wkr"] = "flying" /\ (SendsCanFail \/ ~CanLand("wkr"))
          /\ WkrFailure
    /\ snd' = [snd EXCEPT !["wkr"] = "none"]
    /\ wpc' = "idle"
    /\ wsnap' = 0
    /\ WkrKeeps

-----------------------------------------------------------------------------
(* Sender processes (ChannelSend.with_timeout, channel_send.ex:219-300)     *)
(*                                                                         *)
(* A caller spawns its sender "flying", linked and monitored. It becomes   *)
(* "landed" when the platform or gateway accepts. The caller then resolves *)
(* it: :ok if it landed, or {:error, _} if it was refused, killed by the   *)
(* watchdog before landing, or killed after landing                        *)
(* (AcceptedSendsCanTimeOut). If the caller dies first, the link kills a   *)
(* flying sender; with SendsDieWithCaller off it becomes an orphan that    *)
(* may still land or fail on its own.                                      *)

\* The platform accepts the text, or Gateway.ingest casts the continuation to
\* the agent queue (gateway.ex:465-468; continuation_dispatcher.ex in
\* fermix_channels, :15-20, :243-257). From here the owner has it, whatever
\* the caller hears next.
Land(c) ==
    /\ snd[c] = "flying"
    /\ CanLand(c)
    /\ snd' = [snd EXCEPT ![c] = "landed"]
    /\ Notify(SenderKind(c))
    /\ UNCHANGED <<origin, runVars, mgrVars, wkrVars, orphans, rowVars, ghostVars>>

\* A sender whose caller died still runs to the end: its send may land.
OrphanLands(k) ==
    /\ orphans[k] > 0
    /\ Notify(k)
    /\ orphans' = [orphans EXCEPT ![k] = @ - 1]
    /\ UNCHANGED <<origin, runVars, mgrVars, wkrVars, snd, rowVars, ghostVars>>

OrphanFails(k) ==
    /\ SendsCanFail
    /\ orphans[k] > 0
    /\ orphans' = [orphans EXCEPT ![k] = @ - 1]
    /\ UNCHANGED <<origin, runVars, mgrVars, wkrVars, snd, rowVars, seenVars, ghostVars>>

-----------------------------------------------------------------------------
Init ==
    /\ origin \in Origins
    /\ rpc = "running" /\ runStale = FALSE /\ reported = FALSE
    /\ mbox = <<>> /\ mpc = "idle" /\ mgrCrashes = 0 /\ tracked = TRUE
    /\ wpc = "idle" /\ wsnap = 0
    /\ snd = [c \in Callers |-> "none"]
    /\ orphans = [k \in Kinds |-> 0]
    /\ status = "active" /\ delivery = "pending" /\ attempts = 0 /\ lastError = "none"
    /\ leased = FALSE
    /\ texts = 0 /\ turns = 0
    /\ writes = 0 /\ clientCause = FALSE /\ confirmedTurn = FALSE /\ lied = FALSE

\* The legitimate end: every process has finished its work. The Run is gone,
\* the Manager is idle with an empty mailbox, the worker has nothing due and
\* no sender is still in flight. Whether the outcome reached the owner is for
\* the properties to judge, so a row left behind is reported by them rather
\* than as a deadlock. A leased pending row is not Done: its lease still ends.
Done ==
    /\ rpc = "gone"
    /\ mbox = <<>>
    /\ mpc = "idle"
    /\ wpc = "idle"
    /\ ~WorkerCanSelect
    /\ orphans = [k \in Kinds |-> 0]

Terminated == Done /\ UNCHANGED vars

MgrStep ==
    \/ MgrReport \/ MgrCleanDown \/ MgrCrashDown
    \/ MgrReconcileScan \/ MgrReconcileRow \/ MgrWriteback \/ MgrResolve

WkrStep == WkrTick \/ WkrResolve

Next ==
    \/ RunReports \/ RunCrashes
    \/ MgrStep \/ MgrCrash \/ OwnerCancelUntracked
    \/ LeaseEnds \/ LeaseLapses
    \/ WkrStep
    \/ \E c \in Callers : Land(c)
    \/ \E k \in Kinds : OrphanLands(k) \/ OrphanFails(k)
    \/ Terminated

\* Fermix drives these itself: a run ends on its host's wall clock, the
\* Manager works through its mailbox and its own watchdog, the clock moves
\* past a lease, the worker ticks on its own timer. Platforms, crashes,
\* timeouts, a lapsing lease and the owner get no fairness.
Fairness ==
    /\ WF_vars(RunReports) /\ WF_vars(MgrStep) /\ WF_vars(LeaseEnds) /\ WF_vars(WkrStep)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* ARCHITECTURE.md FermixCore.Harness: "Manager is the only writer of terminal
\* status"; manager.ex:20-23: the single terminal writer, with "the P0
\* :already_terminal guard" as "the idempotence backstop"; manager.ex:1079-1081:
\* the loser of a terminal race is dropped, "never re-deliver and never
\* re-continue". Each terminal write starts one hand-off, so this also counts
\* hand-offs.
TerminalizedOnce == writes <= 1

\* supervisor.ex:8-11: the :rest_for_one order sweeps every live Run first, "so
\* the restarted Manager's boot reconciliation only ever finds genuinely dead
\* rows". Only reconciliation writes interrupted here.
ReconcileFindsDeadRuns == status = "interrupted" => rpc = "gone"

\* manager.ex:966-972 (cancel_untracked/3): an active row missing from the
\* runs map "has no live Run, and the owner's cancel terminalizes it". Only
\* that cancel writes cancelled here, so a cancelled row's Run must be gone.
CancelFinalizesDeadRuns == status = "cancelled" => rpc = "gone"

\* manager.ex:162-170 (cancel/3): an owner cancel of an active run is :ok,
\* and :already_terminal means the run is terminal; cancel_untracked/3:
\* "Never a false 'already finished'".
CancelAnswersTruly == ~lied

\* channel_send.ex:98-105 (with_timeout/2): "The send never outlives its
\* caller, except in the few instructions between the watchdog's unlink and
\* its kill: if the caller dies mid-send, the link takes the send process
\* down with it." That exception is below this spec's step granularity (see
\* the README's assumptions).
NoOrphanedSends == \A k \in Kinds : orphans[k] = 0

\* Proposed rule: a run that has ended gets its terminal row (and with it its
\* delivery, and the release of its workspace locks and capacity slot).
EveryRunEndsTerminal == (rpc = "gone") ~> (status /= "active")

\* delivery_worker.ex:29-32: "the at-least-once / dead-letter guarantee";
\* manager.ex:1170-1171: "the durable outbox is the at-least-once path".
OutboxDrains == (status /= "active") ~> (delivery \in {"delivered", "dead_letter"})

\* Proposed rule: the owner hears each outcome once, counting a continuation
\* turn and a text alike. (A text resent after a failure is by design:
\* delivery.ex:24 prefixes every message "[run <id>]" for at-least-once dedup.)
AtMostOneNotification == texts + turns <= 1

\* manager.ex:1091-1103: on a CONFIRMED dispatch (the dispatcher answered :ok)
\* the row is marked delivered, "the agent's turn IS the notification - no
\* text push, and no double-notify while the lease holds". An unconfirmed
\* dispatch the gateway accepted is followed by the text by design (see
\* Witness_TextAfterUnconfirmedTurn), and so is a confirmed one whose lease
\* lapsed mid-hand-off (the designed lapse duplicate; a hand run in the
\* README), so the checks that assert this rule run with LeaseCanLapse = FALSE.
NoTextAfterConfirmedContinuation == ~(confirmedTurn /\ texts >= 1)

\* manager.ex:1157-1161: leaving a client-owned row pending would let the
\* worker "overwrite the real reason ... with the useless
\* unsupported_delivery_platform word"; manager.ex:1194-1195: "the name goes on
\* the row (last_delivery_error)".
NamedCauseKept == (clientCause /\ delivery = "dead_letter") => lastError = "named"

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* The designed at-least-once resend: an inline text times out after the
\* platform accepted it, so the worker sends it again.
Witness_TextResent == texts < 2

\* The designed at-least-once notification after a dispatch the Manager
\* could not confirm (manager.ex:1091-1103, continuation.ex:148-152, design
\* §23.2): the gateway accepted the continuation, but the Manager saw a
\* watchdog expiry or died before it read the answer, so the row stayed
\* pending and the worker's text follows the agent's turn.
Witness_TextAfterUnconfirmedTurn == ~(turns >= 1 /\ texts >= 1)

\* The documented limitation (manager.ex:40-44): the Run reported its end,
\* but a restart took the report with the Manager's mailbox, so boot
\* reconciliation records the finished run as interrupted.
Witness_ReportLostOnRestart == ~(reported /\ status = "interrupted")

\* The designed duplicate after a lapsed lease: the wall clock passed the
\* lease while the Manager was still inside its hand-off, so a tick sent the
\* outcome beside the Manager's own attempt.
Witness_LapsedLeaseDuplicate == texts + turns <= 1

=============================================================================
