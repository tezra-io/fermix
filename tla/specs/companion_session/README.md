# companion_session: the companion chat socket, one shared conversation

Models the companion chat socket (`companion.sock`) for one conversation that
two clients share:
- each client's `Companion.Connection`, connecting and dropping at any time;
- the request path both transports share (`Companion.Requests`): the durable
  claim, `accepted`, the request coordinator's attempt fence, the user's row,
  and the hand-off to the Gateway;
- `Companion.Turns`, which ends every turn on the wire from the Queue's outcome;
- the Gateway Queue;
- the timeline (`FermixCore.Companion.Timeline`, written through
  `Memory.Repo`);
- a scheduled job reporting back through `Channels.Companion.send_message`;
- one approval, answered by a `/confirm` or `/deny` command.

The clients follow the rules `FermixCore.Companion.Protocol` exports in
`apps/fermix_core/priv/companion/PROTOCOL.md` ("Keeping a client's timeline",
"Delivery and the outbox"): an outbox resent on every connection, and a seq
cursor. `PROTOCOL.md` is pinned whole, so a change to those rules marks the spec
STALE.

The spec was first written as a design spec, ahead of the code (a075b8c9). It
was then re-read against the implementation and pinned. COMPANION-1 to
COMPANION-5 are what the design spec asked of the implementation, with their
status now. COMPANION-6 and COMPANION-7 are new, found in the re-read.

