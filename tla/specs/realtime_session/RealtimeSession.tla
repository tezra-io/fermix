--------------------------- MODULE RealtimeSession ---------------------------
(***************************************************************************)
(* FermixCore.Realtime.SessionServer for ONE voice call after call_start: *)
(* how a tool result becomes the model's next spoken response, and how   *)
(* the call keeps exactly one upstream OpenAI socket across drops and     *)
(* reconnects.                                                            *)
(*                                                                         *)
(* Processes: the session GenServer and its one mailbox; its tool tasks   *)
(* (async_nolink on the Realtime TaskSupervisor); its reconnect timers;   *)
(* and each upstream socket (a WebSockex process linked to the session)   *)
(* together with the OpenAI conversation behind it.                       *)
(*                                                                         *)
(* Every message a socket sends names it: its events and errors carry     *)
(* self() (OpenAIClient.handle_frame -> notify_parent, openai_client.ex:  *)
(* 436, :459), and its death reaches the session only as its EXIT through *)
(* the link. "disc" below is that EXIT.                                   *)
(* OpenAIClient overrides no handle_disconnect/2. Its SOURCE pin names    *)
(* functions, so that absence is pinned by openai_client_test.exs         *)
(* instead: "a disconnect sends the session nothing", and "a real         *)
(* socket's events name it, ..." for the link over a loopback connection. *)
(*                                                                         *)
(* Assumed of OpenAI, not documented: a response.create rejected because  *)
(* a response is running is rejected before that response's              *)
(* response.done (the response is still running when OpenAI reads the    *)
(* create). The model has it by construction: ProvRead queues the         *)
(* rejection while the response is active, and RespDone queues its done   *)
(* in a later step on the same socket. The re-armed trigger rests on it   *)
(* (handle_active_response_race, session_server.ex:1289-1309).            *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - audio, transcripts, usage and cost limits, the max-session timer,   *)
(*    the screen feed and screen_share (answered inline, no task),       *)
(*    reload_runtime;                                                     *)
(*  - interrupt: its response.cancel only ends the active response early, *)
(*    which RespDone already allows at any time;                          *)
(*  - a tool task crash: its :DOWN is answered exactly like a result      *)
(*    (session_server.ex:402-407), so TaskFinish covers both;             *)
(*  - call_start: the call starts connected on socket 1, configured, with *)
(*    the operator's first response under way;                            *)
(*  - the network between OpenAI and the socket process: an event OpenAI *)
(*    emits lands in the session's mailbox in the same step;              *)
(*  - WebSockex itself (deps/websockex, 0.5.1 in mix.lock; not pinnable): *)
(*    a socket the session closed exits once its close handshake ends, at *)
(*    the latest on its 5 s close timeout (websockex.ex:925-932,          *)
(*    close_loop :732-763, then terminate :1135-1159), or at once when    *)
(*    its connection is already gone (:934-935); CloseDone may come at    *)
(*    any time. A failed handshake leaves no socket                       *)
(*    (handle_initial_conn_failure defaults to false, websockex.ex:610).  *)
(*    WebSockex does not trap exits, so any non-normal exit of the        *)
(*    session kills its sockets through the link: end_call and call_stop  *)
(*    exit with {:shutdown, _} (:665-669, :277-288), and a crash or a     *)
(*    supervisor shutdown is non-normal too. terminate/2 also closes      *)
(*    openai_pid (:499-513);                                              *)
(*  - SessionServer.handle_provider_event/2 (session_server.ex:95): a     *)
(*    test seam nothing in lib calls. It acts on an event without the pid *)
(*    check, so NoFreeze, NoStrayTimer and NoTickWhileConnected hold only *)
(*    while it stays one.                                                 *)
(*                                                                         *)
(* One step = one session callback, one tool task finishing, one timer    *)
(* firing, or one thing OpenAI or the network does.                       *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/realtime/session_server.ex @ 273bc3f99163
\* SOURCE: apps/fermix_core/lib/fermix_core/realtime/openai_client.ex#start_link,send_event,close,turn_detection,decode_server_event,handle_frame,handle_cast,notify_parent @ c095cbe0ed9b
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Calls,          \* the tool calls the model may make, e.g. {c1, c2}; each at most once
    MaxSockets,     \* upstream sockets the call may open, socket 1 included. Past it,
                    \* every further open fails, as if the network were down.
    MaxAttempts,    \* Len(reconnect_backoff_ms): 3 in production (session_server.ex:53)
    None,
    \* Environment: what OpenAI, the network and the operator may do.
    Drops,          \* how many times the network or OpenAI may drop an open socket
    VadTurns,       \* how many more responses server VAD may start on the operator's
                    \* speech (turn_detection create_response: true, openai_client.ex:423)
    OpensCanFail,   \* a reconnect's WebSocket handshake fails (start_link returns an error)
    UpdatesCanFail, \* a reconnect's socket opens, but sending session.update to it fails
    UsersCanStop,   \* the operator ends the call (call_stop, session_server.ex:277)
    LateVadCreated, \* a VAD response takes its context in one step and OpenAI emits its
                    \* response.created in a later one; FALSE emits it in the same step
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off only by the checks that show a property needs it.
    DefersWhileCallsPending,   \* finish_tool_turn holds the trigger while other calls
                               \* of the batch are in flight (session_server.ex:1263)
    DefersWhileResponseActive, \* ... and while OpenAI's response is active; the
                               \* response.done then sends it (:1267, flush_deferred_response :1276)
    RearmsOnRejection,         \* a response.create OpenAI rejected for an active response
                               \* is owed again (handle_active_response_race, :1302)
    CancelsToolsOnReconnect,   \* schedule_reconnect kills in-flight tool tasks, and
                               \* Task.shutdown flushes their replies (:604 -> :681-682)
    ClosesUnconfigured,        \* resume_provider_session closes a socket whose
                               \* session.update failed (:649)
    EndsWhenExhausted,         \* no reconnect left ends the call (end_call, :665)
    ResetsAttemptsOnSuccess,   \* a successful reconnect resets reconnect_attempts (:467)
    OwnSocketOnly              \* only openai_pid's events, errors and EXIT are acted on;
                               \* any other socket's are dropped (:385, :425, :434, :440)

VARIABLES
    \* the session GenServer
    alive,        \* the session process is running
    mbox,         \* its mailbox: one FIFO, in arrival order, of <<kind, socket, call>>
    sock,         \* openai_pid: the socket the session sends to, or None
    ready,        \* provider_ready?: the current socket's session.updated was handled
    attempts,     \* reconnect_attempts
    timer,        \* reconnect_timer: "none", "armed", or "fired" (its message is queued)
    stray,        \* armed reconnect timers the session holds no ref for any more
    pending,      \* pending_tool_calls
    respActive,   \* response_active?: the session's mirror of OpenAI's response
    needsResp,    \* needs_response?: a response.create is owed
    \* the tool tasks
    task,         \* task[c]: "idle", "running", "replied" (its result is queued),
                  \* "done" (answered), "killed"
    \* each upstream socket and the conversation behind it
    sstate,       \* sstate[k]: "unused", "open", "closing" (the session closed it), "gone"
    up,           \* up[k]: client events the session sent on k, not yet read by OpenAI
    pActive,      \* pActive[k]: k's conversation has a response in progress
    vadOwed,      \* vadOwed[k]: k's VAD response has not emitted response.created yet
    issuer,       \* issuer[c]: the conversation whose response called c
    out,          \* out[c]: "none", "appended", or "answered" (a response started after it)
    outAt,        \* outAt[c]: the conversation c's output was appended to
    dropsLeft,    \* environment budget: socket drops still allowed
    vadLeft,      \* environment budget: VAD responses still allowed
    \* bookkeeping
    rejected,     \* OpenAI rejected a response.create: a response was already active
    tries,        \* reconnect attempts run since the call was last connected
    ended         \* why the session ended: "none", "stop", "exhausted"

session  == <<alive, mbox, sock, ready, attempts, timer, stray, pending, respActive, needsResp>>
sockets  == <<sstate, up>>
provider == <<pActive, vadOwed, issuer, out, outAt, dropsLeft, vadLeft, rejected>>
book     == <<tries, ended>>
vars == <<session, task, sockets, provider, book>>

SockIds == 1..MaxSockets
ClientEvents == ({"create", "update"} \X {None}) \cup ({"out"} \X Calls)
Msgs ==
    ({"created", "done", "reject", "updated", "disc"} \X SockIds \X {None})
    \cup ({"call"} \X SockIds \X Calls)
    \cup ({"result"} \X {None} \X Calls)
    \cup ({"tick"} \X {None} \X {None})

TypeOK ==
    /\ alive \in BOOLEAN
    /\ mbox \in Seq(Msgs)
    /\ sock \in SockIds \cup {None}
    /\ ready \in BOOLEAN
    /\ attempts \in 0..MaxAttempts
    /\ timer \in {"none", "armed", "fired"}
    /\ stray \in Nat
    /\ pending \subseteq Calls
    /\ respActive \in BOOLEAN /\ needsResp \in BOOLEAN
    /\ task \in [Calls -> {"idle", "running", "replied", "done", "killed"}]
    /\ sstate \in [SockIds -> {"unused", "open", "closing", "gone"}]
    /\ \A k \in SockIds : up[k] \in Seq(ClientEvents)
    /\ pActive \in [SockIds -> BOOLEAN]
    /\ vadOwed \in [SockIds -> BOOLEAN]
    /\ issuer \in [Calls -> SockIds \cup {None}]
    /\ out \in [Calls -> {"none", "appended", "answered"}]
    /\ outAt \in [Calls -> SockIds \cup {None}]
    /\ dropsLeft \in 0..Drops /\ vadLeft \in 0..VadTurns
    /\ rejected \in BOOLEAN /\ tries \in Nat
    /\ ended \in {"none", "stop", "exhausted"}

-----------------------------------------------------------------------------
(* Helpers *)

Range(s) == {s[i] : i \in 1..Len(s)}

\* The lowest socket id not used yet, or None when the bound is reached.
NextSock ==
    IF \E k \in SockIds : sstate[k] = "unused"
    THEN CHOOSE k \in SockIds : sstate[k] = "unused" /\ \A j \in SockIds : sstate[j] = "unused" => k <= j
    ELSE None

\* Socket k puts one message in the session's mailbox: an event or error
\* (OpenAIClient.handle_frame -> notify_parent, openai_client.ex:436, :459),
\* or its EXIT.
Emit(k, kind, c) == mbox' = Append(mbox, <<kind, k, c>>)

\* send_openai/2 -> OpenAIClient.send_event (session_server.ex:1341,
\* openai_client.ex:65): a call into the socket process, which writes the frames
\* in order. To a socket that is closing or gone, or with no openai_pid
\* (:1345), the send fails and is only reported (send_openai_events).
SendUp(es) ==
    IF sock /= None /\ sstate[sock] = "open"
    THEN up' = [up EXCEPT ![sock] = @ \o es]
    ELSE UNCHANGED up

KillTasks == [c \in Calls |-> IF task[c] \in {"running", "replied"} THEN "killed" ELSE task[c]]

\* Task.shutdown(task, :brutal_kill) also takes the task's reply out of the
\* mailbox (session_server.ex:675-676, :682).
NotResult(m) == m[1] /= "result"

\* terminate/2 (session_server.ex:499-513) and what the exit causes: kill the tool
\* tasks, cancel the timers, close openai_pid. Every socket is linked to the
\* session, which exits with {:shutdown, _}, so every socket dies with it, and
\* nothing reaches a dead session's mailbox. s is sstate as the calling callback
\* left it.
EndSession(why, s) ==
    /\ alive' = FALSE
    /\ ended' = why
    /\ mbox' = <<>>
    /\ sock' = None
    /\ sstate' = [k \in SockIds |-> IF s[k] = "unused" THEN "unused" ELSE "gone"]
    /\ up' = [k \in SockIds |-> <<>>]
    /\ task' = KillTasks
    /\ pending' = {}
    /\ timer' = "none" /\ stray' = 0
    /\ respActive' = FALSE /\ needsResp' = FALSE
    /\ UNCHANGED <<attempts, ready>>

\* schedule_reconnect/1 (session_server.ex:588-630), and end_call/2 (:665) when
\* it returns :exhausted. m and s are the mailbox and sstate as the calling
\* callback left them.
\*  - It does not close openai_pid: its callers reach it only once that socket
\*    is dead, or with none.
\*  - Process.send_after (:617) replaces reconnect_timer. A timer still armed
\*    would fire with no ref left to it; with OwnSocketOnly nothing reaches
\*    here while one is armed (NoStrayTimer).
Reconnect(m, s) ==
    IF attempts < MaxAttempts
    THEN /\ attempts' = attempts + 1
         /\ sock' = None /\ ready' = FALSE
         /\ timer' = "armed"
         /\ stray' = stray + (IF timer = "armed" THEN 1 ELSE 0)
         /\ respActive' = FALSE /\ needsResp' = FALSE
         /\ IF CancelsToolsOnReconnect
            THEN task' = KillTasks /\ pending' = {} /\ mbox' = SelectSeq(m, NotResult)
            ELSE UNCHANGED <<task, pending>> /\ mbox' = m
         /\ sstate' = s
         /\ UNCHANGED <<alive, ended, up>>
    ELSE IF EndsWhenExhausted
    THEN EndSession("exhausted", s)
    \* The teardown end_call replaced: the session lived on with no socket and
    \* no timer (the comment at session_server.ex:656-664).
    ELSE /\ sock' = None /\ ready' = FALSE /\ timer' = "none"
         /\ task' = KillTasks /\ pending' = {} /\ mbox' = SelectSeq(m, NotResult)
         /\ respActive' = FALSE /\ needsResp' = FALSE
         /\ sstate' = s
         /\ UNCHANGED <<alive, ended, stray, up, attempts>>

\* A response starts in k's conversation. It reads the outputs appended so
\* far; the comment at session_server.ex:1252-1262 records that a response
\* "snapshotted context" when it began, so an output appended later is not
\* part of it.
StartResponse(k) ==
    /\ pActive' = [pActive EXCEPT ![k] = TRUE]
    /\ out' = [c \in Calls |-> IF out[c] = "appended" /\ outAt[c] = k THEN "answered" ELSE out[c]]

-----------------------------------------------------------------------------
(* The session GenServer: one callback per message, oldest first *)

\* A message from openai_pid, or from any socket when OwnSocketOnly is off:
\* handle_info({:openai_realtime_event, pid, event}) (session_server.ex:385),
\* and the EXIT clause (:440) for "disc".
OnSocketMsg(msg, rest) ==
    CASE msg[1] = "disc" ->
           \* :440 -> schedule_reconnect, or end_call when exhausted
           /\ Reconnect(rest, sstate)
           /\ UNCHANGED tries
      [] msg[1] = "created" ->
           \* {:response_created, _} (:883)
           /\ respActive' = TRUE
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, needsResp,
                          task, sockets, book>>
      [] msg[1] = "done" ->
           \* {:response_done, _} (:891), ending in flush_deferred_response (:1276)
           /\ respActive' = FALSE
           /\ IF needsResp /\ pending = {}
              THEN needsResp' = FALSE /\ SendUp(<<<<"create", None>>>>)
              ELSE UNCHANGED <<needsResp, up>>
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, task, sstate, book>>
      [] msg[1] = "call" ->
           \* {:function_call, call} (:875) -> dispatch_tool_call (:927)
           /\ task' = [task EXCEPT ![msg[3]] = "running"]
           /\ pending' = pending \cup {msg[3]}
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, respActive, needsResp,
                          sockets, book>>
      [] msg[1] = "reject" ->
           \* {:error, conversation_already_has_active_response} (:902) ->
           \* handle_active_response_race (:1302) owes the trigger again; the
           \* rejecting response's response.done sends it
           /\ needsResp' = (needsResp \/ RearmsOnRejection)
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive,
                          task, sockets, book>>
      [] msg[1] = "updated" ->
           \* {:session_updated, _} (:818-832). The first one for a socket sets
           \* provider_ready? and runs start_timers -> cancel_timers (:1543-1560),
           \* which forgets reconnect_timer: an armed timer is cancelled, and a
           \* fired one's tick stays queued.
           /\ ready' = TRUE
           /\ timer' = IF ready THEN timer ELSE "none"
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, attempts, stray, pending, respActive, needsResp,
                          task, sockets, book>>

\* A message from a socket that is not openai_pid: the catch-all for events and
\* errors (session_server.ex:434) or the EXIT catch-all (:457). Nothing but the
\* mailbox changes.
DropStale(rest) ==
    /\ mbox' = rest
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   task, sockets, book>>

\* A tool task's reply: handle_info({ref, result}) (session_server.ex:393) ->
\* apply_tool_result (:1213) -> append_tool_output (:1237) -> finish_tool_turn
\* (:1263-1274). The output always goes to openai_pid; the trigger goes with
\* it only when nothing defers it.
OnResult(c, rest) ==
    /\ task' = [task EXCEPT ![c] = "done"]
    /\ mbox' = rest
    /\ LET p == pending \ {c} IN
       /\ pending' = p
       /\ IF p /= {} /\ DefersWhileCallsPending
          THEN needsResp' = TRUE /\ SendUp(<<<<"out", c>>>>)
          ELSE IF respActive /\ DefersWhileResponseActive
          THEN needsResp' = TRUE /\ SendUp(<<<<"out", c>>>>)
          ELSE needsResp' = FALSE /\ SendUp(<<<<"out", c>>, <<"create", None>>>>)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, respActive, sstate, book>>

\* handle_info(:reconnect_attempt) (session_server.ex:459-480) ->
\* attempt_reconnect (:632) -> open_openai_session (:517; start_link returns
\* after the handshake) -> resume_provider_session (:643). It does not check
\* whether the call is already connected.
OnTick(rest) ==
    LET k == NextSock IN
    \/ \* the handshake fails, or every allowed socket is used: {:error, _}
       /\ OpensCanFail \/ k = None
       /\ tries' = tries + 1
       /\ Reconnect(rest, sstate)
    \/ \* the socket opens but session.update fails: close it (:649), schedule again
       /\ UpdatesCanFail /\ k /= None
       /\ tries' = tries + 1
       /\ Reconnect(rest, [sstate EXCEPT ![k] = IF ClosesUnconfigured THEN "closing" ELSE "open"])
    \/ \* connected, with session.update on the wire (:462-469); the ref to an
       \* armed timer is dropped
       /\ k /= None
       /\ tries' = 0
       /\ mbox' = rest
       /\ sock' = k /\ ready' = FALSE
       /\ sstate' = [sstate EXCEPT ![k] = "open"]
       /\ up' = [up EXCEPT ![k] = <<<<"update", None>>>>]
       /\ attempts' = IF ResetsAttemptsOnSuccess THEN 0 ELSE attempts
       /\ timer' = "none"
       /\ stray' = stray + (IF timer = "armed" THEN 1 ELSE 0)
       /\ UNCHANGED <<alive, pending, task, respActive, needsResp, ended>>

FromSocket(msg) == msg[1] \notin {"result", "tick"}
Stale(msg) == OwnSocketOnly /\ msg[2] /= sock

\* The session takes the oldest message in its mailbox.
HandleNext ==
    /\ alive
    /\ mbox /= <<>>
    /\ LET msg == Head(mbox)
           rest == Tail(mbox)
       IN CASE msg[1] = "result" -> OnResult(msg[3], rest)
            [] msg[1] = "tick" -> OnTick(rest)
            [] FromSocket(msg) /\ Stale(msg) -> DropStale(rest)
            [] FromSocket(msg) /\ ~Stale(msg) -> OnSocketMsg(msg, rest)
    /\ UNCHANGED provider

\* Process.send_after(self(), :reconnect_attempt, delay) (session_server.ex:617) fires.
TimerFires ==
    /\ alive /\ timer = "armed"
    /\ timer' = "fired"
    /\ mbox' = Append(mbox, <<"tick", None, None>>)
    /\ UNCHANGED <<alive, sock, ready, attempts, stray, pending, respActive, needsResp,
                   task, sockets, provider, book>>

\* A timer whose ref the session dropped fires all the same.
StrayFires ==
    /\ alive /\ stray > 0
    /\ stray' = stray - 1
    /\ mbox' = Append(mbox, <<"tick", None, None>>)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, pending, respActive, needsResp,
                   task, sockets, provider, book>>

\* handle_call(:call_stop) (session_server.ex:277) -> {:stop, ...} -> terminate/2.
\* Modelled as handled at any moment, ahead of anything queued. Ending the call
\* early only removes behaviour, so no property can pass because of it.
Stop ==
    /\ UsersCanStop /\ alive
    /\ EndSession("stop", sstate)
    /\ UNCHANGED <<provider, tries>>

-----------------------------------------------------------------------------
(* A tool task *)

\* ToolBridge.execute_call returns; the reply lands in the session's mailbox.
TaskFinish(c) ==
    /\ alive /\ task[c] = "running"
    /\ task' = [task EXCEPT ![c] = "replied"]
    /\ mbox' = Append(mbox, <<"result", None, c>>)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   sockets, provider, book>>

-----------------------------------------------------------------------------
(* OpenAI and the network, per socket *)

\* OpenAI reads the next client event on k.
\*  - A function_call_output joins the conversation.
\*  - A session.update is answered with session.updated.
\*  - A response.create starts a response, or is rejected with
\*    conversation_already_has_active_response while one is active.
ProvRead(k) ==
    /\ alive /\ sstate[k] = "open" /\ up[k] /= <<>>
    /\ LET e == Head(up[k]) IN
       /\ up' = [up EXCEPT ![k] = Tail(@)]
       /\ CASE e[1] = "out" ->
                 /\ out' = [out EXCEPT ![e[2]] = "appended"]
                 /\ outAt' = [outAt EXCEPT ![e[2]] = k]
                 /\ UNCHANGED <<pActive, rejected, mbox>>
            [] e[1] = "update" ->
                 /\ Emit(k, "updated", None)
                 /\ UNCHANGED <<pActive, out, outAt, rejected>>
            [] e[1] = "create" /\ pActive[k] ->
                 /\ rejected' = TRUE
                 /\ Emit(k, "reject", None)
                 /\ UNCHANGED <<pActive, out, outAt>>
            [] e[1] = "create" /\ ~pActive[k] ->
                 /\ StartResponse(k)
                 /\ Emit(k, "created", None)
                 /\ UNCHANGED <<rejected, outAt>>
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   task, sstate, vadOwed, issuer, dropsLeft, vadLeft, book>>

\* Server VAD commits the operator's speech and starts a response
\* (create_response: true, openai_client.ex:423). Audio only goes to openai_pid.
\* With LateVadCreated its response.created leaves OpenAI in a later step.
Vad ==
    /\ vadLeft > 0
    /\ alive /\ sock /= None /\ sstate[sock] = "open" /\ ~pActive[sock]
    /\ vadLeft' = vadLeft - 1
    /\ StartResponse(sock)
    /\ IF LateVadCreated
       THEN vadOwed' = [vadOwed EXCEPT ![sock] = TRUE] /\ UNCHANGED mbox
       ELSE Emit(sock, "created", None) /\ UNCHANGED vadOwed
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   task, sockets, issuer, outAt, dropsLeft, rejected, book>>

\* The VAD response's response.created leaves OpenAI (LateVadCreated only).
VadCreated(k) ==
    /\ alive /\ sstate[k] = "open" /\ vadOwed[k]
    /\ vadOwed' = [vadOwed EXCEPT ![k] = FALSE]
    /\ Emit(k, "created", None)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   task, sockets, pActive, issuer, out, outAt, dropsLeft, vadLeft, rejected, book>>

\* The active response calls tool c (response.function_call_arguments.done,
\* openai_client.ex:393).
EmitCall(k, c) ==
    /\ alive /\ sstate[k] = "open" /\ pActive[k] /\ ~vadOwed[k] /\ issuer[c] = None
    /\ issuer' = [issuer EXCEPT ![c] = k]
    /\ Emit(k, "call", c)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   task, sockets, pActive, vadOwed, out, outAt, dropsLeft, vadLeft, rejected,
                   book>>

\* The response ends: completed, or cancelled by an interrupt or by VAD
\* (interrupt_response: true, openai_client.ex:424).
RespDone(k) ==
    /\ alive /\ sstate[k] = "open" /\ pActive[k] /\ ~vadOwed[k]
    /\ pActive' = [pActive EXCEPT ![k] = FALSE]
    /\ Emit(k, "done", None)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   task, sockets, vadOwed, issuer, out, outAt, dropsLeft, vadLeft, rejected, book>>

\* OpenAI or the network drops an open socket. WebSockex runs the default
\* handle_disconnect and the process exits; the link hands the session its
\* EXIT.
Drop(k) ==
    /\ alive /\ dropsLeft > 0 /\ sstate[k] = "open"
    /\ dropsLeft' = dropsLeft - 1
    /\ sstate' = [sstate EXCEPT ![k] = "gone"]
    /\ pActive' = [pActive EXCEPT ![k] = FALSE]
    /\ vadOwed' = [vadOwed EXCEPT ![k] = FALSE]
    /\ up' = [up EXCEPT ![k] = <<>>]
    /\ Emit(k, "disc", None)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   task, issuer, out, outAt, vadLeft, rejected, book>>

\* A socket the session closed (OpenAIClient.close -> {:close, state},
\* openai_client.ex:102, :457) finishes its close handshake or hits the 5 s
\* close timeout, then exits like any other (websockex.ex:925-931).
CloseDone(k) ==
    /\ alive /\ sstate[k] = "closing"
    /\ sstate' = [sstate EXCEPT ![k] = "gone"]
    /\ Emit(k, "disc", None)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   task, up, provider, book>>

-----------------------------------------------------------------------------
Init ==
    /\ alive = TRUE
    /\ mbox = <<<<"created", 1, None>>>>
    /\ sock = 1 /\ ready = TRUE
    /\ attempts = 0 /\ timer = "none" /\ stray = 0
    /\ pending = {} /\ respActive = FALSE /\ needsResp = FALSE
    /\ task = [c \in Calls |-> "idle"]
    /\ sstate = [k \in SockIds |-> IF k = 1 THEN "open" ELSE "unused"]
    /\ up = [k \in SockIds |-> <<>>]
    /\ pActive = [k \in SockIds |-> k = 1]
    /\ vadOwed = [k \in SockIds |-> FALSE]
    /\ issuer = [c \in Calls |-> None]
    /\ out = [c \in Calls |-> "none"]
    /\ outAt = [c \in Calls |-> None]
    /\ dropsLeft = Drops /\ vadLeft = VadTurns
    /\ rejected = FALSE /\ tries = 0 /\ ended = "none"

\* The legitimate ends: the session has exited, or the call is connected and
\* idle, with an empty mailbox, no tool task running and no reconnect timer.
\* Deadlock checking is on, so any other state where nothing can happen is
\* reported as a wedge.
Done ==
    \/ ~alive
    \/ /\ sock /= None
       /\ mbox = <<>>
       /\ \A c \in Calls : task[c] /= "running"
       /\ timer = "none" /\ stray = 0

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ HandleNext \/ TimerFires \/ StrayFires \/ Stop
    \/ \E c \in Calls : TaskFinish(c)
    \/ \E k \in SockIds :
          \/ ProvRead(k) \/ RespDone(k) \/ Drop(k) \/ CloseDone(k) \/ VadCreated(k)
          \/ \E c \in Calls : EmitCall(k, c)
    \/ Vad
    \/ Terminated

\* Fairness only on what Fermix drives: the session's callbacks, its tool
\* tasks and its timers. None on OpenAI, the network or the operator. Every
\* property below is an invariant, so no verdict rests on it.
Fairness ==
    /\ WF_vars(HandleNext) /\ WF_vars(TimerFires) /\ WF_vars(StrayFires)
    /\ \A c \in Calls : WF_vars(TaskFinish(c))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* The call has settled: the mailbox is empty, nothing waits on the wire to
\* openai_pid, no tool task is running, no response is running and no
\* reconnect is under way. The model stays silent until the operator speaks
\* again. A trigger may still be owed; NoSilentStall asks whether one was lost.
Settled ==
    /\ alive /\ sock /= None /\ sstate[sock] = "open"
    /\ mbox = <<>>
    /\ up[sock] = <<>>
    /\ \A c \in Calls : task[c] /= "running"
    /\ ~pActive[sock]
    /\ timer = "none"

\* finish_tool_turn (session_server.ex:1252-1262): racing triggers left "a
\* silent stall until the operator spoke again". Read as: once the call has
\* settled, every tool output in the live conversation has had a response
\* start after it.
NoSilentStall ==
    Settled => \A c \in Calls : ~(out[c] = "appended" /\ outAt[c] = sock)

\* finish_tool_turn (session_server.ex:1252-1262): "a trigger sent before its
\* response.done is the race itself", and the deferral "avoids every rejection
\* the session can foresee". Read as: with no server-VAD response the session
\* has not heard of, OpenAI never rejects a response.create.
NoRejectedTrigger == ~rejected

\* schedule_reconnect (session_server.ex:596-598): abandon in-flight tool tasks
\* "rather than let a late result fire at (or tear down) the new session".
\* Read as: a tool output only ever joins the conversation that called it.
LateResultStaysHome ==
    \A c \in Calls : out[c] /= "none" => outAt[c] = issuer[c]

\* resume_provider_session (session_server.ex:639-642): leaving an unconfigured
\* socket open "leaks an upstream connection per retry". Read as: while the
\* call lives, every open socket is openai_pid.
NoOrphanSocket ==
    alive => \A k \in SockIds : sstate[k] = "open" => k = sock

\* end_call (session_server.ex:656-664) makes a live call with no provider
\* connection "unrepresentable"; audio_chunk (:326-327): "openai_pid is nil
\* ONLY inside the bounded reconnect window". Read as: a live session has a
\* socket, or a reconnect timer on the way.
NoFreeze ==
    alive => sock /= None \/ timer /= "none"

\* Proposed rule: @default_reconnect_backoff_ms (session_server.ex:53) names one
\* delay per attempt, so a call gives up on OpenAI only after running every
\* attempt.
EveryAttemptTried ==
    ended = "exhausted" => tries >= MaxAttempts

\* Proposed rule, the one the cancel that schedule_reconnect used to carry
\* stood in for: a reconnect timer is outstanding only while openai_pid is nil,
\* and the session holds the ref of every timer that can still fire.
NoStrayTimer ==
    stray = 0 /\ (timer /= "none" => sock = None)

\* Proposed rule: handle_info(:reconnect_attempt) (session_server.ex:459) has no
\* guard, so a tick that reached a connected call would open a second socket and
\* orphan the first. No tick is ever queued while the call is connected.
NoTickWhileConnected ==
    ~(alive /\ sock /= None /\ <<"tick", None, None>> \in Range(mbox))

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* OpenAI rejects a trigger: a VAD response started before the session heard
\* of it (RT-1). The re-armed trigger answers it; this shows it still happens.
Witness_RejectedTrigger == ~rejected

=============================================================================
