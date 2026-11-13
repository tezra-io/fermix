# Fermix management socket protocol

The wire contract between the Fermix daemon and the Fermix macOS application.

**Source of truth:** `FermixCore.Management.Protocol`
(`lib/fermix_core/management/protocol.ex`). This file, `protocol.schema.json`,
and `fixtures/*.jsonl` are the machine-readable export of that module.
`protocol_contract_test.exs` asserts they never drift from it. A downstream
consumer (`fermix-macos`) **vendors the schema and fixtures pinned by checksum**
rather than hand-copying the shapes — that is the single coordination point
across the two independently-released repos.

## Transport

- **Socket:** a Unix-domain stream socket at `$FERMIX_HOME/daemon.sock`
  (default `~/.fermix/daemon.sock`), mode `0600`, owned by the daemon. There is
  no per-request authentication; the trust boundary is the socket file's mode
  and ownership.
- **Framing:** Erlang `{:packet, 4}` — one big-endian 32-bit byte length
  followed by exactly that many bytes of UTF-8 JSON. A frame arrives whole or
  not at all, so a decode failure means malformed JSON, never truncation.
- **Frame ceiling:** `max_frame_bytes` = `4194304` (4 MiB), enforced on both
  ends via `{:packet_size, ...}`. A client rejects an oversized request before
  sending it rather than failing on an opaque `emsgsize`.
- **Exchange:** one request, one response, then the daemon closes the
  connection. There are no server-initiated frames and no streaming; Doctor runs
  and log pages are polled, which is why `doctor.start` returns immediately with
  a session id instead of holding the request open.

## Versioning

The protocol is versioned by a single integer, `protocol_version`, carried on
every request. The daemon accepts the inclusive range `{minimum, maximum}`. The
range is an **N/N-1 window**: `maximum` is the current version and `minimum` is
the previous one (or the same value when only one version has ever existed), so
a daemon that has moved to `N+1` still serves an app speaking `N` for one
release.

Current values (see the schema's `x-protocol-version` /
`x-supported-version-range`):

| Field | Value |
|---|---|
| `protocol_version` (app declares) | `2` |
| daemon `minimum_version` | `1` |
| daemon `maximum_version` | `2` |

`hello` returns the same range, so a client learns the window without having to
provoke an error.

### Per-method minimum versions

A single integer is not enough once the window is wider than one version. Each
method declares its own `min_protocol_version`, published whole in the schema as
`x-method-minimum-versions` and in `hello` as `capabilities.minimum_versions`.
The daemon gates on the version the **request** declares, not on its own: a
v1-negotiated session calling a v2 method is refused with `method_not_found` and
`details.requires`, so the wire's meaning never depends on the client's honesty.

A client computes its negotiated version as the highest version both halves
speak, stamps it on every request, and refuses a method whose published minimum
exceeds it *before sending*. That refusal is not a boot failure: it means the
running daemon cannot serve those surfaces, and the client says so rather than
showing an empty pane.

The consequence, stated as the guarantee: `hello`, `overview.get`, `logs.query`,
`lifecycle.prepare` / `commit` / `cancel`, `doctor.*` and `diagnostics.build`
work against a daemon one release behind, so a client can always read the state,
explain it, and restart that daemon onto a newer engine. Only the v2-only
surfaces refuse until then.

Fields a daemon adds to a method after that method's minimum version, whether
a v2 daemon adding to a v1-minimum method or a later protocol-2 engine adding
to a v2 method, are **optional**, with a defined absent rendering, and move
neither the protocol version nor the method's minimum, because the direction
that breaks is a new client talking to an old daemon. `overview.get`'s
`health.restart_reasons` absent means "restart to apply" with no reason list; a
Doctor check's `remediation` absent means the summary renders with no action
button.

## Request envelope

```json
{
  "request_id": "req-1",
  "protocol_version": 1,
  "method": "hello",
  "params": {}
}
```

- `request_id` — required, `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`. Echoed on
  every response; a client that receives a different id must discard the frame.
- `protocol_version` — required integer, negotiated against the window above.
- `method` — required, from the catalog below.
- `params` — optional object, defaulting to `{}`.

Unknown top-level fields are refused with `invalid_request`, naming the field.
Every method declares its own parameter set: input-free methods refuse any
params at all, and params-carrying methods refuse an unknown key rather than
ignoring it.

## Response envelope

A response carries **exactly one** of `result` or `error`, never both and never
neither.

```json
{ "request_id": "req-1", "result": { } }
```

```json
{
  "request_id": "req-1",
  "error": {
    "code": "unknown_session",
    "message": "The Doctor session is not retained by this daemon.",
    "details": { "session_id": "doctor:9Fj2mQ" }
  }
}
```

`code` is from the stable catalog below, `message` is a fixed operator-facing
sentence owned by the daemon, and `details` is a bounded object of public
scalars. No `inspect(reason)` output, internal term, filesystem path, or Setup
token ever crosses this boundary. `request_id` is `null` only when the request
was so malformed that no valid id could be recovered from it.

## After a move: requests the primary answers

When the owner moves Fermix to another host (M75), the computer it moved from
keeps its engine in the device role and keeps this socket, so the app changes
nothing. That engine answers a request about this computer itself and sends
every other one to the primary over its encrypted session, after this
socket's own placement of the caller (an owner decision from a process the
engine started is refused here, as above, and never sent). The answer is the
primary's, exactly as its own socket would give it.

- **Answered on this computer** (device-class): `hello`, `lifecycle.*`,
  `diagnostics.build`, `logs.query`, `doctor.*`, `setup.session.create`,
  `setup.detect`, `coding_agents.check` (this computer's own coding agents),
  `computer_use.*`, `imessage.*`, `accessories.*` (the
  robot is wired to this computer), `computer.*` (this computer's own
  record of what its server did here, `computer.journal.list`, the Stop
  beside the mark while its server controls its screen,
  `computer.screen.stop`, and its own link to a home, `computer.join.start`,
  `computer.join.cancel` and `computer.disconnect`),
  `browser.install.start`,
  `capabilities.install.start`, Always On's steps (`home.act`: a move back
  and Restore here are this computer's own, and `home.act` sends the server's
  own steps itself, below), and `settings.get` and `settings.apply` for a section
  that configures only this computer: `sandbox`, `computer_use`,
  `computer_history`, `accessories`, `computer` (what Fermix on the server
  may use on this computer, which the server can never write; its `imessage`
  switch says this Mac carries Messages) and `harness_machine` (whether coding
  agents may run on the machine that answers, published only where they run:
  a linked computer publishes none, and leaves its server's out of the
  composed inventory, since the server approves its own). `channels.imessage` is the home's:
  that the home uses iMessage, its owner and its guests are the primary's, and
  a linked Mac asks for them there, while who Fermix may write to is confirmed
  on that Mac (`imessage.policy.confirm`, which reads the primary's owner and
  guests).
- **Composed** (answered here, with the primary's own part): `home.status`
  answers this computer's facts and adds `primary_home`, the primary's own
  `home.status`; `settings.sections` lists this computer's own sections and
  the primary's others. The primary's part is asked within 5 s; while it is
  missing (unreachable, or no answer in time) this computer's part is still
  answered and `primary_missing` holds the sentence that says why. The primary
  answers a composed request a desktop forwards as its own.
- **Answered by the primary** (primary-class): every other method, the
  home's recovery and the servers it holds included (`home.snapshots.status`,
  `home.snapshots.passphrase`, `home.candidates.list`), and the names of the
  home's computers (`computers.rename`): after a move the server holds them.
- **Rail-only** (Always On setup §3.5): the server's Always On steps,
  `home.move.readiness`, `home.move.start`, `home.enroll.open` (both kinds),
  `home.enroll.withdraw`, `home.enroll.approve`, `home.enroll.deny` and
  `home.snapshots.run`, are primary-class and
  answered only to a desktop's forward, which a linked desktop's own
  `home.act` sends (Back up now, Check again, Add a computer and its Add it
  and Do not add it, and a move back's Move back,
  Move now, Try again and Cancel). On this
  socket, in every role, each is refused by name before anything else:
  `unavailable`, `details.capability` `home`, `details.method` naming it and
  `details.sentence` `Always On takes this step itself: send home.act with
  the action the summary offers.`
- While the primary cannot be reached, a primary-class request is answered
  `primary_unreachable`, `details.primary` naming it and `details.sentence`
  saying so: `The server <name> is unreachable. Fermix keeps your message until
  it is back.` One the primary did not answer within its forward deadline
  (below; work longer than that is a job on the primary, answered at once) is
  answered the same way, with the sentence that it did not answer in time. A
  desktop the primary revoked says so instead, and one whose session the
  primary ended normally (a daemon stopping) says the link was renewed; a
  primary that ends the renewed session normally again within a minute is an
  outage from then on, redialed with the backoff.
- **The link's state in one word.** `home.status`'s `primary.status` is one
  of `connected` (a session is up), `renewing` (a session opening with
  nothing known to be wrong: the first since the engine started, or the quiet
  renewal above; draw it quietly, not as an outage), `unreachable` (an
  outage, the renewal loop included, retried with the backoff; also a link
  this engine refused to use), `revoked` (the primary no longer knows this
  computer; not retried until the engine restarts) and `stale` (the primary
  answered as an older copy; retried). A redial during an outage keeps the
  outage's word until a session is up; `sentence` says the rest.
