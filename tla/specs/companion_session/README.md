# companion_session: the companion chat socket, one shared conversation

Models the companion chat socket (`companion.sock`) for one conversation that
two clients share:
- each client's `Companion.Connection`, connecting and dropping at any time;
- the request path both transports share (`Companion.Requests`): the durable
  claim, `accepted`, the request coordinator's attempt fence, the user's row,
  announced as it is written, and the request's settlement once ingest
  returned;
- `Companion.Turns`, one process with one mailbox, the settlement owner of both
  transports. It hands every turn to the Queue, sends every stop of a turn it
  handed off, ends every turn on the wire from the Queue's outcome, and settles
  a request the gateway answered without a turn;
- the Gateway Queue;
- the timeline (`FermixCore.Companion.Timeline`, written through
  `Memory.Repo`);
- a scheduled job reporting back through `Channels.Companion.send_message`,
  which stands for a GPT-Live call's rows too (`write_call_row`, written and
  announced the same way);
- one approval, kept by `Companion.Approvals` until it resolves or expires,
  and answered by a `/confirm` or `/deny` command.

The clients follow the rules `FermixCore.Companion.Protocol` exports in
`apps/fermix_core/priv/companion/PROTOCOL.md` ("Keeping a client's timeline",
"Delivery and the outbox", "Approvals"). Each keeps an outbox, resent on every
connection, and a seq cursor that applies a live row (a `row` or a
`text_done`) at cursor + 1. It drops every approval card it shows when
`server_hello` arrives. `PROTOCOL.md` is pinned whole, so a change to those
rules marks the spec STALE.

The spec was first written as a design spec, ahead of the code (70dc7e86). It
was then re-read against the implementation, and re-read again after its
fixes. COMPANION-1 to COMPANION-5 are what the design spec asked of the
implementation. COMPANION-6 and COMPANION-7 were found in the first re-read,
and COMPANION-8 in the implementation's own review. COMPANION-9 to
COMPANION-13 were found in the 2026-09-27 review of the phone channel, which
made `Companion.Turns` the settlement owner of both transports; the re-reads
after it added the settlement, the settlement that fails, and the approval
cards kept across drops and dropped at `server_hello`. All thirteen are fixed
or hold, in the code or in `PROTOCOL.md`'s client rules. The 2026-10-03
re-read for M56's typed turns during a voice call added a turn that ends with
no reply, `turn_done` on companion protocol 2, and each client's version. The
re-read after M56 stage 5 found a second writer the job's row stands for, a
GPT-Live call's row, and the Mac's `row` carrying `kind` and `metadata`,
which no rule reads; nothing the spec models changed. The re-read after M56
stage 6 found one more row that writer stands for, a call's own row when it
ends, written by the task that made the call's gist or by the boot pass after
a restart, and `PROTOCOL.md` describing it; again nothing the spec models
changed. The re-read after M56 stage 7 found two more rows that writer stands
for, a GPT-Live task's running and done rows, written by `Voice.Detached`
after the call has ended (a job's row can be written at any time), and a new
clause of `Requests.cancel`: a version 2 `cancel` with `task_ref` names no
request and never reaches the request store or `Turns`, and stops one voice
task's own turn through its owner, a named stop `turn_queue` proves; a refused
one is an `error` the client acts on no rule for. The request `cancel` the
spec models is unchanged, so nothing it models changed.

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
to the worker's casts into `Turns`. Nothing distinct is lost this way:
- A client event lost in a drop looks to the client exactly like one whose
  answer was lost, because the client acts only on answers.
- An event delivered late is the same as one sent late, and users here cancel,
  answer or resend at any moment.

`Turns` is a separate process: hand-offs, settlements, cancels and the Queue's
outcomes queue in its mailbox and are handled in order. Nobody waits on it for
a request's fate: the hand-off and the settlement are casts. `Turns` itself
waits on the Queue for each stop it sends, with no timeout, and the Queue
answers however busy it is, so the model folds the Queue's stop into that
`Turns` step.

**What the code does, as modelled:**
- A `msg` is claimed under its `client_msg_id` and answered `accepted` before
  anything runs (`claim_and_run`). The coordinator starts one attempt
  (`acquire_and_run`). The attempt writes the user's row and announces it to
  every connection as a `row` (`announce_user_row`, through
  `Companion.Fanout`). It then calls `Turns.handle_message`, which casts the
  hand-off into `Turns`' mailbox. A slash command the gateway answers without a
  turn hands nothing off.
- Once ingest returned, the worker moves the coordinator's fence onto `Turns`
  and casts the request's settlement behind its hand-off
  (`settle_after_ingest`). `Turns` completes the request only if no turn was
  handed off for it (`settle_unless_handed_off`): a turn settles from its
  outcome instead. A completion that fails, in the store or by a raise in the
  request path's settle code, is followed by one failure write for the
  attempt and by `error{request_failed, client_msg_id}` to the connection that
  sent the request (`run_settle`; `Requests.fail_attempt`, `report_failure`).
- `Turns` hands the turn off in one step of its process (`hand_off`): it reads
  the request's cancel mark and either ends a marked request with one
  `turn_error` (settling it failed) or enqueues it. A `cancel` goes through
  `Requests.cancel`, for both transports: it marks the request first
  (`cancel_request`, one Repo call), then asks `Turns`, which sends
  `Queue.stop_turn` for a turn it handed off, after that turn's enqueue, and
  waits for the answer (`stop_in_queue`).
- `Turns` holds a turn's reply until the Queue's outcome:
  - `{:completed}` writes the reply row, fenced to the running attempt, and
    announces `text_done{server_seq}`, then completes the request;
  - `{:completed}` of a turn its runner said ends with no reply (M56 §4.4: a
    turn of the chat during a GPT-Live call, which answered exactly
    `[SILENT]`) writes no row, completes the request and announces
    `turn_done`, live-only and sent only to a client that declared companion
    protocol 2. The runner's word (`Turns.silent`), its reply and its outcome
    come from the turn's one process in that order, so they are one event,
    `"quiet"`;
  - `{:cancelled}` settles the request failed and announces one `turn_error`,
    which is live-only.
- Whether a turn may end with no reply is frozen when it starts, at the
  queue's checkout (`MainAgent.turn_state` -> `Voice.Bridge.chat_call` ->
  `Companion.every_client_reads?`): only a turn this socket's transport runs,
  while every client joined then declared version 2. A phone turn in the chat
  (M56 D9) is never offered it: the phone's wire has no such ending. Each
  client's version is fixed for the run (`V1Clients`), and the clients joined
  at the start are kept as the turn's watchers.
