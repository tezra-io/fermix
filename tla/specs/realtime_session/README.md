# realtime_session: one voice call's tool turns and upstream socket

Models `FermixCore.Realtime.SessionServer` for one voice call after
`call_start`, with two concerns:
- **Tool turns.** A tool result becomes the model's next spoken response. The
  session appends the output and sends one `response.create` per answered
  batch (`finish_tool_turn`, `flush_deferred_response`), and sends it again
  when OpenAI rejects it for a response the session had not heard of
  (`handle_active_response_race`). OpenAI runs its own response lifecycle, and
  server VAD starts responses of its own. The owner's spoken yes to an
  access-sensitive command a tool call parked starts its confirmed run off the
  loop (`answer_access`, `start_access_dispatch`). The run's reply puts
  Fermix's status item with the outcome on the wire and goes through the same
  `finish_tool_turn` (`access_dispatched`, `speak_outcome`), so the model can
  tell the owner. A reply that lands while the call is not live is held and
  told once OpenAI confirms the next socket (`speak_held_outcomes`).
- **The upstream socket.** The call keeps one OpenAI socket across drops. This
  covers `schedule_reconnect`, the backoff timer, `attempt_reconnect`,
  `resume_provider_session` closing a socket it could not configure, the new
  socket's `session.updated`, and `end_call` once no attempt is left.

The session's mailbox is one FIFO in arrival order. Socket events and errors,
socket exits, tool replies, the confirmed run's reply and timer messages all
share it, and the session handles the oldest first. Every message a socket
sends names it: its events and errors carry the socket's pid, and its death
reaches the session only as its `EXIT` through the link (`OpenAIClient` has no
disconnect notice). Each socket is modelled with the OpenAI conversation
behind it:
- OpenAI reads client events in order.
- It answers a `session.update` with `session.updated`.
- It runs at most one response per conversation.
- It rejects a `response.create` while a response is running
  (`conversation_already_has_active_response`).
- A response reads only the outputs and status items appended before it
  started. The comment at `session_server.ex:1428-1438` records this
  ("snapshotted context").

The call starts connected on socket 1, configured, with the operator's first
response under way. The checks use one or two tool calls, one to four sockets,
two or three reconnect attempts and at most one yes. Production has three
attempts (`session_server.ex:60`).

**Environment switches** (set per check):
- `Drops`: how many times the network or OpenAI may drop an open socket.
- `VadTurns`: how many more responses server VAD may start on the operator's
  speech (`create_response: true`, `openai_client.ex:427`).
- `Yeses` (0 or 1): the owner says yes to the command a tool call parked, and
  the session starts its confirmed run (`answer_access` ->
  `start_access_dispatch`, `session_server.ex:1263-1291`). The yes is one
  step, `Yes`, on the current socket, allowed once a tool call has run. Its
  own server-VAD response is `VadTurns`'s.
- `OpensCanFail`: a reconnect's handshake fails. No socket process is left
  behind, because `handle_initial_conn_failure` defaults to `false`
  (`websockex.ex:610`).
- `UpdatesCanFail`: a reconnect's socket opens, but sending `session.update`
  to it fails.
- `UsersCanStop`: the operator ends the call (`call_stop`).
- `LateVadCreated`: a VAD response takes its context in one step, and OpenAI
  emits its `response.created` in a later one. A trigger can then be rejected
  before the session hears the response exists.
- `MaxSockets` bounds the sockets a call may open. Past it, every further open
  fails as if the network were down.

**Mechanism switches** (`TRUE` is the real code; each is switched off only by
the checks that show a rule needs it):
- `DefersWhileCallsPending`: `finish_tool_turn` holds the trigger while other
  calls of the batch are in flight (`session_server.ex:1439`).
- `DefersWhileResponseActive`: it also holds the trigger while OpenAI's
  response is active, and `response.done` sends it (`:1443`,
  `flush_deferred_response` `:1452`).
- `RearmsOnRejection`: a trigger OpenAI rejected for an active response is owed
  again, and that response's `response.done` sends it
  (`handle_active_response_race`, `:1478`).
