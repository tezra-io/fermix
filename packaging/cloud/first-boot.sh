#!/bin/sh
# Fermix Always On: first boot of a server that becomes the owner's primary.
#
# Runs once as root. Cloud-init user data runs it with the enrollment code in
# FERMIX_ENROLL_CODE; on an existing Debian 13 or Ubuntu 24.04 host it asks for
# the code on the terminal, without echo:
#
#   curl -fsSL https://fermix.ai/always-on | sudo sh
#
# With --restore it takes no code and enrolls nothing: it prepares the same
# server and prints the steps that restore a snapshot onto it. Either way the
# server gets swap when it has none, and keeps itself up to date: Debian's
# security updates every day, Fermix every night at 04:00 UTC.
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
# The memory guard's swap, for a host with none (Hetzner's images have none):
# memory pressure then slows the server before the kernel stops a process, and
# the engine starts Chromium as the process it stops first. 2 GB until a
# measurement on the smallest server Fermix creates sets the size (M75 §3).
SWAP_FILE=/swapfile
SWAP_SIZE=2G
# Updates: Debian's own through unattended-upgrades, Fermix's through its
# installer, by a root timer every night at 04:00 UTC.
UPGRADES_CONF=/etc/apt/apt.conf.d/21fermix-always-on
UPDATE_SCRIPT=/usr/local/sbin/fermix-update
# Fermix's Linux sandbox holds commands only from Landlock ABI 3 (Linux 6.2);
# on a kernel below it the engine installs and runs but refuses every command.
LANDLOCK_ABI_MIN=3

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

# The Landlock ABI this kernel gives, 0 for none: landlock_create_ruleset
# (syscall 444 on x86_64 and arm64 alike) asked for its version, through the
# perl every Debian and Ubuntu host has (perl-base is essential). The call
# fails, read as none, on a kernel built without Landlock or booted without it
# in its lsm= list.
landlock_abi() {
  perl -e 'my $abi = syscall(444, 0, 0, 1); printf("%d\n", $abi < 0 ? 0 : $abi)'
}