- Every writer gets `server_seq` from the per-profile counter inside the
  insert's transaction (`append_in_tx`).
- A Connection joins the registry before it writes `server_hello`, and writes
  every approval card still waiting right behind it. It writes every
  `history_page` to the socket in the step that read it (`read_opts`). A page
  is cut to fit its byte budget (60 KiB on this socket): it keeps its oldest
  rows, at least one, and its `next_after_seq` names the last row it kept.
- A job's row is written, then announced as a `row` by the job's own process
  (`send_message` -> `announce_written`).
- An approval is a single-use token, stored by `store_pending_grant` for a
  directory grant or for a coding run's vendor-config change to acknowledge.
  `Companion.Approvals` keeps its card for the transport that raised it and
  announces it there in the same call, through the one announce that also
  carries its end. The first `/confirm` or `/deny` that `take`s the token
  applies the answer; `Approvals.resolve` forgets the card and announces
  `approval_resolved`. When the card's `ttl_s` runs out, `Approvals` drops it
  and announces `approval_resolved{expired}`. The turn does not wait on it. A
  client drops every card it shows when `server_hello` arrives and keeps only
  the cards sent after it, since `approval_resolved` goes only to the
  connections open when the card ends.

**Environment switches** (set per check):
- `ClientsCanDisconnect`: a connection drops, and what is in its mailbox or on
  the socket is lost. A request worker runs on, since it is not linked. The
  client keeps its outbox, its view, and any approval card it shows until its
  next `server_hello`. `MaxDrops` bounds the drops.
- `MessagesCanBeResent`: a client resends a message it has no `accepted` for
  yet, at any moment on a live connection, at most once per message.
- `TurnsCanBeCancelled`: a user sends `cancel{client_msg_id}` for any message of
  the shared conversation, whatever state its request is in. `MaxCancels`
  bounds the cancels.
- `DeliveriesWhileOffline`: a scheduled job reports back once, at any moment,
  including while no client is connected.
- `PagesCanBeCut`: rows are long enough that a `history_page` holds fewer rows
  than its limit, at least one.
