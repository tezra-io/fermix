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
ahead. It now mirrors the built acts. Two findings are open against them:
HR-2 and HR-3.

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
- `DeleteOfferedOnlyBack` (check 09, 31 states). Delete your server is
  offered on the moving screen, and pressed in the second between step g and
  the candidate's restart. In that second, `delete_target/4` answers
  `:current`: `candidate/` is gone (g), and so are the link (c) and the
  marker (e). So the server is deleted before `moved_at`.

  `delete_target/4` now refuses `:moving_back` while any `candidate/`
  exists. That closes the window from e to f, which this check took before
  that change, but not the second after g. There the key rule is still the
  only guard. To close it in `delete_target/4` too, refuse while
  `return.json` has `move_started_at` and no `moved_at`.

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

### HR-2: after the server undoes a return, or never starts it, the Mac can be left showing moving with nothing to press

Open, against the code at 69fb0c1a. Check 19 keeps the shortest path.

The rule is a proposed one: `UndoneReturnCanEnd`. While the server answers
as the primary with no move under way (it undid the move, or never had it)
and nothing runs on the Mac, the Mac's screen offers a step. The code breaks
it in two independent ways.

**1. Cancel removes `candidate/` before `return.json`** (`forget_return/1`).
A stop between the two leaves a record with `move_started_at` alone.
`returning/1` draws that record as moving, with no action, for good. The
act's Cancel needs a candidate anyway (`cancel/2`'s first clause). The path
(check 19, 13 states):
1. Move back. The candidate enrols.
2. Move now: the start is written ahead, and the request is lost before the
   server has it (`unconfirmed`, kept).
3. The server answers as the primary with no move, so the screen is ready
   again with Cancel.
4. Cancel stops the candidate and removes `candidate/`.
5. The Mac's engine dies before `return.json` goes. It boots to a started
   record with no candidate, drawn as moving.

Path 2 below starts from a Cancel pressed on undone, so a stop between the
two removals there gives the same wedge.

