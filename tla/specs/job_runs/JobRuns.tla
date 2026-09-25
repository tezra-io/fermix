----------------------------- MODULE JobRuns -----------------------------
(***************************************************************************)
(* FermixCore.Jobs for ONE recurring job: the Scheduler's due tick and its  *)
(* atomic claim, one Runner per run (a :temporary GenServer), the settle    *)
(* that writes a run's final row and releases its job in one transaction,  *)
(* the delivery of the run's final text through a watchdog-bounded send    *)
(* helper, the Scheduler's monitors and its reconciliation pass (at init   *)
(* and every 60 s) over every unsettled run, a Runner crash, a             *)
(* Scheduler-only crash, a daemon crash followed by boot reconciliation,  *)
(* and the owner's pause, resume, edit and "run now".                      *)
(*                                                                         *)
(* Time: `now` counts the fire times that have passed and `nextRun` is the *)
(* job row's next_run_at, as the index of a fire time. The job is due when *)
(* nextRun <= now. A claim or a resume sets next_run_at to the next future *)
(* occurrence (now + 1).                                                   *)
(*                                                                         *)
(* Not modelled: the AgentLoop and its own watchdog and transient retry    *)
(* (one "loop" step that ends in text, [SILENT] or an error); media sends; *)
(* other jobs; one-shot ("once") jobs, expiry, an unparseable schedule and *)
(* the stale-skip of a due time older than the freshness window; removal; *)
(* SQLite busy or errors (every Repo call succeeds unless its caller       *)
(* dies); the admission ceiling (four runs; one job never has more than    *)
(* two runner processes, so the ceiling's :busy never happens);            *)
(* delivery_mode "none"/"local" (they behave like a [SILENT] result: final *)
(* at once); memory-source rows, telemetry, the start-up stagger and the   *)
(* network-readiness wait. An owner edit is modelled as one that touches   *)
(* none of the modelled columns (a task or delivery edit).                 *)
(*                                                                         *)
(* Late writes: a process that dies waiting on a Repo call (a 5 s          *)
(* GenServer.call timeout, repo.ex:3777-3780) does not cancel the call;    *)
(* the write still lands. So a crash at a Repo write comes in two kinds:   *)
(* the write lands late, or it never lands (a kill). The late kind is      *)
(* modelled where no later crash point stands for it: the runner's final   *)
(* write (RunnerCrashLate) and the reaper's write (SchedulerCrashLate).    *)
(* Every later reader queues its own call after the late one, so the late  *)
(* write lands in the crash step itself.                                   *)
(*                                                                         *)
(* Folded steps (each fold is argued where it happens):                    *)
(*  - the output artifact file write joins the Repo write after it;        *)
(*  - the memory-source get + upsert join the step before them (the        *)
(*    memory write after a success, the settle after a failure);           *)
(*  - resume's read joins its write; "run now"'s lookup joins its claim;   *)
(*  - the reaper's get_job_run and its write are one step;                 *)
(*  - starting a runner and monitoring it are one step, and so are         *)
(*    reading the live runners and monitoring the ones adopted;            *)
(*  - a runner's normal exit also pops its monitor (DOWN :normal).         *)
(*                                                                         *)
(* Run ids are reused once a run is fully finished, so two ids model an    *)
(* unbounded run history. A daemon crash also stands for a crash of        *)
(* Memory.Repo, of the RunnerSupervisor or of any child started between    *)
(* them: under :rest_for_one each restarts the RunnerSupervisor with its   *)
(* linked runners and the Scheduler (application.ex). With the send helper *)
(* linked to its caller (REMIND-2, channel_send.ex:219-224), one process   *)
(* survives such a restart unlinked: the AgentLoop (spawn_monitor,         *)
(* runner.ex:977). The fold kills it too; the README's JOB-8 records the   *)
(* second execution that hides. Process-local values a step no longer      *)
(* needs are cleared, so that dead values do not multiply the states.      *)
(*                                                                         *)
(* Runner steps (pc[r]), each named after the action that takes it. With   *)
(* AtomicSettle (the real code):                                           *)
(*   off -Start-> start -MarkRunning-> loop -Loop-> complete | fail        *)
(*   complete -Settle-> memo -Memory-> await (a pending send) | mark       *)
(*   fail -Settle-> await                                                  *)
(* Without it (the code before the fix), the split finish:                 *)
(*   complete -MarkCompleted-> memo -Memory-> finread                      *)
(*   fail -MarkFailed-> finread -FinRead-> finwrite -FinWrite-> await|mark *)
(* Then await -GotResult or Watchdog-> mark -MarkDelivery-> gone, and      *)
(*   start, complete, memo, fail, finread, finwrite, mark -RunnerCrash->   *)
(*   gone; complete, fail -RunnerCrashLate-> gone                          *)
(* Scheduler steps (sPc), from idle:                                       *)
(*   idle -DueTimerFires-> scan    idle -ReconcileFires-> r_rows           *)
(*   idle -JobChanged-> arm        idle -HandleDown-> r_mark               *)
(*   idle -ManualRun-> start | arm                                         *)
(*   r_rows -ReconcileRows-> r_live -ReconcileLive-> r_mark | reapReturn   *)
(*   r_mark -ReapRun-> (next orphan or reapReturn), or r_read without      *)
(*   AtomicSettle: r_read -ReapReadJob-> r_write -ReapWriteJob-> (next     *)
(*   orphan or reapReturn)                                                 *)
(*   scan -Scan-> claim | arm   claim -Claim-> start | arm                 *)
(*   start -Start-> arm         arm -Arm-> idle                            *)
(* reapReturn is where the Scheduler goes once its reaping is done: "arm"  *)
(* after init, "scan" in the 60 s tick, "idle" after a DOWN.               *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/scheduler.ex @ e401632559f7
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/runner.ex @ 16741b5f20c2
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/runner_supervisor.ex @ 6a21dfe6cfad
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/delivery.ex @ 4eb42c517b57
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/registry.ex @ 2bdc53628bcc
\* SOURCE: apps/fermix_core/lib/fermix_core/delivery/channel_send.ex @ 380824457212
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#call,claim_due_job,claim_job_now,claim_due_job_tx,claim_in_tx,claim_job_now_tx,transact_claim,fetch_claimable_due_job,finish_job_claim,rollback_job_claim,upsert_scheduled_job_row,upsert_job_run_row,ensure_no_active_job_run,fetch_claimable_job,settle_job_run,settle_job_run_tx,settle_job_run_in_tx,ensure_job_run_active,release_settled_job,finish_job_settle,rollback_job_settle,unsettled_job_runs,fetch_unsettled_job_runs,@unsettled_job_runs_sql,update_scheduled_job_fields,update_scheduled_job_fields_row,scheduled_job_field_assignments!,scheduled_job_field_assignment!,@owner_text_fields,due_scheduled_jobs,fetch_due_scheduled_jobs,next_scheduled_job,fetch_next_scheduled_job,upsert_job_run,upsert_scheduled_job,get_job_run,get_scheduled_job,upsert_memory @ 94ec90ea322b
\* SOURCE: apps/fermix_core/lib/fermix_core/application.ex#start_supervision_tree,jobs_scheduler_opts @ 06fbd1afd4cc
EXTENDS Naturals, FiniteSets

CONSTANTS
    \* Bounds.
    NumRuns,            \* run ids, e.g. 2 (reused once a run is fully finished)
    Fires,              \* fire times the clock passes through, e.g. 2
    SendAttempts,       \* ChannelSend attempts per delivery (the code uses 3)
    OwnerMoves,         \* pause/resume requests the owner may make
    OwnerEdits,         \* update_job requests the owner may make
    ManualRuns,         \* "run now" requests the owner may make
    \* Environment switches: what may happen.
    DaemonCanCrash,     \* the daemon dies once (every process) and boots again
    SchedulerCrashes,   \* how many times the Scheduler alone may die, e.g. on a 5 s
                        \* GenServer.call timeout to the Repo (repo.ex:3777-3780)
    RunnerCanCrash,     \* a runner dies at one of its Repo calls (a timeout, a failed match)
    LoopCanFail,        \* the AgentLoop ends in an error or a timeout
    PlatformCanFail,    \* a send fails: no connection, or an error after the platform took it
    ResponsesCanStall,  \* the platform takes a message and its answer never arrives in time;
                        \* with DeliveryWatchdog off the wait is unbounded (the adapters'
                        \* own HTTP timeouts are outside the sources)
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by the checks that show a property needs it.
    AtomicRaceStop,           \* the claim refuses while a run is queued/running (repo.ex:5771, :5824-5842)
    RetriesOnlyUnsent,        \* a send is retried only when it never reached the platform (channel_send.ex:140-143, :194-202);
                              \* the mechanism for platforms that do not dedupe on the run's proactive_key
    ReconcilesRuns,           \* init and every 60 s reap orphaned runs, adopt live runners (scheduler.ex:168, :197-273)
    CrashFailsPendingDelivery,\* a dead runner's pending delivery is marked failed, whatever the run's
                              \* status (scheduler.ex:721-723, :742-755)
    DeliveryWatchdog,         \* the runner stops waiting for a send after delivery_timeout_ms (channel_send.ex:219-241)
    AtomicSettle,             \* a run's final row and its job's release are one transaction, for the
                              \* runner and the reaper alike (repo.ex:2263, :5859-5928)
    ReconcilesPending,        \* the reconcile pass also reads runs whose delivery is still pending
                              \* (unsettled_job_runs, repo.ex:2272-2305, scheduler.ex:233)
    RefusalBacksOff,          \* a due claim refused as :already_running is backpressure: the re-arm
                              \* floors at the 5 s backoff (scheduler.ex:451-455, :864-870)
    OwnerWritesColumns        \* pause, resume and update_job write only the columns they own
                              \* (registry.ex:93-116; repo.ex:2206, :6071-6078, :6955-6996)

Runs == 1..NumRuns

VARIABLES
    \* --- SQLite rows (survive every crash) ---
    jobEnabled,  \* scheduled_jobs.enabled
    jobState,    \* scheduled_jobs.state: "scheduled" | "running" | "paused"
    nextRun,     \* scheduled_jobs.next_run_at, as a fire-time index
    runStatus,   \* runStatus[r]: job_runs.status ("absent" = no row for this id yet)
    delivery,    \* delivery[r]: job_runs.delivery_status; "unset" is the "none" the claim
                 \* writes before a result exists (scheduler.ex:632), kept apart from the
                 \* final "none" of delivery_mode "none" (modelled as "skipped")
    \* --- the environment ---
    now,         \* fire times that have passed (the wall clock)
    \* --- each Runner process (process-local, per run) ---
    pc,          \* pc[r]: where the runner of r is; "off" = never started, "gone" = dead
    resp,        \* resp[r]: the AgentLoop's final text: "text" or "silent" ([SILENT])
    finSnap,     \* finSnap[r]: the job row the split finish read (AtomicSettle off only)
    outcome,     \* outcome[r]: the delivery result the runner will record
    \* --- the delivery helper each runner spawns (channel_send.ex:223-224) ---
    helper,      \* helper[r]: "none" | "sending" | "accepted" (answer pending) | "ok" | "err"
    tries,       \* tries[r]: failed send attempts so far
    \* --- the chat platform (what the user sees) ---
    delivered,   \* delivered[r]: copies of r's final text the platform took
    \* --- the Scheduler GenServer (state and mailbox, lost when it dies) ---
    sPc,         \* where the Scheduler is inside its current callback
    reapReturn,  \* where it goes once its reaping is done: "arm" | "scan" | "idle"
    monitors,    \* runs whose runner it monitors (run_monitors)
    downs,       \* runs whose crash DOWN waits in its mailbox
    changed,     \* a :job_changed cast waits in its mailbox
    dueTimer,    \* its due timer: "none" | "zero" (0 ms) | "later" (at next_run_at)
                 \* | "backoff" (no sooner than 5 s)
    refused,     \* this callback's claim returned :already_running
    sRun,        \* the run this callback is starting or reaping (0 = none)
    activeSnap,  \* the unsettled rows its reconcile scan read
    reapQ,       \* runs its reconcile pass still has to reap
    sSnap,       \* the job row its split reaper read (AtomicSettle off only)
    \* --- the owner (through the pause_job / resume_job / update_job / run_job_now tools) ---
    oPc,         \* "idle" | "pausing" (a split pause read the row) | "editing" (an edit read it)
    oSnap,       \* the job row that pause or edit read
    intent,      \* the owner's last pause/resume, as acknowledged to them
    movesLeft,   \* pause/resume requests left
    editsLeft,   \* update_job requests left
    manualLeft,  \* "run now" requests left
    \* --- bookkeeping ---
    daemonCrashed, \* the daemon has died (at most once)
    schedCrashes   \* times the Scheduler alone has died

jobVars    == <<jobEnabled, jobState, nextRun>>
rowVars    == <<runStatus, delivery>>
runnerVars == <<pc, resp, finSnap, outcome>>
helperVars == <<helper, tries, delivered>>
schedVars  == <<sPc, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
               activeSnap, reapQ, sSnap>>
ownerVars  == <<oPc, oSnap, intent, movesLeft, editsLeft, manualLeft>>
envVars    == <<now, daemonCrashed, schedCrashes>>
vars == <<jobVars, rowVars, runnerVars, helperVars, schedVars, ownerVars, envVars>>

-----------------------------------------------------------------------------
PcStates == {"off", "start", "loop", "complete", "memo", "fail",
             "finread", "finwrite", "await", "mark", "gone"}
SchedStates == {"idle", "r_rows", "r_live", "r_mark", "r_read", "r_write",
                "scan", "claim", "start", "arm"}
Snaps == [en : BOOLEAN, st : {"scheduled", "running", "paused", "none"},
          next : 0..(Fires + 1)]
NoSnap == [en |-> FALSE, st |-> "none", next |-> 0]
Final == {"skipped", "sent", "failed"}

TypeOK ==
    /\ jobEnabled \in BOOLEAN
    /\ jobState \in {"scheduled", "running", "paused"}
    /\ nextRun \in 1..(Fires + 1)
    /\ runStatus \in [Runs -> {"absent", "queued", "running", "ok", "error"}]
    /\ delivery \in [Runs -> {"unset", "pending"} \cup Final]
    /\ now \in 0..Fires
    /\ pc \in [Runs -> PcStates]
    /\ resp \in [Runs -> {"-", "text", "silent"}]
    /\ finSnap \in [Runs -> Snaps]
    /\ outcome \in [Runs -> {"-", "sent", "failed"}]
    /\ helper \in [Runs -> {"none", "sending", "accepted", "ok", "err"}]
    /\ tries \in [Runs -> 0..SendAttempts]
    /\ delivered \in [Runs -> 0..SendAttempts]
    /\ sPc \in SchedStates
    /\ reapReturn \in {"arm", "scan", "idle"}
    /\ monitors \subseteq Runs /\ downs \subseteq Runs
    /\ changed \in BOOLEAN
    /\ dueTimer \in {"none", "zero", "later", "backoff"}
    /\ refused \in BOOLEAN
    /\ sRun \in 0..NumRuns
    /\ activeSnap \subseteq Runs /\ reapQ \subseteq Runs
    /\ sSnap \in Snaps
    /\ oPc \in {"idle", "pausing", "editing"}
    /\ oSnap \in Snaps
    /\ intent \in {"none", "paused", "resumed"}
    /\ movesLeft \in 0..OwnerMoves /\ editsLeft \in 0..OwnerEdits
    /\ manualLeft \in 0..ManualRuns
    /\ daemonCrashed \in BOOLEAN /\ schedCrashes \in 0..SchedulerCrashes

-----------------------------------------------------------------------------
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

Due == nextRun <= now
Alive(r) == pc[r] \notin {"off", "gone"}

\* Rows that hold an active slot: what ensure_no_active_job_run counts
\* (repo.ex:5824-5841) and the settle's guard accepts (repo.ex:5876-5883).
Active == {r \in Runs : runStatus[r] \in {"queued", "running"}}

\* What the reconcile scan reads: unsettled_job_runs, the active rows and then
\* the rows whose delivery is still pending (repo.ex:2272-2305); without
\* ReconcilesPending, the active rows alone.
Scanned == IF ReconcilesPending
           THEN Active \cup {r \in Runs : delivery[r] = "pending"}
           ELSE Active

JobRow == [en |-> jobEnabled, st |-> jobState, next |-> nextRun]

\* The settle's job release (release_settled_job, repo.ex:5889-5914): one
\* column-targeted UPDATE that turns "running" back into "scheduled" and keeps
\* any other state. It never writes next_run_at, and writes enabled only to
\* disable a one-off its claim consumed (one-offs are not modelled).
Release == jobState' = IF jobState = "running" THEN "scheduled" ELSE jobState

\* The job upsert the split finish and the split reaper do (AtomicSettle off):
\* the whole row from its earlier read, with "running" turned into "scheduled".
WriteBack(s) ==
    /\ jobEnabled' = s.en
    /\ jobState' = IF s.st = "running" THEN "scheduled" ELSE s.st
    /\ nextRun' = s.next

\* A run id can be reused once nothing refers to it any more.
Reusable(r) ==
    \/ runStatus[r] = "absent"
    \/ /\ runStatus[r] \in {"ok", "error"}
       /\ delivery[r] \in Final \cup {"unset"}
       /\ pc[r] \in {"off", "gone"}
       /\ helper[r] = "none"
       /\ r \notin monitors \cup downs \cup activeSnap \cup reapQ
       /\ r /= sRun
FreeIds == {r \in Runs : Reusable(r)}

\* The job_runs row the claim inserts (run_attrs, scheduler.ex:624-636),
\* and a clean slate for the per-run process and platform variables.
NewRun(r) ==
    /\ runStatus' = [runStatus EXCEPT ![r] = "queued"]
    /\ delivery' = [delivery EXCEPT ![r] = "unset"]
    /\ pc' = [pc EXCEPT ![r] = "off"]
    /\ delivered' = [delivered EXCEPT ![r] = 0]
    /\ UNCHANGED <<resp, finSnap, outcome, helper, tries>>

-----------------------------------------------------------------------------
(* The environment: the clock and the owner *)

\* Wall-clock time reaches the next fire time.
Tick ==
    /\ now < Fires
    /\ now' = now + 1
    /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, schedVars, ownerVars,
                   daemonCrashed, schedCrashes>>

\* Owner steps leave the Scheduler alone, except for the :job_changed cast.
OwnerQuiet == <<rowVars, runnerVars, helperVars, envVars, sPc, reapReturn, monitors,
                downs, dueTimer, refused, sRun, activeSnap, reapQ, sSnap>>

\* Registry.pause_job (registry.ex:42-44 -> update_job_fields :96-104):
\* Repo.update_scheduled_job_fields writes enabled = false and state =
\* "paused" in place (repo.ex:2206, :6071-6078), then the :job_changed cast
\* (registry.ex:345-350). The owner is told "paused". Nothing is read first.
Pause ==
    /\ OwnerWritesColumns
    /\ oPc = "idle" /\ movesLeft > 0
    /\ jobEnabled' = FALSE
    /\ jobState' = "paused"
    /\ changed' = TRUE
    /\ intent' = "paused"
    /\ movesLeft' = movesLeft - 1
    /\ UNCHANGED <<OwnerQuiet, nextRun, oPc, oSnap, editsLeft, manualLeft>>

\* Without OwnerWritesColumns, the pause before the fix: first
\* Repo.get_scheduled_job ...
PauseRead ==
    /\ ~OwnerWritesColumns
    /\ oPc = "idle" /\ movesLeft > 0
    /\ oPc' = "pausing"
    /\ oSnap' = JobRow
    /\ movesLeft' = movesLeft - 1
    /\ UNCHANGED <<OwnerQuiet, jobVars, changed, intent, editsLeft, manualLeft>>

\* ... then an upsert of the row it read with enabled = false, state =
\* "paused" (next_run_at as read), then the :job_changed cast.
PauseWrite ==
    /\ oPc = "pausing"
    /\ jobEnabled' = FALSE
    /\ jobState' = "paused"
    /\ nextRun' = oSnap.next
    /\ changed' = TRUE
    /\ intent' = "paused"
    /\ oPc' = "idle"
    /\ oSnap' = NoSnap
    /\ UNCHANGED <<OwnerQuiet, movesLeft, editsLeft, manualLeft>>

\* Registry.resume_job (registry.ex:47-59): get the row, then write enabled =
\* true, state = "scheduled" and next_run_at = the next future occurrence
\* (update_job_fields, :96-104), whatever state the job is in (nothing checks
\* that it is paused), then the :job_changed cast. The read is folded into the
\* write: every modelled column the write sets comes from the patch, none from
\* the read, with or without OwnerWritesColumns.
Resume ==
    /\ oPc = "idle" /\ movesLeft > 0
    /\ jobEnabled' = TRUE
    /\ jobState' = "scheduled"
    /\ nextRun' = now + 1
    /\ changed' = TRUE
    /\ intent' = "resumed"
    /\ movesLeft' = movesLeft - 1
    /\ UNCHANGED <<OwnerQuiet, oPc, oSnap, editsLeft, manualLeft>>

\* Registry.update_job (registry.ex:63-70): Repo.get_scheduled_job, whose row
\* the edit is computed from (normalize_update_attrs) ...
UpdateRead ==
    /\ oPc = "idle" /\ editsLeft > 0
    /\ oPc' = "editing"
    /\ oSnap' = JobRow
    /\ editsLeft' = editsLeft - 1
    /\ UNCHANGED <<OwnerQuiet, jobVars, changed, intent, movesLeft, manualLeft>>

\* ... then apply_job_update (registry.ex:106-116). With OwnerWritesColumns,
\* Repo.update_scheduled_job_fields writes only the edited columns, never
\* state, enabled or last_* (repo.ex:6071-6078; the owner field list,
\* :6955-6996): the modelled edit writes no modelled column. Without it, the
\* code before the fix upserted the whole row it read, writing back the
\* enabled, state and next_run_at it saw. Then the :job_changed cast.
UpdateWrite ==
    /\ oPc = "editing"
    /\ IF OwnerWritesColumns
       THEN UNCHANGED jobVars
       ELSE /\ jobEnabled' = oSnap.en
            /\ jobState' = oSnap.st
            /\ nextRun' = oSnap.next
    /\ changed' = TRUE
    /\ oPc' = "idle"
    /\ oSnap' = NoSnap
    /\ UNCHANGED <<OwnerQuiet, intent, movesLeft, editsLeft, manualLeft>>

-----------------------------------------------------------------------------
(* The Scheduler: callbacks that start when it is idle *)

\* Every callback below starts from an idle Scheduler. An idle Scheduler has
\* reapReturn "idle", refused FALSE, sRun 0 and empty reconcile locals.
Quiet == <<jobVars, rowVars, runnerVars, helperVars, ownerVars, envVars>>

\* handle_info(:due_tick) (scheduler.ex:191-193): the timer armed at 0 ms or
\* at the backoff, or the one armed for next_run_at once that time has come.
\* A backoff timer fires whether or not the job is due: firing early is free,
\* the scan finds nothing due and re-arms.
DueTimerFires ==
    /\ sPc = "idle"
    /\ dueTimer \in {"zero", "backoff"} \/ (dueTimer = "later" /\ Due)
    /\ sPc' = "scan"
    /\ dueTimer' = "none"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* handle_info(:reconcile_tick) (scheduler.ex:197-205), armed every 60 s:
\* reconcile, then the same due scan and re-arm as a due tick.
ReconcileFires ==
    /\ sPc = "idle"
    /\ sPc' = IF ReconcilesRuns THEN "r_rows" ELSE "scan"
    /\ reapReturn' = IF ReconcilesRuns THEN "scan" ELSE "idle"
    /\ UNCHANGED <<Quiet, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* handle_cast(:job_changed) (scheduler.ex:186-188): re-arm the due timer.
JobChanged ==
    /\ sPc = "idle"
    /\ changed
    /\ sPc' = "arm"
    /\ changed' = FALSE
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* handle_info({:DOWN, ...}) with an abnormal reason (scheduler.ex:207-218):
\* forget the monitor, then mark_run_crashed -> mark_run_failed (:673-697).
HandleDown(r) ==
    /\ sPc = "idle"
    /\ r \in downs
    /\ sPc' = "r_mark"
    /\ sRun' = r
    /\ downs' = downs \ {r}
    /\ monitors' = monitors \ {r}
    /\ UNCHANGED <<Quiet, reapReturn, changed, dueTimer, refused, activeSnap, reapQ, sSnap>>

\* handle_call({:run_now, ...}) -> manual_run (scheduler.ex:180-183, :470-503).
\* Its Repo.get_scheduled_job lookup is folded into Repo.claim_job_now: the
\* claim transaction re-checks enabled, "scheduled" and (the race-stop) no
\* queued/running run (repo.ex:5752-5757, :5769-5776, :5803-5822), so the
\* fold only drops harmless outcomes (an error reply either way). A manual
\* claim leaves a recurring job's next_run_at alone (manual_claim_patch,
\* scheduler.ex:494, :618-622). With every modelled run id in use, the
\* request is out of the model's bounds and is refused.
ManualRun ==
    /\ sPc = "idle"
    /\ manualLeft > 0
    /\ manualLeft' = manualLeft - 1
    /\ IF /\ jobEnabled /\ jobState = "scheduled"
          /\ (Active = {} \/ ~AtomicRaceStop)
          /\ FreeIds /= {}
       THEN LET r == Min(FreeIds) IN
            /\ sPc' = "start"
            /\ sRun' = r
            /\ NewRun(r)
            /\ jobState' = "running"
            /\ UNCHANGED <<jobEnabled, nextRun>>
       ELSE /\ sPc' = "arm"
            /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, sRun>>
    /\ UNCHANGED <<envVars, oPc, oSnap, intent, movesLeft, editsLeft, reapReturn,
                   monitors, downs, changed, dueTimer, refused, activeSnap, reapQ, sSnap>>

-----------------------------------------------------------------------------
(* The Scheduler: steps inside a callback, one Repo call each *)

\* Take the next orphan to reap, or go to reapReturn: init only re-arms
\* (scheduler.ex:168-169), the 60 s tick goes on to the due scan (:200-201),
\* a DOWN callback ends (:217).
NextReap(q) ==
    IF q /= {}
    THEN /\ sRun' = Min(q) /\ reapQ' = q \ {Min(q)} /\ sPc' = "r_mark"
         /\ UNCHANGED reapReturn
    ELSE /\ sRun' = 0 /\ reapQ' = {} /\ sPc' = reapReturn
         /\ reapReturn' = "idle"

\* After one run is reaped. A DOWN callback has no queue, so it ends.
AfterReap == NextReap(reapQ)

\* reconcile_active_runs: Repo.unsettled_job_runs (scheduler.ex:233), the
\* queued/running rows and the rows whose delivery is pending (Scanned).
ReconcileRows ==
    /\ sPc = "r_rows"
    /\ activeSnap' = Scanned
    /\ sPc' = "r_live"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   reapQ, sSnap>>

\* live_runner_pids: DynamicSupervisor.which_children + the run id each
\* runner published in its init (scheduler.ex:235, :281-295; runner.ex:158).
\* Live runs are adopted: monitored if not already (adopt_live_run, scheduler.ex:256-264;
\* the monitor call is folded in: monitoring a pid that just died delivers
\* DOWN at once, the same outcome as reaping it). A runner past its settle and
\* still sending is live and adopted too. The rest are orphans.
ReconcileLive ==
    /\ sPc = "r_live"
    /\ LET live == {r \in Runs : Alive(r)} IN
       /\ monitors' = monitors \cup (activeSnap \cap live)
       /\ activeSnap' = {}
       /\ NextReap(activeSnap \ live)
    /\ UNCHANGED <<Quiet, downs, changed, dueTimer, refused, sSnap>>

\* The reaper's write for run r, as it lands (mark_run_error, scheduler.ex
\* :699-725). A queued/running run is settled "error": with AtomicSettle
\* through Repo.settle_job_run, which releases the job in the same write
\* (:703-719); without, an upsert of the run row alone. A run whose delivery
\* is still pending, whatever its status, gets delivery "failed" (:721-723,
\* :742-755). Any other row is left alone.
ReapWrite(r) ==
    /\ IF runStatus[r] \in {"queued", "running"}
       THEN /\ runStatus' = [runStatus EXCEPT ![r] = "error"]
            /\ UNCHANGED delivery
            /\ IF AtomicSettle THEN Release ELSE UNCHANGED jobState
       ELSE IF CrashFailsPendingDelivery /\ delivery[r] = "pending"
       THEN /\ delivery' = [delivery EXCEPT ![r] = "failed"]
            /\ UNCHANGED <<runStatus, jobState>>
       ELSE UNCHANGED <<rowVars, jobState>>
    /\ UNCHANGED <<jobEnabled, nextRun>>

\* Whether that write leaves a job write to follow: only the split reaper
\* (AtomicSettle off) writes the job row after it, and only when it wrote.
SplitReapFollows(r) ==
    /\ ~AtomicSettle
    /\ \/ runStatus[r] \in {"queued", "running"}
       \/ CrashFailsPendingDelivery /\ delivery[r] = "pending"

\* mark_run_failed -> mark_run_error (scheduler.ex:680-725): Repo.get_job_run,
\* then the write above. The two calls are one step: once its runner is dead
\* only the Scheduler writes this row, and a runner's timed-out write landed
\* before the get, which was queued after it. For the same reason the
\* settle's :run_not_active branch (:712-713) is unreachable here. Without
\* AtomicSettle the code before the fix then wrote the job row (r_read).
ReapRun ==
    /\ sPc = "r_mark"
    /\ ReapWrite(sRun)
    /\ IF SplitReapFollows(sRun)
       THEN /\ sPc' = "r_read"
            /\ UNCHANGED <<sRun, reapQ, reapReturn>>
       ELSE AfterReap
    /\ UNCHANGED <<runnerVars, helperVars, ownerVars, envVars,
                   monitors, downs, changed, dueTimer, refused, activeSnap, sSnap>>

\* Without AtomicSettle, the job write of the code before the fix
\* (mark_job_error / mark_job_completed_after_delivery_crash), first half:
\* Repo.get_scheduled_job.
ReapReadJob ==
    /\ sPc = "r_read"
    /\ sSnap' = JobRow
    /\ sPc' = "r_write"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ>>

\* ... second half: Repo.upsert_scheduled_job of the row it read, "running"
\* -> "scheduled" (the memory-source update after it is folded in).
ReapWriteJob ==
    /\ sPc = "r_write"
    /\ WriteBack(sSnap)
    /\ sSnap' = NoSnap
    /\ AfterReap
    /\ UNCHANGED <<rowVars, runnerVars, helperVars, ownerVars, envVars,
                   monitors, downs, changed, dueTimer, refused, activeSnap>>

\* run_due_jobs: Repo.due_scheduled_jobs (scheduler.ex:309-318): enabled,
\* state "scheduled", next_run_at <= now (repo.ex:5686-5713).
Scan ==
    /\ sPc = "scan"
    /\ sPc' = IF jobEnabled /\ jobState = "scheduled" /\ Due THEN "claim" ELSE "arm"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* claim_patched_job -> Repo.claim_due_job (scheduler.ex:444-464): one
\* BEGIN IMMEDIATE transaction (repo.ex:5744-5776) that re-checks the job is
\* due, refuses while a run is queued/running (the race-stop), then sets
\* state "running" with next_run_at advanced (claim_job_patch, scheduler.ex
\* :609-613) and inserts the run "queued". :already_running returns
\* {:busy, state} (:451-455), :not_due {:ok, state}. With every modelled run
\* id in use the claim is out of the model's bounds and behaves like :not_due.
Claim ==
    /\ sPc = "claim"
    /\ IF ~(jobEnabled /\ jobState = "scheduled" /\ Due) \/ FreeIds = {}
       THEN /\ sPc' = "arm"
            /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, sRun, refused>>
       ELSE IF AtomicRaceStop /\ Active /= {}
       THEN /\ refused' = TRUE /\ sPc' = "arm"
            /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, sRun>>
       ELSE LET r == Min(FreeIds) IN
            /\ NewRun(r)
            /\ jobState' = "running"
            /\ nextRun' = now + 1
            /\ sRun' = r
            /\ sPc' = "start"
            /\ UNCHANGED <<jobEnabled, refused>>
    /\ UNCHANGED <<ownerVars, envVars, reapReturn, monitors, downs, changed, dueTimer,
                   activeSnap, reapQ, sSnap>>

\* start_or_mark_failed (scheduler.ex:593-603): RunnerSupervisor.start_run
\* runs Runner.init synchronously (runner_supervisor.ex:20-23), which
\* publishes the run id (runner.ex:158); then Process.monitor.
Start ==
    /\ sPc = "start"
    /\ pc' = [pc EXCEPT ![sRun] = "start"]
    /\ monitors' = monitors \cup {sRun}
    /\ sRun' = 0
    /\ sPc' = "arm"
    /\ UNCHANGED <<jobVars, rowVars, resp, finSnap, outcome, helperVars, ownerVars,
                   envVars, reapReturn, downs, changed, dueTimer, refused, activeSnap,
                   reapQ, sSnap>>

\* schedule_due_timer -> next_due_timer: Repo.next_scheduled_job (scheduler.ex
\* :791-819, repo.ex:5715-5742). A tick whose claim was refused re-arms no
\* sooner than the 5 s backoff (outcome :busy, due_delay_ms, scheduler.ex:864-870) with
\* RefusalBacksOff; without it the refusal counted as a clean drain. After a
\* clean tick an enabled "scheduled" job is armed at its next_run_at, which is
\* 0 ms when it is already due; no such job arms nothing.
Arm ==
    /\ sPc = "arm"
    /\ dueTimer' = IF refused /\ RefusalBacksOff THEN "backoff"
                   ELSE IF jobEnabled /\ jobState = "scheduled"
                        THEN IF Due THEN "zero" ELSE "later"
                        ELSE "none"
    /\ sPc' = "idle"
    /\ reapReturn' = "idle"
    /\ refused' = FALSE
    /\ UNCHANGED <<Quiet, monitors, downs, changed, sRun, activeSnap, reapQ, sSnap>>

SchedStep ==
    \/ ReconcileRows \/ ReconcileLive \/ ReapRun \/ ReapReadJob \/ ReapWriteJob
    \/ Scan \/ Claim \/ Start \/ Arm

-----------------------------------------------------------------------------
(* One Runner (runner.ex), a :temporary child of Jobs.RunnerSupervisor *)

Move(r, s) == pc' = [pc EXCEPT ![r] = s]
RunnerQuiet == <<jobVars, ownerVars, envVars, schedVars>>

\* handle_continue(:run) -> mark_running (runner.ex:164-167, :215-232):
\* Repo.upsert_job_run with status "running".
MarkRunning(r) ==
    /\ pc[r] = "start"
    /\ Move(r, "loop")
    /\ runStatus' = [runStatus EXCEPT ![r] = "running"]
    /\ UNCHANGED <<RunnerQuiet, delivery, resp, finSnap, outcome, helperVars>>

\* The whole AgentLoop, run in a spawned process the runner watches
\* (runner.ex:190, :967-989): final text, [SILENT], or an error/timeout.
Loop(r) ==
    /\ pc[r] = "loop"
    /\ \/ \E res \in {"text", "silent"} :
             /\ resp' = [resp EXCEPT ![r] = res]
             /\ Move(r, "complete")
       \/ /\ LoopCanFail
          /\ Move(r, "fail")
          /\ UNCHANGED resp
    /\ UNCHANGED <<RunnerQuiet, rowVars, finSnap, outcome, helperVars>>

\* The runner's final write, as it lands. After the loop: status "ok" with
\* delivery "pending", or "skipped" for [SILENT] (Delivery.initial_status,
\* delivery.ex:24-31). After a loop error: status "error" with delivery
\* "pending" for the failure text. With AtomicSettle the job release lands in
\* the same transaction (Repo.settle_job_run, runner.ex:258 / :321).
RunnerWrite(r) ==
    /\ runStatus' = [runStatus EXCEPT ![r] = IF pc[r] = "complete" THEN "ok" ELSE "error"]
    /\ delivery' = [delivery EXCEPT ![r] =
                      IF pc[r] = "complete" /\ resp[r] = "silent" THEN "skipped" ELSE "pending"]
    /\ IF AtomicSettle THEN Release ELSE UNCHANGED jobState
    /\ UNCHANGED <<jobEnabled, nextRun>>

\* The settle's guard (ensure_job_run_active, repo.ex:5876-5883): only a
\* queued/running row may be settled. The split write has no guard.
Settleable(r) == ~AtomicSettle \/ runStatus[r] \in {"queued", "running"}

\* mark_completed (runner.ex:239-261) / mark_failed (:302-326) with
\* AtomicSettle: write output.md or error.md (folded in), then
\* Repo.settle_job_run (repo.ex:2263, :5859-5928): the run row and the job's
\* release in one transaction. After a success the memory write comes next;
\* after a loop error the memory-source update (runner.ex:324, folded in) and then the
\* send, so that runner goes straight to its send. A settle the guard refuses
\* fails the {:ok, _} match and kills the runner; that branch is unreachable,
\* since the reaper only settles a run whose runner is dead.
Settle(r) ==
    /\ AtomicSettle
    /\ pc[r] \in {"complete", "fail"}
    /\ IF Settleable(r)
       THEN /\ RunnerWrite(r)
            /\ IF pc[r] = "complete"
               THEN /\ Move(r, "memo") /\ UNCHANGED helper
               ELSE /\ Move(r, "await") /\ helper' = [helper EXCEPT ![r] = "sending"]
            /\ UNCHANGED downs
       ELSE /\ Move(r, "gone")
            /\ downs' = IF r \in monitors THEN downs \cup {r} ELSE downs
            /\ UNCHANGED <<jobVars, rowVars, helper>>
    /\ resp' = [resp EXCEPT ![r] = "-"]
    /\ UNCHANGED <<ownerVars, envVars, sPc, reapReturn, monitors, changed, dueTimer,
                   refused, sRun, activeSnap, reapQ, sSnap, finSnap, outcome, tries,
                   delivered>>

\* Without AtomicSettle, mark_completed before the fix: Repo.upsert_job_run of
\* the run row alone.
MarkCompleted(r) ==
    /\ ~AtomicSettle
    /\ pc[r] = "complete"
    /\ RunnerWrite(r)
    /\ Move(r, "memo")
    /\ resp' = [resp EXCEPT ![r] = "-"]
    /\ UNCHANGED <<ownerVars, envVars, schedVars, finSnap, outcome, helperVars>>

\* Without AtomicSettle, mark_failed before the fix: the run row alone.
MarkFailed(r) ==
    /\ ~AtomicSettle
    /\ pc[r] = "fail"
    /\ RunnerWrite(r)
    /\ Move(r, "finread")
    /\ UNCHANGED <<ownerVars, envVars, schedVars, resp, finSnap, outcome, helperVars>>

\* persist_run_summary_memory (runner.ex:203, :263-300): Repo.upsert_memory
\* (skipped for [SILENT]), then the memory-source update (:204, :368-385),
\* folded in. No modelled row changes; it is a crash point. With AtomicSettle
\* finalize_delivery (:205, :334-342) follows: a pending delivery spawns the
\* monitored send helper (Delivery.deliver_with_timeout ->
\* ChannelSend.with_timeout, delivery.ex:53-78, channel_send.ex:219-224); a
\* skipped one is immediate. Without it the split job write comes first.
Memory(r) ==
    /\ pc[r] = "memo"
    /\ IF ~AtomicSettle
       THEN /\ Move(r, "finread") /\ UNCHANGED helper
       ELSE IF delivery[r] = "pending"
       THEN /\ Move(r, "await") /\ helper' = [helper EXCEPT ![r] = "sending"]
       ELSE /\ Move(r, "mark") /\ UNCHANGED helper
    /\ UNCHANGED <<RunnerQuiet, rowVars, resp, finSnap, outcome, tries, delivered>>

\* Without AtomicSettle, finalize_job / finalize_failed_job before the fix,
\* first half: Repo.get_scheduled_job.
FinRead(r) ==
    /\ pc[r] = "finread"
    /\ Move(r, "finwrite")
    /\ finSnap' = [finSnap EXCEPT ![r] = JobRow]
    /\ UNCHANGED <<RunnerQuiet, rowVars, resp, outcome, helperVars>>

\* ... second half: Repo.upsert_scheduled_job of the row it read, with
\* "running" turned into "scheduled" (the memory-source update after it is
\* folded in). Then finalize_delivery, as after Memory with AtomicSettle.
FinWrite(r) ==
    /\ pc[r] = "finwrite"
    /\ WriteBack(finSnap[r])
    /\ finSnap' = [finSnap EXCEPT ![r] = NoSnap]
    /\ IF delivery[r] = "pending"
       THEN /\ Move(r, "await")
            /\ helper' = [helper EXCEPT ![r] = "sending"]
       ELSE /\ Move(r, "mark")
            /\ UNCHANGED helper
    /\ UNCHANGED <<ownerVars, envVars, schedVars, rowVars, resp, outcome,
                   tries, delivered>>

\* The watchdog's receive gets the helper's result (channel_send.ex:226-233).
GotResult(r) ==
    /\ pc[r] = "await"
    /\ helper[r] \in {"ok", "err"}
    /\ outcome' = [outcome EXCEPT ![r] = IF helper[r] = "ok" THEN "sent" ELSE "failed"]
    /\ helper' = [helper EXCEPT ![r] = "none"]
    /\ Move(r, "mark")
    /\ UNCHANGED <<RunnerQuiet, rowVars, resp, finSnap, tries, delivered>>

\* mark_delivery (runner.ex:344-366): Repo.upsert_job_run with the result,
\* then {:stop, :normal} (runner.ex:176). The Scheduler's DOWN :normal
\* handler only drops the monitor (scheduler.ex:212-213); it is folded in.
MarkDelivery(r) ==
    /\ pc[r] = "mark"
    /\ delivery' = [delivery EXCEPT ![r] =
                      IF delivery[r] = "skipped" THEN "skipped" ELSE outcome[r]]
    /\ outcome' = [outcome EXCEPT ![r] = "-"]
    /\ Move(r, "gone")
    /\ monitors' = monitors \ {r}
    /\ UNCHANGED <<jobVars, ownerVars, envVars, runStatus, resp, finSnap,
                   helperVars, sPc, reapReturn, downs, changed, dueTimer, refused,
                   sRun, activeSnap, reapQ, sSnap>>

RunnerStep(r) ==
    \/ MarkRunning(r) \/ Loop(r) \/ Settle(r) \/ MarkCompleted(r) \/ Memory(r)
    \/ MarkFailed(r) \/ FinRead(r) \/ FinWrite(r) \/ GotResult(r) \/ MarkDelivery(r)

\* The runner dies at one of its Repo calls and the call never lands (a
\* kill, a failed {:ok, _} match). A failed output.md/error.md write also
\* kills it ({:ok, _} match, runner.ex:241, :307); that write is folded into
\* the final write, so it is the crash at "complete"/"fail". The
\* memory-source calls after the split job upsert are a crash point with no
\* pc of their own: a crash there leaves the rows a crash at "mark" leaves,
\* minus the send. It raises nowhere while it waits in receive (the loop or a
\* send). Its supervisor does not restart it (restart: :temporary,
\* runner.ex:112); a Scheduler that monitors it gets a DOWN.
RunnerCrash(r) ==
    /\ RunnerCanCrash
    /\ pc[r] \in {"start", "complete", "memo", "fail", "finread", "finwrite", "mark"}
    /\ Move(r, "gone")
    /\ resp' = [resp EXCEPT ![r] = "-"]
    /\ finSnap' = [finSnap EXCEPT ![r] = NoSnap]
    /\ outcome' = [outcome EXCEPT ![r] = "-"]
    /\ downs' = IF r \in monitors THEN downs \cup {r} ELSE downs
    /\ UNCHANGED <<jobVars, rowVars, ownerVars, envVars, helperVars, sPc, reapReturn,
                   monitors, changed, dueTimer, refused, sRun, activeSnap, reapQ, sSnap>>

\* The runner's final write times out: GenServer.call exits the runner
\* (repo.ex:3777-3780), but the request stays in the Repo's mailbox and lands.
\* With AtomicSettle that is the whole settle, guard included; after a loop
\* error it also stands for a crash at the memory-source calls between the
\* settle and the send. Every later reader's call was queued after it.
RunnerCrashLate(r) ==
    /\ RunnerCanCrash
    /\ pc[r] \in {"complete", "fail"}
    /\ Settleable(r)
    /\ RunnerWrite(r)
    /\ Move(r, "gone")
    /\ resp' = [resp EXCEPT ![r] = "-"]
    /\ downs' = IF r \in monitors THEN downs \cup {r} ELSE downs
    /\ UNCHANGED <<ownerVars, envVars, helperVars, finSnap, outcome, sPc, reapReturn,
                   monitors, changed, dueTimer, refused, sRun, activeSnap, reapQ, sSnap>>

-----------------------------------------------------------------------------
(* The send helper and the platform (ChannelSend.send, run_send) *)

\* One send attempt (channel_send.ex:135-149, :190-210). The platform takes
\* the message or not; the helper retries only the connection-unavailable
\* error, which never reached the platform, up to SendAttempts attempts.
HelperSend(r) ==
    /\ helper[r] = "sending"
    /\ LET again == tries[r] + 1 < SendAttempts
           took == [delivered EXCEPT ![r] = @ + 1]
       IN
       \/ \* taken and answered :ok
          /\ delivered' = took
          /\ helper' = [helper EXCEPT ![r] = "ok"]
          /\ tries' = [tries EXCEPT ![r] = 0]
       \/ \* taken, and the answer does not arrive in time
          /\ ResponsesCanStall
          /\ delivered' = took
          /\ helper' = [helper EXCEPT ![r] = "accepted"]
          /\ tries' = [tries EXCEPT ![r] = 0]
       \/ \* taken, but the adapter reports an error (e.g. a read timeout)
          /\ PlatformCanFail
          /\ delivered' = took
          /\ IF again /\ ~RetriesOnlyUnsent
             THEN /\ tries' = [tries EXCEPT ![r] = @ + 1] /\ UNCHANGED helper
             ELSE /\ helper' = [helper EXCEPT ![r] = "err"]
                  /\ tries' = [tries EXCEPT ![r] = 0]
       \/ \* no connection: it never reached the platform
          /\ PlatformCanFail
          /\ UNCHANGED delivered
          /\ IF again
             THEN /\ tries' = [tries EXCEPT ![r] = @ + 1] /\ UNCHANGED helper
             ELSE /\ helper' = [helper EXCEPT ![r] = "err"]
                  /\ tries' = [tries EXCEPT ![r] = 0]
    /\ UNCHANGED <<RunnerQuiet, rowVars, runnerVars>>

\* The runner's own delivery timer (delivery_timeout_ms, runner.ex:1277):
\* no result yet, so it kills the helper and returns {:error,
\* :delivery_timeout} (channel_send.ex:238-239, :284-300). It cannot tell whether the
\* platform already took the message.
Watchdog(r) ==
    /\ DeliveryWatchdog
    /\ pc[r] = "await"
    /\ helper[r] \in {"sending", "accepted"}
    /\ helper' = [helper EXCEPT ![r] = "none"]
    /\ tries' = [tries EXCEPT ![r] = 0]
    /\ outcome' = [outcome EXCEPT ![r] = "failed"]
    /\ Move(r, "mark")
    /\ UNCHANGED <<RunnerQuiet, rowVars, resp, finSnap, delivered>>

-----------------------------------------------------------------------------
(* Crashes and restarts *)

\* The Scheduler (re)starts: init reconciles, then arms (scheduler.ex:124-173).
\* Its monitors, timers and mailbox are gone.
SchedRestart ==
    /\ sPc' = IF ReconcilesRuns THEN "r_rows" ELSE "arm"
    /\ reapReturn' = "arm"
    /\ monitors' = {}
    /\ downs' = {}
    /\ changed' = FALSE
    /\ dueTimer' = "none"
    /\ refused' = FALSE
    /\ sRun' = 0
    /\ activeSnap' = {}
    /\ reapQ' = {}
    /\ sSnap' = NoSnap

\* The Scheduler dies alone, at any point of any callback (a Repo call
\* timeout exits it wherever it waits), and the call it waited on never
\* lands. FermixCore.Supervisor is :rest_for_one and starts
\* JobRunnerSupervisor before JobScheduler (application.ex:220, :227, :259),
\* so the restart leaves every runner running.
SchedulerCrash ==
    /\ schedCrashes < SchedulerCrashes
    /\ schedCrashes' = schedCrashes + 1
    /\ SchedRestart
    /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, ownerVars, now, daemonCrashed>>

\* The Scheduler dies waiting on the reaper's write, and the write lands late
\* (repo.ex:3777-3780). With AtomicSettle that is the whole settle; without,
\* the run row alone, and the job write never happens.
SchedulerCrashLate ==
    /\ sPc = "r_mark"
    /\ schedCrashes < SchedulerCrashes
    /\ schedCrashes' = schedCrashes + 1
    /\ ReapWrite(sRun)
    /\ SchedRestart
    /\ UNCHANGED <<runnerVars, helperVars, ownerVars, now, daemonCrashed>>

\* The daemon dies: every process with it (runners, send helpers, the
\* owner's request in flight). Only SQLite rows and what the platform took
\* survive. On boot the Scheduler's init reconciles.
DaemonCrash ==
    /\ DaemonCanCrash /\ ~daemonCrashed
    /\ daemonCrashed' = TRUE
    /\ pc' = [r \in Runs |-> IF Alive(r) THEN "gone" ELSE pc[r]]
    /\ resp' = [r \in Runs |-> "-"]
    /\ finSnap' = [r \in Runs |-> NoSnap]
    /\ outcome' = [r \in Runs |-> "-"]
    /\ helper' = [r \in Runs |-> "none"]
    /\ tries' = [r \in Runs |-> 0]
    /\ oPc' = "idle"
    /\ oSnap' = NoSnap
    /\ SchedRestart
    /\ UNCHANGED <<jobVars, rowVars, delivered, intent, movesLeft, editsLeft, manualLeft,
                   now, schedCrashes>>

-----------------------------------------------------------------------------
Init ==
    /\ jobEnabled = TRUE
    /\ jobState = "scheduled"
    /\ nextRun = 1
    /\ runStatus = [r \in Runs |-> "absent"]
    /\ delivery = [r \in Runs |-> "unset"]
    /\ now = 0
    /\ pc = [r \in Runs |-> "off"]
    /\ resp = [r \in Runs |-> "-"]
    /\ finSnap = [r \in Runs |-> NoSnap]
    /\ outcome = [r \in Runs |-> "-"]
    /\ helper = [r \in Runs |-> "none"]
    /\ tries = [r \in Runs |-> 0]
    /\ delivered = [r \in Runs |-> 0]
    /\ sPc = "idle"
    /\ reapReturn = "idle"
    /\ monitors = {}
    /\ downs = {}
    /\ changed = FALSE
    /\ dueTimer = "later"
    /\ refused = FALSE
    /\ sRun = 0
    /\ activeSnap = {}
    /\ reapQ = {}
    /\ sSnap = NoSnap
    /\ oPc = "idle"
    /\ oSnap = NoSnap
    /\ intent = "none"
    /\ movesLeft = OwnerMoves
    /\ editsLeft = OwnerEdits
    /\ manualLeft = ManualRuns
    /\ daemonCrashed = FALSE
    /\ schedCrashes = 0

\* The legitimate end: the clock at its horizon, no runner or send helper
\* alive, the owner done, and an idle Scheduler with an empty mailbox. The
\* Scheduler's 60 s reconcile timer is always armed, so it always has a next
\* step: a wedge shows up as a broken liveness property, not as a deadlock.
Done ==
    /\ now = Fires
    /\ \A r \in Runs : ~Alive(r) /\ helper[r] = "none"
    /\ oPc = "idle"
    /\ sPc = "idle" /\ downs = {} /\ ~changed

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ Tick \/ Pause \/ PauseRead \/ PauseWrite \/ Resume \/ UpdateRead \/ UpdateWrite
    \/ ManualRun
    \/ DueTimerFires \/ ReconcileFires \/ JobChanged \/ \E r \in Runs : HandleDown(r)
    \/ SchedStep
    \/ \E r \in Runs : RunnerStep(r) \/ HelperSend(r) \/ Watchdog(r) \/ RunnerCrash(r)
                       \/ RunnerCrashLate(r)
    \/ SchedulerCrash \/ SchedulerCrashLate \/ DaemonCrash
    \/ Terminated

\* Fermix drives these itself: a live runner's and send helper's next step,
\* the runner's delivery timer, the Scheduler's steps inside a callback
\* (weak fairness), and the Scheduler serving its mailbox and its own timers
\* (strong fairness: a message that keeps finding the Scheduler idle is
\* eventually handled). The clock, the owner, the platform's answers and
\* every crash get no fairness.
Fairness ==
    /\ WF_vars(SchedStep)
    /\ SF_vars(DueTimerFires) /\ SF_vars(ReconcileFires) /\ SF_vars(JobChanged)
    /\ \A r \in Runs :
          /\ SF_vars(HandleDown(r))
          /\ WF_vars(RunnerStep(r))
          /\ WF_vars(HelperSend(r))
          /\ WF_vars(Watchdog(r))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* scheduler.ex:477-481: "a job mid-run carries state 'running' (the claim
\* sets it atomically) ... The in-transaction `ensure_no_active_job_run`
\* guard (shared with the due path) remains the atomic race-stop
\* underneath." Read as: at most one run of the job is active, counting a
\* queued/running row or a runner still before or inside its AgentLoop.
OneActiveRun ==
    Cardinality({r \in Runs : runStatus[r] \in {"queued", "running"}
                              \/ pc[r] \in {"start", "loop"}}) <= 1

\* ARCHITECTURE.md, "FermixCore.Jobs, Temporal, and Delivery": a run's
\* "final text is delivered once". Safety half: never twice.
DeliveredAtMostOnce == \A r \in Runs : delivered[r] <= 1

\* channel_send.ex:10-11: "a with_timeout/2 watchdog so a slow
\* send can never wedge the caller". Read as: a runner waiting on a send
\* always stops waiting.
SendNeverWedgesRunner == \A r \in Runs : pc[r] = "await" ~> pc[r] /= "await"

\* Proposed rule: a job the owner left enabled is never wedged: it always
\* gets back to "scheduled" with no active run, where a due tick claims it.
JobIdle == jobState = "scheduled" /\ Active = {}
EnabledJobNotWedged == jobEnabled ~> (JobIdle \/ ~jobEnabled)

\* Proposed rule: every run whose delivery is pending reaches a final
\* delivery status (sent, failed or skipped).
DeliveryReachesFinal == \A r \in Runs : delivery[r] = "pending" ~> delivery[r] \in Final

\* Proposed rule: a pause the owner was told about stays in force until the
\* owner resumes.
PauseNeverOverwritten == intent = "paused" => ~jobEnabled

\* Proposed rule: a resume the owner was told about stays in force until the
\* owner pauses.
ResumeNeverOverwritten == intent = "resumed" => jobEnabled

\* scheduler.ex:29-34: a due tick that cannot drain its work, including "a
\* due job whose previous run is still active", re-arms no sooner than the
\* backoff, "so a persistently past-due-but-unclaimable job can never spin
\* the scheduler at 0ms"; :858-862 says it again. Read as an action rule: the
\* Arm step that ends a callback whose claim was refused as :already_running
\* never arms the 0 ms timer. (Arm is the only step from "arm" to "idle".)
NoZeroRearmAfterRefusal ==
    [][(sPc = "arm" /\ refused /\ sPc' = "idle") => dueTimer' /= "zero"]_vars

\* Proposed rule: a delivery recorded as failed did not reach the user.
\* Fermix deliberately does not make it (JOB-6): "failed" means "not
\* confirmed delivered".
FailedMeansNotDelivered == \A r \in Runs : delivery[r] = "failed" => delivered[r] = 0

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* One run is still finishing (after its final write, delivering) while the
\* next run of the same job is already in its AgentLoop: the race-stop
\* counts rows, not runner processes.
Witness_OverlappingRunners ==
    ~(\E a, b \in Runs :
        /\ pc[a] \in {"start", "loop"}
        /\ pc[b] \in {"memo", "finread", "finwrite", "await", "mark"})

\* A due claim is refused as :already_running: the job is "scheduled", enabled
\* and due while a run still holds it (a resume mid-run). The re-arm rule
\* above is not vacuous.
Witness_ClaimRefused == ~(sPc = "arm" /\ refused)

=============================================================================
