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

On macOS the kernel (Seatbelt) holds the commands a turn runs (the shell, git
and operator-declared command tools; not coding agents or plugin processes) to
the sandbox mode and keeps Fermix's own secrets out of their reach. Linux has no
kernel confinement yet: a command is checked only for the folder it starts in
and for catastrophic patterns, so it can read and send whatever the account can.
Until that lands, a command (shell, git writes, operator-declared commands) in a
turn that has read content someone else could have written — a web page, a
plugin's or MCP server's result, a worker's report, an attachment, the Recent
Activity note — waits for the owner's own confirmation, and never runs from a
delegated worker, a cue-woken task or another unattended run; a scheduled job
runs one only when its allowlist names it. The `codex` and `claude_code`
command presets and the local coding runs (`codex_run`, `claude_code_run`)
start a vendor CLI with the owner's account authority outside the sandbox
everywhere, so they wait the same way on macOS, and the owner's confirmation
shows every argument the vendor CLI is handed; once confirmed, a coding run
still meets its own authorization, consent and vendor-config checks.
The same gate holds access-sensitive plugin commands (a car unlock) on every
platform.

What this deliberately does not cover:

- Only the turn that read the content waits. Replayed history on a later turn,
  and memory, skills or a job's task that a tainted turn wrote, run clean later.
  A tainted turn cannot set up, change or run now a job whose tools would
  include such a command (one naming it, one with no allowlist, or one that can
  start a skill or manage jobs), but a job it creates with narrower tools runs
  them freely. With the coding runs set up this holds on macOS too: such a job
  could start one. A request that runs again after the owner's `/confirm` (a
  directory grant, a coding-agent config acknowledgment) is the same request
  and keeps what it had read.
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
- A voice note is treated as the owner's own words when the channel declares it
  a voice recording. A forwarded Telegram or WhatsApp voice note is not, but a
  forwarded Telegram video note still is, and a phone app that sends its
  recordings as plain audio files gets no exemption.

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

Also out of scope: the operator's own model provider (reached over TLS with the
operator's own key), and GitHub itself for release distribution — the upgrade
path pins the release origin and verifies a keyless cosign signature, which
bounds tampering in transit, not a compromise of the platform hosting it.
