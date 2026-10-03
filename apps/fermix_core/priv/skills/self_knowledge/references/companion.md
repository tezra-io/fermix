# Companion chat socket

The Mac app's chat: a local, owner-only channel named `companion` that the app on the same Mac speaks to the running daemon. Fermix owns its versioned wire contract; the app vendors it.

**Availability: no released Fermix.app has the chat window yet.** The socket is the daemon half, shipped first. Tell an owner who wants to chat from the Mac app exactly that, point them at the channels that work today, and never walk them to a chat window that is not there.

## The socket and its trust

- `$FERMIX_HOME/companion.sock` (default `~/.fermix/companion.sock`), mode `0600`, owned by the daemon's user. Served whenever the daemon runs: no setting, flag, setup step or pairing. A socket the daemon cannot bind (usually a `FERMIX_HOME` path too long for a unix socket) is skipped for that boot with one log line.
- Only the daemon's user can open a `0600` socket, so a client is the owner: turns run as the operator under the normal sandbox, and slash commands work (`/new`, `/stop`, `/compact` and the rest). A turn from a process Fermix itself started, or from a detached one with no terminal, runs unattended (no desktop control, event changes or recent activity), and a connection whose process cannot be identified is refused.
- An approval (a directory grant, an access-sensitive plugin command after outside content) arrives as an approve/deny card answered through the same `/confirm` and `/deny` routes as other chats; Fermix runs exactly that command once approved. A card belongs to the chat whose turn raised it (a phone's card never shows here, and this chat's never shows on a phone). A card still waiting is sent again when the app reconnects, with the time it has left, and withdrawn as expired when that runs out; one answered or expired while the app was away is not sent again.
- At most four clients connect at once; a fifth is refused and told why.

## Conversation and timeline

- The chat is its own agent conversation: `/new` there starts a fresh session there only and never clears what the app shows.
- A GPT-Live voice call joins that conversation unless it is private (`[fermix_core.realtime] conversation`): each task asked aloud runs in it, reads what was typed before it, and is in the history the next typed message reads (marked as spoken and never memory-reviewed). They share one turn queue, so a typed message waits for a running voice task and the reverse; cancelling one stops only that one. Voice tasks are history only: they are not timeline rows, so the app and the phone do not show them.
- What the app shows is the profile's **timeline**, the numbered record of every message, shared with the phone's mobile channel when enabled: rows, `server_seq` numbering and the read frontier, whoever writes.
- Delivery is at least once: each message carries a client message id the daemon claims durably before acknowledging, so a resend after a dropped connection never runs the turn twice (claims kept 24 hours). A request accepted but unfinished when the daemon stopped runs again when it next starts.
- A slash command settles its request with its answer: one answered at once (`/help`, `/new`) never runs again at the next start, one that becomes a turn (`/ultra`) is settled by that turn, and one that answers later (`/background`, `/skills review`, `/skills approve`) posts its result to this chat when done.

## Streaming, cancel and stop

- A reply streams live with tool activity (a tool's detail and a turn's error text are cut to 512 bytes). Each reply part becomes a timeline row only when the turn completes; a cancelled or failed turn ends with an error and keeps nothing of its draft, and a turn lost to a restart of the daemon's queue ends as interrupted. An offline client later sees the message with no answer.
- Cancel names **one request by its client message id** and stops that turn whether it is running, still waiting behind another turn, or not yet queued (the cancel is recorded, so a restart does not run it again). It never touches another turn, and a turn already finished ends normally with its answer.
- `/stop` is still stop-everything: every active turn and queued message, each settled as cancelled so it is not run again at the next boot.

## History and search

Every row is announced live to connected clients the moment it is written, whoever writes it (the owner's message, a command's answer, a job's delivery, the phone); this chat's rows reach the phones the same way, and read state is shared with them. History pages forward from the last row a client showed (catch-up after a reconnect) and backward from any row (scrolling up), up to 200 rows and about 60 KiB a page (the cursor names the last row carried). Full-text search covers the whole timeline, newest first, with an excerpt and the matched ranges; every query word must match as a word prefix, and results page backward the same way.

## Scheduled delivery

`schedule_job` with `delivery_mode: "origin"` from this chat delivers each run's result into the companion timeline, written whether or not the app is connected, announced to any connected client, and caught up by the history read on the next connect. From another chat, use `delivery_mode: "channel"` with `delivery_target: {platform: "companion", chat_id: "main"}`. A final response of exactly `[SILENT]` delivers nothing.

## What it does not carry

Attachments do not travel on it yet: a message with attachments is refused, and a file or image sent into this chat (`send_attachment`, an image delivery) is refused rather than written as a row the app could not fetch, so answer in text there. Voice uses the realtime socket, not this one.

Turns keep the `main-*` trace session and group in Opik under the `companion:main` thread; each accepted request counts one inbound `channel_msg` and each reply row one outbound (channel `companion`), and a resent duplicate counts nothing.
