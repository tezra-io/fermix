# history_submit: a purge from chat against late sittings, across computers

Models computer history once it is split between each computer and the home
(M97 §8.1, §8.5). Each computer records raw events into its own store,
forms a finished sitting from what it has not sent and submits it
(`history.submit`); the home summarizes it and writes the note. The owner
purges a window from chat, on the home, for one computer or for every
computer, while a computer may be away, a sitting may be in flight or being
summarized, and a late event may still be recorded with a stamp inside the
window.

The rule it checks is the one the design names: a purged window never gains a
note, whatever order the purge and a late sitting arrive in.

The steps, each one call of the real code:

- **Record** (`Ingest.ingest/2` → `Spool.insert_events/2` →
  `ComputerHistorySql.insert_unless_purged/3`): a late event may carry any
  stamp; one inside an interval the computer applied is fenced.
- **Read, in two store calls** (`Sittings.step/2`): `Spool.link/1` for the
  mark of the home's intervals this computer applied, then
  `Spool.events_after/3` for the events past its cursor. The sitting carries
  the mark.
- **Arrive** (`Submission.accept/3`): a sitting already noted is answered
  from its note; one reached by an interval above its mark, of its computer or
  of every computer, is refused with those intervals; otherwise it is
  summarized.
- **Write** (`ComputerHistorySql.insert_note/6`): one transaction that checks
  the intervals again and writes the note.
- **Settle** (`Sittings.settle/5`): `summarized` moves the cursor; a refusal's
  intervals are applied (`Spool.apply_intervals/3`), which deletes the raw
  events inside them and raises the mark.
- **Lose**: the link dropped with the request or its answer in flight; the
  sitting is held and formed again.
- **Purge** (`Purge.purge/2` → `ComputerHistorySql.purge_notes/5`): one
  transaction that deletes the notes of that scope reaching the window and
  records the interval.
- **Deliver** (`Delivery.deliver/1` → `MachineService` → `Spool.apply_at/3`):
  a connected computer applies every interval it has not.

Out of scope, each a single call ExUnit covers: the signal gate, the
renderer and the summary itself, the pause from chat (an interval of its own
kind, refused by the same check), the 48-hour expiry, the pruning of old
intervals, the home's own machine (it applies a purge inside the purge's own
command), the roll-up's purge guard, and a computer restarting (its store
survives; a sitting in flight is formed again).

**Environment switches** (set per check):
- `OwnerCanPurge`: the owner purges from chat, at most `MaxPurges` times.
- `ScopedPurges`: a purge may name one computer, not only every one.
- `ComputersGoAway`: a computer's link drops, at most `MaxAway` times, and
  comes back.

**Mechanism switches** (`TRUE` is the real code; each is switched off by the
`needs` check that shows a rule depends on it):
- `WriteRechecks`: `insert_note_in_tx` checks the intervals again inside the
  note's write.
- `ComputerFences`: an interval the computer applied refuses an event stamped
  inside it that arrives later (`insert_unless_purged`).
- `MarkBeforeEvents`: `Sittings.step` reads the mark before the events.
- `PurgeDeletesNotes`: `purge_notes_in_tx` deletes the notes that reach the
  window.
- `MarkSkipsApplied`: the sitting carries the mark, so an interval the
  computer applied is never asked about again (`reaching_intervals/5`'s
  `after_id`). Without it the rule still holds, but a sitting whose events lie
  either side of a window the computer already purged is refused for that
  window forever.
- `RefusalNamesAllPending`: a refusal names every interval of the computer
  above the sitting's mark, oldest first (`Submission.refused_by/4`), not only
  those that reach the sitting. The computer records the highest one it
  applies as its mark, so the mark never steps over one it was not given.

## What holds

- `01`: with a computer going away, late events at any stamp and two purges,
  no note holds an event stamped inside a purged window (one computer).
- `10`: the same with two computers and purges of one of them or of all.
- `06`: every event a computer still holds is noted in the end, under weak
  fairness on the computer's cycle, the home's answer and its delivery.

Each has its `needs` checks: `02` (the write's recheck), `03` (the
computer's fence), `04` (the mark read first), `05` (the purge's own delete),
`12` (the refusal names every pending interval) and `11` (the recheck, with
two computers) for the safety rule, and `07` (the mark) for the liveness one. `08` and `09`
are witnesses: a late sitting refused for a purge, and a note made from
events either side of a purged window.

## Findings

### HS-1: a refusal that named only the intervals reaching the sitting let the mark step over a pending purge (fixed)

Found by this spec before the code was committed. Two purges of one computer
are pending, `p1` over a later window and `p2` over an earlier one. A sitting
holding only an event in `p2`'s window is refused, naming `p2` alone; the
computer applies it and records `p2`'s id as its mark, which is above `p1`'s.
Its next sitting holds an event inside `p1`'s window and carries that mark,
so the home no longer asks about `p1`, and the note is written: a purged
window gained a note. Fixed in the same change: a refusal names every interval
of the computer above the sitting's mark, oldest first, so the mark is always
a true prefix (`Submission.refused_by/4`); check `12` shows the rule depends
on it.
