#!/bin/sh
# Fermix Always On: first boot of a server that becomes the owner's primary.
#
# Runs once as root. Cloud-init user data runs it with the enrollment code in
# FERMIX_ENROLL_CODE; on an existing Debian 12, Debian 13 or Ubuntu 24.04 host
# whose kernel gives Landlock ABI 3 it asks for the code on the terminal,
# without echo:
#
#   curl -fsSL https://fermix.ai/install | sudo sh -s -- --always-on
#
# Every release publishes this script, byte for byte, as fermix_always_on.sh;
# the regular installer's --always-on runs that copy once its sha256 matches
# the one fermix.ai lists, with --version naming its release, and passes on
# every other option.
#
# With --restore it takes no code and enrolls nothing: it prepares the same
# server and prints the steps that restore a snapshot onto it. Either way the
# server gets swap when it has none, and keeps itself up to date: Debian's
# security updates every day, Fermix to the newest release that the app of
# each computer keeping its backups carries, within five minutes of its
# publication (the server leads: its computers follow within a window), and
# the reboots updates ask for at 04:00 UTC.
#
# Options: --restore, --snapshot-bucket NAME --snapshot-region REGION
# (together; or the bucket the server's infrastructure set, from
# /etc/fermix/snapshot-destination, which fermix-server-aws's user data writes:
# then the snapshots are signed with the server's instance role through a root
# credentials helper, and flags that name another bucket are refused), --version X (the release to install: the one the computer that
# sets the server up runs; the latest without it), --update-script-only (what
# fermix-update runs after it installs a release: the update script written
# again as this release writes it, and nothing else), --tailscale (join the
# owner's tailnet before enrolling, with the auth key in TS_AUTHKEY or asked
# for on the terminal without echo). It never prints the code or the key,
# never logs them and never puts them on a command line. Run again, it
# converges on the same state. A host whose Fermix home exists is read
# first: a candidate that has not begun to receive its move enrolls again
# with a new code (one whose enrollment is refused, as the code it enrolled
# with is, keeps the enrollment it had and runs again), a home that runs is
# started as it is (and refused when given a code), and any other home is
# refused, with the commands that remove it when the home could be read,
# which the script never runs itself. One already on a tailnet is not
# logged in again.
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
# installer, by root timers every five minutes and every night at 04:00 UTC.
UPGRADES_CONF=/etc/apt/apt.conf.d/21fermix-always-on
UPDATE_SCRIPT=/usr/local/sbin/fermix-update
# Fermix's Linux sandbox holds commands only from Landlock ABI 3 (Linux 6.2);
# on a kernel below it the engine installs and runs but refuses every command.
# This, not the release, decides: Debian 12's own 6.1 gives ABI 2, and a
# Debian 12 host on a 6.2 or later kernel qualifies.
LANDLOCK_ABI_MIN=3
# With --tailscale: Tailscale's own package from its signed repository for
# this release, whose signing key (one key for every release's repository) is
# checked by its fingerprint before apt is given it, at the paths Tailscale's
# own instructions use, so a host set up by them converges. The owner's auth
# key goes only to a file in the work directory, which tailscale up reads
# (--auth-key=file:) and which is removed right after.
TAILSCALE_PKGS=https://pkgs.tailscale.com/stable
TAILSCALE_KEY_FPR=2596A99EAAB33821893C0A79458CA832957F5868
TAILSCALE_KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
TAILSCALE_SOURCE=/etc/apt/sources.list.d/tailscale.list
# How long tailscale up waits for the server to reach the tailnet.
TAILSCALE_UP_TIMEOUT=2m
TS_KEY_PREFIX=tskey-
TS_KEY_MIN=20
TS_KEY_MAX=200
# E1: where the server's infrastructure names its snapshot bucket, and the
# root helper that hands the engine account a one-hour session of the
# snapshot writer role for it, through a directory that account may only
# read. The engine account never reaches the metadata service itself.
SNAPSHOT_DESTINATION=/etc/fermix/snapshot-destination
CREDENTIALS_HELPER=/usr/local/sbin/fermix-snapshot-credentials
CREDENTIALS_DIR=/run/fermix-snapshots

CODE=""
RELEASE=""
RELEASE_GIVEN=0
RESTORE=0
# --update-script-only: the update script (fermix-update) is written again as
# this release writes it, and nothing else runs (update_script_only).
UPDATE_SCRIPT_ONLY=0
SNAPSHOT_BUCKET=""
SNAPSHOT_REGION=""
SNAPSHOT_ROLE_ARN=""
HOME_EXISTS=0
# What an existing home is (read_home): kept as it runs, or a candidate that
# enrolls again with a new code. KEPT_HOME_IS says what a kept home is.
HOME_KEPT=0
KEPT_HOME_IS=""
REENROLL=0
HOME_JSON=""
ENGINE_UID=""
APT_UPDATED=0
WORK=""
TTY_STATE=""
HIDDEN=""
TAILSCALE=0
TS_KEY=""
TS_KEY_FILE=""
TS_ON_TAILNET=0
TS_STATE=""
TS_TAILNET=""
TS_REPO=""

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
      --tailscale) TAILSCALE=1; shift ;;
      --update-script-only) UPDATE_SCRIPT_ONLY=1; shift ;;
      --snapshot-bucket | --snapshot-region | --version)
        [ $# -ge 2 ] || fail "$1 needs a value."
        case "$1" in
          --snapshot-bucket) SNAPSHOT_BUCKET=$2 ;;
          --snapshot-region) SNAPSHOT_REGION=$2 ;;
          --version) RELEASE=$2 RELEASE_GIVEN=1 ;;
        esac
        shift 2
        ;;
      *) fail "An option was not recognised. This script takes --restore, --snapshot-bucket, --snapshot-region, --version and --tailscale." ;;
    esac
  done

  if [ "$UPDATE_SCRIPT_ONLY" -eq 1 ] &&
    { [ "$RESTORE" -eq 1 ] || [ "$TAILSCALE" -eq 1 ] || [ "$RELEASE_GIVEN" -eq 1 ] ||
      [ -n "$SNAPSHOT_BUCKET" ] || [ -n "$SNAPSHOT_REGION" ]; }; then
    fail "--update-script-only takes no other option: it rewrites the update script and nothing else."
  fi

  # A release is a plain MAJOR.MINOR.PATCH, as every release's packages are.
  if [ "$RELEASE_GIVEN" -eq 1 ]; then
    matches "$RELEASE" '^[0-9]+\.[0-9]+\.[0-9]+$' ||
      fail "--version is not a Fermix release, such as 0.17.0."
  fi

  if [ -n "$SNAPSHOT_BUCKET" ] || [ -n "$SNAPSHOT_REGION" ]; then
    matches "$SNAPSHOT_BUCKET" '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' ||
      fail "--snapshot-bucket is not an S3 bucket name, or is missing beside --snapshot-region."
    matches "$SNAPSHOT_REGION" '^[a-z0-9][a-z0-9-]{0,31}$' ||
      fail "--snapshot-region is not a region name, or is missing beside --snapshot-bucket."
  fi

  # A key meant for the tailnet, without the step that uses it.
  if [ "$TAILSCALE" -eq 0 ] && [ -n "$TS_KEY" ]; then
    TS_KEY=""
    fail "TS_AUTHKEY holds a Tailscale auth key, but --tailscale was not given: add --tailscale to join this server to your tailnet, or leave TS_AUTHKEY out."
  fi
}

# The one line KEY=value of the destination file, exactly once.
destination_field() {
  [ "$(grep -c "^$1=" "$SNAPSHOT_DESTINATION")" -eq 1 ] || return 1
  sed -n "s/^$1=//p" "$SNAPSHOT_DESTINATION"
}

