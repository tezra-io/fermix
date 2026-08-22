# The Fermix macOS application (app-managed engine)

On macOS, Fermix ships two ways: the **standalone** binary (Homebrew formula,
install script, or a downloaded release) that installs its own launchd unit, and
the **Fermix.app** bundle, whose engine runs as an app-owned background service.
The engine knows which one it is from an immutable build identity — it is never
inferred from where the binary sits — and the CLI behaves differently in each.

## App-managed CLI behaviour

The application owns the background service, so the verbs that would create,
remove, or drive a launchd unit are not the CLI's to run:

- `fermix start`, `fermix stop`, `fermix service install`, and
  `fermix service uninstall` exit non-zero and point at the app's
  **Enable/Disable background service** controls. (The app deliberately does not
  call these Start and Stop: the durable state is the service *registration*,
  not whether a process happens to be alive right now.)
- `fermix setup`, `fermix upgrade`, and `fermix uninstall` open the matching
  application screen and report only that the hand-off was accepted — never that
  the screen finished its work. `fermix upgrade` starts a foreground update
  check in the app; its exit status does not mean an update installed.
- `fermix status`, `fermix doctor`, and `fermix logs` are answered by the daemon
  over its management socket, because the daemon — not the CLI process — holds
  the bootstrap home and the app's identity. `fermix logs -f` is refused there:
  the application's Logs screen is what follows the log, and the management
  surface does not open a streaming connection. `fermix logs -n` above the
  published page ceiling is refused with the exact ceiling rather than quietly
  clamped.
- `fermix doctor`'s binary-integrity, upgrade-available, and service-unit rows
  report `N/A`: the app updates itself and registers its own login item, so a
  standalone release feed, an in-place binary swap, and a launchd unit do not
  apply. They appear in the plain run, not only under `--full`.
- `fermix restart` works, and follows the app-owned restart contract rather than
  touching a launchd unit: it drains the daemon over the management socket,
  commits the shutdown, and waits for a *different* process to answer. The
  service registration is never changed, so the app's login item brings the
  daemon back. If the daemon is not answering at all, it says so and points at
  the app's background-service controls rather than at a verb this engine
  refuses.

On a standalone engine none of that applies — the checks run locally, `logs -f`
follows the file, and `fermix uninstall` refuses rather than guessing an owner,
naming the service unit this binary installed and the package manager that owns
the binary.

## Moving a Homebrew formula install to the app: `fermix migrate-to-app`

`brew uninstall fermix` alone is not enough on macOS: the formula never owned the
launch agent (`fermix setup` wrote `~/Library/LaunchAgents/io.tezra.fermix.plist`),
so uninstalling the formula strands a KeepAlive job pointing at a deleted binary.
`fermix migrate-to-app` performs the move as one transaction, and it must run in
the operator's own shell — that is the only place a custom `FERMIX_HOME`
exported there is visible.

Run without arguments it inspects the account and prints the plan, changing
nothing; `fermix migrate-to-app --yes` performs it. In order: drain the daemon,
boot out and remove the launch agent it verified byte-for-byte, write an
owner-only handoff journal under `~/Library/Application Support/Fermix/`,
`brew uninstall --formula fermix`, `brew install --cask tezra-io/tap/fermix`, and
launch the app, which reads the journal, keeps the same Fermix home, registers
its own background service, and verifies the same data before clearing it.

Every step is executed and every failure is loud: a `launchctl bootout` the
system refused fails the whole migration with launchd's own words and leaves the
launch agent in place, and a failing `brew` step stops the transaction quoting
brew's output rather than degrading into printed advice.

It refuses, with the exact facts it inspected and what to do about them, when the
account is in a state it must not resolve on its own: a system-scope
LaunchDaemon, a launch agent that is not the one `fermix setup` wrote, more than
one `Fermix.app` copy, an already-installed `Fermix.app`, a running
`brew services` entry for fermix, a launch agent whose daemon does not answer,
another `fermix` on `PATH` owned by neither Homebrew nor the app, or no Homebrew
formula install at all. It is macOS-only — the Linux `fermix` formula continues
unchanged — and an engine that is already app-managed has nothing to migrate.

**No path here ever deletes a Fermix home** — not the migration, not
`fermix uninstall`, not the app's own uninstall route, which removes the app's
bootstrap record and CLI symlink and leaves the home alone unless the operator
separately confirms a destructive removal.
