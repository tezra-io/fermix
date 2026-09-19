# Sandbox environment passthrough

How allowed environment variables reach sandboxed commands, where their values are stored, and what happens when one cannot be read.

## What is passed

A sandboxed `shell` command runs with a minimal child environment: `PATH`, `HOME`, `USER`, `LANG`, `SHELL`, `TMPDIR`, the `LC_*` keys, plus every name on `[sandbox.env] allow`. Every allowed name reaches every shell command, the way a terminal's variables reach every process started from it: an interactive turn, a scheduled job, a `skill_run` and a delegated sub-agent alike. A skill written for another host that reads `ALPACA_API_KEY` from its environment needs no change. `[sandbox.env] mode = "all"` passes the whole daemon environment minus the deny list when nothing is named.

The list is the child's whole environment: the command is started with it in place of everything the daemon inherited, never as `env -i NAME=value` arguments, so no value appears in any process's argument list. Allowing a name is the permission. Any turn allowed to run `shell` receives the allowed values, and nothing isolates one skill's variables from another's.

Each value is read fresh on every command, from one of three places:

- **Stored in Fermix (managed).** Settings > Sandbox lists one row per allowed name. Add stores the pasted value in the OS secret store: the login Keychain on macOS (account `fermix`, item `fermix:external_env:NAME`, or `fermix:<profile>:external_env:NAME` under `[fermix_core] profile`), or the Secret Service on a Linux desktop. The config records the name with a `source = "command"` entry that reads that item back. The `external_env` item never shares a name with a provider key, so storing a skill's own `OPENAI_API_KEY` never touches Fermix's. Adding, replacing or removing a value takes effect on the next command, with no restart. Remove deletes the item and leaves the name allowed, now not stored.
- **An operator helper.** `fermix sandbox env set NAME -- <helper> [args...]` (or `/sandbox env set` from a chat) points the name at a command that prints the value, for example a password manager lookup. Settings shows such a name read-only.
- **The daemon's own environment.** An allowed name with no source, or `source = "env"` with an alias, reads the variable the Fermix service itself was started with. "Not stored" in Settings means exactly this: commands get the value only if the service was started with it.

A background service never reads a shell profile. A variable exported only in `~/.zshrc` reaches a daemon started from that shell (`mix fermix.dev`) and never one started by launchd or systemd, so on a service the value has to be stored in Fermix, come from a helper, or be in the service's own environment.

## A Linux server with no keyring

A headless host has no Secret Service, so Settings > Sandbox cannot store a value there (it answers that no secret store is available). The Linux service unit loads an optional environment file instead: `~/.config/fermix/env` for a user-scope unit and for the distribution package's unit, `/etc/fermix/env` for a system-scope unit. Write one `NAME=value` per line, allow the name, and restart Fermix: the file is read only when the service starts. Fermix never writes the file. A missing file is fine. A unit installed before the file existed picks the line up when `fermix setup` rewrites the drifted unit or `fermix service install` runs again; the package's unit carries it from the package.

A variable in the service's environment is inherited by every process the daemon starts without building a sandbox environment (a helper, an MCP server), the same exposure any service variable has.

## Redaction

Every value read for an allowed name, and every `pass_env` value a command capability receives, is scrubbed from what the command returns before anything else sees it: the tool result the model reads (which is also what the conversation keeps) and the `tool_exec` trace, metadata included, with content capture on or off. Each occurrence becomes `«redacted»`, and the scrub runs before any truncation, so a cut cannot leave half a value behind. Values shorter than 8 bytes are not scrubbed, because such a string occurs inside ordinary output. Matching is exact: a value the command encodes, hashes or transforms is not recognised. The default keys (`PATH`, `HOME` and the rest) are ordinary environment and are never scrubbed.

## Lookup time

All the helper lookups for one command share one 5-second budget. Each helper runs for the lesser of its own `timeout_ms` and what is left; a helper still running when the budget ends is killed, and a helper-backed name not yet reached is skipped. Those names are reported as unresolved with their own reason, and the command runs without them. A locked keychain with several stored names therefore costs a command at most the budget once. Reading the daemon's environment spawns nothing and is never cut off. A command capability's `pass_env` and a coding-agent adapter's declared variables are requirements outside this budget: each is bounded by its own helper timeout.

## An allowed name the daemon cannot read

It is never a reason to refuse the command. Every allowed name resolves on its own, the command runs with the ones that resolved, and the miss is reported on every surface:

- the tool result opens with a note naming the variable and the remedy (store it in the sandbox settings, or on a server with no keyring add it to the env file and restart Fermix), on success and on failure alike;
- the `tool_exec` trace carries `env_unresolved` (names only, so a content-free export still shows it) and never `policy_enforcement`, because nothing was denied;
- the daemon log gets one line when a name stops resolving and one when it resolves again, not one per command;
- readiness shows an advisory failure in the Sandbox pane, `sandbox:env_missing` (no value where Fermix runs) or `sandbox:env_helper_failed` (a helper failed, timed out, or was cut off by the lookup budget), one row per cause naming every variable, from boot, from every config apply, and from every shell command, until the value resolves or the name leaves the allow list. Advisory: it never marks setup unfinished. The record lives in the daemon, so the app's Home, Settings and Doctor see it; a `fermix doctor` run from a shell is a separate process with no view of it and shows nothing for this.

A name a consumer requests for itself is different: a coding-agent adapter's declared variable or a command capability's `pass_env` is a requirement, and one that cannot be read fails that run or command with the reason.

## Fixing it

Store the value in Settings > Sandbox, or on a Linux server with no keyring add it to the env file and restart Fermix. To read it from a tool of your own instead, `fermix sandbox env set NAME -- <helper> [args...]`; to stop passing it, `fermix sandbox env unset NAME`. From a chat, `/sandbox env set NAME -- <helper> [args...]` and `/sandbox env unset NAME` do the same inside the running daemon. On an app-managed home a standalone `fermix` writes the settings file from outside the daemon, which then refuses its own writes until settings are reloaded, so prefer the app or the chat command there.
