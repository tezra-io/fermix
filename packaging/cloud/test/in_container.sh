#!/bin/sh
# Runs inside a throwaway debian:trixie-slim container started by
# first_boot_test.sh, with packaging/cloud mounted read-only at /cloud, the
# package's systemd units at /linux-systemd, /run on a tmpfs and NET_ADMIN, so
# nft loads the real ruleset. useradd, runuser and nft are real; systemctl,
# loginctl, curl, apt-get and fermix are the stand-ins in stubs/ (in the
# chromium scenario apt-get is the real one). One scenario per container:
#
#   existing-host  refusals, then the code typed at a terminal, the wait for
#                  the primary, then a re-run
#   aws            user data unpacking, the code and the wait handle in the
#                  environment, an instance role, a bucket, the credentials
#                  helper, the success signal, a re-run, then an instance with
#                  no role
#   restore        --restore: no code, no enrollment, the steps printed, the
#                  success signal, a re-run once a home exists
#   failures       each failure the stack is told about, exactly once
#   ubuntu         no Chromium package, and the sentence that says to install one
#   chromium       the distribution's Chromium installed for real and started
#                  headless as the engine account, its own sandbox on
set -eu

SCENARIO=${1:?scenario: existing-host, aws, restore, failures, ubuntu or chromium}
FIRST_BOOT=/cloud/first-boot.sh
TEMPLATE=/cloud/aws/fermix-always-on.yaml
LOG=/var/log/fermix-test
FIXTURES=/etc/fermix-test
OUT=/tmp/first-boot.out
FAILURES=0
# An invented wait handle in the shape CloudFormation presigns.
SIGNAL_URL='https://cloudformation-waitcondition-eu-west-1.s3.eu-west-1.amazonaws.com/arn%3Aaws%3Acloudformation%3Aeu-west-1%3A210987654321%3Astack/fermix-always-on/0a1b2c3d/FirstBootHandle?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20261028T000000Z&X-Amz-SignedHeaders=host&X-Amz-Expires=86399&X-Amz-Credential=AKIAINVENTEDEXAMPLE%2F20261028%2Feu-west-1%2Fs3%2Faws4_request&X-Amz-Signature=0123456789abcdef'

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
  rm -f "$LOG/signals"
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

# The one signal the stack's wait handle received, exactly.
signaled_once() {
  printf '{"Status":"%s","Reason":"%s","UniqueId":"fermix-first-boot","Data":"%s"}\n' "$1" "$2" "$1" \
    >/tmp/signal.expected
  if [ -f "$LOG/signals" ] && cmp -s "$LOG/signals" /tmp/signal.expected &&
    [ "$(grep -c "curl PUT $SIGNAL_URL" "$LOG/calls.log")" -eq 1 ]; then
    pass "$3"
  else
    fail "$3"
    printf '    expected: %s\n' "$(cat /tmp/signal.expected)"
    if [ -f "$LOG/signals" ]; then sed 's/^/    got:      /' "$LOG/signals"; else echo "    got: no signal"; fi
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
  refuses "an unknown option, without echoing it (here the code itself)" "An option was not recognised. This script takes --restore, --snapshot-bucket, --snapshot-region and --shell-access." \
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
  for name in FERMIX_ENROLL_CODE FERMIX_SIGNAL_URL; do
    check "! grep -qx $name $LOG/env-home-enroll" "fermix home enroll does not have $name in its environment"
  done
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
  find /etc/fermix /etc/systemd/system /etc/tmpfiles.d/fermix-always-on.conf /usr/local/lib/fermix-always-on \
    /run/fermix -type f 2>/dev/null | sort | xargs sha256sum >"$1"
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
curl PUT http://169.254.169.254/latest/api/token
fermix home enroll --code-file /run/fermix/enroll.code [as fermix]
fermix service install --home /home/fermix/.fermix [as fermix]
apt-get -qq -y install --no-install-recommends chromium
fermix home status --json [as fermix]
fermix home status --json [as fermix]
EOF
  check "cmp -s $LOG/calls.log /tmp/calls.expected" \
    "the steps run in order, enrolling with no instance facts and no bucket, then waiting until the primary accepts it"
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
  check "[ ! -e $LOG/signals ]" "with no wait handle it signals nothing"
  check "[ -x /usr/bin/chromium ]" "Debian gets the distribution's Chromium"
  check "[ ! -e /run/fermix/instance.json ] && [ ! -e /etc/systemd/system/fermix-aws-credentials.timer ]" \
    "a host with no metadata service gets no instance facts and no credentials timer"
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
}

