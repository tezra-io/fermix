--------------------------- MODULE HistorySubmit ---------------------------
(***************************************************************************)
(* One home, many computers (M97 §8.1, §8.5): each computer records raw    *)
(* history into its own store, forms a finished sitting from what it has   *)
(* not sent, and submits it to the home (`history.submit`), which makes    *)
(* the note. The owner purges a window from chat, on the home, for one     *)
(* computer or all, while a computer may be away, a sitting may be in      *)
(* flight or being summarized, and a late event may still be recorded.     *)
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
(*  - ComputerHistory.Delivery.deliver/1 (delivery.ex) and                *)
(*    MachineService (machine_service.ex): a connected computer is sent  *)
(*    every interval it has not applied, and applies them: its raw events *)
(*    inside go, and its fence refuses one recorded inside later          *)
(*    (ComputerHistorySql.fence_window/4, insert_events/2).               *)
(*                                                                         *)
(* Left out, each a single call ExUnit covers: the signal gate, the       *)
(* renderer and the summary itself, the pause (an interval of its own     *)
(* kind refused by the same check), the 48-hour expiry and the pruning of *)
(* intervals, the home's own machine (it applies a purge in the purge's   *)
(* own command, `Purge.purge/2`), the roll-up's purge guard, a computer  *)
(* restarting (its store survives; a sitting in flight is formed again). *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/sittings.ex#run,step,dispatch,send_sitting,sitting,settle,settled
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/submission.ex#accept,unnoted,unrefused,refused_by,make,write
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/computer_history_sql.ex#insert_note,insert_note_in_tx,reaching_intervals,purge_notes,purge_notes_in_tx,scoped_notes,fence_window,fence_window_in_tx,insert_events,insert_unless_purged,stamped_in_purge?
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/spool.ex#apply_intervals,apply_interval,mark_applied,apply_at
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/delivery.ex
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/purge.ex#purge,fence_here

EXTENDS Naturals, FiniteSets

CONSTANTS
    Computers,          \* the home's computers
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
    RefusalNamesAllPending \* a refusal names every interval above the sitting's mark, not only those reaching it (submission.ex refused_by)

VARIABLES
    recorded,   \* computer -> stamps it has recorded (each once)
    raw,        \* computer -> its raw events still in its store
    sent,       \* computer -> stamps its cursor passed (noted)
    mark,       \* computer -> highest interval it applied
    connected,  \* computer -> its link is up
    away,       \* times a computer went away
    stage,      \* computer -> "none" | "half" | "out" | "summarizing" | "answered"
    fmark,      \* computer -> the mark the sitting in flight carries
    fstamps,    \* computer -> the stamps of the sitting in flight
    answer,     \* computer -> the intervals refusing its sitting; {} when it was noted
    notes,      \* the home's notes: [c, stamps]
    purges,     \* the home's purge intervals: [id, from, to, scope]
    nextId

vars == <<recorded, raw, sent, mark, connected, away, stage, fmark, fstamps, answer,
          notes, purges, nextId>>

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
Applied(c) == {p \in purges : p.id <= mark[c] /\ Covers(p, c)}
Pending(c) == {p \in purges : p.id > mark[c] /\ Covers(p, c)}
MaxId(R) == Max({p.id : p \in R})

TypeOK ==
    /\ recorded \in [Computers -> SUBSET Stamps]
    /\ raw \in [Computers -> SUBSET Stamps]
    /\ sent \in [Computers -> SUBSET Stamps]
    /\ mark \in [Computers -> 0..MaxPurges]
    /\ connected \in [Computers -> BOOLEAN]
    /\ away \in 0..MaxAway
    /\ stage \in [Computers -> {"none", "half", "out", "summarizing", "answered"}]
    /\ fmark \in [Computers -> 0..MaxPurges]
    /\ fstamps \in [Computers -> SUBSET Stamps]
    /\ answer \in [Computers -> SUBSET Interval]
    /\ notes \subseteq Note
    /\ purges \subseteq Interval
    /\ nextId \in 1..(MaxPurges + 1)

Init ==
    /\ recorded = [c \in Computers |-> {}]
    /\ raw = [c \in Computers |-> {}]
    /\ sent = [c \in Computers |-> {}]
    /\ mark = [c \in Computers |-> 0]
    /\ connected = [c \in Computers |-> TRUE]
    /\ away = 0
    /\ stage = [c \in Computers |-> "none"]
    /\ fmark = [c \in Computers |-> 0]
    /\ fstamps = [c \in Computers |-> {}]
    /\ answer = [c \in Computers |-> {}]
    /\ notes = {}
    /\ purges = {}
    /\ nextId = 1

-----------------------------------------------------------------------------
(* THE COMPUTER *)

\* The recorder's flush into the store (Ingest.ingest/2 -> Spool.insert_events
\* -> insert_unless_purged): a stamp inside an applied interval is fenced. A
\* late event may carry any stamp.
Record(c, t) ==
    /\ t \notin recorded[c]
    /\ recorded' = [recorded EXCEPT ![c] = @ \cup {t}]
    /\ raw' = [raw EXCEPT ![c] =
                 IF ComputerFences /\ \E p \in Applied(c) : Inside(p, t) THEN @ ELSE @ \cup {t}]
    /\ UNCHANGED <<sent, mark, connected, away, stage, fmark, fstamps, answer, notes, purges,
                   nextId>>

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
    /\ UNCHANGED <<recorded, raw, sent, mark, connected, away, answer, notes, purges, nextId>>