- `CancelsToolsOnReconnect`: `schedule_reconnect` kills in-flight tool tasks,
  and `Task.shutdown` flushes their replies (`:651`, `:728-729`). A
  confirmed run is not a tool task: a reconnect leaves it running, and its
  reply stays queued.
- `ClosesUnconfigured`: `resume_provider_session` closes a socket whose
  `session.update` failed (`:696`).
- `EndsWhenExhausted`: with no reconnect left, the call ends (`end_call`,
  `:712`).
- `ResetsAttemptsOnSuccess`: a reconnect OpenAI confirms resets
  `reconnect_attempts`: the new socket's first `session.updated` (`:875`).
- `ResetsOnlyWhenConfirmed`: nothing earlier resets it (`:508`). A socket
  that opens and takes its `session.update` but drops before
  `session.updated` has used an attempt. Off, the reset runs as soon as the
  socket opens, as it did at `35a6acdc` (`:467`).
- `OwnSocketOnly`: only `openai_pid`'s events, errors and `EXIT` are acted on.
  Any other socket's are dropped: the event and error clauses match the pid in
  their heads (`:409`, `:471`), one clause drops the rest (`:480`), and the
  `EXIT` clause matches only `openai_pid` (`:486`).
- `HoldsOutcome`: a confirmed run's outcome that lands while the call is not
  live is held, and told once OpenAI confirms the next socket
  (`speak_outcome` `:1304-1319`, `hold_outcome` `:1321`,
  `speak_held_outcomes` `:879`, `:1325-1326`). Not live means
  `provider_ready?` is false (the reconnect window, before the next socket's
  `session.updated`), or the status item's send fails (`openai_pid` died and
  its `EXIT` is still queued behind the reply). Off, the status item and the
  trigger go out whatever the call's state, and a failed send is only
  reported, as before the fix for RT-4.

The confirmed run's reply goes through the same `finish_tool_turn`, so the
first three switches act on its trigger too.

**Assumed of OpenAI, not documented:** a `response.create` rejected because a
response is running is rejected before that response's `response.done`. The
response is still running when OpenAI reads the create, so this is very likely,
but no document says so. The model has it by construction: the rejection is
queued while the response is active, and its `response.done` is queued in a
later step on the same socket. The re-armed trigger rests on it. In the other
order the owed trigger waits for the next response to end: the old stall until
the operator speaks again, plus one extra reply.

No check needs a timing idealisation. A closed socket's exit may land at any
point, before or after the next reconnect timer.

## What holds

**Check 01** holds with no server-VAD response, no spoken yes, a socket drop,
failed reconnect handshakes and the operator's stop:
- OpenAI never rejects a trigger. This rests on `DefersWhileCallsPending`
  (check 02) and `DefersWhileResponseActive` (check 03).
- A tool output only ever joins the conversation that called it. This rests
  on `CancelsToolsOnReconnect` (check 04).

With server-VAD responses a rejection still happens: witness 11 reaches one.
With the owner's yes it happens with no server-VAD response at all: witness 26
reaches one (16 states). The confirmed run is not one of
`pending_tool_calls`, and the session learns of a response only from its
`response.created`, so the run's reply can put a second trigger on the wire
behind one the session has just sent (from `finish_tool_turn` or
`flush_deferred_response`). OpenAI starts a response on the first and rejects
the second. That response started before the status item joined, so the
re-armed trigger is the one that speaks the outcome.

**Check 10** holds with two calls, two server-VAD responses whose
`response.created` may trail their start, a drop, failed handshakes and the
operator's stop: once the call settles, every tool output in the live
conversation has had a response start after it. This rests on
`RearmsOnRejection` (check 16), the fix for RT-1.

**Check 24** holds with the owner's yes, one call, a server-VAD response whose
`response.created` may trail its start, a drop, failed handshakes and the
operator's stop. Once the call settles:
- a run that replied has had its status item put on the wire to an open
  socket, even when the reply landed while the call reconnected. This rests
  on `HoldsOutcome` (check 27, 14 states), the fix for RT-4;
