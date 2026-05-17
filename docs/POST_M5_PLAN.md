# Post-M5 Plan: Finish + Sandbox Env Unification

**Status:** Draft
**Date:** 2026-05-17
**Author:** Sujeeth / Aira
**Depends on:** M5 (sandbox core, channel commands, SafeRm, mode/profile rename)
**Blocks:** M10 — leaves the floor coherent enough that M10's Sentinel / leak detector / approval flow can bind to a single declared-secret registry instead of two.

---

## 1. Context

M5 shipped the sandbox core: enforcement, modes (`strict`/`standard`/`open`), command profiles (`bare`/`assistant`/`extended`), hardline, env passthrough, channel commands, SafeRm test discipline. 1278 tests green.

Two halves of the M5 design did not ship:

1. The §6.1 wizard secret writer that puts provider/channel API keys into the OS-native secret store instead of plaintext `config.toml`.
2. The §10 Stage 6/7 polish: doctor trace scan, sandbox wizard step, `auth.json` perms-widened boot refusal.

Separately, the M4.9 outbound MCP layer reads env via a parallel `$env:KEY` shorthand that bypasses `Sandbox.Env` entirely. Declaring `[sandbox.env.OPENAI_API_KEY] source = "command"` does not make Peekaboo or any other MCP server see the value. The Peekaboo entry in `~/.fermix-dev/config.toml` works around this with an inline `sh -c "OPENAI_API_KEY=$(/usr/bin/security ...) exec npx ..."` invocation.

This plan covers both gaps.

---

## 2. Track A — Finish M5

Two-and-a-half working days. Five slices, four PRs (A2/A4/A5 bundle).

### 2.1 A1. Wizard secret writer + `"@keyring"` sentinel (macOS-first)

**Goal.** Provider and channel API keys typed during setup land in macOS Keychain via `/usr/bin/security`, not in plaintext `config.toml`. The wizard writes a sentinel string at each secret's TOML path; `ConfigStore` resolves the sentinel at load time by running the same `security` invocation.

**Scope:**

- `FermixCore.Setup.SecretWriter` (new module) — single backend in this PR: macOS `/usr/bin/security`. Detected via `System.find_executable("/usr/bin/security")`. Tests use a `:secret_writer` Application env binding to inject a Stub impl; the real binary is never called from `mix test`.
- `setup/wizard.ex` — replace the eight `put_*` writer paths (`put_openai_api_key`, the WhatsApp/Discord/Slack/Telegram token writers) with `Setup.SecretWriter.put/2` calls. Plaintext values never persist in the wizard's snapshot.
- `setup/config_store.ex` — `"@keyring"` sentinel detection in normalize paths. When the loader sees `api_key = "@keyring"` at a secret path, it dispatches to the SecretWriter's read side at load time, with bounded execution: `SecretWriter.get/1` runs the helper command (`/usr/bin/security find-generic-password ...`) under a per-call timeout (default 3000ms, matching `[sandbox.env.*].timeout_ms`) inside a `Task` with `Task.yield/Task.shutdown`. Reads are strictly noninteractive — no TTY, no fallback, no retry. On timeout / non-zero exit / missing entry / locked Keychain, `SecretWriter.get/1` returns `{:error, {tag, helper_command_string}}` and the loader fails the daemon boot with a clear actionable message: `"Could not resolve @keyring sentinel at [providers.openai].api_key — security find-generic-password timed out after 3000ms. Unlock your login Keychain or run security set-keychain-settings -lut 0 to disable auto-lock; or run 'fermix sandbox env set OPENAI_API_KEY' to reconfigure."` Fail-fast at boot, never silent passthrough of the literal `"@keyring"` string. This matches the noninteractive boot rule: secret reads run, but if they fail, the daemon refuses to start rather than serving requests with a missing key.
- Migration is an explicit operator action, not part of config load. Config load stays noninteractive — the daemon boot path under `launchd` / `systemd-user` has no TTY and must never block waiting for input. If `ConfigStore` sees plaintext values at any of the eight setup secret paths, it logs a one-line warning and leaves them in place; the values still work for the existing provider/channel reads (back-compat). Migration is triggered by a new `fermix setup --migrate-secrets` Mix task (and equivalent CLI subcommand). `fermix doctor` detects plaintext values and prints the exact migration command to run. The migration command iterates each plaintext path, prompts the operator for confirmation, calls `SecretWriter.put/2`, rewrites the TOML to `"@keyring"`, and preserves the pre-migration `config.toml` as `config.toml.pre-m5`.
- Non-macOS hosts: wizard falls back to "set the env var manually" with a clear message naming the env var and the right place to set it (shell rc / systemd unit / launchd plist). No silent failure.
- OAuth blobs (`~/.fermix/auth.json`) stay as `0600` plaintext per §6.1's atomicity argument. Not touched by this PR.

