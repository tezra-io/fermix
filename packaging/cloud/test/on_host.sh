#!/bin/sh
# Runs first-boot.sh's own main on this host, macOS or Linux, as any account
# and with no Docker: its arguments, the enrollment code and the Tailscale
# step for real, and the steps that need a Debian server as root stood in for
# by functions that log their names. Started by first_boot_test.sh.
#
# The copy it runs is first-boot.sh without its last line (`main "$@"`) and
# without the update script's writer (write_update_script, whose script the
# container scenarios and scripts/release/test_fermix_update.py run), with six
# fixed lines moved under this test's own directory, each asserted present
# exactly once. Its PATH holds only this test's bin directory: tailscale,
# apt-get, curl, gpg and systemctl are stand-ins, and every other command is
# a shim that logs its arguments and runs the host's own, so every command
# line the first boot starts is logged. Nothing reaches the network, a
# package manager, systemd, /run or another account.
#
# Cases: the flag absent (nothing of Tailscale runs); the key from
# TS_AUTHKEY; the code and the key typed at a terminal (script(1) gives the
# run a pty); a key without --tailscale, malformed keys, an OAuth client
# secret and no key without a terminal, each refused before any step; a host
# already on a tailnet, which goes on naming it without a key and is refused
# with one, or when its status names no tailnet; a host logged in with
# Tailscale down, refused; a signing key that is not Tailscale's; tailscaled
# that does not start; tailscale up failing before enrolling; each supported
# release's repository; --restore. After every run the key is nowhere under
# this test's directory, in no logged command line and in no command's
# environment. Then a host whose Fermix home exists, read through a stand-in
# for the engine account's fermix calls that answers home status --json in
# the engine's envelope: a candidate that has not begun to receive its move
# enrolling again (code in the environment, typed, or missing), its refused
# enrollment starting its service again once (a first one refused starting
# none), a home that
# runs (no code, at a terminal too, ending with the commands that remove it,
# or refused with them when given one), and every other home refused, with
# the commands that remove it when the home could be read.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
FIRST_BOOT=$(dirname "$here")/first-boot.sh
# Tailscale's package signing key, the one key its Debian and Ubuntu
# repositories serve: the SHA-1 of its v4 public-key packet, read from the
# keyring pkgs.tailscale.com serves for bookworm, trixie and noble alike.
PINNED=2596A99EAAB33821893C0A79458CA832957F5868
INVENTED_FPR=0123456789ABCDEF0123456789ABCDEF01234567
# Invented values in the real shapes; nothing here is a secret.
CODE=fxenroll1.InventedEnrollmentCodeForTheHostTestOnly0123456789
KEY=tskey-auth-kInvented1CNTRL-InventedSecretForTheHostTestOnly0123456789
ANSWERS=type_answers

die() {
  printf 'on_host: %s\n' "$1" >&2
  exit 1
}

# Each failure is a line in $FAILED, not a count in a variable: a check at
# the end of a pipeline (calls_are) runs in a subshell, whose variables are
# lost when it ends.
fail() {
  printf 'FAIL: %s\n' "$1"
  printf '%s\n' "$1" >>"$FAILED"
}

pass() {
  printf 'ok: %s\n' "$1"
}

check() {
  if eval "$1"; then pass "$2"; else fail "$2"; fi
}

command -v dash >/dev/null 2>&1 || die "dash is not installed; first-boot.sh runs under Debian's sh, which is dash."
command -v script >/dev/null 2>&1 || die "script(1) is not installed, so no run can be given a terminal."

T=$(mktemp -d "${TMPDIR:-/tmp}/first-boot-host.XXXXXX")
case "$T" in *[!A-Za-z0-9/._-]*) die "the test directory $T holds a character the copy's moved lines cannot." ;; esac
# T is this run's own directory, made just above; nothing else is removed.
cleanup() {
  case "$T" in */first-boot-host.*) rm -rf "$T" ;; esac
}
trap cleanup EXIT

BIN=$T/bin
STATE=$T/state
LOG=$T/calls.log
ARGV=$T/argv.log
FAILED=$T/failed
OUT=$T/out
ERR=$T/err
COPY=$T/first-boot.sh
KEYRING=$T/keyrings/tailscale-archive-keyring.gpg
SOURCE=$T/sources.list.d/tailscale.list

# -- the copy --------------------------------------------------------------

# Replaces the one line of $1 equal to $2 with $3.
move_line() {
  count=$(grep -cxF -- "$2" "$1" || true)
  [ "$count" -eq 1 ] || die "first-boot.sh holds the line '$2' $count times, not once."
  OLD=$2 NEW=$3 awk '$0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; next } { print }' "$1" >"$1.moved"
  mv "$1.moved" "$1"
}

# first-boot.sh without write_update_script, from its first line to the
# brace that closes it.
drop_update_writer() {
  awk '
    state == 0 && $0 == "write_update_script() {" { state = 1; next }
    state == 1 { if ($0 == "  } | write_file \"$UPDATE_SCRIPT\" 0755") state = 2; next }
    state == 2 { if ($0 != "}") exit 4; state = 3; next }
    { print }
    END { if (state != 3) exit 3 }'
}

# The steps that need a Debian server as root: each logs its name, and says
# so when the key file tailscale up read is still there. enroll and
# start_service are first-boot.sh's own, through the engine account's stand-in.
stand_in_steps() {
  cat <<EOF

# -- stood in for by on_host.sh ---------------------------------------------
os_field() {
  case "\$1" in
    ID) cat '$STATE/os-id' ;;
    VERSION_ID) cat '$STATE/os-version' ;;
  esac
}

stand_in() {
  printf 'step %s\n' "\$1" >>'$LOG'
  if [ -f '$STATE/up-key-path' ] && [ -e "\$(cat '$STATE/up-key-path')" ]; then
    printf 'the key file is still there at step %s\n' "\$1" >>'$LOG'
  fi
}