**2. Receiving and staged are drawn moving whatever the server says**
(`return_view/2`'s last clause). Suppose the server undoes a return after the
candidate took an offer. Three ways lead there:
- the marker write fails;
- three streams fail;
- three restores outlive the 30-minute wait.

The Mac's candidate then stays receiving or staged, and its screen stays
moving, with nothing to press:
- `listen_end` expires only an enrolled candidate;
- undone and the ready-again row read only an enrolled one.

`MoveAwake` holds the Mac awake in those phases, so it never sleeps either.
With Cancel's removals reordered, the model reaches this path in 22 states:
Move back, Move now, offer, stream, staged, `move_ready`, the marker write
fails, abort, undo, restart. Which of the two paths check 19 pins is a matter
of length; both break the same rule.

**How likely.** The first path needs a stop between two file writes. The
second needs a return the server undid after the stream began: a flaky
network during a large stream does it. No primary is lost (the server
serves), but the Mac's Always On screen is a dead end that no step clears.
Only removing `candidate/` and `return.json` by hand clears it.

**A fix:**
- Remove `return.json` before `candidate/`. A stop between them then leaves
  the candidate alone, which `return_stopped/1` offers to Cancel.
- In `return_view/2`, draw receiving and staged like enrolled whenever the
  server answers with no move under way (`server_move == "aborted"` or
  `server_idle?/1`). That gives undone (Try again, Cancel) or ready (Move
  now, Cancel).

Both are safe:
- A server that answers as the primary holds no marker, so it never retires
  for that move.
- Try again's new move id is later than the one the candidate holds, so the
  candidate takes it.

### HR-3: a stop between the fence's delete and its `fenced_at` leaves no primary and no Restore here

Open, against the code at 69fb0c1a. Check 20 keeps the path.

The rule is a proposed one: `GoneServerCanBeRestored`. A Mac whose server is
gone, and which serves nothing itself, is offered Restore here once nothing
runs.

The fence is two writes:
1. `Driver.delete/3` removes the server and clears it from the ledger
   (`Ledger.clear/1`).
2. `Provision.fenced/2` writes `fenced_at` into `return.json`.

Restore here is offered only for a ledger server or a `fenced_at`
(`restore_offer/1`). After a stop between the two writes there is neither:
- the screen is `cannot_reach` with Learn more, or `deleted`;
- the fence's failure screen (`fence_failed/2`) also needs `restore_offer/1`;
- no step restores the copy;
- no server serves the home.

The path (check 20, 6 states): the network fails; Restore here; the fence
deletes the server and clears the ledger; the Mac's engine dies.

A failed `fenced_at` write gives the same end without any stop:
`fenced/2` logs it and carries on. If the copy's staging then fails, the
restore's failure screen offers Learn more only.

**How likely.** Narrow: a stop in the moment between the provider's delete
and the next file write, or a write that fails then. But it is the worst end
in the spec: the home lives nowhere, and Always On cannot restore it.

**A fix**: key `restore_offer/1` on `fence_requested` with a ledger that holds
no server, rather than on `fenced_at`. The job's `fence/4` already treats a
ledger that holds nothing as fenced before (`fenced_before/2`). Or write
`fenced_at` before the ledger is cleared.

## Model and code

Walked step by step against 69fb0c1a. Where the code differs from what the
first version modelled from the design, and whether it matters:
- **`returning/1`.** `return.json` alone with no start (a stop between Move
  back's writes) is not returning: it draws `on` or the away screens, not
  Cancel. A started record with no candidate draws moving. Receiving and
  staged draw moving whatever the server says, which is HR-2. Modelled.
- **`delete_target/4`.** It has the fence case and refuses `:moving_back`
  while any `candidate/` exists. Modelled; see check 09 for the second it
  leaves open.
- **The fence is two writes.** Restore here's offer needs the ledger's server
  or `fenced_at`. Modelled; this is HR-3.
- **A local staging can fail.** It records `failed` and ends the job, and
  `prepare_return/3` replaces that candidate. Modelled.
- **Move now's write-ahead and settlement**, and **Cancel's stop, withdraw
  and two removals**, are as the spec proposed. Unchanged.
- **The key's derivation** happens at the press, before the fence. It
  matters to no rule (one staging step here).
- **Move back's server check and forward** fold into the press, as before.

## Done

Deadlock checking is on. `Done` has these ends:
- **Back on the Mac**: its engine booted as the primary, and the server is
  retired or deleted. The server's worker may still resume, a loop that never
  stops here: with no desktop key it cannot probe the moved identity, and
  its 24-hour bound is not modelled.
- **The server serves**: its worker is off and the Mac waits as a device,
  whatever its candidate holds. HR-2's check says when that wait is a dead
  end.
- **The server deleted as the fence, the restore unfinished**, with one of
  two causes:
  - the owner's presses are spent, and Restore here is offered again;
  - HR-3's dead end, which check 20 records. It is listed here only so that
    every other check runs. Remove it from `Done` with the fix.

## Bounds

The checks run with `MaxLosses = 2`, `MaxCrashes = 1` per engine and
`MaxPresses = 4`. Each takes about one to two seconds; the three holds checks
explore 56,003 states.

Every rule of the three holds checks was run by hand, together:
- with one more of each (`MaxLosses = 3`, `MaxCrashes = 2`,
  `MaxPresses = 5`): no error, 385,520 states, 6 s;
- with two more (`MaxLosses = 4`, `MaxCrashes = 3`, `MaxPresses = 6`): no
  error, 1,360,376 states, 21 s.

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

- **A fence refused while the link came back.** Restore here is pressed
  while the server is silent. The link answers again before the job's
  `delete_target/4`, which refuses the fence. `fence_failed/2` keeps the
  failure, and `restoring/1` then draws `delete_failed` with Restore here
  only, ahead of `on`. Every later Restore here is refused while the link is
  up, and Move back is not drawn until the failure clears. Only three things
  clear a delete's failure:
  - a delete that succeeds (`Ledger.clear/1`);
  - a create (`Ledger.begin_create/3`);
  - a fence run with nothing in the ledger (`fenced_before/2`).

  None of them can run while the server stands and answers. The home is
  served throughout. Only the Mac's screen is stuck, offering a step that
  cannot succeed, which `UndoneReturnCanEnd` (any step offered) does not
  catch.
- **Cancel in undone.** Section 9's text said Cancel "is not offered once
  `move_started_at` is set", while its table offers it on undone. The code
  follows the table, and so does the spec. Cancel is safe there, since the
  server undid the move and serves.
