# Computer history (opt-in, off by default)

An activity memory: a record of what the owner did in the apps they chose, on each computer of the home, summarized into notes the agent can recall. No screenshots, no audio, no keystroke tap: text comes from macOS Accessibility field values once they settle. A Mac records; a Linux computer says `history: unavailable` until a Linux recorder ships. A Linux server keeps and recalls the notes of the computers that record.

## Turning it on

Enabling is the consent act, done in settings, never from chat.

1. **Mac app**: Settings > Computer > **Computer history**, then **Apps** > **Choose…** to pick the apps to watch ("Only these apps are watched."). **Summarize with** shows the summarizer in force (read-only). Restart to apply.
2. **A dev install on a Mac**: browser setup's Plugins tab, **Computer History** card: **Enable**, **Grant**, **Edit apps**.
3. `[fermix_core.computer_history]`: `enabled`, `apps` (bundle ids, the only allowlist), `remote_summaries`, `summarizer`. An empty `apps` list is refused. The retired `sites` key is dropped with one warning.

What switching it on agrees to: Fermix records what you do in the apps you choose on this computer. The raw record stays here and is deleted after 48 hours. Each finished sitting goes to your Fermix home (this computer, or your Fermix server once the home is there), which has its summarizer summarize it and keeps the summary. Summaries from all your computers can be recalled in chat.

It shares the computer-use helper and its rights (Settings > Computer > **What the helper may do**). There is no backfill: capture starts at enable.

## One memory from every computer

- **Raw history stays on the machine that recorded it**: `device/history.db` under its home, a store of its own on every engine, the home's own machine included, never in `memory.db`, never in a move, snapshot or backup.
- **A finished sitting goes to the home** to be summarized: from a computer whose home is a server, over the link (`history.submit`, after the same scrubbing, at most 60,000 characters, with its apps, sites, titles, addresses, counts and time range); on a home that records itself, in process. The home makes the note on its summarizer, marks it with the computer, and never writes the sitting's text down: the summary call's request and reply are kept out of every trace and Opik export.
- **The computer's history switch** (This computer > Your computer history) lets the server have its sittings; with it off, nothing is sent and raw events expire. A computer whose `summarizer` is `local` makes the note on its own model and sends only the note.
- A sitting the home refuses (a purge or pause it has not applied yet) or does not answer is sent again later; raw events still expire after 48 hours, and an unsent one that expires is counted in `/history status`.
- Notes and threads are the home's: they travel with a move and a move back, and nothing deletes them on the way. Notes recorded on the home's own machine before a move are named "this computer" on the server.

## What it records

- Default-deny, apps only: nothing is recorded from an app not on the list. Within a listed app: app switches, launches and quits, focused-window titles, focused-field role and settled value, and gap markers so a capture gap never reads as inactivity.
- **Listing a browser is consent to record where the owner goes in it**: every page title and address (scheme, host and path; never a query string or fragment), and typed text only in windows positively known not to be private. A navigation in a private window is never recorded, and its row keeps neither address nor host.
- Private-window detection is definitive only for the Chromium family (Chrome and its Canary, Beta and Dev channels, Chromium). In every other recognized browser (Safari and Safari Technology Preview, Edge, Brave, Firefox and its Nightly and Developer editions, Opera, Arc, Vivaldi) addresses are recorded but typed text is always withheld, and `/history status` names those browsers. Withheld text keeps its character count and a withheld marker, so "nothing typed" and "not observable" stay distinct.
- Coverage is per app and reported: an app where only titles are readable, or that refuses to report changes, is named by `/history status`.
- Titles are normalized: leading spinner and status glyphs are stripped and a repeated title change is dropped.
- The raw spool keeps 48 hours, with a size ceiling that drops the oldest events loudly.

## The privacy gate

One gate, checked once per turn, governs every reader: the turn's model calls, the Recent Activity prompt section, `recall_activity`, the summarizer and voice.

- **Summaries are made off-device by default.** The home's summarizer (default: the sub-agent model and provider, else the primary) receives each sitting's raw activity. `summarizer = "local"` on a computer (an on-device Ollama) keeps its raw events on that computer: it summarizes there and sends only the note.
- **Whether history can surface** is the home's fact, never this host's platform: this machine records, a computer offers its history, or a home with no recorder of its own (a server) holds notes. A Mac that is its own home and switches history off hides it, as before, unless a computer still offers it.
- **Derived summaries reach a model call only when the turn's whole provider chain is local or granted**, because failover re-sends the same messages to later hops. A chain with any ungranted remote hop hides the feature for that turn (no section, no tool).
- **History turns are pinned to granted providers**: in an attended owner turn whose lead provider is granted, the turn runs only on granted hops in order, an ungranted fallback is dropped, and if none answers the turn fails with the ordinary provider-unavailable reply. If the primary itself is not granted, nothing is pinned and history does not surface; the status surfaces say why. With history off, failover is untouched.
- Owner-only, attended, top-level turns only: guests, sub-agents and scheduled or background runs get nothing.
- A provider counts as local only if it declares loopback and its effective base URL is loopback; an Ollama on a remote URL is remote.