# E1: the bucket the server's infrastructure set, read as --snapshot-bucket
# and --snapshot-region are, before anything is installed. Root's file, which
# no other account may change; flags that name another bucket or region are
# refused, so there is one path.
read_snapshot_destination() {
  [ -e "$SNAPSHOT_DESTINATION" ] || return 0
  case "$(stat -c '%u %A' "$SNAPSHOT_DESTINATION")" in
    "0 -rw-r--r--" | "0 -rw-------" | "0 -r--r--r--" | "0 -r--------") ;;
    *) fail "$SNAPSHOT_DESTINATION is not root's alone (owned by root, writable by no other account), so the bucket it names is not used." ;;
  esac
  bucket=$(destination_field bucket) || bucket=""
  matches "$bucket" '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' ||
    fail "$SNAPSHOT_DESTINATION names no S3 bucket on one bucket= line."
  region=$(destination_field region) || region=""
  matches "$region" '^[a-z0-9][a-z0-9-]{0,31}$' ||
    fail "$SNAPSHOT_DESTINATION names no region on one region= line."
  role=$(destination_field role_arn) || role=""
  matches "$role" '^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$' ||
    fail "$SNAPSHOT_DESTINATION names no IAM role on one role_arn= line."
  if [ -n "$SNAPSHOT_BUCKET" ] && { [ "$SNAPSHOT_BUCKET" != "$bucket" ] || [ "$SNAPSHOT_REGION" != "$region" ]; }; then
    fail "--snapshot-bucket and --snapshot-region name another bucket than $SNAPSHOT_DESTINATION, which this server's infrastructure wrote: leave them out to use $bucket in $region."
  fi
  SNAPSHOT_BUCKET=$bucket
  SNAPSHOT_REGION=$region
  SNAPSHOT_ROLE_ARN=$role
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
  # The release it was given, as the installer always gives one, stays in the
  # command, so the copied line installs the desktop's release.
  [ "$(id -u)" -eq 0 ] ||
    fail "Run this as root: curl -fsSL https://fermix.ai/install | sudo sh -s -- --always-on${RELEASE:+ --version $RELEASE}"
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

# One line typed at the terminal without echo, into HIDDEN, after the prompt
# $1.
read_hidden() {
  TTY_STATE=$(stty -g </dev/tty)
  stty -echo </dev/tty
  printf '%s' "$1" >/dev/tty
  read -r HIDDEN </dev/tty || HIDDEN=""
  stty "$TTY_STATE" </dev/tty
  TTY_STATE=""
  printf '\n' >/dev/tty
}

read_code() {
  if [ -z "$CODE" ]; then
    (: </dev/tty) 2>/dev/null ||
      fail "No enrollment code: run this in a terminal, which asks for it, or pass it in FERMIX_ENROLL_CODE."
    read_hidden 'Enrollment code from Fermix (it is not shown as you type): '
    CODE=$HIDDEN
    HIDDEN=""
  fi
  [ -n "$CODE" ] || fail "No enrollment code was entered."
  check_code
}

# An OAuth client secret (tskey-client-) also starts tskey-, but tailscale up
# takes one only with tags of the script's own, which it never passes.
check_tailscale_key() {
  case "$TS_KEY" in
    "${TS_KEY_PREFIX}client-"*) fail "That is a Tailscale OAuth client secret, not an auth key: create an auth key in Tailscale's admin console (Settings, Keys) and run this again." ;;
    "$TS_KEY_PREFIX"*) ;;
    *) fail "That is not a Tailscale auth key, which starts with $TS_KEY_PREFIX. Create one in Tailscale's admin console and run this again." ;;
  esac
  case "${TS_KEY#"$TS_KEY_PREFIX"}" in
    *[!A-Za-z0-9_-]*) fail "The Tailscale auth key holds a character no auth key has. Copy it again from Tailscale's admin console." ;;
  esac
  if [ "${#TS_KEY}" -lt "$TS_KEY_MIN" ] || [ "${#TS_KEY}" -gt "$TS_KEY_MAX" ]; then
    fail "The Tailscale auth key is not between $TS_KEY_MIN and $TS_KEY_MAX characters long. Copy it again from Tailscale's admin console."
  fi
}

# Where this host's Tailscale stands, from tailscale status --json: its
# daemon's BackendState in TS_STATE and the tailnet it is logged in to
# (CurrentTailnet.Name, an object of plain fields) in TS_TAILNET. Both are
# empty on a host without Tailscale or whose daemon does not answer (never
# started), which this run sets up; the daemon's complaint that it is not
# running is that answer, not an error.
tailscale_status() {
  TS_STATE=""
  TS_TAILNET=""
  command -v tailscale >/dev/null 2>&1 || return 0
  ts_json=$(tailscale status --json 2>/dev/null </dev/null | tr -d '\n')
  TS_STATE=$(printf '%s\n' "$ts_json" | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p')
  TS_TAILNET=$(printf '%s\n' "$ts_json" | sed -n 's/.*"CurrentTailnet": *{\([^}]*\)}.*/\1/p' |
    sed -n 's/.*"Name": *"\([^"]*\)".*/\1/p')
}

# A host on a tailnet already (Running) keeps it, named, and is neither asked
# for a key nor logged in again: a key given for it would be dropped without
# a word, so it stops instead. One that is logged in but down (Stopped) stops
# too: tailscale up with a key would log it in again.
check_tailnet() {
  case "$TS_STATE" in
    Running)
      [ -n "$TS_TAILNET" ] ||
        fail "Tailscale says this server is on a tailnet, but its status names no tailnet: update Tailscale and run this again."
      if [ -n "$TS_KEY" ]; then
        TS_KEY=""
        fail "This server is already on the tailnet $TS_TAILNET: leave TS_AUTHKEY out to keep it, or, if that tailnet is not yours, run sudo tailscale logout and run this again."
      fi
      TS_ON_TAILNET=1
      ;;
    Stopped)
      TS_KEY=""
      fail "This server is logged in to a tailnet but Tailscale is down: run sudo tailscale up and run this again."
      ;;
  esac
}

# With --tailscale, before anything is installed: no key on a host already on
# a tailnet; else the key in TS_AUTHKEY, or asked for on the terminal without
# echo, checked, then written only to TS_KEY_FILE in the work directory
# (tmpfs, root's, 0600).
read_tailscale_key() {
  tailscale_status
  check_tailnet
  [ "$TS_ON_TAILNET" -eq 0 ] || return 0
  if [ -z "$TS_KEY" ]; then
    (: </dev/tty) 2>/dev/null ||
      fail "No Tailscale auth key: run this in a terminal, which asks for it, or pass it in TS_AUTHKEY."
    read_hidden 'Tailscale auth key (it is not shown as you type): '
    TS_KEY=$HIDDEN
    HIDDEN=""
  fi
  [ -n "$TS_KEY" ] || fail "No Tailscale auth key was entered."
  check_tailscale_key
  TS_KEY_FILE=$WORK/tailscale.authkey
  printf '%s' "$TS_KEY" >"$TS_KEY_FILE"
  TS_KEY=""
  chmod 0600 "$TS_KEY_FILE"
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
    apt_get update || fail "apt-get update failed. Check this host's package sources and network."
    APT_UPDATED=1
  fi
  apt_get -y install --no-install-recommends "$@" || fail "apt-get could not install $*."
}

# apt-get -qq with its output in the work directory: dpkg's lines for each
# package (which -qq does not quiet; Chromium alone brings about 150) stay
# out of the run's own, and a call that fails puts all it said on stderr, so
# the sentence after it still has its reason above it.
apt_get() {
  if apt-get -qq "$@" </dev/null >"$WORK/apt-get.out" 2>&1; then return 0; fi
  cat "$WORK/apt-get.out" >&2
  return 1
}

# A fermix verb as the engine account: its uid, gid and groups through
# setpriv, which opens no PAM session (the one runuser opens logs two lines
# for every call), and a clean environment of exactly these names.
as_engine() {
  setpriv --reuid="$ENGINE_USER" --regid="$ENGINE_USER" --init-groups -- env -i HOME="$ACCOUNT_HOME" \
    USER="$ENGINE_USER" LOGNAME="$ENGINE_USER" SHELL=/usr/sbin/nologin PATH=/usr/bin:/bin LANG=C.UTF-8 \
    XDG_RUNTIME_DIR="/run/user/$ENGINE_UID" FERMIX_HOME="$FERMIX_HOME_DIR" \
    "$FERMIX_BIN" "$@" </dev/null
}

prepare_run_dir() {
  mkdir -p "$RUN_DIR"
  chmod 0700 "$RUN_DIR"
}

# The string at the key $2 in the one-line JSON $1, its escapes undone: the
# last such key in the text.
json_string() {
  printf '%s\n' "$1" | sed -En 's/.*"'"$2"'": *"(([^"\\]|\\.)*)".*/\1/p' | sed 's/\\"/"/g; s/\\\\/\\/g'
}

