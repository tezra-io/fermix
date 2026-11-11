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
- **Apply here** (`Delivery.apply_here/1`, from `Purge.purge/2`, from the
  pause command's `History.apply_here/2` and from the home scheduler's tick,
  `Scheduler.apply_here/1`): no delivery reaches the home's own machine, so it
  applies what it owes itself: every interval of its own above its mark
  (`intervals_after/4`), oldest first, the fences first and the mark last, in
  two steps like a delivery's (it shares `DeliverSecond`). A command whose
  apply failed, or one beside which a second command ran, is applied by the
  next command or the next tick. Before the fix it applied the command's own
  interval alone (HS-2). In the model one apply here runs at a time; in the
  code two can overlap (two commands, or a command and the tick). That is
  safe whatever order their calls take: each fences every interval above the
  mark it read before it raises the mark to the highest of them, and the
  mark never goes down (`set_home_mark/2`), so the mark only ever names a
  prefix that some apply fenced whole.
- **Deliver, in two steps** (`Delivery.deliver/1` → `MachineService` →
  `Spool.apply_at/3`): a connected computer is sent every interval it has not
  applied and applies them in a process of its own, beside its sending
  cycle: every interval's fence first, the mark last. Delivery runs right
  after a purge or pause from chat and on the home scheduler's 5-minute tick
  (the home's scheduler always runs, `Controller.default_children/2`); a
  computer that is away is skipped and gets them at the first tick after it
  is back, and until then the home refuses its sittings that reach them.
- **The home store's identity** (`ComputerHistory.home_identity/1`: the
  store's own token, migration 61, and the home's epoch). A machine keeps its
  mark with the identity of the store it counts (`computer_history_link.home`).
  Its sitting names it, and the home counts the mark only when it names this
  store, reading it as 0 otherwise (`Submission.mark/2`; `Delivery.mark/2`
  for the home's own machine); every answer and every `history.apply` names
  the store, and `set_home_mark/3` raises the mark under the same store and
  replaces mark and store together under another.
- **Take a backup, Restore**: the owner backs the home up once, at any
  moment (`TakeBackup`: its intervals, its next id and the home's epoch
  then); a restore from it (`Restore`, `Home.Archive.install/5`) puts those
  intervals and that next id back, so the store's ids start again from the
  backup's, holds none of the notes, and sets the epoch to the backup's plus
  one, which makes the identity. A server rebuilt from nothing and another
  home are the same with a token never seen. The machines' own stores are not
  in the backup and keep their marks. The engine restarts, so no sitting is
  being summarized then; one on its way, and an answer or an apply on its
  way back, goes on under the store it was made under.

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
  note nor applies the purge until the switch is back on;
- a machine whose history is off (`/history off` naming a computer and not
  yet done there, a computer whose `history` offer is off, or the home's own
  machine while it does not record): the home refuses its sitting `off`
  before any provider call (`Submission.contributing/3`,
  `ComputerHistory.contributors/1`), and the machine holds it, as after a
  lost answer. That only writes less: no note, no cursor moved and nothing
  to apply, so the safety rule cannot break through it, and it is asked
  after the purge check, so a sitting in a purged window is still refused
  `purged` and brings its machine the intervals. `EverySittingSettles` is
  about machines that contribute; one that is off holds its events until it
  is on again, as with the master switch. Not modelled for that reason. One
  window the check leaves, seen while reading: a sitting that passed it is
  summarized and written even if the owner's off lands during that
  provider call, since the write does not ask again.

**Environment switches** (set per check):
- `OwnerCanPurge`: the owner purges from chat, at most `MaxPurges` times.
- `ScopedPurges`: a purge may name one computer, not only every one. Chat
  purges every machine today (`History.run_purge/2`); `Purge.purge/2` takes a
  `:computer` that no caller passes yet.
- `ComputersGoAway`: a computer's link drops, at most `MaxAway` times, and
  comes back. The home's own machine never goes away.
- `HomeCanRestore`: the owner takes a backup, and the home is restored from
  it at most `MaxRestores` times (0 in every check but 16 to 20).
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
- `HereAppliesPending`: the home's own machine applies every interval of its
  own above its mark (`Delivery.apply_here/1`), not the command's own one
  alone, so its mark never steps over one it has not applied.
- `MarkTiedToHome`: a mark counts only under the home store it names, and is
  replaced, not raised, under another (`Submission.mark/2`,
  `Delivery.mark/2`, `set_home_mark/3`). Off, the code before `c6fe1c48`: a
  mark counts whatever store it was made under.
- `RestoreRenews`: a restore gives the store it installs a new token, so a
  new identity each time (`Archive.install/5`'s `history_identity/4`);
  `FALSE` keeps the backup's token (HS-4).

## What holds

- `01`: with a computer going away, late events at any stamp and two purges,
  no note holds an event stamped inside a purged window (one computer).
- `10`: the same with two computers and purges of one of them or of all
  (under symmetry of the two computers).
- `14`: the same on a Mac that is its own home, with two purges that may run
  at once and an apply here that may come late.
- `06`: every event a computer still holds is noted in the end, under weak
  fairness on the computer's cycle, the home's answer, its delivery and the
  computer's apply of it.

Each has its `needs` checks: `02` (the write's recheck), `03` (the
computer's fence), `04` (the mark read first), `05` (the purge's own delete),
`12` (the refusal names every pending interval), `13` (the mark written after
the fences), `11` (the recheck, with two computers) and `15` (the home's own
machine applies every pending interval, for `14`) for the safety rule,
and `07` (the mark) for the liveness one. `08` and `09` are witnesses: a late
sitting refused for a purge, and a note made from events either side of a
purged window.

Only `14`, `15`, `18` and `19` have the home's own machine record
(`HomeMachine` in `Computers`); the others have it outside `Computers`.

With a backup taken at any moment and one restore from it
(`HomeCanRestore`, one purge before it and one after, two stamps): `16`
holds the safety rule for a computer that goes away and `18` for a Mac that
is its own home, and each needs `MarkTiedToHome` (`17`, 12 states; `19`).
With two restores from that backup it holds too (`20`), because each
restore gives the store a new token, and it needs `RestoreRenews` (`21`, the
counterexample HS-4 found). The
identities start at the first store, so the checks without a restore
explore the states they did before.

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

### HS-2: the home's own machine applies a purge alone, and its mark can step over one it never applied (fixed)

Found by check `14` at `826ba83a` (9 states), on a Mac that is its own home.
Fixed in `18710c89`, which adds `Delivery.apply_here/1`: this machine applies
every interval of its own above its mark, oldest first, before its mark
moves, the rule computers already followed through refusals and deliveries;
every purge and pause command runs it, and so does the home scheduler's tick,
which is how an apply that failed is done. Check `14` now holds, and check
`15` (`HereAppliesPending` off) shows the rule depends on it. The path, as it
was:

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

The fix keeps the home's machine's mark a true prefix, as `refused_by/4`
keeps a computer's.

### HS-3: a mark kept from a home store whose ids started again steps over a new purge (fixed)

Found by the review of M97 and fixed in `c6fe1c48`; check `17` shows it
without `MarkTiedToHome` (12 states), on a computer:
1. The recorder stores an event stamped `1`; the owner backs the home up
   before any interval.
2. A purge records interval 1 over `[2, 2]`; a delivery applies it and the
   computer's mark is 1.
3. The computer's cycle forms a sitting with mark 1 and the event stamped
   `1`.
4. The home is restored from that backup: its next interval id is 1 again.
5. The sitting arrives: nothing above mark 1 reaches it, so it is
   summarized.
6. A purge records a new interval 1, over `[1, 1]`.
7. The write checks again above mark 1 and finds nothing: the note holds an
   event inside the purged window.

The same holds for a server rebuilt from nothing and for a computer that
joins another home: ids start again, and a mark made under the old store
names intervals it never saw. The fix ties the mark to the store's identity:
the sitting names it, the home reads a mark under another store as 0 and
refuses the sitting with every interval it holds, and the computer replaces
its mark and store together. Check `19` shows the same on a Mac that is its
own home, whose store keeps its mark across a restore of its memory.db.

### HS-4: a home restored twice from one backup has the same identity both times, and a mark from the first restore steps over a new purge (fixed)

Fixed in the M97 fix pass (uncommitted at this writing; re-pin with its
commit). The identity is now the store's token alone, and
`Archive.install/5` gives every store it installs from a stored copy a new
one before the epoch is written, under the same roll-back
(`history_identity/4`, `ComputerHistorySql.renew_home_token/1`): a restore
from an archive or a snapshot, Restore here, a server rebuilt from a
snapshot, however often the same copy is restored. A move's or a move
back's live stream (`history: :continued`, `candidate.ex` `stage_fun/4`)
keeps its token, since its ids go on, so a move no longer resets any
computer's mark. Model: `RestoreRenews` in `Restore`; check `20` holds with
it, and `21` is its mechanism check, the counterexample below.

Found in the re-read of `c6fe1c48`. The home store's identity is its token
and its epoch (`ComputerHistory.home_identity/1`). A restore writes the
backup's own epoch plus one (`Home.Archive.install/5` → `next_epoch/1`,
`archive.ex:214`, `:790-792`), and the token is the one in the backup's
memory.db (`computer_history_home`, migration 61). Restoring the same backup
again gives the same identity, while the store's interval ids start again
from the backup's. Check `20` (13 states), on a computer:
1. The recorder stores an event stamped `1`; the owner backs the home up
   (no interval yet, epoch 1).
2. The home is restored from that backup: epoch 2, identity `T.2`.
3. A purge records interval 1 over `[2, 2]`; a delivery applies it, and the
   computer's mark is 1 under `T.2`.
4. The home is restored from the same backup again: epoch 2, identity `T.2`
   again, and its next interval id is 1 again.
5. A purge records a new interval 1, over `[1, 1]`.
6. The computer's sitting (mark 1 under `T.2`, the event stamped `1`)
   arrives: the mark counts, nothing above it reaches the sitting, and the
   note is written: the purged window gained a note.

In the code the computer is still linked after the second restore: its link
refuses only an epoch below the one it saw, and this one is equal. A delivery
would have applied the new interval's fence (the home's delivered mark comes
from the backup), so the note needs the sitting to reach the home first: a
computer that was away during the purge sends its held sitting at once when
it is back, while the home's delivery waits for its scheduler's tick.
Restoring the same backup twice, or a backup whose epoch plus one is an
epoch the home already had under the same token, was enough.

