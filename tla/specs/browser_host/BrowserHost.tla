---------------------------- MODULE BrowserHost ----------------------------
(***************************************************************************)
(* The browser host protocol: the daemon listens on one 0600 Unix socket,  *)
(* browser_host.sock (newline JSON, a hello handshake), and the Mac app    *)
(* connects to it as the host: its web views run a task's browser work on  *)
(* the person's own machine. Direction is reversed from the chat wire: the *)
(* daemon sends requests with an id and the host answers each with ok or   *)
(* error; the host sends unsolicited events (attached, availability,       *)
(* tab.closed, dialog.opened, download.*, host_stopping).                  *)
(*                                                                         *)
(* Written as a DESIGN SPEC before the code (3ee506f3), and now re-read    *)
(* and pinned by function against feat/browser-host-wire (PR #94, on       *)
(* feat/browser-backend-boundary, PR #93), as companion_session was.       *)
(* BROWSER-1 to BROWSER-8 are what the design asked of the implementation; *)
(* all are fixed or hold by construction, as the findings section records  *)
(* with the commit that proves each. The re-read also found TurnMarker, a  *)
(* mechanism the design did not ask for (see "Not modelled").              *)
(*                                                                         *)
(* The daemon side, still one process group here ("daemon"), turned out to *)
(* be several real modules, not the one process the design guessed at:     *)
(*  - FermixCore.Browser.HostServer: the pane task, running inside its own *)
(*    ProfileServer (one live task per profile, not one process for the    *)
(*    whole daemon). It binds a host task to the connection it was decided *)
(*    on (bind, host_server.ex:387-413) and to that connection alone       *)
(*    (check_host, :417-430); it fails the task on that connection's :DOWN, *)
(*    the app's host_stopping, or the person's own task.cancel for it      *)
(*    (handle_message, :136-167; lose/lose_cancelled, :456-475) and names   *)
(*    its tabs by the connection (public_id, :698);                        *)
(*  - FermixCore.Browser.HostAvailability: the one process that holds the  *)
(*    host's last report, with no probe, and which connection it is on;    *)
(*  - FermixCore.Browser.HostLauncher: the pure decision table (step,      *)
(*    host_launcher.ex:95-105) that opens the app on demand and waits for  *)
(*    its attach and first report under one deadline, shared by every task *)
(*    that finds a launch pending (SingleLaunch), and bounded by a cooldown *)
(*    after a launch that never attached -- BROWSER-6's bounded answer,    *)
(*    since a crashed launch and a quit before attach look identical;      *)
(*  - FermixCore.Browser.Routing: decides a task's backend once, when no   *)
(*    profile is live for it, and pins every later request of it to the    *)
(*    backend the live profile was started on (for_request, routing.ex:42) *)
(*    (ProfileManager.backend, not this spec's: it is not one of the files *)
(*    below, since it also covers profiles this design never routes);      *)
(*  - FermixCore.Browser.execute/dispatch (browser.ex): where a call first *)
(*    meets a lost turn's TurnMarker mark and, past that, Routing;         *)
(*  - FermixChannels.BrowserHost.{Endpoint,Connection,Supervisor}: the     *)
(*    listener (one host at a time, endpoint.ex:209-219) and its           *)
(*    connection process, the handshake and the line codec. A connection   *)
(*    forwards every task's request and release in the order its own      *)
(*    process took them off its mailbox -- BROWSER-1's fix -- and its exit *)
(*    is HostServer's :DOWN. The person's own cancel of one task, from its *)
(*    tab in the app, arrives here as task.cancel and is told to that one  *)
(*    task and released exactly as release_task/2 releases one that ends  *)
(*    on its own (cancel_task, connection.ex).                            *)
(*                                                                         *)
(* The Mac app's BrowserHostReducer (tezra-io/fermix-macos) still owns the *)
(* tabs, the registry, the caps, the availability reports and the quit     *)
(* hold, and it still lives in another repository: an UNPINNED MIRROR, as  *)
(* it was in the design spec. This spec states what it must do; the app's  *)
(* own tests hold it to that.                                              *)
(*                                                                         *)
(* Managed Chrome is ONE abstract "elsewhere" that always completes: the   *)
(* ProfileManager's own rules (its tab cap evicts the oldest tab; the host *)
(* refuses instead) are not this spec's.                                   *)
(*                                                                         *)
(* Only the order of each direction matters: each is one FIFO per          *)
(* connection. What the daemon writes after the socket closed is lost;     *)
(* what the host wrote before it closed is still read, then the :DOWN.     *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - page.snapshot, page.screenshot, page.upload, dialog.resolve,         *)
(*    cookies.*, host.status, tab.navigate, tab.list, tab.focus and        *)
(*    tab.close: each is one request on a tab the task owns, answered like *)
(*    page.act (a task step here is tab.open or page.act). tab.list's      *)
(*    opener_tab_id (protocol.ex#listed_tab?) is the wire field BROWSER-3   *)
(*    asked for, so a popup's owner can be told to the daemon; the caps    *)
(*    and the release that read it are still the app reducer's own,        *)
(*    unpinned;                                                            *)
(*  - tab.closed, dialog.opened and download.* events: informational to    *)
(*    the daemon; a request on a closed tab is answered with an error,     *)
(*    which is what the model uses;                                        *)
(*  - which of lock, display sleep or app termination made the host        *)
(*    unavailable: one reason, "locked", stands for all three;             *)
(*  - a new connection attaching before the daemon has taken the old one's *)
(*    :DOWN: Endpoint refuses a second client while one is attached        *)
(*    (accept_connection, host_already_attached, endpoint.ex:209-219), so  *)
(*    the model attaching only after it is the code, not a shortcut taken  *)
(*    for the model's sake; the daemon itself restarting is not modelled;  *)
(*  - the socket's 0600 mode, the peer check and the line codec: single-   *)
(*    call rules that ExUnit covers;                                       *)
(*  - FermixCore.Browser.TurnMarker: a turn (the caller of a task, not the *)
(*    task itself) that loses its pane marks every later browser call of   *)
(*    THAT TURN with the same sentence (dispatch reads the mark before     *)
(*    Routing ever runs, browser.ex:120-126), so a turn whose first task   *)
(*    failed on the host never starts a second task Routing could send to  *)
(*    Chrome. This spec's Tasks are already turn-sized: a Task is one      *)
(*    script run to one Terminal state, and nothing here lets a second     *)
(*    Task share a first one's caller once it has ended, so                *)
(*    NoChromeAfterHostFailure cannot see the gap TurnMarker closes, and no *)
(*    needs check can turn it off meaningfully -- switching a mechanism    *)
(*    off must break a rule the spec can state, and this one cannot state  *)
(*    this rule. Giving a turn more than one task in sequence would be a   *)
(*    bigger change than a re-read, so it is recorded here rather than     *)
(*    modelled.                                                            *)
(*                                                                         *)
(* One step = one callback of the HostServer, one reducer step of the      *)
(* host, or one thing the person, a page or the environment does.          *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/browser.ex#dispatch,dispatch_profile @ d5d1f1812173
\* SOURCE: apps/fermix_core/lib/fermix_core/browser/host_server.ex#init,stop,handle_message,operate,ensure_task,bind,check_host,lose,lost_error,request,host_error,public_id @ 367903d92b93
\* SOURCE: apps/fermix_core/lib/fermix_core/browser/host_availability.ex @ 5ea87b4f20e6
\* SOURCE: apps/fermix_core/lib/fermix_core/browser/host_launcher.ex @ 731c241a3438
\* SOURCE: apps/fermix_core/lib/fermix_core/browser/routing.ex @ 4f623fbc4804
\* SOURCE: apps/fermix_core/lib/fermix_core/browser/turn_marker.ex @ 9e55937dc45a
\* SOURCE: apps/fermix_core/lib/fermix_core/browser_host/protocol.ex#listed_tab? @ 883cbc90b089
\* SOURCE: apps/fermix_core/lib/fermix_core/browser_host/link.ex @ 279273a16f24
\* SOURCE: apps/fermix_channels/lib/fermix_channels/browser_host/connection.ex#attach,availability,host_stopping,task_request,bind_task,release_task,task_exited,write_request,cancel_task @ 8e5a12ad7b4c
\* SOURCE: apps/fermix_channels/lib/fermix_channels/browser_host/endpoint.ex @ 50e6a7f26529
\* SOURCE: apps/fermix_channels/lib/fermix_channels/browser_host/supervisor.ex @ a91e3fe95333
\* SOURCE: apps/fermix_core/priv/browser_host/PROTOCOL.md @ d9dfad12723c
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Tasks,          \* the browser tasks, e.g. {t1, t2}
    OpensPerTask,   \* tab.open requests in each task's script (1 or 2)
    MaxTabs,        \* tab ids the model can hand out (a bound, not a cap)
    TaskCap,        \* live tabs one task may own on the host
    GlobalCap,      \* live task tabs on the host in all
    \* Environment switches: what may happen around a task. Each enabled
    \* kind happens at most once per behaviour.
    HostCanDetach,      \* the connection drops while the app runs on (its socket code
                        \* restarts, the daemon's listener is replaced); the app
                        \* reconnects on its own
    HostCanCrash,       \* the app process dies: every tab with it
    SessionCanLock,     \* the screen locks, and may unlock again (display sleep and app
                        \* termination make the host unavailable the same way)
    PersonCanQuit,      \* the person quits the app
    PersonOpensTabs,    \* the person opens a tab of their own in the app
    PersonCanCloseTabs, \* the person tries to close a tab, any tab
    PersonCanCancel,    \* the person cancels a task: in chat before it has a host tab (its
                        \* turn ends, the caller's :DOWN), or, once it is on the host, from
                        \* its own tab in the app -- task.cancel over the wire
    LaunchCanTimeOut,   \* a launched app may never attach: it hangs, or macOS refuses it
    PagesOpenPopups,    \* a page opens a popup from any live tab
    \* Mechanism switches: what the design does about it. TRUE is the design;
    \* each is switched off only by the checks that show a rule needs it.
    DecideOnceAtStart,  \* the backend is decided once, when no profile is live for the
                        \* task (Routing.for_request, routing.ex:42-48), and a host task is
                        \* bound to the connection it was decided on and refused on any
                        \* other (HostServer.check_host, host_server.ex:417-430); FALSE
                        \* re-decides before every step
    LastReportWins,     \* HostAvailability keeps the host's last report and hands it back
                        \* with no probe (report/3, current/1, host_availability.ex:97-100,
                        \* :72-77); FALSE keeps the first report after the attach
    SingleLaunch,       \* a task that finds a launch already pending waits on it
                        \* (HostLauncher.pending?, host_launcher.ex:129); FALSE launches
                        \* again
    LaunchDeadline,     \* the tasks waiting on a launch decide Chrome when its one
                        \* deadline passes (waited_deadline, launched_step,
                        \* host_launcher.ex:154-158,:134-135); FALSE waits for the attach
                        \* and first report
    OwnershipRegistry,  \* the host records an owner for every tab: the task that opened
                        \* it, its opener's owner for a popup, the person for their own;
                        \* release, idle and the caps read it. Still the app reducer's own
                        \* state, an unpinned mirror; the engine's own part is the wire
                        \* field a popup's owner can ride on, tab.list's opener_tab_id
                        \* (protocol.ex#listed_tab?, BROWSER-3). FALSE ("no registry"):
                        \* the host records only the person's own tabs, and every other
                        \* tab, a popup included, joins one pool that any task's release
                        \* closes; it counts itself idle with no person tab and no
                        \* request waiting
    ReleaseOnce,        \* the host drops a tab's record when it releases or closes it,
                        \* so a second release of the same task finds nothing (app-side,
                        \* unpinned; the engine's own release is already idempotent by
                        \* construction, see ReleaseOnce's needs check and BROWSER-2)
    PersonCannotCloseTaskTab, \* the host refuses the person's close of a tab the
                        \* registry gives to a task (app-side, unpinned)
    TabCaps,            \* tab.open and a popup past TaskCap or GlobalCap are refused
                        \* (app-side, unpinned; the engine only carries the two numbers on
                        \* tab.open, task_tab_cap and tab_cap, host_server.ex:184-186)
    StoppingHandshake,  \* on quit an attached host sends host_stopping and holds its
                        \* quit for the daemon's answer (app-side, unpinned); the engine's
                        \* half is answering host.stop_ack behind every release
                        \* (Connection.host_stopping, connection.ex:270-284, BROWSER-7).
                        \* FALSE quits at once
    QuitBound,          \* the held quit ends when a bound elapses, answer or not
                        \* (app-side, unpinned)
    NoChromeRetry       \* a host task the host fails is failed with a sentence, never
                        \* re-routed to Chrome (HostServer.lose, host_server.ex:434-438),
                        \* and TurnMarker keeps the rest of its turn off Chrome too (not
                        \* modelled here, see the header); FALSE re-runs the task on
                        \* Chrome

VARIABLES
    \* FermixCore.Browser.HostServer and the tasks' browser calls
    status,     \* status[t]: "idle", "waiting" (on a launch), "running", "done_host",
                \* "done_chrome", "failed" (with a sentence; a cancel included)
    route,      \* route[t]: "none", "host", "chrome"
    tgen,       \* tgen[t]: the connection a host task is bound to
    decGen,     \* decGen[t]: the connection t was first routed to the host on, 0 before
    pc,         \* pc[t]: the next step of t's script
    busy,       \* busy[t]: t's request is out, unanswered
    ttab,       \* ttab[t]: the tab t's first tab.open was answered with, 0 before
    attached,   \* HostServer holds a live connection (set at attached, cleared at :DOWN)
    dgen,       \* the connection HostServer took attached from
    cache,      \* its availability for that connection: "none", "available",
                \* "unavailable", "stopping"
    launching,  \* launches pending: started, waiting for the attach and first report
    launchOk,   \* HostServer may launch the app (cleared by the person's quit)
    \* the socket, one FIFO each way
    toHost,     \* requests on their way to the host
    toDaemon,   \* answers and events on their way to HostServer
    conn,       \* the connection is open
    gen,        \* the id of the latest connection
    \* the Mac app (BrowserHostReducer)
    app,        \* "off", "starting" (running, not connected), "up", "stopping"
    locked,     \* the session is locked: the host is unavailable
    tab,        \* tab[i]: "none", "live", "closed", "died" (with the app)
    reg,        \* reg[i]: the registry's record: a task, "person", "pool" (no registry),
                \* or "nobody"
    views,      \* the web view pool: "cold" or "warm"
    quit,       \* "no", "stopping" (holding), "done"
    \* ground truth and budgets
    own,        \* own[i]: who a tab really belongs to: a task or "person"
    popup,      \* popup[i]: tab i was opened by a page
    closes,     \* closes[i]: times the host released or closed tab i
    left,       \* left[k]: environment actions of kind k still possible
    \* observers (read only by rules and witnesses)
    lastRecv,       \* the last availability report HostServer took on this connection
    badDecision,    \* a task was routed to the host while lastRecv said unavailable
    hostGen,        \* hostGen[t]: the connection the host first handled a request of t
                    \* on, 0 before
    hostRan,        \* hostRan[t]: the host carried out a step of t (answered ok)
    withoutHost,    \* the host handled a request of a task on another connection than
                    \* the one it first handled one on
    chromeStep,     \* chromeStep[t]: t ran on Chrome
    personHit,      \* a release the app runs on after (a task's, the host's on losing
                    \* the daemon, or the idle one) closed a person's tab
    personClosed,   \* the person closed a tab a running task owns
    idleHit,        \* the idle release closed a tab a running task owns
    abandoned,      \* the app detached by its quit while a host task still ran,
                    \* before the bound elapsed
    lockGap,        \* tasks routed to the host that the lock found before their
                    \* first host step
    popupCounted,   \* a tab.open was refused at the cap while its task held a popup
    quitMidAct,     \* the handshake quit began with a page.act out
    closeRefused,   \* tasks whose tab the person tried to close and was refused
    cancelled       \* tasks the person cancelled

daemon == <<status, route, tgen, decGen, pc, busy, ttab, attached, dgen, cache, launching,
            launchOk>>
wire   == <<toHost, toDaemon, conn, gen>>
host   == <<app, locked, tab, reg, views, quit>>
truth  == <<own, popup, closes, left>>
obs    == <<lastRecv, badDecision, hostGen, hostRan, withoutHost, chromeStep, personHit,
            personClosed, idleHit, abandoned, lockGap, popupCounted, quitMidAct, closeRefused,
            cancelled>>
vars == <<daemon, wire, host, truth, obs>>

\* Tasks play the same part: invariant checks may reduce by symmetry.
Symm == Permutations(Tasks)

Terminal == {"done_host", "done_chrome", "failed"}
Script == IF OpensPerTask = 2 THEN <<"open", "act", "open">> ELSE <<"open", "act">>
TabIds == 1..MaxTabs
Kinds == {"lock", "unlock", "detach", "crash", "quit", "popen", "pclose", "cancel", "popup"}
Allowed(k) ==
    CASE k \in {"lock", "unlock"} -> SessionCanLock
      [] k = "detach" -> HostCanDetach
      [] k = "crash" -> HostCanCrash
      [] k = "quit" -> PersonCanQuit
      [] k = "popen" -> PersonOpensTabs
      [] k = "pclose" -> PersonCanCloseTabs
      [] k = "cancel" -> PersonCanCancel
      [] k = "popup" -> PagesOpenPopups

ToHostMsgs ==
    ({"open"} \X Tasks) \cup ({"act"} \X Tasks \X (0..MaxTabs))
    \cup ({"release"} \X SUBSET Tasks) \cup {<<"stop_ack">>}
ToDaemonMsgs ==
    {<<"attached">>, <<"stopping">>} \cup ({"avail"} \X {"available", "unavailable"})
    \cup ({"ok"} \X Tasks \X (0..MaxTabs)) \cup ({"err"} \X Tasks) \cup ({"cancel"} \X Tasks)

TypeOK ==
    /\ status \in [Tasks -> {"idle", "waiting", "running"} \cup Terminal]
    /\ route \in [Tasks -> {"none", "host", "chrome"}]
    /\ tgen \in [Tasks -> Nat] /\ decGen \in [Tasks -> Nat]
    /\ pc \in [Tasks -> 1..(Len(Script) + 1)]
    /\ busy \in [Tasks -> BOOLEAN]
    /\ ttab \in [Tasks -> 0..MaxTabs]
    /\ attached \in BOOLEAN /\ dgen \in Nat
    /\ cache \in {"none", "available", "unavailable", "stopping"}
    /\ launching \in Nat /\ launchOk \in BOOLEAN
    /\ toHost \in Seq(ToHostMsgs) /\ toDaemon \in Seq(ToDaemonMsgs)
    /\ conn \in BOOLEAN /\ gen \in Nat
    /\ app \in {"off", "starting", "up", "stopping"}
    /\ locked \in BOOLEAN
    /\ tab \in [TabIds -> {"none", "live", "closed", "died"}]
    /\ reg \in [TabIds -> Tasks \cup {"person", "pool", "nobody"}]
    /\ views \in {"cold", "warm"}
    /\ quit \in {"no", "stopping", "done"}
    /\ own \in [TabIds -> Tasks \cup {"person", "nobody"}]
    /\ popup \in [TabIds -> BOOLEAN]
    /\ closes \in [TabIds -> Nat]
    /\ left \in [Kinds -> 0..1]
    /\ lastRecv \in {"none", "available", "unavailable"}
    /\ badDecision \in BOOLEAN /\ withoutHost \in BOOLEAN
    /\ hostGen \in [Tasks -> Nat] /\ hostRan \in [Tasks -> BOOLEAN]
    /\ chromeStep \in [Tasks -> BOOLEAN]
    /\ personHit \in BOOLEAN /\ personClosed \in BOOLEAN /\ idleHit \in BOOLEAN
    /\ abandoned \in BOOLEAN /\ popupCounted \in BOOLEAN /\ quitMidAct \in BOOLEAN
    /\ lockGap \subseteq Tasks /\ closeRefused \subseteq Tasks /\ cancelled \subseteq Tasks

-----------------------------------------------------------------------------
(* Helpers *)

Live(i) == tab[i] = "live"
Running(t) == status[t] = "running"

\* A record that names a task, or the pool that stands for tasks without the
\* registry: what the caps count and what a release closes.
TaskRecord(r) == r \notin {"person", "nobody"}
Owned(r) == Cardinality({i \in TabIds : Live(i) /\ reg[i] = r})
TaskTabs == Cardinality({i \in TabIds : Live(i) /\ TaskRecord(reg[i])})

\* TabCaps: one more tab for record r would pass the task's cap or the
\* global cap. Refused, not queued.
AtCap(r) == TabCaps /\ ((r \in Tasks /\ Owned(r) >= TaskCap) \/ TaskTabs >= GlobalCap)

\* The next tab id; the model's bound, not a rule of the design.
NewTab ==
    IF \E i \in TabIds : tab[i] = "none"
    THEN CHOOSE i \in TabIds : tab[i] = "none" /\ \A j \in TabIds : tab[j] = "none" => i <= j
    ELSE Assert(FALSE, "MaxTabs too small for this check")

\* A task whose tab it is, still running as HostServer sees it.
HeldByRunningTask(i) == own[i] \in Tasks /\ status[own[i]] \in {"waiting", "running"}

\* The host releases every tab whose record is in R: each is closed if
\* still live and counted in closes. ReleaseOnce drops the record, so a
\* second release of the same task finds nothing. Without the registry
\* (no registry) a task's release closes the whole pool. A person's tab
\* closed here is touched (personHit) when the app runs on afterwards; the
\* release at host_stopping is the start of a quit that ends every tab.
ReleaseTabsAs(R, touches) ==
    LET S == {i \in TabIds : reg[i] \in R} IN
    /\ tab' = [i \in TabIds |-> IF i \in S /\ Live(i) THEN "closed" ELSE tab[i]]
    /\ closes' = [i \in TabIds |-> IF i \in S THEN closes[i] + 1 ELSE closes[i]]
    /\ reg' = [i \in TabIds |-> IF i \in S /\ ReleaseOnce THEN "nobody" ELSE reg[i]]
    /\ personHit' = (personHit \/ (touches /\ \E i \in S : Live(i) /\ own[i] = "person"))
    /\ idleHit' = idleHit
ReleaseTabs(R) == ReleaseTabsAs(R, TRUE)

AllTaskRecords == Tasks \cup {"pool"}

\* The app exits on the spot: it releases every task's tabs, and the rest
\* (the person's) die with it.
ReleaseAndExit ==
    LET S == {i \in TabIds : reg[i] \in AllTaskRecords} IN
    /\ tab' = [i \in TabIds |-> IF Live(i) THEN (IF i \in S THEN "closed" ELSE "died")
                               ELSE tab[i]]
    /\ closes' = [i \in TabIds |-> IF i \in S THEN closes[i] + 1 ELSE closes[i]]
    /\ reg' = [i \in TabIds |-> "nobody"] /\ views' = "cold"
    /\ UNCHANGED <<personHit, idleHit>>

TaskRelease(t) == IF OwnershipRegistry THEN {t} ELSE {"pool"}

\* What the daemon writes reaches the host only while the socket is open.
Send(msgs) == toHost' = IF conn THEN toHost \o msgs ELSE toHost
\* What the host writes is read by HostServer even after the socket closed.
Tell(msgs) == toDaemon' = toDaemon \o msgs

AvailOf(l) == IF l THEN "unavailable" ELSE "available"
HostUsable == attached /\ cache = "available"

\* HostServer's host tasks on connection g.
HostTasks(g) == {t \in Tasks : Running(t) /\ route[t] = "host" /\ tgen[t] = g}

\* HostServer ends the host tasks S because their host failed them (it went
\* unavailable, stopped, detached or crashed). NoChromeRetry: each fails
\* with a sentence. Without it each is re-run on Chrome. The caller sends
\* task.release for them while the socket is up.
EndHostTasks(S) ==
    /\ status' = [t \in Tasks |-> IF t \in S /\ NoChromeRetry THEN "failed" ELSE status[t]]
    /\ route' = [t \in Tasks |-> IF t \in S /\ ~NoChromeRetry THEN "chrome" ELSE route[t]]
    /\ busy' = [t \in Tasks |-> IF t \in S THEN FALSE ELSE busy[t]]
ReleaseFor(S) == IF S /= {} THEN <<<<"release", S>>>> ELSE <<>>

\* The waiting tasks decide on the report v: available runs them on the
\* host, bound to this connection; anything else runs them on Chrome.
Settle(v) ==
    LET W == {t \in Tasks : status[t] = "waiting"}
        onHost == v = "available"
    IN /\ status' = [t \in Tasks |-> IF t \in W THEN "running" ELSE status[t]]
       /\ route' = [t \in Tasks |-> IF t \in W THEN (IF onHost THEN "host" ELSE "chrome")
                                    ELSE route[t]]
       /\ tgen' = [t \in Tasks |-> IF t \in W /\ onHost THEN dgen ELSE tgen[t]]
       /\ decGen' = [t \in Tasks |-> IF t \in W /\ onHost /\ decGen[t] = 0 THEN dgen
                                     ELSE decGen[t]]

-----------------------------------------------------------------------------
(* FermixCore.Browser.HostServer and the tasks' calls through the backend  *)
(* boundary                                                               *)

\* A task's first browser call: decided once, when no profile is live for it
\* (Routing.for_request, routing.ex:42-48; ProfileManager.backend is nil).
\*  - An attached host whose report says available runs it, bound to this
\*    connection (HostAvailability.usable?, host_availability.ex:116-119).
\*    With LastReportWins that is the last report; without, the first after
\*    the attach.
\*  - No host attached and launching allowed: HostLauncher opens the app
\*    hidden (`launch/1`, host_launcher.ex:186-191, `open -g -j -b <bundle>`),
\*    and the task waits for the attach and the first report under one
\*    deadline (launch_step, :120-127). SingleLaunch: a launch already
\*    pending is waited on, not repeated (pending?, :129).
\*  - Anything else (attached with no report yet, unavailable, stopping, or
\*    launching not allowed) runs it on Chrome (step, host_launcher.ex:95-105).
Decide(t) ==
    /\ status[t] = "idle"
    /\ IF HostUsable
       THEN /\ status' = [status EXCEPT ![t] = "running"]
            /\ route' = [route EXCEPT ![t] = "host"]
            /\ tgen' = [tgen EXCEPT ![t] = dgen]
            /\ decGen' = [decGen EXCEPT ![t] = dgen]
            /\ badDecision' = (badDecision \/ lastRecv /= "available")
            /\ UNCHANGED <<launching, app>>
       ELSE IF ~attached /\ launchOk
       THEN /\ status' = [status EXCEPT ![t] = "waiting"]
            /\ IF SingleLaunch /\ launching > 0
               THEN UNCHANGED <<launching, app>>
               ELSE /\ launching' = launching + 1
                    /\ app' = IF app = "off" THEN "starting" ELSE app
            /\ UNCHANGED <<route, tgen, decGen, badDecision>>
       ELSE /\ status' = [status EXCEPT ![t] = "running"]
            /\ route' = [route EXCEPT ![t] = "chrome"]
            /\ UNCHANGED <<tgen, decGen, launching, app, badDecision>>
    /\ UNCHANGED <<pc, busy, ttab, attached, dgen, cache, launchOk, wire, locked, tab, reg,
                   views, quit, truth, lastRecv, hostGen, hostRan, withoutHost, chromeStep,
                   personHit, personClosed, idleHit, abandoned, lockGap, popupCounted,
                   quitMidAct, closeRefused, cancelled>>

\* The launch's one deadline passes (HostLauncher's own clock, recorded
\* before the app is opened so a task that starts while it comes up finds
\* the launch pending: `launching`, host_launcher.ex:163-164; `waited_deadline`,
\* :154-158): every task waiting on it runs on Chrome.
Deadline ==
    /\ LaunchDeadline /\ launching > 0
    /\ launching' = 0
    /\ Settle("none")
    /\ UNCHANGED <<pc, busy, ttab, attached, dgen, cache, launchOk, wire, host, truth, obs>>

\* Where t's next step goes. DecideOnceAtStart: where it was decided --
\* route[t] never changes once set, because Routing.for_request only
\* re-decides when no profile is live (routing.ex:44-47) and a live host
\* profile's task is refused on any other connection (check_host,
\* host_server.ex:417-430). Without it the step re-decides from what
\* HostServer knows now, and NoChromeRetry still refuses Chrome to a task
\* once routed to the host.
Resolve(t) ==
    IF DecideOnceAtStart THEN route[t]
    ELSE IF HostUsable THEN "host"
    ELSE IF NoChromeRetry /\ decGen[t] /= 0 THEN "fail"
    ELSE "chrome"

\* A running task takes its next step through the backend boundary
\* (HostServer.operate/ensure_task, host_server.ex:376-385):
\*  - on the host, its next request (tab.open, then page.act on its tab,
\*    `request`, :449-462), and it waits for the answer; with the script
\*    done it completes and HostServer releases it (`Link.release`,
\*    `stop`, :107-129, BROWSER-1/2's `task.release`);
\*  - on Chrome, managed Chrome runs the rest of it and completes (not this
\*    spec's, see the header).
TaskStep(t) ==
    /\ Running(t) /\ ~busy[t]
    /\ LET r == Resolve(t) IN
       CASE r = "host" /\ pc[t] <= Len(Script) ->
              /\ Send(<<IF Script[pc[t]] = "open" THEN <<"open", t>>
                        ELSE <<"act", t, ttab[t]>>>>)
              /\ busy' = [busy EXCEPT ![t] = TRUE]
              /\ route' = [route EXCEPT ![t] = "host"]
              /\ tgen' = [tgen EXCEPT ![t] = dgen]
              /\ decGen' = [decGen EXCEPT ![t] = IF @ = 0 THEN dgen ELSE @]
              /\ UNCHANGED <<status, chromeStep>>
         [] r = "host" /\ pc[t] > Len(Script) ->
              /\ status' = [status EXCEPT ![t] = "done_host"]
              /\ Send(<<<<"release", {t}>>>>)
              /\ UNCHANGED <<busy, route, tgen, decGen, chromeStep>>
         [] r = "chrome" ->
              /\ status' = [status EXCEPT ![t] = "done_chrome"]
              /\ route' = [route EXCEPT ![t] = "chrome"]
              /\ chromeStep' = [chromeStep EXCEPT ![t] = TRUE]
              /\ UNCHANGED <<busy, tgen, decGen, toHost>>
         [] r = "fail" ->
              /\ status' = [status EXCEPT ![t] = "failed"]
              /\ Send(<<<<"release", {t}>>>>)
              /\ UNCHANGED <<busy, route, tgen, decGen, chromeStep>>
    /\ UNCHANGED <<pc, ttab, attached, dgen, cache, launching, launchOk, toDaemon, conn, gen,
                   host, truth, lastRecv, badDecision, hostGen, hostRan, withoutHost, personHit,
                   personClosed, idleHit, abandoned, lockGap, popupCounted, quitMidAct,
                   closeRefused, cancelled>>

\* HostServer takes the next answer or event from the host.
\*  - attached: the connection is live, with no report yet (Connection.attach,
\*    connection.ex:242-252; HostAvailability.attached, host_availability.ex:
\*    206-217, clearing any earlier connection's report, quit and launch).
\*  - availability: kept (LastReportWins; HostAvailability.report, :163-169,
\*    ignored once stopping -- BROWSER-5), then the tasks waiting on a launch
\*    decide on it, and on unavailable every task bound to this host ends
\*    (EndHostTasks) with task.release -- this folds into one step what the
\*    real code discovers lazily, at each such task's own next check_host
\*    (host_server.ex:417-430); both orders (one more host step slips through,
\*    or none does) are still explored, since TaskStep and DaemonRecv race
\*    freely. After host_stopping the host is stopping for good and a report
\*    changes nothing (BROWSER-5).
\*  - ok: the task's step is done; a late answer for a task that ended is
\*    dropped (`request`, host_server.ex:449-462). error: the task fails
\*    with a sentence and its tabs are released (`host_error`, :466-475).
\*  - stopping: in one callback every task bound to this host ends and
\*    task.release goes for it -- the app side of the handshake and its own
\*    release loop are Connection.host_stopping (connection.ex:270-284,
\*    BROWSER-1/7); HostServer's own end of each task is `lose`/`stop`
\*    (host_server.ex:434-438,:107-129) on `{:browser_host_stopping, _}`
\*    (:146-150) -- launching is no longer allowed (the person quit the app),
\*    and the answer, host.stop_ack, is sent behind every release
\*    (connection.ex:283, protocol.ex "host.stop_ack").
\*  - cancel: the one task task_id names ends the way EndHostTasks ends a
\*    host failure -- NoChromeRetry decides it the same way -- and its
\*    task.release goes behind whatever it already had queued
\*    (Connection.cancel_task, connection.ex; HostServer's end of it is
\*    `lose_cancelled`/`stop`, host_server.ex:456-475,:107-129, on
\*    `{:browser_host_cancelled, _, _}`, :164-167,:489,:1046-1047). A task_id
\*    already ended by the time this is read (HostTasks(dgen) no longer names
\*    it) is left alone, matching the connection's own idempotent lookup.
DaemonRecv ==
    /\ toDaemon /= <<>>
    /\ LET m == Head(toDaemon) IN
       /\ toDaemon' = Tail(toDaemon)
       /\ CASE m[1] = "attached" ->
                 /\ attached' = TRUE /\ dgen' = gen /\ cache' = "none" /\ lastRecv' = "none"
                 /\ UNCHANGED <<status, route, tgen, decGen, pc, busy, ttab, launching,
                                launchOk, toHost, badDecision>>
            [] m[1] = "avail" /\ cache = "stopping" ->
                 /\ UNCHANGED <<status, route, tgen, decGen, pc, busy, ttab, attached, dgen,
                                cache, launching, launchOk, toHost, lastRecv, badDecision>>
            [] m[1] = "avail" ->
                 LET v == m[2]
                     c == IF LastReportWins \/ cache = "none" THEN v ELSE cache
                     W == {t \in Tasks : status[t] = "waiting"}
                     S == IF DecideOnceAtStart /\ v = "unavailable" THEN HostTasks(dgen) ELSE {}
                 IN /\ cache' = c /\ lastRecv' = v
                    /\ IF launching > 0
                       THEN /\ launching' = 0
                            /\ Settle(c)
                            /\ badDecision' = (badDecision \/ (W /= {} /\ c = "available"
                                                               /\ v /= "available"))
                            /\ UNCHANGED <<busy, toHost>>
                       ELSE /\ EndHostTasks(S)
                            /\ Send(ReleaseFor(S))
                            /\ UNCHANGED <<tgen, decGen, launching, badDecision>>
                    /\ UNCHANGED <<pc, ttab, attached, dgen, launchOk>>
            [] m[1] = "ok" ->
                 LET t == m[2] IN
                 /\ IF Running(t) /\ busy[t]
                    THEN /\ busy' = [busy EXCEPT ![t] = FALSE]
                         /\ pc' = [pc EXCEPT ![t] = @ + 1]
                         /\ ttab' = [ttab EXCEPT ![t] = IF @ = 0 THEN m[3] ELSE @]
                    ELSE UNCHANGED <<busy, pc, ttab>>
                 /\ UNCHANGED <<status, route, tgen, decGen, attached, dgen, cache, launching,
                                launchOk, toHost, lastRecv, badDecision>>
            [] m[1] = "err" ->
                 LET t == m[2] IN
                 /\ IF Running(t) /\ busy[t]
                    THEN /\ status' = [status EXCEPT ![t] = "failed"]
                         /\ busy' = [busy EXCEPT ![t] = FALSE]
                         /\ Send(<<<<"release", {t}>>>>)
                    ELSE UNCHANGED <<status, busy, toHost>>
                 /\ UNCHANGED <<route, tgen, decGen, pc, ttab, attached, dgen, cache,
                                launching, launchOk, lastRecv, badDecision>>
            [] m[1] = "stopping" ->
                 LET S == IF DecideOnceAtStart THEN HostTasks(dgen) ELSE {} IN
                 /\ cache' = "stopping" /\ launchOk' = FALSE
                 /\ EndHostTasks(S)
                 /\ Send(ReleaseFor(S) \o <<<<"stop_ack">>>>)
                 /\ UNCHANGED <<tgen, decGen, pc, ttab, attached, dgen, launching, lastRecv,
                                badDecision>>
            [] m[1] = "cancel" ->
                 LET t == m[2]
                     S == HostTasks(dgen) \cap {t}
                 IN /\ EndHostTasks(S)
                    /\ Send(ReleaseFor(S))
                    /\ UNCHANGED <<tgen, decGen, pc, ttab, attached, dgen, cache, launching,
                                   launchOk, lastRecv, badDecision>>
    /\ UNCHANGED <<conn, gen, host, truth, hostGen, hostRan, withoutHost, chromeStep, personHit,
                   personClosed, idleHit, abandoned, lockGap, popupCounted, quitMidAct,
                   closeRefused, cancelled>>

\* The connection's :DOWN, once everything the host wrote before it closed
\* was read (Connection owns the socket, so its exit closes the fd on every
\* path; HostServer watches it, `handle_message` on `{:DOWN, connection_ref,
\* ...}`, host_server.ex:140-144, `lose`, :434-438). DecideOnceAtStart: every
\* task bound to it fails (no release: there is no socket; the host released
\* on losing the daemon, or died). Without it, only a task with a request out
\* fails (its call returns an error); the rest re-decide at their next step.
DaemonDown ==
    /\ attached /\ ~conn /\ toDaemon = <<>>
    /\ attached' = FALSE /\ cache' = "none"
    /\ LET S == IF DecideOnceAtStart THEN HostTasks(dgen)
                ELSE {t \in Tasks : Running(t) /\ route[t] = "host" /\ busy[t]}
       IN /\ status' = [t \in Tasks |-> IF t \in S /\ (NoChromeRetry \/ ~DecideOnceAtStart)
                                        THEN "failed" ELSE status[t]]
          /\ route' = [t \in Tasks |-> IF t \in S /\ ~NoChromeRetry /\ DecideOnceAtStart
                                       THEN "chrome" ELSE route[t]]
          /\ busy' = [t \in Tasks |-> IF t \in S THEN FALSE ELSE busy[t]]
    /\ UNCHANGED <<tgen, decGen, pc, ttab, dgen, launching, launchOk, wire, host, truth, obs>>

\* The person cancels a task that has not ended. One not yet on the host --
\* waiting on a launch decision, or already routed to Chrome -- has no tab in
\* the app to cancel from: the turn (its caller) ends there, the same :DOWN a
\* crash would send (`handle_message` on `{:DOWN, caller_ref, ...}`,
\* host_server.ex:137-138, `stop`, :107-129); a waiting task simply stops
\* waiting. A task on the host has its own tab in the app's pane, with its
\* own "Cancel task": the person's click is the app's task.cancel
\* { task_id, reason } event over the wire (`Connection.cancel_task`;
\* `Link.cancelled/3`), read later by DaemonRecv like any other event, so it
\* can race an in-flight request exactly as the real wire does -- ending the
\* task and releasing its tabs is DaemonRecv's `"cancel"` case, not this step.
PersonCancel(t) ==
    /\ left["cancel"] > 0 /\ status[t] \in {"waiting", "running"}
    /\ left' = [left EXCEPT !["cancel"] = 0]
    /\ cancelled' = cancelled \cup {t}
    /\ IF route[t] = "host" /\ status[t] = "running"
       THEN /\ Tell(<<<<"cancel", t>>>>)
            /\ UNCHANGED <<status, busy>>
       ELSE /\ status' = [status EXCEPT ![t] = "failed"]
            /\ busy' = [busy EXCEPT ![t] = FALSE]
            /\ UNCHANGED toDaemon
    /\ UNCHANGED <<route, tgen, decGen, pc, ttab, attached, dgen, cache, launching, launchOk,
                   toHost, conn, gen, host, own, popup, closes, lastRecv, badDecision,
                   hostGen, hostRan, withoutHost, chromeStep, personHit, personClosed, idleHit,
                   abandoned, lockGap, popupCounted, quitMidAct, closeRefused>>

-----------------------------------------------------------------------------
(* The Mac app: BrowserHostReducer (an unpinned mirror, see the header)    *)

\* The app connects: the hello handshake, then `attached` and its first
\* availability report, in one reducer step (two real frames, PROTOCOL.md's
\* "Handshake and attach"; the daemon's side of each is Connection.attach,
\* connection.ex:242-252, and .availability, :256-266 -- folded into one step
\* here because nothing can act differently in the gap: HostAvailability
\* treats "attached, no report yet" the same whichever of the two just
\* landed). A new connection waits for HostServer to have taken the last
\* one's :DOWN: Endpoint refuses a second client outright while one is
\* attached (accept_connection, endpoint.ex:209-219, `host_already_attached`)
\* rather than queuing it, so this is the code, not a simplification (see the
\* header).
Attach ==
    /\ app = "starting" /\ ~conn /\ ~attached /\ toDaemon = <<>>
    /\ app' = "up" /\ conn' = TRUE /\ gen' = gen + 1
    /\ Tell(<<<<"attached">>, <<"avail", AvailOf(locked)>>>>)
    /\ UNCHANGED <<daemon, toHost, locked, tab, reg, views, quit, truth, obs>>

\* A tab.open that passes the caps opens a tab owned by the task
\* (no registry: into the pool).
HostOpen(t) ==
    LET i == NewTab
        r == IF OwnershipRegistry THEN t ELSE "pool"
    IN IF app = "stopping" \/ locked \/ AtCap(r)
       THEN /\ Tell(<<<<"err", t>>>>)
            /\ UNCHANGED hostRan
            /\ popupCounted' = (popupCounted \/ (AtCap(r) /\ \E j \in TabIds :
                                  Live(j) /\ own[j] = t /\ popup[j]))
            /\ UNCHANGED <<tab, reg, views, own, popup>>
       ELSE /\ tab' = [tab EXCEPT ![i] = "live"]
            /\ reg' = [reg EXCEPT ![i] = r]
            /\ own' = [own EXCEPT ![i] = t]
            /\ views' = "warm"
            /\ Tell(<<<<"ok", t, i>>>>)
            /\ hostRan' = [hostRan EXCEPT ![t] = TRUE]
            /\ UNCHANGED <<popup, popupCounted>>

\* A page.act on the task's tab. Refused while unavailable or stopping, or
\* on a tab that is gone.
HostAct(t, i) ==
    LET refused == app = "stopping" \/ locked \/ i = 0 \/ ~Live(i) IN
    /\ Tell(<<IF refused THEN <<"err", t>> ELSE <<"ok", t, 0>>>>)
    /\ hostRan' = [hostRan EXCEPT ![t] = @ \/ ~refused]
    /\ UNCHANGED <<tab, reg, views, own, popup, popupCounted>>

\* The host takes the next request. What is on `toHost` is what the daemon's
\* Connection wrote for it, in the order its one process took requests and
\* releases off its own mailbox (task_request, bind_task, release_task,
\* write_request, connection.ex:328-394 -- BROWSER-1's fix: a release can
\* never overtake a request the same task sent before it). tab.open and
\* page.act are host steps of their task (recorded for NoTaskWithoutHost).
\* task.release releases the named tasks' tabs (idempotent: BROWSER-2). The
\* answer to host_stopping (host.stop_ack, written behind every release,
\* connection.ex:283) ends the held quit: the app detaches and exits, its
\* remaining tabs with it. The app's own ok/error reply to host.stop_ack is
\* not modelled: nothing reads it.
HostRecv ==
    /\ conn /\ toHost /= <<>>
    /\ LET m == Head(toHost) IN
       /\ toHost' = Tail(toHost)
       /\ CASE m[1] \in {"open", "act"} ->
                 LET t == m[2] IN
                 /\ hostGen' = [hostGen EXCEPT ![t] = IF @ = 0 THEN gen ELSE @]
                 /\ withoutHost' = (withoutHost \/ (hostGen[t] /= 0 /\ hostGen[t] /= gen))
                 /\ IF m[1] = "open" THEN HostOpen(t) ELSE HostAct(t, m[3])
                 /\ UNCHANGED <<conn, app, quit, closes, personHit, idleHit, abandoned>>
            [] m[1] = "release" ->
                 /\ ReleaseTabs(UNION {TaskRelease(t) : t \in m[2]})
                 /\ UNCHANGED <<toDaemon, conn, app, views, quit, own, popup, hostGen,
                                hostRan, withoutHost, popupCounted, abandoned>>
            [] m[1] = "stop_ack" ->
                 /\ app' = "off" /\ conn' = FALSE /\ quit' = "done"
                 /\ tab' = [i \in TabIds |-> IF Live(i) THEN "died" ELSE tab[i]]
                 /\ reg' = [i \in TabIds |-> "nobody"] /\ views' = "cold"
                 /\ abandoned' = (abandoned \/ HostTasks(gen) /= {})
                 /\ UNCHANGED <<toDaemon, own, popup, closes, hostGen, hostRan, withoutHost,
                                personHit, idleHit, popupCounted>>
    /\ UNCHANGED <<daemon, gen, locked, left, lastRecv, badDecision, chromeStep, personClosed,
                   lockGap, quitMidAct, closeRefused, cancelled>>

\* The session locks, or unlocks: the host reports it at once while it is
\* up. A lock finds tasks routed to the host that have not yet run a host
\* step (Witness_LockBeforeFirstStep).
Lock ==
    /\ left["lock"] > 0 /\ ~locked
    /\ left' = [left EXCEPT !["lock"] = 0]
    /\ locked' = TRUE
    /\ IF app = "up" /\ conn THEN Tell(<<<<"avail", "unavailable">>>>) ELSE UNCHANGED toDaemon
    /\ lockGap' = lockGap \cup {t \in Tasks : Running(t) /\ route[t] = "host" /\ hostGen[t] = 0}
    /\ UNCHANGED <<daemon, toHost, conn, gen, app, tab, reg, views, quit, own, popup, closes,
                   lastRecv, badDecision, hostGen, hostRan, withoutHost, chromeStep, personHit,
                   personClosed, idleHit, abandoned, popupCounted, quitMidAct, closeRefused,
                   cancelled>>

Unlock ==
    /\ left["unlock"] > 0 /\ locked
    /\ left' = [left EXCEPT !["unlock"] = 0]
    /\ locked' = FALSE
    /\ IF app = "up" /\ conn THEN Tell(<<<<"avail", "available">>>>) ELSE UNCHANGED toDaemon
    /\ UNCHANGED <<daemon, toHost, conn, gen, app, tab, reg, views, quit, own, popup, closes,
                   obs>>

\* The connection drops while the app runs on. What was on its way to the
\* host is lost. The host has lost the daemon: it releases every task's
\* tabs, and reconnects later (Attach), unless it is holding a quit.
Detach ==
    /\ left["detach"] > 0 /\ conn
    /\ left' = [left EXCEPT !["detach"] = 0]
    /\ conn' = FALSE /\ toHost' = <<>>
    /\ app' = IF app = "up" THEN "starting" ELSE app
    /\ ReleaseTabs(AllTaskRecords)
    /\ UNCHANGED <<daemon, toDaemon, gen, locked, views, quit, own, popup, lastRecv,
                   badDecision, hostGen, hostRan, withoutHost, chromeStep, personClosed, abandoned,
                   lockGap, popupCounted, quitMidAct, closeRefused, cancelled>>

\* The app crashes: every tab dies with it, the registry too.
Crash ==
    /\ left["crash"] > 0 /\ app /= "off"
    /\ left' = [left EXCEPT !["crash"] = 0]
    /\ app' = "off" /\ conn' = FALSE /\ toHost' = <<>>
    /\ tab' = [i \in TabIds |-> IF Live(i) THEN "died" ELSE tab[i]]
    /\ reg' = [i \in TabIds |-> "nobody"] /\ views' = "cold"
    /\ quit' = IF quit = "stopping" THEN "done" ELSE quit
    /\ UNCHANGED <<daemon, toDaemon, gen, locked, own, popup, closes, obs>>

\* The person quits the app.
\*  - StoppingHandshake, attached: the host releases every task's tabs,
\*    sends host_stopping and holds its quit for the answer (or QuitBound).
\*  - Otherwise (not connected, or FALSE) it exits at once: it releases
\*    every task's tabs and closes the socket, whatever task still runs.
PersonQuit ==
    /\ left["quit"] > 0 /\ app \in {"starting", "up"}
    /\ left' = [left EXCEPT !["quit"] = 0]
    /\ IF conn /\ StoppingHandshake
       THEN /\ app' = "stopping" /\ quit' = "stopping"
            /\ quitMidAct' = \E t \in Tasks : busy[t] /\ route[t] = "host" /\ Running(t)
                                             /\ Script[pc[t]] = "act"
            /\ ReleaseTabsAs(AllTaskRecords, FALSE)
            /\ Tell(<<<<"stopping">>>>)
            /\ UNCHANGED <<conn, toHost, abandoned, views>>
       ELSE /\ app' = "off" /\ quit' = "done" /\ conn' = FALSE /\ toHost' = <<>>
            /\ ReleaseAndExit
            /\ abandoned' = (abandoned \/ (conn /\ HostTasks(gen) /= {}))
            /\ UNCHANGED <<toDaemon, quitMidAct>>
    /\ UNCHANGED <<daemon, gen, locked, own, popup, lastRecv, badDecision, hostGen,
                   hostRan, withoutHost, chromeStep, personClosed, lockGap, popupCounted,
                   closeRefused, cancelled>>

\* QuitBound: the held quit ends when the bound elapses (the app's own
\* timer), answered or not: the app detaches and exits.
QuitBoundElapses ==
    /\ QuitBound /\ app = "stopping"
    /\ app' = "off" /\ quit' = "done" /\ conn' = FALSE /\ toHost' = <<>>
    /\ tab' = [i \in TabIds |-> IF Live(i) THEN "died" ELSE tab[i]]
    /\ reg' = [i \in TabIds |-> "nobody"] /\ views' = "cold"
    /\ UNCHANGED <<daemon, toDaemon, gen, locked, truth, obs>>

\* The person opens a tab of their own in the running app.
PersonOpenTab ==
    /\ left["popen"] > 0 /\ app \in {"starting", "up"}
    /\ left' = [left EXCEPT !["popen"] = 0]
    /\ LET i == NewTab IN
       /\ tab' = [tab EXCEPT ![i] = "live"]
       /\ reg' = [reg EXCEPT ![i] = "person"]
       /\ own' = [own EXCEPT ![i] = "person"]
    /\ views' = "warm"
    /\ UNCHANGED <<daemon, wire, app, locked, quit, popup, closes, obs>>

\* The person tries to close tab i. PersonCannotCloseTaskTab: refused for a
\* tab the registry gives to a task (the person may cancel the task
\* instead). Otherwise the tab closes, and its record goes (ReleaseOnce).
PersonCloseTab(i) ==
    /\ left["pclose"] > 0 /\ app \in {"starting", "up", "stopping"} /\ Live(i)
    /\ left' = [left EXCEPT !["pclose"] = 0]
    /\ IF PersonCannotCloseTaskTab /\ TaskRecord(reg[i])
       THEN /\ closeRefused' = closeRefused \cup (IF HeldByRunningTask(i) THEN {own[i]} ELSE {})
            /\ UNCHANGED <<tab, reg, closes, personClosed>>
       ELSE /\ tab' = [tab EXCEPT ![i] = "closed"]
            /\ closes' = [closes EXCEPT ![i] = @ + 1]
            /\ reg' = [reg EXCEPT ![i] = IF ReleaseOnce THEN "nobody" ELSE @]
            /\ personClosed' = (personClosed \/ HeldByRunningTask(i))
            /\ UNCHANGED closeRefused
    /\ UNCHANGED <<daemon, wire, app, locked, views, quit, own, popup, lastRecv, badDecision,
                   hostGen, hostRan, withoutHost, chromeStep, personHit, idleHit, abandoned,
                   lockGap, popupCounted, quitMidAct, cancelled>>

\* A page in live tab i opens a popup. The registry gives it i's owner
\* (no registry: the pool), and the caps count it: at the cap it is blocked
\* (window.open returns null). App-side and still unpinned (BROWSER-3); the
\* engine's own part of this finding is the wire the app can now report it
\* over, tab.list's opener_tab_id (protocol.ex#listed_tab?), which this step
\* has no need to read since it already knows own[i] as ground truth.
Popup(i) ==
    /\ left["popup"] > 0 /\ app /= "off" /\ Live(i)
    /\ left' = [left EXCEPT !["popup"] = 0]
    /\ LET r == IF OwnershipRegistry THEN reg[i] ELSE "pool"
           j == NewTab
       IN IF TaskRecord(r) /\ AtCap(r)
          THEN UNCHANGED <<tab, reg, own, popup, views>>
          ELSE /\ tab' = [tab EXCEPT ![j] = "live"]
               /\ reg' = [reg EXCEPT ![j] = r]
               /\ own' = [own EXCEPT ![j] = own[i]]
               /\ popup' = [popup EXCEPT ![j] = TRUE]
               /\ views' = "warm"
    /\ UNCHANGED <<daemon, wire, app, locked, quit, closes, obs>>

\* Idle: with no task tabs and no person tabs the host may release its web
\* views. With the registry that reads the records. Without it (no registry)
\* the host knows only the person's tabs and the requests it is serving, so
\* it is "idle" with no person tab and no request waiting, and the pool
\* goes.
Idle ==
    IF OwnershipRegistry
    THEN \A i \in TabIds : Live(i) => ~(TaskRecord(reg[i]) \/ reg[i] = "person")
    ELSE toHost = <<>> /\ \A i \in TabIds : Live(i) => reg[i] /= "person"

IdleRelease ==
    /\ app \in {"starting", "up"} /\ views = "warm" /\ Idle
    /\ views' = "cold"
    /\ LET S == {i \in TabIds : Live(i) /\ reg[i] /= "person"} IN
       /\ tab' = [i \in TabIds |-> IF i \in S THEN "closed" ELSE tab[i]]
       /\ closes' = [i \in TabIds |-> IF i \in S THEN closes[i] + 1 ELSE closes[i]]
       /\ reg' = [i \in TabIds |-> IF i \in S /\ ReleaseOnce THEN "nobody" ELSE reg[i]]
       /\ idleHit' = (idleHit \/ \E i \in S : HeldByRunningTask(i))
       /\ personHit' = (personHit \/ \E i \in S : own[i] = "person")
    /\ UNCHANGED <<daemon, wire, app, locked, quit, own, popup, left, lastRecv, badDecision,
                   hostGen, hostRan, withoutHost, chromeStep, personClosed, abandoned, lockGap,
                   popupCounted, quitMidAct, closeRefused, cancelled>>

\* Time passes while something waits on a timer: a task on its launch, or
\* the app holding its quit. It changes nothing; it is here so that a wait
\* with no timer to end it is a behaviour the liveness rules can see, not a
\* deadlock.
Wait ==
    /\ (\E t \in Tasks : status[t] = "waiting") \/ app = "stopping"
    /\ UNCHANGED vars

-----------------------------------------------------------------------------
Init ==
    /\ status = [t \in Tasks |-> "idle"]
    /\ route = [t \in Tasks |-> "none"]
    /\ tgen = [t \in Tasks |-> 0] /\ decGen = [t \in Tasks |-> 0]
    /\ pc = [t \in Tasks |-> 1] /\ busy = [t \in Tasks |-> FALSE]
    /\ ttab = [t \in Tasks |-> 0]
    /\ attached = FALSE /\ dgen = 0 /\ cache = "none"
    /\ launching = 0 /\ launchOk = TRUE
    /\ toHost = <<>> /\ toDaemon = <<>> /\ conn = FALSE /\ gen = 0
    \* the app is not running, or the person has it open and it is about to connect
    /\ app \in {"off", "starting"}
    /\ locked = FALSE
    /\ tab = [i \in TabIds |-> "none"] /\ reg = [i \in TabIds |-> "nobody"]
    /\ views = "cold" /\ quit = "no"
    /\ own = [i \in TabIds |-> "nobody"] /\ popup = [i \in TabIds |-> FALSE]
    /\ closes = [i \in TabIds |-> 0]
    /\ left = [k \in Kinds |-> IF Allowed(k) THEN 1 ELSE 0]
    /\ lastRecv = "none" /\ badDecision = FALSE
    /\ hostGen = [t \in Tasks |-> 0] /\ hostRan = [t \in Tasks |-> FALSE]
    /\ withoutHost = FALSE
    /\ chromeStep = [t \in Tasks |-> FALSE]
    /\ personHit = FALSE /\ personClosed = FALSE /\ idleHit = FALSE /\ abandoned = FALSE
    /\ lockGap = {} /\ popupCounted = FALSE /\ quitMidAct = FALSE
    /\ closeRefused = {} /\ cancelled = {}

\* The legitimate end: every task ended, nothing on the wire, no launch
\* pending, HostServer has taken any :DOWN, and the app is either off or up
\* and attached. Deadlock checking is on, so any other state where nothing
\* can happen is reported as a wedge.
Done ==
    /\ \A t \in Tasks : status[t] \in Terminal
    /\ toHost = <<>> /\ toDaemon = <<>>
    /\ launching = 0
    /\ attached = conn
    /\ app \in {"off", "up"}

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E t \in Tasks : Decide(t) \/ TaskStep(t) \/ PersonCancel(t)
    \/ Deadline \/ DaemonRecv \/ DaemonDown
    \/ Attach \/ HostRecv \/ Lock \/ Unlock \/ Detach \/ Crash \/ PersonQuit
    \/ QuitBoundElapses \/ PersonOpenTab \/ IdleRelease
    \/ \E i \in TabIds : PersonCloseTab(i) \/ Popup(i)
    \/ Wait
    \/ Terminated

\* Fairness only on what Fermix drives: a task's calls (the agent's turn),
\* HostServer, its deadline, the host's reducer, the app's reconnect (not
\* when a launched app may hang: LaunchCanTimeOut), and the quit's bound.
\* None on the person, pages, locks, crashes, drops or the idle release.
Fairness ==
    /\ \A t \in Tasks : WF_vars(Decide(t)) /\ WF_vars(TaskStep(t))
    /\ WF_vars(Deadline) /\ WF_vars(DaemonRecv) /\ WF_vars(DaemonDown)
    /\ WF_vars(HostRecv) /\ WF_vars(QuitBoundElapses)
    /\ (~LaunchCanTimeOut => WF_vars(Attach))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* Proposed rule (the design): at a task's start, an attached host whose
\* last report is available runs it. Read as: no task is ever routed to the
\* host while the last availability report HostServer took says otherwise.
DecisionUsesCurrentAvailability == ~badDecision

\* Proposed rule: the daemon launches the app hidden at most once per
\* decision. Read as: never two launches pending at once.
AtMostOneLaunchPending == launching <= 1

\* Proposed rule: every task that starts ends: completed on the host,
\* completed on Chrome, or failed with a sentence.
EveryTaskTerminates ==
    \A t \in Tasks : (status[t] /= "idle") ~> (status[t] \in Terminal)

\* Proposed rule: task.release releases every tab of the task exactly once.
\* Read as: the host never releases or closes a tab twice, and at rest every
\* task tab is closed (or died with the app).
TabsReleasedExactlyOnce ==
    /\ \A i \in TabIds : closes[i] <= 1
    /\ Done => \A i \in TabIds : own[i] \in Tasks => tab[i] \in {"closed", "died"}

\* Proposed rule: tabs the person opens (and their popups) are never
\* touched by any task or release.
PersonTabsNeverReleasedByTasks == ~personHit

\* Proposed rule: a tab a task owns cannot be closed by the person while
\* the task runs.
NoTaskTabClosedByPerson == ~personClosed

\* Proposed rule: live tabs never exceed the per-task cap and the global cap.
CapsHold ==
    /\ \A t \in Tasks : Cardinality({i \in TabIds : Live(i) /\ own[i] = t}) <= TaskCap
    /\ Cardinality({i \in TabIds : Live(i) /\ own[i] \in Tasks}) <= GlobalCap

\* Proposed rule: no host step for a task after its host detached. Read as:
\* the host handles every request of a task on the connection it handled
\* the task's first one on.
NoTaskWithoutHost == ~withoutHost

\* Proposed rule: after quit is requested every host task ends before the
\* host detaches, or the bound elapses and they end then. Read as: the app
\* never detaches by its quit while a host task runs (before the bound), and
\* the quit always completes with every host task ended.
QuitSettled ==
    /\ quit = "done" /\ ~abandoned
    /\ \A t \in Tasks : route[t] = "host" => status[t] \in Terminal
QuitNeverAbandons == (quit /= "no") ~> QuitSettled

\* Proposed rule: the idle release never releases a tab a task owns.
IdleReleaseSparesTaskTabs == ~idleHit

\* The owner's rule, "identify early, never retry with Chrome". Read as: a
\* task that ran a step on the host never runs a step on Chrome. Proved here
\* by NoChromeRetry alone (check 05); the code adds TurnMarker on top, which
\* this property cannot see because it is stated per Task, not per turn --
\* see the header's "Not modelled" for why no needs check exists for it.
NoChromeAfterHostFailure == \A t \in Tasks : ~(hostRan[t] /\ chromeStep[t])

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* The lock lands between a task's decision for the host and its first
\* host step, and the task fails rather than moving to Chrome.
Witness_LockBeforeFirstStep ==
    ~\E t \in lockGap : status[t] = "failed" /\ ~chromeStep[t]

\* A popup from a task tab counts against the cap: the task's own next
\* tab.open is refused while it holds the popup.
Witness_PopupCountsAgainstCap == ~popupCounted

\* The person quits an attached app while a task's page.act is out; the
\* quit completes through the handshake and the task failed with a sentence.
Witness_QuitMidAct ==
    ~(quitMidAct /\ quit = "done" /\ \E t \in Tasks : status[t] = "failed")

\* The person tries to close a tab a task owns, is refused, cancels the
\* task instead, and its tabs are released.
Witness_CancelInsteadOfClose ==
    ~\E t \in closeRefused \cap cancelled :
        \A i \in TabIds : own[i] = t => tab[i] \in {"closed", "died"}

=============================================================================