- the status item, if it is in the live conversation, has had a response
  start after it. This rests on `RearmsOnRejection` (check 25, 20 states),
  on the path witness 26 shows.

A readiness-only hold (hold while `provider_ready?` is false, send
otherwise) still breaks the first half in 14 states, run by hand: the reply
is handled before the dead socket's `EXIT`, and the status item's send
fails. That is why a failed send holds too. The rule claims no more than
that: a status item still on the wire, or not yet answered, when its socket
drops dies with that conversation, as a tool output does. An outcome still
held when the call ends is never told; `terminate/2` logs one warning naming
the intent and the tool (`warn_unspoken_outcomes`, `:551`, `:1331-1338`),
which the spec does not model.

**Check 05** holds with a drop, failed handshakes, failed `session.update`s and
a closed socket's exit landing at any point:
- While the call lives, every open socket is `openai_pid`. This rests on
  `ClosesUnconfigured` (check 06).
- A live call always has a socket or a reconnect timer: the 43 s freeze that
  the comment at `session_server.ex:703-711` describes. This rests on
  `EndsWhenExhausted` (check 07) and on `OwnSocketOnly` (check 17).

Check 05 and its needs checks run production's three attempts. With two, the
drop and the failed `session.update` spend the budget, so in check 17 the
closed socket's exit ends the call instead of reaching the freeze.

**Check 08** holds with two drops and failed handshakes: the call gives up
only after running every reconnect attempt. This rests on
`ResetsAttemptsOnSuccess` (check 09). It also holds `AttemptsBounded`:
between two confirmations the call runs at most one attempt per delay in
`@default_reconnect_backoff_ms`, however often a socket opens and drops
before its `session.updated`. This rests on `ResetsOnlyWhenConfirmed` (check
23). Before the fix (84670433) the count reset when a
socket opened, so an upstream that kept closing before `session.updated`
reconnected until the max-session timer, or, if the call's first socket was
never confirmed (the timer is armed only by a `session.updated`), until the
operator hung up; check 23 reaches three attempts against a budget of two.

**Checks 12 to 15** take the setups of the old RT-2 and RT-3 checks and
witness. Each now holds, and each rests on `OwnSocketOnly`. Check 14 (and so
check 21) differs in one constant: the operator may stop the call
(`UsersCanStop`), which the old check 14 did not allow. With `OwnSocketOnly`
off, check 21 reaches the freeze (no socket, no timer, nothing enabled), and
TLC reports that deadlock before `LateResultStaysHome` breaks; a stop only
removes behaviour, so no property holds because of it.
- Check 12: a closed socket's late exit leaves one open socket, `openai_pid`
  (check 18).
- Check 13: a reconnect timer is outstanding only while no socket is current,
  and the session holds its ref; no reconnect tick is ever queued while the
  call is connected (checks 19 and 20).
- Check 14: a tool output only joins the conversation that called it (check
  21).
- Check 15: with failed `session.update`s, the call gives up only after
  running every attempt (check 22).

With the operator's stop allowed, TLC's deadlock check cannot fire in checks
01, 05, 08, 10, 14 and 24: `Stop` is enabled in every live state. The only
wedge this model has room for is the freeze (no socket, no timer, an empty
mailbox), since tool calls, the confirmed run and VAD never touch the socket
or the timer, and check 05 asserts it directly as `NoFreeze`. The first five
checks were also run by hand with the stop left out, so the deadlock check was
live, once and again after the attempt reset moved to `session.updated`: all
five still hold, with no deadlock. Check 24 was run the same way when the
confirmed run was modelled, and again with the hold: it holds, with no
deadlock (6,124 states, and 1,322,125 with one more of each entity). Checks
12, 13 and 15 leave the stop out.

The holds checks were also run once by hand with one more of each entity, and
again after the attempt reset moved to `session.updated`; check 24 when the
confirmed run was modelled and again with the hold, still with one yes
(`Yeses` is at most 1). All still hold:

