# always_on_act: every Always On step through one act

Models Always On's steps (Always On setup §3.4, §5): every step a surface
asks for is one `home.act`, which `Management.AlwaysOn.act/2` runs in one
serializer per engine. The act reads the summary first and runs the step
only when the summary offers that action under the key it was drawn with
(`HomeSummary.find_action/3`).

The scene is Restore here on a linked desktop the home moved from (its
moved marker) whose server went silent, and whose Fermix reads the server's
home: the one step that starts a job of the family. Two surfaces press at once. The
act keeps its request in `return.json` before the `home_restore` job starts,
and takes it back when the start is refused. The job's ending takes it back
however the run ended, while the family still counts the job running.

The modules it describes:
- `FermixCore.Management.AlwaysOn` (whole): the serializer, the key rule,
  Restore here's request (`restore_record`, `keep_record`), its job and the
  job's ending (`start_restore`, `request_done`), and the request taken back
  when the start is refused busy.
- `FermixCore.Management.Jobs`: one running job per kind and name, and a
  few at most in all (`handle_call {:start, ...}`, `running?`,
  `running_count`), and a job's ending, which the family runs once the run
  is over however it ended (`complete_task`, `task_down`, `finish`,
  `begin_ending`), the job counted running until the ending is done
  (`ending_done`, `ending_down`, `end_closing`).
- `FermixCore.Management.HomeSummary` and `FermixCore.Management.Home`:
  `restoring` draws the restore running, with nothing to press, while its
  request stands beside its running job (`restore_running?`, `Home`'s
  `restoring?`); elsewhere a silent server offers Restore here
  (`restore_offer`) on the computer the home moved from. `offered` and `find_action` read what a screen offers.

