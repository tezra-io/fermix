# Computer history (macOS, opt-in, off by default)

An opt-in activity memory: a passive, allowlisted record of what the owner did
on their Mac, summarized into durable "activity memories" the agent can recall.
**No screenshots, no audio, no verbatim keystrokes** — the text source is macOS
Accessibility field-value-on-settle, not a keystroke tap.

Derived memory has **two layers**, in one store, behind one gate:

- **Session notes** — the journal. A *sitting* is a contiguous stretch of
  activity, and it is summarized **once, when it closes**, never on a clock. Time
  windows read these.
- **Threads** — current work. A daily roll-up rewrites the whole active thread
  set from the previous threads plus the session notes written since: each thread
  names a subject, says where the work stands, cites the notes it drew on, and
  carries their page/URL artifacts. A thread the roll-up stops re-emitting
  retires; nothing is lost, because the journal underneath is never touched.

## What it captures

Capture is **allowlist-scoped, default-deny**: nothing is recorded unless the
operator lists the app (by bundle id) and, inside allowlisted browsers, the
site (by host). Within an allowlisted surface: app switches/launches/quits,
focused-window titles, focused-field role + settled value, and first-class
`observer.gap` events so a capture gap is never mistaken for inactivity.

Coverage is **per app, and reported**: when the recorder can only read titles in
an app (or the app refuses to report changes) it records that as an app-scoped
coverage gap, `/history status` names those apps, and the summarizer is told what
the marker means — so "nothing typed there" is never read as "the owner typed
nothing".

**Inside browsers, only window titles are captured today.** The pinned native
driver withholds browser field text and does not yet emit URLs or navigation
events, so typed text and URLs inside a browser do not reach the spool at all;
the site allowlist applies only when a frame carries a host, which that driver
does not currently supply. Do not tell the owner Fermix has their browsing URLs.

Window and page titles are **normalized at ingest**: the leading run of status
glyphs an app paints into its title (a spinner frame such as `⠙ fermix — fermix`,
a bullet marking unsaved work) is stripped, a title that is nothing but glyphs
becomes empty, and a title-change event that repeats the previous kept event's
app and normalized title inside the same batch is dropped. A spinner otherwise
changes the title on every animation tick and one glyph is enough to defeat every
downstream dedupe, which is how a live spool became almost entirely spinner
frames. The stripped set is deliberately narrow — spaces, the Braille block and
an enumerated list of circle/bullet frames — so a title that legitimately starts
with `~`, `$`, `€`, `±`, `<` or `+` is stored exactly as the app wrote it.

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
- **History-bearing owner turns are pinned to the granted hops.** While history
  is on and the turn is an attended owner turn whose *lead* provider is granted,
  the turn runs only on the granted hops, keeping their order: failover among
  them still works, an ungranted fallback is dropped for that turn, and if none
  of the granted hops answers the turn fails with the ordinary
  provider-unavailable reply rather than reaching a provider the owner never
  consented to. The lead is never replaced — if the primary itself is not
  granted, nothing is pinned, history does not surface, and the status surfaces
  say why. With history off, failover is untouched.
- **Owner-only, attended, top-level turns only.** Guests, subagent workers, and
  scheduled/background runs get nothing (and are never pinned).
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
  **both that provider and the primary** are auto-granted for history egress —
  only while this route is in force and history stays enabled (the grant lapses
  on disable). Granting both is what lets recall surface in chat when the
  subagent tier differs from the primary the turn actually runs on. Five-minute
  poll; a call only when a sitting has closed with signal in it.
- **`summarizer = "local"`: on-device (opt-in).** On-device summarization via a
  local-loopback provider (Ollama); raw events never leave; derived summaries
  only on all-local chains. For operators who run a local model. Nothing is
  granted implicitly here: a remote primary must be named in `remote_summaries`
  before recall can surface in chat.
- **Tier 2 — `remote_summaries = ["anthropic"]`.** Named providers may see
  *derived summaries* (never raw events) in owner turns and voice. Grants name
  providers, not models.
- **Tier 3 — `summarizer = "anthropic"`.** Pin one named provider for
  summarization: raw activity goes to exactly that vendor, pinned, never failing
  over to another. Like Tier 1 this grants nothing implicitly — the primary still
  needs a `remote_summaries` entry for recall to appear in chat. A router (e.g. OpenRouter) is flagged as a sharper risk
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
  what it said about the sitting's other events) is kept, so one echoed field no
  longer discards a whole window's information. A shorter fragment — a bare SSN,
  a nine-digit routing number — is below the floor and is **not** caught: the
  prompt forbids copying, and this is the backstop behind it, not the barrier.