ReadSecond(c) ==
    /\ stage[c] = "half"
    /\ IF MarkBeforeEvents
          THEN /\ fstamps' = [fstamps EXCEPT ![c] = Unsent(c)]
               /\ stage' = [stage EXCEPT ![c] = IF Unsent(c) = {} THEN "none" ELSE "out"]
               /\ UNCHANGED fmark
          ELSE /\ fmark' = [fmark EXCEPT ![c] = TheMark(c)]
               /\ stage' = [stage EXCEPT ![c] = "out"]
               /\ UNCHANGED fstamps
    /\ UNCHANGED <<recorded, raw, sent, mark, connected, away, answer, notes, purges, nextId>>

\* The answer reaches the computer (HistoryUplink.submit -> Sittings.settle):
\* summarized moves the cursor past the sitting; a refusal's intervals are
\* applied (Spool.apply_intervals/3), and the sitting is formed again.
Settle(c) ==
    /\ stage[c] = "answered"
    /\ connected[c]
    /\ IF answer[c] = {}
          THEN /\ sent' = [sent EXCEPT ![c] = @ \cup fstamps[c]]
               /\ UNCHANGED <<raw, mark>>
          ELSE /\ raw' = [raw EXCEPT ![c] = {t \in @ : ~\E p \in answer[c] : Inside(p, t)}]
               /\ mark' = [mark EXCEPT ![c] = IF MaxId(answer[c]) > @ THEN MaxId(answer[c]) ELSE @]
               /\ UNCHANGED sent
    /\ stage' = [stage EXCEPT ![c] = "none"]
    /\ UNCHANGED <<recorded, connected, away, fmark, fstamps, answer, notes, purges, nextId>>

\* No answer: the request or its answer was lost with the link. The sitting is
\* held and formed again later (`{:held, "unanswered"}`).
Lose(c) ==
    /\ stage[c] \in {"out", "answered"}
    /\ ~connected[c]
    /\ stage' = [stage EXCEPT ![c] = "none"]
    /\ UNCHANGED <<recorded, raw, sent, mark, connected, away, fmark, fstamps, answer, notes,
                   purges, nextId>>

GoAway(c) ==
    /\ ComputersGoAway
    /\ connected[c]
    /\ away < MaxAway
    /\ connected' = [connected EXCEPT ![c] = FALSE]
    /\ away' = away + 1
    /\ UNCHANGED <<recorded, raw, sent, mark, stage, fmark, fstamps, answer, notes, purges, nextId>>