# The user data the template runs, minus the parameter line: the literal
# header and the embedded part, de-indented exactly as YAML reads them.
check_user_data() {
  awk '
    /^ *- - \|$/ && !started { started = 1; next }
    started && /# >>> first-boot.sh/ { next }
    started && /# <<< first-boot.sh/ { exit }
    started && /^ *- \|$/ { next }
    started { sub(/^                  /, ""); print }
  ' "$TEMPLATE" >/tmp/user-data.sh
  check "head -n 1 /tmp/user-data.sh | grep -qx '#!/bin/sh'" "the template's user data is a shell script"
  # EC2 takes at most 16384 bytes of user data. The last line adds at most
  # 3600: its fixed text, the wait handle's presigned address (well under
  # 1000), a 2048-character code, a 63-character bucket, a region and
  # --shell-access.
  check "[ \$((\$(wc -c </tmp/user-data.sh) + 3600)) -le 16384 ]" \
    "the user data fits EC2's 16 KB with the longest code, wait handle and bucket"
  rm -rf /usr/local/lib/fermix-always-on
  check "sh /tmp/user-data.sh" "the user data unpacks the script and its SHA-256 check passes"
  check "cmp -s /usr/local/lib/fermix-always-on/first-boot.sh $FIRST_BOOT" \
    "the template carries first-boot.sh byte for byte (else run packaging/cloud/aws/embed-first-boot.sh)"
  # The ${...} are CloudFormation's substitutions, not the shell's.
  cat >/tmp/user-data-enroll <<'LINE'
FERMIX_SIGNAL_URL='${FirstBootHandle}' FERMIX_ENROLL_CODE='${EnrollmentCode}' sh /usr/local/lib/fermix-always-on/first-boot.sh --snapshot-bucket '${SnapshotBucket}' --snapshot-region '${AWS::Region}'${ShellOption}
LINE
  cat >/tmp/user-data-restore <<'LINE'
FERMIX_SIGNAL_URL='${FirstBootHandle}' sh /usr/local/lib/fermix-always-on/first-boot.sh --restore --snapshot-bucket '${ExistingSnapshotBucket}' --snapshot-region '${AWS::Region}'${ShellOption}
LINE
  check "grep -qFf /tmp/user-data-enroll $TEMPLATE" \
    "enroll mode passes the wait handle and the code in the environment and the bucket and region as options"
  check "grep -qFf /tmp/user-data-restore $TEMPLATE" \
    "restore mode passes the wait handle in the environment, no code, and the lost server's bucket"
  rm -rf /usr/local/lib/fermix-always-on
}

aws_fixtures() {
  imds=$FIXTURES/imds
  mkdir -p "$imds/latest/meta-data/iam/security-credentials" "$imds/latest/meta-data/placement" \
    "$imds/latest/dynamic/instance-identity"
  printf 'INVENTED-IMDS-TOKEN' >"$imds/token"
  printf 'fermix-always-on-InstanceRole-INVENTED\n' >"$imds/latest/meta-data/iam/security-credentials/_index"
  credentials 2026-10-27T21:00:00Z
  printf 'i-0a1b2c3d4e5f60718' >"$imds/latest/meta-data/instance-id"
  printf 'eu-west-1' >"$imds/latest/meta-data/placement/region"
  cat >"$imds/latest/dynamic/instance-identity/document" <<'EOF'
{
  "accountId" : "210987654321",
  "architecture" : "arm64",
  "instanceId" : "i-0a1b2c3d4e5f60718",
  "region" : "eu-west-1"
}
EOF
}

