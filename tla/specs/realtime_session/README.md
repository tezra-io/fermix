# realtime_session: one voice call's tool turns and upstream socket

Models `FermixCore.Realtime.SessionServer` for one voice call after
`call_start`, with two concerns:
- **Tool turns.** A tool result becomes the model's next spoken response. The
  session appends the output and sends one `response.create` per answered
  batch (`finish_tool_turn`, `flush_deferred_response`). OpenAI runs its own
  response lifecycle, and server VAD starts responses of its own.
- **The upstream socket.** The call keeps one OpenAI socket across drops. This
  covers `schedule_reconnect`, the backoff timer, `attempt_reconnect`,
  `resume_provider_session` closing a socket it could not configure, and
  `end_call` once no attempt is left.

The session's mailbox is one FIFO in arrival order. Socket events, disconnect
notices, tool replies and timer messages all share it, and the session handles
the oldest first. Each socket is modelled with the OpenAI conversation behind
it:
- OpenAI reads client events in order.
- It runs at most one response per conversation.
- It rejects a `response.create` while a response is running
  (`conversation_already_has_active_response`).
- A response reads only the outputs appended before it started. The comment at
  `session_server.ex:1260-1266` records this ("snapshotted context").

The call starts connected on socket 1, with the operator's first response
under way. The checks use one or two tool calls, two to four sockets and two
or three reconnect attempts. Production has three attempts
(`session_server.ex:53`).

**Environment switches** (set per check):
- `Drops`: how many times the network or OpenAI may drop an open socket.
- `VadTurns`: how many more responses server VAD may start on the operator's
  speech (`create_response: true`, `openai_client.ex:417`).
- `OpensCanFail`: a reconnect's handshake fails. WebSockex then reports
  nothing, because `handle_initial_conn_failure` defaults to `false`
  (`websockex.ex:610`).
- `UpdatesCanFail`: a reconnect's socket opens, but sending `session.update`
  to it fails.
- `UsersCanStop`: the operator ends the call (`call_stop`).
- `MaxSockets` bounds the sockets a call may open. Past it, every further open
  fails as if the network were down.

**Mechanism switches** (`TRUE` is the real code; each is switched off by
exactly one check):
- `DefersWhileCallsPending`: `finish_tool_turn` holds the trigger while other
  calls of the batch are in flight (`session_server.ex:1267`).
- `DefersWhileResponseActive`: it also holds the trigger while OpenAI's
  response is active, and `response.done` sends it (`:1271`,
  `flush_deferred_response` `:1280`).
- `CancelsToolsOnReconnect`: `schedule_reconnect` kills in-flight tool tasks,
  and `Task.shutdown` flushes their replies (`:607`, `:687-688`).
- `ClosesUnconfigured`: `resume_provider_session` closes a socket whose
  `session.update` failed (`:655`).
- `EndsWhenExhausted`: with no reconnect left, the call ends (`end_call`,
  `:671`).
- `ResetsAttemptsOnSuccess`: a successful reconnect resets
  `reconnect_attempts` (`:470`).

**Timing idealisation:** `LateCloseNotice`. `TRUE` is the real code. A socket
the session closes (`OpenAIClient.close`) still reports a disconnect, but only
after its close handshake or WebSockex's 5 s close timeout
(`websockex.ex:925-931`). The first backoff delays are 1 s and 2 s, so that
notice can arrive after the next reconnect timer. `FALSE` makes the notice
arrive before any reconnect timer fires. A check that sets it `FALSE` proves a
property only for a network that finishes the close handshake inside the
backoff delay.

## What holds

**Check 01** holds with a socket drop, failed reconnect handshakes and the
operator's stop:
- Once the call settles, every tool output in the live conversation has had a
  response start after it. This rests on `DefersWhileCallsPending` (check 02).
- OpenAI never rejects a trigger. This rests on `DefersWhileResponseActive`
  (check 03).
- A tool output only ever joins the conversation that called it. This rests
  on `CancelsToolsOnReconnect` (check 04).

Check 01 has no VAD responses beyond the first. With them, the first two rules
break (RT-1).

**Check 05** (idealised) holds with a drop and failed handshakes and
`session.update`s:
- While the call lives, every open socket is `openai_pid`. This rests on
  `ClosesUnconfigured` (check 06).
- A live call always has a socket or a reconnect timer. This rests on
  `EndsWhenExhausted` (check 07). This rule, the 43 s freeze that the comment at
  `session_server.ex:662-670` describes, needs no idealisation: no finding
  breaks it.

In the real code the first rule does not hold; see RT-2.

**Check 08** holds with two drops and failed handshakes: the call gives up
only after running every reconnect attempt. This rests on
`ResetsAttemptsOnSuccess` (check 09). A failed `session.update` breaks it
(RT-3).

The holds checks were also run once by hand with one more of each entity. All
three still hold:
- Check 01 with three calls, three sockets, three attempts and two drops
  (7,398 states).
- Check 05 with one call, four sockets, three attempts and two drops
  (435 states).
