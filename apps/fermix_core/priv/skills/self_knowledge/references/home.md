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
  curation or meetings, and refuses every turn with "This engine runs in the
  device role; the primary is <where it went>." From the desktop app it also
  refuses, with the same sentence, every write into the retired copy: a
  cancel, a read receipt and an answer to a cue card; history and search still
  answer.
- A device-role engine makes no provider call and refreshes no token: it
  starts no token manager and no realtime voice (the voice socket is absent,
  so the app sees no connection rather than a refusal), its computer history
  captures and purges but does not summarize, and the management methods that
  sign in, sign out, import a login, probe a provider, list a provider's live
  models or run the network doctor answer that the engine runs in the device
  role. `fermix memory review --now` and `fermix memory restore` refuse the
  same way. On a home configured as a device or carrying the moved marker,
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
  sandbox grants, browser profiles, the iMessage cursor, coding-harness
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
  Importing also withdraws coding-harness consent, deletes screen history
  from the restored database, moves a keyring-mode home to the file store on
  a host whose keyring does not answer that it is available (a check that
  timed out counts as no answer, and the log says so; macOS keeps its
  keyring), and names the
  settings that still hold paths outside the old home and the installed
  plugins built for another OS, which `fermix plugins install NAME`
  reinstalls. It never marks the old home moved. A home a newer Fermix wrote
  is refused by name, and nothing is written: update Fermix first.
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
  enter again, the coding-harness consent to give again, the settings that
  still hold absolute paths outside the old home, and the installed plugins
  built for the old OS to install again.
- After a stage-one move iMessage, ACP, voice and meetings stop on both
  machines: the device role starts none of them and the VM has no Mac to
  reach. Slack and WhatsApp keep working once their webhook points at the new
  host; Telegram and Discord resume on their own. After a move by hand the
  desktop app cannot reach the new host (it has no link to it, below); phones
  can.
- Whoever holds an archive's passphrase can stand up a primary that every
  paired phone trusts.

## Moving to a VM (Always On)

- Always On puts the primary on a Linux server the owner controls, so Fermix
  keeps working with the Mac closed. The server enrolls with an enrollment
  code the primary opens (one use, 30 minutes), on an existing Debian 12,
  Debian 13 or Ubuntu 24.04 host (arm64 or x86_64) whose kernel gives
  Landlock ABI 3: `curl -fsSL https://fermix.ai/always-on | sudo sh`, which
  asks for the code without echoing it. ABI 3 means Linux 6.2 or later with
  Landlock enabled, as Debian 13 and Ubuntu 24.04 have by default; Debian
  12's own 6.1 does not, so a stock Debian 12 is refused (one on a 6.2 or
  later kernel is not). Below it every command Fermix runs would be refused,
  so the first boot checks the kernel before it installs anything and names
  what is missing. After `sh -s --`:
  `--snapshot-bucket NAME --snapshot-region REGION`, `--restore`.
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
  candidate role, enrolls with the primary and waits for the move. Running
  it again is safe: a host whose home exists is not enrolled again. It never
  prints the code; cloud-init's console log shows each step.
- **Updates on the server.** Nobody logs in to it, so it updates itself.
  Debian's security updates: `unattended-upgrades` every day (the first boot
  installs it where the image lacks it and sets its two daily switches in
  `/etc/apt/apt.conf.d/21fermix-always-on`). Fermix: the package comes from
  release files, not an apt source, so `fermix-update.timer` (root) runs
  `/usr/local/sbin/fermix-update` every night at 04:00 UTC: the installer
  again, `fermix restart` as `fermix` when `fermix service status` says the
  running engine is behind the installed one (so a restart a night skipped is
  done the next night), then a reboot when `/run/reboot-required` exists.
  While a move is under way on the server (sending its home, or as a
  candidate enrolling or receiving one) the restart waits, and so it does
  when the engine's status cannot be read; the reboot waits at most two
  nights in a row for a move and then happens all the same. Each night says
  what it did in `journalctl -u fermix-update`; an installer that ran and
  failed stops the night and leaves the running engine as it was, while one
  that could not be downloaded changed nothing, so the restart and the reboot
  are still decided; the next night tries again.
  So a server's engine can be a day or more behind the Mac's.