- `SettlesCanFail`: the settlement of a request answered without a turn fails:
  its completion write returns an error or exits, or the request path's settle
  code raises.
- `SilentTurns`: a GPT-Live call in the chat is up, so a turn whose snapshot
  lets it end with no reply may answer exactly `[SILENT]`. With it off the
  silence decision is never taken and the state space is the one before.
  `V1Clients` names the clients on companion protocol 1.

**Mechanism switches** (`TRUE` is the real code; each is switched off only by
the checks that show a rule needs it):
- `OutboxResend`: the client's outbox, resent on every new connection
  (`PROTOCOL.md`).
- `AcceptedDedupe`: a known `client_msg_id` is claimed as a duplicate
  (`claim_request_in_tx`, `classify_claim`). The coordinator starts no second
  attempt of a request running, completed or failed
  (`request_coordinator.ex:125-132`).
- `SeqCursor`: the client's cursor rules (`PROTOCOL.md`).
- `SubscribeBeforePull`: the Connection joins the registry before
  `server_hello` (`join`, `connection.ex:258-268`).
- `PageWrittenInReadStep`: the Connection writes `history_page` to the socket
  in the step that read it (`read_opts`, `connection.ex:534-538`). `FALSE`
  sends it through its own mailbox, where a live row sent after the read can
  overtake it.
- `AnnouncesEveryRow`: every row written outside a turn's completion is
  announced as a `row` as it is written: the user's row (`announce_user_row`,
  `connection.ex:522-523`) and a delivery (`announce_written`,
  `channels/companion.ex:338-339`), both built by `Companion.Output.row` and
  sent through `Companion.Fanout.announce`. `FALSE` announces no user row.
- `SingleAnswer`: `Confirmations.take` is an `:ets.take`, the sole consumer of
  a token (`confirmations.ex:21-31`).
- `ResendsPendingApprovals`: the Connection writes every card still waiting
  right after `server_hello`, in the step that joined the registry
  (`send_pending_approvals`, `connection.ex:274-283`, from
  `Approvals.pending`). `FALSE`: a card goes out once, live.
- `DropsCardsAtHello`: when `server_hello` arrives the client drops every card
  it shows and keeps only those sent after it (`PROTOCOL.md` "Approvals").
  `FALSE` keeps a card across a drop until an `approval_resolved` reaches it.
- `OneTurnAtATime`: `maybe_start_next_request` (`queue.ex:317-325`).
- `StopTurnNamesTurn`: a stop ends the named message's turn only
  (`Queue.stop_turn`, `stop_named_in`, `queue.ex:185`, `:1035-1072`). `FALSE`
  is the conversation stop.
- `CancelMarksRequest`: a cancel is recorded on its request first
  (`Requests.cancel`, `requests.ex:157-173`; `cancel_request`,
  `mobile_sql.ex:546-565`). `Turns` reads the mark and enqueues in one step
  (`hand_off`, `turns.ex:328-343`), and sends every stop of a turn it handed
  off itself, after the enqueue (`turns.ex:242-246`, `stop_in_queue`,
  `:449-460`). `FALSE` is the code before 431d5663: the Connection called
  `Queue.stop_turn` directly.
- `OutcomeEndsTurn`: a turn ends on the wire only from the Queue's outcome, in
  `Turns`; the cancel writes nothing.
- `SettleAfterIngest`: once ingest returned, the request worker casts the
  request's settlement to `Turns` (`settle_after_ingest`,
  `requests.ex:303-307`). `FALSE` is the code before: a message the gateway
  answered without a turn stayed `running`, and the next boot ran it again.
- `SettleUnlessHandedOff`: `Turns` settles that request only if no turn was
  handed off for it (`handle_cast({:settle_unless_handed_off, ...})`,
  `turns.ex:288-294`). `FALSE` completes it regardless, as the code before did
  for every `command`, so a command that became a turn (`/ultra`) had its reply
  refused.
- `FailsUnsettled`: a settlement that fails is followed by one failure write
  for the attempt and by `error{request_failed, client_msg_id}` to the client
  that sent the request (`settle_inline`, `run_settle`, `turns.ex:361-396`;
  `fail_attempt`, `report_failure`, `requests.ex:340-360`), through the
  transport's `report_failure`, which the connection writes as a failed
  worker's error (`connection.ex:510-517`, `:159-160`). `FALSE` only logs the
  failure: the request stays `running`, and the next boot runs the command
  again.
