------------------------- MODULE CompanionSession -------------------------
(***************************************************************************)
(* DESIGN SPEC of the companion chat wire for ONE shared conversation,     *)
(* written before the code. The Mac app and the iPhone app each hold one   *)
(* connection to a 0600 Unix socket (newline JSON, protocol 1, a           *)
(* mandatory client_hello/server_hello), connect and drop at any time,     *)
(* and share one conversation and its durable timeline.                    *)
(*                                                                         *)
(* The companion modules do not exist yet. Their SOURCE pins follow the    *)
(* first engine commit that lands them; until then this spec describes     *)
(* the intended design, and every step below names the module that is to   *)
(* own it:                                                                 *)
(*  - FermixCore.Companion.Protocol: the wire events and the handshake;    *)
(*  - FermixChannels.Companion.Endpoint: ONE process per daemon that       *)
(*    dedupes msg on client_msg_id, writes every row the conversation      *)
(*    produces, fans rows out to subscribed connections, hands turns to    *)
(*    the Queue and holds the pending approval;                            *)
(*  - its socket handler: one process per connection; the handshake, the   *)
(*    subscription, and history_pull answered straight from the Timeline;  *)
(*  - FermixCore.Companion.Timeline: the durable rows, one server_seq      *)
(*    each, written through Memory.Repo (one process, so one call is       *)
(*    atomic);                                                             *)
(*  - FermixChannels.Gateway.Queue: the only one that exists. The pin      *)
(*    below names the functions whose rules this spec composes with.       *)
(*                                                                         *)
(* The Queue is ONE abstract process here, not the turn_queue module:      *)
(* the runner takes one .tla per spec, and turn_queue already proves the   *)
(* rules taken as given: one turn at a time per conversation               *)
(* (maybe_start_next_request; SingleFlight rests on StartsWhenIdle), one   *)
(* outcome per turn through the claim (claim_active_turn;                  *)
(* AtMostOneOutcome), and a stop that spares a claimed turn and cancels    *)
(* every waiting message (stop_active_turn, cancel_pending; its checks 15  *)
(* and 16). As in queue.ex, a turn starts in the callback that enqueues    *)
(* it or that clears the previous turn, and then takes three steps of its  *)
(* own: an optional approval, the claim (after the commit), and the        *)
(* invocation of {:completed}.                                             *)
(*                                                                         *)
(* Only the daemon-to-app side of a socket is a queue. The handler reads   *)
(* each app event as it arrives, so an app event, the handler's handling   *)
(* of it and the Endpoint call it makes are one step. Nothing distinct is  *)
(* lost: an app event lost in a drop looks to the app exactly like one     *)
(* whose answer was lost (the app acts only on answers), and the           *)
(* Endpoint's effects of an event that did arrive are the harder case; an  *)
(* event delivered late is one sent late, and users may cancel, answer or  *)
(* resend at any moment here. Server events travel on a FIFO per           *)
(* connection, and a drop loses what is on it.                             *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - text_delta, tool_event, turn_started and read_state: live-only,      *)
(*    never in the timeline, and no rule reads them;                       *)
(*  - history_search and scroll-back (history_pull{before_seq}): reads     *)
(*    below the cursor that never move it;                                 *)
(*  - turn_error's code and sentence, and turns that fail ({:failed}       *)
(*    ends a turn through the same outcome path as {:cancelled});          *)
(*  - the LLM and tools, the ConversationStore, auth and the socket's      *)
(*    0600 mode (single-call rules; ExUnit covers them);                   *)
(*  - a daemon restart, a Queue crash, and a turn task crash: turn_queue   *)
(*    covers what they do to outcomes (QUEUE-8, QUEUE-9);                  *)
(*  - other conversations (the Queue keys all state by conversation).      *)
(*                                                                         *)
(* One step = one callback of one process, one Memory.Repo call, or one    *)
(* thing an app or the environment does.                                   *)
(***************************************************************************)
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/queue.ex#stop_conversation,maybe_start_next_request,claim_active_turn,stop_conversation_runtime,stop_active_turn,cancel_pending @ 8a618a01a62c
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Clients,        \* the apps on the conversation, e.g. {mac, phone}
    Senders,        \* the apps whose users type, a subset of Clients
    MsgsPerSender,  \* messages each of them types
    None,
    PageLimit,      \* history_pull's limit
    Approvals,      \* approvals the turns may raise in all (0 or 1)
    MaxDrops,       \* bound: connection drops the environment may cause in all
    MaxCancels,     \* bound: cancels the users may send in all
    \* Environment switches: what may happen to the conversation.
    ClientsCanDisconnect,   \* a connection drops (sleep, network, app killed); what is
                            \* on its way to the app is lost
    MessagesCanBeResent,    \* an app resends a message it has no accepted for yet, at
                            \* any moment on a live connection (its ack timeout, or the
                            \* user's retry), at most once per message
    TurnsCanBeCancelled,    \* a user sends cancel{turn_id}, for any turn of the shared
                            \* conversation, whatever state it is in
    DeliveriesWhileOffline, \* a scheduled job reports back into the conversation at any
                            \* moment, including while no app is connected (one delivery)
    \* Mechanism switches: what the design does about it. TRUE is the design;
    \* each is switched off only by the checks that show a rule needs it.
    OutboxResend,        \* the app keeps every typed message in its outbox until
                         \* accepted, and sends the outbox again on every new connection
    AcceptedDedupe,      \* the Endpoint keeps a durable record of accepted
                         \* client_msg_ids and answers a known one accepted{duplicate:
                         \* true}, with no second row and no second turn
    SeqCursor,           \* the app keeps the last server_seq it shows, pulls
                         \* history_pull{after_seq: cursor} after server_hello, on a gap
                         \* and while a page says more, and drops any row at or below it
    SubscribeBeforePull, \* the handler subscribes its connection to the fan-out at
                         \* client_hello, before server_hello, so before any pull
    SingleAnswer,        \* the Endpoint applies the first answer to a pending approval
                         \* and drops every later one
    OneTurnAtATime,      \* the Queue starts a turn only when none of the conversation's
                         \* turns is alive (queue.ex maybe_start_next_request)
    CancelNamesTurn,     \* cancel{turn_id} stops that turn only, through a per-turn stop
                         \* the Queue does not have yet (FALSE: Queue.stop_conversation)
    OutcomeEndsTurn,     \* the Endpoint ends a turn on the wire only from the Queue's
                         \* outcome; a cancel request writes nothing itself
    SeqAssignedOnInsert  \* the Timeline assigns server_seq inside the one Repo call that
                         \* inserts the row (FALSE: a writer reads the highest seq, then
                         \* inserts in a second call)

VARIABLES
    \* each app (the Mac app, the iPhone app)
    link,       \* link[c]: "down", "hello" (client_hello sent), "up" (server_hello read)
    composed,   \* messages the users typed
    outbox,     \* outbox[c]: c's typed messages it has no accepted for yet
    sentOn,     \* sentOn[c]: messages sent on c's current connection
    view,       \* view[c]: the server_seq of each row the app shows, in order
    pulling,    \* pulling[c]: a history_pull is outstanding
    prompt,     \* prompt[c]: the app shows the approval
    resent,     \* messages resent on the app's own initiative (MessagesCanBeResent)
    \* each connection: server events on their way, and the handler's subscription
    wire,       \* wire[c]: server events on the socket, not yet read by the app
    sub,        \* sub[c]: "no", "joining" (the handler is about to subscribe), "yes"
    \* the Endpoint
    accepted,   \* durable record: client_msg_ids accepted
    ends,       \* ends[m]: the endings written for m's turn, in order: "done"
                \* (text_done) or "cancelled" (turn_error)
    cancelAsked,\* messages a cancel{turn_id} reached the Endpoint for
    epbox,      \* its mailbox: the Queue's outcomes and the job's delivery notice
    appr,       \* the approval: "none", "pending", "resolved", "withdrawn"
    apprTurn,   \* the turn that raised it
    applied,    \* answers (or the timeout) applied to it
    \* the Gateway Queue and its turn tasks
    qpending,   \* FIFO of waiting turns
    turn,       \* turn[m]: "none", "queued", "running", "asking" (waits on the
                \* approval), "claimed" (committed, holds its outcome), "ended"
    handed,     \* handed[m]: turns handed to the Queue for m
    \* the Timeline and the job reporting back
    tl,         \* the durable rows: the server_seq of each, in insertion order
    job,        \* "idle", "read" (read the highest seq; SeqAssignedOnInsert off), "done"
    jobSeq,     \* the highest seq the job read
    dseq,       \* the delivery row's server_seq, 0 before it is written
    \* environment budgets
    dropsLeft,
    cancelsLeft,
    \* observers (read only by witnesses)
    answeredBy,     \* apps whose answer to the approval reached the Endpoint
    dupWhileRunning \* a resend reached the Endpoint while its message's turn was alive

app      == <<link, composed, outbox, sentOn, view, pulling, prompt, resent>>
conn     == <<wire, sub>>
endpoint == <<accepted, ends, cancelAsked, epbox, appr, apprTurn, applied>>
queue    == <<qpending, turn, handed>>
store    == <<tl, job, jobSeq, dseq>>
env      == <<dropsLeft, cancelsLeft>>
obs      == <<answeredBy, dupWhileRunning>>
vars == <<app, conn, endpoint, queue, store, env, obs>>

Msgs == Senders \X (1..MsgsPerSender)
Owner(m) == m[1]

\* Apps that play the same part are interchangeable: invariant checks may
\* reduce by symmetry.
Symm == IF Senders = Clients THEN Permutations(Clients) ELSE Permutations(Clients \ Senders)

Live == {"running", "asking", "claimed"}     \* a turn task is alive
Stoppable == {"queued", "running", "asking"} \* a stop still reaches it

Page == [rows : Seq(Nat), more : BOOLEAN]
DownEvents ==
    ({"hello_ok", "appr", "resolved"} \X {None}) \cup ({"acc"} \X Msgs)
    \cup ({"row"} \X Nat) \cup ({"page"} \X Page)
EpEvents == ({"completed", "cancelled"} \X Msgs) \cup ({"delivered"} \X Nat)

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
    /\ accepted \subseteq Msgs
    /\ \A m \in Msgs : ends[m] \in Seq({"done", "cancelled"})
    /\ cancelAsked \subseteq Msgs
    /\ epbox \in Seq(EpEvents)
    /\ appr \in {"none", "pending", "resolved", "withdrawn"}
    /\ apprTurn \in Msgs \cup {None}
    /\ applied \in Nat
    /\ qpending \in Seq(Msgs)
    /\ turn \in [Msgs -> {"none", "queued", "running", "asking", "claimed", "ended"}]
    /\ handed \in [Msgs -> Nat]
    /\ tl \in Seq(Nat)
    /\ job \in {"idle", "read", "done"}
    /\ jobSeq \in Nat /\ dseq \in Nat
    /\ dropsLeft \in 0..MaxDrops /\ cancelsLeft \in 0..MaxCancels
    /\ answeredBy \subseteq Clients /\ dupWhileRunning \in BOOLEAN

-----------------------------------------------------------------------------
(* Helpers *)

Range(s) == {s[i] : i \in 1..Len(s)}
MaxOf(S) == IF S = {} THEN 0 ELSE CHOOSE x \in S : \A y \in S : y <= x

\* The app's cursor: the last server_seq it shows.
Cursor(c) == IF view[c] = <<>> THEN 0 ELSE view[c][Len(view[c])]

\* Timeline.append with the seq assigned inside the insert: one past the highest.
NextSeq == MaxOf(Range(tl)) + 1

\* The Endpoint fans one event out to every subscribed connection: its
\* handler writes it to the socket in the order it receives them.
Fanout(ev) == [c \in Clients |-> IF sub[c] = "yes" THEN Append(wire[c], ev) ELSE wire[c]]

\* The handler answers history_pull{after_seq: a, limit}: one Repo read of the
\* rows after a, oldest first, at most PageLimit of them, and whether more follow
\* (history_page's next_after_seq).
PageAfter(a) ==
    LET later == SelectSeq(tl, LAMBDA s : s > a)
        k == IF Len(later) < PageLimit THEN Len(later) ELSE PageLimit
    IN [rows |-> SubSeq(later, 1, k), more |-> Len(later) > PageLimit]

\* The handler answers a pull on connection c (the app sent it in the same
\* step): the page goes on the socket after `w`, what c's socket holds then.
\* Without SubscribeBeforePull, the handler joins the fan-out only after its
\* first page, in a call of its own (Join).
Pull(c, w, a) ==
    /\ wire' = [wire EXCEPT ![c] = Append(w, <<"page", PageAfter(a)>>)]
    /\ sub' = IF sub[c] = "no" THEN [sub EXCEPT ![c] = "joining"] ELSE sub

\* maybe_start_next_request (queue.ex), run by every Queue callback that can
\* free the slot or fill the queue: with the waiting turns p and the turn
\* states t that callback left, start the head of p if no turn is alive
\* (OneTurnAtATime), or at once without it.
StartNext(p, t) ==
    IF p /= <<>> /\ (OneTurnAtATime => \A x \in Msgs : t[x] \notin Live)
    THEN turn' = [t EXCEPT ![Head(p)] = "running"] /\ qpending' = Tail(p)
    ELSE turn' = t /\ qpending' = p

-----------------------------------------------------------------------------
(* The Endpoint's callbacks for an app event, called by the socket handler  *)
(* (FermixChannels.Companion.Endpoint; a GenServer.call, so the handler     *)
(* waits)                                                                   *)

\* msg{client_msg_id}. A known id is answered accepted{duplicate: true} and
\* nothing else (AcceptedDedupe). A new one is recorded, its user row appended
\* (one Repo call) and fanned out, accepted written to the sender, and the turn
\* handed to the Queue (Queue.enqueue, a cast; the Queue's handle_cast is
\* folded in, since nothing in the model tells the two apart).
OnMsg(c, m) ==
    /\ dupWhileRunning' = (dupWhileRunning \/ (m \in accepted /\ turn[m] \in Live))
    /\ IF AcceptedDedupe /\ m \in accepted
       THEN /\ wire' = [wire EXCEPT ![c] = Append(@, <<"acc", m>>)]
            /\ UNCHANGED <<endpoint, queue, tl>>
       ELSE LET s == NextSeq
                w == Fanout(<<"row", s>>)
            IN /\ accepted' = accepted \cup {m}
               /\ tl' = Append(tl, s)
               /\ wire' = [w EXCEPT ![c] = Append(@, <<"acc", m>>)]
               /\ handed' = [handed EXCEPT ![m] = @ + 1]
               /\ StartNext(Append(qpending, m), [turn EXCEPT ![m] = "queued"])
               /\ UNCHANGED <<ends, cancelAsked, epbox, appr, apprTurn, applied>>
    /\ UNCHANGED <<sub, job, jobSeq, dseq, answeredBy>>

\* A set of at most one turn as a sequence. CHOOSE on a singleton is
\* deterministic, so symmetry stays sound; no check reaches two.
One(S) ==
    IF Cardinality(S) > 1 THEN Assert(FALSE, "two running turns stopped at once")
    ELSE IF S = {} THEN <<>> ELSE <<CHOOSE x \in S : TRUE>>

\* The Queue stops the turns in `hit`, inside the Endpoint's call: a running
\* one is killed and a waiting one dropped, and each gets {:cancelled}, sent
\* to the Endpoint (the running one first, then the waiting ones in queue
\* order). A claimed turn is never in `hit`: the stop spares it
\* (stop_active_turn). The approval of a killed turn is withdrawn. A
\* per-turn stop that kills the running turn starts the next one, as the
\* :DOWN of a finished turn does; stop_conversation leaves none waiting.
StopTurns(hit) ==
    LET order == One({x \in hit : turn[x] /= "queued"})
                 \o SelectSeq(qpending, LAMBDA x : x \in hit)
    IN /\ StartNext(SelectSeq(qpending, LAMBDA x : x \notin hit),
                    [x \in Msgs |-> IF x \in hit THEN "ended" ELSE turn[x]])
       /\ epbox' = epbox \o [i \in 1..Len(order) |-> <<"cancelled", order[i]>>]
       /\ IF appr = "pending" /\ apprTurn \in hit
          THEN appr' = "withdrawn" /\ wire' = Fanout(<<"resolved", None>>)
          ELSE UNCHANGED <<appr, wire>>

\* cancel{turn_id}.
\*  - CancelNamesTurn: a per-turn Queue stop (the Queue has none yet): m's turn
\*    stops if a stop still reaches it, and nothing else does.
\*  - Otherwise Queue.stop_conversation (stop_conversation_runtime), called
\*    while the Endpoint still takes m's turn for unfinished: it kills
\*    whichever turn is running unclaimed, and cancels every waiting message.
\*  - Without OutcomeEndsTurn the Endpoint also writes turn_error{cancelled}
\*    at once, before the Queue has stopped anything.
OnCancel(m) ==
    LET open == m \in accepted /\ ends[m] = <<>>
        hit == IF CancelNamesTurn
               THEN IF turn[m] \in Stoppable THEN {m} ELSE {}
               ELSE IF open THEN {x \in Msgs : turn[x] \in Stoppable} ELSE {}
    IN /\ cancelAsked' = cancelAsked \cup {m}
       /\ ends' = IF ~OutcomeEndsTurn /\ open
                  THEN [ends EXCEPT ![m] = Append(@, "cancelled")] ELSE ends
       /\ StopTurns(hit)
       /\ UNCHANGED <<sub, accepted, apprTurn, applied, handed, store, obs>>

\* The approval is resolved: its turn resumes, and every app clears it.
Resolve ==
    /\ appr' = "resolved"
    /\ applied' = applied + 1
    /\ turn' = [turn EXCEPT ![apprTurn] = "running"]
    /\ wire' = Fanout(<<"resolved", None>>)

\* The approval's answer. The first answer to a pending approval resolves
\* it; any other is dropped (SingleAnswer) or applied as well.
OnAnswer(c) ==
    /\ answeredBy' = answeredBy \cup {c}
    /\ IF appr = "pending"
       THEN Resolve
       ELSE /\ applied' = IF SingleAnswer THEN applied ELSE applied + 1
            /\ UNCHANGED <<appr, turn, wire>>
    /\ UNCHANGED <<sub, accepted, ends, cancelAsked, epbox, apprTurn, qpending, handed, store,
                   dupWhileRunning>>

-----------------------------------------------------------------------------
(* The apps (FermixCore.Companion.Protocol's client side, in the Mac and    *)
(* iPhone apps), each event handled by the connection's socket handler in   *)
(* the same step                                                            *)

\* The user types m. With the outbox it is kept until accepted and goes out
\* now if the app is connected, or once it is (Flush). Without one, the app
\* can only send while connected, and sends once.
Compose(m) ==
    LET c == Owner(m) IN
    /\ m \notin composed
    /\ OutboxResend \/ link[c] = "up"
    /\ composed' = composed \cup {m}
    /\ outbox' = [outbox EXCEPT ![c] = @ \cup {m}]
    /\ IF link[c] = "up"
       THEN sentOn' = [sentOn EXCEPT ![c] = @ \cup {m}] /\ OnMsg(c, m)
       ELSE UNCHANGED <<sentOn, conn, endpoint, queue, store, obs>>
    /\ UNCHANGED <<link, view, pulling, prompt, resent, env>>

\* OutboxResend: after server_hello the app sends every outboxed message it
\* has not sent on this connection.
Flush(m) ==
    LET c == Owner(m) IN
    /\ OutboxResend
    /\ link[c] = "up" /\ m \in outbox[c] /\ m \notin sentOn[c]
    /\ sentOn' = [sentOn EXCEPT ![c] = @ \cup {m}]
    /\ OnMsg(c, m)
    /\ UNCHANGED <<link, composed, outbox, view, pulling, prompt, resent, env>>

\* The app sends again a message it sent on this connection and has no
\* accepted for yet: its ack timeout, or the user's retry. Once per message.
Resend(m) ==
    LET c == Owner(m) IN
    /\ MessagesCanBeResent
    /\ link[c] = "up" /\ m \in outbox[c] /\ m \in sentOn[c] /\ m \notin resent
    /\ resent' = resent \cup {m}
    /\ OnMsg(c, m)
    /\ UNCHANGED <<link, composed, outbox, sentOn, view, pulling, prompt, env>>

\* The app connects and sends client_hello. The handler subscribes the
\* connection (SubscribeBeforePull), then writes server_hello, and the
\* approval if one is pending.
Connect(c) ==
    /\ link[c] = "down"
    /\ link' = [link EXCEPT ![c] = "hello"]
    /\ sub' = IF SubscribeBeforePull THEN [sub EXCEPT ![c] = "yes"] ELSE sub
    /\ wire' = [wire EXCEPT ![c] = <<<<"hello_ok", None>>>>
                                   \o (IF appr = "pending" THEN <<<<"appr", None>>>> ELSE <<>>)]
    /\ UNCHANGED <<composed, outbox, sentOn, view, pulling, prompt, resent, endpoint, queue,
                   store, env, obs>>

\* The connection drops, and what is on its way to the app is lost. The
\* handler exits and the Endpoint's monitor takes it out of the fan-out.
Drop(c) ==
    /\ ClientsCanDisconnect /\ dropsLeft > 0 /\ link[c] /= "down"
    /\ dropsLeft' = dropsLeft - 1
    /\ link' = [link EXCEPT ![c] = "down"]
    /\ wire' = [wire EXCEPT ![c] = <<>>]
    /\ sub' = [sub EXCEPT ![c] = "no"]
    /\ sentOn' = [sentOn EXCEPT ![c] = {}]
    /\ pulling' = [pulling EXCEPT ![c] = FALSE]
    /\ prompt' = [prompt EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<composed, outbox, view, resent, endpoint, queue, store, cancelsLeft, obs>>

\* The user answers the approval the app shows.
Answer(c) ==
    /\ prompt[c] /\ link[c] = "up"
    /\ prompt' = [prompt EXCEPT ![c] = FALSE]
    /\ OnAnswer(c)
    /\ UNCHANGED <<link, composed, outbox, sentOn, view, pulling, resent, env>>

\* A user cancels m's turn: either app may cancel any turn of the shared
\* conversation.
Cancel(c, m) ==
    /\ TurnsCanBeCancelled /\ cancelsLeft > 0
    /\ link[c] = "up" /\ m \in composed
    /\ cancelsLeft' = cancelsLeft - 1
    /\ OnCancel(m)
    /\ UNCHANGED <<app, dropsLeft>>

\* server_hello: the app pulls after its cursor (SeqCursor).
OnServerHello(c, rest) ==
    /\ link' = [link EXCEPT ![c] = "up"]
    /\ pulling' = [pulling EXCEPT ![c] = SeqCursor]
    /\ IF SeqCursor THEN Pull(c, rest, Cursor(c))
       ELSE wire' = [wire EXCEPT ![c] = rest] /\ UNCHANGED sub
    /\ UNCHANGED <<composed, outbox, sentOn, view, prompt, resent>>

\* A live row. With the cursor: the next seq is shown, one at or below the
\* cursor is a duplicate and dropped, and one past a gap is dropped and the
\* gap pulled, unless a pull is already out (its page, or a later gap,
\* covers it). Without: every row is shown as it comes.
OnRow(c, s, rest) ==
    /\ IF ~SeqCursor \/ s = Cursor(c) + 1
       THEN /\ view' = [view EXCEPT ![c] = Append(@, s)]
            /\ wire' = [wire EXCEPT ![c] = rest]
            /\ UNCHANGED <<pulling, sub>>
       ELSE IF s <= Cursor(c) \/ pulling[c]
       THEN /\ wire' = [wire EXCEPT ![c] = rest]
            /\ UNCHANGED <<view, pulling, sub>>
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
               /\ UNCHANGED sub
       /\ UNCHANGED <<link, composed, outbox, sentOn, prompt, resent>>

\* The app reads the next server event.
AppRead(c) ==
    /\ wire[c] /= <<>>
    /\ LET ev == Head(wire[c])
           rest == Tail(wire[c])
       IN CASE ev[1] = "hello_ok" -> OnServerHello(c, rest)
            [] ev[1] = "row" -> OnRow(c, ev[2], rest)
            [] ev[1] = "page" -> OnPage(c, ev[2], rest)
            [] ev[1] = "acc" ->
                 /\ outbox' = [outbox EXCEPT ![c] = @ \ {ev[2]}]
                 /\ wire' = [wire EXCEPT ![c] = rest]
                 /\ UNCHANGED <<link, composed, sentOn, view, pulling, prompt, resent, sub>>
            [] ev[1] \in {"appr", "resolved"} ->
                 /\ prompt' = [prompt EXCEPT ![c] = (ev[1] = "appr")]
                 /\ wire' = [wire EXCEPT ![c] = rest]
                 /\ UNCHANGED <<link, composed, outbox, sentOn, view, pulling, resent, sub>>
    /\ UNCHANGED <<endpoint, queue, store, env, obs>>

\* Without SubscribeBeforePull: the handler joins the fan-out after it
\* answered the first pull (Endpoint.subscribe, a call of its own).
Join(c) ==
    /\ sub[c] = "joining"
    /\ sub' = [sub EXCEPT ![c] = "yes"]
    /\ UNCHANGED <<app, wire, endpoint, queue, store, env, obs>>

-----------------------------------------------------------------------------
(* The Endpoint's own mailbox                                               *)

\* The Endpoint handles its next mailbox message.
\*  - {:completed} (turn_result_fn): the assistant row is appended (one Repo
\*    call) and fanned out as text_done{server_seq}.
\*  - {:cancelled}: turn_error{cancelled}, live only.
\*  - The job's delivery notice: its row is fanned out.
EndpointNext ==
    /\ epbox /= <<>>
    /\ epbox' = Tail(epbox)
    /\ LET ev == Head(epbox) IN
       CASE ev[1] = "completed" ->
              /\ tl' = Append(tl, NextSeq)
              /\ wire' = Fanout(<<"row", NextSeq>>)
              /\ ends' = [ends EXCEPT ![ev[2]] = Append(@, "done")]
         [] ev[1] = "cancelled" ->
              /\ ends' = [ends EXCEPT ![ev[2]] = Append(@, "cancelled")]
              /\ UNCHANGED <<tl, wire>>
         [] ev[1] = "delivered" ->
              /\ wire' = Fanout(<<"row", ev[2]>>)
              /\ UNCHANGED <<tl, ends>>
    /\ UNCHANGED <<app, sub, accepted, cancelAsked, appr, apprTurn, applied, queue,
                   job, jobSeq, dseq, env, obs>>

-----------------------------------------------------------------------------
(* The Gateway Queue and its turn tasks, abstract (see the header)          *)

\* A tool call of m's turn needs the owner's approval: the turn waits, and
\* the Endpoint records the approval and fans it out.
Ask(m) ==
    /\ turn[m] = "running" /\ appr = "none" /\ Approvals > 0
    /\ turn' = [turn EXCEPT ![m] = "asking"]
    /\ appr' = "pending" /\ apprTurn' = m
    /\ wire' = Fanout(<<"appr", None>>)
    /\ UNCHANGED <<app, sub, accepted, ends, cancelAsked, epbox, applied, qpending, handed,
                   store, env, obs>>

\* The approval's own timer: nobody answered in time.
ApprovalTimeout ==
    /\ appr = "pending"
    /\ Resolve
    /\ UNCHANGED <<app, sub, accepted, ends, cancelAsked, epbox, apprTurn, qpending, handed,
                   store, env, obs>>

\* m's turn committed its reply and claimed its outcome: from here a stop
\* spares it (claim_active_turn, stop_active_turn).
Claim(m) ==
    /\ turn[m] = "running"
    /\ turn' = [turn EXCEPT ![m] = "claimed"]
    /\ UNCHANGED <<app, conn, endpoint, qpending, handed, store, env, obs>>

\* The turn invokes {:completed} and exits; the Queue's :DOWN frees the slot
\* and starts the next waiting turn (folded in: nothing else can act on the
\* dead turn in between).
Finish(m) ==
    /\ turn[m] = "claimed"
    /\ epbox' = Append(epbox, <<"completed", m>>)
    /\ StartNext(qpending, [turn EXCEPT ![m] = "ended"])
    /\ UNCHANGED <<app, conn, accepted, ends, cancelAsked, appr, apprTurn, applied,
                   handed, store, env, obs>>

-----------------------------------------------------------------------------
(* A scheduled job reporting back: FermixCore.Companion.Timeline, then a    *)
(* notice to the Endpoint                                                   *)

\* Without SeqAssignedOnInsert the job reads the highest seq first.
JobRead ==
    /\ DeliveriesWhileOffline /\ ~SeqAssignedOnInsert /\ job = "idle"
    /\ job' = "read" /\ jobSeq' = MaxOf(Range(tl))
    /\ UNCHANGED <<app, conn, endpoint, queue, tl, dseq, env, obs>>

\* The job inserts its row (one Repo call) and tells the Endpoint.
JobInsert ==
    /\ DeliveriesWhileOffline
    /\ job = IF SeqAssignedOnInsert THEN "idle" ELSE "read"
    /\ LET s == IF SeqAssignedOnInsert THEN NextSeq ELSE jobSeq + 1 IN
       /\ tl' = Append(tl, s)
       /\ dseq' = s
       /\ epbox' = Append(epbox, <<"delivered", s>>)
    /\ job' = "done"
    /\ UNCHANGED <<app, conn, accepted, ends, cancelAsked, appr, apprTurn, applied, queue,
                   jobSeq, env, obs>>

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
    /\ accepted = {}
    /\ ends = [m \in Msgs |-> <<>>]
    /\ cancelAsked = {}
    /\ epbox = <<>>
    /\ appr = "none" /\ apprTurn = None /\ applied = 0
    /\ qpending = <<>>
    /\ turn = [m \in Msgs |-> "none"]
    /\ handed = [m \in Msgs |-> 0]
    /\ tl = <<>> /\ job = "idle" /\ jobSeq = 0 /\ dseq = 0
    /\ dropsLeft = MaxDrops /\ cancelsLeft = MaxCancels
    /\ answeredBy = {} /\ dupWhileRunning = FALSE

\* The legitimate end: every app connected with nothing left to read, no
\* pull outstanding, no handler about to join, the Endpoint's mailbox empty,
\* no turn waiting or alive, no approval pending and no job half-way.
\* Whether the apps show the right rows then is for the rules to say.
\* Deadlock checking is on, so any other state where nothing can happen is
\* reported as a wedge.
Done ==
    /\ \A c \in Clients :
          link[c] = "up" /\ wire[c] = <<>> /\ ~pulling[c] /\ sub[c] /= "joining"
    /\ epbox = <<>> /\ qpending = <<>>
    /\ \A m \in Msgs : turn[m] \notin Live
    /\ appr /= "pending" /\ job /= "read"

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E m \in Msgs : Compose(m) \/ Flush(m) \/ Resend(m) \/ Ask(m) \/ Claim(m) \/ Finish(m)
    \/ \E c \in Clients :
          \/ Connect(c) \/ Drop(c) \/ Answer(c) \/ AppRead(c) \/ Join(c)
          \/ \E m \in Msgs : Cancel(c, m)
    \/ ApprovalTimeout \/ EndpointNext \/ JobRead \/ JobInsert
    \/ Terminated

\* Fairness only on what Fermix drives: the apps' reconnect loop, their
\* reading of the socket and their outbox, the handlers, the Endpoint, a
\* running turn, and the approval's timer. None on users (typing,
\* answering, cancelling, retrying), on drops, or on the job reporting back.
Fairness ==
    /\ \A c \in Clients : WF_vars(Connect(c)) /\ WF_vars(AppRead(c)) /\ WF_vars(Join(c))
    /\ \A m \in Msgs : WF_vars(Flush(m)) /\ WF_vars(Claim(m)) /\ WF_vars(Finish(m))
    /\ WF_vars(EndpointNext) /\ WF_vars(ApprovalTimeout)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* Design claim: a msg is run at most once. Read as: no client_msg_id is ever
\* handed to the Queue twice, however often it reaches the Endpoint.
RunAtMostOnce == \A m \in Msgs : handed[m] <= 1

\* Design claim: a msg is acknowledged at least once. Read as: every message a
\* user typed is eventually acknowledged to the app that sent it.
AckAtLeastOnce ==
    \A m \in Msgs : (m \in composed) ~> (m \notin outbox[Owner(m)])

\* The app c has caught up: connected, subscribed, nothing on its socket, no
\* pull outstanding, and the Endpoint has fanned out every row written.
Quiet(c) ==
    /\ link[c] = "up" /\ sub[c] = "yes"
    /\ wire[c] = <<>> /\ ~pulling[c]
    /\ epbox = <<>>

\* Design claim: a client that reconnects ends up with every row in order,
\* with no gap and no duplicate. Read as: every app shows a prefix of the
\* timeline at all times, and the whole timeline once it has caught up.
TimelineConverges ==
    \A c \in Clients :
        /\ Len(view[c]) <= Len(tl) /\ view[c] = SubSeq(tl, 1, Len(view[c]))
        /\ Quiet(c) => view[c] = tl

\* Design claim: a cancel for a running turn yields turn_error, never a
\* text_done after it for the same turn.
NoDoneAfterCancel ==
    \A m \in Msgs : \A i, j \in 1..Len(ends[m]) :
        (i < j /\ ends[m][i] = "cancelled") => ends[m][j] /= "done"

\* Design claim: an approval is answered exactly once, by whichever client
\* answers first; a late second answer is ignored. Safety half: at most one
\* answer (or its timeout) is ever applied.
ApprovalAnsweredOnce == applied <= 1

\* Design claim: a delivery appended while no client is connected is pulled
\* by the next connect. Read as: every app eventually shows the delivery row.
OfflineDeliveryArrives ==
    \A c \in Clients : (dseq /= 0) ~> (dseq \in Range(view[c]))

\* Design claim: every row gets a strictly increasing server_seq.
SeqStrictlyIncreasing == \A i \in 1..Len(tl) - 1 : tl[i] < tl[i + 1]

\* Design claim (the Queue's rule, as the apps see it): the shared
\* conversation runs one turn at a time, so the wire never streams two turns.
OneTurnOnTheWire == Cardinality({m \in Msgs : turn[m] \in Live}) <= 1

\* Proposed rule: cancel{turn_id} ends only the turn it names. Read as: no
\* turn is told cancelled unless a cancel named it.
CancelEndsOnlyNamedTurn ==
    \A m \in Msgs : "cancelled" \in Range(ends[m]) => m \in cancelAsked

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* Both apps answered the one approval: one answer resolved it, and the
\* other raced it.
Witness_ApprovalRace == ~(answeredBy = Clients)

\* A resend of a message reached the Endpoint while that message's own turn
\* was alive.
Witness_ResendWhileRunning == ~dupWhileRunning

\* Live rows reach an app out of seq order: a row is on its socket behind a
\* row with a higher seq (the job's row is fanned out after a row the
\* Endpoint wrote later).
Witness_LiveRowsOutOfOrder ==
    ~(\E c \in Clients : \E i, j \in 1..Len(wire[c]) :
        /\ i < j /\ wire[c][i][1] = "row" /\ wire[c][j][1] = "row"
        /\ wire[c][j][2] < wire[c][i][2])

\* A page and a live row carry the same row to one app.
Witness_PageOverlapsLive ==
    ~(\E c \in Clients : \E i, j \in 1..Len(wire[c]) :
        /\ wire[c][i][1] = "page" /\ wire[c][j][1] = "row"
        /\ wire[c][j][2] \in Range(wire[c][i][2].rows))

=============================================================================
