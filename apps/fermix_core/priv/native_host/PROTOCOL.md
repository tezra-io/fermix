# Fermix native host protocol

The wire contract between the Fermix daemon and the Fermix app, over which the
app serves the daemon this Mac's own services: notifications first.

**Source of truth:** `FermixCore.NativeHost.Protocol`
(`lib/fermix_core/native_host/protocol.ex`). This file, `protocol.schema.json`,
and `fixtures/*.jsonl` are the machine-readable export of that module.
`protocol_contract_test.exs` asserts they never drift from it. A downstream
consumer (`fermix-macos`) **vendors the schema and fixtures pinned by
checksum** rather than hand-copying the shapes.

It is the browser host's grammar (`priv/browser_host/PROTOCOL.md`) for a
different concept. The browser host wire is the app's browser pane, and its
`availability` is the pane's readiness; this wire is the app's grants and
the services they open, and it has no tasks and no tabs. The two share the
transport, the trust check and the one app launcher, and nothing else.

**Direction is reversed from the other local wires**, as on the browser host
wire. The Fermix app is the client that opens the socket, and once it has
attached as the host the **daemon is the one asking**: it sends requests
carrying an `id`, the app answers each with `ok` or `error`, and the app sends
its own news as events that carry no `id`.

## Transport

- **Socket:** a Unix-domain stream socket at `$FERMIX_HOME/native_host.sock`,
  mode `0600`, owned by the daemon. It is served only by the Fermix app's own
  engine on a Mac (`Native.Provider` is `:mac_app`). A standalone or source
  engine on a Mac serves nothing an app could attach to, and a Linux engine
  reaches the session bus itself. No setting or feature flag turns it on. A
  socket the daemon cannot bind is logged and skipped, and the daemon runs on
  with nothing ringing on this Mac.
- **Trust:** the socket's owner is the daemon's user, but a host must also be
  a process the daemon did not itself start (an agent's own shell command
  could otherwise answer as the app). The daemon asks the kernel which process
  connected before reading a line; a connection it cannot place as
  independent of itself is refused with `error: untrusted_host` and closed.
- **Framing:** newline-delimited JSON. Each frame is one JSON object followed
  by a single `\n`, with a `type` discriminator (a response instead carries
  `id` and no `type`). A line from the app longer than **4,194,304 bytes** is
  refused with `error: line_too_large` and the connection is closed: the
  browser host's bound, kept so one transport rule holds on both of the app's
  wires. Daemon-to-app lines are not capped.
- **One host at a time.** A second client while a connection is attached is
  answered `error: host_already_attached` and closed; the daemon never queues
  a second host or picks between them.
- **Absent is absent:** an optional field with no value is an absent key,
  never an explicit `null`; a payload carrying an explicit `null` for any
  field is refused. Unknown top-level fields on a daemon frame are never sent
  in the first place: this module is the frame's only writer.

## Versioning

The protocol is versioned by a single integer, `protocol_version`. The daemon
advertises the inclusive range `{min_version, max_version}` it accepts, an
**N/N-1 window**: `max_version` is the current version and `min_version` the
previous one (or the same value while only one version exists; version 1's
window is 1 to 1). The engine manifest lists the window under
`protocols.native_host`.

| Field | Value |
|---|---|
| `protocol_version` (the app declares) | `1` |
| daemon `min_version` | `1` |
| daemon `max_version` | `1` |

A later version adds request families (calendar, reminders, contacts) and a
`capabilities` field per family, each marked `x-since-version` in the schema,
so an app attached on an older version is sent nothing it cannot answer.

## Handshake, attach and capabilities

The connection opens with a **mandatory, one-shot handshake**, then a
**mandatory, one-shot attach**. No request is sent and no other event is
serviced until both complete.

```
app: connect socket
app -> daemon:  client_hello { protocol_version: P }
                daemon negotiates P against {min, max}:
                  P in [min, max] -> daemon -> app: server_hello { min_version, max_version }
                  P < min         -> error(unsupported_protocol_version, client_too_old); close
                  P > max         -> error(unsupported_protocol_version, client_too_new); close
app -> daemon:  attached { host_version }
                daemon: this connection is now the host (Native.HostAvailability.attached/4)
app -> daemon:  capabilities { notifications: "granted" }  (or "not_granted", "not_asked")
daemon -> app:  notifications.post { id: 1, reminder_id, title, body, sound, actions }
app -> daemon:  { id: 1, ok: true, result: { notification_id } }
```