| `summarizer` | Raw activity goes to | Granted for recall in chat |
|---|---|---|
| unset (`default`) | the sub-agent provider (else the primary); a call only when a sitting with signal has closed | that provider and the primary, while this route is in force and history stays on |
| `local` | nowhere (on-device) | nothing implicitly: a remote primary needs a `remote_summaries` entry |
| a provider name, e.g. `anthropic` | exactly that provider, never failing over | nothing implicitly; a router such as OpenRouter is a sharper risk (unknown downstream vendors) |

`remote_summaries = ["anthropic"]` lets named providers see derived summaries, never raw events, in owner turns and voice. Grants name providers, not models. The section is set in each computer's `machine.toml`; the Mac app shows the summarizer read-only.

## How notes are made

- A **sitting** is a stretch of activity ending at a ten-minute gap, a sleep, lock or user-switch boundary, or a 90-minute ceiling. Only a closed sitting is summarized, once, into a **session note**; the open one waits. A sitting with no typed text and at most one distinct title costs nothing (`no_signal`, no call).
- An event stamped while Fermix on the owner's server controlled that computer's screen is marked as Fermix's own (`by=fermix`), and the summarizer never reports it as the owner's activity.
- The summarizer keeps up to three meaningful tasks with subject and action, never turns a viewed page into a completed task, and may abstain. Notes are cut at 900 characters. Copied field text above a short floor is replaced with `[…]`; a short fragment such as a bare SSN is not caught, so this is a backstop behind the prompt, not a barrier. Card numbers and IBANs are caught by checksum; a low-entropy or novel secret is not.
- Once a day, on the home, a roll-up across every computer rewrites the **threads**; a thread may cite notes from several computers, so work that moved from one machine to another is one thread (current work: a subject, where it stands, the notes it cites, their pages), at most eight. Every thread must cite a note the store still holds, and a roll-up that overlaps a purge made while it ran writes nothing.
- Each summarizer cycle logs one line per sitting (`ok`, `abstained`, `empty`, `no_signal`), so a summarizer that abstains on everything is visible.

## What the agent reads

- `recall_activity` (owner-only) returns derived summaries only, never raw field text, each sitting named with its machine once the home has a computer besides its own ("studio Mac, Nov 11 09:00–10:30"); `computer: "<name>"` (or "this computer") takes one machine's notes alone: a **time window** in the owner's time zone ("this morning", from session notes); `window: "current"` (the active threads, dated by last touch); or `about: "<topic>"` (a search across both layers and all dates; a topic with no searchable word is refused). Results are newest first, dated, with their apps and pages, and a header states the true total when more matched than shown.
- The **Recent Activity** prompt section injects up to three current threads, then up to 8 dated sittings from the last 24 hours, each named with its machine, each layer on its own budget.
- Both frame activity as untrusted data. A reply built from activity is tainted, so compaction and replay never send it to an ungranted remote provider. Notes live in their own tables in `memory.db`; general memory search never returns them.
- When such a reply raises an open loop, the follow-up record keeps what Fermix said marked too: it comes back in a due note or `open_loop_list` only on a request that may carry activity, and never in a check-in run; anywhere else the follow-up shows only that Fermix raised it and what the owner replied.
- Screen control from the server is marked as Fermix's own; Fermix's other automation on a computer (the managed browser) is not, so activity the agent caused there can still appear as the owner's. Never assume your own actions are absent.

## Commands

- `/history status`: this machine's lines where it records, the home's, then one block per computer (its history switch, connected or last seen, its last sitting and how it was answered, its notes, purges or pauses it has not applied yet). This machine's lines: the recorder (`Capture:` running, starting, restarting, standing down because another daemon on this Mac holds capture, not running, not answering, or degraded with the reason), `Coverage:` (title-only apps, unclassifiable browsers, apps that refused), `Chat:` (which providers history turns use, which hops are off, or the `remote_summaries` entry that would fix a non-granted primary), `Agent reads:` (a metadata-only audit of every agent read, newest 10,000 kept), `Memory:` (note and thread counts, last roll-up, the open sitting), and unsummarized spool events with the oldest one's age.
- `/history pause 10m|1h|24h`: recorded on the home, which takes no sitting stamped inside it from any computer; this machine pauses at once and each connected computer is told (one that is away when it is next connected). It survives a restart, and an event stamped before the horizon is never stored. A pause set at a computer applies to that computer.
- `/history purge 10m|1h|24h|all`: runs on the home: erases that window from the notes and threads of every computer (a thread that cited it goes too) and the audit rows, fences this machine's raw events, and tells each connected computer, which deletes its raw events in the window and fences late ones; one that is away gets it when next connected, and until then the home takes no sitting of its that touches the window. A purged window never gains a note, in whichever order the purge and a late sitting arrive. The reply says what purge cannot reach (delivered replies, remote copies, backups including the Fermix server's, another daemon's store) and that deletion is logical.
- `/history off`: disable on this machine (off is per computer; a computer's own history switch is at that computer) (un-advertised next turn when nothing else offers history); data stays until purged and the app list is kept for re-enabling. The reply says capture stopped only once the recorder confirms it; otherwise it points to `/history status`.
- `fermix doctor`'s `computer history` row reports availability, on/off, the summarizer, the app count and the chat sentence, and warns when history is on but cannot surface in chat.