- `SeqAssignedOnInsert`: the seq comes from the counter inside the inserting
  transaction (`append_in_tx`, `mobile_sql.ex:737-743`). `FALSE`: a writer
  reads the counter, then inserts in a second call.
- `SilenceGate`: a turn may end with no reply only if every client joined
  when it started declared version 2 (`MainAgent.live_call`,
  `Voice.Bridge.chat_call` for a turn on this socket's channel,
  `Companion.every_client_reads?`, frozen into the turn's snapshot). `FALSE`
  offers silence whoever is joined.

**Bounds** (set per check): `Clients` (always two), `Senders` (the clients
whose users type), `InlineSenders` (the senders whose messages are slash
commands answered without a turn), `MsgsPerSender`, `PageLimit` (2),
`Approvals` (0 or 1), `MaxDrops`, `MaxCancels`. Each check uses only the
entities its rules need. Invariant checks in which both clients type the same
kind of message reduce by their symmetry.

## What holds

**Check 01** holds with one client typing, a drop, resends, pages cut to their
byte budget, and a job reporting back at any moment:
- Every client shows a gapless, duplicate-free prefix of the timeline at all
  times, and all of it once it and the conversation are at rest
  (`TimelineConverges`). This rests on:
  - `SeqCursor` (check 02);
  - `SubscribeBeforePull` (check 03);
  - `PageWrittenInReadStep` (check 20), COMPANION-6's fix.
- Every row's seq is higher than the one before (`SeqStrictlyIncreasing`).
  This rests on `SeqAssignedOnInsert` (check 04).

Witnesses 18 and 19 show why the cursor rule has two halves: live rows arrive
out of seq order, and a page and a live row can carry the same row. Witness 30
shows a page cut to its byte budget reaching a client, with more to pull.

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

**Check 21** holds in check 09's setup, with pages cut to their byte budget:
every client shows the timeline, a cancelled message's row included
(`TimelineConverges`). This rests on `AnnouncesEveryRow` (check 22),
COMPANION-7's fix, and still on `SeqCursor` (check 23).

**Check 26** holds with one client's message becoming a turn and the other
client's a slash command answered without one, whose settlement can fail,
resends, and a cancel for any message at any moment:
- Once `Turns` has nothing left to do and no turn waits or runs, every
  accepted request is settled, so no boot runs again a request that was
  answered or failed (`RequestsSettle`). This rests on `SettleAfterIngest`
  (check 27), COMPANION-9's fix, and on `FailsUnsettled` (check 31),
  COMPANION-12's fix.
- No turn completes after its request was settled, which would refuse its
  reply (`ReplyNeverRefused`). This rests on `SettleUnlessHandedOff` (check
  28), COMPANION-10's fix.

Witness 32 shows a settlement that fails: the request is failed and its
client told.

**Check 12** holds with both clients shown the approval, a drop, and a cancel:
- At most one answer to it is ever applied (`ApprovalAnsweredOnce`). This
  rests on `SingleAnswer` (check 13). Witness 14 shows both clients answering:
  one take resolves the approval, and the other client, still showing the
  card, answers too and is refused.
- While the approval waits, every client that has caught up shows its card,
  one that connected after the card went out included
  (`PendingApprovalShown`). This rests on `ResendsPendingApprovals` (check
  29), COMPANION-11's fix.
- Once it no longer waits, no client that has caught up shows it, one that was
  away when it was answered or expired included (`NoStaleCard`). This rests on
  `DropsCardsAtHello` (check 33), COMPANION-13's fix.

**Check 34** holds with a GPT-Live call in the chat, a version 2 client typing,
a version 1 client that may drop and reconnect, and a turn free to end with no
reply whenever its snapshot allows: no turn ends with `turn_done` while a
version 1 client watched it start (`NoTurnLeftThinking`), so no version 1
client is left showing a turn as thinking. This rests on `SilenceGate` (check
35). Witness 36 shows a turn ending with `turn_done` while a client watches
it: the version 1 client had dropped before the turn started.

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
| 06 | `AcceptedDedupe` | 8 states: a resend, before its `accepted` is read, is handed to the Queue a second time |
| 07 | `OneTurnAtATime` | 10 states: the second client's message starts while the first client's turn runs |
| 10 | `OutcomeEndsTurn` | 10 states: the turn has finished, its `{:completed}` is still in `Turns`' mailbox, and a cancel answered at once is followed by `text_done` |
| 11 | `StopTurnNamesTurn` | 14 states: a cancelled request is ended at its hand-off; the cancel's stop, still in `Turns`' mailbox, then reaches the Queue as the conversation stop and kills the other client's turn |
| 13 | `SingleAnswer` | 15 states: one client's answer takes the token; the other, still showing the card, answers too and is applied as well |
| 16 | `OutboxResend` | a lasso: a drop loses the `accepted`, and the client never sends the message again |
| 17 | `SeqCursor` | a lasso: the delivery lands while a client is offline, and it never pulls it |
| 20 | `PageWrittenInReadStep` | 14 states: COMPANION-6's path |
| 22 | `AnnouncesEveryRow` | 10 states: COMPANION-7's path |
| 23 | `SeqCursor` | 9 states: a client that connects after a message's row was announced never pulls it |
| 24 | `CancelMarksRequest` | 6 states: COMPANION-8's path |
| 27 | `SettleAfterIngest` | 4 states: COMPANION-9's path |
| 28 | `SettleUnlessHandedOff` | 9 states: COMPANION-10's path |
| 29 | `ResendsPendingApprovals` | 13 states: COMPANION-11's path |
| 31 | `FailsUnsettled` | 5 states: COMPANION-12's path |
| 33 | `DropsCardsAtHello` | 18 states: COMPANION-13's path |
| 35 | `SilenceGate` | 10 states: the version 1 client connects, the version 2 client's message starts its turn with both joined, and the turn ends with `turn_done`, which the version 1 client is never sent |

The settlement `Turns` is sent after every hand-off made several paths one or
two states longer than they were before it: `Turns` handles that settlement
between the hand-off and what follows.

The whole spec runs in about a minute and a half with the runner's one worker
(96 s; up to two minutes on a loaded laptop). The largest checks are 15
(63,810 states and its liveness graph, 22 s), 05 (644,722 states, 16 s), 01
(568,195 states, 12 s), 12 (256,995 states, 6 s) and 26 (147,864 states,
5 s). Every other check takes a few seconds.

Each `holds` check was also run once by hand, with four workers, with one more
of an entity its rules are about. All still hold:

| Check | One more | States |
|---|---|---|
| 01 | drop (2) | 1,452,877 |
| 05 | drop (2) | 2,564,390 |
| 09 | cancel (2) | 140,954 |
| 12 | drop (2) | 981,243 |
| 15 | drop (2) | 210,613 |
| 21 | cancel (2) | 182,444 |
| 26 | cancel (2) | 540,622 |

## Not modelled

- `text_delta`, `tool_event`, `turn_started` and `read_state`: live-only, never
  in the timeline, and no rule reads them. `read_state` is a frontier the
  daemon caps at the newest row and announces to every watcher, the phones
  included.
- `history_search` and scroll-back through `history_pull{before_seq}`: reads
  below the cursor that never move it. `search_results` is written in the
  reading step like a page (453c24fc).
- The phone. It shares this timeline: its rows and `read_state` reach this
  socket through `Companion.Fanout`, each wire in its own shape (a row is built
  once, by `Companion.Output.row`), and this socket's reach the phones, a
  turn's reply as a `row`. A turn's stream and its ending, and an approval card
  with its resolution, stay on the transport that raised them, the only one
  its token resolves from. A phone's row reaches this spec's clients as the
  job's row does. This spec is two clients on `companion.sock`. The phone's
  turns run in this conversation's queue too (M56 D9): a phone turn waits as
  another sender's would, its cancel names its own message id (the named stop
  `turn_queue` proves), it is never offered silence, and it ends on its own
  wire.
