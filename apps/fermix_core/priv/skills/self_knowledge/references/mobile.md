# Mobile companion (phone channel)

An owner-only channel from the owner's phone to their own Fermix daemon. It is not a hosted chat service: messages stay between the phone and the host, and a paired device enters the gateway as the operator. Fermix owns the versioned wire contract; the phone apps live in their own repositories.

**No phone app is released.** The Android app is in development and the iPhone app has not shipped. What exists is the daemon half, so there is nothing to install or scan yet. Tell an owner who asks exactly that, point them at the chat channels that work today, and never walk them through installing an app or pairing.

## Turning it on

On by default: an absent `[fermix_channels.mobile]` section, or one without `enabled`, means enabled, and `enabled = false` keeps it off. An install that saved its settings while the channel was off by default carries that `enabled = false` line, so it stays off until the line changes. The daemon publishes two management surfaces:

- the `channels.mobile` settings section: `enabled`, `port`, `bind` (`0.0.0.0` for every network, or one literal IP such as the Tailscale address; anything else is refused by name) and `advertise_mdns`. A write lands in `config.toml` at once, but the listener starts or stops only at a restart; until then the channel keeps doing what it did at boot (turned on, it reports not started; turned off, it keeps serving, pairing and revoking included).
- the `mobile.*` methods: `mobile.status`, the pairing session (`mobile.pair.start`, `mobile.pair.get`, `mobile.pair.decide`, `mobile.pair.cancel`) and paired devices (`mobile.devices.list`, `mobile.devices.revoke`).

No desktop app draws a Phone pane on them yet. On an app-managed Mac, enabling and pairing belong to the app, never the CLI. On a dev or Linux host whose `config.toml` says `enabled = false`:

```toml
[fermix_channels.mobile]
enabled = true
```

then `fermix restart`, and pair with `fermix pair`. The terminal wizard and browser setup have no mobile step or flag.

**Only the owner pairs or forgets a phone.** Starting, deciding or cancelling a pairing and revoking a phone are taken only from a process the daemon places as the owner's own (the app, or a command typed in a terminal). One Fermix started itself (an agent's shell command, a coding run, a scheduled job), a detached one, or one it cannot place is refused with "Only the owner can pair or forget a phone; run this from your own terminal." So never run `fermix pair` or `fermix devices revoke` through `shell`; tell the owner to. Reading the status, the session and the phone list stays open.

Hand-edit only: `streaming` (draft streaming is the default) and `max_media_bytes`. `media_store_max_bytes` sets the media retention budget (2 GiB by default).

## Reachability and security

- The phone connects to a dedicated listener, `wss://HOST:4031/ws` by default (`/healthz` is its only other route), over the LAN (Bonjour) or any shared network such as a Tailscale tailnet. Binding to `0.0.0.0` exposes only this listener; setup and the web UI stay loopback-only.
- TLS satisfies the phone platform; trust comes from an end-to-end Noise session between device and gateway keys. The pairing QR carries the pinned certificate fingerprint and gateway public key. No bearer token, port forwarding, public funnel or hosted relay is involved.
- The listener bounds a peer that never finishes: 64 connections at once, 10 seconds for TLS, 15 seconds to the WebSocket upgrade, 10 seconds for the Noise hello, 64 KiB per client frame. An app built for a protocol version the daemon does not speak is refused with an error naming which side must update.
- A listener that cannot bind (`address_unavailable`, `address_in_use`, `permission_denied`) never stops the daemon: `mobile.status` reads it `unavailable` with that reason, and it retries (one second doubling to a minute) for up to a day, then waits for the next restart.
- Host material lives in `$FERMIX_HOME/mobile/` (`0700`): `gateway_key`, `tls.crt`, `tls.key`, `devices.toml` and the `media/` store; keys and the device list must stay `0600`.

## Pairing

- `mobile.pair.start` opens the one pairing window (120 seconds; a second start while it is open is refused as busy) and returns the pairing link once, on that call only, with up to 16 host addresses, best first; the link's single-use secret is never logged or repeated and expires with the window. A refused start answers `failed` with the daemon's sentence: the channel is off, could not start this boot, was turned on but not yet restarted, identity files are incomplete, the device list is unreadable, or the listener could not start.
- Session `state`: `awaiting_scan` (window open, `ttl_ms` left); `awaiting_decision` (a phone completed the Noise handshake; `request` carries its name, model, platform (`android` or `ios`, as the phone says), app version and the six-digit SAS, and an attestation line that always reads "Fermix does not check a phone's secure hardware yet.": the phone sends its secure-hardware certificate chain, and this Fermix takes it without verifying it); terminal `approved` (with the new device id), `denied`, `expired` (`timeout`) or `cancelled`; or `failed` (`device_disconnected` before a decision, so nothing is saved). A finished session stays readable for a few minutes (at most eight kept).
- Failed handshakes never close the window: an address that fails five times is refused for the rest of that window and no other address is, and nothing is counted while a phone waits for the owner's decision. The same phone asking again replaces its own waiting request.
- `fermix pair` drives this session: it prints the QR, time left and manual link, polls every second, shows the attestation line and the device with its SAS, and approves only on an explicit `y` (blank or closed input denies). Compare the SAS on phone and terminal first. It cancels the window if anything fails. Approval stores the device key in `devices.toml`. Device names and models over 128 bytes or with control characters are refused before the owner is asked.
- `fermix devices list` (`mobile.devices.list`): paired ids, names, created and last-seen times, oldest first; with the channel off it reads `devices.toml`. `fermix devices revoke DEVICE_ID` (`mobile.devices.revoke`) removes the key, drops its live socket at once, and cancels every unfinished request from that phone so none runs again at the next boot; with the channel off it edits `devices.toml` the same way. An unknown id answers "No paired phone has that id." Unpairing on the phone requests removal, but host revocation is authoritative for a lost phone.