# The object of plain fields at the key $2 in the one-line JSON $1, without
# its braces; nothing when it is null.
json_object() {
  printf '%s\n' "$1" | sed -En 's/.*"'"$2"'": *\{([^}]*)\}.*/\1/p'
}

# 0. A host whose Fermix home exists already: what the home is, from `fermix
# home status --json` as the engine account (it answers with Fermix running
# or not), decides the run before anything is installed. A candidate that
# has not begun to receive its move (enrolling, failed, expired, or enrolled
# and waiting for it) enrolls again with a new code; a home that runs (the
# primary, or a candidate receiving its move) is started as it is, and
# refused when given a code; any other home is refused. The script never
# removes a home: each refusal of a home it could read, and the end of a
# run that kept one, names the commands that do.
read_home() {
  ENGINE_UID=$(id -u "$ENGINE_USER") ||
    fail "The Fermix home $FERMIX_HOME_DIR exists, but the account $ENGINE_USER does not, so this script cannot read what it is."
  read_status=0
  as_engine home status --json >"$WORK/home.json" || read_status=$?
  HOME_JSON=$(tr -d '\n' <"$WORK/home.json")
  [ "$read_status" -eq 0 ] || home_unreadable
  role=$(json_string "$HOME_JSON" role)
  phase=$(json_string "$(json_object "$HOME_JSON" move)" phase)
  case "$role $phase" in
    "candidate enrolling" | "candidate failed" | "candidate expired" | "candidate enrolled")
      [ "$RESTORE" -eq 0 ] || refuse_home "This server holds a Fermix home that has not received its move"
      REENROLL=1
      ;;
    "candidate receiving" | "candidate staged" | "candidate activating") home_runs "This server is receiving its move" ;;
    "primary "*) home_runs "Fermix runs on this server as your primary" ;;
    "device "*) retired_home ;;
    "candidate "*) refuse_home "This server's Fermix home is a candidate whose move cannot be read" ;;
    *) fail "fermix home status names no role this script knows for the Fermix home $FERMIX_HOME_DIR." ;;
  esac
}

# fermix home status refused (its envelope says why) or stopped (its stderr
# does). What the home holds is not known, so no command that removes it is
# named.
home_unreadable() {
  said=$(json_string "$(json_object "$HOME_JSON" error)" sentence)
  [ -n "$said" ] || fail "fermix home status stopped, so this script cannot read what the Fermix home $FERMIX_HOME_DIR is; its message above says why."
  CODE=""
  fail "fermix home status could not read the Fermix home $FERMIX_HOME_DIR on this server (${said%.}): run sudo -H -u $ENGINE_USER env -C / $FERMIX_BIN home status to see why."
}

# A home that runs is started as it is, unless a code came with this run;
# the run then ends saying what it is ($1) and the commands that remove it.
home_runs() {
  [ -z "$CODE" ] || refuse_home "$1"
  HOME_KEPT=1
  KEPT_HOME_IS=$1
}

# A device's home on a server is the retired copy a move left (its marker
# names where Fermix went), or a desktop of another primary.
retired_home() {
  to=$(json_string "$(json_object "$HOME_JSON" moved)" to)
  [ -z "$to" ] || refuse_home "This server's Fermix home is a retired copy, left when Fermix moved to $to"
  refuse_home "This server's Fermix runs as a desktop of another primary"
}

# Stops at a home this run does not set up: removal_sentence's.
refuse_home() {
  CODE=""
  fail "$(removal_sentence "$1")"
}

# What a home is ($1), then the commands that remove it, which the owner
# runs. Each command the owner is given runs fermix from / (env -C /): the
# engine account cannot open the directory an owner logs in to (0700 on
# Debian 13), and fermix refuses to start in one it cannot open.
removal_sentence() {
  printf '%s\n' "$1: to set this server up again, which deletes that home, run sudo -H -u $ENGINE_USER env -C / XDG_RUNTIME_DIR=/run/user/$ENGINE_UID $FERMIX_BIN service uninstall, then sudo rm -rf $FERMIX_HOME_DIR, then this command again."
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
  systemctl --quiet enable fermix-metadata-block.service
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

# 4. The signed Linux package, through the same installer every host uses:
# the release it was given, which the computer that set it up runs, so the
# home can always move back there; the latest without one.
install_fermix() {
  set -- --no-setup
  if [ -n "$RELEASE" ]; then
    say "Installing Fermix $RELEASE, the release your computer runs, with $INSTALL_URL"
    set -- "$@" --version "$RELEASE"
  else
    say "Installing Fermix with $INSTALL_URL"
  fi
  apt_install ca-certificates curl
  curl -fsSL --proto '=https' "$INSTALL_URL" -o "$WORK/install.sh" ||
    fail "Could not download the Fermix installer from $INSTALL_URL."
  sh "$WORK/install.sh" "$@" </dev/null || fail "The Fermix installer stopped; its message above says why."
  [ -x "$FERMIX_BIN" ] || fail "The installer finished, but $FERMIX_BIN is not there."
}

# Whether apt's effective configuration sets APT::Periodic::$1 to 1.
apt_periodic_on() {
  [ "$(apt-config shell VALUE "APT::Periodic::$1")" = "VALUE='1'" ]
}

# --update-script-only, which fermix-update runs after it installs a release,
# once it has checked this script against the release table: the update
# script written again as this release writes it, and nothing else, so a
# server set up by an older first boot follows the rules of the release it
# runs. No code is asked for, nothing is installed, and the host is not
# checked again.
update_script_only() {
  [ "$(id -u)" -eq 0 ] || fail "Run this as root: fermix-update runs it after an update."
  WORK=$(mktemp -d /run/fermix-update-script.XXXXXX)
  write_update_script
  say "The update script $UPDATE_SCRIPT is this release's own"
  exit 0
}

# The script fermix-update.timer and fermix-follow.timer run: first boot's
# account, home, binary and installer address, then a fixed body.
write_update_script() {
  install -d -m 0755 "$(dirname "$UPDATE_SCRIPT")"
  {
    cat <<EOF
#!/bin/sh
# Fermix Always On: with no argument, the nightly update fermix-update.timer
# runs at 04:00 UTC; with --follow, the follow run fermix-follow.timer starts
# every five minutes, which installs and restarts but never reboots; with
# --release X [--ahead-of-apps], the owner's own update to release X, behind
# the same gate. Written by Fermix's first boot, which writes it again
# whenever it runs, and by each release this script installs
# (--update-script-only).
set -eu

ENGINE_USER=$ENGINE_USER
ACCOUNT_HOME=$ACCOUNT_HOME
FERMIX_HOME_DIR=$FERMIX_HOME_DIR
FERMIX_BIN=$FERMIX_BIN
INSTALL_URL=$INSTALL_URL
EOF
    cat <<'FERMIX_UPDATE'
REBOOT_FLAG=/run/reboot-required
# Whether a move is under way is the engine account's answer, so it may hold a
# root reboot off only this many nights in a row, counted in root's own file.
DEFERRALS_FILE=/var/lib/fermix-update/reboot-deferrals
DEFERRALS_MAX=2
# One update at a time: the night and a follow run each take this lock
# (flock(1), util-linux, essential on Debian and Ubuntu), on a file only root
# can make, as /run is root's. The night waits for a run that holds it at most
# this long, half its unit's 30 minutes, so it keeps the rest to update.
LOCK_FILE=/run/fermix-update.lock
LOCK_WAIT_SECONDS=900
# The release table the installer trusts, and where every release's files
# are, as the installer builds their address: a hand update reads which
# releases exist from it, and each install checks the release's own update
# script against it.
RELEASES_URL=https://fermix.ai/install/releases
ARTIFACT_ORIGIN=https://github.com/tezra-io/fermix/releases/download/
ALWAYS_ON_FILE=fermix_always_on.sh
WORK=""
PHASE=""
# What holds the restart (restart_held): move, work, or nothing; and how long
# work on a computer still holds it, in seconds.
HOLD=""
WAIT_S=""
# Set when the engine's answer or its restart failed: the night still decides
# the reboot, then ends non-zero.
ENGINE_FAILED=0
# Set when the installer itself could not be downloaded: it never ran, so
# nothing on disk changed and the night goes on to the restart and the
# reboot, then ends non-zero.
INSTALLER_UNREACHABLE=0
# Set when the update script of a release just installed could not replace
# this one (refresh_update_script): the run goes on, then ends non-zero.
REFRESH_FAILED=0
# The release this run installs, once read (release_due, hand_release), and
# the newest release eligible for this server (read_eligible).
RELEASE=""
ELIGIBLE=""
# A follow run (--follow, read_mode) installs and restarts but never
# reboots, and says in its own words what the night says differently: when
# (WHEN), what is still decided once the installer could not be downloaded
# (STILL_DECIDED), and what a failed read of the move leaves (AS_IF_NO_MOVE).
FOLLOW=0
WHEN=tonight
STILL_DECIDED="the restart and the reboot are still decided"
AS_IF_NO_MOVE=" and the reboot is decided as if no move were under way"
# The owner's own update (--release X): the release asked for, and whether it
# may go ahead of the apps (--ahead-of-apps). It installs and restarts as a
# follow run does, never reboots, and says every step.
HAND=0
WANTED=""
AHEAD_OF_APPS=0

# One sentence and a non-zero exit, ending the run there.
fail() {
  printf 'fermix update: %s\n' "$1" >&2
  exit 1
}

say() {
  printf '==> %s\n' "$1"
}

# A line only the night and a hand update say: a follow run, in the journal
# every five minutes, says what it did and what failed, not that nothing was
# due.
note() {
  [ "$FOLLOW" -eq 1 ] || say "$1"
}

finish() {
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}

# The run's kind, from its arguments: none for the night, --follow for a
# follow run, --release X with --ahead-of-apps or not for the owner's own
# update. Nothing else is taken, and no argument is echoed back.
read_mode() {
  case "$#:${1-}" in
    0:) return 0 ;;
    1:--follow) FOLLOW=1 ;;
    2:--release | 3:--release) read_release "$@" ;;
    *) refuse_mode ;;
  esac
  WHEN=now
  STILL_DECIDED="the restart is still decided"
  AS_IF_NO_MOVE=""
}