credentials() {
  cat >"$FIXTURES/imds/latest/meta-data/iam/security-credentials/fermix-always-on-InstanceRole-INVENTED" <<EOF
{
  "Code" : "Success",
  "LastUpdated" : "2026-10-27T15:00:00Z",
  "Type" : "AWS-HMAC",
  "AccessKeyId" : "ASIAINVENTEDEXAMPLE1",
  "SecretAccessKey" : "invented-secret-access-key-for-tests-only",
  "Token" : "invented-session-token-for-tests-only",
  "Expiration" : "$1"
}
EOF
}

check_credentials() {
  file=/run/fermix/aws-credentials.json
  role=$FIXTURES/imds/latest/meta-data/iam/security-credentials/fermix-always-on-InstanceRole-INVENTED
  check "[ \"\$(mode_owner $file)\" = '600 fermix:fermix' ]" "the role's credentials are 0600 and the engine account's"
  check "cmp -s $file $role" "they are the metadata service's answer, unchanged"
  for unit in fermix-aws-credentials.service fermix-aws-credentials.timer; do
    check "[ \"\$(mode_owner /etc/systemd/system/$unit)\" = '644 root:root' ]" "$unit is root's"
  done
  check "contains /etc/systemd/system/fermix-aws-credentials.timer 'OnUnitActiveSec=15min'" "the timer refreshes every 15 minutes"
  check "contains /etc/systemd/system/fermix-aws-credentials.timer 'OnBootSec=10s'" "and at boot"
  check "[ \"\$(mode_owner /usr/local/lib/fermix-always-on/aws-credentials)\" = '755 root:root' ]" "the helper is root's"

  credentials 2026-10-27T22:00:00Z
  check "/usr/local/lib/fermix-always-on/aws-credentials" "the helper runs again"
  check "cmp -s $file $role" "a later run replaces them with the newer credentials"
  printf 'untouched\n' >/tmp/victim
  rm -f "$file"
  runuser -u fermix -- ln -s /tmp/victim "$file"
  check "/usr/local/lib/fermix-always-on/aws-credentials" "the helper runs over a link the engine account placed"
  check "[ ! -L $file ] && cmp -s $file $role && [ \"\$(cat /tmp/victim)\" = untouched ]" \
    "it replaces the link and never writes through it"
  check "[ -z \"\$(find /run -maxdepth 1 -name 'fermix-credentials.*')\" ]" "the helper leaves no work directory behind"
}

