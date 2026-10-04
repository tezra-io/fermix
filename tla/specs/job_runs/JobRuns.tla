----------------------------- MODULE JobRuns -----------------------------
(***************************************************************************)
(* FermixCore.Jobs for ONE recurring job: the Scheduler's due tick and its  *)
(* atomic claim, one Runner per run (a :temporary GenServer), the settle    *)
(* that writes a run's final row and releases its job in one transaction,  *)
(* the delivery of the run's final text through a watchdog-bounded send    *)
(* helper, the Scheduler's monitors and its reconciliation pass (at init   *)
(* and every 60 s) over every unsettled run, a Runner crash, a Scheduler   *)
(* Repo call that times out, a Scheduler-only crash, a daemon crash        *)
(* followed by boot reconciliation, and the owner's pause, resume, edit    *)
(* and "run now".                                                          *)
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
(* SQLite busy or errors (every Repo call succeeds, unless its caller dies *)
(* or, for the Scheduler, times out); the admission ceiling (four runs;    *)
(* one job never has more than two runner processes, so the ceiling's      *)
(* :busy never happens);                                                   *)
(* delivery_mode "none"/"local" (they behave like a [SILENT] result: final *)
(* at once); memory-source rows, telemetry, the start-up stagger and the   *)
(* network-readiness wait. An owner edit is modelled as one that touches   *)
(* none of the modelled columns (a task or delivery edit).                 *)
(* The access gate is not modelled either. A run's access-sensitive tool   *)
(* call that its job row does not name is refused inside the one loop      *)
(* step, since a scheduled run never parks a call for the owner            *)
(* (access_gate.ex:261-270). An owner edit, resume or run now of a job     *)
(* naming such a tool, from a turn that could not run it directly, is      *)
(* refused by the tool before any registry write or Scheduler call         *)
(* (job_registry_support.ex:33-38): a request the owner never made. Its    *)
(* job-row read feeds no modelled column. The store of parked              *)
(* confirmations (AccessGate.Pending, application.ex:222) is one more core *)
(* child started before the RunnerSupervisor, so its crash is the daemon   *)
(* crash below.                                                            *)
(*                                                                         *)
(* Late writes: the Repo serves one request at a time, and a call it does  *)
(* not answer within 5 s (Timeouts.repo_call) is not cancelled: the        *)
(* request lands later, still before any later request from the same       *)
(* caller (repo.ex:3931-3944). A runner dies on that timeout, so a crash   *)
(* at a runner's Repo write comes in two kinds: the write lands late, or   *)
(* it never lands (a kill). The late kind is modelled where no later crash *)
(* point stands for it: the runner's final write (RunnerCrashLate). The    *)
(* Scheduler survives the timeout (Repo.periodic_opts, repo.ex:1152-1154,  *)
(* :3946-3954): the call returns {:error, :repo_timeout}, and the          *)
(* Scheduler takes that call site's error branch and keeps its monitors    *)
(* and timers (the timeout steps below). It can still die of another       *)
(* cause while it waits on the reaper's write, which then lands            *)
(* (SchedulerCrashLate). Every later reader queues its own call after the  *)
(* late one, and the Scheduler's own steps before its next Repo call read  *)
(* no row, so a late write lands in the crash or timeout step itself.      *)
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
(* unbounded run history. A daemon crash also stands for a crash of any    *)
(* core child started before the RunnerSupervisor (Memory.Repo, Trace,     *)
(* Finch, MainAgent and the rest, application.ex:169-225) or of the        *)
(* RunnerSupervisor itself: under :rest_for_one each restarts the          *)
(* RunnerSupervisor with its runners and the Scheduler                     *)
(* (application.ex:264). A runner's send helper (REMIND-2,                 *)
(* channel_send.ex:219-224) and its AgentLoop (JOB-8, runner.ex:984-988)   *)
(* are linked to it, so the restart kills them too. With                   *)
(* LoopDiesWithRunner off (the code before JOB-8's fix, an unlinked        *)
(* spawn_monitor) the loop outlives it (strayLoops). Process-local values  *)
(* a step no longer needs are cleared, so that dead values do not          *)
(* multiply the states.                                                    *)
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
(* A timed-out Repo call takes its call site's error branch:               *)
(*   r_rows -ReconcileRowsTimeout-> reapReturn (no pass)                   *)
(*   r_mark -ReapLookupTimeout-> (next orphan or reapReturn; no write)     *)
(*   scan -ScanTimeout-> idle      claim -ClaimTimeout-> idle (may land)   *)
(*   arm -ArmTimeout-> idle        idle -ManualRunTimeout-> arm (may land) *)
(* reapReturn is where the Scheduler goes once its reaping is done: "arm"  *)
(* after init, "scan" in the 60 s tick, "idle" after a DOWN.               *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/scheduler.ex @ 431e59acf5c0
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/runner.ex @ 17c578e38326
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/runner_supervisor.ex @ 6a21dfe6cfad
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/delivery.ex @ 4eb42c517b57
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/registry.ex @ 2bdc53628bcc
\* SOURCE: apps/fermix_core/lib/fermix_core/delivery/channel_send.ex @ 9b06289e25ae
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#call,call_or_timeout_error,request_name,periodic_opts,claim_due_job,claim_job_now,claim_due_job_tx,claim_in_tx,claim_job_now_tx,transact_claim,fetch_claimable_due_job,finish_job_claim,rollback_job_claim,upsert_scheduled_job_row,upsert_job_run_row,ensure_no_active_job_run,fetch_claimable_job,settle_job_run,settle_job_run_tx,settle_job_run_in_tx,ensure_job_run_active,release_settled_job,finish_job_settle,rollback_job_settle,unsettled_job_runs,fetch_unsettled_job_runs,@unsettled_job_runs_sql,update_scheduled_job_fields,update_scheduled_job_fields_row,scheduled_job_field_assignments!,scheduled_job_field_assignment!,@owner_text_fields,due_scheduled_jobs,fetch_due_scheduled_jobs,next_scheduled_job,fetch_next_scheduled_job,upsert_job_run,upsert_scheduled_job,get_job_run,get_scheduled_job,upsert_memory @ caaa1f9eebe9
\* SOURCE: apps/fermix_core/lib/fermix_core/application.ex#start_supervision_tree,jobs_scheduler_opts @ 2920c077b364
\* SOURCE: apps/fermix_core/lib/fermix_core/timeouts.ex#expired,repo_call,@repo_call_ms @ 05d3e6ea2142
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
    SchedulerCrashes,   \* how many times the Scheduler alone may die of a cause other than a
                        \* Repo timeout, e.g. :rest_for_one restarting it when the
                        \* MeetingsSupervisor between the RunnerSupervisor and it dies
                        \* (application.ex:230-237)
    SchedulerTimeouts,  \* how many of the Scheduler's Repo calls may time out (5 s); it takes
                        \* that call site's error branch and keeps running (repo.ex:1152-1154)
    RunnerCanCrash,     \* a runner dies at one of its Repo calls (a timeout, a failed match)
    LoopCanFail,        \* the AgentLoop ends in an error or a timeout
    PlatformCanFail,    \* a send fails: no connection, or an error after the platform took it
    ResponsesCanStall,  \* the platform takes a message and its answer never arrives in time;
                        \* with DeliveryWatchdog off the wait is unbounded (the adapters'
                        \* own HTTP timeouts are outside the sources)
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by the checks that show a property needs it.
    AtomicRaceStop,           \* the claim refuses while a run is queued/running (repo.ex:6018, :6071-6089)
    RetriesOnlyUnsent,        \* a send is retried only when it never reached the platform (channel_send.ex:140-143, :194-202);
                              \* the mechanism for platforms that do not dedupe on the run's proactive_key
    ReconcilesRuns,           \* init and every 60 s reap orphaned runs, adopt live runners (scheduler.ex:178, :207-283)
    CrashFailsPendingDelivery,\* a dead runner's pending delivery is marked failed, whatever the run's
                              \* status (scheduler.ex:731-733, :752-765)
    DeliveryWatchdog,         \* the runner stops waiting for a send after delivery_timeout_ms (channel_send.ex:219-241)
    AtomicSettle,             \* a run's final row and its job's release are one transaction, for the
                              \* runner and the reaper alike (repo.ex:2369, :6106-6175)
    ReconcilesPending,        \* the reconcile pass also reads runs whose delivery is still pending
                              \* (unsettled_job_runs, repo.ex:2378-2411, scheduler.ex:243)
    RefusalBacksOff,          \* a due claim refused as :already_running is backpressure: the re-arm
                              \* floors at the 5 s backoff (scheduler.ex:461-465, :886-892)
    OwnerWritesColumns,       \* pause, resume and update_job write only the columns they own
                              \* (registry.ex:93-116; repo.ex:2312, :6318-6325, :7221-7262)
    LoopDiesWithRunner        \* a runner's AgentLoop is linked to it, so a restart that kills
                              \* the runner kills its loop too (runner.ex:984-988)

Runs == 1..NumRuns

VARIABLES
    \* --- SQLite rows (survive every crash) ---
    jobEnabled,  \* scheduled_jobs.enabled
    jobState,    \* scheduled_jobs.state: "scheduled" | "running" | "paused"
    nextRun,     \* scheduled_jobs.next_run_at, as a fire-time index
    runStatus,   \* runStatus[r]: job_runs.status ("absent" = no row for this id yet)
    delivery,    \* delivery[r]: job_runs.delivery_status; "unset" is the "none" the claim
                 \* writes before a result exists (scheduler.ex:642), kept apart from the
                 \* final "none" of delivery_mode "none" (modelled as "skipped")
    \* --- the environment ---
    now,         \* fire times that have passed (the wall clock)
    strayLoops,  \* runs whose AgentLoop outlived its runner in a daemon crash (only
                 \* without LoopDiesWithRunner): a process no model step reaches
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
    schedCrashes,  \* times the Scheduler alone has died
    schedTimeouts  \* times a Scheduler Repo call has timed out

jobVars    == <<jobEnabled, jobState, nextRun>>
rowVars    == <<runStatus, delivery>>
runnerVars == <<pc, resp, finSnap, outcome>>
helperVars == <<helper, tries, delivered>>
schedVars  == <<sPc, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
               activeSnap, reapQ, sSnap>>
ownerVars  == <<oPc, oSnap, intent, movesLeft, editsLeft, manualLeft>>
envVars    == <<now, strayLoops, daemonCrashed, schedCrashes, schedTimeouts>>
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
    /\ strayLoops \subseteq Runs
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
    /\ schedTimeouts \in 0..SchedulerTimeouts

-----------------------------------------------------------------------------
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

Due == nextRun <= now
Alive(r) == pc[r] \notin {"off", "gone"}

\* Rows that hold an active slot: what ensure_no_active_job_run counts
\* (repo.ex:6071-6088) and the settle's guard accepts (repo.ex:6123-6130).
Active == {r \in Runs : runStatus[r] \in {"queued", "running"}}

\* What the reconcile scan reads: unsettled_job_runs, the active rows and then
\* the rows whose delivery is still pending (repo.ex:2378-2411); without
\* ReconcilesPending, the active rows alone.
Scanned == IF ReconcilesPending
           THEN Active \cup {r \in Runs : delivery[r] = "pending"}
           ELSE Active

JobRow == [en |-> jobEnabled, st |-> jobState, next |-> nextRun]

\* The settle's job release (release_settled_job, repo.ex:6136-6161): one
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

\* A run id can be reused once nothing refers to it any more, a stray loop
\* still running that run included.
Reusable(r) ==
    \/ runStatus[r] = "absent"
    \/ /\ runStatus[r] \in {"ok", "error"}
       /\ delivery[r] \in Final \cup {"unset"}
       /\ pc[r] \in {"off", "gone"}
       /\ helper[r] = "none"
       /\ r \notin monitors \cup downs \cup activeSnap \cup reapQ \cup strayLoops
       /\ r /= sRun
FreeIds == {r \in Runs : Reusable(r)}

\* The job_runs row the claim inserts (run_attrs, scheduler.ex:634-646),
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
                   strayLoops, daemonCrashed, schedCrashes, schedTimeouts>>

\* Owner steps leave the Scheduler alone, except for the :job_changed cast.
OwnerQuiet == <<rowVars, runnerVars, helperVars, envVars, sPc, reapReturn, monitors,
                downs, dueTimer, refused, sRun, activeSnap, reapQ, sSnap>>

\* Registry.pause_job (registry.ex:42-44 -> update_job_fields :96-104):
\* Repo.update_scheduled_job_fields writes enabled = false and state =
\* "paused" in place (repo.ex:2312, :6318-6325), then the :job_changed cast
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
\* state, enabled or last_* (repo.ex:6318-6325; the owner field list,
\* :7221-7262): the modelled edit writes no modelled column. Without it, the
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

\* handle_info(:due_tick) (scheduler.ex:201-203): the timer armed at 0 ms or
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

\* handle_info(:reconcile_tick) (scheduler.ex:207-215), armed every 60 s:
\* reconcile, then the same due scan and re-arm as a due tick.
ReconcileFires ==
    /\ sPc = "idle"
    /\ sPc' = IF ReconcilesRuns THEN "r_rows" ELSE "scan"
    /\ reapReturn' = IF ReconcilesRuns THEN "scan" ELSE "idle"
    /\ UNCHANGED <<Quiet, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* handle_cast(:job_changed) (scheduler.ex:196-198): re-arm the due timer.
JobChanged ==
    /\ sPc = "idle"
    /\ changed
    /\ sPc' = "arm"
    /\ changed' = FALSE
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* handle_info({:DOWN, ...}) with an abnormal reason (scheduler.ex:217-228):
\* forget the monitor, then mark_run_crashed -> mark_run_failed (:683-707).
HandleDown(r) ==
    /\ sPc = "idle"
    /\ r \in downs
    /\ sPc' = "r_mark"
    /\ sRun' = r
    /\ downs' = downs \ {r}
    /\ monitors' = monitors \ {r}
    /\ UNCHANGED <<Quiet, reapReturn, changed, dueTimer, refused, activeSnap, reapQ, sSnap>>

\* handle_call({:run_now, ...}) -> manual_run (scheduler.ex:190-193, :480-513).
\* Its Repo.get_scheduled_job lookup is folded into Repo.claim_job_now: the
\* claim transaction re-checks enabled, "scheduled" and (the race-stop) no
\* queued/running run (repo.ex:5999-6004, :6016-6023, :6050-6069), so the
\* fold only drops harmless outcomes (an error reply either way). A manual
\* claim leaves a recurring job's next_run_at alone (manual_claim_patch,
\* scheduler.ex:504, :628-632). With every modelled run id in use, the
\* request is out of the model's bounds and is refused. A Repo call that
\* times out is ManualRunTimeout.
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
\* (scheduler.ex:178-179), the 60 s tick goes on to the due scan (:210-211),
\* a DOWN callback ends (:227).
NextReap(q) ==
    IF q /= {}
    THEN /\ sRun' = Min(q) /\ reapQ' = q \ {Min(q)} /\ sPc' = "r_mark"
         /\ UNCHANGED reapReturn
    ELSE /\ sRun' = 0 /\ reapQ' = {} /\ sPc' = reapReturn
         /\ reapReturn' = "idle"

\* After one run is reaped. A DOWN callback has no queue, so it ends.
AfterReap == NextReap(reapQ)

\* reconcile_active_runs: Repo.unsettled_job_runs (scheduler.ex:243), the
\* queued/running rows and the rows whose delivery is pending (Scanned). A
\* scan that times out is ReconcileRowsTimeout.
ReconcileRows ==
    /\ sPc = "r_rows"
    /\ activeSnap' = Scanned
    /\ sPc' = "r_live"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   reapQ, sSnap>>

\* live_runner_pids: DynamicSupervisor.which_children + the run id each
\* runner published in its init (scheduler.ex:245, :291-305; runner.ex:164).
\* Live runs are adopted: monitored if not already (adopt_live_run, scheduler.ex:266-274;
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
\* :709-735). A queued/running run is settled "error": with AtomicSettle
\* through Repo.settle_job_run, which releases the job in the same write
\* (:713-729); without, an upsert of the run row alone. A run whose delivery
\* is still pending, whatever its status, gets delivery "failed" (:731-733,
\* :752-765). Any other row is left alone.
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

\* mark_run_failed -> mark_run_error (scheduler.ex:690-735): Repo.get_job_run,
\* then the write above. The two calls are one step: once its runner is dead
\* only the Scheduler writes this row, and a runner's timed-out write landed
\* before the get, which was queued after it. For the same reason the
\* settle's :run_not_active branch (:722-724) is unreachable here. A write
\* that times out is this step too: it lands late, before the Scheduler's
\* next Repo call, and its error branch only logs and skips the
\* memory-source mirror (:726-727, :760-763), which is not modelled. A get
\* that times out is ReapLookupTimeout. Without AtomicSettle the code before
\* the fix then wrote the job row (r_read).
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

\* run_due_jobs: Repo.due_scheduled_jobs (scheduler.ex:319-328): enabled,
\* state "scheduled", next_run_at <= now (repo.ex:5933-5960). A scan that
\* times out is ScanTimeout.
Scan ==
    /\ sPc = "scan"
    /\ sPc' = IF jobEnabled /\ jobState = "scheduled" /\ Due THEN "claim" ELSE "arm"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* claim_patched_job -> Repo.claim_due_job (scheduler.ex:454-474): one
\* BEGIN IMMEDIATE transaction (repo.ex:5991-6023) that re-checks the job is
\* due, refuses while a run is queued/running (the race-stop), then sets
\* state "running" with next_run_at advanced (claim_job_patch, scheduler.ex
\* :619-623) and inserts the run "queued". :already_running returns
\* {:busy, state} (:461-465), :not_due {:ok, state}. With every modelled run
\* id in use the claim is out of the model's bounds and behaves like :not_due.
\* A claim that times out is ClaimTimeout.
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

\* start_or_mark_failed (scheduler.ex:603-613): RunnerSupervisor.start_run
\* runs Runner.init synchronously (runner_supervisor.ex:20-23), which
\* publishes the run id (runner.ex:164); then Process.monitor. No Repo call.
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
\* :813-841, repo.ex:5962-5989). A tick whose claim was refused re-arms no
\* sooner than the 5 s backoff (outcome :busy, due_delay_ms, scheduler.ex:886-892) with
\* RefusalBacksOff; without it the refusal counted as a clean drain. After a
\* clean tick an enabled "scheduled" job is armed at its next_run_at, which is
\* 0 ms when it is already due; no such job arms nothing. A lookup that times
\* out is ArmTimeout.
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
(* The Scheduler: a Repo call that times out *)

\* Every Repo call the Scheduler's process makes passes Repo.periodic_opts
\* (scheduler.ex:135-138; repo.ex:1152-1154): a call the Repo does not answer
\* within 5 s returns {:error, :repo_timeout} (repo.ex:3946-3954) and the
\* Scheduler takes that call site's error branch, its monitors and timers
\* intact. The request is not cancelled: it lands later, before the
\* Scheduler's next Repo call, so a write lands in the timeout step itself
\* (see late writes). Each takes one of SchedulerTimeouts. A timed-out
\* write in the reaper is ReapRun, and ReconcileLive and Start make no Repo
\* call; the other call sites follow.
TimeOut ==
    /\ schedTimeouts < SchedulerTimeouts
    /\ schedTimeouts' = schedTimeouts + 1

\* Everything outside the Scheduler but the timeout count.
TimeoutQuiet == <<jobVars, rowVars, runnerVars, helperVars, ownerVars,
                  now, strayLoops, daemonCrashed, schedCrashes>>

\* reconcile_active_runs: Repo.unsettled_job_runs times out (scheduler.ex
\* :248-250). The pass reaps and adopts nothing, and the callback goes on:
\* to the re-arm at init, to the due scan in the 60 s tick. An orphan waits
\* for the next pass; after a restart a live runner stays unmonitored, so if
\* it dies no DOWN arrives and the next pass reaps its run.
ReconcileRowsTimeout ==
    /\ sPc = "r_rows"
    /\ TimeOut
    /\ NextReap({})
    /\ UNCHANGED <<TimeoutQuiet, monitors, downs, changed, dueTimer, refused, activeSnap,
                   sSnap>>

\* mark_run_failed: Repo.get_job_run times out (scheduler.ex:700-703), so the
\* run is not marked and its row keeps its status. After a DOWN the monitor
\* is already gone: a queued/running row holds the job, with no runner and
\* no monitor, until the next reconcile pass reaps it with the generic
\* "reaped: no live runner" text (:51-55, :280-283). In a reconcile pass
\* the orphan waits for the next pass.
ReapLookupTimeout ==
    /\ sPc = "r_mark"
    /\ TimeOut
    /\ AfterReap
    /\ UNCHANGED <<TimeoutQuiet, monitors, downs, changed, dueTimer, refused, activeSnap,
                   sSnap>>

\* run_due_jobs: Repo.due_scheduled_jobs times out (scheduler.ex:324-326).
\* The tick's outcome is :error, so the re-arm floors at the 5 s backoff
\* (:813-850, :886-892). That re-arm is folded in: whatever its own lookup
\* returns, or if it times out too (:837-839), the model arms "backoff",
\* which fires whether or not the job is due. Nothing is written.
ScanTimeout ==
    /\ sPc = "scan"
    /\ TimeOut
    /\ sPc' = "idle"
    /\ dueTimer' = "backoff"
    /\ UNCHANGED <<TimeoutQuiet, reapReturn, monitors, downs, changed, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* claim_patched_job: Repo.claim_due_job times out (scheduler.ex:470-472).
\* The claim transaction still runs when the Repo reaches it, as Claim would
\* run it, but the Scheduler starts no runner and monitors nothing: a claim
\* that lands leaves a queued run with no runner, which holds its job until
\* the next reconcile pass reaps it ("... or a memory store that answered too
\* late", scheduler.ex:51-55). The tick's outcome is :error: the re-arm is
\* folded in as in ScanTimeout.
ClaimTimeout ==
    /\ sPc = "claim"
    /\ TimeOut
    /\ IF /\ jobEnabled /\ jobState = "scheduled" /\ Due /\ FreeIds /= {}
          /\ (Active = {} \/ ~AtomicRaceStop)
       THEN LET r == Min(FreeIds) IN
            /\ NewRun(r)
            /\ jobState' = "running"
            /\ nextRun' = now + 1
            /\ UNCHANGED jobEnabled
       ELSE UNCHANGED <<jobVars, rowVars, runnerVars, helperVars>>
    /\ sPc' = "idle"
    /\ dueTimer' = "backoff"
    /\ UNCHANGED <<ownerVars, now, strayLoops, daemonCrashed, schedCrashes, reapReturn,
                   monitors, downs, changed, refused, sRun, activeSnap, reapQ, sSnap>>

\* next_due_timer: Repo.next_scheduled_job times out (scheduler.ex:835-839):
\* the timer is armed at the backoff whatever the row says.
ArmTimeout ==
    /\ sPc = "arm"
    /\ TimeOut
    /\ dueTimer' = "backoff"
    /\ sPc' = "idle"
    /\ reapReturn' = "idle"
    /\ refused' = FALSE
    /\ UNCHANGED <<TimeoutQuiet, monitors, downs, changed, sRun, activeSnap, reapQ, sSnap>>

\* handle_call({:run_now, ...}) whose lookup (scheduler.ex:481-483) or
\* Repo.claim_job_now (:506-511) times out. A claim that times out still
\* lands when ManualRun's would, with no runner started. Either way the
\* owner is told {:error, :repo_timeout} and the due timer is re-armed, as
\* after any "run now" (:192).
ManualRunTimeout ==
    /\ sPc = "idle"
    /\ manualLeft > 0
    /\ TimeOut
    /\ manualLeft' = manualLeft - 1
    /\ \/ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars>>
       \/ /\ jobEnabled /\ jobState = "scheduled"
          /\ (Active = {} \/ ~AtomicRaceStop)
          /\ FreeIds /= {}
          /\ LET r == Min(FreeIds) IN
             /\ NewRun(r)
             /\ jobState' = "running"
             /\ UNCHANGED <<jobEnabled, nextRun>>
    /\ sPc' = "arm"
    /\ UNCHANGED <<now, strayLoops, daemonCrashed, schedCrashes, oPc, oSnap, intent,
                   movesLeft, editsLeft, reapReturn, monitors, downs, changed, dueTimer,
                   refused, sRun, activeSnap, reapQ, sSnap>>

SchedTimeout ==
    \/ ReconcileRowsTimeout \/ ReapLookupTimeout \/ ScanTimeout \/ ClaimTimeout
    \/ ArmTimeout \/ ManualRunTimeout

-----------------------------------------------------------------------------
(* One Runner (runner.ex), a :temporary child of Jobs.RunnerSupervisor *)

Move(r, s) == pc' = [pc EXCEPT ![r] = s]
RunnerQuiet == <<jobVars, ownerVars, envVars, schedVars>>

\* handle_continue(:run) -> mark_running (runner.ex:170-173, :221-238):
\* Repo.upsert_job_run with status "running".
MarkRunning(r) ==
    /\ pc[r] = "start"
    /\ Move(r, "loop")
    /\ runStatus' = [runStatus EXCEPT ![r] = "running"]
    /\ UNCHANGED <<RunnerQuiet, delivery, resp, finSnap, outcome, helperVars>>

\* The whole AgentLoop, run in a process linked to the runner that the runner
\* watches (runner.ex:196, :966-998): final text, [SILENT], or an
\* error/timeout (a crash of the loop included, reported as a value).
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
\* the same transaction (Repo.settle_job_run, runner.ex:264 / :325).
RunnerWrite(r) ==
    /\ runStatus' = [runStatus EXCEPT ![r] = IF pc[r] = "complete" THEN "ok" ELSE "error"]
    /\ delivery' = [delivery EXCEPT ![r] =
                      IF pc[r] = "complete" /\ resp[r] = "silent" THEN "skipped" ELSE "pending"]
    /\ IF AtomicSettle THEN Release ELSE UNCHANGED jobState
    /\ UNCHANGED <<jobEnabled, nextRun>>

\* The settle's guard (ensure_job_run_active, repo.ex:6123-6130): only a
\* queued/running row may be settled. The split write has no guard.
Settleable(r) == ~AtomicSettle \/ runStatus[r] \in {"queued", "running"}

\* mark_completed (runner.ex:245-267) / mark_failed (:306-330) with
\* AtomicSettle: write output.md or error.md (folded in), then
\* Repo.settle_job_run (repo.ex:2369, :6106-6175): the run row and the job's
\* release in one transaction. After a success the memory write comes next;
\* after a loop error the memory-source update (runner.ex:330, folded in) and then the
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

\* persist_run_summary_memory (runner.ex:209, :269-306): Repo.upsert_memory
\* (skipped for [SILENT]), then the memory-source update (:208, :374-394,
\* whose failures are logged), folded in. No modelled row changes; it is a
\* crash point. With AtomicSettle
\* finalize_delivery (:209, :338-346) follows: a pending delivery spawns the
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

\* mark_delivery (runner.ex:350-372): Repo.upsert_job_run with the result,
\* then {:stop, :normal} (runner.ex:182). The Scheduler's DOWN :normal
\* handler only drops the monitor (scheduler.ex:222-223); it is folded in.
\* A refused write exits the runner with the outcome and its error in its
\* reason (runner.ex:365-371): that is RunnerCrash at "mark".
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
\* kill, a failed {:ok, _} match, or mark_delivery's exit on a refused
\* write, runner.ex:365-371). A failed output.md/error.md write also
\* kills it ({:ok, _} match, runner.ex:247, :313); that write is folded into
\* the final write, so it is the crash at "complete"/"fail". The
\* memory-source calls after the split job upsert are a crash point with no
\* pc of their own: a crash there leaves the rows a crash at "mark" leaves,
\* minus the send. It raises nowhere while it waits on a send. While it
\* waits on its loop, the loop reports its own crash as a value
\* (runner.ex:1000-1017); the one death left there, a process the loop links
\* to itself killing the loop and through the link the runner, leaves the
\* rows the Loop step and then a crash at "complete" or "fail" leave, so it
\* needs no step of its own. Its supervisor does not restart it
\* (restart: :temporary, runner.ex:117); a Scheduler that monitors it gets a
\* DOWN.
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

\* The runner's final write times out: GenServer.call exits the runner, which
\* passes no on_timeout (repo.ex:3936-3944), but the request stays in the
\* Repo's mailbox and lands.
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

\* The runner's own delivery timer (delivery_timeout_ms, runner.ex:1316):
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

\* The Scheduler (re)starts: init reconciles, then arms (scheduler.ex:128-183).
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

\* The Scheduler dies alone, at any point of any callback, and the call it
\* waited on never lands. A Repo call that times out no longer kills it
\* (the timeout steps above); another cause still does, such as
\* :rest_for_one restarting it when the MeetingsSupervisor started between
\* the RunnerSupervisor and it dies (application.ex:231-238), or a raise in
\* its own code. FermixCore.Supervisor is :rest_for_one and starts
\* JobRunnerSupervisor before JobScheduler (application.ex:231, :238, :270),
\* so the restart leaves every runner running.
SchedulerCrash ==
    /\ schedCrashes < SchedulerCrashes
    /\ schedCrashes' = schedCrashes + 1
    /\ SchedRestart
    /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, ownerVars, now, strayLoops,
                   daemonCrashed, schedTimeouts>>

\* The Scheduler dies of such a cause while it waits on the reaper's write,
\* and the write still lands (repo.ex:3931-3935). With AtomicSettle that is
\* the whole settle; without, the run row alone, and the job write never
\* happens.
SchedulerCrashLate ==
    /\ sPc = "r_mark"
    /\ schedCrashes < SchedulerCrashes
    /\ schedCrashes' = schedCrashes + 1
    /\ ReapWrite(sRun)
    /\ SchedRestart
    /\ UNCHANGED <<runnerVars, helperVars, ownerVars, now, strayLoops, daemonCrashed,
                   schedTimeouts>>

\* The daemon dies: every process with it (runners, send helpers, the
\* owner's request in flight). Only SQLite rows and what the platform took
\* survive. On boot the Scheduler's init reconciles. The same step stands for
\* a restart of the job subtree, which the loop of a runner inside its
\* AgentLoop outlives unless it is linked to that runner (LoopDiesWithRunner,
\* runner.ex:984-988; spawn_monitor before JOB-8's fix).
DaemonCrash ==
    /\ DaemonCanCrash /\ ~daemonCrashed
    /\ daemonCrashed' = TRUE
    /\ pc' = [r \in Runs |-> IF Alive(r) THEN "gone" ELSE pc[r]]
    /\ strayLoops' = IF LoopDiesWithRunner THEN strayLoops
                     ELSE strayLoops \cup {r \in Runs : pc[r] = "loop"}
    /\ resp' = [r \in Runs |-> "-"]
    /\ finSnap' = [r \in Runs |-> NoSnap]
    /\ outcome' = [r \in Runs |-> "-"]
    /\ helper' = [r \in Runs |-> "none"]
    /\ tries' = [r \in Runs |-> 0]
    /\ oPc' = "idle"
    /\ oSnap' = NoSnap
    /\ SchedRestart
    /\ UNCHANGED <<jobVars, rowVars, delivered, intent, movesLeft, editsLeft, manualLeft,
                   now, schedCrashes, schedTimeouts>>

\* A stray loop ends: max_iterations, a provider error, or the real daemon
\* dying. It writes nothing: its runner is gone, so its answer reaches no
\* one. No fairness: nothing in Fermix bounds when.
StrayLoopEnds(r) ==
    /\ r \in strayLoops
    /\ strayLoops' = strayLoops \ {r}
    /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, schedVars, ownerVars, now,
                   daemonCrashed, schedCrashes, schedTimeouts>>

-----------------------------------------------------------------------------
Init ==
    /\ jobEnabled = TRUE
    /\ jobState = "scheduled"
    /\ nextRun = 1
    /\ runStatus = [r \in Runs |-> "absent"]
    /\ delivery = [r \in Runs |-> "unset"]
    /\ now = 0
    /\ strayLoops = {}
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
    /\ schedTimeouts = 0

\* The legitimate end: the clock at its horizon, no runner, stray loop or
\* send helper alive, the owner done, and an idle Scheduler with an empty
\* mailbox. The Scheduler's 60 s reconcile timer is always armed, so it
\* always has a next step: a wedge shows up as a broken liveness property,
\* not as a deadlock.
Done ==
    /\ now = Fires
    /\ \A r \in Runs : ~Alive(r) /\ helper[r] = "none"
    /\ strayLoops = {}
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
    \/ SchedTimeout
    \/ SchedulerCrash \/ SchedulerCrashLate \/ DaemonCrash \/ \E r \in Runs : StrayLoopEnds(r)
    \/ Terminated

\* Fermix drives these itself: a live runner's and send helper's next step,
\* the runner's delivery timer, the Scheduler's steps inside a callback
\* (weak fairness), and the Scheduler serving its mailbox and its own timers
\* (strong fairness: a message that keeps finding the Scheduler idle is
\* eventually handled). The clock, the owner, the platform's answers and
\* every crash and Repo timeout get no fairness.
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

\* scheduler.ex:487-491: "a job mid-run carries state 'running' (the claim
\* sets it atomically) ... The in-transaction `ensure_no_active_job_run`
\* guard (shared with the due path) remains the atomic race-stop
\* underneath." Read as: at most one run of the job is active, counting a
\* queued/running row, a runner still before or inside its AgentLoop, or an
\* AgentLoop that outlived its runner.
OneActiveRun ==
    Cardinality({r \in Runs : runStatus[r] \in {"queued", "running"}
                              \/ pc[r] \in {"start", "loop"}
                              \/ r \in strayLoops}) <= 1

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

\* scheduler.ex:30-35: a due tick that cannot drain its work, including "a
\* due job whose previous run is still active", re-arms no sooner than the
\* backoff, "so a persistently past-due-but-unclaimable job can never spin
\* the scheduler at 0ms"; :880-884 says it again. Read as an action rule: the
\* Arm step that ends a callback whose claim was refused as :already_running
\* never arms the 0 ms timer. (Arm and ArmTimeout, which arms the backoff,
\* are the only steps from "arm" to "idle".)
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

\* A claim whose call timed out landed: its run is queued with no runner
\* ever started, while the Scheduler, never restarted, is idle. Only a
\* reconcile pass releases the job.
Witness_ClaimWithoutRunner ==
    ~(\E r \in Runs :
        /\ runStatus[r] = "queued" /\ pc[r] = "off"
        /\ sPc = "idle" /\ schedCrashes = 0 /\ ~daemonCrashed)

\* A runner died and the run lookup in its DOWN's handler timed out: its run
\* still holds the job, unmonitored, with no DOWN left to handle, while the
\* Scheduler, never restarted, is idle. Only a reconcile pass releases it.
Witness_CrashLeftUnmarked ==
    ~(\E r \in Runs :
        /\ runStatus[r] \in {"queued", "running"} /\ pc[r] = "gone"
        /\ r \notin monitors \cup downs
        /\ sPc = "idle" /\ schedCrashes = 0 /\ ~daemonCrashed)

=============================================================================
