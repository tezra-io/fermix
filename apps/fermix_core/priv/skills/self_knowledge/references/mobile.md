# iPhone mobile companion

The mobile companion is a first-party, owner-only channel from an iPhone to the
operator's own Fermix daemon. The app lives in its own repository; Fermix is the
source of truth for the versioned wire contract. It is not a hosted chat service:
messages stay between the phone and the host, and a paired device enters the
gateway with operator role and trust.

**Availability: no phone app has been released.** The iPhone app has not
shipped, and an Android app is in design. Everything below is the daemon half,
which ships first so the apps can be built against a fixed wire. There is
nothing to install on a phone yet, so pairing has no counterpart until an app
ships in its own release. Tell an owner asking to use Fermix from their phone
exactly that, and point them at the channels that work today; never walk them
through installing an app or scanning.

**The channel is off by default and is managed over the management protocol.**
An absent `[fermix_channels.mobile]` section means disabled, not unconfigured.
The daemon publishes two things for it on its management socket:

- the `channels.mobile` settings section: the enable switch, the port, the
  address the listener binds (`0.0.0.0` for every network, or one address such
  as the Tailscale IP), and whether it announces itself over mDNS. Every row is
  boot-bound: a write lands in `config.toml` at once, but the listener starts
  or stops only when the daemon restarts. Until then the channel keeps doing
  what it did at boot: a channel turned on reports itself as not started, and
  one turned off keeps serving, pairing and revoking included;
- the `mobile.*` methods: `mobile.status`, the pairing session
  (`mobile.pair.start`, `mobile.pair.get`, `mobile.pair.decide`,
  `mobile.pair.cancel`), and the paired phones (`mobile.devices.list`,
  `mobile.devices.revoke`).

The desktop apps build their "Phone" pane on exactly these, and that pane ships
with the apps, not with the engine. On an app-managed Mac, enabling the channel
and pairing belong to the app, never the CLI. Until the pane ships, a dev or
Linux host pairs with `fermix pair`, which drives the same management methods,
and revokes with `fermix devices`; there, hand-editing `config.toml` is still a
valid way to turn the channel on:

```toml
[fermix_channels.mobile]
enabled = true
```

then restart the daemon (`fermix restart`). The terminal setup wizard and the
web setup have no mobile step or flag; never send an owner there for it.

**Only the owner pairs or forgets a phone.** The daemon takes
`mobile.pair.start`, `mobile.pair.decide`, `mobile.pair.cancel` and
`mobile.devices.revoke` only from a process it places as the owner's own (the
app, or a command typed in a terminal). One Fermix started itself (an agent's
shell command, a coding run, a scheduled job), a detached one, or one it cannot
place is refused with "Only the owner can pair or forget a phone; run this from
your own terminal." Reading the status, the pairing session and the phone list
stays open to any caller.

## Reachability and security

The app connects to the dedicated mobile listener over LAN/Bonjour or any
network shared by the phone and host, commonly a Tailscale tailnet. The default
listener is `wss://HOST:4031/ws`; `/healthz` is its only other HTTP route. The
regular setup endpoint and LiveView remain loopback-only.

TLS satisfies iOS transport requirements, but trust comes from an end-to-end
Noise session between device and gateway keys. A pinned certificate fingerprint
and gateway public key arrive through the pairing QR. There is no bearer token,
port-forwarding workflow, public Funnel, or hosted relay in the message path.
A planned iroh sidecar is a later addition, not part of today's setup and never
a second runtime fallback.

The listener is bounded against a peer that never finishes: at most 64
connections at once, a TLS handshake it must finish within 10 seconds, 15
seconds from connecting to the WebSocket upgrade with one HTTP request per
connection, and a Noise handshake with its hello (or, while pairing, its pair
request) due within 10 seconds of the upgrade. A connection that has not
authenticated is held to a small memory bound, and a client frame carries at
most 64 KiB. An app built for a protocol version the daemon does not speak is
refused with an error that says which side must update.

