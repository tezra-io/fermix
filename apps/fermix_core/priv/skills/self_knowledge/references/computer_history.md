# Computer history (macOS, opt-in, off by default)

An activity memory: a record of what the owner did in the apps they chose, summarized into memories the agent can recall. No screenshots, no audio, no keystroke tap: text comes from macOS Accessibility field values once they settle. macOS only; on any other host it is unavailable.

## Turning it on

Enabling is the consent act, done in settings, never from chat.

1. **Mac app**: Settings > Computer > **Computer history**, then **Apps** > **Choose…** to pick the apps to watch ("Only these apps are watched."). **Summarize with** shows the summarizer in force (read-only). Restart to apply.
2. **A dev install on a Mac**: browser setup's Plugins tab, **Computer History** card: **Enable**, **Grant**, **Edit apps**.
3. `[fermix_core.computer_history]`: `enabled`, `apps` (bundle ids, the only allowlist), `remote_summaries`, `summarizer`. An empty `apps` list is refused. The retired `sites` key is dropped with one warning.

It shares the computer-use helper and its rights (Settings > Computer > **What the helper may do**). There is no backfill: capture starts at enable.

## What it records

- Default-deny, apps only: nothing is recorded from an app not on the list. Within a listed app: app switches, launches and quits, focused-window titles, focused-field role and settled value, and gap markers so a capture gap never reads as inactivity.
- **Listing a browser is consent to record where the owner goes in it**: every page title and address (scheme, host and path; never a query string or fragment), and typed text only in windows positively known not to be private. A navigation in a private window is never recorded, and its row keeps neither address nor host.
- Private-window detection is definitive only for the Chromium family (Chrome and its Canary, Beta and Dev channels, Chromium). In every other recognized browser (Safari and Safari Technology Preview, Edge, Brave, Firefox and its Nightly and Developer editions, Opera, Arc, Vivaldi) addresses are recorded but typed text is always withheld, and `/history status` names those browsers. Withheld text keeps its character count and a withheld marker, so "nothing typed" and "not observable" stay distinct.
- Coverage is per app and reported: an app where only titles are readable, or that refuses to report changes, is named by `/history status`.
- Titles are normalized: leading spinner and status glyphs are stripped and a repeated title change is dropped.
- The raw spool keeps 48 hours, with a size ceiling that drops the oldest events loudly.

## The privacy gate

One gate, checked once per turn, governs every reader: the turn's model calls, the Recent Activity prompt section, `recall_activity`, the summarizer and voice.

- **Summaries are made off-device by default.** The default summarizer is the sub-agent model and provider (else the primary), so each summary sends that sitting's raw activity to that provider. `summarizer = "local"` (an on-device Ollama) is the opt-in that keeps raw events on the Mac.
- **Derived summaries reach a model call only when the turn's whole provider chain is local or granted**, because failover re-sends the same messages to later hops. A chain with any ungranted remote hop hides the feature for that turn (no section, no tool).
- **History turns are pinned to granted providers**: in an attended owner turn whose lead provider is granted, the turn runs only on granted hops in order, an ungranted fallback is dropped, and if none answers the turn fails with the ordinary provider-unavailable reply. If the primary itself is not granted, nothing is pinned and history does not surface; the status surfaces say why. With history off, failover is untouched.
- Owner-only, attended, top-level turns only: guests, sub-agents and scheduled or background runs get nothing.
- A provider counts as local only if it declares loopback and its effective base URL is loopback; an Ollama on a remote URL is remote.

| `summarizer` | Raw activity goes to | Granted for recall in chat |
|---|---|---|
| unset (`default`) | the sub-agent provider (else the primary); a call only when a sitting with signal has closed | that provider and the primary, while this route is in force and history stays on |
| `local` | nowhere (on-device) | nothing implicitly: a remote primary needs a `remote_summaries` entry |
| a provider name, e.g. `anthropic` | exactly that provider, never failing over | nothing implicitly; a router such as OpenRouter is a sharper risk (unknown downstream vendors) |

`remote_summaries = ["anthropic"]` lets named providers see derived summaries, never raw events, in owner turns and voice. Grants name providers, not models. The summarizer and `remote_summaries` are set in `config.toml`; the Mac app shows the summarizer read-only.

## How notes are made

- A **sitting** is a stretch of activity ending at a ten-minute gap, a sleep, lock or user-switch boundary, or a 90-minute ceiling. Only a closed sitting is summarized, once, into a **session note**; the open one waits. A sitting with no typed text and at most one distinct title costs nothing (`no_signal`, no call).
- The summarizer keeps up to three meaningful tasks with subject and action, never turns a viewed page into a completed task, and may abstain. Notes are cut at 900 characters. Copied field text above a short floor is replaced with `[…]`; a short fragment such as a bare SSN is not caught, so this is a backstop behind the prompt, not a barrier. Card numbers and IBANs are caught by checksum; a low-entropy or novel secret is not.
- Once a day a roll-up rewrites the **threads** (current work: a subject, where it stands, the notes it cites, their pages), at most eight. Every thread must cite a note the store still holds, and a roll-up that overlaps a purge made while it ran writes nothing.
- Each summarizer cycle logs one line per sitting (`ok`, `abstained`, `empty`, `no_signal`), so a summarizer that abstains on everything is visible.

## What the agent reads

- `recall_activity` (owner-only) returns derived summaries only, never raw field text: a **time window** in the owner's time zone ("this morning", from session notes); `window: "current"` (the active threads, dated by last touch); or `about: "<topic>"` (a search across both layers and all dates; a topic with no searchable word is refused). Results are newest first, dated, with their apps and pages, and a header states the true total when more matched than shown.
- The **Recent Activity** prompt section injects up to three current threads, then up to 8 dated sittings from the last 24 hours, each layer on its own budget.
- Both frame activity as untrusted data. A reply built from activity is tainted, so compaction and replay never send it to an ungranted remote provider. Activity lives in its own tables in `memory.db`; general memory search never returns it.
- Fermix's own automation (the managed browser, computer-use actions) is not excluded from capture: activity the agent caused can appear as the owner's. Never assume your own actions are absent.

## Commands

- `/history status`: the recorder (`Capture:` running, starting, restarting, standing down because another daemon on this Mac holds capture, not running, not answering, or degraded with the reason), `Coverage:` (title-only apps, unclassifiable browsers, apps that refused), `Chat:` (which providers history turns use, which hops are off, or the `remote_summaries` entry that would fix a non-granted primary), `Agent reads:` (a metadata-only audit of every agent read, newest 10,000 kept), `Memory:` (note and thread counts, last roll-up, the open sitting), and unsummarized spool events with the oldest one's age.
- `/history pause 10m|1h|24h`: pause capture; it survives a restart, and an event stamped before the horizon is never stored.
- `/history purge 10m|1h|24h|all`: erase that window from the spool and from notes and threads of both layers (a thread that cited it goes too), including audit rows. A late event stamped inside a purged window never lands. The reply says what purge cannot reach (delivered replies, remote copies, backups, another daemon's store) and that deletion is logical (FileVault bounds an offline attacker).
- `/history off`: disable (un-advertised next turn); data stays until purged and the app list is kept for re-enabling. The reply says capture stopped only once the recorder confirms it; otherwise it points to `/history status`.
- `fermix doctor`'s `computer history` row reports availability, on/off, the summarizer, the app count and the chat sentence, and warns when history is on but cannot surface in chat.
