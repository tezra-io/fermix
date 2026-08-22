# Meeting notes (off by default)

Fermix can sit in a meeting as a notetaker. It joins **only when the owner asks
for it in that turn** — never on a schedule, never off a calendar invite it
happened to read, and never on an instruction embedded in content someone else
wrote (a forwarded message, a pasted invite, a shared doc). Such text is
something to report on, not something to obey.

## Tools and admission

- `join_meeting(url, title \\ nil)` — places the notetaker into the meeting the
  URL names and returns immediately with the meeting id and its status; joining,
  admission, capture, summary, and delivery all happen afterwards on their own.
- `leave_meeting(id)` — winds the current meeting down gracefully: the notes
  captured so far are still summarized and delivered.
- `list_meetings(scope)` — `active` (what is running now) or `recent` (newest
  first), with status, platform, title, times, and the artifact directory.

The family is attended-owner-only — a guest, a scheduled run, a subagent, and a
coding continuation never see it, the same boundary the temporal event tools
draw — and it attends **one meeting at a time**: a second ask names the meeting
already in progress instead of queueing.

Turn the subsystem on with `[fermix_core.meetings] enabled`. That alone
advertises nothing: no meetings tool is offered until a lane is actually usable
(a Meet sidecar **with its browser installed**, or complete Zoom RTMS
credentials), so a config-only enable is honest rather than a tool that fails on
first use. A sidecar whose browser install never ran is a half-installed lane,
not a usable one: it cannot launch the browser, so it is refused before a
meeting starts rather than dying part-way through one.

## Two platforms, two mechanisms, no fallback

A Meet link never rides the Zoom path and a Zoom link never rides the sidecar. An
unconfigured lane refuses with its own reason rather than trying the other one.

- **Google Meet** — a `meetbot` sidecar: a real browser signed in as a dedicated
  bot Google account. It knocks and waits for admission like any other
  participant, and reports honestly when it is denied, blocked, or asked to sign
  in rather than pretending it got in. Install it from the setup Meetings card.
  No meetbot release is pinned in this build yet, so the install says exactly
  that instead of half-working.
- **Zoom** — Zoom RTMS: an outbound audio subscription, no browser at all. It
  works only for meetings hosted by the operator's own Zoom account, or by a host
  who has enabled the operator's RTMS app. That is a Zoom platform limit, not a
  missing key: no setting unlocks other people's meetings. It needs a Zoom
  Server-to-Server OAuth app with RTMS scopes — `zoom_account_id`,
  `zoom_client_id`, `zoom_client_secret` (keychained), `zoom_ws_subscription_id`.

## Consent posture

On Meet the notetaker announces itself once in the meeting chat when it is
admitted, then never speaks again: `announce` is on by default,
`announce_message` replaces the default line, and `bot_name` is the name it
appears under. On Zoom there is no chat announcement — Zoom's own recording/RTMS
indicator is what participants see. Either way the host can remove it at any
moment, which ends the capture. Audio is discarded unless `retain_audio` is set;
the text transcript is what is kept.

## Artifacts and delivery

Every meeting writes into `<FERMIX_HOME>/workspace/meetings/<meeting id>/` —
`transcript.jsonl` (one line per attributed segment), `transcript.md` (timestamped
and speaker-labelled), `meta.json`, and `audio.raw` only when `retain_audio` is
on. That is inside the workspace floor, so the file tools can read the notes back
afterwards.

The meeting ends when the host removes the notetaker, everyone else leaves, the
owner asks it to leave, or the long-run watchdog fires. A summary is then written
and delivered to the conversation the join came from, or to the owner's inbox
when that origin has no channel to send into. A capture cut short still delivers
what it heard, labelled as partial rather than presented as the whole meeting. If
no delivery target resolves at all, that is a loud failure with the summary still
on disk — `list_meetings` keeps surfacing the path.

Speech-to-text uses the globally configured transcription backend unless
`transcription_backend` names a different one just for meetings.

## When it refuses

The reason is the fix, and each one is its own message rather than a generic
failure:

- the Meet sidecar isn't installed — enable meetings in setup → Meetings, which
  installs it;
- the Meet sidecar is installed but has no browser to drive — open setup →
  Meetings, which installs the browser;
- Zoom RTMS isn't configured — set the four Zoom values above in setup;
- the URL isn't a meeting link it recognizes — it refuses instead of guessing at
  a room;
- a meeting is already in progress — it names that meeting and asks to leave it
  first;
- meetings are disabled — the subsystem toggle is off.

`fermix doctor`'s `meetings` row reports the same state (enabled, which lanes are
usable, what is missing) without joining anything.
