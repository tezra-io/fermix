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
  allowance (`await`, `wait_left`, `gave_up`), its state asked for by the
  caller itself when told a new session began, once its request was sent
  and from the process that sent it (`await`'s `:reconnected`,
  `ask_again`), and what a lost answer means (`lost?`, `again`): an effect
  ends there, a read is asked once more under a new id.
- `FermixCore.Computers.Calls` (whole): the waiters, which outlive a
  session, and the word to each caller still waiting on a computer that a
  new session began (`reconnected`, `tell_reconnected`).
- `FermixChannels.Desktop.InvokeFamily`: as the computer's next session
  starts it tells `Calls` (`init`, `reconcile`), and hands each
  `invoke_result` to `Calls` (`handle_event`).
- `FermixChannels.Desktop.Invoke` and `Desktop.Invoke.Admission` (whole):
  the epoch check (`current_epoch`), the switches read at that moment
  (`switched_on`, `Invoke.switches_in`) and again when a request that
  waited for a slot or its upload would start (`next`, `uploaded`,
  `waited`), the `started` record before the run (`start`), the `finished` record before the answer (`answer`,
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
  is refused and a newer copy's epoch kept in `device/desktop.json`, the
  one place it lives, before anything relies on it; a newer epoch it
  cannot write leaves that session unused (`hello_ack`, `connected`,
  `keep_epoch`), and each `invoke_*` event is handed to Admission as it
  came (`invocation`).
- `FermixChannels.Mobile.Lanes` (whole): a request's own `invoke_status`
  and `invoke_cancel` name its capability and op and ride its lane
  (`@header_fields`, `@follow_request`, `lane` and the `interactive?` and
  `bulk?` guards it reads), so neither passes it on the link.
- The browser's requests (`FermixCore.Computers.Capabilities.Browser.run/4`
  and `FermixCore.Browser.HeldTurn`, whole): each runs in the held process
  that stands for its server turn on the computer, linked to the run that
  made it for as long as it runs (`handle_call {:run, fun}`, `link/1`), so
  whatever ends the run ends the request there, and a request whose run
  ended before the held process took it is never started (`Held`,
  `HeldEndsWithRun`; INVOKE-1, fixed).

Not modelled, each covered elsewhere:
- the bound (8 running, 32 waiting, `busy` past it), the relay's 512
  events for Admission (an event it drops is one never taken, which no
  step here owes), an upload or an answer's part and the lanes it rides,
  and the bytes of anything (`invoke_test.exs`, `invoke_family_test.exs`,
  `lanes_test.exs`, `two_engines_invoke_test.exs`): a request that waits
  for a slot or its upload is one step here (`Queue`, the second branch of
  `Open`), and starts later (`StartQueued`);
- a capability's own refusals and failures: its switch, its origin rules,
  the sandbox. Each is an answer like any other (`invoke_test.exs`);