# A fermix verb as the engine account: logged; home status --json prints
# state/home-status.json and exits with state/home-status-exit; a verb whose
# arguments are a line in state/fermix-fails exits 1.
as_engine() {
  printf 'fermix %s\n' "\$*" >>'$LOG'
  if fermix_fails "\$*"; then
    echo "fermix \$1: (test) it stopped" >&2
    return 1
  fi
  [ "\$*" = 'home status --json' ] || return 0
  /bin/cat '$STATE/home-status.json'
  return "\$(/bin/cat '$STATE/home-status-exit')"
}

fermix_fails() {
  [ -f '$STATE/fermix-fails' ] || return 1
  while IFS= read -r failing; do
    if [ "\$1" = "\$failing" ]; then return 0; fi
  done <'$STATE/fermix-fails'
  return 1
}
EOF
  for step in check_host block_metadata add_swap install_fermix schedule_updates \
    create_engine_user install_browser await_enrollment print_restore_steps; do
    printf '%s() { stand_in %s; }\n' "$step" "$step"
  done
}

build_copy() {
  [ "$(tail -n 1 "$FIRST_BOOT")" = 'main "$@"' ] || die "first-boot.sh no longer ends with main \"\$@\"."
  sed '$d' "$FIRST_BOOT" | drop_update_writer >"$COPY" ||
    die "first-boot.sh no longer holds write_update_script as this test cuts it out."
  move_line "$COPY" 'ACCOUNT_HOME=/home/fermix' "ACCOUNT_HOME=$T/home/fermix"
  move_line "$COPY" 'RUN_DIR=/run/fermix' "RUN_DIR=$T/run/fermix"
  move_line "$COPY" 'TAILSCALE_KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg' "TAILSCALE_KEYRING=$KEYRING"
  move_line "$COPY" 'TAILSCALE_SOURCE=/etc/apt/sources.list.d/tailscale.list' "TAILSCALE_SOURCE=$SOURCE"
  move_line "$COPY" '  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "  PATH=$BIN"
  # shellcheck disable=SC2016 # the line as first-boot.sh holds it, unexpanded
  move_line "$COPY" '  WORK=$(mktemp -d /run/fermix-always-on.XXXXXX)' "  WORK=\$(mktemp -d $T/run/fermix-always-on.XXXXXX)"
  stand_in_steps >>"$COPY"
  printf 'main "$@"\n' >>"$COPY"
  dash -n "$COPY" || die "the copy of first-boot.sh does not parse."
}

# -- the commands it runs ----------------------------------------------------

write_exe() {
  cat >"$1"
  chmod 0755 "$1"
}

# What every command records: its arguments, and whether TS_AUTHKEY reached
# its environment.
record_lines() {
  cat <<EOF
printf '%s %s\n' "\${0##*/}" "\$*" >>'$ARGV'
if [ -n "\${TS_AUTHKEY+set}" ]; then printf 'TS_AUTHKEY reached %s\n' "\${0##*/}" >>'$ARGV'; fi
EOF
}

# A host command, run through a shim that records it. mv takes GNU's -T,
# which the first boot passes and macOS's mv lacks: with a plain file at the
# destination, as here, it is the same move.
make_shims() {
  for tool in cat chmod cut grep head mkdir mktemp mv rm sed stty tr; do
    real=$(PATH=/usr/bin:/bin command -v "$tool") || die "the host has no $tool."
    {
      echo '#!/bin/sh'
      record_lines
      # shellcheck disable=SC2016 # a line of the shim, expanded when it runs
      if [ "$tool" = mv ]; then echo 'if [ "${1-}" = -fT ]; then shift; set -- -f "$@"; fi'; fi
      echo "exec $real \"\$@\""
    } | write_exe "$BIN/$tool"
  done
}

# apt-get and systemctl log their arguments; a call whose arguments are the
# line in state/<tool>-fails exits 1, as a unit that does not start does.
make_stand_ins() {
  printf 'Invented bytes standing in for a signing key; gpg here is a stand-in.\n' >"$T/served-key.gpg"
  for tool in apt-get systemctl; do
    {
      echo '#!/bin/sh'
      record_lines
      cat <<EOF
printf '$tool %s\n' "\$*" >>'$LOG'
if [ -f '$STATE/$tool-fails' ] && [ "\$*" = "\$(/bin/cat '$STATE/$tool-fails')" ]; then
  echo "$tool stand-in: (test) \$* failed" >&2
  exit 1
fi
EOF
    } | write_exe "$BIN/$tool"
  done
  { echo '#!/bin/sh'; record_lines; stand_in_curl; } | write_exe "$BIN/curl"
  { echo '#!/bin/sh'; record_lines; stand_in_id; } | write_exe "$BIN/id"
  { echo '#!/bin/sh'; record_lines; stand_in_gpg; } | write_exe "$BIN/gpg"
  { echo '#!/bin/sh'; record_lines; stand_in_tailscale; } | write_exe "$BIN/tailscale"
}

# curl: pkgs.tailscale.com's keyring for each supported release answers the
# invented key bytes; any other address is refused, as one that does not
# resolve is.
stand_in_curl() {
  cat <<EOF
url="" out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    --proto) shift 2 ;;
    https://*) url=\$1; shift ;;
    -*) shift ;;
    *) echo "curl stand-in: unexpected argument" >&2; exit 2 ;;
  esac
done
printf 'curl GET %s\n' "\$url" >>'$LOG'
case "\$url" in
  https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | \\
    https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg | \\
    https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg)
    /bin/cat '$T/served-key.gpg' >"\$out" ;;
  *) exit 6 ;;
esac
EOF
}

# id: the engine account is uid 1001; there is no other account.
stand_in_id() {
  cat <<'EOF'
if [ "$*" = '-u fermix' ]; then echo 1001; exit 0; fi
echo "id: '$*': no such user" >&2
exit 1
EOF
}

