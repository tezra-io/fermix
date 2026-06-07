---
name: google-drive
description: Search Google Drive and create folders, upload files, rename, move, copy, share, trash, or delete files through the Fermix Google Drive plugin.
---

# Google Drive

Use this skill when the user wants to find files in Google Drive or inspect Drive file metadata through Fermix.

## Tools

Read:
- `google_drive_search_files` (read-only) — search by file name. Args: `query`, `max_results` (default 10), `include_trashed` (default false). Returns metadata (name, type, link, modified time).

Create:
- `google_drive_create_folder` — make a folder. Args: `name`, optional `parent_id`.
- `google_drive_upload_file` — create a file with text content. Args: `name` (with extension), `content`, optional `mime_type` (default text/plain), `parent_id`.

Edit & organize:
- `google_drive_update_file` — rename a file. Args: `file_id`, `name`.
- `google_drive_move_file` — move a file. Args: `file_id`, `add_parent_id` (destination), optional `remove_parent_id` (current folder).
- `google_drive_copy_file` — copy a file. Args: `file_id`, optional `name`, `parent_id`.
- `google_drive_trash_file` — move to Trash (or restore with `restore: true`). Args: `file_id`.
- `google_drive_delete_file` — permanently delete (no Trash, irreversible). Args: `file_id`.

Share:
- `google_drive_share_file` — grant access. Args: `file_id`, `role` (reader | commenter | writer), `type` (user | group | domain | anyone), optional `email_address`, `domain`, `send_notification_email`.

All tools use the `drive` scope (full read/write). If it wasn't granted at sign-in, a tool returns a "reauthorize" error — tell the user to run `fermix plugins auth reauthorize google_drive`.

## Workflow

1. Find before acting: use `google_drive_search_files` to locate the file and get its `id` before editing, moving, sharing, or deleting.
2. Confirm before destructive or outward-facing actions: always confirm before `google_drive_delete_file` (permanent), `google_drive_trash_file`, and `google_drive_share_file` — restate the file and, for sharing, exactly who gets what access. Public (`type: anyone`) or external sharing deserves an explicit warning.
3. Prefer trash over delete: use `google_drive_trash_file` (recoverable) unless the user explicitly asks to permanently delete.
4. To move a file, pass the destination as `add_parent_id` and the current folder as `remove_parent_id` so it relocates rather than living in two folders.
5. Treat file names, contents, and links as private user data.

## Limitations

Search, create folders, upload text files, rename, move, copy, trash/restore, permanently delete, and share. It uploads text content only (no binary upload, no replacing the content of an existing file), does not export Google Docs/Sheets/Slides, and does not manage revisions or comments — do not claim those.

## Examples

- "Make a 'Receipts 2026' folder." → `google_drive_create_folder` name "Receipts 2026".
- "Share the Q3 plan with dana@acme.com as editor." → find the file, confirm, then `google_drive_share_file` role writer / type user / email_address dana@acme.com.
- "Delete that draft." → find it, confirm a permanent delete, then `google_drive_delete_file` (or trash if unsure).
