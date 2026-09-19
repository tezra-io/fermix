# The service unit and the built-in updater

The first part of this file is the **standalone** install (Homebrew formula,
install script, or a downloaded release): the binary installs and owns its own
launchd/systemd unit. On a Fermix.app-managed macOS engine none of it applies —
the app owns the service and the app updates itself; see
`skill_view(name: "self-knowledge", file: "macos_app")`. On a Linux distribution
package the package owns the unit and the CLI owns a binding instead; that is
the last section here.

## Upgrading the binary

`fermix upgrade` is the built-in updater for standalone installs: it swaps the
cosign-verified binary, then restarts and health-checks itself, rolling back on
failure. On a package-manager install (e.g. Homebrew) it refuses to touch the
managed binary and points at the package manager instead — and after
`brew upgrade fermix` the daemon keeps running the old version until
`fermix restart`.

`fermix status` and `fermix doctor`'s daemon-socket check warn when the running
daemon's version differs from the installed binary, and name the restart as the
fix. "Upgraded but behavior unchanged" almost always means the daemon was never
restarted.

## The unit's pinned `PATH`

The installed unit pins a `PATH`: the directory `fermix` was installed into (its
sibling `cosign` on a Homebrew install) plus the standard system and Homebrew
bin dirs. The supervised daemon needs it to shell out to `cosign` for
plugin-signature verification and to brew-installed `node`/`python` for MCP
runtimes. A bare launchd/systemd `PATH` omits the Homebrew prefix, which makes
plugin installs fail with a misleading `signature invalid`.

The engine appends that same baseline to its own `PATH` at boot, from one list
the unit and the process both read, so a daemon started any other way — an
app-managed engine launched by `SMAppService`, or a plain `fermix run` — still
resolves `cosign`, brew `node` and `python`, and the `codex` and `claude` CLIs in
`~/.local/bin`. It appends and never prepends, so it can make an unresolvable
name resolvable and can never shadow a binary the operator's own `PATH` already
chose; a source checkout gets none of it, so a developer sees their real `PATH`.
`fermix doctor` carries an `engine path baseline` warning row.

## Drifted units

The unit is a snapshot of install-time settings, but `fermix setup` self-heals a
drifted one: when the on-disk unit no longer matches what the current binary
would write (the `PATH` or the template changed across an upgrade, say), setup
rewrites and reloads it instead of just restarting. So re-running setup picks up
unit changes. `fermix service install` is the manual escape hatch.

## The optional environment file (Linux)

Every Linux unit loads an optional environment file: `~/.config/fermix/env` for
a user-scope unit and for the distribution package's unit, `/etc/fermix/env` for
a system-scope unit. It is how a server with no keyring gives allowed sandbox
variables to the daemon: one `NAME=value` per line, allow the name, then restart
Fermix, because the file is read only when the service starts. Fermix never
writes it, and a missing file is fine. A unit written before the line existed
gets it when setup rewrites the drifted unit. What reaches commands from there:
`skill_view(name: "self-knowledge", file: "sandbox_env")`.

## Linux distribution packages

A Fermix installed from a `.deb` or `.rpm` is a different configuration from the
standalone binary above, and the difference is who owns the unit.

**Two package channels, one engine.** The `.deb` serves the apt family (Debian,
Ubuntu) and the `.rpm` serves the rpm families (Fedora and RHEL through dnf,
openSUSE through zypper). Both carry the same engine, built from one tag, for
`x86_64` and `arm64`. A separate `fermix-desktop` package adds the GTK4
companion application; it depends on the exact engine version it was built
against, drives the engine only through the typed CLI operations below, and
never writes a unit or calls `systemctl` itself. The engine is complete without
it — a headless server installs the engine package alone.

**The package owns the unit.** It installs a systemd *user* unit at
`/usr/lib/systemd/user/fermix.service` that starts `fermix service run`. Nothing
in Fermix writes, rewrites or removes it, and it carries no install-time values
at all — one unit file serves every account on the machine, and the optional
environment file it loads is each account's own `~/.config/fermix/env`.

**The listener port is a home setting.** `[fermix_web] port` (1024 through
65535, default 4030) is parsed and validated by the shared config layer, and
`fermix service install --port N` writes it through the same path, which works
while the daemon is down. A packaged engine **refuses** a `PORT` environment
variable rather than starting on an unexplained port: one unit file serves every
account on the machine, so the persisted setting is the only answer that can be
predicted. Standalone and source installs keep `PORT`, then the setting, then
the default. Changing the port needs a restart. `--port N` rewrites the whole
settings file through the shared renderer, so it refuses a `config.toml` that
carries a hand-written `[mcp.*]` block rather than dropping it: on such a home,
set the port by editing the file.