refuse_mode() {
  fail "An option was not recognised. fermix-update takes --follow, which fermix-follow.timer passes, --release with a release and, to go ahead of the apps, --ahead-of-apps, or nothing for the nightly update."
}

# --release X [--ahead-of-apps]: X a plain MAJOR.MINOR.PATCH, as every
# release's packages are.
read_release() {
  if [ "$#" -eq 3 ] && [ "$3" != --ahead-of-apps ]; then refuse_mode; fi
  case "$2" in
    '' | *[!0-9.]* | .* | *. | *..*) fail "--release takes a Fermix release, such as 0.17.0." ;;
  esac
  minor_patch=${2#*.}
  patch=${minor_patch#*.}
  case "$patch" in *.*) fail "--release takes a Fermix release, such as 0.17.0." ;; esac
  [ "$minor_patch" != "$2" ] && [ "$patch" != "$minor_patch" ] ||
    fail "--release takes a Fermix release, such as 0.17.0."
  HAND=1
  WANTED=$2
  if [ "$#" -eq 3 ]; then AHEAD_OF_APPS=1; fi
}

# flock(1) on the lock's descriptor, 9, with $@ (-n, or -w and a bound): 0
# once the lock is this run's, 1 while another run holds it (util-linux's own
# status for that); any other status fails the run.
lock() {
  status=0
  flock "$@" 9 || status=$?
  case "$status" in
    0 | 1) return "$status" ;;
  esac
  fail "flock could not take the lock $LOCK_FILE (exit $status), so Fermix is not updated $WHEN; its message above says why."
}

# The lock, before anything is read or installed. A follow run that finds it
# held leaves the update to the run that holds it; the night and a hand
# update wait for that run, at most LOCK_WAIT_SECONDS. Exiting releases it.
take_lock() {
  exec 9>"$LOCK_FILE"
  if lock -n; then return 0; fi
  if [ "$FOLLOW" -eq 1 ]; then
    say "Another Fermix update is running, so this follow run leaves it to that one"
    exit 0
  fi
  if [ "$HAND" -eq 1 ]; then
    say "Another Fermix update is running, so this update waits for it to finish"
    lock -w "$LOCK_WAIT_SECONDS" ||
      fail "Another Fermix update was still running when this update stopped waiting for it, so nothing was installed; run it again."
    return 0
  fi
  say "Another Fermix update is running, so the nightly update waits for it to finish"
  lock -w "$LOCK_WAIT_SECONDS" ||
    fail "Another Fermix update was still running when the nightly update stopped waiting for it, so nothing is updated, restarted or rebooted tonight; the next night tries again."
}

installed_version() {
  # shellcheck disable=SC2016 # ${Version} is dpkg-query's own format syntax
  dpkg-query -W -f='${Version}' fermix 2>/dev/null ||
    fail "dpkg lists no fermix package on this server, so there is nothing to update."
}

# The installer every host uses, downloaded afresh. A failed download changed
# nothing, so the run carries on without an update.
fetch_installer() {
  if ! curl -fsSL --proto '=https' "$INSTALL_URL" -o "$WORK/install.sh"; then
    warn "Could not download the Fermix installer from $INSTALL_URL, so Fermix is not updated $WHEN; nothing was installed, so $STILL_DECIDED."
    INSTALLER_UNREACHABLE=1
    return 1
  fi
}

# The installer, checking fermix.ai's digests: it installs the release this
# run chose (RELEASE). The package restarts nothing, so the running engine is
# untouched until the restart. Its exit status does not say whether it failed
# before or after the package manager ran, so any failure stops the run
# before the restart and the reboot. The lock's descriptor is closed for it,
# as for every fermix verb, so nothing they leave running holds the lock.
update_fermix() {
  sh "$WORK/install.sh" --no-setup --version "$RELEASE" </dev/null 9>&- ||
    fail "The Fermix installer stopped, so the engine keeps running; its message above says why."
}

# A fermix verb as the engine account, as first boot runs one: its uid, gid
# and groups through setpriv, which opens no PAM session (the one runuser
# opens would log two lines for every call, every five minutes), and the
# clean environment first boot gives it.
as_engine() {
  uid=$(id -u "$ENGINE_USER")
  setpriv --reuid="$ENGINE_USER" --regid="$ENGINE_USER" --init-groups -- env -i HOME="$ACCOUNT_HOME" \
    USER="$ENGINE_USER" LOGNAME="$ENGINE_USER" SHELL=/usr/sbin/nologin PATH=/usr/bin:/bin LANG=C.UTF-8 \
    XDG_RUNTIME_DIR="/run/user/$uid" FERMIX_HOME="$FERMIX_HOME_DIR" \
    "$FERMIX_BIN" "$@" </dev/null 9>&-
}

# A line on stderr for a failure the run carries on past.
warn() {
  printf 'fermix update: %s\n' "$1" >&2
}

# The newest release eligible for this server (ELIGIBLE): `fermix home status
# --json`'s `update_ceiling`, which is `update.eligible`: the newest release,
# at or above the one Fermix runs, that the app of each system whose
# computers keep the home's backups carries, read from the release table the
# engine keeps (M97, the server leads). Empty when none is, or when the
# engine has read no table. A status read that fails fails the run.
read_eligible() {
  ELIGIBLE=""
  if ! as_engine home status --json >"$WORK/eligible.json"; then
    warn "fermix home status stopped, so Fermix is not updated $WHEN; its message above says why."
    ENGINE_FAILED=1
    return 1
  fi
  ELIGIBLE=$(tr -d '\n' <"$WORK/eligible.json" |
    sed -n 's/.*"update_ceiling": *"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p')
}

# Whether this run installs a release, and which (RELEASE): the eligible one
# (read_eligible), when the installed release ($1) is older in dpkg's own
# order: a newer one is never installed back down. No home yet, none
# eligible, or an answer that cannot be read installs nothing; only the last
# fails the run.
release_due() {
  if [ ! -e "$FERMIX_HOME_DIR" ]; then
    note "This server has no Fermix home yet, so no release is chosen for it; Fermix stays at $1"
    return 1
  fi
  read_eligible || return 1
  if [ -z "$ELIGIBLE" ]; then
    note "No release is eligible for this server now (fermix home status says why), so Fermix stays at $1"
    return 1
  fi
  if [ "$ELIGIBLE" = "$1" ]; then
    note "Fermix $1 is the newest release eligible for this server"
    return 1
  fi
  if dpkg --compare-versions "$ELIGIBLE" lt "$1"; then
    note "Fermix $1 is newer than $ELIGIBLE, the newest release eligible for this server, and is never installed back down"
    return 1
  fi
  RELEASE=$ELIGIBLE
}

