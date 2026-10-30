#!/bin/sh
# Fermix Always On: first boot of a server that becomes the owner's primary.
#
# Runs once as root. The CloudFormation template runs it from user-data with
# the enrollment code in FERMIX_ENROLL_CODE and the stack's wait handle in
# FERMIX_SIGNAL_URL; on an existing Debian or Ubuntu host it asks for the code
# on the terminal, without echo:
#
#   curl -fsSL https://fermix.ai/always-on | sudo sh
#
# With --restore it takes no code and enrolls nothing: it prepares the same
# server and prints the steps that restore a snapshot onto it.
#
# Options: --restore, --snapshot-bucket NAME --snapshot-region REGION
# (together), --shell-access. It never prints the code, never logs it
# and never puts it on a command line. Run again, it converges on the same
# state; a host whose Fermix home exists is not enrolled again.
set -eu

ENGINE_USER=fermix
# Not /var/lib/fermix: that tree holds the root-owned loader every packaged
# engine executes, and no engine account may own a directory above it.
ACCOUNT_HOME=/home/fermix
FERMIX_HOME_DIR=$ACCOUNT_HOME/.fermix
FERMIX_BIN=/usr/bin/fermix
RUN_DIR=/run/fermix
CODE_FILE=$RUN_DIR/enroll.code
INSTANCE_FILE=$RUN_DIR/instance.json
CREDENTIALS_FILE=$RUN_DIR/aws-credentials.json
LIB_DIR=/usr/local/lib/fermix-always-on
CREDENTIALS_HELPER=$LIB_DIR/aws-credentials
UNIT_DIR=/etc/systemd/system
INSTALL_URL=https://fermix.ai/install
IMDS=http://169.254.169.254
CODE_PREFIX=fxenroll1.
CODE_MIN=42
CODE_MAX=2048
# How long the first boot waits for the primary to accept this server: 60
# looks, 5 s apart. The engine keeps trying after that, until the code expires.
ENROLL_WAIT_TRIES=60
ENROLL_WAIT_SECONDS=5
RESTORE_FILE=$ACCOUNT_HOME/restore.fxsnap
# The import runs from a home of its own, so nothing it writes as it starts
# lands in the empty home it restores into.
RESTORE_CLI_HOME=$ACCOUNT_HOME/.fermix-restore

CODE=""
SIGNAL_URL=""
SIGNALED=0
FAILURE_REASON=""
RESTORE=0
SHELL_ACCESS=0
SNAPSHOT_BUCKET=""
SNAPSHOT_REGION=""
HOME_EXISTS=0
AWS=0
HAS_ROLE=0
IMDS_TOKEN=""
INSTANCE_ID=""
ENGINE_UID=""
APT_UPDATED=0
WORK=""
TTY_STATE=""

# One sentence and a non-zero exit. A command substitution runs in a subshell,
# which keeps no global, so the sentence is also left in the work directory
# for finish to tell the stack.
fail() {
  FAILURE_REASON=$1
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then printf '%s\n' "$1" >"$WORK/failure"; fi
  printf 'fermix always-on: %s\n' "$1" >&2
  exit 1
}

say() {
  printf '==> %s\n' "$1"
}

# Tells the stack's wait condition how the first boot ended, once: SUCCESS, or
# FAILURE with the sentence, which then fails the stack and shows as its
# reason. Without a wait handle (an existing host) it does nothing.
signal() {
  if [ -z "$SIGNAL_URL" ] || [ "$SIGNALED" -eq 1 ]; then return 0; fi
  SIGNALED=1
  reason=$(printf '%s' "$2" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-1000)
  printf '{"Status":"%s","Reason":"%s","UniqueId":"fermix-first-boot","Data":"%s"}' "$1" "$reason" "$1" |
    curl -fsS --retry 3 --max-time 30 -X PUT -H 'Content-Type:' --data-binary @- "$SIGNAL_URL" >/dev/null ||
    printf 'fermix always-on: the stack could not be told how the first boot ended; it fails once its wait runs out.\n' >&2
}

