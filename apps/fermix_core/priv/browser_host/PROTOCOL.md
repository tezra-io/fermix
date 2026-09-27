# Fermix browser host protocol

The wire contract between the Fermix daemon and the Fermix app's own browser
pane, the macOS app first.

**Source of truth:** `FermixCore.BrowserHost.Protocol`
(`lib/fermix_core/browser_host/protocol.ex`). This file, `protocol.schema.json`,
and `fixtures/*.jsonl` are the machine-readable export of that module.
`protocol_contract_test.exs` asserts they never drift from it. A downstream
consumer (`fermix-macos`) **vendors the schema and fixtures pinned by
checksum** rather than hand-copying the shapes.

**Direction is reversed from the other local wires.** On `daemon.sock`,
`realtime.sock` and `companion.sock` the daemon answers a client. Here the
Fermix app is the client that opens the socket, and once it has attached as
the host the **daemon is the one asking**: it sends requests carrying an `id`,
the app answers each with `ok` or `error`, and the app sends its own news as
events that carry no `id`.

## Transport

- **Socket:** a Unix-domain stream socket at `$FERMIX_HOME/browser_host.sock`,
  mode `0600`, owned by the daemon. It is served whenever the daemon runs; no
  setting or feature flag turns it on. A socket the daemon cannot bind is
  logged and skipped, and the daemon runs on with every `fermix` task routed
  to managed Chrome.
- **Trust:** the socket's owner is the daemon's user, but a host must also be
  a process the daemon did not itself start (an agent's own shell command
  could otherwise answer pages of its own making). The daemon asks the kernel
  which process connected before reading a line; a connection it cannot place
  as independent of itself is refused with `error: untrusted_host` and closed.
- **Framing:** newline-delimited JSON. Each frame is one JSON object followed
  by a single `\n`, with a `type` discriminator (a response instead carries
  `id` and no `type`). A line from the app longer than **4,194,304 bytes** is
  refused with `error: line_too_large` and the connection is closed; a
  snapshot's node list is the largest frame the app sends, and this bound
  holds whatever it sends. Daemon-to-app lines are not capped.
- **One host at a time.** A second client while a connection is attached is
  answered `error: host_already_attached` and closed; the daemon never queues
  a second host or picks between them.
- **Absent is absent:** an optional field with no value is an absent key,
  never an explicit `null`; a payload carrying an explicit `null` for any
  field is refused. Unknown top-level fields on a daemon frame are never sent
  in the first place — this module is the frame's only writer.

## Versioning

The protocol is versioned by a single integer, `protocol_version`. The daemon
advertises the inclusive range `{min_version, max_version}` it accepts, an
**N/N-1 window**: `max_version` is the current version and `min_version` the
previous one (or the same value while only one version exists — version 1's
window is 1 to 1).

| Field | Value |
|---|---|
| `protocol_version` (the app declares) | `1` |
| daemon `min_version` | `1` |
| daemon `max_version` | `1` |

## Handshake and attach

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
app -> daemon:  attached { host_version, profile_id }
                daemon: this connection is now the host (HostAvailability.attached/3)
app -> daemon:  availability { available: true }  (or false, with reason)
daemon -> app:  tab.open { id: 1, task_id, url, observe, download_dir, task_tab_cap, tab_cap }
app -> daemon:  { id: 1, ok: true, result: { tab_id, url, title } }
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
8. It sends `availability` right after attaching and again on every change
   (the Mac locked or unlocked, the display slept or woke, the app is about
   to quit), never in answer to a poll: the daemon never asks for one.

`error(unsupported_protocol_version)` carries `direction` (`client_too_old`:
update the app; `client_too_new`: update Fermix), `client_version`,
`min_version`, and `max_version`.

## Requests (daemon → app)

