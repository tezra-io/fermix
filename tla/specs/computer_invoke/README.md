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
  it is sent (`invoke`), waited on at most its deadline and the link's
  allowance (`await`, `wait_left`, `gave_up`), and what a lost answer means
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
  `append_finished`), the read a status ask makes (`lookup`), and the mark
  a restart leaves on what a crash left started (`interrupted`).
- `FermixChannels.Desktop.DeviceSupervisor`: `Desktop.Invoke` beside the
  dial subtree, never inside it (`children`, `invoke_spec`), so a relay or
  helper restart is a session that drops, not a computer that stops.

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
  answers one it knows as a status ask (`invoke_test.exs`);
- a computer's own request to its server (the home's services);
- the switch going back on, a second computer, and a restart of the
  server's `Calls`, whose waiters time out;
- a journal that cannot be written: nothing runs (`invoke_test.exs`);
- a run admitted before the computer learned of a newer copy of its home.
  It finishes: the epoch is checked when a request is admitted.

## Pins

The `.tla` header names these sources. They are **not pinned yet**: the
code is uncommitted, and a pin names code that exists in history. Until
`make -C tla repin SPECS=computer_invoke` runs after the commit, every run
reports the spec STALE.

- `apps/fermix_core/lib/fermix_core/computers/invocation.ex`, whole;
- `apps/fermix_core/lib/fermix_core/computers/calls.ex`, whole;
- `apps/fermix_core/lib/fermix_core/computers/journal.ex`, by function:
  `append_started`, `append_finished`, `lookup`, `interrupted`,
  `close_all`;
- `apps/fermix_core/lib/fermix_core/computers.ex`, by function: `call`,
  `cancel`;
- `apps/fermix_channels/lib/fermix_channels/desktop/invoke.ex`, whole;
- `apps/fermix_channels/lib/fermix_channels/desktop/invoke/admission.ex`,
  whole;
- `apps/fermix_channels/lib/fermix_channels/desktop/invoke_family.ex`, by
  function: `init`, `handle_event`, `reconcile`, `outstanding`;
- `apps/fermix_channels/lib/fermix_channels/desktop/device_supervisor.ex`,
  by function: `children`, `invoke_spec`.

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
  happens at most once. It needs `NoResendOfEffects` (check 02, 11 states):
  the run acts, the session drops, the computer stops, and the server's
  status ask after the reconnect is answered with the journal's receipt
  alone (`unknown`, interrupted); asked again as a read would be, the
  effect happens a second time.
- `ActedIsJournaled`: whatever acted on the computer is in its journal at
  every moment, a stop included. It needs `JournalBeforeRun` (check 03, 4
  states): a run that acted has no record until it ends, so a stop there
  leaves none.
- `StaleEpochNeverActs`: no request from an older copy of the home is
  admitted. It needs `EpochCheck` (check 04, 5 states): a request handed to
  Admission as the session dropped is taken after the computer met the
  newer copy. The relay refuses a session with an older copy too; this is
  the request that was already inside.
- `OffAlwaysWins`: nothing starts while the master switch is off, and once
  Admission has heard, nothing runs. It needs `SwitchReadAtAdmit` (check
  05, 4 states): a request taken after the switch went off, and before
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
the server it was done (13).

## Findings

None.