| Check | Calls | Sockets | Attempts | Drops | VAD responses | States |
|---|---|---|---|---|---|---|
| 01 | 3 | 3 | 3 | 2 | 0 | 10,773 |
| 05 | 1 | 4 | 4 | 2 | 0 | 4,250 |
| 08 | 1 | 4 | 3 | 3 | 0 | 500 |
| 10 | 3 | 3 | 3 | 2 | 3 | 5,981,665 |
| 12 | 1 | 4 | 3 | 2 | 1 | 20,124 |
| 13 | 1 | 5 | 4 | 2 | 1 | 136,580 |
| 14 | 2 | 5 | 3 | 2 | 2 | 2,811,507 |
| 15 | 1 | 3 | 3 | 2 | 1 | 3,930 |
| 24 | 2 | 3 | 3 | 2 | 2 | 1,405,520 |

## Not modelled

- Audio, transcripts other than the owner's yes, usage and cost limits, the
  max-session timer, the screen feed, and `screen_share`, which is answered
  inline with no task. What `start_timers` does to the reconnect timer is
  modelled.
- `interrupt`. Its `response.cancel` only ends the active response early,
  which `RespDone` already allows at any time.
- A tool task crash. Its `:DOWN` is answered exactly like a result
  (`session_server.ex:448-453`). A confirmed run's crash is answered like its
  reply, with the outcome-unknown text (`:440-444`).
- The access gate's own state (`Capabilities.AccessGate`): what the call has
  read from outside (`outside_sources`), the waiting stamp
  `tool_call_context` gives each tool task (`:1228-1234`), and the binding of
  the owner's answer to the first input item committed after the park, by
  item id (`bind_access_answer` and `answer_access`, `:1244-1273`, with the
  item id `decode_server_event` passes on, `openai_client.ex:367-375`).
  They decide whether a yes starts a run, not when its reply lands. A spoken
  no only adds a passive status item (no `response.create`) and starts
  nothing.
- A confirmed run after the call ends: `terminate/2` cancels only tool tasks,
  so the run goes on and its reply reaches no one. An outcome the call still
  holds when it ends is only logged (`warn_unspoken_outcomes`).
- A second confirmed run in one call. `Yeses` is at most 1, so at most one
  outcome is held; the code keeps them in a list, oldest first
  (`held_outcomes`), one per confirmed run.
- `call_start` and its failure path. It builds the `session.update` before it
  opens a socket, so a failed build opens none. A failed `call_start` stops
  the voice connection and the session with it
  (`local_voice_socket.ex:561-564`), and a socket it closed after a failed
  send never became `openai_pid`.
- The network between OpenAI and the socket process. An event OpenAI emits
  lands in the session's mailbox in the same step.
- WebSockex itself (`deps/websockex`, 0.5.1 in `mix.lock`). It cannot be
  pinned. The spec relies on:
  - a socket the session closed exits once its close handshake ends, at the
    latest on its 5 s close timeout (`websockex.ex:925-932`, `close_loop`
    `:732-763`), or at once when its connection is already gone
    (`:934-935`). The model lets that exit come at any time;
  - WebSockex does not trap exits, so any non-normal exit of the session
    kills its sockets through the link: `end_call` and `call_stop` exit with
    `{:shutdown, _}`, and a crash or a supervisor shutdown is non-normal too.
    `terminate/2` also closes `openai_pid`.
