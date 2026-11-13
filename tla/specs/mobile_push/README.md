# mobile_push: how a reply reaches the owner's phones as a notification

**A design spec, written before the code.** It models the push contract of M51
(`docs/design/MILESTONE_51_ANDROID_COMPANION_APP.md`, decisions D20 to D22 and
§10) for one profile, which is one chat on the phone:
- the writer of a pushable row (the reply that ends a turn, or a proactive
  row), which announces the row to the live sockets and starts the row's push
  task;
- one push task per row: its one wait, its decision, its attempts at the
  dispatcher, and the write of the profile's push cursor
  (`push_attempted_seq`);
- the `DeviceRegistry` and each device's socket, which carries the phone's
  `ack`;
- the push platform, the service a phone is pushed through, which holds what
  it accepted;
- each phone's app: it takes rows off its socket, announces them, and handles
  a push;
- the owner, who opens, leaves and navigates the app, and may read the reply
  on the Mac;
- the faults: an app frozen with its socket open, a dispatcher call that
  fails or whose answer is lost, and a daemon crash.

The SOURCE pins name the code the design replaces: `Mobile.Push`, the push
scheduling in `Channels.Mobile`, the `DeviceRegistry`, the socket's `ack`
handler, the transport's idle timeout, and the attempts of a Web Push
phone's send (`Push.WebPushLeg`, `WebPush.send/4`). When stage D2 of M51 lands, those
files change, the spec goes STALE, and it is re-read against the
implementation. The phone app lives in another repository and has no pin. Its
rules are M51 §7, §8.2, §10 and §12.5.

Time is abstract. The task's one wait of 5 s is "the decision has not run
yet". The 2 s, 10 s and 30 s between attempts are "the next attempt has not
run yet".

**Bounds.** The one-row checks use two phones, one reply, two faults (freezes
and crashes) and three failing dispatcher calls, which is what it takes to
give a device up. One of the two phones is in `Idle`: its owner never opens
the app, so it only receives pushes. The two-row checks use one phone, two
replies, one fault and one failing call. Two replies on two phones do not fit
the one-minute bound (see "One more of each").

Every check keeps one phone outside `Idle`. The spec has no `Done` state,
because the owner of such a phone can always open or leave the app. For the
same reason deadlock checking finds nothing here by construction. A wedge
shows up as a broken `ChatAccounted` instead.

**Environment switches** (set per check):

| Switch | When `TRUE` |
|---|---|
| `SocketsCanFreeze` | The OS suspends an app with no clean close. The daemon keeps its socket registered until the 150 s idle timeout (`Session.idle_timeout_ms`, `session.ex:281`), which the WebSocket (`router.ex:53-60`) and the iroh bridge connection (`bridge_connection.ex:233-241`) both apply. |
| `DispatchCanFail` | A dispatcher call returns a transient error. |
| `AnswerCanBeLost` | The platform accepted a push and the daemon saw a timeout instead. |
| `DaemonCanCrash` | The daemon dies with push tasks in flight, and boots again. |
| `OwnerReadsElsewhere` | The owner reads the reply on the Mac. |

**Mechanism switches** (`TRUE` is the design; each is switched off by at least
one check):

| Switch | The design | Switched off |
|---|---|---|
| `DecidesOnEvidence` | D20: the decision reads the read frontier and each device's acked cursor. | **Today's code:** a phone whose socket is registered is not pushed, and the phones beside it are (`away_decision`, `push.ex:212-229`; `connected_devices`, `:567-579`). |
| `AcksAfterAnnounce` | The app acks a row once it has announced it: shown it on screen, or posted its notification. | The design's first draft: the app acks as soon as the row is persisted (PUSH-2). |
| `LocalNotify` | The app posts the notification itself for a row that arrives while its chat is off screen. | The row is only listed. |
| `NotifiedSet` | D22: the app announces an id once, whichever path brought it. | Every arrival alerts. |
| `RetriesTransient` | D21: a transient dispatcher error is retried. | **Today's code for an iPhone:** one APNs attempt, its failure logged (`notify_timeline_row`, `channels/mobile.ex:602-609`). A Web Push phone's send retries; see "What today's code does". |
| `AttemptCap` | D21: at most three attempts per device. | The retry has no bound. |
| `BootCheck` | D21: a boot step reads `push_attempted_seq` and decides once for the newest unread row above it. | **Today's code:** nothing runs at boot. |

