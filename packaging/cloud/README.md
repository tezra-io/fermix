# Always On servers (`packaging/cloud`)

A server that becomes the owner's Fermix primary (M75 step 6, D21). One
script, two modes:

- **Any Debian 12, Debian 13 or Ubuntu 24.04 host** (arm64, x86_64) whose
  kernel gives Landlock ABI 3 or later: Linux 6.2 or later with Landlock
  enabled, as Debian 13 and Ubuntu 24.04 have by default. Debian 12's own 6.1
  gives ABI 2, so a stock Debian 12 is refused, and one on a 6.2 or later
  kernel is not:
  `curl -fsSL https://fermix.ai/always-on | sudo sh`, which serves
  `first-boot.sh` byte for byte and asks for the code without echo. Cloud-init
  user data can run it with the code in `FERMIX_ENROLL_CODE` instead.
  `--version X` names the release to install: the one the computer that sets
  the server up runs, which Always On's command for the server passes, so the
  home can always move back there; without it, the latest. `--tailscale`
  joins the server to the owner's tailnet before it enrolls (below).
- **Enroll** (the default) makes the server a candidate the primary moves
  to. **Restore** (`--restore`) takes no code and enrolls nothing: it prepares
  the same hardened server and prints the exact steps that restore the newest
  snapshot of a primary that is gone.

| File | What it is |
|---|---|
| `first-boot.sh` | The root first boot. POSIX `sh`, run once, safe to run again. |
| `test/first_boot_test.sh` | shellcheck, then the script's own main on this host (`test/on_host.sh`), then the script in throwaway `debian:trixie-slim` containers (`test/in_container.sh`), one per scenario. |

## What the first boot does

First it checks the host and refuses, before it installs or writes anything,
an account other than root, a release other than Debian 12, Debian 13 or
Ubuntu 24.04, an architecture other than arm64 or x86_64, a `/run` that is
not a tmpfs, and a kernel below Landlock ABI 3 (the check that decides, not
the release): Fermix's Linux sandbox holds commands only
from ABI 3, and below it the engine installs and runs but refuses every
command. The ABI is the kernel's own answer to `landlock_create_ruleset`'s
version query (syscall 444 on both architectures), asked through `perl`
(`perl-base` is essential on Debian and Ubuntu); a kernel built without
Landlock, or booted without it in its `lsm=` list, answers none. It refuses
just as early a Tailscale auth key in `TS_AUTHKEY` without `--tailscale`, and,
with it, a key that is not one (below) or no key without a terminal. The
enrollment code and the key are both read and checked before either is
written.

A host whose Fermix home `/home/fermix/.fermix` exists already, a run again,
is read first, still before anything is installed: `fermix home status
--json` as `fermix` (it answers with Fermix running or not) gives the home's
`role` and, on a candidate, its move's `phase`.

- A candidate whose enrollment did not finish (`enrolling`, `failed` or
  `expired`: the code ran out before the computer was reached, it was used
  elsewhere or cancelled, or no move came within 24 hours) enrolls again
  with a new code, read like a first one: Fermix is stopped (`fermix service
  uninstall` as `fermix`, since the candidate is replaced only while no
  engine runs in the home), enrolled with the new code, started and waited
  for.
- A home that runs (the primary, or a candidate waiting for its move or
  receiving it) is bound and started as it is, and the run ends with "Done.
  Fermix runs from the home it already had." Given a code, it is refused.
- Any other home (a retired copy a move left, naming where Fermix moved; a
  desktop of another primary; a candidate whose move cannot be read; a home
  `fermix home status` refuses to read, with its sentence) is refused, and so
  is a candidate that did not finish under `--restore`.

Each refusal is one sentence that says what the home is and the commands
that remove it, should the owner want the server set up again (`sudo -H -u
fermix env XDG_RUNTIME_DIR=/run/user/<uid> /usr/bin/fermix service
uninstall`, then `sudo rm -rf /home/fermix/.fermix`, then the command
again). The script itself never removes a home.

Then, in this order, failing with one sentence and a non-zero exit at any
step:

1. Enroll mode only: writes the code to `/run/fermix/enroll.code` (tmpfs; the
   directory 0700 and the file 0600, root's until the engine account exists,
   then its). Restore mode refuses a code.
