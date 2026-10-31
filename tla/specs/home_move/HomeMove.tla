----------------------------- MODULE HomeMove -----------------------------
(***************************************************************************)
(* Moving a home to another host (M75 section 7.2, B5). Three parts:      *)
(*  - the SOURCE: the home that was the primary, restarted in the device  *)
(*    role, and its move worker (FermixChannels.Home.MoveWorker), with    *)
(*    the files it writes: config.toml's role, moved.json and             *)
(*    .move/phase.json;                                                    *)
(*  - the CANDIDATE: the enrolled host that receives the home, stages it  *)
(*    and activates it (FermixChannels.Home.Candidate, its responder      *)
(*    MoveResponder, and Candidate.Activation), with its durable phase;   *)
(*  - the RAIL between them (Mobile.Rail): one rail per dial, request and *)
(*    answer in turn on each, which can lose a message, and can still     *)
(*    deliver a request after the worker gave up on the rail it was sent  *)
(*    on.                                                                  *)
(*                                                                         *)
(* Rails are named from the worker's side. "cur" is the rail it waits on  *)
(* now; "gone" is one it closed (close_rail/1 after a failed wait,        *)
(* with_rail/2 after a resume round) or that died with it. A request sent *)
(* on a closed rail may still arrive (OldRequestsArrive); an answer on it *)
(* reaches no one, except one that reached the worker's mailbox before    *)
(* the close, which await_any/3 never takes from another rail             *)
(* (AwaitPinsRail). Renaming "cur" to "gone" when the worker closes the   *)
(* rail is bookkeeping of which rail is which, not a step of the          *)
(* candidate.                                                              *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - enrollment: the candidate starts enrolled. Its 24-hour listen       *)
(*    window (an expired candidate refuses the offer) is one of the        *)
(*    refusals TransferCanFail stands for;                                 *)
(*  - the stream's frames: move_offer and move_accept, then one "stream"  *)
(*    request for every move_chunk and the move_end. A wrong size or      *)
(*    SHA-256, or a recipient that changed (same_recipient/2), is a       *)
(*    refusal;                                                             *)
(*  - the desktop key, its device row, device/desktop.json, request.json  *)
(*    and the snapshot file: writes no rule reads;                         *)
(*  - the sleep guard the worker holds for its whole run (MoveAwake) and   *)
(*    the staged plugin store's reinstall request (Plugins.Dist.Reinstall, *)
(*    which a failed staging removes with the rest): no rule reads them;   *)
(*  - the 24-hour bound on the resume loop (unconfirmed/2): it records a  *)
(*    sentence and ends the worker until the next boot, which resumes;    *)
(*    no file a rule reads changes, so here the loop runs on;              *)
(*  - a marker write that fails part-way: Moved.write/2 creates the file  *)
(*    exclusively, then writes it, so a failed write or close leaves an   *)
(*    unreadable marker. Here the marker is written whole or not at all;  *)
(*  - an activation that fails inside activate/1 (a rename refused): the  *)
(*    candidate stays in activating, records its sentence and tries again  *)
(*    on a timer (activation_failed/2); a resume meanwhile is refused      *)
(*    (OnResume), as for any candidate still activating;                    *)
(*  - the one capture every attempt sends: a capture failing is an attempt *)
(*    failing (AttemptFails), and reusing it writes nothing a rule reads;  *)
(*  - a second move id: start/5 refuses a home that carries the marker,   *)
(*    and an aborted move never sent move_commit. With one move id, the    *)
(*    fence's {move_id, attempt} order (move ids ordered by when the move  *)
(*    started) is the attempt order;                                       *)
(*  - the probe's own rail: probe_primary/2 succeeds exactly when the     *)
(*    candidate runs as the primary;                                       *)
(*  - the cast put_phase/4 sends the Always On watch (Home.StatusWatch)    *)
(*    once a phase is written: it writes nothing, and no step reads it.    *)
(*                                                                         *)
(* One step = one thing in the code: one file write, one Candidate        *)
(* callback (the responder's frame and the call it makes), one dial, or   *)
(* one wait the worker ends.                                               *)
(***************************************************************************)
\* SOURCE: apps/fermix_channels/lib/fermix_channels/home/move_worker.ex @ 174049035bfe
\* SOURCE: apps/fermix_channels/lib/fermix_channels/home/candidate.ex @ 75587263f63d
\* SOURCE: apps/fermix_channels/lib/fermix_channels/home/move_responder.ex @ 31d80078d517
\* SOURCE: apps/fermix_core/lib/fermix_core/home/candidate/activation.ex @ 65dd08bdd156
\* SOURCE: apps/fermix_core/lib/fermix_core/home/move.ex#start,move_id,write_request,put_phase,pending?,not_pending,max_attempts,@max_attempts,@pending,@running,@phases,finish_at_boot,finish_due,ending,finish,view,remember_unrecorded_ending,boot_ending,@boot_key @ 52918b4a9417
\* SOURCE: apps/fermix_core/lib/fermix_core/home/role.ex#resolve,primary,configured_role @ 6b56d83c809d
\* SOURCE: apps/fermix_core/lib/fermix_core/home/moved.ex#write,exclusive_write,read @ f1fa82381547
\* SOURCE: apps/fermix_core/lib/fermix_core/home/candidate.ex#put_state,write_private @ b39833e3c49c
\* SOURCE: apps/fermix_core/lib/fermix_core/management/home_move.ex#move_start,move_view @ 9adacb0279fd
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/device_supervisor.ex#children @ 1d7d689451c7
\* SOURCE: apps/fermix_channels/lib/fermix_channels/mobile/rail.ex#@moduledoc @ eea53ac3d395
\* SOURCE: apps/fermix_core/lib/fermix_core/application.ex#prepare_home,finish_activation,finish_move,left_to_status @ 72deb4c9e847
EXTENDS Naturals, FiniteSets

CONSTANTS
    \* Environment switches: what may happen around the move.
    MessagesCanBeLost,  \* the rail loses a request or an answer, or an answer comes only
                        \* after the worker stopped waiting (await_any/3's timeout,
                        \* move_worker.ex:742-755): at most MaxLosses times in all
    MaxLosses,
    SourceCanCrash,     \* the source engine dies and its service manager boots it again
    CandidateCanCrash,  \* the candidate engine dies and boots again
    MaxCrashes,         \* how often each engine may crash
    TransferCanFail,    \* before move_ready: an attempt fails at the source before its
                        \* offer is out (the desktop key or row, the capture), the
                        \* candidate's restore fails (restored/2's error clause), or the
                        \* ready epoch or the marker cannot be written (commit/4 aborts)
    PhaseWriteCanFail,  \* the boot's write of a move's ending fails (a full disk, a
                        \* folder it may not write): finish_move/2 in application.ex
    OldRequestsArrive,  \* a request the worker sent on a rail it has since given up on
                        \* still reaches the candidate. Two rails are two streams, so
                        \* nothing orders one's frames against another's; closing the
                        \* rail it gives up on (close_rail/1, move_worker.ex:208, :426,
                        \* :439) puts a close frame behind the request (Rail.close/1,
                        \* rail.ex), and whether the iroh helper still delivers what it
                        \* holds once the socket closes is the helper's (outside this repo)
    \* Mechanism switches: what the code does about it. TRUE is the real code.
    CandidateWaitsForCommit, \* the candidate activates only on move_commit for the move
                             \* it staged (commit_move/2, candidate.ex:503-536)
    MarkerBeforeCommit,      \* the worker writes moved.json and records committing before
                             \* it sends move_commit (commit/4 then retired/4,
                             \* move_worker.ex:420-442)
    OffersFenced,            \* the candidate takes an offer only when it is later than the
                             \* move it holds: a later move id, or a later attempt of the
                             \* same move (fenced_offer/2 and later?/2,
                             \* candidate.ex:400-412). move_offer carries the attempt
                             \* (stream/3, move_worker.ex:370), which only grows across
                             \* restarts; move ids are ordered by when the move started
                             \* (move_id/1, move.ex:506-515)
    ReadyAfterStaged,        \* move_ready goes out only once staged is written: restored/2
                             \* records staged, then tells the responder
                             \* (candidate.ex:481-487), which answers move_ready only then
                             \* (move_responder.ex:65-69)
    AwaitPinsRail,           \* the worker takes an answer only from the rail it waits on
                             \* (await_any/3 matches {:rail, ^rail, _},
                             \* move_worker.ex:742-755)
    EndingsAfterRestart,     \* the worker records committed or undoing before its restart,
                             \* and the engine that boots after it records done or aborted
                             \* (done/2, undo/3, Move.finish_at_boot/2): an ending is never
                             \* written by an engine about to stop
    RetryOnlyAfterBoot       \* a home.status read writes an ending only in the engine whose
                             \* boot could not write it (Move.view/3 with
                             \* Move.boot_ending/0, which application.ex's left_to_status/1
                             \* records)

VARIABLES
    \* The source: files under its home.
    role,       \* config.toml [fermix_core.engine] role: "primary" | "device"
    moved,      \* moved.json exists
    phase,      \* .move/phase.json's phase; "none" before home.move.start
    attempts,   \* .move/phase.json's attempts
    \* The source: its running engine.
    boot,       \* the role this boot took (Role.resolve/2): "primary" | "device" | "refused"
    unsaid,     \* this boot could not write the move's ending (Move.boot_ending/0)
    wpc,        \* where the move worker is in its code; "off" when no worker runs
    \* The candidate.
    cand,       \* candidate/state.json's phase, and "active" once activate/1 renamed
                \* config.toml into place, its commit point: the next boot is the primary
    candUp,     \* the role the candidate engine runs: "candidate" | "primary"
    restore,    \* the restore task in flight (state.restore), by the rail its answer
                \* goes to: "none" | "cur" | "gone"
    cpc,        \* an activation under way: "idle"; "activate_cur", commit_move/2 for a
                \* move_commit on the worker's rail, which it answers; "activate", one
                \* that answers no one (an old rail's commit, the boot's
                \* finish_activation, or, without CandidateWaitsForCommit, by itself)
    held,       \* the attempt of the move candidate/state.json holds (its "move"), 0
                \* when it holds none
    \* The rail.
    railUp,     \* the worker's current rail is open at both ends
    req,        \* the request on the worker's rail the candidate has not handled yet
    rep,        \* the answer on the worker's rail the worker has not taken yet
    oldReq,     \* streams, commits and resumes sent on rails the worker closed, still
                \* on their way
    oldOffers,  \* the attempts of offers sent on rails the worker closed, still on
                \* their way
    oldReady,   \* a move_ready from a rail the worker left, waiting in its mailbox
    \* Budgets and history.
    losses,     \* messages lost or late so far
    srcCrashes, \* source crashes so far
    candCrashes,\* candidate crashes so far
    doneLost,   \* history: a move_done was lost, or came after the worker stopped waiting
    lateOfferFenced \* history: a late offer reached a staged candidate after the source
                    \* retired, and was refused

vars == <<role, moved, phase, attempts, boot, unsaid, wpc, cand, candUp, restore, cpc, held,
          railUp, req, rep, oldReq, oldOffers, oldReady, losses, srcCrashes, candCrashes,
          doneLost, lateOfferFenced>>

SrcFiles == <<role, moved, phase, attempts>>
CandAll  == <<cand, candUp, restore, cpc, held>>
Net      == <<railUp, req, rep, oldReq, oldOffers, oldReady>>
Budgets  == <<losses, srcCrashes, candCrashes>>
Hist     == <<doneLost, lateOfferFenced>>

MaxAttempts == 3    \* @max_attempts, Move.max_attempts/0 (move.ex:65, :84)

Phases   == {"none", "requested", "streaming", "committing", "committed", "done", "aborting",
             "undoing", "aborted"}
Pending  == {"requested", "streaming", "committing", "aborting"}  \* @pending (move.ex:68)
Requests == {"offer", "stream", "commit", "resume"}
Answers  == {"accept", "ready", "done", "error"}
WorkerStates ==
    {"off", "run", "transfer", "offer", "await_accept", "await_ready", "record_ready",
     "retire", "record_committing", "send_commit", "await_done", "finish", "resume",
     "resume_dial", "await_resume", "await_done_r", "probe", "abort", "undo", "undo_role",
     "undo_end", "restart"}
Awaiting == {"await_accept", "await_ready", "await_done", "await_resume", "await_done_r"}

ASSUME MaxLosses \in Nat /\ MaxCrashes \in Nat

TypeOK ==
    /\ role \in {"primary", "device"}
    /\ moved \in BOOLEAN
    /\ phase \in Phases
    /\ attempts \in 0..MaxAttempts
    /\ boot \in {"primary", "device", "refused"}
    /\ unsaid \in BOOLEAN
    /\ wpc \in WorkerStates
    /\ cand \in {"enrolled", "receiving", "staged", "activating", "active"}
    /\ candUp \in {"candidate", "primary"}
    /\ restore \in {"none", "cur", "gone"}
    /\ cpc \in {"idle", "activate_cur", "activate"}
    /\ railUp \in BOOLEAN
    /\ req \in Requests \cup {"none"}
    /\ rep \in Answers \cup {"none"}
    /\ held \in 0..MaxAttempts
    /\ oldReq \subseteq Requests \ {"offer"}
    /\ oldOffers \subseteq 1..MaxAttempts
    /\ oldReady \in BOOLEAN
    /\ losses \in 0..MaxLosses
    /\ srcCrashes \in 0..MaxCrashes
    /\ candCrashes \in 0..MaxCrashes
    /\ doneLost \in BOOLEAN
    /\ lateOfferFenced \in BOOLEAN

-----------------------------------------------------------------------------
(* Shared pieces *)

\* Role.resolve/2 (role.ex:165-177) at a boot: a configured device is a
\* device; a configured primary that carries moved.json is refused, never a
\* primary.
Resolve(r, m) == IF r = "device" THEN "device" ELSE IF m THEN "refused" ELSE "primary"

\* The request on the worker's rail when the rail closes: still on its way
\* (OldRequestsArrive), or lost. A cur offer carries the worker's attempt.
OldRequest ==
    /\ oldReq' = IF OldRequestsArrive /\ req \in {"stream", "commit", "resume"}
                 THEN oldReq \cup {req} ELSE oldReq
    /\ oldOffers' = IF OldRequestsArrive /\ req = "offer"
                    THEN oldOffers \cup {attempts} ELSE oldOffers

\* The source boots from its files r, m, p (its service manager, after
\* the deliberate self-restart, Lifecycle.restart_self/0, or a crash). DeviceSupervisor.children/1 starts the
\* worker only on a device boot while a move is pending (device_supervisor.ex:50-64,
\* Move.pending?/1, move.ex:311-316). Its rails end with it: an owner that exits
\* takes its session down (rail.ex moduledoc). A request already sent may still
\* arrive; an answer reaches no one.
SourceBoots(r, m, p) ==
    /\ boot' = Resolve(r, m)
    /\ unsaid' = FALSE
    /\ wpc' = IF Resolve(r, m) = "device" /\ p \in Pending THEN "run" ELSE "off"
    /\ req' = "none"
    /\ OldRequest
    /\ rep' = "none"
    /\ oldReady' = FALSE
    /\ railUp' = FALSE
    /\ restore' = IF restore = "cur" THEN "gone" ELSE restore
    /\ cpc' = IF cpc = "activate_cur" THEN "activate" ELSE cpc

\* The worker closes the rail it holds, if any (close_rail/1: Rail.close/1
\* sends its close frame behind whatever the rail already sent), then opens a
\* new one and sends newReq (Rail.open/3 through open_candidate/1,
\* move_worker.ex:709-723), or opens none (newReq = "none", up = FALSE). A
\* request on the closed rail may still arrive; an answer already in the
\* mailbox stays there, where only a worker that does not pin its rail would
\* read it; any later answer is lost.
MoveOn(newReq, up) ==
    /\ req' = newReq
    /\ OldRequest
    /\ rep' = "none"
    /\ oldReady' = (oldReady \/ (rep = "ready" /\ ~AwaitPinsRail))
    /\ railUp' = up
    /\ restore' = IF restore = "cur" THEN "gone" ELSE restore
    /\ cpc' = IF cpc = "activate_cur" THEN "activate" ELSE cpc

\* The worker closes the rail it holds and opens none.
CloseRail == MoveOn("none", FALSE)

\* The candidate's responder answers a on the rail tag names; on a closed
\* rail the answer reaches no one.
Answer(tag, a) ==
    /\ rep' = IF tag = "cur" THEN a ELSE rep
    /\ UNCHANGED oldReady
NoAnswer == UNCHANGED <<rep, oldReady>>

\* The candidate engine stops: every rail to it ends. A request on its way is
\* lost; an answer already sent may have arrived (the step that takes it can
\* come first), and is otherwise lost.
CandidateRailsEnd ==
    /\ req' = "none"
    /\ rep' = "none"
    /\ oldReq' = {}
    /\ oldOffers' = {}
    /\ railUp' = FALSE
    /\ doneLost' = (doneLost \/ rep = "done")
    /\ UNCHANGED <<oldReady, lateOfferFenced>>

\* An old move_ready the worker would take (only without AwaitPinsRail), once
\* its own rail has nothing outstanding.
OldReadyUsable == ~AwaitPinsRail /\ oldReady /\ req = "none"

\* Something will still arrive on the worker's rail: a request the candidate
\* has not handled, or a restore or an activation that answers on it.
Coming == req /= "none" \/ restore = "cur" \/ cpc = "activate_cur"

NothingComing ==
    /\ ~Coming /\ rep = "none"
    /\ ~(OldReadyUsable /\ wpc \in {"await_ready", "await_resume"})

\* Where a failed wait goes: another attempt before move_ready
\* (attempt_failed/2, move_worker.ex:228-235), the resume after the commit
\* (retired/4, :438-440), the next round of the resume loop (resume_loop/4,
\* :519-536).
AfterAwait(w) == CASE w \in {"await_accept", "await_ready"} -> "transfer"
                   [] w = "await_done" -> "resume"
                   [] OTHER -> "resume_dial"

-----------------------------------------------------------------------------
(* The source and its move worker *)

\* A worker step that only moves the worker on.
Goto(w) ==
    /\ wpc' = w
    /\ UNCHANGED <<SrcFiles, boot, unsaid, CandAll, Net, Budgets, Hist>>

\* home.move.start (HomeMove.move_start/3, home_move.ex:188-206): Move.start/5
\* writes request.json, phase "requested", then role = "device", the last
\* write (write_request/3, move.ex:559-588: a failure part-way removes .move/,
\* so a part-way start leaves the primary as it was), and the handler restarts
\* through Lifecycle.restart_self/0. The boot is a device with a move pending,
\* so the worker starts. One step: until the restart the engine still runs as
\* the primary, and nothing of the move acts.
Start ==
    /\ phase = "none" /\ boot = "primary" /\ wpc = "off"
    /\ phase' = "requested"
    /\ role' = "device"
    /\ boot' = "device"
    /\ unsaid' = FALSE
    /\ wpc' = "run"
    /\ UNCHANGED <<moved, attempts, CandAll, Net, Budgets, Hist>>

\* run/1 (move_worker.ex:115-129) reads the request and the phase, and
\* carry_on/3 (:147-156) the marker first, then the phase. (An unreadable
\* marker, :154, is not modelled: the marker is whole or absent.)
Run ==
    /\ wpc = "run"
    /\ Goto(IF moved THEN "resume" ELSE IF phase = "aborting" THEN "abort" ELSE "transfer")

\* transfer/1 (move_worker.ex:186-196): counts the attempt in phase.json, or
\* aborts once MaxAttempts were made, across restarts. A failed attempt closed
\* its rail first (close_rail/1, :208, before attempt_failed/2): the close is
\* folded in here, the worker's next step, so an answer can still reach the
\* mailbox in the moment between the wait ending and the close.
Transfer ==
    /\ wpc = "transfer"
    /\ IF attempts >= MaxAttempts
       THEN /\ wpc' = "abort" /\ UNCHANGED <<attempts, phase>>
       ELSE /\ attempts' = attempts + 1 /\ phase' = "streaming" /\ wpc' = "offer"
    /\ CloseRail
    /\ UNCHANGED <<role, moved, boot, unsaid, cand, candUp, held, Budgets, Hist>>

\* attempt_transfer/1 (move_worker.ex:198-214): the desktop key and row and
\* the capture (writes no rule reads), open_candidate/1 (:709-723) and
\* move_offer (stream/3, :373). The dial reaches the candidate's own key only
\* while it runs in the candidate role.
SendOffer ==
    /\ wpc = "offer" /\ candUp = "candidate"
    /\ wpc' = "await_accept"
    /\ MoveOn("offer", TRUE)
    /\ UNCHANGED <<SrcFiles, boot, unsaid, cand, candUp, held, Budgets, Hist>>

\* No candidate answers the dial: it rebooted as the primary, and its key is
\* gone. attempt_failed/2 sleeps and tries again (move_worker.ex:212, :228-235).
DialFails ==
    /\ wpc = "offer" /\ candUp = "primary"
    /\ wpc' = "transfer"
    /\ MoveOn("none", FALSE)
    /\ UNCHANGED <<SrcFiles, boot, unsaid, cand, candUp, held, Budgets, Hist>>

\* await(rail, "move_accept"), same_recipient/2, send_file/3 and move_end
\* (stream/3, move_worker.ex:374-377): one "stream" request stands for every
\* move_chunk and the move_end.
TakeAccept ==
    /\ wpc = "await_accept" /\ rep = "accept"
    /\ rep' = "none"
    /\ req' = IF railUp THEN "stream" ELSE "none"
    /\ wpc' = "await_ready"
    /\ UNCHANGED <<SrcFiles, boot, unsaid, CandAll, railUp, oldReq, oldOffers, oldReady, Budgets, Hist>>

\* await(rail, "move_ready") (stream/3, move_worker.ex:378). Without
\* AwaitPinsRail the worker would also take one from a rail it left.
TakeReady ==
    /\ wpc = "await_ready"
    /\ \/ rep = "ready" /\ rep' = "none" /\ UNCHANGED oldReady
       \/ OldReadyUsable /\ oldReady' = FALSE /\ UNCHANGED rep
    /\ wpc' = "record_ready"
    /\ UNCHANGED <<SrcFiles, boot, unsaid, CandAll, railUp, req, oldReq, oldOffers, Budgets, Hist>>

\* An error event is a refusal ({:refused, _, _}, await_any/3,
\* move_worker.ex:744-745): before move_ready it aborts the move
\* (attempt_failed/2, :216-217); after it, retired/4 resumes (:438-440) and
\* the resume loop goes round again (:524-534).
TakeRefusal ==
    /\ wpc \in Awaiting /\ rep = "error"
    /\ rep' = "none"
    /\ wpc' = IF wpc \in {"await_accept", "await_ready"} THEN "abort" ELSE AfterAwait(wpc)
    /\ UNCHANGED <<SrcFiles, boot, unsaid, CandAll, railUp, req, oldReq, oldOffers, oldReady, Budgets, Hist>>

\* The wait's own timeout, or the rail's {:closed, _} (await_any/3,
\* move_worker.ex:750-753), when nothing can arrive any more: the worker's own
\* timer.
GiveUp ==
    /\ wpc \in Awaiting /\ NothingComing
    /\ Goto(AfterAwait(wpc))

\* commit/4 (move_worker.ex:420-429), one file write per step: record the ready
\* epoch (:421); retire/1 writes moved.json (:422, :452-464). Then retired/4
\* (:431-442): link/3 and record committing (:432-433); move_commit on the
\* same rail (:434) and await move_done (:435). A failure recording the ready
\* epoch is the same abort as a failed marker write (RetireFails, :425-427).
\* Without MarkerBeforeCommit, move_commit goes right after
\* the ready epoch and the marker after it.
RecordReady == wpc = "record_ready" /\ Goto(IF MarkerBeforeCommit THEN "retire" ELSE "send_commit")

Retire ==
    /\ wpc = "retire"
    /\ moved' = TRUE
    /\ wpc' = "record_committing"
    /\ UNCHANGED <<role, phase, attempts, boot, unsaid, CandAll, Net, Budgets, Hist>>

RecordCommitting ==
    /\ wpc = "record_committing"
    /\ phase' = "committing"
    /\ wpc' = IF MarkerBeforeCommit THEN "send_commit" ELSE "await_done"
    /\ UNCHANGED <<role, moved, attempts, boot, unsaid, CandAll, Net, Budgets, Hist>>

SendCommit ==
    /\ wpc = "send_commit"
    /\ req' = IF railUp THEN "commit" ELSE "none"
    /\ wpc' = IF MarkerBeforeCommit THEN "await_done" ELSE "retire"
    /\ UNCHANGED <<SrcFiles, boot, unsaid, CandAll, railUp, rep, oldReq, oldOffers, oldReady, Budgets, Hist>>

\* move_done (retired/4 :435; resume_on/2 :549 and resumed/3 :555-561).
TakeDone ==
    /\ wpc \in {"await_done", "await_resume", "await_done_r"} /\ rep = "done"
    /\ rep' = "none"
    /\ wpc' = "finish"
    /\ UNCHANGED <<SrcFiles, boot, unsaid, CandAll, railUp, req, oldReq, oldOffers, oldReady, Budgets, Hist>>

\* done/2: record committed (with EndingsAfterRestart; done without), remove
\* the request, then the restart (SelfRestart), a step of its own: until it,
\* this engine still answers home.status.
Finish ==
    /\ wpc = "finish"
    /\ phase' = IF EndingsAfterRestart THEN "committed" ELSE "done"
    /\ wpc' = "restart"
    /\ UNCHANGED <<role, moved, attempts, boot, unsaid, CandAll, Net, Budgets, Hist>>

\* The worker's deliberate self-restart (Lifecycle.restart_self/0): the
\* engine stops and its service manager boots it from its files. A crash at
\* the same point is the same boot (SourceCrash).
SelfRestart ==
    /\ wpc = "restart"
    /\ SourceBoots(role, moved, phase)
    /\ UNCHANGED <<role, moved, phase, attempts, cand, candUp, held, Budgets, Hist>>

\* The ending a boot in its role says for the phase the engine before the
\* restart left half-said (ending/2, move.ex): a device boot turns committed
\* into done; a primary boot turns undoing, or an aborting a crash cut short
\* after the role write, into aborted.
EndingDue ==
    \/ boot = "device" /\ phase = "committed"
    \/ boot = "primary" /\ phase \in {"undoing", "aborting"}
Ending == IF phase = "committed" THEN "done" ELSE "aborted"

\* Move.finish_at_boot/2, from the boot's prepare_home (finish_move/2,
\* application.ex), before anything reads the home. One file write, once per
\* boot.
Finalize ==
    /\ wpc = "off" /\ ~unsaid /\ EndingDue
    /\ phase' = Ending
    /\ UNCHANGED <<role, moved, attempts, boot, unsaid, wpc, CandAll, Net, Budgets, Hist>>

\* That write fails (PhaseWriteCanFail). The boot goes on and records that it
\* left the ending unrecorded (left_to_status/1, application.ex:
\* Move.remember_unrecorded_ending/0).
FinalizeFails ==
    /\ PhaseWriteCanFail /\ wpc = "off" /\ ~unsaid /\ EndingDue
    /\ unsaid' = TRUE
    /\ UNCHANGED <<SrcFiles, boot, wpc, CandAll, Net, Budgets, Hist>>

\* A home.status read (Move.view/3, through HomeMove.move_view/3) tries the
\* write again, once per read, until it lands; a read whose write fails
\* changes nothing. With RetryOnlyAfterBoot only the engine whose boot left
\* the ending unrecorded writes it; switched off, a read in any engine of the
\* ending's role writes it, the one about to restart included.
StatusRetry ==
    /\ EndingDue
    /\ IF RetryOnlyAfterBoot THEN unsaid ELSE TRUE
    /\ phase' = Ending
    /\ UNCHANGED <<role, moved, attempts, boot, unsaid, wpc, CandAll, Net, Budgets, Hist>>

\* resume/1 (move_worker.ex:498-511): ensure_link/3, then record committing.
\* A failed commit closed its rail first (retired/4, :439): folded in here.
Resume ==
    /\ wpc = "resume"
    /\ phase' = "committing"
    /\ wpc' = "resume_dial"
    /\ CloseRail
    /\ UNCHANGED <<role, moved, attempts, boot, unsaid, cand, candUp, held, Budgets, Hist>>

\* resume_once/2 (move_worker.ex:538-543): open_candidate/1, then move_resume
\* (resume_on/2, :545-552). with_rail/2 closed the previous round's rail
\* (:586-590): folded in here. A candidate that no longer answers on its own
\* key sends the worker to probe_primary/2.
ResumeDial ==
    /\ wpc = "resume_dial" /\ candUp = "candidate"
    /\ wpc' = "await_resume"
    /\ MoveOn("resume", TRUE)
    /\ UNCHANGED <<SrcFiles, boot, unsaid, cand, candUp, held, Budgets, Hist>>

ResumeDialFails ==
    /\ wpc = "resume_dial" /\ candUp = "primary"
    /\ wpc' = "probe"
    /\ MoveOn("none", FALSE)
    /\ UNCHANGED <<SrcFiles, boot, unsaid, cand, candUp, held, Budgets, Hist>>

\* move_ready answers move_resume: still staged, so commit now (resumed/3,
\* move_worker.ex:557-561).
TakeResumeReady ==
    /\ wpc = "await_resume"
    /\ \/ rep = "ready" /\ rep' = "none" /\ UNCHANGED oldReady
       \/ OldReadyUsable /\ oldReady' = FALSE /\ UNCHANGED rep
    /\ req' = IF railUp THEN "commit" ELSE "none"
    /\ wpc' = "await_done_r"
    /\ UNCHANGED <<SrcFiles, boot, unsaid, CandAll, railUp, oldReq, oldOffers, Budgets, Hist>>

\* probe_primary/2 (move_worker.ex:565-583): dial the moved identity as the
\* desktop; a hello_ack at the ready epoch or later is the new primary, which
\* only the activated candidate, booted as the primary, can give.
Probe ==
    /\ wpc = "probe"
    /\ Goto(IF candUp = "primary" THEN "finish" ELSE "resume_dial")

\* abort/3 (move_worker.ex:658-664): reads the marker again; with it, resume.
\* A refused attempt or a failed commit closed its rail first (:208, :426):
\* folded in here.
Abort ==
    /\ wpc = "abort"
    /\ wpc' = IF moved THEN "resume" ELSE "undo"
    /\ CloseRail
    /\ UNCHANGED <<SrcFiles, boot, unsaid, cand, candUp, held, Budgets, Hist>>

\* undo/3 (move_worker.ex:666-685), one file write per step: record aborting
\* (:668); the desktop row, key and snapshot go (nothing a rule reads); role =
\* "primary" (:671); remove the request and record aborted (:672-673); restart
\* (:684).
Undo ==
    /\ wpc = "undo"
    /\ phase' = "aborting"
    /\ wpc' = "undo_role"
    /\ UNCHANGED <<role, moved, attempts, boot, unsaid, CandAll, Net, Budgets, Hist>>

UndoRole ==
    /\ wpc = "undo_role"
    /\ role' = "primary"
    /\ wpc' = "undo_end"
    /\ UNCHANGED <<moved, phase, attempts, boot, unsaid, CandAll, Net, Budgets, Hist>>

UndoEnd ==
    /\ wpc = "undo_end"
    /\ phase' = IF EndingsAfterRestart THEN "undoing" ELSE "aborted"
    /\ wpc' = "restart"
    /\ UNCHANGED <<role, moved, attempts, boot, unsaid, CandAll, Net, Budgets, Hist>>

-----------------------------------------------------------------------------
(* The candidate *)

\* The Candidate process takes calls one at a time, and only in the candidate
\* role: the responder runs under CandidateSupervisor (candidate_supervisor.ex).
CandIdle == candUp = "candidate" /\ cpc = "idle"

\* move_offer -> Candidate.offer/2 -> offer_move/2 (candidate.ex:385-393): an
\* enrolled, receiving or staged candidate takes the offer through
\* fenced_offer/2 (:400-407); any other phase refuses it (move_failed). With
\* OffersFenced it takes only an offer later than the move it holds
\* (later?/2, :409-412: {move_id, attempt} above the held one, any offer when
\* it holds none; with one move id, a later attempt), and refuses an earlier
\* or equal one (move_mismatch), leaving what it holds untouched. Taking it,
\* accept_offer/2 (:414-434) discards any staging, records receiving with the
\* offer as its move, and answers; the responder sends move_accept
\* (move_responder.ex:91-101, :150-172). A restore in flight is not stopped
\* (state.restore is kept).
OnOffer(tag, a) ==
    IF cand \in {"enrolled", "receiving", "staged"} /\ (~OffersFenced \/ a > held)
    THEN /\ cand' = "receiving" /\ held' = a /\ Answer(tag, "accept")
         /\ UNCHANGED <<candUp, restore, cpc, lateOfferFenced>>
    ELSE /\ Answer(tag, "error") /\ UNCHANGED CandAll
         /\ lateOfferFenced' = (lateOfferFenced \/ (moved /\ cand = "staged"))

\* move_end -> end_stream/1 -> Candidate.stage/3 -> stage_move/3
\* (move_responder.ex:196-218, candidate.ex:456-479): a receiving candidate
\* starts the restore task in place of any earlier one; the answer waits for
\* it. Without ReadyAfterStaged the responder answers move_ready at once.
OnStream(tag) ==
    IF cand = "receiving"
    THEN /\ restore' = tag /\ UNCHANGED <<cand, candUp, cpc, held>>
         /\ IF ReadyAfterStaged THEN NoAnswer ELSE Answer(tag, "ready")
    ELSE /\ Answer(tag, "error") /\ UNCHANGED CandAll

\* move_commit -> Candidate.commit/2 -> commit_move/2 (candidate.ex:503-536).
\* Once the home is in place (the activated? flag, set where activate/1
\* succeeded, :523, :543), a second move_commit for the move, from a rail its
\* source gave up on, is answered as the first was (:505-509). Staged or
\* activating, for this move: record activating; the renames and the answer
\* follow in the same callback (Activate). Otherwise move_unknown.
OnCommit(tag) ==
    CASE cand = "active" ->
             /\ Answer(tag, "done") /\ UNCHANGED CandAll
      [] cand \in {"staged", "activating"} ->
             /\ cand' = "activating"
             /\ cpc' = IF tag = "cur" THEN "activate_cur" ELSE "activate"
             /\ UNCHANGED <<candUp, restore, held>> /\ NoAnswer
      [] OTHER ->
             /\ Answer(tag, "error") /\ UNCHANGED CandAll

\* move_resume -> Candidate.resume/2 and the responder: staged answers
\* move_ready; once activate/1 renamed the settings into place (the
\* activated? flag) it answers move_done; a candidate still activating is
\* refused (move_failed), so the source keeps resuming; anything else is
\* refused (move_unknown).
OnResume(tag) ==
    /\ UNCHANGED CandAll
    /\ CASE cand = "staged" -> Answer(tag, "ready")
         [] cand = "active" -> Answer(tag, "done")
         [] OTHER -> Answer(tag, "error")

\* A request other than an offer.
OnRequest(r, tag) ==
    /\ CASE r = "stream" -> OnStream(tag)
         [] r = "commit" -> OnCommit(tag)
         [] r = "resume" -> OnResume(tag)
    /\ UNCHANGED lateOfferFenced

\* The responder of the worker's rail handles its request. An offer on it
\* carries the worker's attempt (stream/3, move_worker.ex:370; transfer/1 puts
\* it in ctx, :194): the worker closes the rail before it counts another.
Handle ==
    /\ CandIdle /\ req /= "none"
    /\ req' = "none"
    /\ IF req = "offer" THEN OnOffer("cur", attempts) ELSE OnRequest(req, "cur")
    /\ UNCHANGED <<railUp, oldReq, oldOffers, SrcFiles, boot, unsaid, wpc, Budgets, doneLost>>

\* The responder of a rail the worker closed handles a request still on its
\* way (OldRequestsArrive). Its answer reaches no one.
HandleOld(r) ==
    /\ CandIdle /\ r \in oldReq
    /\ oldReq' = oldReq \ {r}
    /\ OnRequest(r, "gone")
    /\ UNCHANGED <<railUp, req, oldOffers, SrcFiles, boot, unsaid, wpc, Budgets, doneLost>>

\* The same, for a move_offer of attempt a.
HandleOldOffer(a) ==
    /\ CandIdle /\ a \in oldOffers
    /\ oldOffers' = oldOffers \ {a}
    /\ OnOffer("gone", a)
    /\ UNCHANGED <<railUp, req, oldReq, SrcFiles, boot, unsaid, wpc, Budgets, doneLost>>

\* The restore task's result -> restored/2 (candidate.ex:211-214, :481-487):
\* record staged, then tell the responder of the rail that staged it, which
\* answers move_ready (move_responder.ex:65-69).
Restored ==
    /\ CandIdle /\ restore /= "none"
    /\ cand' = "staged"
    /\ restore' = "none"
    /\ IF ReadyAfterStaged THEN Answer(restore, "ready") ELSE NoAnswer
    /\ UNCHANGED <<candUp, cpc, held, railUp, req, oldReq, oldOffers, SrcFiles, boot, unsaid, wpc, Budgets, Hist>>

\* Without CandidateWaitsForCommit: a staged candidate activates by itself.
SelfActivate ==
    /\ ~CandidateWaitsForCommit /\ CandIdle /\ cand = "staged"
    /\ cand' = "activating"
    /\ cpc' = "activate"
    /\ UNCHANGED <<candUp, restore, held, Net, SrcFiles, boot, unsaid, wpc, Budgets, Hist>>

\* Activation.activate/1 (activation.ex:76-85): the staged entries, then
\* config.toml last (place_config/2, :197-202), the commit point: the next boot
\* reads role = "primary". Then candidate/ goes, the restart is scheduled
\* (candidate.ex:522, :542), and commit_move/2 answers, so the responder sends
\* move_done and closes (move_responder.ex:119-124). A crash between the
\* rename and the answer is a crash after this step, which loses the answer.
Activate ==
    /\ candUp = "candidate" /\ cpc \in {"activate_cur", "activate"}
    /\ cand' = "active"
    /\ cpc' = "idle"
    /\ IF cpc = "activate_cur" THEN Answer("cur", "done") ELSE NoAnswer
    /\ UNCHANGED <<candUp, restore, held, railUp, req, oldReq, oldOffers, SrcFiles, boot, unsaid, wpc, Budgets, Hist>>

\* handle_info(:restart) (candidate.ex:227-230) -> Lifecycle.restart_self/0. The
\* boot reads role = "primary" and finishes the activation
\* (FermixCore.Application, application.ex:195-214).
Restart ==
    /\ CandIdle /\ cand = "active"
    /\ candUp' = "primary"
    /\ restore' = "none"
    /\ CandidateRailsEnd
    /\ UNCHANGED <<cand, cpc, held, SrcFiles, boot, unsaid, wpc, Budgets>>

-----------------------------------------------------------------------------
(* The environment *)

CanLose == MessagesCanBeLost /\ losses < MaxLosses

\* The rail loses the request or the answer on it; the worker then sees
\* {:closed, _} or its timeout (GiveUp).
Lose ==
    /\ CanLose
    /\ \/ /\ req /= "none" /\ req' = "none"
          /\ UNCHANGED <<rep, doneLost>>
       \/ /\ rep /= "none" /\ rep' = "none"
          /\ doneLost' = (doneLost \/ rep = "done")
          /\ UNCHANGED req
    /\ losses' = losses + 1
    /\ UNCHANGED <<railUp, oldReq, oldOffers, oldReady, SrcFiles, boot, unsaid, wpc, CandAll,
                   srcCrashes, candCrashes, lateOfferFenced>>

\* The worker's wait times out while its answer is still coming (a restore
\* longer than @ready_ms, a slow rail). Not once the answer arrived: a message
\* in the mailbox is taken at once.
Late ==
    /\ CanLose /\ wpc \in Awaiting /\ Coming /\ rep = "none"
    /\ ~(OldReadyUsable /\ wpc \in {"await_ready", "await_resume"})
    /\ losses' = losses + 1
    /\ wpc' = AfterAwait(wpc)
    /\ doneLost' = (doneLost \/ wpc \in {"await_done", "await_done_r"})
    /\ UNCHANGED <<SrcFiles, boot, unsaid, CandAll, Net, srcCrashes, candCrashes, lateOfferFenced>>

\* Before its offer is out, an attempt fails at the source: the desktop key or
\* row, or the capture (attempt_transfer/1 -> attempt_failed/2,
\* move_worker.ex:212, :228-235).
AttemptFails ==
    /\ TransferCanFail /\ wpc = "offer"
    /\ wpc' = "transfer"
    /\ MoveOn("none", FALSE)
    /\ UNCHANGED <<SrcFiles, boot, unsaid, cand, candUp, held, Budgets, Hist>>

\* Moved.write/2 fails before the file exists (moved.ex:45-59): retire/1's
\* error -> commit/4 closes the rail and aborts (move_worker.ex:425-427).
RetireFails == TransferCanFail /\ wpc = "retire" /\ Goto("abort")

\* The candidate refuses an offer it has no room for (room_for/2: twice the
\* stream plus a floor), before any byte moves, holding what it held.
OfferRefusedForRoom ==
    /\ TransferCanFail /\ CandIdle /\ req = "offer"
    /\ cand \in {"enrolled", "receiving", "staged"}
    /\ req' = "none"
    /\ Answer("cur", "error")
    /\ UNCHANGED <<CandAll, railUp, oldReq, oldOffers, SrcFiles, boot, unsaid, wpc, Budgets, Hist>>

\* restored/2's error clause (candidate.ex:489-501): back to enrolled, holding
\* no move (put/3 drops the nil "move"), and the
\* responder refuses (move_failed, move_responder.ex:71-75).
RestoreFails ==
    /\ TransferCanFail /\ CandIdle /\ restore /= "none"
    /\ cand' = "enrolled"
    /\ held' = 0
    /\ restore' = "none"
    /\ Answer(restore, "error")
    /\ UNCHANGED <<candUp, cpc, railUp, req, oldReq, oldOffers, SrcFiles, boot, unsaid, wpc, Budgets, Hist>>

\* The source engine dies, and its service manager boots it from its files.
SourceCrash ==
    /\ SourceCanCrash /\ srcCrashes < MaxCrashes /\ wpc /= "off"
    /\ srcCrashes' = srcCrashes + 1
    /\ SourceBoots(role, moved, phase)
    /\ UNCHANGED <<SrcFiles, cand, candUp, held, losses, candCrashes, Hist>>

\* The candidate engine dies and boots again: as the primary once config.toml
\* is in place; otherwise as the candidate, whose handle_continue/2 runs
\* carry_on/1 first (candidate.ex:148-158), and activating finishes the
\* activation (finish_activation/1, :538-548). Its restore task dies with it.
CandidateCrash ==
    /\ CandidateCanCrash /\ candCrashes < MaxCrashes /\ candUp = "candidate"
    /\ candCrashes' = candCrashes + 1
    /\ candUp' = IF cand = "active" THEN "primary" ELSE "candidate"
    /\ cpc' = IF cand = "activating" THEN "activate" ELSE "idle"
    /\ restore' = "none"
    /\ CandidateRailsEnd
    /\ UNCHANGED <<cand, held, SrcFiles, boot, unsaid, wpc, losses, srcCrashes>>

-----------------------------------------------------------------------------
Init ==
    /\ role = "primary"
    /\ moved = FALSE
    /\ phase = "none"
    /\ attempts = 0
    /\ boot = "primary"
    /\ unsaid = FALSE
    /\ wpc = "off"
    /\ cand = "enrolled"
    /\ candUp = "candidate"
    /\ restore = "none"
    /\ cpc = "idle"
    /\ held = 0
    /\ railUp = FALSE
    /\ req = "none"
    /\ rep = "none"
    /\ oldReq = {}
    /\ oldOffers = {}
    /\ oldReady = FALSE
    /\ losses = 0
    /\ srcCrashes = 0
    /\ candCrashes = 0
    /\ doneLost = FALSE
    /\ lateOfferFenced = FALSE

\* The legitimate ends: the move done, the source a desktop and the candidate
\* booted as the primary; or the move undone, the source booted as the primary
\* with its worker gone, whatever the candidate holds (it never activated: a
\* candidate left staged or receiving waits, harmlessly, for a move that will
\* not come). A boot finishes a committed, undoing or cut-short aborting
\* phase (Finalize), so the ends are done and aborted themselves. Deadlock
\* checking is on, so any other state where nothing can happen is a wedge.
Done ==
    \/ phase = "done" /\ wpc = "off" /\ candUp = "primary"
    \/ phase = "aborted" /\ boot = "primary" /\ wpc = "off"

Terminated == Done /\ UNCHANGED vars

SourceStep ==
    \/ Run \/ Transfer \/ SendOffer \/ DialFails \/ TakeAccept \/ TakeReady \/ TakeRefusal
    \/ GiveUp \/ RecordReady \/ Retire \/ RecordCommitting \/ SendCommit \/ TakeDone
    \/ Finish \/ SelfRestart \/ Finalize \/ Resume \/ ResumeDial \/ ResumeDialFails
    \/ TakeResumeReady \/ Probe \/ Abort \/ Undo \/ UndoRole \/ UndoEnd

CandidateStep ==
    \/ Handle \/ (\E r \in Requests \ {"offer"} : HandleOld(r))
    \/ (\E a \in 1..MaxAttempts : HandleOldOffer(a))
    \/ Restored \/ SelfActivate \/ Activate \/ Restart

Environment ==
    \/ Start \/ Lose \/ Late \/ AttemptFails \/ RetireFails \/ RestoreFails
    \/ OfferRefusedForRoom \/ SourceCrash \/ CandidateCrash \/ FinalizeFails \/ StatusRetry

Next == SourceStep \/ CandidateStep \/ Environment \/ Terminated

\* The worker's next step, the candidate's own steps (its restore task, its
\* activation, its scheduled restart) and the handling of a request that
\* arrived are Fermix's. The owner's start and status reads, the rail's
\* losses and delays, failures and crashes get no fairness. Every check here is a safety check,
\* so this records intent for a later liveness check; it changes no result.
Fairness ==
    /\ WF_vars(SourceStep)
    /\ WF_vars(Restored)
    /\ WF_vars(Activate)
    /\ WF_vars(Restart)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* The source serves as the primary when the engine booted as one, or when its
\* next boot will (config.toml says primary and moved.json is absent,
\* Role.resolve/2). Counting the next boot as well keeps undo/3's last window
\* (role written, restart not yet) on the cautious side.
SourceServesPrimary == boot = "primary" \/ (role = "primary" /\ ~moved)

\* The candidate serves as the primary from its commit point on: config.toml
\* renamed into place (activation.ex moduledoc), whether or not it has booted
\* again yet; nothing ever renames it back.
CandidateServesPrimary == cand = "active"

\* Build spec section 7.2 (B5): "at most one engine serves as the primary".
AtMostOnePrimary == ~(SourceServesPrimary /\ CandidateServesPrimary)

\* The source never retires without a candidate that can activate: once
\* moved.json exists, the candidate holds the staged home, or is activating it
\* or has (commit/4's comment, move_worker.ex:415-419: "the marker comes before
\* move_commit"; MoveWorker's moduledoc: "Once moved.json exists the move is
\* never aborted"). A later move_commit, which the resume loop keeps sending,
\* activates a staged candidate.
RetiredOnlyForStagedCandidate == moved => cand \in {"staged", "activating", "active"}

\* An ending is said only by the engine that came back after the restart: a
\* home.status that reads done or aborted never reads it from an engine about
\* to stop (edges F1), so a desktop's primary is already beside a done, and
\* the primary's own role beside an aborted.
EndingsFromSurvivor == phase \in {"done", "aborted"} => wpc /= "restart"

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* The move completes: the source is done and the candidate booted as the primary.
Witness_MoveDone == ~(phase = "done" /\ candUp = "primary")

\* The move is undone and the source booted as the primary again.
Witness_AbortedBack == ~(phase = "aborted" /\ boot = "primary")

\* A move_done was lost or late, and the move still completed, by the resume
\* loop or the probe.
Witness_ResumedAfterLostDone == ~(doneLost /\ phase = "done")

\* A move_offer from a rail the worker gave up on reaches the staged candidate
\* after the source retired, and the fence refuses it.
Witness_LateOfferFenced == ~lateOfferFenced

=============================================================================
