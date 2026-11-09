#!/bin/sh
# Runs inside a throwaway debian:trixie-slim container started by
# first_boot_test.sh, with packaging/cloud mounted read-only at /cloud, the
# package's systemd units at /linux-systemd, the regular installer
# (scripts/install.sh) at /install.sh, /run on a tmpfs and NET_ADMIN, so
# nft loads the real ruleset. useradd, runuser, nft and apt-config are real;
# systemctl, loginctl, curl, apt-get, dpkg-query, perl, swapon, fallocate,
# mkswap, tailscale and fermix are the stand-ins in stubs/ (in the chromium
# scenario apt-get, dpkg-query and perl are the real ones, so first boot asks
# the kernel Docker runs on for its Landlock ABI). One scenario per container:
#
#   existing-host  refusals (a kernel below Landlock ABI 3 among them), then
#                  the code typed at a terminal, the wait for
#                  the primary, then a re-run once it is the primary, the
#                  same home given a code (refused) and a candidate whose
#                  enrollment failed enrolling again; then the code in the
#                  environment with a bucket and the release to install; then
#                  the same through the regular installer's --always-on, which
#                  checks the release's server script (this first-boot.sh)
#                  against a stand-in fermix.ai table first: a table that
#                  disagrees and a code passed as an argument refused, then
#                  the whole first boot with the table's latest release
#   restore        --restore: no code, no enrollment, the steps printed, a
#                  re-run once a home exists, a retired copy refused
#   failures       each failure that stops the first boot: its exit status
#                  and its one sentence on stderr
#   ubuntu         no Chromium package, and the sentence that says to install
#                  one; swap of its own, which it keeps
#   updates        the nightly update, which installs the release its
#                  computers run: that release already installed, a newer
#                  one, a failed installer, a reboot asked for, an installer
#                  that cannot be downloaded, a failed status read, three
#                  nights under a move, an ended move, a failed restart, an
#                  older one never installed back down, none seen, no home;
#                  then the follow run: no home, a newer release and the
#                  restart but never a reboot, a move holding the restart
#                  until it ends, nothing due; and the lock, with the real
#                  flock: a follow run leaving the update to the run that
#                  holds it, and the night waiting for that run
#   tailnet        --tailscale: a key without the flag, a malformed one and
#                  none refused before anything is installed; Tailscale's
#                  live keyring (real curl and gpg) checked by its pinned
#                  fingerprint and read by the real apt-get, tailscale up
#                  with the key file before enrolling; a re-run on the
#                  tailnet that logs in again nowhere; a tailscale up that
#                  fails, before enrolling
#   chromium       the distribution's Chromium installed for real and started
#                  headless as the engine account, the way the engine's
#                  launcher starts it, its own sandbox on
#   s3-backups     E1: a server whose infrastructure set its bucket
#                  (/etc/fermix/snapshot-destination): enrolled with it and
#                  --snapshot-instance-role, the root credentials helper and
#                  its timer, the session the engine account reads and cannot
#                  change, no secret in any command line; each failure of
#                  the helper in its own words, kept for the engine; a first
#                  boot whose helper fails stopped before enrolling; flags
#                  naming another bucket and a destination not root's alone
#                  or not in its shape refused; a restore host
set -eu

SCENARIO=${1:?scenario: existing-host, restore, failures, ubuntu, updates, tailnet, chromium or s3-backups}
FIRST_BOOT=/cloud/first-boot.sh
INSTALLER=/install.sh
# Where the installer's mktemp makes its directory, so a run can be seen to
# leave nothing behind.
INSTALLER_TMP=/tmp/installer-tmp
LOG=/var/log/fermix-test
FIXTURES=/etc/fermix-test
OUT=/tmp/first-boot.out
ERR=/tmp/first-boot.err
FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

pass() {
  printf 'ok: %s\n' "$1"
}

check() {
  if eval "$1"; then pass "$2"; else fail "$2"; fi
}

contains() {
  grep -qF -- "$2" "$1"
}

mode_owner() {
  stat -c '%a %U:%G' "$1"
}

# An invented enrollment code in the real shape: the prefix and a base64url
# JSON body. Nothing in it is a secret.
make_code() {
  printf '{"v":1,"secret":"%s","gateway_pk":"bG9jYWwtdGVzdC1nYXRld2F5LWtleS0wMDAwMDAwMDAwMDA","node_id":"ae58ff8833241ac82d6ff7611046ed67b5072d142c588d0063e942d9a75502b6","relays":["https://relay.example.net/"],"relays_rev":"0123456789abcdef","name":"Invented Mac","expires_at":"2026-10-27T15:10:00Z"}' "$1" |
    base64 -w0 | tr '+/' '-_' | tr -d '=' | sed 's/^/fxenroll1./'
}

reset_log() {
  mkdir -p "$LOG"
  chmod 1777 "$LOG"
  : >"$LOG/calls.log"
  chmod 0666 "$LOG/calls.log"
}

code_absent_everywhere() {
  if grep -rqF -- "$CODE_BODY" "$OUT" "$LOG"; then
    fail "the enrollment code appears in the output or a recorded call"
  else
    pass "the enrollment code appears in no output and no recorded call"
  fi
}

install_stubs() {
  for stub in systemctl loginctl curl swapon fallocate mkswap; do
    install -m 0755 "/cloud/test/stubs/$stub" "/usr/local/bin/$stub"
  done
  reset_log
}

# The real apt-get installs what the checks run for real (and any packages
# named), then the stand-ins take over apt-get and dpkg-query.
setup_tools() {
  apt-get -qq update >/dev/null
  apt-get -qq -y install --no-install-recommends nftables shellcheck "$@" >/dev/null 2>&1
  install_stubs
  install -m 0755 /cloud/test/stubs/apt-get /usr/local/sbin/apt-get
  for stub in dpkg-query perl; do install -m 0755 "/cloud/test/stubs/$stub" "/usr/local/bin/$stub"; done
}

# Runs first-boot.sh with no terminal; $OUT gets stdout and stderr, $STATUS
# its exit status.
run_first_boot() {
  reset_log
  set +e
  "$@" </dev/null >"$OUT" 2>&1
  STATUS=$?
  set -e
}

refuses() {
  description=$1
  sentence=$2
  shift 2
  run_first_boot "$@"
  if [ "$STATUS" -ne 0 ] && contains "$OUT" "$sentence" && [ ! -e /run/fermix/enroll.code ] &&
    [ ! -s "$LOG/calls.log" ] && ! grep -qF -- "$CODE_BODY" "$OUT" && ! grep -qF -- "$TS_KEY" "$OUT" &&
    [ -z "$(find /run -maxdepth 1 -name 'fermix-always-on.*')" ]; then
    pass "refuses $description"
  else
    fail "refuses $description (exit $STATUS)"
    sed 's/^/    /' "$OUT"
  fi
}

# Runs first-boot.sh with no terminal, its stdout in $OUT and its stderr in
# $ERR apart, and $STATUS its exit status.
run_apart() {
  reset_log
  set +e
  "$@" </dev/null >"$OUT" 2>"$ERR"
  STATUS=$?
  set -e
}

# The run failed, and stderr holds exactly its one sentence.
stopped_with() {
  printf 'fermix always-on: %s\n' "$1" >/tmp/stderr.expected
  if [ "$STATUS" -ne 0 ] && cmp -s "$ERR" /tmp/stderr.expected; then
    pass "$2"
  else
    fail "$2 (exit $STATUS)"
    sed 's/^/    stderr: /' "$ERR"
  fi
}

# Runs first boot on a host whose /etc/os-release names ID $1, VERSION_ID $2
# and PRETTY_NAME $3, putting the container's own back after.
as_release() {
  sh -c "cp /etc/os-release /tmp/os-release && printf 'ID=$1\nVERSION_ID=\"$2\"\nPRETTY_NAME=\"$3\"\n' >/etc/os-release && { FERMIX_ENROLL_CODE='$CODE' sh $FIRST_BOOT; status=\$?; cp /tmp/os-release /etc/os-release; exit \$status; }"
}

check_refusals() {
  refuses "a host that is not Debian 12, Debian 13 or Ubuntu 24.04" \
    "This host runs Invented Linux 7. Fermix Always On supports Debian 12, Debian 13 and Ubuntu 24.04." \
    as_release invented 7 "Invented Linux 7"
  printf '2\n' >"$FIXTURES/landlock-abi"
  refuses "a Debian 12 host on its own 6.1 kernel, by its Landlock ABI" \
    "This host's kernel gives Landlock ABI 2 (0 is none) and Fermix's sandbox needs ABI 3, so Fermix would run no command here: Fermix Always On needs Linux 6.2 or later with Landlock enabled, as Debian 13 and Ubuntu 24.04 have by default." \
    as_release debian 12 "Debian GNU/Linux 12 (bookworm)"
  for abi in 2 0; do
    printf '%s\n' "$abi" >"$FIXTURES/landlock-abi"
    refuses "a kernel that gives Landlock ABI $abi, before anything is installed" \
      "This host's kernel gives Landlock ABI $abi (0 is none) and Fermix's sandbox needs ABI 3, so Fermix would run no command here: Fermix Always On needs Linux 6.2 or later with Landlock enabled, as Debian 13 and Ubuntu 24.04 have by default." \
      env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  done
  rm -f "$FIXTURES/landlock-abi"
  printf '#!/bin/sh\necho riscv64\n' >/usr/local/bin/uname
  chmod 0755 /usr/local/bin/uname
  refuses "an architecture other than arm64 and x86_64" \
    "This host is riscv64. Fermix Always On supports arm64 and x86_64." \
    env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  rm -f /usr/local/bin/uname
  refuses "an account other than root" "Run this as root" \
    runuser -u nobody -- env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  refuses "an account other than root, naming the command with the release it was given" \
    "Run this as root: curl -fsSL https://fermix.ai/install | sudo sh -s -- --always-on --version 1.2.3" \
    runuser -u nobody -- env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --version 1.2.3
  refuses "a run with no code and no terminal" \
    "No enrollment code: run this in a terminal, which asks for it, or pass it in FERMIX_ENROLL_CODE." \
    sh "$FIRST_BOOT"
  refuses "a code without the fxenroll1. prefix" "That is not a Fermix enrollment code" \
    env FERMIX_ENROLL_CODE="fxenroll2.${CODE_BODY}" sh "$FIRST_BOOT"
  refuses "a code with a character no code has" "The enrollment code holds a character no code has." \
    env FERMIX_ENROLL_CODE="${CODE}+" sh "$FIRST_BOOT"
  refuses "a code that is too short" "The enrollment code is not between 42 and 2048 characters long." \
    env FERMIX_ENROLL_CODE="fxenroll1.abc" sh "$FIRST_BOOT"
  refuses "a code that is too long" "The enrollment code is not between 42 and 2048 characters long." \
    env FERMIX_ENROLL_CODE="${CODE}$(printf '%2048s' '' | tr ' ' A)" sh "$FIRST_BOOT"
  refuses "an unknown option, without echoing it (here the code itself)" "An option was not recognised. This script takes --restore, --snapshot-bucket, --snapshot-region, --version and --tailscale." \
    env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" "$CODE"
  refuses "a release that is not one" "--version is not a Fermix release, such as 0.17.0." \
    env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --version 1.2
  refuses "a bucket without a region" "--snapshot-region is not a region name, or is missing beside --snapshot-bucket." \
    env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --snapshot-bucket fermix-snapshots-invented
  refuses "a restore given an enrollment code, without echoing it" \
    "--restore takes no enrollment code: the home comes from a snapshot." \
    env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --restore
}

