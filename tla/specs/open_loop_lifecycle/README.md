# open_loop_lifecycle: one open loop, from capture to its end

Models one open loop (M78, `docs/design/MILESTONE_78_OPEN_LOOPS.html`) of class
medium or long, through every party that can move it:
- the scheduler's due scan (`Scheduler.run_due/2` → `Repo.scan_due_open_loops/3`,
  each row decided by `Lifecycle.due_decision/2`), its rung 2 claim pass
  (`Scheduler.weigh_due/3`: the owner-busy skip, active hours, the day's budget,
  `Lifecycle.rung2_eligible?/4`, `Repo.claim_open_loop_checkin/3`) and its boot
  sweep (`Repo.sweep_open_loop_claims/1`);
- a check-in run (`OpenLoops.CheckIn`): the model's decision, the re-read of its
  claim (`still_claimed/1`), the spend of the owner's day on that claim
  (`spend_then_deliver/3` → `Repo.spend_open_loop_budget/5`), one `ChannelSend`
  attempt, the history row (`ConversationStore.add_message/4`), and the
  compare-and-set finalising write (`Repo.finalize_open_loop_checkin/4`);
- the main agent recording a rung 1 raise (`open_loop_update` answer `asked`);
- the owner's answer (done, stop, drop, a plan, not yet) through
  `Repo.settle_open_loop/3`, racing the run;
- the clock (the owner's active hours, local midnights, the loop's date) and the
  faults: a failed send, a send the platform showed but answered as failed, and a
  daemon crash.

**Status.** Written against the stage 1 and stage 3 code before it was
committed, re-read against the commit that landed the feature, `d4c723aa`
(2026-10-23), and pinned to it. That commit also carries the spend's refusal of
an already-spent day (`budget_spent`), described under `SpendBeforeSend` below;
the one-loop model never reaches it. Every `path:line` in the spec names that
commit.

**Abstractions.** Time is a day in three phases (before, inside and after the
owner's active hours) and a count of midnights until the loop's date has passed
(`DaysToDate`). The pending touch is a slot index: 0 and 1 are before the date, 2
is the hand-back (the day after the date), 3 is the answer day after the
hand-back, whose end expires the loop; a plan stands in for the pending slot
(`planned`). A slot has "arrived" or not, and `hold` says it is on a later local
day, as every slot after a touch, a silence or a failed run is. The rung 1 window
is one boolean on a due row. The daily budget is what the claim reads: the
row's `last_rung2_at` is today (`rung2Today`, which `Spend` sets and `NewDay`
resets), the column `budget_spent_since/3` reads. With `SpendBeforeSend` off it
is the budget before the fix: the loop's last touch was a rung 2 touch today
(`lastRung = 2 /\ touchedToday`).

