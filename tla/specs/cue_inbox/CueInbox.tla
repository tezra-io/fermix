------------------------------ MODULE CueInbox ------------------------------
(***************************************************************************)
(* The M60 cue inbox for a few deliveries: accept and route, the filter    *)
(* dispatcher (Cues.Filters) and its call tasks, the boot reset, admission *)
(* of cue runs inside Jobs.Scheduler with the run slots, the run's claim   *)
(* and its settle by the runner or by the scheduler (a crash or a reap),   *)
(* reconciliation, the lifetime expiry sweep, the tools_started_at marker  *)
(* that ends retries, and (behind a switch) one proposal of a mandate in   *)
(* approve mode, answered from the owner's chat or (behind another) from   *)
(* one of the owner's devices by id (M60 app surface §3.7, D28).           *)
(*                                                                         *)
(* A topology constant fixes the deliveries: their watcher, subject and    *)
(* order (the delivery id is the arrival order, so a delivery is accepted  *)
(* only after every lower id). A watcher's kind is llm or none, and each   *)
(* watcher wakes its own task job; the job is named by its watcher.        *)
(*                                                                         *)
(* Time is booleans: a delivery's `due` (ready_at has passed), a watcher's *)
(* `wblocked` (filter_retry_at has not passed), a delivery's `valid`       *)
(* (valid_until has not passed), a proposal's `propLive` (expires_at has   *)
(* not passed). Backoff lengths, the held state (a longer backoff), daily  *)
(* caps, filter budgets, the inbox cap of 250 and its eviction, receipts,  *)
(* self-caused items, gaps, notices and telemetry are not modelled: none   *)
(* moves a live delivery between the states the properties read, except   *)
(* eviction, which only expires pending and passed rows like the sweep.    *)
(* The slot ceiling and the cue share are scaled down (code: 4 and 3;      *)
(* checks: MaxCue = MaxActive - 1), and so are the attempt caps (code: 3). *)
(* Cron and manual runs are not modelled: the cue share is a bound on cue  *)
(* runners, which is what leaves a cron run its slot.                      *)
(*                                                                         *)
(* One step = one GenServer callback, one Memory.Repo call (every SQLite   *)
(* access goes through the single Repo process, so one call is atomic      *)
(* whatever SQL it runs), or one side effect. Repo calls from one process  *)
(* are served in the order sent, and a call whose caller timed out still   *)
(* runs, ahead of anything that caller sends next (repo.ex call/2,         *)
(* call_or_timeout_error/3).                                               *)
(*                                                                         *)
(* The spec follows the code as committed in e0be70a6 (M60): the review-1  *)
(* (R1) fixes, lane R3's fixes of CUE-1 (the sweep reclaims a filtering    *)
(* row no task holds) and CUE-2 (no cue run is admitted while the run set  *)
(* is unknown), the review fixes after them, and the owner's devices       *)
(* answering a proposal. Line numbers below are those of that commit.      *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/cues/ingest.ex @ 331e846921b6
\* SOURCE: apps/fermix_core/lib/fermix_core/cues/filters.ex @ d1ca51d578e1
\* SOURCE: apps/fermix_core/lib/fermix_core/cues/supervisor.ex @ e1b36533a8b3
\* SOURCE: apps/fermix_core/lib/fermix_core/cues/sweeper.ex @ 7472388b5bc0
\* SOURCE: apps/fermix_core/lib/fermix_core/cues/proposals.ex @ 47e885432444
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/cues_sql.ex @ b55ea63d73b1
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/cues_filter_sql.ex @ 867ac594eb14
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/cues_runs_sql.ex#@open_sql,@cap_room_sql,@eligible_sql,@candidates_sql,@eligible_delivery_sql,@settle_facts_sql,eligible_delivery,settle_delivery,settle_facts,settle_held,settle_move,unspent_retry,spent_retry,move_patch,untouched @ f65310ef1716
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/cues_mandate_sql.ex#mark_tools_started,decide_propose,store_proposal,point_at_existing,decide_waiting,decided_or_why,decide_by_id,decided_by_id,end_denied,settle_proposal,expire_proposals @ 029c6975cee1
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/cue_admission.ex @ 94f9aac007e9
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/scheduler.ex#init,handle_info,handle_cast,maybe_request_admission,request_admission,admit_cue_runs,free_cue_slots,cue_run_attrs,start_cue_run,reconcile_active_runs,reconcile_active_run,adopt_live_run,monitored_run?,reap_orphaned_run,live_runner_pids,put_live_runner,active_run_count,start_or_mark_failed,monitor_entry,mark_run_crashed,mark_run_failed,mark_run_error,fail_delivery_after_settle @ b0de1f598583
\* SOURCE: apps/fermix_core/lib/fermix_core/jobs/runner.ex#complete_run,mark_cue_completed,mark_failed @ 4006c75e7387
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#call,call_or_timeout_error,periodic_opts,claim_cue_run,claim_cue_run_tx,claim_cue_run_in_tx,claim_delivery,claim_in_tx,fetch_claimable_job,ensure_no_active_job_run,settle_cue_run,settle_cue_run_tx,settle_cue_run_in_tx,active_run_trigger,release_cue_job,ensure_job_run_active,finish_job_settle,rollback_job_settle,upsert_job_run_row @ 87275850c2a1
\* SOURCE: apps/fermix_core/lib/fermix_core/application.ex#start_supervision_tree,supervision_children,maybe_cues_supervisor @ c12bdbb2ed72
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Topology,        \* which deliveries exist (see Wat, Subj, Kind below)
    MaxFaults,       \* how many injected faults one behaviour may contain
    MaxActive,       \* the scheduler's run ceiling (@max_active_runs 4, scheduler.ex:70)
    MaxCue,          \* the cue share of it (@max_cue_runs 3, cue_admission.ex:37)
    MaxFilterAttempts, \* @max_filter_attempts 3 (cues_filter_sql.ex:66), scaled
    MaxTaskAttempts, \* @max_task_attempts 3 (cues_runs_sql.ex:46), scaled
    \* Environment switches: what may happen.
    ProviderCanFail,     \* a filter call fails (provider or content failure) or
                         \* is still running at the 60 s deadline
    TasksCanCrash,       \* a filter call's task exits abnormally
    FiltersCanRestart,   \* Cues.Filters crashes and its rest_for_one siblings
                         \* after it restart with it
    SchedulerCanRestart, \* Jobs.Scheduler crashes and restarts (runners survive:
                         \* RunnerSupervisor starts before it)
    RunnersCanCrash,     \* a cue run's runner exits abnormally before it settles
    RunsCanFail,         \* a cue run ends in a failure (a provider failure or
                         \* any other), so its delivery is retried or exhausted
    RunsCanAct,          \* a cue run makes an allowed mandate call or a
                         \* proposal, which sets job_runs.tools_started_at
    FilterRepoCanFail,   \* a filter Repo call fails: the claim times out (and
                         \* still lands), a settle rolls back
    SchedulerRepoCanFail,\* a scheduler Repo call fails: the cue claim times out
                         \* (and still lands), a crash settle rolls back, the
                         \* reconcile scan errors
    LifetimesCanEnd,     \* a delivery's valid_until passes
    Proposals,           \* the run's first action is a proposal (approve mode)
                         \* and the owner may tap /confirm and /deny
    OwnerCanMistap,      \* the owner taps from a chat the proposal was not sent to
    AppAnswers,          \* the owner also answers from one of their devices (the
                         \* Mac app's socket, the management socket), by id:
                         \* Cues.Proposals.decide/4; the answers share the taps
    \* Mechanism switches: TRUE is the real code; each is FALSE in a needs check.
    SubjectRule,                \* the subject clause of @open_sql
                                \* (cues_runs_sql.ex:95-98)
    SubjectRuleCoversUndecided, \* ... over pending and filtering rows too (:98,
                                \* PLAN §1; draft 7 read passed and claimed only)
    ExcludesBusyWatchers,       \* the dispatcher passes the watchers whose call it
                                \* still holds (filters.ex:235)
    SettleFenced,               \* a filter settle needs its call open and the row's
                                \* filter_call_id (cues_filter_sql.ex:432 open_call,
                                \* :543 move)
    TasksDieWithDispatcher,     \* FilterSupervisor starts after Filters in the
                                \* rest_for_one filtering group (FilteringSupervisor,
                                \* cues/supervisor.ex:44-47, :51, :58-63)
    BootReset,                  \* Filters.init resets filtering rows
                                \* (filters.ex:102, :159; cues_filter_sql.ex:635)
    NonePassesAtAccept,         \* a none watcher's delivery is inserted passed
                                \* (cues_sql.ex:631)
    ClaimNeedsIdleJob,          \* a cue claim needs the job scheduled with no active
                                \* run (@open_sql :91-94; repo.ex fetch_claimable_job,
                                \* ensure_no_active_job_run)
    CueSlotCap,                 \* free = min(max_active - active, 3 - active_cue)
                                \* (cue_admission.ex:57)
    AtomicCueSettle,            \* the run row, the job release and the delivery move
                                \* are one transaction (repo.ex settle_cue_run_in_tx)
    RunSettleFenced,            \* a run settle needs the run active
                                \* (repo.ex ensure_job_run_active) and the delivery
                                \* claimed by it (cues_runs_sql.ex:313)
    ReapsOnlyDeadRuns,          \* reconciliation reaps a run only when the runner
                                \* supervisor no longer holds its runner
                                \* (scheduler.ex:386, :398)
    ReconcilesRuns,             \* init and the 60 s tick reconcile unsettled runs
                                \* (scheduler.ex:210, :250, :370)
    ExhaustsAfterAction,        \* a failure once tools_started_at is set ends the
                                \* delivery exhausted (cues_runs_sql.ex:335)
    ToolsMarkWriteOnce,         \* the run upsert never clears tools_started_at
                                \* (repo.ex upsert_job_run_row: coalesce)
    ConfirmFenced,              \* a confirm is one UPDATE on state, token, chat and
                                \* expiry (cues_mandate_sql.ex decide_waiting)
    ReclaimsOrphans,            \* every sweep puts back a filtering row whose call
                                \* the dispatcher does not hold (R3, CUE-1:
                                \* filters.ex:192-215 reclaim_orphans,
                                \* cues_filter_sql.ex:670 reclaim_in_tx)
    AdmitsAfterScan,            \* no cue run is admitted while the last reconcile
                                \* scan failed (R3, CUE-2: scheduler.ex:312
                                \* free_cue_slots; the flag :374, :382)
    AppDecideFenced             \* a device's answer is one UPDATE on id, state and
                                \* expiry (cues_mandate_sql.ex decide_by_id)

-----------------------------------------------------------------------------
(* Topologies *)

Wat == CASE Topology = "subject"      -> <<"a", "a">>
         [] Topology = "two_subjects" -> <<"a", "a">>
         [] Topology = "two_tasks"    -> <<"a", "b">>
         [] Topology = "one_llm"      -> <<"a">>
         [] Topology = "one_none"     -> <<"a">>
         [] Topology = "mixed"        -> <<"a", "b">>
         \* One more of each entity, for the hand runs the README records.
         [] Topology = "subject3"     -> <<"a", "a", "a">>
         [] Topology = "two_subjects3" -> <<"a", "a", "a">>
         [] Topology = "three_tasks"  -> <<"a", "b", "c">>
         [] Topology = "two_llm"      -> <<"a", "a">>
         [] Topology = "two_none"     -> <<"a", "a">>
         [] Topology = "mixed3"       -> <<"a", "a", "b">>

Subj == CASE Topology = "subject"      -> <<"s", "s">>
          [] Topology = "two_subjects" -> <<"s", "t">>
          [] Topology = "two_tasks"    -> <<"s", "t">>
          [] Topology = "one_llm"      -> <<"s">>
          [] Topology = "one_none"     -> <<"s">>
          [] Topology = "mixed"        -> <<"s", "t">>
          [] Topology = "subject3"     -> <<"s", "s", "s">>
          [] Topology = "two_subjects3" -> <<"s", "t", "s">>
          [] Topology = "three_tasks"  -> <<"s", "t", "u">>
          [] Topology = "two_llm"      -> <<"s", "t">>
          [] Topology = "two_none"     -> <<"s", "t">>
          [] Topology = "mixed3"       -> <<"s", "s", "t">>

Kind(w) == IF \/ Topology \in {"subject", "one_llm", "subject3", "two_llm"}
              \/ (Topology \in {"mixed", "mixed3"} /\ w = "a")
           THEN "llm" ELSE "none"

NDel == Len(Wat)
D == 1..NDel
Watchers == {Wat[d] : d \in D}
\* Every claim that does not end its delivery spends a fault, so these never
\* bind (IdBoundsNeverBind in TypeOK).
MaxCalls == NDel + MaxFaults
MaxRuns == NDel + MaxFaults
Calls == 1..MaxCalls
Runs == 1..MaxRuns

Live == {"pending", "filtering", "passed", "claimed"}
Terminal == {"acked", "dropped", "exhausted", "expired"}

Min(a, b) == IF a < b THEN a ELSE b

VARIABLES
    \* SQLite rows: the only state a restart keeps.
    dstate,     \* cue_deliveries.state ("absent" before the accept)
    fcall,      \* cue_deliveries.filter_call_id (0 = NULL)
    holder,     \* cue_deliveries.claimed_run_id (0 = NULL)
    due,        \* ready_at <= now
    valid,      \* now < valid_until
    fatt,       \* filter_attempts
    tatt,       \* task_attempts
    wblocked,   \* cue_watchers.filter_retry_at > now
    jstate,     \* scheduled_jobs.state of each watcher's task
    callOpen,   \* cue_filter_calls.finished_at IS NULL
    callDel,    \* cue_filter_calls.delivery_id (0 = no row)
    nextCall,   \* the next filter_call_id
    rstatus,    \* job_runs.status: "none", "active" (queued or running), "final"
    rjob,       \* job_runs.job_id
    rdel,       \* job_runs.cue_delivery_id
    nextRun,    \* the next run id
    acted,      \* job_runs.tools_started_at as the mandate gate wrote it
    prop,       \* cue_proposals.state ("none" before the proposal)
    propLive,   \* now < cue_proposals.expires_at
    \* Processes.
    disp,         \* Cues.Filters: "up" or "down" (restarting)
    resetPending, \* Filters state: the boot reset has not run yet
    inflight,     \* Filters state: the calls whose task it holds
    task,         \* each call's task: "none", "deciding", "finishing" (its
                  \* result written or refused, not yet reported) or "crashed"
                  \* (exited abnormally, DOWN not yet handled)
    sched,        \* Jobs.Scheduler: "up" or "down" (restarting)
    monitors,     \* Scheduler state: the runs it monitors (all cue runs here)
    runner,       \* each run's runner: "none", "live", "half" (delivery moved,
                  \* run row not yet written: only without AtomicCueSettle),
                  \* "exited" or "crashed" (gone, its DOWN not yet handled)
    runsKnown,    \* Scheduler state: the last reconcile scan succeeded, so the
                  \* monitors hold every live runner (runs_known?)
    confirmers,   \* /confirm commands, or device confirms' tasks, that won
                  \* the confirm and have not run the call yet
    taps,         \* the owner's answers left (/confirm, /deny, or a device's)
    \* Observers.
    staleFilterWrite,   \* a filter settle moved a row its call did not hold
    staleRunWrite,      \* a run settle moved a row its run did not hold
    retriedAfterAction, \* a delivery went back to passed from a run that acted
    badConfirm,         \* a confirm was accepted not waiting, expired or from
                        \* the wrong chat
    callRuns,           \* how many times the proposal's call ran (saturates at 2)
    faults

vars == <<dstate, fcall, holder, due, valid, fatt, tatt, wblocked, jstate,
          callOpen, callDel, nextCall, rstatus, rjob, rdel, nextRun, acted,
          prop, propLive, disp, resetPending, inflight, task, sched, monitors,
          runner, runsKnown, confirmers, taps, staleFilterWrite, staleRunWrite,
          retriedAfterAction, badConfirm, callRuns, faults>>

rowD == <<dstate, fcall, holder, due, valid, fatt, tatt>>
callRows == <<callOpen, callDel, nextCall>>
runRows == <<rstatus, rjob, rdel, nextRun, acted>>
propVars == <<prop, propLive, confirmers, taps, badConfirm, callRuns>>
dispVars == <<disp, resetPending, inflight, task>>
schedVars == <<sched, monitors, runner, runsKnown>>
obs == <<staleFilterWrite, staleRunWrite, retriedAfterAction>>

Fault == faults > 0 /\ faults' = faults - 1

-----------------------------------------------------------------------------
(* Accept and route: Cues.Ingest.accept/3 -> CuesSql {:accept, ...}, one   *)
(* BEGIN IMMEDIATE (cues_sql.ex:330, accept_in_tx :420): insert_and_route  *)
(* (:569) and insert_deliveries (:615): one delivery per enabled           *)
(* listening watcher, pending for llm, passed with reason "no filter" and  *)
(* ready_at = now for none. Ids are AUTOINCREMENT: the arrival order.      *)

Accept(d) ==
    /\ dstate[d] = "absent"
    /\ \A o \in D : o < d => dstate[o] /= "absent"
    /\ dstate' = [dstate EXCEPT ![d] =
                    IF Kind(Wat[d]) = "none" /\ NonePassesAtAccept THEN "passed" ELSE "pending"]
    /\ due' = [due EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<fcall, holder, valid, fatt, tatt, wblocked, jstate, callRows, runRows,
                   propVars, dispVars, schedVars, obs, faults>>

-----------------------------------------------------------------------------
(* The filter dispatcher (Cues.Filters) and its claims *)

WatcherBusy(w) == \E c \in inflight : callDel[c] /= 0 /\ Wat[callDel[c]] = w
HasFiltering(w) == \E d \in D : Wat[d] = w /\ dstate[d] = "filtering"
\* A due pending delivery the filter may claim: its ready_at has come and its
\* valid_until has not (cues_filter_sql.ex eligible/4, `d.valid_until > ?`).
DuePending(w) == {d \in D : Wat[d] = w /\ dstate[d] = "pending" /\ due[d] /\ valid[d]}
Oldest(S) == CHOOSE d \in S : \A o \in S : d <= o

\* CuesFilterSql eligible/4 (cues_filter_sql.ex:169): an enabled llm
\* watcher, filter_retry_at null or past, no delivery in filtering (:179),
\* not in `exclude`, with a due pending delivery; its oldest one is claimed.
\* The 16-claim and 4-in-flight caps never bind with two llm deliveries.
FilterClaimable(w) ==
    /\ Kind(w) = "llm"
    /\ ~wblocked[w]
    /\ ~HasFiltering(w)
    /\ ~(ExcludesBusyWatchers /\ WatcherBusy(w))
    /\ DuePending(w) /= {}

\* claim_one/3 (cues_filter_sql.ex:211): pending -> filtering with a new
\* filter_call_id (CuesSql.transition, fence :none) and the call row.
ClaimFilterRows(w) ==
    LET d == Oldest(DuePending(w))
        c == nextCall
    IN /\ dstate' = [dstate EXCEPT ![d] = "filtering"]
       /\ fcall' = [fcall EXCEPT ![d] = c]
       /\ callOpen' = [callOpen EXCEPT ![c] = TRUE]
       /\ callDel' = [callDel EXCEPT ![c] = d]
       /\ nextCall' = nextCall + 1

\* dispatch -> claim/2 (filters.ex:219, :233): one {:claim, now, free, busy}
\* Repo call (periodic opts, :488), then start_call/2 (:249) starts each claim's task
\* under FilterSupervisor (async_nolink, monitored) in the same callback.
FClaim(w) ==
    /\ disp = "up" /\ ~resetPending
    /\ FilterClaimable(w)
    /\ nextCall <= MaxCalls
    /\ ClaimFilterRows(w)
    /\ task' = [task EXCEPT ![nextCall] = "deciding"]
    /\ inflight' = inflight \cup {nextCall}
    /\ UNCHANGED <<holder, due, valid, fatt, tatt, wblocked, jstate, runRows, propVars,
                   disp, resetPending, schedVars, obs, faults>>

\* The same claim call times out: claim/2 traces sweep_error (filter_claim) and
\* starts nothing (filters.ex:243-245), but the request still runs and its
\* write lands. No task holds the row and the dispatcher's in_flight does not
\* know it: the sweep's reclaim (FReclaim) or a boot reset puts it back (CUE-1,
\* fixed in R3; without ReclaimsOrphans only a boot reset does).
FClaimTimesOut(w) ==
    /\ FilterRepoCanFail /\ Fault
    /\ disp = "up" /\ ~resetPending
    /\ FilterClaimable(w)
    /\ nextCall <= MaxCalls
    /\ ClaimFilterRows(w)
    /\ UNCHANGED <<holder, due, valid, fatt, tatt, wblocked, jstate, runRows, propVars,
                   dispVars, schedVars, staleRunWrite, retriedAfterAction,
                   staleFilterWrite>>

\* The boot reset: CuesFilterSql {:reset, now} (cues_filter_sql.ex:635, :655):
\* every filtering row back to pending with its fence cleared and its
\* attempts unchanged, every open call finished as aborted. One transaction.
ResetRows ==
    /\ dstate' = [d \in D |-> IF dstate[d] = "filtering" THEN "pending" ELSE dstate[d]]
    /\ fcall' = [d \in D |-> IF dstate[d] = "filtering" THEN 0 ELSE fcall[d]]
    /\ callOpen' = [c \in Calls |-> FALSE]

\* Filters.init -> boot_reset/1 (filters.ex:102, :159). A reset that fails is
\* traced and stays pending; every dispatch tries it first (:219). The new
\* dispatcher claims nothing before its first sweep timer (ready?, :111, :129,
\* :135); under weak fairness that timer always fires, so the delay is not
\* modelled. A reset that times out still runs before the dispatcher's next
\* call, so it is the success branch taken where it lands.
FBoot ==
    /\ disp = "down"
    /\ disp' = "up"
    /\ IF BootReset
       THEN \/ /\ ResetRows /\ resetPending' = FALSE
               /\ UNCHANGED faults
            \/ /\ FilterRepoCanFail /\ Fault
               /\ resetPending' = TRUE
               /\ UNCHANGED <<dstate, fcall, callOpen>>
       ELSE /\ resetPending' = FALSE
            /\ UNCHANGED <<dstate, fcall, callOpen, faults>>
    /\ UNCHANGED <<holder, due, valid, fatt, tatt, wblocked, jstate, callDel, nextCall,
                   runRows, propVars, inflight, task, schedVars, obs>>

FRetryReset ==
    /\ disp = "up" /\ resetPending
    /\ \/ /\ ResetRows /\ resetPending' = FALSE
          /\ UNCHANGED faults
       \/ /\ FilterRepoCanFail /\ Fault
          /\ UNCHANGED <<dstate, fcall, callOpen, resetPending>>
    /\ UNCHANGED <<holder, due, valid, fatt, tatt, wblocked, jstate, callDel, nextCall,
                   runRows, propVars, disp, inflight, task, schedVars, obs>>

\* A filtering row whose call the dispatcher does not hold: a claim that landed
\* after its Repo call timed out, or a settle that rolled back (CUE-1).
Orphan(d) == dstate[d] = "filtering" /\ fcall[d] \notin inflight

\* The 60 s sweep -> reclaim_orphans/1 (filters.ex:133, :192-215), skipped
\* while the boot reset is pending: CuesFilterSql {:reclaim_orphans, held,
\* cutoff, now} (cues_filter_sql.ex:130, reclaim_in_tx :670), one transaction:
\* each filtering row whose filter_call_id is not one the dispatcher holds goes
\* back to pending through the boot reset's fenced move (reset_each/2, :655),
\* fence cleared and attempts unchanged, and its open call is finished aborted
\* (abort_orphan_calls/3, :705). The cutoff (a call started more than the 60 s
\* deadline plus 30 s ago) changes when, not whether: a younger orphan is
\* reclaimed by a later sweep. A reclaim that fails changes no row and is
\* tried by the next sweep; one that times out still lands, as this step.
FReclaim ==
    /\ ReclaimsOrphans
    /\ disp = "up" /\ ~resetPending
    /\ \E d \in D : Orphan(d)
    /\ dstate' = [d \in D |-> IF Orphan(d) THEN "pending" ELSE dstate[d]]
    /\ fcall' = [d \in D |-> IF Orphan(d) THEN 0 ELSE fcall[d]]
    /\ callOpen' = [c \in Calls |->
                      IF \E d \in D : Orphan(d) /\ fcall[d] = c THEN FALSE ELSE callOpen[c]]
    /\ UNCHANGED <<holder, due, valid, fatt, tatt, wblocked, jstate, callDel, nextCall,
                   runRows, propVars, dispVars, schedVars, obs, faults>>

-----------------------------------------------------------------------------
(* One call's settle: CuesFilterSql {:settle, call_id, result, now}, one   *)
(* BEGIN IMMEDIATE (cues_filter_sql.ex:116, :400): open_call/2 refuses a  *)
(* call already finished (:432), apply_result/5 (:482) moves the row       *)
(* through move/5 (:543), fenced on filtering and filter_call_id. Zero     *)
(* rows changed is {:error, :stale}: the row is not written, and since R1  *)
(* the open call is closed aborted in the same commit (abort_stale_call/3, *)
(* :421).                                                                   *)

Holds(c) == LET d == callDel[c] IN dstate[d] = "filtering" /\ fcall[d] = c /\ callOpen[c]
Lands(c) == IF SettleFenced THEN Holds(c) ELSE dstate[callDel[c]] = "filtering"

\* res: "pass", "drop", "pfail" (provider failure), "cfail" (content failure).
SettleRows(c, res) ==
    LET d == callDel[c]
        w == Wat[d]
    IN IF ~Lands(c)
       THEN /\ callOpen' = [callOpen EXCEPT ![c] = FALSE]
            /\ UNCHANGED <<dstate, fcall, due, fatt, wblocked, staleFilterWrite>>
       ELSE /\ staleFilterWrite' = (staleFilterWrite \/ ~Holds(c))
            /\ callOpen' = [callOpen EXCEPT ![c] = FALSE]
            /\ CASE res = "pass" ->
                      \* :482: passed, ready_at = now; the fence is kept. A
                      \* watcher paused while the call ran gets filtering ->
                      \* pending instead (fence cleared, attempts unchanged);
                      \* watchers are always enabled here, so that is never taken.
                      /\ dstate' = [dstate EXCEPT ![d] = "passed"]
                      /\ due' = [due EXCEPT ![d] = TRUE]
                      /\ UNCHANGED <<fcall, fatt, wblocked>>
                 [] res = "drop" ->
                      \* :491
                      /\ dstate' = [dstate EXCEPT ![d] = "dropped"]
                      /\ UNCHANGED <<fcall, due, fatt, wblocked>>
                 [] res = "pfail" ->
                      \* :500: back to pending unchanged; the watcher backs off
                      /\ dstate' = [dstate EXCEPT ![d] = "pending"]
                      /\ fcall' = [fcall EXCEPT ![d] = 0]
                      /\ wblocked' = [wblocked EXCEPT ![w] = TRUE]
                      /\ UNCHANGED <<due, fatt>>
                 [] res = "cfail" ->
                      \* :518: an attempt spent; retried later, or exhausted
                      /\ fatt' = [fatt EXCEPT ![d] = fatt[d] + 1]
                      /\ IF fatt[d] + 1 >= MaxFilterAttempts
                         THEN /\ dstate' = [dstate EXCEPT ![d] = "exhausted"]
                              /\ UNCHANGED <<fcall, due>>
                         ELSE /\ dstate' = [dstate EXCEPT ![d] = "pending"]
                              /\ fcall' = [fcall EXCEPT ![d] = 0]
                              /\ due' = [due EXCEPT ![d] = FALSE]
                      /\ UNCHANGED wblocked

\* run_call/2 inside the task (filters.ex:271): Llm.decide, then the task's
\* own settle (:300). The model call is invisible; the Repo call is
\* the step. A failure result spends a fault.
TaskSettle(c, res) ==
    /\ task[c] = "deciding"
    /\ IF res \in {"pfail", "cfail"} THEN ProviderCanFail /\ Fault ELSE UNCHANGED faults
    /\ SettleRows(c, res)
    /\ task' = [task EXCEPT ![c] = "finishing"]
    /\ UNCHANGED <<holder, valid, tatt, jstate, callDel, nextCall, runRows, propVars,
                   disp, resetPending, inflight, schedVars, staleRunWrite,
                   retriedAfterAction>>

TaskStep(c) == \E res \in {"pass", "drop", "pfail", "cfail"} : TaskSettle(c, res)

\* The task's settle rolls back: it traces run_error settle_failed and reports
\* {:settled, false} (filters.ex:365-384, finish/5). The row stays filtering with its
\* call open; once the task has reported, the sweep reclaims it (CUE-1).
TaskSettleFails(c) ==
    /\ FilterRepoCanFail /\ Fault
    /\ task[c] = "deciding"
    /\ task' = [task EXCEPT ![c] = "finishing"]
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propVars, disp,
                   resetPending, inflight, schedVars, obs>>

\* The task returns and the dispatcher's reported/3 (filters.ex:307) frees
\* its slot: one step, because the dispatcher still excludes the watcher until
\* it handles the reply. A task whose dispatcher is gone just ends.
TaskReport(c) ==
    /\ task[c] = "finishing"
    /\ task' = [task EXCEPT ![c] = "none"]
    /\ inflight' = inflight \ {c}
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propVars, disp,
                   resetPending, schedVars, obs, faults>>

\* The task exits abnormally (a raise before or after its settle).
TaskCrash(c) ==
    /\ TasksCanCrash /\ Fault
    /\ task[c] \in {"deciding", "finishing"}
    /\ task' = [task EXCEPT ![c] = IF c \in inflight THEN "crashed" ELSE "none"]
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propVars, disp,
                   resetPending, inflight, schedVars, obs>>

\* handle_info({:DOWN, ...}) -> crashed/3 -> end_here/3 (filters.ex:320, :346,
\* down_result :360): an abnormal exit is a content failure for the cue,
\* written with the same fence. A settle that rolls back leaves the row
\* filtering for the sweep to reclaim (CUE-1).
FDown(c) ==
    /\ disp = "up" /\ c \in inflight /\ task[c] = "crashed"
    /\ task' = [task EXCEPT ![c] = "none"]
    /\ inflight' = inflight \ {c}
    /\ \/ SettleRows(c, "cfail") /\ UNCHANGED faults
       \/ /\ FilterRepoCanFail /\ Fault
          /\ UNCHANGED <<dstate, fcall, due, fatt, wblocked, callOpen, staleFilterWrite>>
    /\ UNCHANGED <<holder, valid, tatt, jstate, callDel, nextCall, runRows, propVars,
                   disp, resetPending, schedVars, staleRunWrite, retriedAfterAction>>

\* {:deadline, ref} -> expire/2 (filters.ex:332): a task still running 60 s
\* after its claim (the provider is slow, or a notice send is) is killed and
\* a provider failure (kind timeout) is written with the same fence.
FDeadline(c) ==
    /\ ProviderCanFail /\ Fault
    /\ disp = "up" /\ c \in inflight /\ task[c] \in {"deciding", "finishing"}
    /\ task' = [task EXCEPT ![c] = "none"]
    /\ inflight' = inflight \ {c}
    /\ SettleRows(c, "pfail")
    /\ UNCHANGED <<holder, valid, tatt, jstate, callDel, nextCall, runRows, propVars,
                   disp, resetPending, schedVars, staleRunWrite, retriedAfterAction>>

\* Cues.Filters crashes. Its group, FilteringSupervisor, is rest_for_one
\* (cues/supervisor.ex:44-47, :51, :58-63): FilterSupervisor, which starts
\* after it, terminates with every call task before Filters starts again. The
\* cue supervisor above the groups is one_for_one (:55), so an intake or
\* Sweeper crash never reaches the dispatcher. A task that already sent its settle has it in the
\* Repo's mailbox ahead of the new dispatcher's reset, so it lands first (the
\* step order below keeps that). Without TasksDieWithDispatcher a task keeps
\* running beside the new dispatcher, which does not know it.
FiltersRestart ==
    /\ FiltersCanRestart /\ Fault
    /\ disp = "up"
    /\ inflight /= {} \/ \E d \in D : dstate[d] = "filtering"
    /\ disp' = "down"
    /\ inflight' = {}
    /\ resetPending' = FALSE
    /\ task' = [c \in Calls |->
                  IF TasksDieWithDispatcher \/ task[c] = "crashed" THEN "none" ELSE task[c]]
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propVars, schedVars, obs>>

\* filter_retry_at passes: the claim's next_at timer (arm_due, filters.ex:263) or
\* the 60 s sweep finds the watcher again.
WatcherDue(w) ==
    /\ wblocked[w]
    /\ wblocked' = [wblocked EXCEPT ![w] = FALSE]
    /\ UNCHANGED <<rowD, jstate, callRows, runRows, propVars, dispVars, schedVars, obs,
                   faults>>

\* A pending or passed row's ready_at passes (a content retry, a run retry).
BecomeDue(d) ==
    /\ ~due[d] /\ dstate[d] \in {"pending", "passed"}
    /\ due' = [due EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<dstate, fcall, holder, valid, fatt, tatt, wblocked, jstate, callRows,
                   runRows, propVars, dispVars, schedVars, obs, faults>>

-----------------------------------------------------------------------------
(* The lifetime clock and the sweep *)

Expire(d) ==
    /\ LifetimesCanEnd
    /\ valid[d] /\ dstate[d] /= "absent"
    /\ valid' = [valid EXCEPT ![d] = FALSE]
    /\ UNCHANGED <<dstate, fcall, holder, due, fatt, tatt, wblocked, jstate, callRows,
                   runRows, propVars, dispVars, schedVars, obs, faults>>

\* Cues.Sweeper :expire_lifetime (sweeper.ex:33) -> CuesSql expire_lifetime
\* (cues_sql.ex:1115, expire_each :709): pending and passed rows past valid_until become
\* expired (transition with no fence); filtering and claimed are never touched.
SweepExpire(d) ==
    /\ ~valid[d] /\ dstate[d] \in {"pending", "passed"}
    /\ dstate' = [dstate EXCEPT ![d] = "expired"]
    /\ UNCHANGED <<fcall, holder, due, valid, fatt, tatt, wblocked, jstate, callRows,
                   runRows, propVars, dispVars, schedVars, obs, faults>>

-----------------------------------------------------------------------------
(* Admission and the cue claim, inside Jobs.Scheduler *)

ActiveRun(w) == \E r \in Runs : rjob[r] = w /\ rstatus[r] = "active"
SubjectStates == IF SubjectRuleCoversUndecided THEN Live ELSE {"passed", "claimed"}
OlderSameSubjectLive(d) ==
    \E o \in D : o < d /\ Wat[o] = Wat[d] /\ Subj[o] = Subj[d] /\ dstate[o] \in SubjectStates

\* @eligible_sql = @open_sql and @cap_room_sql (cues_runs_sql.ex:81-118), one
\* rule for the candidates (:123) and the claim's in-transaction re-read
\* (eligible_delivery/3, :225). The daily cap is 0 here (no cap). Since R1 the
\* rule does not read cue_watchers.enabled (a paused watcher's passed items
\* still run); watchers are always enabled here. A delivery past its
\* valid_until is never claimed (`d.valid_until > ?`): the lifetime sweep's.
Eligible(d) ==
    /\ dstate[d] = "passed" /\ due[d] /\ valid[d]
    /\ ClaimNeedsIdleJob => (jstate[Wat[d]] = "scheduled" /\ ~ActiveRun(Wat[d]))
    /\ SubjectRule => ~OlderSameSubjectLive(d)
EligibleOf(w) == {d \in D : Wat[d] = w /\ Eligible(d)}

\* The runner supervisor's active children (active_run_count/1,
\* scheduler.ex:489) and the scheduler's monitored cue runs
\* (CueAdmission.active_cue_runs/1). free_cue_slots/1 (scheduler.ex:312):
\* none while the last reconcile scan failed (the monitors may miss runners
\* that survived a restart, CUE-2), else CueAdmission.free_slots/3.
LiveRunners == {r \in Runs : runner[r] \in {"live", "half"}}
FreeSlots ==
    IF AdmitsAfterScan /\ ~runsKnown THEN 0
    ELSE IF CueSlotCap
         THEN Min(MaxActive - Cardinality(LiveRunners), MaxCue - Cardinality(monitors))
         ELSE MaxActive - Cardinality(LiveRunners)

\* Repo.claim_cue_run/4 (repo.ex claim_cue_run_in_tx, claim_in_tx,
\* claim_delivery): one BEGIN IMMEDIATE: the task's oldest eligible delivery,
\* the job to running, the run inserted (trigger "cue", cue_delivery_id), the
\* delivery passed -> claimed with claimed_run_id.
ClaimRunRows(w) ==
    LET d == Oldest(EligibleOf(w))
        r == nextRun
    IN /\ dstate' = [dstate EXCEPT ![d] = "claimed"]
       /\ holder' = [holder EXCEPT ![d] = r]
       /\ rstatus' = [rstatus EXCEPT ![r] = "active"]
       /\ rjob' = [rjob EXCEPT ![r] = w]
       /\ rdel' = [rdel EXCEPT ![r] = d]
       /\ jstate' = [jstate EXCEPT ![w] = "running"]
       /\ nextRun' = nextRun + 1

\* :cue_admit / a tick -> admit_cue_runs/2 (scheduler.ex:260, :293), gated on
\* cues_running? (the cue tree alive, :202; always true here):
\* CueAdmission.free_slots/3 then claim/4 (cue_admission.ex:57, :82), each
\* claim one Repo call, then start_cue_run/2 -> start_or_mark_failed/3 (scheduler.ex:357, :735)
\* starts the runner and monitors it, in the same callback. One claim per
\* step; the slots are recomputed each step, which bounds the claims exactly
\* as the pass's one `free` does.
Admit(w) ==
    /\ sched = "up"
    /\ FreeSlots > 0
    /\ EligibleOf(w) /= {}
    /\ nextRun <= MaxRuns
    /\ ClaimRunRows(w)
    /\ runner' = [runner EXCEPT ![nextRun] = "live"]
    /\ monitors' = monitors \cup {nextRun}
    /\ UNCHANGED <<fcall, due, valid, fatt, tatt, wblocked, callRows, acted, propVars,
                   dispVars, sched, runsKnown, obs, faults>>

\* The claim call times out (periodic opts): claim_candidate/4 logs it and
\* starts nothing (claim_candidate/4, cue_admission.ex:132), but the write lands: a run with
\* no runner, which reconciliation reaps.
AdmitTimesOut(w) ==
    /\ SchedulerRepoCanFail /\ Fault
    /\ sched = "up"
    /\ FreeSlots > 0
    /\ EligibleOf(w) /= {}
    /\ nextRun <= MaxRuns
    /\ ClaimRunRows(w)
    /\ UNCHANGED <<fcall, due, valid, fatt, tatt, wblocked, callRows, acted, propVars,
                   dispVars, schedVars, obs>>

-----------------------------------------------------------------------------
(* The settle: Repo.settle_cue_run/3 (repo.ex settle_cue_run_in_tx):       *)
(* ensure_job_run_active, the run row upserted, release_cue_job (running  *)
(* -> scheduled), and CuesRunsSql.settle_delivery/4 (cues_runs_sql.ex:254), *)
(* whose settle_held/5 (:313, :325) moves the delivery only while          *)
(* it is claimed by this run; otherwise the run settles and the delivery   *)
(* is left untouched.                                                      *)

\* settle_move/4 (cues_runs_sql.ex:332-344), with `tools` the run row's
\* tools_started_at as the upsert left it. how: "ack" (ignored or acted),
\* "pfail" (provider failure: no attempt spent), "ofail" (any other failure),
\* "sched" (a reap or a monitored crash: as ofail, the cap being 0).
DeliveryMove(r, how, tools) ==
    LET d == rdel[r] IN
    IF dstate[d] = "claimed" /\ (RunSettleFenced => holder[d] = r)
    THEN /\ staleRunWrite' = (staleRunWrite \/ holder[d] /= r)
         /\ CASE how = "ack" ->
                   /\ dstate' = [dstate EXCEPT ![d] = "acked"]
                   /\ UNCHANGED <<holder, due, tatt, retriedAfterAction>>
              [] how /= "ack" /\ tools /\ ExhaustsAfterAction ->
                   /\ dstate' = [dstate EXCEPT ![d] = "exhausted"]
                   /\ UNCHANGED <<holder, due, tatt, retriedAfterAction>>
              [] how = "pfail" ->
                   /\ dstate' = [dstate EXCEPT ![d] = "passed"]
                   /\ holder' = [holder EXCEPT ![d] = 0]
                   /\ due' = [due EXCEPT ![d] = FALSE]
                   /\ retriedAfterAction' = (retriedAfterAction \/ acted[r])
                   /\ UNCHANGED tatt
              [] how \in {"ofail", "sched"} ->
                   /\ tatt' = [tatt EXCEPT ![d] = tatt[d] + 1]
                   /\ IF tatt[d] + 1 >= MaxTaskAttempts
                      THEN /\ dstate' = [dstate EXCEPT ![d] = "exhausted"]
                           /\ UNCHANGED <<holder, due, retriedAfterAction>>
                      ELSE /\ dstate' = [dstate EXCEPT ![d] = "passed"]
                           /\ holder' = [holder EXCEPT ![d] = 0]
                           /\ due' = [due EXCEPT ![d] = FALSE]
                           /\ retriedAfterAction' = (retriedAfterAction \/ acted[r])
    ELSE UNCHANGED <<dstate, holder, due, tatt, staleRunWrite, retriedAfterAction>>

\* The run row final and its job released (release_cue_job: only running goes
\* back to scheduled; last_* untouched).
RunRelease(r) ==
    /\ rstatus' = [rstatus EXCEPT ![r] = "final"]
    /\ jstate' = [jstate EXCEPT ![rjob[r]] = "scheduled"]

RunActive(r) == RunSettleFenced => rstatus[r] = "active"

\* A runner process leaves: its DOWN reaches the scheduler only if monitored.
Exit(r, kind) == IF r \in monitors THEN kind ELSE "none"

\* The runner's settle: complete_run/2 -> mark_cue_completed/4 or
\* mark_failed/3 (runner.ex:230, :321, :409; the settle :340, :431) ->
\* CueAdmission.settle/3. Its attrs are the run as the runner read it at
\* start, with tools_started_at nil, so the column survives only through the
\* upsert's coalesce. `{:ok, ...} =` on {:error, :run_not_active} raises: the
\* runner crashes. A failure outcome spends a fault.
RunnerSettle(r, how) ==
    /\ runner[r] = "live"
    /\ AtomicCueSettle
    /\ IF how = "ack" THEN UNCHANGED faults ELSE RunsCanFail /\ Fault
    /\ IF RunActive(r)
       THEN /\ RunRelease(r)
            /\ DeliveryMove(r, how, ToolsMarkWriteOnce /\ acted[r])
            /\ runner' = [runner EXCEPT ![r] = Exit(r, "exited")]
       ELSE /\ runner' = [runner EXCEPT ![r] = Exit(r, "crashed")]
            /\ UNCHANGED <<dstate, holder, due, tatt, staleRunWrite, retriedAfterAction,
                           rstatus, jstate>>
    /\ UNCHANGED <<fcall, valid, fatt, wblocked, callRows, rjob, rdel, nextRun, acted,
                   propVars, dispVars, sched, monitors, runsKnown, staleFilterWrite>>

\* Without AtomicCueSettle: the delivery move, then the run row and the
\* release, as two Repo calls.
RunnerSettleDelivery(r, how) ==
    /\ runner[r] = "live"
    /\ ~AtomicCueSettle
    /\ IF how = "ack" THEN UNCHANGED faults ELSE RunsCanFail /\ Fault
    /\ IF RunActive(r)
       THEN /\ DeliveryMove(r, how, ToolsMarkWriteOnce /\ acted[r])
            /\ runner' = [runner EXCEPT ![r] = "half"]
       ELSE /\ runner' = [runner EXCEPT ![r] = Exit(r, "crashed")]
            /\ UNCHANGED <<dstate, holder, due, tatt, staleRunWrite, retriedAfterAction>>
    /\ UNCHANGED <<fcall, valid, fatt, wblocked, jstate, callRows, runRows, propVars,
                   dispVars, sched, monitors, runsKnown, staleFilterWrite>>

RunnerSettleRun(r) ==
    /\ runner[r] = "half"
    /\ IF RunActive(r)
       THEN /\ RunRelease(r)
            /\ runner' = [runner EXCEPT ![r] = Exit(r, "exited")]
       ELSE /\ runner' = [runner EXCEPT ![r] = Exit(r, "crashed")]
            /\ UNCHANGED <<rstatus, jstate>>
    /\ UNCHANGED <<rowD, wblocked, callRows, rjob, rdel, nextRun, acted, propVars,
                   dispVars, sched, monitors, runsKnown, obs, faults>>

RunnerStep(r) ==
    \/ \E how \in {"ack", "pfail", "ofail"} : RunnerSettle(r, how) \/ RunnerSettleDelivery(r, how)
    \/ RunnerSettleRun(r)

\* An allowed mandate call or a proposal: the decision's Repo call sets
\* tools_started_at in the same transaction (cues_mandate_sql.ex
\* mark_tools_started, decide_propose). With Proposals, the run's first one is
\* the proposal, stored waiting (store_proposal) with where it was sent.
RunnerAct(r) ==
    /\ RunsCanAct
    /\ runner[r] = "live" /\ ~acted[r]
    /\ acted' = [acted EXCEPT ![r] = TRUE]
    /\ IF Proposals /\ prop = "none"
       THEN /\ prop' = "waiting"
            /\ propLive' = TRUE
       ELSE UNCHANGED <<prop, propLive>>
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, rstatus, rjob, rdel, nextRun,
                   confirmers, taps, badConfirm, callRuns, dispVars, schedVars, obs, faults>>

RunnerCrash(r) ==
    /\ RunnersCanCrash /\ Fault
    /\ runner[r] \in {"live", "half"}
    /\ runner' = [runner EXCEPT ![r] = Exit(r, "crashed")]
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propVars, dispVars, sched,
                   monitors, runsKnown, obs>>

-----------------------------------------------------------------------------
(* The scheduler's recovery paths *)

\* mark_run_failed/4 -> mark_run_error/4 (scheduler.ex:831, :887):
\* the run read fresh (so its tools_started_at is the column's), then
\* CueAdmission.settle(attrs, :scheduler, ...).
SchedulerSettle(r) ==
    IF RunActive(r)
    THEN /\ RunRelease(r)
         /\ DeliveryMove(r, "sched", acted[r])
    ELSE UNCHANGED <<dstate, holder, due, tatt, staleRunWrite, retriedAfterAction,
                     rstatus, jstate>>

\* handle_info({:DOWN, ...}) (scheduler.ex:266): a normal exit only frees
\* the monitor; a crash is settled by the scheduler. A crash settle that
\* rolls back is logged and left for reconciliation.
SchedDown(r) ==
    /\ sched = "up"
    /\ r \in monitors /\ runner[r] \in {"exited", "crashed"}
    /\ monitors' = monitors \ {r}
    /\ runner' = [runner EXCEPT ![r] = "none"]
    /\ IF runner[r] = "crashed"
       THEN \/ SchedulerSettle(r) /\ UNCHANGED faults
            \/ /\ SchedulerRepoCanFail /\ Fault
               /\ UNCHANGED <<dstate, holder, due, tatt, staleRunWrite,
                              retriedAfterAction, rstatus, jstate>>
       ELSE UNCHANGED <<dstate, holder, due, tatt, staleRunWrite, retriedAfterAction,
                        rstatus, jstate, faults>>
    /\ UNCHANGED <<fcall, valid, fatt, wblocked, callRows, rjob, rdel, nextRun, acted,
                   propVars, dispVars, sched, runsKnown, staleFilterWrite>>

Alive(r) == runner[r] \in {"live", "half"}

\* One unsettled run of a reconciliation pass (reconcile_active_runs/1 and
\* reconcile_active_run/3, scheduler.ex:370, :386): a run whose runner the
\* supervisor still holds is adopted (monitored, :398); any other is reaped
\* (:412), whatever its monitor. Without ReapsOnlyDeadRuns a run
\* the scheduler does not monitor is reaped even with its runner alive.
ReconcileRun(r) ==
    /\ ReconcilesRuns
    /\ sched = "up"
    /\ rstatus[r] = "active"
    /\ IF ReapsOnlyDeadRuns
       THEN IF Alive(r)
            THEN /\ r \notin monitors
                 /\ monitors' = monitors \cup {r}
                 /\ UNCHANGED <<dstate, holder, due, tatt, staleRunWrite,
                                retriedAfterAction, rstatus, jstate, faults>>
            ELSE /\ \/ SchedulerSettle(r) /\ UNCHANGED faults
                    \/ /\ SchedulerRepoCanFail /\ Fault
                       /\ UNCHANGED <<dstate, holder, due, tatt, staleRunWrite,
                                      retriedAfterAction, rstatus, jstate>>
                 /\ UNCHANGED monitors
       ELSE /\ r \notin monitors \/ ~Alive(r)
            /\ \/ SchedulerSettle(r) /\ UNCHANGED faults
               \/ /\ SchedulerRepoCanFail /\ Fault
                  /\ UNCHANGED <<dstate, holder, due, tatt, staleRunWrite,
                                 retriedAfterAction, rstatus, jstate>>
            /\ UNCHANGED monitors
    /\ UNCHANGED <<fcall, valid, fatt, wblocked, callRows, rjob, rdel, nextRun, acted,
                   propVars, dispVars, sched, runner, runsKnown, staleFilterWrite>>

\* Jobs.Scheduler crashes. Its rest_for_one parent restarts it; the runner
\* supervisor starts before it, so runners survive, unmonitored, and a DOWN
\* that was in the old mailbox is lost. Everything after it restarts too, and
\* application.ex supervision_children/2 puts the cue tree last, so the
\* code restarts Cues.Filters with it; the model takes that as FiltersRestart,
\* a fault of its own, so the two are explored apart and together.
SchedRestart ==
    /\ SchedulerCanRestart /\ Fault
    /\ sched = "up"
    /\ \E r \in Runs : rstatus[r] = "active"
    /\ sched' = "down"
    /\ monitors' = {}
    /\ runner' = [r \in Runs |-> IF runner[r] \in {"exited", "crashed"} THEN "none" ELSE runner[r]]
    /\ runsKnown' = FALSE
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propVars, dispVars, obs>>

\* init/1 (scheduler.ex:152): runs_known? starts false (:200), then
\* reconcile_active_runs (:210). The scan adopts every live runner's run (the
\* dead ones are reaped by ReconcileRun, the same function) and sets the run
\* set known (:374). A scan that errors or times out (periodic opts) is logged,
\* leaves the run set unknown (:382) and init goes on with no monitors
\* (:370-384); it then requests an admission pass (:213,
\* maybe_request_admission/1), which admits no cue run while the set is
\* unknown (free_cue_slots/1, :312). Without reconciliation there is no scan,
\* and the empty monitors are taken as the run set, as before R3.
SchedBoot ==
    /\ sched = "down"
    /\ sched' = "up"
    /\ \/ /\ ReconcilesRuns /\ ReapsOnlyDeadRuns
          /\ monitors' = {r \in Runs : Alive(r) /\ rstatus[r] = "active"}
          /\ runsKnown' = TRUE
          /\ UNCHANGED faults
       \/ /\ ~(ReconcilesRuns /\ ReapsOnlyDeadRuns)
          /\ monitors' = {}
          /\ runsKnown' = TRUE
          /\ UNCHANGED faults
       \/ /\ ReconcilesRuns /\ SchedulerRepoCanFail /\ Fault
          /\ monitors' = {}
          /\ runsKnown' = FALSE
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propVars, dispVars, runner,
                   obs>>

\* The 60 s reconcile tick's scan (handle_info(:reconcile_tick),
\* scheduler.ex:245-250 -> reconcile_active_runs/1, :370) succeeding while the
\* run set is unknown: every live runner's run is adopted in that callback and
\* the set is known again (:374). Reaping the dead runs of the same pass is
\* ReconcileRun (which, without ReapsOnlyDeadRuns, also reaps the live runs
\* this step then leaves unmonitored).
SchedRescan ==
    /\ ReconcilesRuns
    /\ sched = "up" /\ ~runsKnown
    /\ monitors' = IF ReapsOnlyDeadRuns
                   THEN monitors \cup {r \in Runs : Alive(r) /\ rstatus[r] = "active"}
                   ELSE monitors
    /\ runsKnown' = TRUE
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propVars, dispVars, sched,
                   runner, obs, faults>>

\* A tick's scan that fails: the run set is unknown until a scan succeeds
\* (:382), even though the monitors already hold every runner.
SchedRescanFails ==
    /\ ReconcilesRuns /\ SchedulerRepoCanFail /\ Fault
    /\ sched = "up" /\ runsKnown
    /\ runsKnown' = FALSE
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propVars, dispVars, sched,
                   monitors, runner, obs>>

-----------------------------------------------------------------------------
(* One proposal (approve mode), abstract: Cues.Proposals. The confirm is  *)
(* one Repo call:                                                         *)
(* UPDATE ... WHERE token_digest = ? AND state = 'waiting' AND             *)
(* sent_platform = ? AND sent_chat_id = ? AND sent_user_id = ? AND        *)
(* expires_at > ? (cues_mandate_sql.ex decide_waiting); the command that  *)
(* won it re-checks and runs the recorded call once (proposals.ex         *)
(* confirm/3, run_confirmed/3).                                           *)

\* /confirm from `right` (the chat the proposal was sent to) or another chat.
OwnerConfirm(right) ==
    /\ Proposals /\ prop /= "none" /\ taps > 0
    /\ right \/ OwnerCanMistap
    /\ taps' = taps - 1
    /\ LET ok == prop = "waiting" /\ propLive /\ right IN
       IF ConfirmFenced => ok
       THEN /\ prop' = "confirmed"
            /\ confirmers' = confirmers + 1
            /\ badConfirm' = (badConfirm \/ ~ok)
       ELSE UNCHANGED <<prop, confirmers, badConfirm>>
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propLive, callRuns,
                   dispVars, schedVars, obs, faults>>

\* /deny, fenced the same way (deny/3, {:deny_proposal, ...}).
OwnerDeny ==
    /\ Proposals /\ prop = "waiting" /\ propLive /\ taps > 0
    /\ taps' = taps - 1
    /\ prop' = "denied"
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propLive, confirmers,
                   badConfirm, callRuns, dispVars, schedVars, obs, faults>>

\* An answer from one of the owner's devices (Cues.Proposals.decide/4): one
\* Repo call, UPDATE ... WHERE id = ? AND state = 'waiting' AND expires_at > ?
\* (cues_mandate_sql.ex decide_by_id). No chat to match: the transport placed
\* the device. A confirm then runs in a task of its own exactly as /confirm
\* runs (start_run, run_confirmed/3: the confirmer below); the answer is
\* acknowledged at once. The first answer from any surface wins.
AppConfirm ==
    /\ Proposals /\ AppAnswers /\ prop /= "none" /\ taps > 0
    /\ taps' = taps - 1
    /\ LET ok == prop = "waiting" /\ propLive IN
       IF AppDecideFenced => ok
       THEN /\ prop' = "confirmed"
            /\ confirmers' = confirmers + 1
            /\ badConfirm' = (badConfirm \/ ~ok)
       ELSE UNCHANGED <<prop, confirmers, badConfirm>>
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propLive, callRuns,
                   dispVars, schedVars, obs, faults>>

\* A device's denial, through the same UPDATE (decide_by_id, then end_denied).
AppDeny ==
    /\ Proposals /\ AppAnswers /\ prop /= "none" /\ taps > 0
    /\ taps' = taps - 1
    /\ IF AppDecideFenced => (prop = "waiting" /\ propLive)
       THEN prop' = "denied"
       ELSE UNCHANGED prop
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propLive, confirmers,
                   badConfirm, callRuns, dispVars, schedVars, obs, faults>>

\* The proposal's send fails (send_new/5): it is refused, "could not reach you".
\* With an app surface the code keeps it waiting instead (the reach rule); the
\* refusal is kept here for every check, a superset of the code's steps, so
\* every safety verdict still covers the app's world.
PropSendFails ==
    /\ Proposals /\ prop = "waiting" /\ Fault
    /\ prop' = "refused"
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propLive, confirmers, taps,
                   badConfirm, callRuns, dispVars, schedVars, obs>>

PropClock ==
    /\ prop /= "none" /\ propLive
    /\ propLive' = FALSE
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, prop, confirmers, taps,
                   badConfirm, callRuns, dispVars, schedVars, obs, faults>>

\* The sweeper's :proposal_expiry step (Proposals.expire/3,
\* {:expire_proposals, ...}): waiting past expires_at becomes expired.
PropSweep ==
    /\ prop = "waiting" /\ ~propLive
    /\ prop' = "expired"
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propLive, confirmers, taps,
                   badConfirm, callRuns, dispVars, schedVars, obs, faults>>

