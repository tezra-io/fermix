# Fermix mobile companion protocol

This is the canonical wire contract between the Fermix daemon and the iOS
companion. The daemon implementation is `FermixChannels.Mobile.Protocol` plus
`FermixChannels.Mobile.Noise`. The iOS repository vendors this directory pinned
by checksum; it does not hand-copy event shapes.

## Stack and bounds

For an established connection the layers are:

1. one WSS binary message (WSS exists for iOS ATS, not as the trust anchor);
2. one Noise transport message (`Noise_IK_25519_ChaChaPoly_SHA256` after pairing);
3. one mobile plaintext frame.

A mobile plaintext frame is:

```text
uint32be json_header_length | JSON header | optional raw bytes
```

The length is a 32-bit unsigned big-endian integer. There is no newline framing
and no second decoder path. The JSON header is at most 4,096 bytes. A raw chunk
is at most **60 KiB** (61,440 bytes). The complete plaintext is at most 65,519
bytes because a Noise message is at most 65,535 bytes and ChaChaPoly adds a
16-byte tag. Therefore a maximum-size raw chunk may carry at most a 4,075-byte
header including its four-byte length prefix.

Only `attach_chunk` (client to daemon) and `media_chunk` (daemon to client) may
carry raw bytes. Every other event must have an empty raw tail. Binary golden
fixtures represent the actual frame as `{header, bytes_b64}` only so JSONL can
store it; that wrapper is not sent on the wire.

## Noise modes and pairing

The phone is always the Noise initiator and the daemon is the responder. The
first handshake message starts with one fixed, clear five-byte prelude:

| Prelude | Pattern | Use |
|---|---|---|
| `46 58 4d 31 01` (`FXM1` + `0x01`) | `IK` | already-paired device session |
| `46 58 4d 31 02` (`FXM1` + `0x02`) | `IKpsk2` | owner-open pairing window |

The responder validates this prelude before initializing cryptographic state.
An unknown or unexpected mode is terminal; it must not try another handshake.
The authenticated prologue is exactly the ASCII bytes `fermix-mobile-v1`
followed by the same five-byte prelude. The prelude appears on the wire only
before the first Noise message.

`IKpsk2` uses the 32-byte one-time QR secret as its PSK. After a successful
pairing handshake both sides show a six-digit SAS derived exactly as follows:

1. `digest = HMAC-SHA256(key: handshake_hash, data: "fermix-mobile-sas-v1")`
2. read the first four digest bytes as an unsigned big-endian integer;
3. reduce modulo 1,000,000 and zero-pad to six decimal digits.

A pairing window lasts at most 120 seconds while the owner decides. During that
wait the daemon answers `ping` with `pong` and refuses every other event until
the decision arrives, so a keepalive never has to stop; an idle disconnect while
a decision is pending is not counted as a failed pairing handshake.

The shared deterministic `noise_vectors.json` pins X25519 keys, both handshake
messages, handshake hashes, SAS values, and the first transport ciphertext for
both patterns. Private keys in that file are test material only.

After a paired `IK` handshake, the daemon authorizes the authenticated initiator
static against `devices.toml`. Noise transport nonces and the application
sequence both restart on every new session. Each direction performs a
deterministic Noise REKEY after exactly 2^20 frames, replacing only that
direction's key while preserving that direction's current transport nonce. The one-hour
session lifetime closes and reconnects with a fresh handshake. A peer never performs a unilateral time-based rekey.

## Envelope, ordering, and version negotiation

Every JSON header has these required fields:

```json
{"v":1,"t":"event_name","seq":1}
```

- `v` is the event schema version.
- `t` is a closed event name. An unknown value receives an `unsupported` error;
  it is never silently ignored.
- `seq` is an unsigned 64-bit integer. It starts at 1, increases by exactly one
  per sender within a Noise session, and resets only with a new session. The
  codec validates its range; the socket owner validates ordering.
