# always_on_act: every Always On step through one act

Models Always On's steps (Always On setup §3.4, §4, §5, §10): every step a
surface asks for is one `home.act`, which `Management.AlwaysOn.act/2` runs
in one serializer per engine. The act reads the summary first and runs the
step only when the summary offers that action under the key it was drawn
with (`HomeSummary.find_action/3`); a step that starts a job names it in the
provisioner's ledger first (`Provision.put_action/2`) and clears the name
again when the start is refused.

The scene is a linked desktop replacing the server Fermix created, where
every rule meets: two surfaces press at once, the job family's run writes the
same ledger, a `home.status` read starts the family's reconcile, Cancel stops
a create and deletes what it made, Move now sends `home.move.start` to the
old server over the link and keeps the replace's move, and the desktop relay
reports the epoch it reaches, after which the old server is deleted
(`Provision.primary_reached/2`).

The modules it describes:
- `FermixCore.Management.AlwaysOn` (whole): the serializer, the key rule, the
  step's name before its job, a refused start's clear, Cancel during a create
  (stop the job, wait for its run, clear the name, delete what stands), and
  the forwarded Move now with its bookkeeping.
- `FermixCore.Management.Provision`: `put_action`, `clear_action`,
  `holding`, `stop_step`, the family's job wrapper (`start`, which gives a
  step's job its ending) and a step's one ending (`ended`, `ending`: the
  failure the run answered, or the interruption of a run that answered
  nothing, then the name cleared, in one write), `delete`, `move_forwarded`
  (`started?`, `record_move`) and `primary_reached` (`reached`,
  `run_clean_up`).