- **It may abstain, and says so in the log.** A sitting with nothing worth
  remembering returns a marker, which is recorded as an empty window rather than
  stored as a note. Every sitting logs one line naming its outcome — `ok` (with
  how many verbatim runs were redacted), `abstained`, `empty`, or `no_signal` (the
  gate, no call made) — plus the event count and the sitting's local time window,
  and each cycle logs how many sittings ran and how many wrote nothing. A
  summarizer that abstains on everything is therefore visible instead of looking
  like a summarizer that never ran.
- **Notes are bounded** — cut at the last sentence end within 900 characters, or
  hard-cut with `…` when there is none — and each memory's structured
  artifacts (apps/sites/titles/urls) are ranked by how much of the sitting carried
  them and how recently, then capped — so the title that mattered leads the list
  instead of being buried under incidental ones. Page titles count as titles.
- **Notes accrete: one per summarized sitting, never superseded at write time.**
  The cursor is an event-id high-water mark, so every event is summarized exactly
  once and a later note can never cover an earlier note's evidence. The only
  supersession anywhere is the thread roll-up, and it only ever supersedes the
  previous thread rows.
- **It catches up and stays oriented.** A cycle summarizes several closed sittings
  (bounded per cycle), the rendered sitting is cut to a character budget (the
  cursor advances only past what was actually sent, and the remainder becomes the
  next sitting), and when a note from the previous two hours exists it is offered
  as continuity context — labelled as context, never as evidence, and counted
  against the same budget as the events.

## Sittings, and when a note is written

A sitting ends where the owner stopped: a gap of ten minutes between consecutive
events, a sleep / screen-lock / user-switch boundary (that event belongs to no
sitting, but the cursor passes it once the sitting before it is written), or a
ninety-minute ceiling. Only a **closed** sitting is summarized — one closed by a
boundary, or one whose last event is ten minutes old — so a note describes a whole
piece of work instead of a clock slice. The trailing open sitting waits, the cursor
never advances past it, and `/history status` reports how long it has been open.
Events flushed late join the sitting their timestamp falls into.

Consuming a boundary marker is not an outcome: it moves the cursor and leaves the
last recorded outcome alone. And because sittings are cut in timestamp order while
the cursor is an event-id high-water mark, a sitting cut by the input budget holds
the cursor below every id it left behind — at the price of re-reading (and
possibly re-summarizing) what it did render, which it logs. A duplicate note is
recoverable; a skipped event is not.

The summarizer ticks every five minutes, which is a cheap poll when nothing has
closed. Before any model call a **signal gate** runs: a sitting with no typed
field text and at most one distinct (normalized) window or page title is recorded
as an empty window with `no_signal` and **no call is made** — a machine left on a
single screen costs nothing. The counts are logged.

The roll-up runs at most once a day, after the sitting work, on the same pinned
route and the same gate (as its own telemetry run, parented to the cycle), and
only when at least one session note has been written since the last one. Each
current thread is offered back **with its own citations**, so a thread nobody
touched that day can be re-emitted from the notes it already draws on instead of
retiring by accident.

Code disposes of what the model proposes here too: every thread block must cite a
session-note id **the store still holds** (the new notes plus the prior threads'
cited notes, fetched by id — so a purged or invented id drops, and a block left
with none drops with it), one thread per subject, the set is capped at eight by
last-touched, each state passes the same bounds and the same verbatim guard as a
note, and the write is one transaction that **re-reads the purge watermark**: a
thread built from a window the owner erased mid-call is dropped rather than
resurrected. A reply with no usable thread writes nothing and does not move the
write mark — but the attempt is recorded, so an unusable reply is retried tomorrow
rather than at every tick, and the notes it read stay ahead of the cursor.

When a day produced more notes than one call can carry, the **newest** reach the
input (they are the ones that describe current work) and the log says how many of
how many were read; the rest stay in the journal.

## What surfaces, and the taint

`recall_activity` (owner-only tool) answers three shapes of question and returns
**derived summaries only**, never raw field text:

- a **time window** ("what was I working on this morning?") — resolved in the
  owner's configured timezone, reading the session journal;
- **`window: "current"`** ("what am I working on?") — the active threads, up to
  eight, each dated by when it was last touched rather than by a window of time;
- **`about: "<topic>"`** ("which pages about the migration?") — a topic search
  across both layers from every date on record, which replaces the window rather
  than narrowing it. A topic with no searchable word in it is refused with a
  sentence, never run as a match-everything.

Results are newest first, each entry dated (a thread as `current, last touched
<date>`) and carrying the apps/pages/URLs it came from, and bounded by whole
entries; when more matched than was shown the header states the **true total** and
how many are displayed — for a window, for the current set and for a topic — so an
omission is never silent. A per-turn **Recent Activity**
section injects a short digest under the same gate: up to three current threads
first, then the **last 24 hours** of sittings, up to 8 dated entries with up to
three pages each, dropping the oldest entry rather than cutting one mid-sentence —
a summary from last year is not recent activity, and the frame says which lines
are current work and which are recent sittings. The two layers hold **separate
character budgets**, so a few wide threads can never crowd the day's sittings out
of the section. Both frame activity as untrusted
data (a captured "ignore previous instructions…" is tagged at ingest and never
executed). Verbatim field-value text is contract-barred: the summarizer's prose
is validated code-side against the source spool before a memory is written and
any verbatim run is redacted out of it; titles/URLs are permitted as whitelisted
structured artifacts. An activity-derived assistant reply is **message-level tainted** so
compaction and conversation replay never re-send it to an ungranted-remote
provider (strict taint). Activity lives in its own `memory.db` tables, never the
general memories store; the general memory reviewer reads only user messages and
never sees it. The topic search reads a full-text index over the activity table
alone, reachable only from `recall_activity` behind the gate — a general memory
search can never return activity.

## Managing it

- Enabling is a **setup** act (the consent surface), never a chat command. The
  setup card's app picker lists installed apps by name; an empty allowlist
  cannot be saved.
- `/history status` — capture/summarizer/allowlist/spool overview. Its `Capture:`
  line is the live state of the recorder: running, starting (the start request is
  sent and the recorder has not answered yet), restarting, standing down because
  another daemon on this Mac holds capture, or degraded with the reason — the
  recorder never answered the start request, it speaks a protocol older than the
  one capture requires, it refused to start observing, it kept exiting, or its
  binary is missing. A degraded recorder releases the machine-wide hold, so the
  other daemon on the Mac can take over instead of standing down for good. Also a
  `Coverage:` line naming the apps where only window titles are observable
  (nothing typed in them can ever reach history) and the apps that refused to
  report changes — omitted when the recorder reported no such state in the
  retention window — a `Chat:`
  line naming which providers history turns run on and which failover hops are
  off while history is on (or, when the primary is not granted, that history
  cannot surface and the exact `remote_summaries` entry that would fix it), plus an
  "Agent reads" line: every agent read of history (the `recall_activity` tool
  and the Recent Activity section) appends a metadata-only audit row in the
  store itself — when, which surface, the window, and the result count, never
  content — so the owner can check what the agent has read, independent of
  rotating traces. Bounded (newest 10,000 rows kept); purge erases audit rows
  in the purged window too. A `Memory:` line counts the two derived layers — how
  many session notes and how many active threads — with how long ago the last
  roll-up ran and how long the current sitting has been going, each clause omitted
  when there is nothing to say, so a roll-up that stopped happening is visible
  before "what am I working on" goes stale.
- `/history pause 10m|1h|24h` — persist a capture pause horizon (survives restart).
- `/history purge 10m|1h|24h|all` — erase a window from the spool and the
  intersecting activity memories of **both** layers; a thread whose provenance
  touched the window goes with it, and the ack says the threads are rebuilt at the
  next roll-up from what remains. The ack also states what purge cannot reach
  (delivered replies, remote copies, backups, another daemon's store) and that it
  is logical deletion (bytes may linger until overwritten).
- `/history off` — disable (un-advertises next turn); stored data stays until
  purged; re-enable in setup reuses the persisted allowlist.
- `fermix doctor`'s `computer history` row reports availability (macOS only),
  on/off, the summarizer posture, the allowlist sizes, and the same chain
  sentence — and **warns** when history is enabled but cannot surface in chat.

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
