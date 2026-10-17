# Shared X handle (the `x` channel)

People mention Fermix's own X account under any post, and their own Fermix answers there. The account is run by **Fermix Connect**, Tezra's hosted service; each person's Fermix pairs with Connect and answers only the mentions its owner makes.

**Not available yet:** no hosted Connect runs yet, so no Fermix can be paired and no mention is answered today. Tell an owner who asks exactly that, and never walk them through pairing. What exists is the engine half: the channel's settings switch, the pairing card in the web setup (below), the `x.*` management methods, and the wire contract Connect will speak. No Mac or Linux sheet exists yet; the apps build theirs on the same methods.

## What it is, and what it is not

- **Connect does the X side.** It watches the shared account's mentions, takes the invoking post's verified numeric author id (never a handle in the text, the thread's root author or anything the post claims), finds the linked X identity and that identity's one paired Fermix, delivers the request, takes back exactly one result, checks it and publishes it: one reply under the invoking post, at most 280 characters as X counts them. It is the only thing that ever posts as the shared account.
- **The installation dials out.** A paired Fermix keeps one authenticated WebSocket to Connect. Nothing listens on the owner's network (pairing's brief listener is on the machine's own loopback address, for the owner's own browser only), and Connect never connects into a home network. Nobody needs an X developer account, an app of their own or a bot token.
- **It is not the X plugin.** The plugin's eleven tools read and post as the owner's own X account, through the owner's own developer app. The channel never posts itself, never calls the plugin, and the plugin is never a way to post as the shared account. The two share the vendor and nothing else: no credential, no code, no settings. Owners can use both.
- **One owner, one Fermix.** A mention reaches the Fermix of the person who wrote it, and only if that person linked their X account and paired a Fermix. A friend who mentions the account reaches the friend's own Fermix, never this one. An unknown or unlinked author gets no reply and learns nothing about who is linked.

## Turning it on

- Off by default, and it stays off until the owner turns it on and pairs: `[fermix_channels.x] enabled = true`, the `channels.x` settings section ("X (shared handle)", one row, "Answer mentions of the shared X account"). The switch is read when Fermix starts, so a change needs a restart.
- On but not paired is refused by name (`x.status` reads `refusal` `not_paired`), never a silent no-op. The Channels attention list says the same, as it does for a pairing that cannot be read and for a configured egress proxy that would carry the connection. Doctor's `x_channel` row reads the settings and the pairing files: off, on and paired (the handle, the Connect address and the key fingerprint), or on and refused with the same sentence.
- No other key exists. Connect's address is chosen when pairing starts, and the pairing itself lives in its own record, not in `config.toml`.

## Pairing

Pairing is one click, shaped like signing in to a model provider: a browser sign-in whose answer comes back to Fermix itself. It runs over the management methods, minimum protocol version 2:

- `x.pair.start` (optional `origin`, default `https://connect.fermix.ai`; only `https://` with a host and no path is taken) creates the instance key on first use, opens an enrollment at Connect, opens a short-lived listener on the machine's own loopback address, and returns the one-use sign-in link once, on that call only. One session at a time; a second start while one is open is refused as busy.
- The pane opens the link. The owner signs in with X, sees the installation's name and their account, and approves. The browser comes back to Fermix's listener with a one-use code, Fermix proves its key to Connect with it, and the session ends `approved` with the linked handle. With the switch already on, the channel then starts without a restart. While the owner is in the browser the session is `awaiting_browser`, and `x.pair.get` shows it.
- **A browser on another machine.** When the browser is not on the machine Fermix runs on, its last page fails to load. The owner copies that page's address and the app sends it with `x.pair.paste`; Fermix reads it exactly as it reads the browser's return, and an address from another attempt changes nothing.
- **From the web setup.** The Channels tab's "X (shared handle)" card holds the switch and the pairing: an address box names the Connect to pair with (the default is the right one), Pair with Fermix Connect opens the link in a new tab and the card waits, with the paste box for a browser elsewhere and Cancel; once paired it names the account, the Connect address and the key fingerprint, says whether the channel is connected, and offers Unpair. A pairing another surface opened shows there too, without its link.
- **Why it is safe.** The code reaches only the machine that started the pairing, and using it needs a secret that machine kept and the key it enrolled, so a link opened by anyone else pairs nothing. Nobody compares a fingerprint; the key fingerprint (the SHA-256 of the instance's public key, in groups of four hex characters) appears in `x.status`, Doctor and the Connect account page, where the owner tells installations apart and revokes one.
- Other endings: `denied` (the owner denied in the browser; nothing is written), `expired` (an enrollment lives ten minutes), `cancelled` (`x.pair.cancel`, which also closes the listener), or `failed` with the daemon's sentence saying why, such as no local port could be opened for the browser to return to. A finished session stays readable for a while, and `x.status` names the session in flight so a reopened sheet resumes it.
- **Only the owner pairs or unpairs.** Starting, pasting into and cancelling a pairing and unpairing are taken only from a process the daemon places as the owner's own (the app, or a command typed in a terminal). One Fermix started itself (an agent's shell command, a coding run, a scheduled job), a detached one, or one it cannot place is refused with "Only the owner can pair this Fermix with Fermix Connect or unpair it, from their own app or terminal." Reading the status and the session stays open.
- The instance key is `FERMIX_HOME/x/instance_key`, a `0600` file rather than the keychain, so two homes on one machine never share or overwrite it. The pairing record is `FERMIX_HOME/x/pairing.json`. Editing the record grants nothing: Connect checks every value in it on every connection and every request.