- `FermixCore.Home.Provision.Ledger`: `put_action` (refused while a live
  step's name stands), `clear_action`, `end_step` and `interrupt` (what a
  step's ending writes), `move_started`, `replace_due` and `moved`.
- `FermixCore.Management.Jobs`: one running job per kind and name
  (`running?`), `cancel`, which answers after the run's `:DOWN`
  (`cancel_job`, `stop_job`, `task_down`, `stopped`), and a job's ending,
  which the family runs however the run ended, before the job leaves
  running (`finish`, `begin_ending`, `end_closing`).
- `FermixCore.Management.HomeSummary`: the actions a desktop's summary offers
  during a replace (`running`, `running_step`, `replace_moving`,
  `new_server_step`, and `cleanup`, the ready new server's Delete, which the
  spec's Cancel stands for), `offered` and `find_action`.
- The old server (its `home.move.start` and its move) and the desktop relay
  (`Desktop.Relay`, which calls `primary_reached/2` at each session's epoch)
  are **unpinned mirrors**: the old server takes a forwarded
  `home.move.start` and moves, serving nothing meanwhile, and the new one
  answers at a higher epoch once the move is done.

Not modelled, each covered elsewhere:
- the server created on the primary rather than replaced: the same act, job,
  cancel and ledger with no link (`always_on_test.exs`);
- Start again, Create in, Turn it on and Restart server: one job each, started
  as `job` starts the create and the delete (`always_on_test.exs`);
- `Provision.delete`'s own refusal while a move runs (`delete_target`), a
  second guard behind the key rule (`provision_test.exs`);
- a step's name outliving its job's budget, read as interrupted, and the
  boot's `interrupt_left_actions/1` (`ledger_test.exs`, `provision_test.exs`);
- the old server undoing the move, and a failed delete of it;
- the summary's words and keys beyond which actions it offers: a key is the
  set of actions the screen was drawn with (`Offered`).

## Pins

The `.tla` header pins these sources by hash, so `make -C tla check` reports
the spec STALE when one of them changes:

- `apps/fermix_core/lib/fermix_core/management/always_on.ex`, whole;
- `apps/fermix_core/lib/fermix_core/management/provision.ex`, by function:
  `put_action`, `clear_action`, `holding`, `stop_step`, `start`, `ended`,
  `ending`, `delete`, `move_forwarded`, `started?`, `record_move`,
  `primary_reached`, `reached`, `run_clean_up`;
- `apps/fermix_core/lib/fermix_core/home/provision/ledger.ex`, by function:
  `put_action`, `clear_action`, `end_step`, `interrupt`, `live_action?`,
  `move_started`, `replace_due`, `moving?`, `moved`;
- `apps/fermix_core/lib/fermix_core/management/jobs.ex`, by function:
  `start`, `cancel`, `handle_call`, `start_job`, `cancel_job`, `stop_job`,
  `task_down`, `stopped`, `finish`, `begin_ending`, `end_closing`,
  `running?`;
- `apps/fermix_core/lib/fermix_core/management/home_summary.ex`, by function:
  `offered`, `find_action`, `running`, `running_step`, `replace_moving`,
  `new_server_step`, `cleanup`.

## Switches

| Switch | Kind | `TRUE` means |
|---|---|---|
| `StepCanFail` | environment | the provider refuses a create or a delete |
| `AnswerCanBeLost` | environment | the old server had the move's start and its answer was lost (`unconfirmed`) |
| `LinkCanDrop` | environment | the link is down: the old server never had the request |
| `ReadsReconcile` | environment | a `home.status` read starts the family's reconcile |
| `RunCanCrash` | environment | a step's run raises, exits or is killed before it answers |
| `Serialized` | mechanism | acts run one at a time in the `AlwaysOn` process (`act/2`'s call, `handle_call`) |
| `KeyRule` | mechanism | the act runs only an action the summary offers now (`find_action/3`); `FALSE` runs what the surface drew |
| `JobsBusy` | mechanism | the family runs one job at a time (`Jobs.running?`) |
| `UnstartedClears` | mechanism | a start refused after the name was written clears it (`AlwaysOn.unstarted`) |
| `ClearOnEnd` | mechanism | a step's ending clears its name (`Provision.ended/3`, `:clears_action`) |
| `KeepFailure` | mechanism | a step that stopped keeps its failure in the ledger: the one its run answered, or the interruption of one that answered nothing |
| `OwnerEnds` | mechanism | the job family runs the step's ending however its run ended (`Jobs`' `:ending`), a run that crashed, exited or was killed included; `FALSE` ends only a run that answered, as a task-local `after` would |
| `CancelWaits` | mechanism | `Jobs.cancel/2` answers after the run's `:DOWN`, the job counted running until then |
| `RecordOnAnswer` | mechanism | the replace's move is kept only once the old server had it, started or unconfirmed (`move_forwarded`'s `started?`) |
| `EpochGuard` | mechanism | the old server is cleaned up only for an epoch above its own (`replace_due/2`, `moved/3`) |

## What holds

`01_one_run_and_endings` (two surfaces, two presses each, two reports, one
read, runs that may crash): one run of the family lives at a time (`AtMostOneRun`, needs
`JobsBusy`), the delete a cancel starts never runs beside the create it
stopped (`NoDeleteBesideCancelled`, needs `CancelWaits`), a step's name stands
only while its step runs or its act is between the name and the start
(`ActionMeansStep`, needs `ClearOnEnd` and `UnstartedClears`), and every
ending is kept, a run that crashed, exited or was killed included
(`EndingKept`, needs `KeepFailure` and `OwnerEnds`).

`07_move_rules` (the same bounds): no delete removes the server a move goes
to (`CancelNeverDeletesMoveTarget`, needs `KeyRule` and `Serialized`), the
replace's move is kept at most once (`RecordedOnce`, needs `KeyRule` and
`Serialized`) and only when the old server had it (`RecordedOnlyWhenHad`,
needs `RecordOnAnswer`), and the old server is deleted only after a newer
epoch answered (`OldDeletedAfterNewer`, needs `EpochGuard`).

Witnesses: a cancel waits while the create's run still lives; a Move now whose
answer was lost is kept as started; a press on a screen another surface
changed is answered `changed`; the move completes and the old server is
deleted.

An ordering the first draft of this spec reached, and the code already
handles: the old server answers Move now, the move completes, the relay
reaches the new server and the clean-up deletes the old one, all before the
act keeps the move. `Ledger.move_started/3` then finds no replace waiting
(`:nothing`), and the summary reads the replace as done (`on`), which offers
no Cancel, so nothing deletes the new server.

Run once by hand with one more surface (three surfaces, two presses each, two
reports, one read, runs that may crash), every rule of both checks together:
no error, 8,983,692 distinct states, about a minute and a half on two workers.

## Findings

None.
