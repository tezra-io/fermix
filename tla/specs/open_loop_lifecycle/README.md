# open_loop_lifecycle: one open loop, from capture to its end

Models one open loop (M78, `docs/design/MILESTONE_78_OPEN_LOOPS.html`; M83,
`docs/design/MILESTONE_83_OPEN_LOOP_CURIOSITY.html`) in either timing and either
reach, through every party that can move it:
- the scheduler's due scan (`Scheduler.run_due/2` → `Repo.scan_due_open_loops/3`,
  each row decided by `Lifecycle.due_decision/2`), including a conversation
  loop's quiet path from one window to the next (`{:lapse, …}`), its rung 2
  claim pass (`Scheduler.weigh_due/3`: the owner-busy skip, active hours, the
  day's budget, `Lifecycle.rung2_eligible?/4`, `Repo.claim_open_loop_checkin/3`)
  and its boot sweep (`Repo.sweep_open_loop_claims/1`);
- a check-in run (`OpenLoops.CheckIn`): the model's decision (speak, silent,
  later or close; a later takes a failed run's retry path, so it is that
  touch's one retry, `after_outcome/4`'s `@retry_outcomes`), the re-read of its
  claim (`still_claimed/1`), the spend of the owner's day on that claim
  (`spend_then_deliver/3` → `Repo.spend_open_loop_budget/5`), one `ChannelSend`
  attempt, the history row (`ConversationStore.add_message/4`), and the
  compare-and-set finalising write (`Repo.finalize_open_loop_checkin/4`);
- the main agent recording a rung 1 raise (`open_loop_update` answer `asked`),
  invited by the due note or on its own;
- the owner's answer through `Repo.settle_open_loop/3`, racing the run: done,
  stop, drop, a plan, not yet (on an `after` loop with its new `ask_after`), a
  moved date (`moved`, dated loops) and a new reach (`reach`);