- **Memory.** Out of memory the kernel stops one process. The swap file makes
  that rarer, and on Linux the engine starts Chrome, and so every Chrome
  process, with `oom_score_adj` 1000, so the kernel stops Chrome before the
  engine. Both values are constants until they are measured on a real server.
- On Ubuntu there is no Chromium package (only a snap, which Fermix does not
  use), so the first boot installs no browser there: an Ubuntu server needs
  one installed by hand (Google Chrome's own package, for example), and until
  then browser tasks on it answer that no Chrome or Chromium is installed. A
  Debian server gets Chromium at its first boot.
- **A server Fermix creates on Hetzner.** Instead of a host of their own,
  the owner can let Fermix create the server with a cloud provider. Hetzner
  is the one provider today: each provider is one module behind one contract
  in the engine, and every surface draws its token and choose screens from
  what the engine's summary lists (`detail.providers`: its name, its token's
  label, its How to get one steps, its console), so another provider needs no
  new app; every sentence about the server names the provider in its own
  words, and Fermix creates on one provider at a time. The engine runs every
  step itself: a surface sends the one step the owner pressed (`home.act`)
  and draws the summary it answers. On Hetzner, from Always On: paste a Read
  & Write API token of a project made for Fermix
  (checked at once; it stays on this computer in its provider's own file,
  `device/provision/hetzner.json`, 0600, never in `config.toml` or the
  keychain, so a move never carries it to the server, and the owner can
  delete the file), pick the size and location (the cheapest x86 type with at
  least 4 GB in stock, in Falkenstein, then Nuremberg, then Helsinki, with
  the next size up as "more room"; prices read live from Hetzner, monthly
  with VAT as the account is billed and the IPv4 address), and **Create
  server**. Fermix creates a firewall with no inbound rule first (a token
  that can only read is refused there, before anything costs money), then a
  Debian 13 server named `fermix-<profile>-<4 hex>` and labelled
  `fermix=always-on`, its IPv4 address kept and no SSH key, whose cloud-init
  runs the same first boot with an enrollment code already inside. That code
  lives 24 hours, so a slow install or a sleeping Mac does not fail it, and
  while it waits **Use my own Linux server** is refused ("Your new server is still setting
  up…"); the server that enrolls with it is the one Fermix created. Hetzner's
  answers in one sentence each: no capacity in a location names the next one
  in stock; "Hetzner limits new servers on this account" (a new account may
  not order at all; the own-server path stays); a token Hetzner stopped
  accepting asks for a new one. Always On's Details list the server and what
  it costs, a server deleted in Hetzner's console shows as gone (the engine
  reads Hetzner back at most once a minute while a step or a problem rests on
  it), **Turn it on** and **Restart server** power it, **Cancel** during a
  create stops the create, waits for it to stop and then deletes what it
  made, **Start again** deletes what stands and creates it again as one step,
  and **Delete your server** deletes everything it created (the server, then
  its addresses, then the firewall). It never deletes the server the
  home moved to: replace the server instead. There is no moving back to the
  Mac in this version, and deleting that server in Hetzner's console does not
  bring Fermix back to it: the home is restored from a snapshot onto a new
  server. Hetzner's root password for the
  server is never kept, and restoring a lost one starts from Hetzner's
  root-password reset (below). Pasting the token, creating, restarting and
  deleting the server are the owner's decisions, refused to a command Fermix
  runs. While the server stands, a new token replaces the kept one only when
  it is from the same Hetzner project (a token that stopped working is
  replaced by a new one from that project; one for another project is
  refused). On a computer whose home already moved to that server, Fermix
  creates another only to replace it (below); a home that moved to a server
  of the owner's own is replaced with a code from Always On used on a Linux
  server of theirs.
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
  https://fermix.ai/always-on | sudo sh`, which carries no code: the server's
  first boot asks for it on the terminal without echo, so it never lands in a
  shell history. **Cancel the code** on the token screen closes it. The code
  is `fxenroll1.` and a long string that carries
  a one-time secret, the primary's gateway key, its iroh endpoint id and
  relays, its name and when the window closes. The window lasts thirty
  minutes (time for a cloud server to boot), takes one server, and opening
  another replaces it, except while a server Fermix created on Hetzner waits
  on its own 24-hour code (until it enrolls, and then while the primary holds
  it for its move), when a new code is refused; deleting that server lets a
  new code open again. A 24-hour code opens only inside a server Fermix
  creates: on this computer, or for the desktop that replaces this server,
  which asks for it over the link; it is never shown to copy. The code is
  shown once and never logged, and the
  window is kept on this machine (`mobile/enrollment.json`, 0600, never in a
  snapshot) so an engine restart before the server checks in loses nothing.
  A server whose acceptance was lost on the way and that asks again with the
  same key hears it again, as the same candidate, while the window lasts. The
  file keeps the secret only while it can still admit a server: once one is
  recorded, or the window is over, the secret leaves it, and the
  state and expiry stay for the status. It needs Reach from
  anywhere on and ready: otherwise it is refused by name ("Remote reach is
  off…", or "…starting; open the code again in a few seconds").
- **The candidate.** `fermix home enroll --code-file PATH
  [--snapshot-bucket B --snapshot-region R]` (what the server's first boot
  runs) makes a fresh home a candidate primary: it writes
  `<home>/candidate/` (the code, the snapshot bucket and region the new
  primary will write to, its own iroh key, its Noise key and a one-time
  snapshot recipient, all 0600) and
  `[fermix_core.engine] role = "candidate"`, and removes the code file. It
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
  `fermix home enroll` again: a candidate that never enrolled is replaced
  (one that enrolled and waits for its move is not).
- **Reviewing it.** `fermix home candidates` (or `home.candidates.list`)
  lists the candidates the primary holds (at most four, each for 24 hours):
  id, name, system, version, and the snapshot bucket it was told.
- **The readiness report.** Before the move, `home.move.readiness
  {candidate_id}` (the apps' review step) answers each fact as `ok`, `warn` or
  `block`: the secrets this computer keeps in its keychain, which move with
  the home (one the keychain will not give blocks, named as its settings row
  labels it, "your Anthropic key", one no row shows counted, never by its id
  or its value); the server's Fermix (an older one blocks); free disk here (the
  capture needs about twice the home; short of it blocks, with the numbers);
  a home over one S3 upload (5 GiB) when the server keeps snapshots in S3
  (warns: it would never back up there); on a server of another system, the
  plugins the catalog has no build of for it (warns, named: they stop
  working; the server installs every other one again itself); what this
  home has turned on that runs only here stopping after the move, each named
  (iMessage on a Mac, voice calls, meetings; nothing to warn of when none is
  on); WhatsApp
  turned on (warns: it needs an address on the internet the server does not
  have, so it stops); Slack turned on without Socket Mode (warns: it stops
  unless switched to Socket Mode in the Slack app's settings and Fermix's);
  coding agents approved here (warns: a move withdraws that approval, as
  every restore does, so they ask again on the server); the cutover gap
  (Telegram messages sent during the move wait until it is done, and a
  recurring job more than an hour late is skipped); this computer
  serving nothing while the move runs; and Fermix run from a terminal
  (`fermix run`, warns: "Fermix runs from a terminal here, so it stops when
  the move starts. Start it again to finish."; the Mac app's engine,
  Fermix's own systemd unit (`fermix.service`, as the Linux package and
  `fermix service install` run it) and a `fermix service` install start again
  by themselves, while a shell inside any other unit, such as a terminal's,
  does not). **Move now** runs it at the press (a ready review under 15
  minutes old is taken as it was shown), and **Check again** runs it again.
  The move does not start while anything blocks, and Move now says each
  block; a warning the screen did not name yet comes back as the screen with
  that warning in Move now's confirm, so the owner accepts it first. Checking
  the keychain reads
  each secret, which opens the keychain and can ask the owner to allow it; a
  start within 15 minutes of a ready review takes that review rather than
  reading it again, so a move opens the keychain in the review and once more
  when its capture carries the values. Every Always On step (a token, a
  server created, powered or deleted, a code, a review, a move) is the
  owner's decision: a process Fermix started is refused on `daemon.sock`
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
  desktop's own key goes to `device/desktop_key` and its row into the device
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
  bucket, region and recovery key, and
  iMessage turned off on a server that is not a Mac, in `candidate/staging`),
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
- **Replacing the server** runs through the same move, started from the
  desktop's Always On: the desktop asks the server for an enrollment code,
  the new server enrolls with it, and Move now starts the move on the old
  server with `keep_as_desktop` false, so the old server keeps no desktop
  key, row or link and serves nothing once the move commits; the server
  checks the passphrase against its own recovery key. Moving Fermix back to a desktop is not part of this release: to
  bring it back to a computer, restore the newest snapshot into a fresh home
  there.
