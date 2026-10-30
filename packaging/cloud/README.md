# Always On servers (`packaging/cloud`)

A server that becomes the owner's Fermix primary (M75 step 6, D21). Two ways
in, one script, two modes:

- **AWS:** `aws/fermix-always-on.yaml`, a CloudFormation quick-create template
  the owner launches in their own account. Its user data unpacks and runs
  `first-boot.sh` with the enrollment code in `FERMIX_ENROLL_CODE` and the
  stack's wait handle in `FERMIX_SIGNAL_URL`.
- **Any Debian 12, Debian 13 or Ubuntu 24.04 host** (arm64, x86_64):
  `curl -fsSL https://fermix.ai/always-on | sudo sh`, which serves
  `first-boot.sh` byte for byte and asks for the code without echo. Cloud-init
  user data can run it with the code in `FERMIX_ENROLL_CODE` instead.
- **Enroll** (the default) makes the server a candidate the primary moves
  to. **Restore** (`--restore`, the template's `Mode` = `restore`) takes no
  code and enrolls nothing: it prepares the same hardened server and prints the
  exact steps that restore the newest snapshot of a primary that is gone. In
  this version a restore runs on an existing host with a terminal; the
  template refuses it (see `Mode` below).

| File | What it is |
|---|---|
| `first-boot.sh` | The root first boot. POSIX `sh`, run once, safe to run again. |
| `aws/fermix-always-on.yaml` | The template. Carries `first-boot.sh` compressed in its user data. |
| `aws/embed-first-boot.sh` | Writes `first-boot.sh` into the template. Run it after every change to the script. |
| `test/first_boot_test.sh` | shellcheck, then the script in throwaway `debian:trixie-slim` containers, one per scenario. |

## What the first boot does

In this order, failing with one sentence and a non-zero exit at any step:

1. Enroll mode only: writes the code to `/run/fermix/enroll.code` (tmpfs; the
   directory 0700 and the file 0600, root's until the engine account exists,
   then its). Restore mode refuses a code.
2. Loads the nftables table `inet fermix_metadata` (`/etc/fermix/metadata-block.nft`),
   which drops traffic to `169.254.169.254` and `fd00:ec2::254` from every uid
   but 0, through `fermix-metadata-block.service`: before `network-pre.target`
   at every boot, again after `nftables.service` starts or reloads (which
   flushes the ruleset). The rule sits on the `output` hook, so it covers what
   the host's own processes send. A container's packets take the `forward`
   path and would pass it, which is one reason the server runs no containers:
   Fermix's Linux sandbox is Landlock, which confines commands in place. On AWS
   the template's hop limit of 1 keeps IMDSv2 from answering a container
   anyway; on another cloud a container runtime would need its own rule.
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
5. On an AWS instance with a role: `fermix-aws-credentials.service` and
   `.timer` (at boot and every 15 minutes), running
   `/usr/local/lib/fermix-always-on/aws-credentials` as root. It fetches the
   role's credentials over IMDSv2 and moves them into
   `/run/fermix/aws-credentials.json` (0600, `fermix`) by rename, never writing
   through a path the engine account could have placed. The file is the
   metadata service's answer unchanged (`AccessKeyId`, `SecretAccessKey`,
   `Token`, `Expiration`), which `Home.Snapshot.S3.Credentials` reads.
6. On AWS: `/run/fermix/instance.json`, `{"provider": "aws", "instance_id",
   "region", "account_id"}`.
