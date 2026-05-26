---
name: google-drive
description: Find Google Drive files and inspect file metadata through the Fermix Google Drive plugin (read-only).
---

# Google Drive

Use this skill when the user wants to find files in Google Drive or inspect Drive file metadata through Fermix.

## Tool

- `google_drive.search_files` (read-only) — search Drive by file name. Args: `query`, `max_results` (default 10), `include_trashed` (default false). Returns metadata (name, type, link, modified time).

## Workflow

1. Prefer `google_drive.search_files` for file discovery; pass a focused `query`.
2. If the user gives no useful search terms, ask for a narrower query rather than dumping a broad list.
3. Treat returned Drive links and metadata as private user data; summarize only what the task needs.

## Limitations (M7.5)

Read-only and metadata-focused. This plugin can find files and report metadata only. It cannot read full file contents, edit, create, move, share, export, or delete files, and it does not handle Google Docs, Sheets, or Slides — do not claim or attempt those.

## Examples

- "Find my Q3 planning doc." → `search_files` query "Q3 planning", summarize matches with links.
- "Anything recent named 'budget'?" → `search_files` query "budget", report names + modified times.
