# home_move: moving a home to another host

Models one move of M75 §7.2 (B5). Three parts take part:
- **The source**: the home that was the primary, restarted in the device role,
  with its move worker (`FermixChannels.Home.MoveWorker`) and the files it
  writes: the role in `config.toml`, `moved.json` and `.move/phase.json`.
- **The candidate**: the enrolled host that receives the home, stages it and
  activates it (`FermixChannels.Home.Candidate`, its responder
  `MoveResponder`, and `FermixCore.Home.Candidate.Activation`), with its
  durable phase and the move it holds.
- **The rail** between them (`Mobile.Rail`). Each dial opens a new rail, which
  carries one request and its answer at a time: offer and accept, stream and
  ready, commit and done, resume and ready or done. One "stream" request stands
  for every `move_chunk` and the `move_end`.

**Who serves as the primary**:
- The source serves as the primary when its engine booted as one, or when its
  next boot will: `config.toml` says primary and `moved.json` is absent
  (`Role.resolve/2`, `role.ex:206-216`). Counting the next boot keeps the end
  of `undo/3` on the cautious side: the role is written there, and the restart
  comes after.
- The candidate serves as the primary once `config.toml` is renamed into
  place, whether or not it has rebooted yet. That rename is the commit point
  of `Activation.activate/1`. A crash before it boots the candidate again, and
  the candidate finishes the activation; a crash after it boots the primary.

**Environment switches** (set per check):
- `MessagesCanBeLost` (at most `MaxLosses` times): the rail loses a request
  or an answer, or an answer arrives only after the worker stopped waiting
  for it, as with a restore that runs past the worker's 30-minute wait.
- `SourceCanCrash`, `CandidateCanCrash` (at most `MaxCrashes` times each):
  the engine dies and boots again from its files. The source's worker re-runs
  `run/1`; the candidate re-runs `carry_on/1`.
- `TransferCanFail`, before `move_ready`. Five failures fall under it:
  - an attempt fails at the source before its offer is out in a way another
    attempt may mend (the device row, or a capture that failed for another
    reason than room), and the worker tries again (`AttemptFails`);
  - an attempt fails at the source before its offer is out in a way another
    would not mend, and the worker aborts the move (`AttemptAborts`,
    `attempt_failed/2`, `move_worker.ex:236-250`): the secret store refuses
    the desktop key, or its item holds another home's key under the same
    profile; the keychain does not give the settings' secrets; or the
    capture has no room;
  - the candidate's restore fails: it goes back to enrolled, holding no move,
    and refuses, so the source aborts;
  - the ready epoch or the marker cannot be written, and `commit/4` aborts;
  - the candidate refuses an offer it has no room for (twice the stream
    plus a floor), before any byte moves (`OfferRefusedForRoom`).

  The attempt cap (3, across restarts) bounds the retries.
- `PhaseWriteCanFail`: the boot's write of a move's ending fails (a full
  disk, a folder it may not write). The boot goes on and records that it left
  the ending unrecorded (`finish_move/2` and `left_to_status/1` in
  `application.ex`, `Move.remember_unrecorded_ending/0`); `home.status` then
  tries the write again at each read (`StatusRetry`, `Move.view/3`).
- `OldRequestsArrive`: a request the worker sent on a rail it has since given
  up on still reaches the candidate. Two rails are two streams, so nothing
  orders one rail's frames against another's. The worker closes a rail it
  gives up on (`close_rail/1`, `move_worker.ex:224`, `:523`, `:537`), but
  `Rail.close/1` sends its close frame behind whatever the rail already sent
  (`rail.ex`). Whether the iroh helper still delivers what it holds once the
  socket closes ("the helper ends its stream on its own", `helper.ex`) is
  decided in the helper, outside this repo.

**Mechanism switches** (`TRUE` is the real code):
- `CandidateWaitsForCommit`: the candidate activates only on `move_commit`
  for the move it staged (`commit_move/2`, `candidate.ex:637-670`).
- `MarkerBeforeCommit`: the worker writes `moved.json` and records
  `committing` before it sends `move_commit` (`commit/4`, then `retired/4`,
  `move_worker.ex:517-540`).