A listener that cannot bind its address (`address_unavailable`,
`address_in_use`, `permission_denied`) never stops the daemon: `mobile.status`
reads its listener as `unavailable` with that reason, and it retries, from one
second doubling to a minute, for up to a day, then waits for the next restart.

## Enable and pair

The knobs live under `[fermix_channels.mobile]` in `config.toml`. `enabled`,
`port`, `bind` and `advertise_mdns` are also the four rows of the
`channels.mobile` settings section; `streaming` and `max_media_bytes` are hand
edits only. Changes reach the listener only after a daemon restart. The
separate `media_store_max_bytes` setting controls the content-addressed
retention budget (2 GiB by default). Draft streaming is the seeded mobile
default. Binding to `0.0.0.0` exposes only the dedicated mobile listener, not
the loopback setup endpoint. `bind` must be a literal IP address; a value that
is not one is refused when the configuration is written or loaded, by name,
instead of failing later at listener startup.

Pairing is a session the daemon owns and a client polls; it is not a job and
holds no connection open. `mobile.pair.start` opens the one pairing window (120
seconds, one at a time; a second start while one is open is refused as busy)
and returns the pairing link once, on that call only, with at most 16 of the
addresses the phone may reach the host on, best first. The link carries the
single-use secret the QR encodes, so it is never logged, never kept and never
repeated by a later read, and the secret expires with the window. A start the
daemon refuses opens nothing and answers a `failed` view with the daemon's own
sentence: the channel is off, it could not start this boot, it was turned on and
has not started yet, the gateway identity files are incomplete, the
paired-device list could not be read, or the listener could not start.

The session view's `state` is the switch:

- `awaiting_scan`: the window is open and no phone has connected yet;
  `ttl_ms` counts down, relative to the read;
- `awaiting_decision`: a phone completed the Noise handshake and asked. The
  `request` carries its name, model and app version and the six-digit SAS, plus
  an attestation field in its final shape that stays empty until
  secure-hardware verification lands: it always reads "This phone sent no
  secure-hardware proof.", and the platform, build role and boot state are
  null;
- `approved` (with the new device id), `denied`, `expired` (reason `timeout`)
  or `cancelled`, which are terminal and keep the request, so a pane can say
  who was approved or denied. The phone is told the same word the pane shows
  (`denied`, `timeout`, `cancelled`, `device_disconnected`);
- `failed`, with the daemon's sentence: the phone disconnected before the owner
  decided (`device_disconnected`, so nothing is persisted and pairing starts
  again).

Failed handshakes never close a window. An address that fails five times is
refused for the rest of that window and no other address is, and nothing is
counted while a phone waits for the owner's decision, so a stranger on the
network can refuse only itself, never end the owner's pairing. The same phone
asking again replaces its own waiting request.

A finished session stays readable for a few minutes (at most eight are kept),
so a pane that was closed and reopened reads how it ended instead of opening a
second window; an id the daemon no longer keeps is its own refusal.

`fermix pair` drives exactly this session. It starts the window, prints the QR,
the time left and the manual pairing link, then polls the daemon every second
until a phone asks (bounded by the window plus a few seconds of slack). It
prints the attestation line and the device line with the SAS, and approves only
on an explicit `y`; a blank answer or a closed input denies. If anything fails
after the window opened, it cancels the window before exiting. A refused start
prints the daemon's sentence, and for a channel that is off it also names the
`config.toml` switch. The phone and terminal show the same six-digit SAS
derived from the Noise handshake; compare it before approving. Approval
persists the device public key in `$FERMIX_HOME/mobile/devices.toml`. The
device name and model shown are bounded, printable text: the daemon refuses
control characters and anything over 128 bytes before the owner is asked.

Host material stays under `$FERMIX_HOME/mobile/`: `gateway_key`, `tls.crt`,
`tls.key`, `devices.toml`, and the durable `media/` store. Private keys and the
pairing registry must retain `0600` permissions, and the directory `0700`:
every start creates it that way and tightens one left looser.

Manage trust from the host:

- `fermix devices list` (`mobile.devices.list`) shows paired device ids, names,
  creation time, and last seen time, oldest first. With the channel not
  running it reads them from `devices.toml` and never creates the directory.