- A phone's revocation. `Turns` runs it in its own mailbox as a cancel of
  every unsettled request the device claimed: one step marks them all and
  stops each turn it handed off (`handle_cast({:revoke_device, ...})`,
  `turns.ex:296-308`), so the device registry that forgot the phone never
  waits on the store.
- A cancel that arrives before its request is claimed. There is no request to
  mark, so `cancel_request` answers `not_found`. `PROTOCOL.md` scopes the
  guarantee to a cancel after `accepted`, and so does
  `CancelledRequestNeverRuns`.
- A failed turn: `{:failed}` ends a turn through the same path as
  `{:cancelled}`.
- A daemon restart and boot recovery. Recovery hands a request off through the
  same `Turns` step, so it reads the mark (431d5663); the model has no boot
  step to check that.
- A Queue crash (`Turns` ends its turns as `interrupted`, `turns.ex:310-316`),
  and a hand-off `Turns` cannot complete (a mark it cannot read, a Queue
  already gone), which ends like a marked one. A cancel whose stop finds its
  Queue gone is left to that `:DOWN`: `stop_in_queue` (`turns.ex:449-460`)
  waits with no timeout, so its call exits only when the Queue was already dead
  (`:noproc`) or dies during the stop (its exit reason), and it catches only
  that exit of its own call; until the review's third round (its R3-2) a Queue
  that died during the stop crashed `Turns`. A store call that exits inside
  `Turns` is logged as that request's error and the turn still ends once
  (`guarded/3`, `turns.ex:559-569`). A raise in `Turns`' own code or store
  calls is a defect: it crashes `Turns` to `Companion.Supervisor`
  (`rest_for_one`), which releases the requests it fenced. A request worker's
  crash.
