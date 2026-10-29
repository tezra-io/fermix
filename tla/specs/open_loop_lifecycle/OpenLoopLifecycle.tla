------------------------- MODULE OpenLoopLifecycle -------------------------
(***************************************************************************)
(* ONE open loop (MILESTONE_78, MILESTONE_83) from capture to its end: the *)
(* due scan (Repo.scan_due_open_loops, Lifecycle.due_decision) in the      *)
(* scheduler, the rung 1 raise a main-agent turn records, the rung 2 claim,*)
(* the check-in run (decide, re-read, spend the day's budget, send, history*)
(* row, finalize) with the owner's answer racing it, the daily budget, a   *)
(* daemon crash and the boot sweep of claims, and expiry.                  *)
(*                                                                         *)
(* Two timings (`cls`): a dated loop, something to do by a date (class     *)
(* medium or long), and an `after` loop, something waited on or gone       *)
(* through, asked about from its anchor (`ask_after`). Two reaches         *)
(* (`reach`): message, raised in conversation or by one check-in message,  *)
(* and conversation, raised only inside a conversation the owner starts:   *)
(* no rung 2, no hand-back, and a rung 1 window that runs slot to slot.    *)
(* The owner can change the reach and move a dated loop's date.            *)
(*                                                                         *)
(* Time is abstract. The day has three phases (before, inside and after    *)
(* the owner's active hours); `daysLeft` counts the midnights until a dated*)
(* loop's date has passed (an after loop has none). A pending touch has    *)
(* "arrived" or not, and `hold` says it is on a later local day. The rung 1*)
(* window is one boolean on a due row (rung1_until > now), and `untilSet`  *)
(* is the column itself (rung1_until IS NOT NULL).                         *)
(*                                                                         *)
(* Dated slots: 0 and 1 are before the date, 2 is the hand-back (the day   *)
(* after the date; for a conversation loop the rest after its last slot,   *)
(* which expires on arrival), 3 is the answer day after the hand-back,     *)
(* whose end expires the loop. A plan stands in for the pending slot       *)
(* (`planned`). An after loop's phase is read off its touches and state,   *)
(* as Lifecycle.phase/1 reads it; `slot` stays 0.                          *)
(*                                                                         *)
(* Not modelled: several loops (the budget is the owner's across loops;    *)
(* OL-2 in the README walks the two-loop path), classes short and imminent *)
(* (a moved date re-derives the class; the spec keeps the medium and long  *)
(* table), message wording, the active-hours derivation, a provider failure*)
(* inside the run (the same failed-outcome path as a failed send), the due *)
(* note's text, the follow-up record (open_loop_reactions, its own table), *)
(* the 20-loop cap, a re-note (kind_conflict and existing are single-call  *)
(* rules), and a telemetry or history write that errors. Only SQLite rows  *)
(* survive a crash.                                                        *)
(*                                                                         *)
(* One step = one indivisible thing: one GenServer callback, one           *)
(* Memory.Repo call (every SQLite access goes through that one process), or*)
(* one side effect at the platform. Every path:line below names the M83    *)
(* working tree it was written against, re-read at the next re-pin.       *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/open_loops/lifecycle.ex @ a0092c2cef0b
\* SOURCE: apps/fermix_core/lib/fermix_core/open_loops/defaults.ex @ dce4830c823c
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/open_loops_sql.ex @ c2a45ffb8a8e
\* SOURCE: apps/fermix_core/lib/fermix_core/open_loops/scheduler.ex @ ca94a8aacbbf
\* SOURCE: apps/fermix_core/lib/fermix_core/open_loops/check_in.ex @ 5c51dae8e631
\* SOURCE: apps/fermix_core/lib/fermix_core/open_loops/registry.ex#update,answer_args,plan_at,plan_day,optional_ask_after,resolve_ask_after,after_instant
EXTENDS Naturals, FiniteSets

CONSTANTS
    Runs,           \* CheckInSupervisor's child slots, e.g. {r1, r2} (max_children 2)
    MaxFaults,      \* how many daemon crashes one behaviour may contain
    DaysToDate,     \* midnights from capture until a dated loop's date has passed
    LapseDays,      \* midnights an after loop's touch stays raisable before it lapses
                    \* (Defaults.conversation_window_ms, 14 days)
    Classes,        \* the timings a behaviour may start with: {"dated", "after"}
    Reaches,        \* the reaches a loop may be recorded with: {"message", "conversation"}
    \* Environment switches: what may happen around the loop.
    OwnerCanAnswer,      \* the owner answers: done, stop, drop, a plan, not yet, a moved date
    OwnerAnswersDuringRun, \* the owner's answer lands while a check-in run is alive
    PlanCanBeToday,      \* a time the owner names (a plan, an after loop's new
                         \* ask_after, at least 3 h on) is later the same local day
    OwnerChangesReach,   \* the owner says how they want the loop raised from now on
    RaiseInConversation, \* an owner-private turn arrives while the rung 1 window is
                         \* open, and the main agent raises the loop and records it
    RaiseUnprompted,     \* the main agent records a raise on a loop the due note did
                         \* not name (open_loop_update asked on an open row)
    SendCanFail,         \* the platform refuses the send: nothing is shown
    AnswerCanBeLost,     \* the platform shows the message, and the run sees a failure
    DaemonCanCrash,      \* the whole daemon dies and boots again
    \* Mechanism switches: what the code does about it. TRUE is the code;
    \* each is switched off by at least one check.
    SingleClaimant,      \* one run per loop: the claim takes only a due, unclaimed
                         \* row (claim/3's WHERE state = 'due' AND claimed_at IS
                         \* NULL, open_loops_sql.ex:876-889), and the scheduler
                         \* claims no loop whose owner has a run in flight
                         \* (Scheduler.weigh/2, scheduler.ex:261-267); redundant
                         \* layers, one switch for both
    FinalizeIsCAS,       \* the run's finalising write is a compare-and-set on
                         \* (id, state = 'due', claimed_at) (finalize/5, :792-804)
    ChecksBeforeSend,    \* the run re-reads the row at its outcome step and reports
                         \* closed_meanwhile when its claim no longer stands
                         \* (CheckIn.still_claimed/1), and the budget spend is a
                         \* compare-and-set on the same claim (spend_budget/5,
                         \* open_loops_sql.ex:818-834); redundant layers, one switch
    WhereLiveGuard,      \* every settle carries WHERE state IN ('open','due','asked')
                         \* (settle/4, :769-779), so a terminal row is unreachable
    SettleClearsClaim,   \* every settle and finalize sets claimed_at = NULL
                         \* (write_settle/5, :859-873), backed by the CHECK
                         \* claimed_at IS NULL OR state = 'due' (:333)
    BudgetRead,          \* a claim needs the owner's day unspent:
                         \* budget_spent_since/3 (:1160-1173) read by
                         \* Scheduler.budget_for/2 (scheduler.ex:310-325) into
                         \* Lifecycle.rung2_eligible?/4 (lifecycle.ex:281-291)
    SpendBeforeSend,     \* the run spends the owner's day before its one send:
                         \* CheckIn.spend_then_deliver/3 -> Repo.spend_open_loop_budget/5
                         \* (spend_budget/5, open_loops_sql.ex:818-834) stamps
                         \* last_rung2_at, the column the budget reads, which no
                         \* touch writes; off, the budget is the loop's last
                         \* recorded touch, as it was before the fix (OL-1, OL-2)
    TouchCap,            \* a dated table ends at the hand-back, whose touch arms
                         \* the answer day (after_touch/4 :305-316,
                         \* following_touch/4 :318-324, Defaults.slots/1), the spent
                         \* phase counts touches against the table (phase/1
                         \* :736-743), asked is refused at three (asked/3 :512-516),
                         \* and the CHECK touches BETWEEN 0 AND 3; one switch for all
    AfterCap,            \* an after loop is spent once its two touches are used
                         \* (phase/1 :732-734, Defaults.after_max_touches), so a
                         \* raise is refused, its arrival expires it, and a plan or
                         \* a not yet is refused :touches_spent (touch_left/1
                         \* :457-460)
    AskedNeedsDue,       \* a raise is recorded only on a due row; on any other it is
                         \* refused :not_due (asked/3, lifecycle.ex:510-518)
    NextTouchLaterDay,   \* the touch after a touch is the first slot on a later
                         \* local day (following_touch/4 -> next_later_day_slot/5,
                         \* lifecycle.ex:318-345),
                         \* so a conversation loop raised on its next slot's day,
                         \* before that slot's time, is not armed again that day
                         \* (OL-3)
    SlotGate,            \* a row becomes due only once its pending touch has
                         \* arrived: scan_candidates' next_touch_at <= now
                         \* (open_loops_sql.ex:938-952) and due_decision/2's
                         \* :not_yet for a future next_touch_at (lifecycle.ex:175)
    ConversationGate,    \* a loop kept for conversation never gets a check-in
                         \* (rung2_eligible?/4 :285) and has no hand-back
                         \* (Defaults.slots/2, defaults.ex:236-238; arrived/3
                         \* :189, :196 expire where the hand-back would be), and its
                         \* rung 1 window runs slot to slot (rung1_until/2 :225-231,
                         \* conversation_close/1 :235-243); off, it is treated as a
                         \* loop raised by message
    WindowCleared,       \* every write that moves a row out of due clears
                         \* rung1_until: normalize_changes/1's window_cleared/1
                         \* (open_loops_sql.ex:573-576) and the scan's own
                         \* rung1_until = NULL (apply_decision/4 :997-1023), backed by
                         \* the CHECK (state = 'due') = (rung1_until IS NOT NULL) (:338)
    WindowLapses,        \* a conversation loop's window that closes unraised takes
                         \* the quiet path to the next slot's window
                         \* (become_due/2 :202-206, window_lapsed?/2 :211-214,
                         \* next_window/1 :218-223; apply_decision {:lapse, ...}
                         \* open_loops_sql.ex:984-995)
    BootSweep,           \* the scheduler's boot clears every claimed_at
                         \* (Scheduler.boot_sweep/1, scheduler.ex:189-204;
                         \* sweep_claims/1, open_loops_sql.ex:892-911)
    ScanExpires          \* the due scan expires a loop never asked once its date
                         \* passes, a hand-back a day after its slot, a conversation
                         \* loop at its rest, an after touch at its lapse, and a
                         \* spent row when its answer day ends (arrived/3 :180-200)

VARIABLES
    state,        \* SQLite row: open | due | asked | closed | expired
    touches,      \* SQLite row: touches
    slot,         \* SQLite row (derived): which slot next_touch_at stands for (dated)
    planned,      \* SQLite row: next_touch_at is a plan's time, not a slot's (dated)
    arrived,      \* SQLite row + clock: next_touch_at <= now
    hold,         \* SQLite row + clock: next_touch_at is on a later local day
    windowOpen,   \* SQLite row + clock: a due row's rung1_until > now
    untilSet,     \* SQLite row: rung1_until IS NOT NULL
    dueDays,      \* SQLite row + clock: midnights a due row has waited (dated: 0..1)
    retried,      \* SQLite row: the pending touch's one retry is spent (a hand-back's,
                  \* handback_failed_before?/1; an after touch's, failed_this_touch?/1)
    lastRung,     \* SQLite row: last_touch_rung (0 = none)
    touchedToday, \* SQLite row + clock: last_touch_at is since the local day began
    rung2Today,   \* SQLite row + clock: last_rung2_at (the spend) is since the
                  \* local day began
    cls,          \* SQLite row: horizon_class after, or a dated class (fixed)
    reach,        \* SQLite row: reach
    holder,       \* SQLite row: claimed_at, as the run that holds it ({} = none)
    daysLeft,     \* clock: midnights until a dated loop's date has passed
    dayPhase,     \* clock: before | in | after the owner's active hours
    run,          \* CheckIn process, per slot
    lost,         \* observer, per run: its claim was released before its outcome step
    sched,        \* the daemon: up | down
    faults,       \* crashes still allowed
    sentToday,    \* observer: rung 2 messages the owner received today (saturates)
    shownThisTouch, \* observer: messages the owner received for the pending touch
    wasTerminal,  \* observer: the row has been closed or expired
    unclaimedSend,  \* observer: a run sent after its claim was released
    shownWhileClosed, \* observer: a message reached the owner after the loop ended
    earlyTouch,   \* observer: a touch recorded, or a send committed, before the
                  \* pending touch arrived
    convMessage,  \* observer: a check-in claimed or spent, or a touch recorded at
                  \* the hand-back, while the reach was conversation
    stranded,     \* observer: a due conversation loop spent a local midnight with
                  \* its window closed while its touch was still live
    twiceToday    \* observer: a second touch recorded on one local day

vars == <<state, touches, slot, planned, arrived, hold, windowOpen, untilSet, dueDays,
          retried, lastRung, touchedToday, rung2Today, cls, reach, holder, daysLeft,
          dayPhase, run, lost, sched, faults, sentToday, shownThisTouch, wasTerminal,
          unclaimedSend, shownWhileClosed, earlyTouch, convMessage, stranded, twiceToday>>

rowVars == <<state, touches, slot, planned, arrived, hold, windowOpen, untilSet, dueDays,
             retried, lastRung, touchedToday, rung2Today, cls, reach>>
clockVars == <<daysLeft, dayPhase>>
obsVars == <<sentToday, shownThisTouch, wasTerminal, unclaimedSend, shownWhileClosed,
             earlyTouch, convMessage, stranded, twiceToday>>
\* The observers only a send or a touch moves.
touchObs == <<earlyTouch, convMessage, stranded, twiceToday>>

States == {"open", "due", "asked", "closed", "expired"}
Live == {"open", "due", "asked"}
Terminal == {"closed", "expired"}
RunStates == {"none", "claimed", "speak", "checked", "spent", "confirmed", "historied",
              "silent", "later", "close", "failed"}
\* A run that has not yet re-read its claim at the outcome step.
PreCheck == {"claimed", "speak"}

Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b

Dated == cls = "dated"
After == cls = "after"
\* The reach as the code applies it: with ConversationGate off, a loop kept for
\* conversation is treated as one raised by message.
Conv == reach = "conversation" /\ ConversationGate
\* Defaults.handback?/2: a dated table ends in a hand-back unless the loop is
\* kept for conversation; an after table never does.
HasHandBack == Dated /\ ~Conv
\* length(Defaults.slots(class, reach)) for medium and long.
NumSlots == IF Conv THEN 2 ELSE 3

datePassed == daysLeft = 0
\* The pending touch is a before-the-date one: slot 0 or 1, or a plan (never later
\* than the date, Lifecycle.plan_bound/3, lifecycle.ex:481-485).
BeforeDate == slot <= 1 \/ planned
\* The day's budget as the claim reads it. With the spend, last_rung2_at is
\* since the local day began (budget_spent_since/3 reads MAX(last_rung2_at) >=
\* the day's start over every row of the owner). Without it, the loop's last
\* touch was a rung 2 touch today: the columns the budget read before the fix
\* (last_touch_rung = 2 AND last_touch_at >= the day's start).
BudgetSpent ==
    /\ BudgetRead
    /\ IF SpendBeforeSend THEN rung2Today ELSE lastRung = 2 /\ touchedToday
\* Lifecycle.phase/1 (lifecycle.ex:736-743) :spent for a dated loop: the table's
\* touches are used, or the hand-back was touched (its answer day is pending).
\* Checked before the pending slot's phase, so a plan never revives a spent loop.
Spent == (TouchCap /\ touches >= NumSlots) \/ slot = 3
\* phase/1 :732-734 for an after loop: both touches used, or waiting for the
\* owner's answer to the last one.
AfterSpent == (AfterCap /\ touches >= 2) \/ state = "asked"
\* asked/3 (lifecycle.ex:510-518): refused on a row not due, once the phase is
\* spent, or at three.
RaiseRefused == (TouchCap /\ touches >= 3) \/ (Dated /\ Spent) \/ (After /\ AfterSpent)
\* The settle's WHERE guard.
Writable == state \in Live \/ ~WhereLiveGuard
\* claimed_at after a settle.
Cleared == IF SettleClearsClaim THEN {} ELSE holder
\* A run before its outcome step whose claim the write releases or replaces.
LoseClaim(newHolder) ==
    [x \in Runs |-> lost[x] \/ (run[x] \in PreCheck /\ x \in holder /\ x \notin newHolder)]
\* rung1_until after a write that leaves due.
UntilLeft == untilSet /\ ~WindowCleared
\* A time the owner names may be later today.
OwnerTime == IF PlanCanBeToday THEN BOOLEAN ELSE {TRUE}
\* A touch at the hand-back: a dated touch after the date.
HandBackTouch == Dated /\ ~BeforeDate

-----------------------------------------------------------------------------
(* Row rules shared by several steps *)

\* The slot a touch arms next, Lifecycle.following_touch/4 (lifecycle.ex:318-324)
\* through next_later_day_slot/5 (:332-345): the first slot from index
\* touches + 1 on a later local day. A touch at a pending slot moves past it; a touch at a plan may
\* re-arm the slot the plan stood before, when that slot is still ahead; a touch
\* before the date at the hand-back's slot arms the hand-back, or none at three;
\* a touch after the date arms the answer day. An after loop arms the answer
\* day. The `slot + 1` at slot 2 without TouchCap is the hand-back re-arming
\* itself, not code.
NextSlots ==
    IF After THEN {0}
    ELSE IF slot = 2 /\ planned THEN {IF touches <= 1 THEN 2 ELSE 3}
    ELSE IF slot = 2 THEN {IF TouchCap THEN 3 ELSE 2}
    ELSE IF slot >= 3 THEN {3}
    ELSE IF planned /\ slot > touches THEN {slot, slot + 1}
    ELSE {slot + 1}

\* Lifecycle.after_touch/4: a recorded raise or a confirmed rung 2 send. One
\* more touch, asked, the following slot armed on a later local day
\* (next_later_day_slot/5). Without NextTouchLaterDay, a conversation loop raised
\* on the day of its next slot, before that slot's time (its window runs to that
\* slot, conversation_close/1), arms that slot later the same day (OL-3). The
\* guard touches < 4 is the spec's bound on a run without TouchCap, not code.
LedgerTouch(rung) ==
    /\ touches < 4
    /\ touches' = touches + 1
    /\ state' = "asked"
    /\ slot' \in NextSlots
    /\ planned' = FALSE
    /\ arrived' = FALSE
    /\ hold' \in (IF ~NextTouchLaterDay /\ Conv /\ Dated /\ slot = 0 /\ slot' = 1
                     /\ dueDays >= 1
                  THEN BOOLEAN ELSE {TRUE})
    /\ windowOpen' = FALSE
    /\ untilSet' = UntilLeft
    /\ retried' = FALSE
    /\ lastRung' = rung
    /\ touchedToday' = TRUE
    /\ earlyTouch' = (earlyTouch \/ ~arrived)
    /\ convMessage' = (convMessage \/ (reach = "conversation" /\ (rung = 2 \/ HandBackTouch)))
    /\ twiceToday' = (twiceToday \/ touchedToday)
    /\ UNCHANGED <<dueDays, rung2Today, cls, reach, stranded>>

\* A closing write: closed_at, close_reason, next_touch_at NULL, rung1_until NULL.
EndAs(s) ==
    /\ state' = s
    /\ windowOpen' = FALSE
    /\ untilSet' = UntilLeft
    /\ wasTerminal' = TRUE
    /\ UNCHANGED <<touches, slot, planned, arrived, hold, dueDays, retried, lastRung,
                   touchedToday, rung2Today, cls, reach>>

\* Lifecycle.due_decision/2 (lifecycle.ex:186-192): {:skip_to_handback, at};
\* apply_decision/4 (open_loops_sql.ex:997-1006) writes a due row back to open.
SkipToHandBack ==
    /\ slot' = 2
    /\ planned' = FALSE
    /\ arrived' = FALSE
    /\ state' = IF state = "due" THEN "open" ELSE state
    /\ windowOpen' = FALSE
    /\ untilSet' = UntilLeft
    /\ UNCHANGED <<touches, hold, dueDays, retried, lastRung, touchedToday, rung2Today,
                   cls, reach, wasTerminal>>

\* An expiry the scan decides; without ScanExpires the row is left as it is.
ScanExpire ==
    \/ ScanExpires /\ EndAs("expired")
    \/ ~ScanExpires /\ UNCHANGED <<rowVars, wasTerminal>>

\* {:due, rung1_until} (become_due/2 :206, rung1_until/2 :225-231): three hours
\* on for a loop raised by message, the next slot or the date for a dated
\* conversation loop, the touch plus 14 days for an after conversation loop.
BecomeDue ==
    /\ state' = "due"
    /\ windowOpen' = TRUE
    /\ untilSet' = TRUE
    /\ dueDays' = 0
    /\ UNCHANGED <<touches, slot, planned, arrived, hold, retried, lastRung,
                   touchedToday, rung2Today, cls, reach, wasTerminal>>

-----------------------------------------------------------------------------
(* The scheduler (OpenLoops.Scheduler, one GenServer) *)

\* The due timer or the 60 s reconcile tick -> Scheduler.run_due/2
\* (scheduler.ex:213-223) -> Repo.scan_due_open_loops (scan_due/3,
\* open_loops_sql.ex:923-1033): one transaction per row, each decided by
\* Lifecycle.due_decision/2 (lifecycle.ex:171-200). A claimed row is left to its
\* check-in (:174).
ScanArrivedDated ==
    \/ Spent /\ ScanExpire
    \/ ~Spent /\ BeforeDate /\ datePassed /\ touches > 0 /\ HasHandBack /\ SkipToHandBack
    \/ ~Spent /\ BeforeDate /\ datePassed /\ (touches = 0 \/ ~HasHandBack) /\ ScanExpire
    \/ ~Spent /\ ~BeforeDate /\ ~HasHandBack /\ ScanExpire
    \/ ~Spent /\ BeforeDate /\ ~datePassed /\ BecomeDue
    \/ ~Spent /\ ~BeforeDate /\ HasHandBack /\ BecomeDue

\* arrived/3 :180-184: a spent after loop expires; an armed one becomes due.
ScanArrivedAfter ==
    \/ AfterSpent /\ ScanExpire
    \/ ~AfterSpent /\ BecomeDue

\* A due row is never made due again (become_due/2 :202-204). A dated one
\* lapses when its before-the-date slot's date passes, or a day after its
\* hand-back slot (grace_spent?/2, :265-268); a conversation one whose hand-back
\* slot is its rest expires there. An after one lapses LapseDays after its touch
\* (touch_lapsed?/2 :208-209; for a conversation loop its window closes then
\* too, next_window/1 :218).
ScanDueDated ==
    \/ Spent /\ ScanExpire
    \/ ~Spent /\ BeforeDate /\ datePassed /\ touches > 0 /\ HasHandBack /\ SkipToHandBack
    \/ ~Spent /\ BeforeDate /\ datePassed /\ (touches = 0 \/ ~HasHandBack) /\ ScanExpire
    \/ ~Spent /\ ~BeforeDate /\ ~HasHandBack /\ ScanExpire
    \/ ~Spent /\ ~BeforeDate /\ HasHandBack /\ dueDays = 1 /\ ScanExpire

ScanDueAfter == dueDays >= LapseDays /\ ScanExpire

\* One row's transaction in the due scan: an arrived open or asked row, or a due
\* row whose touch has lapsed. Unclaimed rows only.
Scan ==
    /\ sched = "up" /\ holder = {}
    /\ \/ /\ state \in {"open", "asked"}
          /\ arrived \/ ~SlotGate
          /\ IF After THEN ScanArrivedAfter ELSE ScanArrivedDated
       \/ /\ state = "due"
          /\ IF After THEN ScanDueAfter ELSE ScanDueDated
    /\ UNCHANGED <<holder, clockVars, run, lost, sched, faults, sentToday, shownThisTouch,
                   unclaimedSend, shownWhileClosed, touchObs>>

\* A due row the same pass's scan moves before any rung 2 claim is weighed:
\* Scheduler.run_due/2 weighs only scan.due ++ scan.waiting (scheduler.ex:217).
ScanMovesDue ==
    IF After THEN dueDays >= LapseDays /\ ScanExpires
    ELSE \/ Spent /\ ScanExpires
         \/ ~Spent /\ BeforeDate /\ datePassed /\ ((touches > 0 /\ HasHandBack) \/ ScanExpires)
         \/ ~Spent /\ ~BeforeDate /\ ~HasHandBack /\ ScanExpires
         \/ ~Spent /\ ~BeforeDate /\ HasHandBack /\ dueDays = 1 /\ ScanExpires

\* A dated conversation loop's window closes at its next slot, a later local day
\* than its pending touch (conversation_close/1 :235-243), and the scan's quiet
\* path opens that slot's window where the last one closed, the loop still due
\* and the ledger untouched: {:lapse, next_touch_at, rung1_until} (next_window/1
\* :220-223; apply_decision/4 open_loops_sql.ex:984-995). The window's close and
\* the scan are one step: the scheduler's timer fires at rung1_until
\* (Lifecycle.next_wake/2 :694-699). The window of the last slot before the date
\* closes at the date (NewDay), where the scan expires the loop. Without
\* WindowLapses the window only closes.
ConvLapse ==
    /\ sched = "up" /\ holder = {}
    /\ Dated /\ Conv /\ state = "due" /\ windowOpen
    /\ slot = 0 /\ dueDays >= 1 /\ ~datePassed
    /\ IF WindowLapses
       THEN /\ slot' = 1
            /\ planned' = FALSE
            /\ dueDays' = 0
            /\ UNCHANGED windowOpen
       ELSE /\ windowOpen' = FALSE
            /\ UNCHANGED <<slot, planned, dueDays>>
    /\ UNCHANGED <<state, touches, arrived, hold, untilSet, retried, lastRung, touchedToday,
                   rung2Today, cls, reach, holder, clockVars, run, lost, sched, faults,
                   obsVars>>

\* The same pass, Scheduler.weigh_due/3 (scheduler.ex:235-257): skip an owner
\* with a run in flight, read the hours and the budget,
\* Lifecycle.rung2_eligible?/4 (conversation, window closed, active hours,
\* budget; lifecycle.ex:281-291), then Repo.claim_open_loop_checkin/3
\* (open_loops_sql.ex:876-889) and a CheckInSupervisor child. CHOOSE takes one
\* free child slot, always the same one for the same state: slots are
\* interchangeable.
Claim ==
    /\ sched = "up"
    /\ \E x \in Runs : run[x] = "none"
    /\ state = "due" /\ ~windowOpen /\ dayPhase = "in" /\ ~BudgetSpent
    /\ ~Conv
    /\ ~ScanMovesDue
    /\ (holder = {} /\ \A x \in Runs : run[x] = "none") \/ ~SingleClaimant
    /\ LET r == CHOOSE x \in Runs : run[x] = "none" IN
         /\ holder' = {r}
         /\ run' = [run EXCEPT ![r] = "claimed"]
         /\ lost' = [x \in Runs |-> IF x = r THEN FALSE ELSE LoseClaim({r})[x]]
    /\ convMessage' = (convMessage \/ reach = "conversation")
    /\ UNCHANGED <<rowVars, clockVars, sched, faults, sentToday, shownThisTouch, wasTerminal,
                   unclaimedSend, shownWhileClosed, earlyTouch, stranded, twiceToday>>

\* The restarted daemon's scheduler init: Scheduler.boot_sweep/1
\* (scheduler.ex:189-204) -> Repo.sweep_open_loop_claims/1
\* (open_loops_sql.ex:892-911), since no run outlives the daemon.
Boot ==
    /\ sched = "down"
    /\ sched' = "up"
    /\ holder' = IF BootSweep THEN {} ELSE holder
    /\ UNCHANGED <<rowVars, clockVars, run, lost, faults, obsVars>>

-----------------------------------------------------------------------------
(* A check-in run (OpenLoops.CheckIn) in child slot r *)

\* The run's loop ends with one open_loop_respond decision: speak, silent,
\* later or close. The model's choice.
Decide(r) ==
    /\ run[r] = "claimed"
    /\ \E d \in {"speak", "silent", "later", "close"} : run' = [run EXCEPT ![r] = d]
    /\ UNCHANGED <<rowVars, holder, clockVars, lost, sched, faults, obsVars>>

\* CheckIn.speak/3 -> still_claimed/1: one Repo read of the row. A row no
\* longer due, or claimed by another, is closed_meanwhile: a traced skip,
\* nothing sent.
Check(r) ==
    /\ run[r] = "speak"
    /\ run' = [run EXCEPT ![r] =
                 IF ~ChecksBeforeSend \/ (state = "due" /\ r \in holder)
                 THEN "checked" ELSE "none"]
    /\ UNCHANGED <<rowVars, holder, clockVars, lost, sched, faults, obsVars>>

\* CheckIn.spend_then_deliver/3 -> Repo.spend_open_loop_budget/5 (spend_budget/5,
\* open_loops_sql.ex:818-834): the owner's day is spent before the send, a
\* compare-and-set on the claim the run holds that stamps last_rung2_at, refused
\* (budget_spent) in the same transaction when any row of the owner's already
\* carries today's stamp; with one loop that refusal is never reached. A claim
\* that no longer stands is closed_meanwhile: nothing spent, nothing sent. A
\* send that then fails, a crash, or an answer during the send leaves the day
\* spent. Without the spend the run goes from its re-read straight to the send.
Spend(r) ==
    /\ SpendBeforeSend
    /\ run[r] = "checked"
    /\ IF ~ChecksBeforeSend \/ (state = "due" /\ r \in holder)
       THEN /\ run' = [run EXCEPT ![r] = "spent"]
            /\ rung2Today' = TRUE
            /\ earlyTouch' = (earlyTouch \/ ~arrived)
            /\ convMessage' = (convMessage \/ reach = "conversation")
       ELSE /\ run' = [run EXCEPT ![r] = "none"]
            /\ UNCHANGED <<rung2Today, earlyTouch, convMessage>>
    /\ UNCHANGED <<state, touches, slot, planned, arrived, hold, windowOpen, untilSet,
                   dueDays, retried, lastRung, touchedToday, cls, reach, holder, clockVars,
                   lost, sched, faults, sentToday, shownThisTouch, wasTerminal,
                   unclaimedSend, shownWhileClosed, stranded, twiceToday>>

\* What the owner receives.
Shown(r) ==
    /\ sentToday' = IF sentToday >= 2 THEN 2 ELSE sentToday + 1
    /\ shownThisTouch' = IF shownThisTouch >= 2 THEN 2 ELSE shownThisTouch + 1
    /\ unclaimedSend' = (unclaimedSend \/ lost[r])
    /\ shownWhileClosed' = (shownWhileClosed \/ state \in Terminal)
    /\ UNCHANGED <<wasTerminal, touchObs>>

\* CheckIn.deliver/3 -> send_once/2: Delivery.ChannelSend, one attempt under
\* send_timeout_ms, proactive key open_loop:<id>:<touch>, to the snapshotted
\* target: confirmed, refused, or shown with the answer lost (a timeout after
\* the platform accepted). The send and its answer are one step.
Send(r) ==
    /\ run[r] = IF SpendBeforeSend THEN "spent" ELSE "checked"
    /\ \/ run' = [run EXCEPT ![r] = "confirmed"] /\ Shown(r)
       \/ SendCanFail /\ run' = [run EXCEPT ![r] = "failed"] /\ UNCHANGED obsVars
       \/ AnswerCanBeLost /\ run' = [run EXCEPT ![r] = "failed"] /\ Shown(r)
    /\ UNCHANGED <<rowVars, holder, clockVars, lost, sched, faults>>

\* CheckIn.record_spoken/3: ConversationStore.add_message/4, the assistant
\* chat_message marked open_loop_checkin, written before the ledger, so a crash
\* between them leaves a history row and no touch.
History(r) ==
    /\ run[r] = "confirmed"
    /\ run' = [run EXCEPT ![r] = "historied"]
    /\ UNCHANGED <<rowVars, holder, clockVars, lost, sched, faults, obsVars>>

\* The run's write lands only while its claim stands.
Holds(r) == (state = "due" /\ r \in holder) \/ ~FinalizeIsCAS

\* The rest of record_spoken/3, then CheckIn.finalize/2:
\* Repo.finalize_open_loop_checkin/5 with Lifecycle.after_touch/4 at rung 2. On
\* :closed_meanwhile the message is already out and the touch is not counted;
\* the day was spent before the send. The follow-up record that follows a
\* written finalise (Reactions.record_sent/4) is another table.
Finalize(r) ==
    /\ run[r] = "historied"
    /\ run' = [run EXCEPT ![r] = "none"]
    /\ IF Holds(r)
       THEN /\ LedgerTouch(2)
            /\ holder' = {}
            /\ shownThisTouch' = 0
            /\ wasTerminal' = wasTerminal
       ELSE UNCHANGED <<rowVars, holder, shownThisTouch, wasTerminal, touchObs>>
    /\ UNCHANGED <<clockVars, lost, sched, faults, sentToday, unclaimedSend,
                   shownWhileClosed>>

\* A failed after touch's retry (Lifecycle.retry/3 :605-609): at the next
\* active-hours start, a later day, once per touch.
AfterRetry ==
    /\ state' = "open"
    /\ arrived' = FALSE
    /\ hold' = TRUE
    /\ windowOpen' = FALSE
    /\ untilSet' = UntilLeft
    /\ retried' = TRUE
    /\ UNCHANGED <<touches, slot, planned, dueDays, lastRung, touchedToday, rung2Today,
                   cls, reach, wasTerminal>>

\* Lifecycle.after_outcome/4 (lifecycle.ex:571-589). close: settled elsewhere.
\* An after loop (advance/3 :593, retry/3 :605-609, failed_this_touch?/1
\* :638-643): silent ends it, a failure or a later
\* retries once. A dated loop: silent arms the following slot, or ends a loop
\* with no slot left (a never-asked loop's last before-the-date slot, or the
\* hand-back); a failed send or a later retries at the next active-hours
\* start, a later day; the hand-back retries once.
AfterOutcome(o) ==
    IF o = "close" THEN EndAs("closed")
    ELSE IF After
    THEN IF o = "silent" \/ retried THEN EndAs("expired") ELSE AfterRetry
    ELSE IF o = "silent"
    THEN IF (slot = 1 /\ ~planned /\ touches = 0) \/ (slot = 2 /\ ~planned)
         THEN EndAs("expired")
         ELSE /\ state' = "open"
              /\ slot' = slot + 1
              /\ planned' = FALSE
              /\ arrived' = FALSE
              /\ hold' = TRUE
              /\ windowOpen' = FALSE
              /\ untilSet' = UntilLeft
              /\ UNCHANGED <<touches, dueDays, retried, lastRung, touchedToday,
                             rung2Today, cls, reach, wasTerminal>>
    ELSE IF slot = 2 /\ ~planned /\ retried
         THEN EndAs("expired")
         ELSE /\ state' = "open"
              /\ arrived' = FALSE
              /\ hold' = TRUE
              /\ windowOpen' = FALSE
              /\ untilSet' = UntilLeft
              /\ retried' = (retried \/ (slot = 2 /\ ~planned))
              /\ UNCHANGED <<touches, slot, planned, dueDays, lastRung, touchedToday,
                             rung2Today, cls, reach, wasTerminal>>

\* The finalising write of a run that sent nothing (CheckIn.quiet/3, close/2,
\* failed/4, delivery_failed/3): the same compare-and-set.
Outcome(r) ==
    /\ run[r] \in {"silent", "later", "close", "failed"}
    /\ run' = [run EXCEPT ![r] = "none"]
    /\ IF Holds(r)
       THEN /\ holder' = {}
            /\ AfterOutcome(run[r])
       ELSE UNCHANGED <<rowVars, holder, wasTerminal>>
    /\ UNCHANGED <<clockVars, lost, sched, faults, sentToday, shownThisTouch,
                   unclaimedSend, shownWhileClosed, touchObs>>

RunStep(r) ==
    \/ Decide(r) \/ Check(r) \/ Spend(r) \/ Send(r)
    \/ History(r) \/ Finalize(r) \/ Outcome(r)

-----------------------------------------------------------------------------
(* The owner and the main agent *)

\* open_loop_update -> Registry.update -> Repo.settle_open_loop/3 with
\* Lifecycle.after_answer/5 (lifecycle.ex:392-554). Accepted on any live state, a
\* claimed row included, and every one clears the claim.
\*   done, stop, drop: close.
\*   plan: re-arms at its time, never past a dated loop's date, at most a year
\*     out for an after loop (plan/3 :439-453, plan_bound/3 :475-485).
\*   not yet, dated: one more touch nearer the date (from a due row the passed
\*     slot is not re-armed; at a due hand-back the hand-back re-arms a day on,
\*     next_future_slot/5 finding no slot ahead, not_yet/4 :497-505).
\*   plan and not yet, after: refused once both touches are used
\*     (:touches_spent, touch_left/1); otherwise re-armed at the plan or the new
\*     ask_after (at least 3 h on, Registry.resolve_ask_after/4), and a failure
\*     recorded before the answer no longer counts against the touch
\*     (rearmed/2 :467-471), so the re-armed touch gets its own retry.
\* A not yet on a row that is not due keeps its pending touch here; the code
\* re-arms the first slot from index touches still ahead, which drops a pending
\* plan for that slot.
Answer ==
    /\ OwnerCanAnswer /\ sched = "up" /\ Writable
    /\ OwnerAnswersDuringRun \/ \A x \in Runs : run[x] = "none"
    /\ \/ EndAs("closed")
       \/ /\ Dated /\ ~datePassed
          /\ state' = "open"
          /\ planned' = TRUE
          /\ arrived' = FALSE
          /\ hold' \in OwnerTime
          /\ windowOpen' = FALSE
          /\ untilSet' = UntilLeft
          /\ UNCHANGED <<touches, slot, dueDays, retried, lastRung, touchedToday,
                         rung2Today, cls, reach, wasTerminal>>
       \/ /\ Dated
          /\ state' = "open"
          /\ IF state = "due"
             THEN /\ slot' \in (IF slot >= 2 THEN {slot}
                                ELSE IF planned /\ slot > touches THEN {slot, slot + 1}
                                ELSE {slot + 1})
                  /\ planned' = FALSE
                  /\ arrived' = FALSE
                  /\ hold' = TRUE
             ELSE UNCHANGED <<slot, planned, arrived, hold>>
          /\ windowOpen' = FALSE
          /\ untilSet' = UntilLeft
          /\ UNCHANGED <<touches, dueDays, retried, lastRung, touchedToday, rung2Today,
                         cls, reach, wasTerminal>>
       \/ /\ After
          /\ ~(AfterCap /\ touches >= 2)
          /\ state' = "open"
          /\ arrived' = FALSE
          /\ hold' \in OwnerTime
          /\ windowOpen' = FALSE
          /\ untilSet' = UntilLeft
          /\ retried' = FALSE
          /\ UNCHANGED <<touches, slot, planned, dueDays, lastRung, touchedToday,
                         rung2Today, cls, reach, wasTerminal>>
    /\ holder' = Cleared
    /\ lost' = LoseClaim(Cleared)
    /\ UNCHANGED <<clockVars, run, sched, faults, sentToday, shownThisTouch, unclaimedSend,
                   shownWhileClosed, touchObs>>

\* moved, a dated loop only (Lifecycle.moved/4 :521-533): a new date at least as
\* far as a new medium or long loop's, the class re-derived from now, the
\* touches kept, and the first slot of the new table from index touches armed,
\* which for medium and long is that slot itself, days ahead. With no slot left
\* the loop rests until the new date's hand-back, or the date when its table
\* has none (moved_rest/2 :539-550), and expires on arrival: slot 3, or a
\* conversation loop's resting slot 2, each arriving only once the date has
\* passed, so a moved loop never expires before its new date. A failure
\* recorded before the new date no longer counts against its hand-back
\* (handback_failed_before?/1 :645-650).
Moved ==
    /\ OwnerCanAnswer /\ sched = "up" /\ Writable /\ Dated
    /\ OwnerAnswersDuringRun \/ \A x \in Runs : run[x] = "none"
    /\ daysLeft' = DaysToDate
    /\ state' = "open"
    /\ slot' = Min(touches, 3)
    /\ planned' = FALSE
    /\ arrived' = FALSE
    /\ hold' = TRUE
    /\ windowOpen' = FALSE
    /\ untilSet' = UntilLeft
    /\ retried' = FALSE
    /\ holder' = Cleared
    /\ lost' = LoseClaim(Cleared)
    /\ UNCHANGED <<touches, dueDays, lastRung, touchedToday, rung2Today, cls, reach,
                   dayPhase, run, sched, faults, obsVars>>

\* The window a reach change gives a due row: rung1_until as the scan would
\* write it now under the new reach (reach/3 :550-551). For message, three hours
\* on. For a dated conversation loop, its next slot or the date: when that slot's
\* time has passed, the write leaves rung1_until behind now and the next scan
\* (the reconcile tick, within 60 s) lapses it into the next window; the two
\* steps are folded. For an after conversation loop, its touch plus 14 days.
NewWindow ==
    IF reach' = "message" \/ ~ConversationGate THEN TRUE
    ELSE IF After THEN dueDays < LapseDays
    ELSE ~datePassed

\* reach (M83 §10, reach/3 :548-554): how the loop may be raised from now on, in
\* the owner's words. It moves no slot; the table under the new reach decides
\* what follows (under conversation a pending or resting hand-back expires on
\* arrival and no rung 2 runs; under message the hand-back is armed again).
ReachChange ==
    /\ OwnerChangesReach /\ sched = "up" /\ Writable
    /\ OwnerAnswersDuringRun \/ \A x \in Runs : run[x] = "none"
    /\ reach' = IF reach = "message" THEN "conversation" ELSE "message"
    /\ windowOpen' = IF state = "due" THEN NewWindow ELSE windowOpen
    /\ holder' = Cleared
    /\ lost' = LoseClaim(Cleared)
    /\ UNCHANGED <<state, touches, slot, planned, arrived, hold, untilSet, dueDays, retried,
                   lastRung, touchedToday, rung2Today, cls, clockVars, run, sched, faults,
                   obsVars>>

\* Rung 1: the due note on an owner-private turn inside the window
\* (due_for_note/4's rung1_until > now); the main agent raises the loop and
\* records open_loop_update(asked) -> after_answer "asked" -> after_touch/4 at
\* rung 1 (asked/3). Refused once the phase is spent, and on a row not due
\* (:not_due): a raise the due note did not invite, on an open row, lands only
\* without AskedNeedsDue.
Raise ==
    /\ sched = "up" /\ Writable
    /\ \/ RaiseInConversation /\ state = "due" /\ windowOpen
       \/ RaiseUnprompted /\ state = "open" /\ ~AskedNeedsDue
    /\ ~RaiseRefused
    /\ LedgerTouch(1)
    /\ holder' = Cleared
    /\ lost' = LoseClaim(Cleared)
    /\ shownThisTouch' = 0
    /\ UNCHANGED <<clockVars, run, sched, faults, sentToday, wasTerminal, unclaimedSend,
                   shownWhileClosed>>

-----------------------------------------------------------------------------
(* The clock and the faults *)

\* The legitimate end: the loop ended and nothing runs for it.
Done ==
    /\ state \in Terminal
    /\ sched = "up"
    /\ \A r \in Runs : run[r] = "none"

\* A message loop's rung 1 window closes three hours after it came due: a
\* scheduler timer (Lifecycle.next_wake/2 reads rung1_until, lifecycle.ex:690-701).
WindowCloses ==
    /\ state = "due" /\ windowOpen /\ ~Conv
    /\ windowOpen' = FALSE
    /\ UNCHANGED <<state, touches, slot, planned, arrived, hold, untilSet, dueDays, retried,
                   lastRung, touchedToday, rung2Today, cls, reach, holder, clockVars, run,
                   lost, sched, faults, obsVars>>

\* next_touch_at passes and the scheduler's timer fires. A dated slot after the
\* date arrives only once the date has passed.
SlotArrives ==
    /\ state \in {"open", "asked"} /\ ~arrived /\ ~hold
    /\ BeforeDate \/ datePassed
    /\ arrived' = TRUE
    /\ UNCHANGED <<state, touches, slot, planned, hold, windowOpen, untilSet, dueDays,
                   retried, lastRung, touchedToday, rung2Today, cls, reach, holder,
                   clockVars, run, lost, sched, faults, obsVars>>

HoursStart ==
    /\ ~Done /\ dayPhase = "before" /\ dayPhase' = "in"
    /\ UNCHANGED <<rowVars, holder, daysLeft, run, lost, sched, faults, obsVars>>

HoursEnd ==
    /\ ~Done /\ dayPhase = "in" /\ dayPhase' = "after"
    /\ UNCHANGED <<rowVars, holder, daysLeft, run, lost, sched, faults, obsVars>>

\* A due conversation loop that cannot be raised although its touch is still
\* live: its window closed before its date (dated) or before its lapse (after).
Stranded ==
    /\ state = "due" /\ Conv /\ ~windowOpen
    /\ IF Dated THEN ~datePassed ELSE dueDays < LapseDays

\* A due conversation loop whose window ends at this midnight: a dated one's on
\* the midnight its date passes, an after one's at its lapse.
ConvWindowEndsTonight ==
    /\ state = "due" /\ Conv
    /\ \/ Dated /\ daysLeft = 1
       \/ After /\ dueDays + 1 >= LapseDays

\* Local midnight: the budget's day begins again, a touch held for a later day
\* may arrive, a waiting due row has waited a day, and on a dated loop's last
\* midnight the date passes (matters_by_at), so a before-the-date slot is in the
\* past and a conversation window (never later than the date) closes; an after
\* conversation window closes at its lapse. No run spans midnight: a run starts
\* inside active hours, which end before midnight (ActiveHours, "never past
\* midnight"), and its watchdog ends it within Defaults.checkin_watchdog_ms
\* (120 s). Timing, not a mechanism.
NewDay ==
    /\ ~Done /\ dayPhase = "after"
    /\ \A r \in Runs : run[r] = "none"
    /\ dayPhase' = "before"
    /\ daysLeft' = IF daysLeft > 0 THEN daysLeft - 1 ELSE 0
    /\ touchedToday' = FALSE
    /\ rung2Today' = FALSE
    /\ hold' = FALSE
    /\ dueDays' = IF state = "due"
                  THEN (IF After THEN Min(dueDays + 1, LapseDays) ELSE 1)
                  ELSE dueDays
    /\ arrived' = IF Dated /\ daysLeft = 1 /\ state \in {"open", "asked"} /\ BeforeDate
                  THEN TRUE ELSE arrived
    /\ windowOpen' = IF ConvWindowEndsTonight THEN FALSE ELSE windowOpen
    /\ stranded' = (stranded \/ Stranded)
    /\ sentToday' = 0
    /\ UNCHANGED <<state, touches, slot, planned, untilSet, retried, lastRung, cls, reach,
                   holder, run, lost, sched, faults, shownThisTouch, wasTerminal,
                   unclaimedSend, shownWhileClosed, earlyTouch, convMessage, twiceToday>>

\* The BEAM dies while a run is alive: every run goes; claimed_at stays in the row.
Crash ==
    /\ DaemonCanCrash /\ faults > 0 /\ sched = "up"
    /\ \E r \in Runs : run[r] # "none"
    /\ faults' = faults - 1
    /\ sched' = "down"
    /\ run' = [r \in Runs |-> "none"]
    /\ UNCHANGED <<rowVars, holder, clockVars, lost, obsVars>>

-----------------------------------------------------------------------------
(* Type and sanity invariant *)

TypeOK ==
    /\ state \in States
    /\ touches \in 0..4
    /\ slot \in 0..3
    /\ planned \in BOOLEAN /\ arrived \in BOOLEAN /\ hold \in BOOLEAN
    /\ windowOpen \in BOOLEAN /\ untilSet \in BOOLEAN /\ dueDays \in 0..LapseDays
    /\ retried \in BOOLEAN
    /\ lastRung \in 0..2 /\ touchedToday \in BOOLEAN /\ rung2Today \in BOOLEAN
    /\ cls \in {"dated", "after"} /\ reach \in {"message", "conversation"}
    /\ holder \subseteq Runs /\ Cardinality(holder) <= 1
    /\ daysLeft \in 0..DaysToDate
    /\ dayPhase \in {"before", "in", "after"}
    /\ run \in [Runs -> RunStates]
    /\ lost \in [Runs -> BOOLEAN]
    /\ sched \in {"up", "down"}
    /\ faults \in 0..MaxFaults
    /\ sentToday \in 0..2 /\ shownThisTouch \in 0..2
    /\ wasTerminal \in BOOLEAN /\ unclaimedSend \in BOOLEAN /\ shownWhileClosed \in BOOLEAN
    /\ earlyTouch \in BOOLEAN /\ convMessage \in BOOLEAN /\ stranded \in BOOLEAN
    /\ twiceToday \in BOOLEAN

-----------------------------------------------------------------------------
\* A new loop (Registry.note/3): the first touch is the table's first slot, or
\* an after loop's anchor (first_touch_at/3, lifecycle.ex:135-140); an anchor is
\* at least 3 h on, so it may arrive the same day.
Init ==
    /\ cls \in Classes
    /\ reach \in Reaches
    /\ state = "open"
    /\ touches = 0
    /\ slot = 0
    /\ planned = FALSE
    /\ arrived = FALSE
    /\ hold = FALSE
    /\ windowOpen = FALSE
    /\ untilSet = FALSE
    /\ dueDays = 0
    /\ retried = FALSE
    /\ lastRung = 0
    /\ touchedToday = FALSE
    /\ rung2Today = FALSE
    /\ holder = {}
    /\ daysLeft = IF cls = "after" THEN 0 ELSE DaysToDate
    /\ dayPhase \in {"before", "in", "after"}
    /\ run = [r \in Runs |-> "none"]
    /\ lost = [r \in Runs |-> FALSE]
    /\ sched = "up"
    /\ faults = MaxFaults
    /\ sentToday = 0
    /\ shownThisTouch = 0
    /\ wasTerminal = FALSE
    /\ unclaimedSend = FALSE
    /\ shownWhileClosed = FALSE
    /\ earlyTouch = FALSE
    /\ convMessage = FALSE
    /\ stranded = FALSE
    /\ twiceToday = FALSE

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ Scan \/ ConvLapse \/ Claim \/ Boot
    \/ \E r \in Runs : RunStep(r)
    \/ Answer \/ Moved \/ ReachChange \/ Raise
    \/ WindowCloses \/ SlotArrives \/ HoursStart \/ HoursEnd \/ NewDay
    \/ Crash
    \/ Terminated

\* Fairness only on what Fermix drives: the scheduler's scan, lapse, claim and
\* boot and its timers (a window closing, a touch arriving, the next
\* active-hours start, the next local day), and each live run's next step (its
\* watchdog bounds it). None on the owner, the main agent's raise, the
\* platform's answer, or crashes.
Fairness ==
    /\ WF_vars(Scan) /\ WF_vars(ConvLapse) /\ WF_vars(Claim) /\ WF_vars(Boot)
    /\ WF_vars(WindowCloses) /\ WF_vars(SlotArrives)
    /\ WF_vars(HoursStart) /\ WF_vars(HoursEnd) /\ WF_vars(NewDay)
    /\ \A r \in Runs : WF_vars(RunStep(r))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* M78 §6 Caps: "Touches per loop, ever | 3 | The hand-back is the third; a
\* fourth cannot exist"; the CHECK touches BETWEEN 0 AND 3.
TouchBound == touches <= 3

\* M83 §05: something waited on or gone through gets "1, and one more if they
\* name a new time, or say 'not yet' and Fermix picks one" (D16);
\* Defaults.after_max_touches.
AfterTouchBound == After => touches <= 2

\* M78 §5: "Two terminal states, and neither reopens: a new intention is a new
\* loop"; §18: "a closed or expired row is unreachable by any write path".
TerminalNeverReopens == wasTerminal => state \in Terminal

\* M78 §6 Caps: "Unprompted check-ins per day, all loops | 1"; D6 "1 unprompted
\* a day". Read as: the owner receives at most one rung 2 message a local day.
OneUnpromptedPerDay == sentToday <= 1

\* M78 §18: zero rows from the finalising compare-and-set means "the owner
\* settled it meanwhile, and the run reports closed_meanwhile instead of
\* sending". Read as: no run sends once its claim was released before its
\* outcome step.
NoSendWithoutClaim == ~unclaimedSend

\* M78 §18: "Every settle clears claimed_at", and CHECK (claimed_at IS NULL OR
\* state = 'due').
ClaimClearedOnSettle == holder # {} => state = "due"

\* M83 §09: "Raises something before its ask_after or a plan's date | Code:
\* lifecycle". Read as: no raise is recorded, and no check-in commits its send,
\* before the pending touch has arrived, whether the due note invited the raise
\* or the main agent records one on its own.
NothingBeforeSlot == ~earlyTouch

\* M83 §09: "Messages about a loop marked conversation | Code: rung 2 never
\* starts for it, and it has no hand-back". Read as: no check-in is claimed or
\* spends the day, and no touch is recorded at the hand-back, while the reach is
\* conversation. A reach change landing during the one send is witness 17's
\* race.
NoMessageForConversation == ~convMessage

\* M83 §11 and the CHECK ((state = 'due') = (rung1_until IS NOT NULL)): a row
\* carries its rung 1 window exactly while it is due.
WindowExactlyWhileDue == (state = "due") = untilSet

\* M83 §11: "A window that closes unraised takes the existing quiet path ... so
\* the loop advances or expires". Read as: a due conversation loop never spends
\* a local midnight unraisable (its window closed) while its touch is still live.
DueNeverStranded == ~stranded

\* M83 review (OL-3, fixed): a loop records at most one touch a local day unless
\* the owner named a time later that day. Checked with PlanCanBeToday off.
OneTouchADay == ~twiceToday

\* M78 §12: "a dated loop without an answer reaching expired in bounded
\* touches"; §5: "The only way out of the cycle without the owner's words is
\* expiry".
EveryLoopEnds == <>[](state \in Terminal)

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* The owner settles the loop after the run's outcome step and before its send:
\* the message still goes out. The race the outcome-step read and the spend's
\* compare-and-set narrow, and only a send under a lock could close.
Witness_ShownAfterOwnerClosed == ~shownWhileClosed

\* The owner receives a second message for the same touch: a send the platform
\* showed but whose answer was lost retries on a later day, since only a
\* confirmed send advances the ledger (M78 §8 "Honest state").
Witness_SameTouchSentTwice == shownThisTouch <= 1

\* An after loop reaches its second touch, so AfterTouchBound is not vacuous.
Witness_AfterSecondTouch == ~(After /\ touches = 2)

\* A dated conversation loop's first window lapses unraised and it is due,
\* raisable, in its next slot's window with no touch yet.
RaisableAfterLapse ==
    /\ Dated /\ reach = "conversation" /\ state = "due" /\ windowOpen
    /\ slot = 1 /\ touches = 0
Witness_RaisableAfterLapse == ~RaisableAfterLapse

=============================================================================