**Bounds.** Two check-in child slots (`CheckInSupervisor`'s `max_children`), one
crash, two midnights to the date. Every check runs in under three seconds.

**Environment switches** (set per check):

| Switch | When `TRUE` |
|---|---|
| `OwnerCanAnswer` | The owner answers: done, stop, drop, a plan, not yet. |
| `OwnerAnswersDuringRun` | The answer can land while a check-in run is alive. |
| `PlanCanBeToday` | A plan names a time later the same local day. |
| `RaiseInConversation` | An owner-private turn arrives inside the rung 1 window, and the main agent raises the loop and records it. |
| `SendCanFail` | The platform refuses the send; nothing is shown. |
| `AnswerCanBeLost` | The platform shows the message and the run sees a failure (a timeout after the platform accepted). |
| `DaemonCanCrash` | The daemon dies with a run alive, and boots again. |

**Mechanism switches** (`TRUE` is the code; each is switched off by at least one
check):

| Switch | The code | Off |
|---|---|---|
| `SingleClaimant` | The claim's `WHERE state = 'due' AND claimed_at IS NULL` (`open_loops_sql.ex:571-583`) and the scheduler's skip of an owner with a run in flight (`scheduler.ex:253-259`). Redundant layers; one switch turns off both. | Two runs hold the loop. |
| `FinalizeIsCAS` | The finalising write's `WHERE id = ? AND state = 'due' AND claimed_at = ?` (`open_loops_sql.ex:487-498`). | The run writes whatever the row became. |
| `ChecksBeforeSend` | `CheckIn.still_claimed/1` (`check_in.ex:427-436`) before the send, and the budget spend's `WHERE id = ? AND state = 'due' AND claimed_at = ?` (`open_loops_sql.ex:513-552`). Redundant layers; one switch turns off both. | The run sends without re-reading, and the spend writes whatever the row became. |
| `WhereLiveGuard` | Every settle's `WHERE state IN ('open','due','asked')` (`open_loops_sql.ex:464-472`). | A settle reaches a closed or expired row. |
| `SettleClearsClaim` | `claimed_at = NULL` in every settle and finalize (`write_settle/5`, `:554-567`), backed by the `CHECK (claimed_at IS NULL OR state = 'due')`. | A settle leaves the claim. |
| `BudgetRead` | The claim reads `budget_spent_since/3` (`:834-846`) through `Scheduler.budget_for/2` (`scheduler.ex:301-316`). | No budget. |
| `SpendBeforeSend` | The run spends the owner's day before its one send (`CheckIn.spend_then_deliver/3`, `check_in.ex:401-425`; `Repo.spend_open_loop_budget/5`, `open_loops_sql.ex:513-552`), stamping `last_rung2_at`, the one column the budget reads and no touch writes. The same transaction refuses the stamp (`budget_spent`) when any row of the owner's already carries one since the local day began; with one loop modelled that branch is never taken. | The budget is the loop's last recorded touch, as before the fix. |
| `TouchCap` | The slot table ends at the hand-back, whose touch arms the answer day (`Lifecycle.after_touch/4`, `following_touch/4`, `Defaults.slots/1`); the spent phase is checked first (`Lifecycle.phase/1`); `asked` is refused once touches are spent; the `CHECK touches BETWEEN 0 AND 3`. One switch for all. | The hand-back re-arms itself. |
| `BootSweep` | `Scheduler.boot_sweep/1` (`scheduler.ex:187-202`). | Nothing runs at boot. |
| `ScanExpires` | The due scan's expiries (`Lifecycle.due_decision/2`, `lifecycle.ex:114-153`). | The scan never expires a loop. |

## What holds

- Check 01, with every fault on, 94,148 states:
  - A loop is touched at most three times (§6 Caps: "a fourth cannot exist").
    This rests on `TouchCap` (check 02).
  - A closed or expired loop never reopens (§5, §18). This rests on
    `WhereLiveGuard` (check 03: an owner's plan or not yet on a closed row) and
    `FinalizeIsCAS` (check 04: a run that outlived the owner's done writes the
    loop back to asked).
  - No run sends once its claim was released before its outcome step (§18,
    `closed_meanwhile`). This rests on `ChecksBeforeSend` (check 05).
  - Only a due row holds a claim (§18 and the `CHECK`). This rests on
    `SettleClearsClaim` (check 06).
- Checks 10 to 13: the owner receives at most one unprompted check-in a day
  (§6 Caps, D6), with plans for later the same day and failed sends, through
  each path that once broke it: a crash between the send and its ledger write
  (10, 8,581 states), an answer landing during the send (11, 16,152), a send the
  platform showed but answered as failed (12, 6,074), and a rung 1 raise after
  the day's rung 2 (13, 5,816). Each rests on `SpendBeforeSend` (checks 19 to
  22): with the budget read from the last recorded touch, each breaks the rule
  again with OL-1's or OL-2's counterexample (14, 18, 17 and 22 states).
- Check 07, 2,543 states, the same rule with the spend switched off: it holds
  when every message the owner receives is a recorded touch (no crash, no lost
  answer, no answer landing during a run) and no rung 1 raise comes between two
  claims. This rests on:
  - `BudgetRead` (check 08). With one loop, the budget is load-bearing only
    when the loop comes due twice in a day, which a same-day plan does.
  - `SingleClaimant` (check 09): two runs hold the loop, both pass their
    re-read, both send.

  The spend is checked apart from the claim because, for one loop, its
  compare-and-set on the run's claim is a second layer behind `SingleClaimant`:
  with the spend on, check 09 holds. Across loops it is not: the spend is
  per row, so two loops' runs in flight at once would both spend and both send,
  and the scheduler's owner-busy skip is the only layer. This spec models one
  loop.
- Check 14: with the owner never answering and every other fault on, the loop
  always ends expired or closed and stays there (§12, §5), 4,971 states. Weak
  fairness covers the scheduler's scan, claim and boot, its timers (the window
  closing, a slot arriving, the next active-hours start, the next local day),
  and each live run's next step. None applies to the owner, the main agent's
  raise, the platform's answer or crashes. This rests on `BootSweep` (check 15:
  a claim stranded by a crash is left to a run that no longer exists, and the
  scan skips claimed rows forever) and `ScanExpires` (check 16: an unanswered
  hand-back stays asked forever).

