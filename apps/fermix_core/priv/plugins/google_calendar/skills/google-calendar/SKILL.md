---
name: google-calendar
description: Inspect Google Calendar, check availability, and create, update, move, RSVP to, or delete events (with confirmation) through the Fermix Google Calendar plugin.
---

# Google Calendar

Use this skill when the Google Calendar plugin is enabled and connected. It turns calendar data into clear scheduling answers and safe event creation.

## Tools

- `google_calendar_search_events` (read-only) — find events. Args: `query`, optional `calendar_id` (default `primary`), `max_results` (default 10).
- `google_calendar_create_event` — add an event. Args: `summary`, `start`, `end` (ISO 8601), optional `description`, `calendar_id`, `time_zone` (IANA).
- `google_calendar_quick_add_event` — create an event from a natural-language phrase. Args: `text` (e.g. "Lunch with Sara tomorrow 1pm"), optional `calendar_id`.
- `google_calendar_update_event` — change fields on an existing event (partial). Args: `event_id`, plus any of `summary`, `description`, `location`, `start`, `end`, `time_zone`; optional `calendar_id`, `send_updates`.
- `google_calendar_respond_to_event` — RSVP to an invite. Args: `event_id`, `response_status` (`accepted` | `declined` | `tentative`); optional `calendar_id`, `send_updates`. Preserves the other attendees.
- `google_calendar_move_event` — move an event to another calendar. Args: `event_id`, `destination_calendar_id`; optional `calendar_id` (source), `send_updates`.
- `google_calendar_delete_event` — delete an event. Args: `event_id`; optional `calendar_id`, `send_updates`.

All writes use the `calendar.events` scope. If it wasn't granted at sign-in, the tool returns a "reauthorize" error — tell the user to run `fermix plugins auth reauthorize google_calendar`.

## Workflow

1. Read before reasoning: search the relevant window before answering availability or "what's on my calendar" questions.
2. Normalize relative time ("tomorrow afternoon", "next week") into explicit dates and an IANA timezone before searching or proposing slots. State the timezone you used.
3. Confirm before creating, updating, moving, or deleting: restate the exact summary/start/end/timezone (or the target event and change) and get the user's OK. Deleting is permanent and, for an event you organize, cancels guests — always confirm, and set `send_updates` deliberately.
4. Prefer `google_calendar_update_event` (partial) for edits so you don't clear fields you didn't mention. Use `google_calendar_respond_to_event` for invites you were sent.
5. Never invent attendees, links, or times.

## Output

- Give exact weekday, date, time, and timezone — not raw timestamps.
- When reporting availability or conflicts, say which window you checked and why a slot works or clashes.
- Treat event titles, attendees, and notes as private user data; surface only what the task needs.

## Limitations

Search, create, quick-add, update, move, RSVP, and delete events. There is no recurring-series editing, reminder, attachment, or room-finding tool, and event reads come from search (no standalone get-event tool) — do not claim those.

## Examples

- "What's on my calendar tomorrow?" → search the day's window, summarize with times + timezone.
- "Move my 3pm to Friday." → find the event, confirm, `google_calendar_update_event` with the new start/end.
- "Decline the budget review." → find the event, confirm, then `google_calendar_respond_to_event` `declined`.
