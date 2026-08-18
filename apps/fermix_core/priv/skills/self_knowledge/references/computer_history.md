# Computer history (macOS, opt-in, off by default)

An opt-in activity memory: a passive, allowlisted record of what the owner did
on their Mac, summarized into durable "activity memories" the agent can recall.
**No screenshots, no audio, no verbatim keystrokes** — the text source is macOS
Accessibility field-value-on-settle, not a keystroke tap.

## What it captures

Capture is **allowlist-scoped, default-deny**: nothing is recorded unless the
operator lists the app (by bundle id) and, inside allowlisted browsers, the
site (by host). Within an allowlisted surface: app switches/launches/quits,
focused-window titles, focused-field role + settled value, browser URL + page
title (private-browsing windows excluded best-effort), and first-class
`observer.gap` events so a capture gap is never mistaken for inactivity. There
is no historical backfill — macOS Accessibility is live-only, so capture begins
at enable and only new events flow.

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
it infers the task/project/topic from titles/URLs/field labels, groups related
activity across apps, ignores brief switches, and names the *subject* of the work
— the events are heterogeneous app/tool activity, most of it incidental. It never
transcribes field text (a code-side verbatim-leak check rejects the whole summary
if it echoes source field values) and never fails over to a second vendor.

## What surfaces, and the taint

`recall_activity` (owner-only tool) answers "what was I working on this
morning?" — windows resolve in the owner's configured timezone and it returns
**derived summaries only**, never raw field text. A per-turn **Recent Activity**
section injects a short digest under the same gate. Both frame activity as
untrusted data (a captured "ignore previous instructions…" is tagged at ingest
and never executed). Verbatim field-value text is contract-barred: the
summarizer's prose is validated code-side against the source spool before a
memory is written; titles/URLs are permitted as whitelisted structured
artifacts. An activity-derived assistant reply is **message-level tainted** so
compaction and conversation replay never re-send it to an ungranted-remote
provider (strict taint). Activity lives in its own `memory.db` tables, never the
general memories store; the general memory reviewer reads only user messages and
never sees it.

## Managing it

- Enabling is a **setup** act (the consent surface), never a chat command.
- `/history status` — capture/summarizer/allowlist/spool overview (operator-only).
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
purge is bounded against an offline attacker by FileVault, not zeroed. Fermix's
own automation (the driven browser and any Computer-Use action) is excluded so
the agent's actions are never recorded as the owner's.

**Current status:** the config, tools, `/history` commands, summarizer, the
entire privacy rail, and the macOS capture layer (an AXObserver/CFRunLoop engine
in the shared native driver, wire protocol v6) are implemented.
