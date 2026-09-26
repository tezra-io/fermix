# realtime_session: one voice call's tool turns and upstream socket

Models `FermixCore.Realtime.SessionServer` for one voice call after
`call_start`, with two concerns:
- **Tool turns.** A tool result becomes the model's next spoken response. The
  session appends the output and sends one `response.create` per answered
  batch (`finish_tool_turn`, `flush_deferred_response`), and sends it again
  when OpenAI rejects it for a response the session had not heard of
  (`handle_active_response_race`). OpenAI runs its own response lifecycle, and
  server VAD starts responses of its own.
- **The upstream socket.** The call keeps one OpenAI socket across drops. This
  covers `schedule_reconnect`, the backoff timer, `attempt_reconnect`,
  `resume_provider_session` closing a socket it could not configure, the new
  socket's `session.updated`, and `end_call` once no attempt is left.

The session's mailbox is one FIFO in arrival order. Socket events and errors,
socket exits, tool replies and timer messages all share it, and the session
handles the oldest first. Every message a socket sends names it: its events
and errors carry the socket's pid, and its death reaches the session only as
its `EXIT` through the link (`OpenAIClient` has no disconnect notice). Each
socket is modelled with the OpenAI conversation behind it:
- OpenAI reads client events in order.
- It answers a `session.update` with `session.updated`.
- It runs at most one response per conversation.
- It rejects a `response.create` while a response is running
  (`conversation_already_has_active_response`).
- A response reads only the outputs appended before it started. The comment at
  `session_server.ex:1252-1262` records this ("snapshotted context").

The call starts connected on socket 1, configured, with the operator's first
response under way. The checks use one or two tool calls, one to four sockets
and two or three reconnect attempts. Production has three attempts
(`session_server.ex:53`).

**Environment switches** (set per check):
- `Drops`: how many times the network or OpenAI may drop an open socket.
- `VadTurns`: how many more responses server VAD may start on the operator's
  speech (`create_response: true`, `openai_client.ex:423`).
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
  calls of the batch are in flight (`session_server.ex:1263`).
- `DefersWhileResponseActive`: it also holds the trigger while OpenAI's
  response is active, and `response.done` sends it (`:1267`,
  `flush_deferred_response` `:1276`).
- `RearmsOnRejection`: a trigger OpenAI rejected for an active response is owed
  again, and that response's `response.done` sends it
  (`handle_active_response_race`, `:1302`).
- `CancelsToolsOnReconnect`: `schedule_reconnect` kills in-flight tool tasks,
  and `Task.shutdown` flushes their replies (`:604`, `:681-682`).
- `ClosesUnconfigured`: `resume_provider_session` closes a socket whose
  `session.update` failed (`:649`).
- `EndsWhenExhausted`: with no reconnect left, the call ends (`end_call`,
  `:665`).
- `ResetsAttemptsOnSuccess`: a successful reconnect resets
  `reconnect_attempts` (`:467`).
- `OwnSocketOnly`: only `openai_pid`'s events, errors and `EXIT` are acted on.
  Any other socket's are dropped: the event and error clauses match the pid in
  their heads (`:385`, `:425`), one clause drops the rest (`:434`), and the
  `EXIT` clause matches only `openai_pid` (`:440`).

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

**Check 01** holds with no server-VAD response, a socket drop, failed reconnect
handshakes and the operator's stop:
- OpenAI never rejects a trigger. This rests on `DefersWhileCallsPending`
  (check 02) and `DefersWhileResponseActive` (check 03).
- A tool output only ever joins the conversation that called it. This rests
  on `CancelsToolsOnReconnect` (check 04).

With server-VAD responses a rejection still happens: witness 11 reaches one.

**Check 10** holds with two calls, two server-VAD responses whose
`response.created` may trail their start, a drop, failed handshakes and the
operator's stop: once the call settles, every tool output in the live
conversation has had a response start after it. This rests on
`RearmsOnRejection` (check 16), the fix for RT-1.

**Check 05** holds with a drop, failed handshakes, failed `session.update`s and
a closed socket's exit landing at any point:
- While the call lives, every open socket is `openai_pid`. This rests on
  `ClosesUnconfigured` (check 06).
- A live call always has a socket or a reconnect timer: the 43 s freeze that
  the comment at `session_server.ex:656-664` describes. This rests on
  `EndsWhenExhausted` (check 07) and on `OwnSocketOnly` (check 17).

**Check 08** holds with two drops and failed handshakes: the call gives up
only after running every reconnect attempt. This rests on
`ResetsAttemptsOnSuccess` (check 09).

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
01, 05, 08, 10 and 14: `Stop` is enabled in every live state. The only wedge
this model has room for is the freeze (no socket, no timer, an empty mailbox),
since tool calls and VAD never touch the socket or the timer, and check 05
asserts it directly as `NoFreeze`. Those five checks were also run once by hand
with the stop left out, so the deadlock check was live: all five still hold,
with no deadlock. Checks 12, 13 and 15 leave the stop out.

The holds checks were also run once by hand with one more of each entity. All
still hold:

| Check | Calls | Sockets | Attempts | Drops | VAD responses | States |
|---|---|---|---|---|---|---|
| 01 | 3 | 3 | 3 | 2 | 0 | 8,523 |
| 05 | 1 | 4 | 3 | 2 | 0 | 2,135 |
| 08 | 1 | 4 | 3 | 3 | 0 | 350 |
| 10 | 3 | 3 | 3 | 2 | 3 | 2,602,623 |
| 12 | 1 | 4 | 3 | 2 | 1 | 18,504 |
| 13 | 1 | 5 | 4 | 2 | 1 | 123,506 |
| 14 | 2 | 5 | 3 | 2 | 2 | 2,577,199 |
| 15 | 1 | 3 | 3 | 2 | 1 | 3,764 |

## Not modelled

- Audio, transcripts, usage and cost limits, the max-session timer, the screen
  feed, and `screen_share`, which is answered inline with no task. What
  `start_timers` does to the reconnect timer is modelled.
- `interrupt`. Its `response.cancel` only ends the active response early,
  which `RespDone` already allows at any time.
- A tool task crash. Its `:DOWN` is answered exactly like a result
  (`session_server.ex:402-407`).
- `call_start` and its failure path. A failed `call_start` stops the voice
  connection and the session with it (`local_voice_socket.ex:556-559`), and the
  socket it closed never became `openai_pid`.
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
- `SessionServer.handle_provider_event/2` (`session_server.ex:95`), a test
  seam that nothing in `lib` calls. It acts on an event without the pid check,
  so `NoFreeze`, `NoStrayTimer` and `NoTickWhileConnected` hold only while it
  stays a test seam.

## Findings

All three findings are fixed (efa5d125). Each write-up
keeps the defect as it was found: its line numbers are those of the code
before the fix (`origin/dev` `693970b7`, unchanged through `2a7bdaa4`). Each
was confirmed by walking the counterexample through that code, and each is
now reproduced by an ExUnit test that failed before the fix
(`apps/fermix_core/test/fermix_core/realtime/session_server_test.exs`). None
was reproduced on a running daemon. The `needs` checks named under each show
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
- **Checks:** 12, 13 and 14 now hold. Checks 18 (10 states), 19 (8 states),
  20 (11 states) and 21 (20 states) break them again with `OwnSocketOnly`
  off, and check 17 (12 states) breaks `NoFreeze` in check 05's setup.
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
