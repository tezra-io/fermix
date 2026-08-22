# The standalone service unit and the built-in updater

This is the **standalone** install (Homebrew formula, install script, or a
downloaded release): the binary installs and owns its own launchd/systemd unit.
On a Fermix.app-managed macOS engine none of this applies — the app owns the
service and the app updates itself; see
`skill_view(name: "self-knowledge", file: "macos_app")`.

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

## Drifted units

The unit is a snapshot of install-time settings, but `fermix setup` self-heals a
drifted one: when the on-disk unit no longer matches what the current binary
would write (the `PATH` or the template changed across an upgrade, say), setup
rewrites and reloads it instead of just restarting. So re-running setup picks up
unit changes. `fermix service install` is the manual escape hatch.
