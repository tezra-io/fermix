# Changelog

All notable changes to Fermix are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Fixed — M4.8 review
- `scripts/release/build_releases_json.sh` previously rewrote every
  underscore in the artifact filename, turning `fermix_macos_x86_64`
  into target `macos-x86-64`. The installer, upgrader, and Homebrew
  bumper all expect `macos-x86_64` / `linux-x86_64`, so x86_64
  Linux and Intel macOS users could not find their artifact in
  the published manifest. Now only the os/arch separator is
  rewritten; `x86_64` stays intact.
- `Fermix.CLI.Daemon` no longer unlinks the control socket
  unconditionally on boot. We probe first: if a daemon is already
  bound, we abort with `{:another_daemon_running, path}` instead of
  unlinking the live socket out from under the running daemon and
  leaving it unreachable via `status` / `stop`. Stale sockets
  (no listener) are still removed.
- `Fermix.CLI.Upgrade.InstallMethod` now follows symlinks and
  consults `brew --prefix`. Intel Homebrew installs link
  `/usr/local/bin/fermix` to a Cellar path, and the link itself
  contains neither `/Cellar/` nor `/homebrew/`. The previous check
  classified those as unmanaged, allowing `fermix upgrade` to
  replace the brew symlink with a raw binary and desync the
  package manager. Brew symlinks are now correctly detected.
- `Fermix.CLI.Upgrade.run/1` only rolls back from the
  `~/.fermix/.previous` recovery slot when a swap actually
  happened. Pre-swap failures (download error, sha mismatch,
  cosign failure) leave the running binary alone; previously they
  could quietly overwrite the current binary with a stale recovery
  slot from an earlier upgrade attempt.
- `scripts/install.sh` no longer aborts when only `sha256sum`
  (and not `shasum`) is on PATH — common on minimal Linux. The
  preflight now accepts either tool.

### Added — M4.8 Stage 7 (`fermix doctor`)
- `Fermix.CLI.Doctor` aggregates one-shot diagnostic checks into a
  uniform table-style report. Returns exit `0` when no checks fail
  (warnings are allowed) and exit `1` otherwise so monitoring
  scripts can branch on it. The default invocation is offline; the
  `--full` flag opts into network checks (binary integrity vs the
  signed manifest, upgrade availability).
- `Fermix.CLI.Doctor.Checks` — readiness (reuses
  `FermixCore.Readiness`), workspace layout (`FERMIX_HOME` and
  subdirs exist), service unit installed, daemon control socket
  reachable, recent log activity (warns when stale > 24h), Linux
  user-scope linger state, sha256 binary integrity vs the manifest
  for the host's target, and upgrade availability.
- `fermix doctor [--full]` wired through `Fermix.CLI.Doctor` and
  documented in the usage banner.

### Added — M4.8 Stage 6 (Distribution channels)
- `scripts/install.sh` — POSIX `sh` installer for the published
  binary. Detects (os, arch), pulls `releases.json` from the latest
  GitHub Release, sha256-verifies the binary against the manifest,
  and installs to `/usr/local/bin` (with `sudo` if needed) or
  `~/.local/bin` (no sudo). Aborts on any sha mismatch or
  unsupported (os, arch) — there is no "best effort" partial
  install. `--prefix DIR` overrides the install location;
  `--no-setup` skips the post-install `fermix setup` wizard. Meant
  to be invoked as `curl -fsSL https://fermix.sh/install | sh`.
- `scripts/homebrew/fermix.rb` — starter Homebrew formula with all
  four `on_macos`/`on_linux` × `on_arm`/`on_intel` artifact blocks
  pre-wired. Versions and sha256s are placeholders that the bumper
  rewrites.
- `scripts/homebrew/bump.sh` — release-pipeline helper that reads
  `releases.json` and rewrites the formula's `version`, `url`, and
  `sha256` lines for each target. Idempotent and stateless. Used by
  CI to open auto-bump PRs against `tezra-io/homebrew-fermix`.

### Added — M4.8 Stage 5 (`fermix upgrade`)
- `Fermix.CLI.Upgrade.Manifest` fetches and parses the signed
  `releases.json` manifest, compares the running version against
  `latest`, and selects the binary artifact for the host
  (os/arch). Schema mismatches and non-200 responses surface
  verbatim instead of degrading to "no upgrade available".