failure_reason() {
  if [ -n "$FAILURE_REASON" ]; then
    printf '%s' "$FAILURE_REASON"
  elif [ -n "$WORK" ] && [ -s "$WORK/failure" ]; then
    head -n 1 "$WORK/failure"
  else
    printf 'The first boot stopped unexpectedly (exit %s); the console log shows the step it stopped at.' "$1"
  fi
}

finish() {
  status=$?
  if [ -n "$TTY_STATE" ]; then stty "$TTY_STATE" </dev/tty 2>/dev/null || true; fi
  if [ "$status" -ne 0 ]; then signal FAILURE "$(failure_reason "$status")"; fi
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}

# Whole-line match of one value against an extended regular expression.
matches() {
  case "$1" in *'
'*) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eq "$2"
}

# Option values are never echoed back: a code pasted in the wrong place must
# not reach the console log.
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --restore) RESTORE=1; shift ;;
      --shell-access) SHELL_ACCESS=1; shift ;;
      --snapshot-bucket | --snapshot-region)
        [ $# -ge 2 ] || fail "$1 needs a value."
        case "$1" in
          --snapshot-bucket) SNAPSHOT_BUCKET=$2 ;;
          --snapshot-region) SNAPSHOT_REGION=$2 ;;
        esac
        shift 2
        ;;
      *) fail "An option was not recognised. This script takes --restore, --snapshot-bucket, --snapshot-region and --shell-access." ;;
    esac
  done

  if [ -n "$SNAPSHOT_BUCKET" ] || [ -n "$SNAPSHOT_REGION" ]; then
    matches "$SNAPSHOT_BUCKET" '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' ||
      fail "--snapshot-bucket is not an S3 bucket name, or is missing beside --snapshot-region."
    matches "$SNAPSHOT_REGION" '^[a-z0-9][a-z0-9-]{0,31}$' ||
      fail "--snapshot-region is not a region name, or is missing beside --snapshot-bucket."
  fi
}

# The wait handle is a presigned AWS address. One that is not is dropped
# before anything is sent to it, then refused.
check_signal_url() {
  [ -n "$SIGNAL_URL" ] || return 0
  if ! matches "$SIGNAL_URL" '^https://[a-z0-9.-]+\.amazonaws\.com(\.cn)?/[A-Za-z0-9%._~/?&=+-]+$'; then
    SIGNAL_URL=""
    fail "FERMIX_SIGNAL_URL is not the stack's wait handle address."
  fi
}

os_field() {
  sed -n "s/^$1=//p" /etc/os-release | head -n 1 | sed "s/^[\"']//; s/[\"']\$//"
}

check_host() {
  [ "$(id -u)" -eq 0 ] || fail "Run this as root: curl -fsSL https://fermix.ai/always-on | sudo sh"
  [ -r /etc/os-release ] ||
    fail "This host has no /etc/os-release. Fermix Always On supports Debian 12, Debian 13 and Ubuntu 24.04."
  case "$(os_field ID) $(os_field VERSION_ID)" in
    "debian 12" | "debian 13" | "ubuntu 24.04") ;;
    *) fail "This host runs $(os_field PRETTY_NAME). Fermix Always On supports Debian 12, Debian 13 and Ubuntu 24.04." ;;
  esac
  case "$(uname -m)" in
    aarch64 | x86_64) ;;
    *) fail "This host is $(uname -m). Fermix Always On supports arm64 and x86_64." ;;
  esac
  [ "$(stat -f -c %T /run)" = tmpfs ] ||
    fail "/run is not a tmpfs, so the enrollment code would be written to disk."
}

check_code() {
  case "$CODE" in
    "$CODE_PREFIX"*) ;;
    *) fail "That is not a Fermix enrollment code, which starts with $CODE_PREFIX Open a new one in Fermix and run this again." ;;
  esac
  case "${CODE#"$CODE_PREFIX"}" in
    *[!A-Za-z0-9_-]*) fail "The enrollment code holds a character no code has. Copy it again from Fermix." ;;
  esac
  if [ "${#CODE}" -lt "$CODE_MIN" ] || [ "${#CODE}" -gt "$CODE_MAX" ]; then
    fail "The enrollment code is not between $CODE_MIN and $CODE_MAX characters long. Copy it again from Fermix."
  fi
}