## Seen while reading, not modelled

- **A delivery to a machine with no store answered a mark it did not
  record (fixed with HS-2).** `Spool.apply_at/3` now answers the store's own
  mark, and 0 where there is no store, so the home records nothing as applied
  there (`Delivery` names that computer under `no_store`) and a store it opens
  later is sent every interval from the first.
- **A failed purge or pause from chat was half done (now said so).**
  `purge_notes/5` and `pause_window/5` commit before this machine's own apply,
  in a separate database. Once the home's transaction commits, the interval
  stands and is never taken back (undoing it would leave notes deleted with
  nothing refusing a late sitting); the reply says the home recorded it, that
  this Mac's own apply has not happened yet and why, and that it is tried
  again on every tick of the scheduler. A transaction that does not commit
  changes nothing, and the reply says that.
- **The store has a second writer.** `MachineService` applies a delivery
  through `Spool.apply_at/3` on a connection of its own, beside the `Spool`
  process (whose documentation now says so). Each call is one `BEGIN
  IMMEDIATE` transaction, which SQLite serializes with the `Spool` process's,
  so every step above stays atomic; a write that waits past the 5 s
  `busy_timeout` fails with an error rather than interleaving.

## Re-read for the fix (18710c89, 2026-11-11)

18710c89 committed HS-2's fix and the spec's change for it, and staled the
`submission.ex`, `spool.ex`, `delivery.ex`, `machine_service.ex`,
`purge.ex` and `history.ex` pins; it added the `scheduler.ex` pin. Walked
against the commit:
- **Apply here** is as `ApplyHere` and `DeliverSecond(HomeMachine)` say:
  `Delivery.apply_here/1` reads this machine's mark, then every interval of
  its own above it (at most 256, oldest first), and applies them with
  `Spool.apply_intervals/3`, each fence (and a pause's horizon) first and
  the mark last. `Purge.purge/2`, the pause command's `apply_here/2` (both
  only where this home records, `run_purge/2` and `apply_here/2`'s first
  clause) and the scheduler's tick (`Scheduler.apply_here/1`, from
  `maybe_roll_up/1`, wherever this home keeps a store) call it. The pin of
  `history.ex` now names `run_purge`, which decides whether the purge
  command applies here.