- `Fermix.CLI.Upgrade.InstallMethod` detects Homebrew (Cellar paths)
  and dpkg-managed installs and refuses to mutate them. Returns
  `{:managed, name, hint}` so the CLI can print the right
  `brew upgrade` / `apt upgrade` command instead of silently
  overwriting package-manager files.
- `Fermix.CLI.Upgrade.Cosign` shells out to `cosign verify-blob`
  with the certificate identity pinned to the
  `tezra-io/fermix` release workflow file and OIDC issuer pinned to
  GitHub Actions. A forged cert minted against another repo cannot
  pass.
- `Fermix.CLI.Upgrade.Swapper` downloads the binary, signature, and
  certificate to a staging directory, sha256-verifies the binary
  against the manifest, snapshots the current binary into a one-shot
  `~/.fermix/.previous` recovery slot, and atomically renames the
  staged binary into the installed path. `rollback/2` is a single
  rename back from the recovery slot — there is no version history
  or A/B install.
- `Fermix.CLI.Upgrade.run/1` orchestrates the full
  fetch → verify → snapshot → rename → restart sequence, polls the
  control socket for up to 10s as a post-swap health check, and
  rolls back automatically when the health check fails.
- `~/.fermix/upgrades.jsonl` audit log records every attempt with
  `{from, to, timestamp, sha256, status}` for `fermix doctor`
  consumption (Stage 7).
- `fermix upgrade` and `fermix upgrade --check` are now wired
  through `Fermix.CLI.UpgradeCommand`. `--check` reports current vs
  latest and the install method without touching disk.

### Added — M4.8 Stage 4 (OS daemon integration)
- `Fermix.CLI.Service` and the `Service.Templates`, `Service.Launchd`,
  `Service.Systemd` backends — install/uninstall/start/stop the
  daemon as a launchd `.plist` (macOS) or systemd `.service` unit
  (Linux). Two scopes per OS — user (default; per-user, no sudo) and
  system (`--system`; boot survival, sudo). On Linux user-scope, the
  installer runs `loginctl enable-linger` and aborts non-zero with
  the exact retry instructions if it fails (no degraded
  "works-while-logged-in" half-state).
- `fermix service install|uninstall [--user|--system]`,
  `fermix start|stop|restart [--user|--system]`. Each command
  refuses to operate when no unit is installed in the requested
  scope and points the operator at the right next step instead of
  silently no-op'ing.
- `Fermix.CLI.Daemon` — Unix-domain control socket
  (`~/.fermix/daemon.sock`, `0600`) that serves a tiny
  newline-delimited JSON request/response protocol. Methods:
  `status` (returns version, uptime, pid) and `shutdown` (replies
  then halts the BEAM via `:init.stop()`). Started only inside
  `fermix run`; stale sockets from prior crashes are removed on
  boot.
- `fermix status` queries the control socket and prints the daemon's
  liveness, version, uptime, and pid. Returns exit `3` when nothing
  is listening so monitoring scripts can branch on the conventional
  "service not running" signal.
- `fermix logs [-f|--follow] [-n LINES]` streams
  `~/.fermix/logs/fermix.log` via `tail`. Aborts with a clear
  message when the log file does not yet exist instead of hanging.
- File-logger rotation default bumped from 5 × 10 MB to 10 × 10 MB to
  match the milestone's stated retention budget.

### Added — M4.8 Stage 3 (Fermix-owned auth, drop runtime ~/.codex)
- `FermixCore.Auth.Store` — versioned, provider-scoped JSON store at
  `~/.fermix/auth.json`. Atomic writes via tmp+rename, `0600` perms,
  silent migration of the M3-era flat shape into the new nested
  schema.
- `FermixCore.Auth.RefreshClient` — extracted OpenAI token refresh
  HTTP shape so `TokenManager` and the new Codex import use one
  implementation.
- `FermixCore.Auth.CodexImport` — one-shot `~/.codex` → `~/.fermix`
  migration. Performs a single OAuth refresh against the Codex
  refresh token, persists the result, and never reads `~/.codex`
  again. Fails loud if the refresh fails (no degraded path).