read_code() {
  if [ -z "$CODE" ]; then
    (: </dev/tty) 2>/dev/null ||
      fail "No enrollment code: run this in a terminal, which asks for it, or pass it in FERMIX_ENROLL_CODE."
    TTY_STATE=$(stty -g </dev/tty)
    stty -echo </dev/tty
    printf 'Enrollment code from Fermix (it is not shown as you type): ' >/dev/tty
    read -r CODE </dev/tty || CODE=""
    stty "$TTY_STATE" </dev/tty
    TTY_STATE=""
    printf '\n' >/dev/tty
  fi
  [ -n "$CODE" ] || fail "No enrollment code was entered."
  check_code
}

# Writes stdin to a root-owned file with MODE, replacing it whole.
write_file() {
  cat >"$WORK/incoming"
  chmod "$2" "$WORK/incoming"
  mv -fT "$WORK/incoming" "$1"
}

# Hands a file root prepared in its own directory to the engine account.
# rename(2) never follows a link at the destination, so nothing the engine
# account placed in its run directory can redirect root's write.
publish() {
  chmod 0600 "$1"
  chown "$ENGINE_USER:$ENGINE_USER" "$1"
  mv -fT "$1" "$2"
}

apt_install() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    apt-get -qq update </dev/null || fail "apt-get update failed. Check this host's package sources and network."
    APT_UPDATED=1
  fi
  apt-get -qq -y install --no-install-recommends "$@" </dev/null ||
    fail "apt-get could not install $*."
}

as_engine() {
  runuser -u "$ENGINE_USER" -- env -i HOME="$ACCOUNT_HOME" USER="$ENGINE_USER" \
    LOGNAME="$ENGINE_USER" SHELL=/usr/sbin/nologin PATH=/usr/bin:/bin LANG=C.UTF-8 \
    XDG_RUNTIME_DIR="/run/user/$ENGINE_UID" FERMIX_HOME="$FERMIX_HOME_DIR" \
    "$FERMIX_BIN" "$@" </dev/null
}

imds_get() {
  curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "$IMDS/$1" ||
    fail "The instance metadata service did not answer $1."
}

prepare_run_dir() {
  mkdir -p "$RUN_DIR"
  chmod 0700 "$RUN_DIR"
}

# 1. The code goes to tmpfs, root's alone until the engine account exists.
write_code_file() {
  say "Writing the enrollment code to $CODE_FILE, in memory only"
  prepare_run_dir
  printf '%s\n' "$CODE" >"$WORK/enroll.code"
  CODE=""
  chmod 0600 "$WORK/enroll.code"
  mv -fT "$WORK/enroll.code" "$CODE_FILE"
}

# 2. Only root reaches the instance metadata service, from now and at every
# boot, before any account's services start. Both the IPv4 address every
# cloud uses and the IPv6 one some offer are blocked, as the engine's own
# service unit blocks them. The rule matches what the
# host's own processes send; a container's packets take the forward path and
# would pass it, which is why this server runs none (Fermix's Linux sandbox is
# Landlock, not a container).
block_metadata() {
  say "Blocking the instance metadata address for every account but root"
  apt_install nftables
  install -d -m 0755 /etc/fermix
  write_file /etc/fermix/metadata-block.nft 0644 <<'EOF'
# Fermix Always On: the instance metadata service answers root only. Loaded
# by fermix-metadata-block.service; replacing the table keeps a reload whole.
table inet fermix_metadata
delete table inet fermix_metadata
table inet fermix_metadata {
	chain output {
		type filter hook output priority filter; policy accept;
		ip daddr 169.254.169.254 meta skuid != 0 drop
		ip6 daddr fd00:ec2::254 meta skuid != 0 drop
	}
}
EOF
  # nftables.service flushes the whole ruleset when it starts or reloads, so
  # this unit follows it and loads the block again.
  write_file "$UNIT_DIR/fermix-metadata-block.service" 0644 <<'EOF'
[Unit]
Description=Fermix: block the instance metadata address for every account but root
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target shutdown.target
After=nftables.service
PartOf=nftables.service
ReloadPropagatedFrom=nftables.service
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/fermix/metadata-block.nft
ExecReload=/usr/sbin/nft -f /etc/fermix/metadata-block.nft

[Install]
WantedBy=sysinit.target
EOF
  systemctl daemon-reload
  systemctl enable fermix-metadata-block.service
  systemctl restart fermix-metadata-block.service
  nft list table inet fermix_metadata >/dev/null 2>&1 ||
    fail "The metadata block did not load: nft lists no table inet fermix_metadata."
}