**The Queue is one abstract process.** The runner takes one `.tla` per spec,
and `turn_queue` proves the Queue's rules against `queue.ex`, so this spec takes
them as given:
- one turn at a time per conversation (`maybe_start_next_request`;
  `turn_queue`'s `SingleFlight`, which rests on `StartsWhenIdle`);
- one outcome per turn, through the claim (`claim_active_turn`;
  `AtMostOneOutcome`);
- a named stop (`stop_turn`) that ends the named message's turn only, and spares
  it once it has claimed its outcome. This is `turn_queue`'s
  `OnlyNamedTurnCancelled`, which rests on `StopTurnNamesTurn` (its checks 18,
  18b, 19 and 19b). This spec uses the same switch and rule names for the same
  claim, observed on the wire.

As in `queue.ex`, a turn starts in the callback that enqueues it or that clears
the previous turn. It then claims its outcome (after the commit) and invokes it.

**Only the daemon-to-client side of a socket is a queue**: the Connection's
mailbox, then the socket, in order. Every event a Connection writes except
`server_hello` reaches it as `{:companion_event, _}` (`connection.ex:124`). A
client event, the Connection's handling of it, and the request worker, Repo and
Queue calls it makes are one step. Nothing distinct is lost this way:
- A client event lost in a drop looks to the client exactly like one whose
  answer was lost, because the client acts only on answers.
- An event delivered late is the same as one sent late, and users here cancel,
  answer or resend at any moment.

The one gap inside such a step that matters is modelled: a history page is read
(one Repo call) and then sent to the Connection's own mailbox
(`LiveRowsOvertakePage`, COMPANION-6).

**What the code does, as modelled:**
- A `msg` is claimed under its `client_msg_id` and answered `accepted` before
  anything runs (`claim_and_run`, `requests.ex:172-191`). The coordinator then
  starts one attempt (`acquire_and_run`, `:193-209`). The attempt writes the
  user's row, which is **not broadcast**: other clients see it through history.
- `Turns` holds a turn's reply until the Queue's outcome (`turns.ex`):
  - `{:completed}` writes the reply row and broadcasts `text_done{server_seq}`;
  - `{:cancelled}` broadcasts one `turn_error`, which is live-only.
- `cancel{client_msg_id}` makes the Connection call `Queue.stop_turn`, and it
  writes nothing itself (`connection.ex:238-246`).
- Every writer gets `server_seq` from the per-profile counter inside the
  insert's transaction (`append_in_tx`, `mobile_sql.ex:490-496`).
- A Connection joins the registry before it writes `server_hello`
  (`connection.ex:212-221`).
- A job's row is written and then broadcast by the job's own process
  (`send_message`, `channels/companion.ex:174-206`).
- An approval is a single-use token. The first `/confirm` or `/deny` that
  `take`s it applies the answer and broadcasts `approval_resolved`
  (`sandbox.ex:223-266`, `:397-414`; `confirmations.ex:21-26`). The turn does
  not wait on it, and a pending approval is not re-sent at `server_hello`.

**Environment switches** (set per check):
- `ClientsCanDisconnect`: a connection drops. What is in the Connection's
  mailbox or on the socket is lost, and so is a page it read and had not sent.
  A request worker runs on, since it is not linked. The client keeps its
  outbox, its view, and any approval card it shows. `MaxDrops` bounds the
  drops.
- `MessagesCanBeResent`: a client resends a message it has no `accepted` for
  yet, at any moment on a live connection, at most once per message.
- `TurnsCanBeCancelled`: a user sends `cancel{client_msg_id}` for any message of
  the shared conversation, whatever state its turn is in. `MaxCancels` bounds
  the cancels.
- `DeliveriesWhileOffline`: a scheduled job reports back once, at any moment,
  including while no client is connected.

**Mechanism switches** (`TRUE` is the real code; each is switched off only by
the checks that show a rule needs it):
- `OutboxResend`: the client keeps every typed message until accepted, and
  sends it again on every new connection (`PROTOCOL.md`).
- `AcceptedDedupe`: a known `client_msg_id` is claimed as a duplicate
  (`claim_request_in_tx`, `classify_claim`, `mobile_sql.ex:722-741`). The
  coordinator starts no second attempt of a request running, completed or
  failed (`request_coordinator.ex:118-125`).
- `SeqCursor`: the client's cursor rules (`PROTOCOL.md`).
- `SubscribeBeforePull`: the Connection joins the registry before
  `server_hello` (`connection.ex:212-221`).
- `SingleAnswer`: `Confirmations.take` is an `:ets.take`, the sole consumer of
  a token (`confirmations.ex:21-31`).
- `OneTurnAtATime`: `maybe_start_next_request` (`queue.ex:304-312`).
- `StopTurnNamesTurn`: `cancel` stops the named message's turn only
  (`Queue.stop_turn`, `stop_named_in`, `queue.ex:172`, `:1005-1042`). `FALSE`
  is the conversation stop (`stop_conversation_runtime`, `:990-994`).
- `OutcomeEndsTurn`: a turn ends on the wire only from the Queue's outcome, in
  `Turns`; the Connection's cancel writes nothing.
- `SeqAssignedOnInsert`: the seq comes from the counter inside the inserting
  transaction. `FALSE`: a writer reads the counter, then inserts in a second
  call.

**Timing:** `LiveRowsOvertakePage`. `TRUE` is the real code: a live row can
reach a Connection's mailbox between its history read and the page it sends to
that mailbox. `FALSE` forbids that. A check that sets it `FALSE` proves a
property only for a Connection that writes the page in the step it reads it.

**Bounds** (set per check): `Clients` (always two), `Senders` (the clients
whose users type), `MsgsPerSender`, `PageLimit` (2), `Approvals` (0 or 1),
`MaxDrops`, `MaxCancels`. Each check uses only the entities its rules need.
Invariant checks in which both clients type reduce by their symmetry.

## What holds

**Check 01** (timing idealised) holds with one client typing, a drop, resends,
and a job reporting back at any moment:
- Every client shows a gapless, duplicate-free prefix of the timeline at all
  times, and all of it once it and the conversation are at rest
  (`TimelineConverges`). This rests on `SeqCursor` (check 02) and
  `SubscribeBeforePull` (check 03).
- Every row's seq is higher than the one before (`SeqStrictlyIncreasing`).
  This rests on `SeqAssignedOnInsert` (check 04).

With the real timing, `TimelineConverges` breaks: COMPANION-6 (check 20).
Witnesses 18 and 19 show why the cursor rule has two halves: live rows arrive
out of seq order, and a page and a live row can carry the same row.

**Check 05** (timing idealised; its rules do not read it, and it keeps the
check small) holds with a drop and resends, both clients typing:
- No message is handed to the Queue twice (`RunAtMostOnce`). This rests on
  `AcceptedDedupe` (check 06).
- The conversation never runs two turns at once (`OneTurnOnTheWire`). This
  rests on `OneTurnAtATime` (check 07).

Witness 08 shows a resend claimed while its message's turn is running.

**Check 09** holds with a cancel for any message at any moment, both clients
typing:
- No `text_done` follows a `turn_error{cancelled}` for the same turn
  (`NoDoneAfterCancel`). This rests on `OutcomeEndsTurn` (check 10).
- A cancel ends only the turn it names (`OnlyNamedTurnCancelled`). This rests
  on `StopTurnNamesTurn` (check 11), as it does in `turn_queue`.

**Check 12** holds with both clients shown the approval, a drop, and a cancel:
at most one answer to it is ever applied (`ApprovalAnsweredOnce`). This rests
on `SingleAnswer` (check 13). Witness 14 shows both clients answering: one take
resolves the approval, and the other client, still showing the card, answers
too and is refused.

**Check 15** (liveness, timing idealised) holds with a drop that can lose any
answer, and a job reporting back while no client is connected. Fairness is on
the steps Fermix drives only: the clients' reconnect loop, their reading and
their outbox, the Connections, `Turns`, a running turn, and the job's
announcement.
- Every typed message is acknowledged to the client that sent it
  (`AckAtLeastOnce`). This rests on `OutboxResend` (check 16).
- Every client shows the delivery (`OfflineDeliveryArrives`). This rests on
  `SeqCursor` (check 17). With the real timing a delivery can be lost the way
  COMPANION-6 loses a reply.

Each `needs` check breaks its rule by this path (states in TLC's
counterexample):

| Check | Switched off | Counterexample |
|---|---|---|
| 02 | `SeqCursor` | 5 states: the job writes row 1 while no client is connected and announces it; the client connects and never pulls it |
| 03 | `SubscribeBeforePull` | 7 states: the client's page is read before its Connection joins the registry, and a row is broadcast in between |
| 04 | `SeqAssignedOnInsert` | 6 states: the job reads the counter (0), the client's message writes row 1, and the job inserts a second row 1 |
| 06 | `AcceptedDedupe` | 5 states: a resend on the same connection, before its `accepted` is read, hands a second turn to the Queue |
| 07 | `OneTurnAtATime` | 7 states: the second client's message starts while the first client's turn runs |
| 10 | `OutcomeEndsTurn` | 8 states: see COMPANION-3 |
| 11 | `StopTurnNamesTurn` | 7 states: the second client's turn runs; the first client's user cancels its own message, not yet sent; the conversation stop kills the running turn |
| 13 | `SingleAnswer` | 12 states: one client's answer takes the token; the other client, still showing the card, answers too and is applied as well |
| 16 | `OutboxResend` | a lasso: a drop loses the `accepted`, and the client never sends the message again |
| 17 | `SeqCursor` | a lasso: the delivery lands while a client is offline, and it never pulls it |

The whole spec runs in under a minute with the runner's one worker (40 to 56 s
on a loaded laptop). The largest checks are 15 (28,363 states and its liveness
graph, 9 to 13 s), 12 (278,978 states, 6 to 10 s), 05 (269,761 states, 6 to
9 s), 09 (61,408 states, 3 s) and 01 (99,229 states, 3 s). Every other check
takes about a second.

