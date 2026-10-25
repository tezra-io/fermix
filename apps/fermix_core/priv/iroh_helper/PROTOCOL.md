# Fermix iroh helper protocol

The wire contract between the Fermix daemon and the `fermix-iroh` helper, the
Rust program that runs the daemon's one iroh endpoint so a paired phone can reach
the daemon from any network (M62). The helper accepts iroh connections and
bridges each accepted stream to a Unix socket the daemon listens on; it holds no
trust of its own and decides nothing.

**Source of truth:** the daemon's codec, `FermixChannels.Mobile.Iroh.HelperProtocol`,
and its bridge listener, `FermixChannels.Mobile.Iroh.Bridge`. This file and `fixtures/*`
are the machine-readable export of those modules, and the daemon's contract test
asserts they never drift from it. The `tezra-io/fermix-iroh` repository **vendors
this file and the fixtures** and tests its own codec against them. Fermix defines
the protocol; the helper implements it.

## Roles

- **The daemon** creates and owns the iroh secret key, holds the relay list,
  listens on the bridge socket, and makes every authorization decision through
  the mobile protocol's Noise session (`../mobile/PROTOCOL.md`).
- **The helper** binds one iroh endpoint with that key and the relays the daemon
  names, accepts connections on one ALPN, and copies each accepted bidirectional
  stream to one connection on the bridge socket. It binds UDP sockets for QUIC,
  asks the local router for a port mapping, and probes only the relays the
  daemon named; it opens no listener and contacts no other host. It reads no
  file but the key and the system's resolver configuration (to resolve the
  relays' names), resolves through the system's nameservers only, never a
  public resolver, and uses no address lookup service. Proxy variables in its
  environment have no effect: it never calls iroh's `proxy_from_env`, and it
  removes them from its own environment before anything reads them, since
  iroh's relay probes would otherwise honour them.

## Process

- The daemon spawns the helper as an Erlang Port in its own process group (on
  macOS through the `disclaim` exec shim) and is its only parent. The helper is
  started with no arguments and reads everything it needs from `start`.
- **Control channel:** the helper's stdin and stdout. **stderr is not part of the
  channel**; the daemon does not read it. Diagnostics the daemon should keep
  travel as `log` events.
- End of stdin is a `shutdown`. The helper exits `0` after a shutdown, and `1`
  within **2 s** of sending an `error` event. An exit `1` with no `error` before
  it, any other exit code (a Rust panic is `101`), or no `hello` within 10 s is a
  crash to the daemon.

## Control framing

**NDJSON**: one compact JSON object per line, UTF-8, `\n`-terminated, in both
directions. A line is at most 64 KiB; a longer line, a line that is not a JSON
object, an unknown `op` or `event`, or a field of the wrong type is a protocol
error, and the side that sees it ends the helper. Frames the helper sends carry
`"event"`; frames the daemon sends carry `"op"`.

## Versioning

A single integer, `protocol_version`, currently **2**. The helper declares it in
`hello`; the daemon refuses any other value and ends the helper. There is no
negotiation: the helper is bundled with, and pinned by, the engine release that
speaks its version, and both halves move together. The daemon also compares
`iroh_version` with the iroh version its built-in relay source names and ends a
helper that differs, so a release that moved one without the other fails loudly
(M62 §8).

Version 2 adds the `close` op.

## Sequence

```
helper                                   daemon
  hello ────────────────────────────────▶   (within 10 s of spawn)
        ◀──────────────────────────────── start
  ready ────────────────────────────────▶   (the endpoint is bound)
  relay ────────────────────────────────▶   (whenever the home relay changes)
  path  ────────────────────────────────▶   (a connection opens or changes path)
  closed ───────────────────────────────▶   (a connection ends)
  refused ──────────────────────────────▶   (a connection or stream is refused)
        ◀──────────────────────────────── set_relays   (any time after ready)
        ◀──────────────────────────────── close        (a session ended before hello or a pair request)
  log   ────────────────────────────────▶   (any time after hello)
        ◀──────────────────────────────── shutdown
```

## Events the helper sends

```json
{"event":"hello","protocol_version":2,"helper_version":"0.2.0","iroh_version":"1.3.0"}
{"event":"ready","endpoint_id":"79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"}
{"event":"relay","home_relay":"https://us1.relay.fermix.ai/","connected":true}
{"event":"path","endpoint_id":"79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664","kind":"relay","relay":"https://us1.relay.fermix.ai/"}
{"event":"closed","endpoint_id":"79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"}
{"event":"refused","reason":"busy","endpoint_id":null}
{"event":"log","level":"warn","message":"bridge socket refused the connection"}
{"event":"error","code":"key_invalid","message":"key file mode is 0644, not 0600"}
```

