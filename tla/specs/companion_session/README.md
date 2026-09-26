# companion_session: the companion chat wire, one shared conversation

A **design spec**, written before the code. It models the companion chat wire
for one shared conversation: the Mac app and the iPhone app, each on its own
connection to a 0600 Unix socket (newline JSON, protocol 1, a mandatory
`client_hello`/`server_hello`), connecting and dropping at any time. The
modules it describes do not exist yet:
- `FermixCore.Companion.Protocol`: the wire events and the handshake.
- `FermixChannels.Companion.Endpoint`: one process per daemon. It dedupes
  `msg` on `client_msg_id`, writes every row the conversation produces, fans
  rows out to subscribed connections, hands turns to the Queue and holds the
  pending approval.
- Its socket handler: one process per connection. It runs the handshake and
  the subscription, and answers `history_pull` straight from the Timeline.
- `FermixCore.Companion.Timeline`: the durable rows, one `server_seq` each,
  written through `Memory.Repo`.

Their `SOURCE` pins follow the first engine commit that lands them: re-read
each step against that code, add the pins, and re-run. Until then the spec
pins the one module that exists, `FermixChannels.Gateway.Queue`, by the
functions whose rules it composes with (`stop_conversation`,
`maybe_start_next_request`, `claim_active_turn`, `stop_conversation_runtime`,
`stop_active_turn`, `cancel_pending`).

**The processes.**
- Each app keeps an outbox of typed messages until each is accepted, and a
  cursor: the last `server_seq` it shows.
- Each connection's socket handler.
- The Endpoint and its mailbox, which receives the Queue's outcomes and the
  job's delivery notice.
- The Gateway Queue with its turn tasks.
- The Timeline.
- A scheduled job reporting back into the conversation: it writes its row
  through the Timeline, then tells the Endpoint.