# gpg --show-keys --with-colons FILE: one primary key, with a subkey, for each
# fingerprint in state/gpg-primary-keys, in gpg's colon format.
stand_in_gpg() {
  cat <<EOF
for arg in "\$@"; do file=\$arg; done
case " \$* " in
  *" --show-keys "*) ;;
  *) echo "gpg stand-in: expected --show-keys" >&2; exit 2 ;;
esac
case " \$* " in
  *" --with-colons "*) ;;
  *) echo "gpg stand-in: expected --with-colons" >&2; exit 2 ;;
esac
/usr/bin/cmp -s "\$file" '$T/served-key.gpg' || { echo "gpg: no valid OpenPGP data found." >&2; exit 2; }
while IFS= read -r fpr; do
  printf 'pub:-:4096:1:%s:1587070209:::-:::scESC::::::23::0:\n' "\$fpr"
  printf 'fpr:::::::::%s:\n' "\$fpr"
  printf 'uid:-::::1587070209::0000::Invented signer <signer@example.invalid>::::::::::0:\n'
  printf 'sub:-:4096:1:FEDCBA9876543210:1587070209::::::e::::::23:\n'
  printf 'fpr:::::::::FEDCBA9876543210FEDCBA9876543210FEDCBA98:\n'
done <'$STATE/gpg-primary-keys'
EOF
}

# tailscale: its daemon's state is the word in state/tailscale-state, and a
# daemon that does not answer without it; the tailnet it is logged in to is
# the name in state/tailnet-name (CurrentTailnet null without it). status and
# ip answer from them and log nothing, as reads; status --json keeps the real
# one's shape around them (nested objects, and names under other keys). up
# records the key file it was named (its path, its mode, a checksum of what
# it holds) and joins the invented tailnet, unless state/up-fails exists.
stand_in_tailscale() {
  cat <<EOF
state='$STATE'
case "\${1-}" in
  status)
    if [ ! -f "\$state/tailscale-state" ]; then
      echo "failed to connect to local tailscaled; it doesn't appear to be running" >&2
      exit 1
    fi
    tailnet=null
    if [ -f "\$state/tailnet-name" ]; then
      tailnet=\$(printf '{\n    "Name": "%s",\n    "MagicDNSSuffix": "tail0invented.ts.net",\n    "MagicDNSEnabled": true\n  }' "\$(/bin/cat "\$state/tailnet-name")")
    fi
    printf '{\n  "Version": "1.90.0-invented",\n  "BackendState": "%s",\n  "Self": {\n    "HostName": "invented-server",\n    "Location": {\n      "Country": "Invented"\n    }\n  },\n  "MagicDNSSuffix": "tail0invented.ts.net",\n  "CurrentTailnet": %s,\n  "User": {\n    "1": {\n      "LoginName": "owner@invented.example",\n      "DisplayName": "Invented Owner"\n    }\n  }\n}\n' \
      "\$(/bin/cat "\$state/tailscale-state")" "\$tailnet"
    exit 0
    ;;
  ip)
    [ "\$(/bin/cat "\$state/tailscale-state" 2>/dev/null)" = Running ] || { echo "no current Tailscale IPs" >&2; exit 1; }
    echo 100.88.12.34
    exit 0
    ;;
esac
printf 'tailscale %s\n' "\$*" >>'$LOG'
[ "\${1-}" = up ] || exit 0
key=""
for arg in "\$@"; do
  case "\$arg" in --auth-key=file:*) key=\${arg#--auth-key=file:} ;; esac
done
[ -n "\$key" ] || { echo "tailscale stand-in: up without --auth-key=file:" >&2; exit 2; }
printf '%s\n' "\$key" >"\$state/up-key-path"
/bin/ls -l "\$key" | /usr/bin/cut -c1-10 >"\$state/up-key-mode"
/usr/bin/cksum <"\$key" | /usr/bin/cut -d' ' -f1 >"\$state/up-key-cksum"
if [ -f "\$state/up-fails" ]; then
  echo "backend error: invalid key: API key does not exist" >&2
  exit 1
fi
echo Running >"\$state/tailscale-state"
echo invented.example >"\$state/tailnet-name"
EOF
}

# -- runs ----------------------------------------------------------------------

# A fresh host: Debian 13, no Tailscale daemon, Tailscale's key served, and
# nothing left of an earlier run.
fresh_host() {
  /bin/rm -rf "${STATE:?}" "${T:?}/run" "${T:?}/home" "${T:?}/keyrings" "${T:?}/sources.list.d"
  /bin/mkdir -p "$STATE" "$T/run" "$T/home/fermix" "$T/keyrings" "$T/sources.list.d"
  release debian 13
  printf '%s\n' "$PINNED" >"$STATE/gpg-primary-keys"
}

release() {
  printf '%s\n' "$1" >"$STATE/os-id"
  printf '%s\n' "$2" >"$STATE/os-version"
}

reset_logs() {
  : >"$LOG"
  : >"$ARGV"
  : >"$OUT"
  : >"$ERR"
}

# Runs the copy with no terminal: in a session of its own, so /dev/tty opens
# nothing even from a developer's terminal, and with a clean environment that
# holds only the VAR=value arguments before the command. stdout in $OUT,
# stderr in $ERR, the exit status in $STATUS.
run() {
  reset_logs
  set +e
  perl -MPOSIX -e '
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) { POSIX::setsid() or die "setsid: $!"; exec(@ARGV) or die "exec: $!" }
    waitpid($pid, 0);
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);' -- env -i PATH=/usr/bin:/bin "$@" \
    </dev/null >"$OUT" 2>"$ERR"
  STATUS=$?
  set -e
}