**Design option** (`FALSE` is the design as written):

| Switch | When `TRUE` |
|---|---|
| `WatermarkCursor` | The cursor is the highest row below which every row concluded, and the boot step decides every row above it. See PUSH-1. |

## What holds

- Check 01, with every fault on, 194,363 states:
  - A phone alerts at most once for a reply (M51 §10, Lifecycle on the phone).
    This rests on `NotifiedSet` (check 02): a push whose answer was lost is
    sent again, and both arrive.
  - No device gets a fourth attempt (D21). This rests on `AttemptCap`
    (check 03).
  - The daemon gives a device up only after the third attempt (D21). This
    rests on `RetriesTransient` (check 04).
  - A device is skipped only on evidence: the owner read the row, or that
    phone holds it (D20). This rests on `DecidesOnEvidence` (check 05).
- Check 06, with every fault on, 194,363 states: a reply the owner has not
  read is in the end announced on every phone, held by the push platform for
  it, or given up with a logged failure (`ChatAccounted`). This rests on:
  - `DecidesOnEvidence` (check 07). With presence, a phone frozen before it
    announced the reply, its socket still registered when the decision
    runs, silences its own push, and nothing tells its owner until the app
    is opened.
  - `AcksAfterAnnounce` (check 08). See PUSH-2.
  - `LocalNotify` (check 09). A phone with the app open on another screen
    acks the row, so the daemon skips it. Only the app can tell its owner.
  - `BootCheck` (check 10). A crash between the decision and the attempt
    takes the task with it.
- Check 11, two replies on one phone with every fault on, 164,534 states:
  `ChatAccounted` still holds for the newest reply, although the cursor can
  pass an older row. This rests on `BootCheck` (check 12).
- Check 14, **hypothetical**, 160,783 states: with `WatermarkCursor` every
  unread reply is accounted for, not only the newest (`EveryRowAccounted`).
  This rests on `WatermarkCursor` (check 15). The design as written breaks the
  same rule in check 13 (PUSH-1).

`ChatAccounted` and `EveryRowAccounted` are liveness rules. They hold under
weak fairness on the push task's steps, the boot, the transport's idle
timeout and a running app's own work (its reconnect loop, taking and
announcing rows, its `ack` and its `read_state`). Nothing is assumed of the
writer, the owner, the OS, the push platform or the faults.

"Held by the push platform" is where the daemon's duty ends. Whether the push
service delivers a push it accepted is outside Fermix.

**Witnesses:**
- 16: a phone alerts for a reply the owner has already read. The decision ran
  before the read, and the phone had no socket to learn of it. The optional
  clearing push of M51 §11.7 is the design's answer.
- 17: a push is on its way to a phone that has already told its owner of that
  reply. The notified set hides it, but the push is still sent.
- 18: the decision marks a device for a push while its socket is registered,
  because the socket's `ack` has not reached the row. This is the case D20
  exists for.

**One more of each, run by hand** (no time limit, six workers): every holds
check still holds. Three replies, and a liveness check on three phones, were
not run.

| Check | Normal bound | One more | Result |
|---|---|---|---|
| 01 | 2 phones, 1 reply, 2 faults, 3 failing calls: 194,363 states | 3 phones, 3 faults, 4 failing calls | holds, 104,294,429 states |
| 01 | the same | 2 replies on 2 phones | holds, 96,883,165 states |
| 06 | 2 phones, 1 reply, 2 faults, 3 failing calls: 194,363 states | 3 faults, 4 failing calls | holds, 508,057 states |
| 11 | 1 phone, 2 replies, 1 fault, 1 failing call: 164,534 states | 2 faults, 2 failing calls | holds, 1,001,085 states |
| 11 | the same | 2 phones, one of them idle | holds, 2,754,581 states |
| 14 | 1 phone, 2 replies, 1 fault, 1 failing call: 160,783 states | 2 faults, 2 failing calls | holds, 834,106 states |

