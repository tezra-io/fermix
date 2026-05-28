---
name: gmail-plugin
description: Search and summarize Gmail messages, and draft or send mail (with confirmation) through the Fermix Gmail plugin.
---

# Gmail

Use this skill when the Gmail plugin is enabled and connected. Turn mailbox searches into clear summaries and ready-to-send drafts; never change mail state without explicit intent.

## Tools

- `gmail_search_messages` (read-only) — search the mailbox. Args: `query` (Gmail search syntax), `max_results` (default 10). Returns message summaries/metadata.
- `gmail_send_message` (write; requires the `send` permission profile) — send an email. Args: `to`, `subject`, `body`.

If only `readonly` is granted, `gmail_send_message` is unavailable — tell the user to reconnect with "Send mail" to send.

## Workflow

1. Use Gmail query syntax for precision: `from:`, `to:`, `subject:`, `is:unread`, `newer_than:7d`, `has:attachment`, `label:...`, exclusions with `-`.
2. Keep searches narrow and bounded — focused `query`, small `max_results`; refine before widening.
3. Summarize from the returned message summaries. Lead with the latest status, then decisions, open questions, and action items.
4. For send requests, draft first and confirm `to`, `subject`, and `body` with the user before calling `gmail_send_message`. Preserve exact recipients and subject from the source thread unless asked to change them; call out assumptions or missing facts.

## Output

- Reference the sender and timestamp of the message that matters most.
- State the search scope (e.g., "from the most recent 15 unread messages") and avoid absolute claims unless the scan was comprehensive.
- Treat message content as private user data; summarize only what the task needs.

## Limitations (M7.5)

Search and send only. There is no full-thread/body fetch, label, archive, trash, or draft-management tool — work from search summaries and do not claim those actions.

## Examples

- "Any unread from Acme this week?" → `is:unread from:acme newer_than:7d`, summarize.
- "Draft a reply confirming Tuesday." → draft, confirm, then `gmail_send_message` (needs `send`).