# Types $1 once its prompt is on the screen, then $2 once its prompt is, so
# an answer that came back would mean echo was on. The pipe stays open until
# the last answer has been read (a line follows its prompt): script(1) sends
# the end of its input on to the pty, which can drop a line not yet read.
type_answers() {
  key_prompt='Tailscale auth key (it is not shown as you type): '
  answer 'Enrollment code from Fermix (it is not shown as you type): ' "$1"
  answer "$key_prompt" "$2"
  wait_for "a line after the key's prompt" "sed -n '/$key_prompt/,\$p' '$OUT' | sed -n 2p | grep -q ."
}

# Types the code $1 alone, for a run that asks for no key.
type_code() {
  answer 'Enrollment code from Fermix (it is not shown as you type): ' "$1"
  wait_for "a line after the code's prompt" "sed -n '/Enrollment code from Fermix/,\$p' '$OUT' | sed -n 2p | grep -q ."
}

answer() {
  wait_for "the prompt '$1'" "grep -qF -- '$1' '$OUT'"
  printf '%s\n' "$2"
}

# Waits, at most 60 s, until the command $2 succeeds.
wait_for() {
  tries=0
  until eval "$2"; do
    tries=$((tries + 1))
    if [ "$tries" -gt 600 ]; then
      echo "on_host: $1 did not appear within 60 s" >&2
      return 1
    fi
    sleep 0.1
  done
}

# Runs the copy at a terminal: script(1) gives it a pty and reads what is
# typed from a pipe, by the function in ANSWERS (the code and then the key
# unless it says otherwise). Output and stderr both land in $OUT, without the pty's
# carriage returns.
run_at_terminal() {
  reset_logs
  for arg in "$@"; do
    case "$arg" in *[[:space:]]* | '') die "a terminal run's arguments are words, since script -c takes one string." ;; esac
  done
  set +e
  if [ "$(uname -s)" = Darwin ]; then
    "$ANSWERS" "$CODE" "$KEY" | script -q /dev/null env -i PATH=/usr/bin:/bin "$@" >"$OUT" 2>&1
  else
    "$ANSWERS" "$CODE" "$KEY" | script -qefc "env -i PATH=/usr/bin:/bin $*" /dev/null >"$OUT" 2>&1
  fi
  STATUS=$?
  set -e
  tr -d '\r' <"$OUT" >"$OUT.clean"
  mv "$OUT.clean" "$OUT"
}

# -- checks --------------------------------------------------------------------

calls_are() {
  sed "s|$T/run/fermix-always-on\.[A-Za-z0-9]*|WORK|g" "$LOG" >"$T/calls.seen"
  cat >"$T/calls.expected"
  if cmp -s "$T/calls.seen" "$T/calls.expected"; then
    pass "$1"
  else
    fail "$1"
    diff "$T/calls.expected" "$T/calls.seen" | sed 's/^/    /' || true
  fi
}

stopped_with() {
  printf 'fermix always-on: %s\n' "$1" >"$T/stderr.expected"
  if [ "$STATUS" -ne 0 ] && cmp -s "$ERR" "$T/stderr.expected"; then
    pass "$2"
  else
    fail "$2 (exit $STATUS)"
    sed 's/^/    stderr: /' "$ERR"
  fi
}

# The key is nowhere under the test's directory (the copy's run and work
# directories, every log, every output), in no command line and in no
# command's environment, and no work directory is left.
key_left_nowhere() {
  check "! grep -rqF -- '$KEY' '$T'" "$1: the key is in no file, output or logged command line"
  check "! grep -q '^TS_AUTHKEY reached' '$ARGV'" "$1: no command it starts has TS_AUTHKEY in its environment"
  check "[ -z \"\$(find '$T/run' -name 'fermix-always-on.*')\" ]" "$1: no work directory is left"
}

refused_before_any_step() {
  check "! grep -qv '^step check_host\$' '$LOG'" "$1: nothing runs after the host check"
}

# What enroll and start_service run as the engine account.
ENROLLS="fermix home enroll --code-file $T/run/fermix/enroll.code"
STARTS="fermix service install --home $T/home/fermix/.fermix"

NO_TAILSCALE_STEPS="step check_host
step block_metadata
step add_swap
step install_fermix
step schedule_updates
step create_engine_user
$ENROLLS
$STARTS
step install_browser
step await_enrollment"

tailscale_calls() {
  cat <<EOF
apt-get -qq update
apt-get -qq -y install --no-install-recommends ca-certificates curl gpg
curl GET https://pkgs.tailscale.com/stable/$1.noarmor.gpg
apt-get -qq update
apt-get -qq -y install --no-install-recommends tailscale
systemctl enable --now tailscaled.service
tailscale up --auth-key=file:WORK/tailscale.authkey --timeout=2m
EOF
}

joined_calls() {
  printf 'step check_host\nstep block_metadata\nstep add_swap\nstep install_fermix\nstep schedule_updates\nstep create_engine_user\n'
  tailscale_calls debian/trixie
  printf '%s\n%s\nstep install_browser\nstep await_enrollment\n' "$ENROLLS" "$STARTS"
}

key_cksum() {
  printf '%s' "$KEY" | cksum | cut -d' ' -f1
}

the_key_reached_tailscale_up() {
  check "[ \"\$(cat '$STATE/up-key-cksum')\" = \"\$(key_cksum)\" ]" "$1: tailscale up read the key from its file"
  check "[ \"\$(cat '$STATE/up-key-mode')\" = '-rw-------' ]" "$1: the key file is 0600"
  check "! grep -q 'the key file is still there' '$LOG'" "$1: the key file is removed before the next step"
  check "[ -s '$STATE/up-key-path' ] && [ ! -e \"\$(cat '$STATE/up-key-path')\" ]" "$1: the key file is gone once the run ends"
}

# -- cases ---------------------------------------------------------------------

without_the_flag() {
  fresh_host
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY"
  check "[ $STATUS -eq 0 ]" "without --tailscale the first boot succeeds (exit $STATUS)"
  printf '%s\n' "$NO_TAILSCALE_STEPS" | calls_are "without --tailscale nothing of Tailscale runs: no apt source, no package, no tailscale"
  check "! grep -qi tailscale '$OUT' '$ARGV'" "without --tailscale nothing says or touches Tailscale"
}