# The code typed at a terminal: script(1) gives first-boot.sh a pty, and the
# code is written only once the prompt is on screen, so a code that came back
# would mean echo was on.
run_with_terminal() {
  reset_log
  rm -f /tmp/tty-in
  mkfifo /tmp/tty-in
  script -qefc "sh $FIRST_BOOT" /dev/null </tmp/tty-in >"$OUT" 2>&1 &
  pid=$!
  exec 3>/tmp/tty-in
  attempts=0
  until contains "$OUT" 'Enrollment code from Fermix (it is not shown as you type): '; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 600 ]; then
      fail "the prompt for the code appears within 60 s"
      break
    fi
    sleep 0.1
  done
  printf '%s\n' "$CODE" >&3
  set +e
  wait "$pid"
  STATUS=$?
  set -e
  exec 3>&-
  tr -d '\r' <"$OUT" >"$OUT.clean"
  mv "$OUT.clean" "$OUT"
}

# Whether a file holds a line apt-get, dpkg or systemctl says as they work,
# which a first boot keeps out of its output.
has_noise() {
  grep -q '^Selecting previously unselected package \|^Preparing to unpack \|^Unpacking \|^Setting up \|^Processing triggers \|^Created symlink ' "$@"
}

expected_ruleset() {
  cat <<'EOF'
table inet fermix_metadata {
	chain output {
		type filter hook output priority filter; policy accept;
		udp dport 53 accept
		tcp dport 53 accept
		udp dport 123 accept
		ip daddr 169.254.169.254 meta skuid != 0 drop
		ip daddr 100.100.100.200 meta skuid != 0 drop
		ip6 daddr fd00:ec2::254 meta skuid != 0 drop
		ip6 daddr fd20:ce::254 meta skuid != 0 drop
	}
}
EOF
}

check_metadata_block() {
  nft list table inet fermix_metadata >/tmp/ruleset 2>&1 || true
  expected_ruleset >/tmp/ruleset.expected
  check "cmp -s /tmp/ruleset /tmp/ruleset.expected" \
    "nft holds exactly the metadata block: the four addresses, but DNS and time, dropped for every uid but 0"
  cmp -s /tmp/ruleset /tmp/ruleset.expected || diff /tmp/ruleset.expected /tmp/ruleset | sed 's/^/    /' || true
  check "[ \"\$(nft list tables | grep -c fermix_metadata)\" -eq 1 ]" "the block is one table, however often it loads"
  unit=/etc/systemd/system/fermix-metadata-block.service
  check "[ \"\$(mode_owner $unit)\" = '644 root:root' ]" "the block's unit is root's"
  check "[ \"\$(mode_owner /etc/fermix)\" = '755 root:root' ] && [ \"\$(mode_owner /etc/fermix/metadata-block.nft)\" = '644 root:root' ]" \
    "the block's ruleset is root's and readable"
  for line in 'ExecStart=/usr/sbin/nft -f /etc/fermix/metadata-block.nft' 'Before=network-pre.target shutdown.target' \
    'WantedBy=sysinit.target' 'PartOf=nftables.service' 'DefaultDependencies=no'; do
    check "contains $unit '$line'" "the block's unit has $line"
  done
  dropin=/etc/systemd/system/user@$ENGINE_UID.service.d/fermix-metadata-block.conf
  check "contains $dropin 'ExecStartPre=+/usr/sbin/nft list table inet fermix_metadata'" \
    "the engine account's user manager checks the block before it starts"
  pre=$(sed -n 's/^ExecStartPre=+//p' "$dropin")
  check "$pre >/dev/null 2>&1" "that check passes while the block is loaded"
  nft delete table inet fermix_metadata
  check "! $pre >/dev/null 2>&1" "that check fails, so the user manager does not start, when the block is missing"
  sh -c "$(sed -n 's/^ExecStart=//p' "$unit")"
  check "nft list table inet fermix_metadata >/dev/null 2>&1" "the unit's command loads the block again"
}

check_account() {
  check "[ \"\$(getent passwd fermix | cut -d: -f5-)\" = 'Fermix engine:/home/fermix:/usr/sbin/nologin' ]" \
    "the engine account fermix has its home at /home/fermix and no login shell"
  check "[ \"\$(passwd -S fermix | cut -d' ' -f2)\" = L ]" "the engine account has no password"
  check "[ \"\$(mode_owner /home/fermix)\" = '700 fermix:fermix' ]" "its home is its own alone"
  check "[ \"\$(getent passwd | grep -c '^fermix:')\" -eq 1 ]" "there is one fermix account"
  check "[ \"\$(cat /etc/tmpfiles.d/fermix-always-on.conf)\" = 'd /run/fermix 0700 fermix fermix -' ]" \
    "/run/fermix is recreated for fermix at every boot"
  check "[ \"\$(mode_owner /run/fermix)\" = '700 fermix:fermix' ]" "/run/fermix is the engine account's alone"
  check "contains $LOG/calls.log 'loginctl enable-linger fermix'" "the engine account lingers"
}

check_code_file() {
  check "[ \"\$(mode_owner /run/fermix/enroll.code)\" = '600 fermix:fermix' ]" "the code file is 0600 and the engine account's"
  check "[ \"\$(cat /run/fermix/enroll.code)\" = \"\$CODE\" ]" "the code file holds the code"
  check "[ \"\$(cat $LOG/code-file.sha256)\" = \"\$(printf '%s\n' \"\$CODE\" | sha256sum | cut -d' ' -f1)\" ]" \
    "fermix home enroll, as fermix, read that code from the file"
  check "! grep -qx FERMIX_ENROLL_CODE $LOG/env-home-enroll" \
    "fermix home enroll does not have FERMIX_ENROLL_CODE in its environment"
  for name in HOME USER PATH LANG FERMIX_HOME XDG_RUNTIME_DIR; do
    check "grep -qx $name $LOG/env-home-enroll" "fermix home enroll has $name"
  done
  check "[ \"\$(cat $LOG/service-runtime-dir)\" = /run/user/$ENGINE_UID ]" \
    "fermix service install reaches the engine account's own service manager"
  engine_call_is_clean home-enroll "fermix home enroll"
}

# A fermix call, $1 its verb as the stand-in names its records, ran as the
# engine account with no PAM session (runuser, which opens one and logs it,
# did not start it), with the account's uid, gid and groups, and with the
# clean environment and nothing else (the stand-in's shell adds PWD).
engine_call_is_clean() {
  check "[ \"\$(cat $LOG/parent-$1)\" != runuser ]" "$2 runs with no PAM session: runuser does not start it"
  check "[ \"\$(cat $LOG/ids-$1)\" = \"\$(id -u fermix) \$(id -g fermix) \$(id -G fermix)\" ]" \
    "$2 runs with the engine account's uid, gid and groups"
  grep -vx PWD "$LOG/env-$1" >/tmp/env.seen || true
  printf '%s\n' FERMIX_HOME HOME LANG LOGNAME PATH SHELL USER XDG_RUNTIME_DIR >/tmp/env.expected
  check "cmp -s /tmp/env.seen /tmp/env.expected" "$2 has the clean environment and nothing else"
  cmp -s /tmp/env.seen /tmp/env.expected || diff /tmp/env.expected /tmp/env.seen | sed 's/^/    /' || true
}

# The unit the package installs is what runs the engine on the server: five
# starts in ten minutes, so a crash loop stops and the budget comes back.
check_package_unit() {
  unit=/usr/lib/systemd/user/fermix.service
  for line in 'StartLimitIntervalSec=600' 'StartLimitBurst=5' 'Restart=always' 'RestartSec=5'; do
    check "grep -qx '$line' $unit" "the package's unit the server runs has $line"
  done
}

# The swap file is root's alone, in /etc/fstab once (so it is on at every
# boot), and nothing half made is left beside it.
check_swap() {
  check "[ \"\$(mode_owner /swapfile)\" = '600 root:root' ]" "the swap file /swapfile is root's alone"
  check "[ \"\$(grep -c '^/swapfile ' /etc/fstab)\" -eq 1 ] && grep -qx '/swapfile none swap sw 0 0' /etc/fstab" \
    "/etc/fstab lists the swap file once, so it is on at every boot"
  check "[ ! -e /swapfile.incoming ]" "no half-made swap file is left"
}

periodic_on() {
  [ "$(apt-config shell VALUE "APT::Periodic::$1")" = "VALUE='1'" ]
}

# Debian's daily updates on, the nightly update's timer and unit, the follow
# run's, and the script both run.
check_updates() {
  conf=/etc/apt/apt.conf.d/21fermix-always-on
  check "[ \"\$(mode_owner $conf)\" = '644 root:root' ]" "Debian's daily updates are set in a file of root's"
  check "periodic_on Update-Package-Lists && periodic_on Unattended-Upgrade" \
    "apt's own configuration runs unattended-upgrades every day"
  timer=/etc/systemd/system/fermix-update.timer
  for line in 'OnCalendar=*-*-* 04:00:00 UTC' 'Persistent=true' 'WantedBy=timers.target'; do
    check "grep -qxF '$line' $timer" "the update timer has $line"
  done
  service=/etc/systemd/system/fermix-update.service
  for line in 'Type=oneshot' 'ExecStart=/usr/local/sbin/fermix-update' 'TimeoutStartSec=30min'; do
    check "grep -qxF '$line' $service" "the update's unit has $line"
  done
  check "contains $LOG/calls.log 'systemctl --quiet enable --now fermix-update.timer'" "the update timer is on"
  timer=/etc/systemd/system/fermix-follow.timer
  for line in 'OnBootSec=2min' 'OnUnitActiveSec=5min' 'WantedBy=timers.target'; do
    check "grep -qxF '$line' $timer" "the follow timer has $line"
  done
  service=/etc/systemd/system/fermix-follow.service
  # The journal holds a line only for what a follow run did: its own lines go
  # in at notice, and systemd's start and finish lines, at info, stay out.
  for line in 'Type=oneshot' 'ExecStart=/usr/local/sbin/fermix-update --follow' 'TimeoutStartSec=30min' \
    'SyslogLevel=notice' 'LogLevelMax=notice'; do
    check "grep -qxF '$line' $service" "the follow run's unit has $line"
  done
  check "[ \"\$(mode_owner $timer)\" = '644 root:root' ] && [ \"\$(mode_owner $service)\" = '644 root:root' ]" \
    "the follow run's units are root's"
  check "contains $LOG/calls.log 'systemctl --quiet enable --now fermix-follow.timer'" "the follow timer is on"
  update=/usr/local/sbin/fermix-update
  check "[ \"\$(mode_owner $update)\" = '755 root:root' ]" "the update script is root's"
  check "dash -n $update" "dash parses the update script"
  check "shellcheck -s sh $update" "shellcheck finds nothing in the update script"
}

