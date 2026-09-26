# companion_session: the companion chat socket, one shared conversation

Models the companion chat socket (`companion.sock`) for one conversation that
two clients share:
- each client's `Companion.Connection`, connecting and dropping at any time;
- the request path both transports share (`Companion.Requests`): the durable
  claim, `accepted`, the request coordinator's attempt fence, and the user's
  row, announced as it is written;
- `Companion.Turns`, one process with one mailbox. It hands every turn to the
  Queue, sends every stop of a turn it handed off, and ends every turn on the
  wire from the Queue's outcome;
- the Gateway Queue;
- the timeline (`FermixCore.Companion.Timeline`, written through
  `Memory.Repo`);
- a scheduled job reporting back through `Channels.Companion.send_message`;
- one approval, answered by a `/confirm` or `/deny` command.

The clients follow the rules `FermixCore.Companion.Protocol` exports in
`apps/fermix_core/priv/companion/PROTOCOL.md` ("Keeping a client's timeline",
"Delivery and the outbox"). Each keeps an outbox, resent on every connection,
and a seq cursor that applies a live row (a `row` or a `text_done`) at
cursor + 1. `PROTOCOL.md` is pinned whole, so a change to those rules marks the
spec STALE.

The spec was first written as a design spec, ahead of the code (70dc7e86). It
was then re-read against the implementation, and re-read again after its
fixes. COMPANION-1 to COMPANION-5 are what the design spec asked of the
implementation. COMPANION-6 and COMPANION-7 were found in the first re-read,
and COMPANION-8 in the implementation's own review. All eight are fixed or
hold in the code.