## Chat behavior

- All paired phones share the `main` conversation, and the Mac app's chat reads the same timeline, so reconnects, a second phone and the Mac see the same history; every row is announced live to each connected device. The phone queues offline messages and resends them by client message id; the host deduplicates and resynchronizes with a monotonic cursor. Read state is shared and never passes the newest row.
- The phone's turns run in the Mac app's chat conversation: one agent history for the one timeline. A turn from the phone reads what was said on the Mac (a GPT-Live call's tasks in the chat included) and the reverse, and a phone message waits for a running Mac turn or voice task and the reverse. `/new` from the phone starts that one conversation afresh for both. The channel is still the phone's: pairing, approval cards, streaming and push are unchanged.
- During a GPT-Live call in the chat, a message typed on the phone is passed to the voice like one typed on the Mac, its answer too, and its turn knows the call is up; it always answers in writing, because the phone's channel writes each reply as it comes and cannot end a turn silently.
- Text, tool activity, photos and documents both ways, voice notes, slash commands and the command palette, link previews (stored with their row), reactions, and approve/deny cards (including an access-sensitive plugin command, run once approved). Voice notes use the configured transcription backend; this is not realtime voice, and phone calls are not supported.
- A reply streams into a live draft only on a streaming provider route (Codex today); otherwise it arrives whole when the turn ends.
- An event over one frame arrives in parts, up to 1 MiB; a longer reply is cut there and marked truncated on the phone while the stored row keeps it whole. A history page holds at most 256 KiB and its cursor pulls the rest.
- The phone's Stop cancels one request by its client message id (running, waiting or not yet queued), never a Mac turn in the queue they share; `/stop` still stops everything.
- Reactions reach only a connected phone; they are not stored.
- An approval card goes only to the chat whose turn raised it (a phone's never shows on the Mac, and the reverse). A card still waiting is sent again when a phone reconnects, with the time it has left.
- A failed message or command comes back by its client message id with its own code (`store_quota_exceeded`, `media_too_large`, `attachment_unavailable`) or `request_failed`.
- Uploads are capped by `max_media_bytes` (20 MiB by default), four in flight per phone and sixteen in all, and never evict stored media; an attach id is valid for two days. The phone strips image location data; the host keeps content-addressed media under `mobile/media/` so another phone can fetch attachments from history.

## Push (APNs)

When no device socket is connected and no other device has read the new content, Fermix sends one direct APNs notification per registered device; scheduled and background deliveries follow the same rule, whether they reach the shared chat through the phone's channel or the Mac's (so `schedule_job` with `delivery_mode: "origin"` from the phone, which delivers into the shared chat as the Mac chat does, still pushes a phone that is away, and an owner reading on the Mac is not pinged). An approval raised on the phone while no device is connected pushes a content-free "Approval needed". The payload carries a per-device encrypted preview, never plaintext, but no phone can decrypt it yet, so the alert reads only "New message". Configure `[fermix_channels.mobile.push]` by hand: `enabled`, `team_id`, `key_id`, `topic`, `environment` (`development` or `production`). The `.p8` key follows the normal secret path: `FERMIX_APNS_KEY`, or write it into `config.toml` once and move it to the keychain with `fermix setup --migrate-secrets`; never leave it in plain TOML. Fermix connects to Apple on the first push, never at boot; while connecting or unreachable, push reads `degraded` and the daemon keeps running.

## Troubleshooting

`fermix doctor` checks gateway keys and TLS files (`0600`), listener reachability on advertised addresses, mDNS, tailnet detection, APNs credentials and delivery, and the paired-device count. An enabled channel with no phone paired passes as "on, no phone paired yet"; an incomplete identity or wrong permissions fails, because Fermix refuses such files rather than regenerating them. "mobile surface refused this boot; see the daemon log" and "mobile channel not started; restart the daemon" replace the per-probe rows; a listener that cannot bind reads "listener unavailable (reason); it keeps retrying". `mobile.status` publishes the same facts (`enabled` and `started` separately, any `refusal` class, listener, APNs, mDNS, tailnet, device count, the gateway key fingerprint and the pairing in flight).

- Phone and host share no reachable LAN or tailnet address.
- The bind address or port is unavailable (the listener keeps retrying).
- The daemon was not restarted after a mobile config change.
- mDNS is off or blocked, so the phone needs a reachable address from the QR.
- APNs `topic` or `environment` does not match the app build, or `FERMIX_APNS_KEY` cannot be read (a locked keychain): mobile starts without push, logs it, and `fermix doctor` reports APNs credentials missing.
- The phone was revoked or reinstalled: pair again.
- Memory is off (`[fermix_core.memory] enabled = false`): the phone channel keeps its timeline there, so it is refused for that boot as `memory_disabled` (every other channel keeps running).
- `devices.toml` is unreadable, corrupt, empty or not `0600`: the mobile surface refuses to start for that boot (every other channel keeps running). Repair or remove the file, then restart.

Turns keep the `main-*` trace session and group in Opik under the `mobile:main` thread.
