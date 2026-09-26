------------------------- MODULE CompanionSession -------------------------
(***************************************************************************)
(* The companion chat socket for ONE shared conversation: two clients on   *)
(* companion.sock, each with its own Companion.Connection, connecting and  *)
(* dropping at any time; the request path they share (Companion.Requests:  *)
(* the claim, accepted, the attempt fence, the user's row, ingest);        *)
(* Companion.Turns, which hands every turn to the Queue, sends every stop  *)
(* of it, and ends it on the wire from the Queue's outcome; the Gateway    *)
(* Queue; the timeline (FermixCore.Companion.Timeline, written through     *)
(* Memory.Repo); a job reporting back through                              *)
(* Channels.Companion.send_message; and one approval, answered by a        *)
(* /confirm or /deny command.                                              *)
(*                                                                         *)
(* The clients follow the rules FermixCore.Companion.Protocol exports in   *)
(* priv/companion/PROTOCOL.md ("Keeping a client's timeline", "Delivery    *)
(* and the outbox"): an outbox resent on every connection, and a seq       *)
(* cursor that applies a live row (a row or a text_done) at cursor + 1.    *)
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
(* mailbox, then the socket, in order (what it writes outside the step     *)
(* that produced it reaches it as {:companion_event, _},                   *)
(* connection.ex:123). A client event, the Connection's handling of it,    *)
(* and the request worker, Repo and Queue calls it makes are one step,     *)
(* up to the worker's call into Turns. Nothing distinct is lost: a client  *)
(* event lost in a drop looks to the client exactly like one whose answer  *)
(* was lost (it acts only on answers), and one delivered late is one sent  *)
(* late (users here cancel, answer or resend at any moment). Turns is its  *)
(* own process with one mailbox: hand-offs, cancels and the Queue's        *)
(* outcomes reach it in order.                                             *)
(*                                                                         *)
(* Not modelled:                                                           *)
(* - text_delta, tool_event, turn_started, read_state: live-only, never    *)
(* in the timeline; no rule reads them;                                    *)
(* - history_search and scroll-back (history_pull{before_seq}): reads      *)
(* below the cursor that never move it;                                    *)
(* - the phone: mobile and companion share the timeline but run under      *)
(* different channel identities, so live events never cross from one       *)
(* socket to the other; this spec is two clients on companion.sock;        *)
(* - a cancel that arrives before its request is claimed: there is no      *)
(* request to mark (cancel_request answers not_found), as PROTOCOL.md      *)
(* scopes the guarantee to a cancel after accepted;                        *)
(* - a failed turn ({:failed} ends it through the same path as             *)
(* {:cancelled}), a daemon restart and boot recovery (which hands a        *)
(* request off through the same Turns step, so it reads the mark), a       *)
(* Queue crash (Turns ends its turns as interrupted), a crash of Turns     *)
(* or of a request worker, and the grant resume a confirmed approval       *)
(* re-ingests as a new turn (sandbox.ex resume_request);                   *)
(* - the LLM and tools, the ConversationStore, attachments, auth and the   *)
(* socket's 0600 mode (single-call rules; ExUnit covers them);             *)
(* - other conversations (the Queue keys all state by conversation).       *)
(*                                                                         *)
(* One step = one callback of one process, one Memory.Repo call, or one    *)
(* thing a client or the environment does.                                 *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/priv/companion/PROTOCOL.md @ 78309c4a941e
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/requests.ex#request,cancel,claim_and_run,acquire_and_run,run_started,ingest_span,append_user,after_user_append,ingest_gateway,handoff_settlement,history,accepted_event,history_event,emit @ bd93219a8e98
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/turns.ex @ bfab37da7b1e
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/output.ex#text_done,turn_error,approval,approval_resolved,persist_text,persist_output @ b2b3eee7c5f7
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/connection.ex#handle_info,dispatch,hello,join,cancel,write_event,send_event,transport,announce_user_row,request_opts,read_opts,sink @ 5663000ca0a4
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/endpoint.ex#@max_clients,accept_connection,start_connection,hand_over @ 61148c849930
\* SOURCE: apps/fermix_channels/lib/fermix_channels/channels/companion.ex#broadcast,announce_row,row_event,dispatch,build_text_reply,build_turn_result,send_approval,send_message,announce_written,message @ 626b2ec6cd07
\* SOURCE: apps/fermix_core/lib/fermix_core/companion/timeline.ex#append_client_message,append_proactive,history_page,claim_client_request,get_client_request,cancel_client_request,start_client_request,append_client_output @ dc48c35b81e5
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/mobile_sql.ex#history,cancel_request,cancelled_request,append_in_tx,next_server_seq,increment_server_seq,claim_request_in_tx,classify_claim @ c0440ecb6aa0
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
                            \* shared conversation, whatever state its request is in
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
                         \* completed or failed (acquire_and_run, requests.ex:205-221)
    SeqCursor,           \* the client keeps the last server_seq it shows, pulls
                         \* history_pull{after_seq: cursor} after server_hello, while a
                         \* page says more and on a gap, and applies a live row only at
                         \* cursor + 1 (PROTOCOL.md "Keeping a client's timeline")
    SubscribeBeforePull, \* the Connection joins the registry before it writes
                         \* server_hello (join, connection.ex:211-220)
    PageWrittenInReadStep, \* the Connection writes history_page to the socket in the step
                         \* that read it (read_opts, connection.ex:446-450); FALSE sends it
                         \* through its own mailbox, behind live rows sent meanwhile
    AnnouncesEveryRow,   \* every row written outside a turn's completion is broadcast as
                         \* a row as it is written: the user's (announce_user_row,
                         \* connection.ex:434) and a delivery's (announce_written,
                         \* channels/companion.ex:236); FALSE announces no user row
    SingleAnswer,        \* an approval token is consumed once: Confirmations.take is
                         \* an :ets.take (confirmations.ex:21-26, take_pending
                         \* sandbox.ex:397-406)
    OneTurnAtATime,      \* the Queue starts a turn only when none of the conversation's
                         \* turns is alive (maybe_start_next_request, queue.ex:304-312)
    StopTurnNamesTurn,   \* a stop ends the named message's turn only (Queue.stop_turn,
                         \* queue.ex:172, stop_named_in :1005-1042); FALSE is the
                         \* conversation stop (stop_conversation_runtime :990-994)
    CancelMarksRequest,  \* a cancel is recorded on its request first (cancel_request,
                         \* mobile_sql.ex:373-401); Turns reads the mark and enqueues in
                         \* one step (hand_off, turns.ex:166-187) and sends every stop
                         \* itself, after its enqueue (turns.ex:117-129). FALSE is the
                         \* old code: the Connection calls Queue.stop_turn directly
    OutcomeEndsTurn,     \* a turn ends on the wire only from the Queue's outcome, in
                         \* Turns; the Connection's cancel writes nothing
                         \* (cancel, connection.ex:244-258; turns.ex:220-233)
    SeqAssignedOnInsert  \* server_seq comes from the per-profile counter inside the one
                         \* transactional Repo call that inserts the row (append_in_tx,
                         \* mobile_sql.ex:538-544); FALSE: a writer reads the counter,
                         \* then inserts in a second call

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
    reading,    \* reading[c]: a history page read and not yet sent through the
                \* mailbox (PageWrittenInReadStep off), or None
    \* the request path and Companion.Turns
    accepted,   \* claimed client_msg_ids (mobile_client_requests)
    marked,     \* requests carrying a cancel mark (cancelled_at)
    ends,       \* ends[m]: the endings written for m's turn, in order: "done"
                \* (text_done) or "cancelled" (turn_error)
    cancelAsked,\* messages a cancel reached the daemon for
    turnsBox,   \* Companion.Turns' mailbox: hand-offs, cancels, the Queue's outcomes
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
    \* observers (read only by rules and witnesses)
    answeredBy,     \* clients whose answer to the approval reached the take
    dupWhileRunning,\* a resend was claimed while its message's turn was alive
    cancelEarly     \* messages whose cancel arrived after their claim and before
                    \* their hand-off to the Queue

client   == <<link, composed, outbox, sentOn, view, pulling, prompt, resent>>
conn     == <<wire, sub, reading>>
turns    == <<accepted, marked, ends, cancelAsked, turnsBox, appr, applied>>
queue    == <<qpending, turn, handed>>
store    == <<tl, job, jobSeq, dseq>>
env      == <<dropsLeft, cancelsLeft>>
obs      == <<answeredBy, dupWhileRunning, cancelEarly>>
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
TurnsEvents == {"handoff", "cancel", "completed", "cancelled"} \X Msgs

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
    /\ accepted \subseteq Msgs /\ marked \subseteq Msgs
    /\ \A m \in Msgs : ends[m] \in Seq({"done", "cancelled"})
    /\ cancelAsked \subseteq Msgs
    /\ turnsBox \in Seq(TurnsEvents)
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
    /\ cancelEarly \subseteq Msgs

-----------------------------------------------------------------------------
(* Helpers *)

Range(s) == {s[i] : i \in 1..Len(s)}
MaxOf(S) == IF S = {} THEN 0 ELSE CHOOSE x \in S : \A y \in S : y <= x

\* The client's cursor: the last server_seq it shows.
Cursor(c) == IF view[c] = <<>> THEN 0 ELSE view[c][Len(view[c])]

\* The per-profile counter, read and bumped inside the insert's transaction
\* (next_server_seq, increment_server_seq, mobile_sql.ex:559-596).
NextSeq == MaxOf(Range(tl)) + 1

\* Channels.Companion.broadcast or announce_row (channels/companion.ex:92-110,
\* dispatch :254-258): one send to every Connection registered under the
\* profile. A row and a text_done are both a live row here.
FanoutTo(w, ev) == [c \in Clients |-> IF sub[c] = "yes" THEN Append(w[c], ev) ELSE w[c]]
Fanout(ev) == FanoutTo(wire, ev)

\* Timeline.history_page -> mobile_sql history (timeline.ex:79,
\* mobile_sql.ex:195): one Repo call reads the rows after a, oldest first, at
\* most PageLimit of them, and the head; more follow while next_after_seq is
\* below history_head_seq.
PageAfter(a) ==
    LET later == SelectSeq(tl, LAMBDA s : s > a)
        k == IF Len(later) < PageLimit THEN Len(later) ELSE PageLimit
    IN [rows |-> SubSeq(later, 1, k), more |-> Len(later) > PageLimit]

\* history_pull on connection c (dispatch, connection.ex:191 ->
\* Requests.history, requests.ex:97-108): the Repo read, in the step the
\* client sends the pull; `w` is c's mailbox and socket as that step left
\* them. With PageWrittenInReadStep the page is written to the socket in this
\* step (read_opts -> send_event, connection.ex:446-450, :387), ahead of any
\* live row sent after the read; without it, it goes through the mailbox in a
\* later step (SendPage). Without SubscribeBeforePull the Connection joins the
\* registry after its first page (Join).
Pull(c, w, a) ==
    /\ IF PageWrittenInReadStep
       THEN wire' = [wire EXCEPT ![c] = Append(w, <<"page", PageAfter(a)>>)] /\ UNCHANGED reading
       ELSE wire' = [wire EXCEPT ![c] = w] /\ reading' = [reading EXCEPT ![c] = PageAfter(a)]
    /\ sub' = IF sub[c] = "no" THEN [sub EXCEPT ![c] = "joining"] ELSE sub

\* maybe_start_next_request (queue.ex:304-312), run by every Queue callback
\* that can free the slot or fill the queue: with the waiting turns p and the
\* turn states t that callback left, start the head of p if no turn is alive
\* (OneTurnAtATime), or at once without it.
StartNext(p, t) ==
    IF p /= <<>> /\ (OneTurnAtATime => \A x \in Msgs : t[x] \notin Live)
    THEN turn' = [t EXCEPT ![Head(p)] = "running"] /\ qpending' = Tail(p)
    ELSE turn' = t /\ qpending' = p

\* A set of at most one turn as a sequence. CHOOSE on a singleton is
\* deterministic, so symmetry stays sound; no check reaches two.
One(S) ==
    IF Cardinality(S) > 1 THEN Assert(FALSE, "two running turns stopped at once")
    ELSE IF S = {} THEN <<>> ELSE <<CHOOSE x \in S : TRUE>>

\* Queue.stop_turn for m, in one Queue callback: the turns in `hit` stop (a
\* running one killed, a waiting one dropped), and each {:cancelled} is
\* invoked off the Queue (invoke_turn_result_async) into Turns' mailbox,
\* after `box`, the running one first. A claimed turn is never in `hit`: the
\* stop spares it (stop_named_in, queue.ex:1005-1013). A named stop that
\* kills the running turn starts the next one (:1015-1026). Without
\* StopTurnNamesTurn it is the conversation stop: whatever runs unclaimed is
\* killed and every waiting message cancelled (:990-994, cancel_pending
\* :1068-1074).
StopTurn(m, box) ==
    LET hit == IF StopTurnNamesTurn
               THEN IF turn[m] \in Stoppable THEN {m} ELSE {}
               ELSE {x \in Msgs : turn[x] \in Stoppable}
        order == One({x \in hit : turn[x] /= "queued"})
                 \o SelectSeq(qpending, LAMBDA x : x \in hit)
    IN /\ StartNext(SelectSeq(qpending, LAMBDA x : x \notin hit),
                    [x \in Msgs |-> IF x \in hit THEN "ended" ELSE turn[x]])
       /\ turnsBox' = box \o [i \in 1..Len(order) |-> <<"cancelled", order[i]>>]

-----------------------------------------------------------------------------
(* The request path: a Connection's request worker (request_job,           *)
(* connection.ex:297) runs Companion.Requests.request                       *)

\* msg{client_msg_id} (Requests.request -> claim_and_run -> acquire_and_run
\* -> run_started -> ingest_span, requests.ex:75-270):
\*  - claim_client_request claims the id durably (claim_request_in_tx,
\*    mobile_sql.ex:770-789), and accepted{duplicate} goes to this client's
\*    Connection (accepted_event, requests.ex:535) before anything runs;
\*  - the coordinator's acquire starts an attempt, or none for a request
\*    running, completed or failed (request_coordinator.ex:118-125);
\*  - an attempt appends the user's row (append_client_message, keyed by
\*    client_msg_id: an existing row is returned, not written again), and a
\*    row it created is announced to every connection (after_user_append ->
\*    announce_user_row, requests.ex:356, connection.ex:434);
\*  - Gateway.ingest calls Companion.Turns.handle_message: the hand-off waits
\*    in Turns' mailbox (turns.ex:69-71).
OnMsg(c, m) ==
    /\ dupWhileRunning' = (dupWhileRunning \/ (m \in accepted /\ turn[m] \in Live))
    /\ IF AcceptedDedupe /\ m \in accepted
       THEN /\ wire' = [wire EXCEPT ![c] = Append(@, <<"acc", m>>)]
            /\ UNCHANGED <<turns, tl>>
       ELSE LET s == NextSeq
                created == m \notin accepted
                w1 == [wire EXCEPT ![c] = Append(@, <<"acc", m>>)]
            IN /\ accepted' = accepted \cup {m}
               /\ tl' = IF created THEN Append(tl, s) ELSE tl
               /\ wire' = IF created /\ AnnouncesEveryRow THEN FanoutTo(w1, <<"row", s>>) ELSE w1
               /\ turnsBox' = Append(turnsBox, <<"handoff", m>>)
               /\ UNCHANGED <<marked, ends, cancelAsked, appr, applied>>
    /\ UNCHANGED <<sub, reading, queue, job, jobSeq, dseq, answeredBy, cancelEarly>>

\* cancel{client_msg_id} (cancel, connection.ex:244-258).
\*  - CancelMarksRequest: Requests.cancel records the mark on a request that
\*    has not settled, in one Repo call (cancel_request, mobile_sql.ex:373-401;
\*    not_found for one never claimed), then asks Turns (Turns.cancel, a call
\*    into its mailbox, turns.ex:79-82).
\*  - Otherwise the old code: the Connection calls Queue.stop_turn itself,
\*    which finds nothing for a request not yet handed off.
\*  - Without OutcomeEndsTurn the Connection also writes turn_error{cancelled}
\*    at once, for a message it has not seen end.
OnCancel(m) ==
    LET open == m \in accepted /\ ends[m] = <<>>
    IN /\ cancelAsked' = cancelAsked \cup {m}
       /\ cancelEarly' = IF open /\ turn[m] = "none" THEN cancelEarly \cup {m} ELSE cancelEarly
       /\ ends' = IF ~OutcomeEndsTurn /\ open
                  THEN [ends EXCEPT ![m] = Append(@, "cancelled")] ELSE ends
       /\ IF CancelMarksRequest
          THEN /\ marked' = IF open THEN marked \cup {m} ELSE marked
               /\ turnsBox' = IF open THEN Append(turnsBox, <<"cancel", m>>) ELSE turnsBox
               /\ UNCHANGED queue
          ELSE /\ StopTurn(m, turnsBox)
               /\ UNCHANGED <<marked, handed>>
       /\ UNCHANGED <<wire, sub, reading, accepted, appr, applied, store, answeredBy,
                      dupWhileRunning>>

\* /confirm TOKEN or /deny TOKEN: a command request through the same path,
\* answered by the Gateway's command (confirm, deny, sandbox.ex:223-243).
\* take_pending peeks, checks the expiry and origin, then takes the token
\* (sandbox.ex:397-414, Confirmations.take, confirmations.ex:21-26). Only a
\* take that finds the token applies the answer and broadcasts
\* approval_resolved (notify_approval :258-266 -> requests.ex:449-457).
\* Without SingleAnswer the token survives its first answer.
OnAnswer(c) ==
    /\ answeredBy' = answeredBy \cup {c}
    /\ IF appr = "pending"
       THEN /\ appr' = "resolved"
            /\ applied' = applied + 1
            /\ wire' = Fanout(<<"resolved", None>>)
       ELSE /\ applied' = IF appr = "resolved" /\ ~SingleAnswer THEN applied + 1 ELSE applied
            /\ UNCHANGED <<appr, wire>>
    /\ UNCHANGED <<sub, reading, accepted, marked, ends, cancelAsked, turnsBox, queue, store,
                   dupWhileRunning, cancelEarly>>

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
\* to the socket (hello, join, connection.ex:204-220). A pending approval is
\* not re-sent.
Connect(c) ==
    /\ link[c] = "down"
    /\ link' = [link EXCEPT ![c] = "hello"]
    /\ sub' = IF SubscribeBeforePull THEN [sub EXCEPT ![c] = "yes"] ELSE sub
    /\ wire' = [wire EXCEPT ![c] = <<<<"hello_ok", None>>>>]
    /\ UNCHANGED <<composed, outbox, sentOn, view, pulling, prompt, resent, reading, turns,
                   queue, store, env, obs>>

\* The connection drops. The Connection exits (connection.ex:116) with its
\* mailbox; its registry entry goes with it. A request worker it started runs
\* on, since it is not linked, so a claimed request still settles. The client
\* keeps its outbox, its view, and any approval card it shows.
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

\* A user cancels m: any client may cancel any message of the shared
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

\* A live row (a row or a text_done). With the cursor: applied at cursor + 1,
\* dropped at or below it, and dropped past a gap with the gap pulled, unless
\* a pull is already out. Without: every row is shown as it comes.
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

\* Without PageWrittenInReadStep: the Connection sends the page it read to
\* its own mailbox, behind whatever other processes sent it since the read.
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
(* Companion.Turns: one process, one mailbox                                *)

\* Turns handles its next message:
\*  - a hand-off (handle_call {:hand_off, ...}, turns.ex:108-113 -> hand_off
\*    :166-178): with CancelMarksRequest it reads the request's mark
\*    (cancel_recorded, get_client_request, :181-187) and, in the same step,
\*    fails a marked request with one turn_error{cancelled} (fail, :229-233),
\*    never enqueued; otherwise it tracks the turn and enqueues it
\*    (Queue.handle_message; the Queue's handle_cast is folded in);
\*  - a cancel (handle_call {:cancel, ...}, :117-129): Queue.stop_turn for a
\*    turn it handed off, sent after its own enqueue, so it cannot overtake it;
\*    for any other, the stop finds nothing;
\*  - {:completed} (outcome/2, :140-145 -> finish/3, :220-227): each held
\*    reply is written as a row (one Repo call) and broadcast as
\*    text_done{server_seq} (write_reply, :239-256); one reply here;
\*  - {:cancelled}: the request is settled failed and one turn_error is
\*    broadcast (fail, :229-233); turn_error is live-only.
TurnsNext ==
    /\ turnsBox /= <<>>
    /\ LET ev == Head(turnsBox)
           m == ev[2]
           rest == Tail(turnsBox)
       IN CASE ev[1] = "handoff" ->
                 IF CancelMarksRequest /\ m \in marked
                 THEN /\ turnsBox' = rest
                      /\ ends' = [ends EXCEPT ![m] = Append(@, "cancelled")]
                      /\ turn' = [turn EXCEPT ![m] = "ended"]
                      /\ UNCHANGED <<qpending, handed>>
                 ELSE /\ turnsBox' = rest
                      /\ handed' = [handed EXCEPT ![m] = @ + 1]
                      /\ StartNext(Append(qpending, m), [turn EXCEPT ![m] = "queued"])
                      /\ UNCHANGED ends
            [] ev[1] = "cancel" ->
                 /\ StopTurn(m, rest)
                 /\ UNCHANGED <<ends, handed>>
            [] ev[1] = "completed" ->
                 /\ turnsBox' = rest
                 /\ ends' = [ends EXCEPT ![m] = Append(@, "done")]
                 /\ UNCHANGED queue
            [] ev[1] = "cancelled" ->
                 /\ turnsBox' = rest
                 /\ ends' = [ends EXCEPT ![m] = Append(@, "cancelled")]
                 /\ UNCHANGED queue
    /\ LET ev == Head(turnsBox) IN
       IF ev[1] = "completed"
       THEN tl' = Append(tl, NextSeq) /\ wire' = Fanout(<<"row", NextSeq>>)
       ELSE UNCHANGED <<tl, wire>>
    /\ UNCHANGED <<client, sub, reading, accepted, marked, cancelAsked, appr, applied,
                   job, jobSeq, dseq, env, obs>>

-----------------------------------------------------------------------------
(* The Gateway Queue and its turn tasks, abstract (see the header)          *)

\* A tool of m's turn needs the owner's approval: the gateway stores a
\* pending token (store_pending_grant, sandbox.ex:178-190) and the channel
\* broadcasts the card (send_approval, channels/companion.ex:192-195). The
\* turn does not wait for it.
Ask(m) ==
    /\ turn[m] = "running" /\ appr = "none" /\ Approvals > 0
    /\ appr' = "pending"
    /\ wire' = Fanout(<<"appr", None>>)
    /\ UNCHANGED <<client, sub, reading, accepted, marked, ends, cancelAsked, turnsBox,
                   applied, queue, store, env, obs>>

\* The token expires: take_pending refuses it from then on (validate_pending,
\* sandbox.ex:408-414). Time, so no fairness.
Expire ==
    /\ appr = "pending"
    /\ appr' = "expired"
    /\ UNCHANGED <<client, conn, accepted, marked, ends, cancelAsked, turnsBox, applied, queue,
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
    /\ UNCHANGED <<client, conn, accepted, marked, ends, cancelAsked, appr, applied, handed,
                   store, env, obs>>

-----------------------------------------------------------------------------
(* A scheduled job reporting back: Channels.Companion.send_message in the   *)
(* job's own process (channels/companion.ex:206-237)                        *)

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

\* announce_written -> announce_row: the job broadcasts its row (:236).
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
    /\ accepted = {} /\ marked = {}
    /\ ends = [m \in Msgs |-> <<>>]
    /\ cancelAsked = {}
    /\ turnsBox = <<>>
    /\ appr = "none" /\ applied = 0
    /\ qpending = <<>>
    /\ turn = [m \in Msgs |-> "none"]
    /\ handed = [m \in Msgs |-> 0]
    /\ tl = <<>> /\ job = "idle" /\ jobSeq = 0 /\ dseq = 0
    /\ dropsLeft = MaxDrops /\ cancelsLeft = MaxCancels
    /\ answeredBy = {} /\ dupWhileRunning = FALSE /\ cancelEarly = {}

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
\* Turns' mailbox is empty, no turn waits or runs, and no job row waits for
\* its announcement.
Quiet(c) ==
    /\ link[c] = "up" /\ sub[c] = "yes"
    /\ wire[c] = <<>> /\ ~pulling[c] /\ reading[c] = None
    /\ turnsBox = <<>> /\ qpending = <<>>
    /\ \A m \in Msgs : turn[m] \notin Live
    /\ job /= "written"

\* PROTOCOL.md "Keeping a client's timeline": "no row can fall between a page
\* and the live events", every row is announced live, and a client that
\* follows the rules shows the rows in order. Read as: every client shows a
\* gapless, duplicate-free prefix of the timeline at all times, and all of it
\* once it and the conversation are at rest.
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

\* PROTOCOL.md: a cancel "that arrives after accepted but before the request
\* has reached the turn queue is not lost: the request is never queued".
\* Read as: a message whose cancel arrived after its claim and before its
\* hand-off never runs and is never answered.
CancelledRequestNeverRuns ==
    \A m \in cancelEarly : turn[m] \notin Live /\ "done" \notin Range(ends[m])

\* take/1 is "the sole consume authority" (confirmations.ex:28-31). Read as:
\* at most one answer to an approval is ever applied, whoever sends it and
\* however late.
ApprovalAnsweredOnce == applied <= 1

\* PROTOCOL.md "One timeline with the phone": a job's result is "written
\* whether or not a client is connected". Read as: every client eventually
\* shows the delivery row.
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
\* row with a higher seq (the job's row announced after a later one).
Witness_LiveRowsOutOfOrder ==
    ~(\E c \in Clients : \E i, j \in 1..Len(wire[c]) :
        /\ i < j /\ wire[c][i][1] = "row" /\ wire[c][j][1] = "row"
        /\ wire[c][j][2] < wire[c][i][2])

\* A page and a live row carry the same row to one client.
Witness_PageOverlapsLive ==
    ~(\E c \in Clients : \E i, j \in 1..Len(wire[c]) :
        /\ wire[c][i][1] = "page" /\ wire[c][j][1] = "row"
        /\ wire[c][j][2] \in Range(wire[c][i][2].rows))

\* A cancel reaches a request after its claim and before its hand-off.
Witness_CancelBeforeHandOff == cancelEarly = {}

=============================================================================
