---------------------------- MODULE NativeHost ----------------------------
(***************************************************************************)
(* The native host wire (M76 §4.4, D10): the daemon listens on one 0600    *)
(* Unix socket, native_host.sock, and the Fermix app connects to it as the *)
(* host of this Mac's own services. As on the browser host wire the daemon *)
(* asks (a request with an id, answered ok or error) and the app tells     *)
(* (attached, capabilities, host_stopping); unlike it there are no tasks   *)
(* and no tabs: a request is one grant question or one post.               *)
(*                                                                         *)
(* What the spec is about: a due reminder's delivery (MacApp.post) finds   *)
(* the app attached and posts on its link, or opens the app once and waits *)
(* for it under the launch's deadline, and gives up within the cooldown    *)
(* after a launch that never attached; and the app's quit, which is final  *)
(* for its connection and answered host.stop_ack.                          *)
(*                                                                         *)
(* The modules it describes:                                               *)
(*  - FermixCore.Native.HostAvailability: the record (the attached link,   *)
(*    stopping, the pending launch's deadline) and claim/3, which reads it *)
(*    and records a launch in one call (host_availability.ex, :202);   *)
(*    its monitor of the link (:218);                                      *)
(*  - FermixCore.NativeHost.Link: the connection process. Its callers'     *)
(*    requests are one GenServer.call each (request/4, link.ex;         *)
(*    handle_call, :103), written with the next id (write_request, :357),  *)
(*    refused once it took host_stopping (caller_request, :342), which it  *)
(*    answers host.stop_ack (host_stopping, :284); its exit ends every     *)
(*    caller still waiting (:closed);                                      *)
(*  - FermixCore.Native.Notifications.MacApp: the caller. post/2           *)
(*    (mac_app.ex) claims a step (run, :188), opens the app on :launch  *)
(*    (launch, :204), waits on a pending launch (wait, :215), and asks on  *)
(*    the attached link under a bound.                                     *)
(*                                                                         *)
(* The Mac app's native host client (tezra-io/fermix-macos) is an UNPINNED *)
(* MIRROR: it connects, attaches, answers posts, and on quit sends         *)
(* host_stopping and holds its quit for host.stop_ack. The app's own bound *)
(* on that hold is its own and not modelled: StopAlwaysAnswered states the *)
(* daemon's half.                                                          *)
(*                                                                         *)
(* Time is abstract. The launch's deadline passing (Deadline) and the      *)
(* cooldown ending (CooldownEnds) are steps; a caller's request bound      *)
(* running out (Timeout) is a step. Each caller makes one post.            *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - ready/2 (host.status, notifications.authorize): the same claim and   *)
(*    the same one request on the link as post/2, with another type; the  *)
(*    prompt and which surface may raise it are single-call rules ExUnit   *)
(*    covers (mac_app_test.exs);                                           *)
(*  - capabilities reports and notification.action events: the record  *)
(*    holds the report for readers, and a press is one snooze through   *)
(*    Temporal.Registry (notification_action), off the request path;   *)
(*  - a second client while a link lives: Server refuses it                *)
(*    (accept_link, host_already_attached), so the app connects only once  *)
(*    every earlier link of its own has exited, which is the code;         *)
(*  - the socket's 0600 mode, the peer check and the line codec: single-   *)
(*    call rules that ExUnit covers (link_test.exs, protocol_contract_test);*)
(*  - the daemon restarting.                                               *)
(*                                                                         *)
(* One step = one callback of a daemon process (the caller, the link, the  *)
(* record), one thing the app does, or time passing. The app's answer to a *)
(* post and the link's reply to its caller are one step: nothing else      *)
(* reads the answer in between, and the caller's own bound is modelled as  *)
(* racing it.                                                              *)
(***************************************************************************)

\* SOURCE: apps/fermix_core/lib/fermix_core/native/host_availability.ex @ acb7bc813f3c
\* SOURCE: apps/fermix_core/lib/fermix_core/native_host/link.ex#request,handle_call,handle_info,caller_request,write_request,sent,attach,host_stopping,answered,deliver @ 917055f7fa1e
\* SOURCE: apps/fermix_core/lib/fermix_core/native/notifications/mac_app.ex#post,posted,host,run,launch,wait @ 13710aafcf21
\* SOURCE: apps/fermix_core/lib/fermix_core/app_launcher.ex#launch @ d3f98dcfb59f
\* SOURCE: apps/fermix_core/priv/native_host/PROTOCOL.md @ 21d6a07e01a5

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Callers,        \* the due reminders posting at once, e.g. {c1, c2}
    MaxConns,       \* connections the app may open in one behaviour (a bound)
    \* Environment switches: what may happen. Each happens at most once.
    PersonCanOpen,  \* the person opens the app themself
    AppCanQuit,     \* the person quits the app: host_stopping, then the hold
    AppCanCrash,    \* the app dies with no host_stopping
    LaunchCanFail,  \* `open` exits non-zero at once (launch, mac_app.ex)
    \* Mechanism switches: TRUE is the code; each is switched off only by
    \* the check that shows a rule needs it.
    AtomicClaim,          \* the step and the launch's record are one call
                          \* (claim/3, host_availability.ex,:202); FALSE
                          \* reads the record, then records the launch
    Cooldown,             \* a claim within the cooldown after a launch that
                          \* never attached is unavailable (step, cooling?,
                          \* host_availability.ex); FALSE launches again
    RefuseAfterStopping,  \* the link refuses a request once it took
                          \* host_stopping (caller_request, link.ex)
    CallerBound,          \* a request is bounded by the caller's timeout
                          \* (request/4, link.ex)
    StopAck               \* the link answers host_stopping with host.stop_ack
                          \* (host_stopping, link.ex)

Conns == 1..MaxConns
Symm == Permutations(Callers)

VARIABLES
    \* the app (unpinned mirror)
    app,          \* "off" | "starting" | "running"
    appConn,      \* the app's live connection, 0 when none
    nextConn,     \* the number its next connection takes
    quitting,     \* the app sent host_stopping and holds its quit
    \* per connection: the socket, the link process and the wire
    conn,         \* "unused" | "open" (handshaken) | "attached" | "closed"
    linkUp,       \* the link process is alive
    stopSent,     \* the app wrote host_stopping on it
    linkStopping, \* the link took host_stopping
    stopAcked,    \* the link wrote host.stop_ack
    toApp,        \* the callers whose post is written and not yet answered
    \* the record (Native.HostAvailability)
    recConn,      \* the attached connection, 0 when none
    recStopping,  \* that connection's app said it is quitting
    pending,      \* a launch is pending: its deadline has not passed
    cooling,      \* the last launch never attached, within its cooldown
    \* the callers (MacApp.post)
    pc,           \* "claim" | "record" | "open" | "wait" | "call" | "sent" | "done"
    via,          \* the connection a caller asks on, 0 until it has one
    outcome,      \* "none" | "posted" | "unavailable" | "timeout" | "closed"
    \* history, for the properties
    windows,      \* launches recorded: a pending window opened
    opens,        \* times `open` ran
    openedInCooldown, \* a launch was recorded while the cooldown ran
    afterAck,     \* a request was written behind host.stop_ack
    used,         \* the environment kinds that have happened
    quitMidPost   \* host_stopping arrived with a post still unanswered

app_vars == <<app, appConn, nextConn, quitting>>
link_vars == <<conn, linkUp, stopSent, linkStopping, stopAcked, toApp>>
rec_vars == <<recConn, recStopping, pending, cooling>>
caller_vars == <<pc, via, outcome>>
hist_vars == <<windows, opens, openedInCooldown, afterAck, used, quitMidPost>>
vars == <<app_vars, link_vars, rec_vars, caller_vars, hist_vars>>

TypeOK ==
    /\ app \in {"off", "starting", "running"}
    /\ appConn \in 0..MaxConns /\ nextConn \in 1..(MaxConns + 1)
    /\ quitting \in BOOLEAN
    /\ conn \in [Conns -> {"unused", "open", "attached", "closed"}]
    /\ linkUp \in [Conns -> BOOLEAN] /\ stopSent \in [Conns -> BOOLEAN]
    /\ linkStopping \in [Conns -> BOOLEAN] /\ stopAcked \in [Conns -> BOOLEAN]
    /\ toApp \in [Conns -> SUBSET Callers]
    /\ recConn \in 0..MaxConns /\ recStopping \in BOOLEAN
    /\ pending \in BOOLEAN /\ cooling \in BOOLEAN
    /\ pc \in [Callers -> {"claim", "record", "open", "wait", "call", "sent", "done"}]
    /\ via \in [Callers -> 0..MaxConns]
    /\ outcome \in [Callers -> {"none", "posted", "unavailable", "timeout", "closed"}]
    /\ windows \in Nat /\ opens \in Nat
    /\ openedInCooldown \in BOOLEAN /\ afterAck \in BOOLEAN
    /\ used \subseteq {"open", "quit", "crash", "fail"}
    /\ quitMidPost \in BOOLEAN

Init ==
    /\ app = "off" /\ appConn = 0 /\ nextConn = 1 /\ quitting = FALSE
    /\ conn = [i \in Conns |-> "unused"]
    /\ linkUp = [i \in Conns |-> FALSE] /\ stopSent = [i \in Conns |-> FALSE]
    /\ linkStopping = [i \in Conns |-> FALSE] /\ stopAcked = [i \in Conns |-> FALSE]
    /\ toApp = [i \in Conns |-> {}]
    /\ recConn = 0 /\ recStopping = FALSE /\ pending = FALSE /\ cooling = FALSE
    /\ pc = [c \in Callers |-> "claim"] /\ via = [c \in Callers |-> 0]
    /\ outcome = [c \in Callers |-> "none"]
    /\ windows = 0 /\ opens = 0 /\ openedInCooldown = FALSE /\ afterAck = FALSE
    /\ used = {} /\ quitMidPost = FALSE

Finish(c, o) ==
    /\ pc' = [pc EXCEPT ![c] = "done"]
    /\ outcome' = [outcome EXCEPT ![c] = o]

\* A launch is recorded: the pending window opens. Recorded within the
\* cooldown only when the claim does not consult it.
RecordLaunch ==
    /\ pending' = TRUE
    /\ windows' = IF pending THEN windows ELSE windows + 1
    /\ openedInCooldown' = (openedInCooldown \/ (cooling /\ ~pending))

-----------------------------------------------------------------------------
(* The caller: MacApp.post/2                                               *)

\* One claim (run, mac_app.ex; claim/3 and step/2,
\* host_availability.ex-172,:202-207): an attached app that is not
\* quitting is asked on its link; a quitting one is unavailable; a pending
\* launch is waited on (only once it ends does the caller claim again); a
\* launch that never attached is unavailable within the cooldown; otherwise
\* the caller opens the app. AtomicClaim: the launch is recorded in the same
\* call; FALSE records it as the caller's next step (`launching/2`).
Claim(c) ==
    /\ \/ pc[c] = "claim"
       \/ pc[c] = "wait" /\ ~pending
    /\ CASE recConn # 0 /\ ~recStopping ->
              /\ pc' = [pc EXCEPT ![c] = "call"]
              /\ via' = [via EXCEPT ![c] = recConn]
              /\ UNCHANGED <<outcome, pending, windows, openedInCooldown>>
         [] recConn # 0 /\ recStopping ->
              /\ Finish(c, "unavailable")
              /\ UNCHANGED <<via, pending, windows, openedInCooldown>>
         [] pending ->
              /\ pc' = [pc EXCEPT ![c] = "wait"]
              /\ UNCHANGED <<via, outcome, pending, windows, openedInCooldown>>
         [] cooling /\ Cooldown ->
              /\ Finish(c, "unavailable")
              /\ UNCHANGED <<via, pending, windows, openedInCooldown>>
         [] OTHER ->
              /\ IF AtomicClaim
                 THEN /\ RecordLaunch
                      /\ pc' = [pc EXCEPT ![c] = "open"]
                 ELSE /\ pc' = [pc EXCEPT ![c] = "record"]
                      /\ UNCHANGED <<pending, windows, openedInCooldown>>
              /\ UNCHANGED <<via, outcome>>
    /\ UNCHANGED <<app_vars, link_vars, recConn, recStopping, cooling, opens, afterAck, used,
                   quitMidPost>>

\* Without AtomicClaim, the launch is recorded by a second call, after the
\* read that decided it.
Record(c) ==
    /\ pc[c] = "record"
    /\ RecordLaunch
    /\ pc' = [pc EXCEPT ![c] = "open"]
    /\ UNCHANGED <<app_vars, link_vars, recConn, recStopping, cooling, via, outcome, opens,
                   afterAck, used, quitMidPost>>

\* AppLauncher.launch/1 (launch, mac_app.ex): `open` brings the app up,
\* and the caller waits on the launch; or `open` fails at once, the record
\* takes that moment as the launch's deadline (launching/2), and the caller
\* is unavailable.
Open(c) ==
    /\ pc[c] = "open"
    /\ opens' = opens + 1
    /\ \/ /\ app' = IF app = "off" THEN "starting" ELSE app
          /\ pc' = [pc EXCEPT ![c] = "wait"]
          /\ UNCHANGED <<outcome, pending, cooling, used>>
       \/ /\ LaunchCanFail /\ "fail" \notin used
          /\ used' = used \cup {"fail"}
          /\ pending' = FALSE /\ cooling' = TRUE
          /\ Finish(c, "unavailable")
          /\ UNCHANGED app
    /\ UNCHANGED <<appConn, nextConn, quitting, link_vars, recConn, recStopping, via, windows,
                   openedInCooldown, afterAck, quitMidPost>>

\* The link's handle_call (link.ex): a link that has exited answers no
\* call (:closed); one that took host_stopping refuses (caller_request,
\* :342); otherwise the post is written with the next id (write_request,
\* :357).
Call(c) ==
    /\ pc[c] = "call"
    /\ LET i == via[c] IN
       CASE ~linkUp[i] ->
              /\ Finish(c, "closed")
              /\ UNCHANGED <<toApp, afterAck>>
         [] linkStopping[i] /\ RefuseAfterStopping ->
              /\ Finish(c, "unavailable")
              /\ UNCHANGED <<toApp, afterAck>>
         [] OTHER ->
              /\ toApp' = [toApp EXCEPT ![i] = @ \cup {c}]
              /\ afterAck' = (afterAck \/ stopAcked[i])
              /\ pc' = [pc EXCEPT ![c] = "sent"]
              /\ UNCHANGED outcome
    /\ UNCHANGED <<app_vars, conn, linkUp, stopSent, linkStopping, stopAcked, rec_vars, via,
                   windows, opens, openedInCooldown, used, quitMidPost>>

\* The caller's bound runs out (request/4's timeout, link.ex); a late
\* answer finds it gone.
Timeout(c) ==
    /\ CallerBound /\ pc[c] = "sent"
    /\ Finish(c, "timeout")
    /\ UNCHANGED <<app_vars, link_vars, rec_vars, via, hist_vars>>

-----------------------------------------------------------------------------
(* The link and the record                                                 *)

\* The link takes host_stopping (host_stopping, link.ex): final for the
\* connection, the record marks it stopping (HostAvailability.stopping/2,
\* host_availability.ex), and StopAck writes host.stop_ack.
LinkStops(i) ==
    /\ linkUp[i] /\ stopSent[i] /\ ~linkStopping[i]
    /\ linkStopping' = [linkStopping EXCEPT ![i] = TRUE]
    /\ stopAcked' = [stopAcked EXCEPT ![i] = StopAck]
    /\ recStopping' = IF recConn = i THEN TRUE ELSE recStopping
    /\ UNCHANGED <<app_vars, conn, linkUp, stopSent, toApp, recConn, pending, cooling,
                   caller_vars, hist_vars>>

\* The socket closed (tcp_closed, link.ex): the link has read every line
\* the app wrote before it, then exits, and every caller still waiting on it
\* is answered :closed.
LinkExits(i) ==
    /\ linkUp[i] /\ conn[i] = "closed"
    /\ stopSent[i] => linkStopping[i]
    /\ linkUp' = [linkUp EXCEPT ![i] = FALSE]
    /\ LET waiting == {c \in Callers : pc[c] = "sent" /\ via[c] = i} IN
       /\ pc' = [c \in Callers |-> IF c \in waiting THEN "done" ELSE pc[c]]
       /\ outcome' = [c \in Callers |-> IF c \in waiting THEN "closed" ELSE outcome[c]]
    /\ UNCHANGED <<app_vars, conn, stopSent, linkStopping, stopAcked, toApp, rec_vars, via,
                   hist_vars>>

\* The record takes the link's :DOWN (host_availability.ex, detached/1).
RecordDown(i) ==
    /\ ~linkUp[i] /\ recConn = i
    /\ recConn' = 0 /\ recStopping' = FALSE
    /\ UNCHANGED <<app_vars, link_vars, pending, cooling, caller_vars, hist_vars>>

\* The pending launch's deadline passes with no attach: its cooldown starts.
Deadline ==
    /\ pending
    /\ pending' = FALSE /\ cooling' = TRUE
    /\ UNCHANGED <<app_vars, link_vars, recConn, recStopping, caller_vars, hist_vars>>

\* The cooldown ends. It outlasts any caller's own wait (AppLauncher's
\* cooldown_ms against its deadline_ms), so it never ends while a caller is
\* opening the app or waiting on a launch: a caller with no time left opens
\* nothing (unattached_step, host_availability.ex), and a launch counts as one of
\* its polls (launch, mac_app.ex).
CooldownEnds ==
    /\ cooling
    /\ \A c \in Callers : pc[c] \notin {"record", "open", "wait"}
    /\ cooling' = FALSE
    /\ UNCHANGED <<app_vars, link_vars, recConn, recStopping, pending, caller_vars, hist_vars>>

-----------------------------------------------------------------------------
(* The app (unpinned mirror)                                               *)

PersonOpens ==
    /\ PersonCanOpen /\ "open" \notin used /\ app = "off"
    /\ app' = "starting" /\ used' = used \cup {"open"}
    /\ UNCHANGED <<appConn, nextConn, quitting, link_vars, rec_vars, caller_vars, windows, opens,
                   openedInCooldown, afterAck, quitMidPost>>

\* The app connects and completes the handshake. Server takes one link at a
\* time, so the app's earlier links have all exited.
Connect ==
    /\ app \in {"starting", "running"} /\ appConn = 0 /\ nextConn <= MaxConns
    /\ \A j \in Conns : ~linkUp[j]
    /\ conn' = [conn EXCEPT ![nextConn] = "open"]
    /\ linkUp' = [linkUp EXCEPT ![nextConn] = TRUE]
    /\ appConn' = nextConn /\ nextConn' = nextConn + 1 /\ app' = "running"
    /\ UNCHANGED <<quitting, stopSent, linkStopping, stopAcked, toApp, rec_vars, caller_vars,
                   hist_vars>>

\* `attached`, as the link takes it (attach, link.ex): the record names
\* this connection, and an earlier launch is void (attached/4,
\* host_availability.ex).
Attach ==
    /\ appConn # 0 /\ conn[appConn] = "open"
    /\ conn' = [conn EXCEPT ![appConn] = "attached"]
    /\ recConn' = appConn /\ recStopping' = FALSE /\ pending' = FALSE /\ cooling' = FALSE
    /\ UNCHANGED <<app_vars, linkUp, stopSent, linkStopping, stopAcked, toApp, caller_vars,
                   hist_vars>>

\* The app answers a post on its attached connection, and the link replies
\* to the caller (answered/deliver, link.ex); an answer to a caller whose
\* bound ran out is dropped.
Answer(c) ==
    /\ appConn # 0 /\ conn[appConn] = "attached" /\ c \in toApp[appConn]
    /\ toApp' = [toApp EXCEPT ![appConn] = @ \ {c}]
    /\ IF pc[c] = "sent" /\ via[c] = appConn
       THEN Finish(c, "posted")
       ELSE UNCHANGED <<pc, outcome>>
    /\ UNCHANGED <<app_vars, conn, linkUp, stopSent, linkStopping, stopAcked, rec_vars, via,
                   hist_vars>>

\* The person quits the app: it sends host_stopping and holds its quit.
Quit ==
    /\ AppCanQuit /\ "quit" \notin used
    /\ appConn # 0 /\ conn[appConn] = "attached" /\ ~quitting
    /\ quitting' = TRUE /\ used' = used \cup {"quit"}
    /\ stopSent' = [stopSent EXCEPT ![appConn] = TRUE]
    /\ quitMidPost' = (quitMidPost \/ toApp[appConn] # {})
    /\ UNCHANGED <<app, appConn, nextConn, conn, linkUp, linkStopping, stopAcked, toApp,
                   rec_vars, caller_vars, windows, opens, openedInCooldown, afterAck>>

\* host.stop_ack read: the app finishes quitting and its socket closes.
QuitDone ==
    /\ quitting /\ stopAcked[appConn]
    /\ app' = "off" /\ appConn' = 0 /\ quitting' = FALSE
    /\ conn' = [conn EXCEPT ![appConn] = "closed"]
    /\ UNCHANGED <<nextConn, linkUp, stopSent, linkStopping, stopAcked, toApp, rec_vars,
                   caller_vars, hist_vars>>

\* The app dies with no host_stopping; its socket closes.
Crash ==
    /\ AppCanCrash /\ "crash" \notin used /\ app # "off"
    /\ app' = "off" /\ appConn' = 0 /\ quitting' = FALSE /\ used' = used \cup {"crash"}
    /\ conn' = IF appConn # 0 THEN [conn EXCEPT ![appConn] = "closed"] ELSE conn
    /\ UNCHANGED <<nextConn, linkUp, stopSent, linkStopping, stopAcked, toApp, rec_vars,
                   caller_vars, windows, opens, openedInCooldown, afterAck, quitMidPost>>

-----------------------------------------------------------------------------

\* The legitimate end: every caller ended, every closed socket's link has
\* exited and the record has taken its :DOWN, and no launch is pending.
\* The app may be off, up, or holding a quit. Deadlock checking is on, so
\* any other state where nothing can happen is reported as a wedge.
Done ==
    /\ \A c \in Callers : pc[c] = "done"
    /\ \A i \in Conns : conn[i] = "closed" => ~linkUp[i]
    /\ ~(recConn # 0 /\ ~linkUp[recConn])
    /\ ~pending

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E c \in Callers : Claim(c) \/ Record(c) \/ Open(c) \/ Call(c) \/ Timeout(c) \/ Answer(c)
    \/ \E i \in Conns : LinkStops(i) \/ LinkExits(i) \/ RecordDown(i)
    \/ Deadline \/ CooldownEnds
    \/ PersonOpens \/ Connect \/ Attach \/ Quit \/ QuitDone \/ Crash
    \/ Terminated

\* Fairness only on what Fermix drives: the callers, the links, the record,
\* and the launch's own deadline. None on the app, the person or the
\* cooldown's end.
Fairness ==
    /\ \A c \in Callers :
          WF_vars(Claim(c)) /\ WF_vars(Record(c)) /\ WF_vars(Open(c)) /\ WF_vars(Call(c))
          /\ WF_vars(Timeout(c))
    /\ \A i \in Conns : WF_vars(LinkStops(i)) /\ WF_vars(LinkExits(i)) /\ WF_vars(RecordDown(i))
    /\ WF_vars(Deadline)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* "the app is opened once however many reminders come while it comes up"
\* (MacApp moduledoc; HostAvailability.claim/3's doc): every run of `open`
\* belongs to a launch window of its own.
OneOpenPerLaunch == opens <= windows

\* "A launch that never attached is not repeated within the cooldown after
\* it" (HostAvailability moduledoc).
NoLaunchInCooldown == ~openedInCooldown

\* "A request after it is refused here, before it reaches the wire"
\* (NativeHost.Link moduledoc): nothing is written behind host.stop_ack,
\* after which the app quits and answers nothing.
NothingAfterStopAck == ~afterAck

\* Proposed rule: every delivery attempt ends, posted or with a reason the
\* rail classifies, whatever the app does.
EveryCallerEnds == \A c \in Callers : <>(pc[c] = "done")

\* "`host_stopping` ... is answered with `host.stop_ack`" (NativeHost.Link
\* moduledoc): the app's quit hold always gets its answer from the daemon.
StopAlwaysAnswered == \A i \in Conns : stopSent[i] ~> stopAcked[i]

\* Witnesses: each defined as "the scenario never happens".
Witness_LaunchedAndPosted == ~(opens >= 1 /\ \E c \in Callers : outcome[c] = "posted")
Witness_QuitMidPost == ~quitMidPost

=============================================================================