- `OffersFenced`: the candidate takes an offer only when it is later than the
  move it holds, a later move id or a later attempt of the same move, and
  refuses an earlier or equal one (`move_mismatch`), leaving what it holds
  untouched (`fenced_offer/2`, `later?/2`, `candidate.ex:506-518`).
  `move_offer` carries the attempt (`send_snapshot/3`, `move_worker.ex:450`),
  which only grows across restarts. Move ids are ordered by when the move
  started (`move_id/1`, `move.ex:532-541`); with one move id, the fence
  orders by attempt.
- `ReadyAfterStaged`: `move_ready` goes out only after `staged` is written.
  `restored/2` records `staged`, then tells the responder
  (`candidate.ex:606-612`), which answers `move_ready` only then
  (`move_responder.ex:65-69`).
- `AwaitPinsRail`: the worker takes an answer only from the rail it waits on
  (`await_any/3` matches `{:rail, ^rail, _}`, `move_worker.ex:944-957`).
- `EndingsAfterRestart`: the worker records `committed` (after `move_done`)
  or `undoing` (after an undo) and then restarts itself (`SelfRestart`,
  `Lifecycle.restart_self/0`); the engine that boots after it records `done`
  or `aborted` (`Finalize`, `Move.finish_at_boot/2` from the boot's
  `prepare_home`). Switched off, the worker records `done` or `aborted`
  before its restart, as the code did before the fix.
- `RetryOnlyAfterBoot`: a `home.status` read writes a move's ending only in
  the engine whose boot could not write it (`Move.view/3` with
  `Move.boot_ending/0`, through `HomeMove.move_view/3`). Switched off, a read
  in any engine of the ending's role writes it, including the device engine
  whose worker just recorded `committed` and is about to restart.

There is no `AbortRechecksMarker` switch, because in this model the re-check
in `abort/3` never finds a marker. Every road to `abort/3` starts before
`retire/1` writes one:
- a refusal, a failure another attempt would not mend, or the attempt cap,
  in `transfer/1` and `attempt_failed/2`, which run only while the marker is
  absent;
- `commit/4`'s error clause, after the ready epoch or the marker could not
  be written (`move_worker.ex:521-524`);
- a recorded `aborting`, which `carry_on/3` reaches only when the marker is
  absent.

The re-check matters only for a marker that exists although its write
reported an error. That needs a part-way write, and the model writes the
marker whole or not at all (see "Outside the model").

**Rails, named from the worker's side**:
- `cur`: the rail the worker waits on now.
- `gone`: a rail the worker closed (`close_rail/1` after a failed wait,
  `with_rail/2` after each resume round), or one that died with it. A request
  sent on it may still arrive (`OldRequestsArrive`); an answer on it reaches
  no one. An answer that reached the mailbox before the close stays there,
  and only a worker without `AwaitPinsRail` would read it.

The close is folded into the worker's next step (`Transfer`, `Abort`,
`Resume`, the next resume dial), so an answer can still land in the moment
between the wait ending and the close, as it can in the code. Renaming `cur`
to `gone` is bookkeeping of which rail is which, not a step of the
candidate. An offer on a closed rail keeps the attempt it was sent with.

## What holds

Every check runs with every failure on: losses and late answers, a request
from an abandoned rail arriving late, both engines crashing, the transfer
failing, and the boot's write of a move's ending failing.

**Check 01**: never both engines serve as the primary. The rule is
`AtMostOnePrimary`, the build spec's "at most one engine serves as the
primary" (§7.2/B5; `commit/4`'s comment: "the marker comes before
move_commit, so the candidate never activates while this home could still
serve"). It rests on two mechanisms:
- `CandidateWaitsForCommit` (check 02: a 17-state counterexample). A
  candidate that activates by itself once staged is already the primary when
  the source aborts: the marker write fails, the source undoes the move and
  writes role primary.
- `MarkerBeforeCommit` (check 03: an 18-state counterexample). A
  `move_commit` sent before the marker activates the candidate, then the
  marker write fails, and the source undoes the move.