**Effort:** ~1 day.

**Tests:**

- SecretWriter Stub round-trip (put → get returns same value).
- Wizard: each of the eight secret paths gets written via SecretWriter, not into the snapshot. Assert the snapshot contains the `"@keyring"` sentinel at each path and no key bytes anywhere.
- ConfigStore sentinel resolution: `"@keyring"` at `[fermix_core.providers.openai].api_key` resolves via Stub to the registered value.
- Migration fixture: the `fermix setup --migrate-secrets` command (not daemon boot) loads a pre-M5 config with plaintext keys, prompts per-key from the controlling TTY, and on completion the rewritten config has `"@keyring"` sentinels at each migrated path and a `config.toml.pre-m5` backup. Daemon boot against a pre-migration config remains noninteractive — it logs a one-line warning, leaves the plaintext values in place, and the provider reads continue to work.
- Non-macOS host fallback: wizard prints the manual-env instructions and does not raise.

**Acceptance:**

- `mix test`, `mix credo --strict`, `mix format --check-formatted`, `mix compile --warnings-as-errors` all green.
- Setting an API key through the wizard never writes the key bytes to `~/.fermix/config.toml` or the persisted snapshot.

### 2.2 A2. `auth.json` perms-widened boot refusal

**Goal.** Daemon refuses to start if `~/.fermix/auth.json` is not `0o600`. `fermix doctor` reports the same check.

**Scope:**

- `application.ex` (or `auth/store.ex` boot hook) calls `File.stat!(Auth.Store.path())` and inspects `Bitwise.band(mode, 0o777)`. If `!= 0o600`, exit non-zero with a clear message: "~/.fermix/auth.json has perms 0o644 (expected 0o600). Run `chmod 600 ~/.fermix/auth.json` and restart."
- `fermix doctor` adds the same check, reports red with the same fix command.
- File-absent case: not an error. The check applies only when the file exists.

**Effort:** ~1 hour. Bundled into PR 1 with A4 and A5.

**Tests:** `auth.json` with `0o644` causes boot failure; `0o600` allows boot; missing file is a no-op.

### 2.3 A3. Persist sandbox decisions, then doctor trace scan

**Goal.** After M5 boot, `fermix doctor` scans the last N days of traces for `file_write` / `file_edit` / `git_write` / `shell` cwd targets outside the auto-allowed roots. Prints one `fermix grant path <target>` suggestion per distinct denied location. Advisory only — no auto-grant.

**Precondition this slice has to add first.** `Sandbox.Decision.emit/2` today only calls `:telemetry.execute([:fermix, :sandbox, :decision], ...)`. Nothing subscribes to that event and writes to `~/.fermix/traces/`. Without persistence the doctor scan would report green forever. So this slice has two parts:

1. **Trace persistence (new):** add a telemetry handler attached at application start that subscribes to `[:fermix, :sandbox, :decision]` and writes `:deny` and `:hardline` events to JSONL via `Trace.record/4` (or the lower-level writer it uses). **`Trace` itself needs widening first:** today `FermixCore.Trace`'s `@valid_types` is `[:llm_call, :tool_exec, :agent_event, :channel_msg, :error]` and the typespec matches. `:sandbox_event` is not in that list, so `Trace.record(:sandbox_event, ...)` would not satisfy the function guard. Add `:sandbox_event` to both `@valid_types` and the `trace_type` typespec as the first step of this slice. `:allow` events are NOT persisted by default (M5 §8 already said so) to keep trace files small. The handler decodes the `reason` tuple shape — `{:outside_root, path}`, `{:protected_path, path}`, `{:blocked_root, path}`, `{:missing_env, name}` — and serializes the path/name explicitly so the scan doesn't have to re-pattern-match raw Erlang terms from JSON.
2. **Doctor scan (new):** reads the last 7 days of trace files, filters for `:sandbox_event` rows with `decision = :deny` and `reason.tag in [:outside_root, :blocked_root]`, groups by suggested-grant target (see A4 — shell denies suggest the cwd itself; file/edit denies suggest `Path.dirname(target)`; git denies suggest the repo root), caps at 20 distinct suggestions.