# 3. The signed Linux package, through the same installer every host uses.
install_fermix() {
  say "Installing Fermix with $INSTALL_URL"
  apt_install ca-certificates curl
  curl -fsSL --proto '=https' "$INSTALL_URL" -o "$WORK/install.sh" ||
    fail "Could not download the Fermix installer from $INSTALL_URL."
  sh "$WORK/install.sh" --no-setup </dev/null || fail "The Fermix installer stopped; its message above says why."
  [ -x "$FERMIX_BIN" ] || fail "The installer finished, but $FERMIX_BIN is not there."
}

# 4. The engine account: no login, its own lingering service manager, and a
# user manager that refuses to start while the metadata block is missing.
create_engine_user() {
  say "Creating the account $ENGINE_USER, which runs Fermix and cannot log in"
  if getent passwd "$ENGINE_USER" >/dev/null; then
    home=$(getent passwd "$ENGINE_USER" | cut -d: -f6)
    [ "$home" = "$ACCOUNT_HOME" ] ||
      fail "An account named $ENGINE_USER already exists with its home at $home; Fermix Always On needs it at $ACCOUNT_HOME."
  else
    useradd --create-home --home-dir "$ACCOUNT_HOME" --shell /usr/sbin/nologin \
      --user-group --comment "Fermix engine" "$ENGINE_USER"
  fi
  chmod 0700 "$ACCOUNT_HOME"
  ENGINE_UID=$(id -u "$ENGINE_USER")

  prepare_run_dir
  chown -h "$ENGINE_USER:$ENGINE_USER" "$RUN_DIR"
  if [ -e "$CODE_FILE" ]; then chown -h "$ENGINE_USER:$ENGINE_USER" "$CODE_FILE"; fi
  install -d -m 0755 /etc/tmpfiles.d
  write_file /etc/tmpfiles.d/fermix-always-on.conf 0644 <<EOF
d $RUN_DIR 0700 $ENGINE_USER $ENGINE_USER -
EOF
  install -d -m 0755 "$UNIT_DIR/user@$ENGINE_UID.service.d"
  write_file "$UNIT_DIR/user@$ENGINE_UID.service.d/fermix-metadata-block.conf" 0644 <<'EOF'
[Unit]
Wants=fermix-metadata-block.service
After=fermix-metadata-block.service

[Service]
ExecStartPre=+/usr/sbin/nft list table inet fermix_metadata
EOF
  systemctl daemon-reload
  loginctl enable-linger "$ENGINE_USER"
  systemctl start "user@$ENGINE_UID.service"
}

detect_aws() {
  IMDS_TOKEN=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
    --connect-timeout 2 --max-time 5 "$IMDS/latest/api/token" 2>/dev/null) || IMDS_TOKEN=""
  [ -n "$IMDS_TOKEN" ] || return 0
  AWS=1
  status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "$IMDS/latest/meta-data/iam/security-credentials/") ||
    fail "The instance metadata service did not say whether this instance has a role."
  case "$status" in
    200) HAS_ROLE=1 ;;
    404) HAS_ROLE=0 ;;
    *) fail "The instance metadata service answered $status when asked for this instance's role." ;;
  esac
}

