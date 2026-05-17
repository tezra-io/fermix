# Milestone 5: Simple Workspace Sandbox

**Status:** Draft
**Date:** 2026-05-16
**Author:** Sujeeth / Aira
**Depends on:** M4.8 (`fermix` CLI, daemon, `~/.fermix` home), M4.9 (`Capability` struct + `policy_class` ladder, `CapabilityRegistry`), M4.10 (`ConfigStore` round-trip), M7 (`shell`, `file_*`, `git_*`, `NetGuard`), M7.1 (`FermixChannels.Commands` slash-command dispatcher and owner authorization)
**Blocks:** M10 (Security & Governance) - M5 provides the basic local safety floor that M10 later hardens.

---

## 1. Goal

M5 should keep Fermix useful first.

The agent should have a normal place to work, should run everyday commands without constant approval prompts, and should be able to call operator-approved local tools such as `codex`, `claude`, `gh`, `brew`, or project CLIs. It should not be able to accidentally start in `/`, wipe the host through a generated test, or write through Fermix file tools to arbitrary host paths by default.

M5 is intentionally **not** the full security system. M10 owns per-call approval, leak detection, prompt-injection guardrails, audit signing, and OS-level isolation.

M5 ships:

1. A default workspace root under `FERMIX_HOME`.
2. Three sandbox modes: `strict`, `standard`, and `open`.
3. A hardline denylist for catastrophic shell commands.
4. Exact path checks for Fermix-owned file and git write tools.
5. A permissive shell that runs from roots allowed by the current mode.
6. Mode-based access to local commands/tools, with optional command presets.
7. Selective env/credential passthrough into sandboxed commands.
8. Operator channel commands for sandbox config updates, routed through the same `ConfigMutation` / `ConfigStore` path as the CLI.
9. Sandbox decision telemetry.
10. Test-safety guardrails before any negative sandbox tests land.

M5 does not ship:

- A Fermix-owned credential store.
- Broad first-class keychain APIs beyond the helper-command setup path in §6.1.
- Mandatory automatic credential migration.
- `age` encryption.
- Website blocklists.
- Shell operand parsing.
- Per-skill ACLs.
- Remote/container backends.
- Global daemon env scrubbing.
- OS-level filesystem isolation.

Those can land later without changing the M5 surface.

---

## 2. Design Principles

1. **Keep the agent productive.** In the default `standard` mode, normal project work should not require constant grants.
2. **Do exact checks where Fermix owns the operation.** `file_write`, `file_edit`, and `git_write` know their target paths, so they must enforce path containment exactly.
3. **Do not overclaim shell safety.** Without Landlock, Docker, Seatbelt, or another OS sandbox, a child process can still write absolute paths if the OS user can. M5 only constrains the shell's working directory and blocks catastrophic known commands.
4. **Use modes before one-off grants.** Operators should pick a posture once, then add explicit grants only when the mode is not enough.
5. **Pass secrets only by explicit declaration.** The daemon does not scrub its global env in M5. It builds a child-process env for shell/subagent calls from an explicit allowlist.
6. **Make effective policy explainable.** Operators need one place to see effective roots, protected paths, command presets, and env names.
7. **Never let the sandbox modify itself.** Sandbox config, grants, credentials, sockets, and daemon state are protected paths. Config changes must come from an operator control surface, not a capability, skill, subagent, MCP client, shell command, or tool output.
8. **Never run dangerous negative tests.** Hardline and containment tests are pure classification tests.

### 2.1 OpenShell Takeaways To Keep

OpenShell validates the broad direction, but M5 borrows only the small mode model, single-shape decision return, and explainable-policy idea. It does not borrow the gateway, container runtime, or policy-engine stack. Self-modification prevention is enforced by §3.4 protected paths and §7.1 config mutation gates.

---

## 3. Workspace Model

### 3.1 FERMIX_HOME

| Build flavor | Default home |
| --- | --- |
| Release | `~/.fermix` |
| Dev (`mix`) | `~/.fermix-dev` |
| Test | Explicit test tmp dir via `FERMIX_HOME` |

`FERMIX_HOME` remains overridable by env and CLI/service configuration. M5 does not add fallback chains between homes.

### 3.2 Workspace Root

Default layout:

```text
~/.fermix/
├── config.toml
├── auth.json
├── memory.db
├── traces/
├── logs/
├── workspace/
│   └── scratch/
└── grants/
```

`workspace/` is created on startup if missing. It is the default working directory for `shell` and the default base for file/git tools when no absolute path is provided.

Config:

```toml
[sandbox]
enabled = true
mode = "standard"                 # "strict" | "standard" | "open"
workspace_root = "~/.fermix/workspace"
allowed_roots = []
blocked_roots = []
```

`allowed_roots` are additional operator-approved directories added on top of the selected mode. `blocked_roots` are operator-denied paths subtracted from the selected mode.

### 3.3 Sandbox Modes

