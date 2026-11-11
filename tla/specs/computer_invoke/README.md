# computer_invoke: what the server asks of a computer

Models the invocation (M97 §5.2, §6.1 to §6.3): the server asks a computer
of the home to do something over that computer's session, and the computer
admits the request, journals it, runs it and answers. The session can drop
with words in flight, the computer can stop in the middle of a run, a held
answer can leave memory, the owner can switch everything off at the
computer, and the home can move on to a newer copy while an older one
still asks.

The scene is one computer and its server, with a call that changes
something on the computer (an effect) and a call that only reads.

The modules it describes:
- `FermixCore.Computers.Invocation` (whole), which `Computers.call/6` runs
  in the caller: a new id for every request (`mint_id`), registered before
  it is sent (`invoke`; two steps, so a session that starts between them
  asks about a request not sent yet), waited on at most its deadline and
  the link's allowance (`await`, `wait_left`, `gave_up`), and what a lost answer means
  (`lost?`, `again`): an effect ends there, a read is asked once more under
  a new id.
- `FermixCore.Computers.Calls` (whole): the waiters, which outlive a
  session, and the ids still waited on from a computer (`outstanding`).
- `FermixChannels.Desktop.InvokeFamily`: as the computer's next session
  starts it asks for the state of every id still waited on (`init`,
  `reconcile`), and hands each `invoke_result` to `Calls` (`handle_event`).
- `FermixChannels.Desktop.Invoke` and `Desktop.Invoke.Admission` (whole):
  the epoch check (`current_epoch`), the switches read at that moment
  (`switched_on`, `Invoke.switches_in`), the `started` record before the
  run (`start`), the `finished` record before the answer (`answer`,
  `record_finished`), the answers held for a status ask (`hold`, `status`),
  the journal's receipt after that (`from_journal`), the master switch off
  (`handle_cast :switches_changed`, `stopped`), and what a restart finds
  (`init`, `recover`).
- `FermixCore.Computers.Journal`: the two records (`append_started`,
  `append_finished`), each synced before the caller goes on (`append`,
  `write_line`), the read a status ask makes (`lookup`, `entries`), and
  the mark a restart leaves on what a crash left started (`interrupted`).
- `FermixChannels.Desktop.DeviceSupervisor`: `Desktop.Invoke` beside the
  dial subtree, never inside it (`children`, `invoke_spec`), so a relay or
  helper restart is a session that drops, not a computer that stops.
- `FermixCore.Computers.Switches`: a write of the switches tells Admission
  (`write`, `forget`, `notify`).
- `FermixChannels.Desktop.Relay`: a session with an older copy of the home
  is refused and a newer copy's epoch kept (`hello_ack`, `keep_epoch`),
  and each `invoke_*` event is handed to Admission as it came
  (`invocation`).

Not modelled, each covered elsewhere:
- the bound (8 running, 32 waiting, `busy` past it), an upload or an
  answer's part and the lanes it rides, and the bytes of anything
  (`invoke_test.exs`, `invoke_family_test.exs`, `lanes_test.exs`,
  `two_engines_invoke_test.exs`);
- a capability's own refusals and failures: its switch, its origin rules,
  the sandbox. Each is an answer like any other (`invoke_test.exs`);
- the computer's own deadline timer, which ends a run `timed_out` as a
  cancel ends it `cancelled`, and a long-lived request (a deadline of 0),
  which is waited on until it is cancelled;
- a caller that ends before its answer, for which `Calls` sends a cancel,
  and `Computers.cancel/2`: the cancel the deadline sends is the same step
  (`invocation_test.exs`);
- an id asked twice: the server never repeats one, and the computer
  answers one it still runs, waits on or holds as a status ask
  (`invoke_test.exs`). That is memory, not the journal: an id whose held
  answer is gone would run again, so the rule rests on the server and the
  link never repeating a request;
