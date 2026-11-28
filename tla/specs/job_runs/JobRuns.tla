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
(* With FollowUp the one job is a watcher's follow-up (schedule_kind       *)
(* "watcher", M60_WATCHER_CODING_RUNS.md §4): as for a cue task, the due   *)
(* scan and the due timer never see it and a resume arms no next run, but  *)
(* the owner may run it now by hand. Its runs start from its watcher's     *)
(* triggers (`starting`, a count; the trigger rows and the cards that      *)
(* lead to them are the cue side's): each admission pass reads them after  *)
(* the re-arm and before the cue runs, and claims each through the claim   *)
(* every run takes. A trigger whose job is paused or still running is      *)
(* refused in that claim, never kept waiting. A follow-up run runs,        *)
(* settles and delivers as a cron run does.                                *)
(*                                                                         *)
(* Time: `now` counts the fire times that have passed and `nextRun` is the *)
(* job row's next_run_at, as the index of a fire time. The job is due when *)
(* nextRun <= now. A claim or a resume sets next_run_at to the next future *)
(* occurrence (now + 1).                                                   *)
(*                                                                         *)
(* Not modelled: the AgentLoop and its own watchdog and transient retry    *)
(* (one "loop" step that ends in text, [SILENT] or an error); media sends; *)
(* other jobs; one-shot ("once") jobs, expiry and an unparseable schedule  *)
(* (see the Scheduler's own writes below); removal; SQLite busy or errors  *)
(* (every Repo call succeeds, unless its caller dies                       *)
(* or, for the Scheduler, times out); the admission ceiling (four runs;    *)
(* one job never has more than two runner processes, so the ceiling's      *)
(* :busy never happens) and the cue share of it (at most three cue runs,   *)
(* so for one job the free cue slots are 0 only while the last reconcile   *)
(* scan failed, runsKnown); the cue inbox's subject rule, daily caps,      *)
(* retry delays and delivery lifetimes (a waiting delivery is claimable at *)
(* once and never expires), and the attempt count that decides a failed    *)
(* cue run's retry; the follow-up's card offers (a Repo call that claims   *)
(* waiting cards, none of them a starting trigger, then a send in a task), *)
(* the hold check before each follow-up claim (FollowUps.check: tools not  *)
(* ready or the switch off refuse the trigger and touch no job row, as     *)
(* the claim's own refusal does), and                                      *)
(* the task that tells the owner of a refused trigger;                     *)
(* delivery_mode "none"/"local" (they behave like a [SILENT] result: final *)
(* at once); memory-source rows, telemetry, the start-up stagger and the   *)
(* network-readiness wait. An owner edit is modelled as one that touches   *)
(* none of the modelled columns (a task or delivery edit).                 *)
(* A run's first tool start is (M106 5.1, 5.3): the loop's process stores  *)
(* it on the run row before the tool runs, in one step with the tool's     *)
(* start (ToolStarts), and a start the store refuses runs no tool and ends *)
(* the loop in an error no retry takes. Without StampsToolStart, the order *)
(* before JOB-9's fix: the tool runs first and the runner stores its start *)
(* when it handles the loop's message (StampsTool). The row the settle     *)
(* writes beside the run row, with the failure's kind, the tool timeline   *)
(* and the tool tally (M106 6), moves no job or run between the states     *)
(* here and is left out.                                                   *)
(*                                                                         *)
(* A failed run's retry (M106 5.3) is modelled: the settle, the runner's   *)
(* and the reaper's, decides it in its own transaction from the run row as *)
(* written (tools_started_at) and the job as released, and keeps it in     *)
(* job_retries (retryAt); the due scan claims a pending retry through the  *)
(* claim every run takes, with next_run_at unmoved; the due claim and the  *)
(* owner's pause, resume, edit and run now clear it. A retry's time is one *)
(* the clock passes before the job's next fire time, so a pending retry is *)
(* taken as due at once (the claim can only come earlier than the code's). *)
(* The attempt count, the ladder of delays and a retry whose time falls at *)
(* or after the next run (it writes no time) are a free choice in the      *)
(* settle, and the drop of a retry older than the freshness window is left *)
(* out (drop_stale_retry). A failure that is not retried goes to a heal    *)
(* (M106 5.4) and sends nothing, unless the job was set up by a guest      *)
(* (GuestJob), whose failure text is sent as before. The heal's rows       *)
(* (job_heals, job_heal_runs) are not modelled: the settle writes them in  *)
(* its transaction beside rows here, and no step here reads them. A failed *)
(* run's settle opens, joins or closes a heal, or reopens a watching one   *)
(* for its verdict. Since M106 6 an ok run's settle does the same when a   *)
(* tool it called never succeeded, as in the job's two runs before it      *)
(* (Jobs.Degraded): it reads those runs' tool tallies in the same          *)
(* transaction, and its own row stays ok and its text is delivered as      *)
(* before. Jobs.HealRun, a child of the RunnerSupervisor that the          *)
(* Scheduler starts, monitors in a map of its own and adopts after a       *)
(* restart, sends the heal's message, a proposal as its card. For a job's  *)
(* heal it first reads the job and runs a diagnosis that writes nothing,   *)
(* then makes at most one move on the job: a pause or a raised time limit, *)
(* since M106 S4 one transaction fenced on its lease, on the job still     *)
(* being the version it read and on no owner write having marked the heal  *)
(* since its claim (Repo.heal_job_write), which is HealRead and HealWrite  *)
(* below (with HealMoves); or, once its message is out, a "run now"        *)
(* (Registry.check_run_now, then Scheduler.run_now), which is ManualRun.   *)
(* Without HealMoves a landed pause or raise writes what Pause or an edit  *)
(* writes, so the owner's steps cover it. The owner's answer to a stored   *)
(* proposal, on its card (Jobs.HealCard, M106 S4b), is the owner's own     *)
(* guarded edit. A plugin's heal has no job and makes no move. The         *)
(* Scheduler's heal claim and its expiry of waiting and watching heals are *)
(* Repo calls on those tables inside callbacks modelled here, where a      *)
(* timeout changes nothing modelled and a crash is SchedulerCrash; and a   *)
(* heal run is no run for the admission ceiling or the cue share, which    *)
(* count runs by the run id each publishes (active_run_count,              *)
(* scheduler.ex:717-721).                                                  *)
(* The access gate is not modelled either. A run's access-sensitive tool   *)
(* call that its job row does not name is refused inside the one loop      *)
(* step, since a scheduled run never parks a call for the owner            *)
(* (access_gate.ex:320-330, :898-907; nor a phone call's start, the gate's *)
(* external effect, :714-724). An owner edit, resume or run now of a job   *)
(* naming such a tool, from a turn that could not run it directly, is      *)
(* refused by the tool before any registry write or Scheduler call         *)
(* (job_registry_support.ex:36-41): a request the owner never made. Its    *)
(* job-row read feeds no modelled column. The store of parked              *)
(* confirmations (AccessGate.Pending, application.ex:499) and the holder   *)
(* of a conversation's place records (ReplyBlocks, :503), which no job     *)
(* process reads, are two more core children started before the            *)
(* RunnerSupervisor, so a crash of either is the daemon crash below.       *)
(*                                                                         *)
(* The Scheduler's own write of a job (with DueCanGoStale): a due scan may *)
(* find the job's due time older than the freshness window, as after a     *)
(* daemon that was down across it, and then skips the run: it moves        *)
(* next_run_at to the next future occurrence and claims nothing this tick  *)
(* (skip_stale_job, scheduler.ex:738-750). The move is one guarded UPDATE  *)
(* of that column with no read before it                                   *)
(* (Repo.advance_stale_scheduled_job/4, with StaleSkipGuarded), so the     *)
(* scan's read and the write are two steps of the Scheduler (Scan,         *)
(* StaleSkip), and the owner's pause, resume and edit may land between     *)
(* them. Without StaleSkipGuarded, the code before the fix: a get, then an *)
(* upsert of the whole row it read (StaleRead, StaleWrite). The            *)
(* Scheduler's two other writes of a job have the same shape and are not   *)
(* modelled apart: the expiry (Repo.expire_scheduled_job/3) and the        *)
(* disable of a job whose schedule no longer parses                        *)
(* (Repo.disable_scheduled_job/4) are each one UPDATE of their own         *)
(* columns, guarded on the job still enabled and "scheduled" and on what   *)
(* each relies on (the expiry passed as of now; the schedule_expr and      *)
(* timezone the scan read), and before the fix each was the same get and   *)
(* whole-row upsert. Both leave the job disabled, which no step here       *)
(* reaches; the stale skip stands for the three because it leaves the job  *)
(* enabled, so a pause the old write undid shows. None of the three is an  *)
(* owner write: none marks a heal, clears a retry or supersedes a          *)
(* proposal. Removal is not modelled, so neither is the old upsert writing *)
(* a removed job back.                                                     *)
(*                                                                         *)
(* Late writes: the Repo serves one request at a time, and a call it does  *)
(* not answer within 5 s (Timeouts.repo_call) is not cancelled: the        *)
(* request lands later, still before any later request from the same       *)
(* caller (repo.ex call/2). The one exception is a claim its caller marks  *)
(* skip_when_late (the Scheduler's claims: claim_due_job, claim_job_now,   *)
(* claim_cue_run, claim_follow_up_run), which the Repo turns away unrun    *)
(* once the caller's deadline has passed (handle_call/3, {:with_deadline,  *)
(* ...}): it writes nothing. A write always lands late. A runner dies on   *)
(* that timeout, so a crash at a runner's Repo write comes in two kinds:   *)
(* the write lands late, or it never lands (a kill). The late kind is      *)
(* modelled where no later crash point stands for it: the runner's final   *)
(* write (RunnerCrashLate). The                                            *)
(* Scheduler survives the timeout (Repo.periodic_opts, repo.ex:1252-1254,  *)
(* :4371-4379): the call returns {:error, :repo_timeout}, and the          *)
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
(*  - a runner's normal exit also drops its monitor; its DOWN :normal,     *)
(*    whose handler re-arms the timer, still waits in the mailbox (exits).  *)
(*                                                                         *)
(* Run ids are reused once a run is fully finished, so two ids model an    *)
(* unbounded run history. A daemon crash also stands for a crash of any    *)
(* core child started before the RunnerSupervisor (Memory.Repo, Trace,     *)
(* Finch, MainAgent and the rest, application.ex:427-511) or of the        *)
(* RunnerSupervisor itself: under :rest_for_one each restarts the          *)
(* RunnerSupervisor with its runners and the Scheduler                     *)
(* (application.ex:290). A runner's send helper (REMIND-2,                 *)
(* channel_send.ex:219-224) and its AgentLoop (JOB-8, runner.ex:1467-1471) *)
(* are linked to it, so the restart kills them too. With                   *)
(* LoopDiesWithRunner off (the code before JOB-8's fix, an unlinked        *)
(* spawn_monitor) the loop outlives it (strayLoops). Process-local values  *)
(* a step no longer needs are cleared, so that dead values do not          *)
(* multiply the states.                                                    *)
(*                                                                         *)
(* Runner steps (pc[r]), each named after the action that takes it. With   *)
(* AtomicSettle (the real code):                                           *)
(*   off -Start-> start -MarkRunning-> loop -Loop-> complete | fail        *)
(*   (inside the loop, ToolStarts, then StampsTool without StampsToolStart, *)
(*   before Loop can end; a start the store refused ends the loop: fail)    *)
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
(*   scan -Scan-> claim | arm | skip   claim -Claim-> start | arm          *)
(*   skip -StaleSkip-> arm, or without StaleSkipGuarded:                   *)
(*   skip -StaleRead-> s_write | arm   s_write -StaleWrite-> arm           *)
(*   start -Start-> arm         arm -Arm-> idle, or c_scan if it admits    *)
(*   (f_scan instead of c_scan for a follow-up)                            *)
(*   f_scan -FollowUpScan-> f_claim | c_scan                               *)
(*   f_claim -FollowUpClaim-> f_claim | f_start | c_scan                   *)
(*   f_start -FollowUpStart-> f_start | c_scan                             *)
(*   c_scan -CueCandidates-> c_claim | idle                                *)
(*   c_claim -CueClaim-> c_start | idle   c_start -CueStart-> idle         *)
(* A timed-out Repo call takes its call site's error branch:               *)
(*   r_rows -ReconcileRowsTimeout-> reapReturn (no pass)                   *)
(*   r_mark -ReapLookupTimeout-> (next orphan or reapReturn; no write)     *)
(*   scan -ScanTimeout-> idle      claim -ClaimTimeout-> idle (may land)   *)
(*   arm -ArmTimeout-> idle        idle -ManualRunTimeout-> arm (may land) *)
(*   skip | s_write -StaleSkipTimeout-> idle (the write lands; the get of  *)
(*   the code before the fix writes nothing)                               *)
(*   (the first three and the last go to c_scan instead when the callback  *)
(*   admits)                                                               *)
(*   c_scan -CueCandidatesTimeout-> idle                                   *)
(*   c_claim -CueClaimTimeout-> idle (may land)                            *)
(*   f_scan -FollowUpScanTimeout-> c_scan                                  *)
(*   f_claim -FollowUpClaimTimeout-> as FollowUpClaim (may land)           *)
(* reapReturn is where the Scheduler goes once its reaping is done: "arm"  *)
(* after init, "scan" in the 60 s tick, "arm" after a DOWN (M106 5.3: the   *)
(* timer is re-armed at every run's end; "idle" without RearmsOnDown).     *)
(*   idle -HandleExit-> arm (a runner's normal exit; "idle" without        *)
(*   RearmsOnDown)                                                          *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/scheduler.ex @ e92cfe390e17
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/runner.ex @ 6759692b63dd
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/runner_supervisor.ex @ 6a21dfe6cfad
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/delivery.ex @ b1dd0422b409
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/registry.ex @ f42f27975a5f
\* SOURCE: apps/fermix_core/lib/fermix_core/delivery/channel_send.ex @ 9b06289e25ae
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#call,request_message,deadline_after,deadline_passed?,call_or_timeout_error,request_name,periodic_opts,claim_due_job,claim_job_now,claim_due_job_tx,claim_in_tx,claim_job_now_tx,transact_claim,fetch_claimable_due_job,finish_job_claim,rollback_job_claim,upsert_scheduled_job_row,upsert_job_run_row,ensure_no_active_job_run,fetch_claimable_job,settle_job_run,settle_job_run_tx,settle_job_run_in_tx,ensure_job_run_active,release_settled_job,finish_job_settle,rollback_job_settle,unsettled_job_runs,fetch_unsettled_job_runs,@unsettled_job_runs_sql,update_scheduled_job_fields,update_scheduled_job_fields_row,scheduled_job_field_assignments!,scheduled_job_field_assignment!,@owner_text_fields,due_scheduled_jobs,fetch_due_scheduled_jobs,next_scheduled_job,fetch_next_scheduled_job,upsert_job_run,upsert_scheduled_job,get_job_run,get_scheduled_job,upsert_memory,claim_retry_job,claim_retry_job_tx,fetch_claimable_retry_job,then_in_claim,scheduled_job_with_retry,@earliest_wakeup_sql @ bb2d114865d9
\* SOURCE: apps/fermix_core/lib/fermix_core/application.ex#start_supervision_tree,supervision_children,daemon_children,jobs_scheduler_opts @ 1f97ceee174c
\* SOURCE: apps/fermix_core/lib/fermix_core/timeouts.ex#expired,repo_call,@repo_call_ms @ 05d3e6ea2142
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/cue_admission.ex @ b98563b66ad5
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#claim_cue_run,claim_cue_run_tx,claim_cue_run_in_tx,claim_delivery,settle_cue_run,settle_cue_run_tx,settle_cue_run_in_tx,ensure_not_cue_run,active_run_trigger,release_cue_job @ 895445d8ff8b
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/cues_runs_sql.ex#@open_sql,@cap_room_sql,@eligible_sql,@candidates_sql,@eligible_delivery_sql,eligible_delivery,settle_delivery @ 80ae2421c1fd
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/cue_run.ex#report_final_failure,record_delivery,write_delivery @ 070e32fa6e21
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#claim_follow_up_run,claim_follow_up_run_tx,claim_follow_up_job,refuse_follow_up,follow_up_refusal @ 820a5c3759c7
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/cues_follow_up_sql.ex#claimable,mark_started,refuse_starting @ 0b00297833af
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/retry.ex @ 29a81ebd67c8
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/job_retries_sql.ex @ d45d0abed8ea
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/job_heals_sql.ex#settle,take_failure,not_closed,verdict,join,open_or_quiet,open,link_run,close_rows,expire_waiting,expire_rows,rerun_outcome,degraded,earlier_tallies,settle_ok,close_proven,open_for,query_open_for,close_ids,run_tally,claimant,claim_written,moved_on,mark_written_under,take_lease,bind_card,write_card,answered @ 24ed0c910ce9
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/degraded.ex @ a44077b00219
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#heal_job_write,heal_job_write_tx,heal_job_write_fenced,heal_job_write_in_tx,write_scheduled_job_fields,supersede_moved,written_under? @ f9994ae3ed8a
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#advance_stale_scheduled_job,advance_stale_scheduled_job_row,guarded_scheduled_job_write,expire_scheduled_job,expire_scheduled_job_row,disable_scheduled_job,disable_scheduled_job_row @ b44b3603da12
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/heal_decision.ex#job_version,@version_fields,@run_written_fields,decide @ 9df0bacc4c33
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/heal_answer.ex#apply_change,leave,waiting,answerable,write @ bf4282c66847
\* SOURCE: apps/fermix_core/lib/fermix_core/agent_loop.ex#run,run_tool_call,gate_tool,trace_unexecuted @ fb2d6fbb7f69
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/failure.ex#provider_failure? @ e1cc6a876455
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/heal_run.ex @ 00d796041b7b
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/heal_diagnosis.ex#@allowed_tools,supervise_loop,await_loop,report_loop,release_loop,kill_loop @ 4c906da777a9
EXTENDS Naturals, FiniteSets

CONSTANTS
    \* Bounds.
    NumRuns,            \* run ids, e.g. 2 (reused once a run is fully finished)
    Fires,              \* fire times the clock passes through, e.g. 2
    SendAttempts,       \* ChannelSend attempts per delivery (the code uses 3)
    OwnerMoves,         \* pause/resume requests the owner may make
    OwnerEdits,         \* update_job requests the owner may make
    ManualRuns,         \* "run now" requests the owner may make
    HealMoves,          \* moves a heal run may make on the job (0 or 1): a pause or a raised
                        \* time limit, drawn from the job as read before its diagnosis
    Cues,               \* passed deliveries the cue inbox may hand the task, each with its wake;
                        \* for a follow-up, the triggers its watcher may set starting, each with
                        \* its wake
    \* Environment switches: what may happen.
    DaemonCanCrash,     \* the daemon dies once (every process) and boots again
    SchedulerCrashes,   \* how many times the Scheduler alone may die of a cause other than a
                        \* Repo timeout, e.g. :rest_for_one restarting it when the
                        \* MeetingsSupervisor between the RunnerSupervisor and it dies
                        \* (application.ex:512-519)
    SchedulerTimeouts,  \* how many of the Scheduler's Repo calls may time out (5 s); it takes
                        \* that call site's error branch and keeps running (repo.ex:1252-1254)
    RunnerCanCrash,     \* a runner dies at one of its Repo calls (a timeout, a failed match)
    LoopCanFail,        \* the AgentLoop ends in an error or a timeout
    PlatformCanFail,    \* a send fails: no connection, or an error after the platform took it
    ResponsesCanStall,  \* the platform takes a message and its answer never arrives in time;
                        \* with DeliveryWatchdog off the wait is unbounded (the adapters'
                        \* own HTTP timeouts are outside the sources)
    \* Configuration: what kind of home and job.
    CuesOn,             \* the cue tree runs (Cues.running?/0, read by the Scheduler for every
                        \* request and every admission; a home with
                        \* [fermix_core.cues] enabled): the Scheduler admits cue runs. Every
                        \* check before 36 sets it FALSE, the Scheduler of a home without cues
    CueTask,            \* the job is a watcher's task, a job that runs on cues (schedule_kind
                        \* "cue", registry.ex:5-11): only with CuesOn. FALSE: a cron job
    FollowUp,           \* the job is a watcher's follow-up (schedule_kind "watcher", made only
                        \* by create_follow_up_job/2, registry.ex:13-18): only with CuesOn,
                        \* never with CueTask. Every check before 54 sets it FALSE
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by the checks that show a property needs it.
    AtomicRaceStop,           \* the claim refuses while a run is queued/running (repo.ex:7006, :7059-7077);
                              \* the due, manual and follow-up claims alike (claim_in_tx, repo.ex:7798)
    RetriesOnlyUnsent,        \* a send is retried only when it never reached the platform (channel_send.ex:140-143, :194-202);
                              \* the mechanism for platforms that do not dedupe on the run's proactive_key
    ReconcilesRuns,           \* init and every 60 s reap orphaned runs, adopt live runners (scheduler.ex:266, :302-315, :548-626)
    CrashFailsPendingDelivery,\* a dead runner's pending delivery is marked failed, whatever the run's
                              \* status (scheduler.ex:1135-1137, :1171-1184)
    DeliveryWatchdog,         \* the runner stops waiting for a send after delivery_timeout_ms (channel_send.ex:219-241)
    AtomicSettle,             \* a run's final row and its job's release are one transaction, for the
                              \* runner and the reaper alike (repo.ex:2563-2566, :7015-7031, :7091-7138)
    ReconcilesPending,        \* the reconcile pass also reads runs whose delivery is still pending
                              \* (unsettled_job_runs, repo.ex:2602-2655, scheduler.ex:560)
    RefusalBacksOff,          \* a due claim refused as :already_running is backpressure: the re-arm
                              \* floors at the 5 s backoff (scheduler.ex:827-830, :1420-1433)
    OwnerWritesColumns,       \* pause, resume and update_job write only the columns they own
                              \* (registry.ex:333-376; repo.ex:2506-2509, :7286-7293, :8260-8298)
    LoopDiesWithRunner,       \* a runner's AgentLoop is linked to it, so a restart that kills
                              \* the runner kills its loop too (runner.ex:1467-1471)
    TicksAdmit,               \* the due and reconcile ticks run cue admission after their due
                              \* scan (handle_info(:due_tick | :reconcile_tick), scheduler.ex
                              \* :295-315), so a cue whose wake found nothing to claim is still
                              \* admitted later
    ReportMarksPending,       \* the reaper's final failure report marks its run's delivery
                              \* "pending" before it sends (mark_attempted, cue_run.ex:377,
                              \* :386-391), so a daemon that dies around the send leaves a row
                              \* the reconcile pass finishes
    RearmsOnDown,             \* every runner's DOWN, a normal exit or a crash, re-arms the due
                              \* timer for the earliest wakeup, a retry's included
                              \* (handle_info({:DOWN, ...}), scheduler.ex:339-367)
    StampsToolStart,          \* a run's first tool start is on its row before the tool runs: the
                              \* loop calls the runner's gate ahead of each call (gate_tool,
                              \* agent_loop.ex:1396-1457; put_tool_start_store, runner.ex
                              \* :1739-1778), so a run the Scheduler settles after a crash has it
    RetryNeedsNoTool,         \* Retry.decide retries only a run in which no tool had started
                              \* (retried?, retry.ex:88-89)
    HealMoveGuarded,          \* a heal run's move is ONE transaction that writes the job only
                              \* while it is still the version the move was drawn for
                              \* (heal_job_write_tx, repo.ex:9030-9064; HealDecision.job_version/1);
                              \* FALSE: the S3 shape, the move written whatever the job became
    MarksOwnerWrites,         \* every owner write marks the job's diagnosing heal
                              \* (mark_written_under, in update_scheduled_job_fields_row,
                              \* repo.ex:8989-9002), the heal's claim clears the mark (take_lease),
                              \* and a heal run's move under a marked heal is not made
                              \* (written_under?, :9047-9056); FALSE: the version compare alone
    OwnerClearsRetry,         \* the owner's pause, resume and edit (update_scheduled_job_fields_row,
                              \* repo.ex:8820-8834) and run now (claim_job_now_tx, :8303-8312)
                              \* delete the job's retry in their own transaction
    \* More environment and configuration (M106).
    ToolsCanStart,            \* a run's AgentLoop may start a tool before it ends; FALSE: every
                              \* run ends before any tool
    ProviderCanFail,          \* a loop error may be one waiting can clear, the provider's
                              \* (failure_settle_by, runner.ex:625-627), which the runner's
                              \* settle retries; FALSE: no loop error is the provider's
    StampCanFail,             \* the store refuses a run's first tool start (an error, or no
                              \* answer within the Repo's bound); FALSE: it always records it
    GuestJob,                 \* the job was set up at guest trust: a failure no retry takes
                              \* sends its failure text (finish_failure, runner.ex:638-641);
                              \* FALSE: the owner's job, whose failure a heal takes, sending
                              \* nothing (:643-646)
    \* The Scheduler's own write of a job.
    DueCanGoStale,            \* a due scan may find the job's due time older than the freshness
                              \* window (stale?, scheduler.ex:723-736: the daemon was down across
                              \* it), and then skips the run (skip_stale_job, :738-750); FALSE:
                              \* every due time is fresh. Every check before 77 sets it FALSE
    StaleSkipGuarded          \* the stale skip's write is ONE guarded UPDATE of next_run_at, with
                              \* no read before it (advance_stale_job, scheduler.ex:760-782;
                              \* Repo.advance_stale_scheduled_job/4, repo.ex:2786-2794, :9330-9341,
                              \* :9377-9383): the job written only while still enabled,
                              \* "scheduled" and due at the instant the scan read; FALSE: the
                              \* code before the fix, a get and then an upsert of the whole row
                              \* it read

Runs == 1..NumRuns

VARIABLES
    \* --- SQLite rows (survive every crash) ---
    jobEnabled,  \* scheduled_jobs.enabled
    jobState,    \* scheduled_jobs.state: "scheduled" | "running" | "paused"
    nextRun,     \* scheduled_jobs.next_run_at, as a fire-time index
    runStatus,   \* runStatus[r]: job_runs.status ("absent" = no row for this id yet)
    delivery,    \* delivery[r]: job_runs.delivery_status; "unset" is the "none" the claim
                 \* writes before a result exists (scheduler.ex:972), kept apart from the
                 \* final "none" of delivery_mode "none" (modelled as "skipped")
    waiting,     \* the task's passed deliveries a claim may take (cue_deliveries rows in
                 \* state passed, as a count; always 0 for a cron job)
    starting,    \* the follow-up's triggers its next admission pass takes (cue_follow_up_
                 \* triggers rows in state starting, as a count; always 0 for any other job)
    retryAt,     \* job_retries.retry_at: "none" (no row, or a retry with no time) or a
                 \* pending retry, tagged with what led to it: "clean", "afterTool" (its
                 \* run had started a tool its row did not record) or "afterOwner" (it
                 \* outlived an owner's pause, resume, edit or run now); the tags are
                 \* for the properties, the code keeps one time
    tool,        \* tool[r]: whether a tool of r has started: "none" | "stamped" (its
                 \* start is job_runs.tools_started_at) | "refused" (the store refused
                 \* the start, so no tool ran) | "ran" (a tool runs with its start not
                 \* on the row: only the order before JOB-9's fix, StampsToolStart off)
    \* --- the environment ---
    now,         \* fire times that have passed (the wall clock)
    strayLoops,  \* runs whose AgentLoop outlived its runner in a daemon crash (only
                 \* without LoopDiesWithRunner): a process no model step reaches
    cueSupply,   \* passed deliveries (or, for a cron job, wakes; for a follow-up, starting
                 \* triggers) still to come
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
    sSnap,       \* the job row it read for the job write it makes next: its split
                 \* reaper's (AtomicSettle off only), or its stale skip's, the due
                 \* scan's read (and without StaleSkipGuarded the get after it)
    cuePending,  \* a :cue_admit pass waits in its mailbox (cue_pending?, one for any
                 \* number of requests)
    admit,       \* this callback runs cue admission once its due scan and re-arm end
    runsKnown,   \* its last reconcile scan succeeded, so its monitors hold every live
                 \* runner (runs_known?, scheduler.ex:247-249, :563, :571); only cue
                 \* admission reads it, so without cues it is kept TRUE
    fQ,          \* the starting triggers its follow-up scan read and has yet to claim
    fClaimed,    \* the follow-up runs it claimed in this pass and has yet to start
    exits,       \* runs whose runner's normal DOWN waits in its mailbox
    sBy,         \* what this callback's due scan will claim the job by: "due" (its next
                 \* run) | "retry" | "-"
    \* --- the owner (through the pause_job / resume_job / update_job / run_job_now tools) ---
    oPc,         \* "idle" | "pausing" (a split pause read the row) | "editing" (an edit read it)
    oSnap,       \* the job row that pause or edit read
    intent,      \* the owner's last pause/resume, as acknowledged to them
    movesLeft,   \* pause/resume requests left
    editsLeft,   \* update_job requests left
    manualLeft,  \* "run now" requests left
    \* --- a heal run's move on the job (M106 5.6), with HealMoves > 0 ---
    hPc,         \* "idle" | "read" (it read the job before its diagnosis) | "done"
    hSnap,       \* the job's version as it read it: enabled and the definition
    hKind,       \* the move its plan holds: "-" | "pause" | "raise"
    defVer,      \* the job's definition as the version reads it (every field but
                 \* enabled), counted: each edit, the owner's or the heal's, moves it
                 \* (only with a heal move or DueCanGoStale, whose steps read it)
    sinceRead,   \* the owner's writes since the heal run's read: "pause", "resume", "edit"
    hMark,       \* job_heals.owner_wrote_at: an owner write since the heal's claim
    overwrote,   \* a heal's raise landed while an owner edit made since its read stood
    undidResume, \* a heal's pause landed after an owner resume made since its read
    \* --- bookkeeping ---
    daemonCrashed, \* the daemon has died (at most once)
    schedCrashes,  \* times the Scheduler alone has died
    schedTimeouts  \* times a Scheduler Repo call has timed out

jobVars    == <<jobEnabled, jobState, nextRun>>
rowVars    == <<runStatus, delivery, waiting, starting, retryAt, tool>>
runnerVars == <<pc, resp, finSnap, outcome>>
helperVars == <<helper, tries, delivered, report>>
schedVars  == <<sPc, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
               activeSnap, reapQ, sSnap, cuePending, admit, runsKnown, fQ, fClaimed,
               exits, sBy>>
healVars   == <<hPc, hSnap, hKind, defVer, sinceRead, hMark, overwrote, undidResume>>
ownerVars  == <<oPc, oSnap, intent, movesLeft, editsLeft, manualLeft, healVars>>
envVars    == <<now, strayLoops, daemonCrashed, schedCrashes, schedTimeouts, cueSupply>>
vars == <<jobVars, rowVars, runnerVars, helperVars, schedVars, ownerVars, envVars>>

-----------------------------------------------------------------------------
PcStates == {"off", "start", "loop", "complete", "memo", "fail",
             "finread", "finwrite", "await", "mark", "gone"}
SchedStates == {"idle", "r_rows", "r_live", "r_mark", "r_read", "r_write",
                "scan", "claim", "start", "arm", "c_scan", "c_claim", "c_start",
                "f_scan", "f_claim", "f_start", "skip", "s_write"}
Snaps == [en : BOOLEAN, st : {"scheduled", "running", "paused", "none"},
          next : 0..(Fires + 1)]
NoSnap == [en |-> FALSE, st |-> "none", next |-> 0]
\* The Scheduler's own reads of the job carry its definition too, which the
\* whole-row upsert of the code before the stale skip's fix wrote back.
SchedSnaps == [en : BOOLEAN, st : {"scheduled", "running", "paused", "none"},
               next : 0..(Fires + 1), ver : 0..(OwnerEdits + HealMoves)]
NoSchedSnap == [en |-> FALSE, st |-> "none", next |-> 0, ver |-> 0]
Final == {"skipped", "sent", "failed"}

\* Fairness gives JobChanged and CueAdmit strong fairness only in a
\* configuration that can take them; this holds that the others cannot.
\* Every check carries TypeOK, so each proves that its own omission is sound.
FairnessScope ==
    /\ OwnerMoves + OwnerEdits + HealMoves = 0 => ~changed
    /\ ~CuesOn => ~cuePending

TypeOK ==
    /\ jobEnabled \in BOOLEAN
    /\ jobState \in {"scheduled", "running", "paused"}
    /\ nextRun \in 1..(Fires + 1)
    /\ runStatus \in [Runs -> {"absent", "queued", "running", "ok", "error"}]
    /\ delivery \in [Runs -> {"unset", "pending"} \cup Final]
    /\ waiting \in 0..Cues /\ starting \in 0..Cues
    /\ retryAt \in {"none", "clean", "afterTool", "afterOwner"}
    /\ tool \in [Runs -> {"none", "ran", "stamped", "refused"}]
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
    /\ sSnap \in SchedSnaps
    /\ oPc \in {"idle", "pausing", "editing"}
    /\ oSnap \in Snaps
    /\ cuePending \in BOOLEAN /\ admit \in BOOLEAN /\ runsKnown \in BOOLEAN
    /\ fQ \in 0..Cues /\ fClaimed \subseteq Runs
    /\ exits \subseteq Runs /\ sBy \in {"-", "due", "retry"}
    /\ FairnessScope
    /\ intent \in {"none", "paused", "resumed"}
    /\ movesLeft \in 0..OwnerMoves /\ editsLeft \in 0..OwnerEdits
    /\ manualLeft \in 0..ManualRuns
    /\ hPc \in {"idle", "read", "done"}
    /\ hSnap \in [en : BOOLEAN, ver : 0..(OwnerEdits + HealMoves)]
    /\ hKind \in {"-", "pause", "raise"}
    /\ defVer \in 0..(OwnerEdits + HealMoves)
    /\ sinceRead \subseteq {"pause", "resume", "edit"}
    /\ hMark \in BOOLEAN /\ overwrote \in BOOLEAN /\ undidResume \in BOOLEAN
    /\ daemonCrashed \in BOOLEAN /\ schedCrashes \in 0..SchedulerCrashes
    /\ schedTimeouts \in 0..SchedulerTimeouts

-----------------------------------------------------------------------------
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

\* The due scan and the due timer never see a job a watcher runs, a cue task
\* or a follow-up: it has neither a next_run_at nor an expiry
\* (fetch_due_scheduled_jobs, fetch_next_scheduled_job, repo.ex:6893-6949;
\* registry.ex:5-18).
WatcherJob == CueTask \/ FollowUp
Due == ~WatcherJob /\ nextRun <= now
Alive(r) == pc[r] \notin {"off", "gone"}

\* Rows that hold an active slot: what ensure_no_active_job_run counts
\* (repo.ex:6980-6998) and the settle's guard accepts (repo.ex:7091-7098).
Active == {r \in Runs : runStatus[r] \in {"queued", "running"}}

\* What the reconcile scan reads: unsettled_job_runs, the active rows and then
\* the rows whose delivery is still pending (repo.ex:2602-2655); without
\* ReconcilesPending, the active rows alone.
Scanned == IF ReconcilesPending
           THEN Active \cup {r \in Runs : delivery[r] = "pending"}
           ELSE Active

JobRow == [en |-> jobEnabled, st |-> jobState, next |-> nextRun]
SchedRow == [en |-> jobEnabled, st |-> jobState, next |-> nextRun, ver |-> defVer]

\* The settle's job release (release_settled_job, repo.ex:7104-7129): one
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
       /\ r \notin monitors \cup downs \cup exits \cup activeSnap \cup reapQ \cup strayLoops
       /\ r /= sRun
FreeIds == {r \in Runs : Reusable(r)}

\* The job_runs row the claim inserts (run_attrs, scheduler.ex:964-976),
\* and a clean slate for the per-run process and platform variables.
NewRun(r) ==
    /\ runStatus' = [runStatus EXCEPT ![r] = "queued"]
    /\ delivery' = [delivery EXCEPT ![r] = "unset"]
    /\ tool' = [tool EXCEPT ![r] = "none"]
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
\* cues_runs_sql.ex:276-306): a completed run acks it; a failed one puts it
\* back to passed (retry) or ends it (exhausted, or untouched), which this spec
\* chooses freely: the attempt count, the provider-failure rule and the
\* tools_started_at marker are tla/specs/cue_inbox's. A cron run holds none.
Retries(r) == IF CueTask /\ pc[r] = "fail" THEN BOOLEAN ELSE {FALSE}

\* A job's retry (M106 5.3). It is decided by the settle of a run of a job that
\* is not a cue task (settle_job_run_in_tx -> JobRetriesSql.settle/4,
\* repo.ex:8547-8562, job_retries_sql.ex:43-57), in the same transaction: a cue
\* run settles through settle_cue_run, which leaves job_retries alone, and the
\* split finish of the code before AtomicSettle had no retries.
RetryPending == retryAt /= "none"
SettleDecidesRetry == AtomicSettle /\ ~CueTask

\* Retry.decide (retry.ex:72-92): a failure is retried only when it was
\* settled :scheduler or {:failed, :provider}, no tool had started, and the
\* job runs again: interval or cron (never a follow-up's kind "watcher"),
\* enabled and "scheduled" once its run released it (runs_again?), which the
\* release makes of "running" and "scheduled" alike. Whether the retry gets a
\* time (before both the next run and the expiry) or none (the next run is the
\* retry, which writes no time) and whether the count is spent (the fourth in
\* a row is :exhausted) are a free choice.
RunsAgain == ~WatcherJob /\ jobEnabled /\ jobState \in {"running", "scheduled"}

\* The runner's own settle of a failed run: {:failed, :provider} only when the
\* provider failed (failure_settle_by, runner.ex:625-627), so never after a
\* start the store refused (tool_start_unrecorded, which is no provider's
\* failure: provider_failure?, failure.ex:319). `tool` is what the runner
\* knows: it handled every message of the loop's before its result
\* (watch_loop, :1799-1807, put_run_facts, :1994-2002).
RunnerRetries(r) ==
    IF /\ SettleDecidesRetry /\ pc[r] = "fail" /\ ProviderCanFail /\ RunsAgain
       /\ tool[r] /= "refused"
       /\ (tool[r] = "none" \/ ~RetryNeedsNoTool)
    THEN BOOLEAN ELSE {FALSE}

\* The Scheduler's crash settle (:scheduler, mark_run_error, scheduler.ex
\* :1106-1133): the run row as it reads it, so a tool counts only if stamped.
ReapRetries(r) ==
    IF SettleDecidesRetry /\ (tool[r] /= "stamped" \/ ~RetryNeedsNoTool) /\ RunsAgain
    THEN BOOLEAN ELSE {FALSE}

\* What the settle leaves in job_retries: the retry, or no row (a retry with no
\* time, an exhausted one, any other failure and an ok run alike).
SettledRetry(set, r) ==
    retryAt' = IF set THEN (IF tool[r] \in {"ran", "stamped"} THEN "afterTool" ELSE "clean")
               ELSE IF SettleDecidesRetry THEN "none" ELSE retryAt

\* An owner's write while a heal run diagnoses: recorded as made since its
\* read (a ghost for the heal's properties), and marked on the heal in the
\* write's own transaction, whatever value it leaves (JOB-12's fix:
\* JobHealsSql.mark_written_under/3 in update_scheduled_job_fields_row,
\* repo.ex:8989-9002; every pause, resume and edit reaches that write). The
\* code marks the heal from its claim on, which comes before the run's read:
\* a mark the model starts at the read refuses fewer moves, never more.
OwnerSince(move) ==
    /\ sinceRead' = IF hPc = "read" THEN sinceRead \cup {move} ELSE sinceRead
    /\ hMark' = (hMark \/ hPc = "read")
HealQuiet == <<hPc, hSnap, hKind, overwrote, undidResume>>

\* What the owner's pause, resume, edit or run now leaves of a pending retry.
OwnerLeavesRetry ==
    retryAt' = IF OwnerClearsRetry THEN "none"
               ELSE IF retryAt = "clean" THEN "afterOwner" ELSE retryAt

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
\* Scheduler.cue_wake/1 (scheduler.ex:166-169), whose handle_cast(:cue_wake)
\* sends one :cue_admit unless one is already pending (request_admission,
\* :290-292, :375-380); the cast and that send are folded into one flag. For a
\* cron job the delivery is another task's and only the wake is modelled.
\* For a follow-up the step is a trigger written starting with its wake: an
\* item passing an always-allowed follow-up's watcher (CuesFollowUpSql.on_pass,
\* in the pass's transaction; the filter's wake, filters.ex:321, or the
\* accept's, ingest.ex:205), or the owner's Run or Always allow on its card,
\* waiting -> starting (FollowUps.confirm, always_allow or decide, then the
\* wake, follow_ups.ex:518).
CueArrives ==
    /\ CuesOn /\ cueSupply > 0
    /\ cueSupply' = cueSupply - 1
    /\ waiting' = IF CueTask THEN waiting + 1 ELSE waiting
    /\ starting' = IF FollowUp THEN starting + 1 ELSE starting
    /\ cuePending' = TRUE
    /\ UNCHANGED <<jobVars, runStatus, delivery, retryAt, tool, runnerVars, helperVars,
                   ownerVars, now, strayLoops, daemonCrashed, schedCrashes, schedTimeouts,
                   sPc, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* Owner steps leave the Scheduler alone, except for the :job_changed cast, and
\* of the rows touch only the job's and its retry (OwnerLeavesRetry).
OwnerQuiet == <<runStatus, delivery, waiting, starting, tool, runnerVars, helperVars,
                envVars, sPc, reapReturn, monitors, downs, dueTimer, refused, sRun,
                activeSnap, reapQ, sSnap, cuePending, admit, runsKnown, fQ, fClaimed,
                exits, sBy>>

\* Registry.pause_job (registry.ex:128-130 -> update_job_fields :336-346):
\* Repo.update_scheduled_job_fields writes enabled = false and state =
\* "paused" in place (repo.ex:2506-2509, :7286-7293), then the :job_changed cast
\* (registry.ex:813-818). The owner is told "paused". Nothing is read first.
\* The write and the deletion of the job's retry are one BEGIN IMMEDIATE
\* (update_scheduled_job_fields_row, repo.ex:8820-8834), and so for resume
\* and update_job below (OwnerLeavesRetry). Since M106 S4 the same
\* transaction reads the job before and after its write and, when the
\* job's version moved (HealDecision.job_version/1, enabled included),
\* closes its waiting heal proposal superseded (update_scheduled_job_fields_row,
\* repo.ex:8989-9002; supersede_moved, :9020-9024), and marks the job's
\* diagnosing heal whatever the write leaves (OwnerSince's hMark): heal rows
\* only. A heal run's pause is no longer this call: it is HealWrite below.
Pause ==
    /\ OwnerWritesColumns
    /\ oPc = "idle" /\ movesLeft > 0
    /\ jobEnabled' = FALSE
    /\ jobState' = "paused"
    /\ OwnerLeavesRetry
    /\ changed' = TRUE
    /\ intent' = "paused"
    /\ movesLeft' = movesLeft - 1
    /\ OwnerSince("pause")
    /\ UNCHANGED <<OwnerQuiet, nextRun, oPc, oSnap, editsLeft, manualLeft, HealQuiet, defVer>>

\* Without OwnerWritesColumns, the pause before the fix: first
\* Repo.get_scheduled_job ...
PauseRead ==
    /\ ~OwnerWritesColumns
    /\ oPc = "idle" /\ movesLeft > 0
    /\ oPc' = "pausing"
    /\ oSnap' = JobRow
    /\ movesLeft' = movesLeft - 1
    /\ UNCHANGED <<OwnerQuiet, jobVars, retryAt, changed, intent, editsLeft, manualLeft,
                   healVars>>

\* ... then an upsert of the row it read with enabled = false, state =
\* "paused" (next_run_at as read), then the :job_changed cast. The code before
\* the fix had no retries; the write is given the retry's deletion all the
\* same, so that only the column write differs from Pause.
PauseWrite ==
    /\ oPc = "pausing"
    /\ jobEnabled' = FALSE
    /\ jobState' = "paused"
    /\ nextRun' = oSnap.next
    /\ OwnerLeavesRetry
    /\ changed' = TRUE
    /\ intent' = "paused"
    /\ oPc' = "idle"
    /\ oSnap' = NoSnap
    /\ OwnerSince("pause")
    /\ UNCHANGED <<OwnerQuiet, movesLeft, editsLeft, manualLeft, HealQuiet, defVer>>

\* Registry.resume_job (registry.ex:132-144): get the row, then write enabled =
\* true, state = "scheduled" and next_run_at = the next future occurrence
\* (update_job_fields, :336-346), whatever state the job is in (nothing checks
\* that it is paused), then the :job_changed cast. The read is folded into the
\* write: every modelled column the write sets comes from the patch, none from
\* the read, with or without OwnerWritesColumns. A resume of a job a watcher
\* runs, a cue task or a follow-up, arms no next run (next_run_at_for_resume,
\* registry.ex:455-457).
Resume ==
    /\ oPc = "idle" /\ movesLeft > 0
    /\ jobEnabled' = TRUE
    /\ jobState' = "scheduled"
    /\ nextRun' = IF WatcherJob THEN nextRun ELSE now + 1
    /\ OwnerLeavesRetry
    /\ changed' = TRUE
    /\ intent' = "resumed"
    /\ movesLeft' = movesLeft - 1
    /\ OwnerSince("resume")
    /\ UNCHANGED <<OwnerQuiet, oPc, oSnap, editsLeft, manualLeft, HealQuiet, defVer>>

\* Registry.update_job (registry.ex:147-155 -> prepare_update :228-234):
\* Repo.get_scheduled_job, whose row the edit is computed from
\* (normalize_update_attrs) ... A heal run's raised limit is no longer this
\* edit: it is HealWrite below. The owner's answer to a stored proposal, a
\* /confirm on its card (Jobs.HealCard -> Jobs.HealAnswer.apply_change/4,
\* in a task the gateway starts, M106 S4b), is the owner's own edit: its
\* reads, then one guarded write (heal_job_write_tx under the answer claim,
\* the heal answerable and the job's version unmoved), then the
\* :job_changed cast. That is this step with the read at the write, or no
\* write.
UpdateRead ==
    /\ oPc = "idle" /\ editsLeft > 0
    /\ oPc' = "editing"
    /\ oSnap' = JobRow
    /\ editsLeft' = editsLeft - 1
    /\ UNCHANGED <<OwnerQuiet, jobVars, retryAt, changed, intent, movesLeft, manualLeft,
                   healVars>>

\* ... then apply_job_update (registry.ex:350-376). With OwnerWritesColumns,
\* Repo.update_scheduled_job_fields writes only the edited columns, never
\* state, enabled or last_* (repo.ex:7286-7293; the owner field list,
\* :8096-8134): the modelled edit writes no modelled column. Without it, the
\* code before the fix upserted the whole row it read, writing back the
\* enabled, state and next_run_at it saw. Then the :job_changed cast.
\* The write and the clearing of a follow-up's Always allow the edit
\* made stale run in one BEGIN IMMEDIATE (update_scheduled_job_fields_row,
\* repo.ex:8162-8173; cue_watchers columns, not modelled), still one Repo
\* call. A follow-up's own edit (update_follow_up_job, registry.ex:246-255)
\* takes the same path and may also write its tools and timeout
\* (repo.ex:9162-9167), which no step here reads. The edit moves the job's
\* definition (defVer) wherever a step reads it: a heal's version, or the
\* row the stale skip's upsert wrote back before its fix.
UpdateWrite ==
    /\ oPc = "editing"
    /\ IF OwnerWritesColumns
       THEN UNCHANGED jobVars
       ELSE /\ jobEnabled' = oSnap.en
            /\ jobState' = oSnap.st
            /\ nextRun' = oSnap.next
    /\ OwnerLeavesRetry
    /\ changed' = TRUE
    /\ oPc' = "idle"
    /\ oSnap' = NoSnap
    /\ OwnerSince("edit")
    /\ defVer' = IF HealMoves > 0 \/ DueCanGoStale THEN defVer + 1 ELSE defVer
    /\ UNCHANGED <<OwnerQuiet, intent, movesLeft, editsLeft, manualLeft, HealQuiet>>

\* A heal run's move (M106 5.6, with HealMoves > 0). Jobs.HealRun reads the
\* job once, before its diagnosis (diagnose, heal_run.ex:254-263), and code
\* resolves the decision against that read (HealDecision.resolve): a pause
\* only for a job enabled and scheduled or running (decide(:pause),
\* heal_decision.ex:222-226), a raised limit any time (:228). The plan
\* carries the job's version as read (job_version, :135-141: the
\* definition and enabled, never what a run writes). Up to two minutes of
\* diagnosis then pass, in which anything else may happen. The step folds
\* in the Scheduler's claim just before the read (take_lease,
\* job_heals_sql.ex:1111-1125), which clears the owner-write mark: the run
\* reads the job after it, so an owner write before it is in what it reads.
HealRead ==
    /\ HealMoves > 0 /\ hPc = "idle"
    /\ hPc' = "read"
    /\ hSnap' = [en |-> jobEnabled, ver |-> defVer]
    /\ hMark' = FALSE
    /\ hKind' \in IF jobEnabled /\ jobState \in {"scheduled", "running"}
                  THEN {"pause", "raise"} ELSE {"raise"}
    /\ sinceRead' = {}
    /\ UNCHANGED <<OwnerQuiet, jobVars, retryAt, changed, oPc, oSnap, intent, movesLeft,
                   editsLeft, manualLeft, defVer, overwrote, undidResume>>

\* ... then the move: Registry.heal_write (registry.ex:188-196) prepares the
\* fields as an owner's pause or edit (heal_move_fields, :201-207) and
\* Repo.heal_job_write writes them in ONE BEGIN IMMEDIATE (heal_job_write_tx,
\* repo.ex:9030-9064): the heal still diagnosing under the run's lease
\* (JobHealsSql.claimant), the job read, and, with HealMoveGuarded, the job
\* written only while its version is the one the plan carries and, with
\* MarksOwnerWrites, no owner write has marked the heal since its claim
\* (heal_job_write_fenced, written_under?, :9047-9056); then the
\* decision's record under the lease, both or neither. The write is an owner
\* write's (write_scheduled_job_fields, :9009-9018): the columns, the
\* follow-up's stale approval and the job's retry (OwnerLeavesRetry), then
\* the :job_changed cast (after_heal_write). A job that moved gets nothing,
\* and the plan is recorded as tell. Without HealMoveGuarded, the S3 shape:
\* Registry.pause_job or update_job after a write that only proved the
\* lease, whatever the job had become. A raised limit writes a field the
\* version reads, so it moves defVer; enabled is the only modelled column a
\* move writes. The ghosts record what a landing write did after the
\* owner's writes since the read.
HealMoved == [en |-> jobEnabled, ver |-> defVer] /= hSnap

HealWrite ==
    /\ hPc = "read"
    /\ hPc' = "done"
    /\ IF HealMoveGuarded /\ (HealMoved \/ (MarksOwnerWrites /\ hMark))
       THEN UNCHANGED <<jobVars, retryAt, changed, defVer, overwrote, undidResume>>
       ELSE /\ jobEnabled' = IF hKind = "pause" THEN FALSE ELSE jobEnabled
            /\ jobState' = IF hKind = "pause" THEN "paused" ELSE jobState
            /\ UNCHANGED nextRun
            /\ defVer' = IF hKind = "raise" THEN defVer + 1 ELSE defVer
            /\ OwnerLeavesRetry
            /\ changed' = TRUE
            /\ overwrote' = (overwrote \/ (hKind = "raise" /\ defVer /= hSnap.ver))
            /\ undidResume' = (undidResume \/ (hKind = "pause" /\ "resume" \in sinceRead))
    /\ UNCHANGED <<OwnerQuiet, oPc, oSnap, intent, movesLeft, editsLeft, manualLeft, hSnap,
                   hKind, sinceRead, hMark>>

-----------------------------------------------------------------------------
(* The Scheduler: callbacks that start when it is idle *)

\* Every callback below starts from an idle Scheduler. An idle Scheduler has
\* reapReturn "idle", refused FALSE, sRun 0 and empty reconcile locals.
Quiet == <<jobVars, rowVars, runnerVars, helperVars, ownerVars, envVars>>

\* handle_info(:due_tick) (scheduler.ex:295-298): the timer armed at 0 ms or
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
                   activeSnap, reapQ, sSnap, cuePending, runsKnown, fQ, fClaimed, exits, sBy>>

\* handle_info(:reconcile_tick) (scheduler.ex:302-315), armed every 60 s:
\* reconcile, then the same due scan and re-arm as a due tick.
ReconcileFires ==
    /\ sPc = "idle"
    /\ sPc' = IF ReconcilesRuns THEN "r_rows" ELSE "scan"
    /\ reapReturn' = IF ReconcilesRuns THEN "scan" ELSE "idle"
    /\ admit' = (CuesOn /\ TicksAdmit)
    /\ UNCHANGED <<Quiet, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, runsKnown, fQ, fClaimed, exits, sBy>>

\* handle_cast(:job_changed) (scheduler.ex:286-288): re-arm the due timer and,
\* with cues on, request one admission pass (maybe_request_admission, :371-373).
JobChanged ==
    /\ sPc = "idle"
    /\ changed
    /\ sPc' = "arm"
    /\ changed' = FALSE
    /\ cuePending' = (cuePending \/ CuesOn)
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* handle_info(:cue_admit) (scheduler.ex:319-323): the one pass a burst of
\* requests coalesced into: the due scan and re-arm first, so a cron run takes
\* a freed slot before a cue run, then admission (admit).
CueAdmit ==
    /\ sPc = "idle"
    /\ cuePending
    /\ cuePending' = FALSE
    /\ sPc' = "scan"
    /\ admit' = TRUE
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, runsKnown, fQ, fClaimed, exits, sBy>>

\* handle_info({:DOWN, ...}) with an abnormal reason (scheduler.ex:357-365):
\* forget the monitor, then mark_run_crashed -> mark_run_failed (:1017-1019, :1025-1043),
\* then (M106 5.3) re-arm the due timer (schedule_due_timer, the lookup Arm
\* makes: the settle may have set the job a retry), start a heal run (not
\* modelled), and with cues on request one admission pass
\* (maybe_request_admission). Without RearmsOnDown, the code before M106: the
\* callback ends after the reap.
HandleDown(r) ==
    /\ sPc = "idle"
    /\ r \in downs
    /\ sPc' = "r_mark"
    /\ sRun' = r
    /\ reapReturn' = IF RearmsOnDown THEN "arm" ELSE "idle"
    /\ downs' = downs \ {r}
    /\ monitors' = monitors \ {r}
    /\ cuePending' = (cuePending \/ CuesOn)
    /\ UNCHANGED <<Quiet, changed, dueTimer, refused, activeSnap, reapQ, sSnap,
                   admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* handle_info({:DOWN, ...}) with a :normal reason (scheduler.ex:348-355): forget
\* the monitor, re-arm the due timer (the runner's settle may have set the job
\* a retry), start a heal run (not modelled), and with cues on request one
\* admission pass. Without RearmsOnDown the monitor and the request alone.
\* A heal run's own DOWN (:325-337, matched first) starts the next heal run
\* and touches nothing modelled; the heal run's one move on the job re-arms
\* the timer on its own (the :job_changed cast, :286-288, or run now's
\* handle_call, :280-283), sent to whichever Scheduler holds the name (see
\* ManualRun). A cast sent while a restarting Scheduler's name is not yet
\* registered is lost, but the write it announces came first, so the new
\* Scheduler's init reads it when it arms its timer.
HandleExit(r) ==
    /\ sPc = "idle"
    /\ r \in exits
    /\ exits' = exits \ {r}
    /\ sPc' = IF RearmsOnDown THEN "arm" ELSE "idle"
    /\ cuePending' = (cuePending \/ CuesOn)
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, admit, runsKnown, fQ, fClaimed, sBy>>

\* handle_call({:run_now, ...}) -> manual_run (scheduler.ex:280-283, :838-878).
\* Its Repo.get_scheduled_job lookup is folded into Repo.claim_job_now: the
\* claim transaction re-checks enabled, "scheduled" and (the race-stop) no
\* queued/running run (repo.ex:6880-6884, :6914-6932, :6959-6998), so the
\* fold only drops harmless outcomes (an error reply either way). A manual
\* claim leaves a recurring job's next_run_at alone (manual_claim_patch,
\* scheduler.ex:866, :953-960), and deletes the job's retry in its transaction
\* (claim_job_now_tx, repo.ex:8303-8312; OwnerLeavesRetry). With every modelled run id in use, the
\* request is out of the model's bounds and is refused. A Repo call that
\* times out is ManualRunTimeout. A cue task never gets here: run_job_now
\* refuses it before calling the Scheduler (Registry.check_run_now,
\* run_job_now.ex:71, registry.ex:110-114), and a job's kind never changes.
\* A follow-up does: check_run_now refuses only the cue kind, since a run of
\* a follow-up is not the run of one item (registry.ex:104-115).
\* A heal run's rerun (M106 5.5, heal_run.ex:597-635) takes the same path,
\* check_run_now then Scheduler.run_now, once its message is out. Its call
\* waits behind whatever callback runs and is served here: the Scheduler
\* never waits on a heal run (its init/1 does no work, and its heal id is
\* read from its process dictionary), so the call cannot deadlock, and one
\* that times out (5 s, as the owner's) is still served later. It names the
\* Scheduler by its registered name (state.name, scheduler.ex:196, :1304;
\* JOB-10's fix), so a heal run that outlived a Scheduler-only restart
\* reaches the Scheduler running then; only while that name is unregistered
\* does the call exit :noproc and start nothing, a request never made. What
\* came of the call (started, running, refused, unanswered) is written on
\* job_heals only.
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
            /\ OwnerLeavesRetry
            /\ jobState' = "running"
            /\ UNCHANGED <<jobEnabled, nextRun>>
       ELSE /\ sPc' = "arm"
            /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, sRun>>
    /\ UNCHANGED <<envVars, oPc, oSnap, intent, movesLeft, editsLeft, healVars, reapReturn,
                   monitors, downs, changed, dueTimer, refused, activeSnap, reapQ, sSnap,
                   waiting, starting, cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

-----------------------------------------------------------------------------
(* The Scheduler: steps inside a callback, one Repo call each *)

\* Take the next orphan to reap, or go to reapReturn: init goes on to the
\* re-arm (scheduler.ex:266-268), the 60 s tick to the due scan (:307-309),
\* a DOWN callback to the re-arm (:361-363; without RearmsOnDown it ends).
NextReap(q) ==
    IF q /= {}
    THEN /\ sRun' = Min(q) /\ reapQ' = q \ {Min(q)} /\ sPc' = "r_mark"
         /\ UNCHANGED reapReturn
    ELSE /\ sRun' = 0 /\ reapQ' = {} /\ sPc' = reapReturn
         /\ reapReturn' = "idle"

\* After one run is reaped. A DOWN callback has no queue, so it ends.
AfterReap == NextReap(reapQ)

\* reconcile_active_runs: Repo.unsettled_job_runs (scheduler.ex:560), the
\* queued/running rows and the rows whose delivery is pending (Scanned). The
\* scan succeeded, so the run set is known again (runs_known?, :563). A scan
\* that times out is ReconcileRowsTimeout.
ReconcileRows ==
    /\ sPc = "r_rows"
    /\ activeSnap' = Scanned
    /\ sPc' = "r_live"
    /\ runsKnown' = TRUE
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   reapQ, sSnap, cuePending, admit, fQ, fClaimed, exits, sBy>>

\* live_runner_pids: DynamicSupervisor.which_children + the run id each
\* runner published in its init (scheduler.ex:562, :612-626; runner.ex:194).
\* Live runs are adopted: monitored if not already (adopt_live_run, scheduler.ex:587-595;
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
                   runsKnown, fQ, fClaimed, exits, sBy>>

\* The reaper's write for run r, as it lands (mark_run_error, scheduler.ex
\* :1073-1139). A queued/running run is settled "error": with AtomicSettle
\* through Repo.settle_job_run, which releases the job in the same write
\* (:1112-1133); without, an upsert of the run row alone. A run whose delivery
\* is still pending, whatever its status, gets delivery "failed" (:1135-1137,
\* :1171-1184). Any other row is left alone.
\* A cue task's queued/running run settles through CueAdmission.settle/3 ->
\* Repo.settle_cue_run (mark_run_error's cue clause, scheduler.ex:1086-1104): the
\* same row and release in one transaction, plus its delivery, put back or
\* ended (Retries). An exhausted one gets its final failure report from a task
\* the reaper starts after the write (report_cue_failure, :1049-1069) when
\* `reports`: not when the Scheduler died waiting on the write. The task
\* first marks the delivery pending (ReportMark), or, without
\* ReportMarksPending, sends at once. A follow-up's run (trigger "watcher")
\* takes the cron clause: the cue clause matches trigger "cue" alone.
\* The cron clause's settle (:scheduler, scheduler.ex:1106-1133) decides the
\* job's retry in its transaction (ReapRetries: from the row, so an unstamped
\* tool start counts as none) and gives a failure no retry takes to a heal,
\* told by its kind's sentence (Failure.sentence/1): nothing is sent either
\* way, as before.
ReapWrite(r, reports) ==
    /\ IF runStatus[r] \in {"queued", "running"}
       THEN /\ runStatus' = [runStatus EXCEPT ![r] = "error"]
            /\ UNCHANGED <<delivery, starting>>
            /\ IF AtomicSettle THEN Release ELSE UNCHANGED jobState
            /\ \E retry \in IF CueTask THEN BOOLEAN ELSE {FALSE}, jobRetry \in ReapRetries(r) :
                  /\ waiting' = IF retry THEN waiting + 1 ELSE waiting
                  /\ report' = IF CueTask /\ ~retry /\ reports
                               THEN [report EXCEPT ![r] =
                                       IF ReportMarksPending THEN "marking" ELSE "sending"]
                               ELSE report
                  /\ SettledRetry(jobRetry, r)
            /\ tool' = [tool EXCEPT ![r] = "none"]
       ELSE IF CrashFailsPendingDelivery /\ delivery[r] = "pending"
       THEN /\ delivery' = [delivery EXCEPT ![r] = "failed"]
            /\ UNCHANGED <<runStatus, jobState, waiting, starting, report, retryAt, tool>>
       ELSE UNCHANGED <<rowVars, jobState, report>>
    /\ UNCHANGED <<jobEnabled, nextRun>>

\* Whether that write leaves a job write to follow: only the split reaper
\* (AtomicSettle off) writes the job row after it, and only when it wrote.
SplitReapFollows(r) ==
    /\ ~AtomicSettle
    /\ \/ runStatus[r] \in {"queued", "running"}
       \/ CrashFailsPendingDelivery /\ delivery[r] = "pending"

\* mark_run_failed -> mark_run_error (scheduler.ex:1025-1043, :1073-1139):
\* Repo.get_job_run, then the write above. The two calls are one step: once
\* its runner is dead
\* only the Scheduler writes this row, and a runner's timed-out write landed
\* before the get, which was queued after it. For the same reason the
\* settle's :run_not_active branch (:1125-1128) is unreachable here. One other
\* writer remains: a cue run's report task, whose pending row a reconcile
\* pass reaps like any orphan's (the task is no runner). Its result write
\* can land between the get and the write, which then records "failed" over
\* it; the fold drops that order. The row is final either way, and only
\* FailedMeansNotDelivered (JOB-6, checked with cues off) tells "failed" over
\* a sent report from "sent". A write that times out is this step too: it
\* lands late, before the Scheduler's next Repo call, and its error branch
\* only logs and skips the memory-source mirror (:1101-1102, :1130-1131), which
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
                   cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* Without AtomicSettle, the job write of the code before the fix
\* (mark_job_error / mark_job_completed_after_delivery_crash), first half:
\* Repo.get_scheduled_job.
ReapReadJob ==
    /\ sPc = "r_read"
    /\ sSnap' = SchedRow
    /\ sPc' = "r_write"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* ... second half: Repo.upsert_scheduled_job of the row it read, "running"
\* -> "scheduled" (the memory-source update after it is folded in).
ReapWriteJob ==
    /\ sPc = "r_write"
    /\ WriteBack(sSnap)
    /\ sSnap' = NoSchedSnap
    /\ AfterReap
    /\ UNCHANGED <<rowVars, runnerVars, helperVars, ownerVars, envVars,
                   monitors, downs, changed, dueTimer, refused, activeSnap, cuePending, admit,
                   runsKnown, fQ, fClaimed, exits, sBy>>

\* run_due_jobs: Repo.due_scheduled_jobs (scheduler.ex:638-649): enabled,
\* state "scheduled", and due by next_run_at <= now or (M106 5.3) by a retry
\* whose time has passed (fetch_due_scheduled_jobs, repo.ex:8238-8262).
\* claim_and_start (scheduler.ex:667-678) claims it by its next run when that
\* is due, the due run also being the retry, and by its retry otherwise; the
\* row it read decides which (sBy). With DueCanGoStale the due time it read
\* may be older than the freshness window (stale?, scheduler.ex:723-736),
\* which claim_and_start checks before any claim: the run is skipped this
\* tick (skip_stale_job, :738-750), and the row as read goes to the stale
\* skip's write (sSnap). A scan that times out is ScanTimeout.
Scan ==
    /\ sPc = "scan"
    /\ IF jobEnabled /\ jobState = "scheduled" /\ (Due \/ RetryPending)
       THEN \/ /\ sPc' = "claim"
               /\ sBy' = IF Due THEN "due" ELSE "retry"
               /\ UNCHANGED sSnap
            \/ /\ DueCanGoStale /\ Due
               /\ sPc' = "skip"
               /\ sSnap' = SchedRow
               /\ UNCHANGED sBy
       ELSE /\ sPc' = "arm"
            /\ UNCHANGED <<sBy, sSnap>>
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, cuePending, admit, runsKnown, fQ, fClaimed, exits>>

\* claim_and_start_due_job -> claim_patched_job -> Repo.claim_due_job
\* (scheduler.ex:784-807): one BEGIN IMMEDIATE transaction (repo.ex:6872-6876,
\* :6914-6957) that re-checks the job is due, refuses while a run is
\* queued/running (the race-stop), then sets state "running" with
\* next_run_at advanced (claim_job_patch, scheduler.ex:943-951) and inserts
\* the run "queued". :already_running returns {:busy, state} (start_claimed,
\* :827-830), :not_due {:ok, state} (:831). With every modelled run
\* id in use the claim is out of the model's bounds and behaves like :not_due.
\* A claim that times out is ClaimTimeout.
\* The claim by a retry (M106 5.3) is Repo.claim_retry_job
\* (claim_and_start_retry, scheduler.ex:809-818; claim_retry_job_tx,
\* repo.ex:8314-8323): the same transaction with the retry for its gate (the
\* job read while enabled, "scheduled" and holding a retry due by now,
\* fetch_claimable_retry_job, :8334-8356), the same race-stop
\* (claim_in_tx), and a patch with no next_run_at, so next_run_at stays as it
\* is. The due claim clears the retry's time with its count kept
\* (claim_due_job_tx, :8293-8301), the retry claim the same: either way no
\* pending retry is left. Its refusals are the due claim's (start_claimed,
\* scheduler.ex:824-836): :already_running is the backoff, :not_due a clean
\* drain.
Claim ==
    /\ sPc = "claim"
    /\ LET gate == IF sBy = "due" THEN Due ELSE RetryPending IN
       IF ~(jobEnabled /\ jobState = "scheduled" /\ gate) \/ FreeIds = {}
       THEN /\ sPc' = "arm"
            /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, sRun, refused>>
       ELSE IF AtomicRaceStop /\ Active /= {}
       THEN /\ refused' = TRUE /\ sPc' = "arm"
            /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, sRun>>
       ELSE LET r == Min(FreeIds) IN
            /\ NewRun(r)
            /\ retryAt' = "none"
            /\ jobState' = "running"
            /\ nextRun' = IF sBy = "due" THEN now + 1 ELSE nextRun
            /\ sRun' = r
            /\ sPc' = "start"
            /\ UNCHANGED <<jobEnabled, refused, waiting, starting>>
    /\ sBy' = "-"
    /\ UNCHANGED <<ownerVars, envVars, reapReturn, monitors, downs, changed, dueTimer,
                   activeSnap, reapQ, sSnap, cuePending, admit, runsKnown,
                   fQ, fClaimed, exits>>

\* start_or_mark_failed (scheduler.ex:927-937): RunnerSupervisor.start_run
\* runs Runner.init synchronously (runner_supervisor.ex:20-23), which
\* publishes the run id (runner.ex:194); then Process.monitor. No Repo call.
Start ==
    /\ sPc = "start"
    /\ pc' = [pc EXCEPT ![sRun] = "start"]
    /\ monitors' = monitors \cup {sRun}
    /\ sRun' = 0
    /\ sPc' = "arm"
    /\ UNCHANGED <<jobVars, rowVars, resp, finSnap, outcome, helperVars, ownerVars,
                   envVars, reapReturn, downs, changed, dueTimer, refused, activeSnap,
                   reapQ, sSnap, cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* The stale skip (DueCanGoStale). skip_stale_job computes the next future
\* occurrence from the row the scan read (advance_schedule, scheduler.ex
\* :752-758, no Repo call; one that fails is the disable, not modelled), and
\* advance_stale_job (:760-782) makes ONE Repo call,
\* Repo.advance_stale_scheduled_job/4 (repo.ex:2786-2794): an UPDATE of
\* next_run_at (and updated_at) with no read before it, guarded on the job
\* still enabled, "scheduled" and due at the instant the scan read
\* (advance_stale_scheduled_job_row, guarded_scheduled_job_write,
\* repo.ex:9330-9341, :9377-9383). A pause or resume that landed since the
\* scan moved what the guard reads, so the write changes no row ({:ok,
\* :unchanged}); an edit is in columns it does not set. Either outcome is
\* {:ok, state}, so the tick re-arms as after a clean drain (Arm). It is no
\* owner write: it marks no heal and clears no retry (repo.ex:9323-9329). A
\* write that times out is StaleSkipTimeout.
StaleAdvance ==
    IF jobEnabled /\ jobState = "scheduled" /\ nextRun = sSnap.next
    THEN /\ nextRun' = now + 1
         /\ UNCHANGED <<jobEnabled, jobState>>
    ELSE UNCHANGED jobVars

StaleSkip ==
    /\ sPc = "skip" /\ StaleSkipGuarded
    /\ StaleAdvance
    /\ sSnap' = NoSchedSnap
    /\ sPc' = "arm"
    /\ UNCHANGED <<rowVars, runnerVars, helperVars, ownerVars, envVars, reapReturn, monitors,
                   downs, changed, dueTimer, refused, sRun, activeSnap, reapQ, cuePending,
                   admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* Without StaleSkipGuarded, advance_stale_job before the fix, first half:
\* Repo.get_scheduled_job, and on to the upsert only for a job still enabled
\* and "scheduled" (any other row, or none, was {:ok, state} with no write).
StaleRead ==
    /\ sPc = "skip" /\ ~StaleSkipGuarded
    /\ IF jobEnabled /\ jobState = "scheduled"
       THEN /\ sPc' = "s_write" /\ sSnap' = SchedRow
       ELSE /\ sPc' = "arm" /\ sSnap' = NoSchedSnap
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* ... second half (store_advanced_run_at): Repo.upsert_scheduled_job of the
\* row it read with next_run_at advanced. The upsert is one INSERT ... ON
\* CONFLICT DO UPDATE of every column (upsert_scheduled_job_row), so it puts
\* back the enabled, state and definition it read over whatever landed
\* since: an owner's pause, resume or edit, or a heal's move.
StaleRowWrite ==
    /\ jobEnabled' = sSnap.en
    /\ jobState' = sSnap.st
    /\ nextRun' = now + 1
    /\ defVer' = sSnap.ver

StaleWrite ==
    /\ sPc = "s_write"
    /\ StaleRowWrite
    /\ sSnap' = NoSchedSnap
    /\ sPc' = "arm"
    /\ UNCHANGED <<rowVars, runnerVars, helperVars, envVars, oPc, oSnap, intent, movesLeft,
                   editsLeft, manualLeft, HealQuiet, sinceRead, hMark, reapReturn, monitors,
                   downs, changed, dueTimer, refused, sRun, activeSnap, reapQ, cuePending,
                   admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* admit_cue_runs (scheduler.ex:382-391) first offers the follow-ups' new
\* cards (offer_follow_ups, :402-409: a Repo call that claims waiting cards
\* and hands each to a task, which no step here reads), then admits follow-up
\* runs (admit_follow_up_runs, :411-426), then cue runs (admit_cue_task_runs,
\* :393-400). For a job with no follow-up the follow-up scan finds none of
\* its triggers and a timeout of it changes nothing modelled, so a callback
\* that admits goes straight to the cue runs' candidate scan.
AdmitFrom == IF FollowUp THEN "f_scan" ELSE "c_scan"

\* schedule_due_timer -> next_due_timer: Repo.next_scheduled_job (scheduler.ex
\* :1360-1388, repo.ex:6843-6870). A tick whose claim was refused re-arms no
\* sooner than the 5 s backoff (outcome :busy, due_delay_ms, scheduler.ex:1420-1433) with
\* RefusalBacksOff; without it the refusal counted as a clean drain. After a
\* clean tick an enabled "scheduled" job is armed at its next_run_at, which is
\* 0 ms when it is already due; no such job arms nothing. A lookup that times
\* out is ArmTimeout. A job a watcher runs is never armed: the lookup never
\* returns it. A callback that admits goes on to admission (admit_cue_runs,
\* after run_due_and_rearm, scheduler.ex:276-323, :382-391): AdmitFrom. The
\* lookup also returns a job with a pending retry, armed for the earliest of
\* its next run, expiry and retry (fetch_next_scheduled_job, repo.ex
\* :8264-8285; next_wakeup_at, scheduler.ex:1401-1407): a retry is due at
\* once here, so 0 ms.
Arm ==
    /\ sPc = "arm"
    /\ dueTimer' = IF refused /\ RefusalBacksOff THEN "backoff"
                   ELSE IF ~WatcherJob /\ jobEnabled /\ jobState = "scheduled"
                        THEN IF Due \/ RetryPending THEN "zero" ELSE "later"
                        ELSE "none"
    /\ sPc' = IF admit THEN AdmitFrom ELSE "idle"
    /\ reapReturn' = "idle"
    /\ refused' = FALSE
    /\ UNCHANGED <<Quiet, monitors, downs, changed, sRun, activeSnap, reapQ, sSnap,
                   cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* admit_follow_up_runs: the free cue slots (free_cue_slots, :434-440), then
\* CueAdmission.claim_follow_ups (cue_admission.ex:197-214): one Repo call
\* for the oldest starting triggers, at most ten ({:starting_triggers, 10},
\* cues_follow_up_sql.ex:261-263). While the last reconcile scan failed the
\* slots are 0 and claim_follow_ups(0, ...) makes no call (:189-191).
\* Otherwise the slots are never 0 for one job (CueCandidates), and they
\* never bind either: a claim needs a free run id, so at most one runner is
\* alive and at most one cue-share run is monitored, which leaves at least
\* two slots, and the one job takes at most one run per pass. A scan that
\* times out is FollowUpScanTimeout.
FollowUpScan ==
    /\ sPc = "f_scan"
    /\ IF runsKnown /\ starting > 0
       THEN /\ fQ' = starting /\ sPc' = "f_claim"
       ELSE /\ UNCHANGED fQ /\ sPc' = "c_scan"
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, admit, runsKnown, fClaimed, exits, sBy>>

\* Whether the claim can take the follow-up's run: fetch_claimable_job (the
\* job enabled and "scheduled", repo.ex:7832-7851) and claim_in_tx's
\* ensure_no_active_job_run (:7634-7641, :7689), the race-stop every claim
\* shares.
FollowUpClaimable == jobEnabled /\ jobState = "scheduled" /\ (Active = {} \/ ~AtomicRaceStop)

\* The claim of one trigger, as it lands: Repo.claim_follow_up_run
\* (repo.ex:2642-2645, :7739-7785), one BEGIN IMMEDIATE that reads the
\* trigger while it is starting (CuesFollowUpSql.claimable,
\* cues_follow_up_sql.ex:526-532), takes the job through the claim every run
\* takes with state "running" alone (claim_follow_up_job: claim_in_tx over
\* fetch_claimable_job), inserts the run with trigger "watcher" and moves the
\* trigger to started (mark_started, :488-494). A job that cannot take the
\* run (:not_runnable, :already_running: paused, gone, or still running)
\* refuses the trigger in the same transaction with Fermix's sentence
\* (refuse_follow_up, follow_up_refusal; refuse_starting, :501-502), so a
\* trigger never waits behind a run. With every modelled run id in use the
\* claim is out of the model's bounds and leaves the trigger starting.
\* `start`: the Scheduler starts the claimed run once every trigger the scan
\* read is done (not after a claim whose call timed out).
FollowUpClaimRows(start) ==
    IF FollowUpClaimable /\ FreeIds /= {}
    THEN LET r == Min(FreeIds) IN
         /\ NewRun(r)
         /\ jobState' = "running"
         /\ starting' = starting - 1
         /\ fClaimed' = IF start THEN fClaimed \cup {r} ELSE fClaimed
         /\ UNCHANGED <<jobEnabled, nextRun, waiting, retryAt>>
    ELSE /\ starting' = IF FollowUpClaimable THEN starting ELSE starting - 1
         /\ UNCHANGED <<jobVars, runStatus, delivery, waiting, retryAt, tool, runnerVars,
                        helperVars, fClaimed>>

\* Where the follow-up pass goes after one trigger: the next one the scan
\* read, the runs it claimed, or the cue runs' candidate scan.
FollowUpNext ==
    sPc' = IF fQ > 1 THEN "f_claim" ELSE IF fClaimed' /= {} THEN "f_start" ELSE "c_scan"

\* One trigger the scan read (admit_trigger, cue_admission.ex:226-245): its
\* job read (JobsRegistry.get_job) and the hold check (held_check,
\* :247-259) are folded in, since the claim re-reads the job in its own
\* transaction and the hold is not modelled (see the header), then the
\* claim (claim_trigger, :261-282). A refused trigger spends no slot and
\* goes to FollowUps.refused/3 in a task (refused, :285-288), which writes
\* nothing modelled; the pass goes on (admit_until_full, :219-223). A claim
\* that times out, or a read before it, is FollowUpClaimTimeout.
FollowUpClaim ==
    /\ sPc = "f_claim"
    /\ FollowUpClaimRows(TRUE)
    /\ fQ' = fQ - 1
    /\ FollowUpNext
    /\ UNCHANGED <<ownerVars, envVars, reapReturn, monitors, downs, changed, dueTimer,
                   refused, sRun, activeSnap, reapQ, sSnap, cuePending, admit, runsKnown, exits, sBy>>

\* start_follow_up_run -> start_or_mark_failed (scheduler.ex:483-484,
\* :927-937), as Start, for each run the pass claimed, after every trigger
\* the scan read. Then the cue runs' admission.
FollowUpStart ==
    /\ sPc = "f_start"
    /\ LET r == Min(fClaimed) IN
       /\ pc' = [pc EXCEPT ![r] = "start"]
       /\ monitors' = monitors \cup {r}
       /\ fClaimed' = fClaimed \ {r}
       /\ sPc' = IF fClaimed \ {r} = {} THEN "c_scan" ELSE "f_start"
    /\ UNCHANGED <<jobVars, rowVars, resp, finSnap, outcome, helperVars, ownerVars,
                   envVars, reapReturn, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, admit, runsKnown, fQ, exits, sBy>>

\* admit_cue_task_runs (scheduler.ex:393-400): the free cue slots, counted
\* again from the monitors that now hold the follow-up runs it started
\* (free_cue_slots, :434-440; CueAdmission.free_slots, cue_admission.ex:82-89), then
\* CueAdmission.claim: one Repo call for the candidates
\* ({:admission_candidates, ...}, cues_runs_sql.ex:221-233). While the last
\* reconcile scan failed the slots are 0 (no cue run starts until a scan
\* succeeds), and claim(0, ...) makes no call (cue_admission.ex:105-107).
\* Otherwise one job never holds more than two runners, so the slots
\* (min(4 - active, 3 - active cue runs)) are never 0 and that call is made;
\* for a cron job it finds nothing. A call that times out is
\* CueCandidatesTimeout.
CueCandidates ==
    /\ sPc = "c_scan"
    /\ sPc' = IF runsKnown /\ CueEligible THEN "c_claim" ELSE "idle"
    /\ admit' = FALSE
    /\ UNCHANGED <<Quiet, reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, runsKnown, fQ, fClaimed, exits, sBy>>

\* Repo.claim_cue_run (cue_admission.ex:298-317; repo.ex:2483-2486,
\* :6727-6748): one BEGIN IMMEDIATE that re-reads the task's oldest eligible
\* delivery (CuesRunsSql.eligible_delivery, the same rule), takes the job with
\* state "running" alone, leaving next_run_at as it is (claim_in_tx, whose
\* ensure_no_active_job_run repeats the rule's no-active-run part inside the
\* same transaction, repo.ex:6925-6932), inserts the run with trigger "cue" and
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
            /\ UNCHANGED <<starting, retryAt>>
            /\ jobState' = "running"
            /\ sRun' = r
            /\ sPc' = "c_start"
       ELSE /\ sPc' = "idle"
            /\ UNCHANGED <<jobState, rowVars, runnerVars, helperVars, sRun>>
    /\ UNCHANGED <<jobEnabled, nextRun, ownerVars, envVars, reapReturn, monitors, downs,
                   changed, dueTimer, refused, activeSnap, reapQ, sSnap, cuePending, admit,
                   runsKnown, fQ, fClaimed, exits, sBy>>

\* start_cue_run -> start_or_mark_failed (scheduler.ex:546, :927-937), as
\* Start. The pass ends here: admission runs after the re-arm.
CueStart ==
    /\ sPc = "c_start"
    /\ pc' = [pc EXCEPT ![sRun] = "start"]
    /\ monitors' = monitors \cup {sRun}
    /\ sRun' = 0
    /\ sPc' = "idle"
    /\ UNCHANGED <<jobVars, rowVars, resp, finSnap, outcome, helperVars, ownerVars,
                   envVars, reapReturn, downs, changed, dueTimer, refused, activeSnap,
                   reapQ, sSnap, cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

SchedStep ==
    \/ ReconcileRows \/ ReconcileLive \/ ReapRun \/ ReapReadJob \/ ReapWriteJob
    \/ Scan \/ Claim \/ Start \/ Arm \/ FollowUpScan \/ FollowUpClaim \/ FollowUpStart
    \/ CueCandidates \/ CueClaim \/ CueStart \/ StaleSkip \/ StaleRead \/ StaleWrite

-----------------------------------------------------------------------------
(* The Scheduler: a Repo call that times out *)

\* Every Repo call the Scheduler's process makes passes Repo.periodic_opts
\* (scheduler.ex:200-203; repo.ex:1252-1254): a call the Repo does not answer
\* within 5 s returns {:error, :repo_timeout} (repo.ex:4455-4463) and the
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
\* :565-572). The pass reaps and adopts nothing, and the callback goes on:
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
                   sSnap, cuePending, admit, fQ, fClaimed, exits, sBy>>

\* mark_run_failed: Repo.get_job_run times out (scheduler.ex:1036-1039), so the
\* run is not marked and its row keeps its status. After a DOWN the monitor
\* is already gone: a queued/running row holds the job, with no runner and
\* no monitor, until the next reconcile pass reaps it with the generic
\* "reaped: no live runner" text (:81-85, :601-604). In a reconcile pass
\* the orphan waits for the next pass.
ReapLookupTimeout ==
    /\ sPc = "r_mark"
    /\ TimeOut
    /\ AfterReap
    /\ UNCHANGED <<TimeoutQuiet, monitors, downs, changed, dueTimer, refused, activeSnap,
                   sSnap, cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* run_due_jobs: Repo.due_scheduled_jobs times out (scheduler.ex:645-647).
\* The tick's outcome is :error, so the re-arm floors at the 5 s backoff
\* (:1360-1397, :1420-1433). That re-arm is folded in: whatever its own lookup
\* returns, or if it times out too (:1382-1386), the model arms "backoff",
\* which fires whether or not the job is due. Nothing is written. A callback
\* that admits still goes on to admission after any of the three timeouts.
ScanTimeout ==
    /\ sPc = "scan"
    /\ TimeOut
    /\ sPc' = IF admit THEN AdmitFrom ELSE "idle"
    /\ dueTimer' = "backoff"
    /\ UNCHANGED <<TimeoutQuiet, reapReturn, monitors, downs, changed, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* claim_patched_job: Repo.claim_due_job times out (start_claimed's error
\* branch, scheduler.ex:833-836).
\* A claim the Repo had started still runs, as Claim would run it (one it
\* reaches past the deadline is turned away unrun, skip_when_late, and
\* writes nothing: what ScanTimeout leaves), but the Scheduler starts no
\* runner and monitors nothing: a claim
\* that lands leaves a queued run with no runner, which holds its job until
\* the next reconcile pass reaps it ("... or a memory store that answered too
\* late", scheduler.ex:81-85). The tick's outcome is :error: the re-arm is
\* folded in as in ScanTimeout.
ClaimTimeout ==
    /\ sPc = "claim"
    /\ TimeOut
    /\ IF /\ jobEnabled /\ jobState = "scheduled" /\ FreeIds /= {}
          /\ IF sBy = "due" THEN Due ELSE RetryPending
          /\ (Active = {} \/ ~AtomicRaceStop)
       THEN LET r == Min(FreeIds) IN
            /\ NewRun(r)
            /\ retryAt' = "none"
            /\ jobState' = "running"
            /\ nextRun' = IF sBy = "due" THEN now + 1 ELSE nextRun
            /\ UNCHANGED jobEnabled
       ELSE UNCHANGED <<jobVars, rowVars, runnerVars, helperVars>>
    /\ sPc' = IF admit THEN AdmitFrom ELSE "idle"
    /\ dueTimer' = "backoff"
    /\ sBy' = "-"
    /\ UNCHANGED <<ownerVars, now, strayLoops, daemonCrashed, schedCrashes, reapReturn,
                   monitors, downs, changed, refused, sRun, activeSnap, reapQ, sSnap,
                   waiting, starting, cueSupply, cuePending, admit, runsKnown, fQ, fClaimed, exits>>

\* next_due_timer: Repo.next_scheduled_job times out (scheduler.ex:1382-1386):
\* the timer is armed at the backoff whatever the row says.
ArmTimeout ==
    /\ sPc = "arm"
    /\ TimeOut
    /\ dueTimer' = "backoff"
    /\ sPc' = IF admit THEN AdmitFrom ELSE "idle"
    /\ reapReturn' = "idle"
    /\ refused' = FALSE
    /\ UNCHANGED <<TimeoutQuiet, monitors, downs, changed, sRun, activeSnap, reapQ, sSnap,
                   cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* advance_stale_job: Repo.advance_stale_scheduled_job times out
\* (scheduler.ex:778-780): it lands late, as StaleSkip would run it, and the
\* tick's outcome is :error, so the re-arm is folded in as in ScanTimeout.
\* Without StaleSkipGuarded, the code before the fix: a get that timed out
\* wrote nothing, and an upsert that timed out lands late as StaleWrite
\* would; the outcome was :error either way.
StaleSkipTimeout ==
    /\ sPc \in {"skip", "s_write"}
    /\ TimeOut
    /\ IF sPc = "s_write" THEN StaleRowWrite
       ELSE IF StaleSkipGuarded THEN StaleAdvance /\ UNCHANGED defVer
       ELSE UNCHANGED <<jobVars, defVer>>
    /\ sSnap' = NoSchedSnap
    /\ sPc' = IF admit THEN AdmitFrom ELSE "idle"
    /\ dueTimer' = "backoff"
    /\ UNCHANGED <<rowVars, runnerVars, helperVars, now, strayLoops, daemonCrashed, schedCrashes,
                   cueSupply, oPc, oSnap, intent, movesLeft, editsLeft, manualLeft, HealQuiet,
                   sinceRead, hMark, reapReturn, monitors, downs, changed, refused, sRun,
                   activeSnap, reapQ, cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* handle_call({:run_now, ...}) whose lookup (scheduler.ex:843-845) or
\* Repo.claim_job_now (:871-877) times out. A claim the Repo had started
\* still lands when ManualRun's would, with no runner started; one it turned
\* away unrun past the deadline (skip_when_late) is the first branch. Either way the
\* owner is told {:error, :repo_timeout} and the due timer is re-armed, as
\* after any "run now" (:282).
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
             /\ OwnerLeavesRetry
             /\ jobState' = "running"
             /\ UNCHANGED <<jobEnabled, nextRun>>
    /\ sPc' = "arm"
    /\ UNCHANGED <<now, strayLoops, daemonCrashed, schedCrashes, oPc, oSnap, intent,
                   movesLeft, editsLeft, healVars, reapReturn, monitors, downs, changed, dueTimer,
                   refused, sRun, activeSnap, reapQ, sSnap, waiting, starting, cueSupply,
                   cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* CueAdmission.claim: the candidate scan times out (cue_admission.ex:120-123):
\* logged, nothing claimed, the pass ends. Only a pass with free slots makes
\* the call.
CueCandidatesTimeout ==
    /\ sPc = "c_scan" /\ runsKnown
    /\ TimeOut
    /\ sPc' = "idle"
    /\ admit' = FALSE
    /\ UNCHANGED <<TimeoutQuiet, reapReturn, monitors, downs, changed, dueTimer, refused,
                   sRun, activeSnap, reapQ, sSnap, cuePending, runsKnown, fQ, fClaimed, exits, sBy>>

\* Repo.claim_cue_run times out (claim_candidate's error branch,
\* cue_admission.ex:312-315): traced, logged and skipped, but a claim the Repo had
\* started still lands, as CueClaim would run it (one turned away unrun past
\* the deadline, skip_when_late, writes nothing and the delivery waits for a
\* later pass), with no runner started:
\* a queued cue run that holds its job until the next reconcile pass reaps it.
CueClaimTimeout ==
    /\ sPc = "c_claim"
    /\ TimeOut
    /\ IF CueEligible /\ FreeIds /= {}
       THEN LET r == Min(FreeIds) IN
            /\ NewRun(r)
            /\ waiting' = waiting - 1
            /\ jobState' = "running"
            /\ UNCHANGED <<jobEnabled, nextRun, starting, retryAt>>
       ELSE UNCHANGED <<jobVars, rowVars, runnerVars, helperVars>>
    /\ sPc' = "idle"
    /\ UNCHANGED <<ownerVars, now, strayLoops, daemonCrashed, schedCrashes, cueSupply,
                   reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* CueAdmission.claim_follow_ups: the scan of starting triggers times out
\* (cue_admission.ex:209-212): traced, logged, nothing admitted, and the
\* pass goes on to the cue runs. Only a pass with free slots makes the call.
FollowUpScanTimeout ==
    /\ sPc = "f_scan" /\ runsKnown
    /\ TimeOut
    /\ sPc' = "c_scan"
    /\ UNCHANGED <<TimeoutQuiet, reapReturn, monitors, downs, changed, dueTimer, refused,
                   sRun, activeSnap, reapQ, sSnap, cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* One trigger's Repo call times out. Its job read or a read of the hold check
\* (admit_trigger's and held_check's error branches, cue_admission.ex:234,
\* :240-243): traced, logged, and the trigger stays starting for a later
\* pass. Or the claim itself (claim_trigger's error branch, :277-280): traced
\* and logged, but one the Repo had started still lands, as FollowUpClaim
\* would run it (one turned away unrun past the deadline, skip_when_late, is
\* the first branch), with no runner to start: a queued run that
\* holds its job until the next reconcile pass reaps it, or a refused
\* trigger. Either way the pass goes on to the next trigger.
FollowUpClaimTimeout ==
    /\ sPc = "f_claim"
    /\ TimeOut
    /\ \/ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, fClaimed>>
       \/ FollowUpClaimRows(FALSE)
    /\ fQ' = fQ - 1
    /\ FollowUpNext
    /\ UNCHANGED <<ownerVars, now, strayLoops, daemonCrashed, schedCrashes, cueSupply,
                   reapReturn, monitors, downs, changed, dueTimer, refused, sRun,
                   activeSnap, reapQ, sSnap, cuePending, admit, runsKnown, exits, sBy>>

SchedTimeout ==
    \/ ReconcileRowsTimeout \/ ReapLookupTimeout \/ ScanTimeout \/ ClaimTimeout
    \/ ArmTimeout \/ ManualRunTimeout \/ CueCandidatesTimeout \/ CueClaimTimeout
    \/ FollowUpScanTimeout \/ FollowUpClaimTimeout \/ StaleSkipTimeout

-----------------------------------------------------------------------------
(* One Runner (runner.ex), a :temporary child of Jobs.RunnerSupervisor *)

Move(r, s) == pc' = [pc EXCEPT ![r] = s]
RunnerQuiet == <<jobVars, ownerVars, envVars, schedVars>>

\* handle_continue(:run) -> mark_running (runner.ex:200-208, :296-313):
\* Repo.upsert_job_run with status "running".
MarkRunning(r) ==
    /\ pc[r] = "start"
    /\ Move(r, "loop")
    /\ runStatus' = [runStatus EXCEPT ![r] = "running"]
    /\ UNCHANGED <<RunnerQuiet, delivery, waiting, starting, retryAt, tool, resp, finSnap,
                   outcome, helperVars>>

\* The whole AgentLoop, run in a process linked to the runner that the runner
\* watches (runner.ex:234, :1442-1474): final text, [SILENT], or an
\* error/timeout (a crash of the loop included, reported as a value).
Loop(r) ==
    /\ pc[r] = "loop"
    /\ tool[r] /= "ran"
    /\ \/ \E res \in {"text", "silent"} :
             /\ resp' = [resp EXCEPT ![r] = res]
             /\ Move(r, "complete")
       \/ /\ LoopCanFail
          /\ Move(r, "fail")
          /\ UNCHANGED resp
    /\ UNCHANGED <<RunnerQuiet, rowVars, finSnap, outcome, helperVars>>

\* Inside the loop the first tool starts. AgentLoop calls the runner's gate in
\* the loop's own process ahead of the call (gate_tool, agent_loop.ex
\* :1396-1457), and the gate stores the start on the run row in one Repo call
\* before the tool can run (put_tool_start_store, store_tool_start,
\* runner.ex:1739-1778): the start and its stamp are one step. A start the
\* store refuses (StampCanFail: an error, or no answer within the Repo's
\* bound) runs no tool: the call is traced unexecuted and the loop ends in
\* {:tool_start_unrecorded, _} (run/1's catch, agent_loop.ex:189-199), an
\* error the runner settles as any other. Only for a job that can be
\* retried: a cue run has no gate, its first tool is its mandate gate's
\* (tools_started_stamp, runner.ex:1731-1737; tla/specs/cue_inbox), and a
\* follow-up is never retried. Without StampsToolStart, the order before
\* JOB-9's fix: the loop announces the start by a message and runs the tool
\* at once, so its effect may already have happened while the row says
\* nothing. No fairness: a loop need start no tool.
ToolStarts(r) ==
    /\ ToolsCanStart /\ ~WatcherJob
    /\ pc[r] = "loop" /\ tool[r] = "none"
    /\ IF StampsToolStart
       THEN \/ /\ tool' = [tool EXCEPT ![r] = "stamped"]
               /\ UNCHANGED pc
            \/ /\ StampCanFail
               /\ tool' = [tool EXCEPT ![r] = "refused"]
               /\ Move(r, "fail")
       ELSE /\ tool' = [tool EXCEPT ![r] = "ran"]
            /\ UNCHANGED pc
    /\ UNCHANGED <<jobVars, runStatus, delivery, waiting, starting, retryAt, resp, finSnap,
                   outcome, helperVars, schedVars, ownerVars, envVars>>

\* Without StampsToolStart only: the runner handles the loop's tool-start
\* message and stores the start then, before it can handle the loop's result,
\* a later message from the same process. (That code's own refusal, logged
\* with the run going on, is left out: JOB-9's window is the tool before the
\* stamp.)
StampsTool(r) ==
    /\ ~StampsToolStart
    /\ pc[r] = "loop" /\ tool[r] = "ran"
    /\ tool' = [tool EXCEPT ![r] = "stamped"]
    /\ UNCHANGED <<jobVars, runStatus, delivery, waiting, starting, retryAt, runnerVars,
                   helperVars, schedVars, ownerVars, envVars>>

\* The runner's final write, as it lands. After the loop: status "ok" with
\* delivery "pending", or "skipped" for [SILENT] (Delivery.initial_status,
\* delivery.ex:24-31). After a loop error: status "error" with delivery
\* "pending" for the failure text. With AtomicSettle the job release lands in
\* the same transaction (Repo.settle_job_run, runner.ex:365 / :519).
RunnerWrite(r) ==
    /\ runStatus' = [runStatus EXCEPT ![r] = IF pc[r] = "complete" THEN "ok" ELSE "error"]
    /\ delivery' = [delivery EXCEPT ![r] =
                      IF pc[r] = "complete" /\ resp[r] = "silent" THEN "skipped" ELSE "pending"]
    /\ IF AtomicSettle THEN Release ELSE UNCHANGED jobState
    /\ UNCHANGED <<jobEnabled, nextRun>>

\* The settle's guard (ensure_job_run_active, repo.ex:7091-7098): only a
\* queued/running row may be settled. The split write has no guard.
Settleable(r) == ~AtomicSettle \/ runStatus[r] \in {"queued", "running"}

\* mark_completed (runner.ex:337-368) / mark_failed (:500-524) with
\* AtomicSettle: write output.md or error.md (folded in), then
\* Repo.settle_job_run (repo.ex:2563-2566, :7015-7031, :7091-7138): the run row and the job's
\* release in one transaction. After a success the memory write comes next;
\* after a loop error the memory-source update (runner.ex:522, folded in) and then the
\* send, so that runner goes straight to its send. A settle the guard refuses
\* fails the {:ok, _} match and kills the runner; that branch is unreachable,
\* since the reaper only settles a run whose runner is dead.
\* A cue run settles through CueAdmission.settle/3 -> Repo.settle_cue_run
\* (runner.ex:374-397, :470-498; settle_job_run refuses it, repo.ex:7023-7031,
\* :6895-6901): the same row and release, and its delivery in the same
\* transaction. A completed one acks it and goes on as above, with no summary
\* memory (complete_run, runner.ex:262-271). A failed one puts it back (Retries) and
\* then only marks its delivery "skipped", sending none of its text and leaving
\* the memory source alone (finish_cue_failure, runner.ex:550-556; a retried
\* provider failure first sends the once-a-day :task_provider_down watcher
\* notice, notify_provider_down, :525-545, which is not modelled), or ends it
\* and sends its failure text as above. A follow-up's run settles as a cron
\* run does (complete_run's and mark_failed's cue clauses match a cue run
\* alone); its trigger and its watcher's name, read at its start
\* (load_follow_up, runner.ex:319-327), add a line to its prompt and its
\* trace; a read that fails fails the run as a loop error does, and one that
\* times out kills the runner, a crash at "start".
\* M106: a run that is not a cue run's also has its job's retry decided in
\* the settle's transaction (RunnerRetries, SettledRetry). A failure retried,
\* and one a heal took (a job not set up by a guest), only mark the delivery
\* "skipped" (finish_failure, runner.ex:629-646); only a guest's job sends its
\* failure text. The settle carries the run's first tool start, which the
\* row keeps (the upsert's coalesce), and nothing here reads it again.
Settle(r) ==
    /\ AtomicSettle
    /\ pc[r] \in {"complete", "fail"}
    /\ IF Settleable(r)
       THEN /\ RunnerWrite(r)
            /\ \E retry \in Retries(r), jobRetry \in RunnerRetries(r) :
                  /\ waiting' = IF retry THEN waiting + 1 ELSE waiting
                  /\ SettledRetry(jobRetry, r)
                  /\ IF pc[r] = "complete"
                     THEN /\ Move(r, "memo") /\ UNCHANGED <<helper, outcome>>
                     ELSE IF retry \/ (~CueTask /\ (jobRetry \/ ~GuestJob))
                     THEN /\ Move(r, "mark")
                          /\ outcome' = [outcome EXCEPT ![r] = "skipped"]
                          /\ UNCHANGED helper
                     ELSE /\ Move(r, "await")
                          /\ helper' = [helper EXCEPT ![r] = "sending"]
                          /\ UNCHANGED outcome
            /\ tool' = [tool EXCEPT ![r] = "none"]
            /\ UNCHANGED <<downs, starting>>
       ELSE /\ Move(r, "gone")
            /\ downs' = IF r \in monitors THEN downs \cup {r} ELSE downs
            /\ UNCHANGED <<jobVars, rowVars, helper, outcome>>
    /\ resp' = [resp EXCEPT ![r] = "-"]
    /\ UNCHANGED <<ownerVars, envVars, sPc, reapReturn, monitors, changed, dueTimer,
                   refused, sRun, activeSnap, reapQ, sSnap, finSnap, tries,
                   delivered, report, cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* Without AtomicSettle, mark_completed before the fix: Repo.upsert_job_run of
\* the run row alone.
MarkCompleted(r) ==
    /\ ~AtomicSettle
    /\ pc[r] = "complete"
    /\ RunnerWrite(r)
    /\ Move(r, "memo")
    /\ resp' = [resp EXCEPT ![r] = "-"]
    /\ UNCHANGED <<ownerVars, envVars, schedVars, finSnap, outcome, helperVars, waiting, starting,
                   retryAt, tool>>

\* Without AtomicSettle, mark_failed before the fix: the run row alone.
MarkFailed(r) ==
    /\ ~AtomicSettle
    /\ pc[r] = "fail"
    /\ RunnerWrite(r)
    /\ Move(r, "finread")
    /\ UNCHANGED <<ownerVars, envVars, schedVars, resp, finSnap, outcome, helperVars,
                   waiting, starting, retryAt, tool>>

\* persist_run_summary_memory (runner.ex:277, :427-464): Repo.upsert_memory
\* (skipped for [SILENT]), then the memory-source update (:277, :632-646,
\* whose failures are logged), folded in. No modelled row changes; it is a
\* crash point. With AtomicSettle
\* finalize_delivery (:278, :596-604) follows: a pending delivery spawns the
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

\* mark_delivery (runner.ex:727-748): Repo.upsert_job_run with the result,
\* then {:stop, :normal}. A Scheduler that monitors the runner gets its DOWN
\* :normal, which now waits in its mailbox (HandleExit): since M106 5.3 its
\* handler re-arms the due timer, a Repo call, so it is no longer folded in.
\* The monitor is dropped here all the same: nothing reads a dead runner's
\* monitor but the cue share, which never binds one job.
\* A refused write exits the runner with the outcome and its error in its
\* reason (:737-747): that is RunnerCrash at "mark".
MarkDelivery(r) ==
    /\ pc[r] = "mark"
    /\ delivery' = [delivery EXCEPT ![r] =
                      IF delivery[r] = "skipped" THEN "skipped" ELSE outcome[r]]
    /\ outcome' = [outcome EXCEPT ![r] = "-"]
    /\ Move(r, "gone")
    /\ monitors' = monitors \ {r}
    /\ exits' = IF r \in monitors THEN exits \cup {r} ELSE exits
    /\ UNCHANGED <<jobVars, ownerVars, envVars, runStatus, waiting, starting, retryAt, tool,
                   resp, finSnap, helperVars, sPc, reapReturn, downs, changed, dueTimer,
                   refused, sRun, activeSnap, reapQ, sSnap, cuePending, admit, runsKnown, fQ,
                   fClaimed, sBy>>

RunnerStep(r) ==
    \/ MarkRunning(r) \/ Loop(r) \/ StampsTool(r) \/ Settle(r) \/ MarkCompleted(r)
    \/ Memory(r) \/ MarkFailed(r) \/ FinRead(r) \/ FinWrite(r) \/ GotResult(r)
    \/ MarkDelivery(r)

\* The runner dies at one of its Repo calls and the call never lands (a
\* kill, a failed {:ok, _} match, or mark_delivery's exit on a refused
\* write, runner.ex:623-629). A failed output.md/error.md write also
\* kills it ({:ok, _} match, runner.ex:339, :505); that write is folded into
\* the final write, so it is the crash at "complete"/"fail". The
\* memory-source calls after the split job upsert are a crash point with no
\* pc of their own: a crash there leaves the rows a crash at "mark" leaves,
\* minus the send. It raises nowhere while it waits on a send. While it
\* waits on its loop, the loop reports its own crash as a value
\* (runner.ex:1476-1493); the one death left there, a process the loop links
\* to itself killing the loop and through the link the runner, leaves the
\* rows the Loop step and then a crash at "complete" or "fail" leave, so it
\* needs no step of its own. Its supervisor does not restart it
\* (restart: :temporary, runner.ex:142); a Scheduler that monitors it gets a
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
                   cuePending, admit, runsKnown, fQ, fClaimed, exits, sBy>>

\* The runner's final write times out: GenServer.call exits the runner, which
\* passes no on_timeout (repo.ex:4445-4453), but the request stays in the
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
    /\ \E retry \in Retries(r), jobRetry \in RunnerRetries(r) :
          /\ waiting' = IF retry THEN waiting + 1 ELSE waiting
          /\ SettledRetry(jobRetry, r)
    /\ tool' = [tool EXCEPT ![r] = "none"]
    /\ Move(r, "gone")
    /\ resp' = [resp EXCEPT ![r] = "-"]
    /\ downs' = IF r \in monitors THEN downs \cup {r} ELSE downs
    /\ UNCHANGED <<ownerVars, envVars, helperVars, finSnap, outcome, sPc, reapReturn,
                   monitors, changed, dueTimer, refused, sRun, activeSnap, reapQ, sSnap,
                   cuePending, admit, runsKnown, fQ, fClaimed, starting, exits, sBy>>

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

\* The runner's own delivery timer (delivery_timeout_ms, runner.ex:1830):
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
\* no Scheduler (report_cue_failure, scheduler.ex:1049-1069), runs
\* CueRun.report_final_failure (cue_run.ex:372-384). The run was settled with
\* the delivery_status its claim wrote ("unset" here). Its first write
\* (mark_attempted, :386-391, after the context and call reads, which write
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
    /\ UNCHANGED <<jobVars, runStatus, waiting, starting, retryAt, tool, runnerVars, helper,
                   tries, delivered, schedVars, ownerVars, envVars>>

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

\* ... and record_delivery -> write_delivery (cue_run.ex:412-437):
\* Repo.upsert_job_run of the settled row with the result, over a "failed" a
\* reconcile pass may have written meanwhile.
ReportWrite(r) ==
    /\ report[r] \in {"sent", "failed"}
    /\ delivery' = [delivery EXCEPT ![r] = report[r]]
    /\ report' = [report EXCEPT ![r] = "none"]
    /\ UNCHANGED <<jobVars, runStatus, waiting, starting, retryAt, tool, runnerVars, helper,
                   tries, delivered, schedVars, ownerVars, envVars>>

-----------------------------------------------------------------------------
(* Crashes and restarts *)

\* The Scheduler (re)starts: init reconciles, then arms (scheduler.ex:189-273).
\* Its monitors, timers and mailbox are gone.
\* A pending :cue_admit dies with the old process, and init asks for none:
\* maybe_request_admission (scheduler.ex:270, :371-373) asks only while the cue
\* tree runs (Cues.running?/0), and that tree starts after the Scheduler under
\* :rest_for_one (application.ex:609, :290), so it is never up while the
\* Scheduler inits. The first admission after a restart is a tick's, a wake's,
\* a run's end's or a job change's. The run set starts unknown (runs_known?
\* false, scheduler.ex:249) until init's reconcile scan succeeds; without
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
    /\ sSnap' = NoSchedSnap
    /\ cuePending' = FALSE
    /\ admit' = FALSE
    /\ runsKnown' = (~CuesOn \/ ~ReconcilesRuns)
    /\ fQ' = 0
    /\ fClaimed' = {}
    /\ exits' = {}
    /\ sBy' = "-"

\* The Scheduler dies alone, at any point of any callback, and the call it
\* waited on never lands. A Repo call that times out no longer kills it
\* (the timeout steps above); another cause still does, such as
\* :rest_for_one restarting it when the MeetingsSupervisor started between
\* the RunnerSupervisor and it dies (application.ex:512-519), or a raise in
\* its own code. FermixCore.Supervisor is :rest_for_one and starts
\* JobRunnerSupervisor before JobScheduler (application.ex:512, :519, :290),
\* so the restart leaves every runner running.
SchedulerCrash ==
    /\ schedCrashes < SchedulerCrashes
    /\ schedCrashes' = schedCrashes + 1
    /\ SchedRestart
    /\ UNCHANGED <<jobVars, rowVars, runnerVars, helperVars, ownerVars, now, strayLoops,
                   daemonCrashed, schedTimeouts, cueSupply>>

\* The Scheduler dies of such a cause while it waits on the reaper's write,
\* and the write still lands (repo.ex:4440-4444). With AtomicSettle that is
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
\* runner.ex:1460-1464; spawn_monitor before JOB-8's fix).
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
    /\ hPc' = IF hPc = "read" THEN "idle" ELSE hPc
    /\ sinceRead' = {}
    /\ SchedRestart
    /\ UNCHANGED <<jobVars, rowVars, delivered, intent, movesLeft, editsLeft, manualLeft,
                   hSnap, hKind, defVer, hMark, overwrote, undidResume,
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
    /\ starting = 0
    /\ retryAt = "none"
    /\ tool = [r \in Runs |-> "none"]
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
    /\ sSnap = NoSchedSnap
    /\ cuePending = FALSE
    /\ admit = FALSE
    /\ runsKnown = TRUE
    /\ fQ = 0
    /\ fClaimed = {}
    /\ exits = {}
    /\ sBy = "-"
    /\ oPc = "idle"
    /\ oSnap = NoSnap
    /\ intent = "none"
    /\ movesLeft = OwnerMoves
    /\ editsLeft = OwnerEdits
    /\ manualLeft = ManualRuns
    /\ hPc = "idle"
    /\ hSnap = [en |-> TRUE, ver |-> 0]
    /\ hKind = "-"
    /\ defVer = 0
    /\ sinceRead = {}
    /\ hMark = FALSE
    /\ overwrote = FALSE
    /\ undidResume = FALSE
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
    /\ sPc = "idle" /\ downs = {} /\ exits = {} /\ ~changed /\ ~cuePending

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ Tick \/ Pause \/ PauseRead \/ PauseWrite \/ Resume \/ UpdateRead \/ UpdateWrite
    \/ ManualRun \/ CueArrives \/ HealRead \/ HealWrite
    \/ DueTimerFires \/ ReconcileFires \/ JobChanged \/ CueAdmit
    \/ \E r \in Runs : HandleDown(r) \/ HandleExit(r) \/ ToolStarts(r)
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
\* is eventually handled). A run's DOWN is a crash's or a normal exit's,
\* never both (a run id is reused only once neither waits), so one strongly
\* fair action per run serves both handlers. The clock, the owner, the cue inbox, the platform's
\* answers and every crash and Repo timeout get no fairness. JobChanged needs
\* an owner's request and CueAdmit the cue tree, so a configuration without
\* them can take neither (FairnessScope): their strong fairness holds on all
\* its behaviours, and is left out. TLC splits a liveness check in two for
\* each strongly fair action, so each one left out halves that check's work.
Fairness ==
    /\ WF_vars(SchedStep)
    /\ SF_vars(DueTimerFires) /\ SF_vars(ReconcileFires)
    /\ IF OwnerMoves + OwnerEdits + HealMoves > 0 THEN SF_vars(JobChanged) ELSE TRUE
    /\ IF CuesOn THEN SF_vars(CueAdmit) ELSE TRUE
    /\ \A r \in Runs :
          /\ SF_vars(HandleDown(r) \/ HandleExit(r))
          /\ WF_vars(RunnerStep(r))
          /\ WF_vars(HelperSend(r))
          /\ WF_vars(Watchdog(r))
          /\ WF_vars(ReportMark(r))
          /\ WF_vars(ReportSend(r))
          /\ WF_vars(ReportWrite(r))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* scheduler.ex:849-853: "a job mid-run carries state 'running' (the claim
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
\* owner resumes. For the Scheduler's own write of a job (checks 77 and
\* 78) it is a claim of the code: Repo.advance_stale_scheduled_job/4's doc
\* (repo.ex:2776-2778), "A write that landed since the scan (an owner's
\* pause, edit or removal, a heal's write, a run's claim or settle) keeps
\* what it wrote".
PauseNeverOverwritten == intent = "paused" => ~jobEnabled

\* Proposed rule: a resume the owner was told about stays in force until the
\* owner pauses.
ResumeNeverOverwritten == intent = "resumed" => jobEnabled

\* The same doc, for an edit: "any other keeps the columns this write does
\* not set" (repo.ex:2779-2780), and of the Scheduler's three writes of a job,
\* "none is a whole row from an earlier read" (:2775). Read as an
\* action rule: no step puts the job's definition back to one from before
\* an owner's edit (defVer, which only an edit or a heal's raise moves,
\* never goes down). A heal's raise over an edit moves it on and is
\* HealNeverOverwritesEdit's.
EditNeverOverwritten == [][defVer' >= defVer]_vars

\* scheduler.ex:60-64: a due tick that cannot drain its work, including "a
\* due job whose previous run is still active", re-arms no sooner than the
\* backoff, "so a persistently past-due-but-unclaimable job can never spin
\* the scheduler at 0ms"; :1420-1423 says it again. Read as an action rule: the
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

\* M60_WATCHER_CODING_RUNS.md §4.3: an automatic trigger "is written
\* starting and the next admission pass starts it", and the owner's yes
\* moves a card to starting; §4.2: a trigger whose follow-up is still
\* running "ends refused". Read as: a starting trigger is in the end started
\* or refused, whatever the job's state, so none is left starting.
TriggerDecided == starting > 0 ~> starting = 0

\* cue_run.ex:365-368 (report_final_failure's doc): "the run row's delivery
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

\* M106 5.3, retry.ex:7-11: "A run is retried only when both hold: no tool had
\* started in it (a second run after a tool ran would repeat what the tool
\* did), and its failure is one waiting can clear". Read as: no retry is ever
\* pending for a run in which a tool had started. A pending retry is what the
\* due scan claims; nothing but the owner's action or a later settle clears it.
RetryOnlyBeforeTool == retryAt /= "afterTool"

\* repo.ex:8820-8821: "The owner's pause, resume and edits each leave the job
\* with no retry (M106 5.3), in their own transaction, so an old retry never
\* fires after one"; and a run now takes the retry with it (:8303-8305). Read
\* as: no pending retry outlives one of those owner actions.
RetryClearedByOwner == retryAt /= "afterOwner"

\* M106 S4 (Repo.heal_job_write/5): "a job the owner changed while the
\* diagnosis ran gets no move". Read as: a heal's raised limit never lands
\* while an edit the owner made after the heal's read still stands. (Only a
\* raise can overwrite one: a pause writes enabled alone, and an owner write
\* that left enabled other than as read left it FALSE, as the pause would.)
HealNeverOverwritesEdit == ~overwrote

\* Read more strongly: a heal's pause never lands after the owner resumed the
\* job since the heal's read. The version compares values, so a resume that
\* leaves enabled as the heal read it is not seen by it (JOB-12); the mark
\* every owner write leaves is (JOB-12's fix, MarksOwnerWrites).
HealPauseNeverUndoesResume == ~undidResume

\* scheduler.ex:339-342: "A run's end can have set its job a retry (M106 5.3),
\* from its runner's settle or the crash settle here, so the due timer is
\* armed again for the earliest wakeup". Read as: once no runner is left and
\* the Scheduler, idle, has handled every DOWN, a pending retry of a claimable
\* job has its due timer armed to fire now (0 ms) or at the backoff. Without
\* Scheduler timeouts: after a reconcile scan that timed out, a runner the
\* restarted Scheduler never adopted dies with no DOWN, and the 60 s tick
\* finds its retry.
RetryTimerArmed ==
    (/\ RetryPending /\ jobEnabled /\ jobState = "scheduled"
     /\ sPc = "idle" /\ downs = {} /\ exits = {}
     /\ \A r \in Runs : ~Alive(r))
    => dueTimer \in {"zero", "backoff"}

\* Proposed rule: the job is "running" only while a run of it is queued or
\* running. Every claim, the retry's included, takes the job and inserts its
\* run in one transaction, and every settle releases the job as its run turns
\* final.
RunningHasRun == jobState = "running" => Active /= {}

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

\* The Scheduler is about to claim the job by its retry alone (its scan found
\* the job due by the retry, not by its next run), and the claim will take it:
\* the job enabled and "scheduled", no active run, a free run id. The retry
\* checks are not vacuous.
Witness_RetryClaimed ==
    ~(/\ sPc = "claim" /\ sBy = "retry" /\ RetryPending
      /\ jobEnabled /\ jobState = "scheduled" /\ Active = {} /\ FreeIds /= {})

\* The stale skip's write is the Scheduler's next step after both an owner's
\* pause and an edit landed since the due scan read the job: the guarded
\* write meets owner writes in its gap, so check 77's pass is not vacuous.
Witness_StaleSkipMeetsOwnerWrites ==
    ~(sPc = "skip" /\ ~jobEnabled /\ defVer /= sSnap.ver)

\* The follow-up claim takes a trigger while the job is "scheduled" again (a
\* resume mid-run) and its run is still active: only the race-stop refuses
\* it, so the one-active-run pass for a follow-up is not vacuous.
Witness_TriggerMeetsRun ==
    ~(/\ sPc = "f_claim" /\ FollowUp /\ fQ > 0
      /\ jobEnabled /\ jobState = "scheduled" /\ Active /= {})

=============================================================================