M5 should avoid cherry-picking every path or command. The operator chooses one of three modes:

| Mode | Intended use | Default roots | Command posture | Env posture |
| --- | --- | --- | --- | --- |
| `strict` | Tightest scope. Use for CI runs, first install, or risky tasks. | `workspace_root` only, plus explicit `allowed_roots`. | Shell can run from allowed roots. Command capabilities only from configured presets. | Selected env only. |
| `standard` | **Default.** Day-to-day scope. Includes the workspace and your project folders. | `workspace_root`, the daemon launch cwd when it is under `$HOME`, common project roots that exist (`~/projects`, `~/src`, `~/code`, `~/work`, `~/dev`), plus explicit `allowed_roots`. | Shell can run normal PATH commands from allowed roots. Built-in command presets can be enabled. | Selected env only. |
| `open` | Broad scope. Use when the agent should reach across user files. | `$HOME` except protected/blocked roots, plus external volumes explicitly granted by `allowed_roots`. | Shell can run normal PATH commands from allowed roots. More command presets can be enabled. | Selected env only by default; `[sandbox.env].mode = "all"` is explicit. |

All modes still block:

- hardline commands
- protected daemon paths
- core OS roots
- known credential directories unless passed as explicit credential files or env vars

`standard` is intentionally lenient enough for day-to-day work but does not grant OS-level paths or broad credential directories.

Mode config can be tuned without replacing the mode:

```toml
[sandbox.mode_options]
include_launch_cwd = true
common_project_roots = ["~/projects", "~/src", "~/code", "~/work", "~/dev"]
```

### 3.4 Protected Daemon Paths

Even if a path is under `FERMIX_HOME`, tools must not write to Fermix control/state files.

Always deny writes to:

- `~/.fermix/config.toml`
- `~/.fermix/config.toml.pre-m5`
- `~/.fermix/auth.json`
- `~/.fermix/memory.db`
- `~/.fermix/traces/`
- `~/.fermix/logs/`
- `~/.fermix/grants/`
- migration marker files such as a future `~/.fermix/keystore.migrated`
- daemon sockets and pid files

Reads can remain allowed for normal introspection unless a later M10 rule restricts them.

Protected-path checks apply to capability-originated writes only. CLI, wizard, daemon control surfaces, `ConfigStore`, and `Auth.Store` write Fermix control files through their own atomic writers; they do not call `Sandbox.enforce/3`.

### 3.5 Allowed Root Validation

`fermix grant path <dir>` must reject unsafe roots.

Reject:

- `/`
- `$HOME` itself
- `FERMIX_HOME`
- parents or children of protected daemon paths
- core OS roots such as `/etc`, `/usr`, `/bin`, `/sbin`, `/System`, `/Library`, `/private`
- known credential directories such as `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker`, `~/.codex`, `~/.config/openai`, `~/.config/anthropic`

If the operator needs one credential file, they use credential/env passthrough, not a broad path grant.

Grant record:

```toml
granted_at = "2026-05-16T12:00:00Z"
granted_by = "operator"
kind = "path"
target = "~/projects/foo"
resolved_target = "/Users/sujshe/projects/foo"
note = ""
```

Grant records are append-only in `~/.fermix/grants/`. Revocation writes a new record and removes the path from config.

---

## 4. Sandbox Enforcement

### 4.1 Dispatch Shape

New modules:

| Module | Purpose |
| --- | --- |
| `FermixCore.Sandbox` | Public `enforce/3` entrypoint. |
| `FermixCore.Sandbox.Config` | Reads `[sandbox]`, mode, root presets, commands, and env specs from `ConfigStore`. |
| `FermixCore.Sandbox.Mode` | Expands `strict` / `standard` / `open` into effective roots and command posture. |
| `FermixCore.Sandbox.Hardline` | Pure command classifier for catastrophic commands. |
| `FermixCore.Sandbox.PathPolicy` | Path expansion, symlink resolution, containment, protected-path checks. |
| `FermixCore.Sandbox.Decision` | Telemetry and trace emission. |
| `FermixCore.Sandbox.ConfigMutation` | Applies validated sandbox config mutations from CLI and channel command handlers. |

Public API:

```elixir
@type decision ::
        :allow
        | {:deny, reason :: atom() | {atom(), term()}}
        | {:hardline, description :: String.t()}

@spec enforce(Capability.policy_class(), map(), map()) :: decision()
```

Every decision emits `[:fermix, :sandbox, :decision]`.

M5 returns only `:allow`, `{:deny, reason}`, and `{:hardline, description}`. M10 can extend the same shape with `{:approval_required, reason, request}` without changing the enforcement entrypoint.

`Sandbox.ConfigMutation` is the single config mutation surface used by CLI and channel commands. It validates proposed changes, computes diffs, writes grant records, delegates TOML normalization to `ConfigStore`, and signals daemon reload.

Public API:

