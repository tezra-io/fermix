--------------------------- MODULE HistorySubmit ---------------------------
(***************************************************************************)
(* One home, many computers (M97 §8.1, §8.5): each computer records raw    *)
(* history into its own store, forms a finished sitting from what it has   *)
(* not sent, and submits it to the home (`history.submit`), which makes    *)
(* the note. The owner purges a window from chat, on the home, for one     *)
(* computer or all, while a computer may be away, a sitting may be in      *)
(* flight or being summarized, and a late event may still be recorded.     *)
(* The home's own machine, when it records (a Mac that is its own home),   *)
(* sends its sittings the same way, in process.                            *)
(*                                                                         *)
(* The rule: a purged window never gains a note, whatever order the purge  *)
(* and a late sitting arrive in.                                           *)
(*                                                                         *)
(* What it describes:                                                      *)
(*  - ComputerHistory.Sittings.run/1 (sittings.ex): one step reads the     *)
(*    mark of the home's intervals this computer applied                   *)
(*    (Spool.link/1), then the events past its cursor (Spool.events_after); *)
(*    the sitting carries that mark ("mark"); the answer moves the cursor  *)
(*    (summarized) or applies the intervals a refusal names               *)
(*    (Spool.apply_intervals/3); no answer holds the sitting for later.   *)
(*  - ComputerHistory.Submission.accept/3 (submission.ex): a sitting       *)
(*    already noted is answered from its note; one reached by an interval *)
(*    above its mark, of its computer or of every computer, is refused,   *)
(*    naming every interval above its mark, oldest first, so the mark the *)
(*    computer then records never steps over one it was not given         *)
(*    (HS-1, fixed); otherwise it is summarized (a provider call,         *)
(*    its own step) and written.                                          *)
(*  - ComputerHistorySql.insert_note/6 and reaching_intervals/5            *)
(*    (computer_history_sql.ex): the write checks the intervals again,    *)
(*    inside its own transaction.                                         *)
(*  - ComputerHistorySql.purge_notes/5: one transaction deletes the notes *)
(*    of that scope that reach the window and records the interval.      *)
(*  - Spool.apply_intervals/3 (spool.ex): each interval is its own        *)
(*    transaction (fence_window/4: the raw events inside go, and the      *)
(*    interval is recorded in the store's fence, which refuses an event   *)
(*    stamped inside it that is recorded later, insert_events/2); the     *)
(*    mark of the highest one is written last, in a call of its own       *)
(*    (set_home_mark/2, which never lowers it).                           *)
(*  - ComputerHistory.Delivery.deliver/1 (delivery.ex) and                *)
(*    MachineService (machine_service.ex): a connected computer is sent  *)
(*    every interval it has not applied, and applies them, in a process   *)
(*    of its own beside its sending cycle (Spool.apply_at/3).             *)
(*  - The home's own machine (Delivery.apply_here/1, from Purge.purge/2,  *)
(*    the pause command's apply_here/2 and the home scheduler's tick): no  *)
(*    delivery reaches it; it applies every interval of its own above its  *)
(*    mark, oldest first, the fences first and the mark last, so its mark  *)
(*    never steps over an interval it has not applied (HS-2, fixed).       *)
(*                                                                         *)
(* Left out, each a single call ExUnit covers or a step that only writes  *)
(* less: the signal gate, the renderer and the summary itself, the pause  *)
(* (an interval of its own kind, refused by the same check and applied    *)
(* the same way; it deletes no note), the 48-hour expiry and the pruning  *)
(* of intervals, the roll-up's purge guard, a computer restarting (its    *)
(* store survives; a sitting in flight is formed again), the home         *)
(* restarting or giving up a sitting it was summarizing (no note is       *)
(* written; the computer holds the sitting and sends it again), and the   *)
(* home's record of what each computer applied (delivered_mark), which is *)
(* at most the computer's own mark, so a delivery from it sends the same  *)
(* pending intervals and some it already applied.                         *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/sittings.ex#run,step,dispatch,send_sitting,sitting,settle,settled @ 29d8a7f0d8ef
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/submission.ex#accept,unnoted,unrefused,refused_by,make,write @ b15e685ca908
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/computer_history_sql.ex#insert_note,insert_note_in_tx,noted,reaching_intervals,intervals_after,purge_notes,purge_notes_in_tx,scoped_notes,fence_window,fence_window_in_tx,insert_events,insert_unless_purged,stamped_in_purge?,link,set_home_mark @ 6a465364b796
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/spool.ex#link,events_after,fence,apply_intervals,apply_interval,mark_applied,apply_at @ 278f51a2319a
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/delivery.ex @ c951071b0b22
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/machine_service.ex @ 98dc1a74bb86
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/purge.ex#purge,apply_here @ c6c55d547d1e
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/controller.ex#home_uplink @ 8176fcfadb34
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/summarizer/scheduler.ex#maybe_roll_up,apply_here @ f144c2cf4979
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/commands/history.ex#pause_everywhere,apply_here,run_purge @ 085fc4f0e215

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Computers,          \* the home's machines that record
    HomeMachine,        \* the home's own machine when it records (a Mac that is its own home),
                        \* one of Computers; any other value: no machine here records
    Stamps,             \* the times an event can be stamped at
    MaxPurges,          \* purges from chat in one behaviour
    MaxAway,            \* times a computer goes away in one behaviour
    \* Environment switches
    OwnerCanPurge,      \* the owner purges from chat
    ScopedPurges,       \* a purge may name one computer, not only every one
    ComputersGoAway,    \* a computer's link drops (asleep, offline)
    \* Mechanism switches (TRUE is the real code)
    WriteRechecks,      \* insert_note checks the intervals in its transaction (computer_history_sql.ex insert_note_in_tx)
    ComputerFences,     \* an applied interval refuses an event recorded inside it later (insert_unless_purged)
    MarkBeforeEvents,   \* Sittings.step reads the mark before the events (sittings.ex step)
    PurgeDeletesNotes,  \* purge_notes deletes the notes that reach the window (purge_notes_in_tx)
    MarkSkipsApplied,   \* the sitting carries the mark, so an interval it applied is not asked again (reaching_intervals after_id)
    RefusalNamesAllPending, \* a refusal names every interval above the sitting's mark, not only those reaching it (submission.ex refused_by)
    MarkAfterFences,    \* apply_intervals fences every interval first and writes the mark last (spool.ex mark_applied)
    HereAppliesPending  \* the home's own machine applies every interval of its own above its mark (delivery.ex apply_here)

VARIABLES
    recorded,   \* computer -> stamps it has recorded (each once)
    raw,        \* computer -> its raw events still in its store
    sent,       \* computer -> stamps its cursor passed (noted)
    fence,      \* computer -> the intervals its store's fence holds (computer_history_purges there)
    mark,       \* computer -> highest interval it recorded as applied (computer_history_link.home_mark)
    applying,   \* computer -> the intervals a delivery is applying there, between its two halves
    connected,  \* computer -> its link is up
    away,       \* times a computer went away
    stage,      \* computer -> "none" | "half" | "out" | "summarizing" | "answered"
    fmark,      \* computer -> the mark the sitting in flight carries
    fstamps,    \* computer -> the stamps of the sitting in flight
    answer,     \* computer -> the intervals refusing its sitting; {} when it was noted
    notes,      \* the home's notes: [c, stamps]
    purges,     \* the home's purge intervals: [id, from, to, scope]
    hereApply,  \* without HereAppliesPending: purges whose own command has not yet applied them here
    nextId

vars == <<recorded, raw, sent, fence, mark, applying, connected, away, stage, fmark, fstamps,
          answer, notes, purges, hereApply, nextId>>

\* Every purge window over the stamps, as <<from, to>>.
Windows == {w \in Stamps \X Stamps : w[1] <= w[2]}
Scopes == IF ScopedPurges THEN Computers \cup {"all"} ELSE {"all"}
Interval == [id : 1..MaxPurges, from : Stamps, to : Stamps, scope : Computers \cup {"all"}]
Note == [c : Computers, stamps : SUBSET Stamps]

Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

Covers(p, c) == p.scope \in {"all", c}
Inside(p, t) == p.from <= t /\ t <= p.to
\* Range intersection, inclusive like the DELETE and the refusal.
Reaches(p, S) == S /= {} /\ p.from <= Max(S) /\ p.to >= Min(S)

\* The intervals a computer has not applied above `m` that reach a sitting,
\* and what its refusal names: every one above `m`, or only those.
Refusing(c, m, S) == {p \in purges : p.id > m /\ Covers(p, c) /\ Reaches(p, S)}
Above(c, m) == {p \in purges : p.id > m /\ Covers(p, c)}
Named(c, m, S) == IF RefusalNamesAllPending THEN Above(c, m) ELSE Refusing(c, m, S)
Pending(c) == {p \in purges : p.id > mark[c] /\ Covers(p, c)}
MaxId(R) == Max({p.id : p \in R})
Raised(c, R) == IF MaxId(R) > mark[c] THEN MaxId(R) ELSE mark[c]
\* fence_window/4 for each interval of R: the raw events inside go.
Without(c, R) == {t \in raw[c] : ~\E p \in R : Inside(p, t)}

IsHere(c) == c = HomeMachine

\* The computers are interchangeable when none is the home's own machine
\* (checks 10 and 11, safety only).
Symm == Permutations(Computers)

TypeOK ==
    /\ recorded \in [Computers -> SUBSET Stamps]
    /\ raw \in [Computers -> SUBSET Stamps]
    /\ sent \in [Computers -> SUBSET Stamps]
    /\ fence \in [Computers -> SUBSET Interval]
    /\ mark \in [Computers -> 0..MaxPurges]
    /\ applying \in [Computers -> SUBSET Interval]
    /\ connected \in [Computers -> BOOLEAN]
    /\ away \in 0..MaxAway
    /\ stage \in [Computers -> {"none", "half", "out", "summarizing", "answered"}]
    /\ fmark \in [Computers -> 0..MaxPurges]
    /\ fstamps \in [Computers -> SUBSET Stamps]
    /\ answer \in [Computers -> SUBSET Interval]
    /\ notes \subseteq Note
    /\ purges \subseteq Interval
    /\ hereApply \subseteq Interval
    /\ nextId \in 1..(MaxPurges + 1)

Init ==
    /\ recorded = [c \in Computers |-> {}]
    /\ raw = [c \in Computers |-> {}]
    /\ sent = [c \in Computers |-> {}]
    /\ fence = [c \in Computers |-> {}]
    /\ mark = [c \in Computers |-> 0]
    /\ applying = [c \in Computers |-> {}]
    /\ connected = [c \in Computers |-> TRUE]
    /\ away = 0
    /\ stage = [c \in Computers |-> "none"]
    /\ fmark = [c \in Computers |-> 0]
    /\ fstamps = [c \in Computers |-> {}]
    /\ answer = [c \in Computers |-> {}]
    /\ notes = {}
    /\ purges = {}
    /\ hereApply = {}
    /\ nextId = 1

-----------------------------------------------------------------------------
(* THE COMPUTER *)

\* The recorder's flush into the store (Ingest.ingest/2 -> Spool.insert_events
\* -> insert_unless_purged): a stamp inside an interval of the store's fence
\* is refused. A late event may carry any stamp.
Record(c, t) ==
    /\ t \notin recorded[c]
    /\ recorded' = [recorded EXCEPT ![c] = @ \cup {t}]
    /\ raw' = [raw EXCEPT ![c] =
                 IF ComputerFences /\ \E p \in fence[c] : Inside(p, t) THEN @ ELSE @ \cup {t}]
    /\ UNCHANGED <<sent, fence, mark, applying, connected, away, stage, fmark, fstamps, answer,
                   notes, purges, hereApply, nextId>>

TheMark(c) == IF MarkSkipsApplied THEN mark[c] ELSE 0
Unsent(c) == raw[c] \ sent[c]

\* Sittings.step: two store calls, Spool.link/1 then Spool.events_after/3, in
\* that order (MarkBeforeEvents) or the other.
ReadFirst(c) ==
    /\ stage[c] = "none"
    /\ Unsent(c) /= {}
    /\ stage' = [stage EXCEPT ![c] = "half"]
    /\ IF MarkBeforeEvents
          THEN fmark' = [fmark EXCEPT ![c] = TheMark(c)] /\ UNCHANGED fstamps
          ELSE fstamps' = [fstamps EXCEPT ![c] = Unsent(c)] /\ UNCHANGED fmark
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, answer, notes,
                   purges, hereApply, nextId>>

ReadSecond(c) ==
    /\ stage[c] = "half"
    /\ IF MarkBeforeEvents
          THEN /\ fstamps' = [fstamps EXCEPT ![c] = Unsent(c)]
               /\ stage' = [stage EXCEPT ![c] = IF Unsent(c) = {} THEN "none" ELSE "out"]
               /\ UNCHANGED fmark
          ELSE /\ fmark' = [fmark EXCEPT ![c] = TheMark(c)]
               /\ stage' = [stage EXCEPT ![c] = "out"]
               /\ UNCHANGED fstamps
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, answer, notes,
                   purges, hereApply, nextId>>

\* The answer reaches the computer (HistoryUplink.submit -> Sittings.settle):
\* summarized moves the cursor past the sitting; a refusal's intervals are
\* applied (Spool.apply_intervals/3), the ones it already applied again, and
\* the sitting is formed again. Its fences and its mark are separate calls of
\* the cycle's own process, folded here: the reads that could fall between
\* them are this same cycle's, and a Record between them meets the fence
\* already written.
Settle(c) ==
    /\ stage[c] = "answered"
    /\ connected[c]
    /\ IF answer[c] = {}
          THEN /\ sent' = [sent EXCEPT ![c] = @ \cup fstamps[c]]
               /\ UNCHANGED <<raw, fence, mark>>
          ELSE /\ raw' = [raw EXCEPT ![c] = Without(c, answer[c])]
               /\ fence' = [fence EXCEPT ![c] = @ \cup answer[c]]
               /\ mark' = [mark EXCEPT ![c] = Raised(c, answer[c])]
               /\ UNCHANGED sent
    /\ stage' = [stage EXCEPT ![c] = "none"]
    /\ UNCHANGED <<recorded, applying, connected, away, fmark, fstamps, answer, notes, purges,
                   hereApply, nextId>>

\* No answer: the request or its answer was lost with the link. The sitting is
\* held and formed again later (`{:held, "unanswered"}`).
Lose(c) ==
    /\ stage[c] \in {"out", "answered"}
    /\ ~connected[c]
    /\ stage' = [stage EXCEPT ![c] = "none"]
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, fmark, fstamps,
                   answer, notes, purges, hereApply, nextId>>

\* The home's own machine never goes away from its home.
GoAway(c) ==
    /\ ComputersGoAway
    /\ ~IsHere(c)
    /\ connected[c]
    /\ away < MaxAway
    /\ connected' = [connected EXCEPT ![c] = FALSE]
    /\ away' = away + 1
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, stage, fmark, fstamps, answer,
                   notes, purges, hereApply, nextId>>

Return(c) ==
    /\ ~connected[c]
    /\ connected' = [connected EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, away, stage, fmark, fstamps,
                   answer, notes, purges, hereApply, nextId>>

-----------------------------------------------------------------------------
(* THE HOME *)

\* Submission.accept/3 takes the sitting: answered from its note when already
\* noted (unnoted/3), refused when an interval above its mark reaches it
\* (unrefused/3), naming what refused_by/4 reads, otherwise summarized next.
\* Three Repo calls folded into one step: a purge between them only adds an
\* interval to what the refusal names, which is still every one above the
\* mark, oldest first.
Arrive(c) ==
    /\ stage[c] = "out"
    /\ connected[c]
    /\ LET noted == [c |-> c, stamps |-> fstamps[c]] \in notes
           refusing == Refusing(c, fmark[c], fstamps[c])
       IN \/ /\ noted
             /\ answer' = [answer EXCEPT ![c] = {}]
             /\ stage' = [stage EXCEPT ![c] = "answered"]
          \/ /\ ~noted
             /\ refusing /= {}
             /\ answer' = [answer EXCEPT ![c] = Named(c, fmark[c], fstamps[c])]
             /\ stage' = [stage EXCEPT ![c] = "answered"]
          \/ /\ ~noted
             /\ refusing = {}
             /\ stage' = [stage EXCEPT ![c] = "summarizing"]
             /\ UNCHANGED answer
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, fmark, fstamps,
                   notes, purges, hereApply, nextId>>

\* The summary is made (a provider call), then insert_note/6 writes it in one
\* transaction that checks the intervals again (WriteRechecks). A refused
\* write's answer names what refused_by/4 reads after it, folded in as above.
Write(c) ==
    /\ stage[c] = "summarizing"
    /\ LET refusing == Refusing(c, fmark[c], fstamps[c])
       IN IF WriteRechecks /\ refusing /= {}
             THEN /\ answer' = [answer EXCEPT ![c] = Named(c, fmark[c], fstamps[c])]
                  /\ UNCHANGED notes
             ELSE /\ notes' = notes \cup {[c |-> c, stamps |-> fstamps[c]]}
                  /\ answer' = [answer EXCEPT ![c] = {}]
    /\ stage' = [stage EXCEPT ![c] = "answered"]
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, fmark, fstamps,
                   purges, hereApply, nextId>>

\* /history purge from chat (Purge.purge/2 -> purge_notes/5): one transaction.
\* When it covers the home's own machine, the same command then applies what
\* that machine owes there (ApplyHere below), in steps of their own.
Purge(w, scope) ==
    /\ OwnerCanPurge
    /\ nextId <= MaxPurges
    /\ LET p == [id |-> nextId, from |-> w[1], to |-> w[2], scope |-> scope]
       IN /\ purges' = purges \cup {p}
          /\ notes' = IF PurgeDeletesNotes
                         THEN {n \in notes : ~(Covers(p, n.c) /\ Reaches(p, n.stamps))}
                         ELSE notes
          /\ hereApply' = IF ~HereAppliesPending /\ HomeMachine \in Computers
                                /\ Covers(p, HomeMachine)
                             THEN hereApply \cup {p} ELSE hereApply
    /\ nextId' = nextId + 1
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, stage, fmark,
                   fstamps, answer>>

\* The first half of applying R on the home's own machine, as DeliverFirst
\* does on a computer: the fences (or, with MarkAfterFences off, the mark), the
\* other half to follow in DeliverSecond(HomeMachine).
ApplyHereOf(R) ==
    /\ applying' = [applying EXCEPT ![HomeMachine] = R]
    /\ IF MarkAfterFences
          THEN /\ raw' = [raw EXCEPT ![HomeMachine] = Without(HomeMachine, R)]
               /\ fence' = [fence EXCEPT ![HomeMachine] = @ \cup R]
               /\ UNCHANGED mark
          ELSE /\ mark' = [mark EXCEPT ![HomeMachine] = Raised(HomeMachine, R)]
               /\ UNCHANGED <<raw, fence>>

\* The home's own machine applies what it owes (Delivery.apply_here/1): run by
\* each purge command (Purge.purge/2) and pause command (History.apply_here/2)
\* once the home recorded its interval, and by the home scheduler's tick
\* (Scheduler.apply_here/1), which is how one whose apply failed is applied.
\* It reads the mark (Spool.link/1), then every interval of this machine above
\* it (intervals_after/4), and applies them (Spool.apply_intervals/3): every
\* fence first, here, and the mark last, in DeliverSecond, which this machine
\* shares with a computer's delivery. The two reads are folded: the mark only
\* rises and an interval is read once committed, so a step between them only
\* applies more. Two commands may run at once, and one that fails after the
\* home recorded its interval applies nothing, which up to the point it
\* matters is the same as applying it later. One apply here runs at a time
\* here (applying is empty); in the code two may overlap (two commands, or a
\* command and the tick), which is safe in any order of their calls: each
\* fences every interval above the mark it read before it raises the mark
\* to the highest of them, and set_home_mark/2 never lowers it.
\*
\* Without HereAppliesPending (the code at 826ba83a, HS-2): Purge.fence_here/4
\* and History.pause_here/3 applied the command's own interval alone, and
\* mark_applied recorded its id as the mark.
ApplyHere ==
    /\ HomeMachine \in Computers
    /\ applying[HomeMachine] = {}
    /\ \/ /\ HereAppliesPending
          /\ Pending(HomeMachine) /= {}
          /\ ApplyHereOf(Pending(HomeMachine))
          /\ UNCHANGED hereApply
       \/ /\ ~HereAppliesPending
          /\ \E p \in hereApply :
                /\ hereApply' = hereApply \ {p}
                /\ ApplyHereOf({p})
    /\ UNCHANGED <<recorded, sent, connected, away, stage, fmark, fstamps, answer, notes, purges,
                   nextId>>


\* Delivery.deliver/1 to a connected computer (never the home's own machine):
\* MachineService.run/4 -> Spool.apply_at/3 applies every interval it has not,
\* in a process of its own beside the computer's sending cycle. Its two
\* halves: every interval's fence_window/4 (raw events inside go, the fence
\* holds it), and then the mark (set_home_mark/2). With MarkAfterFences off,
\* the mark comes first.
DeliverFirst(c) ==
    /\ ~IsHere(c)
    /\ connected[c]
    /\ applying[c] = {}
    /\ Pending(c) /= {}
    /\ applying' = [applying EXCEPT ![c] = Pending(c)]
    /\ IF MarkAfterFences
          THEN /\ raw' = [raw EXCEPT ![c] = Without(c, Pending(c))]
               /\ fence' = [fence EXCEPT ![c] = @ \cup Pending(c)]
               /\ UNCHANGED mark
          ELSE /\ mark' = [mark EXCEPT ![c] = Raised(c, Pending(c))]
               /\ UNCHANGED <<raw, fence>>
    /\ UNCHANGED <<recorded, sent, connected, away, stage, fmark, fstamps, answer, notes, purges,
                   hereApply, nextId>>

DeliverSecond(c) ==
    /\ applying[c] /= {}
    /\ applying' = [applying EXCEPT ![c] = {}]
    /\ IF MarkAfterFences
          THEN /\ mark' = [mark EXCEPT ![c] = Raised(c, applying[c])]
               /\ UNCHANGED <<raw, fence>>
          ELSE /\ raw' = [raw EXCEPT ![c] = Without(c, applying[c])]
               /\ fence' = [fence EXCEPT ![c] = @ \cup applying[c]]
               /\ UNCHANGED mark
    /\ UNCHANGED <<recorded, sent, connected, away, stage, fmark, fstamps, answer, notes, purges,
                   hereApply, nextId>>

-----------------------------------------------------------------------------

\* The legitimate end: every stamp recorded, nothing in flight, every computer
\* back with nothing unsent and nothing left to apply, no purge left to send.
Done ==
    /\ \A c \in Computers :
          /\ recorded[c] = Stamps
          /\ stage[c] = "none"
          /\ Unsent(c) = {}
          /\ connected[c]
          /\ Pending(c) = {}
          /\ applying[c] = {}
    /\ hereApply = {}
    /\ (nextId > MaxPurges \/ ~OwnerCanPurge)

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E c \in Computers, t \in Stamps : Record(c, t)
    \/ \E c \in Computers :
          ReadFirst(c) \/ ReadSecond(c) \/ Arrive(c) \/ Write(c) \/ Settle(c) \/ Lose(c)
          \/ GoAway(c) \/ Return(c) \/ DeliverFirst(c) \/ DeliverSecond(c)
    \/ \E w \in Windows, s \in Scopes : Purge(w, s)
    \/ ApplyHere
    \/ Terminated

\* Fermix's own steps always happen: a computer's cycle and the home's answer,
\* the home's delivery and the computer's apply of it, the purge command's
\* apply here, and a computer that is away comes back. The owner, the
\* recorder's events and a link that drops get no fairness.
Fairness ==
    /\ \A c \in Computers :
        /\ WF_vars(ReadFirst(c)) /\ WF_vars(ReadSecond(c))
        /\ WF_vars(Arrive(c)) /\ WF_vars(Write(c)) /\ WF_vars(Settle(c))
        /\ WF_vars(Lose(c)) /\ WF_vars(Return(c))
        /\ WF_vars(DeliverFirst(c)) /\ WF_vars(DeliverSecond(c))
    /\ WF_vars(ApplyHere)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* "a purged window never gains a note" (M97 §8.5): no note of a machine holds
\* an event stamped inside a purge of that machine or of every machine.
PurgedWindowNeverGainsANote ==
    \A n \in notes, p \in purges :
        Covers(p, n.c) => \A t \in n.stamps : ~Inside(p, t)

\* "a refused or unanswered sitting is offered again later" (M97 §8.1): every
\* event a computer still holds is noted in the end; none is refused forever.
EverySittingSettles == <>[](\A c \in Computers : Unsent(c) = {})

\* Witnesses: each says the scenario never happens.
Witness_LateSittingRefused ==
    ~\E c \in Computers : stage[c] = "answered" /\ answer[c] /= {}

Witness_NoteSpansPurgedWindow ==
    ~\E n \in notes, p \in purges : Covers(p, n.c) /\ Reaches(p, n.stamps)
=============================================================================
