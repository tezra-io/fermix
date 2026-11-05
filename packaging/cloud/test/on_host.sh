#!/bin/sh
# Runs first-boot.sh's own main on this host, macOS or Linux, as any account
# and with no Docker: its arguments, the enrollment code and the Tailscale
# step for real, and the steps that need a Debian server as root stood in for
# by functions that log their names. Started by first_boot_test.sh.
#
# The copy it runs is first-boot.sh without its last line (`main "$@"`) and
# without the nightly update's writer (write_update_script, whose script the
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
# run a pty); a key without --tailscale, malformed keys and no key without a
# terminal, each refused before any step; a host already on a tailnet; a
# signing key that is not Tailscale's; tailscale up failing before enrolling;
# each supported release's repository; --restore. After every run the key is
# nowhere under this test's directory, in no logged command line and in no
# command's environment.
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
FAILURES=0

die() {
  printf 'on_host: %s\n' "$1" >&2
  exit 1
}

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
# so when the key file tailscale up read is still there.
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
EOF
  for step in check_host block_metadata add_swap install_fermix schedule_updates \
    create_engine_user enroll start_service install_browser await_enrollment print_restore_steps; do
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

make_stand_ins() {
  printf 'Invented bytes standing in for a signing key; gpg here is a stand-in.\n' >"$T/served-key.gpg"
  for tool in apt-get systemctl; do
    {
      echo '#!/bin/sh'
      record_lines
      cat <<EOF
printf '$tool %s\n' "\$*" >>'$LOG'
EOF
    } | write_exe "$BIN/$tool"
  done
  { echo '#!/bin/sh'; record_lines; stand_in_curl; } | write_exe "$BIN/curl"
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
# daemon that does not answer without it. status and ip answer from it and
# log nothing, as reads; up records the key file it was named (its path, its
# mode, a checksum of what it holds) and joins the invented tailnet, unless
# state/up-fails exists.
stand_in_tailscale() {
  cat <<EOF
state='$STATE'
case "\${1-}" in
  status)
    if [ ! -f "\$state/tailscale-state" ]; then
      echo "failed to connect to local tailscaled; it doesn't appear to be running" >&2
      exit 1
    fi
    printf '{\n  "BackendState": "%s",\n  "Self": {\n    "HostName": "invented-server"\n  }\n}\n' "\$(/bin/cat "\$state/tailscale-state")"
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
# typed from a pipe. Output and stderr both land in $OUT, without the pty's
# carriage returns.
run_at_terminal() {
  reset_logs
  for arg in "$@"; do
    case "$arg" in *[[:space:]]* | '') die "a terminal run's arguments are words, since script -c takes one string." ;; esac
  done
  set +e
  if [ "$(uname -s)" = Darwin ]; then
    type_answers "$CODE" "$KEY" | script -q /dev/null env -i PATH=/usr/bin:/bin "$@" >"$OUT" 2>&1
  else
    type_answers "$CODE" "$KEY" | script -qefc "env -i PATH=/usr/bin:/bin $*" /dev/null >"$OUT" 2>&1
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

NO_TAILSCALE_STEPS='step check_host
step block_metadata
step add_swap
step install_fermix
step schedule_updates
step create_engine_user
step enroll
step start_service
step install_browser
step await_enrollment'

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
  printf 'step enroll\nstep start_service\nstep install_browser\nstep await_enrollment\n'
}

key_cksum() {
  printf '%s' "$KEY" | cksum | cut -d' ' -f1
}

the_key_reached_tailscale_up() {
  check "[ \"\$(cat '$STATE/up-key-cksum')\" = \"\$(key_cksum)\" ]" "$1: tailscale up read the key from its file"
  check "[ \"\$(cat '$STATE/up-key-mode')\" = '-rw-------' ]" "$1: the key file is 0600"
  check "! grep -q 'the key file is still there' '$LOG'" "$1: the key file is removed before the next step"
  check "[ ! -e \"\$(cat '$STATE/up-key-path')\" ]" "$1: the key file is gone once the run ends"
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

  for bad in "tskex-auth-kInvented1CNTRL-InventedSecret0123456789|That is not a Tailscale auth key, which starts with tskey-. Create one in Tailscale's admin console and run this again." \
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

already_on_a_tailnet() {
  fresh_host
  echo Running >"$STATE/tailscale-state"
  run TS_AUTHKEY="$KEY" FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
  check "[ $STATUS -eq 0 ]" "a server already on a tailnet goes on (exit $STATUS)"
  [ "$STATUS" -eq 0 ] || sed 's/^/    /' "$OUT" "$ERR"
  printf '%s\n' "$NO_TAILSCALE_STEPS" | calls_are "it installs nothing of Tailscale and logs in again nowhere"
  check "grep -qxF '==> This server is already on a tailnet, so Tailscale is not installed or logged in again' '$OUT'" \
    "it says so"
  check "grep -qxF '==> This server is on your tailnet at 100.88.12.34' '$OUT'" "and names its tailnet address"
  key_left_nowhere "already on a tailnet"

  fresh_host
  echo Running >"$STATE/tailscale-state"
  run FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
  check "[ $STATUS -eq 0 ]" "a server already on a tailnet needs no key and no terminal (exit $STATUS)"
}

not_tailscales_key() {
  for keys in "$INVENTED_FPR" "$PINNED
$INVENTED_FPR"; do
    fresh_host
    printf '%s\n' "$keys" >"$STATE/gpg-primary-keys"
    run TS_AUTHKEY="$KEY" FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
    stopped_with "The key https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg serves is not Tailscale's package signing key alone ($PINNED), so Tailscale is not installed." \
      "a served key that is not Tailscale's alone is refused ($(printf '%s' "$keys" | tr '\n' ' '))"
    check "! grep -q 'install --no-install-recommends tailscale\|^tailscale \|^step enroll' '$LOG'" \
      "and nothing is installed from it, joined or enrolled"
    check "[ ! -e '$KEYRING' ] && [ ! -e '$SOURCE' ]" "and apt is given no keyring and no source"
    key_left_nowhere "a key that is not Tailscale's"
  done
}

up_fails() {
  fresh_host
  : >"$STATE/up-fails"
  run TS_AUTHKEY="$KEY" FERMIX_ENROLL_CODE="$CODE" dash "$COPY" --tailscale
  check "[ $STATUS -eq 1 ] && [ \"\$(tail -n 1 '$ERR')\" = \"fermix always-on: tailscale up did not join this server to your tailnet, so the first boot stops here; its message above says why. A key that is used up, expired or revoked is refused: create a new one and run this again.\" ]" \
    "a tailscale up that fails stops the first boot with one sentence (exit $STATUS)"
  [ "$STATUS" -eq 1 ] || sed 's/^/    /' "$OUT" "$ERR"
  check "grep -q '^tailscale up ' '$LOG' && ! grep -q '^step enroll' '$LOG'" "before enrolling"
  check "[ ! -e \"\$(cat '$STATE/up-key-path')\" ]" "the key file is gone after the failure"
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
not_tailscales_key
up_fails
each_release
restore_host

if [ "$FAILURES" -ne 0 ]; then
  printf 'on host: %s check(s) failed\n' "$FAILURES"
  exit 1
fi
echo "on host: every check passed"
