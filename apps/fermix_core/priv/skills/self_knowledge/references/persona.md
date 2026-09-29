# Persona, prompt files and personalization

## About you and the assistant's name

- Values: the owner's name, time zone and communication style, plus the assistant's own name.
- A fresh home's first boot seeds them from the machine (the system time zone, the account's full name, the Balanced style); a fact the machine cannot give is left unset, never invented. A missing value is a nudge ("Tell Fermix about you"), not a setup blocker.
- Change them: Mac Settings > Personality > About you (**Your name**, **Time zone**, **Style**, **Call the assistant**); browser setup; the terminal wizard (`fermix setup`), which offers the machine's time zone as the default. No setup flag or env var sets them; a headless install writes `[fermix_core.personalization]` `user_name`, `timezone`, `communication_style` in `config.toml`.
- The assistant's name is identity, not a preference: it lives in `[fermix_core.agent] name` (default `fermix`), seeds `IDENTITY.md` (the first block of the system prompt) and is written into its `**Name:**` line on every daemon start, so a changed name takes effect after a restart. A blank name and any other edit to `IDENTITY.md` are left alone.
- Each turn and each scheduled run carries today's date (UTC, labelled with the configured time zone), so the agent never runs `date` just to know the day. Date only: a clock time would break provider prompt caching every turn. The precise time comes from `date`.

## Prompt files

`bootstrap/main/{IDENTITY,FERMIX,SOUL,REALTIME,LIVE}.md` and `memory/main/{USER,MEMORY}.md` under `FERMIX_HOME` (default agent id `main`).

- Seeded by the first boot and by every setup save, per file, never overwriting a file that exists. A personalization save rebuilds `USER.md` from memory.
- `USER.md` and `MEMORY.md` belong to memory: the background review rebuilds them from memory rows, and the start-up reconcile never touches them.
- On every daemon start the four variable-free files (`FERMIX`, `SOUL`, `REALTIME`, `LIVE`) are reconciled: one still equal to its recorded baseline (the seed, an earlier adoption, or a `/soul reset`) is rewritten to the template this build ships, as a revertable `template_adopt` revision, so an upgrade reaches an install that never edited its defaults. A file the owner edited is kept and named in the boot log. A file with no baseline record is kept.
- The Doctor `bootstrap templates` row (the Mac app's Doctor, answered by the daemon) reports each file: current, customized while the shipped template moved on (diff yours, or `/soul reset` for `SOUL.md`), pending adoption until a restart on the new build, or no baseline record. A terminal `fermix doctor` on a standalone or package install reads `skipped (memory repo unavailable)`.

## `/soul`: curating `SOUL.md`

Owner-only and never autonomous; every subcommand is operator-only, even for an allowlisted guest.

| Command | Does |
|---|---|
| `/soul` | reports the current revision |
| `/soul review` | drafts a subtle, voice-preserving edit within a small change budget; declines when nothing warrants a change |
| `/soul review <instruction>` | drafts the explicit change asked for, unbounded |
| `… --with-context` | adds a bounded window of the owner's own recent messages as evidence (guest turns excluded) |
| `/soul diff TOKEN` | shows a pending proposal again |
| `/soul apply TOKEN` | applies it |
| `/soul deny TOKEN` | discards it |
| `/soul history` | lists revisions |
| `/soul revert N` | proposes rolling back to revision N |
| `/soul reset` | proposes the shipped default |

A draft is one bounded provider call with no tools that never writes; it returns a diff and rationale, and flags prompt-injection markers found in its sources. Every change, including a revert or reset, is a proposal that takes effect only with `/soul apply TOKEN`; a token lasts 5 minutes. Every write is a versioned, revertable revision. An edit to `SOUL.md` made outside `/soul` is recorded as an `unreviewed_edit` revision, and the owner's private chat gets one line naming the `/soul revert N` that undoes it. The draft run emits `[:fermix, :soul_curation, :run_start|:run_complete|:run_error]` under its own `session_id`.