# The release table, into the run's directory.
fetch_table() {
  curl -fsSL --proto '=https' "$RELEASES_URL" -o "$WORK/releases" &&
    [ "$(awk 'NR == 1 { print; exit }' "$WORK/releases")" = "format 1" ]
}

# Whether the table lists release $1: one of its file rows names it.
table_lists() {
  awk -v version="$1" '
    NR > 1 && NF == 3 && $1 == version { found = 1; exit }
    END { exit !found }
  ' "$WORK/releases"
}

# The sha256 the table lists for file $2 of release $1, or nothing unless it
# lists exactly one, as the installer reads it.
table_digest() {
  awk -v version="$1" -v file="$2" '
    NR > 1 && NF == 3 && $1 == version && $3 == file { digest = $2; rows++ }
    END { if (rows == 1) print digest }
  ' "$WORK/releases"
}

# The owner's own update to WANTED (--release), behind the same gate as the
# automatic one: never below the installed release ($1), since an older
# Fermix cannot read the home; only a release the table lists; and only an
# eligible one, or one no newer than it, unless --ahead-of-apps says to go
# ahead of the apps, which this says. Sets RELEASE; 1 when nothing is due.
hand_release() {
  if dpkg --compare-versions "$WANTED" lt "$1"; then
    fail "Fermix $1 is installed, and $WANTED is older: Fermix is never installed back down, since an older Fermix cannot read your home."
  fi
  if [ "$WANTED" = "$1" ]; then
    say "Fermix $WANTED is installed already"
    return 1
  fi
  [ -e "$FERMIX_HOME_DIR" ] ||
    fail "This server has no Fermix home yet, so no release is chosen for it; nothing was installed."
  fetch_table ||
    fail "Could not read the release table from $RELEASES_URL, so nothing was installed."
  table_lists "$WANTED" ||
    fail "$RELEASES_URL lists no release $WANTED, so nothing was installed."
  read_eligible || exit 1
  if [ -z "$ELIGIBLE" ] || dpkg --compare-versions "$WANTED" gt "$ELIGIBLE"; then
    [ "$AHEAD_OF_APPS" -eq 1 ] ||
      fail "Fermix $WANTED is ahead of the apps: no app that carries it is published yet for a computer that keeps your backups, and that computer could not restore your home from them. Nothing was installed. To install it all the same, run: fermix-update --release $WANTED --ahead-of-apps"
    say "Installing Fermix $WANTED ahead of the apps, as asked: each computer that keeps your backups says so until its app carries it"
  fi
  RELEASE=$WANTED
}

# The release chosen, through the installer; then this script becomes the
# installed release's own.
install_release() {
  if fetch_installer; then
    update_fermix
    report_versions "$1"
    refresh_update_script
  fi
}

# The update script of the release just installed, so the next run follows
# that release's rules: its Always On server script (the copy of
# first-boot.sh every release publishes as fermix_always_on.sh), checked
# against the sha256 the release table lists for it as the installer checks
# a package, rewrites this script and nothing else (--update-script-only).
# This run goes on as it began: the shell keeps the file it read, which the
# rewrite replaces by a rename. A script that cannot be fetched or checked
# leaves this one as it is, says so, and fails the run at its end.
refresh_update_script() {
  installed=$(installed_version) || exit 1
  if ! fetch_table; then
    refresh_failed "the release table could not be read from $RELEASES_URL"
    return 0
  fi
  digest=$(table_digest "$installed" "$ALWAYS_ON_FILE")
  if [ -z "$digest" ]; then
    refresh_failed "$RELEASES_URL lists no single update script for Fermix $installed"
    return 0
  fi
  if ! curl -fsSL --proto '=https' "${ARTIFACT_ORIGIN}v$installed/$ALWAYS_ON_FILE" -o "$WORK/$ALWAYS_ON_FILE"; then
    refresh_failed "the update script of Fermix $installed could not be downloaded"
    return 0
  fi
  if [ "$(sha256sum "$WORK/$ALWAYS_ON_FILE" | cut -d ' ' -f 1)" != "$digest" ]; then
    refresh_failed "the update script of Fermix $installed is not the one $RELEASES_URL lists"
    return 0
  fi
  if ! sh "$WORK/$ALWAYS_ON_FILE" --update-script-only </dev/null 9>&-; then
    refresh_failed "the update script of Fermix $installed stopped; its message above says why"
    return 0
  fi
  say "This update script is now Fermix $installed's own"
}

refresh_failed() {
  warn "Fermix is updated, but $1, so this update script stays as it was."
  REFRESH_FAILED=1
}

# Whether the running engine is older than the installed one: the `alignment`
# `fermix service status --json` publishes, `pending_restart` exactly then. It
# compares what runs with what is installed, so a restart a run skipped or
# failed is still due at the next, and an engine that is not running (a
# restore host before its import) is not started.
restart_due() {
  if ! as_engine service status --json >"$WORK/service-status.json"; then
    warn "fermix service status stopped, so the engine is not restarted $WHEN; its message above says why."
    ENGINE_FAILED=1
    return 1
  fi
  [ "$(tr -d '\n' <"$WORK/service-status.json" |
    sed -n 's/.*"alignment": *"\([a-z_]*\)".*/\1/p')" = pending_restart ]
}

# Whether the engine's restart waits, from `fermix home status --json` (with
# Fermix running or not): a move under way here, in a phase the move code
# treats as pending: this server sending its home (Home.Move's pending
# phases), or a candidate enrolling or receiving one; ended phases
# (committed, undoing, done, aborted, enrolled, expired, failed) are not.
# Or work Fermix runs on a computer (`restart_hold.wait_s` above 0), which
# the engine bounds at ten minutes. Sets PHASE, HOLD (move or work) and
# WAIT_S. An answer that cannot be read counts as no hold, and the engine is
# not restarted on this run.
restart_held() {
  HOLD=""
  [ -e "$FERMIX_HOME_DIR" ] || return 1
  if ! as_engine home status --json >"$WORK/home-status.json"; then
    warn "fermix home status stopped, so the engine is not restarted $WHEN$AS_IF_NO_MOVE; its message above says why."
    ENGINE_FAILED=1
    return 1
  fi
  PHASE=$(tr -d '\n' <"$WORK/home-status.json" | sed -n 's/.*"move": *{\([^}]*\)}.*/\1/p' |
    sed -n 's/.*"phase": *"\([a-z_]*\)".*/\1/p')
  case "$PHASE" in
    requested | streaming | committing | aborting | enrolling | receiving | staged | activating)
      HOLD=move
      return 0
      ;;
  esac
  WAIT_S=$(tr -d '\n' <"$WORK/home-status.json" | sed -n 's/.*"restart_hold": *{\([^}]*\)}.*/\1/p' |
    sed -n 's/.*"wait_s": *\([0-9][0-9]*\).*/\1/p')
  if [ -n "$WAIT_S" ] && [ "$WAIT_S" -gt 0 ]; then
    HOLD=work
    return 0
  fi
  return 1
}

# The engine account's own `fermix restart`, the restart an owner runs after an
# update: it restarts the service and waits for the new engine to answer.
restart_engine() {
  say "Restarting the engine, which runs an older release than the one installed"
  if ! as_engine restart; then
    warn "Fermix is updated, but fermix restart stopped; its message above says why."
    ENGINE_FAILED=1
  fi
}

# The restart, unless the engine's answers failed or something holds it ($1:
# move, work, or nothing).
restart_step() {
  [ "$ENGINE_FAILED" -eq 0 ] || return 0
  case "$1" in
    move)
      say "A move is under way on this server ($PHASE), so the engine restarts at the first follow run after it ends"
      return 0
      ;;
    work)
      say "Fermix is running work on a computer, so the engine restarts once it ends, at a follow run within $WAIT_S seconds"
      return 0
      ;;
  esac
  restart_engine
}