**The Queue is one abstract process.** The runner takes one `.tla` per spec,
and `turn_queue` proves the Queue's rules against `queue.ex`, so this spec takes
them as given:
- one turn at a time per conversation (`maybe_start_next_request`;
  `turn_queue`'s `SingleFlight`, which rests on `StartsWhenIdle`);
- one outcome per turn, through the claim (`claim_active_turn`;
  `AtMostOneOutcome`);
- a named stop (`stop_turn`) that ends the named message's turn only, and spares
  it once it has claimed its outcome. This is `turn_queue`'s
  `OnlyNamedTurnCancelled`, which rests on `StopTurnNamesTurn` (its checks 18
  to 19b). This spec uses the same switch and rule names for the same claim,
  observed on the wire.

As in `queue.ex`, a turn starts in the callback that enqueues it or that clears
the previous turn. It then claims its outcome (after the commit) and invokes it.

**Only the daemon-to-client side of a socket is a queue**: the Connection's
mailbox, then the socket, in order. A client event, the Connection's handling
of it, and the request worker, Repo and Queue calls it makes are one step, up
to the worker's call into `Turns`. Nothing distinct is lost this way:
- A client event lost in a drop looks to the client exactly like one whose
  answer was lost, because the client acts only on answers.
- An event delivered late is the same as one sent late, and users here cancel,
  answer or resend at any moment.

`Turns` is a separate process: hand-offs, cancels and the Queue's outcomes
queue in its mailbox and are handled in order.

**What the code does, as modelled:**
- A `msg` is claimed under its `client_msg_id` and answered `accepted` before
  anything runs (`claim_and_run`). The coordinator starts one attempt
  (`acquire_and_run`). The attempt writes the user's row and announces it to
  every connection as a `row` (`announce_user_row`). It then calls
  `Turns.handle_message`.
- `Turns` hands the turn off in one step of its process (`hand_off`): it reads
  the request's cancel mark and either ends a marked request with one
  `turn_error` or enqueues it. A `cancel` marks the request first
  (`cancel_request`, one Repo call), then asks `Turns`, which sends
  `Queue.stop_turn` for a turn it handed off, after that turn's enqueue.
- `Turns` holds a turn's reply until the Queue's outcome:
  - `{:completed}` writes the reply row and broadcasts `text_done{server_seq}`;
  - `{:cancelled}` broadcasts one `turn_error`, which is live-only.
- Every writer gets `server_seq` from the per-profile counter inside the
  insert's transaction (`append_in_tx`).
- A Connection joins the registry before it writes `server_hello`. It writes
  every `history_page` to the socket in the step that read it (`read_opts`).
- A job's row is written, then announced as a `row` by the job's own process
  (`send_message` -> `announce_written`).
- An approval is a single-use token. The first `/confirm` or `/deny` that
  `take`s it applies the answer and broadcasts `approval_resolved`. The turn
  does not wait on it, and a pending approval is not re-sent at
  `server_hello`.

**Environment switches** (set per check):
- `ClientsCanDisconnect`: a connection drops, and what is in its mailbox or on
  the socket is lost. A request worker runs on, since it is not linked. The
  client keeps its outbox, its view, and any approval card it shows.
  `MaxDrops` bounds the drops.
- `MessagesCanBeResent`: a client resends a message it has no `accepted` for
  yet, at any moment on a live connection, at most once per message.
- `TurnsCanBeCancelled`: a user sends `cancel{client_msg_id}` for any message of
  the shared conversation, whatever state its request is in. `MaxCancels`
  bounds the cancels.
- `DeliveriesWhileOffline`: a scheduled job reports back once, at any moment,
  including while no client is connected.

**Mechanism switches** (`TRUE` is the real code; each is switched off only by
the checks that show a rule needs it):
- `OutboxResend`: the client's outbox, resent on every new connection
  (`PROTOCOL.md`).
- `AcceptedDedupe`: a known `client_msg_id` is claimed as a duplicate
  (`claim_request_in_tx`, `classify_claim`). The coordinator starts no second
  attempt of a request running, completed or failed
  (`request_coordinator.ex:118-125`).
- `SeqCursor`: the client's cursor rules (`PROTOCOL.md`).
- `SubscribeBeforePull`: the Connection joins the registry before
  `server_hello` (`join`, `connection.ex:211-220`).
- `PageWrittenInReadStep`: the Connection writes `history_page` to the socket
  in the step that read it (`read_opts`, `connection.ex:446-450`). `FALSE`
  sends it through its own mailbox, where a live row sent after the read can
  overtake it.
- `AnnouncesEveryRow`: every row written outside a turn's completion is
  broadcast as a `row` as it is written: the user's row (`announce_user_row`,
  `connection.ex:434`) and a delivery (`announce_written`,
  `channels/companion.ex:236`). `FALSE` announces no user row.
- `SingleAnswer`: `Confirmations.take` is an `:ets.take`, the sole consumer of
  a token (`confirmations.ex:21-31`).
- `OneTurnAtATime`: `maybe_start_next_request` (`queue.ex:304-312`).
- `StopTurnNamesTurn`: a stop ends the named message's turn only
  (`Queue.stop_turn`, `stop_named_in`, `queue.ex:172`, `:1005-1042`). `FALSE`
  is the conversation stop.
- `CancelMarksRequest`: a cancel is recorded on its request first
  (`cancel_request`, `mobile_sql.ex:373-401`). `Turns` reads the mark and
  enqueues in one step (`hand_off`, `turns.ex:166-187`), and sends every stop
  of a turn it handed off itself, after the enqueue (`turns.ex:117-129`).
  `FALSE` is the code before 431d5663: the Connection called `Queue.stop_turn`
  directly.
- `OutcomeEndsTurn`: a turn ends on the wire only from the Queue's outcome, in
  `Turns`; the Connection's cancel writes nothing.
- `SeqAssignedOnInsert`: the seq comes from the counter inside the inserting
  transaction (`append_in_tx`, `mobile_sql.ex:538-544`). `FALSE`: a writer
  reads the counter, then inserts in a second call.

**Bounds** (set per check): `Clients` (always two), `Senders` (the clients
whose users type), `MsgsPerSender`, `PageLimit` (2), `Approvals` (0 or 1),
`MaxDrops`, `MaxCancels`. Each check uses only the entities its rules need.
Invariant checks in which both clients type reduce by their symmetry.

