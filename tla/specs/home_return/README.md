# home_return: moving a home back to the computer it left

Models Always On's move back (`ALWAYS_ON_MOVE_BACK.md`, draft 2, sections 1,
3, 7 and 8, as built). The home comes back from the server it moved to, to
the computer it left, which receives it in its own device engine. "Mac" is
that computer, whatever its OS. Three copies of the home take part:
- **The Mac's retired copy**: its home, configured as a device, carrying the
  moved marker (`moved.json`) and the desktop link (`device/desktop.json`).
- **The server's home**, the primary, on the Linux server the owner set up.
  It moves with `keep_as_desktop: false` (`FermixChannels.Home.MoveWorker`):
  it retires by its own marker, or undoes the move before writing it.
- **The Mac's staging** (`candidate/staging`): the server's copy restored for
  this computer. The activation puts it in place of the retired copy, in the
  same home (`Activation.activate/2`, steps a to g of the design's 3.2, one
  durable write per step).

The parts:
- **The server's worker**, as `home_move` models it: attempts and their cap,
  `move_ready`, the marker before `move_commit`, the resume loop, the undo
  before the marker, and the endings its boots record.
- **The Mac's receiver**: the candidate process under the device tree
  (`FermixChannels.Home.Candidate`, `DeviceSupervisor`), its staging, and the
  activation. The process runs the activation on `move_commit`, or at its
  start in `activating`; Restore here's job runs it for a local copy
  (`Home.LocalReturn`).
- **The Mac's acts**, through `home.act` (`Management.AlwaysOn`), one at a
  time:
  - Move back: a return candidate, then `return.json`.
  - Move now: `move_started_at` written ahead, then `home.move.start`
    forwarded over the link.
  - Cancel.
  - Restore here, when no server answers: its request in `return.json`, then
    the local copy staged and activated in the `home_restore` job, whose
    ending takes the request back.

  Each act reads the summary (`HomeSummary`) first and runs only what it
  offers (the key rule). Its steps after that read are steps of their own, so
  the candidate and the server can move in between, as they can in the code.
- **The owner**, who deletes or stops the server outside Fermix where the
  Mac's screen offers Restore here, as its confirm asks. Fermix deletes no
  server.

The spec was first written from the design, ahead of the acts. Its finding
HR-1 changed the design before the acts were built: Move now writes the start
ahead. It now mirrors the built acts. Its findings against them, HR-2 and
HR-3, are fixed (352ae545). Restore here then ran a delete of its own before
its restore; since 63207f61 it deletes nothing, and HR-3's rule rests on its
request standing beside its job.

**Who serves as the primary**:
- **The server**: it runs (the owner did not delete or stop it), and its
  engine booted as the primary, or its next boot will (config primary, no
  marker: `Role.resolve/2`).
- **The Mac**: its engine booted as the primary, or, from its commit point on,
  its `config.toml` says primary with no marker. The commit point is step f,
  the rename of the staged `config.toml`.

The Mac's two copies share one engine and one `config.toml`, so "at most one
primary over the three copies" is two rules here:
- `AtMostOnePrimary`, over the two engines;
- `RetiredCopyNeverServes`, over what the Mac's primary serves.

## Switches