- A slash command's answer: `Turns` writes and announces it as a `row`
  (`write_untracked`), as a delivery is. Only the command's settlement is
  modelled. A command that answers later (`/background`, a `/skills` review or
  approval), typed as a `msg` or sent as a `command`, defers its request, which
  settles when the command reports.
- The report of a failed settlement. Its `error{request_failed}` goes to the
  connection that ran the request, best effort (lost if that connection
  dropped), and it can follow the command's own answer row; no client rule
  reads it, so the model only records it (`told`). The failure write never
  fails here: with the store down for both writes, the request stays `running`
  and the next boot runs it again, and both failures are logged. A failure
  after the completion committed (a raise in the phone's `after_settle`) tells
  the phone `request_failed` for a request it saw answered; only a defect
  reaches it.
- The two casts of one request worker are appended to `Turns`' mailbox
  together. Another process's message can land between them in the daemon;
  the only one that could change the settlement's decision is the turn's own
  outcome, and `Turns` keeps the request in its `ended` list, so the
  settlement is still skipped.
- The grant resume a confirmed approval re-ingests as a new turn (`sandbox.ex`
  `resume_request`).
- The peer check at the hand-over (`handle_info(:socket_handover)`,
  `connection.ex:126-133`). A client the daemon cannot place is sent
  `error: unidentified_client` and closed before a line is read, which the
  client sees as a drop before `server_hello`. The caller it places rides on
  each turn (`metadata.caller`) and decides only what the turn's tools may do.
- The LLM and tools, the ConversationStore, attachments, authentication and
  the socket's 0600 mode: single-call rules that ExUnit covers.
- A GPT-Live call's rows (`Channels.Companion.write_call_row`, M56 §4.2,
  §4.5): a result the voice cannot say, written from the call's session, and
  the call's one row when it ends, written after the session has gone by the
  task that made its gist (`Realtime.CallGist`) or, after a restart, by the
  boot pass (`Voice.CallRowSweep`). Each goes through the same proactive
  write and announcement as a job's delivery (`Output.persist_text` with its
  key, then `announce_written`), so the job's row stands for them. They are
  deduplicated per task revision or per call, as a keyed delivery is, and
  their `kind` and `metadata.call`, which the Mac's `row` carries, are read by
  no client rule.
- The Live voice mirror (`Voice.ChatMirror`, M56 §4.3). While a call in the
  chat is up, `Turns` tells it each turn of the chat's conversation it hands
  off and, as one completes, its answer: a cast to the call's session and one
  ConversationStore read, whose exit is logged. No request, turn or wire state
  moves, so no rule here reads it.
- Between a turn's checkout and its `turn_started` the runner reads history
  and builds the prompt; the model folds both into the turn's start. A version
  1 client that joins in that window, after the silence decision and before
  `turn_started`, would see the turn start and, if it ends with no reply,
  never see it end until the next turn begins. The window is the runner's own
  set-up, milliseconds; it is not modelled.
- `turn_done` on the wire: no client rule reads it (a client clears the turn
  it shows, which the model does not track), so it is recorded as the turn's
  ending (`ends`) and not put on the wire. A version 1 connection drops it
  (`write_in_version`), an ExUnit rule.