## What holds

**Check 01** holds with one client typing, a drop, resends, and a job reporting
back at any moment:
- Every client shows a gapless, duplicate-free prefix of the timeline at all
  times, and all of it once it and the conversation are at rest
  (`TimelineConverges`). This rests on:
  - `SeqCursor` (check 02);
  - `SubscribeBeforePull` (check 03);
  - `PageWrittenInReadStep` (check 20), COMPANION-6's fix.
- Every row's seq is higher than the one before (`SeqStrictlyIncreasing`).
  This rests on `SeqAssignedOnInsert` (check 04).

Witnesses 18 and 19 show why the cursor rule has two halves: live rows arrive
out of seq order, and a page and a live row can carry the same row.

**Check 05** holds with a drop and resends, both clients typing:
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
- A message whose cancel arrived after its claim and before its hand-off never
  runs and is never answered (`CancelledRequestNeverRuns`). This rests on
  `CancelMarksRequest` (check 24), COMPANION-8's fix. Witness 25 reaches that
  window.

**Check 21** holds in check 09's setup: every client shows the timeline, a
cancelled message's row included (`TimelineConverges`). This rests on
`AnnouncesEveryRow` (check 22), COMPANION-7's fix, and still on `SeqCursor`
(check 23).

**Check 12** holds with both clients shown the approval, a drop, and a cancel:
at most one answer to it is ever applied (`ApprovalAnsweredOnce`). This rests
on `SingleAnswer` (check 13). Witness 14 shows both clients answering: one
take resolves the approval, and the other client, still showing the card,
answers too and is refused.

**Check 15** (liveness) holds with a drop that can lose any answer, and a job
reporting back while no client is connected. Fairness is on the steps Fermix
drives only: the clients' reconnect loop, their reading and their outbox, the
Connections, `Turns`, a running turn, and the job's announcement.
- Every typed message is acknowledged to the client that sent it
  (`AckAtLeastOnce`). This rests on `OutboxResend` (check 16).
- Every client shows the delivery (`OfflineDeliveryArrives`). This rests on
  `SeqCursor` (check 17).

Each `needs` check breaks its rule by this path (states in TLC's
counterexample):

| Check | Switched off | Counterexample |
|---|---|---|
| 02 | `SeqCursor` | 5 states: the job writes and announces row 1 while no client is connected; the client connects and never pulls it |
| 03 | `SubscribeBeforePull` | 7 states: the client's page is read before its Connection joins the registry, and a row is announced in between |
| 04 | `SeqAssignedOnInsert` | 6 states: the job reads the counter (0), the client's message writes row 1, and the job inserts a second row 1 |
| 06 | `AcceptedDedupe` | 7 states: a resend, before its `accepted` is read, is handed to the Queue a second time |
| 07 | `OneTurnAtATime` | 9 states: the second client's message starts while the first client's turn runs |
| 10 | `OutcomeEndsTurn` | 9 states: the turn has finished, its `{:completed}` is still in `Turns`' mailbox, and a cancel answered at once is followed by `text_done` |
| 11 | `StopTurnNamesTurn` | 12 states: a cancelled request is ended at its hand-off; the cancel's stop, still in `Turns`' mailbox, then reaches the Queue as the conversation stop and kills the other client's turn |
| 13 | `SingleAnswer` | 15 states: one client's answer takes the token; the other, still showing the card, answers too and is applied as well |
| 16 | `OutboxResend` | a lasso: a drop loses the `accepted`, and the client never sends the message again |
| 17 | `SeqCursor` | a lasso: the delivery lands while a client is offline, and it never pulls it |
| 20 | `PageWrittenInReadStep` | 13 states: COMPANION-6's path |
| 22 | `AnnouncesEveryRow` | 9 states: COMPANION-7's path |
| 23 | `SeqCursor` | 9 states: a client that connects after a message's row was announced never pulls it |
| 24 | `CancelMarksRequest` | 6 states: COMPANION-8's path |