2. Loads the nftables table `inet fermix_metadata` (`/etc/fermix/metadata-block.nft`),
   which drops every packet to `169.254.169.254`, `100.100.100.200`,
   `fd00:ec2::254` and `fd20:ce::254` from every uid but 0, except DNS (udp
   and tcp 53) and time (udp 123), through
   `fermix-metadata-block.service`: before `network-pre.target` at every boot,
   again after `nftables.service` starts or reloads (which flushes the
   ruleset). User data that holds the enrollment code stays readable
   through the metadata service for the server's life. Some clouds
   serve DNS and time from the same address, so those two are accepted before
   the drop and keep working for every account; anything else a cloud serves
   there stays root's. An accept ends only this table's chain, whose policy is
   accept anyway, so it opens nothing another firewall on the host closes. The
   rule sits on the `output` hook, so it covers what the host's own processes
   send. A container's packets take the `forward` path and would pass it,
   which is one reason the server runs no containers: Fermix's Linux sandbox
   is Landlock, which confines commands in place. A container runtime would
   need its own rule.
3. Swap, the memory guard's first half: a host with no swap (many cloud
   images have none) gets a 2 GB swap file, `/swapfile` (0600, made with
   `fallocate` and `mkswap`, listed in `/etc/fstab`, turned on), so memory
   pressure slows the server before the kernel stops a process. A host with
   swap of its own keeps it and gets none, and a run again changes nothing.
   The guard's second half is the engine's: on Linux it starts Chromium with
   `oom_score_adj` 1000, inherited by each of Chromium's processes, so out of
   memory the kernel stops a Chromium process before the engine. Both values
   are constants until a measurement on a small real server sets them
   (M75 §3).
4. Installs the Linux package through `https://fermix.ai/install --no-setup`
   (`--version X` when it was given one), the installer every host uses, with
   its checks. The package's user unit
   runs the engine with `Restart=always` and at most five starts in ten
   minutes, so a crash loop stops and the budget comes back.