snapshot_files() {
  find /etc/fermix /etc/systemd/system /etc/tmpfiles.d/fermix-always-on.conf /run/fermix \
    /etc/apt/apt.conf.d/21fermix-always-on /usr/local/sbin/fermix-update /etc/fstab /swapfile \
    -type f 2>/dev/null | sort | xargs sha256sum >"$1"
  nft list table inet fermix_metadata >>"$1"
  stat -c '%n %a %U:%G' /run/fermix /home/fermix /swapfile >>"$1"
}

existing_host() {
  check_refusals

  mkdir -p "$FIXTURES"
  printf 'enrolling|Enrolling with Invented Mac.\nenrolled|Enrolled with Invented Mac; waiting for its move.\n' \
    >"$FIXTURES/phases"
  run_with_terminal
  check "[ $STATUS -eq 0 ]" "an existing host enrolls with the code typed at the terminal (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
  ENGINE_UID=$(id -u fermix)
  code_absent_everywhere
  cat >/tmp/calls.expected <<EOF
apt-get -qq update
apt-get -qq -y install --no-install-recommends nftables
systemctl daemon-reload
systemctl --quiet enable fermix-metadata-block.service
systemctl restart fermix-metadata-block.service
fallocate -l 2G /swapfile.incoming
mkswap /swapfile.incoming
swapon /swapfile
apt-get -qq -y install --no-install-recommends ca-certificates curl
curl GET https://fermix.ai/install
installer --no-setup
apt-get -qq -y install --no-install-recommends unattended-upgrades
systemctl daemon-reload
systemctl --quiet enable --now fermix-update.timer
systemctl --quiet enable --now fermix-follow.timer
systemctl daemon-reload
loginctl enable-linger fermix
systemctl start user@$ENGINE_UID.service
fermix home enroll --code-file /run/fermix/enroll.code [as fermix]
fermix service install --home /home/fermix/.fermix [as fermix]
apt-get -qq -y install --no-install-recommends chromium
fermix home status --json [as fermix]
fermix home status --json [as fermix]
EOF
  check "cmp -s $LOG/calls.log /tmp/calls.expected" \
    "the steps run in order, swap and updates among them, enrolling with no bucket, then waiting until the primary accepts it"
  cmp -s "$LOG/calls.log" /tmp/calls.expected || diff /tmp/calls.expected "$LOG/calls.log" | sed 's/^/    /' || true
  grep '^==> ' "$OUT" | cut -c5- | cut -d' ' -f1-3 >/tmp/steps
  cat >/tmp/steps.expected <<'EOF'
Writing the enrollment
Blocking the instance
Giving this server
Installing Fermix with
(test) installed the
Turning on updates:
Creating the account
Enrolling this server
Starting Fermix as
Installing Chromium for
Waiting for your
Done. Open Always
EOF
  check "cmp -s /tmp/steps /tmp/steps.expected" "it says each step, in order"
  check "! has_noise $OUT" "apt-get's, dpkg's and systemctl's progress stays out of its output"
  check "[ -z \"\$(grep -v '^==> ' $OUT | grep -v '^Enrollment code from Fermix')\" ]" \
    "it says its own steps and nothing else"
  grep -v '^==> ' "$OUT" | grep -v '^Enrollment code from Fermix' | sed 's/^/    /' || true
  check "[ -x /usr/bin/chromium ]" "Debian gets the distribution's Chromium"
  check "[ -z \"\$(find /run -maxdepth 1 -name 'fermix-always-on.*')\" ]" "it leaves no work directory behind"
  check_account
  check_code_file
  check_metadata_block
  check_swap
  check_updates
  check_package_unit

  # Once the move made this server the primary, a home that runs.
  rm -f "$FIXTURES/phases"
  printf 'primary\n' >"$FIXTURES/role"
  snapshot_files /tmp/state.first
  run_first_boot sh "$FIRST_BOOT"
  check "[ $STATUS -eq 0 ]" "a re-run with no code succeeds (exit $STATUS)"
  check "contains $OUT 'The Fermix home /home/fermix/.fermix already exists, so this host is not enrolled again'" \
    "a re-run says the home exists and does not enroll again"
  check "[ \"\$(grep -c 'fermix ' $LOG/calls.log)\" -eq 2 ] && [ \"\$(grep 'fermix ' $LOG/calls.log | head -n 1)\" = 'fermix home status --json [as fermix]' ]" \
    "a re-run reads what the home is first, then neither enrolls nor waits for the primary"
  check "contains $LOG/calls.log 'fermix service install --home /home/fermix/.fermix [as fermix]'" \
    "a re-run binds and starts the service again"
  check "contains $OUT 'Done. Fermix runs from the home it already had.'" "a re-run says Fermix runs from that home"
  check "[ \"\$(tail -n 1 $OUT)\" = '==> Fermix runs on this server as your primary: to set this server up again, which deletes that home, run sudo -H -u fermix env -C / XDG_RUNTIME_DIR=/run/user/$ENGINE_UID /usr/bin/fermix service uninstall, then sudo rm -rf /home/fermix/.fermix, then this command again.' ]" \
    "then what the home is and the commands that remove it"
  snapshot_files /tmp/state.second
  check "cmp -s /tmp/state.first /tmp/state.second" "a re-run leaves every file, mode and rule as it was"
  cmp -s /tmp/state.first /tmp/state.second || diff /tmp/state.first /tmp/state.second | sed 's/^/    /' || true
  check "[ \"\$(getent passwd | grep -c '^fermix:')\" -eq 1 ]" "a re-run creates no second account"
  check "! grep -q 'fallocate\|mkswap\|swapon' $LOG/calls.log" "a re-run makes no second swap file and turns nothing on again"

  # Given a code, that home is refused, saying what it is and how to remove it.
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  stopped_with "Fermix runs on this server as your primary: to set this server up again, which deletes that home, run sudo -H -u fermix env -C / XDG_RUNTIME_DIR=/run/user/$ENGINE_UID /usr/bin/fermix service uninstall, then sudo rm -rf /home/fermix/.fermix, then this command again." \
    "the primary, given a code, is refused with the commands that remove it"
  check "[ \"\$(cat $LOG/calls.log)\" = 'fermix home status --json [as fermix]' ] && [ -d /home/fermix/.fermix ]" \
    "after reading the home, with nothing installed and the home left as it is"
  rm -f "$FIXTURES/role"

  # A candidate whose enrollment failed enrolls again with the new code:
  # Fermix stopped, enrolled, started and waited for.
  printf 'failed|The enrollment with Invented Mac failed.\nenrolling|Enrolling with Invented Mac.\nenrolled|Enrolled with Invented Mac; waiting for its move.\n' \
    >"$FIXTURES/phases"
  run_first_boot env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -eq 0 ]" "a candidate whose enrollment failed enrolls again with the new code (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
  cat >/tmp/calls.expected <<EOF
fermix home status --json [as fermix]
fermix service uninstall [as fermix]
fermix home enroll --code-file /run/fermix/enroll.code [as fermix]
fermix service install --home /home/fermix/.fermix [as fermix]
fermix home status --json [as fermix]
fermix home status --json [as fermix]
EOF
  grep '^fermix ' "$LOG/calls.log" >/tmp/calls.seen || true
  check "cmp -s /tmp/calls.seen /tmp/calls.expected" \
    "it reads the home first, then stops Fermix before enrolling, starts it and waits for the primary"
  cmp -s /tmp/calls.seen /tmp/calls.expected || diff /tmp/calls.expected /tmp/calls.seen | sed 's/^/    /' || true
  code_absent_everywhere
  rm -f "$FIXTURES/phases"

  # The same host enrolled again, the code in the environment and the release
  # on the command line as cloud-init passes them, with a bucket. Its swap
  # file is on by now, so no swap step runs.
  fresh_host
  run_first_boot env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" \
    --snapshot-bucket fermix-snapshots-invented --snapshot-region eu-west-1 --version 1.2.3
  check "[ $STATUS -eq 0 ]" "a host enrolls with the code in its environment and a bucket (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
  code_absent_everywhere
  cat >/tmp/calls.expected <<EOF
apt-get -qq update
apt-get -qq -y install --no-install-recommends nftables
systemctl daemon-reload
systemctl --quiet enable fermix-metadata-block.service
systemctl restart fermix-metadata-block.service
apt-get -qq -y install --no-install-recommends ca-certificates curl
curl GET https://fermix.ai/install
installer --no-setup --version 1.2.3
apt-get -qq -y install --no-install-recommends unattended-upgrades
systemctl daemon-reload
systemctl --quiet enable --now fermix-update.timer
systemctl --quiet enable --now fermix-follow.timer
systemctl daemon-reload
loginctl enable-linger fermix
systemctl start user@$ENGINE_UID.service
fermix home enroll --code-file /run/fermix/enroll.code --snapshot-bucket fermix-snapshots-invented --snapshot-region eu-west-1 [as fermix]
fermix service install --home /home/fermix/.fermix [as fermix]
apt-get -qq -y install --no-install-recommends chromium
fermix home status --json [as fermix]
EOF
  check "cmp -s $LOG/calls.log /tmp/calls.expected" \
    "the steps run in order, with the bucket, the release, Chromium and the wait"
  check "contains $OUT '==> Installing Fermix 1.2.3, the release your computer runs, with https://fermix.ai/install'" \
    "and it names the release it installs"
  cmp -s "$LOG/calls.log" /tmp/calls.expected || diff /tmp/calls.expected "$LOG/calls.log" | sed 's/^/    /' || true
  # What through_the_installer expects the same run to do after its downloads.
  cp "$LOG/calls.log" /tmp/calls.direct
}

