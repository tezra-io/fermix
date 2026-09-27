# browser_host: tasks on the person's own browser, through the Mac app

Models the browser host protocol: the daemon listens on one 0600 Unix socket,
`browser_host.sock` (newline JSON, a hello handshake), and the Mac app
connects to it as the host. Its web views run a task's browser work on the
person's own machine. The direction is reversed from the chat wire:
- the daemon sends requests with an id (`tab.open`, `page.act`,
  `task.release`, ...), and the host answers each with ok or error;
- the host sends unsolicited events (`attached`, `availability`,
  `tab.closed`, `dialog.opened`, `download.*`, `host_stopping`).

The spec was first written as a design spec, ahead of the code (3ee506f3). It
was then re-read against `feat/browser-host-wire` (PR #94, on
`feat/browser-backend-boundary`, PR #93) and pinned by function, as
`companion_session` was. BROWSER-1 to BROWSER-8 are what the design spec asked
of the implementation; all are fixed or hold by construction, per the findings
section below, each with the commit that proves it. The re-read also turned up
`TurnMarker`, a mechanism the design spec did not ask for (see "Not
modelled").

The modules it describes turned out to be several real modules, not the one
process the design spec guessed at:
- `FermixCore.Browser.HostServer`: the pane task, running inside its own
  `ProfileServer` (one live task per profile, not one process for the whole
  daemon). It binds a host task to the connection it was decided on, and
  refuses it on any other; it fails the task with a sentence when that
  connection goes down or the app says it is quitting; it names tabs by the
  connection (`h<connection_id>:<wire_id>`), so a tab id can never reach
  another connection's tab.
- `FermixCore.Browser.HostAvailability`: the one process that holds the host's
  last report, with no probe, and which connection it is on. `host_stopping`
  is final for that connection: a later report on it is ignored, and it is
  cleared only by a fresh attach.
- `FermixCore.Browser.HostLauncher`: the pure decision table that opens the
  app on demand and waits for its attach and first report under one deadline,
  shared by every task that finds a launch pending, and bounded by a cooldown
  after a launch that never attached.
- `FermixCore.Browser.Routing`: decides a task's backend once, when no profile
  is live for it, and pins every later request of it to the backend the live
  profile was started on.
- `FermixCore.Browser.execute`/`dispatch` (`browser.ex`): where a call first
  meets a lost turn's `TurnMarker` mark and, past that, `Routing`.
- `FermixChannels.BrowserHost.{Endpoint,Connection,Supervisor}`: the listener
  (one host at a time) and its connection process, the handshake and the line
  codec. A connection forwards every task's request and release in the order
  its own process took them off its mailbox, and its exit is `HostServer`'s
  `:DOWN`, so the spec folds it into the daemon's steps.
- The Mac app's `BrowserHostReducer`, in `tezra-io/fermix-macos`: one
  main-actor reducer that owns the tabs, the ownership registry, the caps, the
  availability reports and the quit hold. It lives in another repository, so
  it is still an **unpinned mirror**: this spec states what it must do, and
  the app's tests hold it to that.

The `.tla` header carries the full `SOURCE` list, by function for the large
shared files (`host_server.ex`, `browser.ex`, `connection.ex`,
`protocol.ex#listed_tab?`) and whole for the small, single-purpose ones
(`host_availability.ex`, `host_launcher.ex`, `routing.ex`, `turn_marker.ex`,
`link.ex`, `endpoint.ex`, `supervisor.ex`), plus `PROTOCOL.md` whole, as
`companion_session` pins its own protocol doc.

**The processes.**
- Two tasks, each with a short script: `tab.open`, then `page.act` on that
  tab (and a second `tab.open` where a check needs one). A task waits for
  each answer before its next request.
- HostServer, with its launch deadline.
- The socket: one FIFO each way. What the daemon writes after the socket
  closed is lost. What the host wrote before it closed is still read, then
  the `:DOWN`.
- The app: its connection, the session lock, its tabs and registry, its web
  view pool, and its quit.
- Managed Chrome, one abstract "elsewhere" that runs a task's remaining
  steps and always completes. Its own rules are not this spec's (its tab cap
  evicts the oldest tab; the host refuses instead).

**The design the spec encodes.**
- **Availability.** The host sends `availability { available, reason }` right
  after attaching and on every change. HostServer keeps the last report and
  reads it at the decision, with no probe.
- **The decision, once.** At a task's start, an attached host whose last
  report is available runs the task, bound to that connection. Otherwise,
  with no host attached and launching allowed, HostServer launches the app
  hidden once. The task waits for the attach and the first report under one
  deadline, and a task that finds a launch pending waits on it. When the
  deadline passes the task runs on Chrome. Anything else runs on Chrome.
- **No retry on Chrome.** A host task whose host goes unavailable, detaches,
  crashes or stops fails with a sentence. It is never re-run on Chrome.
- **Ownership.** The host records an owner for every tab:
  - a tab from `tab.open` is its task's;
  - a popup is its opener's owner's, so a popup from the person's tab is the
    person's;
  - a tab the person opens is the person's.

  A `task.release` closes that task's tabs only. The person cannot close a
  tab a task owns, but may cancel the task. The host releases every task's
  tabs on `host_stopping` and on losing the daemon, and drops a tab's record
  when it releases or closes it.
- **Caps.** A `tab.open`, or a popup, that would pass the task's cap or the
  global cap is refused, not queued. A popup refused at the cap is blocked
  (`window.open` returns null). The caps count task tabs only.
- **Quit.** An attached app asked to quit releases every task's tabs, sends
  `host_stopping` and holds its quit. The daemon answers in one callback
  (`Connection.host_stopping`, folding in each task's own end,
  `HostServer.lose`/`stop`):
  - it fails every task bound to that host with a sentence and sends
    `task.release` for them;
  - it stops launching the app;
  - it answers `host.stop_ack` (the design spec's `stop_ok`, renamed to the
    real wire name at the re-read).

  The app exits on the answer, or when the quit's bound elapses. Stopping is
  final for its connection: the host sends no availability after
  `host_stopping`, and `HostAvailability` ignores any, cleared only by a fresh
  attach.
- **Idle.** With no task tab and no person tab the host may release its web
  views. The check reads the registry, in the step that releases.

**Environment switches** (set per check; each enabled kind happens at most
once per behaviour):
- `HostCanDetach`: the connection drops while the app runs on, and the app
  reconnects on its own.
- `HostCanCrash`: the app dies, every tab with it.
- `SessionCanLock`: the screen locks, and may unlock again. Display sleep and
  app termination make the host unavailable the same way.
- `PersonCanQuit`: the person quits the app.
- `PersonOpensTabs`: the person opens a tab of their own.
- `PersonCanCloseTabs`: the person tries to close a tab, any tab.
- `PersonCanCancel`: the person cancels a task, whatever state it is in.
- `LaunchCanTimeOut`: a launched app may never attach. It hangs, or macOS
  refuses it. The app's attach then has no fairness.
- `PagesOpenPopups`: a page opens a popup from any live tab.

**Mechanism switches** (`TRUE` is the design; each is switched off only by the
checks that show a rule needs it):
- `DecideOnceAtStart`: the backend is decided once, when no profile is live
  for the task (`Routing.for_request`), and a host task is bound to its
  connection and refused on any other (`HostServer.check_host`). `FALSE`
  re-decides before every step.
- `LastReportWins`: `HostAvailability` keeps the last report, with no probe.
  `FALSE` keeps the first report after the attach.
- `SingleLaunch`: a task that finds a launch pending waits on it
  (`HostLauncher.pending?`). `FALSE` launches again.
- `LaunchDeadline`: the tasks waiting on a launch run on Chrome when its one
  deadline passes (`waited_deadline`). `FALSE` waits for the attach and first
  report.
- `OwnershipRegistry`: the owner record above. Still the app reducer's own
  state, an unpinned mirror; the engine's own part of BROWSER-3 is the wire
  field a popup's owner can ride on, `tab.list`'s `opener_tab_id`
  (`protocol.ex#listed_tab?`). `FALSE` is a host with no registry. It records
  only the person's own tabs. Every other tab, a popup included, joins one
  pool, and any task's release closes the pool. It counts itself idle with no
  person tab and no request waiting.
- `ReleaseOnce`: the host drops a tab's record when it releases or closes it.
  App-side, unpinned; the engine's own release (`task.release`) is already
  idempotent by construction (`Connection.release_task` pops the task on its
  first release; `HostServer.stop` is a no-op once the task is `nil`).
- `PersonCannotCloseTaskTab`: the host refuses the person's close of a tab
  the registry gives to a task. App-side, unpinned.
- `TabCaps`: the caps above. App-side, unpinned; the engine only carries the
  two numbers on `tab.open` (`task_tab_cap`, `tab_cap`).
- `StoppingHandshake`: the quit above. App-side, unpinned; the engine's half
  is answering `host.stop_ack` behind every release it issued
  (`Connection.host_stopping`). `FALSE` exits at once.
- `QuitBound`: the held quit ends when its bound elapses, answered or not.
  App-side, unpinned.
- `NoChromeRetry`: a host task its host fails is failed with a sentence
  (`HostServer.lose`), never re-routed to Chrome. `TurnMarker` extends this
  across the rest of the turn (see "Not modelled"); this spec's Tasks are
  already turn-sized, so it cannot state a rule that needs `TurnMarker`.
  `FALSE` re-runs the task on Chrome.

**Bounds** (set per check): `Tasks` (always two), `OpensPerTask` (1, or 2 for
the popup witness), `TaskCap` and `GlobalCap` (1 and 1 in the tab checks, so
each cap bites), `MaxTabs` (tab ids, never reused; a bound, not a cap). Each
check turns on only the environment its rules need. Invariant checks reduce
by the tasks' symmetry.

One `Wait` step is part of the model: time passing while a task waits on its
launch or the app holds its quit. It changes nothing. Without it, a wait that
no timer ends would be reported as a deadlock rather than as the liveness
violation it is.

## What holds

**Check 01** holds with a lock and an unlock, a drop, a crash and a launch
that may hang:
- A task is never routed to the host while the last report HostServer took
  says unavailable (`DecisionUsesCurrentAvailability`). This rests on
  `LastReportWins` (check 02).
- Never two launches are pending (`AtMostOneLaunchPending`). This rests on
  `SingleLaunch` (check 03).
- The host handles every request of a task on the connection it handled the
  task's first one on (`NoTaskWithoutHost`). This rests on
  `DecideOnceAtStart` (check 04).
- A task that ran a step on the host never runs a step on Chrome
  (`NoChromeAfterHostFailure`). This rests on `NoChromeRetry` (check 05).

Witness 06 shows the lock landing between a task's decision for the host and
its first host step: the task fails and is not moved.

**Check 07** holds with popups, a tab and a close attempt by the person, a
cancel, a quit and a drop:
- No tab is ever released twice, and at rest every task tab is closed
  (`TabsReleasedExactlyOnce`). This rests on `ReleaseOnce` (check 08).
- No release the app runs on after closes a person's tab
  (`PersonTabsNeverReleasedByTasks`). This rests on `OwnershipRegistry`
  (check 09).
- The person never closes a running task's tab (`NoTaskTabClosedByPerson`).
  This rests on `PersonCannotCloseTaskTab` (check 11).
- Live tabs stay within both caps (`CapsHold`). This rests on `TabCaps`
  (check 12).
- The idle release never closes a running task's tab
  (`IdleReleaseSparesTaskTabs`). This rests on `OwnershipRegistry`
  (check 10).

Witness 13 shows a popup taking a slot under its task's cap, so the task's
own next `tab.open` is refused. Witness 14 shows the person refused the close
of a task's tab, cancelling the task instead, and its tab released.

**Check 15** (liveness) holds with a launch that may hang, a lock and an
unlock, a drop and a crash: every task that starts ends on the host, on
Chrome, or failed with a sentence (`EveryTaskTerminates`). This rests on
`LaunchDeadline` (check 16).

**Check 17** (liveness) holds with a drop that can land at any moment,
including while the app holds its quit. After a quit is asked, the quit
completes, and every host task has ended (`QuitNeverAbandons`). The app never
detaches by its quit while a host task still runs, unless the bound elapsed.
This rests on `StoppingHandshake` (check 18) and on `QuitBound` (check 19).
Witness 20 shows a quit while a task's `page.act` is out: HostServer fails
the task, and the quit completes.

Fairness is only on steps Fermix drives: a task's calls, HostServer and its
deadline, the host's reducer, the quit's bound, and the app's reconnect
(unless `LaunchCanTimeOut`). There is none on the person, pages, locks,
crashes, drops or the idle release.

Each `needs` check breaks its rule by this path (states in TLC's
counterexample):

| Check | Switched off | Counterexample |
|---|---|---|
| 02 | `LastReportWins` | 7 states: the host attaches available and then reports the lock; a task is routed to it on the first report |
| 03 | `SingleLaunch` | 3 states: two tasks start with no host attached, and each launches the app |
| 04 | `DecideOnceAtStart` | 15 states: BROWSER-4's path |
| 05 | `NoChromeRetry` | 11 states: a task opens its tab on the host, the lock is reported, and the task is re-run on Chrome |
| 08 | `ReleaseOnce` | 9 states: BROWSER-2's path |
| 09 | `OwnershipRegistry` | 5 states: BROWSER-3's first path |
| 10 | `OwnershipRegistry` | 8 states: BROWSER-3's second path |
| 11 | `PersonCannotCloseTaskTab` | 8 states: the person closes the tab a running task just opened |
| 12 | `TabCaps` | 8 states: a page in a task's one tab opens a popup, past the task's cap of one |
| 16 | `LaunchDeadline` | a lasso: BROWSER-8's path |
| 18 | `StoppingHandshake` | a lasso: the person quits while a task runs on the host; the app exits at once, and the task fails only at the `:DOWN` |
| 19 | `QuitBound` | a lasso: BROWSER-7's path |

The whole spec runs in about 45 s with the runner's one worker. The largest
checks are 15 (90,651 states and its liveness graph, 13 s) and 07 (444,456
states, 12 s). Every other check takes one to four seconds.

Each `holds` check was also run once by hand, with four workers, with one
more of an entity its rules are about. All still hold:

| Check | One more | States |
|---|---|---|
| 01 | task (3) | 412,490 |
| 01 | `tab.open` per task (2, caps 2 and 4) | 78,928 |
| 07 | task (3) | 4,309,190 |
| 07 | `tab.open` per task (2, caps 2 and 3) | 2,851,614 |
| 15 | task (3) | 2,368,476 |
| 15 | `tab.open` per task (2) | 155,819 |
| 17 | task (3) | 186,109 |
| 17 | a lock and an unlock | 137,729 |

## Not modelled

- `page.snapshot`, `page.screenshot`, `page.upload`, `dialog.resolve`,
  `cookies.*`, `host.status`, `tab.navigate`, `tab.list`, `tab.focus` and
  `tab.close`: each is one request on a tab the task owns, answered like
  `page.act`. `tab.list`'s `opener_tab_id` (`protocol.ex#listed_tab?`) is the
  wire field BROWSER-3 asked for, but the ownership it lets the app report is
  still the app reducer's own, unpinned.
- The `tab.closed`, `dialog.opened` and `download.*` events. They inform the
  daemon, and a request on a closed tab is answered with an error, which is
  what the model uses.
- Which of lock, display sleep or app termination made the host unavailable:
  one reason stands for all three.
- A new connection attaching before HostServer has taken the old one's
  `:DOWN`: the model attaches only after it, and this is the code, not a
  simplification — `Endpoint` refuses a second client while one is attached
  (`error: host_already_attached`, `endpoint.ex:209-219`) rather than queuing
  it. The connection binding (BROWSER-4) is what makes the other order safe
  too, but the code never takes that order. The daemon itself restarting is
  not modelled.
- The daemon restarting, and the person opening the app again after a quit,
  which should allow launching again (BROWSER-6).
- The socket's 0600 mode, the peer check, the line codec, the page's content,
  and the managed-Chrome backend's own rules: single-call rules that ExUnit
  covers, or other specs' subject.
- `FermixCore.Browser.TurnMarker`: found in the re-read, not asked for by the
  design spec. A turn (the process that made the first browser call — a
  conversation's turn, a scheduled run, a subagent — not the task itself) that
  loses its pane is marked, and `dispatch` reads that mark before `Routing`
  ever runs (`browser.ex:120-126`), so every later browser call of *that
  turn* answers the same sentence instead of being routed — a turn whose
  first task failed on the host never starts a second task that `Routing`
  could send to Chrome. This is a strictly stronger version of
  `NoChromeRetry`, scoped to the turn rather than the task, and this spec
  cannot state a rule that needs it: a `Task` here already stands for a whole
  turn's browser use — one script run to one `Terminal` state — and nothing
  in the model lets a second `Task` share a first one's caller once that
  first one has ended. `NoChromeAfterHostFailure` is proved by `NoChromeRetry`
  alone (check 05); switching `NoChromeRetry` off is what its `needs` check
  does, and no separate `needs TurnMarker` check would break anything
  differently, since the model has no way to run a second task on the first
  task's turn after the first has failed. Giving turns more than one task in
  sequence — a caller that keeps making browser calls after one profile was
  reaped — would be a bigger change to the model's shape than a re-read, so
  it is recorded here rather than modelled.

## Findings

Every finding below was first written as a design requirement, ahead of the
code. Each was then walked through the implementation on
`feat/browser-host-wire` and is fixed there, or holds by construction, with
the commit that lands the mechanism. None was reproduced on a running daemon.
The `needs` check named under each brings its counterexample back with its
fix's mechanism switched off; open `tla/out/browser_host/<check>.txt` after a
run to see the path. Entries marked **explored** come from a variant of the
spec run by hand.

### BROWSER-1: `task.release` must travel behind the task's own requests
- **Severity:** medium if built the other way: a tab no release will ever
  close, open on the person's machine until the app quits.
- **Status:** fixed (7cc024ee). `FermixChannels.BrowserHost.Connection` is the
  one process every request and release of a task pass through: both
  `:browser_host_request` and `:browser_host_release` are handled off the same
  mailbox, in the order they arrived (`task_request`, `release_task`,
  `connection.ex:328-365`), and both are written to the socket by the same
  `write_request` (`:382-394`). Holds in the design (check 07) and in the
  code.
- **Counterexample (explored, 12 states):** a variant in which the host may
  take a `task.release` ahead of requests queued before it.
  1. A task on the host sends `tab.open`.
  2. The person cancels the task. HostServer sends `task.release`.
  3. The host takes the release first: the task owns nothing yet, so nothing
     closes.
  4. The host takes the `tab.open` and opens a tab. HostServer drops the late
     answer. The tab stays open for good.
- **Requirement:**
  - Write `task.release` on the task's own connection, after its last
    request, and never on a side channel.
  - The host handles requests in arrival order and answers every one.
  - HostServer drops late answers for a task that has ended.
- **Consequence (explored, 10 states, then the host's step):** a `page.act`
  that is out when the person cancels still runs. The task sends the act, the
  person cancels, HostServer sends `task.release` behind it, and the host
  carries out the act before the release closes the tab. A click the person
  cancelled can still land. If the host is to pre-empt in-flight work on a
  cancel, it must remember released task ids and refuse their later
  requests, not let the release overtake them.

### BROWSER-2: a release must be idempotent, because two sides release the same tabs
- **Severity:** medium if built the other way. Each release is a
  `tab.closed{by: task}` event, and a second one for the same tab makes
  HostServer's per-task accounting go below zero.
- **Status:** fixed (7cc024ee, 32297ead). `Connection.release_task` pops the
  task id out of `state.tasks` on its first release and writes `task.release`
  only then; a second release for the same task id finds nothing and writes
  nothing (`connection.ex:356-365`, matching `PROTOCOL.md`'s "Idempotent: a
  second release for the same task answers `released: []`"). On the daemon
  side, `HostServer.stop/1` is a no-op once `task` is already `nil`
  (`host_server.ex:107-108`), so ending an already-ended task never sends a
  second `Link.release`. The design asks both sides to release: the host on
  `host_stopping` and on losing the daemon, and HostServer with
  `task.release` for every task it ends.
- **Checks:** check 08 (9 states) breaks `TabsReleasedExactlyOnce` when the
  host keeps a tab's record after releasing it.
- **Counterexample (check 08):**
  1. A task opens a tab on the host.
  2. The connection drops, and the host releases every task's tabs.
  3. The person quits the app, and the host releases them again from the
     records it kept.
- **The same shape (explored, 10 states):** with no drop, the task's
  `task.release` and then the host's own release at `host_stopping`.
- **Requirement:**
  - The host drops a tab's record at its first release or close, so a second
    release finds nothing.
  - HostServer counts one `tab.closed` per tab id.

### BROWSER-3: every tab needs an owner, and a popup takes its opener's
- **Severity:** high if built the other way. A task's release closes the
  person's own tab, and the idle release kills a task's tab mid-task.
- **Status:** the engine's own part is fixed (08ddc33b): `tab.list`'s
  `listedTab` result carries an optional `opener_tab_id`
  (`protocol.ex#listed_tab?`, `protocol.schema.json`'s `listedTab`), so the
  app can tell the daemon which tab is a popup's opener. The registry itself
  — keyed by tab, set at `tab.open`, inherited by a popup from its opener, and
  set to the person for a tab they open, with release, idle, the caps and the
  person's close all reading it — is `BrowserHostReducer`'s own state in
  `tezra-io/fermix-macos`, still an **unpinned mirror**: this repository has
  no code to verify it against, and the wire field is what lets the app prove
  it, not what enforces it. Holds in the design (check 07).
- **Checks:** 09 (5 states) and 10 (8 states) break
  `PersonTabsNeverReleasedByTasks` and `IdleReleaseSparesTaskTabs` with no
  registry. Check 12 (8 states) and witness 13 (14 states) show that popups
  must count against the caps.
- **Counterexample (check 09):**
  1. The person opens a tab, and its page opens a popup.
  2. With no owner to inherit, the popup joins the task pool.
  3. The connection drops, and the host's release of every task's tabs
     closes the person's popup.
- **Counterexample (check 10):**
  1. A task opens a tab and waits between two steps. No request is in flight
     and the person has no tab.
  2. A host that cannot see who owns a tab counts itself idle and releases
     its web views, the task's tab with them.
- **Requirement:**
  - A popup is registered to its opener's owner in the step the host creates
    its web view (`createWebViewWith`), and counted under that owner's cap
    there.
  - At the cap the popup is blocked.
  - The idle check reads the registry in the same reducer step that releases
    the web views, so a timer armed when the host went idle must re-read it
    when it fires.

### BROWSER-4: a host task is bound to the connection it was decided on
- **Severity:** high if built the other way. After a drop and a reconnect a
  task's next step lands on a host that released its tabs. If the host ever
  reuses a tab id, the step lands on another tab, possibly the person's.
- **Status:** fixed (32297ead). `HostServer.bind/2` records the connection and
  a monitor on it with the task at its first browser call
  (`host_server.ex:387-413`); `check_host/1` refuses the task on any other
  connection (`:417-430`), and its `handle_message` clause on that
  connection's `:DOWN` fails the task with a sentence whether or not a
  request is out (`:140-144`, `lose`, `:434-438`). Tabs are named
  `h<connection_id>:<wire_id>` (`public_id/2`, `:698`), so a tab id can never
  reach another connection's tab even if the app reused a wire id across
  connections. Holds in the design (check 01) and in the code.
- **Checks:** check 04 (15 states) breaks `NoTaskWithoutHost` when the task
  re-decides at every step.
- **Counterexample (check 04):**
  1. A task opens tab 1 on connection 1.
  2. The connection drops. The host releases tab 1, and HostServer takes the
     `:DOWN` with no request of the task out, so the task is not failed.
  3. The app reconnects as connection 2 and reports available.
  4. The task's `page.act` on tab 1 goes to connection 2, which never had
     it.
- **Requirement:**
  - HostServer records the connection with each host task.
  - At that connection's `:DOWN` it fails every such task with a sentence,
    whether or not a request is out.
  - It never sends their requests on a later connection.
  - Tab ids are never reused, across connections too.

### BROWSER-5: availability after `host_stopping` must not reopen the host
- **Severity:** low. A new task is routed to an app that is quitting, and it
  fails where Chrome would have run it.
- **Status:** fixed (01ed959f). `HostAvailability.handle_call({:report, ...})`
  is a no-op once `host.stopping` is `true` (`host_availability.ex:163-164`);
  `{:stopping, connection}` sets it only when `connection` matches the one it
  is currently attached on (`:171-172`), so a stale connection cannot mark a
  fresh one stopping; and it is cleared only by the next `attached/3`, which
  replaces the whole report (`attach/3`, `:206-217`). Holds in the design:
  stopping is final for its connection. **Explored:** with a report allowed
  after `host_stopping`, "no task is routed to a host HostServer knows is
  stopping" breaks in 10 states. The design holds it (70,446 states).
- **Counterexample (explored):**
  1. The screen is locked, and the host has reported it.
  2. The person quits: the host sends `host_stopping`.
  3. The person unlocks, and the host reports available behind it.
  4. HostServer takes `host_stopping`, then the report, and routes a new
     task to the quitting app.
- **Requirement:**
  - The host sends no availability after `host_stopping`.
  - HostServer treats stopping as final for that connection and ignores any
    later report on it.

### BROWSER-6: a quit the daemon never heard of does not stop the relaunch
- **Severity:** medium. The person quits the app, and the daemon launches it
  again hidden for the next task.
- **Status:** fixed with a bounded answer, not a definitive one (01ed959f).
  The daemon still has no `daemon.sock` signal for "the person quit before
  attaching" — `HostAvailability`'s `quit` field is set only by `stopping/2`
  (`host_availability.ex:171-173`), which needs an attached connection to say
  `host_stopping` on, exactly the case this finding is about. What the code
  adds instead is `host_launch_cooldown_ms`: `HostLauncher` records each
  launch's deadline (`launching/2`) and, once it passes with no attach,
  refuses to launch again for `cooldown_ms` after it (`cooling?/2`,
  `host_launcher.ex:131-132`), because "the app was quit before it attached"
  and "the launch crashed before it attached" look identical from here — the
  moduledoc calls this "the bounded answer to a quit the engine never hears
  of". So a quit-before-attach no longer launches the app again on every
  task, only after the cooldown elapses; it is bounded, not stopped for good.
- **Counterexample (explored, still reachable after the fix, past the
  cooldown):**
  1. The app is running but has not attached yet (just opened, or
     reconnecting after a drop). The person quits it.
  2. There is no connection, so there is no `host_stopping`, and HostServer
     never learns of the quit.
  3. The next task, within `host_launch_cooldown_ms` of the launch's deadline,
     runs on Chrome without relaunching (the fix); one that starts after the
     cooldown finds no host attached and launches the app hidden again (the
     original finding, now bounded rather than immediate).
- **Requirement:** launching must stop after a quit however the app exits, or
  at least not repeat on every task. A permanent stop would need the app to
  tell the daemon over `daemon.sock` that the person quit, when it has no
  `browser_host.sock` connection to say it on, with launching allowed again
  when the person opens the app themselves; neither the permanent signal nor
  its allow-again counterpart is modelled here, only the cooldown that bounds
  the gap.

### BROWSER-7: the quit hold must end on its bound, because the answer can be lost
- **Severity:** medium if built the other way: the app never quits.
- **Status:** the engine's half is fixed (7cc024ee); the hold and its bound
  are the app's own, unpinned. `Connection.host_stopping` releases every task
  still bound to it (`Enum.reduce` over `state.tasks`, calling
  `release_task`) before it answers `host.stop_ack` behind them
  (`connection.ex:270-284`), matching `PROTOCOL.md`'s "Quit mid-task": the
  daemon never answers before every release it owes is on the wire. Holding
  the quit for that answer, or ending the hold on its own bound if the answer
  is lost, is `BrowserHostReducer`'s job in `tezra-io/fermix-macos`, still
  unmodelled here. Holds in the design (check 17).
- **Checks:** check 19 (a lasso) breaks `QuitNeverAbandons` with no bound.
- **Counterexample (check 19):**
  1. The person quits the attached app. It releases every task's tabs, sends
     `host_stopping` and holds.
  2. The connection drops. HostServer reads `host_stopping` and answers into
     a closed socket.
  3. The app waits for that answer forever.
- **Requirement:** the hold ends on the answer or when the bound elapses,
  whichever comes first. Ending it at once on losing the daemon is the same
  rule with a bound of zero. The tabs were released at `host_stopping`, so
  nothing is left to hand back.

### BROWSER-8: a launch whose app dies before it attaches is ended only by the deadline
- **Severity:** medium if built without the deadline: tasks that never end.
- **Status:** fixed (01ed959f). `HostLauncher.pending?/2` sends a second task
  that finds a launch already running to wait on that SAME launch's deadline,
  never a fresh one of its own (`host_launcher.ex:129`, `launched_step/1`,
  `:134-135`); `waited_deadline/3` shrinks the loop's own deadline down to
  that recorded launch, never past it (`:154-158`), so nothing but the one
  deadline ends the wait, however many tasks are on it. Holds in the design
  (check 15).
- **Checks:** check 16 (a lasso) breaks `EveryTaskTerminates` with no
  deadline.
- **Counterexample (check 16):**
  1. A task starts with no host, and HostServer launches the app.
  2. The app crashes before it attaches.
  3. A second task finds the launch pending and waits on it too
     (`SingleLaunch`).
  4. Nothing will ever attach, and both tasks wait forever.
- **Requirement:** one deadline per launch, started with it, that decides
  Chrome for every task waiting on it. HostServer cannot tell a crashed
  launch from a slow one, so nothing but that deadline may end the wait.

### Design notes the checks do not cover
- **The decision can be one report stale.** A lock the host has reported but
  HostServer has not yet read does not stop a task being routed to the host.
  The report then fails the task, as witness 06 shows. This is the owner's
  rule, "identify early, never retry with Chrome": the task's sentence must
  say the Mac was locked or asleep, and nothing may re-run it. The code
  carries this rule one step further than the design asked (see `TurnMarker`
  under "Not modelled"): the whole turn, not just the task, is kept off
  Chrome.
- **A task that starts between the attach and the first report runs on
  Chrome,** as the design reads ("an attached host whose last report is
  available"), even if the report is about to say available. Waiting on the
  report instead, under the launch deadline, would be a design change.
- **The caps count task tabs only.** The person's tabs never block a task,
  and a task never closes a tab to make room. That is the opposite of managed
  Chrome's cap, which evicts the oldest tab.
