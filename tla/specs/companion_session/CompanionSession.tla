------------------------- MODULE CompanionSession -------------------------
(***************************************************************************)
(* The companion chat socket for ONE shared conversation: two clients on   *)
(* companion.sock, each with its own Companion.Connection, connecting and  *)
(* dropping at any time; the request path the two transports share         *)
(* (Companion.Requests: the claim, accepted, the attempt fence, the user's *)
(* row, ingest, and the settlement once ingest returned); Companion.Turns, *)
(* the settlement owner of both transports, which hands every turn to the  *)
(* Queue, sends every stop of it, ends it on the wire from the Queue's     *)
(* outcome, and settles a request the gateway answered without a turn; the *)
(* Gateway Queue; the timeline (FermixCore.Companion.Timeline, written     *)
(* through Memory.Repo); a job reporting back through                      *)
(* Channels.Companion.send_message; and one approval, kept by              *)
(* Companion.Approvals until it resolves or expires and answered by a      *)
(* /confirm or /deny command.                                              *)
(*                                                                         *)
(* The clients follow the rules FermixCore.Companion.Protocol exports in   *)
(* priv/companion/PROTOCOL.md ("Keeping a client's timeline", "Delivery    *)
(* and the outbox", "Approvals"): an outbox resent on every connection; a  *)
(* seq cursor that applies a live row (a row or a text_done) only at       *)
(* cursor + 1; and every approval card it shows dropped when server_hello  *)
(* arrives, so that only the cards sent after it stay.                     *)
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
(* connection.ex:147-148). A client event, the Connection's handling of    *)
(* it, and the request worker, Repo and Queue calls it makes are one step, *)
(* up to the worker's casts into Turns (the hand-off during ingest, the    *)
(* settlement once ingest returned). Nothing distinct is lost: a client    *)
(* event lost in a drop looks to the client exactly like one whose answer  *)
(* was lost (it acts only on answers), and one delivered late is one sent  *)
(* late (users here cancel, answer or resend at any moment). Turns is its  *)
(* own process with one mailbox: hand-offs, settlements, cancels and the   *)
(* Queue's outcomes reach it in order, and a worker's two casts reach it   *)
(* in the order the worker sent them.                                      *)
(*                                                                         *)
(* Not modelled:                                                           *)
(* - text_delta, tool_event, turn_started, read_state: live-only, never in *)
(* the timeline; no rule reads them (read_state is a frontier the daemon   *)
(* caps at the newest row and announces to every watcher, the phones       *)
(* included);                                                              *)
(* - history_search and scroll-back (history_pull{before_seq}): reads      *)
(* below the cursor that never move it;                                    *)
(* - the phone: it shares this timeline, and its rows and read_state reach *)
(* this socket through Companion.Fanout, each wire in its own shape (a row *)
(* is built once, by Output.row), as this socket's reach the phones (a     *)
(* turn's reply as a row); a turn's stream and ending, and an approval,    *)
(* stay on the transport that raised them. A phone's row reaches this      *)
(* spec's clients as the job's row does; this spec is two clients on       *)
(* companion.sock. A phone's revocation is not modelled either: Turns runs *)
(* it in its own mailbox as a cancel of every unsettled request the device *)
(* claimed, one step that marks them all and stops each turn it handed off *)
(* (handle_cast {:revoke_device}, turns.ex:270-282);                       *)
(* - a cancel that arrives before its request is claimed: there is no      *)
(* request to mark (cancel_request answers not_found), as PROTOCOL.md      *)
(* scopes the guarantee to a cancel after accepted;                        *)
(* - a failed turn ({:failed} ends it through the same path as             *)
(* {:cancelled}), a daemon restart and boot recovery (which hands a        *)
(* request off through the same Turns step, so it reads the mark), a Queue *)
(* crash (Turns ends its turns as interrupted, and a stop that finds its   *)
(* Queue gone, dead already or dying in the stop, is left to that :DOWN),  *)
(* a hand-off Turns cannot complete (a mark it cannot read, a Queue        *)
(* already gone), which ends like a marked one, a store call inside Turns  *)
(* that exits, which Turns logs as that request's error while the turn     *)
(* still ends once (guarded/3), and a raise in Turns' own code or store    *)
(* calls, which crashes it to its supervisor; a request worker's crash;    *)
(* and the grant resume a confirmed approval re-ingests as a new turn      *)
(* (sandbox.ex resume_request);                                            *)
(* - a slash command's answer, which Turns writes and announces as a row   *)
(* (write_untracked) as the job's row is: only the command's settlement is *)
(* modelled, and the write that fails a request whose completion failed    *)
(* never fails itself (with the store down for both, the request stays     *)
(* running for the next boot). A command that answers later (/background,  *)
(* a /skills review or approval) defers its request, which settles when    *)
(* the command reports;                                                    *)
(* - the peer check at the hand-over (handle_info(:socket_handover),       *)
(* connection.ex:120-127): a client the daemon cannot place is sent        *)
(* error{unidentified_client} and closed before a line is read, which it   *)
(* sees as a drop before server_hello; the caller it places rides on each  *)
(* turn (metadata.caller) and decides only what the turn's tools may do;   *)
(* - the LLM and tools, the ConversationStore, attachments, auth and the   *)
(* socket's 0600 mode (single-call rules; ExUnit covers them);             *)
(* - other conversations (the Queue keys all state by conversation).       *)
(*                                                                         *)
(* One step = one callback of one process, one Memory.Repo call, or one    *)
(* thing a client or the environment does.                                 *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/priv/companion/PROTOCOL.md @ e1dddc1df7d3
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/requests.ex#request,cancel,claim_and_run,acquire_and_run,run_started,ingest_span,settle_after_ingest,settle_unless_handed_off,handoff_settlement,fail_attempt,report_failure,settle_failed,append_user,after_user_append,settle_inline,ingest_gateway,approval_resolution_fn,history,fit_page,cut_page,take_within,accepted_event,history_event,emit,best_effort_emit @ bd93219a8e98
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/turns.ex @ 47825aba960e
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/output.ex#text_done,turn_error,row,timeline_message,approval,approval_resolved,persist_text,persist_output,complete_request,fail_request @ b2b3eee7c5f7
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/connection.ex#handle_info,dispatch,hello,join,send_pending_approvals,write_pending_approval,write_event,send_event,transport,request_failure_reporter,announce_user_row,request_opts,read_opts,sink @ dbb6c34b6a55
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/fanout.ex
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/approvals.ex
\* SOURCE: apps/fermix_channels/lib/fermix_channels/companion/endpoint.ex#@max_clients,accept_connection,start_connection,hand_over @ 61148c849930
\* SOURCE: apps/fermix_channels/lib/fermix_channels/channels/companion.ex#broadcast,dispatch,build_text_reply,build_turn_result,send_approval,send_message,announce_written,message @ afb2f200897c
\* SOURCE: apps/fermix_core/lib/fermix_core/companion/timeline.ex#append_client_message,append_proactive,history_page,claim_client_request,get_client_request,cancel_client_request,start_client_request,append_client_output,complete_client_request,fail_client_request @ dc48c35b81e5
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/repo/mobile_sql.ex#history,cancel_request,cancelled_request,append_in_tx,next_server_seq,increment_server_seq,claim_request_in_tx,classify_claim,complete_request,settle_request_in_tx,request_transition,append_client_output_in_tx,ensure_running_attempt @ c0440ecb6aa0
\* SOURCE: apps/fermix_channels/lib/fermix_channels/mobile/request_coordinator.ex#handle_call @ b9579b8e9e13
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/queue.ex#stop_turn,stop_named_turn,stop_named_in,maybe_start_next_request,claim_active_turn,stop_conversation_runtime,stop_active_turn,cancel_pending @ 0dc22aada1ac
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/commands/sandbox.ex#store_pending_grant,confirm,deny,notify_approval,take_pending,validate_pending @ f399896eeb20
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/commands/sandbox/confirmations.ex @ 7f77c69d0c1a
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Clients,        \* the clients on the conversation, e.g. {c1, c2}
    Senders,        \* the clients whose users type, a subset of Clients
    InlineSenders,  \* the senders whose messages are slash commands the gateway answers
                    \* without a turn (/help, /status), a subset of Senders
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
    PagesCanBeCut,          \* rows are long enough that a history_page is cut to fewer
                            \* rows than its limit, at least one, to fit its byte budget
    SettlesCanFail,         \* the settlement of a request answered without a turn fails:
                            \* its completion write returns an error or exits, or the
                            \* request path's settle code raises
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off only by the checks that show a rule needs it.
    OutboxResend,        \* the client keeps every typed message until accepted and sends
                         \* it again on every new connection (PROTOCOL.md "Delivery and
                         \* the outbox")
    AcceptedDedupe,      \* a known client_msg_id is claimed as a duplicate
                         \* (claim_request_in_tx, classify_claim) and the request
                         \* coordinator starts no second attempt of a request running,
                         \* completed or failed (acquire_and_run, requests.ex:216-232)
    SeqCursor,           \* the client keeps the last server_seq it shows, pulls
                         \* history_pull{after_seq: cursor} after server_hello, while a
                         \* page says more and on a gap, and applies a live row only at
                         \* cursor + 1 (PROTOCOL.md "Keeping a client's timeline")
    SubscribeBeforePull, \* the Connection joins the registry before it writes
                         \* server_hello (join, connection.ex:252-262)
    PageWrittenInReadStep, \* the Connection writes history_page to the socket in the step
                         \* that read it (read_opts, connection.ex:520-524); FALSE sends it
                         \* through its own mailbox, behind live rows sent meanwhile
    AnnouncesEveryRow,   \* every row written outside a turn's completion is announced as
                         \* a row as it is written: the user's (announce_user_row,
                         \* connection.ex:508-509) and a delivery's (announce_written,
                         \* channels/companion.ex:225-226), both built by Output.row and
                         \* sent through Fanout.announce; FALSE announces no user row
    SingleAnswer,        \* an approval token is consumed once: Confirmations.take is
                         \* an :ets.take (confirmations.ex:21-26, take_pending
                         \* sandbox.ex:521-530)
    ResendsPendingApprovals, \* the Connection writes every card still waiting right
                         \* after server_hello, in the step that joined the registry
                         \* (join, send_pending_approvals, connection.ex:252-277, from
                         \* Approvals.pending, approvals.ex:112-115); FALSE: a card goes
                         \* out once, live
    DropsCardsAtHello,   \* when server_hello arrives the client drops every approval card
                         \* it shows and keeps only those sent after it (PROTOCOL.md
                         \* "Approvals"); FALSE keeps a card across a drop until an
                         \* approval_resolved reaches it
    OneTurnAtATime,      \* the Queue starts a turn only when none of the conversation's
                         \* turns is alive (maybe_start_next_request, queue.ex:317-325)
    StopTurnNamesTurn,   \* a stop ends the named message's turn only (Queue.stop_turn,
                         \* queue.ex:185, stop_named_in :1035-1072); FALSE is the
                         \* conversation stop (stop_conversation_runtime :1020-1024)
    CancelMarksRequest,  \* a cancel is recorded on its request first (Requests.cancel,
                         \* requests.ex:148-158; cancel_request, mobile_sql.ex:546-565);
                         \* Turns reads the mark and enqueues in one step (hand_off,
                         \* turns.ex:302-315) and sends every stop itself, after its
                         \* enqueue (turns.ex:226-229, stop_in_queue :416-427). FALSE is
                         \* the old code: the Connection calls Queue.stop_turn directly
    OutcomeEndsTurn,     \* a turn ends on the wire only from the Queue's outcome, in
                         \* Turns; the cancel writes nothing (Requests.cancel,
                         \* requests.ex:148-158; finish, fail, turns.ex:432-445)
    SettleAfterIngest,   \* once ingest returned, the request worker casts the request's
                         \* settlement to Turns (settle_after_ingest,
                         \* requests.ex:288-292); FALSE is the code before: a message the
                         \* gateway answered without a turn stayed running, and the next
                         \* boot ran it again
    SettleUnlessHandedOff, \* Turns settles that request only if no turn was handed off
                         \* for it (handle_cast {:settle_unless_handed_off},
                         \* turns.ex:262-268); FALSE completes it regardless, as the code
                         \* before did for every command, so a command that became a turn
                         \* (/ultra) had its reply refused
    FailsUnsettled,      \* a settlement that fails fails the request once for its attempt
                         \* and tells its client error{request_failed, client_msg_id}
                         \* (settle_inline, run_settle, turns.ex:334-369; fail_attempt,
                         \* report_failure, requests.ex:325-345, through the
                         \* transport's report_failure, which the Connection writes as
                         \* a failed worker's error, connection.ex:496-503,
                         \* :153-154); FALSE only logs
                         \* the failure: the request stays running, and the next boot
                         \* runs the command again
    SeqAssignedOnInsert  \* server_seq comes from the per-profile counter inside the one
                         \* transactional Repo call that inserts the row (append_in_tx,
                         \* mobile_sql.ex:737-743); FALSE: a writer reads the counter,
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
    turnsBox,   \* Companion.Turns' mailbox: hand-offs, settlements, cancels, outcomes
    appr,       \* the approval token and its card: "none", "pending", "resolved",
                \* "expired"
    applied,    \* answers applied to it
    \* each request's settlement
    settled,    \* requests settled (completed or failed) in mobile_client_requests
    known,      \* requests Turns took a hand-off for: tracked, or ended by it
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
    cancelEarly,    \* messages whose cancel arrived after their claim and before
                    \* their hand-off to the Queue
    refused,        \* messages whose turn completed after their request was settled,
                    \* so its reply was refused as a stale attempt
    told            \* messages whose settlement failed, so their request was failed and
                    \* the client that sent it was told error{request_failed}

client   == <<link, composed, outbox, sentOn, view, pulling, prompt, resent>>
conn     == <<wire, sub, reading>>
turns    == <<accepted, marked, ends, cancelAsked, turnsBox, appr, applied>>
reqs     == <<settled, known>>
queue    == <<qpending, turn, handed>>
store    == <<tl, job, jobSeq, dseq>>
env      == <<dropsLeft, cancelsLeft>>
obs      == <<answeredBy, dupWhileRunning, cancelEarly, refused, told>>
vars == <<client, conn, turns, reqs, queue, store, env, obs>>

Msgs == Senders \X (1..MsgsPerSender)
Owner(m) == m[1]

\* A slash command the gateway answers without a turn: its request is never
\* handed to the Queue.
Inline == {m \in Msgs : Owner(m) \in InlineSenders}

\* Clients that play the same part are interchangeable: invariant checks may
\* reduce by symmetry. A check whose senders play different parts (a slash
\* command beside a message) declares none.
Symm == IF Senders = Clients THEN Permutations(Clients) ELSE Permutations(Clients \ Senders)

Live == {"running", "claimed"}          \* a turn task is alive
Stoppable == {"queued", "running"}      \* a stop still reaches it

Page == [rows : Seq(Nat), more : BOOLEAN]
DownEvents ==
    ({"hello_ok", "appr", "resolved"} \X {None}) \cup ({"acc"} \X Msgs)
    \cup ({"row"} \X Nat) \cup ({"page"} \X Page)
TurnsEvents == {"handoff", "settle", "cancel", "completed", "cancelled"} \X Msgs

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
    /\ settled \subseteq Msgs /\ known \subseteq Msgs
    /\ qpending \in Seq(Msgs)
    /\ turn \in [Msgs -> {"none", "queued", "running", "claimed", "ended"}]
    /\ handed \in [Msgs -> Nat]
    /\ tl \in Seq(Nat)
    /\ job \in {"idle", "read", "written", "done"}
    /\ jobSeq \in Nat /\ dseq \in Nat
    /\ dropsLeft \in 0..MaxDrops /\ cancelsLeft \in 0..MaxCancels
    /\ answeredBy \subseteq Clients /\ dupWhileRunning \in BOOLEAN
    /\ cancelEarly \subseteq Msgs /\ refused \subseteq Msgs /\ told \subseteq Msgs

-----------------------------------------------------------------------------
(* Helpers *)

Range(s) == {s[i] : i \in 1..Len(s)}
MaxOf(S) == IF S = {} THEN 0 ELSE CHOOSE x \in S : \A y \in S : y <= x

\* The client's cursor: the last server_seq it shows.
Cursor(c) == IF view[c] = <<>> THEN 0 ELSE view[c][Len(view[c])]

\* The per-profile counter, read and bumped inside the insert's transaction
\* (next_server_seq, increment_server_seq, mobile_sql.ex:758, :786-795).
NextSeq == MaxOf(Range(tl)) + 1

\* Companion.Fanout.announce (fanout.ex:44-64) -> Channels.Companion.broadcast
\* (channels/companion.ex:105-108, dispatch :245-249): one send to every
\* Connection registered under the profile, each event the companion wire
\* carries, a row (built once, by Output.row) projected to the fields this
\* wire's row has. A row and a text_done are both a live row here.
FanoutTo(w, ev) == [c \in Clients |-> IF sub[c] = "yes" THEN Append(w[c], ev) ELSE w[c]]
Fanout(ev) == FanoutTo(wire, ev)

\* Timeline.history_page -> mobile_sql history (timeline.ex:83-90,
\* mobile_sql.ex:370), then Requests.history's byte budget (fit_page, cut_page,
\* requests.ex:124-136, :683-711): one Repo call reads the rows after a,
\* oldest first, at most PageLimit of them, and the head. A page cut to fit
\* keeps its oldest rows, at least one, and its next_after_seq names the last
\* row it kept; more follow while next_after_seq is below history_head_seq.
PagesAfter(a) ==
    LET later == SelectSeq(tl, LAMBDA s : s > a)
        most == IF Len(later) < PageLimit THEN Len(later) ELSE PageLimit
        least == IF PagesCanBeCut /\ most > 1 THEN 1 ELSE most
    IN {[rows |-> SubSeq(later, 1, k), more |-> Len(later) > k] : k \in least..most}

\* history_pull on connection c (dispatch, connection.ex:232-233 ->
\* Requests.history): the Repo read, in the step the client sends the pull;
\* `w` is c's mailbox and socket as that step left them. With
\* PageWrittenInReadStep the page is written to the socket in this step
\* (read_opts -> send_event, connection.ex:520-524, :436-440), ahead of any
\* live row sent after the read; without it, it goes through the mailbox in a
\* later step (SendPage). Without SubscribeBeforePull the Connection joins the
\* registry after its first page (Join).
Pull(c, w, a) ==
    /\ \E pg \in PagesAfter(a) :
          IF PageWrittenInReadStep
          THEN wire' = [wire EXCEPT ![c] = Append(w, <<"page", pg>>)] /\ UNCHANGED reading
          ELSE wire' = [wire EXCEPT ![c] = w] /\ reading' = [reading EXCEPT ![c] = pg]
    /\ sub' = IF sub[c] = "no" THEN [sub EXCEPT ![c] = "joining"] ELSE sub

\* maybe_start_next_request (queue.ex:317-325), run by every Queue callback
\* that can free the slot or fill the queue: with the waiting turns p and the
\* turn states t that callback left, start the head of p if no turn is alive
\* (OneTurnAtATime), or at once without it.
StartNext(p, t) ==
    IF p /= <<>> /\ (OneTurnAtATime => \A x \in Msgs : t[x] \notin Live)
    THEN turn' = [t EXCEPT ![Head(p)] = "running"] /\ qpending' = Tail(p)
    ELSE turn' = t /\ qpending' = p

\* Whether a settlement of a request answered without a turn completes it:
\* always, unless SettlesCanFail.
SettleResults == IF SettlesCanFail THEN BOOLEAN ELSE {TRUE}

\* A set of at most one turn as a sequence. CHOOSE on a singleton is
\* deterministic, so symmetry stays sound; no check reaches two.
One(S) ==
    IF Cardinality(S) > 1 THEN Assert(FALSE, "two running turns stopped at once")
    ELSE IF S = {} THEN <<>> ELSE <<CHOOSE x \in S : TRUE>>

\* Queue.stop_turn for m, in one Queue callback: the turns in `hit` stop (a
\* running one killed, a waiting one dropped), and each {:cancelled} is
\* invoked off the Queue (invoke_turn_result_async) into Turns' mailbox,
\* after `box`, the running one first. A claimed turn is never in `hit`: the
\* stop spares it (stop_named_in, queue.ex:1035-1041). A named stop that
\* kills the running turn starts the next one (:1045-1056). Without
\* StopTurnNamesTurn it is the conversation stop: whatever runs unclaimed is
\* killed and every waiting message cancelled (:1020-1024, cancel_pending
\* :1098-1104).
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
(* connection.ex:346-358) runs Companion.Requests.request                   *)

\* The worker's casts into Turns' mailbox, in the order it sends them: the
\* hand-off during ingest, unless the gateway answered inline, then the
\* settlement once ingest returned (SettleAfterIngest; without it the worker
\* casts none, and a request is left to its turn's outcome). Erlang keeps
\* the order of one sender's messages. Another process's message can land
\* between the two; the only one that could change the settlement's
\* decision is the turn's own outcome, which leaves the request in Turns'
\* `ended` list, so the model appends both at once.
Casts(m) ==
    (IF m \in Inline THEN <<>> ELSE <<<<"handoff", m>>>>)
    \o (IF SettleAfterIngest THEN <<<<"settle", m>>>> ELSE <<>>)

\* msg{client_msg_id} (Requests.request -> claim_and_run -> acquire_and_run
\* -> run_started -> ingest_span, requests.ex:101-108, :195-280):
\*  - claim_client_request claims the id durably (claim_request_in_tx,
\*    mobile_sql.ex:963-972), and accepted{duplicate} goes to this client's
\*    Connection (accepted_event, requests.ex:584-587) before anything runs;
\*  - the coordinator's acquire starts an attempt, or none for a request
\*    running, completed or failed (request_coordinator.ex:125-132);
\*  - an attempt appends the user's row (append_client_message, keyed by
\*    client_msg_id: an existing row is returned, not written again), and a
\*    row it created is announced to every connection (after_user_append ->
\*    announce_user_row, requests.ex:403-407, connection.ex:508-509);
\*  - Gateway.ingest calls Companion.Turns.handle_message, which casts the
\*    hand-off into Turns' mailbox and returns (turns.ex:123-128). A slash
\*    command the gateway answers inline hands nothing off;
\*  - once ingest returned, the worker moves the coordinator's fence onto
\*    Turns (handoff_settlement, requests.ex:306-323; not modelled) and casts
\*    the settlement to Turns, with how to complete the request, fail it and
\*    tell its client (settle_after_ingest, settle_unless_handed_off,
\*    requests.ex:288-302 -> Turns.settle_unless_handed_off, turns.ex:151-165).
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
               /\ turnsBox' = turnsBox \o Casts(m)
               /\ UNCHANGED <<marked, ends, cancelAsked, appr, applied>>
    /\ UNCHANGED <<sub, reading, settled, known, queue, job, jobSeq, dseq, answeredBy,
                   cancelEarly, refused, told>>

\* cancel{client_msg_id} (dispatch, connection.ex:229-230 -> Requests.cancel,
\* requests.ex:148-158), in the Connection's own step.
\*  - CancelMarksRequest: the mark is recorded on a request that has not
\*    settled, in one Repo call (cancel_request, mobile_sql.ex:546-565;
\*    settled for one that has, not_found for one never claimed), then Turns
\*    is asked (Turns.cancel, a call into its mailbox, turns.ex:173-176).
\*  - Otherwise the old code: the Connection calls Queue.stop_turn itself,
\*    which finds nothing for a request not yet handed off.
\*  - Without OutcomeEndsTurn the Connection also writes turn_error{cancelled}
\*    at once, for a message it has not seen end.
OnCancel(m) ==
    LET open == m \in accepted /\ m \notin settled
        unseen == m \in accepted /\ ends[m] = <<>>
    IN /\ cancelAsked' = cancelAsked \cup {m}
       /\ cancelEarly' = IF open /\ turn[m] = "none" /\ m \notin Inline
                         THEN cancelEarly \cup {m} ELSE cancelEarly
       /\ ends' = IF ~OutcomeEndsTurn /\ unseen
                  THEN [ends EXCEPT ![m] = Append(@, "cancelled")] ELSE ends
       /\ IF CancelMarksRequest
          THEN /\ marked' = IF open THEN marked \cup {m} ELSE marked
               /\ turnsBox' = IF open THEN Append(turnsBox, <<"cancel", m>>) ELSE turnsBox
               /\ UNCHANGED queue
          ELSE /\ StopTurn(m, turnsBox)
               /\ UNCHANGED <<marked, handed>>
       /\ UNCHANGED <<wire, sub, reading, accepted, appr, applied, reqs, store, answeredBy,
                      dupWhileRunning, refused, told>>

\* /confirm TOKEN or /deny TOKEN: a command request through the same path,
\* answered by the Gateway's command (confirm, deny, sandbox.ex:251-271).
\* take_pending peeks, checks the expiry and origin, then takes the token
\* (sandbox.ex:521-538, Confirmations.take, confirmations.ex:21-26). Only a
\* take that finds the token applies the answer and announces
\* approval_resolved (notify_approval, sandbox.ex:317-325 ->
\* approval_resolution_fn, requests.ex:501-506 -> Approvals.resolve,
\* approvals.ex:97-105, :136-143, which forgets the card first). Without
\* SingleAnswer the token survives its first answer.
OnAnswer(c) ==
    /\ answeredBy' = answeredBy \cup {c}
    /\ IF appr = "pending"
       THEN /\ appr' = "resolved"
            /\ applied' = applied + 1
            /\ wire' = Fanout(<<"resolved", None>>)
       ELSE /\ applied' = IF appr = "resolved" /\ ~SingleAnswer THEN applied + 1 ELSE applied
            /\ UNCHANGED <<appr, wire>>
    /\ UNCHANGED <<sub, reading, accepted, marked, ends, cancelAsked, turnsBox, reqs, queue,
                   store, dupWhileRunning, cancelEarly, refused, told>>

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
       ELSE UNCHANGED <<sentOn, conn, turns, reqs, queue, store, obs>>
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
\* to the socket, and right behind it every card still waiting
\* (ResendsPendingApprovals; hello, join, send_pending_approvals,
\* connection.ex:245-277). The store keeps a card before it announces it, in
\* one step (Approvals.announce, approvals.ex:79-88, :130-134), and the
\* Connection joins before it reads the kept cards, so however the two
\* interleave, a connection gets the
\* card from the one, the other, or both (a client deduplicates by
\* approval_id); each is one step here.
Connect(c) ==
    /\ link[c] = "down"
    /\ link' = [link EXCEPT ![c] = "hello"]
    /\ sub' = IF SubscribeBeforePull THEN [sub EXCEPT ![c] = "yes"] ELSE sub
    /\ wire' = [wire EXCEPT ![c] =
                  <<<<"hello_ok", None>>>>
                  \o (IF ResendsPendingApprovals /\ appr = "pending"
                      THEN <<<<"appr", None>>>> ELSE <<>>)]
    /\ UNCHANGED <<composed, outbox, sentOn, view, pulling, prompt, resent, reading, turns,
                   reqs, queue, store, env, obs>>

\* The connection drops. The Connection exits (connection.ex:140) with its
\* mailbox; its registry entry goes with it. A request worker it started runs
\* on, since it is not linked, so a claimed request still settles. The client
\* keeps its outbox, its view, and any approval card it shows until its next
\* server_hello (OnServerHello).
Drop(c) ==
    /\ ClientsCanDisconnect /\ dropsLeft > 0 /\ link[c] /= "down"
    /\ dropsLeft' = dropsLeft - 1
    /\ link' = [link EXCEPT ![c] = "down"]
    /\ wire' = [wire EXCEPT ![c] = <<>>]
    /\ sub' = [sub EXCEPT ![c] = "no"]
    /\ reading' = [reading EXCEPT ![c] = None]
    /\ sentOn' = [sentOn EXCEPT ![c] = {}]
    /\ pulling' = [pulling EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<composed, outbox, view, prompt, resent, turns, reqs, queue, store,
                   cancelsLeft, obs>>

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

\* server_hello: the client drops every approval card it shows, since only
\* the cards the daemon sends after it still wait (DropsCardsAtHello), and
\* pulls after its cursor (SeqCursor).
OnServerHello(c, rest) ==
    /\ link' = [link EXCEPT ![c] = "up"]
    /\ prompt' = IF DropsCardsAtHello THEN [prompt EXCEPT ![c] = FALSE] ELSE prompt
    /\ pulling' = [pulling EXCEPT ![c] = SeqCursor]
    /\ IF SeqCursor THEN Pull(c, rest, Cursor(c))
       ELSE wire' = [wire EXCEPT ![c] = rest] /\ UNCHANGED <<sub, reading>>
    /\ UNCHANGED <<composed, outbox, sentOn, view, resent>>

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
    /\ UNCHANGED <<turns, reqs, queue, store, env, obs>>

\* Without PageWrittenInReadStep: the Connection sends the page it read to
\* its own mailbox, behind whatever other processes sent it since the read.
SendPage(c) ==
    /\ reading[c] /= None
    /\ wire' = [wire EXCEPT ![c] = Append(@, <<"page", reading[c]>>)]
    /\ reading' = [reading EXCEPT ![c] = None]
    /\ UNCHANGED <<client, sub, turns, reqs, queue, store, env, obs>>

\* Without SubscribeBeforePull: the Connection joins the registry after it
\* answered the first pull, in a step of its own.
Join(c) ==
    /\ sub[c] = "joining"
    /\ sub' = [sub EXCEPT ![c] = "yes"]
    /\ UNCHANGED <<client, wire, reading, turns, reqs, queue, store, env, obs>>

-----------------------------------------------------------------------------
(* Companion.Turns: one process, one mailbox                                *)

\* Turns handles its next message:
\*  - a hand-off (handle_cast {:hand_off, ...}, turns.ex:255-260 -> hand_off
\*    :302-315): with CancelMarksRequest it reads the request's mark
\*    (cancel_recorded, get_client_request, :318-326) and, in the same step,
\*    ends a marked request with one turn_error{cancelled} and settles it
\*    failed (fail, :440-445), never enqueued; otherwise it tracks the turn
\*    and enqueues it (Queue.handle_message; the Queue's handle_cast is
\*    folded in). Either way Turns now knows the request (tracked, or in its
\*    `ended` list);
\*  - a settlement (handle_cast {:settle_unless_handed_off, ...}, :262-268):
\*    with SettleUnlessHandedOff it runs only if Turns knows no hand-off of
\*    the request; otherwise regardless. It completes the request
\*    (settle_inline, run_settle, :334-369 -> Requests.settle_inline,
\*    requests.ex:411-422). A completion that fails (SettlesCanFail) is,
\*    with FailsUnsettled, followed by one failure write for the attempt and
\*    by error{request_failed, client_msg_id} to the Connection that ran the
\*    request (Requests.fail_attempt, report_failure, requests.ex:325-345,
\*    through the transport's report_failure, request_failure_reporter,
\*    connection.ex:496-503, which the Connection writes as a failed
\*    worker's error, :153-154). That report is best effort
\*    and no client rule reads it, so it is only observed here (told).
\*    Without FailsUnsettled the failure is only logged and the request
\*    stays running;
\*  - a cancel (handle_call {:cancel, ...}, turns.ex:226-229 -> stop :403-408,
\*    stop_in_queue :416-427): Queue.stop_turn for a turn it handed off,
\*    sent after its own enqueue, so it cannot overtake it. Turns waits for
\*    the answer with no timeout and the Queue answers however busy it is, so
\*    the Queue's stop is folded into this step; for any other message the
\*    stop finds nothing. A Queue gone before or during the stop exits the
\*    call, which stop_in_queue catches, and its :DOWN ends the turn as
\*    interrupted (not modelled);
\*  - {:completed} (outcome/2, :242-252 -> finish/3, :432-435): each held
\*    reply is written as a row, fenced to the running attempt (one Repo
\*    call), and announced as text_done{server_seq} (write_reply, :453-472),
\*    then the request is completed (settle_completed, :476-488); one reply
\*    here. A request already settled refuses the write as a stale attempt
\*    (append_client_output_in_tx, ensure_running_attempt,
\*    mobile_sql.ex:1142-1152): no row and no text_done;
\*  - {:cancelled}: the request is settled failed and one turn_error is
\*    announced (fail, :440-445); turn_error is live-only.
TurnsNext ==
    /\ turnsBox /= <<>>
    /\ LET ev == Head(turnsBox)
           m == ev[2]
           rest == Tail(turnsBox)
       IN CASE ev[1] = "handoff" ->
                    /\ turnsBox' = rest
                    /\ known' = known \cup {m}
                    /\ IF CancelMarksRequest /\ m \in marked
                       THEN /\ ends' = [ends EXCEPT ![m] = Append(@, "cancelled")]
                            /\ settled' = settled \cup {m}
                            /\ turn' = [turn EXCEPT ![m] = "ended"]
                            /\ UNCHANGED <<qpending, handed>>
                       ELSE /\ handed' = [handed EXCEPT ![m] = @ + 1]
                            /\ StartNext(Append(qpending, m), [turn EXCEPT ![m] = "queued"])
                            /\ UNCHANGED <<ends, settled>>
                    /\ UNCHANGED <<refused, told>>
               [] ev[1] = "settle" ->
                    /\ turnsBox' = rest
                    /\ IF SettleUnlessHandedOff /\ m \in known
                       THEN UNCHANGED <<settled, told>>
                       ELSE \E completes \in SettleResults :
                               /\ settled' = IF completes \/ FailsUnsettled
                                             THEN settled \cup {m} ELSE settled
                               /\ told' = IF ~completes /\ FailsUnsettled
                                          THEN told \cup {m} ELSE told
                    /\ UNCHANGED <<ends, known, queue, refused>>
               [] ev[1] = "cancel" ->
                    /\ StopTurn(m, rest)
                    /\ UNCHANGED <<ends, settled, known, handed, refused, told>>
               [] ev[1] = "completed" ->
                    /\ turnsBox' = rest
                    /\ IF m \in settled
                       THEN refused' = refused \cup {m} /\ UNCHANGED <<ends, settled>>
                       ELSE /\ ends' = [ends EXCEPT ![m] = Append(@, "done")]
                            /\ settled' = settled \cup {m}
                            /\ UNCHANGED refused
                    /\ UNCHANGED <<known, queue, told>>
               [] ev[1] = "cancelled" ->
                    /\ turnsBox' = rest
                    /\ ends' = [ends EXCEPT ![m] = Append(@, "cancelled")]
                    /\ settled' = settled \cup {m}
                    /\ UNCHANGED <<known, queue, refused, told>>
    /\ LET ev == Head(turnsBox) IN
       IF ev[1] = "completed" /\ ev[2] \notin settled
       THEN tl' = Append(tl, NextSeq) /\ wire' = Fanout(<<"row", NextSeq>>)
       ELSE UNCHANGED <<tl, wire>>
    /\ UNCHANGED <<client, sub, reading, accepted, marked, cancelAsked, appr, applied, job,
                   jobSeq, dseq, env, answeredBy, dupWhileRunning, cancelEarly>>

-----------------------------------------------------------------------------
(* The Gateway Queue and its turn tasks, abstract (see the header)          *)

\* A tool of m's turn needs the owner's approval (a directory grant, or a
\* coding run's vendor-config change to acknowledge; one path for both): the
\* gateway stores a pending token (store_pending_grant, sandbox.ex:198-210)
\* and the channel's approval store keeps the card, then announces it to this
\* transport's connections alone, through the announce it announces the
\* card's end with (send_approval, channels/companion.ex:180-183 ->
\* Approvals.announce, approvals.ex:79-88, :130-134). The turn does not wait
\* for it.
Ask(m) ==
    /\ turn[m] = "running" /\ appr = "none" /\ Approvals > 0
    /\ appr' = "pending"
    /\ wire' = Fanout(<<"appr", None>>)
    /\ UNCHANGED <<client, sub, reading, accepted, marked, ends, cancelAsked, turnsBox,
                   applied, reqs, queue, store, env, obs>>

\* The card's ttl_s runs out: the token is refused from then on
\* (validate_pending, sandbox.ex:532-538), and Approvals drops the card and
\* announces approval_resolved{expired} to its transport (handle_info
\* {:approval_expired, ...}, expire, approvals.ex:150-155, :208-217). The two
\* clocks start a moment apart; either order leaves no card that can be
\* approved, so they are one step here. Time, so no fairness.
Expire ==
    /\ appr = "pending"
    /\ appr' = "expired"
    /\ wire' = Fanout(<<"resolved", None>>)
    /\ UNCHANGED <<client, sub, reading, accepted, marked, ends, cancelAsked, turnsBox,
                   applied, reqs, queue, store, env, obs>>

\* m's turn committed its reply and claimed its outcome: from here a stop
\* spares it (claim_active_turn, queue.ex:1120-1124).
Claim(m) ==
    /\ turn[m] = "running"
    /\ turn' = [turn EXCEPT ![m] = "claimed"]
    /\ UNCHANGED <<client, conn, turns, reqs, qpending, handed, store, env, obs>>

\* The turn invokes {:completed} (Turns.outcome, a call into Turns' mailbox,
\* turns.ex:208-210, through build_turn_result, channels/companion.ex:160-164)
\* and exits; the Queue's :DOWN frees the slot and starts the next waiting
\* turn (folded in: nothing else can act on the dead turn in between).
Finish(m) ==
    /\ turn[m] = "claimed"
    /\ turnsBox' = Append(turnsBox, <<"completed", m>>)
    /\ StartNext(qpending, [turn EXCEPT ![m] = "ended"])
    /\ UNCHANGED <<client, conn, accepted, marked, ends, cancelAsked, appr, applied, handed,
                   reqs, store, env, obs>>

-----------------------------------------------------------------------------
(* A scheduled job reporting back: Channels.Companion.send_message in the   *)
(* job's own process (channels/companion.ex:194-207)                        *)

\* Without SeqAssignedOnInsert the job reads the counter first.
JobRead ==
    /\ DeliveriesWhileOffline /\ ~SeqAssignedOnInsert /\ job = "idle"
    /\ job' = "read" /\ jobSeq' = MaxOf(Range(tl))
    /\ UNCHANGED <<client, conn, turns, reqs, queue, tl, dseq, env, obs>>

\* Output.persist_text -> Timeline.append: one Repo call (append_in_tx).
JobWrite ==
    /\ DeliveriesWhileOffline
    /\ job = IF SeqAssignedOnInsert THEN "idle" ELSE "read"
    /\ LET s == IF SeqAssignedOnInsert THEN NextSeq ELSE jobSeq + 1 IN
       /\ tl' = Append(tl, s)
       /\ dseq' = s
       /\ jobSeq' = s
    /\ job' = "written"
    /\ UNCHANGED <<client, conn, turns, reqs, queue, env, obs>>

\* announce_written -> Fanout.announce: the job announces its row
\* (channels/companion.ex:225-226).
JobAnnounce ==
    /\ job = "written"
    /\ job' = "done"
    /\ wire' = Fanout(<<"row", jobSeq>>)
    /\ UNCHANGED <<client, sub, reading, turns, reqs, queue, tl, jobSeq, dseq, env, obs>>

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
    /\ settled = {} /\ known = {}
    /\ qpending = <<>>
    /\ turn = [m \in Msgs |-> "none"]
    /\ handed = [m \in Msgs |-> 0]
    /\ tl = <<>> /\ job = "idle" /\ jobSeq = 0 /\ dseq = 0
    /\ dropsLeft = MaxDrops /\ cancelsLeft = MaxCancels
    /\ answeredBy = {} /\ dupWhileRunning = FALSE /\ cancelEarly = {} /\ refused = {}
    /\ told = {}

\* Nothing is left for Fermix to do: Turns' mailbox is empty and no turn
\* waits or is alive.
Idle ==
    /\ turnsBox = <<>> /\ qpending = <<>>
    /\ \A m \in Msgs : turn[m] \notin Live

\* The legitimate end: every client connected with nothing left to read, no
\* pull outstanding, no page unsent, no Connection about to join, Fermix idle
\* and no job half-way. Whether the clients show the right rows then is for
\* the rules to say. Deadlock checking is on, so any other state where
\* nothing can happen is reported as a wedge.
Done ==
    /\ \A c \in Clients :
          /\ link[c] = "up" /\ wire[c] = <<>> /\ ~pulling[c]
          /\ reading[c] = None /\ sub[c] /= "joining"
    /\ Idle
    /\ job \notin {"read", "written"}

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E m \in Msgs :
          \/ Compose(m) \/ Flush(m) \/ Resend(m) \/ Ask(m) \/ Claim(m) \/ Finish(m)
    \/ \E c \in Clients :
          \/ Connect(c) \/ Drop(c) \/ Answer(c) \/ ClientRead(c) \/ SendPage(c) \/ Join(c)
          \/ \E m \in Msgs : Cancel(c, m)
    \/ TurnsNext \/ Expire \/ JobRead \/ JobWrite \/ JobAnnounce
    \/ Terminated

\* Fairness only on what Fermix drives: the clients' reconnect loop, their
\* reading of the socket and their outbox, the Connections, Turns, a running
\* turn, and the job's announcement once its row is written. None on users
\* (typing, answering, cancelling, retrying), on drops, on time, or on the job
\* reporting back.
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
\* Fermix is idle, and no job row waits for its announcement.
Quiet(c) ==
    /\ link[c] = "up" /\ sub[c] = "yes"
    /\ wire[c] = <<>> /\ ~pulling[c] /\ reading[c] = None
    /\ Idle
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

\* PROTOCOL.md "Delivery and the outbox": a request the daemon accepted is run
\* again at its next start only if it "could not finish", and one "that fails
\* after accepted" is answered request_failed and "stays failed". Read as:
\* once Fermix is idle, every accepted request is settled, so no boot runs
\* again a request that was answered or failed, a slash command's included.
RequestsSettle == Idle => accepted \subseteq settled

\* A turn's reply is its request's output, written only while that attempt
\* runs (append_client_output_in_tx). Read as: no turn completes after its
\* request was settled, which would refuse its reply and leave the message
\* unanswered.
ReplyNeverRefused == refused = {}

\* take/1 is "the sole consume authority" (confirmations.ex:28-31). Read as:
\* at most one answer to an approval is ever applied, whoever sends it and
\* however late.
ApprovalAnsweredOnce == applied <= 1

\* Approvals moduledoc: a card is kept "so a client that was not connected
\* when one went out still gets it". Read as: while the approval waits for
\* the owner, every client that has caught up shows its card.
PendingApprovalShown == \A c \in Clients : (Quiet(c) /\ appr = "pending") => prompt[c]

\* PROTOCOL.md "Approvals": "When server_hello arrives, a client drops every
\* card it shows and keeps only the ones the daemon sends after it", since a
\* card that ended while the client was away "is never withdrawn: it is
\* simply not sent again". Read as: no client that has caught up shows a card
\* that no longer waits.
NoStaleCard == \A c \in Clients : (Quiet(c) /\ appr /= "pending") => ~prompt[c]

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

\* A request answered without a turn could not be settled, so it was failed
\* and the client that sent it was told.
Witness_SettleFailed == told = {}

\* A page cut to fit its byte budget reaches a client: fewer rows than its
\* limit, and more to pull.
Witness_PageCut ==
    ~(\E c \in Clients : \E i \in 1..Len(wire[c]) :
        /\ wire[c][i][1] = "page"
        /\ wire[c][i][2].more /\ Len(wire[c][i][2].rows) < PageLimit)

=============================================================================
