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
  only when the daemon restarts, and until then the channel reports itself as
  not started;
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

## Reachability and security

The v1 app connects to the dedicated mobile listener over LAN/Bonjour or any
network shared by the phone and host, commonly a Tailscale tailnet. The default
listener is `wss://HOST:4031/ws`; `/healthz` is its only other HTTP route. The
regular setup endpoint and LiveView remain loopback-only.

TLS satisfies iOS transport requirements, but trust comes from an end-to-end
Noise session between device and gateway keys. A pinned certificate fingerprint
and gateway public key arrive through the pairing QR. There is no bearer token,
port-forwarding workflow, public Funnel, or hosted relay in the v1 message path.
The planned iroh sidecar is a v1.x fast-follow, not part of the v1 setup or a
second runtime fallback.

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
and returns the pairing link once, on that call only. The link carries the
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
  who was approved or denied;
- `failed`, with the daemon's sentence: five failed connection attempts
  (`rate_limited`), or the phone disconnected before the owner decided
  (`device_disconnected`, so nothing is persisted and pairing starts again).

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
pairing registry must retain `0600` permissions.

Manage trust from the host:

- `fermix devices list` (`mobile.devices.list`) shows paired device ids, names,
  creation time, and last seen time, oldest first. It is empty whenever the
  channel is not running.
- `fermix devices revoke DEVICE_ID` (`mobile.devices.revoke`) removes that key
  and terminates its live socket immediately; an id no phone has is refused
  with "No paired phone has that id."
- App-side Unpair deletes the phone's local keys and requests removal, but host
  revocation remains authoritative for a lost or unavailable phone.

## Chat behavior

Every paired device shares the `main` profile conversation, so reconnects and a
second phone see the same durable host history. The phone queues messages while
offline and resends them by client message id; the host deduplicates them and
resynchronizes with a monotonic history cursor. Read state is also monotonic and
shared across the owner's devices.

The v1 surface includes text and draft streaming, tool-activity indicators,
photos and documents in both directions, voice notes, slash commands and the
host-supplied command palette, reactions, and approve/deny cards (including the
confirmation for an access-sensitive plugin command, such as a car unlock, that
Fermix runs once it is approved). Voice notes
use the configured Fermix transcription backend. They are not realtime voice:
full-duplex phone calls belong to the later mobile realtime milestone.

Mobile uploads are capped by `max_media_bytes` (20 MiB by default). The phone
strips image location metadata before upload, and the host keeps durable,
content-addressed media under `$FERMIX_HOME/mobile/media/` so another paired
device can fetch attachments from history.

## Direct APNs push

When no device socket is connected and another device has not already read the
new content, Fermix can send one direct APNs notification per registered device.
Connected devices receive socket events only, preventing double notification.
Scheduled and background channel deliveries use the same rule.

Configure `[fermix_channels.mobile.push]` by hand with `enabled`, `team_id`,
`key_id`, `topic`, and `environment` (`development` or `production`). The `.p8`
key uses the normal Fermix secret path: provide `FERMIX_APNS_KEY`, or write it
into `config.toml` once and move it to the OS keychain with
`fermix setup --migrate-secrets` (the generic secret migration, not a mobile
step); never leave it in ordinary TOML. The payload carries a
per-device encrypted preview, not plaintext chat content. This direct-key model
is for the owner-operated/TestFlight v1; a public App Store push relay is a
separate future milestone.

## Troubleshooting and observability

Run `fermix doctor` after enabling the channel and restarting. Its mobile checks
cover gateway keys and TLS
files with `0600` permissions, listener reachability on advertised candidates,
mDNS advertising, tailnet detection, APNs credential resolution, and paired
device count. An enabled channel that has never been paired is a warning with
the `fermix pair` hint, not a failure — the identity is created by that command.
An identity that exists but is incomplete or no longer `0600` is a failure,
because Fermix refuses such files rather than regenerating them. Two daemon
facts come first and replace the per-probe symptoms: a surface the daemon
refused this boot fails as "mobile surface refused this boot; see the daemon
log", and a channel enabled but not started since fails as "mobile channel not
started; restart the daemon". `mobile.status` publishes the same facts
(`enabled`, `started`, `refused`) beside the listener, mDNS, tailnet, APNs,
paired-device count, the gateway key's fingerprint and the pairing session in
flight. Common failures are:

- phone and host share no reachable LAN/tailnet candidate;
- the configured bind address or port is unavailable;
- the daemon was not restarted after changing mobile configuration;
- mDNS is disabled or blocked, requiring a reachable candidate from the QR;
- the APNs topic/environment does not match the app build, or
  `FERMIX_APNS_KEY` cannot be resolved: a locked or unreadable OS keychain
  leaves the key unresolved, so mobile starts without push, logs that loudly,
  and `fermix doctor` reports APNs credentials missing;
- the device was revoked or reinstalled and must pair again;
- `devices.toml` is unreadable, corrupt, or no longer `0600`: the mobile surface
  refuses to start for that boot and says so in the daemon log and in
  `fermix doctor`, while every other channel keeps running. Fermix never
  rebuilds a trust store — repair or remove the file, then restart.

Normal turns retain the standard `main-*` trace session and group in Opik under
the `mobile:main` conversation thread. Pairing emits terminal
`channel_pair` events (`approved`, `denied`, `expired`, `cancelled`,
`rate_limited`, or `device_disconnected`) and
APNs attempts emit `channel_push` (`sent` or `failed`) in `agent_event.jsonl`.
Those operational events contain counts, duration, channel, and status only, never
message text, pairing secret, key material, SAS, device name, APNs token, or
provider response body.