- Check 08 with one call, four sockets, three attempts and three drops
  (275 states).

## Not modelled

- Audio, transcripts, usage and cost limits, the max-session timer, the screen
  feed, and `screen_share`, which is answered inline with no task.
- `interrupt`. Its `response.cancel` only ends the active response early,
  which `RespDone` already allows at any time.
- A tool task crash. Its `:DOWN` is answered exactly like a result
  (`session_server.ex:400-405`).
- A socket's `EXIT`. The disconnect notice always comes first, and the `EXIT`
  clause (`:443`) matches only `openai_pid`, which the notice has already
  cleared.
- `call_start` and its failure path. A failed `call_start` stops the voice
  connection and the session with it (`local_voice_socket.ex:556-559`), so no
  later notice can reach a live call.
- The network between OpenAI and the socket process. An event OpenAI emits
  lands in the session's mailbox in the same step.
- WebSockex itself (`deps/websockex`, 0.5.1 in `mix.lock`). It cannot be
  pinned; the behaviour the spec relies on is cited above.

## Findings

Every finding below was confirmed by walking the counterexample through the
code on `dev`. None has been reproduced on a running daemon. To see a
counterexample, run `make -C tla check SPECS=realtime_session` and open
`tla/out/realtime_session/<check>.txt`.

### RT-1: a tool result that lands as a VAD response starts is never spoken
- **Severity:** low to medium. The window is about one network round trip,
  but the operator then hears nothing about the result until they speak again.
- **Status:** open.
- **Checks:** 10 (15 states), 11 (11 states).
- **Counterexample (check 10):**
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
    about.
- **Impact:**
  - This is the silent stall that `finish_tool_turn`'s comment describes
    fixing for two calls in one batch. It still happens when the operator
    speaks while a tool runs and the result lands as their turn is committed.
  - The model answers what the operator said, without the result. It stays
    silent about the result until the operator speaks again.
- **Check 11** breaks the "exactly one `response.create` per answered batch"
  claim (`:196-199`). In its shortest path the VAD response started after the
  output joined, so it read it: the rejection alone loses nothing. Only check
  10's order, with VAD's response starting first, loses the answer.

### RT-2: a closed socket's late disconnect notice orphans the live socket
- **Severity:** medium when it happens. The trigger is rare: a reconnect's
  `session.update` must fail, and the network must then be slow to close
  that socket but recover in time for the next attempt.
- **Status:** open.
- **Checks:** 12 (10 states), 14 (19 states); witness 13.
- **Counterexample (check 12):**
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
  - The disconnect clause (`:422`) matches a notice from any socket, while the
    `EXIT` clause (`:443`) matches only `openai_pid`. The comment at
    `:645-648` expects the closed socket's later `EXIT` to race the attempt
    that replaced it. It is the notice that does.
  - Socket events are not checked against `openai_pid` either (`:383`).
  - **Witness 13** is a second route. The notice arrives, and the next timer
    fires before the session has handled it:
    1. `schedule_reconnect` cancels a timer that already fired, which does
       nothing to its queued message, and arms another (`:623-624`).
    2. The queued message then connects and sets `reconnect_timer` to nil
       (`:471`), dropping the ref to the new timer.
    3. That timer later fires into the connected call. `attempt_reconnect`
       (`:639`) has no guard, so it opens yet another socket and overwrites
       `openai_pid` without closing the old one.
- **Impact:**
  - The healthy socket stays open and linked to the session until the call
    ends: a billed upstream connection that nothing owns.
  - The call reconnects for no reason. The companion is told "reconnecting",
    in-flight tools are killed, and the screen feed is suspended.
  - Events from the orphaned conversation keep arriving and are handled as
    the current one's:
    - its audio deltas reach the companion;
    - its `response.created` and `response.done` move `response_active?`;
    - a tool it calls runs, with its side effects, and the output is sent to
      the new conversation, which never called it (check 14).

### RT-3: a failed `session.update` costs two reconnect attempts
- **Severity:** low.
- **Status:** open.
- **Check:** 15 (8 states). It runs with `LateCloseNotice = FALSE`, so it
  happens even when the notice arrives promptly.
- **Counterexample:**
  1. Socket 1 drops, and attempt 1 of 2 is scheduled.
  2. Socket 2 opens, `session.update` fails, the socket is closed, and attempt
     2 is scheduled.
  3. Socket 2's notice arrives before that timer fires. `schedule_reconnect`
     runs again, finds attempt 2 of 2 used, and calls
     `end_call(:provider_disconnected)`. Only one attempt ever ran.
- **Code:** the same unguarded disconnect clause (`:422`). Each
  `schedule_reconnect` call counts an attempt (`:634`), and the one for the
  notice cancels the timer the failed attempt armed (`:623`).
- **Impact:** in production, with three delays, a failed `session.update`
  uses two of the three attempts. The call gives up after two real attempts,
  and its 2 s wait becomes 4 s. If the second attempt is the one that fails
  this way, the call ends at once and the third attempt never runs.