Each `holds` check was also run once by hand, with four workers, with one
more of an entity its rules are about. All still hold:

| Check | One more | States |
|---|---|---|
| 01 | drop (2) | 314,402 |
| 05 | drop (2) | 1,153,171 |
| 09 | cancel (2) | 130,172 |
| 12 | drop (2) | 1,136,097 |
| 15 | drop (2) | 101,880 |

## Not modelled

- `text_delta`, `tool_event`, `turn_started` and `read_state`: live-only, never
  in the timeline, and no rule reads them.
- `history_search`, and scroll-back through `history_pull{before_seq}`: reads
  below the cursor that never move it.
- The phone. Mobile and companion share the timeline but run under different
  channel identities, so live events never cross from one socket to the other.
  This spec is two clients on `companion.sock`.
- A failed turn: `{:failed}` ends a turn through the same path as
  `{:cancelled}`.
- A daemon restart and boot recovery, a Queue crash, and a crash of `Turns` or
  of a request worker. On a Queue crash, `Turns` ends its turns as
  `interrupted` (`turns.ex:115-123`).
- The grant resume a confirmed approval re-ingests as a new turn
  (`sandbox.ex` `resume_request`).
- The LLM and tools, the ConversationStore, attachments, authentication and
  the socket's 0600 mode: single-call rules that ExUnit covers.