# 5. Root fetches the role's credentials, since the engine cannot reach the
# metadata address, and hands them over in the shape the service answers.
install_credentials_timer() {
  if [ "$HAS_ROLE" -ne 1 ]; then
    if [ "$AWS" -eq 1 ]; then say "This instance has no role, so no credentials are handed to Fermix"; fi
    return 0
  fi
  say "Handing the instance role's credentials to Fermix every 15 minutes"
  install -d -m 0755 "$LIB_DIR"
  write_file "$CREDENTIALS_HELPER" 0755 <<'EOF'
#!/bin/sh
# Fermix Always On: writes the instance role's credentials to
# /run/fermix/aws-credentials.json for the engine account
# (fermix-aws-credentials.service). Never prints them.
set -eu
umask 077
imds=http://169.254.169.254
work=""
fail() {
  printf 'fermix-aws-credentials: %s\n' "$1" >&2
  exit 1
}
trap 'if [ -n "$work" ]; then rm -rf "$work"; fi' EXIT
[ -d /run/fermix ] || fail "/run/fermix is missing; systemd-tmpfiles creates it at boot."
work=$(mktemp -d /run/fermix-credentials.XXXXXX)
token=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
  --connect-timeout 2 --max-time 10 --retry 3 "$imds/latest/api/token") ||
  fail "The instance metadata service gave no session token."
get() {
  curl -fsS --max-time 10 --retry 3 -H "X-aws-ec2-metadata-token: $token" "$@"
}
role=$(get "$imds/latest/meta-data/iam/security-credentials/") ||
  fail "The instance metadata service names no role for this instance."
role=$(printf '%s\n' "$role" | head -n 1)
case "$role" in
  "" | *[!A-Za-z0-9+=,.@_-]*) fail "The instance metadata service named a role IAM would not." ;;
esac
get -o "$work/credentials.json" "$imds/latest/meta-data/iam/security-credentials/$role" ||
  fail "The instance metadata service gave no credentials for the role $role."
grep -Eq '"Code"[[:space:]]*:[[:space:]]*"Success"' "$work/credentials.json" ||
  fail "The instance metadata service did not answer Success for the role $role."
for field in AccessKeyId SecretAccessKey Token Expiration; do
  grep -q "\"$field\"" "$work/credentials.json" ||
    fail "The credentials for the role $role carry no $field."
done
chown fermix:fermix "$work/credentials.json"
chmod 0600 "$work/credentials.json"
mv -fT "$work/credentials.json" /run/fermix/aws-credentials.json
EOF
  write_file "$UNIT_DIR/fermix-aws-credentials.service" 0644 <<EOF
[Unit]
Description=Fermix: write the instance role's credentials for the engine
Wants=network-online.target
After=network-online.target fermix-metadata-block.service

[Service]
Type=oneshot
ExecStart=$CREDENTIALS_HELPER
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/run
EOF
  write_file "$UNIT_DIR/fermix-aws-credentials.timer" 0644 <<'EOF'
[Unit]
Description=Fermix: refresh the instance role's credentials every 15 minutes

[Timer]
OnBootSec=10s
OnUnitActiveSec=15min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl start fermix-aws-credentials.service
  systemctl enable --now fermix-aws-credentials.timer
  [ -s "$CREDENTIALS_FILE" ] ||
    fail "The credentials service ran but wrote no $CREDENTIALS_FILE; journalctl -u fermix-aws-credentials says why."
}

# 6. The instance's facts, which the owner compares before the move.
write_instance_file() {
  [ "$AWS" -eq 1 ] || return 0
  say "Writing this instance's facts to $INSTANCE_FILE"
  INSTANCE_ID=$(imds_get latest/meta-data/instance-id)
  region=$(imds_get latest/meta-data/placement/region)
  document=$(imds_get latest/dynamic/instance-identity/document)
  account_id=$(printf '%s\n' "$document" | sed -n 's/.*"accountId"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p')
  matches "$INSTANCE_ID" '^i-[0-9a-f]{8,32}$' || fail "The instance metadata service gave no instance id."
  matches "$region" '^[a-z0-9][a-z0-9-]{0,31}$' || fail "The instance metadata service gave no region."
  matches "$account_id" '^[0-9]{12}$' || fail "The instance identity document names no account."
  printf '{"provider": "aws", "instance_id": "%s", "region": "%s", "account_id": "%s"}\n' \
    "$INSTANCE_ID" "$region" "$account_id" >"$WORK/instance.json"
  publish "$WORK/instance.json" "$INSTANCE_FILE"
}