Run by hand against the retire rule (check 04's setup), neither mechanism
switched off breaks `RetiredOnlyForStagedCandidate` (37,100 and 35,061 states
explored). When the marker lands, the candidate is already activating or
active, and both are in the rule's set. They protect only the one-primary
rule.

**Check 04**: once `moved.json` exists, the candidate holds the staged home,
or is activating it, or has. The rule is `RetiredOnlyForStagedCandidate`. It
rests on three mechanisms:
- `OffersFenced` (check 05: a 16-state counterexample, the finding below). A
  late offer from attempt 1's rail un-stages the candidate after the source
  retired on attempt 2.
- `ReadyAfterStaged` (check 06: an 11-state counterexample): a `move_ready`
  sent when the restore starts lets the source retire while the candidate is
  still receiving.
- `AwaitPinsRail` (check 07: an 18-state counterexample). The path:
  1. Attempt 1's restore outlives the worker's 30-minute wait.
  2. Its `move_ready` reaches the mailbox in the moment between the wait
     ending and the worker closing rail 1, and stays there.
  3. Attempt 2's offer, later than attempt 1, has the candidate discard that
     staging.
  4. A worker that took the old `move_ready` would retire beside a candidate
     that is only receiving.

**Witnesses**:
- **08**: the move completes, with the source done and the candidate booted
  as the primary.
- **09**: the move is undone and the source boots as the primary again. Its
  shortest path is an attempt that aborts at the source before its offer is
  out (`AttemptAborts`), as a desktop key the secret store refuses does.
- **10**: the move completes after a `move_done` was lost. Its shortest path
  is the candidate's own scheduled restart, which ends the rail before the
  `move_done` arrives. The worker's wait ends, it resumes, the dial finds no
  candidate key, and the probe finds the new primary.
- **11**: a late offer from attempt 1's rail reaches the staged candidate
  after the source retired, and the fence refuses it. This shows check 04
  explores the finding's scenario rather than passing because it never
  happens.

**Check 12**: `done` and `aborted` are written only by the engine that came
back after its restart, never by one about to stop. The rule is
`EndingsFromSurvivor`. It rests on two mechanisms:
- `EndingsAfterRestart` (check 13: a 219-state search finds the
  counterexample, the worker writing `done` and still running).
- `RetryOnlyAfterBoot` (check 14: a 19-state counterexample). The worker
  records `committed` and is about to restart its engine, and a
  `home.status` read in that same engine, a device like the one that comes
  back, writes `done`. The retry exists for an ending the boot could not
  write (a full disk); gated on the boot's own record, only the engine that
  came back ever makes it. The finding behind it (the M75 edges review, F1): a pane
that read `done` or `aborted` in the moment between the record and the
restart stopped following the move, with no primary in `home.status` yet and
an engine about to vanish. The rule is about who writes the ending, so it
holds with the one-primary and retire rules unchanged.

## Finding, fixed: a late `move_offer` un-staged the candidate after the source retired

This spec found it, and it was fixed before the move code was first
committed. Check 05 keeps the path: it is what breaks the rule without
`OffersFenced`.

The path, in the code before the fix:
1. Attempt 1 sends `move_offer` on rail 1, and the offer is held up in
   transit.
2. The 60 s accept wait expires. The worker closes rail 1, which puts a close
   frame behind the offer and does not recall it, and tries again.
3. Attempt 2's offer arrives at the enrolled candidate, which records
   `receiving`. The stream, the restore and `restored/2` take it to `staged`,
   and the responder answers `move_ready`.
4. `commit/4` records the ready epoch, and `retire/1` writes `moved.json`.
5. Rail 1's offer arrives now. `offer_move/2` took any offer in `staged`:
   `accept_offer/2` discarded the staging and recorded `receiving`. Nothing
   told this offer apart: it carried the same move id and no attempt number.

What followed was a wedge:
- `move_commit` and every later `move_resume` were answered `move_unknown`.
- After 24 hours the worker recorded "has not confirmed the move".
- The source stayed a device and the candidate stayed in `receiving`, which
  has no expiry. No engine served the home until someone removed
  `moved.json` and reset the role.

**How likely.** The window was narrow. The offer had to be in transit past
the accept wait, the 5 s pause, and attempt 2's capture, stream and restore.
Nothing in Fermix's own code fenced it.

**The fix** (`OffersFenced`):
- `move_offer` carries the attempt.
- Move ids are ordered by when the move started.
- `fenced_offer/2` refuses an offer whose `{move_id, attempt}` is not above
  the held move's, as `move_mismatch` on that rail, and leaves the staged
  home untouched.

The same change answers a second `move_commit` after activation from the
`activated?` flag (`candidate.ex:639-643`). Before, it crashed in `put/3`,
because `activate/1` had removed `candidate/`. The model's `OnCommit` now
answers it `move_done`.

An earlier version of this spec also had a check with `OldRequestsArrive =
FALSE`: the rule held there while the fence was missing. With the fence,
check 04 holds with old requests arriving, a stronger setting, so that check
was dropped.

## Why an invariant and not "the move eventually completes"

The natural rule is liveness: a started move eventually ends, either done
with the candidate as the primary, or undone with the source as the primary.
It cannot hold here. Losing a message, a late answer and a crash are
environment steps, and rule 6 of `tla/README.md` gives them no fairness. A
run that loses every `move_commit` and `move_resume` the resume loop sends
never ends, and bounding the losses only hides that behind the bound.

What the design guarantees is a safety fact that keeps the end reachable. A
source that has written `moved.json` never goes back (`abort/3` re-reads the
marker and resumes). It leaves behind a candidate that holds the staged home,
and a single `move_commit` turns that candidate into the primary. The resume
loop keeps sending one, and a candidate rebooting in `activating` needs none.
`RetiredOnlyForStagedCandidate` states that fact. The resume loop and the
probe are the steps that use it, and witness 10 shows them completing a move
whose `move_done` was lost.

## Done

`Done` has two legitimate ends:
- **The move is done**: the source's boot as a device recorded `done` (or,
  when that write failed, a later `home.status` read in the same engine did),
  and the candidate booted as the primary.