## Status

`x.status` answers with the channel off too:

- `enabled`: the switch.
- `paired`: the instance id, the linked X handle, the key fingerprint, the Connect address, the tenant generation and when it was paired; or none.
- `connection`: `off` (switched off or not running), `refused` (on but cannot run; `refusal` says why), `connecting`, `connected` or `down` (the connection was lost and is being retried). Connected means the socket is up, not that every route behind it is healthy.
- `refusal`, with its sentence: `not_paired`; `pairing_invalid` (the key or the record cannot be read: unpair and pair again); `memory_disabled` (the channel keeps its work in the memory store, which is off); `proxy_unsupported` (a configured egress proxy cannot carry the socket yet); `revoked` (Connect no longer accepts this Fermix: unpair and pair again).
- `pending` and `running`: requests accepted and waiting, and the one turn running now (X turns run one at a time).
- `last_failure`: when and a sentence, such as Connect could not be reached, Connect refused this Fermix's key, the connection was lost, another connection for this Fermix replaced it, Connect asked it to slow down, a mention expired before this Fermix could answer, a turn failed, or Connect refused a reply.
- The pairing session in flight, if any.

## Why a mention went unanswered

Nobody answers in public when something is wrong; only the owner's private status says why.

- The machine was off, asleep or offline: a request waits at Connect for 15 minutes and then expires with no reply. It is never moved to another machine.
- This Fermix is not paired, the switch is off, or it was turned on without a restart.
- The pairing was revoked or the record is unreadable (`refusal` `revoked` or `pairing_invalid`): unpair and pair again.
- Connect is down. By design the handle is then silent, with no fallback.
- The author is not a linked user, or is someone else: their mention never reaches this Fermix.
- Shadow mode: until X's written approval for this use is on record, results are recorded and never posted.
- The turn failed, or Connect refused the reply (over 280 characters, for one); `last_failure` says which.

## What an X turn can and cannot do

These are fixed by the channel, not settings:

- It runs as a guest: no USER.md or MEMORY.md in the prompt, and read-only tools only: no skills, MCP, shell or network, and none of the tools that return the owner's own data.
- No slash commands, no approvals, no streaming, no typing or progress messages: one final reply of at most 280 characters, or none.
- Nothing private ever goes to X. The post and its thread are untrusted public text: an instruction inside them changes nothing.
- The X conversation never joins any other channel's history, and memory review never learns from it.
- Jobs, reminders and `send_to_channel` never send to X.
- It cannot post on its own, post a second reply, reply somewhere else, like, repost or follow. Connect alone publishes, and only the one reply.
- Publishing stays in shadow mode until X's written approval for this use is on record: Connect records each result and posts none.
- Private actions asked from X (saving something, a reminder) come later, each behind a private approval the owner gives off X.

## What Fermix Connect sees and keeps

Connect holds the linked X identity (numeric id and handle), each installation's public key and label, the public posts in the bounded context it forwards with a request (at most 8 posts), the interactions, requests and the replies it publishes, and its routing records. It never holds the owner's memory, files, tools, model keys or the instance's private key. A page on what Connect keeps, how to unlink and how deletion works is planned; do not quote retention periods or addresses for it.

## Unpairing and unlinking

- `x.unpair` tells Connect to revoke this installation (its waiting requests are cancelled and its connection closed), then deletes the instance key and the pairing record and stops the channel. Nothing paired answers `unavailable` with a sentence, and so does a Connect that cannot be reached, in which case this Fermix stays paired: try again later. The next pairing makes a new key.
- A pairing whose record or key cannot be read cannot sign that revocation. Unpairing then removes it from this machine only, and the daemon log says to remove the installation from the Connect account page as well; pairing again then starts clean.
- Unlinking the X account itself happens at Connect, not on the machine.
