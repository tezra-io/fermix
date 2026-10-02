--------------------------- MODULE RealtimeSession ---------------------------
(***************************************************************************)
(* FermixCore.Realtime.SessionServer for ONE voice call after call_start: *)
(* how a tool result becomes the model's next spoken response, how the    *)
(* call keeps exactly one upstream OpenAI socket across drops and         *)
(* reconnects, and how it ends when OpenAI refuses to configure one.      *)
(*                                                                         *)
(* Processes: the session GenServer and its one mailbox; its tool tasks   *)
(* (async_nolink on the Realtime TaskSupervisor); the confirmed run of an *)
(* access-sensitive command the owner said yes to (another async_nolink   *)
(* task); its reconnect timers; and each upstream socket (a WebSockex     *)
(* process linked to the session) together with the OpenAI conversation  *)
(* behind it.                                                             *)
(*                                                                         *)
(* Every message a socket sends names it: its events and errors carry     *)
(* self() (OpenAIClient.handle_frame -> notify_parent, openai_client.ex:  *)
(* 443, :475), and its death reaches the session only as its EXIT through *)
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
(* (handle_active_response_race, session_server.ex:1515-1535).            *)
(*                                                                         *)
(* Observed of OpenAI (2026-09-26, a wrong key): it accepts the WebSocket, *)
(* then answers session.update with an error (invalid_api_key) and never  *)
(* sends session.updated. Whether it then closes the socket is not known, *)
(* so the model leaves it open; Drop may still close it.                  *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - audio, transcripts other than the owner's yes, usage and cost       *)
(*    limits, the max-session timer, the screen feed and screen_share     *)
(*    (answered inline, no task), reload_runtime;                         *)
(*  - interrupt: its response.cancel only ends the active response early, *)
(*    which RespDone already allows at any time;                          *)
(*  - a tool task crash: its :DOWN is answered exactly like a result      *)
(*    (session_server.ex:466-471), so TaskFinish covers both; likewise a  *)
(*    confirmed run's crash (:458-462) and DispatchFinish;                *)
(*  - a second confirmed run: Yeses is at most 1, so at most one outcome  *)
(*    is held (held_outcomes is a list, oldest first, :1371-1376);        *)
(*  - the warning terminate/2 logs for an outcome still held when the     *)
(*    call ends (warn_unspoken_outcomes, :569, :1381-1388);               *)
(*  - the access gate's own state: what a call has read from outside      *)
(*    (outside_sources), the waiting stamp tool_call_context gives each   *)
(*    tool task (:1278-1284), and the binding of the owner's answer to    *)
(*    the first input item committed after the park (bind_access_answer   *)
(*    and answer_access, :1294-1323). The owner's yes is one step, Yes,   *)
(*    and needs only that a tool call has run. A spoken no only adds a    *)
(*    passive status item (no response.create) and starts nothing;        *)
(*  - call_start: the call starts connected on socket 1, configured, with *)
(*    the operator's first response under way. OpenAI refusing socket 1's *)
(*    session.update takes the same clause (session_server.ex:420) as a   *)
(*    reconnect's refusal, which is modelled; ExUnit covers socket 1's;   *)
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
(*    exit with {:shutdown, _} (:730-734, :301-312), and a crash or a     *)
(*    supervisor shutdown is non-normal too. terminate/2 also closes      *)
(*    openai_pid (:563-578);                                              *)
(*  - SessionServer.handle_provider_event/2 (session_server.ex:102): a    *)
(*    test seam nothing in lib calls. It acts on an event without the pid *)
(*    check, and an error before session.updated does not end the call    *)
(*    through it, so NoFreeze, NoStrayTimer, NoTickWhileConnected and     *)
(*    NoUnconfiguredWait hold only while it stays one.                    *)
(*                                                                         *)
(* One step = one session callback, one task finishing, one timer firing, *)
(* or one thing OpenAI, the network or the owner does.                    *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/realtime/session_server.ex @ 604b617c39b2
\* SOURCE: apps/fermix_core/lib/fermix_core/realtime/openai_client.ex#start_link,send_event,close,turn_detection,decode_server_event,handle_frame,handle_cast,notify_parent @ 68769ed69762
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Calls,          \* the tool calls the model may make, e.g. {c1, c2}; each at most once
    MaxSockets,     \* upstream sockets the call may open, socket 1 included. Past it,
                    \* every further open fails, as if the network were down.
    MaxAttempts,    \* Len(reconnect_backoff_ms): 3 in production (session_server.ex:60)
    None,
    \* Environment: what OpenAI, the network and the operator may do.
    Drops,          \* how many times the network or OpenAI may drop an open socket
    VadTurns,       \* how many more responses server VAD may start on the operator's
                    \* speech (turn_detection create_response: true, openai_client.ex:432)
    Yeses,          \* 0 or 1: the owner says yes to an access-sensitive command a tool
                    \* call parked, and the session starts its confirmed run
                    \* (answer_access -> start_access_dispatch, session_server.ex:1313-1341)
    OpensCanFail,   \* a reconnect's WebSocket handshake fails (start_link returns an error)
    UpdatesCanFail, \* a reconnect's socket opens, but sending session.update to it fails
    UsersCanStop,   \* the operator ends the call (call_stop, session_server.ex:301)
    LateVadCreated, \* a VAD response takes its context in one step and OpenAI emits its
                    \* response.created in a later one; FALSE emits it in the same step
    OpenAICanRefuse, \* OpenAI answers a reconnect's session.update with an error instead
                     \* of session.updated: a refused key, a refused configuration
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off only by the checks that show a property needs it.
    DefersWhileCallsPending,   \* finish_tool_turn holds the trigger while other calls
                               \* of the batch are in flight (session_server.ex:1489)
    DefersWhileResponseActive, \* ... and while OpenAI's response is active; the
                               \* response.done then sends it (:1493, flush_deferred_response :1502)
    RearmsOnRejection,         \* a response.create OpenAI rejected for an active response
                               \* is owed again (handle_active_response_race, :1528)
    CancelsToolsOnReconnect,   \* schedule_reconnect kills in-flight tool tasks, and
                               \* Task.shutdown flushes their replies (:669 -> :776-777)
    ClosesUnconfigured,        \* resume_provider_session closes a socket whose
                               \* session.update failed (:714)
    EndsWhenExhausted,         \* no reconnect left ends the call (end_call, :730)
    ResetsAttemptsOnSuccess,   \* a reconnect OpenAI confirms resets reconnect_attempts: the
                               \* new socket's first session.updated (:923)
    ResetsOnlyWhenConfirmed,   \* ... and nothing earlier does (:526). FALSE resets it as soon
                               \* as the socket opens and takes its session.update, as the code
                               \* did before the reset moved (:467 at 35a6acdc)
    OwnSocketOnly,             \* only openai_pid's events, errors and EXIT are acted on;
                               \* any other socket's are dropped (:420, :427, :489, :498,
                               \* :504)
    HoldsOutcome,              \* a confirmed run's outcome that lands while the call is not
                               \* live, or whose status item cannot be sent, is held and told
                               \* once OpenAI confirms the next socket (speak_outcome
                               \* :1354-1369, speak_held_outcomes :927, :1375-1376). FALSE
                               \* sends it whatever the call's state, as before (:1277-1281
                               \* at 82a91e60)
    EndsOnRefusal              \* an error on openai_pid before its session.updated ends
                               \* the call (:420 -> refuse_call :745 -> end_call :730)

ASSUME Yeses \in {0, 1}

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
    held,         \* held_outcomes is not empty: the confirmed run's outcome waits for a
                  \* socket OpenAI has confirmed
    \* the tool tasks
    task,         \* task[c]: "idle", "running", "replied" (its result is queued),
                  \* "done" (answered), "killed"
    \* the confirmed run (access_dispatches)
    disp,         \* "idle", "running", "replied" (its outcome is queued), "done" (answered)
    \* each upstream socket and the conversation behind it
    sstate,       \* sstate[k]: "unused", "open", "closing" (the session closed it), "gone"
    up,           \* up[k]: client events the session sent on k, not yet read by OpenAI
    pActive,      \* pActive[k]: k's conversation has a response in progress
    vadOwed,      \* vadOwed[k]: k's VAD response has not emitted response.created yet
    issuer,       \* issuer[c]: the conversation whose response called c
    out,          \* out[c]: "none", "appended", or "answered" (a response started after it)
    outAt,        \* outAt[c]: the conversation c's output was appended to
    note,         \* the confirmed run's status item: "none", "appended", or "answered"
    noteAt,       \* the conversation it was appended to
    dropsLeft,    \* environment budget: socket drops still allowed
    vadLeft,      \* environment budget: VAD responses still allowed
    yesLeft,      \* environment budget: the owner's yes, not said yet
    \* bookkeeping
    rejected,     \* OpenAI rejected a response.create: a response was already active
    tries,        \* reconnect attempts run since OpenAI last confirmed the call's socket
                  \* (its first session.updated)
    ended,        \* why the session ended: "none", "stop", "exhausted", "refused"
    noteSent      \* the session put the confirmed run's status item on the wire to an
                  \* open socket

session  == <<alive, mbox, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
              held>>
sockets  == <<sstate, up>>
provider == <<pActive, vadOwed, issuer, out, outAt, note, noteAt, dropsLeft, vadLeft, yesLeft,
              rejected>>
book     == <<tries, ended, noteSent>>
vars == <<session, task, disp, sockets, provider, book>>

SockIds == 1..MaxSockets
ClientEvents == ({"create", "update", "note"} \X {None}) \cup ({"out"} \X Calls)
Msgs ==
    ({"created", "done", "reject", "updated", "refused", "disc", "yes"} \X SockIds \X {None})
    \cup ({"call"} \X SockIds \X Calls)
    \cup ({"result"} \X {None} \X Calls)
    \cup ({"tick", "dispatched"} \X {None} \X {None})

TypeOK ==
    /\ alive \in BOOLEAN
    /\ mbox \in Seq(Msgs)
    /\ sock \in SockIds \cup {None}
    /\ ready \in BOOLEAN
    /\ attempts \in 0..MaxAttempts
    /\ timer \in {"none", "armed", "fired"}
    /\ stray \in Nat
    /\ pending \subseteq Calls
    /\ respActive \in BOOLEAN /\ needsResp \in BOOLEAN /\ held \in BOOLEAN
    /\ task \in [Calls -> {"idle", "running", "replied", "done", "killed"}]
    /\ disp \in {"idle", "running", "replied", "done"}
    /\ sstate \in [SockIds -> {"unused", "open", "closing", "gone"}]
    /\ \A k \in SockIds : up[k] \in Seq(ClientEvents)
    /\ pActive \in [SockIds -> BOOLEAN]
    /\ vadOwed \in [SockIds -> BOOLEAN]
    /\ issuer \in [Calls -> SockIds \cup {None}]
    /\ out \in [Calls -> {"none", "appended", "answered"}]
    /\ outAt \in [Calls -> SockIds \cup {None}]
    /\ note \in {"none", "appended", "answered"}
    /\ noteAt \in SockIds \cup {None}
    /\ dropsLeft \in 0..Drops /\ vadLeft \in 0..VadTurns /\ yesLeft \in 0..Yeses
    /\ rejected \in BOOLEAN /\ tries \in Nat
    /\ ended \in {"none", "stop", "exhausted", "refused"}
    /\ noteSent \in BOOLEAN

-----------------------------------------------------------------------------
(* Helpers *)

Range(s) == {s[i] : i \in 1..Len(s)}

\* The lowest socket id not used yet, or None when the bound is reached.
NextSock ==
    IF \E k \in SockIds : sstate[k] = "unused"
    THEN CHOOSE k \in SockIds : sstate[k] = "unused" /\ \A j \in SockIds : sstate[j] = "unused" => k <= j
    ELSE None

\* Socket k puts one message in the session's mailbox: an event or error
\* (OpenAIClient.handle_frame -> notify_parent, openai_client.ex:448, :480),
\* or its EXIT.
Emit(k, kind, c) == mbox' = Append(mbox, <<kind, k, c>>)

\* send_openai/2 -> OpenAIClient.send_event (session_server.ex:1567,
\* openai_client.ex:70): a call into the socket process, which writes the frames
\* in order. To a socket that is closing or gone, or with no openai_pid
\* (:1571), the send fails and is only reported (send_openai_events). The
\* session learns which from the send's result.
CanSend == sock /= None /\ sstate[sock] = "open"

SendUp(es) ==
    IF CanSend
    THEN up' = [up EXCEPT ![sock] = @ \o es]
    ELSE UNCHANGED up

KillTasks == [c \in Calls |-> IF task[c] \in {"running", "replied"} THEN "killed" ELSE task[c]]

\* Task.shutdown(task, :brutal_kill) also takes the task's reply out of the
\* mailbox (session_server.ex:770-771, :777). A confirmed run's reply is not a
\* tool task's, and stays queued.
NotResult(m) == m[1] /= "result"

\* terminate/2 (session_server.ex:563-578) and what the exit causes: kill the tool
\* tasks, cancel the timers, close openai_pid. Every socket is linked to the
\* session, which exits with {:shutdown, _}, so every socket dies with it, and
\* nothing reaches a dead session's mailbox. s is sstate as the calling callback
\* left it. A confirmed run is not stopped (cancel_pending_tool_calls covers
\* only tool tasks); its reply then reaches no one. An outcome still held is
\* only logged (warn_unspoken_outcomes, :569).
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
    /\ UNCHANGED <<attempts, ready, disp, held>>

\* schedule_reconnect/1 (session_server.ex:653-695), and end_call/2 (:730) when
\* it returns :exhausted. m and s are the mailbox and sstate as the calling
\* callback left them.
\*  - It does not close openai_pid: its callers reach it only once that socket
\*    is dead, or with none.
\*  - Process.send_after (:682) replaces reconnect_timer. A timer still armed
\*    would fire with no ref left to it; with OwnSocketOnly nothing reaches
\*    here while one is armed (NoStrayTimer).
\*  - It leaves a confirmed run alone: cancel_pending_tool_calls kills only
\*    pending_tool_calls (:776-777), so the run's reply may land in the
\*    reconnect window or on the next socket. It leaves a held outcome held.
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
         /\ UNCHANGED <<alive, ended, up, disp, held>>
    ELSE IF EndsWhenExhausted
    THEN EndSession("exhausted", s)
    \* The teardown end_call replaced: the session lived on with no socket and
    \* no timer (the comment at session_server.ex:721-729).
    ELSE /\ sock' = None /\ ready' = FALSE /\ timer' = "none"
         /\ task' = KillTasks /\ pending' = {} /\ mbox' = SelectSeq(m, NotResult)
         /\ respActive' = FALSE /\ needsResp' = FALSE
         /\ sstate' = s
         /\ UNCHANGED <<alive, ended, stray, up, attempts, disp, held>>

\* A response starts in k's conversation. It reads the outputs appended so
\* far, and the confirmed run's status item if it is there; the comment at
\* session_server.ex:1478-1488 records that a response "snapshotted context"
\* when it began, so an item appended later is not part of it.
StartResponse(k) ==
    /\ pActive' = [pActive EXCEPT ![k] = TRUE]
    /\ out' = [c \in Calls |-> IF out[c] = "appended" /\ outAt[c] = k THEN "answered" ELSE out[c]]
    /\ note' = IF note = "appended" /\ noteAt = k THEN "answered" ELSE note

-----------------------------------------------------------------------------
(* The session GenServer: one callback per message, oldest first *)

\* The trigger rule finish_tool_turn (session_server.ex:1489-1500) applies after
\* the session has put es on the wire to openai_pid: with calls of the batch in
\* flight, or OpenAI's response active, the trigger is owed; otherwise it goes
\* with es.
FinishTurn(p, es) ==
    IF p /= {} /\ DefersWhileCallsPending
    THEN needsResp' = TRUE /\ SendUp(es)
    ELSE IF respActive /\ DefersWhileResponseActive
    THEN needsResp' = TRUE /\ SendUp(es)
    ELSE needsResp' = FALSE /\ SendUp(es \o <<<<"create", None>>>>)

\* The confirmed run's outcome, told: Fermix's status item goes to openai_pid
\* (speak_outcome -> send_openai_seq, session_server.ex:1356-1358), then
\* finish_tool_turn (:1359), as for a tool result.
Tell ==
    /\ noteSent' = (noteSent \/ CanSend)
    /\ FinishTurn(pending, <<<<"note", None>>>>)

\* speak_held_outcomes (:1375-1376) runs each held outcome through
\* speak_outcome again, with provider_ready? already true: told now, or held
\* again when its status item cannot be sent (:1361-1367).
SpeakHeld ==
    IF held /\ CanSend
    THEN Tell /\ held' = FALSE
    ELSE UNCHANGED <<held, noteSent, needsResp, up>>

\* A message from openai_pid, or from any socket when OwnSocketOnly is off:
\* handle_info({:openai_realtime_event, pid, event}) (session_server.ex:427),
\* and the EXIT clause (:504) for "disc". An error before session.updated
\* does not get here with EndsOnRefusal: see Refuse.
OnSocketMsg(msg, rest) ==
    CASE msg[1] = "disc" ->
           \* :504 -> schedule_reconnect, or end_call when exhausted
           /\ Reconnect(rest, sstate)
           /\ UNCHANGED <<tries, noteSent>>
      [] msg[1] = "created" ->
           \* {:response_created, _} (:979)
           /\ respActive' = TRUE
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, needsResp, held,
                          task, disp, sockets, book>>
      [] msg[1] = "done" ->
           \* {:response_done, _} (:987), ending in flush_deferred_response (:1502)
           /\ respActive' = FALSE
           /\ IF needsResp /\ pending = {}
              THEN needsResp' = FALSE /\ SendUp(<<<<"create", None>>>>)
              ELSE UNCHANGED <<needsResp, up>>
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, held, task, disp,
                          sstate, book>>
      [] msg[1] = "call" ->
           \* {:function_call, call} (:971) -> dispatch_tool_call (:1025)
           /\ task' = [task EXCEPT ![msg[3]] = "running"]
           /\ pending' = pending \cup {msg[3]}
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, respActive, needsResp,
                          held, disp, sockets, book>>
      [] msg[1] = "reject" ->
           \* {:error, conversation_already_has_active_response} (:998) ->
           \* handle_active_response_race (:1528) owes the trigger again; the
           \* rejecting response's response.done sends it
           /\ needsResp' = (needsResp \/ RearmsOnRejection)
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive,
                          held, task, disp, sockets, book>>
      [] msg[1] = "refused" ->
           \* any other {:error, _} (:998) is only reported; without EndsOnRefusal
           \* (the old code) even one that came before session.updated
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive,
                          needsResp, held, task, disp, sockets, book>>
      [] msg[1] = "updated" ->
           \* {:session_updated, _} (:913-928). The first one for a socket sets
           \* provider_ready?, resets reconnect_attempts (:923), and runs
           \* start_timers -> cancel_timers (:1769-1786), which forgets
           \* reconnect_timer: an armed timer is cancelled, and a fired one's tick
           \* stays queued. Then speak_held_outcomes (:927): OpenAI has confirmed
           \* this socket, so a held outcome is told.
           /\ ready' = TRUE
           /\ timer' = IF ready THEN timer ELSE "none"
           /\ attempts' = IF ~ready /\ ResetsAttemptsOnSuccess /\ ResetsOnlyWhenConfirmed
                          THEN 0 ELSE attempts
           /\ tries' = IF ready THEN tries ELSE 0
           /\ mbox' = rest
           /\ IF ready THEN UNCHANGED <<held, noteSent, needsResp, up>> ELSE SpeakHeld
           /\ UNCHANGED <<alive, sock, stray, pending, respActive, task, disp, sstate, ended>>
      [] msg[1] = "yes" ->
           \* The owner's yes to the parked command: {:input_audio_committed, _}
           \* (:941) -> bind_access_answer (:1294), then {:user_transcript_done, _, _}
           \* (:903) -> answer_access (:1313) -> start_access_dispatch (:1329), which
           \* runs AccessGate.confirm off the loop.
           /\ disp' = "running"
           /\ mbox' = rest
           /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive,
                          needsResp, held, task, sockets, book>>

\* A message from a socket that is not openai_pid: the catch-all for events and
\* errors (session_server.ex:498) or the EXIT catch-all (:521). Nothing but the
\* mailbox changes.
DropStale(rest) ==
    /\ mbox' = rest
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   held, task, disp, sockets, book>>

\* An error from openai_pid before its session.updated, of any kind: the clause
\* at session_server.ex:420 matches {:error, _} while provider_ready? is false.
Refuses(msg) == EndsOnRefusal /\ ~ready /\ msg[1] \in {"reject", "refused"}

\* refuse_call (session_server.ex:745) -> end_call(:provider_refused) (:730):
\* the call ends, and terminate/2 closes the refused socket.
Refuse ==
    /\ EndSession("refused", sstate)
    /\ UNCHANGED <<tries, noteSent>>

\* A tool task's reply: handle_info({ref, result}) (session_server.ex:435) ->
\* apply_tool_result (:1439) -> append_tool_output (:1463) -> finish_tool_turn.
\* The output always goes to openai_pid; the trigger goes with it only when
\* nothing defers it.
OnResult(c, rest) ==
    /\ task' = [task EXCEPT ![c] = "done"]
    /\ mbox' = rest
    /\ LET p == pending \ {c} IN
       /\ pending' = p
       /\ FinishTurn(p, <<<<"out", c>>>>)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, respActive, held, disp, sstate,
                   book>>

\* The confirmed run's reply: handle_info({ref, {status, outcome}})
\* (session_server.ex:448), or its :DOWN (:458), answered alike ->
\* access_dispatched (:1343) -> speak_outcome (:1354-1369). While the call is
\* not live (provider_ready? false, :1354), or when the status item's send
\* fails (openai_pid is dead, its EXIT still queued, :1361-1367), the outcome is
\* held (hold_outcome, :1371) for the next socket OpenAI confirms. Otherwise it
\* is told. The run is not one of pending_tool_calls, so it holds back no
\* batch's trigger, and nothing tells it apart from a trigger already on the
\* wire. With HoldsOutcome off, the status item and the trigger go out
\* whatever the call's state, and a failed send is only reported.
OnDispatched(rest) ==
    /\ disp' = "done"
    /\ mbox' = rest
    /\ IF HoldsOutcome /\ ~(ready /\ CanSend)
       THEN held' = TRUE /\ UNCHANGED <<noteSent, needsResp, up>>
       ELSE Tell /\ UNCHANGED held
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive,
                   task, sstate, tries, ended>>

\* handle_info(:reconnect_attempt) (session_server.ex:523-544) ->
\* attempt_reconnect (:697) -> open_openai_session (:582; start_link returns
\* after the handshake) -> resume_provider_session (:708). It does not check
\* whether the call is already connected.
OnTick(rest) ==
    LET k == NextSock IN
    \/ \* the handshake fails, or every allowed socket is used: {:error, _}
       /\ OpensCanFail \/ k = None
       /\ tries' = tries + 1
       /\ Reconnect(rest, sstate)
       /\ UNCHANGED noteSent
    \/ \* the socket opens but session.update fails: close it (:714), schedule again
       /\ UpdatesCanFail /\ k /= None
       /\ tries' = tries + 1
       /\ Reconnect(rest, [sstate EXCEPT ![k] = IF ClosesUnconfigured THEN "closing" ELSE "open"])
       /\ UNCHANGED noteSent
    \/ \* connected, with session.update on the wire (:526-533); the ref to an
       \* armed timer is dropped. The attempt stays counted until the socket's
       \* session.updated: OpenAI has not confirmed it yet.
       /\ k /= None
       /\ tries' = tries + 1
       /\ mbox' = rest
       /\ sock' = k /\ ready' = FALSE
       /\ sstate' = [sstate EXCEPT ![k] = "open"]
       /\ up' = [up EXCEPT ![k] = <<<<"update", None>>>>]
       /\ attempts' = IF ResetsAttemptsOnSuccess /\ ~ResetsOnlyWhenConfirmed
                      THEN 0 ELSE attempts
       /\ timer' = "none"
       /\ stray' = stray + (IF timer = "armed" THEN 1 ELSE 0)
       /\ UNCHANGED <<alive, pending, task, disp, respActive, needsResp, held, ended, noteSent>>

FromSocket(msg) == msg[1] \notin {"result", "tick", "dispatched"}
Stale(msg) == OwnSocketOnly /\ msg[2] /= sock

\* The session takes the oldest message in its mailbox.
HandleNext ==
    /\ alive
    /\ mbox /= <<>>
    /\ LET msg == Head(mbox)
           rest == Tail(mbox)
       IN CASE msg[1] = "result" -> OnResult(msg[3], rest)
            [] msg[1] = "dispatched" -> OnDispatched(rest)
            [] msg[1] = "tick" -> OnTick(rest)
            [] FromSocket(msg) /\ Stale(msg) -> DropStale(rest)
            [] FromSocket(msg) /\ ~Stale(msg) /\ Refuses(msg) -> Refuse
            [] FromSocket(msg) /\ ~Stale(msg) /\ ~Refuses(msg) -> OnSocketMsg(msg, rest)
    /\ UNCHANGED provider

\* Process.send_after(self(), :reconnect_attempt, delay) (session_server.ex:682) fires.
TimerFires ==
    /\ alive /\ timer = "armed"
    /\ timer' = "fired"
    /\ mbox' = Append(mbox, <<"tick", None, None>>)
    /\ UNCHANGED <<alive, sock, ready, attempts, stray, pending, respActive, needsResp,
                   held, task, disp, sockets, provider, book>>

\* A timer whose ref the session dropped fires all the same.
StrayFires ==
    /\ alive /\ stray > 0
    /\ stray' = stray - 1
    /\ mbox' = Append(mbox, <<"tick", None, None>>)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, pending, respActive, needsResp,
                   held, task, disp, sockets, provider, book>>

\* handle_call(:call_stop) (session_server.ex:301) -> {:stop, ...} -> terminate/2.
\* Modelled as handled at any moment, ahead of anything queued. Ending the call
\* early only removes behaviour, so no property can pass because of it.
Stop ==
    /\ UsersCanStop /\ alive
    /\ EndSession("stop", sstate)
    /\ UNCHANGED <<provider, tries, noteSent>>

-----------------------------------------------------------------------------
(* The tool tasks and the confirmed run *)

\* ToolBridge.execute_call returns; the reply lands in the session's mailbox.
TaskFinish(c) ==
    /\ alive /\ task[c] = "running"
    /\ task' = [task EXCEPT ![c] = "replied"]
    /\ mbox' = Append(mbox, <<"result", None, c>>)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   held, disp, sockets, provider, book>>

\* AccessGate.confirm returns, or the run crashes; either way one message lands
\* in the session's mailbox.
DispatchFinish ==
    /\ alive /\ disp = "running"
    /\ disp' = "replied"
    /\ mbox' = Append(mbox, <<"dispatched", None, None>>)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   held, task, sockets, provider, book>>

-----------------------------------------------------------------------------
(* OpenAI, the network and the owner, per socket *)

\* OpenAI reads the next client event on k.
\*  - A function_call_output, or Fermix's status item, joins the conversation.
\*  - A session.update is answered with session.updated or, with
\*    OpenAICanRefuse, with an error: a refused key or configuration. The
\*    socket is not configured, and stays open.
\*  - A response.create starts a response, or is rejected with
\*    conversation_already_has_active_response while one is active.
ProvRead(k) ==
    /\ alive /\ sstate[k] = "open" /\ up[k] /= <<>>
    /\ LET e == Head(up[k]) IN
       /\ up' = [up EXCEPT ![k] = Tail(@)]
       /\ CASE e[1] = "out" ->
                 /\ out' = [out EXCEPT ![e[2]] = "appended"]
                 /\ outAt' = [outAt EXCEPT ![e[2]] = k]
                 /\ UNCHANGED <<pActive, note, noteAt, rejected, mbox>>
            [] e[1] = "note" ->
                 /\ note' = "appended"
                 /\ noteAt' = k
                 /\ UNCHANGED <<pActive, out, outAt, rejected, mbox>>
            [] e[1] = "update" ->
                 /\ \/ Emit(k, "updated", None)
                    \/ OpenAICanRefuse /\ Emit(k, "refused", None)
                 /\ UNCHANGED <<pActive, out, outAt, note, noteAt, rejected>>
            [] e[1] = "create" /\ pActive[k] ->
                 /\ rejected' = TRUE
                 /\ Emit(k, "reject", None)
                 /\ UNCHANGED <<pActive, out, outAt, note, noteAt>>
            [] e[1] = "create" /\ ~pActive[k] ->
                 /\ StartResponse(k)
                 /\ Emit(k, "created", None)
                 /\ UNCHANGED <<rejected, outAt, noteAt>>
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   held, task, disp, sstate, vadOwed, issuer, dropsLeft, vadLeft, yesLeft, book>>

\* Server VAD commits the operator's speech and starts a response
\* (create_response: true, openai_client.ex:432). Audio only goes to openai_pid.
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
                   held, task, disp, sockets, issuer, outAt, noteAt, dropsLeft, yesLeft, rejected,
                   book>>

\* The VAD response's response.created leaves OpenAI (LateVadCreated only).
VadCreated(k) ==
    /\ alive /\ sstate[k] = "open" /\ vadOwed[k]
    /\ vadOwed' = [vadOwed EXCEPT ![k] = FALSE]
    /\ Emit(k, "created", None)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   held, task, disp, sockets, pActive, issuer, out, outAt, note, noteAt, dropsLeft,
                   vadLeft, yesLeft, rejected, book>>

\* The active response calls tool c (response.function_call_arguments.done,
\* openai_client.ex:402).
EmitCall(k, c) ==
    /\ alive /\ sstate[k] = "open" /\ pActive[k] /\ ~vadOwed[k] /\ issuer[c] = None
    /\ issuer' = [issuer EXCEPT ![c] = k]
    /\ Emit(k, "call", c)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   held, task, disp, sockets, pActive, vadOwed, out, outAt, note, noteAt, dropsLeft,
                   vadLeft, yesLeft, rejected, book>>

\* The response ends: completed, or cancelled by an interrupt or by VAD
\* (interrupt_response: true, openai_client.ex:433).
RespDone(k) ==
    /\ alive /\ sstate[k] = "open" /\ pActive[k] /\ ~vadOwed[k]
    /\ pActive' = [pActive EXCEPT ![k] = FALSE]
    /\ Emit(k, "done", None)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   held, task, disp, sockets, vadOwed, issuer, out, outAt, note, noteAt, dropsLeft,
                   vadLeft, yesLeft, rejected, book>>

\* The owner says yes to the command a tool call parked: server VAD commits the
\* utterance (input_audio_buffer.committed, openai_client.ex:382) and its
\* transcript follows with the item id (conversation.item.input_audio_transcription.
\* completed, :367-375), both on openai_pid, the only socket audio goes to. One
\* step here, and one message: the binding by item id is not modelled. The
\* utterance's own VAD response is Vad's, so checks that allow the yes may leave
\* it out.
Yes ==
    /\ alive /\ yesLeft > 0 /\ sock /= None /\ sstate[sock] = "open"
    /\ \E c \in Calls : task[c] /= "idle"
    /\ yesLeft' = yesLeft - 1
    /\ Emit(sock, "yes", None)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   held, task, disp, sockets, pActive, vadOwed, issuer, out, outAt, note, noteAt,
                   dropsLeft, vadLeft, rejected, book>>

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
                   held, task, disp, issuer, out, outAt, note, noteAt, vadLeft, yesLeft, rejected,
                   book>>

\* A socket the session closed (OpenAIClient.close -> {:close, state},
\* openai_client.ex:107, :478) finishes its close handshake or hits the 5 s
\* close timeout, then exits like any other (websockex.ex:925-931).
CloseDone(k) ==
    /\ alive /\ sstate[k] = "closing"
    /\ sstate' = [sstate EXCEPT ![k] = "gone"]
    /\ Emit(k, "disc", None)
    /\ UNCHANGED <<alive, sock, ready, attempts, timer, stray, pending, respActive, needsResp,
                   held, task, disp, up, provider, book>>

-----------------------------------------------------------------------------
Init ==
    /\ alive = TRUE
    /\ mbox = <<<<"created", 1, None>>>>
    /\ sock = 1 /\ ready = TRUE
    /\ attempts = 0 /\ timer = "none" /\ stray = 0
    /\ pending = {} /\ respActive = FALSE /\ needsResp = FALSE /\ held = FALSE
    /\ task = [c \in Calls |-> "idle"]
    /\ disp = "idle"
    /\ sstate = [k \in SockIds |-> IF k = 1 THEN "open" ELSE "unused"]
    /\ up = [k \in SockIds |-> <<>>]
    /\ pActive = [k \in SockIds |-> k = 1]
    /\ vadOwed = [k \in SockIds |-> FALSE]
    /\ issuer = [c \in Calls |-> None]
    /\ out = [c \in Calls |-> "none"]
    /\ outAt = [c \in Calls |-> None]
    /\ note = "none" /\ noteAt = None
    /\ dropsLeft = Drops /\ vadLeft = VadTurns /\ yesLeft = Yeses
    /\ rejected = FALSE /\ tries = 0 /\ ended = "none" /\ noteSent = FALSE

\* The legitimate ends: the session has exited, or the call is connected and
\* idle, with an empty mailbox, no tool task or confirmed run running, no
\* outcome held and no reconnect timer. Deadlock checking is on, so any other
\* state where nothing can happen is reported as a wedge.
Done ==
    \/ ~alive
    \/ /\ sock /= None
       /\ mbox = <<>>
       /\ \A c \in Calls : task[c] /= "running"
       /\ disp /= "running"
       /\ ~held
       /\ timer = "none" /\ stray = 0

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ HandleNext \/ TimerFires \/ StrayFires \/ Stop
    \/ \E c \in Calls : TaskFinish(c)
    \/ DispatchFinish
    \/ \E k \in SockIds :
          \/ ProvRead(k) \/ RespDone(k) \/ Drop(k) \/ CloseDone(k) \/ VadCreated(k)
          \/ \E c \in Calls : EmitCall(k, c)
    \/ Vad \/ Yes
    \/ Terminated

\* Fairness only on what Fermix drives: the session's callbacks, its tasks and
\* its timers. None on OpenAI, the network, the operator or the owner. Every
\* property below is an invariant, so no verdict rests on it.
Fairness ==
    /\ WF_vars(HandleNext) /\ WF_vars(TimerFires) /\ WF_vars(StrayFires)
    /\ \A c \in Calls : WF_vars(TaskFinish(c))
    /\ WF_vars(DispatchFinish)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* The call has settled: the mailbox is empty, nothing waits on the wire to
\* openai_pid, no tool task or confirmed run is running, no response is running
\* and no reconnect is under way. The model stays silent until the operator
\* speaks again. A trigger may still be owed; NoSilentStall asks whether one was
\* lost.
Settled ==
    /\ alive /\ sock /= None /\ sstate[sock] = "open"
    /\ mbox = <<>>
    /\ up[sock] = <<>>
    /\ \A c \in Calls : task[c] /= "running"
    /\ disp /= "running"
    /\ ~pActive[sock]
    /\ timer = "none"

\* finish_tool_turn (session_server.ex:1478-1488): racing triggers left "a
\* silent stall until the operator spoke again". Read as: once the call has
\* settled, every tool output in the live conversation has had a response
\* start after it.
NoSilentStall ==
    Settled => \A c \in Calls : ~(out[c] = "appended" /\ outAt[c] = sock)

\* The comment on the confirmed run's reply (session_server.ex:443-447): "The
\* model is told through Fermix's status item, and one response is owed so it
\* can tell the owner, in this conversation or, when the call is not live, the
\* next one OpenAI confirms." Read as: once the call has settled, a run that
\* replied has had its status item put on the wire to an open socket, even
\* when the reply landed while the call reconnected; and the status item, if
\* it is in the live conversation, has had a response start after it. One
\* still on the wire, or not yet answered, when its socket drops dies with
\* that conversation, as a tool output does.
OutcomeAnswered ==
    Settled => /\ disp = "done" => noteSent
               /\ ~(note = "appended" /\ noteAt = sock)

\* finish_tool_turn (session_server.ex:1478-1488): "a trigger sent before its
\* response.done is the race itself", and the deferral "avoids every rejection
\* the session can foresee". Read as: with no server-VAD response the session
\* has not heard of, and no confirmed run (Witness_OutcomeTriggerRejected),
\* OpenAI never rejects a response.create.
NoRejectedTrigger == ~rejected

\* schedule_reconnect (session_server.ex:661-663): abandon in-flight tool tasks
\* "rather than let a late result fire at (or tear down) the new session".
\* Read as: a tool output only ever joins the conversation that called it.
LateResultStaysHome ==
    \A c \in Calls : out[c] /= "none" => outAt[c] = issuer[c]

\* resume_provider_session (session_server.ex:704-707): leaving an unconfigured
\* socket open "leaks an upstream connection per retry". Read as: while the
\* call lives, every open socket is openai_pid.
NoOrphanSocket ==
    alive => \A k \in SockIds : sstate[k] = "open" => k = sock

\* end_call (session_server.ex:721-729) makes a live call with no provider
\* connection "unrepresentable"; audio_chunk (:350-351): "openai_pid is nil
\* ONLY inside the bounded reconnect window". Read as: a live session has a
\* socket, or a reconnect timer on the way.
NoFreeze ==
    alive => sock /= None \/ timer /= "none"

\* Proposed rule: @default_reconnect_backoff_ms (session_server.ex:60) names one
\* delay per attempt, so a call gives up on OpenAI only after running every
\* attempt.
EveryAttemptTried ==
    ended = "exhausted" => tries >= MaxAttempts

\* Proposed rule (Rule 2, bounded retries): the call runs at most one reconnect
\* attempt per delay in @default_reconnect_backoff_ms (session_server.ex:60)
\* between two confirmations, however often a socket opens and drops before
\* its session.updated.
AttemptsBounded ==
    tries <= MaxAttempts

\* Proposed rule, the one the cancel that schedule_reconnect used to carry
\* stood in for: a reconnect timer is outstanding only while openai_pid is nil,
\* and the session holds the ref of every timer that can still fire.
NoStrayTimer ==
    stray = 0 /\ (timer /= "none" => sock = None)

\* Proposed rule: handle_info(:reconnect_attempt) (session_server.ex:523) has no
\* guard, so a tick that reached a connected call would open a second socket and
\* orphan the first. No tick is ever queued while the call is connected.
NoTickWhileConnected ==
    ~(alive /\ sock /= None /\ <<"tick", None, None>> \in Range(mbox))

\* The clause at session_server.ex:408-425: after an error that answers its
\* session.update, "this socket will never configure the call", and a call left
\* on it "waits for a listening that never comes". Read as: once nothing is in
\* flight to or from the call's socket, the call is configured.
NoUnconfiguredWait ==
    (alive /\ sock /= None /\ mbox = <<>> /\ up[sock] = <<>>) => ready

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* OpenAI rejects a trigger: a VAD response started before the session heard
\* of it (RT-1). The re-armed trigger answers it; this shows it still happens.
Witness_RejectedTrigger == ~rejected

\* OpenAI rejects the confirmed run's trigger with no server-VAD response at
\* all: the run replied while the session's own trigger was still on the wire.
Witness_OutcomeTriggerRejected == ~rejected

=============================================================================