**Witnesses:**
- 17: the owner settles the loop after the run's spend and before its send, and
  the message still arrives. The re-read and the spend's compare-and-set narrow
  the window to one `ChannelSend` attempt (up to `send_timeout_ms`, 60 s); only a
  send under a lock would close it. `record_spoken/3` logs the case when its
  finalise finds the claim gone; the day stays spent.
- 18: with no crash, a check-in the platform showed but answered as failed is
  sent again on a later day for the same touch. Only a confirmed send advances
  the ledger (§8 "Honest state"), so the owner can receive more messages for a
  loop than it has touches.

**One more of each, run by hand** (six workers, no time limit): every holds check
still holds.

| Check | Normal bound | One more | Result |
|---|---|---|---|
| 01 | 2 runs, 1 crash, 2 midnights: 94,148 states | 2 crashes, 3 midnights | holds, 255,040 states |
| 01 | the same | 3 runs | holds, 94,148 states (the third slot is never used) |
| 07 | 2 runs, 1 crash, 2 midnights: 2,543 states | 2 crashes, 3 midnights | holds, 3,811 states |
| 07 | the same | 3 runs | holds, 2,543 states |
| 10 | 2 runs, 1 crash, 2 midnights: 8,581 states | 2 crashes, 3 midnights | holds, 24,925 states |
| 10 | the same | 3 runs | holds, 8,581 states |
| 11 | 2 runs, 1 crash, 2 midnights: 16,152 states | 2 crashes, 3 midnights | holds, 30,283 states |
| 11 | the same | 3 runs | holds, 16,152 states |
| 12 | 2 runs, 1 crash, 2 midnights: 6,074 states | 2 crashes, 3 midnights | holds, 10,020 states |
| 12 | the same | 3 runs | holds, 6,074 states |
| 13 | 2 runs, 1 crash, 2 midnights: 5,816 states | 2 crashes, 3 midnights | holds, 8,722 states |
| 13 | the same | 3 runs | holds, 5,816 states |
| 14 | 2 runs, 1 crash, 2 midnights: 4,971 states | 2 crashes, 3 midnights | holds, 11,210 states |
| 14 | the same | 3 runs | holds, 4,971 states |

A third child slot is never used: with `SingleClaimant` the scheduler claims
nothing for an owner whose run is alive, so one slot serves every claim.

## Findings

Both were found by the model checker in the build before it was committed,
walked through that code, and fixed by one mechanism inside the same commit,
`d4c723aa`: the run spends the owner's day before its send
(`SpendBeforeSend`). To see a counterexample from before the fix, run
`make -C tla report SPECS=open_loop_lifecycle`, or `tla/bin/check.py
open_loop_lifecycle` and open `tla/out/open_loop_lifecycle/<check>.txt` for
checks 19 to 22.

### OL-1: a message without its touch leaves the day's budget unspent
- **Severity:** low. Each path needs a narrow window or a second fault, and the
  extra message is one more check-in, not a stream of them.
- **Status:** fixed by `SpendBeforeSend` in `d4c723aa`, the commit that landed
  the feature; the defect never shipped.
- **Checks:** 10 (a crash), 11 (an answer during the send) and 12 (a lost
  answer) hold; 19, 20 and 21 (`needs SpendBeforeSend`) break with the fix
  switched off. Before the fix checks 10 to 12 were `violated OL-1`.
- **Root cause (before the fix).** The budget counted recorded touches
  (`rung2_sent_since/3` read `last_touch_rung = 2`, written only by a successful
  finalise), while the owner counts messages. Three paths delivered a message
  with no recorded touch:
- **Counterexample, through a crash (old check 10, now 19; 14 states):**
  1. The loop is due, its window closes, and a run claims it, decides to speak,
     re-reads its claim and sends. The owner has the message.
  2. The daemon crashes before `record_spoken/3` finalises.
  3. The boot sweep returns the claim. The row is still due, and no rung 2 touch
     is recorded today.
  4. The next pass claims it again, and the second run sends.
- **Counterexample, through an answer during the send (old check 11, now 20;
  18 states):**
  1. A run sends and writes the history row.
  2. The owner answers with a plan for later the same day. The settle clears the
     claim.
  3. The finalise finds the claim gone and records nothing; `record_spoken/3`
     logs "the touch is not counted".
  4. The plan comes due that afternoon, its window closes, the budget reads
     unspent, and a second run sends.
