--------------------------- MODULE ComputerInvoke ---------------------------
(***************************************************************************)
(* One home, many computers (M97 §5.2, §6.1 to §6.3): the server asks a   *)
(* computer of the home to do something (an invocation) over the          *)
(* computer's session, and the computer admits it, journals it, runs it   *)
(* and answers. The session can drop with words in flight, the computer   *)
(* can stop in the middle of a run, the owner can switch everything off   *)
(* at the computer, and the home can move on to a newer copy while an     *)
(* older one still asks.                                                   *)
(*                                                                         *)
(* The scene is one computer and two calls on its server: one that        *)
(* changes something there (an effect) and one that only reads.           *)
(*                                                                         *)
(* What it describes:                                                      *)
(*  - Computers.Invocation (invocation.ex), which Computers.call/6 runs   *)
(*    in the caller: it mints an id never used before, registers it,      *)
(*    sends invoke_open, waits at most the deadline and the link's        *)
(*    allowance, and decides what a lost answer means: an effect ends     *)
(*    there (never sent twice), a read is asked once more under a new id. *)
(*  - Computers.Calls (calls.ex): the waiters, which outlive a session,   *)
(*    and the ids still waited on from a computer.                         *)
(*  - Desktop.InvokeFamily (invoke_family.ex): as the computer's next     *)
(*    session starts it asks for the state of each id still waited on     *)
(*    (invoke_status), and hands each invoke_result to Calls.             *)
(*  - Desktop.Invoke and its Admission (invoke.ex, admission.ex): the     *)
(*    epoch check, the switches read at that moment, the started record   *)
(*    before the run, the finished record before the answer, the answers  *)
(*    held in memory for a status ask, the receipt alone after that, the  *)
(*    master switch off, and what a restart finds.                         *)
(*  - Computers.Journal (journal.ex): the started and finished records    *)
(*    and the mark a restart leaves on what a crash left started.         *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - the bound (8 running, 32 waiting, busy past it), an upload or an    *)
(*    answer's part and its lanes, and the bytes of anything: one request *)
(*    here is one message, as the codec delivers it (invoke_test.exs,     *)
(*    invoke_family_test.exs, two_engines_invoke_test.exs);               *)
(*  - a capability's own refusals and failures (its switch, its origin    *)
(*    rules, the sandbox): each is an answer like any other;              *)
(*  - the computer's own deadline timer, which ends a run as timed_out as *)
(*    a cancel ends it as cancelled, and a long-lived request (a deadline *)
(*    of 0), which is waited on until cancelled;                          *)
(*  - a caller that ends before its answer (Calls sends a cancel) and     *)
(*    Computers.cancel/2: the cancel the deadline sends is the same step; *)
(*  - an id asked twice: the server never repeats one (mint_id), and the  *)
(*    computer answers a known one as a status ask (repeated/2);          *)
(*  - a computer's own request to its server (the home's services);       *)
(*  - the switch going back on, a second computer, and a restart of the   *)
(*    server's Calls (its waiters time out);                              *)
(*  - a run admitted before the computer learned of a newer copy of the   *)
(*    home: it finishes. The epoch is checked when a request is admitted. *)
(*                                                                         *)
(* One step = one message taken by one process, one write of the          *)
(* journal with what follows it in the same callback, one moment the run  *)
(* acts, or one thing the world does (a drop, a stop, a switch).          *)
(***************************************************************************)

\* SOURCE: apps/fermix_core/lib/fermix_core/computers/invocation.ex
\* SOURCE: apps/fermix_core/lib/fermix_core/computers/calls.ex
\* SOURCE: apps/fermix_core/lib/fermix_core/computers/journal.ex#append_started,append_finished,lookup,interrupted,close_all
\* SOURCE: apps/fermix_core/lib/fermix_core/computers.ex#call,cancel
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/invoke.ex
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/invoke/admission.ex
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/invoke_family.ex#init,handle_event,reconcile,outstanding
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/device_supervisor.ex#children,invoke_spec

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Calls,              \* the calls on the server, e.g. {e, r}
    Effects,            \* those that change something on the computer
    MaxTries,           \* the ids one call may use (2: asked once more)
    MaxDrops,           \* the times the session drops (a bound)
    \* Environment switches: what may happen.
    SessionCanDrop,     \* the session ends with words in flight
    ComputerCanStop,    \* the computer's Admission (or its engine) stops
                        \* in the middle and starts again
    AnswersCanExpire,   \* a held answer leaves memory (10 minutes, or the
                        \* bounds of what is held)
    OwnerCanSwitchOff,  \* the master switch goes off at the computer
    HomeCanMoveOn,      \* the computer learns of a newer copy of its home
                        \* while this server still asks
    \* Mechanism switches: TRUE is the code.
    JournalBeforeRun,   \* the started record is synced before the run
                        \* (Admission.start/3, admission.ex:487-499;
                        \* Journal.append_started/2, journal.ex:81); FALSE
                        \* writes the journal only when it ends
    NoResendOfEffects,  \* an effect whose answer is lost ends there
                        \* (Invocation.again/5, invocation.ex:384-390:
                        \* `not request.effect?`); FALSE asks it again as
                        \* a read is
    EpochCheck,         \* a request from an epoch below the link's is
                        \* refused (Admission.current_epoch/2,
                        \* admission.ex:312-325); FALSE admits it
    SwitchReadAtAdmit,  \* the switches are read as each request is
                        \* admitted (Admission.admit/2, admission.ex:299-300;
                        \* switches/1, :834; Invoke.switches_in/1,
                        \* invoke.ex:49-61); FALSE uses what was read when
                        \* Admission started
    ServerDeadline      \* the caller waits at most its deadline and the
                        \* link's allowance (Invocation.await/5,
                        \* invocation.ex:269-281; wait_left/3, :283-288;
                        \* gave_up/4, :348-359); FALSE waits for ever

ASSUME Effects \subseteq Calls

ServerEpoch == 1
Ids == Calls \X (1..MaxTries)
CallOf(id) == id[1]

\* How a call can end: the closed set (Outcome.statuses/0), a refusal with
\* the reason the model reads.
Refusals == {"refused_off", "refused_stale_epoch", "refused_stopped_here", "refused_unavailable"}
Closed == {"ok", "timed_out", "cancelled", "unknown"} \cup Refusals

\* An answer on the wire: what it says, and whether it carries the result
\* ("full"), only the journal's receipt ("receipt") or no record ("none").
Answers == [id : Ids, status : Closed, rec : {"full", "receipt", "none"}]
Asks == [t : {"open", "status", "cancel"}, id : Ids]

VARIABLES
    \* the server: Computers.Invocation in the caller, and Computers.Calls
    st,             \* each call: "idle", "waiting", "done"
    try,            \* the ids the call has used; its current id is <<c, try[c]>>
    out,            \* how the call ended, "none" until then
    \* the link: the computer's session
    up,             \* the session is up
    down,           \* asks sent to the computer and not yet taken there
    back,           \* answers sent to the server and not yet taken there
    drops,          \* the times it dropped
    \* the computer: Desktop.Invoke's Admission and its journal
    run,            \* each id: "none", "running", "acted" (the run did its
                    \* work and has not answered yet), "ended"
    held,           \* the answer held in memory for the id, "none"
    journal,        \* the id's record: "none", "started", or how it ended
    acted,          \* the times the id's work happened on the computer
    master,         \* the master switch, in machine.toml
    seen,           \* the master switch as read when Admission started
    stopOwed,       \* the switch went off and Admission has not heard yet
    linkEpoch,      \* the highest primary epoch the computer has seen
    stopped,        \* the computer stopped once (a bound)
    \* history, for the rules and the witnesses
    staleAdmitted,  \* a request from an older copy was admitted
    startedOff,     \* a run started while the master switch was off
    dropSeen,       \* the session dropped while the call waited
    via             \* what ended the call: "none" until then, "local" (refused
                    \* before anything was sent), "deadline", or the answer
                    \* it took: "full", "receipt", "no_record"

server_vars == <<st, try, out>>
link_vars == <<up, down, back, drops>>
computer_vars == <<run, held, journal, acted, master, seen, stopOwed, linkEpoch, stopped>>
hist_vars == <<staleAdmitted, startedOff, dropSeen, via>>
vars == <<server_vars, link_vars, computer_vars, hist_vars>>

TypeOK ==
    /\ st \in [Calls -> {"idle", "waiting", "done"}]
    /\ try \in [Calls -> 0..MaxTries]
    /\ out \in [Calls -> Closed \cup {"none"}]
    /\ up \in BOOLEAN /\ down \subseteq Asks /\ back \subseteq Answers
    /\ drops \in 0..MaxDrops
    /\ run \in [Ids -> {"none", "running", "acted", "ended"}]
    /\ held \in [Ids -> Closed \cup {"none"}]
    /\ journal \in [Ids -> Closed \cup {"none", "started"}]
    /\ acted \in [Ids -> 0..1]
    /\ master \in BOOLEAN /\ seen \in BOOLEAN /\ stopOwed \in BOOLEAN
    /\ linkEpoch \in 1..2 /\ stopped \in BOOLEAN
    /\ staleAdmitted \in BOOLEAN /\ startedOff \in BOOLEAN
    /\ dropSeen \in [Calls -> BOOLEAN]
    /\ via \in [Calls -> {"none", "local", "deadline", "full", "receipt", "no_record"}]

Init ==
    /\ st = [c \in Calls |-> "idle"] /\ try = [c \in Calls |-> 0]
    /\ out = [c \in Calls |-> "none"]
    /\ up = TRUE /\ down = {} /\ back = {} /\ drops = 0
    /\ run = [i \in Ids |-> "none"] /\ held = [i \in Ids |-> "none"]
    /\ journal = [i \in Ids |-> "none"] /\ acted = [i \in Ids |-> 0]
    /\ master = TRUE /\ seen = TRUE /\ stopOwed = FALSE
    /\ linkEpoch = 1 /\ stopped = FALSE
    /\ staleAdmitted = FALSE /\ startedOff = FALSE
    /\ dropSeen = [c \in Calls |-> FALSE] /\ via = [c \in Calls |-> "none"]

Current(c) == <<c, try[c]>>
\* The ids Calls still waits on from the computer (Calls.outstanding/2,
\* calls.ex:77, ids_on/2, :139).
Outstanding == {Current(c) : c \in {w \in Calls : st[w] = "waiting"}}
Live == {i \in Ids : run[i] \in {"running", "acted"}}

End(c, how, by) ==
    /\ st' = [st EXCEPT ![c] = "done"]
    /\ out' = [out EXCEPT ![c] = how]
    /\ via' = [via EXCEPT ![c] = by]

-----------------------------------------------------------------------------
(* The server: Computers.call/6 (computers.ex:129), Computers.Invocation   *)

\* invoke/3 (invocation.ex:215-249): a new id (mint_id/0, :440), registered
\* with Calls (calls.ex:59) before invoke_open goes (the transport's
\* open/5). With no session nothing is sent and the call is refused at once
\* (reachable/2, :95; sent/5's :not_connected, :259).
Send(c) ==
    /\ st[c] = "idle"
    /\ IF up
          THEN /\ try' = [try EXCEPT ![c] = 1]
               /\ st' = [st EXCEPT ![c] = "waiting"]
               /\ down' = down \cup {[t |-> "open", id |-> <<c, 1>>]}
               /\ UNCHANGED <<out, via>>
          ELSE /\ End(c, "refused_unavailable", "local")
               /\ UNCHANGED <<try, down>>
    /\ UNCHANGED <<up, back, drops, computer_vars, staleAdmitted, startedOff, dropSeen>>

\* An answer says the outcome is not known, or holds only the journal's
\* receipt (lost?/1, :394-396).
Lost(m) == m.status = "unknown" \/ m.rec = "receipt"

\* An invoke_result reaches the family (invoke_family.ex:65), which hands it
\* to Calls (deliver/4, calls.ex:65; route/4, :147), and the caller takes it
\* (await/5, :269; take/3, :293). One for an id nobody waits on is dropped
\* (route/4's :error). A lost answer ends an effect there; a read is asked
\* once more under a new id (again/5, :384-390), where the session allows.
Receive(m) ==
    /\ m \in back
    /\ back' = back \ {m}
    /\ LET c == CallOf(m.id)
           again == Lost(m) /\ try[c] < MaxTries
                    /\ (c \notin Effects \/ ~NoResendOfEffects)
           heard == IF m.rec = "none" THEN "no_record" ELSE m.rec
       IN IF st[c] # "waiting" \/ m.id # Current(c)
             THEN UNCHANGED <<server_vars, down, via>>
             ELSE IF again /\ up
                     THEN /\ try' = [try EXCEPT ![c] = try[c] + 1]
                          /\ down' = down \cup {[t |-> "open", id |-> <<c, try[c] + 1>>]}
                          /\ UNCHANGED <<st, out, via>>
                     ELSE /\ IF again
                                THEN End(c, "refused_unavailable", "local")
                                ELSE End(c, m.status, heard)
                          /\ UNCHANGED <<try, down>>
    /\ UNCHANGED <<up, drops, computer_vars, staleAdmitted, startedOff, dropSeen>>

\* The wait ends (await/5's after, :279; gave_up/4, :348-359): an effect's
\* outcome is not known, a read timed out, and the computer is told to
\* cancel it, best-effort (cancel_sent/4, :361).
Deadline(c) ==
    /\ ServerDeadline /\ st[c] = "waiting"
    /\ End(c, IF c \in Effects THEN "unknown" ELSE "timed_out", "deadline")
    /\ down' = IF up THEN down \cup {[t |-> "cancel", id |-> Current(c)]} ELSE down
    /\ UNCHANGED <<try, up, back, drops, computer_vars, staleAdmitted, startedOff, dropSeen>>

\* Without its deadline a caller goes on waiting.
Wait(c) == ~ServerDeadline /\ st[c] = "waiting" /\ UNCHANGED vars

-----------------------------------------------------------------------------
(* The link: the computer's session                                        *)

\* The session ends. What was on its way to the server is lost; what was on
\* its way to the computer is lost too, or was already handed to Admission
\* (Relay.invocation/4, a cast) and is taken later.
Drop ==
    /\ SessionCanDrop /\ up /\ drops < MaxDrops
    /\ up' = FALSE /\ drops' = drops + 1
    /\ back' = {} /\ down' \in {down, {}}
    /\ dropSeen' = [c \in Calls |-> dropSeen[c] \/ st[c] = "waiting"]
    /\ UNCHANGED <<server_vars, computer_vars, staleAdmitted, startedOff, via>>

\* The computer's next session with this server: its family starts and asks
\* for every id still waited on (InvokeFamily.init/1, invoke_family.ex:47;
\* reconcile/1, :91). A computer that has seen a newer copy of its home
\* never comes back to this one (Relay.hello_ack/2 refuses a lower epoch).
Reconnect ==
    /\ ~up /\ linkEpoch <= ServerEpoch
    /\ up' = TRUE
    /\ down' = down \cup {[t |-> "status", id |-> i] : i \in Outstanding}
    /\ UNCHANGED <<server_vars, back, drops, computer_vars, hist_vars>>

-----------------------------------------------------------------------------
(* The computer: Desktop.Invoke's Admission                                *)

\* The answer goes if the session is up (send_answer/4, admission.ex:755;
\* deliver/5, :768: a refused send is said and nothing more).
Say(id, status, rec) ==
    back' = IF up THEN back \cup {[id |-> id, status |-> status, rec |-> rec]} ELSE back

\* answer/3 (:679-692): the finished record is synced (record_finished/6,
\* :709; Journal.append_finished/2, journal.ex:105), then the answer is held
\* (hold/3, :803) and sent.
Answer(id, status) ==
    /\ journal' = [journal EXCEPT ![id] = status]
    /\ held' = [held EXCEPT ![id] = status]
    /\ Say(id, status, "full")

Take(m) == m \in down /\ down' = down \ {m}

\* Admission takes its mailbox in order, and the server asks about an id
\* only after it sent that id's request: a status ask or a cancel is taken
\* after the request it is about, where that one is still to be taken.
AfterItsOpen(m) == [t |-> "open", id |-> m.id] \notin down

\* invoke_open (open/3, :219; admitted/2, :288; admit/2, :299-310): the
\* epoch first (current_epoch/2, :312-325), then the switches as they are
\* now (switched_on/2, :335-344), each a refusal with only a finished
\* record. Then the started record is synced and the run starts (accept/2,
\* :377; start/3, :487-499; launch/3, :501).
Open(m) ==
    /\ Take(m) /\ m.t = "open"
    /\ LET id == m.id
           stale == ServerEpoch < linkEpoch
           on == IF SwitchReadAtAdmit THEN master ELSE seen
       IN IF EpochCheck /\ stale
             THEN /\ Answer(id, "refused_stale_epoch")
                  /\ UNCHANGED <<run, staleAdmitted, startedOff>>
             ELSE IF ~on
                     THEN /\ Answer(id, "refused_off")
                          /\ UNCHANGED <<run, staleAdmitted, startedOff>>
                     ELSE /\ run' = [run EXCEPT ![id] = "running"]
                          /\ journal' = [journal EXCEPT ![id] =
                                            IF JournalBeforeRun THEN "started" ELSE @]
                          /\ staleAdmitted' = (staleAdmitted \/ stale)
                          /\ startedOff' = (startedOff \/ ~master)
                          /\ UNCHANGED <<held, back>>
    /\ UNCHANGED <<server_vars, up, drops, acted, master, seen, stopOwed, linkEpoch,
                   stopped, dropSeen, via>>

\* The run does its work (the capability's run/4, in a task of the runs'
\* supervisor): for an effect, the moment something changes.
Act(id) ==
    /\ run[id] = "running"
    /\ run' = [run EXCEPT ![id] = "acted"]
    /\ acted' = [acted EXCEPT ![id] = 1]
    /\ UNCHANGED <<server_vars, link_vars, held, journal, master, seen, stopOwed,
                   linkEpoch, stopped, hist_vars>>

\* The run answers Admission (handle_info {ref, result}, :156; ran/3, :515),
\* which records and answers.
Finish(id) ==
    /\ run[id] = "acted"
    /\ run' = [run EXCEPT ![id] = "ended"]
    /\ Answer(id, "ok")
    /\ UNCHANGED <<server_vars, up, down, drops, acted, master, seen, stopOwed,
                   linkEpoch, stopped, hist_vars>>

\* What a status ask is answered (status/2, :616-629; from_journal/2,
\* :631-645): nothing while it runs, the held answer, else the journal's
\* receipt alone, else that there is no record.
StatusAnswer(id) ==
    IF id \in Live THEN back' = back
    ELSE IF held[id] # "none" THEN Say(id, held[id], "full")
    ELSE IF journal[id] # "none" THEN Say(id, journal[id], "receipt")
    ELSE Say(id, "unknown", "none")

\* invoke_status.
Status(m) ==
    /\ Take(m) /\ m.t = "status" /\ AfterItsOpen(m)
    /\ StatusAnswer(m.id)
    /\ UNCHANGED <<server_vars, up, drops, computer_vars, hist_vars>>

\* invoke_cancel (cancel/2, :600-614): a run is stopped and answered
\* cancelled (stop_running/3, :570), exactly once; one that already ended is
\* answered as a status ask is.
Cancel(m) ==
    /\ Take(m) /\ m.t = "cancel" /\ AfterItsOpen(m)
    /\ IF m.id \in Live
          THEN /\ run' = [run EXCEPT ![m.id] = "ended"]
               /\ Answer(m.id, "cancelled")
          ELSE /\ StatusAnswer(m.id)
               /\ UNCHANGED <<run, held, journal>>
    /\ UNCHANGED <<server_vars, up, drops, acted, master, seen, stopOwed, linkEpoch,
                   stopped, hist_vars>>

\* The owner switches everything off at the computer: machine.toml is
\* written (Switches.write/2), and Admission is told (switches_changed/1).
SwitchOff ==
    /\ OwnerCanSwitchOff /\ master
    /\ master' = FALSE /\ stopOwed' = TRUE
    /\ UNCHANGED <<server_vars, link_vars, run, held, journal, acted, seen, linkEpoch,
                   stopped, hist_vars>>

\* Admission hears (handle_cast :switches_changed, :146-150): what runs ends
\* as refused, stopped here (stopped/2, :667-673), each recorded and
\* answered.
HearSwitch ==
    /\ stopOwed
    /\ stopOwed' = FALSE
    /\ run' = [i \in Ids |-> IF i \in Live THEN "ended" ELSE run[i]]
    /\ journal' = [i \in Ids |-> IF i \in Live THEN "refused_stopped_here" ELSE journal[i]]
    /\ held' = [i \in Ids |-> IF i \in Live THEN "refused_stopped_here" ELSE held[i]]
    /\ back' = IF up
                  THEN back \cup {[id |-> i, status |-> "refused_stopped_here", rec |-> "full"] :
                                    i \in Live}
                  ELSE back
    /\ UNCHANGED <<server_vars, up, down, drops, acted, master, seen, linkEpoch, stopped,
                   hist_vars>>

\* A held answer leaves memory (held?/3, expired?/2, :809-816; within_bounds/1,
\* :819).
Expire(id) ==
    /\ AnswersCanExpire /\ held[id] # "none"
    /\ held' = [held EXCEPT ![id] = "none"]
    /\ UNCHANGED <<server_vars, link_vars, run, journal, acted, master, seen, stopOwed,
                   linkEpoch, stopped, hist_vars>>

\* Admission stops and starts again (Desktop.Invoke is :one_for_all,
\* invoke.ex:91): its runs end with it, what it held and what waited in its
\* mailbox are gone, and at start it closes what the crash left started as
\* unknown, interrupted (init/1, :102; recover/1, :192; Journal.interrupted/2,
\* journal.ex:175), and reads the switches anew.
Stop ==
    /\ ComputerCanStop /\ ~stopped
    /\ stopped' = TRUE
    /\ run' = [i \in Ids |-> IF i \in Live THEN "none" ELSE run[i]]
    /\ held' = [i \in Ids |-> "none"]
    /\ journal' = [i \in Ids |-> IF journal[i] = "started" THEN "unknown" ELSE journal[i]]
    /\ down' = {}
    /\ seen' = master /\ stopOwed' = FALSE
    /\ UNCHANGED <<server_vars, up, back, drops, acted, master, linkEpoch, hist_vars>>

\* The home moves on: the computer's next session is with a newer copy, and
\* it keeps that epoch (Relay.keep_epoch/3, DesktopLink.record_epoch/3)
\* before anything relies on it.
MoveOn ==
    /\ HomeCanMoveOn /\ ~up /\ linkEpoch = ServerEpoch
    /\ linkEpoch' = ServerEpoch + 1
    /\ UNCHANGED <<server_vars, link_vars, run, held, journal, acted, master, seen,
                   stopOwed, stopped, hist_vars>>

-----------------------------------------------------------------------------

\* Every call ended.
Done == \A c \in Calls : st[c] = "done"

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E c \in Calls : Send(c) \/ Deadline(c) \/ Wait(c)
    \/ \E m \in back : Receive(m)
    \/ \E m \in down : Open(m) \/ Status(m) \/ Cancel(m)
    \/ \E i \in Ids : Act(i) \/ Finish(i) \/ Expire(i)
    \/ Drop \/ Reconnect \/ SwitchOff \/ HearSwitch \/ Stop \/ MoveOn
    \/ Terminated

\* Fairness only on what the server itself drives: a call is made, an
\* answer that reached the server is taken, and a wait ends. The link, the
\* computer and the owner owe nothing.
Fairness ==
    /\ \A c \in Calls : WF_vars(Send(c)) /\ WF_vars(Deadline(c))
    /\ WF_vars(\E m \in back : Receive(m))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* "An effect is never sent twice by the link" (§6.3): whatever is lost,
\* what a call changes on the computer happens at most once.
EffectAtMostOnce ==
    \A c \in Effects : Cardinality({i \in Ids : CallOf(i) = c /\ acted[i] = 1}) <= 1

\* "A started entry, synced to disk, before the run" (§6.3): whatever acted
\* on this computer is in its journal, at every moment, a stop included.
ActedIsJournaled == \A i \in Ids : acted[i] = 1 => journal[i] # "none"

\* "A stale primary epoch never acts" (§6.2): no request from an older copy
\* of the home is admitted.
StaleEpochNeverActs == ~staleAdmitted

\* "The master switch off refuses everything and ends running work" (§7.2):
\* nothing starts while it is off, and once Admission has heard, nothing
\* runs.
OffAlwaysWins == ~startedOff /\ ((~master /\ ~stopOwed) => Live = {})

\* Every call ends, whatever the link and the computer do, and in the closed
\* set (§6.1): TypeOK holds every outcome to it.
EveryCallEnds == <>(Done /\ \A c \in Calls : out[c] \in Closed)

\* Witnesses: each defined as "the scenario never happens".
\* A call is answered in full after its session dropped and came back.
Witness_ResultAfterReconnect ==
    ~(\E c \in Calls : out[c] = "ok" /\ via[c] = "full" /\ dropSeen[c] /\ try[c] = 1)
\* An effect happened, the computer stopped before it answered, and the
\* receipt the server asked for says only that the outcome is not known.
Witness_UnknownAfterLostAnswer ==
    ~(\E c \in Effects : out[c] = "unknown" /\ via[c] = "receipt" /\ acted[<<c, 1>>] = 1)
\* A read whose answer was lost ran again under a new id and answered.
Witness_ReadRunAgain ==
    ~(\E c \in Calls \ Effects : out[c] = "ok" /\ via[c] = "full" /\ try[c] = 2
                                  /\ acted[<<c, 1>>] = 1 /\ acted[<<c, 2>>] = 1)
\* A request from an older copy of the home is refused by name, on the
\* computer's own record: its session with that copy never comes back.
Witness_StaleRefused == ~(\E i \in Ids : journal[i] = "refused_stale_epoch")
\* The switch going off ended a run, and its call heard so.
Witness_StoppedHere == ~(\E c \in Calls : out[c] = "refused_stopped_here")
\* An effect ran and its answer left the computer's memory: the receipt
\* alone says it was done, and it is not done again.
Witness_ReceiptOnly ==
    ~(\E c \in Effects : out[c] = "ok" /\ via[c] = "receipt" /\ acted[<<c, 1>>] = 1)

=============================================================================
