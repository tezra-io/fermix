-------------------------- MODULE HarnessDelivery --------------------------
(***************************************************************************)
(* How ONE local coding-harness run's outcome reaches the owner: the Run   *)
(* reporting its end (or crashing), the Harness.Manager writing the one    *)
(* terminal ledger row, running the memory write-back and handing the      *)
(* outcome off (a continuation turn, an inline text, or a dead letter),    *)
(* the DeliveryWorker's 30 s outbox tick, a Manager crash with its         *)
(* :rest_for_one restart and boot reconciliation, and sends that fail or   *)
(* time out after they landed. The Manager can crash at every step,        *)
(* including between the terminal write and the write-back, and during    *)
(* the write-back itself (a second Repo call).                            *)
(*                                                                         *)
(* Not modelled:                                                           *)
(* - admission and its refusals (the row starts admitted, the Run started) *)
(* - the cloud rail (submit, polling, stop_tracking)                       *)
(* - owner cancel and /stop: for a framework origin they only choose the   *)
(*   "text" hand-off; for a client-owned origin a cancelled, tracking-     *)
(*   stopped or depth-capped row, or one with no dispatcher, is dead-      *)
(*   lettered with no send at all (manager.ex:1046-1050, :1057-1061,       *)
(*   :1109-1111). HARNESS-1's overwrite reaches that arm too.              *)
(* - the continuation depth cap itself (a pure per-row rule; ExUnit)       *)
(* - delivery_mode "none" and "local", which succeed without a channel     *)
(*   send (delivery.ex:101-103)                                            *)
(* - advisory notices and telemetry                                        *)
(* - the worker's backoff clock and max-age rule (a rescheduled row is     *)
(*   simply due again at a later tick)                                     *)
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
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/manager.ex @ 8abbc6048a77
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/delivery_worker.ex @ fb5f4bacffba
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/continuation.ex @ 116b637303d6
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/continuation_dispatcher.ex @ 92d85f69b270
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/delivery.ex @ 5227fb48817f
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/ledger.ex @ 3e2769ddc399
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/memory_writeback.ex @ d85eb40385ad
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/supervisor.ex @ f4967c985e88
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/run_supervisor.ex @ 434b12f3182b
\* SOURCE: apps/fermix_core/lib/fermix_core/harness/run.ex @ 788c70041804
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#call,admit_harness_run,admit_harness_run_tx,admit_harness_run_in_tx,ensure_harness_capacity,insert_harness_run_row,terminalize_harness_run,terminalize_harness_run_row,update_harness_run,update_harness_run_row,pending_harness_deliveries,fetch_pending_harness_deliveries,active_harness_runs,fetch_active_harness_runs,normalize_harness_run_attrs,upsert_memory,@harness_runs_schema_sql,@harness_active_status_sql @ 025ab35639d2
\* SOURCE: apps/fermix_core/lib/fermix_core/delivery/channel_send.ex @ f3d4fbac434a
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
                             \* accepted: with_timeout cannot tell (channel_send.ex:200-219)
    TerminalWriteCanFail,    \* the terminal UPDATE returns an error (SQLite busy, I/O, full)
    \* Timing idealisation: TRUE is the real code. FALSE restricts the
    \* scheduler to isolate other causes; it lets the worker's step read the
    \* Manager's mpc, which the real worker cannot see.
    TicksDuringHandOff,      \* the worker's 30 s tick can fire while the Manager is
                             \* between its terminal write and its delivery mark
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* a check switches one off to show a property rests on it.
    CleanDownDropsOnly,    \* a :normal/:shutdown DOWN only drops the monitor (manager.ex:958)
    IgnoresUntrackedRun,   \* every terminalization outcome ends in drop_run (manager.ex:997,
                           \* :1013, :1017, :1168-1184), and a report or DOWN for a run no
                           \* longer tracked is ignored (:938-940, :956-957, :964-965)
    GuardedTerminalUpdate, \* the terminal UPDATE only matches an active row (repo.ex:6045-6050);
                           \* :already_terminal is dropped (manager.ex:973, :1008-1013)
    RestForOne,            \* a Manager crash also restarts RunSupervisor and DeliveryWorker
                           \* (supervisor.ex:38-44), killing every live Run first
    ReconcilesAtBoot,      \* the restarted Manager finalizes active rows interrupted
                           \* (manager.ex:196-197, :1260-1270)
    CrashDownTerminalizes, \* an abnormal Run DOWN terminalizes failed/run_crashed
                           \* (manager.ex:955-968)
    MarksDelivered,        \* a successful hand-off marks the row delivered
                           \* (manager.ex:1066, :1071-1078, :1146, :1151-1161)
    ClientDeadLetters,     \* a failed client-owned dispatch dead-letters the row with its
                           \* named cause (manager.ex:1085-1091, :1119-1134)
    WorkerDrainsOutbox,    \* the worker selects terminal rows still pending
                           \* (delivery_worker.ex:96-118, repo.ex:6168-6180)
    DeadLetterCap          \* the worker dead-letters at MaxAttempts (delivery_worker.ex:124-136)

VARIABLES
    origin,      \* SQLite row: origin_kind / client_origin, frozen at admission
    rpc,         \* the Harness.Run process: "running" or "gone"
    runStale,    \* Run state: its :manager pid belongs to a dead Manager
    reported,    \* history: the Run sent its terminal report (run.ex:634)
    mbox,        \* Manager mailbox: the Run's report and DOWN messages, in order
    mpc,         \* Manager: which callback it is in (see MgrStates)
    mgrCrashes,  \* environment bound: Manager crashes so far
    tracked,     \* Manager state: the run is in its runs / run_monitors maps (manager.ex:314-324)
    wpc,         \* DeliveryWorker: "idle" between ticks, "sending" inside process_row
    wsnap,       \* DeliveryWorker: delivery_attempts in the row it selected
    snd,         \* snd[c]: the with_timeout sender process caller c is waiting on
    orphans,     \* orphans[k]: senders of kind k still in flight whose caller died
    status,      \* SQLite row: "active" or the terminal status written
    delivery,    \* SQLite row: delivery_status
    attempts,    \* SQLite row: delivery_attempts
    lastError,   \* SQLite row: last_delivery_error: "none", "named" (Manager) or "worker"
    texts,       \* visible to the owner: text messages received for this run (capped at 2)
    turns,       \* visible to the owner: continuation turns ingested for this run (capped at 2)
    writes,      \* history: successful terminal writes (capped at 2)
    clientCause  \* history: the Manager saw a client-owned dispatch fail (a named cause)

\* History variables (reported, writes, clientCause) are read by no process:
\* they record what already happened so the properties can refer to the past.
runVars   == <<rpc, runStale, reported>>
mgrVars   == <<mbox, mpc, mgrCrashes, tracked>>
wkrVars   == <<wpc, wsnap>>
sndVars   == <<snd, orphans>>
rowVars   == <<status, delivery, attempts, lastError>>
seenVars  == <<texts, turns>>
ghostVars == <<writes, clientCause>>
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
    /\ status \in {"active", "result", "crashed", "interrupted"}
    /\ delivery \in {"pending", "delivered", "dead_letter"}
    /\ attempts \in 0..MaxAttempts
    /\ lastError \in {"none", "named", "worker"}
    /\ texts \in 0..2 /\ turns \in 0..2 /\ writes \in 0..2
    /\ clientCause \in BOOLEAN

-----------------------------------------------------------------------------
Min(a, b) == IF a < b THEN a ELSE b
Sat(n)    == Min(n, 2)

\* What the Manager's hand-off sends for this origin (manager.ex:1031-1036):
\* a chat or client-owned origin dispatches a continuation turn, the rest a text.
KindOf(o) == IF o = "text" THEN "text" ELSE "turn"
SenderKind(c) == IF c = "mgr" THEN KindOf(origin) ELSE "text"

\* The worker's text to a client-owned origin is refused inside its sender
\* before anything is dispatched: ChannelSend has no adapter for "acp"
\* (config.exs:117-125), so resolve_adapter answers
\* {:error, {:unsupported_delivery_platform, "acp"}} (channel_send.ex:237-243).
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
\* manager.ex:315). A report to a dead Manager's pid is dropped.
RunReports ==
    /\ rpc = "running"
    /\ rpc' = "gone"
    /\ reported' = TRUE
    /\ mbox' = IF runStale THEN mbox ELSE mbox \o <<"report", "down_normal">>
    /\ UNCHANGED <<origin, runStale, mpc, mgrCrashes, tracked, wkrVars, sndVars,
                   rowVars, seenVars, ghostVars>>

\* The Run raises before its report: only an abnormal DOWN reaches the
\* Manager (manager.ex:250-252). After report_and_stop it cannot crash:
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
(*   idle --report/DOWN--> [terminal write] --ok--> writeback --> handoff  *)
(*     ^                        | error, :already_terminal         |       *)
(*     +------------------------+----------------------------------+       *)
(*   crash --> reconcile --> reconciling --> [terminal write] ...          *)

\* The Manager acts on a report or DOWN only for a run it still tracks,
\* unless that layer is switched off.
Knows == tracked \/ ~IgnoresUntrackedRun

\* terminalize_and_notify/4 (manager.ex:970-976): Ledger.terminalize ->
\* Repo terminalize_harness_run_row/4 (ledger.ex:69-76, repo.ex:6038-6053),
\* ONE Repo call running `UPDATE ... WHERE id = ? AND status IN (active)`. It
\* writes status, the outcome's ledger fields and completed_at; it leaves
\* delivery_status 'pending' and next_delivery_at NULL as admission wrote
\* them (manager.ex:356-386, repo.ex:470-473, :6486-6488), so the row is due
\* for the worker the moment this call returns.
\* The call has three outcomes, one per disjunct: the Repo returns an error;
\* the UPDATE changes the row; or the guard finds the row already terminal.
TerminalWrite(st) ==
    \/ /\ TerminalWriteCanFail
       \* after_terminalize_error/4 for a local run: log and drop_run
       \* (manager.ex:984-991, :1015-1018). The row stays active.
       /\ mpc' = "idle"
       /\ tracked' = FALSE
       /\ UNCHANGED <<status, writes>>
    \/ /\ status = "active" \/ ~GuardedTerminalUpdate
       \* {:ok, row} -> post_terminal/5 (manager.ex:972, :993-998).
       /\ status' = st
       /\ writes' = Sat(writes + 1)
       /\ mpc' = "writeback"
       /\ UNCHANGED tracked
    \/ /\ status /= "active" /\ GuardedTerminalUpdate
       \* {:error, :already_terminal} -> resolve_after_race: drop, never
       \* re-deliver or re-continue (manager.ex:973, :1008-1013).
       /\ mpc' = "idle"
       /\ tracked' = FALSE
       /\ UNCHANGED <<status, writes>>

TerminalWriteKeeps == UNCHANGED <<mpc, status, writes, tracked>>

MgrKeeps == UNCHANGED <<origin, runVars, mgrCrashes, wkrVars, sndVars, delivery,
                        attempts, lastError, seenVars, clientCause>>

\* handle_info({:harness_report_terminal, ...}) -> finalize_reported/4
\* (manager.ex:246-247, :937-945); an untracked run's report is only logged
\* (log_unknown_report, :947-953).
MgrReport ==
    /\ mpc = "idle" /\ mbox /= <<>> /\ Head(mbox) = "report"
    /\ mbox' = Tail(mbox)
    /\ IF Knows THEN TerminalWrite("result") ELSE TerminalWriteKeeps
    /\ MgrKeeps

\* handle_info({:DOWN, ...}) -> handle_down/3 (manager.ex:250-251, :955-961):
\* a DOWN for an untracked run finds no monitor (:956-957); a :normal or
\* :shutdown DOWN only drops the monitor (:958).
MgrCleanDown ==
    /\ mpc = "idle" /\ mbox /= <<>> /\ Head(mbox) = "down_normal"
    /\ mbox' = Tail(mbox)
    /\ IF Knows /\ ~CleanDownDropsOnly
       THEN TerminalWrite("crashed")
       ELSE TerminalWriteKeeps
    /\ MgrKeeps

\* An abnormal DOWN -> mark_run_crashed/2 -> terminalize failed/run_crashed
\* (manager.ex:959, :963-968, :1213-1220).
MgrCrashDown ==
    /\ mpc = "idle" /\ mbox /= <<>> /\ Head(mbox) = "down_crash"
    /\ mbox' = Tail(mbox)
    /\ IF Knows /\ CrashDownTerminalizes
       THEN TerminalWrite("crashed")
       ELSE TerminalWriteKeeps
    /\ MgrKeeps

\* handle_continue(:reconcile) -> reconcile/1 -> Ledger.active_runs, one Repo
\* call (manager.ex:196-197, :1260-1265; repo.ex:6152-6166).
MgrReconcileScan ==
    /\ mpc = "reconcile"
    /\ mpc' = IF ReconcilesAtBoot /\ status = "active" THEN "reconciling" ELSE "idle"
    /\ UNCHANGED <<origin, runVars, mbox, mgrCrashes, tracked, wkrVars, sndVars,
                   rowVars, seenVars, ghostVars>>

\* reconcile_row/2 for a local starting/running row: terminalize it
\* interrupted, then the same post_terminal (manager.ex:1267-1270, :1222-1224).
MgrReconcileRow ==
    /\ mpc = "reconciling"
    /\ TerminalWrite("interrupted")
    /\ UNCHANGED mbox
    /\ MgrKeeps

\* The rest of post_terminal/5 (manager.ex:994-996): run_complete/run_error
\* telemetry, then MemoryWriteback.write, which for a completed run is a
\* second Repo call, Repo.upsert_memory (memory_writeback.ex:46-52, :159);
\* then hand_off_outcome spawns the text send or the continuation dispatch
\* under ChannelSend.with_timeout (delivery.ex:273-286, continuation.ex:147-159)
\* and waits. The Manager can crash before this step (no sender exists yet).
MgrWriteback ==
    /\ mpc = "writeback"
    /\ mpc' = "handoff"
    /\ snd' = [snd EXCEPT !["mgr"] = "flying"]
    /\ UNCHANGED <<origin, runVars, mbox, mgrCrashes, tracked, wkrVars, orphans,
                   rowVars, seenVars, ghostVars>>

\* The sender answered :ok. mark_continued/2 or deliver_and_mark/2 then
\* mark_delivered/2: one Repo call, an unguarded UPDATE by id
\* (manager.ex:1066, :1071-1078, :1146, :1151-1161; repo.ex:6079-6086).
MgrHandOffOk ==
    /\ IF MarksDelivered THEN delivery' = "delivered" ELSE UNCHANGED delivery
    /\ UNCHANGED <<lastError, clientCause>>

\* The sender answered {:error, _}. A client-owned origin dead-letters with
\* the named cause (continuation_failed/3 -> dead_letter/3, manager.ex:1085-1091,
\* :1119-1134, one Repo call); every other origin leaves the row pending for
\* the worker (manager.ex:1093-1102, :1147, :1163-1166).
MgrHandOffError ==
    IF origin = "client"
    THEN /\ clientCause' = TRUE
         /\ IF ClientDeadLetters
            THEN delivery' = "dead_letter" /\ lastError' = "named"
            ELSE UNCHANGED <<delivery, lastError>>
    ELSE UNCHANGED <<delivery, lastError, clientCause>>

\* with_timeout returns, the Manager records the result, then drop_run
\* (manager.ex:997, :1168-1184). The watchdog kills a sender that has not
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
                   attempts, seenVars, writes>>

\* Senders of kind k a Manager crash orphans: the Manager's own, plus the
\* worker's when :rest_for_one kills the worker too.
NewOrphans(k) ==
    (IF snd["mgr"] = "flying" /\ KindOf(origin) = k THEN 1 ELSE 0)
    + (IF RestForOne /\ snd["wkr"] = "flying" /\ CanLand("wkr") /\ k = "text" THEN 1 ELSE 0)

\* The Manager dies (a raise, or an exit from a Repo call past its 5 s
\* GenServer.call timeout, repo.ex:3623-3626). Harness.Supervisor is
\* :rest_for_one Manager -> RunSupervisor -> DeliveryWorker (supervisor.ex:38-44):
\* it terminates the DeliveryWorker and the RunSupervisor (whose :temporary
\* Runs die with it, run.ex:77-85, run_supervisor.ex:12, :32-34; nothing in the
\* harness traps exits), then restarts all three. The new Manager starts with
\* empty runs and run_monitors maps (manager.ex:1423-1424), and its init
\* returns {:continue, :reconcile} (manager.ex:188-191), so the supervisor
\* starts the new worker while reconciliation is still to run. The mailbox
\* is lost. A with_timeout sender is spawn_monitor'ed, not linked
\* (channel_send.ex:205), so one still in flight outlives its caller.
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
(* The Harness.DeliveryWorker process *)

WorkerCanSelect == WorkerDrainsOutbox /\ status /= "active" /\ delivery = "pending"

\* handle_info(:tick) -> run_tick/1 -> Ledger.pending_deliveries, one Repo
\* call: `delivery_status = 'pending' AND status NOT IN (active) AND
\* (next_delivery_at IS NULL OR next_delivery_at <= now)` (delivery_worker.ex:57-60,
\* :96-103; repo.ex:6168-6180). Then process_row/3 spawns Delivery.deliver
\* under with_timeout (delivery_worker.ex:113-114, delivery.ex:273-286) and
\* waits. Nothing claims the row between the select and the send.
\* The mpc test is the timing idealisation only (see TicksDuringHandOff).
WkrTick ==
    /\ wpc = "idle"
    /\ WorkerCanSelect
    /\ TicksDuringHandOff \/ mpc \notin {"writeback", "handoff"}
    /\ wpc' = "sending"
    /\ wsnap' = attempts
    /\ snd' = [snd EXCEPT !["wkr"] = "flying"]
    /\ UNCHANGED <<origin, runVars, mgrVars, orphans, rowVars, seenVars, ghostVars>>

\* handle_failure/4 (delivery_worker.ex:124-136) from the selected row's
\* attempts: dead_letter/3 (:148-153) at the cap, else reschedule/5 (:155-163),
\* which writes attempts, next_delivery_at and last_delivery_error but not
\* delivery_status. Either is one unguarded UPDATE (repo.ex:6079-6086).
WkrFailure ==
    LET tried == wsnap + 1 IN
    IF DeadLetterCap /\ tried >= MaxAttempts
    THEN /\ delivery' = "dead_letter" /\ lastError' = "worker"
         /\ UNCHANGED attempts
    ELSE /\ attempts' = Min(tried, MaxAttempts) /\ lastError' = "worker"
         /\ UNCHANGED delivery

\* process_row/3 once with_timeout returns: mark_delivered/3 on :ok
\* (delivery_worker.ex:115, :120-122), handle_failure/4 on {:error, _}.
WkrKeeps == UNCHANGED <<origin, runVars, mgrVars, orphans, status, seenVars, ghostVars>>

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
(* Sender processes (ChannelSend.with_timeout, channel_send.ex:200-219)     *)
(*                                                                         *)
(* A caller spawns its sender "flying". It becomes "landed" when the       *)
(* platform or gateway accepts. The caller then resolves it: :ok if it     *)
(* landed, or {:error, _} if it was refused, killed by the watchdog before *)
(* landing, or killed after landing (AcceptedSendsCanTimeOut). If the      *)
(* caller dies first, a flying sender becomes an orphan that may still     *)
(* land or fail on its own.                                                *)

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
    /\ texts = 0 /\ turns = 0
    /\ writes = 0 /\ clientCause = FALSE

\* The legitimate end: every process has finished its work. The Run is gone,
\* the Manager is idle with an empty mailbox, the worker has nothing due and
\* no sender is still in flight. Whether the outcome reached the owner is for
\* the properties to judge, so a row left behind is reported by them rather
\* than as a deadlock.
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
    \/ MgrStep \/ MgrCrash
    \/ WkrStep
    \/ \E c \in Callers : Land(c)
    \/ \E k \in Kinds : OrphanLands(k) \/ OrphanFails(k)
    \/ Terminated

\* Fermix drives these itself: a run ends on its host's wall clock, the
\* Manager works through its mailbox and its own watchdog, the worker ticks
\* on its own timer. Platforms, crashes and timeouts get no fairness.
Fairness == WF_vars(RunReports) /\ WF_vars(MgrStep) /\ WF_vars(WkrStep)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* ARCHITECTURE.md FermixCore.Harness: "Manager is the only writer of terminal
\* status"; manager.ex:20-23: the single terminal writer, with "the P0
\* :already_terminal guard" as "the idempotence backstop"; manager.ex:1008-1010:
\* the loser of a terminal race is dropped, "never re-deliver and never
\* re-continue". Each terminal write starts one hand-off, so this also counts
\* hand-offs.
TerminalizedOnce == writes <= 1

\* supervisor.ex:8-11: the :rest_for_one order sweeps every live Run first, "so
\* the restarted Manager's boot reconciliation only ever finds genuinely dead
\* rows". Only reconciliation writes interrupted here.
ReconcileFindsDeadRuns == status = "interrupted" => rpc = "gone"

\* Proposed rule: a run that has ended gets its terminal row (and with it its
\* delivery, and the release of its workspace locks and capacity slot).
EveryRunEndsTerminal == (rpc = "gone") ~> (status /= "active")

\* delivery_worker.ex:24-27: "the at-least-once / dead-letter guarantee";
\* manager.ex:1093-1094: "the durable outbox is the at-least-once path".
OutboxDrains == (status /= "active") ~> (delivery \in {"delivered", "dead_letter"})

\* Proposed rule: the owner hears each outcome once, counting a continuation
\* turn and a text alike. (A text resent after a failure is by design:
\* delivery.ex:24 prefixes every message "[run <id>]" for at-least-once dedup.)
AtMostOneNotification == texts + turns <= 1

\* manager.ex:1021-1023: on a successful dispatch the row is marked delivered,
\* "the agent's turn IS the notification - no text push, no double-notify".
NoTextAfterContinuation == ~(turns >= 1 /\ texts >= 1)

\* manager.ex:1080-1084: leaving a client-owned row pending would let the
\* worker "overwrite the real reason ... with the useless
\* unsupported_delivery_platform word"; manager.ex:1117-1118: "the name goes on
\* the row (last_delivery_error)".
NamedCauseKept == (clientCause /\ delivery = "dead_letter") => lastError = "named"

\* Proposed rule: a run that reported its outcome is recorded with that
\* outcome, not as interrupted or crashed.
ReportedResultKept == reported => status \in {"active", "result"}

-----------------------------------------------------------------------------
(* WITNESS: violated when its scenario is reachable. *)

\* The designed at-least-once resend: an inline text times out after the
\* platform accepted it, so the worker sends it again.
Witness_TextResent == texts < 2

=============================================================================