\* run_confirmed/3: the re-check passes and the executor runs exactly the
\* recorded call (execute/4), or it refuses (refuse_confirmed/4: confirmed ->
\* refused), a re-check that raises included (guarded_recheck/3), and so does
\* a device's confirm whose task could not start (start_run/3). Either way
\* that command is done.
ConfirmerStep ==
    /\ confirmers > 0
    /\ confirmers' = confirmers - 1
    /\ \/ /\ callRuns' = IF callRuns >= 2 THEN 2 ELSE callRuns + 1
          /\ UNCHANGED prop
       \/ /\ prop = "confirmed" /\ prop' = "refused"
          /\ UNCHANGED callRuns
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, propLive, taps, badConfirm,
                   dispVars, schedVars, obs, faults>>

\* The command dies after the confirm and before it writes a result: before
\* its call (it is killed, or a device's answer was recorded and its task
\* never started), or once its call has started, which may then have run
\* (killed mid-call, say; a raise inside the call itself is caught and
\* finished unknown at once, record_result/3, which is ConfirmerStep's first
\* branch). The proposal stays confirmed with no result; report_unknown/4
\* tells the owner once, finishes it unknown and it is never run again.
ConfirmerCrash ==
    /\ confirmers > 0 /\ TasksCanCrash /\ Fault
    /\ confirmers' = confirmers - 1
    /\ \/ UNCHANGED callRuns
       \/ callRuns' = IF callRuns >= 2 THEN 2 ELSE callRuns + 1
    /\ UNCHANGED <<rowD, wblocked, jstate, callRows, runRows, prop, propLive, taps,
                   badConfirm, dispVars, schedVars, obs>>

