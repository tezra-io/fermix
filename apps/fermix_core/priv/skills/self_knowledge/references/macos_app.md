# The Fermix macOS application (app-managed engine)

On macOS, Fermix ships two ways: the **standalone** binary (Homebrew formula,
install script, or a downloaded release) that installs its own launchd unit, and
the **Fermix.app** bundle, whose engine runs as an app-owned background service.
The engine knows which one it is from an immutable build identity — it is never
inferred from where the binary sits — and the CLI behaves differently in each.

## App-managed CLI behaviour

The application owns the background service, so the verbs that would create,
remove, or drive a launchd unit are not the CLI's to run.

**Two predicates decide this, and they ask different questions.** The build
identity asks whether *this binary* is the app engine. A standalone binary on
PATH beside an installed app answers that false, so it would otherwise happily
install, start, or stop a service the app owns. A second check asks whether
*this home* is app-managed, and it is a table over two states of the machine
rather than a chain: when a daemon answers on the management socket, its
identity decides; when none answers, a small ownership marker in the home
decides, and only while the app bundle it records still exists. It fails open —
a machine with no app, no daemon, and no marker behaves exactly as it always
has — and it covers `fermix start`, `fermix stop`, and `fermix service install`
(refused) plus `fermix setup` and `fermix upgrade` (routed to the app). It does
**not** cover `fermix service uninstall`, which is the supported way to remove a
unit the app does not own. A standalone CLI beside an installed app stays a
supported client of that app's daemon: everything else runs against it over the
socket exactly as it runs against a standalone one.

The verbs, on an app-managed engine:

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

## What the application reads and writes over the management socket

The application never edits `config.toml` itself. It reads a typed description
of the settings and sends back typed values, and the daemon is what writes the
file — so the browser setup page and the application are two doors onto one
writer rather than two writers racing each other.

- The daemon publishes an **ordered inventory of settings sections** and, for
  each one, its **rows**: a key, a label, a footer, the value in force, the
  options where the value is a choice, the bounds and unit where it is a number,
  and whether changing it needs a restart. Labels and sentences are the
  daemon's; no front-end writes its own.
- A row is one of six kinds: a toggle, a choice, a text field, a number, a
  secret, or a list. A row marked read-only is shown and changed elsewhere.
- **A choice row's options are its value space unless the row says they are
  suggestions.** A plain choice row refuses a value that is not among its
  options; a suggestions row (the time zone, the communication style and the
  model rows) offers what it can list inline and still accepts anything its own
  validator takes, so a native picker can send a zone or a model the daemon has
  never listed.
- The restart mark is derived from the values the daemon read at boot, so a row
  can never claim a change takes effect immediately when the next status read
  would ask for a restart.
- **Secrets travel one way only.** There is one method for storing a secret,
  one secret per call, and nothing ever reads a secret back out: every other
  answer says only whether one is present. Forgetting a secret removes the
  keyring item, the reference to it, and the value the running daemon holds.
  Four id families reach it: a registry key, a plugin's own token, a sign-in
  client's secret, and the Anthropic setup token — the last of which is a
  subscription credential rather than a keyring item, so storing one also
  selects the sign-in route that reads it and clearing one is the same act as
  signing out.
- **Connecting the first provider makes it the one Fermix calls.** A key stored
  or a sign-in completed on a home with no configured primary promotes that
  provider, through both doors and by one rule; after the first one, changing
  the primary is an explicit action.
- **Signing out signs the running daemon out.** The stored session is deleted,
  the route it fed reverts, and the tokens the running process holds are
  dropped, so nothing keeps calling as the account just removed.
- **A settings file edited outside Fermix stops writes rather than losing
  them.** While an outside change stands, every write refuses and says so; one
  action re-reads the file and clears the state. A file that cannot be parsed is
  a different state, reported with the parser's own sentence and never answered
  with a re-read that would fail the same way.

## Long operations are jobs, and the application polls them

Anything that waits — a browser sign-in, a download, an OS permission prompt, a
metered call to a provider — is a *job* rather than a held request. The starting
method mints a job id and returns at once; one method reads a job, one lists
every job the daemon still holds, and one cancels a running job. One shape
covers all of them, so a surface has one progress row and one failure sentence
rather than one per operation.

- A job carries its kind, its state, the step it is on, progress where the work
  reports any, the budget it is bounded by, and either its result or a failure
  with the daemon's own sentence. The step names come from a closed list per
  kind, and the application turns each into a sentence; it is display copy, not
  a state to branch on.
- Every bound is published: one budget per kind, one running job per kind and
  name, at most four running at once, and a fixed number of finished jobs
  retained for a fixed window. Asking about a job the daemon no longer holds is
  its own answer, distinct from an unknown method.
- Because jobs are listable, a panel reopened over a running install finds it
  again instead of starting a second one.

The flows that start a job, and the reads beside them:

- **Signing in through a browser.** The daemon opens the loopback listener,
  mints the authorization link, and hands it back once on the call that starts
  the flow; the application opens it and then polls the job. The link is never
  logged and never repeated by a later read. Signing in to a provider whose
  route is credential-driven also switches that route, because a stored token is
  inert until it does.
- **Adopting a sign-in this Mac already has**, from Claude Code or the Codex
  CLI. It is a job because reading the keychain can raise the allow prompt. No
  token ever crosses the socket; only an account name does.
