----------------------------- MODULE JobRuns -----------------------------
(***************************************************************************)
(* FermixCore.Jobs for ONE recurring job: the Scheduler's due tick and its  *)
(* atomic claim, one Runner per run (a :temporary GenServer), the delivery  *)
(* of the run's final text through a watchdog-bounded send helper, the     *)
(* Scheduler's monitors and its reconciliation pass (at init and every 60  *)
(* s), a Runner crash, a Scheduler-only crash, a daemon crash followed by  *)
(* boot reconciliation, and the owner's pause, resume and "run now".       *)
(*                                                                         *)
(* Time: `now` counts the fire times that have passed and `nextRun` is the *)
(* job row's next_run_at, as the index of a fire time. The job is due when *)
(* nextRun <= now. A claim or a resume sets next_run_at to the next future *)
(* occurrence (now + 1).                                                   *)
(*                                                                         *)
(* Not modelled: the AgentLoop and its own watchdog and transient retry    *)
(* (one "loop" step that ends in text, [SILENT] or an error); media sends; *)
(* other jobs; one-shot ("once") jobs, expiry, an unparseable schedule and *)
(* the stale-skip of a due time older than the freshness window; owner     *)
(* edits (update_job) and removal; SQLite busy or errors (every Repo call  *)
(* succeeds unless its caller dies); the admission ceiling (four runs; one *)
(* job never has more than two runner processes, so :busy never happens);  *)
(* delivery_mode "none"/"local" (they behave like a [SILENT] result: final *)
(* at once); memory-source rows, telemetry, the start-up stagger and the   *)
(* network-readiness wait.                                                 *)
(*                                                                         *)
(* Folded steps (each fold is argued where it happens):                    *)
(*  - the output artifact file write joins the Repo write after it;        *)
(*  - the memory-source get + upsert joins the job upsert before it;       *)
(*  - resume's read joins its write; "run now"'s lookup joins its claim;   *)
(*  - the reaper's get_job_run + upsert_job_run are one step;              *)
(*  - starting a runner and monitoring it are one step, and so are         *)
(*    reading the live runners and monitoring the ones adopted;            *)
(*  - a runner's normal exit also pops its monitor (DOWN :normal).         *)
(*                                                                         *)
(* Run ids are reused once a run is fully finished, so two ids model an    *)
(* unbounded run history. A daemon crash also stands for a Memory.Repo or  *)
(* RunnerSupervisor crash: under :rest_for_one either one restarts the     *)
(* RunnerSupervisor with its linked runners and the Scheduler. Two         *)
(* processes are not linked and would survive it: the send helper         *)
(* (spawn_monitor, channel_send.ex:205) and the AgentLoop process          *)
(* (runner.ex:1024). The fold kills them too. That is harmless for the     *)
(* properties: a surviving helper can land at most one more copy of the    *)
(* final text, which no row records. Process-local values a step no longer *)
(* needs are cleared, so that dead values do not multiply the states.      *)
(*                                                                         *)
(* Runner steps (pc[r]), each named after the action that takes it:        *)
(*   off -Start-> start -MarkRunning-> loop -Loop-> complete | fail        *)
(*   complete -MarkCompleted-> memo -Memory-> finread                      *)
(*   fail -MarkFailed-> finread -FinRead-> finwrite                        *)
(*   finwrite -FinWrite-> await (a pending send) | mark (nothing to send)  *)
(*   await -GotResult or Watchdog-> mark -MarkDelivery-> gone              *)
(*   start, complete, memo, fail, finread, finwrite, mark -RunnerCrash->   *)
(*   gone                                                                  *)
(* Scheduler steps (sPc), from idle:                                       *)
(*   idle -DueTimerFires-> scan    idle -ReconcileFires-> r_rows           *)
(*   idle -JobChanged-> arm        idle -HandleDown-> r_mark               *)
(*   idle -ManualRun-> start | arm                                         *)
(*   r_rows -ReconcileRows-> r_live -ReconcileLive-> r_mark | reapReturn   *)
(*   r_mark -ReapRun-> r_read | (next orphan or reapReturn)                *)
(*   r_read -ReapReadJob-> r_write -ReapWriteJob-> (next orphan or         *)
(*   reapReturn)                                                           *)
(*   scan -Scan-> claim | arm   claim -Claim-> start | arm                 *)
(*   start -Start-> arm         arm -Arm-> idle                            *)
(* reapReturn is where the Scheduler goes once its reaping is done: "arm"  *)
(* after init, "scan" in the 60 s tick, "idle" after a DOWN.               *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/scheduler.ex @ 1e942183055a
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/runner.ex @ e3e19e979178
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/runner_supervisor.ex @ 6a21dfe6cfad
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/delivery.ex @ 4eb42c517b57
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/registry.ex @ 28835c6acffd
\* SOURCE: apps/fermix_core/lib/fermix_core/delivery/channel_send.ex @ f3d4fbac434a
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#call,claim_due_job,claim_job_now,claim_due_job_tx,claim_in_tx,claim_job_now_tx,ensure_no_active_job_run,fetch_claimable_job,active_job_runs,fetch_active_job_runs,due_scheduled_jobs,fetch_due_scheduled_jobs,next_scheduled_job,fetch_next_scheduled_job,upsert_job_run,upsert_scheduled_job,get_job_run,get_scheduled_job,upsert_memory @ 1bf78ac61970
\* SOURCE: apps/fermix_core/lib/fermix_core/application.ex#start_supervision_tree,jobs_scheduler_opts @ 06fbd1afd4cc
EXTENDS Naturals, FiniteSets

CONSTANTS
    \* Bounds.
    NumRuns,            \* run ids, e.g. 2 (reused once a run is fully finished)
    Fires,              \* fire times the clock passes through, e.g. 2
    SendAttempts,       \* ChannelSend attempts per delivery (the code uses 3)
    OwnerMoves,         \* pause/resume requests the owner may make
    ManualRuns,         \* "run now" requests the owner may make
    \* Environment switches: what may happen.
    DaemonCanCrash,     \* the daemon dies once (every process) and boots again
    SchedulerCrashes,   \* how many times the Scheduler alone may die, e.g. on a 5 s
                        \* GenServer.call timeout to the Repo (repo.ex:3623-3626)
    RunnerCanCrash,     \* a runner dies at one of its Repo calls (a timeout, a failed match)
    LoopCanFail,        \* the AgentLoop ends in an error or a timeout
    PlatformCanFail,    \* a send fails: no connection, or an error after the platform took it
    ResponsesCanStall,  \* the platform takes a message and its answer never arrives in time;
                        \* with DeliveryWatchdog off the wait is unbounded (the adapters'
                        \* own HTTP timeouts are outside the sources)
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by exactly one check to show a property needs it.
    AtomicRaceStop,           \* the claim refuses while a run is queued/running (repo.ex:5561, :5614-5631)
    RetriesOnlyUnsent,        \* a send is retried only when it never reached the platform (channel_send.ex:126-129, :180-188);
                              \* the mechanism for platforms that do not dedupe on the run's proactive_key
    ReconcilesRuns,           \* init and every 60 s reap orphaned runs, adopt live runners (scheduler.ex:167, :196-270)
    CrashFailsPendingDelivery,\* a dead runner's ok/pending delivery is marked failed (scheduler.ex:686-687, :711-719)
    DeliveryWatchdog          \* the runner stops waiting for a send after delivery_timeout_ms (channel_send.ex:200-219)

Runs == 1..NumRuns

VARIABLES
    \* --- SQLite rows (survive every crash) ---
    jobEnabled,  \* scheduled_jobs.enabled
    jobState,    \* scheduled_jobs.state: "scheduled" | "running" | "paused"
    nextRun,     \* scheduled_jobs.next_run_at, as a fire-time index
    runStatus,   \* runStatus[r]: job_runs.status ("absent" = no row for this id yet)
    delivery,    \* delivery[r]: job_runs.delivery_status; "unset" is the "none" the claim
                 \* writes before a result exists (scheduler.ex:616), kept apart from the
                 \* final "none" of delivery_mode "none" (modelled as "skipped")
    \* --- the environment ---
    now,         \* fire times that have passed (the wall clock)
    \* --- each Runner process (process-local, per run) ---
    pc,          \* pc[r]: where the runner of r is; "off" = never started, "gone" = dead
    resp,        \* resp[r]: the AgentLoop's final text: "text" or "silent" ([SILENT])
    finSnap,     \* finSnap[r]: the job row finalize_job read (runner.ex:358 / :411)
    outcome,     \* outcome[r]: the delivery result the runner will record
    \* --- the delivery helper each runner spawns (channel_send.ex:204) ---
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
    refused,     \* this callback's claim returned :already_running
    sRun,        \* the run this callback is starting or reaping (0 = none)
    activeSnap,  \* the queued/running rows its reconcile scan read
    reapQ,       \* runs its reconcile pass still has to reap
    sSnap,       \* the job row its reaper read (scheduler.ex:735 / :772)
    \* --- the owner (through the pause_job / resume_job / run_job_now tools) ---
    oPc,         \* "idle" | "pausing" (pause read the row, its write is pending)
    oSnap,       \* next_run_at as pause read it
    intent,      \* the owner's last pause/resume, as acknowledged to them
    movesLeft,   \* pause/resume requests left
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
ownerVars  == <<oPc, oSnap, intent, movesLeft, manualLeft>>
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
    /\ dueTimer \in {"none", "zero", "later"}
    /\ refused \in BOOLEAN
    /\ sRun \in 0..NumRuns
    /\ activeSnap \subseteq Runs /\ reapQ \subseteq Runs
    /\ sSnap \in Snaps
    /\ oPc \in {"idle", "pausing"}
    /\ oSnap \in 0..(Fires + 1)
    /\ intent \in {"none", "paused", "resumed"}
    /\ movesLeft \in 0..OwnerMoves /\ manualLeft \in 0..ManualRuns
    /\ daemonCrashed \in BOOLEAN /\ schedCrashes \in 0..SchedulerCrashes

-----------------------------------------------------------------------------
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

Due == nextRun <= now
Alive(r) == pc[r] \notin {"off", "gone"}

\* Rows that hold an active slot: what ensure_no_active_job_run counts
\* (repo.ex:5614-5631) and what the reconcile scan reads (repo.ex:5900-5915).
Active == {r \in Runs : runStatus[r] \in {"queued", "running"}}

JobRow == [en |-> jobEnabled, st |-> jobState, next |-> nextRun]

\* The job upsert every read-then-write path does: the whole row from its
\* earlier read, with final_job_state/failed_job_state/completed_job_state
\* applied (runner.ex:385, scheduler.ex:768, :803): "running" becomes
\* "scheduled" for a recurring job, anything else is kept.
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

\* The job_runs row the claim inserts (run_attrs, scheduler.ex:608-620),
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

\* Registry.pause_job -> update_job_state (registry.ex:42-44, :93-97): first
\* Repo.get_scheduled_job ...
PauseRead ==
    /\ oPc = "idle" /\ movesLeft > 0
    /\ oPc' = "pausing"
    /\ oSnap' = nextRun
    /\ movesLeft' = movesLeft - 1
    /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, schedVars,
                   intent, manualLeft, envVars>>

\* ... then update_existing_job_state (registry.ex:99-106): upsert the row it
\* read with enabled = false, state = "paused" (next_run_at as read), then
\* the :job_changed cast (:345-350). The owner is told "paused".
PauseWrite ==
    /\ oPc = "pausing"
    /\ jobEnabled' = FALSE
    /\ jobState' = "paused"
    /\ nextRun' = oSnap
    /\ changed' = TRUE
    /\ intent' = "paused"
    /\ oPc' = "idle"
    /\ oSnap' = 0
    /\ UNCHANGED <<rowVars, runnerVars, helperVars, movesLeft, manualLeft, envVars,
                   sPc, reapReturn, monitors, downs, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* Registry.resume_job (registry.ex:47-59): get the row, then upsert it with
\* enabled = true, state = "scheduled" and next_run_at = the next future
\* occurrence, whatever state the job is in (nothing checks that it is
\* paused), then the :job_changed cast. The read is folded into the write:
\* every modelled field of the write comes from the patch, none from the read.
Resume ==
    /\ oPc = "idle" /\ movesLeft > 0
    /\ jobEnabled' = TRUE
    /\ jobState' = "scheduled"
    /\ nextRun' = now + 1
    /\ changed' = TRUE
    /\ intent' = "resumed"
    /\ movesLeft' = movesLeft - 1
    /\ UNCHANGED <<rowVars, runnerVars, helperVars, oPc, oSnap, manualLeft, envVars,
                   sPc, reapReturn, monitors, downs, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap>>

-----------------------------------------------------------------------------
(* The Scheduler: callbacks that start when it is idle *)

\* Every callback below starts from an idle Scheduler. An idle Scheduler has
\* reapReturn "idle", refused FALSE, sRun 0 and empty reconcile locals.
Quiet == <<jobVars, rowVars, runnerVars, helperVars, ownerVars, envVars>>

\* handle_info(:due_tick) (scheduler.ex:190-192): the timer armed at 0 ms,
\* or the one armed for next_run_at once that time has come.
DueTimerFires ==
    /\ sPc = "idle"
    /\ dueTimer = "zero" \/ (dueTimer = "later" /\ Due)
    /\ sPc' = "scan"
    /\ dueTimer' = "none"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* handle_info(:reconcile_tick) (scheduler.ex:196-204), armed every 60 s:
\* reconcile, then the same due scan and re-arm as a due tick.
ReconcileFires ==
    /\ sPc = "idle"
    /\ sPc' = IF ReconcilesRuns THEN "r_rows" ELSE "scan"
    /\ reapReturn' = IF ReconcilesRuns THEN "scan" ELSE "idle"
    /\ UNCHANGED <<Quiet, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* handle_cast(:job_changed) (scheduler.ex:185-187): re-arm the due timer.
JobChanged ==
    /\ sPc = "idle"
    /\ changed
    /\ sPc' = "arm"
    /\ changed' = FALSE
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* handle_info({:DOWN, ...}) with an abnormal reason (scheduler.ex:206-217):
\* forget the monitor, then mark_run_crashed -> mark_run_failed (:657-679).
HandleDown(r) ==
    /\ sPc = "idle"
    /\ r \in downs
    /\ sPc' = "r_mark"
    /\ sRun' = r
    /\ downs' = downs \ {r}
    /\ monitors' = monitors \ {r}
    /\ UNCHANGED <<Quiet, reapReturn, changed, dueTimer, refused, activeSnap, reapQ, sSnap>>

\* handle_call({:run_now, ...}) -> manual_run (scheduler.ex:179-182, :463-496).
\* Its Repo.get_scheduled_job lookup is folded into Repo.claim_job_now: the
\* claim transaction re-checks enabled, "scheduled" and (the race-stop) no
\* queued/running run (repo.ex:5542-5547, :5559-5566, :5593-5612), so the
\* fold only drops harmless outcomes (an error reply either way). A manual
\* claim leaves next_run_at alone (scheduler.ex:487). With every modelled
\* run id in use, the request is out of the model's bounds and is refused.
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
    /\ UNCHANGED <<envVars, oPc, oSnap, intent, movesLeft, reapReturn, monitors, downs,
                   changed, dueTimer, refused, activeSnap, reapQ, sSnap>>

-----------------------------------------------------------------------------
(* The Scheduler: steps inside a callback, one Repo call each *)

\* Take the next orphan to reap, or go to reapReturn: init only re-arms
\* (scheduler.ex:167-168), the 60 s tick goes on to the due scan (:199-200),
\* a DOWN callback ends (:216).
NextReap(q) ==
    IF q /= {}
    THEN /\ sRun' = Min(q) /\ reapQ' = q \ {Min(q)} /\ sPc' = "r_mark"
         /\ UNCHANGED reapReturn
    ELSE /\ sRun' = 0 /\ reapQ' = {} /\ sPc' = reapReturn
         /\ reapReturn' = "idle"

\* After one run is reaped. A DOWN callback has no queue, so it ends.
AfterReap == NextReap(reapQ)

\* reconcile_active_runs: Repo.active_job_runs (scheduler.ex:230), the
\* queued/running rows (repo.ex:5900-5915).
ReconcileRows ==
    /\ sPc = "r_rows"
    /\ activeSnap' = Active
    /\ sPc' = "r_live"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   reapQ, sSnap>>

\* live_runner_pids: DynamicSupervisor.which_children + the run id each
\* runner published in its init (scheduler.ex:232, :278-289; runner.ex:157).
\* Live runs are adopted: monitored if not already (adopt_live_run, :253-261;
\* the monitor call is folded in: monitoring a pid that just died delivers
\* DOWN at once, the same outcome as reaping it). The rest are orphans.
ReconcileLive ==
    /\ sPc = "r_live"
    /\ LET live == {r \in Runs : Alive(r)} IN
       /\ monitors' = monitors \cup (activeSnap \cap live)
       /\ activeSnap' = {}
       /\ NextReap(activeSnap \ live)
    /\ UNCHANGED <<Quiet, downs, changed, dueTimer, refused, sSnap>>

\* mark_run_failed -> mark_run_error (scheduler.ex:664-698): Repo.get_job_run
\* then Repo.upsert_job_run. The two calls are one step here: once its
\* runner is dead only the Scheduler writes this row, and the Scheduler is
\* one process. A queued/running run becomes "error" (:683-684, :700-709); an
\* ok/pending run gets delivery "failed" (:686-687, :711-719); any other row
\* is left alone and the job row is not touched (:689-690, :674-675).
ReapRun ==
    /\ sPc = "r_mark"
    /\ LET r == sRun IN
       IF runStatus[r] \in {"queued", "running"}
       THEN /\ runStatus' = [runStatus EXCEPT ![r] = "error"]
            /\ sPc' = "r_read"
            /\ UNCHANGED <<delivery, sRun, reapQ, reapReturn>>
       ELSE IF CrashFailsPendingDelivery /\ runStatus[r] = "ok" /\ delivery[r] = "pending"
       THEN /\ delivery' = [delivery EXCEPT ![r] = "failed"]
            /\ sPc' = "r_read"
            /\ UNCHANGED <<runStatus, sRun, reapQ, reapReturn>>
       ELSE /\ UNCHANGED rowVars
            /\ AfterReap
    /\ UNCHANGED <<jobVars, runnerVars, helperVars, ownerVars, envVars,
                   monitors, downs, changed, dueTimer, refused, activeSnap, sSnap>>

\* mark_job_error / mark_job_completed_after_delivery_crash, first half:
\* Repo.get_scheduled_job (scheduler.ex:772 / :735).
ReapReadJob ==
    /\ sPc = "r_read"
    /\ sSnap' = JobRow
    /\ sPc' = "r_write"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ>>

\* ... second half: Repo.upsert_scheduled_job of the row it read, "running"
\* -> "scheduled" (scheduler.ex:774-782 / :737-745; the memory-source update
\* after it is folded in).
ReapWriteJob ==
    /\ sPc = "r_write"
    /\ WriteBack(sSnap)
    /\ sSnap' = NoSnap
    /\ AfterReap
    /\ UNCHANGED <<rowVars, runnerVars, helperVars, ownerVars, envVars,
                   monitors, downs, changed, dueTimer, refused, activeSnap>>

\* run_due_jobs: Repo.due_scheduled_jobs (scheduler.ex:305-314): enabled,
\* state "scheduled", next_run_at <= now (repo.ex:5476-5503).
Scan ==
    /\ sPc = "scan"
    /\ sPc' = IF jobEnabled /\ jobState = "scheduled" /\ Due THEN "claim" ELSE "arm"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap>>

\* claim_patched_job -> Repo.claim_due_job (scheduler.ex:440-457): one
\* BEGIN IMMEDIATE transaction (repo.ex:5534-5566) that re-checks the job is
\* due, refuses while a run is queued/running (the race-stop), then sets
\* state "running" with next_run_at advanced (claim_job_patch, scheduler.ex
\* :602-606) and inserts the run "queued". :not_due and :already_running
\* both return {:ok, state} (:447-451), so the tick's outcome stays :ok.
\* With every modelled run id in use the claim is out of the model's
\* bounds and behaves like :not_due.
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

\* start_or_mark_failed (scheduler.ex:586-596): RunnerSupervisor.start_run
\* runs Runner.init synchronously (runner_supervisor.ex:20-23), which
\* publishes the run id (runner.ex:157); then Process.monitor.
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
\* :857-885, repo.ex:5505-5532). An enabled "scheduled" job is armed at its
\* next_run_at, which is 0 ms when it is already due and the tick was :ok
\* (due_delay_ms, :929-936); no such job and a clean tick arm nothing.
ArmsZero == jobEnabled /\ jobState = "scheduled" /\ Due

Arm ==
    /\ sPc = "arm"
    /\ dueTimer' = IF jobEnabled /\ jobState = "scheduled"
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

\* handle_continue(:run) -> mark_running (runner.ex:163-166, :214-231):
\* Repo.upsert_job_run with status "running".
MarkRunning(r) ==
    /\ pc[r] = "start"
    /\ Move(r, "loop")
    /\ runStatus' = [runStatus EXCEPT ![r] = "running"]
    /\ UNCHANGED <<RunnerQuiet, delivery, resp, finSnap, outcome, helperVars>>

\* The whole AgentLoop, run in a spawned process the runner watches
\* (runner.ex:189, :1014-1036): final text, [SILENT], or an error/timeout.
Loop(r) ==
    /\ pc[r] = "loop"
    /\ \/ \E res \in {"text", "silent"} :
             /\ resp' = [resp EXCEPT ![r] = res]
             /\ Move(r, "complete")
       \/ /\ LoopCanFail
          /\ Move(r, "fail")
          /\ UNCHANGED resp
    /\ UNCHANGED <<RunnerQuiet, rowVars, finSnap, outcome, helperVars>>

\* mark_completed (runner.ex:199, :233-255): write output.md (folded in),
\* then Repo.upsert_job_run: status "ok", delivery "pending", or "skipped"
\* for [SILENT] (Delivery.initial_status, delivery.ex:24-31).
MarkCompleted(r) ==
    /\ pc[r] = "complete"
    /\ Move(r, "memo")
    /\ runStatus' = [runStatus EXCEPT ![r] = "ok"]
    /\ delivery' = [delivery EXCEPT ![r] = IF resp[r] = "silent" THEN "skipped" ELSE "pending"]
    /\ resp' = [resp EXCEPT ![r] = "-"]
    /\ UNCHANGED <<RunnerQuiet, finSnap, outcome, helperVars>>

\* persist_run_summary_memory (runner.ex:202, :257-294): Repo.upsert_memory
\* (skipped for [SILENT]). No modelled row changes; it is a crash point.
Memory(r) ==
    /\ pc[r] = "memo"
    /\ Move(r, "finread")
    /\ UNCHANGED <<RunnerQuiet, rowVars, resp, finSnap, outcome, helperVars>>

\* mark_failed (runner.ex:207-210, :296-319): write error.md (folded in),
\* then Repo.upsert_job_run: status "error", delivery "pending" for the
\* failure text.
MarkFailed(r) ==
    /\ pc[r] = "fail"
    /\ Move(r, "finread")
    /\ runStatus' = [runStatus EXCEPT ![r] = "error"]
    /\ delivery' = [delivery EXCEPT ![r] = "pending"]
    /\ UNCHANGED <<RunnerQuiet, resp, finSnap, outcome, helperVars>>

\* finalize_job / finalize_failed_job, first half: Repo.get_scheduled_job
\* (runner.ex:358 / :411).
FinRead(r) ==
    /\ pc[r] = "finread"
    /\ Move(r, "finwrite")
    /\ finSnap' = [finSnap EXCEPT ![r] = JobRow]
    /\ UNCHANGED <<RunnerQuiet, rowVars, resp, outcome, helperVars>>

\* ... second half: Repo.upsert_scheduled_job of the row it read, with
\* final_job_state applied (runner.ex:360-370 / :413-423, :381-387; the
\* memory-source update after it is folded in). Then finalize_delivery
\* (runner.ex:204, :321-329): a pending delivery spawns the monitored send
\* helper (Delivery.deliver_with_timeout -> ChannelSend.with_timeout,
\* delivery.ex:53-78, channel_send.ex:200-205); a skipped one is immediate.
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

\* The watchdog's receive gets the helper's result (channel_send.ex:207-210).
GotResult(r) ==
    /\ pc[r] = "await"
    /\ helper[r] \in {"ok", "err"}
    /\ outcome' = [outcome EXCEPT ![r] = IF helper[r] = "ok" THEN "sent" ELSE "failed"]
    /\ helper' = [helper EXCEPT ![r] = "none"]
    /\ Move(r, "mark")
    /\ UNCHANGED <<RunnerQuiet, rowVars, resp, finSnap, tries, delivered>>

\* mark_delivery (runner.ex:331-353): Repo.upsert_job_run with the result,
\* then {:stop, :normal} (runner.ex:175). The Scheduler's DOWN :normal
\* handler only drops the monitor (scheduler.ex:211-212); it is folded in.
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
    \/ MarkRunning(r) \/ Loop(r) \/ MarkCompleted(r) \/ Memory(r) \/ MarkFailed(r)
    \/ FinRead(r) \/ FinWrite(r) \/ GotResult(r) \/ MarkDelivery(r)

\* The runner dies at one of its Repo calls (a GenServer.call timeout exits
\* it, a failed {:ok, _} match or finalize_job's raise, runner.ex:370, :377).
\* A failed output.md/error.md write also kills it ({:ok, _} match,
\* runner.ex:235, :299); that write is folded into MarkCompleted/MarkFailed,
\* so it is the crash at "complete"/"fail". The memory-source calls after the
\* job upsert (runner.ex:371, :424) are a crash point with no pc of its own:
\* a crash there leaves the rows a crash at "mark" leaves, minus the send.
\* It raises nowhere while it waits in receive (the loop or a send). Its
\* supervisor does not restart it (restart: :temporary, runner.ex:111); a
\* Scheduler that monitors it gets a DOWN.
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

-----------------------------------------------------------------------------
(* The send helper and the platform (ChannelSend.send, run_send) *)

\* One send attempt (channel_send.ex:121-135, :176-196). The platform takes
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

\* The runner's own delivery timer (delivery_timeout_ms, runner.ex:1303):
\* no result yet, so it kills the helper and returns {:error,
\* :delivery_timeout} (channel_send.ex:214-218). It cannot tell whether the
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

\* The Scheduler (re)starts: init reconciles, then arms (scheduler.ex:123-172).
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
\* timeout exits it wherever it waits). FermixCore.Supervisor is :rest_for_one and
\* starts JobRunnerSupervisor before JobScheduler (application.ex:220, :227,
\* :259), so the restart leaves every runner running.
SchedulerCrash ==
    /\ schedCrashes < SchedulerCrashes
    /\ schedCrashes' = schedCrashes + 1
    /\ SchedRestart
    /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, ownerVars, now, daemonCrashed>>

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
    /\ oSnap' = 0
    /\ SchedRestart
    /\ UNCHANGED <<jobVars, rowVars, delivered, intent, movesLeft, manualLeft,
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
    /\ oSnap = 0
    /\ intent = "none"
    /\ movesLeft = OwnerMoves
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
    \/ Tick \/ PauseRead \/ PauseWrite \/ Resume \/ ManualRun
    \/ DueTimerFires \/ ReconcileFires \/ JobChanged \/ \E r \in Runs : HandleDown(r)
    \/ SchedStep
    \/ \E r \in Runs : RunnerStep(r) \/ HelperSend(r) \/ Watchdog(r) \/ RunnerCrash(r)
    \/ SchedulerCrash \/ DaemonCrash
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

\* scheduler.ex:470-474: "a job mid-run carries state 'running' (the claim
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

\* channel_send.ex:10-12: "a spawn-monitor with_timeout/2 watchdog so a slow
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

\* scheduler.ex:29-32: a due tick that cannot drain its work re-arms no
\* sooner than the backoff, "so a persistently past-due-but-unclaimable job
\* can never spin the scheduler at 0ms"; :924-926 says it again. Read as:
\* after a claim refused as :already_running, the re-arm is not at 0 ms.
\* Claim refuses only when the job is enabled, "scheduled" and due, which is
\* exactly ArmsZero, so this rule reduces to "no due claim is ever refused
\* as :already_running": any reachable refusal breaks it. The code re-arms
\* in the same callback from next_scheduled_job (scheduler.ex:871-885).
NoZeroRearmAfterRefusal == (sPc = "arm" /\ refused) => ~ArmsZero

\* Proposed rule: a delivery recorded as failed did not reach the user.
FailedMeansNotDelivered == \A r \in Runs : delivery[r] = "failed" => delivered[r] = 0

-----------------------------------------------------------------------------
(* WITNESS: violated when its scenario is reachable. *)

\* One run is still finishing (writing the job row or delivering) while the
\* next run of the same job is already in its AgentLoop: the race-stop
\* counts rows, not runner processes.
Witness_OverlappingRunners ==
    ~(\E a, b \in Runs :
        /\ pc[a] \in {"start", "loop"}
        /\ pc[b] \in {"memo", "finread", "finwrite", "await", "mark"})

=============================================================================