Rules the daemon enforces:

1. Any frame other than `client_hello` received **before** a successful
   handshake is rejected with `error: handshake_required` and closed.
2. A second `client_hello` is rejected with `error: unexpected_client_hello`
   and closed.
3. Any frame other than `attached` received after the handshake but **before**
   the app has attached is rejected with `error: attach_required` and closed.
4. A second `attached` on an already-attached connection is rejected with
   `error: unexpected_attached` and closed.
5. A `client_hello` without a positive integer `protocol_version` is rejected
   with `error: missing_field` (`field: "protocol_version"`).
6. A connection while one host is already attached is rejected with
   `error: host_already_attached` and closed, before the handshake is even
   read.

Rules the app enforces:

7. It is not the host until it has sent `attached` and read no `error` back.
8. It sends `capabilities` right after attaching and again on every change
   (after the person answers a prompt, when the app becomes active, since a
   grant can change in System Settings while it is in the background), never
   in answer to a poll. It reads the grant from the framework itself; it
   never decides whether Fermix may ring.

`error(unsupported_protocol_version)` carries `direction` (`client_too_old`:
update the app; `client_too_new`: update Fermix), `client_version`,
`min_version`, and `max_version`.

## Requests (daemon → app)

Every request carries `id` (a positive integer, unique per connection, never
reused) and `type`; the app answers each with `{id, ok: true, result}` or
`{id, ok: false, error: {reason, message}}`, in any order: the daemon matches
by `id`, not by arrival order. A grant state is one of `granted`,
`not_granted` and `not_asked`.

| `type` | Fields | Result | Notes |
|---|---|---|---|
| `notifications.authorize` | — | `state` | Raises the macOS notification prompt when the state is `not_asked`, and answers the state after it; answers at once otherwise. Never raises the prompt twice. See *Prompts*. |
| `notifications.post` | `title`, `body`, `sound`, `actions`; `reminder_id?` | `notification_id` | Shows one notification. Refused `not_authorized` unless the state is `granted`, and `post_failed` with the framework's own words when the framework refuses it. It never raises the prompt. `actions` is at most 2 buttons, each `{id, title}`; a post that offers one carries the `reminder_id` the press names. |
| `host.status` | — | `host_version`, `notifications` | A snapshot of the host's own state, raising no prompt. |
| `host.stop_ack` | — | `{}` | The daemon's answer to the app's `host_stopping`. |

`actions[].id` is one of: `snooze_10m`. `title` is the button's words, which
the app shows as given. `body` is the reminder's whole text as the engine
rendered it (at most 1,800 characters), and `title` the event's title (at most
256); the app adds nothing to either.

### Prompts

The daemon raises the notification prompt only for a turn from
**this computer's own surfaces**: the Mac chat, `fermix ask`, an editor over
ACP, or a voice call (`Native.local_surface?/1`). A turn from anywhere else (a chat
channel, the phone) sends `host.status` and never prompts: a prompt on a Mac
nobody is at would wait unanswered, and a withheld grant is the owner's own
answer. `notifications.authorize` is bounded: on the daemon's deadline it
stops waiting and refuses with the sentence that names where to grant, the
macOS prompt stays up, and the person's answer arrives later as
`capabilities`. `notifications.post` never raises the prompt: a grant that is
missing or revoked after a reminder was stored answers `not_authorized`,
which the daemon records as a permanent failure of that delivery. Nothing
stands in for a missing grant.

## Events (app → daemon)

An event carries `type` and no `id`. `attached` and the first
`capabilities` are consumed by the daemon before any request is sent (see
*Handshake, attach and capabilities*).

| `type` | Fields | Notes |
|---|---|---|
| `attached` | `host_version` | Ends the attach step. |
| `capabilities` | `notifications` | The app's grants. Sent at attach and on every change. |
| `notification.action` | `reminder_id`, `action` | The person pressed `action` (`snooze_10m`) on the notification for `reminder_id`. The daemon snoozes that reminder ten minutes as the owner's own act, with no model turn; there is no answer on the wire. |
| `host_stopping` | — | The app is quitting. Final for this connection: see *Quit*. |

## Errors

**Host errors** answer a request (`{id, ok: false, error: {reason, message}}`)
and never close the connection by themselves.