| Event | Fields | Meaning |
|---|---|---|
| `hello` | `protocol_version`, `helper_version`, `iroh_version` | The first line, within **10 s** of spawn. |
| `ready` | `endpoint_id` | The endpoint is bound with the key from `start`. `endpoint_id` is the lowercase hex of the key's Ed25519 public key (iroh's own display form); the daemon checks it against its own derivation from the same key and ends a helper that disagrees. Sent once. |
| `relay` | `home_relay` (a URL, or `null` before one is chosen), `connected`; `error?` | The endpoint's home relay and whether it is connected, sent after `ready` and whenever either changes. iroh reports home relays as a list; `home_relay` is the connected entry, else the first. `error` is the first line of iroh's error text, at most 512 bytes, with any `user:password@` removed from URLs: relay-influenced text the daemon logs and never matches on. |
| `path` | `endpoint_id`, `kind` (`relay` or `direct`), `relay` (a URL, or `null` for a direct path) | A connection's selected path, sent when the connection opens and whenever its selected path changes. `endpoint_id` is the peer's: per phone process, since a phone makes a new iroh key on each launch. For the Phone sheet's route line and the speed measurement (M62 §3.2, D5). |
| `closed` | `endpoint_id` | A connection that had a `path` ended, however it ended. Sent once per connection, after its last `path`; the daemon forgets that peer's path. |
| `refused` | `reason`, `endpoint_id` (hex, or `null` where it is not known) | A connection or stream the helper refused: `busy` (over `limits.max_connections`, refused before its handshake, so `endpoint_id` is `null`), `alpn` (no matching application protocol), `bridge_unreachable` (the bridge socket could not be reached for a stream). The daemon counts these toward its admission bound and per-peer accounting; it never parses `log` text. |
| `log` | `level` (`info` or `warn`), `message` | A diagnostic for the daemon's log, at most 512 bytes. The daemon logs it and never matches on it. Never key material, never stream contents. |
| `error` | `code`, `message` | Fatal: the helper exits `1` after sending it. `code` is one of `bad_request` (a malformed or out-of-order `op`, one with an unknown or missing field, or a `start` whose values the helper refuses), `key_unreadable`, `key_invalid`, `bind_failed`, `internal`. `message` is at most 512 bytes. The daemon restarts a helper that failed, except after `bad_request` or `key_invalid`, which the same `start` would get again. |

## Ops the daemon sends

```json
{"op":"start","secret_key_path":"/Users/owner/.fermix/mobile/iroh_key","bridge_socket":"/Users/owner/.fermix/mobile/bridge.sock","alpn":"fermix/mobile/1","relays":[{"url":"https://us1.relay.fermix.ai/","quic_port":7842},{"url":"https://eu1.relay.fermix.ai/","quic_port":7842}],"limits":{"max_connections":64,"max_streams_per_connection":4,"stream_receive_window":262144,"connection_receive_window":1048576,"send_window":1048576}}
{"op":"set_relays","relays":[{"url":"https://us1.relay.fermix.ai/","quic_port":7842},{"url":"https://eu1.relay.fermix.ai/","quic_port":7842}]}
{"op":"close","endpoint_id":"79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"}
{"op":"shutdown"}
```