The whole spec runs in under a minute with the runner's one worker (55 s on a
loaded laptop). The largest checks are 15 (48,771 states and its liveness
graph, 15 s), 05 (417,556 states, 10 s), 01 (173,999 states, 4 s) and 12
(131,291 states, 3 s). Every other check takes about a second.

Each `holds` check was also run once by hand, with four workers, with one more
of an entity its rules are about. All still hold:

| Check | One more | States |
|---|---|---|
| 01 | drop (2) | 513,817 |
| 05 | drop (2) | 1,697,230 |
| 09 | cancel (2) | 90,326 |
| 12 | drop (2) | 526,633 |
| 15 | drop (2) | 164,236 |
| 21 | cancel (2) | 90,326 |

## Not modelled

- `text_delta`, `tool_event`, `turn_started` and `read_state`: live-only, never
  in the timeline, and no rule reads them.
- `history_search` and scroll-back through `history_pull{before_seq}`: reads
  below the cursor that never move it. `search_results` is written in the
  reading step like a page (453c24fc).
- The phone. Mobile and companion share the timeline but run under different
  channel identities, so live events never cross from one socket to the other.
  The phone's rows reach this socket as `row`s (7f4e122d). This spec is two
  clients on `companion.sock`.
- A cancel that arrives before its request is claimed. There is no request to
  mark, so `cancel_request` answers `not_found`. `PROTOCOL.md` scopes the
  guarantee to a cancel after `accepted`, and so does
  `CancelledRequestNeverRuns`.
- A failed turn: `{:failed}` ends a turn through the same path as
  `{:cancelled}`.
- A daemon restart and boot recovery. Recovery hands a request off through the
  same `Turns` step, so it reads the mark (431d5663); the model has no boot
  step to check that.
- A Queue crash (`Turns` ends its turns as `interrupted`, `turns.ex:148-156`),
  and a crash of `Turns` or of a request worker.
- The grant resume a confirmed approval re-ingests as a new turn
  (`sandbox.ex` `resume_request`).
- The LLM and tools, the ConversationStore, attachments, authentication and
  the socket's 0600 mode: single-call rules that ExUnit covers.
- Other conversations: the Queue keys all state by conversation.

## Findings

Every finding below was walked through the code on `feat/companion-chat-wire`
and is fixed there, or holds by construction. None was reproduced on a
running daemon. The `needs` check named under each brings its counterexample
back with its fix's mechanism switched off; open
`tla/out/companion_session/<check>.txt` after a run to see the path.

### COMPANION-1: `cancel` could not be built on `Queue.stop_conversation`
- **Severity:** medium. One client's cancel stopped the other client's turn.
- **Status:** fixed (286b43dd, 768ea8df). `Queue.stop_turn/3` stops one message
  by its id, and `cancel` names the `client_msg_id`. `turn_queue` models the
  stop (checks 18 to 19b).
- **Checks:** 09 holds; 11 breaks `OnlyNamedTurnCancelled` with the
  conversation stop.

### COMPANION-2: a connection must join the fan-out before its history is read
- **Status:** holds in the code (b9248004): `join` registers the Connection
  before it writes `server_hello` (`connection.ex:211-220`).
- **Checks:** 01 holds; 03 breaks `TimelineConverges` with the join after the
  first page.

### COMPANION-3: a cancel must not end the turn on the wire
- **Status:** fixed (768ea8df). `Companion.Turns` ends every turn from the
  Queue's outcome and only from it, and the Connection's cancel writes nothing.
- **Checks:** 09 holds; 10 breaks `NoDoneAfterCancel`.

### COMPANION-4: a client must drop rows at or below its cursor, and pull on a gap
- **Status:** documented in `PROTOCOL.md`'s client rules. They now apply to
  every live row, a `row` or a `text_done` (7f4e122d). The clients live outside
  this repository.
- **Checks:** 01, 15 and 21 hold; 02, 17 and 23 break without the cursor.

### COMPANION-5: `server_seq` must be assigned in the insert
- **Status:** holds in the code. Every writer (`append_in_tx`) reads and bumps
  the per-profile counter inside one transactional Repo call.
