# Changelog

All notable changes to Fermix are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A Games plugin is in the catalog.** Install it from the setup Plugins
  page or the macOS app's Available list, with nothing to connect, and Fermix
  knows where its games are: ask it to play chess, or which games it can
  play, and it reads the games index on fermix.ai itself, opens the game's
  lobby in its own browser and plays through the page's WebMCP tools. No link
  or address needs to be pasted. The plugin is one skill and no tools, and it
  carries the rules of play in a chat: a game is played move by move, because
  a page's wait tool holds the conversation while it waits.

### Fixed

- **A sign-in that loses the network now says so.** When the provider's sign-in
  server timed out or could not be reached after the browser step, the daemon
  crashed while logging the error, and the app showed only "The operation failed
  inside the daemon." Error details such as a network timeout are now logged
  safely, and the sign-in fails with a sentence that names the problem and asks
  you to sign in again.

## [0.11.0] - 2026-09-23

### Added

- **Grok 4.7, Claude Opus 5.5, and GPT-6 Sol and Luna are in the model
  pickers.** They appear in the browser setup and in the macOS app. Grok 4.7
  goes to the head of the SpaceXAI list and becomes its default, so an
  install that never picked a Grok model moves to it on upgrade. To stay on
  Grok 4.6, pick it in setup. Claude Opus 5.5 joins the Anthropic list, and
  the Anthropic default stays Claude Sonnet 4.6. GPT-6 Sol and GPT-6 Luna join
  both the OpenAI API list and the ChatGPT-subscription (Codex) list, after
  GPT-6 Astra, which stays the default on both. Opus 5.5 always thinks and
  refuses forced tool use, and Fermix already sends it requests that follow
  both rules.
- **Venice is a provider, and every model says how private it is.** Save a
  Venice API key under Providers and Venice joins the fallback chain after
  Mistral, ahead of the local Ollama hop. The model picker lists every
  tool-calling model Venice serves, newest first within each model family, and
  each label ends with the privacy tier Venice publishes for that model:
  `Private` when the prompt is not kept, `Anonymized` when it is passed to the
  model's maker without your account and that maker still reads it, and
  `Private (TEE)` when the model runs inside a hardware enclave. An info control
  beside the Model row explains the three, in the browser setup and in the macOS
  app. The default model is `grok-4-6`, a private one. Every request tells
  Venice not to add its own system prompt and to strip inline thinking out of
  the reply.
- **One tab of your own browser can be handed to Fermix.** Click the Fermix
  browser extension on a tab and Fermix can read and act in that tab, with your
  real login, without a second browser and without touching the pointer. It is
  the same `browser` tool with the same rules — the read policy, the navigation
  checks and the upload path policy are unchanged — reached with
  `profile: "selected_tab"`. Everything browser-wide stays with the managed
  profile and is refused there by name: no new tabs, no closing tabs, no
  bringing a tab to the front, no cookies, no downloads. Closing the tab,
  dismissing Chrome's debugging bar, opening DevTools on it, or ending the task
  detaches, and Fermix says which of those happened. Only a turn you are present
  for can use it: guest, scheduled, background and delegated runs get the
  managed browser instead. Install the bridge with
  `fermix browser bridge install --browser chrome --extension-id <id>`; the
  extension and how to load it live in `apps/fermix_core/priv/browser_extension/`.
- **Computer use can work inside one window, experimentally and off by default.**
  With `background = true` under `[fermix_core.computer_use]` — a new setting that
  ships switched off and stays off until it has been checked on a real desktop —
  Fermix picks one window and works in it: it sees that window even when another
  covers it, its coordinates are that window's rather than the screen's, and where
  the window offers named controls it presses them without taking the pointer, so
  you can keep working in front of it. The helper puts a small panel on screen
  naming the window it is in, with pause and stop that reach it directly rather
  than through the daemon. Stop there stops the work, not just the session: it
  says so in the conversation, and it tells Fermix to put the task down and ask
  you before going any further rather than carrying on with a fresh helper. Choosing the whole screen instead is an explicit move with
  its own wording, so going from working quietly in one window to moving your
  pointer around is never something that simply happens. While the setting is off
  none of this is offered to the model and computer use behaves exactly as before;
  the new `window binding` row in `fermix doctor` reports the setting, whether the
  installed helper can bind a window, and whether its on-screen panel is there.

- **A click's picture now waits for the screen to react.** The image a computer-use
  action came back with was taken the instant the input went out, before the
  application had done anything, so a button that takes a moment to repaint looked
  as though nothing had happened and got clicked again. The check now waits for
  that view to stop changing before it is captured, and says so when it never did.
  It also says when nothing visible changed since the picture the action was aimed
  at — in plain words, and as a fact about the view rather than a verdict on the
  click, because an action that changes nothing on screen is often an action that
  worked. When three actions in a row leave the view unchanged, the result says so
  and names the ways out: a fresh full screenshot, a list of the controls, or
  telling the user. Nothing is blocked by it. Pressing a control by name no longer
  takes a picture at all — the control itself is read again and its state reported
  in one line, including when it has gone entirely, which usually means the press
  worked and dismissed it — and a zoomed action no longer costs a second round trip
  to the helper for its picture, because an action and its check are one exchange.

- **Buttons can be pressed by name instead of aimed at.** The element listing now
  gives each control a short reference and says what that control itself can do —
  whether it is enabled, whether it can be pressed, whether its value can be set —
  plus where it sits, so two "Save" buttons in one window are tellable apart. A
  control that can be pressed is pressed by name: no pointer moves, nothing is
  aimed, and it cannot land on the wrong thing. A field that reports itself as
  settable is filled the same way, and its value is read back afterwards, so a set
  that could not be confirmed says so and says to check the field rather than
  being reported as done. Typing and pasting stay for fields that are not
  settable. A click, move or scroll can name a control instead of a point too, and
  the control's position is re-read as it is used, so one that has shifted since
  the listing is still hit. Disabled controls are now listed AS disabled rather
  than left out, because a button that is simply missing invites a guess about
  why. Nothing is ever swapped for something else: a control that cannot be
  pressed is refused and says so, a disabled one says to work out what enables it
  rather than to try again, and a reference from a listing that has aged out says
  to take a fresh listing. Naming a target twice — a control and a coordinate on
  the same action — is refused before anything reaches the screen. An action that
  pulls its application to the front now says so, because it changes where the
  next keystroke goes.

- **Every screenshot now has a name, and a click says which picture it came
  from.** Before, coordinates read on a zoomed crop only landed correctly if the
  same `region` rectangle was repeated on the click that followed, and forgetting
  it sent the pointer somewhere else entirely — a whole class of clicks that
  looked confirmed and missed. Now each screenshot, element listing and window
  listing comes back with an id, the text beside the picture says so, and every
  click, move, drag, scroll and inspect names the image its coordinates were read
  in. A pointer action that names none is refused before anything reaches the
  screen, and the refusal says exactly what to do next. Only the last few images
  stay usable, and only for about half a minute: naming one that has been
  replaced, has aged out, or belongs to a display that moved or changed size is
  refused rather than clicked, and a point off the edge of the image it names is
  refused rather than nudged onto the edge. A numbered mark now belongs to the
  picture it was badged on, so its number keeps working while that picture does.

- **Only one conversation drives the cursor and keyboard at a time.** Two
  conversations acting on the same desktop each moved the pointer the other had
  just aimed and read a screen the other was changing, so both concluded their
  clicks had missed and repeated them. A disturbing action from a second
  conversation is now refused straight away, with a sentence saying to wait
  rather than re-send; looking is never blocked, so both can still take
  screenshots. The hold lapses once its conversation has dispatched nothing for
  a minute, so a conversation that went quiet cannot keep the machine.
- **Computer-use sessions now appear in traces.** A session starting, being
  paused and resumed, finishing, or dying on its helper used to leave no record
  anywhere: the events were emitted and nothing listened. They now reach the
  local trace stream, the Opik exporter and trace replay, and a session that
  died says so with its reason instead of looking like one that finished. Every
  `computer_use` tool call also records which session it ran in and how it ended:
  `refused`, `performed`, `performed_unverified`, `unknown`, or `read`.
- **Several form fields can be filled in one browser step.** The `browser`
  tool's `act` gains a `fill_form` kind that takes up to twelve fields from one
  snapshot and fills them in order, so a five-field form is one step instead of
  five. It only fills: it never clicks or submits. Every field is checked against
  the page before anything is typed, so a field that is no longer there refuses
  the whole call instead of leaving the form half filled.
- **The browser can use the tools a page offers to agents over WebMCP.** A page
  that registers WebMCP tools (a game, a docs search, a booking form) can now be
  driven with one typed call per step instead of a snapshot and a click. The
  `browser` tool gains a `webmcp` action: `op: "list"` names the tools the page
  offers with their input schemas, and `op: "call"` runs one by `name` with an
  `input` object. It runs in the same managed Chrome and behind the same read
  policy as every other page read, and the managed Chrome now starts with the
  WebMCP feature on, so a site that relies on the browser's own API works as
  well as one that ships its own shim. Tool names, descriptions and results come
  from the page, so they are marked as page content and never treated as
  instructions. A tool that throws, or does not answer in time, is reported that
  way with its effect unknown, so the assistant looks before it repeats anything.
- **A prompt file you never edited adopts the newer shipped template on the
  next daemon start.** Setup seeds `SOUL.md`, `FERMIX.md`, `REALTIME.md` and
  `LIVE.md` once and then treats them as yours, so a `brew upgrade` or an app
  update that shipped better prompts never reached an existing home. The daemon
  now compares each of those four files against the baseline it recorded
  (the seed, an earlier adoption, or a `/soul reset`) and against the template
  the running build ships: a file still equal to its baseline is rewritten to
  the new default through the versioned registry (revertable with the existing
  history), a file you changed is left alone and named in the log and in the
  `bootstrap templates` Doctor row, and a file with no baseline record is never
  guessed to be untouched. `IDENTITY.md`, `USER.md` and `MEMORY.md` are never
  part of this.
- **A skill's API key can be stored from Settings, and every shell command
  gets it.** Allow the variable name under Settings > Sandbox, then add its
  value on the row that appears.
  - The value is stored in the Keychain on macOS, or in the Secret Service
    on a Linux desktop, under its own entry (`fermix:external_env:NAME`). It
    never collides with a provider key of the same name.
  - Every shell command the assistant runs receives it as an ordinary
    environment variable, in chat, scheduled jobs and delegated work alike.
    It needs no terminal export, no change to the skill and no restart.
  - Removing the value deletes the stored item and keeps the name allowed.
  - On the management wire this is a new `env:<NAME>` id family on
    `secret.set` and `secret.clear`, plus one row per name in the sandbox
    section. There is no new method, so an older app shows the rows through
    its existing secret control.
- **A Linux server with no keyring can supply skill keys from a file.** The
  service unit now loads an optional `~/.config/fermix/env` (for a system
  unit, `/etc/fermix/env`), one `NAME=value` per line. An allowed name with
  no stored value is read from there. Changing the file needs a service
  restart.

- **A Fermix installed from a Linux package manages its service through
  its own verbs.** The package owns the systemd user unit, so
  `fermix service install [--home PATH]` writes no unit: it records which
  home this account's service runs in `$XDG_CONFIG_HOME/fermix/service.json`
  (default `~/.config`), requires `loginctl enable-linger`, enables the unit,
  and then proves it worked — the bound home's own socket answers and that
  daemon's web address is live, within ninety seconds. `fermix service
  uninstall` disables and stops the service and keeps the binding, the home
  and the runtime store. A user unit an older install left behind is
  recognised and migrated: its home becomes the binding, its observability
  values move into a drop-in, and the shadowing unit is removed. Any other
  unit or drop-in is named and left alone.
- **`fermix service status [--json]`** answers with no daemon running, and
  reports the binding, the effective unit and whether it is the package's,
  enabled, active and sub-state, pid, invocation id, restart count, linger,
  the listener, and the installed versus running engine identity with a typed
  alignment. A session with no user service manager is its own answer rather
  than a service reported as inactive.
- **Fermix installs from a Linux package.** Every release now also builds a
  `.deb` and an `.rpm` for x86_64 and arm64, carrying the engine, the systemd
  user unit the package owns, a bundled `cosign` so plugin signatures verify on
  a stock host, shell completions for bash, zsh and fish, a man page, and the
  installed engine's identity at `/usr/share/fermix/engine.json`. The packages
  are cosign-signed beside the standalone binaries, attached to the release, and
  described in `releases.json`; the release rail installs all four and runs the
  whole service transaction on a real host before publishing. Installing the
  package writes the engine's own loader to `/var/lib/fermix/runtimes/<digest>/`
  after verifying its digest, and removing the package leaves it there, because
  a Fermix that is still running opens that exact file whenever it starts a
  helper.
- **One command installs the Linux package.**
  `curl -fsSL https://fermix.ai/install | sh` installs the `.deb` through apt on
  Debian and Ubuntu and the `.rpm` through dnf or zypper on Fedora, RHEL and
  openSUSE, where it used to drop the standalone binary on every machine. It
  picks the package for the machine's architecture out of `releases.json`,
  checks its sha256, checks its cosign signature against the release tag when a
  `cosign` is there to ask — on a machine that already has the package, the one
  the package bundles — and hands the file to the package manager, which is
  told to remove nothing else to make room. Run again it
  is the updater: it installs the newer package, starts no setup and says to run
  `fermix restart`, and on the latest version it downloads nothing. An earlier
  standalone `fermix` that still comes first on `PATH` is named, with the page
  that moves it, instead of being set up by mistake. macOS, a Linux host with
  none of the three package managers, and `--standalone` get the standalone
  binary as before, and a package install that fails is never retried as a
  standalone one. Every package in `releases.json` now names its signature and
  its certificate the way the binaries do, and after publishing the release rail
  runs the advertised installer against the release it just published, on all
  four package targets.
- **The on-device speech engine is built for Linux, and setup does not offer it
  yet.** The `local` transcription backend now has a pinned, checksum-verified
  engine for Linux (x86_64 and arm64) as well as Apple Silicon Macs, all three
  from fermix-stt 0.1.1. Choosing it downloads a speech model on the spot, and
  that flow has not been proven end to end, so no picker lists it: not the
  browser setup's Voice notes tab, not either app, not the meeting notetaker's
  own backend choice, and the macOS app's install for it refuses. A
  configuration that already names it keeps transcribing on-device and is shown
  the choice, disabled, saying it cannot be chosen. `local_offered = true` under
  `[fermix_core.transcription]` puts it back, which is how the flow is walked
  before it ships.
- **A keyring that cannot be used is a verdict, not a hang, and the file store
  is the other choice.** On Linux the login keyring stays locked after a
  fingerprint or automatic login (it is encrypted with the password), and
  Fermix used to treat an installed `secret-tool` as a usable keyring: every
  save pushed the secret at the lock, GNOME raised its unlock dialog, the
  three-second timeout fired, and the save failed with macOS wording. Before
  a write, and before the daemon reads a secret at boot, Fermix now asks the
  Secret Service three read-only questions over `busctl --user` — is a keyring
  running, which collection is the default, is it locked — and never a secret
  read, so a background daemon never raises that dialog. A save you make
  yourself still gets the prompt, and now gets time to answer it: the write
  used to be killed after three seconds, before anyone could type, so the
  dialog was never answerable. Only a store with nothing to answer (no keyring
  service, no session bus, no `secret-tool`) is refused before the write, with
  its own sentence; a locked keyring is tried, and a cancelled or unanswered
  prompt is refused with `the login keyring is locked, and the unlock prompt
  was cancelled or left unanswered. Unlock it when the prompt appears, or in
  Passwords and Keys; fingerprint and automatic login leave it locked`. An
  unchanged value is kept rather than pushed at the lock; at boot the secrets
  in an unusable store stay unresolved with one log line naming them. `fermix
  doctor` gains a `secret store` row that names the configured store, its
  verdict and how many secrets each store holds.
  The second store is declared, never slid into: `[fermix_core] secret_store =
  "file"` keeps each secret as one `0600` file under `<FERMIX_HOME>/secrets/`
  (the directory `0700`; readable only by that account and not encrypted at
  rest, the posture `auth.json` already has). `fermix setup --secret-store
  file|keyring` chooses it, and when the keyring refuses a save the terminal
  wizard asks once — a no leaves the refusal exactly as it was. It is the way
  in for a machine whose keyring cannot be unlocked at all. New secrets go
  to the configured store and are persisted as its sentinel, `@file` beside
  `@keyring`; each is read back from the store it names, so a home can hold
  both. `fermix setup --migrate-secrets` now moves every secret that is not in
  the configured store into it — plaintext and the other store's alike, one
  confirmation each — and refuses up front when the store a secret must leave
  cannot be read.
- **`fermix upgrade` tells a Linux operator the right command.** An engine this
  project built as a package refuses to update itself before it looks at a
  single file and names the command for the family — `sudo apt update && sudo
  apt upgrade fermix`, `sudo dnf upgrade fermix`, or `sudo zypper update
  fermix`. A binary the host's own package database owns is recognised too:
  `rpm -qf` and `pacman -Qo` join `dpkg -S`, so an rpm-installed or
  AUR-installed Fermix is no longer treated as a file the updater may rename
  out from under the package manager, and the Debian hint finally names a
  package that exists.
- **`fermix restart [--json] [--when-idle]` on a Linux package install** runs
  one restart transaction and lets systemd own the termination signal: it takes
  the admission lease from the daemon it is replacing, clears the start-limit
  budget, issues a single `systemctl --user restart`, waits up to ninety seconds
  for a different pid to answer, and reports the previous pid, the new one and
  whether the running engine is now the installed one. The lease is never
  committed, and is cancelled only when the restart could not be issued. A
  daemon that is not answering is recovered rather than refused. `--when-idle`
  is refused with a sentence for now, because restarting today interrupts work
  in progress and saying so is better than quietly doing it.
- **`fermix diagnostics export --offline [--json]`** collects a bounded,
  redacted support bundle with no daemon at all — the state it is most needed
  in. Six sources (engine, service, doctor, logs, secret backend and desktop
  session) each report available, unavailable or not applicable with an
  observation time, so a stopped daemon, an unreadable journal or a missing log
  file is evidence rather than a lost bundle. Logs carry both named places,
  labelled per entry: the daemon's own rotated file and a bounded
  `journalctl --user -u fermix` tail. Nothing is read from a keyring, and a
  bundle that would exceed a megabyte or ten seconds refuses rather than
  arriving truncated.
- **`[fermix_web] port`**, an integer from 1024 through 65535 defaulting to
  4030, sets the port the daemon's web listener and setup page use. It is
  parsed and validated by the shared settings layer and written by `fermix
  service install --port N`, which works while the daemon is down. A packaged
  engine takes the port from that setting and refuses a `PORT` environment
  variable rather than starting somewhere nothing can predict; standalone and
  source installs keep `PORT`, then the setting, then the default. Changing it
  needs a restart.
- **Doctor rows for a Linux host.** `linger` reads the same inspector the
  service verbs use and separates "not enabled" (with the one command that
  fixes it) from "this host has no `loginctl`" (which has no command to give).
  `service unit` understands a packaged install, where Fermix owns no unit:
  it passes when the package's unit is effective with a home bound, warns on a
  unit an older install left behind with the verb that adopts it, and fails on
  a file Fermix did not write, naming it. A new `engine alignment` row carries
  the typed comparison of installed and running engine identity, so a daemon
  still serving the old engine after an update says so once, with the restart,
  rather than in two places, and a new `package origin` row reports who owns the
  binary and the command that updates it, reading the same detectors `fermix
  upgrade` refuses with.
- **Behavioral eval scenarios** `linux_install_and_update` and
  `linux_service_not_running` in the `skills` suite.
- **The typed CLI is a published contract.** `priv/cli/CONTRACT.md` and one
  golden per published result under `priv/cli/fixtures/` describe the envelope,
  every error code with the sentence it prints, and every field of the service,
  restart and diagnostics results with its type and nullability. A test rebuilds
  every golden from the code that prints it and fails on drift, so a graphical
  client can vendor the directory and decode against it the way the macOS
  application vendors the management protocol.
- **A machine-readable mode for the service verbs.** `--json` on `service
  install`, `service uninstall` and `service status` prints one
  schema-versioned envelope on standard output and nothing else, with every
  refusal carrying a code and one sentence; prose and progress go to standard
  error. Exit 0 when the verb succeeded, 1 when it refused, 2 on a usage error.
