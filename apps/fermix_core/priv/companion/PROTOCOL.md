# Fermix companion chat socket protocol

The wire contract between the Fermix daemon and a native companion's chat (the
Mac app first).

**Source of truth:** `FermixCore.Companion.Protocol` (`lib/fermix_core/companion/protocol.ex`).
This file, `protocol.schema.json`, and `fixtures/*.jsonl` are the machine-readable
export of that module. `protocol_contract_test.exs` asserts they never drift from
it. A downstream consumer (e.g. `fermix-macos`) **vendors the schema and fixtures
pinned by checksum** rather than hand-copying the shapes.

**One chat vocabulary.** The chat events are the same payloads the mobile wire
(`priv/mobile/`) carries inside its Noise envelope; the mobile codec validates
the ones it shares (`msg`, `command`, `read_state`, `accepted`, `turn_started`,
`text_delta`, `tool_event`, `text_done`, `turn_error`, `approval`,
`approval_resolved`) through the same module. This wire adds `cancel`,
`history_search`, `search_results`, and a backward cursor on `history_pull`
and `history_page`.

## Transport

- **Socket:** a Unix-domain stream socket at `$FERMIX_HOME/companion.sock`
  (default `~/.fermix/companion.sock`), mode `0600`, owned by the daemon. It is
  served whenever the daemon runs; no setting or feature flag turns it on. A
  socket the daemon cannot bind is logged and skipped, and the daemon runs on.
- **Trust:** the socket's owner is the daemon's user, so a client is the owner.
  A turn from this socket runs as the operator, and slash commands are served.
- **Framing:** newline-delimited JSON. Each frame is one JSON object followed by
  a single `\n`, with a `type` discriminator. There is no length prefix; a
  client line longer than **65,536 bytes** is refused with
  `error: line_too_large` and the connection is closed. Daemon lines are not
  capped (a history page can be long).
- **Clients:** at most **4** connections at once. A fifth is answered with
  `error: max_clients_reached` and closed.
- **Direction:** *client events* flow companion → daemon; *server events* flow
  daemon → companion.
- **Absent is absent:** an optional field the daemon has no value for is an
  absent key, never an explicit `null`. Unknown fields are ignored by older
  peers, so an additive optional field does not need a version bump.

## Versioning

The protocol is versioned by a single integer, `protocol_version`. The daemon
advertises the inclusive range `{min_version, max_version}` it accepts, an
**N/N-1 window**: `max_version` is the current version and `min_version` the
previous one (or the same value while only one version exists).

| Field | Value |
|---|---|
| `protocol_version` (companion declares) | `1` |
| daemon `min_version` | `1` |
| daemon `max_version` | `1` |

## Handshake state machine

The connection opens with a **mandatory, one-shot handshake**, exactly as the
Realtime voice socket's. No other event is serviced until it completes.

```
companion: connect socket
companion -> daemon:  client_hello { protocol_version: P }
                      daemon negotiates P against {min, max}:
                        P in [min, max] -> daemon -> companion: server_hello { min_version, max_version }
                        P < min         -> error(unsupported_protocol_version, client_too_old); close
                        P > max         -> error(unsupported_protocol_version, client_too_new); close
companion: on server_hello, validate its own version V in [min_version, max_version]:
             in range     -> connected
             out of range -> refuse; report which side must update
```

Rules the daemon enforces:

1. Any client event other than `client_hello` received **before** a successful
   handshake is rejected with `error: handshake_required` and the connection is
   closed.
2. A second `client_hello` is rejected with `error: unexpected_client_hello`
   and the connection is closed.
3. A `client_hello` without a positive integer `protocol_version` is rejected
   with `error: missing_protocol_version` or `error: invalid_protocol_version`.

Rules the companion enforces:

4. It does not consider itself connected until it has received and validated
   `server_hello`. A version outside the range surfaces a directional message
   (update the app, or update Fermix), not a generic offline state.
5. Unrecognized server events are logged, never silently dropped.

`error(unsupported_protocol_version)` carries `direction` (`client_too_old`:
update the app; `client_too_new`: update Fermix), `client_version`,
`min_version`, and `max_version`.

## Rollout / rollback order

The daemon and the app ship from separate repositories, so a version bump lands
in a fixed order:

1. **Daemon first.** Ship a daemon that adds `N+1` while keeping `N`.
2. **App second.** Only after that daemon is released, ship an app that speaks
   `N+1`. An app never requires a version the released daemon lacks.
3. **Rollback** is the reverse: roll the app back to `N` before dropping `N`
   from the daemon.

## Client events (companion → daemon)