- **Replacing a server Fermix created on Hetzner** (Always On's details,
  Replace the server, on the computer the home left, which keeps the token
  and the record of what Fermix created): pick the size and location, and
  Fermix asks the old server for a 24-hour code (the old server opens one only
  when its desktop asks), creates the new server with it, named apart from
  the old one, and keeps both in its record, the old one holding the home.
  While the new one waits, no other code opens on the old server. Once it
  enrolled, the owner reviews and starts the same move to it, with the
  recovery passphrase; the old server serves nothing while the move runs.
  When this computer next reaches its server and finds it one epoch above
  the old one, the move is done: this computer names the new server from
  then on, and Fermix deletes the old server by itself, once (its addresses
  unless they went with it, then its firewall). If that
  delete fails, the old server stays listed, with why, and Delete tries it
  again; the new one, which now holds the home, is never deleted from here.
  Before the move, Cancel or Start again deletes only the new server, closes
  its code on the old one and leaves the home where it was; a move the old
  server undid leaves the new one waiting for its move again. Replace is
  refused while the new server stands, while the move to it runs and while the
  old one is not deleted yet, each in one sentence.

## Snapshots and the recovery passphrase

- A primary can keep encrypted snapshots of its home in an S3 bucket (AWS or
  any S3-compatible service), so a lost host is recovered by restoring the
  newest one. A snapshot carries what an export carries, taken while Fermix
  runs: the memory database is copied consistently and nothing is torn.
