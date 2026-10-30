#!/bin/sh
# Runs inside a throwaway debian:trixie-slim container started by
# first_boot_test.sh, with packaging/cloud mounted read-only at /cloud, the
# package's systemd units at /linux-systemd, /run on a tmpfs and NET_ADMIN, so
# nft loads the real ruleset. useradd, runuser and nft are real; systemctl,
# loginctl, curl, apt-get and fermix are the stand-ins in stubs/ (in the
# chromium scenario apt-get is the real one). One scenario per container:
#
#   existing-host  refusals, then the code typed at a terminal, the wait for
#                  the primary, then a re-run; then the code in the
#                  environment with a bucket
#   restore        --restore: no code, no enrollment, the steps printed, a
#                  re-run once a home exists
#   failures       each failure that stops the first boot: its exit status
#                  and its one sentence on stderr
#   ubuntu         no Chromium package, and the sentence that says to install one
#   chromium       the distribution's Chromium installed for real and started
#                  headless as the engine account, its own sandbox on
set -eu

SCENARIO=${1:?scenario: existing-host, restore, failures, ubuntu or chromium}
FIRST_BOOT=/cloud/first-boot.sh
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
  for stub in systemctl loginctl curl; do install -m 0755 "/cloud/test/stubs/$stub" "/usr/local/bin/$stub"; done
  reset_log
}