- the clock (the owner's active hours, local midnights, a dated loop's date, an
  `after` touch's 14-day lapse) and the faults: a failed send, a send the
  platform showed but answered as failed, and a daemon crash.

The two timings (`Classes`): a **dated** loop, something to do by a date, of
class medium or long; an **after** loop, something waited on or gone through,
asked about from its anchor, touched at most twice, with no hand-back. The two
reaches (`Reaches`, and the owner's `reach` answer): **message**, raised in
conversation or by one check-in message, and **conversation**, raised only in a
conversation the owner starts: no rung 2, no hand-back, and a rung 1 window that
runs from one slot to the next (`rung1_until`).

**Status.** M78's version was written against the stage 1 and stage 3 code
before it was committed and pinned to the commit that landed the feature,
`d4c723aa` (2026-10-23). This revision was written against M83's lifecycle work
(stage 2) while it was still uncommitted: every `path:line` names that working
tree, and the spec stays STALE until that code is committed, this spec re-read
against it, and `make -C tla repin SPECS=open_loop_lifecycle` run. It also pins
`Registry.update/4` and the helpers that resolve an answer's times, since the
answers now carry them.

This revision also follows the fixes the first M83 read prompted, made in the
same working tree: OL-3, a raise recorded only on a due row (`:not_due`), an
`after` loop's spent touches refusing a plan or a new `ask_after`
(`:touches_spent`), and its retry counted per armed touch. Re-reading the M78
parts against the code corrected two steps that no check depended on: the due scan's skip to the hand-back writes a due row back to
`open`, not `asked` (`apply_decision/4`); and `not_yet` on a due hand-back
re-arms the hand-back a day on, since `next_future_slot/5` finds no slot ahead
and the phase stays `:handback`. The claim pass now also leaves a due row the
same pass's scan moves (`run_due/2` weighs only `scan.due ++ scan.waiting`).
A moved loop with no slot of its new table left now rests until the new
date's hand-back, or the date when its table has none (`moved_rest/2`), which
`Moved` already modelled, since slot 3 and a conversation loop's resting slot
2 arrive only after the date; the code had armed the answer day a day on, and
expired the loop before its new date.

**Abstractions.** Time is a day in three phases (before, inside and after the
owner's active hours) and, for a dated loop, a count of midnights until its
date has passed (`DaysToDate`). A dated loop's pending touch is a slot index: 0
and 1 are before the date, 2 is the hand-back (for a conversation loop, the rest
after its last slot, which expires on arrival), 3 is the answer day after the
hand-back, whose end expires the loop; a plan stands in for the pending slot
(`planned`). An `after` loop's phase is read off its touches and state, as
`Lifecycle.phase/1` reads it. A touch has "arrived" or not, and `hold` says it
is on a later local day, as every touch after a raise, a silence, a later or a
failed run is. The rung 1 window is one boolean on a due row
(`rung1_until > now`), and `untilSet` is the column (`rung1_until IS NOT
NULL`). An `after` touch lapses `LapseDays` midnights after it came due (14 days
in the code, measured from `next_touch_at`). The daily budget is what the claim
reads: the row's `last_rung2_at` is today (`rung2Today`, which `Spend` sets and
`NewDay` resets), the column `budget_spent_since/3` reads. With
`SpendBeforeSend` off it is the budget before the fix: the loop's last touch was
a rung 2 touch today (`lastRung = 2 /\ touchedToday`).

**Bounds.** Two check-in child slots (`CheckInSupervisor`'s `max_children`), one
crash, two midnights to the date, two midnights to an `after` touch's lapse.
Every check runs in under ten seconds.

**Environment switches** (set per check):

| Switch | When `TRUE` |
|---|---|
| `Classes` | The timings a behaviour may start with (`{"dated", "after"}`). |
| `Reaches` | The reaches a loop may be recorded with (`{"message", "conversation"}`). |
| `OwnerCanAnswer` | The owner answers: done, stop, drop, a plan, not yet, a moved date. |
| `OwnerAnswersDuringRun` | The answer can land while a check-in run is alive. |
| `PlanCanBeToday` | A time the owner names (a plan, an `after` loop's new `ask_after`, at least three hours on) is later the same local day. |
| `OwnerChangesReach` | The owner says how they want the loop raised from now on. |
| `RaiseInConversation` | An owner-private turn arrives inside the rung 1 window, and the main agent raises the loop and records it. |
| `RaiseUnprompted` | The main agent records a raise on a loop the due note did not name (`asked` on an open row). |
| `SendCanFail` | The platform refuses the send; nothing is shown. |
| `AnswerCanBeLost` | The platform shows the message and the run sees a failure (a timeout after the platform accepted). |
| `DaemonCanCrash` | The daemon dies with a run alive, and boots again. |

**Mechanism switches** (`TRUE` is the code; each is switched off by at least one
check):

| Switch | The code | Off |
|---|---|---|
| `SingleClaimant` | The claim's `WHERE state = 'due' AND claimed_at IS NULL` (`open_loops_sql.ex:876-889`) and the scheduler's skip of an owner with a run in flight (`scheduler.ex:261-267`). Redundant layers; one switch turns off both. | Two runs hold the loop. |
| `FinalizeIsCAS` | The finalising write's `WHERE id = ? AND state = 'due' AND claimed_at = ?` (`open_loops_sql.ex:792-804`). | The run writes whatever the row became. |
| `ChecksBeforeSend` | `CheckIn.still_claimed/1` before the send, and the budget spend's `WHERE id = ? AND state = 'due' AND claimed_at = ?` (`open_loops_sql.ex:818-834`). Redundant layers; one switch turns off both. | The run sends without re-reading, and the spend writes whatever the row became. |
| `WhereLiveGuard` | Every settle's `WHERE state IN ('open','due','asked')` (`open_loops_sql.ex:769-779`). | A settle reaches a closed or expired row. |
| `SettleClearsClaim` | `claimed_at = NULL` in every settle and finalize (`write_settle/5`, `:859-873`), backed by the `CHECK (claimed_at IS NULL OR state = 'due')`. | A settle leaves the claim. |
| `BudgetRead` | The claim reads `budget_spent_since/3` (`:1160-1173`) through `Scheduler.budget_for/2` (`scheduler.ex:310-325`). | No budget. |
| `SpendBeforeSend` | The run spends the owner's day before its one send (`CheckIn.spend_then_deliver/3`; `Repo.spend_open_loop_budget/5`, `open_loops_sql.ex:818-834`), stamping `last_rung2_at`, the one column the budget reads and no touch writes. The same transaction refuses the stamp (`budget_spent`) when any row of the owner's already carries one since the local day began; with one loop modelled that branch is never taken. | The budget is the loop's last recorded touch, as before the fix. |
| `TouchCap` | A dated table ends at the hand-back, whose touch arms the answer day (`Lifecycle.after_touch/4`, `following_touch/4`, `Defaults.slots/1`); the spent phase counts touches against the table (`Lifecycle.phase/1`); `asked` is refused at three; the `CHECK touches BETWEEN 0 AND 3`. One switch for all. | The hand-back re-arms itself. |
| `AfterCap` | An `after` loop is spent once its two touches are used (`phase/1`, `lifecycle.ex:732-734`; `Defaults.after_max_touches/0`), so a raise is refused, its arrival expires it, and a plan or a new `ask_after` is refused `:touches_spent` (`touch_left/1`, `:457-460`). | A not yet after the second touch arms a third. |
| `AskedNeedsDue` | A raise is recorded only on a due row; on any other `asked` is refused `:not_due` (`asked/3`, `lifecycle.ex:510-518`). | The main agent records a raise on an open row before its touch. |
| `NextTouchLaterDay` | The touch after a touch is the first slot on a later local day than the touch (`following_touch/4` → `next_later_day_slot/5`, `lifecycle.ex:318-345`). | A conversation loop raised on its next slot's day, before that slot's time, is armed again that day (OL-3). |
| `SlotGate` | A row becomes due only once its pending touch has arrived: `scan_candidates/3`'s `next_touch_at <= now` (`open_loops_sql.ex:938-952`) and `due_decision/2`'s `:not_yet` for a future one (`lifecycle.ex:175`). | The scan marks a row due early. |
| `ConversationGate` | A loop kept for conversation never gets a check-in (`rung2_eligible?/4`, `lifecycle.ex:285`), has no hand-back (`Defaults.slots/2`, `defaults.ex:236-238`; `arrived/3` expires where the hand-back would be), and its rung 1 window runs slot to slot (`rung1_until/2`, `conversation_close/1`, `:225-243`). | It is treated as a loop raised by message. |
| `WindowCleared` | Every write that moves a row out of due clears `rung1_until`: `normalize_changes/1`'s `window_cleared/1` (`open_loops_sql.ex:573-576`) and the scan's own `rung1_until = NULL` (`apply_decision/4`, `:997-1023`), backed by the `CHECK ((state = 'due') = (rung1_until IS NOT NULL))`. | A raise or settle leaves the window on a row no longer due. |
| `WindowLapses` | A conversation loop's window that closes unraised takes the quiet path into the next slot's window (`become_due/2`, `window_lapsed?/2`, `next_window/1`, `lifecycle.ex:202-223`; `apply_decision/4` `{:lapse, …}`, `open_loops_sql.ex:984-995`). | The window only closes, and the loop sits due until its date. |
| `BootSweep` | `Scheduler.boot_sweep/1` (`scheduler.ex:189-204`). | Nothing runs at boot. |
| `ScanExpires` | The due scan's expiries (`Lifecycle.due_decision/2`, `lifecycle.ex:171-200`). | The scan never expires a loop. |

## What holds

- Check 01, with every fault on, both timings, both reaches, the owner
  changing the reach and moving the date, and the main agent recording raises
  the due note did not invite, 354,242 states:
  - A loop is touched at most three times (M78 §6 Caps: "a fourth cannot
    exist"). This rests on `TouchCap` (check 02).
  - An `after` loop is touched at most twice (M83 §05, D16). This rests on
    `AfterCap` (check 23: a not yet after the second touch arms a third).
  - A closed or expired loop never reopens (M78 §5, §18). This rests on
    `WhereLiveGuard` (check 03: an owner's plan or not yet on a closed row) and
    `FinalizeIsCAS` (check 04: a run that outlived the owner's done writes the
    loop back to asked).
  - No run sends once its claim was released before its outcome step (M78 §18,
    `closed_meanwhile`). This rests on `ChecksBeforeSend` (check 05).
  - Only a due row holds a claim (M78 §18 and the `CHECK`). This rests on
    `SettleClearsClaim` (check 06).
  - No raise is recorded, and no check-in commits its send, before the
    pending touch has arrived: the anchor, a plan's time or a new `ask_after`
    (M83 §09). This rests on `SlotGate` (check 24: the scan marks a loop due
    early) and `AskedNeedsDue` (check 32: the main agent records a raise on an
    open loop).
  - A loop kept for conversation is never claimed for a check-in, never spends
    the day, and is never touched at a hand-back (M83 §09: "rung 2 never starts
    for it, and it has no hand-back"), across reach changes either way. This
    rests on `ConversationGate` (check 25: the loop is claimed like one raised
    by message). A reach change that lands during the one send is witness 17's
    race.
  - `rung1_until` is set exactly while the row is due (M83 §11 and its
    `CHECK`). This rests on `WindowCleared` (check 26).
  - A due conversation loop never spends a local midnight unraisable while its
    touch is still live: a window that closes unraised lapses into the next
    slot's, and the last one closes at the date, where the loop expires (M83
    §11). This rests on `WindowLapses` (check 27: the first window closes, the
    loop sits due and hidden from the due note until its date).
- Checks 10 to 13: the owner receives at most one unprompted check-in a day
  (M78 §6 Caps, D6), across both timings, with plans for later the same day and
  failed sends, through each path that once broke it: a crash between the send
  and its ledger write (10, 11,117 states), an answer landing during the send
  (11, 30,550), a send the platform showed but answered as failed (12, 10,338),
  and a rung 1 raise after the day's rung 2 (13, 8,515). Each rests on
  `SpendBeforeSend` (checks 19 to 22): with the budget read from the last
  recorded touch, each breaks the rule again with OL-1's or OL-2's
  counterexample (14, 18, 17 and 22 states).
- Check 07, 3,088 states, the same rule with the spend switched off: it holds
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
- Check 14: with the owner never answering and every other fault on, a loop of
  either timing and either reach always ends expired or closed and stays there
  (M78 §12, §5), 3,927 states. Weak fairness covers the scheduler's scan, lapse,
  claim and boot, its timers (a window closing, a touch arriving, the next
  active-hours start, the next local day), and each live run's next step. None
  applies to the owner, the main agent's raise, the platform's answer or
  crashes. This rests on `BootSweep` (check 15: a claim stranded by a crash is
  left to a run that no longer exists, and the scan skips claimed rows forever)
  and `ScanExpires` (check 16: an unanswered last touch stays asked forever).

- Check 28: with no time named for later the same day, a loop kept for
  conversation is touched at most once a local day (OL-3, fixed), 99 states.
  This rests on `NextTouchLaterDay` (check 31: OL-3's counterexample).

**Witnesses:**
- 17: the owner settles the loop after the run's spend and before its send, and
  the message still arrives. The re-read and the spend's compare-and-set narrow
  the window to one `ChannelSend` attempt (up to `send_timeout_ms`, 60 s); only a
  send under a lock would close it. `record_spoken/3` logs the case when its
  finalise finds the claim gone; the day stays spent, and no follow-up is
  recorded.
- 18: with no crash, a check-in the platform showed but answered as failed is
  sent again on a later day for the same touch. Only a confirmed send advances
  the ledger (M78 §8 "Honest state"), so the owner can receive more messages for
  a loop than it has touches.
- 29: an `after` loop is touched, the owner names a new time, and the second
  touch lands, so the two-touch bound is not vacuous.
- 30: a dated conversation loop is not raised in its first window, which lapses
  into the next slot's, where it is due and raisable with no touch yet.

**One more of each, run by hand** (six workers, no time limit): every holds check
still holds.

| Check | Normal bound | One more | Result |
|---|---|---|---|
| 01 | 2 runs, 1 crash, 2 midnights to the date and to a lapse: 354,242 states | 2 crashes, 3 midnights to each | holds, 811,631 states |
| 01 | the same | 3 runs | holds, 354,242 states (the third slot is never used) |
| 07 | 3,088 states | 2 crashes, 3 midnights | holds, 4,510 states |
| 07 | the same | 3 runs | holds, 3,088 states |
| 10 | 11,117 states | 2 crashes, 3 midnights | holds, 32,969 states |
| 10 | the same | 3 runs | holds, 11,117 states |
| 11 | 30,550 states | 2 crashes, 3 midnights | holds, 45,236 states |
| 11 | the same | 3 runs | holds, 30,550 states |
| 12 | 10,338 states | 2 crashes, 3 midnights | holds, 15,296 states |
| 12 | the same | 3 runs | holds, 10,338 states |
| 13 | 8,515 states | 2 crashes, 3 midnights | holds, 12,247 states |
| 13 | the same | 3 runs | holds, 8,515 states |
| 14 | 3,927 states | 2 crashes, 3 midnights | holds, 9,782 states |
| 14 | the same | 3 runs | holds, 3,927 states |
| 28 | 99 states | 2 crashes, 3 midnights | holds, 177 states |
| 28 | the same | 3 runs | holds, 99 states |

A third child slot is never used: with `SingleClaimant` the scheduler claims
nothing for an owner whose run is alive, so one slot serves every claim.

## Findings

OL-1 and OL-2 were found by the model checker in M78's build before it was
committed, walked through that code, and fixed by one mechanism inside the same
commit, `d4c723aa`: the run spends the owner's day before its send
(`SpendBeforeSend`). To see a counterexample from before the fix, run
`make -C tla report SPECS=open_loop_lifecycle`, or `tla/bin/check.py
open_loop_lifecycle` and open `tla/out/open_loop_lifecycle/<check>.txt` for
checks 19 to 22. OL-3 was found in M83's working tree and fixed there, before
it was committed; check 31 reproduces it with the fix switched off.

### OL-1: a message without its touch leaves the day's budget unspent
- **Severity:** low. Each path needs a narrow window or a second fault, and the
  extra message is one more check-in, not a stream of them.
- **Status:** fixed by `SpendBeforeSend` in `d4c723aa`, the commit that landed
  the feature; the defect never shipped.
- **Checks:** 10 (a crash), 11 (an answer during the send) and 12 (a lost
  answer) hold; 19, 20 and 21 (`needs SpendBeforeSend`) break with the fix
  switched off. Before the fix checks 10 to 12 were `violated OL-1`.
- **Root cause (before the fix).** A conversation loop's window runs from its
  slot to the next slot's day at the default 09:00 start
  (`conversation_close/1`, `lifecycle.ex:233-243`), so a raise can land on that
  day before the next slot's own time. The raise's `after_touch/4` armed the
  first slot from index `touches + 1` whose time was still ahead
  (`following_touch/4` → `next_future_slot/5`, as they were), with no
  requirement that it fall on a later local day, so it armed that slot later
  the same day. A loop raised by message never meets this: its window is three
  hours from its own slot, days before the next.
- **Counterexample (now check 31; 8 states):**
  1. A medium loop kept for conversation comes due at its first slot, three days
     before the date; its window runs to the day before the date at 09:00.
  2. Midnight: it is now the day before the date.
  3. At 08:00 the owner chats; the main agent raises the loop and records it.
     The next slot, the day before the date at the owner's active-hours start
     (09:00 with the default hours), is still ahead, so it is armed.
  4. At 09:00 the loop comes due again, its window running to the date.
  5. The owner chats again at 09:15 and the loop is raised a second time.
- **A second path, not modelled, closed by the same fix.** After a lapse, the
  next window opens at the default 09:00 start while the slot's own time is the
  owner's derived start. An owner whose hours start later (say 10:00) and who
  was raised at 09:30 had that same slot armed again for 10:00
  (`next_future_slot/5` from index `touches + 1`, which the lapse did not
  advance).
- **The fix.** The touch after any touch arms the first slot on a later local
  day than the touch (`next_later_day_slot/5`), the rule `conversation_close/1`
  already used for the window; with none left, the loop rests. ExUnit:
  "a raise on the next slot's day, before that slot's time, never re-arms it
  (OL-3)" and "after a lapse, a raise before the owner's own start never
  re-arms that slot (OL-3)".

## Not modelled

- **Several loops.** The budget and the owner-busy skip are the owner's across
  loops; OL-2's realistic path needs two. Across loops two layers keep two
  runs from both sending on one day: the scheduler's owner-busy skip, and the
  spend's own refusal of a day any row of the owner's already stamped
  (`budget_spent`, read and written in one transaction on the single writer;
  the run then closes as an `error` and re-arms, and nothing is sent). The
  one-loop model exercises neither. Nor does it weigh loops against each other:
  the claim pass takes dated loops first, nearest date first, then loops waited
  on, oldest anchor first (`weigh_due/3`, `scheduler.ex:235-257`), since a
  deadline loses its value after its date while "how did it go" keeps a day.
- **Classes short and imminent.** Short is two slots of the same table; imminent
  is rung 1 only and expires at its date. A moved date re-derives the class; the
  spec keeps the medium and long table, and a shorter table only reaches the
  spent phase sooner.
- **A raise recorded on a due row after its window closed**, the double-ask
  M78 §11 names. `asked/3` accepts any due row; only the prompt (the due note
  shows a loop only inside its window) keeps it from happening. A raise on a
  row not due is refused (`AskedNeedsDue`, modelled).
- **Where a re-armed touch falls inside a day**, beyond "today" or "a later
  day". A not yet on a row that is not due keeps its pending touch here, while
  the code re-arms the first slot from index `touches` still ahead, which drops
  a pending plan for that slot. An `after` loop's open row whose anchor passed
  long ago (the daemon down) expires at once in the code; here it comes due and
  lapses `LapseDays` later.
- **A provider failure or timeout inside the run.** The same failed-outcome path
  as a failed send (`after_outcome/4`), including a failed read of the recent
  follow-ups, which ends the run as an `error`.
- **`empty`** (no decision): `silent`'s path.
- **The follow-up record** (`open_loop_reactions`): written after the ledger
  (`Reactions.record_sent/4`, `record_asked/4`) in its own table, never read by
  the lifecycle; nor is its `raised_history_tainted` mark, which only decides
  whether a later read shows what Fermix said.
- **A re-note.** The same words in the same timing return the stored loop; in
  the other timing `kind_conflict` (`create/2`, `open_loops_sql.ex:732-746`), so
  one turn never makes two loops of one thing. Single-call rules, in ExUnit.
- **The 20-loop cap, message bounds and wording**, single-call rules in ExUnit
  and the capability eval.
- **A history or telemetry write that errors.** `record_spoken/3` matches `:ok`.
- **Where a loop may be read or changed, and its words' provenance
  (2026-10-27).** The private-turn check (which also gates the follow-up
  record's reply capture and raise text), the `noted_after_outside_content`
  column (migration 49, carried through migration 51's rebuild) and the
  framing of a stamped loop's words, and of the follow-ups' quoted texts, in
  the due note and the check-in decide no transition: no step reads the
  column, and the check-in prompt's wording is outside the model. The owner's
  own words an answer needs after outside content are a refusal before any
  write, the same as a missing `owner_words`.

## Assumptions

- **No run spans midnight.** A run starts inside active hours, which end before
  midnight, and its watchdog ends it within `checkin_watchdog_ms` (120 s). This
  is timing, not a mechanism, so it has no switch: `NewDay` waits for every run
  to end.
- **Folded steps.** `Send` is the request and the platform's answer. `Claim` is
  the pass's reads (the owner-busy check, the hours, the budget) and the claim
  write: one GenServer callback, and only the claim is a write. `Answer`,
  `Moved` and `ReachChange` are each the settle, one Repo call. `ConvLapse` is a
  conversation window's close and the scan's quiet path, since the scheduler's
  timer fires at `rung1_until`. A reach change to conversation on a due row
  whose computed window is already behind now leaves it raisable here; the code
  writes the past window and the next scan (the reconcile tick, within 60 s)
  lapses it into the next one.
- **The due scan's skip lands the hand-back at the default 09:00**, before the
  owner's own hours; the claim still waits for the owner's window, so the spec
  treats the skipped row like any other pending hand-back.
