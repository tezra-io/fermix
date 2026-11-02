# home_return: moving a home back to the computer it left

Models Always On's move back (`ALWAYS_ON_MOVE_BACK.md`, draft 2: sections 1,
3, 7 and 8, and the TLA paragraph of section 10). The home comes back from
the server it moved to, to the computer it left, which receives it in its own
device engine. "Mac" is that computer, whatever its OS. Three copies of the
home take part:
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
  before the marker, the endings its boots record.
- **The Mac's receiver**: the candidate process under the device tree
  (`FermixChannels.Home.Candidate`, `DeviceSupervisor`), its staging, and the
  activation. The process runs it on `move_commit`, or at its start in
  `activating`. The `return_restore` job runs it for a local copy.
- **The Mac's acts**, through `home.act`, one at a time (the serializer). Each
  act reads the summary first and runs only what it offers (the key rule):
  - Move back: a return candidate, then `return.json`.
  - Move now: `home.move.start` forwarded over the link.
  - Cancel.
  - Delete your server.
  - Restore here, when no server answers: the delete through the ledger as
    the fence, then the local copy staged and activated.

  An act's steps after that read are steps of their own, so the candidate and
  the server can move in between, as they can in the code.
- **The provider**, which deletes the server, or refuses.

**The Mac's acts are modelled from the design.** At the pinned commit they are
being built, so `Press`, the `Mb`, `Mn`, `Cx`, `Ds` and `Rh` actions and the
summary's offers (`Offered`, `ReturnOffers`, `DeviceOffers`) carry no `SOURCE`
pin yet. `StartKeptFirst` is in neither the design nor the code: it is the fix
this spec proposes for its finding, HR-1.

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
| `MessagesCanBeLost` | environment | a rail loses a request or an answer; an answer comes after the worker stopped waiting; or the forwarded `home.move.start`'s answer is lost (`unconfirmed`), before or after the server had it. At most `MaxLosses` in all |
| `ServerCanCrash`, `MacCanCrash` | environment | the engine dies and boots again from its files (at most `MaxCrashes` each) |
| `TransferCanFail` | environment | the Mac's staging fails (a keychain that refuses, a restore that fails: `restored/2`'s error clause), or the server's ready epoch or marker cannot be written (`commit/4` aborts) |
| `NetCanFail` | environment | the network between the Mac and its server fails for good. The link and every rail end; a server that runs runs on |
| `DeleteCanFail` | environment | the provider refuses a delete |
| `MaxPresses` | bound | the owner's presses on the Mac's Always On screen |
| `MarkerBeforeCommit` | mechanism | the server writes its `moved.json` and records `committing` before it sends `move_commit` (`commit/4`, `retired/4`) |
| `MarkerBeforeConfig` | mechanism | the activation removes the Mac's `moved.json` (step e) before it renames the staged `config.toml` into place (step f) (`activate/3`) |
| `RecordEntries` | mechanism | the staged entries are recorded once, in `candidate/entries.json`, before any rename, and every run reads them back (`record_entries/1`). `FALSE` lists the staging again at each run, as the forward `activate/1` does |
| `PruneRetired` | mechanism | step a sets aside every path of the retired copy that no recorded entry names and this machine does not keep (`prune_retired/3`) |
| `DeleteBeforeRestore` | mechanism (design) | the `return_restore` job deletes the server first, and restores nothing after a refused delete (design section 8). `FALSE` restores first |
| `DeleteOfferedOnlyBack` | mechanism (design) | the summary offers Delete your server only once `return.json` has `moved_at` (section 7). `FALSE` offers it whenever the ledger's server stands, which leaves the delete to `delete_target/4` alone |
| `UnconfirmedKept` | mechanism (design) | Move now keeps `move_started_at` for an `unconfirmed` answer too, as a replace's `Provision.move_forwarded/3` does ("a lost answer is unconfirmed as for a replace", M2). `FALSE` keeps it only on `{ok, move_id}` |
| `StartKeptFirst` | **proposed** (HR-1) | Move now writes `move_started_at` before it forwards `home.move.start`, and removes it only when the request never reached the server. `FALSE` is the design as written: the write comes after the answer |

Every check sets every switch. The checks that hold set `StartKeptFirst` to
`TRUE`; check 12 runs the design as written.

## What holds

Every check runs with every failure on: losses, late answers and lost
forwarded answers; both engines crashing; the staging and the server's marker
failing; the network failing for good; and the provider refusing deletes.

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

**Check 07**: `ServerDeletedOnlyAfterReturn`. The server is deleted only once
the Mac recorded `moved_at` at its boot as the primary, or as Restore here's
fence before anything is staged and while the Mac's `config.toml` still says
device. It rests on two mechanisms:
- `DeleteBeforeRestore` (check 08, 17 states): a job that restores first
  deletes after the staging.
- `DeleteOfferedOnlyBack` (check 09, 29 states). Delete your server is
  offered on the moving screen and pressed after step e. The device has lost
  its link (step c) and its marker (step e), so `delete_target/4` answers
  `:current`, and the server is deleted before `moved_at`. The key rule is
  the only guard here: `delete_target/4` refuses a linked or marked device,
  and between e and f a returning device is neither.

**Check 10**: `RetiredOnlyForStagedReturn`. Once the server wrote its marker,
the Mac holds the staged home, is activating it, or serves it. This is
`home_move`'s retire rule, carried to the return: a server that retired for
anything less leaves no primary, and its resume loop never ends. It holds
with the proposed `StartKeptFirst`, and rests on `UnconfirmedKept` (check 11,
22 states). With the first write but an `unconfirmed` answer taken as "not
started", the record goes again, so Cancel is offered while the server
moves. The path from there is HR-1's.

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