- **Tesla plugin support.** A `tesla` sign-in provider that exchanges the
  code with the account's regional audience, sends the public redirect
  page Tesla requires (`https://fermix.ai/api/integrations/tesla/callback`,
  which forwards to the daemon's loopback listener), rotates refresh tokens,
  and records the account's region on the grant. HTTP plugin tools may
  declare `regional_urls` (the host is chosen from the signed-in region,
  never from the model), `requires_setting` (a tool exists only while a
  plugin setting reads `true`), and scalar bounds on their arguments.
- **Region on the sign-in client.** A regional provider offers its regions
  on the client row, `plugins.oauth_client.set` takes a `region`, the
  browser setup form renders the choice, and after every sign-in the daemon
  checks the account's region with the provider; a mismatch shows on the
  plugin row as `wrong_region` with the fix, and that grant is never served.
- **Plugin settings can be switches.** A manifest `config` entry declares a
  `kind` (`text` or `boolean`); a boolean setting stores only `true` or
  `false`, is published on the plugin row, and renders as an instant switch
  on the setup page's plugin card.
- **Local plugin processes can sign for the account.** A local plugin
  runtime can be gated by a setting (`runtime.requires_setting`) and
  receives the account's current access token through a daemon-owned file
  named by `FERMIX_PLUGIN_TOKEN_FILE`, rewritten on every refresh and
  deleted on sign-out; the refresh token and client secret never leave the
  daemon.
- **Behavioral eval suite** `tesla` (reads, command safety, explicit wake
  and command cases).
- **A call can be spoken by GPT-Live.** The voice companion has a second
  engine. `openai_realtime` stays the default and keeps the `screen_share`
  tool; `openai_live` hands the speaking to GPT-Live while Fermix does the
  work behind it, and has no screen sharing of its own. The engine is chosen
  per call, the setup and doctor surfaces report which one a host can run, and
  every trace and Opik export names the engine the call ran on.
- **Computer history records every site visited in the browsers you allow.** A
  settled navigation in an allowed browser is stored as its address reduced to
  scheme, host and path, with the page and window titles beside it; the
  per-site allowlist is retired, and an existing configuration boots, warns
  once, and drops the key on its next save. Typed text is sent only from a
  window that can be positively judged not private — the Chrome family carries
  a marker that makes that judgement possible, while Safari, Edge and Firefox
  answer "unknown", so their addresses are recorded, their typed text is
  withheld, and `/history status` names them. The scrubber also learned
  Luhn-checked card numbers and registry-checked IBANs.

### Changed

- **Every computer-use request and its reply are matched to each other.** Replies
  from the helper used to be paired with requests by the order they arrived, so
  one late reply — after an action timed out — became the answer to the next
  action, and a single unreadable line could silently answer the wrong question
  for the rest of a session. Each request now carries an identifier its reply
  echoes, a late reply is discarded instead of reused, and a reply that cannot be
  read ends the helper rather than being passed off as an answer. The
  workarounds this replaces are gone, including the drain that threw away frames
  arriving after a timeout. Computer use and computer history both require the
  matching helper version and refuse an older one at startup, so a partly
  completed upgrade says so instead of misbehaving.
- **Computer use answers `/pause` while it is acting, and `/pause` now tells you
  what the helper confirmed.** A single computer-use action can make four calls
  to the helper, each with a thirty-second budget, and the session used to sit
  inside them — so `/pause`, `/resume` and shutting the session down waited for
  the very action they exist to interrupt. The helper now runs in its own
  process and the session stays answerable throughout. `/pause` also reaches the
  helper itself rather than only this side of it: it stops a sequence such as a
  drag part way through, releases what that sequence was holding, and answers
  with what the helper acknowledged — paused, paused with one action still
  finishing, or, when the helper does not confirm, that it was shut down
  instead, because a machine that may still be driven must never be described as
  handed back. Stopping a session gracefully — `/stop`, the end of a
  conversation, a helper that answered and was reset — now releases any held key
  or button before the helper is ended, rather than leaving a modifier down; a
  helper that is killed outright still releases nothing, which is why the pause
  barrier, not the kill, is what stops a drag part way through. A
  second action sent while the first is still running is refused as busy instead
  of queueing behind it, so a long action no longer silently delays everything
  after it.
- **What a computer-use action reports is what the helper said it did.** The
  outcome of a click or a keystroke — sent, not sent, half sent — used to be
  inferred from whether the check screenshot came back, which could report an
  action as performed when nothing reached the screen. The helper now states it
  on every mutating action and that statement is what the result and the trace
  record. A helper that does not state it is treated as a broken helper: the
  outcome is reported as unknown and the session takes a fresh one, rather than
  a guess being reported as fact. A refused action carries the same statement, so
  "the helper said no" no longer implies nothing reached the screen.
- **Computer use tells the assistant the truth about what happened to an
  action.** A click whose helper timed out used to come back as "action failed"
  with a raw error term, and a check image whose cursor had moved used to say the
  action "did nothing, re-send the same action". Neither is known: someone moving
  the mouse makes a click that landed look like a miss, and a blind re-send is a
  double submit. The result now says what was and was not seen. An action that
  was sent but could not be checked says so; one whose outcome cannot be told
  says "outcome unknown" and asks for a screenshot before anything else; one that
  was never sent says it was not sent. How the assistant aims is unchanged.
- **A browser click now reports what it did to the page.** After a `click`, a
  `submit`, a `click_coords` or an Enter on a page the assistant has already
  read, the result says whether the page is `unchanged` (the elements it knows
  are still good) or `changed`, and a changed page comes back with its fresh
  snapshot, so the assistant no longer spends a whole extra step looking again.
  The address in the result is the one the page settled on, not the one it was
  leaving. Looking is bounded to about a second and a half and never fails the
  click: when the page cannot be read in time the result says `unobserved`, and
  when it moved somewhere the read policy refuses it says so and returns no page
  text. A snapshot no longer repeats every element in a separate list beside the
  text that already names it, which makes every later step in the turn smaller.
- **Opening a page in the browser now hands the page back.** `open` and
  `navigate` answered with the tab and nothing of what was on it, so the
  assistant's next step was almost always a second call whose only job was to
  look at the page it had just asked for. Both now wait for the page to settle
  and come back with it, in the same words a click uses: `changed` with the
  fresh snapshot, or `unchanged` when a navigation lands on content the
  assistant already holds. The wait is bounded and never fails the navigation: a
  site still building when the time is up is handed over as it stands, marked as
  still loading, so an ordinary slow page costs the wait and not another step as
  well; only a page that cannot be looked at at all — one holding a dialog, say
  — comes back unobserved. A page that ends up somewhere the read policy refuses
  returns the tab and the reason, and none of that page's text, address or
  title. A page opened only to be screenshotted, printed or driven through the
  tools the page itself offers can skip the look with `observe: false`. Your own
  granted tab still cannot open a second tab; navigating it hands back its page
  through the same checks.
- **A click's look at the page no longer gives up on a page that is nearly
  there.** The same rule applies after a click, a submit, an Enter or a
  click_coords: a page still rendering when the look runs out of time comes back
  as it stands, saying it was still building, instead of reporting that nothing
  could be seen. A single momentary browser error during that look — routine in
  the instant after a page commits — is retried rather than ending it.
- **The shipped persona and operating rules are shorter and sharper.** `SOUL.md`
  now asks for judgment with confidence that follows evidence rather than a
  forced side, dry wit with clear limits instead of stock praise, and scoped
  authorization instead of a fresh question for every outward step; its stale
  description of self-editing memory is gone. `FERMIX.md` drops rules that
  repeated it, says tools are the advertised and discoverable capabilities
  rather than "everything I have", asks only about gaps that change the
  outcome, carries the active task and earlier approvals forward, and keeps
  every verification, provenance and proof-of-work contract. New installs and
  untouched files get the new text; an edited file keeps yours.
- **`web_search` is the route for any fact that may have moved since
  training.** Every routing surface described it as a tool for static facts and
  sent "live data" to the browser, so a current price, rate, version or office
  holder could read as neither and be answered from memory. The tool
  description, the runtime routing rule, the browser guidance and the
  operating rules now say the same thing: a confident memory of a mutable
  fact is a reason to search, and the browser is for pages that need
  rendering, login or interaction.
- **Allowed variable values no longer appear in any process's command line,
  and are scrubbed from what the assistant sees.**
  - Shell commands and operator command capabilities now receive their
    environment directly as the child process's own environment.
    Previously it was passed as `env -i NAME=value` arguments, which any
    process on the machine could read.
  - Every allowed value of at least eight bytes is replaced with
    `«redacted»` in the command's result and in its trace. A non-secret
    allowed value, such as `NODE_ENV=production`, is redacted too.
- **Reading allowed variables has one time limit per command.** All helper
  lookups for a command share a five-second budget, so a locked keychain
  can no longer delay a command by three seconds for every name. A name
  still unread when the budget runs out is reported, and the command runs
  without it.
- **A missing allowed variable now names where to store it**: in the sandbox
  settings, or on a Linux server in the service's env file. The old
  sentence pointed at a CLI verb that the macOS app does not ship.
- **`fermix doctor`'s `cosign` row names the executable this host resolved**
  and the remedy for its own install family — the distribution's own package on
  a Linux package install, where the bundled `/usr/lib/fermix/cosign` is the
  fallback, and Homebrew's on macOS. It no longer tells a Linux operator to run
  `brew`.
- **The computer-use remediation stops naming an action the user cannot take.**
  On a Wayland session the row now says what is refused, why, and what remains
  true, instead of "use an X11 session" on desktops that no longer offer one;
  on arm64 Linux, where the sidecar publishes no build, it says computer use is
  unavailable on this architecture and that Fermix itself is fully supported,
  instead of offering an install that can only fail.
- **The daemon-socket Doctor row reports liveness only.** Whether the running
  engine is the installed one is a different question with a different remedy,
  and it is now the `engine alignment` row's, so the two can never disagree.

### Removed

- **Eden is no longer offered as a plugin.** The catalog no longer lists it, so
  the macOS app, the setup page and `fermix plugins` stop offering it. Support
  for hosted (remote MCP) plugins is unchanged, and Eden's published releases
  stay up, so an older Fermix can still install it. If you use Eden, disconnect
  it before you upgrade, then turn it off or run
  `fermix plugins uninstall eden`: disconnecting is what deletes its token from
  your keychain, and a Fermix without Eden can no longer find that token to
  delete it.

### Fixed

- **Asking the assistant to make a code change itself is no longer overridden.**
  With a coding agent set up, repository work such as a bug fix goes to a Codex
  or Claude Code run by default, and that default outranked the request: told
  "do this yourself, don't delegate", the assistant delegated anyway and said its
  instructions required it. An explicit request to do the work directly now
  wins.
- **The browser acts on an element named the way its page snapshot shows it.** A
  snapshot lists each control as `@link_3 [link] "Search"`, but an action naming
  `@link_3` was refused as out of date ("the page has changed since"), and the
  fresh snapshot it asked for showed `@link_3` again, so the assistant could loop
  on a page it had just opened until it gave up. A ref is now accepted as the
  snapshot shows it, with or without the `@`, in every action that takes one.
- **On-device speech says plainly where it can't run, and no longer shows up as
  a notetaker failure.** On a machine this build has no on-device speech engine
  for, choosing On-device for voice notes printed a developer instruction about
  building the engine from source, and the Integrations page repeated it under
  the Meeting Notetaker card, where it read as the notetaker's own error. The
  Integrations page no longer shows that result at all, and wherever the choice
  is still shown it carries the reason it cannot be chosen — beside it in the
  browser setup, on hover in the macOS app — and asking for it anyway is refused
  in that sentence. `fermix doctor` says on-device speech isn't available on this
  machine instead of naming an install, and a voice note sent while it is
  selected gets a reply saying to choose another backend rather than to try
  again. The choice is labelled "On this device", not "On this Mac".
- **The meeting notetaker's Google sign-in works on a fresh desktop again.**
  The pinned `meetbot` sidecar moves to a release whose sign-in window no
  longer announces itself as automated. Google Accounts refuses a browser that
  does ("Couldn't sign you in. This browser or app may not be secure"), and
  the sign-in window, unlike the join, launched with Playwright's
  `--enable-automation` on, so on a fresh Linux profile Google blocked the bot
  account's sign-in outright. The window is otherwise what it was: the
  sidecar's own pinned Chromium on the persistent profile the join reopens,
  never the default browser, because the signed-in state has to live where
  the join runs, and a human still types the password. Enabling the notetaker
  installs the new sidecar; an existing install picks it up the next time the
  card's install runs.
- **The installer's setup wizard reads the terminal, not the installer.** Under
  `curl … | sh` standard input is the script itself, so on a host with no
  display the terminal wizard `fermix setup` starts would have taken the rest of
  the script as its answers. Setup is now handed the terminal; with no terminal
  at all, as in a CI job, the installer prints `fermix setup` as the next command
  rather than starting a wizard nobody can answer. The installer's usage also
  named `fermix.sh`, a host that never served it; it is served at
  `https://fermix.ai/install`.
- **The browser's `console` action now faces the same read policy as every other
  page read.** Console entries are page text, and a page that redirected or was
  clicked onto a host the browser policy refuses logs there too — so `console`
  was returning bytes the same tab's `snapshot` had just refused. It is now
  refused the same way, in every browser profile.
- **A screenshot dropped from the conversation no longer leaves text describing
  it as if it were still there.** Older screenshots are removed to keep the
  conversation within its budget, but the words beside them stayed in the present
  tense — "this is what is really on screen" — so the assistant could reason about
  a picture it could no longer see. The note left in the image's place now says
  the text is a record of a past look and that nothing in it can be acted on.
- **`/pause` can no longer be raced, and says when an action is still
  finishing.** A pause that landed between the assistant deciding on an action and
  sending it was ignored for that action. It is now checked again at the moment
  of sending. When one action is already under way, `/pause` says it will finish
  and that nothing further will be sent, instead of claiming the cursor and
  keyboard were already yours.
- **A computer-use helper that stops answering no longer leaves the session half
  alive.** A check or an idle probe that timed out was swallowed, which left the
  helper's replies one step out of order so the next action could be answered
  with the last one's reply. A helper that exited mid-action, or was no longer
  running, left a session that failed every later action until the conversation
  ended. All of these now reset the session, so the next action starts a fresh
  helper.
- **A long page's snapshot and its element list can no longer disagree.** The
  snapshot text was cut to size after the elements had been collected, so the
  assistant could be handed elements whose lines it never saw. The text is now
  cut at whole lines and only the elements on surviving lines can be acted on.
- **A page with no accessibility tree no longer takes the browser down.** A
  snapshot reply with no tree raised inside the browser profile's process. It
  now answers `snapshot_unavailable`.
- **A coordinate click that landed is no longer reported as failed** when the
  address could not be read afterwards.
- **A plugin tool call now records what it was asked to do.** Every built-in
  tool traced its arguments, but the two plugin paths (declared HTTP tools and
  local plugin processes) traced only the result. A vendor can accept a call
  made with the wrong value and answer success, so a wrong navigation
  destination or a wrong seat read as a healthy call with nothing to explain it.
  Plugin arguments now ride the same trace field as every other tool's: only
  while content capture is on, and scrubbed of the values a turn marks for
  redaction.

- **A click is no longer sent twice when the browser dies mid-action.** When a
  browser profile's process died with an action in flight, the same request was
  re-sent up to three times, which for a click, a form fill, an upload or a page
  tool call means doing it again. A request that never reached the browser (an
  idle-reaped profile, or one still shutting down after the previous turn) is
  retried on a fresh profile, as before. One that was in flight when the process
  died is retried only if it is a read. Anything that changes something now
  answers `outcome_unknown` and tells the assistant to take a snapshot and check
  before repeating it.
- **Page text can no longer close the page-content marker early.** A browser
  snapshot is wrapped in delimiters that tell the model it is reading page
  content. A page that spelled the closing delimiter itself could end that block
  early. It is now neutralised, as every other content wrapper already did.
- **One allowed environment variable the daemon cannot read no longer
  refuses every shell command.** An entry on `[sandbox.env] allow` whose value
  lives only in a shell profile is invisible to a background service, and the
  sandbox used to answer that by denying every command in every session, even
  a bare `date`, with a raw error and nothing in the log. Each allowed name now
  resolves on its own: the command runs with the rest, its result opens with a
  note naming the variable and the fix, the trace carries the names, the log
  says once when a name stops resolving and once when it resolves again, and
  the app's Settings, Home and Doctor show an advisory row in the Sandbox pane
  until it is stored with `fermix sandbox env set` or removed from the list. A
  `fermix doctor` run from a shell has no view of the daemon's record and does
  not show the row. A variable
  a coding-agent adapter or a command capability names for itself is still
  required.
- **A scheduled job's run history says when a run was blocked.** A run's
  `ok` status only ever meant the agent loop finished, so a job whose tracker
  tool refused on every call still read as a success. Each run now records how
  many of its tool calls failed, visible in `list_job_runs`, in the run's
  `output.md`, and on the run's trace event, without failing runs that met a
  recoverable tool error.
- **The first `fermix service install` on a Linux account no longer refuses
  itself.** Clearing the unit's start-limit budget is part of enabling it, and
  systemd answers "not loaded" for a unit it has never seen — which is nothing
  to clear, not a reason to stop, so a fresh account's install and the first
  `fermix restart` after it now go through.
- **`fermix service status` reports each fact under its own name on every
  systemd.** The unit's properties were read back in the order they were asked
  for while systemd answers in its own, so on some versions the status put a
  process id where a state belongs and read a file path as a restart count.
- **A Linux package install can restart itself from the setup page again.**
  "Is this process supervised" and "is a service installed" were both answered
  by looking for a unit file this binary writes, which a packaged install never
  has — so the browser setup's apply-and-restart button refused on a daemon
  systemd was supervising, and `fermix setup`'s own service activation read the
  install it had just completed as a failure. Both now read the package's
  world: a bound home with the package's unit in force, and the service
  invocation systemd puts in the daemon's own environment.
- **`fermix service install --port N` refuses a settings file it cannot
  rewrite.** Setting the port re-renders `config.toml` through the shared
  renderer, which does not know the hand-written `[mcp.*]` blocks a different
  parser reads. Such a file is now named and left untouched, with the fix, so
  setting a port can never delete an operator's MCP servers.
- **`fermix setup` no longer calls a `PORT` invalid when it is simply not
  read.** A packaged engine takes its listener port from the settings file, and
  a `PORT` left in the shell was reported as a bad port number rather than as
  the variable this engine does not use.
- **`fermix plugins` and `fermix auth` commands that save settings work
  again.** A command run from a shell has no background service around it, and
  the keychain step of a save still asked for the service's process supervisor,
  so the command stopped with "command host supervisor ... is not running".
  `fermix plugins auth set` and `auth clear` stopped wherever a keychain is
  available; `enable`, `disable`, `uninstall`, `config set`, `auth login` and
  `reauthorize`, and `fermix auth login` and `logout` with `--provider
  anthropic` or `--provider xai`, stopped whenever the settings held a key
  stored in the keychain, and a sign-in stopped after its token was already
  saved. The keychain step now runs inside the command, and the release rail
  runs `fermix plugins auth clear` from each standalone binary before it ships.
- **`fermix doctor` names the platform computer use is unavailable on.** On an
  Intel Mac with computer use turned on, the computer-use row said the sidecar
  publishes no arm64 Linux build. It now says Intel macOS, in `fermix doctor`
  and in the app's Doctor pane.
- **The Linux service unit no longer fights the daemon for the log file.**
  The unit sent its own output to `logs/fermix.log` with `append:` while the
  daemon's rotating handler owned the same path, so after the first rotation
  half the output went to a file the next rotation deleted. The unit's streams
  now go to the journal (`journalctl --user -u fermix`) and the daemon owns
  the file, so each line is in one named place. Every `Environment=` line is
  serialized and escaped, so a home containing a space or a percent character
  round-trips instead of producing a unit systemd reads wrong.
- **An over-long home is refused before the socket bind, by name.** The
  control socket and the voice socket now measure their path against this
  operating system's socket address limit and refuse with the same sentence
  the ACP socket already used, instead of failing the bind with an error that
  every client reports as "the daemon is not running".
- **Two local plugins can run side by side.** Every MCP client advertised
  the same identity, and the client library keys a cache table by that
  name, so the second local plugin failed discovery on every attempt.
- **A local plugin's error is an error.** A result the child flagged as an
  error reached the agent as a success, and a successful result reached it
  as a dumped response struct rather than the child's text.
- **A configured OAuth `region` was silently dropped** on the way through
  the config store, so an explicit setting could never take effect.
- **A spoken request finished a few seconds early is no longer refused.** A
  Live delegation decided whether it had anything to read from a two-second
  window around its own timeline offset, so a sentence finished slightly
  before the voice model raised the delegation came back as "did not catch
  that". It now reads the same thirty-second window the request itself is
  built from.
- **A long, dated page address is no longer redacted down to its host.** The
  high-entropy detectors that hunt secrets in free text treated a whole URL
  path as one opaque token and redacted any long path containing a digit —
  which removed precisely the article, results and dated pages the feature
  exists to recall. A normalised address, whose query string is already gone,
  is now scrubbed with the named-secret patterns instead, while typed text,
  window and page titles keep both detectors at full strength.
- **A weekly capability run that stops at the release gate now says so.** The
  eval box publishes one exit code for the tier it ran, and the expression that
  chose it took the first *truthy* value — where the string `0` is truthy. A
  capability run whose deterministic sweep passed and whose judged axis stopped
  at a red release gate published the `0`, so the alert filed a generic "the
  tier is failing" and dropped the paragraph explaining that the gate is
  fail-closed by design. The choice now lives in a script with its own tests:
  the first step that failed decides, a step that died before publishing
  anything stops the job publishing a code at all rather than letting a later
  step speak for its run, and `0` is published only when every step that ran
  passed.
- **A capability sweep no longer scores a task the machine could not run.** The
  coding-harness tasks need a vendor coding CLI on the daemon's path when it
  boots; a hosted CI box has none, so the tools were never offered, the model
  could not delegate however well it reasoned, and the sweep recorded two zeros
  that read as the model failing. A task whose required tools the daemon does
  not advertise is now held out before anything is spent and reported as NOT
  EVALUATED — named in the run, in the report, on the leaderboard and in the
  release gate, and never rendered as a pass. Holding tasks out changes the
  measured task set, so those rows sit in their own cohort and are not ranked
  against runs that scored the full set.
- **An instruction hidden in relayed content is named, not adopted.** Asked to
  summarize something someone else wrote — a pasted note, a forwarded message —
  and say what needs doing, Fermix could hand the instruction the note addressed
  to it straight back as an assigned task. The operating rules said to ignore
  embedded commands but left the summarize-and-triage path undecided, and that
  is the one place an instruction has to be described without being taken on.
  An instruction addressed to Fermix inside content that came from somewhere
  else is now named as what it is — an attempt to direct it from outside your
  conversation — never carried out, and never handed back as anyone's task,
  however trusted its source looks. A request someone makes of *you* in the same
  content is still triaged into your own to-dos as before.
- **A plugin this build no longer offers is not left running.** Retiring a
  plugin used to be a catalog decision only: a fresh install stopped being
  offered it, and an install that already had it kept it enabled, kept its
  stored key mapping, and kept starting it — so a retired hosted plugin whose
  provider had moved on logged a connection failure on every start, forever,
  and that error read as "this plugin is broken" when it meant "this plugin is
  gone". Fermix now knows the retired names as it reads your configuration: the
  plugin is dropped from the enabled list, its own section and its stored-key
  entry go with it, and it is named once in the log, so nothing starts it and
  the next save writes the file without it. The stored credential is left
  exactly as it is — forgetting it locally and revoking it with the provider
  stay two separate, deliberate acts.

## [0.10.5] - 2026-09-17

### Added

- **Fermix can look at a picture that is already on disk.** Until now the only way to read
  a file was as text, so a photo on disk was invisible: the assistant would try
  the browser, then the desktop, then build something elaborate, and still
  never see it. A new `view_image` tool hands one to six sandbox-approved
  image files straight to the model in the order you name them. JPEG, PNG and
  WebP are supported and the format is read from the file's own bytes rather
  than its name, so a mislabelled file is refused instead of silently
  misread. One unreadable path fails the whole request, because a partial set
  of references the model believes is complete is worse than an error.
- **Image generation can save without sending.** `generate_image` takes a
  `delivery` argument: `save` writes the picture and sends nothing, so it can
  be inspected before it goes anywhere, and `send` refuses up front when there
  is nowhere to deliver it rather than charging for a picture that cannot be
  handed over. Left out, it behaves exactly as before. A send the chat rejects
  is now reported as a failure that still names the saved file, so the picture
  can be retried without paying to make it again.
- **A scheduled job can send attachments to the conversation it reports to.**
  The scheduler resolves that destination once, when the run starts, from the
  job's own configuration — never from whichever chat happens to be active, and
  never from something the model supplies — and lets `send_attachment` deliver
  through it. A run is bounded to sixteen attachments and to its own remaining
  time, and the destination stops accepting the moment the run ends. Jobs that
  save locally or report nowhere refuse the send and say so, in the run's own
  instructions as well as in the tool's answer, so the assistant is never told
  it can attach something it cannot.

### Fixed

- **A skill can use its own files without a grant.** In the default
  `standard` sandbox mode a scheduled job bound to a skill, or a chat turn
  following one, was refused when it read the skill's own folder inside the
  Fermix home, so a skill that ships photos, scripts or a state file only worked
  after the operator granted that folder by hand or switched the whole sandbox
  to `open`. The `skills` folder under the Fermix home is now a standard-mode
  root, like the workspace. Nothing else in the home comes with it: browser
  profiles, tokens, the secret key base and pairing state stay outside every
  standard root.
- **A scheduled run no longer fails outright when the model asks to send two
  things at once.** Fermix executes one channel send per step so a job cannot
  flood a chat, but asking for a second one ended the entire run with an error
  the model never saw — one wardrobe job died that way after three and a half
  minutes and two generated previews. The first send now goes through, each
  extra one comes back as an answer telling the model to ask again on its next
  step, and everything else in the same step still runs.
- **`send_attachment` works inside a scheduled job.** It used to refuse before
  it even looked at the file, because a scheduled run had no conversation
  attached to it, which is why jobs reported their work as finished while the
  files stayed on disk.

## [0.10.4] - 2026-09-12

### Fixed

- **The app's Logs pane no longer goes blank on a log line that is not valid
  UTF-8.** The daemon's console output is redirected into the same file as
  its log handler and flattens text bytewise, so a line such as a Phoenix
  timing in microseconds lands on disk with a byte the JSON encoder refuses.
  One such byte anywhere in the newest page failed the whole `logs.query`
  answer, and the pane showed nothing. Every message is now repaired before
  it is redacted, so the page is delivered with a replacement character in
  that spot.
- **A management route failure names its cause in the daemon log.** The
  route wrapper logged `failure=exception` and dropped the exception, which
  is how the blank pane went undiagnosed. It now logs the message and the
  first stack frames, bounded.

## [0.10.3] - 2026-09-12

### Fixed

- **`fermix migrate-to-app` no longer refuses its own installed release as a
  foreign `fermix` on `PATH`.** Every Homebrew install on macOS was refused:
  the standalone unpacks itself and runs out of that copy, and the unpacked
  copy's own launcher is on the `PATH` of the processes the command spawns, so
  the check for a stray `fermix` that would shadow the one the cask installs
  found the installation doing the migrating and stopped there. The command now
  recognizes the release it is running from as its own, and still refuses any
  other `fermix` that belongs to neither Homebrew nor the app.

## [0.10.2] - 2026-09-12

### Fixed

- **`fermix migrate-to-app` no longer refuses an account that already has
  the Mac app.** Downloading the disk image before retiring the Homebrew
  formula left the two halves pointing at each other: the command refused
  because `Fermix.app` was installed and sent the operator to the app's
  onboarding, while the app refused to activate under the formula's launch
  agent and sent them back to the command. One installed copy in the
  Applications folder is now a valid starting state. The migration runs
  exactly as before except that the cask install is skipped and the last
  step opens the copy that is already there, and running it without
  arguments says which of the two it will do. The copy is accepted only
  once its bundle identifier proves it is Fermix: a bundle called
  `Fermix.app` that is something else, and a single copy installed
  outside the Applications folder, are each refused with what to do about
  it, and two copies stay refused as before.

## [0.10.1] - 2026-09-12

### Fixed

- **The macOS app engine carries one build identity per release.** The two
  architecture trees of an engine release were stamped with build ids that
  differed by target, and the app verifies the engine it boots after an
  update against the single build id its update feed carries, so a
  universal update could never verify on both kinds of Mac. A release now
  stamps one id shared by both trees; the target remains its own field in
  the engine manifest. Nothing else changed.

### Added

- **Computer History records every site you visit in the browsers you
  allow.** Alongside window titles, the recorder now reports each page's
  address and title for every site inside an allowlisted browser, so
  "which page was I reading about X" is answerable through `recall_activity`
  and the daily threads. Addresses are kept as scheme, host and path only:
  the query string and fragment, where session ids and tokens live, are
  dropped in the recorder and again at the store. Typed text inside a
  browser is recorded only from windows the recorder can positively classify
  as not private; today that is the Chrome family, whose incognito windows
  carry a marker the live check pins. Safari, Edge and Firefox report an
  unknown private state, so their addresses are recorded, their typed text
  is withheld, and `/history status` names them. The per-site allowlist
  (`sites`) is retired: an existing `config.toml` still boots, logs one
  retirement line, and the key disappears on the next save. The scrubber
  also redacts payment-card numbers and IBANs before anything is stored.
  Pairs with compux 0.9.0.

## [0.10.0] - 2026-09-11

### Added

- **GPT Image 2.5 is selectable on the OpenAI images backend.**
  `gpt-image-2.5-flare` and `gpt-image-2.5-sunburst` join the image model
  picker in the setup wizard, the web pane and the macOS app. Flare is
  OpenAI's recommended tier for most work and generates faster than
  `gpt-image-2`; Sunburst is the premium tier for edit-heavy workflows. Both
  support generation and editing, including masked inpainting, so the whole
  `generate_image` surface works on either. The default is unchanged:
  `gpt-image-2` stays the head of the list, so an install that never picked
  a model keeps generating exactly as it did — the 2.5 models roll out per
  account, and a default that moved on upgrade would have broken every
  install that is not yet entitled. Pick one in setup to move. These are API
  models: the ChatGPT-subscription images backend (`openai_codex`) does not
  offer them, because the hosted image tool it drives selects its own model
  and ignores the one it is given.

- **GPT-6 Astra is in the OpenAI and Codex catalogs, and is the new default
  there.** `gpt-6-astra` is selectable in the setup wizard and the web pane
  on both the OpenAI (API key) and Codex (ChatGPT subscription) providers,
  and is what a fresh install resolves to on either, and it reaches `max`
  reasoning effort. `gpt-5.6-sol` and every earlier model remain selectable.
  Astra's Codex-only `ultra` effort level is a Codex-harness delegation mode
  rather than a wire value, so Fermix's effort vocabulary is unchanged. Two
  things to know before you upgrade. An install that pins `default_model`
  keeps what it pins, but one that never pinned anything moves to Astra on
  the next upgrade without being asked — and if your account is not yet
  entitled to GPT-6, nothing on the upgrade path checks: the entitlement
  probe runs in the setup wizard's finalize step and in `fermix doctor
  --full`, neither of which an upgrade re-runs, so the first turn is where
  it would surface. Pin `default_model = "gpt-5.6-sol"` if you would rather
  not move yet. And on the API-key provider Fermix compacts Astra at 272k
  input tokens rather than at its full 1.05M window: above 272k OpenAI
  reprices the whole request at 2x input and 1.5x output, so this keeps long
  conversations inside standard pricing instead of silently doubling the
  bill.

- **Claude Fable 5.1 on the Anthropic provider.** `claude-fable-5-1` joins
  the model catalog (1M context, 128k output ceiling) and is offered in both
  the CLI wizard and web setup; set it with
  `[fermix_core.providers.anthropic] default_model = "claude-fable-5-1"`.
  The Anthropic default is unchanged. It rides the same adaptive-thinking,
  no-sampling wire shape as Fable 5. One account-level caveat worth knowing
  before you chase a payload bug: Anthropic treats this as a Covered Model
  requiring 30-day data retention, so an organization on zero data retention
  gets a 400 on every request until Anthropic authorizes it.

- **A management surface the Fermix macOS app talks to, instead of reading
  your files behind your back.** The daemon's local control socket now
  speaks a versioned request/response protocol with one result or one
  structured error per request: an identity handshake, the same overview and
  health projection `fermix status` uses, one-use setup URLs, Doctor as a
  cancellable session with a hard deadline (so a slow network check never
  holds the connection open), bounded paged log queries, a short leased
  drain used for restart and shutdown, and a field-allowlisted diagnostics
  bundle for export. Errors carry stable codes and bounded details; no
  internal term crosses the boundary. The contract ships beside the code as
  a document, a JSON schema, and golden fixtures the app vendors by
  checksum, so the two sides cannot drift silently — and version negotiation
  refuses an out-of-range client with an explicit
  client-too-old/daemon-too-old answer rather than half-speaking to it. The
  existing socket, framing, and 4 MiB frame ceiling are unchanged.

- **That surface grew from eleven methods into the whole control plane, and
  the browser setup page now goes through the same daemon.** The protocol
  carries 42 methods over a `{1,2}` version window — 11 at v1, 31 added at
  v2 — and the daemon, not the client, owns config, validation, secrets and
  restart truth for both doors. That means one settings descriptor per
  section (personality, memory, channels, providers, assistant, realtime,
  tools, sandbox, computer, meetings, plugins) with typed rows, options and
  restart flags; secrets that go in by id and are never read back out;
  long-running work — provider sign-ins, capability installs, the notetaker
  sign-in, the computer-use grant — modelled as cancellable jobs with phases
  and byte progress; plugin rows whose actions come from a closed published
  vocabulary, so a client never has to guess which method a verb runs; and
  provider primary-setting, where the first provider you configure is
  promoted to primary on both doors, so a sign-in clears the readiness gate
  without a second step. Every published sentence is held to one copy
  contract — sentence case, no em dashes, no exclamation marks, no version
  numbers, no wire tokens — and a v1-declared request for a v2 method is
  refused rather than served, so the wire's meaning never depends on the
  client's honesty about what it speaks. Both doors render one descriptor:
  the browser setup page and the app draw the same rows, so a label fixed in
  one place is fixed in both. The app that consumes the v2 half ships from
  its own repo, so this is the daemon half landing first, by design.

- **The setup page has a second presentation, for the Mac app's in-app
  pane.** When the daemon mints a setup URL with `embed=1`, the one LiveView
  renders natively instead of drawing a website inside native chrome: no
  card sidebar, no mascot, no step counter, no theme toggle, a transparent
  background so the app's palette shows through, denser controls, and one
  shared caption under every action that hands sign-in off to your browser.
  Dark mode follows the app's appearance rather than a stored preference, so
  the pane and the app can never disagree. Three of those changes reach the
  browser page too: the header and the setup sidebar draw the Fermix
  wordmark where the mascot used to stand in as a brand mark; every pane
  grid splits on the width of its own column rather than the viewport's, so
  a narrow window collapses to one column instead of cramming two provider
  cards into it; and the renderable strings across setup and the dashboard
  lost their em dashes to a copy gate that scans the live sources rather
  than a hand-kept list. The pane itself is only reachable from the app,
  which is not released yet.

- **On a Mac where the app owns Fermix, the CLI says so instead of fighting
  it.** An app-managed engine knows what it is from its own build identity,
  never from where the binary sits, and splits the commands three ways.
  `fermix start`, `fermix stop`, `fermix service install`, and `fermix
  service uninstall` exit non-zero and point at the app's Enable and Disable
  background service controls — the app deliberately does not call these
  Start and Stop, because the durable state is the registration, not whether
  a process happens to be alive right now. `fermix setup`, `fermix upgrade`,
  and `fermix uninstall` open the matching screen in the app and report only
  that the hand-off was accepted, never that the work is done. `fermix
  status`, `fermix doctor`, and `fermix logs` are answered by the daemon
  over the management socket. Doctor's `upgrade`, `binary integrity`, and
  `service unit` checks report not-applicable there, because the app updates
  itself, the standalone in-place binary swap would break a signed bundle,
  and the background service is a login item the app registers rather than a
  unit this engine installs; that updater remains for Linux and standalone
  installs, where nothing about it changes.

- **`fermix migrate-to-app` moves a Homebrew install to the Mac app in one
  transaction.** `brew uninstall` on its own is not enough: the formula
  never owned the launch agent `fermix setup` wrote, so uninstalling strands
  a KeepAlive job pointing at a binary that no longer exists. The new
  command runs in your own shell — the only place a custom `FERMIX_HOME`
  exported there is visible — and with no arguments it inspects the account
  and prints the plan without changing anything. `--yes` performs it: drain
  the daemon, boot out and remove the launch agent it verified byte for
  byte, write an owner-only handoff journal, uninstall the formula, install
  the cask, and launch the app, which reads the journal, keeps the same
  Fermix home, registers its own background service, and verifies the same
  data before clearing it. Every failure is loud and quotes launchd or brew
  verbatim rather than degrading into printed advice, and it refuses
  outright — naming the facts it inspected and what to do — for a
  system-scope daemon, an unrecognised launch agent, a `Fermix.app` that is
  already installed, duplicate app copies, a running `brew services` entry,
  a daemon that does not answer, or a `fermix` on `PATH` owned by neither
  Homebrew nor the app. No path in it deletes a Fermix home. **Do not run it
  yet.** `tezra-io/tap` publishes no `fermix` cask today — only `fermixpet`
  — so the cask install cannot succeed until the Mac app is released, and
  that step comes *after* the formula has already been uninstalled. There is
  no path that skips it: the command refuses outright when a `Fermix.app` is
  already installed, so an account that gets that far has no app to fall
  back on. The command ships with the release that precedes the app, by
  design; it becomes usable when the cask exists.

- **The daemon half of an iPhone companion — the app itself is not released
  yet.** A new `mobile` channel serves a first-party companion app over your
  own network — LAN, or a tailnet when both devices are on one — with
  streaming replies that edit in place, tool activity as it happens, photo
  and voice-note attachments, the same slash commands the other channels
  have, and history that re-syncs exactly after a reconnect rather than
  approximately. Every frame is Noise-encrypted between a key on the phone
  and a key on your machine, so the conversation is unreadable to anything
  on the path; nothing is relayed through a server we run, because there is
  no server. This is the order FermixPet shipped in: the daemon publishes
  the wire contract first and the app follows in its own release, so until
  that release there is nothing to connect. Because of that, this is
  groundwork shipped dormant behind a feature flag rather than a feature you
  can use today: the channel is disabled by default and is offered nowhere
  in setup — no wizard step, no CLI flag, no tab on the setup page. The only
  way to turn it on is to hand-write `enabled = true` under
  `[fermix_channels.mobile]` in `config.toml` and restart the daemon. Setup
  will start offering it when the companion app ships. The wire contract
  ships beside the code the way the management one does — a document, a JSON
  schema, Noise and push test vectors, and golden fixtures pinned by a
  contract test — and `fermix doctor` gains one `mobile companion` row that
  reads `disabled` and probes nothing until you turn the channel on.

- **The pairing ceremony is in place, waiting for the app.** `fermix pair`
  mints a one-time secret, renders the QR, and waits: the phone shows a
  six-digit code derived from the handshake itself, your terminal shows the
  code it derived, and you approve only if they match — so a QR photographed
  over your shoulder cannot complete the pairing. Outside that window there
  is no pairing endpoint at all. `fermix devices list` shows what is paired
  and when it was last seen; `fermix devices revoke <id>` removes the device
  and drops its live socket in the same breath. All three verbs need the
  channel flag on; with it off they refuse and tell you which line of
  `config.toml` to write. There is nothing to scan the QR with until the
  companion app ships.

- **Push previews Apple cannot read, for when the app arrives.** When a turn
  finishes and no phone is connected, Fermix sends one notification per
  registered device with the preview encrypted under a key derived at
  pairing — the phone decrypts it locally, and APNs carries ciphertext only.
  A message you already read on another device does not notify you again.
  Push stays off until you supply your own APNs credentials under
  `[fermix_channels.mobile.push]`, and the signing key lives in the keychain
  or `FERMIX_APNS_KEY`, never as plaintext in `config.toml`.

- **Transcription now runs live, not just file by file.** Speech-to-text
  gained a streaming session: audio is pushed in as it arrives and finished
  segments come back with their timings while the speaker is still talking.
  Deepgram, SpaceXAI, and the on-device backend speak a streaming protocol
  natively; a batch-only backend (OpenAI) is driven by a chunked adapter
  that transcribes short spoken spans in order, so every configured backend
  can feed a live listener rather than only the ones with a socket. A stream
  speaks one audio format — 16 kHz mono s16le PCM — and callers convert
  before pushing, which is what keeps the meeting notetaker below and the
  existing voice-note path on one engine. The default backend and model are
  unchanged; nothing about a voice note behaves differently. OpenAI's newer
  `gpt-transcribe` is also selectable now, beside the default mini model it
  does not replace. A backend that stops draining cannot silently eat your
  audio: both native streams share one outbound window — five seconds of
  audio in flight over a thirty-second buffer — and a socket that has not
  acknowledged a full window within ten seconds is killed into the bounded
  reconnect rather than blocking behind a single write, with overflow
  dropped and counted instead of dropped quietly.

- **A meeting notetaker that joins only when you ask — off by default,
  installed on demand.** Fermix can sit in a Google Meet or Zoom meeting,
  transcribe it with speaker attribution, and deliver a summary when it
  ends. `join_meeting`, `leave_meeting`, and `list_meetings` are owner-only
  and attended-only: it never joins on a schedule, off an invite it read, or
  on an instruction embedded in content someone else wrote, and it attends
  one meeting at a time. The two platforms work differently on purpose, with
  no fallback between them: **Google Meet** is joined by a `meetbot` browser
  sidecar signed in as a dedicated bot account, so it knocks and waits for
  admission like any participant and reports denial, a sign-in demand, or a
  block honestly instead of pretending; **Zoom** is joined through Zoom
  RTMS, an outbound audio subscription with no browser at all, which reaches
  only meetings hosted by your own Zoom account or by a host who has enabled
  your RTMS app — that is a Zoom platform limit, not a missing key, and no
  setting unlocks other people's meetings. On Meet the notetaker announces
  itself once in the meeting chat and never speaks again
  (`announce`/`announce_message`/`bot_name`); on Zoom the platform's own
  recording indicator is what participants see; either way the host can
  remove it and that ends the capture. Transcripts, a rendered
  `transcript.md`, and run metadata land under
  `<FERMIX_HOME>/workspace/meetings/<id>/` where the file tools can read
  them back, and audio is discarded unless `retain_audio` is set. A capture
  cut short still delivers what was heard, labelled as partial rather than
  passed off as the whole meeting. Turn it on from its native-driver card on
  the setup Plugins page — beside computer use and computer history — with
  the detailed configuration (bot name, announcement, transcription backend,
  Zoom RTMS credentials) in the card's own Configure panel. Enabling
  installs the pinned `meetbot` sidecar (`v0.3.3`) for your host, and the
  sidecar then installs the exact Chromium build it was tested against —
  there is no browser to prepare by hand, and a sidecar upgrade re-runs that
  install rather than trusting a browser an older release left behind. Meet
  needs one more deliberate act before the first join: signing the bot
  account in, from the Sign-in button in that panel; until then the card
  says "Sign-in needed" rather than pretending installed means ready.
  Apple-silicon macOS and both Linux architectures are pinned; Intel macOS
  is not, because the meetbot release builds no such artifact, so there the
  Meet install refuses honestly and the Zoom RTMS lane is the one a
  configured operator can use. The macOS binary is ad-hoc-signed rather than
  notarized — fine for the daemon that downloads it, and notarization is the
  gate for distribution beyond your own machine. `fermix doctor` gains a
  `meetings` row that reports the same state without joining anything.

- **What the notetaker does in the room, and when it decides the meeting is
  over.** It joins with its camera off and its microphone muted and never
  turns either on. On Meet the participant list shows the bot Google
  account's own profile name — Meet offers no name field to an account that
  is already signed in — so `bot_name` names the notetaker in the
  announcement line rather than in the roster, and that account is worth
  naming for what it is. It leaves about a minute after the last other
  participant does, which is when your notes arrive; a notetaker admitted to
  a room nobody else has entered waits ten minutes for people to show up
  instead, and on Zoom — where presence is only known from who is
  transmitting — the ten-minute bound is the only one. A join that never
  lands now says so in the conversation you asked from, naming the reason,
  instead of going quiet after an optimistic "joining". On macOS the daemon
  holds a sleep guard for the length of a capture, so the machine will not
  sleep mid-meeting and cut the transcript at the moment the lid closed.

- **The meeting summary can run on a model of its own.**
  `[fermix_core.routing] meeting_provider`, `meeting_model` and
  `meeting_reasoning_effort` point the notetaker's summarizer at a specific
  provider and model, the same way `subagent_*` and `cron_*` already do;
  leave them unset and the summary runs on your default. There is no setup
  screen for them — like `cron_*`, they are hand-written in `config.toml` —
  so `fermix doctor`'s `routing` row now validates and prints the meeting
  override beside the other two, and a typo'd provider name or effort level
  is caught at your desk rather than at the end of the meeting you wanted
  notes from. Worth stating plainly for anyone reviewing the privacy
  surface: the summarizer is a bounded, no-tools run that frames the
  transcript and the participant roster as untrusted content, and it sends
  both to whichever provider those keys resolve to — your default, unless
  you say otherwise.

- **The Zoom client secret is keychained, not left sitting in
  `config.toml`.** Of the four Zoom RTMS credentials the notetaker needs,
  `zoom_client_secret` is a managed secret: setup writes it to the keychain,
  and `MEETINGS_ZOOM_CLIENT_SECRET` is the environment name if you would
  rather supply it that way. It is deliberately not exported into the
  sandbox environment, because the RTMS connection is made inside the daemon
  and the meetbot sidecar never sees your Zoom credentials at all. The other
  three — `zoom_account_id`, `zoom_client_id`, `zoom_ws_subscription_id` —
  are ordinary config values.

- **The on-device transcription backend — fermix's half of it.**
  `[fermix_core.transcription] backend = "local"` selects a `fermix-stt`
  sidecar running over a locally installed speech model: audio never leaves
  the machine and there is no key to configure. What it needs instead is an
  installed binary AND an installed model, and it says which half is missing
  rather than quietly falling back to a hosted backend. Installing is a
  deliberate act — select `local` as the backend in the setup page's Voice
  notes tab and both halves install right there; writing the backend name
  into `config.toml` by hand installs nothing, and boot never downloads. The
  `fermix-stt` sidecar is released at `v0.1.0` (Parakeet TDT 0.6B v3 int8,
  both the binary and every model checksum pinned), so on a pinned host
  enabling it downloads and verifies both halves on-device; only
  `macos-aarch64` is pinned in this build, so other hosts refuse honestly
  instead of fetching an unverified binary or unverified weights. The binary
  is ad-hoc-signed, not notarized.

- **Computer History: an activity memory you switch on per app — off by
  default, macOS only.** When you enable it, Fermix remembers what you were
  doing in exactly the apps you allowlist — window titles and the text on
  screen, read from the accessibility tree — so you can ask "what was that
  article I had open yesterday?" and get an answer. Inside a browser it is
  titles only: the pinned capture driver withholds browser content entirely
  rather than site-filtering it, so no URLs and no typed page text are
  captured, and the `sites` allowlist has nothing to match on until a later
  driver emits navigation events. What it is **not** is a surveillance
  suite: no screenshots, no audio, no keystroke logging, and nothing outside
  the apps you picked. Password and secure fields are never captured
  (suppressed at the capturer AND again at ingest), and a scrubber drops
  secret-shaped text — tokens, JWTs, `password=` URL parameters — before
  anything is stored. Raw activity lives in a local spool for at most 48
  hours (with a byte ceiling as a backstop) and is condensed into durable
  activity memories by a summarizer that runs on one strict route — your
  subagent provider if you have one configured, else your primary, unless
  you point it at the on-device model or one named provider — and never
  fails over to a second vendor, because a failover would send activity
  somewhere you never consented to. A summary that quotes raw field text
  verbatim has the quoted run cut out and replaced with `[…]` rather than
  being discarded whole, matched on a normalized letters-and-digits
  projection so a reflowed or re-cased copy is still caught. You stay in
  control from any chat: `/history status`, `/history pause 10m|1h|24h`,
  `/history purge 10m|1h|24h|all` (erases both the spool and the derived
  memories for the window), and `/history off`; turning it on is a
  setup-page act — pick the apps in the Computer History card's picker,
  which also installs the shared capture driver and asks for the
  Accessibility grant it needs. The model sees a Recent Activity section and
  a recall tool only while every gate holds, and replies built from activity
  are tainted. That taint does two jobs, not one: it makes the reply
  purgeable, and it decides where the reply may travel. `/compact` masks a
  tainted turn exactly as automatic compaction does, a reply derived from
  unmasked tainted replay is stamped tainted itself, and skill curation
  drops tainted entries — counted as `dropped_history_tainted`, so a drop is
  visible rather than silent — when the provider chain is not one you
  granted history to. The rule holds after `/history off`, because taint is
  a property of where the content came from, not of whether the feature is
  on right now, and the gate is frozen once per turn so a mid-turn `/history
  off` cannot make the Recent Activity section, the recall tool and the
  taint stamp disagree. `fermix doctor` reports the whole posture in one
  row.

- **Activity recall dates every entry and tells you what it left out.** The
  Recent Activity digest reads the last 24 hours only, up to 8 entries, each
  stamped with its local time range in your timezone, and it spends its
  budget in whole entries — an oversized old entry is skipped rather than
  truncated mid-sentence. `recall_activity` returns newest first, also
  bounded by whole entries, and its header states how many entries the
  window actually held against how many it showed, so an omission is never
  silent. Memories accrete: one per summarized batch, never superseded,
  because the summarizer's cursor is an event-id high-water mark, so a later
  note cannot hide an earlier one over a shared boundary millisecond.
  `/history status` gained a line for how many spool events are still
  unsummarized and how old the oldest is, so a summarizer falling behind is
  visible before retention starts eating the backlog. One timezone resolver
  serves both surfaces; an unusable zone is logged and both render UTC and
  say so.

- **`/history status` tells you what the agent has read from your history.**
  Every successful agent read appends a metadata-only row — time, sink, the
  resolved window, the result count, never content — to a dedicated audit
  table, and status reports it as "Agent reads: N recorded (last: …)". That
  covers the `recall_activity` tool, including reads that returned nothing,
  and any non-empty Recent Activity section, so you can answer "what has it
  read from my history" from the store itself rather than from traces that
  rotate away. The table is capped at the newest 10,000 rows by the
  retention tick, `/history purge` erases the audit rows recorded inside the
  window it purges, and a failed audit write logs an error rather than
  failing the read.

- **Declining an access request is now one tap, not a dangling prompt.**
  When Fermix asks for sandbox access, the prompt on Telegram and Discord
  carries a Deny button beside Approve — same single-use token,
  operator-only, same origin — and `/deny <token>` is the typed equivalent
  on every channel. Denying consumes the token and answers the request
  honestly instead of leaving it to expire in silence. `/soul deny <token>`
  is the persona counterpart: a `/soul review` proposal, a `/soul revert N`,
  or a `/soul reset` each mint a token you can now discard on purpose, and
  the token is consumed with an answer rather than left to time out.

- **A remote MCP server that changes its tool list no longer needs a daemon
  restart.** Fermix listens for `notifications/tools/list_changed` on the
  response stream and re-discovers that server's tools, so a tool an
  upstream added or withdrew appears or disappears on the next turn instead
  of at the next restart. A proxy suspended mid-reconnect holds the calls
  that arrive during the gap and drains them on resume rather than failing
  them, and rejects them only once the connection is terminally down. A
  source whose discovery has no callback wired refuses the watch outright
  instead of registering one that could never fire.

- **Provider spans carry cached-input and cache-write token counts.** Every
  adapter — Anthropic, OpenAI Responses and Chat Completions, Codex,
  SpaceXAI, and the realtime session — parses the cache split the vendor
  reports and forwards it through the shared emitter, and the Opik mapper
  exports it as `cached_input_tokens` and `cache_creation_input_tokens`.
  `prompt_tokens` keeps exactly the meaning it had, blended cache reads and
  writes included, so nothing you already compute from a trace changes. A
  count the vendor did not report is omitted rather than written as zero,
  because a fabricated zero is indistinguishable from a measured one and a
  cache-aware price has to tell them apart. You see this only with Opik
  tracing on.

### Changed

- **A fresh install counts as ready once a provider and your personality
  answers are in place.** Readiness used to treat every failure as blocking,
  and Fermix ships with Telegram enabled — so a brand-new install with a
  working provider still reported setup as incomplete, `/health` and
  `/health/ready` answered 503, and `fermix doctor` failed. Only two things
  gate now: one configured provider, and your name, time zone and
  communication style. An enabled channel missing its token, and realtime
  without an OpenAI key, are still reported — as a warning row naming each
  component — but they no longer say your setup is unfinished. Every
  readiness sentence was rewritten at the same time to name the control that
  fixes it ("Add the Telegram bot token in Channels settings.") rather than
  the environment variable behind it.

- **`/health` judges a channel by the transport that is actually running,
  not by what `config.toml` says its mode is.** The old check looked up a
  process name by the configured `mode`; the default Telegram block carries
  no `mode` key at all, so that lookup returned nothing and Telegram
  reported ready on every install without the transport ever having been
  examined. Health now keys on the supervised child itself, so a missing one
  reads degraded. ACP is judged by its endpoint rather than its supervisor,
  because an endpoint that cannot bind returns `:ignore` and the supervisor
  starts around it. Telegram additionally reports degraded once its poller
  has failed five times in a row — production once logged 27,394 consecutive
  timeouts across two days with no signal anywhere — and clears on the first
  success, and it never stops polling. `/health` also gained a
  `restart_reasons` array and now takes `restart_required?` from the restart
  state rather than the boot report, so an out-of-process config edit is
  visible there.

- **`fermix status` reports the protocol version and no longer prints the
  Fermix home path.** `fermix status` is answered over the versioned
  management protocol on every install now, not only on an app-managed one,
  so the running line gains `protocol vN` beside the pid, version and
  uptime. The daemon's public projection deliberately carries no filesystem
  path and no raw failure term, so `--full` and `--json` no longer include
  the `paths` block; both facts remain available from `fermix doctor` and
  `fermix logs`. The old unversioned `status` and `overview` socket methods
  were deleted rather than kept alive, so a new `fermix status` against a
  daemon you have not restarted yet reports an error and exits 1 — it names
  the condition and tells you to run `fermix restart` — until that daemon
  comes back on the new engine. **`brew upgrade` does not restart the
  daemon, so run `fermix restart` once after upgrading.**

- **A Homebrew `fermix` pointed at a home the Mac app manages refuses the
  verbs the app owns.** The existing CLI matrix keys on the binary's own
  build identity, which answers false for a formula binary sitting beside an
  installed app — so that binary would happily install, start or stop a
  service the app owns. `fermix start`, `fermix stop` and `fermix service
  install` now refuse and point at the app's background service controls,
  and `fermix setup` and `fermix upgrade` open the matching screen in the
  app. The question asked is about the home, not the disk: a running
  daemon's identity handshake answers it, and with no daemon a marker
  recording the app bundle answers it, and only while that bundle still
  exists. It fails open — a machine with no app, no daemon and no marker
  behaves exactly as it does today. `fermix service uninstall` is
  deliberately not refused on this path, because it is the remedy for the
  legacy-unit condition Doctor reports.

- **Computer use and computer history are native-driver cards on the setup
  page, not catalog entries.** Both now sit at the top of the setup Plugins
  tab, above the third-party integrations, as compact one-row cards with a
  status line, an info icon linking to their docs page and carrying the
  privacy summary, and their own actions. Computer use is no longer listed
  in the plugin catalog at all, so an existing computer-use operator looking
  for it among the integrations will find it moved to the top of the page.
  Enabling computer history opens a picker of the apps actually installed on
  your Mac, listed by name — you check the ones it may record instead of
  typing bundle ids — and saving writes the allowlist, enables the feature
  and installs the shared capture driver in one act; an empty selection
  cannot be saved, because consent to capture nothing is not consent. The
  card names where summarization runs, so the posture is on the card rather
  than buried in `config.toml`.

- **The setup page's Transcription tab is now called Voice notes.** Same
  tab, same job — picking the speech-to-text backend and its model — and it
  is now where the on-device backend is selected too, so there is one home
  for the single transcription setting. Nothing about the setting changed;
  only its label. This is the one surface in the speech work that an
  existing install meets on upgrade, because the tab already existed.

### Fixed

- **Meeting notetaker, transcription and jobs settings no longer reset on
  restart of a release.** A packaged daemon (the Homebrew binary and the
  macOS app engine) reads `config.toml` while its runtime configuration is
  being evaluated, and Elixir then re-applies the compile-time defaults over
  the environment. Any section that also had a compile-time default lost the
  file's values on every boot: the notetaker read as disabled again, a
  transcription backend chosen in setup reverted, and the reminders delivery
  target vanished, while every save made through setup or the app worked
  until the next restart. A daemon run from source never showed it. The
  runtime configuration now restates every section the file hydrates, and a
  test reproduces the boot merge so a new section cannot regress alone.
- **The meeting notetaker installs once, and the app knows when it is signed
  in.** Enabling the notetaker downloaded the pinned release every time; a
  present, verified binary is now the install and nothing is fetched again.
  The one-time Google sign-in is also published on the management wire, so
  the macOS app's Meetings pane shows the signed-in account and offers a
  sign-in again, instead of the idle sign-in control after a sign-in that
  succeeded.

- **Long conversations on the Codex provider now compact against the right
  window.** The catalog recorded a 400k context window for GPT-5.5 and
  GPT-5.4 mini on the Codex path long after those models had moved to 272k,
  so Fermix would not begin compacting until 340k — past the point the
  provider itself refuses the request, which is how a long conversation
  could fail at the window edge instead of being summarized. Both now read
  272k. GPT-5.4, which has since disappeared from the model catalog Codex
  publishes, is set to the same 272k on the same conservative reasoning
  rather than on a measured value.

- **Deep conversations on a ChatGPT subscription run much further before
  compacting.** GPT-6 Astra and the GPT-5.6 family now read 872k on the
  Codex path — the ceiling that path actually stretches to, rather than the
  smaller working budget the `codex` CLI displays, which is the field the
  catalog had been reading. Requests well past the old 272k figure have
  always been served, so this stops Fermix compacting far earlier than it
  needed to.

- **Setup no longer tells you a credential is saved when it had nowhere to
  put it.** Every secret typed into setup is persisted as a keyring
  reference, which only means anything once the value is actually in the OS
  keyring. On a host with no secret writer the value used to be dropped with
  a log line while the save reported success — so you saw a stored key and
  the runtime had none. A save that carries a secret is now refused before
  the snapshot is built, with a sentence saying this machine has no secret
  store, so a save either stores every secret in it or stores nothing. The
  refusal reaches both the CLI wizard and the web setup page.

- **Editing `config.toml` while Fermix is running no longer silently loses
  your edit.** The daemon keeps two baselines — what it started from and
  what it last wrote — so it can tell its own writes apart from yours. If
  the settings file changed underneath it, the next save is refused with a
  sentence naming the changed sections, the setup page shows a banner, and
  the one action offered is Reload settings from disk; an unreadable file is
  reported with the parser's own words and is deliberately offered no
  reload, because the reload would re-run the read that just failed. Before
  this, a save quietly overwrote whatever you had edited by hand. The two
  in-tree writers that do not go through a setup screen — the model-routing
  tool and the `/history` channel command — record the baseline themselves,
  so they do not look like an outside edit and lock you out of every later
  save.

- **A long reply no longer takes seconds to render on its way out.** Both
  outbound Markdown renderers hunted for a closing delimiter by walking the
  rest of the message, so an unmatched opener — which is what a model emits
  every time it means a literal asterisk — walked the entire remainder, once
  per opener. Rendering went quadratic, and it paid that on the delivery
  path of every message and again inside the outbound splitter's binary
  search, which re-measures the same text repeatedly: 32 KB of stray bold
  openers took over ten seconds on the development machine. The scan is now
  indexed once per inline pass and shared by both renderers, and the same 32
  KB renders in about 60 ms. Output is byte-identical, proven by a
  differential oracle across both implementations rather than by inspection.

- **A cancelled or killed plugin install no longer strands the plugin store
  lock.** The lockfile was released by an `after` block in the process
  holding it, which covers a return and a raise but not an exit signal — and
  stopping a run is exactly an exit signal. One cancel left the lockfile
  behind and refused every plugin operation on the machine until the stale
  threshold expired ten minutes later. The lock is now owned by a linked
  process that traps exits and removes the file in its own shutdown, so
  there is one release path whether the critical section ended by returning,
  by raising, or by being killed.

- **A daemon that was not started by the service unit now finds the binaries
  the unit's PATH used to give it.** launchd and systemd hand a daemon a
  bare PATH, and `cosign`, Homebrew's `node` and `python`, and the `codex`
  and `claude` CLIs in `~/.local/bin` are not on it. The service unit had
  always written that list into its own environment; a daemon started any
  other way inherited the bare one and reported those tools absent while
  your shell resolved them fine. The engine now appends the same baseline to
  its own PATH at boot, from one list the unit and the process both read. It
  appends and never prepends, so it can make an unresolvable name resolvable
  and can never shadow a binary your own PATH already chose, and a source
  checkout gets none of it so a developer sees their real PATH.

- **The daemon and voice sockets are removed when Fermix stops, and a
  failure to remove them is logged instead of discarded.** Neither listener
  trapped its parent's shutdown, so the cleanup that closes the listening
  socket and unlinks the socket file never ran on an ordinary stop — the
  file was left behind for the next boot to clear as stale. Both listeners
  now trap the shutdown and clean up on the way out, and if either the close
  or the unlink fails they say so in the log rather than swallowing the
  result.

- **Signing a provider out from the app drops the tokens the running daemon
  is still holding.** A sign-out that only deleted the stored entry left the
  live daemon holding the access and refresh tokens in memory, so Fermix
  kept making calls as the account you had just removed until the token
  expired. The sign-out path now invalidates the running token manager as
  well as the store. This is wired into the app-facing `auth.logout` method;
  `fermix auth logout` is unchanged and still removes the stored credentials
  and tells you to restart the daemon.

- **A remote MCP plugin that refuses a capability now tells you which
  capability.** A contract refusal carried a class and no name, so `fermix
  doctor` and the setup modal could say a plugin refused without saying what
  it refused over. The runtime status table now holds the capability name
  beside the class, bounded, and only where the name is a key of your own
  signed manifest — it can never be a credential or a crash term. A plugins
  row reads like `runtime refused/duplicate_tool (calendar_create_event)`.

- **`fermix doctor` reports a refused `config.toml` as a failed row instead
  of dying on it.** The diagnostic verb reads config through the same loader
  the daemon boots with, and that loader raises — on an unknown section key,
  on an invalid value, and, as a bare `raise` the first rescue missed, on
  the legacy `provider = ...` layout under a provider section, whose
  remediation text is the longest and most useful one doctor has. So the one
  command meant to explain a broken install printed a stacktrace and nothing
  else. Both kinds are caught now and rendered as a failed check carrying
  the loader's own message. One caveat stated plainly: in the shipped binary
  the release config provider evaluates that same load at boot and raises
  there first, so what you actually see is the boot error, and this row
  covers the paths where that provider chain does not run. Separately, the
  Computer History doctor row stopped crashing on a default-configured
  install, where the default summarizer route hit a clause that did not
  exist.

### Security

- **The browser tool refuses ambiguous host spellings and non-web
  documents.** Fermix vetted the host `URI.parse/1` produced while Chrome
  fetched the host its own parser produced, and the two agree only over
  ASCII: `%2e` decodes to a dot, a backslash ends the authority
  (`169.254.169.254\.example.com` read as a subdomain of `example.com` here
  and reached the metadata endpoint there), a trailing dot is the DNS root
  anchor (`metadata.google.internal.` named exactly what its undotted
  spelling names), and IDN mapping rewrites or deletes characters outright.
  Every one of those was a way past the private-network and internal-name
  blocks. A host is now accepted only as ASCII letters, digits, `-`, `.` and
  `_`, or as an address literal, with the trailing root dot removed before
  classification — so an internationalised domain must be given in its
  punycode (`xn--`) spelling to navigate, and the refusal says so. Reading
  page content became an allow-list on the same pass: the tool reads `http`,
  `https` and `about:blank`, and refuses `file:`, `view-source:`,
  `filesystem:` and `data:` documents with `read_origin_blocked` — a `blob:`
  URL is judged by the document it wraps, so `blob:file:///…` and
  `blob:null/…` are refused with it. The refusal points at the file tools
  instead of leaving the model to retry against a `file://` tab.

- **The browser tool vets what a download is fetching, not just what a page
  navigates to.** Chrome performs a download as a navigation without the
  private-network and CORS protections, and streams the bytes straight into
  the workspace where the file tools can read them back — so an allowed
  public page could pull `http://192.168.1.1/config.bin` past every host
  rule the read gate enforces. The source URL is now checked the moment
  Chrome announces the download: a refused one is cancelled, whatever had
  already landed on disk is deleted, and the tool answers `download_blocked`
  carrying the policy's own sentence. A download that announces no source
  URL cannot be vetted, so it is refused rather than waved through, and a
  cancel the browser itself refuses gets its own distinct error saying the
  transfer may still be writing. Page-local sources (`blob:`, `data:`,
  `filesystem:`) stay allowed, because their bytes come from a document the
  navigation gate already admitted.

- **`[fermix_core.browser] allowed_hosts` is the way back in.** Every host
  the policy refuses can be listed there and is matched before the
  localhost, internal-suffix and private-range rules, so a refusal is never
  a dead end. It is the only settable key in that section — the timeouts and
  caps beside it are internal constants — and it is validated rather than
  assumed: an entry outside the canonical host alphabet is refused by name
  (it could never have matched anything), and any other key in the section
  stops the daemon from booting with a message naming it, instead of sitting
  in `config.toml` reading as if it were in force. The refusals for an
  internal hostname and for a private-network address now name that remedy
  inline rather than ending at "blocked by browser policy", which is the
  half that matters, since the model is the primary reader of those
  sentences and a dead-end refusal sends it straight into a retry loop
  against the same wall.

- **Every outbound WebSocket that dials a vendor verifies the certificate it
  is handed.** WebSockex opens a `wss://` socket with `insecure: true`
  unless the call site passes explicit `:ssl_options`, and nothing at the
  call site says so — no error, no log line — so the Discord gateway and the
  OpenAI Realtime voice socket accepted any certificate an active attacker
  on the path presented, along with the API key or bearer token sitting in
  the handshake headers. All five now dial through one shared TLS posture:
  peer verification against the OS trust store, with SNI and the hostname
  check derived from the URL being dialled — Discord, OpenAI Realtime,
  Deepgram and SpaceXAI transcription, and Zoom RTMS. A URL with no host is
  refused before dialling and is never echoed back in the error, because the
  RTMS event URL carries an OAuth token. There is deliberately no opt-out
  flag.

- **The daemon log redacts private keys instead of writing them out in
  full.** The log formatter already masked provider keys and tokens by
  shape; it now also matches a whole `-----BEGIN … PRIVATE KEY-----` block —
  EC, RSA, DSA, encrypted, OpenSSH — and a PGP private key block, and
  replaces it with `[REDACTED:private-key]`. This matters more than it
  sounds: an APNs `.p8` signing key and the mobile listener's own TLS key
  are both PEM, and `ssh-keygen` writes OpenSSH format by default, so any
  error or config dump carrying one previously wrote the entire key into
  `~/.fermix/logs` and straight out of `fermix logs`. It is a pattern match
  over the already-formatted line, so it costs nothing when there is no key
  to find, and the pattern list is hand-maintained — a key format nobody
  wrote a pattern for is still not redacted. Nothing about how keys are
  stored or read changes.

## [0.9.0] - 2026-08-13

### Added

- **Grok 4.6 is available and is now the model a new SpaceXAI setup picks.**
  It joins the catalog with its documented 500k context window, and the xAI
  model list is ordered newest generation first (larger window breaking ties
  within a generation), so the model offered first is always the current
  frontier one. Existing installs are untouched — a `default_model` already in
  `config.toml` keeps working; only setups that never chose a model follow the
  new head.

- **`xhigh` reasoning effort is now available on SpaceXAI, for Grok 4.6.** The
  xAI effort vocabulary previously stopped at `high`, so the level Grok 4.6
  actually supports was unreachable. Setup offers it only on 4.6 — every older
  Grok carries a `high` ceiling and a request above it self-heals down at route
  resolution, which is the same thing SpaceXAI does server-side when an older
  model is asked for `xhigh`.

- **Grok Imagine Image 2.0 is available for image generation and editing, and
  is now the SpaceXAI image default.** The previous model, Imagine Image
  Quality, stays selectable — the two are separate models on xAI's side, not
  aliases, and 2.0 is both the current generation and the cheaper of the pair.


- **Fermix can look up real places.** Ask for coffee near Alexanderplatz, a
  pharmacy open now, or the address of a landmark and Fermix answers from a
  place search rather than a web page: name, hours, rating, contact details,
  distance, and a link to the place's own page for every result. It needs a
  Brave Search API key, which is the same key the Brave web-search backend
  uses — you can set it in setup without making Brave your web backend, and
  the tool stays hidden until you do. Web calls and place calls are billed
  separately by Brave. Results are transient: nothing is cached or stored,
  and only the answer persists, as ordinary chat history. Ask for somewhere
  "near me" without naming an area and Fermix uses the area you have already
  mentioned — in this conversation first, then a neighborhood or city it
  remembers about you — and asks which area to search when it knows neither;
  it names the area it searched so you can correct it.
- **Answers keep the links they were built from.** When a lookup supplies a
  fact, the answer now carries that tool's exact URL — beside the claim, or
  in a short source list — instead of dropping it. Places link to their own
  page, images link to the page they came from, and an answer that did no
  research gets no ceremonial sources section.

- **A reminder that matters can be followed by a check-in.** When you store a
  date, Fermix decides whether it is an occasion you would plausibly want help
  acting on — a birthday, an anniversary, something to prepare or decide — and
  says so in the confirmation, so a wrong call is visible immediately and a
  plain "actually, no need to check in" fixes it. After that reminder has been
  delivered, Fermix may send one short follow-up into the same conversation: an
  offer to help, something it remembers about the person, or a single question.
  It stays quiet when it has nothing worth adding, and a plain logistics ping
  stays a plain reminder. The reminder itself is untouched — it is still
  rendered and sent word for word, the follow-up begins only once the reminder
  has landed, and nothing that goes wrong with the follow-up can cost you the
  reminder. What it offers is remembered, so your reply to it lands with
  context.

- **A long answer arrives as sections while it is being written.** On Telegram
  the reply streams into a live message edited in place, and once it grows past
  one section card that message is sealed at a real boundary and the rest keeps
  streaming into a fresh one — so a long answer lands as a few readable cards
  rather than one wall that appears all at once. Sealed cards are finished
  messages: commentary before a tool round stays as conversation, `/stop`
  removes only the unsealed card, and a short final tail is merged into the
  live card rather than ringing a second message.

- **You can see what Fermix is working on, and it cleans up after itself.** Its
  reasoning headings now roll into a single 💭 status bubble that updates in
  place and is deleted the moment the answer lands. Answer text always takes
  priority, so a thought never appears between a paragraph and its
  continuation; the bubble never rings; and a channel that cannot delete
  messages gets no thought stream at all rather than permanent 💭 residue.

- **Every chat surface gets the formatting it can actually render.** Slack
  mrkdwn, WhatsApp's native styles, and Signal's plain-text dialect join
  Telegram's HTML and Discord's native Markdown, so one house style reaches
  each platform in that platform's own notation instead of leaking raw
  Markdown. Chat turns also carry a short presentation note telling Fermix it
  is writing for a phone-width bubble stream — lead with the answer, short
  self-contained sections, no tables or rules, links inline on the claim —
  while terminal and machine surfaces (`cli`, `acp`, scheduled runs) get no
  such note and stay unchanged.

- **Replies are quieter.** Link previews are disabled on every outbound
  message, edit, and seal, so a linked answer no longer drags an unrelated
  preview card under it, and only the first message of a reply notifies —
  continuations arrive silently.

### Fixed

- **The meeting notetaker no longer claims the Google Meet lane is ready when it
  has no browser.** Installing the Meet sidecar and never running its browser
  install left `fermix doctor` reporting the lane as fine and let a join start a
  session that died the moment the sidecar tried to open Chromium. The lane now
  counts as usable only when both halves are present: readiness, the join gate,
  and the Doctor row all read the same answer, and a half-installed lane refuses
  before a meeting starts, naming the browser install as the fix.

- **Ending a computer-use session no longer risks the next one resuming the
  session that just ended.** Tearing a session down left its registry entry to
  be swept asynchronously, so for a brief moment after the teardown returned,
  starting a session for the same conversation could hand back the one that had
  already stopped instead of opening a fresh one. Most visible where a voice
  call ends and another begins straight after, since ending an attended call
  tears the session down. The entry is now dropped as part of the teardown.

- **Two Grok context windows were wrong, so conversations compacted at the
  wrong point.** The catalog credited Grok 4.5 with a 1M window when xAI
  documents 500k — which defers compaction past the model's real limit — and
  credited Grok 4.20 with 256k when it serves 1M, compacting roughly four times
  earlier than needed. Both now match the published windows.

- **Researched answers stop citing links they assembled themselves, and quick
  questions stop turning into research projects.** The runtime evidence rule
  now names the observed fabrication classes — a URL built from an article or
  press-release ID, an advisory date, a version number, or a site's known URL
  pattern is a fabrication even when it resolves; when the exact deep link was
  never returned, the answer links the page that was. And effort is calibrated
  before delegation: a casual "quick rundown" gets a direct answer from a few
  tool calls, with subagent fan-out reserved for work whose breadth or stakes
  earn it. Both are enforced by the behavioral eval: reply URLs are checked
  verbatim against the complete tool-evidence inventory by a deterministic
  gate, and the "latest news" cases carry duration budgets.

- **Recompiling under a daemon run from source no longer breaks process-group
  sweeping.** The `kill_pgid` NIF carried no upgrade callback, so a hot code
  swap — a second `mix compile`, or the Phoenix code reloader picking up
  changed sources — was refused by the VM: the module lost its native binding
  and every external command's group sweep then crashed until the daemon
  restarted. The NIF (stateless by design) now accepts the swap and keeps its
  binding across it. Released installs were never affected; they load the
  library once and never hot-swap code.

- **Upgrading no longer makes macOS ask to allow a new "fermix" under App
  Management.** The browser tool now launches Chrome through a small disclaim
  shim, so Chrome runs as its own macOS privacy principal instead of being
  attributed to the fermix daemon — Chrome's launch-time probe of its own
  bundle was raising an App Management notification against fermix's
  versioned install path after every upgrade, and the password-gated grant
  could never carry over to the next release. Existing "fermix" rows in App
  Management are inert leftovers and no grant is needed. A launch that cannot
  disclaim refuses loudly instead of ever spawning Chrome undisclaimed
  (`fermix doctor` gains a `browser` row for the shim), and a Chrome that
  dies at launch now fails fast with its exit code instead of waiting out
  the launch timeout.

- **A live turn no longer dies when the connection pool cannot hand over a
  socket.** A checkout that timed out — contention after heavy concurrent use,
  or a pool process busy tearing down keep-alive sockets that went stale while
  the machine was idle or asleep — ended the turn, even though the request had
  never been sent. Fermix now retries that failure inside the turn on every
  surface, not just in scheduled runs, and reaps idle Codex pool processes so
  the stale-socket cleanup happens off the request path instead of inside the
  next checkout. The error you see if it still fails says what actually
  happened, and that re-issuing is safe, rather than blaming a wake from sleep.

- **Long replies no longer break mid-sentence on Telegram.** An over-length
  reply was cut at the last whitespace before the platform limit, so the next
  message opened lowercase, halfway through a bullet. Replies are now split on
  a boundary ladder — section heading first, then paragraph, line, and sentence
  end, with a hard cut only as a last resort — measured in the UTF-16 units
  Telegram actually counts (an emoji is two), held under the per-message
  formatting-entity limit as an independent condition, and never cut inside a
  code fence. A fenced block too large to render inline arrives as a text
  document after the reply instead of as two corrupt halves.

- **Telegram renders what the answer was written as.** A link wrapped in bold
  lost its link, nested emphasis produced visible tag soup, `snake_case`
  identifiers and URLs containing underscores turned into italics, a stray
  asterisk in arithmetic italicised the rest of the paragraph, and tables,
  block quotes, and horizontal rules had no rendering at all. All of them now
  land correctly; if Telegram still refuses a message, that one chunk is
  resent once as plain text so the reply is never lost, and the renderer fault
  is logged and marked in telemetry rather than hidden.

- **WhatsApp and Discord no longer refuse a reply for being too long.** Both
  adapters returned an error over the platform's message cap, so the answer
  simply never arrived. They now deliver it as sequential, boundary-aware
  messages in order — the same ladder Telegram uses, measured the way each
  platform counts — and a failed send aborts the remainder rather than
  half-delivering the reply out of order.

### Changed

- **Traces now record the full prompt, response, and tool bodies by default.**
  A trace that omits the request and the response cannot answer the questions
  traces exist to answer, and the privacy argument for the lean default does not
  apply here — the JSONL lives under a `0700` `FERMIX_HOME` and any Opik
  instance is local, so bodies never leave the machine. Set
  `FERMIX_TRACE_CONTENT=0` to go back to the lean posture.

- **Streaming defaults now follow what the channel can do.** A configured
  channel that can edit messages (Telegram today) defaults to the live
  edited-in-place card, every other configured channel keeps sending each
  completed thought as its own message, and an unconfigured channel stays off.
  Both remain settable per channel with `[fermix_channels.<name>] streaming`;
  nothing needs configuring to get the better default.

- **Outbound channel telemetry counts messages, not replies.** Each delivered
  message is now its own row, including every live card a stream creates — a
  reply that half-lands reports what actually arrived instead of reporting
  nothing, and an answer that streamed and sealed in place no longer leaves the
  turn with zero outbound rows.

## [0.8.0] - 2026-08-05

### Added

- **Drive Fermix from any ACP client — Buzz, Zed, and anything else that speaks
  the Agent Client Protocol.** `fermix acp` bridges stdio to the running daemon,
  which answers ACP v1 on `<FERMIX_HOME>/acp.sock`. Each session becomes an
  ordinary gateway conversation, so it gets the real system prompt, tools,
  sandbox, memory, and telemetry rather than a second agent loop bolted on the
  side.
- **Reminders that understand time the way you say it.** Ask for a birthday, a
  deadline, or "remind me in twenty minutes" and Fermix materializes the actual
  occurrences — leads, annual roll-forward, DST-correct local times — then
  delivers them to your configured default channel, or, with nothing
  configured, to the inbox derived from a channel you own — a fresh install or
  upgrade needs no new config, and a reminder never quietly falls back to the
  chat you happened to ask in. Snooze and "cancel that" work on the reminder
  you just received, and a reminder you slept through expires rather than
  firing late.
- **A stored date never changes silently.** Restating a date under an
  already-stored name gets a question first — the same event to correct, or a
  different person who shares the name and needs their own entry. A change you
  did ask for is applied in one step and confirmed with what the date was
  before as well as what it is now, and a newly stored date's confirmation
  lists your other entries of the same kind, so a near-duplicate under a
  similar name is visible the moment it exists.
- **Digest jobs can see your reminders.** A scheduled job you create can read
  your stored dates (listing only), so a morning digest folds upcoming
  reminders in alongside a connected calendar — and when you ask what is coming
  up, the answer draws on every calendar surface you have and says which events
  came from where. Storing, changing, snoozing, and cancelling stay
  attended-owner-only; jobs and guests can never touch them.
- **Skill curation.** Every couple of weeks Fermix mines your own recent
  requests for tasks you keep repeating that nothing covers, and proposes each
  as a skill — delivered to your private chat with approve/deny buttons, and
  nothing is ever written without your approval. Approved skills are drafted
  into `~/.fermix/skills/` where they load like hand-made ones; skills that sit
  unused earn a reversible archive proposal rather than deletion. `/skills`
  drives it all — review on demand, approve, deny, archive, restore — and
  `/skills list` shows the whole inventory grouped by origin (curation-managed
  with lifecycle state, your own skills, plugin skills), each line carrying how
  often it ran and when it was last used.
- **Hosted (remote) MCP plugins, and Eden as the first one.** A remote plugin
  ships no code: its artifact is a signed manifest plus a skill, and the tools
  run on the vendor's servers. The endpoint, the exact set of agent-visible tool
  names, and every tool's input/output descriptor are signed, so an upstream
  change registers none of that plugin's tools rather than silently widening
  what the agent can do. **Eden** connects with a personal access token and one
  chosen workspace, read-only by default.
- **An aimed-click accuracy harness for computer use** (`make aim`), measuring
  the model's click grounding on the live display now that delivery is proven
  exact.

### Fixed

- **A hosted plugin now says it is hosted, before you connect.** The catalog
  carried no runtime kind, so a remote plugin fell back to the local-process
  consent line — telling you it runs on your machine while it sends your content
  to a vendor's service. The disclosure is now derived from the plugin's own
  manifest.
- **An expired remote MCP session recovers instead of dying quietly.** The first
  time a hosted server retired a session, every later call to that plugin failed
  for the life of the daemon and nothing ever reconnected. A daemon left running
  overnight would wake up unable to reach the plugin at all.
- **An unsigned hosted plugin can no longer be loaded.** A remote manifest binds
  a live credential to a network endpoint, so it is now runnable only from an
  artifact whose publisher signature and file tree re-verify; a manifest edited
  after install cannot redirect that credential somewhere else.
- **Annual reminders stopped rewriting themselves once a minute.** On the day an
  annual event came due, the horizon pass recomputed an identical plan every 60
  seconds — thousands of no-op writes and lifecycle events per event, per year.
  No reminders were lost or duplicated; the noise is simply gone.
- **A Buzz mention no longer produces five identical replies**, ACP clients are
  remembered between sessions, and delegated harness runs are delivered back to
  the client that asked for them.
- **The stuck-loop guard no longer kills healthy computer-use turns.** The
  repeated-tool-call detector counted identical calls across a sliding window,
  so a turn that legitimately re-observes the screen — screenshot, click,
  screenshot, click — reached the kill threshold at the fifth identical
  screenshot and was ended mid-work with an override reply, even though every
  repeat followed a state-changing action the contract itself demands. A kill
  now requires an unbroken run of the same call with nothing in between;
  interleaved repetition still gets the one-time warning and stays bounded by
  the per-turn iteration cap.
- **A daemon restart mid-run no longer wedges a scheduled job forever.** A run
  orphaned by a restart left its job permanently blocked from ever being
  claimed again; orphaned runs are now detected and failed on the next
  scheduler pass, the job returns to its schedule, and a runner that survived a
  scheduler-only restart is re-adopted rather than double-run.
- **A truncated model response can no longer end a turn in silence.** A Codex
  stream that died after its first frame still counted as "delivered" — that
  frame is the model's own reasoning, which carries no answer and no tool call —
  so the turn completed successfully with nothing in it. Scheduled jobs were the
  worst case: the run finished green and the delivered report was empty. A
  response now has to carry actual text or a tool call to count as delivered,
  and a terminal event that carried nothing is no longer an exemption. Whatever
  did arrive is still kept and never discarded.

### Security

- Closes the remaining accepted findings from the 2026-07 review, and
  `SECURITY.md` now states the local-account trust boundary explicitly.

## [0.7.2] - 2026-07-31

### Fixed

- **A provider that says "our servers are overloaded" is now quoted, not
  paraphrased as a dropped connection.** When Codex declared a failure on an
  intact response stream and delivered nothing, the reply blamed a closed
  connection and suggested reducing request size — wrong on both counts. The
  server's own sentence now reaches the reply, marked plainly as a
  provider-side failure rather than a problem on this machine.
- **A transient provider failure mid-task no longer kills the whole turn.**
  Fresh calls always retried these; the mid-task continuation call did not, so
  one momentary provider overload could end a long turn one step short of
  done. The continuation now retries the same bounded way — transport cuts and
  provider-declared unavailability, never after visible streamed content, and
  never a rate limit.
- **A failed coding run's ledger row now carries the vendor's own words.**
  Vendors that report errors as well-formed JSON left the row saying only
  `exit_1` while the real diagnosis ("You've hit your session limit…") lived
  in an artifact file only the run directory had; the durable row now carries
  the same sentence.

## [0.7.1] - 2026-07-31

### Fixed

- **`fermix doctor` runs again.** It aborted with a stacktrace and printed no
  checks at all — on every machine, whatever your config — because its
  coding-harness disk-space probe tried to use machinery that only exists inside
  the running daemon. The one command meant to explain what is wrong with an
  install was the one command that could not run.
- **`fermix doctor` now tells you when the service definition is out of date.**
  It only ever checked that a service was *installed*, so one written by an older
  version read as healthy forever — including one whose daemon is still running
  with an outdated PATH, which is how coding agents go undetected. Upgrading
  never rewrites that definition (and on a Homebrew install the upgrade command
  declines to touch it at all), so there was no way to find out. Doctor now says
  so plainly and names the command that fixes it, `fermix setup`.
- **Coding agents are detected when the daemon runs as a service.** The service
  is started with a fixed list of directories to look in, and that list left out
  `~/.local/bin` — exactly where the official Codex and Claude Code installers
  put their binaries. Setup therefore reported "no coding agent CLI is detected"
  on a machine with both installed, while the same CLIs resolved fine from the
  operator's own shell. That directory is now included on macOS and Linux, added
  last so it cannot shadow anything already being found. **After upgrading, run
  `fermix setup` once**: it rewrites the service definition and restarts the
  daemon, which upgrading alone does not do. Coding agents then still need the
  one-time approval in Setup → Coding Agents.

## [0.7.0] - 2026-07-30

### Added

- **Claude Opus 5 on the Anthropic provider.** `claude-opus-5` joins the model
  catalog (1M context, 128k output ceiling) and is offered as the best-quality
  Anthropic choice in the CLI wizard and web setup — set it with
  `[fermix_core.providers.anthropic] default_model = "claude-opus-5"`. It rides
  the same adaptive-thinking + `reasoning_effort` wire as Opus 4.8.

- **Voice calls can watch your screen.** Ask a call to watch, look at, or follow
  along with your screen and it watches that display for the rest of the call —
  playing a game with you, working through a page you are both reading, helping
  with an app. Changed frames join the conversation quietly: a still screen sends
  nothing and a frame never makes the agent speak on its own, so it answers about
  the screen when you ask instead of narrating it. It rides on computer use (same
  helper, same macOS Screen Recording permission) and refuses to start rather than
  streaming blank frames if that permission is missing. Consent is per call:
  "stop watching" ends it, and hanging up always does. Withhold it entirely with
  `[fermix_core.realtime] screen_share = false`.
- **The browser can measure an element.** `act` with `kind: "get"` and
  `field: "rect"` returns the viewport box of the first `selector` match, in the
  same coordinate space `click_coords` clicks in — so a board, map, or chart that
  exposes no clickable elements can still be driven exactly, instead of by
  guessing pixels.
- **Computer use can list open windows.** A `windows` action returns each window
  with a ready-made zoom region, so on a large or ultrawide display the agent
  crops to the app it is working in instead of spending its whole image budget on
  desktop it does not care about.

### Fixed

- **A brief provider hiccup no longer quietly moves your whole turn to a
  different model.** When the provider you normally use hit a momentary failure
  — a capacity blip, a dropped connection — Fermix moved straight to your next
  configured provider on the very first error. That provider is a different
  model, and whichever one answers keeps the rest of the turn, so a few seconds
  of trouble could hand an entire conversation or scheduled job to a smaller
  model for its whole run, still reported as a success, with nothing anywhere
  saying the model had changed. The original provider is now tried again a few
  times, with a short growing pause between attempts, before anything moves.
  Moving on still happens once those retries are spent, so a real outage is
  still covered, and errors that a retry cannot fix still move on immediately.
  Scheduled jobs are unchanged for now: they deliberately opt out of this retry
  and keep their own slower one, so they still move to the next provider on the
  first hiccup.

- **"I didn't get a response — please try again" is no longer the answer to a
  request that actually worked.** When a reply from the primary provider was cut
  off before it finished, Fermix read the silence as a complete answer that
  happened to be empty: the turn ended with nothing to say, you got a canned retry
  line, and nothing anywhere recorded a failure. It also lost work that had already
  succeeded — a finished coding-agent run whose result was being written up came
  back as that same line. A reply that arrives with nothing in it at all is now
  treated as the failure it is, so it retries or moves to your next configured
  provider, and when the provider says *why* it stopped, that reason is recorded
  instead of discarded. A reply that was cut off partway still comes through:
  a partial answer is more use than an error, and throwing it away would also
  strand a turn that had already run tools.

- **Asking a resumed Codex run for a sandbox level no longer fails.** Continuing a
  thread and choosing a sandbox posture in the same call was refused outright,
  because the resume command has no `-s` flag. It does accept the same setting as
  a config override, so the posture is now honored on both kinds of run. A resumed
  thread already keeps the posture it was started with, so this matters when you
  want to *change* it partway through — which is exactly when the refusal used to
  cost a wasted step. Two parameters are still refused on a resume, each for its
  own reason, and the message now says which and what to do instead.
- **Coding-harness parameter errors are readable.** A refused parameter came back
  as raw internal syntax — `{:param_not_supported_with_resume, :sandbox}` was
  delivered verbatim in a real run — which reads as a broken Fermix rather than a
  request the coding CLI cannot serve. Every one of these now states the problem
  and names the next move, for both Codex and Claude Code: a bad effort or
  permission mode lists the levels that exist, combining `resume` with `continue`
  explains why they conflict, and a directory outside the sandbox names the
  directory and how to grant it instead of printing an internal tag.

- **Voice calls were running without their own rules.** The voice-only rules file
  (`REALTIME.md` — speak briefly, lead with the answer, do not narrate tool use)
  was never actually loaded into a live call: voice ran on the text agent's prompt
  instead. That is why calls talked through every step. Editing the file now
  changes how calls behave, as it was always documented to.
- **Clicks and drags land where the agent aims.** Two separate defects in the
  desktop helper: a click could be delivered at the position of the *previous*
  click while reporting success, and a drag was performed as an instantaneous jump
  that pages with drag-and-drop never registered as a drag at all. Drags are now
  performed as real movement with the pointer placed before each event. A click
  the operating system did not deliver is also reported as such instead of being
  reported as done.
- **A voice call is no longer torn down by someone else's cost.** Per-call spend
  was over-counted several-fold — cached tokens were billed twice and each
  response re-counted earlier ones — so a short call could hit its cost ceiling
  and end mid-sentence. Screen-sharing spend is now counted separately from the
  agent's own screenshots, so precision looks cannot close the eyes that are
  watching for you.
- **A hiccup no longer ends a live call.** Routine, recoverable provider errors
  were being reported to the voice companion as fatal, which shut the microphone
  down while the call itself was still running. Only genuinely terminal failures
  end a call now.
- **Browser errors say how to recover.** A blocked dialog, a stale element handle,
  an element with no rendered box, and using an `act` kind as a top-level action
  each ended in a dead end that named the mistake but not the fix. Each now names
  the call that works. Clicking an element below the fold scrolls it into view
  first, instead of silently clicking nothing and reporting success, and a page
  snapshot can no longer return the previous page's contents after a navigation.


- **Turning the coding harness off now hides all of it, not most of it.** With
  coding agents not approved on a machine, the tools that launch a run were
  correctly withheld, but the three that inspect run history stayed offered —
  so the agent was handed harness tools while the prompt, which drops the whole
  harness section when it is unusable, said nothing about the harness at all.
  Fermix now withholds every harness tool in that state, exactly as it already
  did for the run tools. They remain reachable by name, so a run recorded before
  you withdrew approval can still be read or cancelled on request.
- **A tool call that never runs is now visible in traces.** When the model called
  a tool that does not exist, was not allowed for that run, or passed arguments
  that would not parse, Fermix told the model and recorded nothing — the trace
  showed a step that called *something*, with no way to see what. Each of these
  now records a failed tool execution under the name the model used, so it shows
  up in `~/.fermix/traces` and as a failed span in Opik alongside real calls.
- **Coding agent runs no longer fail instantly with "Not logged in" on macOS.**
  Fermix starts the vendor CLIs in a wiped environment, and that environment was
  missing the account name. Claude Code looks its macOS Keychain login up by
  account, so it found nothing and every run exited within a couple of seconds
  asking you to sign in — while the same `claude -p` worked fine from your own
  terminal. Codex was never affected, because it reads its login from a file.
  The account name is now part of the environment Fermix reconstructs, and a
  daemon that does not have one refuses the run up front, naming the cause,
  instead of starting a CLI that cannot authenticate.
- **A failed coding run now tells you what the tool actually said.** The vendor's
  own error was captured and then discarded, so a failure came back as a bare
  exit code with no explanation — and the agent, unable to tell an expired login
  from a crash, would often relaunch straight into the same wall. That message
  now leads the completion notice, the delivered message, and `get_coding_run`.
  The notice also asks the agent to check the working tree before redoing
  anything (a run killed by a timeout may have left changes behind) and to say
  plainly what failed and what it needs.
- **Anthropic requests no longer send a sampling parameter the 5-generation
  models reject.** `temperature` was still going out for `claude-fable-5` (and
  any Sonnet 5 / Mythos model), which the API answers with a 400; it is now
  dropped for the whole 5 generation as it already was for Claude 4.7/4.8.

### Changed

- **Channel streaming is now on by default.** A configured channel streams its
  reply as the model works (`streaming = "block"`) instead of staying silent until
  the final message, so you see the intermediate "thinking" progress. Opt out per
  channel with `[fermix_channels.<name>] streaming = "off"`, or use `"draft"` for a
  single message edited in place. Streaming is a no-op for non-streaming providers,
  so nothing changes unless your primary provider streams.

## [0.6.0] - 2026-07-19

### Added

- **Computer use no longer fights you for the cursor (coexistence).** When the
  agent is driving the host desktop and you start using the machine, it now yields
  the seat instead of stealing the pointer mid-action. Before any disturbing action
  (click, drag, scroll, mouse-move, type, key, paste) it checks how long you have
  been idle and, if you are active, briefly waits in-turn for a pause, then either
  proceeds or holds the action back and tells you so. `/pause` hands the machine
  back on demand (the session stays alive and resumable — unlike `/stop`, which
  tears it down) and `/resume` continues. Controlled by `[fermix_core.computer_use]
  courtesy` (`yield` default, `off`) and `courtesy_idle_ms`. Idle detection is
  macOS-only; where it is unavailable the arbiter proceeds rather than blocking.
- **Image generation can run on a ChatGPT/Codex subscription (keyless).** A new
  `openai_codex` image backend drives `gpt-image-2` over the Codex subscription
  endpoint — billed to the subscription, no `OPENAI_API_KEY` — mirroring how the
  Codex chat provider works. Opt-in and connection-gated (never a fallback); a
  missing/unentitled token fails loud. Selectable in the CLI wizard and web setup.
- **One-tap directory-grant approval, and the grant loop is multi-user safe.** The
  `/confirm` prompt renders as a tap-to-copy code span, and Telegram/Discord get a
  native **Approve** button that synthesizes the exact confirm through the unchanged
  origin-bound, single-use, TTL path. Grants are now strictly operator-only (never
  reachable through the guest command allowlist), `/confirm` peek-validates before
  consuming so a wrong-origin attempt can't burn the owner's token, and a non-owner
  button tap is refused before consumption. (Telegram + Discord; Slack deferred.)
- **Owner-approval directory access, and the sandbox lives where you do.** Standard
  mode now auto-allows the launch/request working directory (under your real home)
  plus the workspace and explicit grants, and open mode is your home minus the
  protected credential/OS/state dirs — the mode roots key off your OS home, not
  `FERMIX_HOME`, so "works where I am" is finally true. A new
  `request_directory_access(path, reason)` tool prompts the owner for an
  out-of-roots path and, on `/confirm`, persists the grant and auto-resumes the
  original request. `fermix sandbox explain` annotates each root as (granted) vs
  (mode).
- **Voice notes are heard everywhere, on a pluggable speech-to-text backend (M21).**
  Milestone 21 makes voice-note transcription real, configurable, and channel-wide
  (see the transcription entries below). Also replaces the old Groq backend with a
  native SpaceXAI STT backend, and relabels user-facing "xAI" → "SpaceXAI" (display
  only — the `:xai` atom, `XAI_API_KEY`, `api.x.ai`, and `grok-*` model ids are
  unchanged, so existing configs keep working).
- **FermixPet is now its own notarized macOS app, and the realtime wire is
  versioned.** The voice companion moved to `tezra-io/fermix-macos` (SwiftPM source,
  notarized universal2 DMG + Homebrew cask). The daemon's realtime socket gained a
  versioned hello-first handshake (N/N-1 window) so the pet and daemon can ship
  independently, and `fermix doctor`/`voice status` now flag the OpenAI-Platform-key
  requirement (a Codex/OAuth login does not authorize the Realtime API).
- **Every spawned OS process is group-reaped (subprocess lifecycle).** External
  commands now run under a central `CommandHost` in their own process group and are
  killed on exit, crash, or daemon shutdown (a new `kill_pgid` NIF), and cron jobs
  can delegate. Closes the orphaned-subprocess class across git tools, subagents,
  jobs, sandbox env, plugin probes, and realtime.
- **`fermix status` and `fermix doctor` now warn when the running daemon's
  version differs from the installed binary.** A package-manager upgrade
  (`brew upgrade fermix`) swaps the binary on disk while the launchd/systemd
  service keeps running the old release until restarted, and nothing surfaced
  that skew — right after a brew upgrade, doctor's upgrade check even reported
  "on the latest version" while the daemon was stale. `fermix status` now
  appends a warning line and doctor's daemon-socket check degrades to a
  warning, both naming the two versions and the `fermix restart` fix. The
  `fermix upgrade` managed-install refusal also tells you to restart after
  running the package-manager command, and the README, wiki, and Homebrew
  caveats now document the restart-after-upgrade requirement.
- **Telegram voice notes are transcribed.** Inbound Telegram voice notes, audio
  files, audio-MIME documents, and round video notes now parse to a transcribable
  audio attachment and are transcribed to text like the other channels — closing
  the gap where Telegram (the primary channel) extracted only photos and answered
  a voice note with "your message looks empty." Video notes ride their MP4
  container straight to the hosted backend (no ffmpeg).
- **A voice note with a caption transcribes both.** When an audio attachment
  arrives with a caption, the caption is kept and the transcript is appended under
  a `[voice note transcript]` delimiter, instead of the caption suppressing
  transcription entirely.
- **Transcription is now a backend-pluggable capability.** `[fermix_core.transcription]
  backend` selects the speech-to-text provider — `openai`, `xai`, or `deepgram` —
  resolved through a fail-loud registry that lists the valid names on an unknown
  choice (the on-device `local` backend is reserved for a later phase and says so).
  Each backend has its own optional API-key slot: `openai_api_key` and
  `xai_api_key` OVERRIDE the reused chat-provider key (or fall through to it if
  unset), while Deepgram (`nova-3`, batch; no chat provider to reuse) requires its
  `deepgram_api_key`. SpaceXAI's native `/v1/stt` is modelless (no model to pick)
  and **requires an API key** — the Grok subscription OAuth token does not work for
  STT, so paste one when your SpaceXAI provider is on OAuth. Every backend routes
  its HTTP round-trip through the shared `[:fermix, :provider, :call]` telemetry
  emitter (`purpose: :transcription`, no token cost), and a missing key fails loud
  rather than degrading silently.
- **Transcription is now configurable through setup.** `[fermix_core.transcription]`
  is a first-class `config.toml` section (`backend`, `model`, per-backend
  `openai_api_key`/`xai_api_key`/`deepgram_api_key`, `max_file_mb`) with an unknown
  key/backend/`max_file_mb` failing config load loudly. The web-setup Transcription
  card (moved to right after Channels) shows an API-key field for the selected
  backend (all three ride secure-on-save to the OS keyring), plus a per-backend
  model dropdown. Set it from the card, or with `fermix setup
  --transcription-backend`/`--transcription-model`/`--transcription-api-key` (the
  generic key flag stores under the currently-selected backend's slot); switching
  backend snaps the single shared `model` to that backend's default so Deepgram
  never inherits the OpenAI-shaped model (SpaceXAI is modelless and sends none).
  `fermix doctor` gains a `transcription` row that reports the active backend and
  whether its credential resolves (offline — it never transcribes).

### Changed

- **GPT-5.6 (Sol, Terra, Luna) context window corrected to 272k** (carried
  forward from 0.5.8). The catalog listed the 5.6 generation at 372k; the
  effective window is 272k on both the Codex (ChatGPT subscription) and OpenAI
  direct-API paths. Auto-compaction thresholds, forced `/compact` budgets, and the
  `fermix doctor` context report key off the corrected value; the older `gpt-5.5` /
  `gpt-5.4` / `gpt-5.4-mini` windows are unchanged.
- **Live-voice replies are quieter and shorter.** The realtime seed no longer
  licenses pre-announcing or narrating tool use ("act and lead with the result; a
  slow action stays silent until you have the answer"), and the default length
  tightened to one sentence, two at most — the "or multi-step" clause had made
  narration the default rather than the exception (computer-use especially).
- **Built-in tool triggers lead with when to act, not just when not to.** The
  `when_to_use` for `web_search`/`web_fetch`/`subagents`/`memory_recall` now opens
  with the affirmative trigger (the answer is current/changing, you already have
  the URL, the request fans out, it may depend on stored facts) before its routing
  exclusions — the documented lever for should-call rate on tool-conservative models.
- **Time-sensitive facts are grounded before answering from memory.** A broad
  "Verify, Don't Guess" principle now covers changeable external facts (rates,
  figures, standings), not just local machine/repo state — verify with a tool
  before answering, however sure the model feels. (Raised the capability-eval
  web-research fire rate 32% → 68% with no query changes.)
- **The agent holds an evidence-backed answer under pushback.** A new "Pushback
  Gets Diligence, Not Deference" rule: re-check before conceding a challenge,
  reconcile an apparent contradiction rather than capitulating, and change the
  answer only when evidence changes it — confidence tracks evidence in both
  directions, no caving and no digging in.
- **The default transcription model is now `gpt-4o-mini-transcribe`** (was the
  legacy `whisper-1`) — better accuracy on the same OpenAI endpoint. Set
  `[fermix_core.transcription] model` to pin a different model.

### Fixed

- **Voice calls no longer freeze after a computer-use (or any slow) tool run.**
  The realtime `SessionServer` is now a non-blocking coordinator — tool calls run
  off the session loop on a supervised task, so mic audio, interrupts, and stop
  keep flowing while a tool runs — and the connection handler owns its socket so
  the pet always sees EOF on teardown. (Fixes a four-defect deadlock chain that
  wedged the companion mid-call.)
- **Anthropic models now actually reason on time-sensitive turns.** Opus 4.8 (and
  4.6+/Sonnet 5/Fable/Mythos) runs without thinking unless the request carries
  `thinking: {type: "adaptive"}` — `reasoning_effort` alone only calibrates token
  spend — so the daemon now sends adaptive thinking on models that support it
  (Haiku 4.5 stays gated off). The non-streaming clamp and buffered receive window
  grew to fit thinking plus the visible answer.
- **The OpenAI direct-API (api-key) path works again.** The Responses adapter was
  sending `temperature`, which every model it serves (the gpt-5 reasoning family)
  rejects with a 400 — breaking the whole direct-API catalog (the dev daemon never
  saw it because it rides the Codex OAuth adapter). Temperature is dropped from the
  Responses payloads; ChatCompletions is unaffected.
- **`web_search` no longer degrades to DuckDuckGo after an idle gap.** All seven
  search backends now route through the shared hardened Finch pool (15s idle cap +
  one stale-socket retry) instead of per-request Req options that silently ran on
  an infinite-idle pool — Cloudflare closed those keepalives and Finch handed out
  the deadest one first, so the first searches after idle each burned a dead socket
  (45 occurrences since June). `fermix doctor --full` now starts the pool before
  its live probes.
- **A connect stall on a continuation call no longer kills the whole run.** The
  Codex adapter mislabeled a ~5s TCP/TLS connect stall as between-chunk stream
  starvation and had no retry seam for continuations, so a mid-run blip was fatal
  (and the failure-report delivery died on the same blip). Transport `stage` is now
  a measured value, and continuations get bounded in-place retry for exactly the
  proven zero-data timeout class (2 attempts, no tool replay, no provider switch) —
  including scheduled runs.
- **Scheduled jobs honor their configured timeout.** `Jobs.Runner` resolved
  timeout precedence by key *presence* rather than value, so the Scheduler's
  always-present-nil `timeout_ms` shadowed each job's own `timeout_seconds` /
  `inactivity_timeout_seconds` — jobs set for longer were killed at the 30-minute
  default and the inactivity watchdog never armed. Now keyed on the value.
- **Codex-style API errors surface their detail, and wire booleans are preserved.**
  Provider error composition falls back to a top-level `detail` field (Codex
  `{"detail": …}` errors were showing a generic message), and the introspection
  wire no longer stringifies a bare `true`/`false`/`nil`.
- **Failed voice-note transcription no longer drops silently.** When
  transcription isn't configured, the audio is over the size cap, or the provider
  errors, the sender now receives a specific, actionable reply (not configured →
  run `fermix setup`; too large → the size-cap limit; other failures →
  transcription failed, try again) and no turn is scheduled — previously the
  gateway logged the error and the sender heard nothing. A `[fermix_core.transcription]
  max_file_mb` cap (default 20, aligned with Telegram's bot limit) is enforced
  before download when the size is declared, after download otherwise.

### Internal

- **Multi-OS CI gate + disposable eval/benchmark boxes (M22).** The PR check job
  is now a 3-leg matrix (linux-x64, linux-arm64, macOS-arm64) — 3 of the 4 shipped
  Burrito targets had never run the suite in CI. The eval stack (including the
  tiers too dangerous for a dev machine) runs unattended on disposable cloud boxes,
  a destructive run additionally requires `FERMIX_EVAL_DISPOSABLE=1`, and any failed
  eval tier auto-files a deduped GitHub issue. Branch protection: the required check
  splits into three per-leg names.
- **Eval boxes and the benchmark harness use a hosted Opik + an external judge.**
  Boxes talk to Comet-hosted Opik over its API (the in-box Docker stack is gone),
  and the local harness calls the external judge API directly (`make
  capability-auto` seeds and tears down a throwaway capability daemon); new
  chief-of-staff / epistemic-integrity suites added.
- **compux pinned to v0.5.0 (protocol 3)** — the sidecar library behind computer
  use, carrying the new idle-detection actions the coexistence arbiter uses; the
  fermix pin verifies against the v0.5.0 signed-release checksum.
- Docs: `self_knowledge`, README, and wiki refreshed (reasoning-effort per-model
  ceiling, `schedule_job` timeout args, bootstrap-template drift, FermixPet cask
  migration, provider/channel/voice sections).
## [0.5.8] - 2026-07-12

### Changed

- **GPT-5.6 (Sol, Terra, Luna) context window corrected to 272k.** The catalog
  listed the 5.6 generation at 372k; the effective window is 272k on both the
  Codex (ChatGPT subscription) and OpenAI direct-API paths, which still serve
  the same window for this generation. Auto-compaction thresholds, forced
  `/compact` budgets, and the `fermix doctor` context report now key off the
  corrected value. The older `gpt-5.5` / `gpt-5.4` / `gpt-5.4-mini` windows are
  unchanged.

## [0.5.7] - 2026-07-11

### Added

- **`fermix doctor`'s Computer Use check now names the compux sidecar version.**
  The check reported permission state but never which screen-capture sidecar build
  is installed, so there was no one-glance way to confirm it after a bump. The
  probed result now appends ` · sidecar compux v<vsn>`, and the not-installed
  warning names the target version — sourced from the same `compux` app version
  the daemon resolves the helper by.

### Fixed

- **Sub-agents now run on your primary provider unless you pin one explicitly.**
  A sub-agent model set without an explicit provider resolves on the primary
  provider, instead of being silently re-routed to whichever provider's catalog
  happens to own the model slug. Previously a leftover sub-agent model from a
  different provider (e.g. a `gpt-oss` pin — an Ollama model — kept after
  switching your main provider to Codex) quietly ran delegated workers on that
  other provider rather than your main model; if that provider wasn't running,
  the spawn failed. The setup page's **Sub-agent model** picker also no longer
  surfaces such a stale cross-provider model as the "current" value on the
  primary pane — it shows "Same as main model" and self-heals on the next save.
  To run sub-agents on a non-primary provider, set `subagent_provider` explicitly
  in `[fermix_core.routing]`.
- **`fermix stop`/`restart`/`upgrade` now force-kill a daemon that won't shut down,
  and `upgrade` verifies the daemon came back on the new version.** The service
  commands sent a single `launchctl kill TERM` and reported success the instant
  launchd accepted the signal — not when the process actually died. A daemon whose
  orderly shutdown stalled (a draining agent turn, an open Computer Use session, a
  hung socket) could survive an "upgrade" silently: the on-disk binary was the new
  version while the old BEAM kept running, and every command reported green. Stop
  now captures the job pid, waits a bounded grace for that exact process to exit,
  escalates to SIGKILL if it stalls, and fails loud (with a `kill -9`/reinstall
  hint) only if even that leaves it alive. The post-restart upgrade health check
  now asserts the daemon reports the new version (semver compare against
  `manifest.latest`) rather than merely `{"status":"ok"}`, so a stale daemon
  triggers rollback instead of a false green. Linux/systemd was never affected
  (its default `TimeoutStopSec` already guarantees SIGKILL).

## [0.5.6] - 2026-07-10

### Added

- **GPT-5.6 models (Sol, Terra, Luna) are now in the OpenAI and Codex catalogs.**
  `gpt-5.6-sol` (frontier), `gpt-5.6-terra` (balanced), and `gpt-5.6-luna` (fast,
  affordable) are selectable in the setup wizard and web pane, and `gpt-5.6-sol`
  is now the default model for both the OpenAI (API-key) and Codex (ChatGPT
  subscription) providers on a fresh install. All three carry a 372k context
  window on both access paths (the Codex path and the direct API report the same
  window for this generation). Existing installs that pin a `default_model` are
  unaffected; the earlier `gpt-5.5` / `gpt-5.4` / `gpt-5.4-mini` models remain
  available.
- **`max` reasoning effort is now available for the GPT-5.6 family on OpenAI and
  Codex.** `max` is a gpt-5.6-family capability, so setup offers it only when the
  selected model is a 5.6 model; gpt-5.5/gpt-5.4/gpt-5.4-mini top out at `xhigh`.
  Each model carries its effort ceiling in the catalog, and an over-reaching
  config or routing override self-heals down to the model's ceiling at route
  resolution (e.g. `max` on gpt-5.5 runs as `xhigh`) instead of failing at the
  provider.
- **Grok 4.5 is now in the xAI catalog and is the default Grok model.**
  `grok-4.5` (1M context window, accepts reasoning effort) leads the xAI model
  list, so a fresh xAI setup defaults to it; `grok-4.3` and the other Grok
  models remain available.

### Fixed

- **macOS keychain secrets no longer trigger repeated login-password prompts.**
  Secrets were stored with `security add-generic-password -U -A`, but the open
  ACL (`-A`) only takes effect when an item is created — on an update it left a
  pre-existing item's restrictive ACL in place, so any item first written without
  `-A` (an older Fermix, a manual Keychain entry, or a past "Always Allow") made
  the daemon's headless reads prompt for the login keychain password on every
  access. Each save now deletes the item before re-adding it, so the open ACL
  always applies and the item self-heals; re-run `fermix setup` once to rewrite
  existing items in a single pass.

## [0.5.5] - 2026-07-08

### Fixed

- **Computer Use permissions now attribute to one stable, signed "Fermix" app on
  macOS.** The screen-capture sidecar used to inherit the ad-hoc, per-version
  identity of the daemon that launched it, so macOS Screen Recording /
  Accessibility grants never persisted — every screenshot re-prompted, and each
  upgrade left a new "Fermix" row in System Settings. The sidecar now runs as its
  own Developer-ID-signed, notarized `Fermix.app` (a permanent bundle identity)
  that disclaims TCC responsibility from its parent, so a grant sticks across
  upgrades and every macOS permission Fermix needs — Screen Recording,
  Accessibility, and the voice companion's Microphone — shows as a single
  **Fermix** app with its icon. The setup Plugins page gains a **Grant macOS
  permissions** button that raises the prompts up front (and registers the app in
  System Settings) instead of surprising you on the first screenshot.
  - _Upgrading from a pre-release build:_ if Computer Use reports a missing
    permission even though the "Fermix" box looks checked, a stale grant from the
    old build is shadowing the signed one — remove the "Fermix" row under System
    Settings ▸ Screen Recording (or run `tccutil reset ScreenCapture
    io.tezra.fermix.computer-use`) and grant again. First-time installs are
    unaffected.
  - _Icon cache:_ the new row may briefly show a generic icon until macOS
    refreshes its icon cache (a relogin, or `killall Dock`).
- **Upgraded voice configs with any official OpenAI voice no longer crash the
  daemon.** 0.5.4 validated the Realtime `voice` against only the four curated
  dropdown options (marin/sage/verse/cedar), but earlier Fermix accepted any
  voice — so a config carrying `alloy`, `echo`, or another official voice raised
  during config normalization, which runs on both setup render and daemon
  boot/readiness. Validation now accepts the full official OpenAI voice set
  (alloy, ash, ballad, coral, echo, sage, shimmer, verse, marin, cedar); the
  setup dropdown still lists the recommended voices first.
- **The setup page reconnects itself after "Apply & restart".** Restarting the
  daemon from the setup UI briefly stops the web server; the page had relied on
  LiveView's default reconnect, which could strand the browser on a terminal
  "can't connect" error during the few seconds of downtime — even though the
  daemon comes back fine (the setup session survives because `secret_key_base`
  is persisted, not regenerated per boot). The "Restarting…" overlay now waits
  for the daemon to go down and come back, then reloads, so the page returns on
  its own instead of needing a manual `fermix setup`.
- **OAuth tokens refresh proactively, and a rotated refresh token is never
  reused.** The daemon refreshed tokens only lazily — on use, within 10 seconds
  of expiry, with no background timer — and refreshed from an in-memory copy of
  the refresh token. If that token was rotated out-of-band (by a `fermix
  doctor`/setup auth probe, or a second daemon on the same account), the daemon
  could reuse the now-consumed token, and providers like Codex invalidate the
  entire session when a rotated refresh token is reused ("your session has
  ended"). `TokenManager` now (a) schedules a single proactive refresh a few
  minutes before expiry — one timer per token, no polling — so an idle daemon
  keeps its token warm, and (b) always refreshes from the latest token persisted
  on disk, so a rotated token is never reused. Recovery from an already-ended
  session is still `fermix auth login`.

## [0.5.4] - 2026-07-07

### Fixed

- **Hung skill and shell commands are fully terminated instead of leaking.** A
  command that spawned a subprocess (a skill running `python`/`node`/`uv`) and
  then timed out had only its direct shell child killed — the grandchild was
  orphaned to the operating system and kept running, in one case for days at
  high CPU. The command runner now signals the whole process group, so every
  descendant is reaped with the timeout.
- **The installed daemon no longer runs at background CPU priority.** Its
  service definition requested macOS's `Background` (`darwinbg`) QoS band, which
  throttles the daemon and everything it spawns whenever the machine is under
  load — so the setup page, keychain reads, and restarts crawled in the
  brew-installed daemon while the foreground development process (unthrottled)
  stayed fast under the same load. The service now runs at `Standard` priority;
  the change reconciles onto an already-installed unit on the next `fermix
  setup`.
- **`fermix restart` and `fermix upgrade` no longer hard-kill the daemon.** They
  kicked the service with launchctl's `-k` (an immediate `SIGKILL`) and the unit
  had no shutdown grace, so a restart could kill the daemon mid-drain and — with
  KeepAlive — bounce it in a relaunch loop (the setup page appearing to "keep
  reloading"). Restart is now a graceful `SIGTERM` plus a shutdown-timeout
  headroom, so in-flight work drains first.
- **A permanently-unreachable MCP server no longer respawns forever.** After a
  server exhausted its discovery retries and logged "giving up", it was
  immediately restarted and tried again — an endless loop that spawned a new
  helper process every few seconds. A server that gives up is now quarantined
  until the next configuration or plugin change, while a genuine transport blip
  still reconnects.
- **The setup page no longer reads the OS keychain to build its prompts.**
  Prompt building resolved every stored secret from the keychain on each page
  load, though it only needs to know whether each secret is present. It now
  tests presence without resolving, removing another batch of `security`
  subprocesses from the setup path.
- **A wedged host runtime can no longer hang the setup page.** The probe that
  runs `<runtime> --version` (for plugins that need `node`/`python` on the host)
  had no timeout; a stuck runtime blocked the page render indefinitely. The
  probe is now bounded and reaps a stuck process.

### Added

- **The voice companion's model, voice, and reasoning effort are now selectable
  in setup.** The web setup Voice pane has dropdowns for the Realtime model
  (`gpt-realtime-2.1-mini`, `gpt-realtime-2.1`, `gpt-realtime-2`), the voice
  (Marin, Sage, Verse, Cedar), and a new **reasoning effort** setting
  (`minimal`/`low`/`medium`/`high`/`xhigh`). Reasoning effort is sent on the
  OpenAI Realtime `session.update` (`[fermix_core.realtime] reasoning_effort`,
  default `low` — OpenAI's recommended starting point for a voice agent); it was
  previously left to the API default. The model/voice/effort option lists have a
  single source of truth (`FermixCore.Realtime.Config`) that both the config
  validator and the setup dropdowns read.

### Changed

- **The realtime voice is now chosen from a dropdown** (Marin, Sage, Verse,
  Cedar) instead of a free-text field, and the config validates the voice
  against that list.
- **The default live-voice instructions (`REALTIME.md`) were rewritten to
  OpenAI's realtime prompting guidelines.** Labeled sections and tighter rules:
  lead with the answer in one or two sentences, no filler openers, and no
  trailing "anything else?" / "let me know if you want more" offers; a
  truthfulness rule (report only what a tool actually returned, say plainly when
  one fails, never present a guess as fact); an explicit act-by-default stance
  that still confirms by voice only before irreversible actions; and a rule to
  look up current or changeable facts (news, live results, prices, schedules)
  with a tool instead of answering from stale training data. Ships as the seeded
  default for new setups; an existing `REALTIME.md` is left untouched.

## [0.5.3] - 2026-07-06

### Fixed

- **The setup page no longer reads the OS keychain on every load.** Computing
  the "restart required" banner reloaded the persisted config with secret
  resolution on, spawning one `security` subprocess per stored secret on every
  page mount (twice per load — LiveView mounts a page twice). On a keychain
  that answers slowly this made the setup page take minutes; on 0.4.2's
  plaintext config it was instant, which is why the slowdown only appeared
  after the keychain move. The comparison now happens at the `@keyring`
  sentinel level — pure, in-memory, zero keychain reads on the web path.

### Added

- **Computer Use now installs.** The `compux` native helper has its first
  published release (v0.3.0): Developer-ID signed and notarized for
  Apple-Silicon macOS, plus Linux x86_64. Enabling Computer Use downloads the
  helper, verifies its sha256 against the pinned checksum map, and — on macOS
  — Gatekeeper accepts it as a notarized Developer ID binary, so the
  Accessibility/Screen Recording grants survive upgrades. Also fixes a latent
  TLS bug in the helper download (Erlang `:httpc` rejected GitHub's wildcard
  release-asset certificate), which would have failed the install for every
  user. Intel-mac and ARM-Linux remain unpublished for now and keep the
  honest "not published for this platform" message.
- **Global log secret redaction.** All log output — file and console, crash
  reports included — now passes through a redacting formatter that replaces
  credential-shaped tokens (OpenAI/Anthropic `sk-…`, GitHub, Slack, xAI,
  Google, Telegram bot tokens, AWS key ids, bearer headers) with
  `[REDACTED:<vendor>]` markers. Defense-in-depth for the 0.5.2 crash-report
  leak class: existing redaction was path-specific and could not see what an
  unforeseen crash dump carries.

### Changed

- **Daemon boot resolves keychain secrets in parallel.** Boot previously read
  each `@keyring` secret sequentially — one `security`/`secret-tool`
  subprocess at a time. A config with 15 stored secrets paid ~0.6s at every
  start (measured: 71ms parallel), and a degraded keychain (3s timeout per
  read) paid 45 seconds where it now pays ~6. Reads fan out over a bounded
  task pool; failure semantics are unchanged (warn loudly, keep the sentinel,
  never crash boot).
- **`fermix setup` waits up to 60s (was 30s) for the daemon before giving up
  on opening the browser.** A healthy boot opens the browser the moment the
  endpoint answers; the longer window only helps a slow-but-healthy boot
  auto-open instead of printing the URL.

## [0.5.2] - 2026-07-06

### Fixed

- **A slow keychain read can no longer crash the setup page or leak a secret to
  the log.** When `security` returned a secret just after its timeout,
  `CommandRunner` left that output — the raw secret — in the calling process's
  mailbox; a GenServer caller (the setup LiveView, `BootReport`) then crashed on
  the unexpected port message and the secret was written into the crash log. The
  runner now drains and flushes any late child output on timeout, so it never
  reaches the caller.
- **Honest Computer Use install error.** A failed Computer Use install now says
  the native helper "hasn't been published for this platform yet" rather than
  "…for this Fermix version yet", which wrongly implied a `fermix upgrade` would
  help. (The helper's first release is still pending.)

### Changed

- **macOS keychain secrets are stored with an open access list (`-A`).** Without
  it, each item's ACL is pinned to the exact code signature of the writing
  binary; the daemon — an ad-hoc-signed, per-version binary the keychain can't
  reliably match — is then treated as an untrusted app and macOS blocks every
  read on an authorization prompt the headless service can't answer, so reads
  hang and time out (slow boot, slow/failed setup). `-A` lets the daemon read
  headlessly. Trade-off: any process running as the same user can read the item
  without a prompt — no weaker than the pre-keychain plaintext-in-config
  baseline, and still keychain-stored. The proper long-term fix is Developer-ID
  signing the release binary. Existing secrets keep their old ACL until
  re-stored (re-enter them in `fermix setup`, or `security add-generic-password
  -U -A …`).

### Fixed

- **The daemon no longer crashes at boot when the login keychain is locked.** A
  required secret stored under `@keyring` (e.g. `OPENAI_API_KEY`) whose keychain
  read timed out — common when the login keychain is locked or slow at daemon
  launch — raised during config hydration and took down the whole node, leaving
  the setup UI (the very surface used to fix it) unreachable. Boot now leaves the
  `@keyring` sentinel in place and logs the failure (the same graceful handling
  optional secrets already had) instead of crashing; the secret resolves on the
  next boot once the keychain is reachable.
- **`fermix setup` no longer opens the browser before the endpoint is live.** On a
  readiness timeout the launcher printed the URL but still opened the browser,
  landing on "Safari can't connect to the server". It now opens the browser only
  once the endpoint actually answers; on timeout it hands back the URL to open
  manually.
- **The setup 403 page is now actionable.** Reaching the token-gated `/setup` page
  without an authorized session returns `setup authorization required` plus a line
  telling you to run `fermix setup` (the only thing that authorizes a browser
  session), instead of a bare error.

## [0.5.0] - 2026-07-04

### Added

- **Computer Use is now backed by the standalone `compux` library.** The native
  computer-use sidecar was extracted into a separate signed binary (mechanism in
  `compux`, policy in Fermix). This release wires Fermix to it, ships the compux
  v0.2/v0.3 action set, surfaces the screenshot cursor, and gives the Computer
  Use setup card its own name and logo. Computer use can also run over realtime
  voice now, across one shared untrusted boundary. Still experimental and off by
  default.
- **Emoji-reaction acknowledgements.** A pure acknowledgement ("ok", "thanks",
  👍) is answered with a message-level emoji reaction instead of a text bubble,
  across all reaction-capable channels (Telegram, Discord, WhatsApp, Signal,
  Slack). A delivered reaction with no accompanying text ends the turn without a
  continuation LLM call, roughly halving ack latency.
- **Chief-of-staff prompt surgery (safe subset)** landed in the operating prompt.
- **Plugin auth failures are agent-actionable**, and stale OAuth tokens are now
  flagged in the provider badge and `fermix doctor`.

### Performance

- **Sandbox path checks no longer recompute their invariant root sets.**
  `read_path`/`write_path`/`working_dir` resolve the protected and effective root
  sets once per call instead of ~3×, and `content_search`/`glob_search` validate
  their candidates through a single batched `Sandbox.read_paths/3` instead of a
  per-file `lstat`/`ls` syscall storm. Behavior-preserving: identical allow/deny
  decisions, `cond` order, and deny audit traces.
- **Album image downloads run concurrently.** Multi-image attachments (e.g. a
  Telegram media group of up to 10 images) are fetched in parallel (bounded)
  instead of serially, cutting pre-turn latency from the sum of the downloads
  toward the slowest single one. Ordering, all-or-nothing fail-loud, and
  temp-file cleanup are preserved.

### Fixed

- **Security:** `git_write` can no longer reach an `ext::` RCE — `GIT_ALLOW_PROTOCOL`
  is pinned so a `git pull` cannot invoke an external protocol helper.
- **Security:** the home page no longer mints a `/setup` launch token to any
  visitor.
- **Computer use fails closed on host control for detached `/background` runs**,
  and picks up the compux stop-kill and display-asleep fail-fast paths.
- **Scheduled deliveries no longer drop on a Finch pool-checkout timeout**
  (wake-from-sleep pool starvation).
- **FermixPet stays in its speaking look for the whole spoken reply.** The macOS
  voice companion previously flipped back to the listening face as soon as the
  model finished *generating*, even though the buffered voice kept playing for
  seconds after; it now tracks actual audio playback (face, glow, controls, and
  motion), leaving the microphone/turn-taking state machine untouched.

### Changed

- **Removed the `watch` construct**, parked pending a redesign.
- **FermixPet mascot animation feels more alive** on the existing art — no new
  assets or dependencies: eye blinks on the open-eyed states, motion that eases
  between states instead of snapping, a smoothed audio-reactive speaking pulse,
  and a corrected speaking-face offset. The animation timeline now pauses when
  the pet window is hidden to save energy.

## [0.4.2] - 2026-06-28

### Added — Computer Use is now installable (signed catalog plugin)

- The computer-use native sidecar ships as a cosign-signed catalog plugin
  (`computer_use_sidecar`): install it (`fermix plugins install
  computer_use_sidecar`), then turn computer use on by flipping
  `[fermix_core.computer_use] enabled`. 0.4.0 shipped the runtime + safety
  floor but not the signed binary; it now installs through the normal plugin
  flow. Still **experimental and off by default** — registered for the model
  only once enabled and `ready?` (binary installed + OS permissions granted),
  with the `access` posture derived 1:1 from `[sandbox] mode` plus the
  attended-origin gate.
- Supported platforms: **Apple Silicon (M-series) macOS and Linux x86_64**.
  Intel Macs are not supported — install fails cleanly with `no_build_for_target`.
- The sidecar binary is cross-compiled per target and published as a per-target
  signed release, then pinned into the bundled plugin catalog (`index.json`).
  The plugin release pipeline and the catalog sync gained a native-build path
  (per-target tarballs) without weakening the mandatory sha256 + cosign install
  verification.

## [0.4.1] - 2026-06-27

### Added — Slack, Discord, and AgentMail plugins
- The three M16 static-secret (`api_key`) communication plugins now ship in the
  bundled catalog: `fermix plugins install slack | discord | agentmail`, then
  `enable` and set the credential (`SLACK_BOT_TOKEN` / `DISCORD_BOT_TOKEN` /
  `AGENTMAIL_API_KEY`). 0.4.0 shipped the api_key HTTP-rail runtime that runs
  them, but the plugin packages themselves were not yet released, so they did
  not appear in the catalog. They are now published as signed releases in
  `fermix-plugins` and synced into the bundled plugin index (`index.json`).

## [0.4.0] - 2026-06-27

### Added — Media Generation (M15)
- `generate_image` built-in tool over a modular `FermixCore.Media.Backend`
  surface (OpenAI / Google / xAI image backends, OpenAI transcription), plus
  the multimodal reply / attachment / browser plumbing that carries generated
  and returned images through to the channel.

### Added — Inbound Multimodal Images
- Inbound images on media-capable channels are downloaded at the gateway
  (sibling to audio transcription) and passed to the model as image content;
  an image whose resolved model cannot accept vision fails loud rather than
  being dropped silently. Each provider encodes one neutral image part at its
  own edge (Anthropic base64 blocks; OpenAI Responses/Codex/xAI `input_image`;
  ChatCompletions `image_url` for OpenRouter/Mistral/Ollama), so the text-only
  request shape is byte-unchanged and prompt caching is unaffected.
- Multi-image messages are coalesced into one turn (shared, non-blocking
  `Gateway.AlbumBuffer`) so the agent sees every image together: Telegram by
  `media_group_id`, WhatsApp per-image webhooks by a per-sender debounce. This
  also removes the ~50s Telegram album delay (the flush timer no longer sits
  behind the `getUpdates` long-poll). New CLI `ask --attach PATH`.

### Added — Plugin runtime for static-secret (api_key) integrations (M16)
- The HTTP-rail `api_key` plugin runtime — the shared static-secret slice across
  plugin secret paths, migration, and the setup CLI / wizard / doctor / web UI
  (Bearer auth by default, `Bot` for providers like Discord/Slack), with OAuth
  scaffolding retained for deferred `search.messages`. This shipped the runtime
  that *runs* static-secret plugins; the Slack, Discord, and AgentMail plugin
  **packages** were not released in 0.4.0 and so did not appear in the catalog —
  they ship in 0.4.1.

### Added — Soul Self-Curation (`/soul`)
- Owner-only `/soul` channel command and the `SoulCuration` core module: an
  owner-driven, never-autonomous path to review, apply, revert, and reset the
  agent's persona file (`SOUL.md`). `/soul review` drafts a versioned edit
  through one bounded provider call that advertises no tools and never writes;
  `:review` is subtle and voice-preserving (declining is the common outcome),
  `:suggest` follows an explicit instruction with proportional scope.
  `--with-context` folds a hard-bounded window of the owner's own recent
  messages in as labeled evidence (guest turns filtered out). Every write goes
  through the resource registry (versioned and itself revertable) behind a
  propose → token → `/soul apply` confirmation; prompt-injection markers in
  source memory are surfaced on the diff. Apply invalidates the MainAgent's
  cached runtime context so a new persona takes effect without a restart.

### Added — Assistant Naming
- An "Assistant name" field in the personalization step (CLI wizard + web
  setup). The name is identity, so it persists to `[fermix_core.agent].name` —
  the source of truth that seeds `IDENTITY.md` — not the personalization block.
  Blank keeps the current/default name (`fermix`).

### Added — Web Search (Firecrawl backend)
- Firecrawl (`api.firecrawl.dev/v2/search`) as a seventh `web_search` backend
  alongside duckduckgo / tavily / exa / parallel / brave / perplexity.
  Cloud-only, snippet-only, Bearer auth with a 500-char query pre-flight and
  shared error mapping, wired through the secret paths, config, wizard, and web
  setup UI.

### Added — Computer Use (host / browser GUI control) — EXPERIMENTAL
- Source-only host/browser GUI control: a `computer_use` tool, the
  `FermixCore.ComputerUse` session / config / safety modules, and a signed
  Rust sidecar (`native/computer-use-sidecar`). Its access posture derives 1:1
  from the existing `[sandbox]` mode (`strict` refuses all mutating actions;
  `standard` confirms irreversible actions; `open` confirms only catastrophic
  ones), with hard floors (strict-refuse, attended-origin gate) orthogonal to
  access. **EXPERIMENTAL and disabled in the production catalog** — it is not
  wired into the default seeder/supervisor and ships off.

### Added — Scheduled Jobs (provider/model pinning)
- Optional provider/model route pinning on `schedule_job` and `update_job`,
  validated by a shared `validate_route_pin/1` (both-or-neither; the provider
  must be a known, configured provider per the same catalog `Jobs.Runner`
  gates against, so the tool-boundary check cannot drift). The registry
  persists the pin and the job payload surfaces it; an unpinned job keeps using
  the global `[fermix_core.routing]` `cron_*` default.
- `update_job` accepts a `clear_route_pin` boolean that un-pins a job's
  provider/model back to default routing (clears both atomically). It is
  mutually exclusive with `provider`/`model` — supplying those re-pins instead,
  and combining a clear with a pin is rejected.

### Added — Centralized Timeouts
- `FermixCore.Timeouts` (named failure deadlines + `expired/3`) and a
  `Timeouts.Telemetry` emitter for one stable `[:fermix, :timeout, :expired]`
  event, wired into both the JSONL `Trace.TelemetryHandler` and `fermix_opik`.
  First adopter: the computer-use Port timeout, which now fires a named
  `expired(:cu_sidecar_action, ...)` and poison-resets the sidecar instead of
  surfacing a cryptic "received unexpected message".

### Changed — Web Fetch (JSON passthrough)
- When a fetched URL serves JSON, `web_fetch` now renders it verbatim instead
  of running it through HTML text extraction (which garbled it). The binary
  HTML path and the size cap are unchanged; the too-large guard still runs
  first on the raw bytes.

### Changed — Provider Resilience (transient retry & friendly 429)
- A bounded same-provider transient retry under the failover executor (new
  `Providers.Transient` classifier) so connection-unavailable and transient
  transport/5xx flakes self-heal on interactive turns and all surfaces, not
  just cron. Cron keeps its own deadline-bounded outer backoff, opts out of the
  inner retry, and retries only the fast pool-checkout race so a slow provider
  `:timeout` can never push a run past its configured job timeout.
- Rate-limit / quota errors now carry `resets_at` / `plan_type` from the body
  and surface a friendly "usage limit — try again in ~N min" message instead of
  a raw error tuple.
- A routing pairing guard: `RoutingOverrides` rejects an explicit provider
  paired with a model the catalog knows under a different provider, and
  `model_routing_config` validates the merged routing on every set, so no
  automated path can persist a mis-pairing.

### Changed — Browser Lifecycle Bounds
- Fermix-managed Chrome no longer accumulates tabs and instances. A per-Chrome
  tab cap (`max_tabs`, default 10) closes the oldest non-active tab past the
  cap; one-shot/loopback conversations (CLI `ask`, daemon) reap their browser
  at turn end instead of pinning a Chrome for the 15-minute idle TTL, while
  remote interactive channels keep their warm Chrome for follow-ups. Subagents
  inherit the parent conversation's browser scope (one shared Chrome), and
  `:auto` profiles launch with `--remote-debugging-port=0` and read the real
  port from `DevToolsActivePort`, removing the check-then-bind race two cold
  starts had on the shared range (the now-dead `cdp_port_range` config is
  dropped).

### Changed — Replayed Screenshot Retention
- `ScreenshotRetention` keeps image bytes only in the most-recent N screenshot
  carriers across the assembled history (Anthropic + OpenAI chat/responses/
  codex), eliding older ones to a text marker, replacing the inverted per-turn
  prune in the agent loop.

### Changed — Memory tuning surfaces cadence, not the extraction timeout
- The setup page's Memory tuning pane (and the CLI wizard's memory prompt) now
  exposes **Review interval (hours)** — the background memory-review cadence —
  instead of the extraction timeout. The timeout is not a knob worth operator
  attention.
- `memory.extraction_timeout_ms` is removed as a config key. The memory review
  is a buffered LLM call and now inherits the centralized `:llm_buffered`
  ceiling from `FermixCore.Net.TimeoutPolicy`, exactly like every other
  buffered turn — one timeout table instead of a bespoke per-feature knob. The
  review claim-lock TTL derives from that same value. Hand-edited
  `extraction_timeout_ms` entries in `config.toml` are ignored.

### Changed — Reply-path performance
- Cut redundant per-iteration work on the agent reply path, behavior-preserving
  (telemetry, security decisions, and trace routing are unchanged): the
  turn-invariant tool-schema byte metrics are now computed once per turn and
  carried in `provider_state` instead of re-encoded on every provider call
  (Anthropic / OpenAI Responses / Codex / xAI); the sandbox resolves its config
  and symlink-resolving protected-roots list once per shell command instead of
  twice; and `Trace.TelemetryHandler` reads each event's definition from its
  handler config rather than rebuilding and linear-scanning the definition list
  on every emitted event.

### Changed — Auto-compaction triggers on real provider token usage
- Preflight auto-compaction now gates on the real provider-reported
  `context_tokens` (the same measure the post-delivery pass already uses),
  tracked per conversation in `MainAgent` (pruned, written off the reply path)
  and read through `turn_state` — instead of a `byte_size/4` estimate dispatched
  through a tiktoken NIF that never existed. The dead NIF reflection is removed;
  a single byte-length estimate remains only for the compactor's per-message
  split. Cold conversations with no prior measurement skip the preflight
  cleanly (the post-delivery pass still catches them).

### Changed — Agent operating principles (prompt)
- Two `FERMIX.md` rules drawn from live traces: change runtime state through the
  owning tool or config, never by editing the source, database, or config it
  runs on; and treat a fact tool-verified earlier in the same conversation as
  current evidence — answer a restatement from it and re-verify only when the
  state could have changed, rather than re-running the whole investigation.

### Fixed — web_fetch crash on non-UTF-8 pages
- `web_fetch` raised on a page served in a non-UTF-8 charset (e.g. Latin-1): the
  unicode-flagged regex in the HTML text renderer hit invalid UTF-8 bytes and
  crashed the tool (and would have broken JSON-encoding the result). The body is
  now normalized to valid UTF-8 at the fetch boundary (invalid sequences →
  U+FFFD; valid bodies pass through unchanged), so the whole pipeline and the
  returned text are valid UTF-8.

### Fixed — Phantom empty Opik traces from late stream:block events
- In block streaming, a `stream:block` telemetry event firing after the turn's
  trace had already closed lazily resurrected a parentless, empty trace that the
  sweep then exported to Opik (the "empty trace after each query"). Late
  `:block` events now attach only if the session is still open and otherwise
  drop, mirroring the `:seal`/`:discard` handling.

### Fixed — Assistant Name reconcile on boot
- `IDENTITY.md` was seeded once and never rewritten, so changing
  `[fermix_core.agent].name` never reached the file the model reads and the
  agent kept answering with the originally-seeded name. `Prompt.IdentityName`
  now reconciles on boot (idempotent, fail-soft): when a name is explicitly
  configured and differs from the file's `**Name:**` line, it rewrites only
  that line, preserving other operator edits. A blank/unset name is a
  deliberate no-op.

### Security — Git sandbox-escape flag hardening
- `git_write` passed model-supplied args to `git` unfiltered, allowing
  `git pull --upload-pack=<cmd>` argument-injection-to-RCE (`git_read` had a
  denylist but `git_write` did not). A prefix-aware flag denylist is now
  centralized in the shared `GitCommand.run` sink both tools call, so every git
  tool is covered uniformly and abbreviations (e.g. `--upload-pac=`) are caught
  too. `git_read` keeps its read-specific positional-path checks locally.

## [0.3.1] - 2026-06-16

### Fixed — Plugin install under the OS-service daemon
- Plugin installation from the web setup page failed for **every** plugin
  with a misleading `signature invalid — refusing.` The OS-service unit
  (launchd `.plist` / systemd unit) carried no `PATH`, so the supervised
  daemon inherited a bare `PATH` that omits the Homebrew prefix where
  `cosign` lives. Signature verification shells out to `cosign`;
  `System.find_executable("cosign")` returned `nil`, the install pipeline
  reported `{:verification_failed, :cosign_not_installed}`, and the page
  rendered it as a bad signature. The signature was never actually checked.
  The same daemon ran fine in a dev shell (where `cosign` is on `PATH`),
  which masked the problem. `fermix service install` now pins a `PATH` in
  the unit file — leading with the directory `fermix` itself was installed
  into (its sibling `cosign` on a Homebrew install) followed by the standard
  system and Homebrew bin directories — so the daemon resolves `cosign` (and
  brew-installed MCP runtimes like `node`/`python`) the same way an
  interactive shell does.
- `fermix setup` now **self-heals a drifted service unit**: when an already
  installed unit no longer matches what the current binary would write (e.g.
  after an upgrade changed the template or the computed `PATH`), setup rewrites
  and reloads it instead of merely restarting the stale one. So upgrading and
  re-running `fermix setup` is enough to pick up the new `PATH` — the manual
  `fermix service install` becomes an escape hatch, not a required step, and
  any future unit-file change reaches existing installs automatically. An
  unchanged unit is still just restarted (no needless reinstall).
- The web setup page no longer reports a missing `cosign` binary as
  `signature invalid`; it now says `cosign not found — install it to verify
  plugin signatures (e.g. \`brew install cosign\`).`, distinguishing an
  environment problem from a genuinely bad signature.

## [0.3.0] - 2026-06-16

### Added — Provider Expansion (M12)
- OpenRouter (`openrouter`) and Ollama (`ollama`) as first-class LLM
  providers: primary/fallback selection, sub-agent and cron routing, CLI
  wizard + web setup panes, doctor probes, and telemetry/Opik attribution.
  OpenRouter rides Chat Completions with vendor-prefixed model ids and
  static app-attribution headers; Ollama is keyless against the local
  OpenAI-compat endpoint (`base_url` presence marks it configured) with a
  300s receive timeout and a doctor probe that checks the *served*
  `num_ctx` against the catalog window via the native `/api/show`.
- `FermixCore.Providers.Descriptor`: a static provider registry (labels,
  auth modes, setup fields, config-key allowlists, default base URLs) that
  routing, selection, config, the setup wizard, web setup, doctor,
  readiness, and health now all derive from instead of hand-maintained
  provider lists.
- Setup-page live model discovery (`FermixCore.Providers.ModelListing`):
  the Ollama pane probes the configured server URL and lists only the
  locally installed models; the OpenRouter pane lists the live upstream
  tool-capable catalog. Fetch failures show loud guidance plus a free-form
  model input. The "Model behavior" panel is hidden for providers without
  effort/fast knobs.

### Added — Mistral Provider
- Mistral (`mistral`) as the seventh first-class provider, riding the
  OpenAI ChatCompletions adapter (api-key only, no reasoning-effort) and
  exposing three rolling `-latest` tiers (large/medium/small) on a
  128k-context catalog through `FermixCore.Providers.Descriptor`. Adds
  `mistral_api_key` / `MISTRAL_API_KEY` across secret paths, wizard, CLI
  setup, the mix task, and `runtime.exs`; a `probe_mistral` doctor auth
  check; and Opik attribution. Canonical provider order is now
  `openai_codex, openai, anthropic, xai, openrouter, mistral, ollama`.

### Added — Sub-agent & Cron Model Selection
- `[fermix_core.routing]` `subagent_*` / `cron_*` keys
  (provider/model/reasoning_effort) give delegated `subagents` workers and
  unpinned cron jobs a smaller/cheaper model and thinking level without
  ever changing the main agent's model; unset keys inherit the main model.
  New `FermixCore.Providers.RoutingOverrides` reads and validates them,
  overlaying effort per-route (clamped per provider) so the inherited
  failover chain is preserved. Surfaced through `config.toml`, the setup
  wizard, the web setup page (sub-agent select shown only on the primary
  provider's pane), the `model_routing_config` tool, an optional on-the-fly
  per-call `model` arg on the `subagents` tool (provider inferred from the
  slug), and `fermix doctor` validation.

### Added — Deferred Tool Catalog
- Lazy tool-discovery surface so the model fetches tool schemas on demand
  instead of carrying the full catalog in every prompt.
  `FermixCore.Capabilities.Deferral` partitions trust-filtered capabilities
  into advertised (full schemas on the wire) and deferred (plugin/MCP tools
  — names stay in the prompt prose, schemas load on demand) sets, with
  three new bridge tools: `tool_search` (BM25 over the live registry),
  `tool_describe`, and `tool_call`. Gated by a single
  `[fermix_core.tools.tool_search] enabled` boolean; disabled is
  byte-identical to the inline catalog.
- `FermixCore.Prompt.ModelOverlays` for constrained per-model-family prompt
  overlays appended at the end of the instructions (currently only the
  Codex/GPT-5 family), preserving the cached prefix.

### Added — Plugin Distribution (M8 / M8.1)
- External plugin distribution: plugins now live in the
  `tezra-io/fermix-plugins` repo and reach users as signed, versioned
  installs. The install pipeline streams the artifact
  (`Net.StreamDownload`), sha256-checks it, runs `cosign verify-blob` with
  the certificate identity pinned to
  `release-plugin.yml@refs/tags/<name>/v<version>`, guards the archive
  against traversal/symlink/zip-bomb attacks, enforces a content boundary,
  decodes the manifest, verifies the `h1` hash, and atomically activates
  into a versioned store under `$FERMIX_HOME/plugins` (cross-VM lock,
  pin/rollback/gc, `SafeRm`-disciplined deletes). Modules under
  `FermixCore.Plugins.Dist.*` (`Installer`, `Store`, `Archive`, `Index`,
  `Lock`, `Verifier.Cosign`).
- Static plugin catalog: `apps/fermix_core/priv/plugins/index.json` is
  checked into the repo and shipped inside the release binary as the only
  catalog source — no remote index, no refresh, no boot-time refresh, no
  downgrade guard. New plugins reach users with the next Fermix release.
  `scripts/release/sync_plugin_catalog.py` regenerates the catalog from
  `fermix-plugins` releases and downloads, sha256-checks, and
  cosign-verifies every artifact pin it writes.
- Two plugin execution rails. Declarative HTTP rail: a template-grammar
  interpreter (`FermixCore.Plugins.Http.*` — `Template`, `Interpreter`,
  `ParamSchema`, `Extract`) with a param schema, SSRF floor, bounded
  pagination, and response extraction; the Google manifests are now
  expressed as in-VM HTTP templates (`ToolExecutor` shrinks 1042 -> 827
  lines). MCP rail: `Dist.McpSource` materializes server specs,
  `MCP.Supervisor.reload/0` starts/stops the per-plugin child (disable
  stops the process), a host-runtime probe gates install, and a `Status`
  ladder (`:not_installed` / `:incompatible` / `:missing_host_runtime` /
  `:needs_config`) surfaces readiness in the prompt catalog.
- `fermix plugins` CLI verbs: `install`, `installed`, `uninstall`,
  `upgrade`, `pin`, `gc`, and `config`, plus a `plugins_apply` daemon
  control-socket method so a running daemon reloads after a change.
  `fermix doctor` gains plugin checks.
- Setup-page plugin catalog: cards with inline logos, install-on-connect,
  and per-stage error prose. Per-plugin manifest config entries are
  collected at Connect time (web form / `fermix plugins config set`),
  persisted to TOML, and injected into the plugin env. A
  `[fermix_core.plugins] dev_local` author loop lets plugin developers
  point at a local build.

### Added — Plugin OAuth Providers (M8 §9.1)
- OAuth provider registry on the existing PKCE-loopback engine
  (`FermixCore.Auth.OAuthProviders`): `google`, `github`, and `notion`
  provider definitions. GitHub uses `Accept: application/json`,
  comma-separated scopes, and a port-wildcarded loopback; Notion uses HTTP
  Basic-auth token exchange on fixed loopback port 1458. Refresh dispatch
  is deduplicated through the registry, client secrets are keychained via
  `SecretPaths`, and the setup page renders a per-provider OAuth-client
  form. `oauth2` manifests may declare empty scopes for page-picker
  providers.
- X (Twitter) OAuth provider so the X HTTP-rail plugin (`x/v1.0.0`)
  connects through the PKCE-loopback engine: `x.com` authorize, `api.x.com`
  token, HTTP Basic confidential-client exchange, fixed loopback port 1459,
  redirect host `127.0.0.1` (X's portal accepts the IP, not `localhost`).
  Added to `Config @registry_oauth_providers`, an `X_OAUTH_CLIENT_SECRET`
  keychain path, the setup-page provider list (display "X", port 1459) with
  OAuth help tooltip, and an agent plugin-surface steer (`x_*` owns
  X/Twitter, not the browser).

### Added — Wave-1 Plugins (M8.1)
- Wave-1 plugins published to the bundled catalog: `github`, `notion`,
  `obsidian`, and `x`. The catalog was re-synced across the release to
  track upstream releases — Obsidian gained a branded card logo (1.0.1),
  then a cleaned-up logo (1.0.2), and GitHub/Notion/Obsidian (1.0.3)/X
  picked up clearer, more token-efficient tool and skill descriptions. Each
  pin is re-downloaded and cosign-verified by the sync script.

### Added — Scheduled Agents (M4.11)
- Scheduled jobs can be bound to an existing skill at create time
  (`schedule_job` `skill_name`), so the future run executes inside that
  skill's tool/policy confinement — its `allowed_tools` and capability
  policy are intersected with the job's, never widened; `Jobs.Runner`
  enforces the intersection and unknown skill names are rejected up front.
- New scheduled-job tools: `run_job_now` fires a job immediately and out of
  band through the same isolated runner (trigger `manual`) while leaving the
  timed cadence untouched, refusing a paused, disabled, expired, or
  already-running job (atomic claim via `Repo.claim_job_now`);
  `list_job_runs` and `get_job_run` read a job's execution history and one
  run in full (status, trigger, timing, prompt snapshot, token usage,
  outcome); `skill_reload` re-scans the skill directories and refreshes the
  running agent in place — reporting added/removed/changed names and load
  errors — without restarting the daemon.
- `list_jobs` payloads now include `task_prompt` (the job's current
  instructions) and `get_job_run` includes the `task_prompt` the run
  actually executed, sourced from the run's recorded `job_config_snapshot`
  so it reflects the instructions at run time rather than the
  possibly-since-edited current text (runs recorded before this change
  return null). The agent no longer has to read `scheduled_jobs.task_prompt`
  straight out of `memory.db`.

### Added — Prompt (Stale-failure guard)
- A `FERMIX.md` operating rule so the agent treats a failure it reported
  earlier as possibly-already-fixed: it checks live state before re-running
  something that failed, and if it cannot confirm the failure was resolved
  it flags what failed last time and asks rather than blindly retrying.
  Closes the narrow cross-turn gap where a narrated failure survives in the
  verbatim recent window with no latest-state-wins principle.

### Changed — Provider Expansion (M12)
- Fail-loud config validation: unknown keys in a
  `[fermix_core.providers.*]` TOML block and an unknown legacy
  `[fermix_core.agent] provider` now stop boot with a clear message instead
  of being silently dropped; an unknown readiness provider is a visible
  setup failure instead of silently coercing to `openai`; scheduled-job
  provider *atoms* are validated like strings.
- `/health` now reports one entry per configured provider (with the primary
  flagged) instead of a hardcoded single `openai` card, and ChatCompletions
  error/telemetry attribution follows the routed provider (OpenRouter/Ollama
  calls are no longer mislabeled `openai`).

### Changed — OpenRouter Setup Picker
- The OpenRouter setup model picker is now searchable and vendor-sorted:
  the live upstream list is sorted by id so same-vendor models cluster
  (`anthropic/*`, `openai/*`, `x-ai/*`, …) instead of newest-first, and the
  `<select>` is replaced by a free-text `<input>` + `<datalist>` so you can
  type to filter by id/label or enter any custom slug. `phx-debounce="blur"`
  keeps keystrokes client-side so the form doesn't re-fetch the catalog per
  letter.

### Changed — Scheduled Agents (M4.11)
- The 5-field cron parser now accepts comma lists (`1,15`), ranges (`9-17`),
  and steps (`*/15`, `8-18/4`) per field, with weekday `7` and `0` both
  meaning Sunday; out-of-range or malformed fields are rejected at creation.
  Schedule descriptions and the canonical example move to the cron form
  (`0 8 * * *`), and free-form English like "daily at 8am" is now rejected.
- `update_job` gains in-place editing of the delivery route (`delivery_mode`
  `none` / `origin` / `channel` / `local` + `delivery_target`) and skill
  rebinding (`skill_name`). Omitted delivery is left unchanged; switching to
  `none` / `local` clears a stale target; unknown skill names are rejected.
- Recurring jobs whose fire time was missed while the daemon was down are
  now skipped instead of running at a wall-clock far from their schedule: a
  due time older than `[fermix_core.jobs] run_freshness_window_seconds`
  (default `3600`) is skipped and the schedule advanced to the next future
  occurrence (logged). A one-off `once` run has no next occurrence, so it
  runs late rather than being dropped.

### Changed — Memory Taxonomy Redesign
- Memory category vocabulary moves to a six-category general-assistant
  spine. USER.md now holds `identity`, `preference`, `interest`, and `goal`
  (facts about the owner); MEMORY.md holds `context` (durable working
  knowledge) and `directive` (behavior-shaping rules), replacing the old
  domain-skewed `project` / `environment` / `instruction` / `correction` /
  `episode` set. `Admission.promotable_category?/2` is the single source of
  truth for which categories each bucket accepts, and `:guest`-trust callers
  can no longer promote `directive` rows into durable memory. The reviewer
  system prompt is rewritten to describe the new taxonomy and steer toward
  keeping memory current (replace/archive/generalize) instead of
  append-only growth.
- Memory prompt files are bounded by per-section row caps
  (Identity/Preferences/Interests 6, Goals 5, Context 12, Working Rules 8)
  plus a 200-char value truncation, keeping the newest rows and logging a
  warning when older rows are dropped. Unknown categories are dropped rather
  than bucketed into a catch-all section, and rendered items now show the
  fact itself instead of the internal dedup key. Per-file prompt token caps
  raised to match the wider spine (`@prompt_user_token_cap` 800 to 1500,
  `@prompt_memory_token_cap` 1600 to 2000).
- Transactional DB migration v10 folds legacy memory rows forward in place:
  `project` / `environment` become `context`, `instruction` / `correction`
  become `directive`, and retired `episode` rows are tombstoned via
  `archived_at` (recoverable, not deleted). FTS triggers and the scope-key
  UNIQUE index are preserved across the migration.

### Changed — Memory Review Hygiene
- The daily memory reviewer prompt gains principle-level rules: write each
  value as a declarative fact about the user or their work (not a
  self-instruction), and on a correction replace or archive the existing row
  by id rather than appending a duplicate (latest statement wins). Review
  excerpts are now labelled as user-sent messages only (the agent's own
  replies are not shown) so a correction is not misread as a fresh fact.
- The per-turn memory prompt now logs a warning when rows are dropped to fit
  the char/token cap, replacing the previously silent eviction.

### Changed — Observability (fermix_opik in umbrella)
- `apps/fermix_opik` joined the umbrella (moved in from `fermix-plugins`
  per M8 §14.3) and is inert until `FERMIX_OPIK_ENABLED`. Background
  `memory_reviewer` writes are now observable: each durable op emits
  `[:fermix, :memory, :write]` via `ReviewTools`, threading
  `session` / `channel` / `chat_id` / `parent_session` through `Reviewer`,
  routed as a `tool_exec` span and aggregated in `fermix_opik` (point
  `memory_write` span + `thread_id` backfill so reviewer runs correlate by
  thread even after the parent turn closes).

### Changed — Secrets (Profile-scoped keychain)
- Keychain secrets are now scoped by an optional `[fermix_core] profile`
  (default `general`) so two installs on one machine (e.g. `~/.fermix` and
  `~/.fermix-dev`) no longer share one keychain entry per secret and resolve
  each other's tokens — a collision that surfaced as a Telegram 409 Conflict
  with both pollers on one bot. `general`/unset keeps the bare
  `fermix:<ENV>` coordinate (existing installs need no migration); a named
  profile uses `fermix:<profile>:<ENV>`. The profile is read from the
  snapshot being resolved/saved (correct at boot, before app env is
  populated) and threaded through `SecretStore` into `SecretWriter`, and is
  wired through the config parse/persist/dump/apply round-trip.

### Changed — Setup UI & Branding
- Setup wizard and operator console retheme: pitch-black/white/grey surface
  with a single Fermix-blue (`#2b5cff`) accent across the daisyUI light/dark
  tokens, shared verbatim by `/setup` and `/`. Dark theme darkened toward
  pitch black (base-100 14%->9%, surfaces and hairline borders lowered
  proportionally). The green-screen-removed ghost mascot and an inlined
  currentColor wordmark replace the old green logo; `fermix_wordmark` is
  promoted to shared `CoreComponents` and used in setup and homepage headers
  (drops the "Fermix" eyebrow, "Agent runtime ready", and "Guided
  onboarding" copy). New monochrome app-icon favicon (256px `favicon.png` +
  multi-res `favicon.ico`, black rounded tile / white ghost) replaces the
  blue tile.
- OAuth integrations in setup replace the always-visible
  client-id/secret/port boxes with a Connect/Edit modal. Google
  (multi-plugin) keeps a shared client row; single-plugin providers
  (GitHub/Notion/X) render as one card like Obsidian with the OAuth client
  folded in. Form panes gain an "Unsaved changes" hint.

### Changed — Release / CI
- 0.3.0 release line: umbrella + `fermix_core` / `fermix_channels` /
  `fermix_web` / `fermix_nif` bumped to 0.3.0 (started as `0.3.0-beta`,
  `-beta` dropped at finalize; `fermix_opik` keeps its own 0.1.0
  lifecycle). CI now runs compile/format/credo/test on `release/**`
  branches, not just main/dev. `release.yml` publishes pre-release tags
  (SemVer `-` segment, e.g. `v0.3.0-beta`) as GitHub pre-releases and skips
  the Homebrew tap bump so a beta never marks itself Latest or promotes into
  the brew formula; stable tags are unchanged.

### Removed — Provider Expansion (M12)
- `together` / `groq` accepted-but-unroutable provider strings (no resolver
  ever existed; OpenRouter covers those vendors' models).

### Removed — Model Catalog
- `claude-opus-4-7` (display "Claude Opus 4.7") dropped from the Anthropic
  model catalog and its max-output map; the selectable Anthropic models are
  now the 4.8 line, and test fixtures pinned to 4.7 move to
  `claude-opus-4-8`.

### Removed — Secrets (Telegram env overlay)
- Removed the `TELEGRAM_BOT_TOKEN` env overlay from `runtime.exs`. The bot
  token is a config-owned secret, and a stray exported var could shadow
  every install's per-config token (an env-beats-config fallback); it now
  resolves only from `config.toml`. Telegram readiness remediation now
  points operators at `fermix setup` / `config.toml` instead of the removed
  env var.

### Fixed — Provider Expansion (M12)
- Cron jobs now fire in the job's own timezone (DST-aware via the `tz` dep)
  instead of UTC, and unknown zones are rejected at creation. `fermix
  doctor` validates routing `subagent_model` / `cron_model` against the
  catalog, ChatCompletions threads `reasoning_effort` onto the request body
  and call telemetry, and the jobs runner records `route_used` from the
  already-resolved route (a second resolution that could re-raise and strand
  the run on the failure path is gone). `OAuthProvider` redacts
  `client_secret` on inspect and the secret temp dir is created `0700`.

### Fixed — Mistral Provider
- ChatCompletions now omits the `content` key (rather than sending an empty
  string) on assistant messages that carry `tool_calls`. Mistral's strict
  validator 422s on empty-string `content` alongside `tool_calls`; the
  omission produces one wire shape valid on Mistral, OpenAI, OpenRouter, and
  Ollama. A real non-empty preamble is preserved.

### Fixed — Sub-agent & Cron Model Selection
- Saving a provider in setup no longer promotes the edited provider to
  primary (model/effort previously wrote to the primary's block) — writes
  land on the edited provider, and only the first configured provider
  auto-promotes; others stay fallbacks until "Set primary". The api-key
  secret writers (`put_openai_secret` / `put_anthropic_secret`) no longer
  replace the whole `[fermix_core]` config with only `:providers`, which had
  wiped routing/personalization/etc. on api-key saves; both now delegate to
  the shared `put_provider_secret`.

### Fixed — Scheduled Agents (M4.11)
- Scheduled runs firing as the host wakes from sleep no longer fail
  permanently on a Finch pool-checkout queue timeout. The timeout is now
  classified as a typed `:connection_unavailable` transport error
  (deliberately excluded from `Providers.Failover` fallback kinds — it is
  terminal for a single route, so the cron runner owns recovery and re-runs
  with bounded exponential backoff). A new `FermixCore.Net.Readiness` runs a
  short, bounded TCP-connect probe to the run's primary route host before
  the first model call, gated by `[fermix_core.jobs]
  network_readiness_enabled` (default true) and skipped when the run has no
  route host.
- Wake-from-sleep pool-timeout recovery is now provider-agnostic:
  `Jobs.Runner` recognizes the bare Finch `%RuntimeError{}` returned by the
  non-Codex adapters (previously only the Codex adapter minted the typed
  `:connection_unavailable` the runner keys on, so cron runs on
  Anthropic/OpenAI/xAI failed permanently on the identical condition). Each
  newly started run also waits a capped startup delay (250ms per
  already-active run, ≤5s) before its first network call so a batch of jobs
  due in the same minute doesn't check out HTTP connections all at once, and
  channel delivery retries with bounded backoff on the same transient pool
  timeout (a checkout timeout never sent, so the retry can't duplicate).

### Fixed — Memory Review Hygiene
- The background memory reviewer no longer persists the agent's own behavior
  or one-off exchanges as durable memory. It previously minted safety
  refusals as `directive` Working Rules and one-shot Q&A answers (e.g. a
  FizzBuzz answer) as `context`. The reviewer prompt restores the
  anti-inference clause and skip-list named by provenance: the agent's own
  refusals and guardrail rules, the substance of a declined or
  instruction-overriding request, and one-shot answers the user did not ask
  to keep are no longer saved. The `directive` category is tightened to a
  standing rule the user set, never the agent's own defensive stance.

### Fixed — Plugin Distribution (M8 / M8.1)
- Connecting a not-yet-installed GitHub/Notion catalog card flashed "Save a
  <Provider> OAuth client first" with no form to do so — the OAuth client
  forms were derived only from installed plugins and catalog entries did not
  carry the auth provider. `auth_provider` now flows end to end (sync script
  -> seed -> `Index.parse` -> `Catalog.available_entry` -> card), and the
  provider client form renders for catalog-only `oauth2` providers.
- HTTP-rail plugins no longer reject stringified object/array params. LLMs
  serialize freeform object/array tool args as JSON strings, which
  `ParamSchema`'s `is_map` / `is_list` checks rejected (e.g. Notion
  create-page "invalid parameter: parent"). A JSON-string value is now
  decoded to a map/list when the param is declared `object` / `array` and
  the string decodes to that type; otherwise it is left untouched so
  `check_type` still fails loud — a single deterministic path with no
  fallback.

### Fixed — Resilience (Un-encodable tool output)
- Tool output containing invalid UTF-8 (e.g. a `0xF3` byte from a scheduled
  run, a Latin-1 file read, or raw command bytes) no longer crashes the run.
  The text agent loop scrubs every captured tool result through
  `String.replace_invalid/1` at the single provider-agnostic seam
  (`AgentLoop.execute_tool_calls/2`) so invalid bytes become U+FFFD and the
  request body stays JSON-encodable across all providers; the Realtime voice
  run-type's separate dispatcher (`Realtime.ToolBridge.execute_call/2`),
  which never passed through the text path's sanitizer, now deep-scrubs the
  binary leaves of the whole result map before `Jason.encode!/1` so an
  invalid byte can no longer crash a live `SessionServer` turn.

### Fixed — Resilience (Trace encoding never crashes)
- The `Trace` GenServer no longer crashes on un-encodable trace content. It
  previously `Jason.encode!`'d each entry raw, so invalid UTF-8 in captured
  tool output or a PID/ref/struct with no encoder raised inside
  `handle_cast` — and because `Trace` is a `rest_for_one` ancestor of
  `MainAgent` and the job supervisors, that crash cascade-restarted them and
  could take down in-flight runs. Encoding is now defensive at the boundary:
  invalid UTF-8 in binary leaves is scrubbed and retried, still-unencodable
  entries are dropped-with-log (rescuing exactly the JSON-encode exception
  classes), and `json_safe/1` is hardened so a struct in telemetry metadata
  can no longer crash `Map.new` in the emitting process and permanently
  detach the telemetry handler.

### Fixed — Resilience (Finch pool exhaustion)
- A starved Finch connection pool no longer crashes an agent turn. On a
  checkout queue-timeout Finch reraises a `RuntimeError` ("unable to provide
  a connection within the timeout due to excess queuing") rather than
  returning an error tuple, so a transiently starved pool (e.g.
  api.telegram.org via the typing indicator) aborted the whole turn,
  surfacing only as the generic "I encountered an error processing your
  message". `Net.HttpClient` now wraps the request in `run/2`, rescuing that
  pool-exhaustion `RuntimeError` and returning it as the
  `{:error, Exception.t()}` its `@spec` already promises — fixing the one
  request instead of the calling process across every caller (typing, sends,
  provider calls, plugins, all channels). Pool exhaustion is deliberately
  not retried; genuine programming errors still crash loud.

### Fixed — FermixPet (macOS voice companion)
- FermixPet `.app` is now signed with a stable self-signed identity
  (auto-created if missing, fails loud with no ad-hoc fallback) so the
  microphone TCC grant keeps matching across rebuilds — previously ad-hoc
  signatures changed cdhash on every build, silently revoking mic capture
  and dropping the call back to idle. The SwiftPM resource bundle is staged
  under `Contents/Resources` for a codesign-valid layout, and
  `FermixPet.icns` is regenerated from the app-icon PNG so the system mic
  indicator and Finder match the dock icon.

### Fixed — Telemetry / Opik export
- Opik no longer exports near-empty traces during `mix test`.
  `FERMIX_OPIK_ENABLED=1` in the developer shell switched the exporter on
  inside `:test` because the sibling `fermix_opik` umbrella app booted there;
  `FermixOpik.enabled?/0` now gates on the compile-time env
  (`@compiled_env != :test and enabled_by_flag?()`), so the flag can never
  turn export on inside a test run. Compile-time capture stays release-safe.

### Fixed — Setup UI & Branding
- Setup flash-banner text now adapts per theme (`text-error` / `text-success`
  instead of `*-content`, which was invisible on the faint tint);
  `set_primary` resets the sub-agent model to same-as-main and is confirmed
  for OpenRouter/Ollama; the confusing empty-catalog line is dropped and the
  topbar uses the brand blue. Fixed the OAuth modal's missing gap between the
  redirect-port field and the Save button.

### Security — Plugin trust-boundary containment
- Three plugin/sandbox containment fixes from the dual-repo security review.
  `Sandbox.PathPolicy` now resolves each path component to its real on-disk
  case (`real_case/2`) so a case-variant like `~/.SSH` can't slip past the
  protected-path check on case-insensitive filesystems (macOS) while still
  landing on the real `~/.ssh` inode — the path checked is now the path
  touched, with exact matches winning on case-sensitive filesystems.
  `Plugins.Registry.validate_runtime_block` now requires a bare executable
  name (no whitespace, `/`, or `..`) so a `vendored: true` MCP command can't
  `Path.join`-escape its `bin/<target>/` dir to a host executable like
  `/bin/sh`, and `validate_asset` bounds the manifest asset path inside the
  plugin dir via `Path.safe_relative`, refusing `../` escapes before the
  read.

## [0.2.3] - 2026-06-08

### Added — FermixPet (macOS voice companion)
- FermixPet build script gains an `install` mode
  (`./script/build_and_run.sh install`): builds the SwiftPM `.app` bundle in
  release configuration under `~/Library/Caches/io.tezra.FermixPet` and
  installs it to `~/Applications/FermixPet.app`, with `FERMIXPET_*` env
  overrides for cache/stage/install paths and configuration. Docs now point
  operators at installing the app rather than running it from source.

### Changed — Setup UI
- Provider and Channels setup tabs reworked into a card selector that loads a
  single "Configuring …" form. Provider cards carry the primary flag (Save
  sets primary; a "Set primary" action flips it among configured providers);
  channel cards are a plain selector with no primary concept. "Apply &
  restart" now returns to the tab you were on (mount honors `?tab=`,
  apply_restart push_patches the active tab across the restart) instead of
  bouncing to the first incomplete tab.

### Fixed — Setup UI
- Saving a Realtime API key no longer steals the primary flag from an
  explicitly chosen provider: the Realtime key shares the OpenAI provider key
  slot, but a realtime-only save no longer counts as a provider-configuring
  promotion trigger.

### Fixed — FermixPet (macOS voice companion)
- FermixPet now fully releases the microphone on call end, disconnect,
  peer-close, and error so macOS clears the mic privacy indicator as soon as
  the local call ends — teardown is unified through a single
  `shutdownAudio()` (calls `audio.shutdown()` and zeroes `audioLevel`)
  instead of leaving the engine/tap warm between calls. Right-click "Quit
  FermixPet" now routes through `quitApplication()`, shutting audio and the
  socket down before terminating.
- The Realtime voice session no longer reports "listening" before the
  provider is ready. `Realtime.SessionServer` tracks a `provider_ready?` flag
  and waits for the upstream `session_updated` event before starting timers
  and notifying the companion to listen, so the pet's listening state matches
  when the provider can actually receive audio (also reset across reconnect
  attempts).

## [0.2.2] - 2026-06-07

### Fixed — Setup (Web wizard OAuth)
- Completing a provider's OAuth in the web setup wizard now persists it as
  primary immediately. Previously the OAuth-completion handlers wrote the
  credential but never the primary flag, so a connect-then-probe flow left no
  config pointer and the end-of-setup probe fell back to its `:openai`
  default and reported "provider not configured" (re-saving the provider step
  fixed it) — worst for `openai_codex`, whose completion persisted no config
  at all, while xAI/Anthropic wrote `auth_mode` but no primary. New
  `Wizard.mark_primary/1` (mirrors `set_provider_auth_mode/2`, reading the
  current snapshot so it can't clobber the auth_mode the login flow just
  wrote) routes all three OAuth-completion handlers (codex/xai/anthropic)
  through it; idempotent with a later save.

## [0.2.1] - 2026-06-07

_Maintenance release — hermetic CI test fixes; no user-facing changes._

## [0.2.0] - 2026-06-07

### Added — Providers (xAI & Anthropic)
- xAI (Grok) and Anthropic (Claude) as first-class providers with API-key and
  OAuth auth modes: route resolver, readiness, doctor, CLI wizard, and web
  setup support; model catalog + reasoning-effort vocabularies; env overlays
  in `runtime.exs`; and `fermix auth login --provider xai|anthropic`.

### Added — Primary-Provider Selection & Failover
- Per-provider `primary` flag in config selects the main provider (replacing
  the legacy `[fermix_core.agent] provider` key, migrated forward; multiple
  primaries are a surfaced config error). `Providers.PrimaryConfig` owns the
  migration and `mark_primary_provider/2` gives the wizard radio semantics
  with auto-promotion of newly configured providers. Status, doctor, jobs,
  and agents all consume one ordered route chain [primary | configured
  fallbacks].
- Bounded provider failover: `Providers.run_chain/3` is the one executor used
  by the agent loop's initial chat, compaction (auto/preflight/`/compact`),
  and memory review, with eligibility keyed on `Providers.Error` kinds (OAuth
  residual 401/refresh-failures eligible; API-key auth and OAuth 403
  terminal). A `[:fermix, :provider, :failover]` telemetry event is emitted
  per transition, and `fermix doctor` lists fallback availability.

### Added — Work-Control Commands & /ultra
- Gateway work-control command surface: `/stop` (owner-only emergency halt of
  active and pending turns, leaving scheduled jobs and voice untouched) and
  `/background`, `/bg`, `/tasks` for detached work via `Gateway.WorkRegistry`
  + `Gateway.BackgroundSupervisor`, with `FermixCore.Agents.BackgroundRun`
  providing work-scoped history/memory isolation. `Commands.Registry.validate!/0`
  now guards against duplicate command names/aliases at boot.
- `/ultra` exhaustive run-mode: an `/ultra <prompt>` turn tags
  `run_profile: :ultra` to widen the `subagents` caps (`subagent_mode: :ultra`)
  and prepend an exhaustive-mode addendum so workers nest under the parent
  trace. Began as a fixed-topology `UltraOrchestrator` (decompose -> fan-out
  -> verify -> synthesize) and was folded into a run-mode of the normal agent
  turn before release.

### Added — Telemetry Contract
- Telemetry contract with shared emitters (`Tools.Telemetry`,
  `Providers.Telemetry`, `Jobs.Telemetry`), `session_id` correlation across
  agent/provider/tool events, and content-capture gating via
  `FERMIX_TRACE_CONTENT` / `FERMIX_OPIK_ENABLED`; documented in
  `docs/TELEMETRY_CONTRACT.md`.

### Added — Channel Streaming
- Live streamed replies into chat channels via
  `[fermix_channels.<name>] streaming = "off" | "draft" | "block"` (off
  default). Draft mode edits one message in place (~1 Hz, 30-char open
  threshold, 300-edit cap); block mode posts each completed model thought
  (and reasoning-summary heading) as its own message with fence-safe
  paragraph chunking. A new channel-agnostic `Gateway.DraftStream` engine
  drives it over an optional open/edit/seal/discard_draft + stream_capability
  channel contract (Telegram implements draft editing; block mode rides
  ordinary sends on every channel). The Codex `SSEParser` gains a
  `delta_callback` emitting `{:text_delta, ...}` / `{:text_done}` /
  `{:reasoning_done, summary}`, and `AgentLoop` / `TurnRunner.run/4` thread a
  `stream_callback`. Emits `[:fermix, :channel, :stream]` telemetry
  (session-correlated, ttfd) and `fermix doctor` warns on draft without the
  channel capability.

### Added — Prompt (Current date)
- A fresh "Current date" system note is injected ahead of conversation
  history on every main turn (`TurnRunner`) and scheduled job run
  (`Jobs.Runner`) via the new `FermixCore.Prompt.CurrentDate` module, sourced
  from the personalization timezone. Date-only by design so the provider
  prompt-cache prefix stays stable (agents call `run` for the precise time).
  Setup now defaults the timezone to `America/New_York` (CLI wizard + web
  form) so the stamp always has a zone, and the `FERMIX.md` guidance that
  told the agent to shell out for the date is softened.

### Added — Setup Secrets (Secure-on-save)
- `FermixCore.Setup.SecretStore` consolidates the three duplicated snapshot
  path-walkers (ConfigStore, SecretMigration, Wizard) and owns
  secure-on-save: any plaintext value registered in `SecretPaths` is written
  through `SecretWriter` and persisted as a `@keyring` sentinel when a writer
  is available. Rotation over a `@keyring` sentinel rewrites the keyring
  instead of silently dropping the new value; writer-less hosts keep
  already-persisted plaintext unchanged while new/changed secrets still fail
  loud. `GOOGLE_OAUTH_CLIENT_SECRET` is registered in `SecretPaths`.

### Added — Browser Runtime
- Native first-party CDP browser runtime (`FermixCore.Browser.*`) replacing
  the agent-browser CLI wrapper: OTP-supervised Chrome driven over the
  DevTools Protocol, per-conversation scoped profiles (hashed
  `conversation_key`) with a live-instance cap, LRU eviction, and idle-sweep
  reclamation, re-attach to an already-running Chrome for a profile (fixes the
  "Opening in existing browser session" failure after daemon restart),
  guaranteed teardown (terminate + SIGTERM/SIGKILL of the Chrome os_pid,
  orphan reaping, launch-failure cooldown), an SSRF URL policy (incl.
  IPv4-mapped/compatible/NAT64 IPv6), accessibility-first snapshots with
  depth budgeting and editable-field refs, plus screenshots, actions,
  downloads, dialogs, redacted cookies, and PDF. All timeouts/limits live in
  `Browser.Config`; per-action latency and Chrome stderr land in
  `tool_exec` / `agent_event` traces. Adds a `browser_guidance` skill and a
  `browser` workspace path.

### Added — Agent Iteration Limits
- `FermixCore.Agents.IterationLimits` adds bounded iteration caps for
  agent-loop entry points (`interactive` / `subagent` / `scheduled_job_default`,
  default 100), read from `[:fermix_core, :iteration_limits]`. Hitting the cap
  now yields a clear "hit the investigation step limit" channel reply instead
  of the generic error.

### Added — Google Plugins (Write tools)
- Write tools across the Gmail, Calendar, and Drive first-party plugins on a
  graceful-error foundation: a ready plugin's tools register regardless of
  granted scope, and a call-time pre-flight check returns reauthorize guidance
  before any API call instead of the tool silently disappearing. 403s are
  classified by Google's reason (scope-insufficient, file-permission,
  organizer-only, rate-limit) so the message says what actually failed. Gmail
  (+gmail.compose, +gmail.modify) adds reply_to_thread, create/send draft,
  modify labels, trash/untrash, create label, and surfaces
  Message-Id/References for threaded replies; Calendar adds update, delete,
  RSVP, and move; Drive adds create folder, upload, rename, move, and copy.
  Destructive ops are `read_only: false` with prompt-driven confirmation in
  each plugin SKILL.

### Changed — Setup Hardening
- Provider `auth_mode = "oauth"` now persists through config instead of being
  normalized to nil (which silently fell back to API-key mode). Setup also
  suppresses the Codex token import when a non-codex provider is explicitly
  selected, and wires xAI through the web setup provider form
  (parse/normalize/models + reasoning-effort field guard).

### Changed — Provider Error Handling
- Provider errors are normalized through a typed `Providers.Error` (kind +
  stage, OAuth tagging): Codex/OpenAI retry and error surfacing hardened, a
  dead/missing `TokenManager` degrades to a failover-eligible auth error
  instead of crashing the loop, and `TurnRunner` no longer string-matches on
  Codex error copy.

### Changed — Web Search
- `web_search` degrades once to the keyless DuckDuckGo backend when a
  configured non-DuckDuckGo backend (Brave/Exa/Tavily/...) hard-errors on a
  service condition (out of credits/HTTP 402, provider errors, rate limits,
  transport failures, response-schema drift), so a dead paid provider no
  longer breaks web research. The degrade is loud — a warning log plus
  `degraded` / `primary_backend` / `fallback_reason` in the result metadata
  (carried on the tool trace). Auth/missing-key and bad-query errors are not
  degraded; the fallback is bounded to one attempt and DuckDuckGo's own
  failure surfaces the original backend's error.

### Changed — Google Plugins (Drive scope)
- The Google Drive plugin now requests the full `drive` scope (search keeps
  `drive.metadata.readonly`) to enable create/edit/organize/copy operations.

### Changed — Observability (fermix_opik gating)
- The `fermix_opik` exporter path dep is gated behind a single
  `FERMIX_OPIK_ENABLED` switch (and scoped to `only: [:dev, :prod]`), so
  default/standalone/CI builds omit it (lock unchanged) and `mix test` never
  bundles the exporter or ships test fixtures to a live Opik project. The same
  flag gates the runtime content-capture default.

### Changed — CLI / provider tidy
- `cli/chat_command` stringifies atom error reasons in the JSON envelope;
  `main_agent` maps `FermixCore.Providers.XAI.Responses` to `:xai`;
  `jobs/runner` derives the provider atom from `ModelCatalog` (dropping
  per-provider clauses). Default and test CDP port ranges shifted in
  `Browser.Config`.

### Fixed — CLI auth (route activation)
- `fermix auth login --provider xai|anthropic` now also sets that
  provider's config `auth_mode = oauth` (and `fermix auth logout` reverts
  it to `api_key`). The stored OAuth token was previously inert —
  `RouteResolver` keys on `[providers.<p>].auth_mode`, so a freshly
  connected provider stayed in API-key mode until the operator flipped it
  by hand. Login and logout now keep the token and the route in sync.

### Removed — Google Plugins (Trimmed surface)
- Dropped the Calendar quick-add (`google_calendar_quick_add_event`) and the
  Drive share/trash/delete (`google_drive_share_file`,
  `google_drive_trash_file`, `google_drive_delete_file`) tools from the Google
  plugin manifests and skill docs; `response_status` is now constrained to an
  enum.

### Fixed — Long-lived HTTP connections
- Supervised shared Finch pool with a 15s idle cap so long-lived daemons drop
  load-balancer-RST'd keep-alive sockets instead of failing requests with
  `:closed`.

### Fixed — OAuth Loopback Catcher
- The loopback OAuth callback server no longer aborts the flow on the first
  non-callback connection (surfaced as "Grok sign-in failed:
  :malformed_request" on xAI's cold ephemeral port). `Auth.OAuthFlow` now
  accumulates the full request line (bounded by per-read timeout, 64 KB cap,
  and overall deadline) and skips junk/segmented connections until the real
  callback or the deadline; genuine callback errors (state mismatch, missing
  code, OAuth error param) stay terminal.

### Fixed — Channel Streaming
- Hardened streaming against mid-stream Codex retries: block mode no longer
  crashes (negative `binary_part`) when a dropped connection is retried with a
  fresh SSE parser and cumulative text restarts shorter than the consumed
  offset (`unsent/1` clamps and resumes once the stream regrows); draft-mode
  seal retries on Telegram `retry_after` are now bounded (~11 s worst case) so
  they no longer outlast the engine's 15 s seal timeout, falling through to
  the designed discard-and-redeliver recovery instead of orphaning the draft
  and duplicating the answer.

### Fixed — Setup Secrets (Secure-on-save)
- Sandbox env command sources now reuse the writer's own lookup args
  (`-a fermix -s fermix:<ENV>`) instead of the old inline `-a $USER -s <ENV>`,
  which could never find what `put()` stored.
- secure-on-save now writes only on a positively-confirmed rotation, never on
  a keychain read failure. `keep_or_rotate` previously lumped a genuine
  rotation in with a locked/timeout/unavailable read under one branch that
  escalated to a write, so a transient read failure on an already-`@keyring`
  secret could error the whole `save_snapshot` and couple unrelated config
  commits (model_routing_config, `/sandbox grant`, plugin enable) to keychain
  health. A read error now keeps the sentinel and lets the save succeed; the
  rotation is re-detected once the keychain is reachable.

### Fixed — Daemon control socket
- Daemon control-socket replies larger than the inet line buffer (e.g.
  `/ultra` output, the enlarged `self_knowledge` skill body pushing
  `skills_view` past ~9 KB) no longer truncate mid-stream into a
  `Jason.DecodeError`. First fixed in the client with a bounded `recv_line`
  loop accumulating chunks to a trailing newline (4 MB cap, fails loud as
  `:response_too_large`), then the framing was switched from `{:packet, :line}`
  to `{:packet, 4}` length-prefixing on both ends so a reply arrives whole,
  with `{:packet_size, 4MB}` bounding each frame (a skewed/corrupt header
  fails instantly with `:emsgsize` instead of buffering to timeout) and decode
  failures reporting `response_decode_failed`.

### Fixed — Gateway queue
- The gateway queue no longer mislabels ordinary turns as `:crashed` under
  load. `Process.monitor` ran after `Task.Supervisor.start_child` returned, so
  a near-instant turn could exit before being monitored, yielding
  `{:DOWN, …, :noproc}` mapped to `:crashed`. The task now parks in
  `await_run_signal` and the queue releases it only after monitoring — closing
  the race (185/200 turns mislabeled on the old code, 0 with the fix).

### Fixed — Path resolution (empty FERMIX_HOME)
- A blank `FERMIX_HOME` (`""`) is now treated as unset across path resolvers.
  It was truthy in Elixir, so `get_env() || default` did not fall back and
  `fermix_home` resolved to `""`, making every workspace path cwd-relative
  (booting from the repo root seeded bundled skills into `./skills` instead of
  `~/.fermix/skills`). Blank is now coerced to unset in the canonical
  `ConfigStore.fermix_home/0`, `runtime.exs`, and the two sandbox resolvers;
  CLI/service route through the canonical one.

### Fixed — Service unit (Homebrew)
- The launchd/systemd service unit is now pinned to the stable Homebrew
  `<prefix>/bin/<name>` symlink instead of the versioned Cellar path, so
  `brew upgrade` (which removes the old Cellar path) no longer strands the
  service unable to start. Non-Cellar paths pass through unchanged.

### Fixed — Audit hardening
- Audit-hardening sweep: `Sandbox.Env` and `SecretWriter.MacOS` run helpers
  through `CommandRunner` (a timeout now kills the OS child; a missing helper
  is an error tuple instead of a crash through the linked Task);
  `Auth.Store.read` returns `{:error, {:invalid_auth_entry, provider, reason}}`
  instead of raising through its tuple spec; provider adapters return
  `ProviderError.auth` tuples for credential-preflight and token-server
  failures, so a missing/expired credential becomes a channel reply instead of
  a silently crashed turn; `file_read` validates `offset` / `limit` as
  positive integers (`offset 0` previously dropped the last line), streams
  line ranges, and caps output at 100 KB with a continue-from-offset marker;
  the realtime voice socket probes for a live listener before unlinking its
  path (mirroring the daemon control socket); and `/health/live` +
  `/health/ready` report `Application.spec` versions instead of a hardcoded
  `0.1.0`.

### Security — Log parameter filtering
- Phoenix request-log parameter filtering now redacts `password`, `secret`,
  `token`, `access_token`, `refresh_token`, `bot_token`, `verify_token`,
  `_csrf_token`, and `t` so credentials no longer land in logs.

## [0.1.0] - 2026-05-30

### Added — Subagents Orchestration
- `subagents` built-in: the main agent can spawn one or more temporary
  generic subagents for independent delegated work, run them concurrently
  up to a bounded cap, and synthesize the structured results. Each worker
  inherits the parent turn's trust and runs with the parent's policy classes
  minus `:read_write` (read, web, MCP/plugins, skills, sandbox-bounded
  `shell`; no direct local/Fermix-state writes), with its `tool_context`
  sanitized so it cannot reply on Fermix's channel or reach the parent's
  memory. Recursive fanout is bounded by a `subagent_depth` guard.
- `skill_list` built-in so a subagent can discover installed skills on
  demand before delegating to one via `skill_run`.
- `FermixCore.Agents.WorkerRun`: shared one-shot worker lifecycle
  (spawn → run → timeout → normalize → stop) reused by `skill_run` and
  `subagents`. `FermixCore.Capabilities.Registry.default_policy_classes/1`
  exposes a trust's baseline class set.

### Removed
- The `delegate` built-in and the `routing.delegate_model` config key
  (and its `model_routing_config` surface). Delegated work now goes through
  `subagents` (general, tool-using) or `skill_run` (named skill); existing
  `delegate_model` config entries are ignored.

### Added — M7.1 (Conversation Lifecycle)
- Per-model context-window catalog and `[fermix_core.compaction]` threshold
  config for automatic post-turn conversation compaction.
- Shared channel command surface for `/compact`, `/new`, `/clear`, `/help`,
  and `/whoami`, routed through `FermixChannels.Dispatcher` before agent
  delivery.
- Per-channel owner authorization for mutating commands via
  `owner_user_id` and optional `command_allowlist`; CLI remains implicit
  owner.
- `fermix doctor` now reports the active compaction trigger point and
  channel command-owner configuration.

### Fixed
- Background memory extraction no longer times out at 5s when the agent
  provider is Codex (or any reasoning model). `[fermix_core.memory]
  extraction_timeout_ms` default raised from `5_000` to `90_000`,
  round-tripped through `ConfigStore` and exposed as an optional
  `extraction_timeout_ms` wizard prompt. The Codex `:timeout` transport
  message no longer hardcodes "60s" and now points operators at the
  `extraction_timeout_ms` knob alongside `req_options[:receive_timeout]`
  and `reasoning_effort`.
- `Providers.OpenAI.Codex` no longer hangs on long Codex turns and surfaces
  `:closed` from the daemon. The SSE response is now consumed via a `Req`
  `:into` callback that feeds `SSEParser` incrementally; `receive_timeout`
  (60s) measures gaps between chunks rather than the whole turn, and a
  5s `connect_options[:timeout]` bounds TCP/TLS handshake. Bare
  `Req.TransportError` reasons (`:closed`, `:timeout`, `:econnrefused`)
  are mapped to actionable operator-readable messages instead of the raw
  atom. `SSEParser` gains `new/0`, `feed/2`, and `finalize/1` for
  incremental parsing; the existing `parse/1` is preserved.
- New `FermixCore.Net.HttpClient.request/2` wraps `Req.request/1` with a
  single retry on stale-pool transport errors (`:closed`,
  `:econnrefused`). Fixes the "first message after macOS sleep fails,
  second works" failure mode: Finch's pooled HTTPS connections to
  long-lived API hosts (api.openai.com, chatgpt.com, api.telegram.org,
  discord.com, slack.com, graph.facebook.com) go silently dead during
  long idle periods and the first request hits an RST'd connection.
  `:timeout` deliberately does NOT retry — a slow server should not be
  hammered. All four OpenAI provider POST sites (`Providers.OpenAI`,
  `Providers.OpenAI.Responses`, `Providers.OpenAI.ChatCompletions`,
  `Providers.OpenAI.Codex`), the Whisper transcription POST
  (`Transcription.OpenAI`), and the five channel-send POSTs (Telegram
  `sendMessage` + `sendChatAction`, Discord, Slack, WhatsApp) now route
  through it.

### Added — M7 (Advanced Tools)
- Built-in catalog expanded with `file_edit`, `glob_search`, `content_search`,
  `git_read`, `git_write`, `web_fetch`, `web_search`, `skill_create`,
  `model_routing_config`, and `tool_help`.
- Capability metadata schema for built-ins: `when_to_use`, `examples`,
  `failure_modes`, `requires_setup`, and `category`. Runtime prompts now
  generate a compact built-in catalog from this metadata.
- `FermixCore.Net.Guard` for public HTTP(S)-only outbound validation and
  sensitive-header redaction, plus `FermixCore.Tools.HtmlText` for
  markdown-light HTML extraction.
- Keyless `web_search` using DuckDuckGo HTML results with loud
  `rate_limited` and `parser_changed` failure contracts.
- Core `self_knowledge` skill explaining Fermix architecture, built-ins,
  skills, jobs, memory, and channels.
- Starter eval fixtures for M7 built-in tool-selection checks and the
  self-knowledge skill.

### Changed — M7
- `ConfigStore` now round-trips `[fermix_core.routing]` for local routing
  preferences used by `model_routing_config`.
- Wizard-written `config.toml` now documents the built-in-tool vs skill
  distinction in comments.

### Added — M4.10 (Codex Parity & Provider Selection)
- `Providers.OpenAI.Codex` adapter now implements the full Responses
  tool-call lifecycle over SSE — `chat/3` posts `tools`, `parse_tool_calls/1`
  surfaces normalized calls, `continue/3` rebuilds `input = prior_input ++
  output_items ++ function_call_outputs` with the API-emitted `call_id`s.
  ChatGPT-Plus users (no API key) can now run skills, MCP tools, and
  built-ins through the agent loop end-to-end.
- Reasoning-effort plumbing across the Responses + Codex adapters and the
  resolver. `:none | :minimal | :low | :medium | :high | :xhigh` accepted
  in config and threaded through `RouteResolver.resolve!/1`.
- TOML config schema gains `agent.provider`, per-provider `default_model`
  and `reasoning_effort`. `Providers.ModelCatalog` defines the canonical
  per-provider model lists. `fermix setup` exposes `--provider`,
  `--default-model`, and `--reasoning-effort` switches; `Wizard.prompts/1`
  asks the same three questions interactively when no provider is yet
  persisted in `~/.fermix/config.toml`. A new `:model` wizard step shows
  up in `WizardState.step` once the provider check is satisfied but no
  provider is recorded. `SetupLive` displays the next step inline.
  Env-var overlays (`FERMIX_PROVIDER`, `FERMIX_DEFAULT_MODEL`,
  `FERMIX_REASONING_EFFORT`) layer on top of TOML values and survive
  round-trips through `ConfigStore.save_snapshot/1`.
- `Setup.Doctor.probe_provider/2` and `probe_active/1`: live ~$0.0001
  auth probes used by `fermix doctor --full` and the wizard finalize step
  to fail loud at config time. Probes classify into `:auth_scope_mismatch`
  (401/403), `:misconfigured`, `:server_error`, `:network`. Inject HTTP
  with `req_options: [plug: ...]`; OAuth bearer comes from `TokenManager`
  (override via `:token_server` for tests).
- `MainAgent.init/1` bakes `agent.provider` + per-provider `default_model`
  + `reasoning_effort` from config into `adapter_overrides`. Explicit
  `adapter_overrides: [provider: ...]` wins whole, so a runtime route to
  a different provider can't leak per-key config from the configured
  provider's block.

### Removed — M4.10
- The "tool calls not supported on Codex" caveat in the M4.9 design doc;
  M4.10 closes that gap. `Providers.OpenAI.Codex` is the explicit
  `:openai_codex` route's adapter.

### Fixed — M4.10
- `Setup.Doctor.probe_provider/2` no longer crashes with `(EXIT) :noproc`
  when the CLI invokes `fermix doctor --full` against an OAuth-mode
  provider. The CLI process intentionally halts before starting the OTP
  supervision tree (no `TokenManager`, no `Memory.Repo`, no port bind),
  so probes that need a Codex bearer now return
  `{:error, {:misconfigured, ...}}` with a hint to run the probe from
  the daemon instead.

### Added — M4.9 (Unified Capabilities)
- Single `%FermixCore.Capabilities.Capability{}` shape for built-ins,
  skills, and MCP server tools. ETS-backed `Capabilities.Registry`
  serves the agent loop's hot path without a GenServer round-trip.
- `Providers.Adapter` behaviour with deterministic `for_route/1`
  routing on `(provider, model, auth_mode, base_url)`. OpenAI Responses
  / Chat Completions / Codex extracted as separate adapters; Codex
  treated as its own `:openai_codex` provider.
- Skills surface as direct named tools — no `invoke_skill` meta-tool.
  Sub-agent trust gate: third-party skills cannot reach `:exec` /
  `:network` / `:external_api` capabilities; `allowed_tools` narrows by
  name on top of policy.
- MCP outbound integration via `hermes_mcp`. Per-server supervisor
  isolates faults; async discovery with exponential backoff so one bad
  server can't take down healthy peers. Tool name sanitization with
  SHA256 collision suffix and 64-byte truncation matches OpenAI
  Responses regex.
- Anthropic adapter scaffold (`Providers.Anthropic.Messages`) with full
  schema-translation coverage; `chat/3` returns `:not_implemented` until
  the OAuth + token-storage milestone lands. `provider:` accepted in
  skill frontmatter so per-skill provider overrides route end-to-end.

### Removed — M4.9 cleanup
- `FermixCore.Tools.Registry`, `FermixCore.Tools.Tool` behaviour, and
  `FermixCore.Tools.InvokeSkill` are gone. Built-in tool modules now
  implement `FermixCore.Capabilities.Builtin.Tool`. `Provider.chat_opts`
  no longer carries a `:tools` field — capabilities flow through the
  adapter, not provider opts.

### Fixed — M4.9 review
- `AgentLoop` now dispatches against the per-turn filtered capability
  map, not the full `CapabilityRegistry`. A capability filtered out by
  `policy:`, `trust:`, or `allowed_tools:` can no longer be invoked
  from the loop just because it's in the registry.
- `AgentServer` now threads `definition.policy` and `definition.trust`
  into `AgentLoop` opts. Sub-agent capability filtering finally fires:
  third-party skills are read-only by default, local skills get the
  broad-but-not-`:external_api` set, and main-agent root sessions stay
  unfiltered. Implements the §4.6.3 trust gate end-to-end.
- `Prompt.RuntimeSections.build/1` no longer crashes on a skill with
  `allowed_tools: nil` (the trust-default sentinel). Renders as
  `tools=default`.
- `RouteResolver` no longer auto-routes `auth_mode: :oauth` to Codex.
  Per design §4.8, default OpenAI OAuth users land on `OpenAI.Responses`
  (which supports tool calling); Codex is reachable only via explicit
  `provider: :openai_codex`. `OpenAI.Responses` accepts `:api_key`,
  `:access_token`, or a `:token_server` for the Bearer header.
- `MCP.Supervisor` now actually starts a `Hermes.Client.Base` +
  `Hermes.Transport.STDIO` pair per server with a `:command`. Pluggable
  via `:hermes_starter` so tests don't have to spawn real subprocesses.
  Per-server sub-supervisor is `:one_for_all` so a transport crash
  bounces the client and discovery process together.
- `SkillRegistry.sync_capabilities/3` refuses to evict an existing
  built-in (or MCP) capability with the same name. Boot order is
  reordered: a `BuiltinSeeder` runs as a supervised child between
  `CapabilityRegistry` and `SkillRegistry`, so built-ins land before
  any skill snapshot can race them.
- `priv/templates/agents.md.eex` no longer references the deleted
  `invoke_skill` tool.
- `MCP.Registry` ETS table is now derived from the GenServer name
  instead of a hardcoded module atom, so multiple registry instances
  (e.g., per-test setups) don't fight over a shared table.

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
  CI to open auto-bump PRs against `tezra-io/homebrew-tap`.

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