- Snapshots are encrypted to a recovery key derived from a recovery passphrase
  the owner chooses (at least 12 bytes). `fermix home snapshots passphrase
  --passphrase-file PATH`, or Fermix asking twice without echo, sets it on a
  running primary; Fermix keeps only the key derived from it and never the
  passphrase, so it writes snapshots on its own and only the passphrase opens
  them. Whoever holds the passphrase and a snapshot can stand up the primary.
- They are on once a recovery passphrase is set and a bucket is named in
  `[fermix_core.snapshots]` (`s3_bucket`, `s3_region`, and `s3_endpoint` for a
  service that is not AWS), every `interval_hours` (default 6). Fermix signs
  with the secrets `snapshot_s3_access_key_id` and
  `snapshot_s3_secret_access_key` (stored with `fermix settings secret set`).
  The key should only be allowed to write objects: Fermix never lists, reads
  or deletes them, and a versioned bucket keeps every snapshot.
- Each snapshot is `<prefix>/<profile>/<UTC time>-e<epoch>.fxsnap` in the
  bucket. It counts as stored only when the bucket accepted its SHA-256
  checksum; a failure keeps the bucket's own words and is retried at the next
  interval. **Back up now** in Always On takes one now (on a linked desktop
  it asks the server). A bucket named with
  dots is addressed path-style, which S3's certificate covers. A capture
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
  names the primary (its name, gateway key, iroh node id and relays, and the
  highest primary epoch this desktop has seen) and `<home>/device/desktop_key`
  is the desktop's own key, used only at mode 0600 (a looser mode is refused
  by name and nothing is dialed). Both stay on this computer.
