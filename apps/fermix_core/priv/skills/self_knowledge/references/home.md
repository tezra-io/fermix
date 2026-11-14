# Home, roles and moves

The home (`FERMIX_HOME`) is the one copy of Fermix that is the primary: its
configuration, memory database, token file, file secret store, phone identity
bundle and device list, prompt files, skills, journals, workspace and installed
plugins. Everything else under the home belongs to the machine it is on. Only
the primary writes long-term memory; a phone or a desktop app is a client of
it, never a second writer.

## The primary epoch

- Each home carries a primary epoch (`mobile/primary_epoch`): 1 from its first
  boot as the primary, one more each time the home moves to another host or is
  restored from an archive. It never goes down, and creating the phone identity
  keeps whatever epoch the home already has. It also serves as the generation
  id of the home's store.
- A home from before the epoch existed gets 1 at its next boot as the primary;
  the primary boot is the one writer of the first epoch, and the phone identity
  reads it and never writes it.
- The phone handshake (`hello_ack`, `pair_approved`) and the desktop app's
  companion handshake (`server_hello`) announce it. Phones and desktop apps keep
  the highest epoch they have seen and refuse a lower one as a stale primary.
  Fermix refuses a client that has seen a higher epoch than its own with
  `stale_primary`, because that client has already met the engine this home
  moved to. The desktop handshake also names the engine's role; an engine in
  the device role announces its home's epoch but refuses no client for having
  seen a higher one, and an app never compares a device engine's epoch.

## Roles

- `[fermix_core.engine] role` in `config.toml`: `primary`, the default when the
  section is absent, runs the agent loop, its schedulers and every channel and
  is the one engine that writes long-term memory. `device` serves the desktop
  app on this machine: it starts no channel transport and none of the
  schedulers for jobs, reminders, open loops, cues, coding-run delivery, skill
  curation or meetings, and refuses every turn, and every slash command
  (`fermix ask "/history"` included), with "This engine runs in the device
  role; the primary is <where it went>." From the desktop app it also refuses,
  with the same sentence, everything that would read or write the retired
  copy itself: a cancel, a read receipt, an answer to a cue card, a page of
  history, a search and the lists (a linked desktop gets those from the
  server). A desktop with no link to its server any more refuses every cue
  method as "Fermix moved to your server, and this <Mac or computer> is no
  longer connected to it.", the error a linked one gets while its server is
  out of reach.
- A device-role engine makes no provider call and refreshes no token: it
  starts no token manager and no realtime voice (the voice socket is absent,
  so the app sees no connection rather than a refusal), it opens no database
  (its `memory.db` is the retired copy; computer history records into
  `device/history.db` and sends sittings to the server), and the management
  methods that sign in, sign out, import a login, probe a provider, list a
  provider's live models or run the network doctor answer that the engine
  runs in the device role. `fermix memory review --now` and `fermix memory
  restore` refuse the same way. On a home configured as a device or
  carrying the moved marker,
  `fermix auth login` and `logout`, `fermix plugins auth login`,
  `reauthorize`, `refresh` and `logout`, and storing or clearing the Anthropic
  setup token refuse with the same sentence and write nothing, and terminal
  `fermix setup` saves its answers but skips signing in, checking the model
  and probing the provider. The browser setup page refuses every sign-in,
  sign-out, Claude Code import, setup-token save, plugin connect or OAuth
  disconnect, notetaker sign-in, provider probe and live model listing with
  the same sentence.
- `candidate` is a fresh server waiting to become the primary through a move
  (below, "Enrollment, the candidate and the move"): it enrolls with the
  primary and waits, answers only `home.status`, and refuses every turn and
  method by name: "This engine is a candidate primary waiting for its move…".
- In the device role the Slack and WhatsApp webhook routes answer 503 and
  reach no channel, and health reports configured channels and voice as not
  started rather than degraded.
- `fermix health --json` and the full health report carry the role as `role`;
  the public `/health/ready` verdict stays status-only.

## Moving the home

- `fermix home export FILE` seals a stopped home into one archive under a
  passphrase the owner holds (at least 12 bytes, read from `--passphrase-file`
  or asked twice without echo). It refuses while the engine that owns the home
  is running, refuses a home that has no primary epoch, and refuses a home
  that carries the moved marker: a retired copy is never exported as a
  primary. The archive carries
  what makes the home the primary (configuration, the memory database, the
  token file, the file secret store, the phone identity bundle and device
  list, prompt files, skills, journals, the workspace and installed plugins)
  and leaves out what belongs to the machine: logs, traces, sockets, locks,
  sandbox grants, the dev plugin folder, `machine.toml` (its own settings),
  browser profiles, the iMessage cursor, coding-harness
  spools, downloaded models and helper binaries, and the moved marker.
  Secrets kept in the OS keyring are not in the home and do not travel in an
  archive; export and import both say how many must be entered again on the
  new host. (The Always On move below does carry them.)
  `fermix home export FILE --mark-moved --to TEXT` marks the home moved as
  soon as the archive is sealed, so a service that relaunches the engine
  cannot start the old home as the primary again.
- `fermix home import FILE --into ROOT` restores an archive into an empty
  directory as the next primary, one epoch above the archived home. Settings
  in `config.toml` that named the old home's path are moved to the new one and
  the keys are named; paths stored inside the memory database are not changed.
  Importing also leaves coding-agent consent with the computer it was given on, moves a keyring-mode home to the file store on
  a host whose keyring does not answer that it is available (a check that
  timed out counts as none, and is logged; macOS keeps its keyring),
  and names the
  settings that still hold paths outside the old home and the installed
  plugins built for another OS, which `fermix plugins install NAME`
  reinstalls. It never marks the old home moved. A home in a newer format
  than this Fermix reads is refused, whichever Fermix wrote it, and nothing
  is written: update Fermix first.
- `fermix home mark-moved --to TEXT [--json]` writes the `moved.json` marker
  once, with the home's current epoch, while Fermix is stopped; it refuses by
  name when Fermix is running (`daemon_running`), when the home has no primary
  epoch (`epoch_absent`) and when the home already moved (`already_moved`). A
  home that carries the marker refuses to start as the primary, naming where it
  went, when and at which epoch; it runs only in the device role, or is
  replaced by an archive restored into an empty home.
- The order of a move: stop Fermix here; `fermix home export FILE --mark-moved
  --to TEXT`, which seals the archive and then writes the marker in one go, so
  a service that relaunches the engine in between cannot start it as the
  primary; copy the archive; `fermix home import FILE --into ROOT` on the new
  host and bind the service there (`fermix service install`); start the new
  host; then start this one in the device role if the desktop app still needs
  it. What import tells the owner to finish by hand: the keyring secrets to
  enter again, coding-agent consent to give here, the settings that
  still hold absolute paths outside the old home, and the installed plugins
  built for the old OS to install again.
