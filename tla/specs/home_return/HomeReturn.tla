----------------------------- MODULE HomeReturn -----------------------------
(***************************************************************************)
(* Always On's move back (ALWAYS_ON_MOVE_BACK.md draft 2, sections 1, 3,  *)
(* 7 and 8): the home comes back from the server it moved to, to the      *)
(* computer it left, which receives it in its own device engine. Three    *)
(* copies of the home take part:                                           *)
(*  - the Mac's RETIRED copy: its home, configured as a device, carrying  *)
(*    the moved marker (moved.json) and the desktop link                  *)
(*    (device/desktop.json);                                               *)
(*  - the SERVER's home, the primary: it moves as a replace's source does *)
(*    (FermixChannels.Home.MoveWorker, keep_as_desktop false), retiring by *)
(*    its own marker, or undoing the move before it;                       *)
(*  - the Mac's STAGING (candidate/staging): the server's copy restored    *)
(*    for this computer, which the activation puts in place of the retired *)
(*    copy, in the same home (Activation.activate/2, steps a to g).        *)
(* "Mac" is the computer the home left, whatever its OS.                   *)
(*                                                                         *)
(* The Mac drives everything through home.act, one act at a time         *)
(* (Management.AlwaysOn's serializer): Move back (a return candidate      *)
(* beside the moved home, then return.json), Move now (home.move.start    *)
(* forwarded over the link), Cancel, Delete your server, and, when no     *)
(* server answers, Restore here (the return_restore job: the delete as    *)
(* the fence, then the local copy staged and activated). Each act reads   *)
(* the summary first and runs only what it offers (the key rule); its     *)
(* steps after that read are steps of their own, so the candidate and the *)
(* server can move in between, as they can in the code.                    *)
(*                                                                         *)
(* The Mac's acts (Press and the Mb, Mn, Cx, Ds and Rh actions) mirror     *)
(* Management.AlwaysOn's move back, Management.Provision's delete and      *)
(* Restore here's job, and Home.LocalReturn; the summary's offers         *)
(* (Offered) mirror HomeSummary's returning/1, settled/1 and back/1. The   *)
(* spec was first written from the design ahead of them: its finding HR-1  *)
(* became the code's write-ahead of move_started_at (StartKeptFirst).      *)
(* Two findings are open against the code, each a proposed rule the code   *)
(* breaks (README.md): HR-2 (UndoneReturnCanEnd) and HR-3                  *)
(* (GoneServerCanBeRestored).                                              *)
(*                                                                         *)
(* Rails are named from the server's worker's side, as in home_move:      *)
(* "cur" is the rail it waits on now, "gone" one it left. A request on a  *)
(* rail the worker left is lost here (home_move checks the late offer and *)
(* the fence against it, with this candidate code); an answer on it       *)
(* reaches no one.                                                         *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - what home_move proves on its own: requests from abandoned rails, the *)
(*    offer fence and the late move_ready (home_move checks 04 to 07, 11), *)
(*    the endings said only by the engine that came back (check 12), and  *)
(*    the ending a boot could not write;                                   *)
(*  - the enrolment window and its withdrawal: the candidate enrols while *)
(*    the server answers as the primary; its failures (an expired code, a  *)
(*    refused enrolment) end it failed, which no rule reads, and Cancel's  *)
(*    withdraw writes nothing a rule reads;                                *)
(*  - Try again after the server undid the move: a second move, which the *)
(*    fence orders by move id (home_move); here a server that moved once  *)
(*    refuses another home.move.start; the 24-hour listen window;          *)
(*  - the stream's frames, the capture, the keychain at staging (a refusal *)
(*    is a restore that fails, RestoreFails), the room check (a refusal    *)
(*    before any byte, as RestoreFails is for the rules), MoveAwake;       *)
(*  - paths this machine keeps (DeviceLocal's return tag) at any depth:    *)
(*    step a keeps them and step b moves them into the staged entry first; *)
(*    activation_return_test holds them at depth after a stop at every     *)
(*    step. Here one entry stands for the staged entries (memory.db and    *)
(*    the rest, each with its -wal and -shm) and one path for what only    *)
(*    the retired copy has (a file the server deleted);                    *)
(*  - an activation that fails part-way and tries again on a timer: it    *)
(*    re-runs the same idempotent steps, as a crash and the next start do; *)
(*  - a boot that cannot write moved_at (it is retried at each             *)
(*    home.status read): delete_server waits for it, which no rule needs;  *)
(*  - an owner's own server: it has no ledger and gets no Restore here;    *)
(*  - a second desktop: the link reaching a newer epoch than return.json   *)
(*    was asked at (stale?/1, Management.Home's drop of a passed return);  *)
(*  - the fence's failure kept in the ledger and its delete_failed screen  *)
(*    (restoring/1): a refused fence here just ends the job;               *)
(*  - the copy's choice and a wrong passphrase, refused before anything is *)
(*    written (LocalReturn.choose/2);                                      *)
(*  - the deriving of the key: part of the staging step (RhStage).        *)
(*                                                                         *)
(* One step = one thing in the code: one file write (or one rename), one  *)
(* Candidate callback, one dial, one forwarded request, one wait the      *)
(* server's worker ends, one provider call, or one boot.                   *)
(***************************************************************************)
\* SOURCE: apps/fermix_channels/lib/fermix_channels/home/move_worker.ex @ 174049035bfe
\* SOURCE: apps/fermix_channels/lib/fermix_channels/home/candidate.ex @ 02a276b26b35
\* SOURCE: apps/fermix_channels/lib/fermix_channels/home/move_responder.ex @ 31d80078d517
\* SOURCE: apps/fermix_core/lib/fermix_core/home/candidate/activation.ex @ 41d05d90bb47
\* SOURCE: apps/fermix_core/lib/fermix_core/home/candidate.ex#prepare_return,returnable_engine,returnable_home,linked_and_still,no_move_here,replaceable_return,present?,remove @ 649c6a74f681
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/device_supervisor.ex#children,dial_children,start_candidate,stop_candidate,start_candidate_subtree,candidate_spec @ a9ce5e14d9a3
\* SOURCE: apps/fermix_channels/lib/fermix_channels/home/link.ex#start_return,stop_return @ c80b94d3aa36
\* SOURCE: apps/fermix_core/lib/fermix_core/application.ex#prepare_home,finish_activation,finish_return @ e3ec83bb1ff3
\* SOURCE: apps/fermix_core/lib/fermix_core/home/return.ex#done,record_done,write,remove @ fa5374582cd1
\* SOURCE: apps/fermix_core/lib/fermix_core/home/moved.ex#write,exclusive_write,read,remove @ 27b13b295c9c
\* SOURCE: apps/fermix_core/lib/fermix_core/home/role.ex#resolve,primary,configured_role @ 6b56d83c809d
\* SOURCE: apps/fermix_core/lib/fermix_core/home/move.ex#start,pending?,@pending,max_attempts,@max_attempts,finish_at_boot,finish_due,ending,finish @ 84b4f8c190f1
\* SOURCE: apps/fermix_core/lib/fermix_core/management/home_move.ex#move_start @ 81c5ae5fa852
\* SOURCE: apps/fermix_core/lib/fermix_core/management/placement.ex#unconfirmed_on_loss?,unconfirmed,@unconfirmed_methods @ 0881001a46d0
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/relay.ex#lost_answer @ dfb459724267
\* SOURCE: apps/fermix_core/lib/fermix_core/management/provision.ex#delete,delete_target,return_fence?,server_silent?,not_holding,run_delete,returned_deleted,start_return_restore,run_return_restore,fenced_restore,fence,fence_delete,fenced_before,fenced,fence_failed @ cfb854f4d22d
\* SOURCE: apps/fermix_core/lib/fermix_core/home/provision/driver.ex#delete @ 4074091d2c54
\* SOURCE: apps/fermix_core/lib/fermix_core/management/always_on.ex @ 2766a6974452
\* SOURCE: apps/fermix_core/lib/fermix_core/management/home_summary.ex#screen,target,device,settled,retired,away,away_here,on,returning,return_view,return_ready,return_moving,return_undone,return_stopped,restore_view,return_cancel,restoring,restore_step,fence_failed?,fence_failed,restore_offer,restorable,back,server_retired,started?,stale?,server_move,server_idle?,@before_move,@ended,@server_moves @ 90bdc82a0b6a
\* SOURCE: apps/fermix_core/lib/fermix_core/home/local_return.ex#restore,restored,staged,placed,failed,restart @ b07d4dc0d235
EXTENDS Naturals

CONSTANTS
    \* Environment switches: what may happen around the return.
    MessagesCanBeLost,  \* a rail loses a request or an answer, an answer comes only after
                        \* the worker stopped waiting (await_any/3, move_worker.ex:742-756),
                        \* or the forwarded home.move.start is lost, before or after the
                        \* server had it (both unconfirmed, placement.ex:185-205): at
                        \* most MaxLosses times in all
    MaxLosses,
    ServerCanCrash,     \* the server's engine dies while its worker runs, and boots again
    MacCanCrash,        \* the Mac's device engine dies and boots again
    MaxCrashes,         \* how often each engine may crash
    TransferCanFail,    \* the Mac's staging fails (restored/2's error clause: a keychain
                        \* that refuses, a restore that fails), or the server's ready
                        \* epoch or marker cannot be written (commit/4 aborts)
    NetCanFail,         \* the network between the Mac and its server fails, for good:
                        \* the link and every rail with it (the server may still run)
    DeleteCanFail,      \* the provider refuses a delete (a revoked token, an API down)
    MaxPresses,         \* the owner's presses on the Mac's Always On screen (a bound)
    \* Mechanism switches: what the code, or the design, does about it. TRUE is
    \* the real order.
    MarkerBeforeCommit,  \* the server writes its moved.json and records committing before
                         \* it sends move_commit (commit/4, retired/4,
                         \* move_worker.ex:420-442)
    MarkerBeforeConfig,  \* the Mac's activation removes its moved.json (step e) before it
                         \* renames the staged config.toml into place (step f)
                         \* (activate/3, activation.ex:210-225)
    RecordEntries,       \* the staged entries are recorded once, in
                         \* candidate/entries.json, before any rename, and every run reads
                         \* them back (record_entries/1, activation.ex:147-156; activate/1,
                         \* candidate.ex:627-630); FALSE lists the staging again at each
                         \* run, as the forward activate/1 does
    PruneRetired,        \* step a sets aside every path of the retired copy the entries
                         \* do not name and this machine does not keep (prune_retired/3,
                         \* activation.ex:375-411)
    DeleteBeforeRestore, \* the return_restore job deletes the server (the fence) before
                         \* it stages anything, and restores nothing when the delete is
                         \* refused (run_return_restore/4, fenced_restore/3,
                         \* provision.ex:940-949); FALSE restores first
    DeleteOfferedOnlyBack, \* the summary offers Delete your server on this computer only
                           \* once return.json has moved_at (back/1, home_summary.ex:
                           \* 1201-1210); FALSE offers it on any screen while the ledger's
                           \* server stands, leaving the delete to delete_target/4 alone
    UnconfirmedKept,     \* Move now on a return keeps move_started_at when the forwarded
                         \* home.move.start is answered unconfirmed too
                         \* (return_answered/3, always_on.ex:518-524), as a replace's
                         \* Provision.move_forwarded/3 does; FALSE keeps it only on
                         \* {ok, move_id}
    StartKeptFirst       \* Move now writes move_started_at before it forwards
                         \* home.move.start (return_start_ahead/2, always_on.ex:503-516),
                         \* and the answer settles it; FALSE is the design's draft 2, which
                         \* writes it after the answer (finding HR-1, fixed)

VARIABLES
    \* The server: files under its home.
    sRole,      \* config.toml's role: "primary" | "device"
    sMoved,     \* its moved.json exists
    sPhase,     \* .move/phase.json's phase, "none" before home.move.start
    sAttempts,  \* .move/phase.json's attempts
    \* The server: its running engine, and whether it exists at all.
    sBoot,      \* the role its engine booted in (Role.resolve/2)
    sAlive,     \* the server exists (FALSE once a delete through the ledger removed it)
    wpc,        \* where its move worker is; "off" when none runs
    \* The rail between the server's worker and the Mac's candidate.
    railUp,     \* the worker's current rail is open at both ends
    req,        \* the request on it the candidate has not handled yet
    rep,        \* the answer on it the worker has not taken yet
    \* The Mac: files under its home.
    mCfg,       \* config.toml's role: "device" (the retired copy's) | "primary" (the staged one's)
    mMarker,    \* moved.json exists
    mLink,      \* device/desktop.json exists
    mDb,        \* what the home holds at a staged entry's name: "retired" (the retired
                \* copy's), "staged" (the staging's), "none", or "fresh" (made by a
                \* primary boot that found none: the memory repo creates the file)
    mStale,     \* the home still holds a path only the retired copy has (a file the
                \* server deleted)
    rj,         \* device/return.json: "none"; "asked" (Move back); "started"
                \* (move_started_at); "fence" (fence_requested, Restore here);
                \* "fenced" (and fenced_at, once the fence deleted the server); "back"
                \* (moved_at, written by the primary's boot)
    cPhase,     \* candidate/state.json's phase, "none" when candidate/ is absent;
                \* "failed" only for a local one whose staging failed
    cKind,      \* its kind: "return" (the rail's) | "local" (from a copy)
    cRec,       \* candidate/entries.json exists
    stDb,       \* candidate/staging holds the staged entry
    stCfg,      \* candidate/staging holds config.toml
    ledger,     \* the provider ledger's server: "standing" | "gone"
    \* The Mac: its running engine.
    mBoot,      \* the role its engine booted in: "device" | "primary" | "refused"
    cUp,        \* the candidate subtree runs (its process, and for a return its listener)
    restore,    \* the restore task in flight, by the rail its answer goes to
    apc,        \* where a return's activation is: "idle", "rec", "a", "b_aside",
                \* "b_place", "c", "d", "e", "f", "g"
    aOwner,     \* who runs it: "cand" (the candidate process) | "job" (return_restore)
    aTo,        \* the rail the activation answers on: "none" | "cur" | "gone"
    activated,  \* the candidate process put the home in place and waits for its restart
    act,        \* where the act the serializer runs (or the job it started) is; "idle"
    \* Budgets.
    net,        \* the network between the Mac and its server works
    losses,     \* messages lost or late so far
    sCrashes,   \* server crashes so far
    mCrashes,   \* Mac crashes so far
    presses,    \* the owner's presses so far
    \* History, for the properties.
    badDelete,    \* a delete removed the server without moved_at, and not as the fence
                  \* before any staging
    doneLost,     \* a move_done was lost, or came after the worker stopped waiting
    crashEF,      \* the Mac's engine died after step e and before step f
    deletedAfter, \* Delete your server removed the server after the return
    fromCopy      \* the Mac restarted from a copy restored here

srvFiles == <<sRole, sMoved, sPhase, sAttempts>>
srvRun   == <<sBoot, sAlive, wpc>>
rail     == <<railUp, req, rep>>
macFiles == <<mCfg, mMarker, mLink, mDb, mStale, rj, cPhase, cKind, cRec, stDb, stCfg, ledger>>
macRun   == <<mBoot, cUp, restore, apc, aOwner, aTo, activated, act>>
budgets  == <<net, losses, sCrashes, mCrashes, presses>>
hist     == <<badDelete, doneLost, crashEF, deletedAfter, fromCopy>>
vars     == <<srvFiles, srvRun, rail, macFiles, macRun, budgets, hist>>

\* The Mac's running parts a rail step leaves alone (restore and aTo name rails).
macHold  == <<mBoot, cUp, apc, aOwner, activated, act>>

MaxAttempts == 3    \* @max_attempts (move.ex:68)

Pending  == {"requested", "streaming", "committing", "aborting"}  \* @pending (move.ex:71)
Phases   == Pending \cup {"none", "committed", "done", "undoing", "aborted"}
Awaiting == {"await_accept", "await_ready", "await_done", "await_resume", "await_done_r"}
WorkerStates ==
    {"off", "run", "transfer", "offer", "await_accept", "await_ready", "retire",
     "send_commit", "await_done", "finish", "restart", "resume", "resume_dial",
     "await_resume", "await_done_r", "abort", "undo", "undo_role"}
ActSteps ==
    {"idle", "mb_prepare", "mb_record", "mb_start", "mn_mark", "mn_forward", "mn_record",
     "mn_unmark", "cx_stop",
     "cx_remove", "cx_forget", "ds_delete", "ds_fenced", "ds_clear", "rh_fence",
     "rh_delete", "rh_fenced", "rh_prepare", "rh_stage", "rh_activating", "rh_activate",
     "rh_restart"}
Actions == {"move_back", "move_now", "cancel", "delete_server", "restore_here"}

ASSUME MaxLosses \in Nat /\ MaxCrashes \in Nat /\ MaxPresses \in Nat

TypeOK ==
    /\ sRole \in {"primary", "device"} /\ sMoved \in BOOLEAN /\ sPhase \in Phases
    /\ sAttempts \in 0..MaxAttempts
    /\ sBoot \in {"primary", "device", "refused"} /\ sAlive \in BOOLEAN /\ wpc \in WorkerStates
    /\ railUp \in BOOLEAN
    /\ req \in {"none", "offer", "stream", "commit", "resume"}
    /\ rep \in {"none", "accept", "ready", "done", "error"}
    /\ mCfg \in {"device", "primary"} /\ mMarker \in BOOLEAN /\ mLink \in BOOLEAN
    /\ mDb \in {"retired", "staged", "none", "fresh"} /\ mStale \in BOOLEAN
    /\ rj \in {"none", "asked", "started", "fence", "fenced", "back"}
    /\ cPhase \in {"none", "enrolling", "enrolled", "receiving", "staged", "activating",
                  "failed"}
    /\ cKind \in {"return", "local"} /\ cRec \in BOOLEAN /\ stDb \in BOOLEAN
    /\ stCfg \in BOOLEAN /\ ledger \in {"standing", "gone"}
    /\ mBoot \in {"device", "primary", "refused"} /\ cUp \in BOOLEAN
    /\ restore \in {"none", "cur", "gone"}
    /\ apc \in {"idle", "rec", "a", "b_aside", "b_place", "c", "d", "e", "f", "g"}
    /\ aOwner \in {"cand", "job"} /\ aTo \in {"none", "cur", "gone"}
    /\ activated \in BOOLEAN /\ act \in ActSteps
    /\ net \in BOOLEAN /\ losses \in 0..MaxLosses /\ sCrashes \in 0..MaxCrashes
    /\ mCrashes \in 0..MaxCrashes /\ presses \in 0..MaxPresses
    /\ badDelete \in BOOLEAN /\ doneLost \in BOOLEAN /\ crashEF \in BOOLEAN
    /\ deletedAfter \in BOOLEAN /\ fromCopy \in BOOLEAN

-----------------------------------------------------------------------------
(* Shared pieces *)

\* Role.resolve/2 (role.ex:191-201) at a boot: a configured device is a
\* device whatever the marker says; a configured primary beside a marker is
\* refused, and that engine never runs.
Resolve(r, m) == IF r = "device" THEN "device" ELSE IF m THEN "refused" ELSE "primary"

\* The server answers as the primary over the network: the Mac's link
\* (Desktop.Relay) reaches it and the candidate's enrolment can.
ServerAnswers == net /\ sAlive /\ sBoot = "primary"

\* The Mac's link is up: its device engine's relay holds a session with the
\* primary. Forwarded requests travel on it.
LinkUp == mBoot = "device" /\ mLink /\ ServerAnswers

\* The server's worker can dial the Mac's candidate: its subtree runs under
\* the device tree with its own listening helper (CandidateSupervisor), which
\* a return's candidate has and a local one does not.
Listening == net /\ mBoot = "device" /\ cUp /\ cKind = "return"

\* The candidate process takes one call at a time, and none while its
\* commit_move/2 is still putting the home in place.
CandIdle == mBoot = "device" /\ cUp /\ apc = "idle"

\* The worker leaves the rail it holds, if any, and opens a new one carrying
\* newReq, or none. A request on the rail it left is lost here; an answer on
\* it, or one a restore or an activation would give on it, reaches no one.
MoveOn(newReq, up) ==
    /\ req' = newReq
    /\ rep' = "none"
    /\ railUp' = up
    /\ restore' = IF restore = "cur" THEN "gone" ELSE restore
    /\ aTo' = IF aTo = "cur" THEN "gone" ELSE aTo

CloseRail == MoveOn("none", FALSE)

\* The candidate's responder answers a on the rail tag names.
Answer(tag, a) == rep' = IF tag = "cur" THEN a ELSE rep

\* Something will still arrive on the worker's rail.
Coming == req # "none" \/ restore = "cur" \/ aTo = "cur"
NothingComing == ~Coming /\ rep = "none"

\* Where a failed wait goes: another attempt before move_ready
\* (attempt_failed/2, move_worker.ex:228-235), the resume after the commit
\* (retired/4, :437-441), the next round of the resume loop (resume_loop/4,
\* :519-536).
AfterAwait(w) == CASE w \in {"await_accept", "await_ready"} -> "transfer"
                   [] w = "await_done" -> "resume"
                   [] OTHER -> "resume_dial"

\* The server's engine boots from its files: after its worker's deliberate
\* restart or a crash. The worker runs only on a device boot with a move
\* pending (device_supervisor.ex:81-98, Move.pending?/1). The boot says the
\* ending the engine before it left half-said (Move.finish_at_boot/2): a
\* device boot turns committed into done, a primary boot turns undoing, or
\* an aborting a crash cut short after the role write, into aborted. Its
\* rails end with it.
ServerBoots ==
    LET b == Resolve(sRole, sMoved) IN
    /\ sBoot' = b
    /\ wpc' = IF b = "device" /\ sPhase \in Pending THEN "run" ELSE "off"
    /\ sPhase' = CASE b = "device" /\ sPhase = "committed" -> "done"
                   [] b = "primary" /\ sPhase \in {"undoing", "aborting"} -> "aborted"
                   [] OTHER -> sPhase
    /\ MoveOn("none", FALSE)

\* The provider deletes the server (Driver.delete/3): it serves nothing and
\* runs nothing from then on, and the ledger says it is gone.
ServerDeleted ==
    /\ sAlive' = FALSE
    /\ wpc' = "off"
    /\ ledger' = "gone"
    /\ MoveOn("none", FALSE)

-----------------------------------------------------------------------------
(* The server and its move worker, as home_move models them *)

WGoto(w) ==
    /\ wpc' = w
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, rail, macFiles, macRun, budgets, hist>>

\* run/1 (move_worker.ex:116-129) and carry_on/3 (:147-156): the marker
\* first, then the phase.
Run ==
    /\ wpc = "run"
    /\ WGoto(IF sMoved THEN "resume" ELSE IF sPhase = "aborting" THEN "abort" ELSE "transfer")

\* transfer/1 (move_worker.ex:186-196): counts the attempt, or aborts once
\* MaxAttempts were made, across restarts. The rail a failed attempt closed
\* (close_rail/1, :208) is closed here, the worker's next step.
Transfer ==
    /\ wpc = "transfer"
    /\ IF sAttempts >= MaxAttempts
       THEN /\ wpc' = "abort" /\ UNCHANGED <<sAttempts, sPhase>>
       ELSE /\ sAttempts' = sAttempts + 1 /\ sPhase' = "streaming" /\ wpc' = "offer"
    /\ CloseRail
    /\ UNCHANGED <<sRole, sMoved, sBoot, sAlive, macFiles, macHold, budgets, hist>>

\* attempt_transfer/1 (move_worker.ex:198-214): the capture (no desktop key
\* or row for a source not kept as a desktop), open_candidate/1 (:709-723)
\* to the Mac's candidate, and move_offer (stream/3, :361-381).
SendOffer ==
    /\ wpc = "offer" /\ Listening
    /\ wpc' = "await_accept"
    /\ MoveOn("offer", TRUE)
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, macFiles, macHold, budgets, hist>>

\* No candidate answers the dial (the Mac's engine is not a device running
\* its candidate, or the network is down): attempt_failed/2 sleeps and tries
\* again (move_worker.ex:212, :228-235).
DialFails ==
    /\ wpc = "offer" /\ ~Listening
    /\ wpc' = "transfer"
    /\ MoveOn("none", FALSE)
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, macFiles, macHold, budgets, hist>>

\* await(rail, "move_accept"), then the chunks and move_end (stream/3,
\* move_worker.ex:374-378): one "stream" request stands for them all.
TakeAccept ==
    /\ wpc = "await_accept" /\ rep = "accept"
    /\ rep' = "none"
    /\ req' = IF railUp THEN "stream" ELSE "none"
    /\ wpc' = "await_ready"
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, railUp, macFiles, macRun, budgets, hist>>

\* await(rail, "move_ready") (stream/3, move_worker.ex:379), then commit/4.
TakeReady ==
    /\ wpc = "await_ready" /\ rep = "ready"
    /\ rep' = "none"
    /\ wpc' = IF MarkerBeforeCommit THEN "retire" ELSE "send_commit"
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, railUp, req, macFiles, macRun, budgets, hist>>

\* An error event is a refusal (await_any/3, move_worker.ex:744-745): before
\* move_ready it aborts the move (attempt_failed/2, :216-217); after it,
\* retired/4 resumes (:437-441) and the resume loop goes round again.
TakeRefusal ==
    /\ wpc \in Awaiting /\ rep = "error"
    /\ rep' = "none"
    /\ wpc' = IF wpc \in {"await_accept", "await_ready"} THEN "abort" ELSE AfterAwait(wpc)
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, railUp, req, macFiles, macRun, budgets, hist>>

\* The wait's timeout, or the rail's {:closed, _} (await_any/3,
\* move_worker.ex:750-753), when nothing can arrive any more.
GiveUp ==
    /\ wpc \in Awaiting /\ NothingComing
    /\ WGoto(AfterAwait(wpc))

\* commit/4 (move_worker.ex:420-429): the ready epoch (a file no rule reads),
\* then retire/1 writes moved.json (:452-465); retired/4 records committing
\* (:432-433), one step here: a crash anywhere among them boots a device that
\* resumes once the marker exists, and transfers again before. Without
\* MarkerBeforeCommit, move_commit goes first.
Retire ==
    /\ wpc = "retire"
    /\ sMoved' = TRUE
    /\ sPhase' = "committing"
    /\ wpc' = IF MarkerBeforeCommit THEN "send_commit" ELSE "await_done"
    /\ UNCHANGED <<sRole, sAttempts, sBoot, sAlive, rail, macFiles, macRun, budgets, hist>>

\* move_commit on the same rail (retired/4, move_worker.ex:434), then await
\* move_done (:435).
SendCommit ==
    /\ wpc = "send_commit"
    /\ req' = IF railUp THEN "commit" ELSE "none"
    /\ wpc' = IF MarkerBeforeCommit THEN "await_done" ELSE "retire"
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, railUp, rep, macFiles, macRun, budgets, hist>>

\* move_done (retired/4 :435; resumed/3 :555-561).
TakeDone ==
    /\ wpc \in {"await_done", "await_resume", "await_done_r"} /\ rep = "done"
    /\ rep' = "none"
    /\ wpc' = "finish"
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, railUp, req, macFiles, macRun, budgets, hist>>

\* done/2 (move_worker.ex:642-656): record committed, then restart, after
\* which the server boots as a device with no link and serves nothing.
Finish ==
    /\ wpc = "finish"
    /\ sPhase' = "committed"
    /\ wpc' = "restart"
    /\ UNCHANGED <<sRole, sMoved, sAttempts, sBoot, sAlive, rail, macFiles, macRun, budgets, hist>>

SelfRestart ==
    /\ wpc = "restart"
    /\ ServerBoots
    /\ UNCHANGED <<sRole, sMoved, sAttempts, sAlive, macFiles, macHold, budgets, hist>>

\* resume/1 (move_worker.ex:498-511): record committing, then the loop. A
\* failed commit closed its rail first (retired/4, :439): folded in here.
Resume ==
    /\ wpc = "resume"
    /\ sPhase' = "committing"
    /\ wpc' = "resume_dial"
    /\ CloseRail
    /\ UNCHANGED <<sRole, sMoved, sAttempts, sBoot, sAlive, macFiles, macHold, budgets, hist>>

\* resume_once/2 (move_worker.ex:538-543): open_candidate/1, then
\* move_resume (resume_on/2, :545-553). with_rail/2 closed the previous
\* round's rail (:586-590): folded in here.
ResumeDial ==
    /\ wpc = "resume_dial" /\ Listening
    /\ wpc' = "await_resume"
    /\ MoveOn("resume", TRUE)
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, macFiles, macHold, budgets, hist>>

\* No candidate answers. A source not kept as a desktop has no desktop key
\* to probe the moved identity with (probe_primary/2, :565-576, finds no
\* link), so the loop sleeps and dials again, for 24 hours (a bound not
\* modelled: it then records a sentence and stops, changing no file a rule
\* reads).
ResumeDialFails ==
    /\ wpc = "resume_dial" /\ ~Listening
    /\ MoveOn("none", FALSE)
    /\ UNCHANGED <<srvFiles, srvRun, macFiles, macHold, budgets, hist>>

\* move_ready answers move_resume: still staged, so commit now (resumed/3,
\* move_worker.ex:557-561).
TakeResumeReady ==
    /\ wpc = "await_resume" /\ rep = "ready"
    /\ rep' = "none"
    /\ req' = IF railUp THEN "commit" ELSE "none"
    /\ wpc' = "await_done_r"
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, railUp, macFiles, macRun, budgets, hist>>

\* abort/3 (move_worker.ex:658-664): reads the marker again; with it,
\* resume. A refused attempt or a failed commit closed its rail first.
Abort ==
    /\ wpc = "abort"
    /\ wpc' = IF sMoved THEN "resume" ELSE "undo"
    /\ CloseRail
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, macFiles, macHold, budgets, hist>>

\* undo/3 (move_worker.ex:666-685): record aborting; then role primary, the
\* request removed and undoing recorded, one step here (a crash between the
\* role and undoing boots the primary, which records aborted either way), and
\* the restart.
Undo ==
    /\ wpc = "undo"
    /\ sPhase' = "aborting"
    /\ wpc' = "undo_role"
    /\ UNCHANGED <<sRole, sMoved, sAttempts, sBoot, sAlive, rail, macFiles, macRun, budgets, hist>>

UndoRole ==
    /\ wpc = "undo_role"
    /\ sRole' = "primary"
    /\ sPhase' = "undoing"
    /\ wpc' = "restart"
    /\ UNCHANGED <<sMoved, sAttempts, sBoot, sAlive, rail, macFiles, macRun, budgets, hist>>

-----------------------------------------------------------------------------
(* The Mac's candidate: FermixChannels.Home.Candidate under the device tree *)

\* move_offer -> offer_move/2 (candidate.ex:432-440): enrolled, receiving or
\* staged takes it (fenced_offer/2, :447-454: every offer here is later than
\* the one held), accept_offer/2 (:461-483) discards any staging and records
\* receiving. Any other phase, or a home already in place, refuses it.
OnOffer(tag) ==
    IF ~activated /\ cPhase \in {"enrolled", "receiving", "staged"}
    THEN /\ cPhase' = "receiving" /\ stDb' = FALSE /\ stCfg' = FALSE
         /\ Answer(tag, "accept")
         /\ UNCHANGED <<restore, apc, aOwner, aTo, activated>>
    ELSE /\ Answer(tag, "error")
         /\ UNCHANGED <<cPhase, stDb, stCfg, restore, apc, aOwner, aTo, activated>>

\* move_end -> stage_move/3 (candidate.ex:518-536): a receiving candidate
\* starts the restore task (stage_fun/4, :539-542: Activation.stage/6 for a
\* return); the answer waits for it (move_responder.ex:65-69).
OnStream(tag) ==
    IF cPhase = "receiving" /\ ~activated
    THEN /\ restore' = tag /\ UNCHANGED rep
         /\ UNCHANGED <<cPhase, stDb, stCfg, apc, aOwner, aTo, activated>>
    ELSE /\ Answer(tag, "error")
         /\ UNCHANGED <<cPhase, stDb, stCfg, restore, apc, aOwner, aTo, activated>>

\* move_commit -> commit_move/2 (candidate.ex:580-611): a second one after the
\* home is in place is answered as the first was; staged or activating,
\* record activating and run the activation in the same call (Activation
\* below), whose end answers. Otherwise move_unknown.
OnCommit(tag) ==
    CASE activated ->
             /\ Answer(tag, "done")
             /\ UNCHANGED <<cPhase, stDb, stCfg, restore, apc, aOwner, aTo, activated>>
      [] cPhase \in {"staged", "activating"} ->
             /\ cPhase' = "activating" /\ apc' = "rec" /\ aOwner' = "cand" /\ aTo' = tag
             /\ UNCHANGED <<rep, stDb, stCfg, restore, activated>>
      [] OTHER ->
             /\ Answer(tag, "error")
             /\ UNCHANGED <<cPhase, stDb, stCfg, restore, apc, aOwner, aTo, activated>>

\* move_resume (candidate.ex:225-243, move_responder.ex:126-143): staged
\* answers move_ready, a home in place move_done, anything else is refused.
OnResume(tag) ==
    /\ CASE activated -> Answer(tag, "done")
         [] cPhase = "staged" -> Answer(tag, "ready")
         [] OTHER -> Answer(tag, "error")
    /\ UNCHANGED <<cPhase, stDb, stCfg, restore, apc, aOwner, aTo, activated>>

\* The responder of the worker's rail hands its request to the candidate.
Handle ==
    /\ CandIdle /\ req # "none"
    /\ req' = "none"
    /\ CASE req = "offer" -> OnOffer("cur")
         [] req = "stream" -> OnStream("cur")
         [] req = "commit" -> OnCommit("cur")
         [] req = "resume" -> OnResume("cur")
    /\ UNCHANGED <<srvFiles, srvRun, railUp, mCfg, mMarker, mLink, mDb, mStale, rj, cKind,
                   cRec, ledger, mBoot, cUp, act, budgets, hist>>

\* The restore task's result -> restored/2 (candidate.ex:547-553): the
\* staging is complete (the server's copy, settled for this computer), staged
\* is recorded, and the responder that staged it answers move_ready.
Restored ==
    /\ CandIdle /\ restore # "none"
    /\ cPhase' = "staged" /\ stDb' = TRUE /\ stCfg' = TRUE
    /\ restore' = "none"
    /\ Answer(restore, "ready")
    /\ UNCHANGED <<srvFiles, srvRun, railUp, req, mCfg, mMarker, mLink, mDb, mStale, rj, cKind,
                   cRec, ledger, mBoot, cUp, apc, aOwner, aTo, activated, act, budgets, hist>>

\* The enrolment (enroll_once/1 and enrolled/2, candidate.ex:331-377): the
\* candidate reaches the server as the primary, which adds it.
Enroll ==
    /\ CandIdle /\ cKind = "return" /\ cPhase = "enrolling" /\ ServerAnswers
    /\ cPhase' = "enrolled"
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, rj, cKind, cRec,
                   stDb, stCfg, ledger, macRun, budgets, hist>>

-----------------------------------------------------------------------------
(* A return's activation: Activation.record_entries/1 and activate/3       *)
(* (activation.ex:147-156, :210-225), one durable write per step, run by   *)
(* the candidate process on move_commit or at its start in activating      *)
(* (carry_on/1, finish_activation/1, activate/1: candidate.ex:191-201,     *)
(* :613-630), or by the return_restore job.                                *)

\* Whether the run places the staged entry: the recorded entries, or, without
\* RecordEntries, the staging as listed now.
Placing == IF RecordEntries THEN cRec ELSE stDb

\* The one running the activation is still alive.
OwnerAlive == mBoot = "device" /\ (IF aOwner = "job" THEN act = "rh_activate" ELSE cUp)

AStep(from, to) == apc = from /\ OwnerAlive /\ apc' = to

ARest == <<srvFiles, srvRun, rail, mBoot, cUp, restore, aOwner, aTo, activated, act, budgets, hist>>

\* record_entries/1: the staged top-level names, once, in entries.json
\* (written only while the staged config.toml is there, refused as
\* :nothing_staged otherwise); a later run reads them back.
ARecord ==
    /\ AStep("rec", "a")
    /\ RecordEntries => (cRec \/ stCfg)
    /\ cRec' = (cRec \/ (RecordEntries /\ stCfg))
    /\ UNCHANGED <<mCfg, mMarker, mLink, mDb, mStale, rj, cPhase, cKind, stDb, stCfg, ledger,
                   ARest>>

\* a. prune_retired/3 (activation.ex:375-411): every top-level path that is no
\* recorded entry, candidate, config.toml or moved.json is pruned in place:
\* what this machine keeps stays, the rest goes into candidate/replaced/.
APrune ==
    /\ AStep("a", "b_aside")
    /\ IF PruneRetired
       THEN /\ mStale' = FALSE
            /\ mDb' = IF Placing THEN mDb ELSE "none"
       ELSE UNCHANGED <<mStale, mDb>>
    /\ UNCHANGED <<mCfg, mMarker, mLink, rj, cPhase, cKind, cRec, stDb, stCfg, ledger, ARest>>

\* b. place_returned/4 (activation.ex:414-435), for a recorded entry still
\* staged: this computer's copy set aside with its -wal and -shm, then the
\* staged one renamed into place; one gone from the staging was placed by an
\* earlier run and is skipped.
BAside ==
    /\ AStep("b_aside", "b_place")
    /\ mDb' = IF Placing /\ stDb THEN "none" ELSE mDb
    /\ UNCHANGED <<mCfg, mMarker, mLink, mStale, rj, cPhase, cKind, cRec, stDb, stCfg, ledger,
                   ARest>>

BPlace ==
    /\ AStep("b_place", "c")
    /\ IF Placing /\ stDb
       THEN mDb' = "staged" /\ stDb' = FALSE
       ELSE UNCHANGED <<mDb, stDb>>
    /\ UNCHANGED <<mCfg, mMarker, mLink, mStale, rj, cPhase, cKind, cRec, stCfg, ledger, ARest>>

\* c. end_tenure/1 (activation.ex:468-469): device/desktop.json and
\* device/desktop_key go.
CTenure ==
    /\ AStep("c", "d")
    /\ mLink' = FALSE
    /\ UNCHANGED <<mCfg, mMarker, mDb, mStale, rj, cPhase, cKind, cRec, stDb, stCfg, ledger, ARest>>

\* d. Status.write(run_at_boot: true): a file no rule reads.
DStatus ==
    /\ AStep("d", IF MarkerBeforeConfig THEN "e" ELSE "f")
    /\ UNCHANGED <<macFiles, ARest>>

\* e. Moved.remove/1 (moved.ex:69-77): the marker goes; the server's exists,
\* since it sent move_commit after writing it.
EMarker ==
    /\ AStep("e", IF MarkerBeforeConfig THEN "f" ELSE "g")
    /\ mMarker' = FALSE
    /\ UNCHANGED <<mCfg, mLink, mDb, mStale, rj, cPhase, cKind, cRec, stDb, stCfg, ledger, ARest>>

\* f. place_return_config/2 (activation.ex:472-478): staging/config.toml
\* renamed to config.toml, the Mac's commit point; done already when an
\* earlier run renamed it.
FConfig ==
    /\ AStep("f", IF MarkerBeforeConfig THEN "g" ELSE "e")
    /\ IF stCfg
       THEN mCfg' = "primary" /\ stCfg' = FALSE
       ELSE UNCHANGED <<mCfg, stCfg>>
    /\ UNCHANGED <<mMarker, mLink, mDb, mStale, rj, cPhase, cKind, cRec, stDb, ledger, ARest>>

\* g. candidate/ removed, replaced/ and entries.json with it. The candidate
\* process then answers (commit_move/2's :ok, candidate.ex:593-598: the
\* responder sends move_done) and schedules its restart; the job goes on to
\* its restart. A crash after g ends the rail, which loses an answer as
\* surely as one never sent.
GDone ==
    /\ apc = "g" /\ OwnerAlive
    /\ apc' = "idle"
    /\ cPhase' = "none" /\ cRec' = FALSE /\ stDb' = FALSE /\ stCfg' = FALSE
    /\ IF aOwner = "job"
       THEN /\ act' = IF DeleteBeforeRestore THEN "rh_restart" ELSE "rh_delete"
            /\ UNCHANGED <<rep, aTo, activated>>
       ELSE /\ activated' = TRUE /\ aTo' = "none"
            /\ Answer(aTo, "done")
            /\ UNCHANGED act
    /\ UNCHANGED <<srvFiles, srvRun, railUp, req, mCfg, mMarker, mLink, mDb, mStale, rj, cKind,
                   ledger, mBoot, cUp, restore, aOwner, budgets, hist>>

-----------------------------------------------------------------------------
(* The Mac's engine: its boots *)

\* The Mac's engine boots from its files (Role.resolve/2): after the
\* candidate's restart, the job's, or a crash. Its acts, its job and its
\* restore task die with the engine before it; its rails end. A device boot
\* starts the candidate subtree when candidate/ exists
\* (DeviceSupervisor.children/1), whose process carries on (carry_on/1,
\* candidate.ex:191-201): activating finishes the activation; a local
\* candidate in any other phase is removed (drop_local/1, :638-648). A
\* primary boot runs prepare_home (application.ex:201-246) first:
\* finish_activation/1 removes a candidate whose settings are in place
\* (activation.ex:249-262), and Return.done/2 records moved_at
\* (return.ex:118-133); then the memory repo opens memory.db, making a fresh
\* one where there is none.
MacBoots ==
    LET b == Resolve(mCfg, mMarker)
        placed == b = "primary" /\ cPhase = "activating" /\ ~stCfg
        dropLocal == b = "device" /\ cKind = "local" /\ cPhase \notin {"none", "activating"}
    IN
    /\ mBoot' = b
    /\ act' = "idle" /\ activated' = FALSE /\ restore' = "none" /\ aTo' = "none"
    /\ req' = "none" /\ rep' = "none" /\ railUp' = FALSE
    /\ doneLost' = (doneLost \/ rep = "done")
    /\ cUp' = (b = "device" /\ cPhase # "none" /\ ~dropLocal)
    /\ apc' = IF b = "device" /\ cPhase = "activating" THEN "rec" ELSE "idle"
    /\ aOwner' = "cand"
    /\ IF placed \/ dropLocal
       THEN cPhase' = "none" /\ cRec' = FALSE /\ stDb' = FALSE /\ stCfg' = FALSE
       ELSE UNCHANGED <<cPhase, cRec, stDb, stCfg>>
    /\ rj' = IF b = "primary" /\ rj # "none" THEN "back" ELSE rj
    /\ mDb' = IF b = "primary" /\ mDb = "none" THEN "fresh" ELSE mDb
    /\ UNCHANGED <<mCfg, mMarker, mLink, mStale, cKind, ledger>>

\* handle_info(:restart) (candidate.ex:271-275) -> Lifecycle.restart_self/0,
\* scheduled once the home is in place.
CandRestart ==
    /\ CandIdle /\ activated
    /\ MacBoots
    /\ UNCHANGED <<srvFiles, srvRun, budgets, badDelete, crashEF, deletedAfter, fromCopy>>

-----------------------------------------------------------------------------
(* The Mac's acts: home.act through Management.AlwaysOn, from the design   *)

\* returning/1 (home_summary.ex:1052-1067), the first clause of the
\* device's summary (device/1, :772): any candidate of this computer's, or,
\* with none, return.json with move_started_at and no moved_at. (The stale
\* check against a newer epoch the link reached needs a second desktop: not
\* modelled.)
Returning == cPhase # "none" \/ rj = "started"

\* The server answers as the primary (its part of the composed home.status)
\* and has undone the move, or has no move at all (server_idle?/1, :1234-1237;
\* @server_moves).
ServerAborted == LinkUp /\ sPhase = "aborted"
ServerIdle == LinkUp /\ sPhase = "none"

\* Restore here (restore_offer/1, :1172-1178): this computer holds a copy
\* (always, here), no replace runs, and the ledger has the server, or the
\* fence deleted it (fenced_at).
RestoreOffer == IF ledger = "standing" \/ rj = "fenced" THEN {"restore_here"} ELSE {}

\* What returning/1 offers (return_view/2, :1069-1111; return_stopped/1,
\* :1113-1116; restore_view/2, :1118-1130):
\*  - a started record with no candidate: moving, nothing;
\*  - a local candidate: moving, or, failed, return_failed with Restore here;
\*  - a return candidate with no record at all (a stop between Move back's
\*    writes): return_stopped, Cancel;
\*  - enrolling: creating, Cancel;
\*  - enrolled, no start recorded: ready, Move now and Cancel; started and
\*    the server undid it: undone, Cancel (Try again is not modelled);
\*    started and the server answers with no move: ready again; otherwise
\*    moving, nothing;
\*  - receiving, staged, activating: moving, nothing, whatever the server
\*    says (finding HR-2).
ReturnOffers ==
    CASE cPhase = "none" -> {}
      [] cKind = "local" -> IF cPhase = "failed" THEN RestoreOffer ELSE {}
      [] rj = "none" /\ cPhase \in {"enrolling", "enrolled"} -> {"cancel"}
      [] cPhase = "enrolling" -> {"cancel"}
      [] cPhase = "enrolled" ->
             CASE rj # "started" -> {"move_now", "cancel"}
               [] ServerAborted -> {"cancel"}
               [] ServerIdle -> {"move_now", "cancel"}
               [] OTHER -> {}
      [] OTHER -> {}

\* Not returning (settled/1, :774-785): a desktop whose server answers draws
\* on (on/1, :908-921), which offers Move back (the act refuses it while the
\* server reports a move, which it cannot while it answers as the primary);
\* one whose server does not answer (away_here/1 and retired/1: cannot_reach,
\* turned_off, deleted, retired) offers Restore here beside its own action.
\* Ten minutes of silence are not modelled: the link is down or up.
DeviceOffers ==
    (IF LinkUp THEN {"move_back"} ELSE {})
    \cup (IF ~LinkUp THEN RestoreOffer ELSE {})

\* The actions the Mac's summary offers now (screen/1, :254-256). A primary
\* with moved_at and the ledger's server standing offers Delete your server
\* (back/1 and server_retired/1, :1201-1219).
Offered ==
    LET extra == IF ~DeleteOfferedOnlyBack /\ ledger = "standing"
                 THEN {"delete_server"} ELSE {}
    IN CASE mBoot = "primary" ->
              (IF rj = "back" /\ ledger = "standing" THEN {"delete_server"} ELSE {}) \cup extra
         [] mBoot = "device" ->
              (IF Returning THEN ReturnOffers ELSE DeviceOffers) \cup extra
         [] OTHER -> {}

First(a) == CASE a = "move_back" -> "mb_prepare"
              [] a = "move_now" -> IF StartKeptFirst THEN "mn_mark" ELSE "mn_forward"
              [] a = "cancel" -> "cx_stop"
              [] a = "delete_server" -> "ds_delete"
              [] a = "restore_here" -> "rh_fence"

\* The owner presses an action the summary offers; the serializer takes it
\* and its key rule passes (act/2, find_action/3): one act at a time, and
\* none while the job one started runs (its step's name stands).
Press(a) ==
    /\ act = "idle" /\ presses < MaxPresses /\ a \in Offered
    /\ presses' = presses + 1
    /\ act' = First(a)
    /\ UNCHANGED <<srvFiles, srvRun, rail, macFiles, mBoot, cUp, restore, apc, aOwner, aTo,
                   activated, net, losses, sCrashes, mCrashes, hist>>

AGoto(s) == act' = s

\* Candidate.prepare_return/3 (candidate.ex:144-156, :386-436) writes a
\* return's candidate only on a device engine (supervised: assumed here),
\* beside a home that carries the moved marker, linked for a return of the
\* rail's kind, with no move of its own pending, replacing only a candidate
\* that ended (here a local one that failed); it refuses otherwise.
Preparable(kind) ==
    /\ mBoot = "device" /\ mMarker
    /\ (kind = "return" => mLink)
    /\ cPhase \in {"none", "failed"}

\* Move back (move_back/2, always_on.ex:542-607): the server's move is
\* checked (server_still/1, a press while it reports one refused) and
\* home.enroll.open forwarded and answered, both folded into the press (a link
\* down refuses it there, as Offered does); then Candidate.prepare_return/3
\* renames the built candidate/ into place (enrolling, kind return),
\* return.json is written, and Link.start_return/1 starts the candidate
\* subtree on the running device tree (a start that fails removes both).
MbPrepare ==
    /\ act = "mb_prepare"
    /\ IF Preparable("return")
       THEN /\ AGoto("mb_record")
            /\ cPhase' = "enrolling" /\ cKind' = "return" /\ cRec' = FALSE
            /\ stDb' = FALSE /\ stCfg' = FALSE
       ELSE /\ AGoto("idle")
            /\ UNCHANGED <<cPhase, cKind, cRec, stDb, stCfg>>
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, rj, ledger,
                   mBoot, cUp, restore, apc, aOwner, aTo, activated, budgets, hist>>

MbRecord ==
    /\ act = "mb_record" /\ AGoto("mb_start")
    /\ rj' = "asked"
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, cPhase, cKind,
                   cRec, stDb, stCfg, ledger, mBoot, cUp, restore, apc, aOwner, aTo,
                   activated, budgets, hist>>

MbStart ==
    /\ act = "mb_start" /\ AGoto("idle")
    /\ cUp' = (cPhase # "none")
    /\ UNCHANGED <<srvFiles, srvRun, rail, macFiles, mBoot, restore, apc, aOwner, aTo,
                   activated, budgets, hist>>

\* Move now on a return (forwarded_move/5, always_on.ex:470-486):
\* home.move.start {candidate_id, passphrase, keep_as_desktop: false}
\* forwarded over the link. The server's HomeMove.move_start/3 runs
\* Move.start/5 (request, phase requested, role device) and restarts into the
\* move. Its answer arrives, or is lost (unconfirmed: placement.ex:185-205),
\* after the server had it or before; a link that is down never sent it.
\* With StartKeptFirst (the code: return_start_ahead/2, :503-516) return.json
\* gains move_started_at before the request leaves (MnMark), and the answer
\* settles it (return_answered/3, :518-524): a move id keeps it (adding the
\* move id, a field no rule reads), unconfirmed keeps it (UnconfirmedKept),
\* any other answer takes it back (MnUnmark). Without StartKeptFirst, the
\* design's draft 2: the record after the answer (MnRecord).
MnMark ==
    /\ act = "mn_mark" /\ AGoto("mn_forward")
    /\ rj' = "started"
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, cPhase, cKind,
                   cRec, stDb, stCfg, ledger, mBoot, cUp, restore, apc, aOwner, aTo,
                   activated, budgets, hist>>

MnForward ==
    /\ act = "mn_forward"
    /\ LET kept == IF StartKeptFirst THEN "idle" ELSE "mn_record"
           unsent == IF StartKeptFirst THEN "mn_unmark" ELSE "idle"
       IN IF LinkUp /\ sPhase = "none"
          THEN /\ sPhase' = "requested" /\ sRole' = "device" /\ sBoot' = "device"
               /\ wpc' = "run"
               /\ \/ AGoto(kept) /\ UNCHANGED losses
                  \/ /\ MessagesCanBeLost /\ losses < MaxLosses /\ losses' = losses + 1
                     /\ AGoto(IF UnconfirmedKept THEN kept ELSE unsent)
          ELSE /\ AGoto(unsent)
               /\ UNCHANGED <<sPhase, sRole, sBoot, wpc, losses>>
    /\ UNCHANGED <<sMoved, sAttempts, sAlive, rail, macFiles, mBoot, cUp, restore, apc, aOwner,
                   aTo, activated, net, sCrashes, mCrashes, presses, hist>>

\* The request was sent and lost before the server had it: unconfirmed too.
MnForwardLost ==
    /\ act = "mn_forward" /\ LinkUp /\ sPhase = "none"
    /\ MessagesCanBeLost /\ losses < MaxLosses /\ losses' = losses + 1
    /\ AGoto(IF UnconfirmedKept
             THEN (IF StartKeptFirst THEN "idle" ELSE "mn_record")
             ELSE (IF StartKeptFirst THEN "mn_unmark" ELSE "idle"))
    /\ UNCHANGED <<srvFiles, srvRun, rail, macFiles, mBoot, cUp, restore, apc, aOwner, aTo,
                   activated, net, sCrashes, mCrashes, presses, hist>>

MnRecord ==
    /\ act = "mn_record" /\ AGoto("idle")
    /\ rj' = "started"
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, cPhase, cKind,
                   cRec, stDb, stCfg, ledger, mBoot, cUp, restore, apc, aOwner, aTo,
                   activated, budgets, hist>>

MnUnmark ==
    /\ act = "mn_unmark" /\ AGoto("idle")
    /\ rj' = "asked"
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, cPhase, cKind,
                   cRec, stDb, stCfg, ledger, mBoot, cUp, restore, apc, aOwner, aTo,
                   activated, budgets, hist>>

\* Cancel on a return (cancel_return/1, always_on.ex:609-638):
\* Link.stop_return/0 stops the candidate subtree
\* (DeviceSupervisor.stop_candidate/1: its process is stopped where it is,
\* an activation part-way included, and its rails end); home.enroll.withdraw
\* {kind: manual} is forwarded (nothing here reads the window); then
\* candidate/ (Candidate.remove/1) and return.json (Return.remove/1) go, in
\* that order.
CxStop ==
    /\ act = "cx_stop" /\ AGoto("cx_remove")
    /\ cUp' = FALSE /\ apc' = "idle" /\ restore' = "none" /\ aTo' = "none"
    /\ activated' = FALSE
    /\ req' = "none" /\ rep' = "none" /\ railUp' = FALSE
    /\ doneLost' = (doneLost \/ rep = "done")
    /\ UNCHANGED <<srvFiles, srvRun, macFiles, mBoot, aOwner, budgets, badDelete,
                   crashEF, deletedAfter, fromCopy>>

CxRemove ==
    /\ act = "cx_remove" /\ AGoto("cx_forget")
    /\ cPhase' = "none" /\ cRec' = FALSE /\ stDb' = FALSE /\ stCfg' = FALSE
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, rj, cKind, ledger,
                   mBoot, cUp, restore, apc, aOwner, aTo, activated, budgets, hist>>

CxForget ==
    /\ act = "cx_forget" /\ AGoto("idle")
    /\ rj' = "none"
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, cPhase, cKind,
                   cRec, stDb, stCfg, ledger, mBoot, cUp, restore, apc, aOwner, aTo,
                   activated, budgets, hist>>

\* A delete that is the return's own end, or the fence before any staging:
\* moved_at is recorded, or no candidate, staging or placed settings exist yet.
DeleteAllowed ==
    \/ rj = "back"
    \/ cPhase = "none" /\ ~stDb /\ ~stCfg /\ mCfg = "device"

\* Provision.delete_target/4 (provision.ex:777-807), in order: Restore here's
\* fence (return_fence?/2: fence_requested, no candidate/, the server silent:
\* no link, revoked, or unreachable for the summary's limit); any candidate/,
\* refused moving_back; a linked or marked device, refused (not_holding/2:
\* live_home, with no replace here); otherwise the server that stands.
DeleteTarget ==
    CASE rj \in {"fence", "fenced"} /\ cPhase = "none" /\ ~LinkUp -> "return_fence"
      [] cPhase # "none" -> "moving_back"
      [] mBoot = "device" /\ (mLink \/ mMarker) -> "live_home"
      [] OTHER -> "current"

\* Delete your server: the delete job (Provision.delete/1, provision.ex:756-775,
\* run_delete/4, :825-843). Driver.delete/3 removes the server and clears it
\* from the ledger, or the provider refuses. Then, for :current, return.json
\* goes when it has moved_at (returned_deleted/1, :854-861); for
\* :return_fence, fenced_at is written (fenced/2, :976-987).
DsDelete ==
    /\ act = "ds_delete"
    /\ IF DeleteTarget \in {"current", "return_fence"} /\ ledger = "standing"
       THEN \/ /\ ServerDeleted
               /\ badDelete' = (badDelete \/ ~DeleteAllowed)
               /\ deletedAfter' = (deletedAfter \/ rj = "back")
               /\ AGoto(IF DeleteTarget = "return_fence" THEN "ds_fenced" ELSE "ds_clear")
               /\ UNCHANGED <<doneLost, crashEF, fromCopy>>
            \/ /\ DeleteCanFail /\ AGoto("idle")
               /\ UNCHANGED <<sAlive, wpc, ledger, rail, restore, aTo, hist>>
       ELSE /\ AGoto("idle")
            /\ UNCHANGED <<sAlive, wpc, ledger, rail, restore, aTo, hist>>
    /\ UNCHANGED <<srvFiles, sBoot, mCfg, mMarker, mLink, mDb, mStale, rj, cPhase, cKind, cRec,
                   stDb, stCfg, mBoot, cUp, apc, aOwner, activated, budgets>>

DsClear ==
    /\ act = "ds_clear" /\ AGoto("idle")
    /\ rj' = IF rj = "back" THEN "none" ELSE rj
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, cPhase, cKind,
                   cRec, stDb, stCfg, ledger, mBoot, cUp, restore, apc, aOwner, aTo,
                   activated, budgets, hist>>

DsFenced ==
    /\ act = "ds_fenced" /\ AGoto("idle")
    /\ rj' = "fenced"
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, cPhase, cKind,
                   cRec, stDb, stCfg, ledger, mBoot, cUp, restore, apc, aOwner, aTo,
                   activated, budgets, hist>>

\* Restore here (restore_here/3, always_on.ex:648-664): the copy is chosen
\* first (a wrong passphrase deletes nothing, not modelled), return.json
\* gains fence_requested (restore_record/3, :666-672: the record kept, or a
\* new one), then the return_restore job (Provision.start_return_restore/2,
\* provision.ex:929-946), which is never resumed after a restart:
\*  (1) the fence (fence/4, fence_delete/4, :951-967): with the ledger
\*      holding a server, delete_target/4 must answer :return_fence, else
\*      the job ends and restores nothing; Driver.delete/3 removes the server
\*      and clears it from the ledger, or the provider refuses; then fenced/2
\*      writes fenced_at, a write of its own. With nothing in the ledger
\*      (fenced before) the restore runs alone (fenced_before/2);
\*  (2) to (5) LocalReturn.restore/3 (local_return.ex:91-238):
\*      Candidate.prepare_return(:local), Activation.stage of the copy (a
\*      failure records failed and ends the job), activating recorded,
\*      record_entries/1 and activate(:return), then the restart.
RhFence ==
    /\ act = "rh_fence" /\ AGoto(IF DeleteBeforeRestore THEN "rh_delete" ELSE "rh_prepare")
    /\ rj' = IF rj = "fenced" THEN "fenced" ELSE "fence"
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, cPhase, cKind,
                   cRec, stDb, stCfg, ledger, mBoot, cUp, restore, apc, aOwner, aTo,
                   activated, budgets, hist>>

AfterFence == IF DeleteBeforeRestore THEN "rh_prepare" ELSE "rh_restart"

RhDelete ==
    /\ act = "rh_delete"
    /\ CASE ledger = "gone" ->
                /\ AGoto(AfterFence)
                /\ UNCHANGED <<sAlive, wpc, ledger, rail, restore, aTo, hist>>
         [] DeleteTarget = "return_fence" ->
                \/ /\ ServerDeleted
                   /\ badDelete' = (badDelete \/ ~DeleteAllowed)
                   /\ AGoto("rh_fenced")
                   /\ UNCHANGED <<doneLost, crashEF, deletedAfter, fromCopy>>
                \/ /\ DeleteCanFail /\ AGoto("idle")
                   /\ UNCHANGED <<sAlive, wpc, ledger, rail, restore, aTo, hist>>
         [] OTHER ->
                /\ AGoto("idle")
                /\ UNCHANGED <<sAlive, wpc, ledger, rail, restore, aTo, hist>>
    /\ UNCHANGED <<srvFiles, sBoot, mCfg, mMarker, mLink, mDb, mStale, rj, cPhase, cKind, cRec,
                   stDb, stCfg, mBoot, cUp, apc, aOwner, activated, budgets>>

RhFenced ==
    /\ act = "rh_fenced" /\ AGoto(AfterFence)
    /\ rj' = "fenced"
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, cPhase, cKind,
                   cRec, stDb, stCfg, ledger, mBoot, cUp, restore, apc, aOwner, aTo,
                   activated, budgets, hist>>

RhPrepare ==
    /\ act = "rh_prepare"
    /\ IF Preparable("local")
       THEN /\ AGoto("rh_stage")
            /\ cPhase' = "receiving" /\ cKind' = "local" /\ cRec' = FALSE
            /\ stDb' = FALSE /\ stCfg' = FALSE
       ELSE /\ AGoto("idle")
            /\ UNCHANGED <<cPhase, cKind, cRec, stDb, stCfg>>
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, rj,
                   ledger, mBoot, cUp, restore, apc, aOwner, aTo, activated, budgets, hist>>

\* The copy is staged; or, with TransferCanFail, its staging fails (a
\* keychain that refuses, a copy that does not restore): failed is recorded
\* and the job ends (failed/5, local_return.ex:218-231).
RhStage ==
    /\ act = "rh_stage"
    /\ \/ /\ AGoto("rh_activating")
          /\ stDb' = TRUE /\ stCfg' = TRUE
          /\ UNCHANGED cPhase
       \/ /\ TransferCanFail /\ AGoto("idle")
          /\ cPhase' = "failed"
          /\ UNCHANGED <<stDb, stCfg>>
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, rj, cKind,
                   cRec, ledger, mBoot, cUp, restore, apc, aOwner, aTo, activated, budgets,
                   hist>>

RhActivating ==
    /\ act = "rh_activating" /\ AGoto("rh_activate")
    /\ cPhase' = "activating" /\ apc' = "rec" /\ aOwner' = "job"
    /\ UNCHANGED <<srvFiles, srvRun, rail, mCfg, mMarker, mLink, mDb, mStale, rj, cKind, cRec,
                   stDb, stCfg, ledger, mBoot, cUp, restore, aTo, activated, budgets, hist>>

RhRestart ==
    /\ act = "rh_restart"
    /\ fromCopy' = TRUE
    /\ MacBoots
    /\ UNCHANGED <<srvFiles, srvRun, budgets, badDelete, crashEF, deletedAfter>>

-----------------------------------------------------------------------------
(* The environment *)

CanLose == MessagesCanBeLost /\ losses < MaxLosses

\* A rail loses the request or the answer on it.
Lose ==
    /\ CanLose
    /\ \/ /\ req # "none" /\ req' = "none"
          /\ UNCHANGED <<rep, doneLost>>
       \/ /\ rep # "none" /\ rep' = "none"
          /\ doneLost' = (doneLost \/ rep = "done")
          /\ UNCHANGED req
    /\ losses' = losses + 1
    /\ UNCHANGED <<srvFiles, srvRun, railUp, macFiles, macRun, net, sCrashes, mCrashes, presses,
                   badDelete, crashEF, deletedAfter, fromCopy>>

\* The worker's wait times out while its answer is still coming (a restore
\* longer than @ready_ms, a slow activation).
Late ==
    /\ CanLose /\ wpc \in Awaiting /\ Coming /\ rep = "none"
    /\ losses' = losses + 1
    /\ wpc' = AfterAwait(wpc)
    /\ doneLost' = (doneLost \/ wpc \in {"await_done", "await_done_r"})
    /\ UNCHANGED <<srvFiles, sBoot, sAlive, rail, macFiles, macRun, net, sCrashes, mCrashes,
                   presses, badDelete, crashEF, deletedAfter, fromCopy>>

\* The Mac's staging fails (restored/2's error clause, candidate.ex:555-568):
\* back to enrolled with the staging removed, and the responder refuses.
RestoreFails ==
    /\ TransferCanFail /\ CandIdle /\ restore # "none"
    /\ cPhase' = "enrolled" /\ stDb' = FALSE /\ stCfg' = FALSE
    /\ restore' = "none"
    /\ Answer(restore, "error")
    /\ UNCHANGED <<srvFiles, srvRun, railUp, req, mCfg, mMarker, mLink, mDb, mStale, rj, cKind,
                   cRec, ledger, mBoot, cUp, apc, aOwner, aTo, activated, act, budgets, hist>>

\* The ready epoch or the marker cannot be written (Moved.write/2 fails
\* before the file exists): commit/4 closes the rail and aborts
\* (move_worker.ex:425-428).
RetireFails == TransferCanFail /\ wpc = "retire" /\ WGoto("abort")

\* The server's engine dies while its worker runs, and boots again.
ServerCrash ==
    /\ ServerCanCrash /\ sCrashes < MaxCrashes /\ wpc # "off" /\ sAlive
    /\ sCrashes' = sCrashes + 1
    /\ ServerBoots
    /\ UNCHANGED <<sRole, sMoved, sAttempts, sAlive, macFiles, macHold, net, losses, mCrashes,
                   presses, hist>>

\* The Mac's device engine dies and boots again from its files.
MacCrash ==
    /\ MacCanCrash /\ mCrashes < MaxCrashes /\ mBoot = "device"
    /\ mCrashes' = mCrashes + 1
    /\ crashEF' = (crashEF \/ (~mMarker /\ mCfg = "device" /\ cPhase = "activating"))
    /\ MacBoots
    /\ UNCHANGED <<srvFiles, srvRun, net, losses, sCrashes, presses, badDelete, deletedAfter,
                   fromCopy>>

\* The network between the Mac and its server fails for good: the link and
\* every rail end; the server, if it runs, runs on.
NetFails ==
    /\ NetCanFail /\ net
    /\ net' = FALSE
    /\ MoveOn("none", FALSE)
    /\ doneLost' = (doneLost \/ rep = "done")
    /\ UNCHANGED <<srvFiles, srvRun, macFiles, macHold, losses, sCrashes, mCrashes, presses,
                   badDelete, crashEF, deletedAfter, fromCopy>>

-----------------------------------------------------------------------------
Init ==
    /\ sRole = "primary" /\ sMoved = FALSE /\ sPhase = "none" /\ sAttempts = 0
    /\ sBoot = "primary" /\ sAlive = TRUE /\ wpc = "off"
    /\ railUp = FALSE /\ req = "none" /\ rep = "none"
    /\ mCfg = "device" /\ mMarker = TRUE /\ mLink = TRUE /\ mDb = "retired" /\ mStale = TRUE
    /\ rj = "none" /\ cPhase = "none" /\ cKind = "return" /\ cRec = FALSE
    /\ stDb = FALSE /\ stCfg = FALSE /\ ledger = "standing"
    /\ mBoot = "device" /\ cUp = FALSE /\ restore = "none" /\ apc = "idle"
    /\ aOwner = "cand" /\ aTo = "none" /\ activated = FALSE /\ act = "idle"
    /\ net = TRUE /\ losses = 0 /\ sCrashes = 0 /\ mCrashes = 0 /\ presses = 0
    /\ badDelete = FALSE /\ doneLost = FALSE /\ crashEF = FALSE /\ deletedAfter = FALSE
    /\ fromCopy = FALSE

\* The server serves as the primary when its engine booted as one, or when
\* its next boot will (config primary, no marker), and it exists.
ServerServes == sAlive /\ (sBoot = "primary" \/ (sRole = "primary" /\ ~sMoved))

\* The Mac serves as the primary when its engine booted as one, or from its
\* commit point on: config.toml primary with no marker (Role.resolve/2).
MacServes == mBoot = "primary" \/ (mCfg = "primary" /\ ~mMarker)

\* Nothing is under way on the Mac or the rail.
Quiet ==
    /\ act = "idle" /\ apc = "idle" /\ restore = "none" /\ ~activated
    /\ req = "none" /\ rep = "none"

\* Proposed rule (finding HR-3): a Mac whose server is gone, and which serves
\* nothing itself, is offered Restore here once nothing runs.
GoneServerCanBeRestored ==
    (~sAlive /\ mBoot = "device" /\ ~MacServes /\ Quiet) => "restore_here" \in Offered

\* The ends: the home is back on the Mac (the server retired or deleted; its
\* worker may still be resuming, which never stops here); the server serves
\* it and the Mac waits, whatever its candidate holds (finding HR-2's rule,
\* UndoneReturnCanEnd, says when that wait is a dead end); or the server was
\* deleted as the fence and the restore here did not finish, with the
\* owner's presses spent (Restore here is offered again) or, finding HR-3,
\* with Restore here no longer offered: that end is not legitimate, and
\* GoneServerCanBeRestored's check records it.
Done ==
    \/ Quiet /\ mBoot = "primary" /\ ~ServerServes
    \/ Quiet /\ mBoot = "device" /\ ServerServes /\ wpc = "off"
    \/ /\ Quiet /\ mBoot = "device" /\ ~sAlive
       /\ (presses = MaxPresses \/ ~GoneServerCanBeRestored)

Terminated == Done /\ UNCHANGED vars

ServerStep ==
    \/ Run \/ Transfer \/ SendOffer \/ DialFails \/ TakeAccept \/ TakeReady \/ TakeRefusal
    \/ GiveUp \/ Retire \/ SendCommit \/ TakeDone \/ Finish \/ SelfRestart \/ Resume
    \/ ResumeDial \/ ResumeDialFails \/ TakeResumeReady \/ Abort \/ Undo \/ UndoRole

MacStep ==
    \/ Handle \/ Restored \/ Enroll \/ CandRestart
    \/ ARecord \/ APrune \/ BAside \/ BPlace \/ CTenure \/ DStatus \/ EMarker \/ FConfig \/ GDone

ActStep ==
    \/ \E a \in Actions : Press(a)
    \/ MbPrepare \/ MbRecord \/ MbStart
    \/ MnMark \/ MnForward \/ MnForwardLost \/ MnRecord \/ MnUnmark
    \/ CxStop \/ CxRemove \/ CxForget \/ DsDelete \/ DsClear \/ DsFenced
    \/ RhFence \/ RhDelete \/ RhFenced \/ RhPrepare \/ RhStage \/ RhActivating \/ RhRestart

Environment ==
    \/ Lose \/ Late \/ RestoreFails \/ RetireFails \/ ServerCrash \/ MacCrash \/ NetFails

Next == ServerStep \/ MacStep \/ ActStep \/ Environment \/ Terminated

\* Fermix's own steps (the worker, the candidate, the activation, an act's
\* steps after the press) would take fairness; the owner's presses, losses,
\* failures and crashes never do. Every check here is a safety check, so
\* this records intent only.
Fairness ==
    /\ WF_vars(ServerStep)
    /\ WF_vars(MacStep)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* "Two primaries: ... the Mac's config.toml (role primary) is placed after
\* the marker goes and is the last rename" (design section 2's risk table):
\* at most one of the server's home and the Mac's (retired or returned)
\* serves as the primary.
AtMostOnePrimary == ~(ServerServes /\ MacServes)

\* "No reachable state has config.toml primary beside a marker: the marker
\* goes first, the config last" (section 2): a boot of the Mac is never
\* refused for a moved home.
NoRefusedBoot == ~(mCfg = "primary" /\ mMarker)

\* "The merge keeps nothing of the retired copy but this machine's own paths
\* ... a stale memory.db ... can never win, even one the server deleted"
\* (section 2): once the Mac serves as the primary, every path that is not
\* this machine's own came from the staging, and none of the staging's is
\* missing (a missing memory.db would open fresh).
RetiredCopyNeverServes == MacServes => (mDb = "staged" /\ ~mStale)

\* "Delete your server is a separate, confirmed step, offered only once the
\* computer booted as the primary again" (B5) and the fence "runs in order:
\* (1) the delete ... (2)..." (section 8): the server is deleted only with
\* moved_at, or as the fence before any staging.
ServerDeletedOnlyAfterReturn == ~badDelete

\* home_move's rule, for the return (proposed rule here; MoveWorker's
\* moduledoc: "Once moved.json exists the move is never aborted"): once the
\* server wrote its marker, the Mac holds the staged home, or is activating
\* it, or serves it. A server that retired for anything less leaves no
\* primary, and its resume loop never ends.
RetiredOnlyForStagedReturn ==
    sMoved => (MacServes \/ (cKind = "return" /\ cPhase \in {"staged", "activating"}))

\* Proposed rule (finding HR-2): while the server answers as the primary with
\* no move under way, the Mac's screen offers a step once nothing runs on the
\* Mac: a return the server undid, or never started, can be cancelled or
\* tried again.
UndoneReturnCanEnd ==
    (mBoot = "device" /\ LinkUp /\ sPhase \in {"none", "aborted"} /\ Quiet) => Offered # {}

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* The round trip: the Mac booted as the primary with moved_at, the server marked.
Witness_RoundTrip == ~(mBoot = "primary" /\ rj = "back" /\ sMoved)

\* During the return from the server, the Mac's engine died between steps e
\* and f, booted as a device, and the activation finished.
Witness_CrashBetweenEF == ~(crashEF /\ mBoot = "primary" /\ rj = "back" /\ sMoved)

\* The server undid the return and serves again.
Witness_ServerUndo == ~(sPhase = "aborted" /\ sBoot = "primary" /\ rj = "started")

\* A move_done was lost and the return still completed.
Witness_LostMoveDone == ~(doneLost /\ mBoot = "primary" /\ rj = "back" /\ sMoved)

\* No server answered: the fence deleted it and the Mac restarted from its copy.
Witness_RestoredFromCopy == ~(fromCopy /\ mBoot = "primary" /\ ledger = "gone")

\* Delete your server removed the server after the return.
Witness_DeletedAfterReturn == ~deletedAfter

=============================================================================
