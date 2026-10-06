# turn_queue: the per-conversation turn queue

Models `FermixChannels.Gateway.Queue` for one conversation: the FIFO of waiting
messages, the one active turn, the turn task's steps (including a failed
MainAgent checkout), the stop that names one message, and how each turn's
result reaches its channel through
`turn_result_fn`. That callback matters to ACP, mobile and voice, which attach
one and wait on it. It also models `Gateway.QueueSupervisor`, which restarts
the Queue together with the turn tasks it started, and one waiting consumer,
`Acp.Peer`, with its watch on the Queue it handed each prompt to. Other
conversations are independent by construction, so one conversation with two
messages covers the interleavings that matter.

**Environment switches** (set per check):
- `UsersCanStop`: `/stop` (through `Stopper` to `Queue.stop_all`), or an ACP
  cancel (`Queue.stop_conversation`). Both go through one per-conversation
  stop path, so they have the same effect on one conversation.
- `UsersCanStopTurn`: a stop that names one message, `Named`
  (`Queue.stop_turn`): a `cancel` from the companion socket or the phone,
  which `Companion.Turns` sends, or a Live call's cancel or hang-up, which
  `Voice.Bridge` sends for the call's own hand-off by its message id
  (`voice-delegation-<id>-<revision>`). Several senders share that
  conversation (the Mac's and the phone's turns run in the chat's one lane,
  M56 D9, and so do a call's hand-offs unless the call is private, M56 §4.1),
  so a stop can name a waiting message while another sender's turn runs, and
  it can arrive after its own turn ended.
- `TasksCanCrash`: the turn task dies at any step. Its own code raises or
  exits, or a linked helper exits: the typing loop (`typing.ex:24`, linked
  until `with_indicator` returns) or DraftStream (`draft_stream.ex:182`,
  linked until the task exits). A helper's exit can land anywhere, including
  where nothing in the task can raise: between delivering the reply and
  marking it delivered ("shown"), in the claim gap ("invoking"), and after the
  outcome was invoked ("done").
- `QueueCanCrash`: the Queue GenServer dies and its supervisor restarts it with
  empty state.

**Mechanism switches** (`TRUE` is the real code; each is switched off only by
the checks that show a property needs it):
- `OneClaimant`: the Queue hands the callback to the claimant and clears its
  own copy (`queue.ex:250-259`, `:1127-1131`).
- `StartsWhenIdle`: a message starts only when no turn is active
  (`queue.ex:317-325`).
- `CrashFiresOutcome`: a crashed turn's callback, if the Queue still holds it,
  fires `{:failed, _}` (`queue.ex:914-922`).
- `TurnsShareQueueFate`: turn tasks run under a `Task.Supervisor` that
  `QueueSupervisor` (`:one_for_all`) terminates before it restarts the Queue
  (`queue_supervisor.ex:46-51`, `application.ex:60`).
- `CrashClosesUserMessage`: a crashed turn's `:DOWN` writes the stopped marker
  before the next message starts (`queue.ex:873`, `:887-893`).
- `StopSparesClaimedTurn`: a stop leaves a turn that has claimed its outcome
  running (`queue.ex:1085-1087`).
- `StopCancelsPending`: a stop fires `{:cancelled}` for every waiting message
  it drops (`queue.ex:1105-1111`).
- `StopTurnSparesClaimedTurn`: a named stop leaves the named turn running once
  it has claimed its outcome (`queue.ex:1042-1048`).
- `StopTurnNamesTurn`: a named stop ends the named message's turn only: it
  kills that turn if it is active, or drops that message if it is waiting,
  and the next waiting message starts (`stop_named_in`, `queue.ex:1042-1079`).
  `FALSE` is the conversation stop, the only stop the Queue had before, which
  kills whichever turn is running.
- `ConsumerFencesQueue`: the consumer monitors the Queue process it handed the
  message to and answers the message as a failed turn on that Queue's `:DOWN`
  (`Acp.Peer`: `hand_off`, `peer.ex:597-605`; `settle_queue_down`, `:205-207`,
  `:954-959`).

**Timing idealisation:** `CrashInClaimGap`. `TRUE` is the real code. A turn
finishes in two steps (`finish_turn`, `queue.ex:587-593`):
1. The turn claims the callback from the Queue.
2. The turn invokes that callback, inside its own task.

`invoke_turn_result` catches whatever the callback raises, exits or throws
(`queue.ex:933-948`), and a stop no longer kills a claimed turn, so only a
linked helper's exit can land between the two steps. `FALSE` forbids that. A
check that sets it `FALSE` proves a property only for a Queue without the gap.

**Queue restart in two steps:** `QueueDown` (the Queue dies; its turns keep
running and can still deliver and commit, witness 09; no message can start)
and `QueueRestart` (the supervisor kills every turn task, then restarts the
task supervisor and the Queue). A message sent between the two is lost, not
sent later: `enqueue/2` casts to the registered name (`queue.ex:104-107`), and a
cast to an unregistered name is dropped silently (QUEUE-8). `Acp.Peer` is not
exposed to that: it resolves the name first and hands the prompt to that
process, so a prompt that finds no Queue is refused at once, and one handed to
a Queue that dies gets the `:DOWN`. The model disables `Send` there only to
stay small. Without `TurnsShareQueueFate`, `QueueDown` alone is today's
`:one_for_one` restart: the Queue is back at once and its turns keep running.

**The Peer's watch:** `QueueDown` puts a `:DOWN` in the Peer's mailbox for
every message the dead Queue held, active or waiting, unless the Peer already
has that message's result: the result is then ahead of the `:DOWN`, answering
it closes the turn, and closing flushes the `:DOWN`. `PeerSettles` is the Peer
handling the `:DOWN`: it answers the message as a failed turn. The model takes
the Peer's mailbox order to be send order. Erlang orders only each sender's
own messages, so the real order of a `:DOWN` and a result can differ; that
changes which of the two answers the prompt, never whether it is answered or
how often.

## What holds

**Check 01** holds with `/stop` and crashes allowed anywhere, including the gap:
- No turn's result ever fires twice. This rests on `OneClaimant`; check 02
  shows the rule breaks without it: a helper exit after the invoke would make
  the crash path fire a second outcome.
- There are never two live turn tasks for one conversation. This rests on
  `StartsWhenIdle` (check 03).

**Check 04** (idealised): every started turn gets its result, with `/stop` and
crashes allowed everywhere except a crash in the claim gap. This rests on
`CrashFiresOutcome` (check 05). In the real code a helper exit in the gap
still loses the result; see QUEUE-9. Witness 06 shows that a stop or crash can
land exactly when the turn is about to claim.

**Check 07** holds with `/stop`, crashes and Queue restarts: never two live
turn tasks for one conversation, and no turn commits while another turn of the
conversation starts. Both rest on `TurnsShareQueueFate` (checks 07b and 07c).

**Check 12** holds with `/stop` and crashes: once no turn runs, no user message
is left unanswered in history. This rests on `CrashClosesUserMessage`
(check 12b).

**Check 15** holds with `/stop` anywhere: every message sent gets a result,
including the waiting messages a stop drops. This rests on
`StopCancelsPending` (check 15b).

**Check 16** holds with `/stop` anywhere, including between the claim and the
invocation: every started turn gets its result. This rests on
`StopSparesClaimedTurn` (check 16b).

**Check 18** holds with a named stop anywhere and crashes: a stop that names
one message never cancels another. This rests on `StopTurnNamesTurn`
(check 18b, 8 states): the conversation stop, given a waiting message's name,
kills the turn that is running instead. Check 01 also allows a named stop.

**Check 19** holds with a named stop anywhere, including after the named turn
claimed its outcome: every message sent gets a result. This rests on
`StopTurnSparesClaimedTurn` (check 19b): a named stop that killed a claimed
turn would take its outcome with it.

**Check 17** (idealised like check 04): with `/stop`, crashes and Queue
restarts, the Peer answers every message sent, by its result or from the dead
Queue's `:DOWN`. This rests on `ConsumerFencesQueue` (check 17b). Witness 17c
shows that a turn that claimed its result before its Queue died can still send
it after the `:DOWN` reached the Peer, so the Peer holds two answers for one
prompt. It writes only the first: answering closes the turn, and the wire fence
drops every later event for it (`apply_if_open`, `peer.ex:772-778`). The
ExUnit test "a Queue crash answers the prompt in flight as a failed turn,
once, and accepts the next" (`acp/peer_test.exs`) pins that. The model allows
no stop while the Queue is restarting, and check 17 does not cover that
window. There the Peer's cancel goes to the dead Queue it handed the prompt
to (`stop_turn`, `peer.ex:726-734`) and exits `:noproc`: a `session/cancel`
is answered `cancelled` and closing the turn flushes the `:DOWN`
(`cancel_turn`, `:700-705`), and the connection lives on (QUEUE-8, What
remains). ExUnit pins it: "a cancel that finds its prompt's Queue gone
answers cancelled, once", "a cancel by request id that finds its prompt's
Queue gone answers once" and "a bridge disconnect after the Queue died ends
the Peer normally" (`acp/peer_test.exs`).

The checks use two messages. Checks 01, 04, 07, 12, 15, 16 and 17 were also
run once by hand with three messages. All still hold (34,736, 21,922, 709,122,
34,736, 11,482, 11,482 and 587,927 states; 07 was re-run after the Peer's
watch was added to the model).

## Not modelled

- The LLM and tools (one "loop" step), streaming drafts, and typing.
- The access gate's parked confirmation. `run_message_loop` hands AgentLoop
  the owner-inbox closure and the Live call id (`turn_runner.ex:532`,
  `:536`). A parked call is a held tool result inside the one loop step, and
  the owner's confirm later runs it on a task outside the Queue, not as a
  new turn.
- The `terminal_error_owner?` branch, which only changes who sends the error
  text.
- The empty-completion path (`queue.ex:541-544`, `:723-732`). It delivers a
  canned retry, commits nothing and claims `{:completed}`. It leaves the user
  message unanswered by design, so that the owner can retry.
- A daemon stop: the Queue dies and nothing restarts it. Turns in flight leave
  their persisted user message without a marker.
- Which conversation a message keys into. That is decided before the Queue,
  by `ConversationKey.from/1`: a Live hand-off keys into the conversation its
  trusted `voice_call` names (the chat's unless the call is private), and is
  then one more message of that FIFO, persisted by `persist_user_message`
  like any other (marked spoken, a mark only the memory review acts on).
- The compaction notices. A hand-off sends neither the preflight nor the
  post-commit one (`maybe_notify_compacted`), and neither is a step here.
- What a turn tells its channel's stream. A hand-off's runner tells it, before
  the reply, that the reply will carry the Computer History stamp `commit/4`
  puts on it (`tell_history_tainted`, M56 §9), so the Live session never
  says it. It is a send inside the turn's own steps and moves no Queue state.
- What an owner's turn reads before its loop: the gists of the last voice
  calls (`inject_recent_calls`, M56 §4.2), one Repo read inside the turn's own
  steps that moves no Queue state.
- The boot pass that writes the chat rows Live calls still owe
  (`Voice.CallRowSweep`, M56 §4.2). `application.ex` starts it after every
  other child; it writes timeline rows and never reaches the Queue.
- Consumers other than `Acp.Peer`. `Companion.Turns`, the settlement owner of
  the companion socket's turns and the phone's alike, watches the Queue it
  handed each turn to and answers the turn the Peer's way, with one
  `turn_error` (`interrupted`), dropping a result that arrives after it. It
  holds the request's fence, so the request is failed once, not released for a
  re-run. Voice watches nothing.

## Findings

Every finding below was confirmed by walking the counterexample through the
code on `dev`. None has been reproduced on a running daemon. To see a
counterexample, run `make -C tla check SPECS=turn_queue` and open
`tla/out/turn_queue/<check>.txt`.

### QUEUE-1: a Queue restart orphans the running turn
- **Severity:** medium. The trigger is rare, but the outcome is bad.
- **Status:** fixed (d514e149). The outcome half is split
  out as QUEUE-8.
- **Checks:** 07 (holds), 07b and 07c (without `TurnsShareQueueFate` they
  reproduce the old 4-state trace and the orphan commit). Witness 09 now shows
  the window that remains.
- **Counterexample (before the fix):** m1's turn starts, then the Queue
  crashes and restarts. m2 arrives and starts while m1's task is still alive.
- **Code (before the fix):**
  - Turn tasks ran under `FermixCore.TaskSupervisor`, which is not linked to
    the Queue.
  - The Queue was a `:one_for_one` child of `FermixChannels.Supervisor`.
  - The orphan kept the dead Queue's pid. Before `fresh?` it delivered and
    committed nothing; after `fresh?` it delivered and committed its reply
    while the new Queue's turn ran, and nobody could stop it.
- **Fix:** `FermixChannels.Gateway.QueueSupervisor` (`queue_supervisor.ex`)
  runs `{Task.Supervisor, name: FermixChannels.Gateway.TurnTasks}` and the
  Queue, in that order, `:one_for_all`; `application.ex:60` starts it in the
  Queue's slot. `:task_supervisor` is a required Queue option
  (`queue.ex:199`), so no Queue runs turns under a supervisor that outlives
  it. When the Queue dies, the supervisor terminates the task supervisor, and
  with it every turn, before a new Queue exists.
- **What remains:** between the Queue's death and the supervisor handling it,
  a turn that already passed `fresh?` can still deliver and commit (witness
  09); no other turn runs then. The killed turns get no outcome and their user
  messages no marker: QUEUE-8.

### QUEUE-2: a `/stop` just after delivery drops the reply from history
- **Severity:** low.
- **Status:** accepted by design.
- **Check:** 10 (6 states).
- **Counterexample:** the reply is delivered (`deliver_final`, `queue.ex:547`).
  `/stop` then arrives before `runner.commit` persists it (`:551` →
  `turn_runner.ex:151`).
- **Code:**
  - `stop_active_turn` kills the task and writes the stopped marker
    (`queue.ex:1095-1100`, `:1145-1158`).
  - The marker is written because the last stored message is still the
    user's (`conversation_store.ex:173`).
- **Impact:** the user saw a full answer, but history says "stopped before I
  finished it". The next turn's model does not know it already answered.
- **Why accepted:** a stop wins until the turn claims its outcome. That is
  consistent with the `{:cancelled}` the channel is told (QUEUE-3) and with
  M29 §8.5's merged re-prompt, for which the marker is "precisely right"
  (`docs/design/MILESTONE_29_ACP_AGENT_SURFACE.md` §8.5). The window runs
  from `deliver_final` returning to the store's `add_message`: a few
  milliseconds. A human `/stop` reacting to the reply arrives hundreds of
  milliseconds later over a long-poll channel, far too late to hit it; only a
  coincident stop or an automated cancel can. The stop docs (`queue.ex:114-136`) and the `self_knowledge` skill
  now say so instead of claiming a stopped turn never delivers.

### QUEUE-3: `cancelled` is reported for a turn the user saw answered
- **Severity:** low.
- **Status:** accepted by design.
- **Check:** 11 (6 states).
- **Counterexample:** the reply is delivered, then `/stop` arrives before the
  task claims its result.
- **Code:** `commit/4` runs auto-compaction synchronously (`queue.ex:551` →
  `turn_runner.ex:182`). The claim happens only after that returns
  (`finish_turn`, `queue.ex:519`), so the window also covers post-delivery
  auto-compaction: seconds to tens of seconds when it runs. The kill aborts
  that compaction (safely: `replace_history` is one atomic call) and skips
  `record_context_tokens_peak`.
- **Impact:** the channel gets `{:cancelled}` after the full reply. ACP reports
  stop reason `cancelled` for an answered prompt; mobile marks the rendered
  turn failed.
- **Why accepted:** the property is a proposed rule that the ACP contract
  Fermix implements rejects. After `session/cancel` the agent must answer the
  in-flight prompt with `stopReason: "cancelled"`
  (`docs/design/MILESTONE_29_ACP_AGENT_SURFACE.md`, the `session/cancel` row
  of the Buzz table, and §8.5). The race test "a stop landing before the
  turn's terminal claim fires only {:cancelled}" (`queue_test.exs`) pins it.

### QUEUE-4: a crashed turn leaves its user message unanswered
- **Severity:** low. It happens on crash paths only.
- **Status:** fixed (d514e149).
- **Checks:** 12 (holds), 12b (without `CrashClosesUserMessage`: the old
  4-state trace).
- **Counterexample (before the fix):** the user message is persisted, then the
  task crashes.
- **Code (before the fix):** `clear_active_request` sent the generic error and
  failed the turn result, but wrote no stopped marker, while the stop and
  error paths both wrote one.
- **Fix:** `clear_active_request` calls `maybe_close_crashed_turn`
  (`queue.ex:873`, `:887-893`), which writes the marker through
  `mark_stopped_turn` synchronously, inside the `:DOWN` handler, before the
  next message starts. Written later it could close the next turn's user
  message. `mark_stopped_turn` now logs a store exit instead of skipping it
  silently.
- **What remains:** a crash after the reply was delivered but before it was
  committed now gets the marker ("stopped before I finished it"), the same
  trade-off as QUEUE-2. The Queue now makes a synchronous store call in its
  `:DOWN` handler, as its stop path already did. While a stuck store blocked
  the Queue there (up to the 5 s call timeout, once per marker), other
  turns' `fresh?` and claim calls could time out, and those calls treated
  any exit as "Queue gone", so those turns silently discarded their replies.
  Fixed (f1712e1e): a turn's calls to its Queue, and the
  stop calls, wait with no timeout, because every Queue callback is bounded
  (the client API note, `queue.ex:80-91`); each catch now means only a dead
  Queue, and logs it (`queue.ex:597-603`, `:678-701`). The model's
  `Fresh(m)` never allowed the timeout, so no check changed. ExUnit pins it
  in "a Queue busy in a slow store call" (`gateway/queue_test.exs`): each
  test holds the Queue in a gated store call, traces the calls waiting on it
  (the turn's `fresh?`, delivered mark and claim; `stop_all`;
  `stop_conversation`) and asserts that none carries a timeout. The store is
  released as soon as the call is seen waiting, so no test waits out the old
  5 s budget; a call that still carries one fails the trace assertion
  instead.

### QUEUE-5: a crash between delivery and marking it sends an error after the reply
- **Severity:** low. It happens on crash paths only.
- **Status:** accepted by design.
- **Check:** 13 (6 states).
- **Counterexample:** `deliver_final` succeeds, then the task dies before
  `mark_final_reply_delivered` (`queue.ex:547-548`).
- **Code:** `maybe_reply_on_crash` (`queue.ex:898`) checks the flag that the
  second call would have set. Nothing in the task can raise between those two
  calls (`mark_final_reply_delivered` catches exits), so only a linked
  helper's exit (typing loop or DraftStream) can kill it there, within one
  `GenServer.call`.
- **Impact:** the user gets "Sorry, I encountered an error…" after the full
  reply. The turn did crash before its commit, so the error is not false.
- **Why accepted:** setting the flag before delivery would silence the error
  for a crash during delivery, which is worse. The microseconds between the
  two steps are inherent.

### QUEUE-6: a `/stop` or crash between claiming the result and invoking it loses the result
- **Severity:** low to medium. The window is microseconds on the `/stop` path,
  but the waiting channel hangs.
- **Status:** fixed (d514e149). The helper-exit residual is
  split out as QUEUE-9.
- **Checks:** 16 (holds), 16b (without `StopSparesClaimedTurn`: the old
  lasso). Check 14 now records QUEUE-9.
- **Counterexample (before the fix, check 16):** the reply is committed. The
  task claims its callback, and the Queue clears its own copy. A `/stop` then
  kills the task before `invoke_turn_result` runs, and nothing fires.
- **Code (before the fix):**
  - The stop found no callback to fire and dropped the monitor with the
    conversation.
  - `invoke_turn_result` rescued exceptions only, so a callback that exited
    or threw crashed the task; its `:DOWN` then found no callback.
- **Fix:**
  - The active entry records `claimed?` (`queue.ex:842`); the claim handler
    replies the closure (or nil) and sets `claimed?: true` and
    `turn_result_fn: nil` (`:250-259`, `:1127-1131`).
  - `stop_active_turn` leaves a claimed turn running with its slot and
    monitor (`:1085-1087`); its `:DOWN` clears the slot through the normal
    path, so single flight stays exact. It is not counted in
    `active_stopped`.
  - `invoke_turn_result` also catches `:exit` and `:throw`, and logs every
    kind (`:933-948`).
- **Trade-off:** `/stop` can no longer cut a claimed turn whose closure hangs.
  Today's closures are bounded (ACP sends, voice dispatches, and the companion
  and phone channels' call into `Companion.Turns`, whose store calls time
  out).
- **Impact (before the fix):** an ACP prompt was never answered and the
  session refused later prompts; a mobile request stayed `running` and was
  re-run after the next restart; voice lost only a `{:failed}` on the error
  path (a cancel is settled by the Live session itself).

### QUEUE-7: a `/stop` drops waiting messages without ever answering them
- **Severity:** medium on mobile, low elsewhere.
- **Status:** fixed (d514e149).
- **Checks:** 15 (holds), 15b (without `StopCancelsPending`: the old lasso).
- **Counterexample (before the fix):** m1 is running and m2 waits in the
  queue. `/stop` cancels m1 and drops m2 without an outcome.
- **Code (before the fix):** the stop fired only the active turn's callback
  and discarded pending messages with the conversation. That broke the rule
  at `queue.ex:380`: "a turn-result consumer must never be left waiting".
- **Fix:** `stop_all` and `stop_conversation` share one per-conversation
  path (`stop_conversation_runtime`, `queue.ex:1027-1031`), whose
  `cancel_pending` fires `{:cancelled}` for every dropped message through the
  off-process, nil-safe `invoke_turn_result_async` (`:1105-1111`). A claimed
  turn's waiting messages are cancelled the same way. Pending messages were
  never persisted, so no marker is needed.
- **Impact by channel (before the fix):**
  - Mobile: the dropped request stayed `running`; resends were answered as
    duplicates, and the next boot re-ran the message the user stopped. The
    trigger is ordinary: two quick messages, then a stop.
  - ACP: reachable through harness continuations, which ingest into the
    session's conversation; a prompt queued behind one was never answered
    after `session/cancel`.
  - Voice: unaffected; a call holds at most one delegation in the Queue.

### QUEUE-8: a Queue restart gives the dead Queue's turns and waiting messages no result
- **Severity:** medium. The trigger (a bug-class raise in a Queue callback) is
  rare.
- **Status:** mitigated (d514e149). ACP and mobile watch the
  Queue process; voice is accepted. The Queue itself still fires nothing, so
  check 08 stays violated.
- **Checks:** 08 (a liveness lasso; its length is not pinned) on the Queue's
  own results; 17 (holds) and 17b (without `ConsumerFencesQueue`: the lasso
  again) for the Peer; witness 17c.
- **Counterexample (check 08):** m1's turn starts; the Queue dies;
  `QueueSupervisor` kills m1's task and restarts. Nothing ever fires m1's
  result.
- **Code:** the restart kills the turn tasks (QUEUE-1's fix), but no process
  fires the `turn_result_fn` of the dead Queue's active turns or waiting
  messages, and no `:DOWN` handler runs for them, so their user messages get
  no marker either.
- **Owner decision:** `Acp.Peer` monitors the Queue it handed each prompt to
  and answers the prompt on that Queue's `:DOWN` the way it answers a failed
  turn. Voice stays as it is: the call is bounded and the operator can cancel
  it.
- **Fix (ACP):**
  - `hand_off` (`peer.ex:597-605`) resolves the Queue's name to a pid with
    `GenServer.whereis`, as `Companion.Turns` does at its hand-off
    (`turns.ex:273-278`), gives the prompt to that pid, and monitors it.
    The monitor is on the process that holds the prompt, so it also covers a
    Queue that dies during the hand-off. No Queue registered: the prompt is
    refused at once (`{:queue_unavailable, name}`, the existing "could not be
    queued" answer).
  - The turn keeps the monitor (`Session.put_queue_ref`). On the `:DOWN`,
    `settle_queue_down` (`peer.ex:205-207`, `:954-959`) calls
    `apply_turn_result` with `{:failed, {:queue_down, reason}}`: the same path
    as any failed turn, so it answers an error the client may retry, or
    `end_turn` once the turn performed an effect. The error is always -32603:
    the Queue calls no provider, so its exit reason is never read as an auth
    failure (`auth_failure?`). It closes the turn, so the session accepts the
    next prompt.
  - Every answer goes through `close_turn` (`peer.ex:972-982`), which drops
    the monitor with `:flush`: a completed, cancelled or failed turn leaves no
    watch and no stray `:DOWN`. A result that arrives after the `:DOWN`
    answered is dropped by the wire fence (witness 17c).
  - A prompt handed to a Queue that died before the cast now gets the
    Gateway's "I'm restarting" chunk and then the failed answer; before, it
    got the chunk and nothing else.
- **Impact by channel (after the fix):**
  - ACP: every prompt handed to a Queue that dies is answered once; the session
    stays usable.
  - Companion socket: like ACP. `Companion.Turns` tracks every turn it hands
    to a Queue, ends each one on that Queue's `:DOWN` with one `turn_error`
    (`interrupted`), and drops a result that arrives after it.
  - Mobile: like the companion socket. Its turns go through
    `Companion.Turns` too, which holds each request's fence
    (`RequestCoordinator.handoff` moves it there once ingest returns) and
    fails the request once on the Queue's `:DOWN` instead of releasing it for
    a re-run.
  - Voice: accepted. The delegation stays open until the operator cancels it
    or the call ends.
  - Every channel without a watch: a message sent while the Queue is
    restarting is dropped by the cast to the unregistered name and gets no
    outcome.
- **What remains:** the dead Queue's turns still get no stopped marker, so
  their persisted user messages stay open in history; an ACP retry of the
  failed prompt adds a second user message after the open one. A turn that
  finished its reply just as its Queue died can be answered as failed, if the
  `:DOWN` reaches the Peer before the result. A cancel that reached the Peer
  while no Queue was registered (`session/cancel`, `$/cancel_request` or a
  bridge disconnect, all through `stop_turn`) exited `:noproc` in its call
  to the Queue's name: the Peer's connection ended and
  its open prompts got no answer. Fixed (f1712e1e): the
  turn keeps the Queue it was handed to beside its monitor
  (`Session.put_queue_ref`), `stop_turn` (`peer.ex:726-734`) stops that
  Queue and reads only `:noproc` as "gone", a `session/cancel` is then
  answered `cancelled` (`cancel_turn`, `:700-705`), `$/cancel_request`
  still answers -32800, and a disconnect moves on to the next session.
  Closing the turn flushes the dead Queue's `:DOWN`, so each prompt is
  answered once. The model allows no stop while restarting, so check 17
  still does not cover it; ExUnit does (see Check 17). Still open: a Queue
  that dies during the stop call, rather than before it, exits the call with
  its own reason, not `:noproc`, and that still ends the Peer's connection
  (reported, not fixed).

### QUEUE-9: a linked helper exiting between the claim and the invocation loses the result
- **Severity:** low. The window is microseconds.
- **Status:** open. Owner question below; recommended: accept for now.
- **Check:** 14 (a liveness lasso; its length is not pinned).
- **Counterexample:** the reply is committed and the task claims its
  callback. Before `invoke_turn_result` runs, the task dies, and the crash
  path finds no callback to fire.
- **Code:** after QUEUE-6's fix neither a stop nor the callback itself can
  kill the task in that gap. A linked helper still can: the typing loop
  (`typing.ex:24`, linked until `Typing.with_indicator` returns, which is
  after `finish_turn`, `queue.ex:422`) or DraftStream (`draft_stream.ex:182`,
  linked until the task exits; its post-seal sweep runs beside the commit).
- **Owner question:** close this too, by calling `finish_turn` after
  `Typing.with_indicator` returns (`turn_task/7` would take the outcome from
  `checkout_and_run` instead of claiming inside it) and unlinking the
  DraftStream after a successful seal? `typing.ex:4-9` promises that a typing
  exception crashes the turn; that would still hold for the turn's work, but
  no longer for delivering its outcome. Recommendation: accept the residual
  now and revisit if helper crashes show up in traces.
