# Standalone and Linux-package installs: the service and updates

| Install | Who owns the service | How it updates |
|---|---|---|
| Fermix.app on a Mac | the app (a Login Items item) | the app's **Check for Updates…**; see `skill_view(name: "self-knowledge", file: "macos_app")` |
| Linux `.deb`/`.rpm` package | the package's systemd *user* unit | the installer run again, then `fermix restart` |
| Standalone binary (Homebrew formula, the installer with `--standalone` or on a host without a supported package manager, a downloaded release) | the binary's own launchd/systemd unit | `fermix upgrade`, or `brew upgrade fermix` then `fermix restart` |

After any update the daemon keeps running the old engine until it restarts: "upgraded but behavior unchanged" almost always means no restart. `fermix status` warns when the running daemon differs from the installed binary, and `fermix doctor`'s `engine alignment` row names the restart.

## Standalone installs

- `fermix upgrade` swaps in the cosign-verified binary, restarts and health-checks the daemon, and rolls back on failure. On a package-manager install (Homebrew) it refuses and names the package manager's command.
- The unit is per-user by default; `--system` installs a system-wide one. It runs `fermix run`, which also runs the daemon in the foreground by hand. Control: `fermix start|stop|restart`; inspect: `fermix status|health|doctor|logs -f|capabilities|agents` (`agents`: the main agent and skill workers).
- **`PATH`.** The unit pins a `PATH` (the directory `fermix` lives in, plus the system and Homebrew bin dirs), and the engine appends the same baseline to its own `PATH` at boot, never prepending, so `cosign`, brew `node`/`python` and the `codex`/`claude` CLIs in `~/.local/bin` resolve however the daemon started (a source checkout keeps its real `PATH`). A missing `cosign` makes plugin installs and `fermix upgrade` refuse; `fermix doctor`'s `cosign` row names the install command. Its `engine_path_baseline` row warns on a missing baseline directory.
- **Drifted unit.** `fermix setup` rewrites and reloads a unit that no longer matches what the current binary would write; `fermix service install` is the manual fix.
- **Environment file (Linux).** A user unit and the package's unit load `~/.config/fermix/env`; a system unit loads `/etc/fermix/env`. One `NAME=value` per line, read only at service start, so restart after editing; a missing file is fine. Fermix never writes it and its file tools cannot open it. What reaches commands: `skill_view(name: "self-knowledge", file: "sandbox_env")`.
- **System unit (Linux).** `sudo fermix service install --system` (or `setup --system`) writes `/etc/systemd/system/fermix.service`. It runs as the account that ran `sudo` when that account owns the home, otherwise as root; from the account, `sudo FERMIX_HOME="$HOME/.fermix" fermix service install --system` names its home. The account is chosen once; setup's rewrites keep it and leave drop-ins alone. To move a root unit to an account: `sudo chown -R "$USER" "$HOME/.fermix"`, `sudo fermix service uninstall --system`, install again. A rewrite for a different home is refused and names both ways out. The system unit also blocks the cloud metadata address (`169.254.169.254`, `fd00:ec2::254`) for the daemon and its children (defense in depth: a process started outside the unit, such as through `systemd-run` or the person's own browser tab, is not covered); a unit written before that gains it only when `sudo fermix setup --system` rewrites it (`fermix doctor`'s `service unit` row reports it stale). To let the agent use the instance's credentials: `sudo systemctl edit fermix`, add `IPAddressDeny=` under `[Service]`. User units cannot carry this block.

## Linux packages

- **Install:** `curl -fsSL https://fermix.ai/install | sh` picks the package for the machine from the latest release, checks its sha256 and (when a `cosign` is present) its cosign signature, installs it with `apt`, `dnf` or `zypper` through `sudo`, then runs `fermix setup` in the terminal (under `sudo` or with no terminal it prints `fermix setup` as the next step). `.deb` for Debian and Ubuntu, `.rpm` for Fedora, RHEL and openSUSE; `x86_64` and `arm64`. The packages are release assets, not a repository: no `apt`/`dnf` source is configured, and `sudo apt install ./<file>.deb` or `sudo dnf install ./<file>.rpm` from the release page is the same result. `--standalone`, macOS, or a host with none of the three managers gets the standalone binary. An older standalone `fermix` first on `PATH` is named, and no setup starts.
- **Unit and binding.** The package ships `/usr/lib/systemd/user/fermix.service` (runs `fermix service run`) and nothing in Fermix rewrites it. Each account's home is recorded in `~/.config/fermix/service.json` (`$XDG_CONFIG_HOME`); the service refuses to boot without it rather than guess a home.
- **Port.** `[fermix_web] port` (1024-65535, default 4030), set with `fermix service install --port N` or in `config.toml`; restart to apply. A packaged engine refuses a `PORT` environment variable. `--port` refuses a `config.toml` holding a hand-written `[mcp.*]` block; edit the file instead.

| Verb | Does |
|---|---|
| `fermix service install [--home PATH] [--port N] [--json]` | records the home, turns on linger (with no `loginctl` it refuses: run the daemon in the foreground with `fermix run`), enables and starts the unit, verifies it answers within 90 s; moving an active service's home is refused until it is stopped |
| `fermix service status [--json]` | works with no daemon: binding, unit state, linger, listener, installed vs running engine (`aligned`, `pending_restart`, `not_running`, `unknown`, `ownership_conflict`) |
| `fermix service uninstall [--json]` | disables and stops; binding and home stay |
| `fermix restart [--json]` | one `systemctl --user restart`, waits up to 90 s for a new pid; `--when-idle` is refused for now, so a restart interrupts work in progress |
| `fermix diagnostics export --offline [--json]` | a redacted support bundle with no daemon needed; reads no secret and never unlocks a keyring (≤ 1 MB, ≤ 10 s) |

- **Logs.** Product logs: `logs/fermix.log` (`fermix logs`). Early boot, crashes and anything outside the logger: `journalctl --user -u fermix`. A service that will not start explains why in the journal.
- **Old standalone unit.** A `~/.config/systemd/user/fermix.service` left by a standalone install shadows the package's unit; `fermix service install` recognises that one shape, adopts its home, carries its observability values into a drop-in and removes it. Anything else there is named as a conflict and left alone.
- **cosign** is bundled at `/usr/lib/fermix/cosign`, appended last to `PATH`, so a distribution `cosign` wins.
- **Removal** leaves `/var/lib/fermix/runtimes/` (a few hundred KB per engine version) in place, even on purge.

**Updating.** `fermix upgrade` refuses a packaged engine and prints the family's line (`sudo apt update && sudo apt upgrade fermix`, `sudo dnf upgrade fermix`, `sudo zypper update fermix`; a binary owned by `dpkg`, `rpm` or `pacman` gets its family's line, and the community AUR build is named as `fermix-bin`). Until a repository is published, those lines find nothing: the package was installed from a file. What updates a package install is `curl -fsSL https://fermix.ai/install | sh` again (installs the newer package, starts no setup, downloads nothing when already current) or the newer file installed by hand, then `fermix restart` once per account that runs a service. Never answer "how do I update?" on a packaged host with `apt upgrade` alone.