key_from_the_environment() {
  fresh_host
  run TS_AUTHKEY="$KEY" FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
  check "[ $STATUS -eq 0 ]" "a server joins the tailnet with the key in TS_AUTHKEY (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT" "$ERR"
  joined_calls | calls_are "Tailscale is installed from its repository and up runs with the key file, after the account and before enrolling"
  the_key_reached_tailscale_up "TS_AUTHKEY"
  key_left_nowhere "TS_AUTHKEY"
  check "cmp -s '$KEYRING' '$T/served-key.gpg' && [ \"\$(ls -l '$KEYRING' | cut -c1-10)\" = '-rw-r--r--' ]" \
    "the checked key is apt's keyring for the source, readable"
  printf '%s\n' "# Fermix Always On: Tailscale's packages for debian trixie, signed by the key $PINNED, which the first boot checked." \
    "deb [signed-by=$KEYRING] https://pkgs.tailscale.com/stable/debian trixie main" \
    >"$T/source.expected"
  check "cmp -s '$SOURCE' '$T/source.expected'" "the apt source names Tailscale's repository and only that keyring"
  check "grep -qxF '==> This server is on your tailnet at 100.88.12.34' '$OUT'" "it says the server's tailnet address"
}

key_at_the_terminal() {
  fresh_host
  run_at_terminal dash "$COPY" --tailscale
  check "[ $STATUS -eq 0 ]" "a server joins the tailnet with the code and the key typed at the terminal (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
  joined_calls | calls_are "the typed key takes the same steps"
  the_key_reached_tailscale_up "typed"
  key_left_nowhere "typed"
  check "! grep -qF -- '$CODE' '$OUT' '$LOG' '$ARGV'" "the typed code is in no output and no command line"
  check "[ \"\$(grep -n 'Enrollment code from Fermix' '$OUT' | cut -d: -f1)\" -lt \"\$(grep -n 'Tailscale auth key (it' '$OUT' | cut -d: -f1)\" ]" \
    "it asks for the code first, then the key"
}

refusals() {
  fresh_host
  run TS_AUTHKEY="$KEY" FERMIX_ENROLL_CODE="$CODE" dash "$COPY"
  stopped_with "TS_AUTHKEY holds a Tailscale auth key, but --tailscale was not given: add --tailscale to join this server to your tailnet, or leave TS_AUTHKEY out." \
    "a key without --tailscale is refused, without echoing it"
  check "[ ! -s '$LOG' ]" "and before even the host check"
  key_left_nowhere "a key without --tailscale"

  oauth="That is a Tailscale OAuth client secret, not an auth key: create an auth key in Tailscale's admin console (Settings, Keys) and run this again."
  for bad in "tskex-auth-kInvented1CNTRL-InventedSecret0123456789|That is not a Tailscale auth key, which starts with tskey-. Create one in Tailscale's admin console and run this again." \
    "tskey-client-kInvented1CNTRL-InventedClientSecret0123456789|$oauth" \
    "tskey-client-kInvented1CNTRL-InventedClientSecret0123456789?ephemeral=false&preauthorized=true|$oauth" \
    "${KEY}?ephemeral=false|The Tailscale auth key holds a character no auth key has. Copy it again from Tailscale's admin console." \
    "tskey-auth-short|The Tailscale auth key is not between 20 and 200 characters long. Copy it again from Tailscale's admin console." \
    "${KEY}$(printf '%140s' '' | tr ' ' A)|The Tailscale auth key is not between 20 and 200 characters long. Copy it again from Tailscale's admin console."; do
    fresh_host
    run TS_AUTHKEY="${bad%%|*}" FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
    stopped_with "${bad#*|}" "a malformed key is refused: ${bad#*|}"
    refused_before_any_step "a malformed key"
    check "! grep -rqF -- '${bad%%|*}' '$T'" "a malformed key is in no file, output or command line"
  done

  fresh_host
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
  stopped_with "No Tailscale auth key: run this in a terminal, which asks for it, or pass it in TS_AUTHKEY." \
    "no key and no terminal is refused"
  refused_before_any_step "no key"

  fresh_host
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscle
  stopped_with "An option was not recognised. This script takes --restore, --snapshot-bucket, --snapshot-region, --version and --tailscale." \
    "an unknown option names --tailscale among the options"
}

# A host whose tailscaled answers the state $1, logged in to the tailnet $2
# when one is named.
tailscale_host() {
  fresh_host
  printf '%s\n' "$1" >"$STATE/tailscale-state"
  if [ -n "${2-}" ]; then printf '%s\n' "$2" >"$STATE/tailnet-name"; fi
}

already_on_a_tailnet() {
  tailscale_host Running invented.example
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
  check "[ $STATUS -eq 0 ]" "a server already on a tailnet goes on with no key and no terminal (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT" "$ERR"
  printf '%s\n' "$NO_TAILSCALE_STEPS" | calls_are "it installs nothing of Tailscale and logs in again nowhere"
  check "grep -qxF '==> This server is already on the tailnet invented.example, so Tailscale is not installed or logged in again' '$OUT'" \
    "it says so, naming the tailnet"
  check "grep -qxF '==> This server is on your tailnet at 100.88.12.34' '$OUT'" "and names its tailnet address"

  # A key given for a host on a tailnet would be dropped without a word, and
  # the server would stay on a tailnet that may not be the owner's.
  tailscale_host Running invented.example
  run TS_AUTHKEY="$KEY" FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
  stopped_with "This server is already on the tailnet invented.example: leave TS_AUTHKEY out to keep it, or, if that tailnet is not yours, run sudo tailscale logout and run this again." \
    "a key given for a server already on a tailnet is refused, naming that tailnet"
  refused_before_any_step "a key for a server on a tailnet"
  key_left_nowhere "a key for a server on a tailnet"

  tailscale_host Running
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
  stopped_with "Tailscale says this server is on a tailnet, but its status names no tailnet: update Tailscale and run this again." \
    "a server on a tailnet its status does not name is refused"
  refused_before_any_step "a tailnet with no name"
}