aws() {
  check_user_data
  aws_fixtures
  run_first_boot env FERMIX_SIGNAL_URL="$SIGNAL_URL" FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" \
    --snapshot-bucket fermix-snapshots-invented --snapshot-region eu-west-1
  check "[ $STATUS -eq 0 ]" "an AWS instance with a role enrolls from user data (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
  ENGINE_UID=$(id -u fermix)
  code_absent_everywhere
  check "! contains $OUT X-Amz-Signature" "the wait handle's address appears in no output"
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
curl PUT http://169.254.169.254/latest/api/token
curl GET http://169.254.169.254/latest/meta-data/iam/security-credentials/
systemctl daemon-reload
systemctl start fermix-aws-credentials.service
curl PUT http://169.254.169.254/latest/api/token
curl GET http://169.254.169.254/latest/meta-data/iam/security-credentials/
curl GET http://169.254.169.254/latest/meta-data/iam/security-credentials/fermix-always-on-InstanceRole-INVENTED
systemctl enable --now fermix-aws-credentials.timer
curl GET http://169.254.169.254/latest/meta-data/instance-id
curl GET http://169.254.169.254/latest/meta-data/placement/region
curl GET http://169.254.169.254/latest/dynamic/instance-identity/document
fermix home enroll --code-file /run/fermix/enroll.code --snapshot-bucket fermix-snapshots-invented --snapshot-region eu-west-1 --instance-file /run/fermix/instance.json [as fermix]
fermix service install --home /home/fermix/.fermix [as fermix]
apt-get -qq -y install --no-install-recommends chromium
fermix home status --json [as fermix]
curl PUT $SIGNAL_URL
EOF
  check "cmp -s $LOG/calls.log /tmp/calls.expected" \
    "the steps run in order, with the role, the instance facts, the bucket, Chromium and the wait, then one signal"
  cmp -s "$LOG/calls.log" /tmp/calls.expected || diff /tmp/calls.expected "$LOG/calls.log" | sed 's/^/    /' || true
  signaled_once SUCCESS "This server enrolled with your primary; open Always On in Fermix to move to it." \
    "the stack hears SUCCESS once, after the primary accepted the server"
  check "contains $OUT 'Done. Open Always On in Fermix, check that it shows the instance i-0a1b2c3d4e5f60718, then move to this server.'" \
    "it ends by naming the instance id to compare"
  check "[ \"\$(cat /run/fermix/instance.json)\" = '{\"provider\": \"aws\", \"instance_id\": \"i-0a1b2c3d4e5f60718\", \"region\": \"eu-west-1\", \"account_id\": \"210987654321\"}' ]" \
    "the instance facts are written for fermix home enroll"
  check "[ \"\$(mode_owner /run/fermix/instance.json)\" = '600 fermix:fermix' ]" "the instance facts are the engine account's"
  check_account
  check_code_file
  check_metadata_block
  check_credentials
  check_package_unit

  snapshot_files /tmp/state.first
  run_first_boot sh "$FIRST_BOOT"
  check "[ $STATUS -eq 0 ]" "a re-run on AWS succeeds (exit $STATUS)"
  check "! grep -q 'home enroll' $LOG/calls.log" "a re-run does not enroll again"
  check "[ ! -e $LOG/signals ]" "a re-run without a wait handle signals nothing"
  snapshot_files /tmp/state.second
  check "cmp -s /tmp/state.first /tmp/state.second" "a re-run leaves every file, mode and rule as it was"
  cmp -s /tmp/state.first /tmp/state.second || diff /tmp/state.first /tmp/state.second | sed 's/^/    /' || true

  # The same host with no instance role and no bucket.
  rm -f "$FIXTURES/imds/latest/meta-data/iam/security-credentials/_index"
  rm -rf /home/fermix/.fermix /run/fermix/* /usr/local/lib/fermix-always-on
  rm -f /etc/systemd/system/fermix-aws-credentials.service /etc/systemd/system/fermix-aws-credentials.timer
  run_first_boot env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -eq 0 ]" "an AWS instance with no role enrolls (exit $STATUS)"
  check "contains $OUT 'This instance has no role, so no credentials are handed to Fermix'" "it says there is no role"
  check "[ ! -e /etc/systemd/system/fermix-aws-credentials.timer ] && [ ! -e /run/fermix/aws-credentials.json ]" \
    "an instance with no role gets no credentials timer"
  check "contains $LOG/calls.log 'fermix home enroll --code-file /run/fermix/enroll.code --instance-file /run/fermix/instance.json [as fermix]'" \
    "it still hands over the instance facts"
}

expected_restore_steps() {
  cat <<EOF
==> Ready to restore your home here. In a shell on this server (Session Manager when the stack's ShellAccess is on), as an account that may use sudo:
  1. On a computer with your AWS credentials, find the newest snapshot and make
     a link to it that works for 15 minutes:
       aws s3 ls s3://fermix-snapshots-invented/ --recursive | sort | tail -n 1
       aws s3 presign s3://fermix-snapshots-invented/<the key it lists> --region eu-west-1 --expires-in 900
     Then on this server download it as the account fermix:
       sudo -H -u fermix curl -fsS -o /home/fermix/restore.fxsnap '<the link>'
  2. Restore it; Fermix asks for your recovery passphrase without showing it:
       sudo -H -u fermix env FERMIX_HOME=/home/fermix/.fermix-restore /usr/bin/fermix home import /home/fermix/restore.fxsnap --into /home/fermix/.fermix
  3. Start Fermix from the restored home:
       sudo -H -u fermix env XDG_RUNTIME_DIR=/run/user/$ENGINE_UID /usr/bin/fermix service install --home /home/fermix/.fermix
  4. Remove the downloaded snapshot and the import's own scratch home:
       sudo rm -rf /home/fermix/restore.fxsnap /home/fermix/.fermix-restore
EOF
}

# Until the server can carry an SSM agent, the template refuses a restore
# stack that would come up with no shell to run the restore in: its Rules
# block, as the template spells it.
check_restore_needs_shell() {
  awk '
    /^  RestoreNeedsShellAccess:$/ { found = 1 }
    found && (/^[^ ]/ || /^  [A-Za-z]/) && !/^  RestoreNeedsShellAccess:$/ { exit }
    found && !/^$/ { print }
  ' "$TEMPLATE" >/tmp/restore-rule
  cat >/tmp/restore-rule.expected <<'RULE'
  RestoreNeedsShellAccess:
    RuleCondition: !Equals [!Ref Mode, restore]
    Assertions:
      - Assert: !Equals [!Ref ShellAccess, "true"]
        AssertDescription: >-
          A restore on AWS needs a shell on the server, which the template's
          Debian image cannot give yet (it carries no SSM agent), so restoring
          on AWS is not available in this version. Restore onto a Linux host you
          have a terminal on instead, with the first-boot script's --restore.
RULE
  check "cmp -s /tmp/restore-rule /tmp/restore-rule.expected" \
    "the template refuses a restore stack with no shell, and says to restore on a host with a terminal"
  cmp -s /tmp/restore-rule /tmp/restore-rule.expected ||
    diff /tmp/restore-rule.expected /tmp/restore-rule | sed 's/^/    /' || true
}

restore() {
  check_restore_needs_shell
  aws_fixtures
  refuses "a restore given an enrollment code, without echoing it" \
    "--restore takes no enrollment code: the home comes from a snapshot." \
    env FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --restore

  run_first_boot env FERMIX_SIGNAL_URL="$SIGNAL_URL" sh "$FIRST_BOOT" --restore \
    --snapshot-bucket fermix-snapshots-invented --snapshot-region eu-west-1
  check "[ $STATUS -eq 0 ]" "a restore host is prepared from user data with no code (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
  ENGINE_UID=$(id -u fermix)
  check "! grep -q 'fermix home enroll' $LOG/calls.log && ! grep -q 'fermix service install' $LOG/calls.log" \
    "a restore host neither enrolls nor starts Fermix before the import"
  check "! grep -q 'Enrollment code' $OUT && [ ! -e /run/fermix/enroll.code ] && [ ! -e /home/fermix/.fermix ]" \
    "it asks for no code, writes none, and leaves the home empty for the import"
  for step in 'Blocking the instance metadata address' 'Creating the account fermix' \
    "Handing the instance role's credentials to Fermix" "Writing this instance's facts" \
    'Installing Chromium for the browser tasks'; do
    check "contains $OUT \"==> $step\"" "a restore host gets the same server: $step"
  done
  sed -n '/^==> Ready to restore/,$p' "$OUT" >/tmp/steps
  expected_restore_steps >/tmp/steps.expected
  check "cmp -s /tmp/steps /tmp/steps.expected" "it prints the import steps exactly, with this stack's bucket and region"
  cmp -s /tmp/steps /tmp/steps.expected || diff /tmp/steps.expected /tmp/steps | sed 's/^/    /' || true
  signaled_once SUCCESS "This server is ready for a snapshot to be restored onto it; its system log lists the steps." \
    "the stack hears SUCCESS once, ready for the import"
  check_account
  check_metadata_block
  check_credentials
  check_package_unit

  # A host with no bucket named: the step says to copy the file over.
  rm -f "$LOG/signals"
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
  rm -rf /home/fermix/.fermix /run/fermix/* "$FIXTURES/phases" "$FIXTURES/systemctl-fails" \
    /usr/bin/amazon-ssm-agent
}

failures() {
  aws_fixtures

  run_first_boot env FERMIX_SIGNAL_URL="$SIGNAL_URL" FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT" --bogus
  check "[ $STATUS -ne 0 ] && [ \"\$(cat $LOG/calls.log)\" = \"curl PUT $SIGNAL_URL\" ]" \
    "a refused option runs nothing but the one signal"
  signaled_once FAILURE "An option was not recognised. This script takes --restore, --snapshot-bucket, --snapshot-region and --shell-access." \
    "a refused option fails the stack once, with its sentence"

  run_first_boot env FERMIX_SIGNAL_URL='https://example.net/not-a-wait-handle' FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -ne 0 ] && contains $OUT 'FERMIX_SIGNAL_URL is not the stack' && [ ! -s $LOG/calls.log ] && [ ! -e $LOG/signals ]" \
    "a wait handle that is not an AWS address is refused and never sent to"

  fresh_host
  printf 'enrolling|Enrolling with Invented Mac.\nexpired|The enrollment code expired at 2026-10-28 00:40 UTC; open a new one in Fermix.\n' \
    >"$FIXTURES/phases"
  run_first_boot env FERMIX_SIGNAL_URL="$SIGNAL_URL" FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -ne 0 ] && [ \"\$(grep -c 'fermix home status' $LOG/calls.log)\" -eq 2 ]" \
    "an enrollment the primary ended stops the first boot at the next look"
  signaled_once FAILURE "The enrollment code expired at 2026-10-28 00:40 UTC; open a new one in Fermix." \
    "an expired enrollment fails the stack once, with the server's own sentence"

  fresh_host
  printf 'restart fermix-metadata-block.service\n' >"$FIXTURES/systemctl-fails"
  run_first_boot env FERMIX_SIGNAL_URL="$SIGNAL_URL" FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -eq 1 ] && ! grep -q 'fermix home enroll' $LOG/calls.log" "a step that stops unexpectedly ends the first boot there"
  signaled_once FAILURE "The first boot stopped unexpectedly (exit 1); the console log shows the step it stopped at." \
    "an unexpected stop fails the stack once"

  fresh_host
  rm -f "$FIXTURES/imds/latest/meta-data/instance-id"
  run_first_boot env FERMIX_SIGNAL_URL="$SIGNAL_URL" FERMIX_ENROLL_CODE="$CODE" sh "$FIRST_BOOT"
  check "[ $STATUS -ne 0 ] && [ ! -e /run/fermix/instance.json ] && ! grep -q 'fermix home enroll' $LOG/calls.log" \
    "a metadata service that names no instance id stops the first boot before it enrolls"
  signaled_once FAILURE "The instance metadata service did not answer latest/meta-data/instance-id." \
    "a failure inside a command substitution fails the stack once, with its sentence"
  printf 'i-0a1b2c3d4e5f60718' >"$FIXTURES/imds/latest/meta-data/instance-id"

  fresh_host
  run_first_boot env FERMIX_SIGNAL_URL="$SIGNAL_URL" sh "$FIRST_BOOT" --restore --shell-access
  check "[ $STATUS -ne 0 ] && ! grep -q 'amazon-ssm-agent' $LOG/calls.log" "ShellAccess with no SSM agent stops the first boot"
  signaled_once FAILURE "ShellAccess is on, but this server has no SSM agent (Debian's images carry none), so Session Manager cannot open a shell on it." \
    "ShellAccess with no SSM agent fails the stack once, naming why"

  fresh_host
  printf '#!/bin/sh\nexit 0\n' >/usr/bin/amazon-ssm-agent
  chmod 0755 /usr/bin/amazon-ssm-agent
  run_first_boot env FERMIX_SIGNAL_URL="$SIGNAL_URL" sh "$FIRST_BOOT" --restore --shell-access
  check "[ $STATUS -eq 0 ] && contains $LOG/calls.log 'systemctl enable --now amazon-ssm-agent.service'" \
    "ShellAccess with an SSM agent turns the agent on"
  signaled_once SUCCESS "This server is ready for a snapshot to be restored onto it; its system log lists the steps." \
    "and the stack hears SUCCESS once"
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
  aws) setup_tools; aws ;;
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