- Other conversations: the Queue keys all state by conversation.

## Findings

Each finding was walked through the code on `feat/companion-chat-wire`
(a7e3b6ef). None was reproduced on a running daemon or in ExUnit. To see a
counterexample, run `make -C tla check SPECS=companion_session` and open
`tla/out/companion_session/<check>.txt`.

### COMPANION-1: `cancel` could not be built on `Queue.stop_conversation`
- **Severity:** medium. One client's cancel stopped the other client's turn.
- **Status:** fixed (5ab65479, db056576). `Queue.stop_turn/3` stops one message
  by its id, and `cancel` names the `client_msg_id` because a waiting message
  has no turn id yet. `turn_queue` models the stop (checks 18 to 19b).
- **Checks:** 09 holds; 11 breaks `OnlyNamedTurnCancelled` with the
  conversation stop.
- **Counterexample (check 11):** the other client's turn runs, and a client's
  message waits behind it. The client cancels its own waiting message, and the
  conversation stop kills the running turn too. A second route, confirmed on a
  variant of the design model: a cancel for a turn that had finished, with its
  outcome still unread, killed the turn that started next.

### COMPANION-2: a connection must join the fan-out before its history is read
- **Status:** holds in the code (ed33c3af). `join` registers the Connection
  before it writes `server_hello` (`connection.ex:212-221`).
- **Checks:** 01 holds; check 03 breaks `TimelineConverges` with the join after
  the first page. A row written in between never reaches the client.

### COMPANION-3: a cancel must not end the turn on the wire
- **Status:** fixed (db056576). `Companion.Turns` ends every turn from the
  Queue's outcome and only from it. It holds a turn's replies until
  `{:completed}`, which writes the rows and sends `text_done`. `{:cancelled}`
  and `{:failed, _}` send one `turn_error`, and a dead Queue ends the turn as
  `interrupted`. The Connection's cancel writes nothing.
- **Checks:** 09 holds; check 10 breaks `NoDoneAfterCancel` when the cancel is
  answered with `turn_error` at once: a turn that had finished, with its
  `{:completed}` still unread, then sends `text_done`.

### COMPANION-4: a client must drop rows at or below its cursor, and pull on a gap
- **Status:** documented. `PROTOCOL.md` ("Keeping a client's timeline", db056576)
  gives clients exactly this rule, and the spec models clients that follow it.
  The clients live outside this repository. COMPANION-6 shows the rule is not
  enough against the server's page ordering.
- **Checks:** 01 and 15 hold; 02 and 17 break without the cursor. Witnesses 18
  and 19 show rows out of order and a page overlapping a live row.

### COMPANION-5: `server_seq` must be assigned in the insert
- **Status:** holds in the code. Every writer (`append_in_tx`) reads and bumps
  the per-profile counter inside one transactional Repo call, the bump guarded
  by the value it read (`mobile_sql.ex:490-548`).
- **Checks:** 01 holds; check 04 breaks `SeqStrictlyIncreasing` when a writer
  reads the counter and inserts in a second call.

### COMPANION-6: a live reply that overtakes a history page is lost
- **Severity:** medium. The window is short, but the reply a user waits for can
  stay unshown for as long as the conversation stays quiet.
- **Status:** open. Recommended fix below.
- **Check:** 20 (`TimelineConverges`, real timing, 11 states).
- **Counterexample (check 20):**
  1. A client connects and reads `server_hello`. Its pull after cursor 0 is
     read from the timeline: an empty page, not yet sent to the Connection's
     mailbox.
  2. The user's message is claimed and its row written (not broadcast). The
     turn runs, completes, and `Turns` writes the reply as row 2 and
     broadcasts its `text_done`. That event lands in the Connection's mailbox
     ahead of the page.
  3. The client reads `text_done` 2. Its cursor is 0 and its pull is still
     out, so by the rule it drops the row.
  4. The page arrives, empty. The client has caught up and shows neither row.