# Logged in, but tailscale down: a key would log the server in again (and
# spend a one-off key), so it stops with or without one.
tailscale_down() {
  for given in with without; do
    key=""
    if [ "$given" = with ]; then key=$KEY; fi
    tailscale_host Stopped invented.example
    run TS_AUTHKEY="$key" FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
    stopped_with "This server is logged in to a tailnet but Tailscale is down: run sudo tailscale up and run this again." \
      "a server whose Tailscale is down is refused ($given a key)"
    refused_before_any_step "Tailscale down"
    key_left_nowhere "Tailscale down"
  done
}

tailscaled_does_not_start() {
  fresh_host
  printf 'enable --now tailscaled.service\n' >"$STATE/systemctl-fails"
  run TS_AUTHKEY="$KEY" FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
  check "[ $STATUS -eq 1 ] && [ \"\$(tail -n 1 '$ERR')\" = 'fermix always-on: systemctl could not start tailscaled.service, so this server cannot join your tailnet; its message above says why.' ]" \
    "a tailscaled that does not start stops the first boot with one sentence (exit $STATUS)"
  [ "$STATUS" -eq 1 ] || sed 's/^/    /' "$OUT" "$ERR"
  check "! grep -q '^tailscale up \|^fermix home enroll' '$LOG'" "before tailscale up and before enrolling"
  key_left_nowhere "a tailscaled that does not start"
}

not_tailscales_key() {
  for keys in "$INVENTED_FPR" "$PINNED
$INVENTED_FPR"; do
    fresh_host
    printf '%s\n' "$keys" >"$STATE/gpg-primary-keys"
    run TS_AUTHKEY="$KEY" FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
    stopped_with "The key https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg serves is not Tailscale's package signing key alone ($PINNED), so Tailscale is not installed." \
      "a served key that is not Tailscale's alone is refused ($(printf '%s' "$keys" | tr '\n' ' '))"
    check "! grep -q 'install --no-install-recommends tailscale\|^tailscale \|^fermix home enroll' '$LOG'" \
      "and nothing is installed from it, joined or enrolled"
    check "[ ! -e '$KEYRING' ] && [ ! -e '$SOURCE' ]" "and apt is given no keyring and no source"
    key_left_nowhere "a key that is not Tailscale's"
  done
}

up_fails() {
  fresh_host
  : >"$STATE/up-fails"
  run TS_AUTHKEY="$KEY" FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
  check "[ $STATUS -eq 1 ] && [ \"\$(tail -n 1 '$ERR')\" = \"fermix always-on: tailscale up did not join this server to your tailnet, so the first boot stops here; its message above says why. A key that is used up, expired or revoked is refused: create a new one and run this again. If it printed a link to approve this server, approve it there and run this again without a key.\" ]" \
    "a tailscale up that fails stops the first boot with one sentence (exit $STATUS)"
  [ "$STATUS" -eq 1 ] || sed 's/^/    /' "$OUT" "$ERR"
  check "grep -q '^tailscale up ' '$LOG' && ! grep -q '^fermix home enroll' '$LOG'" "before enrolling"
  check "[ -s '$STATE/up-key-path' ] && [ ! -e \"\$(cat '$STATE/up-key-path')\" ]" "the key file is gone after the failure"
  key_left_nowhere "a failed tailscale up"
}

each_release() {
  for rel in "debian 12 debian/bookworm debian bookworm" "debian 13 debian/trixie debian trixie" \
    "ubuntu 24.04 ubuntu/noble ubuntu noble"; do
    # shellcheck disable=SC2086 # the words of one release
    set -- $rel
    fresh_host
    release "$1" "$2"
    run TS_AUTHKEY="$KEY" FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
    check "[ $STATUS -eq 0 ] && grep -qxF 'curl GET https://pkgs.tailscale.com/stable/$3.noarmor.gpg' '$LOG' && grep -qxF 'deb [signed-by=$KEYRING] https://pkgs.tailscale.com/stable/$4 $5 main' '$SOURCE'" \
      "$1 $2 takes Tailscale's $4 $5 repository"
  done
}

restore_host() {
  fresh_host
  run TS_AUTHKEY="$KEY" dash "$COPY" --restore --tailscale
  check "[ $STATUS -eq 0 ]" "a restore host joins the tailnet too (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT" "$ERR"
  {
    printf 'step check_host\nstep block_metadata\nstep add_swap\nstep install_fermix\nstep schedule_updates\nstep create_engine_user\n'
    tailscale_calls debian/trixie
    printf 'step install_browser\nstep print_restore_steps\n'
  } | calls_are "it joins after the account and before printing the restore steps, and enrolls nothing"
  key_left_nowhere "a restore host"
}

# -- a host whose Fermix home exists -------------------------------------------

HOME_DIR_MOVED=$T/home/fermix/.fermix
REMOVE="to set this server up again, which deletes that home, run sudo -H -u fermix env XDG_RUNTIME_DIR=/run/user/1001 /usr/bin/fermix service uninstall, then sudo rm -rf $HOME_DIR_MOVED, then this command again."