- `OpenAIClient`'s missing `handle_disconnect/2` override. Its `SOURCE` pin
  names functions, so re-adding one would not make the spec STALE. The
  absence is pinned by `openai_client_test.exs` ("a disconnect sends the
  session nothing"), and the link by a test over a loopback connection ("a
  real socket's events name it, and its death reaches the caller only as its
  EXIT").
- `SessionServer.handle_provider_event/2` (`session_server.ex:102`), a test
  seam that nothing in `lib` calls. It acts on an event without the pid check,
  so `NoFreeze`, `NoStrayTimer` and `NoTickWhileConnected` hold only while it
  stays a test seam.

## Findings

RT-1 to RT-3 are fixed (efa5d125), and RT-4 is fixed in this change. Each
write-up keeps the defect as it was found: its line numbers are those of the
code before the fix (for RT-1 to RT-3, `origin/dev` `693970b7`, unchanged
through `2a7bdaa4`; for RT-4, `82a91e60`). Each was confirmed by walking the
counterexample through that code, and each is now reproduced by an ExUnit
test that failed before the fix
(`apps/fermix_core/test/fermix_core/realtime/session_server_test.exs`, and
`session_server_access_test.exs` for RT-4). None was reproduced on a running
daemon. The `needs` checks named under each show
the finding's rule breaking again with the fix's mechanism switched off; open
`tla/out/realtime_session/<check>.txt` after a run to see the path.

### RT-1: a tool result that lands as a VAD response starts is never spoken
- **Severity:** low to medium. The window is about one network round trip,
  but the operator then hears nothing about the result until they speak again.
  The output stays in the conversation, so their next turn reads it.
- **Status:** fixed (efa5d125). A rejected trigger is owed
  again: `handle_active_response_race` sets `needs_response?`, logs at info,
  and sends nothing itself. The rejecting response's `response.done` runs
  `flush_deferred_response`, which sends the trigger once no call is pending.
  Each re-send needs another response the server started, so it is bounded.
- **Checks:** 10 now holds; check 16 (16 states) breaks it again with
  `RearmsOnRejection` off, on the deferred send, with the rejection arriving
  before the VAD response's `response.created`. Witness 11 (11 states) shows
  rejections still happen.
- **Counterexample (the old check 10):**
  1. The first response calls `c1` and ends.
  2. `c1` returns. With no call pending and `response_active?` false,
     `finish_tool_turn` sends the output and `response.create`, and clears
     `needs_response?` (`:1275-1278`).
  3. Before OpenAI reads them, server VAD commits the operator's speech and
     starts its own response. That response began before the output joined,
     so it does not read it.
  4. OpenAI appends the output, then rejects the trigger with
     `conversation_already_has_active_response`.
  5. `handle_active_response_race` only logs the rejection (`:908`, `:1293`),
     and nothing sets `needs_response?` again.
  6. The VAD response ends, and `flush_deferred_response` finds nothing owed.
- **Code:**
  - `response_active?` mirrors OpenAI's lifecycle only from the events it
    receives (`:889`, `:897`). A VAD response that OpenAI started, but whose
    `response.created` is still on the wire, looks like no response at all.
  - The deferral at `:1271` covers only a response the session already knows
    about. Both send sites lost the answer: the immediate send in
    `finish_tool_turn` (`:1275-1278`) and the deferred one in
    `flush_deferred_response` (`:1283`).
- **Impact:**
  - This is the silent stall that `finish_tool_turn`'s comment describes
    fixing for two calls in one batch. It still happened when the operator
    spoke while a tool ran and the result landed as their turn was committed.
  - The model answered what the operator said, without the result, and stayed
    silent about the result until the operator spoke again.
- **Trade-off of the fix:** OpenAI also rejects in a harmless order: the VAD
  response started after the output joined, and read it. The re-sent trigger
  then asks for one reply the model does not need, and it may speak about the
  result twice. Nothing the session receives tells the two orders apart. An
  item-order check was declined: it would bring the stall back silently if
  `response.created` can follow the moment a response takes its context,
  which OpenAI does not document.

### RT-2: a closed socket's late disconnect notice orphans the live socket
- **Severity:** medium when it happens. The trigger is rare: a reconnect's
  `session.update` must fail, and the network must then be slow to close
  that socket but recover in time for the next attempt.
- **Status:** fixed (efa5d125). Every message a socket
  sends names it, and a socket's death reaches the session only as its
  `EXIT`: `OpenAIClient.handle_disconnect` is gone. The session acts only on
  `openai_pid`'s events, errors and `EXIT`, and drops any other socket's. The
  cancel in `schedule_reconnect` (`:620-623`) is gone too: nothing reaches
  `schedule_reconnect` any more while a timer is armed. No reconnect token was
  added: check 13 shows no stray tick is left for one to guard against, and
  checks 19 and 20 show that rests on `OwnSocketOnly`.
- **Checks:** 12, 13 and 14 now hold. Checks 18 (12 states), 19 (8 states),
  20 (11 states) and 21 (22 states) break them again with `OwnSocketOnly`
  off, and check 17 (12 states) breaks `NoFreeze` in check 05's setup.
  Checks 18 and 21 took two states fewer while a socket's open reset the
  attempt count: now the new socket's `session.updated` has to refill the
  budget before the stale exit can schedule a reconnect.
- **Counterexample (the old check 12):**
  1. Socket 1 drops. `schedule_reconnect` arms the first timer.
  2. The timer fires. Socket 2 opens, but `session.update` fails, so
     `resume_provider_session` closes it (`:655`) and a second timer is armed.
  3. The second timer fires before socket 2's close completes. Socket 3 opens,
     is configured, and becomes `openai_pid`.
  4. Socket 2's close finishes, or hits WebSockex's 5 s timeout.
     `OpenAIClient.handle_disconnect` sends `{:openai_realtime_disconnect, _}`
     (`openai_client.ex:450`).
  5. The session handles it as if socket 3 had dropped (`:422`).
     `schedule_reconnect` sets `openai_pid` to nil without closing socket 3
     (`:629`).
- **Code:**
  - The disconnect clause (`:422`) matched a notice from any socket, while the
    `EXIT` clause (`:443`) matched only `openai_pid`. The comment at
    `:646-648` expected the closed socket's later `EXIT` to race the attempt
    that replaced it. It was the notice that did.
  - Socket events were not checked against `openai_pid` either (`:383`).
  - **A second route** (the old witness 13). The notice arrives, and the next
    timer fires before the session has handled it:
    1. `schedule_reconnect` cancels a timer that already fired, which does
       nothing to its queued message, and arms another (`:623-624`).
    2. The queued message then connects and sets `reconnect_timer` to nil
       (`:471`), dropping the ref to the new timer.
    3. That timer later fires into the connected call. `attempt_reconnect`
       (`:639`) has no guard, so it opens yet another socket and overwrites
       `openai_pid` without closing the old one.
  - **A freeze** (found in review; check 17 now). The stale notice set
    `openai_pid` to nil and armed a reconnect timer. Socket 3's
    `session.updated`, still on its way, then arrived with `provider_ready?`
    false: `start_timers` ran `cancel_timers` (`:1530-1547`) and disarmed the
    timer the notice had just armed. The call had no socket and no timer. The
    next unmuted audio chunk ended it with `provider_session_missing`
    (`:336`); a muted call sat frozen. The spec did not model
    `session.updated` then, so it missed this, and wrongly said the no-freeze
    rule needed no idealisation.
- **Impact:**
  - The healthy socket stayed open and linked to the session until the call
    ended: an upstream connection nothing owned, with its in-flight response
    and its server-side session.
  - The call reconnected for no reason. The companion was told
    "reconnecting", in-flight tools were killed, and the screen feed was
    suspended.
  - Events from the orphaned conversation kept arriving and were handled as
    the current one's:
    - its audio deltas reached the companion;
    - its `response.created` and `response.done` moved `response_active?`;
    - a tool it called ran, with its side effects, and the output was sent to
      the new conversation, which never called it (check 21).
  - Or the call froze, as above.

### RT-3: a failed `session.update` costs two reconnect attempts
- **Severity:** low.
- **Status:** fixed (efa5d125) by the RT-2 change. The
  closed socket was never `openai_pid`, so its exit is dropped, and each real
  attempt schedules once. A call whose `session.update` keeps failing now
  uses the whole backoff (1 + 2 + 4 s, three sockets) before it ends.
- **Checks:** 15 now holds; check 22 (8 states) breaks it again with
  `OwnSocketOnly` off.
- **Counterexample (the old check 15):**
  1. Socket 1 drops, and attempt 1 of 2 is scheduled.
  2. Socket 2 opens, `session.update` fails, the socket is closed, and attempt
     2 is scheduled.
  3. Socket 2's notice arrives before that timer fires. `schedule_reconnect`
     runs again, finds attempt 2 of 2 used, and calls
     `end_call(:provider_disconnected)`. Only one attempt ever ran.
- **Code:** the same unguarded disconnect clause (`:422`). Each
  `schedule_reconnect` call counted an attempt (`:634`), and the one for the
  notice cancelled the timer the failed attempt armed (`:623`).
- **Impact:** in production, with three delays, a failed `session.update`
  used two of the three attempts. The call gave up after two real attempts,
  and its 2 s wait became 4 s. If the second attempt was the one that failed
  this way, the call ended at once and the third attempt never ran.

### RT-4: a confirmed run's outcome that lands during a reconnect is never spoken
- **Severity:** medium when it happens. The window is a reconnect (up to
  1 + 2 + 4 s of backoff, plus the handshakes) or the moment between a
  socket's death and its `EXIT`, and the command must be one the owner said
  yes to by voice. The owner then never hears whether a car command ran.
- **Status:** fixed in this change. `access_dispatched` hands the outcome to
  `speak_outcome`. While `provider_ready?` is false it is held on the state
  (`held_outcomes`, oldest first, at most one per confirmed run of the
  call); when the status item's send fails it is held too. The not-ready
  clause of `session.updated` runs `speak_held_outcomes`, which sends each
  through the same status item and `finish_tool_turn` a live call uses, so a
  held outcome is told exactly once, in the first conversation OpenAI
  confirms. If the call ends first, `terminate/2` logs one warning per held
  outcome with the intent id and the tool (never the arguments), so the
  operator knows which command to check.
- **Checks:** check 24's `OutcomeAnswered` now also asks that a run that
  replied has had its status item put on the wire to an open socket; it
  holds. Check 27 (14 states) breaks it with `HoldsOutcome` off.
- **Counterexample (check 27):**
  1. The first response calls `c1`; the owner says yes, and the confirmed
     run starts.
  2. The run replies while the first response is still active. Socket 1
     drops, and its `EXIT` queues behind the reply.
  3. The session handles the reply: `provider_ready?` is still true, so
     `access_dispatched` calls `inject_status_notice`, whose send to the dead
     socket fails with a debug log (`:1197-1206`). `finish_tool_turn` owes
     the trigger, since a response is active.
  4. The `EXIT` runs `schedule_reconnect`, which clears `needs_response?`
     (`:655`) and keeps no trace of the outcome.
  5. Socket 2 opens and OpenAI confirms it. The call settles with the
     outcome never sent.

  A path of the same length handles the drop's `EXIT` first: the reply then
  lands with no `openai_pid`, the status item's send fails (`send_openai`,
  `:1464`), and `finish_tool_turn`'s last clause clears `needs_response?`
  and reports the failed trigger (`:1390-1393`, `report_provider_send_error`
  `:1454`).
