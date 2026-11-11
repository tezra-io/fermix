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
(*    then sends invoke_open, waits at most the deadline and the link's   *)
(*    allowance, asks for its id's state itself when told a new session   *)
(*    started (after its request, never before), and decides what a lost *)
(*    answer means: an effect ends there (never sent twice), a read is    *)
(*    asked once more under a new id.                                     *)
(*  - Computers.Calls (calls.ex): the waiters, which outlive a session,   *)
(*    and the word to each caller still waiting that a new session began. *)
(*  - Desktop.InvokeFamily (invoke_family.ex): as the computer's next     *)
(*    session starts it tells Calls (reconcile), and hands each           *)
(*    invoke_result to Calls.                                             *)
(*  - Desktop.Invoke and its Admission (invoke.ex, admission.ex): the     *)
(*    epoch check, the switches read at that moment and again when a      *)
(*    request that waited would start, the started record before the run,*)
(*    the finished record before the answer, the answers held in memory   *)
(*    for a status ask, the receipt alone after that, the master switch   *)
(*    off, and what a restart finds.                                      *)
(*  - Computers.Journal (journal.ex): the started and finished records    *)
(*    and the mark a restart leaves on what a crash left started.         *)
(*  - The browser's requests (Computers.Capabilities.Browser.run/4,       *)
(*    Browser.HeldTurn): each runs in its server turn's held process,     *)
(*    which the run only calls, so a run Admission ends leaves what that  *)
(*    process took to go on (Held, INVOKE-1).                             *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - the bound (8 running, 32 waiting, busy past it), the relay's 512    *)
(*    events (one it drops is one never taken), an upload or an answer's  *)
(*    part, and the bytes of anything: one request here is one message,   *)
(*    as the codec delivers it, and a request that waits for a slot or    *)
(*    its upload is one step, Queue (invoke_test.exs,                     *)
(*    invoke_family_test.exs, two_engines_invoke_test.exs);               *)
(*  - a capability's own refusals and failures (its switch, its origin    *)
(*    rules, the sandbox): each is an answer like any other;              *)
(*  - the computer's own deadline timer, which ends a run as timed_out as *)
(*    a cancel ends it as cancelled, and a long-lived request (a deadline *)
(*    of 0: screen.watch, imessage.watch), which holds a running slot and *)
(*    is waited on until cancelled or a new session asks for it, so one   *)
(*    whose run a restart of Admission ended while the session stayed up  *)
(*    is answered by nothing (README, Not modelled);                      *)
(*  - a caller that ends before its answer (Calls sends a cancel) and     *)
(*    Computers.cancel/2, which no code calls yet: the cancel the         *)
(*    deadline sends is the same step;                                    *)
(*  - an id asked twice: the server never repeats one (mint_id), and the  *)
(*    computer answers one it still runs, waits on or holds as a status   *)
(*    ask (known?/2, repeated/2). That is memory, not the journal: one    *)
(*    whose held answer is gone would run again, so the rule rests on     *)
(*    the server and the link never repeating a request;                  *)
(*  - a machine.toml changed by hand: Admission is told only by           *)
(*    Switches.write/2 and forget/1, so later requests are refused and    *)
(*    what runs goes on;                                                   *)
(*  - a journal that cannot be written or read: a started record that     *)
(*    fails runs nothing, a finished record that fails is logged and the  *)
(*    answer still goes. A link file the relay cannot write is no MoveOn: *)
(*    the newer copy's session is not used (Relay.keep_epoch/3), so the   *)
(*    relay and Admission read one epoch, the file's;                     *)
(*  - a computer's own request to its server (the home's services);       *)
(*  - the switch going back on, a second computer, and a restart of the   *)
(*    server's Calls (its waiters time out);                              *)
(*  - a run admitted before the computer learned of a newer copy of the   *)
(*    home: it finishes. The epoch is checked when a request is admitted, *)
(*    not again when one that waited starts.                              *)
(*                                                                         *)
(* One step = one message taken by one process, one write of the          *)
(* journal with what follows it in the same callback, one moment the run  *)
(* acts, or one thing the world does (a drop, a stop, a switch).          *)
(***************************************************************************)

\* SOURCE: apps/fermix_core/lib/fermix_core/computers/invocation.ex @ b9c2a52f4883
\* SOURCE: apps/fermix_core/lib/fermix_core/computers/calls.ex @ 8a46173d76cf
\* SOURCE: apps/fermix_core/lib/fermix_core/computers/journal.ex#append_started,append_finished,lookup,interrupted,close_all,append,write_line,entries,entry @ 344561793d17
\* SOURCE: apps/fermix_core/lib/fermix_core/computers.ex#call,cancel @ 15ac082efc1f
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/invoke.ex @ b71842df3295
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/invoke/admission.ex @ 740e1e827d2d
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/invoke_family.ex#init,handle_event,reconcile @ 8a7c3466672c
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/device_supervisor.ex#children,invoke_spec @ f6ac6a300a5b
\* SOURCE: apps/fermix_core/lib/fermix_core/computers/switches.ex#write,forget,notify @ 8a938ee89c4d
\* SOURCE: apps/fermix_channels/lib/fermix_channels/desktop/relay.ex#hello_ack,connected,keep_epoch,invocation @ 2b7075eee2d1
\* SOURCE: apps/fermix_channels/lib/fermix_channels/mobile/lanes.ex @ 57286e685875
\* SOURCE: apps/fermix_core/lib/fermix_core/computers/capabilities/browser.ex#run @ d85592331818
\* SOURCE: apps/fermix_core/lib/fermix_core/browser/held_turn.ex @ 118d0bc71922

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Calls,              \* the calls on the server, e.g. {e, r}
    Effects,            \* those that change something on the computer
    Held,               \* those of the browser: each runs in its server turn's
                        \* Browser.HeldTurn (Capabilities.Browser.run/4,
                        \* capabilities/browser.ex:233-242; handle_call {:run,
                        \* fun}, held_turn.ex:87), which the run only calls,
                        \* so ending the run leaves what the held turn took to
                        \* go on (INVOKE-1); {} is every other capability,
                        \* whose work ends with its run (Admission.stop_task/2,
                        \* admission.ex:597-605)
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
                        \* (Admission.start/3, admission.ex:496-506;
                        \* Journal.append_started/2, journal.ex:81;
                        \* write_line/3's :file.sync, :247-255); FALSE
                        \* writes the journal only when it ends
    NoResendOfEffects,  \* an effect whose answer is lost ends there
                        \* (Invocation.again/5, invocation.ex:405-411:
                        \* `not request.effect?`); FALSE asks it again as
                        \* a read is
    AskOnceSent,        \* a new session's status ask comes from the caller,
                        \* after its request (Calls.reconnected/2,
                        \* calls.ex:80, tell_reconnected/2, :170;
                        \* Invocation.await/5's :reconnected, invocation.ex:274,
                        \* ask_again/3, :355); FALSE has the family ask for
                        \* every id registered, sent or not
    EpochCheck,         \* a request from an epoch below the link's is
                        \* refused (Admission.current_epoch/2,
                        \* admission.ex:320-332); FALSE admits it
    SwitchReadAtAdmit,  \* the switches are read as each request is
                        \* admitted (Admission.admit/2, admission.ex:307-308;
                        \* switches/1; Invoke.switches_in/1, invoke.ex);
                        \* FALSE uses what was read when Admission started
    SwitchReadAtStart,  \* the switches are read again the moment a request
                        \* that waited for a slot or its upload would start
                        \* (Admission.waited/3, admission.ex:439-444, from
                        \* next/1, :427, and uploaded/3, :480); FALSE starts
                        \* it as it was admitted
    ServerDeadline      \* the caller waits at most its deadline and the
                        \* link's allowance (Invocation.await/5,
                        \* invocation.ex:272-288; wait_left/3, :290-295;
                        \* gave_up/4, :367-378); FALSE waits for ever

ASSUME Effects \subseteq Calls /\ Held \subseteq Calls

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
    st,             \* each call: "idle", "registered" (its id is with
                    \* Calls and its request not sent yet), "waiting", "done"
    try,            \* the ids the call has used; its current id is <<c, try[c]>>
    out,            \* how the call ended, "none" until then
    owed,           \* the caller was told a new session began and has not
                    \* asked for its id's state yet (its mailbox)
    \* the link: the computer's session
    up,             \* the session is up
    down,           \* asks sent to the computer and not yet taken there
    back,           \* answers sent to the server and not yet taken there
    drops,          \* the times it dropped
    \* the computer: Desktop.Invoke's Admission and its journal
    run,            \* each id: "none", "queued" (admitted, waiting for a slot
                    \* or its upload), "running", "acted" (the run did its
                    \* work and has not answered yet), "ended"
    held,           \* the answer held in memory for the id, "none"
    journal,        \* the id's record: "none", "started", or how it ended
    acted,          \* the times the id's work happened on the computer
    master,         \* the master switch, in machine.toml
    seen,           \* the master switch as read when Admission started
    stopOwed,       \* the switch went off and Admission has not heard yet
    linkEpoch,      \* the highest primary epoch the computer has seen
    stopped,        \* the computer stopped once (a bound)
    heldWork,       \* the ids whose request a held turn took and still does,
                    \* though Admission ended their run (INVOKE-1)
    \* history, for the rules and the witnesses
    staleAdmitted,  \* a request from an older copy was admitted
    startedOff,     \* a run started while the master switch was off
    saidNone,       \* each id: the computer answered that it has no record
    dropSeen,       \* the session dropped while the call waited
    via             \* what ended the call: "none" until then, "local" (refused
                    \* before anything was sent), "deadline", or the answer
                    \* it took: "full", "receipt", "no_record"

server_vars == <<st, try, out, owed>>
link_vars == <<up, down, back, drops>>
computer_vars == <<run, held, journal, acted, master, seen, stopOwed, linkEpoch, stopped,
                   heldWork>>
hist_vars == <<staleAdmitted, startedOff, saidNone, dropSeen, via>>
vars == <<server_vars, link_vars, computer_vars, hist_vars>>

TypeOK ==
    /\ st \in [Calls -> {"idle", "registered", "waiting", "done"}]
    /\ try \in [Calls -> 0..MaxTries]
    /\ out \in [Calls -> Closed \cup {"none"}]
    /\ owed \in [Calls -> BOOLEAN]
    /\ up \in BOOLEAN /\ down \subseteq Asks /\ back \subseteq Answers
    /\ drops \in 0..MaxDrops
    /\ run \in [Ids -> {"none", "queued", "running", "acted", "ended"}]
    /\ held \in [Ids -> Closed \cup {"none"}]
    /\ journal \in [Ids -> Closed \cup {"none", "started"}]
    /\ acted \in [Ids -> 0..1]
    /\ master \in BOOLEAN /\ seen \in BOOLEAN /\ stopOwed \in BOOLEAN
    /\ linkEpoch \in 1..2 /\ stopped \in BOOLEAN /\ heldWork \subseteq Ids
    /\ staleAdmitted \in BOOLEAN /\ startedOff \in BOOLEAN
    /\ saidNone \in [Ids -> BOOLEAN]
    /\ dropSeen \in [Calls -> BOOLEAN]
    /\ via \in [Calls -> {"none", "local", "deadline", "full", "receipt", "no_record"}]

Init ==
    /\ st = [c \in Calls |-> "idle"] /\ try = [c \in Calls |-> 0]
    /\ out = [c \in Calls |-> "none"] /\ owed = [c \in Calls |-> FALSE]
    /\ up = TRUE /\ down = {} /\ back = {} /\ drops = 0
    /\ run = [i \in Ids |-> "none"] /\ held = [i \in Ids |-> "none"]
    /\ journal = [i \in Ids |-> "none"] /\ acted = [i \in Ids |-> 0]
    /\ master = TRUE /\ seen = TRUE /\ stopOwed = FALSE
    /\ linkEpoch = 1 /\ stopped = FALSE /\ heldWork = {}
    /\ staleAdmitted = FALSE /\ startedOff = FALSE
    /\ saidNone = [i \in Ids |-> FALSE]
    /\ dropSeen = [c \in Calls |-> FALSE] /\ via = [c \in Calls |-> "none"]

Current(c) == <<c, try[c]>>
\* The ids Calls waits on from the computer, each from its registration on
\* (Calls.register/2, calls.ex:66; tell_reconnected/2, :170).
Registered == {c \in Calls : st[c] \in {"registered", "waiting"}}
Live == {i \in Ids : run[i] \in {"running", "acted"}}
\* What the computer still runs or waits on: a status ask for one of these is
\* answered when it ends.
Pending == Live \cup {i \in Ids : run[i] = "queued"}
\* A browser run that has not acted yet: its request is with the held turn,
\* which goes on if Admission ends the run (INVOKE-1).
HeldRunning == {i \in Ids : run[i] = "running" /\ CallOf(i) \in Held}
\* What still works on the computer: what Admission runs or waits on, and
\* what a held turn goes on with.
Working == Pending \cup heldWork

\* The call ends; a word owed to it is dropped with it (flush/1,
\* invocation.ex:453).
End(c, how, by) ==
    /\ st' = [st EXCEPT ![c] = "done"]
    /\ out' = [out EXCEPT ![c] = how]
    /\ owed' = [owed EXCEPT ![c] = FALSE]
    /\ via' = [via EXCEPT ![c] = by]

-----------------------------------------------------------------------------
(* The server: Computers.call/6 (computers.ex:141), Computers.Invocation   *)

\* invoke/3 (invocation.ex:218-254): a new id (mint_id/0, :461), registered
\* with Calls (register/2, calls.ex:66; :226-236) before anything is sent.
Register(c) ==
    /\ st[c] = "idle"
    /\ st' = [st EXCEPT ![c] = "registered"]
    /\ try' = [try EXCEPT ![c] = 1]
    /\ UNCHANGED <<out, owed, link_vars, computer_vars, hist_vars>>

\* Then invoke_open goes (the transport's open/5, :240-247). With no session
\* nothing is sent and the call is refused (sent/5's :not_connected, :264;
\* reachable/2, :98, says the same before an id is minted).
SendOpen(c) ==
    /\ st[c] = "registered"
    /\ IF up
          THEN /\ st' = [st EXCEPT ![c] = "waiting"]
               /\ down' = down \cup {[t |-> "open", id |-> Current(c)]}
               /\ UNCHANGED <<out, owed, via>>
          ELSE /\ End(c, "refused_unavailable", "local")
               /\ UNCHANGED down
    /\ UNCHANGED <<try, up, back, drops, computer_vars, staleAdmitted, startedOff, saidNone,
                   dropSeen>>

\* An answer says the outcome is not known, or holds only the journal's
\* receipt (lost?/1, :415-417).
Lost(m) == m.status = "unknown" \/ m.rec = "receipt"

\* An invoke_result reaches the family (invoke_family.ex:67), which hands it
\* to Calls (deliver/4, calls.ex:85; route/4, :182), and the caller takes it
\* (await/5, :272; take/3, :298). One for an id nobody waits on is dropped
\* (route/4's :error); one for a request registered and not sent yet stays
\* in the caller's mailbox until it waits. A lost answer ends an effect
\* there; a read is asked once more under a new id (again/5, :405-411),
\* registered and sent as the first was, and a word owed to the first id is
\* dropped (flush/1).
Receive(m) ==
    /\ m \in back
    /\ ~(st[CallOf(m.id)] = "registered" /\ m.id = Current(CallOf(m.id)))
    /\ back' = back \ {m}
    /\ LET c == CallOf(m.id)
           again == Lost(m) /\ try[c] < MaxTries
                    /\ (c \notin Effects \/ ~NoResendOfEffects)
           heard == IF m.rec = "none" THEN "no_record" ELSE m.rec
       IN IF st[c] # "waiting" \/ m.id # Current(c)
             THEN UNCHANGED <<server_vars, via>>
             ELSE IF again
                     THEN /\ try' = [try EXCEPT ![c] = try[c] + 1]
                          /\ st' = [st EXCEPT ![c] = "registered"]
                          /\ owed' = [owed EXCEPT ![c] = FALSE]
                          /\ UNCHANGED <<out, via>>
                     ELSE /\ End(c, m.status, heard)
                          /\ UNCHANGED try
    /\ UNCHANGED <<up, down, drops, computer_vars, staleAdmitted, startedOff, saidNone, dropSeen>>

\* The caller, told a new session began, asks for its id's state itself
\* (await/5's :reconnected, :274; ask_again/3, :355-365): once it waits,
\* that is once its request was sent, and from the process that sent it, so
\* the ask follows the request on the link. With no session it is not sent;
\* the next session tells the caller again.
Ask(c) ==
    /\ AskOnceSent /\ owed[c] /\ st[c] = "waiting"
    /\ owed' = [owed EXCEPT ![c] = FALSE]
    /\ down' = IF up THEN down \cup {[t |-> "status", id |-> Current(c)]} ELSE down
    /\ UNCHANGED <<st, try, out, up, back, drops, computer_vars, hist_vars>>

\* The wait ends (await/5's after, :286; gave_up/4, :367-378): an effect's
\* outcome is not known, a read timed out, and the computer is told to
\* cancel it, best-effort, by the caller (cancel_sent/4, :380).
Deadline(c) ==
    /\ ServerDeadline /\ st[c] = "waiting"
    /\ End(c, IF c \in Effects THEN "unknown" ELSE "timed_out", "deadline")
    /\ down' = IF up THEN down \cup {[t |-> "cancel", id |-> Current(c)]} ELSE down
    /\ UNCHANGED <<try, up, back, drops, computer_vars, staleAdmitted, startedOff, saidNone,
                   dropSeen>>

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
    /\ UNCHANGED <<server_vars, computer_vars, staleAdmitted, startedOff, saidNone, via>>

\* The computer's next session with this server: its family starts and
\* tells Calls (InvokeFamily.init/1, invoke_family.ex:49; reconcile/1, :94),
\* which tells every caller it still waits for (Calls.reconnected/2,
\* calls.ex:80). Without AskOnceSent the family asks the computer itself for
\* every id registered, its request sent or not. A computer that has seen a
\* newer copy of its home never comes back to this one (Relay.hello_ack/2
\* refuses a lower epoch).
Reconnect ==
    /\ ~up /\ linkEpoch <= ServerEpoch
    /\ up' = TRUE
    /\ IF AskOnceSent
          THEN /\ owed' = [c \in Calls |-> owed[c] \/ c \in Registered]
               /\ UNCHANGED down
          ELSE /\ down' = down \cup {[t |-> "status", id |-> Current(c)] : c \in Registered}
               /\ UNCHANGED owed
    /\ UNCHANGED <<st, try, out, back, drops, computer_vars, hist_vars>>

-----------------------------------------------------------------------------
(* The computer: Desktop.Invoke's Admission                                *)

\* The answer goes if the session is up (send_answer/4, admission.ex:775;
\* deliver/5, :788: a refused send is said and nothing more).
Say(id, status, rec) ==
    back' = IF up THEN back \cup {[id |-> id, status |-> status, rec |-> rec]} ELSE back

\* answer/3 (:699-711): the finished record is synced (record_finished/6,
\* :729; Journal.append_finished/2, journal.ex:105), then the answer is sent
\* and held (hold/3, :823), in the one callback.
Answer(id, status) ==
    /\ journal' = [journal EXCEPT ![id] = status]
    /\ held' = [held EXCEPT ![id] = status]
    /\ Say(id, status, "full")

Take(m) == m \in down /\ down' = down \ {m}

\* Admission takes its mailbox in order, and each session hands it what it
\* received in order: a status ask or a cancel is taken after the request it
\* is about, where that one is still to be taken. A request's invoke_status
\* and invoke_cancel name its capability and op and ride its lane
\* (Mobile.Lanes, lanes.ex: @follow_request), the bulk one for a history
\* submit and the interactive one for every other, so none passes it.
AfterItsOpen(m) == [t |-> "open", id |-> m.id] \notin down

\* invoke_open (open/3, :227; admitted/2, :296; admit/2, :307-317): the
\* epoch first (current_epoch/2, :320-332), then the switches as they are
\* now (switched_on/2, :340-349), each a refusal with only a finished
\* record. Then the started record is synced and the run starts (accept/2,
\* :382; start/3, :496-506; launch/3, :509), or the request waits for a
\* slot or its upload (queue/2, :418; upload/2, :420), with no record yet.
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
                     ELSE /\ staleAdmitted' = (staleAdmitted \/ stale)
                          /\ \/ /\ run' = [run EXCEPT ![id] = "running"]
                                /\ journal' = [journal EXCEPT ![id] =
                                                  IF JournalBeforeRun THEN "started" ELSE @]
                                /\ startedOff' = (startedOff \/ ~master)
                             \/ /\ run' = [run EXCEPT ![id] = "queued"]
                                /\ UNCHANGED <<journal, startedOff>>
                          /\ UNCHANGED <<held, back>>
    /\ UNCHANGED <<server_vars, up, drops, acted, master, seen, stopOwed, linkEpoch,
                   stopped, heldWork, saidNone, dropSeen, via>>

\* A request that waited starts once a slot is free or its upload is whole
\* (next/1, :427; uploaded/3, :480), the switches read again at that moment
\* (waited/3, :439-444): off, it is refused as at admission and never runs.
StartQueued(id) ==
    /\ run[id] = "queued"
    /\ IF SwitchReadAtStart /\ ~master
          THEN /\ run' = [run EXCEPT ![id] = "ended"]
               /\ Answer(id, "refused_off")
               /\ UNCHANGED startedOff
          ELSE /\ run' = [run EXCEPT ![id] = "running"]
               /\ journal' = [journal EXCEPT ![id] = IF JournalBeforeRun THEN "started" ELSE @]
               /\ startedOff' = (startedOff \/ ~master)
               /\ UNCHANGED <<held, back>>
    /\ UNCHANGED <<server_vars, up, down, drops, acted, master, seen, stopOwed, linkEpoch,
                   stopped, heldWork, staleAdmitted, saidNone, dropSeen, via>>

\* The run does its work (the capability's run/4, in a task of the runs'
\* supervisor): for an effect, the moment something changes.
Act(id) ==
    /\ run[id] = "running"
    /\ run' = [run EXCEPT ![id] = "acted"]
    /\ acted' = [acted EXCEPT ![id] = 1]
    /\ UNCHANGED <<server_vars, link_vars, held, journal, master, seen, stopOwed,
                   linkEpoch, stopped, heldWork, hist_vars>>

\* The run answers Admission (handle_info {ref, result}, :164; ran/3, :523),
\* which records and answers.
Finish(id) ==
    /\ run[id] = "acted"
    /\ run' = [run EXCEPT ![id] = "ended"]
    /\ Answer(id, "ok")
    /\ UNCHANGED <<server_vars, up, down, drops, acted, master, seen, stopOwed,
                   linkEpoch, stopped, heldWork, hist_vars>>

\* What a status ask is answered (status/2, :636-649; from_journal/2,
\* :651-665): nothing while it runs or waits, the held answer, else the
\* journal's receipt alone, else that there is no record.
StatusAnswer(id) ==
    IF id \in Pending THEN /\ back' = back /\ UNCHANGED saidNone
    ELSE IF held[id] # "none" THEN /\ Say(id, held[id], "full") /\ UNCHANGED saidNone
    ELSE IF journal[id] # "none" THEN /\ Say(id, journal[id], "receipt") /\ UNCHANGED saidNone
    ELSE /\ Say(id, "unknown", "none")
         /\ saidNone' = [saidNone EXCEPT ![id] = TRUE]

\* invoke_status.
Status(m) ==
    /\ Take(m) /\ m.t = "status" /\ AfterItsOpen(m)
    /\ StatusAnswer(m.id)
    /\ UNCHANGED <<server_vars, up, drops, computer_vars, staleAdmitted, startedOff,
                   dropSeen, via>>

\* invoke_cancel (cancel/2, :620-634): a run, or a request that waits, is
\* stopped and answered cancelled (stop_running/3, :590; drop_waiting/3,
\* :612), exactly once; one that already ended is answered as a status ask
\* is. Stopping a run ends its task (stop_task/2, :597-605); a browser run's
\* request goes on in its held turn (INVOKE-1).
Cancel(m) ==
    /\ Take(m) /\ m.t = "cancel" /\ AfterItsOpen(m)
    /\ IF m.id \in Pending
          THEN /\ run' = [run EXCEPT ![m.id] = "ended"]
               /\ heldWork' = heldWork \cup (HeldRunning \cap {m.id})
               /\ Answer(m.id, "cancelled")
               /\ UNCHANGED saidNone
          ELSE /\ StatusAnswer(m.id)
               /\ UNCHANGED <<run, held, journal, heldWork>>
    /\ UNCHANGED <<server_vars, up, drops, acted, master, seen, stopOwed, linkEpoch,
                   stopped, staleAdmitted, startedOff, dropSeen, via>>

\* The owner switches everything off at the computer: machine.toml is
\* written (Switches.write/2), and Admission is told (switches_changed/1).
SwitchOff ==
    /\ OwnerCanSwitchOff /\ master
    /\ master' = FALSE /\ stopOwed' = TRUE
    /\ UNCHANGED <<server_vars, link_vars, run, held, journal, acted, seen, linkEpoch,
                   stopped, heldWork, hist_vars>>

\* Admission hears (handle_cast :switches_changed, :154-158): what runs or
\* waits ends as refused, stopped here (stopped/2, :687-692), each recorded
\* and answered. A browser run's request goes on in its held turn
\* (INVOKE-1).
HearSwitch ==
    /\ stopOwed
    /\ stopOwed' = FALSE
    /\ run' = [i \in Ids |-> IF i \in Pending THEN "ended" ELSE run[i]]
    /\ heldWork' = heldWork \cup HeldRunning
    /\ journal' = [i \in Ids |-> IF i \in Pending THEN "refused_stopped_here" ELSE journal[i]]
    /\ held' = [i \in Ids |-> IF i \in Pending THEN "refused_stopped_here" ELSE held[i]]
    /\ back' = IF up
                  THEN back \cup {[id |-> i, status |-> "refused_stopped_here", rec |-> "full"] :
                                    i \in Pending}
                  ELSE back
    /\ UNCHANGED <<server_vars, up, down, drops, acted, master, seen, linkEpoch, stopped,
                   hist_vars>>

\* A held answer leaves memory (held?/3, expired?/2, :829-836; within_bounds/1,
\* :839).
Expire(id) ==
    /\ AnswersCanExpire /\ held[id] # "none"
    /\ held' = [held EXCEPT ![id] = "none"]
    /\ UNCHANGED <<server_vars, link_vars, run, journal, acted, master, seen, stopOwed,
                   linkEpoch, stopped, heldWork, hist_vars>>

\* Admission stops and starts again (Desktop.Invoke is :one_for_all,
\* invoke.ex:102-112): its runs end with it, what it held, what waited and
\* what waited in its mailbox are gone, and at start it closes what the
\* crash left started as unknown, interrupted (init/1, :108; recover/1, :200;
\* Journal.interrupted/2, journal.ex:175), and reads the switches anew. A
\* held turn lives in the engine's browser tree (Browser.Supervisor), not in
\* Desktop.Invoke: a restart of Admission leaves it going, a stop of the
\* engine ends it too.
Stop ==
    /\ ComputerCanStop /\ ~stopped
    /\ stopped' = TRUE
    /\ run' = [i \in Ids |-> IF i \in Pending THEN "none" ELSE run[i]]
    /\ heldWork' \in {heldWork, heldWork \cup HeldRunning}
    /\ held' = [i \in Ids |-> "none"]
    /\ journal' = [i \in Ids |-> IF journal[i] = "started" THEN "unknown" ELSE journal[i]]
    /\ down' = {}
    /\ seen' = master /\ stopOwed' = FALSE
    /\ UNCHANGED <<server_vars, up, back, drops, acted, master, linkEpoch, hist_vars>>

\* The held turn does a request Admission no longer runs (INVOKE-1): the one
\* it was running when the run was ended, or one waiting in its mailbox
\* behind that, which it takes though its caller is gone (handle_call
\* {:run, fun}, held_turn.ex:87; the caller's GenServer.call, :108).
ActHeld(id) ==
    /\ id \in heldWork
    /\ heldWork' = heldWork \ {id}
    /\ acted' = [acted EXCEPT ![id] = 1]
    /\ UNCHANGED <<server_vars, link_vars, run, held, journal, master, seen, stopOwed,
                   linkEpoch, stopped, hist_vars>>

\* The home moves on: the computer's next session is with a newer copy, and
\* it keeps that epoch in device/desktop.json (Relay.keep_epoch/3, relay.ex:983;
\* DesktopLink.record_epoch/3) before anything relies on it. A write that
\* fails is no move: the newer copy's session is not used (connected/3,
\* :910), so the relay and Admission read the one epoch, the file's.
MoveOn ==
    /\ HomeCanMoveOn /\ ~up /\ linkEpoch = ServerEpoch
    /\ linkEpoch' = ServerEpoch + 1
    /\ UNCHANGED <<server_vars, link_vars, run, held, journal, acted, master, seen,
                   stopOwed, stopped, heldWork, hist_vars>>

-----------------------------------------------------------------------------

\* Every call ended.
Done == \A c \in Calls : st[c] = "done"

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E c \in Calls : Register(c) \/ SendOpen(c) \/ Ask(c) \/ Deadline(c) \/ Wait(c)
    \/ \E m \in back : Receive(m)
    \/ \E m \in down : Open(m) \/ Status(m) \/ Cancel(m)
    \/ \E i \in Ids : StartQueued(i) \/ Act(i) \/ Finish(i) \/ Expire(i) \/ ActHeld(i)
    \/ Drop \/ Reconnect \/ SwitchOff \/ HearSwitch \/ Stop \/ MoveOn
    \/ Terminated

\* Fairness only on what the server itself drives: a call is made, an
\* answer that reached the server is taken, the caller asks, and a wait
\* ends. The link, the computer and the owner owe nothing.
Fairness ==
    /\ \A c \in Calls : WF_vars(Register(c)) /\ WF_vars(SendOpen(c)) /\ WF_vars(Ask(c))
                        /\ WF_vars(Deadline(c))
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
\* nothing starts while it is off, a request that waited included, and once
\* Admission has heard, nothing runs or waits, in Admission or in a browser
\* turn's held process.
OffAlwaysWins == ~startedOff /\ ((~master /\ ~stopOwed) => Working = {})

\* "Unknown" means not known (§6.3): once the computer has answered that it
\* has no record of a request, that request never acts, so an effect that
\* ends not known on that answer did not happen behind the owner's back,
\* and a read asked again runs once. The server asks only about a request
\* it sent, and the ask never passes the request.
NoRecordIsFinal == \A i \in Ids : saidNone[i] => acted[i] = 0

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
\* A request that waited for a slot or its upload was refused off when it
\* would have started: the switch went off before Admission heard.
Witness_WaitedRefusedOff ==
    ~(\E i \in Ids : journal[i] = "refused_off" /\ run[i] = "ended")

=============================================================================