check_host() {
  [ "$(id -u)" -eq 0 ] || fail "Run this as root: curl -fsSL https://fermix.ai/always-on | sudo sh"
  [ -r /etc/os-release ] ||
    fail "This host has no /etc/os-release. Fermix Always On supports Debian 13 and Ubuntu 24.04."
  case "$(os_field ID) $(os_field VERSION_ID)" in
    "debian 13" | "ubuntu 24.04") ;;
    *) fail "This host runs $(os_field PRETTY_NAME). Fermix Always On supports Debian 13 and Ubuntu 24.04." ;;
  esac
  case "$(uname -m)" in
    aarch64 | x86_64) ;;
    *) fail "This host is $(uname -m). Fermix Always On supports arm64 and x86_64." ;;
  esac
  [ "$(stat -f -c %T /run)" = tmpfs ] ||
    fail "/run is not a tmpfs, so the enrollment code would be written to disk."
  abi=$(landlock_abi) || fail "perl could not ask this host's kernel for its Landlock ABI."
  matches "$abi" '^[0-9]+$' || fail "perl answered this host's Landlock ABI with something other than a number."
  [ "$abi" -ge "$LANDLOCK_ABI_MIN" ] ||
    fail "This host's kernel gives Landlock ABI $abi (0 is none) and Fermix's sandbox needs ABI $LANDLOCK_ABI_MIN, so Fermix would run no command here: Fermix Always On needs Linux 6.2 or later with Landlock enabled, as Debian 13 and Ubuntu 24.04 have by default."
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
# boot, before any account's services start: user data, which holds the
# enrollment code, stays readable there for the server's life. Every packet
# from any account but root to a metadata address (169.254.169.254 on most
# clouds, 100.100.100.200 on Alibaba's, fd00:ec2::254 on AWS's IPv6,
# fd20:ce::254 on Google's) is dropped, except DNS (udp and tcp 53) and time
# (udp 123), which some clouds serve from the same address. Those are accepted
# first; an accept only ends this table's chain, whose policy is accept
# anyway, so it opens nothing another firewall closes. The rule matches what
# the host's own processes send; a container's packets take the forward path
# and would pass it, which is why this server runs none (Fermix's Linux
# sandbox is Landlock, not a container).
block_metadata() {
  say "Blocking the instance metadata service for every account but root"
  apt_install nftables
  install -d -m 0755 /etc/fermix
  write_file /etc/fermix/metadata-block.nft 0644 <<'EOF'
# Fermix Always On: the instance metadata addresses answer root only, but for
# DNS and time, which some clouds serve there. Loaded by
# fermix-metadata-block.service; replacing the table keeps a reload whole.
table inet fermix_metadata
delete table inet fermix_metadata
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
  # nftables.service flushes the whole ruleset when it starts or reloads, so
  # this unit follows it and loads the block again.
  write_file "$UNIT_DIR/fermix-metadata-block.service" 0644 <<'EOF'
[Unit]
Description=Fermix: block the instance metadata service for every account but root
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

# 3. Swap for a host that has none. A host with swap of its own keeps it; a
# run again finds this file made, in /etc/fstab and on, and changes nothing.
# The file takes its name only once mkswap has formatted it, so a run cut
# short leaves no half-made swap file under that name.
add_swap() {
  swaps=$(swapon --show=NAME --noheadings) || fail "swapon could not list this host's swap."
  if [ -n "$swaps" ] && ! printf '%s\n' "$swaps" | grep -qxF "$SWAP_FILE"; then
    say "This host has swap of its own, so no swap file is made"
    return 0
  fi
  say "Giving this server $SWAP_SIZE of swap in $SWAP_FILE"
  if [ ! -e "$SWAP_FILE" ]; then
    rm -f "$SWAP_FILE.incoming"
    fallocate -l "$SWAP_SIZE" "$SWAP_FILE.incoming" ||
      fail "Could not reserve $SWAP_SIZE for the swap file $SWAP_FILE. Check the free disk space."
    chmod 0600 "$SWAP_FILE.incoming"
    mkswap "$SWAP_FILE.incoming" >/dev/null || fail "mkswap could not format the swap file $SWAP_FILE."
    mv -fT "$SWAP_FILE.incoming" "$SWAP_FILE"
  fi
  grep -qs "^$SWAP_FILE " /etc/fstab || printf '%s none swap sw 0 0\n' "$SWAP_FILE" >>/etc/fstab
  if [ -z "$swaps" ]; then
    swapon "$SWAP_FILE" || fail "The kernel refused $SWAP_FILE as swap; this host's filesystem may not hold a swap file."
  fi
}

# 4. The signed Linux package, through the same installer every host uses.
install_fermix() {
  say "Installing Fermix with $INSTALL_URL"
  apt_install ca-certificates curl
  curl -fsSL --proto '=https' "$INSTALL_URL" -o "$WORK/install.sh" ||
    fail "Could not download the Fermix installer from $INSTALL_URL."
  sh "$WORK/install.sh" --no-setup </dev/null || fail "The Fermix installer stopped; its message above says why."
  [ -x "$FERMIX_BIN" ] || fail "The installer finished, but $FERMIX_BIN is not there."
}

# Whether apt's effective configuration sets APT::Periodic::$1 to 1.
apt_periodic_on() {
  [ "$(apt-config shell VALUE "APT::Periodic::$1")" = "VALUE='1'" ]
}

# The script fermix-update.timer runs: first boot's account, home, binary and
# installer address, then a fixed body.
write_update_script() {
  install -d -m 0755 "$(dirname "$UPDATE_SCRIPT")"
  {
    cat <<EOF
#!/bin/sh
# Fermix Always On: the nightly update fermix-update.timer runs at 04:00 UTC.
# Written by Fermix's first boot, which writes it again whenever it runs.
set -eu

ENGINE_USER=$ENGINE_USER
ACCOUNT_HOME=$ACCOUNT_HOME
FERMIX_HOME_DIR=$FERMIX_HOME_DIR
FERMIX_BIN=$FERMIX_BIN
INSTALL_URL=$INSTALL_URL
EOF
    cat <<'FERMIX_UPDATE'
REBOOT_FLAG=/run/reboot-required
WORK=""
PHASE=""

# One sentence and a non-zero exit, before anything restarts or reboots.
fail() {
  printf 'fermix update: %s\n' "$1" >&2
  exit 1
}

say() {
  printf '==> %s\n' "$1"
}

finish() {
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}

installed_version() {
  # shellcheck disable=SC2016 # ${Version} is dpkg-query's own format syntax
  dpkg-query -W -f='${Version}' fermix 2>/dev/null ||
    fail "dpkg lists no fermix package on this server, so there is nothing to update."
}

# The installer every host uses, with its sha256 and cosign checks: it installs
# the newest release's package, or nothing when that one is installed. The
# package restarts nothing, so the running engine is untouched until the restart.
update_fermix() {
  curl -fsSL --proto '=https' "$INSTALL_URL" -o "$WORK/install.sh" ||
    fail "Could not download the Fermix installer from $INSTALL_URL, so Fermix was not updated and the engine keeps running."
  sh "$WORK/install.sh" --no-setup </dev/null ||
    fail "The Fermix installer stopped, so the engine keeps running; its message above says why."
}

# A fermix verb as the engine account, with the clean environment first boot
# gives it.
as_engine() {
  uid=$(id -u "$ENGINE_USER")
  runuser -u "$ENGINE_USER" -- env -i HOME="$ACCOUNT_HOME" USER="$ENGINE_USER" \
    LOGNAME="$ENGINE_USER" SHELL=/usr/sbin/nologin PATH=/usr/bin:/bin LANG=C.UTF-8 \
    XDG_RUNTIME_DIR="/run/user/$uid" FERMIX_HOME="$FERMIX_HOME_DIR" \
    "$FERMIX_BIN" "$@" </dev/null
}

# Whether the running engine is older than the installed one: the `alignment`
# `fermix service status --json` publishes, `pending_restart` exactly then. It
# compares what runs with what is installed, so a restart a night skipped or
# failed is still due the next night, and an engine that is not running (a
# restore host before its import) is not started.
restart_due() {
  as_engine service status --json >"$WORK/service-status.json" ||
    fail "fermix service status stopped, so whether the engine runs the installed release is unknown and it keeps running; its message above says why."
  [ "$(tr -d '\n' <"$WORK/service-status.json" |
    sed -n 's/.*"alignment": *"\([a-z_]*\)".*/\1/p')" = pending_restart ]
}

# Whether a move is under way here, read from `fermix home status --json` (with
# Fermix running or not): this server sending its home (requested to undoing)
# or, as a candidate, receiving one (receiving, staged, activating). A restart
# or a reboot then would cut the move short. Sets PHASE.
move_under_way() {
  [ -e "$FERMIX_HOME_DIR" ] || return 1
  as_engine home status --json >"$WORK/home-status.json" ||
    fail "fermix home status stopped, so whether a move is under way is unknown and nothing restarts; its message above says why."
  PHASE=$(tr -d '\n' <"$WORK/home-status.json" | sed -n 's/.*"move": *{\([^}]*\)}.*/\1/p' |
    sed -n 's/.*"phase": *"\([a-z_]*\)".*/\1/p')
  case "$PHASE" in
    requested | streaming | committing | committed | aborting | undoing) return 0 ;;
    receiving | staged | activating) return 0 ;;
  esac
  return 1
}

# The engine account's own `fermix restart`, the restart an owner runs after an
# update: it restarts the service and waits for the new engine to answer.
restart_engine() {
  say "Restarting the engine, which runs an older release than the one installed"
  as_engine restart ||
    fail "Fermix is updated, but fermix restart stopped; its message above says why."
}

# After the update: the restart when the engine is behind, the reboot when an
# update asks for one, neither while a move is under way.
restart_and_reboot() {
  restart=0
  if restart_due; then restart=1; fi
  if [ "$restart" -eq 0 ] && [ ! -e "$REBOOT_FLAG" ]; then
    say "No restart is due and no update asks for a reboot"
    return 0
  fi
  if move_under_way; then
    say "A move is under way on this server ($PHASE), so the restart and the reboot wait for the next night"
    return 0
  fi
  if [ "$restart" -eq 1 ]; then restart_engine; fi
  if [ -e "$REBOOT_FLAG" ]; then
    say "An installed update asks for a reboot ($REBOOT_FLAG), so this server reboots now"
    systemctl reboot || fail "systemctl reboot was refused; the next night tries again."
  fi
}

main() {
  umask 077
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  LC_ALL=C
  DEBIAN_FRONTEND=noninteractive
  NEEDRESTART_SUSPEND=1
  export PATH LC_ALL DEBIAN_FRONTEND NEEDRESTART_SUSPEND
  cd /
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ "$(id -u)" -eq 0 ] || fail "Run this as root, as fermix-update.timer does."
  WORK=$(mktemp -d /run/fermix-update.XXXXXX)
  printf 'DPkg::Lock::Timeout "600";\n' >"$WORK/apt.conf"
  APT_CONFIG=$WORK/apt.conf
  export APT_CONFIG

  before=$(installed_version) || exit 1
  say "Updating Fermix $before through $INSTALL_URL"
  update_fermix
  after=$(installed_version) || exit 1
  if [ "$after" = "$before" ]; then
    say "Fermix $after is the newest release"
  else
    say "Fermix went from $before to $after"
  fi
  restart_and_reboot
}

