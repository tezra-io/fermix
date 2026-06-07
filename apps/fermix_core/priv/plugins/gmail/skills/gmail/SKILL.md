---
name: gmail-plugin
description: Search, read, compose/send, draft, reply, label, and trash Gmail messages (confirming sends and trashing) through the Fermix Gmail plugin.
---

# Gmail

Use this skill when the Gmail plugin is enabled and connected. Turn mailbox searches into clear summaries and ready-to-send drafts; never change mail state without explicit intent.

## Tools

Read:
- `gmail_search_messages` (read-only) — search the mailbox. Args: `query` (Gmail search syntax), `max_results` (default 10). Returns one summary per match: `id`, `threadId`, `from`, `to`, `subject`, `date`, `snippet` (no body).
- `gmail_get_message` (read-only) — fetch one message's headers and decoded text body. Args: `id`. Returns `from`, `to`, `cc`, `subject`, `date`, `snippet`, `body`, plus `message_id` and `references` (needed to thread a reply).

Compose & send:
- `gmail_send_message` — send a new email. Args: `to`, `subject`, `body` (optional `cc`, `bcc`).
- `gmail_reply_to_thread` — reply inside a thread. Args: `thread_id`, `to`, `subject`, `body`; set `in_reply_to` (the original `message_id`) and `references` from `gmail_get_message` so it threads correctly.
- `gmail_create_draft` — create a draft without sending. Args: `to`, `subject`, `body` (optional `cc`, `bcc`, `thread_id`). Returns the draft `id`.
- `gmail_send_draft` — send an existing draft. Args: `id` (from `gmail_create_draft`).

Organize:
- `gmail_modify_message_labels` — add/remove labels. Args: `id`, `add_label_ids`, `remove_label_ids`. Mark read = remove `UNREAD`; mark unread = add `UNREAD`; archive = remove `INBOX`; star = add `STARRED`.
- `gmail_trash_message` / `gmail_untrash_message` — move a message to Trash / restore it. Args: `id`.
- `gmail_create_label` — create a label. Args: `name` (use `/` for nesting).

Write tools need their scope granted (`gmail.send`, `gmail.compose`, or `gmail.modify`). If a scope wasn't granted at sign-in, the tool returns a "reauthorize" error — tell the user to run `fermix plugins auth reauthorize gmail` and grant it.

## Workflow

1. Use Gmail query syntax for precision: `from:`, `to:`, `subject:`, `is:unread`, `newer_than:7d`, `has:attachment`, `label:...`, exclusions with `-`. Keep `query` focused and `max_results` small.
2. Summarize from the search summaries. Call `gmail_get_message` only when the snippet isn't enough — full content, an exact quote, or to get `message_id`/`references` for a reply.
3. Confirm before any state change. Draft `to`/`subject`/`body` and get the user's explicit OK before `gmail_send_message`, `gmail_reply_to_thread`, `gmail_send_draft`, or `gmail_trash_message`. Preserve exact recipients/subject from the source thread unless asked to change them; call out assumptions.
4. Prefer `gmail_create_draft` when the user wants to review before sending; reserve send/`gmail_send_draft` for explicit "send it" intent.
5. Label and read-state changes (`gmail_modify_message_labels`, `gmail_untrash_message`) are reversible — apply them on clear intent without a heavy confirmation gate.

## Output

- Reference the sender and timestamp of the message that matters most.
- State the search scope (e.g., "from the most recent 15 unread messages") and avoid absolute claims unless the scan was comprehensive.
- Treat message content as private user data; summarize only what the task needs.

## Limitations

Can search, read, compose/send, draft, reply, label, and trash/untrash. It does not permanently delete mail (trash only), download attachments, manage drafts beyond create + send, or fetch whole threads (reads are per-message). Do not claim those actions.

## Examples

- "Any unread from Acme this week?" → `gmail_search_messages` `is:unread from:acme newer_than:7d`, summarize.
- "Reply to Dana confirming Tuesday." → `gmail_get_message` for `message_id`/`references`, draft the reply, confirm, then `gmail_reply_to_thread`.
- "Archive that receipt and mark it read." → confirm the target, then `gmail_modify_message_labels` removing `INBOX` + `UNREAD`.
