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
- **Enroll** (the default) makes the server a candidate the primary moves
  to. **Restore** (`--restore`) takes no code and enrolls nothing: it prepares
  the same hardened server and prints the exact steps that restore the newest
  snapshot of a primary that is gone.

| File | What it is |
|---|---|
| `first-boot.sh` | The root first boot. POSIX `sh`, run once, safe to run again. |
| `test/first_boot_test.sh` | shellcheck, then the script in throwaway `debian:trixie-slim` containers, one per scenario. |

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
Landlock, or booted without it in its `lsm=` list, answers none.

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
   ruleset). The server's user data, which holds the enrollment code, stays
   readable through the metadata service for the server's life. Some clouds
   serve DNS and time from the same address, so those two are accepted before
   the drop and keep working for every account; anything else a cloud serves
   there stays root's. An accept ends only this table's chain, whose policy is
   accept anyway, so it opens nothing another firewall on the host closes. The
   rule sits on the `output` hook, so it covers what the host's own processes
   send. A container's packets take the `forward` path and would pass it,
   which is one reason the server runs no containers: Fermix's Linux sandbox
   is Landlock, which confines commands in place. A container runtime would
   need its own rule.
3. Swap, the memory guard's first half: a host with no swap (Hetzner's images
   have none) gets a 2 GB swap file, `/swapfile` (0600, made with
   `fallocate` and `mkswap`, listed in `/etc/fstab`, turned on), so memory
   pressure slows the server before the kernel stops a process. A host with
   swap of its own keeps it and gets none, and a run again changes nothing.
   The guard's second half is the engine's: on Linux it starts Chromium with
   `oom_score_adj` 1000, inherited by each of Chromium's processes, so out of
   memory the kernel stops a Chromium process before the engine. Both values
   are constants until a measurement on the smallest server Fermix creates
   sets them (M75 §3).
4. Installs the Linux package through `https://fermix.ai/install --no-setup`,
   the installer every host uses, with its checks. The package's user unit
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
   installer again (`--no-setup`, with its sha256 check and the cosign
   signature check through the package's own cosign); then `fermix restart`
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
7. Enroll mode, as `fermix`, with a clean environment: `fermix home enroll
   --code-file /run/fermix/enroll.code [--snapshot-bucket B --snapshot-region
   R]`, then, with `XDG_RUNTIME_DIR=/run/user/<uid>` (systemctl reaches the user manager's
   private socket; no user D-Bus needed), `fermix service install --home
   /home/fermix/.fermix`. Enrolling is skipped, and said, when
   `/home/fermix/.fermix` exists; the service is bound and started again.
8. A browser for the agent's tasks. Debian: the distribution's `chromium`,
   which the engine's launcher finds on its `PATH` and starts headless as
   `fermix`, with Chromium's own sandbox. Ubuntu ships Chromium only as a
   snap, so nothing is installed and one sentence says to install a browser by
   hand (Google Chrome's own package, for example), or browser tasks answer
   that no Chrome or Chromium is installed.
9. Enroll mode: waits, up to 5 minutes, for the primary to accept the server
   (`fermix home status --json` shows the candidate `enrolled`), and fails
   with the candidate's own sentence when the enrollment expired or failed.
   Restore mode: prints the restore steps instead (below).

The code reaches the engine only as that file: never in an argument, never in
an environment the engine inherits (`env -i`), never in the output. An option
the script does not know is refused without being echoed, in case it is a code
pasted in the wrong place.

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

Run again once the home exists, the first boot binds and starts it and prints
no steps.

## Testing

```bash
sh packaging/cloud/test/first_boot_test.sh
```

Needs shellcheck, Docker with `debian:trixie-slim`, and network inside the
containers (they install `nftables` and `shellcheck`, and Chromium in its
scenario). `useradd`, `runuser`, `nft` and `apt-config` run for real
(`--cap-add NET_ADMIN`, `/run` on a tmpfs); `systemctl` (which runs a unit's
`ExecStart` for `start` and `restart`), `loginctl`, `curl` (the fake
installer, which records the release it installed), `apt-get`, `dpkg-query`,
`perl` (the Landlock ABI from a fixture), `swapon`, `fallocate`, `mkswap` and
`fermix` (which runs the release its last start installed, and whose status
reads can fail) are the stand-ins in `test/stubs/`. The chromium scenario
keeps the real `perl`, so it asks the kernel Docker runs on for its Landlock
ABI and needs Linux 6.2 or later with Landlock enabled. The scenarios: an
existing host typing the code at a terminal, then enrolling again with the
code in the environment and a bucket, after the refusals (a stock Debian 12
host and kernels with Landlock ABI 2 or none, by the ABI sentence, among
them); a restore host and its printed steps; the failures that stop the
first boot, each by its exit status and its one sentence on stderr; an
Ubuntu host with swap of its own; the nightly update, one night per case (no
new release, a new one, a failed installer while a reboot is asked for, the
reboot, an installer that cannot be downloaded (the reboot all the same), a
failed `service status` and a failed `home status` (no restart, the
reboot all the same), three nights under a move (the reboot waits two, then
goes), a move in an ended phase, a failed restart (the reboot all the same),
no home yet); and the distribution's Chromium installed with
the real `apt-get` and started headless as `fermix` through the engine's
`oom_score_adj` shell, with its own sandbox (that container runs without
Docker's seccomp profile, which refuses the user namespaces a server's kernel
gives an unprivileged account). It is not wired into CI. What only a real
server proves: the user manager starting behind the drop-in, the swap file
turning on, the timer firing at 04:00 UTC and the reboot.
