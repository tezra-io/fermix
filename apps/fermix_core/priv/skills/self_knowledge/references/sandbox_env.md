# Sandbox environment passthrough

How allowed environment variables reach sandboxed commands, and what happens when one cannot be read.

## What is passed

A sandboxed `shell` command runs with a minimal child environment: `PATH`, `HOME`, `USER`, `LANG`, `SHELL`, `TMPDIR`, the `LC_*` keys, plus every name on `[sandbox.env] allow`. Each allowed name is read from the daemon's own process environment, or, when the name has a `source = "command"` entry, from the helper that entry names (`fermix sandbox env set NAME -- <helper> [args...]`, for example a keychain lookup), fresh on every command. `[sandbox.env] mode = "all"` passes the whole daemon environment minus the deny list when nothing is named.

A background service never reads a shell profile. A variable exported only in `~/.zshrc` reaches a daemon started from that shell (`mix fermix.dev`) and never one started by launchd or systemd, so on a service the value has to come from a `command` helper or be stored where the service reads it.

## An allowed name the daemon cannot read

It is never a reason to refuse the command. Every allowed name resolves on its own, the command runs with the ones that resolved, and the miss is reported on every surface:

- the tool result opens with a note naming the variable and the remedy sentence, on success and on failure alike;
- the `tool_exec` trace carries `env_unresolved` (names only, so a content-free export still shows it) and never `policy_enforcement`, because nothing was denied;
- the daemon log gets one line when a name stops resolving and one when it resolves again, not one per command;
- readiness shows an advisory failure in the Sandbox pane, `sandbox:env_missing` (not set where Fermix runs) or `sandbox:env_helper_failed` (the helper failed), one row per cause naming every variable, from boot, from every config apply, and from every shell command, until the value resolves or the name leaves the allow list. Advisory: it never marks setup unfinished. The record lives in the daemon, so the app's Home, Settings and Doctor see it; a `fermix doctor` run from a shell is a separate process with no view of it and shows nothing for this.

A name a consumer requests for itself is different: a coding-agent adapter's declared variable or a command capability's `pass_env` is a requirement, and one that cannot be read fails that run or command with the reason.

## Fixing it

Store the value where the daemon can read it. On macOS, `security add-generic-password -a fermix -s fermix:NAME -w '<value>' -U` puts it in the login keychain, then `fermix sandbox env set NAME -- /usr/bin/security find-generic-password -a fermix -s fermix:NAME -w` makes the sandbox read it from there; or drop the name with `fermix sandbox env unset NAME`. From a chat, `/sandbox env set NAME -- <helper> [args...]` and `/sandbox env unset NAME` do the same inside the running daemon, and the app's Sandbox settings edit the allow list. On an app-managed home a standalone `fermix` writes the settings file from outside the daemon, which then refuses its own writes until settings are reloaded, so prefer the chat command or the app there.
