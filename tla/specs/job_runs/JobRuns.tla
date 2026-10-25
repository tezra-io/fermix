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
(* With CuesOn the Scheduler also admits cue runs (M60): one coalesced     *)
(* :cue_admit pass on a wake from the cue inbox, a run's end and           *)
(* :job_changed, and admission after the due scan of every due and         *)
(* reconcile tick. For a cron job (CueTask FALSE) that only adds due       *)
(* scans. With CueTask the one job is a watcher's task (schedule_kind      *)
(* "cue"): the due scan and the due timer never see it, "run now" refuses  *)
(* it before the Scheduler, and its runs are claimed by admission from its *)
(* passed deliveries (`waiting`, a count; the delivery rows themselves are *)
(* tla/specs/cue_inbox's). Its settle moves the delivery in the same       *)
(* transaction: a completed run acks it; a failed one puts it back or ends *)
(* it, which this spec chooses freely, and a retried attempt sends         *)
(* none of its text. The reaper settles a dead cue run the same way, and   *)
(* an exhausted one gets its failure text from a task under the shared     *)
(* TaskSupervisor, which marks the run's delivery pending before it sends. *)
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
(* :busy never happens) and the cue share of it (at most three cue runs,   *)
(* so for one job the free cue slots are 0 only while the last reconcile   *)
(* scan failed, runsKnown); the cue inbox's subject rule, daily caps,      *)
(* retry delays and delivery lifetimes (a waiting delivery is claimable at *)
(* once and never expires), and the attempt count that decides a failed    *)
(* cue run's retry;                                                        *)
(* delivery_mode "none"/"local" (they behave like a [SILENT] result: final *)
(* at once); memory-source rows, telemetry, the start-up stagger and the   *)
(* network-readiness wait. An owner edit is modelled as one that touches   *)
(* none of the modelled columns (a task or delivery edit).                 *)
(* The access gate is not modelled either. A run's access-sensitive tool   *)
(* call that its job row does not name is refused inside the one loop      *)
(* step, since a scheduled run never parks a call for the owner            *)
(* (access_gate.ex:363-372). An owner edit, resume or run now of a job     *)
(* naming such a tool, from a turn that could not run it directly, is      *)
(* refused by the tool before any registry write or Scheduler call         *)
(* (job_registry_support.ex:36-41): a request the owner never made. Its    *)
(* job-row read feeds no modelled column. The store of parked              *)
(* confirmations (AccessGate.Pending, application.ex:238) and the holder   *)
(* of a conversation's place records (ReplyBlocks, :242), which no job     *)
(* process reads, are two more core children started before the            *)
(* RunnerSupervisor, so a crash of either is the daemon crash below.       *)
(*                                                                         *)
(* Late writes: the Repo serves one request at a time, and a call it does  *)
(* not answer within 5 s (Timeouts.repo_call) is not cancelled: the        *)
(* request lands later, still before any later request from the same       *)
(* caller (repo.ex:4279-4292). A runner dies on that timeout, so a crash   *)
(* at a runner's Repo write comes in two kinds: the write lands late, or   *)
(* it never lands (a kill). The late kind is modelled where no later crash *)
(* point stands for it: the runner's final write (RunnerCrashLate). The    *)
(* Scheduler survives the timeout (Repo.periodic_opts, repo.ex:1219-1221,  *)
(* :4294-4302): the call returns {:error, :repo_timeout}, and the          *)
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
(* Finch, MainAgent and the rest, application.ex:173-244) or of the        *)
(* RunnerSupervisor itself: under :rest_for_one each restarts the          *)
(* RunnerSupervisor with its runners and the Scheduler                     *)
(* (application.ex:297). A runner's send helper (REMIND-2,                 *)
(* channel_send.ex:219-224) and its AgentLoop (JOB-8, runner.ex:1243-1247) *)
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
(*   fail -Settle-> await, or mark (a cue run's retried attempt)           *)
(* Without it (the code before the fix), the split finish:                 *)
(*   complete -MarkCompleted-> memo -Memory-> finread                      *)
(*   fail -MarkFailed-> finread -FinRead-> finwrite -FinWrite-> await|mark *)
(* Then await -GotResult or Watchdog-> mark -MarkDelivery-> gone, and      *)
(*   start, complete, memo, fail, finread, finwrite, mark -RunnerCrash->   *)
(*   gone; complete, fail -RunnerCrashLate-> gone                          *)
(* Scheduler steps (sPc), from idle:                                       *)
(*   idle -DueTimerFires-> scan    idle -ReconcileFires-> r_rows           *)
(*   idle -JobChanged-> arm        idle -HandleDown-> r_mark               *)
(*   idle -ManualRun-> start | arm      idle -CueAdmit-> scan              *)
(*   r_rows -ReconcileRows-> r_live -ReconcileLive-> r_mark | reapReturn   *)
(*   r_mark -ReapRun-> (next orphan or reapReturn), or r_read without      *)
(*   AtomicSettle: r_read -ReapReadJob-> r_write -ReapWriteJob-> (next     *)
(*   orphan or reapReturn)                                                 *)
(*   scan -Scan-> claim | arm   claim -Claim-> start | arm                 *)
(*   start -Start-> arm         arm -Arm-> idle, or c_scan if it admits    *)
(*   c_scan -CueCandidates-> c_claim | idle                                *)
(*   c_claim -CueClaim-> c_start | idle   c_start -CueStart-> idle         *)
(* A timed-out Repo call takes its call site's error branch:               *)
(*   r_rows -ReconcileRowsTimeout-> reapReturn (no pass)                   *)
(*   r_mark -ReapLookupTimeout-> (next orphan or reapReturn; no write)     *)
(*   scan -ScanTimeout-> idle      claim -ClaimTimeout-> idle (may land)   *)
(*   arm -ArmTimeout-> idle        idle -ManualRunTimeout-> arm (may land) *)
(*   (the first three go to c_scan instead when the callback admits)       *)
(*   c_scan -CueCandidatesTimeout-> idle                                   *)
(*   c_claim -CueClaimTimeout-> idle (may land)                            *)
(* reapReturn is where the Scheduler goes once its reaping is done: "arm"  *)
(* after init, "scan" in the 60 s tick, "idle" after a DOWN.               *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/scheduler.ex @ dc199b476a15
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/runner.ex @ dcbc87178691
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/runner_supervisor.ex @ 6a21dfe6cfad
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/delivery.ex @ 4eb42c517b57
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/registry.ex @ c75bc539b7c1
\* SOURCE: apps/fermix_core/lib/fermix_core/delivery/channel_send.ex @ 9b06289e25ae
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#call,call_or_timeout_error,request_name,periodic_opts,claim_due_job,claim_job_now,claim_due_job_tx,claim_in_tx,claim_job_now_tx,transact_claim,fetch_claimable_due_job,finish_job_claim,rollback_job_claim,upsert_scheduled_job_row,upsert_job_run_row,ensure_no_active_job_run,fetch_claimable_job,settle_job_run,settle_job_run_tx,settle_job_run_in_tx,ensure_job_run_active,release_settled_job,finish_job_settle,rollback_job_settle,unsettled_job_runs,fetch_unsettled_job_runs,@unsettled_job_runs_sql,update_scheduled_job_fields,update_scheduled_job_fields_row,scheduled_job_field_assignments!,scheduled_job_field_assignment!,@owner_text_fields,due_scheduled_jobs,fetch_due_scheduled_jobs,next_scheduled_job,fetch_next_scheduled_job,upsert_job_run,upsert_scheduled_job,get_job_run,get_scheduled_job,upsert_memory @ 4babf473a267
\* SOURCE: apps/fermix_core/lib/fermix_core/application.ex#start_supervision_tree,jobs_scheduler_opts @ 2af672d8803d
\* SOURCE: apps/fermix_core/lib/fermix_core/timeouts.ex#expired,repo_call,@repo_call_ms @ 05d3e6ea2142
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/cue_admission.ex @ 94f9aac007e9
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#claim_cue_run,claim_cue_run_tx,claim_cue_run_in_tx,claim_delivery,settle_cue_run,settle_cue_run_tx,settle_cue_run_in_tx,ensure_not_cue_run,active_run_trigger,release_cue_job @ 895445d8ff8b
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/cues_runs_sql.ex#@open_sql,@cap_room_sql,@eligible_sql,@candidates_sql,@eligible_delivery_sql,eligible_delivery,settle_delivery @ 9724800c9e21
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/cue_run.ex#report_final_failure,record_delivery,write_delivery @ fb34531385a5
EXTENDS Naturals, FiniteSets

CONSTANTS
    \* Bounds.
    NumRuns,            \* run ids, e.g. 2 (reused once a run is fully finished)
    Fires,              \* fire times the clock passes through, e.g. 2
    SendAttempts,       \* ChannelSend attempts per delivery (the code uses 3)
    OwnerMoves,         \* pause/resume requests the owner may make
    OwnerEdits,         \* update_job requests the owner may make
    ManualRuns,         \* "run now" requests the owner may make
    Cues,               \* passed deliveries the cue inbox may hand the task, each with its wake
    \* Environment switches: what may happen.
    DaemonCanCrash,     \* the daemon dies once (every process) and boots again
    SchedulerCrashes,   \* how many times the Scheduler alone may die of a cause other than a
                        \* Repo timeout, e.g. :rest_for_one restarting it when the
                        \* MeetingsSupervisor between the RunnerSupervisor and it dies
                        \* (application.ex:245-252)
    SchedulerTimeouts,  \* how many of the Scheduler's Repo calls may time out (5 s); it takes
                        \* that call site's error branch and keeps running (repo.ex:1219-1221)
    RunnerCanCrash,     \* a runner dies at one of its Repo calls (a timeout, a failed match)
    LoopCanFail,        \* the AgentLoop ends in an error or a timeout
    PlatformCanFail,    \* a send fails: no connection, or an error after the platform took it
    ResponsesCanStall,  \* the platform takes a message and its answer never arrives in time;
                        \* with DeliveryWatchdog off the wait is unbounded (the adapters'
                        \* own HTTP timeouts are outside the sources)
    \* Configuration: what kind of home and job.
    CuesOn,             \* the cue tree runs (Cues.running?/0, read by the Scheduler for every
                        \* request and every admission; a development build with
                        \* [fermix_core.cues] enabled): the Scheduler admits cue runs. Every
                        \* check before 36 sets it FALSE, the Scheduler of a home without cues
    CueTask,            \* the job is a watcher's task, a job that runs on cues (schedule_kind
                        \* "cue", registry.ex:5-11): only with CuesOn. FALSE: a cron job
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by the checks that show a property needs it.
    AtomicRaceStop,           \* the claim refuses while a run is queued/running (repo.ex:6508, :6561-6579)
    RetriesOnlyUnsent,        \* a send is retried only when it never reached the platform (channel_send.ex:140-143, :194-202);
                              \* the mechanism for platforms that do not dedupe on the run's proactive_key
    ReconcilesRuns,           \* init and every 60 s reap orphaned runs, adopt live runners (scheduler.ex:210, :245-415)
    CrashFailsPendingDelivery,\* a dead runner's pending delivery is marked failed, whatever the run's
                              \* status (scheduler.ex:925-927, :946-959)
    DeliveryWatchdog,         \* the runner stops waiting for a send after delivery_timeout_ms (channel_send.ex:219-241)
    AtomicSettle,             \* a run's final row and its job's release are one transaction, for the
                              \* runner and the reaper alike (repo.ex:2453-2456, :6596-6612, :6672-6719)
    ReconcilesPending,        \* the reconcile pass also reads runs whose delivery is still pending
                              \* (unsettled_job_runs, repo.ex:2492-2526, scheduler.ex:371)
    RefusalBacksOff,          \* a due claim refused as :already_running is backpressure: the re-arm
                              \* floors at the 5 s backoff (scheduler.ex:593-597, :1080-1086)
    OwnerWritesColumns,       \* pause, resume and update_job write only the columns they own
                              \* (registry.ex:179-202; repo.ex:2396-2399, :6867-6874, :7782-7820)
    LoopDiesWithRunner,       \* a runner's AgentLoop is linked to it, so a restart that kills
                              \* the runner kills its loop too (runner.ex:1243-1247)
    TicksAdmit,               \* the due and reconcile ticks run cue admission after their due
                              \* scan (handle_info(:due_tick | :reconcile_tick), scheduler.ex
                              \* :238-256), so a cue whose wake found nothing to claim is still
                              \* admitted later
    ReportMarksPending        \* the reaper's final failure report marks its run's delivery
                              \* "pending" before it sends (mark_attempted, cue_run.ex:376,
                              \* :385-390), so a daemon that dies around the send leaves a row
                              \* the reconcile pass finishes

Runs == 1..NumRuns

VARIABLES
    \* --- SQLite rows (survive every crash) ---
    jobEnabled,  \* scheduled_jobs.enabled
    jobState,    \* scheduled_jobs.state: "scheduled" | "running" | "paused"
    nextRun,     \* scheduled_jobs.next_run_at, as a fire-time index
    runStatus,   \* runStatus[r]: job_runs.status ("absent" = no row for this id yet)
    delivery,    \* delivery[r]: job_runs.delivery_status; "unset" is the "none" the claim
                 \* writes before a result exists (scheduler.ex:780), kept apart from the
                 \* final "none" of delivery_mode "none" (modelled as "skipped")
    waiting,     \* the task's passed deliveries a claim may take (cue_deliveries rows in
                 \* state passed, as a count; always 0 for a cron job)
    \* --- the environment ---
    now,         \* fire times that have passed (the wall clock)
    strayLoops,  \* runs whose AgentLoop outlived its runner in a daemon crash (only
                 \* without LoopDiesWithRunner): a process no model step reaches
    cueSupply,   \* passed deliveries (or, for a cron job, wakes) still to come
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
    \* --- the final failure report of a cue run the Scheduler exhausted ---
    report,      \* report[r]: "none" | "marking" (its task has yet to mark the delivery
                 \* pending) | "sending" | "sent" / "failed" (the result its task has
                 \* yet to write)
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
    cuePending,  \* a :cue_admit pass waits in its mailbox (cue_pending?, one for any
                 \* number of requests)
    admit,       \* this callback runs cue admission once its due scan and re-arm end
    runsKnown,   \* its last reconcile scan succeeded, so its monitors hold every live
                 \* runner (runs_known?, scheduler.ex:198-200, :374, :382); only cue
                 \* admission reads it, so without cues it is kept TRUE
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
rowVars    == <<runStatus, delivery, waiting>>
runnerVars == <<pc, resp, finSnap, outcome>>
helperVars == <<helper, tries, delivered, report>>
schedVars  == <<sPc, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
               activeSnap, reapQ, sSnap, cuePending, admit, runsKnown>>
ownerVars  == <<oPc, oSnap, intent, movesLeft, editsLeft, manualLeft>>
envVars    == <<now, strayLoops, daemonCrashed, schedCrashes, schedTimeouts, cueSupply>>
vars == <<jobVars, rowVars, runnerVars, helperVars, schedVars, ownerVars, envVars>>

-----------------------------------------------------------------------------
PcStates == {"off", "start", "loop", "complete", "memo", "fail",
             "finread", "finwrite", "await", "mark", "gone"}
SchedStates == {"idle", "r_rows", "r_live", "r_mark", "r_read", "r_write",
                "scan", "claim", "start", "arm", "c_scan", "c_claim", "c_start"}
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
    /\ waiting \in 0..Cues
    /\ now \in 0..Fires
    /\ strayLoops \subseteq Runs
    /\ cueSupply \in 0..Cues
    /\ pc \in [Runs -> PcStates]
    /\ resp \in [Runs -> {"-", "text", "silent"}]
    /\ finSnap \in [Runs -> Snaps]
    /\ outcome \in [Runs -> {"-", "sent", "failed", "skipped"}]
    /\ helper \in [Runs -> {"none", "sending", "accepted", "ok", "err"}]
    /\ tries \in [Runs -> 0..SendAttempts]
    /\ delivered \in [Runs -> 0..SendAttempts]
    /\ report \in [Runs -> {"none", "marking", "sending", "sent", "failed"}]
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
    /\ cuePending \in BOOLEAN /\ admit \in BOOLEAN /\ runsKnown \in BOOLEAN
    /\ intent \in {"none", "paused", "resumed"}
    /\ movesLeft \in 0..OwnerMoves /\ editsLeft \in 0..OwnerEdits
    /\ manualLeft \in 0..ManualRuns
    /\ daemonCrashed \in BOOLEAN /\ schedCrashes \in 0..SchedulerCrashes
    /\ schedTimeouts \in 0..SchedulerTimeouts

-----------------------------------------------------------------------------
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

\* The due scan and the due timer never see a cue task: it has neither a
\* next_run_at nor an expiry (fetch_due_scheduled_jobs, fetch_next_scheduled_job,
\* repo.ex:6395-6451; registry.ex:5-11).
Due == ~CueTask /\ nextRun <= now
Alive(r) == pc[r] \notin {"off", "gone"}

\* Rows that hold an active slot: what ensure_no_active_job_run counts
\* (repo.ex:6561-6579) and the settle's guard accepts (repo.ex:6672-6679).
Active == {r \in Runs : runStatus[r] \in {"queued", "running"}}

\* What the reconcile scan reads: unsettled_job_runs, the active rows and then
\* the rows whose delivery is still pending (repo.ex:2492-2526); without
\* ReconcilesPending, the active rows alone.
Scanned == IF ReconcilesPending
           THEN Active \cup {r \in Runs : delivery[r] = "pending"}
           ELSE Active

JobRow == [en |-> jobEnabled, st |-> jobState, next |-> nextRun]

\* The settle's job release (release_settled_job, repo.ex:6685-6710): one
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
       /\ helper[r] = "none" /\ report[r] = "none"
       /\ r \notin monitors \cup downs \cup activeSnap \cup reapQ \cup strayLoops
       /\ r /= sRun
FreeIds == {r \in Runs : Reusable(r)}

\* The job_runs row the claim inserts (run_attrs, scheduler.ex:751-763),
\* and a clean slate for the per-run process and platform variables.
NewRun(r) ==
    /\ runStatus' = [runStatus EXCEPT ![r] = "queued"]
    /\ delivery' = [delivery EXCEPT ![r] = "unset"]
    /\ pc' = [pc EXCEPT ![r] = "off"]
    /\ delivered' = [delivered EXCEPT ![r] = 0]
    /\ UNCHANGED <<resp, finSnap, outcome, helper, tries, report>>

\* A task is a cue candidate (cues_runs_sql.ex @eligible_sql, one rule for the
\* candidate scan and the claim): a passed delivery, the job enabled and
\* "scheduled", and no queued/running run of it. The watcher's own enabled
\* flag is not part of the rule (design §8.8). The subject rule, the daily cap,
\* the retry delay (ready_at) and the lifetime (valid_until) are
\* tla/specs/cue_inbox's, so a waiting delivery is claimable at once and stays
\* claimable.
CueEligible ==
    /\ CueTask /\ waiting > 0
    /\ jobEnabled /\ jobState = "scheduled" /\ Active = {}

\* What a cue run's settle may do with its delivery (CuesRunsSql.settle_delivery,
\* cues_runs_sql.ex:233-263): a completed run acks it; a failed one puts it
\* back to passed (retry) or ends it (exhausted, or untouched), which this spec
\* chooses freely: the attempt count, the provider-failure rule and the
\* tools_started_at marker are tla/specs/cue_inbox's. A cron run holds none.
Retries(r) == IF CueTask /\ pc[r] = "fail" THEN BOOLEAN ELSE {FALSE}

-----------------------------------------------------------------------------
(* The environment: the clock and the owner *)

\* Wall-clock time reaches the next fire time.
Tick ==
    /\ now < Fires
    /\ now' = now + 1
    /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, schedVars, ownerVars,
                   strayLoops, daemonCrashed, schedCrashes, schedTimeouts, cueSupply>>

\* Ingest (a none watcher) or a filter call (a pass) commits a passed delivery
\* for the task and wakes the Scheduler: Cues.wake_scheduler/0 ->
\* Scheduler.cue_wake/1 (scheduler.ex:132-134), whose handle_cast(:cue_wake)
\* sends one :cue_admit unless one is already pending (request_admission,
\* :233-235, :286-291); the cast and that send are folded into one flag. For a
\* cron job the delivery is another task's and only the wake is modelled.
CueArrives ==
    /\ CuesOn /\ cueSupply > 0
    /\ cueSupply' = cueSupply - 1
    /\ waiting' = IF CueTask THEN waiting + 1 ELSE waiting
    /\ cuePending' = TRUE
    /\ UNCHANGED <<jobVars, runStatus, delivery, runnerVars, helperVars, ownerVars, now,
                   strayLoops, daemonCrashed, schedCrashes, schedTimeouts, sPc, reapReturn,
                   monitors, downs, changed, dueTimer, refused, sRun, activeSnap, reapQ,
                   sSnap, admit, runsKnown>>

\* Owner steps leave the Scheduler alone, except for the :job_changed cast.
OwnerQuiet == <<rowVars, runnerVars, helperVars, envVars, sPc, reapReturn, monitors,
                downs, dueTimer, refused, sRun, activeSnap, reapQ, sSnap, cuePending, admit,
                runsKnown>>

\* Registry.pause_job (registry.ex:89-91 -> update_job_fields :182-190):
\* Repo.update_scheduled_job_fields writes enabled = false and state =
\* "paused" in place (repo.ex:2396-2399, :6867-6874), then the :job_changed cast
\* (registry.ex:513-518). The owner is told "paused". Nothing is read first.
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

\* Registry.resume_job (registry.ex:93-105): get the row, then write enabled =
\* true, state = "scheduled" and next_run_at = the next future occurrence
\* (update_job_fields, :181-189), whatever state the job is in (nothing checks
\* that it is paused), then the :job_changed cast. The read is folded into the
\* write: every modelled column the write sets comes from the patch, none from
\* the read, with or without OwnerWritesColumns. A cue task's resume arms no
\* next run (next_run_at_for_resume, registry.ex:263-264).
Resume ==
    /\ oPc = "idle" /\ movesLeft > 0
    /\ jobEnabled' = TRUE
    /\ jobState' = "scheduled"
    /\ nextRun' = IF CueTask THEN nextRun ELSE now + 1
    /\ changed' = TRUE
    /\ intent' = "resumed"
    /\ movesLeft' = movesLeft - 1
    /\ UNCHANGED <<OwnerQuiet, oPc, oSnap, editsLeft, manualLeft>>

\* Registry.update_job (registry.ex:109-117): Repo.get_scheduled_job, whose row
\* the edit is computed from (normalize_update_attrs) ...
UpdateRead ==
    /\ oPc = "idle" /\ editsLeft > 0
    /\ oPc' = "editing"
    /\ oSnap' = JobRow
    /\ editsLeft' = editsLeft - 1
    /\ UNCHANGED <<OwnerQuiet, jobVars, changed, intent, movesLeft, manualLeft>>

\* ... then apply_job_update (registry.ex:191-201). With OwnerWritesColumns,
\* Repo.update_scheduled_job_fields writes only the edited columns, never
\* state, enabled or last_* (repo.ex:6867-6874; the owner field list,
\* :7782-7820): the modelled edit writes no modelled column. Without it, the
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

\* handle_info(:due_tick) (scheduler.ex:238-241): the timer armed at 0 ms or
\* at the backoff, or the one armed for next_run_at once that time has come.
\* A backoff timer fires whether or not the job is due: firing early is free,
\* the scan finds nothing due and re-arms.
DueTimerFires ==
    /\ sPc = "idle"
    /\ dueTimer \in {"zero", "backoff"} \/ (dueTimer = "later" /\ Due)
    /\ sPc' = "scan"
    /\ dueTimer' = "none"
    /\ admit' = (CuesOn /\ TicksAdmit)
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, runsKnown>>

\* handle_info(:reconcile_tick) (scheduler.ex:245-256), armed every 60 s:
\* reconcile, then the same due scan and re-arm as a due tick.
ReconcileFires ==
    /\ sPc = "idle"
    /\ sPc' = IF ReconcilesRuns THEN "r_rows" ELSE "scan"
    /\ reapReturn' = IF ReconcilesRuns THEN "scan" ELSE "idle"
    /\ admit' = (CuesOn /\ TicksAdmit)
    /\ UNCHANGED <<Quiet, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, runsKnown>>

\* handle_cast(:job_changed) (scheduler.ex:229-231): re-arm the due timer and,
\* with cues on, request one admission pass (maybe_request_admission, :282-284).
JobChanged ==
    /\ sPc = "idle"
    /\ changed
    /\ sPc' = "arm"
    /\ changed' = FALSE
    /\ cuePending' = (cuePending \/ CuesOn)
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, admit, runsKnown>>

\* handle_info(:cue_admit) (scheduler.ex:260-264): the one pass a burst of
\* requests coalesced into: the due scan and re-arm first, so a cron run takes
\* a freed slot before a cue run, then admission (admit).
CueAdmit ==
    /\ sPc = "idle"
    /\ cuePending
    /\ cuePending' = FALSE
    /\ sPc' = "scan"
    /\ admit' = TRUE
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, runsKnown>>

\* handle_info({:DOWN, ...}) with an abnormal reason (scheduler.ex:266-278):
\* forget the monitor, then mark_run_crashed -> mark_run_failed (:824-848), and
\* with cues on request one admission pass (maybe_request_admission).
HandleDown(r) ==
    /\ sPc = "idle"
    /\ r \in downs
    /\ sPc' = "r_mark"
    /\ sRun' = r
    /\ downs' = downs \ {r}
    /\ monitors' = monitors \ {r}
    /\ cuePending' = (cuePending \/ CuesOn)
    /\ UNCHANGED <<Quiet, reapReturn, changed, dueTimer, refused, activeSnap, reapQ, sSnap,
                   admit, runsKnown>>

\* handle_call({:run_now, ...}) -> manual_run (scheduler.ex:223-226, :612-645).
\* Its Repo.get_scheduled_job lookup is folded into Repo.claim_job_now: the
\* claim transaction re-checks enabled, "scheduled" and (the race-stop) no
\* queued/running run (repo.ex:6461-6465, :6495-6513, :6540-6579), so the
\* fold only drops harmless outcomes (an error reply either way). A manual
\* claim leaves a recurring job's next_run_at alone (manual_claim_patch,
\* scheduler.ex:636, :764-768). With every modelled run id in use, the
\* request is out of the model's bounds and is refused. A Repo call that
\* times out is ManualRunTimeout. A cue task never gets here: run_job_now
\* refuses it before calling the Scheduler (Registry.check_run_now,
\* run_job_now.ex:71, registry.ex:71-75), and a job's kind never changes.
ManualRun ==
    /\ sPc = "idle"
    /\ ~CueTask /\ manualLeft > 0
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
                   monitors, downs, changed, dueTimer, refused, activeSnap, reapQ, sSnap,
                   waiting, cuePending, admit, runsKnown>>

-----------------------------------------------------------------------------
(* The Scheduler: steps inside a callback, one Repo call each *)

\* Take the next orphan to reap, or go to reapReturn: init only re-arms
\* (scheduler.ex:210-211), the 60 s tick goes on to the due scan (:250-251),
\* a DOWN callback ends (:276).
NextReap(q) ==
    IF q /= {}
    THEN /\ sRun' = Min(q) /\ reapQ' = q \ {Min(q)} /\ sPc' = "r_mark"
         /\ UNCHANGED reapReturn
    ELSE /\ sRun' = 0 /\ reapQ' = {} /\ sPc' = reapReturn
         /\ reapReturn' = "idle"

\* After one run is reaped. A DOWN callback has no queue, so it ends.
AfterReap == NextReap(reapQ)

\* reconcile_active_runs: Repo.unsettled_job_runs (scheduler.ex:371), the
\* queued/running rows and the rows whose delivery is pending (Scanned). The
\* scan succeeded, so the run set is known again (runs_known?, :374). A scan
\* that times out is ReconcileRowsTimeout.
ReconcileRows ==
    /\ sPc = "r_rows"
    /\ activeSnap' = Scanned
    /\ sPc' = "r_live"
    /\ runsKnown' = TRUE
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   reapQ, sSnap, cuePending, admit>>

\* live_runner_pids: DynamicSupervisor.which_children + the run id each
\* runner published in its init (scheduler.ex:373, :423-437; runner.ex:172).
\* Live runs are adopted: monitored if not already (adopt_live_run, scheduler.ex:398-406;
\* the monitor call is folded in: monitoring a pid that just died delivers
\* DOWN at once, the same outcome as reaping it). A runner past its settle and
\* still sending is live and adopted too. The rest are orphans.
ReconcileLive ==
    /\ sPc = "r_live"
    /\ LET live == {r \in Runs : Alive(r)} IN
       /\ monitors' = monitors \cup (activeSnap \cap live)
       /\ activeSnap' = {}
       /\ NextReap(activeSnap \ live)
    /\ UNCHANGED <<Quiet, downs, changed, dueTimer, refused, sSnap, cuePending, admit,
                   runsKnown>>

\* The reaper's write for run r, as it lands (mark_run_error, scheduler.ex
\* :878-929). A queued/running run is settled "error": with AtomicSettle
\* through Repo.settle_job_run, which releases the job in the same write
\* (:907-923); without, an upsert of the run row alone. A run whose delivery
\* is still pending, whatever its status, gets delivery "failed" (:925-927,
\* :946-959). Any other row is left alone.
\* A cue task's queued/running run settles through CueAdmission.settle/3 ->
\* Repo.settle_cue_run (mark_run_error's cue clause, scheduler.ex:887-905): the
\* same row and release in one transaction, plus its delivery, put back or
\* ended (Retries). An exhausted one gets its final failure report from a task
\* the reaper starts after the write (report_cue_failure, :854-874) when
\* `reports`: not when the Scheduler died waiting on the write. The task
\* first marks the delivery pending (ReportMark), or, without
\* ReportMarksPending, sends at once.
ReapWrite(r, reports) ==
    /\ IF runStatus[r] \in {"queued", "running"}
       THEN /\ runStatus' = [runStatus EXCEPT ![r] = "error"]
            /\ UNCHANGED delivery
            /\ IF AtomicSettle THEN Release ELSE UNCHANGED jobState
            /\ \E retry \in IF CueTask THEN BOOLEAN ELSE {FALSE} :
                  /\ waiting' = IF retry THEN waiting + 1 ELSE waiting
                  /\ report' = IF CueTask /\ ~retry /\ reports
                               THEN [report EXCEPT ![r] =
                                       IF ReportMarksPending THEN "marking" ELSE "sending"]
                               ELSE report
       ELSE IF CrashFailsPendingDelivery /\ delivery[r] = "pending"
       THEN /\ delivery' = [delivery EXCEPT ![r] = "failed"]
            /\ UNCHANGED <<runStatus, jobState, waiting, report>>
       ELSE UNCHANGED <<rowVars, jobState, report>>
    /\ UNCHANGED <<jobEnabled, nextRun>>

\* Whether that write leaves a job write to follow: only the split reaper
\* (AtomicSettle off) writes the job row after it, and only when it wrote.
SplitReapFollows(r) ==
    /\ ~AtomicSettle
    /\ \/ runStatus[r] \in {"queued", "running"}
       \/ CrashFailsPendingDelivery /\ delivery[r] = "pending"

\* mark_run_failed -> mark_run_error (scheduler.ex:831-929): Repo.get_job_run,
\* then the write above. The two calls are one step: once its runner is dead
\* only the Scheduler writes this row, and a runner's timed-out write landed
\* before the get, which was queued after it. For the same reason the
\* settle's :run_not_active branch (:917-918) is unreachable here. One other
\* writer remains: a cue run's report task, whose pending row a reconcile
\* pass reaps like any orphan's (the task is no runner). Its result write
\* can land between the get and the write, which then records "failed" over
\* it; the fold drops that order. The row is final either way, and only
\* FailedMeansNotDelivered (JOB-6, checked with cues off) tells "failed" over
\* a sent report from "sent". A write that times out is this step too: it
\* lands late, before the Scheduler's next Repo call, and its error branch
\* only logs and skips the memory-source mirror (:920-921, :954-957), which
\* is not modelled. A get that times out is ReapLookupTimeout. Without
\* AtomicSettle the code before the fix then wrote the job row (r_read).
ReapRun ==
    /\ sPc = "r_mark"
    /\ ReapWrite(sRun, TRUE)
    /\ IF SplitReapFollows(sRun)
       THEN /\ sPc' = "r_read"
            /\ UNCHANGED <<sRun, reapQ, reapReturn>>
       ELSE AfterReap
    /\ UNCHANGED <<runnerVars, helper, tries, delivered, ownerVars, envVars,
                   monitors, downs, changed, dueTimer, refused, activeSnap, sSnap,
                   cuePending, admit, runsKnown>>

\* Without AtomicSettle, the job write of the code before the fix
\* (mark_job_error / mark_job_completed_after_delivery_crash), first half:
\* Repo.get_scheduled_job.
ReapReadJob ==
    /\ sPc = "r_read"
    /\ sSnap' = JobRow
    /\ sPc' = "r_write"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, cuePending, admit, runsKnown>>

\* ... second half: Repo.upsert_scheduled_job of the row it read, "running"
\* -> "scheduled" (the memory-source update after it is folded in).
ReapWriteJob ==
    /\ sPc = "r_write"
    /\ WriteBack(sSnap)
    /\ sSnap' = NoSnap
    /\ AfterReap
    /\ UNCHANGED <<rowVars, runnerVars, helperVars, ownerVars, envVars,
                   monitors, downs, changed, dueTimer, refused, activeSnap, cuePending, admit,
                   runsKnown>>

\* run_due_jobs: Repo.due_scheduled_jobs (scheduler.ex:451-460): enabled,
\* state "scheduled", next_run_at <= now (repo.ex:6395-6422). A scan that
\* times out is ScanTimeout.
Scan ==
    /\ sPc = "scan"
    /\ sPc' = IF jobEnabled /\ jobState = "scheduled" /\ Due THEN "claim" ELSE "arm"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, admit, runsKnown>>

\* claim_patched_job -> Repo.claim_due_job (scheduler.ex:586-606): one
\* BEGIN IMMEDIATE transaction (repo.ex:6453-6457, :6495-6538) that re-checks the job is
\* due, refuses while a run is queued/running (the race-stop), then sets
\* state "running" with next_run_at advanced (claim_job_patch, scheduler.ex
\* :755-759) and inserts the run "queued". :already_running returns
\* {:busy, state} (:593-597), :not_due {:ok, state}. With every modelled run
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
                   activeSnap, reapQ, sSnap, waiting, cuePending, admit, runsKnown>>

\* start_or_mark_failed (scheduler.ex:735-745): RunnerSupervisor.start_run
\* runs Runner.init synchronously (runner_supervisor.ex:20-23), which
\* publishes the run id (runner.ex:172); then Process.monitor. No Repo call.
Start ==
    /\ sPc = "start"
    /\ pc' = [pc EXCEPT ![sRun] = "start"]
    /\ monitors' = monitors \cup {sRun}
    /\ sRun' = 0
    /\ sPc' = "arm"
    /\ UNCHANGED <<jobVars, rowVars, resp, finSnap, outcome, helperVars, ownerVars,
                   envVars, reapReturn, downs, changed, dueTimer, refused, activeSnap,
                   reapQ, sSnap, cuePending, admit, runsKnown>>

\* schedule_due_timer -> next_due_timer: Repo.next_scheduled_job (scheduler.ex
\* :1007-1035, repo.ex:6424-6451). A tick whose claim was refused re-arms no
\* sooner than the 5 s backoff (outcome :busy, due_delay_ms, scheduler.ex:1080-1086) with
\* RefusalBacksOff; without it the refusal counted as a clean drain. After a
\* clean tick an enabled "scheduled" job is armed at its next_run_at, which is
\* 0 ms when it is already due; no such job arms nothing. A lookup that times
\* out is ArmTimeout. A cue task is never armed: the lookup never returns it.
\* A callback that admits goes on to the candidate scan (admit_cue_runs, after
\* run_due_and_rearm, scheduler.ex:219-264, :293-305).
Arm ==
    /\ sPc = "arm"
    /\ dueTimer' = IF refused /\ RefusalBacksOff THEN "backoff"
                   ELSE IF ~CueTask /\ jobEnabled /\ jobState = "scheduled"
                        THEN IF Due THEN "zero" ELSE "later"
                        ELSE "none"
    /\ sPc' = IF admit THEN "c_scan" ELSE "idle"
    /\ reapReturn' = "idle"
    /\ refused' = FALSE
    /\ UNCHANGED <<Quiet, monitors, downs, changed, sRun, activeSnap, reapQ, sSnap,
                   cuePending, admit, runsKnown>>

\* admit_cue_runs (scheduler.ex:293-305): the free cue slots (free_cue_slots,
\* :306-318; CueAdmission.free_slots, cue_admission.ex:56-63), then
\* CueAdmission.claim: one Repo call for the candidates
\* ({:admission_candidates, ...}, cues_runs_sql.ex:184-190). While the last
\* reconcile scan failed the slots are 0 (no cue run starts until a scan
\* succeeds), and claim(0, ...) makes no call (cue_admission.ex:78-80).
\* Otherwise one job never holds more than two runners, so the slots
\* (min(4 - active, 3 - active cue runs)) are never 0 and that call is made;
\* for a cron job it finds nothing. A call that times out is
\* CueCandidatesTimeout.
CueCandidates ==
    /\ sPc = "c_scan"
    /\ sPc' = IF runsKnown /\ CueEligible THEN "c_claim" ELSE "idle"
    /\ admit' = FALSE
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, runsKnown>>

\* Repo.claim_cue_run (cue_admission.ex:132-149; repo.ex:2373-2376,
\* :6472-6493): one BEGIN IMMEDIATE that re-reads the task's oldest eligible
\* delivery (CuesRunsSql.eligible_delivery, the same rule), takes the job with
\* state "running" alone, leaving next_run_at as it is (claim_in_tx, whose
\* ensure_no_active_job_run repeats the rule's no-active-run part inside the
\* same transaction, repo.ex:6506-6513), inserts the run with trigger "cue" and
\* moves the delivery passed -> claimed. A task no longer eligible is
\* :nothing_due, skipped. With every modelled run id in use the claim is out of
\* the model's bounds and behaves like :nothing_due. A claim that times out is
\* CueClaimTimeout.
CueClaim ==
    /\ sPc = "c_claim"
    /\ IF CueEligible /\ FreeIds /= {}
       THEN LET r == Min(FreeIds) IN
            /\ NewRun(r)
            /\ waiting' = waiting - 1
            /\ jobState' = "running"
            /\ sRun' = r
            /\ sPc' = "c_start"
       ELSE /\ sPc' = "idle"
            /\ UNCHANGED <<jobState, rowVars, runnerVars, helperVars, sRun>>
    /\ UNCHANGED <<jobEnabled, nextRun, ownerVars, envVars, reapReturn, monitors, downs,
                   changed, dueTimer, refused, activeSnap, reapQ, sSnap, cuePending, admit,
                   runsKnown>>

\* start_cue_run -> start_or_mark_failed (scheduler.ex:357, :735-745), as
\* Start. The pass ends here: admission runs after the re-arm.
CueStart ==
    /\ sPc = "c_start"
    /\ pc' = [pc EXCEPT ![sRun] = "start"]
    /\ monitors' = monitors \cup {sRun}
    /\ sRun' = 0
    /\ sPc' = "idle"
    /\ UNCHANGED <<jobVars, rowVars, resp, finSnap, outcome, helperVars, ownerVars,
                   envVars, reapReturn, downs, changed, dueTimer, refused, activeSnap,
                   reapQ, sSnap, cuePending, admit, runsKnown>>

SchedStep ==
    \/ ReconcileRows \/ ReconcileLive \/ ReapRun \/ ReapReadJob \/ ReapWriteJob
    \/ Scan \/ Claim \/ Start \/ Arm \/ CueCandidates \/ CueClaim \/ CueStart

-----------------------------------------------------------------------------
(* The Scheduler: a Repo call that times out *)

\* Every Repo call the Scheduler's process makes passes Repo.periodic_opts
\* (scheduler.ex:159-162; repo.ex:1219-1221): a call the Repo does not answer
\* within 5 s returns {:error, :repo_timeout} (repo.ex:4294-4302) and the
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
                  now, strayLoops, daemonCrashed, schedCrashes, cueSupply>>

\* reconcile_active_runs: Repo.unsettled_job_runs times out (scheduler.ex
\* :376-382). The pass reaps and adopts nothing, and the callback goes on:
\* to the re-arm at init, to the due scan in the 60 s tick. An orphan waits
\* for the next pass; after a restart a live runner stays unmonitored, so if
\* it dies no DOWN arrives and the next pass reaps its run. The run set is
\* unknown until a scan succeeds, so no cue run starts (runs_known? false).
ReconcileRowsTimeout ==
    /\ sPc = "r_rows"
    /\ TimeOut
    /\ NextReap({})
    /\ runsKnown' = ~CuesOn
    /\ UNCHANGED <<TimeoutQuiet, monitors, downs, changed, dueTimer, refused, activeSnap,
                   sSnap, cuePending, admit>>

\* mark_run_failed: Repo.get_job_run times out (scheduler.ex:841-844), so the
\* run is not marked and its row keeps its status. After a DOWN the monitor
\* is already gone: a queued/running row holds the job, with no runner and
\* no monitor, until the next reconcile pass reaps it with the generic
\* "reaped: no live runner" text (:60-64, :412-415). In a reconcile pass
\* the orphan waits for the next pass.
ReapLookupTimeout ==
    /\ sPc = "r_mark"
    /\ TimeOut
    /\ AfterReap
    /\ UNCHANGED <<TimeoutQuiet, monitors, downs, changed, dueTimer, refused, activeSnap,
                   sSnap, cuePending, admit, runsKnown>>

\* run_due_jobs: Repo.due_scheduled_jobs times out (scheduler.ex:456-458).
\* The tick's outcome is :error, so the re-arm floors at the 5 s backoff
\* (:1007-1044, :1080-1086). That re-arm is folded in: whatever its own lookup
\* returns, or if it times out too (:1031-1033), the model arms "backoff",
\* which fires whether or not the job is due. Nothing is written. A callback
\* that admits still goes on to admission after any of the three timeouts.
ScanTimeout ==
    /\ sPc = "scan"
    /\ TimeOut
    /\ sPc' = IF admit THEN "c_scan" ELSE "idle"
    /\ dueTimer' = "backoff"
    /\ UNCHANGED <<TimeoutQuiet, reapReturn, monitors, downs, changed, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, admit, runsKnown>>

\* claim_patched_job: Repo.claim_due_job times out (scheduler.ex:602-604).
\* The claim transaction still runs when the Repo reaches it, as Claim would
\* run it, but the Scheduler starts no runner and monitors nothing: a claim
\* that lands leaves a queued run with no runner, which holds its job until
\* the next reconcile pass reaps it ("... or a memory store that answered too
\* late", scheduler.ex:60-64). The tick's outcome is :error: the re-arm is
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
    /\ sPc' = IF admit THEN "c_scan" ELSE "idle"
    /\ dueTimer' = "backoff"
    /\ UNCHANGED <<ownerVars, now, strayLoops, daemonCrashed, schedCrashes, reapReturn,
                   monitors, downs, changed, refused, sRun, activeSnap, reapQ, sSnap,
                   waiting, cueSupply, cuePending, admit, runsKnown>>

\* next_due_timer: Repo.next_scheduled_job times out (scheduler.ex:1029-1033):
\* the timer is armed at the backoff whatever the row says.
ArmTimeout ==
    /\ sPc = "arm"
    /\ TimeOut
    /\ dueTimer' = "backoff"
    /\ sPc' = IF admit THEN "c_scan" ELSE "idle"
    /\ reapReturn' = "idle"
    /\ refused' = FALSE
    /\ UNCHANGED <<TimeoutQuiet, monitors, downs, changed, sRun, activeSnap, reapQ, sSnap,
                   cuePending, admit, runsKnown>>

\* handle_call({:run_now, ...}) whose lookup (scheduler.ex:613-615) or
\* Repo.claim_job_now (:638-643) times out. A claim that times out still
\* lands when ManualRun's would, with no runner started. Either way the
\* owner is told {:error, :repo_timeout} and the due timer is re-armed, as
\* after any "run now" (:225).
ManualRunTimeout ==
    /\ sPc = "idle"
    /\ ~CueTask /\ manualLeft > 0
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
                   refused, sRun, activeSnap, reapQ, sSnap, waiting, cueSupply, cuePending,
                   admit, runsKnown>>

\* CueAdmission.claim: the candidate scan times out (cue_admission.ex:93-96):
\* logged, nothing claimed, the pass ends. Only a pass with free slots makes
\* the call.
CueCandidatesTimeout ==
    /\ sPc = "c_scan" /\ runsKnown
    /\ TimeOut
    /\ sPc' = "idle"
    /\ admit' = FALSE
    /\ UNCHANGED <<TimeoutQuiet, reapReturn, monitors, downs, changed, dueTimer, refused,
                   sRun, activeSnap, reapQ, sSnap, cuePending, runsKnown>>

\* Repo.claim_cue_run times out (claim_candidate's error branch,
\* cue_admission.ex:144-147): traced, logged and skipped, but the claim still lands
\* when the Repo reaches it, as CueClaim would run it, with no runner started:
\* a queued cue run that holds its job until the next reconcile pass reaps it.
CueClaimTimeout ==
    /\ sPc = "c_claim"
    /\ TimeOut
    /\ IF CueEligible /\ FreeIds /= {}
       THEN LET r == Min(FreeIds) IN
            /\ NewRun(r)
            /\ waiting' = waiting - 1
            /\ jobState' = "running"
            /\ UNCHANGED <<jobEnabled, nextRun>>
       ELSE UNCHANGED <<jobVars, rowVars, runnerVars, helperVars>>
    /\ sPc' = "idle"
    /\ UNCHANGED <<ownerVars, now, strayLoops, daemonCrashed, schedCrashes, cueSupply,
                   reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, admit, runsKnown>>

SchedTimeout ==
    \/ ReconcileRowsTimeout \/ ReapLookupTimeout \/ ScanTimeout \/ ClaimTimeout
    \/ ArmTimeout \/ ManualRunTimeout \/ CueCandidatesTimeout \/ CueClaimTimeout

-----------------------------------------------------------------------------
(* One Runner (runner.ex), a :temporary child of Jobs.RunnerSupervisor *)

Move(r, s) == pc' = [pc EXCEPT ![r] = s]
RunnerQuiet == <<jobVars, ownerVars, envVars, schedVars>>

\* handle_continue(:run) -> mark_running (runner.ex:178-183, :263-280):
\* Repo.upsert_job_run with status "running".
MarkRunning(r) ==
    /\ pc[r] = "start"
    /\ Move(r, "loop")
    /\ runStatus' = [runStatus EXCEPT ![r] = "running"]
    /\ UNCHANGED <<RunnerQuiet, delivery, waiting, resp, finSnap, outcome, helperVars>>

\* The whole AgentLoop, run in a process linked to the runner that the runner
\* watches (runner.ex:206, :1218-1250): final text, [SILENT], or an
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
\* the same transaction (Repo.settle_job_run, runner.ex:311 / :457).
RunnerWrite(r) ==
    /\ runStatus' = [runStatus EXCEPT ![r] = IF pc[r] = "complete" THEN "ok" ELSE "error"]
    /\ delivery' = [delivery EXCEPT ![r] =
                      IF pc[r] = "complete" /\ resp[r] = "silent" THEN "skipped" ELSE "pending"]
    /\ IF AtomicSettle THEN Release ELSE UNCHANGED jobState
    /\ UNCHANGED <<jobEnabled, nextRun>>

\* The settle's guard (ensure_job_run_active, repo.ex:6672-6679): only a
\* queued/running row may be settled. The split write has no guard.
Settleable(r) == ~AtomicSettle \/ runStatus[r] \in {"queued", "running"}

\* mark_completed (runner.ex:292-314) / mark_failed (:438-462) with
\* AtomicSettle: write output.md or error.md (folded in), then
\* Repo.settle_job_run (repo.ex:2453-2456, :6596-6612, :6672-6719): the run row and the job's
\* release in one transaction. After a success the memory write comes next;
\* after a loop error the memory-source update (runner.ex:460, folded in) and then the
\* send, so that runner goes straight to its send. A settle the guard refuses
\* fails the {:ok, _} match and kills the runner; that branch is unreachable,
\* since the reaper only settles a run whose runner is dead.
\* A cue run settles through CueAdmission.settle/3 -> Repo.settle_cue_run
\* (runner.ex:320-343, :408-436; settle_job_run refuses it, repo.ex:6604-6612,
\* :6640-6646): the same row and release, and its delivery in the same
\* transaction. A completed one acks it and goes on as above, with no summary
\* memory (complete_run, runner.ex:229-238). A failed one puts it back (Retries) and
\* then only marks its delivery "skipped", sending none of its text and leaving
\* the memory source alone (finish_cue_failure, runner.ex:488-494; a retried
\* provider failure first sends the once-a-day :task_provider_down watcher
\* notice, notify_provider_down, :464-484, which is not modelled), or ends it
\* and sends its failure text as above.
Settle(r) ==
    /\ AtomicSettle
    /\ pc[r] \in {"complete", "fail"}
    /\ IF Settleable(r)
       THEN /\ RunnerWrite(r)
            /\ \E retry \in Retries(r) :
                  /\ waiting' = IF retry THEN waiting + 1 ELSE waiting
                  /\ IF pc[r] = "complete"
                     THEN /\ Move(r, "memo") /\ UNCHANGED <<helper, outcome>>
                     ELSE IF retry
                     THEN /\ Move(r, "mark")
                          /\ outcome' = [outcome EXCEPT ![r] = "skipped"]
                          /\ UNCHANGED helper
                     ELSE /\ Move(r, "await")
                          /\ helper' = [helper EXCEPT ![r] = "sending"]
                          /\ UNCHANGED outcome
            /\ UNCHANGED downs
       ELSE /\ Move(r, "gone")
            /\ downs' = IF r \in monitors THEN downs \cup {r} ELSE downs
            /\ UNCHANGED <<jobVars, rowVars, helper, outcome>>
    /\ resp' = [resp EXCEPT ![r] = "-"]
    /\ UNCHANGED <<ownerVars, envVars, sPc, reapReturn, monitors, changed, dueTimer,
                   refused, sRun, activeSnap, reapQ, sSnap, finSnap, tries,
                   delivered, report, cuePending, admit, runsKnown>>

\* Without AtomicSettle, mark_completed before the fix: Repo.upsert_job_run of
\* the run row alone.
MarkCompleted(r) ==
    /\ ~AtomicSettle
    /\ pc[r] = "complete"
    /\ RunnerWrite(r)
    /\ Move(r, "memo")
    /\ resp' = [resp EXCEPT ![r] = "-"]
    /\ UNCHANGED <<ownerVars, envVars, schedVars, finSnap, outcome, helperVars, waiting>>

\* Without AtomicSettle, mark_failed before the fix: the run row alone.
MarkFailed(r) ==
    /\ ~AtomicSettle
    /\ pc[r] = "fail"
    /\ RunnerWrite(r)
    /\ Move(r, "finread")
    /\ UNCHANGED <<ownerVars, envVars, schedVars, resp, finSnap, outcome, helperVars,
                   waiting>>

\* persist_run_summary_memory (runner.ex:244, :365-402): Repo.upsert_memory
\* (skipped for [SILENT]), then the memory-source update (:245, :560-574,
\* whose failures are logged), folded in. No modelled row changes; it is a
\* crash point. With AtomicSettle
\* finalize_delivery (:246, :524-532) follows: a pending delivery spawns the
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
    /\ UNCHANGED <<RunnerQuiet, rowVars, resp, finSnap, outcome, tries, delivered, report>>

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
                   tries, delivered, report>>

\* The watchdog's receive gets the helper's result (channel_send.ex:226-233).
GotResult(r) ==
    /\ pc[r] = "await"
    /\ helper[r] \in {"ok", "err"}
    /\ outcome' = [outcome EXCEPT ![r] = IF helper[r] = "ok" THEN "sent" ELSE "failed"]
    /\ helper' = [helper EXCEPT ![r] = "none"]
    /\ Move(r, "mark")
    /\ UNCHANGED <<RunnerQuiet, rowVars, resp, finSnap, tries, delivered, report>>

\* mark_delivery (runner.ex:534-556): Repo.upsert_job_run with the result,
\* then {:stop, :normal} (runner.ex:192). The Scheduler's DOWN :normal
\* handler only drops the monitor (scheduler.ex:271-272); it is folded in.
\* A refused write exits the runner with the outcome and its error in its
\* reason (runner.ex:549-555): that is RunnerCrash at "mark". With cues on, the
\* folded DOWN :normal also requests one admission pass (scheduler.ex:271-272),
\* when this Scheduler monitors the runner.
MarkDelivery(r) ==
    /\ pc[r] = "mark"
    /\ delivery' = [delivery EXCEPT ![r] =
                      IF delivery[r] = "skipped" THEN "skipped" ELSE outcome[r]]
    /\ outcome' = [outcome EXCEPT ![r] = "-"]
    /\ Move(r, "gone")
    /\ monitors' = monitors \ {r}
    /\ cuePending' = (cuePending \/ (CuesOn /\ r \in monitors))
    /\ UNCHANGED <<jobVars, ownerVars, envVars, runStatus, waiting, resp, finSnap,
                   helperVars, sPc, reapReturn, downs, changed, dueTimer, refused,
                   sRun, activeSnap, reapQ, sSnap, admit, runsKnown>>

RunnerStep(r) ==
    \/ MarkRunning(r) \/ Loop(r) \/ Settle(r) \/ MarkCompleted(r) \/ Memory(r)
    \/ MarkFailed(r) \/ FinRead(r) \/ FinWrite(r) \/ GotResult(r) \/ MarkDelivery(r)

\* The runner dies at one of its Repo calls and the call never lands (a
\* kill, a failed {:ok, _} match, or mark_delivery's exit on a refused
\* write, runner.ex:549-555). A failed output.md/error.md write also
\* kills it ({:ok, _} match, runner.ex:294, :443); that write is folded into
\* the final write, so it is the crash at "complete"/"fail". The
\* memory-source calls after the split job upsert are a crash point with no
\* pc of their own: a crash there leaves the rows a crash at "mark" leaves,
\* minus the send. It raises nowhere while it waits on a send. While it
\* waits on its loop, the loop reports its own crash as a value
\* (runner.ex:1252-1269); the one death left there, a process the loop links
\* to itself killing the loop and through the link the runner, leaves the
\* rows the Loop step and then a crash at "complete" or "fail" leave, so it
\* needs no step of its own. Its supervisor does not restart it
\* (restart: :temporary, runner.ex:122); a Scheduler that monitors it gets a
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
                   monitors, changed, dueTimer, refused, sRun, activeSnap, reapQ, sSnap,
                   cuePending, admit, runsKnown>>

\* The runner's final write times out: GenServer.call exits the runner, which
\* passes no on_timeout (repo.ex:4284-4292), but the request stays in the
\* Repo's mailbox and lands.
\* With AtomicSettle that is the whole settle, guard included; after a loop
\* error it also stands for a crash at the memory-source calls between the
\* settle and the send. Every later reader's call was queued after it. A cue
\* run's late settle moves its delivery too (Retries).
RunnerCrashLate(r) ==
    /\ RunnerCanCrash
    /\ pc[r] \in {"complete", "fail"}
    /\ Settleable(r)
    /\ RunnerWrite(r)
    /\ \E retry \in Retries(r) : waiting' = IF retry THEN waiting + 1 ELSE waiting
    /\ Move(r, "gone")
    /\ resp' = [resp EXCEPT ![r] = "-"]
    /\ downs' = IF r \in monitors THEN downs \cup {r} ELSE downs
    /\ UNCHANGED <<ownerVars, envVars, helperVars, finSnap, outcome, sPc, reapReturn,
                   monitors, changed, dueTimer, refused, sRun, activeSnap, reapQ, sSnap,
                   cuePending, admit, runsKnown>>

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
    /\ UNCHANGED <<RunnerQuiet, rowVars, runnerVars, report>>

\* The runner's own delivery timer (delivery_timeout_ms, runner.ex:1598):
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
    /\ UNCHANGED <<RunnerQuiet, rowVars, resp, finSnap, delivered, report>>

-----------------------------------------------------------------------------
(* The final failure report of a cue run the Scheduler exhausted *)

\* A task under the shared TaskSupervisor, started by the reaper and linked to
\* no Scheduler (report_cue_failure, scheduler.ex:854-874), runs
\* CueRun.report_final_failure (cue_run.ex:371-383). The run was settled with
\* the delivery_status its claim wrote ("unset" here). Its first write
\* (mark_attempted, :385-390, after the context and call reads, which write
\* nothing) is Repo.upsert_job_run of that settled row with delivery_status
\* "pending", the initial status of the failure text, which is never the
\* silent marker. From then on the task is no runner the reconcile pass can
\* find, so a pass may reap the pending row as an orphan's (ReapWrite marks
\* it "failed") while the task still sends. Without ReportMarksPending, the
\* code before the fix, the task sent first (ReportSend straight from the
\* reaper).
ReportMark(r) ==
    /\ report[r] = "marking"
    /\ delivery' = [delivery EXCEPT ![r] = "pending"]
    /\ report' = [report EXCEPT ![r] = "sending"]
    /\ UNCHANGED <<jobVars, runStatus, waiting, runnerVars, helper, tries, delivered,
                   schedVars, ownerVars, envVars>>

\* Then the failure text through CueRun.deliver (ChannelSend: a send retried
\* only when it never reached the platform, under the watchdog) ...
ReportSend(r) ==
    /\ report[r] = "sending"
    /\ \/ /\ delivered' = [delivered EXCEPT ![r] = @ + 1]
          /\ report' = [report EXCEPT ![r] = "sent"]
       \/ /\ PlatformCanFail
          /\ report' = [report EXCEPT ![r] = "failed"]
          /\ \/ UNCHANGED delivered
             \/ delivered' = [delivered EXCEPT ![r] = @ + 1]
    /\ UNCHANGED <<jobVars, rowVars, runnerVars, helper, tries, schedVars, ownerVars,
                   envVars>>

\* ... and record_delivery -> write_delivery (cue_run.ex:411-436):
\* Repo.upsert_job_run of the settled row with the result, over a "failed" a
\* reconcile pass may have written meanwhile.
ReportWrite(r) ==
    /\ report[r] \in {"sent", "failed"}
    /\ delivery' = [delivery EXCEPT ![r] = report[r]]
    /\ report' = [report EXCEPT ![r] = "none"]
    /\ UNCHANGED <<jobVars, runStatus, waiting, runnerVars, helper, tries, delivered,
                   schedVars, ownerVars, envVars>>

-----------------------------------------------------------------------------
(* Crashes and restarts *)

\* The Scheduler (re)starts: init reconciles, then arms (scheduler.ex:152-216).
\* Its monitors, timers and mailbox are gone.
\* A pending :cue_admit dies with the old process, and init asks for none:
\* maybe_request_admission (scheduler.ex:213, :282-284) asks only while the cue
\* tree runs (Cues.running?/0), and that tree starts after the Scheduler under
\* :rest_for_one (application.ex:293, :297), so it is never up while the
\* Scheduler inits. The first admission after a restart is a tick's, a wake's,
\* a run's end's or a job change's. The run set starts unknown (runs_known?
\* false, scheduler.ex:200) until init's reconcile scan succeeds; without
\* ReconcilesRuns there is no scan, and the empty monitors are taken as the
\* run set, as tla/specs/cue_inbox does.
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
    /\ cuePending' = FALSE
    /\ admit' = FALSE
    /\ runsKnown' = (~CuesOn \/ ~ReconcilesRuns)

\* The Scheduler dies alone, at any point of any callback, and the call it
\* waited on never lands. A Repo call that times out no longer kills it
\* (the timeout steps above); another cause still does, such as
\* :rest_for_one restarting it when the MeetingsSupervisor started between
\* the RunnerSupervisor and it dies (application.ex:245-252), or a raise in
\* its own code. FermixCore.Supervisor is :rest_for_one and starts
\* JobRunnerSupervisor before JobScheduler (application.ex:245, :252, :297),
\* so the restart leaves every runner running.
SchedulerCrash ==
    /\ schedCrashes < SchedulerCrashes
    /\ schedCrashes' = schedCrashes + 1
    /\ SchedRestart
    /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, ownerVars, now, strayLoops,
                   daemonCrashed, schedTimeouts, cueSupply>>

\* The Scheduler dies of such a cause while it waits on the reaper's write,
\* and the write still lands (repo.ex:4279-4283). With AtomicSettle that is
\* the whole settle; without, the run row alone, and the job write never
\* happens. A cue run's write lands whole, but no report task starts.
SchedulerCrashLate ==
    /\ sPc = "r_mark"
    /\ schedCrashes < SchedulerCrashes
    /\ schedCrashes' = schedCrashes + 1
    /\ ReapWrite(sRun, FALSE)
    /\ SchedRestart
    /\ UNCHANGED <<runnerVars, helper, tries, delivered, ownerVars, now, strayLoops,
                   daemonCrashed, schedTimeouts, cueSupply>>

\* The daemon dies: every process with it (runners, send helpers, the
\* owner's request in flight). Only SQLite rows and what the platform took
\* survive. On boot the Scheduler's init reconciles. The same step stands for
\* a restart of the job subtree, which the loop of a runner inside its
\* AgentLoop outlives unless it is linked to that runner (LoopDiesWithRunner,
\* runner.ex:1236-1240; spawn_monitor before JOB-8's fix).
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
    /\ report' = [r \in Runs |-> "none"]
    /\ oPc' = "idle"
    /\ oSnap' = NoSnap
    /\ SchedRestart
    /\ UNCHANGED <<jobVars, rowVars, delivered, intent, movesLeft, editsLeft, manualLeft,
                   now, schedCrashes, schedTimeouts, cueSupply>>

\* A stray loop ends: max_iterations, a provider error, or the real daemon
\* dying. It writes nothing: its runner is gone, so its answer reaches no
\* one. No fairness: nothing in Fermix bounds when.
StrayLoopEnds(r) ==
    /\ r \in strayLoops
    /\ strayLoops' = strayLoops \ {r}
    /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, schedVars, ownerVars, now,
                   daemonCrashed, schedCrashes, schedTimeouts, cueSupply>>

-----------------------------------------------------------------------------
Init ==
    /\ jobEnabled = TRUE
    /\ jobState = "scheduled"
    /\ nextRun = 1
    /\ runStatus = [r \in Runs |-> "absent"]
    /\ delivery = [r \in Runs |-> "unset"]
    /\ waiting = 0
    /\ now = 0
    /\ strayLoops = {}
    /\ cueSupply = Cues
    /\ pc = [r \in Runs |-> "off"]
    /\ resp = [r \in Runs |-> "-"]
    /\ finSnap = [r \in Runs |-> NoSnap]
    /\ outcome = [r \in Runs |-> "-"]
    /\ helper = [r \in Runs |-> "none"]
    /\ tries = [r \in Runs |-> 0]
    /\ delivered = [r \in Runs |-> 0]
    /\ report = [r \in Runs |-> "none"]
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
    /\ cuePending = FALSE
    /\ admit = FALSE
    /\ runsKnown = TRUE
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
    /\ \A r \in Runs : ~Alive(r) /\ helper[r] = "none" /\ report[r] = "none"
    /\ strayLoops = {}
    /\ oPc = "idle"
    /\ sPc = "idle" /\ downs = {} /\ ~changed /\ ~cuePending

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ Tick \/ Pause \/ PauseRead \/ PauseWrite \/ Resume \/ UpdateRead \/ UpdateWrite
    \/ ManualRun \/ CueArrives
    \/ DueTimerFires \/ ReconcileFires \/ JobChanged \/ CueAdmit
    \/ \E r \in Runs : HandleDown(r)
    \/ SchedStep
    \/ \E r \in Runs : RunnerStep(r) \/ HelperSend(r) \/ Watchdog(r) \/ RunnerCrash(r)
                       \/ RunnerCrashLate(r) \/ ReportMark(r) \/ ReportSend(r)
                       \/ ReportWrite(r)
    \/ SchedTimeout
    \/ SchedulerCrash \/ SchedulerCrashLate \/ DaemonCrash \/ \E r \in Runs : StrayLoopEnds(r)
    \/ Terminated

\* Fermix drives these itself: a live runner's, send helper's and report
\* task's next step, the runner's delivery timer, the Scheduler's steps inside
\* a callback (weak fairness), and the Scheduler serving its mailbox and its
\* own timers (strong fairness: a message that keeps finding the Scheduler idle
\* is eventually handled). The clock, the owner, the cue inbox, the platform's
\* answers and every crash and Repo timeout get no fairness.
Fairness ==
    /\ WF_vars(SchedStep)
    /\ SF_vars(DueTimerFires) /\ SF_vars(ReconcileFires) /\ SF_vars(JobChanged)
    /\ SF_vars(CueAdmit)
    /\ \A r \in Runs :
          /\ SF_vars(HandleDown(r))
          /\ WF_vars(RunnerStep(r))
          /\ WF_vars(HelperSend(r))
          /\ WF_vars(Watchdog(r))
          /\ WF_vars(ReportMark(r))
          /\ WF_vars(ReportSend(r))
          /\ WF_vars(ReportWrite(r))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* scheduler.ex:619-623: "a job mid-run carries state 'running' (the claim
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

\* scheduler.ex:39-44: a due tick that cannot drain its work, including "a
\* due job whose previous run is still active", re-arms no sooner than the
\* backoff, "so a persistently past-due-but-unclaimable job can never spin
\* the scheduler at 0ms"; :1074-1078 says it again. Read as an action rule: the
\* Arm step that ends a callback whose claim was refused as :already_running
\* never arms the 0 ms timer. (Arm and ArmTimeout, which arms the backoff,
\* are the only steps from "arm" to "idle", or to the candidate scan in a
\* callback that admits.)
NoZeroRearmAfterRefusal ==
    [][(sPc = "arm" /\ refused /\ sPc' \in {"idle", "c_scan"}) => dueTimer' /= "zero"]_vars

\* M60 design §17: "no undecided or passed delivery is stranded while its
\* watcher and task are enabled and under their caps". Read for the Scheduler's
\* part: a passed delivery of an enabled task is in the end claimed (some run
\* of the task is active again), or none is left.
CueClaimedEventually ==
    (waiting > 0 /\ jobEnabled) ~> (waiting = 0 \/ ~jobEnabled \/ Active /= {})

\* cue_run.ex:364-367 (report_final_failure's doc): "the run row's delivery
\* reads `pending` ... before the send and its result after it, so a daemon
\* that dies around the send leaves a row the reconcile pass finishes". Read as:
\* text that reached the user is never left on a run row that records no
\* delivery once nothing is left to write one. A runner's own send always
\* follows a "pending" write; the reaper's report rests on ReportMarksPending.
SentTextRecorded ==
    \A r \in Runs : (delivered[r] >= 1 /\ report[r] = "none") => delivery[r] /= "unset"

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

\* The candidate scan runs while a second delivery waits, the job is enabled
\* and "scheduled" (a resume mid-run) and its run is still active: only the
\* rule's no-active-run part keeps that delivery from a second run, so the
\* one-active-run pass for a cue task is not vacuous.
Witness_CueWaitsBehindRun ==
    ~(/\ sPc = "c_scan" /\ runsKnown /\ CueTask /\ waiting > 0
      /\ jobEnabled /\ jobState = "scheduled" /\ Active /= {})

=============================================================================