- **Counterexample, through a lost answer (old check 12, now 21; 17 states):**
  1. A run sends; the platform shows the message and the send times out.
  2. The outcome is `delivery_failed`: a retry at the next active-hours start,
     no touch.
  3. The owner plans for later the same day; the plan comes due, and a second
     run sends.
- **Impact (before the fix):** a second unprompted message the same day,
  against D6's one a day. With several loops the same paths let another loop's
  check-in through.
- **The fix.** After its re-read and before `ChannelSend`, the run spends the
  day: `Repo.spend_open_loop_budget/5` stamps `last_rung2_at` with a
  compare-and-set on its claim (`closed_meanwhile` sends nothing), refusing
  `budget_spent` in the same transaction when any row of the owner's already
  carries today's stamp, and the claim reads `MAX(last_rung2_at)` over every
  row of the owner, closed and expired ones included
  (`open_loop_budget_spent_since/3`). Every path above now finds the day
  spent. The cost is the safe direction: a send that fails, or a crash
  before it, uses the day, so a lost message costs the owner a quiet day, never
  a second message.

### OL-2: a rung 1 raise erases the day's rung 2 touch from the budget
- **Severity:** medium-low. It needs a check-in the owner answered with a plan
  for later the same day, or a second loop.
- **Status:** fixed by `SpendBeforeSend` in `d4c723aa`, the commit that landed
  the feature; the defect never shipped.
- **Checks:** 13 holds; 22 (`needs SpendBeforeSend`) breaks with the fix
  switched off. Before the fix check 13 was `violated OL-2`.
- **Root cause (before the fix).** The budget read each loop's last touch only.
  A rung 1 raise writes `last_touch_rung = 1` and a new `last_touch_at` over the
  rung 2 touch the budget was counting (`after_answer` "asked" →
  `after_touch/4` at rung 1).
- **Counterexample (old check 13, now 22; 22 states):**
  1. A rung 2 check-in is sent and finalised: touch 1, `last_touch_rung = 2`.
  2. The owner answers with a plan for later today; it comes due, and inside its
     window the owner chats. The main agent raises the loop and records it:
     `last_touch_rung = 1`.
  3. The owner plans again for later today; it comes due and its window closes
     without a raise.
  4. The budget reads no rung 2 touch today, and a second run sends.
- **The realistic path has two loops**, which this spec does not model: loop A's
  rung 2 check-in at 10:00, a plan for 14:00, a rung 1 raise on A at 14:30. From
  then on loop B's due row read the budget unspent and got the day's second
  unprompted message.
- **The fix.** The budget is its own column, `last_rung2_at`, written only by
  the spend before a send and read across the owner's rows; a raise writes the
  touch columns and never touches it. The scheduler test "a rung 1 raise after
  the day's rung 2 still blocks a second rung 2" walks the two-loop path.

## Not modelled

- **Several loops.** The budget and the owner-busy skip are the owner's across
  loops; OL-2's realistic path needs two. Across loops two layers keep two
  runs from both sending on one day: the scheduler's owner-busy skip, and the
  spend's own refusal of a day any row of the owner's already stamped
  (`budget_spent`, read and written in one transaction on the single writer;
  the run then closes as an `error` and re-arms, and nothing is sent). The
  one-loop model exercises neither.
- **Classes short and imminent.** Short is two slots of the same table; imminent
  is rung 1 only and expires at its date.
- **A provider failure or timeout inside the run.** The same failed-outcome path
  as a failed send (`after_outcome/4`).
- **`empty`** (no decision): `silent`'s path.
- **The main agent recording a raise after the window closed**, the double-ask
  risk §11 names. A raise lands only inside the window here.
- **The 20-loop cap, message bounds and wording**, single-call rules in ExUnit
  and the capability eval.
- **A history or telemetry write that errors.** `record_spoken/3` matches `:ok`.

## Assumptions

- **No run spans midnight.** A run starts inside active hours, which end before
  midnight, and its watchdog ends it within `checkin_watchdog_ms` (120 s). This
  is timing, not a mechanism, so it has no switch: `NewDay` waits for every run
  to end.
- **Folded steps.** `Send` is the request and the platform's answer. `Claim` is
  the pass's reads (the owner-busy check, the hours, the budget) and the claim
  write: one GenServer callback, and only the claim is a write. `Answer` is the
  settle, one Repo call.
- **The due scan's skip lands the hand-back at the default 09:00**, before the
  owner's own hours; the claim still waits for the owner's window, so the spec
  treats the skipped row like any other pending hand-back.
