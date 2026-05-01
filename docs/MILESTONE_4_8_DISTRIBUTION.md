# Milestone 4.8: Distribution & Daemon — Functional Design

**Status:** Draft
**Date:** 2026-04-26
**Author:** Sujeeth / Aira
**Depends on:** M3 (`Setup.Wizard`, `mix fermix.setup`), M4.7 (setup-time prompt seeding), `FermixCore.Auth.TokenManager`
**References:** `docs/ROADMAP.md` (M3, M8, Future/Extended Providers), `docs/MILESTONE_3_ONBOARDING_CHANNEL_COVERAGE.md` §5.6, `apps/fermix_core/lib/fermix_core/auth/token_manager.ex`, [Burrito](https://github.com/burrito-elixir/burrito), [Codex CLI auth flow](https://github.com/openai/codex)

---

## 1. Problem / Goal

After M4.7, Fermix is a working dev project: clone the repo, run `mix deps.get`, run `mix fermix.setup`, run `iex -S mix phx.server`, and the agent is alive. The wizard hands you a complete prompt-bootstrap and a configured Telegram channel. That experience is good for *developers* and useless for everyone else.

**Three concrete blockers stop a non-developer from running Fermix on their own machine today:**

| Blocker | Today | Required for "install once and forget" |
|---------|-------|----------------------------------------|
| Install | clone repo + Erlang/Elixir toolchain + `mix deps.get` | Single-command install. No language toolchain on the host. |
| Run | `iex -S mix phx.server` in a foreground terminal | Background daemon. Survives reboot. Restarts on crash. |
| Authenticate to OpenAI | `TokenManager` bootstraps from `~/.codex/auth.json` (Codex CLI must be installed and logged in) | Native Fermix auth profile; no Codex CLI dependency. |

The roadmap fragments this across three places:
- M3 shipped the `mix fermix.setup` wizard and the `fermix setup` release alias *concept* but not the release-binary distribution.
- M8 lists "Docker images" (P1) and "Systemd service" (P2) but no macOS daemon, no installer, no upgrade story.
- "OpenAI Codex provider" sits in **Future / Extended Providers** as M effort, deferred indefinitely. The `TokenManager` source already flags this: *"Temporary: remove codex bootstrap + fork once M3 onboarding persists tokens directly"* (`apps/fermix_core/lib/fermix_core/auth/token_manager.ex:92`).

**Goal of M4.8:** turn Fermix from a runnable project into an **installable product**. After this milestone:

1. A user runs one command (e.g. `brew install fermix` or `curl -fsSL https://fermix.sh/install | sh`) and gets a single executable on their PATH.
2. They run `fermix setup` once. The wizard completes; the binary registers itself as a launchd / systemd service; the agent comes up under OS-level supervision and survives reboot.
3. The wizard's OpenAI step offers **Sign in with OpenAI** or **Use API key**. OAuth opens the browser on desktop, falls back to a printed URL/code in headless sessions, and persists Fermix-owned provider state into `~/.fermix/auth.json`. Optional Codex CLI token import may exist, but `~/.codex` is not a runtime dependency.
4. `fermix upgrade` pulls the latest signed release and restarts the service in place.

Non-goal: Windows desktop, mobile, multi-tenant cloud hosting. Those stay in M9 / Future.

---

## 2. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| Burrito single-binary build | P0 | New | Wrap `mix release fermix` with [Burrito](https://github.com/burrito-elixir/burrito) to produce one self-extracting binary per `(os, arch)` target. Bundles ERTS and all OTP apps. If native helpers are added before release, they must be validated per target. |
| Cross-compile matrix | P0 | New | Build targets: `macos-aarch64`, `macos-x86_64`, `linux-aarch64`, `linux-x86_64`. Windows deferred. |
| `fermix` CLI surface | P0 | New | Single binary with subcommands: `setup`, `run`, `service install`, `service uninstall`, `start`, `stop`, `restart`, `status`, `logs`, `upgrade`, `uninstall`, `version`, `doctor`. Routes to release-safe runtime modules; Mix tasks remain dev wrappers only. |
| OS daemon integration | P0 | New | `fermix service install` writes a launchd `.plist` (macOS) or systemd unit (Linux) and enables it. Service units execute `fermix run`. `fermix service uninstall` removes them. Logs go to `~/.fermix/logs/fermix.log` with rotation. |
| Native OpenAI auth | P0 | New | Wizard asks the user to choose OpenAI OAuth or API key. OAuth opens the browser when possible; in `--no-browser` / headless mode the same flow prints a URL and code (one flow, one UX branch on terminal capability — not a separate path). Tokens stored in `~/.fermix/auth.json`. Optional Codex CLI import is an onboarding convenience, not the source of truth. |
| `fermix upgrade` | P0 | New | Self-update for unmanaged installs: fetches the latest signed release manifest, downloads the platform-matching binary, verifies signature, swaps the executable atomically, restarts the service. Package-manager installs print the correct `brew` / `apt` command instead of overwriting managed files. |
| Versioning + release manifest | P0 | New | Bump `mix.exs` version on every release. Publish a signed `releases.json` listing `(version, target, sha256, signature, url)` to the release channel. |
| Release channel infrastructure | P0 | New | GitHub Releases as the source of truth. Optional `https://fermix.sh` redirect domain. Cosign or Minisign for signatures. |
| Homebrew tap | P1 | New | `brew install tezra-io/tap/fermix` formula in `tezra-io/homebrew-tap`. Auto-bumped from CI on release. |
| Linux install script | P1 | New | `curl -fsSL https://fermix.sh/install \| sh` detects `(os, arch)`, downloads the matching binary, drops it in `~/.local/bin` or `/usr/local/bin`, runs `fermix setup`. |
| Debian package | P2 | New | `.deb` for Ubuntu/Debian; ships systemd unit at `/lib/systemd/system/fermix.service`. |
| Docker image | P2 | New | Production-grade Docker image for server deployments. (Already in M8 — pulled into M4.8 to consolidate.) |
| `fermix doctor` | P1 | New | Diagnostic: checks binary version, daemon/service status, FERMIX_HOME layout, provider auth validity, channel reachability, endpoint health, and native-helper status only if native helpers are present. Same shape as the setup readiness report, but post-install. |
| First-boot UX | P0 | New | If `~/.fermix/config.toml` is missing, `fermix run` and service startup refuse and tell the user to run `fermix setup` first. If setup completes and no service is registered, the wizard offers to install one. |

### Non-Goals

| Feature | Reason | When |
|---------|--------|------|
| Windows native binary | Burrito may support it, but this milestone validates macOS and Linux only. Windows service management, shell setup, path handling, and native helper packaging need separate validation. | M9 or later |
| Auto-update without user consent | `fermix upgrade` is explicit. No silent background updaters. Operators choose when to upgrade. | Never |
| GUI installer / `.dmg` / `.msi` | The CLI install + brew tap covers >95% of the target audience. Bundled GUI installer adds maintenance with no clear demand. | Future |
| Multi-tenant cloud hosting | Different milestone (M9 / Future). M4.8 is about single-user local install only. | Future |
| Silently migrating existing `~/.codex` users | The wizard may offer an explicit one-time import from Codex CLI, but Fermix should own and refresh its own `~/.fermix/auth.json` profile. Silent runtime reads from `~/.codex` keep the dependency alive. | Never |
| Replacing the Phoenix HTTP listener with a CLI-only mode | Web surface (LiveView setup, webhooks) stays. The daemon hosts both. | — |
| In-app notification for new versions | `fermix doctor` and `fermix upgrade` report available versions. No always-on update banner in the LiveView dashboard. | M6 or later |
| Hex publication of `fermix_core` etc. as libraries | Fermix is an application, not a library. Hex publication has no audience. | Never |

---

## 3. Reference Comparison

Two reference systems frame the design.

### Codex CLI — single binary, OAuth profile, no daemon

The OpenAI Codex CLI (`/Users/sujshe/.codex/`) ships as a Rust single binary distributed via npm and Homebrew. It does **not** run as a daemon; each invocation is a one-shot CLI with persistent auth in `~/.codex/auth.json`. Auth uses an OAuth device-code flow against `auth.openai.com`.

**What we adopt:** the single-binary distribution pattern, a local versioned auth profile, and a user-driven OpenAI sign-in flow.
**What we reject:** the no-daemon model. Fermix needs to be online 24/7 to receive Telegram webhooks and run cron-like agents — one-shot CLI is the wrong shape.
**Boundary:** Fermix should not depend on `~/.codex` at runtime. If import is supported, it performs one OAuth refresh using the Codex credentials, persists the refreshed tokens to `~/.fermix/auth.json`, and never reads `~/.codex` again. Import succeeds only if the refresh succeeds — there is no separate validity check.

### Hermes — install script + systemd + app-owned auth

Hermes (`/Users/sujshe/projects/hermes-agent/scripts/install.sh`) uses a `curl | sh` installer that drops a Python venv + entrypoint script into `~/.hermes/`, generates a systemd unit, and starts the service. No single binary; relies on system Python.

Hermes also keeps provider state in its own `~/.hermes/auth.json`, prompts the user to choose an auth method during onboarding, can open the browser automatically, and supports a no-browser mode (same OAuth flow, prints URL+code) for remote/headless sessions. Its Codex-token handling intentionally avoids sharing refresh-token ownership with the Codex CLI.

**What we adopt:** the install-script + systemd-unit shape (one command → working daemon), the `~/.hermes/` workspace pattern (mirrors our `~/.fermix/`), provider-choice onboarding, browser-first auth, headless `--no-browser` mode (one flow, two UX branches), and an app-owned auth file.
**What we reject:** dependency on a system interpreter. Burrito eliminates that for us.

### Tailscale — gold standard for "install once, forget"

Tailscale ships native packages for every OS, runs as a system daemon, has an explicit `tailscale up` first-run command, and `tailscale status` / `tailscale doctor` for ops. Auth is OAuth-style.

**What we adopt:** the CLI verb shape (`fermix start | stop | status | doctor` directly maps), the explicit-first-run philosophy, the single-binary-per-platform distribution.
**What we reject:** kernel-level networking (irrelevant); their closed-source GUI dashboard.

---

## 4. Operating Model / Assumptions

### Product assumptions

1. **One operator, one machine.** M4.8 targets a single user installing on their own laptop or server. Multi-user/multi-tenant is M9+.
2. **The user can approve service setup on their own machine.** Installing a launchd `.plist` in `~/Library/LaunchAgents/` is per-user (no sudo needed); systemd user units in `~/.config/systemd/user/` are likewise per-user. Linux user-scope reboot survival may still require `loginctl enable-linger`, which can require sudo or polkit depending on distro. We default to **user-scope** services and only escalate to system-scope on explicit `--system` flag.
3. **Setup is interactive once, daemon thereafter.** `fermix setup` is the only interactive entry point. `fermix run`, `fermix start`, and the systemd/launchd unit run non-interactively against the persisted config.
4. **Releases are signed and public.** GitHub Releases artifacts include a `.sig` per binary. The installer + `fermix upgrade` verify before swap. No private/enterprise release channel in M4.8.
5. **Fermix self-updates explicitly.** `fermix upgrade` is opt-in. No silent updaters. The doctor command flags the available version but never installs it.

### Technical assumptions

1. **Burrito is the right wrapper.** It is actively maintained and produces binaries that don't require Erlang on the host. Bakeware is unmaintained; `mix release` alone leaves the user to manage extraction.
2. **M4.8 does not require NIF work.** The current `apps/fermix_nif` implementation is a placeholder, not a tiktoken/crypto dependency. If native helpers become required before distribution, they must be validated per target and added to Burrito packaging explicitly.
3. **The Phoenix listener is enabled explicitly in daemon mode.** Current runtime config only starts the endpoint server when `PHX_SERVER=true`; `fermix run` must either set the endpoint server config before boot or service templates must set `PHX_SERVER=true`.
4. **The Phoenix listener can rebind on restart.** `fermix restart` stops the daemon and starts a new one; no rolling-upgrade story (single-node assumption holds through M9).
5. **OpenAI OAuth permissibility is unresolved.** A browser-first OpenAI OAuth flow is the preferred UX, but use of any upstream Codex/OpenAI client flow must be confirmed before shipping it as P0. API-key auth remains a guaranteed path.
6. **Setup must be release-safe.** `Mix.Tasks.Fermix.Setup` currently uses Mix APIs and should become a dev wrapper around runtime setup modules. The Burrito CLI must not rely on Mix being present at runtime.

---

## 5. High-Level Design

M4.8 adds three layers on top of the existing M3/M4.7 codebase. Prompt, memory, and channel behavior stay unchanged. `apps/` changes are limited to release-safe setup modules, CLI/service modules, auth storage/flow, and a small daemon control child.

```
┌───────────────────────────────────────────────────────────────┐
│  Distribution layer  (new in M4.8)                            │
│  ───────────────────                                          │
│  • Burrito build → one binary per (os, arch)                  │
│  • GitHub Releases + signed releases.json                     │
│  • Homebrew tap, install.sh, .deb, Docker                     │
└───────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────────┐
│  CLI dispatch layer  (new in M4.8)                            │
│  ──────────────────                                           │
│  fermix setup     → release-safe setup runtime                │
│  fermix run       → foreground OTP daemon + Phoenix endpoint  │
│  fermix start     → start installed OS service                │
│  fermix stop      → graceful shutdown (drain + SIGTERM)       │
│  fermix status    → query daemon over local socket            │
│  fermix logs      → tail ~/.fermix/logs/fermix.log            │
│  fermix upgrade   → fetch + verify + swap binary + restart    │
│  fermix doctor    → diagnostics                               │
│  fermix uninstall → remove service unit + binary (keep data)  │
│  fermix version   → print version + commit sha                │
└───────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────────┐
│  OS daemon layer  (new in M4.8)                               │
│  ───────────────                                              │
│  macOS  → ~/Library/LaunchAgents/io.tezra.fermix.plist        │
│  Linux  → ~/.config/systemd/user/fermix.service               │
│  Logs   → ~/.fermix/logs/fermix.log (rotated)                 │
│  Crash  → OS-level restart; OTP supervises within             │
└───────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────────┐
│  Existing OTP runtime (same product behavior as M4.7)         │
│  • FermixCore.Application                                     │
│  • FermixChannels.Application                                 │
│  • FermixWeb.Endpoint                                         │
│  • TokenManager (modified: Fermix-owned provider auth)        │
└───────────────────────────────────────────────────────────────┘
```

### Key components

1. **`Fermix.CLI`** (new module in `apps/fermix_core/lib/fermix/cli.ex`) — entry point invoked by Burrito. Parses argv, dispatches to subcommand modules. Fewer than 100 lines; no business logic, only routing.
2. **`Fermix.CLI.Setup` / `FermixCore.Setup.Runtime`** — release-safe setup runner. The existing Mix task becomes a thin development wrapper around this module.
3. **`Fermix.CLI.Run`** — foreground daemon entry point used by launchd/systemd. It validates config, enables Phoenix server mode, starts OTP apps, and blocks until terminated.
4. **`Fermix.CLI.Service`** — generates and installs/uninstalls the launchd or systemd unit. Detects OS at runtime. Idempotent.
5. **`Fermix.CLI.Upgrade`** — fetches `releases.json`, picks the newest semver above current, verifies signature, downloads binary to `~/.fermix/.upgrade.tmp`, swaps via `rename(2)` (atomic on POSIX), restarts the service. Refuses to mutate package-manager-owned binaries.
6. **`Fermix.CLI.Daemon`** — small control-socket protocol so `fermix status` can query the running BEAM without going through HTTP. User-scope socket at `~/.fermix/daemon.user.sock`; system-scope socket at `/var/run/fermix.sock` (root-owned, queries from non-root require sudo). Restricts file permissions to the owner, removes stale sockets on boot, and `fermix run` fails fast on EADDRINUSE rather than double-binding.
7. **`FermixCore.Auth.Store`** (new) — versioned, provider-scoped `~/.fermix/auth.json` store with file locking, atomic writes, and `0600` permissions.
8. **`FermixCore.Auth.OAuth`** (new) — OpenAI OAuth client. One device-code flow with a single runtime UX branch: open browser when `$DISPLAY` / `xdg-open` / `open` is available, otherwise print URL+code. Same endpoints, same poll loop, same persistence — not a separate code path.
9. **`Setup.Wizard.OAuthStep`** — new wizard step inserted before `:provider_credentials` when the chosen auth mode is `:oauth`. Drives `Auth.OAuth`; API-key mode remains first class.
10. **Burrito build config** in `mix.exs` — declares `releases: [fermix: [steps: [:assemble, &Burrito.wrap/1], burrito: [...]]]`. Native-helper hooks are added only if native helpers become required.
11. **`scripts/release.sh`** — local cross-build orchestrator. CI uses the same script in matrix mode (one runner per target) and uploads to GitHub Releases.
12. **`scripts/install.sh`** — POSIX install script served from the release channel. Detects platform, downloads, verifies, drops in PATH, runs `fermix setup`.

### Install location and PATH

The binary location is chosen per install method, not per-OS:

| Install method | Binary path | Sudo required? | PATH handling |
|----------------|-------------|----------------|---------------|
| `brew install` | `$(brew --prefix)/bin/fermix` (`/opt/homebrew/bin` Apple Silicon, `/usr/local/bin` Intel/Linuxbrew) | No | Brew already on PATH |
| `curl \| sh` (default) | `/usr/local/bin/fermix` | Yes (`sudo install`) | Already on PATH everywhere |
| `curl \| sh --user` | `~/.local/bin/fermix` | No | Installer appends `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and `~/.bashrc` only if the directory is not already on PATH; prints `Open a new shell or run: source ~/.zshrc` |
| `.deb` | `/usr/bin/fermix` | Yes (apt) | Already on PATH |
| Docker | n/a — `docker run tezraio/fermix` | No | n/a |

The `curl | sh` default is system-wide because (a) it matches the daemon location convention, (b) it's the path users expect from analogous tools (`brew`, `gh`, `tailscale`), and (c) the `--user` flag exists for users who refuse sudo.

### Reboot survival — OS daemon semantics

The "install once, survives reboot" promise is not free; both launchd and systemd have **two** scopes with different start triggers. The default install picks user-scope on personal machines and system-scope on headless servers, configurable via flags.

| Scope | macOS file | Linux file | Sudo? | Starts on reboot when… | Best for |
|-------|------------|------------|-------|-------------------------|----------|
| **User** (default on laptops) | `~/Library/LaunchAgents/io.tezra.fermix.plist` | `~/.config/systemd/user/fermix.service` | Usually no; Linux linger may need sudo/polkit | macOS: user logs in. Linux: only if `loginctl enable-linger $USER` is set. | Personal laptops where the user is the operator. |
| **System** (`--system` flag) | `/Library/LaunchDaemons/io.tezra.fermix.plist` | `/etc/systemd/system/fermix.service` | Yes | At boot, regardless of login | Headless servers, multi-user machines, always-on personal desktops. |

**macOS plist (user-scope)** — minimum viable shape:

```xml
<key>RunAtLoad</key><true/>            <!-- start when agent loaded (login) -->
<key>KeepAlive</key><true/>            <!-- restart on crash -->
<key>ProcessType</key><string>Background</string>
<key>ProgramArguments</key>
<array>
  <string>/Users/alice/.local/bin/fermix</string>
  <string>run</string>
</array>
<key>StandardOutPath</key><string>/Users/alice/.fermix/logs/fermix.log</string>
<key>StandardErrorPath</key><string>/Users/alice/.fermix/logs/fermix.log</string>
```

User-scope LaunchAgents start **at user login**, not at boot. On laptops this is fine; the user's session is active when they want the agent. On headless / always-logged-out machines, use `--system` to install a `LaunchDaemon`, which starts at boot.

**Linux systemd unit (user-scope)** — minimum viable shape:

```ini
[Service]
Type=simple
Environment=PHX_SERVER=true
ExecStart=%h/.local/bin/fermix run
Restart=on-failure
RestartSec=5
StandardOutput=append:%h/.fermix/logs/fermix.log
StandardError=append:%h/.fermix/logs/fermix.log

[Install]
WantedBy=default.target
```

systemd-user units only run while the user has an active session **unless lingering is enabled**. `fermix service install --user` runs `loginctl enable-linger $USER`. If the call fails (sudo/polkit denied), the installer aborts with a non-zero exit code and prints the exact command to run before retrying. There is no degraded-but-installed state: the install either has reboot survival or it doesn't exist.

`fermix doctor` checks both: (a) the unit is enabled, (b) on Linux user-scope, lingering is on. Failures print the exact `loginctl` / `launchctl` command to fix.

**Choosing scope at setup time:** `fermix setup` final step asks `Install as a background service? [Y/n]` — and if yes, `User-scope (recommended for laptops) or system-scope (recommended for servers)? [user/system]`. Defaults to user. The wizard explains the tradeoff in one line: *"User-scope starts when you log in. On Linux, reboot survival may need linger. System-scope starts at boot but needs sudo once."*

### CLI surface (full)

| Command | Effect | Implementation |
|---------|--------|----------------|
| `fermix setup` | Run wizard | `Fermix.CLI.Setup.run([])` |
| `fermix setup --print-state` | Print readiness without prompting | `Fermix.CLI.Setup.run(["--print-state"])` |
| `fermix run` | Start OTP apps in foreground for service managers | validate config, enable Phoenix endpoint server mode, `Application.ensure_all_started(:fermix_web)`, then block |
| `fermix service install [--user\|--system]` | Install and enable OS service | writes launchd/systemd unit that executes `fermix run` |
| `fermix service uninstall` | Remove OS service | stops unit, disables/removes unit file |
| `fermix start` | Start installed service | calls launchctl/systemctl; if no service is installed, prints `fermix service install` or `fermix run` guidance |
| `fermix stop` | Stop installed service | calls `launchctl unload` (macOS) or `systemctl --user stop` / `systemctl stop` (Linux) on the installed unit |
| `fermix restart` | Restart installed service | sequential `stop` + `start` |
| `fermix status` | Show daemon state | queries control socket. Socket missing or unreachable → reports "not running"; this is the authoritative signal, not a fallback path |
| `fermix logs [-f]` | Print or follow logs | tails `~/.fermix/logs/fermix.log` |
| `fermix upgrade` | Self-update | `Upgrade.run/0` |
| `fermix upgrade --check` | Show available version, don't install | `Upgrade.check/0` |
| `fermix doctor` | Run diagnostics | extends the release-safe setup readiness check with post-install checks (binary integrity, service unit health, log directory writable) |
| `fermix uninstall [--purge]` | Remove service + binary; `--purge` also deletes `~/.fermix/` data dir | confirms before deleting; `--purge` requires a second confirmation |
| `fermix version` | Print `0.x.y (commit-sha)` | from compile-time `Application.spec/2` |

Subcommand-routing conventions follow Tailscale/Caddy: each subcommand is its own module under `Fermix.CLI.*`, parsed by `OptionParser`, returns `:ok | {:error, term()}`. `fermix run` is the only long-running foreground command; service managers call it directly.

### OpenAI auth flow (replaces `~/.codex` bootstrap)

```
1. Wizard reaches OpenAI provider auth step.
2. Wizard asks:
     [1] Sign in with OpenAI (recommended)
     [2] Use API key
     [3] Import Codex CLI login, if ~/.codex/auth.json exists
3. OAuth path:
   → Auth.OAuth.start_browser_flow/1 opens the login URL when a local browser is available.
   → In SSH/headless mode or with --no-browser, it prints the URL/code and waits.
   → The exact upstream OAuth/client choice is gated by the Stage 3 TOS/compliance decision.
4. API-key path:
   → Wizard stores provider config in the existing config store.
   → TokenManager uses the API key path without requiring OAuth.
5. Optional Codex CLI import path:
   → Wizard performs one OAuth refresh using the credentials in ~/.codex/auth.json.
   → Refresh succeeds → refreshed tokens are written to ~/.fermix/auth.json. Done.
   → Refresh fails → the wizard reports the failure and re-prompts with the remaining options. ~/.codex is never read again.
   → No timestamp/expiry pre-check: the refresh attempt is the only authoritative validity test.
6. Auth.Store writes ~/.fermix/auth.json atomically with 0600 permissions.
7. Wizard advances; ConfigStore records the selected auth mode.
8. TokenManager boot reads ~/.fermix/auth.json / config directly.
   → ~/.codex fallback path is deleted.
```

Suggested `~/.fermix/auth.json` shape:

```json
{
  "version": 1,
  "providers": {
    "openai": {
      "auth_mode": "oauth",
      "tokens": {
        "access_token": "...",
        "refresh_token": "..."
      },
      "expires_at": "2026-04-26T20:15:00Z",
      "last_refresh": "2026-04-26T19:15:00Z"
    }
  }
}
```

Failures during OAuth (timeout, denial, network) raise back to the wizard with a clear message. The wizard re-prompts with the full menu (OAuth / API key / Codex import). There is no silent fallback from OAuth to API-key — the user explicitly re-chooses.

---

## 6. Phased Delivery

Each phase is independently shippable and testable.

### Stage 1 — Burrito MVP for the developer's own machine (P0)

Goal: produce a single binary that boots Fermix on `aarch64-apple-darwin` (the dev machine) and runs `fermix setup` end-to-end without Mix at runtime.

1. Add `:burrito` dep, configure `releases: [fermix: [...]]` in `mix.exs`.
2. Extract the existing setup wizard into release-safe runtime modules; keep `mix fermix.setup` as a wrapper.
3. Write `Fermix.CLI` with `setup` / `run` / `start` / `stop` / `version` only.
4. Verify the wrapped binary starts the Phoenix endpoint in `fermix run`.
5. `mix release` → produces `./burrito_out/fermix-darwin-aarch64`.
6. Manual verification: copy binary to a clean directory, run `./fermix setup`, run `./fermix run`, send a Telegram message, verify reply.
7. **Acceptance gate:** measure compressed binary size and record in CHANGELOG. Hard ceiling 100MB; if exceeded, escalate as a blocker before Stage 2 begins. (Resolves §10 Q5.)

### Stage 2 — Cross-compile matrix + signed releases (P0)

1. Add `linux-aarch64`, `linux-x86_64`, `macos-x86_64` targets.
2. CI workflow: matrix build per target, sign with cosign, publish to GitHub Releases.
3. Generate `releases.json` from CI, publish to the same release.
4. Manual verification: download signed binary on a fresh Linux VM, install, verify works.

### Stage 3 — Native OAuth + drop `~/.codex` (P0)

1. Resolve the OpenAI OAuth compliance/client question. If it is not permitted, keep API-key mode as the P0 path and defer OAuth to a Fermix-owned compliant flow.
2. Implement `FermixCore.Auth.Store` with provider-scoped JSON, file locking, atomic writes, and `0600` permissions.
3. Implement `FermixCore.Auth.OAuth` as a single device-code flow with one UX branch: browser-open vs URL+code printing, decided at start of flow from terminal capability + `--no-browser` flag.
4. Add `:provider_auth_oauth` wizard step with choices: OAuth, API key, optional Codex CLI import.
5. Modify `TokenManager.start_link/1` to read only Fermix-owned config/auth state (delete `load_from_codex`, `default_codex_path`, the bootstrap-fork path, and the M3-temporary comment).
6. Migration: existing installs with only `~/.codex/auth.json` are detected at next `fermix setup`; the OpenAI step pre-selects "Import Codex CLI login" as the default option. If a running daemon hits a missing `~/.fermix/auth.json` post-upgrade, it fails loud with `OpenAI auth not configured — run \`fermix setup\`` and exits non-zero. No silent re-read of `~/.codex`.
7. Tests: mock OAuth endpoints, assert wizard advances, assert browser/no-browser paths, assert tokens land in `~/.fermix/auth.json`, assert `TokenManager` no longer reads `~/.codex`.

### Stage 4 — OS daemon integration (P0)

1. Implement `Fermix.CLI.Service` for both launchd and systemd, both user and system scope (4 unit templates).
2. Wire `fermix service install [--user|--system]`, `fermix service uninstall`, `fermix start`, and `fermix stop`.
3. `fermix run` enables the Phoenix endpoint server internally (`Application.put_env(:fermix_web, FermixWeb.Endpoint, server: true)` before `Application.ensure_all_started`). Service templates do **not** set `PHX_SERVER` — the runtime owns this decision, not the unit file.
4. On Linux user-scope: installer runs `loginctl enable-linger $USER` and aborts with non-zero exit on failure (sudo/polkit denied), printing the exact command to run before retrying. The install never enters a "works while logged in" half-state.
5. Wizard final step: prompt "install as a background service? [Y/n]" then "user-scope or system-scope? [user/system]".
6. Implement control socket (`~/.fermix/daemon.sock`) for `status` / `stop` IPC.
7. Implement log rotation (size-based, 10 × 10MB rolling).
8. Manual verification matrix:
   - macOS user-scope: install → log out → log in → service running → reboot → log in → service running.
   - macOS system-scope: install with sudo → reboot → service running before login.
   - Linux user-scope: install → verify lingering on → reboot → service running with no user logged in.
   - Linux system-scope: install with sudo → reboot → service running.
9. `fermix doctor` validates: unit installed, unit enabled, lingering on (Linux user-scope only), recent log activity, control socket reachable.

### Stage 5 — `fermix upgrade` (P0)

1. Implement `Upgrade.check/0` (parse `releases.json`, semver compare).
2. Implement install-method detection (`brew`, `.deb`, unmanaged user/system binary).
3. Implement `Upgrade.run/0` for unmanaged installs:
   a. Download new binary to `~/.fermix/.upgrade.tmp`, verify cosign signature.
   b. Copy current binary to `~/.fermix/.previous` (one-shot recovery slot; overwritten on every upgrade; **no user-facing `--rollback` command, no version history A/B install**).
   c. Atomic `rename(2)` `.upgrade.tmp` → installed path.
   d. Restart service via `Service.restart/0`. If post-swap health check (control-socket round trip) fails within 10 seconds, `rename(2)` `.previous` → installed path, restart, exit non-zero.
4. For package-manager installs, print `brew upgrade fermix` or `sudo apt upgrade fermix` and exit without mutating managed paths.
5. Manual verification: install v0.1.0, publish v0.1.1, run `fermix upgrade`, verify daemon comes back at v0.1.1 with no data loss. Force a post-swap failure (publish a binary that exits 1 immediately) and verify rollback restores v0.1.0 and surfaces the failure.

### Stage 6 — Distribution channels (P1)

1. Homebrew tap repo (`tezra-io/homebrew-tap`) with auto-bump CI.
2. `scripts/install.sh` published at `https://fermix.sh/install`.
3. `.deb` package (P2 — defer if Stage 1-5 lands before launch).
4. Docker image (P2 — pull forward from M8 if there's demand).

### Stage 7 — `fermix doctor` (P1)

1. Reuse the release-safe setup readiness module for the readiness portion.
2. Add binary-integrity check (SHA256 vs release manifest).
3. Add service-unit health check (process running, ports bound, recent log activity).
4. Add native-helper load checks only if native helpers are present.
5. Add provider auth check (token validity, refresh if needed).

---

## 7. Telemetry

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:fermix, :cli, :command]` | `duration_ms` | `subcommand, exit_status` |
| `[:fermix, :upgrade, :start]` | — | `from_version, to_version` |
| `[:fermix, :upgrade, :complete]` | `duration_ms` | `from_version, to_version, status` |
| `[:fermix, :daemon, :start]` | `boot_ms` | `version, target, install_kind (service \| foreground)` |
| `[:fermix, :daemon, :stop]` | `uptime_s` | `reason (signal \| upgrade \| crash)` |
| `[:fermix, :auth, :oauth, :start]` | — | `provider` |
| `[:fermix, :auth, :oauth, :complete]` | `duration_ms` | `provider, status` |

All events written to `~/.fermix/traces/` per the existing `FermixCore.Trace` JSONL format.

---

## 8. Risks

| Risk | Mitigation |
|------|------------|
| **Burrito packaging fails** for one of the 4 targets | Stage 1 validates `aarch64-apple-darwin` end-to-end before adding other targets. If a target is genuinely broken, document it and ship the others; expand later. If native helpers are added, validate them per target before including that target in the release matrix. |
| **OpenAI OAuth via upstream/Codex flow is disallowed or unstable** | Validate before Stage 3 (open question §10.1). API-key mode remains a P0 path. OAuth ships only if the client/endpoint flow is compliant and supportable. |
| **`fermix upgrade` corrupts an in-flight daemon** | Atomic swap via `rename(2)` after sig verify; daemon restarts via service unit, not in-process binary swap. Failures roll back to previous binary kept at `~/.fermix/.previous`. |
| **launchd / systemd unit generation breaks on exotic distros** | Detect at runtime; if neither launchd nor systemd is found, `fermix service install` errors with a clear message and falls back to documenting how to write a custom unit. |
| **`fermix upgrade` overwrites package-manager-owned files** | Detect install method before upgrade. Homebrew and apt installs should print the package-manager upgrade command and refuse self-overwrite. `/usr/local/bin` unmanaged installs may still require sudo for atomic replacement. |
| **Signing key compromise** | Use Sigstore / Cosign with keyless OIDC (GitHub Actions identity) — no long-lived signing keys to leak. |
| **Existing `~/.codex` users surprised by auth migration in Stage 3** | One-time migration/import prompt; documented in CHANGELOG; the wizard explicitly says Fermix now keeps its own auth profile and offers either import, OAuth, or API-key setup. |

---

## 9. Versioning Policy

- **SemVer.** `mix.exs` version is the source of truth. Releases tag the repo with `v0.x.y` and create a GitHub Release with the same tag.
- **Pre-1.0:** breaking changes allowed in minor version bumps with a CHANGELOG entry.
- **Post-1.0:** breaking changes only in major bumps. Migrations published as `docs/migrations/v<N>_to_v<N+1>.md`.
- **`fermix upgrade` refuses major-version jumps without `--allow-major`** to prevent surprise migrations.
- **The release manifest pins the minimum prior version that can upgrade**; older daemons must do a clean reinstall.

---

## 10. Open Questions

1. **Which OpenAI OAuth endpoint/client is permitted for Fermix?** If an upstream/Codex-compatible flow is permitted, Stage 3 ships browser-first OAuth. If not, OAuth must wait for a compliant Fermix-owned flow and API-key mode remains the P0 path. **Owner: Sujeeth. Hard deadline: before Stage 3 kickoff.** If unresolved by then, Stage 3 ships API-key + Codex import only and OAuth slips to a follow-up milestone.
2. **Cosign vs Minisign for release signing?** Cosign + GitHub OIDC has zero key management overhead but requires Sigstore infrastructure to verify. Minisign is simpler but needs a long-lived key. Recommendation: Cosign with keyless OIDC for v0.x; revisit if Sigstore proves flaky.
3. **Where does the install script live?** `https://fermix.sh/install` requires a domain + redirect. `https://raw.githubusercontent.com/tezra-io/fermix/main/scripts/install.sh` works without one. Recommendation: ship via GitHub raw at first, add `fermix.sh` once a stable v1.0 lands.
4. **Should `fermix doctor` make outbound network calls (e.g., probe OpenAI / Telegram reachability)?** Useful for diagnostics, slow on every run, and may surprise privacy-sensitive users. Recommendation: gate behind `--full` flag.
5. **Where does the upgrade audit log live?** `~/.fermix/upgrades.jsonl` with `{from, to, timestamp, sha256, status}` per attempt. Used by `fermix doctor` and post-mortem.
6. **Should `--user` install of `curl | sh` modify the user's shell rc files?** Yes, by default — it appends a single guarded line to `~/.zshrc` and `~/.bashrc` only if `~/.local/bin` is missing from `$PATH`. `--no-modify-path` opts out and prints the line for the user to add manually. Same posture as `rustup-init` and `volta`.
7. **Default scope on first install — user or system?** User. Operator can switch with `fermix service uninstall && fermix service install --system`. Headless installs (no `$DISPLAY`, no `$XDG_RUNTIME_DIR`) auto-suggest `--system` in the wizard.

---

## 11. Out-of-Band: What changes in `apps/`

To keep the surgical-changes principle visible, here is the full list of code changes in `apps/` for M4.8. Distribution scaffolding lives in `mix.exs`, `scripts/`, and `.github/workflows/` — not in `apps/`.

| File | Change |
|------|--------|
| `apps/fermix_core/lib/fermix/cli.ex` (new) | Entry point dispatched by Burrito; routes argv to subcommand modules. |
| `apps/fermix_core/lib/fermix/cli/setup.ex` (new) | Release-safe setup command that calls runtime setup modules without Mix. |
| `apps/fermix_core/lib/fermix/cli/run.ex` (new) | Foreground daemon command used by service managers; validates config, enables endpoint server mode, starts OTP apps, and blocks. |
| `apps/fermix_core/lib/fermix/cli/service.ex` (new) | launchd / systemd unit generation. |
| `apps/fermix_core/lib/fermix/cli/upgrade.ex` (new) | Self-update implementation. |
| `apps/fermix_core/lib/fermix/cli/daemon.ex` (new) | Control socket listener + supervisor child. |
| `apps/fermix_core/lib/fermix/cli/doctor.ex` (new) | Diagnostics. |
| `apps/fermix_core/lib/fermix_core/setup/runtime.ex` or equivalent (new) | Runtime setup implementation extracted from the Mix task. |
| `apps/fermix_core/lib/mix/tasks/fermix.setup.ex` (modify) | Thin development wrapper around the runtime setup module. |
| `apps/fermix_core/lib/fermix_core/auth/store.ex` (new) | Versioned provider auth store at `~/.fermix/auth.json` with locking, atomic writes, and `0600` permissions. |
| `apps/fermix_core/lib/fermix_core/auth/oauth.ex` (new) | OpenAI OAuth device-code client. One flow, one UX branch (browser-open vs URL+code print). Subject to Stage 3 compliance decision. |
| `apps/fermix_core/lib/fermix_core/auth/token_manager.ex` (modify) | Delete runtime `~/.codex` fallback (`load_from_codex`, `default_codex_path`, bootstrap-fork branch, and the M3-temporary comment). Read Fermix-owned config/auth state only. |
| `apps/fermix_core/lib/fermix_core/setup/wizard.ex` (modify) | Add `:provider_auth_oauth` step in front of `:provider_credentials` when `auth_mode == :oauth`. |
| `apps/fermix_core/lib/fermix_core/application.ex` (modify) | Add `Fermix.CLI.Daemon` to the supervision tree (only when `start_daemon_socket: true`). |

That's it. Nothing in prompt, memory, channel, or `fermix_nif` behavior changes for M4.8. `fermix_web` behavior stays the same, but packaged daemon startup must explicitly enable the Phoenix endpoint server.

---

_Every install is a chance to lose a user. Make it boring._