- **The move is undone**: the source's boot as the primary recorded
  `aborted` with its worker gone, whatever the candidate holds. It never
  activated, and a candidate left staged or receiving waits, harmlessly, for
  a move that will not come. A crash between the role write and the
  `undoing` write boots the primary with `aborting`, which that boot turns
  into `aborted` too (`Finalize`).

The 24-hour bound on the resume loop is not modelled. When it runs out, the
worker records a sentence and exits, which changes no file a rule reads, and
the next boot resumes. A source whose budgets ran out therefore sits in the
loop. A dial or a probe is always enabled there, so it is never deadlocked and
needs no `Done` case. The wedge the finding caused was such a loop. The
deadlock check cannot see one, which is why the invariant must.

## Bounds

The checks run with one move, the code's three attempts, `MaxLosses = 2` and
`MaxCrashes = 1` per engine. Each check takes about a second; the largest,
checks 01, 04 and 12, explore 24,617 states.

Each `holds` check was run by hand with one more loss and one more crash
(`MaxLosses = 3`, `MaxCrashes = 2`): checks 01, 04 and 12 hold (133,773
states, about 2 s for the three together). With two more of each
(`MaxLosses = 4`, `MaxCrashes = 3`), check 04 still holds (382,801 states,
5 s).

## Not modelled

The `.tla` header lists what is left out:
- enrollment, and its 24-hour listen window;
- the stream's frames and their checks;
- the desktop key (in the secret store, its store and public half recorded
  in `.move/phase.json` first), its row, `desktop.json`, the switches in
  `machine.toml` (what the computer keeps on for its server), the request's
  `keep_offers`, and the snapshot file;
- the sleep guard the worker holds for its run (`MoveAwake`) and the staged
  plugin store's reinstall request (`Plugins.Dist.Reinstall`);
- the resume loop's 24-hour bound, and a link or switches write after the
  marker that fails at the commit and again on resuming: each ends the
  worker until the next boot, which resumes;
