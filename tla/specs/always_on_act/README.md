# always_on_act: every Always On step through one act

Models Always On's steps (Always On setup §3.4, §5): every step a surface
asks for is one `home.act`, which `Management.AlwaysOn.act/2` runs in one
serializer per engine. The act reads the summary first and runs the step
only when the summary offers that action under the key it was drawn with
(`HomeSummary.find_action/3`).

The scene is Restore here on a linked desktop whose server went silent, the
one step that starts a job of the family. Two surfaces press at once. The
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
  (`restore_offer`). `offered` and `find_action` read what a screen offers.

Not modelled, each covered elsewhere:
- the other steps of `home.act` (Move back, Move now, Cancel and the rest):
  one act each through the same serializer and key rule, with no job of the
  family (`always_on_test.exs`; `home_return` models the move back's);
- the run itself (`LocalReturn.restore/3`), its candidate, which draws
  moving once written, and the restart its success ends in (`home_return`);
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
  `restore_running?`, `restore_offer`;
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
