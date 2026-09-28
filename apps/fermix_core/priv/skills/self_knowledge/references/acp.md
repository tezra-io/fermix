# The ACP agent surface (Zed, Buzz and other ACP clients)

Any Agent Client Protocol client can drive Fermix as an agent. The client spawns `fermix acp`, a bridge that pipes the client's stdio into the running daemon's `$FERMIX_HOME/acp.sock`; it is never a second Fermix, and it refuses with one stderr line when the daemon is down.

## Turning it on and connecting a client

1. `[fermix_channels.acp] enabled` is on by default and is the whole config. Change it in Mac Settings > Channels > Editors > **Accept editor connections**, browser setup's Channels tab, or `fermix setup --acp-enabled` / `--no-acp-enabled`; restart to apply.
2. The client needs a `fermix` command to spawn. On a Mac with only the app, that means installing the standalone binary (the app ships none).
3. **Zed and other editors**: add an agent server whose command is `fermix` with args `acp`; it runs in the project directory the client opens.
4. **Buzz**: add a custom harness in the org: label `Fermix`, command `fermix`, args `acp`. Set `FERMIX_HOME` in the harness env only when the home is not the default: a GUI spawn inherits no shell exports.

Check it: `fermix doctor`'s `acp surface` row shows the socket path, whether the listener is up, and every remembered identity by npub (never key material), even when the surface is disabled.

## How a session behaves

- Each ACP session is its own conversation, so a harness restart starts fresh; what carries over is daemon-wide (memory, skills, persona), never the transcript.
- Turns run at operator trust under the normal sandbox. The model writes its own replies; under Buzz it posts in-channel by running the `buzz` CLI through the shell tool, which works because the client's environment is overlaid onto that session's shell commands.
- **Remembered identities.** A client that presents a Buzz relay identity is remembered like a connected provider: its credentials live in a private per-identity record under `FERMIX_HOME` until `fermix acp forget <npub>` (`--all` clears every one). Reconnecting refreshes them; disabling the surface deletes nothing; an editor that presents no identity stores nothing.
- **Coding runs need a remembered identity**: because those credentials outlive the connection, a session with one is offered `codex_run`, `claude_code_run` and the run-inspection tools; the launch returns a run id, and the finished run arrives later as a new message in the channel. A session whose identity record is gone loses them from its next turn.
- **Absent by design** (asking is a dead end, not a bug): the slash-command pipeline (no `/sandbox`, `/soul`, `/compact`, `/background`; a leading `/` is plain text), the in-chat approval flow (no `request_directory_access`; a sandbox refusal is final and must be granted from an owner surface), and origin-mode scheduling (`schedule_job` refuses `delivery_mode: "origin"`; schedule to an explicit channel).
- A Buzz-wired session is a channel others can post in, so computer use and the person's own browser tab are refused there, and access-sensitive plugin commands always wait for the owner's confirmation in their own chat. Ask from the Fermix app, the owner's own chat, or voice.

## Failure

- No provider was connected when the daemon started → the ACP listener never starts, and doctor's `acp surface` row fails with "enabled but its listener is not running". Connect a provider, then restart.
- Socket cannot be bound at boot (usually a `FERMIX_HOME` path long enough to push the socket past the OS limit) → ACP is off for that boot only, the rest of the daemon runs, and the daemon log has one line naming the path and the fix.
