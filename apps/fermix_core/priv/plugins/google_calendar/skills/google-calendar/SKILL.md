---
name: google-calendar
description: Inspect Google Calendar, check availability, summarize schedules, and create events (with confirmation) through the Fermix Google Calendar plugin.
---

# Google Calendar

Use this skill when the Google Calendar plugin is enabled and connected. It turns calendar data into clear scheduling answers and safe event creation.

## Tools

- `google_calendar_search_events` (read-only) — find events. Args: `query`, optional `calendar_id` (default `primary`), `max_results` (default 10).
- `google_calendar_create_event` (write; requires the `events_write` permission profile) — add an event. Args: `summary`, `start`, `end` (ISO 8601), optional `description`, `calendar_id`, `time_zone` (IANA).

If only `readonly` is granted, `google_calendar_create_event` is unavailable — tell the user to reconnect with "Create and update events" to write.

## Workflow

1. Read before reasoning: search the relevant window before answering availability or "what's on my calendar" questions.
2. Normalize relative time ("tomorrow afternoon", "next week") into explicit dates and an IANA timezone before searching or proposing slots. State the timezone you used.
3. Keep searches bounded — focused `query`, small `max_results`; widen only if needed.
4. For create requests, confirm the exact summary, start, end, and timezone with the user before calling `google_calendar_create_event`. Never invent attendees, links, or times.

## Output

- Give exact weekday, date, time, and timezone — not raw timestamps.
- When reporting availability or conflicts, say which window you checked and why a slot works or clashes.
- Treat event titles, attendees, and notes as private user data; surface only what the task needs.

## Limitations (M7.5)

Read and create only. There is no update, reschedule, delete, reminder, recurring-series, or room-finding tool — do not claim those. If asked, say the plugin currently supports searching and creating events.

## Examples

- "What's on my calendar tomorrow?" → search the day's window, summarize with times + timezone.
- "Am I free Thursday 2–4pm Pacific?" → search that window, report conflicts.
- "Add a 30-min sync Friday 10am Pacific." → confirm details, then `google_calendar_create_event` (needs `events_write`).
