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
(* Not modelled:                                                           *)
(*  - audio, transcripts, usage and cost limits, the max-session timer,   *)
(*    the screen feed and screen_share (answered inline, no task),       *)
(*    reload_runtime;                                                     *)
(*  - interrupt: its response.cancel only ends the active response early, *)
(*    which RespDone already allows at any time;                          *)
(*  - a tool task crash: its :DOWN is answered exactly like a result      *)
(*    (session_server.ex:400-405), so TaskFinish covers both;             *)
(*  - a socket's EXIT: its disconnect notice always comes first (both     *)
(*    come from the socket process, in order), and the EXIT clause        *)
(*    (session_server.ex:443) matches only openai_pid, which the notice   *)
(*    has already cleared;                                                *)
(*  - call_start: the call starts connected on socket 1, with the         *)
(*    operator's first response under way;                                *)
(*  - the network between OpenAI and the socket process: an event OpenAI *)
(*    emits lands in the session's mailbox in the same step;              *)
(*  - WebSockex itself (deps/websockex, 0.5.1 in mix.lock; not pinnable): *)
(*    a closed socket reports its disconnect only after the close         *)
(*    handshake or its 5 s timeout (websockex.ex:925-931 -> on_disconnect *)
(*    -> handle_disconnect); a failed handshake reports nothing           *)
(*    (handle_initial_conn_failure defaults to false, websockex.ex:610);  *)
(*    a socket dies with its parent (websockex.ex:740).                   *)
(*                                                                         *)
(* One step = one session callback, one tool task finishing, one timer    *)
(* firing, or one thing OpenAI or the network does.                       *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/realtime/session_server.ex @ 90449a1a7c1d
\* SOURCE: apps/fermix_core/lib/fermix_core/realtime/openai_client.ex#start_link,send_event,close,turn_detection,decode_server_event,handle_frame,handle_cast,handle_disconnect,notify_parent @ cd3cc875ab8b
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
                    \* speech (turn_detection create_response: true, openai_client.ex:417)
    OpensCanFail,   \* a reconnect's WebSocket handshake fails (start_link returns an error)
    UpdatesCanFail, \* a reconnect's socket opens, but sending session.update to it fails
    UsersCanStop,   \* the operator ends the call (call_stop, session_server.ex:275)
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by exactly one check to show a property needs it.
    DefersWhileCallsPending,   \* finish_tool_turn holds the trigger while other calls
                               \* of the batch are in flight (session_server.ex:1267)
    DefersWhileResponseActive, \* ... and while OpenAI's response is active; the
                               \* response.done then sends it (:1271, flush_deferred_response :1280)
    CancelsToolsOnReconnect,   \* schedule_reconnect kills in-flight tool tasks, and
                               \* Task.shutdown flushes their replies (:607 -> :687-688)
    ClosesUnconfigured,        \* resume_provider_session closes a socket whose
                               \* session.update failed (:655)
    EndsWhenExhausted,         \* no reconnect left ends the call (end_call, :671)
    ResetsAttemptsOnSuccess,   \* a successful reconnect resets reconnect_attempts (:470)
    \* Timing idealisation. TRUE is the real code. FALSE makes a socket the session
    \* closed report its disconnect before any reconnect timer fires. WebSockex
    \* waits up to 5 s for the close handshake (websockex.ex:931); the first
    \* backoff delays are 1 s and 2 s (session_server.ex:53).
    LateCloseNotice

VARIABLES
    \* the session GenServer
    alive,        \* the session process is running
    mbox,         \* its mailbox: one FIFO, in arrival order, of <<kind, socket, call>>
    sock,         \* openai_pid: the socket the session sends to, or None
    attempts,     \* reconnect_attempts
    timer,        \* reconnect_timer: "none", "armed", or "fired" (its message is queued)
    stray,        \* armed reconnect timers the session holds no ref for any more
    pending,      \* pending_tool_calls
    respActive,   \* response_active?: the session's mirror of OpenAI's response
    needsResp,    \* needs_response?: a tool output still owes its response.create
    \* the tool tasks
    task,         \* task[c]: "idle", "running", "replied" (its result is queued),
                  \* "done" (answered), "killed"
    \* each upstream socket and the conversation behind it
    sstate,       \* sstate[k]: "unused", "open", "closing" (the session closed it), "gone"
    up,           \* up[k]: client events the session sent on k, not yet read by OpenAI
    pActive,      \* pActive[k]: k's conversation has a response in progress
    issuer,       \* issuer[c]: the conversation whose response called c
    out,          \* out[c]: "none", "appended", or "answered" (a response started after it)
    outAt,        \* outAt[c]: the conversation c's output was appended to
    dropsLeft,    \* environment budget: socket drops still allowed
    vadLeft,      \* environment budget: VAD responses still allowed
    \* bookkeeping
    rejected,     \* OpenAI rejected a response.create: a response was already active
    tries,        \* reconnect attempts run since the call was last connected
    ended         \* why the session ended: "none", "stop", "exhausted"

session  == <<alive, mbox, sock, attempts, timer, stray, pending, respActive, needsResp>>
sockets  == <<sstate, up>>
provider == <<pActive, issuer, out, outAt, dropsLeft, vadLeft, rejected>>
book     == <<tries, ended>>
vars == <<session, task, sockets, provider, book>>

SockIds == 1..MaxSockets
ClientEvents == ({"create"} \X {None}) \cup ({"out"} \X Calls)
Msgs ==
    ({"created", "done", "reject", "disc"} \X SockIds \X {None})
    \cup ({"call"} \X SockIds \X Calls)
    \cup ({"result"} \X {None} \X Calls)
    \cup ({"tick"} \X {None} \X {None})

TypeOK ==
    /\ alive \in BOOLEAN
    /\ mbox \in Seq(Msgs)
    /\ sock \in SockIds \cup {None}
    /\ attempts \in 0..MaxAttempts
    /\ timer \in {"none", "armed", "fired"}
    /\ stray \in Nat
    /\ pending \subseteq Calls
    /\ respActive \in BOOLEAN /\ needsResp \in BOOLEAN
    /\ task \in [Calls -> {"idle", "running", "replied", "done", "killed"}]
    /\ sstate \in [SockIds -> {"unused", "open", "closing", "gone"}]
    /\ \A k \in SockIds : up[k] \in Seq(ClientEvents)
    /\ pActive \in [SockIds -> BOOLEAN]
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

\* Socket k puts one event in the session's mailbox (OpenAIClient.handle_frame
\* -> notify_parent, openai_client.ex:430, :455; handle_disconnect, :450).
Emit(k, kind, c) == mbox' = Append(mbox, <<kind, k, c>>)

\* send_openai/2 -> OpenAIClient.send_event (session_server.ex:1328,
\* openai_client.ex:59): a call into the socket process, which writes the frames
\* in order. To a socket that is closing or gone, or with no openai_pid
\* (:1332), the send fails and is only reported (send_openai_events).
SendUp(es) ==
    IF sock /= None /\ sstate[sock] = "open"
    THEN up' = [up EXCEPT ![sock] = @ \o es]
    ELSE UNCHANGED up

KillTasks == [c \in Calls |-> IF task[c] \in {"running", "replied"} THEN "killed" ELSE task[c]]

\* Task.shutdown(task, :brutal_kill) also takes the task's reply out of the
\* mailbox (session_server.ex:681-682, :688).
NotResult(m) == m[1] /= "result"

\* terminate/2 (session_server.ex:502-516) and what the exit causes: kill the tool
\* tasks, cancel the timers, close openai_pid. Every socket is linked to the
\* session and dies with it (websockex.ex:740), and nothing reaches a dead
\* session's mailbox. s is sstate as the calling callback left it.
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
    /\ UNCHANGED attempts

\* schedule_reconnect/1 (session_server.ex:591-635), and end_call/2 (:671) when
\* it returns :exhausted. m and s are the mailbox and sstate as the calling
\* callback left them.
\*  - It does not close openai_pid: it assumes the notice came from that socket.
\*  - It cancels an armed timer (:623). A timer that already fired has its
\*    message queued, and Process.cancel_timer does not take it back.
Reconnect(m, s) ==
    IF attempts < MaxAttempts
    THEN /\ attempts' = attempts + 1
         /\ sock' = None
         /\ timer' = "armed"
         /\ respActive' = FALSE /\ needsResp' = FALSE
         /\ IF CancelsToolsOnReconnect
            THEN task' = KillTasks /\ pending' = {} /\ mbox' = SelectSeq(m, NotResult)
            ELSE UNCHANGED <<task, pending>> /\ mbox' = m
         /\ sstate' = s
         /\ UNCHANGED <<alive, ended, stray, up>>
    ELSE IF EndsWhenExhausted
    THEN EndSession("exhausted", s)
    \* The teardown end_call replaced: the session lived on with no socket and
    \* no timer (the comment at session_server.ex:662-670).
    ELSE /\ sock' = None /\ timer' = "none"
         /\ task' = KillTasks /\ pending' = {} /\ mbox' = SelectSeq(m, NotResult)
         /\ respActive' = FALSE /\ needsResp' = FALSE
         /\ sstate' = s
         /\ UNCHANGED <<alive, ended, stray, up, attempts>>

\* A response starts in k's conversation. It reads the outputs appended so
\* far; the comment at session_server.ex:1260-1266 records that a response
\* "snapshotted context" when it began, so an output appended later is not
\* part of it.
StartResponse(k) ==
    /\ pActive' = [pActive EXCEPT ![k] = TRUE]
    /\ out' = [c \in Calls |-> IF out[c] = "appended" /\ outAt[c] = k THEN "answered" ELSE out[c]]

-----------------------------------------------------------------------------
(* The session GenServer: one callback per message, oldest first *)

\* handle_info({:openai_realtime_event, event}) (session_server.ex:383) and
\* handle_info({:openai_realtime_disconnect, _}) (:422): neither checks which
\* socket sent the message, so an event or a notice from any socket is handled
\* as if it came from openai_pid.
OnSocketMsg(msg, rest) ==
    CASE msg[1] = "disc" ->
           \* :422 -> schedule_reconnect, or end_call when exhausted
           /\ Reconnect(rest, sstate)
           /\ UNCHANGED tries
      [] msg[1] = "created" ->
           \* {:response_created, _} (:889)
           /\ respActive' = TRUE
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, attempts, timer, stray, pending, needsResp,
                          task, sockets, book>>
      [] msg[1] = "done" ->
           \* {:response_done, _} (:897), ending in flush_deferred_response (:1280)
           /\ respActive' = FALSE
           /\ IF needsResp /\ pending = {}
              THEN needsResp' = FALSE /\ SendUp(<<<<"create", None>>>>)
              ELSE UNCHANGED <<needsResp, up>>
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, attempts, timer, stray, pending, task, sstate, book>>
      [] msg[1] = "call" ->
           \* {:function_call, call} (:881) -> dispatch_tool_call (:933)
           /\ task' = [task EXCEPT ![msg[3]] = "running"]
           /\ pending' = pending \cup {msg[3]}
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, attempts, timer, stray, respActive, needsResp,
                          sockets, book>>
      [] msg[1] = "reject" ->
           \* {:error, conversation_already_has_active_response} (:908):
           \* handle_active_response_race only logs it (:1293)
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, attempts, timer, stray, pending, respActive, needsResp,
                          task, sockets, book>>

\* A tool task's reply: handle_info({ref, result}) (session_server.ex:391) ->
\* apply_tool_result (:1219) -> append_tool_output (:1243) -> finish_tool_turn
\* (:1267-1278). The output always goes to openai_pid; the trigger goes with
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
    /\ UNCHANGED <<alive, sock, attempts, timer, stray, respActive, sstate, book>>

\* handle_info(:reconnect_attempt) (session_server.ex:462-483) ->
\* attempt_reconnect (:639) -> open_openai_session (:520; start_link returns
\* after the handshake) -> resume_provider_session (:649). It does not check
\* whether the call is already connected.
OnTick(rest) ==
    LET k == NextSock IN
    \/ \* the handshake fails, or every allowed socket is used: {:error, _}
       /\ OpensCanFail \/ k = None
       /\ tries' = tries + 1
       /\ Reconnect(rest, sstate)
    \/ \* the socket opens but session.update fails: close it (:655), schedule again
       /\ UpdatesCanFail /\ k /= None
       /\ tries' = tries + 1
       /\ Reconnect(rest, [sstate EXCEPT ![k] = IF ClosesUnconfigured THEN "closing" ELSE "open"])
    \/ \* connected and configured (:465-472); the ref to an armed timer is dropped
       /\ k /= None
       /\ tries' = 0
       /\ mbox' = rest
       /\ sock' = k
       /\ sstate' = [sstate EXCEPT ![k] = "open"]
       /\ attempts' = IF ResetsAttemptsOnSuccess THEN 0 ELSE attempts
       /\ timer' = "none"
       /\ stray' = stray + (IF timer = "armed" THEN 1 ELSE 0)
       /\ UNCHANGED <<alive, pending, task, respActive, needsResp, up, ended>>

\* The session takes the oldest message in its mailbox.
HandleNext ==
    /\ alive
    /\ mbox /= <<>>
    /\ LET msg == Head(mbox)
           rest == Tail(mbox)
       IN CASE msg[1] = "result" -> OnResult(msg[3], rest)
            [] msg[1] = "tick" -> OnTick(rest)
            [] OTHER -> OnSocketMsg(msg, rest)
    /\ UNCHANGED provider

\* A socket the session closed has not reported its disconnect yet.
NoticePending ==
    \E k \in SockIds :
        /\ k /= sock
        /\ (sstate[k] = "closing" \/ <<"disc", k, None>> \in Range(mbox))

TimerMayFire == LateCloseNotice \/ ~NoticePending

\* Process.send_after(self(), :reconnect_attempt, delay) (session_server.ex:624) fires.
TimerFires ==
    /\ alive /\ timer = "armed" /\ TimerMayFire
    /\ timer' = "fired"
    /\ mbox' = Append(mbox, <<"tick", None, None>>)
    /\ UNCHANGED <<alive, sock, attempts, stray, pending, respActive, needsResp,
                   task, sockets, provider, book>>

\* A timer whose ref the session dropped fires all the same.
StrayFires ==
    /\ alive /\ stray > 0 /\ TimerMayFire
    /\ stray' = stray - 1
    /\ mbox' = Append(mbox, <<"tick", None, None>>)
    /\ UNCHANGED <<alive, sock, attempts, timer, pending, respActive, needsResp,
                   task, sockets, provider, book>>

\* handle_call(:call_stop) (session_server.ex:275) -> {:stop, ...} -> terminate/2.
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
    /\ UNCHANGED <<alive, sock, attempts, timer, stray, pending, respActive, needsResp,
                   sockets, provider, book>>

-----------------------------------------------------------------------------
(* OpenAI and the network, per socket *)

\* OpenAI reads the next client event on k.
\*  - A function_call_output joins the conversation.
\*  - A response.create starts a response, or is rejected with
\*    conversation_already_has_active_response while one is active.
ProvRead(k) ==
    /\ alive /\ sstate[k] = "open" /\ up[k] /= <<>>
    /\ LET e == Head(up[k]) IN
       /\ up' = [up EXCEPT ![k] = Tail(@)]
       /\ IF e[1] = "out"
          THEN /\ out' = [out EXCEPT ![e[2]] = "appended"]
               /\ outAt' = [outAt EXCEPT ![e[2]] = k]
               /\ UNCHANGED <<pActive, rejected, mbox>>
          ELSE IF pActive[k]
          THEN /\ rejected' = TRUE
               /\ Emit(k, "reject", None)
               /\ UNCHANGED <<pActive, out, outAt>>
          ELSE /\ StartResponse(k)
               /\ Emit(k, "created", None)
               /\ UNCHANGED <<rejected, outAt>>
    /\ UNCHANGED <<alive, sock, attempts, timer, stray, pending, respActive, needsResp,
                   task, sstate, issuer, dropsLeft, vadLeft, book>>

\* Server VAD commits the operator's speech and starts a response
\* (create_response: true, openai_client.ex:417). Audio only goes to openai_pid.
Vad ==
    /\ vadLeft > 0
    /\ alive /\ sock /= None /\ sstate[sock] = "open" /\ ~pActive[sock]
    /\ vadLeft' = vadLeft - 1
    /\ StartResponse(sock)
    /\ Emit(sock, "created", None)
    /\ UNCHANGED <<alive, sock, attempts, timer, stray, pending, respActive, needsResp,
                   task, sockets, issuer, outAt, dropsLeft, rejected, book>>

\* The active response calls tool c (response.function_call_arguments.done,
\* openai_client.ex:387).
EmitCall(k, c) ==
    /\ alive /\ sstate[k] = "open" /\ pActive[k] /\ issuer[c] = None
    /\ issuer' = [issuer EXCEPT ![c] = k]
    /\ Emit(k, "call", c)
    /\ UNCHANGED <<alive, sock, attempts, timer, stray, pending, respActive, needsResp,
                   task, sockets, pActive, out, outAt, dropsLeft, vadLeft, rejected, book>>

\* The response ends: completed, or cancelled by an interrupt or by VAD
\* (interrupt_response: true, openai_client.ex:418).
RespDone(k) ==
    /\ alive /\ sstate[k] = "open" /\ pActive[k]
    /\ pActive' = [pActive EXCEPT ![k] = FALSE]
    /\ Emit(k, "done", None)
    /\ UNCHANGED <<alive, sock, attempts, timer, stray, pending, respActive, needsResp,
                   task, sockets, issuer, out, outAt, dropsLeft, vadLeft, rejected, book>>

\* OpenAI or the network drops an open socket; WebSockex reports it
\* (handle_disconnect, openai_client.ex:450) and the process exits.
Drop(k) ==
    /\ alive /\ dropsLeft > 0 /\ sstate[k] = "open"
    /\ dropsLeft' = dropsLeft - 1
    /\ sstate' = [sstate EXCEPT ![k] = "gone"]
    /\ pActive' = [pActive EXCEPT ![k] = FALSE]
    /\ up' = [up EXCEPT ![k] = <<>>]
    /\ Emit(k, "disc", None)
    /\ UNCHANGED <<alive, sock, attempts, timer, stray, pending, respActive, needsResp,
                   task, issuer, out, outAt, vadLeft, rejected, book>>

\* A socket the session closed (OpenAIClient.close -> {:close, state},
\* openai_client.ex:96, :447) finishes its close handshake or hits the 5 s
\* close timeout, then reports a disconnect like any other (websockex.ex:925-931).
CloseDone(k) ==
    /\ alive /\ sstate[k] = "closing"
    /\ sstate' = [sstate EXCEPT ![k] = "gone"]
    /\ Emit(k, "disc", None)
    /\ UNCHANGED <<alive, sock, attempts, timer, stray, pending, respActive, needsResp,
                   task, up, provider, book>>

-----------------------------------------------------------------------------
Init ==
    /\ alive = TRUE
    /\ mbox = <<<<"created", 1, None>>>>
    /\ sock = 1
    /\ attempts = 0 /\ timer = "none" /\ stray = 0
    /\ pending = {} /\ respActive = FALSE /\ needsResp = FALSE
    /\ task = [c \in Calls |-> "idle"]
    /\ sstate = [k \in SockIds |-> IF k = 1 THEN "open" ELSE "unused"]
    /\ up = [k \in SockIds |-> <<>>]
    /\ pActive = [k \in SockIds |-> k = 1]
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
          \/ ProvRead(k) \/ RespDone(k) \/ Drop(k) \/ CloseDone(k)
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
\* openai_pid, no tool task is running, no trigger is owed, no response is
\* running and no reconnect is under way. The model stays silent until the
\* operator speaks again.
Settled ==
    /\ alive /\ sock /= None /\ sstate[sock] = "open"
    /\ mbox = <<>>
    /\ up[sock] = <<>>
    /\ \A c \in Calls : task[c] /= "running"
    /\ ~needsResp /\ ~pActive[sock]
    /\ timer = "none"

\* finish_tool_turn (session_server.ex:1260-1266): racing triggers left "a
\* silent stall until the operator spoke again". Read as: once the call has
\* settled, every tool output in the live conversation has had a response
\* start after it.
NoSilentStall ==
    Settled => \A c \in Calls : ~(out[c] = "appended" /\ outAt[c] = sock)

\* session_server.ex:196-199: response_active? and needs_response? "make
\* 'exactly one response.create per answered batch' hold under EVERY
\* interleaving"; :1262-1264: "a trigger sent before its response.done is the
\* race itself". Read as: OpenAI never rejects a response.create.
NoRejectedTrigger == ~rejected

\* schedule_reconnect (session_server.ex:600-605): abandon in-flight tool tasks
\* "rather than let a late result fire at (or tear down) the new session".
\* Read as: a tool output only ever joins the conversation that called it.
LateResultStaysHome ==
    \A c \in Calls : out[c] /= "none" => outAt[c] = issuer[c]

\* resume_provider_session (session_server.ex:645-648): leaving an unconfigured
\* socket open "leaks a billed upstream connection per retry". Read as: while
\* the call lives, every open socket is openai_pid.
NoOrphanSocket ==
    alive => \A k \in SockIds : sstate[k] = "open" => k = sock

\* end_call (session_server.ex:662-670) makes a live call with no provider
\* connection "unrepresentable"; audio_chunk (:324-325): "openai_pid is nil
\* ONLY inside the bounded reconnect window". Read as: a live session has a
\* socket, or a reconnect timer on the way.
NoFreeze ==
    alive => sock /= None \/ timer /= "none"

\* Proposed rule: @default_reconnect_backoff_ms (session_server.ex:53) names one
\* delay per attempt, so a call gives up on OpenAI only after running every
\* attempt.
EveryAttemptTried ==
    ended = "exhausted" => tries >= MaxAttempts

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* A :reconnect_attempt reaches a call that is already connected: its attempt
\* opens a second socket, and success or failure leaves the first one open.
Witness_TickWhileConnected ==
    ~(alive /\ sock /= None /\ <<"tick", None, None>> \in Range(mbox))

=============================================================================