```elixir
set_mode(config, mode)
add_allowed_root(config, path)
remove_allowed_root(config, path)
add_env_passthrough(config, name, source_spec)
remove_env_passthrough(config, name)
enable_preset(config, preset)
disable_preset(config, preset)
enable_command(config, name, command_spec)
disable_command(config, name)
diff(current_config, proposed_config)
requires_confirmation?(current_config, proposed_config)
apply(config, mutation, opts)
```

These functions are thin validation and diff layers above `ConfigStore`; they must not re-implement TOML parsing or formatting.

### 4.2 Hardline Shell Denylist

`Sandbox.Hardline.classify/1` is a pure function. It never executes commands.

Hardline blocks:

- `rm -rf /`
- recursive deletes of core OS roots and home
- `mkfs`
- `dd of=/dev/...` block-device writes
- fork bombs
- kill-all-process patterns
- shutdown/reboot/poweroff
- `sudo -S` password feeding

Hardline blocks cannot be disabled by config.

### 4.3 Shell Policy

Current `shell` default cwd must change from `File.cwd!()` to a sandbox-selected working directory.

Shell v1 enforcement:

1. Command must pass `Hardline.classify/1`.
2. `working_dir` defaults to the request context cwd when present and allowed; otherwise `standard` mode uses the daemon launch cwd if it is under an effective root; otherwise it falls back to `workspace_root`.
3. Resolved `working_dir` must be inside the effective roots for the selected mode.
4. Child process env is built from explicit passthrough config.
5. Command runs through existing `System.cmd("sh", ["-c", command], ...)`.

No shell operand parser in M5.

Reason: a parser catches some forms like `> /etc/foo` but misses equivalent writes through Python, Node, Make, tar, install scripts, editor CLIs, and other programs. That creates false confidence. M5 stays honest: shell is permissive inside allowed working roots; real write isolation is an OS-sandbox milestone.

### 4.4 File Write/Edit Policy

`file_write` and `file_edit` must check their `path` before writing.

Rules:

1. Resolve relative paths against the request context cwd when present and allowed; otherwise use the shell default working directory for the selected mode.
2. Expand `~`.
3. Resolve symlinks with a bounded hop count.
4. Allow only if the final target is inside the effective roots for the selected mode.
5. Deny if the final target is inside a protected daemon path.

This is exact containment because Fermix owns the target path.

### 4.5 Git Write Policy

`git_write` must resolve the repo root and enforce containment on that root.

Rules:

1. Resolve relative repo paths against the request context cwd when present and allowed; otherwise use the shell default working directory for the selected mode.
2. Run `git rev-parse --show-toplevel` with structured args.
3. Allow only if the repo root is inside the effective roots for the selected mode.
4. Keep the existing `git_write` subcommand whitelist. `push` remains outside `git_write` until M10 approval flow.

Shell may still run `git push` from an allowed repo. That is an accepted M5 tradeoff: M5 is not a network approval system.

### 4.6 Upgrade Compatibility

Adding root checks to `file_write`, `file_edit`, `git_write`, and shell cwd is a real behavior change. Operators with project layouts outside the default roots (`~/projects`, `~/src`, `~/code`, `~/work`, `~/dev`) may need grants for paths such as `~/Workspace`, `~/repos`, or `~/Documents/code`.

After M5 boot, `fermix doctor` scans recent traces for `file_write`, `file_edit`, `git_write`, and shell cwd targets outside the effective auto-allowed roots. It prints one `fermix grant path <dir>` suggestion per distinct parent directory. This is advisory only; it does not auto-grant.

### 4.7 Read Tools

M5 does not try to enforce all reads.

Read tools should resolve relative paths the same way write tools do: request context cwd first, then the selected mode's default working directory. Broad read restriction is M10. Credential directories are not granted as allowed roots; individual secrets are passed through explicit env/credential config.

---

## 5. External Commands and Subagents

Command access is mode-based first, configurable second. The shell can already call normal PATH commands from an allowed working directory. M5 adds command presets only for tools that should appear as first-class capabilities in the registry, such as Codex or Claude Code.

Config:

```toml
[sandbox.commands]
profile = "assistant"              # "bare" | "assistant" | "extended"
enabled_presets = ["ai_tools"]      # optional, profile default if absent
```

Profiles:

| Profile | First-class command capability posture |
| --- | --- |
| `bare` | No preset commands auto-register. `shell` and any explicit `[sandbox.commands.*]` blocks still work. |
| `assistant` | Register enabled presets if binaries exist. `shell` and explicit blocks also work. Good default for `standard` sandbox mode. |
| `extended` | Same as `assistant`, plus optional broader local-tool presets. Intended for `open`. |

Presets are small groups, not one-off command cherry-picks:

| Preset | Examples | Notes |
| --- | --- | --- |
| `ai_tools` | `codex`, `claude` | One-shot prompt command capabilities. |
| `dev_tools` | `git`, `gh`, `make`, language package managers | Shell remains the main interface; presets are for direct capability use. |
| `app_tools` | operator-declared app CLIs | Disabled unless configured. |