- a request that waits for a slot or for its upload. It is admitted as it
  arrives and starts later (`next`, `uploaded`) with no second look at the
  epoch or at any switch, so one can start in the moment after the master
  switch went off and before Admission hears; the hearing ends it, as it
  ends a run;
- a `machine.toml` changed by hand. Admission is told only by a write
  through `Switches`, so later requests are refused and what runs goes on;
- a link file that cannot be written: an epoch the relay could not keep in
  `device/desktop.json` is not the one Admission reads;
- a computer's own request to its server (the home's services);
- the switch going back on, a second computer, and a restart of the
  server's `Calls`, whose waiters time out;
- a journal that cannot be written: a `started` record that fails runs
  nothing (`invoke_test.exs`); a `finished` record that fails is logged and
  the answer still goes;
- a run admitted before the computer learned of a newer copy of its home.
  It finishes: the epoch is checked when a request is admitted.

## Pins

The `.tla` header pins these sources:

- `apps/fermix_core/lib/fermix_core/computers/invocation.ex`, whole;
- `apps/fermix_core/lib/fermix_core/computers/calls.ex`, whole;
- `apps/fermix_core/lib/fermix_core/computers/journal.ex`, by function:
  `append_started`, `append_finished`, `lookup`, `interrupted`,
  `close_all`, `append`, `write_line`, `entries`, `entry`;
- `apps/fermix_core/lib/fermix_core/computers.ex`, by function: `call`,
  `cancel`;
- `apps/fermix_channels/lib/fermix_channels/desktop/invoke.ex`, whole;
- `apps/fermix_channels/lib/fermix_channels/desktop/invoke/admission.ex`,
  whole;
- `apps/fermix_channels/lib/fermix_channels/desktop/invoke_family.ex`, by
  function: `init`, `handle_event`, `reconcile`, `outstanding`;
- `apps/fermix_channels/lib/fermix_channels/desktop/device_supervisor.ex`,
  by function: `children`, `invoke_spec`;
- `apps/fermix_core/lib/fermix_core/computers/switches.ex`, by function:
  `write`, `forget`, `notify`;
- `apps/fermix_channels/lib/fermix_channels/desktop/relay.ex`, by
  function: `hello_ack`, `keep_epoch`, `invocation`.

## Switches

| Switch | Kind | `TRUE` means |
|---|---|---|
| `SessionCanDrop` | environment | the session ends with words in flight: answers on their way are lost, requests on their way are lost or were already handed to Admission |
| `ComputerCanStop` | environment | the computer's Admission, or its engine, stops in the middle and starts again |
| `AnswersCanExpire` | environment | a held answer leaves memory (10 minutes, or the bounds of what is held) |
| `OwnerCanSwitchOff` | environment | the master switch goes off at the computer |
| `HomeCanMoveOn` | environment | the computer learns of a newer copy of its home while this server still asks |
| `JournalBeforeRun` | mechanism | the `started` record is synced before the run (`Admission.start/3`, `Journal.append_started/2`); `FALSE` writes the journal only when a request ends |
| `NoResendOfEffects` | mechanism | an effect whose answer is lost ends there (`Invocation.again/5`); `FALSE` asks it again, as a read is |
| `EpochCheck` | mechanism | a request from an epoch below the link's is refused (`Admission.current_epoch/2`); `FALSE` admits it |
| `SwitchReadAtAdmit` | mechanism | the switches are read as each request is admitted (`Admission.admit/2`, `Invoke.switches_in/1`); `FALSE` uses what was read when Admission started |
| `ServerDeadline` | mechanism | the caller waits at most its deadline and the link's allowance (`Invocation.await/5`, `gave_up/4`); `FALSE` waits for ever |

## What holds

