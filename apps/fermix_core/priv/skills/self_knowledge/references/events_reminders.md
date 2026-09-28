# Events and reminders

A durable personal date plus a finite reminder plan, delivered to the owner through the default background channel. No model runs when a reminder fires.

## Event or scheduled job

- **Event** (`event_store`): a deterministic date whose only future action is notifying the owner: birthdays, anniversaries, appointments, deadlines, follow-ups, a plain "remind me on Friday".
- **Scheduled job** (`schedule_job`): future work that must reason, call a provider, use tools, check changing state or produce a digest.
- Events are their own rows in `~/.fermix/memory.db`, never memory facts (the memory reviewer may archive a passed date) and never job rows.
- A connected calendar (such as the Google Calendar plugin) is a separate, unsynced source. A schedule question consults `event_list` plus any connected calendar tools and attributes each answer, saying when a source was not consulted or unreachable. A calendar event does not make Fermix remind anyone; before storing a date a connected calendar likely has, ask whether the owner also wants Fermix reminders.

## Time and recurrence

- `when` is one tagged form: `{"type":"date"}`, `{"type":"datetime"}` (with `utc_offset` when a local time is ambiguous), `{"type":"relative","amount":2,"unit":"days"|"weeks"}`, or `{"type":"annual","month":9,"day":14}`.
- The tool owns the clock: it uses `[fermix_core.personalization] timezone` unless the owner names an IANA zone, and a missing or invalid zone fails creation rather than assuming UTC. A nonexistent DST-gap time is rejected; an ambiguous one needs `utc_offset` (ask the owner).
- Recurrence is one-time or yearly. A yearly event is one row with one id; reminders are materialized for the next two occurrences, rolling over by local calendar, never +365 days. A yearly February 29 needs a `feb_28` or `mar_1` policy: ask once.
- Every create and edit returns `stated_as`, the stored occurrence written absolutely with its weekday (a yearly event: its day plus the next occurrence); confirm with that, not the owner's relative word. A relative day word used in the small hours after midnight gets a which-day question naming both dates before anything is stored.

## Reminder plans and delivery

- Defaults: birthday or anniversary, 7 days before and the day of at 9:00 local; timed appointment, 24 hours and 1 hour before; date-only deadline, 7 days, 1 day and the day of. "Remind me at X" creates exactly that one. A custom plan replaces the defaults (at most 10 rules); lead times already past are skipped, so say when nothing future remains.
- Delivery goes to `[fermix_core.jobs] default_delivery_target`, snapshotted onto the event: Telegram, Slack, Discord, Signal or WhatsApp (`cli` is a jobs target, not a reminder target). With none configured, Fermix derives the owner's inbox from the first channel with an explicit `owner_user_id` (Telegram, then Signal, then WhatsApp); `delivery.source` says `configured` or `derived`, so the acknowledgement can name the derived inbox. With neither, `event_store` fails naming both fixes and never falls back to the current chat. The default target is a `config.toml` key; no settings pane writes it. Telegram refuses a bot's first message to someone who never pressed **Start**, so a Telegram inbox needs the owner to have started the bot once.
- A later config change does not move existing events; `event_update(rebind_delivery_to_default: true)` does.
- A failed send is retried on the same target (at due, +1 min, +5 min, +15 min, +60 min, honoring a rate-limit hint, within the reminder's validity), then fails visibly; it never switches channel. A later rule coming due supersedes an earlier still-failing one, so a recovery never sends "one week before" and "today" together. Messages always state the absolute date and time and fit in one message on every channel.

## The follow-up check-in

- An event flagged `followup` gets, after each delivered reminder, one short model turn that may send at most one extra message: an offer to help, something remembered about the person, or one focused question. It runs only after delivery has settled, so it can never cost the reminder.
- The flag is judged once, by the attended turn that stores or edits the event (`event_store`/`event_update` take `followup`; there is no per-kind default). Set it for an occasion the owner would plausibly want help acting on; leave it off for a logistics ping. The confirmation says a check-in will follow. Changing it later is an ordinary `event_update`. A yearly event keeps it across rollovers.
- The run sees the delivered text and the stored event, can call only `event_list`, `memory_recall` and `memory_store`, cannot change the event, and answers with one message to the same conversation or exactly `[SILENT]`. When it sends, it stores a one-line memory in that conversation so a reply to it has context.
- Best-effort: no queue, retry or boot sweep. A concurrency limit, a cancelled or unflagged event, a restart, a provider outage or a timeout skips it; an empty reply without `[SILENT]` sends nothing.

## Managing stored events

- **Duplicates.** A create that matches an active event's identity on a different date refuses and quotes the stored date, so ask which it is. Every create returns `similar_events` (up to five active events of the same kind) to catch a twin stored under another title. Every `event_update` returns `previous`, the prior values of the fields it changed, so the acknowledgement states was-and-now from stored values.
- **Date changes need `owner_direction`**: a near-verbatim excerpt of the owner's own words directing the change. Without it the edit refuses, naming the stored date, so ask whether to overwrite or keep both. Title, kind, time zone, plan and rebind edits need none.
- `event_list` searches by text, kind, status and date window and shows the next occurrence, plan, next due reminder and last delivery state. With no window or status it lists upcoming events from today.
- `event_remove` soft-cancels (delivered history stays). With no `event_id`, "cancel that" cancels the event behind the most recent reminder delivered into this exact conversation within 24 hours; the result carries the whole event, so say when a yearly event took every future occurrence with it.
- `reminder_snooze` defers one reminder: with no `reminder_id` it takes the most recent reminder delivered into this conversation within 24 hours, never guessing across chats (if nothing matches, ask which). The time is a duration up to 90 days or a DST-safe time in the owner's zone; a time at or past the event itself needs `confirm_past_boundary`. One active snooze per reminder: a new time replaces it, a repeat of a live snooze is idempotent (a time whose earlier snooze was cancelled or replaced arms it again), the delivered original stays in history, and the stored plan never changes. A snooze after a one-time event completed reactivates it just long enough to deliver.
- `event_update`, `event_remove` and `reminder_snooze` refuse with `delivery_in_progress` while that event's reminder is mid-send (a send cannot be recalled); retry when the attempt ends.
- **Who can use them**: the four mutating tools only in a top-level operator turn from an interactive or voice surface. Guest, scheduled, background, delegated and coding-continuation runs, and a local-socket prompt from a process Fermix started or a detached one, cannot see or call them. `event_list` is also readable from an operator-created scheduled run, so a morning-brief job can include stored events.
