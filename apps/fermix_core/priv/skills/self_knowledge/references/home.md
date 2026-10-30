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
  a host with no usable keyring (macOS keeps its keyring), and names the
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
  Debian 13 or Ubuntu 24.04 host (arm64 or x86_64):
  `curl -fsSL https://fermix.ai/always-on | sudo sh`, which asks for the code
  without echoing it. After `sh -s --`:
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
  candidate role, enrolls with the primary and waits for the move. Running it again is safe: a host whose home exists is not enrolled
  again. It never prints the code; cloud-init's console log shows each step.
- **Updates on the server.** Nobody logs in to it, so it updates itself.
  Debian's security updates: `unattended-upgrades` every day (the first boot
  installs it where the image lacks it and sets its two daily switches in
  `/etc/apt/apt.conf.d/21fermix-always-on`). Fermix: the package comes from
  release files, not an apt source, so `fermix-update.timer` (root) runs
  `/usr/local/sbin/fermix-update` every night at 04:00 UTC: the installer
  again, `fermix restart` as `fermix` only when the installed version changed,
  then a reboot when `/run/reboot-required` exists. A night that fails stops
  before the restart and the reboot, leaves the running engine as it was and
  says why in `journalctl -u fermix-update`; the next night tries again. So a
  server's engine can be up to a day behind the Mac's.
- **Memory.** Out of memory the kernel stops one process. The swap file makes
  that rarer, and on Linux the engine starts Chrome, and so every Chrome
  process, with `oom_score_adj` 1000, so the kernel stops Chrome before the
  engine. Both values are constants until they are measured on a real server.
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

