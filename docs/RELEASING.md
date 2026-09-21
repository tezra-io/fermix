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
launcher on PATH, both green in every unit test. Walk these before announcing.

| Install path | What to run | What proves it |
| --- | --- | --- |
| Fresh install, no home | `brew install tezra-io/tap/fermix`, then `fermix setup` on a machine with no Fermix home | Setup completes without a pre-existing home, writes the user launch agent, and `fermix status` and `fermix doctor` both answer from the new daemon |
| Homebrew formula → app, via `fermix migrate-to-app` | `fermix migrate-to-app`, read the plan, then `fermix migrate-to-app --yes` | The plan refuses nothing and names no foreign `fermix` on PATH (the release's own launcher is its own); `--yes` drains the daemon, retires the launch agent, uninstalls the formula, installs the cask, and the app's onboarding reads the handoff journal and keeps the same home |
| Disk image dragged first, formula still present | Drag Fermix.app to `/Applications` while the formula and its launch agent are installed, then `fermix migrate-to-app` | The plan reports the application as already installed and says the cask step is skipped, rather than refusing and sending the operator to an onboarding that refuses back |
| App beside nothing | Install the application on a machine with no formula and no Fermix home, and open it | It onboards with no handoff journal to read and registers its own background service |
| Cask upgrade over a running service | `brew upgrade --cask fermix` on a Mac where the app's background service is registered and its engine is running | The old engine stops, the new app's service starts from the new bundle with no manual toggle, `launchctl print gui/<uid>/io.tezra.FermixPet.agent` shows the job running without a pending requirement refresh, and the app reports the pinned engine of the new version. The 0.1.3 upgrade left the job registered against the old bundle and every spawn of the launcher without a `PATH`; a bundle replaced under a registered agent is its own install path |
| Linux formula | `brew install tezra-io/tap/fermix` on Linux, then `fermix setup` and `fermix migrate-to-app` | The Linux install works unchanged and the macOS-only verb refuses with a sentence (`not_macos`), not a crash |
| Linux package, by the installer | `curl -fsSL https://fermix.ai/install \| sh` on a Debian or Ubuntu machine and on a Fedora one, each logged in as an ordinary account with a terminal | The installer names the package and the package manager it chose, asks for the account's password through `sudo`, and `fermix setup` then runs as that account with the terminal as its input. `fermix service status` reports `aligned` with the unit marked `(package)`. Run a second time it says the latest release is already installed and downloads nothing |
| Standalone → Linux package | The same command on a machine whose account still has an earlier standalone `fermix` first on `PATH` | The package installs, the installer names the earlier binary and the page that moves it, and starts no setup |

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

**The installer, and the one job that runs after publishing.** `scripts/install.sh`
is what `https://fermix.ai/install` serves. On Linux with apt, dnf or zypper it
installs the package; everywhere else, and with `--standalone`, it installs the
standalone binary. It reads a package as `packages -> <target> -> <deb|rpm>` in
`releases.json`, where each entry carries `url`, `sha256`, `sig_url` and
`cert_url`, with a line-scanning awk rather than jq, so the feed stays
pretty-printed, one key per line; `test_install_sh.py` runs the installer over
the feed `build_releases_json.sh` really writes, which is what holds the two
together. The installer reads the public `latest` feed and the public download
URLs, and a draft has neither, so `release.yml`'s `installer` job runs after
`promote`: `scripts/release/verify_installer.sh` waits (twelve checks, ten
seconds apart) for `latest` to name the tag, runs the installer with `cosign`
present, and requires that it chose the package, verified the signature against
the tag, left the package database and `fermix --version` naming the release,
and changed nothing on a second run — the debs on the two Ubuntu runners through
`sudo`, the rpms as root inside `fedora:41`. Nothing waits on that job. A red
one means the advertised command is broken for a release that is already out:
fix the installer and re-serve it, because the release itself cannot be
replaced.

**Serving it.** `fermix-site` vendors the script as `public/install`, byte for
byte, and a test there pins its sha256 and the engine commit it came from; the
served copy is never edited in the site repository. Check the copy before the
site deploys:

```sh
cmp scripts/install.sh ../fermix-site/public/install
```

**The order matters the first time a release changes what the installer needs.**
An installer that installs packages, served against a `latest` release that
carries none, refuses every apt, dnf and zypper machine with `lists no deb
package`. So the site deploys the new script only after the release that
publishes packages is out, which is where the site already sits in the release
order.

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