- a part-way marker write;
- a failed rename inside `activate/1` (retried on a timer; a resume meanwhile
  is refused, as for any candidate still activating);
- the one capture every attempt of a move sends again;
- a second move id (with one, the fence orders by attempt);
- the probe's own rail;
- the cast `put_phase/4` sends the Always On watch (`Home.StatusWatch`) once a
  phase is written, which writes nothing and which no step reads.

The worker's rail-level failures (a dial the network refuses) are the same,
to every rule, as a lost request followed by the worker's wait ending.

## Outside the model

This was noticed while reading the code. TLC does not show it.

- **A part-way marker write.** `Moved.write/2` creates `moved.json`
  exclusively, then writes it (`moved.ex:45-59`). If the write or the close
  fails (a full disk), the file may be left unreadable. `commit/4` then
  aborts, and `abort/3` raises on the unreadable marker
  (`move_worker.ex:845-851`). The worker's restart reaches `carry_on/3`'s
  clause for an unreadable marker (`:169`), which records a sentence asking for the
  marker to be fixed and does nothing else. The source stays a device and
  the candidate stays staged: safe, never two primaries, and stopped until a
  person acts. This is by design, since whether the home retired cannot be
  told.

## Re-read for the computer's key and switches (M97, 2026-11-10)

Re-read against db21a29d, which staled the `move_worker.ex`, `activation.ex`,
`move.ex` and `home_move.ex` pins:
- **The desktop key** moved from `device/desktop_key` to the secret store
  (`ComputerKey`). Before the key is stored, its store and public half are
  recorded in `.move/phase.json`, whose phase stays `streaming`; a restart
  reads that record, and an undo deletes only that key, logging and leaving
  one the store will not delete. None of these is a write a rule reads.
- **A key failure now aborts the move** where a key file failure tried
  again: `attempt_failed/2` aborts on `{:computer_key, _}` by name. The
  model had no abort before the offer, though the keychain's secrets and a
  capture with no room already aborted there. `AttemptAborts` adds it, under
  `TransferCanFail`. With it, every check keeps its verdict and every `needs`
  counterexample its length; the holds checks explore 24,617 states, up from
  24,579; witness 09 now takes it, a 10-state path where it was 12.
- **The switches** (`[fermix_core.computer]` in `machine.toml`, what the
  computer keeps on for its server) are written by `retired/4` between the
  link and `committing`, after the marker, and once by `resume/1`. They are
  read by no rule, and one that cannot be written ends the worker until the
  next boot as a link that cannot be written does.
- **`Move.start/5` and `HomeMove.move_start/3`** add `keep_offers` to the
  request, a field no rule reads.
- **`activation.ex`** changed only in a return's step c (`home_return`) and
  its moduledoc; the forward `activate/1` is as before.

The comments' line numbers for these four files had drifted before this
change too; they now point at the committed code.

## Re-read for a second computer and the server's lead on versions (M97, 2026-11-10)

Re-read against 16207ff5, which staled the `move_worker.ex`,
`activation.ex` and `device_supervisor.ex` pins:
- **The switches on a resume.** `resume/1` still writes the link, then the
  switches, then `committing`, but a source not kept as a computer is owed
  no switches and its `machine.toml` is no longer read. A switches write
  that fails, at the commit or on a resume, ends the worker with a sentence
  of its own where it shared the link's. An offer the request keeps that
  this engine does not know is left off and logged where it crashed the
  worker. None is a write a rule reads.
- **`activation.ex`** changed in a return's step c (`home_return`), its
  moduledoc and its aliases; the forward `activate/1` and `place_config/2`
  are as before.
- **The device tree** starts this computer's invocations (`Desktop.Invoke`)
  beside the dial subtree while the home is linked, and a joiner in the
  dial subtree only while this computer joins a home and has no link. The
  move worker still starts only while a move is pending, the first of the
  dial subtree's users after the helper.

No modelled step changed. The comments' line numbers into these files, and
into `role.ex` and `home_move.ex`, point at the committed code.