- After a stage-one move iMessage, ACP, voice and Google Meet meetings stop
  on both machines: the device role starts none of them and the VM has no
  Mac to reach, nor a screen to sign the notetaker in to Google on. Zoom
  meetings run on the VM (`meetings`). Slack and WhatsApp keep working once their webhook points at the new
  host; Telegram and Discord resume on their own. After a move by hand the
  desktop app cannot reach the new host (it has no link to it, below); phones
  can.
- Whoever holds an archive's passphrase can stand up a primary that every
  paired phone trusts.

## Moving to a VM (Always On)

- Always On is not in released builds of Fermix yet: there `fermix
  always-on`, `fermix home status` and the engine say "Always On is not in
  this release of Fermix yet.", the setup page has no Always On tab and the Fermix app no Always On
  pane, and a home moves only by hand (`fermix home export` and `import`,
  below). A home whose `config.toml` carries `[fermix_core.always_on]
  enabled = true` gets it in a released build too: a switch for testing
  only, unsupported and not offered to owners. The switch is the home's
  setting, so it moves with the home, and the restart after editing it by
  hand is what applies it.
- Always On puts the primary on a Linux server the owner controls, so Fermix
  keeps working with the Mac closed. The server enrolls with an enrollment
  code the primary opens (one use, 30 minutes), on an existing Debian 12,
  Debian 13 or Ubuntu 24.04 host (arm64 or x86_64) whose kernel gives
  Landlock ABI 3: `curl -fsSL https://fermix.ai/install | sudo sh -s --
  --always-on`, which runs the release's server script and asks for the code
  without echoing it. ABI 3 means Linux 6.2 or later with
  Landlock enabled, as Debian 13 and Ubuntu 24.04 have by default; Debian
  12's own 6.1 does not, so a stock Debian 12 is refused (one on a 6.2 or
  later kernel is not). Below it every command Fermix runs would be refused,
  so the first boot checks the kernel before it installs anything and names
  what is missing. After `--always-on`:
  `--snapshot-bucket NAME --snapshot-region REGION` (or the bucket the
  server's infrastructure wrote), `--restore`,
  `--version X`, the release to install (Always On's command names this
  computer's; without it, the latest), and `--tailscale` (below).
- The first boot, as root: writes the code to `/run/fermix/enroll.code`
  (memory only, the engine account's), blocks the instance metadata service
  for every account but root at every boot (every packet to
  `169.254.169.254`, `100.100.100.200`, `fd00:ec2::254` and `fd20:ce::254`
  except DNS and time, which some clouds serve from the same address; the
  host's own processes: the server runs no containers, whose traffic that rule
  would not see), gives a host with no swap a 2 GB `/swapfile` (a host with
  swap keeps its own), installs the Linux package, turns on updates (below),
  creates the account `fermix` (home `/home/fermix`, no login shell,
  lingering), runs `fermix home enroll` and `fermix service install` as
  `fermix`, installs Chromium on Debian for browser tasks, and waits up to 5
  minutes for the primary to accept the server. The engine starts in the
  candidate role, enrolls with the primary and waits for the move. It never
  prints the code; cloud-init's console log shows each step.
- **Running it again.** On a server whose home `/home/fermix/.fermix`
  exists, the first boot first reads `fermix home status --json` as
  `fermix` (the home's role and its candidate's phase), before it installs
  anything. A candidate that has not begun to receive its move (enrolling,
  failed, ran out after 24 hours, or enrolled and still waiting for a move
  its computer gave up on) is enrolled again with a new code, from
  `FERMIX_ENROLL_CODE` or asked for at the terminal (refused with neither):
  its service is stopped (`fermix service uninstall` as `fermix`), `fermix
  home enroll` runs with the new code, and the service is installed and
  started again. The code it enrolled with is refused while it enrolls or
  waits for its move, and an enrollment refused (that code, or one past its
  thirty minutes) changes nothing: the service starts again with the
  enrollment the server had, once, and the run fails saying so. A home that
  runs (the primary, or a candidate receiving its move) is left running
  with no code ("Done. Fermix runs from the home it
  already had.", then the sentence naming it and the commands that remove
  it, since a run at a terminal asks no code of it: how an owner reusing the
  server after Restore here learns to set it up again) and refused with that
  sentence when given one; a retired copy a move left
  (naming where Fermix moved) and a desktop of another primary are refused
  either way. Each refusal is one sentence naming the home and the
  commands that remove it, should the owner want the server set up again
  (`sudo -H -u fermix env -C / XDG_RUNTIME_DIR=/run/user/<uid>
  /usr/bin/fermix service uninstall`, then `sudo rm -rf
  /home/fermix/.fermix`, then the command again). A home `fermix home
  status` cannot read is refused with the engine's sentence and no command
  that deletes it: `sudo -H -u fermix env -C / /usr/bin/fermix home
  status` shows why. `--restore` refuses a home that has not received its move. The
  first boot never removes a home itself.
- **The server on the owner's tailnet.** `--tailscale` joins the server to
  the owner's tailnet before it enrolls, so its tailnet address exists when
  it enrolls; without the flag nothing of Tailscale happens (a key in
  `TS_AUTHKEY` without it is refused). The Tailscale auth key comes from
  `TS_AUTHKEY` (cloud-init user data) or is asked for on the terminal without
  echo, after the code. Never pass it on sudo's command line (`sudo
  TS_AUTHKEY=… sh`): sudo writes the assignment to the system journal, every
  account can read it in `/proc` while the run lasts, and the shell keeps it
  in its history; at a terminal, leave it out and let the first boot ask.
  Cloud-init runs as root and needs no sudo: give the code and the key as
  assignments in front of `sh` in a `runcmd` item written as one string
  (one written as a list is run as a command line, key included), and use
  a one-off key, since cloud-init keeps the user data on the server's disk
  (`packaging/cloud/README.md` has the example). A key that does not start
  with `tskey-`, holds other than letters, digits, `-` and `_`, or is not 20
  to 200 characters long is refused before anything is installed, and so is
  an OAuth client secret (`tskey-client-`), which is not an auth key. The
  key is never printed or on a command line: it lives only in a 0600 file
  in the first boot's work directory under `/run`, which `tailscale up
  --auth-key=file:` reads and which is removed right after, and on every
  exit (a `kill -9` or a power loss leaves it in `/run` until the next
  reboot). Tailscale comes from its own signed package repository for the
  release (`pkgs.tailscale.com`), its signing key checked by fingerprint
  before apt is given it, never from a script piped into a shell. A host
  already on a tailnet (`tailscale status` says Running) is not logged in
  again and the first boot names its tailnet; given a key there, it stops,
  naming the tailnet, rather than drop the key (leave `TS_AUTHKEY` out to
  keep it, or `sudo tailscale logout` first). A host logged in with
  Tailscale down (`Stopped`) stops too: run `sudo tailscale up`, then the
  first boot again. A `tailscale up` that fails stops the first boot before
  it enrolls: a used-up, expired or revoked key needs a new one, and a
  server waiting for approval (it printed a link) is approved there and the
  first boot run again without a key. `--restore` takes `--tailscale` too.
- **The tailnet policy** is the owner's: the first boot opens no port and
  adds no rule. In the policy file (HuJSON, the admin console's Access
  controls), declare the tag before creating the key, since the key form
  offers only declared tags, and let only your own devices reach the
  server's iroh port, UDP 4033:

  ```jsonc
  "tagOwners": {"tag:fermix-server": ["autogroup:admin"]},
  "grants": [{"src": ["autogroup:member"], "dst": ["tag:fermix-server"], "ip": ["udp:4033"]}],
  // Only with webhooks (WhatsApp, cue webhook sources): Tailscale Funnel.
  "nodeAttrs": [{"target": ["tag:fermix-server"], "attr": ["funnel"]}]
  ```

  Then create the key tagged `tag:fermix-server`, one-off and pre-approved
  (the first boot passes no tags of its own). The grant holds only once the
  policy stops allowing everything: a new tailnet's file starts with a rule
  from `*` to `*:*`, and a file with no rule reads as that allow-all, so
  removing it or adding any rule turns allow-all off for every device, and
  the file then needs a rule for whatever your other devices reach today.
  The grant opens only `udp:4033`, so SSH or anything else to the server's
  tailnet address then needs your own rule (`tcp:22` from your devices, or a
  Tailscale SSH rule); SSH to its public address is unaffected.
  Funnel also needs MagicDNS and HTTPS certificates on (the DNS page), and a
  new server name can take about ten minutes to resolve.
- **Updates on the server.** Nobody logs in to it, so it updates itself.
  Debian's security updates: `unattended-upgrades` every day (the first boot
  installs it where the image lacks it and sets its two daily switches in
  `/etc/apt/apt.conf.d/21fermix-always-on`). Fermix: the package comes from
  release files, not an apt source, so two root timers run
  `/usr/local/sbin/fermix-update`: `fermix-follow.timer` every five minutes
  and `fermix-update.timer` every night at 04:00 UTC. The server leads:
  each installs the newest release whose home a published app reads for
  every computer keeping its backups (`fermix home status --json`'s `update`,
  read from fermix.ai's release table; `held` names a newer one waiting for
  an app), never back down, nothing while no table was read, then takes
  that release's own update script; then `fermix restart` as `fermix` when
  the engine is behind. Computers up to two minor versions behind are
  served; older ones keep settings only ("Update Fermix on this computer").
  `fermix-update --release X` updates by hand behind the same gate
  (`--ahead-of-apps` to go past it). The reboot stays at night.
  A move under way on the server, or a computer's work (ten minutes at
  most), holds the restart, and so does a status that cannot be
  read; the reboot waits at most two nights in a row for a move and then
  happens all the same. The two runs never install at once (one lock: a
  five-minute run leaves the update to one already running, the night waits
  for it). Each run says what it did in `journalctl -u fermix-follow` or
  `journalctl -u fermix-update` (a five-minute run with nothing due says
  nothing); an installer that ran and failed stops the run and leaves the
  running engine as it was, while one that could not be downloaded changed
  nothing, so the restart (and at night the reboot) is still decided; the
  next run tries again. A server set up before the five-minute timer
  existed gets it when its command runs again.
  So a server always runs the Fermix of the computer it serves, from its
  first install (Always On's command for the server names that release): a
  fix reaches the server within minutes of that computer having it, and the
  home can always move back there.
- **Memory.** Out of memory the kernel stops one process. The swap file makes
  that rarer, and on Linux the engine starts Chrome, and so every Chrome
  process, with `oom_score_adj` 1000, so the kernel stops Chrome before the
  engine.
- On Ubuntu there is no Chromium package (only a snap, which Fermix does not
  use), so the first boot installs no browser there: an Ubuntu server needs
  one installed by hand (Google Chrome's own package, for example), and until
  then browser tasks on it answer that no Chrome or Chromium is installed. A
  Debian server gets Chromium at its first boot.
- **A restore host.** When the primary is gone, `--restore` on a host
  prepares the same server without enrolling it and prints the exact steps:
  copy the newest snapshot onto it (downloaded from the bucket by hand, when
  one is named), `fermix home import` it into `/home/fermix/.fermix` as
  `fermix` with the recovery passphrase, then `fermix service install`. The
  restored home is the primary, one epoch up.

## Enrollment, the candidate and the move

- **The code.** On the primary, Always On's **Use my own Linux server**
  (`home.act`'s `own_server`) opens an enrollment window and shows its code
  once, with the command to run on the server, `curl -fsSL
  https://fermix.ai/install | sudo sh -s -- --always-on --version X` (X this
  computer's release, which the server installs), which carries no code: the
  server's first boot asks for it on the terminal without echo, so it never
  lands in a shell history. Beside it is the optional line that also joins
  the server to the owner's tailnet, which WhatsApp and webhook sources need:
  the same command with `--tailscale`, which then asks for a Tailscale auth
  key the same way (first declare `tag:fermix-server` under `tagOwners` in
  the tailnet policy, then create the key in Tailscale's admin console with
  that tag, one-off and pre-approved, and let only your own devices reach
  the server: *The tailnet policy*, above). **Cancel the code** closes it. The code
  is `fxenroll1.` and a long string that carries
  a one-time secret, the primary's gateway key, its iroh endpoint id and
  relays, its name (on a Mac its computer name) and when the window
  closes. The window lasts thirty
  minutes (time for a cloud server to boot), takes one server, and opening
  another replaces it. The code is shown once and never logged, and the
  window is kept on this machine (`mobile/enrollment.json`, 0600, never in a
  snapshot) so an engine restart before the server checks in loses nothing.
  A server whose acceptance was lost on the way and that asks again with the
  same key hears it again, as the same candidate, while the window lasts. The
  file keeps the secret only while it can still admit a server: once one is
  recorded, or the window is over, the secret leaves it, and the
  state and expiry stay for the status. It needs Reach from
  anywhere on, waking it for 10 s, or refuses by name ("Remote reach is
  off…", "…did not start…").
- **The candidate.** `fermix home enroll --code-file PATH
  [--snapshot-bucket B --snapshot-region R]` (what the server's first boot
  runs) makes a fresh home a candidate primary: it writes
  `<home>/candidate/` (the code, the snapshot bucket and region, its own
  iroh key, its Noise key and a one-time snapshot recipient, all 0600) and
  `[fermix_core.engine] role = "candidate"`, and removes the code file. It
  also marks the machine an Always On server (`<home>/device/server.json`,
  which stays on the machine through the move), whose iroh endpoint listens
  on the fixed UDP port 4033 as a candidate and as the primary (*Desktops
  (Always On)* in the `mobile` reference) and which announces no mDNS. A candidate whose endpoint cannot
  start says why in each retry's log line and, once its code expires, in
  `fermix home status`. It
  refuses a home that ran as a primary, carries a moved marker, is a
  candidate already, or holds anything a fresh install does not write, and a
  failure leaves the home and the code file as they were. A candidate engine
  runs only logging, its own iroh endpoint, the candidate process and
  `daemon.sock`, which answers `home.status` and refuses everything else by
  name; it opens no memory database, serves no web page, runs no channel or
  scheduler and has no primary epoch. It enrolls with the primary, then waits
  for the move for 24 hours. A refused enrollment ("already used",
  "expired", the primary "already holds four candidates") ends it, in its
  log and in `fermix home status`, and removes the code from the disk (every
  ending does). To enroll again with a new code, stop its service and run
  `fermix home enroll` again (running the server's command again does
  this): a candidate no move has reached (one that never enrolled, one
  whose 24 hours ran out, or one that waits for its move, which a new code
  means its computer forgot) is replaced; one receiving its move is not, nor
  one enrolling or waiting for its move given the code it enrolled with
  ("This server enrolled with this code already and waits for its move…"),
  whose primary would refuse the replacement as used: `state.json` keeps a
  digest of the window it enrolled into, never the code. A
  server that did not finish or ran out says, in its own status, to open a
  new code in Always On and run the command there again.
- **Reviewing it.** `fermix home candidates` (or `home.candidates.list`)
  lists the candidates the primary holds (at most four, each for 24 hours):
  id, name, system, version, and the snapshot bucket it was told.
- **The readiness report.** Before the move, the review (`home.act`'s Move
  now and Check again; `home.move.readiness` is rail-only) answers each fact
  as `ok`, `warn` or `block`: a meeting the notetaker is in (blocks, named:
  the move would end it before its notes are written, so leave it or wait
  for it to end; the same on a move back, and Move now asks again); the
  secrets this computer keeps in its keychain, which move with
  the home (one the keychain will not give blocks, named as its settings row
  labels it, "your Anthropic key", one no row shows counted, never by its id
  or its value); the server's Fermix (one that cannot read this home's format
  blocks, as does one whose home this computer could not read back until
  a published update does; a move back, to the desktop the
  home left, blocks only a desktop that cannot read the server's); free disk here (the
  capture needs about twice the home; short of it blocks, with the numbers);
  a home over one S3 upload (5 GiB) when the server keeps snapshots in S3
  (warns: it would never back up there); on a server of another system, the
  plugins the catalog has no build of for it (warns, named: they stop
  working; the server installs every other one again itself); a dev plugin
  folder (warns: it stays here); what this
  home has turned on that runs only here stopping after the move, each named
  (voice calls, Google Meet meetings; nothing to warn of when none is
  on; Zoom meetings carry on at the server, said where a Zoom app is set
  up); WhatsApp
  turned on (warns: it stops until you run the Tailscale Funnel command
  Always On shows for the server and point Meta at its address);
  Slack turned on without Socket Mode (warns: it stops
  unless switched to Socket Mode in the Slack app's settings and Fermix's);
  coding agents approved here (warns: they stop here, and run on the
  server only once approved there); the cutover gap
  (a recurring job more than an hour late is skipped; while Telegram is set
  up, its messages wait until the move is done); this computer
  serving nothing while the move runs; and Fermix run from a terminal
  (`fermix run`, warns: "Fermix runs from a terminal here, so it stops when
  the move starts. Start it again to finish."; the Mac app's engine,
  Fermix's own systemd unit (`fermix.service`, as the Linux package and
  `fermix service install` run it) and a `fermix service` install start again
  by themselves, while a shell inside any other unit, such as a terminal's,
  does not). At Move now a ready review under 15 minutes old is taken as it
  was shown.
  The move does not start while anything blocks, and Move now says each
  block; a warning the screen did not name yet comes back as the screen with
  that warning in Move now's confirm, so the owner accepts it first. Checking
  the keychain reads
  each secret, which opens the keychain and can ask the owner to allow it; a
  start within 15 minutes of a ready review takes that review rather than
  reading it again, so a move opens the keychain in the review and once more
  when its capture carries the values. Every Always On step (a code, a
  review, a move, a restore) is the owner's decision: a process Fermix started is refused on `daemon.sock`
  ("Only the owner can set up Always On, move Fermix or set its recovery
  passphrase: use the Fermix app, the setup page or your own terminal."). The
  server's own steps (opening a code, reviewing and starting a move, a backup
  now) answer only a linked desktop's request over the link, which that
  desktop's own Always On sends; on `daemon.sock` they are refused by name.
- **Starting the move.** **Move now** (`home.act`'s `move_now`), with Fermix
  running, asks for the recovery passphrase (twice, compared, where none is
  set yet; once where one is) and checks it: with one set, it must be that
  one ("That is not the recovery passphrase you set." otherwise, and nothing
  moves); with none set, it sets it, as setting the passphrase does. The move then carries the recovery key
  this computer already keeps, never a second one, so the new primary's
  snapshots open with the passphrase the owner has. It writes
  `<home>/.move/request.json` (the move id, the candidate, and that recovery
  key; the passphrase itself is never stored), sets the
  role to `device` and restarts Fermix through its own stop, which the service
  manager brings back (the Mac app's agent and launchd units keep it alive;
  the Linux service restarts always). Under a systemd user service a restart
  Fermix chooses resets the service's start budget first, so moves never use
  up the starts a crash loop is held to. An engine started by hand with `fermix
  run` just stops; start it again (the review warns of it). Keep the recovery
  passphrase: the new primary's snapshots open only with it.
- **What happens** (`home.status`'s `move`: phase, candidate, sentence; also
  `fermix home status`). On this computer: `requested`; `streaming`, the
  desktop's own key goes into the secret store and its row into the device
  list, the value of every secret `config.toml` keeps in the keychain is read,
  then the home is captured (as a snapshot, encrypted to the candidate's
  one-time key, in `.move/`, the keychain's secrets inside it as files of the
  server's secret store, never on this disk in clear) and sent to the
  candidate over the iroh rail; `committing`, once the candidate restored it,
  this home writes its moved marker and its desktop link and tells the
  candidate to commit; `committed`, Fermix restarts as a desktop of the new
  primary, whose start records `done` (only the engine that came back says a
  move ended; if it cannot write that, say on a full disk, `home.status`
  keeps the phase, says the ending and why in its sentence, and tries again
  at each read). On the server:
  `enrolled`, `receiving`, `staged` (restored one epoch up, with its snapshot
  bucket, region and recovery key, and no machine settings, in
  `candidate/staging`; the server's own sandbox starts at `open`),
  `activating` (the restored home renamed into place,
  its settings last), then it restarts as the primary, and its first start
  takes a snapshot at once and installs again, through the plugin installer
  (checksum and signature checked), every plugin from the old system that
  has a build for the server. One it could not install, tried three times,
  says so on its row in Plugins ("Fermix could not install it again after
  the move.", with Install…), and one with no build there reads "This build
  of Fermix cannot run it."; the daemon log says why. The keychain's secrets land in the server's
  secret files and its settings name them there (`@file`), so the server
  resolves every secret this computer had. The server never becomes the
  primary until this computer, already marked moved, tells it to.
- **When something fails.** Before the server restored the home, a refusal
  (the server's disk has no room for the stream and the restored home, the
  keychain will not give a secret, this disk has no room for the capture) or
  three failed attempts undo the move (`undoing`, then `aborted` once Fermix
  is back): the desktop's key and row go, the role is `primary` again and
  Fermix restarts; nothing was retired. Every attempt sends the same capture.
  Once the moved marker is written the move is never undone, only finished: a
  lost message is resumed (Fermix asks the server again, and if the server
  already became the primary, asks the new primary itself), retrying for 24
  hours with the sentence in `home.status`, and again at every start. The
  server takes only an offer later than the move it holds, so a stale attempt
  arriving late cannot undo a staged home. A server whose renaming of the
  home fails part-way says so in its `home.status` and tries again on a timer
  (and at its next start), answering this computer "not yet" meanwhile. At any
  crash or lost message at most one engine serves as the primary. Do not
  restore a snapshot of this home elsewhere while the original still runs: the
  restored copy holds the same identity and could answer for the moved one.
- Phones see a reconnect and nothing else: the gateway key and the iroh
  endpoint move with the home and the epoch rises by one. The move needs room
  on this computer for a copy of the home and its encrypted snapshot, and on
  the server for the stream and the restored home: about twice the home on
  each, which the readiness report and the server check first. A move session
  has no time limit, so a large home on a slow link just takes longer.
- While the move runs this computer is kept awake, and only then: from the
  restart into the device role until the restart the move ends with
  (caffeinate on a Mac, systemd-inhibit on Linux, each ending with Fermix).
  A closed lid still sleeps a Mac; the move then retries or waits, as for a
  network drop. Nothing keeps it awake while a server waits for the move: the
  server keeps trying until its code expires. Without an inhibitor (a Linux
  without systemd-inhibit) the move runs anyway and the log says the computer
  may sleep.
- While the move runs this computer serves nothing; a message typed in the
  app then is answered "Fermix is moving this home to <name>; your message is
  kept until it is done." and sent again once Fermix is back.
- The cutover has a gap: a recurring job that comes due more than an hour
  late is skipped rather than run late. The apps say so before the owner
  moves. Telegram messages sent while the move runs are not lost: Telegram
  keeps them for 24 hours, and Fermix answers each once when it runs again,
  on the server (or here, if the move is undone), since the ids of the
  updates it already took move with the home's memory database.
- On the server Fermix keeps every secret in its file secret store
  (`<home>/secrets/`, readable by the server's `fermix` account only): in
  plain files, which Fermix's sandbox keeps from every command Fermix runs.
  The secrets this computer kept in its keychain move into those files.
- **What lives on the server, and for how long.** The home lives there for as
  long as Fermix runs there: the conversations and memories in `memory.db`,
  the settings, the token file and the secret files, the phone identity,
  skills, journals, workspace and installed plugins. Beside it are the
  server's own browser profile, with the sessions of the sites signed in to
  there, the logs (10 MB, five files) and the traces: the prompts, replies,
  tool input and output and shell commands in them are kept about a day
  (through the previous UTC day) on a server, the rest of each record (when,
  which model, tokens, errors, ids) 14 days and at most 1 GiB. Fermix adds no
  disk encryption on the server: one that restarts on its own would need the
  key on the same disk, so it would protect little. The hosting provider can
  technically read the server's disk, so turn on two-factor sign-in for the
  hosting account and keep a project for Fermix alone. What leaves the server
  is encrypted end to end: snapshots to the recovery key, of which the server
  keeps only the half that writes them, so neither it nor the provider can
  open one, and every link to the phones and the desktop.
- After a move, or a restore, `home.status`'s `secrets_missing` on the
  primary names each secret reference that did not resolve on that host (by
  the id `fermix setup` and the app take), and the settings rows show those
  secrets as not set rather than set: each needs entering again there.
- **Changing servers.** Fermix replaces no server itself: move back to the
  computer the home left (*Moving back*, below), then set the new server up
  from Always On as the first time.

## Snapshots and the recovery passphrase

- An Always On server's primary keeps encrypted snapshots of its home in an
  S3 bucket, so a lost server is recovered by restoring the newest one. A
  computer whose home never moved keeps none (`fermix doctor` says so). A
  snapshot carries what an export carries, taken while Fermix runs: the
  memory database is copied consistently.
- Snapshots are encrypted to a recovery key derived from a recovery passphrase
  the owner chooses (at least 12 bytes). `fermix home snapshots passphrase
  --passphrase-file PATH`, or Fermix asking twice without echo, sets it on a
  running primary; Fermix keeps only the key derived from it and never the
  passphrase, so it writes snapshots on its own and only the passphrase opens
  them. Whoever holds the passphrase and a snapshot can stand up the primary.
- They are on once a recovery passphrase is set and a bucket is named in
  `[fermix_core.snapshots]`, every `interval_hours` (default 6). No app sets
  S3. On AWS, fermix-server-aws's `enable_s3_backups` names the bucket at
  first boot and Fermix signs with a root helper's one-hour session of the
  server's snapshot writer role (`s3_credentials = "instance_role"`): no
  keys. Another S3 service is set on the server: `s3_bucket`, `s3_region`,
  `s3_endpoint`, and the two `snapshot_s3_*` secrets (`fermix settings secret
  set`). Fermix never lists, reads or deletes objects.
- Each snapshot is `<prefix>/<profile>/<UTC time>-e<epoch>.fxsnap` in the
  bucket. It counts as stored only when the bucket accepted its SHA-256
  checksum; a failure keeps the bucket's own words and is retried at the next
  interval. **Back up now** in Always On takes one now (on a linked desktop
  it asks the server). A capture
  needs about twice the home free on the disk and is refused with the
  numbers otherwise.
- Each stored point names the recovery key it was written for (its key id,
  as setting the passphrase shows it). Setting the passphrase again replaces
  the key; the snapshots written before open only with the earlier
  passphrase, and setting it says so. A move never replaces it: it checks the
  passphrase typed against the one set.
- `fermix home status` (and `fermix home snapshots status`) shows the role,
  the epoch, the moved marker, whether snapshots are on, the last one stored,
  the last error and the next run, from the running engine or, with Fermix
  stopped, from the home's own files; `--json` for scripts. The engine's
  `home.status` management method is the same picture the apps draw.
- Restoring: download the newest snapshot from the bucket by hand (the
  server's own credentials cannot read it), then `fermix home import FILE
  --into ROOT --passphrase-file PATH`; it is restored exactly as an archive is,
  one epoch above, with the same changes and the same things to redo by hand.
  A wrong passphrase, a damaged or cut-short snapshot is refused by name and
  nothing is written.
- Snapshots are the primary's: in the device role none are written.
- The primary also keeps a copy of each snapshot on every desktop connected
  to it (the computer the home left, "your desktop" in the status), beside
  the bucket's: it streams the encrypted snapshot to the desktop, which keeps
  the newest 3 under its own `<home>/snapshots/` (mode 0600) and counts as
  stored only once the desktop answered the same SHA-256. A desktop keeps no
  copy that would leave its disk with less than 2 GiB free, and says so. A
  desktop that is not connected (asleep, shut, offline) is no failure: its
  status is `waiting`, "Your <name> is not connected; the snapshot waits for
  the next run.", while the bucket's copy goes on. The
  desktop never holds the passphrase, so it cannot read its copies; restoring
  from one is `fermix home import <home>/snapshots/<name>.fxsnap --into ROOT
  --passphrase-file PATH`, as from a downloaded one.

## The desktop after the move

- After an Always On move the computer the home left keeps Fermix running in
  the device role, linked to the new primary: `<home>/device/desktop.json`
  names the primary (its name, gateway key, iroh node id and relays, its
  direct address hints, the highest primary epoch this desktop has seen, and
  the secret store with its own key: the keychain, or the file store, whose
  copy never travels). An old key file moves there at start; a key it cannot
  use is refused by name and nothing is dialed. Both stay here.
- The Mac or Linux app changes nothing: it keeps talking to this computer's
  own Fermix sockets, and this Fermix carries what belongs to the primary over
  one encrypted session through the iroh rail. The app's chat goes to the
  primary, each app connection as one channel: messages, history, search,
  turns, approvals and proposals are the primary's. Only the owner's app is
  carried; a process this Fermix started (a command the primary asked this
  desktop to run) or one running detached is refused. Media a chat row names
  is fetched from the primary and handed to the app as a file on this
  computer.
- Settings and other Fermix-wide requests from the app go to the primary
  too, recovery, enrollment and move included: after the move the server
  holds them, its own sandbox, browser and coding agents included. Answered
  here: Fermix's own status and lifecycle, its logs, diagnostics and Doctor,
  the setup page, computer use, iMessage, its browser's installer, and its
  own settings under This Mac (the `computers` reference, "Settings after a
  move"); iMessage's owner and guests are the primary's.
- Two answers are put together here: the home's status is this computer's
  own (its role, its link, where the move went) with the primary's own
  picture added (its recovery, enrollment, candidates and move), and the
  settings list is the primary's with this computer's own after it. The
  primary's part is asked within 5 seconds; without it, this computer's
  part is still shown and a sentence says why. This computer's own old
  snapshot status is a retired copy, not the home's recovery.
- Signing in (a provider, a plugin, an MCP server) from the app on this
  desktop runs on the primary, where the tokens live, and the browser page
  opens here. While it waits, this desktop listens on the same `127.0.0.1`
  port the primary's sign-in does and forwards what the browser sends there
  to the primary, which answers it as if the browser were its own: the
  sign-in completes as it does on one machine, for every provider, with
  nothing to paste. At most 8 requests per sign-in, and the forward closes
  when the sign-in ends (at most 15 minutes). This desktop listens only on a
  port nothing else on it listens on, never below 1024 and never one of its
  own Fermix ports, and holds at most 8 such forwards open, so the server can
  never take over a service the owner runs on `localhost`. A port another
  program holds on this desktop fails the sign-in at once, saying "Your
  <name> could not open port <port> to receive the sign-in reply: …"; free
  the port and sign in again.
- While the primary is unreachable the app is told so by name: "The server
  <name> is unreachable. Fermix keeps your message until it is back." The
  app keeps unsent messages in its outbox and sends them once it reconnects.
  This Fermix tries again after 1 s, doubling to 60 s, and starts over once
  connected. A request the primary does not answer within 8 seconds (inside
  the apps' own 10-second wait) is answered that it did not answer in time.
  Reviewing and starting a move wait 60 seconds instead, since the server
  walks the whole home first (the apps give those two 65 seconds). A move
  start whose answer never comes back (the server restarts into the move
  right after answering) is never reported as failed: the app hears that
  whether it started is not known yet, and the move's state shows in the
  server's home status once it answers again; starting it again never starts
  a second move.
- The link is meant to stay up: it has no one-hour lifetime as a phone's
  session has (its keys are still renewed every 2^20 messages). When the
  server ends the session normally (it is restarting) this desktop reconnects
  at once and says the link was renewed, not that the server is unreachable.
  A server that ends the renewed session too, within a minute of it opening,
  is treated as an outage from then on: this desktop waits longer between
  tries (the usual backoff) and says "The server <name> ends this computer's
  session each time it opens."
  Removing this computer on the server, or Disconnect here, ends the link
  (the `computers` reference).
  When the server does not know this computer anyway (the server was
  restored from a snapshot taken before this computer joined it), this
  desktop stops trying
  and says "The server <name> does not know this computer: it was removed from
  the server's devices, or the server was restored from a snapshot taken
  before this computer joined it. Fermix stopped reaching it." until Fermix
  restarts here. Any other ending is said in plain words ("it closed the
  session", "it sent a message this computer could not read") and tried again.
- `home.status`'s `primary.status` names the link's state in one word, so the
  apps draw a quiet renewal apart from an outage: `connected`; `renewing` (a
  session opening with nothing known to be wrong: the first since Fermix
  started here, or the renewal above, drawn quietly); `unreachable` (an
  outage, tried again; also a link file Fermix refused to use); `revoked`
  (the server does not know this computer); `stale` (an older copy answered).
  A desktop's chat refuses a message with `desktop_revoked` once the server no
  longer knows this computer, so the app stops keeping it for later.
- At each connection this desktop names the highest primary epoch it has
  seen. A server that answers with a lower one, or refuses it, is an older
  copy of Fermix: this desktop does not use it, says so, and keeps its epoch.
  A higher epoch is kept; so is a newer relay list, which the next connection
  acknowledges.
- The server's address hints, dialed beside the relay, and the link's path:
  *Desktops (Always On)* in the `mobile` reference.
- The engine's `home.status` (what the apps draw, and `fermix home status
  --json`) shows the link: the primary's name, whether it is connected and
  since when, the epoch, the sentence, and while it is connected its path
  (`direct` or `relay`). On the primary the same picture lists its desktops,
  each with whether it is connected, and beside them `computers`, each
  computer's record and what it offers (the `computers` reference).

## Moving back to the computer the home left

- Fermix can move back from the server to the computer the home left
  (**Move back to this Mac**, then **Move now**), and a computer whose server
  is gone can restore its own copy (**Restore on this Mac**), once the owner
  confirms they deleted the server, or stopped it for good. Every step, what
  comes back and what is lost: skill_view(name: "self-knowledge", file:
  "move_back").

## Where each Always On fact and action lives

- Every surface draws one picture, the engine's `home.status`, and acts
  through the same `home.*` methods and settings sections: the Fermix Mac and
  Linux apps' **Always On** pane and the CLI. Nothing on one surface is
  missing from the other except where the table says so.
- **One summary says where Always On stands.** `home.status` carries
  `summary`, the Always On screen, worked out once by the engine, which the
  apps, the setup page and `fermix home status` print as they are: one short
  sentence, at most one more under it (what to check or do, until when
  something waits, why a move was undone, a failure's own words), at most
  one main action (none while a step runs) with every other step beside it,
  Details with facts only, and one help page on the Always On docs for the
  screen. Every action says what the surface must collect first (the
  recovery passphrase), the confirm the owner accepts before Fermix moves,
  restores or forgets (one part per line, never a time that moves with the
  clock; Move now's names every warning of the review, which the screen
  itself never shows), and a key. Its words never name an epoch, the
  primary, a candidate, the relay, the rail, a phase or the daemon, and a
  secret is named as its settings row labels it. Fermix creates, powers and
  deletes no server: the server is the owner's own. Its states:
  - before the move, on the computer that sets it up: nothing set up ("Keep
    Fermix running when this Mac sleeps. It moves to a server you own.",
    **Use my own Linux server**); a code open ("Waiting for your server to
    use its code.", **Replace the code**, **Cancel the code**); the server
    connecting (**Cancel the code**); ready ("Your server is ready. Fermix
    moves to it when you press Move now.", until when it waits under it,
    **Move now**, what this Mac keeps on for its server as ticks, and
    **Forget this server**, which asks first); a review that blocks ("The
    move cannot start yet." with each block, **Check again**); the move
    undone (why, **Try again**, **Forget this server**). Each screen of the
    move, and of the move back, shows its four steps on one line, the
    owner's marked, and while it moves the route to the server and, only
    while bytes move, how much was sent or received;
  - on the computer the move leaves: moving (packing, sending, the server
    unpacking, switching over; "Fermix keeps trying." while it waits on the
    server); "Fermix runs on your server. Last backup 2 hours ago." once
    linked, with **Back up now**, **Add a computer** and **Move back to this
    Mac**, and Details' Backup settings (whether the recovery passphrase is
    set, with **Change**, and that the server keeps an S3 copy where it
    does); no longer connected to it (**Restore on this Mac** where it holds
    a copy, its confirm naming the backup's date); moving back (below);
  - on the server: waiting for its move, then "Fermix runs here."; after a
    move back, its retired copy says "This copy is retired: Fermix moved
    back to <the computer>.";
  - a problem, with the one action that fixes it, or none: no answer for 10
    minutes of this computer being awake (check that it is on and online;
    **Restore on this Mac** where it holds a copy), this computer too old for
    its server or past its window (**Update**), the server older than this
    computer (it updates once the apps carry the newer one) or ahead of the
    apps (**Update**; Move back and Restore here say "Update Fermix on this
    Mac first"), the server's disk 85% full or more (free space or give it a
    bigger disk), the last backup over 3 days old or failed until stored
    (**Back up now**; a failure's own words under it), a move back that
    stopped, and on the server, one that waited past its 24 hours or whose
    enrollment failed (open a new code and run the command there again).
- Details holds facts: the server, its system and version, each place's
  last backup and the S3 bucket, the space this computer's copies take and
  the server's disk, in the owner's time zone as dates and times, never as
  ages. Background and caveats are the Always On docs.
- **Webhooks on the server.** Slack (Socket Mode), Telegram and Discord need
  nothing inbound. WhatsApp (Meta's Cloud API) and cue webhook sources do,
  and the server opens no public port: they reach it through Tailscale
  Funnel. While Fermix runs on the server, the desktop's Always On screen
  prints the exact command for each mount, to run on the server as root
  (`sudo`: the first boot names no Tailscale operator): WhatsApp's (`sudo
  tailscale funnel --bg --set-path=/webhook/whatsapp
  http://127.0.0.1:<port>/webhook/whatsapp`, the server's web listener port,
  one mount for Meta's GET check and its POSTs, while WhatsApp is on), with
  its note: set the address Tailscale prints as Meta's Callback URL, with
  the verify token, and press Verify and save, for until then WhatsApp
  messages do not arrive; and each enabled webhook source's with a URL,
  its prefix (`/cues/hooks/<ref>` on the server's cue door port, so the
  command carries none of the URL's secret: Tailscale passes the rest of
  the path to the door, which answers only that source's own path), with
  its note: in the sender, change the host of the webhook's address to the
  one Tailscale prints and keep its path. With them: once, in the tailnet
  policy, the `funnel` node attribute for `tag:fermix-server`, and MagicDNS
  and HTTPS certificates on; a new address can take about ten minutes to
  resolve; Funnel publishes whatever `tailscale serve` has on
  port 443, so mount only these paths there; the traffic enters through
  Tailscale's ingress servers, which see only encrypted bytes; without
  Tailscale, Cloudflare Tunnel to the same two loopback ports does the same.
  The ports and the sources are the server's (its `home.status` `webhooks`),
  never this computer's; a server serving none shows nothing, and the
  server's own screen shows none (its desktops do: the server's summary
  rides inside each desktop's `home.status`, where the mounts would pass the
  protocol's nesting bound). Fermix ships no tunnel.
- The summary also names the latest occurrence the apps raise as a system
  notification (`notice`): the server ready, the move done, the server out of
  reach, the last backup a week old, Fermix back on this computer after a
  move back, Restore here finished ("Fermix runs on this Mac again, from its
  backup of <the backup's day>."), and a held server whose 24 hours ran out
  ("Your server waited 24 hours for the move and must be set up again. Open
  a new code in Always On and run the command on it again."). Each keeps one
  id while it stands, so an app posts it once.
- When the server's newest backup passes 7 days it tells the paired phones,
  once per occurrence, as a message in the owner's phone chat: open Fermix on
  the Mac to back up now.
- **No polling.** The apps never ask for the summary on a timer. The chat
  socket tells a connected app that it changed (`home_status_changed`, which
  carries nothing; the app then reads `home.status`): once when the app
  connects unless Always On is off, and whenever the summary's key moves:
  anything a surface draws, the step in hand, a confirm, an alternative, a
  Details line or the notice included, but never the clock alone (a
  backup's age in a sentence). Nothing is told while Always On stays off, not even a settings
  change to what the off line names: the app forgets Always On while it is
  off and reads that line when the pane opens. Fermix works the change out
  without polling: it reads the summary
  again only when something it rests on happens (the move's phase or a move
  back's record, the enrollment code opened, used, withdrawn or expiring, a
  server enrolling, the link to the server up or down, a backup run
  finishing) and at the next time it changes by the clock alone (10 minutes
  awake of silence, a waiting server's 24 hours, a backup's 3 days and its
  7), on one timer, armed again at each read and after a wake from sleep, and
  only while an app is connected. While Always On is off nothing is armed,
  and only a code or a move is read. A
  `home.status` asked with the key it was drawn with and a wait (`after`,
  `wait_ms`, at most 25 seconds) is answered once the key moves, which is how
  a terminal follows a step without polling. After a move the desktop's Fermix tells its app about its own
  summary, reading the server's part again when the server says its own
  moved; while the server is unreachable the chat connection is refused, and
  the app reads the summary then. A server's disk filling is seen at the next
  thing that happens (on the server, every backup run).
- **From a terminal: `fermix always-on`.** On a Homebrew or Linux install
  without the Fermix app, this is how Always On is set up. With no step it
  prints the summary (its sentence and note, the step in hand, Details, the
  help page) and each step with its command; on a terminal it numbers them, Enter takes the main one
  and `q` quits, and for the step taken it asks what the step needs: the
  recovery passphrase without echo (twice where none is set yet), and the
  confirm as `[y/N]`, No unless answered. It prints the step's id as it runs,
  never what was typed, then waits for Always On to move on and offers the
  next step. The code for the server is printed once, under the command
  to run on it. `fermix always-on STEP` takes one step, by the action's id
  with `-` for `_` (`own-server`, `cancel`, `back-up-now`, `check-again`,
  `move-now`, `try-again`, `move-back`, `restore-here`,
  `change-passphrase`; `update` says how). With no terminal or with `--json` it asks nothing:
  `--recovery-passphrase-file PATH` gives the passphrase, `--yes` accepts the
  step's confirm, and `--wait` waits; a need no flag gives exits 2 naming the
  flag, and a confirm without `--yes` refuses `confirm_required`. A
  passphrase typed as an argument is refused. The wait asks `home.status` with the screen's key while the
  screen's outcome says Always On is at it, and stops after 45 minutes; a
  waited step that ends on a problem exits 1 (`step_failed`), and so does
  one still at it when the wait runs out (`step_unfinished`), each with the
  screen where it stands, while the screen read alone exits 0 whatever it
  shows. Ctrl-C stops the wait and the step goes on. During Move now the engine restarts, so the wait reconnects for up to
  90 seconds and otherwise says "Start Fermix again to finish the move." If
  Always On changed since the screen was read (another window pressed first),
  it says so (`changed`) and shows the screen again; a Move now sent to the
  server whose answer was lost says so and is followed as a started move;
  any other refusal is the engine's own sentence (`action_refused`). It needs Fermix running
  (`engine_stopped` otherwise, writing nothing), and on a home the Mac app
  manages it refuses `app_managed`, naming the app's Always On pane.
  `fermix home status` ends its summary line with where the next step is
  taken: `fermix always-on`, or the Fermix app on a home the app manages.
- The browser setup page's **Always On** tab is the same screen as the
  apps' pane and takes every step the App column below lists, so an owner
  with no app (a Homebrew or Linux install) sets Always On up there: `fermix
  setup` opens it, over SSH through the tunnel it prints. It draws the
  summary's sentence and note, the step in hand and its buttons; the sentence to
  accept before Fermix moves or restores; the recovery passphrase at **Move
  now** and **Restore on this computer**, typed twice where none is set yet;
  the code for the server, shown once with **Copy**; Details, with
  **Change** for the recovery passphrase; and Learn more. It reads the summary when the
  tab opens and whenever Fermix says it changed, never on a timer, and if
  Always On changed since the screen was drawn a press does nothing and says
  so. **Move now** on the computer that sets it up shows Fermix restarting,
  and the page opens on Always On again once it is back. Inside the Mac app
  the page has no Always On tab: the app's own pane is there.

| Fact or action | App | CLI |
|---|---|---|
| Where Always On stands: one sentence and at most one action (`summary`) | The pane's first line and its button | `fermix home status`, first; `fermix always-on` |
| The role and the epoch | This computer | `fermix home status` |
| On a desktop: the primary (connected or not, since when, its sentence), or where the home moved | The primary | `fermix home status` |
| On the primary: its desktops, each connected or not | Desktops | `fermix home status --json` |
| Whether a recovery passphrase is set; each place snapshots go, its last verified snapshot (and the recovery key it opens with), a desktop copy that is waiting, and its last error | Details: Backup settings | `fermix home snapshots status` |
| Set the recovery passphrase | Backup settings' **Change**: typed twice, never shown; a change says which snapshots open with which passphrase | `fermix home snapshots passphrase` |
| On the primary: the secrets that did not resolve on this host (`secrets_missing`), by id | Secrets to enter again | `fermix home status` |
| How often snapshots run, and whether the recovery passphrase is set (S3 is the server's own) | Recovery: the `snapshots` section | `fermix settings set snapshots …` |
| Take a snapshot now (`home.act` `back_up_now`) | **Back up now**, offered once snapshots have somewhere to go | `fermix always-on back-up-now` |
| An enrollment code for the server (`home.act` `own_server`) | **Use my own Linux server**: the code shown once with **Copy** and when it expires, beside the command for the server, which carries no code, and the optional `--tailscale` one; **Cancel the code** closes it | `fermix always-on own-server`, the code printed once under both commands; `cancel` closes it |
| On a linked desktop: the Tailscale Funnel mounts the server's webhooks need (`summary.detail.webhooks`, from the server's `webhooks`) | Each command with **Copy**, its policy step and caveats | `fermix always-on`, each command on a line of its own |
| The servers waiting for the move | Servers waiting for the move | `fermix home candidates` |
| Review the move: each item ready, a note or a block | Move now reviews at the press; **Check again** on a block | The same; `fermix always-on check-again` |
| Start the move (`home.act` `move_now`, `try_again`) | **Move now**, the recovery passphrase asked first | `fermix always-on move-now`, `try-again`: the passphrase asked without echo, or `--recovery-passphrase-file` |
| Where the move stands (its phase and sentence) | The move | `fermix home status` |
| On a linked desktop: the server's own recovery, its move, and the secrets it could not resolve (the composed `primary_home`, or why it is missing) | The server's recovery (**Back up now** asks the server), The server's move | `fermix home status --json` |
| On a linked desktop: move back, or restore from this computer's copy (`home.act` `move_back`, `restore_here`) | **Move back to this Mac**, **Restore on this Mac** | `fermix always-on move-back`, `restore-here` |

- In the device role the browser setup page opens on Always On, which acts
  there too, and leads with a notice that Fermix-wide settings live on the
  server and that the page sets up this computer and Always On. Its tabs for providers,
  voice, channels, voice notes, plugins, search, images, coding agents,
  memory, personalization and cues show that sentence instead of their forms;
  its Sandbox and Doctor tabs set up this computer.

## What a restart or a move does to a message in flight

- If Fermix restarts, a message from the Mac app or a phone that it had not
  started answering is answered when it comes back.
- One it was already working on is not run again, because part or all of it may
  have run; nor is any unfinished message after the home moved to another
  computer or was restored from an archive. Such a message ends with a note
  that it may have run before the restart (`uncertain_after_restart`), and the
  owner sends it again as a new message to run it again; re-sending the
  original is recognised as a duplicate and ignored. A message the owner had
  cancelled ends as cancelled.
- Reminders still delivering at a restart are sent again, and a job run in
  progress is marked failed.

## Browser profiles and the move

- Browser profiles belong to the device: a sign-in on one Fermix does not sign
  another in, and export leaves them behind, so after an Always On move the
  server's browser is signed in to no site.