- **The code.** On the primary, `fermix home enroll-code` (or the
  `home.enroll.open` management method the apps call) opens an enrollment
  window and shows its code once: `fxenroll1.` and a long string that carries
  a one-time secret, the primary's gateway key, its iroh endpoint id and
  relays, its name and when the window closes. The window lasts thirty
  minutes (time for a cloud server to boot), takes one server, and opening
  another replaces it; the code is shown once and never logged, and the
  window is kept on this machine (`mobile/enrollment.json`, 0600, never in a
  snapshot) so an engine restart before the server checks in loses nothing.
  A server whose acceptance was lost on the way and that asks again with the
  same key hears it again, as the same candidate, while the window lasts. The
  file keeps the secret only while it can still admit a server: once one is
  recorded, or the thirty minutes are over, the secret leaves it, and the
  state and expiry stay for the status. It needs Reach from
  anywhere on and ready: otherwise it is refused by name ("Remote reach is
  off…", or "…starting; open the code again in a few seconds").
- **The candidate.** `fermix home enroll --code-file PATH
  [--snapshot-bucket B --snapshot-region R] [--instance-file PATH]` (what the
  server's first boot runs) makes a fresh home a candidate primary: it writes
  `<home>/candidate/` (the code, the snapshot bucket and region the new
  primary will write to, what the host says of itself, its own iroh key, its
  Noise key and a one-time snapshot recipient, all 0600) and
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
  id, name, system, version, and the instance facts the server reported
  about itself, which nobody verified.
- **The readiness report.** Before the move, `home.move.readiness
  {candidate_id}` (the apps' review step) answers each fact as `ok`, `warn` or
  `block`: the secrets this computer keeps in its keychain, which move with
  the home (one the keychain will not give blocks, named by its id, never its
  value); the server's Fermix (an older one blocks); free disk here (the
  capture needs about twice the home; short of it blocks, with the numbers);
  a home over one S3 upload (5 GiB) when the server keeps snapshots in S3
  (warns: it would never back up there); plugins built for another system
  (warns, named); voice calls and meetings, and iMessage on a Mac, stopping
  after the move; the cutover gap (Telegram messages sent during the move
  wait until it is done, and a recurring job more than an hour late is
  skipped); and this computer serving nothing while the move runs. The move
  does not start while anything blocks, from the apps or
  from `fermix home move`, which says each block. Checking the keychain reads
  each secret, which opens the keychain and can ask the owner to allow it; a
  start within 15 minutes of a ready review takes that review rather than
  reading it again, so a move opens the keychain in the review and once more
  when its capture carries the values. Reviewing and starting a
  move, like opening a code, are the owner's decisions: a process Fermix
  started is refused on `daemon.sock`.
- **Starting the move.** `fermix home move --to ID [--recovery-passphrase-file
  PATH] [--retire]` (or `home.move.start {candidate_id, recovery_passphrase,
  keep_as_desktop?}`) writes
  `<home>/.move/request.json` (the move id, the candidate, and the recovery
  key derived from the passphrase, which itself is never stored), sets the
  role to `device` and restarts Fermix through its own stop, which the service
  manager brings back (the Mac app's agent and launchd units keep it alive;
  the Linux service restarts always). Under a systemd user service a restart
  Fermix chooses resets the service's start budget first, so moves never use
  up the starts a crash loop is held to. An engine started by hand with `fermix
  run` just stops; start it again. With Fermix stopped the command writes the
  request and the role itself, and the move starts when Fermix does. Keep the
  recovery passphrase: the new primary's snapshots open only with it.
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
  takes a snapshot at once. The keychain's secrets land in the server's
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
  plain files, held by the disk's encryption (the owner encrypts the disk
  where its host does not) and by Fermix's sandbox, which keeps them from
  every command Fermix runs. The secrets this computer kept in its keychain
  move into those files.
- After a move, or a restore, `home.status`'s `secrets_missing` on the
  primary names each secret reference that did not resolve on that host (by
  the id `fermix setup` and the app take), and the settings rows show those
  secrets as not set rather than set: each needs entering again there.
- **Replacing the server** runs through the same move, started from the
  desktop's app: the desktop asks the server for an enrollment code, the new
  server enrolls with it, and the move starts on the old server with
  `keep_as_desktop` false (`home.move.start`; true unless said), so the old
  server keeps no desktop key, row or link and serves nothing once the move
  commits. On a server primary with no desktop to start it from, the same
  move is `fermix home move --to ID --retire` at the server's own terminal.
  Moving Fermix back to a desktop is not part of this release: to
  bring it back to a computer, restore the newest snapshot into a fresh home
  there.

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
  interval. `fermix home snapshots run` takes one now. A bucket named with
  dots is addressed path-style, which S3's certificate covers. A capture
  needs about twice the home free on the disk and is refused with the
  numbers otherwise.
- Each stored point names the recovery key it was written for (its key id,
  as setting the passphrase shows it). After the passphrase changes, the
  snapshots written before open only with the earlier one, and setting it
  says so.
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
  When the server does not know this computer (it was revoked from the Mac
  app, the phone or the server itself, or the server was restored from a
  snapshot taken before this computer joined it), this desktop stops trying
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
- The browser setup page's **Always On** tab sets nothing up and shows one
  sentence for where Fermix runs, read when the tab opens and on
  **Refresh**: on the primary that Fermix runs on this computer; on a desktop
  the link's own sentence, or, with no link, where the home moved.

| Fact or action | App | CLI |
|---|---|---|
| The role and the epoch | This computer | `fermix home status` |
| On a desktop: the primary (connected or not, since when, its sentence), or where the home moved | The primary | `fermix home status` |
| On the primary: its desktops, each connected or not | Desktops | `fermix home status --json` |
| Whether a recovery passphrase is set; each place snapshots go, its last verified snapshot (and the recovery key it opens with), a desktop copy that is waiting, and its last error | Recovery | `fermix home snapshots status` |
| Set the recovery passphrase | Recovery: typed twice, never shown; a change says which snapshots open with which passphrase | `fermix home snapshots passphrase` |
| On the primary: the secrets that did not resolve on this host (`secrets_missing`), by id | Secrets to enter again | `fermix home status` |
| Where snapshots are kept (bucket, region, the S3-compatible address, how often) and the two access keys | Recovery: the `snapshots` section; the keys as hidden fields, never shown again | `fermix settings set snapshots …`, `fermix settings secret set snapshot_s3_access_key_id` |
| Take a snapshot now | **Back up now**, offered once snapshots have somewhere to go | `fermix home snapshots run` |
| An enrollment code | **Get a code** (**Get a new code** while one is open, which stops the open one working), shown once with **Copy** and when it expires, beside the command for a server you have, and what to know before moving (the disk it needs, that this computer serves nothing meanwhile, the cutover gap, where the server keeps secrets, no way back) | `fermix home enroll-code` |
| The servers waiting for the move, with the instance facts they reported (unverified) | Servers waiting for the move | `fermix home candidates` |
| Review the move (`home.move.readiness`): each item ready, a note or a block | **Review the move** on a server waiting; a block is shown as one | `fermix home move` says each block |
| Start the move | the app's pane | `fermix home move --to ID [--retire]` |
| Where the move stands (its phase and sentence) | The move | `fermix home status` |
| On a linked desktop: the server's own recovery, its move, and the secrets it could not resolve (the composed `primary_home`, or why it is missing) | The server's recovery (**Back up now** asks the server), The server's move | `fermix home status --json` |
| On a linked desktop: replace the server (a code from the server, the review on it, then the move with `keep_as_desktop` false) | Replace the server: **Get a code**, **Review the move**, the passphrase typed twice, **Move to NAME** (the server restarts, never this computer) | none |

- In the device role the browser setup page opens on Always On and leads
  with a notice that Fermix-wide settings live on the primary and are changed
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