# A follow run's restart, decided as the night's is: when the engine is
# behind the installed release, unless a move or a computer's work holds it.
# A restart they held off is still due at the first run after. It never
# reboots, and never reads or writes the night's deferral count.
follow_restart() {
  restart_due || return 0
  restart_held || :
  restart_step "$HOLD"
}

# Consecutive nights a move has held a reboot off. A count the file does not
# hold as a number reads as the limit, so the reboot waits no longer.
deferrals() {
  if [ ! -e "$DEFERRALS_FILE" ]; then
    echo 0
    return 0
  fi
  count=$(cat "$DEFERRALS_FILE") || count=""
  case "$count" in
    '' | *[!0-9]*) echo "$DEFERRALS_MAX" ;;
    *) echo "$count" ;;
  esac
}

record_deferral() {
  install -d -m 0700 "$(dirname "$DEFERRALS_FILE")"
  printf '%s\n' "$1" >"$DEFERRALS_FILE.incoming"
  mv -f "$DEFERRALS_FILE.incoming" "$DEFERRALS_FILE"
}

# The reboot an update asks for, unless a move is under way ($1 is move) and
# has held it off fewer than DEFERRALS_MAX nights in a row. A computer's work
# holds the restart, not the night's reboot.
reboot_step() {
  sentence="An installed update asks for a reboot ($REBOOT_FLAG), so this server reboots now"
  if [ "$1" = move ]; then
    count=$(deferrals)
    if [ "$count" -lt "$DEFERRALS_MAX" ]; then
      record_deferral $((count + 1))
      say "A move is under way on this server ($PHASE), so the reboot an update asks for waits: night $((count + 1)) of at most $DEFERRALS_MAX"
      return 0
    fi
    sentence="A move has held the reboot an update asks for off $DEFERRALS_MAX nights in a row, so this server reboots now all the same"
  fi
  rm -f "$DEFERRALS_FILE"
  say "$sentence"
  systemctl reboot || fail "systemctl reboot was refused; the next night tries again."
}

# After the update: the restart when the engine is behind, the reboot when an
# update asks for one. Only the restart rests on the engine's answers; a move
# defers the reboot a bounded number of nights.
restart_and_reboot() {
  restart=0
  if restart_due; then restart=1; fi
  if [ "$restart" -eq 0 ] && [ ! -e "$REBOOT_FLAG" ]; then
    [ "$ENGINE_FAILED" -eq 1 ] || say "No restart is due and no update asks for a reboot"
    rm -f "$DEFERRALS_FILE"
    return 0
  fi
  restart_held || :
  if [ "$restart" -eq 1 ]; then restart_step "$HOLD"; fi
  if [ -e "$REBOOT_FLAG" ]; then
    reboot_step "$HOLD"
  else
    rm -f "$DEFERRALS_FILE"
  fi
}

report_versions() {
  after=$(installed_version) || exit 1
  if [ "$after" = "$1" ]; then
    say "Fermix stays at $after"
  else
    say "Fermix went from $1 to $after"
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
  read_mode "$@"
  [ "$(id -u)" -eq 0 ] || fail "Run this as root, as fermix-update.timer does."
  take_lock
  # A server with no Fermix home yet (a first boot that has not enrolled it,
  # or a restore host before its import) has no release chosen for it and no
  # engine to restart, so a follow run there does nothing and says nothing.
  if [ "$FOLLOW" -eq 1 ] && [ ! -e "$FERMIX_HOME_DIR" ]; then exit 0; fi
  WORK=$(mktemp -d /run/fermix-update.XXXXXX)
  printf 'DPkg::Lock::Timeout "600";\n' >"$WORK/apt.conf"
  APT_CONFIG=$WORK/apt.conf
  export APT_CONFIG

  before=$(installed_version) || exit 1
  if [ "$HAND" -eq 1 ]; then
    if hand_release "$before"; then
      say "Updating Fermix $before to $RELEASE, as asked, through $INSTALL_URL"
      install_release "$before"
    fi
  elif release_due "$before"; then
    say "Updating Fermix $before to $RELEASE, the newest release eligible for this server, through $INSTALL_URL"
    install_release "$before"
  fi
  if [ "$FOLLOW" -eq 1 ] || [ "$HAND" -eq 1 ]; then follow_restart; else restart_and_reboot; fi
  [ "$ENGINE_FAILED" -eq 0 ] && [ "$INSTALLER_UNREACHABLE" -eq 0 ] && [ "$REFRESH_FAILED" -eq 0 ] ||
    exit 1
}

main "$@"
FERMIX_UPDATE
  } | write_file "$UPDATE_SCRIPT" 0755
}

