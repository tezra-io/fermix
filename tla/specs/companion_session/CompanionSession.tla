------------------------- MODULE CompanionSession -------------------------
(***************************************************************************)
(* The companion chat socket for ONE shared conversation: two clients on   *)
(* companion.sock, each with its own Companion.Connection, connecting and  *)
(* dropping at any time; the request path they share (Companion.Requests:  *)
(* the claim, accepted, the attempt fence, the user's row, ingest);        *)
(* Companion.Turns, which ends every turn on the wire from the Queue's     *)
(* outcome; the Gateway Queue; the timeline                                *)
(* (FermixCore.Companion.Timeline, written through Memory.Repo); a job     *)
(* reporting back through                                                  *)
(* Channels.Companion.send_message; and one approval, answered by a        *)
(* /confirm or /deny command.                                              *)
(*                                                                         *)
(* The clients follow the rules FermixCore.Companion.Protocol exports in   *)
(* priv/companion/PROTOCOL.md ("Keeping a client's timeline", "Delivery    *)
(* and the outbox"): an outbox resent on every connection, and a seq       *)
(* cursor.                                                                 *)
(*                                                                         *)
(* The Queue is ONE abstract process here, not the turn_queue module: the  *)
(* runner takes one .tla per spec, and turn_queue proves the rules taken   *)
(* as given against queue.ex: one turn at a time per conversation          *)
(* (maybe_start_next_request; SingleFlight rests on StartsWhenIdle), one   *)
(* outcome per turn through the claim (claim_active_turn;                  *)
(* AtMostOneOutcome), and a named stop (stop_turn) that ends the named     *)
(* message's turn only and spares it once it has claimed its outcome       *)
(* (OnlyNamedTurnCancelled rests on StopTurnNamesTurn, its checks 18 and   *)
(* 19). As in queue.ex, a turn starts in the callback that enqueues it or  *)
(* that clears the previous turn, then claims its outcome (after the       *)
(* commit) and invokes it.                                                 *)
(*                                                                         *)
(* Only the daemon-to-client side of a socket is a queue: a Connection's   *)
(* mailbox, then the socket, in order (every event it writes except        *)
(* server_hello reaches it as {:companion_event, _}, connection.ex:124).   *)
(* A client event, the Connection's handling of it, and the request        *)
(* worker, Repo and Queue calls it makes are one step. Nothing distinct    *)
(* is lost: a client event lost in a drop looks to the client exactly      *)
(* like one whose answer was lost (it acts only on answers), and one       *)
(* delivered late is one sent late (users here cancel, answer or resend    *)
(* at any moment). The one gap inside such a step that matters is          *)
(* modelled: a history page is read (one Repo call) and sent to the        *)
(* Connection's own mailbox in two steps (LiveRowsOvertakePage).           *)
(*                                                                         *)
(* Not modelled:                                                           *)
(* - text_delta, tool_event, turn_started, read_state: live-only, never    *)
(* in the timeline; no rule reads them;                                    *)
(* - history_search and scroll-back (history_pull{before_seq}): reads      *)
(* below the cursor that never move it;                                    *)
(* - the phone: mobile and companion share the timeline but run under      *)
(* different channel identities, so live events never cross from one       *)
(* socket to the other; this spec is two clients on companion.sock;        *)
(* - a failed turn ({:failed} ends it through the same path as             *)
(* {:cancelled}), a daemon restart and boot recovery, a Queue crash        *)
(* (Turns ends its turns as interrupted, turns.ex:115-123), a crash of     *)
(* Turns or of a request worker, and the grant resume a confirmed          *)
(* approval re-ingests as a new turn (sandbox.ex resume_request);          *)
(* - the LLM and tools, the ConversationStore, attachments, auth and the   *)
(* socket's 0600 mode (single-call rules; ExUnit covers them);             *)
(* - other conversations (the Queue keys all state by conversation).       *)
(*                                                                         *)
(* One step = one callback of one process, one Memory.Repo call, or one    *)
(* thing a client or the environment does.                                 *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/priv/companion/PROTOCOL.md @ 741b20607fe3
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/requests.ex#request,claim_and_run,acquire_and_run,run_started,ingest_span,append_user,ingest_gateway,handoff_settlement,history,accepted_event,history_event,emit @ d775f5d7484c
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/turns.ex @ b4c4926a309c
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/output.ex#text_done,turn_error,approval,approval_resolved,persist_text,persist_output @ b2b3eee7c5f7
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/connection.ex#handle_info,dispatch,hello,join,cancel,write_event,transport,request_opts,sink @ a7c7ddd008b8
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/endpoint.ex#@max_clients,accept_connection,start_connection,hand_over @ 61148c849930
\* SOURCE: apps/fermix_channels/lib/fermix_channels/channels/companion.ex#broadcast,dispatch,build_text_reply,build_turn_result,send_approval,send_message,announce_text,message @ b3ab2c19657e
\* SOURCE: apps/fermix_core/lib/fermix_core/companion/timeline.ex#append_client_message,append_proactive,history_page,claim_client_request,start_client_request,append_client_output @ 80efab0d3c3a
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/mobile_sql.ex#history,append_in_tx,next_server_seq,increment_server_seq,claim_request_in_tx,classify_claim @ fdf45f89fd4c
\* SOURCE: apps/fermix_channels/lib/fermix_channels/mobile/request_coordinator.ex#handle_call @ b9579b8e9e13
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/queue.ex#stop_turn,stop_named_turn,stop_named_in,maybe_start_next_request,claim_active_turn,stop_conversation_runtime,stop_active_turn,cancel_pending @ d7cf3a18de4c
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/commands/sandbox.ex#store_pending_grant,confirm,deny,notify_approval,take_pending,validate_pending @ 8ab15a5580bd
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/commands/sandbox/confirmations.ex @ 7f77c69d0c1a
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Clients,        \* the clients on the conversation, e.g. {c1, c2}
    Senders,        \* the clients whose users type, a subset of Clients
    MsgsPerSender,  \* messages each of them types
    None,
    PageLimit,      \* history_pull's limit
    Approvals,      \* approvals the turns may raise in all (0 or 1)
    MaxDrops,       \* bound: connection drops the environment may cause in all
    MaxCancels,     \* bound: cancels the users may send in all
    \* Environment switches: what may happen to the conversation.
    ClientsCanDisconnect,   \* a connection drops (sleep, network, the app killed); what is
                            \* in the Connection's mailbox or on the socket is lost
    MessagesCanBeResent,    \* a client resends a message it has no accepted for yet, at
                            \* any moment on a live connection (its ack timeout, or the
                            \* user's retry), at most once per message
    TurnsCanBeCancelled,    \* a user sends cancel{client_msg_id}, for any message of the
                            \* shared conversation, whatever state its turn is in
    DeliveriesWhileOffline, \* a scheduled job reports back into the conversation at any
                            \* moment, including while no client is connected (one delivery)
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off only by the checks that show a rule needs it.
    OutboxResend,        \* the client keeps every typed message until accepted and sends
                         \* it again on every new connection (PROTOCOL.md "Delivery and
                         \* the outbox")
    AcceptedDedupe,      \* a known client_msg_id is claimed as a duplicate
                         \* (claim_request_in_tx, classify_claim) and the request
                         \* coordinator starts no second attempt of a request running,
                         \* completed or failed (acquire_and_run, requests.ex:193-209)
    SeqCursor,           \* the client keeps the last server_seq it shows, pulls
                         \* history_pull{after_seq: cursor} after server_hello, while a
                         \* page says more and on a gap, and drops rows at or below it
                         \* (PROTOCOL.md "Keeping a client's timeline")
    SubscribeBeforePull, \* the Connection joins the registry before it writes
                         \* server_hello (join, connection.ex:212-221)
    SingleAnswer,        \* an approval token is consumed once: Confirmations.take is
                         \* an :ets.take (confirmations.ex:21-26, take_pending
                         \* sandbox.ex:397-406)
    OneTurnAtATime,      \* the Queue starts a turn only when none of the conversation's
                         \* turns is alive (maybe_start_next_request, queue.ex:304-312)
    StopTurnNamesTurn,   \* cancel stops the named message's turn only (Queue.stop_turn,
                         \* queue.ex:172, stop_named_in :1005-1042); FALSE is the
                         \* conversation stop (stop_conversation_runtime :990-994)
    OutcomeEndsTurn,     \* a turn ends on the wire only from the Queue's outcome, in
                         \* Companion.Turns; the Connection's cancel writes nothing
                         \* (cancel, connection.ex:238-246; turns.ex:155-168)
    SeqAssignedOnInsert, \* server_seq comes from the per-profile counter inside the one
                         \* transactional Repo call that inserts the row (append_in_tx,
                         \* mobile_sql.ex:490-496); FALSE: a writer reads the counter,
                         \* then inserts in a second call
    \* Timing. TRUE is the real code; FALSE forbids a live row reaching a
    \* Connection's mailbox between its history read and the page it sends to
    \* that mailbox (history, requests.ex:96-107, sent through sink,
    \* connection.ex:425-428). A check that sets it FALSE proves a property only
    \* for a Connection that writes the page in the step it reads it.
    LiveRowsOvertakePage

VARIABLES
    \* each client (the Protocol's client rules)
    link,       \* link[c]: "down", "hello" (client_hello sent), "up" (server_hello read)
    composed,   \* messages the users typed
    outbox,     \* outbox[c]: c's typed messages it has no accepted for yet
    sentOn,     \* sentOn[c]: messages sent on c's current connection
    view,       \* view[c]: the server_seq of each row the client shows, in order
    pulling,    \* pulling[c]: a history_pull is outstanding
    prompt,     \* prompt[c]: the client shows the approval card
    resent,     \* messages resent on the client's own initiative
    \* each Companion.Connection
    wire,       \* wire[c]: its mailbox's {:companion_event, _} then the socket, in order
    sub,        \* sub[c]: "no", "joining" (about to join the registry), "yes"
    reading,    \* reading[c]: the history page it read and has not sent to its
                \* mailbox yet, or None
    \* the request path and Companion.Turns
    accepted,   \* claimed client_msg_ids (mobile_client_requests)
    ends,       \* ends[m]: the endings written for m's turn, in order: "done"
                \* (text_done) or "cancelled" (turn_error)
    cancelAsked,\* messages a cancel reached the Queue for
    turnsBox,   \* Companion.Turns' mailbox: the Queue's outcomes
    appr,       \* the approval token: "none", "pending", "resolved", "expired"
    applied,    \* answers applied to it
    \* the Gateway Queue and its turn tasks
    qpending,   \* FIFO of waiting turns
    turn,       \* turn[m]: "none", "queued", "running", "claimed" (committed, holds
                \* its outcome), "ended"
    handed,     \* handed[m]: turns handed to the Queue for m
    \* the timeline and the job reporting back
    tl,         \* the rows: the server_seq of each, in insertion order
    job,        \* "idle", "read" (read the counter; SeqAssignedOnInsert off),
                \* "written" (row in, not announced), "done"
    jobSeq,     \* the counter value the job read, or the seq it wrote
    dseq,       \* the delivery row's server_seq, 0 before it is written
    \* environment budgets
    dropsLeft,
    cancelsLeft,
    \* observers (read only by witnesses)
    answeredBy,     \* clients whose answer to the approval reached the take
    dupWhileRunning \* a resend was claimed while its message's turn was alive

client   == <<link, composed, outbox, sentOn, view, pulling, prompt, resent>>
conn     == <<wire, sub, reading>>
turns    == <<accepted, ends, cancelAsked, turnsBox, appr, applied>>
queue    == <<qpending, turn, handed>>
store    == <<tl, job, jobSeq, dseq>>
env      == <<dropsLeft, cancelsLeft>>
obs      == <<answeredBy, dupWhileRunning>>
vars == <<client, conn, turns, queue, store, env, obs>>

Msgs == Senders \X (1..MsgsPerSender)
Owner(m) == m[1]

\* Clients that play the same part are interchangeable: invariant checks may
\* reduce by symmetry.
Symm == IF Senders = Clients THEN Permutations(Clients) ELSE Permutations(Clients \ Senders)

Live == {"running", "claimed"}          \* a turn task is alive
Stoppable == {"queued", "running"}      \* a stop still reaches it

Page == [rows : Seq(Nat), more : BOOLEAN]
DownEvents ==
    ({"hello_ok", "appr", "resolved"} \X {None}) \cup ({"acc"} \X Msgs)
    \cup ({"row"} \X Nat) \cup ({"page"} \X Page)

TypeOK ==
    /\ link \in [Clients -> {"down", "hello", "up"}]
    /\ composed \subseteq Msgs
    /\ outbox \in [Clients -> SUBSET Msgs]
    /\ sentOn \in [Clients -> SUBSET Msgs]
    /\ \A c \in Clients : view[c] \in Seq(Nat)
    /\ pulling \in [Clients -> BOOLEAN]
    /\ prompt \in [Clients -> BOOLEAN]
    /\ resent \subseteq Msgs
    /\ \A c \in Clients : wire[c] \in Seq(DownEvents)
    /\ sub \in [Clients -> {"no", "joining", "yes"}]
    /\ \A c \in Clients : reading[c] \in Page \cup {None}
    /\ accepted \subseteq Msgs
    /\ \A m \in Msgs : ends[m] \in Seq({"done", "cancelled"})
    /\ cancelAsked \subseteq Msgs
    /\ turnsBox \in Seq({"completed", "cancelled"} \X Msgs)
    /\ appr \in {"none", "pending", "resolved", "expired"}
    /\ applied \in Nat
    /\ qpending \in Seq(Msgs)
    /\ turn \in [Msgs -> {"none", "queued", "running", "claimed", "ended"}]
    /\ handed \in [Msgs -> Nat]
    /\ tl \in Seq(Nat)
    /\ job \in {"idle", "read", "written", "done"}
    /\ jobSeq \in Nat /\ dseq \in Nat
    /\ dropsLeft \in 0..MaxDrops /\ cancelsLeft \in 0..MaxCancels
    /\ answeredBy \subseteq Clients /\ dupWhileRunning \in BOOLEAN

-----------------------------------------------------------------------------
(* Helpers *)

Range(s) == {s[i] : i \in 1..Len(s)}
MaxOf(S) == IF S = {} THEN 0 ELSE CHOOSE x \in S : \A y \in S : y <= x

\* The client's cursor: the last server_seq it shows.
Cursor(c) == IF view[c] = <<>> THEN 0 ELSE view[c][Len(view[c])]

\* The per-profile counter, read and bumped inside the insert's transaction
\* (next_server_seq, increment_server_seq, mobile_sql.ex:511-548).
NextSeq == MaxOf(Range(tl)) + 1

\* Channels.Companion.broadcast (channels/companion.ex:91-95, dispatch
\* :223-227): one send to every Connection registered under the profile.
Fanout(ev) == [c \in Clients |-> IF sub[c] = "yes" THEN Append(wire[c], ev) ELSE wire[c]]

\* Timeline.history_page -> mobile_sql history (timeline.ex:79,
\* mobile_sql.ex:184-198): one Repo call reads the rows after a, oldest
\* first, at most PageLimit of them, and the head; more follow while
\* next_after_seq is below history_head_seq.
PageAfter(a) ==
    LET later == SelectSeq(tl, LAMBDA s : s > a)
        k == IF Len(later) < PageLimit THEN Len(later) ELSE PageLimit
    IN [rows |-> SubSeq(later, 1, k), more |-> Len(later) > PageLimit]

\* history_pull on connection c (dispatch, connection.ex:192-193 ->
\* Requests.history, requests.ex:96-107): the Repo read, in the step the
\* client sends the pull; `w` is c's mailbox and socket as that step left
\* them. The page then goes to the Connection's own mailbox (emit -> sink,
\* connection.ex:425-428): in a later step (SendPage) when live rows may
\* overtake it, in this one otherwise. Without SubscribeBeforePull the
\* Connection joins the registry after its first page (Join).
Pull(c, w, a) ==
    /\ IF LiveRowsOvertakePage
       THEN wire' = [wire EXCEPT ![c] = w] /\ reading' = [reading EXCEPT ![c] = PageAfter(a)]
       ELSE wire' = [wire EXCEPT ![c] = Append(w, <<"page", PageAfter(a)>>)] /\ UNCHANGED reading
    /\ sub' = IF sub[c] = "no" THEN [sub EXCEPT ![c] = "joining"] ELSE sub

\* maybe_start_next_request (queue.ex:304-312), run by every Queue callback
\* that can free the slot or fill the queue: with the waiting turns p and the
\* turn states t that callback left, start the head of p if no turn is alive
\* (OneTurnAtATime), or at once without it.
StartNext(p, t) ==
    IF p /= <<>> /\ (OneTurnAtATime => \A x \in Msgs : t[x] \notin Live)
    THEN turn' = [t EXCEPT ![Head(p)] = "running"] /\ qpending' = Tail(p)
    ELSE turn' = t /\ qpending' = p

-----------------------------------------------------------------------------
(* The request path: a Connection's request worker (request_job,           *)
(* connection.ex:285-297) runs Companion.Requests.request                   *)

\* msg{client_msg_id} (Requests.request -> claim_and_run -> acquire_and_run
\* -> run_started -> ingest_span, requests.ex:74-258):
\*  - claim_client_request claims the id durably (claim_request_in_tx,
\*    mobile_sql.ex:722-741), and accepted{duplicate} goes to this client's
\*    Connection (accepted_event, requests.ex:523-526) before anything runs;
\*  - the coordinator's acquire starts an attempt, or none for a request
\*    running, completed or failed (request_coordinator.ex:118-125);
\*  - an attempt appends the user's row (append_client_message, keyed by
\*    client_msg_id: an existing row is returned, not written again). The
\*    row is not broadcast: other clients see it through history;
\*  - Gateway.ingest hands the turn to Companion.Turns.handle_message, which
\*    tracks it and casts it to the Queue (turns.ex:59-64, :130-144); the
\*    Queue's handle_cast is folded in, since nothing here tells them apart.
OnMsg(c, m) ==
    /\ dupWhileRunning' = (dupWhileRunning \/ (m \in accepted /\ turn[m] \in Live))
    /\ IF AcceptedDedupe /\ m \in accepted
       THEN /\ wire' = [wire EXCEPT ![c] = Append(@, <<"acc", m>>)]
            /\ UNCHANGED <<turns, queue, tl>>
       ELSE /\ accepted' = accepted \cup {m}
            /\ tl' = IF m \in accepted THEN tl ELSE Append(tl, NextSeq)
            /\ wire' = [wire EXCEPT ![c] = Append(@, <<"acc", m>>)]
            /\ handed' = [handed EXCEPT ![m] = @ + 1]
            /\ StartNext(Append(qpending, m), [turn EXCEPT ![m] = "queued"])
            /\ UNCHANGED <<ends, cancelAsked, turnsBox, appr, applied>>
    /\ UNCHANGED <<sub, reading, job, jobSeq, dseq, answeredBy>>

\* A set of at most one turn as a sequence. CHOOSE on a singleton is
\* deterministic, so symmetry stays sound; no check reaches two.
One(S) ==
    IF Cardinality(S) > 1 THEN Assert(FALSE, "two running turns stopped at once")
    ELSE IF S = {} THEN <<>> ELSE <<CHOOSE x \in S : TRUE>>

\* The Queue stops the turns in `hit`, in one callback: a running one is
\* killed and a waiting one dropped, and each {:cancelled} is invoked off the
\* Queue (invoke_turn_result_async) into Turns' mailbox, the running one
\* first. A claimed turn is never in `hit`: the stop spares it
\* (stop_named_in, queue.ex:1005-1013; stop_active_turn :1048-1050). A named
\* stop that kills the running turn starts the next one (:1015-1026); the
\* conversation stop leaves none waiting (cancel_pending :1068-1074).
StopTurns(hit) ==
    LET order == One({x \in hit : turn[x] /= "queued"})
                 \o SelectSeq(qpending, LAMBDA x : x \in hit)
    IN /\ StartNext(SelectSeq(qpending, LAMBDA x : x \notin hit),
                    [x \in Msgs |-> IF x \in hit THEN "ended" ELSE turn[x]])
       /\ turnsBox' = turnsBox \o [i \in 1..Len(order) |-> <<"cancelled", order[i]>>]

\* cancel{client_msg_id} (cancel, connection.ex:238-246): the Connection calls
\* Queue.stop_turn(key, client_msg_id) and writes nothing.
\*  - StopTurnNamesTurn: the named message's turn stops if a stop still
\*    reaches it, and nothing else does (stop_named_in, queue.ex:1005-1042).
\*  - Otherwise the conversation stop: whichever turn runs unclaimed is
\*    killed, and every waiting message cancelled.
\*  - Without OutcomeEndsTurn the Connection also writes turn_error{cancelled}
\*    at once, for a message it has not seen end.
OnCancel(m) ==
    LET open == m \in accepted /\ ends[m] = <<>>
        hit == IF StopTurnNamesTurn
               THEN IF turn[m] \in Stoppable THEN {m} ELSE {}
               ELSE {x \in Msgs : turn[x] \in Stoppable}
    IN /\ cancelAsked' = cancelAsked \cup {m}
       /\ ends' = IF ~OutcomeEndsTurn /\ open
                  THEN [ends EXCEPT ![m] = Append(@, "cancelled")] ELSE ends
       /\ StopTurns(hit)
       /\ UNCHANGED <<wire, sub, reading, accepted, appr, applied, handed, store, obs>>

\* /confirm TOKEN or /deny TOKEN: a command request through the same path,
\* answered by the Gateway's command (confirm, deny, sandbox.ex:223-243).
\* take_pending peeks, checks the expiry and origin, then takes the token
\* (sandbox.ex:397-414, Confirmations.take, confirmations.ex:21-26). Only a
\* take that finds the token applies the answer and broadcasts
\* approval_resolved (notify_approval :258-266 -> requests.ex:437-445).
\* Without SingleAnswer the token survives its first answer.
OnAnswer(c) ==
    /\ answeredBy' = answeredBy \cup {c}
    /\ IF appr = "pending"
       THEN /\ appr' = "resolved"
            /\ applied' = applied + 1
            /\ wire' = Fanout(<<"resolved", None>>)
       ELSE /\ applied' = IF appr = "resolved" /\ ~SingleAnswer THEN applied + 1 ELSE applied
            /\ UNCHANGED <<appr, wire>>
    /\ UNCHANGED <<sub, reading, accepted, ends, cancelAsked, turnsBox, queue, store,
                   dupWhileRunning>>

-----------------------------------------------------------------------------
(* The clients (PROTOCOL.md's client rules) and their Connections           *)

\* The user types m. With the outbox it is kept until accepted and goes out
\* now if the client is connected, or once it is (Flush). Without one, the
\* client can only send while connected, and sends once.
Compose(m) ==
    LET c == Owner(m) IN
    /\ m \notin composed
    /\ OutboxResend \/ link[c] = "up"
    /\ composed' = composed \cup {m}
    /\ outbox' = [outbox EXCEPT ![c] = @ \cup {m}]
    /\ IF link[c] = "up"
       THEN sentOn' = [sentOn EXCEPT ![c] = @ \cup {m}] /\ OnMsg(c, m)
       ELSE UNCHANGED <<sentOn, conn, turns, queue, store, obs>>
    /\ UNCHANGED <<link, view, pulling, prompt, resent, env>>

\* OutboxResend: after server_hello the client sends every outboxed message
\* it has not sent on this connection.
Flush(m) ==
    LET c == Owner(m) IN
    /\ OutboxResend
    /\ link[c] = "up" /\ m \in outbox[c] /\ m \notin sentOn[c]
    /\ sentOn' = [sentOn EXCEPT ![c] = @ \cup {m}]
    /\ OnMsg(c, m)
    /\ UNCHANGED <<link, composed, outbox, view, pulling, prompt, resent, env>>

\* The client sends again a message it sent on this connection and has no
\* accepted for yet: its ack timeout, or the user's retry. Once per message.
Resend(m) ==
    LET c == Owner(m) IN
    /\ MessagesCanBeResent
    /\ link[c] = "up" /\ m \in outbox[c] /\ m \in sentOn[c] /\ m \notin resent
    /\ resent' = resent \cup {m}
    /\ OnMsg(c, m)
    /\ UNCHANGED <<link, composed, outbox, sentOn, view, pulling, prompt, env>>

\* The client connects: the Endpoint starts its Connection and hands it the
\* socket (accept_connection, start_connection, hand_over, endpoint.ex:218-268;
\* @max_clients 4, two here). The client sends client_hello; the Connection
\* joins the registry (SubscribeBeforePull), then writes server_hello straight
\* to the socket (hello, join, connection.ex:205-221). A pending approval is
\* not re-sent.
Connect(c) ==
    /\ link[c] = "down"
    /\ link' = [link EXCEPT ![c] = "hello"]
    /\ sub' = IF SubscribeBeforePull THEN [sub EXCEPT ![c] = "yes"] ELSE sub
    /\ wire' = [wire EXCEPT ![c] = <<<<"hello_ok", None>>>>]
    /\ UNCHANGED <<composed, outbox, sentOn, view, pulling, prompt, resent, reading, turns,
                   queue, store, env, obs>>

\* The connection drops. The Connection exits (connection.ex:117-122) with its
\* mailbox and any page it had not sent; its registry entry goes with it. A
\* request worker it started runs on, since it is not linked, so a claimed
\* request still settles. The client keeps its outbox, its view, and any
\* approval card it shows.
Drop(c) ==
    /\ ClientsCanDisconnect /\ dropsLeft > 0 /\ link[c] /= "down"
    /\ dropsLeft' = dropsLeft - 1
    /\ link' = [link EXCEPT ![c] = "down"]
    /\ wire' = [wire EXCEPT ![c] = <<>>]
    /\ sub' = [sub EXCEPT ![c] = "no"]
    /\ reading' = [reading EXCEPT ![c] = None]
    /\ sentOn' = [sentOn EXCEPT ![c] = {}]
    /\ pulling' = [pulling EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<composed, outbox, view, prompt, resent, turns, queue, store, cancelsLeft,
                   obs>>

\* The user answers the approval card the client shows.
Answer(c) ==
    /\ prompt[c] /\ link[c] = "up"
    /\ prompt' = [prompt EXCEPT ![c] = FALSE]
    /\ OnAnswer(c)
    /\ UNCHANGED <<link, composed, outbox, sentOn, view, pulling, resent, env>>

\* A user cancels m's turn: any client may cancel any message of the shared
\* conversation.
Cancel(c, m) ==
    /\ TurnsCanBeCancelled /\ cancelsLeft > 0
    /\ link[c] = "up" /\ m \in composed
    /\ cancelsLeft' = cancelsLeft - 1
    /\ OnCancel(m)
    /\ UNCHANGED <<client, dropsLeft>>

\* server_hello: the client pulls after its cursor (SeqCursor).
OnServerHello(c, rest) ==
    /\ link' = [link EXCEPT ![c] = "up"]
    /\ pulling' = [pulling EXCEPT ![c] = SeqCursor]
    /\ IF SeqCursor THEN Pull(c, rest, Cursor(c))
       ELSE wire' = [wire EXCEPT ![c] = rest] /\ UNCHANGED <<sub, reading>>
    /\ UNCHANGED <<composed, outbox, sentOn, view, prompt, resent>>

\* A live text_done. With the cursor: the next seq is shown, one at or below
\* the cursor is dropped, and one past a gap is dropped and the gap pulled,
\* unless a pull is already out. Without: every row is shown as it comes.
OnRow(c, s, rest) ==
    /\ IF ~SeqCursor \/ s = Cursor(c) + 1
       THEN /\ view' = [view EXCEPT ![c] = Append(@, s)]
            /\ wire' = [wire EXCEPT ![c] = rest]
            /\ UNCHANGED <<pulling, sub, reading>>
       ELSE IF s <= Cursor(c) \/ pulling[c]
       THEN /\ wire' = [wire EXCEPT ![c] = rest]
            /\ UNCHANGED <<view, pulling, sub, reading>>
       ELSE /\ pulling' = [pulling EXCEPT ![c] = TRUE]
            /\ Pull(c, rest, Cursor(c))
            /\ UNCHANGED view
    /\ UNCHANGED <<link, composed, outbox, sentOn, prompt, resent>>

\* history_page: show the rows past the cursor (the page starts right after
\* the after_seq its pull named, and the cursor has not gone back since, so
\* they follow it with no gap), and pull again while the page says more.
OnPage(c, pg, rest) ==
    LET v == view[c] \o SelectSeq(pg.rows, LAMBDA s : s > Cursor(c))
        cur == IF v = <<>> THEN 0 ELSE v[Len(v)]
    IN /\ view' = [view EXCEPT ![c] = v]
       /\ IF pg.more
          THEN Pull(c, rest, cur) /\ UNCHANGED pulling
          ELSE /\ pulling' = [pulling EXCEPT ![c] = FALSE]
               /\ wire' = [wire EXCEPT ![c] = rest]
               /\ UNCHANGED <<sub, reading>>
       /\ UNCHANGED <<link, composed, outbox, prompt, resent, sentOn>>

\* The client reads the next event its Connection wrote.
ClientRead(c) ==
    /\ wire[c] /= <<>>
    /\ LET ev == Head(wire[c])
           rest == Tail(wire[c])
       IN CASE ev[1] = "hello_ok" -> OnServerHello(c, rest)
            [] ev[1] = "row" -> OnRow(c, ev[2], rest)
            [] ev[1] = "page" -> OnPage(c, ev[2], rest)
            [] ev[1] = "acc" ->
                 /\ outbox' = [outbox EXCEPT ![c] = @ \ {ev[2]}]
                 /\ wire' = [wire EXCEPT ![c] = rest]
                 /\ UNCHANGED <<link, composed, sentOn, view, pulling, prompt, resent, sub,
                                reading>>
            [] ev[1] \in {"appr", "resolved"} ->
                 /\ prompt' = [prompt EXCEPT ![c] = (ev[1] = "appr")]
                 /\ wire' = [wire EXCEPT ![c] = rest]
                 /\ UNCHANGED <<link, composed, outbox, sentOn, view, pulling, resent, sub,
                                reading>>
    /\ UNCHANGED <<turns, queue, store, env, obs>>

\* LiveRowsOvertakePage: the Connection sends the page it read to its own
\* mailbox (emit, requests.ex:604 -> sink, connection.ex:425-428), behind
\* whatever other processes sent it since the read.
SendPage(c) ==
    /\ reading[c] /= None
    /\ wire' = [wire EXCEPT ![c] = Append(@, <<"page", reading[c]>>)]
    /\ reading' = [reading EXCEPT ![c] = None]
    /\ UNCHANGED <<client, sub, turns, queue, store, env, obs>>

\* Without SubscribeBeforePull: the Connection joins the registry after it
\* answered the first pull, in a step of its own.
Join(c) ==
    /\ sub[c] = "joining"
    /\ sub' = [sub EXCEPT ![c] = "yes"]
    /\ UNCHANGED <<client, wire, reading, turns, queue, store, env, obs>>

-----------------------------------------------------------------------------
(* Companion.Turns: every turn ends on the wire here, from its outcome      *)

\* Turns handles its next outcome (outcome/2, handle_call, turns.ex:107-112
\* -> finish/3, :155-168):
\*  - {:completed}: each held reply is written as a row (Output.persist_text
\*    -> append_client_output, one Repo call) and broadcast as
\*    text_done{server_seq} (write_reply, turns.ex:174-191); one reply here;
\*  - {:cancelled}: the request is settled failed and one turn_error is
\*    broadcast (fail, turns.ex:164-168); turn_error is live-only.
TurnsNext ==
    /\ turnsBox /= <<>>
    /\ turnsBox' = Tail(turnsBox)
    /\ LET ev == Head(turnsBox) IN
       IF ev[1] = "completed"
       THEN /\ tl' = Append(tl, NextSeq)
            /\ wire' = Fanout(<<"row", NextSeq>>)
            /\ ends' = [ends EXCEPT ![ev[2]] = Append(@, "done")]
       ELSE /\ ends' = [ends EXCEPT ![ev[2]] = Append(@, "cancelled")]
            /\ UNCHANGED <<tl, wire>>
    /\ UNCHANGED <<client, sub, reading, accepted, cancelAsked, appr, applied, queue,
                   job, jobSeq, dseq, env, obs>>

-----------------------------------------------------------------------------
(* The Gateway Queue and its turn tasks, abstract (see the header)          *)

\* A tool of m's turn needs the owner's approval: the gateway stores a
\* pending token (store_pending_grant, sandbox.ex:178-190) and the channel
\* broadcasts the card (send_approval, channels/companion.ex:160-163). The
\* turn does not wait for it.
Ask(m) ==
    /\ turn[m] = "running" /\ appr = "none" /\ Approvals > 0
    /\ appr' = "pending"
    /\ wire' = Fanout(<<"appr", None>>)
    /\ UNCHANGED <<client, sub, reading, accepted, ends, cancelAsked, turnsBox, applied, queue,
                   store, env, obs>>

\* The token expires: take_pending refuses it from then on (validate_pending,
\* sandbox.ex:408-414). Time, so no fairness.
Expire ==
    /\ appr = "pending"
    /\ appr' = "expired"
    /\ UNCHANGED <<client, conn, accepted, ends, cancelAsked, turnsBox, applied, queue,
                   store, env, obs>>

\* m's turn committed its reply and claimed its outcome: from here a stop
\* spares it (claim_active_turn, queue.ex:1090-1094).
Claim(m) ==
    /\ turn[m] = "running"
    /\ turn' = [turn EXCEPT ![m] = "claimed"]
    /\ UNCHANGED <<client, conn, turns, qpending, handed, store, env, obs>>

\* The turn invokes {:completed} (Turns.outcome, a call into Turns' mailbox)
\* and exits; the Queue's :DOWN frees the slot and starts the next waiting
\* turn (folded in: nothing else can act on the dead turn in between).
Finish(m) ==
    /\ turn[m] = "claimed"
    /\ turnsBox' = Append(turnsBox, <<"completed", m>>)
    /\ StartNext(qpending, [turn EXCEPT ![m] = "ended"])
    /\ UNCHANGED <<client, conn, accepted, ends, cancelAsked, appr, applied, handed, store,
                   env, obs>>

-----------------------------------------------------------------------------
(* A scheduled job reporting back: Channels.Companion.send_message in the   *)
(* job's own process (channels/companion.ex:174-206)                        *)

\* Without SeqAssignedOnInsert the job reads the counter first.
JobRead ==
    /\ DeliveriesWhileOffline /\ ~SeqAssignedOnInsert /\ job = "idle"
    /\ job' = "read" /\ jobSeq' = MaxOf(Range(tl))
    /\ UNCHANGED <<client, conn, turns, queue, tl, dseq, env, obs>>

\* Output.persist_text -> Timeline.append: one Repo call (append_in_tx).
JobWrite ==
    /\ DeliveriesWhileOffline
    /\ job = IF SeqAssignedOnInsert THEN "idle" ELSE "read"
    /\ LET s == IF SeqAssignedOnInsert THEN NextSeq ELSE jobSeq + 1 IN
       /\ tl' = Append(tl, s)
       /\ dseq' = s
       /\ jobSeq' = s
    /\ job' = "written"
    /\ UNCHANGED <<client, conn, turns, queue, env, obs>>

\* announce_text: the job broadcasts its row as text_done (:201-206).
JobAnnounce ==
    /\ job = "written"
    /\ job' = "done"
    /\ wire' = Fanout(<<"row", jobSeq>>)
    /\ UNCHANGED <<client, sub, reading, turns, queue, tl, jobSeq, dseq, env, obs>>

-----------------------------------------------------------------------------
Init ==
    /\ link = [c \in Clients |-> "down"]
    /\ composed = {}
    /\ outbox = [c \in Clients |-> {}]
    /\ sentOn = [c \in Clients |-> {}]
    /\ view = [c \in Clients |-> <<>>]
    /\ pulling = [c \in Clients |-> FALSE]
    /\ prompt = [c \in Clients |-> FALSE]
    /\ resent = {}
    /\ wire = [c \in Clients |-> <<>>]
    /\ sub = [c \in Clients |-> "no"]
    /\ reading = [c \in Clients |-> None]
    /\ accepted = {}
    /\ ends = [m \in Msgs |-> <<>>]
    /\ cancelAsked = {}
    /\ turnsBox = <<>>
    /\ appr = "none" /\ applied = 0
    /\ qpending = <<>>
    /\ turn = [m \in Msgs |-> "none"]
    /\ handed = [m \in Msgs |-> 0]
    /\ tl = <<>> /\ job = "idle" /\ jobSeq = 0 /\ dseq = 0
    /\ dropsLeft = MaxDrops /\ cancelsLeft = MaxCancels
    /\ answeredBy = {} /\ dupWhileRunning = FALSE

\* The legitimate end: every client connected with nothing left to read, no
\* pull outstanding, no page unsent, no Connection about to join, Turns'
\* mailbox empty, no turn waiting or alive and no job half-way. Whether the
\* clients show the right rows then is for the rules to say. Deadlock
\* checking is on, so any other state where nothing can happen is reported
\* as a wedge.
Done ==
    /\ \A c \in Clients :
          /\ link[c] = "up" /\ wire[c] = <<>> /\ ~pulling[c]
          /\ reading[c] = None /\ sub[c] /= "joining"
    /\ turnsBox = <<>> /\ qpending = <<>>
    /\ \A m \in Msgs : turn[m] \notin Live
    /\ job \notin {"read", "written"}

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E m \in Msgs : Compose(m) \/ Flush(m) \/ Resend(m) \/ Ask(m) \/ Claim(m) \/ Finish(m)
    \/ \E c \in Clients :
          \/ Connect(c) \/ Drop(c) \/ Answer(c) \/ ClientRead(c) \/ SendPage(c) \/ Join(c)
          \/ \E m \in Msgs : Cancel(c, m)
    \/ TurnsNext \/ Expire \/ JobRead \/ JobWrite \/ JobAnnounce
    \/ Terminated

\* Fairness only on what Fermix drives: the clients' reconnect loop, their
\* reading of the socket and their outbox, the Connections, Turns, a running
\* turn, and the job's announcement once its row is written. None on users
\* (typing, answering, cancelling, retrying), on drops, on time, or on the
\* job reporting back.
Fairness ==
    /\ \A c \in Clients :
          /\ WF_vars(Connect(c)) /\ WF_vars(ClientRead(c))
          /\ WF_vars(SendPage(c)) /\ WF_vars(Join(c))
    /\ \A m \in Msgs : WF_vars(Flush(m)) /\ WF_vars(Claim(m)) /\ WF_vars(Finish(m))
    /\ WF_vars(TurnsNext) /\ WF_vars(JobAnnounce)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* PROTOCOL.md "Delivery and the outbox": a resend "is answered accepted with
\* duplicate: true and never runs the turn twice". Read as: no client_msg_id
\* is ever handed to the Queue twice.
RunAtMostOnce == \A m \in Msgs : handed[m] <= 1

\* PROTOCOL.md: msg is at-least-once from the companion, and accepted is the
\* point after which it stops resending. Read as: every message a user typed
\* is eventually acknowledged to the client that sent it.
AckAtLeastOnce ==
    \A m \in Msgs : (m \in composed) ~> (m \notin outbox[Owner(m)])

\* Client c has caught up and the conversation is at rest: c is connected
\* and joined, nothing is on its way to it, no pull or page is outstanding,
\* Turns has announced every outcome, no turn waits or runs, and no job row
\* waits for its announcement.
Quiet(c) ==
    /\ link[c] = "up" /\ sub[c] = "yes"
    /\ wire[c] = <<>> /\ ~pulling[c] /\ reading[c] = None
    /\ turnsBox = <<>> /\ qpending = <<>>
    /\ \A m \in Msgs : turn[m] \notin Live
    /\ job /= "written"

\* PROTOCOL.md "Keeping a client's timeline": no row "can fall between a page
\* and the live events", and a client that follows the rules shows the rows
\* in order. Read as: every client shows a gapless, duplicate-free prefix of
\* the timeline at all times, and all of it once it and the conversation are
\* at rest.
TimelineConverges ==
    \A c \in Clients :
        /\ Len(view[c]) <= Len(tl) /\ view[c] = SubSeq(tl, 1, Len(view[c]))
        /\ Quiet(c) => view[c] = tl

\* PROTOCOL.md "Streaming a turn": a turn ends on the wire exactly once, only
\* from its outcome. Read as: no text_done follows a turn_error{cancelled}
\* for the same turn.
NoDoneAfterCancel ==
    \A m \in Msgs : \A i, j \in 1..Len(ends[m]) :
        (i < j /\ ends[m][i] = "cancelled") => ends[m][j] /= "done"

\* take/1 is "the sole consume authority" (confirmations.ex:28-31). Read as:
\* at most one answer to an approval is ever applied, whoever sends it and
\* however late.
ApprovalAnsweredOnce == applied <= 1

\* PROTOCOL.md "One timeline with the phone": a job's result "is written
\* there whether or not a client is connected". Read as: every client
\* eventually shows the delivery row.
OfflineDeliveryArrives ==
    \A c \in Clients : (dseq /= 0) ~> (dseq \in Range(view[c]))

\* PROTOCOL.md: server_seq comes from "a per-profile counter that never goes
\* back ... no two rows share one".
SeqStrictlyIncreasing == \A i \in 1..Len(tl) - 1 : tl[i] < tl[i + 1]

\* queue.ex moduledoc: "Each conversation runs at most one active turn", as
\* the clients see it: the wire never streams two turns of the conversation.
OneTurnOnTheWire == Cardinality({m \in Msgs : turn[m] \in Live}) <= 1

\* PROTOCOL.md: cancel "never stops another turn" (turn_queue's rule of the
\* same name, on the Queue's outcomes). Read as: no turn is told cancelled
\* unless a cancel named its message.
OnlyNamedTurnCancelled ==
    \A m \in Msgs : "cancelled" \in Range(ends[m]) => m \in cancelAsked

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* Both clients' answers to the one approval reached the take.
Witness_ApprovalRace == ~(answeredBy = Clients)

\* A resend was claimed while its message's own turn was alive.
Witness_ResendWhileRunning == ~dupWhileRunning

\* Live rows reach a client out of seq order: a row is on its way behind a
\* row with a higher seq (the job's row announced after a later reply's).
Witness_LiveRowsOutOfOrder ==
    ~(\E c \in Clients : \E i, j \in 1..Len(wire[c]) :
        /\ i < j /\ wire[c][i][1] = "row" /\ wire[c][j][1] = "row"
        /\ wire[c][j][2] < wire[c][i][2])

\* A page and a live row carry the same row to one client.
Witness_PageOverlapsLive ==
    ~(\E c \in Clients : \E i, j \in 1..Len(wire[c]) :
        /\ wire[c][i][1] = "page" /\ wire[c][j][1] = "row"
        /\ wire[c][j][2] \in Range(wire[c][i][2].rows))

=============================================================================