-----------------------------------------------------------------------------
(* Type and sanity invariant *)

\* The spec's id bounds never block a claim, so they lose no behaviour.
IdBoundsNeverBind ==
    /\ (disp = "up" /\ ~resetPending /\ \E w \in Watchers : FilterClaimable(w))
          => nextCall <= MaxCalls
    /\ (sched = "up" /\ FreeSlots > 0 /\ \E w \in Watchers : EligibleOf(w) /= {})
          => nextRun <= MaxRuns

TypeOK ==
    /\ dstate \in [D -> {"absent"} \cup Live \cup Terminal]
    /\ fcall \in [D -> 0..MaxCalls]
    /\ holder \in [D -> 0..MaxRuns]
    /\ due \in [D -> BOOLEAN] /\ valid \in [D -> BOOLEAN]
    /\ fatt \in [D -> 0..MaxFilterAttempts] /\ tatt \in [D -> 0..MaxTaskAttempts]
    /\ wblocked \in [Watchers -> BOOLEAN]
    /\ jstate \in [Watchers -> {"scheduled", "running"}]
    /\ callOpen \in [Calls -> BOOLEAN] /\ callDel \in [Calls -> 0..NDel]
    /\ nextCall \in 1..(MaxCalls + 1)
    /\ rstatus \in [Runs -> {"none", "active", "final"}]
    /\ rjob \in [Runs -> Watchers \cup {"none"}] /\ rdel \in [Runs -> 0..NDel]
    /\ nextRun \in 1..(MaxRuns + 1)
    /\ acted \in [Runs -> BOOLEAN]
    /\ prop \in {"none", "waiting", "confirmed", "denied", "expired", "refused"}
    /\ propLive \in BOOLEAN
    /\ disp \in {"up", "down"} /\ resetPending \in BOOLEAN
    /\ inflight \subseteq Calls
    /\ task \in [Calls -> {"none", "deciding", "finishing", "crashed"}]
    /\ \A c \in inflight : task[c] /= "none"
    /\ sched \in {"up", "down"} /\ monitors \subseteq Runs
    /\ runner \in [Runs -> {"none", "live", "half", "exited", "crashed"}]
    /\ runsKnown \in BOOLEAN
    /\ confirmers \in 0..2 /\ taps \in 0..2
    /\ callRuns \in 0..2
    /\ faults \in 0..MaxFaults
    /\ IdBoundsNeverBind

