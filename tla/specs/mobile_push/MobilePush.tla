----------------------------- MODULE MobilePush -----------------------------
(***************************************************************************)
(* DESIGN SPEC, written before the code: how a reply reaches the owner's   *)
(* phones as a notification, for ONE profile. The design is M51's push     *)
(* contract (docs/design/MILESTONE_51_ANDROID_COMPANION_APP.md, decisions  *)
(* D20 to D22 and section 10). The processes:                              *)
(*  - the writer of a pushable row (the reply that ends a turn, or a       *)
(*    proactive row), which announces the row to the live sockets and      *)
(*    starts that row's push task;                                         *)
(*  - one push task per row: its one wait, its decision, its attempts at   *)
(*    the dispatcher, and the write of the profile's push cursor;          *)
(*  - the DeviceRegistry and each device's socket, which carries the       *)
(*    phone's ack;                                                         *)
(*  - the push platform (FCM or APNs), which holds what it accepted;       *)
(*  - each phone's app: it takes rows off its socket, announces them, and  *)
(*    handles a push;                                                      *)
(*  - the owner, who opens, leaves and navigates the app and may read the  *)
(*    reply on the Mac;                                                    *)
(*  - the faults: an app frozen with its socket open, a dispatcher call    *)
(*    that fails or whose answer is lost, and a daemon crash.              *)
(*                                                                         *)
(* The SOURCE pins name the code the design replaces. Every mechanism      *)
(* switch is TRUE for the design; where today's code is that mechanism     *)
(* switched off, the switch says so, and its `needs` check is then also    *)
(* the statement of what today's code gets wrong. When stage D2 lands,     *)
(* this spec goes STALE and is re-read against the implementation. The     *)
(* phone app lives in another repository and has no pin.                   *)
(*                                                                         *)
(* Rows are numbered in server_seq order. Time is abstract: the task's     *)
(* one wait of 5 s is "the decision has not run yet", and the 2 s, 10 s    *)
(* and 30 s between attempts are "the next attempt has not run yet".       *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - approvals and failed turns. They carry no server_seq, go to every    *)
(*    registered device at once through the same attempts, and the phone   *)
(*    deduplicates them by id in the same notified set. What is theirs     *)
(*    alone (no retry past expires_at, a late approval shown as expired)   *)
(*    is a single-call rule;                                               *)
(*  - push_unregister, UNREGISTERED / NOT_FOUND (terminal before any       *)
(*    retry) and a device with no token: a device is registered            *)
(*    throughout;                                                          *)
(*  - the push TTL (24 h) and the boot check's "younger than the TTL";     *)
(*  - the plaintext, its padding and the encryption (single-call rules,    *)
(*    pinned by push_vectors.json);                                        *)
(*  - rows that are not pushable (the owner's own messages, the sealed     *)
(*    bubbles before the last one);                                        *)
(*  - history paging: a connecting phone receives every row at once;       *)
(*  - what a turn is, and the Queue (turn_queue, companion_session).       *)
(*                                                                         *)
(* One step = one callback of one process, one Memory.Repo call, one call  *)
(* at the push platform, or one thing the app, the owner or the            *)
(* environment does. Three steps fold calls together; each says why.       *)
(***************************************************************************)
\* SOURCE: apps/fermix_channels/lib/fermix_channels/mobile/push.ex @ c5c4223a58ba
\* SOURCE: apps/fermix_channels/lib/fermix_channels/channels/mobile.ex#schedule_push,launch_push,default_push_launcher,notify_timeline_row,push_notify,maybe_schedule_proactive_push,deliver_persisted_text,delivered_text,deliver_persisted_media,phone_effects,build_turn_result,schedule_request_push,broadcast,emit,emit_after_commit @ e2011201a5c1
\* SOURCE: apps/fermix_channels/lib/fermix_channels/mobile/event_router.ex#after_settle,end_phone_turn,schedule_settled_push @ d42cb71bf67e
\* SOURCE: apps/fermix_channels/lib/fermix_channels/mobile/device_registry.ex @ 2947cb567cb4
\* SOURCE: apps/fermix_channels/lib/fermix_channels/mobile/socket_handler.ex#dispatch_event,terminate @ 2ef0feef5137
\* SOURCE: apps/fermix_channels/lib/fermix_channels/mobile/router.ex#socket_options,@idle_grace_ms @ baf5f2adb72c
EXTENDS Naturals, FiniteSets

CONSTANTS
    Devices,        \* the paired, registered phones, e.g. {a, b}
    Idle,           \* the phones whose owner never opens the app in this
                    \* behaviour: they only receive pushes
    MaxRows,        \* pushable rows the conversation produces (1 or 2)
    MaxFaults,      \* bound: freezes and daemon crashes in one behaviour
    MaxFailures,    \* bound: dispatcher calls that fail or lose their answer
    \* Environment switches: what may happen.
    SocketsCanFreeze,     \* the OS freezes an app without closing its socket
    DispatchCanFail,      \* a dispatcher call returns a transient error
    AnswerCanBeLost,      \* the platform accepted a push and the daemon saw a
                          \* timeout instead
    DaemonCanCrash,       \* the daemon dies and boots again
    OwnerReadsElsewhere,  \* the owner reads the reply on the Mac
    \* Mechanism switches: what the design does about it. TRUE is the design
    \* (M51 section 10); each is switched off by at least one check.
    DecidesOnEvidence,    \* D20: the decision reads the read frontier and each
                          \* device's acked cursor. FALSE is today's code: any
                          \* registered socket of the profile suppresses the
                          \* push for every device (push.ex:164, :407-417)
    AcksAfterAnnounce,    \* the app acks a row once it has announced it (shown
                          \* it on screen or posted its notification), never
                          \* on persisting it alone
    LocalNotify,          \* the app posts the notification itself for a row
                          \* that arrives while its chat is off screen
    NotifiedSet,          \* D22: the app announces an id once, whichever path
                          \* brought it
    RetriesTransient,     \* D21: a transient dispatcher error is retried.
                          \* FALSE is today's code: one attempt, its failure
                          \* logged (channels/mobile.ex:596-603)
    AttemptCap,           \* D21: at most three attempts per device
    BootCheck,            \* D21: the boot step that reads push_attempted_seq.
                          \* FALSE is today's code: nothing runs at boot
    \* Design option: FALSE is the design as written.
    WatermarkCursor       \* the cursor is the highest row below which every
                          \* row concluded, and the boot step decides every
                          \* row above it

Rows == 1..MaxRows
Cap == 3

VARIABLES
    head,       \* SQLite: the newest pushable row written (0 = none yet)
    readUpTo,   \* SQLite: the profile's read frontier
    cursor,     \* SQLite: push_attempted_seq
    daemon,     \* "up" or "down" (crashed, not booted yet)
    reg,        \* DeviceRegistry, per device: "open" (a socket is registered)
                \* or "none"
    acked,      \* DeviceRegistry entry, per device: the socket's acked cursor
    wire,       \* per device: row events sent to its socket and not yet taken
                \* by the app; lost when the socket goes
    task,       \* push task, per row: "none" (never started, or lost in a
                \* crash), "wait" (started, not decided), "run" (decided) or
                \* "done" (concluded)
    ob,         \* push task, per row and device: "none", "pending" (to be
                \* pushed), or how it ended: "sent", "read", "acked",
                \* "presence" (today's suppression) or "failed"
    tries,      \* push task, per row and device: dispatcher calls made
    atPlatform, \* platform, per device: pushes accepted and not yet handed
                \* to the phone
    accepted,   \* observer, per row and device: the platform accepted a push
    app,        \* phone, per device: "away" (not in the foreground, no
                \* socket), "on" (foreground, the chat on screen), "off"
                \* (foreground elsewhere, or inside the background grace) or
                \* "frozen" (suspended, its socket still open)
    have,       \* phone, per device: the newest row it has persisted
    unannounced,\* phone, per device: rows persisted and not announced yet
    noted,      \* phone, per device: the notified set, which holds every id
                \* the owner was told of on this phone
    twice,      \* observer: a phone alerted for an id it had already told
    alertedAfterRead,
                \* observer: a phone alerted for a row the owner had read
    faults,     \* freezes and crashes still allowed
    failures    \* failing dispatcher calls still allowed

vars == <<head, readUpTo, cursor, daemon, reg, acked, wire, task, ob, tries,
          atPlatform, accepted, app, have, unannounced, noted, twice,
          alertedAfterRead, faults, failures>>

durable == <<head, readUpTo, cursor>>
sockets == <<reg, acked, wire>>
pushTask == <<task, ob, tries>>
platform == <<atPlatform, accepted>>
observers == <<twice, alertedAfterRead>>
budgets == <<faults, failures>>

Ended == {"sent", "read", "acked", "presence", "failed"}

Max(x, y) == IF x >= y THEN x ELSE y
Lowest(S) == CHOOSE x \in S : \A y \in S : x <= y

-----------------------------------------------------------------------------
(* What the phone does with an id *)

\* The app is running in the foreground, or inside its background grace.
Running(d) == app[d] \in {"on", "off"}

\* Its socket is the registered one and the daemon is there to answer.
Linked(d) == Running(d) /\ reg[d] = "open" /\ daemon = "up"

\* The phone puts row r in front of the owner as a notification.
Alert(d, r) ==
    /\ noted' = [noted EXCEPT ![d] = @ \cup {r}]
    /\ twice' = (twice \/ r \in noted[d])
    /\ alertedAfterRead' = (alertedAfterRead \/ readUpTo >= r)

\* The phone records the id without alerting: the row is on screen, or the
\* phone knows it was read.
Quiet(d, r) ==
    /\ noted' = [noted EXCEPT ![d] = @ \cup {r}]
    /\ UNCHANGED <<twice, alertedAfterRead>>

\* M51 section 10, Lifecycle on the phone: "A push or a socket row whose
\* server_seq is already in the set, already read, or on screen adds nothing
\* and alerts nobody." A phone knows the read frontier only while linked.
Announce(d, r) ==
    IF NotifiedSet /\ r \in noted[d]
    THEN UNCHANGED <<noted, twice, alertedAfterRead>>
    ELSE IF app[d] = "on" \/ (Linked(d) /\ readUpTo >= r)
    THEN Quiet(d, r)
    ELSE Alert(d, r)

\* The highest row the app may ack. M51 section 7, `ack`: once the row is
\* announced. With the mechanism off it is the design's first draft: "as soon
\* as the row is persisted locally".
AckTarget(d) ==
    IF AcksAfterAnnounce /\ unannounced[d] /= {}
    THEN Lowest(unannounced[d]) - 1
    ELSE have[d]

-----------------------------------------------------------------------------
(* The writer and the push task (Channels.Mobile, Mobile.Push) *)

\* deliver_persisted_text / deliver_persisted_media for a row nobody asked
\* for (channels/mobile.ex:488-513), and for a request's reply its
\* settlement: build_turn_result when it became a turn (:200-206,
\* :1034-1044), Mobile.EventRouter.after_settle -> schedule_settled_push when
\* it did not (event_router.ex:142-168), after the turn_done that ends the
\* request's turn on the phones (end_phone_turn, :148-153; not a row). The
\* row's Repo write, then emit_after_commit -> DeviceRegistry.broadcast
\* (:559-564, :918-931), then schedule_push -> Task.Supervisor.start_child
\* (:380-386, :579-594). A row nobody asked for reaches the sockets as a
\* `row`, a reply as its turn's `text_done` (delivered_text, :500-505): either
\* way the phone takes the row.
\* Three calls folded into one step: a crash between them leaves what a crash
\* right after them leaves, a durable row with no task, because the registry
\* and the task die with the daemon.
WriteRow ==
    /\ daemon = "up" /\ head < MaxRows
    /\ head' = head + 1
    /\ wire' = [d \in Devices |->
                  IF reg[d] = "open" THEN wire[d] \cup {head + 1} ELSE wire[d]]
    /\ task' = [task EXCEPT ![head + 1] = "wait"]
    /\ UNCHANGED <<readUpTo, cursor, daemon, reg, acked, ob, tries, platform, app,
                   have, unannounced, noted, observers, budgets>>

AnySocket == \E d \in Devices : reg[d] = "open"

\* The design, M51 section 10 Trigger: "no push at all if the profile's
\* read_up_to_seq covers the row ...; else a push to every registered device
\* whose acked cursor has not reached the row, which includes a device with
\* no socket and one whose socket closed or froze meanwhile."
\* Today's code, push.ex:156-181 and :516-518: presence first, then the
\* frontier.
Decision(r, d) ==
    IF DecidesOnEvidence
    THEN IF readUpTo >= r THEN "read"
         ELSE IF reg[d] = "open" /\ acked[d] >= r THEN "acked"
         ELSE "pending"
    ELSE IF AnySocket THEN "presence"
         ELSE IF readUpTo >= r THEN "read"
         ELSE "pending"

\* Mobile.Push.notify after the task's one wait (today: maybe_notify,
\* push.ex:156-162). It reads the frontier (one Repo call, :419-422) and the
\* registry (one GenServer call, :407-417). The two reads are folded into one
\* step: both values only grow while a socket lives, a socket that goes takes
\* its acked cursor with it and is then pushed, and a read that lands after
\* the decision is the race Witness_AlertAfterRead keeps in view.
Decide(r) ==
    /\ daemon = "up" /\ task[r] = "wait"
    /\ task' = [task EXCEPT ![r] = "run"]
    /\ ob' = [ob EXCEPT ![r] = [d \in Devices |-> Decision(r, d)]]
    /\ tries' = [tries EXCEPT ![r] = [d \in Devices |-> 0]]
    /\ UNCHANGED <<durable, daemon, sockets, platform, app, have, unannounced,
                   noted, observers, budgets>>

\* What a failed attempt numbered n leaves. M51 section 10, Retries: "at
\* most three attempts"; today's code makes one (push.ex:225-255).
AfterFailure(n) ==
    IF RetriesTransient /\ (n < Cap \/ ~AttemptCap) THEN "pending" ELSE "failed"

\* One dispatcher call for one device (today: dispatch/3, push.ex:225-231,
\* which sends every device's notification in one call). The platform takes
\* the push and says so, or the call fails, or the platform takes the push
\* and the daemon sees a timeout. The spec stops at a fourth attempt: that is
\* the attempt the rule forbids.
Attempt(r, d) ==
    /\ daemon = "up" /\ task[r] = "run" /\ ob[r][d] = "pending"
    /\ tries[r][d] <= Cap
    /\ tries' = [tries EXCEPT ![r][d] = @ + 1]
    /\ \/ /\ ob' = [ob EXCEPT ![r][d] = "sent"]
          /\ atPlatform' = [atPlatform EXCEPT ![d] = @ \cup {r}]
          /\ accepted' = [accepted EXCEPT ![r][d] = TRUE]
          /\ UNCHANGED failures
       \/ /\ DispatchCanFail /\ failures > 0
          /\ failures' = failures - 1
          /\ ob' = [ob EXCEPT ![r][d] = AfterFailure(tries[r][d] + 1)]
          /\ UNCHANGED platform
       \/ /\ AnswerCanBeLost /\ failures > 0
          /\ failures' = failures - 1
          /\ ob' = [ob EXCEPT ![r][d] = AfterFailure(tries[r][d] + 1)]
          /\ atPlatform' = [atPlatform EXCEPT ![d] = @ \cup {r}]
          /\ accepted' = [accepted EXCEPT ![r][d] = TRUE]
    /\ UNCHANGED <<durable, daemon, sockets, task, app, have, unannounced, noted,
                   observers, faults>>

\* The highest row below which every row concluded.
Watermark(t) ==
    CHOOSE k \in 0..MaxRows :
        /\ \A j \in 1..k : t[j] = "done"
        /\ k = MaxRows \/ t[k + 1] /= "done"

\* M51 section 10, Retries: "When the attempts for a row conclude, the daemon
\* advances the profile's push_attempted_seq in mobile_profile_state
\* (monotonic)." One Repo call. No such cursor exists today.
Conclude(r) ==
    /\ daemon = "up" /\ task[r] = "run"
    /\ \A d \in Devices : ob[r][d] \in Ended
    /\ task' = [task EXCEPT ![r] = "done"]
    /\ cursor' = IF WatermarkCursor
                 THEN Max(cursor, Watermark([task EXCEPT ![r] = "done"]))
                 ELSE Max(cursor, r)
    /\ UNCHANGED <<head, readUpTo, daemon, sockets, ob, tries, platform, app, have,
                   unannounced, noted, observers, budgets>>

-----------------------------------------------------------------------------
(* The daemon's crash and boot *)

InFlight == \E r \in Rows : task[r] \in {"wait", "run"}

\* The BEAM dies. Every task, the registry and every socket go; what the
\* platform accepted stays there; the rows and both cursors are SQLite. The
\* apps keep running and their reconnect loops find the daemon again.
DaemonCrash ==
    /\ DaemonCanCrash /\ faults > 0
    /\ daemon = "up" /\ InFlight
    /\ faults' = faults - 1
    /\ daemon' = "down"
    /\ task' = [r \in Rows |-> IF task[r] \in {"wait", "run"} THEN "none" ELSE task[r]]
    /\ ob' = [r \in Rows |-> [d \in Devices |->
                IF ob[r][d] = "pending" THEN "none" ELSE ob[r][d]]]
    /\ reg' = [d \in Devices |-> "none"]
    /\ acked' = [d \in Devices |-> 0]
    /\ wire' = [d \in Devices |-> {}]
    /\ UNCHANGED <<durable, tries, platform, app, have, unannounced, noted,
                   observers, failures>>

\* The rows the boot step starts a task for. As written, M51 section 10: the
\* "newest pushable row ... above both push_attempted_seq and read_up_to_seq
\* ... the daemon runs the normal decision once for that row".
Relaunched ==
    IF ~BootCheck THEN {}
    ELSE IF WatermarkCursor THEN {r \in Rows : cursor < r /\ r <= head}
    ELSE IF head > cursor /\ head > readUpTo THEN {head}
    ELSE {}

\* The mobile channel boots (M51 section 11.4: "a boot step runs the
\* restart-gap check once per profile"). Two Repo reads and the task starts,
\* folded into one step: nothing else runs on the channel before it.
Boot ==
    /\ daemon = "down"
    /\ daemon' = "up"
    /\ task' = [r \in Rows |-> IF r \in Relaunched THEN "wait" ELSE task[r]]
    /\ ob' = [r \in Rows |->
                IF r \in Relaunched THEN [d \in Devices |-> "none"] ELSE ob[r]]
    /\ tries' = [r \in Rows |->
                IF r \in Relaunched THEN [d \in Devices |-> 0] ELSE tries[r]]
    /\ UNCHANGED <<durable, sockets, platform, app, have, unannounced, noted,
                   observers, budgets>>

-----------------------------------------------------------------------------
(* A socket, seen from the daemon *)

\* The transport's idle timeout closes a socket nothing was read from for
\* 150 s (router.ex:20, :61-68); SocketHandler.terminate (socket_handler.ex:
\* 230-237) and the registry's :DOWN (device_registry.ex:213-215) drop the
\* entry. Only a frozen app leaves its socket to this timeout.
IdleTimeout(d) ==
    /\ daemon = "up" /\ reg[d] = "open" /\ app[d] = "frozen"
    /\ reg' = [reg EXCEPT ![d] = "none"]
    /\ acked' = [acked EXCEPT ![d] = 0]
    /\ wire' = [wire EXCEPT ![d] = {}]
    /\ UNCHANGED <<durable, daemon, pushTask, platform, app, have, unannounced,
                   noted, observers, budgets>>

\* dispatch_event "ack" (socket_handler.ex:756-757) and, in the design, the
\* registry entry's acked_seq (M51 section 11.4). The app's send and the
\* daemon's handling are one step: an ack lost on the way is an ack sent
\* late, and the app may ack at any moment here.
AckArrives(d) ==
    /\ Linked(d)
    /\ acked[d] < AckTarget(d)
    /\ acked' = [acked EXCEPT ![d] = AckTarget(d)]
    /\ UNCHANGED <<durable, daemon, reg, wire, pushTask, platform, app, have,
                   unannounced, noted, observers, budgets>>

-----------------------------------------------------------------------------
(* The phone's app (another repository; M51 sections 8.2, 10 and 12.5) *)

\* The app's reconnect loop: hello, hello_ack, then the rows it lacks.
\* Attaching replaces any older entry (device_registry.ex:119-130, :222-236).
Connect(d) ==
    /\ Running(d) /\ reg[d] = "none" /\ daemon = "up"
    /\ reg' = [reg EXCEPT ![d] = "open"]
    /\ have' = [have EXCEPT ![d] = head]
    /\ unannounced' = [unannounced EXCEPT ![d] =
                         @ \cup {r \in Rows : have[d] < r /\ r <= head}]
    /\ UNCHANGED <<durable, daemon, acked, wire, pushTask, platform, app, noted,
                   observers, budgets>>

\* The app takes the next row event off its socket and persists it.
TakeRow(d) ==
    /\ Linked(d) /\ wire[d] /= {}
    /\ LET r == Lowest(wire[d]) IN
         /\ wire' = [wire EXCEPT ![d] = @ \ {r}]
         /\ have' = [have EXCEPT ![d] = Max(@, r)]
         /\ unannounced' = [unannounced EXCEPT ![d] = @ \cup {r}]
    /\ UNCHANGED <<durable, daemon, reg, acked, pushTask, platform, app, noted,
                   observers, budgets>>

\* The app announces the next row it persisted: on screen, or as a
\* notification it posts itself. Without LocalNotify the row is only listed.
AnnounceNext(d) ==
    /\ Running(d) /\ unannounced[d] /= {}
    /\ LET r == Lowest(unannounced[d]) IN
         /\ unannounced' = [unannounced EXCEPT ![d] = @ \ {r}]
         /\ IF app[d] = "off" /\ ~LocalNotify
            THEN UNCHANGED <<noted, twice, alertedAfterRead>>
            ELSE Announce(d, r)
    /\ UNCHANGED <<durable, daemon, sockets, pushTask, platform, app, have,
                   budgets>>

\* read_state from the chat on screen (Timeline.advance_read_frontier, one
\* Repo call).
PhoneRead(d) ==
    /\ Linked(d) /\ app[d] = "on"
    /\ unannounced[d] = {} /\ readUpTo < have[d]
    /\ readUpTo' = have[d]
    /\ UNCHANGED <<head, cursor, daemon, sockets, pushTask, platform, app, have,
                   unannounced, noted, observers, budgets>>

\* The platform hands a push to the phone, whatever the app is doing: a
\* high-priority message wakes it. A push the platform never delivers (its
\* TTL, a phone that never returns) is one that stays there.
PushArrives(d, r) ==
    /\ r \in atPlatform[d]
    /\ atPlatform' = [atPlatform EXCEPT ![d] = @ \ {r}]
    /\ Announce(d, r)
    /\ UNCHANGED <<durable, daemon, sockets, pushTask, accepted, app, have,
                   unannounced, budgets>>

-----------------------------------------------------------------------------
(* The owner, and the OS *)

\* The rows a phone holds come on screen with the chat.
Shown(d) == [noted EXCEPT ![d] = @ \cup (1..have[d])]

\* The owner opens the app, on the chat or elsewhere. A frozen app's socket
\* is dead: the daemon closes the older one when the new one attaches (close
\* code 4001), folded here.
Open(d) ==
    /\ d \notin Idle
    /\ app[d] \in {"away", "frozen"}
    /\ \E s \in {"on", "off"} :
         /\ app' = [app EXCEPT ![d] = s]
         /\ noted' = IF s = "on" THEN Shown(d) ELSE noted
         /\ unannounced' = IF s = "on"
                           THEN [unannounced EXCEPT ![d] = {}]
                           ELSE unannounced
    /\ reg' = [reg EXCEPT ![d] = "none"]
    /\ acked' = [acked EXCEPT ![d] = 0]
    /\ wire' = [wire EXCEPT ![d] = {}]
    /\ UNCHANGED <<durable, daemon, pushTask, platform, have, observers, budgets>>

\* The owner moves between the chat and another screen.
Navigate(d) ==
    /\ Running(d)
    /\ IF app[d] = "on"
       THEN /\ app' = [app EXCEPT ![d] = "off"]
            /\ UNCHANGED <<noted, unannounced>>
       ELSE /\ app' = [app EXCEPT ![d] = "on"]
            /\ noted' = Shown(d)
            /\ unannounced' = [unannounced EXCEPT ![d] = {}]
    /\ UNCHANGED <<durable, daemon, sockets, pushTask, platform, have, observers,
                   budgets>>

\* The owner leaves the app and the grace ends: a clean close (M51 section
\* 12.5). Persisting and announcing a row takes milliseconds and the grace
\* is 5 s, so the app has announced what it took; rows still on the socket
\* are lost with it.
Leave(d) ==
    /\ Running(d) /\ unannounced[d] = {}
    /\ app' = [app EXCEPT ![d] = "away"]
    /\ reg' = [reg EXCEPT ![d] = "none"]
    /\ acked' = [acked EXCEPT ![d] = 0]
    /\ wire' = [wire EXCEPT ![d] = {}]
    /\ UNCHANGED <<durable, daemon, pushTask, platform, have, unannounced, noted,
                   observers, budgets>>

\* The OS suspends the app with no clean close. The daemon still holds its
\* socket as registered (R18).
Freeze(d) ==
    /\ SocketsCanFreeze /\ faults > 0
    /\ Running(d)
    /\ faults' = faults - 1
    /\ app' = [app EXCEPT ![d] = "frozen"]
    /\ UNCHANGED <<durable, daemon, sockets, pushTask, platform, have, unannounced,
                   noted, observers, failures>>

\* The owner reads the reply on the Mac: the companion socket's read_state.
ReadElsewhere ==
    /\ OwnerReadsElsewhere
    /\ daemon = "up" /\ readUpTo < head
    /\ readUpTo' = head
    /\ UNCHANGED <<head, cursor, daemon, sockets, pushTask, platform, app, have,
                   unannounced, noted, observers, budgets>>

-----------------------------------------------------------------------------
(* Type invariant *)

TypeOK ==
    /\ head \in 0..MaxRows /\ readUpTo \in 0..MaxRows /\ cursor \in 0..MaxRows
    /\ daemon \in {"up", "down"}
    /\ reg \in [Devices -> {"none", "open"}]
    /\ acked \in [Devices -> 0..MaxRows]
    /\ wire \in [Devices -> SUBSET Rows]
    /\ task \in [Rows -> {"none", "wait", "run", "done"}]
    /\ ob \in [Rows -> [Devices -> {"none", "pending"} \cup Ended]]
    /\ tries \in [Rows -> [Devices -> 0..(Cap + 1)]]
    /\ atPlatform \in [Devices -> SUBSET Rows]
    /\ accepted \in [Rows -> [Devices -> BOOLEAN]]
    /\ app \in [Devices -> {"away", "on", "off", "frozen"}]
    /\ have \in [Devices -> 0..MaxRows]
    /\ unannounced \in [Devices -> SUBSET Rows]
    /\ noted \in [Devices -> SUBSET Rows]
    /\ twice \in BOOLEAN /\ alertedAfterRead \in BOOLEAN
    /\ faults \in 0..MaxFaults /\ failures \in 0..MaxFailures
    /\ Idle \subseteq Devices

-----------------------------------------------------------------------------
Init ==
    /\ head = 0 /\ readUpTo = 0 /\ cursor = 0
    /\ daemon = "up"
    /\ reg = [d \in Devices |-> "none"]
    /\ acked = [d \in Devices |-> 0]
    /\ wire = [d \in Devices |-> {}]
    /\ task = [r \in Rows |-> "none"]
    /\ ob = [r \in Rows |-> [d \in Devices |-> "none"]]
    /\ tries = [r \in Rows |-> [d \in Devices |-> 0]]
    /\ atPlatform = [d \in Devices |-> {}]
    /\ accepted = [r \in Rows |-> [d \in Devices |-> FALSE]]
    /\ app = [d \in Devices |-> "away"]
    /\ have = [d \in Devices |-> 0]
    /\ unannounced = [d \in Devices |-> {}]
    /\ noted = [d \in Devices |-> {}]
    /\ twice = FALSE /\ alertedAfterRead = FALSE
    /\ faults = MaxFaults /\ failures = MaxFailures

\* There is no end state: the owner can always open or leave the app, and a
\* daemon that is down can always boot. Deadlock checking stays on, so a
\* state where nothing at all can happen is still reported.
Next ==
    \/ WriteRow \/ DaemonCrash \/ Boot \/ ReadElsewhere
    \/ \E r \in Rows : Decide(r) \/ Conclude(r)
    \/ \E r \in Rows, d \in Devices : Attempt(r, d) \/ PushArrives(d, r)
    \/ \E d \in Devices :
          \/ IdleTimeout(d) \/ AckArrives(d) \/ Connect(d) \/ TakeRow(d)
          \/ AnnounceNext(d) \/ PhoneRead(d)
          \/ Open(d) \/ Navigate(d) \/ Leave(d) \/ Freeze(d)

\* Fairness only on what Fermix drives: the push task's steps, the boot, the
\* transport's timeout, and a running app's own work (its reconnect loop,
\* taking and announcing rows, its ack and its read_state). None on the
\* writer (a turn may never end), the owner, the OS, the push platform or
\* the faults.
Fairness ==
    /\ WF_vars(Boot)
    /\ \A r \in Rows : WF_vars(Decide(r)) /\ WF_vars(Conclude(r))
    /\ \A r \in Rows, d \in Devices : WF_vars(Attempt(r, d))
    /\ \A d \in Devices :
          /\ WF_vars(IdleTimeout(d)) /\ WF_vars(AckArrives(d))
          /\ WF_vars(Connect(d)) /\ WF_vars(TakeRow(d))
          /\ WF_vars(AnnounceNext(d)) /\ WF_vars(PhoneRead(d))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* M51 section 10, Lifecycle on the phone: "A push or a socket row whose
\* server_seq is already in the set, already read, or on screen adds nothing
\* and alerts nobody."
AtMostOneAlert == ~twice

\* M51 D21 and section 10, Retries: "at most three attempts" per device.
AttemptsBounded == \A r \in Rows, d \in Devices : tries[r][d] <= Cap

\* M51 section 10, Retries: a transient dispatcher error "is retried for that
\* device only". Read as: the daemon gives a device up only after the third
\* attempt.
GivesUpOnlyAfterThree ==
    \A r \in Rows, d \in Devices : ob[r][d] = "failed" => tries[r][d] >= Cap

\* M51 D20: "Decided from evidence, not presence." Read as: a device is
\* skipped only because the owner read the row, or because that phone holds
\* it.
SkippedOnlyOnEvidence ==
    \A r \in Rows, d \in Devices :
        /\ ob[r][d] /= "presence"
        /\ ob[r][d] = "read" => readUpTo >= r
        /\ ob[r][d] = "acked" => have[d] >= r

\* The owner was told of row r on phone d, or the platform holds a push of
\* it for d, or the daemon gave d up and said so.
Accounted(r, d) == r \in noted[d] \/ accepted[r][d] \/ ob[r][d] = "failed"

RowSettled(r) == readUpTo >= r \/ \A d \in Devices : Accounted(r, d)

\* The rule the design claims (M51 goal G4, D20 and D21): a reply the owner
\* has not read is, in the end, announced on every phone, held by the push
\* platform for it, or given up with a logged failure. It is a rule about
\* the chat: it speaks of the newest row.
ChatAccounted == <>[](head = 0 \/ RowSettled(head))

\* Proposed rule: the same for every unread row, not only the newest. The
\* design does not claim it (PUSH-1).
EveryRowAccounted == <>[](\A r \in 1..head : RowSettled(r))

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* A phone alerts for a reply the owner has already read: the decision ran
\* before the read, or the phone had no socket to learn of it.
Witness_AlertAfterRead == ~alertedAfterRead

\* A push is on its way to a phone that has told its row already: the
\* notified set has work to do.
Witness_RedundantPush ==
    \A d \in Devices : atPlatform[d] \cap noted[d] = {}

\* The decision marks a device for a push while its socket is registered,
\* because the socket's ack has not reached the row: the case D20 exists
\* for. It is a rule about the decision's step, so that a phone connecting
\* after the decision does not count.
Witness_PushBehindOpenSocket ==
    [][\A r \in Rows, d \in Devices :
          (task[r] = "wait" /\ task'[r] = "run" /\ reg[d] = "open")
              => ob'[r][d] /= "pending"]_vars

=============================================================================