Presets only register commands whose executable exists. Missing binaries are reported by `fermix doctor`, not fatal.

The operator can still declare or override individual commands when needed. That is the escape hatch, not the default model.

Example:

```toml
[sandbox.commands.codex]
enabled = true
command = "codex"
args = ["--quiet", "--message"]
description = "Run Codex CLI for one prompt"
timeout_ms = 120000
pass_env = ["OPENAI_API_KEY"]

[sandbox.commands.claude_code]
enabled = true
command = "claude"
args = ["-p"]
description = "Run Claude Code for one prompt"
timeout_ms = 180000
pass_env = ["ANTHROPIC_API_KEY"]
```

Each enabled command registers one built-in capability in `CapabilityRegistry`:

- `kind: :builtin`
- `policy_class: :exec`
- `requires_approval?: false`
- schema: `%{"prompt" => string, "args" => optional string array}`

Execution:

1. Resolve executable with `System.find_executable/1`.
2. Use the sandbox-mode default working dir and audit it through `Sandbox.enforce/3`.
3. Build child env from `pass_env`.
4. Run the configured command with structured args plus the prompt.
5. Return stdout/stderr and exit code.

No broad auto-discovery in M5. Modes and presets define what can register; per-command blocks override preset defaults.

Command capabilities do not support per-call working directories in M5. They use the sandbox-mode default working dir; use `shell` when a specific cwd matters.

Command capabilities also do not run `Hardline.classify/1`; they execute operator-declared specs. Do not expose `sh -c`, `bash -c`, `python -c`, or equivalent command specs as command capabilities unless you intentionally want to recreate shell without the hardline filter.

Skills that need external tools can either:

- call the normal `shell` capability inside an allowed root, or
- call an operator-declared command capability such as `codex` or `claude_code`.

---

## 6. Env and Credential Passthrough

M5 does not build a new secret store. It only controls which values are passed into child processes. Env is always selective by default, even in `open`, because credentials are the easiest thing to leak accidentally.

Config:

```toml
[sandbox.env]
mode = "selected"                  # "selected" | "all"; default "selected"
allow = ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"]

[sandbox.env.OPENAI_API_KEY]
source = "command"
command = "secret"
args = ["OPENAI_API_KEY"]
timeout_ms = 3000

[sandbox.env.ANTHROPIC_API_KEY]
source = "env"
name = "ANTHROPIC_API_KEY"

[sandbox.env.CODEX_API_KEY]
source = "command"
command = "pass"
args = ["show", "fermix/codex_api_key"]
timeout_ms = 3000
```

The common local shell pattern:

```sh
OPENAI_API_KEY=$(secret OPENAI_API_KEY)
```

maps to the structured `source = "command"` block above. Fermix runs `secret` with structured args, trims one trailing newline from stdout, and injects the value as `OPENAI_API_KEY` into child commands that explicitly request it. The secret value is never written to `config.toml`, traces, logs, or tool output.

`source = "command"` is the portable secret-source interface. Operators can map it to whatever their OS or password manager provides:

```toml
# macOS Keychain CLI
[sandbox.env.OPENAI_API_KEY]
source = "command"
command = "/usr/bin/security"
args = ["find-generic-password", "-w", "-s", "fermix", "-a", "openai_api_key"]

# Linux Secret Service
[sandbox.env.OPENAI_API_KEY]
source = "command"
command = "secret-tool"
args = ["lookup", "service", "fermix", "account", "openai_api_key"]

# pass
[sandbox.env.OPENAI_API_KEY]
source = "command"
command = "pass"
args = ["show", "fermix/openai_api_key"]

# Windows PowerShell SecretManagement
[sandbox.env.OPENAI_API_KEY]
source = "command"
command = "powershell.exe"
args = ["-NoProfile", "-Command", "Get-Secret -Name OPENAI_API_KEY -AsPlainText"]
```

Supported sources in M5:

| Source | Behavior |
| --- | --- |
| `env` | Reads from the daemon process env. Works for values exported before the daemon starts. |
| `command` | Runs an operator-declared command with structured args and uses stdout as the value. This is the preferred path for local helpers like `secret OPENAI_API_KEY`. |

No OS-specific secret backend is needed in M5. If a future milestone wants first-class keychain integrations, it can add aliases on top of `source = "command"`.

Security boundary note: selected env passthrough controls what Fermix injects into child processes. It does not stop a permitted shell command from invoking local tools such as `secret`, `security`, `pass`, `op`, or `secret-tool` itself. If that helper allows the same OS user to read a secret non-interactively, then any local shell owned by that user can read it too. M5 accepts that limitation. Stronger control requires command allow/block policy or OS-level sandboxing in a later milestone.

Important launch note: `bashrc` is not automatically loaded by `launchd` or `systemd` services. If the operator wants values from shell startup files, they must start Fermix from that shell or put the values in the service environment. `fermix doctor` should report which declared env names are currently visible.

