---------------------------- MODULE AlwaysOnAct ----------------------------
(***************************************************************************)
(* Always On's steps (Always On setup §3.4, §4, §5): every step a surface  *)
(* asks for is one `home.act`, which `Management.AlwaysOn.act/2` runs in   *)
(* one serializer per engine. It reads the summary first and runs the     *)
(* step only when the summary offers that action under the key it was     *)
(* drawn with (HomeSummary.find_action/3); a step that starts a job names *)
(* it in the provisioner's ledger first (Provision.put_action/2).         *)
(*                                                                         *)
(* The scene is a linked desktop replacing the server Fermix created,     *)
(* the one place every rule meets: two surfaces press at once, the job    *)
(* family's run writes the same ledger, a home.status read starts the     *)
(* family's reconcile, the act sends Move now to the old server over the  *)
(* link, and the desktop relay reports the epoch it reaches, after which  *)
(* the old server is deleted (Provision.primary_reached/2).               *)
(*                                                                         *)
(* What it describes:                                                      *)
(*  - Management.AlwaysOn (always_on.ex): act/2 hands the request to the  *)
(*    serializer (handle_call); run reads the summary and checks the key  *)
(*    (offered); job writes the step's name, then starts its job, and     *)
(*    unstarted clears the name when the start is refused; cancel during  *)
(*    a create stops the job (Provision.stop_step/1), clears the name and *)
(*    starts the delete when something stands (Provision.holding/1);      *)
(*    forwarded_move sends home.move.start and keeps the replace's move   *)
(*    (Provision.move_forwarded/3).                                       *)
(*  - Management.Provision: put_action, clear_action, holding, stop_step, *)
(*    start (the family's one job wrapper) and step (a step's job ends by *)
(*    clearing its name, end_step), delete, move_forwarded with started?  *)
(*    and record_move, primary_reached with reached and run_clean_up.     *)
(*  - Home.Provision.Ledger: put_action (refused while a live step's name *)
(*    stands), clear_action, move_started, replace_due and moved.        *)
(*  - Management.Jobs: one running job per kind and name (running?), and  *)
(*    cancel, which answers after the run's :DOWN (cancel_job, stop_job,  *)
(*    task_down).                                                          *)
(*  - Management.HomeSummary: the actions a desktop's summary offers      *)
(*    during a replace (Offered below: running, running_step,            *)
(*    replace_moving, new_server_step) and find_action.                   *)
(*                                                                         *)
(* The old server (its move_start, its move) and the desktop relay        *)
(* (Desktop.Relay, which calls primary_reached/2 at each session's        *)
(* epoch) are UNPINNED MIRRORS: the old server takes a forwarded          *)
(* home.move.start and moves, serving nothing meanwhile, and the new one  *)
(* answers at a higher epoch once the move is done.                       *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - the server being created on the primary rather than replaced: the   *)
(*    same act, job, cancel and ledger, with no link (always_on_test);    *)
(*  - Start again, Create in, Turn it on and Restart server: one job each, *)
(*    started as `job` starts the create and the delete (always_on_test); *)
(*  - Provision.delete's own refusal while a move runs (delete_target),   *)
(*    a second guard behind the key rule, single-call (provision_test);   *)
(*  - a step's name outliving its job's budget, read as interrupted, and  *)
(*    the boot's interrupt_left_actions/1 (ledger_test, provision_test);  *)
(*  - the old server undoing the move, and a failed delete of it;         *)
(*  - the summary's words and keys beyond which actions it offers: a key  *)
(*    is modelled as the set of actions the screen was drawn with.       *)
(*                                                                         *)
(* One step = one callback of the serializer between two calls it makes,  *)
(* one write of the ledger, one call of the job family, one write of a    *)
(* run, one answer over the link, or one report of the relay.            *)
(***************************************************************************)

\* SOURCE: apps/fermix_core/lib/fermix_core/management/always_on.ex @ b8861ebfbb8b
\* SOURCE: apps/fermix_core/lib/fermix_core/management/provision.ex#put_action,clear_action,holding,stop_step,start,step,end_step,delete,move_forwarded,started?,record_move,primary_reached,reached,run_clean_up @ 309735f51667
\* SOURCE: apps/fermix_core/lib/fermix_core/home/provision/ledger.ex#put_action,clear_action,live_action?,move_started,replace_due,moving?,moved @ f562176b8bc8
\* SOURCE: apps/fermix_core/lib/fermix_core/management/jobs.ex#start,cancel,handle_call,start_job,cancel_job,stop_job,task_down,running? @ 7489b0734b3d
\* SOURCE: apps/fermix_core/lib/fermix_core/management/home_summary.ex#find_action,running,running_step,replace_moving,new_server_step @ 95a2bc971e65

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Callers,          \* the surfaces pressing at once, e.g. {c1, c2}
    MaxActs,          \* the presses each surface makes (a bound)
    MaxReports,       \* the epochs the relay reports (a bound)
    MaxReads,         \* the reconciles home.status reads start (a bound)
    \* Environment switches: what may happen.
    StepCanFail,      \* the provider refuses a create or a delete
    AnswerCanBeLost,  \* the old server had the move's start and its answer was lost
    LinkCanDrop,      \* the link is down: the old server never had the request
    ReadsReconcile,   \* a home.status read starts the family's reconcile
    \* Mechanism switches: TRUE is the code.
    Serialized,       \* acts run one at a time in the AlwaysOn process
                      \* (act/2's GenServer.call, handle_call); FALSE
                      \* interleaves two acts' steps
    KeyRule,          \* the act runs only an action the summary offers now
                      \* (run, offered: find_action/3); FALSE runs what
                      \* the surface drew
    JobsBusy,         \* the family runs one job at a time (Jobs.running?/3
                      \* in handle_call {:start, ...})
    UnstartedClears,  \* a start refused after the name was written clears
                      \* it (AlwaysOn.unstarted, Provision.clear_action/1)
    ClearOnEnd,       \* a step's job ends by clearing the name (Provision
                      \* step/4 :clears_action, end_step)
    KeepFailure,      \* a step that stopped keeps its failure in the ledger
                      \* (Provision.step_failed, remembered)
    CancelWaits,      \* Jobs.cancel/2 answers after the run's :DOWN, and the
                      \* job counts as running until then (cancel_job,
                      \* task_down); FALSE closes it at once
    RecordOnAnswer,   \* the replace's move is kept only once the old server
                      \* had it, started or unconfirmed (move_forwarded,
                      \* started?); FALSE keeps it whatever the answer
    EpochGuard        \* the old server is cleaned up only for an epoch above
                      \* its own (Ledger.replace_due/2 and moved/3); FALSE
                      \* takes any epoch the relay reaches

Kinds == {"create", "delete", "reconcile", "cleanup"}
Actions == {"replace", "cancel", "move_now", "delete"}
Answers == {"none", "started", "lost", "unreachable", "refused"}
Pcs == {"idle", "drawn", "queued", "check", "put", "start", "unstart", "cancel_job",
        "cancel_wait", "cancel_clear", "cancel_holding", "forward", "record", "done"}
Symm == Permutations(Callers)

VARIABLES
    \* the desktop's ledger (Home.Provision.Ledger)
    action,         \* "none" | "create" | "delete": the step whose job runs
    server,         \* "none" | "requested" | "created": the new server
    failure,        \* the last step's failure is kept
    old,            \* "standing" | "deleted": the server the home lives on
    moveStarted,    \* the replace's move is kept started (move_started_at)
    moved,          \* the move is done: moved_at
    records,        \* times the move's start was kept
    \* the job family (Management.Jobs)
    jobs,           \* the kinds it counts running
    tasks,          \* the kinds whose run is alive
    killed,         \* the kinds whose run was told to stop
    phase,          \* each kind's run: "p1" | "p2" | "end", "idle" when none
    \* the old server, the relay and the reads (mirrors)
    srv,            \* "waiting" | "moving" | "done": the move, as the old server holds it
    newer,          \* the relay reached a primary above the old server's epoch
    reports,        \* reports the relay made
    reads,          \* reconciles reads started
    \* the surfaces and the serializer
    pc,             \* each surface's press, in the act's steps
    drawn,          \* the actions the surface's screen offered (its key)
    want,           \* the action pressed
    kind,           \* the step's job the act starts
    ans,            \* the old server's answer to the forwarded move
    acts,           \* presses made
    holder,         \* the surface whose act the serializer runs, "none"
    \* history, for the properties
    deletedTarget,  \* a delete removed the server a move was going to
    lostEnding,     \* a step's run ended with no server change and no failure kept
    recordedUngot,  \* the move was kept while the old server never had it
    changedSeen     \* an act was answered changed

ledger_vars == <<action, server, failure, old, moveStarted, moved, records>>
job_vars == <<jobs, tasks, killed, phase>>
world_vars == <<srv, newer, reports, reads>>
caller_vars == <<pc, drawn, want, kind, ans, acts, holder>>
hist_vars == <<deletedTarget, lostEnding, recordedUngot, changedSeen>>
vars == <<ledger_vars, job_vars, world_vars, caller_vars, hist_vars>>

TypeOK ==
    /\ action \in {"none", "create", "delete"}
    /\ server \in {"none", "requested", "created"}
    /\ failure \in BOOLEAN /\ old \in {"standing", "deleted"}
    /\ moveStarted \in BOOLEAN /\ moved \in BOOLEAN /\ records \in Nat
    /\ jobs \subseteq Kinds /\ tasks \subseteq Kinds /\ killed \subseteq Kinds
    /\ phase \in [Kinds -> {"idle", "p1", "p2", "end"}]
    /\ srv \in {"waiting", "moving", "done"} /\ newer \in BOOLEAN
    /\ reports \in 0..MaxReports /\ reads \in 0..MaxReads
    /\ pc \in [Callers -> Pcs] /\ drawn \in [Callers -> SUBSET Actions]
    /\ want \in [Callers -> Actions \cup {"none"}]
    /\ kind \in [Callers -> {"none", "create", "delete"}]
    /\ ans \in [Callers -> Answers] /\ acts \in [Callers -> 0..MaxActs]
    /\ holder \in Callers \cup {"none"}
    /\ deletedTarget \in BOOLEAN /\ lostEnding \in BOOLEAN
    /\ recordedUngot \in BOOLEAN /\ changedSeen \in BOOLEAN

Init ==
    /\ action = "none" /\ server = "none" /\ failure = FALSE /\ old = "standing"
    /\ moveStarted = FALSE /\ moved = FALSE /\ records = 0
    /\ jobs = {} /\ tasks = {} /\ killed = {} /\ phase = [k \in Kinds |-> "idle"]
    /\ srv = "waiting" /\ newer = FALSE /\ reports = 0 /\ reads = 0
    /\ pc = [c \in Callers |-> "idle"] /\ drawn = [c \in Callers |-> {}]
    /\ want = [c \in Callers |-> "none"] /\ kind = [c \in Callers |-> "none"]
    /\ ans = [c \in Callers |-> "none"] /\ acts = [c \in Callers |-> 0]
    /\ holder = "none"
    /\ deletedTarget = FALSE /\ lostEnding = FALSE /\ recordedUngot = FALSE
    /\ changedSeen = FALSE

\* The actions a linked desktop's summary offers during a replace
\* (HomeSummary: running and running_step while a step's name stands,
\* replace_moving once the move is kept, new_server_step and the ready view
\* while the new server sets up and waits, the problem's Delete): Replace
\* the server from `on`; Cancel while the create runs or the new server
\* stands before the move; Move now when it is ready; Delete after a step
\* failed with the new server standing. Nothing while the move runs, and
\* once it is done the new server is the one the home lives on (the
\* replace's state `done`, read as `on`), whose own actions are no part
\* of this spec.
Replacing == ~moveStarted /\ ~moved /\ old = "standing"

Offered ==
    (IF action = "none" /\ server = "none" /\ ~failure /\ Replacing
        THEN {"replace"} ELSE {})
    \cup (IF action = "create" \/ (action = "none" /\ server # "none" /\ ~failure /\ Replacing)
            THEN {"cancel"} ELSE {})
    \cup (IF action = "none" /\ server = "created" /\ ~failure /\ Replacing /\ srv = "waiting"
            THEN {"move_now"} ELSE {})
    \cup (IF action = "none" /\ server # "none" /\ failure /\ Replacing
            THEN {"delete"} ELSE {})

\* Where the move is going: the new server, once the old server had its start.
MoveTarget == srv \in {"moving", "done"}

Goto(c, p) == pc' = [pc EXCEPT ![c] = p]

-----------------------------------------------------------------------------
(* The surfaces and the serializer: AlwaysOn.act/2                         *)

\* The surface draws the summary (home.status): its key is what it offers.
Draw(c) ==
    /\ pc[c] = "idle" /\ acts[c] < MaxActs
    /\ Goto(c, "drawn")
    /\ drawn' = [drawn EXCEPT ![c] = Offered]
    /\ UNCHANGED <<ledger_vars, job_vars, world_vars, want, kind, ans, acts, holder, hist_vars>>

\* The owner presses nothing on this screen.
Leave(c) ==
    /\ pc[c] = "drawn"
    /\ Goto(c, "idle")
    /\ acts' = [acts EXCEPT ![c] = acts[c] + 1]
    /\ UNCHANGED <<ledger_vars, job_vars, world_vars, drawn, want, kind, ans, holder, hist_vars>>

\* The owner presses an action the screen offered: home.act {action, key}.
Press(c, a) ==
    /\ pc[c] = "drawn" /\ a \in drawn[c]
    /\ Goto(c, "queued")
    /\ want' = [want EXCEPT ![c] = a]
    /\ UNCHANGED <<ledger_vars, job_vars, world_vars, drawn, kind, ans, acts, holder, hist_vars>>

\* The serializer takes the act (handle_call): one at a time.
Take(c) ==
    /\ pc[c] = "queued"
    /\ Serialized => holder = "none"
    /\ holder' = IF Serialized THEN c ELSE holder
    /\ Goto(c, "check")
    /\ UNCHANGED <<ledger_vars, job_vars, world_vars, drawn, want, kind, ans, acts, hist_vars>>

\* run/offered: the summary as it is now, and the key rule; then the step
\* by what the screen showed (step/3; cancel/2 by the step that runs).
Check(c) ==
    /\ pc[c] = "check"
    /\ IF KeyRule /\ want[c] \notin Offered
          THEN /\ Goto(c, "done")
               /\ changedSeen' = TRUE
               /\ UNCHANGED kind
          ELSE /\ changedSeen' = changedSeen
               /\ CASE want[c] = "replace" ->
                         Goto(c, "put") /\ kind' = [kind EXCEPT ![c] = "create"]
                    [] want[c] = "cancel" /\ action = "create" ->
                         Goto(c, "cancel_job") /\ UNCHANGED kind
                    [] want[c] \in {"cancel", "delete"} ->
                         Goto(c, "put") /\ kind' = [kind EXCEPT ![c] = "delete"]
                    [] want[c] = "move_now" ->
                         Goto(c, "forward") /\ UNCHANGED kind
    /\ UNCHANGED <<ledger_vars, job_vars, world_vars, drawn, want, ans, acts, holder,
                   deletedTarget, lostEnding, recordedUngot>>

\* job/3: the step's name first (Provision.put_action/2, under the ledger's
\* lock), refused while another stands (Ledger.put_action/3).
Put(c) ==
    /\ pc[c] = "put"
    /\ IF action # "none"
          THEN Goto(c, "done") /\ UNCHANGED action
          ELSE Goto(c, "start") /\ action' = kind[c]
    /\ UNCHANGED <<server, failure, old, moveStarted, moved, records, job_vars, world_vars,
                   drawn, want, kind, ans, acts, holder, hist_vars>>

\* Then its job (Provision.start/4, Jobs.start/2), refused busy beside
\* another run of the family.
Start(c) ==
    /\ pc[c] = "start"
    /\ IF JobsBusy /\ jobs # {}
          THEN Goto(c, "unstart") /\ UNCHANGED job_vars
          ELSE /\ Goto(c, "done")
               /\ jobs' = jobs \cup {kind[c]} /\ tasks' = tasks \cup {kind[c]}
               /\ phase' = [phase EXCEPT ![kind[c]] = "p1"]
               /\ UNCHANGED killed
    /\ UNCHANGED <<ledger_vars, world_vars, drawn, want, kind, ans, acts, holder, hist_vars>>

\* unstarted/2: the refused start leaves no step behind.
Unstart(c) ==
    /\ pc[c] = "unstart"
    /\ Goto(c, "done")
    /\ action' = IF UnstartedClears THEN "none" ELSE action
    /\ UNCHANGED <<server, failure, old, moveStarted, moved, records, job_vars, world_vars,
                   drawn, want, kind, ans, acts, holder, hist_vars>>

\* cancel/2 while a create runs: Provision.stop_step/1 cancels the family's
\* running job; Jobs.cancel/2 tells its run to stop and, with CancelWaits,
\* answers only after the run's :DOWN, the job still counted running.
CancelJob(c) ==
    /\ pc[c] = "cancel_job"
    /\ Goto(c, "cancel_wait")
    /\ killed' = killed \cup (jobs \cap tasks)
    /\ jobs' = IF CancelWaits THEN jobs ELSE {}
    /\ UNCHANGED <<ledger_vars, tasks, phase, world_vars, drawn, want, kind, ans, acts,
                   holder, hist_vars>>

CancelWait(c) ==
    /\ pc[c] = "cancel_wait"
    /\ CancelWaits => tasks \cap killed = {}
    /\ Goto(c, "cancel_clear")
    /\ UNCHANGED <<ledger_vars, job_vars, world_vars, drawn, want, kind, ans, acts, holder,
                   hist_vars>>

\* A cancelled run ends with no clear of its own, so the act clears it.
CancelClear(c) ==
    /\ pc[c] = "cancel_clear"
    /\ Goto(c, "cancel_holding")
    /\ action' = "none"
    /\ UNCHANGED <<server, failure, old, moveStarted, moved, records, job_vars, world_vars,
                   drawn, want, kind, ans, acts, holder, hist_vars>>

\* What the create made is deleted (Provision.holding/1), else nothing.
CancelHolding(c) ==
    /\ pc[c] = "cancel_holding"
    /\ IF server # "none"
          THEN Goto(c, "put") /\ kind' = [kind EXCEPT ![c] = "delete"]
          ELSE Goto(c, "done") /\ UNCHANGED kind
    /\ UNCHANGED <<ledger_vars, job_vars, world_vars, drawn, want, ans, acts, holder, hist_vars>>

\* forwarded_move/4: home.move.start to the old server over the link. It
\* had it and answered; or had it and the answer was lost (unconfirmed); or
\* never had it (the link down). While it moves it serves nothing, and
\* once the move is done the new server holds no such candidate.
ForwardAnswers ==
    CASE srv = "waiting" ->
           {"started"} \cup (IF AnswerCanBeLost THEN {"lost"} ELSE {})
                       \cup (IF LinkCanDrop THEN {"unreachable"} ELSE {})
      [] srv = "moving" ->
           {"refused"} \cup (IF AnswerCanBeLost THEN {"lost"} ELSE {})
                       \cup (IF LinkCanDrop THEN {"unreachable"} ELSE {})
      [] srv = "done" -> {"refused"}

Forward(c) ==
    /\ pc[c] = "forward"
    /\ \E a \in ForwardAnswers :
          /\ ans' = [ans EXCEPT ![c] = a]
          /\ srv' = IF srv = "waiting" /\ a \in {"started", "lost"} THEN "moving" ELSE srv
    /\ Goto(c, "record")
    /\ UNCHANGED <<ledger_vars, job_vars, newer, reports, reads, drawn, want, kind, acts,
                   holder, hist_vars>>

\* Provision.move_forwarded/3: kept when the old server had it (started?),
\* while a replace waits for its move (Ledger.move_started/3).
Record(c) ==
    /\ pc[c] = "record"
    /\ LET keep == (IF RecordOnAnswer THEN ans[c] \in {"started", "lost"} ELSE TRUE)
                   /\ old = "standing" /\ ~moved
       IN /\ moveStarted' = (moveStarted \/ keep)
          /\ records' = IF keep THEN records + 1 ELSE records
          /\ recordedUngot' = (recordedUngot \/ (keep /\ srv = "waiting"))
    /\ Goto(c, "done")
    /\ UNCHANGED <<action, server, failure, old, moved, job_vars, world_vars, drawn, want, kind,
                   ans, acts, holder, deletedTarget, lostEnding, changedSeen>>

\* The act answers; the serializer takes the next one.
Finish(c) ==
    /\ pc[c] = "done"
    /\ Goto(c, "idle")
    /\ acts' = [acts EXCEPT ![c] = acts[c] + 1]
    /\ holder' = IF holder = c THEN "none" ELSE holder
    /\ UNCHANGED <<ledger_vars, job_vars, world_vars, drawn, want, kind, ans, hist_vars>>

-----------------------------------------------------------------------------
(* The family's runs: Provision.start/4 and the Driver's writes            *)

\* A run told to stop may still take the step it is in until it dies
\* (RunDies): the hazard CancelWaits closes.

\* The create's first write: the new server asked for (Driver.create).
CreateWrites ==
    /\ "create" \in tasks /\ phase["create"] = "p1"
    /\ server' = IF server = "none" THEN "requested" ELSE server
    /\ phase' = [phase EXCEPT !["create"] = "p2"]
    /\ UNCHANGED <<action, failure, old, moveStarted, moved, records, jobs, tasks, killed,
                   world_vars, caller_vars, hist_vars>>

\* The provider answers: the server created, or the create refused, kept
\* in the ledger as its failure (remembered/4).
CreateAnswered ==
    /\ "create" \in tasks /\ phase["create"] = "p2"
    /\ \/ server' = "created" /\ UNCHANGED <<failure, lostEnding>>
       \/ /\ StepCanFail
          /\ server' = "none" /\ failure' = KeepFailure
          /\ lostEnding' = (lostEnding \/ ~KeepFailure)
    /\ phase' = [phase EXCEPT !["create"] = "end"]
    /\ UNCHANGED <<action, old, moveStarted, moved, records, jobs, tasks, killed, world_vars,
                   caller_vars, deletedTarget, recordedUngot, changedSeen>>

\* The delete (Driver.delete): the new server goes, or the delete stops and
\* is kept as its failure (step_failed/4).
DeleteAnswered ==
    /\ "delete" \in tasks /\ phase["delete"] = "p1"
    /\ \/ /\ server' = "none" /\ failure' = FALSE
          /\ deletedTarget' = (deletedTarget \/ (server # "none" /\ MoveTarget))
          /\ UNCHANGED lostEnding
       \/ /\ StepCanFail /\ server # "none"
          /\ failure' = KeepFailure /\ UNCHANGED <<server, deletedTarget>>
          /\ lostEnding' = (lostEnding \/ ~KeepFailure)
    /\ phase' = [phase EXCEPT !["delete"] = "end"]
    /\ UNCHANGED <<action, old, moveStarted, moved, records, jobs, tasks, killed, world_vars,
                   caller_vars, recordedUngot, changedSeen>>

\* A step's run ends: its name cleared (step/4's end_step), its task gone
\* and its job closed (:DOWN).
StepEnds(k) ==
    /\ k \in {"create", "delete"} /\ k \in tasks /\ phase[k] = "end"
    /\ action' = IF ClearOnEnd THEN "none" ELSE action
    /\ tasks' = tasks \ {k} /\ jobs' = jobs \ {k} /\ killed' = killed \ {k}
    /\ phase' = [phase EXCEPT ![k] = "idle"]
    /\ UNCHANGED <<server, failure, old, moveStarted, moved, records, world_vars, caller_vars,
                   hist_vars>>

\* A run told to stop dies with no end of its own (no end_step), and the
\* family takes its :DOWN.
RunDies(k) ==
    /\ k \in tasks \cap killed
    /\ tasks' = tasks \ {k} /\ jobs' = jobs \ {k} /\ killed' = killed \ {k}
    /\ phase' = [phase EXCEPT ![k] = "idle"]
    /\ UNCHANGED <<ledger_vars, world_vars, caller_vars, hist_vars>>

\* A home.status read whose summary rests on the provider starts one
\* reconcile (Management.Home.refresh_provider), refused busy beside a run.
ReadStartsReconcile ==
    /\ ReadsReconcile /\ reads < MaxReads
    /\ reads' = reads + 1
    /\ IF JobsBusy /\ jobs # {}
          THEN UNCHANGED <<jobs, tasks, phase>>
          ELSE /\ jobs' = jobs \cup {"reconcile"} /\ tasks' = tasks \cup {"reconcile"}
               /\ phase' = [phase EXCEPT !["reconcile"] = "end"]
    /\ UNCHANGED <<ledger_vars, killed, srv, newer, reports, caller_vars, hist_vars>>

\* A reconcile names no step and clears none.
OtherEnds(k) ==
    /\ k \in {"reconcile"} /\ k \in tasks /\ phase[k] = "end"
    /\ tasks' = tasks \ {k} /\ jobs' = jobs \ {k} /\ killed' = killed \ {k}
    /\ phase' = [phase EXCEPT ![k] = "idle"]
    /\ UNCHANGED <<ledger_vars, world_vars, caller_vars, hist_vars>>

-----------------------------------------------------------------------------
(* The old server and the relay (mirrors), and the clean-up               *)

\* The old server's move ends: the new server is the primary, one epoch up.
MoveDone ==
    /\ srv = "moving"
    /\ srv' = "done"
    /\ UNCHANGED <<ledger_vars, job_vars, newer, reports, reads, caller_vars, hist_vars>>

\* The relay reaches its server: the old one at its own epoch while it
\* serves, the new one at the higher epoch once the move is done (none
\* while the old one moves: it serves nothing). primary_reached/2 cleans
\* up when replace_due/2 says so, as a job of the family, refused busy (the
\* next report tries again).
Report ==
    /\ reports < MaxReports /\ srv \in {"waiting", "done"}
    /\ reports' = reports + 1
    /\ LET higher == srv = "done"
           due == old = "standing" /\ ~moved /\ (EpochGuard => higher)
       IN /\ newer' = (newer \/ higher)
          /\ IF due /\ ~(JobsBusy /\ jobs # {}) /\ "cleanup" \notin tasks
                THEN /\ jobs' = jobs \cup {"cleanup"} /\ tasks' = tasks \cup {"cleanup"}
                     /\ phase' = [phase EXCEPT !["cleanup"] = "p1"]
                ELSE UNCHANGED <<jobs, tasks, phase>>
    /\ UNCHANGED <<ledger_vars, killed, srv, reads, caller_vars, hist_vars>>

\* run_clean_up/4: the move kept done (Ledger.moved/3), then the old server
\* deleted (delete_replaced); it names no step.
CleanUp ==
    /\ "cleanup" \in tasks /\ phase["cleanup"] = "p1"
    /\ moved' = TRUE /\ old' = "deleted"
    /\ phase' = [phase EXCEPT !["cleanup"] = "end"]
    /\ UNCHANGED <<action, server, failure, moveStarted, records, jobs, tasks, killed,
                   world_vars, caller_vars, hist_vars>>

CleanUpEnds ==
    /\ "cleanup" \in tasks /\ phase["cleanup"] = "end"
    /\ tasks' = tasks \ {"cleanup"} /\ jobs' = jobs \ {"cleanup"} /\ killed' = killed \ {"cleanup"}
    /\ phase' = [phase EXCEPT !["cleanup"] = "idle"]
    /\ UNCHANGED <<ledger_vars, world_vars, caller_vars, hist_vars>>

-----------------------------------------------------------------------------

\* Every surface made its presses and every run ended. The old server may
\* still be moving and the relay may have reports left.
Done ==
    /\ \A c \in Callers : pc[c] = "idle" /\ acts[c] = MaxActs
    /\ tasks = {}

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E c \in Callers :
          \/ Draw(c) \/ Leave(c) \/ \E a \in Actions : Press(c, a)
          \/ Take(c) \/ Check(c) \/ Put(c) \/ Start(c) \/ Unstart(c)
          \/ CancelJob(c) \/ CancelWait(c) \/ CancelClear(c) \/ CancelHolding(c)
          \/ Forward(c) \/ Record(c) \/ Finish(c)
    \/ CreateWrites \/ CreateAnswered \/ DeleteAnswered
    \/ \E k \in Kinds : StepEnds(k) \/ RunDies(k) \/ OtherEnds(k)
    \/ ReadStartsReconcile \/ MoveDone \/ Report \/ CleanUp \/ CleanUpEnds
    \/ Terminated

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* "One job of the kind runs at a time (`busy` otherwise)" (Management.
\* Provision moduledoc): at most one run of the family is alive.
AtMostOneRun == Cardinality(tasks) <= 1

\* "the delete never starts while a cancelled run is alive" (Always On
\* setup §10): a create alive beside the delete is one a cancel stopped.
NoDeleteBesideCancelled == ~("delete" \in tasks /\ "create" \in tasks)

\* "act/2 writes the ledger's `action` row itself ... before `Jobs.start`
\* ... the job's end clears it" (Always On setup §3.4, §5): a step's name
\* stands only while its run lives or its act is between the name and the
\* start, or stopping a create.
ActionMeansStep ==
    action # "none" =>
        \/ action \in tasks
        \/ \E c \in Callers : pc[c] \in {"start", "unstart", "cancel_job", "cancel_wait",
                                          "cancel_clear"}

\* "Every ending lands in the ledger" (Always On setup §5): a step that
\* ended changed the server or left its failure.
EndingKept == ~lostEnding

\* "cancel never deletes a server a move is going to" (Always On setup §10).
CancelNeverDeletesMoveTarget == ~deletedTarget

\* "the replace bookkeeping at most once and only after the server
\* answered" (Always On setup §10).
RecordedOnce == records <= 1
RecordedOnlyWhenHad == ~recordedUngot

\* "the old server deleted only after a newer epoch answered" (Always On
\* setup §10).
OldDeletedAfterNewer == old = "deleted" => newer

\* Witnesses: each defined as "the scenario never happens".
Witness_CancelWaitsForRun == ~(\E c \in Callers : pc[c] = "cancel_wait" /\ "create" \in tasks)
Witness_LostAnswerKept == ~(moveStarted /\ \E c \in Callers : ans[c] = "lost")
Witness_Changed == ~changedSeen
Witness_OldDeleted == ~(old = "deleted")

=============================================================================