7. With `--shell-access` (the template's `ShellAccess`): turns on the SSM agent
   so Session Manager can open a shell, or fails when the server has none (see
   *ShellAccess* below).
8. Enroll mode, as `fermix`, with a clean environment: `fermix home enroll
   --code-file /run/fermix/enroll.code [--snapshot-bucket B --snapshot-region
   R] [--instance-file /run/fermix/instance.json]`, then, with
   `XDG_RUNTIME_DIR=/run/user/<uid>` (systemctl reaches the user manager's
   private socket; no user D-Bus needed), `fermix service install --home
   /home/fermix/.fermix`. Enrolling is skipped, and said, when
   `/home/fermix/.fermix` exists; the service is bound and started again.
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
11. With a wait handle: signals the stack once, `SUCCESS` at the end, or
    `FAILURE` with the sentence that ended the first boot (also one that
    stopped it unexpectedly, or a refused option), which fails the stack with
    that sentence as its reason.

The code reaches the engine only as that file: never in an argument, never in
an environment the engine inherits (`env -i`), never in the output. Neither
does the wait handle's address. An option the script does not know is refused
without being echoed, in case it is a code pasted in the wrong place.

### The restore steps it prints

In a shell on the server (Session Manager with `ShellAccess`, or the host's
own terminal), as an account that may use `sudo`:

1. On a computer with the owner's AWS credentials, `aws s3 ls s3://BUCKET/
   --recursive | sort | tail -n 1` finds the newest snapshot, and `aws s3
   presign s3://BUCKET/KEY --region R --expires-in 900` a link to it; on the
   server, `sudo -H -u fermix curl -fsS -o /home/fermix/restore.fxsnap
   'LINK'`. With no bucket named, copy the `.fxsnap` file over instead.
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

## The template

`aws/fermix-always-on.yaml` makes a VPC with one public subnet, an internet
gateway and a security group with no inbound rule; a launch template with IMDSv2 required, hop limit
1, and an encrypted gp3 root volume (`/dev/xvda`, Debian's root device); the
latest Debian 13 image from the public SSM parameters
`/aws/service/debian/release/13/latest/{arm64,amd64}`, chosen by the
architecture of `InstanceType`; and an instance role whose only permission is
`s3:PutObject` on the snapshot bucket's objects.

- **`Mode`**: `enroll` (default) or `restore`. Rules keep the parameters
  straight: `enroll` needs `EnrollmentCode` and makes a new bucket;
  `restore` takes no code and needs `ExistingSnapshotBucket`, the bucket the
  lost server wrote to (its stack's `SnapshotBucket` output, kept when that
  stack was deleted). A restore stack makes no bucket: its role writes to that
  one, which the restored home already names, so snapshots go on where they
  were. Launch it in that bucket's region. **Restoring on AWS is not available
  in this version:** the steps need a shell on the server, and the Debian
  image cannot give one yet (no SSM agent, see `ShellAccess`), so the rule
  `RestoreNeedsShellAccess` refuses `restore` with `ShellAccess` off, saying
  so, rather than create a server nobody can reach; with it on, first boot
  fails the stack. Restore onto an existing Linux host instead, from its own
  terminal: `curl -fsSL https://fermix.ai/always-on | sudo sh -s -- --restore`
  (add `--snapshot-bucket` and `--snapshot-region` to have the steps name the
  bucket), then the steps it prints.
- **The bucket** (enroll mode): versioned, all public access blocked, SSE-S3,
  a TLS-only policy, kept when the stack is deleted. Lifecycle: every snapshot
  object expires 30 days after it was written (S3 then keeps it as a
  noncurrent version), noncurrent versions expire 90 days later, and
  incomplete multipart uploads after 1 day. So the bucket holds about 120 days
  of snapshots: the last 30 days' as objects `aws s3 ls` lists, the 90 before
  as previous versions (`aws s3api list-object-versions`, then `get-object
  --version-id`). The cost is that many snapshots at the home's encrypted
  size: at the default interval of 6 hours, 4 a day, about 480 in all, so a
  home whose snapshot is 200 MB keeps about 96 GB, roughly USD 2.20 a month at
  S3 Standard's us-east-1 list price of USD 0.023 per GB-month (check your
  region). Retention is the trade: a server that stops writing leaves its last
  snapshot listed for 30 days and recoverable as a previous version for 90
  more, after which it is gone, so restore within four months of losing a
  server. Change the two numbers in the template for another balance.
- **`ShellAccess`** (`false` by default): `true` attaches the AWS managed
  policy `AmazonSSMManagedInstanceCore` to the role, so Session Manager can
  open a shell on the server with no inbound port: the way to restore a
  snapshot onto a restore host, or to repair a server. It needs the SSM agent
  on the server, and Debian's images carry none, so today first boot fails
  the stack with that sentence when `ShellAccess` is on; installing the agent
  is AWS's own package and waits on the owner's decision.
- **The wait condition**: `FirstBootHandle` and `FirstBoot` (30 minutes). The
  stack completes only once first boot signals `SUCCESS`: the primary
  accepted the server, or a restore host is ready for the import. A first boot
  that fails signals `FAILURE` with its sentence, which fails the stack with
  it as the reason; one that never reports fails it when the 30 minutes run
  out. A failed create rolls the stack back (the console's option to keep
  provisioned resources leaves the instance to look at), and the bucket of an
  enroll stack is kept, empty, to delete by hand. The handle's address sits in
  the user data, readable to whoever may read the instance's user data; it can
  only signal this stack while it is being created.
- **Outputs**: the instance id, in enroll mode the sentence telling the owner
  to compare it with what Fermix shows, in restore mode where the steps are,
  the bucket and the region.

**Why the script is embedded compressed.** EC2 takes at most 16 KB of user
data and the script is larger, so it travels gzip-compressed and base64-encoded
with its SHA-256, which the server checks before running it. Embedding keeps
the template whole on its own (uploaded in the console, it needs no second
download and no pinned URL), and what ran is what the instance's user data
shows. The test decodes the embedded copy and compares it with `first-boot.sh`
byte for byte, and checks that the longest code, wait handle and bucket still
fit.

**Validate** with `uvx cfn-lint packaging/cloud/aws/fermix-always-on.yaml`
(also clean with `--include-checks I` after the file name). After editing
`first-boot.sh`: `sh packaging/cloud/aws/embed-first-boot.sh`, then the test.

**Hosting.** Quick-create needs the template at an S3 URL, which is the
owner's to host:
`https://console.aws.amazon.com/cloudformation/home#/stacks/quickcreate?templateURL=<S3 URL>&stackName=fermix-always-on`.
The enrollment code is pasted into the `EnrollmentCode` field (`NoEcho`) and
never goes in a URL: never build a link with `param_EnrollmentCode`. `NoEcho`
masks the parameter in the console and the stack APIs, but the resolved user
data stays readable to anyone in the account with `ec2:Describe*`, and to root
on the instance through the metadata service. That is acceptable only because
the code works once, for 30 minutes, and the primary burns it at the first
handshake.

## Testing

```bash
sh packaging/cloud/test/first_boot_test.sh
```

Needs shellcheck, Docker with `debian:trixie-slim`, and network inside the
containers (they install `nftables`, and Chromium in its scenario). `useradd`,
`runuser` and `nft` run for real (`--cap-add NET_ADMIN`, `/run` on a tmpfs);
`systemctl` (which runs a unit's `ExecStart` for `start` and `restart`),
`loginctl`, `curl` (the fake installer, a fake IMDSv2 service and the stack's
wait handle), `apt-get` and `fermix` are the stand-ins in `test/stubs/`. The
scenarios: an existing host typing the code at a terminal; an AWS instance
from user data with a role, a bucket and the success signal; a restore host and its printed steps,
with the template's rule that refuses a restore stack with no shell;
every failure the stack is told about, each signalled exactly once; an Ubuntu
host; and the distribution's Chromium installed with the real `apt-get` and
started headless as `fermix` with its own sandbox (that container runs without
Docker's seccomp profile, which refuses the user namespaces a server's kernel
gives an unprivileged account). It is not wired into CI. What only a real
launch proves, and is owed before the template is published: the Debian
image's root device name, the SSM parameter paths in every region, the user
manager starting behind the drop-in, the engine reading the credentials file, and the wait handle's
signal reaching CloudFormation.
