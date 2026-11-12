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
(*    (Spool.apply_intervals/4); no answer holds the sitting for later.   *)
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
(*  - Spool.apply_intervals/4 (spool.ex): each interval is its own        *)
(*    transaction (fence_window/4: the raw events inside go, and the      *)
(*    interval is recorded in the store's fence, which refuses an event   *)
(*    stamped inside it that is recorded later, insert_events/2); the     *)
(*    mark of the highest one is written last, in a call of its own       *)
(*    (set_home_mark/3, which never lowers it under the same home store). *)
(*  - ComputerHistory.Delivery.deliver/1 (delivery.ex) and                *)
(*    MachineService (machine_service.ex): a connected computer is sent  *)
(*    every interval it has not applied, and applies them, in a process   *)
(*    of its own beside its sending cycle (Spool.apply_at/4).             *)
(*  - The home's own machine (Delivery.apply_here/1, from Purge.purge/2,  *)
(*    the pause command's apply_here/2 and the home scheduler's tick): no  *)
(*    delivery reaches it; it applies every interval of its own above its  *)
(*    mark, oldest first, the fences first and the mark last, so its mark  *)
(*    never steps over an interval it has not applied (HS-2, fixed).       *)
(*  - The home store's identity (ComputerHistory.home_identity/1): the     *)
(*    store's own token (memory.db migration 61), which Archive.install/5  *)
(*    makes again for every store it installs from a stored copy, however  *)
(*    often the same copy (RestoreRenews; a move's or a move back's live   *)
(*    stream, whose ids go on, keeps it: history: :continued, candidate.ex *)
(*    stage_fun/4). A mark is kept with the                                *)
(*    identity of the store it counts (computer_history_link.home):        *)
(*    set_home_mark/3 raises it under the same identity and replaces mark  *)
(*    and identity together under another; history.apply and every answer  *)
(*    to a sitting carry the identity, and a sitting's mark counts only    *)
(*    when its identity is the home's, else the home reads it as 0         *)
(*    (MarkTiedToHome). A restore from a backup, a store whose ids start   *)
(*    again from the backup's, is TakeBackup and Restore (HomeCanRestore,  *)
(*    checks 16 to 20); a server rebuilt from nothing and another home are *)
(*    the same with a token never seen. Two restores from one backup get   *)
(*    two identities (HS-4, fixed). Spool.forget_home/1 at a join or a     *)
(*    leave,                                                               *)
(*    which sets the mark to 0 under no store, is left out: a mark of 0    *)
(*    counts the same under any store.                                     *)
(*                                                                         *)
(* Left out, each a single call ExUnit covers or a step that only writes  *)
(* less: the signal gate, the renderer and the summary itself, the pause  *)
(* (an interval of its own kind, refused by the same check and applied    *)
(* the same way; it deletes no note), the 48-hour expiry (a machine sweeps *)
(* expired events before each cycle and the home refuses an older sitting  *)
(* as expired, both single calls) and the pruning of intervals, the        *)
(* roll-up's purge guard, a computer restarting (its store survives; a    *)
(* sitting in flight is formed again), the home                           *)
(* restarting or giving up a sitting it was summarizing (no note is       *)
(* written; the computer holds the sitting and sends it again), and the   *)
(* home's record of what each computer applied (delivered_mark), which is *)
(* at most the computer's own mark, so a delivery from it sends the same  *)
(* pending intervals and some it already applied.                         *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/sittings.ex#run,step,dispatch,send_sitting,sitting,settle,settled @ 6b43d6f6534b
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/submission.ex#accept,checked,identity,mark,unnoted,unrefused,refused_by,make,write @ bbeaf8434c2d
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history.ex#home_identity @ 2eedfe384754
\* SOURCE: apps/fermix_core/lib/fermix_core/home/archive.ex#install,write_home,settle_home,history_identity,renew_token,renewed,history! @ 797f91e393db
\* SOURCE: apps/fermix_channels/lib/fermix_channels/home/candidate.ex#stage_fun,continued @ 9b5ceaa10793
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/computer_history_sql.ex#renew_home_token @ 5665fd6cbf1b
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/computer_history_sql.ex#insert_note,insert_note_in_tx,noted,reaching_intervals,intervals_after,purge_notes,purge_notes_in_tx,scoped_notes,fence_window,fence_window_in_tx,insert_events,insert_unless_purged,stamped_in_purge?,link,set_home_mark @ b24f49d2e1e9
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/spool.ex#link,events_after,fence,apply_intervals,apply_interval,mark_applied,apply_at @ ec5d295f5f69
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/delivery.ex @ 5d4a6f817ffc
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/machine_service.ex @ 4f821b0e8da9
\* SOURCE: apps/fermix_core/lib/fermix_core/computer_history/purge.ex#purge,apply_here @ f5b3d0524839
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
    MaxRestores,        \* times the home's store starts its ids again in one behaviour
    \* Environment switches
    OwnerCanPurge,      \* the owner purges from chat
    ScopedPurges,       \* a purge may name one computer, not only every one
    ComputersGoAway,    \* a computer's link drops (asleep, offline)
    HomeCanRestore,     \* the home's store is restored from a backup (or rebuilt, or the
                        \* machines join another home): its interval ids start again
    \* Mechanism switches (TRUE is the real code)
    WriteRechecks,      \* insert_note checks the intervals in its transaction (computer_history_sql.ex insert_note_in_tx)
    ComputerFences,     \* an applied interval refuses an event recorded inside it later (insert_unless_purged)
    MarkBeforeEvents,   \* Sittings.step reads the mark before the events (sittings.ex step)
    PurgeDeletesNotes,  \* purge_notes deletes the notes that reach the window (purge_notes_in_tx)
    MarkSkipsApplied,   \* the sitting carries the mark, so an interval it applied is not asked again (reaching_intervals after_id)
    RefusalNamesAllPending, \* a refusal names every interval above the sitting's mark, not only those reaching it (submission.ex refused_by)
    MarkAfterFences,    \* apply_intervals fences every interval first and writes the mark last (spool.ex mark_applied)
    HereAppliesPending, \* the home's own machine applies every interval of its own above its mark (delivery.ex apply_here)
    MarkTiedToHome,     \* a mark is kept with the identity of the home store it counts, and counts only
                        \* under it (submission.ex mark/2, delivery.ex mark/2, set_home_mark/3)
    RestoreRenews       \* a restore gives the store it installs a new token, so a new identity
                        \* each time (archive.ex history_identity/4, renew_home_token/1); FALSE keeps
                        \* the backup's token, and the identity is the one the home had the first
                        \* time it was restored from that backup (the token and the backup's epoch
                        \* plus one: HS-4)

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
    nextId,
    ident,      \* the home stores' identities (ComputerHistory.home_identity/1), 1 the first:
                \* home, the home's now; mark, the one each computer's mark counts
                \* (computer_history_link.home); sit, the one its sitting in flight names;
                \* ans, the one its answer names; dlv, the one the apply under way names
    bk          \* the owner's backup of the home (Home.Archive): taken, and the intervals,
                \* next id and epoch it holds; restores, how often a home was restored from it

vars == <<recorded, raw, sent, fence, mark, applying, connected, away, stage, fmark, fstamps,
          answer, notes, purges, hereApply, nextId, ident, bk>>

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
\* A mark counts only under the home store it names (submission.ex mark/2,
\* delivery.ex mark/2); without MarkTiedToHome, the code before c6fe1c48,
\* every mark counts.
Eff(m, h) == IF MarkTiedToHome /\ h # ident.home THEN 0 ELSE m
MarkNow(c) == Eff(mark[c], ident.mark[c])
SitMark(c) == Eff(fmark[c], ident.sit[c])
Pending(c) == {p \in purges : p.id > MarkNow(c) /\ Covers(p, c)}
MaxId(R) == Max({p.id : p \in R})
Raised(c, R) == IF MaxId(R) > mark[c] THEN MaxId(R) ELSE mark[c]
\* set_home_mark/3 for R applied under store h: raised under the same store,
\* replaced under another (without MarkTiedToHome, always raised).
SetMark(c, h, R) == IF MarkTiedToHome /\ ident.mark[c] # h THEN MaxId(R) ELSE Raised(c, R)
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
    /\ bk \in [taken : BOOLEAN, purges : SUBSET Interval, next : 1..(MaxPurges + 1),
               epoch : 1..(MaxRestores + 1), restores : 0..MaxRestores]
    /\ ident \in [home : 1..(MaxRestores + 1), mark : [Computers -> 1..(MaxRestores + 1)],
                  sit : [Computers -> 1..(MaxRestores + 1)], ans : [Computers -> 1..(MaxRestores + 1)],
                  dlv : [Computers -> 1..(MaxRestores + 1)]]

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
    \* A machine that applied nothing names no store (0 in the code, home NULL);
    \* its mark 0 counts the same under any, so it starts named for the first.
    /\ bk = [taken |-> FALSE, purges |-> {}, next |-> 1, epoch |-> 1, restores |-> 0]
    /\ ident = [home |-> 1, mark |-> [c \in Computers |-> 1], sit |-> [c \in Computers |-> 1],
               ans |-> [c \in Computers |-> 1], dlv |-> [c \in Computers |-> 1]]

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
                   notes, purges, hereApply, nextId, ident, bk>>

TheMark(c) == IF MarkSkipsApplied THEN mark[c] ELSE 0
Unsent(c) == raw[c] \ sent[c]

\* Sittings.step: two store calls, Spool.link/1 then Spool.events_after/3, in
\* that order (MarkBeforeEvents) or the other.
ReadFirst(c) ==
    /\ stage[c] = "none"
    /\ Unsent(c) /= {}
    /\ stage' = [stage EXCEPT ![c] = "half"]
    /\ IF MarkBeforeEvents
          THEN /\ fmark' = [fmark EXCEPT ![c] = TheMark(c)]
               /\ ident' = [ident EXCEPT !.sit[c] = ident.mark[c]]
               /\ UNCHANGED fstamps
          ELSE fstamps' = [fstamps EXCEPT ![c] = Unsent(c)] /\ UNCHANGED <<fmark, ident>>
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, answer, notes,
                   purges, hereApply, nextId, bk>>

ReadSecond(c) ==
    /\ stage[c] = "half"
    /\ IF MarkBeforeEvents
          THEN /\ fstamps' = [fstamps EXCEPT ![c] = Unsent(c)]
               /\ stage' = [stage EXCEPT ![c] = IF Unsent(c) = {} THEN "none" ELSE "out"]
               /\ UNCHANGED <<fmark, ident>>
          ELSE /\ fmark' = [fmark EXCEPT ![c] = TheMark(c)]
               /\ ident' = [ident EXCEPT !.sit[c] = ident.mark[c]]
               /\ stage' = [stage EXCEPT ![c] = "out"]
               /\ UNCHANGED fstamps
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, answer, notes,
                   purges, hereApply, nextId, bk>>

\* The answer reaches the computer (HistoryUplink.submit -> Sittings.settle):
\* summarized moves the cursor past the sitting; a refusal's intervals are
\* applied (Spool.apply_intervals/4) under the home store the answer names
\* (SetMark), the ones it already applied again, and the sitting is formed
\* again. Its fences and its mark are separate calls of
\* the cycle's own process, folded here: the reads that could fall between
\* them are this same cycle's, and a Record between them meets the fence
\* already written.
Settle(c) ==
    /\ stage[c] = "answered"
    /\ connected[c]
    /\ IF answer[c] = {}
          THEN /\ sent' = [sent EXCEPT ![c] = @ \cup fstamps[c]]
               /\ UNCHANGED <<raw, fence, mark, ident>>
          ELSE /\ raw' = [raw EXCEPT ![c] = Without(c, answer[c])]
               /\ fence' = [fence EXCEPT ![c] = @ \cup answer[c]]
               /\ mark' = [mark EXCEPT ![c] = SetMark(c, ident.ans[c], answer[c])]
               /\ ident' = [ident EXCEPT !.mark[c] = ident.ans[c]]
               /\ UNCHANGED sent
    /\ stage' = [stage EXCEPT ![c] = "none"]
    /\ UNCHANGED <<recorded, applying, connected, away, fmark, fstamps, answer, notes, purges,
                   hereApply, nextId, bk>>

\* No answer: the request or its answer was lost with the link. The sitting is
\* held and formed again later (`{:held, "unanswered"}`).
Lose(c) ==
    /\ stage[c] \in {"out", "answered"}
    /\ ~connected[c]
    /\ stage' = [stage EXCEPT ![c] = "none"]
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, fmark, fstamps,
                   answer, notes, purges, hereApply, nextId, ident, bk>>

\* The home's own machine never goes away from its home.
GoAway(c) ==
    /\ ComputersGoAway
    /\ ~IsHere(c)
    /\ connected[c]
    /\ away < MaxAway
    /\ connected' = [connected EXCEPT ![c] = FALSE]
    /\ away' = away + 1
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, stage, fmark, fstamps, answer,
                   notes, purges, hereApply, nextId, ident, bk>>

Return(c) ==
    /\ ~connected[c]
    /\ connected' = [connected EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, away, stage, fmark, fstamps,
                   answer, notes, purges, hereApply, nextId, ident, bk>>

-----------------------------------------------------------------------------
(* THE HOME *)

\* Submission.accept/3 takes the sitting: answered from its note when already
\* noted (unnoted/3), refused when an interval above its mark reaches it
\* (unrefused/3), naming what refused_by/4 reads, otherwise summarized next.
\* Three Repo calls folded into one step: a purge between them only adds an
\* interval to what the refusal names, which is still every one above the
\* mark, oldest first. Before them, accept/3 reads the home store's identity
\* (identity/1) and puts the sitting's mark in its place: kept when the
\* sitting names this store, 0 otherwise (mark/2, SitMark); the answer names
\* the store (ans).
Arrive(c) ==
    /\ stage[c] = "out"
    /\ connected[c]
    /\ LET noted == [c |-> c, stamps |-> fstamps[c]] \in notes
           refusing == Refusing(c, SitMark(c), fstamps[c])
       IN \/ /\ noted
             /\ answer' = [answer EXCEPT ![c] = {}]
             /\ stage' = [stage EXCEPT ![c] = "answered"]
             /\ UNCHANGED ident
          \/ /\ ~noted
             /\ refusing /= {}
             /\ answer' = [answer EXCEPT ![c] = Named(c, SitMark(c), fstamps[c])]
             /\ ident' = [ident EXCEPT !.ans[c] = ident.home]
             /\ stage' = [stage EXCEPT ![c] = "answered"]
          \/ /\ ~noted
             /\ refusing = {}
             /\ stage' = [stage EXCEPT ![c] = "summarizing"]
             /\ UNCHANGED <<answer, ident>>
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, fmark, fstamps,
                   notes, purges, hereApply, nextId, bk>>

\* The summary is made (a provider call), then insert_note/6 writes it in one
\* transaction that checks the intervals again (WriteRechecks). A refused
\* write's answer names what refused_by/4 reads after it, folded in as above.
Write(c) ==
    /\ stage[c] = "summarizing"
    /\ LET refusing == Refusing(c, SitMark(c), fstamps[c])
       IN IF WriteRechecks /\ refusing /= {}
             THEN /\ answer' = [answer EXCEPT ![c] = Named(c, SitMark(c), fstamps[c])]
                  /\ ident' = [ident EXCEPT !.ans[c] = ident.home]
                  /\ UNCHANGED notes
             ELSE /\ notes' = notes \cup {[c |-> c, stamps |-> fstamps[c]]}
                  /\ answer' = [answer EXCEPT ![c] = {}]
                  /\ UNCHANGED ident
    /\ stage' = [stage EXCEPT ![c] = "answered"]
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, fmark, fstamps,
                   purges, hereApply, nextId, bk>>

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
                   fstamps, answer, ident, bk>>

\* The first half of applying R on the home's own machine, as DeliverFirst
\* does on a computer: the fences (or, with MarkAfterFences off, the mark), the
\* other half to follow in DeliverSecond(HomeMachine).
ApplyHereOf(R) ==
    /\ applying' = [applying EXCEPT ![HomeMachine] = R]
    /\ IF MarkAfterFences
          THEN /\ raw' = [raw EXCEPT ![HomeMachine] = Without(HomeMachine, R)]
               /\ fence' = [fence EXCEPT ![HomeMachine] = @ \cup R]
               /\ ident' = [ident EXCEPT !.dlv[HomeMachine] = ident.home]
               /\ UNCHANGED mark
          ELSE /\ mark' = [mark EXCEPT ![HomeMachine] = SetMark(HomeMachine, ident.home, R)]
               /\ ident' = [ident EXCEPT !.dlv[HomeMachine] = ident.home,
                                          !.mark[HomeMachine] = ident.home]
               /\ UNCHANGED <<raw, fence>>

\* The home's own machine applies what it owes (Delivery.apply_here/1): run by
\* each purge command (Purge.purge/2) and pause command (History.apply_here/2)
\* once the home recorded its interval, and by the home scheduler's tick
\* (Scheduler.apply_here/1), which is how one whose apply failed is applied.
\* It reads the home store's identity and the mark (Spool.link/1, counted as
\* 0 under another store: mark/2), then every interval of this machine above
\* it (intervals_after/4), and applies them (Spool.apply_intervals/4): every
\* fence first, here, and the mark last, in DeliverSecond, which this machine
\* shares with a computer's delivery. The two reads are folded: the mark only
\* rises and an interval is read once committed, so a step between them only
\* applies more. Two commands may run at once, and one that fails after the
\* home recorded its interval applies nothing, which up to the point it
\* matters is the same as applying it later. One apply here runs at a time
\* here (applying is empty); in the code two may overlap (two commands, or a
\* command and the tick), which is safe in any order of their calls: each
\* fences every interval above the mark it read before it raises the mark
\* to the highest of them, and set_home_mark/3 never lowers it under the
\* same store.
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
                   nextId, bk>>


\* Delivery.deliver/1 to a connected computer (never the home's own machine):
\* MachineService.run/4 -> Spool.apply_at/4 applies every interval it has not,
\* in a process of its own beside the computer's sending cycle; the request
\* names the home store (dlv). Its two halves: every interval's
\* fence_window/4 (raw events inside go, the fence holds it), and then the
\* mark (set_home_mark/3, SetMark). With MarkAfterFences off, the mark comes
\* first. After a restore the home sends from the delivered mark its backup
\* held, which may sit above what a computer applied under the restored
\* store; it then sends fewer than Pending, and the refusal names the rest.
DeliverFirst(c) ==
    /\ ~IsHere(c)
    /\ connected[c]
    /\ applying[c] = {}
    /\ Pending(c) /= {}
    /\ applying' = [applying EXCEPT ![c] = Pending(c)]
    /\ IF MarkAfterFences
          THEN /\ raw' = [raw EXCEPT ![c] = Without(c, Pending(c))]
               /\ fence' = [fence EXCEPT ![c] = @ \cup Pending(c)]
               /\ ident' = [ident EXCEPT !.dlv[c] = ident.home]
               /\ UNCHANGED mark
          ELSE /\ mark' = [mark EXCEPT ![c] = SetMark(c, ident.home, Pending(c))]
               /\ ident' = [ident EXCEPT !.dlv[c] = ident.home, !.mark[c] = ident.home]
               /\ UNCHANGED <<raw, fence>>
    /\ UNCHANGED <<recorded, sent, connected, away, stage, fmark, fstamps, answer, notes, purges,
                   hereApply, nextId, bk>>

DeliverSecond(c) ==
    /\ applying[c] /= {}
    /\ applying' = [applying EXCEPT ![c] = {}]
    /\ IF MarkAfterFences
          THEN /\ mark' = [mark EXCEPT ![c] = SetMark(c, ident.dlv[c], applying[c])]
               /\ ident' = [ident EXCEPT !.mark[c] = ident.dlv[c]]
               /\ UNCHANGED <<raw, fence>>
          ELSE /\ raw' = [raw EXCEPT ![c] = Without(c, applying[c])]
               /\ fence' = [fence EXCEPT ![c] = @ \cup applying[c]]
               /\ UNCHANGED <<mark, ident>>
    /\ UNCHANGED <<recorded, sent, connected, away, stage, fmark, fstamps, answer, notes, purges,
                   hereApply, nextId, bk>>

\* The owner backs the home up (Home.Archive): its memory.db, with its
\* intervals and the next id, and the home's epoch then (the manifest's
\* primary_epoch). Once in a behaviour, at any moment.
TakeBackup ==
    /\ HomeCanRestore
    /\ ~bk.taken
    /\ bk' = [bk EXCEPT !.taken = TRUE, !.purges = purges, !.next = nextId, !.epoch = ident.home]
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, stage, fmark,
                   fstamps, answer, notes, purges, hereApply, nextId, ident>>

\* The home is restored from that backup (Archive.install/5): its store starts
\* its interval ids again from the backup's, and the install gives it a new
\* token (RestoreRenews), so its identity (home_identity/1, the token) is one
\* no machine has counted under, the second restore from one backup as much
\* as the first. Without it the store keeps the backup's token, and the
\* identity is the one the home had the first time it was restored from that
\* backup (HS-4). A server rebuilt from nothing or another home is the same
\* with a token never seen. Its notes
\* are none of these (fewer notes only answer fewer sittings from a note).
\* The machines' own stores are not in the backup and keep their marks. The
\* engine restarts, so no sitting is being summarized then; one on its way,
\* or an answer or an apply on its way back, goes on and names the store it
\* was made under.
Restore ==
    /\ bk.taken
    /\ bk.restores < MaxRestores
    /\ \A c \in Computers : stage[c] /= "summarizing"
    /\ purges' = bk.purges
    /\ hereApply' = hereApply \cap bk.purges
    /\ nextId' = bk.next
    /\ notes' = {}
    /\ ident' = [ident EXCEPT !.home = IF RestoreRenews THEN bk.restores + 2 ELSE bk.epoch + 1]
    /\ bk' = [bk EXCEPT !.restores = @ + 1]
    /\ UNCHANGED <<recorded, raw, sent, fence, mark, applying, connected, away, stage, fmark,
                   fstamps, answer>>

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
    \/ TakeBackup \/ Restore
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