5. Updates, as nobody logs in to the server. Debian's own: `unattended-upgrades`
   (the Debian 13 cloud image installs it and its package turns it on by
   default; it is installed when an image lacks it), with
   `APT::Periodic::Update-Package-Lists` and `Unattended-Upgrade` set to 1 in
   `/etc/apt/apt.conf.d/21fermix-always-on`, and checked through
   `apt-config`; it installs security updates every day and never reboots on
   its own. Fermix's own: the package comes from release files, not an apt
   source, so unattended-upgrades never sees it, and the package's postinst
   restarts nothing. `fermix-update.timer` (root, `OnCalendar=*-*-* 04:00:00
   UTC`, `Persistent=true`) runs `fermix-update.service`, a oneshot bounded
   by `TimeoutStartSec=30min` that runs `/usr/local/sbin/fermix-update`: the
   release the computers this server serves run, read from `fermix home
   status --json`'s `update_ceiling` (the oldest engine among the desktops
   that reached it in the last 30 days), installed with the installer again
   (`--no-setup --version X`, with its sha256 check and the cosign signature
   check through the package's own cosign) when it is newer than the
   installed one in `dpkg --compare-versions`' order; an installed release
   newer than it is never installed back down, and no home, no computer seen
   or a `home status` that fails installs nothing that night (the last fails
   the night). So the home can always move back to its computer, the server's
   Fermix follows that computer's: a fix reaches the server the night after
   the computer has it. Then `fermix restart`
   as `fermix` when `fermix service status --json` says `pending_restart`
   (the running engine is older than the installed one, so a restart a night
   skipped or failed is still due the next night, and an engine that is not
   running, such as a restore host's before its import, is not started); then
   `systemctl reboot` when `/run/reboot-required` exists (unattended-upgrades'
   kernel hook writes it). A move under way is read from `fermix home status
   --json`, in the phases the move code treats as pending: `requested`,
   `streaming`, `committing` or `aborting` on a server sending its home
   (`FermixCore.Home.Move`'s pending list), `enrolling`, `receiving`,
   `staged` or `activating` on a candidate; ended phases (`committed`,
   `undoing`, `done`, `aborted`, `enrolled`, `expired`, `failed`) defer
   nothing. Only the restart rests on the engine account's answers: a move
   under way skips it, and so does a `service status` or `home status` that
   fails, in one journal line. The reboot is root's: a move defers it at most
   two nights in a row, counted in `/var/lib/fermix-update/reboot-deferrals`
   (root's, 0600, in a 0700 directory; cleared by a reboot and by a night
   without a move; a count that is not a number reads as the limit), and the
   third night reboots all the same and says so; a failed read of the engine
   counts as no move. Each night says what it did in one line per step. An
   installer that cannot be downloaded from `fermix.ai` never ran, so
   nothing changed and the restart and the reboot are still decided; one
   that ran and failed stops the night before both and leaves the running
   engine as it was, since its exit status (1 for a refusal before the
   package manager runs and for a failure after it) cannot say whether the
   package was touched. Any failure says why on stderr (the journal:
   `journalctl -u fermix-update`) and the night exits non-zero; the next
   night tries again. First boot writes the script again whenever it
   runs.
6. Creates the account `fermix` (home `/home/fermix`, `/usr/sbin/nologin`, no
   password), lingering, with `/run/fermix` recreated for it at every boot
   (tmpfiles.d) and a `user@<uid>.service` drop-in whose `ExecStartPre` refuses
   to start the account's service manager, and so the engine, while the
   metadata table is missing. Not `/var/lib/fermix`: it holds the root-owned
   loader every packaged engine executes, and no engine account may own a
   directory above it. A normal uid also keeps `journalctl --user` working.
7. With `--tailscale` (either mode), joins the owner's tailnet, so the
   server's tailnet address exists when it enrolls (below).
8. Enroll mode, as `fermix`, with a clean environment: `fermix home enroll
   --code-file /run/fermix/enroll.code [--snapshot-bucket B --snapshot-region
   R]`, then, with `XDG_RUNTIME_DIR=/run/user/<uid>` (systemctl reaches the user manager's
   private socket; no user D-Bus needed), `fermix service install --home
   /home/fermix/.fermix`. A candidate enrolling again is stopped first
   (`fermix service uninstall`); a home that runs is not enrolled again, which
   is said, and its service is bound and started again.
9. A browser for the agent's tasks. Debian: the distribution's `chromium`,
   which the engine's launcher finds on its `PATH` and starts headless as
   `fermix`, with Chromium's own sandbox. Ubuntu ships Chromium only as a
   snap, so nothing is installed and one sentence says to install a browser by
   hand (Google Chrome's own package, for example), or browser tasks answer
   that no Chrome or Chromium is installed.
10. Enroll mode: waits, up to 5 minutes, for the primary to accept the server
    (`fermix home status --json` shows the candidate `enrolled`), and fails
    with the candidate's own sentence when the enrollment expired or failed.
    Restore mode: prints the restore steps instead (below).

The code reaches the engine only as that file: never in an argument, never in
an environment the engine inherits (`env -i`), never in the output. An option
the script does not know is refused without being echoed, in case it is a code
pasted in the wrong place.

### Joining a tailnet (`--tailscale`)

Opt-in: without `--tailscale` nothing of Tailscale is installed, written or
run. With it:

- **The key.** A Tailscale auth key from `TS_AUTHKEY` (cloud-init user data,
  or any run with no terminal) or, when that is absent, asked for on the
  terminal without echo, after the enrollment code. It must start with
  `tskey-`, hold only letters, digits, `-` and `_`, and be 20 to 200
  characters long; anything else is refused, without echoing it, before
  anything is installed. An OAuth client secret (`tskey-client-`) is refused
  as not an auth key: `tailscale up` takes one only with tags the script
  never passes. The key is never on a command line and never printed:
  `TS_AUTHKEY` is unset before the script runs anything, and the key goes
  only to `tailscale.authkey` (0600) in the script's work directory under
  `/run` (tmpfs, 0700, root's), which `tailscale up --auth-key=file:PATH`
  reads and which is removed right after it, whether it joined or not, and
  with the work directory on every exit; a `kill -9` or a power loss
  mid-run skips that, and the file stays in `/run` until the next reboot
  empties it. Create the key in Tailscale's admin console tagged
  `tag:fermix-server`, after declaring that tag in the tailnet policy
  (below), so the server joins as a tagged device; the script passes no
  `--advertise-tags` of its own. A one-off, pre-approved key suits a server;
  one that is used up, expired or revoked is refused by `tailscale up`.
- **The package.** Tailscale's own package from its signed repository for
  the host's release (`https://pkgs.tailscale.com/stable/debian bookworm`,
  `debian trixie` or `ubuntu noble`), never a script piped into a shell. The
  repository's signing key (`<suite>.noarmor.gpg`) is downloaded over HTTPS
  and must hold Tailscale's package signing key alone, by its fingerprint
  `2596A99EAAB33821893C0A79458CA832957F5868` (`gpg --show-keys`, installed
  for it); only then is it written to
  `/usr/share/keyrings/tailscale-archive-keyring.gpg`, and
  `/etc/apt/sources.list.d/tailscale.list` names the repository with
  `signed-by` that keyring alone. Those are the paths Tailscale's own
  instructions use, so a host set up by them converges. Then `apt-get
  install tailscale` and `systemctl enable --now tailscaled.service`, each
  failing with one sentence.
- **A host with Tailscale already**, read from `tailscale status --json`
  before anything is installed. One whose daemon says `Running` is on a
  tailnet: without a key it keeps it, and the first boot names it
  (`CurrentTailnet.Name`), installs nothing of Tailscale and logs in again
  nowhere; with a key in `TS_AUTHKEY` it stops, naming that tailnet, rather
  than drop the key while the server stays on a tailnet that may not be the
  owner's (leave the key out to keep it, or `sudo tailscale logout` first).
  One that is logged in with Tailscale down (`Stopped`) stops too, with or
  without a key, since `tailscale up` with a key would log it in again: run
  `sudo tailscale up`, then the script again.
- **`tailscale up`**, bounded by `--timeout=2m`, runs after the engine account
  and before enrolling, so the server's tailnet address exists when it
  enrolls; one that fails stops the first boot there with one sentence: a
  key that is used up, expired or revoked needs a new one, and a server
  waiting for approval (a tailnet with device approval on and a key that is
  not pre-approved, for which `tailscale up` prints a link) is approved there
  and the script run again without a key. Either way the first boot says the
  server's tailnet address (`tailscale ip -1`).
- **Restore mode** takes `--tailscale` too: the server joins the tailnet the
  same way, then prints the restore steps.

Never pass `TS_AUTHKEY` on sudo's command line (`sudo TS_AUTHKEY=… sh`):
sudo logs it, as `ENV=TS_AUTHKEY=…` in the line it writes to the system
journal for every command it runs; every account on the server can read it in
sudo's own command line in `/proc` while the run lasts; and the shell keeps
it in its history. At a terminal, leave it out and let the script ask.
Cloud-init runs the user data as root, so it needs no sudo: give the code and
the key as assignments in front of `sh`, in a `runcmd` item written as one
string, which cloud-init hands to a shell, so neither is in any process's
command line (an item written as a list is run as one command line, key
included):

```yaml
#cloud-config
runcmd:
  - curl -fsSL https://fermix.ai/always-on | FERMIX_ENROLL_CODE='<the code>' TS_AUTHKEY='<a one-off auth key>' sh -s -- --version X --tailscale
```

with `X` the release Always On's command names. Cloud-init keeps the user
data, the code and the key with it, on the server's disk (under
`/var/lib/cloud`, root's), so use a one-off key, which joins nothing once it
has been used.

### The tailnet policy

The policy is the owner's: the first boot opens no port and adds no firewall
rule for the tailnet. Three parts of the tailnet policy file (HuJSON, on the
admin console's Access controls page) concern the server:

```jsonc
{
  // Declared before the key is created: the key form offers only the tags
  // listed here.
  "tagOwners": {
    "tag:fermix-server": ["autogroup:admin"]
  },
  // Only the owner's own devices reach the server.
  "grants": [
    {"src": ["autogroup:member"], "dst": ["tag:fermix-server"], "ip": ["*"]}
  ],
  // Only with webhooks (WhatsApp, cue webhook sources): Tailscale Funnel.
  "nodeAttrs": [
    {"target": ["tag:fermix-server"], "attr": ["funnel"]}
  ]
}
```

The grant holds only once the policy stops allowing everything: a new
tailnet's file starts with a rule from `*` to `*:*`, and a file with no rule
at all is read as that same allow-all. Removing that rule, or adding any rule
to a file that has none, turns allow-all off for every device, so the file
then needs a rule for whatever the owner's other devices reach today.

Webhooks reach the server through Tailscale Funnel, with the mount commands
Always On shows once Fermix runs there. Funnel also needs MagicDNS and HTTPS
certificates on (the admin console's DNS page), and a new server name can
take up to ten minutes to resolve, so a sender's first check right after the
mount may fail.

### The restore steps it prints

In a shell on the server, as an account that may use `sudo`:

1. Copy the newest `.fxsnap` snapshot onto the server as
   `/home/fermix/restore.fxsnap`, owned by `fermix` (`sudo install -o fermix
   -g fermix -m 0600 FILE /home/fermix/restore.fxsnap`). With a bucket named,
   the step names it: download the snapshot whose name sorts last from it
   first.
2. `sudo -H -u fermix env FERMIX_HOME=/home/fermix/.fermix-restore fermix home
   import /home/fermix/restore.fxsnap --into /home/fermix/.fermix`, which asks
   for the recovery passphrase without echo. The import runs from a scratch
   home of its own so that nothing it writes as it starts lands in the empty
   home it restores into.
3. `sudo -H -u fermix env XDG_RUNTIME_DIR=/run/user/<uid> fermix service
   install --home /home/fermix/.fermix`.
4. `sudo rm -rf /home/fermix/restore.fxsnap /home/fermix/.fermix-restore`.

Run again once the import made the home, a primary, the first boot binds and
starts it and prints no steps.

## Testing

```bash
sh packaging/cloud/test/first_boot_test.sh        # shellcheck, host, containers
sh packaging/cloud/test/first_boot_test.sh host   # shellcheck and the host part
```

The host part (`test/on_host.sh`) needs shellcheck, dash, `script(1)` and
`perl`, on macOS or Linux, as any account. It runs first-boot.sh's own main,
less its nightly update's writer, with six fixed paths moved under a
directory of its own (each line asserted present exactly once) and the steps
that need a Debian server as root stood in for by functions that log their
names, and the engine account's `fermix` calls by one that logs them and
answers `home status --json` from a fixture in the engine's own one-line
envelope. `tailscale`, `apt-get`, `curl`, `gpg`, `id` and `systemctl` are
stand-ins, and every other command runs through a shim that logs its
arguments and its environment, so every command line the run starts is seen.
Its cases: no `--tailscale` (nothing of Tailscale runs), the key from
`TS_AUTHKEY`, the code and the key typed at a terminal, a key without the
flag, malformed keys, an OAuth client secret and no key without a terminal
(each refused before any step), a host already on a tailnet (named, refused
with a key, refused when its status names none), a host with Tailscale down,
a served key that is not Tailscale's alone, `tailscaled` that does not start,
`tailscale up` failing before enrolling, each release's repository, and
`--restore`; after each, the key is in no file, output, command line or
environment, and its file is gone. Then a host whose home exists: a
candidate `enrolling`, `failed` or `expired` enrolling again (the code in
the environment, typed at a terminal, or missing), a Fermix that does not
stop; a home that runs, with no code and with one; a retired copy, a
desktop, a candidate whose move cannot be read, a candidate under
`--restore` and a home the engine refuses to read, each refused. A failure
is counted in a file, so a check that ends a pipeline counts too.

The containers need Docker with `debian:trixie-slim`, and network inside them
(they install `nftables` and `shellcheck`, Chromium in its scenario, and
`ca-certificates`, `curl` and `gpg` in the tailnet scenario). `useradd`, `runuser`, `nft` and
`apt-config` run for real (`--cap-add NET_ADMIN`, `/run` on a tmpfs);
`systemctl` (which runs a unit's `ExecStart` for `start` and `restart`),
`loginctl`, `curl` (the fake installer, which records the release it
installed; `pkgs.tailscale.com` fetched for real), `apt-get`, `dpkg-query`,
`perl` (the Landlock ABI from a fixture), `swapon`, `fallocate`, `mkswap`,
`tailscale` (which records the key file it read, never the key) and `fermix`
(which runs the release its last start installed, and whose status reads can
fail) are the stand-ins in `test/stubs/`. The chromium scenario
keeps the real `perl`, so it asks the kernel Docker runs on for its Landlock
ABI and needs Linux 6.2 or later with Landlock enabled. The scenarios: an
existing host typing the code at a terminal, run again with no code, then
given a code (refused), then enrolling again once its enrollment failed,
then enrolling afresh with the code in the environment and a bucket, after
the refusals (a stock Debian 12 host and kernels with Landlock ABI 2 or none,
by the ABI sentence, among them); a restore host and its printed steps, run
again once its home is a primary, and refused as a retired copy; the
failures that stop the
first boot, each by its exit status and its one sentence on stderr; an
Ubuntu host with swap of its own; the nightly update, one night per case (the
computers' release already installed, a newer one, a failed installer while
a reboot is asked for, the reboot, an installer that cannot be downloaded
(the reboot all the same), a failed `service status` and a failed `home
status` (no restart, the reboot all the same), three nights under a move
(the reboot waits two, then goes), a move in an ended phase, a failed
restart (the reboot all the same), an older release never installed back
down, no computer seen, no home yet); a host joining a tailnet with
Tailscale's live signing key checked by its fingerprint and the source read
by the real `apt-get`, a re-run on the tailnet, and a `tailscale up` that
fails before enrolling; and the distribution's Chromium installed with
the real `apt-get` and started headless as `fermix` through the engine's
`oom_score_adj` shell, with its own sandbox (that container runs without
Docker's seccomp profile, which refuses the user namespaces a server's kernel
gives an unprivileged account). It is not wired into CI;
`scripts/release/test_fermix_update.py` runs the nightly update's release
choice and first boot's `--version` hermetically, in CI. What only a real
server proves: the user manager starting behind the drop-in, the swap file
turning on, the timer firing at 04:00 UTC and the reboot.