# Serves release $1 as fermix.ai and GitHub would for the curl stand-in: a
# table whose latest is $1 and whose one row lists the sha256 of $3 (of $2
# unless given) as its Always On server script, and $2 as that script.
serve_release() {
  listed=${3:-$2}
  printf 'format 1\nlatest %s\n%s %s fermix_always_on.sh\n' "$1" "$1" "$(sha256sum "$listed" | cut -d' ' -f1)" \
    >"$FIXTURES/releases"
  install -D -m 0644 "$2" "$FIXTURES/release/v$1/fermix_always_on.sh"
}

# Runs the regular installer with --always-on as run_apart runs first-boot.sh.
run_installer() {
  rm -rf "$INSTALLER_TMP"
  mkdir -p "$INSTALLER_TMP"
  run_apart env TMPDIR="$INSTALLER_TMP" "$@"
}

# The installer refused, or the script it ran refused, with $2 on stderr,
# before anything was installed: only the table and the script were
# fetched, no code was written and none was echoed, and no download or work
# directory is left.
installer_refused() {
  printf 'curl GET https://fermix.ai/install/releases\ncurl GET %s\n' \
    "https://github.com/tezra-io/fermix/releases/download/v1.2.3/fermix_always_on.sh" >/tmp/calls.expected
  if [ "$STATUS" -ne 0 ] && contains "$ERR" "$2" && cmp -s "$LOG/calls.log" /tmp/calls.expected &&
    [ ! -e /run/fermix/enroll.code ] && ! grep -qF -- "$CODE_BODY" "$OUT" "$ERR" &&
    [ -z "$(find "$INSTALLER_TMP" -mindepth 1)" ] && [ -z "$(find /run -maxdepth 1 -name 'fermix-always-on.*')" ]; then
    pass "$1"
  else
    fail "$1 (exit $STATUS)"
    sed 's/^/    /' "$OUT" "$ERR" "$LOG/calls.log"
  fi
}

# Always On's command for the server: the regular installer with
# --always-on, which runs this first-boot.sh as the release's server script
# once its sha256 matches the table, handing it the table's latest release.
through_the_installer() {
  fresh_host
  serve_release 1.2.3 "$FIRST_BOOT" /cloud/README.md
  run_installer env FERMIX_ENROLL_CODE="$CODE" sh "$INSTALLER" --always-on
  installer_refused "the installer refuses a server script the table does not list, before running it" \
    "sha256 mismatch: expected"

  serve_release 1.2.3 "$FIRST_BOOT"
  run_installer env FERMIX_ENROLL_CODE="$CODE" sh "$INSTALLER" --always-on "$CODE"
  installer_refused "a code passed to the installer as an argument reaches the server script, which refuses it unechoed" \
    "An option was not recognised. This script takes --restore, --snapshot-bucket, --snapshot-region, --version and --tailscale."

  # The last run of existing_host, the code in the environment and the
  # bucket on the command line, through the installer: the same steps after
  # the two downloads, the release coming from the table.
  run_installer env FERMIX_ENROLL_CODE="$CODE" sh "$INSTALLER" --always-on \
    --snapshot-bucket fermix-snapshots-invented --snapshot-region eu-west-1
  check "[ $STATUS -eq 0 ]" "a host enrolls through the installer's --always-on (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT" "$ERR"
  code_absent_everywhere
  check "! grep -qF -- \"\$CODE_BODY\" $ERR" "and the code appears in nothing it wrote to stderr"
  sha=$(sha256sum "$FIRST_BOOT" | cut -d' ' -f1)
  check "contains $OUT '==> Verified sha256 $sha against https://fermix.ai/install/releases (fermix_always_on.sh, release 1.2.3)'" \
    "it checks the server script against the table before running it"
  check "[ \"\$(sed -n 1p $LOG/calls.log)\" = 'curl GET https://fermix.ai/install/releases' ] && [ \"\$(sed -n 2p $LOG/calls.log)\" = 'curl GET https://github.com/tezra-io/fermix/releases/download/v1.2.3/fermix_always_on.sh' ]" \
    "it fetches the table, then the release's server script"
  tail -n +3 "$LOG/calls.log" >/tmp/calls.seen
  check "cmp -s /tmp/calls.seen /tmp/calls.direct" \
    "then the first boot runs the same steps, installing the table's latest release, 1.2.3"
  cmp -s /tmp/calls.seen /tmp/calls.direct || diff /tmp/calls.direct /tmp/calls.seen | sed 's/^/    /' || true
  check "[ -z \"\$(find $INSTALLER_TMP -mindepth 1)\" ]" "and the installer leaves no download behind"
}

expected_restore_steps() {
  cat <<EOF
==> Ready to restore your home here. In a shell on this server, as an account that may use sudo:
  1. Download your newest snapshot from the bucket fermix-snapshots-invented in
     eu-west-1 (its name sorts last), then copy it onto this server as
     /home/fermix/restore.fxsnap, owned by fermix:
       sudo install -o fermix -g fermix -m 0600 <the file> /home/fermix/restore.fxsnap
  2. Restore it; Fermix asks for your recovery passphrase without showing it:
       sudo -H -u fermix env -C / FERMIX_HOME=/home/fermix/.fermix-restore /usr/bin/fermix home import /home/fermix/restore.fxsnap --into /home/fermix/.fermix
  3. Start Fermix from the restored home:
       sudo -H -u fermix env -C / XDG_RUNTIME_DIR=/run/user/$ENGINE_UID /usr/bin/fermix service install --home /home/fermix/.fermix
  4. Remove the downloaded snapshot and the import's own scratch home:
       sudo rm -rf /home/fermix/restore.fxsnap /home/fermix/.fermix-restore
EOF
}

restore() {
  refuses "a restore given an enrollment code, without echoing it" \
    "--restore takes no enrollment code: the home comes from a snapshot." \
    env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --restore

  run_first_boot sh "$FIRST_BOOT" --restore --snapshot-bucket fermix-snapshots-invented --snapshot-region eu-west-1
  check "[ $STATUS -eq 0 ]" "a restore host is prepared with no code (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
  ENGINE_UID=$(id -u fermix)
  check "! grep -q 'fermix home enroll' $LOG/calls.log && ! grep -q 'fermix service install' $LOG/calls.log" \
    "a restore host neither enrolls nor starts Fermix before the import"
  check "! grep -q 'Enrollment code' $OUT && [ ! -e /run/fermix/enroll.code ] && [ ! -e /home/fermix/.fermix ]" \
    "it asks for no code, writes none, and leaves the home empty for the import"
  for step in 'Blocking the instance metadata service' 'Giving this server 2G of swap' \
    'Turning on updates' 'Creating the account fermix' 'Installing Chromium for the browser tasks'; do
    check "contains $OUT \"==> $step\"" "a restore host gets the same server: $step"
  done
  sed -n '/^==> Ready to restore/,$p' "$OUT" >/tmp/steps
  expected_restore_steps >/tmp/steps.expected
  check "cmp -s /tmp/steps /tmp/steps.expected" "it prints the import steps exactly, naming the bucket and its region"
  cmp -s /tmp/steps /tmp/steps.expected || diff /tmp/steps.expected /tmp/steps | sed 's/^/    /' || true
  check_account
  check_metadata_block
  check_swap
  check_updates
  check_package_unit

  # A host with no bucket named: the step says to copy the file over.
  run_first_boot sh "$FIRST_BOOT" --restore
  check "[ $STATUS -eq 0 ] && contains $OUT 'Copy your newest snapshot (a .fxsnap file) onto this server as'" \
    "with no bucket named it says to copy the snapshot onto the server"

  # Once the import made a home, the primary's, a re-run reads what it is,
  # starts Fermix from it and prints no steps.
  runuser -u fermix -- mkdir -p /home/fermix/.fermix
  printf 'primary\n' >"$FIXTURES/role"
  run_first_boot sh "$FIRST_BOOT" --restore
  check "[ $STATUS -eq 0 ]" "a restore re-run after the import succeeds (exit $STATUS)"
  check "contains $LOG/calls.log 'fermix home status --json [as fermix]' && contains $LOG/calls.log 'fermix service install --home /home/fermix/.fermix [as fermix]' && ! contains $OUT 'Ready to restore'" \
    "a re-run reads the home, binds and starts the restored home and prints no steps"

  # A retired copy (the marker names where Fermix moved) is refused.
  printf 'device\n' >"$FIXTURES/role"
  printf 'Invented Mac\n' >"$FIXTURES/moved-to"
  run_apart sh "$FIRST_BOOT" --restore
  stopped_with "This server's Fermix home is a retired copy, left when Fermix moved to Invented Mac: to set this server up again, which deletes that home, run sudo -H -u fermix env -C / XDG_RUNTIME_DIR=/run/user/$ENGINE_UID /usr/bin/fermix service uninstall, then sudo rm -rf /home/fermix/.fermix, then this command again." \
    "a retired copy is refused, naming where Fermix moved and the commands that remove it"
  rm -f "$FIXTURES/role" "$FIXTURES/moved-to"
}

