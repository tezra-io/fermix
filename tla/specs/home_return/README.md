# home_return: moving a home back to the computer it left

Models Always On's move back (`ALWAYS_ON_MOVE_BACK.md`, draft 2, sections 1,
3, 7 and 8, as built). The home comes back from the server it moved to, to
the computer it left, which receives it in its own device engine. "Mac" is
that computer, whatever its OS. Three copies of the home take part:
- **The Mac's retired copy**: its home, configured as a device, carrying the
  moved marker (`moved.json`) and the desktop link (`device/desktop.json`).
- **The server's home**, the primary. It moves as a replace's source does
  (`FermixChannels.Home.MoveWorker`, `keep_as_desktop: false`): it retires by
  its own marker, or undoes the move before writing it.
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
  - Delete your server.
  - Restore here, when no server answers: the delete through the ledger as
    the fence, then the local copy staged and activated.

  Each act reads the summary (`HomeSummary`) first and runs only what it
  offers (the key rule). Its steps after that read are steps of their own, so
  the candidate and the server can move in between, as they can in the code.
- **The provider**, which deletes the server, or refuses (`Provision`,
  `Provision.Driver`).

The spec was first written from the design, ahead of the acts. Its finding
HR-1 changed the design before the acts were built: Move now writes the start
ahead. It now mirrors the built acts. Its findings against them, HR-2 and
HR-3, are fixed (352ae545), and so is the second check 09 found.