- **Signing out** forgets the local session and puts the route back. Nothing is
  revoked upstream, and signing out twice is not an error.
- **Providers.** The daemon lists a page of models, from the catalog this build
  ships or from a provider that can list what it serves right now, and a live
  listing that fails refuses rather than quietly answering from the catalog
  under a live label. Making a provider primary is refused unless it already has
  credentials. Probing a provider is a real metered call and therefore a job.
- **Installing a capability** — the computer use helper, the meeting notetaker
  and its browser, or the on-device speech backend — is one job kind with one
  target per call, idempotent, so a retry resumes rather than starting over.
- **Computer use permissions** are read without prompting and granted only on an
  explicit ask, which is a separate job. Whether the helper is installed is read
  from the installer, so a switched-off feature still reports honestly whether
  the helper is on disk.
- **The meeting notetaker's one-time sign-in** is a job that waits at a headed
  browser. Its refusals name what is missing rather than reporting a bare exit.
- **Detection** answers, for only the targets asked about, whether this Mac
  already has a chosen primary provider, Claude Code, the Codex CLI, a reachable
  Ollama, or a coding-harness CLI. Harness detection also reports each supported
  CLI's installation, version and authentication status, with setup guidance;
  neither credential values nor binary paths cross the wire.
- **Installing a plugin, checking one, listing a hosted plugin's workspaces and
  binding one** are four job kinds of their own. The binding answers only once
  the replacement client is connected and its signed contract re-checked, so a
  reported binding is a working one rather than a started process.

## Integrations are one list, and every word on a row is the daemon's

One read answers the whole integrations surface: every plugin the registry holds
and every remaining entry in the catalog this build ships, in one row shape, plus
one entry per sign-in client a published plugin needs. Client entries include
its public client ID and secret-presence flag so native settings can edit an
existing client without re-entering its ID; no secret value is returned.
A row carries where the
plugin stands as a sentence, the verb it leads with, the settings its manifest
declares, whether a credential sits behind it, the access levels it offers and
the workspace it is bound to. The status vocabulary and the verb vocabulary stay
on the daemon side; the application arranges the words and writes none of them.

- **The consent sentence is always present and names where the code runs**: on
  the plugin's own servers, on this Mac as a separate process, or inside Fermix
  itself. A plugin that runs somewhere else also carries what leaves this Mac.
  There is no default, because a hosted plugin rendering the local-process line
  would tell the operator their content stays here when it does not.
- **Every verb is published twice: the word to draw and the action it runs.**
  The words are the daemon's copy and the actions are a closed set of ids in the
  same order, so a surface paints the label and routes on the id rather than
  guessing the method from the row's state and disagreeing with its own button.
- **Turning one on, turning it off, disconnecting it, writing one manifest
  setting, and registering a sign-in client** are ordinary requests that answer
  with the row. A plugin's own token and a sign-in client's secret travel only
  through the one inbound secret method, under their own ids; a plugin's browser
  sign-in is the same sign-in flow every provider uses, addressed by plugin name.
- **A hosted plugin's workspaces are republished on its row**, not in the job
  that found them: a job result is flat values only. The list is boot-bound, so
  a restart clears it and the next discovery replaces it.
- **Disconnecting is local.** An OAuth session is deleted and a stored token is
  removed from the keyring; neither is revoked with the provider.
- **The native driver features are not integrations.** Computer use, computer
  history and the meeting notetaker have their own settings sections and their
  own switches, so they never appear as plugin rows even where the catalog
  carries an entry for their helper.
- **A sign-in client appears only where a plugin needs one**, derived from the
  providers the published rows name rather than from a fixed table.

## One wire, two release cadences

The application and the engine ship from separate repositories, so the socket is
versioned and the two halves negotiate rather than assume. The daemon accepts a
window of protocol versions: the current one and the one before it. An
application that speaks the older version still reaches the whole read side —
the overview, the logs, Doctor, the diagnostics bundle, and the calls that
restart the daemon — which is what lets it restart that daemon onto the newer
engine bundled beside it.

- **Each method declares the lowest version that may call it**, and the whole
  table is published, so a client can tell "this needs a newer Fermix" from
  "this daemon has no such method". Those are two different states with two
  different remedies, and a Settings pane that says the first is telling the
  operator to finish an update, not reporting a fault.
- **A version outside the window is refused before anything runs**, saying which
  half is behind: the application is too old, or Fermix is.
- **The daemon ships first.** A new version is added to the daemon while the old
  one is still served, and only then does an application that requires it ship.
  A rollback is the reverse. That order is what keeps the two from ever being
  mutually unintelligible.
- **The contract is an artefact, not a description.** The daemon publishes the
  schema, the per-method minimums, the published bounds and a golden example of
  every request, result and error beside itself; the application vendors that
  export by checksum and tests its own client against the same examples. Neither
  side hand-copies a shape.

Every sentence that crosses this socket is the daemon's: row labels and footers,
choice options, section titles, the sentence behind a plugin's state, what to do
about a failed Doctor check, why a restart is pending, and why a write was
refused. They are held to one set of rules — sentence case, no dashes for
punctuation, no exclamation marks, no version numbers, and no configuration key
or internal identifier dropped into prose without being marked as something to
type. A front-end arranges them and rewrites none of them, so the two doors say
the same thing on the day a sentence changes.

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
