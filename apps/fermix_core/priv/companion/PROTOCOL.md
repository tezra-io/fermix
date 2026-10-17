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
the ones it shares (`msg`, `command`, `cancel`, `read_state`, `accepted`,
`turn_started`, `text_delta`, `tool_event`, `text_done`, `turn_error`, `row`,
`approval`, `approval_resolved`) through the same module. This wire adds
`history_search`, `search_results`, and a backward cursor on `history_pull`
and `history_page`. The phone's `row` carries more than this wire's: the whole
history message. This wire's `row` carries the message's `kind`, `metadata`,
`media_refs`, `link_previews` and `blocks` beside its own fields. This wire's
`media_fetch` (version 3) is not the phone's: the phone's streams the bytes in
chunks inside its envelope, and this one grants a managed file on the same
machine, so neither it nor its answers are shared.

## Transport

- **Socket:** a Unix-domain stream socket at `$FERMIX_HOME/companion.sock`
  (default `~/.fermix/companion.sock`), mode `0600`, owned by the daemon. It is
  served whenever the daemon runs; no setting or feature flag turns it on. A
  socket the daemon cannot bind is logged and skipped, and the daemon runs on.
- **Trust:** the socket's owner is the daemon's user, so a client is the owner.
  A turn from this socket runs as the operator, and slash commands are served.
  Before it reads a line, the daemon asks the kernel which process connected:
  a turn from a client the daemon itself started (an agent's shell command) or
  from a detached one with no terminal runs unattended, without host desktop
  control or reminder and event changes. A connection whose process the daemon
  cannot identify is answered with `error: unidentified_client` and closed.
- **Framing:** newline-delimited JSON. Each frame is one JSON object followed by
  a single `\n`, with a `type` discriminator. There is no length prefix; a
  client line longer than **65,536 bytes** is refused with
  `error: line_too_large` and the connection is closed. Daemon lines are not
  capped, though a `history_page` is kept to about 60 KiB (see *Delivery and
  the outbox*).
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
| `protocol_version` (companion declares) | `3` |
| daemon `min_version` | `2` |
| daemon `max_version` | `3` |

### Version 2: a turn that ends with no reply

Version 2 adds one server event, `turn_done { turn_id }`: the turn completed and
wrote no reply, so no `text_done` ends it. It happens during a GPT-Live voice
call in the chat, where a message typed may be material for the call rather
than a request, and the agent may answer it with nothing. A version 1 client
clears a turn only on `text_done` or `turn_error`, so it would show such a turn
as thinking until the next one began. So the daemon:

- sends a server event only to a connection whose `client_hello` declared the
  version that brought it, so `turn_done` reaches version 2 connections only
  (the schema names that version as `x-since-version`);
- lets a turn end with no reply only while every connection attached declared
  version 2. With a version 1 client attached the agent is told to answer
  briefly instead, and its answer ends the turn with `text_done` as always.

Version 2 also adds one client field, `cancel.task_ref`, which stops a
GPT-Live task that outlived its call (see *A Live call's rows*). A version 1
client never sends it.

A version 1 client was served as before and never saw `turn_done`. Every
version 1 event, field and rule holds unchanged on version 2. Since version 3
the window is {2, 3}, so a version 1 client is refused and every connection
reads `turn_done`.

### Version 3: phone-side media and rows that change

Version 3 lets the Mac's chat show what the phones put in the timeline: a
voice note, a picture or a file sent from a phone, a picture Fermix sent to
one, and the picture of a link preview stored on a row. Their bytes are in the
daemon's media store, by `ref`, the sha256 of the bytes. It adds:

- two client events: `media_fetch { profile_id, ref }` asks for a managed
  local file holding the bytes of a ref, and `media_release { profile_id,
  ref }` lets it go (see *Managed media files*);
- three server events: `media_path`, the grant, or `media_missing`, in answer
  to `media_fetch`, and `row_updated { profile_id, server_seq }`, which says a
  row already written changed (see *When a row changes*).

Each of the five names version 3 as its `x-since-version`. The three server
events reach version 3 connections only, and a version 2 connection that sends
`media_fetch` or `media_release` is refused with `error: unknown_event` and
closed, as for any event its version does not have.

A `row` now carries the row's `media_refs[]` (always, possibly empty) and
`link_previews[]` (only when it has one, at most 4), in the shapes a
`history_page` message carries them (see *Timeline shapes*). They are
additive, so they are sent on every version and an older client ignores them;
a new row needs no history read for its media.

Every version 2 event, field and rule holds unchanged on version 3. A version
1 client is refused with `error: unsupported_protocol_version`
(`client_too_old`).

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
| `cancel` | `profile_id`, `client_msg_id`; `task_ref?` | Stops the turn of that request, running or waiting, and no other, whichever client sent the request (the Mac or a phone). Never answered itself; see *Streaming a turn*. Version 2: with `task_ref { call_uuid, task_id, revision }` it stops instead the GPT-Live task those ids name, one that outlived its call, and `client_msg_id` names the cancel itself; see *A Live call's rows*. |
| `history_pull` | `profile_id`, `limit` (1–200), and exactly one of `after_seq` (≥ 0) or `before_seq` (≥ 1) | `after_seq` pages forward (the catch-up read); `before_seq` pages backward from it (scroll to the top). Either is any unsigned 64-bit value. |
| `history_search` | `profile_id`, `query` (1–256 characters), `limit` (1–50); `before_seq?` | Full-text search of the timeline, newest first, below `before_seq` when given. |
| `read_state` | `profile_id`, `read_up_to_seq` | Advances the monotonic read frontier, never past the newest row. |
| `media_fetch` | `profile_id`, `ref` (64 lowercase hex digits) | Version 3. Asks for a managed local file holding the bytes of `ref`, a media ref a row of the profile names. Answered by `media_path`, `media_missing`, or `error: request_failed` with `ref`. Any other `ref` is refused with `error: invalid_field` (`ref`) and the connection is closed. See *Managed media files*. |
| `media_release` | `profile_id`, `ref` (64 lowercase hex digits) | Version 3. The client has finished with the file `media_path` granted for `ref`. Never answered. Releasing a ref this connection does not hold changes nothing. |

`profile_id` is `main`, the one profile; any other is refused with
`error: unsupported_profile`, and the connection stays open.

## Server events (daemon → companion)

| `type` | Fields | Notes |
|---|---|---|
| `server_hello` | `min_version`, `max_version` | Handshake reply. |
| `accepted` | `client_msg_id`, `duplicate`; `server_seq?` | Durable receipt for a `msg` or `command`; clears the outbox item. `server_seq` is present only on a duplicate whose request already has a reply row: that reply's seq. A first `accepted` never carries it; the request's own row arrives as a `row`. |
| `turn_started` | `profile_id`, `turn_id`, `in_reply_to` | A turn began answering `in_reply_to`. |
| `text_delta` | `turn_id`, `text` | Text to append to the turn's draft, exactly as sent. |
| `tool_event` | `turn_id`, `tool`, `phase`; `detail?` | `phase` is `start` or `stop`. `detail` is at most 512 bytes. |
| `text_done` | `turn_id`, `server_seq`, `text`; `blocks[]?` | A reply's canonical text at its timeline row, sent once the turn has completed; replaces the draft. A turn may send more than one. `blocks` are the row's, present only when it has one; see *Blocks under a reply*. |
| `turn_error` | `turn_id`, `code`, `message` | The turn's terminal failure: `code` is `cancelled` after a `cancel`, `interrupted` when the daemon lost the turn. `message` is at most 512 bytes. |
| `turn_done` | `turn_id` | Version 2. The turn completed and wrote no reply: it ends the turn, and nothing of its draft is kept. Sent only to a connection on version 2; see *Version 2*. |
| `row` | `profile_id`, `server_seq`, `role`, `text`, `ts`, `media_refs[]`; `client_msg_id?`, `kind?`, `metadata?`, `link_previews[]?`, `blocks[]?` | A timeline row this socket did not stream, announced to every connection as it is written: the sender's own message (with its `client_msg_id`, to match the outbox), a slash command's answer, a scheduled delivery, a message from a phone, the reply to a phone's turn, and a Live call's row. `kind`, `metadata`, `media_refs`, `link_previews` and `blocks` are the history message's, as a `history_page` carries them (see *Timeline shapes*); a Live call's row carries `metadata.call` (see *A Live call's rows*). |
| `row_updated` | `profile_id`, `server_seq` | Version 3. A row already written changed: its text, its media refs or its link previews. Carries no content; see *When a row changes*. Sent only to a connection on version 3. |
| `approval` | `approval_id`, `kind`, `text`, `token`, `ttl_s`, `approve_command`, `deny_command`; `detail?` | An owner-approval card raised by a turn on this socket. The token is submitted, never rendered. Routes are nonempty and at most 1,024 characters. Sent again after `server_hello` while it waits; see *Approvals*. |
| `approval_resolved` | `approval_id`, `outcome` | `approved` or `denied` when the owner answered, `expired` when its `ttl_s` ran out. |
| `read_state` | `profile_id`, `read_up_to_seq` | The read frontier, sent to every connection, whichever client (the Mac or a phone) moved it. |
| `history_page` | `profile_id`, `messages[]`, `history_head_seq`; `next_after_seq?`, `next_before_seq?` | Messages oldest first, at most `limit` and about 60 KiB of them. |
| `search_results` | `profile_id`, `query`, `hits[]`; `next_before_seq?` | Hits newest first. |
| `media_path` | `ref`, `path`, `kind`, `mime`, `size_bytes`, `sha256` | Version 3. The grant answering `media_fetch`: an absolute path to a managed file holding the ref's bytes, held for this connection; see *Managed media files*. Sent only to a connection on version 3. |
| `media_missing` | `ref` | Version 3. Nothing to grant for `ref`; see *Managed media files*. Sent only to a connection on version 3. |
| `error` | `reason`; `message?`, `field?`, `event?`, `client_msg_id?`, `ref?`, `direction?`, `client_version?`, `min_version?`, `max_version?` | A refusal; see *Errors*. |

### Timeline shapes

A `history_page` message is the exported timeline row and nothing else:
`server_seq`, `role`, `content`, `ts` (RFC 3339, UTC), `media_refs[]`, plus
optional `kind`, `client_msg_id`, `in_reply_to`, `metadata`,
`link_previews[]` and `blocks[]` (see *Blocks under a reply*). A
`media_refs[]` entry carries `ref`, `kind`, `mime`, and
`size_bytes`, plus optional `sha256`, `filename`, and `caption`. A
`link_previews[]` entry is a link preview the phone channel stored on the row:
`url` (at most 2,048 bytes), `site` (120), `title` (300), and optional
`description` (600) and `image_ref`; a row carries at most 4, and has the key
only when it has one. `metadata` never holds a null. Internal storage columns
are never shipped.

A `search_results` hit carries `server_seq`, `role`, `ts`, `excerpt` (plain
text around the matches, `…` where it was cut), and `ranges[]`, each
`{start, length}` in **Unicode scalar values** of `excerpt`, one per matched
word.

### A Live call's rows

A GPT-Live voice call in the chat writes rows of its own to the timeline, each
`kind: "text"`, `role: "assistant"` and `media_refs: []`, so every client
draws one as text. A task's result that is too long to say, or cannot be said
(a link, code, a table), is one: the voice says a short line and the whole
result is written here, at most 32 KB (cut at the end behind a marker). The
call's own row when it ends is another (`event: "ended"`): the daemon's
sentence, `Voice call, 6 minutes` (`under a minute` below one), then, on its
own paragraph, the call's gist, a few sentences on what was asked, done,
decided and left open; or, when the gist could not be made, the call's tasks,
one a line, each its state and summary (`Still running` for a task that
outlived the call); or nothing more when the call had neither. It is written
once the gist is made or has failed, so it always carries the settled cost.
A private call writes no row.

A task still running when a call in the chat ends is not cancelled: it
finishes into the chat, so it writes two rows of its own. The first, as the
call ends, says it is still running (`event: "task_running"`): `Still working
on:` and the request on one line. The second, when it ends
(`event: "task_done"`, with its terminal `state`), is its result as the
shown part of a reply (or the whole reply), its failure's sentence, or a fixed
sentence for a task cancelled, timed out (it may run 30 minutes) or lost to a
daemon restart (`failed`). A client resolves the running row with the done row
of the same `uuid`, `task_id` and `revision`. While the running row stands, a
version 2 client may stop the task with `cancel { task_ref: { call_uuid,
task_id, revision } }`, the three ids that row carries: only that task's turn
is stopped, and the acknowledgement is its done row with `state: "cancelled"`
(or the state it reached first, when it was already finishing). A `task_ref`
that names no task still running under exactly those ids (another revision, a
task already done, a private call's) is refused with
`error { reason: "request_failed", message }`, and the connection stays open.
A `/stop` stops such a task too, which then writes its `cancelled` row. Such a
row's `metadata.call` says what it is about:

| Key | Type | Notes |
|---|---|---|
| `uuid` | UUID | The call, as `call_ready.call_uuid` names it on the realtime wire. Always present. |
| `event` | `shared` \| `ended` \| `task_running` \| `task_done` | Always present. `shared` is a task's result shown here during the call; `ended` the call's row when it ends; `task_running` and `task_done` the two rows of a task that outlived its call. |
| `task_id` | string | The task, the realtime wire's `delegation_id`. Present on `shared`, `task_running` and `task_done`. |
| `revision` | int ≥ 1 | The task's revision, beside `task_id`. |
| `state` | `completed` \| `failed` \| `cancelled` \| `timed_out` | A task's terminal state. Present on `task_done`. |
| `engine` | string | The call's voice engine, `openai_live`. Present on `ended`. |
| `duration_s` | int ≥ 0 | The call's length. Present on `ended`. |
| `voice_cost_cents` | number ≥ 0 | The call's settled voice cost. On `ended` when it is known. |
| `accounting` | `complete` \| `incomplete` | Whether that cost is settled. Present on `ended`. |
| `gist_status` | `written` \| `failed` \| `none` | What became of the call's gist: in the text, could not be made (the text lists the tasks), or none was needed (nothing was said). Present on `ended`. |

No other key appears in it. A call's row is written once: a write repeated for
the same task revision and event, or for the same call's end, finds the row
already written, and the realtime wire's `task.server_seq` names a task's, so
the app can say the result is in the chat.

## Managed media files

A `media_fetch` names a ref a row of the profile names, in its `media_refs` or
as a link preview's `image_ref`. The daemon answers with one of:

- `media_path { ref, path, kind, mime, size_bytes, sha256 }`, the grant.
  `path` is absolute: the managed file `$FERMIX_HOME/companion/media/<ref><ext>`,
  its extension taken from the mime the way every inbound copy is named
  (`audio/ogg` is `.ogg`). `kind`, `mime` and `size_bytes` are the ones the row
  names for the ref, and `sha256` equals `ref`: the file's bytes were checked
  against it when the file was made.
- `media_missing { ref }`: nothing to grant. No row of the profile names the
  ref, the media store no longer holds its bytes, its bytes no longer match the
  row, or the phone channel whose store keeps them is off.
- `error { reason: "request_failed", message, ref }`: the daemon could not
  serve it for a reason of its own, such as a disk error making the copy. The
  connection stays open.

A `media_release` is never answered. The daemon owns the files and keeps these
rules:

1. **One file per ref.** Asking again returns the same path while the file
   exists, so repeated viewing piles nothing up. A file that has disappeared
   (removed from outside) is made again at the same path.
2. **Held while in use.** A `media_path` holds the file for its connection
   until that connection sends `media_release` for the ref or closes. A
   connection holds a ref once, however many times it fetched it.
3. **Held means held.** A held file is never removed or rewritten, whatever
   the budget says.
4. **Kept after release.** A file no connection holds stays at least 60 s
   after its last release, so a reconnect takes back what was playing or
   showing: on reconnect a client sends `media_fetch` again for every ref it
   still holds, and gets the same path.
5. **Reclaimed under a budget.** Beyond that, the daemon keeps its managed
   files within 512 MiB, removing the least recently released first.
6. **The budget gives way.** When held and kept files alone pass the budget,
   the daemon removes every other file, still grants the next `media_fetch`
   (viewing never fails for the budget's sake), logs the overage once with the
   held total, and comes back under the budget as files are released and their
   60 s pass.
7. **Fresh at start.** Every managed file is removed when the daemon starts,
   which also clears what a crash left. A path granted before a restart is
   gone, and the client asks again.
8. **No processing.** The daemon makes no thumbnails, and decodes and
   transcodes nothing. The file is a reusable copy of the stored blob (a
   filesystem clone may replace the copy later, behind the same rules); the
   stored original is never handed out.

The two numbers are the schema's `x-media-budget-bytes` (536,870,912) and
`x-media-release-grace-s` (60).

## When a row changes

`row_updated { profile_id, server_seq }` (version 3) says a row already
written changed, and carries none of it: a client that holds the row reads it
again from history (`history_pull { after_seq: server_seq - 1, limit: 1 }`),
and one that does not drops the notice, since it reads that row as it stands
when it pages it in. The daemon sends it to every version 3 connection
watching the profile:

- when a phone's voice note's transcript replaces its user row's text, and
  only when the stored text did change: a Mac message, which has nothing to
  transcribe, passes through the same step unchanged and sends none;
- when a link preview is stored on a row, after it is stored.

The phones are not sent it: their wire has `link_preview`, which reaches them
as before. A notice sent while a client was disconnected is lost, so a client
that reconnects reads again the rows it shows.

## Blocks under a reply

A reply can carry `blocks[]`: records its text links, which a client draws
beside the text. Its `text_done`, its `row` and its history message carry the
same `blocks`, and have the key only when the reply has one. The rules:

- **The text stands alone.** Every reply is complete as text, each place it
  recommends linked by name. A block adds to the text and never replaces it,
  so a client that draws no blocks, every other channel and the transcript
  search lose nothing.
- **A client skips a block `type` it does not know.** `places` is the only
  type so far, and `blocks` holds at most one block of each type.
- **Additive, so no version bump.** An older client ignores the key (*Absent
  is absent*, under *Transport*).
- **Places, in first-link order.** A `places` block holds the places a
  `place_search` in the same conversation found in the last 30 minutes that
  the reply's text links, one to ten, in the order the text first links them,
  each once. A link names a place when it is the place's `canonical_url` or
  `source_url`, compared with the scheme and host in lower case, without the
  fragment and without a trailing slash on the path. A place found but not
  linked is not in it, and a reply that links none has no block.
- **A place is the search's own record**, cut to these fields under the
  record's own names: `name` and `location {latitude, longitude}`, always (a
  place without coordinates stays a link in the text); at least one of
  `canonical_url` and `source_url`, HTTPS addresses exactly as returned; and,
  each only when the source gave it, `apple_place_id`, `address`, `rating
  {value?, best?, count?}`, `price_range`, `categories[]` (at most 5),
  `opening_hours {current_day}` and `distance {value, units}`. The
  description, contact details, cuisines, the other days' hours and the
  picture are left out. The coordinates are the place's, never the person's.
- **Two sources, one record.** The Fermix Mac app's engine searches Apple
  Maps and the Homebrew and Linux builds Brave, or whichever its settings name. A place Apple Maps found
  carries `apple_place_id`, Apple Maps' identifier for it, by which a Mac opens
  Apple's own place card; its `source_url` is Apple's page for the place
  (`https://maps.apple.com/place?place-id=` and the identifier), and it has a
  kind and an address but no rating, price or hours. A `distance` is present
  only when the search was anchored on coordinates. A client draws what a place
  has, and opens a place without an identifier from its name and coordinates.
- **Hours as given.** `opening_hours.current_day` is today's hours as the
  source wrote them (`Thursday 07:00-19:00`); a client shows it as it is and
  never works out whether the place is open now.
- **Bounds.** The counts are the search's own: at most 10 places and 5
  categories a place. Strings are as the source gave them, inside its 1 MiB
  response.

The phones' `row` carries the history message whole, so it carries `blocks`
too, and a phone app may ignore them.

## One timeline with the phone

The profile's timeline is the one the phone's mobile channel reads and writes:
its rows, `server_seq` numbering and read frontier are shared. **Every row is
announced live** to every connection watching the profile at the moment it is
written, whoever writes it: the reply of a turn started on this socket as
that turn's `text_done`, and every other row as a `row` (the user's message,
including to the connection that sent it; a slash command's answer; a
scheduled job's delivery, written whether or not a client is connected; a
message from a phone and the reply to a phone's turn).

The phones hear this socket the same way: every row written here reaches them
as their own `row`, which carries the whole history message, and the reply of
a turn started here reaches them as a `row` too, since they never saw that
turn start. What crosses the two transports is the timeline and the read
frontier. A turn's stream and its ending (`turn_started`, `text_delta`,
`tool_event`, `text_done`, `turn_error`, `turn_done`) stay with the transport
that ran the turn, and so do approvals, whose token resolves only there (see
*Approvals*).

`server_seq` is assigned inside the write that stores the row, from a
per-profile counter that never goes back, whoever writes (a turn, a job, the
phone): no two rows share one, and the daemon never renumbers or reorders a
row to hide how its announcement arrived.

## Keeping a client's timeline

A connection is watching the profile from its `server_hello` on, before it can
ask for history, and the daemon writes each `history_page` to the socket in the
same step that read it. So no row can fall between a page and the live events:
a row written after the read is announced after the page reaches the socket,
and a live event that arrives ahead of a page is for a row already committed
when the page was read (in that page, or a later one of the same pull). Live
announcements can still arrive out of `server_seq` order (a job's row can be
announced after a later reply's), and a page and a live event can carry the
same row. So a client keeps a cursor, the last `server_seq` it shows, and:

- pulls `history_pull{after_seq: cursor}` after every `server_hello`, and again
  while a page's `next_after_seq` is below its `history_head_seq`;
- applies a live row (a `row`, or a `text_done` at its `server_seq`) when its
  seq is `cursor + 1`, drops one at or below the cursor, and on a gap pulls
  from the cursor (unless a pull is already out) instead of showing it;
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
`history_pull(before_seq)` returns the newest rows before a cursor, oldest
first, and `next_before_seq` (its oldest row) only when an older row exists.
`history_search` pages the same way.

A page holds at most `limit` rows and at most about 60 KiB of them, so it can
hold fewer than asked; it always holds at least one row when there is one. A
forward page keeps its oldest rows and its `next_after_seq` names the last one
sent; a backward page keeps its newest rows and its `next_before_seq` names
the oldest one sent. A client pulls on from that cursor. A cursor above
2^63-1 (the largest row number the store holds) is one past every row: a
forward page is then empty and echoes the cursor, and a backward page or a
search starts from the newest row.

The read frontier moves forward and never past the newest row: the daemon
stores `min(max(stored, reported), history_head_seq)` and sends the result to
every connection. A frontier stored past the newest row earlier comes back to
it on the next report.

A request that fails after `accepted` is answered
`error{reason: "request_failed", message, client_msg_id}` with a message of at
most 512 bytes. A request that failed stays failed: its resend is a duplicate
and never runs again. A `msg` whose text runs a command that answers later
(`/background` and `/bg`, `/skills review`, `/skills approve`) stays running
until the command reports, and its later answer arrives as a `row`.

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
- it completed and wrote no reply (version 2): one `turn_done`, and nothing of
  its draft is kept. Only a turn the agent was told it may leave unanswered
  ends this way, and only while every connection speaks version 2 (see
  *Version 2*); no `text_delta` carries the reply it did not write;
- it was cancelled or failed: one `turn_error` (`cancelled`, or the failure's
  code), and nothing of its draft is kept;
- the daemon lost the turn (its queue restarted under it): one `turn_error`
  with code `interrupted`;
- the request could not be handed to the turn queue: one `turn_error` with
  code `turn_failed`.

`turn_error` and `turn_done` are live-only and carry no seq: a cancelled or
failed message, or one that ended with no reply, leaves its user's row
(announced as a `row` when it was written) with no answer after it. `cancel` names the request whose turn to stop, whichever
client sent it and whether it runs or still waits; it never stops another
turn, and the daemon never answers it itself. It is recorded on the request
before anything else, so a cancel that arrives after `accepted` but before
the request has reached the turn queue is not lost: the request is never
queued and ends with `turn_error` (code `cancelled`), and a request the
daemon recovers after a restart is not run again. A turn that had already
finished when the cancel arrived ends with its `text_done`, not an error, and
a cancel for a request that already ended changes nothing. A `cancel` with
`task_ref` (version 2) is the one a `cancel` is answered for: a task the
daemon is not running under exactly those ids is refused with
`request_failed`; see *A Live call's rows*.

## Approvals

When a tool needs the owner's approval, the daemon sends `approval`. The
companion answers by sending one of the routes as a `command`: drop the
leading `/`, the first word is `name` and the rest is `args`. `/confirm TOKEN`
is `command{name: "confirm", args: "TOKEN"}`, and `/soul apply TOKEN` is
`command{name: "soul", args: "apply TOKEN"}`.

- A card belongs to the transport whose turn raised it, the only one its token
  resolves from: this socket gets the cards its own turns raise, and never a
  phone's. Its re-send, expiry and resolution go to this socket's connections
  alone.
- `approval_resolved` reports the outcome to every connection of this socket:
  `approved` or `denied` when the owner answered, `expired` when the card's
  `ttl_s` ran out.
- Right after `server_hello`, the daemon sends again every card of the profile
  still waiting that this socket's turns raised, oldest first, each with
  `ttl_s` set to the seconds it has left, rounded up. A client keys cards by
  `approval_id`, so a card it already shows is replaced, not doubled.
- When `server_hello` arrives, a client drops every card it shows and keeps
  only the ones the daemon sends after it. `approval_resolved` goes only to the
  connections open when a card is answered or expires, so a card that ended
  while the client was away is never withdrawn: it is simply not sent again.
- Waiting cards live in the daemon's memory, as their tokens do: a restart
  forgets them without resolving them, so a client also drops a card when its
  own `ttl_s` runs out. The daemon keeps at most 64; past that a card still
  goes out live but is not sent again, so a reconnect drops it.

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
| `unidentified_client` | `message` | closed |
| `client_message_conflict` | `client_msg_id` | open |
| `unsupported_profile` | `client_msg_id?` | open |
| `request_backlog_full` | — | open |
| `request_failed` | `message` (at most 512 bytes), `client_msg_id?`, `ref?` | open |

`unknown_event` also refuses an event newer than the version the connection's
`client_hello` declared. `ref` is set only on the `request_failed` that answers
a `media_fetch`.

## Chat sequence

```
companion -> daemon:  client_hello { protocol_version: 3 }
daemon -> companion:  server_hello { min_version: 2, max_version: 3 }
companion -> daemon:  history_pull { profile_id: "main", after_seq: 12, limit: 200 }
daemon -> companion:  history_page { messages: [...], next_after_seq: 12, history_head_seq: 12 }
companion -> daemon:  msg { client_msg_id: "mac-1", profile_id: "main", text, attach_ids: [] }
daemon -> companion:  accepted { client_msg_id: "mac-1", duplicate: false }
daemon -> companion:  row { server_seq: 13, role: "user", text, ts, media_refs: [], client_msg_id: "mac-1" }
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

A phone's voice note, on version 3:

```
daemon -> companion:  row { server_seq: 21, role: "user", text: "", ts, kind: "media",
                            media_refs: [{ ref: "<64 hex>", kind: "audio", mime: "audio/ogg", size_bytes: 48213, sha256: "<same>" }] }
daemon -> companion:  row_updated { profile_id: "main", server_seq: 21 }        (the transcript was stored)
companion -> daemon:  history_pull { profile_id: "main", after_seq: 20, limit: 1 }
daemon -> companion:  history_page { messages: [{ server_seq: 21, content: "Pick up milk", ... }], ... }
companion -> daemon:  media_fetch { profile_id: "main", ref: "<64 hex>" }          (the person pressed play)
daemon -> companion:  media_path { ref, path: "/Users/me/.fermix/companion/media/<ref>.ogg", kind: "audio", mime: "audio/ogg", size_bytes: 48213, sha256: "<same>" }
companion -> daemon:  media_release { profile_id: "main", ref: "<64 hex>" }        (the player let it go)
```
