# history_submit: a purge from chat against late sittings, across computers

Models computer history once it is split between each computer and the home
(M97 §8.1, §8.5). Each computer records raw events into its own store,
forms a finished sitting from what it has not sent and submits it
(`history.submit`); the home summarizes it and writes the note. A Mac that is
its own home records too and sends its sittings the same way, in process
(`Controller.home_uplink/1`). The owner purges a window from chat, on the
home, for one computer or for every computer, while a computer may be away,
a sitting may be in flight or being summarized, and a late event may still
be recorded with a stamp inside the window.

The rule it checks is the one the design names: a purged window never gains a
note, whatever order the purge and a late sitting arrive in.

The steps, each one call of the real code:

- **Record** (`Ingest.ingest/2` → `Spool.insert_events/2` →
  `ComputerHistorySql.insert_unless_purged/3`): a late event may carry any
  stamp; one inside an interval the store's fence holds is refused.
- **Read, in two store calls** (`Sittings.step/2`): `Spool.link/1` for the
  mark of the home's intervals this computer applied, then
  `Spool.events_after/3` for the events past its cursor. The sitting carries
  the mark.
- **Arrive** (`Submission.accept/3`): a sitting already noted is answered
  from its note; one reached by an interval above its mark, of its computer or
  of every computer, is refused with every interval of that computer above
  its mark, oldest first (`refused_by/4`, `intervals_after/4`); otherwise it
  is summarized. These are three Repo calls folded into one step: a purge
  between them only adds an interval to what the refusal names, which is
  still every one above the mark.
- **Write** (`ComputerHistorySql.insert_note/6`): one transaction that checks
  the intervals again and writes the note. A refused write names, as above,
  what `refused_by/4` reads after it.
- **Settle** (`Sittings.settle/5`): `summarized` moves the cursor; a refusal's
  intervals are applied (`Spool.apply_intervals/3`): each one's
  `fence_window/4` deletes the raw events inside and records it in the
  store's fence, and the highest id is recorded as the mark last
  (`set_home_mark/2`, which never lowers it). A computer applies every
  interval a refusal names whether or not a delivery brought it, and one a
  delivery already applied is applied again, harmlessly. The fences and the
  mark are separate calls of the cycle's own process, folded into one step:
  only a Record can fall between them, and it meets the fence already
  written.
- **Lose**: the link dropped with the request or its answer in flight; the
  sitting is held and formed again (`{:held, "unanswered"}`).
- **Purge** (`Purge.purge/2` → `ComputerHistorySql.purge_notes/5`): one
  transaction that deletes the notes of that scope reaching the window and
  records the interval.
- **Apply here** (`Purge.fence_here/4`; `History.pause_here/3` for a pause):
  on the home's own machine, the purge command then applies its own interval
  alone (`Spool.apply_intervals([interval])`), and `mark_applied` records its
  id as the mark. No delivery reaches the home's own machine.
- **Deliver, in two steps** (`Delivery.deliver/1` → `MachineService` →
  `Spool.apply_at/3`): a connected computer is sent every interval it has not
  applied and applies them in a process of its own, beside its sending
  cycle: every interval's fence first, the mark last. Delivery runs right
  after a purge or pause from chat and on the home scheduler's 5-minute tick
  (the home's scheduler always runs, `Controller.default_children/2`); a
  computer that is away is skipped and gets them at the first tick after it
  is back, and until then the home refuses its sittings that reach them.

Out of scope, each a single call ExUnit covers or a step that only writes
less:
- the signal gate, the renderer and the summary itself;
- the pause from chat (`pause_window/5`): an interval of its own kind,
  always for every machine, refused by the same check and applied the same
  way, its fence included, and on each machine it also stores the horizon
  that stops recording. It deletes no note: a note made before the pause from
  events stamped inside its window (possible only with a computer's clock
  ahead of the home's) is kept;
- the 48-hour expiry and the pruning of intervals, and the roll-up's purge
  guard;
- a computer restarting: its store survives, and a sitting in flight is
  formed again;
- the home restarting, or the computer's uplink giving up after its deadline
  (185 s) and sending a cancel, while the home summarizes: no note is written,
  the computer holds the sitting and sends it again on a later cycle with the
  mark it then reads. If the home's run finishes after the computer gave up,
  its write still checks the intervals above the mark that sitting carried,
  so a late write is as safe as an early one, and one sent twice makes one
  note (`noted/3`);
- the home's record of what each computer applied (`delivered_mark`), from
  which a delivery reads what to send: it is at most the computer's own mark,
  so the delivery sends the same pending intervals plus some already applied
  (one exception under Seen while reading);
- a computer whose master switch is off: `history.apply` is refused there and
  its sittings are not sent (`HistoryUplink.submit/2`), so it neither gains a
  note nor applies the purge until the switch is back on.

**Environment switches** (set per check):
- `OwnerCanPurge`: the owner purges from chat, at most `MaxPurges` times.
- `ScopedPurges`: a purge may name one computer, not only every one. Chat
  purges every machine today (`History.run_purge/2`); `Purge.purge/2` takes a
  `:computer` that no caller passes yet.
- `ComputersGoAway`: a computer's link drops, at most `MaxAway` times, and
  comes back. The home's own machine never goes away.
- `HomeMachine`: which of `Computers` is the home's own machine (a Mac that is
  its own home), or a value outside them for a home that records nothing
  itself.

**Mechanism switches** (`TRUE` is the real code; each is switched off by the
`needs` check that shows a rule depends on it):
- `WriteRechecks`: `insert_note_in_tx` checks the intervals again inside the
  note's write.
- `ComputerFences`: an interval the store's fence holds refuses an event
  stamped inside it that arrives later (`insert_unless_purged`).
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
- `MarkAfterFences`: `Spool.apply_intervals/3` fences every interval before it
  writes the mark (`mark_applied/3`). Mark first, a sitting formed beside a
  delivery reads the new mark and an event the fence has not yet deleted.

## What holds

- `01`: with a computer going away, late events at any stamp and two purges,
  no note holds an event stamped inside a purged window (one computer).
- `10`: the same with two computers and purges of one of them or of all
  (under symmetry of the two computers).
- `06`: every event a computer still holds is noted in the end, under weak
  fairness on the computer's cycle, the home's answer, its delivery and the
  computer's apply of it.

Each has its `needs` checks: `02` (the write's recheck), `03` (the
computer's fence), `04` (the mark read first), `05` (the purge's own delete),
`12` (the refusal names every pending interval), `13` (the mark written after
the fences) and `11` (the recheck, with two computers) for the safety rule,
and `07` (the mark) for the liveness one. `08` and `09` are witnesses: a late
sitting refused for a purge, and a note made from events either side of a
purged window.

None of these has the home's own machine record (`HomeMachine` is outside
`Computers`): with it, the rule breaks (HS-2, check `14`).