# 7. With the stack's ShellAccess on, the instance role lets Session Manager
# open a shell here, through the SSM agent, for a restore or a repair.
enable_shell_access() {
  [ "$SHELL_ACCESS" -eq 1 ] || return 0
  if [ -x /usr/bin/amazon-ssm-agent ]; then
    unit=amazon-ssm-agent.service
  elif [ -x /snap/amazon-ssm-agent/current/amazon-ssm-agent ]; then
    unit=snap.amazon-ssm-agent.amazon-ssm-agent.service
  else
    fail "ShellAccess is on, but this server has no SSM agent (Debian's images carry none), so Session Manager cannot open a shell on it."
  fi
  say "Letting Session Manager open a shell on this server (ShellAccess)"
  systemctl enable --now "$unit"
}

# 8. The engine account writes its candidate home from the code file.
enroll() {
  if [ "$HOME_EXISTS" -eq 1 ]; then
    say "The Fermix home $FERMIX_HOME_DIR already exists, so this host is not enrolled again"
    return 0
  fi
  say "Enrolling this server with your primary"
  set -- home enroll --code-file "$CODE_FILE"
  if [ -n "$SNAPSHOT_BUCKET" ]; then
    set -- "$@" --snapshot-bucket "$SNAPSHOT_BUCKET" --snapshot-region "$SNAPSHOT_REGION"
  fi
  if [ "$AWS" -eq 1 ]; then set -- "$@" --instance-file "$INSTANCE_FILE"; fi
  as_engine "$@" || fail "fermix home enroll stopped; its message above says why."
}

# 9. The packaged user service, bound to that home and started.
start_service() {
  say "Starting Fermix as the background service of $ENGINE_USER"
  as_engine service install --home "$FERMIX_HOME_DIR" ||
    fail "fermix service install stopped; its message above says why."
}

# 10. A browser for the agent's tasks. On Debian the distribution's Chromium,
# which the engine finds on its PATH and starts headless as the engine account.
# Ubuntu ships Chromium only as a snap.
install_browser() {
  case "$(os_field ID)" in
    debian)
      say "Installing Chromium for the browser tasks Fermix runs"
      apt_install chromium
      [ -x /usr/bin/chromium ] || fail "apt-get installed chromium, but /usr/bin/chromium is not there."
      ;;
    ubuntu)
      say "Ubuntu ships Chromium only as a snap, which Fermix does not use: install a browser by hand (Google Chrome's own package, for example), or browser tasks answer that no Chrome or Chromium is installed."
      ;;
  esac
}

# One field of the candidate's `move` in `fermix home status --json`.
move_field() {
  tr -d '\n' <"$1" | sed -n 's/.*"move": *{\([^}]*\)}.*/\1/p' |
    sed -n 's/.*"'"$2"'": *"\(\([^"\\]\|\\.\)*\)".*/\1/p' | sed 's/\\"/"/g; s/\\\\/\\/g'
}

# 11. The engine dials the primary from the code; the first boot ends once
# the primary accepted this server, refused it, or did not answer.
await_enrollment() {
  say "Waiting for your primary to accept this server"
  tries=0
  while [ "$tries" -lt "$ENROLL_WAIT_TRIES" ]; do
    tries=$((tries + 1))
    as_engine home status --json >"$WORK/home-status.json" ||
      fail "fermix home status stopped; its message above says why."
    case "$(move_field "$WORK/home-status.json" phase)" in
      enrolled | receiving | staged | activating) return 0 ;;
      expired | failed) fail "$(move_field "$WORK/home-status.json" sentence)" ;;
    esac
    sleep "$ENROLL_WAIT_SECONDS"
  done
  fail "Your primary has not accepted this server yet: Fermix keeps trying until the code expires, and Always On on the primary shows this server once it is accepted; check that Fermix runs there with Remote reach on."
}

