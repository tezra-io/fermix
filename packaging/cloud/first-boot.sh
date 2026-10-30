#!/bin/sh
# Fermix Always On: first boot of a server that becomes the owner's primary.
#
# Runs once as root. Cloud-init user data runs it with the enrollment code in
# FERMIX_ENROLL_CODE; on an existing Debian or Ubuntu host it asks for the code
# on the terminal, without echo:
#
#   curl -fsSL https://fermix.ai/always-on | sudo sh
#
# With --restore it takes no code and enrolls nothing: it prepares the same
# server and prints the steps that restore a snapshot onto it.
#
# Options: --restore, --snapshot-bucket NAME --snapshot-region REGION
# (together). It never prints the code, never logs it
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
UNIT_DIR=/etc/systemd/system
INSTALL_URL=https://fermix.ai/install
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
RESTORE=0
SNAPSHOT_BUCKET=""
SNAPSHOT_REGION=""
HOME_EXISTS=0
ENGINE_UID=""
APT_UPDATED=0
WORK=""
TTY_STATE=""

# One sentence and a non-zero exit.
fail() {
  printf 'fermix always-on: %s\n' "$1" >&2
  exit 1
}

say() {
  printf '==> %s\n' "$1"
}

finish() {
  if [ -n "$TTY_STATE" ]; then stty "$TTY_STATE" </dev/tty 2>/dev/null || true; fi
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
      --snapshot-bucket | --snapshot-region)
        [ $# -ge 2 ] || fail "$1 needs a value."
        case "$1" in
          --snapshot-bucket) SNAPSHOT_BUCKET=$2 ;;
          --snapshot-region) SNAPSHOT_REGION=$2 ;;
        esac
        shift 2
        ;;
      *) fail "An option was not recognised. This script takes --restore, --snapshot-bucket and --snapshot-region." ;;
    esac
  done

  if [ -n "$SNAPSHOT_BUCKET" ] || [ -n "$SNAPSHOT_REGION" ]; then
    matches "$SNAPSHOT_BUCKET" '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' ||
      fail "--snapshot-bucket is not an S3 bucket name, or is missing beside --snapshot-region."
    matches "$SNAPSHOT_REGION" '^[a-z0-9][a-z0-9-]{0,31}$' ||
      fail "--snapshot-region is not a region name, or is missing beside --snapshot-bucket."
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

# 5. The engine account writes its candidate home from the code file.
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
  as_engine "$@" || fail "fermix home enroll stopped; its message above says why."
}

# 6. The packaged user service, bound to that home and started.
start_service() {
  say "Starting Fermix as the background service of $ENGINE_USER"
  as_engine service install --home "$FERMIX_HOME_DIR" ||
    fail "fermix service install stopped; its message above says why."
}

# 7. A browser for the agent's tasks. On Debian the distribution's Chromium,
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

# 8. The engine dials the primary from the code; the first boot ends once
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
  say "Ready to restore your home here. In a shell on this server, as an account that may use sudo:"
  if [ -n "$SNAPSHOT_BUCKET" ]; then
    cat <<EOF
  1. Download your newest snapshot from the bucket $SNAPSHOT_BUCKET in
     $SNAPSHOT_REGION (its name sorts last), then copy it onto this server as
     $RESTORE_FILE, owned by $ENGINE_USER:
       sudo install -o $ENGINE_USER -g $ENGINE_USER -m 0600 <the file> $RESTORE_FILE
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
    return 0
  fi
  await_enrollment
  say "Done. Open Always On in Fermix to review this server, then move to it."
}

finish_restore() {
  install_browser
  print_restore_steps
}

main() {
  CODE=${FERMIX_ENROLL_CODE-}
  unset FERMIX_ENROLL_CODE
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
  if [ "$RESTORE" -eq 1 ] && [ "$HOME_EXISTS" -eq 0 ]; then
    finish_restore
  else
    finish_enrollment
  fi
}

main "$@"