# 5. Updates, as nobody logs in to this server. Debian's own: unattended-upgrades,
# which the Debian 13 cloud image installs and turns on, installed here when a
# provider's image lacks it, and its two daily switches set in a file of
# Fermix's. Fermix's own: the package comes from the release files, not an apt
# source, so unattended-upgrades never sees it; root timers run the installer
# for the newest release eligible for this server (the engine's `update`, from
# the release table: one the app of each computer keeping its backups
# carries; nothing when none is, and never back down), then make the update
# script that release's own, and restart the engine when it runs an older
# release than the one installed (not while a move is under way or a
# computer's work holds it, at most ten minutes, nor when the engine's
# answers fail): every five minutes (fermix-follow.timer), so the server takes
# a release within minutes of its apps, and every night at 04:00 UTC
# (fermix-update.timer), which also reboots when an update asks for it (a
# move may hold that off two nights in a row, no more). One lock keeps the two
# from running at once. An installer that ran and failed stops the run before
# both; one that could not be downloaded changed nothing, so both are still
# decided. Every failure says why in the journal, and the next run tries
# again.
schedule_updates() {
  say "Turning on updates: Debian's security updates every day, Fermix every five minutes to the newest release your apps carry, and the reboots updates ask for at 04:00 UTC"
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
  # The follow run's own lines reach the journal at notice, and nothing below
  # notice does: systemd's own start and finish lines for each run, at info,
  # stay out, and a run that fails keeps systemd's lines that say so.
  write_file "$UNIT_DIR/fermix-follow.service" 0644 <<EOF
[Unit]
Description=Fermix: install the newest release eligible for this server, and restart Fermix when it is behind
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$UPDATE_SCRIPT --follow
TimeoutStartSec=30min
SyslogLevel=notice
LogLevelMax=notice
EOF
  write_file "$UNIT_DIR/fermix-follow.timer" 0644 <<'EOF'
[Unit]
Description=Fermix: follow the newest release eligible for this server, every five minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl --quiet enable --now fermix-update.timer
  systemctl --quiet enable --now fermix-follow.timer
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

# 6b. E1, on a server whose infrastructure set the bucket: the root helper
# that assumes the snapshot writer role with the instance role's credentials
# (root alone reaches the metadata service) and hands the engine account that
# one-hour session, which may only put objects into the bucket. It runs once
# now, and the run must work, then every 15 minutes from a root timer, so a
# session always has 45 minutes left. The engine reads
# $CREDENTIALS_DIR/credentials.json (root:fermix 0640) at each upload, and the
# last failed run's one sentence from $CREDENTIALS_DIR/error.
install_snapshot_credentials() {
  [ -n "$SNAPSHOT_ROLE_ARN" ] || return 0
  say "Setting up S3 backups to $SNAPSHOT_BUCKET, signed with this server's instance role"
  write_credentials_helper
  write_file /etc/tmpfiles.d/fermix-snapshot-credentials.conf 0644 <<EOF
d $CREDENTIALS_DIR 0750 root $ENGINE_USER -
EOF
  install -d -m 0750 -o root -g "$ENGINE_USER" "$CREDENTIALS_DIR"
  chown root:"$ENGINE_USER" "$CREDENTIALS_DIR"
  chmod 0750 "$CREDENTIALS_DIR"
  write_file "$UNIT_DIR/fermix-snapshot-credentials.service" 0644 <<EOF
[Unit]
Description=Fermix: hand Fermix a one-hour S3 session of this server's snapshot writer role
Wants=network-online.target
After=network-online.target fermix-metadata-block.service

[Service]
Type=oneshot
ExecStart=$CREDENTIALS_HELPER
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=$CREDENTIALS_DIR
EOF
  write_file "$UNIT_DIR/fermix-snapshot-credentials.timer" 0644 <<'EOF'
[Unit]
Description=Fermix: a fresh S3 session for Fermix's snapshots every 15 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=15min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
  "$CREDENTIALS_HELPER" ||
    fail "The S3 credentials helper could not hand Fermix a session, so S3 backups would fail; its message above says why. Check that this server's stack applied enable_s3_backups, then run this command again."
  systemctl daemon-reload
  systemctl --quiet enable --now fermix-snapshot-credentials.timer
}

# The helper: the role, region, directory and group first boot read, then a
# fixed body. Every secret it handles reaches curl on its standard input
# (-K -), never its command line, which any account may read.
write_credentials_helper() {
  install -d -m 0755 "$(dirname "$CREDENTIALS_HELPER")"
  {
    cat <<EOF
#!/bin/sh
# Fermix Always On: hands Fermix's account a one-hour session of the snapshot
# writer role, which may only put objects into this server's snapshot bucket.
# fermix-snapshot-credentials.timer runs it every 15 minutes, as root.
# Written by Fermix's first boot, which writes it again whenever it runs.
set -eu

ROLE_ARN=$SNAPSHOT_ROLE_ARN
REGION=$SNAPSHOT_REGION
OUT_DIR=$CREDENTIALS_DIR
ENGINE_GROUP=$ENGINE_USER
EOF
    cat <<'FERMIX_CREDENTIALS'
IMDS=http://169.254.169.254
SESSION_SECONDS=3600
SESSION_NAME=fermix-snapshots
MAX_SAID=300
WORK=""
TOKEN=""
KEY_ID=""
SECRET=""
SESSION=""

finish() {
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}

# One sentence, kept for the engine to show beside its own, and a non-zero
# exit. A sentence that cannot be kept still reaches the journal.
fail() {
  printf 'fermix snapshot credentials: %s\n' "$1" >&2
  if [ -n "$WORK" ] && printf '%s\n' "$1" >"$WORK/error" && chmod 0640 "$WORK/error" &&
    chgrp "$ENGINE_GROUP" "$WORK/error"; then
    mv -fT "$WORK/error" "$OUT_DIR/error" || true
  fi
  exit 1
}

# Whole-line match of one value against an extended regular expression.
matches() {
  case "$1" in *'
'*) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eq "$2"
}

# A value made only of the characters AWS writes in a key, a secret or a
# token, of at most $2 bytes.
plain() {
  [ -n "$1" ] && [ "${#1}" -le "$2" ] && matches "$1" '^[A-Za-z0-9/+=]+$'
}

# curl's own words for a failed call, one line, bounded.
curl_said() {
  tr '\n' ' ' <"$WORK/curl.err" | sed 's/^curl: //; s/^([0-9]*) //; s/ *$//' | cut -c1-"$MAX_SAID"
}

# A metadata path into the file $2, with the session token on curl's
# standard input.
imds() {
  printf 'header = "X-aws-ec2-metadata-token: %s"\n' "$TOKEN" |
    curl -fsS --max-time 5 -K - -o "$2" "$IMDS$1" 2>"$WORK/curl.err"
}

# The field $1 of the JSON the metadata service answers, one per line.
imds_field() {
  sed -n 's/^ *"'"$1"'" *: *"\([^"]*\)".*/\1/p' "$WORK/instance.json" | head -n 1
}

# The element $1 of STS's XML answer.
sts_field() {
  tr -d '\n' <"$WORK/sts.xml" | sed -n 's/.*<'"$1"'>\([^<]*\)<\/'"$1"'>.*/\1/p'
}

instance_credentials() {
  TOKEN=$(curl -fsS --max-time 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
    "$IMDS/latest/api/token" 2>"$WORK/curl.err") ||
    fail "The instance metadata service did not answer ($(curl_said)), so no S3 session was made."
  imds /latest/meta-data/iam/security-credentials/ "$WORK/role" ||
    fail "This server's instance metadata names no instance role ($(curl_said)), so no S3 session was made."
  role=$(head -n 1 "$WORK/role")
  matches "$role" '^[A-Za-z0-9+=,.@_-]+$' ||
    fail "This server's instance metadata names no instance role, so no S3 session was made."
  imds "/latest/meta-data/iam/security-credentials/$role" "$WORK/instance.json" ||
    fail "The instance metadata service gave no credentials for the role $role ($(curl_said))."
  KEY_ID=$(imds_field AccessKeyId)
  SECRET=$(imds_field SecretAccessKey)
  SESSION=$(imds_field Token)
  if [ "$(imds_field Code)" != Success ] || ! plain "$KEY_ID" 128 || ! plain "$SECRET" 128 ||
    ! plain "$SESSION" 8192; then
    fail "The instance role's credentials are not in the shape AWS writes, so no S3 session was made."
  fi
}

# sts:AssumeRole of the snapshot writer, signed by curl (SigV4) with the
# instance role's credentials, which reach it on its standard input.
assume_role() {
  status=$(printf 'user = "%s:%s"\nheader = "x-amz-security-token: %s"\n' "$KEY_ID" "$SECRET" "$SESSION" |
    curl -sS --max-time 30 --proto '=https' -K - --aws-sigv4 "aws:amz:$REGION:sts" \
      -d Action=AssumeRole -d Version=2011-06-15 --data-urlencode "RoleArn=$ROLE_ARN" \
      -d "RoleSessionName=$SESSION_NAME" -d "DurationSeconds=$SESSION_SECONDS" \
      -o "$WORK/sts.xml" -w '%{http_code}' "https://sts.$REGION.amazonaws.com/" 2>"$WORK/curl.err") ||
    fail "AWS STS could not be reached ($(curl_said)), so no S3 session was made."
  KEY_ID="" SECRET="" SESSION=""
  [ "$status" = 200 ] || sts_refused "$status"
}

# STS's own Code and Message, its escapes undone, bounded.
sts_refused() {
  code=$(sts_field Code | cut -c1-80)
  message=$(sts_field Message | sed "s/&quot;/\"/g; s/&apos;/'/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\\&/g" |
    cut -c1-"$MAX_SAID")
  fail "AWS STS refused the snapshot session (HTTP $1 ${code:-with no code}: ${message:-no message})."
}

# The session, as the engine reads it, with the account the role is in: the
# bucket's owner the engine names on every upload. Replaced whole, by rename.
write_session() {
  key_id=$(sts_field AccessKeyId)
  secret=$(sts_field SecretAccessKey)
  session=$(sts_field SessionToken)
  expiration=$(sts_field Expiration)
  account=$(printf '%s\n' "$ROLE_ARN" | cut -d: -f5)
  if ! plain "$key_id" 128 || ! plain "$secret" 128 || ! plain "$session" 8192 ||
    ! matches "$expiration" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    fail "AWS STS answered with no session in its shape, so none was handed to Fermix."
  fi
  printf '{"access_key_id":"%s","secret_access_key":"%s","session_token":"%s","expiration":"%s","account_id":"%s"}\n' \
    "$key_id" "$secret" "$session" "$expiration" "$account" >"$WORK/credentials.json"
  chmod 0640 "$WORK/credentials.json"
  chgrp "$ENGINE_GROUP" "$WORK/credentials.json"
  mv -fT "$WORK/credentials.json" "$OUT_DIR/credentials.json" ||
    fail "The S3 session could not be written to $OUT_DIR/credentials.json."
  rm -f "$OUT_DIR/error"
  printf '==> Fermix holds an S3 session until %s\n' "$expiration"
}

main() {
  umask 077
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  LC_ALL=C
  export PATH LC_ALL
  cd /
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ "$(id -u)" -eq 0 ] || fail "Run this as root, as fermix-snapshot-credentials.timer does."
  [ "$#" -eq 0 ] || fail "fermix-snapshot-credentials takes no argument."
  # The work directory is beside the output, so each file lands by rename.
  WORK=$(mktemp -d "$OUT_DIR/.work.XXXXXX") ||
    fail "$OUT_DIR is missing or not root's to write, so no S3 session was made."
  instance_credentials
  assume_role
  write_session
}

main "$@"
FERMIX_CREDENTIALS
  } | write_file "$CREDENTIALS_HELPER" 0755
}