- `fermix devices revoke DEVICE_ID` (`mobile.devices.revoke`) removes that key,
  closes its live socket at once, and stops what that phone asked for: every
  request it sent that has not finished is cancelled and its turn stopped, and
  none of them runs again at the next boot. With the channel not running it
  deletes the row from `devices.toml` and cancels those requests the same way.
  An id no phone has is refused with "No paired phone has that id."
- App-side Unpair deletes the phone's local keys and requests removal, but host
  revocation remains authoritative for a lost or unavailable phone.

## Chat behavior

Every paired device shares the `main` profile conversation, and the Mac app's
chat reads the same timeline, so reconnects, a second phone and the Mac see the
same durable host history. Every row is announced live the moment it is
written, whoever writes it (a phone, the Mac app, a job's delivery, a turn's
reply), to every connected phone with its attachments and link previews and to
the Mac app. The phone queues messages while offline and resends them by client
message id; the host deduplicates them and resynchronizes with a monotonic
history cursor. Read state is also monotonic, never past the newest row, and
shared across the owner's devices.

The surface is text, tool-activity indicators, photos and documents in both
directions, voice notes, slash commands and the host-supplied command palette,
link previews, reactions, and approve/deny cards (including the confirmation
for an access-sensitive plugin command, such as a car unlock, that Fermix runs
once it is approved). Its limits:

- **Streaming needs a streaming route.** A reply streams into a live draft on
  the phone only when the turn runs on a streaming provider route (Codex
  today); on any other route it arrives whole when the turn ends. A draft opens
  on its first character and updates every tenth of a second.
- **Long replies arrive in parts.** An event too large for one frame (a long
  reply, a history page) is sent as parts the app reassembles, up to 1 MiB per
  event; a reply or row longer than that is cut there and marked truncated,
  while the stored row keeps it whole. A history page holds at most 256 KiB, so
  it can carry fewer rows than asked, with a cursor to pull the rest.
- **The phone has a scoped Stop.** Cancel names one request by its client
  message id and stops that turn whether it is running, waiting behind another,
  or not yet queued; it never touches another turn. `/stop` still stops
  everything.
- **Reactions are live-only.** The `react` tool reaches a connected phone; the
  reaction is not stored, so a phone that was away never sees it.
- **Approvals stay on the phone.** A card goes only to the transport whose turn
  raised it, because its token resolves only there: a phone's card never shows
  on the Mac, and the reverse. A card still waiting is sent again when a phone
  says hello, with the time it has left, and is withdrawn as expired when that
  runs out. A card that was answered or ran out while the phone was away is not
  sent again: the app drops every card it shows when the daemon answers its
  hello and keeps only the ones sent after that.
- **A request that fails is answered by name.** After `accepted`, a failed
  message or command comes back as an error carrying its client message id, to
  whichever socket the phone has by then. A refusal the phone can act on keeps
  its own code (such as `store_quota_exceeded`, `media_too_large` or
  `attachment_unavailable` for an attach id the host no longer holds); any
  other failure reads `request_failed`.
- **Link previews persist.** A preview is stored with its row before it goes
  out, so history carries it; resolving one has a hard deadline and at most four
  run at once.

Voice notes use the configured Fermix transcription backend. They are not
realtime voice: full-duplex phone calls belong to the later mobile realtime
milestone.

Mobile uploads are capped by `max_media_bytes` (20 MiB by default), with at
most four uploads in flight per phone and sixteen in all; a new upload never
evicts stored media to make room. An upload's attach id is valid for two days.
The phone strips image location metadata before upload, and the host keeps
durable, content-addressed media under `$FERMIX_HOME/mobile/media/` so another
paired device can fetch attachments from history. A download streams in
chunks, so the chat keeps moving while it runs.

## Direct APNs push

When no device socket is connected and another device has not already read the
new content, Fermix can send one direct APNs notification per registered device.
Connected devices receive socket events only, preventing double notification.
Scheduled and background channel deliveries use the same rule. An approval
raised on the phone, while no device of the profile is connected, pushes a
content-free "Approval needed"; an approval raised on the Mac pushes nothing.