- **Code:**
  - `history_pull` runs `Requests.history` inside the Connection
    (`connection.ex:192-193`). It reads the page in one Repo call, then emits
    it through the event sink (`requests.ex:96-107`), which for this client is
    `send(self(), {:companion_event, page})` (`sink`, `connection.ex:425-428`).
  - A broadcast from another process lands in the same mailbox
    (`Channels.Companion.dispatch`, `channels/companion.ex:223-227`, from
    `write_reply`, `turns.ex:174-191`). One sent after the read but before the
    self-send is ahead of the page.
  - `PROTOCOL.md` tells the client to drop a gap row while a pull is out,
    expecting the page to cover it. A page read before the row was written
    cannot. `PROTOCOL.md` also claims no row "can fall between a page and the
    live events"; this one does.
- **Impact:** the client shows the reply's streamed draft but never its
  `text_done` row, until another row arrives or it reconnects. A job's delivery
  can be lost the same way.
- **Fix (recommended):** the Connection writes `history_page` to the socket in
  the callback that read it, as it writes `server_hello` (`send_event`,
  `connection.ex:375-379`), instead of through its own mailbox. Every live event
  the read missed is then behind the page. With that, check 20 is check 01's
  setup with the timing idealisation made real: set `LiveRowsOvertakePage` to
  `FALSE` there, flip check 20 to `holds`, and drop the switch. The client-side
  alternative (remember a dropped gap and pull again after the page) would
  need every client to change.

### COMPANION-7: a message whose turn writes no reply stays off every client's timeline
- **Severity:** low.
- **Status:** open. Owner question below.
- **Check:** 21 (`TimelineConverges` with a cancel, timing idealised so the path
  is this one, 8 states).
- **Counterexample (check 21):**
  1. A client sends a message. It is claimed, answered `accepted` (no
     `server_seq`: the request has no reply row), and its user row 1 is
     written, not broadcast.
  2. The client cancels it. The turn stops, and `Turns` broadcasts one
     `turn_error`.
  3. The conversation is at rest. No client, the sender included, shows row 1,
     and none will pull it until a later row reveals the gap.
- **Code:** `append_user` writes the row and broadcasts nothing
  (`requests.ex:331-342`). `accepted` carries `server_seq` only once the
  request has a reply row (`accepted_event`, `requests.ex:523-526`).
  `turn_error` carries no seq (`fail`, `turns.ex:164-168`). The client pulls
  only after `server_hello`, while a page says more, and on a gap
  (`PROTOCOL.md`).
- **Impact:** the other client never shows a cancelled or failed message until
  the conversation moves on or it reconnects. The sender knows the message
  only from its outbox and cannot place it by seq. `PROTOCOL.md` says a user's
  row reaches other connections only through history, but not that a
  connected client gets no signal to fetch it.
- **Owner question:** broadcast the user row when it is written, so every
  client places it by the cursor rule? The alternative is to put the user
  row's `server_seq` on `turn_started` and `turn_error`, so a client sees the
  gap and pulls. That misses a message cancelled while it waited, which never
  sent `turn_started`. Recommended: broadcast the row.

### Design notes
- **Where `text_done` comes from:** from `{:completed}` in `Turns` (db056576),
  so a stop between the reply callback and the claim (`turn_queue`'s QUEUE-2
  and QUEUE-3) no longer leaves the timeline holding an answer the history
  marks as stopped.
- **A turn whose outcome is lost:** `Turns` watches the Queue it handed each
  turn to and ends the turn as `interrupted` on that Queue's `:DOWN`
  (`turns.ex:115-123`). Not modelled.
- **`turn_error` is live-only**, as `PROTOCOL.md` says. COMPANION-7 is its
  consequence for a connected client.
- **The claim and the user row are two writes.** A daemon restart between them
  leaves a claim with no row; boot recovery re-runs the request under the
  attempt fence, and the row is written then. Not modelled.
- **Approvals:** a pending approval is not re-sent at `server_hello`, so a
  client that connects after the card was broadcast never sees it. A confirmed
  grant resumes its request as a new turn even if the turn that asked for it
  was cancelled: the token outlives the turn. Neither breaks a rule here.