Return(c) ==
    /\ ~connected[c]
    /\ connected' = [connected EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<recorded, raw, sent, mark, away, stage, fmark, fstamps, answer, notes, purges,
                   nextId>>

-----------------------------------------------------------------------------
(* THE HOME *)

\* Submission.accept/3 takes the sitting: answered from its note when already
\* noted (unnoted/3), refused with the intervals above its mark that reach it
\* (unrefused/3), otherwise summarized next.
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
    /\ UNCHANGED <<recorded, raw, sent, mark, connected, away, fmark, fstamps, notes, purges,
                   nextId>>

\* The summary is made (a provider call), then insert_note/6 writes it in one
\* transaction that checks the intervals again (WriteRechecks).
Write(c) ==
    /\ stage[c] = "summarizing"
    /\ LET refusing == Refusing(c, fmark[c], fstamps[c])
       IN IF WriteRechecks /\ refusing /= {}
             THEN /\ answer' = [answer EXCEPT ![c] = Named(c, fmark[c], fstamps[c])]
                  /\ UNCHANGED notes
             ELSE /\ notes' = notes \cup {[c |-> c, stamps |-> fstamps[c]]}
                  /\ answer' = [answer EXCEPT ![c] = {}]
    /\ stage' = [stage EXCEPT ![c] = "answered"]
    /\ UNCHANGED <<recorded, raw, sent, mark, connected, away, fmark, fstamps, purges, nextId>>

\* /history purge from chat (Purge.purge/2 -> purge_notes/5): one transaction.
Purge(w, scope) ==
    /\ OwnerCanPurge
    /\ nextId <= MaxPurges
    /\ LET p == [id |-> nextId, from |-> w[1], to |-> w[2], scope |-> scope]
       IN /\ purges' = purges \cup {p}
          /\ notes' = IF PurgeDeletesNotes
                         THEN {n \in notes : ~(Covers(p, n.c) /\ Reaches(p, n.stamps))}
                         ELSE notes
    /\ nextId' = nextId + 1
    /\ UNCHANGED <<recorded, raw, sent, mark, connected, away, stage, fmark, fstamps, answer>>

\* Delivery.deliver/1 to a connected computer, which applies every interval
\* it has not (MachineService.run/4 -> Spool.apply_at/3): raw events inside
\* go, and the mark rises.
Deliver(c) ==
    /\ connected[c]
    /\ Pending(c) /= {}
    /\ raw' = [raw EXCEPT ![c] = {t \in @ : ~\E p \in Pending(c) : Inside(p, t)}]
    /\ mark' = [mark EXCEPT ![c] = MaxId(Pending(c))]
    /\ UNCHANGED <<recorded, sent, connected, away, stage, fmark, fstamps, answer, notes, purges,
                   nextId>>

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
    /\ (nextId > MaxPurges \/ ~OwnerCanPurge)

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E c \in Computers, t \in Stamps : Record(c, t)
    \/ \E c \in Computers :
          ReadFirst(c) \/ ReadSecond(c) \/ Arrive(c) \/ Write(c) \/ Settle(c) \/ Lose(c)
          \/ GoAway(c) \/ Return(c) \/ Deliver(c)
    \/ \E w \in Windows, s \in Scopes : Purge(w, s)
    \/ Terminated

\* Fermix's own steps always happen: a computer's cycle and the home's answer,
\* the home's delivery, and a computer that is away comes back. The owner, the
\* recorder's events and a link that drops get no fairness.
Fairness ==
    \A c \in Computers :
        /\ WF_vars(ReadFirst(c)) /\ WF_vars(ReadSecond(c))
        /\ WF_vars(Arrive(c)) /\ WF_vars(Write(c)) /\ WF_vars(Settle(c))
        /\ WF_vars(Lose(c)) /\ WF_vars(Return(c)) /\ WF_vars(Deliver(c))

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