- Unknown payload fields are preserved and ignored by older peers, so additive
  optional fields do not require a version bump.

The first encrypted event in a paired session is `hello` and its `seq` is 1.
`hello.protocol_v` must equal the envelope `v`. The daemon replies with
`hello_ack` containing `min_version` and `max_version`. The supported window is
**N/N-1**: the current protocol and previous protocol (or just 1 before a second
version exists). A client below the floor must update the app; a client above
the ceiling must update Fermix. No other event is serviced before hello and a
second hello is terminal.

Rollout order is daemon first (add N+1 while retaining N), then app. Rollback is
the reverse. The app must never ship a required version before a released daemon
accepts it.

## Client events

| `t` | Required payload | Rules |
|---|---|---|
| `hello` | `device_id`, `app_version`, `last_server_seq`, `protocol_v` | first paired-session event |
| `msg` | `client_msg_id`, `profile_id`, `text`, `attach_ids[]` | text or at least one attachment is required |
| `attach_begin` | `attach_id`, `kind`, `mime`, `size_bytes`, `sha256`; `name?` | SHA-256 is announced before transfer so the host can deduplicate |
| `attach_chunk` | `attach_id`, `index` + raw bytes | contiguous zero-based indexes; raw bytes ≤60 KiB |
| `attach_end` | `attach_id`, `sha256` | host verifies announced size and digest |
| `command` | `client_msg_id`, `profile_id`, `name`; `args?` | uses the normal command registry |
| `history_pull` | `profile_id`, `after_seq`, `limit` | limit is 1–200 |
| `media_fetch` | `ref` | re-download a content-addressed blob |
| `push_register` | `apns_token`, `environment` | environment is `development` or `production` |
| `ack` | `server_seq` | cumulative socket-delivery cursor |
| `read_state` | `profile_id`, `read_up_to_seq` | monotonic read frontier |
| `pair_request` | `device_name`, `model`, `app_version` | first event inside an IKpsk2 pairing session; each field is ≤128 bytes of valid UTF-8 and must contain no C0/C1/DEL control characters |
| `unpair` | — | best-effort self-removal; host CLI remains authoritative |
| `ping` | — | keepalive |

`attach_begin` receives `attach_status{status:"upload"}` before chunks, or
`attach_status{status:"present"}` when the digest is already stored. A client
must not upload chunks after `present`.

## Server events

| `t` | Required payload | Rules |
|---|---|---|
| `hello_ack` | `session_id`, `min_version`, `max_version`, `profiles[]`, `candidates[]`, `history_head_seq`, `read_up_to_seq`, `caps{}` | completes hello negotiation |
| `accepted` | `client_msg_id`, `duplicate` | durable receipt for a `msg` or `command`; clears the outbox item |
| `attach_status` | `attach_id`, `status` | status is `upload` or `present` |
| `turn_started` | `profile_id`, `turn_id`, `in_reply_to` | begins streamed draft |
| `text_delta` | `turn_id`, `text` | streamed delta |
| `tool_event` | `turn_id`, `tool`, `phase` | phase is `start` or `stop` |
| `text_done` | `turn_id`, `server_seq`, `text` | canonical final text |
| `media_begin` | `ref`, `server_seq`, `kind`, `mime`, `size_bytes`, `sha256`; `filename?`, `caption?` | starts outbound media |
| `media_chunk` | `ref`, `index` + raw bytes | contiguous zero-based indexes; raw bytes ≤60 KiB |
| `media_end` | `ref`, `sha256` | completes outbound media |
| `turn_error` | `turn_id`, `code`, `message` | terminal turn failure |
| `reaction` | `in_reply_to`, `emoji` | reacts to a client message id |
| `approval` | `approval_id`, `kind`, `text`, `token`, `ttl_s`, `approve_command`, `deny_command`; `detail?` | command routes are nonempty and at most 1,024 characters; token is submitted but never rendered |
| `approval_resolved` | `approval_id`, `outcome` | approved, denied, or expired |
| `link_preview` | `in_reply_to`, `url`, `site`, `title`; `description?`, `image_ref?` | host-resolved preview |
| `read_state` | `profile_id`, `read_up_to_seq` | another device advanced the frontier |
| `history_page` | `profile_id`, `messages[]`; `next_after_seq?` | exact server-sequence cursor page |
| `notice` | `kind`, `text` | non-turn informational output |
| `pair_approved` | `device_id`, `candidates[]`, `profiles[]` | completes pairing |
| `pair_denied` | `reason` | terminal pairing refusal |
| `error` | `code`, `message`; `ref_seq?` | protocol-level refusal |
| `pong` | — | keepalive response |