## What today's code does

Three mechanism switches are today's code when switched off. Their checks are
therefore also the statement of what today's code gets wrong:
- **Presence** (`DecidesOnEvidence`, checks 05 and 07). A phone whose socket
  is registered when the decision runs is not pushed, though it may not have
  announced the reply: frozen before it did, or gone before it took the row
  off its socket (M51 R18). Since `81b3fc25` the phone silences only
  itself, and the phones beside it are pushed.
- **One attempt** (`RetriesTransient`, check 04), for an iPhone. A transient
  APNs error ends the push (M51 R19). A Web Push phone's one send
  (`WebPush.send/4`) tries a 429, a 5xx or a transport error again, at most
  three attempts within a minute of its first: the retry and the cap of
  D21, inside one call. A `Retry-After` that would pass the minute ends it
  sooner, which `GivesUpOnlyAfterThree` does not allow; the spec has no
  clock, and does not model that bound.
- **Nothing at boot** (`BootCheck`, checks 10 and 12). A crash inside the
  task's wait or between attempts loses the push (M51 R19).

Re-read on 2026-09-29 after the phone backend fix (`6d1f802f`), which changed
none of the three. What it changed around them:
- The fan-out to the sockets is `DeviceRegistry.broadcast`, a cast. The row's
  write, its announcement and the start of its task keep their order.
- A reply's push is scheduled where its request settles: `build_turn_result`
  for a request that became a turn, `Mobile.EventRouter.schedule_settled_push`
  for one that did not. A request settles on one of the two paths, so a row
  has one task.
- A proactive row is pushed only while the phone subtree runs
  (`delivered_effects`, `phone_effects` until 5e9ec545). The spec models the
  channel switched on. Since 5e9ec545 the same function previews the row's
  links whether or not the subtree runs (`LinkPreviews`), which no push rule
  reads, so nothing the spec models changed.
