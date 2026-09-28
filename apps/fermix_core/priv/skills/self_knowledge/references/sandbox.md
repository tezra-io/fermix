# Sandbox

The sandbox bounds what the file, image, search, git, attachment and shell tools reach. It does not limit plugins, web search, memory or provider calls, and it sets computer use's `access` (`strict` is look-only). One gap: a shell command is checked only for the folder it runs in and for destructive patterns, not for the files it names, so a command run from an allowed folder can still read `~/.ssh` as the owner.

## Modes and roots

| Mode | Roots |
|---|---|
| `strict` | the workspace (`~/.fermix/workspace`) + grants. Not the skills folder: a skill that uses its own files needs `/grant path ~/.fermix/skills`. |
| `standard` (default) | the workspace, `~/.fermix/skills`, grants, and, when strictly inside the OS home, the folder the daemon started in and the folder the request came from (where `fermix ask` ran, or an ACP session's working directory) |
| `open` | all of `$HOME`, minus protected paths |

- The request folder counts only on a trusted local operator turn; remote channels and guests get the workspace, the skills folder, the start folder and grants. A background service (the Mac app, launchd, systemd) starts in `/` or the home folder, so there only a `fermix ask` or ACP folder adds anything. The home folder itself is never a `standard` root.
- Roots live in `[sandbox]`: `workspace_root`, `allowed_roots` (grants), `blocked_roots` (wins inside a grant or mode root).

## Always refused

- **Protected paths**, in every mode and even inside a grant (file, search and git tools cannot open them; no shell command runs from inside one): `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.docker`, `~/.kube`, `~/.codex` (or its configured home), `~/.anthropic`, `~/.config/fermix` (a Linux service's env file), Claude Code's `~/.claude.json` and the `.credentials.json`/`.claude.json` in its config folder (the rest of `~/.claude` stays reachable); Fermix's `config.toml`, `auth.json`, `secrets/`, `secret_key_base`, `setup-token`, `setup-launch-token.json`, `acp_identities/`, `mobile/`, `plugins/run/`, `browser/profiles/`, `bootstrap/`, `memory.db`, `grants/`, `logs/`, `traces/` and its sockets; OS roots (`/etc`, `/usr`, `/bin`, `/sbin`, `/System`, `/Library`). Names match with a `.` or `-` suffix (`memory.db-wal`) and case-insensitively (`~/.SSH`). A grant for a protected path, the home folder, the Fermix home or `/` is refused as `unsafe_root`.
- **Catastrophic commands**, before any shell command runs: recursive delete of a protected root, `mkfs`, `dd of=/dev/…`, a fork bomb, mass kill, shutdown or reboot, `sudo -S`. A pattern check for common mistakes, not a complete boundary.

## Changing it

| Setting | Mac Settings > Sandbox | Browser setup, Sandbox tab | Chat | Terminal (Linux, dev) |
|---|---|---|---|---|
| Mode | **Sandbox** | **Mode** | `/sandbox mode MODE` | `fermix sandbox mode MODE` |
| Command profile | **Command profile** | **Command profile** | `/sandbox commands profile PROFILE` | `fermix sandbox commands profile PROFILE` |
| Presets | none | none | `/sandbox commands enable\|disable PRESET` | `fermix sandbox commands enable\|disable PRESET` |
| Folder grants | none | none | `/grant path PATH`, `/revoke path PATH` | `fermix grant\|revoke path PATH` |
| Allowed variables | **Allowed environment variables** | **Allowed env names** | `/sandbox env allow\|deny NAME` | `fermix sandbox env allow\|deny NAME` |

- Mac app and browser setup changes to mode and profile need a restart; variable changes apply to the next command. Chat changes apply at once (after `/confirm` where one is asked). A terminal edit reaches a running daemon only after a restart; on an app-managed home it also makes the app refuse saves until **Reload settings from disk**, so on a Mac use the app or chat.
- The Mac pane's one-line mode hints are approximate; the table above is what each mode reaches.
- Inspect: `/sandbox status|explain`, `fermix sandbox status`, `fermix sandbox explain` (each root marked `(granted)` or `(mode)`, plus the protected paths).

## What needs `/confirm`

A change that adds a root, an allowed variable, a preset or a command asks for `/confirm TOKEN` first; one that only removes applies at once. Leaving `open` for `strict` or `standard` asks, because the new roots are named differently from `open`'s single `$HOME` root. `standard` to `strict` applies at once. `/sandbox commands profile` never asks, even when it switches on presets already listed.

## The directory-approval loop

- When a filesystem call is refused as outside the roots and the task genuinely needs that folder, the agent calls `request_directory_access`, only in an attended operator turn. Guests, scheduled jobs, sub-agents and unattended runs never get it, and it never asks for a path it would refuse (`$HOME` wholesale, the Fermix home, `~/.ssh`, OS roots).
- The owner sees the canonical path, the reason and the config diff, and answers `/confirm TOKEN` or `/deny TOKEN` (a visible refusal that discards the grant). Tokens are single-use, bound to that conversation, owner-only and expire in 60 s; a `/confirm` from a process Fermix started is refused. On Telegram and Discord the prompt also has **Approve**/**Deny** buttons that deliver the token privately, and a group chat's text leaves the token out (button mechanics: `channel_presentation` reference).
- On confirm the grant persists to `[sandbox] allowed_roots`. On a chat channel the original request resumes by itself; on the one-shot CLI the owner re-runs it.
- The same prompt also acknowledges a coding agent's config change and holds an access-sensitive plugin command.

## Command profiles and presets

- Profiles: `bare` (default: no presets), `assistant` (presets you turn on are available), `extended` (same as `assistant`).
- Presets: `ai_tools` (`codex` with `OPENAI_API_KEY`, `claude_code` with `ANTHROPIC_API_KEY`) and `dev_tools` (`git`, `gh`, `make`). A preset command appears only when its executable is on the daemon's `PATH`, and every name it passes (`pass_env`) must be on the allowed list or the call fails.
- A single command: a `[sandbox.commands.<name>]` block (`command` required; `args`, `pass_env`, `timeout_ms` default 30000, `description`, `enabled` default true) or `fermix sandbox grant command NAME -- CMD [ARGS...]`; available under every profile, `bare` included. `fermix sandbox command list` lists them.

## Diagnosing

Every refusal is written to the day's `sandbox_event.jsonl` trace. Doctor's sandbox trace check (in the Mac app's **Doctor**, or the `sandbox traces` row of `fermix doctor`) reads the last 7 days and names each refused folder with the grant that would allow it. `outside_root` means approve or grant the folder; `protected_path` cannot be granted.