A `history_page` message is the exported timeline shape and nothing else:
`server_seq`, `role`, `content`, `ts` (RFC 3339, UTC), `media_refs[]`, plus
optional `kind`, `client_msg_id`, `in_reply_to`, and `metadata`. The page also
carries `history_head_seq`. Internal storage columns are never shipped.

A `media_refs[]` entry carries `ref`, `kind`, `mime`, and `size_bytes`, plus
optional `sha256`, `filename`, and `caption`. Every field marked `?` here is
optional by omission: a value the host does not have is an absent key, never an
explicit `null`, so no exported field accepts a null.

## Push notifications (APNs)

Push is the one payload that leaves the socket, so it carries its own
end-to-end encryption. The daemon sends nothing readable to Apple: the alert is
a fixed string and the real content rides in a separate `fx` object that only
the paired device can open, inside the Notification Service Extension.

The per-device key is derived once per notification from the two static
X25519 identities already established by pairing:

```text
shared  = X25519(gateway_static_private, device_static_public)
push_key = HKDF-SHA256(salt: apns_key_salt, ikm: shared, info: "fermix-push-v1", L: 32)
```

`apns_key_salt` is the 32-byte per-device salt stored in `devices.toml`, so two
devices paired to the same gateway never share a key. The device derives the
identical key from its own side as `X25519(device_static_private,
gateway_static_public)`.

The payload is:

```json
{
  "aps": {"alert": {"title": "Fermix", "body": "New message"}, "mutable-content": 1},
  "fx": {"n": "<base64 12-byte nonce>", "c": "<base64 ciphertext||tag>"}
}
```

`fx.c` is ChaCha20-Poly1305 over the JSON object `{"preview_text":…,
"profile_id":…}` with `push_key`, the 12-byte nonce from `fx.n`, **empty**
associated data, and the 16-byte tag appended to the ciphertext. `aps.alert`
never contains conversation content, and `mutable-content: 1` is what lets the
extension replace it after decrypting. The whole APNs JSON is at most 4,096
bytes; when the encrypted preview would exceed that, the daemon sends
`preview_text: null` with a title-only alert rather than truncating content, so
the extension must accept a null preview.

`push_vectors.json` pins one complete example — both static keypairs, the salt,
the shared secret, the derived key, the nonce, the exact inner plaintext, and
the resulting payload — and is generated by an implementation independent of the
daemon's. The extension must reproduce it before shipping.

## Delivery and failure behavior

`msg` and `command` are at-least-once from the phone. The daemon durably claims
`client_msg_id` before replying `accepted`; resends return `accepted` with
`duplicate:true` and never run the turn twice. `ack.server_seq` is a separate,
cumulative acknowledgement of daemon output and must not be used as the outbox
receipt. History is recovered exactly with `history_pull(after_seq)`.

Malformed JSON, an invalid length, an oversized frame/chunk, a sequence gap,
authentication failure, a repeated hello, or a version mismatch fails loudly.
The daemon may emit one typed `error` when an authenticated transport still
exists, then closes. Noise authentication failures close without an application
error because the plaintext cannot be trusted.