- **Checks:** 01 holds; 04 breaks `SeqStrictlyIncreasing`.

### COMPANION-6: a live reply that overtakes a history page is lost
- **Severity:** medium. The window was short, but the reply a user waited for
  could stay unshown for as long as the conversation stayed quiet.
- **Status:** fixed (453c24fc). `history_page` and `search_results` are written
  to the socket in the step that read them (`read_opts`), so a live row for a
  row written after the read reaches the socket after the page.
- **Checks:** 01 holds; 20 (13 states) breaks `TimelineConverges` with the page
  sent through the Connection's mailbox.
- **Counterexample (check 20):**
  1. A client's pull after `server_hello` is read: its page is not yet sent.
  2. A message's turn completes, and `Turns` writes the reply as row 2 and
     broadcasts its `text_done`. That lands in the Connection's mailbox ahead
     of the page.
  3. The client drops row 2 as a gap, because its pull is still out.
  4. The page, read before row 2 existed, lacks it. The client is at rest
     without the reply.

### COMPANION-7: a message whose turn writes no reply stayed off every client's timeline
- **Severity:** low. The other client never showed a cancelled or failed
  message until the conversation moved on or it reconnected.
- **Status:** fixed (7f4e122d). Every row written outside a turn's completion
  is announced to every connection as a `row` as it is written: the sender's
  own user row, a slash command's answer, a delivery, and a row the phone
  writes. `accepted.server_seq` is set only on a duplicate, as the reply's seq.
- **Checks:** 21 holds; 22 (9 states) breaks `TimelineConverges` with the user
  row not announced.
- **Counterexample (check 22):** a client sends a message; its row 1 is written
  and not announced. The client cancels it before the hand-off, and `Turns`
  ends it with one `turn_error`. The conversation is at rest, and no client
  shows row 1.

### COMPANION-8: a cancel between `accepted` and the hand-off was lost
- **Severity:** medium. A user who cancelled right after `accepted` still got
  the message run and answered.
- **Status:** fixed (431d5663), found in the implementation's review, not by
  this spec. The cancel is recorded on the request first (`cancelled_at`,
  `cancel_request`). `Turns` owns the hand-off: in one step of its process it
  reads the mark and either ends a marked request with one `turn_error` or
  enqueues it. It sends every `Queue.stop_turn` itself, after its own
  enqueue, so a stop never overtakes the turn it names. Boot recovery hands off
  through the same step (not modelled).
- **Checks:** 09 holds `CancelledRequestNeverRuns`; 24 (6 states) breaks it
  with the old code. Witness 25 reaches the window.
- **Counterexample (check 24):**
  1. A client's message is claimed, answered `accepted`, and its row written.
     The worker's hand-off waits in `Turns`' mailbox.
  2. The client cancels it. The Connection's `Queue.stop_turn` finds no such
     turn (`not_found`) and nothing else records the cancel.
  3. `Turns` hands the turn off, and it runs.

### Design notes
- **Where `text_done` comes from:** from `{:completed}` in `Turns` (768ea8df),
  so a stop between the reply callback and the claim (`turn_queue`'s QUEUE-2
  and QUEUE-3) never leaves the timeline holding an answer the history marks
  as stopped.
- **A turn whose outcome is lost:** `Turns` watches the Queue it handed each
  turn to and ends the turn as `interrupted` on that Queue's `:DOWN`. Not
  modelled.
- **`turn_error` is live-only and carries no seq.** Since 7f4e122d the user's
  row reaches every client anyway, as a `row`.
- **The claim and the user row are two writes.** A restart between them
  leaves a claim with no row. Boot recovery re-runs the request under the
  attempt fence, and the row is written then. Not modelled.
- **Approvals:** a pending approval is not re-sent at `server_hello`, so a
  client that connects after the card was broadcast never sees it. A confirmed
  grant resumes its request as a new turn even if the turn that asked for it
  was cancelled: the token outlives the turn. Neither breaks a rule here.
