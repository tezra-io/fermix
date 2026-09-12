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
| Linux formula | `brew install tezra-io/tap/fermix` on Linux, then `fermix setup` and `fermix migrate-to-app` | The Linux install works unchanged and the macOS-only verb refuses with a sentence (`not_macos`), not a crash |

A CLI verb that inspects PATH, the process environment, or the account's files also
needs a step in `scripts/release/verify_standalone.sh` that runs it from the staged
artifact, so the packaged world is exercised by the rail and not only by hand.