Child process env rules:

1. Start from a tiny default env: `PATH`, `HOME`, `USER`, `LANG`, `LC_*`, `SHELL`, `TMPDIR`.
2. In `selected` mode, add only names listed in `[sandbox.env].allow` and the command's `pass_env`.
3. In `all` mode, pass the daemon env except denied names; this requires explicit config and is never the default.
4. Command-level `pass_env` can only request names that the sandbox env policy allows.
5. Missing required env values fail the command call with a clear error.
6. `source = "command"` uses structured command + args, not shell interpolation.
7. Env-source command output is capped, must exit 0, and must produce exactly one secret value after trimming a trailing newline.
8. Do not mutate the daemon's global env.

Optional denylist for `all` mode:

```toml
[sandbox.env]
mode = "all"
deny = ["AWS_SECRET_ACCESS_KEY", "GITHUB_TOKEN"]
```

`all` mode is useful for trusted local workflows, but M5 docs should steer setup toward `selected`.

This gives operators control without making M5 a full keystore project.

### 6.1 Setup-Time Credential Entry

§6 describes how Fermix retrieves env values at child-process build time. The other half is initial entry: how a value typed into the setup wizard or `fermix sandbox env set` reaches the local store that §6 reads from.

M5 does not become a credential store. The wizard delegates secret storage to whichever OS-native helper the operator chose during setup, using the same `source = "command"` shape §6 already reads through.

The current wizard can write up to eight persisted secret paths in `@setup_secret_paths`, depending on enabled providers and channels: OpenAI API key, Telegram bot token, WhatsApp access token, WhatsApp verify token, WhatsApp app secret, Discord bot token, Slack bot token, and Slack signing secret. The realtime API key prompt also writes through the OpenAI provider key path. `Setup.SecretWriter` migration scans all known setup secret paths but only offers migration for non-empty values already present in config or entered during setup.

Wizard flow when prompting for an API key or channel secret:

1. Read the value from stdin with no echo.
2. Detect available local helpers with `System.find_executable/1` in this order: `security` on macOS, `secret-tool` for Linux Secret Service, `pass`, `op`. First match is the recommended default; the operator can override.
3. Ask the operator to choose: store this in the detected helper (recommended), set it in the daemon env manually, or use another helper command.
4. Helper selected: run the store command once with structured args; write a `[sandbox.env.<NAME>]` block with `source = "command"` pointing at the matching retrieval command; discard the plaintext value from wizard memory.
5. Manual env selected: write `source = "env" name = "<NAME>"`. Print instructions to export the value in the shell or service file that starts Fermix.
6. Other helper selected: prompt for `command` and `args`, write the matching `source = "command"` block.

After the wizard exits, no secret value is written to `~/.fermix/config.toml`. The `[sandbox.env.<NAME>]` block describes how to retrieve the value, not the value itself.

`fermix sandbox env set <NAME>` re-runs the same prompt for rotation. `fermix sandbox env get <NAME>` runs the configured retrieval command and prints `***` by default, or the resolved value behind `--unsafe-print`. `fermix sandbox env unset <NAME>` removes the `[sandbox.env.<NAME>]` block from config and prints the helper-specific command the operator can run to delete the stored value (Fermix does not delete from the operator's keychain on its behalf - that is the operator's tool to manage).

Existing operators upgrading from pre-M5 builds may have plaintext values in any setup secret path. On first M5 boot, the wizard detects them and offers per-secret migration through the same flow. Migration is opt-in per key. The pre-migration `config.toml` is preserved as `config.toml.pre-m5` until `fermix doctor` is green.

OAuth credential blobs are kept as `0600` plaintext, not in keychain entries. Codex `auth.json` is a multi-field JSON that `TokenManager` refreshes in place, and splitting it across per-field keychain entries introduces a multi-write atomicity problem (access token, refresh token, and expiry must update together) without changing the effective threat surface, since the OS user who can read a keychain entry can also read a `0600` file in their own home. M5 keeps `~/.fermix/auth.json` as a single isolated `0600` file. At boot, Fermix reads `File.stat!(~/.fermix/auth.json).mode` and refuses to start if `Bitwise.band(mode, 0o777) != 0o600`; `fermix doctor` reports the same failure.

Test discipline: wizard secret-store writes dispatch through a `:secret_writer` Application env binding. Tests use a `Stub` impl that records intended calls without invoking `security`, `secret-tool`, `pass`, or `op`. A Credo check forbids direct calls to these binaries from `apps/fermix_core/lib/fermix_core/setup/**` outside the `Setup.SecretWriter` module.

---

## 7. CLI Surface

M5 adds:

```sh
fermix sandbox mode standard
fermix sandbox mode strict
fermix sandbox mode open
fermix grant path ~/projects/foo
fermix revoke path ~/projects/foo
fermix sandbox status
fermix sandbox explain
fermix sandbox env
fermix sandbox env allow OPENAI_API_KEY
fermix sandbox env deny OPENAI_API_KEY
fermix sandbox env set OPENAI_API_KEY
fermix sandbox env get OPENAI_API_KEY
fermix sandbox env unset OPENAI_API_KEY
fermix sandbox commands profile assistant
fermix sandbox commands enable ai_tools
fermix sandbox command list
```

Optional convenience commands:

```sh
fermix grant command codex -- codex --quiet --message
fermix grant command claude_code -- claude -p
```

These commands edit `config.toml` through `ConfigMutation`/`ConfigStore`, write grant records, and signal the daemon to reload sandbox config.

`fermix sandbox status` prints a compact, one-screen summary:

- current sandbox mode
- workspace root
- allowed and blocked root counts
- env passthrough count
- enabled command profile and preset count
- last 5 denied or hardline decisions when available

`fermix sandbox explain` prints the full effective policy:

- current sandbox mode
- effective roots after mode expansion, allowed roots, and blocked roots
- protected daemon paths
- env names that can be passed through, names only, never values
- enabled command profile, presets, and explicit command capabilities
- recent denied and hardline decision counts when available from telemetry/trace state

No `fermix keystore` CLI in M5.

### 7.1 Channel Commands

The CLI is the canonical config surface, but owner-authorized channels can expose the same changes as explicit slash commands. This keeps the OpenClaw-style "tell the agent to update its config" workflow without giving the agent a tool that can rewrite its own permissions.

M5 reuses the existing M7.1 channel command layer:

- `FermixChannels.Commands.parse/2` recognizes leading slash commands before delivery to `MainAgent`.
- `FermixChannels.Commands.Authorization.owner_only/3` authorizes the caller.
- CLI is implicit-owner.
- Remote channels require the stable sender id to match the configured `owner_user_id` or `command_allowlist`.
- If no command handler is registered, the message passes through as normal user content.

M5 adds a `FermixChannels.Commands.Sandbox` handler that parses sandbox subcommands and calls `FermixCore.Sandbox.ConfigMutation`. The handler owns channel UX. `ConfigMutation` owns validation, diffing, grant writes, `ConfigStore` writes, and daemon reload signaling.

Examples:

```text
/sandbox status
/sandbox explain
/sandbox mode standard
/sandbox mode strict
/sandbox mode open
/grant path ~/projects/foo
/revoke path ~/projects/foo
/sandbox env allow OPENAI_API_KEY
/sandbox env deny OPENAI_API_KEY
/sandbox env set OPENAI_API_KEY
/sandbox env unset OPENAI_API_KEY
/sandbox commands profile assistant
/sandbox commands enable ai_tools
/confirm ABCD2345
```

Rules:

1. Channel config updates are parsed only from exact slash/control commands handled by the M7.1 command dispatcher before `MainAgent` sees the message.
2. Natural language like "update your config" is not a config mutation in M5.
3. The command handler calls the same `ConfigMutation`, `ConfigStore`, and grant-writing code as the CLI.
4. Widening access requires a confirmation step that shows the config diff or grant target before write.
5. Narrowing access, status, and explain commands can run without confirmation.
6. Channel commands are never registered in `CapabilityRegistry`.
7. Channel commands are rejected when the origin is an agent message, tool output, skill, subagent, inbound MCP client, or replayed transcript.
8. A channel command cannot edit protected daemon paths directly; it can only call the narrow config mutation functions.

This is a strict config-mutation gate, not a fourth sandbox mode. The agent can suggest the exact slash command for the operator to run, but it cannot execute that command on its own.

Confirmation protocol:

1. A widening command replies with the proposed diff or grant target and an instruction: `/confirm <token>`.
2. The token is single-use, 8 characters of base32 text, generated by `FermixChannels.Commands.Sandbox`.
3. The pending mutation is stored in memory only and expires after 60 seconds.
4. `/confirm <token>` must arrive from the same channel, chat/thread, and authorized stable user id.
5. Timeout discards the pending mutation.
6. Tokens and resolved secret values are not written to traces, logs, or `config.toml`.

`FermixCore.Sandbox.ConfigMutation.requires_confirmation?/2` compares current and proposed effective policy. Confirmation is required when any of these sets gains an element:

- effective roots
- env names available for passthrough, including `selected` -> `all`
- enabled command presets
- enabled first-class command capabilities

`/sandbox status`, `/sandbox explain`, revoking paths, removing env names, disabling presets/commands, and moving to a strictly smaller effective policy do not require confirmation.

---

## 8. Telemetry

Every sandbox decision emits:

```elixir
:telemetry.execute(
  [:fermix, :sandbox, :decision],
  %{duration_us: duration},
  %{
    capability: capability_name,
    policy_class: policy_class,
    resource: %{kind: kind, target: capped_target, target_hash: hash},
    decision: :allow | :deny | :hardline,
    agent: agent_name,
    conversation_key: conversation_key
  }
)
```

`target` is capped at 256 chars. The full target hash is included for audit correlation.