- **A delivery** is as before; `Spool.apply_at/3` answers the store's own
  mark, 0 where there is none, which the home records as delivered.
- **The off refusal** (`Submission.contributing/3`, asked after
  `unrefused/3`) and `history.off` (`MachineService`, `Delivery.switch_off/2`)
  are left out, for the reason under Out of scope.
- Checks: every verdict as the commit left it; `14` holds and `15` needs
  `HereAppliesPending`.

## Re-read for the review's fixes (c6fe1c48, 2026-11-11)

`c6fe1c48` staled the `sittings.ex`, `submission.ex`,
`computer_history_sql.ex`, `spool.ex`, `delivery.ex`, `machine_service.ex`
and `purge.ex` pins:
- **The home store's identity.** Interval ids are not the same for ever: a
  restore, a rebuilt server or another home starts them again, which the
  model had left out. It is modelled now (`TakeBackup`, `Restore`, `ident`,
  `bk`, `MarkTiedToHome`, checks 16 to 20, HS-3 above), since a check can
  show the defect the fix closes, and one it leaves: a restore's identity
  was the backup's token and its epoch plus one, so two restores from one
  backup shared it (HS-4, fixed: each restore now writes a new token). Every read of the mark (`Spool.link/1`) answers
  its store too, so the sitting's mark and store are one read; the home reads
  its identity once per sitting, before its three Repo calls, so a restore
  cannot fall between them (the engine restarts).
- **`expired`.** The home refuses a sitting older than the retention window
  before any other check (`Submission.fresh/2`), and the machine moves past
  it; each cycle first sweeps its expired raw events (`Retention.sweep/3`).
  Both only write less, and the 48 hours are far beyond the model's time.
- **`apply_intervals/4`, `apply_at/4`, `set_home_mark/3`** take the store;
  `forget_home/1` (a join or a leave) sets the mark to 0 under no store,
  which counts as any 0 does. `history.apply` names the store and is refused
  without one.
- **A store that does not open** answers every call `store_unavailable`; no
  step here runs then.
- **The pins** now name `Submission`'s `checked`, `identity` and `mark`, and
  `ComputerHistory.home_identity/1` with its `epoch/1`, which the identity's
  steps encode.

Every earlier check keeps its verdict and its state count.