Every request carries `id` (a positive integer, unique per connection, never
reused) and `type`; the app answers each with `{id, ok: true, result}` or
`{id, ok: false, error: {reason, message}}}`, in the order the daemon sent
them or any order it chooses to answer in — the daemon matches by `id`, not by
arrival order. `task_id` and `tab_id` are opaque strings the app never
interprets. A request whose `observe` is `true` carries a `snapshot` object
(`mode`, `max_chars`, `depth`) naming the look the app takes at the page right
after the request completes; `observe: false` carries no `snapshot`.

| `type` | Fields | Result | Notes |
|---|---|---|---|
| `tab.open` | `task_id`, `url`, `observe`, `download_dir`, `task_tab_cap`, `tab_cap`; `snapshot?` | `tab_id`, `url`, `title`; `page?` | Opens a tab owned by `task_id`. Refused with `cap_reached` past either cap. |
| `tab.navigate` | `tab_id`, `url`, `observe`; `snapshot?` | `tab_id`, `url`, `title`; `page?` | Navigates a tab the task already owns. |
| `tab.list` | `task_id` | `tabs[]` | Every tab `task_id` owns, popups included. |
| `tab.focus` | `tab_id` | `tab_id`, `url`, `title` | Refused with `not_owner` on the person's tab. |
| `tab.close` | `tab_id` | `tab_id` | Closes one tab the task owns. |
| `task.release` | `task_id` | `released[]` | Closes every tab `task_id` owns. Idempotent: a second release for the same task answers `released: []`. |
| `page.snapshot` | `tab_id`, `mode`, `max_chars`, `depth` | `url`, `title`, `ready_state`, `nodes[]` | The accessibility node list `browser/snapshot.ex` renders. |
| `page.screenshot` | `tab_id`, `full_page`, `path` | `path`, `mime_type`, `bytes`, `url`, `device_pixel_ratio` | The app writes exactly to `path`, inside the engine's workspace. |
| `page.pdf` | `tab_id`, `path` | `path`, `mime_type`, `bytes`, `url` | Same placement rule as `page.screenshot`. |
| `page.act` | `tab_id`, `kind`, `observe`; `ref?`, `x?`, `y?`, `text?`, `key?`, `fields?`, `field?`, `selector?`, `wait_until?`, `timeout_ms?`, `snapshot?` | `url`, `title`; `value?`, `page?` | One of the ten `act` kinds below. |
| `page.upload` | `tab_id`, `ref`, `path` | `tab_id` | Puts the file at `path` (inside the workspace) into the file input `ref` names. |
| `dialog.resolve` | `tab_id`, `accept`; `text?` | `tab_id` | Clears a `dialog.opened` on `tab_id`. Refused with `no_dialog` if none is open. |
| `cookies.get` | `tab_id` | `url`, `cookies[]` | Metadata only; the app never sends a cookie's value. |
| `cookies.clear` | `tab_id` | `cleared` | Count of cookies removed for the tab's page. |
| `host.status` | — | `host_version`, `profile_id`, `available`, `task_tabs`, `person_tabs` | A snapshot of the host's own counters. |
| `host.stop_ack` | — | `{}` | The daemon's answer to the app's `host_stopping`, sent behind every `task.release` the daemon issued for it. |

`page.act`'s `kind` is one of: `click`, `fill`, `fill_form`, `type`, `submit`,
`press`, `hover`, `get`, `wait`, `click_coords`. `click`, `hover` and `submit`
take `ref`; `fill` and `type` take `ref` and `text`; `fill_form` takes
`fields[]` (each `{ref, text}`, at most 12); `press` takes `key`;
`click_coords` takes `x` and `y`; `get` takes an optional `field` (`text`,
`title`, `html`, `count`, `ready_state`, `rect`) and `selector`; `wait` takes
`wait_until` (`text`, `url`, `element`, `load`), `timeout_ms`, and the target
the mode names (`text` for `text`/`url`, `ref` or `selector` for `element`).

A navigation or an act's result carries `page: "changed"` with a fresh
`snapshot` when the app judges the page restructured, `page: "unchanged"`
when an identical look was taken and found no different text, or no `page`
key when `observe` was `false`.