| `reason` | Context | What the daemon does |
|---|---|---|
| `not_authorized` | `notifications.post` while the grant is not `granted` | the delivery fails permanently, and says so |
| `post_failed` | the framework refused the notification; `message` is its own words | the delivery fails permanently, with those words logged |
| `invalid_request` | the request's fields do not fit what the app can show | the delivery fails permanently |
| `host_unavailable` | the app cannot take the request right now (it is quitting) | the delivery is retried on the same target |

**Daemon errors** are the daemon's own `error` frame; every one closes the
connection.

| `reason` | Fields |
|---|---|
| `invalid_json` | — |
| `invalid_frame` | — |
| `missing_type` | — |
| `unknown_event` | `event` |
| `missing_field` | `field` |
| `invalid_field` | `field` |
| `line_too_large` | — |
| `handshake_required` | — |
| `unexpected_client_hello` | — |
| `attach_required` | — |
| `unexpected_attached` | — |
| `unsupported_protocol_version` | `direction`, `client_version`, `min_version`, `max_version` |
| `host_already_attached` | — |
| `untrusted_host` | `message` |

## Sequences

### A timer rings

```
app -> daemon:  client_hello { protocol_version: 1 }
daemon -> app:  server_hello { min_version: 1, max_version: 1 }
app -> daemon:  attached { host_version: "0.6.0" }
app -> daemon:  capabilities { notifications: "granted" }
                (ten minutes later the reminder is due)
daemon -> app:  { id: 1, type: "notifications.post", reminder_id: "rem_8Kf2xQ1vT0w",
                  title: "Tea", body: "Tea, today at 16:05 (in 10 minutes).", sound: true,
                  actions: [{ id: "snooze_10m", title: "Snooze 10 minutes" }] }
app -> daemon:  { id: 1, ok: true, result: { notification_id: "7E1A…" } }
app -> daemon:  notification.action { reminder_id: "rem_8Kf2xQ1vT0w", action: "snooze_10m" }
daemon:         snoozes the reminder ten minutes; it rings again at 16:15
```

### The grant, asked from the Mac chat

```
daemon:         a "remind me here in 10 minutes" from the Mac chat, a local surface
daemon -> app:  { id: 2, type: "notifications.authorize" }
                the app raises the macOS prompt; the person allows it
app -> daemon:  capabilities { notifications: "granted" }
app -> daemon:  { id: 2, ok: true, result: { state: "granted" } }
daemon:         the reminder is stored for this computer
```

If the person has not answered by the daemon's deadline, the daemon stops
waiting and the reminder is refused with the sentence that names where to
grant. The prompt stays up; the answer arrives as `capabilities`, and the
next ask finds the grant.

### The grant, asked from away

```
daemon:         "remind me on my Mac" from Telegram, which is not a local surface
daemon -> app:  { id: 3, type: "host.status" }
app -> daemon:  { id: 3, ok: true, result: { host_version: "0.6.0", notifications: "not_asked" } }
daemon:         refuses with "Fermix needs permission to show notifications on your Mac;
                next time you are at it, open Settings > Permissions > Notifications >
                Grant…"; no prompt is raised
```

### Launch on demand

```
daemon:         a reminder for this computer is due; no host is attached
daemon:         Native.HostAvailability shows listening, not attached, and no launch
                pending or cooling down
daemon:         AppLauncher.launch/1 runs `open -g -j -b <bundle id> --args --background`
                and records the deadline (Native.HostAvailability.launching/2) before the
                app can possibly attach
app -> daemon:  connect socket, client_hello, attached, capabilities
daemon -> app:  { id: 1, type: "notifications.post", … }
```

A due reminder needs no setting to open the app: storing it for this computer
was the owner's consent. If the app never attaches before the deadline, that
delivery attempt fails and is retried on the same target, and the deadline's
moment is remembered: an attempt within the cooldown after it fails at once
rather than opening the app again, since a launch that crashed before it
attached looks identical to one still coming up.

### Quit

```
app -> daemon:  host_stopping
daemon:         Native.HostAvailability.stopping/2 is final for this connection
daemon -> app:  { id: 4, type: "host.stop_ack" }
app -> daemon:  { id: 4, ok: true, result: {} }
                (the app's quit hold ends here, or at its own bound if this answer is lost)
```

A request the daemon sends after `host_stopping` is refused before it reaches
the wire, and the delivery is retried. Once the connection closes, the next
due reminder opens the app again.