**The Queue is one abstract process.** The runner takes one `.tla` per spec,
and `turn_queue` already proves the Queue's rules against its code, so this
spec takes them as given rather than restating that model:
- one turn at a time per conversation (`maybe_start_next_request`;
  `turn_queue`'s `SingleFlight`, which rests on `StartsWhenIdle`);
- one outcome per turn, through the claim (`claim_active_turn`;
  `AtMostOneOutcome`);
- a stop spares a claimed turn and cancels every waiting message
  (`stop_active_turn`, `cancel_pending`; `turn_queue` checks 15 and 16).

As in `queue.ex`, a turn starts in the callback that enqueues it or that
clears the previous turn. It then takes three steps of its own: an optional
approval, the claim (after the commit), and the invocation of `{:completed}`.

**Only the daemon-to-app side of a socket is a queue.** The handler reads each
app event as it arrives, so an app event, the handler's handling of it and the
Endpoint call it makes are one step. Nothing distinct is lost this way:
- An app event lost in a drop looks to the app exactly like one whose answer
  was lost, because the app acts only on answers. The Endpoint's effects of an
  event that did arrive are the harder case, and the model keeps them.
- An event delivered late is the same as one sent late, and users may cancel,
  answer or resend at any moment here.

Server events travel on one FIFO per connection, and a drop loses what is on
it.

**The design the spec encodes.**
- The Endpoint writes the user row when it accepts a `msg`.
- It writes the assistant row, and sends `text_done{server_seq}`, when the
  Queue reports `{:completed}`, not from the turn's reply callback.
- `turn_error{cancelled}` comes only from the Queue's `{:cancelled}`. It is
  live-only and never becomes a row.
- Every row the Endpoint writes is appended (one Repo call) and fanned out in
  the same callback.
- The job's row is written by the job and fanned out when its notice reaches
  the Endpoint.
- A pending approval is re-sent at `server_hello`, and its resolution is fanned
  out so other apps clear it.

**Environment switches** (set per check):
- `ClientsCanDisconnect`: a connection drops (the Mac sleeps, the network goes,
  the app is killed). Whatever is on its way to the app is lost. `MaxDrops`
  bounds the drops.
- `MessagesCanBeResent`: an app resends a message it has no `accepted` for
  yet, at any moment on a live connection (its ack timeout, or the user's
  retry), at most once per message.
- `TurnsCanBeCancelled`: a user sends `cancel{turn_id}` for any turn of the
  shared conversation, whichever app started it, whatever state it is in.
  `MaxCancels` bounds the cancels.
- `DeliveriesWhileOffline`: a scheduled job reports back once, at any moment,
  including while no app is connected.

**Mechanism switches** (`TRUE` is the design; each is switched off only by the
checks that show a rule needs it):
- `OutboxResend`: the app keeps every typed message in its outbox until
  accepted, and sends it again on every new connection.
- `AcceptedDedupe`: the Endpoint keeps a durable record of accepted
  `client_msg_id`s and answers a known one `accepted{duplicate: true}`, with no
  second row and no second turn.
- `SeqCursor`: the app pulls `history_pull{after_seq: cursor}` after
  `server_hello`, again while a page says more, and on a gap. It shows only
  the row after its cursor and drops any at or below it.
- `SubscribeBeforePull`: the handler subscribes its connection to the fan-out
  at `client_hello`, before it writes `server_hello`, so before any pull.
- `SingleAnswer`: the Endpoint applies the first answer to a pending approval
  and drops every later one.
- `OneTurnAtATime`: the Queue starts a turn only when none of the
  conversation's turns is alive (`maybe_start_next_request`).
- `CancelNamesTurn`: `cancel{turn_id}` stops that turn only, through a
  per-turn stop the Queue does not have yet. `FALSE` is
  `Queue.stop_conversation`, the only stop the Queue offers today
  (COMPANION-1).
- `OutcomeEndsTurn`: the Endpoint ends a turn on the wire only from the
  Queue's outcome; a cancel request writes nothing itself.
- `SeqAssignedOnInsert`: the Timeline assigns `server_seq` inside the one Repo
  call that inserts the row. `FALSE`: a writer reads the highest seq and
  inserts in a second call.

**Bounds** (set per check): `Clients` (the apps), `Senders` (the apps whose
users type), `MsgsPerSender`, `PageLimit` (`history_pull`'s limit),
`Approvals` (0 or 1), `MaxDrops`, `MaxCancels`. Each check uses only the
entities its rules need: two apps always, one message from one app or one from
each, one approval, and at most one drop, one cancel and one delivery. Two
messages and a delivery in one check (five rows) take the state space past a
million; every check here runs in under a minute. Invariant checks in which
both apps type reduce by the apps' symmetry.

## What holds

**Check 01** holds with one app typing, a drop, resends, and a job reporting
back at any moment:
- Every app shows a gapless, duplicate-free prefix of the timeline at all
  times, and all of it once it has caught up (`TimelineConverges`). This rests
  on `SeqCursor` (check 02) and `SubscribeBeforePull` (check 03).
- Every row's seq is higher than the one before (`SeqStrictlyIncreasing`).
  This rests on `SeqAssignedOnInsert` (check 04).

Witnesses 18 and 19 show why the app needs both halves of its cursor rule.
Live rows reach an app out of seq order: the job's row is fanned out after a
row the Endpoint wrote later. And a page and a live row can carry the same row.

**Check 05** holds with a drop and resends, both apps typing:
- No message is handed to the Queue twice (`RunAtMostOnce`). This rests on
  `AcceptedDedupe` (check 06).
- The conversation never runs two turns at once (`OneTurnOnTheWire`). This
  rests on `OneTurnAtATime` (check 07).

Witness 08 shows a resend reaching the Endpoint while its own turn is running.

**Check 09** holds with a cancel for any turn at any moment, an approval, and
both apps typing:
- No `text_done` follows a `turn_error{cancelled}` for the same turn
  (`NoDoneAfterCancel`). This rests on `OutcomeEndsTurn` (check 10).
- A cancel ends only the turn it names (`CancelEndsOnlyNamedTurn`, a proposed
  rule). This rests on `CancelNamesTurn` (check 11), a Queue stop that does not
  exist yet: COMPANION-1.

**Check 12** holds with both apps shown the approval, a drop that can lose it
(`server_hello` re-sends it) and a cancel that can withdraw it: at most one
answer, or the approval's timeout, is applied (`ApprovalAnsweredOnce`). This
rests on `SingleAnswer` (check 13). Witness 14 shows both apps answering the
one approval: one answer resolves it, and the other app, still showing it,
answers too.

**Check 15** (liveness) holds with a drop that can lose any answer, and a job
reporting back while no app is connected. Fairness applies only to steps
Fermix drives: the apps' reconnect loop and their reading of the socket and
the outbox, the handlers, the Endpoint, a running turn, and the approval's
timer.
- Every typed message is acknowledged to the app that sent it
  (`AckAtLeastOnce`). This rests on `OutboxResend` (check 16).
- Every app shows the delivery (`OfflineDeliveryArrives`). This rests on
  `SeqCursor` (check 17).

Each `needs` check breaks its rule by the path below (states in TLC's
counterexample):

| Check | Switched off | Counterexample |
|---|---|---|
| 02 | `SeqCursor` | 5 states: the job writes row 1 while no app is connected; the Mac connects and never pulls it |
| 03 | `SubscribeBeforePull` | 7 states: the Mac's pull is answered before its handler joins the fan-out, and its own message's row is fanned out in between |
| 04 | `SeqAssignedOnInsert` | 6 states: the job reads the highest seq (0), the Endpoint writes row 1 for a message, and the job inserts a second row 1 |
| 06 | `AcceptedDedupe` | 5 states: a resend on the same connection, before its `accepted` is read, writes a second row and hands a second turn to the Queue |
| 07 | `OneTurnAtATime` | 7 states: the iPhone's message starts while the Mac's turn runs |
| 10 | `OutcomeEndsTurn` | 8 states: see COMPANION-3 |
| 11 | `CancelNamesTurn` | 9 states: see COMPANION-1 |
| 13 | `SingleAnswer` | 10 states: the iPhone connects while the approval is pending and is shown it; the approval times out, then the iPhone answers, and that answer is applied too |
| 16 | `OutboxResend` | a lasso: the drop loses the `accepted`, and the app never sends the message again |
| 17 | `SeqCursor` | a lasso: the delivery lands while the Mac is offline; the Mac reconnects, shows the rows written after it, and never pulls it |

A run of every check takes one to two and a half minutes with the runner's
one worker, depending on the machine's load. The largest are check 15 (42,202
states and its liveness graph, 25 to 30 s), check 05 (386,298 states, about
12 s) and checks 01 and 09 (146,860 and 135,187 states, under 10 s each).
Every other check takes a few seconds.

Each `holds` check was also run once by hand, with four workers, with one
more of an entity its rules are about. No run found a violation. Three of them
stopped at their time cap before TLC had explored every state, so they show only
that no violation lies among the states explored:

| Check | One more | Result |
|---|---|---|
| 01 | drop (2) | holds, 407,144 states |
| 01 | message (two from one app) | no violation in 4,816,849 states; stopped at 2 min |
| 05 | drop (2) | holds, 1,593,561 states |
| 09 | cancel (2) | holds, 322,197 states |
| 09 | app and message (3 of each) | no violation in 5,005,561 states; stopped at 5 min |
| 12 | app (3, two racing the answer) | holds, 2,452,964 states |
| 12 | drop (2) | holds, 191,846 states |
| 15 | drop (2) | holds, 133,562 states |
| 15 | message (two from one app) | no violation in 213,043 states; stopped at 2 min |

## Not modelled

- `text_delta`, `tool_event`, `turn_started` and `read_state`: they are
  live-only, never in the timeline, and no rule reads them.
- `history_search`, and scroll-back through `history_pull{before_seq}`: reads
  below the cursor that never move it. The model's apps start with an empty
  cursor and page forward from the first row. A fresh app that starts from the
  newest page instead, taking that page's highest seq as its cursor, is not
  modelled.
- `turn_error`'s code and sentence, and turns that fail: `{:failed}` ends a
  turn through the same outcome path as `{:cancelled}`.
- The LLM and tools, the ConversationStore, authentication and the socket's
  0600 mode: single-call rules that ExUnit covers.
- A daemon restart, a Queue crash, and a turn task crash. `turn_queue` covers
  what they do to a turn's outcome (QUEUE-8, QUEUE-9); see the design notes
  below for what that means on this wire.
- Other conversations: the Queue keys all state by conversation.

## Findings

The code does not exist yet, so nothing here was walked through an
implementation. Each entry is something the model shows the implementation
must do, with the counterexample the matching `needs` check prints. Open
`tla/out/companion_session/<check>.txt` after a run to see the full path.

### COMPANION-1: `cancel{turn_id}` cannot be built on `Queue.stop_conversation`
- **Severity:** medium. One app's cancel stops the other app's turn, which
  nobody cancelled.
- **Status:** open. The Queue needs a per-turn stop before `cancel` ships.
- **Checks:** 09 holds with a per-turn stop (`CancelNamesTurn`). Check 11
  (9 states) breaks `CancelEndsOnlyNamedTurn` with `stop_conversation`.
- **Counterexample (check 11):**
  1. The Mac's message is accepted and its turn starts.
  2. The iPhone's message is accepted and waits behind it.
  3. The iPhone cancels its own waiting message.
  4. `stop_conversation` kills the Mac's running turn, which has not claimed
     its outcome, and cancels the iPhone's message. The Mac gets
     `turn_error{cancelled}` for a turn nobody cancelled.
- **A second route**, confirmed by hand on a variant of the model with the
  cancel restricted to it (12 states):
  1. The iPhone's turn finishes. Its `{:completed}` still waits in the
     Endpoint's mailbox.
  2. The Mac's waiting turn starts.
  3. The iPhone cancels its finished turn. The Endpoint still takes that turn
     for unfinished and calls `stop_conversation`, which kills the Mac's turn.

  No guard in the Endpoint closes this. Its view of which turn runs always
  lags the Queue's, because the Queue reports through the Endpoint's mailbox.
- **Code:** `stop_conversation/2` takes only a conversation key
  (`queue.ex:146`). `stop_conversation_runtime` calls `stop_active_turn`,
  which kills whichever active turn has not claimed its outcome, and
  `cancel_pending`, which cancels every waiting message (`queue.ex:959-995`).
  That is right for ACP's `session/cancel`, which cancels a session, and wrong
  for a wire where two apps share one conversation.
- **Requirement:** a Queue stop that names the turn, for example
  `Queue.stop_turn(conversation_key, turn_id)`, with the turn's identity
  handed in with the message. In one Queue callback it:
  - kills the active turn only if it is the named one and has not claimed its
    outcome;
  - or drops the named message alone if it is waiting;
  - fires `{:cancelled}` for that turn only, and starts the next waiting turn.

  `turn_queue` pins `queue.ex` whole, so that change marks it STALE. It must
  then model the new stop, with a `needs` check of its own.

### COMPANION-2: a connection must join the fan-out before its history is read
- **Severity:** medium if built the other way. A row can be missing from an
  app with nothing to show it, until a later row reveals the gap. The last row
  of a burst, typically the assistant's reply, can stay missing for good.
- **Status:** design requirement; holds in the design.
- **Checks:** 01 holds; check 03 (7 states) breaks `TimelineConverges` with
  the subscription after the first page.
- **Counterexample (check 03):**
  1. The Mac connects.
  2. Its pull after `server_hello` is answered, with an empty page.
  3. The Mac's user sends a message. The Endpoint writes its row and fans it
     out before the handler has joined the fan-out.
  4. The handler joins. The Mac has caught up and never shows its own message.
- **Requirement:** the handler subscribes at `client_hello`, before it writes
  `server_hello`. A page and a live row may then carry the same row (witness
  19), which the cursor drops.

### COMPANION-3: a cancel must not end the turn on the wire
- **Severity:** medium if built the other way. The app shows a cancelled turn,
  then its answer.
- **Status:** design requirement; holds in the design.
- **Checks:** 09 holds; check 10 (8 states) breaks `NoDoneAfterCancel` when
  the Endpoint answers a cancel with `turn_error{cancelled}` itself.
- **Counterexample (check 10):**
  1. The Mac's turn runs, claims its outcome and invokes `{:completed}`, which
     now waits in the Endpoint's mailbox.
  2. The Mac cancels the turn. The Endpoint still takes it for unfinished and
     writes `turn_error{cancelled}`.
  3. The Endpoint reads `{:completed}`, writes the assistant row, and sends
     `text_done` after the error.

  A turn that claimed its outcome before the cancel reaches the Queue takes
  the same path: the stop spares it (`stop_active_turn`), and it completes.
- **Requirement:** the Endpoint forwards the cancel to the Queue and writes
  nothing. The turn's ending on the wire is whichever outcome the Queue fires:
  `{:completed}` gives `text_done`, and `{:cancelled}` gives `turn_error`. The
  Queue fires one outcome per turn (`turn_queue`'s `AtMostOneOutcome`), so the
  wire carries one ending. A cancel that loses the race to the claim gets the
  answer, not an error.

### COMPANION-4: an app must drop rows at or below its cursor, and pull on a gap
- **Severity:** medium if built the other way: rows shown twice, out of order,
  or never.
- **Status:** design requirement; holds in the design.
- **Checks:** 01 and 15 hold. Check 02 (5 states) breaks `TimelineConverges`
  and check 17 breaks `OfflineDeliveryArrives` when the app renders only live
  rows. Witnesses 18 (6 states) and 19 (5 states) show the two other ways live
  rows mislead an app.
- **Counterexamples:**
  - Check 02: the job writes a row while no app is connected. The Mac connects
    and, with no pull after its cursor, never shows it.
  - Witness 18: row 2, the Endpoint's, is on the Mac's socket ahead of row 1,
    the job's. The job wrote first, but its notice reached the Endpoint after
    the Endpoint had written and fanned out row 2.
  - Witness 19: the job's row is written, the Mac's pull returns it, and the
    Endpoint then fans it out live as well.
- **Requirement:**
  - Pull `after_seq: cursor` after every `server_hello`, and keep pulling
    while a page says there is more.
  - Show a live row only if it is the one after the cursor. Drop one at or
    below the cursor.
  - On a gap, drop the row and pull, unless a pull is already out.
  - Do not key the cursor on arrival order.

### COMPANION-5: `server_seq` must be assigned in the insert
- **Severity:** high if built the other way: two rows with one seq, and the
  cursor then hides one of them from every app.
- **Status:** design requirement; holds in the design.
- **Checks:** 01 holds; check 04 (6 states) breaks `SeqStrictlyIncreasing`.
- **Counterexample (check 04):**
  1. The job reads the highest seq, 0.
  2. The Endpoint writes row 1 for the Mac's message.
  3. The job inserts its row with seq 1 as well.
- **Requirement:** assign the seq inside the one `Memory.Repo` call that
  inserts the row, whoever writes it: an `INTEGER PRIMARY KEY AUTOINCREMENT`,
  since a plain rowid can be reused once the highest row is deleted. The
  Endpoint and the job both write, from different processes, and
  `Memory.Repo` serializes calls, not callers.

### Design notes the checks do not cover
- **Where `text_done` comes from.** The spec writes the assistant row and
  `text_done` on `{:completed}`, not from the turn's reply callback. The
  reply callback runs before the commit and the claim, and a stop in that
  window kills the turn. That is `turn_queue`'s QUEUE-2 and QUEUE-3, accepted
  there. Written from the reply callback, the timeline would keep an answer
  that the model's history marks as stopped, and the apps would get
  `text_done` and then `turn_error{cancelled}` for one turn.
- **A turn whose outcome is lost never ends on the wire.** A Queue restart
  (QUEUE-8) or a linked helper's exit between the claim and the invocation
  (QUEUE-9) leaves a turn with no outcome. The apps then show it running
  forever. The Endpoint should watch the Queue process it handed each turn to
  and end the turn with `turn_error` on that process's `:DOWN`, as `Acp.Peer`
  does (`turn_queue`'s `ConsumerFencesQueue`).
- **`turn_error` is live-only.** An app offline when a turn is cancelled or
  fails sees, after it reconnects, a user row with no answer. If it must show
  why, the ending has to be a timeline row, and the rules above then cover it.
- **The dedupe record and the user row belong in one insert.** A daemon
  restart is not modelled. If the record of an accepted `client_msg_id` and
  the user row are written by separate Repo calls, a restart between them
  either runs a resent message twice or loses its row. Make the id a unique
  column of the row.