-----------------------------------------------------------------------------
Init ==
    /\ dstate = [d \in D |-> "absent"]
    /\ fcall = [d \in D |-> 0]
    /\ holder = [d \in D |-> 0]
    /\ due = [d \in D |-> FALSE]
    /\ valid = [d \in D |-> TRUE]
    /\ fatt = [d \in D |-> 0]
    /\ tatt = [d \in D |-> 0]
    /\ wblocked = [w \in Watchers |-> FALSE]
    /\ jstate = [w \in Watchers |-> "scheduled"]
    /\ callOpen = [c \in Calls |-> FALSE]
    /\ callDel = [c \in Calls |-> 0]
    /\ nextCall = 1
    /\ rstatus = [r \in Runs |-> "none"]
    /\ rjob = [r \in Runs |-> "none"]
    /\ rdel = [r \in Runs |-> 0]
    /\ nextRun = 1
    /\ acted = [r \in Runs |-> FALSE]
    /\ prop = "none"
    /\ propLive = FALSE
    /\ disp = "up"
    /\ resetPending = FALSE
    /\ inflight = {}
    /\ task = [c \in Calls |-> "none"]
    /\ sched = "up"
    /\ monitors = {}
    /\ runner = [r \in Runs |-> "none"]
    /\ runsKnown = TRUE
    /\ confirmers = 0
    /\ taps = IF Proposals THEN 2 ELSE 0
    /\ staleFilterWrite = FALSE
    /\ staleRunWrite = FALSE
    /\ retriedAfterAction = FALSE
    /\ badConfirm = FALSE
    /\ callRuns = 0
    /\ faults = MaxFaults

