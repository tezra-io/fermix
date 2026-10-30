# Always On servers (`packaging/cloud`)

A server that becomes the owner's Fermix primary (M75 step 6, D21). One
script, two modes:

- **Any Debian 12, Debian 13 or Ubuntu 24.04 host** (arm64, x86_64):
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

In this order, failing with one sentence and a non-zero exit at any step:

1. Enroll mode only: writes the code to `/run/fermix/enroll.code` (tmpfs; the
   directory 0700 and the file 0600, root's until the engine account exists,
   then its). Restore mode refuses a code.
2. Loads the nftables table `inet fermix_metadata` (`/etc/fermix/metadata-block.nft`),
   which drops traffic to `169.254.169.254` from every uid but 0, through
   `fermix-metadata-block.service`: before `network-pre.target` at every boot,
   again after `nftables.service` starts or reloads (which flushes the
   ruleset). The rule sits on the `output` hook, so it covers what the host's
   own processes send. A container's packets take the `forward` path and would
   pass it, which is one reason the server runs no containers: Fermix's Linux
   sandbox is Landlock, which confines commands in place. A container runtime
   would need its own rule.
3. Installs the Linux package through `https://fermix.ai/install --no-setup`,
   the installer every host uses, with its checks. The package's user unit
   runs the engine with `Restart=always` and at most five starts in ten
   minutes, so a crash loop stops and the budget comes back.
4. Creates the account `fermix` (home `/home/fermix`, `/usr/sbin/nologin`, no
   password), lingering, with `/run/fermix` recreated for it at every boot
   (tmpfiles.d) and a `user@<uid>.service` drop-in whose `ExecStartPre` refuses
   to start the account's service manager, and so the engine, while the
   metadata table is missing. Not `/var/lib/fermix`: it holds the root-owned
   loader every packaged engine executes, and no engine account may own a
   directory above it. A normal uid also keeps `journalctl --user` working.
5. Enroll mode, as `fermix`, with a clean environment: `fermix home enroll
   --code-file /run/fermix/enroll.code [--snapshot-bucket B --snapshot-region
   R]`, then, with `XDG_RUNTIME_DIR=/run/user/<uid>` (systemctl reaches the user manager's
   private socket; no user D-Bus needed), `fermix service install --home
   /home/fermix/.fermix`. Enrolling is skipped, and said, when
   `/home/fermix/.fermix` exists; the service is bound and started again.
6. A browser for the agent's tasks. Debian: the distribution's `chromium`,
   which the engine's launcher finds on its `PATH` and starts headless as
   `fermix`, with Chromium's own sandbox. Ubuntu ships Chromium only as a
   snap, so nothing is installed and one sentence says to install a browser by
   hand (Google Chrome's own package, for example), or browser tasks answer
   that no Chrome or Chromium is installed.
7. Enroll mode: waits, up to 5 minutes, for the primary to accept the server
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
containers (they install `nftables`, and Chromium in its scenario). `useradd`,
`runuser` and `nft` run for real (`--cap-add NET_ADMIN`, `/run` on a tmpfs);
`systemctl` (which runs a unit's `ExecStart` for `start` and `restart`),
`loginctl`, `curl` (the fake installer), `apt-get` and `fermix` are the
stand-ins in `test/stubs/`. The scenarios: an existing host typing the code
at a terminal, then enrolling again with the code in the environment and a
bucket; a restore host and its printed
steps; the failures that stop the first boot, each by its exit status and its
one sentence on stderr; an Ubuntu host; and the distribution's Chromium
installed with the real `apt-get` and started headless as `fermix` with its own
sandbox (that container runs without Docker's seccomp profile, which refuses
the user namespaces a server's kernel gives an unprivileged account). It is not
wired into CI. What only a real server proves: the user manager starting
behind the drop-in.