- **The link's path.** While a session is up, `primary.path` says how it
  runs: `direct` (a direct UDP path, a tailnet address included) or `relay`
  (through Fermix's relay), as the iroh helper reported it when the session
  opened and at each change after. It is absent while no session is up,
  before the helper names it, and from an engine older than the field, which
  a client draws as no path.
- **Forward deadlines.** How long the computer waits for the primary's answer
  to a forwarded request:

  | Method | Deadline | A client's own timeout for it |
  |---|---|---|
  | `home.move.readiness` | 60 s | at least 65 s |
  | `home.move.start` | 60 s | at least 65 s |
  | every other forwarded method | 8 s | the usual 10 s |

  The two move calls walk the whole home on the primary before they answer
  (60 s holds a home at the archive's 100,000-file bound walked at the slowest
  rate measured). A client gives them at least 65 s on every engine, a primary
  included, where the same walk runs in the call itself.
- **A move's start whose answer was lost is `unconfirmed`, never a failure.**
  When the primary had the `home.move.start` a desktop's `home.act` sent and
  its answer did not arrive (the deadline passed, or the session ended under
  it, as it does when the primary restarts into the move right after
  answering), `home.act` answers `unconfirmed`, `details.method`
  `home.move.start`, `details.primary` naming the server and
  `details.sentence` `The server <name> did not confirm in time whether the
  move started. Its state shows once the server answers again, and starting
  it again never starts a second move.` The desktop records the move back's
  start either way, and the client reads what happened from
  `home.status`; a second start is refused while one runs.
- The primary refuses a device-class request that reaches it anyway with
  `device_class_method`, `details.method` naming it.

A computer that runs in the device role without having moved this way (no
link to a primary) forwards nothing, and refuses as before.

An engine in the **candidate role** (a fresh host enrolled with `fermix home
enroll`, waiting for the move that makes it the primary) answers `hello` and
`home.status` and nothing else. Every other method is `unavailable`, with
`details.capability` `candidate` and `details.sentence` `This engine is a
candidate primary waiting for its move; it answers home.status and nothing
else until the move makes it the primary.` Its `home.status` reports `role`
`candidate`, `move` with `candidate` null, and `snapshots` that say they are
the primary's.

## The server leads

An Always On server updates itself from the release channel; its computers
are clients with a window (M97). It reads the release table fermix.ai
serves (`https://fermix.ai/install/releases`, the one the installer
trusts) every five minutes, and a release is eligible once, for each
system whose computers keep the home's backups, a published app carries an
engine that reads the home that release writes. `home.status.update` says
what it found:

| Field | Meaning |
|---|---|
| `running` | this engine's version |
| `eligible` | the newest eligible release at or above `running`; null when there is none or no table was read, and the update then installs nothing |
| `held` | `{version, waits_for, sentence}`: a newer release not eligible yet, the systems whose app it waits for (`macos`, `linux`, `unknown` for a computer that has not said its system), and a sentence that names no version; null when there is none |
| `ahead_of_apps` | `true` once no published app for some backup system reads the home this engine writes, after an owner's override |
| `table` | `{read_at, sentence}`: when the table was last read, and the sentence of a fetch that failed or of why none was read; each null otherwise |

`update_ceiling` is `update.eligible`. A computer stands against the
server's version by major.minor, never by patch (`computers[].standing`,
and `hello_ack.caps.computer.standing` on its link): `current`, `behind`
(the same major, at most two minor versions behind: served as `current`
is), `ahead` (newer, speaking the server's versions) or `settings_only`
(further behind, or an older major: its link carries settings alone, its
chat is refused and it offers nothing until it updates; its summary is the
`update` problem in its own sentence).

That window is about the wire. Whether an engine can take a home into its
keeping (a restore, Restore here, a move, a move back) is the home's
**format** (M97 D16), never the engine version that wrote it:
`home.status.home_format` is the format this engine reads and writes, and
every archive, snapshot and move stream names its own. An engine reads a
home of its format or an older one, whichever engine wrote it, and refuses a
newer one before anything is written; a home or an engine that names no
format is from before home formats, and such a home is format 1. The format
is raised only by a release that writes something an older engine cannot
read, so most releases restore on an older app, and the release table names
each release's format in a `home_format <engine_version> <home_format>` row,
which the gate above reads; an app whose engine the table names none for
reads only its own release's home or an older one's. Where this engine
cannot read the home its server writes (by `primary_home.home_format`), the
summary offers `update` in place of Move back and Restore here.

## The Always On summary

**Not in a release build yet.** A build compiled for production serves no
Always On: `hello` lists none of `home.status`, `home.act`,
`home.enroll.approve`, `home.enroll.deny`, `computers.rename`,
`computer.join.start`, `computer.join.cancel`, `computer.disconnect`,
`computer.journal.list` and `computer.screen.stop` (in `methods` or
`minimum_versions`), and each is refused
by name, `unavailable` {`capability`: `always_on`, `method`, `sentence`:
"Always On is not in this release of Fermix yet."}. A client shows no Always
On where `hello` lists no `home.act`. Every other `home.*` method is served
as ever.

**An app from before the pane's draft 3** (one that knows `learn_more`,
`detail.actions`, `detail.data` and `detail.review`) keeps working under
the protocol's rule for fields (*Versioning*): every field this summary adds
(`help`, `note` on any state, `steps`, `route`, `transfer`, `backup`,
`webhooks.url`, `own_server`'s `sentence` and `tailscale`'s `label` and
`url`) is one it ignores, and every field it no longer carries is one such
an app reads as optional, with its absent rendering: no `detail.actions`
(`on`'s steps are in `detail.alternatives`, which it draws the same way), no
`detail.data`, no `detail.review` (a review is `on`'s `action`
`review_offers`, sent with no `keep_offers`: the switches as they are), no
action `url` and never `learn_more` (no help control until it reads `help`).
Neither the protocol version nor `home.status`'s minimum moves.

`home.status.summary` is the Always On screen, worked out once by the engine
(M75 lean v1 §7, Always On setup §3), so the Mac app, the Linux app, the
setup page and `fermix home status` draw the same thing. The server is the
owner's own: a Linux server they set up and install Fermix on with the
command `own_server` answers; Fermix creates, powers and deletes no server.

```json
{"key": "Hpj619zuAVxgXXRVumw26w", "state": "problem",
 "sentence": "Fermix cannot reach your server. Your messages wait until it is back.",
 "action": null,
 "detail": {"kind": "cannot_reach", "seen_at": null,
            "note": "Check that your server is on and online. If it is gone for good, restore Fermix on this Mac.",
            "alternatives": [{"id": "restore_here", "label": "Restore on this Mac",
                              "needs": ["recovery_passphrase"],
                              "confirm": "Restore Fermix on this Mac from its backup of Sunday, May 4, 2031 at 12:00 PM CEST?\nConfirm only once you deleted your server, or stopped it for good: if it runs again, two copies of Fermix answer the same channels.\nMessages, memory and jobs since that backup are gone.",
                              "key": "er-r-ReXG6gOEo4Q7ANhcQ"}]},
 "notice": {"id": "cannot_reach:2031-05-04T11:49:00Z",
            "sentence": "Fermix cannot reach your server. Your messages wait until it is back."},
 "outcome": "failed",
 "help": "https://fermix.ai/docs/always-on/#when-the-server-is-gone"}
```

**One sentence and at most one action per screen** (the Always On pane,
draft 3). A client maps `state` to its screen and draws, top to bottom:
`sentence` as it is (a screen's own words are at most 20 words); under it
`detail.note`, the one secondary sentence, on any state (what the owner must
know or do now: the wait, why a move was undone, what to check, what to do,
a failure's own words), never in Details; the step in hand
(`detail.progress`, with `detail.steps`, `detail.route` and
`detail.transfer` where the screen has them); the blocks of
`detail.readiness`; then `action`, the one main step, or none, and every
other step (`detail.alternatives`) beside it as equal buttons. `action` is
null while a step runs (`outcome` `running`): Cancel, where it is offered,
is then an alternative. `detail.lines` sit behind Details and are facts
only. `help` is the Always On docs page at the screen's anchor, which a
client opens from one help control (the Mac's help button, a Learn more row
on Linux, a link on the setup page, the CLI's last line): background,
caveats and alternatives live there, and no action is ever Learn more. Every
word is the engine's: none names an epoch, the primary, a candidate, the
relay, the rail, a phase, an item id or a key id.

`help`'s anchors are the contract with the docs page: `what-you-need`
(`off`), `set-up-your-server` (`connect`, the owner's server connecting,
`candidate`, `not_set_up`, `waited_too_long`), `tailscale` (the code's
Tailscale step), `the-move` (`ready`, `not_ready`, `moving`, `undone`),
`on-your-server` (`on`, `primary`), `webhooks` (`detail.webhooks.url`),
`backups` (`backup_old`, `backup_failed`), `when-the-server-is-gone`
(`cannot_reach`, `retired`, a restore), `updates` (`update`,
`server_older`, `server_ahead`), `server-disk` (`disk_full`), `move-back`
(the move back's screens, `return_failed`) and `add-a-computer` (a computer
that asks to join, and the computer that joins).
An engine that sends no `summary` is older than this record: the apps answer
it with their "update Fermix" screen, so they raise their own minimum for
`home.status` to an engine that sends it.

**Every action is one record**, wherever it sits (`action`,
`detail.alternatives`, `detail.backup.change`): `id`, `label`, `needs`,
`confirm` and `key`.

- `needs` lists what the surface collects before it acts:
  `new_recovery_passphrase` (Move now and Try again where this move's
  recovery key is not set yet: the surface asks for it twice and compares
  the two) or `recovery_passphrase` (where one is set, and on a move back,
  whose key is the server's own: asked once, and the move checks it).
  Either passphrase is sent as `input.recovery_passphrase`; `restore_here`
  needs `recovery_passphrase` too, the key the copy it restores was written
  for, and `change_passphrase` needs `new_recovery_passphrase`.
- `confirm` is what the owner accepts before Fermix moves, restores, forgets
  a server or changes the recovery passphrase; null otherwise. Its parts are
  one per line (`\n`): the question, then each thing it says, which an
  alert, a sheet, a terminal and a page (`white-space: pre-line`) draw as it
  is. It never carries a time that moves with the clock, so it is stable.
  Move now's asks "Move Fermix to your server now? You can move it back to
  this Mac any time.", then says each warning: those the review's items this
  home's settings decide give now (`stays_here`, `whatsapp`, `slack`,
  `coding_agents`, `cutover_gap`, `serves_nothing`, in their own words; a
  review's older word for one of them gives way), and every other warning the
  last review of the same server gave. `ready` draws no warning of its own,
  so this is where the owner reads each before anything moves. During a move
  back it says what runs on this computer again and what the move back
  costs, each only where this computer's settings have it (Telegram set up;
  coding agents cost nothing, since this computer keeps its own approval,
  M98 D5). Restore here's names the date of the backup it restores, stated
  absolutely in the owner's zone, asks the owner's word that the server is
  deleted, or stopped for good, and names Telegram's 24 hours only where this
  computer's settings have it set up. Forget this server's (`cancel` on a
  held server) asks before the server is dropped, and Change's
  (`change_passphrase`) says that backups made before keep opening only with
  the passphrase set before.
- `key` is the digest of the action's `id`, `label`, `confirm`, `needs` and
  the one thing it acts on: the server a move goes to (`move_now`,
  `try_again`, `check_again`), the server Forget this server drops
  (`cancel` on a held server), the copy a restore takes (`restore_here`), or
  nothing; during a move back, the server a move goes to is this computer's
  own candidate.

**The keys.** `summary.key` is the one digest of the summary: of everything
it holds but `key` itself, the sentence of an `off`, `on` or `problem` (whose
figures move with the clock; not a `backup_failed` problem's, which names its
try's own time and words) and what was last seen (`detail.seen_at`). A
change of the state, a step's sentence, an action, a confirm, an
alternative, a line, the progress or the notice moves it. It is what the
companion socket's `home_status_changed` and a waiting `home.status` (below)
compare.

**`detail`** holds what the state draws, a field only where it has
something: `note` and `alternatives` (above); `lines` (the Details, facts
only, `{label, value}` each, finished by the engine: the server, its system
and version, each place's newest backup and the S3 bucket where the server
keeps an S3 copy, the space this computer's copies take and the server's
disk, the move back's own refusal where Move back is not offered, the
link's path; times stated absolutely in the owner's zone; on `ready`, `on`
and `problem`); `progress` (the sentence of the step in hand while a move, a
move back, a restore or a backup runs: for the move "Packing your home…",
"Sending your home to <server>…", "<server> is unpacking your home…",
"Switching over to <server>…"); `steps`, `route` and `transfer` (see *A
flow's steps and progress*); `backup` (see *Backup settings*); `webhooks`
(see *Inbound webhooks*); and `keeps_on` (see *What a computer keeps on for
its server*). The raw facts beside them (`server`, `waits_until`,
`backups`, `copies_bytes`, `disk_used`, `kind`, `seen_at`) are for machines;
their words are the lines and the note.

**A flow's steps and progress.** Every screen of the move to the owner's
server (`connect`, `creating`, `ready`, `moving`, `undone`) and of the move
back (its `creating`, `ready`, `moving`, `undone`) carries `steps`, its four
steps in order as one line that never wraps, `{label, state}` each: the
move's Connect your server, Move now, Send your home, Switch over, and the
move back's Get this Mac ready ("this computer" off a Mac), Move now,
Receive your home, Put Fermix in place; `state` is `done`, `active` (it
runs), `yours` (the owner takes it: the screen's action, or on `connect`
running the command on the server) or `pending`. A screen that waits on the
owner says so in its sentence ("… when you press Move now"), and a step done
is never worded as the flow done. While either flow moves (`moving`),
`route` is `{from, to, direction}`: this computer ("This Mac", "This
computer"), the server's name, and `forward` (the home goes to the server)
or `back`. `transfer` is present only while the move's bytes move: the bytes
the source handed to the link (the move) or the bytes this computer received
(the move back) over the home's size, counted in whole twentieths
(`fraction`, 0 to 1) with its words (`label`, "700 MiB of 1.4 GiB sent");
the count changes the summary's key at most 20 times per transfer, and a
client never fills ahead of it nor shows a percentage or a time the engine
did not send. Where nothing is counted (packing, unpacking, switching over,
a restore, a backup) there is no `transfer`.

**Backup settings** (the pane's §3.12). Backups show only once the home has
a server: a Mac that never moved has none, and the `snapshots` settings
section ("Backup settings") is listed only where the primary is an Always
On server. On a linked desktop's `on`, `detail.backup` is `{passphrase:
{label, value, footer}, change, s3}`: whether the recovery passphrase is set
("Recovery passphrase": "Set" or "Not set"; the recovery key is never
shown), `change`, the `change_passphrase` action ("Change", needs
`new_recovery_passphrase`, with its confirm; sent to the server, which sets
it as `home.snapshots.passphrase` does), and `s3`, "Also kept in S3, set up
with your server." where the server's S3 target is configured, null
otherwise (the app sets no part of S3). The server's own `primary` carries
none: its summary rides inside each desktop's `home.status`, where
`change.needs` would pass `max_json_depth` (*Bounds*).

**What a computer keeps on for its server** (M97, D27). Fermix on the
server may use the computer it moved from, and every computer linked to it,
only for what that computer keeps on: its switches on the computer itself
(the `computer` settings section, *Notes*), which the server can never
write, one for files and commands together, and computer history's own
recorder setting. Before the move, one block says it, `{sentence, warning,
lines}`: `sentence` asks the owner to tick what stays on ("Tick what Fermix
on your server may still use on this Mac after the move.") and, on a Mac,
says where a ticked history goes ("Ticked, each sitting of your computer
history goes to your server, which keeps its summary."); `warning` is the
plain warning where files and commands stay on while this computer's
sandbox is open ("With files and commands on and this Mac's sandbox open, a
server that is taken over can read and change this account's files on this
Mac."; null otherwise), and `lines` are one per thing this computer's system
can have, in order (`files_and_shell`, `browser`, `computer_use`,
`imessage`, `history`; a Linux computer lists no `imessage` or `history`),
each `{offer, label, on}`: what it decides, its words ("files and commands
(standard)", with the sandbox mode they run in, "the browser", "your
screen", "Messages", "your computer history") and whether it stays on. A
surface draws `sentence` and `warning` as they are and each line as a tick
the owner may change, and sends the lines left ticked as `home.act`'s
`input.keep_offers`. The history line sets that computer's recorder: ticked,
it records (and so offers its history); left unticked, it stops. An app from
before D27 drew `files` and `shell` as two lines and sends them so: both
keep `files_and_shell` on, one alone keeps it off.

- `keeps_on`, on the computer that sets Always On up, in `ready`'s
  `detail`: what this computer keeps on for its server after the move.
  Files and commands and the browser are ticked; its screen, Messages and
  its computer history are ticked where their own settings have them on.
  Move now and Try again send the lines left ticked (absent: the block as
  shown), the move records them when it is accepted, and the computer
  writes exactly those when the move commits (the recorder first, then the
  switches), so a move that is undone leaves no switches behind. Never on a
  server, and never on a move back.
- A linked computer that moved before M97 offers its server nothing until
  the owner reviews its switches, which are set in one place, its `computer`
  settings section ("This computer"), so the summary carries no block of its
  own for them (one source of truth: a tick drawn twice on one screen could
  disagree with the switch it stands for until it was saved). Its `on` says
  so in `detail.note` ("Fermix on your server can use nothing on this Mac
  until you review the switches under This computer.") and its `action` is
  `review_offers` ("Keep these switches"; no needs, no confirm), which takes
  the switches as they are and the recorder as it is; the notice
  `computer_review` says it once. Saving any switch of the `computer` section
  is the review too. An app from before this sent the lines of a `review`
  block it drew as `input.keep_offers`: still read, they stay on, everything
  else is switched off, and the history line sets the recorder as at a
  move.

**Adding a computer (M97).** A computer joins a home that already runs with
a code and a six-digit check, and moves nothing.

- A linked computer's `on` and the server's own `primary` list
  `add_computer` ("Add a computer"; no needs, no confirm) in
  `detail.alternatives`. Its `result` is `{code, expires_at}`, answered once: the
  code works once, for thirty minutes, for a computer and for nothing else.
  While a code for the owner's own server is open the step is refused
  (`unavailable`, "A code for your own server is open. Use it or cancel it
  before you add a computer."), and that code stays as it is.
- The new computer takes the code in `computer.join.start` (or `fermix
  computer join CODE`, with Fermix stopped there). Its own `home.status` then
  carries `join` and its summary is `creating` with `cancel` beside it (no
  action: nothing is the owner's to do there while it dials or waits):
  "Connecting this Mac to your Fermix on <server>." (`outcome` `running`),
  then, once the server answered, "Type 482 913 on <server>, where it asks
  you to add this Mac." (`outcome` `waiting`; "this computer" on Linux). The
  digits show only here, on the computer that asks: they prove the computer
  the owner looks at is the one asking, so the owner reads them here and
  types them where the home asks. A
  join that was not added says why in its sentence (`outcome` `failed`),
  with `cancel` its action; `cancel` makes the computer its own home
  again.
- While that computer waits, the server's `primary` and every linked
  computer's `on` carry the request: the sentence is "A computer named
  loft-linux (Linux) asks to join your Fermix. To add it, type the six
  digits it shows.", `action` is `approve_computer` ("Add it"; `needs`
  `["sas"]`: the surface asks the owner for the six digits they read on the
  new computer and sends them as `input.sas`), and `deny_computer` ("Do not
  add it") is first in `detail.alternatives`, then the step the screen led
  with before (`review_offers`, while a review waits). No screen of the home holds
  the digits: neither the summary nor `enrollment.joiner` carries them. The
  key of `approve_computer` binds the computer that asks (its name and
  system), so a second computer that takes the place of the first answers
  `changed`. Digits that are not the computer's are refused on `sas`
  ("Those digits are not the ones the new computer showed, so it was not
  added. Open a new code to try again."), the computer is not added, and
  the code is spent. Until the owner approves, the new computer has no row
  and no access; a refusal, a wrong code, a session that ends while it
  waits and the window's half hour running out add nothing, and the code is
  spent either way.
- An added computer is listed in `computers` at once, with every offer off
  and `backups` false, and the window names it until another code is
  opened: the notice `computer_joined:<device id>` says "A computer named
  loft-linux joined your Fermix." once on the owner's other surfaces. Its
  own summary offers no Move back and no Restore here: those are offered
  only where the home moved from this computer (its moved marker).
- A phone is no approval surface yet.

**Inbound webhooks.** On a linked desktop's `on` only, where its server
serves a webhook the internet must reach, `detail.webhooks` is `{sentence,
mounts, notes, url}`: the Tailscale Funnel mounts the owner runs on the
server, in the engine's words. The server's own `primary` carries none: its
summary rides inside each linked desktop's `home.status` as `primary_home`,
where `detail.webhooks.mounts[].command` would sit one level past
`max_json_depth` (6, *Bounds*), so a desktop's `home.status` would be
refused as `invalid_result`. `sentence` says what needs them, naming only
what the server serves ("WhatsApp and your webhook sources need a public
address to reach your server. Run each command once, on the server.");
`mounts` lists `{label, command, note}`, WhatsApp's first
(`/webhook/whatsapp` on the web listener's port, one mount for Meta's GET
check and its POSTs; its `note`: "Then set the address it prints as Meta's
Callback URL, with your verify token."), then each webhook source's (its
prefix, `/cues/hooks/<ref>`, on the cue door's port: Tailscale passes the
rest of each request's path to the door, which answers only that source's
own `/cues/hooks/<ref>/<random>`, so no command carries the URL's secret;
its `note`: "In the sender, change the host of the source's webhook address
to the one it prints."). Every command starts with `sudo `: the server's
first boot names no Tailscale operator, so only root changes its serve
config. `notes` holds one note, the step a tailnet takes once ("These use
Tailscale Funnel. Once per tailnet, let tag:fermix-server use Funnel, and
turn on MagicDNS and HTTPS certificates."), and `url` is the docs page
(`#webhooks`) that holds the rest: Cloudflare Tunnel to the same loopback
ports instead, that Funnel publishes whatever `tailscale serve` has on port
443, Tailscale's ingress, and the wait for a new address. The values are the
server's own (its `home.status` `webhooks`; a desktop reads them in
`primary_home`), never this computer's. A surface draws the sentence, each
mount folded under its label with its command (and a way to copy it) and
its note, then the note and a link to `url`. No `webhooks` where the server
serves none.

**`outcome`** is what a surface following a step reads, so none keeps its
own table of states: `running` while Always On is at something that moves
the screen on by itself (the server connecting; the move, from its request
here, whose screen reads `ready` until the restart shows, to its end or
undoing; a server receiving its home; a restore; a backup, on a screen that
offers `back_up_now`, while it runs, so `back_up_now`'s screen runs until its
backup ends), `waiting` while it waits
on the owner's server to use its code, `failed` on a `problem`, and `done`
when the next step is the owner's. A surface that waits for a step it sent
follows the screen while the outcome is `running` (or `waiting`, right after
the step that opened the code), and reports a `failed` one as the step's
failure.

**`notice`** is the occurrence the apps raise as a system notification, or
null: the server ready (`ready:<candidate>`), the move done
(`moved:<epoch>`, until the first backup after it), the server out of reach
(`cannot_reach:<since>`, since the link went down), the newest backup a week
old (`backup_week:<at>`), Fermix back on this computer after a move back,
whose server still runs its retired copy (`back:<epoch>`, the epoch it came
back at), Restore here finished, naming the day of the backup it restored
(`restored:<epoch>`), and a held server whose 24 hours ran out, which must
be set up again by running its command with a new code
(`server_lapsed:<candidate>`, on the `off` it leaves, until a new code is
opened), a computer that joined the home (`computer_joined:<device id>`,
while the server's window names it), a linked computer whose switches wait for the owner's review
(`computer_review`, while it waits: "Fermix on your server can use nothing
on this Mac until you review what it may use."), and a server whose own
settings file left out what it had inherited from the computer it moved
from, so it now uses its own sandbox setting (`server_sandbox:<at>`, for a
week after: "This server now uses its own sandbox setting: open. The
settings it had from your computer stay on that computer."). Its `id` stays
the same while the occurrence stands, so an app posts when the id changes
and keeps the last one; the page and the CLI ignore it.

**Waiting for a change.** `home.status {after, wait_ms}` (`wait_ms` at most
25,000) answers at once when `summary.key` is not `after`; otherwise the
daemon holds the request, reading the summary again each time the Always On
watch says something it rests on changed, and answers when the key differs or
`wait_ms` passed. Off tells nothing and a candidate runs no watch, so a wait
there runs out. A client gives the call `wait_ms` plus 5 seconds.

A client need not read the summary on a timer: on the companion chat socket,
`home_status_changed` (companion protocol 6) says when it changed, once after
the hello unless the state is `off` (`priv/companion/PROTOCOL.md`, *When
Always On changes*).

| `state` | Where it is answered | What it means |
|---|---|---|
| `off` | the computer that sets Always On up | Nothing is set up: "Keep Fermix running when this Mac sleeps. It moves to a server you own." (what stops after the move is Move now's confirm). Its action is `own_server`, labelled `Use my own Linux server`, which opens a code for the owner's server; its `result` holds the code, the command that installs Fermix there, the sentence the code is shown with and the optional step that also joins the server to the owner's tailnet. |
| `connect` | the same | A code for the owner's server is open: "Waiting for your server to use its code." No action; `detail.alternatives` holds `own_server` (`Replace the code`: a new code in place of the open one, which a server may be using already) and `cancel` (`Cancel the code`); `steps` mark Connect your server as the owner's. |
| `creating` | the same, and a linked desktop | The owner's server used its code and connects (`cancel` in `detail.alternatives`, `Cancel the code`, which closes it; once the code's 30 minutes are over with no server recorded, the window reads `expired` and the screen is `off`), or a linked desktop connects to its server to move back (`cancel` in `detail.alternatives`), or this computer joins a home with a code (*Adding a computer*). No action while it connects. |
| `ready` | the same, and a linked desktop during a move back | The server is held, and Fermix has not moved: "Your server is ready. Fermix moves to it when you press Move now." (during a move back, "Fermix still runs on your server. It moves back to this Mac when you press Move now."), `note` until when it waits, `steps` with Move now the owner's. `detail`: `server` (`{name, system, version}`), `waits_until`, and on the computer that sets Always On up `alternatives` with `cancel` (`Forget this server`, with a confirm: the held server is dropped and the screen is `off`), except while a move to it runs, and `keeps_on`, what this computer keeps on for its server after the move (*What a computer keeps on for its server*); during a move back `alternatives` with `cancel`. No warning on the screen: they are Move now's confirm; a review that blocks makes the `not_ready` problem. |
| `moving` | the computer the move leaves, and a linked desktop during a move back or a restore | The move runs; once that computer waits on the server's confirmation the sentence says Fermix keeps trying. `progress`, and on the move and the move back `steps`, `route` and, while bytes move, `transfer` (*A flow's steps and progress*). |
| `on` | a linked desktop | Fermix runs on the server. `detail`: `server` (`{name, version}`), `backups` (`{place, at}` for each place's newest verified backup), `copies_bytes` (the space this computer's copies take), `disk_used`, `alternatives` (`back_up_now`, `add_computer`, and, only where the home moved from this computer, `move_back` where this engine starts again by itself; one run from a terminal has a `Move back` line instead, saying why in the move back's own refusal; where this engine cannot read a home the server's engine writes (a newer one), `update` labelled `Update Fermix on this Mac first` stands in place of `move_back`, as it does of `restore_here` wherever that would be offered), `backup` (*Backup settings*) and, where the server serves any, `webhooks` (*Inbound webhooks*); while this computer waits for the owner's review of its switches, `review_offers` is its action and `note` says where they are (*What a computer keeps on for its server*); its `lines` end with `Connection` while the link's session is up and its path is known: `Direct`, or `Through Fermix's network` through Fermix's relay. |
| `undone` | the computer the move left | The move was undone and its server is still held (`try_again`, and `cancel`, `Forget this server`, with `ready`'s confirm in `detail.alternatives`, once the undoing is over; `note`, why, in the move's own words, where its record has them), or the engine is restarting as it was (no action). |
| `retired` | a computer the move left | It has no link to the server, or the server no longer knows it. On a server's own copy that a move back left serving nothing, the sentence names where Fermix moved back to (the marker's `to`). `restore_here` in `detail.alternatives` where it applies (*Moving back*). |
| `candidate` | the server, before its move | It waits for its move, or receives the home. |
| `primary` | the server, after its move | Fermix runs there. `detail.alternatives` holds `add_computer`; while a computer asks to join, the sentence names it and the action is `approve_computer` (*Adding a computer*). No `detail.webhooks` and no `detail.backup`: its desktops' `on` draws them. For a week after its own settings file left out what it had inherited, its `notice` is `server_sandbox:<at>`. |
| `problem` | anywhere | `detail.kind` names it, `detail.note` adds one sentence where the screen has one (what to check or do, a failure's own words), `detail.seen_at` is when Fermix last saw what it rests on, and `detail.alternatives` lists the other steps. Its action is the one step that fixes it, or none where no step of the owner's does. |

Problems (`detail.kind`): `cannot_reach` (no session with the server for 10
minutes while this computer is awake: no action; its note says to check
that the server is on and online and, where Restore here is offered, that
it is the answer once the server is gone for good), `not_set_up` (on the
server, its enrollment failed), `waited_too_long` (on the server, it waited
past its 24 hours for its move; both say to open a new code and run the
command there again; no action), `update` (the server speaks a protocol this engine
is too old for; or, in a sentence of its own, this engine is past the
server's window, more than two minor versions behind the server's
`version` or on an older major, so it keeps its link for settings alone:
`update`), `server_older` (the server refused this engine's protocol as
newer than its own, `daemon_too_old`, because this computer updated
first: its note says the server updates on its own once the app for each
computer that keeps the backups carries the newer release, since the server
leads from the release channel (*The server leads*); no action),
`server_ahead` (the server runs a release whose home no published app
reads, its `update.ahead_of_apps`, after an owner's override, and this
engine cannot read the home it writes, by its `home_format`: until this
computer's Fermix catches up, a restore here would be refused; `update`),
`disk_full` (85% or more; its note says to free space or give the server a
bigger disk; no action), `backup_old` (the
newest backup is over 3 days old, or none since a move that long ago),
`backup_failed` (on a linked desktop, and on a server with desktops: a
backup that failed, until a backup is stored at the place it failed at; the
sentence says where it went ("Backing up to S3 failed."), its note the
newest failed try's own words and when ("S3 could not be reached: the
connection timed out. Tried Sunday, May 4, 2031 at 1:00 PM CEST."),
`detail.seen_at` that try's time, and `back_up_now` its action; a later try
that fails in other words moves the key, since the note is in `detail`),
`not_ready` (the last review blocks the move: "The move cannot start yet.",
`check_again`, its blocks alone in `detail.readiness`, and `cancel`, Forget
this server, in `detail.alternatives`) and `return_failed` (a move back to this computer that
ended or stopped part-way: `move_back` again, `cancel` where it stopped with
no record of it, or `restore_here` again for a restore).

**Moving back** (Always On's move back: the home comes back to the computer
it left). On a linked desktop, `on` offers `move_back` ("Move back to this
Mac", "this computer" off a Mac; no needs, no confirm) where its engine
starts again by itself (see `on`). Once pressed, the
desktop's own move back leads its screen, ahead of everything else, the link
gone included: `creating` while it connects to the server (no action,
`cancel` in `detail.alternatives`), `ready` once the server holds it
("Fermix still runs on your server. It moves back to this Mac when you
press Move now.", its note until when this computer waits: `move_now` needs
the server's `recovery_passphrase`, its confirm built on the desktop says
what runs here again; `cancel` in `detail.alternatives`; `detail` the server
and `waits_until`; its notice says the same: "Fermix still runs on your
server. Open Always On and press Move now to move it back to this Mac."),
`moving` from the server's start of
the move until this computer restarts as the primary (`detail.progress`:
receiving, waiting for the server to hand over, putting Fermix in place;
no action), `undone` when the server undid it (`try_again`, `cancel`), and
`problem` `return_failed`. Move now records its start before the request
leaves, and keeps it unless the server refused it or it never left; from
then on `cancel` is offered only once the server undid the move, or answers
as the primary with no move under way (`ready` again, or `undone` while
this computer had begun to receive), never while its move runs, once it
retired, or once the home is being put in place here. A stop part-way that
leaves the start recorded with no candidate, while the server answers as
the primary with no move, is `return_failed` with `cancel`. A move back the home went past (another
desktop took it, at a newer epoch) is dropped, and not drawn. Where
nothing answers from the server (`cannot_reach` once it has had no session
for 10 minutes, or `retired` with no link at all; a server that answers it
no longer knows this computer, or a retired copy that answers, is not
silent) and this computer keeps a copy of its snapshots,
`detail.alternatives` adds `restore_here` (needs
`recovery_passphrase`; its confirm asks the owner's word that the server is
deleted, or stopped for good, since a server that runs again answers the
same channels as the restored copy, names the date of the copy it restores
and says what is lost). Fermix deletes no server for it: one job of its own
(`home_restore`) restores the copy, and the screen is `moving` from the
press until this computer restarts as the primary. A restore that stopped
before its copy was in place offers `restore_here` again. Back on this
computer as the primary after a move back, the server's retired copy is
told once (`back:<epoch>`), and after Restore here the restore is
(`restored:<epoch>`, naming the day of the backup).

**Acting on it: `home.act`.** A surface sequences nothing. For the action the
owner pressed it collects what `needs` lists, asks `confirm` (when it is not
null) and accepts it or stops, and sends `home.act {action, key, input}`
with the action's `id` and the `key` it was drawn with; the engine runs every
step (which calls, in what order, which server, following the job) and
answers `{summary, result}`, the summary after the step, which the surface
draws. On `changed` it shows that refusal's sentence and reads `home.status`
again, as after any act, and the owner presses again from the screen drawn
then. While a move back or a restore runs the summary says so (`moving`,
`detail.progress`), and its end moves the key, so the surface follows it
with `home_status_changed` or a waiting `home.status`, never `job.*`. One
action is opened by the surface itself and never sent: `update`, the app's
own update.

| `id` | What the engine does on `home.act` |
|---|---|
| `own_server` | opens a code for the owner's server; `result` is `{code, expires_at, command, sentence, tailscale}`, answered once: `command` installs Fermix, `sentence` is the line the code is shown with ("Run this on your Debian 12 or 13, or Ubuntu 24.04 server, then paste the code when it asks. The code works once, until …", the time in the owner's zone), which replaces every surface's own, and `tailscale` (`{label, sentence, command, url}`, folded under its label, its tagOwners and policy steps on the docs page at `url`) is the optional step that also joins the server to the owner's tailnet, which WhatsApp and webhook sources need: the same command with `--tailscale`, after which the server asks for the code and then a Tailscale auth key (created with `tag:fermix-server`, which the tailnet policy declares under `tagOwners` first) at the terminal without echo, so the key is on no command line |
| `cancel` | on `connect` and on `creating`, closes the code for the owner's server; on a held server's `ready`, `not_ready` or `undone` (Forget this server), drops the held server, after its confirm, and the screen is `off` |
| `back_up_now` | runs a backup now (on a linked desktop, on the server); the screen it answers runs (`outcome` `running`, `progress` "Backing up now…") until the backup ends: back on `on`, its backup's line updated, when it was stored (`fermix always-on back-up-now --wait` exits 0), or the `backup_failed` problem when it failed (`outcome` `failed`, exit 1) |
| `check_again` | runs the move's review again, and keeps it |
| `move_now`, `try_again` | reviews at the press (a block refuses; a warning the confirm did not name answers `changed`), checks or sets the recovery passphrase, records what this computer keeps on for its server (`input.keep_offers`, the lines of `keeps_on` left ticked; absent, the block as shown; an id that is not one of `files_and_shell`, `browser`, `computer_use`, `imessage` and `history`, or an earlier app's `files` and `shell`, which keep `files_and_shell` on only together, is `invalid_params` on `keep_offers`, "Name only what this computer may keep on for your server."), starts the move and restarts the engine; `result` is `{move_id}`. During a move back it sends the move to the server, which checks the passphrase against its own key and keeps no desktop of itself, to this desktop's own candidate, kept in the move back's own record |
| `review_offers` | Keep these switches, on a linked computer whose switches wait for the owner's review: with no `input.keep_offers`, its switches as they are and its recorder as it is; with them (an app from before this change), those lines stay on, every other is switched off and the history line sets the recorder (an id that is not one of those, as for Move now, is `invalid_params` on `keep_offers`); either way the review is done; `result` is null. One that cannot be saved is `unavailable` {`capability`: `home`}, "Your review could not be saved. See the daemon log." |
| `add_computer` | opens a code for a computer that joins the home, on the server (`home.enroll.open` with `purpose` `computer`, sent over the link from a linked computer); `result` is `{code, expires_at}`, answered once |
| `approve_computer` | adds the computer that waits, with the six digits it shows (`input.sas`; spaces are dropped; anything but six digits is `invalid_params` on `sas`, "Type the six digits the new computer shows.", and nothing is sent): `home.enroll.approve` on the server; `result` is `{device_id, name}`, the computer as the home added it |
| `deny_computer` | does not add the computer that waits (`home.enroll.deny` on the server), and its code is spent; `result` is null |
| `cancel` (a join) | on the computer that joins: ends the join wherever it stands, deletes the key it made, and restarts the engine as its own home |
| `move_back` | on a linked desktop: makes this computer's own checks first, so a refused one asks the server for nothing, then asks the server for a copied code (`home.enroll.open`, which names this desktop), writes this desktop's candidate for the home beside it and the move back's record, and starts receiving beside the link; a step after the code that does not go through withdraws it (`home.enroll.withdraw`), and the refusal's sentence says so when the server could not be asked. Refused, `unavailable` with a sentence, while the server reports a move of its own, and where Fermix would not start again by itself (run from a terminal) |
| `cancel` (a move back) | stops receiving, closes the server's copied code (`home.enroll.withdraw`; one the server cannot be asked to close lapses by itself) and forgets the move back |
| `change_passphrase` | Change, in the backup settings: a new recovery passphrase (`input.recovery_passphrase`, collected twice), set on the server as `home.snapshots.passphrase` sets it (sent over the link from a linked desktop); backups made before keep the key they were written for; `result` is null. A shorter one is `invalid_params` on `recovery_passphrase` |
| `restore_here` | chooses the newest copy `input.recovery_passphrase` opens (none: `invalid_params` on `recovery_passphrase`, before anything else), keeps the request in the move back's record, then one job (`home_restore`) restores the copy, and the engine restarts as the primary; it deletes no server |

The server also tells the paired phones, once per occurrence, when its newest
backup passes 7 days, as a message in the owner's phone chat ("Your last
backup is 8 days old. It runs when your Mac is online: open Fermix on your
Mac to back up now.").

## v0 compatibility window

The daemon also serves the historical **unversioned** control protocol as v0 for
one migration release — that is what `fermix stop`, mobile pairing, and the
remaining introspection verbs (`health`, `agents`, `capabilities`, `skills`,
`plugins`, `observability`) speak today. Classification is structural and has no
fallback:

1. A frame carrying **either** `request_id` or `protocol_version` is an
   attempted v1 request. If it is not a valid one it is refused with a v1 error
   envelope and **never** retried as v0.
2. A frame carrying neither marker, with a string `method`, is v0.
3. Anything else — non-object JSON, undecodable bytes, a v0 frame without a
   `method` — is refused as an invalid v0 request.

New application code sends v1 only and never retries through v0. A v0 method is
deleted, not deprecated in place, when its verb moves onto v1: `status` and
`overview` were removed when `fermix status` moved onto `hello` plus
`overview.get`, and a daemon asked for either now answers the ordinary v0
`unknown method` reply.

## Direction of an unsupported version

A version outside the window is refused before routing, with the range attached
so the app can tell the user which component to update without re-deriving it:

- `client_too_old` — the app declared a version below the daemon's floor →
  **update the app**.
- `daemon_too_old` — the app declared a version above the daemon's ceiling →
  **update Fermix**.

Both carry `details: {"minimum_version": N, "maximum_version": M}`.

## Rollout / rollback order

Because the daemon and the app ship from separate repos on independent cadences,
a version bump must land in a fixed order so the two are never mutually
unintelligible:

1. **Daemon first.** Ship a daemon that *adds* support for `N+1` while keeping
   `N` (the N/N-1 window). Never remove support for a version a released app
   still requires.
2. **App second.** Only after that daemon is released, ship an app that speaks
   `N+1`. An app must never require a version the released daemon lacks.
3. **Rollback** is the reverse: roll the app back to `N` before dropping `N`
   from the daemon.

The window is what makes step 3 survivable rather than a coordinated outage: a
daemon serving `{N-1, N}` answers both the app being rolled back to and the one
being rolled back from, so the two halves are never simultaneously
unintelligible at any point in either direction. What must never happen is a
release that widens `maximum` and lifts `minimum` in one step, because that
leaves no version both halves speak and no call the app can make to restart the
daemon onto anything else.

## Method catalog

| `method` | Params | Result |
|---|---|---|
| `hello` | none | Supported range, method catalog, immutable engine identity, PID, and the loopback Setup endpoint. |
| `overview.get` | none | Typed projection of readiness, health, daemon, provider, channels, memory, jobs, agents, realtime, and capability counts. A channel's `status` is `away` while the computer that carries it is asleep or offline (iMessage on a server, through the Mac that carries Messages, M97 D4), as that channel reads it now; a readiness row that says so owes no setup, so it never makes the channel `setup_required`, which a row that does owe setup still does. |
| `setup.session.create` | none | A one-use Setup URL and its absolute expiry. The durable token is never returned. An owner decision. |
| `doctor.start` | `scope` (`local` \| `network`, default `local`) | A session view; the run continues in the background. In the device role the local scope, named or by default, runs on this computer, and the network scope is `unavailable` {`capability`: `doctor`, `sentence`}: its probes would call a provider with this computer's retired credentials. |
| `doctor.get` | `session_id` | The session view with the checks that have landed so far. |
| `doctor.cancel` | `session_id` | The terminal session view. Cancelling a finished session is a no-op, not an error. |
| `logs.query` | `limit`, `level`, `subsystem`, `search`, `direction`, `cursor` | A bounded page of redacted entries plus the opaque cursor for the next page in the same direction. |
| `lifecycle.prepare` | none | `lease_id` and the relative `ttl_ms` of the single drain window. |
| `lifecycle.commit` | `lease_id` | Runs the daemon's shutdown path and answers before the VM stops. |
| `lifecycle.cancel` | `lease_id` | Releases the window with the daemon untouched. |
| `diagnostics.build` | none | A bounded, field-allowlisted, scrubbed diagnostic object for user-selected export. |
| `setup.state.get` | none | Everything a setup surface reads before it renders: readiness with its gating split, restart state with the daemon's own reason sentences, one row per provider and per channel, the personalization presence summary, feature switches, the profile, and the coexistence facts. Minimum version `2`. |
| `settings.sections` | none | The ordered inventory of every section this daemon can serve, each with the pane it renders under, as `{sections, primary_missing}`. The one enumerator: a section reachable through `settings.get` and absent here fails the daemon's own contract test. On a linked desktop it is composed (see *After a move*): this computer's own sections (`sandbox`, `computer_use`, `computer_history`, `accessories`, and `computer`, which only a linked computer publishes, and only where Always On is offered) and the primary's others, `channels.imessage` among them where the primary publishes it but not its `harness_machine` (whether coding agents may run on the server, which only the server shows), and `primary_missing` the sentence while the primary's are missing; null everywhere else. Every engine but a linked computer publishes its own `harness_machine` (M98 D5: whether coding agents may run on this machine, its `machine.toml`), titled "This Mac" or "This computer", in the `coding` pane before `harness`, which keeps the home's preferred tool. Minimum version `2`. |
| `settings.get` | `section` | One section's rows. Exactly one section per call, which is what keeps every result inside the published depth budget. Minimum version `2`. |
| `settings.apply` | `section`, `values` | Applies the changed keys of one section and answers with what landed, the restart state, a readiness summary, and the changes the operator did not type. Minimum version `2`. |
| `settings.reload` | none | Re-reads the settings file, pushes it into the running configuration, and re-records the baseline. The one action behind `Reload settings from disk`. Minimum version `2`. |
| `secret.set` | `id`, `value` | Stores one secret and answers with its presence, never its value, and the environment variable that overrides it, if any. Minimum version `2`. |
| `secret.clear` | `id` | Forgets one secret: the keyring item, the reference that reads it, and the value in force. Answers with the environment variable still in use, if any. Minimum version `2`. |
| `setup.detect` | `targets` | One row per target asked for: whether this Mac already has it, and a short detail where there is one. The harness target also reports vendor installation, version and sign-in state (`auth`, and `signed_out` once a run there failed to sign in), with guidance. The `meetbot` target reports whether both halves of the meeting notetaker are installed, its detail carries the state of the notetaker's Google sign-in as a sentence, and `signed_in` carries the same state as a boolean, null while the notetaker is absent. Never a credential value. Minimum version `2`. |
| `coding_agents.check` | `vendors` (optional: a list naming `codex` and `claude`, each at most once; both when absent) | Check again for this computer's coding agents: the owner's word that they signed in again. The sign-in marks of the agents it names (an agent whose last run here failed to sign in, `signed_out` in `setup.detect`) are cleared on this computer, and the answer is `{results}` with the one `harness_vendors` row `setup.detect` answers, read again. A client calls it only when `hello` lists it, and `setup.detect` otherwise. Refusals: a parameter it does not take, or `vendors` that is not such a list, is `invalid_params` with `field`; sign-in marks this computer cannot read are `unavailable` {`capability`: `coding_agents`, `sentence`: "Fermix could not read the coding agents' sign-in marks here, so none was cleared."}, and nothing is cleared. Device-class: answered on the computer that asks. Minimum version `2`. |
| `providers.set_primary` | `provider` | Makes one configured provider the primary and answers with the restart state and any change the operator did not type. Minimum version `2`. |
| `providers.models.list` | `provider`, `live`, `query`, `cursor`, `limit` | One page of models, from the catalog this build ships or from the provider's own live listing, with the cursor for the next page. Minimum version `2`. |
| `providers.probe.start` | `provider` | Starts a metered call against the provider. A job; the result carries the model and the latency. Minimum version `2`. |
| `job.get` | `job_id` | One job's uniform view. Minimum version `2`. |
| `job.cancel` | `job_id` | Stops a running job and answers its terminal view once its run has stopped: the run is signalled to stop and killed if it is still running 5 s later, so the answer can take that long, and a step started after it never runs beside the run it cancelled. Cancelling a finished job is a no-op, not an error. Minimum version `2`. |
| `job.list` | none | Every job this daemon retains, oldest first. What lets a reopened surface find a run it started rather than starting a second one. Minimum version `2`. |
| `auth.start` | `provider` | Starts a browser sign-in and answers with the job plus the authorize url and its lifetime, returned once. `openai_codex` signs in with ChatGPT: a sign-in that leaves ChatGPT plan usage off fails the job with its sentence, and a completed one first makes sure the default model is one the account lists. When that check cannot be made (the account's model list could not be read, or the model could not be saved), the sign-in still completes and its result carries `model_warning`, the daemon's sentence saying the default model was not checked and why, beside `account_label`. The field is optional: absent means the check was made, and a client that does not know it shows the sign-in as completed. `mcp:<name>` signs in one MCP server the owner added, a remote one whose `auth` is `auto`, and is refused with `invalid_params` on `provider` and a sentence for a name no server has, a server on this Mac, one that sends a key and one set to need no sign-in. Minimum version `2`. |
| `auth.import.start` | `source` | Adopts a sign-in this Mac already has, from Claude Code. A job, because reading the keychain can prompt. `codex_cli` is still accepted as a source and refused with `invalid_params` and a sentence: a Codex CLI sign-in is no longer adopted, and `openai_codex` signs in with ChatGPT through `auth.start`. Minimum version `2`. |
| `auth.logout` | `provider` | Forgets one provider's local session and reverts the route it fed. Nothing is revoked upstream, except for `openai_codex`: its sign-out revokes the ChatGPT session and keeps the registration, so the next sign-in reuses it. `mcp:<name>` forgets one MCP server's sign-in, revokes nothing upstream, and starts the server again without it; a client its sign-in registered is kept for the next one. Minimum version `2`. |
| `plugins.list` | none | Every integration this daemon can show, installed or not, in one row shape, plus one entry per sign-in client a published plugin needs, each carrying the account region it is bound to and the regions this daemon offers for it. Every word on a row is the daemon's. Minimum version `2`. |
| `plugins.install.start` | `name` | Fetches, verifies and activates one catalog plugin. A job. Minimum version `2`. |
| `plugins.check.start` | `name` | Runs one plugin's own health check, live probe included. A job. Minimum version `2`. |
| `plugins.workspaces.discover.start` | `name` | Lists the workspaces a hosted plugin's stored credential can reach. A job; what it finds is republished on the plugin's row rather than in the job result. Minimum version `2`. |
| `plugins.workspace.select.start` | `name`, `profile`, `workspace_id`, `label` | Binds one hosted plugin to one workspace under one access profile, and answers only once the replacement client is connected and contract-checked. A job. Minimum version `2`. |
| `plugins.enable` | `name` | Turns one installed plugin on and answers with its row. Minimum version `2`. |
| `plugins.disable` | `name` | Turns one plugin off and answers with its row. Minimum version `2`. |
| `plugins.disconnect` | `name` | Forgets the credential behind one plugin, locally: an OAuth session is deleted, a stored token is removed from the keyring, and neither is revoked upstream. Minimum version `2`. |
| `plugins.oauth_client.set` | `provider`, `client_id`, `redirect_port`, `region` | Registers one sign-in client. The client secret is not a parameter: it arrives through `secret.set`. `region` is required exactly where the client row publishes a non-empty `regions`, and refused where it publishes none; it is optional on the wire, like `secret_present`, so an older engine is unaffected. Minimum version `2`. |
| `plugins.setting.set` | `name`, `key`, `value` | Writes one manifest-declared setting and answers with the plugin's row. `value` is always a string, and a setting whose `kind` is `boolean` takes only `true` or `false`. Minimum version `2`. |
| `capabilities.install.start` | `target` | Installs the computer use helper, the meeting notetaker, the on-device speech backend, or the iMessage helper (`imessage_helper`). A job. Minimum version `2`. |
| `meetings.signin.start` | none | Starts the notetaker's one-time interactive sign-in. A job, because it waits for a person. Minimum version `2`. |
| `computer_use.grant.start` | none | Raises the OS permission prompts and answers with what was granted. A job, and only ever on an explicit ask. Minimum version `2`. |
| `computer_use.permissions.get` | none | The current, non-prompting permission state: whether the helper is installed, which grants it holds (on Linux, what this session's pixel route serves), and when they were read. A probed answer names the helper's `platform`; a Linux one adds its `display_server` and the doctor's Linux `rows`. Minimum version `2`. |
| `mobile.status` | none | The phone channel as it stands: whether it is enabled, whether it started, whether it was refused this boot and the class of that refusal, whether it is held until setup is finished, the listener (`status`, `reason`, `port`, `bind`, `candidates`), the local-network announcement, detected tailnet addresses, the gateway identity's presence and fingerprint, remote reach, push credentials and delivery, the paired-phone count, the mobile protocol version this daemon serves, and the pairing session open or newest retained. Answers with the channel off. Minimum version `2`. |
| `mobile.pair.start` | none | Opens the pairing window and answers with the pairing session view plus, once, the pairing link as `uri`. `busy` while a window is open. Minimum version `2`. |
| `mobile.pair.get` | `session_id` | The pairing session as it stands. The pane polls it until the session is terminal. Minimum version `2`. |
| `mobile.pair.decide` | `session_id`, `approved` (boolean) | Approves or denies the phone waiting in the session and answers the terminal view. Minimum version `2`. |
| `mobile.pair.cancel` | `session_id` | Closes the window and answers the terminal view. Cancelling a finished session is a no-op, not an error. Minimum version `2`. |
| `mobile.devices.list` | none | Every paired device, oldest first, at most 64, read from the paired-device file while the channel is not running. Each row names its `kind`, `phone` or `desktop` (a desktop engine a move paired). Minimum version `2`. |
| `mobile.devices.revoke` | `device_id`, `confirmed` (optional boolean) | Forgets one paired phone, or removes one computer of the home (`kind` `desktop`, M97), closes its live connection, and answers with the id and `revoked: true`. While the channel is not running it forgets the device in the paired-device file. A removed computer's next connection ends as revoked, the home forgets what it offered, and it can join again with a code (*Adding a computer*). The one computer that keeps the server's backup copies is removed only with `confirmed: true`: without it the answer is `unavailable` {`capability`: `mobile`, `sentence`: "<name> keeps the only copies of your server's backups. Remove it anyway?", `confirm`: true}, nothing changes, and the surface asks the owner and sends the request again with `confirmed`. A `confirmed` that is not a boolean is `invalid_params` on `confirmed`. Minimum version `2`. |
| `browser.install.start` | none | Downloads a browser for tasks: the meeting notetaker's helper, then the Chromium build it is pinned to, and completes with the name of the browser tasks now run in. A job. Minimum version `2`. |
| `imessage.permissions.get` | none | The Fermix Messages helper's non-prompting state: whether it is installed, its version, Full Disk Access, the Messages database, Automation, whether Messages runs and is signed in, the user session, the confirmed recipient policy, whether that policy is exactly the saved settings, and when it was read. Minimum version `2`. |
| `imessage.grant.start` | `service` (`automation` or `full_disk_access`) | Asks for one grant: `automation` raises the one system prompt, `full_disk_access` registers the helper, opens the Full Disk Access pane and reveals the helper for drag-in. A job that completes with the permissions view. Minimum version `2`. |
| `imessage.policy.confirm` | none | Asks the helper to confirm the saved recipients; when they differ from the ones it holds, the helper shows its own dialog naming every handle. A job that completes with the permissions view plus `outcome`. Minimum version `2`. |
| `mcp.servers.list` | none | Every MCP server the owner added, imported or wrote by hand in `config.toml`, as rows without their tools, plus `limits` (`max_servers`) and `can_add`. Minimum version `2`. |
| `mcp.servers.get` | `name` | One server's row with its `tools`, at most 256, in the server's order. Minimum version `2`. |
| `mcp.servers.draft` | `text` | Reads what the owner typed or pasted into the add form (a URL, a command line, an `mcpServers` or `servers` JSON map, one server object, a `claude mcp add` line or a Codex `[mcp_servers.<name>]` block), writes nothing, and answers `{drafts}`: at most 32, each a server as the form takes it, with the `draft_id` that holds the values it carried. Minimum version `2`. |
| `mcp.servers.add` | `name`, `transport`, `command_line` or `url`, `cwd`, `env_names`, `auth`, `key_header`, `header_names`, `oauth_client_id`, `draft_id` | Writes one server and answers `{server, job_id}`: its row, and the `mcp_check` it started, or a null `job_id` where the server waits for a value and so did not start. With a `draft_id`, the values that draft carried are stored for the names the form still declares. Minimum version `2`. |
| `mcp.servers.update` | `name` and any field `add` takes but `draft_id` | Changes the fields given and answers `{server}`. The name and transport cannot change, and a value the server no longer declares is deleted. Minimum version `2`. |
| `mcp.servers.remove` | `name` | Removes one server, every value it declares and its live status, and answers `{name, removed: true}`. Minimum version `2`. |
| `mcp.servers.enable` | `name` | Turns one server on and answers `{server}`. Minimum version `2`. |
| `mcp.servers.disable` | `name` | Turns one server off and answers `{server}`. Minimum version `2`. |
| `mcp.servers.tool.set` | `name`, `tool`, `enabled` (boolean) | Switches one tool on or off for the agent and answers `{server}`. The server's program keeps running. Minimum version `2`. |
| `mcp.servers.check.start` | `name` | Connects one server and lists its tools once. A job, kind `mcp_check`, whose result carries `tool_count` and `latency_ms`. Minimum version `2`. |
| `mcp.servers.import.scan` | none | Reads the MCP servers in Claude Desktop's, Claude Code's, Cursor's, VS Code's, Windsurf's and Codex's settings on this Mac, now and only now, and answers `candidates`, each with its `source`, `source_label`, name, transport, summary, command line or URL, consent sentence, resolved program and `secret_names` (never a value), and `skipped`, what could not be offered with the daemon's sentence. Minimum version `2`. |
| `mcp.servers.import` | `servers` (`[{source, name}]`, at most 32) | Reads those settings again and adds each server named through the add path, with the values its settings held stored in the Keychain and `origin` `imported:<source>`, and answers `{servers, refused}`: the new rows, and each server not added with its sentence. Minimum version `2`. |
| `cues.status` | none | The cue subsystem as it stands: `available` (always `true`: every build has cues), the switches (`enabled`, `mandates_enabled`), whether the cue tree is `running`, `memory_enabled`, a `state` (`off`, `needs_memory`, `needs_restart`, `running`) with its `status_sentence`, the `door` (`state` `listening`, `unavailable` or `not_running`, `port`, `reason`, `sentence`), and `counts` (`sources`, `sources_attention`, `watchers`, `watchers_held`, `mandates`, `mandates_attention`, `proposals_waiting`). Answers on every build. Minimum version `2`. |
| `cues.sources.list` | none | Every source as a row, at most 64, plus `can_add` and `limits` (`max_sources`). Minimum version `2`. |
| `cues.sources.get` | `ref` | One source's row, its editable fields as settings rows (`values`), its open gaps (at most 20, each with the daemon's sentence) and its refused requests by reason (`rejected`). Minimum version `2`. |
| `cues.sources.form` | `kind`, `preset`, `verify` (each optional) | The add form for that choice, and writes nothing: `choices`, `requirement`, `kinds`, `presets`, `rows` (the name first, then the fields of that kind, preset and verification method, a secret field as a `secret` row with `present: false`), `consent_sentence` and `notes`. `choices` is the same on every answer: what the owner can watch, in the order a client lists them, each `{id, label, sentence, kind, preset, featured}` (`preset` null where the choice has none); a client lists all of them, the featured ones first, and asks for a choice's form by its `kind` and `preset`. `requirement` is null except for X accounts: `{state, sentence, plugin: "x"}`, `state` `ready` ("Signed in to X.") or `needs_sign_in` ("Connect X to read these accounts."), read from the X plugin's sign-in the source reads with; it never stops the add. Only the rows a choice needs are open; the rest, the name first among them, are `advanced`. The name row is empty, with an `example` of the name Fermix would make. GitHub's form has no secret row: Fermix makes that secret when the source is added. Its `notes` are the tunnel note, then GitHub's three steps in order (where the secret and the source's address go in GitHub's webhook form); every note is plain text, shown as written. A stream has no preset; it is the general WebSocket source: each of its field rows but the name and the daily budget carries an `info` and an `example` (no row of the form carries a `footer`), and two `secret` rows, `key` (API key) and `secret` (API secret), follow its address. `kinds` and `presets` are as they were, for the edit form and older apps. Minimum version `2`. |
| `cues.sources.add` | `ref` (optional), `kind` or `preset`, `values` | Saves a new source and answers `{source, token, secret}`: its row, under the name given or, with `ref` absent or empty, one Fermix makes (a feed's or stream's site, such as `ycombinator` for `news.ycombinator.com`; `x-` and the first handle; `github`; `scripts` for a local push; `webhook`), with `-2`, `-3` and so on when the name is taken. `source.ref` is the name in force, and a client stores typed secrets under it. `token` is a new local push source's first token and `secret` the secret Fermix makes for a new GitHub source, each returned once and null otherwise. Minimum version `2`. |
| `cues.sources.update` | `ref`, `values` | Changes the fields `values` names and answers `{source}`. The name, kind and preset cannot change. Minimum version `2`. |
| `cues.sources.remove` | `ref` | Removes a source and its stored secrets, and answers `{ref, removed: true, left, watchers}`: any secret that could not be deleted, as sentences, and the watchers that listened to it. Minimum version `2`. |
| `cues.sources.enable` | `ref` | Turns a source on and answers `{source}`. Minimum version `2`. |
| `cues.sources.disable` | `ref` | Turns a source off and answers `{source}`. Minimum version `2`. |
| `cues.sources.token.new` | `ref` | A fresh token for a local push source, returned once, as `{ref, token}`. The old one stops working within a minute. Minimum version `2`. |
| `cues.sources.url.get` | `ref` | A webhook source's address, `{ref, url, path}`: made on the first call and the same on every later one. Minimum version `2`. |
| `cues.watchers.list` | none | Every watcher as a row, oldest first, at most 200, with `window_s` (86400) and `truncated`; a row carries its task (for a watcher with only a follow-up, that follow-up's job, so never null) and its follow-up (null when it has none). Minimum version `2`. |
| `cues.watchers.get` | `name` | One watcher's row plus its `purpose`, its keywords to listen for (`listen_for`), its `instructions` and how many of its examples are marked each way. Minimum version `2`. |
| `cues.watchers.always_allow.revoke` | `name` | Takes back the owner's Always allow of the watcher's follow-up, so each of its runs asks first again on a card, and answers `{watcher}`, its row with `follow_up.always_allowed` false. A follow-up that already asks first is answered the same. Only ever lowers what the follow-up may do: granting is the owner's answer on one of its cards alone. A watcher with no follow-up, or none of that name, is refused with `invalid_params` (`name`) and the daemon's sentence. Minimum version `2`. |
| `cues.mandates.list` | none | Every mandate as a row, at most 64, plus `can_add` and `limits` (`max_mandates`). Minimum version `2`. |
| `cues.mandates.choices` | none | What a mandate form offers: the jobs that run on cues, each with the watcher that wakes it and the mandate that names it, and the installed, enabled `http` plugin tools. Minimum version `2`. |
| `cues.mandates.add` | `name`, `values` | Saves a new mandate and answers `{mandate}`. Durations travel as whole seconds (`approve_within_s`, `max_cue_age_s`). Minimum version `2`. |
| `cues.mandates.update` | `name`, `values` | Changes the fields `values` names and answers `{mandate}`. Its approval covers the section, so the row then says `changed` until approved again. Minimum version `2`. |
| `cues.mandates.remove` | `name` | Removes a mandate and answers `{name, removed: true}`. Minimum version `2`. |
| `cues.mandates.enable` | `name` | Turns a mandate on and answers `{mandate}`. Minimum version `2`. |
| `cues.mandates.disable` | `name` | Turns a mandate off and answers `{mandate}`. Minimum version `2`. |
| `cues.mandates.approve` | `name` | Records the owner's approval of a mandate as it is now, from the Fermix app, and answers `{mandate}`. An inactive mandate is refused with its load sentence. Minimum version `2`. |
| `cues.proposals.list` | `state` (`waiting`, the default, or `recent`) | Fermix's record of each waiting proposal (oldest first, at most 100) or of the last 7 days (at most 50), and `waiting`. No arguments and no cue text. Minimum version `2`. |
| `cues.proposals.get` | `proposal_id` | `{proposal}`: the record plus the card, the outside text apart. Minimum version `2`. |
| `cues.proposals.decide` | `proposal_id`, `decision` (`confirm` or `deny`) | Answers a waiting proposal and returns `{proposal}` once the decision is recorded: `denied`, or `confirmed` with a null `result_status` while the call runs. Minimum version `2`. |
| `home.status` | none; or `after` (a `summary.key`) and `wait_ms` (at most 25,000) together, to wait for a change (see *The Always On summary*) | The one picture of this home every surface draws: `role` (`primary`, `device` or `candidate`), `epoch` (null before the home's first boot as the primary), `moved` (`{to, moved_at, epoch}` or null), `snapshots` (as `home.snapshots.status`), `primary` (in the device role after a move, the primary this desktop reaches: `{name, connected, status, since, epoch, sentence}`, `status` one of `connected`, `renewing`, `unreachable`, `revoked` or `stale` (see *After a move*), `since` null while not connected and `epoch` the highest primary epoch this desktop has seen; null otherwise), `desktops` (on the primary, each desktop that holds a session to it: `{device_id, name, connected, since}`, `since` null while not connected; empty otherwise), `enrollment` (on the primary, the enrollment window opened since the engine started: `{state, expires_at, candidate_id}`, `state` `open`, `used` or `expired`, `candidate_id` the candidate that enrolled with it, null until one did, never the code; a window opened for a computer that joins the home also carries `purpose` `computer`, `joiner` (`{name, platform}` while a computer waits for the owner, its `state` then `awaiting_approval`, never its digits; else null; an engine before this one also sent `sas`, which a client does not show) and `joined` (`{device_id, name}` once the owner added it, its `state` then `approved`; else null), and its `state` is `denied` once the computer was not added; null otherwise), `join` (only on a computer joining a home with a code: `{phase, server, sas, sentence}`, `phase` `dialing`, `awaiting_approval` or `denied`, `server` the server's name, `sas` the six digits this computer shows for the owner to type where the home asks, null until the server answered; absent on every other engine), `screen` (only on a linked computer: while Fermix on its server controls this computer's screen, `{since, sentence}`, `since` when it took the screen (an RFC 3339 instant) and `sentence` the words the mark says, "Fermix on your server is controlling this screen.", which a client shows as a mark (the menu bar on a Mac, the tray on Linux) with Stop beside it, `computer.screen.stop`, whether or not a window is open; null while it does not; absent on every other engine; taking and letting go of the screen is a change told as `home_status_changed`), `candidates` (on the primary, the candidate primaries it holds, as `home.candidates.list` answers them; empty otherwise), `move` (the move this home started or, on a candidate, the one it waits for: `{phase, candidate, sentence}`; null when there is none), `secrets_missing` (on the primary, the ids `secret.set` takes of the secret references in its settings that did not resolve on this host, each one to enter again; empty otherwise), `primary_home` (on a linked desktop, the primary's own `home.status`, asked within 5 s; null otherwise), `primary_missing` (on a linked desktop, the sentence while `primary_home` is missing; null otherwise), `summary` (the Always On screen: `{key, state, sentence, action, detail, notice, outcome}`, see *The Always On summary*), `disk` (on the primary, how full its disk is: `{used, nearly_full}`, `used` a fraction from 0 to 1 and `nearly_full` from 0.85; null in any other role and when it cannot be read), `version` (this engine's version), `home_format` (the home format this engine reads and writes, see *The server leads*), `update` (on an Always On server, what its update may install, see *The server leads*; null on every other engine), `update_ceiling` (the release an Always On server's update may install, `update.eligible`; null where `update` is null or names none; kept because every server's update script reads it, so a script an older first boot wrote follows the server too), `restart_hold` (what holds the engine's restart after an update, `{reason, count, wait_s, sentence}`: `reason` `move` for a move under way, or `computer_work` for work in progress on a computer, at most ten minutes from the oldest one's start, `count` that work, `wait_s` the seconds the restart still waits, 0 to 600; null when nothing holds it) and `webhooks` (on the primary, what it serves on loopback that the internet must reach, `{kind, ref, port}` each: `whatsapp`, `ref` null, on the web listener's port while the WhatsApp channel is on, then each enabled cue webhook source with a URL, `cue` and `ref` its name, on the cue door's port, by name; never a source's URL; empty otherwise; *Inbound webhooks*) and `computers` (on the primary, each computer of the home, by name: `{device_id, name, platform, engine_version, standing, connected, since, last_seen, path, offers, backups}`, `platform` `macos` or `linux` and null before it said, `engine_version` the Fermix version it last said, `standing` where that version stands against this server's (*The server leads*), null before it said one, `since` null while not connected, `last_seen` when the home last heard it, `path` `direct` or `relay` while its session is up and the path is known, else null, `offers` what it offers its server, each `{id, label, state, sentence, detail}` (`id` one of `files`, `shell`, `browser`, `computer_use`, `imessage` and `history`, or another a different engine names, kept as it came; `label` the words it goes by in the server's own offer list, such as `commands` or `your screen`, null for an id the server does not know, `state` `on`, `off` or `unavailable`, `sentence` why it is not on, null while on, `detail` a short word while on, such as the sandbox mode commands run in), in its session the ones it sent (none before its first), while it is away the ones it last sent, `backups` whether it keeps copies of the home's backups, and `this_computer` true on the row of the linked computer whose request the server answers (its own row, which its app never offers to remove) and false on every other row and to every other caller; empty otherwise. `desktops` stays for the clients that read it; `computers` says more of the same). Answered locally in every role; composed on a linked desktop (see *After a move*), whose own `snapshots` list no target, its status file being a retired copy. `summary`, `disk`, `version`, `home_format`, `update_ceiling`, `update`, `restart_hold`, `webhooks`, `computers`, each computer's `standing` and `this_computer` and each offer's `label` came after the method: an engine that does not send `summary` is drawn as one that needs updating, a client reads a missing `update_ceiling`, `update`, `restart_hold`, `standing` or `label` as null (and shows an offer's `id` in place of a null `label`), a missing `this_computer` as false, a missing `home_format` as 1, a missing `screen` as null, and a missing `webhooks` or `computers` as none. Minimum version `2`. |
| `home.snapshots.status` | none | The snapshots view: `configured`, `recipient_set`, `interval_hours`, `running`, `next_run_at`, one row per target (`id`, `label`, `configured`, `destination`, `last_attempt_at`, `last_result` (`verified`, `failed`, `waiting` or null), `last_verified` `{at, name, epoch, size, sha256, location, key_id}` or null, `last_error`, `waiting`) and one `sentence`. Minimum version `2`. |
| `home.snapshots.run` | none | Starts a snapshot now and answers `{started: true, snapshots}`. `busy` while one runs; `unavailable` {`capability`: `snapshots`} with the daemon's sentence when nothing is configured, in the device role, or with no scheduler. Rail-only: answered only to a desktop's forward, which a linked desktop's own `home.act` sends; on `daemon.sock` it is `unavailable` {`capability`: `home`, `method`} with "Always On takes this step itself: send home.act with the action the summary offers." (*After a move*). On the computer that sets up, Back up now (`home.act`) runs it in place. Minimum version `2`. |
| `home.snapshots.passphrase` | `recovery_passphrase` (12 to 1024 bytes) | Derives a new recovery key from the passphrase, under a new salt, and keeps only its public half as `[fermix_core.snapshots] recipient` in place of any kept one; answers `{recipient, key_id, snapshots, sentence}`, the sentence saying that snapshots written before now open only with the earlier passphrase. `home.move.start` checks a passphrase against the key this keeps. The passphrase is never stored, logged or answered. A shorter one is `invalid_params` with a sentence; the device role answers `unavailable`. Minimum version `2`. |
| `home.enroll.open` | `purpose` (optional: `candidate`, the default, or `computer`) | On the primary only: opens the one enrollment window, for thirty minutes and replacing an open one of the same purpose, kept across an engine restart, and answers `{code, expires_at}`. With `purpose` `computer` the code is for a computer that joins the home (`home.act`'s `add_computer`, *Adding a computer*) and for nothing else; a code of either purpose is refused, `unavailable` with its sentence, while one of the other purpose is open, which stays as it is. Its code is the one `home.act`'s `own_server` opens on the computer that sets up, which reaches this window directly; a window a desktop asks for is that desktop's move back (`home.act`'s `move_back`): the window names the desktop, and so does the candidate that enrolls through it, which is how this server knows the move goes back to it. The code (`fxenroll1.` and base64url, at most 2,048 characters) is single use and answered once: it is never logged, and `home.status` shows the window's `state` and `expires_at` and never the code. `unavailable` {`capability`: `home`} with the daemon's sentence in any other role, or while the rail cannot open a window. Rail-only: answered only to a desktop's forward, which a linked desktop's own `home.act` sends; on `daemon.sock` it is `unavailable` {`capability`: `home`, `method`} with "Always On takes this step itself: send home.act with the action the summary offers." (*After a move*). Minimum version `2`. |
| `home.enroll.withdraw` | none | On the primary only: releases the window, the copied code a desktop opened to move back, when its owner cancels (`home.act`'s `cancel` on a move back). An open one ends now and its secret leaves the disk, a used one stays as the record of who used it. None is left as it is. Answers `{withdrawn: true}`; `unavailable` {`capability`: `home`} with the daemon's sentence in any other role, or when the window cannot be kept. Rail-only: answered only to a desktop's forward, which a linked desktop's own `home.act` sends; on `daemon.sock` it is `unavailable` {`capability`: `home`, `method`} with "Always On takes this step itself: send home.act with the action the summary offers." (*After a move*). Minimum version `2`. |
| `home.candidates.list` | none | The candidate primaries this home holds, oldest first: `{candidates}`, each `{candidate_id, name, os, arch, version, node_id, snapshots, enrolled_at, expires_at}` and never its keys. A candidate is held for 24 hours after it enrolled, at most four at once. `snapshots` (`{s3_bucket, s3_region}`) is the bucket it was told to keep snapshots in, null when the host gave none. `unavailable` {`capability`: `home`} with the daemon's sentence when the list cannot be read. Minimum version `2`. |
| `home.move.readiness` | `candidate_id` | On the primary only: what the owner reviews before moving this home to a held candidate, answered `{ready, items}`, each item `{id, status, sentence}` with `status` `ok`, `warn` or `block` and `ready` false while any item blocks. The items, in order: `call_in_progress` (first, and only while a voice call is in progress: it warns, naming whom the call is with, "on this computer", "from your phone" or "from an accessory", since the move ends the call before it starts), `keychain_secrets` (the secrets this computer keeps in its keychain move with the home, into the server's secret files; one the keychain will not give blocks, named as its settings row labels it ("your Anthropic key", with the section's title when the label alone does not say which; one no row shows is counted), never by its id or its value; checking reads each value, which opens the keychain and can raise its prompt, and the sentence says so), `engine_version` (a server that runs an older Fermix blocks, and so does a newer one, which could never move the home back here; on a move back to the Mac the home left, a candidate whose `os` is macOS, only a Mac older than the server blocks), `disk` (the capture needs about twice the home free here; short of it blocks, with the numbers; a home the move cannot carry, such as a link out of it, blocks, naming the path and what to do in the words `fermix home export` uses), `s3_size` (a home over one S3 upload, 5 GiB, warns where the server keeps snapshots in S3), `plugins` (on a server of another OS or architecture, the plugins the catalog has no build of for it warn, named; the server installs every other one again right after the move), `dev_plugins` (only while this computer's settings name a dev plugin folder, `[fermix_core.plugins] dev_local`, it warns: "Dev plugins stay on this Mac: north-box runs none of them."; the folder, its links and the setting stay on this computer, and a move back keeps them), `stays_here` (what the home has turned on that runs only on this computer stops after the move: iMessage on a Mac, voice calls, meetings, each named; `ok` when none is on; on a move back to a Mac, what of them the server's settings turn on runs there again, named, and is `ok`), `whatsapp` (WhatsApp turned on warns: it stops after the move until the owner runs the Tailscale Funnel command the Always On screen shows for the server, which gives it an inbound address there, and points Meta at the address it prints), `slack` (Slack turned on without Socket Mode warns: it stops after the move unless switched to Socket Mode), `coding_agents` (coding agents approved on this computer warn: "Coding agents stop on this Mac after the move. They run on north-box only with your approval there."; the approval is this computer's own, in its `machine.toml`, and stays here, and the server runs them only with its own (M98 D5); `ok` when none is approved here), `cutover_gap` (a recurring job more than an hour late is skipped; with Telegram set up, its messages sent during the move wait until it is done), `serves_nothing` (this computer serves nothing during the move) and `service` (Fermix run from a terminal, with nothing to start it again, warns: "Fermix runs from a terminal here, so it stops when the move starts. Start it again to finish."; the Mac app's engine, a process inside Fermix's own systemd unit (`fermix.service`, read from its cgroup, never from an inherited `INVOCATION_ID`) and a `fermix service` install are `ok`). A client that does not know an id shows its sentence as it is. The engine keeps the review for the start that follows it; one it cannot keep is `unavailable` {`capability`: `home`}. A candidate this home does not hold is `invalid_params` on `candidate_id`; another role is `unavailable` {`capability`: `home`}. It walks the whole home first: a client gives it at least 65 s, and a desktop forwarding it waits 60 s (*Forward deadlines*). Rail-only: answered only to a desktop's forward, which a linked desktop's own `home.act` sends; on `daemon.sock` it is `unavailable` {`capability`: `home`, `method`} with "Always On takes this step itself: send home.act with the action the summary offers." (*After a move*). On the computer that sets up, `home.act` runs the same review at Move now and at Check again. Minimum version `2`. |
| `home.move.start` | `candidate_id`, `recovery_passphrase` (12 to 1024 bytes), `keep_as_desktop?` (boolean, true unless said) | On the primary only, and only while `home.move.readiness` has no item that blocks (otherwise `unavailable` {`capability`: `home`} with the sentence of each block). A ready review of the same candidate at most 15 minutes old is taken as it was shown, so the keychain is not read again before the move's capture reads it; with none, the engine checks now. Before anything else of the move, the recovery passphrase is checked against the recovery key this primary keeps: with one set, it must be the passphrase that set it (derived under the kept key's own salt, it must give its public half), else `invalid_params` on `recovery_passphrase` with "That is not the recovery passphrase you set."; with none set, it sets one, as `home.snapshots.passphrase` does, and a start refused after that keeps it. The move carries the kept key, so the new primary's snapshots open with the passphrase the owner already has and a move never makes a second key. On a move back this runs on the server, whose key it is. It writes the move to a held candidate, hands this home to the device role, removes this home's record of a move back that ended (`device/return.json`), answers `{move_id, candidate, recovery_recipient, key_id, keep_as_desktop, sentence}`, and then restarts the engine through the daemon's one stop path; the service manager brings it back in the device role, which carries the move out. The passphrase is never stored, logged or answered. A candidate this home does not hold is `invalid_params` on `candidate_id` and a passphrase under 12 bytes `invalid_params` on `recovery_passphrase`, each with a sentence; another role, a move already under way, or a home that never started as the primary is `unavailable` {`capability`: `home`} with the daemon's sentence. It may walk the whole home first: a client gives it at least 65 s, and a desktop forwarding it waits 60 s, answering `unconfirmed` when the primary had it and its answer was lost (*After a move*). Rail-only: answered only to a desktop's forward, which a linked desktop's own `home.act` sends; on `daemon.sock` it is `unavailable` {`capability`: `home`, `method`} with "Always On takes this step itself: send home.act with the action the summary offers." (*After a move*). On the computer that sets up, `home.act`'s Move now reaches the same start in place. Minimum version `2`. |
| `home.enroll.approve` | `sas` (text: the six digits the computer that asks shows; spaces are dropped) | On the primary only: the owner adds the computer waiting on the window (`home.act`'s `approve_computer`). Its row is written, with its system, every offer off and no backup copies, under the name it said unless another device holds it (then suffixed ` 2`, ` 3` and on), it is told where its server is, and the answer is `{device_id, name}`. Refusals: `invalid_params` on `sas` for anything but six digits ("Type the six digits the new computer shows."), and for six that are not the computer's ("Those digits are not the ones the new computer showed, so it was not added. Open a new code to try again."), which denies the computer and spends the code; `unavailable` {`capability`: `home`} with "No computer is waiting to join your Fermix." when none waits, and with the daemon's sentence in any other role. Rail-only, as `home.enroll.open` is. Gated with Always On. Minimum version `2`. |
| `home.enroll.deny` | none | On the primary only: the owner does not add the computer waiting on the window (`home.act`'s `deny_computer`). It is told, nothing of it is written, and its code is spent; with none waiting nothing changes. Answers `{denied: true}`. Rail-only, as `home.enroll.open` is. Gated with Always On. Minimum version `2`. |
| `home.act` | `action` (an action id the summary offers, but `update`, which the surface opens itself), `key` (the `key` it was drawn with), `input` (optional: `recovery_passphrase`, text, as the action's `needs` asked; `keep_offers`, at most 32 offer ids, for `move_now` and `try_again`, the lines of the `keeps_on` block left ticked, and for `review_offers` from an app before this change, the lines it drew left ticked; `sas`, text, for `approve_computer`: the six digits the new computer shows) | Every Always On step (Always On setup §3.4, and *The Always On summary*'s *Acting on it*). The engine runs one act at a time and reads the summary first: one that does not offer `action` under `key` answers `changed` with `details.sentence` alone, and does nothing; the surface reads `home.status` again. Otherwise it runs the step and answers `{summary, result}`: the summary after it (Restore here's job already says it runs) and `result`, `own_server`'s `{code, expires_at, command, sentence, tailscale}` (the code answered once and never again, the command carrying none, `sentence` the line the code is shown with, `tailscale` the optional step that also joins the server to the owner's tailnet, `{label, sentence, command, url}`), `move_now`'s and `try_again`'s `{move_id}`, `add_computer`'s `{code, expires_at}` (answered once), `approve_computer`'s `{device_id, name}`, null for every other step. Refusals, each with `details.sentence`: `invalid_params` on `action` (one the surface opens itself, or no action), `key`, `input` or the field of a missing or bad input (a passphrase that is not the one set: "That is not the recovery passphrase you set."; `keep_offers` that is not a list of text: "Send the offers to keep on as a list of their ids.", or names an offer a move does not decide: "Name only what this computer may keep on for your server."); `unavailable` {`capability`: `home`} (a backup or a restore already runs, the review blocks the move, nothing to move to, a review of what the server may use that could not be saved); `external_change` and `config_unreadable` when the recovery key could not be kept; and a step sent to the server answered as the server answered it (`primary_unreachable`, `unconfirmed` among them). `input` is never logged, traced or answered. An owner decision. Device-class: a linked desktop answers it itself, sending the server's own steps over the link (*After a move*), and the server refuses one forwarded to it with `device_class_method`. A client gives it 90 s (a review sent to the server takes up to 60 s). Minimum version `2`. |
| `computers.rename` | `device_id`, `name` (text, each at most 256 bytes) | Names a computer of the home (M97): `name` is trimmed and must be one line of 1 to 64 bytes, held by no other computer of the home and not the server's own name, each compared without case. Answers `{computer}`, the computer under its new name as `home.status` lists it in `computers`. Refusals: `invalid_params` with `field` and `sentence`, on `name` ("Give the computer a name of one line, at most 64 characters.", "Another computer of yours is already called <name>.", "Your server is already called <name>." or, when the name could not be written, "The name could not be saved. See the daemon log.") or on `device_id` ("Your Fermix has no such computer."); a missing or non-text parameter, or one it does not take, is `invalid_params` with `field` alone. Primary-class: a linked computer forwards it to its server (*After a move*). Gated with Always On: an engine that does not offer Always On neither lists it in `hello` nor serves it (*The Always On summary*). Minimum version `2`. |
| `computer.join.start` | `code` (text, at most 4,096 bytes: the code Add a computer opened) | This computer joins the home the code names (M97, *Adding a computer*): it makes its own key in the secret store, records the join (`device/join.json`, mode `0600`), becomes a device, and the engine restarts, dials the server and waits for the owner there; `home.status` then carries `join`. Answers `{joining: true, sentence}`. Refusals, each with `sentence`: `invalid_params` on `code` for a code Fermix did not open ("That is not a code Fermix opened. Copy the code again from Add a computer."), one for the owner's own server ("That code sets up a server of your own, so a computer cannot join with it. Use Add a computer in Always On.") and one that expired ("That code expired. Open a new one with Add a computer."); `unavailable` {`capability`: `computer`} for a computer that has a home of its own ("This computer already has a Fermix of its own (it holds <what>), so it cannot join another. Two homes cannot be merged.": any message, memory or scheduled job, a paired phone or computer, the moved marker, or a link to a server; nothing is deleted to make a home empty), one already joining, and a secret store that cannot keep the key. A refusal leaves nothing behind. An owner decision. Device-class: answered on the computer that asks. Gated with Always On. Minimum version `2`. |
| `computer.join.cancel` | none | Ends this computer's join wherever it stands: the key it made and its record go, the engine restarts as its own home, and `{cancelled: true, sentence}` is the answer; `unavailable` {`capability`: `computer`} with "This computer is not joining a Fermix." when none is under way. `home.act`'s `cancel` on the joining screen does the same. An owner decision. Device-class. Gated with Always On. Minimum version `2`. |
| `computer.disconnect` | `confirmed` (optional boolean) | This computer leaves the home it is linked to (M97): it tells the server (`mobile.devices.revoke` for its own id, over the link), which forgets it and closes its session, then deletes its key from the secret store, its link and what the server may use here, and the engine restarts; a computer that joined is its own home again, and the one a home moved from stays retired with its own copies of the server's backups. Answers `{disconnected: true, server_told, sentence}`. A server that cannot be told is `unavailable` {`capability`: `computer`, `sentence`: "Fermix could not tell your server. Disconnect anyway? Your server lists this computer until you remove it there.", `confirm`: true} and nothing changes; with `confirmed: true` the computer leaves anyway and `server_told` is false. A computer with no link is `unavailable` with "This computer is not connected to a Fermix." An owner decision. Device-class. Gated with Always On. Minimum version `2`. |
| `computer.journal.list` | `limit` (integer 1 to 200, default 50), `before` (an invocation's id) | What Fermix on its server did on this computer (M97 §6.3), from this computer's own journal, which the server cannot edit: the app shows it as "What Fermix did on this computer". Answers `{entries, more}`, the newest first, at most `limit`, only those older than the invocation `before` when it is given; `more` is true while older ones remain. Each entry is `{id, at, finished_at, capability, capability_label, op, op_label, target, origin, status, refusal, result_bytes, duration_ms}`: `capability_label` and `op_label` the owner's words for `capability` and `op`, from the capability's own module, lower case as an offer's `label` (`commands` and `run a command`, `files` and `write a file`), each null where this computer's engine has no words for its id (an older journal row), which a client shows as the id, as it does for an engine before them, which sends neither; `at` when it came (an RFC 3339 instant), `finished_at` when it ended, null while it runs; `target` a short description of what it acted on (a path, a host or an action, never content); `origin` the kind of turn that asked (`chat`, `voice`, `scheduled`, `cue`, `worker`, `background`, or `computer` for a computer's own request); `status` `ok`, `failed`, `refused`, `timed_out`, `cancelled` or `unknown` (the engine stopped while it ran), null while it runs; `refusal` (`off`, `unavailable`, `outside_sandbox`, `not_attended`, `stopped_here`, `busy`, `stale_epoch`) only when refused, else null; `result_bytes` and `duration_ms` null while it runs. A request refused before it ran opens and ends at once. The journal keeps the newest 2,000 invocations of the last 7 days. A computer that never moved, and a server, answer no entries. Refusals: a parameter it does not take, a `limit` outside its range or a `before` that is not an id is `invalid_params` with `field`; a journal this computer cannot read is `unavailable` with `sentence` ("This computer's record of what Fermix did here could not be read. See the daemon log."). Device-class: answered on the computer that asks; a server refuses a forwarded one (`device_class_method`). Gated with Always On (*The Always On summary*). Minimum version `2`. |
| `computer.screen.stop` | none | The person at this computer stops Fermix on its server controlling its screen (M97 §7.4): the Stop beside the mark `home.status`'s `screen` draws. The server's hold ends at once: held keys and buttons are released, the helper stops, the mark goes (`screen` null, told as `home_status_changed`), and the server hears that the person at this computer stopped it and tells the model so; the server's session on this screen ends and that session is refused from then on, so the screen is used again only when the owner asks again. Answers `{stopped}`, false when the server held nothing. Switching the master switch or the screen switch off in the `computer` section ends the hold the same way. A parameter it does not take is `invalid_params` with `field`. Device-class: answered on the computer that asks. Gated with Always On. Minimum version `2`. |
| `accessories.status` | none; or `after` (a `key`) and `wait_ms` (at most 25,000) together, to wait for a change | The accessory picture this Mac draws (see *Accessories*): `key`, `state` (`off`, `needs_local_primary`, `not_running`, `on`), `sentence`, `enabled`, `kinds`, `voice`, `voice_device`, `ports`, `accessories`, `pairing` and `call`. Answered in every role and with accessories off. With `after` and `wait_ms` it is answered once its `key` is not `after`, or when `wait_ms` passed. Device-class. Minimum version `2`. |
| `accessories.pair.start` | `path` | Opens the port the owner selected for pairing, ending whatever held it, and answers the status. A port must be listed (`invalid_params` on `path`) and not released for a firmware update. An owner decision. Device-class. Minimum version `2`. |
| `accessories.pair.begin` | `path`, `name` (optional, 1 to 64 bytes) | Starts the pairing attempt on the selected port once it reads `unpaired`: the robot asks "Pair with this Mac?" on its screen. `name` is the name the paired robot is kept under, the kind's name when absent. Answers the status, whose `pairing` names the new `attempt`. An owner decision. Device-class. Minimum version `2`. |
| `accessories.pair.decide` | `path`, `attempt`, `matches` (boolean) | The owner's answer to the compare code: `true` confirms it (the robot is enrolled once it confirmed too), `false` says the codes differ (the next round with a new code, and the third closes the attempt). Answers the status. An `attempt` that is not the open one answers `changed`. An owner decision. Device-class. Minimum version `2`. |
| `accessories.pair.cancel` | `path`, `attempt` (optional) | Cancels the open attempt, if any (`changed` when `attempt` names another), closes the selected port and clears the selection, and answers the status. A robot already enrolled stays paired: its row says so, and Forget removes it. An owner decision. Device-class. Minimum version `2`. |
| `accessories.retry` | `path` | Opens a busy or failed port again now, or the port that gave no Fermix answer, and answers the status. An owner decision. Device-class. Minimum version `2`. |
| `accessories.release` | `path` | Releases a port for a firmware update: the port is closed, and it stays closed, across the installer's resets, until `accessories.reconnect`. Refused with "End the call first." while the robot on it has a call, running or settling. Answers the status. An owner decision. Device-class. Minimum version `2`. |
| `accessories.reconnect` | `path` | Watches a released port again and answers the status. An owner decision. Device-class. Minimum version `2`. |
| `accessories.forget` | `accessory_id` | Forgets a paired robot (the `forget` action): an attached one is told to erase its keys and its call ends; its record is erased either way, and it stops being the voice device. Answers the status. An owner decision. Device-class. Minimum version `2`. |
| `accessories.revoke` | `accessory_id` | Erases a paired robot's record at this Mac alone (the `revoke` action, offered wherever `forget` is), without telling the robot, so its next attach is refused: for a robot that is lost or that cannot be told. Its call ends and it stops being the voice device. Answers the status. An owner decision. Device-class. Minimum version `2`. |
| `accessories.voice_device.set` | `device` (`desktop` or `accessory:<accessory_id>`) | Chooses where the next call captures and plays audio. Only while no call runs or settles anywhere in this home (otherwise `unavailable` with the sentence); an accessory must be paired. While an accessory is chosen, the Mac's own call on `realtime.sock` is refused `voice_device_elsewhere` with the daemon's sentence (`priv/realtime/PROTOCOL.md`, *One call at a time*), and a tap on a robot that is not chosen is refused `not_selected`. Answers the status. An owner decision. Device-class. Minimum version `2`. |
| `accessories.call.start` | `accessory_id` | Starts a call on an attached robot from the Mac and answers the status at once, inside the standard call timeout. The status long poll carries what follows: `call.phase` `starting`, then `active` once admitted, or, when the voice core refuses it (another call holds the home's one call), no `call` and the robot's `last_call` naming the refusal. A start the link refuses itself answers `unavailable` {`capability`: `accessories`, `code`, `sentence`}, `code` the refusal's (`call_in_progress` while the robot has a call, `voice_disabled`, `missing_key`, `restart_required`, `power_too_low`). A robot that is not attached is refused `invalid_params` on `accessory_id` ("That robot is not connected."). An owner decision. Device-class. Minimum version `2`. |
| `accessories.call.end` | `accessory_id`, `call_id` | Ends the robot's call and answers the status. A `call_id` that is not the current call's answers `changed`. An owner decision. Device-class. Minimum version `2`. |
| `accessories.call.mute` | `accessory_id`, `call_id`, `muted` (boolean) | The Mac's mute for the robot's call: the robot closes its microphone gate. Answers the status; `changed` as `accessories.call.end`. An owner decision. Device-class. Minimum version `2`. |
| `accessories.call.interrupt` | `accessory_id`, `call_id` | Stops the assistant's reply on the robot. It does not cancel a task. Answers the status; `changed` as `accessories.call.end`. An owner decision. Device-class. Minimum version `2`. |
| `accessories.call.task.cancel` | `accessory_id`, `call_id`, `task` | Cancels one task of a Live or Grok call (a task the call view marks `cancellable`). Answers the status; `changed` as `accessories.call.end`. An owner decision. Device-class. Minimum version `2`. |
| `accessories.check.start` | `accessory_id`, `check` (`tone`, `mic`, `face`, `motion`), `seconds` (`mic` only, 1 to 10, default 5) | Runs one local setup check on an attached robot with no call: a test tone, the microphone's level while the owner speaks (levels only, no audio leaves the robot), the kind's test face or its test head movement. Its progress and result show in the accessory's `check`. Answers the status. An owner decision. Device-class. Minimum version `2`. |
| `accessories.check.stop` | `accessory_id` | Ends any running check and answers the status. An owner decision. Device-class. Minimum version `2`. |
| `accessories.calibrate` | `accessory_id`, `op` (`begin`, `nudge`, `set_zero`, `cancel`), `axis` and `steps` (`nudge` only: `pan` or `tilt`, −64 to 64 and not 0) | Calibrate head, one step at a time, on an attached robot with head motion and no call. Progress shows in the accessory's `state.calibration`. Answers the status. An owner decision. Device-class. Minimum version `2`. |
| `accessories.set` | `accessory_id`, `volume`, `brightness` (each 0 to 100), `motion` (boolean, robots with head motion only), at least one | Changes the robot's own settings and answers the status; the robot reports the values it took in `state`. An owner decision. Device-class. Minimum version `2`. |

Notes that the shapes alone do not carry:

- A **Doctor session** is one of the three management operation families that are
  *runs*: it has its own session id, a whole-run budget (`local` 10000 ms,
  `network` 30000 ms), and cancellation. At most 2 sessions run concurrently
  (`busy` beyond that) and at most 8 finished sessions are retained, none older
  than 300000 ms.
- A **job** is another, and covers every long operation that is not Doctor.
  One shape serves all of them, so a client writes one poller, one progress row
  and one failure sentence rather than one per operation. Each kind carries its
  own budget: `provider_probe` 15000 ms, `auth` 300000 ms, `auth_import`
  60000 ms, `plugin_install` 600000 ms, `plugin_check` 30000 ms,
  `plugin_workspaces_discover` 60000 ms, `plugin_workspace_select` 60000 ms,
  `capability_install` 900000 ms, `meetings_signin` 660000 ms,
  `computer_use_grant` 120000 ms, `browser_install` 900000 ms, `imessage_grant`
  120000 ms, `imessage_policy_confirm` 180000 ms, `mcp_check` 75000 ms,
  `home_restore` 900000 ms. At most 4 jobs run at once, at most one per
  kind and name (`busy` beyond either), and at most 16 finished jobs are
  retained, none older than 600000 ms. A `job_id` this daemon does not retain
  answers `unknown_job`. A job that is stopped (cancelled, past its budget, or
  never minting the value its start waits for) stays `running` until its run
  has stopped, at most 5 s more, and holds its place against `busy` until then;
  it then finishes `cancelled`, `timed_out` or `failed`. Restore here's job
  (`home_restore`) is ended by the daemon itself once its run is over,
  however it ended, before it finishes: its request in the move back's record
  is taken back then (at most 35 s more), so a job read as finished never
  left a restore said to run.
- **`phase` is display copy, never a state.** It names the current step from a
  closed per-kind vocabulary — `provider_probe`: `calling`; `auth`: `binding`,
  `discovering`, `registering`, `awaiting_browser`, `verifying` (an MCP server's
  sign-in discovers and registers before the browser opens, and binds nothing
  first); `auth_import`: `reading_keychain`,
  `verifying`; `plugin_install`: `downloading`; `plugin_check`: `probing`;
  `plugin_workspaces_discover`: `listing`; `plugin_workspace_select`: `binding`;
  `capability_install`: `sidecar_downloading`, `downloading`,
  `verifying`; `meetings_signin`: `awaiting_signin`; `computer_use_grant`: none;
  `browser_install`: `sidecar_downloading`, `downloading`; `imessage_grant`: none;
  `imessage_policy_confirm`: none; `mcp_check`: `connecting`, `listing`;
  `home_restore`: none.
  `status` is the state a client switches on. A terminal job clears its phase
  unless it `failed` or `timed_out`, where the step it stopped in is part of the
  diagnosis. A run that reports a phase outside its vocabulary fails the job:
  a client has no sentence for it and would draw nothing.
- **A job's `failure` carries the daemon's own sentence**, and its `code` is one
  of `unavailable`, `refused`, `timed_out` and `internal_error`. A terminal
  status word is not a diagnosis, so a refusal that has an operator-facing
  reason is answered as a job failure rather than as a bare capability name: the
  meeting sign-in that has no notetaker installed says so in the job.
- **`auth.start` returns the authorize url once**, on the call that starts the
  flow, together with the lifetime it is good for. A later read of the same job
  carries the job view alone. The url is never logged, never traced and never
  retained.
- A **pairing session** is the third, and it is polled rather than a job: its
  view grows while it runs, and the operator decides mid-run. `mobile.pair.start`
  opens the one pairing window and answers at once, the pane reads
  `mobile.pair.get` (every 1000 ms is the recommended cadence) until the session
  is terminal, and `mobile.pair.decide` or `mobile.pair.cancel` ends it. One
  session is open at a time (`busy` {`operation`: `mobile.pair`} for a second
  start), and at most 8 finished sessions are retained, none older than
  300000 ms; a `session_id` this daemon does not retain answers
  `unknown_pairing_session`. There is no connection lease: an abandoned window
  closes on the daemon's own 120000 ms window and on nothing else, so the one
  clock is the daemon's. `ttl_ms` is relative, like `lifecycle.prepare`'s, and
  null once the session is terminal.
- **A pairing session's `state` is the switch.** It is one of `awaiting_scan`,
  `awaiting_decision`, `approved`, `denied`, `expired`, `cancelled` and `failed`.
  `request` fills in once a phone has completed the handshake and stays on the
  terminal view, so a pane can say who was approved or denied. `outcome` is set
  on `approved` (`device_id`) and on `denied`, `expired` and `cancelled`
  (`reason`: `denied`, `timeout` or `cancelled`); `failure` is set on `failed`,
  with the daemon's own sentence and a `code` of `unavailable`, `refused` or
  `internal_error`. A start refused for a reason the operator can act on (the
  channel is off, it could not start this boot, it was turned on and has not
  started yet, the gateway identity is incomplete, the paired-device list could
  not be read, the listener could not start) answers a `failed` view with a null
  `session_id` and a null `uri`: nothing was opened and there is nothing to
  poll.
- **`mobile.pair.start` returns the pairing link once**, as `uri`, on the call
  that opens the window. It carries the one-time secret the phone pairs with, so
  it is never logged, never traced and never retained, and no later read
  repeats it. The pane draws the QR code from it.
- **Only a phone whose secure hardware the daemon verified reaches the
  owner.** The phone's key attestation is verified before a request appears
  (see *Attestation* in the mobile protocol), so a request's
  `attestation.status` is `verified`, with the daemon's sentence, `build_role`
  is the role of the key the app is signed with, and `boot_state` is
  `{verified: true, locked: true}`. A request's `platform` is the phone's own
  word. A refused proof never reaches the owner: the session ends `failed`
  with `request` null, a `refused` failure whose sentence names the check that
  failed, or an `unavailable` failure when Google's attestation service could
  not be reached. A device paired with a verified attestation carries
  `platform`, `signer_role` and `boot_state`; one paired before the daemon
  verified attestation carries them null and keeps working.
- **`mobile.status`, `mobile.devices.list` and `mobile.devices.revoke` answer
  with the channel off**, so a pane can always read the state and the owner
  can always forget a phone or remove a computer: while the channel is not running the paired
  devices are read from, and forgotten in, the paired-device file. The switch
  is live: a `settings.apply` or a reload that moves it starts or stops the
  channel at once, and a write says in `side_effects` when the channel did not
  follow it. `enabled` is the switch and `started` whether the channel runs;
  they differ when the channel could not start (`refused`), or when setup was
  not complete at boot, until the next start. Every verb goes by `started`,
  never by the switch. A boot whose setup was not finished starts no channel,
  so while setup still is not finished `hold` is `setup`, the pairing verbs
  are refused with "The phone channel starts once setup is finished.", and a
  restart would start nothing. Once setup is finished `hold` is null and,
  while the switch is on, the restart reasons carry a `channels` reason,
  because the next start runs it.
  `refused` is true when the channel could not start this boot, and
  `refusal` names the class: `memory_disabled` (the conversation lives in the
  memory store, which is off), `identity`, `attachment_manifest` or
  `trust_store`; the daemon log says what to repair. `paired_devices` counts
  the running channel's phones and is 0 while it is not running.
  `identity.fingerprint` is the SHA-256 of the gateway public key a phone
  pins, lowercase hex in groups of four, null until the first pairing creates
  it. A decide with no phone waiting and a revoke of an id no phone has are
  `invalid_params` with the daemon's sentence. `unavailable`
  {`capability`: `mobile`} with no `sentence` means the phone channel could
  not answer at all: `mobile.pair.get`, `mobile.pair.decide` and
  `mobile.pair.cancel` answer it while the channel is not running.
- **A running channel that cannot listen stays up.** `listener.status` is
  `unavailable` when the channel runs but cannot listen on its address, with
  `listener.reason` one of `address_unavailable` (the address is not up yet,
  such as a tailnet address at login), `address_in_use` (another program holds
  the port), `permission_denied` or `listen_failed`. The channel retries on
  its own, from one second doubling to a minute, and stops retrying after a
  day until the next restart. `listener.reason` is null in every other state.
- **Push connects when there is something to send.** `apns.delivery` is
  `ready`, `degraded` while a connection to Apple is being made or when the
  last one failed or was lost (`apns.reason`: `connecting`, `connect_failed`
  or `connection_lost`; the next push reconnects), or `down` when no push
  dispatcher runs: the channel is not running, push is off, or its
  settings did not resolve (a key the keychain could not give, one that is
  not a P-256 key, a missing or invalid field), when `apns.credentials` reads
  `missing` and the rest of the channel runs. A connect is given up after ten
  seconds, and the status answers while one runs.
- **Remote reach lets a paired phone reach this daemon from any network**,
  through Fermix's relays (M62). `remote.state` is `off` (its switch is off,
  or the channel is not running), `dormant` (no phone has been paired yet;
  relay contact starts with the first pairing window), `helper_missing` (this
  build carries no `fermix-iroh`; the daemon log names the path),
  `starting`, `ready` or `failed`. While `ready`, `endpoint_id` is the
  daemon's iroh endpoint id, `relay` the URL of the relay it is reached
  through, `connected` whether it is connected to that relay right now, and
  `relay_error` the relay connection's last error, at most 512 bytes; while
  `failed`, `failure` is why, in the helper's own words where it gave them.
  Both have control characters removed, so a client shows them as written.
  Each is null, and `connected` false, in every other state. `refused` counts the remote
  connections the helper turned away by reason: `busy` (64 already
  connected), `alpn` (not a Fermix phone) and `bridge_unreachable` (the
  daemon was not taking them). A rail that fails is retried on its own, from
  one second doubling to a minute, and given up after a day until the next
  restart; a helper that disagrees with this daemon's protocol, iroh version
  or key is not retried.
- **Pairing and forgetting a device are the owner's decisions.**
  `mobile.pair.start`, `mobile.pair.decide`, `mobile.pair.cancel` and
  `mobile.devices.revoke` answer `unavailable` {`capability`: `mobile`,
  `sentence`: "Only the owner can pair or forget a phone; run this from your
  own terminal."} to a process the daemon itself started (a shell command the
  agent ran, a coding harness), to a detached process nobody is watching, and
  to a caller the daemon cannot place, and the daemon log says so. The
  sentence is what tells this refusal from a channel that is not running.
  Reading a session and the status stay open to every caller.
- **Opening the setup page is the owner's decision too.** A setup page
  session drives every decision the page offers, so `setup.session.create`
  answers `unavailable` {`capability`: `setup_session`, `sentence`: "Only the
  owner can open the setup page: use the Fermix app or your own terminal."} to the same callers. The Mac app's agent is an
  independent caller, and `fermix setup` mints the page's link in its own
  process without asking this socket.
- **Cue writes, the two values handed out and a proposal's answer are the
  owner's decisions too.** `cues.sources.add`, `.update`, `.remove`,
  `.enable`, `.disable`, `.token.new`, `.url.get`, `cues.mandates.add`,
  `.update`, `.remove`, `.enable`, `.disable`, `.approve`,
  `cues.proposals.decide` and `cues.watchers.always_allow.revoke` answer
  `unavailable` {`capability`: `cues`,
  `sentence`: "Only the owner can change cues: use the Fermix app or your own
  terminal."} to the same callers. So do the two cue writes that ride a
  generic method: `secret.set` and `secret.clear` on a `cue_source:` id, and
  `settings.apply` on the `cues` section, whatever its values, since turning
  `cues_mandates_enabled` back on undoes the owner's stop of every watcher action. The
  capability and the sentence are the request's family's. This raises the bar
  and authenticates nobody: it stops a model's own command from approving a
  mandate, answering a proposal or switching mandates back on. Every cue read
  stays open, and so does every other secret and settings section.
- **Every Always On step and setting the recovery passphrase are the
  owner's decisions (M75, Always On setup §6).** `home.act` (a code lets a
  server take this home; a review reads every keychain secret the move would
  carry; a move hands the home to a server; a restore takes it back from a
  copy) and
  `home.snapshots.passphrase` answer `unavailable` {`capability`: `home`,
  `sentence`: "Only the owner can set up Always On, move Fermix or set its
  recovery passphrase: use the Fermix app, the setup page or your own
  terminal."} to the same callers, so a command the agent ran can neither
  hand this home to a server nor replace the key its snapshots are encrypted
  to. `home.status`, `home.candidates.list` and `home.snapshots.status` stay
  open. The server's
  Always On steps (`home.enroll.open`, `home.enroll.withdraw`,
  `home.enroll.approve`, `home.enroll.deny`,
  `home.move.readiness`, `home.move.start`, `home.snapshots.run`) are refused
  on this socket to every caller, by name (*After a move*). A computer's own
  link is its owner's decision the same way: `computer.join.start`,
  `computer.join.cancel` and `computer.disconnect` are refused to those
  callers with that sentence.
- **What Fermix on the server may use on this computer is its owner's
  decision too (M97 §7.2).** `settings.apply` on the `computer` section
  answers `unavailable` {`capability`: `home`, `sentence`: "Only the person at
  this computer can change what Fermix on your server may use on it: use the
  Fermix app or the setup page."} to the same callers, so a command run on
  this computer, the server's work among them, never widens it.
- **`channels.mobile` is the phone channel's settings section**: the enable
  switch and the remote-reach switch `mobile_iroh` (on by default), each
  applied the moment it is written (their rows' `restart` is false), and the
  port, the address it listens on and the local-network announcement, which
  are read when the channel starts, are boot-bound and are `advanced`. Neither
  the address nor the announcement reaches remote reach: only its own switch
  keeps a phone to the home network and Tailscale. Remote reach is
  switched within a running channel: with the channel off it is read when the
  channel starts, and a write says in `side_effects` when the rail did not
  follow it. It is a section of its own rather than a
  channels-inventory entry, because the phone channel has no credential.
  `setup.state.get` carries a `mobile` channel row after the inventory
  channels, always `configured`, with mode `listener` while it is enabled.
- **`browser` is the managed task browser's section**, under pane `browser`,
  published on every install. Its first row, `browser_executable`, is read-only
  and says which browser the launcher would start for a task: `value` is that
  browser's name (`Google Chrome`, `Chromium`, `Google Chrome Canary`, `Chrome`,
  `Google Chrome for Testing` for the Chromium Fermix downloads, or `The
  configured browser` for one set by path), and null when there is none, with
  the daemon's sentence in `footer`: `No Chrome or Chromium is installed.`, or
  the refusal of a browser configuration the launcher would not start, which a
  download does not clear. A path never crosses the wire. The other three rows
  are the `[fermix_core.browser]` keys a person sets. `browser_default_profile`
  is how tasks run, and its options are the managed profile names, which is how
  that section already spells it: `fermix` (automatically: in a window where
  there is a display, otherwise in the background), `fermix_headless` and
  `fermix_visible`. `browser_max_tabs` is a whole number from 1, with no
  ceiling. `browser_allowed_hosts` replaces the whole list, and its value is the
  list in force: the shipped default until the file names one. Every row
  carries `restart: false`, because a call reads the section when it runs; a
  browser already running takes a new tab cap when it next starts.
  `settings.apply` refuses a value the browser would refuse at launch, in the
  browser's own sentence.
- **`web_search` also carries place search's backend.** After
  `web_search_backend`, the row `place_search_backend` (a choice, `Place
  search`) is `[fermix_core.tools.place_search] backend`, and its `value` is the
  backend in force: the one the file names, or the build's default when it
  names none (`apple_maps` in the Fermix Mac app's engine, which carries the
  Apple Maps helper, `brave` in the Homebrew and Linux builds). Its options are
  the ones this build can run: `apple_maps` (`Apple Maps`, hint `Needs no key`)
  and `brave` (`Brave`) where the build carries the helper, `brave` alone
  everywhere else, where `settings.apply` refuses `apple_maps` as a value the
  row does not publish. The `brave_api_key`
  row stands whenever web search or place search uses Brave, its footer
  `Also powers place search.` when both do and `Powers place search.` when only
  place search does; with neither on Brave it is not published. A call reads
  the section when it runs, so the row carries the section's usual `restart`.
- **`browser.install.start` completes only once the launcher finds a
  browser.** It runs the meeting notetaker's own install step (the notetaker's
  helper, then the Chromium build that helper is pinned to, about 150 MB, and a
  fast no-op when it is already there) and then asks the launcher which browser
  tasks now run in. It completes with `result` {`installed`: true, `browser`:
  that browser's name}. A machine the notetaker has no build for, a Chromium
  step that fails, and a download the launcher still cannot find each fail the
  job with the daemon's sentence. One download runs at a time (`busy`
  {`operation`: `browser_install`}).
- **A live model listing never degrades to the catalog.** The two answer
  different questions, so a live fetch that fails answers `unavailable`
  {`capability`: `model_listing`} and `source` always names where the rows on
  the wire came from. A provider with no live listing of its own, whose models
  ship in the catalog, answers `live` true with that catalog and `source`
  `catalog`, since there is no live fetch to fail.
- **`default_model` is the model in force, never the config value alone.** A
  provider row in `setup.state.get`, the Model row of that provider's settings
  section and `provider.model` in `overview.get` carry the model the daemon
  calls the provider with: the one chosen in Settings, or the catalog default
  until one is. A sign-in that has just completed therefore names its model at
  once, and Doctor probes the same one. Engines before this published `null`,
  or an empty value, until a model was chosen, so a client keeps accepting both.
- **`computer_use.permissions.get` never prompts**, and `installed` comes from
  the installer rather than from the probe: the feature being switched off says
  nothing about whether the helper is on disk, and that is exactly what decides
  whether a surface offers "install it" or "turn it on". An answer whose
  `probed_at` is not null carries `platform`, the helper's own word for its
  system (`macos`, `linux`, `unknown` where it named none); one that probed
  nothing (switched off, not installed) carries none, and a macOS answer carries
  nothing else new. On Linux nothing is granted: `screen_capture` and
  `input_control` say whether this session's pixel route serves screenshots, and
  the pointer and keys, and are not grants, so a Linux client offers no grant
  and `computer_use.grant.start` stays the Mac's. A Linux answer adds
  `display_server`, the probe's word (`x11`, `wayland`, `none`, or another,
  `unknown` where the helper named none), which names the session's display,
  not its pixel route: on Wayland only GNOME's desktop portal gives pixels, so
  another Wayland desktop, or a portal that cannot serve, has a display and no
  route. The route is what the `pixel route` row says, rendered verbatim like
  every row; from an older helper, which sends no route and so no such row, the
  client names no route and says what the two booleans say. Either way it never
  guesses a route from the word or from a sentence. It adds
  `rows` too: the rows `fermix doctor` prints after its `computer use` row, in
  that order and from the same producers, each `{name, status, detail}`.
  `status` is the doctor's `ok`, `warn`, `fail` or `not_applicable`; `detail` is
  the daemon's sentence, rendered verbatim, and a backticked span in it is a
  literal shown as written (the command that resets a stored screenshot
  refusal, the word the helper names an unavailable accessibility bus's cause
  by, the desktop portal interface a session without a pixel route lacks). The
  `computer use` row is not among them: it ends with the helper's build suffix,
  an internal name and version the copy rules keep out of what an app renders.
  The three fields are optional for older protocol-2 engines (see
  *Per-method minimum versions*), so neither the protocol version nor the
  method's minimum moves: a client that finds no `platform` renders the two
  booleans as the screen capture and input control rows it always has.
- **iMessage runs on a Mac, or through one.** The three `imessage.*` methods
  answer `unavailable` {`capability`: `imessage`} anywhere but a Mac. Off a
  Mac, `settings.sections` publishes `channels.imessage` only where a Mac of
  the home offers Messages (a server whose iMessage that Mac carries), and
  `settings.get` refuses the section elsewhere. `channels.imessage` carries
  three boot-bound rows:
  `imessage_owner_user_id` (`text`); `imessage_allowed_sender_ids`, the guests
  (`list`); and the `imessage_enabled` switch. There is no account row: the
  helper derives the account when it confirms the recipients. Saving the owner
  or the guests never turns the channel on: only its switch does.
  `capabilities.install.start` {`target`: `imessage_helper`} installs Fermix
  Messages: it checks the download's sha256, extracts the bundle, verifies its
  signature and Team ID, places it and registers it with LaunchServices, and a
  refusal names the check that stopped it.
- **`imessage.permissions.get` never prompts.** With `installed: false` every
  other field is null. `full_disk_access` is `granted` or `denied`; `db` is
  `readable`, `missing`, `unreadable` or `schema_unexpected`; `automation` is
  `granted`, `denied`, `not_determined` or `unknown` (Messages is not running);
  `signed_in` is null while Automation is not granted, because the helper cannot
  ask Messages without it; `policy` is `confirmed`, `unconfirmed` or `absent`.
  `policy_matches_config` is true only when the confirmed recipients are exactly
  the saved ones; anything else is the state "Awaiting confirmation", cleared by
  `imessage.policy.confirm` and never by the engine rewriting the helper's
  record. A probe that cannot run answers `unavailable` {`capability`:
  `imessage_permissions`}.
- **An iMessage grant or confirmation waits on a person**, so each is a job
  whose `result` is the permissions view. A confirmation's `result` adds
  `outcome`: `confirmed`, or `policy_refused` when the owner pressed Cancel on
  the helper's dialog. Cancel is a decision, so it completes the job rather than
  failing it. A confirmation with no saved owner, with an owner that is not a
  handle of the Messages account on this Mac, or with an owner that is the
  address Messages on this Mac is signed in as, fails `refused` with the
  daemon's sentence; the last one names the fix, signing Messages in with a
  separate Apple ID for Fermix. One of each runs at a time (`busy` {`operation`:
  `imessage_grant`} or `imessage_policy_confirm`).
- A **check status** is one of `passed`, `warning`, `failed`, `not_applicable`,
  `unavailable`, `skipped`, `cancelled`, `timed_out`. `not_applicable` means
  this distribution does not have the check (the two distribution rows under
  `macos_app`); `unavailable` means the check itself could not answer. A session
  `summary` carries one count per status.
- **Readiness is split into gating and advisory.** A failure carries `gating`,
  the `pane` that can clear it, and a closed-set `detail_key`. Provider
  failures gate; personalization, the channels, realtime, and allowed
  sandbox environment variables the daemon cannot read (`sandbox:env_missing`,
  `sandbox:env_helper_failed`, pane `sandbox`, one failure per cause naming
  every affected variable, with `component` `sandbox:env:missing` or
  `sandbox:env:helper_failed`) are advisory. `status` is `ready` exactly
  when no gating failure remains, and every advisory failure stays in the list,
  so a surface never needs a second definition of ready. Personalization is
  advisory because the daemon's first boot seeds it from the machine (the
  system time zone, the account's full name, a default style), so its row
  fires only where the machine could not answer; engines before this gated on
  it, so a client keeps reading `gating` rather than assuming it. A failure
  also carries `sentence`, the engine's own words where it publishes them,
  which a client shows in place of its own for the `detail_key`: the iMessage
  rows (`channel:imessage:helper`, `:carrier`, `:mac_only`, `:conflict` and
  `:away`), which name the Mac of the home that carries Messages where the
  engine knows it ("studio-mac, the Mac that carries Messages, is asleep or
  offline."). It is null on every other row, whose words a client keeps by
  its key, and absent from an engine before it, which a client reads as null.
- **Restart truth has one owner.** `restart.required` and `restart.reasons` come
  from the daemon's two baselines: the application environment captured at boot,
  and the parsed settings file as this daemon last saw it. The sentence for each
  reason is the daemon's; a client renders it and never composes its own.
- **`coexistence.config_state`** is `clear`, `external_change` (the settings file
  was edited by something else, and every write refuses until it is read again),
  or `config_unreadable` (the file cannot be parsed, which is never answered with
  a reload).
- **`coexistence.secret_acl_restricted.present` is `null` until Doctor has run.**
  Deciding whether a stored key is readable means reading it, which costs one
  keychain subprocess per key and prompts on exactly the keys the row exists to
  name. `setup.state.get` never does that: it publishes the last measurement the
  `secret_acl_restricted` Doctor check took, and `null` means "not measured",
  which is not the same answer as `false`.
- **A settings row is a fixed record.** Every field is present on every row,
  `null` where it does not apply, so a client decodes one shape rather than
  probing for keys. `kind` is one of `toggle`, `choice`, `text`, `number`,
  `secret` and `list`; `unit` and `format` are meaningful on a number row only;
  `present` is meaningful on a secret row only, and a secret row never carries a
  value.
- **`options` is the value space unless `suggestions` says otherwise.** On a
  choice row with `suggestions: false`, `settings.apply` refuses a value that is
  not among the options; render a closed menu. On a choice row with
  `suggestions: true` — the time zone row, the communication style row and the
  four model rows — the options are only what a client may offer inline, an
  off-list value is accepted wherever the key's own validator takes it, and a
  native picker may send any zone the database knows or any model the vendor
  ships. `suggestions` is `false` on every non-choice kind.
- **A text value that names something is one line.** `settings.apply` trims the
  ends of a text, suggestion or list value, so a pasted trailing line break
  saves, and refuses one with a control character left inside it (`This setting
  takes a single line of text.`). The two prose rows, the meeting announcement
  and the communication style, take line breaks and keep them as sent.
- **A `disabled` option is shown and cannot be chosen.** Its `hint` is never
  null and says why: show the option unselectable, with its hint inline or on
  hover, rather than hiding it. `settings.apply` refuses a disabled value with
  that same sentence. Today the two transcription backend rows publish one:
  `local`, on a machine this build has no on-device speech engine for.
- **`restart` on a row is derived, never declared.** A row is flagged exactly
  when its own configuration section is one the daemon compares against the
  values it read at boot, so a row can never deny a restart the next
  `overview.get` asks for. A section can have a part that is read on every use
  instead: the sandbox environment policy (the allowed names, the deny list and
  where each value comes from) is read by every command, so the allowed
  environment variables row and every name row below it carry `restart: false`,
  while the sandbox mode and command profile rows still carry `true`.
- **`read_only` marks a row `settings.apply` will not take**, rendered as a plain
  labelled row rather than a control whose save always refuses.
- **`info` is the longer explanation, kept behind an info control.** `footer` is
  the one short line under the control and is always shown; `info` is a
  paragraph a client puts behind an `(i)` beside the row and reveals on demand.
  It is `null` on every row with nothing more to say, which is most of them.
  A row carries one when its choice has a consequence its label cannot say,
  such as the Venice model row, where the privacy tier in each model's label is two
  words that mean materially different things; the secrets section's store
  row, where the choice trades a keyring password for a file that is not
  encrypted; and the phone channel's reach-from-anywhere switch, which says
  what turning it off keeps the phone to.
- **`example` is a sample value for an empty field.** A client shows it in an
  empty text or list field, in place of its own empty prompt ("Not set", "New
  entry"), so the field shows what goes in it. It is never a default: nothing
  is saved from it, and a client never sends it. It is `null` on every row of
  another kind and on every row with nothing to show; today the fields of a
  stream source carry one.
- **`advanced` marks a row most people never need to change.** A client draws
  a section's advanced rows after its other rows, under one disclosure that
  starts closed; a section with none draws no disclosure. It says nothing about
  how the row applies, which is `restart`'s job. Today the phone channel's
  port, listen address and local-network announcement carry it.
- **The secrets section chooses where a new secret is kept.** Section
  `secrets`, pane `secrets`, publishes one closed choice row, `secret_store`:
  `keyring` (the default, and what a home that never chose reads as) or `file`,
  one `0600` file per secret under the Fermix home's `secrets/` directory. It
  exists for a Linux desktop that logs in with a fingerprint or automatically,
  where the login keyring stays locked and every save asks for its password.
  `settings.apply` records the choice in `[fermix_core] secret_store` and applies
  it at once, so the very next `secret.set` writes to the chosen store and the
  row carries `restart: false`. Choosing moves nothing: a secret already saved
  stays in the store it was saved to and is read back from there, and `fermix
  setup --migrate-secrets` is what moves them. `secret.set` refusing a locked
  keyring (`secret_store_failed`, reason `locked`) is unchanged.
- **The sandbox section publishes one row per environment variable name.**
  After `sandbox_env_allow` come the allowed names in allow-list order, then
  the names Fermix still stores but no longer allows, sorted. Each row's key is
  `env:<NAME>` and its label is the name itself. A stored name is a `secret`
  row with `present: true`, and one no longer allowed says in its footer that
  commands do not get it until the name is allowed again. An allowed name with
  nothing stored is a `secret` row with `present: false`, whose footer says
  commands get it only if Fermix was started with it. A name whose value comes
  from a helper command or from another variable, and a name Fermix cannot
  store, is a read-only `text` row whose footer says where the value comes from;
  for another variable, `value` is that variable's name. `present` is read from
  the settings file alone, like every other secret row. Removing a name from
  the allow list keeps its stored value, so its row stays reachable: allowing
  the name again reuses the value, and `secret.clear` removes it.
- **The voice section's model row selects its engine.** `realtime_model`
  publishes every model the engines ship, in one list, each option labelled
  with the engine it selects: `openai_realtime` (the Realtime API, which runs
  tools inside the voice session), `openai_live` (the Live API, which
  delegates every tool call, memory read and reasoning step back to the Fermix
  agent and bills by the minute) or `xai_realtime` (Grok Voice on SpaceXAI,
  which delegates the same way and bills by the minute). `openai_live` and
  `xai_realtime` are the task engines. There is no engine row; the engine is
  derived from the model and stored as `realtime.engine`, with the provider it
  dials as `realtime.provider` (`openai` or `xai`), and `settings.apply` refuses
  `realtime_engine` as a key this section does not have. The rest of the section
  is scoped to the engine that model implies: `realtime_voice` publishes the
  voices of that engine and nothing else, `realtime_reasoning_effort` is a
  Realtime session setting with no task-engine equivalent and is absent under
  both task engines, and `realtime_backend` is present only under a task engine,
  is read-only, and names the primary provider and model that answer while the
  engine speaks. `realtime_conversation` ("Voice calls join the chat") is present
  only under a task engine too, a choice of `chat` or `private` stored as
  `realtime.conversation`: `chat`, the value in force while the key is unset,
  runs a call's hand-offs in the chat's own conversation, and `private` keeps
  them in one of the call's own. `realtime_camera_share` ("Share the phone's
  camera") is present only under a task engine as well, a toggle stored as
  `realtime.camera_share` and on by default: whether a call from a paired phone
  may share its camera once the owner turns the camera on in the call (M87).
  The Realtime engine takes no calls from the phone, so it has no such row and
  refuses the key. The key row is the voice provider's own slot:
  `openai_api_key` under both OpenAI engines and `xai_api_key` under Grok, which
  takes an API key only (a SpaceXAI sign-in does not authorize voice). Applying a
  model of another engine therefore moves the engine and its provider with it,
  adds or removes the reasoning effort, moves a voice the new engine does not
  ship to that engine's default, drops a chosen `realtime_conversation` and the
  camera switch on the way to Realtime, puts the camera switch back, on, on the
  way from Realtime to a task engine (a move between Live and Grok keeps it as it
  was), and on the way to Grok turns off screen sharing during calls, which Grok
  does not support. The result names every key the daemon derived in
  `applied` — including `realtime_engine`, which is a derived key rather than a
  row — with a sentence for each in `side_effects` (screen sharing has a
  sentence and no row); reload the section when one of those keys appears,
  because its row list has changed. `overview.get` reports the same selection as
  `realtime.engine`, null while voice is disabled.
- **Secrets travel inbound only, in `secret.set`, one per call.** Every other
  method reports presence as a boolean. "Present" means a reference or a value
  sits at that key's own path, never "the keyring holds an item": a key stored
  without its reference is never read back, so calling it present would describe
  a credential the runtime cannot use.
- **A stored value is not always the value in use.** For the provider API
  keys, the WhatsApp, Discord and Slack channel secrets and the APNs key, a
  nonblank environment variable of the key's own name (`ANTHROPIC_API_KEY`,
  `DISCORD_BOT_TOKEN`, …) in the daemon's environment overrides the stored value
  at every start. `secret.set` and `secret.clear` name that variable in
  `environment_override` (null when the stored value is the one in use, and
  null for every other family), so storing a value the daemon will not use
  still succeeds and says so. The field is optional: an older daemon omits it,
  which a client renders as no override reported.
- **`id` names one of seven families.** A bare registry key (`openai_api_key`,
  `telegram_bot_token`, …), `plugin:<name>` for a plugin's own token,
  `oauth_client:<provider>` for a sign-in client's secret,
  `anthropic_setup_token`, `env:<NAME>` for a sandbox environment variable,
  `mcp:<name>/…` for a value an MCP server declares, and `cue_source:<ref>:…`
  for what the owner types for a cue source.
  The first three take the same keychain-first write.
  The fourth is a different mechanism and is documented as such: a
  `claude setup-token` value is a long-lived subscription credential, so it is
  stored in the auth store rather than the keychain, storing one also selects
  the Anthropic sign-in route that reads it (a stored token the runtime never
  calls is not a connection), and clearing one is the same operation as
  `auth.logout anthropic`. Its `present` is "a setup token is stored", not "an
  Anthropic sign-in exists": an adopted Claude Code login lives under the same
  profile and is reported by `setup.state.get`'s account row instead.
- **`env:<NAME>` stores a value every sandboxed command receives as `NAME`.**
  It is the key of the sandbox section's name rows, and the family is open:
  `NAME` is any name matching `^[A-Za-z_][A-Za-z0-9_]{0,127}$` exactly, except
  `PATH`, `HOME`, `USER`, `LANG`, `SHELL`, `TMPDIR`, `FERMIX_HOME` and any name
  starting `LC_`, which Fermix sets itself. The value is one line of 1 to 8,192
  bytes of printable ASCII, space to `~` (so no NUL, CR, LF, tab or non-ASCII
  character), and at most 64 names are stored. `secret.set`
  stores the value in the OS secret store in a namespace of its own (a skill's
  `OPENAI_API_KEY` never touches the OpenAI provider's key), reads it back to
  verify it, and then allows the name, removes it from the deny list and points
  the name at the stored value in one settings write. It refuses a name whose
  value already comes from a helper command or another variable, because
  storing would silently change where the value comes from. `secret.clear`
  deletes the stored value first and then the reference, so a refused delete
  changes nothing; the name stays allowed and reads the environment Fermix was
  started with. Neither ever asks for a restart. Where no OS secret store
  exists, `secret.set` answers `secret_store_failed` with reason `unavailable`.
  `present` is "the settings file points this name at a stored value".
- **`mcp:<name>/env/<NAME>`, `mcp:<name>/header/<Header-Name>` and
  `mcp:<name>/client_secret` store the values an MCP server declares**: a local
  server's `env_names`, a remote server's headers (`header_names` and its
  `key_header`), and the secret of its `oauth_client_id`, which is optional: a
  client ID with no secret is a pre-registered public client, so a server
  never waits for it, and `oauth_client.secret_present` says whether one is
  stored. The family is open,
  like `env:`: an id is accepted only when the server exists and declares that
  name, and the server's block in `config.toml` is the reference, so storing
  writes nothing else and `present` is "the store reads the value back". The
  value is one line of 1 to 8,192 bytes; an `Authorization` key is sent as
  `Bearer <value>`, so a pasted `Bearer …` is stored as what follows it.
  Storing the last value a server needs starts it, storing a new one
  restarts it, and clearing one it runs with stops it. Both answer the shape
  `env:` answers, with `environment_override` null. A value pasted into the
  add form never travels back: `mcp.servers.draft` holds it under a
  `draft_id`, and `mcp.servers.add` stores it. A server whose name was
  written by hand outside the name rule holds no values, and the refusal says to
  add it again under a lowercase name.
- **`cue_source:<ref>:key` and `cue_source:<ref>:secret` store what the owner
  types for a cue source.** An id is accepted only when the source exists and
  its kind declares the field (a webhook's signing or shared secret, a feed's
  or a stream's key and secret). The value is one line of 1 to 8,192 bytes.
  Storing writes the value and the reference that names it in one settings
  write, so storing the last secret a source waits for starts it; clearing
  deletes the value first, then the reference, and a source that needs that
  secret waits for it again. `present` is "the settings file points this
  field at a stored value". `cue_source:<ref>:token` and
  `cue_source:<ref>:path_secret` are Fermix's to make and are refused with
  `invalid_params` and a sentence: a new token comes from
  `cues.sources.token.new`, an address from `cues.sources.url.get`. On a build
  without cues the family answers `unavailable` {`capability`: `cues`}. Both
  methods on this family are the owner's decisions, as every cue write is: a
  caller the daemon does not place as the owner (a process it started, a
  detached one, or one it cannot place) is answered `unavailable`
  {`capability`: `cues`, `sentence`: "Only the owner can change cues: use the
  Fermix app or your own terminal."}, and nothing is stored or cleared.
- **A plugin row is one shape for two halves.** An installed plugin and a
  catalog entry that has never been fetched publish the same fields, so a client
  decodes one record rather than two. `installed` is what separates them.
- **`consent_sentence` is always present, and it names where the code runs.**
  `remote_mcp` runs on the plugin's own servers, `local_stdio` runs on this Mac
  as a separate process, and a plugin with no runtime block runs inside Fermix
  itself. There is no absent case and no default: a hosted plugin rendering the
  local-process line is the one defect this field exists to prevent, and
  `remote_disclosure` names what leaves this Mac wherever the runtime is hosted.
- **The status vocabulary and the verb vocabulary stay on this side.** A row
  carries the daemon's `status_sentence` and its `primary_verb`; the `status`
  atom is published for logs and support, and nothing on the far side is
  expected to have words for it. `primary_verb` is `null` where the next step is
  not a button this surface owns, and a client then uses its own word for
  whatever control it drew.
- **After a move from another system the new primary installs the plugins
  again.** A plugin it could not install again is `reinstall_failed`, enabled
  or not, and leads with `install`; one the catalog has no build of for that
  computer is `incompatible`. Either lasts until an install records another
  build of it.
- **A word is not a routing key: `primary_action` and `actions` are.** Every
  verb is published twice — `verbs` carries the words to draw, `actions` carries
  one closed id per word IN THE SAME ORDER saying which method that button runs,
  and `primary_verb`/`primary_action` are the same pair for the verb the row
  leads with. The ids are `install`, `enable`, `disable`, `sign_in`,
  `add_token`, `replace_token`, `set_up_client`, `choose_workspace`, `check` and
  `disconnect`; `primary_action` is `null` exactly when `primary_verb` is.
  Paint `verbs[i]`, route on `actions[i]`, and draw no buttons at all when
  `verbs` is empty. Deriving the method from `status` instead is what put a
  button labelled "Choose workspace" onto the health check, and one labelled
  "Set up the sign-in client" onto a sign-in the daemon refuses. Two words share
  one id: "Sign in" and "Sign in again" are the same method with different copy.
- **A setting names the control it is, and a switch has exactly two words.**
  Every entry in `settings` carries a `kind`: `text` is a free-text field, and
  `boolean` is a switch whose value is the string `true` or `false` and nothing
  else. `plugins.setting.set` refuses any other value for a `boolean` setting
  with "This setting is a switch: send true or false.", and refuses a blank
  value for either kind; an unwritten setting is simply absent from the row's
  `value`, which is what off is. The daemon always publishes `kind`, but it is
  optional for older protocol-2 engines, and an absent one reads as `text`.
  The two words are the spelling a manifest's per-tool gate reads, so a switch
  drawn as a text field is how an operator turns a tool on by typing `TRUE` and
  finds it still off.
- **`credential_present` is published rather than inferred.** A plugin that
  authenticates with a typed token never has an `account_label`, so reading
  presence off that field would hide the token that is actually stored.
- **A discovery is republished on the row, not in the job.** A job result is
  flat scalars only, so `plugins.workspaces.discover.start` records what it
  found and `plugins.list` carries it in `workspaces`. It is boot-bound: a
  restart clears it, and a new discovery replaces the previous list.
- **Native driver features are not integrations.** Computer use, computer
  history and the meeting notetaker are settings sections with their own panes
  and their own switches, so they never appear as plugin rows even where the
  catalog carries an entry for their helper.
- **An MCP server row is the daemon's, like a plugin row.** One row shape
  serves every operator MCP server, whether the owner added it here, imported
  it, or wrote its `[mcp.servers.<name>]` block by hand (`origin` null). Every
  field is present on every row, null where the transport has none, except
  `tools`, which only `mcp.servers.get` carries: 32 servers of 256 described
  tools would pass the result bound, so the list carries `tool_count` and
  `tools_on` alone. `consent_sentence` always says where the code runs and what
  leaves this Mac: a local server runs on this Mac as a separate program with
  the owner's access, a remote one on the host its URL names.
- **The status is derived in one order, and the row switches on actions.** `off`
  (turned off), `failed` for a server that names nothing to start (a local one
  without its command, a remote one without its URL, which only a hand edit
  writes; its sentence says what to add, and it offers only `disable`),
  `needs_secret` (a value it needs is not stored, so the server does not start;
  the sentence names what it waits for), `needs_sign_in` (an `auto` server the
  server itself asked to sign in), `starting` (connecting, or no status yet for
  a server that runs), `connected`, `retrying` (the last connection failed and
  the daemon is starting it again), `failed` (it stopped trying). The first that
  holds wins. The status is published for logs and support; a client draws
  `status_sentence` and switches on `primary_action` and `actions`, which are
  `check`, `enable`, `disable`, `sign_in` and `sign_out`, in that order. `check`
  is offered while a server is `connected`, `retrying` or `failed`, and a
  `failed` server leads with it; an `off` server offers and leads with `enable`
  alone. `needs_sign_in` also covers an `auto` server that asked to be signed
  in again for more access. `last_error` is the daemon's sentence for the
  failure while a server is `retrying` or `failed`, and null otherwise.
- **An `auto` server's sign-in is on its row.** `auth.state` is `signed_in`
  with a grant the server can use, `expired` when its authorization server
  refused to refresh it, `signed_out` where the server asked for a sign-in and
  there is no grant, and `not_needed` otherwise; `account_label` (the
  account's email, user name or name, else the authorization server's host)
  and `issuer` (the authorization server) name the grant, and are null without
  one. `sign_in` is offered, and led with, where the server asks for a sign-in,
  where the grant expired, and where one of its tools asked for more access than
  the grant gives (`status_sentence` then says so beside its tools); `sign_out`
  is offered while signed in. A `header` or `none` server offers neither.
- **An MCP server signs in through `auth.start mcp:<name>`.** The job discovers
  the server's authorization server the way the MCP authorization
  specification orders it (the server's `401` challenge, its protected resource
  metadata, then its authorization server's metadata), with no redirect
  followed and every address held to the rule its own URL is. It registers
  with the server's `oauth_client_id` (and `mcp:<name>/client_secret` when
  stored; without one it is a public client), which stays bound to the
  authorization server it was signed in with: through a sign-out, and through
  a server that names another, where a sign-in with the same client ID fails
  the job with a sentence naming both before the secret is read or the browser
  opens, until the owner enters another client ID or removes and adds the
  server again; else with Fermix's client metadata document
  (`https://fermix.ai/oauth/mcp-client.json`) where the authorization server
  takes one, else by dynamic client registration, which names the exact
  loopback redirect the sign-in uses, port included; its client and port are
  kept for the next sign-in to the same authorization server, which uses that
  port again, or registers again where the port is taken. The browser sign-in uses PKCE
  and names the server as the resource; a reply from another authorization
  server is refused. A sign-in that completes starts the server once and its
  result carries `account_label`. The grant lives in the daemon's auth store,
  never in `config.toml` and never on the wire; it is refreshed before it
  expires and once when the server refuses it, is not used once the server
  names another authorization server, and is deleted with the server.
- **`server_info` and the tools are what the server last said.** Both come from
  the server's last connection, so a server that is off or starting again still
  shows them; `server_info` is null before a server first connects. A tool's
  `read_only` and `destructive` are the server's own `readOnlyHint` and
  `destructiveHint` as it declared them, an absent hint being false; they inform
  the owner and decide nothing. This is not the MCP specification's default,
  which takes a tool that declares nothing as destructive, and a tool declared
  read-only is never destructive. `enabled` is false for a tool the owner hid
  from the agent, and `tools_on` counts the rest. Only a tool whose name is at
  most 128 bytes is described, so a tool with a longer name is counted in
  `tool_count`, not listed in `tools`, and counted as on in `tools_on`.
- **A form writes a server as fields, and a refusal names the field.**
  `command_line` is one line, split as a shell splits one simple command: blanks
  separate words, quotes and `\` keep what they cover, and a line that needs a
  shell (a pipe, a redirection, a list, `$`, a leading `NAME=value`) is refused
  rather than run as something else. The one expansion is a shell's `~`: an
  unquoted `~` that starts a word, alone or before a `/`, is the home folder, in
  `command_line` and in `cwd`, and the server is written with the absolute path
  that runs, which the row's `location` shows; a quoted `~` stays as it is, and
  `~name` is refused. A local server takes `command_line`, `cwd` and
  `env_names`; a remote one `url`, `auth` (`auto`, the default, `header` or
  `none`), `key_header`, `header_names` and `oauth_client_id`; the other
  transport's fields are refused. `header_names` are the headers besides the
  key's own, which `key_header` names and the row reports as `auth.key_header`.
  A URL is `https`, or `http` only to this Mac. On an update a null clears a
  nullable field (`cwd`, `key_header`, `oauth_client_id`) and a list replaces
  the one it names. Every refusal is `invalid_params` with the daemon's
  `sentence` and the `field` a form marks, named as the form names it. Values
  never ride these methods: they follow through `secret.set mcp:<name>/…`, or
  an add's `draft_id`, and the server starts once the last one is stored. Every write applies to the one
  server it names, with no restart, and refuses with `external_change` while the
  settings file was changed outside Fermix.
- **A draft fills the add form, and writes nothing.** `mcp.servers.draft`
  reads one `text` of at most 65536 bytes: a URL (`https`, or `http` only to
  this Mac), a command line (split as `command_line` is, with its refusals and
  its `~`), JSON (an `mcpServers` map as Claude Desktop, Claude Code, Cursor and
  Windsurf write it, a `servers` map as VS Code writes it, a bare map of names to
  servers, or one server object, with `command`, `args`, `env` and `cwd`, or
  `url` or `serverUrl` with `headers`, and `type` or `transport` of `stdio`,
  `http`, `streamable-http` or `sse`), a `claude mcp add` line (`--transport`,
  `--scope`, `-e`, `-H`, a name, then a URL or `--` and a command) or a `claude
  mcp add-json` line, or a Codex block of `[mcp_servers.<name>]` tables. It
  answers at most 32 drafts, in the text's order (a Codex block's by name).
  Every field of a draft is present, null where the transport has none.
  `command_line` is the words that will run, a leading `~` written out;
  `resolved_command` is the program a local command runs and `command_sentence`
  says `Runs <program>` or the row's own sentence for a program this Mac does
  not have. The first draft after the daemon starts may begin reading the login
  shell's PATH and waits for it only briefly, so a bare command's
  `resolved_command` and `command_sentence` may be null, and the next draft has
  them. A server keeps the name its source gives it where a new server may take
  that name; otherwise the name comes from the URL's host, the label before its
  public suffix (`mcp.linear.app` is `linear`, `eu.mcp.sentry.io` is `sentry`),
  or the command's package (`uvx mcp-server-fetch` is `fetch`).
  `conflict` is true where an MCP server here already has the name, or one that
  gives its tools the same names. `summary` is `Remote, <host>`, or the program
  and the package it starts.
- **A pasted value is held, never returned.** A variable's or a header's
  value in the text is held in the daemon's memory, and `env` and `headers` say
  which names it carried (`present`); the key's header is among `headers`, and
  `key_header` names it. A placeholder (`${input:…}`, `${env:…}`, `${NAME}`,
  `${NAME:-default}`, an empty value, a Codex variable name, and in a `claude
  mcp add` line, written for a shell, `$NAME` or anything the shell would fill
  in, `Bearer $NAME` included) declares its name and carries no value, so the
  server waits for it. In such a line a `$` in the name, the address or the
  command needs a shell and is refused, as in a command line.
  `Authorization: Bearer <token>` is the key, sent as `Bearer <value>`, its value the token; otherwise
  a remote server's first header is its key and the rest its other headers, and
  a remote server with no header signs in by itself (`auto`). Each draft that
  carried a value has its own `draft_id`, null for one that carried none, so
  one paste may give two servers one name with two values. A `draft_id` is
  opaque, belongs to this boot, expires 10 minutes after its draft, is used
  once, and at most 64 are held, a newer one dropping the oldest. An add with it
  stores, under the name the form chose, the values for the names the form
  still declares, and drops the rest; the server starts once, with all of them,
  and its row then waits only for what the paste did not carry. A refused add
  stores nothing and leaves the `draft_id` for the next try. An unknown,
  expired or used `draft_id` is `invalid_params` with `field` `draft_id`.
- **A paste Fermix cannot add as given is refused whole.** Text that is none of
  the shapes, and a placeholder inside a command, its arguments, a working
  folder or an address (nothing there is filled in), are `invalid_params` with
  `field` `text` and a sentence; in a paste of several servers the sentence
  names the server, and the paste answers no drafts.
- **Import reads another app's settings only when asked.** `mcp.servers.import.scan`
  and `mcp.servers.import` each read the settings files then, and nothing is
  kept between them, so an import adds what the files hold when it runs. The
  sources are fixed files under the home folder: Claude Desktop's
  `claude_desktop_config.json`, Claude Code's `~/.claude.json` (its user
  servers, not a project's), Cursor's `~/.cursor/mcp.json`, VS Code's user
  `mcp.json`, Windsurf's `mcp_config.json` and Codex's `~/.codex/config.toml`,
  each read whole up to 8 MiB, its servers taken out and translated one by
  one as a paste is. VS Code's is read as VS Code reads it, JSON with `//` and
  `/* */` comments and trailing commas; the others as JSON, as their apps read
  them. A missing file holds no servers; one that cannot be
  opened, is too large, does not parse or holds its servers in another shape
  is one `skipped` entry with `name` null, and a server that could not be added
  as it is written (a placeholder in its command, say) is one with its name;
  neither hides the rest. At most 32 servers are read from one file. A
  candidate is named as a draft is, and `conflict` says the name, or its
  tools' names, is taken here. Neither method ever carries a value: an import
  stores what the file held under `mcp:<name>/…` as a paste's values are
  stored, a placeholder declares a name the server waits for, and the other
  app's file is never written. One refused server leaves the others; a
  settings file changed outside Fermix refuses the whole import with
  `external_change` before anything is added.
- **A check connects, then lists once.** `mcp.servers.check.start` waits for a
  server that is starting, starts again one that is not running or has failed,
  then asks it for its tools; `tool_count` is what it listed and `latency_ms`
  how long that took. Its wait for a connection outlasts a first start's own
  60 s, so a server that downloads its package on first run ends the job with
  how that start ended. A server the daemon does not run (off, naming nothing to
  start, or waiting for a value) is refused with its own row's sentence, and a
  connection that fails ends the job with that sentence. After an add or an
  update, `mcp.servers.get` reads the row as it connects.
- **The cue methods are on every build**, and so is the `cues` section of
  `settings.sections`. They are minimum version `2` with no protocol bump, so a
  client finds them in `hello.capabilities.methods`. With memory
  off, `cues.status` says `needs_memory`, the source and mandate lists are drawn
  from the settings file, and the reads that need rows (`cues.watchers.*`,
  `cues.mandates.choices`, `cues.proposals.*`) answer `unavailable` with the
  daemon's sentence. An unknown source, watcher, mandate or proposal is
  `invalid_params` with the field and a sentence ("There is no source named
  home-alerts.").
- **`cues` is the cue section**, under pane `cues`: `cues_enabled` (the cue tree
  starts at boot, so `restart` is true), `cues_mandates_enabled` ("Let watchers
  act", read at every mandate call and every follow-up trigger), `cues_screen` (how items are checked, read at every
  accept and filter call), `cues_decision_provider` (which decision model
  that is, read at every filter call), `filter_provider` and `filter_model` (the Cues
  filter model, the one every watcher's filter uses, read at every filter call)
  and `cues_door_port` (`advanced`, 1024 to 65535, always on 127.0.0.1). The rows
  carry their explanations in `info` and no `footer`; the filter model's says
  a smaller, faster model works well. `filter_provider` offers `""`, the
  default, labelled with the main model it resolves to ("Default: your main
  model (Anthropic · claude-sonnet-5-5)"), then only the providers that are set
  up; a saved provider that is no longer set up stays, disabled with its hint,
  so the value is always an option. `filter_model` offers the chosen provider's
  catalog as suggestions. With neither set, every filter runs on the main
  model. The two are applied together in one `settings.apply`, both or `""`
  for both; either alone is refused with "Pick a provider and a model, or
  clear both." `cues_screen` is how items are checked before the filter model
  reads them, always two options: `keyword` ("Keyword match", the default),
  the watcher's keywords to listen for, and `decision_model` ("Decision
  model"), which checks each item by meaning, with the watcher's purpose,
  instructions and keywords as hints, so only an item it lets through reaches
  the filter model. The option's `hint` names the decision model in use
  ("Uses OpenAI · gpt-6-luna"), or, while the chosen one is not set up, what
  to set up ("Set up OpenRouter first: the screen's decision model runs on its
  key.", also the refusal of that choice). While none is set up, `decision_model` is
  disabled with the hint "Set up OpenRouter, Venice or OpenAI first.", which
  is also the refusal; a saved `decision_model` keeps its value, and its
  watchers are held until one is set up or `keyword` is picked.
  `cues_decision_provider` ("Decision model") is which decision model the
  screen uses, published whatever `cues_screen` is, so a client shows or
  hides it as the screen's choice changes, with no read. Its first option is
  `""`, Automatic: the daemon uses the primary provider's decision model when
  it serves one and is set up, otherwise the first set up of OpenRouter,
  Venice and OpenAI, and the label names it ("Automatic (Uses OpenAI ·
  gpt-6-luna)"); while none is set up it is "Automatic", disabled with the
  hint "Set up OpenRouter, Venice or OpenAI first.". Then always `openrouter`
  ("OpenRouter · Jev"), `venice` ("Venice · Jev") and `openai` ("OpenAI ·
  gpt-6-luna"), each disabled with the hint "Set up this provider first."
  while its provider is not set up with a key that loaded, a saved one
  included, so the value is always an option. A chosen provider that is not
  set up holds the watchers with a sentence naming it, and never falls back to
  Automatic. `cues_screen` and `cues_decision_provider` may go in one
  `settings.apply`: each is checked before either is written, and neither
  check reads the other's saved value, so a refusal of one writes neither.
- **Every cue write goes through the setup page's own path**, so the outside
  edit refusal (`external_change`), the baseline re-record, the secret
  take-back and the source workers' reconcile apply identically from either
  door, and a source or a mandate written here reads back from `config.toml`
  as a hand edit would hold it, with no secret value in it. At most 64 sources
  and 64 mandates are added; past that the add is refused with a sentence.
  A form's refusal is `invalid_params` with `field` (the value's key, or `ref`
  or `name`) and the daemon's sentence; a name that breaks the rule is
  refused under `ref` with the rule in its sentence.
- **A source row is the daemon's.** `state` is `off`, `needs_secret`,
  `not_running` (cues off, or on and not yet restarted), then the status the
  source last wrote: `idle`, `polling`, `connected`, `reconnecting`,
  `auth_failed`, `over_budget`, `stopped` or `unavailable`. A client draws
  `status_sentence` and switches on `primary_action` and `actions` (closed:
  `enable`, `disable`, `set_secret`, `new_token`, `get_url`); edit and remove
  are always available and are the client's controls. `secrets` reports each
  field's presence and nothing else. Never on the wire: a payload, an item's
  text or snapshot, a cursor, a secret's value, or a webhook's address.
- **A source can wait for its secret.** A source that needs a secret (a
  webhook's signing secret, a local push's token, or the `key` and `secret` a
  stream with no preset signs in with, by a header or a placeholder in its
  sign-in message) and has one not stored loads as `needs_secret` with
  `missing_secret` naming the first such field (key before secret), for a
  hand-edited file as much as for a socket write: the door refuses its
  requests and no worker runs until each is stored. So `cues.sources.add`
  saves a webhook or a stream first and the client stores its secrets with
  `secret.set` after, one per secret row, under the `source.ref` the add
  answered; `secrets` lists each field the source needs with its own
  presence. A GitHub source never waits: `cues.sources.add` stores the secret
  Fermix makes for it, and `secret.set` replaces it later.
- **Three values are handed out.** A new local push source's first token
  (`cues.sources.add`) and a fresh one (`cues.sources.token.new`), and the
  secret Fermix makes for a new GitHub source (`cues.sources.add`, as
  strong as a token and stored as a typed secret is), are returned once:
  never logged, never traced, never retained, and no later read repeats them.
  A webhook's address is returned by `cues.sources.url.get` alone, on every
  ask, and is never on a list.
- **A watcher row is read-only**: watchers are made and changed in a chat with
  Fermix, and every `llm` watcher filters with the one Cues filter model.
  `state` is `on`, `paused`, `needs_update` or `held` (its filter cannot reach
  its model; while the screen's decision model cannot run, `status_sentence`
  names it in the words of the hold's notice: "Held: The screen's decision
  model is OpenRouter's, which is not set up: set it up or pick another in the
  Cues settings. 3 items are waiting."). `needs_update` is a watcher saved before a rule every save now
  keeps, which gets nothing until a change in chat: one that filters needs
  keywords to listen for ("Needs keywords to listen for: update it in chat."), and
  one with no filter cannot listen to a stream ("Passes everything, so it
  can't listen to a stream: give it a filter in chat."). `counts` cover
  `window_s`: `offered` is every item the watcher's keywords let through, kept or
  not; a stream keeps only what passes, so its watchers' `offered`, `dropped`
  and `failed` are counted by the hour rather than stored. `purpose`,
  `listen_for` and `instructions` are the owner's own words and are on
  `cues.watchers.get` alone; examples are counted, never shown; reasons and
  hints never cross. A watcher has a task, a follow-up or both. `task` is the
  job a passing item starts: its task, or for a watcher with only a follow-up,
  that follow-up's job (then `follow_up.job_id` names the same job), so `task`
  is never null and a client that predates follow-ups still reads every row.
  `follow_up` is null for one with none, else the job a passing item sets off, which Fermix hands nothing from the
  item: its `job_id`, `name`, `always_allowed` (whether the owner's Always
  allow on one of its cards lets it run with no card for what it runs and
  what sets it off now; false while each run asks first on a card, and false
  again after any change to either), `state` (`ready`, or `held` while it
  cannot run: "Let watchers act" is off, or a tool or the channel it needs is
  not set up) and `status_sentence`, which while it is held says what is
  missing and where to fix it. It is made and changed in chat like the rest;
  only Always allow is granted on a card and taken back here
  (`cues.watchers.always_allow.revoke`) or in chat. A daemon older than
  follow-ups omits `follow_up`, which a client draws as no follow-up; one
  older than Always allow publishes `mode` and `approved` in its place, which
  a client reads as asking first.
- **A mandate row carries its load and its approval.** `load` is `active`, or
  `inactive` with the check's sentence; `approval.state` is `unapproved`,
  `approved`, `changed` or `disabled`, null where memory is off. A client
  switches on `primary_action` (`approve` or null) and `actions` (closed:
  `approve`, `enable`, `disable`); `consent_sentence` says what the mode lets
  the task do. `cues.mandates.approve` records the approval as from "Fermix
  app".
- **A proposal is Fermix's record, and its card keeps the outside text
  apart.** A record carries ids, names from the owner's configuration, times,
  `decided_from` (`telegram`, `signal`, `whatsapp`, `imessage`, `companion`,
  `mobile` or `management`) and Fermix's `status_sentence`, never an argument or
  cue text. `cues.proposals.get` adds `received_at`, `summary` (Fermix's
  sentence) and `outside`: `args_text` (the recorded call's arguments, at most
  3,500 characters) and `cue` (`type`, `subject`, `text`, `occurred_at`) or
  null, all outside text a client draws only as such. `cues.proposals.decide`
  answers by id with no token; the first answer from any surface wins, and a
  later one is refused with the daemon's sentence and runs nothing.
- **A sign-in client appears only where a plugin needs one.** `oauth_clients` is
  derived from the providers the published rows name, so a client row for a
  family this Mac has no plugin for is never drawn. `client_id` is the public
  identifier, or null when unset. `secret_present` reports the stored secret
  independently of `configured`, which requires both identifier and secret.
  These two fields are optional for older protocol-2 engines. The secret value
  is never returned. A null `redirect_port` means the daemon's own default is in
  force, not that no port is used.
- **The region is chosen before connecting, because it selects the token
  audience.** Some providers serve one account region per host and refuse every
  call from another, so the region is part of the sign-in client rather than
  something a first call discovers. `regions` lists the choices with the
  daemon's own labels and is empty for a provider that serves one region;
  `region` is the chosen one, or null while nothing is chosen. Both are optional
  for older protocol-2 engines, and an absent `regions` reads as a provider with
  one region, never as a picker that failed to arrive. A plugin whose provider
  offers regions and whose client has none is `needs_client_config`, the same as
  one missing its identifier.
- **A grant minted for the wrong region is `wrong_region`.** Right after a
  sign-in the daemon asks the provider which region the account is in, and
  records a disagreement on the grant. The status is its own word because the
  fix is the region on the sign-in client, not a renewed sign-in: the row leads
  with `set_up_client` and keeps `sign_in` beside it, and the status sentence
  names the account's own region wherever the provider gave one. No token is
  served for such a grant, so a plugin holding one refuses its tools rather than
  calling the wrong host.
- **Harness detection reports bounded public status.** Only the `harness_vendors`
  target can add `vendors` and `guidance` to its existing `target`, `present` and
  `detail` fields. Both additions are optional for older protocol-2 engines.
  `vendors` contains at most one row each for `claude` and `codex`, with required
  `vendor`, `installed`, `version` and `auth` fields. Version is nullable and at
  most 512 characters; auth is `authenticated`, `unverified` or `absent`,
  read from the agent's sign-in file alone ("Sign-in found" for
  `authenticated`: the vendor is never asked). An optional boolean
  `signed_out` is true while the agent is marked signed out on this computer:
  its last run here ended because the vendor could not sign in, and the mark
  clears on a run of it that works, a change to its sign-in file, or
  `coding_agents.check`; an engine that cannot read its marks leaves the field
  out. Guidance is nullable and at most 512 characters, and names a marked
  agent and how to sign in again. Neither binary paths nor credential values
  are returned.
- **Notetaker detection is both halves plus the sign-in.** The `meetbot` target
  is present only when the notetaker's sidecar and its browser are both
  installed: half an install can neither sign in nor join a meeting. Its
  `detail` is `Signed in to Google` or `Not signed in to Google`, which is the
  one notetaker fact a client cannot read for itself — the marker lives beside a
  browser profile nothing on the wire exposes. With the notetaker absent there
  is nothing to be signed in to, so `detail` is null rather than a
  not-signed-in sentence. No profile path and no credential is returned.
- **`settings.reload` is the one write-family method allowed while an external
  change stands**, because it is the action that clears it. Every other write
  answers `external_change`; a file that cannot be parsed answers
  `config_unreadable` and is never answered with a reload, because the reload
  would re-run the read that just failed.
- A **prepared daemon auto-resumes.** The drain lease is finite: if the app
  crashes or the machine reboots between prepare and commit, the lease expires
  and the daemon keeps serving.
- **`lifecycle.prepare` quiesces nothing.** It takes the single-flight window
  and nothing else: in-flight agent turns and tool runs continue, and new work
  is still accepted. `busy` means another lease is open, never "this daemon has
  work in flight". A client that must not interrupt work has to establish that
  itself before committing.
- **`ttl_ms` is relative, deliberately.** The expiry timer runs on monotonic
  time, which is frozen across sleep and never stepped by NTP, so a wall-clock
  deadline would disagree with it. Clients start their own timer on receipt.
- A **log cursor** is opaque and carries the rotation fingerprint it was minted
  against. After the log set rotates the cursor answers `cursor_expired` rather
  than silently returning a different window.
- **`subsystem`** matches a leading `[tag]` the log message itself wrote; the
  engine's on-disk log format carries no module or subsystem field, so a line
  without such a tag is excluded whenever a subsystem filter is supplied.
- **The home family is answered locally in every role** (M75). `home.status`
  is one fixed record from its first release: the places the desktop relay,
  the desktop peers, enrollment and the move fill are present in every role,
  as `null` or `[]` where they hold nothing, so a client decodes the same keys
  in every role. A candidate answers `home.status` alone of the family. A device
  reports its own role, epoch and marker; its `snapshots` say they are the
  primary's (`configured` false, `recipient_set` false, `next_run_at` null, no
  target, the sentence saying so). A linked desktop adds the primary's own
  picture as `primary_home`, or says in `primary_missing` why it is missing;
  the rest of the family is the primary's there (see *After a move*).
- **A move back runs through the same move** (M75). A desktop's `home.act`
  sends `home.enroll.open` and `home.move.start` to the server; with
  `keep_as_desktop` false the server keeps no desktop key, row or link and
  serves nothing once the move commits.
- **Enrollment and the move are the primary's** (M75). `home.enroll.open`
  opens one window at a time; a host that enrolls with its code becomes a
  candidate the primary holds for 24 hours. A window opened for a computer
  (M97) takes a computer that joins the home instead, which the owner adds
  with `home.enroll.approve` or not with `home.enroll.deny`. `home.move.start` answers before
  the engine restarts, so the same socket then answers from the device role;
  the move runs on its own from there, and `home.status`'s `move` follows it:
  `requested`, `streaming`, `committing`, `committed` (restarting as a
  desktop) and `done`, or `aborting`, `undoing` (restarting as the primary)
  and `aborted` when it was undone before the candidate was ready, which
  leaves this home the primary. `done` and `aborted` are written only by the
  engine that came back after the restart, so a client that reads either
  reads it from the engine that stays, with a desktop's `primary` already
  beside it; `committed` and `undoing` mean the engine is about to restart.
  An engine that came back but could not write its ending keeps answering
  `committed` or `undoing`, with a `sentence` that says the ending and why it
  is not recorded; each read tries the write again, and the ending follows
  once it is written.
  A move session has no one-hour lifetime, and its attempts send one capture. On a candidate, `phase` is `enrolling`, `enrolled`,
  `receiving`, `staged`, `activating`, `expired` or `failed`, and `candidate`
  is null.
- **A snapshot target row is the daemon's.** On an Always On server's
  primary (its home holds a desktop row a move wrote, and the host is not
  macOS) there are two targets, in order: `s3` (label `S3`) and `desktop`
  (label `your desktop`: every desktop connected to this primary over the
  rail, on while it has a desktop row). Any other primary has none:
  `targets` is `[]`, `configured` false, and `sentence` says
  `Snapshots are kept only by an Always On server, and this computer is not one.`,
  whatever its settings name; `home.snapshots.run` is refused with that
  sentence.
  `last_verified` is the newest snapshot the target proved it holds (S3
  accepted its SHA-256 checksum; a desktop answered the same SHA-256) and
  outlives later failures; `last_error` is the newest failure's sentence,
  carrying the storage service's own words, and clears only at the next
  verified run. A desktop asleep or offline is no failure: `last_result` is
  `waiting` and `waiting` holds the sentence
  (`Your <name> is not connected; the snapshot waits for the next run.`),
  null otherwise; such a run stored nothing, so while a failure stands it is
  not recorded over it, and `last_attempt_at`, `last_result` and
  `last_error` stay the failed try's (Always On's `backup_failed` says them). Each point names the recovery key it was written for
  (`key_id`, as `home.snapshots.passphrase` answers it). The first boot of a
  primary a move activated runs its first snapshot at once. `destination` is where the target puts
  snapshots (`s3://<bucket>/<prefix>/<profile>/`, or `snapshots/ on <names>`
  for the desktops), null while it is off.
- **`snapshots` is Backup settings**, under pane `always_on`, with one row:
  `snapshots_interval_hours` ("Back up every", 1 to 168, format `hours`).
  Only an Always On server's primary lists it and takes its `settings.get`
  and `settings.apply` (a home a move moved there, never a Mac); a Mac that
  never moved, or any home that never moved, keeps no S3 backup and has no
  `snapshots` section (`settings.get` and `settings.apply` answer
  `invalid_params` on `section` there). A linked desktop lists the server's own, since it is no section
  of this machine. Whether the recovery passphrase is set is the summary's
  `detail.backup`, and the passphrase changes only through
  `home.snapshots.passphrase` (`home.act` `change_passphrase`); the recovery
  key is never shown. No app sets any part of S3: an Always On server's bucket
  comes from its infrastructure through first boot, and another S3 service is
  set on the server itself (`config.toml`, its keys through `secret.set`,
  which still takes `snapshot_s3_access_key_id` and
  `snapshot_s3_secret_access_key` though no row shows them). The row needs no
  restart: the scheduler reads the section at every run and plans again when
  it is saved.
- **`computer_history` is this computer's part of computer history** (M97),
  answered on this computer (*After a move*): `computer_history_enabled`
  (whether it records), `computer_history_apps` (which apps), both in
  `[fermix_core.computer_history]` of this computer's `machine.toml`, and
  `computer_history_summarizer` (read-only), what this computer's own
  sittings are summarized with: `local` where its `machine.toml` says
  `summarizer = "local"` (it makes its own notes, and where it is the home,
  its roll-up stays on it too), else the home's route (`default_provider`,
  `local`, or a pinned provider's id). Where `machine.toml`'s local
  summarizer decides over a different one in this home's `config.toml`, the
  row's footer says so; otherwise it has none. Deleting that line from
  `machine.toml` hands the choice back to `config.toml`. The home's route and
  the providers that may receive summaries (`summarizer`, `remote_summaries`
  in the home's `config.toml`) have no row, so no write here reaches them. The switch's
  footer says what switching history on agrees to, true on this computer:
  with no server, that the raw record stays here for 48 hours and each
  finished sitting is summarized by the provider it names (or on this Mac);
  where this computer's history goes to its server (a computer linked to it,
  or the server itself, where Always On is offered), that each sitting is
  sent there (or only its summary, where this computer makes its own notes)
  and summaries from every computer can be recalled in chat.
- **`computer` is a linked computer's own section** (M97), under pane
  `always_on`, titled `This computer`: what Fermix on the server may use on
  this computer, `[fermix_core.computer]` in this computer's `machine.toml`,
  which travels with no move, backup or restore. Only a computer linked to
  its server, where Always On is offered, publishes it; the server never
  does, and refuses a forwarded `settings.get` or `settings.apply` for it
  with `device_class_method` (*After a move*), so it can never widen it.
  Its rows (M97 D27), every one a toggle with `restart` false:
  `computer_enabled` ("Fermix on your server may use this computer", off
  stops everything the server does here from its next request; while a
  computer that moved before M97 waits for the owner's review, its footer
  says so), `computer_files_and_shell` ("Files and commands": the `files` and
  `shell` offers together, in this computer's sandbox mode),
  `computer_browser` ("The browser"), `computer_computer_use` ("Your screen")
  and, on a Mac only, `computer_imessage` ("Messages"), each off until
  switched on: five rows on a Mac, four on Linux. Nothing else is a row: the
  review is the computer's own state, computer history's consent is its
  recorder (the `computer_history` section), and what reaches the server from
  the computer has no switch. A key that is no row, `computer_reviewed` and
  an earlier engine's `computer_files`, `computer_shell`, `computer_history`,
  `computer_voice`, `computer_attachments`, `computer_accessory` and
  `computer_notifications` among them, is `invalid_params` on that key. Any
  write is the owner's review: it leaves the switches reviewed. Every switch
  is live: the next request reads it, and the computer sends its offers to
  its server again at once.

## Accessories

`accessories.*` manages a Fermix accessory (M91: a StackChan robot) wired to
this Mac over USB. The daemon owns the port, the pairing records and the
robot's calls (`priv/accessory/PROTOCOL.md`); the app sends requests and draws
what the daemon answers, and keeps no state of its own but unsaved form input.
Every sentence and every action a row offers is the daemon's; the app renders
them as they are and keeps no compatibility table, no readiness rule and no
copy of its own.

**Where it answers.** Every method is device-class (*After a move*): the
engine that receives it answers it. Accessories run only on a local Mac
primary, so on a device-role or candidate engine, or off macOS,
`accessories.status` answers `state` `needs_local_primary` and every other
method `unavailable` {`capability`: `accessories`, `sentence`: "StackChan setup
needs a local Mac primary."}. With accessories off, the status answers `off`
and the other methods `unavailable` with "StackChan is off."; Forget and Revoke
still erase a record then.

**The switch.** `[fermix_channels.accessories] enabled` is the `accessories`
settings section's one row, `accessories_enabled` (pane `voice`, a Mac only).
It is live: `settings.apply` starts or stops the accessory link at once
(turning it off ends a robot call and closes the port), and a link that did not
follow says so in `side_effects`. It never needs a restart.

### The status

`accessories.status` and every other method's success answer the same object:

| Field | Shape |
|---|---|
| `key` | 16 hex digits: changes when anything below changes. A client waits with `{after: key, wait_ms}` (at most 25,000) and is answered at the first change or when the wait ran out. A waiting read wakes at once at each change of the ports, links and calls the accessory link owns, so a call's state, captions and tasks arrive as they happen, and reads again every 2 s for what no process announces (the home's call lease, voice readiness, the switch, the pairing store), so no change waits out the wait. |
| `state` | `off`, `needs_local_primary`, `not_running` (on, but the link has not started this boot) or `on`. |
| `sentence` | The daemon's one line for the whole picture. |
| `enabled` | The switch. |
| `kinds` | `[{kind, name, wire_min, wire_max, install_guide}]`: each kind this engine pairs and its pinned metadata. `stackchan`: name `StackChan`, wire `1`–`1`, the guide `https://github.com/tezra-io/fermix-stackchan/blob/main/INSTALL.md`. Compatible firmware is firmware that speaks a wire version in the range. |
| `voice` | `{ready, code, sentence, engine, engine_label, model, voice}`: whether a call can start now (`code` null, `voice_disabled`, `missing_key` or `restart_required`), and the configured voice a next call takes. |
| `voice_device` | `{device, accessory_id, changeable, sentence}`: `device` is `desktop`, `accessory:<accessory_id>`, or `unreadable` when the choice cannot be read (`accessory_id` null; every call, the Mac's own and a robot's tap, is refused until the owner chooses again with `accessories.voice_device.set`, which stays allowed). A client routes a call on `device` and opens this Mac's microphone only for `desktop`: an app that does not know `unreadable`, or any later value, decodes it as unrecognized and routes no call to this Mac for it. `changeable` is false while a call runs or settles anywhere in this home. `sentence` says why the device needs the owner: the call that keeps it ("The voice device can change once the call has finished."), a choice that cannot be read ("The voice device could not be read. Choose one in Pet."), or a robot still chosen while accessories are off ("StackChan is off but is still your voice device. Choose This Mac in Pet to talk here.", also the status's `sentence`); null otherwise. The choice never changes by itself. |
| `ports` | Every Espressif USB serial port the daemon sees, by `path` (at most 16 that went away are kept): `{path, serial, status, selected, accessory_id, kind, firmware, update, install_guide, retrying, sentence, actions}`. |
| `ports_sentence` | While accessories are on and no port is seen: "Plug your StackChan into this Mac with its USB-C cable."; null otherwise. |
| `accessories` | Every paired robot, oldest first, at most 8: `{accessory_id, short_id, name, kind, enrolled_at, connection, path, gen, firmware, capabilities, state, calibration_sentence, fault, diag, check, selected, sentence, actions, last_call}`. |
| `pairing` | The attempt on the selected port, or null: `{path, attempt, round, max_rounds, phase, code, accessory_confirmed, owner_confirmed, closed_reason, accessory_id, expires_at, sentence}`. |
| `call` | The robot call that runs, or null (a desktop or phone call is not here): `{accessory_id, call_id, source, phase, phase_sentence, state, muted, muted_by, engine, engine_label, model, voice, call_uuid, conversation, started_at, transcript, tasks, usage}`. |

A **port**'s `status`, its `sentence` and the `actions` it offers:

| `status` | `sentence` | `actions` |
|---|---|---|
| `unrelated` | "A USB serial device is plugged in." | `pair` |
| `attaching` | "Checking the USB device." | none |
| `unpaired` | "StackChan found. Fermix firmware is compatible." (the selected port, an unpaired robot that answered) | `pair_begin`, `pair_cancel` |
| `pairing` | the attempt's sentence (below) | `pair_cancel` |
| `attached` | "Connected by USB." | `release` |
| `busy` | "Another app is using StackChan's USB port. Close it and try again." | `retry` |
| `needs_firmware` | "This USB device isn't running Fermix firmware. If it's your StackChan, install the firmware first." | `open_install_guide`, `retry` |
| `incompatible` | `update` `firmware`: "Update the robot firmware." `update` `fermix`: "Update Fermix: this robot's firmware is newer than this Fermix." | `open_install_guide` or `update_fermix`, then `release` |
| `not_paired` | "This robot isn't paired with this Mac." (a robot whose proof failed, or one that forgot its pairing); a robot that refused this Mac as another host (`unknown_host`), which ignores a pairing request until it forgets that Mac: "This StackChan is paired with another Mac. To pair it here, hold the right edge of its screen for 3 seconds, tap Forget, then choose Pair." | `pair` |
| `released` | "Install the firmware update now, then choose Reconnect." | `reconnect` |
| `vanished` | "The USB device was unplugged." | none |
| `failed` | "The USB connection failed. Try again." | `retry` |

`selected` is the port chosen for pairing. `retrying` is true while a busy
port is opened again on its own (five opens, 1, 2, 4, 8 and 15 s apart; after
them only Retry opens it). `install_guide` is the kind's guide on a row that
offers `open_install_guide`, null otherwise. `accessory_id` is the robot
attached on it, `kind` and `firmware` what it reported, and `update` (`firmware`
or `fermix`) which side to update on an `incompatible` port. The daemon opens
only the selected port and ports whose USB serial a paired robot's record
names, so `unrelated` is any other Espressif board as much as a robot: the app
does not call it a StackChan.

An **accessory**'s `connection` and `sentence` (the robot's own fault or power
sentence comes first while attached):

| `connection` | `sentence` |
|---|---|
| `attached` | "Connected by USB. Firmware compatible." |
| `attaching` | "Connecting to StackChan." |
| `unplugged` | "Plug StackChan into this Mac." |
| `released` | "Install the firmware update now, then choose Reconnect." |
| `busy` | the port's |
| `not_paired` | the port's `not_paired` sentence |
| `incompatible` | the port's |
| `failed` | "StackChan's USB connection failed. Try again." |
| `off` | the status's |

While attached: `fault` set, "StackChan reports a problem: `<fault>`. Check its
screen."; `state.power` `low` or `critical`, "StackChan needs more power. Plug
it into one of this Mac's USB-C ports, not a hub."

`actions` come from `start_call` (attached, voice ready, power not low, no
call anywhere), `select` (not the voice device, no call), `check` and
`calibrate` (attached, no call; `calibrate` only with `motion`), `release`
(attached, no call), `reconnect`, `retry`, `pair`, `open_install_guide`,
`update_fermix`, and `forget` and `revoke`, which every paired robot on a
local Mac primary offers. `short_id` is the ID as a person reads it (16 hex digits in four groups
of four). `gen` is the connection generation of an attached robot, null
otherwise. `capabilities` are the ones in use on the link (`mic`, `speaker`,
`screen`, `touch`, `pet`, `motion`, `battery`); the app offers a kind's
controls only for these. `state` is the robot's own report, or null before one
arrives: `{battery, power, brownout, volume, brightness, motion,
calibration}`, `battery` null when the robot has no reading (never zero, never a
factory placeholder), `motion` `absent`, `off`, `homing`, `ready`, `paused` or
`fault`, and `calibration` `absent`, `missing`, `valid`, `calibrating` or
`failed`; Head movements stays off until `calibration` is `valid`.
`calibration_sentence` is the daemon's sentence for `calibration`, null for
`absent` or with no `state`: `missing` "Head movement is off until the robot is
calibrated.", `valid` "The head is calibrated.", `calibrating` "Calibrating the
head: nudge each axis to its center, then set zero.", `failed` "The head
calibration did not finish, so head movement stays off until a calibration
succeeds." `diag` is the robot's own counters, since its boot, as it last
reported them (`diag.counters`, every 10 s and at a call's end) on this attach,
or null before a report and on a robot not attached: `{uptime_s, frames_rx,
frames_tx, crc_errors, resync_bytes, pcm_seq_gaps, mic_overflows,
spk_underflows}`, each an integer from 0 to 4,294,967,295; read-only, for
diagnosis. `check` is
the newest setup check, or null: `{check, status, code, level}`, `status`
`running`, `ok` or `fault`, `level` the microphone's newest RMS level (0 to
32,767) during `mic`. `selected` is whether it is the voice device.
`last_call` is how its newest call ended, or null: `{call_id, reason, sentence,
ended_at}`. A reason the daemon has no sentence for reads "The call ended.",
and `reason` keeps the token:

| `reason` | `sentence` |
|---|---|
| `unplugged` | "StackChan was unplugged, so the call ended." |
| `link_lost` | "StackChan's connection was lost, so the call ended." |
| `forgotten` | "The robot was forgotten, so its call ended." |
| `call_in_progress` | "Another voice call is in progress." |
| `not_selected` | "StackChan is not your voice device. Choose it in Pet to call from the robot." |
| `power_too_low` | the power sentence |
| `voice_disabled`, `missing_key`, `restart_required` | the voice sentence |
| `call_failed` | "The call could not start. See the daemon log." |

The **pairing** attempt: `phase` `begun` (the robot asks "Pair with this
Mac?"), `offered`, `revealed` (both screens show `code`, six digits), `committing`,
`done` or `closed` (`closed_reason` `owner`, `expired`, `mismatch_limit`,
`invalid_offer`, `invalid_reveal` or `link_reset`). `code` is null before
`revealed`. `round` counts from 1 to `max_rounds` (3). `accessory_id` is the
robot the attempt paired once it is `done`, null before. `expires_at` is when the
attempt's two minutes run out, until the robot is committing. Its sentences:
`begun` "Tap Pair with this Mac on your robot.", `offered` and `revealed`
"Check the code on your robot. It should match the code shown here.",
`committing` "Pairing your robot. Keep it plugged in.", `done` "Your robot is
paired.", and closed: `owner` "Pairing was cancelled.", `expired` "Pairing took
longer than two minutes. Start again.", `mismatch_limit` "The codes did not
match three times. Start pairing again.", `invalid_offer` and `invalid_reveal`
"The robot's pairing answer did not check out, so nothing was paired.",
`link_reset` "The robot's connection reset during pairing. Start again." A
code match alone pairs nothing: the robot's own confirmation, which proves it
holds the key it offered, and the owner's `matches: true`, in either order,
commit it. The first pairing burns one of the robot's eFuse key blocks, which
the robot says on its own screen before the owner confirms.

The **call**: `call_id` is the call's session id, which the call controls
name. `source` `screen_tap`, `head_swipe` or `mac`. `phase` `starting` (not yet
admitted), `active` or `ending` (settling: the voice device cannot change).
`state` the voice state (`connecting`, `listening`, `thinking`, `speaking`,
`muted`, `reconnecting`) or null before the first. `phase_sentence` is "The call
is starting." while `starting`, "The call is ending." while `ending`, and null
while `active`, where `state` says what the call is doing. `muted` with `muted_by`
`mac` or `accessory`. `engine`, `engine_label`, `model` and `voice` are the
ones the call started with, which a voice setting saved during the call does
not change; the app labels the call with them, never with `voice`'s.
`call_uuid` and `conversation` (`chat` or `private`) once the call is ready,
null before and on an engine without them. `started_at` is when the call was
admitted, null while `starting`. `transcript` is the call's newest lines,
oldest first, at most 6: `{speaker, text, final}`, `speaker` `user` or
`assistant`, `text` at most 400 characters (a longer line keeps its end),
`final` once the line is whole; nothing of it is persisted by this method.
`tasks` are the call's newest tasks, at most 8, in the order they started:
`{task, revision, status, summary, in_chat, cancellable}`, `status`
`running`, `completed`, `failed` or `cancelled`, `summary` at most 240
characters or null, `in_chat` true when the result was written to the chat,
`cancellable` true for a Live or Grok task still running. `usage` is null or
`{cost_cents, voice_seconds, accounting}`, each null when the engine did not
say; unknown is never zero. The app observes the call through this method and
opens no microphone or speaker of the Mac; a robot call also runs, and its
controls work on the robot, with the app closed.

**Refusals.** Every refusal carries `details.sentence`:

- `invalid_params` on `volume` for an `accessories.set` with no setting
  ("Send at least one of volume, brightness or motion."), on `path` ("No USB
  device is plugged in at that port.",
  "That port is released for a firmware update. Choose Reconnect first.",
  "Pairing has not been started on that port."), on `accessory_id` ("No paired
  robot has that id.", "That robot is not connected."), on `device` ("No paired
  robot has that id."), on `task` ("That task cannot be cancelled."), and on
  any other field with the field alone;
- `unavailable` {`capability`: `accessories`} with the status's sentence when
  accessories are off, need a local Mac primary or have not started; with
  "Only the owner can set up or control StackChan: use the Fermix app or your
  own terminal." for an owner decision another caller asked for (every method
  of the family but `accessories.status`: a process the daemon started never
  pairs, calls, sounds, moves or frees the robot, nor ends or mutes the
  owner's call); with
  "The voice device can change once the call has finished." while a call runs;
  with "End the call first." for a check, calibration, setting or release
  during one; with "StackChan cannot do that." for a check or setting the
  robot did not report the capability of; with "Pairing is already open on
  this port." and "StackChan is already paired."; and, for `call.start`, with
  `code` and the refusal's sentence (*Accessories*, `last_call`);
- `changed` when an `attempt` or `call_id` is not the current one, with "That
  pairing attempt has ended, so look at it again." or "That call has ended, so
  look at it again."

**Bounds.** At most 8 paired robots, 16 vanished ports, 6 transcript lines of
400 characters and 8 tasks of 240-character summaries; a status wait of
25,000 ms. Every method but a status wait answers inside the standard call
timeout.

## Error codes

| `code` | Meaning |
|---|---|
| `invalid_request` | The envelope is malformed. `details.field` names the offending field. |
| `invalid_params` | The parameters are malformed, unknown, or oversized for this method. `details.field` names the offending field. `details.sentence`, when present, is the daemon's own refusal sentence for it. |
| `method_not_found` | The method is not in this daemon's catalog. |
| `client_too_old` | The declared version is below the daemon's floor. |
| `daemon_too_old` | The declared version is above the daemon's ceiling. |
| `internal_error` | The daemon failed to complete the request. Details are always empty. |
| `unavailable` | The named capability could not answer. `details.capability` names it. `details.sentence`, when present, is the daemon's own sentence for this refusal. `details.confirm` true marks a refusal that is a question: the same request with `confirmed: true` is the act (`mobile.devices.revoke` of the one computer that keeps the backups, `computer.disconnect` when the server cannot be told), so a surface asks the owner with the sentence instead of showing an error; absent otherwise, and from an engine before it, where a client keeps its own reading. |
| `busy` | Another operation of this kind is already running. |
| `lease_expired` | The lifecycle lease's window elapsed and the daemon resumed. |
| `unknown_lease` | The lease was never issued by this daemon, or was already consumed. |
| `unknown_session` | The Doctor session is not retained by this daemon. |
| `unknown_job` | The job is not retained by this daemon. `details.job_id` names it. |
| `cursor_expired` | The log cursor predates a rotation and cannot be resumed. |
| `secret_store_failed` | The OS keyring refused the write. `details.reason` is `unavailable`, `locked` or `timeout`. |
| `external_change` | The settings file was changed outside Fermix. `details.section` names the section the refused write targeted; `settings.reload` clears the state. |
| `config_unreadable` | The settings file could not be read or parsed. `details.sentence` is the parser's own message, and no reload is offered for it. |
| `unknown_pairing_session` | The pairing session is not retained by this daemon. `details.session_id` names it. |
| `primary_unreachable` | After a move, the primary this computer forwards to cannot be reached, or did not answer in time. `details.sentence` says so, and `details.primary` names it when it is known (see *After a move*). |
| `device_class_method` | The primary refused a request that configures the computer that forwarded it. `details.method` names it and `details.sentence` says why. |
| `unconfirmed` | After a move, the primary had a forwarded request whose effect may stand though its answer did not arrive (`home.move.start`). `details.method` names it, `details.primary` names the primary when known, and `details.sentence` says where its outcome shows (see *After a move*). Not a failure: read `home.status`. |
| `changed` | `home.act` was drawn from a summary that no longer offers the action under its key, or an `accessories.*` request named a pairing attempt or a call that is no longer the current one, so nothing was done. `details` holds `sentence` alone, which says so; the surface reads `home.status` again and the owner presses again from there (see *The Always On summary*). |

`lease_expired` and `unknown_lease` are deliberately distinct: the first lets
the app tell the operator the transaction timed out, the second says the id was
never valid here. The elapsed memory is bounded, so an ancient id honestly
degrades to `unknown_lease`.

### Where the refusal sentence lives

`message` is a fixed per-code string and never varies with the request; it names
the CLASS of failure. The daemon's own sentence about THIS request, when it has
one, is `details.sentence`. Six codes carry one:

- `invalid_params` — every request-path refusal that has something to say to the
  operator. `details.field` names the parameter and `details.sentence` says why:
  "This provider has no browser sign-in.", "This setting cannot be cleared.",
  "A secret cannot be empty.", "Install this plugin before using it.", "Add this
  provider's sign-in client secret first.", "This setting is a switch: send true
  or false.", "No phone is waiting for a decision.", "No paired phone has that
  id.", and every settings validation refusal. A refusal with nothing to
  add carries `field` alone.
- `config_unreadable` — `details.sentence` is the parser's own message.
- `unavailable` — when a caller that is not the owner asks for an owner's
  decision: the phone's, "Only the owner can pair or forget a phone; run this
  from your own terminal.", the accessories', "Only the owner can set up or
  control StackChan: use the Fermix app or your own terminal.", the cues', "Only the owner can change cues: use
  the Fermix app or your own terminal.", the home's, "Only the owner can
  move Fermix or set its recovery passphrase: use the Fermix app or your own
  terminal.", and this computer's switches', "Only the person at this
  computer can change what Fermix on your server may use on it: use the
  Fermix app or the setup page." And when the cues cannot reach their records, with the cues'
  sentence for why: memory is off, or the records could not be read.
- `primary_unreachable` — "The server <name> is unreachable. Fermix keeps your
  message until it is back.", or why this computer does not reach it.
- `device_class_method` — "This request configures the computer it came
  from, so the server does not answer it."
- `unconfirmed` — "The server <name> did not confirm in time whether the move
  started. Its state shows once the server answers again, and starting it
  again never starts a second move."

**A client that renders `message` alone renders "Request parameters are
invalid." for that whole family**, which is the one sentence in the catalog that
tells an operator nothing. Render `details.sentence` when it is present and
`message` otherwise. Both are plain text, bounded, and safe to show: no
credential, no path, no internal term reaches either.

## Bounds

Every bound is published in the schema's `x-limits` and pinned to
`FermixCore.Management.Protocol.limits/0`.

| Bound | Value | Applies to |
|---|---|---|
| `max_frame_bytes` | `4194304` | One transport frame, request or response. |
| `max_params_bytes` | `65536` | The encoded `params` object. |
| `max_result_bytes` | `1048576` | The encoded `result` object. |
| `max_error_details_bytes` | `4096` | The encoded `error.details` object. |
| `max_json_depth` | `6` | Nesting depth of `params`, `result`, and `error.details`. |
| `max_json_collection_items` | `500` | Items in any one array or keys in any one object. |

Operation-specific bounds, owned by the operation rather than the envelope: a
`logs.query` page defaults to 200 entries and is capped at 500 entries and
262144 encoded bytes, with a 256-character search and a 64-character subsystem;
a `diagnostics.build` object carries at most 500 log entries; `mobile.devices.list`
carries at most 64 devices, each string a phone sends in a pairing request is
at most 128 bytes, and a pairing `uri` is at most 2048 bytes; `accessories.status`
carries at most 8 paired robots and 16 vanished ports (*Accessories*).

## Vendoring into `fermix-macos`

The macOS repository must not hand-copy these shapes. It vendors
`protocol.schema.json` and `fixtures/*.jsonl` with a checksum pin and runs its
own client tests against the same golden frames the daemon is tested against.

- `fixtures/requests.jsonl` — one well-formed v1 request per method, plus
  parameter variants. Each record declares the classification the daemon owes
  it.
- `fixtures/success.jsonl` — one full success envelope per method, for
  `settings.get` one per section (`computer` as a linked computer answers
  it), because a section with no golden result is a
  pane whose row keys nothing on the far side is held to, for
  `settings.sections` also a linked computer's composed inventory
  (`settings_sections_computer`), for
  `mobile.pair.get` one per session state, for `job.get` a browser download
  both completed and failed, for `computer_use.permissions.get` a Mac
  answer and a Linux one, for `home.status` one per family of the Always On
  summary's states and four of M97's (a server listing its two computers,
  `home_status_server_computers`; a linked Mac waiting for the review of
  what its server may use, `home_status_on_review`; `ready` with what the
  Mac keeps on for its server after the move, `home_status_ready_keeps_on`;
  and the linked Mac of `home_status_on` while its server controls its
  screen, with the mark's `screen`, `home_status_on_screen`, where every
  other golden has no `screen`, which a client reads as null),
  for `accessories.status` one per family of the setup and
  call states (off, needs a local Mac primary, a port with no Fermix answer,
  incompatible firmware, pairing with its code, a pairing just done, a paired
  robot in a call, that call settling, StackChan off with the robot still
  chosen, and a voice device choice that cannot be read), and for `home.act` a cancelled code, `own_server`'s
  answer (`home_act_own_server`: the code, its command and the Tailscale
  step), Add a computer's code (`home_act_add_computer`) and the computer
  added with its digits (`home_act_approve_computer`). A computer joining:
  the server while one asks (`home_status_server_asking`), once it was added
  (`home_status_server_joined`, with its notice), and the joining computer's
  own picture (`home_status_joining`).
- `fixtures/errors.jsonl` — one full error envelope per published code,
  including the fixed `message` text. `method_not_found` appears twice: once
  for a method this daemon does not serve at all, and once as
  `method_requires_newer_engine`, which carries `details.requires`.
- `fixtures/compatibility.jsonl` — the v0 window and the negotiation matrix: v0
  requests, partial-marker rejects that must never fall through to v0, both
  `client_too_old` and `daemon_too_old`, an N-1 client calling a v2 method
  (`expect: refused_by_router`, answered by the router with `method_not_found`
  and `requires`, once for a settings method, once for the plugin surface, once
  for the phone pairing surface, once for the browser download, and once each
  for the cue, home and computer surfaces),
  and golden responses (`expect: response`) showing optional fields absent at
  once (a plugin row, a sign-in client row, and a probed
  `computer_use.permissions.get` answer from before `platform`), which is the
  rendering a client owes a daemon that knows less than it does.

Re-vendor whenever `protocol_version` changes, a method or error code is added,
or a bound moves. The daemon ships first; see *Rollout / rollback order*.
