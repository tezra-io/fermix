# Companion chat socket

The companion chat socket is the Mac app's chat: a local, owner-only channel
named `companion` that a native companion on the same Mac speaks to the
running daemon. Fermix is the source of truth for its versioned wire contract
(exported with the engine under `priv/companion/`); the app vendors it.

**Availability: no released Fermix.app has the chat window yet.** The socket is
the daemon half, which ships first so the app can be built against a fixed
wire. An owner asking to chat with Fermix from the Mac app should hear exactly
that, and be pointed at the channels that work today; never walk them to a
chat window that is not there.

## The socket and its trust

`$FERMIX_HOME/companion.sock` (default `~/.fermix/companion.sock`), mode `0600`,
owned by the daemon's user. It is served whenever the daemon runs: there is no
setting, feature flag, setup step or pairing, and nothing to turn on. A socket
the daemon cannot bind (most often a `FERMIX_HOME` long enough to push the path
past the OS limit for a unix socket address) is skipped for that boot with one
line in the daemon log, and the rest of the daemon keeps running.

Only the daemon's own user can open a `0600` socket, so a client is the owner:
its turns run as the operator under the normal sandbox, and slash commands are
served (`/new`, `/stop`, `/compact` and the rest). A tool that needs the owner's
approval shows up as an approve/deny card answered with the same `/confirm` and
`/deny` routes as on the other chats. At most four clients connect at once; a
fifth is refused and told why.

## Conversation and timeline

The chat is its own conversation to the agent: `/new` there starts a fresh
session there and nowhere else, and it never clears what the app shows. What
the app shows is the profile's **timeline**, the durable, numbered record of
every message, and that timeline is the one the phone's mobile channel reads
and writes when it is enabled: rows, their `server_seq` numbering and the read
frontier are shared, whoever writes.

Messages are delivered at least once: each carries a client message id the
daemon claims durably before it acknowledges, so a resend after a dropped
connection is recognized and never runs the turn twice. A request the daemon
accepted but could not finish because it stopped runs again when it next
starts. Claims are kept for 24 hours.

## Streaming, cancel and stop

A reply streams live as it is generated, with tool activity alongside it. Each
reply part becomes one timeline row only when the turn completes; a cancelled
or failed turn ends with an error and keeps nothing of its draft, and a turn
the daemon lost to a restart of its queue ends as interrupted. An offline
client later sees the user's message with no answer after it.

Cancel names **one request by its client message id** and stops that turn
whether it is already running or still waiting behind another turn; it never
touches any other turn, and a turn that had already finished when the cancel
arrived ends normally with its answer. `/stop` is still the stop-everything
command: every active turn and every queued message, each settled as cancelled
so it is not run again at the next boot.

## History and search

Every row is announced live to the connected clients the moment it is written,
whoever writes it: the sender's own message, a slash command's answer, a job's
delivery, a message or reply from the phone. History pages both ways from a
cursor: forward from the last row a client showed (the catch-up read after a
reconnect) and backward from any row (scrolling up), up to 200 rows a page. Full-text search covers the whole timeline, newest first, with a
plain-text excerpt around each match and the matched ranges; every word of the
query must match, each as a word prefix, and results page backward the same
way.

## Scheduled delivery

`schedule_job` with `delivery_mode: "origin"` from this chat delivers each
run's result back into the companion timeline. The row is written whether or
not the app is connected at that moment, announced live to any client that is,
and caught up by the history read when the app next connects. From another
chat, the explicit form is `delivery_mode: "channel"` with
`delivery_target: {platform: "companion", chat_id: "main"}`. A final response
of exactly `[SILENT]` delivers nothing, as everywhere.

## What this socket does not carry

Attachments do not travel on it yet: a message carrying attachments is refused,
and a file or image sent into this chat (`send_attachment`, an image delivery)
is refused rather than written as a row the app could never fetch, so answer in
text there. Voice is the realtime socket's, not this one's.

## Observability

Turns keep the standard `main-*` trace session and group in Opik under the
`companion:main` thread. Each accepted request counts one inbound
`channel_msg` and each written reply row one outbound, with channel
`companion`; a resent duplicate counts nothing.