## Events (app → daemon)

An event carries `type` and no `id`. `attached` and `availability` are
consumed by the daemon before any request is sent (see *Handshake and
attach*); the rest inform whichever tasks own the tab or download named.

| `type` | Fields | Notes |
|---|---|---|
| `attached` | `host_version`, `profile_id` | Ends the attach step. |
| `availability` | `available`; `reason?` (required when `available` is `false`) | The pane's readiness. Sent at attach and on every change. |
| `tab.closed` | `tab_id`, `by` (`task`, `person`, `page`, `host`) | A tab left the app's list, however it closed. |
| `dialog.opened` | `tab_id`, `kind` (`alert`, `confirm`, `prompt`, `beforeunload`), `message`; `default?` | Blocks further `page.act` on that tab until `dialog.resolve`. |
| `download.began` | `download_id`, `tab_id`, `filename` | A download started on a task's tab. |
| `download.progress` | `download_id`, `received_bytes`; `total_bytes?` | Progress of one download. |
| `download.finished` | `download_id`, `tab_id`, `state` (`completed`, `failed`, `cancelled`); `path?`, `bytes?`, `reason?` | Terminal. `path` is set only on `completed`, and only inside the engine's downloads directory. |
| `task.cancel` | `task_id`, `reason` | The person cancelled `task_id` from its own tab in the app. See *A cancel mid-task*. |
| `host_stopping` | — | The app is quitting. Final for this connection: see *Quit mid-task*. |

## Errors

**Host errors** answer a request (`{id, ok: false, error: {reason, message}}`)
and never close the connection by themselves.

| `reason` | Context | Ends the task? |
|---|---|---|
| `tab_not_found` | the named `tab_id` is not open | no — the request fails |
| `cap_reached` | `tab.open`/a popup past the task's or the global tab cap | no |
| `not_owner` | the tab belongs to the person, not the task | no |
| `navigation_refused` | the app itself refuses the address (e.g. a scheme it never opens) | no |
| `act_failed` | the element has no box, is disabled, or the action otherwise could not run | no |
| `stale_ref` | the ref names no element on the page as it now is | no |
| `dialog_blocked` | a JavaScript dialog is open on the tab | no |
| `no_dialog` | `dialog.resolve` with nothing open | no |
| `wait_timeout` | a `wait` act's condition never became true | no |
| `write_failed` | the app could not write a screenshot or PDF to `path` | no |
| `upload_failed` | the ref is not a file input, or the OS refused the write | no |
| `invalid_request` | the request's fields do not fit its `kind` (e.g. `fill_form` naming an unknown ref) | no |
| `host_unavailable` | the pane cannot take work right now | **yes** — `HostServer` reaps the profile with `host_lost` |

**Daemon errors** are the daemon's own `error` frame; every one closes the
connection, which fails every task bound to it.

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

### A task on the host

```
app -> daemon:  client_hello { protocol_version: 1 }
daemon -> app:  server_hello { min_version: 1, max_version: 1 }
app -> daemon:  attached { host_version: "0.2.0", profile_id: "fermix-web-3c9a" }
app -> daemon:  availability { available: true }
daemon -> app:  { id: 1, type: "tab.open", task_id: "task-1", url, observe: true, snapshot, download_dir, task_tab_cap, tab_cap }
app -> daemon:  { id: 1, ok: true, result: { tab_id: "t1", url, title, page: { ... } } }
daemon -> app:  { id: 2, type: "page.act", tab_id: "t1", kind: "click", ref: 13, observe: true, snapshot }
app -> daemon:  { id: 2, ok: true, result: { url, title, page: "changed", snapshot, truncated } }
daemon -> app:  { id: 3, type: "task.release", task_id: "task-1" }
app -> daemon:  { id: 3, ok: true, result: { released: ["t1"] } }
```

### A lock mid-task