- `fermix setup --import-codex` (also offered interactively when the
  Codex CLI auth file is detected and OpenAI is otherwise missing).
  Marks the openai provider with `auth_mode: :oauth` so subsequent
  daemon boots start `TokenManager`.
- `Readiness` recognizes `auth_mode == :oauth` as the canonical
  OAuth-configured signal alongside the legacy credential keys.

### Removed
- `TokenManager` no longer reads `~/.codex` at runtime — the codex
  bootstrap path, `:fork_refresh` handler, and the M3-temporary
  TODO comment are gone. A daemon that starts without
  `~/.fermix/auth.json` (or any equivalent provider config) logs a
  warning and `:get_token` returns `{:error, :no_token}`. Operators
  re-run `fermix setup` to migrate.

### Added — M4.8 Stage 2 (cross-compile + signed releases)
- `mix.exs` Burrito targets now cover `macos_aarch64`, `macos_x86_64`,
  `linux_aarch64`, `linux_x86_64`. Cross-compile from a macOS arm64 host
  validated locally (`fermix_linux_aarch64` builds as a 19 MB statically
  linked ELF).
- `.github/workflows/release.yml` — tag-driven (`v*.*.*`) release
  pipeline on `ubuntu-24.04`. Verifies tag matches `mix.exs` version,
  builds all four targets, signs each binary with cosign keyless OIDC,
  generates `releases.json`, and creates a GitHub Release with the
  binaries, signatures, certificates, and manifest attached. Auto-
  generated release notes include the cosign verification command.
- `scripts/release/build_releases_json.sh` — emits the signed-release
  manifest consumed by `fermix upgrade` (Stage 5). Schema is documented
  inline; `schema_version` field bumps on breaking changes.

### Added — M4.8 Stage 1 (Burrito single-binary)
- `fermix` CLI dispatcher (`Fermix.CLI`) routing argv to subcommand modules
  (`setup`, `run`, `version`, `help`). `start`/`stop` are registered but
  print a Stage 4 deferral message and exit `2` rather than silently
  delegating to `run`.
- Release-safe `FermixCore.Setup.Runtime` extracted from
  `Mix.Tasks.Fermix.Setup`; the Mix task is now a thin wrapper.
- `FermixCore.Application.start/2` decides at boot whether the binary was
  invoked through Burrito (`Burrito.Util.running_standalone?/0`) and
  routes accordingly:
  - `setup` — full supervision tree (needed for `Memory.Repo`), then
    `System.halt/1` before sibling apps boot. No port bind.
  - `run` — enable Phoenix endpoint server in env, start the supervision
    tree, and spawn the foreground daemon CLI. All sibling apps remain
    `:permanent` so OTP keeps the BEAM alive.
  - `version` / `help` / `start` / `stop` / unknown — read-only;
    `System.halt/1` runs before any sibling app starts. No file logger,
    no `Memory.Repo`, no `TokenManager`, no port bind.
- Burrito wrap step in `mix.exs`; `macos-aarch64` target shipped first.
- `FERMIX_HTTP_BIND` runtime env (default `127.0.0.1`) parsed via
  `:inet.parse_address/1`. Invalid values raise during `runtime.exs`
  evaluation so the daemon fails loud at boot rather than silently
  binding the wrong interface.
- Auto-generated `SECRET_KEY_BASE` if the env var is unset, so a freshly
  installed binary can boot before the user has configured anything.

### Distribution — Stage 1 acceptance gate
- **Compressed binary size:** `fermix_macos_aarch64` is **11 MB**
  (`11,455,336 bytes`). Hard ceiling for M4.8 is 100 MB; well within
  budget.
- Stage 1 verified end-to-end on `aarch64-apple-darwin`:
  `version` / `help` / unknown commands halt before any supervision tree
  starts; `setup --print-state` boots the full tree and halts; `run`
  binds `127.0.0.1` by default and `0.0.0.0` via `FERMIX_HTTP_BIND`.

### Known
- The packaged release logs a startup warning that
  `priv/static/cache_manifest.json` is missing. This is a pre-existing
  Phoenix digest-pipeline gap (the cache manifest is not produced by the
  current build) and does not block `fermix run`. Tracked separately.
