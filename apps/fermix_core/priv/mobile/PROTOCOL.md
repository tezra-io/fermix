# Fermix mobile companion protocol

This is the canonical wire contract between the Fermix daemon and the phone
companion apps. The daemon implementation is `FermixChannels.Mobile.Protocol`
plus `FermixChannels.Mobile.Noise`; the chat events it shares with the Mac's
companion socket are validated by `FermixCore.Companion.Protocol`. A phone app
vendors this directory pinned by checksum; it does not hand-copy event shapes.

| File | What it pins |
|---|---|
| `protocol.schema.json` | every frame header, and the pairing link (`$defs/pairingLink`) |
| `fixtures/client_events.jsonl`, `fixtures/server_events.jsonl` | one golden header per event, and more for the shapes that matter |
| `fixtures/client_binary_frames.jsonl`, `fixtures/server_binary_frames.jsonl` | frames with a raw tail, as `{header, bytes_b64}`, including one whole `event_part` run |
| `fixtures/pairing_links.jsonl` | a pairing link and its decoded fields, as the daemon builds it |
| `noise_vectors.json`, `push_vectors.json` | the Noise handshakes and the push encryption, byte for byte |

**Optional fields are absent, never null.** Every field marked `?` below is
optional by omission: a value the daemon does not have is an absent key, never
an explicit `null`, and no exported field accepts one. The daemon's encoder
refuses a server event with a top-level null, and a fanned-out event it cannot
encode is dropped for that phone, logged, and the session stays up. Unknown
fields are ignored by older peers, so an additive optional field needs no
version bump.

## Transport

The listener serves TLS on its configured port (4031 by default). Its
certificate is the daemon's own, and a phone trusts it by the fingerprint the
pairing link carries (`tls_fp`), not by a certificate authority. It has two
routes and nothing else:

- `GET /healthz` answers `200` with `{"fermix":"mobile","v":<protocol version>}`,
  the version this daemon serves (the schema's `x-protocol-version`).
- `GET /ws` upgrades to the WebSocket every session runs on. A request without
  the upgrade headers is answered `426`. Any other path is `404`.

It speaks HTTP/1.1 only. A connection carries one request: any answer but the
upgrade closes it, so `/healthz` takes a connection of its own.

WebSocket compression is off, and only binary messages are accepted: a text
message closes the connection with `1003`. What the listener bounds:

| Bound | Value | Past it |
|---|---|---|
| Connections at once | 64 | a new connection waits a few seconds for a free slot, then is closed |
| TLS handshake | 10 s | the connection is closed |
| HTTP request before the upgrade | 10 s between reads; a request line of 2,048 bytes, 32 headers of 4,096 bytes each | the connection is closed; an oversized request is answered `414` or `431` first |
| From accept to the upgrade, the TLS handshake included | 15 s | the connection is closed |
| Handshake deadline: the prelude and Noise handshake, then `hello` or `pair_request` | 10 s from the upgrade; a fresh 10 s for the `hello` after `pair_approved` | close `1008` |
| One WebSocket message | 65,535 payload bytes | close `1009` |
| No inbound frame | 150 s | close `1002` |
| One Noise session | 1 hour | close `1000` |
| Memory of a connection that has not said `hello` | 4 MiB, fragments included | the connection is dropped with no close frame |
| Memory of a paired phone's connection | 64 MiB plus 4 × `caps.max_media_bytes` | the connection is dropped with no close frame |

A client pings well inside the 150 s idle bound, during a long download too.

## Stack and bounds

For an established connection the layers are:

1. one WSS binary message (WSS carries the session; it is not the trust anchor);
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

Only `attach_chunk` (client to daemon), `media_chunk` and `event_part` (daemon
to client) carry raw bytes, and theirs is never empty. Every other event must
have an empty raw tail. Binary golden fixtures represent the actual frame as
`{header, bytes_b64}` only so JSONL can store it; that wrapper is not sent on
the wire.

## Continuation frames (`event_part`)

A server event whose JSON header would be over 4,096 bytes (a long reply, a
history page, a `hello_ack` with long candidate names, an error with a long
message) is sent as one run of `event_part` frames instead of one frame:

```json
{"v":1,"t":"event_part","seq":S,"index":I,"count":N}
```

- The run is `N` frames, `2 ≤ N ≤ 18`, with `index` `0` to `N-1` in order and
  consecutive `seq`, and no other frame between them: the daemon encodes the
  whole run before it sends any of it.
- Each frame's raw tail is one slice, at most 60 KiB, of the logical event's
  JSON object text. That object carries `t` and the event's fields, but not
  `v` or `seq`.
- The client concatenates the tails in `index` order, decodes the result, and
  handles it as the event its `t` names, with the run's `v` and its first
  frame's `seq`. That is also how it validates it against the schema.
- The logical event is at most **1 MiB** (1,048,576 bytes, the schema's
  `x-max-event-bytes`). Past it, a `text_done` or `row` text, or the `content`
  of the one message of a `history_page`, is cut on a UTF-8 boundary and
  marked `"truncated": true`; the row in the timeline stays whole. Any other
  event that large is never sent.
- `event_part` is server-only; a client that sends one is refused as an
  unknown event. Any server event can arrive this way, `hello_ack`,
  `pair_approved` and `error` included, except `media_chunk`, whose own tail
  already fills a frame.
- A run that breaks these rules (an index out of order, a `count` that
  changes, another event inside it, a tail missing) is a protocol error the
  client closes on; the daemon never sends one.

`fixtures/server_binary_frames.jsonl` carries a whole two-frame run.

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

`IKpsk2` uses the 32-byte one-time secret of the pairing link as its PSK and
the link's `gateway_pk` as the responder's static key. After a successful
pairing handshake both sides show a six-digit SAS derived exactly as follows:

1. `digest = HMAC-SHA256(key: handshake_hash, data: "fermix-mobile-sas-v1")`
2. read the first four digest bytes as an unsigned big-endian integer;
3. reduce modulo 1,000,000 and zero-pad to six decimal digits.

A pairing session runs in this order:

1. The phone sends `pair_request` (`seq` 1) within the handshake deadline, 10 s
   after the upgrade. A peer that finishes the handshake and sends nothing is
   closed with `1008`, and that counts as a failed pairing attempt from its
   address.
2. The owner compares the SAS and decides. A pairing window lasts at most 120
   seconds. While the owner decides, the daemon answers `ping` with `pong` and
   refuses every other event, so a keepalive never has to stop; an idle
   disconnect while a decision is pending is not a failed pairing handshake.
3. Approved: `pair_approved{device_id, candidates[], profiles[]}`. The phone
   then sends `hello` on the same session (its next `seq`) within a fresh 10 s,
   and the session goes on as a paired one.
4. Not approved: `pair_denied{reason}`, then close `4003` with the text
   `pairing <reason>`. `reason` is one word, the one the management protocol
   uses for the same ending: `denied` (the owner said no), `timeout` (the
   window ran out), `cancelled` (the owner closed the window) or
   `device_disconnected` (the phone was gone when the owner approved).

Failed pairing attempts are counted per source address. An address's fifth
failure refuses that address for the rest of the window: its next handshake is
closed with `1002` before any Noise state exists. Failures never close the
window, so nobody but the owner can end one, and nothing is counted while a
request waits for the owner. A window remembers at most 1,024 addresses; a
failure from another address is not counted. A `pair_request` from the same
phone key as the one waiting replaces it, and the older socket is closed with
`4001`. A phone that was approved but never said `hello` can pair again.

The shared deterministic `noise_vectors.json` pins X25519 keys, both handshake
messages, handshake hashes, SAS values, and the first transport ciphertext for
both patterns. Private keys in that file are test material only.

After a paired `IK` handshake, the daemon authorizes the authenticated initiator
static against `devices.toml`; a key it does not hold is closed with `1002`.
Noise transport nonces and the application sequence both restart on every new
session. Each direction performs a deterministic Noise REKEY after exactly 2^20
frames, replacing only that direction's key while
preserving that direction's current transport nonce. The one-hour session
lifetime closes and reconnects with a fresh handshake. A peer
never performs a unilateral time-based rekey.

## Pairing link

The owner's QR code, and the `uri` of the management protocol's
`mobile.pair.start`, carry one link:

```text
fermix://pair?v=1&candidates=<JSON array>&port=<port>&tls_fp=<hex>&gateway_pk=<base64>&secret=<base64>&name=<name>
```

The query is `application/x-www-form-urlencoded`: a space is `+`, and a `+`,
`/` or `=` of base64 is percent-encoded, so a phone decodes it with a form
decoder. An unknown parameter is ignored, so the link can gain one.

| Parameter | Value |
|---|---|
| `v` | `1`, this link format |
| `candidates` | a JSON array of at most 16 hosts to try, best first: tailnet MagicDNS names, then tailnet addresses, then private LAN addresses. Like `hello_ack`'s, it keeps the best 16 of what the host finds; unlike them, these carry no interface or scope. |
| `port` | the listener's TCP port, in decimal |
| `tls_fp` | the SHA-256 of the listener's TLS certificate (DER), 64 lowercase hex digits; the phone pins it |
| `gateway_pk` | the gateway's X25519 static public key, 32 bytes, standard base64 with padding |
| `secret` | the one-time 32-byte pairing PSK, standard base64 with padding |
| `name` | the host's name, for the phone to show |

The phone connects to `wss://<candidate>:<port>/ws`, trusts the certificate
whose SHA-256 is `tls_fp`, and runs `IKpsk2` against `gateway_pk` with
`secret`. The link is good while its window is open, at most 120 s, and only
once. It is shown on the call that opens the window and never logged,
traced or kept. `fixtures/pairing_links.jsonl` pins a link the daemon built,
with its decoded fields; its secret and keys are test material only.

## Envelope, ordering, and version negotiation

Every JSON header has these required fields:

```json
{"v":1,"t":"event_name","seq":1}
```

- `v` is the event schema version.
- `t` is a closed event name. An unknown value receives an `unsupported` error;
  it is never silently ignored.
- `seq` is an unsigned 64-bit integer. It starts at 1, increases by exactly one
  per sender within a Noise session, and resets only with a new session. An
  `event_part` frame takes one `seq` like any other frame. The codec validates
  its range; the socket owner validates ordering.
- Unknown payload fields are preserved and ignored by older peers, so additive
  optional fields do not require a version bump.

The first encrypted event in a paired session is `hello` and its `seq` is 1.
`hello.protocol_v` must equal the envelope `v`, and every later frame of the
session carries the same `v`. The daemon replies with `hello_ack` containing
`min_version` and `max_version`. The supported window is **N/N-1**: the current
protocol and previous protocol (or just 1 before a second version exists). No
other event is serviced before hello and a second hello is terminal.

A `hello` or `pair_request` whose `v` is outside the window is answered with a
typed refusal, then close `1002` with the text `unsupported mobile protocol
version`. The refusal is encoded at the daemon's own version, `seq` 1:

```json
{"v":1,"t":"error","seq":1,"code":"unsupported_protocol_version","message":"…","direction":"client_too_new","client_version":2,"min_version":1,"max_version":1}
```

`direction` is `client_too_old` (the app must update) or `client_too_new`
(Fermix must update). It is never counted as a failed pairing attempt.

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
| `command` | `client_msg_id`, `profile_id`, `name`; `args?` | uses the normal command registry; `name` is lowercase letters, digits and `_` |
| `cancel` | `profile_id`, `client_msg_id` | stops that request's turn, running or waiting, and no other; never answered |
| `history_pull` | `profile_id`, `after_seq`, `limit` | limit is 1–200; `after_seq` is any unsigned 64-bit value |
| `media_fetch` | `ref` | re-download a content-addressed blob |
| `push_register` | `apns_token`, `environment` | environment is `development` or `production` |
| `ack` | `server_seq` | cumulative socket-delivery cursor |
| `read_state` | `profile_id`, `read_up_to_seq` | monotonic read frontier |
| `pair_request` | `device_name`, `model`, `app_version` | first event inside an IKpsk2 pairing session; each field is ≤128 bytes of valid UTF-8 and must contain no C0/C1/DEL control characters |
| `unpair` | — | best-effort self-removal; host CLI remains authoritative |
| `ping` | — | keepalive |

`profile_id` is `main`, the one profile; any other is refused with
`unsupported_profile`.

What each is answered with:

| Client event | Answer |
|---|---|
| `hello` | `hello_ack`, then every approval still waiting (see *Approvals*) |
| `msg`, `command` | `accepted`, then the request's rows and turn; `error{client_msg_id}` if it fails |
| `attach_begin` | `attach_status{status:"upload"}`, or `attach_status{status:"present"}` when the digest is already stored |
| `attach_chunk` | nothing; a refused chunk is an `error` |
| `attach_end` | `attach_status{status:"present"}` once size and digest check out |
| `cancel`, `ack`, `push_register` | nothing; a refused one is an `error` |
| `read_state` | the frontier as `read_state`, to every client of the profile, this one included |
| `history_pull` | `history_page` |
| `media_fetch` | the blob as `media_begin`, `media_chunk`s and `media_end`, or an `error` naming its `ref` |
| `unpair` | close `4003` |
| `ping` | `pong` |

A client must not upload chunks after `present`.

## Server events

| `t` | Required payload | Rules |
|---|---|---|
| `hello_ack` | `session_id`, `min_version`, `max_version`, `profiles[]`, `candidates[]`, `history_head_seq`, `read_up_to_seq`, `caps{}` | completes hello negotiation |
| `accepted` | `client_msg_id`, `duplicate`; `server_seq?` | durable receipt for a `msg` or `command`; clears the outbox item |
| `attach_status` | `attach_id`, `status` | status is `upload` or `present` |
| `turn_started` | `profile_id`, `turn_id`, `in_reply_to` | begins streamed draft |
| `text_delta` | `turn_id`, `text` | streamed delta |
| `tool_event` | `turn_id`, `tool`, `phase`; `detail?` | phase is `start` or `stop`; detail ≤512 bytes |
| `text_done` | `turn_id`, `server_seq`, `text`; `truncated?` | canonical final text at its row |
| `media_begin` | `ref`, `server_seq`, `kind`, `mime`, `size_bytes`, `sha256`; `filename?`, `caption?` | starts outbound media |
| `media_chunk` | `ref`, `index` + raw bytes | contiguous zero-based indexes; raw bytes ≤60 KiB |
| `media_end` | `ref`, `sha256` | completes outbound media |
| `turn_error` | `turn_id`, `code`, `message` | terminal turn failure; message ≤512 bytes |
| `row` | `profile_id`, `server_seq`, `role`, `text`, `ts`, `media_refs[]`; `kind?`, `client_msg_id?`, `in_reply_to?`, `metadata?`, `link_previews[]?`, `truncated?` | a timeline row this client did not stream |
| `reaction` | `in_reply_to`, `emoji` | reacts to a client message id |
| `approval` | `approval_id`, `kind`, `text`, `token`, `ttl_s`, `approve_command`, `deny_command`; `detail?` | command routes are nonempty and at most 1,024 characters; token is submitted but never rendered |
| `approval_resolved` | `approval_id`, `outcome` | approved, denied, or expired |
| `link_preview` | `in_reply_to`, `url`, `site`, `title`; `description?`, `image_ref?` | host-resolved preview of the row at `in_reply_to` |
| `read_state` | `profile_id`, `read_up_to_seq` | the frontier, after any client moved it |
| `history_page` | `profile_id`, `messages[]`, `next_after_seq`, `history_head_seq` | exact server-sequence cursor page |
| `notice` | `kind`, `text` | reserved: in the catalog, never sent yet |
| `pair_approved` | `device_id`, `candidates[]`, `profiles[]` | completes pairing |
| `pair_denied` | `reason` | terminal pairing refusal |
| `error` | `code`, `message`; `client_msg_id?`, `ref?`, `direction?`, `client_version?`, `min_version?`, `max_version?` | a refusal; message ≤512 bytes; see *Errors* |
| `pong` | — | keepalive response |
| `event_part` | `index`, `count` + raw bytes | one frame of a longer event; see *Continuation frames* |

`accepted.server_seq` is present only on a duplicate whose request already has
a reply row: that reply's seq. A first `accepted` never carries it.

`hello_ack.candidates[]` and `pair_approved.candidates[]` hold at most 16
routes for later reconnects, best first: `{host, interface, scope}`, where
`host` is an address or a MagicDNS name of at most 253 bytes and `scope` is
`lan` or `tailnet`. `profiles[]` is `{id, name}`, the name at most 128 bytes.
`caps` carries `commands[]` (`{name, aliases[], description}`, the command
palette), `media`, `streaming` and `max_media_bytes`, the largest attachment
the daemon takes. A `hello_ack` with 16 numeric candidates and the whole
command catalog fits one frame; one whose candidates are long MagicDNS names
arrives as an `event_part` run.

`error.ref_seq` is reserved: the schema names it, and the daemon never sends
it.

### Timeline shapes

A `history_page` message is the exported timeline shape and nothing else:
`server_seq`, `role`, `content`, `ts` (RFC 3339, UTC), `media_refs[]`, plus
optional `kind` (`text` or `media`), `client_msg_id`, `in_reply_to`,
`metadata`, `link_previews[]` and `truncated`. Internal storage columns are
never shipped, and `metadata` never holds a null.

A `media_refs[]` entry carries `ref`, `kind`, `mime`, and `size_bytes`, plus
optional `sha256`, `filename`, and `caption`.

A `link_previews[]` entry is a preview stored on its row, as `link_preview`
sent it: `url`, `site`, `title`, and optional `description` and `image_ref`. A
row carries at most 4, and has the key only when it has one.

A `row` is the same message with `text` in place of `content`, plus
`profile_id`. It is the companion socket's `row` event, which on that wire
carries only `server_seq`, `role`, `text`, `ts` and `client_msg_id`; on this
wire it carries the whole message, so a phone shows a row it did not write as
a history page would.

## One timeline

The profile's timeline is one, shared by every phone and by the Mac's
companion socket (`priv/companion/`): its rows, `server_seq` numbering and read
frontier are the same whoever reads them. `server_seq` is assigned inside the
write that stores the row, from a per-profile counter that never goes back; the
daemon never renumbers or reorders a row.

Every row is announced live to every connected phone as it is written:

- a reply written on the phone channel, as a `text_done` at its row, to every
  phone: the reply of a turn a phone started, the answer to a phone's slash
  command, and what the daemon delivers there on its own (a scheduled job, a
  reminder, a background command's result). Its `turn_id` may be one no
  `turn_started` announced. A media reply arrives as `media_begin`…`media_end`;
- every other row as a `row`: a user's message from any phone or the Mac (the
  sender's own included, with its `client_msg_id`, to match its outbox), the
  reply of a turn the Mac started, and every other row written for the Mac.

A client keeps a cursor, the last `server_seq` it shows, and:

- pulls `history_pull{after_seq: cursor}` after every `hello_ack`, and again
  while a page's `next_after_seq` is below its `history_head_seq`;
- applies a live row (a `row`, or a `text_done` at its `server_seq`) when its
  seq is `cursor + 1`, drops one at or below the cursor, and on a gap pulls
  from the cursor instead of showing it;
- never keys the cursor on arrival order.

A row can change after it was announced: a voice note's transcript replaces
its text once transcription finishes, and no event says so yet. A client that
shows a voice note from a live `row` refreshes it from history
(`history_pull{after_seq: seq - 1, limit: 1}`).

### History pages

`history_pull{after_seq, limit}` answers the rows after `after_seq`, oldest
first. A page holds at most `limit` rows and at most 256 KiB of them, so it
can hold fewer than asked; it always holds at least one row when there is
one. `next_after_seq` is the last row sent, or `after_seq` itself on an empty
page, and `history_head_seq` is the newest row. A cursor above 2^63-1 (the
largest row number the store holds) is one past every row: the page is empty
and echoes it. A page over 4,096 bytes arrives as an `event_part` run; a row
whose own content passes 1 MiB arrives alone, cut and marked `truncated`.

### Read state

`read_state{read_up_to_seq}` from any client moves the profile's frontier
forward and never past the newest row: the daemon stores
`min(max(stored, reported), history_head_seq)` and sends the result as
`read_state` to every client of the profile, on both transports. A frontier
stored past the newest row earlier comes back to it on the next report.

## Streaming a turn

A `msg` or `command` that becomes a turn streams to every phone of the
profile. `turn_started{profile_id, turn_id, in_reply_to}` opens it
(`turn_id` is `turn-` followed by the request's `client_msg_id`), and
`text_delta` carries the reply as it is written: from its first character, at
most every 100 ms, with no cap on how many. `tool_event` reports each tool's
`start` and `stop`. A route that does not stream sends no `turn_started` or
`text_delta`, only the ending.

A turn ends on the wire exactly once:

- it completed: its reply is written to the timeline and sent as `text_done`
  at its row;
- it was cancelled or failed: one `turn_error` whose `code` is `cancelled`,
  `interrupted` (the daemon lost the turn), a failure's own word, or
  `turn_failed`, and whose message is at most 512 bytes;
- a request whose hand-off to the turn queue failed also ends in
  `turn_error`, not `error`.

A turn's stream and its ending stay with the transport that ran it: a turn
started on the Mac reaches phones only as the `row` of its reply.

`cancel{profile_id, client_msg_id}` names the request whose turn to stop,
whichever client sent it and whether it runs or still waits; it never stops
another turn, and the daemon never answers it. It is recorded on the request
first, so a cancel that arrives after `accepted` but before the request reached
the turn queue is not lost: the request is never queued, ends with
`turn_error{code:"cancelled"}`, and is not run again after a restart. A turn
that had already finished ends with its `text_done`, and a cancel for a request
that already ended changes nothing.

## Approvals

When a tool needs the owner's approval, the daemon sends `approval`. Its
`kind` is `sandbox` or `soul`. The client answers by sending one of the routes
as a `command`: drop the leading `/`, the first word is `name` and the rest is
`args`. `/confirm TOKEN` is `command{name:"confirm", args:"TOKEN"}`, and
`/soul apply TOKEN` is `command{name:"soul", args:"apply TOKEN"}`. The token is
submitted, never rendered.

- A card belongs to the transport whose turn raised it, the only one its token
  resolves from: a phone's turn's card goes to phones only, and a Mac's to the
  Mac only. Its re-send, expiry and resolution go to that transport too.
- `approval_resolved{approval_id, outcome}` withdraws it: `approved` or
  `denied` when the owner answered, `expired` when its `ttl_s` ran out.
- Right after `hello_ack`, in the same push, the daemon sends again every card
  of the profile still waiting that phones raised, oldest first, each with
  `ttl_s` set to the seconds it has left, rounded up. A client keys cards by
  `approval_id`, so a card it already shows is replaced, not doubled.
- When `hello_ack` arrives, a client drops every card it shows and keeps only
  the ones the daemon sends after it. `approval_resolved` goes only to the
  connections open when a card is answered or expires, so a card that ended
  while the phone was away is never withdrawn: it is simply not sent again.
- Waiting cards live in the daemon's memory, as their tokens do: a restart
  forgets them without resolving them, so a client also drops a card when its
  own `ttl_s` runs out. The daemon keeps at most 64; past that a card still
  goes out live but is not sent again, so a reconnect drops it.
- A card a phone's turn raises while no phone of the profile is connected also
  sends each registered phone a push with no content (see *Push
  notifications*).

## Attachments

`attach_begin` announces a blob before its bytes. The daemon answers
`attach_status{status:"upload"}`, or `present` when it already holds that
digest, and then takes `attach_chunk`s from index 0, each at most 60 KiB,
until `attach_end`, which it answers `present` once the size and SHA-256 match.
A blob is at most `caps.max_media_bytes`. A zero-byte blob announced with the
SHA-256 of the empty string is `present` at once, with no chunks and no
`attach_end`; announced with any other digest it is refused
(`sha256_mismatch`).

At most 4 uploads run at once on one connection (`upload_limit_reached`) and
16 in the daemon (`store_upload_limit_reached`). An upload is refused when its
size and the uploads already running would pass the media store's quota
(`store_quota_exceeded`); it never evicts stored media to make room. A
connection that closes takes its unfinished uploads with it.

A `msg`'s `attach_ids` name blobs by the `attach_id` of their `attach_begin`.
An id lasts 48 hours; a blob keeps its 8 newest ids, and the daemon its 4,096
newest. A `msg` naming an id past that fails as a request
(`error{code:"attachment_unavailable", client_msg_id}`).

## Media downloads

`media_fetch{ref}` downloads a blob a row names: any `ref` of its
`media_refs[]`, or the `image_ref` of one of its link previews. Blobs are
served one at a time, first in, first out, and up to 8 fetches wait; one more
is refused at once with `error{code:"media_fetch_backlog_full", ref}`, naming
the fetch it refuses.

A blob streams as `media_begin`, its `media_chunk`s (indexes from 0, each at
most 60 KiB) and `media_end`, one chunk a step: other frames, `pong`
included, can arrive between them, but one blob's frames stay in order and two
blobs never mix. The daemon checks the size and SHA-256 as it streams: a blob
that no longer matches its row ends with `error{code:"media_descriptor_mismatch",
ref}` in place of `media_end`, and the client discards what it received. A
fetch that cannot start is `error{code, ref}`, such as `not_found` or
`media_gone`.

A media reply is sent to every phone the same way, as it is written, with no
`media_fetch`.

## Link previews

After a row with links is written, the daemon may resolve previews for it,
store each on the row, and only then send it as
`link_preview{in_reply_to, url, site, title, description?, image_ref?}`, where
`in_reply_to` is the row's `server_seq`. From then on the row's history
carries it in `link_previews[]`.

- `site` is at most 120 bytes, `title` 300 and `description` 600, cut on a
  UTF-8 boundary; a `url` over 2,048 bytes is no preview at all.
- A row gets at most 4. Resolving them has a 20 s deadline for the whole row,
  and at most 4 rows resolve at once; past either, no preview.
- `image_ref` is served by `media_fetch`; it never appears in `media_refs[]`.

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

An approval waiting while no phone of the profile is connected sends each
registered phone a notification with no content at all: the alert is
`{"title": "Fermix", "body": "Approval needed"}` and the encrypted object is
`{"preview_text": null, "profile_id": …}`. Nothing is pushed while a phone of
the profile is connected, or when push is off.

`push_vectors.json` pins one complete example — both static keypairs, the salt,
the shared secret, the derived key, the nonce, the exact inner plaintext, and
the resulting payload — and is generated by an implementation independent of the
daemon's. The extension must reproduce it before shipping.

## Delivery and failure behavior

`msg` and `command` are at-least-once from the phone. The daemon durably claims
`client_msg_id` before replying `accepted`; resends return `accepted` with
`duplicate:true` and never run the turn twice. The same `client_msg_id` with
different content is refused with `client_message_conflict`. A request the
daemon accepted but could not finish because it stopped is run again when it
next starts; claims last 24 hours. A request that failed stays failed: its
resend is a duplicate and never runs again. `ack.server_seq` is a separate,
cumulative acknowledgement of daemon output and must not be used as the outbox
receipt. History is recovered exactly with `history_pull(after_seq)`.

One connection runs one request at a time, in the order sent, and holds at
most 32 waiting (`request_backlog_full`). A request that fails after
`accepted` is answered `error{code, message, client_msg_id}`, addressed to the
device, so the socket that replaced the one that sent it gets it; its message
is at most 512 bytes. A `msg` or `command` that runs a command answering later
(`/background` and `/bg`, `/skills review`, `/skills approve`) stays running
until the command reports, and its later answer is that request's output.

Revoking a phone (`fermix devices revoke`, the management protocol, or its own
`unpair`) closes its socket with `4003`, cancels every request it sent that
has not ended and stops their turns; none is run again after a restart.

Malformed JSON, an invalid length, an oversized frame/chunk, a sequence gap,
authentication failure, a repeated hello, or a version mismatch fails loudly.
The daemon may emit one typed `error` when an authenticated transport still
exists, then closes. Noise authentication failures close without an application
error because the plaintext cannot be trusted.

## Errors

`error.code` is the refusal's own word when the daemon has one, and
`request_failed` for a failure only the daemon can explain; a client branches
on `code`. `message` describes it for logs, is at most 512 bytes and is never
parsed.

| `code` | When | Context | Connection |
|---|---|---|---|
| `unsupported` | an unknown `t` once paired, `event_part` from a client included | — | closed `1002` |
| `repeated_hello` | a second `hello` | — | closed `1002` |
| `unsupported_protocol_version` | a `hello` or `pair_request` outside the version window | `direction`, `client_version`, `min_version`, `max_version` | closed `1002` |
| `request_failed`, `client_message_conflict`, `unsupported_profile` | a request refused or failed after `accepted`, or any refusal with no word of its own | `client_msg_id` for a `msg` or `command` | open |
| `attachment_unavailable` | a `msg` naming an `attach_id` the daemon no longer holds | `client_msg_id` | open |
| `invalid_field`, `missing_field` | a field the daemon refuses once the frame decoded, such as a `msg`'s `attach_ids` | `client_msg_id` for a `msg` or `command` | open |
| `unsupported_event` | a known event the paired socket does not take, such as `pair_request` | — | open |
| `request_backlog_full` | 32 requests already waiting | — | open |
| `media_fetch_backlog_full` | 8 fetches already waiting | `ref` | open |
| `media_descriptor_mismatch`, `not_found`, `media_gone` | a `media_fetch` that failed | `ref` | open |
| `upload_limit_reached`, `store_upload_limit_reached`, `upload_exists`, `attachment_exists`, `unknown_upload` | an upload refused | — | open |
| `store_quota_exceeded`, `media_too_large` | an upload that would pass the media store's quota or the largest blob | — | open |
| `unexpected_chunk`, `size_exceeded`, `size_mismatch`, `sha256_mismatch`, `announced_hash_mismatch` | an upload whose chunks, size or digest differ from its `attach_begin`, or a zero-byte one announced with another digest | — | open |
| `push_environment_mismatch` | a token for the other APNs environment | — | open |

Every other failure a frame can be refused with is closed `1002` with no
`error`: malformed JSON or framing, a sequence gap or replay, a frame whose `v`
differs from the session's, an event before `hello`, and a frame from a socket
the device has since replaced.

## Close codes

| Code | Why | Client |
|---|---|---|
| `1000` | the one-hour session lifetime ran out (`Noise session lifetime reached`), or the daemon is shutting down | reconnect with a new handshake |
| `1002` | a protocol error (`mobile protocol error`, `invalid mobile prelude`, `unsupported mobile protocol version`), no inbound frame for 150 s, or a malformed WebSocket frame | reconnect; after `unsupported_protocol_version`, update first |
| `1003` | a text message | send binary messages |
| `1008` | the handshake deadline (`mobile handshake deadline`) | reconnect |
| `1009` | a message over 65,535 bytes (`mobile frame too large`) | never send one |
| `1011` | the daemon's socket failed | reconnect |
| `4001` | `connection replaced`: a newer connection of the same phone, or a pairing request from the same phone key | do not reconnect this connection; the newer one is live |
| `4003` | `device revoked`, `pairing <reason>` after `pair_denied`, or `authenticated device mismatch` (the `hello` named another device) | do not reconnect with this identity until it pairs again |

A connection past its memory bound is dropped with no close frame.
