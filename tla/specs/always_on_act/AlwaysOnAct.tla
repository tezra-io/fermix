---------------------------- MODULE AlwaysOnAct ----------------------------
(***************************************************************************)
(* Always On's steps (Always On setup §3.4, §5): every step a surface asks *)
(* for is one `home.act`, which `Management.AlwaysOn.act/2` runs in one    *)
(* serializer per engine. It reads the summary first and runs the step    *)
(* only when the summary offers that action under the key it was drawn    *)
(* with (HomeSummary.find_action/3).                                       *)
(*                                                                         *)
(* The scene is Restore here on a linked desktop the home moved from (its *)
(* moved marker) whose server went silent, and whose Fermix reads the     *)
(* server's home: the one step that starts a job of the family. Two       *)
(* surfaces press at once, the act keeps its request in return.json       *)
(* before the job starts and takes it back when the start is refused, and *)
(* the job's ending takes it back however its run ended, while the job    *)
(* still counts as running.                                                *)
(*                                                                         *)
(* What it describes:                                                      *)
(*  - Management.AlwaysOn (always_on.ex): act/2 hands the request to the  *)
(*    serializer (handle_call); run reads the summary and checks the key  *)
(*    (offered); restore_here keeps the request (restore_record,         *)
(*    keep_record), then start_restore starts the home_restore job with   *)
(*    its ending (request_done) and, refused busy, takes the request back *)
(*    itself.                                                              *)
(*  - Management.Jobs: one running job per kind and name, and at most a   *)
(*    few in all (handle_call {:start, ...}: running?/3, running_count),  *)
(*    and a job's ending, which the family runs once the run is over     *)
(*    however it ended (complete_task, task_down, finish, begin_ending),  *)
(*    the job counted running until the ending is done (ending_done,      *)
(*    ending_down, end_closing).                                           *)
(*  - Management.HomeSummary and Management.Home: restoring/1 draws the   *)
(*    restore running, with nothing to press, while its request stands    *)
(*    beside its running job (restore_running?/1, Home's restoring?/2);   *)
(*    elsewhere a silent server offers Restore here (restore_offer/1) on  *)
(*    the computer the home moved from.                                   *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - the other steps of home.act (Move back, Move now, Cancel, the review *)
(*    of what a computer keeps on for its server, adding a computer and    *)
(*    the owner's answer to one that asks to join, and the rest): one act  *)
(*    each through the same serializer and key rule, with no job of the    *)
(*    family (home_return models the move back's);                         *)
(*  - a computer that joined the home (no moved marker), which is offered  *)
(*    neither Move back nor Restore here, and one whose Fermix cannot read *)
(*    the server's home, which is offered Update in their place            *)
(*    (readable_or_update/2): neither has the press this scene starts      *)
(*    with;                                                                *)
(*  - the run itself (LocalReturn.restore/3), its candidate, which draws  *)
(*    moving once written, and the restart its success ends in: all       *)
(*    home_return's;                                                       *)
(*  - an engine that stops while the job runs: it leaves the request      *)
(*    beside no job, which the summary draws as nothing (home_return,     *)
(*    RequestBesideJob);                                                   *)
(*  - an ending that cannot write return.json (it logs), one that raises, *)
(*    or one that outlives its bound and is killed (kill_ending): the     *)
(*    request then stands beside no job, as above;                        *)
(*  - the copy's choice and the passphrase, read before anything is       *)
(*    written (LocalReturn.choose/2), and an act past its deadline;       *)
(*  - the summary's words and keys beyond which actions it offers: a key  *)
(*    is modelled as the set of actions the screen was drawn with.       *)
(*                                                                         *)
(* One step = one callback of the serializer between two calls it makes,  *)
(* one write of return.json, one call of the job family, a run's answer,  *)
(* or one step of a job's ending.                                          *)
(***************************************************************************)

\* SOURCE: apps/fermix_core/lib/fermix_core/management/always_on.ex @ 013c9c46254f
\* SOURCE: apps/fermix_core/lib/fermix_core/management/jobs.ex#start,handle_call,start_job,running?,running_count,complete_task,task_down,finish,begin_ending,ending_done,ending_down,end_closing @ 0061e7895996
\* SOURCE: apps/fermix_core/lib/fermix_core/management/home_summary.ex#offered,find_action,device,restoring,restore_running?,restore_offer,readable_or_update @ ff0a67460be1
\* SOURCE: apps/fermix_core/lib/fermix_core/management/home.ex#restoring? @ 10524f88be3d

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Callers,          \* the surfaces pressing at once, e.g. {c1, c2}
    MaxActs,          \* the presses each surface makes (a bound)
    \* Environment switches: what may happen.
    RunCanCrash,      \* a run raises, exits or is killed before it answers
    \* Mechanism switches: TRUE is the code.
    Serialized,       \* acts run one at a time in the AlwaysOn process
                      \* (act/2's GenServer.call, handle_call); FALSE
                      \* interleaves two acts' steps
    KeyRule,          \* the act runs only an action the summary offers now
                      \* (run, offered: find_action/3); FALSE runs what
                      \* the surface drew
    JobsBusy,         \* the family refuses a start beside a running job of
                      \* the kind (Jobs' handle_call {:start, ...},
                      \* running?/3), a job in its ending included
    UnstartedClears,  \* a start refused busy takes the request back
                      \* (start_restore/3's :busy, request_done/1)
    ClearOnEnd,       \* the job's ending takes the request back
                      \* (start_restore/3's :ending, request_done/1)
    OwnerEnds         \* the job family runs the ending however the run
                      \* ended (Jobs' :ending, task_down/3, finish/4): a run
                      \* that crashed, exited or was killed is ended too;
                      \* FALSE ends only a run that answered, as a
                      \* task-local after would

Pcs == {"idle", "drawn", "queued", "check", "request", "start", "unstart", "done"}
Slots == 1..(Cardinality(Callers) * MaxActs)
JobStates == {"none", "run", "ending", "closing"}
Symm == Permutations(Callers)

VARIABLES
    \* device/return.json
    request,        \* restore_requested stands
    \* the job family (Management.Jobs): each home_restore job a start made
    jobs,           \* each slot's job: "none" (never started, or closed),
                    \* "run" (its run alive), "ending" (the run is over, its
                    \* ending not yet written), "closing" (written, the job
                    \* still running until the ending is done)
    \* the surfaces and the serializer
    pc,             \* each surface's press, in the act's steps
    drawn,          \* the actions the surface's screen offered (its key)
    acts,           \* presses made
    holder,         \* the surface whose act the serializer runs, "none"
    \* history, for the witnesses
    changedSeen,    \* an act was answered changed
    busySeen,       \* a start was refused busy
    crashed         \* a run crashed

job_vars == <<request, jobs>>
caller_vars == <<pc, drawn, acts, holder>>
hist_vars == <<changedSeen, busySeen, crashed>>
vars == <<job_vars, caller_vars, hist_vars>>

TypeOK ==
    /\ request \in BOOLEAN
    /\ jobs \in [Slots -> JobStates]
    /\ pc \in [Callers -> Pcs] /\ drawn \in [Callers -> SUBSET {"restore_here"}]
    /\ acts \in [Callers -> 0..MaxActs] /\ holder \in Callers \cup {"none"}
    /\ changedSeen \in BOOLEAN /\ busySeen \in BOOLEAN /\ crashed \in BOOLEAN

Init ==
    /\ request = FALSE /\ jobs = [j \in Slots |-> "none"]
    /\ pc = [c \in Callers |-> "idle"] /\ drawn = [c \in Callers |-> {}]
    /\ acts = [c \in Callers |-> 0] /\ holder = "none"
    /\ changedSeen = FALSE /\ busySeen = FALSE /\ crashed = FALSE

\* The family counts the job running from its start until its ending is
\* done (finish/4: "A job with an ending stays running until its ending is
\* done").
Running == {j \in Slots : jobs[j] # "none"}

\* What the desktop's summary offers (device/1, :617-618): restoring/1 draws
\* the restore running, with nothing to press, while the request stands
\* beside a running job (restore_running?/1, :909-910; Home's restoring?/2,
\* home.ex:263-272, reads the family); otherwise the silent server's screen
\* offers Restore here (restore_offer/1, :914-927) on the computer the home
\* moved from.
Offered == IF request /\ Running # {} THEN {} ELSE {"restore_here"}

Goto(c, p) == pc' = [pc EXCEPT ![c] = p]

-----------------------------------------------------------------------------
(* The surfaces and the serializer: AlwaysOn.act/2                         *)

\* The surface draws the summary (home.status): its key is what it offers.
Draw(c) ==
    /\ pc[c] = "idle" /\ acts[c] < MaxActs
    /\ Goto(c, "drawn")
    /\ drawn' = [drawn EXCEPT ![c] = Offered]
    /\ UNCHANGED <<job_vars, acts, holder, hist_vars>>

\* The owner presses nothing on this screen.
Leave(c) ==
    /\ pc[c] = "drawn"
    /\ Goto(c, "idle")
    /\ acts' = [acts EXCEPT ![c] = acts[c] + 1]
    /\ UNCHANGED <<job_vars, drawn, holder, hist_vars>>

\* The owner presses Restore here on a screen that offered it, and confirms:
\* home.act {action, key}.
Press(c) ==
    /\ pc[c] = "drawn" /\ "restore_here" \in drawn[c]
    /\ Goto(c, "queued")
    /\ UNCHANGED <<job_vars, drawn, acts, holder, hist_vars>>

\* The serializer takes the act (act/2, always_on.ex:274-282, handle_call,
\* :287-289): one at a time.
Take(c) ==
    /\ pc[c] = "queued"
    /\ Serialized => holder = "none"
    /\ holder' = IF Serialized THEN c ELSE holder
    /\ Goto(c, "check")
    /\ UNCHANGED <<job_vars, drawn, acts, hist_vars>>

\* run/3 and offered/4 (:293-319): the summary as it is now, and the key
\* rule; then restore_here/3 (:826-835), whose copy is chosen first (a read).
Check(c) ==
    /\ pc[c] = "check"
    /\ IF KeyRule /\ "restore_here" \notin Offered
          THEN Goto(c, "done") /\ changedSeen' = TRUE
          ELSE Goto(c, "request") /\ UNCHANGED changedSeen
    /\ UNCHANGED <<job_vars, drawn, acts, holder, busySeen, crashed>>

\* keep_record/2 of restore_record/3 (:846-849, :758-763): the request in
\* return.json, before the job.
Request(c) ==
    /\ pc[c] = "request"
    /\ Goto(c, "start")
    /\ request' = TRUE
    /\ UNCHANGED <<jobs, drawn, acts, holder, hist_vars>>

\* start_restore/3 (:859-874): Jobs.start/2, refused busy beside a running
\* job of the kind (jobs.ex:237-245); else the job runs, its ending kept.
Start(c) ==
    /\ pc[c] = "start"
    /\ IF JobsBusy /\ Running # {}
          THEN /\ Goto(c, "unstart") /\ busySeen' = TRUE
               /\ UNCHANGED jobs
          ELSE /\ Goto(c, "done")
               /\ LET j == CHOOSE free \in Slots : jobs[free] = "none"
                  IN jobs' = [jobs EXCEPT ![j] = "run"]
               /\ UNCHANGED busySeen
    /\ UNCHANGED <<request, drawn, acts, holder, changedSeen, crashed>>

\* The refused start takes the request back (request_done/1, always_on.ex:917-925); the
\* refusal names a restore only when one runs (busy_with/1, :878-882).
Unstart(c) ==
    /\ pc[c] = "unstart"
    /\ Goto(c, "done")
    /\ request' = IF UnstartedClears THEN FALSE ELSE request
    /\ UNCHANGED <<jobs, drawn, acts, holder, hist_vars>>

\* The act answers; the serializer takes the next one.
Finish(c) ==
    /\ pc[c] = "done"
    /\ Goto(c, "idle")
    /\ acts' = [acts EXCEPT ![c] = acts[c] + 1]
    /\ holder' = IF holder = c THEN "none" ELSE holder
    /\ UNCHANGED <<job_vars, drawn, hist_vars>>

-----------------------------------------------------------------------------
(* The job: its run and its ending (Management.Jobs)                       *)

\* The run answers (complete_task/3, jobs.ex:491-501): a restore, or a
\* refusal; finish/4 (:538-544) starts its ending (begin_ending/4,
\* :546-553), the job still running.
RunAnswers(j) ==
    /\ jobs[j] = "run"
    /\ jobs' = [jobs EXCEPT ![j] = "ending"]
    /\ UNCHANGED <<request, caller_vars, hist_vars>>

\* The run raises, exits or is killed (task_down/3, :503-513). With
\* OwnerEnds the family ends it as any other (finish/4); without, the job
\* closes with no ending.
RunCrashes(j) ==
    /\ RunCanCrash /\ jobs[j] = "run"
    /\ jobs' = [jobs EXCEPT ![j] = IF OwnerEnds THEN "ending" ELSE "none"]
    /\ crashed' = TRUE
    /\ UNCHANGED <<request, caller_vars, changedSeen, busySeen>>

\* The ending (restore_ended/3, always_on.ex:891-915) takes the request back
\* (request_done/1, :917-925), which tells the watch, then settles a local
\* candidate a run stopped from outside left (home_return's RhSettle: no
\* request here); the job still runs until the family hears the ending is
\* done.
EndingWrites(j) ==
    /\ jobs[j] = "ending"
    /\ jobs' = [jobs EXCEPT ![j] = "closing"]
    /\ request' = IF ClearOnEnd THEN FALSE ELSE request
    /\ UNCHANGED <<caller_vars, hist_vars>>

\* ending_done/2 or ending_down/3, then end_closing/2 (jobs.ex:555-584): the
\* job leaves running.
Close(j) ==
    /\ jobs[j] = "closing"
    /\ jobs' = [jobs EXCEPT ![j] = "none"]
    /\ UNCHANGED <<request, caller_vars, hist_vars>>

-----------------------------------------------------------------------------

\* Every surface made its presses and every job closed.
Done ==
    /\ \A c \in Callers : pc[c] = "idle" /\ acts[c] = MaxActs
    /\ Running = {}

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E c \in Callers :
          \/ Draw(c) \/ Leave(c) \/ Press(c) \/ Take(c) \/ Check(c) \/ Request(c)
          \/ Start(c) \/ Unstart(c) \/ Finish(c)
    \/ \E j \in Slots : RunAnswers(j) \/ RunCrashes(j) \/ EndingWrites(j) \/ Close(j)
    \/ Terminated

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* "One job of the kind runs at a time (`busy` otherwise)" (Management.Jobs):
\* at most one Restore here job counts running, its ending included.
AtMostOneJob == Cardinality(Running) <= 1

\* "its ending, however the run ended, takes the request back ... A start
\* refused takes it back too" (start_restore/3): the request stands only
\* while its job runs, or while its act is between the request and the
\* start's answer.
RequestMeansRestore ==
    request => (Running # {} \/ \E c \in Callers : pc[c] \in {"start", "unstart"})

\* "while it runs beside the request the summary says it runs, from the
\* press on" (start_restore/3): while a run lives, its request stands.
RestoreMeansRequest == (\E j \in Slots : jobs[j] = "run") => request

\* Witnesses: each defined as "the scenario never happens".
Witness_Changed == ~changedSeen
Witness_BusyRefused == ~busySeen
Witness_CrashEnded == ~(crashed /\ ~request /\ Running = {})

=============================================================================