setup_tools() {
  apt-get -qq update >/dev/null
  apt-get -qq -y install --no-install-recommends nftables >/dev/null 2>&1
  install_stubs
  install -m 0755 /cloud/test/stubs/apt-get /usr/local/sbin/apt-get
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
    [ ! -s "$LOG/calls.log" ] && ! grep -qF -- "$CODE_BODY" "$OUT" &&
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

check_refusals() {
  refuses "a host that is not Debian 12, Debian 13 or Ubuntu 24.04" \
    "This host runs Invented Linux 7. Fermix Always On supports Debian 12, Debian 13 and Ubuntu 24.04." \
    sh -c "cp /etc/os-release /tmp/os-release && printf 'ID=invented\nVERSION_ID=\"7\"\nPRETTY_NAME=\"Invented Linux 7\"\n' >/etc/os-release && { FERMIX_ENROLL_CODE='$CODE' sh $FIRST_BOOT; status=\$?; cp /tmp/os-release /etc/os-release; exit \$status; }"
  printf '#!/bin/sh\necho riscv64\n' >/usr/local/bin/uname
  chmod 0755 /usr/local/bin/uname
  refuses "an architecture other than arm64 and x86_64" \
    "This host is riscv64. Fermix Always On supports arm64 and x86_64." \
    env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  rm -f /usr/local/bin/uname
  refuses "an account other than root" "Run this as root" \
    runuser -u nobody -- env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
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
  refuses "an unknown option, without echoing it (here the code itself)" "An option was not recognised. This script takes --restore, --snapshot-bucket and --snapshot-region." \
    env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" "$CODE"
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

expected_ruleset() {
  cat <<'EOF'
table inet fermix_metadata {
	chain output {
		type filter hook output priority filter; policy accept;
		ip daddr 169.254.169.254 meta skuid != 0 drop
		ip6 daddr fd00:ec2::254 meta skuid != 0 drop
	}
}
EOF
}

check_metadata_block() {
  nft list table inet fermix_metadata >/tmp/ruleset 2>&1 || true
  expected_ruleset >/tmp/ruleset.expected
  check "cmp -s /tmp/ruleset /tmp/ruleset.expected" "nft holds exactly the metadata block for every uid but 0"
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
}

# The unit the package installs is what runs the engine on the server: five
# starts in ten minutes, so a crash loop stops and the budget comes back.
check_package_unit() {
  unit=/usr/lib/systemd/user/fermix.service
  for line in 'StartLimitIntervalSec=600' 'StartLimitBurst=5' 'Restart=always' 'RestartSec=5'; do
    check "grep -qx '$line' $unit" "the package's unit the server runs has $line"
  done
}

snapshot_files() {
  find /etc/fermix /etc/systemd/system /etc/tmpfiles.d/fermix-always-on.conf /run/fermix \
    -type f 2>/dev/null | sort | xargs sha256sum >"$1"
  nft list table inet fermix_metadata >>"$1"
  stat -c '%n %a %U:%G' /run/fermix /home/fermix >>"$1"
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
systemctl enable fermix-metadata-block.service
systemctl restart fermix-metadata-block.service
apt-get -qq -y install --no-install-recommends ca-certificates curl
curl GET https://fermix.ai/install
installer --no-setup
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
    "the steps run in order, enrolling with no bucket, then waiting until the primary accepts it"
  cmp -s "$LOG/calls.log" /tmp/calls.expected || diff /tmp/calls.expected "$LOG/calls.log" | sed 's/^/    /' || true
  grep '^==> ' "$OUT" | cut -c5- | cut -d' ' -f1-3 >/tmp/steps
  cat >/tmp/steps.expected <<'EOF'
Writing the enrollment
Blocking the instance
Installing Fermix with
(test) installed the
Creating the account
Enrolling this server
Starting Fermix as
Installing Chromium for
Waiting for your
Done. Open Always
EOF
  check "cmp -s /tmp/steps /tmp/steps.expected" "it says each step, in order"
  check "[ -x /usr/bin/chromium ]" "Debian gets the distribution's Chromium"
  check "[ -z \"\$(find /run -maxdepth 1 -name 'fermix-always-on.*')\" ]" "it leaves no work directory behind"
  check_account
  check_code_file
  check_metadata_block
  check_package_unit

  snapshot_files /tmp/state.first
  run_first_boot sh "$FIRST_BOOT"
  check "[ $STATUS -eq 0 ]" "a re-run with no code succeeds (exit $STATUS)"
  check "contains $OUT 'The Fermix home /home/fermix/.fermix already exists, so this host is not enrolled again'" \
    "a re-run says the home exists and does not enroll again"
  check "! grep -q 'home enroll' $LOG/calls.log && ! grep -q 'home status' $LOG/calls.log" \
    "a re-run neither enrolls nor waits for the primary"
  check "contains $LOG/calls.log 'fermix service install --home /home/fermix/.fermix [as fermix]'" \
    "a re-run binds and starts the service again"
  check "contains $OUT 'Done. Fermix runs from the home it already had.'" "a re-run says Fermix runs from that home"
  snapshot_files /tmp/state.second
  check "cmp -s /tmp/state.first /tmp/state.second" "a re-run leaves every file, mode and rule as it was"
  cmp -s /tmp/state.first /tmp/state.second || diff /tmp/state.first /tmp/state.second | sed 's/^/    /' || true
  check "[ \"\$(getent passwd | grep -c '^fermix:')\" -eq 1 ]" "a re-run creates no second account"

  # The same host enrolled again, the code in the environment as cloud-init
  # passes it, with a bucket.
  fresh_host
  run_first_boot env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" \
    --snapshot-bucket fermix-snapshots-invented --snapshot-region eu-west-1
  check "[ $STATUS -eq 0 ]" "a host enrolls with the code in its environment and a bucket (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
  code_absent_everywhere
  cat >/tmp/calls.expected <<EOF
apt-get -qq update
apt-get -qq -y install --no-install-recommends nftables
systemctl daemon-reload
systemctl enable fermix-metadata-block.service
systemctl restart fermix-metadata-block.service
apt-get -qq -y install --no-install-recommends ca-certificates curl
curl GET https://fermix.ai/install
installer --no-setup
systemctl daemon-reload
loginctl enable-linger fermix
systemctl start user@$ENGINE_UID.service
fermix home enroll --code-file /run/fermix/enroll.code --snapshot-bucket fermix-snapshots-invented --snapshot-region eu-west-1 [as fermix]
fermix service install --home /home/fermix/.fermix [as fermix]
apt-get -qq -y install --no-install-recommends chromium
fermix home status --json [as fermix]
EOF
  check "cmp -s $LOG/calls.log /tmp/calls.expected" \
    "the steps run in order, with the bucket, Chromium and the wait"
  cmp -s "$LOG/calls.log" /tmp/calls.expected || diff /tmp/calls.expected "$LOG/calls.log" | sed 's/^/    /' || true
}

expected_restore_steps() {
  cat <<EOF
==> Ready to restore your home here. In a shell on this server, as an account that may use sudo:
  1. Download your newest snapshot from the bucket fermix-snapshots-invented in
     eu-west-1 (its name sorts last), then copy it onto this server as
     /home/fermix/restore.fxsnap, owned by fermix:
       sudo install -o fermix -g fermix -m 0600 <the file> /home/fermix/restore.fxsnap
  2. Restore it; Fermix asks for your recovery passphrase without showing it:
       sudo -H -u fermix env FERMIX_HOME=/home/fermix/.fermix-restore /usr/bin/fermix home import /home/fermix/restore.fxsnap --into /home/fermix/.fermix
  3. Start Fermix from the restored home:
       sudo -H -u fermix env XDG_RUNTIME_DIR=/run/user/$ENGINE_UID /usr/bin/fermix service install --home /home/fermix/.fermix
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
  for step in 'Blocking the instance metadata address' 'Creating the account fermix' \
    'Installing Chromium for the browser tasks'; do
    check "contains $OUT \"==> $step\"" "a restore host gets the same server: $step"
  done
  sed -n '/^==> Ready to restore/,$p' "$OUT" >/tmp/steps
  expected_restore_steps >/tmp/steps.expected
  check "cmp -s /tmp/steps /tmp/steps.expected" "it prints the import steps exactly, naming the bucket and its region"
  cmp -s /tmp/steps /tmp/steps.expected || diff /tmp/steps.expected /tmp/steps | sed 's/^/    /' || true
  check_account
  check_metadata_block
  check_package_unit

  # A host with no bucket named: the step says to copy the file over.
  run_first_boot sh "$FIRST_BOOT" --restore
  check "[ $STATUS -eq 0 ] && contains $OUT 'Copy your newest snapshot (a .fxsnap file) onto this server as'" \
    "with no bucket named it says to copy the snapshot onto the server"

  # Once the import made a home, a re-run starts Fermix from it and prints no
  # steps.
  runuser -u fermix -- mkdir -p /home/fermix/.fermix
  run_first_boot sh "$FIRST_BOOT" --restore
  check "[ $STATUS -eq 0 ]" "a restore re-run after the import succeeds (exit $STATUS)"
  check "contains $LOG/calls.log 'fermix service install --home /home/fermix/.fermix [as fermix]' && ! contains $OUT 'Ready to restore'" \
    "a re-run binds and starts the restored home and prints no steps"
}

# A fresh host in the same container: no home, no code, no fixtures left.
fresh_host() {
  rm -rf /home/fermix/.fermix /run/fermix/* "$FIXTURES/phases" "$FIXTURES/systemctl-fails"
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
}

ubuntu() {
  cat >/etc/os-release <<'EOF'
PRETTY_NAME="Ubuntu 24.04.3 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
ID=ubuntu
ID_LIKE=debian
EOF
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
}

# The real package and the real browser: what the engine's launcher starts
# (`chromium` on its PATH, headless, the launcher's Linux flags), as the engine
# account, with no --no-sandbox, so Chromium's own sandbox has to come up.
chromium() {
  apt-get -qq update >/dev/null
  apt-get -qq -y install --no-install-recommends nftables >/dev/null 2>&1
  install_stubs
  run_first_boot env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -eq 0 ]" "a Debian host installs the distribution's Chromium with the real apt-get (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || tail -n 20 "$OUT" | sed 's/^/    /'
  check "dpkg-query -W -f='\${Status}' chromium | grep -q 'install ok installed'" "the chromium package is installed"
  check "[ \"\$(runuser -u fermix -- env -i PATH=/usr/bin:/bin sh -c 'command -v chromium')\" = /usr/bin/chromium ]" \
    "the engine account finds chromium on its PATH, where the launcher looks"
  profile=/home/fermix/.fermix/browser/profiles/fermix_headless
  runuser -u fermix -- mkdir -p "$profile"
  set +e
  runuser -u fermix -- env -i HOME=/home/fermix USER=fermix LOGNAME=fermix PATH=/usr/bin:/bin LANG=C.UTF-8 \
    chromium --headless=new --disable-dev-shm-usage --no-first-run --no-default-browser-check \
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

CODE=$(make_code "invented-enrollment-secret-for-tests-only")
CODE_BODY=${CODE#fxenroll1.}
dash -n "$FIRST_BOOT"
pass "dash parses first-boot.sh"
mkdir -p "$FIXTURES"
case "$SCENARIO" in
  existing-host) setup_tools; existing_host ;;
  restore) setup_tools; restore ;;
  failures) setup_tools; failures ;;
  ubuntu) setup_tools; ubuntu ;;
  chromium) chromium ;;
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