Configure `[fermix_channels.mobile.push]` by hand with `enabled`, `team_id`,
`key_id`, `topic`, and `environment` (`development` or `production`). The `.p8`
key uses the normal Fermix secret path: provide `FERMIX_APNS_KEY`, or write it
into `config.toml` once and move it to the OS keychain with
`fermix setup --migrate-secrets` (the generic secret migration, not a mobile
step); never leave it in ordinary TOML. The payload carries a per-device
encrypted preview, never plaintext chat content, but no phone can decrypt that
preview yet: pairing does not hand the phone the salt it needs to derive its
push key, so the alert a phone shows reads only "New message" until it does.
This direct-key model is for owner-operated and TestFlight builds; a public App
Store push relay is a separate future milestone.

Push degrades instead of failing. Fermix connects to Apple on the first push,
never at boot. A push waits for a connect at most 10 seconds; the APNs library
cannot cut a connect short, so a slower one runs to its end and until then
every push is refused as connecting, with no second connect behind it. While
it connects, or when Apple cannot be reached, push reads `degraded`
(`connecting`, `connect_failed` or `connection_lost`) and the daemon keeps
running; the next push reconnects.

## Troubleshooting and observability

Run `fermix doctor` after enabling the channel and restarting. Its mobile checks
cover gateway keys and TLS
files with `0600` permissions, listener reachability on advertised candidates,
mDNS advertising, tailnet detection, APNs credential resolution and delivery,
and paired device count. An enabled channel that has never been paired is a
warning with the `fermix pair` hint, not a failure — the identity is created by
that command. An identity that exists but is incomplete or no longer `0600` is
a failure, because Fermix refuses such files rather than regenerating them. Two
daemon facts come first and replace the per-probe symptoms: a surface the
daemon refused this boot fails as "mobile surface refused this boot (class);
see the daemon log", and a channel enabled but not started since fails as
"mobile channel not started; restart the daemon". A
listener that cannot bind reads "listener unavailable (reason); it keeps
retrying", and push that is not ready reads "APNs connecting to Apple" or "APNs
degraded (reason); the next push reconnects". `mobile.status` publishes the
same facts: `enabled` (the config switch) and `started` (the channel serving)
as separate facts, `refused` with its `refusal` class, the listener with its
status and reason, APNs with its delivery and reason, mDNS, tailnet, the
paired-device count, the gateway key's fingerprint and the pairing session in
flight. Common failures are:

- phone and host share no reachable LAN/tailnet candidate;
- the configured bind address or port is unavailable (the listener keeps
  retrying);
- the daemon was not restarted after changing mobile configuration;
- mDNS is disabled or blocked, requiring a reachable candidate from the QR;
- the APNs topic/environment does not match the app build, or
  `FERMIX_APNS_KEY` cannot be resolved: a locked or unreadable OS keychain
  leaves the key unresolved, so mobile starts without push, logs that loudly,
  and `fermix doctor` reports APNs credentials missing;
- the device was revoked or reinstalled and must pair again;
- memory is turned off (`[fermix_core.memory] enabled = false`): the phone
  channel keeps its timeline and requests there, so it is refused for that
  boot with the class `memory_disabled`, while every other channel keeps
  running;
- `devices.toml` is unreadable, corrupt, empty, or no longer `0600`: the mobile
  surface refuses to start for that boot and says so in the daemon log and in
  `fermix doctor`, while every other channel keeps running. Fermix never
  rebuilds a trust store — repair or remove the file, then restart.

Normal turns retain the standard `main-*` trace session and group in Opik under
the `mobile:main` conversation thread. Pairing emits terminal
`channel_pair` events (`approved`, `denied`, `expired`, `cancelled`, or
`device_disconnected`) and
APNs attempts emit `channel_push` (`sent` or `failed`) in `agent_event.jsonl`.
Those operational events contain counts, duration, channel, and status only, never
message text, pairing secret, key material, SAS, device name, APNs token, or
provider response body.