## Findings

### HS-1: a refusal that named only the intervals reaching the sitting let the mark step over a pending purge (fixed)

Found by this spec before the code was committed. Two purges of one computer
are pending, `p1` over a later window and `p2` over an earlier one. A sitting
holding only an event in `p2`'s window is refused, naming `p2` alone; the
computer applies it and records `p2`'s id as its mark, which is above `p1`'s.
Its next sitting holds an event inside `p1`'s window and carries that mark,
so the home no longer asks about `p1`, and the note is written: a purged
window gained a note. Fixed in the same change (`826ba83a`): a refusal names
every interval of the computer above the sitting's mark, oldest first, so the
mark is always a true prefix (`Submission.refused_by/4`); check `12` shows the
rule depends on it.

### HS-2: the home's own machine applies a purge alone, and its mark can step over one it never applied (open)

Check `14`, 9 states, on a Mac that is its own home. Walked through the code
at `826ba83a`:

1. The recorder stores an event stamped `1` in this machine's store
   (`Ingest.ingest/2` → `Spool.insert_events/2`).
2. `/history purge` (command A) runs `Purge.purge/2`: `purge_notes/5`
   records interval 1 over `[1, 1]` for every machine. Its `fence_here/4` has
   not run yet: a second command runs beside it, or it failed after the
   transaction (a `Spool` call that errors or times out: the owner is told
   the purge failed, or gets no answer, while the interval stands on the
   home).
3. `/history purge` (command B) records interval 2 over `[2, 2]`.
4. Command B's `fence_here/4` applies interval 2 alone
   (`Spool.apply_intervals([interval])`), and `mark_applied/3` records the
   home mark 2. Interval 1 is not in this store's fence, and the event
   stamped `1` is still there.
5. The home's sending cycle (`Sittings.step/2`) reads the mark 2, then the
   event stamped `1`.
6. `Controller.home_uplink/1` → `Submission.accept/3` with mark 2:
   `reaching_intervals/5` asks only about intervals above 2, so interval 1 is
   not asked about, and the sitting is summarized.
7. `insert_note/6` checks again above mark 2 and writes the note: a purged
   window gained a note.

It is HS-1's shape on the home's own machine: the mark is recorded from an
interval that is not the next one this machine has not applied.
`History.pause_here/3` does the same with a pause, which then no longer
refuses this machine's sittings inside a window that may still be running.
The computers are not affected: what a refusal names and what a delivery
sends both start at or below the next interval they have not applied.

A fix keeps the home's machine's mark a true prefix, for example by having
`fence_here/4` and `pause_here/3` apply every interval of this machine above
its mark (as `refused_by/4` names them), not their own one alone. Check `14`
then holds, and a `needs` check for that mechanism goes with it.

## Seen while reading, not modelled

- **A delivery to a machine with no store answers a mark it did not
  record.** `Spool.apply_at/3` answers `:ok` when this machine has no store
  file, `MachineService.run/4` answers the highest id, and the home records it
  as delivered. A machine that later opens a store starts at mark 0 while the
  home's record is ahead, so the next delivery sends only intervals above
  that record and the machine records their highest id: HS-1's shape through
  delivery, and a pause still running among the skipped ones would no longer
  refuse its sittings. Today only a machine with no recorder (Linux) has no
  store, and it records nothing, so this is latent until a Linux recorder.
- **A failed purge or pause from chat is half done.** `purge_notes/5` (notes
  deleted, interval recorded) and `pause_window/5` commit before this
  machine's own apply. When that apply fails, the reply says the purge
  failed, or that capture is not paused, but the interval stands: the home
  refuses sittings inside it and the scheduler's next tick delivers it to
  every computer, which deletes and, for a pause, pauses.
- **The store has a second writer.** `Spool`'s documentation calls it the
  single writer of `device/history.db`, but `MachineService` applies a
  delivery through `Spool.apply_at/3` on a connection of its own. Each call is
  still one `BEGIN IMMEDIATE` transaction, which SQLite serializes with the
  `Spool` process's, so every step above stays atomic; a write that waits
  past the 5 s `busy_timeout` fails with an error rather than interleaving.