\* The legitimate end of the processes: every delivery accepted, both
\* GenServers up and idle, no task, runner or confirm command alive and no
\* DOWN waiting. Rows may still be live: whether one is stranded is for
\* NothingStranded to judge (the job_runs convention), so deadlock checking
\* reports only a process wedged mid-step.
Done ==
    /\ \A d \in D : dstate[d] /= "absent"
    /\ disp = "up" /\ ~resetPending /\ inflight = {}
    /\ \A c \in Calls : task[c] = "none"
    /\ sched = "up" /\ monitors = {}
    /\ \A r \in Runs : runner[r] = "none"
    /\ confirmers = 0

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E d \in D : Accept(d) \/ BecomeDue(d) \/ Expire(d) \/ SweepExpire(d)
    \/ \E w \in Watchers : FClaim(w) \/ FClaimTimesOut(w) \/ WatcherDue(w)
                           \/ Admit(w) \/ AdmitTimesOut(w)
    \/ FBoot \/ FRetryReset \/ FiltersRestart \/ FReclaim
    \/ \E c \in Calls : TaskStep(c) \/ TaskSettleFails(c) \/ TaskReport(c)
                        \/ TaskCrash(c) \/ FDown(c) \/ FDeadline(c)
    \/ \E r \in Runs : RunnerStep(r) \/ RunnerAct(r) \/ RunnerCrash(r)
                       \/ SchedDown(r) \/ ReconcileRun(r)
    \/ SchedRestart \/ SchedBoot \/ SchedRescan \/ SchedRescanFails
    \/ \E right \in BOOLEAN : OwnerConfirm(right)
    \/ OwnerDeny \/ AppConfirm \/ AppDeny \/ PropSendFails \/ PropClock \/ PropSweep
    \/ ConfirmerStep \/ ConfirmerCrash
    \/ Terminated

