# Releasing

The release itself is `.github/workflows/release.yml`, fired by a `v*.*.*` tag; the
per-target smoke gates it runs on every candidate and staged asset live in
`scripts/release/`.

## Install paths to walk before announcing

The release rail proves the *artifact*: it is signed, its checksum matches, it runs,
and its packaged shims answer. It cannot prove an *install path* — which world the
binary lands in, what is already on the machine, and which files it then reads.
Every `migrate-to-app` defect that reached an operator was an install path nobody
walked: the verb refused an already-installed application, then refused its own
launcher on PATH, both green in every unit test. Walk these five before announcing.

| Install path | What to run | What proves it |
| --- | --- | --- |
| Fresh install, no home | `brew install tezra-io/tap/fermix`, then `fermix setup` on a machine with no Fermix home | Setup completes without a pre-existing home, writes the user launch agent, and `fermix status` and `fermix doctor` both answer from the new daemon |
| Homebrew formula → app, via `fermix migrate-to-app` | `fermix migrate-to-app`, read the plan, then `fermix migrate-to-app --yes` | The plan refuses nothing and names no foreign `fermix` on PATH (the release's own launcher is its own); `--yes` drains the daemon, retires the launch agent, uninstalls the formula, installs the cask, and the app's onboarding reads the handoff journal and keeps the same home |
| Disk image dragged first, formula still present | Drag Fermix.app to `/Applications` while the formula and its launch agent are installed, then `fermix migrate-to-app` | The plan reports the application as already installed and says the cask step is skipped, rather than refusing and sending the operator to an onboarding that refuses back |
| App beside nothing | Install the application on a machine with no formula and no Fermix home, and open it | It onboards with no handoff journal to read and registers its own background service |
| Cask upgrade over a running service | `brew upgrade --cask fermix` on a Mac where the app's background service is registered and its engine is running | The old engine stops, the new app's service starts from the new bundle with no manual toggle, `launchctl print gui/<uid>/io.tezra.FermixPet.agent` shows the job running without a pending requirement refresh, and the app reports the pinned engine of the new version. The 0.1.3 upgrade left the job registered against the old bundle and every spawn of the launcher without a `PATH`; a bundle replaced under a registered agent is its own install path |
| Linux formula | `brew install tezra-io/tap/fermix` on Linux, then `fermix setup` and `fermix migrate-to-app` | The Linux install works unchanged and the macOS-only verb refuses with a sentence (`not_macos`), not a crash |

A CLI verb that inspects PATH, the process environment, or the account's files also
needs a step in `scripts/release/verify_standalone.sh` that runs it from the staged
artifact, so the packaged world is exercised by the rail and not only by hand.

## Linux packages

The same tag that builds the four standalone binaries builds four Linux packages:
a `.deb` and a `.rpm` for `linux_x86_64` and `linux_aarch64`. They carry the same
Burrito-wrapped engine, stamped `linux_package` rather than `standalone`, plus the
vendor systemd user unit, a bundled `cosign`, shell completions, a man page, the
archive documentation and `/usr/share/fermix/engine.json`.

**What the rail does.** `release.yml`'s `linux-packages` job runs
`scripts/release/build_linux_packages.sh` for both targets; `sign-candidate`
cosign-signs all four package files beside the binaries and generates
`releases.json` (which now carries a `packages` object per target);
`verify-candidate` and `verify-published` each install all four — the debs on the
`ubuntu-24.04` and `ubuntu-24.04-arm` runners, where the whole
`service install` → `status` → `uninstall` transaction runs against a home whose
path contains a space and a percent character, and the rpms inside a `fedora:41`
container, where there is no user service manager and `service status --json`
must answer the structured `user_manager_unreachable` error. `stage-release`
attaches the packages to the draft.

**The version rule, and what it costs.** Neither package may carry a Debian
revision or an rpm epoch, because `fermix-desktop` pins `Depends: fermix (= <v>)`
and `Requires: fermix = <v>` and the two spellings must mean the same thing. The
build script refuses a version containing `-` or `:` before it builds anything,
so **a prerelease tag produces no packages at all**. One consequence is worth
stating: nFPM's rpm packager defaults an empty `release` to `1`, so the rpm is
`fermix-<version>-1.<arch>.rpm` while the deb is `fermix_<version>_<arch>.deb`
with no revision. That asymmetry is harmless — an rpm `=` relation on a version
matches any release — but it is the reason a packaging-only fix is published as
the next version rather than as a revision of the current one: nFPM's `release`
is a single top-level field, so the two families cannot be given different
revisions from one configuration anyway.

**Building one locally.** On Linux, with `patchelf`, `zig` and `xz` present:

```sh
FERMIX_BUILD_ID=local-1 FERMIX_BUILD_SOURCE_COMMIT=$(git rev-parse HEAD) \
  scripts/release/build_linux_packages.sh linux_x86_64 <version> packaging/linux/out/packages
```

On a Mac, or to reproduce the release toolchain exactly, add `--container`: the
build runs inside `packaging/linux/docker/Dockerfile.build`, which pins the same
OTP, Elixir and Zig the release job uses. Add `--dev` to build the working tree
instead of the exact committed tree; it stamps the build id `dev-<sha>-dirty`,
and its packages are for testing only. A branch build with no tag is also a
workflow: `linux-packages.yml` runs on `workflow_dispatch` and on pull requests
that touch the packaging surface, and uploads the packages as artifacts.

**Verifying one by hand.** `scripts/release/verify_linux_package.sh <package>
deb|rpm <version>` is the same script the rail runs. The deb path needs
`RUNNER_TEMP` set to a writable directory and `sudo`; the rpm path needs Docker.

**The loader store.** Every packaged engine's ELF interpreter names
`/var/lib/fermix/runtimes/<digest>/libc-musl.so`, which the package's postinstall
materialises from `/usr/lib/fermix/runtime-payload/libc-musl-<digest>.so` after
verifying the digest. Nothing removes it, including on purge, because a release
that is still running opens it every time it spawns a helper. Say so in the
release notes when the loader digest changes.

**The typed CLI export is a vendoring obligation.** `apps/fermix_core/priv/cli/`
holds `CONTRACT.md` and one golden per published `--json` result. A graphical
Linux client vendors that directory the way `fermix-macos` vendors
`priv/management/`, so the order is the same: land the engine change with its
regenerated goldens, release the engine, re-vendor in the client repository,
then release the client. Adding a field is safe for a client already in the
field; removing or repurposing one is not, and changes the envelope's
`schema_version`.