# A fresh host in the same container: no home, no code, no fixtures left.
fresh_host() {
  rm -rf /home/fermix/.fermix /run/fermix/* "$FIXTURES/phases" "$FIXTURES/systemctl-fails" \
    "$FIXTURES/role" "$FIXTURES/moved-to"
}

# Each failure that stops the first boot: a non-zero exit, and the one
# sentence it names on stderr.
failures() {
  printf 'enrolling|Enrolling with Invented Mac.\nexpired|The enrollment code expired at 2026-10-28 00:40 UTC; open a new one in Fermix.\n' \
    >"$FIXTURES/phases"
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ \"\$(grep -c 'fermix home status' $LOG/calls.log)\" -eq 2 ]" \
    "an enrollment the primary ended stops the first boot at the next look"
  stopped_with "The enrollment code expired at 2026-10-28 00:40 UTC; open a new one in Fermix." \
    "an expired enrollment ends the first boot with the server's own sentence"

  fresh_host
  printf 'restart fermix-metadata-block.service\n' >"$FIXTURES/systemctl-fails"
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -eq 1 ] && ! grep -q 'fermix home enroll' $LOG/calls.log" "a step that stops unexpectedly ends the first boot there"

  # apt-get's own words are kept for the install that fails, and only for it.
  fresh_host
  printf 'unattended-upgrades\n' >"$FIXTURES/apt-fails"
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  printf '%s\n' 'E: Unable to locate package unattended-upgrades' \
    'fermix always-on: apt-get could not install unattended-upgrades.' >/tmp/stderr.expected
  check "[ $STATUS -eq 1 ] && cmp -s $ERR /tmp/stderr.expected" \
    "a package apt-get cannot install ends the first boot with apt-get's own message, then its sentence"
  cmp -s "$ERR" /tmp/stderr.expected || sed 's/^/    stderr: /' "$ERR"
  check "! has_noise $OUT $ERR" "and the progress of the packages before it stays out"
  rm -f "$FIXTURES/apt-fails"
}

# An Ubuntu server the owner already had, with a swap partition of its own.
ubuntu() {
  cat >/etc/os-release <<'EOF'
PRETTY_NAME="Ubuntu 24.04.3 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
ID=ubuntu
ID_LIKE=debian
EOF
  printf '/dev/vda2\n' >"$FIXTURES/swaps"
  run_first_boot env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -eq 0 ]" "an Ubuntu 24.04 host enrolls (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
  check "! grep -q chromium $LOG/calls.log && [ ! -e /usr/bin/chromium ]" "Ubuntu gets no Chromium package"
  check "[ \"\$(grep -c '^==> Ubuntu ships Chromium only as a snap' $OUT)\" -eq 1 ]" \
    "it says so in one sentence"
  check "contains $OUT 'which Fermix does not use: install a browser by hand (Google Chrome'\''s own package, for example), or browser tasks answer that no Chrome or Chromium is installed.'" \
    "the sentence says the owner installs a browser by hand, and what tasks answer until then"
  check "! grep -q 'ms-playwright' $OUT && ! grep -q 'Chrome for Testing' $OUT" \
    "and promises no browser Fermix downloads itself"
  check "contains $OUT '==> This host has swap of its own, so no swap file is made' && [ ! -e /swapfile ]" \
    "a host with swap of its own keeps it and gets no swap file"
  check "! grep -q 'fallocate\|mkswap\|swapon' $LOG/calls.log && ! grep -q /swapfile /etc/fstab" \
    "and nothing is formatted, turned on or added to /etc/fstab"
}

# The run failed, and the last line on stderr is its one sentence (the
# installer's or fermix's own message comes before it).
ended_with() {
  if [ "$STATUS" -ne 0 ] && [ "$(tail -n 1 "$ERR")" = "fermix update: $1" ]; then
    pass "$2"
  else
    fail "$2 (exit $STATUS)"
    sed 's/^/    stderr: /' "$ERR"
  fi
}

# One night's calls, exactly, in order.
night_calls() {
  printf '%s\n' "$@" >/tmp/calls.expected
  cmp -s "$LOG/calls.log" /tmp/calls.expected
}

# The reboot deferral count, root's own: "N MODE OWNER", or "none".
deferral_count() {
  file=/var/lib/fermix-update/reboot-deferrals
  if [ -f "$file" ]; then printf '%s %s\n' "$(cat "$file")" "$(mode_owner "$file")"; else echo none; fi
}

# A night the stand-in systemctl "rebooted": the real reboot empties /run.
rebooted() {
  rm -f /run/reboot-required
}

# The nightly update, run by hand as fermix-update.service runs it, one night
# per case, on a host first boot enrolled. Releases are invented versions: the
# release the computers run is the stand-in fermix's update_ceiling
# ($FIXTURES/ceiling, 1.2.3 without it), the fake installer installs the one
# it is asked for, and the stand-in fermix runs the release its last start
# installed.
updates() {
  run_first_boot env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -eq 0 ]" "a host enrolls (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
  check_updates
  update=/usr/local/sbin/fermix-update
  status='fermix service status --json [as fermix]'
  home='fermix home status --json [as fermix]'
  restart='fermix restart [as fermix]'
  reboot='systemctl reboot'
  install='curl GET https://fermix.ai/install'

  run_apart "$update"
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$status'" \
    "a night on the release its computers run downloads nothing, asks whether a restart is due, and does nothing else"
  check "contains $OUT '==> Fermix 1.2.3 is the release your computers run'" "and says so"
  check "contains $OUT '==> No restart is due and no update asks for a reboot'" "and that nothing is due"

  printf '1.2.4\n' >"$FIXTURES/ceiling"
  run_apart "$update"
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$install' 'installer --no-setup --version 1.2.4' '$status' '$home' '$restart'" \
    "a newer release on its computers is installed exactly, and with no move under way the engine restarts as its own account"
  check "contains $OUT '==> Fermix went from 1.2.3 to 1.2.4'" "and names both versions"
  for name in HOME XDG_RUNTIME_DIR FERMIX_HOME; do
    check "grep -qx $name $LOG/env-restart" "fermix restart has $name"
  done
  engine_call_is_clean service-status "the update's fermix service status"
  engine_call_is_clean restart "the update's fermix restart"

  printf '1.2.5\n' >"$FIXTURES/ceiling"
  : >"$FIXTURES/installer-fails"
  : >/run/reboot-required
  run_apart "$update"
  ended_with "The Fermix installer stopped, so the engine keeps running; its message above says why." \
    "a failed installer ends the night with its sentence"
  check "night_calls '$home' '$install' 'installer --no-setup --version 1.2.5'" \
    "and neither restarts the engine nor reboots, though a reboot is asked for"

  rm -f "$FIXTURES/installer-fails"
  run_apart "$update"
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$install' 'installer --no-setup --version 1.2.5' '$status' '$home' '$restart' '$reboot'" \
    "the next night updates, restarts the engine, then reboots as asked"
  rebooted

  printf '1.2.6\n' >"$FIXTURES/ceiling"
  : >"$FIXTURES/install-unreachable"
  : >/run/reboot-required
  run_apart "$update"
  ended_with "Could not download the Fermix installer from https://fermix.ai/install, so Fermix is not updated tonight; nothing was installed, so the restart and the reboot are still decided." \
    "an installer that cannot be downloaded says so in one line and ends the night non-zero"
  check "night_calls '$home' '$install' '$status' '$home' '$reboot'" \
    "and, nothing installed, the server still reboots as asked"
  rm -f "$FIXTURES/install-unreachable"
  rebooted

  : >"$FIXTURES/service-status-fails"
  : >/run/reboot-required
  run_apart "$update"
  ended_with "fermix service status stopped, so the engine is not restarted tonight; its message above says why." \
    "when fermix service status fails, the night says so in one line and ends non-zero"
  check "night_calls '$home' '$install' 'installer --no-setup --version 1.2.6' '$status' '$home' '$reboot'" \
    "and skips the restart but still reboots"
  rm -f "$FIXTURES/service-status-fails"
  rebooted

  : >"$FIXTURES/home-status-fails"
  : >/run/reboot-required
  run_apart "$update"
  ended_with "fermix home status stopped, so the engine is not restarted tonight and the reboot is decided as if no move were under way; its message above says why." \
    "when fermix home status fails, the night says so in one line and ends non-zero"
  check "contains $ERR 'fermix update: fermix home status stopped, so Fermix is not updated tonight; its message above says why.'" \
    "and installs nothing, with no release named"
  check "night_calls '$home' '$status' '$home' '$reboot'" "and skips the restart but reboots as if no move were under way"
  rm -f "$FIXTURES/home-status-fails"
  rebooted

  printf '1.2.7\n' >"$FIXTURES/ceiling"
  printf 'receiving|Receiving the home from Invented Mac.\n' >"$FIXTURES/phases"
  : >/run/reboot-required
  run_apart "$update"
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$install' 'installer --no-setup --version 1.2.7' '$status' '$home'" \
    "the first night this candidate receives a move, nothing restarts or reboots"
  check "contains $OUT '==> A move is under way on this server (receiving), so the engine restarts at the first follow run after it ends'" \
    "and the restart says why in one line"
  check "contains $OUT '==> A move is under way on this server (receiving), so the reboot an update asks for waits: night 1 of at most 2'" \
    "and the reboot says how many nights it has waited"
  check "[ \"\$(deferral_count)\" = '1 600 root:root' ] && [ \"\$(mode_owner /var/lib/fermix-update)\" = '700 root:root' ]" \
    "the deferral is counted in a file root alone can read"

  printf 'streaming|Moving to the invented server.\n' >"$FIXTURES/phases"
  run_apart "$update"
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$status' '$home'" \
    "the second night, this server sending its home, nothing restarts or reboots"
  check "contains $OUT '==> A move is under way on this server (streaming), so the reboot an update asks for waits: night 2 of at most 2'" \
    "and the reboot waits its second and last night"
  check "[ \"\$(deferral_count)\" = '2 600 root:root' ]" "the count reads 2"

  run_apart "$update"
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$status' '$home' '$reboot'" \
    "the third night under a move, the server reboots all the same and the engine still waits"
  check "contains $OUT '==> A move has held the reboot an update asks for off 2 nights in a row, so this server reboots now all the same'" \
    "and says so in one line"
  check "[ \"\$(deferral_count)\" = none ]" "the reboot clears the count"
  rebooted

  printf 'committed|Moved to the invented server.\n' >"$FIXTURES/phases"
  printf '1\n' >/var/lib/fermix-update/reboot-deferrals
  : >/run/reboot-required
  run_apart "$update"
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$status' '$home' '$restart' '$reboot'" \
    "a move in an ended phase (committed) defers nothing: the engine restarts and the server reboots"
  check "[ \"\$(deferral_count)\" = none ]" "and the count is cleared"
  rm -f "$FIXTURES/phases"
  rebooted

  printf '1.2.8\n' >"$FIXTURES/ceiling"
  : >"$FIXTURES/restart-fails"
  : >/run/reboot-required
  run_apart "$update"
  ended_with "Fermix is updated, but fermix restart stopped; its message above says why." \
    "a restart that fails says so in one line and ends the night non-zero"
  check "night_calls '$home' '$install' 'installer --no-setup --version 1.2.8' '$status' '$home' '$restart' '$reboot'" \
    "and the server still reboots"
  rm -f "$FIXTURES/restart-fails"
  rebooted

  printf '1.2.7\n' >"$FIXTURES/ceiling"
  run_apart "$update"
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$status' '$home' '$restart'" \
    "a computer on an older release is never installed back down to; the restart a night left due still runs"
  check "contains $OUT '==> Fermix 1.2.8 is newer than 1.2.7, the oldest release your computers run, and is never installed back down: moving Fermix back to that computer waits until it updates'" \
    "and says why"

  printf 'none\n' >"$FIXTURES/ceiling"
  run_apart "$update"
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$status'" "with no computer seen, nothing is installed"
  check "contains $OUT '==> No computer has reached this server in the last 30 days, so Fermix stays at 1.2.8'" \
    "and says so"

  rm -rf /home/fermix/.fermix
  printf '1.2.9\n' >"$FIXTURES/ceiling"
  printf '1\n' >/var/lib/fermix-update/reboot-deferrals
  run_apart "$update"
  check "[ $STATUS -eq 0 ] && night_calls '$status'" \
    "a server with no home yet (a restore host) installs nothing and starts no engine"
  check "contains $OUT '==> This server has no Fermix home yet, so no computer names the release to install; Fermix stays at 1.2.8'" \
    "and says why"
  check "contains $OUT '==> No restart is due and no update asks for a reboot'" "and that nothing is due"
  check "[ \"\$(deferral_count)\" = none ]" "a night with no move clears the count"
  check "[ -z \"\$(find /run -maxdepth 1 -name 'fermix-update.*' -type d)\" ]" "no night leaves a work directory behind"
  follow_runs
  update_lock
}

# The follow run fermix-follow.service starts every five minutes, run by hand
# as it runs it, on the same host, which has no home yet: it installs and
# restarts as the night does, never reboots, and says nothing when nothing is
# due.
follow_runs() {
  run_apart "$update" --follow
  check "[ $STATUS -eq 0 ] && [ ! -s $LOG/calls.log ] && [ ! -s $OUT ] && [ ! -s $ERR ]" \
    "a follow run on a server with no home yet runs nothing and says nothing"

  runuser -u fermix -- mkdir -p /home/fermix/.fermix
  printf '1\n' >/var/lib/fermix-update/reboot-deferrals
  count=$(deferral_count)
  : >/run/reboot-required
  run_apart "$update" --follow
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$install' 'installer --no-setup --version 1.2.9' '$status' '$home' '$restart'" \
    "a follow run installs its computers' newer release, then restarts the engine as its own account"
  check "contains $OUT '==> Fermix went from 1.2.8 to 1.2.9'" "and names both versions"
  check "[ -e /run/reboot-required ] && [ \"\$(deferral_count)\" = '$count' ]" \
    "it never reboots, though an update asks for it, and leaves the night's count as it was"

  printf '1.2.10\n' >"$FIXTURES/ceiling"
  printf 'receiving|Receiving the home from Invented Mac.\n' >"$FIXTURES/phases"
  run_apart "$update" --follow
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$install' 'installer --no-setup --version 1.2.10' '$status' '$home'" \
    "a follow run while a move is under way installs, and holds the restart"
  check "contains $OUT '==> A move is under way on this server (receiving), so the engine restarts at the first follow run after it ends'" \
    "and says the restart waits until the move ends"
  printf 'committed|Moved to the invented server.\n' >"$FIXTURES/phases"
  run_apart "$update" --follow
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$status' '$home' '$restart'" \
    "the first follow run after the move ended restarts the engine"
  rm -f "$FIXTURES/phases"

  run_apart "$update" --follow
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$status' && [ ! -s $OUT ] && [ ! -s $ERR ]" \
    "a follow run with nothing due asks only what it must and says nothing"
  run_apart "$update" --now
  check "[ $STATUS -eq 1 ] && [ ! -s $LOG/calls.log ] && [ \"\$(cat $ERR)\" = 'fermix update: An option was not recognised. fermix-update takes --follow, which fermix-follow.timer passes, or nothing for the nightly update.' ]" \
    "an option other than --follow is refused, in one sentence, before anything runs"
}

# Waits, at most 60 s, until the command $2 succeeds; past that, $1 is a
# failed check and the scenario goes on to its count.
wait_until() {
  tries=0
  until eval "$2"; do
    tries=$((tries + 1))
    if [ "$tries" -gt 600 ]; then
      fail "$1 within 60 s"
      return 0
    fi
    sleep 0.1
  done
}

# Another update's hold on the update lock, taken with the real flock until
# release_lock (at most 60 s): it says it holds the lock once it does.
hold_lock() {
  rm -f /tmp/lock-held /tmp/lock-release
  # shellcheck disable=SC2016 # the holder's own script, expanded as it runs
  flock /run/fermix-update.lock sh -c ': >/tmp/lock-held; tries=0; until [ -e /tmp/lock-release ] || [ "$tries" -gt 600 ]; do tries=$((tries + 1)); sleep 0.1; done' &
  HOLDER=$!
  wait_until "the other update holds the lock" "[ -e /tmp/lock-held ]"
}

release_lock() {
  : >/tmp/lock-release
  wait "$HOLDER"
}

# One update at a time, with the real flock: a follow run leaves the update
# to the run that holds the lock; the night waits for that run, then runs.
update_lock() {
  check "[ \"\$(mode_owner /run/fermix-update.lock)\" = '600 root:root' ]" "the update lock is a file of root's alone"
  hold_lock
  run_apart "$update" --follow
  check "[ $STATUS -eq 0 ] && [ ! -s $LOG/calls.log ] && [ \"\$(cat $OUT)\" = '==> Another Fermix update is running, so this follow run leaves it to that one' ] && [ ! -s $ERR ]" \
    "a follow run while another update holds the lock leaves it to that one, in one line"

  reset_log
  "$update" </dev/null >"$OUT" 2>"$ERR" &
  night=$!
  wait_until "the night says it waits" "contains $OUT '==> Another Fermix update is running, so the nightly update waits for it to finish'"
  check "[ ! -s $LOG/calls.log ]" "the night, finding the lock held, says it waits and runs nothing meanwhile"
  release_lock
  set +e
  wait "$night"
  STATUS=$?
  set -e
  check "[ $STATUS -eq 0 ] && night_calls '$home' '$status' '$home' '$reboot'" \
    "once the other update ends, the night runs: here the reboot the follow runs left to it"
  rebooted
  check "[ -z \"\$(find /run -maxdepth 1 -name 'fermix-update.*' -type d)\" ]" "no run leaves a work directory behind"
}

# A host joining the owner's tailnet with --tailscale. Its keyring is the one
# pkgs.tailscale.com serves today (curl and gpg are real here), so the pinned
# fingerprint is checked against Tailscale's own key, and the real apt-get
# reads the source first boot writes; tailscale itself is the stand-in, which
# the apt-get stand-in installs.
tailnet() {
  refuses "a Tailscale auth key without --tailscale, without echoing it" \
    "TS_AUTHKEY holds a Tailscale auth key, but --tailscale was not given: add --tailscale to join this server to your tailnet, or leave TS_AUTHKEY out." \
    env TS_AUTHKEY="$TS_KEY" FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  refuses "a malformed Tailscale auth key, before anything is installed" \
    "The Tailscale auth key is not between 20 and 200 characters long. Copy it again from Tailscale's admin console." \
    env TS_AUTHKEY=tskey-auth-short FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --tailscale
  refuses "no Tailscale auth key and no terminal" \
    "No Tailscale auth key: run this in a terminal, which asks for it, or pass it in TS_AUTHKEY." \
    env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --tailscale

  run_first_boot env TS_AUTHKEY="$TS_KEY" FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --tailscale --version 1.2.3
  check "[ $STATUS -eq 0 ]" "a host joins the tailnet with the key in TS_AUTHKEY, then enrolls (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
  ENGINE_UID=$(id -u fermix)
  sed 's|/run/fermix-always-on\.[A-Za-z0-9]*/|WORK/|' "$LOG/calls.log" >/tmp/calls.seen
  cat >/tmp/calls.expected <<EOF
apt-get -qq update
apt-get -qq -y install --no-install-recommends nftables
systemctl daemon-reload
systemctl --quiet enable fermix-metadata-block.service
systemctl restart fermix-metadata-block.service
fallocate -l 2G /swapfile.incoming
mkswap /swapfile.incoming
swapon /swapfile
apt-get -qq -y install --no-install-recommends ca-certificates curl
curl GET https://fermix.ai/install
installer --no-setup --version 1.2.3
apt-get -qq -y install --no-install-recommends unattended-upgrades
systemctl daemon-reload
systemctl --quiet enable --now fermix-update.timer
systemctl --quiet enable --now fermix-follow.timer
systemctl daemon-reload
loginctl enable-linger fermix
systemctl start user@$ENGINE_UID.service
apt-get -qq -y install --no-install-recommends ca-certificates curl gpg
curl GET https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg
apt-get -qq update
apt-get -qq -y install --no-install-recommends tailscale
systemctl --quiet enable --now tailscaled.service
tailscale up --auth-key=file:WORK/tailscale.authkey --timeout=2m
fermix home enroll --code-file /run/fermix/enroll.code [as fermix]
fermix service install --home /home/fermix/.fermix [as fermix]
apt-get -qq -y install --no-install-recommends chromium
fermix home status --json [as fermix]
EOF
  check "cmp -s /tmp/calls.seen /tmp/calls.expected" \
    "Tailscale comes from its repository and tailscale up reads the key file, after the account and before enrolling"
  cmp -s /tmp/calls.seen /tmp/calls.expected || diff /tmp/calls.expected /tmp/calls.seen | sed 's/^/    /' || true
  check "[ \"\$(cat $LOG/tailscale-key.sha256)\" = \"\$(printf '%s' \"\$TS_KEY\" | sha256sum | cut -d' ' -f1)\" ]" \
    "tailscale up read the key from its file"
  check "[ \"\$(cat $LOG/tailscale-key-mode)\" = '600 root:root' ]" "the key file was root's alone"
  check "[ -s $LOG/tailscale-key-path ] && [ ! -e \"\$(cat $LOG/tailscale-key-path)\" ] && [ -z \"\$(find /run -maxdepth 1 -name 'fermix-always-on.*')\" ]" \
    "the key file and its work directory are gone"
  check "! grep -rqsF -- \"\$TS_KEY\" /run /etc /home /var/log/fermix-test /var/lib/fermix-test $OUT" \
    "the key is in no file, no output and no recorded call"
  check "[ -f $LOG/env-home-enroll ] && ! grep -qx TS_AUTHKEY $LOG/env-home-enroll" "fermix home enroll does not have TS_AUTHKEY in its environment"
  keyring=/usr/share/keyrings/tailscale-archive-keyring.gpg
  check "[ \"\$(mode_owner $keyring)\" = '644 root:root' ]" "apt's keyring for Tailscale is root's and readable"
  check "[ \"\$(gpg --batch --quiet --show-keys --with-colons $keyring | sed -n '/^pub:/{n;s/^fpr:::::::::\([0-9A-F]*\):.*/\1/p;}')\" = $TAILSCALE_FPR ]" \
    "it holds Tailscale's package signing key alone, by its fingerprint"
  printf '%s\n' "# Fermix Always On: Tailscale's packages for debian trixie, signed by the key $TAILSCALE_FPR, which the first boot checked." \
    "deb [signed-by=$keyring] https://pkgs.tailscale.com/stable/debian trixie main" >/tmp/source.expected
  check "cmp -s /etc/apt/sources.list.d/tailscale.list /tmp/source.expected && [ \"\$(mode_owner /etc/apt/sources.list.d/tailscale.list)\" = '644 root:root' ]" \
    "the apt source names Tailscale's repository and only that keyring"
  # The real apt-get on that one source (an empty parts directory, so only it
  # is read): it fetches Tailscale's InRelease and reports no warning or
  # error, which a signature it could not check would be.
  mkdir -p /tmp/apt-no-parts
  set +e
  /usr/bin/apt-get -o Dir::Etc::SourceList=/etc/apt/sources.list.d/tailscale.list \
    -o Dir::Etc::SourceParts=/tmp/apt-no-parts -o APT::Get::List-Cleanup=0 --error-on=any update \
    >/tmp/apt-update.out 2>&1
  apt_status=$?
  set -e
  check "[ $apt_status -eq 0 ] && grep -qF 'https://pkgs.tailscale.com/stable/debian trixie InRelease' /tmp/apt-update.out && ! grep -q '^[WE]:' /tmp/apt-update.out" \
    "the real apt-get reads Tailscale's repository through that source, its signature checked with that key"
  grep -q '^[WE]:' /tmp/apt-update.out && sed 's/^/    /' /tmp/apt-update.out
  check "apt-cache policy tailscale | grep -qF 'https://pkgs.tailscale.com/stable/debian trixie/main'" \
    "and offers Tailscale's own package from it"
  check "contains $OUT '==> This server is on your tailnet at 100.88.12.34'" "it says the server's tailnet address"

  # Run again once the move made it the primary, a home that runs.
  printf 'primary\n' >"$FIXTURES/role"
  run_first_boot sh "$FIRST_BOOT" --tailscale
  rm -f "$FIXTURES/role"
  check "[ $STATUS -eq 0 ]" "a re-run on the tailnet needs no key and no terminal (exit $STATUS)"
  check "contains $OUT '==> This server is already on the tailnet invented.example, so Tailscale is not installed or logged in again'" \
    "it says the server is on a tailnet already, naming it"
  check "! grep -q tailscale $LOG/calls.log" "and installs nothing of Tailscale and logs in again nowhere"

  fresh_host
  rm -f /var/lib/fermix-test/tailscale-state
  : >"$FIXTURES/tailscale-up-fails"
  run_apart env TS_AUTHKEY="$TS_KEY" FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --tailscale
  check "[ $STATUS -eq 1 ] && [ \"\$(tail -n 1 $ERR)\" = \"fermix always-on: tailscale up did not join this server to your tailnet, so the first boot stops here; its message above says why. A key that is used up, expired or revoked is refused: create a new one and run this again. If it printed a link to approve this server, approve it there and run this again without a key.\" ]" \
    "a tailscale up that fails stops the first boot with one sentence"
  check "grep -q '^tailscale up ' $LOG/calls.log && ! grep -q 'fermix home enroll' $LOG/calls.log" "before enrolling"
  check "[ -s $LOG/tailscale-key-path ] && [ ! -e \"\$(cat $LOG/tailscale-key-path)\" ] && ! grep -rqsF -- \"\$TS_KEY\" /run $OUT $ERR" \
    "and the key file is gone, the key in no output"
  rm -f "$FIXTURES/tailscale-up-fails"
}

