# Open loops

An open loop is an intention the owner stated, with a date by which it matters, that they have not reported closing. Fermix records it at the turn where the owner says it, keeps it as its own row in `~/.fermix/memory.db` (never a memory fact, never an event), raises it at most three times at moments it judges receptive, and lets the owner's answer settle it. It is a different thing from a reminder: the owner asked for a reminder, while a loop is something Fermix noticed from the owner's own words.

## Turning it on

- One key, `[fermix_core.open_loops] enabled`, off by default. Browser setup's Personalization page has the toggle beside skill curation, and `config.toml` can set it on Linux and dev installs. No Mac Settings pane sets it yet. Restart after changing it: the part that raises loops on its own starts only when Fermix starts.
- Everything else (checks, windows, caps, active hours) is a fixed constant, not a setting.
- Off, no open-loop tool is offered anywhere, the prompt says nothing about loops, and stored loops are neither noted nor raised.

## What becomes a loop

- `open_loop_note` records it silently: the owner's own words for what they mean to do or decide, the date by which it matters (a date, a datetime, or a relative number of days or weeks, resolved in `[fermix_core.personalization] timezone` unless the owner names a zone), and the stakes when they stated any. The reply says nothing about it unless the owner asks.
- Not a loop: a question about a date, someone else's deadline, a hypothetical, an occasion that arrives whether or not the owner acts, a date read in tool output or fetched content, anything a guest or a group chat says, or something Fermix itself owns. A timer or a yearly date is refused; that is a reminder (`event_store`).
- A loop, not also a reminder: something the owner has to do by a date, said without asking to be reminded, is recorded as a loop only, never also as an event. The exception is a loop under 48 hours away: it is never raised by message, so the agent stores the reminder too, and when the owner settles that task (done, or no longer needed) it settles both. A date too close to raise at least three hours after it was said records no loop, and the agent stores the reminder instead.
- One loop per intention: the same intention stated again returns the stored loop.
- A loop needs somewhere the owner can answer: the owner's inbox (`[fermix_core.jobs] default_delivery_target`, else the owner DM an explicit owner id derives), snapshotted when the loop is recorded. With no chat inbox, or only this computer's notifications, nothing is recorded and the agent answers the owner's actual question.

## The tools

- `open_loop_note`, `open_loop_update` and `open_loop_list` run only on an attended, top-level owner turn: never for a guest, a scheduled job, a background or delegated run, or a coding continuation.
- `open_loop_update` answers: `done` closes it for good; `plan` with `plan_at` re-arms it at the owner's date and no earlier (never later than the loop's own date); `not_yet` keeps it open for one more check nearer the date; `stop` closes it and the owner is not asked about it again; `drop` stops tracking it with no boundary stated; `asked` records that this reply raised it. Every answer but `asked` carries `owner_words`, the owner's clause it rests on (at most 240 characters, never stored). A loop is settled from the owner's words only.
- `open_loop_list` (`state` `live`, `closed` or `any`) shows each loop's words, its date, when and where it was said, its state, how many times it has been raised and its next check, never a destination or a check-in's text. "What are you keeping an eye on?" lists them and "drop that" removes one.
- Refusals name their reason: `disabled`, `not_attended`, `missing_parameters`, `too_long`, `invalid_when`, `not_dated`, `date_passed`, `timezone_not_configured`, `no_target`, `too_many_loops`, `imminent_without_window` (the date is under three hours away), `no_conversation`; for an update also `not_found`, `not_live` (closed and expired loops never reopen), `already_asked`, `missing_owner_words`, `owner_words_too_long`, `plan_requires_date`, `plan_after_date`, `plan_passed`, `plan_at_without_plan` and `invalid_answer`.

## Lifecycle

- States: `open`, `due`, `asked`, `closed`, `expired`. Closed and expired are final; a new intention is a new loop.
- The checks follow how far off the date was when the owner said it: two weeks or more, 7 days before, the day before and the day after; 4 to 13 days, 3 days before, the day before and the day after; 2 to 3 days, one check at least 24 hours before and the day after; under 48 hours, only the in-chat note, from three hours after the owner said it (never in the conversation it came from) until the date passes. A check falls at the start of the owner's active hours on its day. The check after the date is the hand-back, which says plainly Fermix will not raise it again; unanswered, the loop expires quietly a day later.
- Active hours come from when the owner writes, over the last 28 days with guest messages left out: the middle of that spread, at least six hours wide. With fewer than 40 messages they are 09:00 to 21:00. There is no quiet-hours setting.
- Silence is not an answer: the next check follows on its own.

## Raising a due loop

- In the chat first: for three hours after a loop comes due (a loop under 48 hours away: from three hours after it was said until its date), every attended owner turn in a private chat, on any channel, carries a system note naming it, its dates and its id. The agent raises it in one or two sentences at the end of a reply only when the exchange has reached a natural stopping point and the owner is not under pressure, and records it as `asked`; otherwise it leaves it.
- Then on its own: when that window closes without a raise, one short check-in run decides, inside active hours and at most once a day across all loops (the nearest date first). It recalls memory, then sends one short message to the snapshotted inbox, stays silent, or closes the loop when memory shows the owner already reported it settled. The message opens with what the owner said and when, and is written into that chat's history, so the owner's reply lands in an ordinary turn that settles the loop.
- A raise counts only once its send is confirmed. A failed send or a provider outage changes no count and retries at a later active-hours start; a loop the owner settled while a check-in was running is not sent.

## Caps

- 3 raises per loop, ever, the hand-back included.
- 1 unprompted check-in a day across all loops.
- 20 live loops per owner; the 21st is refused.
- 2 check-in runs at a time; a run gets at most 6 model steps and 120 seconds, and a message at most 1,800 bytes, refused rather than cut when longer.

## What the check-in cannot do

- Its tools are `memory_recall`, `open_loop_list` and `open_loop_respond`, its one exit (`speak` with the text, `silent`, or `close` with a reason). It has no channel tools, no event, job or loop changes, no browsing, no delegation and no `memory_store`, and Fermix, not the run, sends its message.
- The surfaces never cross: an owner's turn is never offered `open_loop_respond`, and a check-in run is never offered `open_loop_note` or `open_loop_update`.
- Check-in runs and their outcomes show in the trace files: skill_view(name: "self-knowledge", file: "observability").