- Other conversations: the Queue keys all state by conversation.

## Findings

Every finding below was walked through the code and is fixed, or holds by
construction. None was reproduced on a running daemon. The `needs` check named
under each brings its counterexample back with its fix's mechanism switched
off; open `tla/out/companion_session/<check>.txt` after a run to see the path.

### COMPANION-1: `cancel` could not be built on `Queue.stop_conversation`
- **Severity:** medium. One client's cancel stopped the other client's turn.
- **Status:** fixed (286b43dd, 768ea8df). `Queue.stop_turn/3` stops one message
  by its id, and `cancel` names the `client_msg_id`. `turn_queue` models the
  stop (checks 18 to 19b).
- **Checks:** 09 holds; 11 breaks `OnlyNamedTurnCancelled` with the
  conversation stop.

### COMPANION-2: a connection must join the fan-out before its history is read
- **Status:** holds in the code (b9248004): `join` registers the Connection
  before it writes `server_hello` (`connection.ex:258-268`).
- **Checks:** 01 holds; 03 breaks `TimelineConverges` with the join after the
  first page.

### COMPANION-3: a cancel must not end the turn on the wire
- **Status:** fixed (768ea8df). `Companion.Turns` ends every turn from the
  Queue's outcome and only from it, and the cancel writes nothing.
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
- **Checks:** 01 holds; 20 (14 states) breaks `TimelineConverges` with the page
  sent through the Connection's mailbox.
- **Counterexample (check 20):**
  1. A client's pull after `server_hello` is read: its page is not yet sent.
  2. A message's turn completes, and `Turns` writes the reply as row 2 and
     announces its `text_done`. That lands in the Connection's mailbox ahead
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
- **Checks:** 21 holds; 22 (10 states) breaks `TimelineConverges` with the user
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
  through the same step (not modelled). `Requests.cancel` now runs this flow
  for both transports, the phone's included.
- **Checks:** 09 holds `CancelledRequestNeverRuns`; 24 (6 states) breaks it
  with the old code. Witness 25 reaches the window.
- **Counterexample (check 24):**
  1. A client's message is claimed, answered `accepted`, and its row written.
     The worker's hand-off waits in `Turns`' mailbox.
  2. The client cancels it. The Connection's `Queue.stop_turn` finds no such
     turn (`not_found`) and nothing else records the cancel.
  3. `Turns` hands the turn off, and it runs.

### COMPANION-9: a slash command typed as a message was run again at the next boot
- **Severity:** high. The Mac app sends what the user types as a `msg`, so
  `/help` or `/new` typed in the chat left its request `running`, and the next
  boot within the claim's 24 hours ran it again and wrote a second answer.
- **Status:** fixed (6d1f802f) in the 2026-09-27 phone-channel review (its STB-4), found
  there, not by this spec. Once ingest returns, the request worker casts the
  request's settlement to `Turns` behind its hand-off (`settle_after_ingest`),
  and `Turns` completes a request no turn was handed off for.
- **Checks:** 26 holds `RequestsSettle`; 27 (4 states) breaks it with the old
  code.
- **Counterexample (check 27):** a client connects and sends a slash command.
  It is claimed, answered `accepted`, and answered by the gateway without a
  turn. Nothing is left to run, and the request is still `running`.

### COMPANION-10: a command that became a turn had its reply refused
- **Severity:** high. `/ultra <prompt>` (or any command the gateway turns into
  a turn) was completed as soon as ingest returned, so its turn's reply was
  refused as a stale attempt and the client never saw an answer.
- **Status:** fixed (6d1f802f) in the same review (its STB-3). `Turns` settles a request
  after ingest only when no turn was handed off for it, decided in its own
  mailbox after the hand-off the same worker cast
  (`settle_unless_handed_off`); a turn settles from its outcome.
- **Checks:** 26 holds `ReplyNeverRefused`; 28 (9 states) breaks it with the
  settlement made regardless.
- **Counterexample (check 28):**
  1. A client's message is claimed and handed off, and its settlement cast
     behind the hand-off.
  2. `Turns` hands it to the Queue; the turn runs, commits and claims its
     outcome, and `{:completed}` joins `Turns`' mailbox behind the settlement.
  3. The settlement completes the request, and the turn's reply is refused.

### COMPANION-11: a client that connected after an approval went out never showed it
- **Severity:** high. An approval raised while the app was closed, or while it
  reconnected, reached no one, so the owner could never grant what the turn
  asked for.