**Scope:**

- `FermixCore.Sandbox.Decision.Telemetry` (new module) attached at `Application.start/2`. Idempotent — attach once, never duplicate handlers.
- Trace event shape: `%{ts: utc, decision: :deny | :hardline, capability: name, policy_class: class, reason_tag: atom, resource: path_or_name, agent: name, conversation_key: key}`.
- `cli/doctor/checks.ex` (or equivalent) new check that walks `~/.fermix/traces/YYYY-MM-DD/*.jsonl`, filters for sandbox-event rows, groups, prints.

**Effort:** ~3-4 hours (was 2-3; added trace persistence).

**Tests:**

- Telemetry handler attach: invoking `Sandbox.Decision.emit({:deny, {:outside_root, "/foo"}}, %{...})` writes a row to the test trace dir.
- Telemetry handler ignores `:allow` (no row written) and persists `:hardline`.
- Reason tuple decoding: each of `{:outside_root, _}`, `{:protected_path, _}`, `{:blocked_root, _}`, `{:missing_env, _}` round-trips through JSON correctly.
- Doctor scan: trace fixture with a denied `file_write` to `~/Workspace/foo/x.txt` produces a suggestion for `fermix grant path /Users/sujshe/Workspace/foo` (parent dir for file targets, per A4).
- Doctor scan: trace fixture with a denied shell cwd `/Users/sujshe/Workspace/foo` produces a suggestion for `fermix grant path /Users/sujshe/Workspace/foo` (the cwd itself, per A4).
- Multiple denies under the same suggested target collapse to one suggestion.
- Empty trace directory: no suggestions, green check.
- Distinct-target cap: 30 denies in 25 targets → 20 suggestions printed plus a "+5 more" tail.

### 2.4 A4. Roadblock-message audit (sandbox + env + doctor)

**Goal.** Every sandbox roadblock tells the operator the exact command to fix it. No deny path leaves the agent (or the operator) guessing.

**Scope:**

Concrete sites where the deny-message format upgrades from "Sandbox denied X" to "Sandbox denied X. To allow this, run `<exact command>`":

| File | Function | Current shape | New shape |
| --- | --- | --- | --- |
| `tools/shell.ex` | `format_error/1` | `"Sandbox denied shell working_dir outside roots: #{path}"` | `"... outside roots: #{path}. To allow this directory, run: fermix grant path #{path}"` — grant the resolved working dir itself, not its parent. The shell's `path` is already a directory, and using `Path.dirname` would over-grant (`~/projects/app` would become `~/projects`, which is broader than the operation needs and may be `$HOME`-adjacent enough that `add_allowed_root` rejects it). |
| `tools/file_write.ex` | `format_error/1` | `"Sandbox denied file_write outside roots: #{path}"` | `"... outside roots: #{path}. To allow, run: fermix grant path #{Path.dirname(path)}"` — `Path.dirname` is correct here because `path` is a file target, and granting the directory containing it is the minimum scope. |
| `tools/file_edit.ex` | `format_error/1` | same shape as file_write | same fix as file_write (`Path.dirname(path)`) |
| `tools/git_write.ex` | `format_error/1` | `"Sandbox denied git_write outside roots: #{path}"` | git_write has two deny points and the message must distinguish them. **Pre-discovery deny** (line 68, `Sandbox.working_dir(repo, ...)` rejects the *input* repo path before `git rev-parse` runs): `"... outside roots: #{input_path}. To allow, run: fermix grant path #{input_path}"` — grant the resolved input dir; the actual repo root is unknown at this point. **Post-discovery deny** (line 70, `Sandbox.write_path(repo_root, ...)` rejects the resolved repo root after `git rev-parse --show-toplevel`): `"... outside roots: #{repo_root} (resolved from input #{input_path}). To allow, run: fermix grant path #{repo_root}"` — grant the resolved root, since that's the actual containment boundary git_write enforces. The two cases are distinguished by which `Sandbox.*` call returned the error. |
| `sandbox/env.ex` | `:missing_env`, `:env_command_failed`, `:env_command_timeout`, `:env_command_output_too_large`, `:empty_env_command_output` | bare atom return | "ENV_NAME could not be resolved via configured source. Run `<helper command>` manually to verify; or `fermix sandbox env set ENV_NAME` to reconfigure." |
| `cli/sandbox_command.ex` | usage/error output | bare strings | name the next command (`fermix sandbox status`, `fermix grant path`, etc.) |
| `channels/commands/sandbox.ex` | `propose/3` / `apply_now/2` error replies | bare error tuple | name the next slash command |