# The real package and the real browser: what the engine's launcher starts
# (`chromium` on its PATH, headless, the launcher's Linux flags, through the
# shell that first raises its oom_score_adj to 1000), as the engine account,
# with no --no-sandbox, so Chromium's own sandbox has to come up.
chromium() {
  apt-get -qq update >/dev/null
  apt-get -qq -y install --no-install-recommends nftables >/dev/null 2>&1
  install_stubs
  run_first_boot env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -eq 0 ]" "a Debian host installs the distribution's Chromium with the real apt-get (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || tail -n 20 "$OUT" | sed 's/^/    /'
  check "dpkg-query -W -f='\${Status}' chromium | grep -q 'install ok installed'" "the chromium package is installed"
  check "! has_noise $OUT" "the real apt-get's and dpkg's progress for Chromium's packages stays out of its output"
  printf '    %s lines of output, %s of them its own steps\n' "$(wc -l <"$OUT")" "$(grep -c '^==> ' "$OUT")"
  check "[ \"\$(runuser -u fermix -- env -i PATH=/usr/bin:/bin sh -c 'command -v chromium')\" = /usr/bin/chromium ]" \
    "the engine account finds chromium on its PATH, where the launcher looks"
  guard='echo 1000 >/proc/self/oom_score_adj && exec "$@"'
  check "[ \"\$(runuser -u fermix -- /bin/sh -c '$guard' sh cat /proc/self/oom_score_adj)\" = 1000 ]" \
    "the launcher's shell raises the engine account's score to 1000 for what it starts"
  profile=/home/fermix/.fermix/browser/profiles/fermix_headless
  runuser -u fermix -- mkdir -p "$profile"
  set +e
  runuser -u fermix -- env -i HOME=/home/fermix USER=fermix LOGNAME=fermix PATH=/usr/bin:/bin LANG=C.UTF-8 \
    /bin/sh -c "$guard" sh chromium --headless=new --disable-dev-shm-usage --no-first-run --no-default-browser-check \
    --disable-background-networking --disable-component-update --password-store=basic \
    --use-mock-keychain --user-data-dir="$profile" \
    --dump-dom 'data:text/html,<p id="probe">fermix-headless-ok</p>' >/tmp/chromium.out 2>/tmp/chromium.err
  chromium_status=$?
  set -e
  check "[ $chromium_status -eq 0 ] && grep -q 'fermix-headless-ok' /tmp/chromium.out" \
    "Chromium renders a page headless as the engine account"
  check "! grep -q 'No usable sandbox' /tmp/chromium.err" "with its own sandbox, not without one"
  [ "$chromium_status" -eq 0 ] || tail -n 20 /tmp/chromium.err | sed 's/^/    /'
}