- An approval is now pushed too, with no content, in one attempt, and
  suppressed while any device of the profile has a socket
  (`push.ex:133-151`). The spec does not model approvals (see "Not
  modelled"); presence is wrong for them for the same reason as for a reply.

Today's app-side rules are the iOS app's and are not pinned here.

Re-read on 2026-10-17 against M60 (cues and watchers, not yet committed on
`release/0.17.0`), which staled the `mobile.ex` pin: `delivered_effects`
(`channels/mobile.ex:517-522`) skips the link-preview fetch when a send
passes `link_previews: false` (a cue run's message, M60 §9.5,
`schedule_previews`, `:503-506`). The push launch beside it is unchanged, and
no push rule reads a preview, so nothing the spec models changed. Re-read
again on 2026-10-23 for the commit of M60 (on dev `b0246d74`): that is the
only change to the pinned functions, and the comments' `mobile.ex` numbers
(13 lines low past `build_turn_result` after the move onto dev) now point at
the committed file.

Re-read on 2026-10-24 for Android push through FCM (M51 §10, on dev
`a8c399b4`), which staled the `push.ex` and `session.ex` pins and moved the
`mobile.ex` numbers. Each registered device is now pushed through its own
platform's service (APNs or FCM), which is the abstract push platform the
spec already has; an approval's push carries its id and expiry; and a phone's
`push_unregister` clears its token, so the phone is no longer registered. The
decision is unchanged (any socket of the profile suppresses the push, then the
read frontier, then one attempt per row, nothing at boot), so nothing the
spec models changed; the comments' line numbers now point at the new file.

Re-read on 2026-10-25 for the removal of direct FCM push (`dc3025a0`),
which staled the `push.ex` pin and moved the `mobile.ex` numbers. Fermix
pushes through APNs alone: an iPhone, or a phone paired before pairing
recorded a platform, is pushed as before, and an Android phone is refused by
name with a typed reason in the log before any attempt, never sent through
APNs. An approval's push carries no id or expiry again. The spec does not
model a device's platform: its devices are the phones a push service reaches.
Since `dbf03a86`, push settings that do not resolve start the channel
without the dispatcher instead of refusing its boot, which is push turned off
and also outside the spec. The decision is unchanged (any socket of the
profile suppresses the push, then the read frontier, then one attempt per row,
nothing at boot), so nothing the spec models changed; the comments' line
numbers now point at the new file.

Re-read on 2026-10-25 for `push_register`'s return to the shape engine 0.16.0
shipped, `{apns_token, environment}` (M82 D16), which staled the `session.ex`
pin. `dispatch_event` stores any phone's `apns_token` once its environment
matches the configured APNs one, as 0.16.0 did, and no longer checks the
phone's platform; Push still refuses an Android phone by name before any
attempt. The spec models neither registration nor a phone's platform: a
device is registered throughout, and its `platform` is the push service. The
`ack` clause, `terminate` and `idle_timeout_ms` are unchanged, so nothing the
spec models changed; the comments' `session.ex` numbers, which had drifted
since `e6042f1f`, now point at the committed file.

Re-read on 2026-11-02 for a reply's time, which staled the `mobile.ex` pin:
`delivered_text` and `seal_draft` hand `Output.text_done` the row the write
returned rather than its `server_seq`, so a phone's `text_done` carries the
row's time as `ts`. The event, its row and the push decisions after it are
as before, so nothing the spec models changed, and no line the spec cites
moved.

Re-read on 2026-11-09 for a phone's list channel (M85 E4), which staled the
`mobile.ex` pin: `delivered_text` passes `Output.text_done` the reply's
blocks, which a turn's reply now takes from its tools' list and place records
before its row is written, as a Mac turn's does. The row, its event, the
sockets it reaches and the push decisions after it are as before, so nothing
the spec models changed. The comments' `mobile.ex` and `session.ex` numbers,
which had drifted since the phone's call, now point at the committed files.

Re-read on 2026-11-13 for phone-by-phone push and Web Push (M99,
`81b3fc25`), which staled the `push.ex` and `session.ex` pins. What it
changed, and what that does to the model:
- **The decision is per phone.** `Mobile.Push.notify` (`push.ex:161-180`)
  leaves out each phone `DeviceRegistry` lists as connected for the profile
  (`away_decision`, `:212-221`); with none left nobody is pushed
  (`decide_away`, `:226`), else the read frontier decides for every phone
  (`read_decision`, `:231-240`), else each phone left out is pushed. Before,
  one socket of the profile silenced every phone. That is the step
  `Decision` takes with `DecidesOnEvidence` off, and it now says so. The
  design's branch is unchanged, so every `holds` check, witness and PUSH-1
  keep their verdicts and state counts, and no expectation moved. Checks 05
  and 07 still break their rules, 05 at the decision itself (5 states: the
  phone in the owner's hand marked `presence`, the idle phone `pending`),
  07 by another path. The idle phone is now pushed, and the reply is lost
  instead on the phone in the owner's hand: it took the row as it connected
  and froze before it announced it, its socket still registered when the
  decision ran, so it was left out, and nothing tells its owner until the
  app is opened. That is M51 R18 narrowed to the phone itself, not a new
  finding.
- **Two routes, one platform.** Each phone left out has one route, by what
  it registered: Web Push for a phone holding a subscription
  (`Push.WebPushLeg`, one `WebPush.send/4` each, the phones sent beside one
  another), APNs for an iPhone holding only a token, and a refusal by name
  for any other; the APNs config, off or broken, stops the APNs route
  alone. The spec does not model a phone's route: the push platform is
  whichever service the route reaches, and it holds what it accepted
  (`atPlatform`), a row's push for a day (the TTL, not modelled). An iPhone
  still gets one attempt. A Web Push phone's send retries (What today's code
  does): `RetriesTransient` and `AttemptCap` for that route, inside one
  call, lost with the daemon as any task is (`BootCheck` off). Its
  one-minute bound is a clock the spec does not have.
- **Registration.** `dispatch_event`'s `push_register` and `push_unregister`
  now write a phone's whole registration, and the new `push_subscribe`
  writes a Web Push subscription; a Web Push service that calls a
  subscription gone, or refuses this home's key, has it cleared until the
  phone next connects. The spec models no registration: a device is
  registered throughout. The `ack` clause, `terminate` and `idle_timeout_ms`
  are unchanged.
- **The pins** gain `push_web_push_leg.ex#deliver,send_all` and
  `web_push.ex#send,deliver,classify,settle,next_step,@max_attempts,@budget_ms`,
  the attempts the switch tables now cite for a Web Push phone. The
  comments' `push.ex` and `session.ex` numbers point at the commit, and so
  do the `mobile.ex`, `event_router.ex`, `device_registry.ex` and
  `bridge_connection.ex` ones, which no longer pointed at the code they
  name.

## What the spec changed in the design

- **The `ack` rule.** M51 §7 first said the app acks "as soon as the row is
  persisted locally". It now says: once the row is announced (PUSH-2).
- **The claimed rule is per chat.** M51 §10 now states `ChatAccounted` as the
  guarantee, and names PUSH-1 as what it leaves out (M51 §19 Q19).

## What the implementation must keep

Stage D2 is re-read against these, in the daemon:
- the decision reads the registry entry's acked cursor and the read frontier,
  never `DeviceRegistry.connected` alone;
- a socket that goes takes its acked cursor with it;
- the cursor is written after the attempts of a row conclude, never before;
- the boot step runs before the channel accepts a turn.

And in the app:
- `ack` follows the announcement;
- the notified set is read on every path that can alert: a socket row, a
  push, and a row loaded on connect;
- a row that arrives off screen is announced by the app itself.

## Findings

Both findings are about the design, not about code that runs today. Each was
found by the model checker and walked through the design text. To see a
counterexample, run `tla/bin/check.py mobile_push` and open
`tla/out/mobile_push/<check>.txt`. TLC's counterexample to a liveness rule is
not the shortest: several have the owner open and leave the app before it
connects. The paths below are the short ones.

### PUSH-1: a restart can lose the push of an older unread reply
- **Severity:** low. The owner is still told of the chat, and opening it shows
  every reply.
- **Status:** open. The owner decides (M51 §19 Q19). `EveryRowAccounted` is a
  proposed rule, so check 13 stays `violated PUSH-1` until then.
- **Checks:** 13 breaks `EveryRowAccounted`; 11 holds `ChatAccounted` in the
  same setup; 14 holds `EveryRowAccounted` with `WatermarkCursor`.
- **Two paths break the rule.** TLC reports one or the other, from one run to
  the next.
- **Counterexample, through the boot step:**
  1. Two replies are written while the phone is in a pocket. Both push tasks
     are in their wait.
  2. The daemon crashes. Both tasks are gone and the cursor is still 0.
  3. The boot step finds the newest row above the cursor and the read
     frontier, and starts one task, for reply 2.
  4. Reply 2 is pushed. Nothing is ever sent for reply 1.
- **Counterexample, through the cursor:**
  1. Two replies are written. Reply 1's task is still in its wait, or its
     first attempt failed and waits for its retry.
  2. Reply 2 is pushed and concludes. The cursor, a plain maximum, moves to 2.
  3. The daemon crashes. Reply 1's task is gone.
  4. The boot step finds nothing above the cursor.
- **Design text:** M51 §10, Retries and the restart gap: the cursor is
  "monotonic", and the boot step takes the "newest pushable row ... above both
  `push_attempted_seq` and `read_up_to_seq`".
- **Impact:** the phone shows one notification where two replies wait. With
  previews on, the owner reads the newer reply's first words and not the
  older one's. A scheduled job's report followed by an unrelated reply is the
  likely pair.
- **Choices:**
  - Keep the design and claim the rule per chat. This is the recommendation:
    one notification opens the chat, and the chat shows both replies.
  - `WatermarkCursor`: the cursor moves only past rows that concluded, and
    the boot step decides every row above it, bounded by the push TTL. It
    costs a per-row conclusion record, since a maximum no longer says which
    rows concluded.

### PUSH-2: an ack on persist silences a reply the owner never saw
- **Severity:** medium. The owner is never told of the reply on that phone,
  and with one phone is never told at all.
- **Status:** fixed in the design (2026-09-27). M51 §7 `ack` and onboarding
  gotcha 14 now say the app acks a row once it has announced it.
- **Checks:** 06 holds; 08 breaks `ChatAccounted` with the ack on persist.
- **Counterexample:**
  1. A reply is written. The app connects and persists the row.
  2. The app acks the row at once.
  3. The OS freezes the app before it has shown the row or posted its
     notification.
  4. The decision finds the row acked on that phone's socket, and skips the
     phone.
  5. The socket times out. Nothing is sent to that phone.
- **Why the window is real:** the freeze needs no bad luck. Android suspends
  a backgrounded process inside the app's 5 s grace, and a row that arrives
  in that grace is persisted by the socket's reader before the notification
  is posted.
- **Cost of the fix:** an ack that waits for the announcement arrives later,
  so a slow phone is pushed although it holds the row. The notified set hides
  that push (witness 17).

## Not modelled

- **Approvals and failed turns.** They carry no `server_seq`, go to every
  registered device at once through the same attempts, and the phone
  deduplicates them by id in the same notified set. What is theirs alone (no
  retry past `expires_at`, a late approval shown as expired) is a single-call
  rule.
- **Registration:** `push_register`, `push_subscribe` and `push_unregister`,
  each a phone's whole registration; `UNREGISTERED` / `NOT_FOUND` and a Web
  Push service's gone or refused key, terminal before any retry, the last
  two clearing the phone's registration until it next connects; and a
  device with no token. A device is registered throughout.
- **A phone's route:** Web Push for a phone holding a subscription, APNs
  for an iPhone holding a token, a refusal by name for any other. The push
  platform is whichever service the route reaches. Push turned off, and the
  APNs config, which stops the APNs route alone, are outside the spec.
- **The push TTL (24 h)** and the boot check's "younger than the TTL".
- **The plaintext, its padding and the encryption.** These are single-call
  rules, pinned by `push_vectors.json`.
- **Rows that are not pushable:** the owner's own messages, and the sealed
  bubbles before the last one.
- **History paging.** A connecting phone receives every row at once.
- **What a turn is, and the Queue** (`turn_queue`, `companion_session`).
- **More than one profile.** The cursor, the read frontier and the decision
  are per profile.

## Assumptions

- **Folded steps.** Three steps fold calls together, and each says why in the
  spec:
  - `WriteRow` is the row's write, its announcement to the sockets and the
    start of its task. A crash between them leaves what a crash right after
    them leaves: a durable row with no task.
  - `Decide` is the read of the frontier and the read of the registry. Both
    values only grow while a socket lives, and a read that lands after the
    decision is witness 16.
  - `Boot` is two Repo reads and the task starts. Nothing else runs on the
    channel before it.
- **An ack lost on the way is an ack sent late.** The app's send and the
  daemon's handling are one step, and the app may ack at any moment.
- **A clean close announces first.** `Leave` requires that the app has
  announced what it took. Persisting and announcing a row takes milliseconds
  and the background grace is 5 s. A freeze has no such guard.
- **A push wakes the app.** `PushArrives` can happen whatever the app is
  doing. A push the platform never delivers is one that stays there.
- **A phone knows the read frontier only while it has a socket.** Away from
  it, a push for a row read elsewhere alerts (witness 16).