The task's decision to run on the host is made once, at its start, from the
last availability report (`FermixCore.Browser.HostAvailability`); a report
that arrives while a request is already out does not pre-empt it, and the
next request the task makes is the one that meets the loss.

```
daemon -> app:  { id: 4, type: "tab.open", task_id: "task-2", ... }
app -> daemon:  { id: 4, ok: true, result: { tab_id: "t2", ... } }
app -> daemon:  availability { available: false, reason: "the Mac is locked" }
daemon:         HostAvailability records the report; task-2's tab stays open
daemon -> app:  { id: 5, type: "page.act", tab_id: "t2", kind: "click", ref: 4, observe: false }
app -> daemon:  { id: 5, ok: false, error: { reason: "host_unavailable", message: "the Mac is locked" } }
daemon:         HostServer reaps task-2 with host_lost("... the Mac is locked."),
                marks its turn (TurnMarker) so the turn's later browser calls
                answer the same sentence instead of running on Chrome
```

### A cancel mid-task

The pane itself stays available; only the one named task ends, from the
person's own act on its tab. `task.release` for it travels behind its own
queued requests, exactly as in *Quit mid-task*, but no other task on the
connection is touched.

```
daemon -> app:  { id: 6, type: "page.act", tab_id: "t4", kind: "fill", ref: 2, text: "…", observe: false }
app -> daemon:  task.cancel { task_id: "task-4", reason: "cancelled by the person" }
daemon:         tells task-4 it was cancelled (its in-flight request, if any,
                fails with it) and writes its task.release behind that request
daemon -> app:  { id: 7, type: "task.release", task_id: "task-4" }
app -> daemon:  { id: 7, ok: true, result: { released: ["t4"] } }
daemon:         HostServer reaps task-4 with cancelled("The person cancelled
                the browser task in the Fermix app."), marks its turn
                (TurnMarker) so the turn's later browser calls answer the
                same sentence instead of running on Chrome
```

### Quit mid-task

`task.release` for every task bound to this connection is written **behind**
each task's own queued requests — both leave the one connection process in
order — so a release can never overtake a `tab.open` still in flight
(finding BROWSER-1). The app answers `host.stop_ack` only after every release
it was sent, and holds its quit for that answer or its own bound, whichever
comes first.

```
daemon -> app:  { id: 6, type: "page.act", tab_id: "t3", kind: "fill", ref: 9, text: "…", observe: false }
app -> daemon:  availability { available: false, reason: "the app is quitting" }
app -> daemon:  host_stopping
daemon:         for every task bound to this connection: fail it with a
                sentence, then write its task.release behind its own queued
                requests (never ahead of them)
daemon -> app:  { id: 7, type: "task.release", task_id: "task-3" }
app -> daemon:  { id: 7, ok: true, result: { released: ["t3"] } }
daemon -> app:  { id: 8, type: "host.stop_ack" }
app -> daemon:  { id: 8, ok: true, result: {} }
                (the app's quit hold ends here, or at its own bound if this
                answer is lost)
daemon:         HostAvailability.stopping/2 is final for this connection: a
                later availability report on it never reopens the host
```

### Launch on demand

```
task:           a `fermix` task starts; no host is attached
daemon:         HostAvailability shows listening, not attached; launch_app is
                on, and no launch is pending or cooling down
daemon:         HostLauncher.launch/1 runs `open -g -j -b <bundle id> --args --background`
                and records the deadline (HostAvailability.launching/2) before
                the app can possibly attach
app -> daemon:  connect socket
app -> daemon:  client_hello { protocol_version: 1 }
daemon -> app:  server_hello { min_version: 1, max_version: 1 }
app -> daemon:  attached { host_version, profile_id }
app -> daemon:  availability { available: true }
daemon:         the waiting task is decided :fermix_app
```

If the app never attaches before the deadline, the task runs on managed
Chrome and the deadline's moment is remembered: a task that starts within
`host_launch_cooldown_ms` after it runs on Chrome without opening the app
again, since a launch that crashed before it attached looks identical to one
still coming up.