`01_what_the_computer_keeps` (one effect, two ids at most, two drops, and
everything the environment can do) holds four rules:
- `EffectAtMostOnce`: whatever is lost, what a call changes on the computer
  happens at most once. It needs `NoResendOfEffects` (check 02, 12 states):
  a session starts between the effect's registration and its request, so
  the status ask finds no record and is answered `unknown`; asked again as
  a read would be, the request and its repeat both run. The same holds
  after a computer that stops in the middle, whose receipt says `unknown`,
  interrupted.
- `ActedIsJournaled`: whatever acted on the computer is in its journal at
  every moment, a stop included. It needs `JournalBeforeRun` (check 03, 5
  states): a run that acted has no record until it ends, so a stop there
  leaves none.
- `StaleEpochNeverActs`: no request from an older copy of the home is
  admitted. It needs `EpochCheck` (check 04, 6 states): a request handed to
  Admission as the session dropped is taken after the computer met the
  newer copy. The relay refuses a session with an older copy too; this is
  the request that was already inside.
- `OffAlwaysWins`: nothing starts while the master switch is off, and once
  Admission has heard, nothing runs. It needs `SwitchReadAtAdmit` (check
  05, 5 states): a request taken after the switch went off, and before
  Admission heard, starts.

`06_every_call_ends` (an effect and a read asked at once, one drop, a
computer that may stop and answers that may expire) holds `EveryCallEnds`:
every call ends, in the closed set. Fairness is only on what the server
drives: making a call, taking an answer that reached it, and its deadline.
It needs `ServerDeadline` (check 07): a computer that never answers, or a
session that never comes back, leaves the caller waiting.

Witnesses: a call whose session dropped while it waited is answered in
full once the session is back (08); an effect happens, the computer stops
before it answers, and the receipt the server asks for says only that the
outcome is not known (09); a read whose answer was lost runs again under a
new id and answers (10); a request from an older copy of the home is
refused by name and journaled (11); the master switch going off ends a
run, and its call hears it was stopped at the computer (12); an effect
runs, its answer leaves the computer's memory, and the receipt alone tells
the server it was done (13); a session starts between an effect's
registration and its request, the status ask finds no record, the call
ends not known, and the request, sent after that, runs once (14).

## Pinned (M97, 2026-11-10)

Read against 16207ff5, which committed the code, before the first pin:
- **Registering and sending are two steps.** `invoke/3` registers the id
  with `Calls` and only then sends `invoke_open`, and a session that starts
  between the two asks the computer about a request it was not sent yet
  (the reconcile's `invoke_status` and the caller's `invoke_open` reach the
  session from two processes, in either order). The computer answers that
  it has no record, `unknown`, and the caller takes that answer from its
  mailbox once it waits: an effect ends not known while its request, sent
  after, runs once; a read is asked again and runs twice. `Register` and
  `SendOpen` model the two steps, `Outstanding` counts a registered id, and
  witness 14 reaches the path. Check 02's shortest path is now this one.
- **The pins** name the journal's `append`, `write_line`, `entries` and
  `entry` (the sync and the read the steps rest on), `Switches.write`,
  `forget` and `notify` (how Admission hears the switch), and the relay's
  `hello_ack`, `keep_epoch` and `invocation` (the session refused for an
  older copy, the newer epoch kept, each event handed as it came).
- **The order a status ask relies on** holds because every `invoke_open` a
  capability here takes rides the interactive lane with `invoke_status` and
  `invoke_cancel`; a history submit's open would ride bulk, and a cancel or
  status ask could then pass it.

## Findings

None from TLC. Read beside the code, outside the model's steps:
- The race above is not a broken rule, but it costs the owner an effect
  whose outcome Fermix says it does not know though it ran.
- A request that waited for a slot or its upload can start after the master
  switch went off and before Admission hears (`next/1` and `uploaded/3`
  look at no switch), which `OffAlwaysWins` says never happens; the hearing
  ends it.
- An epoch the relay could not write to `device/desktop.json` is kept in
  the relay's memory only, so Admission, which reads the file, would admit
  a request from the older copy that was already inside.