Trace logging records denied and hardline decisions by default. Allow decisions may be sampled or logged only in debug mode to avoid trace noise.

---

## 9. Testing and Negative-Test Discipline

This section is mandatory because a previous implementation pass generated a cleanup hook that called `File.rm_rf!` on a computed path that collapsed to `/`.

### 9.1 Stage 0 Must Land First

Before implementing sandbox behavior:

1. Add `FermixCore.TestSupport.SafeRm`.
2. Ban direct `File.rm_rf`, `File.rm_rf!`, `File.rm`, and `File.rm!` in tests outside approved helpers.
3. Ban `System.cmd`, `:os.cmd`, `Port.open`, and `:erlang.spawn_executable` in sandbox negative tests.
4. Rewrite existing test cleanup call sites through safe helpers or ExUnit tmp dirs.
5. Run the full suite before continuing.

Current scope is non-trivial: the tree has roughly 45 test files with `File.rm_rf` / `File.rm_rf!` and roughly 64 test files with `System.tmp_dir!`. Most should rewrite to ExUnit tmp-dir callbacks; deterministic-name tests use `SafeRm` with an explicit `fermix-` prefix.

### 9.2 SafeRm Requirements

`SafeRm.rm_rf!/1` must:

1. Require a binary path.
2. Expand and realpath the target where possible.
3. Require a Fermix-owned tmp marker or prefix.
4. Require a minimum path depth.
5. Reject `/`, `$HOME`, `FERMIX_HOME`, and protected daemon paths.
6. Raise loudly instead of deleting on uncertainty.

The previous design allowed broad `/var/folders/...`; this version should not. The safe prefix must be Fermix-owned, such as `/tmp/fermix-test-*` or an ExUnit tmp dir created by the test.

### 9.3 Negative Tests Are Pure

Hardline tests:

- Use fixture strings.
- Call `Sandbox.Hardline.classify/1`.
- Never execute the command.

Path tests:

- Use synthetic paths and test tmp dirs.
- Create symlinks only inside test tmp dirs.
- Never create or delete real `/etc`, home, credential, or daemon paths.

Shell integration tests:

- Only run harmless commands such as `pwd`, `echo`, or `touch` inside test tmp workspace.
- Never run hardline commands through `shell`.

### 9.4 Required Coverage

- Hardline blocks known catastrophic strings.
- Shell defaults cwd to the selected mode's working directory.
- `strict` mode denies cwd outside workspace and explicit allowed roots.
- `standard` mode allows a common project root and still denies OS/protected roots.
- `open` mode allows `$HOME` paths and still denies OS/protected roots.
- `file_write` denies outside paths.
- `file_edit` denies symlink escapes.
- `git_write` denies repos outside effective roots.
- `fermix grant path` rejects unsafe roots.
- Command capability receives only declared env values.
- Command presets register only in modes/profiles that enable them.
- Missing declared env produces a clear error.
- Channel slash commands route through the same config mutation code as the CLI.
- Channel slash commands use M7.1 owner authorization and never register in `CapabilityRegistry`.
- Widening channel commands require confirmation with a visible diff or grant target.
- Confirmation tokens are same-channel, same-user, single-use, in-memory, and time bounded.
- `fermix sandbox status` prints compact mode, root, grant/env/command counts, and last denied/hardline decisions.
- `fermix sandbox explain` prints mode, effective roots, protected paths, env names only, enabled command posture, and recent deny/hardline counts.
- Sandbox telemetry fires for allow, deny, and hardline.

---

## 10. Implementation Stages

Each stage is `step -> verify`.

### Stage 0 - Test Safety

Step:

- Add `SafeRm`.
- Add Credo checks or equivalent static checks.
- Rewrite direct destructive cleanup calls in tests.

Verify:

- `mix test`
- `mix credo --strict`
- `mix compile --warnings-as-errors`
- `mix format --check-formatted`

Nothing else starts before this is green.

### Stage 1 - Config, Modes, and Workspace

Step:

- Add sandbox config parser.
- Add `strict` / `standard` / `open` mode expansion.
- Add workspace path to `ConfigStore`.
- Create workspace and grants dirs at startup.
- Add `fermix sandbox status`.
- Add `fermix sandbox explain`.

Verify:

- Config round-trip tests.
- Doctor/status tests, including compact status output.
- Explain output tests for mode, roots, protected paths, env names without values, command posture, and deny/hardline counts.

### Stage 2 - Hardline and Shell Cwd

Step:

- Add `Sandbox.Hardline`.
- Add `Sandbox.enforce/3` skeleton and telemetry.
- Change shell default cwd to the selected mode's working directory.
- Deny shell working dirs outside the selected mode's effective roots.

Verify:

- Pure hardline classifier tests.
- Shell harmless integration tests inside tmp workspace.

### Stage 3 - File and Git Write Guards

Step:

- Add `PathPolicy`.
- Wire `file_write`, `file_edit`, and `git_write`.
- Add protected daemon path denylist.