## Finding

### HR-1: a Mac that loses the record of the move's start offers Cancel while the server moves, and a Cancel that lands mid-move leaves no primary

Open, against the design as written (draft 2). Check 12 keeps the path.

The design writes `move_started_at` into `return.json` after the server
answered `home.move.start` ("on `{ok, move_id}`", M2). It keys Cancel on
that record: "not offered once `move_started_at` is set" (section 9), and
ready (enrolled) offers it. Cancel's key check reads the summary, then
`Link.stop_return/0` stops the candidate, then `candidate/` and `return.json`
are removed.

Nothing ties that record to the server's move: the server restarts into the
move as it answers. When the Mac does not write the record, its screen shows
ready, with Cancel, for as long as the server moves. Two ways lead there:
- the Mac's engine dies between the answer and the write;
- an `unconfirmed` answer is not counted as started. The design's "on
  `{ok, move_id}`" reads that way.

The path (check 12, 21 states):
1. Move back. The candidate enrols.
2. Move now. The server takes `home.move.start`, records the move, restarts
   into it, and answers.
3. The Mac's engine dies before `return.json` gains `move_started_at`, and
   boots again as a device. Its candidate is still enrolled.
4. The server's worker sends `move_offer`.
5. The owner presses Cancel. The summary is ready, so the key check passes.
6. Before Cancel's next step, the candidate takes the offer, the stream and
   the restore stage the home, and the server retires: it writes its marker.
7. Cancel stops the candidate and removes `candidate/`. The server is
   retired, and nothing holds its home.

The same lost record has two more ways to end badly. TLC finds them when the
design as written runs against checks 01 and 07:
- **A wedge** (check 01's rules, a 39-state deadlock). The activation
  finishes (g), and the candidate schedules its restart, one second later.
  In that second the summary offers Cancel for `return.json` alone (the
  crash-leftover rule), and Cancel's stop kills the candidate before its
  restart. The Mac runs on as a device with primary settings and no marker
  until something restarts it. `return.json` is gone, so `moved_at` is never
  written and Delete your server is never offered.
- **A delete before `moved_at`** (check 07's rule, 35 states). Cancel lands
  mid-activation, after f, and stops it. With its link file gone (step c),
  the device's screen then offers Restore here. Its fence deletes the server
  while the Mac's `config.toml` already says primary. That server was
  retired, so nothing is lost, but B5's rule is broken.

Read, not checked: a `returning/1` that follows section 14's key to the
letter ("`return.json` with `move_started_at`") reaches the same delete
without Cancel. In the second after g, `return.json` alone is not returning,
and the screen is `retired`, which offers Restore here.

**How likely.** It is narrow:
- The record must be lost: a crash at one point, or an `unconfirmed` answer.
- The press must land in a window: between Cancel's key check and its stop,
  or in the second before the candidate's restart.

Nothing in the design closes it.

**The proposed fix** (`StartKeptFirst`, which every check that holds sets):
- Move now writes `move_started_at` before it forwards `home.move.start`.
- It removes the record again only when the request never left (the link was
  down) or the server refused it.
- An `unconfirmed` answer keeps it, as for a replace (`UnconfirmedKept`).

Then the server never moves without the Mac's record, and returning/1 shows
moving, with no Cancel and no Restore here, until the server answers again.
The record can now stand where no move does: a stop between the write and
the forward, or a request lost before the server had it. So the summary also
needs the row section 9 lacks: a return with `move_started_at` whose server
answers as the primary with no move under way offers Cancel, as undone does
(`NoMoveThere` here). With both, every rule holds (check 10). Without the row,
that screen shows moving until the candidate's 24-hour listen window ends.

A fix in the candidate is the alternative. Cancel would go through the
candidate process, which refuses it once it holds a move or has put the home
in place, so the check and the stop are one step against an offer. That
closes the race, but not the second after g, and not the Restore here path.

## Done

Deadlock checking is on. `Done` has three legitimate ends:
- **Back on the Mac**: its engine booted as the primary, and the server is
  retired or deleted. The server's worker may still resume, a loop that never
  stops here: with no desktop key it cannot probe the moved identity, and
  its 24-hour bound is not modelled.
- **The server serves**: its worker is off and the Mac waits as a device,
  whatever its candidate holds. This covers a return undone, cancelled or
  never started, and a network that failed for good.
- **The server deleted as the fence, the presses spent**: the restore did not
  finish (refused, or stopped by a crash), and Restore here is offered again.

## Bounds

The checks run with `MaxLosses = 2`, `MaxCrashes = 1` per engine and
`MaxPresses = 4`. Each takes about one to four seconds; the three holds
checks explore 49,209 states.

Every rule of the three holds checks was run by hand, together:
- with one more of each (`MaxLosses = 3`, `MaxCrashes = 2`,
  `MaxPresses = 5`): no error, 355,926 states, 7 s;
- with two more (`MaxLosses = 4`, `MaxCrashes = 3`, `MaxPresses = 6`): no
  error, 1,275,709 states, 46 s.

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
- an owner's own server, which has no ledger and no Restore here;
- the key's derivation and the copy's choice.

## Outside the model

Noticed while modelling from the design. TLC does not show these.

- **Cancel in undone.** Section 9's text says Cancel "is not offered once
  `move_started_at` is set", while its table offers Cancel beside Try again
  on undone, which has `move_started_at`. The spec follows the table. Cancel
  is safe there, since the server undid the move and serves.
- **The second after g, with the record kept.** `return.json` has
  `move_started_at` and no `moved_at`, so returning/1 shows moving and offers
  nothing. That is right. Any later change to returning/1's key should keep
  this second covered (see HR-1).