- **Status:** fixed (6d1f802f) in the same review (its FEAT-2). `Companion.Approvals`
  keeps each card for the transport that raised it until it resolves or its
  `ttl_s` runs out, and the Connection writes every card still waiting right
  after `server_hello`, with the time it has left as its `ttl_s`. A card's end
  is announced as `approval_resolved`, `expired` included.
- **Checks:** 12 holds `PendingApprovalShown`; 29 (13 states) breaks it with
  the card sent once, live.
- **Counterexample (check 29):** one client's turn raises the card while the
  other client is not connected. The turn completes. The other client
  connects, reads its history and is at rest, and the approval still waits
  without its card.

### COMPANION-12: a slash command whose answer could not be recorded stayed running
- **Severity:** low: it needs the store to fail at that moment. A store that
  timed out or restarted while `Turns` completed a slash command left the
  request `running`. The chat got no word of the failure, and the next boot
  within the claim's 24 hours ran the command again.
- **Status:** fixed (6d1f802f) in the same review's third round (its R3-4), found there,
  not by this spec, in the settlement COMPANION-9's fix moved into `Turns`,
  which only logged a failure. `Turns` now runs the settlement's completion
  (`run_settle`, which also contains a raise in the request path's settle
  code), and on a failure fails the request once for its attempt and sends
  `error{request_failed, client_msg_id}` to the connection that sent it,
  whether or not the failure write took (`settle_inline`;
  `Requests.fail_attempt`, `report_failure`). `guarded/3` now catches exits
  only.
- **Checks:** 26 holds `RequestsSettle` with `SettlesCanFail`; 31 (5 states)
  breaks it with the failure only logged. Witness 32 reaches the failure path.
- **Counterexample (check 31):** a client connects and sends a slash command.
  It is claimed and answered by the gateway without a turn, and `Turns`'
  completion of it fails. Nothing is left to run, and the request is still
  `running`.

### COMPANION-13: a card that ended while a client was away stayed on it
- **Severity:** low. A reconnected client kept showing an approval that was
  answered elsewhere or had expired; tapping it answered "Confirmation
  failed".
- **Status:** documented (6d1f802f) in `PROTOCOL.md`'s client rules (found in the same
  review's contract pass). `approval_resolved` goes only to the connections
  open when a card ends, and what follows `server_hello` is only the cards
  still waiting, so the daemon never withdraws such a card. A client drops
  every card it shows when `server_hello` arrives and keeps only the cards sent
  after it. The clients live outside this repository.
- **Checks:** 12 holds `NoStaleCard`; 33 (18 states) breaks it with the card
  kept across the drop.
- **Counterexample (check 33):**
  1. One client's turn raises the card, and the other client shows it.
  2. That client drops, and the card expires while it is away.
  3. It reconnects, reads `server_hello` and its history, and is at rest
     still showing the card.

### Design notes
- **Where `text_done` comes from:** from `{:completed}` in `Turns` (768ea8df),
  so a stop between the reply callback and the claim (`turn_queue`'s QUEUE-2
  and QUEUE-3) never leaves the timeline holding an answer the history marks
  as stopped.
- **A turn whose outcome is lost:** `Turns` watches the Queue it handed each
  turn to and ends the turn as `interrupted` on that Queue's `:DOWN`, on both
  transports, and holds each request's fence, so a dead Queue fails the
  request once instead of releasing it to run again. Not modelled.
- **`turn_error` is live-only and carries no seq.** Since 7f4e122d the user's
  row reaches every client anyway, as a `row`.
- **The claim and the user row are two writes.** A restart between them
  leaves a claim with no row. Boot recovery re-runs the request under the
  attempt fence, and the row is written then. Not modelled.
- **Approvals:** a card is announced only to the transport whose turn raised
  it, because its token resolves only there (M19 §9.5); a phone's cards never
  reach this socket. `approval_resolved` is live-only, so a card that ended
  while a client was away leaves that client only by the client's own rule
  at `server_hello` (COMPANION-13). The daemon keeps at most 64 cards; one
  past that goes out live only, so a reconnect drops it while it still waits
  (not modelled: one approval here). A confirmed grant resumes its request as
  a new turn even if the turn that asked for it was cancelled: the token
  outlives the turn. That breaks no rule here.