\* Fairness only on what Fermix drives: both GenServers' callbacks and
\* timers (claims, admission, DOWNs, reconciliation and its rescan, the boot
\* steps, the filter sweep's reclaim, backoff and retry timers firing), each
\* live task's and runner's next step, the
\* sweeper, and a confirm command finishing. None on the outside world
\* (accepts, the provider's choice of answer, the lifetime clock, the owner)
\* or on faults (crashes, failures, deadlines, Repo errors).
Fairness ==
    /\ WF_vars(FBoot) /\ WF_vars(FRetryReset) /\ WF_vars(SchedBoot)
    /\ WF_vars(FReclaim) /\ WF_vars(SchedRescan)
    /\ \A w \in Watchers : WF_vars(FClaim(w)) /\ WF_vars(WatcherDue(w)) /\ WF_vars(Admit(w))
    /\ \A c \in Calls : WF_vars(TaskStep(c)) /\ WF_vars(TaskReport(c)) /\ WF_vars(FDown(c))
    /\ \A d \in D : WF_vars(BecomeDue(d)) /\ WF_vars(SweepExpire(d))
    /\ \A r \in Runs : WF_vars(RunnerStep(r)) /\ WF_vars(SchedDown(r))
                       /\ WF_vars(ReconcileRun(r))
    /\ WF_vars(ConfirmerStep) /\ WF_vars(PropSweep)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* cues_runs_sql.ex:19-28 and PLAN §1 "Subject order": a delivery is claimable
\* only if no older delivery of the same watcher and subject is pending,
\* filtering, passed or claimed. Read as a state: while a delivery is
\* claimed, no older one of its watcher and subject is live (terminal states
\* are absorbing, so a breach at claim time stays visible).
SubjectOrder ==
    \A d, o \in D :
        (o < d /\ Wat[o] = Wat[d] /\ Subj[o] = Subj[d] /\ dstate[d] = "claimed")
            => dstate[o] \notin Live

\* filters.ex:7-12 and design §17: "at most one filter call per watcher is in
\* flight": never two live call tasks for one watcher.
OneTaskPerWatcher ==
    \A w \in Watchers :
        Cardinality({c \in Calls : task[c] \in {"deciding", "finishing"}
                                    /\ callDel[c] /= 0 /\ Wat[callDel[c]] = w}) <= 1

\* PLAN §1 "Fenced transitions": a late filter write (after the boot reset,
\* or after another settle) is refused; zero rows changed, nothing written.
\* Read as: a row leaves filtering only by the call that holds it. With the
\* settle mapping (a failure moves a row only to pending or exhausted), this
\* is design §17's "a failed filter never passes or drops a cue".
FencedFilterMoves == ~staleFilterWrite

\* The same rule for runs (cues_runs_sql.ex:248-250, repo.ex settle_cue_run
\* doc): a row leaves claimed only by the run that holds it, while active.
FencedRunMoves == ~staleRunWrite

\* Design §17: "a delivery is acked only by a settled run".
AckedBySettledRun ==
    \A d \in D : dstate[d] = "acked" => rstatus[holder[d]] = "final"

\* Design §17 / §9.2: "one active run per job holds" for cue claims.
OneActiveRunPerJob ==
    \A w \in Watchers : Cardinality({r \in Runs : rjob[r] = w /\ rstatus[r] = "active"}) <= 1

\* cue_admission.ex:9-11: "Cue runs hold at most three of the scheduler's run
\* slots ... so a cron run always keeps one"; design §17 "cue runs never take
\* the last slot". Read as: live cue runners never exceed the cue share.
CueShare == Cardinality(LiveRunners) <= MaxCue

\* cues_runs_sql.ex:238-239, design §17: "no run is retried after an allowed
\* mandate call or a proposal".
NoRetryAfterAction == ~retriedAfterAction

\* Design §17: "a none watcher's deliveries are passed at acceptance and never
\* filtered".
NonePassedAtAccept ==
    \A d \in D : Kind(Wat[d]) = "none" => dstate[d] \notin {"pending", "filtering"}

\* Design §17 and proposals.ex:15-23: a proposal's call runs "only after a
\* confirmation while it was waiting and unexpired", from the chat it was
\* sent to or one of the owner's devices, and "at most once", whichever
\* surface answered first (M60 app surface §3.7).
ConfirmedOnlyWhileWaiting == ~badConfirm
RunsAtMostOnce == callRuns <= 1

\* Design §17: "no undecided or passed delivery is stranded while its watcher
\* and task are enabled and under their caps (a held watcher retries until a
\* call succeeds or the delivery's lifetime ends)". Watchers and tasks are
\* always enabled here and no cap is set.
NothingStranded == \A d \in D : (dstate[d] \in Live) ~> (dstate[d] \in Terminal)

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* A passed delivery waits only because an older one of its subject is still
\* undecided (the case PLAN §1 widened the rule for).
Witness_WaitsBehindUndecided ==
    ~\E d, o \in D :
        /\ o < d /\ Wat[o] = Wat[d] /\ Subj[o] = Subj[d]
        /\ dstate[o] \in {"pending", "filtering"}
        /\ dstate[d] = "passed" /\ due[d]
        /\ jstate[Wat[d]] = "scheduled" /\ ~ActiveRun(Wat[d])

=============================================================================
