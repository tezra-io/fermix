# Security Policy

## Supported versions

Fermix is pre-1.0 (alpha). Security fixes land on `main` and ship in the next
release. Always run the latest release.

| Version       | Supported |
| ------------- | --------- |
| latest `0.x`  | ✅        |
| older `0.x`   | ❌        |

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately by email to **[security@tezra.io](mailto:security@tezra.io)**.
The same address covers every Fermix repository: the engine, the macOS, Linux
and Android apps, the sidecars and the plugins.

Please include:

- a description of the issue and its impact,
- steps to reproduce (or a proof of concept),
- the affected version / commit, and
- any suggested remediation.

We aim to acknowledge reports within a few days and will coordinate a fix and
disclosure timeline with you. Never include real secrets (API keys, tokens) in
a report — redact them.

## Scope

Fermix runs as a local daemon that holds provider API keys and bot tokens,
executes a workspace-rooted command/path sandbox, and bridges external chat
channels. Areas of particular interest:

- secret handling (config, env passthrough, `auth.json`),
- the sandbox and its allow/deny policy,
- inbound/outbound MCP and channel ingress authorization,
- the signed `fermix upgrade` path.

The kernel holds the commands a turn runs (the shell, git and
operator-declared command tools; not coding agents or plugin processes) to the
sandbox mode and keeps Fermix's own secrets and keys out of their reach:
Seatbelt on macOS, Landlock on Linux. A Linux kernel without Landlock ABI 3
(Linux 6.2) runs none of them: ABI 2 cannot refuse a truncate, so a command
could empty a file it may only read. Where the kernel has them, Landlock also
refuses a command's ioctls on every device but a terminal (ABI 5, Linux 6.10)
and its signals and abstract unix socket connections to anything outside its
sandbox (ABI 6, Linux 6.12). Each command runs in a session of its own, so it
cannot push input into the terminal of a `fermix` started by hand. Landlock
cannot refuse a connection to Fermix's local sockets, so on Linux those keep
only their own peer checks.
Where the kernel does not hold commands, a command (shell, git writes,
operator-declared commands) in a turn that has read content someone else could
have written — a web page, a plugin's or MCP server's result, a worker's
report, a forwarded message, an attachment, the Recent Activity note — waits
for the owner's own confirmation, and never runs from a delegated worker, a
cue-woken task or another unattended run; a scheduled job runs one only when
its allowlist names it. The `codex` and `claude_code` command presets and the
local coding runs (`codex_run`, `claude_code_run`) start a vendor CLI with the
owner's account authority outside the sandbox everywhere, so they wait the
same way on macOS and Linux, and the owner's confirmation shows every argument
the vendor CLI is handed; once confirmed, a coding run still meets its own
authorization, consent and vendor-config checks.
The same gate holds access-sensitive plugin commands (a car unlock) on every
platform.

Every Always On step is one method, `home.act`: opening a code for the
owner's server, starting a move, moving back and restoring here are owner
decisions, refused to a command Fermix started and to a caller Fermix cannot
place, in words that name every place the owner can act (the Fermix app, the
setup page or their own terminal). A step runs only when the summary it was
drawn from still offers it under its key, so a confirm accepted on an older
screen does nothing. Its input (the recovery passphrase) is decoded where it
arrives into a struct whose inspection withholds it, so no log line, crash
report or telemetry event carries it, and the setup page's request logs
filter any parameter named for a passphrase. On the setup page a passphrase
lives only in the submitted form and the one step it becomes: every such
field is drawn empty and replaced after each submit, none is kept in the
page's state, and the one-time code for the owner's server is held where no
crash report prints it and copied from the page, never sent back in an
event. `fermix always-on` takes the recovery passphrase only from a prompt
that does not echo or from a file, refuses it typed as an argument, and holds
it in that struct until the one request that sends it. Cloud-init user data
that carries an enrollment code stays readable through the metadata service,
which the server's first boot blocks for every account but root. The
server's own Always On steps (opening a code, closing it, reviewing and
starting a move, a backup now) are served only to a linked desktop's forward
over the rail, sent by that desktop's own `home.act` after it placed its
caller as the owner; on `daemon.sock` they are refused to every caller, by
name. So when the desktop moves the home back, the server opens its code only
for that desktop, the code crosses only that encrypted session, and no local
command can open, close or use one. The command for the owner's server
carries no code: its first boot asks for the code on the terminal without
echo, so it never lands in a shell history.

Opening the setup page is an owner decision on `daemon.sock` as well: a page
session drives every decision the page offers, so `setup.session.create` is
refused to a command Fermix started and to a caller it cannot place. The Mac
app's agent opens the page, and `fermix setup` mints its one-time link in its
own process.

The recovery passphrase typed for an Always On move is checked against the
recovery key the primary keeps (derived under that key's own salt, it must
give its public half), so a mistyped passphrase is refused rather than
becoming the key the server's snapshots are encrypted to, and a move never
mints a second key; with none kept, the move sets one. The passphrase lives
only inside that check: never stored, logged, answered or carried in an error.