- The Mac or Linux app changes nothing: it keeps talking to this computer's
  own Fermix sockets, and this Fermix carries what belongs to the primary over
  one encrypted session through the iroh rail. The app's chat goes to the
  primary, each app connection as one channel: messages, history, search,
  turns, approvals and proposals are the primary's. Only the owner's app is
  carried; a process this Fermix started (a command the primary asked this
  desktop to run) or one running detached is refused. Media a chat row names
  is fetched from the primary and handed to the app as a file on this
  computer, as always.
- Settings and other Fermix-wide requests from the app go to the primary
  too, the home's recovery, enrollment and move included (snapshots, a new
  enrollment code, the servers waiting, the move's readiness and the move
  itself): after the move the server holds them. What configures this
  computer is answered here: Fermix's own status and lifecycle, its logs,
  diagnostics and Doctor, the setup page, computer use, iMessage, the browser
  and capability installers, and the settings sections sandbox, computer
  use, computer history and iMessage.
- Two answers are put together here: the home's status is this computer's
  own (its role, its link to the primary, where the move went) with the
  primary's own picture added (its recovery, its enrollment and candidates,
  its move), and the list of settings sections is this computer's own with the
  primary's others. The primary's part is asked within 5 seconds; while it
  cannot be had, this computer's part is still shown and a sentence says why
  the primary's is missing. This computer's own old snapshot status is a
  retired copy and is not shown as the home's recovery.
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
  The server refuses to remove this computer from its devices ("This desktop
  cannot be removed: …"), since this version cannot link it again and it
  keeps copies of the server's backups.
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
- The engine's `home.status` (what the apps draw, and `fermix home status
  --json`) shows the link: the primary's name, whether it is connected and
  since when, the epoch, and the sentence. On the primary the same picture
  lists its desktops, each with whether it is connected.

## Where each Always On fact and action lives

- Every surface draws one picture, the engine's `home.status`, and acts
  through the same `home.*` methods and settings sections: the Fermix Mac and
  Linux apps' **Always On** pane and the CLI. Nothing on one surface is
  missing from the other except where the table says so.
- **One summary says where Always On stands.** `home.status` carries
  `summary`, the Always On screen: one sentence and at most one action,
  worked out once by the engine, which the apps, the setup page and `fermix
  home status` (first, before the rest) all print as they are. Every action,
  wherever it sits, says what the surface must collect first (a token, the
  recovery passphrase, or a choice of size and place), the sentence the owner
  accepts before Fermix spends money, deletes, restarts a server or moves
  (never with a time or a price in it; Move now's names what stops or waits
  after the move, from this home's settings), the page Learn more and Open
  Hetzner open, and a key. Its words never name an epoch, the
  primary, a candidate, the relay, the rail, a phase, the daemon (a problem
  points to Fermix's log) or an error code (a refusal of Hetzner's is said in
  its message alone), and a secret is named as its settings row labels it.
  Its states:
  - before the move, on the computer that sets it up: nothing set up ("Keep
    Fermix running when this Mac sleeps. It moves to a server you own.", with
    a second line only when this home uses something that stops after the
    move, naming only that: iMessage on a Mac, voice calls, meetings; and
    **Set up**, which asks for the token); the token step ("Paste a
    Hetzner API token…", whose How to get one says to turn on two-factor
    sign-in in Hetzner and make a project for Fermix alone; **Cancel the
    code** while a code for a server of the owner's own is open); the token
    works (choose the server); creating (from the moment a step starts:
    creating, deleting, turning on or restarting the server, each with the
    step in hand, then starting, installing Fermix, connecting, with
    **Cancel** while it creates); ready (**Move now**, with the review's
    warnings, and that there is no way back to this Mac in this version); the
    move undone (**Try again**);
  - on the computer the move leaves: moving ("Waiting for your server to
    confirm the move. Fermix keeps trying." once it waits on the server);
    "Fermix runs on your server. Last backup 2 hours ago." once linked; no
    longer connected to it (**Learn more**); while it replaces the server
    Fermix created on Hetzner: creating, starting, installing Fermix on or
    connecting the new server (**Cancel**), "Your new server is ready for the
    move." (**Move now**), "Moving to your new server. Messages wait until it
    is done.", removing the old server, and a problem of the new server in
    its own words (**Start again**, or **Delete your old server** when
    deleting the old one stopped after the move);
  - on the server: waiting for its move, then "Fermix runs here.";
  - a problem, in one sentence with the one action that fixes it: turned off
    (**Turn it on**), no answer for 10 minutes of this computer being awake
    while Hetzner says it runs (**Restart server**), deleted in Hetzner, never
    checked in within 30 minutes of being awake for it or waited past its 24
    hours (**Start again**), no capacity (**Create in** the next location in
    stock), the account's limit (**Open Hetzner**, beside the own-server
    path), a token that can only read or stopped working (**Paste a new
    token**), this computer too old for its server (**Update**), the server's
    disk 85% full or more, the last backup over 3 days old (**Back up now**),
    a review that blocks the move (**Check again**), turning the server on or
    restarting it that stopped (**Turn it on**, **Restart server** again), a
    delete that stopped (**Delete your server** again), and a step Fermix's
    own restart cut short (**Start again**). Every step's ending is kept on
    this computer, so the problem outlives the step. Before the move, while
    the created server stands, Details also says it costs money and offers to
    delete it.
- Details holds the rest: every provider's token screen, how Hetzner bills,
  the server's facts and the review's items, Back up now and Replace the
  server, what lives on the server (conversations and memories, the secrets,
  the browser, traces) with the plain fact that its host can technically read
  its disk (snapshots are encrypted to the recovery passphrase), and lines the
  engine finishes: the server, its size, place, address, system and version,
  until when it waits, each place's last backup, the space this computer's
  copies take, the server's disk, when Hetzner was last checked and what the
  server costs a month, from the offer its create chose. Times are stated in
  the owner's time zone as dates and times, never as ages. Learn more opens
  the Always On docs at Hetzner's part.
- The summary also names the latest occurrence the apps raise as a system
  notification (`notice`): the server ready, the move done, the server out of
  reach, a server that must be set up again, the last backup a week old. Each
  keeps one id while it stands, so an app posts it once.
- When the server's newest backup passes 7 days it tells the paired phones,
  once per occurrence, as a message in the owner's phone chat: open Fermix on
  the Mac to back up now.
- **No polling.** The apps never ask for the summary on a timer. The chat
  socket tells a connected app that it changed (`home_status_changed`, which
  carries nothing; the app then reads `home.status`): once when the app
  connects unless Always On is off, and whenever the summary's key moves:
  anything a surface draws, the step in hand, a confirm, an alternative, a
  Details line or the notice included, but never the clock alone (a
  backup's age in a sentence, when Hetzner was last checked). Nothing is told while Always On stays off, not even a settings
  change to what the off line names: the app forgets Always On while it is
  off and reads that line when the pane opens. Fermix works the change out
  without polling: it reads the summary
  again only when something it rests on happens (the move's phase, the
  enrollment code opened, used, withdrawn or expiring, a server enrolling,
  the provider's file written, the link to the server up or down, a backup run
  finishing) and at the next time it changes by the clock
  alone (30 minutes awake for a created server to check in, 10 minutes awake
  of silence, a waiting server's 24 hours, a backup's 3 days and its 7), on
  one timer, armed again at each read and after a wake from sleep, and only while an app
  is connected. While Always On is off nothing is armed, and only a token, a
  code or a move is read. The watch never asks the cloud provider itself: a
  `home.status` read that shows a problem, a step or a ready server, while a
  server Fermix created stands, checks with Hetzner at most once a minute, as
  a job of the same family as every step, so never beside one. A
  `home.status` asked with the key it was drawn with and a wait (`after`,
  `wait_ms`, at most 25 seconds) is answered once the key moves, which is how
  a terminal follows a step without polling. After a move the desktop's Fermix tells its app about its own
  summary, reading the server's part again when the server says its own
  moved; while the server is unreachable the chat connection is refused, and
  the app reads the summary then. A server's disk filling is seen at the next
  thing that happens (on the server, every backup run).
- **From a terminal: `fermix always-on`.** On a Homebrew or Linux install
  without the Fermix app, this is how Always On is set up. With no step it
  prints the summary (its sentence, the step in hand, Details) and each step
  with its command; on a terminal it numbers them, Enter takes the main one
  and `q` quits, and for the step taken it asks what the step needs: the
  provider's How to get one and the token without echo (with the count of
  characters it read), the size and place as a numbered list of what Hetzner
  has in stock, grouped by city, with the recommendation first and each
  offer and its price in Fermix's words, the recovery passphrase without
  echo (twice where none is set yet), and the confirm as `[y/N]`, No unless
  answered. It prints the step's id as it runs, never what was typed, then
  waits for Always On to move on (a step's job, the move, a code waiting for
  its server) and offers the next step. The code for a server of your own is
  printed once, under the command to run on it. `fermix always-on STEP` takes
  one step, by the action's id with `-` for `_` (`paste-token`,
  `create-server`, `create-in`, `cancel`, `turn-on`, `restart-server`,
  `start-again`, `delete-server`, `own-server`, `back-up-now`,
  `replace-server`, `check-again`, `move-now`, `try-again`; `learn-more` and
  `open-console` print their page). With no terminal or with `--json` it asks
  nothing: `--stdin` reads the token from a pipe (`--provider ID` when more
  than one provider is offered), `--recovery-passphrase-file PATH` the
  passphrase, `--type` with `--location` the size and place (else Fermix's
  recommendation), `--yes` accepts the step's confirm, and `--wait` waits; a
  need no flag gives exits 2 naming the flag, and a confirm without `--yes`
  refuses `confirm_required`. A token or passphrase typed as an argument is
  refused. The wait asks `home.status` with the screen's key and stops after
  45 minutes with the screen as it stands; Ctrl-C stops it and the step goes
  on. During Move now the engine restarts, so the wait reconnects for up to
  90 seconds and otherwise says "Start Fermix again to finish the move." If
  Always On changed since the screen was read (another window pressed first),
  it says so (`changed`) and shows the screen again; a Move now sent to the
  server whose answer was lost says so and is followed as a started move;
  any other refusal is the engine's own sentence (`action_refused`). It needs Fermix running
  (`engine_stopped` otherwise, writing nothing), and on a home the Mac app
  manages it refuses `app_managed`, naming the app's Always On pane.
  `fermix home status` ends its summary line with where the next step is
  taken: `fermix always-on`, or the Fermix app on a home the app manages.
- The browser setup page's **Always On** tab sets nothing up yet and shows
  the summary, read when the tab opens and on **Refresh**: its sentence, and
  its action as the Fermix app's to take, or Learn more.

| Fact or action | App | CLI |
|---|---|---|
| Where Always On stands: one sentence and at most one action (`summary`) | The pane's first line and its button | `fermix home status`, first; `fermix always-on` |
| The role and the epoch | This computer | `fermix home status` |
| On a desktop: the primary (connected or not, since when, its sentence), or where the home moved | The primary | `fermix home status` |
| On the primary: its desktops, each connected or not | Desktops | `fermix home status --json` |
| Whether a recovery passphrase is set; each place snapshots go, its last verified snapshot (and the recovery key it opens with), a desktop copy that is waiting, and its last error | Recovery | `fermix home snapshots status` |
| Set the recovery passphrase | Recovery: typed twice, never shown; a change says which snapshots open with which passphrase | `fermix home snapshots passphrase` |
| On the primary: the secrets that did not resolve on this host (`secrets_missing`), by id | Secrets to enter again | `fermix home status` |
| Where snapshots are kept (bucket, region, the S3-compatible address, how often) and the two access keys | Recovery: the `snapshots` section; the keys as hidden fields, never shown again | `fermix settings set snapshots …`, `fermix settings secret set snapshot_s3_access_key_id` |
| Take a snapshot now (`home.act` `back_up_now`) | **Back up now**, offered once snapshots have somewhere to go | `fermix always-on back-up-now` |
| An enrollment code for a server of your own (`home.act` `own_server`) | **Use my own Linux server**: the code shown once with **Copy** and when it expires, beside the command for the server, which carries no code; **Cancel the code** closes it | `fermix always-on own-server`, the code printed once under the command; `cancel` closes it |
| The cloud providers Fermix creates the server on (Hetzner today), each with its name, token label, How to get one and console (the summary's `detail.providers`) | The token screen | `fermix home status --json` |
| A Hetzner token: pasted once, checked at once, kept on this computer (`home.act` `paste_token`) | Paste a token, with How to get one | `fermix always-on paste-token`: asked without echo, or `--stdin` |
| The sizes and locations Hetzner has in stock, with the monthly price (`home.provision.options`) | The recommendation, and Change | Numbered on a terminal, the recommendation first; `--type` and `--location` |
| Create the server on Hetzner (`home.act` `create_server`, a job), in the next place when the first had none (`create_in`) | **Create server**, **Create in CITY** | `fermix always-on create-server`, `create-in` |
| The server Fermix created, what it costs and when Hetzner was last read back (the summary's Details) | Details | `fermix home status` |
| Turn the created server on, or restart it (`home.act` `turn_on`, `restart_server`) | **Turn it on**, **Restart server** | `fermix always-on turn-on`, `restart-server` |
| Delete what Fermix created on Hetzner (`home.act` `delete_server`, `cancel`, `start_again`), never the server the home moved to | **Delete your server**, **Cancel**, **Start again** | `fermix always-on delete-server`, `cancel`, `start-again` |
| On a linked desktop: replace a server Fermix created on Hetzner (`home.act` `replace_server`), the move to it as below, then the old one deleted by itself | Replace the server, then Move now; the old server listed with Delete if its delete failed | `fermix always-on replace-server`, then `move-now` |
| The servers waiting for the move | Servers waiting for the move | `fermix home candidates` |
| Review the move: each item ready, a note or a block | Move now reviews at the press; **Check again** on a block | The same; `fermix always-on check-again` |
| Start the move (`home.act` `move_now`, `try_again`) | **Move now**, the recovery passphrase asked first | `fermix always-on move-now`, `try-again`: the passphrase asked without echo, or `--recovery-passphrase-file` |
| Where the move stands (its phase and sentence) | The move | `fermix home status` |
| On a linked desktop: the server's own recovery, its move, and the secrets it could not resolve (the composed `primary_home`, or why it is missing) | The server's recovery (**Back up now** asks the server), The server's move | `fermix home status --json` |
| On a linked desktop: replace the server (a code from the server, the review on it, then the move with `keep_as_desktop` false) | Replace the server, then **Move now** with the server's recovery passphrase (the server restarts, never this computer) | `fermix always-on replace-server`, then `move-now` with the server's recovery passphrase |

- In the device role the browser setup page opens on Always On and leads
  with a notice that Fermix-wide settings live on the server and are changed
  in the Fermix app on this computer. Its tabs for providers,
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
