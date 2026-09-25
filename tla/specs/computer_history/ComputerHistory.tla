--------------------------- MODULE ComputerHistory ---------------------------
(***************************************************************************)
(* Computer History's write path against the owner's three privacy        *)
(* controls: /history pause, /history off and /history purge.              *)
(*                                                                         *)
(* The compux sidecar stamps each observed event with the wall clock and  *)
(* streams it to the Capturer GenServer, which keeps it in an in-memory   *)
(* buffer. A flush (the 2 s timer, the 25-event size trigger, or          *)
(* terminate/2) hands the buffer to Ingest, which makes two Memory.Repo   *)
(* calls: it reads the pause horizon and drops each event stamped before  *)
(* it, then inserts the rest into the spool, which refuses a row stamped  *)
(* inside a recorded purge interval. /history off flips the app env, asks *)
(* the Controller to stop the Capturer, saves config.toml and replies     *)
(* with what the stop confirmed. The Controller and the Capturer are      *)
(* supervised, and the model follows their real restarts; every Capturer  *)
(* start re-reads the enable bit.                                          *)
(*                                                                         *)
(* Deliberately not modelled:                                              *)
(*  - the summarizer and the roll-up, and their purge guard: a note or    *)
(*    thread is refused when a purge issued after its batch was read      *)
(*    reaches it (computer_history_sql.ex:1141-1151, :1220-1228, the      *)
(*    mark read first in Summarizer.run_session/4 and                     *)
(*    Rollup.maybe_run/3); migration 32, which turns a stored watermark   *)
(*    into one interval (repo.ex:3890, computer_history_sql.ex:284-298);  *)
(*    pruning at the 48 h sweep (:437, far beyond MaxTime); `purge all`,  *)
(*    whose [0, now] has the shape of a window (purge.ex:79); more than   *)
(*    one recorded interval (the owner purges once; the insert checks     *)
(*    every interval, computer_history_sql.ex:394, :664-675); the Setup   *)
(*    UI disable path: single-call facts covered by ExUnit                *)
(*    (TLA_PLUS_MODELS.md 5.1);                                           *)
(*  - the observe_start handshake: every Capturer starts already          *)
(*    capturing (before the ack, sidecar frames are held, never written:  *)
(*    capturer.ex:474-479);                                               *)
(*  - observer.gap rows the Capturer writes itself (capturer.ex:539-553)  *)
(*    and Ingest's per-event gates (allowlist, private window, scrubber), *)
(*    which do not depend on timing;                                      *)
(*  - the Summarizer.Scheduler child the Controller stops after the       *)
(*    Capturer (controller.ex:86-91), the singleton lock, a 2nd daemon;   *)
(*  - the DynamicSupervisor's 5 s shutdown kill (it only loses buffered   *)
(*    events), a Capturer crash in the middle of a flush, a failed        *)
(*    config save, a state-read error in Ingest's pause check (it fails   *)
(*    open, ingest.ex:247-250), an unparseable horizon and an event with  *)
(*    no integer ts (both fail closed, ingest.ex:232, :240): single-call  *)
(*    facts, covered by ExUnit;                                           *)
(*  - re-enable (the wizard's job, never a chat command: history.ex:12).  *)
(*    The owner sends pause and purge at most once, and /history off     *)
(*    once, or again after a daemon restart killed it unanswered.         *)
(*                                                                         *)
(* One step = one indivisible thing in the code: one GenServer callback,  *)
(* one Memory.Repo call (every SQLite access goes through that one        *)
(* process), or one file or app-env write. A process's own code next to a *)
(* Repo call touches only its own state, so it is folded into that step.  *)
(*                                                                         *)
(* Reading tip: in an action, IF c THEN x' = 1 /\ y' = 2 ELSE ... means   *)
(* "in the state before the step, if c holds this step sets x and y as    *)
(* shown"; each branch names the variables it changes.                    *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/capturer.ex @ a51810e9e720
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/wire.ex @ 35da392f4930
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/ingest.ex @ bcf44c4e67ca
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/controller.ex @ 66ba8ebde374
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/supervisor.ex @ 457bfb76bf4e
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history.ex @ a209702c717c
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/purge.ex @ 2f22405f1e30
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_use/sidecar_installer.ex @ a34df3f95db0
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/computer_history_sql.ex @ fe920569e2f8
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#call,computer_history_insert_events,computer_history_purge_window,computer_history_set_pause_until @ 62edd6a2ac97
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo.ex#computer_history_ensure_state @ ad9078b46f85
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/commands/history.ex @ 1911dca78a4e
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Events,             \* the owner's activity the recorder may observe, e.g. {e1, e2}
    MaxTime,            \* the wall clock runs 0..MaxTime
    PauseLengths,       \* /history pause durations in clock ticks, e.g. {1, 2}
    PurgeWidths,        \* /history purge windows in clock ticks, e.g. {1}
    MaxFaults,          \* at most this many restarts and crashes in one behaviour
    \* Environment switches: what may happen.
    OwnerCanPause,      \* the owner sends /history pause <duration> once
    OwnerCanPurge,      \* the owner sends /history purge <window> once
    OwnerCanDisable,    \* the owner sends /history off
    DaemonCanRestart,   \* the daemon stops and boots again
    ControllerCanCrash, \* the Controller dies alone; ComputerHistory.Supervisor restarts it
    CapturerCanCrash,   \* the Capturer raises; its DynamicSupervisor restarts it
    ReconcileCanTimeOut,\* /history off's reconcile call gives up after its 15 s timeout
                        \* (controller.ex:45, :53-54; the timer starts at history.ex:487)
    ReconcileCanStall,  \* the timeout can fire BEFORE the DynamicSupervisor has sent the
                        \* Capturer :shutdown. FALSE is a timing assumption: the work before
                        \* it (app env, file stats in installed?, whereis: controller.ex:94,
                        \* :128, sidecar_installer.ex:62-67) takes far less than the timeout
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by the checks that show a property needs it.
    IngestChecksPause,  \* Ingest has a pause gate: it reads the horizon once per batch and
                        \* drops each event while the pause is in force, now < pause_until
                        \* (ingest.ex:175, :178, :231-240). Off, nothing is dropped
    PauseByStamp,       \* the gate also drops each event stamped before the horizon, however
                        \* late its batch is flushed: the ts half of min(ts, now) < pause_until
                        \* (ingest.ex:234-235). Off, it is the flush-time gate of 693970b7
    StopBeforeReply,    \* /history off waits for the reconcile call, which returns after the
                        \* Capturer exited (history.ex:487, computer_history.ex:70,
                        \* controller.ex:53-54, :133)
    SaveBeforeReply,    \* /history off saves config.toml before it replies (history.ex:482,
                        \* :490-493, then :426-427)
    BootReconciles,     \* a (re)started Controller reconciles in handle_continue (controller.ex:57-74)
    OffConfirmsStop,    \* an exit of the reconcile call (no Controller, a crash mid-call, a
                        \* timeout) is returned as an error, and /history off then says the
                        \* stop is unconfirmed instead of "nothing new is captured"
                        \* (computer_history.ex:68-75, history.ex:447-452)
    InitChecksEnabled,  \* every Capturer start re-reads the enable bit and declines (:ignore)
                        \* while the feature is off (capturer.ex:124-130)
    InsertChecksIntervals \* the spool insert refuses, inside its own transaction, each row
                        \* stamped inside a recorded purge interval (computer_history_sql.ex:
                        \* 358-402, :664-675). Off, it is the plain INSERT OR IGNORE of 693970b7

VARIABLES
    clock,        \* environment: the wall clock, in ticks
    where,        \* where[e]: who holds event e (Places below): buffer and batch are
                  \* Capturer state, spool and deleted are SQLite rows
    ts,           \* ts[e]: the timestamp the sidecar stamped on e (the spool's ts column)
    sidecar,      \* the compux sidecar OS process: alive and observing
    cap,          \* Capturer GenServer: which callback it is in (CapStates below)
    exitQueued,   \* Capturer mailbox: the DynamicSupervisor's :shutdown EXIT is queued
    inc,          \* registry: incarnation number of the latest Capturer process (its pid)
    dsBox,        \* DynamicSupervisor mailbox: child EXITs and terminate_child calls, in order
    dsBusy,       \* DynamicSupervisor state: the Capturer incarnation it is terminating (0 = none)
    dsFor,        \* DynamicSupervisor state: the Controller incarnation that terminate_child
                  \* call came from, which gets the reply (0 = none)
    ctrl,         \* Controller process: "up" or "down"
    ctrlGen,      \* registry: incarnation number of the current Controller process
    ctrlPc,       \* Controller GenServer: where it is in a reconcile
    ctrlPid,      \* Controller GenServer: the Capturer pid its whereis returned (0 = none)
    ctrlCall,     \* Controller mailbox: /history off's reconcile call is queued
    env,          \* app env: computer_history enabled
    config,       \* config.toml: computer_history enabled (survives a restart)
    pauseUntil,   \* SQLite: computer_history_state.pause_until (0 = no horizon)
    pausePc,      \* the /history pause command's process
    purges,       \* SQLite: the computer_history_purges rows, each [lo, hi] (the owner
                  \* purges at most once, so {} until the purge commits)
    offPc,        \* the /history off command's process
    faultsLeft,   \* environment: restarts and crashes still allowed
    \* Ghost bookkeeping for the properties; no Fermix process holds these.
    pauseAcked,   \* the owner has read "Computer-history capture paused until ..."
    offAcked,     \* the owner has read "Computer history disabled - nothing new is captured ..."
    offUnconfirmed, \* the owner has read "... the recorder could not be confirmed stopped ..."
    inPause,      \* events captured while the stored pause horizon was in force
    inAckedPause, \* events captured after the pause reply and before its horizon
    afterOff,     \* events captured after the /history off reply
    purged        \* events captured before a committed purge whose window holds their ts

vars == <<clock, where, ts, sidecar, cap, exitQueued, inc, dsBox, dsBusy, dsFor,
          ctrl, ctrlGen, ctrlPc, ctrlPid, ctrlCall, env, config, pauseUntil, pausePc,
          purges, offPc, faultsLeft, pauseAcked, offAcked, offUnconfirmed, inPause,
          inAckedPause, afterOff, purged>>

(* Where an event can be.                                                  *)
(*  unseen  : it has not happened (or nothing was observing)               *)
(*  unread  : stamped, but no Capturer callback will ever read it: its     *)
(*            line sits behind the :shutdown EXIT in the Capturer's        *)
(*            mailbox, or arrived once terminate/2 had begun               *)
(*  buffer  : in the Capturer's state.buffer                               *)
(*  batch   : in the flush the Capturer is running (pause check passed)    *)
(*  spool   : a computer_history_events row                                *)
(*  dropped : dropped by Ingest's pause gate                               *)
(*  fenced  : refused by the spool insert: stamped inside a purged window  *)
(*  deleted : deleted from the spool by a purge                            *)
(*  lost    : the daemon died holding it in memory                         *)
Places == {"unseen", "unread", "buffer", "batch", "spool", "dropped", "fenced", "deleted",
           "lost"}

(* Capturer states and the code each stands for:                           *)
(*  none        : no process (never started, or deleted by terminate_child)*)
(*  running     : between callbacks, reading its mailbox (capturer.ex:270-385) *)
(*  flushing    : inside a flush, pause check done, insert pending          *)
(*                (capturer.ex:483-487 -> ingest.ex:187-201)               *)
(*  term_check  : in terminate/2 (capturer.ex:594), its flush's pause      *)
(*                check next                                               *)
(*  term_insert : in terminate/2, its flush's insert next                  *)
(*  term_stop   : in terminate/2, stop_driver and the lock release next    *)
(*                (:595-596)                                               *)
(*  dead        : exited; the DynamicSupervisor has not handled it yet     *)
CapStates == {"none", "running", "flushing", "term_check", "term_insert", "term_stop", "dead"}

\* Process.whereis(Capturer) returns a pid: the process is alive.
Registered == cap \in {"running", "flushing", "term_check", "term_insert", "term_stop"}

MaxInc == 1 + MaxFaults     \* each new Capturer or Controller costs one fault
MaxPause == CHOOSE m \in PauseLengths : \A x \in PauseLengths : x <= m
DsMsgs == [kind : {"exit", "term"}, n : 1..MaxInc, from : 0..MaxInc]
CtrlStates == {"idle", "boot", "boot_lookedup", "call_lookedup", "boot_stopping", "call_stopping"}

TypeOK ==
    /\ clock \in 0..MaxTime
    /\ where \in [Events -> Places]
    /\ ts \in [Events -> 0..MaxTime]
    /\ sidecar \in BOOLEAN
    /\ cap \in CapStates
    /\ exitQueued \in BOOLEAN
    /\ inc \in 1..MaxInc
    /\ dsBox \in Seq(DsMsgs)
    /\ dsBusy \in 0..MaxInc
    /\ dsFor \in 0..MaxInc
    /\ ctrl \in {"up", "down"}
    /\ ctrlGen \in 1..MaxInc
    /\ ctrlPc \in CtrlStates
    /\ ctrlPid \in 0..MaxInc
    /\ ctrlCall \in BOOLEAN
    /\ env \in BOOLEAN
    /\ config \in BOOLEAN
    /\ pauseUntil \in 0..(MaxTime + MaxPause)
    /\ pausePc \in {"idle", "committed", "done"}
    /\ purges \subseteq [lo : 0..MaxTime, hi : 0..MaxTime]
    /\ offPc \in {"idle", "flipped", "waiting", "reconciled", "unconfirmed", "saved",
                  "saved_unconfirmed", "replied", "replied_unconfirmed", "done"}
    /\ faultsLeft \in 0..MaxFaults
    /\ pauseAcked \in BOOLEAN
    /\ offAcked \in BOOLEAN
    /\ offUnconfirmed \in BOOLEAN
    /\ inPause \subseteq Events
    /\ inAckedPause \subseteq Events
    /\ afterOff \subseteq Events
    /\ purged \subseteq Events

-----------------------------------------------------------------------------
Buffer == {e \in Events : where[e] = "buffer"}
Batch  == {e \in Events : where[e] = "batch"}

\* Move every event at place `from` to place `to`.
Move(from, to) == [e \in Events |-> IF where[e] = from THEN to ELSE where[e]]

\* The stored pause is in force: now < pause_until (0 = no horizon).
Paused == clock < pauseUntil

\* Ingest's pause gate, per event: paused?/3 (ingest.ex:231-240) drops e when
\* min(ts, now) < pause_until, i.e. while the pause is in force or when e was
\* stamped before the horizon. No ts is below 0, so pauseUntil = 0 drops
\* nothing. With PauseByStamp off only the first half is left (the old
\* flush-time rule); with IngestChecksPause off nothing is dropped.
GateDrops(e) == IngestChecksPause /\ (Paused \/ (PauseByStamp /\ ts[e] < pauseUntil))

\* Ingest's split (Enum.split_with, ingest.ex:178): each buffered event is
\* dropped by the gate or goes on in the batch.
Split == [e \in Events |-> IF where[e] = "buffer"
                           THEN IF GateDrops(e) THEN "dropped" ELSE "batch"
                           ELSE where[e]]

\* The spool insert's purge fence, per event: insert_unless_purged
\* (computer_history_sql.ex:385-395) refuses a row whose ts lies inside any
\* recorded interval, bounds inclusive like the purge's DELETE (:616, :664-675).
\* At tick granularity it also refuses an event captured after the purge in the
\* same tick (ts = clock = hi): an over-approximation of the 1 ms edge that no
\* property depends on.
Fenced(e) == InsertChecksIntervals /\ \E i \in purges : i.lo <= ts[e] /\ ts[e] <= i.hi

\* The insert of the batch: each event lands in the spool or is fenced.
Insert == [e \in Events |-> IF where[e] = "batch"
                            THEN IF Fenced(e) THEN "fenced" ELSE "spool"
                            ELSE where[e]]

\* The buffered events that pass the gate. None: write_unpaused([], ...)
\* returns without an insert call (ingest.ex:183-184).
Kept == {e \in Buffer : ~GateDrops(e)}

\* The call exited without a confirmed stop: the fixed code returns that as an
\* error (computer_history.ex:68-75) and the reply says so; without the
\* mechanism the exit is read as :ok, a confirmed stop.
Unconfirmed == IF OffConfirmsStop THEN "unconfirmed" ELSE "reconciled"

\* The Controller's reconcile returns (to History, if History's call was
\* the one it served). A caller that already gave up ignores the reply.
CtrlFinish(forCall) ==
    /\ ctrlPc' = "idle"
    /\ ctrlPid' = 0
    /\ IF forCall
       THEN /\ ctrlCall' = FALSE
            /\ offPc' = IF offPc = "waiting" THEN "reconciled" ELSE offPc
       ELSE UNCHANGED <<ctrlCall, offPc>>

\* The DynamicSupervisor replies to the terminate_child call of Controller
\* incarnation `from`. A reply to a Controller that has since died is
\* dropped; it must not move a restarted Controller.
ReplyTo(from) ==
    IF from = ctrlGen /\ ctrl = "up"
    THEN CtrlFinish(ctrlPc \in {"call_lookedup", "call_stopping"})
    ELSE UNCHANGED <<ctrlPc, ctrlPid, ctrlCall, offPc>>

GhostsUnchanged ==
    UNCHANGED <<pauseAcked, offAcked, offUnconfirmed, inPause, inAckedPause, afterOff, purged>>

-----------------------------------------------------------------------------
(* The environment: the clock and the owner's activity *)

Tick ==
    /\ clock < MaxTime
    /\ clock' = clock + 1
    /\ UNCHANGED <<where, ts, sidecar, cap, exitQueued, inc, dsBox, dsBusy, dsFor, ctrl,
                   ctrlGen, ctrlPc, ctrlPid, ctrlCall, env, config, pauseUntil, pausePc,
                   purges, offPc, faultsLeft>>
    /\ GhostsUnchanged

\* The sidecar observes e and stamps it with the wall clock (the frame's
\* "ts", which becomes the row's ts: wire.ex:95, :125-129); the Port
\* delivers the line to the Capturer's mailbox, and
\* handle_info({port, {:data, {:eol, _}}}) -> route_frame -> ingest_event
\* (capturer.ex:270-286, :401-407, :446-457) appends it to state.buffer.
\* What decides "buffer" or "unread" is the line's position in the
\* Capturer's mailbox relative to the :shutdown EXIT: a line ahead of the
\* EXIT is handled first and buffered (receiving is folded into this step);
\* a line behind it, or arriving once terminate/2 has begun, is never read.
Capture(e) ==
    /\ where[e] = "unseen"
    /\ sidecar
    /\ ts' = [ts EXCEPT ![e] = clock]
    /\ where' = [where EXCEPT ![e] =
                    IF cap \in {"running", "flushing"} /\ ~exitQueued THEN "buffer" ELSE "unread"]
    /\ inPause' = IF Paused THEN inPause \cup {e} ELSE inPause
    /\ inAckedPause' = IF pauseAcked /\ Paused THEN inAckedPause \cup {e} ELSE inAckedPause
    /\ afterOff' = IF offAcked THEN afterOff \cup {e} ELSE afterOff
    /\ UNCHANGED <<clock, sidecar, cap, exitQueued, inc, dsBox, dsBusy, dsFor, ctrl, ctrlGen,
                   ctrlPc, ctrlPid, ctrlCall, env, config, pauseUntil, pausePc, purges,
                   offPc, faultsLeft, pauseAcked, offAcked, offUnconfirmed, purged>>

-----------------------------------------------------------------------------
(* The Capturer GenServer and Ingest (which runs inside the Capturer)      *)

CapturerOthersUnchanged ==
    UNCHANGED <<clock, ts, inc, dsFor, ctrl, ctrlGen, ctrlPc, ctrlPid, ctrlCall, env, config,
                pauseUntil, pausePc, purges, offPc, faultsLeft>>
    /\ GhostsUnchanged

\* A flush: handle_info(:flush) on the 2 s timer (capturer.ex:352-362) or the
\* 25-event size trigger (:451-452) -> flush/do_flush (:467-487) ->
\* Ingest.ingest (ingest.ex:173). Its first Repo call,
\* computer_history_ensure_state (ingest.ex:243), reads the horizon, and the
\* gate splits the buffer event by event (ingest.ex:178). The dropped ones are
\* gone; the Capturer empties its buffer either way (capturer.ex:487). When
\* none passes, Ingest returns with no insert call and the flush is over;
\* otherwise the survivors go on to the insert. A :flush timer message queued
\* ahead of the EXIT would write the same buffer terminate/2 writes, so a flush
\* is modelled only before it.
FlushCheck ==
    /\ cap = "running"
    /\ ~exitQueued
    /\ Buffer /= {}
    /\ where' = Split
    /\ cap' = IF Kept = {} THEN "running" ELSE "flushing"
    /\ UNCHANGED <<sidecar, exitQueued, dsBox, dsBusy>>
    /\ CapturerOthersUnchanged

\* Ingest's second Repo call: computer_history_insert_events (ingest.ex:201,
\* repo.ex:3285 -> computer_history_sql.ex:346-402), one BEGIN IMMEDIATE
\* transaction that checks each row against the recorded purge intervals, then
\* INSERT OR IGNOREs the rest. It does not read the pause.
FlushInsert ==
    /\ cap = "flushing"
    /\ where' = Insert
    /\ cap' = "running"
    /\ UNCHANGED <<sidecar, exitQueued, dsBox, dsBusy>>
    /\ CapturerOthersUnchanged

\* terminate/2 (capturer.ex:589-598) runs on the :shutdown EXIT, because
\* init traps exits (:140), or after a callback raised. Its flush makes the
\* same per-event pause check (flush/1 of an empty buffer makes no call,
\* :467), and inserts only when some event passed it.
TermCheck ==
    /\ \/ cap = "running" /\ exitQueued
       \/ cap = "term_check"
    /\ where' = Split
    /\ cap' = IF Kept = {} THEN "term_stop" ELSE "term_insert"
    /\ UNCHANGED <<sidecar, exitQueued, dsBox, dsBusy>>
    /\ CapturerOthersUnchanged

\* terminate/2's insert (the same Repo call as FlushInsert).
TermInsert ==
    /\ cap = "term_insert"
    /\ where' = Insert
    /\ cap' = "term_stop"
    /\ UNCHANGED <<sidecar, exitQueued, dsBox, dsBusy>>
    /\ CapturerOthersUnchanged

\* stop_driver (capturer.ex:595, :600-603) sends observe_stop and kills the
\* sidecar; the lock is released (:596) and the process exits. Its EXIT
\* reaches the DynamicSupervisor's mailbox.
TermStop ==
    /\ cap = "term_stop"
    /\ cap' = "dead"
    /\ sidecar' = FALSE
    /\ exitQueued' = FALSE
    /\ dsBox' = Append(dsBox, [kind |-> "exit", n |-> inc, from |-> 0])
    /\ UNCHANGED <<where, dsBusy>>
    /\ CapturerOthersUnchanged

\* A Capturer callback raises (for example a Repo call past GenServer.call's
\* 5 s default, repo.ex:3777-3780). gen_server then runs terminate/2.
CapturerCrash ==
    /\ CapturerCanCrash
    /\ faultsLeft > 0
    /\ cap = "running"
    /\ ~exitQueued
    /\ cap' = "term_check"
    /\ faultsLeft' = faultsLeft - 1
    /\ UNCHANGED <<clock, where, ts, sidecar, exitQueued, inc, dsBox, dsBusy, dsFor, ctrl,
                   ctrlGen, ctrlPc, ctrlPid, ctrlCall, env, config, pauseUntil, pausePc,
                   purges, offPc>>
    /\ GhostsUnchanged

CapturerStep == FlushCheck \/ FlushInsert \/ TermCheck \/ TermInsert \/ TermStop

-----------------------------------------------------------------------------
(* The DynamicSupervisor that owns the Capturer (supervisor.ex:55).        *)
(* OTP semantics: it handles its mailbox in order; a child is :permanent   *)
(* (the use GenServer default), so an EXIT it did not ask for restarts    *)
(* it in the same message; terminate_child/2 monitors and unlinks the      *)
(* child, sends :shutdown and blocks until the child is DOWN, then deletes *)
(* it without a restart.                                                   *)

DsUnchanged ==
    UNCHANGED <<clock, where, ts, env, config, pauseUntil, pausePc, purges, faultsLeft,
                ctrl, ctrlGen>>
    /\ GhostsUnchanged

\* An EXIT at the head: restart the Capturer. The new process registers its
\* name and runs init/1, which re-reads the enable bit (capturer.ex:124-130).
\* Off: init returns :ignore, the name is unregistered and the
\* DynamicSupervisor deletes the child. On: it bootstraps (:186-210) and opens
\* a new sidecar. Folding register-then-read into one step is sound: a
\* Controller whereis that runs after the flip either sees the new pid (and
\* stops it) or the init read sees the flip.
DsRestart ==
    /\ dsBusy = 0
    /\ dsBox /= <<>>
    /\ Head(dsBox).kind = "exit"
    /\ dsBox' = Tail(dsBox)
    /\ IF Head(dsBox).n = inc /\ cap = "dead"
       THEN IF InitChecksEnabled /\ ~env
            THEN cap' = "none" /\ UNCHANGED <<inc, sidecar>>
            ELSE cap' = "running" /\ inc' = inc + 1 /\ sidecar' = TRUE
       ELSE UNCHANGED <<cap, inc, sidecar>>
    /\ UNCHANGED <<exitQueued, dsBusy, dsFor, ctrlPc, ctrlPid, ctrlCall, offPc>>
    /\ DsUnchanged

\* A terminate_child(pid) call at the head (controller.ex:133). The pid is
\* still its child (alive, or dead with its EXIT not yet handled): send
\* :shutdown (it queues behind the Capturer's other messages) and block.
\* Otherwise (a Capturer that exited after the Controller's whereis, whose
\* restart declined or was replaced) reply {:error, :not_found}, which
\* ensure_stopped logs as "already gone" (controller.ex:142-143).
DsTerminate ==
    /\ dsBusy = 0
    /\ dsBox /= <<>>
    /\ Head(dsBox).kind = "term"
    /\ dsBox' = Tail(dsBox)
    /\ LET m == Head(dsBox) IN
       IF m.n = inc /\ cap /= "none"
       THEN /\ dsBusy' = m.n
            /\ dsFor' = m.from
            /\ exitQueued' = (cap /= "dead")
            /\ UNCHANGED <<ctrlPc, ctrlPid, ctrlCall, offPc>>
       ELSE /\ UNCHANGED <<dsBusy, dsFor, exitQueued>>
            /\ ReplyTo(m.from)
    /\ UNCHANGED <<cap, inc, sidecar>>
    /\ DsUnchanged

\* The child is DOWN: delete it and reply :ok. terminate_child unlinked the
\* child and consumes an EXIT already queued, so its EXIT never reaches the
\* restart path: SelectSeq removes it from the mailbox.
DsReaped ==
    /\ dsBusy /= 0
    /\ cap = "dead"
    /\ inc = dsBusy
    /\ cap' = "none"
    /\ dsBusy' = 0
    /\ dsFor' = 0
    /\ LET NotItsExit(m) == ~(m.kind = "exit" /\ m.n = dsBusy)
       IN dsBox' = SelectSeq(dsBox, NotItsExit)
    /\ ReplyTo(dsFor)
    /\ UNCHANGED <<inc, sidecar, exitQueued>>
    /\ DsUnchanged

DynSupStep == DsRestart \/ DsTerminate \/ DsReaped

-----------------------------------------------------------------------------
(* The Controller (controller.ex), the middle child of the :rest_for_one   *)
(* ComputerHistory.Supervisor: DynamicSupervisor, Controller, Retention    *)
(* (supervisor.ex:54-60).                                                  *)

CtrlUnchanged ==
    UNCHANGED <<clock, where, ts, exitQueued, dsBusy, dsFor, ctrl, ctrlGen, env, config,
                pauseUntil, pausePc, purges, faultsLeft>>
    /\ GhostsUnchanged

\* handle_continue(:reconcile) after a start (controller.ex:57-74), or
\* handle_call(:reconcile) (:77-80) -> do_reconcile (:93-96). want? is
\* operative? (the app env, computer_history.ex:43) and installed?.
\*  - want: ensure_started (controller.ex:101-125). whereis nil and no child at all:
\*    start_child starts one (the DynamicSupervisor's start is folded in,
\*    with the Capturer's init read of the same env in this step; a disable
\*    racing it makes start_child answer :ignore, :117-118, which ExUnit
\*    covers). whereis nil because the child is "dead" with its EXIT queued:
\*    that EXIT is ahead of start_child in the DynamicSupervisor's mailbox,
\*    so the restart comes first and start_child answers already_started
\*    (:113), a no-op here.
\*  - not want: ensure_stopped (:127-135) reads Process.whereis(Capturer)
\*    (:128). The call to the DynamicSupervisor is the next step.
CtrlLookup ==
    /\ ctrl = "up"
    /\ \/ ctrlPc = "boot"
       \/ ctrlPc = "idle" /\ ctrlCall
    /\ LET forCall == ctrlPc = "idle" IN
       IF env
       THEN /\ IF ~Registered /\ cap = "none"
               THEN cap' = "running" /\ inc' = inc + 1 /\ sidecar' = TRUE
               ELSE UNCHANGED <<cap, inc, sidecar>>
            /\ CtrlFinish(forCall)
       ELSE IF Registered
            THEN /\ ctrlPid' = inc
                 /\ ctrlPc' = IF forCall THEN "call_lookedup" ELSE "boot_lookedup"
                 /\ UNCHANGED <<cap, inc, sidecar, ctrlCall, offPc>>
            ELSE /\ CtrlFinish(forCall)
                 /\ UNCHANGED <<cap, inc, sidecar>>
    /\ UNCHANGED dsBox
    /\ CtrlUnchanged

\* DynamicSupervisor.terminate_child(sup, pid) (controller.ex:133): send the
\* call with the pid whereis returned, then block until the reply. The
\* DynamicSupervisor may have restarted the Capturer since the lookup.
CtrlSend ==
    /\ ctrl = "up"
    /\ ctrlPc \in {"boot_lookedup", "call_lookedup"}
    /\ dsBox' = Append(dsBox, [kind |-> "term", n |-> ctrlPid, from |-> ctrlGen])
    /\ ctrlPc' = IF ctrlPc = "call_lookedup" THEN "call_stopping" ELSE "boot_stopping"
    /\ UNCHANGED <<cap, inc, sidecar, ctrlPid, ctrlCall, offPc>>
    /\ CtrlUnchanged

\* The Controller dies alone, at any point (for example do_reconcile raises,
\* controller.ex:93-96). A queued or running call dies with it: the
\* caller's GenServer.call exits, and reconcile_runtime returns that as
\* {:error, {:reconcile_failed, _}} (computer_history.ex:68-75), an
\* unconfirmed stop. A terminate_child it already sent still runs; the
\* reply goes to the dead process (see ReplyTo).
ControllerCrash ==
    /\ ControllerCanCrash
    /\ faultsLeft > 0
    /\ ctrl = "up"
    /\ ctrl' = "down"
    /\ ctrlPc' = "idle"
    /\ ctrlPid' = 0
    /\ ctrlCall' = FALSE
    /\ offPc' = IF offPc = "waiting" THEN Unconfirmed ELSE offPc
    /\ faultsLeft' = faultsLeft - 1
    /\ UNCHANGED <<clock, where, ts, sidecar, cap, exitQueued, inc, dsBox, dsBusy, dsFor,
                   ctrlGen, env, config, pauseUntil, pausePc, purges>>
    /\ GhostsUnchanged

\* ComputerHistory.Supervisor (:rest_for_one, supervisor.ex:60) restarts the
\* Controller (and Retention after it); init continues to :reconcile.
ControllerRestart ==
    /\ ctrl = "down"
    /\ ctrl' = "up"
    /\ ctrlGen' = ctrlGen + 1
    /\ ctrlPc' = IF BootReconciles THEN "boot" ELSE "idle"
    /\ UNCHANGED <<clock, where, ts, sidecar, cap, exitQueued, inc, dsBox, dsBusy, dsFor,
                   ctrlPid, ctrlCall, env, config, pauseUntil, pausePc, purges, offPc,
                   faultsLeft>>
    /\ GhostsUnchanged

ControllerStep == CtrlLookup \/ CtrlSend \/ ControllerRestart

-----------------------------------------------------------------------------
(* /history off (history.ex:426-498), in the channel's ingress process    *)

OffUnchanged ==
    UNCHANGED <<clock, where, ts, sidecar, cap, exitQueued, inc, dsBox, dsBusy, dsFor, ctrl,
                ctrlGen, ctrlPc, ctrlPid, pauseUntil, pausePc, purges, faultsLeft>>
    /\ UNCHANGED <<pauseAcked, inPause, inAckedPause, afterOff, purged>>

\* The owner sends /history off; disable/2 flips the app env (history.ex:479-480).
\* That is a get_env then a put_env, folded into one step: no other writer
\* of this key is in scope.
OffFlip ==
    /\ OwnerCanDisable
    /\ offPc = "idle"
    /\ env' = FALSE
    /\ offPc' = "flipped"
    /\ UNCHANGED <<ctrlCall, config, offAcked, offUnconfirmed>>
    /\ OffUnchanged

\* stop_capture -> ComputerHistory.reconcile_runtime (history.ex:482, :487,
\* computer_history.ex:68-75) -> GenServer.call(Controller, :reconcile). The
\* model's host is macOS (off it, history.ex:488 skips the call: there is no
\* rail). A dead Controller: the call exits at once, an unconfirmed stop. With
\* StopBeforeReply off, History does not wait for the Controller.
OffCall ==
    /\ offPc = "flipped"
    /\ IF ctrl = "down"
       THEN offPc' = Unconfirmed /\ UNCHANGED ctrlCall
       ELSE /\ ctrlCall' = TRUE
            /\ offPc' = IF StopBeforeReply THEN "waiting" ELSE "reconciled"
    /\ UNCHANGED <<env, config, offAcked, offUnconfirmed>>
    /\ OffUnchanged

\* The call's 15 s timeout (controller.ex:45) fires: an unconfirmed stop. This
\* is the environment's timing, not something the History process reads.
\* Without ReconcileCanStall it fires only once the DynamicSupervisor has sent
\* the Capturer :shutdown (dsBusy /= 0), i.e. while it waits for terminate/2,
\* the one step that can take seconds.
OffTimeout ==
    /\ ReconcileCanTimeOut
    /\ offPc = "waiting"
    /\ ReconcileCanStall \/ dsBusy /= 0
    /\ offPc' = Unconfirmed
    /\ UNCHANGED <<ctrlCall, env, config, offAcked, offUnconfirmed>>
    /\ OffUnchanged

\* save_disabled: ConfigStore.current_snapshot + save_snapshot (history.ex:490-493),
\* one write of config.toml with enabled = false. It runs whatever the stop's
\* outcome (history.ex:482). With SaveBeforeReply off it runs after the reply.
OffSave ==
    /\ IF SaveBeforeReply
       THEN /\ offPc \in {"reconciled", "unconfirmed"}
            /\ offPc' = IF offPc = "reconciled" THEN "saved" ELSE "saved_unconfirmed"
       ELSE /\ offPc \in {"replied", "replied_unconfirmed"}
            /\ offPc' = "done"
    /\ config' = FALSE
    /\ UNCHANGED <<ctrlCall, env, offAcked, offUnconfirmed>>
    /\ OffUnchanged

\* The reply, chosen by off_text from the {stop, save} outcomes (history.ex:426-459).
\* A confirmed stop: "Computer history disabled - nothing new is captured ..."
\* (:432-436). An unconfirmed one: "... the recorder could not be confirmed
\* stopped ... it may still be capturing" (:447-452).
OffReply ==
    /\ IF SaveBeforeReply
       THEN /\ offPc \in {"saved", "saved_unconfirmed"}
            /\ offPc' = "done"
       ELSE /\ offPc \in {"reconciled", "unconfirmed"}
            /\ offPc' = IF offPc = "reconciled" THEN "replied" ELSE "replied_unconfirmed"
    /\ LET confirmed == offPc \in {"saved", "reconciled"}
       IN /\ offAcked' = (offAcked \/ confirmed)
          /\ offUnconfirmed' = (offUnconfirmed \/ ~confirmed)
    /\ UNCHANGED <<ctrlCall, env, config>>
    /\ OffUnchanged

OffStep == OffCall \/ OffSave \/ OffReply

-----------------------------------------------------------------------------
(* /history pause and /history purge (history.ex:367-422)                 *)

CommandUnchanged ==
    UNCHANGED <<clock, ts, sidecar, cap, exitQueued, inc, dsBox, dsBusy, dsFor, ctrl, ctrlGen,
                ctrlPc, ctrlPid, ctrlCall, env, config, offPc, faultsLeft>>

\* The owner sends /history pause <d>: until = now + d (history.ex:370);
\* persist_pause -> Repo.computer_history_set_pause_until (:382,
\* computer_history_sql.ex:1205-1215), one Repo call.
PauseCommit(d) ==
    /\ OwnerCanPause
    /\ pausePc = "idle"
    /\ pauseUntil' = clock + d
    /\ pausePc' = "committed"
    /\ UNCHANGED <<where, purges>>
    /\ CommandUnchanged
    /\ GhostsUnchanged

\* The reply (history.ex:384-387): "paused until <until>. It resumes
\* automatically then." There is no resume verb: the horizon passing is the
\* only unpause (Ingest re-reads it per batch, ingest.ex:217-230).
PauseReply ==
    /\ pausePc = "committed"
    /\ pausePc' = "done"
    /\ pauseAcked' = TRUE
    /\ UNCHANGED <<where, pauseUntil, purges>>
    /\ CommandUnchanged
    /\ UNCHANGED <<offAcked, offUnconfirmed, inPause, inAckedPause, afterOff, purged>>

\* The owner sends /history purge <w>: Purge.purge takes now and the window
\* [now - w, now] (purge.ex:56-58, :80), then one Repo call, purge_window
\* (computer_history_sql.ex:606-647): one BEGIN IMMEDIATE transaction that
\* deletes the spool rows in the window (:616) and records the interval
\* (:640). Rows still in a Capturer buffer, or in a batch past its pause
\* check, are not in the spool yet. The reply (history.ex:411-417) is folded
\* in: no property depends on its timing.
PurgeCommit(w) ==
    /\ OwnerCanPurge
    /\ purges = {}
    /\ LET lo == IF clock >= w THEN clock - w ELSE 0
           InWindow(e) == where[e] /= "unseen" /\ lo <= ts[e] /\ ts[e] <= clock
       IN /\ where' = [e \in Events |->
                          IF where[e] = "spool" /\ InWindow(e) THEN "deleted" ELSE where[e]]
          /\ purged' = purged \cup {e \in Events : InWindow(e)}
          /\ purges' = {[lo |-> lo, hi |-> clock]}
    /\ UNCHANGED <<pauseUntil, pausePc>>
    /\ CommandUnchanged
    /\ UNCHANGED <<pauseAcked, offAcked, offUnconfirmed, inPause, inAckedPause, afterOff>>

-----------------------------------------------------------------------------
(* The daemon restarts. Only SQLite rows (the spool, pause_until, the      *)
(* purge intervals) and config.toml survive; every process and its memory *)
(* is gone. Boot loads the app env from config.toml, and the fresh        *)
(* Controller reconciles in handle_continue. A command in flight dies     *)
(* unanswered: the owner may send /history off again (not once it was    *)
(* answered, either way); an unanswered pause stays stored.               *)
DaemonRestart ==
    /\ DaemonCanRestart
    /\ faultsLeft > 0
    /\ faultsLeft' = faultsLeft - 1
    /\ where' = [e \in Events |-> IF where[e] \in {"buffer", "batch"} THEN "lost" ELSE where[e]]
    /\ cap' = "none"
    /\ exitQueued' = FALSE
    /\ sidecar' = FALSE
    /\ dsBox' = <<>>
    /\ dsBusy' = 0
    /\ dsFor' = 0
    /\ ctrl' = "up"
    /\ ctrlGen' = ctrlGen + 1
    /\ ctrlPc' = IF BootReconciles THEN "boot" ELSE "idle"
    /\ ctrlPid' = 0
    /\ ctrlCall' = FALSE
    /\ env' = config
    /\ offPc' = IF offAcked \/ offUnconfirmed THEN "done" ELSE "idle"
    /\ pausePc' = IF pausePc = "committed" THEN "done" ELSE pausePc
    /\ UNCHANGED <<clock, ts, inc, config, pauseUntil, purges>>
    /\ GhostsUnchanged

-----------------------------------------------------------------------------
Init ==
    /\ clock = 0
    /\ where = [e \in Events |-> "unseen"]
    /\ ts = [e \in Events |-> 0]
    /\ sidecar = TRUE
    /\ cap = "running"          \* enabled and capturing at the start
    /\ exitQueued = FALSE
    /\ inc = 1
    /\ dsBox = <<>>
    /\ dsBusy = 0
    /\ dsFor = 0
    /\ ctrl = "up"
    /\ ctrlGen = 1
    /\ ctrlPc = "idle"          \* its boot reconcile started the Capturer
    /\ ctrlPid = 0
    /\ ctrlCall = FALSE
    /\ env = TRUE
    /\ config = TRUE
    /\ pauseUntil = 0
    /\ pausePc = "idle"
    /\ purges = {}
    /\ offPc = "idle"
    /\ faultsLeft = MaxFaults
    /\ pauseAcked = FALSE
    /\ offAcked = FALSE
    /\ offUnconfirmed = FALSE
    /\ inPause = {}
    /\ inAckedPause = {}
    /\ afterOff = {}
    /\ purged = {}

\* The legitimate end: the clock has run out and no Fermix process has
\* anything left to do. Deadlock checking is on, so any other state where
\* nothing can happen is reported as a wedge.
Done ==
    /\ clock = MaxTime
    /\ cap \in {"none", "running"}
    /\ ~exitQueued
    /\ Buffer = {}
    /\ dsBox = <<>>
    /\ dsBusy = 0
    /\ ctrl = "up"
    /\ ctrlPc = "idle"
    /\ ~ctrlCall
    /\ offPc \in {"idle", "done"}
    /\ pausePc \in {"idle", "done"}

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ Tick
    \/ \E e \in Events : Capture(e)
    \/ CapturerStep \/ CapturerCrash
    \/ DynSupStep
    \/ ControllerStep \/ ControllerCrash
    \/ OffFlip \/ OffStep \/ OffTimeout
    \/ \E d \in PauseLengths : PauseCommit(d)
    \/ PauseReply
    \/ \E w \in PurgeWidths : PurgeCommit(w)
    \/ DaemonRestart
    \/ Terminated

\* Fermix's own processes always take their next step: the Capturer's flush
\* timer and callbacks, the DynamicSupervisor, the Controller and its
\* supervisor, and a command process that has started. The owner, the
\* clock, the sidecar's events, crashes, restarts and timeouts get no
\* fairness.
Fairness ==
    /\ WF_vars(CapturerStep)
    /\ WF_vars(DynSupStep)
    /\ WF_vars(ControllerStep)
    /\ WF_vars(OffStep)
    /\ WF_vars(PauseReply)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* MILESTONE_32 14.2 invariant 12 (docs/design/MILESTONE_32_COMPUTER_HISTORY.md:553):
\* "Pause and disable both halt ingestion at the ack - no event timestamped
\* after the pause or the disable acknowledgment lands in the spool".
\* The disable half. The off reply itself says "nothing new is captured"
\* (history.ex:433), and only after a confirmed stop.
DisableHaltsAtAck == \A e \in afterOff : where[e] /= "spool"

\* The pause half, read up to the horizon: 12 says after the ack, and 12
\* (line 470) says "resume is ... after the duration".
PauseHaltsAtAck == \A e \in inAckedPause : where[e] /= "spool"

\* An event captured while the stored pause is in force is never stored,
\* whenever its batch is flushed: the claim at ingest.ex:217-230 ("an event
\* stamped inside the pause therefore never reaches the spool, even when its
\* batch is flushed after the horizon"). It implies PauseHaltsAtAck
\* (inAckedPause is a subset of inPause) and that nothing captured during the
\* pause is in the spool while it lasts.
CapturedWhilePausedNeverStored == \A e \in inPause : where[e] /= "spool"

\* After purge(W) commits, no spool row with a timestamp in W appears: the
\* claim at purge.ex:3-9 ("an event stamped inside the window that was still
\* buffered or in flight never lands after the purge"), and MILESTONE_32 12
\* (line 469: purge "deletes spool rows in the window").
PurgedWindowStaysPurged == \A e \in purged : where[e] /= "spool"

\* Proposed rule: once the owner has been told capture is off, or that its
\* stop could not be confirmed, capture eventually stops for good (no
\* Capturer process and no sidecar).
CaptureStopped == cap = "none" /\ ~sidecar
DisableEventuallyStops == [](offAcked \/ offUnconfirmed => <>[]CaptureStopped)

-----------------------------------------------------------------------------
(* WITNESSES: violated when their scenario is reachable. *)

\* The terminate-time flush of /history off writes buffered events while
\* the command still waits for the reconcile, i.e. before the reply.
Witness_TerminateFlushWrites ==
    ~(cap = "term_insert" /\ Batch /= {} /\ offPc = "waiting")

\* A batch whose pause check ran before the pause was written is inserted
\* after the owner read "paused until ...": rows land after the ack, all
\* stamped before it.
Witness_WriteAfterPauseAck ==
    ~(cap = "flushing" /\ Batch /= {} /\ pauseAcked /\ Paused)

\* CH-2's path, now closed: a row stamped inside the purged window reaches the
\* spool insert after the purge committed (buffered, or in a batch past its
\* pause check), and the insert's purge fence refuses it
\* (computer_history_sql.ex:385-395).
Witness_LateRowFenced == \A e \in Events : where[e] /= "fenced"

\* CH-4's second path, now harmless: the Controller's whereis returned a
\* Capturer that then exited, and its restart declined because the feature
\* is off, so the DynamicSupervisor is about to answer the terminate_child
\* {:error, :not_found}, which the Controller logs as "already gone"
\* (controller.ex:142-143), with no Capturer running.
Witness_StaleTerminate ==
    ~(/\ dsBox /= <<>>
      /\ Head(dsBox).kind = "term"
      /\ cap = "none"
      /\ ~env)

=============================================================================
