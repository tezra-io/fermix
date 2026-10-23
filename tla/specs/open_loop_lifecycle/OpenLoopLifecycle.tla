------------------------- MODULE OpenLoopLifecycle -------------------------
(***************************************************************************)
(* ONE open loop (MILESTONE_78) of class medium or long, from capture to   *)
(* its end: the due scan (Repo.scan_due_open_loops, Lifecycle.due_decision)*)
(* in the scheduler, the rung 1 raise a main-agent turn records, the rung  *)
(* 2 claim, the check-in run (decide, re-read, spend the day's budget,     *)
(* send, history row, finalize) with the owner's answer racing it, the     *)
(* daily budget, a daemon crash and the boot sweep of claims, and expiry.  *)
(*                                                                         *)
(* Time is abstract. The day has three phases (before, inside and after    *)
(* the owner's active hours); `daysLeft` counts the midnights until the    *)
(* loop's date has passed. A slot is "arrived" or not, and `hold` says the *)
(* pending slot is on a later day (every slot after a touch, a silence or a*)
(* failed run is). The rung 1 window is one boolean on a due row.          *)
(*                                                                         *)
(* Slots: 0 and 1 are before the date, 2 is the hand-back (the day after   *)
(* the date), 3 is the answer day after the hand-back, whose end expires   *)
(* the loop. A plan stands in for the pending slot (`planned`). Classes    *)
(* short and imminent are subsets of this table and are not modelled.      *)
(*                                                                         *)
(* Not modelled: several loops (the budget is the owner's across loops;    *)
(* OL-2 in the README walks the two-loop path), message wording, the       *)
(* active-hours derivation, a provider failure inside the run (the same    *)
(* failed-outcome path as a failed send), the due note's text, the 20-loop *)
(* cap, the main agent recording a raise after the window closed, and a    *)
(* telemetry or history write that errors. Only SQLite rows survive a      *)
(* crash.                                                                  *)
(*                                                                         *)
(* One step = one indivisible thing: one GenServer callback, one           *)
(* Memory.Repo call (every SQLite access goes through that one process), or*)
(* one side effect at the platform. A design spec ahead of part of the     *)
(* code: the scheduler and check-in pins name files lane E is writing, and *)
(* every line number below is re-read at the first re-pin.                 *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/open_loops/lifecycle.ex
\* SOURCE: apps/fermix_core/lib/fermix_core/open_loops/defaults.ex
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/open_loops_sql.ex
\* SOURCE: apps/fermix_core/lib/fermix_core/open_loops/scheduler.ex
\* SOURCE: apps/fermix_core/lib/fermix_core/open_loops/check_in.ex
EXTENDS Naturals, FiniteSets

CONSTANTS
    Runs,           \* CheckInSupervisor's child slots, e.g. {r1, r2} (max_children 2)
    MaxFaults,      \* how many daemon crashes one behaviour may contain
    DaysToDate,     \* midnights from capture until the loop's date has passed
    \* Environment switches: what may happen around the loop.
    OwnerCanAnswer,      \* the owner answers: done, stop, drop, a plan, not yet
    OwnerAnswersDuringRun, \* the owner's answer lands while a check-in run is alive
    PlanCanBeToday,      \* a plan names a time later the same local day
    RaiseInConversation, \* an owner-private turn arrives while the rung 1 window is
                         \* open, and the main agent raises the loop and records it
    SendCanFail,         \* the platform refuses the send: nothing is shown
    AnswerCanBeLost,     \* the platform shows the message, and the run sees a failure
    DaemonCanCrash,      \* the whole daemon dies and boots again
    \* Mechanism switches: what the code does about it. TRUE is the design;
    \* each is switched off by at least one check.
    SingleClaimant,      \* one run per loop: the claim takes only a due, unclaimed
                         \* row (claim/3's WHERE state = 'due' AND claimed_at IS
                         \* NULL, open_loops_sql.ex:571-583), and the scheduler
                         \* claims no loop whose owner has a run in flight
                         \* (Scheduler.weigh/2, scheduler.ex:253-259); redundant
                         \* layers, one switch for both
    FinalizeIsCAS,       \* the run's finalising write is a compare-and-set on
                         \* (id, state = 'due', claimed_at) (finalize/5, :487-498)
    ChecksBeforeSend,    \* the run re-reads the row at its outcome step and reports
                         \* closed_meanwhile when its claim no longer stands
                         \* (CheckIn.still_claimed/1, check_in.ex:426-435), and
                         \* the budget spend is a compare-and-set on the same claim
                         \* (spend_budget/5, open_loops_sql.ex:513-552); redundant
                         \* layers, one switch for both
    WhereLiveGuard,      \* every settle carries WHERE state IN ('open','due','asked')
                         \* (settle/4, :464-472), so a terminal row is unreachable
    SettleClearsClaim,   \* every settle and finalize sets claimed_at = NULL
                         \* (write_settle/5, :554-567), backed by the CHECK
                         \* claimed_at IS NULL OR state = 'due'
    BudgetRead,          \* a claim needs the owner's day unspent:
                         \* budget_spent_since/3 (:834-846) read by
                         \* Scheduler.budget_for/2 (scheduler.ex:301-316) into
                         \* Lifecycle.rung2_eligible?/4 (lifecycle.ex:162-171)
    SpendBeforeSend,     \* the run spends the owner's day before its one send:
                         \* CheckIn.spend_then_deliver/3 (check_in.ex:400-424) ->
                         \* Repo.spend_open_loop_budget/5 (spend_budget/5,
                         \* open_loops_sql.ex:513-552) stamps last_rung2_at, the
                         \* column the budget reads, which no touch writes; off,
                         \* the budget is the loop's last recorded touch, as it
                         \* was before the fix (OL-1, OL-2)
    TouchCap,            \* the slot table ends at the hand-back, whose touch arms
                         \* the answer day (after_touch/4 :184-195,
                         \* following_touch/4 :197-201, Defaults.slots/1), asked is
                         \* refused once touches are spent (:273-279), and the
                         \* CHECK touches BETWEEN 0 AND 3; one switch for all
    BootSweep,           \* the scheduler's boot clears every claimed_at
                         \* (Scheduler.boot_sweep/1, scheduler.ex:187-202;
                         \* sweep_claims/1, open_loops_sql.ex:556-573)
    ScanExpires          \* the due scan expires a loop never asked once its date
                         \* passes, a hand-back a day after its slot, and an asked
                         \* row when its answer day ends (due_decision/2 :112-136)

VARIABLES
    state,        \* SQLite row: open | due | asked | closed | expired
    touches,      \* SQLite row: touches
    slot,         \* SQLite row (derived): which slot next_touch_at stands for
    planned,      \* SQLite row: next_touch_at is a plan's time, not a slot's
    arrived,      \* SQLite row + clock: next_touch_at <= now
    hold,         \* SQLite row + clock: next_touch_at is on a later local day
    windowOpen,   \* SQLite row + clock: a due row inside its 3 h rung 1 window
    dueDays,      \* SQLite row + clock: a due row has waited past a midnight
    hbRetried,    \* SQLite row: the hand-back's one retry is spent
                  \* (handback_failed_before?/1 reads last_outcome)
    lastRung,     \* SQLite row: last_touch_rung (0 = none)
    touchedToday, \* SQLite row + clock: last_touch_at is since the local day began
    rung2Today,   \* SQLite row + clock: last_rung2_at (the spend) is since the
                  \* local day began
    holder,       \* SQLite row: claimed_at, as the run that holds it ({} = none)
    daysLeft,     \* clock: midnights until the date has passed
    dayPhase,     \* clock: before | in | after the owner's active hours
    run,          \* CheckIn process, per slot
    lost,         \* observer, per run: its claim was released before its outcome step
    sched,        \* the daemon: up | down
    faults,       \* crashes still allowed
    sentToday,    \* observer: rung 2 messages the owner received today (saturates)
    shownThisTouch, \* observer: messages the owner received for the pending touch
    wasTerminal,  \* observer: the row has been closed or expired
    unclaimedSend,  \* observer: a run sent after its claim was released
    shownWhileClosed \* observer: a message reached the owner after the loop ended

vars == <<state, touches, slot, planned, arrived, hold, windowOpen, dueDays, hbRetried,
          lastRung, touchedToday, rung2Today, holder, daysLeft, dayPhase, run, lost, sched,
          faults, sentToday, shownThisTouch, wasTerminal, unclaimedSend, shownWhileClosed>>

rowVars == <<state, touches, slot, planned, arrived, hold, windowOpen, dueDays, hbRetried,
             lastRung, touchedToday, rung2Today>>
clockVars == <<daysLeft, dayPhase>>
obsVars == <<sentToday, shownThisTouch, wasTerminal, unclaimedSend, shownWhileClosed>>

States == {"open", "due", "asked", "closed", "expired"}
Live == {"open", "due", "asked"}
Terminal == {"closed", "expired"}
RunStates == {"none", "claimed", "speak", "checked", "spent", "confirmed", "historied",
              "silent", "close", "failed"}
\* A run that has not yet re-read its claim at the outcome step.
PreCheck == {"claimed", "speak"}

datePassed == daysLeft = 0
\* The pending touch is a before-the-date one: slot 0 or 1, or a plan (never later
\* than the date, Lifecycle.plan/3, lifecycle.ex:250-261).
BeforeDate == slot <= 1 \/ planned
\* The day's budget as the claim reads it. With the spend, last_rung2_at is
\* since the local day began (budget_spent_since/3 reads MAX(last_rung2_at) >=
\* the day's start over every row of the owner). Without it, the loop's last
\* touch was a rung 2 touch today: the columns the budget read before the fix
\* (last_touch_rung = 2 AND last_touch_at >= the day's start).
BudgetSpent ==
    /\ BudgetRead
    /\ IF SpendBeforeSend THEN rung2Today ELSE lastRung = 2 /\ touchedToday
\* Lifecycle.phase/1 (lifecycle.ex:430-437) :spent: the class's touches are used,
\* or the hand-back was touched (its answer day is pending). Checked before the
\* pending slot's phase, so a plan never revives a spent loop.
Spent == (TouchCap /\ touches >= 3) \/ slot = 3
\* The settle's WHERE guard.
Writable == state \in Live \/ ~WhereLiveGuard
\* claimed_at after a settle.
Cleared == IF SettleClearsClaim THEN {} ELSE holder
\* A run before its outcome step whose claim the write releases or replaces.
LoseClaim(newHolder) ==
    [x \in Runs |-> lost[x] \/ (run[x] \in PreCheck /\ x \in holder /\ x \notin newHolder)]

-----------------------------------------------------------------------------
(* Row rules shared by several steps *)

\* Lifecycle.after_touch/4 (lifecycle.ex:184-201): a recorded raise or a
\* confirmed rung 2 send. One more touch, asked, the following slot armed on a
\* later day; a touch at the hand-back arms the answer day. The guard
\* touches < 4 is the spec's bound on a run without TouchCap, not code.
LedgerTouch(rung) ==
    /\ touches < 4
    /\ touches' = touches + 1
    /\ state' = "asked"
    /\ slot' = IF slot = 2 THEN (IF TouchCap THEN 3 ELSE 2) ELSE slot + 1
    /\ planned' = FALSE
    /\ arrived' = FALSE
    /\ hold' = TRUE
    /\ windowOpen' = FALSE
    /\ hbRetried' = FALSE
    /\ lastRung' = rung
    /\ touchedToday' = TRUE
    /\ UNCHANGED <<dueDays, rung2Today>>

\* A closing write: closed_at, close_reason, next_touch_at NULL.
EndAs(s) ==
    /\ state' = s
    /\ windowOpen' = FALSE
    /\ wasTerminal' = TRUE
    /\ UNCHANGED <<touches, slot, planned, arrived, hold, dueDays, hbRetried, lastRung,
                   touchedToday, rung2Today>>

\* Lifecycle.due_decision/2 (lifecycle.ex:112-136): {:skip_to_handback, at}.
SkipToHandBack ==
    /\ slot' = 2
    /\ planned' = FALSE
    /\ arrived' = FALSE
    /\ state' = IF state = "due" THEN "asked" ELSE state
    /\ windowOpen' = FALSE
    /\ UNCHANGED <<touches, hold, dueDays, hbRetried, lastRung, touchedToday, rung2Today,
                   wasTerminal>>

\* An expiry the scan decides; without ScanExpires the row is left as it is.
ScanExpire ==
    \/ ScanExpires /\ EndAs("expired")
    \/ ~ScanExpires /\ UNCHANGED <<rowVars, wasTerminal>>

BecomeDue ==
    /\ state' = "due"
    /\ windowOpen' = TRUE
    /\ dueDays' = 0
    /\ UNCHANGED <<touches, slot, planned, arrived, hold, hbRetried, lastRung,
                   touchedToday, rung2Today, wasTerminal>>

-----------------------------------------------------------------------------
(* The scheduler (OpenLoops.Scheduler, one GenServer) *)

\* The due timer or the 60 s reconcile tick -> Scheduler.run_due/2
\* (scheduler.ex:211-221) -> Repo.scan_due_open_loops (open_loops_sql.ex:587-684):
\* one transaction per row, each decided by Lifecycle.due_decision/2. A claimed
\* row is left to its check-in (lifecycle.ex:114).
ScanArrived ==
    \/ Spent /\ ScanExpire
    \/ ~Spent /\ BeforeDate /\ datePassed /\ touches > 0 /\ SkipToHandBack
    \/ ~Spent /\ BeforeDate /\ datePassed /\ touches = 0 /\ ScanExpire
    \/ ~Spent /\ ~(BeforeDate /\ datePassed) /\ BecomeDue

\* A due row is never made due again (become_due, :138); it lapses when its
\* before-the-date slot's date passes, or a day after its hand-back slot
\* (grace_spent?/2, :148-151).
ScanDue ==
    \/ Spent /\ ScanExpire
    \/ ~Spent /\ BeforeDate /\ datePassed /\ touches > 0 /\ SkipToHandBack
    \/ ~Spent /\ BeforeDate /\ datePassed /\ touches = 0 /\ ScanExpire
    \/ ~Spent /\ ~BeforeDate /\ dueDays = 1 /\ ScanExpire

\* One row's transaction in the due scan: an arrived open or asked row, or a due
\* row whose slot has lapsed. Unclaimed rows only.
Scan ==
    /\ sched = "up" /\ holder = {}
    /\ \/ state \in {"open", "asked"} /\ arrived /\ ScanArrived
       \/ state = "due" /\ ScanDue
    /\ UNCHANGED <<holder, clockVars, run, lost, sched, faults, sentToday, shownThisTouch,
                   unclaimedSend, shownWhileClosed>>

\* The same pass, Scheduler.weigh_due/3 (scheduler.ex:230-281): skip an owner
\* with a run in flight, read the hours and the budget, Lifecycle.rung2_eligible?/4
\* (window closed, active hours, budget; lifecycle.ex:162-171), then
\* Repo.claim_open_loop_checkin/3 (open_loops_sql.ex:571-583) and a
\* CheckInSupervisor child. CHOOSE takes one free child slot, always the same one
\* for the same state: slots are interchangeable.
Claim ==
    /\ sched = "up"
    /\ \E x \in Runs : run[x] = "none"
    /\ state = "due" /\ ~windowOpen /\ dayPhase = "in" /\ ~BudgetSpent
    /\ (holder = {} /\ \A x \in Runs : run[x] = "none") \/ ~SingleClaimant
    /\ LET r == CHOOSE x \in Runs : run[x] = "none" IN
         /\ holder' = {r}
         /\ run' = [run EXCEPT ![r] = "claimed"]
         /\ lost' = [x \in Runs |-> IF x = r THEN FALSE ELSE LoseClaim({r})[x]]
    /\ UNCHANGED <<rowVars, clockVars, sched, faults, obsVars>>

\* The restarted daemon's scheduler init: Scheduler.boot_sweep/1
\* (scheduler.ex:187-202) -> Repo.sweep_open_loop_claims/1
\* (open_loops_sql.ex:556-573), since no run outlives the daemon.
Boot ==
    /\ sched = "down"
    /\ sched' = "up"
    /\ holder' = IF BootSweep THEN {} ELSE holder
    /\ UNCHANGED <<rowVars, clockVars, run, lost, faults, obsVars>>

-----------------------------------------------------------------------------
(* A check-in run (OpenLoops.CheckIn) in child slot r *)

\* The run's loop ends with one open_loop_respond decision (§18 "How the outcome
\* tool works"): speak, silent or close. The model's choice.
Decide(r) ==
    /\ run[r] = "claimed"
    /\ \E d \in {"speak", "silent", "close"} : run' = [run EXCEPT ![r] = d]
    /\ UNCHANGED <<rowVars, holder, clockVars, lost, sched, faults, obsVars>>

\* CheckIn.speak/3 -> still_claimed/1 (check_in.ex:378-384, :426-435): one Repo
\* read of the row. A row no longer due, or claimed by another, is
\* closed_meanwhile: a traced skip, nothing sent.
Check(r) ==
    /\ run[r] = "speak"
    /\ run' = [run EXCEPT ![r] =
                 IF ~ChecksBeforeSend \/ (state = "due" /\ r \in holder)
                 THEN "checked" ELSE "none"]
    /\ UNCHANGED <<rowVars, holder, clockVars, lost, sched, faults, obsVars>>

\* CheckIn.spend_then_deliver/3 -> spend_budget/1 (check_in.ex:400-424) ->
\* Repo.spend_open_loop_budget/5 (spend_budget/5, open_loops_sql.ex:513-552):
\* the owner's day is spent before the send, a compare-and-set on the claim the
\* run holds that stamps last_rung2_at, refused (budget_spent) in the same
\* transaction when any row of the owner's already carries today's stamp; with
\* one loop that refusal is never reached. A claim that no longer stands is
\* closed_meanwhile: nothing spent, nothing sent. A send that then fails, a
\* crash, or an answer during the send leaves the day spent. Without the spend
\* the run goes from its re-read straight to the send.
Spend(r) ==
    /\ SpendBeforeSend
    /\ run[r] = "checked"
    /\ IF ~ChecksBeforeSend \/ (state = "due" /\ r \in holder)
       THEN /\ run' = [run EXCEPT ![r] = "spent"]
            /\ rung2Today' = TRUE
       ELSE /\ run' = [run EXCEPT ![r] = "none"]
            /\ UNCHANGED rung2Today
    /\ UNCHANGED <<state, touches, slot, planned, arrived, hold, windowOpen, dueDays,
                   hbRetried, lastRung, touchedToday, holder, clockVars, lost, sched,
                   faults, obsVars>>

\* What the owner receives.
Shown(r) ==
    /\ sentToday' = IF sentToday >= 2 THEN 2 ELSE sentToday + 1
    /\ shownThisTouch' = IF shownThisTouch >= 2 THEN 2 ELSE shownThisTouch + 1
    /\ unclaimedSend' = (unclaimedSend \/ lost[r])
    /\ shownWhileClosed' = (shownWhileClosed \/ state \in Terminal)
    /\ UNCHANGED wasTerminal

\* CheckIn.deliver/3 -> send_once/2 (check_in.ex:426-444): Delivery.ChannelSend,
\* one attempt under send_timeout_ms, proactive key open_loop:<id>:<touch>, to
\* the snapshotted target: confirmed, refused, or shown with the answer lost (a
\* timeout after the platform accepted). The send and its answer are one step.
Send(r) ==
    /\ run[r] = IF SpendBeforeSend THEN "spent" ELSE "checked"
    /\ \/ run' = [run EXCEPT ![r] = "confirmed"] /\ Shown(r)
       \/ SendCanFail /\ run' = [run EXCEPT ![r] = "failed"] /\ UNCHANGED obsVars
       \/ AnswerCanBeLost /\ run' = [run EXCEPT ![r] = "failed"] /\ Shown(r)
    /\ UNCHANGED <<rowVars, holder, clockVars, lost, sched, faults>>

\* CheckIn.record_spoken/3 (check_in.ex:446-470): ConversationStore.add_message/4,
\* the assistant chat_message marked open_loop_checkin, written before the ledger,
\* so a crash between them leaves a history row and no touch.
History(r) ==
    /\ run[r] = "confirmed"
    /\ run' = [run EXCEPT ![r] = "historied"]
    /\ UNCHANGED <<rowVars, holder, clockVars, lost, sched, faults, obsVars>>

\* The run's write lands only while its claim stands.
Holds(r) == (state = "due" /\ r \in holder) \/ ~FinalizeIsCAS

\* The rest of record_spoken/3, then CheckIn.finalize/2 (check_in.ex:486-503):
\* Repo.finalize_open_loop_checkin/5 with Lifecycle.after_touch/4 at rung 2. On
\* :closed_meanwhile the message is already out and the touch is not counted;
\* the day was spent before the send.
Finalize(r) ==
    /\ run[r] = "historied"
    /\ run' = [run EXCEPT ![r] = "none"]
    /\ IF Holds(r)
       THEN /\ LedgerTouch(2)
            /\ holder' = {}
            /\ shownThisTouch' = 0
            /\ wasTerminal' = wasTerminal
       ELSE UNCHANGED <<rowVars, holder, shownThisTouch, wasTerminal>>
    /\ UNCHANGED <<clockVars, lost, sched, faults, sentToday, unclaimedSend,
                   shownWhileClosed>>

\* Lifecycle.after_outcome/4 (lifecycle.ex:295-345). close: settled elsewhere.
\* silent: the following slot, or the end of a loop with no slot left (a
\* never-asked loop's last before-the-date slot, or the hand-back). A failed
\* send: retry at the next active-hours start, a later day; the hand-back
\* retries once.
AfterOutcome(o) ==
    IF o = "close" THEN EndAs("closed")
    ELSE IF o = "silent"
    THEN IF (slot = 1 /\ ~planned /\ touches = 0) \/ (slot = 2 /\ ~planned)
         THEN EndAs("expired")
         ELSE /\ state' = "open"
              /\ slot' = slot + 1
              /\ planned' = FALSE
              /\ arrived' = FALSE
              /\ hold' = TRUE
              /\ windowOpen' = FALSE
              /\ UNCHANGED <<touches, dueDays, hbRetried, lastRung, touchedToday,
                             rung2Today, wasTerminal>>
    ELSE IF slot = 2 /\ ~planned /\ hbRetried
         THEN EndAs("expired")
         ELSE /\ state' = "open"
              /\ arrived' = FALSE
              /\ hold' = TRUE
              /\ windowOpen' = FALSE
              /\ hbRetried' = (hbRetried \/ (slot = 2 /\ ~planned))
              /\ UNCHANGED <<touches, slot, planned, dueDays, lastRung, touchedToday,
                             rung2Today, wasTerminal>>

\* The finalising write of a run that sent nothing (CheckIn.quiet/3, close/2,
\* failed/4, delivery_failed/3; check_in.ex:358-372, :472-482): the same
\* compare-and-set.
Outcome(r) ==
    /\ run[r] \in {"silent", "close", "failed"}
    /\ run' = [run EXCEPT ![r] = "none"]
    /\ IF Holds(r)
       THEN /\ holder' = {}
            /\ AfterOutcome(run[r])
       ELSE UNCHANGED <<rowVars, holder, wasTerminal>>
    /\ UNCHANGED <<clockVars, lost, sched, faults, sentToday, shownThisTouch,
                   unclaimedSend, shownWhileClosed>>

RunStep(r) ==
    \/ Decide(r) \/ Check(r) \/ Spend(r) \/ Send(r)
    \/ History(r) \/ Finalize(r) \/ Outcome(r)

-----------------------------------------------------------------------------
(* The owner and the main agent *)

\* open_loop_update -> Registry.update -> Repo.settle_open_loop/3 with
\* Lifecycle.after_answer/5 (lifecycle.ex:226-271). done, stop and drop close;
\* a plan re-arms at its time, never past the date; not yet keeps the loop open
\* for one more touch nearer the date (from a due row, the passed slot is not
\* re-armed). Accepted on any live state, a claimed row included.
Answer ==
    /\ OwnerCanAnswer /\ sched = "up" /\ Writable
    /\ OwnerAnswersDuringRun \/ \A x \in Runs : run[x] = "none"
    /\ \/ /\ EndAs("closed")
       \/ /\ ~datePassed
          /\ state' = "open"
          /\ planned' = TRUE
          /\ arrived' = FALSE
          /\ hold' \in (IF PlanCanBeToday THEN BOOLEAN ELSE {TRUE})
          /\ windowOpen' = FALSE
          /\ UNCHANGED <<touches, slot, dueDays, hbRetried, lastRung, touchedToday,
                         rung2Today, wasTerminal>>
       \/ /\ state' = "open"
          /\ IF state = "due" /\ slot < 3
             THEN /\ slot' = slot + 1
                  /\ planned' = FALSE
                  /\ arrived' = FALSE
                  /\ hold' = TRUE
             ELSE UNCHANGED <<slot, planned, arrived, hold>>
          /\ windowOpen' = FALSE
          /\ UNCHANGED <<touches, dueDays, hbRetried, lastRung, touchedToday, rung2Today,
                         wasTerminal>>
    /\ holder' = Cleared
    /\ lost' = LoseClaim(Cleared)
    /\ UNCHANGED <<clockVars, run, sched, faults, sentToday, shownThisTouch, unclaimedSend,
                   shownWhileClosed>>

\* Rung 1: the due note on an owner-private turn inside the window; the main agent
\* raises the loop and records open_loop_update(asked) -> after_answer "asked"
\* -> after_touch/4 at rung 1 (lifecycle.ex:273-279). Refused once touches are
\* spent.
Raise ==
    /\ RaiseInConversation /\ sched = "up" /\ Writable
    /\ state = "due" /\ windowOpen
    /\ touches < 3 \/ ~TouchCap
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

\* The rung 1 window closes (rung1_window_ms after next_touch_at): a scheduler
\* timer (Lifecycle.next_wake/2, lifecycle.ex:394-405).
WindowCloses ==
    /\ state = "due" /\ windowOpen
    /\ windowOpen' = FALSE
    /\ UNCHANGED <<state, touches, slot, planned, arrived, hold, dueDays, hbRetried,
                   lastRung, touchedToday, rung2Today, holder, clockVars, run, lost, sched,
                   faults, obsVars>>

\* next_touch_at passes and the scheduler's timer fires. A slot after the date
\* arrives only once the date has passed.
SlotArrives ==
    /\ state \in {"open", "asked"} /\ ~arrived /\ ~hold
    /\ BeforeDate \/ datePassed
    /\ arrived' = TRUE
    /\ UNCHANGED <<state, touches, slot, planned, hold, windowOpen, dueDays, hbRetried,
                   lastRung, touchedToday, rung2Today, holder, clockVars, run, lost, sched,
                   faults, obsVars>>

HoursStart ==
    /\ ~Done /\ dayPhase = "before" /\ dayPhase' = "in"
    /\ UNCHANGED <<rowVars, holder, daysLeft, run, lost, sched, faults, obsVars>>

HoursEnd ==
    /\ ~Done /\ dayPhase = "in" /\ dayPhase' = "after"
    /\ UNCHANGED <<rowVars, holder, daysLeft, run, lost, sched, faults, obsVars>>

\* Local midnight: the budget's day begins again, a slot held for a later day may
\* arrive, a waiting due row has waited a day, and on the last midnight the date
\* passes (matters_by_at), so a before-the-date slot is in the past. No run spans
\* midnight: a run starts inside active hours, which end before midnight
\* (ActiveHours, "never past midnight"), and its watchdog ends it within
\* Defaults.checkin_watchdog_ms (120 s). Timing, not a mechanism.
NewDay ==
    /\ ~Done /\ dayPhase = "after"
    /\ \A r \in Runs : run[r] = "none"
    /\ dayPhase' = "before"
    /\ daysLeft' = IF daysLeft > 0 THEN daysLeft - 1 ELSE 0
    /\ touchedToday' = FALSE
    /\ rung2Today' = FALSE
    /\ hold' = FALSE
    /\ dueDays' = IF state = "due" THEN 1 ELSE dueDays
    /\ arrived' = IF daysLeft = 1 /\ state \in {"open", "asked"} /\ BeforeDate
                  THEN TRUE ELSE arrived
    /\ sentToday' = 0
    /\ UNCHANGED <<state, touches, slot, planned, windowOpen, hbRetried, lastRung, holder,
                   run, lost, sched, faults, shownThisTouch, wasTerminal, unclaimedSend,
                   shownWhileClosed>>

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
    /\ windowOpen \in BOOLEAN /\ dueDays \in 0..1 /\ hbRetried \in BOOLEAN
    /\ lastRung \in 0..2 /\ touchedToday \in BOOLEAN /\ rung2Today \in BOOLEAN
    /\ holder \subseteq Runs /\ Cardinality(holder) <= 1
    /\ daysLeft \in 0..DaysToDate
    /\ dayPhase \in {"before", "in", "after"}
    /\ run \in [Runs -> RunStates]
    /\ lost \in [Runs -> BOOLEAN]
    /\ sched \in {"up", "down"}
    /\ faults \in 0..MaxFaults
    /\ sentToday \in 0..2 /\ shownThisTouch \in 0..2
    /\ wasTerminal \in BOOLEAN /\ unclaimedSend \in BOOLEAN /\ shownWhileClosed \in BOOLEAN

-----------------------------------------------------------------------------
Init ==
    /\ state = "open"
    /\ touches = 0
    /\ slot = 0
    /\ planned = FALSE
    /\ arrived = FALSE
    /\ hold = FALSE
    /\ windowOpen = FALSE
    /\ dueDays = 0
    /\ hbRetried = FALSE
    /\ lastRung = 0
    /\ touchedToday = FALSE
    /\ rung2Today = FALSE
    /\ holder = {}
    /\ daysLeft = DaysToDate
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

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ Scan \/ Claim \/ Boot
    \/ \E r \in Runs : RunStep(r)
    \/ Answer \/ Raise
    \/ WindowCloses \/ SlotArrives \/ HoursStart \/ HoursEnd \/ NewDay
    \/ Crash
    \/ Terminated

\* Fairness only on what Fermix drives: the scheduler's scan, claim, boot and
\* timers (the window closing, a slot arriving, the next active-hours start, the
\* next local day), and each live run's next step (its watchdog bounds it). None on
\* the owner, the main agent's raise, the platform's answer, or crashes.
Fairness ==
    /\ WF_vars(Scan) /\ WF_vars(Claim) /\ WF_vars(Boot)
    /\ WF_vars(WindowCloses) /\ WF_vars(SlotArrives)
    /\ WF_vars(HoursStart) /\ WF_vars(HoursEnd) /\ WF_vars(NewDay)
    /\ \A r \in Runs : WF_vars(RunStep(r))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* M78 §6 Caps: "Touches per loop, ever | 3 | The hand-back is the third; a
\* fourth cannot exist"; the CHECK touches BETWEEN 0 AND 3.
TouchBound == touches <= 3

\* M78 §5: "Two terminal states, and neither reopens: a new intention is a new
\* loop"; §18: "a closed or expired row is unreachable by any write path".
TerminalNeverReopens == wasTerminal => state \in Terminal

\* M78 §6 Caps: "Unprompted check-ins per day, all loops | 1"; D6 "1 unprompted
\* a day". Read as: the owner receives at most one rung 2 message a local day.
OneUnpromptedPerDay == sentToday <= 1

\* §18: zero rows from the finalising compare-and-set means "the owner settled it
\* meanwhile, and the run reports closed_meanwhile instead of sending". Read as:
\* no run sends once its claim was released before its outcome step.
NoSendWithoutClaim == ~unclaimedSend

\* §18: "Every settle clears claimed_at", and CHECK (claimed_at IS NULL OR
\* state = 'due').
ClaimClearedOnSettle == holder # {} => state = "due"

\* §12: "a dated loop without an answer reaching expired in bounded touches";
\* §5: "The only way out of the cycle without the owner's words is expiry".
EveryLoopEnds == <>[](state \in Terminal)

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* The owner settles the loop after the run's outcome step and before its send:
\* the message still goes out. The race the outcome-step read and the spend's
\* compare-and-set narrow, and only a send under a lock could close.
Witness_ShownAfterOwnerClosed == ~shownWhileClosed

\* The owner receives a second message for the same touch: a send the platform
\* showed but whose answer was lost retries on a later day, since only a
\* confirmed send advances the ledger (§8 "Honest state").
Witness_SameTouchSentTwice == shownThisTouch <= 1

=============================================================================
