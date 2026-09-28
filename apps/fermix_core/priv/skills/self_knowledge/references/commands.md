# Trust tiers and slash commands

## Trust tiers

- **Operator**: the channel's `owner_user_id`, or any local caller (`fermix ask`, the Mac app's sockets, an ACP client). Full surface.
- **Guest**: a sender on `allowed_*_ids`. The list authorizes chat only and never promotes to operator. A guest gets read-only chat: no skills, MCP, exec or network.
- Read-only bounds what a guest may do, not whose data comes back, so tools that return the owner's own data are never in a guest's surface, prompt or wire, nor dispatchable by name: workspace reads (`file_read`, `view_image`, `glob_search`, `content_search`, `git_read`), scheduled-job reads (`list_jobs`, `list_job_runs`, `get_job_run`), `send_attachment` and `memory_sources_list`. Tool discovery (`tool_search`, `tool_describe`, `tool_help`) is filtered by the same ceiling, so a guest cannot read the schema of a tool it cannot call.
- A sender on neither list gets no reply at all.

## Who may run each command

Commands are handled before the agent, in the ingress path, so `/stop` never waits behind the work it stops.

| Command | What it does | Who |
|---|---|---|
| `/help`, `/whoami` | list commands; show your stable channel user id | any allowed sender |
| `/compact` | compact this conversation now (auto-compaction runs after a reply at the threshold, default 0.85) | operator, or a guest on `command_allowlist` |
| `/new` (`/clear`) | start a fresh session in this conversation | operator, or allowlisted guest |
| `/pause`, `/resume` | hand the cursor and keyboard back from computer use; let it continue | operator, or allowlisted guest |
| `/tasks` | list running and recent background work | operator, or allowlisted guest |
| `/sandbox status\|explain\|mode\|env\|commands` | inspect or change the sandbox (`sandbox` reference) | operator, or allowlisted guest |
| `/grant`, `/revoke`, `/confirm`, `/deny` | directory grants and approval answers | operator only |
| `/soul` (every subcommand, including `status`, `history`, `diff`) | persona review (`persona` reference) | operator only |
| `/skills` (every subcommand) | skill-curation proposals (`skills` reference) | operator only |
| `/stop` | stop all running work daemon-wide | operator only |
| `/background` (`/bg`), `/ultra` | run a task in the background; exhaustive wide fan-out | operator only |
| `/history` (every subcommand) | computer history: `status`, `pause`, `purge`, `off` | operator only |

- `command_allowlist` never opens an operator-only command. An allowlisted guest therefore cannot grant directory access, read or rewrite the persona, stop work daemon-wide, or pick a run mode that multiplies the owner's provider spend.
- A guest's `/sandbox` change that needs no `/confirm` (removing access, re-sourcing an allowed env name) applies at once, daemon-wide. One that needs `/confirm` is never applied: its token is bound to the guest, who cannot run `/confirm`.
- **In person only.** `/sandbox` and its aliases, `/soul` and `/skills` also refuse a message from a process Fermix started (the agent's own shell command, a coding run) or a detached process with no terminal, even on a local socket, so the agent can never answer its own approval prompt. Every other command answers by role alone.

## What `/stop` settles

- It cancels every active turn that has not claimed its outcome, drops every queued message, stops background tasks, and cancels every coding run, including one a scheduled job started. The reply counts each.
- It does not reach a scheduled job's own run, a voice call, or a computer-use session: the session outlives the turn, and `/pause` is how the owner takes the machine back. A task a GPT-Live call handed to the agent is an ordinary turn, so `/stop` cancels it.
- Channels that track turn results (mobile, the companion socket, ACP, voice) are told each stopped turn and dropped message was cancelled, so a mobile or companion request is settled and not re-run at the next boot.
- A turn claims its outcome only once its reply is committed and any post-reply compaction has finished; from then on `/stop` leaves it to finish. A turn stopped before its final delivery neither delivers nor commits a reply. A stop after delivery but before the commit still ends the turn although the person saw the reply: history gets the marker below instead; during post-reply compaction the reply stays in history.
- The stopped turn's user message was stored at turn start, so the gateway appends a short assistant marker after it ("stopped before I finished … context only"): the request stays in history and memory, and the next turn does not replay and answer it. A crashed turn gets the same marker. The marker is added only when the conversation's last stored message is that orphaned user turn, so nothing is marked twice.