Not modelled, each covered elsewhere:
- the other steps of `home.act` (Move back, Move now, Cancel, the review of
  what a computer keeps on for its server, adding a computer and the
  owner's answer to one that asks to join, and the rest): one act each
  through the same serializer and key rule, with no job of the family
  (`always_on_test.exs`; `home_return` models the move back's);
- a computer that joined the home, which has no moved marker and is offered
  neither Move back nor Restore here, and one whose Fermix cannot read the
  server's home, which is offered Update in their place: neither has the
  press this scene starts with (`home_summary_test.exs`);
- the run itself (`LocalReturn.restore/3`), its candidate, which draws
  moving once written, the restart its success ends in, and what the ending
  settles after a run stopped from outside (`home_return`);
- which sentence a busy refusal says (a restore runs, or other work fills
  the family): the request is taken back either way (`always_on_test.exs`);
- an engine that stops while the job runs: it leaves the request beside no
  job, which the summary draws as nothing (`home_return`'s
  `RequestBesideJob`);
- an ending that cannot write `return.json` (it logs), one that raises
  (`jobs_test.exs`), or one that outlives its bound and is killed: the
  request then stands beside no job, as above;
- the copy's choice and the passphrase, read before anything is written
  (`always_on_test.exs`), and an act past its deadline;
- the summary's words and keys beyond which actions it offers: a key is the
  set of actions the screen was drawn with (`Offered`).

## Pins

The `.tla` header pins these sources by hash, so `make -C tla check` reports
the spec STALE when one of them changes:

- `apps/fermix_core/lib/fermix_core/management/always_on.ex`, whole;
- `apps/fermix_core/lib/fermix_core/management/jobs.ex`, by function:
  `start`, `handle_call`, `start_job`, `running?`, `running_count`,
  `complete_task`, `task_down`, `finish`, `begin_ending`, `ending_done`,
  `ending_down`, `end_closing`;
- `apps/fermix_core/lib/fermix_core/management/home_summary.ex`, by
  function: `offered`, `find_action`, `device`, `restoring`,
  `restore_running?`, `restore_offer`, `readable_or_update`;
- `apps/fermix_core/lib/fermix_core/management/home.ex`, by function:
  `restoring?`.

## Switches

| Switch | Kind | `TRUE` means |
|---|---|---|
| `RunCanCrash` | environment | the run raises, exits or is killed before it answers |
| `Serialized` | mechanism | acts run one at a time in the `AlwaysOn` process (`act/2`'s call, `handle_call`) |
| `KeyRule` | mechanism | the act runs only an action the summary offers now (`find_action/3`); `FALSE` runs what the surface drew |
| `JobsBusy` | mechanism | the family refuses a start beside a running job of the kind (`running?/3`), a job in its ending included |
| `UnstartedClears` | mechanism | a start refused busy takes the request back (`start_restore/3`'s `:busy`, `request_done/1`) |
| `ClearOnEnd` | mechanism | the job's ending takes the request back (`start_restore/3`'s `:ending`, `request_done/1`) |
| `OwnerEnds` | mechanism | the job family runs the ending however the run ended (`Jobs`' `:ending`), a run that crashed, exited or was killed included; `FALSE` ends only a run that answered, as a task-local `after` would |

## What holds

`01_one_job_and_its_request` (two surfaces, two presses each, runs that may
crash) holds three rules:
- `AtMostOneJob`: one Restore here job counts running at a time, its ending
  included. It needs `JobsBusy` (check 02, 16 states): once the first job's
  ending took the request back, the screen no longer draws the restore
  running, so a second press passes the key rule while that job is still in
  its ending.
- `RequestMeansRestore`: the request stands only while its job runs, or
  while its act is between the request and the start's answer. It needs:
  - `UnstartedClears` (check 03, 18 states): that second press is refused
    busy and leaves its request behind once the first job closes;
  - `ClearOnEnd` (check 04, 10 states): a job that ends leaves its request;
  - `OwnerEnds` (check 05, 8 states): a run that crashed gets no ending.
- `RestoreMeansRequest`: while a run lives, its request stands, so the
  screen says the restore runs from the press on. It needs:
  - `KeyRule` (check 06, 15 states): a screen drawn between the first act's
    request and its job's start still offers Restore here; pressed after
    the job started, it is refused busy, which takes the running restore's
    request back;
  - `Serialized` (check 07, 14 states): a second act's check runs between
    the first's request and its start, with the same end.

Witnesses: a press on a screen another surface changed is answered
`changed` (08); a Restore here pressed while the job before it is still in
its ending is refused busy (09); a run that crashed is ended by the family
and its request taken back (10).

## Findings

None.

## Re-read for the computer's switches (M97, 2026-11-10)

Re-read against db21a29d, which staled the `always_on.ex` pin. The act
gained `review_offers`, the review of what a computer that moved before M97
keeps on for its server: a step of `step/3`, run after the key rule like
the others, which writes the computer's switches in `machine.toml` and
starts no job. Move now from the computer that sets Always On up casts its
`keep_offers` input before `HomeMove.move_start/3`, refusing an unknown one
before the move starts. Restore here's request, its job, the busy
refusal and the ending are as before, so nothing the spec models changed.
The comments' line numbers into `always_on.ex`, and into `home_summary.ex`
and `home.ex`, which the same commit changed, had drifted before it too;
they now point at the committed code.

## Re-read for a second computer and the server's lead on versions (M97, 2026-11-10)

Re-read against 16207ff5, which staled the `always_on.ex` and
`home_summary.ex` pins. The act gained three steps, each run after the key
rule like the others and none starting a job: `add_computer`, and
`approve_computer` and `deny_computer` for a computer that asks to join;
`cancel` on a computer that is joining ends the join. The serializer, the
key rule, Restore here's request, its job, the busy refusal and the ending
are as before. The summary now offers Restore here only on the computer the
home moved from, and offers Update in its place where this computer's
Fermix cannot read the server's home; a computer joining draws its own
screen ahead of the others. The modelled desktop is one the home moved from
that reads its server's home, which the scene now says, so no modelled step
changed; the `home_summary.ex` pin now names `readable_or_update`, whose
answer the scene takes as read. The comments' line numbers into
`always_on.ex`, `home_summary.ex` and `home.ex` point at the committed code.

## Re-read for the review's fixes (M97, 2026-11-11)

Re-read against c6fe1c48, which staled the `always_on.ex` pin. Try again
with no block ticked (its undone screen offers none) now moves with the keep
the undone move started with, read from that move's phase
(`Move.undone_keep/1`), not the engine's proposal: a field of the request
no rule reads. The serializer, the key rule, Restore here's request, its
job, the busy refusal and the ending are as before. The comments' line
numbers into `always_on.ex` point at the committed code.

## Re-read for the computer's switches (M97 D27, 2026-11-12)

Re-read against 101830533, which staled the `always_on.ex` pin: a move's
kept lines now set the recorder through the history line, and an earlier
app's `files` and `shell` keep files and commands on only together
(`Consent.known/1`). Fields of the request and switches no rule reads; no
modelled step changed. The comments' line numbers into `always_on.ex` point
at the committed code.

## Re-read for the Always On pane's engine half (M97, 2026-11-12)

Re-read against 8e3f586f, which staled the `always_on.ex` and
`home_summary.ex` pins. The act gains `change_passphrase` (the backup
settings' Change: a new recovery passphrase set here, or sent to the
server), run after the key rule like the others and starting no job, and
`offered/1` reads the screen's action, its alternatives and that Change;
`own_server` answers a sentence and a tailnet label; `review_offers` with no
`keep_offers` keeps the switches as they are. The serializer, the key rule,
Restore here's request, its job, the busy refusal and the ending are as
before, so no modelled step changed. The comments' line numbers into both
files point at the committed code.

## Re-read for one set of settings after a move (M97 D28, 2026-11-13)

Re-read for M97 D28, which stales the `always_on.ex` and `jobs.ex` pins.
The act gains `restart_server` (Restart <server> on a linked computer),
which sends the rail-only `home.restart` to the server, runs after the key
rule like the others and starts no job; an answer lost to the server's own
restart is `unconfirmed`, as a move's start is. In `jobs.ex`, `start_job`
mints an id that names the computer on a computer linked to its server
(`computer.job:<id>`), so that computer answers `job.get` and `job.cancel`
of its own jobs; the id is opaque to the model. The serializer, the key
rule, Restore here's request, its job, the busy refusal and the ending are
as before, so no modelled step changed. The comments' line numbers into
`always_on.ex` point at the committed code.

## Re-read for the review's fixes (M97, 2026-11-14)

Re-read against f2d5efc5 and efcfa64f, which staled the `always_on.ex` and
`jobs.ex` pins. `restart_server` answers a server reply it does not read as
`unavailable` with a sentence of its own, never as a restart under way; a
job names what an install installs (`target`, stored at `start/2`, required
of `capability_install` and `browser_install` and refused for every other
kind, Restore here's `home_restore` among them, which names none). Neither
is a step of the model: the serializer, the key rule, Restore here's
request, its job, the busy refusal and the ending are as before. The
comments' line numbers into both files point at the committed code.

## Re-read for voice and attachments from a computer (M97 stage A, 2026-11-14)

Re-read against 4c58837a, which staled the `always_on.ex` pin: Move now on a
move back ends the app's call bridged to the server and drops its uploads
before `home.move.start` leaves (`end_for_return/0`), a step of the move back
this spec does not model (`home_return` does). The serializer, the key rule,
Restore here's request, its job, the busy refusal and the ending are as
before. The comments' line numbers into `always_on.ex` point at the
committed code.
