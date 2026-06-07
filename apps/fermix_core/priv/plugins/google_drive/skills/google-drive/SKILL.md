---
name: google-drive
description: Search Google Drive and create folders, upload files, rename, move, or copy files through the Fermix Google Drive plugin.
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

Search uses a read-only scope; the create/edit tools use the `drive` scope. If a tool's scope wasn't granted at sign-in, it returns a "reauthorize" error — tell the user to run `fermix plugins auth reauthorize google_drive`. There is no trash, delete, or share tool right now (withheld pending a runtime approval gate).

## Workflow

1. Find before acting: use `google_drive_search_files` to locate the file and get its `id` before renaming, moving, or copying.
2. Confirm edits to existing files: restate the file and the change before `google_drive_update_file` or `google_drive_move_file`.
3. To move a file, pass the destination as `add_parent_id` and the current folder as `remove_parent_id` so it relocates rather than living in two folders.
4. There is no delete, trash, or share tool — if asked to delete or share, say it isn't available yet rather than improvising (e.g. don't fake a delete by moving the file somewhere hidden).
5. Treat file names, contents, and links as private user data.

## Limitations

Search, create folders, upload text files, rename, move, and copy. It cannot delete, trash, or share files (those are withheld pending a runtime approval gate), uploads text content only (no binary upload, no replacing an existing file's content), does not export Google Docs/Sheets/Slides, and does not manage revisions or comments — do not claim those.

## Examples

- "Make a 'Receipts 2026' folder." → `google_drive_create_folder` name "Receipts 2026".
- "Rename the Q3 plan to 'Q3 plan (final)'." → find the file, confirm, then `google_drive_update_file`.
- "Share the Q3 plan with dana@acme.com." → not available yet; say so (there is no share tool).
