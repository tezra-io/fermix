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
  (`Role.resolve/2`, `role.ex:165-177`). Counting the next boot keeps the end
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
- `TransferCanFail`, before `move_ready`. Three failures fall under it:
  - an attempt fails at the source before its offer is out (the desktop key
    or row, or the capture), and the worker tries again;
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
  gives up on (`close_rail/1`, `move_worker.ex:208`, `:426`, `:439`), but
  `Rail.close/1` sends its close frame behind whatever the rail already sent
  (`rail.ex`). Whether the iroh helper still delivers what it holds once the
  socket closes ("the helper ends its stream on its own", `helper.ex`) is
  decided in the helper, outside this repo.

**Mechanism switches** (`TRUE` is the real code):
- `CandidateWaitsForCommit`: the candidate activates only on `move_commit`
  for the move it staged (`commit_move/2`, `candidate.ex:503-536`).
- `MarkerBeforeCommit`: the worker writes `moved.json` and records
  `committing` before it sends `move_commit` (`commit/4`, then `retired/4`,
  `move_worker.ex:420-442`).
- `OffersFenced`: the candidate takes an offer only when it is later than the
  move it holds, a later move id or a later attempt of the same move, and
  refuses an earlier or equal one (`move_mismatch`), leaving what it holds
  untouched (`fenced_offer/2`, `later?/2`, `candidate.ex:400-412`).
  `move_offer` carries the attempt (`stream/3`, `move_worker.ex:370`), which
  only grows across restarts. Move ids are ordered by when the move started
  (`move_id/1`, `move.ex:505-514`); with one move id, the fence orders by
  attempt.
- `ReadyAfterStaged`: `move_ready` goes out only after `staged` is written.
  `restored/2` records `staged`, then tells the responder
  (`candidate.ex:481-487`), which answers `move_ready` only then
  (`move_responder.ex:65-69`).
- `AwaitPinsRail`: the worker takes an answer only from the rail it waits on
  (`await_any/3` matches `{:rail, ^rail, _}`, `move_worker.ex:742-755`).
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
- a refusal or the attempt cap, in `transfer/1` and `attempt_failed/2`,
  which run only while the marker is absent;
- `commit/4`'s error clause, after the ready epoch or the marker could not
  be written (`move_worker.ex:425-427`);
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
switched off breaks `RetiredOnlyForStagedCandidate` (26,486 and 29,530 states
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
- **09**: the move is undone (the restore fails, the candidate refuses, the
  source aborts) and the source boots as the primary again.
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
- `EndingsAfterRestart` (check 13: a 545-state search finds the
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
`activated?` flag (`candidate.ex:505-509`). Before, it crashed in `put/3`,
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
checks 01, 04 and 12, explore 24,579 states.

Each `holds` check was run by hand with one more loss and one more crash
(`MaxLosses = 3`, `MaxCrashes = 2`): checks 01, 04 and 12 hold (133,698
states, about 1 s each). With two more of each (`MaxLosses = 4`,
`MaxCrashes = 3`), check 04 still holds (382,677 states, 4 s).

## Not modelled

The `.tla` header lists what is left out:
- enrollment, and its 24-hour listen window;
- the stream's frames and their checks;
- the desktop key, its row, `desktop.json` and the snapshot file;
- the sleep guard the worker holds for its run (`MoveAwake`) and the staged
  plugin store's reinstall request (`Plugins.Dist.Reinstall`);
- the resume loop's 24-hour bound;
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
  (`move_worker.ex:658-664`). The worker's restart reaches `carry_on/3`'s
  clause for an unreadable marker (`:154`), which records a sentence asking for the
  marker to be fixed and does nothing else. The source stays a device and
  the candidate stays staged: safe, never two primaries, and stopped until a
  person acts. This is by design, since whether the home retired cannot be
  told.