**Who serves as the primary**:
- **The server**: it exists (no delete removed it), and its engine booted as
  the primary, or its next boot will (config primary, no marker:
  `Role.resolve/2`).
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
| `NetCanFail` | environment | The network between the Mac and its server fails for good. The link and every rail end; a server that runs runs on |
| `DeleteCanFail` | environment | The provider refuses a delete |
| `MaxPresses` | bound | The owner's presses on the Mac's Always On screen |
| `MarkerBeforeCommit` | mechanism | The server writes its `moved.json` and records `committing` before it sends `move_commit` (`commit/4`, `retired/4`) |
| `MarkerBeforeConfig` | mechanism | The activation removes the Mac's `moved.json` (step e) before it renames the staged `config.toml` into place (step f) (`activate/3`) |
| `RecordEntries` | mechanism | The staged entries are recorded once, in `candidate/entries.json`, before any rename, and every run reads them back (`record_entries/1`). `FALSE` lists the staging again at each run, as the forward `activate/1` does |
| `PruneRetired` | mechanism | Step a sets aside every path of the retired copy that no recorded entry names and this machine does not keep (`prune_retired/3`) |
| `DeleteBeforeRestore` | mechanism | Restore here's job deletes the server first, and restores nothing after a fence refused or failed (`run_return_restore/4`, `fenced_restore/3`). `FALSE` restores first |
| `DeleteOfferedOnlyBack` | mechanism | The summary offers Delete your server on this computer only once `return.json` has `moved_at` (`back/1`). `FALSE` offers it whenever the ledger's server stands, which leaves the delete to `delete_target/4` alone |
| `UnconfirmedKept` | mechanism | Move now keeps `move_started_at` for an `unconfirmed` answer too (`return_answered/3`), as a replace's `Provision.move_forwarded/3` does. `FALSE` keeps it only on `{ok, move_id}` |
| `StartKeptFirst` | mechanism | Move now writes `move_started_at` before it forwards `home.move.start` (`return_start_ahead/2`), and the answer settles it. `FALSE` is the design's draft 2, which wrote it after the answer (HR-1) |
| `MovingBackRefused` | mechanism | `delete_target/4` refuses `:moving_back` while a `candidate/` exists, or while `return.json` says the move back started and is not done (`moving_back?/1`, `started_back?/1`). `FALSE` has no such clause |
| `StoppedReturnClears` | mechanism | A move back that a stop left part-way can be cleared. This switch stands for two changes, either of which alone closes the path (checked by hand): Cancel removes `return.json` before `candidate/` (`forget_return/1`), and a started record left alone, whose server answers with no move, offers Cancel (`returning/1` with `server_idle?/1`, `return_stopped/2`; `cancel/2`'s `returning?/1`). `FALSE` is neither change (HR-2) |
| `UndoneInAnyPhase` | mechanism | A candidate receiving or staged, whose server answers as the primary with no move under way, draws undone, or Cancel when it has no record (`return_view/2`). `FALSE` draws moving whatever the server says (HR-2) |
| `RestoreOnFenceRequest` | mechanism | Restore here is offered for a ledger server or a requested fence (`restore_offer/1` on `fence_requested`). `FALSE` needs `fenced_at`, which a stop after the delete never writes (HR-3) |

Every check sets every switch.

## What holds

Every check runs with every failure on: losses, late answers and lost
forwarded answers; both engines crashing; the stagings and the server's
marker failing; the network failing for good; and the provider refusing
deletes.

**Check 01**: three rules.
- `AtMostOnePrimary`: never both the server and the Mac serve as the
  primary. It rests on two mechanisms:
  - `MarkerBeforeCommit` (check 02, a 31-state counterexample). The server
    sends `move_commit` before its marker, and the Mac activates through f.
    The marker write then fails, so the server aborts and undoes the move and
    writes role primary.
  - `DeleteBeforeRestore` (check 03, 15 states). With the network down,
    Restore here stages and activates the copy first. The server, which
    still runs, has not been deleted when the Mac's `config.toml` says
    primary.
- `NoRefusedBoot`: the Mac's `config.toml` never says primary beside its
  marker. It rests on `MarkerBeforeConfig` (check 04, 16 states): with f
  before e, the state between them is one whose boot `Role.resolve/2`
  refuses.
- `RetiredCopyNeverServes`: once the Mac serves as the primary, every path
  that is not this machine's own came from the staging, and none of the
  staging's is missing. A missing `memory.db` would make the primary's repo
  open a fresh one. The rule rests on two mechanisms:
  - `RecordEntries` (check 05, 22 states). A local restore's activation
    places the staged entry, and the engine dies. The next run lists the
    staging, which no longer names the entry, so step a sets the server's
    copy aside, and the primary opens a fresh `memory.db`.
  - `PruneRetired` (check 06, 17 states): without step a, a file the server
    deleted survives into the primary.

**Check 07**: `ServerDeletedOnlyAfterReturn`. The server is deleted only once
the Mac recorded `moved_at` at its boot as the primary, or as Restore here's
fence before anything is staged and while the Mac's `config.toml` still says
device. It rests on two mechanisms:
- `DeleteBeforeRestore` (check 08, 17 states): a job that restores first
  deletes after the staging.
- **Check 09** runs the same rule with `DeleteOfferedOnlyBack` off: Delete
  your server offered on every screen while the ledger's server stands. The
  rule still holds, because `delete_target/4` alone refuses the delete while
  a move back's candidate or started record stands. That rests on
  `MovingBackRefused` (check 21, 29 states). Without the refusal, Delete is
  pressed after step e, when the device has lost its link (step c) and its
  marker (step e), and the server is deleted before `moved_at`.

  Wave 3 first refused only while a `candidate/` existed. This check then
  broke in the second between step g and the candidate's restart, where no
  candidate is left. Refusing a started record too (`started_back?/1`)
  closed that second (352ae545).

**Check 10**: `RetiredOnlyForStagedReturn`. Once the server wrote its marker,
the Mac holds the staged home, is activating it, or serves it. This is
`home_move`'s retire rule, carried to the return: a server that retired for
anything less leaves no primary, and its resume loop never ends. It rests on
two mechanisms:
- `UnconfirmedKept` (check 11, 22 states). With an `unconfirmed` answer
  taken as "not started", the record goes again, so Cancel is offered while
  the server moves. The path from there is HR-1's.
- `StartKeptFirst` (check 12, 21 states): HR-1's path, with the start written
  after the answer.

**Check 19**: `UndoneReturnCanEnd`, a proposed rule (HR-2). While the
server answers as the primary with no move under way, and nothing runs on
the Mac, the Mac's screen offers a step. It rests on two mechanisms:
- `StoppedReturnClears` (check 22, 13 states): HR-2's first path.
- `UndoneInAnyPhase` (check 23, 22 states): HR-2's second path.

**Check 20**: `GoneServerCanBeRestored`, a proposed rule (HR-3). A Mac whose
server is gone, and which serves nothing itself, is offered Restore here
once nothing runs. It rests on `RestoreOnFenceRequest` (check 24, 6 states):
HR-3's path.

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
- **17**: no server answers. The fence deletes it, and the Mac restarts from
  its copy.
- **18**: Delete your server removes the server after the return.

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

The path (check 12, 21 states):
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

The same lost record also gave two more paths, found against checks 01 and 07:
- a wedge: Cancel killed the candidate's restart in the second after g;
- a delete before `moved_at`, by Restore here's fence.

**The fix, as built**:
- **Write ahead.** `return_start_ahead/2` writes `move_started_at` before the
  request leaves.
- **The answer settles it** (`return_answered/3`). A move id keeps it, and so
  does `unconfirmed` (`UnconfirmedKept`). Any other answer (the link down, a
  refusal) takes it back.
- **A new summary row.** A start recorded while the server answers as the
  primary with no move under way draws ready again (`server_idle?/1`).
- **Delete refused.** `delete_target/4` refuses `:moving_back` while a
  `candidate/` exists.

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

### HR-3: a stop between the fence's delete and its `fenced_at` left no primary and no Restore here

**Fixed** in 352ae545. Check 24 keeps the path. Check 20 holds.

The rule is a proposed one: `GoneServerCanBeRestored`. A Mac whose server is
gone, and which serves nothing itself, is offered Restore here once nothing
runs.

The fence is two writes:
1. `Driver.delete/3` removes the server and clears it from the ledger.
2. `Provision.fenced/2` writes `fenced_at`.

`restore_offer/1` offered Restore here only for a ledger server or a
`fenced_at`, so after a stop between the two writes there was neither:
- the screen was `cannot_reach` or `deleted`, with Learn more;
- nothing served the home;
- Always On could not restore it.

The path (check 24, 6 states): the network fails; Restore here; the fence
deletes the server and clears the ledger; the Mac's engine dies.

**The fix, as built** (`RestoreOnFenceRequest`):
- `restore_offer/1` offers Restore here for a ledger server or a
  `fence_requested`. The job's `fence/4` then runs the restore alone
  (`fenced_before/2`).
- `fence_failed?/2` needs the ledger still to hold a server, so a fence whose
  delete went through is no delete failure.
- `restore_offer/1` also needs the server as silent as the fence asks (D13).
  Here that is the link being down.

## Model and code

Walked step by step against 69fb0c1a. Where the code differs from what the
first version modelled from the design, and whether it matters:
- **`returning/1`.** `return.json` alone with no start (a stop between Move
  back's writes) is not returning: it draws `on` or the away screens, not
  Cancel. A started record with no candidate draws moving. Receiving and
  staged draw moving whatever the server says. That was HR-2, since fixed;
  modelled.
- **`delete_target/4`.** It has the fence case and refuses `:moving_back`
  while any `candidate/` exists. Modelled. It left open the second after
  step g, which check 09 found and `started_back?/1` has since closed.
- **The fence is two writes.** Restore here's offer needs the ledger's server
  or `fenced_at`. That was HR-3, since fixed; modelled.
- **A local staging can fail.** It records `failed` and ends the job, and
  `prepare_return/3` replaces that candidate. Modelled.
- **Move now's write-ahead and settlement**, and **Cancel's stop, withdraw
  and two removals**, are as the spec proposed. Unchanged.
- **The key's derivation** happens at the press, before the fence. It
  matters to no rule (one staging step here).
- **Move back's server check and forward** fold into the press, as before.

Walked again against e115c598, the fixes:
- **HR-2:** `forget_return/1`'s order; `cancel/2` with `returning?/1`;
  `returning/1` with `server_idle?/1`; `return_stopped/2`; and `return_view/2`
  for receiving and staged.
- **HR-3:** `restore_offer/1` on `fence_requested` and `silent?/1`;
  `fence_failed?/2` with a ledger server.
- **Check 09's second:** `delete_target/4` with `moving_back?/1` and
  `started_back?/1`.
- **A fence refused for a server that answers again:** `fence_refused/1`
  and `server_back/1`. The request is dropped, with no ledger failure, and
  the screen is the linked one again (`RhDelete` sets `return.json` back to
  a plain record).

Each is modelled as built. Walking them found nothing new.

## Done

Deadlock checking is on. `Done` has these ends:
- **Back on the Mac**: its engine booted as the primary, and the server is
  retired or deleted. The server's worker may still resume, a loop that never
  stops here: with no desktop key it cannot probe the moved identity, and
  its 24-hour bound is not modelled.
- **The server serves**: its worker is off and the Mac waits as a device,
  whatever its candidate holds. Check 19 holds that the Mac's screen offers
  a step there wherever the server answers.
- **The server deleted as the fence, the restore unfinished**, with the
  owner's presses spent. Restore here is offered again (check 20).

## Bounds

The checks run with `MaxLosses = 2`, `MaxCrashes = 1` per engine and
`MaxPresses = 4`. Each takes about one to two seconds. The holds checks
explore 56,532 states; check 09, with Delete offered everywhere, 100,806.

Every rule of the holds checks was run by hand, together:
- with one more of each (`MaxLosses = 3`, `MaxCrashes = 2`,
  `MaxPresses = 5`): no error, 390,663 states, 7 s;
- with two more (`MaxLosses = 4`, `MaxCrashes = 3`, `MaxPresses = 6`): no
  error, 1,382,436 states, 24 s.

Check 09's setup one bound up: no error, 695,984 states, 11 s.

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
- a second desktop (the stale epoch, the passed return's drop);
- an owner's own server, which has no ledger and no Restore here;
- the fence's failure kept in the ledger and its `delete_failed` screen;
- the copy's choice and a wrong passphrase;
- the key's derivation.

## Outside the model

Read while walking the code. TLC does not show these.

- **A fence refused while the link came back** used to keep a delete
  failure that left `delete_failed` with only Restore here, ahead of `on`,
  for as long as the server answered. It is fixed in 352ae545:
  `server_back/1` drops the request and keeps no failure.
- **Cancel in undone.** Section 9's text said Cancel "is not offered once
  `move_started_at` is set", while its table offers it on undone. The code
  follows the table, and so does the spec. Cancel is safe there, since the
  server undid the move and serves.