Verify:

- Outside path deny tests.
- Symlink escape tests.
- Git repo root containment tests.

### Stage 4 - Allowed Roots and Grants

Step:

- Implement `fermix grant path`.
- Implement `fermix revoke path`.
- Add grant record writing.
- Add live sandbox config reload if the daemon is running.
- Add `FermixCore.Sandbox.ConfigMutation`.
- Add `FermixChannels.Commands.Sandbox` handler backed by M7.1 parsing and owner authorization.
- Add channel slash commands for `status`, `explain`, `mode`, `grant path`, and `revoke path`.

Verify:

- Unsafe grant rejection tests.
- Allowed root happy path tests.
- Channel command owner authorization tests.
- Channel command confirmation tests for widening changes, token expiry, token single-use, and same-channel/same-user enforcement.

### Stage 5 - External Commands and Env Passthrough

Step:

- Parse `[sandbox.commands.*]`.
- Parse command profiles and presets.
- Register command capabilities in `CapabilityRegistry`.
- Resolve env values from declared sources.
- Pass only configured env to child commands.
- Add `Setup.SecretWriter` with helper detection via `System.find_executable/1` (`security` first; `secret-tool`, `pass`, `op` follow as demand surfaces).
- Wire the wizard credential-entry step so typed setup secrets land in the operator-chosen helper, not in `config.toml`.
- Add `fermix sandbox env set / get / unset`.
- Add channel slash commands for sandbox env and command-profile updates.
- Detect plaintext values for all setup secret paths on first M5 boot; offer per-secret opt-in migration.
- Verify `~/.fermix/auth.json` perms at boot; refuse to start if they have widened.

Verify:

- Registry tests.
- Mock command tests.
- Env passthrough tests.
- Missing env failure tests.
- `SecretWriter` Stub tests for each backend shape and helper detection path.
- Wizard assertion: no plaintext setup secret reaches `config.toml`.
- Migration round-trip test against a fixture pre-M5 config.
- Migration coverage for all setup secret paths and the realtime API key prompt.
- `auth.json` perms-widened boot refusal using `File.stat!` mode.
- Channel command tests for env and command-profile updates.

### Stage 6 - Doctor and Docs

Step:

- Add `fermix doctor` sandbox checks.
- Add doctor trace scan for recent out-of-root `file_write`, `file_edit`, `git_write`, and shell cwd targets, with `fermix grant path <dir>` suggestions.
- Document launchd/systemd env behavior.
- Add README operator summary.

Verify:

- Doctor tests.
- Full repo gates.

---

## 11. Open Questions

1. **Keychain source scope.** §6.1's `Setup.SecretWriter` detects `security` first with `System.find_executable/1` (macOS Keychain). `secret-tool` (Linux Secret Service), `pass`, and `op` follow as operator demand surfaces. Retrieval side (§6 `source = "command"`) already works against any of them because it is just `command` + `args` - the only thing that needs per-backend code is the *write* side in the wizard.
2. **Command preset contents.** `ai_tools` is clear. `dev_tools` should start small and avoid surprising system mutation. `gh`, `git`, `make`, and language runtimes are reasonable; package installers that mutate global locations can stay shell-only until there is real demand.
3. **Allow decisions in trace logs.** Telemetry should emit all decisions, but trace files may only need denies/hardlines by default.
4. **Shell absolute writes.** M5 accepts this limitation. If it becomes a real problem, the next stage is OS sandboxing, not a larger parser.
5. **Channel confirmation storage.** M5 keeps pending channel confirmations in memory only. If daemon restarts during the 60-second window, the operator reruns the slash command.

---

## 12. README Summary

Fermix runs tools under a simple local sandbox. The default `standard` mode is intentionally usable: the agent can work in `~/.fermix/workspace`, the project directory it was launched from, and common project folders such as `~/projects` or `~/src`, while OS roots, Fermix daemon state, credential directories, and catastrophic commands remain blocked. Use `strict` mode for tighter scope or `open` mode when you want the agent to reach across most of your home directory. Fermix-owned file and git write tools enforce path checks exactly; shell stays permissive but must run from an approved working root. Local tools such as Codex or Claude Code can be exposed through command presets or explicit command blocks, with only the env vars or credential files the operator chooses to pass through. M10 later adds approvals, leak scanning, and stronger isolation.

---

## 13. Pitfalls

- **Test cleanup wiped the host.** A generated cleanup hook called `File.rm_rf!` on a computed path that collapsed to `/`. Stage 0 exists to make that impossible before sandbox negative tests are written.
- **Do not claim shell filesystem isolation without OS support.** M5 constrains shell cwd and known catastrophic commands. It does not stop every program from writing absolute paths.
- **Hardline is a coarse guard, not a shell parser.** M5 blocks common catastrophic command strings, but Unicode confusables, aliases, advanced quoting, generated scripts, and command wrappers remain M10 territory.