# 7. A candidate that enrolls again: its engine stops first, since the
# enrollment replaces the candidate only while no engine runs in the home;
# the service starts again at step 8, or right after a refused enrollment
# (enroll_refused).
stop_engine() {
  say "Stopping Fermix to enroll this server again with the new code"
  as_engine service uninstall ||
    fail "fermix service uninstall stopped, so this server is not enrolled again; its message above says why."
}

# The engine account writes its candidate home from the code file.
enroll() {
  if [ "$HOME_KEPT" -eq 1 ]; then
    say "The Fermix home $FERMIX_HOME_DIR already exists, so this host is not enrolled again"
    return 0
  fi
  say "Enrolling this server with your primary"
  set -- home enroll --code-file "$CODE_FILE"
  if [ -n "$SNAPSHOT_BUCKET" ]; then
    set -- "$@" --snapshot-bucket "$SNAPSHOT_BUCKET" --snapshot-region "$SNAPSHOT_REGION"
  fi
  if [ -n "$SNAPSHOT_ROLE_ARN" ]; then set -- "$@" --snapshot-instance-role; fi
  as_engine "$@" || enroll_refused
}

# fermix home enroll stopped, leaving the home as it was. A candidate
# enrolling again had its engine stopped for it (stop_engine), so its service
# starts again with the enrollment it had, once, before the run fails: the
# one recovery step for that stop.
enroll_refused() {
  [ "$REENROLL" -eq 1 ] || fail "fermix home enroll stopped; its message above says why."
  start_service "fermix home enroll stopped, and fermix service install did not start this server again with the enrollment it had; their messages above say why."
  fail "fermix home enroll stopped, so this server keeps the enrollment it had and runs again; its message above says why."
}

# 8. The packaged user service, bound to that home and started; one that
# does not start ends the run with $1, or with this step's own sentence.
start_service() {
  say "Starting Fermix as the background service of $ENGINE_USER"
  as_engine service install --home "$FERMIX_HOME_DIR" ||
    fail "${1:-fermix service install stopped; its message above says why.}"
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

# Tailscale's repository for this host's release, as pkgs.tailscale.com
# names it: DIST/SUITE.
tailscale_repo() {
  case "$(os_field ID) $(os_field VERSION_ID)" in
    "debian 12") TS_REPO=debian/bookworm ;;
    "debian 13") TS_REPO=debian/trixie ;;
    "ubuntu 24.04") TS_REPO=ubuntu/noble ;;
    *) fail "Fermix knows no Tailscale repository for $(os_field PRETTY_NAME)." ;;
  esac
}

# The key the repository serves ($1, from the address $2) must be Tailscale's
# package signing key alone: gpg lists each primary key's fingerprint on the
# line after it, and only the pinned one may be there. Its subkeys are bound
# to it by its own signatures, which apt's verifier checks.
check_tailscale_signing_key() {
  mkdir -p "$WORK/gnupg"
  gpg --homedir "$WORK/gnupg" --batch --quiet --no-autostart --with-colons --show-keys "$1" \
    </dev/null >"$WORK/tailscale-key.txt" ||
    fail "gpg could not read the key $2 serves, so Tailscale is not installed."
  primaries=$(sed -n '/^pub:/{n;s/^fpr:::::::::\([0-9A-F]*\):.*$/\1/p;}' "$WORK/tailscale-key.txt")
  [ "$primaries" = "$TAILSCALE_KEY_FPR" ] ||
    fail "The key $2 serves is not Tailscale's package signing key alone ($TAILSCALE_KEY_FPR), so Tailscale is not installed."
}

# Tailscale's own package from its repository, the way a careful installer
# adds a source: the signing key checked first, then a source that trusts
# that key alone for that repository. The package starts tailscaled; the
# enable makes sure of it.
install_tailscale() {
  tailscale_repo
  key_url=$TAILSCALE_PKGS/$TS_REPO.noarmor.gpg
  say "Installing Tailscale from its signed repository, $TAILSCALE_PKGS/${TS_REPO%/*} ${TS_REPO#*/}"
  apt_install ca-certificates curl gpg
  curl -fsSL --proto '=https' "$key_url" -o "$WORK/tailscale-keyring.gpg" ||
    fail "Could not download Tailscale's package signing key from $key_url."
  check_tailscale_signing_key "$WORK/tailscale-keyring.gpg" "$key_url"
  write_file "$TAILSCALE_KEYRING" 0644 <"$WORK/tailscale-keyring.gpg"
  write_file "$TAILSCALE_SOURCE" 0644 <<EOF
# Fermix Always On: Tailscale's packages for ${TS_REPO%/*} ${TS_REPO#*/}, signed by the key $TAILSCALE_KEY_FPR, which the first boot checked.
deb [signed-by=$TAILSCALE_KEYRING] $TAILSCALE_PKGS/${TS_REPO%/*} ${TS_REPO#*/} main
EOF
  # The new source's package lists.
  APT_UPDATED=0
  apt_install tailscale
  systemctl --quiet enable --now tailscaled.service ||
    fail "systemctl could not start tailscaled.service, so this server cannot join your tailnet; its message above says why."
}

# tailscale up with the key file, which is removed whether it joined or not.
tailscale_up() {
  say "Joining this server to your tailnet"
  up=0
  tailscale up --auth-key="file:$TS_KEY_FILE" --timeout="$TAILSCALE_UP_TIMEOUT" </dev/null || up=$?
  rm -f "$TS_KEY_FILE"
  [ "$up" -eq 0 ] ||
    fail "tailscale up did not join this server to your tailnet, so the first boot stops here; its message above says why. A key that is used up, expired or revoked is refused: create a new one and run this again. If it printed a link to approve this server, approve it there and run this again without a key."
}

# With --tailscale, after the engine account and before enrolling, so the
# server's tailnet address exists when it enrolls: Tailscale's package, then
# tailscale up with the owner's key, with no tags of its own (the key carries
# them). A host already on a tailnet keeps it as it is. It opens no port:
# the tailnet policy decides which devices reach the server.
join_tailnet() {
  if [ "$TS_ON_TAILNET" -eq 1 ]; then
    say "This server is already on the tailnet $TS_TAILNET, so Tailscale is not installed or logged in again"
  else
    install_tailscale
    tailscale_up
  fi
  address=$(tailscale ip -1 </dev/null) ||
    fail "Tailscale names no tailnet address for this server; tailscale ip's message above says why."
  say "This server is on your tailnet at $address"
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
       sudo -H -u $ENGINE_USER env -C / FERMIX_HOME=$RESTORE_CLI_HOME $FERMIX_BIN home import $RESTORE_FILE --into $FERMIX_HOME_DIR
  3. Start Fermix from the restored home:
       sudo -H -u $ENGINE_USER env -C / XDG_RUNTIME_DIR=/run/user/$ENGINE_UID $FERMIX_BIN service install --home $FERMIX_HOME_DIR
  4. Remove the downloaded snapshot and the import's own scratch home:
       sudo rm -rf $RESTORE_FILE $RESTORE_CLI_HOME
EOF
}

finish_enrollment() {
  if [ "$REENROLL" -eq 1 ]; then stop_engine; fi
  enroll
  start_service
  install_browser
  if [ "$HOME_KEPT" -eq 1 ]; then
    say "Done. Fermix runs from the home it already had."
    say "$(removal_sentence "$KEPT_HOME_IS")"
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
  TS_KEY=${TS_AUTHKEY-}
  unset FERMIX_ENROLL_CODE TS_AUTHKEY
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
  if [ "$UPDATE_SCRIPT_ONLY" -eq 1 ]; then update_script_only; fi
  check_host
  read_snapshot_destination
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
    read_home
  fi
  if [ "$RESTORE" -eq 0 ] && [ "$HOME_KEPT" -eq 0 ]; then read_code; fi
  # Both secrets are read and checked before either is written, and before
  # anything is installed. CODE holds one only on a host that enrolls.
  if [ "$TAILSCALE" -eq 1 ]; then read_tailscale_key; fi
  if [ -n "$CODE" ]; then write_code_file; fi
  block_metadata
  add_swap
  install_fermix
  schedule_updates
  create_engine_user
  if [ "$TAILSCALE" -eq 1 ]; then join_tailnet; fi
  install_snapshot_credentials
  if [ "$RESTORE" -eq 1 ] && [ "$HOME_EXISTS" -eq 0 ]; then
    finish_restore
  else
    finish_enrollment
  fi
}

main "$@"