**The CLI owns the binding.** Because the unit names no home, the home each
account chose is recorded in `$XDG_CONFIG_HOME/fermix/service.json` (default
`~/.config/fermix/service.json`), a small file holding one absolute path and no
credentials. `fermix service run` resolves it before any configuration is read,
and refuses to boot when it is missing or malformed rather than guessing a
default home — guessing would start a daemon on somebody else's data.

**The verbs.**

- `fermix service install [--home PATH] [--json]` validates and records the
  binding, requires `loginctl enable-linger` (without it the daemon dies at
  logout and never returns), reloads, clears the start-limit budget, enables the
  unit, and then verifies: the bound home's own socket answers as a packaged
  engine and that daemon's web address is live, within ninety seconds. Moving an
  active service's home is refused until it has been stopped.
- `fermix service status [--json]` answers with no daemon running. It reports
  the binding, the effective unit and whether it is the package's, enabled,
  active and sub-state, pid, invocation id, restart count, linger, the listener,
  and the installed versus running engine identity with a typed alignment
  (`aligned`, `pending_restart`, `not_running`, `unknown`, `ownership_conflict`).
  Alignment compares build ids, never product versions.
- `fermix service uninstall [--json]` disables and stops the service. The
  binding, the home, the vendor unit and the extracted runtime all stay.
- `fermix restart [--json] [--when-idle]` is the one restart transaction, and
  systemd owns the termination signal throughout: the CLI takes the admission
  lease from the generation being replaced, clears the start-limit budget,
  issues a single `systemctl --user restart`, waits up to ninety seconds for a
  *different* pid to answer, and reports `previous_pid`, `pid` and the typed
  alignment. The lease is never committed — committing means "shut yourself
  down", which is systemd's job here — and is cancelled only when the restart
  could not be issued, while that generation is still alive to cancel it. With
  no daemon answering there is no lease and no previous pid, and the restart
  still runs. `--when-idle` is refused with a sentence until the shared protocol
  publishes an idle lease; restarting today interrupts work in progress, and
  saying so is better than quietly doing the interrupting thing.
- `fermix diagnostics export --offline [--json]` collects a bounded, redacted
  support bundle with no daemon at all, which is the state it is most needed in.
  Six sources — engine, service, doctor, logs, secret backend and desktop
  session — each report `available`, `unavailable` or `not_applicable` with an
  observation time, so a stopped daemon, an unreadable journal or a missing log
  file is evidence rather than a lost bundle. Logs carry both named places,
  labelled per entry: the daemon's rotated file and a bounded `journalctl --user
  -u fermix` tail. It reads no secret and never unlocks a keyring — the secret
  backend source reports tool presence only. One megabyte and ten seconds bound
  it; exceeding either is an error, never a truncated bundle with a reassuring
  name.

A user unit left at `~/.config/systemd/user/fermix.service` by an older
standalone install shadows the package's unit. `fermix service install`
recognises exactly that one shape, records its home as the binding, carries its
observability values into `fermix.service.d/fermix-observability.conf`, removes
it and reloads. Any other file at that path, or any drop-in Fermix did not
write, is a conflict it names and leaves alone.

**Logs live in two named places.** The unit sends its own streams to the
journal, so `journalctl --user -u fermix` shows early-boot output, crash dumps
and anything the runtime writes outside Logger. Everything the product itself
writes stays in the rotating `logs/fermix.log` the daemon owns, which is what
`fermix logs` and the Logs surface read. There is no third place.

**The package manager is the updater.** `fermix upgrade` refuses a packaged
engine before it looks at a single file — the refusal comes from the engine's
own build identity, so it is the same answer on a host where the ownership tool
is not even installed — and prints the line for the operator's family:
`sudo apt update && sudo apt upgrade fermix` on Debian and Ubuntu,
`sudo dnf upgrade fermix` on Fedora and RHEL, `sudo zypper update fermix` on
openSUSE. The same refusal covers a binary a host's package database owns
without this project having built it: a `dpkg`, `rpm` or `pacman` file answers
with its own family's line, and the community AUR rebuild is named as
`fermix-bin` with the operator's own helper rather than a command that would
not work. After any of them the daemon keeps running the old engine until it is
restarted.

**The package brings its own signature verifier.** `cosign` is installed at
`/usr/lib/fermix/cosign` and found through the shared `PATH` baseline, which
appends `/usr/lib/fermix` last — so a distribution's own `cosign` always wins
and the bundled copy can only make a lookup succeed that would otherwise have
failed. Plugin-signature verification therefore works on a stock packaged host
with nothing installed by hand.

**The runtime store is installer-managed state that outlives the package.** The
engine's own loader lives at `/var/lib/fermix/runtimes/<digest>/libc-musl.so`,
root-owned, written by the package's configuration step from bytes it verifies
first. Removing the package deletes nothing there, on purge either: a release
that is still running asks the kernel for that exact file every time it starts
a helper, so deleting it would break a live daemon. Each loader version is a few
hundred kilobytes and nothing prunes them automatically.