# A host with a Fermix home, whose fermix home status --json answers the role
# $1, the candidate's phase $2 (no move when empty) and the moved marker's
# $3 (none when empty), in the engine's own one-line envelope.
home_is() {
  fresh_host
  /bin/mkdir -p "$HOME_DIR_MOVED"
  move=null
  moved=null
  if [ -n "${2-}" ]; then move="{\"candidate\":null,\"phase\":\"$2\",\"sentence\":\"An invented sentence with \\\"quotes\\\" in it.\"}"; fi
  if [ -n "${3-}" ]; then moved="{\"epoch\":4,\"moved_at\":\"2026-11-05T20:00:00Z\",\"to\":\"$3\"}"; fi
  printf '{"ok":true,"result":{"candidates":[],"desktops":[],"disk":null,"enrollment":null,"epoch":null,"move":%s,"moved":%s,"primary":null,"primary_home":null,"primary_missing":null,"role":"%s","secrets_missing":[],"snapshots":{"configured":false,"interval_hours":6,"next_run_at":null,"recipient_set":false,"running":false,"sentence":"An invented snapshots sentence.","targets":[]},"summary":{"action":null,"detail":{},"key":"InventedKey","notice":null,"outcome":"done","sentence":"An invented summary sentence.","state":"candidate"},"update_ceiling":null,"version":"1.2.3","webhooks":[]},"schema_version":1}\n' \
    "$move" "$moved" "$1" >"$STATE/home-status.json"
  echo 0 >"$STATE/home-status-exit"
}

# A host whose fermix home status --json refuses with the code $1 and the
# sentence $2.
home_refuses() {
  fresh_host
  /bin/mkdir -p "$HOME_DIR_MOVED"
  printf '{"error":{"code":"%s","sentence":"%s"},"ok":false,"schema_version":1}\n' "$1" "$2" >"$STATE/home-status.json"
  echo 1 >"$STATE/home-status-exit"
}

refused_after_reading_the_home() {
  printf 'step check_host\nfermix home status --json\n' | calls_are "$1: nothing runs after the home is read"
}

REENROLLED_STEPS="step check_host
fermix home status --json
step block_metadata
step add_swap
step install_fermix
step schedule_updates
step create_engine_user
fermix service uninstall
$ENROLLS
$STARTS
step install_browser
step await_enrollment"