- **Code:**
  - A reconnect deliberately leaves the confirmed run going:
    `schedule_reconnect` cancels only `pending_tool_calls` (`:646`), because
    a car command must not be cut off mid-flight. Its reply can therefore
    land in the reconnect window, or on a socket that is already dead.
  - `access_dispatched` (`:1277-1281`) sent the status item and the trigger
    whatever the call's state. `inject_status_notice` only logs a failed
    send at debug (`:1203`), and nothing kept the outcome for the next
    conversation, which starts empty.
  - The comment on the reply clause (`:422-425`) says one response is owed
    "so it can tell the owner". In this window nothing was owed any more.
- **Impact:** the owner said yes to a command (unlock, trunk, vent) and the
  model never told them whether it ran. The model in the new conversation
  has no record of it, so a question about it gets a guess. Asking for the
  command again is answered "already done" while the record's tombstone
  lives (60 s), and after that asks the owner to confirm it a second time.
- **Trade-off of the fix:** a held outcome is told one reconnect late, in a
  conversation where the owner may have moved on; the status item marks it
  as Fermix's, and the model decides how to bring it up. A failed send now
  holds the outcome instead of dropping it. A send that fails for any other
  reason than a dead socket (none is known: the status item is Fermix's own
  text) waits for a reconnect that may never come, and ends in the warning.
  A status item that reached a socket which then drops before OpenAI
  answers it is still lost with that conversation, as a tool output is.