| Op | Fields | Meaning |
|---|---|---|
| `start` | `secret_key_path`, `bridge_socket`, `alpn`, `relays`, `limits` | Exactly once, after `hello`. The helper reads the key, binds the endpoint and answers `ready`, or `error`. |
| `set_relays` | `relays` | Replaces the endpoint's relay map at run time: relays not named are removed, new ones added. Valid only after `ready`. |
| `close` | `endpoint_id` (lowercase hex) | A session on a stream from this peer ended, for any reason, before it was a paired phone's session or a pairing request: in the prelude, in the Noise handshake, or before `hello` or the pair request (`../mobile/PROTOCOL.md`), the phone's own ending of the stream included. The helper bridges no further stream from the peer's connections, resetting each new one with application code `0`, and closes each connection with code `0`, reason `refused`, once every stream it bridges on it has ended and the peer has acknowledged what the daemon wrote on it, so the daemon's close frame reaches the phone first. It waits at most **5 s** for that acknowledgement after a stream ends. Valid only after `ready`; a peer with no connection is not an error. |
| `shutdown` | — | Stop accepting; close every connection with application code `0`, reason `shutdown` (iroh's `Endpoint::close` alone sends an empty reason; a connection still in its handshake cannot carry a reason and is closed without one); close every bridge connection; wait for iroh's drain, bounded by its own timeout; exit `0` within **5 s**. The daemon kills the process group after that. This is also how the daemon turns remote reach off: after the exit nothing contacts a relay. |

- **`secret_key_path`:** an absolute path to a file of exactly 32 bytes, the raw
  Ed25519 secret key, mode `0600`. The daemon writes it atomically before the
  first `start` and never changes it. Any other size or mode is `key_invalid`;
  a file that cannot be opened is `key_unreadable`. The helper never writes it.
- **`bridge_socket`:** an absolute path to the daemon's bridge socket (below).
- **`alpn`:** the one application protocol the endpoint accepts, `fermix/mobile/1`.
  A connection that offers no matching ALPN is refused in the TLS handshake,
  before anything reaches the daemon.
- **`relays`:** one to eight entries, each an `https` relay URL and its QUIC
  address-discovery port. These are the only relays the endpoint uses. The
  endpoint uses no address lookup service, so it never publishes to or resolves
  through a third party.
- **`limits.max_connections`:** concurrent iroh connections, 1 to 1,024,
  handshaking ones included. A connection over the bound is refused before its
  handshake (iroh's `Incoming::refuse`), so it costs no key exchange, and
  reported as `refused` `busy`. No connection holds a place for nothing: a
  handshake not finished within **10 s** is dropped, a connection that has had
  no stream for **30 s** is closed with code `0`, reason `idle`, the
  connections of a peer whose session ended before `hello` or a pair request
  are closed on the daemon's `close`, so opening stream after stream that fails
  its handshake keeps no place, and once half the places are taken a new peer
  whose address QUIC has not validated is sent a Retry first, so forged
  packets never take one.
- **`limits.max_streams_per_connection`:** concurrent bidirectional streams on one
  connection, 1 to 16, applied as the connection's QUIC bidirectional stream
  credit: a peer past it waits for a stream to close; the helper neither sees
  nor reports the attempt. A phone opens one stream per session; a renewal opens
  the next before the last has closed.
- **`limits.stream_receive_window`, `limits.connection_receive_window`,
  `limits.send_window`:** bytes, each 65,536 to 16,777,216, applied through
  iroh's QUIC transport configuration. They are QUIC's own flow-control windows,
  so they bound what an unauthenticated peer can make the helper hold before any
  byte reaches the daemon.

## The bridge

The daemon listens on a Unix-domain stream socket at `bridge_socket`, mode
`0600`. For each bidirectional stream it accepts, the helper opens one
connection to that socket.

**Preamble.** The helper's first 37 bytes on a bridge connection:

| Offset | Bytes | Value |
|---|---|---|
| 0 | 4 | `46 58 42 31`, ASCII `FXB1` |
| 4 | 1 | the peer's kind: `01`, a phone (connections on `fermix/mobile/1`) |
| 5 | 32 | the peer's iroh endpoint id, raw |

The daemon reads exactly 37 bytes within **5 s** of accept and closes a
connection whose magic or kind it does not know. The endpoint id is accounting
metadata (pairing-failure rate accounting, logs), never authorization: a peer is
authorized only by its Noise static key.

**After the preamble** the helper copies bytes unchanged in both directions
between the iroh stream and the bridge connection, with a bounded buffer of
64 KiB each way, until either side ends. It does not parse them: they are the
mobile protocol's iroh carrier frames, which the daemon parses and bounds
(`../mobile/PROTOCOL.md`).

**Ending.**

- When the peer finishes its side of the stream, the helper shuts down the write
  half of the bridge connection; the daemon reads end of file.
- When the daemon closes the bridge connection, the helper finishes its side of
  the stream and stops reading it.
- When the peer resets the stream, or the iroh connection is lost, the helper
  closes the bridge connection.
- When the bridge socket cannot be reached, the helper resets the stream with
  application code `2` and reports `refused` `bridge_unreachable`; it does not
  retry.

The daemon bounds concurrent bridge connections itself, as its mobile listener
bounds WebSocket connections: the helper may open up to
`max_connections × max_streams_per_connection` of them.

Ending a stream never closes the iroh connection: a phone renews its session on a
new stream of the same connection, opened as the last one ends. A connection with
no stream for 30 s is closed (`idle`, above); iroh's keep-alive would otherwise
hold it for as long as the peer answers. The one exception is `close`, which the
daemon sends for a peer whose session ended before `hello` or a pair request.

## Fixtures

`fixtures/` holds the exact bytes of every frame above:

| File | Contents |
|---|---|
| `hello.json`, `ready.json`, `relay.json`, `path.json`, `closed.json`, `refused.json`, `log.json`, `error.json` | events, one line each with its trailing `\n` |
| `start.json`, `set_relays.json`, `close.json`, `shutdown.json` | ops, one line each with its trailing `\n` |
| `bridge_preamble.bin` | the 37-byte preamble for a phone whose endpoint id is the one in `ready.json` |

The fixtures' key is the Ed25519 secret key whose 32 bytes are `01 02 … 20`; its
endpoint id is the one in `ready.json`.