# A candidate that has not begun to receive its move (enrolling, failed,
# expired, or enrolled and waiting) enrolls again with a new code: the engine
# stopped first, then enrolled, started and waited for as on a fresh host.
enrolls_again() {
  for phase in enrolling failed expired enrolled; do
    home_is candidate "$phase"
    run FERMIX_ENROLL_CODE="$CODE" dash "$COPY"
    check "[ $STATUS -eq 0 ]" "a candidate $phase enrolls again with the new code (exit $STATUS)"
    [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT" "$ERR"
    printf '%s\n' "$REENROLLED_STEPS" | calls_are "$phase: the home is read before anything is installed, and Fermix stopped before it enrolls"
    check "[ \"\$(cat '$T/run/fermix/enroll.code')\" = '$CODE' ]" "$phase: the new code is written for the enrollment"
    check "grep -qxF '==> Done. Open Always On in Fermix to review this server, then move to it.' '$OUT'" \
      "$phase: it ends as a first enrollment does"
  done

  for phase in failed enrolled; do
    home_is candidate "$phase"
    ANSWERS=type_code
    run_at_terminal dash "$COPY"
    ANSWERS=type_answers
    check "[ $STATUS -eq 0 ] && grep -qF 'Enrollment code from Fermix' '$OUT'" \
      "at a terminal, a candidate $phase asks for the new code (exit $STATUS)"
    [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT"
    printf '%s\n' "$REENROLLED_STEPS" | calls_are "$phase at a terminal: the same steps"
    check "! grep -qF -- '$CODE' '$OUT' '$LOG' '$ARGV'" "$phase at a terminal: the typed code is in no output and no command line"
  done

  for phase in expired enrolled; do
    home_is candidate "$phase"
    run dash "$COPY"
    stopped_with "No enrollment code: run this in a terminal, which asks for it, or pass it in FERMIX_ENROLL_CODE." \
      "a candidate $phase, with no code and no terminal, is refused"
    refused_after_reading_the_home "no code for a candidate $phase"
  done

  home_is candidate failed
  printf 'service uninstall\n' >"$STATE/fermix-fails"
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY"
  check "[ $STATUS -eq 1 ] && [ \"\$(tail -n 1 '$ERR')\" = 'fermix always-on: fermix service uninstall stopped, so this server is not enrolled again; its message above says why.' ]" \
    "a Fermix that does not stop stops the first boot with one sentence (exit $STATUS)"
  check "! grep -q '^fermix home enroll' '$LOG'" "before it enrolls"

  # A refused enrollment (an old code past its thirty minutes, or the code
  # the server enrolled with) leaves the home as it was, so a re-run starts
  # the service stop_engine took down again, once, with the enrollment the
  # server had, then fails saying so.
  home_is candidate enrolled
  printf '%s\n' "${ENROLLS#fermix }" >"$STATE/fermix-fails"
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY"
  check "[ $STATUS -eq 1 ] && [ \"\$(tail -n 1 '$ERR')\" = 'fermix always-on: fermix home enroll stopped, so this server keeps the enrollment it had and runs again; its message above says why.' ]" \
    "a re-run whose enrollment is refused starts the server again and says so (exit $STATUS)"
  [ "$STATUS" -eq 1 ] || sed 's/^/    /' "$OUT" "$ERR"
  printf 'step check_host\nfermix home status --json\nstep block_metadata\nstep add_swap\nstep install_fermix\nstep schedule_updates\nstep create_engine_user\nfermix service uninstall\n%s\n%s\n' "$ENROLLS" "$STARTS" |
    calls_are "after the refusal its service is installed and started again, then nothing else runs"

  home_is candidate enrolled
  printf '%s\n%s\n' "${ENROLLS#fermix }" "${STARTS#fermix }" >"$STATE/fermix-fails"
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY"
  check "[ $STATUS -eq 1 ] && [ \"\$(tail -n 1 '$ERR')\" = 'fermix always-on: fermix home enroll stopped, and fermix service install did not start this server again with the enrollment it had; their messages above say why.' ]" \
    "a service that does not start again after the refusal stops the run with its own sentence (exit $STATUS)"
  [ "$STATUS" -eq 1 ] || sed 's/^/    /' "$OUT" "$ERR"
  check "[ \"\$(grep -c '^fermix service install' '$LOG')\" -eq 1 ] && [ \"\$(tail -n 1 '$LOG')\" = '$STARTS' ]" \
    "and it tries the service once, last"

  # A first enrollment stopped nothing, so a refusal fails as it always did.
  fresh_host
  printf '%s\n' "${ENROLLS#fermix }" >"$STATE/fermix-fails"
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY"
  check "[ $STATUS -eq 1 ] && [ \"\$(tail -n 1 '$ERR')\" = 'fermix always-on: fermix home enroll stopped; its message above says why.' ]" \
    "a first enrollment that is refused stops the first boot with one sentence (exit $STATUS)"
  printf 'step check_host\nstep block_metadata\nstep add_swap\nstep install_fermix\nstep schedule_updates\nstep create_engine_user\n%s\n' "$ENROLLS" |
    calls_are "and starts no service after it"
}

# Answers nothing, for a terminal run that asks for nothing.
no_answers() {
  :
}

# A home that runs (the primary, or a candidate receiving its move), run
# again with no code, is started as it is, and the run ends saying what it is
# and the commands that remove it, as the refusal does; given a code, it is
# refused, saying the same.
home_that_runs() {
  for case in "candidate receiving|This server is receiving its move" \
    "candidate activating|This server is receiving its move" \
    "primary |Fermix runs on this server as your primary"; do
    home=${case%%|*}
    # shellcheck disable=SC2086 # the role and the phase
    home_is $home
    run dash "$COPY"
    printf '==> Done. Fermix runs from the home it already had.\n==> %s: %s\n' "${case#*|}" "$REMOVE" >"$T/end.expected"
    check "[ $STATUS -eq 0 ] && tail -n 2 '$OUT' | cmp -s - '$T/end.expected'" \
      "a $home home, run again with no code, runs as it is, then says what it is and the commands that remove it (exit $STATUS)"
    [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT" "$ERR"
    printf 'step check_host\nfermix home status --json\nstep block_metadata\nstep add_swap\nstep install_fermix\nstep schedule_updates\nstep create_engine_user\n%s\nstep install_browser\n' "$STARTS" |
      calls_are "$home: it reads the home, stops nothing, enrolls nothing and waits for nothing"
  done

  # The owner who reuses the server after Restore here runs the command at
  # a terminal: nothing asks for a code, and the run ends the same way. The
  # pty echoes the end of the empty input as ^D and two backspaces, wherever
  # it lands.
  home_is primary
  ANSWERS=no_answers
  run_at_terminal dash "$COPY"
  ANSWERS=type_answers
  sed 's/\^D//g' "$OUT" | tr -d '\010' | tail -n 2 >"$T/end.seen"
  check "[ $STATUS -eq 0 ] && ! grep -qF 'Enrollment code from Fermix' '$OUT' && cmp -s '$T/end.seen' '$T/end.expected'" \
    "at a terminal, the primary asks for no code and ends saying what it is and the commands that remove it (exit $STATUS)"
  if ! cmp -s "$T/end.seen" "$T/end.expected"; then sed 's/^/    /' "$OUT"; fi

  for case in "candidate receiving|This server is receiving its move" \
    "candidate staged|This server is receiving its move" \
    "primary |Fermix runs on this server as your primary"; do
    # shellcheck disable=SC2086 # the role and the phase
    home_is ${case%%|*}
    run FERMIX_ENROLL_CODE="$CODE" dash "$COPY"
    stopped_with "${case#*|}: $REMOVE" "a ${case%%|*} home given a code is refused, saying what it is and how to remove it"
    refused_after_reading_the_home "a ${case%%|*} home given a code"
    check "! grep -rqF -- '$CODE' '$T/run' '$OUT' '$ERR' '$LOG' '$ARGV'" "and the code is written nowhere"
  done
}

# Any other home is refused, code or not.
other_homes() {
  home_is device "" "Invented's Mac"
  run dash "$COPY"
  stopped_with "This server's Fermix home is a retired copy, left when Fermix moved to Invented's Mac: $REMOVE" \
    "a retired copy is refused, naming where Fermix moved"
  refused_after_reading_the_home "a retired copy"

  home_is device ""
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY"
  stopped_with "This server's Fermix runs as a desktop of another primary: $REMOVE" "a desktop's home is refused"

  home_is candidate ""
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY"
  stopped_with "This server's Fermix home is a candidate whose move cannot be read: $REMOVE" \
    "a candidate whose move cannot be read is refused"

  for phase in failed enrolled; do
    home_is candidate "$phase"
    run dash "$COPY" --restore
    stopped_with "This server holds a Fermix home that has not received its move: $REMOVE" \
      "--restore on a candidate $phase is refused"
  done

  home_refuses always_on_unavailable "Always On is not in this release of Fermix yet."
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY"
  stopped_with "fermix home status could not read the Fermix home $HOME_DIR_MOVED on this server (Always On is not in this release of Fermix yet): run sudo -H -u fermix /usr/bin/fermix home status to see why." \
    "a home fermix home status cannot read is refused, naming it, with the engine's own sentence and no command that removes it"
  refused_after_reading_the_home "a home the engine refuses to read"
}

/bin/mkdir -p "$BIN"
build_copy
make_shims
make_stand_ins
pass "the copy of first-boot.sh parses, its six moved lines each found once"

without_the_flag
key_from_the_environment
key_at_the_terminal
refusals
already_on_a_tailnet
tailscale_down
not_tailscales_key
tailscaled_does_not_start
up_fails
each_release
restore_host
enrolls_again
home_that_runs
other_homes

if [ -s "$FAILED" ]; then
  printf 'on host: %s check(s) failed\n' "$(wc -l <"$FAILED" | tr -d ' ')"
  exit 1
fi
echo "on host: every check passed"