Cross-cutting rule: deny messages emit two pieces — what was denied (with the *resolved* path, not the input path) and the exact CLI/slash command to fix it.

Granularity rule for the fix-command target:

| Tool family | What `path` is in the deny | Grant suggestion |
| --- | --- | --- |
| `shell` | the resolved cwd | the cwd itself |
| `file_write` / `file_edit` | the resolved file target | `Path.dirname(path)` |
| `git_write` | the resolved repo root | the repo root itself |
| `sandbox/env.ex` | the env name and configured source | helper command + `fermix sandbox env set` |

**Effort:** ~2-3 hours. Largely mechanical. Bundled into PR 1.

**Tests:**

- One test per format_error clause asserts the message contains both the denied resource and the fix command.
- Snapshot-style: assert the message includes the substring `"fermix grant path"` or `"fermix sandbox env set"` as appropriate.

### 2.5 A5. Rename migration error (option (a) — clear error at boot)

**Goal.** Existing operators with `mode = "developer"` / `profile = "trusted"` / etc. in `config.toml` get a clear `ArgumentError` at boot naming the old → new mapping and the exact fix command.

**Scope:**

- `sandbox/config.ex` `enum_value/3` already raises `ArgumentError` for invalid enums. Extend the message: when the invalid value is `"developer"`, `"workspace"`, `"trusted_local"`, `"none"`, `"trusted"`, include the rename mapping and the CLI fix.
- Same shape for `commands.profile`.

Example message:

```
invalid sandbox mode "developer". The names changed in M5:
  workspace -> strict
  developer -> standard
  trusted_local -> open
Run: fermix sandbox mode standard
Or edit ~/.fermix/config.toml: mode = "developer" -> mode = "standard"
```

**Effort:** ~30 minutes. Bundled into PR 1.

**Tests:** boot with each old name asserts the error message contains the new-name mapping and the CLI fix.

---

## 3. Track B — Sandbox Env Unification (post-M5)

One slice. Half day. Drops the `$env:KEY` shorthand because pre-release; no migration burden.

### 3.1 B1. Route MCP env through `Sandbox.Env`, drop `$env:KEY`

**Goal.** One env-passthrough registry for the whole daemon. `[sandbox.env]` is the single declared-secrets registry. Shell, sandbox command capabilities, and MCP servers all spawn with env built by `Sandbox.Env`. `[sandbox.env].mode = "all"` extends to MCP.

**Scope:**

