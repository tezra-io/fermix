# iPhone mobile companion

The mobile companion is a first-party, owner-only channel from an iPhone to the
operator's own Fermix daemon. The app lives in its own repository; Fermix is the
source of truth for the versioned wire contract. It is not a hosted chat service:
messages stay between the phone and the host, and a paired device enters the
gateway with operator role and trust.

**Availability: the iPhone app has not been released.** Everything below is the
daemon half, which ships first so the app can be built against a fixed wire.
There is nothing to install on a phone yet, so pairing has no counterpart and
becomes usable when the app ships in its own release. Tell an owner asking to use
Fermix from their phone exactly that, and point them at the channels that work
today; never walk them through installing or scanning.

**The channel is feature-flagged off and has no setup surface.** It is not
offered anywhere in setup — no wizard step, no CLI flag, no tab in the web
setup — and an absent `[fermix_channels.mobile]` section means disabled, not
unconfigured. The only way to turn it on is to hand-edit `config.toml`:

```toml
[fermix_channels.mobile]
enabled = true
```

then restart the daemon (`fermix restart`). Never tell an owner to enable it
through setup; that switch does not exist there.

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

Every knob is a hand edit of `config.toml` under `[fermix_channels.mobile]`:
`enabled`, `port`, `bind`, `advertise_mdns`, `streaming`, and
`max_media_bytes`. Changes reach the listener only after a daemon restart. The
separate `media_store_max_bytes` setting controls the content-addressed
retention budget (2 GiB by default). Draft streaming is the seeded mobile
default. Binding to `0.0.0.0` exposes only the dedicated mobile listener, not
the loopback setup endpoint. `bind` must be a literal IP address; a value that
is not one is refused when the configuration is written or loaded, by name,
instead of failing later at listener startup.

Run `fermix pair` on the host and scan the displayed QR in the app — the host
side works now, the scanning side arrives with the app. The window lasts 120
seconds. The phone and terminal show the same six-digit SAS derived
from the Noise handshake; compare it before approving. Approval persists the
device public key in `$FERMIX_HOME/mobile/devices.toml`. The QR secret is
single-use and expires with the pairing window. The device name and model shown
in the prompt are bounded, printable text — the daemon refuses control
characters and anything over 128 bytes before the owner is asked. If the phone
disconnects while the owner is deciding, approval is refused rather than
persisted, and `fermix pair` says so and must be re-run.

Host material stays under `$FERMIX_HOME/mobile/`: `gateway_key`, `tls.crt`,
`tls.key`, `devices.toml`, and the durable `media/` store. Private keys and the
pairing registry must retain `0600` permissions.

Manage trust from the host:

- `fermix devices list` shows paired device ids, names, creation time, and last
  seen time.
- `fermix devices revoke DEVICE_ID` removes that key and terminates its live
  socket immediately.
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
host-supplied command palette, reactions, and approve/deny cards. Voice notes
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

Run `fermix doctor` after enabling the flag and restarting. Its mobile checks
cover gateway keys and TLS
files with `0600` permissions, listener reachability on advertised candidates,
mDNS advertising, tailnet detection, APNs credential resolution, and paired
device count. An enabled channel that has never been paired is a warning with
the `fermix pair` hint, not a failure — the identity is created by that command.
An identity that exists but is incomplete or no longer `0600` is a failure,
because Fermix refuses such files rather than regenerating them. Common failures
are:

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
`channel_pair` events (`approved`, `denied`, `expired`, or `rate_limited`) and
APNs attempts emit `channel_push` (`sent` or `failed`) in `agent_event.jsonl`.
Those operational events contain counts, duration, channel, and status only—no
message text, pairing secret, key material, SAS, device name, APNs token, or
provider response body.