# The steps that restore the newest snapshot onto this server, exactly.
print_restore_steps() {
  say "Ready to restore your home here. In a shell on this server (Session Manager when the stack's ShellAccess is on), as an account that may use sudo:"
  if [ -n "$SNAPSHOT_BUCKET" ]; then
    cat <<EOF
  1. On a computer with your AWS credentials, find the newest snapshot and make
     a link to it that works for 15 minutes:
       aws s3 ls s3://$SNAPSHOT_BUCKET/ --recursive | sort | tail -n 1
       aws s3 presign s3://$SNAPSHOT_BUCKET/<the key it lists> --region $SNAPSHOT_REGION --expires-in 900
     Then on this server download it as the account $ENGINE_USER:
       sudo -H -u $ENGINE_USER curl -fsS -o $RESTORE_FILE '<the link>'
EOF
  else
    cat <<EOF
  1. Copy your newest snapshot (a .fxsnap file) onto this server as
     $RESTORE_FILE, owned by $ENGINE_USER:
       sudo install -o $ENGINE_USER -g $ENGINE_USER -m 0600 <the file> $RESTORE_FILE
EOF
  fi
  cat <<EOF
  2. Restore it; Fermix asks for your recovery passphrase without showing it:
       sudo -H -u $ENGINE_USER env FERMIX_HOME=$RESTORE_CLI_HOME $FERMIX_BIN home import $RESTORE_FILE --into $FERMIX_HOME_DIR
  3. Start Fermix from the restored home:
       sudo -H -u $ENGINE_USER env XDG_RUNTIME_DIR=/run/user/$ENGINE_UID $FERMIX_BIN service install --home $FERMIX_HOME_DIR
  4. Remove the downloaded snapshot and the import's own scratch home:
       sudo rm -rf $RESTORE_FILE $RESTORE_CLI_HOME
EOF
}

finish_enrollment() {
  enroll
  start_service
  install_browser
  if [ "$HOME_EXISTS" -eq 1 ]; then
    say "Done. Fermix runs from the home it already had."
    signal SUCCESS "This server already holds a Fermix home, which runs again."
    return 0
  fi
  await_enrollment
  if [ -n "$INSTANCE_ID" ]; then
    say "Done. Open Always On in Fermix, check that it shows the instance $INSTANCE_ID, then move to this server."
  else
    say "Done. Open Always On in Fermix to review this server, then move to it."
  fi
  signal SUCCESS "This server enrolled with your primary; open Always On in Fermix to move to it."
}

finish_restore() {
  install_browser
  print_restore_steps
  signal SUCCESS "This server is ready for a snapshot to be restored onto it; its system log lists the steps."
}

main() {
  CODE=${FERMIX_ENROLL_CODE-}
  SIGNAL_URL=${FERMIX_SIGNAL_URL-}
  unset FERMIX_ENROLL_CODE FERMIX_SIGNAL_URL
  umask 077
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  LC_ALL=C
  DEBIAN_FRONTEND=noninteractive
  # needrestart would restart services, cloud-init's among them, mid-run.
  NEEDRESTART_SUSPEND=1
  export PATH LC_ALL DEBIAN_FRONTEND NEEDRESTART_SUSPEND
  cd /
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  check_signal_url
  parse_args "$@"
  check_host
  WORK=$(mktemp -d /run/fermix-always-on.XXXXXX)
  # A first boot often finds unattended upgrades holding the package lock; the
  # installer's apt-get waits for it too.
  printf 'DPkg::Lock::Timeout "600";\n' >"$WORK/apt.conf"
  APT_CONFIG=$WORK/apt.conf
  export APT_CONFIG

  if [ "$RESTORE" -eq 1 ] && [ -n "$CODE" ]; then
    CODE=""
    fail "--restore takes no enrollment code: the home comes from a snapshot."
  fi
  if [ -e "$FERMIX_HOME_DIR" ]; then
    HOME_EXISTS=1
    CODE=""
  elif [ "$RESTORE" -eq 0 ]; then
    read_code
    write_code_file
  fi
  block_metadata
  install_fermix
  create_engine_user
  detect_aws
  install_credentials_timer
  write_instance_file
  enable_shell_access
  if [ "$RESTORE" -eq 1 ] && [ "$HOME_EXISTS" -eq 0 ]; then
    finish_restore
  else
    finish_enrollment
  fi
}

main "$@"