| Switch | Kind | `TRUE` means |
|---|---|---|
| `MessagesCanBeLost` | environment | A rail loses a request or an answer. An answer comes after the worker stopped waiting. Or the forwarded `home.move.start`'s answer is lost (`unconfirmed`), before or after the server had it. At most `MaxLosses` in all |
| `ServerCanCrash`, `MacCanCrash` | environment | The engine dies and boots again from its files (at most `MaxCrashes` each) |
| `TransferCanFail` | environment | A staging fails: the rail's (a keychain that refuses, a restore that fails: `restored/2`'s error clause) or a local copy's (`LocalReturn`'s `failed`). Or the server's ready epoch or marker cannot be written (`commit/4` aborts) |
| `JobCanStop` | environment | Restore here's job is stopped from outside, past its budget or cancelled: its run runs nothing after the stop |
| `NetCanFail` | environment | The network between the Mac and its server fails for good. The link and every rail end; a server that runs runs on |
| `MaxPresses` | bound | The owner's presses on the Mac's Always On screen |
| `MarkerBeforeCommit` | mechanism | The server writes its `moved.json` and records `committing` before it sends `move_commit` (`commit/4`, `retired/4`) |
| `MarkerBeforeConfig` | mechanism | The activation removes the Mac's `moved.json` (step e) before it renames the staged `config.toml` into place (step f) (`activate/3`) |
| `RecordEntries` | mechanism | The staged entries are recorded once, in `candidate/entries.json`, before any rename, and every run reads them back (`record_entries/1`). `FALSE` lists the staging again at each run, as the forward `activate/1` does |
| `PruneRetired` | mechanism | Step a sets aside every path of the retired copy that no recorded entry names and this machine does not keep (`prune_retired/3`) |
| `OwnerDeletesFirst` | mechanism | The owner confirms Restore here only once the server is deleted or stopped, as its confirm asks (`Copy`'s `confirm_restore_here`). `FALSE` confirms with the server still running |
| `UnconfirmedKept` | mechanism | Move now keeps `move_started_at` for an `unconfirmed` answer too (`return_answered/3`). `FALSE` keeps it only on `{ok, move_id}` |
| `StartKeptFirst` | mechanism | Move now writes `move_started_at` before it forwards `home.move.start` (`return_start_ahead/2`), and the answer settles it. `FALSE` is the design's draft 2, which wrote it after the answer (HR-1) |
| `StoppedReturnClears` | mechanism | A move back that a stop left part-way can be cleared. This switch stands for two changes, either of which alone closes the path (checked by hand): Cancel removes `return.json` before `candidate/` (`forget_return/1`), and a started record left alone, whose server answers with no move, offers Cancel (`returning/1` with `server_idle?/1`, `return_stopped/2`; `cancel/2`'s `returning?/1`). `FALSE` is neither change (HR-2) |
| `UndoneInAnyPhase` | mechanism | A candidate receiving or staged, whose server answers as the primary with no move under way, draws undone, or Cancel when it has no record (`return_view/2`). `FALSE` draws moving whatever the server says (HR-2) |
| `RequestBesideJob` | mechanism | The summary draws Restore here running only while its request in `return.json` stands beside its running job (`restore_running?/1`, `Home`'s `restoring?/2`). `FALSE` takes the request alone, which a stop of the engine leaves behind |
| `EndingSettles` | mechanism | The job's ending settles a `local` candidate a stopped run left, as the next start would (`restore_ended/3`): one receiving is discarded (`Home.Candidate.remove/1`), one activating is finished by a restart. `FALSE` takes back only the request |

Every check sets every switch.

## What holds

Every check runs with every failure on: losses, late answers and lost
forwarded answers; both engines crashing; the stagings and the server's
marker failing; the network failing for good; Restore here's job stopped
from outside; and the owner deleting the server where Restore here is
offered.

**Check 01**: three rules.
- `AtMostOnePrimary`: never both the server and the Mac serve as the
  primary. It rests on two mechanisms:
  - `MarkerBeforeCommit` (check 02, a 31-state counterexample). The server
    sends `move_commit` before its marker, and the Mac activates through f.
    The marker write then fails, so the server aborts and undoes the move and
    writes role primary.
  - `OwnerDeletesFirst` (check 03, 15 states). With the network down,
    Restore here is confirmed while the server still runs, and the Mac's
    `config.toml` says primary beside a server that serves.
- `NoRefusedBoot`: the Mac's `config.toml` never says primary beside its
  marker. It rests on `MarkerBeforeConfig` (check 04, 15 states): with f
  before e, the state between them is one whose boot `Role.resolve/2`
  refuses.
- `RetiredCopyNeverServes`: once the Mac serves as the primary, every path
  that is not this machine's own came from the staging, and none of the
  staging's is missing. A missing `memory.db` would make the primary's repo
  open a fresh one. The rule rests on two mechanisms:
  - `RecordEntries` (check 05, 21 states). A local restore's activation
    places the staged entry, and the engine dies. The next run lists the
    staging, which no longer names the entry, so step a sets the server's
    copy aside, and the primary opens a fresh `memory.db`.
  - `PruneRetired` (check 06, 16 states): without step a, a file the server
    deleted survives into the primary.

**Check 10**: `RetiredOnlyForStagedReturn`. Once the server wrote its marker,
the Mac holds the staged home, is activating it, or serves it. This is
`home_move`'s retire rule, carried to the return: a server that retired for
anything less leaves no primary, and its resume loop never ends. It rests on
two mechanisms:
- `UnconfirmedKept` (check 11, 23 states). With an `unconfirmed` answer
  taken as "not started", the record goes again, so Cancel is offered while
  the server moves. The path from there is HR-1's.
- `StartKeptFirst` (check 12, 22 states): HR-1's path, with the start written
  after the answer.

**Check 19**: `UndoneReturnCanEnd`, a proposed rule (HR-2). While the
server answers as the primary with no move under way, and nothing runs on
the Mac, the Mac's screen offers a step. It rests on two mechanisms:
- `StoppedReturnClears` (check 22, 13 states): HR-2's first path.
- `UndoneInAnyPhase` (check 23, 22 states): HR-2's second path.

**Check 20**: `GoneServerCanBeRestored`, a proposed rule (HR-3). A Mac whose
server is gone, and which serves nothing itself, is offered Restore here
once nothing runs. It rests on two mechanisms:
- `RequestBesideJob` (check 24, 6 states): the network fails, the owner
  deletes the server, Restore here keeps its request, and the Mac's engine
  stops before its job writes anything else. Taken alone, the request it
  leaves draws moving with nothing to press.
- `EndingSettles` (check 25, 9 states): the same, but the job is stopped
  from outside once its `local` candidate is written. The ending takes the
  request back, and the candidate left receiving draws moving with nothing
  to press until the next start.

**Witnesses**:
- **13**: the round trip. The server retires, and the Mac boots as the
  primary with `moved_at`.
- **14**: during the return from the server, the Mac's engine dies between
  steps e and f. It boots as a device, whose candidate finishes the
  activation and restarts.
- **15**: the server undoes the return before its marker (the Mac's staging
  failed and refused) and boots as the primary again.
- **16**: a `move_done` is lost (the Mac restarted with it on the rail), and
  the return completes on the Mac. The server resumes, and finds no candidate
  to answer.
- **17**: no server answers. The owner deletes it, and the Mac restarts from
  its copy.

## Findings

### HR-1: a Mac that lost the record of the move's start offered Cancel while the server moved, and a Cancel that landed mid-move left no primary

**Fixed** in a34f05bc (`aos/moveback-flow`), before the acts were first
committed. Check 12 keeps the path: it is what breaks the rule without
`StartKeptFirst`.

The design's draft 2 wrote `move_started_at` after the server answered
`home.move.start`, and keyed Cancel on that record. The server restarts into
the move as it answers. So when the Mac did not write the record, its screen
showed ready, with Cancel, for as long as the server moved. Two ways led
there:
- the Mac's engine died between the answer and the write;
- an `unconfirmed` answer was not counted as started.

The path (check 12, 22 states):
1. Move back. The candidate enrols.
2. Move now. The server takes `home.move.start`, records the move, restarts
   into it, and answers.
3. The Mac's engine dies before `return.json` gains `move_started_at`, and
   boots again as a device. Its candidate is still enrolled.
4. The server's worker sends `move_offer`.
5. The owner presses Cancel. The summary is ready, so the key check passes.
6. Before Cancel's next step, the candidate takes the offer, the stream and
   the restore stage the home, and the server retires.
7. Cancel stops the candidate and removes `candidate/`. The server is
   retired, and nothing holds its home.

The same lost record also gave a wedge, found against check 01: Cancel
killed the candidate's restart in the second after g.

**The fix, as built**:
- **Write ahead.** `return_start_ahead/2` writes `move_started_at` before the
  request leaves.
- **The answer settles it** (`return_answered/3`). A move id keeps it, and so
  does `unconfirmed` (`UnconfirmedKept`). Any other answer (the link down, a
  refusal) takes it back.
- **A new summary row.** A start recorded while the server answers as the
  primary with no move under way draws ready again (`server_idle?/1`).

### HR-2: after the server undid a return, or never started it, the Mac could be left showing moving with nothing to press

**Fixed** in 352ae545. Checks 22 and 23 keep the two paths. Check 19 holds.

The rule is a proposed one: `UndoneReturnCanEnd`. While the server answers
as the primary with no move under way (it undid the move, or never had it)
and nothing runs on the Mac, the Mac's screen offers a step. The code at
69fb0c1a broke it in two independent ways.

**1. Cancel removed `candidate/` before `return.json`.** A stop between the
two left a record with `move_started_at` alone, which `returning/1` drew as
moving with no action, for good. The path (check 22, 13 states):
1. Move back. The candidate enrols.
2. Move now: the start is written ahead, and the request is lost before the
   server has it (`unconfirmed`, kept).
3. The server answers as the primary with no move, so the screen is ready
   again with Cancel.
4. Cancel stops the candidate and removes `candidate/`.
5. The Mac's engine dies before `return.json` goes. It boots to a started
   record with no candidate, drawn as moving.

**2. Receiving and staged were drawn moving whatever the server said.** The
server can undo a return after its candidate took an offer: the marker write
fails, three streams fail, or three restores outlive the 30-minute wait.
The candidate then stayed receiving or staged:
- its screen stayed moving, with nothing to press;
- `MoveAwake` held the Mac awake.

The path (check 23, 22 states): Move back, Move now, offer, stream, staged,
`move_ready`, the marker write fails, abort, undo, restart.

**The fix, as built**:
- **`StoppedReturnClears`**, two changes:
  - `forget_return/1` removes `return.json` first.
  - `returning/1` gives a started record with no candidate, whose server
    answers with no move, Cancel (`return_stopped/2`). `cancel/2` routes
    such a record to `cancel_return/1` (`returning?/1`).

  Either change alone closes the first path.
- **`UndoneInAnyPhase`.** `return_view/2` draws a receiving or staged
  candidate as undone (Try again, Cancel) when the server answers with no
  move, or `return_stopped/2` with Cancel when there is no record.

Both are safe:
- A server that answers as the primary holds no marker, so it never retires
  for that move.
- Try again's later move id is one the candidate's offer fence takes.

A started record with no candidate, whose server does not answer, still
draws moving (D14). With the fix, only a candidate removed by hand reaches
that, and the model reaches it only in the second before the candidate's
restart, which ends at the Mac's boot as the primary.

### HR-3: a stop inside Restore here left no primary and no Restore here

**Fixed** in 352ae545, for the delete Restore here then ran before its
restore. Restore here deletes nothing since 63207f61, and check 24 keeps the
path the rule rests on now. Check 20 holds.

The rule is a proposed one: `GoneServerCanBeRestored`. A Mac whose server is
gone, and which serves nothing itself, is offered Restore here once nothing
runs.

At 69fb0c1a, Restore here's delete and the record that it was done were two
writes, and the offer read the record. After a stop between them:
- the screen was `cannot_reach`, with Learn more;
- nothing served the home;
- Always On could not restore it.

**As built now** (`RequestBesideJob`): Restore here keeps its request in
`return.json` and starts the `home_restore` job, whose ending takes the
request back however the run ended. The summary draws the restore running
only while that request stands beside the running job
(`restore_running?/1`, `Home`'s `restoring?/2`). A request a stop of the
engine leaves behind draws nothing, so Restore here is offered again.

## Model and code

Walked step by step against 69fb0c1a. Where the code differs from what the
first version modelled from the design, and whether it matters:
- **`returning/1`.** `return.json` alone with no start (a stop between Move
  back's writes) is not returning: it draws `on` or the away screens, not
  Cancel. A started record with no candidate draws moving. Receiving and
  staged draw moving whatever the server says. That was HR-2, since fixed;
  modelled.
- **A local staging can fail.** It records `failed` and ends the job, and
  `prepare_return/3` replaces that candidate. Modelled.
- **Move now's write-ahead and settlement**, and **Cancel's stop, withdraw
  and two removals**, are as the spec proposed. Unchanged.
- **The key's derivation** happens at the press. It matters to no rule (one
  staging step here).
- **Move back's server check and forward** fold into the press, as before.

Walked again against e115c598, the fixes:
- **HR-2:** `forget_return/1`'s order; `cancel/2` with `returning?/1`;
  `returning/1` with `server_idle?/1`; `return_stopped/2`; and `return_view/2`
  for receiving and staged.
- **HR-3:** `restore_offer/1` with `silent?/1`.

Each is modelled as built. Walking them found nothing new.

Walked again against 63207f61, Restore here with no delete:
- `restore_here/3` keeps the request (`restore_record/3`) and starts the
  job (`start_restore/3`), whose ending takes it back (`request_done/1`),
  as a start refused busy does;
- `restoring/1` and `restore_running?/1` draw it running only beside the
  running job, which `Home`'s `restoring?/2` reads from the job family;
- `restore_offer/1` needs a copy and a silent server, nothing more;
- the owner deletes or stops the server outside Fermix, where Restore
  here's confirm asks for it (`OwnerDeletes`).

Walked again after the review of the cut:
- `silent?/1` is silent only where nothing answers (no link, or no session
  for ten minutes). A server that answers as one that is not the primary
  (`revoked`, `stale`) is not silent. `RestoreOffer` follows it
  (`ServerSilent`): here a server that runs answers unless the network
  failed.
- `restore_record/3` starts a record of its own over a move back that
  ended. Here the home moves away once only, so it never meets one.
- `restore_ended/3`: the job's ending settles what a stopped run left
  (`RhStopped`, `RhSettle`, `EndingSettles`).

Each is modelled as built. Walking them found nothing new.

Each is modelled as built. Walking them found nothing new.

Walked again against db21a29d (M97: the computer's key and switches):
- **Step c** (`end_tenure/2`) deletes the ended tenure's key from the secret
  store its link records (with any file an older Fermix kept it in), then
  removes the link, so a stop between the two deletes the key again. The key
  is a write no rule reads, so `CTenure` stays one step. A link it cannot
  read, or a store that will not delete, now fails the step where two file
  removals did before, and the activation tries again, as the header's
  failed activation does (not modelled).
- **The server's move worker** moves with `keep_as_desktop: false`, so it
  makes no key, no row, no link and no switches; `ensure_offers/1` on its
  resume writes nothing.
- **The `on` screen** offers the review of what a computer that moved before
  M97 keeps on for its server (`review_offers`), beside Back up now, and
  Move now from the computer that sets Always On up records `keep_offers`
  in its request (`local_move/3`). Each is an act that writes nothing a rule
  reads; Move now on a return (`forwarded_move/4`) is as before.

None changes a modelled step. The comments' line numbers into the files
this commit changed had drifted before it too; they now point at the
committed code.

Walked again against 16207ff5 (M97: a second computer, and the server's
lead on versions):
- **Move back and Restore here need the moved marker.** `move_back/1` and
  `restore_offer/1` now offer them only where the home moved from this
  computer (`moved`), so a computer that joined has neither. The model had
  offered Restore here on a Mac with no marker: a Restore here whose engine
  died while activating is finished by the candidate at the next start, and
  between its last step and the restart the engine is still a device with
  no marker, no link and no candidate, beside a request with no job.
  `RestoreOffer` and `DeviceOffers` now read the marker (`mMarker`). The
  press there was refused before any write (`Preparable` reads the marker
  too), so every check has the result it had; the reachable states are
  fewer (check 01: 54613, from 54682).
- **Update in their place.** Where this computer's Fermix cannot read the
  server's home, the summary offers Update where Move back or Restore here
  would stand. Here the Mac reads it (the header says so).
- **The pin** of `home_summary.ex` now names `move_back` and
  `readable_or_update` as well, since `DeviceOffers` reads the first's
  marker and the model takes the second's answer as read.
- **Step c** (`end_tenure/2`) records which key is this home's once, in
  `candidate/tenure.json`, before anything is deleted, deletes the stored
  key only while it still holds that key, then removes the link. A link it
  cannot read no longer fails the step: it is removed, the reason logged,
  and any key it named stays. The record and the key are writes no rule
  reads, and a later run reads the record and still removes the link, so
  `CTenure` stays one step; its comment said an unreadable link fails the
  step, and no longer does. A record that cannot be read or written, a
  store that cannot be read, or one that will not delete, still fails it.
- **The device tree** starts this computer's invocations (`Desktop.Invoke`)
  beside the dial subtree while the home is linked, and a joiner inside the
  dial subtree only while this computer joins a home and has no link. The
  candidate subtree starts and stops as before.
- **The act** gained Add a computer, the owner's answer to a computer that
  asks to join, and Cancel on a computer that is joining: acts that write
  nothing a rule reads. Move back, Move now, Cancel on a return and Restore
  here are as before.
- **The server's move worker** no longer reads its `machine.toml` on a
  resume when it is not kept as a computer, as here.

The comments' line numbers into the files this commit changed point at the
committed code.

Walked again against 18710c89 (M97: history notes named for their
machine), which staled the `move_worker.ex`, `candidate.ex` and
`activation.ex` pins:
- **A return's staging names this computer's notes as the home's own
  again.** `Activation.stage/6` for a return (from `stage_fun/4`, and from
  Restore here's `LocalReturn`) renames the staged copy's rows of the device
  id its desktop link holds back to `""` in one transaction (`own_notes/4`,
  `ComputerHistorySql.rename_machine/3`). A link that is gone renames
  nothing; one that cannot be read, or a rename that fails, fails the
  staging, which the model has under `TransferCanFail` (`RestoreFails`, and
  `RhStage` for Restore here). The link is still in place at every staging:
  step c removes it only during the activation, after the staging. No rule
  reads the notes.
- **The server's move worker** names the source's device id in `move_offer`
  when it is kept as a computer (`send_snapshot/4`), a field no rule reads.
- **The activation** (`activate/2`, steps a to g) is as before.

None changes a modelled step. The comments' line numbers into these three
files point at the committed code; those into the candidate's
`candidate.ex` had drifted before this change too.

Walked again against c6fe1c48 (the review's fixes), which staled the
`always_on.ex` pin: Try again with no block ticked moves with the keep the
undone move started with (`Move.undone_keep/1`), a field of its request no
rule reads, and Try again is not modelled. Move back, Move now, Cancel and
Restore here are as before. The comments' line numbers into `always_on.ex`
point at the committed code.

Walked again against 1a89beae (HS-4's fix), which staled the
`candidate.ex` pin: a return's staging passes `history: :continued`, so the
server's live store keeps its history token; Restore here, from a stored
copy, gets a new one. No rule reads it, no modelled step changed, and the
comments' line numbers into `candidate.ex` point at the committed code.

Walked again against c4c72e1f (M97 D16, a home's format), which staled
the `candidate.ex` pin. A Mac whose Fermix cannot read the server's home
format refuses it in the staging (`Archive.install/5`'s `not_newer`), a
failed staging the model has (`RestoreFails`): the server's worker aborts
and serves again, since it retires only once the Mac staged. Restore here
refuses a copy in a newer format the same way (`LocalReturn`'s
`failed_sentence/2`, `RhStage`), and the copy stays for a Fermix that reads
it; the summary offers Update where Move back or Restore here would stand
(`readable_or_update`, read as the scene takes it). So no move back leaves
a home that no machine serves. No modelled step changed; the comments' line
numbers into `candidate.ex` point at the committed code.

## Done

Deadlock checking is on. `Done` has these ends:
- **Back on the Mac**: its engine booted as the primary, and the server is
  retired or deleted. The server's worker may still resume, a loop that never
  stops here: with no desktop key it cannot probe the moved identity, and
  its 24-hour bound is not modelled.
- **The server serves**: its worker is off and the Mac waits as a device,
  whatever its candidate holds. Check 19 holds that the Mac's screen offers
  a step there wherever the server answers.
- **The server deleted by the owner, the restore unfinished**, with the
  owner's presses spent. Restore here is offered again (check 20).

## Bounds

The checks run with `MaxLosses = 2`, `MaxCrashes = 1` per engine and
`MaxPresses = 4`. Each takes about one to two seconds. The holds checks
explore 54,682 states.

Every rule of the holds checks was run by hand, together:
- with one more of each (`MaxLosses = 3`, `MaxCrashes = 2`,
  `MaxPresses = 5`): no error, 378,985 states, 7 s;
- with two more (`MaxLosses = 4`, `MaxCrashes = 3`, `MaxPresses = 6`): no
  error, 1,342,200 states, 21 s.

## Not modelled

The `.tla` header lists what is left out, with the reason for each:
- what `home_move` proves on its own: requests on abandoned rails and the
  offer fence, endings said only by the engine that came back, and an ending
  a boot could not write;
- a request the server sent before it crashed is lost here, not delivered
  late: delivered, it is a commit whose answer was lost, which the model has;
- the enrolment window, its expiry and its withdrawal;
- Try again, a second move, and the 24-hour listen window;
- the stream's frames, the capture, the room check (a refusal before any
  byte, which counts as a failed staging), and `MoveAwake`;
- paths this machine keeps at any depth: one staged entry stands for all of
  them, and one path for what only the retired copy has.
  `activation_return_test` holds the kept paths at depth after a stop at
  every step;
- an activation that fails part-way and tries again on a timer: it re-runs
  the same idempotent steps, as a crash and the next start do;
- a primary boot that cannot write `moved_at` (it is retried at each
  `home.status` read);
- a server the owner deletes at another moment than Restore here's confirm,
  or stops and later starts again: the confirm names the two primaries a
  server that still runs makes;
- Restore here's ending that cannot write `return.json` (it logs): the
  request then stands beside no job, as a stop of the engine leaves it;
- a second desktop (the stale epoch, the passed return's drop);
- the copy's choice and a wrong passphrase;
- the key's derivation;
- the Mac's other acts: Back up now, Add a computer and the owner's answer
  to one that asks to join, and the review of what a computer that moved
  before M97 keeps on for its server;
- a computer that joined the home, which carries no moved marker and is
  offered neither Move back nor Restore here, and a Mac whose Fermix cannot
  read the server's home, which is offered Update in their place.

## Outside the model

Read while walking the code. TLC does not show these.

- **Cancel in undone.** Section 9's text said Cancel "is not offered once
  `move_started_at` is set", while its table offers it on undone. The code
  follows the table, and so does the spec. Cancel is safe there, since the
  server undid the move and serves.