main "$@"
FERMIX_UPDATE
  } | write_file "$UPDATE_SCRIPT" 0755
}

# 5. Updates, as nobody logs in to this server. Debian's own: unattended-upgrades,
# which the Debian 13 cloud image installs and turns on, installed here when a
# provider's image lacks it, and its two daily switches set in a file of
# Fermix's. Fermix's own: the package comes from the release files, not an apt
# source, so unattended-upgrades never sees it; a root timer runs the
# installer every night at 04:00 UTC, restarts the engine when it runs an
# older release than the one installed and reboots when an update asks for
# it, neither while a move is under way. A run that fails stops before both,
# says why in the journal, and the next night tries again.
schedule_updates() {
  say "Turning on updates: Debian's security updates every day, Fermix every night at 04:00 UTC"
  apt_install unattended-upgrades
  write_file "$UPGRADES_CONF" 0644 <<'EOF'
// Fermix Always On: nobody logs in to this server, so Debian's own updates
// install themselves every day. The nightly fermix-update reboots when one
// asks for it.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  if ! apt_periodic_on Update-Package-Lists || ! apt_periodic_on Unattended-Upgrade; then
    fail "Debian's daily updates stay off: a later apt setting overrides $UPGRADES_CONF (apt-config dump APT::Periodic shows it)."
  fi
  write_update_script
  write_file "$UNIT_DIR/fermix-update.service" 0644 <<EOF
[Unit]
Description=Fermix: update Fermix through its installer, restart it when it is behind, reboot when an update asks
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$UPDATE_SCRIPT
TimeoutStartSec=30min
EOF
  write_file "$UNIT_DIR/fermix-update.timer" 0644 <<'EOF'
[Unit]
Description=Fermix: the nightly update at 04:00 UTC

[Timer]
OnCalendar=*-*-* 04:00:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now fermix-update.timer
}

# 6. The engine account: no login, its own lingering service manager, and a
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

# 7. The engine account writes its candidate home from the code file.
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

# 8. The packaged user service, bound to that home and started.
start_service() {
  say "Starting Fermix as the background service of $ENGINE_USER"
  as_engine service install --home "$FERMIX_HOME_DIR" ||
    fail "fermix service install stopped; its message above says why."
}

# 9. A browser for the agent's tasks. On Debian the distribution's Chromium,
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

# 10. The engine dials the primary from the code; the first boot ends once
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
  add_swap
  install_fermix
  schedule_updates
  create_engine_user
  if [ "$RESTORE" -eq 1 ] && [ "$HOME_EXISTS" -eq 0 ]; then
    finish_restore
  else
    finish_enrollment
  fi
}

main "$@"