| `type` | Fields | Notes |
|---|---|---|
| `client_hello` | `protocol_version` (int > 0) | First frame. Opens the handshake. |
| `msg` | `client_msg_id`, `profile_id`, `text`, `attach_ids[]` | A message to the agent. `text` must not be blank. `attach_ids` is **empty** on this wire in version 1; a non-empty list is refused with `error: attachments_unsupported`. |
| `command` | `client_msg_id`, `profile_id`, `name`; `args?` | A slash command, `/name args`. An approval's routes are sent this way. |
| `cancel` | `profile_id`, `client_msg_id` | Stops the turn of that request, running or waiting, and no other. Never answered itself; see *Streaming a turn*. |
| `history_pull` | `profile_id`, `limit` (1–200), and exactly one of `after_seq` (≥ 0) or `before_seq` (≥ 1) | `after_seq` pages forward (the catch-up read); `before_seq` pages backward from it (scroll to the top). |
| `history_search` | `profile_id`, `query` (1–256 characters), `limit` (1–50); `before_seq?` | Full-text search of the timeline, newest first, below `before_seq` when given. |
| `read_state` | `profile_id`, `read_up_to_seq` | Advances the monotonic read frontier. |

`profile_id` is `main`, the one profile; any other is refused with
`error: unsupported_profile`.

## Server events (daemon → companion)

| `type` | Fields | Notes |
|---|---|---|
| `server_hello` | `min_version`, `max_version` | Handshake reply. |
| `accepted` | `client_msg_id`, `duplicate`; `server_seq?` | Durable receipt for a `msg` or `command`; clears the outbox item. `server_seq` is present once the request has a reply row. |
| `turn_started` | `profile_id`, `turn_id`, `in_reply_to` | A turn began answering `in_reply_to`. |
| `text_delta` | `turn_id`, `text` | Text to append to the turn's draft, exactly as sent. |
| `tool_event` | `turn_id`, `tool`, `phase`; `detail?` | `phase` is `start` or `stop`. |
| `text_done` | `turn_id`, `server_seq`, `text` | A reply's canonical text at its timeline row, sent once the turn has completed; replaces the draft. A turn may send more than one. |
| `turn_error` | `turn_id`, `code`, `message` | The turn's terminal failure: `code` is `cancelled` after a `cancel`, `interrupted` when the daemon lost the turn. |
| `approval` | `approval_id`, `kind`, `text`, `token`, `ttl_s`, `approve_command`, `deny_command`; `detail?` | An owner-approval card. The token is submitted, never rendered. Routes are nonempty and at most 1,024 characters. |
| `approval_resolved` | `approval_id`, `outcome` | `approved`, `denied`, or `expired`. |
| `read_state` | `profile_id`, `read_up_to_seq` | The read frontier, sent to every connection. |
| `history_page` | `profile_id`, `messages[]`, `history_head_seq`; `next_after_seq?`, `next_before_seq?` | Messages oldest first. |
| `search_results` | `profile_id`, `query`, `hits[]`; `next_before_seq?` | Hits newest first. |
| `error` | `reason`; `message?`, `field?`, `event?`, `client_msg_id?`, `direction?`, `client_version?`, `min_version?`, `max_version?` | A refusal; see *Errors*. |

### Timeline shapes

A `history_page` message is the exported timeline row and nothing else:
`server_seq`, `role`, `content`, `ts` (RFC 3339, UTC), `media_refs[]`, plus
optional `kind`, `client_msg_id`, `in_reply_to`, and `metadata`. A
`media_refs[]` entry carries `ref`, `kind`, `mime`, and `size_bytes`, plus
optional `sha256`, `filename`, and `caption`. Internal storage columns are never
shipped.

A `search_results` hit carries `server_seq`, `role`, `ts`, `excerpt` (plain
text around the matches, `…` where it was cut), and `ranges[]`, each
`{start, length}` in **Unicode scalar values** of `excerpt`, one per matched
word.

## One timeline with the phone

The profile's timeline is the one the phone's mobile channel reads and writes:
its rows, `server_seq` numbering and read frontier are shared. A turn started
from this socket is written there and seen live by every connection on this
socket; a turn started from the phone reaches this socket's clients through
`history_pull`. A scheduled job whose result is delivered to the companion
channel is written there whether or not a client is connected, and announced
as a `text_done` to any that are.

`server_seq` is assigned inside the write that stores the row, from a
per-profile counter that never goes back, whoever writes (a turn, a job, the
phone): no two rows share one, and the daemon never renumbers or reorders a
row to hide how its announcement arrived.

## Keeping a client's timeline

A connection is watching the profile from its `server_hello` on, before it can
ask for history, so no row written after the handshake can fall between a
page and the live events. Live announcements still arrive out of `server_seq`
order at times (a job's row can be announced after a later reply's), a page
and a live `text_done` can carry the same row, and a user's row reaches the
other connections only through history. So a client keeps a cursor, the last
`server_seq` it shows, and:

- pulls `history_pull{after_seq: cursor}` after every `server_hello`, and again
  while a page's `next_after_seq` is below its `history_head_seq`;
- shows a `text_done`'s row only when its `server_seq` is `cursor + 1`, drops
  one at or below the cursor, and on a gap pulls from the cursor (unless a
  pull is already out) instead of showing it;
- never keys the cursor on arrival order.

## Delivery and the outbox

`msg` and `command` are at-least-once from the companion. The daemon durably
claims `client_msg_id` before it answers `accepted`; a resend of the same
request is answered `accepted` with `duplicate: true` and never runs the turn
twice. The same `client_msg_id` with different content is refused with
`error: client_message_conflict`. A request the daemon accepted but could not
finish because it stopped is run again when it next starts, so `accepted` is
the point after which the companion stops resending. Claims last 24 hours.

History is recovered exactly: `history_pull(after_seq)` returns the rows after
a cursor, oldest first, with `next_after_seq` (the last row returned, or the
cursor itself on an empty page) and `history_head_seq`.
`history_pull(before_seq)` returns the newest `limit` rows before a cursor,
oldest first, and `next_before_seq` (its oldest row) only when an older row
exists. `history_search` pages the same way.

## Streaming a turn

`turn_started` is sent when the turn begins. `text_delta` then carries the
reply as it is generated: each is the text this connection has not received
yet, to be appended exactly as sent, never trimmed or spaced. When the agent
starts another model call in the same turn (after a tool), the next text starts
a new stretch and is appended after the previous one. A connection that joins
mid-turn receives the text so far as its first `text_delta` for that turn,
possibly without having seen `turn_started`. Deltas are live-only.

A turn ends on the wire exactly once, and only from its outcome in the
daemon's turn queue:

- it completed: each reply part is written to the timeline then, and sent as
  a `text_done` at its row, replacing the draft;
- it was cancelled or failed: one `turn_error` (`cancelled`, or the failure's
  code), and nothing of its draft is kept;
- the daemon lost the turn (its queue restarted under it): one `turn_error`
  with code `interrupted`.

`turn_error` is live-only: a client that was offline sees the user's row with
no answer after it. `cancel` names the request whose turn to stop, whichever
client sent it and whether it runs or still waits; it never stops another
turn, and the daemon never answers it itself. A turn that had already
finished when the cancel arrived ends with its `text_done`, not an error.

## Approvals

When a tool needs the owner's approval, the daemon sends `approval`. The
companion answers by sending one of the routes as a `command`: `/confirm TOKEN`
is `command{name: "confirm", args: "TOKEN"}`. `approval_resolved` reports the
outcome to every connection.

## Errors

| `reason` | Context | Connection |
|---|---|---|
| `invalid_json`, `invalid_event`, `missing_type` | — | closed |
| `unknown_event` | `event` | closed |
| `missing_field`, `invalid_field` | `field` | closed |
| `attachments_unsupported` | — | closed |
| `line_too_large` | — | closed |
| `handshake_required`, `unexpected_client_hello` | — | closed |
| `missing_protocol_version`, `invalid_protocol_version` | — | closed |
| `unsupported_protocol_version` | `direction`, `client_version`, `min_version`, `max_version` | closed |
| `max_clients_reached` | — | closed |
| `client_message_conflict` | `client_msg_id` | open |
| `unsupported_profile` | `client_msg_id?` | open |
| `request_backlog_full` | — | open |
| `request_failed` | `message`, `client_msg_id?` | open |

## Chat sequence

```
companion -> daemon:  client_hello { protocol_version: 1 }
daemon -> companion:  server_hello { min_version: 1, max_version: 1 }
companion -> daemon:  history_pull { profile_id: "main", after_seq: 12, limit: 200 }
daemon -> companion:  history_page { messages: [...], next_after_seq: 12, history_head_seq: 12 }
companion -> daemon:  msg { client_msg_id: "mac-1", profile_id: "main", text, attach_ids: [] }
daemon -> companion:  accepted { client_msg_id: "mac-1", duplicate: false }
daemon -> companion:  turn_started { turn_id: "turn-mac-1", in_reply_to: "mac-1" }
daemon -> companion:  tool_event { turn_id, tool, phase: "start" } / { phase: "stop" }
daemon -> companion:  text_delta { turn_id, text } …
daemon -> companion:  text_done { turn_id, server_seq: 14, text }
companion -> daemon:  read_state { profile_id: "main", read_up_to_seq: 14 }
daemon -> companion:  read_state { profile_id: "main", read_up_to_seq: 14 }
                      (reconnect; the outbox resends "mac-1")
companion -> daemon:  msg { client_msg_id: "mac-1", … }
daemon -> companion:  accepted { client_msg_id: "mac-1", duplicate: true, server_seq: 14 }
```