Moving back to the computer the home left keeps one primary at a time the
same way a move does: the server writes its moved marker before it lets the
computer put the home in place, and the computer removes its own marker only
then, its settings naming it the primary last. The secrets come back into
that computer's keychain by value, under the settings' profile, replacing
whatever stale item was there. Restore here, which takes the home back from
the computer's own copy of the server's backups when the server cannot be
reached, deletes nothing: it is offered only once the server has been
silent for ten minutes (or no link runs; a server that answers is never
silent), and its confirm asks the owner's word that they deleted the server,
or stopped it for good, since a copy restored beside a running server would
answer the same channels twice. The passphrase opens the copy only in memory, for the
restore's length: the derived key is never written, and a passphrase that
opens no copy is refused before anything is written.
Fermix never deletes the server, which is the owner's own: nothing the
computer can check would prove it is down.

What this deliberately does not cover:

- Only the turn that read the content waits. Replayed history on a later turn,
  and memory, skills or a job's task that a tainted turn wrote, run clean later.
  A tainted turn cannot set up, change or run now a job whose tools would
  include such a command (one naming it, one with no allowlist, or one that can
  start a skill or manage jobs), but a job it creates with narrower tools runs
  them freely. With the coding runs set up this holds on macOS too: such a job
  could start one. A request that runs again after the owner's `/confirm` (a
  directory grant, a coding-agent config acknowledgment) is the same request
  and keeps what it had read. Two things carry it further: an open loop noted
  in such a turn is marked, and the later turn its due note rides, or that
  lists, settles or notes it again, counts as having read outside content; and
  on a GPT-Live or Grok voice call, once one task has read it, every later task
  of that call has.
- A finished coding run reports back as a follow-up turn, which may start the
  next run of the chain without asking (the owner's choice): with the same
  coding agent and the same starting folder as the run that finished, once per
  finished run (a resumed or later turn included), while that run's report is
  all it has read, and with nothing but its task, folder, model, effort and
  limits. The starting folder is not a boundary: a coding agent reads whatever
  the owner's account can, and Codex's read-only and workspace-write modes
  still read the whole disk. The chain stops after three follow-ups; any other
  run from that turn is refused.
- In a shared Buzz channel, the other members' messages are not outside content
  for commands (the owner's choice: a Buzz session replies through the shell);
  they still hold access-sensitive plugin commands.
- A file on disk is read as the owner's, whoever wrote it: a file, an image,
  a search result or git history read from a folder the owner works in, an
  attachment an earlier turn saved included, leaves the turn clean, as a
  command's own output does. Marking them would not hold, since a command can
  read the same bytes, and it would make a coding run wait in nearly every
  turn that first looked at a file. A coding run reads the same repository
  with the owner's account anyway, and a build or test runs its scripts, so a
  repository someone else wrote is trusted as far as the owner trusts running
  it. A shell or git command is held by the kernel: Seatbelt on a Mac, and on
  Linux Landlock ABI 3 or later (Linux 6.2), where a kernel without it runs
  no command; a coding run stays unconfined on either.
- A voice note or Telegram video note is treated as the owner's own words when
  the channel declares it a recording and does not mark it forwarded; a
  forwarded one counts as outside content. A phone app that sends its
  recordings as plain audio files gets no exemption.
- Telegram and WhatsApp mark a forwarded message, text or recording, and it
  counts as outside content, also when it runs again after a `/confirm`. The
  model reads its text under a `[forwarded message]` label, it is never taken
  as the owner's command, and the memory review never reads it as the owner's
  words. The other channels do not mark forwards yet, so a message forwarded
  there reads as the owner's own.

### Out of scope

Fermix defends the operator's account, not the machine against its own users. A
second local account that can already run `ps`, read another user's process
environment, or write into their home directory is outside this boundary — it is
assumed to be the operator or to have already defeated the OS. Reports whose only
mechanism is "another local user could observe or tamper with this" are therefore
not treated as vulnerabilities.

This is a boundary, not an excuse for sloppiness: `auth.json` is `0600`,
`$FERMIX_HOME` is `0700`, secrets are read from a prompt or stdin rather than
from `argv`, and temp files are created exclusively with private modes. Those
reduce blast radius. They are not a claim to withstand a hostile local account.

Also out of scope: the hosting provider of an Always On server, which can
technically read the server's disk. Fermix adds no disk encryption there, since
a server that restarts on its own would keep the key on the same disk; it keeps
less there instead (the bodies in its traces about a day, through the previous
UTC day) and encrypts what leaves
it: snapshots to the recovery key, whose private half the server never holds,
and every link to the phones and the desktop.

Also out of scope: the operator's own model provider (reached over TLS with the
operator's own key), and GitHub itself for release distribution — the upgrade
path pins the release origin and verifies a keyless cosign signature, which
bounds tampering in transit, not a compromise of the platform hosting it.