# -- s3-backups (E1) -----------------------------------------------------------

DESTINATION=/etc/fermix/snapshot-destination
HELPER=/usr/local/sbin/fermix-snapshot-credentials
SESSIONS=/run/fermix-snapshots
S3_BUCKET=fermix-server-snapshots-111122223333-eu-west-1
S3_ROLE=arn:aws:iam::111122223333:role/fermix-server/fermix-server-snapshot-writer
# Invented values in AWS's shapes; nothing here is a secret.
INSTANCE_KEY=ASIAINVENTEDINSTANCE1
INSTANCE_SECRET=InventedInstanceSecretForTheContainerTest0123
INSTANCE_TOKEN=IQoJInventedInstanceTokenForTheContainerTestOnly/0123456789+abcdef=
SESSION_KEY=ASIAINVENTEDSESSION01
SESSION_SECRET=InventedSessionSecretForTheContainerTest/0123
SESSION_TOKEN=IQoJInventedSessionTokenForTheContainerTestOnly/0123456789+abcdef=

# What fermix-server-aws's user data writes, as root.
write_destination() {
  install -d -m 0755 /etc/fermix
  printf '# Written by fermix-server'"'"'s user data (enable_s3_backups).\nbucket=%s\nregion=eu-west-1\nrole_arn=%s\n' \
    "$S3_BUCKET" "$S3_ROLE" >"$DESTINATION"
  chmod 0644 "$DESTINATION"
}

# The metadata service's role and credentials, and STS's answer: a session
# unless $1 names a status, with $2 as its body.
serve_aws() {
  rm -rf "$FIXTURES/imds" "$FIXTURES/sts"
  mkdir -p "$FIXTURES/imds" "$FIXTURES/sts"
  printf 'fermix-server-instance\n' >"$FIXTURES/imds/role"
  cat >"$FIXTURES/imds/credentials.json" <<EOF
{
  "Code" : "Success",
  "LastUpdated" : "2026-11-09T05:00:00Z",
  "Type" : "AWS-HMAC",
  "AccessKeyId" : "$INSTANCE_KEY",
  "SecretAccessKey" : "$INSTANCE_SECRET",
  "Token" : "$INSTANCE_TOKEN",
  "Expiration" : "2026-11-09T11:00:00Z"
}
EOF
  if [ -n "${1-}" ]; then
    printf '%s' "$1" >"$FIXTURES/sts/status"
    printf '%s' "$2" >"$FIXTURES/sts/answer.xml"
    return 0
  fi
  cat >"$FIXTURES/sts/answer.xml" <<EOF
<AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
  <AssumeRoleResult>
    <AssumedRoleUser>
      <AssumedRoleId>AROAINVENTED:fermix-snapshots</AssumedRoleId>
      <Arn>arn:aws:sts::111122223333:assumed-role/fermix-server-snapshot-writer/fermix-snapshots</Arn>
    </AssumedRoleUser>
    <Credentials>
      <AccessKeyId>$SESSION_KEY</AccessKeyId>
      <SecretAccessKey>$SESSION_SECRET</SecretAccessKey>
      <SessionToken>$SESSION_TOKEN</SessionToken>
      <Expiration>2026-11-09T06:00:00Z</Expiration>
    </Credentials>
  </AssumeRoleResult>
</AssumeRoleResponse>
EOF
}

# No instance secret or token in any command line, output or recorded call.
secrets_absent_everywhere() {
  for secret in "$INSTANCE_SECRET" "$INSTANCE_TOKEN" "$SESSION_SECRET" "$SESSION_TOKEN"; do
    if grep -rqF -- "$secret" "$OUT" "$LOG/calls.log" "$LOG/curl-argv" "$LOG/exec-start" 2>/dev/null; then
      fail "a secret of the instance role or the session appears in a command line, an output or a recorded call"
      return 0
    fi
  done
  pass "no secret of the instance role or the session is in a command line, an output or a recorded call"
}

# The helper, as the timer runs it: its exit in STATUS, its stderr in ERR.
run_helper() {
  reset_log
  set +e
  "$HELPER" </dev/null >"$OUT" 2>"$ERR"
  STATUS=$?
  set -e
}

# The helper refused with $1: its sentence on stderr and in the error file
# the engine shows, the session it held before left until it runs out.
helper_refused() {
  if [ "$STATUS" -eq 1 ] && [ "$(cat "$ERR")" = "fermix snapshot credentials: $1" ] &&
    [ "$(cat "$SESSIONS/error")" = "$1" ] && [ "$(mode_owner "$SESSIONS/error")" = '640 root:fermix' ] &&
    [ -f "$SESSIONS/credentials.json" ] && [ -z "$(find "$SESSIONS" -name '.work.*')" ]; then
    pass "$2"
  else
    fail "$2 (exit $STATUS)"
    sed 's/^/    stderr: /' "$ERR"
  fi
}