- the computer's own deadline timer, which ends a run `timed_out` as a
  cancel ends it `cancelled`, and a long-lived request (a deadline of 0:
  `screen.watch`, `imessage.watch`), which holds a running slot for as long
  as it waits (one `imessage.watch` at a time, a newer one ending the
  older; a `screen.watch` until the seat's hold ends) and is waited on
  until its caller ends or an answer comes. One whose run a restart of
  Admission ended is answered by that restart (`Stop`, the journal's
  receipt), so a watch is asked again at once (`two_engines_invoke_test.exs`);
  `EveryCallEnds` is about calls with a deadline and does not cover a
  watch;
- a caller that ends before its answer, for which `Calls` sends a cancel
  (`abandoned/2`), after the request the caller itself sent: the cancel the
  deadline sends is the same step (`invocation_test.exs`). `Computers.cancel/2`,
  a cancel sent from `Calls` that could pass its request, is gone: nothing
  called it, and a caller stops what it asked by ending;
- the browser switch, and `Browser.HeldTurnListener` (the switches' fourth
  listener), which ends every held turn when the master or the browser
  switch goes off: a turn that runs no request holds nothing this spec
  sees, and one at work ends with its run, both ways, since the two are
  linked: a held turn the listener ends takes its run with it, which
  Admission then answers `failed` ("It stopped before it finished."),
  unless it had already ended that run itself on the master switch
  (`held_turn_listener_test.exs`, `two_engines_browser_test.exs`). So does
  the rule that a conversation's next turn ends the turn held before it,
  which is about whose pane task a request runs in, not whether it runs
  (`held_turn_test.exs`);
- an id asked twice: the server never repeats one, and the computer
  answers one it still runs, waits on or holds as a status ask
  (`invoke_test.exs`). That is memory, not the journal: an id whose held
  answer is gone would run again, so the rule rests on the server and the
  link never repeating a request;
- a `machine.toml` changed by hand. Admission is told only by a write
  through `Switches`, so later requests are refused and what runs goes on;
- a link file that cannot be written: the relay does not use the newer
  copy's session (`connected`, `keep_epoch`), so it is no `MoveOn`, and the
  relay and Admission read one epoch, the file's;
- a computer's own request to its server (`history.submit`, M97 §8.1):
  `Desktop.HistoryUplink` opens it, waits on it and cancels it in the
  process that sends it, under an id of its own, outside Admission's
  journal, epoch check and runs; Admission only hands its `invoke_result`
  on. Why no rule here depends on it is in the last re-read below;
- the switch going back on, a second computer, and a restart of the
  server's `Calls`, whose waiters time out;
- a journal that cannot be written: a `started` record that fails runs
  nothing (`invoke_test.exs`); a `finished` record that fails is logged and
  the answer still goes;
- a run admitted before the computer learned of a newer copy of its home.
  It finishes: the epoch is checked when a request is admitted, not again
  when one that waited starts;

## Pins

The `.tla` header pins these sources:

- `apps/fermix_core/lib/fermix_core/computers/invocation.ex`, whole;
- `apps/fermix_core/lib/fermix_core/computers/calls.ex`, whole;
- `apps/fermix_core/lib/fermix_core/computers/journal.ex`, by function:
  `append_started`, `append_finished`, `lookup`, `interrupted`,
  `close_all`, `closed_entry`, `append`, `write_line`, `entries`, `entry`;
- `apps/fermix_core/lib/fermix_core/computers.ex`, by function: `call`;
- `apps/fermix_channels/lib/fermix_channels/desktop/invoke.ex`, whole;
- `apps/fermix_channels/lib/fermix_channels/desktop/invoke/admission.ex`,
  whole;
- `apps/fermix_channels/lib/fermix_channels/desktop/invoke_family.ex`, by
  function: `init`, `handle_event`, `reconcile`;
- `apps/fermix_channels/lib/fermix_channels/desktop/device_supervisor.ex`,
  by function: `children`, `invoke_spec`;
- `apps/fermix_core/lib/fermix_core/computers/switches.ex`, by function:
  `write`, `forget`, `notify`;
- `apps/fermix_channels/lib/fermix_channels/desktop/relay.ex`, by
  function: `hello_ack`, `connected`, `keep_epoch`, `invocation`;
- `apps/fermix_channels/lib/fermix_channels/mobile/lanes.ex`, whole: the
  lane a request's status ask and cancel ride is decided by the
  `interactive?` and `bulk?` guards, which a definition pin cannot name;
- `apps/fermix_core/lib/fermix_core/computers/capabilities/browser.ex`, by
  function: `run`;
- `apps/fermix_core/lib/fermix_core/browser/held_turn.ex`, whole.

## Switches

| Switch | Kind | `TRUE` means |
|---|---|---|
| `Held` | scene | (a set of calls) the calls that are the browser's, each run in its server turn's held process; `{}`, every other capability, in every check but 17 and 18 |
| `SessionCanDrop` | environment | the session ends with words in flight: answers on their way are lost, requests on their way are lost or were already handed to Admission |
| `ComputerCanStop` | environment | the computer's Admission, or its engine, stops in the middle and starts again |
| `AnswersCanExpire` | environment | a held answer leaves memory (10 minutes, or the bounds of what is held) |
| `OwnerCanSwitchOff` | environment | the master switch goes off at the computer |
| `HomeCanMoveOn` | environment | the computer learns of a newer copy of its home while this server still asks |
| `JournalBeforeRun` | mechanism | the `started` record is synced before the run (`Admission.start/3`, `Journal.append_started/2`); `FALSE` writes the journal only when a request ends |
| `NoResendOfEffects` | mechanism | an effect whose answer is lost ends there (`Invocation.again/5`); `FALSE` asks it again, as a read is |
| `EpochCheck` | mechanism | a request from an epoch below the link's is refused (`Admission.current_epoch/2`); `FALSE` admits it |
| `SwitchReadAtAdmit` | mechanism | the switches are read as each request is admitted (`Admission.admit/2`, `Invoke.switches_in/1`); `FALSE` uses what was read when Admission started |
| `SwitchReadAtStart` | mechanism | the switches are read again the moment a request that waited for a slot or its upload would start (`Admission.waited/3`); `FALSE` starts it as it was admitted |
| `AskOnceSent` | mechanism | a new session's status ask comes from the caller, once its request was sent (`Calls.reconnected/2`, `Invocation.ask_again/3`); `FALSE` has the family ask for every id registered, sent or not |
| `ServerDeadline` | mechanism | the caller waits at most its deadline and the link's allowance (`Invocation.await/5`, `gave_up/4`); `FALSE` waits for ever |
| `HeldEndsWithRun` | mechanism | a held turn runs each request linked to the run that made it (`HeldTurn.handle_call {:run, fun}`, `link/1`), so whatever ends the run ends the request, and one whose run is gone never starts; `FALSE` has the run only call it, and the request goes on (INVOKE-1) |

## What holds

`01_what_the_computer_keeps` (one effect, two ids at most, two drops, and
everything the environment can do) holds five rules:
- `EffectAtMostOnce`: whatever is lost, what a call changes on the computer
  happens at most once. It needs `NoResendOfEffects` (check 02, 10 states):
  the effect acts, the computer stops before it answers, and its restart
  tells the server the receipt, `unknown`, interrupted (a status ask at the
  next session hears the same when the session was down); asked again as
  a read would be, the request and its repeat both run.
- `ActedIsJournaled`: whatever acted on the computer is in its journal at
  every moment, a stop included. It needs `JournalBeforeRun` (check 03, 5
  states): a run that acted has no record until it ends, so a stop there
  leaves none.
- `StaleEpochNeverActs`: no request from an older copy of the home is
  admitted. It needs `EpochCheck` (check 04, 6 states): a request handed to
  Admission as the session dropped is taken after the computer met the
  newer copy. The relay refuses a session with an older copy too; this is
  the request that was already inside.
- `OffAlwaysWins`: nothing starts while the master switch is off, a
  request that waited included, and once Admission has heard, nothing runs
  or waits, in Admission or in a browser turn's held process (`Working`).
  It holds for the browser too (`Held = {e}`, check 17), and there it
  needs `HeldEndsWithRun` (check 18, 6 states): a browser request the held
  process took goes on after Admission ended its run and answered it
  stopped here (INVOKE-1). It needs `SwitchReadAtAdmit` (check 05, 5 states): a request
  taken after the switch went off, and before Admission heard, starts; and
  `SwitchReadAtStart` (check 15, 6 states): a request admitted to wait,
  the switch off before Admission heard, starts when its slot frees.
- `NoRecordIsFinal`: once the computer has answered that it has no record
  of a request, that request never acts, so a call that ends not known on
  that answer did not happen behind the owner's back, and a read asked
  again runs once. It needs `AskOnceSent` (check 14, 8 states): with the
  family asking for every id registered, a session that starts between an
  effect's registration and its request is asked about it first, answers
  no record, and the request, sent after, runs. That was witness 14
  (`asked before sent`) of the first pin; it is unreachable now.

`06_every_call_ends` (an effect and a read asked at once, one drop, a
computer that may stop and answers that may expire) holds `EveryCallEnds`:
every call ends, in the closed set. Fairness is only on what the server
drives: making a call, taking an answer that reached it, and its deadline.
It needs `ServerDeadline` (check 07): a computer that never answers, or a
session that never comes back, leaves the caller waiting.

Witnesses: a call whose session dropped while it waited is answered in
full once the session is back (08); an effect happens, the computer stops
before it answers, and the receipt, which the restart sends or the server
asks for, says only that the outcome is not known (09); a read whose answer
was lost runs again under a new id and answers (10); a request from an older
copy of the home is refused by name and journaled (11); the master switch
going off ends a run, and its call hears it was stopped at the computer
(12); an effect
runs, its answer leaves the computer's memory, and the receipt alone tells
the server it was done (13); a request admitted to wait for a slot or its
upload is refused off when it would start, the switch having gone off
before Admission heard (16).

## Pinned (M97, 2026-11-10)

Read against 16207ff5, which committed the code, before the first pin.
Its findings, the order a status ask relies on included, are fixed in the
re-read below.

## Re-read (M97, the invocation's fixes)

Read against the working tree that fixed the first pin's findings, which
`26196634` committed; pinned in the re-read below:
- **The caller asks, once its request is sent.** A new session no longer
  has the family ask for every id registered: it tells `Calls`
  (`reconnected/2`), which tells each caller still waiting on that
  computer, and the caller sends `invoke_status` itself from `await/5`,
  that is only after `invoke_open` went, and from the process that sent
  it, so Erlang's order between two processes keeps the ask behind the
  request. `Ask` and `owed` model it, `AskOnceSent` switches it, and
  `NoRecordIsFinal` is the rule it keeps (check 14 reaches the old path).
- **A request that waited is checked again.** `next/1` and `uploaded/3`
  start a request through `waited/3`, which reads the switches at that
  moment and refuses it `off` as admission would. `run`'s `queued`,
  `StartQueued` and `SwitchReadAtStart` model it (checks 15, 16).
- **One epoch.** A newer epoch the relay cannot write to
  `device/desktop.json` is no longer kept in memory alone: the session is
  not used (`epoch_not_kept`, logged and said in the status), and it is
  tried again with the backoff. The relay and Admission read one value,
  so `MoveOn` stands for the write that succeeded.
- **The lanes keep a request's own words behind it.** `invoke_status` and
  `invoke_cancel` now carry their request's `capability` and `op`, which
  the codec requires, and `Mobile.Lanes` gives them the request's lane:
  bulk for a history submit, interactive for every other. `AfterItsOpen`
  states that order and the lanes pin is what it rests on.
- **The pins** drop `InvokeFamily.outstanding` (gone), add
  `Relay.connected` (where an epoch that was not kept ends the session)
  and the lanes definitions.

## Re-read (M97, the computers' capabilities, 2026-11-11)

Read against `42a52e1b` (files and commands on a named computer) and
`26196634` (a computer's browser, screen and Messages, and the
invocation's fixes above), which staled every pin but the journal's and
`Computers.call/cancel`. Each change, and what it does to the model:
- `invocation.ex`, `calls.ex`, `admission.ex` (`waited`),
  `invoke_family.ex#reconcile`, `relay.ex#connected,keep_epoch` and
  `lanes.ex`: the four fixes the section above models, now committed; every
  cited line was walked against the commit. `current_epoch/2` is
  `:320-332` and `stopped/2` `:687-692`; the comments said `:320-334` and
  `:687-697`.
- `admission.ex`, besides: a run that failed with a result of its own (a
  tool's error) is answered `failed` with it, never `ok`; the sentences
  moved into one table. Each is an answer like any other. The context a
  run gets now reads this computer's sandbox and browser at each launch, in
  Admission's own process, after the started record: a raise there is a
  `Stop`, which leaves that record to be marked `unknown`.
- `invoke.ex`: the capabilities `files`, `shell`, `imessage`, `browser`
  and `computer_use` beside `system`, and the `:sandbox` and `:browser`
  readers. Admission and its runs are still `:one_for_all`
  (`invoke.ex:102-112`).
- `device_supervisor.ex#invoke_spec`: hands `Desktop.Invoke` those two
  readers; it is still beside the dial subtree.
- `switches.ex#notify`: a third listener, this computer's screen while its
  server drives it (`ComputerUse.Seat`), which lets go of the server when
  the master or the screen switch goes off. Admission is told as before.
- The capabilities themselves, read for whether a run's work ends with its
  run, which every step that ends a run here assumes: files and shell run
  in the run's task (a command under `CommandHost`, whose process group is
  swept when its requester dies); the screen's look and act run in the
  task, its watch lets go through `cancel/2` (`Seat.close`), and the seat
  hears the switch itself; Messages writes each request to the helper at
  once from the task. The browser does not: INVOKE-1, now modelled as the
  scene's `Held`, with `heldWork`, `ActHeld` and `Working`. With
  `Held = {}` the state space of every earlier check is unchanged.
- The long-lived requests (`screen.watch`, `imessage.watch`) and
  `Computers.cancel/2`: under Not modelled above, with the one gap each
  leaves.
- **The pins**: `lanes.ex` whole, since the guards that decide a lane are
  `defguard`s, which a definition pin cannot name; the browser
  capability's `run` and `held_turn.ex`, which INVOKE-1 describes.

## Re-read (M97, the off switch reaches a held browser turn)

Read against the working tree after `15f1ef38`, uncommitted when written;
`826ba83a` committed it, and the re-read below re-pins against that commit.
Each change, and what it does to the model:
- `held_turn.ex` (whole): a request runs linked to its run, and one whose
  run is gone is dropped unstarted (`HeldEndsWithRun`, INVOKE-1 fixed); a
  held turn is keyed by its server turn's session and conversation, and a
  conversation's own next turn ends the one held before it, normally, before
  its first request runs (not modelled: whose pane task, not whether);
  `stop_all/1` for `Browser.HeldTurnListener`.
- `capabilities/browser.ex#run`: hands the held turn the request's turn,
  conversation and whether it is a worker's. No modelled step changes.
- `switches.ex#notify`: a fourth listener, `Browser.HeldTurnListener`.
  Admission is told as before.
- `admission.ex` (whole): at start it answers every run its recovery
  closed with the journal's receipt (`handle_continue`), which `Stop` now
  says; every line cited moved, the other builder's `invoke_result` clause
  for a computer's own request included, so each cite is to be walked again
  at the re-pin.
- `journal.ex#interrupted,close_all` (and the new `closed_entry`): answers
  the entries it closed instead of their count. No modelled step changes.
- `computers.ex#call` (`cancel` is gone), `invocation.ex` (its `cancel/2`
  and a moduledoc sentence gone) and `calls.ex` (its `cancel/2` gone): no
  modelled step changes; the README's last Not modelled item, the order a
  caller of `Computers.cancel/2` had to keep, is gone with it.
- `invoke_family.ex#init,handle_event,reconcile`: changed by the computer
  history work, not this re-read; to be read at the re-pin.

## Re-read (M97, `826ba83a`: the held turn's fix and computer history, 2026-11-11)

Read against `826ba83a`, which committed the section above and computer
history from every computer, and staled every pin but the device
supervisor's, the relay's and the lanes'. Each change, and what it does to
the model:
- `held_turn.ex` (whole), walked step by step: `handle_call {:run, fun}`
  (`:134-145`) links the held process to its caller, the run's task, before
  it starts the request, and unlinks it only once the request answered;
  `link/1` (`:224`) fails with `noproc` for a task already gone, and the
  request is dropped unanswered. The held process does not trap exits, so
  `stop_task/2`'s `terminate_child` (`admission.ex:626-634`) and a restart
  of `Desktop.Invoke`'s `:one_for_all` (`invoke.ex:103-113`) end the
  request it runs. `Cancel`, `HearSwitch` and `Stop` leave `heldWork` alone
  under `HeldEndsWithRun`, which is that. One abstraction: the exit signal
  is sent as the task ends, before `terminate_child` returns and Admission
  answers, and taken by the held process a moment later; the model makes
  the two one step. A request that waits in the held process's mailbox
  behind the one that ended is not taken: its own caller's call exits with
  the held process (`:shutdown` is not one `run/4` retries), so that run
  ends `failed` before it acted. Check 17 holds and check 18 (6 states)
  needs the link.
- `admission.ex` (whole): a restart answers every run its recovery closed,
  once it stands (`handle_continue`, `:144-151`, the journal's receipt), as
  `Stop` says; that made check 02's path shorter (14 states to 10: the
  restart's own receipt, no drop needed) and gives witness 09 a second way.
  The new `invoke_result` clause (`:168-174`) is computer history's, below.
  Every `admission.ex` line cited moved, and is walked again here.
- `journal.ex#interrupted,close_all,closed_entry`: the entries it closed,
  as `lookup/2` would read them, for the restart's answers. No modelled
  step changes; `write_line` moved to `:263-271`.
- `invocation.ex`, `calls.ex`, `computers.ex#call`: `cancel/2` gone from
  all three; no modelled step changes. Every `invocation.ex` line cited
  past the removed function moved up by five, `tell_reconnected` and
  `route` in `calls.ex` by twelve, and `Computers.call/6` down by two.
- `switches.ex#notify`: the fourth listener, `Browser.HeldTurnListener`.
  Admission is told as before.
- `capabilities/browser.ex#run` (`:233-248`): hands the held turn its
  turn's session, conversation and whether it is a worker's. No modelled
  step changes.
- `invoke.ex`, `invoke_family.ex#init,handle_event,reconcile` (computer
  history): a capability `history` on the computer (`MachineService`, its
  op `apply`), a service `history` on the home (`HomeService`, its op
  `submit`), and the family's context names the computer that asked. The
  family's three pinned functions do what they did; their lines moved.
  `history.apply` is a request of the server like any other: admitted,
  journaled, gated by the master switch alone (it offers nothing of its
  own), so every rule here covers it.

**The computer's own requests (computer to home).** A computer now opens
invocations toward its home: `Desktop.HistoryUplink` sends one
`history.submit` at a time, waits on it in the process that sent it, and
sends its own `invoke_cancel` after its deadline. No rule here changes, and
the direction needs no modelling in this spec:
- Ids cannot meet: the server mints `inv-…` (`Invocation.mint_id/0`), the
  computer `hist-…` (`HistoryUplink.request/1`). Each side hands an
  `invoke_result` only to its own waiters: the home's family to `Calls`
  (`route/4` drops an id nobody waits on), the computer's Admission to
  `HistoryUplink.answer/4`, whose waiter takes only its own id. Admission's
  `open`, `cancel` and `status` see only the server's requests, and the
  home's family `serve`, `cancel` and `status` only the computer's.
- Admission's state does not move for the computer's own request: the new
  clause runs nothing, journals nothing and holds nothing, so `run`,
  `journal`, `held` and the rest are as before. Its epoch check and journal
  never see it; the home does not check the epoch the computer names, and
  the computer reaches only a copy whose session its relay accepted
  (`Relay.hello_ack/2` refuses a lower epoch).
- The switch off: `HistoryUplink.submit/2` sends nothing while the master
  or the `history` switch is off; a sitting sent before is not work running
  on the computer (its text has left, the home finishes it), so
  `OffAlwaysWins` still describes everything the computer runs.
- A restart of Admission, or a session that drops, loses an answer on its
  way to the computer's waiter; the waiter gives up at its deadline and the
  next cycle sends the sitting again, which the home answers from the note
  it made. What a lost or repeated sitting does to the home's notes is
  `history_submit`'s rule, and that spec models the resend.
- Shared with the server's requests: the relay's 512 events for
  Admission, now also the answers to the computer's own requests (not
  modelled, as the bound is not), and the lanes, where a history submit
  and its cancel ride the bulk lane (pinned).

Seen while reading, not modelled and not a rule here:
- A held turn that the browser switch alone ends (the master switch on)
  takes its run with it, which Admission answers `failed`, "It stopped
  before it finished. The computer's log says why.", not `refused` `off`:
  the server hears a crash for what the owner switched off. Admission ends
  runs on the master switch only.
- A restart of Admission answers only what had a started record. A request
  still waiting for a slot has none and is answered by nothing: a call with
  a deadline ends at it, but a long-lived one (`imessage.watch`,
  `screen.watch`, deadline 0) queued behind eight runs waits until its
  caller ends while the session stays up. The moduledoc's "a restart of
  this process while the session stays up leaves no caller waiting, a
  long-lived one included" holds for one that ran.

## Findings

The first pin's three (a status ask that could reach the computer before
its request, a request that waited and could start after the switch went
off, an epoch kept only in the relay's memory) are fixed in the code and
modelled above.

### INVOKE-1: a browser request outlives the run Admission ends
- **Severity:** medium. The trigger is rare, but the master switch is the
  owner's stop at the computer, and for the browser it answers "The person
  at this computer stopped it." and stops nothing already handed over.
- **Status:** fixed in `826ba83a`. Found in the re-read of `26196634`.
- **Check:** 18 (6 states) reaches it without the fix; 17 holds with it.
- **Counterexample:** the server sends a browser request that changes
  something; Admission records it started and runs it, and the run hands
  it to the turn's held process. The owner switches everything off at the
  computer and Admission hears: it answers the request `refused`
  `stopped_here` and ends the run, while the held process still has the
  request. The rule breaks there; the request can then act (`ActHeld`).
- **Code** (lines as they were at `26196634`):
  - `Capabilities.Browser.run/4` (`computers/capabilities/browser.ex:233-242`)
    makes each request through `HeldTurn.run/3`, a
    `GenServer.call(…, :infinity)` (`held_turn.ex:108`) into the turn's
    `Browser.HeldTurn`, which runs it in its own `handle_call` (`:87`).
  - Admission ends a run with `stop_task/2` (`admission.ex:597-605`): the
    capability's `cancel/2` first, when it has one, then the run's task.
    The browser has none, so only the task ends. The held process finishes
    the request it runs, then takes each call still in its mailbox, though
    the caller that sent it is gone.
  - The held turns live under `Browser.Supervisor` in core, not under
    `Desktop.Invoke`, so a restart of Admission leaves them going too.
- **Reach:** every way Admission ends a run: the master switch
  (`stopped/2`), a cancel (which the server's deadline and a caller's end
  send), the computer's own deadline, a restart of Admission. The request
  the held process runs finishes: a navigation, a click, a submit, a
  sign-in. A later request of the same turn, which the server sends once
  its own call for the earlier one has ended, waits behind it in the held
  process's mailbox and still starts after the switch went off, though
  Admission answered it stopped here. The journal keeps the refusal or the
  cancel; `ActedIsJournaled`, `EffectAtMostOnce` and `NoRecordIsFinal`
  still hold, since every such request has a started record and none is
  sent twice.
- **What a fix needs:** the end of a run to reach the held turn: a
  `cancel/2` for the browser that ends the request the held process runs,
  and a held process that drops a call whose caller is gone before it
  starts it. Check 17 then holds and becomes the `holds` check, with a
  `needs` check for that mechanism.
- **The fix:** no `cancel/2`: the held process links itself to the run
  for as long as it runs that run's request (`HeldTurn.handle_call {:run,
  fun}`, `link/1`), so every way Admission ends a run (`stop_task/2`'s
  `terminate_child`, a restart of `Desktop.Invoke`'s `:one_for_all`) ends
  the request there and the held process with it, and its pane task as a
  stopped turn's; a call whose run is already gone fails the link and is
  dropped unstarted. `HeldEndsWithRun` models it; check 17 holds, check 18
  is its `needs` check. The request a browser already has (one CDP or pane
  operation, inside its profile's process) is not interrupted: that
  operation completes in the browser, as on the server's own browser when a
  turn is cancelled, and nothing the held process would do after it
  starts. Beside it, `Browser.HeldTurnListener` ends every held turn when
  the master or the browser switch goes off, so no pane task and tab wait
  for the 10-minute idle bound.