- `Capabilities.MCP.Config` learns a `pass_env` field on `[mcp.servers.<name>]` blocks: list of env-var names the server wants Fermix to inject at spawn time. Validation of names follows the active `[sandbox.env].mode`: in `selected` mode, every `pass_env` name must appear in `[sandbox.env].allow`; in `all` mode, names without a configured source still resolve from daemon env (matching `Sandbox.Env`'s existing `selected_env(%Config{env: %{mode: :all}}, ...)` branch) — `pass_env` names do NOT have to be declared in `[sandbox.env]` in `all` mode.
- **Conflict rejection at config load:** if the same name appears in both `pass_env` and the literal `env = { ... }` block on the same server, `Capabilities.MCP.Config.from_toml/1` raises with a clear error naming the duplicate. Operators pick one; no silent precedence.
- The MCP outbound supervisor (wherever it spawns the server — likely `mcp/supervisor.ex` or equivalent), when starting a server, builds the effective env with a documented precedence ladder:
  ```
  {:ok, sandbox_env} = Sandbox.Env.build_command(Sandbox.Config.current(), spec.pass_env)
  literal_env = Map.new(spec.env)
  # Precedence (lowest to highest): sandbox defaults, sandbox-resolved pass_env, literal MCP env.
  # Conflict between pass_env and literal env is rejected at config load (see above), so the
  # merge below is unambiguous: literal env wins over defaults; pass_env wins over defaults
  # but never overlaps literal env.
  effective_env =
    sandbox_env                  # includes PATH, HOME, USER, LANG, SHELL, TMPDIR + resolved pass_env
    |> Map.new()
    |> Map.merge(literal_env)    # operator's literal env = { ... } wins over defaults
  ```
  …then passes `effective_env` to the spawn call. The rationale: operator-typed values in `env = { ... }` are explicit operator choice and must beat any Fermix-injected default (e.g., operator setting `env = { PATH = "/opt/custom/bin:..." }` should not be silently overridden by `Sandbox.Env`'s daemon-`PATH` default). Conflicts with `pass_env` are rejected loudly so the operator must pick one declaration shape per name.
- `$env:KEY` literal-string parsing in `Capabilities.MCP.Config` is **deleted, not deprecated.** No migration shim. Anyone with a `$env:KEY` value gets the same A5-shaped clear error: `"MCP env value '$env:GITHUB_TOKEN' uses the removed $env: shorthand. Declare GITHUB_TOKEN in [sandbox.env] and reference it via pass_env = [\"GITHUB_TOKEN\"]."`
- The Peekaboo entry in `~/.fermix-dev/config.toml` is rewritten as part of this PR's smoke test:

  ```toml
  [mcp.servers.peekaboo]
  command = "npx"
  args = ["-y", "@steipete/peekaboo"]
  env = { PEEKABOO_AI_PROVIDERS = "openai/gpt-5.5" }
  pass_env = ["OPENAI_API_KEY"]
  ```

  …assuming `[sandbox.env.OPENAI_API_KEY]` is already configured with `source = "command"` against Keychain.

**Effort:** ~4-6 hours.

**Tests:**

- MCP config parser accepts `pass_env`.
- MCP supervisor merges literal env + Sandbox.Env-built env at spawn time.
- `selected` mode: server with `pass_env = ["FOO"]` where `FOO` is not in `[sandbox.env].allow` → clear deny message naming the missing `[sandbox.env.FOO]` block and the fix command (`fermix sandbox env allow FOO`).
- `all` mode: server with `pass_env = ["FOO"]` where `FOO` is not in `[sandbox.env].allow` but **is not** in `[sandbox.env].deny` → resolves successfully, via configured source if present, otherwise via daemon-env fallback (`Sandbox.Env` already does this in `selected_env(%Config{env: %{mode: :all}}, ...)` — confirm the existing branch covers MCP too).
- `all` mode: server with `pass_env = ["FOO"]` where `FOO` is in `[sandbox.env].deny` → deny with the same clear message naming the denylist as the cause and `fermix sandbox env allow FOO` (or removing the deny entry) as the fix.
- `$env:KEY` rejection produces the A5-shaped error.
- Config-load conflict: server with `pass_env = ["OPENAI_API_KEY"]` AND `env = { OPENAI_API_KEY = "literal-value" }` → `Capabilities.MCP.Config.from_toml/1` raises with a clear error naming the duplicate name and instructing the operator to pick one shape.
- Merge precedence: server with `env = { PATH = "/opt/custom/bin" }` and `pass_env = ["OPENAI_API_KEY"]` → spawned process sees `PATH = "/opt/custom/bin"` (literal beats sandbox default), `OPENAI_API_KEY` from `Sandbox.Env`, plus the remaining defaults (HOME, USER, etc.) from `Sandbox.Env`. No silent overlap.
- Integration: Peekaboo-shaped fixture starts with `pass_env = ["OPENAI_API_KEY"]` and `[sandbox.env.OPENAI_API_KEY] source = "command"` — `Sandbox.Env.build_command/2` (via Stub) returns the expected value.

**Doc:**

- M5 §6 gets a paragraph saying MCP env routes through Sandbox.Env via `pass_env`.
- M4.9 / outbound MCP doc gets the same. Remove any `$env:KEY` references.

---

## 4. PR Order

Four PRs. PR 1 first because it's lowest-risk and establishes the error-message format the rest of the work follows.

### PR 1 — Clear-error UX (A2 + A4 + A5)

Half day. No new behaviour, no migration, just clearer errors and a perms check.

- A2: `auth.json` perms-widened boot refusal.
- A4: every deny-message site upgraded to include the fix command.
- A5 (a): rename migration errors.

Tests for each. Ships standalone.

### PR 2 — Wizard secret writer (A1)

One day. The largest single slice.

- `Setup.SecretWriter` macOS backend + Stub.
- Wizard wiring for all eight secret paths.
- `ConfigStore` `"@keyring"` sentinel resolution.
- One-time plaintext migration prompt.
- Non-macOS fallback.

Ships after PR 1 so migration-prompt error paths use the A4 format.

### PR 3 — Doctor trace scan (A3)

Half day. Depends on PR 1's deny-message format.

- Trace reader, dedup by parent, advisory output.
- `fermix doctor` integration.

### PR 4 — MCP env unification (B1)

Half day. Independent of A1-A4; can land after PR 1 in any order.

- `Capabilities.MCP.Config` learns `pass_env`.
- Outbound supervisor routes through `Sandbox.Env`.
- `$env:KEY` deletion + A5-style migration error.
- Peekaboo config rewrite as the smoke test.

---

## 5. Explicitly Out of Scope

- Keyring NIF / `age` encryption — M5 design intentionally dropped these. `source = "command"` covers the same surface via the operator's existing helpers.
- Linux `secret-tool` / `pass` / `op` SecretWriter backends — roadmap (§6).
- Windows `Wincred` SecretWriter backend — roadmap (§6); aligned with M4.8 Windows deferral.
- Auto-detection of project roots beyond the five common ones (`~/projects`, `~/src`, `~/code`, `~/work`, `~/dev`). Operator adds custom roots via `fermix grant path`. A4 ensures the agent tells them how.
- A wizard step that prompts for sandbox mode / project roots — dropped in favor of A4's "clear error tells the operator" model.
- OAuth-blob keychain migration — `auth.json` stays as `0600` plaintext per §6.1.
- M10 work — Sentinel, leak detector, prompt-injection guard, per-call approval, audit signing.
- Shell operand parser — still an accepted M5 tradeoff.
- Per-skill ACLs.

---

## 6. Roadmap (Backburner)

These are not blockers. Land when there is operator demand.

| Item | Trigger to land |
| --- | --- |
| Linux `secret-tool` SecretWriter backend | First Linux operator install that wants Keychain-equivalent secret storage. |
| `pass` SecretWriter backend | Operator request. |
| `op` (1Password CLI) SecretWriter backend | Operator request. |
| Windows `Wincred` SecretWriter backend | After M4.8 Windows port lands. |
| Auto-detect `~/Workspace`, `~/repos`, `~/Documents/code` in `developer` mode common roots | Second operator complaint about manual grant on first run. |
| Doctor scan: protected-path read alerts | M10. |
| `$env:KEY` shorthand revival (if anyone misses it) | Unlikely; the unified `pass_env` form is strictly more capable. |

---

## 7. Pitfalls Carried From M5

- **Test cleanup wiped the host.** SafeRm + `test_safety_test.exs` guards must stay green for all PRs. No PR adds a direct `File.rm_rf` call in `test/`.
- **Provider key plaintext in `config.toml`.** A1 closes this loop, but until A1 lands, every PR must avoid logging or tracing the resolved secret value. A4 specifically: deny messages must include the *fix command* but never the value of a resolved env source.
- **MCP server env defaults wide.** B1's spawn-time env merge starts from `Sandbox.Env.build_command/2` output plus the literal `env` block — nothing else. No daemon-env leak.
- **Rename collisions in operator configs.** A5 is the boot-time canary. Anyone hitting the error gets a single CLI command to fix it; no auto-rewrite, no silent degradation.

---

_M5 shipped the floor. This plan finishes the polish and unifies the env-passthrough surface so the floor reads as one coherent design instead of two parallel ones._