s3_backups() {
  write_destination
  serve_aws
  printf 'enrolling|Enrolling with Invented Mac.\nenrolled|Enrolled with Invented Mac; waiting for its move.\n' \
    >"$FIXTURES/phases"
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -eq 0 ]" "a server whose infrastructure set its bucket enrolls (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT" "$ERR"
  ENGINE_UID=$(id -u fermix)
  check "contains $LOG/calls.log 'fermix home enroll --code-file /run/fermix/enroll.code --snapshot-bucket $S3_BUCKET --snapshot-region eu-west-1 --snapshot-instance-role [as fermix]'" \
    "it enrolls with the bucket and region the file names, signed with the instance role"
  check "contains $OUT '==> Setting up S3 backups to $S3_BUCKET, signed with this server'\''s instance role'" \
    "and says it sets S3 backups up"
  check "[ \"\$(mode_owner $HELPER)\" = '755 root:root' ] && contains $HELPER 'ROLE_ARN=$S3_ROLE' && contains $HELPER 'REGION=eu-west-1'" \
    "the helper is root's, with the role and region the file names"
  check "[ \"\$(mode_owner $SESSIONS)\" = '750 root:fermix' ]" "the session directory is root's, read by fermix"
  check "[ \"\$(cat /etc/tmpfiles.d/fermix-snapshot-credentials.conf)\" = 'd $SESSIONS 0750 root fermix -' ]" \
    "and is recreated so at every boot"
  printf '{"access_key_id":"%s","secret_access_key":"%s","session_token":"%s","expiration":"2026-11-09T06:00:00Z","account_id":"111122223333"}\n' \
    "$SESSION_KEY" "$SESSION_SECRET" "$SESSION_TOKEN" >/tmp/session.expected
  check "cmp -s $SESSIONS/credentials.json /tmp/session.expected && [ \"\$(mode_owner $SESSIONS/credentials.json)\" = '640 root:fermix' ]" \
    "the first run wrote the session and its account, root's and read by fermix"
  check "[ ! -e $SESSIONS/error ] && [ -z \"\$(find $SESSIONS -name '.work.*')\" ]" \
    "and left no error and no work directory"
  check "[ \"\$(cat $LOG/sts-signed-with)\" = $INSTANCE_KEY ] && [ \"\$(cat $LOG/sts-token-header)\" = '$INSTANCE_TOKEN' ]" \
    "STS was asked with the instance role's credentials, on curl's standard input"
  printf 'Action=AssumeRole\nVersion=2011-06-15\nRoleArn=%s\nRoleSessionName=fermix-snapshots\nDurationSeconds=3600\n' \
    "$S3_ROLE" >/tmp/params.expected
  check "cmp -s $LOG/sts-params /tmp/params.expected" "for the snapshot writer, for an hour"
  cmp -s "$LOG/sts-params" /tmp/params.expected || diff /tmp/params.expected "$LOG/sts-params" | sed 's/^/    /' || true
  service=/etc/systemd/system/fermix-snapshot-credentials.service
  timer=/etc/systemd/system/fermix-snapshot-credentials.timer
  check "contains $service 'ExecStart=$HELPER' && contains $service 'ReadWritePaths=$SESSIONS' && contains $timer 'OnUnitActiveSec=15min' && contains $timer 'OnBootSec=1min'" \
    "a root timer runs it every 15 minutes, and a minute after each boot"
  check "contains $LOG/calls.log 'systemctl --quiet enable --now fermix-snapshot-credentials.timer'" "the timer is on"
  secrets_absent_everywhere
  check "runuser -u fermix -- cat $SESSIONS/credentials.json >/dev/null" "the engine account reads the session"
  check "! runuser -u fermix -- sh -c ': >$SESSIONS/credentials.json' 2>/dev/null && ! runuser -u fermix -- sh -c ': >$SESSIONS/other' 2>/dev/null" \
    "and can change nothing there"

  # Each failure of a later run: its own sentence, kept for the engine; the
  # session the last run left stays until it runs out.
  serve_aws 403 '<ErrorResponse><Error><Type>Sender</Type><Code>AccessDenied</Code><Message>User: arn:aws:sts::111122223333:assumed-role/fermix-server-instance/i-0 is not authorized to perform: sts:AssumeRole on resource: &quot;fermix-server-snapshot-writer&quot;</Message></Error></ErrorResponse>'
  run_helper
  helper_refused 'AWS STS refused the snapshot session (HTTP 403 AccessDenied: User: arn:aws:sts::111122223333:assumed-role/fermix-server-instance/i-0 is not authorized to perform: sts:AssumeRole on resource: "fermix-server-snapshot-writer").' \
    "STS's refusal is kept in its own words"
  serve_aws 200 '<AssumeRoleResponse><AssumeRoleResult></AssumeRoleResult></AssumeRoleResponse>'
  run_helper
  helper_refused "AWS STS answered with no session in its shape, so none was handed to Fermix." \
    "an answer with no session is named"
  serve_aws
  touch "$FIXTURES/sts/unreachable"
  run_helper
  helper_refused "AWS STS could not be reached (Could not resolve host: sts.eu-west-1.amazonaws.com), so no S3 session was made." \
    "STS out of reach, in curl's words"
  serve_aws
  rm "$FIXTURES/imds/role"
  run_helper
  helper_refused "This server's instance metadata names no instance role (The requested URL returned error: 404), so no S3 session was made." \
    "a server with no instance role"
  serve_aws
  printf '{\n  "Code" : "Success",\n  "AccessKeyId" : "not one"\n}\n' >"$FIXTURES/imds/credentials.json"
  run_helper
  helper_refused "The instance role's credentials are not in the shape AWS writes, so no S3 session was made." \
    "credentials not in AWS's shape"
  serve_aws
  touch "$FIXTURES/imds/unreachable"
  run_helper
  helper_refused "The instance metadata service did not answer (Connection timed out after 5002 milliseconds), so no S3 session was made." \
    "the metadata service out of reach"
  serve_aws
  run_helper
  check "[ $STATUS -eq 0 ] && [ ! -e $SESSIONS/error ] && cmp -s $SESSIONS/credentials.json /tmp/session.expected" \
    "the next run that works clears the error"
  secrets_absent_everywhere

  # A first boot whose helper cannot hand a session stops before enrolling.
  fresh_host
  serve_aws 403 '<ErrorResponse><Error><Code>AccessDenied</Code><Message>Not authorized.</Message></Error></ErrorResponse>'
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "! grep -q 'fermix home enroll' $LOG/calls.log" "a helper that fails stops the first boot before it enrolls"
  check "contains $ERR 'fermix always-on: The S3 credentials helper could not hand Fermix a session, so S3 backups would fail; its message above says why.' && contains $ERR 'AWS STS refused the snapshot session (HTTP 403 AccessDenied: Not authorized.)'" \
    "with its own sentence after the helper's"
  serve_aws

  # The destination is one path: flags naming another bucket, and a file that
  # is not root's alone or not in its shape, are refused before anything runs.
  fresh_host
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --snapshot-bucket fermix-snapshots-invented --snapshot-region eu-west-1
  stopped_with "--snapshot-bucket and --snapshot-region name another bucket than $DESTINATION, which this server's infrastructure wrote: leave them out to use $S3_BUCKET in eu-west-1." \
    "flags that name another bucket than the infrastructure's are refused"
  check "[ ! -s $LOG/calls.log ]" "before anything runs"
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --snapshot-bucket "$S3_BUCKET" --snapshot-region eu-west-1
  check "[ $STATUS -eq 0 ] && contains $LOG/calls.log '--snapshot-bucket $S3_BUCKET --snapshot-region eu-west-1 --snapshot-instance-role'" \
    "the same bucket given as flags too is the one path"
  fresh_host
  chmod 0664 "$DESTINATION"
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  stopped_with "$DESTINATION is not root's alone (owned by root, writable by no other account), so the bucket it names is not used." \
    "a destination another account could write is refused"
  chmod 0644 "$DESTINATION"
  sed -i '/^role_arn=/d' "$DESTINATION"
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  stopped_with "$DESTINATION names no IAM role on one role_arn= line." "a destination with no role is refused"
  printf 'role_arn=%s\nrole_arn=%s\n' "$S3_ROLE" "$S3_ROLE" >>"$DESTINATION"
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  stopped_with "$DESTINATION names no IAM role on one role_arn= line." "and one with two"
  write_destination
  sed -i 's/^bucket=.*/bucket=Not_A_Bucket/' "$DESTINATION"
  run_apart env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  stopped_with "$DESTINATION names no S3 bucket on one bucket= line." "a destination naming no bucket is refused"
  write_destination

  # A server restored from a snapshot gets the helper too, and the steps name
  # the bucket the infrastructure set.
  fresh_host
  rm -rf /home/fermix/.fermix "$SESSIONS"
  run_first_boot sh "$FIRST_BOOT" --restore
  check "[ $STATUS -eq 0 ] && contains $OUT 'from the bucket $S3_BUCKET in' && [ -f $SESSIONS/credentials.json ]" \
    "a restore host gets the helper and names the bucket in its steps"
  check "! grep -q 'fermix home enroll' $LOG/calls.log" "and enrolls nothing"
}

CODE=$(make_code "invented-enrollment-secret-for-tests-only")
CODE_BODY=${CODE#fxenroll1.}
# An invented key in the real shape, and Tailscale's package signing key, as
# first-boot.sh pins it.
TS_KEY=tskey-auth-kInvented1CNTRL-InventedSecretForTheContainerTestOnly012345
TAILSCALE_FPR=2596A99EAAB33821893C0A79458CA832957F5868
dash -n "$FIRST_BOOT"
pass "dash parses first-boot.sh"
mkdir -p "$FIXTURES"
case "$SCENARIO" in
  existing-host) setup_tools; existing_host; through_the_installer ;;
  restore) setup_tools; restore ;;
  failures) setup_tools; failures ;;
  ubuntu) setup_tools; ubuntu ;;
  updates) setup_tools; updates ;;
  tailnet) setup_tools ca-certificates curl gpg; tailnet ;;
  chromium) chromium ;;
  s3-backups) setup_tools; s3_backups ;;
  *)
    echo "unknown scenario $SCENARIO" >&2
    exit 2
    ;;
esac

if [ "$FAILURES" -ne 0 ]; then
  printf '%s: %s check(s) failed\n' "$SCENARIO" "$FAILURES"
  exit 1
fi
printf '%s: every check passed\n' "$SCENARIO"
