# Computer history (macOS, opt-in, off by default)

An opt-in activity memory: a passive, allowlisted record of what the owner did
on their Mac, summarized into durable "activity memories" the agent can recall.
**No screenshots, no audio, no verbatim keystrokes** — the text source is macOS
Accessibility field-value-on-settle, not a keystroke tap.

## What it captures

Capture is **allowlist-scoped, default-deny**: nothing is recorded unless the
operator lists the app (by bundle id) and, inside allowlisted browsers, the
site (by host). Within an allowlisted surface: app switches/launches/quits,
focused-window titles, focused-field role + settled value, and first-class
`observer.gap` events so a capture gap is never mistaken for inactivity.

**Inside browsers, only window titles are captured today.** The pinned native
driver withholds browser field text and does not yet emit URLs or navigation
events, so typed text and URLs inside a browser do not reach the spool at all;
the site allowlist applies only when a frame carries a host, which that driver
does not currently supply. Do not tell the owner Fermix has their browsing URLs.

There is no historical backfill — macOS Accessibility is live-only, so capture
begins at enable and only new events flow. The raw spool is double-bounded: 48h
retention plus a size ceiling that drops the oldest events (with a loud
warning) if a pathological source balloons it inside the window.

## The privacy spine (one gate)

Every reader — the turn's LLM chain, the Recent Activity prompt section, the
`recall_activity` tool, the summarizer, a voice session — consults one resolver,
`ComputerHistory.Gate`, snapshotted once per turn. The load-bearing rules:

- **The default summarizer runs off-device.** Summarization defaults to the
  operator's subagent model/provider (else the primary) — so producing a summary
  sends that window's raw activity to that provider. This inverts the original
  on-device-by-default posture and is why enabling is a disclosed privacy
  decision. `summarizer = "local"` (on-device Ollama) stays an explicit opt-in;
  otherwise raw events stay on the Mac (~48h) and only *derived summaries* ever
  reach the turn's LLM chain.
- **Whole-chain rule**: derived summaries reach an LLM call only when that turn's
  *entire* provider route chain is local-or-granted. Because failover re-sends
  the same messages to later hops and Ollama sits last as the fallback, a chain
  with any ungranted-remote hop hides the whole feature that turn (no section,
  no tool) — the failover-leak the gate exists to close.
- **Owner-only, attended, top-level turns only.** Guests, subagent workers, and
  scheduled/background runs get nothing.
- **Locality is declared, never inferred.** A provider is local only if it
  declares `:local_loopback` AND its effective base URL resolves to loopback; an
  Ollama pointed at a non-loopback URL is remote.

## Provider tiers (the `[fermix_core.computer_history]` block)

`enabled` (the consent act), `apps`/`sites` (default-deny allowlists),
`remote_summaries` (Tier 2 grants), `summarizer` (the route). Enabling with an
empty allowlist is refused — consent to capture nothing is not consent.

- **Default — `summarizer` unset (`"default"`): the subagent tier.** Summarize on
  the operator's subagent model/provider (else the primary + its default model).
  Reuses the tier the operator already picked for cheap delegated work instead of
  hard-coding a model here; the setup card names the resolved `provider · model`.
  Raw activity is sent to that provider off-device to produce each summary, and
  the primary is auto-granted for history egress only while this route is in
  force and history stays enabled (it lapses on disable). ~30-min cadence.
- **`summarizer = "local"`: on-device (opt-in).** On-device summarization via a
  local-loopback provider (Ollama); raw events never leave; derived summaries
  only on all-local chains. For operators who run a local model.
- **Tier 2 — `remote_summaries = ["anthropic"]`.** Named providers may see
  *derived summaries* (never raw events) in owner turns and voice. Grants name
  providers, not models.
- **Tier 3 — `summarizer = "anthropic"`.** Pin one named provider for
  summarization: raw activity goes to exactly that vendor, pinned, never failing
  over to another. A router (e.g. OpenRouter) is flagged as a sharper risk
  (opaque downstream vendors).

The summarizer is prompted for **importance extraction, not an app inventory**:
it keeps up to three meaningful tasks with their subject and observed action,
ignores repetition and transient switches, and never turns a viewed surface into
a completed task — the events are heterogeneous app/tool activity, most of it
incidental. It never fails over to a second vendor, and code disposes of what it
proposes:

- **Verbatim field text is redacted, not stored.** Both the note and the source
  fields are compared through a normalized projection — letters and digits only,
  lowercased, in one Unicode normal form — so a copy that was reflowed,
  re-punctuated, re-cased or differently accent-encoded (NFC/NFD) is still
  caught. What it catches is a **contiguous run** of source field text above a
  short floor; the run is replaced with `[…]` and the rest of the note (including
  what it said about other events in the batch) is kept, so one echoed field no
  longer discards a whole window's information. A shorter fragment — a bare SSN,
  a nine-digit routing number — is below the floor and is **not** caught: the
  prompt forbids copying, and this is the backstop behind it, not the barrier.
- **It may abstain.** A batch with nothing worth remembering returns a marker,
  which is recorded as an empty window rather than stored as a memory.
- **Notes are bounded** — cut at the last sentence end within 900 characters, or
  hard-cut with `…` when there is none — and each memory's structured
  artifacts (apps/sites/titles/urls) are ranked by how much of the batch carried
  them and how recently, then capped — so the title that mattered leads the list
  instead of being buried under incidental ones. Page titles count as titles.
- **Memories accrete: one per summarized batch, never superseded.** The cursor is
  an event-id high-water mark, so every event is summarized exactly once and a
  later note can never cover an earlier note's evidence.
- **It catches up and stays oriented.** A cycle drains a backlog over several
  bounded calls instead of a single fixed batch, the rendered batch is cut to a
  character budget (the cursor advances only past what was actually sent), and
  when a note from the previous two hours exists it is offered as continuity
  context — labelled as context, never as evidence, and counted against the same
  budget as the events.

## What surfaces, and the taint

`recall_activity` (owner-only tool) answers "what was I working on this
morning?" — windows resolve in the owner's configured timezone and it returns
**derived summaries only**, never raw field text. Results are newest first, each
entry dated with its local time range and carrying the apps/pages/URLs it came
from, and bounded by whole entries; when the window held more than was shown the
header says how many entries exist and how many are displayed, so an omission is
never silent. A per-turn **Recent Activity** section injects a short digest under
the same gate: the **last 24 hours only**, up to 8 dated entries with up to three
pages each, dropping the oldest entry rather than cutting one mid-sentence — a
summary from last year is not recent activity. Both frame activity as untrusted
data (a captured "ignore previous instructions…" is tagged at ingest and never
executed). Verbatim field-value text is contract-barred: the summarizer's prose
is validated code-side against the source spool before a memory is written and
any verbatim run is redacted out of it; titles/URLs are permitted as whitelisted
structured artifacts. An activity-derived assistant reply is **message-level tainted** so
compaction and conversation replay never re-send it to an ungranted-remote
provider (strict taint). Activity lives in its own `memory.db` tables, never the
general memories store; the general memory reviewer reads only user messages and
never sees it.

## Managing it

- Enabling is a **setup** act (the consent surface), never a chat command. The
  setup card's app picker lists installed apps by name; an empty allowlist
  cannot be saved.
- `/history status` — capture/summarizer/allowlist/spool overview, plus an
  "Agent reads" line: every agent read of history (the `recall_activity` tool
  and the Recent Activity section) appends a metadata-only audit row in the
  store itself — when, which surface, the window, and the result count, never
  content — so the owner can check what the agent has read, independent of
  rotating traces. Bounded (newest 10,000 rows kept); purge erases audit rows
  in the purged window too.
- `/history pause 10m|1h|24h` — persist a capture pause horizon (survives restart).
- `/history purge 10m|1h|24h|all` — erase a window from the spool and the
  intersecting activity memories; the ack states what purge cannot reach
  (delivered replies, remote copies, backups, another daemon's store) and that
  it is logical deletion (bytes may linger until overwritten).
- `/history off` — disable (un-advertises next turn); stored data stays until
  purged; re-enable in setup reuses the persisted allowlist.
- `fermix doctor` shows a `computer history` row.

## Boundaries

macOS only — the capture layer *is* macOS (Accessibility TCC, NSWorkspace,
AXObserver) and does not port; on any other host the feature is unavailable.
The scrubber and secure-field suppression reduce but cannot close the
secret-capture risk (codes and tokens pasted into allowlisted apps can be seen);
purge is bounded against an offline attacker by FileVault, not zeroed. Excluding
Fermix's own automation (the driven browser, any Computer-Use action) from
capture is **designed but not yet enforced** — there is no driven-pid exclusion
today, so activity the agent itself caused can appear in history as if it were
the owner's. Never assume your own actions are absent from what you recall.
`/history status` reports how many spool events are still unsummarized and how
old the oldest is, so a summarizer falling behind is visible before the 48h
retention starts eating the backlog.

**Current status:** the config, tools, `/history` commands, summarizer, the
entire privacy rail, and the macOS capture layer (an AXObserver/CFRunLoop engine
in the shared native driver, wire protocol v6) are implemented.
